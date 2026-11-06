#!/usr/bin/env python3
"""Evaluate a train-only FormulaRasterV1 instance-slot checkpoint on held-out formulas."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch
from torch import Tensor

from formula_instance_slots import (
    FormulaInstanceSlotDataset,
    FormulaInstanceSlotSeparator,
    collate_formula_instances,
    slot_instance_loss,
)
from instance_separator import load_symbol_vocabulary


def _box_iou(predicted: Tensor, expected: Tensor) -> Tensor:
    left = torch.maximum(predicted[..., 0], expected[..., 0])
    top = torch.maximum(predicted[..., 1], expected[..., 1])
    right = torch.minimum(predicted[..., 2], expected[..., 2])
    bottom = torch.minimum(predicted[..., 3], expected[..., 3])
    intersection = (right - left).clamp_min(0) * (bottom - top).clamp_min(0)
    predicted_area = (predicted[..., 2] - predicted[..., 0]).clamp_min(0) * (predicted[..., 3] - predicted[..., 1]).clamp_min(0)
    expected_area = (expected[..., 2] - expected[..., 0]).clamp_min(0) * (expected[..., 3] - expected[..., 1]).clamp_min(0)
    return intersection / (predicted_area + expected_area - intersection).clamp_min(1e-8)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--vocabulary-teachers", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is unavailable; do not run a CPU replacement")
    checkpoint: dict[str, Any] = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("format") != "inf6-formula-instance-slot-v1":
        raise ValueError("unexpected checkpoint format")
    vocabulary = load_symbol_vocabulary(args.vocabulary_teachers)
    if list(vocabulary.tokens) != checkpoint.get("vocabulary"):
        raise ValueError("checkpoint vocabulary differs from the authoritative teacher vocabulary")
    dataset = FormulaInstanceSlotDataset(args.teachers, args.mathwriting_root, vocabulary)
    slots = checkpoint.get("report", {}).get("slotCapacity")
    if not isinstance(slots, int) or slots < dataset.max_slots:
        raise ValueError("checkpoint slot capacity cannot represent held-out formulas")
    model = FormulaInstanceSlotSeparator(slots).to("mps")
    model.load_state_dict(checkpoint["stateDict"], strict=True)
    model.eval()
    totals = {"total": 0.0, "mask": 0.0, "bbox": 0.0, "class": 0.0}
    instances = 0
    correct = 0
    box_iou_sum = 0.0
    mask_intersection = 0.0
    mask_union = 0.0
    with torch.no_grad():
        for row in dataset:
            batch = collate_formula_instances([row], slots)
            device_batch = {key: value.to("mps") if isinstance(value, Tensor) else value for key, value in batch.items()}
            outputs = model(device_batch["raster"])
            losses = slot_instance_loss(outputs, device_batch)
            for key in totals:
                totals[key] += float(losses[key].cpu())
            active = device_batch["active"]
            predicted_class = outputs["classLogits"].argmax(dim=-1)
            correct += int((predicted_class[active] == device_batch["classIndex"][active]).sum().cpu())
            instances += int(active.sum().cpu())
            box_iou_sum += float(_box_iou(outputs["bbox"][active], device_batch["bbox"][active]).sum().cpu())
            predicted_mask = outputs["maskLogits"].sigmoid().ge(0.5)[active]
            expected_mask = device_batch["mask"][active].ge(0.5)
            mask_intersection += float((predicted_mask & expected_mask).sum().cpu())
            mask_union += float((predicted_mask | expected_mask).sum().cpu())
    report = {
        "format": "inf6-formula-instance-slot-validation-v1",
        "checkpoint": str(args.checkpoint),
        "formulaCount": len(dataset),
        "instanceCount": instances,
        "slotCapacity": slots,
        "meanLoss": {key: value / len(dataset) for key, value in totals.items()},
        "orderedSlotClassTop1": correct / instances,
        "meanBoxIoU": box_iou_sum / instances,
        "maskIoUAt0_5": mask_intersection / mask_union if mask_union else 0.0,
        "scope": "Held-out formula IDs from the direct-instance corpus; this is an auxiliary separator evaluation, not final LaTeX recognition.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
