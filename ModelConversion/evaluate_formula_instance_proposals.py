#!/usr/bin/env python3
"""Held-out evaluation for FormulaRasterV1 variable-count proposal fields."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch import Tensor

from formula_instance_proposals import FormulaInstanceProposalNet, proposal_loss, proposal_targets
from formula_instance_slots import FormulaInstanceSlotDataset, collate_formula_instances
from instance_separator import EXPECTED_CLASS_COUNT, load_symbol_vocabulary


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
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("format") != "inf6-formula-instance-proposal-v1":
        raise ValueError("unexpected checkpoint format")
    vocabulary = load_symbol_vocabulary(args.vocabulary_teachers)
    if checkpoint.get("vocabulary") != list(vocabulary.tokens):
        raise ValueError("checkpoint vocabulary differs from authoritative teacher vocabulary")
    semantic_weights = checkpoint.get("semanticClassWeights")
    if not isinstance(semantic_weights, Tensor) or semantic_weights.shape != (EXPECTED_CLASS_COUNT,):
        raise ValueError("checkpoint lacks the required train-only semantic class weights")
    dataset = FormulaInstanceSlotDataset(args.teachers, args.mathwriting_root, vocabulary)
    model = FormulaInstanceProposalNet().to("mps")
    model.load_state_dict(checkpoint["stateDict"], strict=True)
    model.eval()
    sums = {"total": 0.0, "foreground": 0.0, "center": 0.0, "semantic": 0.0}
    foreground_intersection = foreground_union = 0
    semantic_correct = semantic_total = 0
    conflicts = 0
    with torch.no_grad():
        for row in dataset:
            batch = collate_formula_instances([row], dataset.max_slots)
            batch = {key: value.to("mps") if isinstance(value, Tensor) else value for key, value in batch.items()}
            targets = proposal_targets(batch)
            outputs = model(batch["raster"])
            # Evaluation loss is unweighted.  A held-out formula may contain
            # a class absent from train; using its zero train weight here
            # would make cross entropy undefined rather than report evidence.
            losses = proposal_loss(outputs, targets)
            for key in sums:
                sums[key] += float(losses[key].cpu())
            predicted_foreground = outputs["foreground"].sigmoid().ge(0.5)
            expected_foreground = targets["foreground"].ge(0.5)
            foreground_intersection += int((predicted_foreground & expected_foreground).sum().cpu())
            foreground_union += int((predicted_foreground | expected_foreground).sum().cpu())
            target_semantic = targets["semantic"]
            active = target_semantic.ne(-100)
            semantic_correct += int((outputs["semantic"].argmax(1)[active] == target_semantic[active]).sum().cpu())
            semantic_total += int(active.sum().cpu())
            conflicts += int(targets["semanticConflictPixels"].cpu())
    report = {
        "format": "inf6-formula-instance-proposal-validation-v1",
        "checkpoint": str(args.checkpoint),
        "formulaCount": len(dataset),
        "meanLoss": {key: value / len(dataset) for key, value in sums.items()},
        "foregroundIoUAt0_5": foreground_intersection / foreground_union if foreground_union else 0.0,
        "semanticTop1OnUnambiguousPixels": semantic_correct / semantic_total if semantic_total else 0.0,
        "semanticConflictPixelsExcluded": conflicts,
        "unseenTrainClassIDs": torch.nonzero(semantic_weights == 0, as_tuple=False).flatten().tolist(),
        "scope": "Held-out direct-label formulas. This measures proposal fields, not final LaTeX recognition or AST reconstruction.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
