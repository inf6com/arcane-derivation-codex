"""Core-ML-lowerable evaluation of the trained whole-formula Transformer.

PyTorch's Transformer modules are used during training.  This module keeps
their exact weights but spells out attention and layer operations as tensor
math so that the exported graph has no framework-specific attention operator
or dynamic causal-mask detection.  It is not a second model: callers must
load a ``FormulaWholeModel`` checkpoint first, then pass that model here.
"""
from __future__ import annotations

import math
import torch
from torch import Tensor, nn
from torch.nn import functional as F

try:
    from ModelConversion.formula_whole_model import MAX_LABEL_TOKENS, MAX_TRACES, POINTS_PER_TRACE, TRACE_GEOMETRY_FEATURE_DIMENSION, FormulaWholeModel
except ImportError:
    from formula_whole_model import MAX_LABEL_TOKENS, MAX_TRACES, POINTS_PER_TRACE, TRACE_GEOMETRY_FEATURE_DIMENSION, FormulaWholeModel


def attention(query: Tensor, key: Tensor, value: Tensor, module: nn.MultiheadAttention, key_invalid: Tensor | None, causal: bool) -> Tensor:
    """Batch-first MultiheadAttention using the original packed projections."""
    batch, query_length, width = query.shape
    key_length = key.shape[1]
    heads = module.num_heads
    head_width = width // heads
    q_weight, k_weight, v_weight = module.in_proj_weight.chunk(3, dim=0)
    q_bias, k_bias, v_bias = module.in_proj_bias.chunk(3, dim=0)
    q = F.linear(query, q_weight, q_bias)
    k = F.linear(key, k_weight, k_bias)
    v = F.linear(value, v_weight, v_bias)
    q = q.reshape(batch, query_length, heads, head_width).transpose(1, 2)
    k = k.reshape(batch, key_length, heads, head_width).transpose(1, 2)
    v = v.reshape(batch, key_length, heads, head_width).transpose(1, 2)
    scores = torch.matmul(q, k.transpose(-2, -1)) / math.sqrt(head_width)
    if key_invalid is not None:
        scores = scores.masked_fill(key_invalid[:, None, None, :], float("-inf"))
    if causal:
        causal_invalid = torch.triu(torch.ones(query_length, key_length, dtype=torch.bool, device=query.device), diagonal=1)
        scores = scores.masked_fill(causal_invalid[None, None], float("-inf"))
    weights = torch.softmax(scores, dim=-1)
    context = torch.matmul(weights, v).transpose(1, 2).reshape(batch, query_length, width)
    return F.linear(context, module.out_proj.weight, module.out_proj.bias)


def encoder_layer(x: Tensor, layer: nn.TransformerEncoderLayer, padding: Tensor | None) -> Tensor:
    x = layer.norm1(x + attention(x, x, x, layer.self_attn, padding, False))
    feed_forward = F.linear(F.relu(F.linear(x, layer.linear1.weight, layer.linear1.bias)), layer.linear2.weight, layer.linear2.bias)
    return layer.norm2(x + feed_forward)


def decoder_layer(x: Tensor, memory: Tensor, layer: nn.TransformerDecoderLayer, target_padding: Tensor, memory_padding: Tensor) -> Tensor:
    x = layer.norm1(x + attention(x, x, x, layer.self_attn, target_padding, True))
    x = layer.norm2(x + attention(x, memory, memory, layer.multihead_attn, memory_padding, False))
    feed_forward = F.linear(F.relu(F.linear(x, layer.linear1.weight, layer.linear1.bias)), layer.linear2.weight, layer.linear2.bias)
    return layer.norm3(x + feed_forward)


class FixedFormulaWholeCoreML(nn.Module):
    """Fixed [1,80,128,2] plus [1,80,9] v4 realization of FormulaWholeModel."""
    def __init__(self, model: FormulaWholeModel):
        super().__init__()
        self.model = model

    def forward(self, traces: Tensor, trace_geometry: Tensor, trace_valid: Tensor, target_tokens: Tensor, token_valid: Tensor) -> Tensor:
        trace_padding = trace_valid < 0.5
        token_padding = token_valid < 0.5
        flat = traces.reshape(MAX_TRACES, POINTS_PER_TRACE, 2)
        points = F.linear(flat, self.model.encoder.point_projection.weight, self.model.encoder.point_projection.bias)
        cls = self.model.encoder.trace_cls.expand(MAX_TRACES, -1, -1)
        points = torch.cat((cls, points), dim=1) + self.model.encoder.point_positions[: POINTS_PER_TRACE + 1].unsqueeze(0)
        for layer in self.model.encoder.point_encoder.layers:
            points = encoder_layer(points, layer, None)
        memory = points[:, 0, :].reshape(1, MAX_TRACES, self.model.encoder.d_model)
        memory = memory + F.linear(
            trace_geometry,
            self.model.encoder.trace_geometry_projection.weight,
            self.model.encoder.trace_geometry_projection.bias,
        )
        memory = memory + self.model.encoder.trace_positions[:MAX_TRACES].unsqueeze(0)
        for layer in self.model.encoder.trace_encoder.layers:
            memory = encoder_layer(memory, layer, trace_padding)
        target = self.model.decoder.token_embedding(target_tokens) + self.model.decoder.token_positions[:MAX_LABEL_TOKENS].unsqueeze(0)
        for layer in self.model.decoder.decoder.layers:
            target = decoder_layer(target, memory, layer, token_padding, trace_padding)
        return F.linear(target, self.model.decoder.output_projection.weight, self.model.decoder.output_projection.bias)
