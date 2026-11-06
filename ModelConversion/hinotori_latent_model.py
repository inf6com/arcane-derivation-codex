"""Differentiable latent-symbol decomposition for weak 229-class supervision."""
from __future__ import annotations

import math

import torch
from torch import Tensor, nn

from hinotori_inkml import canonical_group_tensor
from hinotori_retrieval import class_retrieval_logits
from hinotori_trajectory_encoder import TrajectoryGroupEncoder


class LatentHinotoriModel(nn.Module):
    """Learns stroke membership and 229 retrieval from formula-level teachers.

    Every input stroke provides one latent-instance slot.  Assignment is soft,
    so formula multiset loss reaches the membership logits; no thresholded
    clustering occurs on the weak-training path.
    """

    def __init__(self, embedding_dimension: int = 128, hidden_dimension: int = 128, point_count: int = 32, temperature: float = 0.07):
        super().__init__()
        if embedding_dimension < 1 or hidden_dimension < 1 or point_count < 1 or temperature <= 0:
            raise ValueError("dimensions, point_count, and temperature must be positive")
        self.point_count = point_count
        self.temperature = temperature
        self.encoder = TrajectoryGroupEncoder(embedding_dimension, hidden_dimension)
        self.spatial = nn.Sequential(nn.Linear(4, hidden_dimension), nn.GELU(), nn.Linear(hidden_dimension, embedding_dimension))
        self.query = nn.Linear(embedding_dimension, embedding_dimension, bias=False)
        self.key = nn.Linear(embedding_dimension, embedding_dimension, bias=False)
        self.active = nn.Sequential(nn.Linear(embedding_dimension, hidden_dimension), nn.GELU(), nn.Linear(hidden_dimension, 1))

    def encode_groups(self, groups: list[Tensor]) -> Tensor:
        if not groups or any(group.ndim != 3 or group.shape[1:] != (self.point_count, 2) or group.shape[0] < 1 for group in groups):
            raise ValueError("groups must be nonempty canonical [stroke,point,2] tensors")
        maximum = max(group.shape[0] for group in groups)
        device = next(self.parameters()).device
        points = torch.zeros((len(groups), maximum, self.point_count, 2), dtype=torch.float32, device=device)
        stroke_padding = torch.ones((len(groups), maximum), dtype=torch.bool, device=device)
        point_padding = torch.ones((len(groups), maximum, self.point_count), dtype=torch.bool, device=device)
        for index, group in enumerate(groups):
            points[index, :group.shape[0]] = group.to(device=device, dtype=torch.float32)
            stroke_padding[index, :group.shape[0]] = False
            point_padding[index, :group.shape[0]] = False
        return self.encoder(points, stroke_padding, point_padding)

    def latent_instances(self, traces: list[Tensor]) -> tuple[Tensor, Tensor, Tensor]:
        """Return instance embeddings, active probabilities, and stroke affinity."""
        if not traces or any(trace.ndim != 2 or trace.shape[1] != 2 or trace.shape[0] < 1 for trace in traces):
            raise ValueError("traces must be nonempty [point,2] tensors")
        device = next(self.parameters()).device
        singleton = [canonical_group_tensor([trace], self.point_count) for trace in traces]
        shape = self.encode_groups(singleton)
        all_points = torch.cat([trace.to(device=device, dtype=torch.float32) for trace in traces], dim=0)
        lower, upper = all_points.amin(dim=0), all_points.amax(dim=0)
        span = (upper - lower).amax().clamp_min(torch.finfo(all_points.dtype).eps)
        spatial_rows = []
        for trace in traces:
            points = trace.to(device=device, dtype=torch.float32)
            minimum, maximum = points.amin(dim=0), points.amax(dim=0)
            center = (minimum + maximum) / 2
            spatial_rows.append(torch.cat(((center - lower) / span, (maximum - minimum) / span)))
        stroke = nn.functional.normalize(shape + self.spatial(torch.stack(spatial_rows)), p=2, dim=1)
        logits = self.query(stroke) @ self.key(stroke).transpose(0, 1) / math.sqrt(stroke.shape[1])
        # Each stroke assigns continuously across latent slots.  This is the
        # differentiable same-symbol relation used by direct supervision.
        membership = torch.softmax(logits, dim=0)
        # Each slot pools the strokes it currently explains.
        pooling = torch.softmax(logits, dim=1)
        instances = nn.functional.normalize(pooling @ stroke, p=2, dim=1)
        active = torch.sigmoid(self.active(instances).squeeze(1))
        affinity = membership.transpose(0, 1) @ membership
        return instances, active, affinity

    def weak_logits(self, traces: list[Tensor], anchor_groups: list[Tensor], anchor_classes: Tensor) -> tuple[Tensor, Tensor, Tensor]:
        instances, active, affinity = self.latent_instances(traces)
        anchors = self.encode_groups(anchor_groups)
        logits = class_retrieval_logits(instances, anchors, anchor_classes.to(instances.device), 229, self.temperature)
        return logits, active, affinity
