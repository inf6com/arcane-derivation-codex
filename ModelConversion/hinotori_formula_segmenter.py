"""Formula-frame stroke-pair model for grouping pen traces into symbols."""
from __future__ import annotations

import torch
from torch import Tensor, nn


def resample_formula_strokes(strokes: list[Tensor], point_count: int = 32) -> Tensor:
    """Normalize all traces in one formula frame, then arc-length resample.

    Unlike isolated-symbol normalization, this retains each stroke's position
    and scale relative to the complete formula. No stroke is reordered.
    """
    if not strokes or point_count < 2:
        raise ValueError("strokes must be nonempty and point_count must be at least 2")
    if any(stroke.ndim != 2 or stroke.shape[1] != 2 or stroke.shape[0] < 1 for stroke in strokes):
        raise ValueError("every trace must be a nonempty [point,2] tensor")
    all_points = torch.cat(strokes, dim=0).to(dtype=torch.float32)
    if not torch.isfinite(all_points).all():
        raise ValueError("formula traces contain non-finite coordinates")
    lower, upper = all_points.amin(dim=0), all_points.amax(dim=0)
    extent = (upper - lower).amax()
    if extent == 0:
        normalized = [torch.zeros_like(stroke, dtype=torch.float32) for stroke in strokes]
    else:
        center = (lower + upper) / 2
        normalized = [(stroke.to(torch.float32) - center) / extent for stroke in strokes]
    return torch.stack([_resample(stroke, point_count) for stroke in normalized])


def _resample(points: Tensor, count: int) -> Tensor:
    if points.shape[0] == 1:
        return points.expand(count, -1).clone()
    lengths = (points[1:] - points[:-1]).norm(dim=1)
    keep = torch.cat((torch.ones(1, dtype=torch.bool), lengths > 0))
    points = points[keep]
    if points.shape[0] == 1:
        return points.expand(count, -1).clone()
    lengths = (points[1:] - points[:-1]).norm(dim=1)
    cumulative = torch.cat((torch.zeros(1), lengths.cumsum(0)))
    if cumulative[-1] == 0:
        return points[:1].expand(count, -1).clone()
    targets = torch.linspace(0, float(cumulative[-1]), count)
    upper = torch.searchsorted(cumulative, targets, right=True).clamp(1, points.shape[0] - 1)
    lower = upper - 1
    ratio = ((targets - cumulative[lower]) / (cumulative[upper] - cumulative[lower])).unsqueeze(1)
    return points[lower] + ratio * (points[upper] - points[lower])


class HinotoriFormulaSegmenter(nn.Module):
    """Predicts symmetric same-symbol logits for every pair of formula traces."""
    def __init__(self, point_count: int = 32, embedding_dimension: int = 96):
        super().__init__()
        if point_count < 2 or embedding_dimension < 8:
            raise ValueError("invalid point or embedding dimension")
        self.point_count = point_count
        self.embedding_dimension = embedding_dimension
        self.stroke_encoder = nn.Sequential(
            nn.Conv1d(2, 32, kernel_size=5, padding=2), nn.GELU(),
            nn.Conv1d(32, 64, kernel_size=5, padding=2), nn.GELU(),
            nn.Conv1d(64, embedding_dimension, kernel_size=3, padding=1), nn.GELU(),
        )
        self.stroke_projection = nn.Sequential(
            nn.Linear(embedding_dimension * 2 + 6, embedding_dimension), nn.GELU(),
            nn.Linear(embedding_dimension, embedding_dimension),
        )
        pair_width = embedding_dimension * 2 + 6
        self.pair_scorer = nn.Sequential(
            nn.Linear(pair_width, embedding_dimension), nn.GELU(),
            nn.Linear(embedding_dimension, embedding_dimension // 2), nn.GELU(),
            nn.Linear(embedding_dimension // 2, 1),
        )

    def forward(self, points: Tensor, stroke_valid: Tensor) -> Tensor:
        if points.ndim != 4 or points.shape[2:] != (self.point_count, 2):
            raise ValueError("points must be [batch,stroke,point_count,2]")
        # Keep data-dependent finite-value checks outside forward: torch.export
        # must be able to trace this fixed-shape graph. Callers validate input
        # values before inference; this branch is shape-only and export-safe.
        if stroke_valid.shape != points.shape[:2]:
            raise ValueError("stroke_valid must be [batch,stroke]")
        batch, stroke_count = points.shape[:2]
        flat = points.reshape(batch * stroke_count, self.point_count, 2).transpose(1, 2)
        encoded = self.stroke_encoder(flat)
        pooled = torch.cat((encoded.mean(dim=-1), encoded.amax(dim=-1)), dim=-1)
        traces = points
        centers = traces.mean(dim=2)
        extents = traces.amax(dim=2) - traces.amin(dim=2)
        directions = traces[:, :, -1] - traces[:, :, 0]
        geometry = torch.cat((centers, extents, directions), dim=-1).reshape(batch * stroke_count, 6)
        stroke_embedding = self.stroke_projection(torch.cat((pooled, geometry), dim=-1))
        stroke_embedding = stroke_embedding.reshape(batch, stroke_count, self.embedding_dimension)

        left = stroke_embedding.unsqueeze(2).expand(-1, -1, stroke_count, -1)
        right = stroke_embedding.unsqueeze(1).expand(-1, stroke_count, -1, -1)
        center_delta = centers.unsqueeze(2) - centers.unsqueeze(1)
        extent_delta = extents.unsqueeze(2) - extents.unsqueeze(1)
        direction_delta = directions.unsqueeze(2) - directions.unsqueeze(1)
        relation = torch.cat((center_delta, extent_delta, direction_delta), dim=-1)
        forward = self.pair_scorer(torch.cat((left, right, relation), dim=-1))
        reverse = self.pair_scorer(torch.cat((right, left, -relation), dim=-1))
        logits = ((forward + reverse) * 0.5).squeeze(-1)
        # `stroke_valid` is a binary 0/1 mask. Multiplying the two endpoint
        # masks keeps padded pairs at zero and stays representable in Core ML.
        pair_valid = stroke_valid.unsqueeze(1) * stroke_valid.unsqueeze(2)
        return logits * pair_valid


def direct_pair_targets(trace_count: int, annotated_groups: list[list[int]]) -> tuple[Tensor, Tensor]:
    """Create pair labels only for traces explicitly covered by direct teachers."""
    if trace_count < 1:
        raise ValueError("trace_count must be positive")
    owners: dict[int, int] = {}
    for group_id, group in enumerate(annotated_groups):
        if not group or len(group) != len(set(group)):
            raise ValueError("annotated symbol groups must be nonempty and unique")
        for trace_index in group:
            if not 0 <= trace_index < trace_count or trace_index in owners:
                raise ValueError("trace annotation is out of range or assigned to multiple symbols")
            owners[trace_index] = group_id
    targets = torch.zeros((trace_count, trace_count), dtype=torch.float32)
    supervised = torch.zeros((trace_count, trace_count), dtype=torch.bool)
    for left, left_owner in owners.items():
        for right, right_owner in owners.items():
            if left != right:
                supervised[left, right] = True
                targets[left, right] = float(left_owner == right_owner)
    return targets, supervised
