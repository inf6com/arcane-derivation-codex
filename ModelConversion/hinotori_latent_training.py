"""Weak-primary losses for latent 229-symbol decomposition."""
from __future__ import annotations

import torch
from torch import Tensor


def weak_multiset_loss(instance_logits: Tensor, active: Tensor, target_counts: Tensor) -> Tensor:
    if instance_logits.ndim != 2 or instance_logits.shape[1] != 229 or active.shape != (instance_logits.shape[0],) or target_counts.shape != (229,):
        raise ValueError("invalid latent multiset tensor shapes")
    if (target_counts < 0).any() or target_counts.sum() < 1:
        raise ValueError("target_counts must be nonnegative and nonempty")
    predicted = (active.unsqueeze(1) * torch.softmax(instance_logits, dim=1)).sum(dim=0)
    count_loss = torch.nn.functional.smooth_l1_loss(predicted, target_counts.to(predicted.device))
    mass_loss = torch.nn.functional.smooth_l1_loss(active.sum(), target_counts.sum().to(active.device))
    return count_loss + mass_loss


def class_absence_loss(instance_logits: Tensor, active: Tensor, class_index: int) -> Tensor:
    """Penalize target-class mass for a formula known not to contain it."""
    if instance_logits.ndim != 2 or instance_logits.shape[1] != 229 or active.shape != (instance_logits.shape[0],):
        raise ValueError("invalid latent absence tensor shapes")
    if not 0 <= class_index < 229:
        raise ValueError("class_index must be in [0, 228]")
    predicted_count = (active * torch.softmax(instance_logits, dim=1)[:, class_index]).sum()
    return torch.nn.functional.smooth_l1_loss(predicted_count, torch.zeros((), device=predicted_count.device, dtype=predicted_count.dtype))


def direct_membership_loss(affinity: Tensor, groups: list[list[int]]) -> Tensor:
    if affinity.ndim != 2 or affinity.shape[0] != affinity.shape[1]:
        raise ValueError("affinity must be square")
    owner: dict[int, int] = {}
    for group_index, group in enumerate(groups):
        if not group or len(group) != len(set(group)):
            raise ValueError("groups must be nonempty and unique")
        for stroke in group:
            if stroke < 0 or stroke >= affinity.shape[0] or stroke in owner:
                raise ValueError("groups must partition supervised strokes")
            owner[stroke] = group_index
    pairs = [(left, right) for left in owner for right in owner if left != right]
    if not pairs:
        raise ValueError("membership loss needs at least two supervised strokes")
    prediction = torch.stack([affinity[left, right] for left, right in pairs]).clamp(torch.finfo(affinity.dtype).eps, 1 - torch.finfo(affinity.dtype).eps)
    target = torch.tensor([float(owner[left] == owner[right]) for left, right in pairs], device=affinity.device, dtype=affinity.dtype)
    positives = target.sum()
    negatives = target.numel() - positives
    if positives == 0 or negatives == 0:
        raise ValueError("membership loss needs both same and different-symbol pairs")
    weights = torch.where(target == 1, negatives / positives, torch.ones_like(target))
    return torch.nn.functional.binary_cross_entropy(prediction, target, weight=weights)
