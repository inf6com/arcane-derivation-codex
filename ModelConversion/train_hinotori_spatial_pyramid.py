#!/usr/bin/env python3
"""Train a new ANE-oriented spatial-pyramid angular-margin symbol model."""
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

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import CLASS_COUNT, direct_class_centroids
from hinotori_spatial_pyramid import HinotoriSpatialPyramidAngularMargin
from train_hinotori_raster_classifier import augment_rasters, collate_rasters, split_fingerprint


def metrics(logits: torch.Tensor, targets: torch.Tensor) -> dict[str, float]:
    if logits.ndim != 2 or logits.shape[1] != CLASS_COUNT or targets.shape != (logits.shape[0],):
        raise ValueError("metric inputs do not match the 229-class isolated-symbol task")
    top = logits.topk(5, dim=1).indices
    return {
        "count": int(targets.numel()),
        "top1": float((top[:, 0] == targets).float().mean().item()),
        "top5": float((top == targets[:, None]).any(dim=1).float().mean().item()),
    }


def evaluate(model: HinotoriSpatialPyramidAngularMargin, loader: DataLoader, device: torch.device) -> tuple[dict[str, float], list[torch.Tensor], list[torch.Tensor]]:
    model.eval()
    logit_parts: list[torch.Tensor] = []
    label_parts: list[torch.Tensor] = []
    with torch.inference_mode():
        for images, labels, _ in loader:
            logits, _ = model(images.to(device))
            logit_parts.append(logits.cpu())
            label_parts.append(labels)
    logits = torch.cat(logit_parts)
    labels = torch.cat(label_parts)
    return metrics(logits, labels), logit_parts, label_parts


