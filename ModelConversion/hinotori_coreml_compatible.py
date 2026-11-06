"""Fixed-shape Core ML views of the trained Hinotori retrieval model.

This module does not introduce a replacement recognizer.  It exposes the two
continuous computations already used by :class:`HinotoriRetrievalModel`:

* singleton-stroke embeddings followed by ``StrokePairAffinity``; and
* one decoded symbol group's embedding followed by class-wise retrieval
  against the complete direct-anchor bank.

``decode_groups`` remains outside Core ML because it is deliberately a
deterministic, discrete connected-components operation over the learned
affinity decision boundary.  The iOS caller must perform that exact operation
before passing each resulting group to ``HinotoriRetrievalCoreML``.
"""
from __future__ import annotations

import torch
from torch import Tensor, nn
from torch.nn import functional as F

try:
    from ModelConversion.hinotori_model import HinotoriRetrievalModel
except ImportError:
    from hinotori_model import HinotoriRetrievalModel


HINOTORI_CLASS_COUNT = 229


def _single_layer_gru(inputs: Tensor, model: HinotoriRetrievalModel) -> Tensor:
    """Spell out the checkpoint's one-layer GRU with its original tensors.

    ``coremltools`` cannot lower an exported ``aten::gru`` node.  This is the
    documented PyTorch GRU recurrence (reset, update, new gate ordering), not
    a substitute network or a re-trained approximation.
    """
    gru = model.encoder.stroke_encoder
    if gru.num_layers != 1 or gru.bidirectional or not gru.batch_first:
        raise ValueError("Hinotori Core ML contract requires the trained one-layer batch-first GRU")
    hidden = torch.zeros((inputs.shape[0], gru.hidden_size), dtype=inputs.dtype, device=inputs.device)
    sequence: list[Tensor] = []
    for index in range(inputs.shape[1]):
        input_gates = F.linear(inputs[:, index], gru.weight_ih_l0, gru.bias_ih_l0)
        hidden_gates = F.linear(hidden, gru.weight_hh_l0, gru.bias_hh_l0)
        input_reset, input_update, input_new = input_gates.chunk(3, dim=1)
        hidden_reset, hidden_update, hidden_new = hidden_gates.chunk(3, dim=1)
        reset = torch.sigmoid(input_reset + hidden_reset)
        update = torch.sigmoid(input_update + hidden_update)
        candidate = torch.tanh(input_new + reset * hidden_new)
        hidden = candidate + update * (hidden - candidate)
        sequence.append(hidden)
    return torch.stack(sequence, dim=1)


def _encode_fixed_groups(model: HinotoriRetrievalModel, points: Tensor, stroke_valid: Tensor) -> Tensor:
    """Run the existing encoder math without Python-side input validation.

    ``TrajectoryGroupEncoder.forward`` intentionally has data-dependent input
    contract checks for training.  Those checks are not exportable.  This is
    the same tensor computation after those checks; callers must validate the
    published Core ML input contract before model invocation.
    """
    if points.ndim != 4 or points.shape[-2:] != (model.point_count, 2):
        raise ValueError("points must be [group,stroke,pointCount,2]")
    if stroke_valid.shape != points.shape[:2]:
        raise ValueError("stroke_valid must be [group,stroke]")
    padding = stroke_valid < 0.5
    point_padding = padding.unsqueeze(-1).expand(-1, -1, model.point_count)
    encoded_points = model.encoder.point_encoder(points)
    encoded_points = encoded_points.masked_fill(point_padding.unsqueeze(-1), float("-inf"))
    stroke_vectors = encoded_points.amax(dim=2)
    stroke_vectors = stroke_vectors.masked_fill(padding.unsqueeze(-1), 0.0)
    sequence = _single_layer_gru(stroke_vectors, model)
    final_index = (~padding).sum(dim=1) - 1
    return F.normalize(model.encoder.output(sequence[torch.arange(points.shape[0], device=points.device), final_index]), p=2, dim=-1)


