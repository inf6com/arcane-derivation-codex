#!/usr/bin/env python3
"""Whole-formula sequence-to-sequence recognizer.

Architecture: FormulaInput v1 -> per-trace point encoder (fixed-length via
arc-length resampling, so no intra-trace padding is needed) -> trace-level
Transformer encoder (order-preserving) -> autoregressive Transformer decoder
over the shared 93-token lossless character vocabulary
(``formula-whole-label-tokenizer-20260927.json``).

This does not group strokes, assign 3x3 cells, or classify individual
glyphs: per HandwrittenFormulaRecognitionDesign.md, segmentation, order, and
structure (superscript/subscript, fractions, ...) are learned end to end
from (FormulaInput, normalizedLabel) pairs only.

Hyperparameters marked "PROVISIONAL" below are not backed by an ablation on
real data yet (this cloud sandbox has no GPU and no full local copy of the
dataset). They are chosen from measured, real dataset statistics
(``runs/agent-control/formula-feature-contract-audit-20260927.json``:
avg 12.4 traces/formula, p99 29, avg 28.0 points/trace) to be *plausible*,
not to be treated as final. Task: sweep POINTS_PER_TRACE and d_model once
real training is possible, the same way POINTS_PER_STROKE=12 was picked by
measurement for the (now-retired) per-glyph classifier.
"""
from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from pathlib import Path

import torch
from torch import nn, Tensor


# --- Shared vocabulary -------------------------------------------------

def load_tokenizer(path: Path) -> "FormulaTokenizer":
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("format") not in {"inf6-formula-whole-label-tokenizer-v1", "inf6-formula-whole-structure-tokenizer-v1"}:
        raise ValueError(f"unexpected tokenizer format: {data.get('format')!r}")
    return FormulaTokenizer(
        tokens=data["tokens"],
        token_to_id=data["tokenToID"],
        tokenization="structure" if data.get("format") == "inf6-formula-whole-structure-tokenizer-v1" else "character",
    )


STRUCTURE_TOKEN_RE = re.compile(r"\\[A-Za-z]+|\\\\|\\.|.", re.DOTALL)


def tokenize_structure(label: str) -> list[str]:
    pieces = STRUCTURE_TOKEN_RE.findall(label)
    if "".join(pieces) != label:
        raise ValueError("structure tokenizer failed lossless coverage")
    return pieces


@dataclass(frozen=True)
class FormulaTokenizer:
    tokens: list[str]
    token_to_id: dict[str, int]
    tokenization: str = "character"

    @property
    def vocab_size(self) -> int:
        return len(self.tokens)

    @property
    def pad_id(self) -> int:
        return self.token_to_id["<pad>"]

    @property
    def bos_id(self) -> int:
        return self.token_to_id["<bos>"]

    @property
    def eos_id(self) -> int:
        return self.token_to_id["<eos>"]

    @property
    def unk_id(self) -> int:
        return self.token_to_id["<unk>"]

    def encode(self, label: str) -> list[int]:
        # No unknown-token substitution: OOV is an error, not a silent <unk>.
        pieces = tokenize_structure(label) if self.tokenization == "structure" else list(label)
        try:
            body = [self.token_to_id[piece] for piece in pieces]
        except KeyError as error:
            raise ValueError(f"label contains a character outside the train vocabulary: {error}") from error
        return [self.bos_id, *body, self.eos_id]

    def decode(self, token_ids: list[int]) -> str:
        characters = []
        for token_id in token_ids:
            if token_id in (self.bos_id, self.eos_id, self.pad_id):
                continue
            characters.append(self.tokens[token_id])
        return "".join(characters)


