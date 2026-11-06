"""Weak formula-level multiset supervision for Hinotori retrieval.

The final LaTeX supplies a multiset of visual symbol tokens, not invented
stroke-to-symbol assignments.  This loss transports proposed-group class
probability mass to that multiset and remains differentiable with respect to
the retrieval logits.
"""
from __future__ import annotations

import torch
from torch import Tensor


def sinkhorn_multiset_loss(
    group_class_logits: Tensor,
    target_counts: Tensor,
    regularization: float = 0.1,
    iterations: int = 80,
) -> Tensor:
    """Return entropic OT loss from proposed groups to a target symbol multiset.

    Each proposed group contributes equal mass.  Target count mass is scaled
    to one, so a formula with repeated tokens retains those repetitions
    without requiring a fabricated per-stroke label.
    """
    if group_class_logits.ndim != 3:
        raise ValueError("group_class_logits must be [batch,group,class]")
    batch, groups, class_count = group_class_logits.shape
    if groups < 1 or class_count != 229:
        raise ValueError("at least one group and exactly 229 classes are required")
    if target_counts.shape != (batch, class_count):
        raise ValueError("target_counts must be [batch,229]")
    if target_counts.dtype not in (torch.int32, torch.int64, torch.float32, torch.float64):
        raise ValueError("target_counts must be numeric")
    if (target_counts < 0).any() or (target_counts.sum(dim=1) == 0).any():
        raise ValueError("every formula needs a nonnegative, nonempty target multiset")
    if regularization <= 0 or iterations < 1:
        raise ValueError("regularization and iterations must be positive")

    log_probabilities = torch.log_softmax(group_class_logits, dim=-1)
    cost = -log_probabilities
    source_mass = torch.full((batch, groups), 1.0 / groups, device=group_class_logits.device, dtype=cost.dtype)
    target_mass = target_counts.to(device=cost.device, dtype=cost.dtype)
    target_mass = target_mass / target_mass.sum(dim=1, keepdim=True)

    log_kernel = -cost / regularization
    log_source = source_mass.log()
    log_target = target_mass.clamp_min(torch.finfo(cost.dtype).tiny).log()
    log_u = torch.zeros_like(source_mass)
    log_v = torch.zeros_like(target_mass)
    for _ in range(iterations):
        log_u = log_source - torch.logsumexp(log_kernel + log_v.unsqueeze(1), dim=2)
        log_v = log_target - torch.logsumexp(log_kernel + log_u.unsqueeze(2), dim=1)
    plan = torch.exp(log_kernel + log_u.unsqueeze(2) + log_v.unsqueeze(1))
    return (plan * cost).sum(dim=(1, 2)).mean()
