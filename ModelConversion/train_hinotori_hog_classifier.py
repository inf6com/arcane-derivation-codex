#!/usr/bin/env python3
"""Train a fixed-HOG linear baseline on a source-grouped Hinotori split."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_hog_classifier import CLASS_COUNT, HinotoriHOGClassifier
from train_hinotori_raster_classifier import augment_rasters, collate_rasters


def evaluate(model: nn.Module, loader: DataLoader, device: torch.device) -> dict[str, object]:
    model.eval()
    count = top1 = top5 = 0
    confusion = torch.zeros((CLASS_COUNT, CLASS_COUNT), dtype=torch.int64)
    with torch.inference_mode():
        for images, labels, _ in loader:
            logits, _ = model(images.to(device))
            labels = labels.to(device)
            ranked = logits.topk(5, dim=1).indices
            top1 += int((ranked[:, 0] == labels).sum())
            top5 += int((ranked == labels[:, None]).any(1).sum())
            count += labels.numel()
            flat = labels.cpu() * CLASS_COUNT + ranked[:, 0].cpu()
            confusion += torch.bincount(flat, minlength=CLASS_COUNT**2).reshape(CLASS_COUNT, CLASS_COUNT)
    if count == 0:
        raise ValueError("source-disjoint validation partition is empty")
    support = confusion.sum(1)
    present = support > 0
    return {
        "sampleCount": count,
        "top1": top1 / count,
        "top5": top5 / count,
        "macroRecallSupportedClasses": float((confusion.diag()[present].double() / support[present]).mean()),
        "supportedClassCount": int(present.sum()),
        "confusionMatrix": confusion.tolist(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=80)
    parser.add_argument("--seed", type=int, default=20261110)
    args = parser.parse_args()
    if args.epochs < 1:
        raise ValueError("epochs must be positive")
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; CPU fallback is prohibited")
    torch.manual_seed(args.seed)
    random.seed(args.seed)
    device = torch.device("mps")
    train = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "train")
    valid = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "valid")
    split = json.loads(args.source_split.read_text(encoding="utf-8"))["sourceSplit"]
    train_sources = {s for s, role in split.items() if role == "train"}
    valid_sources = {s for s, role in split.items() if role == "valid"}
    if train_sources & valid_sources:
        raise ValueError("source-level leakage between training and validation")
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary = json.loads(vocabulary_bytes).get("labels")
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain 229 unique labels")
    if {int(row["classIndex"]) for row in train.rows} != set(range(CLASS_COUNT)):
        raise ValueError("training split must cover all 229 classes")
    generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train, batch_size=64, shuffle=True, collate_fn=collate_rasters, generator=generator)
    valid_loader = DataLoader(valid, batch_size=128, shuffle=False, collate_fn=collate_rasters)
    counts = torch.bincount(torch.tensor([int(row["classIndex"]) for row in train.rows]), minlength=CLASS_COUNT)
    weights = counts.float().pow(-0.5)
    weights = (weights / weights.mean()).to(device)
    model = HinotoriHOGClassifier().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-3)
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = {
        "architecture": "HinotoriHOGClassifier",
        "task": "isolated_symbol_exact_classification",
        "classCount": CLASS_COUNT,
        "classLabelsByIndex": vocabulary,
        "vocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
        "input": {"kind": "order_invariant_binary_ink_raster", "size": 64, "channels": 1},
        "descriptor": {"kind": "unsigned Sobel HOG", "orientationBins": 9, "cellPixels": 8, "blockCells": [2, 2], "blockNormalization": "L2-Hys, clip 0.2"},
        "trainAugmentation": {"kind": "per-sample affine transform", "rotationRadiansMaxAbs": 0.08, "scaleRange": [0.9, 1.1], "translationRangePerAxis": [-0.06, 0.06], "flips": False},
        "classWeighting": {"kind": "inverse-frequency power", "power": 0.5, "trainCountsByClassIndex": counts.tolist()},
        "optimizer": {"name": "AdamW", "learningRate": 1e-3, "weightDecay": 1e-3},
        "seed": args.seed,
        "device": str(device),
        "trainAnchorCount": len(train),
        "validAnchorCount": len(valid),
        "trainSourceCount": len(train_sources),
        "validSourceCount": len(valid_sources),
        "validRole": "checkpoint selection/development only",
    }
    (args.output / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    best = {"top1": -1.0, "top5": -1.0}
    with (args.output / "metrics.jsonl").open("w", encoding="utf-8") as history:
        for epoch in range(1, args.epochs + 1):
            model.train()
            for images, labels, _ in train_loader:
                images = augment_rasters(images).to(device)
                labels = labels.to(device)
                logits, _ = model(images)
                loss = nn.functional.cross_entropy(logits, labels, weight=weights)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                optimizer.step()
            metrics = evaluate(model, valid_loader, device)
            record = {"epoch": epoch, **metrics}
            history.write(json.dumps(record, ensure_ascii=False) + "\n")
            history.flush()
            for name, metric in (("top1", "top1"), ("top5", "top5")):
                if metrics[metric] > best[name]:
                    best[name] = float(metrics[metric])
                    torch.save({"epoch": epoch, "model": model.state_dict(), "run": metadata, "validation": metrics}, args.output / f"best{'-top5' if name == 'top5' else ''}.pt")
                    (args.output / f"best{'-top5' if name == 'top5' else ''}.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
            torch.save({"epoch": epoch, "model": model.state_dict(), "run": metadata, "validation": metrics}, args.output / "latest.pt")
            print(json.dumps({"epoch": epoch, "top1": metrics["top1"], "top5": metrics["top5"], "macroRecallSupportedClasses": metrics["macroRecallSupportedClasses"]}), flush=True)
    (args.output / "summary.json").write_text(json.dumps({"architecture": metadata["architecture"], "bestTop1": best["top1"], "bestTop5": best["top5"], "epochs": args.epochs, "metrics": str(args.output / "metrics.jsonl")}, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