def syntax_allowed_mask(prefix_token_ids: torch.Tensor, tokenizer: FormulaTokenizer) -> torch.Tensor:
    """Return legal next-character masks for teacher-forced or generated prefixes.

    The whole-formula target is a character stream, so structural validity must
    be enforced at the same boundary at which characters are predicted.  This
    mask encodes syntax that is observable without inventing a general LaTeX
    parser: balanced curly-brace groups, the measured ``matrix`` environment
    token sequence, a required character after ``^`` or ``_``, and EOS only
    after all groups and environments are closed.  Parentheses and
    square brackets are visual LaTeX symbols and may legally cross a curly
    group boundary, so they are not treated as one shared delimiter stack.
    Unknown/BOS tokens are never valid predictions.  An invalid prefix is a
    hard model/data error; it is not repaired or silently accepted.
    """
    if prefix_token_ids.ndim != 2:
        raise ValueError(f"prefix_token_ids must be rank-2, got {tuple(prefix_token_ids.shape)}")
    device = prefix_token_ids.device
    batch, length = prefix_token_ids.shape
    mask = torch.zeros(batch, length, tokenizer.vocab_size, dtype=torch.bool, device=device)
    opening = {"{": "}"}
    closing = {"}": "{"}
    token_text = tokenizer.tokens
    for row_index, row in enumerate(prefix_token_ids.tolist()):
        stack: list[str] = []
        pending_script = False
        environment_stack: list[str] = []
        pending_environment: list[str] | None = None
        pending_environment_command: str | None = None
        pending_escape = False
        ended = False
        for position, token_id in enumerate(row):
            if token_id == tokenizer.pad_id:
                if not ended:
                    raise ValueError(f"padding before EOS in prefix row {row_index} at position {position}")
                mask[row_index, position, tokenizer.pad_id] = True
                continue
            if token_id == tokenizer.eos_id:
                if stack or pending_script or pending_escape:
                    raise ValueError(f"EOS before structural closure in prefix row {row_index} at position {position}")
                ended = True
                mask[row_index, position, tokenizer.pad_id] = True
                continue
            if ended:
                raise ValueError(f"token after EOS in prefix row {row_index} at position {position}")
            if token_id in (tokenizer.bos_id, tokenizer.unk_id):
                if token_id == tokenizer.bos_id and position == 0:
                    legal = torch.ones(tokenizer.vocab_size, dtype=torch.bool, device=device)
                    legal[tokenizer.pad_id] = False
                    legal[tokenizer.bos_id] = False
                    legal[tokenizer.unk_id] = False
                    # MathWriting labels are non-empty formulas.  EOS is only
                    # legal after at least one formula token, so the training
                    # and greedy-decoding masks share the same boundary.
                    for token_index, next_character in enumerate(token_text):
                        if next_character in closing:
                            legal[token_index] = False
                        if next_character == "\\end":
                            legal[token_index] = False
                    legal[tokenizer.eos_id] = False
                    mask[row_index, position] = legal
                    continue
                raise ValueError(f"invalid special token {token_id} in prefix row {row_index} at position {position}")
            character = token_text[token_id]
            escaped_character = pending_escape
            pending_escape = character == "\\" and not escaped_character
            if pending_environment is not None:
                expected_character = pending_environment.pop(0)
                if character != expected_character:
                    raise ValueError(
                        f"invalid environment token in prefix row {row_index} at position {position}: "
                        f"expected {expected_character!r}, got {character!r}"
                    )
                if not pending_environment:
                    if pending_environment_command == "\\begin":
                        environment_stack.append("matrix")
                    elif not environment_stack or environment_stack.pop() != "matrix":
                        raise ValueError(f"matrix environment closes without a matching begin in prefix row {row_index}")
                    pending_environment = None
                    pending_environment_command = None
            elif character == "\\begin":
                pending_environment = list("{matrix}")
                pending_environment_command = character
            elif character == "\\end":
                if not environment_stack:
                    raise ValueError(f"matrix environment ends without a matching begin in prefix row {row_index}")
                pending_environment = list("{matrix}")
                pending_environment_command = character
            if not escaped_character and character in closing:
                if not stack or stack[-1] != closing[character]:
                    raise ValueError(f"unbalanced delimiter prefix row {row_index} at position {position}")
                stack.pop()
            elif not escaped_character and character in opening:
                stack.append(character)
            if not escaped_character and character in "^_":
                if pending_script:
                    raise ValueError(f"consecutive script markers in prefix row {row_index} at position {position}")
                pending_script = True
            elif pending_script:
                if character in closing:
                    raise ValueError(f"script marker closes before an operand in prefix row {row_index} at position {position}")
                pending_script = False

            legal = torch.ones(tokenizer.vocab_size, dtype=torch.bool, device=device)
            legal[tokenizer.pad_id] = False
            legal[tokenizer.bos_id] = False
            legal[tokenizer.unk_id] = False
            for token_index, next_character in enumerate(token_text):
                if next_character in closing and character != "\\" and (not stack or stack[-1] != closing[next_character]):
                    legal[token_index] = False
                if pending_script and next_character in closing:
                    legal[token_index] = False
                if pending_script and next_character in "^_":
                    legal[token_index] = False
                if pending_environment is not None:
                    legal[token_index] = next_character == pending_environment[0]
                elif next_character == "\\end" and not environment_stack:
                    legal[token_index] = False
                elif next_character == "\\begin" and environment_stack:
                    legal[token_index] = False
            legal[tokenizer.eos_id] = not stack and not pending_script and not pending_escape and not environment_stack and pending_environment is None
            mask[row_index, position] = legal
        if ended:
            mask[row_index, -1, tokenizer.pad_id] = True
    return mask


