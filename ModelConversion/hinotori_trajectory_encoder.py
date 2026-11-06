"""Trajectory encoder for the Hinotori retrieval classifier.

The encoder consumes only ordered pen trajectories for one proposed symbol
group.  It emits a unit-length embedding; class scoring is intentionally kept
in ``hinotori_retrieval`` against the direct annotated anchor bank.
"""
from __future__ import annotations

import torch
from torch import Tensor, nn


class TrajectoryGroupEncoder(nn.Module):
    """Encode padded stroke trajectories as a retrieval embedding.

    ``points`` is [batch, stroke, point, 2]. ``stroke_padding`` marks absent
    strokes and ``point_padding`` marks absent points.  A non-padded stroke
    must contain at least one non-padded point; otherwise its input contract is
    invalid and is rejected rather than silently repaired.
    """

    def __init__(self, embedding_dimension: int, hidden_dimension: int = 128):
        super().__init__()
        if embedding_dimension < 1 or hidden_dimension < 1:
            raise ValueError("embedding_dimension and hidden_dimension must be positive")
        self.point_encoder = nn.Sequential(
            nn.Linear(2, hidden_dimension),
            nn.GELU(),
            nn.Linear(hidden_dimension, hidden_dimension),
            nn.GELU(),
        )
        self.stroke_encoder = nn.GRU(hidden_dimension, hidden_dimension, batch_first=True)
        self.output = nn.Linear(hidden_dimension, embedding_dimension)

    def forward(self, points: Tensor, stroke_padding: Tensor, point_padding: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[-1] != 2:
            raise ValueError("points must be [batch,stroke,point,2]")
        batch, strokes, point_count, _ = points.shape
        if stroke_padding.shape != (batch, strokes) or stroke_padding.dtype != torch.bool:
            raise ValueError("stroke_padding must be boolean [batch,stroke]")
        if point_padding.shape != (batch, strokes, point_count) or point_padding.dtype != torch.bool:
            raise ValueError("point_padding must be boolean [batch,stroke,point]")
        valid_points = ~point_padding
        valid_strokes = ~stroke_padding
        if (valid_strokes & ~valid_points.any(dim=-1)).any():
            raise ValueError("every non-padded stroke must contain a point")
        if (~valid_strokes & valid_points.any(dim=-1)).any():
            raise ValueError("padded strokes must not contain points")
        encoded_points = self.point_encoder(points)
        encoded_points = encoded_points.masked_fill(point_padding.unsqueeze(-1), float("-inf"))
        stroke_vectors = encoded_points.amax(dim=2)
        stroke_vectors = stroke_vectors.masked_fill(stroke_padding.unsqueeze(-1), 0.0)
        sequence, _ = self.stroke_encoder(stroke_vectors)
        valid_count = valid_strokes.sum(dim=1)
        if (valid_count == 0).any():
            raise ValueError("group must contain at least one stroke")
        final_index = valid_count - 1
        group_vectors = sequence[torch.arange(batch, device=points.device), final_index]
        return nn.functional.normalize(self.output(group_vectors), p=2, dim=-1)
