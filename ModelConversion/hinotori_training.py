"""Loss wiring for the Hinotori retrieval-training objective.

No term here is a fixed 229-way classifier.  Direct annotations train retrieval
geometry and stroke affinity; full formulas train the final-LaTeX multiset
constraint over groups proposed by that affinity model.
"""
from __future__ import annotations

import torch
from torch import Tensor

from hinotori_anchor_loss import direct_anchor_metric_loss
from hinotori_group_proposer import affinity_loss, direct_pair_targets
from hinotori_inkml import canonical_group_tensor
from hinotori_model import HinotoriRetrievalModel
from hinotori_weak_multiset import sinkhorn_multiset_loss


def direct_retrieval_loss(
    model: HinotoriRetrievalModel,
    query_groups: list[Tensor],
    query_classes: Tensor,
    bank_groups: list[Tensor],
    bank_classes: Tensor,
) -> Tensor:
    """Metric loss from direct annotations to the direct-example search bank."""
    return direct_anchor_metric_loss(
        model.encode_groups(query_groups), query_classes.to(next(model.parameters()).device),
        model.encode_groups(bank_groups), bank_classes.to(next(model.parameters()).device), model.temperature,
    )


def direct_grouping_loss(model: HinotoriRetrievalModel, traces: list[Tensor], annotated_groups: list[list[int]]) -> Tensor:
    """Supervise same-symbol stroke affinity only where direct labels exist."""
    if not traces:
        raise ValueError("direct formula must contain traces")
    singleton_groups = [canonical_group_tensor([trace], model.point_count) for trace in traces]
    embeddings = model.encode_groups(singleton_groups)
    padding = torch.zeros((1, len(traces)), dtype=torch.bool, device=embeddings.device)
    logits = model.group_proposer(embeddings.unsqueeze(0), padding)
    targets, supervised = direct_pair_targets(len(traces), annotated_groups)
    return affinity_loss(logits, targets.unsqueeze(0).to(logits.device), supervised.unsqueeze(0).to(logits.device))


def weak_formula_loss(
    model: HinotoriRetrievalModel,
    traces: list[Tensor],
    target_counts: Tensor,
    bank_groups: list[Tensor],
    bank_classes: Tensor,
    anchor_embeddings: Tensor | None = None,
) -> Tensor:
    """OT multiset loss from a final-LaTeX teacher and current proposed groups."""
    logits, _, _ = model.formula_retrieval_logits(traces, bank_groups, bank_classes, anchor_embeddings)
    return sinkhorn_multiset_loss(logits.unsqueeze(0), target_counts.unsqueeze(0).to(logits.device))


def weak_class_presence_loss(group_class_logits: Tensor, class_index: int) -> Tensor:
    """Require an ``A_c`` candidate among groups ranked against all anchors.

    ``group_class_logits`` is obtained by comparing every proposed group to
    the complete direct-anchor bank.  The selected class is therefore the
    positive candidate set ``A_c`` and every other column is the complement
    candidate set ``A \\ A_c``.  This is a multiple-instance presence
    objective: the formula teacher says the class occurs somewhere, but never
    fabricates which stroke group it is.  The formula multiset loss allocates
    the remaining target symbols over the complement candidates.
    """
    if group_class_logits.ndim != 2 or group_class_logits.shape[1] != 229:
        raise ValueError("group_class_logits must be [group,229]")
    if not 0 <= class_index < 229:
        raise ValueError("class_index must be in [0,229)")
    probabilities = torch.softmax(group_class_logits, dim=1)[:, class_index]
    epsilon = torch.finfo(probabilities.dtype).eps
    log_none = torch.log1p(-probabilities.clamp(max=1 - epsilon)).sum()
    return -torch.log((-torch.expm1(log_none)).clamp_min(epsilon))
