#!/usr/bin/env python3
"""Train/evaluate the Firebird online-trajectory-only symbol classifier."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import torch
from torch.nn import functional as F
from torch.utils.data import DataLoader

from firebird_online_trajectory import FirebirdOnlineTrajectoryClassifier
from hinotori_direct_dataset import DirectAnchorDataset, collate_direct_anchors
from hinotori_raster_classifier import CLASS_COUNT, direct_class_centroids


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def collate_trajectories(samples):
    batch = collate_direct_anchors(samples)
    points, padding = batch["points"], batch["strokePadding"]
    labels, sources = batch["classIndices"], batch["sourceSampleIds"]
    if not isinstance(points, torch.Tensor) or not isinstance(padding, torch.Tensor):
        raise TypeError("direct-stroke batch is missing coordinate tensors")
    if points.ndim != 4 or points.shape[2:] != (128, 2) or padding.shape != points.shape[:2] or padding.dtype != torch.bool:
        raise ValueError("trajectory batch violates the [batch,stroke,128,2] contract")
    if padding.all(dim=1).any() or not torch.isfinite(points).all():
        raise ValueError("trajectory batch contains an empty or non-finite symbol")
    return points, padding, labels, sources


def summarize(logits: torch.Tensor, targets: torch.Tensor) -> dict[str, object]:
    if logits.ndim != 2 or logits.shape[1] != CLASS_COUNT or targets.shape != (len(logits),):
        raise ValueError("evaluation does not match isolated 229-class symbol recognition")
    top = logits.topk(5, dim=1).indices
    predicted = top[:, 0]
    confusion = torch.bincount(targets * CLASS_COUNT + predicted, minlength=CLASS_COUNT**2).reshape(CLASS_COUNT, CLASS_COUNT)
    support = confusion.sum(1)
    present = support > 0
    recalls = confusion.diag()[present].double() / support[present]
    return {
        "count": int(targets.numel()),
        "top1": float((predicted == targets).float().mean().item()),
        "top5": float((top == targets[:, None]).any(dim=1).float().mean().item()),
        "macroRecallSupportedClasses": float(recalls.mean().item()),
        "supportedClassCount": int(present.sum().item()),
        "classSupport": support.tolist(),
        "confusionMatrix": confusion.tolist(),
    }


def source_fingerprint(dataset):
    sources = sorted({str(row["sourceSampleId"]) for row in dataset.rows})
    return hashlib.sha256("\n".join(sources).encode()).hexdigest(), sources


def augment_trajectories(points: torch.Tensor, stroke_padding: torch.Tensor) -> torch.Tensor:
    """Apply one label-preserving affine transform to each symbol's path."""
    if points.ndim != 4 or points.shape[-1] != 2 or stroke_padding.shape != points.shape[:2]:
        raise ValueError("affine augmentation inputs do not align")
    batch_size = points.shape[0]
    angle = (torch.rand(batch_size, dtype=points.dtype) * 2.0 - 1.0) * 0.08
    scale = 0.90 + torch.rand(batch_size, dtype=points.dtype) * 0.20
    translation = torch.rand((batch_size, 2), dtype=points.dtype) * 0.12 - 0.06
    cosine, sine = torch.cos(angle), torch.sin(angle)
    centered = points - translation[:, None, None, :]
    x = (cosine[:, None, None] * centered[..., 0] + sine[:, None, None] * centered[..., 1]) / scale[:, None, None]
    y = (-sine[:, None, None] * centered[..., 0] + cosine[:, None, None] * centered[..., 1]) / scale[:, None, None]
    transformed = torch.stack((x, y), dim=-1)
    return transformed.masked_fill(stroke_padding[:, :, None, None], 0.0)


@torch.inference_mode()
def embed_dataset(model, loader, device):
    model.eval()
    embeddings, labels = [], []
    for points, padding, targets, _ in loader:
        embeddings.append(model.encode(points.to(device), padding.to(device)).cpu())
        labels.append(targets)
    return torch.cat(embeddings), torch.cat(labels)


