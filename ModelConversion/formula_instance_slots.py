#!/usr/bin/env python3
"""MPS-only formula-to-instance-slot training over direct stroke annotations."""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

import torch
from torch import Tensor, nn
from torch.nn import functional as F
from torch.utils.data import Dataset

from formula_whole_input import load_formula_input
from instance_separator import (
    COORDINATE_SPEC,
    EXPECTED_CLASS_COUNT,
    MASK_STRIDE,
    RASTER_SIZE,
    SymbolVocabulary,
    _bbox,
    _mask,
    load_symbol_vocabulary,
)
from raster_formula_model import raster_tensor


def _slot_key(row: dict[str, Any]) -> tuple[float, float, float, float, str]:
    """Return a visual, deterministic training order for anonymous slots.

    `instanceId` remains the source-stable identity used for persistence and
    graph connections.  Its stroke-index suffix is temporal input order,
    however, and is absent from FormulaRasterV1.  Supervising fixed decoder
    slots with that suffix asks a raster-only model to predict information it
    cannot observe.  Slot order is therefore derived from the direct visual
    box only; a full instance ID is retained solely as a deterministic tie
    breaker for coincident boxes.
    """
    x0, y0, x1, y1 = map(float, row["bbox512"])
    return (y0, x0, y1, x1, row["instanceId"])


class FormulaInstanceSlotDataset(Dataset[dict[str, Any]]):
    """One FormulaRasterV1 per sample with deterministically ordered instance slots."""
    def __init__(self, teachers: Path, mathwriting_root: Path, vocabulary: SymbolVocabulary) -> None:
        grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for line in teachers.read_text(encoding="utf-8").splitlines():
            if not line:
                continue
            row = json.loads(line)
            sample_id = row.get("sampleId")
            if not isinstance(sample_id, str) or not sample_id:
                raise ValueError("instance teacher requires non-empty sampleId")
            if row.get("coordinateSpec") != COORDINATE_SPEC:
                raise ValueError(f"{sample_id}: incompatible coordinate specification")
            if not isinstance(row.get("instanceId"), str) or not row["instanceId"].startswith(sample_id + ":"):
                raise ValueError(f"{sample_id}: instanceId is not source-stable")
            vocabulary.index(row.get("symbolToken"))
            _mask(row.get("maskPixels512")); _bbox(row.get("bbox512"))
            grouped[sample_id].append(row)
        if not grouped:
            raise ValueError("instance teacher input is empty")
        self.rows = [(sample_id, sorted(rows, key=_slot_key)) for sample_id, rows in sorted(grouped.items())]
        self.root = mathwriting_root
        self.vocabulary = vocabulary
        self.max_slots = max(len(rows) for _, rows in self.rows)

    def __len__(self) -> int: return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, Any]:
        sample_id, rows = self.rows[index]
        formula, meta = load_formula_input(self.root / "train" / f"{sample_id}.inkml")
        if meta["sampleId"] != sample_id:
            raise ValueError(f"{sample_id}: InkML identity mismatch")
        masks = torch.stack([F.max_pool2d(_mask(row["maskPixels512"]), MASK_STRIDE, MASK_STRIDE) for row in rows])
        return {
            "sampleId": sample_id,
            "raster": raster_tensor(formula),
            "mask": masks,
            "bbox": torch.stack([_bbox(row["bbox512"]) for row in rows]),
            "classIndex": torch.tensor([self.vocabulary.index(row["symbolToken"]) for row in rows], dtype=torch.long),
        }


