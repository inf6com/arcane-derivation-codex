"""Raster plus direction-symmetrized per-stroke BiLSTM for 229 isolated symbols."""
from __future__ import annotations

import torch
from torch import Tensor, nn
from torch.nn import functional as F

from hinotori_raster_classifier import CLASS_COUNT, RASTER_SIZE, ConvBlock


class FirebirdBiLSTMFusion(nn.Module):
    """Fuse spatial ink with stroke-local bidirectional sequence evidence.

    Stroke permutation and traversal direction are not labels: stroke vectors
    are pooled symmetrically, and each stroke is encoded in both directions.
    The recurrent branch retains within-stroke curvature/order while the raster
    branch retains global 2-D layout. This is a development candidate, not an
    assertion that either branch improves accuracy or runs on ANE.
    """

    def __init__(self, embedding_dimension: int = 128, hidden_dimension: int = 64):
        super().__init__()
        if embedding_dimension < 16 or hidden_dimension < 8:
            raise ValueError("embedding and hidden dimensions are too small")
        self.raster_features = nn.Sequential(
            nn.Conv2d(1, 32, 3, padding=1, bias=False), nn.BatchNorm2d(32), nn.SiLU(), nn.MaxPool2d(2),
            ConvBlock(32, 48), ConvBlock(48, 64, stride=2),
            ConvBlock(64, 96, stride=2), ConvBlock(96, 128, stride=2),
        )
        self.raster_projection = nn.Sequential(nn.Linear(256, 128), nn.SiLU())
        self.stroke_encoder = nn.LSTM(
            input_size=2, hidden_size=hidden_dimension, num_layers=1,
            batch_first=True, bidirectional=True,
        )
        stroke_feature_size = hidden_dimension * 4  # pooled mean and max over 2 directions
        self.stroke_projection = nn.Sequential(
            nn.Linear(stroke_feature_size, 128), nn.SiLU(), nn.Dropout(0.10),
        )
        self.fusion = nn.Sequential(
            nn.Linear(128 * 3, 256), nn.SiLU(), nn.Dropout(0.20),
            nn.Linear(256, embedding_dimension),
        )
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def encode_strokes(self, points: Tensor, stroke_valid: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 2:
            raise ValueError("points must have shape [batch,stroke,point,2]")
        batch, stroke_count, point_count, _ = points.shape
        if point_count < 2 or stroke_valid.shape != (batch, stroke_count):
            raise ValueError("stroke validity mask or point count is invalid")
        if stroke_valid.dtype != torch.bool or (~stroke_valid.any(dim=1)).any():
            raise ValueError("each symbol must contain a valid stroke")
        if not torch.isfinite(points).all():
            raise ValueError("trajectory coordinates must be finite")

        flat = points.reshape(batch * stroke_count, point_count, 2)
        forward_features, _ = self.stroke_encoder(flat)
        reverse_features, _ = self.stroke_encoder(flat.flip(dims=(1,)))
        # Time pooling and direction averaging ensure reversal invariance.
        forward_summary = torch.cat((forward_features.mean(dim=1), forward_features.amax(dim=1)), dim=-1)
        reverse_summary = torch.cat((reverse_features.mean(dim=1), reverse_features.amax(dim=1)), dim=-1)
        per_stroke = self.stroke_projection((forward_summary + reverse_summary) * 0.5)
        per_stroke = per_stroke.reshape(batch, stroke_count, -1)
        mask = stroke_valid.unsqueeze(-1)
        mean = per_stroke.masked_fill(~mask, 0.0).sum(dim=1) / stroke_valid.sum(dim=1, keepdim=True).clamp_min(1)
        maximum = per_stroke.masked_fill(~mask, float("-inf")).amax(dim=1)
        return torch.cat((mean, maximum), dim=-1)

    def encode(self, images: Tensor, points: Tensor, stroke_valid: Tensor) -> Tensor:
        if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
        if points.shape[:2] != stroke_valid.shape or points.shape[0] != images.shape[0]:
            raise ValueError("raster, trajectory, and stroke-mask batches do not align")
        raster_map = self.raster_features(images)
        raster = torch.cat((F.adaptive_avg_pool2d(raster_map, 1).flatten(1),
                            F.adaptive_max_pool2d(raster_map, 1).flatten(1)), dim=1)
        raster = self.raster_projection(raster)
        strokes = self.encode_strokes(points, stroke_valid)
        return F.normalize(self.fusion(torch.cat((raster, strokes), dim=1)), p=2, dim=1)

    def forward(self, images: Tensor, points: Tensor, stroke_valid: Tensor) -> tuple[Tensor, Tensor]:
        embedding = self.encode(images, points, stroke_valid)
        return self.classifier(embedding), embedding