# --- FormulaInput v1 trace resampling -----------------------------------

# The all-data feature-loss audit shows that 128 points halves the remaining
# nearest-sampled-point error of the former 64-point contract on both train
# and valid.  This is a new input contract: no checkpoint from either earlier
# contract is compatible with it.
MODEL_INPUT_CONTRACT_VERSION = "inf6-formula-whole-trace-v4-128pt-geometry9"
POINTS_PER_TRACE = 128
TRACE_GEOMETRY_FEATURE_DIMENSION = 9

# Measured train maximum is 80 traces in the cycle238 full-dataset audit.
# The limit therefore covers every measured train example. If a future input
# exceeds it, the loader raises rather than silently truncating a stroke.
MAX_TRACES = 80

MAX_LABEL_TOKENS = 192  # measured max sequence length (train) is 190 incl. BOS/EOS.


class TooManyTracesError(ValueError):
    pass


def model_input_contract() -> dict[str, object]:
    """Return the complete fixed tensor contract required by a checkpoint."""
    return {
        "version": MODEL_INPUT_CONTRACT_VERSION,
        "dtype": "float32",
        "shape": f"[trace,{POINTS_PER_TRACE},2]",
        "pointsPerTrace": POINTS_PER_TRACE,
        "featureDimension": 2,
        "traceGeometryShape": f"[trace,{TRACE_GEOMETRY_FEATURE_DIMENSION}]",
        "traceGeometryFeatureDimension": TRACE_GEOMETRY_FEATURE_DIMENSION,
        "traceGeometryFeatures": ["minX", "minY", "maxX", "maxY", "centroidX", "centroidY", "extentX", "extentY", "traceWriteProgress"],
        "maxTraces": MAX_TRACES,
        "normalization": "isotropic-bounds-to-[0,1]-square-with-centered-padding",
    }


def require_checkpoint_input_contract(checkpoint: Path) -> dict[str, object]:
    """Reject a checkpoint without an exact persisted input-contract record."""
    contract_path = checkpoint.parent / "checkpoint-contract.json"
    if not contract_path.is_file():
        raise ValueError(
            f"checkpoint has no input-contract record: {contract_path}; "
            "a checkpoint from an earlier point-count contract cannot be resumed or evaluated as v3-128pt"
        )
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read checkpoint input-contract record {contract_path}: {error}") from error
    expected = model_input_contract()
    actual = contract.get("inputContract")
    if actual != expected:
        raise ValueError(
            f"checkpoint input contract mismatch: expected {expected!r}, got {actual!r}; "
            "cross-contract model reuse is forbidden"
        )
    return contract


def verify_execution_device(requested_device: str, *, cpu_comparison: bool = False) -> dict[str, object]:
    """Enforce MPS-first execution, except for an explicitly labelled CPU control."""
    mps_built = torch.backends.mps.is_built()
    mps_available = torch.backends.mps.is_available()
    evidence = {
        "requestedDevice": requested_device,
        "mpsBuilt": mps_built,
        "mpsAvailable": mps_available,
        "cpuComparison": cpu_comparison,
    }
    if requested_device == "mps" and not mps_available:
        raise RuntimeError(f"MPS was requested but is unavailable: {evidence!r}")
    if requested_device == "cpu" and mps_available and not cpu_comparison:
        raise RuntimeError(f"CPU execution is forbidden while MPS is available: {evidence!r}")
    if cpu_comparison and requested_device != "cpu":
        raise ValueError(f"cpu_comparison requires requested_device='cpu': {evidence!r}")
    if requested_device not in {"mps", "cpu", "cuda"}:
        raise ValueError(f"unsupported execution device: {requested_device!r}")
    return evidence


