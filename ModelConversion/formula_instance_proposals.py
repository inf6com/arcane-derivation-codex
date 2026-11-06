#!/usr/bin/env python3
"""Variable-count instance proposals from one complete FormulaRasterV1.

The input is always a full formula raster.  Direct symbol annotations are
used only as pixel/centre supervision; no pre-cut symbol image enters forward.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch
from torch import Tensor, nn
from torch.nn import functional as F

from formula_instance_slots import FormulaInstanceSlotDataset, collate_formula_instances
from instance_separator import EXPECTED_CLASS_COUNT, load_symbol_vocabulary


def proposal_targets(batch: dict[str, Any]) -> dict[str, Tensor]:
    masks = batch["mask"].squeeze(2).ge(0.5)  # [B,N,128,128]
    active = batch["active"]
    classes = batch["classIndex"]
    b, _, height, width = masks.shape
    foreground = torch.zeros((b, 1, height, width), dtype=torch.float32, device=masks.device)
    center = torch.zeros_like(foreground)
    semantic = torch.full((b, height, width), -100, dtype=torch.long, device=masks.device)
    conflict_pixels = torch.zeros((b, height, width), dtype=torch.bool, device=masks.device)
    for batch_index in range(b):
        for instance_index in torch.nonzero(active[batch_index], as_tuple=False).flatten().tolist():
            mask = masks[batch_index, instance_index]
            if not torch.any(mask):
                raise ValueError("direct instance teacher has an empty pooled mask")
            conflict = mask & semantic[batch_index].ne(-100) & semantic[batch_index].ne(classes[batch_index, instance_index])
            # A crossing pixel belongs to two handwritten instances.  It has
            # no single semantic class, so excluding it from this *exclusive*
            # pixel loss is mathematically required; foreground and centres
            # remain supervised and the count is reported to the caller.
            conflict_pixels[batch_index] |= conflict
            foreground[batch_index, 0][mask] = 1.0
            semantic[batch_index][mask] = classes[batch_index, instance_index]
            semantic[batch_index][conflict_pixels[batch_index]] = -100
            points = torch.nonzero(mask, as_tuple=False).to(torch.float32)
            y, x = points.mean(dim=0).round().to(torch.long).tolist()
            center[batch_index, 0, max(0, min(height - 1, y)), max(0, min(width - 1, x))] = 1.0
    return {"foreground": foreground, "center": center, "semantic": semantic, "semanticConflictPixels": conflict_pixels.sum()}


class FormulaInstanceProposalNet(nn.Module):
    """Fully convolutional proposal field; output count is determined at inference."""
    def __init__(self) -> None:
        super().__init__()
        self.encoder = nn.Sequential(
            nn.Conv2d(1, 64, 5, 2, 2), nn.GELU(),
            nn.Conv2d(64, 128, 3, 2, 1), nn.GELU(),
            nn.Conv2d(128, 128, 3, 1, 1), nn.GELU(),
        )
        self.foreground = nn.Conv2d(128, 1, 1)
        self.center = nn.Conv2d(128, 1, 1)
        self.semantic = nn.Conv2d(128, EXPECTED_CLASS_COUNT, 1)

    def forward(self, raster: Tensor) -> dict[str, Tensor]:
        if raster.device.type != "mps":
            raise RuntimeError("FormulaInstanceProposalNet optimization requires MPS")
        if raster.ndim != 4 or raster.shape[1:] != (1, 512, 512):
            raise ValueError("proposal net requires FormulaRasterV1 [B,1,512,512]")
        features = self.encoder(raster)
        return {"foreground": self.foreground(features), "center": self.center(features), "semantic": self.semantic(features)}


def proposal_loss(outputs: dict[str, Tensor], targets: dict[str, Tensor], semantic_class_weights: Tensor | None = None) -> dict[str, Tensor]:
    def balanced_binary(logits: Tensor, expected: Tensor, name: str) -> Tensor:
        positives = expected.sum()
        negatives = expected.numel() - positives
        if positives <= 0 or negatives <= 0:
            raise ValueError(f"{name} target must contain both positive and negative pixels")
        # The weight is measured from the current complete-formula batch.  It
        # prevents the all-background solution observed in held-out evidence.
        return F.binary_cross_entropy_with_logits(logits, expected, pos_weight=(negatives / positives))
    foreground = balanced_binary(outputs["foreground"], targets["foreground"], "foreground")
    center = balanced_binary(outputs["center"], targets["center"], "center")
    semantic = F.cross_entropy(outputs["semantic"], targets["semantic"], ignore_index=-100, weight=semantic_class_weights)
    total = foreground + center + semantic
    if not torch.isfinite(total):
        raise ValueError("proposal loss is non-finite")
    return {"total": total, "foreground": foreground, "center": center, "semantic": semantic}


def instance_class_weights(dataset: FormulaInstanceSlotDataset) -> Tensor:
    """Inverse-square-root instance frequency weights from train teachers only."""
    counts = torch.zeros(EXPECTED_CLASS_COUNT, dtype=torch.float32)
    for _, rows in dataset.rows:
        for row in rows:
            counts[dataset.vocabulary.index(row["symbolToken"])] += 1
    observed = counts > 0
    # The held-out split contains two labels not present in train.  Their
    # weights must not be inferred from validation; zero explicitly records
    # that this training run cannot learn those classes.
    weights = torch.zeros_like(counts)
    weights[observed] = counts[observed].rsqrt()
    return weights / weights[observed].mean()


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
    model = FormulaInstanceProposalNet().to("mps")
    semantic_class_weights = instance_class_weights(dataset).to("mps")
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4)
    losses: dict[str, Tensor] | None = None
    semantic_conflict_pixels = 0
    for index in range(args.steps):
        start = (index * args.batch_size) % len(dataset)
        rows = [dataset[(start + offset) % len(dataset)] for offset in range(args.batch_size)]
        batch = collate_formula_instances(rows, dataset.max_slots)
        batch = {key: value.to("mps") if isinstance(value, Tensor) else value for key, value in batch.items()}
        targets = proposal_targets(batch)
        semantic_conflict_pixels += int(targets["semanticConflictPixels"].cpu())
        losses = proposal_loss(model(batch["raster"]), targets, semantic_class_weights)
        optimizer.zero_grad(set_to_none=True); losses["total"].backward(); optimizer.step()
    assert losses is not None
    unseen_class_ids = torch.nonzero(semantic_class_weights.cpu() == 0, as_tuple=False).flatten().tolist()
    report = {"format": "inf6-formula-instance-proposal-v1", "formulaCount": len(dataset), "batchSize": args.batch_size, "steps": args.steps, "semanticConflictPixels": semantic_conflict_pixels, "unseenTrainClassIDs": unseen_class_ids, **{key: float(value.detach().cpu()) for key, value in losses.items()}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"format": report["format"], "stateDict": model.state_dict(), "vocabulary": list(vocabulary.tokens), "semanticClassWeights": semantic_class_weights.cpu(), "report": report}, args.output)
    args.output.with_suffix(".json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
