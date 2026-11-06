"""End-to-end retrieval model plumbing for the 229-symbol classifier."""
from __future__ import annotations

import torch
from torch import Tensor, nn

from hinotori_group_proposer import StrokePairAffinity, decode_groups
from hinotori_inkml import canonical_group_tensor
from hinotori_retrieval import class_retrieval_logits
from hinotori_trajectory_encoder import TrajectoryGroupEncoder


class HinotoriRetrievalModel(nn.Module):
    """Trajectory encoder plus learned grouping and direct-example retrieval."""

    def __init__(self, embedding_dimension: int = 128, hidden_dimension: int = 128, point_count: int = 32, temperature: float = 0.07):
        super().__init__()
        if point_count < 1 or temperature <= 0:
            raise ValueError("point_count and temperature must be positive")
        self.point_count = point_count
        self.temperature = temperature
        self.encoder = TrajectoryGroupEncoder(embedding_dimension, hidden_dimension)
        self.group_proposer = StrokePairAffinity(embedding_dimension)

    def encode_groups(self, groups: list[Tensor]) -> Tensor:
        """Encode canonical [stroke,point,2] groups without truncation."""
        if not groups or any(group.ndim != 3 or group.shape[1:] != (self.point_count, 2) or group.shape[0] < 1 for group in groups):
            raise ValueError("groups must be nonempty canonical [stroke,point,2] tensors")
        max_strokes = max(group.shape[0] for group in groups)
        device = next(self.parameters()).device
        points = torch.zeros((len(groups), max_strokes, self.point_count, 2), dtype=torch.float32, device=device)
        stroke_padding = torch.ones((len(groups), max_strokes), dtype=torch.bool, device=device)
        point_padding = torch.ones((len(groups), max_strokes, self.point_count), dtype=torch.bool, device=device)
        for index, group in enumerate(groups):
            stroke_count = group.shape[0]
            points[index, :stroke_count] = group.to(device=device, dtype=torch.float32)
            stroke_padding[index, :stroke_count] = False
            point_padding[index, :stroke_count] = False
        return self.encoder(points, stroke_padding, point_padding)

    def formula_retrieval_logits(
        self,
        traces: list[Tensor],
        anchor_groups: list[Tensor],
        anchor_classes: Tensor,
        anchor_embeddings: Tensor | None = None,
    ) -> tuple[Tensor, list[list[int]], Tensor]:
        """Propose formula symbol groups then rank all 229 labels by retrieval.

        Decoding edges is discrete; the weak multiset loss therefore updates
        the trajectory encoder on the current proposed groups, while direct
        annotation batches supervise the affinity module itself.
        """
        if not traces:
            raise ValueError("formula must contain traces")
        singleton_groups = [canonical_group_tensor([trace], self.point_count) for trace in traces]
        stroke_embeddings = self.encode_groups(singleton_groups)
        padding = torch.zeros((1, len(traces)), dtype=torch.bool, device=stroke_embeddings.device)
        affinity = self.group_proposer(stroke_embeddings.unsqueeze(0), padding)[0]
        decoded = decode_groups(affinity.detach(), padding[0])
        proposed_groups = [canonical_group_tensor([traces[index] for index in group], self.point_count) for group in decoded]
        query = self.encode_groups(proposed_groups)
        anchors = self.encode_groups(anchor_groups) if anchor_embeddings is None else anchor_embeddings
        if anchors.ndim != 2 or anchors.shape[0] != len(anchor_groups):
            raise ValueError("anchor_embeddings must align with every direct anchor group")
        logits = class_retrieval_logits(query, anchors, anchor_classes.to(query.device), 229, self.temperature)
        return logits, decoded, affinity