@torch.inference_mode()
def evaluate(model, loader, device, centroids):
    model.eval()
    classifier_logits, prototypes_logits, labels, source_ids = [], [], [], []
    for points, padding, targets, sources in loader:
        embeddings = model.encode(points.to(device), padding.to(device))
        classifier_logits.append(model.classifier(embeddings).cpu())
        prototypes_logits.append((embeddings @ centroids.T).cpu())
        labels.append(targets)
        source_ids.extend(sources)
    classifier_logits = torch.cat(classifier_logits)
    prototype_logits = torch.cat(prototypes_logits)
    targets = torch.cat(labels)
    return {
        "classifier": summarize(classifier_logits, targets),
        "fitTrainPrototype": summarize(prototype_logits, targets),
        "validationSourceIds": source_ids,
        "validationTargets": targets.tolist(),
        "classifierPredictions": classifier_logits.argmax(1).tolist(),
        "fitPrototypePredictions": prototype_logits.argmax(1).tolist(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--patience", type=int, default=10)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--class-weight-power", type=float, default=0.5)
    parser.add_argument("--seed", type=int, default=20261119)
    args = parser.parse_args()
    if args.epochs < 1 or args.patience < 1 or args.batch_size < 1 or args.learning_rate <= 0 or not 0 <= args.class_weight_power <= 1:
        raise ValueError("epoch, patience, batch, learning rate, or class-weight settings are invalid")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is unavailable; this experiment requires MPS and has no CPU fallback")
    if args.output.exists() and any(args.output.iterdir()):
        raise FileExistsError(f"refusing to overwrite an existing experiment: {args.output}")
    for path in (args.teachers, args.source_split, args.vocabulary):
        if not path.is_file():
            raise FileNotFoundError(f"required input does not exist: {path}")
    args.output.mkdir(parents=True, exist_ok=True)

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.mps.manual_seed(args.seed)
    device = torch.device("mps")
    train_data = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, 128, "train")
    valid_data = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, 128, "valid")
    train_fingerprint, train_sources = source_fingerprint(train_data)
    valid_fingerprint, valid_sources = source_fingerprint(valid_data)
    if set(train_sources) & set(valid_sources):
        raise ValueError("source-level leakage between fit-train and inner validation")
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary_doc = json.loads(vocabulary_bytes)
    vocabulary = vocabulary_doc.get("labels") if isinstance(vocabulary_doc, dict) else None
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain exactly 229 unique ordered labels")
    for row in train_data.rows + valid_data.rows:
        index = row.get("classIndex")
        if not isinstance(index, int) or not 0 <= index < CLASS_COUNT or row.get("label") != vocabulary[index]:
            raise ValueError("direct teacher label disagrees with the ordered 229-symbol vocabulary")
    class_counts = torch.bincount(torch.tensor([int(row["classIndex"]) for row in train_data.rows]), minlength=CLASS_COUNT)
    if (class_counts == 0).any():
        raise ValueError("all 229 classes need fit-train direct teachers")

    generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=True, collate_fn=collate_trajectories, generator=generator)
    fit_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_trajectories)
    valid_loader = DataLoader(valid_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_trajectories)
    model = FirebirdOnlineTrajectoryClassifier().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-2)
    weights = class_counts.float().pow(-args.class_weight_power)
    weights = (weights / weights.mean()).to(device)
    run = {
        "model": "FirebirdOnlineTrajectoryClassifier",
        "task": "229-way isolated handwritten symbol classification",
        "architecture": "XY path + first differences + curvature proxy -> per-stroke bidirectional LSTM -> ordered stroke-sequence LSTMCell -> normalized 128D embedding -> 229-way classifier",
        "inputContract": {
            "source": "directly annotated InkML stroke groups",
            "coordinates": "group-centered, isotropically scaled, arc-length resampled to 128 points per stroke",
            "strokeOrder": "preserved from annotation trace order",
            "withinStrokeDirection": "preserved as distinct forward/reverse BiLSTM endpoint states",
            "derivedChannels": ["x", "y", "delta_x", "delta_y", "delta_delta_x", "delta_delta_y"],
            "physicalTiming": "not available in current XY-only InkML parser; no speed claim",
            "rasterOrImageInput": False,
        },
        "trainingObjective": "class-weighted cross entropy",
        "trainTeachersSHA256": sha256(args.teachers),
        "sourceSplitSHA256": sha256(args.source_split),
        "vocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
        "trainSourceFingerprint": train_fingerprint,
        "validSourceFingerprint": valid_fingerprint,
        "trainSourceCount": len(train_sources),
        "validSourceCount": len(valid_sources),
        "trainSymbolCount": len(train_data),
        "validSymbolCount": len(valid_data),
        "trainClassCounts": class_counts.tolist(),
        "optimizer": "AdamW", "learningRate": args.learning_rate, "weightDecay": 1e-2,
        "classWeightPower": args.class_weight_power, "seed": args.seed, "device": "MPS",
        "outerTestRead": False,
        "checkpointSelection": "independent inner-validation classifier/prototype Top-1 and Top-5; stop after patience epochs without any metric improvement",
        "validationRole": "inner development validation, not final independent evaluation",
        "aneStatus": "not measured; Core ML conversion and physical iPad execution are separate gates",
    }
    (args.output / "run.json").write_text(json.dumps(run, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    best = {name: -1.0 for name in ("classifierTop1", "classifierTop5", "fitPrototypeTop1", "fitPrototypeTop5")}
    stale_epochs = 0
    history_path = args.output / "metrics.jsonl"
    with history_path.open("x", encoding="utf-8") as history:
        for epoch in range(1, args.epochs + 1):
            model.train()
            loss_sum = 0.0
            count = 0
            for points, padding, targets, _ in train_loader:
                points = augment_trajectories(points, padding).to(device)
                padding = padding.to(device)
                targets = targets.to(device)
                logits, _ = model(points, padding)
                loss = F.cross_entropy(logits, targets, weight=weights)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
                optimizer.step()
                loss_sum += float(loss.detach().item()) * targets.numel()
                count += targets.numel()

            fit_embeddings, fit_labels = embed_dataset(model, fit_loader, device)
            centroids = direct_class_centroids(fit_embeddings.to(device), fit_labels.to(device))
            measured = evaluate(model, valid_loader, device, centroids)
            record = {
                "epoch": epoch,
                "trainLoss": loss_sum / count,
                "classifier": measured["classifier"],
                "fitTrainPrototype": measured["fitTrainPrototype"],
                "validationSourceIds": measured["validationSourceIds"],
                "validationTargets": measured["validationTargets"],
                "classifierPredictions": measured["classifierPredictions"],
                "fitPrototypePredictions": measured["fitPrototypePredictions"],
            }
            improved_any = False
            checkpoint = {"model": model.state_dict(), "optimizer": optimizer.state_dict(), "epoch": epoch,
                          "run": run, "metrics": record, "torchRngState": torch.get_rng_state()}
            for name, mode, metric in (
                ("classifierTop1", "classifier", "top1"), ("classifierTop5", "classifier", "top5"),
                ("fitPrototypeTop1", "fitTrainPrototype", "top1"), ("fitPrototypeTop5", "fitTrainPrototype", "top5"),
            ):
                value = float(record[mode][metric])
                if value > best[name]:
                    improved_any = True
                    best[name] = value
                    filename = f"best-{name.replace('fitPrototype', 'fit-prototype-').replace('classifier', 'classifier-').lower()}"
                    torch.save(checkpoint, args.output / f"{filename}.pt")
                    (args.output / f"{filename}.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            stale_epochs = 0 if improved_any else stale_epochs + 1
            record["earlyStoppingStaleEpochs"] = stale_epochs
            history.write(json.dumps(record, ensure_ascii=False) + "\n")
            history.flush()
            torch.save(checkpoint, args.output / "latest.pt")
            (args.output / "latest.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            compact = {
                "epoch": epoch, "trainLoss": record["trainLoss"],
                "classifier": {key: record["classifier"][key] for key in ("top1", "top5", "macroRecallSupportedClasses")},
                "fitTrainPrototype": {key: record["fitTrainPrototype"][key] for key in ("top1", "top5", "macroRecallSupportedClasses")},
                "staleEpochs": stale_epochs,
            }
            print(json.dumps(compact, ensure_ascii=False), flush=True)
            if stale_epochs >= args.patience:
                break
    summary = {"status": "EARLY_STOPPED" if epoch < args.epochs else "COMPLETED", "epochsRun": epoch,
               "bestInnerValidationMetrics": best, "outerTestRead": False, "run": run}
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
