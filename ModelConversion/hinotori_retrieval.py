"""The retrieval head for the Hinotori classifier.

It converts normalized trajectory embeddings and labelled direct examples into
class probabilities by class-wise log-sum-exp cosine retrieval.  There is no
trainable 229-way output layer in this module.
"""
from __future__ import annotations

import torch
from torch import Tensor
from torch.nn import functional as F


def normalized_embeddings(values: Tensor) -> Tensor:
    if values.ndim != 2:
        raise ValueError(f"embeddings must be [item,dimension], got {tuple(values.shape)}")
    if not torch.isfinite(values).all():
        raise ValueError("embeddings contain non-finite values")
    norms = values.norm(dim=1, keepdim=True)
    if (norms == 0).any():
        raise ValueError("embeddings contain a zero vector")
    return F.normalize(values, p=2, dim=1)


def class_retrieval_logits(query: Tensor, anchors: Tensor, anchor_classes: Tensor, class_count: int, temperature: float) -> Tensor:
    """Return [query, class] logits from labelled exemplar similarity.

    Every class must have at least one anchor.  Missing-class smoothing would
    invent a candidate and is therefore forbidden.
    """
    if query.ndim != 2 or anchors.ndim != 2 or query.shape[1] != anchors.shape[1]:
        raise ValueError("query and anchors must be compatible [item,dimension] tensors")
    if anchor_classes.ndim != 1 or anchor_classes.shape[0] != anchors.shape[0]:
        raise ValueError("anchor_classes must have one class per anchor")
    if class_count != 229:
        raise ValueError(f"Hinotori requires exactly 229 classes, got {class_count}")
    if temperature <= 0:
        raise ValueError("temperature must be positive")
    if (anchor_classes < 0).any() or (anchor_classes >= class_count).any():
        raise ValueError("anchor class outside vocabulary")
    observed = torch.bincount(anchor_classes, minlength=class_count)
    if (observed == 0).any():
        missing = (observed == 0).nonzero(as_tuple=False).flatten().tolist()
        raise ValueError(f"retrieval bank has no anchors for classes {missing}")
    similarity = normalized_embeddings(query) @ normalized_embeddings(anchors).transpose(0, 1)
    logits = torch.full((query.shape[0], class_count), float("-inf"), dtype=similarity.dtype, device=similarity.device)
    for class_index in range(class_count):
        logits[:, class_index] = torch.logsumexp(similarity[:, anchor_classes == class_index] / temperature, dim=1)
    return logits


def top_candidates(query: Tensor, anchors: Tensor, anchor_classes: Tensor, class_count: int, temperature: float, top_k: int = 5) -> tuple[Tensor, Tensor]:
    if top_k < 1 or top_k > class_count:
        raise ValueError(f"invalid top_k {top_k}")
    probabilities = torch.softmax(class_retrieval_logits(query, anchors, anchor_classes, class_count, temperature), dim=1)
    return probabilities.topk(top_k, dim=1)