def resample_trace(points: list[tuple[float, float]], count: int = POINTS_PER_TRACE) -> list[tuple[float, float]]:
    """Arc-length resampling to a fixed point count.

    Identical tie rule to the retired per-glyph feature extractor
    (``Inf6GlyphFeatures.resample`` / the training-side reference): equal
    arc-length spacing, endpoints included, "first index where cumulative
    distance >= target". A single-point trace repeats that point, matching
    PencilKit's degenerate case (a tap) rather than raising.
    """
    if len(points) == 1:
        return [points[0]] * count
    dist = [0.0]
    for i in range(1, len(points)):
        (x0, y0), (x1, y1) = points[i - 1], points[i]
        dist.append(dist[-1] + math.hypot(x1 - x0, y1 - y0))
    total = dist[-1]
    if total <= 0:
        return [points[0]] * count
    out: list[tuple[float, float]] = []
    for i in range(count):
        target = total * i / (count - 1)
        upper = next((j for j, d in enumerate(dist) if d >= target), len(dist) - 1)
        if upper == 0:
            out.append(points[0])
            continue
        lower = upper - 1
        span = dist[upper] - dist[lower]
        ratio = (target - dist[lower]) / span if span > 0 else 0.0
        x0, y0 = points[lower]
        x1, y1 = points[upper]
        out.append((x0 + (x1 - x0) * ratio, y0 + (y1 - y0) * ratio))
    return out


def prepare_traces(traces: list[list[tuple[float, float]]]) -> Tensor:
    """`[T, POINTS_PER_TRACE, 2]` float32, trace order preserved, T <= MAX_TRACES."""
    if len(traces) > MAX_TRACES:
        raise TooManyTracesError(f"{len(traces)} traces exceeds MAX_TRACES={MAX_TRACES}; not silently truncating")
    resampled = [resample_trace(trace) for trace in traces]
    return torch.tensor(resampled, dtype=torch.float32)


def prepare_trace_geometry(geometry: list[tuple[float, ...]]) -> Tensor:
    """`[T, 9]` float32 v4 side tensor, aligned to the trace tensor axis."""
    if len(geometry) > MAX_TRACES:
        raise TooManyTracesError(f"{len(geometry)} geometry traces exceeds MAX_TRACES={MAX_TRACES}; not silently truncating")
    if not geometry:
        raise ValueError("trace geometry cannot be empty")
    if any(len(features) != TRACE_GEOMETRY_FEATURE_DIMENSION for features in geometry):
        raise ValueError(f"trace geometry requires {TRACE_GEOMETRY_FEATURE_DIMENSION} features per trace")
    tensor = torch.tensor(geometry, dtype=torch.float32)
    if not torch.isfinite(tensor).all() or not bool(((tensor >= 0) & (tensor <= 1)).all()):
        raise ValueError("trace geometry must be finite and normalized to [0,1]")
    return tensor


# --- Model ---------------------------------------------------------------

def sinusoidal_positions(length: int, d_model: int) -> Tensor:
    position = torch.arange(length, dtype=torch.float32).unsqueeze(1)
    div_term = torch.exp(torch.arange(0, d_model, 2, dtype=torch.float32) * (-math.log(10000.0) / d_model))
    pe = torch.zeros(length, d_model)
    pe[:, 0::2] = torch.sin(position * div_term)
    pe[:, 1::2] = torch.cos(position * div_term)
    return pe


