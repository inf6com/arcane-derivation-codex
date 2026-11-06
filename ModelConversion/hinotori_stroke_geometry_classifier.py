"""Stroke-order- and direction-invariant geometry classifier for 229 symbols."""
from __future__ import annotations

import torch
from torch import Tensor, nn

from hinotori_raster_classifier import CLASS_COUNT, EMBEDDING_DIMENSION
class HinotoriStrokeGeometryClassifier(nn.Module):
    """Classify symbol geometry while treating points/strokes as unordered sets.

    Point-cloud features preserve position. Undirected adjacent segment
    features preserve local line geometry without encoding stroke direction.
    Symmetric pooling removes stroke order and point traversal order.
    """

    def __init__(self, class_count: int = CLASS_COUNT, embedding_dimension: int = EMBEDDING_DIMENSION):
        super().__init__()
        if class_count != CLASS_COUNT or embedding_dimension < 1:
            raise ValueError("Hinotori requires exactly 229 classes and a positive embedding dimension")
        self.point_encoder = nn.Sequential(nn.Linear(2, 32), nn.SiLU(), nn.Linear(32, 32), nn.SiLU())
        self.segment_encoder = nn.Sequential(nn.Linear(5, 32), nn.SiLU(), nn.Linear(32, 32), nn.SiLU())
        self.stroke_encoder = nn.Sequential(nn.Linear(128, 128), nn.SiLU(), nn.Linear(128, 128), nn.SiLU())
        self.embedding = nn.Sequential(nn.Linear(256, 192), nn.SiLU(), nn.Dropout(0.15), nn.Linear(192, embedding_dimension))
        self.classifier = nn.Linear(embedding_dimension, CLASS_COUNT)

    def forward(self, points: Tensor, stroke_padding: Tensor, point_padding: Tensor) -> tuple[Tensor, Tensor]:
        if points.ndim != 4 or points.shape[-1] != 2:
            raise ValueError("points must be [batch,stroke,point,2]")
        batch, strokes, point_count, _ = points.shape
        if stroke_padding.shape != (batch, strokes) or stroke_padding.dtype != torch.bool:
            raise ValueError("stroke_padding must be boolean [batch,stroke]")
        if point_padding.shape != (batch, strokes, point_count) or point_padding.dtype != torch.bool:
            raise ValueError("point_padding must be boolean [batch,stroke,point]")
        valid_points = ~point_padding
        valid_strokes = ~stroke_padding
        if (valid_strokes & ~valid_points.any(dim=-1)).any() or (~valid_strokes & valid_points.any(dim=-1)).any():
            raise ValueError("stroke and point padding masks are inconsistent")
        if point_count < 2 or (~valid_strokes.any(dim=1)).any():
            raise ValueError("every symbol needs at least one stroke with two points")

        point_features = self.point_encoder(points)
        point_mask = valid_points.unsqueeze(-1)
        point_count_per_stroke = valid_points.sum(dim=2, keepdim=True).clamp_min(1).to(points.dtype)
        point_mean = point_features.masked_fill(~point_mask, 0.0).sum(dim=2) / point_count_per_stroke
        point_max = point_features.masked_fill(~point_mask, float("-inf")).amax(dim=2)
        point_max = point_max.masked_fill(stroke_padding.unsqueeze(-1), 0.0)

        starts, ends = points[:, :, :-1], points[:, :, 1:]
        delta = ends - starts
        reverse = (delta[..., 0] < 0) | ((delta[..., 0] == 0) & (delta[..., 1] < 0))
        undirected_delta = torch.where(reverse.unsqueeze(-1), -delta, delta)
        midpoint = (starts + ends) * 0.5
        segment_input = torch.cat((midpoint, undirected_delta, delta.norm(dim=-1, keepdim=True)), dim=-1)
        segment_features = self.segment_encoder(segment_input)
        segment_valid = valid_points[:, :, :-1] & valid_points[:, :, 1:]
        segment_mask = segment_valid.unsqueeze(-1)
        segment_count = segment_valid.sum(dim=2, keepdim=True).clamp_min(1).to(points.dtype)
        segment_mean = segment_features.masked_fill(~segment_mask, 0.0).sum(dim=2) / segment_count
        segment_max = segment_features.masked_fill(~segment_mask, float("-inf")).amax(dim=2)
        segment_max = segment_max.masked_fill(stroke_padding.unsqueeze(-1), 0.0)

        stroke_features = self.stroke_encoder(torch.cat((point_mean, point_max, segment_mean, segment_max), dim=-1))
        stroke_features = stroke_features.masked_fill(stroke_padding.unsqueeze(-1), 0.0)
        valid_count = valid_strokes.sum(dim=1, keepdim=True).clamp_min(1).to(points.dtype)
        group_mean = stroke_features.sum(dim=1) / valid_count
        group_max = stroke_features.masked_fill(stroke_padding.unsqueeze(-1), float("-inf")).amax(dim=1)
        group = torch.cat((group_mean, group_max), dim=-1)
        embedding = nn.functional.normalize(self.embedding(group), p=2, dim=1)
        return self.classifier(embedding), embedding
