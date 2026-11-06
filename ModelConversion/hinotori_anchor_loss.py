"""Metric supervision from direct Hinotori annotations.

Direct annotations teach retrieval geometry: a query group should be nearer to
anchors with its observed class than to anchors of different classes.  This is
not a fixed 229-way output layer.
"""
from __future__ import annotations

import torch
from torch import Tensor


def direct_anchor_metric_loss(
    query_embeddings: Tensor,
    query_classes: Tensor,
    anchor_embeddings: Tensor,
    anchor_classes: Tensor,
    temperature: float = 0.07,
) -> Tensor:
    """Supervised contrastive loss against an annotated anchor batch."""
    if query_embeddings.ndim != 2 or anchor_embeddings.ndim != 2:
        raise ValueError("query_embeddings and anchor_embeddings must be matrices")
    if query_embeddings.shape[1] != anchor_embeddings.shape[1]:
        raise ValueError("query and anchor embedding dimensions must match")
    if query_classes.shape != (query_embeddings.shape[0],) or anchor_classes.shape != (anchor_embeddings.shape[0],):
        raise ValueError("class tensors must match their embedding rows")
    if query_classes.dtype != torch.int64 or anchor_classes.dtype != torch.int64:
        raise ValueError("class tensors must be int64")
    if temperature <= 0:
        raise ValueError("temperature must be positive")
    if ((query_classes < 0) | (query_classes >= 229)).any() or ((anchor_classes < 0) | (anchor_classes >= 229)).any():
        raise ValueError("class ids must be in [0, 229)")
    queries = torch.nn.functional.normalize(query_embeddings, p=2, dim=1)
    anchors = torch.nn.functional.normalize(anchor_embeddings, p=2, dim=1)
    logits = queries @ anchors.transpose(0, 1) / temperature
    positive = query_classes.unsqueeze(1) == anchor_classes.unsqueeze(0)
    if (~positive.any(dim=1)).any():
        raise ValueError("every query needs an anchor of the same class")
    return -(torch.logsumexp(logits.masked_fill(~positive, float("-inf")), dim=1) - torch.logsumexp(logits, dim=1)).mean()