def encode_fit(model: HinotoriSpatialPyramidAngularMargin, loader: DataLoader, device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
    model.eval()
    embeddings: list[torch.Tensor] = []
    labels: list[torch.Tensor] = []
    with torch.inference_mode():
        for images, targets, _ in loader:
            embeddings.append(model.encode(images.to(device)).cpu())
            labels.append(targets)
    return torch.cat(embeddings), torch.cat(labels)


def evaluate_prototypes(
    model: HinotoriSpatialPyramidAngularMargin,
    train_loader: DataLoader,
    valid_loader: DataLoader,
    device: torch.device,
) -> dict[str, float]:
    train_embeddings, train_labels = encode_fit(model, train_loader, device)
    centroids = direct_class_centroids(train_embeddings.to(device), train_labels.to(device))
    model.eval()
    logits: list[torch.Tensor] = []
    labels: list[torch.Tensor] = []
    with torch.inference_mode():
        for images, targets, _ in valid_loader:
            query = model.encode(images.to(device))
            logits.append((query @ centroids.T * model.scale).cpu())
            labels.append(targets)
    return metrics(torch.cat(logits), torch.cat(labels))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--class-weight-power", type=float, default=0.5)
    parser.add_argument("--seed", type=int, default=20261104)
    parser.add_argument("--scale", type=float, default=32.0)
    parser.add_argument("--margin", type=float, default=0.30)
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0 or not 0 <= args.class_weight_power <= 1:
        raise ValueError("epochs, batch size, learning rate, or class-weight power is invalid")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; CPU training fallback is prohibited")
    if args.output.exists() and any(args.output.iterdir()):
        raise FileExistsError(f"refusing to overwrite an existing experiment: {args.output}")
    args.output.mkdir(parents=True, exist_ok=True)
    for path in (args.teachers, args.source_split, args.vocabulary):
        if not path.is_file():
            raise FileNotFoundError(f"required model input is missing: {path}")

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.mps.manual_seed(args.seed)
    device = torch.device("mps")
    dataset_train = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, 128, "train")
    dataset_valid = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, 128, "valid")
    vocab_bytes = args.vocabulary.read_bytes()
    vocab_doc = json.loads(vocab_bytes)
    vocabulary = vocab_doc.get("labels") if isinstance(vocab_doc, dict) else None
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain exactly 229 unique ordered labels")
    if any(row.get("classIndex") not in range(CLASS_COUNT) or row.get("label") != vocabulary[row["classIndex"]]
           for row in dataset_train.rows + dataset_valid.rows):
        raise ValueError("teacher label/class mapping does not match the fixed 229-symbol vocabulary")
    train_sources = {str(row["sourceSampleId"]) for row in dataset_train.rows}
    valid_sources = {str(row["sourceSampleId"]) for row in dataset_valid.rows}
    if train_sources & valid_sources:
        raise ValueError("source-level leakage detected between train and validation")
    class_counts = torch.bincount(torch.tensor([int(row["classIndex"]) for row in dataset_train.rows]), minlength=CLASS_COUNT)
    if (class_counts == 0).any():
        raise ValueError("all 229 classes must have direct training examples")

    generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(dataset_train, batch_size=args.batch_size, shuffle=True, collate_fn=collate_rasters, generator=generator)
    fit_eval_loader = DataLoader(dataset_train, batch_size=args.batch_size, shuffle=False, collate_fn=collate_rasters)
    valid_loader = DataLoader(dataset_valid, batch_size=args.batch_size, shuffle=False, collate_fn=collate_rasters)
    model = HinotoriSpatialPyramidAngularMargin(scale=args.scale, margin=args.margin).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-2)
    class_weights = class_counts.float().pow(-args.class_weight_power)
    class_weights = (class_weights / class_weights.mean()).to(device)
    metadata = {
        "model": "HinotoriSpatialPyramidAngularMargin",
        "task": "229-way isolated handwritten symbol classification",
        "architecture": "residual raster encoder; 1x1+2x2+4x4 spatial pyramid average pooling; 128D normalized embedding; learned 229 class prototypes",
        "trainingObjective": "ArcFace additive angular margin on target cosine logit plus class-weighted cross entropy",
        "arcFaceScale": args.scale,
        "arcFaceMarginRadians": args.margin,
        "input": {"kind": "order-independent binary ink raster", "size": 64, "channels": 1,
                  "strokeOrderEncoded": False, "withinStrokeDirectionEncoded": False},
        "aneIntent": "Core ML compatible standard convolution/pooling/linear/normalization arithmetic; ANE use requires physical iPad measurement",
        "trainTeachersSHA256": sha256(args.teachers),
        "sourceSplitSHA256": sha256(args.source_split),
        "vocabularySHA256": hashlib.sha256(vocab_bytes).hexdigest(),
        "trainSourceFingerprint": split_fingerprint(dataset_train),
        "validSourceFingerprint": split_fingerprint(dataset_valid),
        "trainSourceCount": len(train_sources),
        "validSourceCount": len(valid_sources),
        "trainSymbolCount": len(dataset_train),
        "validSymbolCount": len(dataset_valid),
        "trainClassCounts": class_counts.tolist(),
        "optimizer": "AdamW",
        "learningRate": args.learning_rate,
        "weightDecay": 1e-2,
        "classWeightPower": args.class_weight_power,
        "trainAugmentation": "bounded affine transform from existing raster protocol: rotation ±0.08 rad, scale 0.90–1.10, translation ±0.06; no flips",
        "seed": args.seed,
        "device": "MPS",
        "checkpointSelection": "inner validation exact Top-1 and Top-5 independently; all outer-test sources remain unopened",
        "validationRole": "development only; not a final independent result",
    }
    (args.output / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    history_path = args.output / "metrics.jsonl"
    best = {"classifierTop1": -1.0, "classifierTop5": -1.0, "fitPrototypeTop1": -1.0, "fitPrototypeTop5": -1.0}
    with history_path.open("x", encoding="utf-8") as history:
        for epoch in range(1, args.epochs + 1):
            model.train()
            train_loss = 0.0
            train_correct = 0
            train_total = 0
            for images, labels, _ in train_loader:
                images = augment_rasters(images).to(device)
                labels = labels.to(device)
                embeddings = model.encode(images)
                logits = model.training_logits(embeddings, labels)
                loss = F.cross_entropy(logits, labels, weight=class_weights)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                optimizer.step()
                train_loss += float(loss.detach().item()) * labels.numel()
                train_correct += int((logits.detach().argmax(1) == labels).sum().item())
                train_total += labels.numel()
            classifier, _, _ = evaluate(model, valid_loader, device)
            prototypes = evaluate_prototypes(model, fit_eval_loader, valid_loader, device)
            record = {
                "epoch": epoch,
                "trainAngularMarginLoss": train_loss / train_total,
                "trainTargetAccuracyDuringMarginTraining": train_correct / train_total,
                "classifier": classifier,
                "fitTrainPrototype": prototypes,
            }
            history.write(json.dumps(record, ensure_ascii=False) + "\n")
            history.flush()
            checkpoint = {"model": model.state_dict(), "optimizer": optimizer.state_dict(), "epoch": epoch,
                          "run": metadata, "metrics": record, "torchRngState": torch.get_rng_state()}
            torch.save(checkpoint, args.output / "latest.pt")
            (args.output / "latest.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            for key, metric_key, suffix in (
                ("classifierTop1", "top1", "classifier-top1"),
                ("classifierTop5", "top5", "classifier-top5"),
                ("fitPrototypeTop1", "top1", "fit-prototype-top1"),
                ("fitPrototypeTop5", "top5", "fit-prototype-top5"),
            ):
                value = float((classifier if key.startswith("classifier") else prototypes)[metric_key])
                if value > best[key]:
                    best[key] = value
                    torch.save(checkpoint, args.output / f"best-{suffix}.pt")
                    (args.output / f"best-{suffix}.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(record, ensure_ascii=False), flush=True)
    summary = {
        "status": "COMPLETED",
        "epochs": args.epochs,
        "bestInnerValidationMetrics": best,
        "checkpointSelection": metadata["checkpointSelection"],
        "outerTestRead": False,
        **metadata,
    }
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
