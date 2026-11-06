"""Learned stroke-pair affinity for Hinotori candidate groups.

This module deliberately produces pairwise same-symbol logits only.  It does
not use distance thresholds, rectangles, grids, or an unverified clustering
rule to pretend that a group has been recovered.
"""
from __future__ import annotations

import torch
from torch import Tensor, nn


def direct_pair_targets(trace_count: int, annotated_groups: list[list[int]]) -> tuple[Tensor, Tensor]:
    """Return pair targets and supervision mask from direct annotations.

    A pair is supervised only if both traces are assigned by direct labels.
    Overlapping groups are rejected: one trace cannot be two symbols.
    """
    if trace_count < 1:
        raise ValueError("trace_count must be positive")
    owners: dict[int, int] = {}
    for group_index, group in enumerate(annotated_groups):
        if not group or len(group) != len(set(group)):
            raise ValueError("annotated group must be nonempty and unique")
        for trace in group:
            if trace < 0 or trace >= trace_count:
                raise ValueError(f"trace index {trace} outside trace_count={trace_count}")
            if trace in owners:
                raise ValueError(f"trace {trace} belongs to direct groups {owners[trace]} and {group_index}")
            owners[trace] = group_index
    target = torch.zeros((trace_count, trace_count), dtype=torch.float32)
    supervised = torch.zeros((trace_count, trace_count), dtype=torch.bool)
    for left, left_owner in owners.items():
        for right, right_owner in owners.items():
            if left == right:
                continue
            supervised[left, right] = True
            target[left, right] = float(left_owner == right_owner)
    return target, supervised


class StrokePairAffinity(nn.Module):
    """Maps per-stroke embeddings to symmetric same-symbol pair logits."""
    def __init__(self, embedding_dimension: int):
        super().__init__()
        if embedding_dimension < 1:
            raise ValueError("embedding_dimension must be positive")
        self.projection = nn.Linear(embedding_dimension, embedding_dimension, bias=False)

    def forward(self, embeddings: Tensor, padding: Tensor) -> Tensor:
        if embeddings.ndim != 3 or padding.shape != embeddings.shape[:2] or padding.dtype != torch.bool:
            raise ValueError("embeddings must be [batch,trace,dimension] with boolean [batch,trace] padding")
        projected = self.projection(embeddings)
        logits = projected @ projected.transpose(1, 2)
        logits = (logits + logits.transpose(1, 2)) / 2
        valid_pairs = (~padding).unsqueeze(1) & (~padding).unsqueeze(2)
        return logits.masked_fill(~valid_pairs, float("-inf"))


def affinity_loss(logits: Tensor, targets: Tensor, supervised: Tensor) -> Tensor:
    if logits.shape != targets.shape or logits.shape != supervised.shape:
        raise ValueError("logits, targets, and supervised masks must have the same shape")
    if logits.ndim != 3:
        raise ValueError("pair tensors must be [batch,trace,trace]")
    diagonal = torch.eye(logits.shape[-1], dtype=torch.bool, device=logits.device).unsqueeze(0)
    selected = supervised & ~diagonal
    if not selected.any():
        raise ValueError("batch has no supervised stroke pairs")
    selected_targets = targets[selected]
    positives = selected_targets.sum()
    negatives = selected_targets.numel() - positives
    if positives <= 0 or negatives <= 0:
        raise ValueError("affinity supervision requires both same-symbol and different-symbol pairs")
    # Direct annotations contain far more different-symbol pairs.  Without
    # balancing, predicting every pair as different is a lower-risk shortcut
    # than learning the positive grouping relation.
    positive_weight = negatives / positives
    return nn.functional.binary_cross_entropy_with_logits(logits[selected], selected_targets, pos_weight=positive_weight)


def decode_groups(affinity_logits: Tensor, padding: Tensor, threshold: float = 0.0) -> list[list[int]]:
    """Decode one learned affinity matrix into stroke groups.

    An edge is accepted only when the trained model assigns it probability
    greater than 0.5 (logit greater than zero).  The threshold is a declared
    probability decision boundary, not a geometric heuristic; its adequacy is
    measured against held-out direct annotations before product use.
    """
    if affinity_logits.ndim != 2 or affinity_logits.shape[0] != affinity_logits.shape[1]:
        raise ValueError("affinity_logits must be square [trace,trace]")
    if padding.shape != (affinity_logits.shape[0],) or padding.dtype != torch.bool:
        raise ValueError("padding must be boolean [trace]")
    if not torch.isfinite(affinity_logits[~padding][:, ~padding]).all():
        raise ValueError("non-padded affinity logits must be finite")
    valid = [index for index in range(affinity_logits.shape[0]) if not padding[index]]
    if not valid:
        raise ValueError("at least one non-padded trace is required")
    parent = {index: index for index in valid}

    def find(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(left: int, right: int) -> None:
        left_root, right_root = find(left), find(right)
        if left_root != right_root:
            parent[right_root] = left_root

    for left_position, left in enumerate(valid):
        for right in valid[left_position + 1:]:
            if affinity_logits[left, right].item() > threshold:
                union(left, right)
    groups: dict[int, list[int]] = {}
    for trace in valid:
        groups.setdefault(find(trace), []).append(trace)
    return list(groups.values())
