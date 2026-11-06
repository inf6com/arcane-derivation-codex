#!/usr/bin/env python3
"""Train and evaluate parallel InkML X/Y/T and raster branches on inner validation."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import torch
from torch import Tensor, nn
from torch.nn import functional as F
from torch.utils.data import DataLoader

from firebird_temporal_fusion import FirebirdTemporalRasterFusion
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import CLASS_COUNT, RASTER_SIZE, direct_class_centroids, rasterize_group

POINT_COUNT = 128


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def collate_temporal(samples: list[dict[str, object]]):
    if not samples:
        raise ValueError("cannot collate an empty temporal batch")
    groups = [sample["points"] for sample in samples]
    if not all(isinstance(group, Tensor) and group.ndim == 3 and group.shape[1:] == (POINT_COUNT, 5) for group in groups):
        raise ValueError("each teacher must carry [stroke,128,(x,y,strokePhase,symbolTimePhase,durationRatio)]")
    raster_groups = [sample.get("rasterPoints") for sample in samples]
    if not all(isinstance(group, Tensor) and group.ndim == 3 and group.shape[1:] == (POINT_COUNT, 2) for group in raster_groups):
        raise ValueError("each temporal teacher must retain its matching arc-length-resampled raster coordinates")
    max_strokes = max(group.shape[0] for group in groups)
    temporal = torch.zeros((len(groups), max_strokes, POINT_COUNT, 5), dtype=torch.float32)
    padding = torch.ones((len(groups), max_strokes), dtype=torch.bool)
    images = []
    for row, group in enumerate(groups):
        temporal[row, :group.shape[0]] = group
        padding[row, :group.shape[0]] = False
        images.append(rasterize_group(raster_groups[row]))
    return (
        torch.stack(images), temporal, padding,
        torch.tensor([int(sample["classIndex"]) for sample in samples], dtype=torch.int64),
        [str(sample["sourceSampleId"]) for sample in samples],
    )


def augment_paired(images: Tensor, temporal: Tensor) -> tuple[Tensor, Tensor]:
    """Apply one paired similarity transform to the raster and temporal XY only."""
    batch = images.shape[0]
    angle = (torch.rand(batch, dtype=images.dtype) * 2 - 1) * 0.08
    scale = 0.90 + torch.rand(batch, dtype=images.dtype) * 0.20
    translate = torch.rand((batch, 2), dtype=images.dtype) * 0.12 - 0.06
    cosine, sine = torch.cos(angle), torch.sin(angle)
    theta = torch.zeros((batch, 2, 3), dtype=images.dtype)
    theta[:, 0, 0], theta[:, 0, 1] = cosine * scale, -sine * scale
    theta[:, 1, 0], theta[:, 1, 1] = sine * scale, cosine * scale
    theta[:, :, 2] = translate
    grid = F.affine_grid(theta, images.shape, align_corners=False)
    augmented_images = F.grid_sample(images, grid, mode="bilinear", padding_mode="zeros", align_corners=False)
    xy = temporal[..., :2] - translate[:, None, None, :]
    x = (cosine[:, None, None] * xy[..., 0] + sine[:, None, None] * xy[..., 1]) / scale[:, None, None]
    y = (-sine[:, None, None] * xy[..., 0] + cosine[:, None, None] * xy[..., 1]) / scale[:, None, None]
    transformed = torch.cat((torch.stack((x, y), dim=-1), temporal[..., 2:]), dim=-1)
    return augmented_images, transformed


def summarize(logits: Tensor, labels: Tensor) -> dict[str, object]:
    if logits.ndim != 2 or logits.shape[1] != CLASS_COUNT or labels.shape != (len(logits),):
        raise ValueError("evaluation is not a 229-class isolated-symbol comparison")
    top = logits.topk(5, dim=1).indices
    predicted = top[:, 0]
    matrix = torch.bincount(labels * CLASS_COUNT + predicted, minlength=CLASS_COUNT**2).reshape(CLASS_COUNT, CLASS_COUNT)
    support = matrix.sum(1)
    present = support > 0
    return {
        "count": int(labels.numel()),
        "top1": float((predicted == labels).float().mean().item()),
        "top5": float((top == labels[:, None]).any(1).float().mean().item()),
        "macroRecallSupportedClasses": float((matrix.diag()[present].double() / support[present]).mean().item()),
        "supportedClassCount": int(present.sum().item()),
        "classSupport": support.tolist(),
        "confusionMatrix": matrix.tolist(),
    }


def source_fingerprint(dataset):
    sources = sorted({str(row["sourceSampleId"]) for row in dataset.rows})
    return hashlib.sha256("\n".join(sources).encode()).hexdigest(), sources


@torch.inference_mode()
def evaluate(model, loader, device, prototypes=None):
    model.eval()
    fused_parts, raster_parts, temporal_parts, embeddings, labels, sources = [], [], [], [], [], []
    for images, points, padding, target, source_ids in loader:
        fused, embedding, raster, temporal = model(images.to(device), points.to(device), padding.to(device))
        fused_parts.append(fused.cpu())
        raster_parts.append(raster.cpu())
        temporal_parts.append(temporal.cpu())
        embeddings.append(embedding.cpu())
        labels.append(target)
        sources.extend(source_ids)
    target = torch.cat(labels)
    results = {
        "fusedClassifier": summarize(torch.cat(fused_parts), target),
        "rasterBranch": summarize(torch.cat(raster_parts), target),
        "temporalBranch": summarize(torch.cat(temporal_parts), target),
    }
    if prototypes is not None:
        prototype_logits = torch.cat(embeddings).to(device) @ prototypes.T
        results["fusedFitPrototype"] = summarize(prototype_logits.cpu(), target)
    return results, sources, target.tolist(), torch.cat(fused_parts).argmax(1).tolist()


@torch.inference_mode()
def fit_prototypes(model, loader, device):
    model.eval()
    embeddings, labels = [], []
    for images, points, padding, target, _ in loader:
        embeddings.append(model.encode(images.to(device), points.to(device), padding.to(device)).cpu())
        labels.append(target)
    return direct_class_centroids(torch.cat(embeddings).to(device), torch.cat(labels).to(device))


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
    parser.add_argument("--seed", type=int, default=20261120)
    parser.add_argument("--class-weight-power", type=float, default=0.5)
    parser.add_argument("--resume", action="store_true", help="continue this run from its latest.pt checkpoint")
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0 or not 0 <= args.class_weight_power <= 1:
        raise ValueError("training settings are invalid")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited")
    if args.output.exists() and any(args.output.iterdir()) and not args.resume:
        raise FileExistsError(f"refusing to overwrite an existing experiment: {args.output}")
    if args.resume and (not args.output.is_dir() or not (args.output / "latest.pt").is_file() or not (args.output / "metrics.jsonl").is_file()):
        raise FileNotFoundError("--resume requires an existing output directory with latest.pt and metrics.jsonl")
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
    vocabulary_doc = json.loads(vocabulary_bytes)
    labels = vocabulary_doc.get("labels") if isinstance(vocabulary_doc, dict) else None
    if not isinstance(labels, list) or len(labels) != CLASS_COUNT or len(set(labels)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain 229 unique ordered symbol labels")
    for row in train_data.rows + valid_data.rows:
        index = row.get("classIndex")
        if not isinstance(index, int) or not 0 <= index < CLASS_COUNT or row.get("label") != labels[index]:
            raise ValueError("direct-teacher class index does not match the fixed vocabulary")
    counts = torch.bincount(torch.tensor([int(row["classIndex"]) for row in train_data.rows]), minlength=CLASS_COUNT)
    if (counts == 0).any():
        raise ValueError("all 229 classes require fit-train examples")
    generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=True, collate_fn=collate_temporal, generator=generator)
    fit_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_temporal)
    valid_loader = DataLoader(valid_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_temporal)
    model = FirebirdTemporalRasterFusion().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-2)
    weights = (counts.float().pow(-args.class_weight_power) / counts.float().pow(-args.class_weight_power).mean()).to(device)
    run = {
        "model": "FirebirdMotionDirectionRasterFusionCandidate",
        "task": "229-way isolated handwritten symbol classification",
        "architecture": "parallel residual raster CNN and per-stroke BiGRU over time-resampled X/Y/T-derived features, followed by chronological stroke GRU and learned late fusion",
        "temporalInput": "InkML traceFormat X/Y/T; point order retained; timestamp jitter corrected by cumulative maximum without reordering points; duplicate times collapsed; XY normalized over the annotated symbol; each stroke resampled uniformly in elapsed time; stroke-local phase, absolute symbol-relative time phase, and relative stroke duration retained; per-point pen direction is normalized delta(X,Y), and relative speed is Euclidean displacement divided by symbol-relative delta time; trace order retained",
        "trainingObjective": "weighted fused cross entropy plus 0.2 raster-branch and 0.2 temporal-branch cross entropy",
        "teachersSHA256": sha256(args.teachers),
        "sourceSplitSHA256": sha256(args.source_split),
        "vocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
        "trainSourceFingerprint": train_fingerprint,
        "validSourceFingerprint": valid_fingerprint,
        "trainSourceCount": len(train_sources), "validSourceCount": len(valid_sources),
        "trainSymbolCount": len(train_data), "validSymbolCount": len(valid_data),
        "trainClassCounts": counts.tolist(), "seed": args.seed,
        "optimizer": "AdamW", "learningRate": args.learning_rate, "weightDecay": 1e-2,
        "classWeightPower": args.class_weight_power, "device": "MPS",
        "outerTestRead": False,
        "validationRole": "inner validation for candidate selection; not final independent evaluation",
        "aneStatus": "not measured",
    }
    history_path = args.output / "metrics.jsonl"
    start_epoch = 1
    best = {name: -1.0 for name in ("fusedTop1", "fusedTop5", "prototypeTop1", "prototypeTop5")}
    if args.resume:
        prior_run = json.loads((args.output / "run.json").read_text(encoding="utf-8"))
        immutable_fields = ("model", "task", "teachersSHA256", "sourceSplitSHA256", "vocabularySHA256", "trainSourceFingerprint", "validSourceFingerprint", "trainSymbolCount", "validSymbolCount", "seed")
        if any(prior_run.get(field) != run.get(field) for field in immutable_fields):
            raise ValueError("resume inputs or model identity differ from the recorded experiment")
        checkpoint = torch.load(args.output / "latest.pt", map_location=device, weights_only=False)
        model.load_state_dict(checkpoint["model"], strict=True)
        optimizer.load_state_dict(checkpoint["optimizer"])
        if checkpoint.get("run", {}).get("model") != run["model"]:
            raise ValueError("latest checkpoint belongs to a different model candidate")
        previous_epoch = int(checkpoint["epoch"])
        start_epoch = previous_epoch + 1
        if start_epoch > args.epochs:
            raise ValueError(f"checkpoint is already at epoch {previous_epoch}; requested limit is {args.epochs}")
        torch.set_rng_state(checkpoint["torchRngState"])
        torch.mps.manual_seed(args.seed + start_epoch)
        generator.manual_seed(args.seed + start_epoch)
        for line in history_path.read_text(encoding="utf-8").splitlines():
            record = json.loads(line)
            for metric, section, key in (
                ("fusedTop1", "fusedClassifier", "top1"), ("fusedTop5", "fusedClassifier", "top5"),
                ("prototypeTop1", "fusedFitPrototype", "top1"), ("prototypeTop5", "fusedFitPrototype", "top5"),
            ):
                best[metric] = max(best[metric], float(record[section][key]))
        (args.output / "resume.json").write_text(json.dumps({"resumedFromEpoch": previous_epoch, "nextEpoch": start_epoch, "epochLimit": args.epochs, "mpsRandomStreamReseeded": True, "outerTestRead": False}, ensure_ascii=False, indent=2) + "\n")
    else:
        (args.output / "run.json").write_text(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    with history_path.open("a" if args.resume else "x", encoding="utf-8") as history:
        for epoch in range(start_epoch, args.epochs + 1):
            model.train()
            total_loss = 0.0
            total_count = 0
            for images, points, padding, targets, _ in train_loader:
                images, points = augment_paired(images, points)
                images, points, padding, targets = images.to(device), points.to(device), padding.to(device), targets.to(device)
                fused, _, raster, temporal = model(images, points, padding)
                loss = F.cross_entropy(fused, targets, weight=weights)
                loss = loss + 0.2 * F.cross_entropy(raster, targets, weight=weights) + 0.2 * F.cross_entropy(temporal, targets, weight=weights)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
                optimizer.step()
                total_loss += float(loss.detach().item()) * targets.numel()
                total_count += targets.numel()
            prototypes = fit_prototypes(model, fit_loader, device)
            measured, sources, target_ids, predictions = evaluate(model, valid_loader, device, prototypes)
            record = {
                "epoch": epoch,
                "trainLoss": total_loss / total_count,
                **measured,
                "validationSourceIds": sources,
                "validationTargets": target_ids,
                "fusedPredictions": predictions,
            }
            history.write(json.dumps(record, ensure_ascii=False) + "\n")
            history.flush()
            checkpoint = {"model": model.state_dict(), "optimizer": optimizer.state_dict(), "epoch": epoch, "run": run, "metrics": record, "torchRngState": torch.get_rng_state()}
            torch.save(checkpoint, args.output / "latest.pt")
            (args.output / "latest.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
            for metric, section, key in (
                ("fusedTop1", "fusedClassifier", "top1"), ("fusedTop5", "fusedClassifier", "top5"),
                ("prototypeTop1", "fusedFitPrototype", "top1"), ("prototypeTop5", "fusedFitPrototype", "top5"),
            ):
                score = float(record[section][key])
                if score > best[metric]:
                    best[metric] = score
                    suffix = metric.replace("prototype", "prototype-").replace("fused", "fused-").lower()
                    torch.save(checkpoint, args.output / f"best-{suffix}.pt")
                    (args.output / f"best-{suffix}.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps({"epoch": epoch, "trainLoss": record["trainLoss"], "fused": {k: record["fusedClassifier"][k] for k in ("top1", "top5")}, "rasterOnly": {k: record["rasterBranch"][k] for k in ("top1", "top5")}, "temporalOnly": {k: record["temporalBranch"][k] for k in ("top1", "top5")}, "fusedFitPrototype": {k: record["fusedFitPrototype"][k] for k in ("top1", "top5")}}, ensure_ascii=False), flush=True)
    (args.output / "summary.json").write_text(json.dumps({"status": "COMPLETED", "epochs": args.epochs, "bestInnerValidationMetrics": best, "outerTestRead": False, "run": run}, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
