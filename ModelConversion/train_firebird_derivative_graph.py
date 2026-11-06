#!/usr/bin/env python3
"""Train one fused raster + complete derivative-trajectory model on MPS."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import torch
from torch import nn
from torch.nn import functional as F
from torch.utils.data import DataLoader

from firebird_temporal_fusion import FirebirdDerivativeGraphRasterFusion
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import CLASS_COUNT
from train_firebird_temporal_fusion import POINT_COUNT, augment_paired, collate_temporal, source_fingerprint, summarize


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


@torch.inference_mode()
def evaluate(model: nn.Module, loader: DataLoader, device: torch.device) -> dict[str, object]:
    model.eval()
    logits_parts, labels, source_ids = [], [], []
    for images, points, padding, targets, sources in loader:
        logits, _ = model(images.to(device), points.to(device), padding.to(device))
        logits_parts.append(logits.cpu())
        labels.append(targets)
        source_ids.extend(sources)
    target = torch.cat(labels)
    prediction = torch.cat(logits_parts)
    return {
        **summarize(prediction, target),
        "sourceSampleIds": source_ids,
        "targets": target.tolist(),
        "predictions": prediction.argmax(1).tolist(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=40)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--seed", type=int, default=20261122)
    parser.add_argument("--class-weight-power", type=float, default=0.5)
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0 or not 0 <= args.class_weight_power <= 1:
        raise ValueError("training settings are invalid")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited")
    if args.output.exists() and any(args.output.iterdir()):
        raise FileExistsError(f"refusing to overwrite an existing experiment: {args.output}")
    for path in (args.teachers, args.source_split, args.vocabulary):
        if not path.is_file():
            raise FileNotFoundError(f"required input is missing: {path}")
    args.output.mkdir(parents=True, exist_ok=True)
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.mps.manual_seed(args.seed)
    device = torch.device("mps")

    train_data = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, POINT_COUNT, "train", temporal=True)
    valid_data = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, POINT_COUNT, "valid", temporal=True)
    train_fingerprint, train_sources = source_fingerprint(train_data)
    valid_fingerprint, valid_sources = source_fingerprint(valid_data)
    if set(train_sources) & set(valid_sources):
        raise ValueError("fit-train and inner-validation sources overlap")
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary = json.loads(vocabulary_bytes)
    labels = vocabulary.get("labels") if isinstance(vocabulary, dict) else None
    if not isinstance(labels, list) or len(labels) != CLASS_COUNT or len(set(labels)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain 229 unique ordered symbol labels")
    for row in train_data.rows + valid_data.rows:
        index = row.get("classIndex")
        if not isinstance(index, int) or not 0 <= index < CLASS_COUNT or row.get("label") != labels[index]:
            raise ValueError("direct-teacher class index does not match the fixed vocabulary")
    counts = torch.bincount(torch.tensor([int(row["classIndex"]) for row in train_data.rows]), minlength=CLASS_COUNT)
    if (counts == 0).any():
        raise ValueError("all 229 classes require fit-train examples")

    loader_rng = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=True, collate_fn=collate_temporal, generator=loader_rng)
    valid_loader = DataLoader(valid_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_temporal)
    model = FirebirdDerivativeGraphRasterFusion().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-2)
    weights = (counts.float().pow(-args.class_weight_power) / counts.float().pow(-args.class_weight_power).mean()).to(device)
    run = {
        "model": "FirebirdDerivativeGraphRasterFusionCandidate",
        "task": "229-way isolated handwritten symbol classification",
        "architecture": "parallel residual raster CNN plus time-ordered parametric trajectory p(t)=(x(t),y(t)); point features include p(t), dp/dt, stroke-local phase, symbol-relative time, and stroke duration; per-stroke bidirectional GRU with learned whole-curve attention pooling, then chronological stroke GRU; fused 128D embedding and one 229-class classifier",
        "derivativeDefinition": "first derivative only: dp/dt=(deltaX/deltaTime,deltaY/deltaTime), with timestamp monotonicity repair and point order preserved; no second derivative; derivative sequence is encoded as one complete curve representation rather than independent pointwise matches",
        "input": {
            "raster": "64x64 binary ink from the same annotated stroke group",
            "trajectory": "InkML X/Y/T direct-teacher traces, XY normalized over the annotated symbol, each stroke resampled uniformly in elapsed time to 128 points; stroke and symbol-relative phases retained",
        },
        "trainingObjective": "class-weighted cross entropy on the fused 229-class output",
        "teachersSHA256": sha256(args.teachers),
        "sourceSplitSHA256": sha256(args.source_split),
        "vocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
        "trainSourceFingerprint": train_fingerprint,
        "validSourceFingerprint": valid_fingerprint,
        "trainSourceCount": len(train_sources),
        "validSourceCount": len(valid_sources),
        "trainSymbolCount": len(train_data),
        "validSymbolCount": len(valid_data),
        "trainClassCounts": counts.tolist(),
        "seed": args.seed,
        "optimizer": "AdamW",
        "learningRate": args.learning_rate,
        "weightDecay": 1e-2,
        "classWeightPower": args.class_weight_power,
        "device": "MPS",
        "outerTestRead": False,
        "validationRole": "inner validation for candidate and epoch selection; final outer test remains unopened",
        "aneStatus": "not measured",
    }
    (args.output / "run.json").write_text(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    best = {"top1": -1.0, "top5": -1.0}
    with (args.output / "metrics.jsonl").open("x", encoding="utf-8") as history:
        for epoch in range(1, args.epochs + 1):
            model.train()
            total_loss = 0.0
            total_count = 0
            for images, points, padding, targets, _ in train_loader:
                images, points = augment_paired(images, points)
                images = images.to(device)
                points = points.to(device)
                padding = padding.to(device)
                targets = targets.to(device)
                logits, _ = model(images, points, padding)
                loss = F.cross_entropy(logits, targets, weight=weights)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
                optimizer.step()
                total_loss += float(loss.detach().item()) * targets.numel()
                total_count += targets.numel()
            validation = evaluate(model, valid_loader, device)
            record = {"epoch": epoch, "trainLoss": total_loss / total_count, "fusedValidation": validation}
            history.write(json.dumps(record, ensure_ascii=False) + "\n")
            history.flush()
            checkpoint = {
                "model": model.state_dict(),
                "optimizer": optimizer.state_dict(),
                "epoch": epoch,
                "run": run,
                "metrics": record,
                "torchRngState": torch.get_rng_state(),
            }
            torch.save(checkpoint, args.output / "latest.pt")
            (args.output / "latest.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
            for metric in ("top1", "top5"):
                score = float(validation[metric])
                if score > best[metric]:
                    best[metric] = score
                    torch.save(checkpoint, args.output / f"best-{metric}.pt")
                    (args.output / f"best-{metric}.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps({"epoch": epoch, "trainLoss": record["trainLoss"], "fusedTop1": validation["top1"], "fusedTop5": validation["top5"], "supportedClasses": validation["supportedClassCount"]}, ensure_ascii=False), flush=True)
    (args.output / "summary.json").write_text(json.dumps({"status": "COMPLETED", "epochs": args.epochs, "bestInnerValidation": best, "outerTestRead": False, "run": run}, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