def collate_formula_instances(rows: list[dict[str, Any]], max_slots: int) -> dict[str, Any]:
    if not rows:
        raise ValueError("cannot collate an empty formula batch")
    batch = len(rows)
    masks = torch.zeros((batch, max_slots, 1, RASTER_SIZE // MASK_STRIDE, RASTER_SIZE // MASK_STRIDE))
    bboxes = torch.zeros((batch, max_slots, 4))
    classes = torch.zeros((batch, max_slots), dtype=torch.long)
    active = torch.zeros((batch, max_slots), dtype=torch.bool)
    for index, row in enumerate(rows):
        count = row["mask"].shape[0]
        if count > max_slots:
            raise ValueError("formula instance count exceeds declared slot capacity")
        masks[index, :count] = row["mask"]; bboxes[index, :count] = row["bbox"]
        classes[index, :count] = row["classIndex"]; active[index, :count] = True
    return {"sampleIds": [row["sampleId"] for row in rows], "raster": torch.stack([row["raster"] for row in rows]), "mask": masks, "bbox": bboxes, "classIndex": classes, "active": active}


class FormulaInstanceSlotSeparator(nn.Module):
    """Predicts all annotated symbol instances from one complete FormulaRasterV1."""
    def __init__(self, slots: int) -> None:
        super().__init__()
        if slots < 1:
            raise ValueError("slot capacity must be positive")
        self.slots = slots
        self.features = nn.Sequential(nn.Conv2d(1, 64, 5, 2, 2), nn.GELU(), nn.Conv2d(64, 128, 3, 2, 1), nn.GELU())
        self.queries = nn.Embedding(slots, 128)
        self.spatial_attention = nn.MultiheadAttention(128, num_heads=4, batch_first=True)
        self.classifier = nn.Linear(128, EXPECTED_CLASS_COUNT)
        self.bbox = nn.Linear(128, 4)

    def forward(self, raster: Tensor) -> dict[str, Tensor]:
        if raster.device.type != "mps":
            raise RuntimeError("FormulaInstanceSlotSeparator optimization requires MPS")
        if raster.ndim != 4 or raster.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
            raise ValueError("slot separator requires FormulaRasterV1 [B,1,512,512]")
        features = self.features(raster)
        spatial = F.adaptive_avg_pool2d(features, output_size=(16, 16)).flatten(2).transpose(1, 2)
        queries = self.queries.weight.unsqueeze(0).expand(raster.shape[0], -1, -1)
        attended, _ = self.spatial_attention(queries, spatial, spatial, need_weights=False)
        slot_features = queries + attended
        return {
            "maskLogits": torch.einsum("bchw,bqc->bqhw", features, slot_features).unsqueeze(2),
            "bbox": self.bbox(slot_features).sigmoid(),
            "classLogits": self.classifier(slot_features),
        }


def slot_instance_loss(outputs: dict[str, Tensor], batch: dict[str, Any]) -> dict[str, Tensor]:
    active = batch["active"]
    if outputs["maskLogits"].shape != batch["mask"].shape or outputs["bbox"].shape != batch["bbox"].shape:
        raise ValueError("slot output and direct instance teachers differ in shape")
    mask = F.binary_cross_entropy_with_logits(outputs["maskLogits"], batch["mask"])
    bbox = F.smooth_l1_loss(outputs["bbox"][active], batch["bbox"][active])
    symbol = F.cross_entropy(outputs["classLogits"][active], batch["classIndex"][active])
    total = mask + bbox + symbol
    if not torch.isfinite(total):
        raise ValueError("slot instance loss is non-finite")
    return {"total": total, "mask": mask, "bbox": bbox, "class": symbol}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--vocabulary-teachers", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--steps", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is unavailable; do not run a CPU replacement")
    vocabulary = load_symbol_vocabulary(args.vocabulary_teachers)
    dataset = FormulaInstanceSlotDataset(args.teachers, args.mathwriting_root, vocabulary)
    if not 0 < args.batch_size <= len(dataset):
        raise ValueError("batch size must select a non-empty in-range formula batch")
    if args.steps < 1:
        raise ValueError("steps must be positive")
    model = FormulaInstanceSlotSeparator(dataset.max_slots).to("mps")
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4)
    losses: dict[str, Tensor] | None = None
    for step in range(args.steps):
        start = (step * args.batch_size) % len(dataset)
        indices = [(start + offset) % len(dataset) for offset in range(args.batch_size)]
        batch = collate_formula_instances([dataset[index] for index in indices], dataset.max_slots)
        device_batch = {key: value.to("mps") if isinstance(value, Tensor) else value for key, value in batch.items()}
        losses = slot_instance_loss(model(device_batch["raster"]), device_batch)
        optimizer.zero_grad(set_to_none=True); losses["total"].backward(); optimizer.step()
    assert losses is not None
    report = {"formulaCount": len(dataset), "slotCapacity": dataset.max_slots, "steps": args.steps, **{key: float(value.detach().cpu()) for key, value in losses.items()}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"format": "inf6-formula-instance-slot-v1", "stateDict": model.state_dict(), "vocabulary": list(vocabulary.tokens), "report": report}, args.output)
    args.output.with_suffix(".json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