class TraceEncoder(nn.Module):
    """Per-trace point encoder (fixed length, no intra-trace padding needed
    because `resample_trace` already fixes the length) followed by a
    trace-level Transformer encoder over the ordered traces of one formula.

    A learned [TRACE] token is prepended to each trace's point sequence and
    its output pooled as that trace's embedding, mirroring standard
    CLS-token pooling rather than mean pooling, which handles the
    resampled point sequence unevenly if intermediate points are
    interpolated (mean pooling would over-weight straight segments).
    """

    def __init__(self, d_model: int = 128, point_layers: int = 2, trace_layers: int = 2, heads: int = 4, dim_feedforward: int = 256, dropout: float = 0.1):
        super().__init__()
        self.d_model = d_model
        self.point_projection = nn.Linear(2, d_model)
        self.trace_geometry_projection = nn.Linear(TRACE_GEOMETRY_FEATURE_DIMENSION, d_model)
        self.trace_cls = nn.Parameter(torch.zeros(1, 1, d_model))
        self.register_buffer("point_positions", sinusoidal_positions(POINTS_PER_TRACE + 1, d_model), persistent=False)
        point_encoder_layer = nn.TransformerEncoderLayer(
            d_model=d_model, nhead=heads, dim_feedforward=dim_feedforward, dropout=dropout, batch_first=True
        )
        self.point_encoder = nn.TransformerEncoder(point_encoder_layer, num_layers=point_layers)

        self.register_buffer("trace_positions", sinusoidal_positions(MAX_TRACES, d_model), persistent=False)
        trace_encoder_layer = nn.TransformerEncoderLayer(
            d_model=d_model, nhead=heads, dim_feedforward=dim_feedforward, dropout=dropout, batch_first=True
        )
        # The trace padding mask is part of the model contract.  PyTorch's
        # nested-tensor conversion is an optional CPU/CUDA optimization, but
        # its mask-alignment operator is not implemented by MPS.  Keep the
        # ordinary masked Transformer path on every device instead of asking
        # PyTorch to fall back to CPU for that operator.
        self.trace_encoder = nn.TransformerEncoder(
            trace_encoder_layer,
            num_layers=trace_layers,
            enable_nested_tensor=False,
        )

    def forward(self, traces: Tensor, trace_geometry: Tensor, trace_padding_mask: Tensor) -> tuple[Tensor, Tensor]:
        """`traces`: `[B,T,POINTS_PER_TRACE,2]`, `trace_geometry`: `[B,T,9]`.

        Returns `(memory, memory_key_padding_mask)`: `memory` is `[B, T, d_model]`.
        """
        batch, num_traces, points_per_trace, _ = traces.shape
        if trace_geometry.shape != (batch, num_traces, TRACE_GEOMETRY_FEATURE_DIMENSION):
            raise ValueError(
                f"trace geometry shape must be [B,T,{TRACE_GEOMETRY_FEATURE_DIMENSION}], got {tuple(trace_geometry.shape)}"
            )
        if trace_padding_mask.shape != (batch, num_traces):
            raise ValueError(f"trace padding mask shape must be [B,T], got {tuple(trace_padding_mask.shape)}")
        flat = traces.reshape(batch * num_traces, points_per_trace, 2)
        projected = self.point_projection(flat)
        cls = self.trace_cls.expand(flat.shape[0], -1, -1)
        with_cls = torch.cat([cls, projected], dim=1)
        with_cls = with_cls + self.point_positions[: with_cls.shape[1]].unsqueeze(0)
        encoded_points = self.point_encoder(with_cls)
        trace_embeddings = encoded_points[:, 0, :]  # [B*T, d_model]
        trace_embeddings = trace_embeddings.reshape(batch, num_traces, self.d_model)
        trace_embeddings = trace_embeddings + self.trace_geometry_projection(trace_geometry)
        trace_embeddings = trace_embeddings + self.trace_positions[:num_traces].unsqueeze(0)
        memory = self.trace_encoder(trace_embeddings, src_key_padding_mask=trace_padding_mask)
        return memory, trace_padding_mask


