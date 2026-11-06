"""Order-aware online trajectory classifier for isolated handwritten symbols."""
from __future__ import annotations

import torch
from torch import Tensor, nn
from torch.nn import functional as F

from hinotori_raster_classifier import CLASS_COUNT, EMBEDDING_DIMENSION


class FirebirdOnlineTrajectoryEncoder(nn.Module):
    """Encode stroke motion without relying on stroke order or travel direction.

    The input is not a raster image. Each stroke is a 128-point, arc-length
    resampled XY path in the shared canonical coordinate frame. Tangent and
    curvature channels are derived from consecutive points. A bidirectional
    bidirectional stroke encoder reads each path. Forward/reverse summaries are
    averaged and stroke vectors are pooled symmetrically, so left-to-right vs
    right-to-left travel and stroke ordering are not required class labels.
    InkML source traces do not provide reliable timestamps, so this model does
    not claim to learn physical speed or elapsed time.
    """

    def __init__(self, hidden_dimension: int = 96, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if hidden_dimension < 16 or embedding_dimension < 16:
            raise ValueError("hidden and embedding dimensions are too small")
        # x,y; first path difference; change in path difference (curvature proxy)
        self.point_encoder = nn.LSTM(
            input_size=6, hidden_size=hidden_dimension, num_layers=1,
            batch_first=True, bidirectional=True,
        )
        self.stroke_projection = nn.Sequential(
            nn.Linear(hidden_dimension * 4, 128), nn.LayerNorm(128), nn.GELU(),
        )
        self.embedding = nn.Sequential(
            nn.Linear(128 * 2, 192), nn.GELU(), nn.Dropout(0.20),
            nn.Linear(192, embedding_dimension), nn.LayerNorm(embedding_dimension),
        )

    @staticmethod
    def trajectory_features(points: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 2 or points.shape[2] < 2:
            raise ValueError("points must have shape [batch,stroke,point>=2,2]")
        if not torch.isfinite(points).all():
            raise ValueError("trajectory coordinates must be finite")
        delta = points[:, :, 1:] - points[:, :, :-1]
        delta = F.pad(delta, (0, 0, 1, 0))
        curvature = F.pad(delta[:, :, 1:] - delta[:, :, :-1], (0, 0, 1, 0))
        return torch.cat((points, delta, curvature), dim=-1)

    def encode(self, points: Tensor, stroke_padding: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 2:
            raise ValueError("points must be [batch,stroke,point,2]")
        batch, stroke_count, point_count, _ = points.shape
        if stroke_padding.shape != (batch, stroke_count) or stroke_padding.dtype != torch.bool:
            raise ValueError("stroke_padding must be boolean [batch,stroke]")
        stroke_valid = ~stroke_padding
        if (~stroke_valid.any(dim=1)).any():
            raise ValueError("every symbol must contain at least one stroke")
        if point_count < 2:
            raise ValueError("every stroke must contain at least two sampled points")

        features = self.trajectory_features(points)
        flat_features = features.reshape(batch * stroke_count, point_count, 6)
        forward_sequence, _ = self.point_encoder(flat_features)
        reverse_sequence, _ = self.point_encoder(flat_features.flip(dims=(1,)))

        def summarize(sequence: Tensor) -> Tensor:
            return torch.cat((sequence.mean(dim=1), sequence.amax(dim=1)), dim=-1)

        # Reversal swaps the BiLSTM direction channels. Averaging both passes
        # makes the representation invariant to pen travel direction while
        # retaining the sequence of XY changes within each stroke.
        stroke_summary = (summarize(forward_sequence) + summarize(reverse_sequence)) * 0.5
        stroke_vectors = self.stroke_projection(stroke_summary).reshape(batch, stroke_count, 128)
        mask = stroke_valid.unsqueeze(-1)
        stroke_mean = stroke_vectors.masked_fill(~mask, 0.0).sum(dim=1)
        stroke_mean = stroke_mean / stroke_valid.sum(dim=1, keepdim=True).clamp_min(1)
        stroke_max = stroke_vectors.masked_fill(~mask, float("-inf")).amax(dim=1)
        combined = torch.cat((stroke_mean, stroke_max), dim=-1)
        return F.normalize(self.embedding(combined), p=2, dim=1)

    def forward(self, points: Tensor, stroke_padding: Tensor) -> Tensor:
        return self.encode(points, stroke_padding)


class FirebirdOnlineTrajectoryClassifier(nn.Module):
    """229-class trajectory-only comparison model using the shared encoder."""

    def __init__(self, hidden_dimension: int = 96, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        self.encoder = FirebirdOnlineTrajectoryEncoder(hidden_dimension, embedding_dimension)
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def encode(self, points: Tensor, stroke_padding: Tensor) -> Tensor:
        return self.encoder(points, stroke_padding)

    def forward(self, points: Tensor, stroke_padding: Tensor) -> tuple[Tensor, Tensor]:
        embedding = self.encode(points, stroke_padding)
        return self.classifier(embedding), embedding
