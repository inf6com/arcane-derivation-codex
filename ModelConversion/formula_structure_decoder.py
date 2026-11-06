#!/usr/bin/env python3
"""Formula-level LaTeX/AST teachers without a pooled-raster shortcut.

The decoder contract keeps FormulaRasterV1 spatial encoder locations separate
from separator instance and relation representations.  It deliberately does
not accept a globally pooled raster vector: doing so would reintroduce the
retired direct-LaTeX path.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import torch
from torch import Tensor, nn
from torch.nn import functional as F

from formula_whole_model import FormulaTokenizer, load_tokenizer
from instance_structure_relation import RELATION_TYPES

VISUAL_SPECIAL_TOKENS = ("<pad>", "<bos>", "<eos>")
STRUCTURAL_RELATIONS = tuple(kind for kind in RELATION_TYPES if kind != "none")
STRUCTURAL_RELATION_INDEX = {kind: index for index, kind in enumerate(STRUCTURAL_RELATIONS)}
IGNORE_INDEX = -100


@dataclass(frozen=True)
class VisualVocabulary:
    tokens: tuple[str, ...]
    token_to_id: dict[str, int]

    @property
    def pad_id(self) -> int: return self.token_to_id["<pad>"]
    @property
    def bos_id(self) -> int: return self.token_to_id["<bos>"]
    @property
    def eos_id(self) -> int: return self.token_to_id["<eos>"]
    @property
    def size(self) -> int: return len(self.tokens)

    def encode(self, values: list[str]) -> list[int]:
        try:
            return [self.bos_id, *(self.token_to_id[value] for value in values), self.eos_id]
        except KeyError as error:
            raise ValueError(f"visual token outside train vocabulary: {error.args[0]!r}") from error

    def to_json(self) -> dict[str, Any]:
        return {"format": "inf6-formula-structure-visual-vocabulary-v1", "specialTokens": list(VISUAL_SPECIAL_TOKENS), "tokens": list(self.tokens), "tokenToID": self.token_to_id}


def build_visual_vocabulary(teacher_path: Path) -> VisualVocabulary:
    values: set[str] = set()
    for line in teacher_path.read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        tokens = row.get("visualTokens")
        if not isinstance(tokens, list) or not all(isinstance(value, str) and value for value in tokens):
            raise ValueError(f"{row.get('sampleId')}: visualTokens must be non-empty strings")
        values.update(tokens)
    overlap = values.intersection(VISUAL_SPECIAL_TOKENS)
    if overlap:
        raise ValueError(f"teacher visual token collides with special token: {sorted(overlap)}")
    tokens = (*VISUAL_SPECIAL_TOKENS, *sorted(values))
    return VisualVocabulary(tuple(tokens), {value: index for index, value in enumerate(tokens)})


class FormulaStructureTeacherDataset:
    """Offset-indexed loader for all train-only v7 structure teachers."""
    def __init__(self, teacher_path: Path, latex_tokenizer: FormulaTokenizer, visual_vocabulary: VisualVocabulary) -> None:
        self.teacher_path = teacher_path
        self.latex_tokenizer = latex_tokenizer
        self.visual_vocabulary = visual_vocabulary
        self._offsets: list[int] = []
        self.sample_ids: list[str] = []
        seen: set[str] = set()
        with teacher_path.open("rb") as handle:
            while True:
                offset = handle.tell()
                line = handle.readline()
                if not line:
                    break
                row = self._validate(json.loads(line))
                sample_id = row["sampleId"]
                if sample_id in seen:
                    raise ValueError(f"duplicate formula teacher sampleId: {sample_id}")
                seen.add(sample_id); self._offsets.append(offset); self.sample_ids.append(sample_id)
        if not self._offsets:
            raise ValueError("formula structure teacher file is empty")

    @staticmethod
    def _validate(row: dict[str, Any]) -> dict[str, Any]:
        sample_id, latex, tokens, nodes, relations = (row.get(key) for key in ("sampleId", "latex", "visualTokens", "nodes", "relations"))
        if not isinstance(sample_id, str) or not sample_id or not isinstance(latex, str):
            raise ValueError("formula teacher requires sampleId and latex")
        if not isinstance(tokens, list) or not isinstance(nodes, list) or len(tokens) != len(nodes):
            raise ValueError(f"{sample_id}: visual token/node cardinality mismatch")
        node_ids = [node.get("nodeId") for node in nodes if isinstance(node, dict)]
        if node_ids != list(range(len(nodes))) or [node.get("token") for node in nodes] != tokens:
            raise ValueError(f"{sample_id}: AST nodes must be contiguous and equal visualTokens")
        if not isinstance(relations, list):
            raise ValueError(f"{sample_id}: relations must be a list")
        for relation in relations:
            if not isinstance(relation, list) or len(relation) != 4:
                raise ValueError(f"{sample_id}: malformed relation")
            source, target, kind, _ = relation
            if not isinstance(source, int) or not isinstance(target, int) or not 0 <= source < len(nodes) or not 0 <= target < len(nodes):
                raise ValueError(f"{sample_id}: relation endpoint outside nodes")
            if kind not in STRUCTURAL_RELATION_INDEX:
                raise ValueError(f"{sample_id}: unsupported structural relation {kind!r}")
        return row

    def __len__(self) -> int: return len(self._offsets)

    def __getitem__(self, index: int) -> dict[str, Any]:
        with self.teacher_path.open("rb") as handle:
            handle.seek(self._offsets[index])
            row = self._validate(json.loads(handle.readline()))
        relation_target = torch.zeros((len(row["nodes"]), len(row["nodes"]), len(STRUCTURAL_RELATIONS)), dtype=torch.float32)
        relation_mask = torch.zeros((len(row["nodes"]), len(row["nodes"])), dtype=torch.bool)
        for source, target, kind, _ in row["relations"]:
            relation_target[source, target, STRUCTURAL_RELATION_INDEX[kind]] = 1.0
            relation_mask[source, target] = True
        return {"sampleId": row["sampleId"], "latexIds": torch.tensor(self.latex_tokenizer.encode(row["latex"]), dtype=torch.long), "visualIds": torch.tensor(self.visual_vocabulary.encode(row["visualTokens"]), dtype=torch.long), "relationTarget": relation_target, "relationMask": relation_mask}


def collate_formula_structure(rows: list[dict[str, Any]], latex_pad_id: int, visual_pad_id: int) -> dict[str, Any]:
    if not rows:
        raise ValueError("cannot collate an empty formula batch")
    batch = len(rows); latex_width = max(row["latexIds"].numel() for row in rows); visual_width = max(row["visualIds"].numel() for row in rows)
    latex_ids = torch.full((batch, latex_width), latex_pad_id, dtype=torch.long)
    visual_ids = torch.full((batch, visual_width), visual_pad_id, dtype=torch.long)
    relation_target = torch.zeros((batch, visual_width - 2, visual_width - 2, len(STRUCTURAL_RELATIONS)), dtype=torch.float32)
    relation_mask = torch.zeros((batch, visual_width - 2, visual_width - 2), dtype=torch.bool)
    for index, row in enumerate(rows):
        latex_ids[index, :row["latexIds"].numel()] = row["latexIds"]
        visual_ids[index, :row["visualIds"].numel()] = row["visualIds"]
        nodes = row["relationMask"].shape[0]
        relation_target[index, :nodes, :nodes] = row["relationTarget"]
        relation_mask[index, :nodes, :nodes] = row["relationMask"]
    return {"sampleIds": [row["sampleId"] for row in rows], "latexIds": latex_ids, "visualIds": visual_ids, "relationTarget": relation_target, "relationMask": relation_mask}


def assert_decoder_condition(batch: dict[str, Any], spatial_features: Tensor, instance_embeddings: Tensor, instance_mask: Tensor, instance_sample_ids: list[list[str | None]], relation_logits: Tensor, relation_mask: Tensor) -> None:
    """Validate sample identity and preserve spatial, instance, and relation axes."""
    sample_ids = batch.get("sampleIds")
    if not isinstance(sample_ids, list) or spatial_features.ndim != 4 or spatial_features.shape[0] != len(sample_ids):
        raise ValueError("spatial features require [B,C,H,W] aligned to teacher sampleIds")
    if spatial_features.shape[-2:] != (128, 128):
        raise ValueError("decoder requires FormulaRasterV1 512-space encoder map [B,C,128,128], never a pooled raster")
    b, n, d = instance_embeddings.shape
    if d != 128 or instance_mask.shape != (b, n) or relation_logits.shape[:3] != (b, n, n) or relation_logits.shape[-1] != len(RELATION_TYPES) or relation_mask.shape != (b, n, n):
        raise ValueError("instance/relation representation shape invariant failed")
    if b != len(sample_ids) or len(instance_sample_ids) != b:
        raise ValueError("instance representation batch does not align to teacher sampleIds")
    for row_index, sample_id in enumerate(sample_ids):
        if len(instance_sample_ids[row_index]) != n:
            raise ValueError("instance sampleId cardinality mismatch")
        for instance_index, active in enumerate(instance_mask[row_index].tolist()):
            linked = instance_sample_ids[row_index][instance_index]
            if active and linked != sample_id:
                raise ValueError(f"instance sampleId mismatch: teacher={sample_id!r}, instance={linked!r}")
            if not active and linked is not None:
                raise ValueError("masked instance slot must not carry a sampleId")
    if torch.any(relation_mask & (~instance_mask.unsqueeze(1) | ~instance_mask.unsqueeze(2))):
        raise ValueError("relation mask may only reference active, sample-matched instances")


def teacher_forcing_loss(latex_logits: Tensor, visual_logits: Tensor, relation_logits: Tensor, batch: dict[str, Any], latex_pad_id: int, visual_pad_id: int) -> dict[str, Tensor]:
    latex_target = batch["latexIds"][:, 1:]
    visual_target = batch["visualIds"][:, 1:]
    if latex_logits.shape != (*latex_target.shape, latex_logits.shape[-1]) or visual_logits.shape != (*visual_target.shape, visual_logits.shape[-1]):
        raise ValueError("teacher forcing logits must predict every shifted target position")
    if relation_logits.shape != batch["relationTarget"].shape:
        raise ValueError("structural relation logits/teacher shape mismatch")
    latex = F.cross_entropy(latex_logits.reshape(-1, latex_logits.shape[-1]), latex_target.reshape(-1), ignore_index=latex_pad_id)
    visual = F.cross_entropy(visual_logits.reshape(-1, visual_logits.shape[-1]), visual_target.reshape(-1), ignore_index=visual_pad_id)
    mask = batch["relationMask"].unsqueeze(-1).expand_as(relation_logits)
    if not torch.any(mask):
        raise ValueError("structural relation loss requires at least one AST relation")
    relation = F.binary_cross_entropy_with_logits(relation_logits[mask], batch["relationTarget"][mask])
    total = latex + visual + relation
    if not torch.isfinite(total):
        raise ValueError("teacher forcing loss is non-finite")
    return {"total": total, "latex": latex, "visual": visual, "relation": relation}


class FormulaStructureDecoder(nn.Module):
    """MPS-only decoder using flattened spatial cells, never a global raster pool."""
    def __init__(self, latex_vocab_size: int, visual_vocab_size: int, channels: int = 128, width: int = 128) -> None:
        super().__init__()
        self.spatial_projection = nn.Conv2d(channels, width, kernel_size=1)
        self.instance_projection = nn.Linear(128, width)
        self.relation_projection = nn.Linear(len(RELATION_TYPES), width)
        self.latex_embedding = nn.Embedding(latex_vocab_size, width)
        self.visual_embedding = nn.Embedding(visual_vocab_size, width)
        layer = nn.TransformerDecoderLayer(width, nhead=4, batch_first=True)
        self.decoder = nn.TransformerDecoder(layer, num_layers=2)
        self.latex_output = nn.Linear(width, latex_vocab_size)
        self.visual_output = nn.Linear(width, visual_vocab_size)
        self.relation_output = nn.Bilinear(width, width, len(STRUCTURAL_RELATIONS))

    def forward(self, spatial_features: Tensor, instance_embeddings: Tensor, instance_mask: Tensor, relation_logits: Tensor, relation_mask: Tensor, latex_prefix: Tensor, visual_prefix: Tensor) -> tuple[Tensor, Tensor, Tensor]:
        if spatial_features.device.type != "mps":
            raise RuntimeError("FormulaStructureDecoder optimization requires MPS")
        # Flattening preserves each 128x128 FormulaRasterV1 spatial location.
        spatial_memory = self.spatial_projection(spatial_features).flatten(2).transpose(1, 2)
        instance_memory = self.instance_projection(instance_embeddings) * instance_mask.unsqueeze(-1)
        relation_memory = self.relation_projection(relation_logits) * relation_mask.unsqueeze(-1)
        memory = torch.cat((spatial_memory, instance_memory, relation_memory.flatten(1, 2)), dim=1)
        latex_hidden = self.decoder(self.latex_embedding(latex_prefix), memory)
        visual_hidden = self.decoder(self.visual_embedding(visual_prefix), memory)
        # visual_prefix is BOS plus every visual node (the shifted EOS is the
        # prediction target), therefore positions 1... retain one state per
        # AST node for the structural relation teacher.
        node_hidden = visual_hidden[:, 1:]
        pairs_left = node_hidden.unsqueeze(2).expand(-1, -1, node_hidden.shape[1], -1)
        pairs_right = node_hidden.unsqueeze(1).expand(-1, node_hidden.shape[1], -1, -1)
        return self.latex_output(latex_hidden), self.visual_output(visual_hidden), self.relation_output(pairs_left, pairs_right)