class HinotoriAffinityCoreML(nn.Module):
    """Exact fixed-shape singleton affinity portion of Hinotori retrieval."""

    def __init__(self, model: HinotoriRetrievalModel):
        super().__init__()
        self.model = model

    def forward(self, trace_points: Tensor, trace_valid: Tensor) -> tuple[Tensor, Tensor]:
        """Return ``(affinityLogits, strokeEmbeddings)`` for padded traces.

        ``trace_points`` is ``[1,maxFormulaStrokes,32,2]`` and
        ``trace_valid`` is float32 ``[1,maxFormulaStrokes]`` containing only
        0 or 1.  Each valid formula trace is one existing encoder group.
        """
        if trace_points.shape[0] != 1:
            raise ValueError("affinity Core ML contract accepts exactly one formula")
        trace_count = trace_points.shape[1]
        singleton_points = trace_points.reshape(trace_count, 1, self.model.point_count, 2)
        # The encoder correctly rejects an empty group.  Core ML nevertheless
        # evaluates every fixed tensor slot, including padded trace slots.  A
        # padded slot is encoded as a harmless zero singleton and is then
        # removed by the exact affinity padding mask below; it cannot create
        # an edge or influence a valid trace.
        singleton_valid = torch.ones((trace_count, 1), dtype=trace_valid.dtype, device=trace_valid.device)
        embeddings = _encode_fixed_groups(self.model, singleton_points, singleton_valid)
        projected = self.model.group_proposer.projection(embeddings)
        logits = projected @ projected.transpose(0, 1)
        logits = (logits + logits.transpose(0, 1)) / 2
        valid_pairs = (trace_valid.transpose(0, 1) * trace_valid) > 0.5
        return torch.where(valid_pairs, logits, torch.full_like(logits, float("-inf"))), embeddings


class HinotoriRetrievalCoreML(nn.Module):
    """Exact fixed-shape group-to-229-class retrieval against a fixed bank."""

    def __init__(self, model: HinotoriRetrievalModel, anchor_classes: Tensor):
        super().__init__()
        if anchor_classes.ndim != 1 or anchor_classes.numel() < HINOTORI_CLASS_COUNT:
            raise ValueError("anchor_classes must contain one entry for every anchor")
        if anchor_classes.dtype not in (torch.int32, torch.int64):
            raise ValueError("anchor_classes must be integer")
        observed = torch.bincount(anchor_classes.to(torch.int64), minlength=HINOTORI_CLASS_COUNT)
        if observed.numel() != HINOTORI_CLASS_COUNT or (observed == 0).any() or (anchor_classes < 0).any() or (anchor_classes >= HINOTORI_CLASS_COUNT).any():
            raise ValueError("anchor_classes must cover exactly all Hinotori classes")
        self.model = model
        membership = F.one_hot(anchor_classes.to(torch.int64), HINOTORI_CLASS_COUNT).to(torch.bool)
        self.register_buffer("anchor_class_membership", membership, persistent=True)
        self.register_buffer("anchor_class_logit_mask", torch.where(membership.unsqueeze(0), torch.zeros((1, 1, 1)), torch.full((1, 1, 1), float("-inf"))), persistent=True)

    def forward(self, query_points: Tensor, query_stroke_valid: Tensor, anchor_points: Tensor, anchor_stroke_valid: Tensor) -> tuple[Tensor, Tensor, Tensor]:
        """Return ``(classLogits, queryEmbedding, anchorEmbeddings)``.

        All tensors are float32.  The first dimension is one query for
        ``query_*`` and the complete fixed direct-anchor count for
        ``anchor_*``.  ``anchor_class_membership`` is immutable model state;
        callers cannot substitute a different label mapping at inference.
        """
        if query_points.shape[0] != 1 or anchor_points.shape[0] != self.anchor_class_membership.shape[0]:
            raise ValueError("query batch must be one and anchor count must match the exported bank")
        query = _encode_fixed_groups(self.model, query_points, query_stroke_valid)
        anchors = _encode_fixed_groups(self.model, anchor_points, anchor_stroke_valid)
        similarity = F.normalize(query, p=2, dim=1) @ F.normalize(anchors, p=2, dim=1).transpose(0, 1)
        masked = (similarity / self.model.temperature).unsqueeze(-1) + self.anchor_class_logit_mask
        logits = torch.logsumexp(masked, dim=1)
        return logits, query, anchors