class SequenceDecoder(nn.Module):
    def __init__(self, vocab_size: int, d_model: int = 128, layers: int = 2, heads: int = 4, dim_feedforward: int = 256, dropout: float = 0.1):
        super().__init__()
        self.d_model = d_model
        self.token_embedding = nn.Embedding(vocab_size, d_model)
        self.register_buffer("token_positions", sinusoidal_positions(MAX_LABEL_TOKENS, d_model), persistent=False)
        decoder_layer = nn.TransformerDecoderLayer(
            d_model=d_model, nhead=heads, dim_feedforward=dim_feedforward, dropout=dropout, batch_first=True
        )
        self.decoder = nn.TransformerDecoder(decoder_layer, num_layers=layers)
        self.output_projection = nn.Linear(d_model, vocab_size)

    def forward(self, target_tokens: Tensor, memory: Tensor, memory_key_padding_mask: Tensor, target_padding_mask: Tensor) -> Tensor:
        """`target_tokens`: `[B, L]` (already shifted right, i.e. starts with <bos>).

        Returns logits `[B, L, vocab_size]`.
        """
        length = target_tokens.shape[1]
        embedded = self.token_embedding(target_tokens) + self.token_positions[:length].unsqueeze(0)
        # Boolean, not the default float(-inf) mask: PyTorch warns (and will
        # eventually reject) mixing a float attn_mask with a bool
        # key_padding_mask in the same call.
        causal_mask = torch.triu(
            torch.ones(length, length, dtype=torch.bool, device=target_tokens.device), diagonal=1
        )
        decoded = self.decoder(
            embedded,
            memory,
            tgt_mask=causal_mask,
            # The caller has constructed the exact upper-triangular causal
            # mask above.  Declaring it avoids PyTorch re-detecting causality
            # by converting a tensor reduction to a Python bool, which makes
            # the otherwise fixed Tensor contract non-exportable.
            tgt_is_causal=True,
            tgt_key_padding_mask=target_padding_mask,
            memory_key_padding_mask=memory_key_padding_mask,
        )
        return self.output_projection(decoded)


class FormulaWholeModel(nn.Module):
    def __init__(self, vocab_size: int, d_model: int = 128, heads: int = 4, dim_feedforward: int = 256, dropout: float = 0.1):
        super().__init__()
        # This is checkpoint identity, not an inference option.  A state dict
        # alone cannot recover these dimensions, so persist them with every
        # newly written checkpoint and require them during evaluation/export.
        self.architecture = {
            "vocabSize": vocab_size,
            "dModel": d_model,
            "heads": heads,
            "dimFeedforward": dim_feedforward,
            "dropout": dropout,
        }
        self.encoder = TraceEncoder(d_model=d_model, heads=heads, dim_feedforward=dim_feedforward, dropout=dropout)
        self.decoder = SequenceDecoder(vocab_size, d_model=d_model, heads=heads, dim_feedforward=dim_feedforward, dropout=dropout)

    def forward(self, traces: Tensor, trace_geometry: Tensor, trace_padding_mask: Tensor, target_input: Tensor, target_padding_mask: Tensor) -> Tensor:
        memory, memory_mask = self.encoder(traces, trace_geometry, trace_padding_mask)
        return self.decoder(target_input, memory, memory_mask, target_padding_mask)

    def syntax_masked_forward(self, traces: Tensor, trace_geometry: Tensor, trace_padding_mask: Tensor, target_input: Tensor, target_padding_mask: Tensor, tokenizer: FormulaTokenizer) -> Tensor:
        logits = self.forward(traces, trace_geometry, trace_padding_mask, target_input, target_padding_mask)
        mask = syntax_allowed_mask(target_input, tokenizer)
        # MPS log_softmax over finfo.min values can underflow every legal
        # token to -inf.  IEEE -inf is the required masked-logit sentinel.
        return logits.masked_fill(~mask, float("-inf"))

    @torch.no_grad()
    def greedy_decode(self, traces: Tensor, trace_geometry: Tensor, trace_padding_mask: Tensor, tokenizer: FormulaTokenizer, max_length: int = MAX_LABEL_TOKENS) -> list[list[int]]:
        self.eval()
        memory, memory_mask = self.encoder(traces, trace_geometry, trace_padding_mask)
        batch = traces.shape[0]
        device = traces.device
        generated = torch.full((batch, 1), tokenizer.bos_id, dtype=torch.long, device=device)
        finished = torch.zeros(batch, dtype=torch.bool, device=device)
        for _ in range(max_length - 1):
            target_padding_mask = torch.zeros_like(generated, dtype=torch.bool)
            logits = self.decoder(generated, memory, memory_mask, target_padding_mask)
            mask = syntax_allowed_mask(generated, tokenizer)
            logits = logits.masked_fill(~mask, float("-inf"))
            next_token = logits[:, -1, :].argmax(dim=-1)
            next_token = torch.where(finished, torch.full_like(next_token, tokenizer.pad_id), next_token)
            generated = torch.cat([generated, next_token.unsqueeze(1)], dim=1)
            finished = finished | (next_token == tokenizer.eos_id)
            if bool(finished.all()):
                break
        return generated.tolist()
