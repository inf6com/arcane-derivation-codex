#!/usr/bin/env python3
"""Train a trajectory auxiliary classifier while keeping the raster model primary."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import torch
from torch.nn import functional as F
from torch.utils.data import DataLoader

from firebird_temporal_fusion import (
    FirebirdMarginGatedTrajectoryAuxiliaryClassifier,
    FirebirdTrajectoryAuxiliaryClassifier,
)
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import CLASS_COUNT
from train_firebird_temporal_fusion import POINT_COUNT, augment_paired, collate_temporal


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def source_fingerprint(dataset) -> tuple[str, list[str]]:
    sources = sorted({str(row["sourceSampleId"]) for row in dataset.rows})
    return hashlib.sha256("\n".join(sources).encode()).hexdigest(), sources


def metrics(logits: torch.Tensor, targets: torch.Tensor) -> dict[str, object]:
    if logits.ndim != 2 or logits.shape != (targets.numel(), CLASS_COUNT):
        raise ValueError("expected aligned 229-way logits and targets")
    top = logits.topk(5, dim=1).indices
    return {
        "top1": float((top[:, 0] == targets).float().mean().item()),
        "top5": float((top == targets[:, None]).any(dim=1).float().mean().item()),
        "count": int(targets.numel()),
        "predictions": top[:, 0].tolist(),
    }


def reverse_stroke_directions(points: torch.Tensor, stroke_padding: torch.Tensor, probability: float) -> torch.Tensor:
    """Reverse point order per selected stroke without changing its raster or time-phase axis."""
    if points.ndim != 4 or points.shape[-1] != 5 or stroke_padding.shape != points.shape[:2]:
        raise ValueError("direction reversal requires aligned [batch,stroke,point,5] points and stroke padding")
    if not 0.0 <= probability <= 1.0:
        raise ValueError("direction-reversal probability must be in [0,1]")
    reverse = (torch.rand(points.shape[:2], device=points.device) < probability) & ~stroke_padding
    reversed_xy = points[..., :2].flip(dims=(2,))
    xy = torch.where(reverse[:, :, None, None], reversed_xy, points[..., :2])
    return torch.cat((xy, points[..., 2:]), dim=-1)


def reverse_all_stroke_directions(points: torch.Tensor, stroke_padding: torch.Tensor) -> torch.Tensor:
    if points.ndim != 4 or points.shape[-1] != 5 or stroke_padding.shape != points.shape[:2]:
        raise ValueError("direction reversal requires aligned [batch,stroke,point,5] points and stroke padding")
    reversed_xy = points[..., :2].flip(dims=(2,))
    xy = torch.where(stroke_padding[:, :, None, None], points[..., :2], reversed_xy)
    return torch.cat((xy, points[..., 2:]), dim=-1)


@torch.inference_mode()
def evaluate(model, loader, device) -> dict[str, object]:
    model.eval()
    primary_parts, final_parts, reversed_final_parts, targets, source_ids = [], [], [], [], []
    auxiliary_weights = []
    for images, points, padding, labels, sources in loader:
        final_logits, primary_logits, _, auxiliary_weight = model(
            images.to(device), points.to(device), padding.to(device)
        )
        reversed_points = reverse_all_stroke_directions(points, padding).to(device)
        reversed_final_logits, _, _, _ = model(images.to(device), reversed_points, padding.to(device))
        primary_parts.append(primary_logits.cpu())
        final_parts.append(final_logits.cpu())
        reversed_final_parts.append(reversed_final_logits.cpu())
        targets.append(labels)
        source_ids.extend(sources)
        auxiliary_weights.extend(auxiliary_weight.reshape(-1).cpu().tolist())
    target = torch.cat(targets)
    primary = metrics(torch.cat(primary_parts), target)
    final = metrics(torch.cat(final_parts), target)
    direction_reversed = metrics(torch.cat(reversed_final_parts), target)
    forward_prediction = torch.tensor(final["predictions"])
    reversed_prediction = torch.tensor(direction_reversed["predictions"])
    return {
        "mainOnly": primary,
        "withTrajectoryAuxiliary": final,
        "withTrajectoryAuxiliaryAllStrokesReversed": direction_reversed,
        "directionTop1Consistency": float((forward_prediction == reversed_prediction).float().mean().item()),
        "top1Delta": final["top1"] - primary["top1"],
        "top5Delta": final["top5"] - primary["top5"],
        "reversedDirectionTop1Delta": direction_reversed["top1"] - primary["top1"],
        "reversedDirectionTop5Delta": direction_reversed["top5"] - primary["top5"],
        "auxiliaryWeight": sum(auxiliary_weights) / len(auxiliary_weights),
        "auxiliaryWeightMin": min(auxiliary_weights),
        "auxiliaryWeightMax": max(auxiliary_weights),
        "sourceSampleIds": source_ids,
        "targets": target.tolist(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--primary-checkpoint", type=Path, required=True)
    parser.add_argument("--primary-metadata", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=40)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--seed", type=int, default=20261104)
    parser.add_argument("--class-weight-power", type=float, default=0.5)
    parser.add_argument("--reverse-direction-probability", type=float, default=0.5)
    parser.add_argument("--margin-gated-direction-symmetric", action="store_true")
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0 or not 0.0 <= args.reverse_direction_probability <= 1.0:
        raise ValueError("training settings are invalid")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited")
    for path in (args.teachers, args.source_split, args.vocabulary, args.primary_checkpoint, args.primary_metadata):
        if not path.is_file():
            raise FileNotFoundError(f"required input is missing: {path}")
    if args.output.exists() and any(args.output.iterdir()):
        raise FileExistsError(f"refusing to overwrite an existing experiment: {args.output}")
    args.output.mkdir(parents=True, exist_ok=True)
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.mps.manual_seed(args.seed)
    device = torch.device("mps")

    primary_meta = json.loads(args.primary_metadata.read_text(encoding="utf-8"))
    checkpoint = torch.load(args.primary_checkpoint, map_location="cpu", weights_only=False)
    expected = {
        "model": "HinotoriSpatialPyramidAngularMargin",
        "task": "229-way isolated handwritten symbol classification",
        "trainTeachersSHA256": sha256(args.teachers),
        "sourceSplitSHA256": sha256(args.source_split),
        "vocabularySHA256": sha256(args.vocabulary),
    }
    for key, value in expected.items():
        if primary_meta.get(key) != value:
            raise ValueError(f"primary checkpoint metadata mismatch for {key}: expected {value}, got {primary_meta.get(key)}")
    if int(checkpoint.get("epoch", -1)) != 26:
        raise ValueError("the selected primary checkpoint must be the recorded epoch-26 classifier checkpoint")
    if checkpoint.get("run", {}).get("model") != expected["model"]:
        raise ValueError("primary checkpoint model identity does not match its metadata")
    if checkpoint.get("run", {}).get("sourceSplitSHA256") != expected["sourceSplitSHA256"]:
        raise ValueError("primary checkpoint source split differs from the requested auxiliary experiment")

    train_data = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, POINT_COUNT, "train", temporal=True)
    valid_data = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, POINT_COUNT, "valid", temporal=True)
    train_fp, train_sources = source_fingerprint(train_data)
    valid_fp, valid_sources = source_fingerprint(valid_data)
    if set(train_sources) & set(valid_sources):
        raise ValueError("fit-train and inner-validation source IDs overlap")
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
    train_generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=True, collate_fn=collate_temporal, generator=train_generator)
    valid_loader = DataLoader(valid_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_temporal)

    if args.margin_gated_direction_symmetric:
        model = FirebirdMarginGatedTrajectoryAuxiliaryClassifier().to(device)
        effective_reverse_probability = 0.0
    else:
        model = FirebirdTrajectoryAuxiliaryClassifier().to(device)
        effective_reverse_probability = args.reverse_direction_probability
    model.primary_classifier.load_state_dict(checkpoint["model"], strict=True)
    for parameter in model.primary_classifier.parameters():
        parameter.requires_grad_(False)
    model.primary_classifier.eval()
    trainable = [parameter for parameter in model.parameters() if parameter.requires_grad]
    if not trainable or any(parameter.requires_grad for parameter in model.primary_classifier.parameters()):
        raise RuntimeError("primary image classifier must remain frozen while trajectory auxiliary parameters train")
    optimizer = torch.optim.AdamW(trainable, lr=args.learning_rate, weight_decay=1e-2)
    weights = counts.float().pow(-args.class_weight_power)
    weights = (weights / weights.mean()).to(device)
    run = {
        "model": "FirebirdMarginGatedTrajectoryAuxiliaryClassifierCandidate" if args.margin_gated_direction_symmetric else "FirebirdTrajectoryAuxiliaryClassifierCandidate",
        "task": "229-way isolated handwritten symbol classification",
        "roleContract": "frozen raster classifier is primary; whole-trajectory derivative-graph classifier contributes only a bounded auxiliary logit residual",
        "architecture": "epoch-26 HinotoriSpatialPyramidAngularMargin checkpoint is frozen in evaluation mode; a learned 128D ordered trajectory representation produces cosine class scores; " + ("forward and all-strokes-reversed trajectory scores are averaged, then a per-example sigmoid gate decreases auxiliary weight monotonically as the primary Top1-Top2 logit margin grows; weight is capped at 0.5" if args.margin_gated_direction_symmetric else "a trainable global sigmoid gate scales only the trajectory residual, capped at 0.5"),
        "trajectoryFeatures": "ordered p(t)=(x,y) and first derivative dp/dt=(dx/dt,dy/dt), stroke-local phase, symbol-relative time, and stroke duration; no second derivative; learned attention pools the complete point sequence per stroke followed by chronological stroke GRU",
        "directionTreatment": "trajectory scores average forward and all-strokes-reversed XY order, preserving the raster, stroke order, phase/time channels, and label; validation reports original and reversed inputs plus prediction consistency" if args.margin_gated_direction_symmetric else "training randomly reverses within-stroke XY point order while preserving each stroke's spatial trace, raster image, stroke order, increasing phase/time channels, and label; validation reports both original and all-strokes-reversed trajectory inputs plus prediction consistency",
        "marginGate": {"enabled": args.margin_gated_direction_symmetric, "definition": "g = (primaryTop1Logit - primaryTop2Logit) / 32; alpha = 0.5 * sigmoid(b - softplus(s) * g); finalLogits = primaryLogits + alpha * directionSymmetricTrajectoryLogits" if args.margin_gated_direction_symmetric else None, "initialBias": -2.1972246 if args.margin_gated_direction_symmetric else None, "initialSlopeRaw": 1.8545865 if args.margin_gated_direction_symmetric else None, "initialWeightAtZeroMargin": 0.05 if args.margin_gated_direction_symmetric else None},
        "trainingObjective": "class-weighted cross entropy on primary-plus-bounded-auxiliary final logits plus 0.2 class-weighted cross entropy on auxiliary scores; primary image parameters are frozen",
        "primaryCheckpoint": str(args.primary_checkpoint),
        "primaryCheckpointSHA256": sha256(args.primary_checkpoint),
        "primaryEpoch": int(checkpoint["epoch"]),
        "teachersSHA256": expected["trainTeachersSHA256"],
        "sourceSplitSHA256": expected["sourceSplitSHA256"],
        "vocabularySHA256": expected["vocabularySHA256"],
        "trainSourceFingerprint": train_fp,
        "validSourceFingerprint": valid_fp,
        "trainSourceCount": len(train_sources),
        "validSourceCount": len(valid_sources),
        "trainSymbolCount": len(train_data),
        "validSymbolCount": len(valid_data),
        "trainClassCounts": counts.tolist(),
        "seed": args.seed,
        "optimizer": "AdamW on trajectory encoder, class prototypes, and auxiliary gate only",
        "learningRate": args.learning_rate,
        "classWeightPower": args.class_weight_power,
        "reverseDirectionProbability": effective_reverse_probability,
        "device": "MPS",
        "outerTestRead": False,
        "validationRole": "inner validation for auxiliary contribution and epoch selection; not an independent final result",
        "standaloneTrajectoryEvaluation": False,
    }
    baseline = evaluate(model, valid_loader, device)
    run["epochZeroValidation"] = {
        key: baseline[key] for key in ("mainOnly", "withTrajectoryAuxiliary", "withTrajectoryAuxiliaryAllStrokesReversed", "directionTop1Consistency", "top1Delta", "top5Delta", "reversedDirectionTop1Delta", "reversedDirectionTop5Delta", "auxiliaryWeight", "auxiliaryWeightMin", "auxiliaryWeightMax")
    }
    (args.output / "run.json").write_text(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    history_path = args.output / "metrics.jsonl"
    best_scores = {"top1": -1.0, "top5": -1.0}
    with history_path.open("x", encoding="utf-8") as history:
        for epoch in range(1, args.epochs + 1):
            model.train()
            total_loss = 0.0
            count = 0
            for images, points, padding, targets, _ in train_loader:
                images, points = augment_paired(images, points)
                if not args.margin_gated_direction_symmetric:
                    points = reverse_stroke_directions(points, padding, args.reverse_direction_probability)
                images, points, padding, targets = images.to(device), points.to(device), padding.to(device), targets.to(device)
                final_logits, _, auxiliary_logits, _ = model(images, points, padding)
                loss = F.cross_entropy(final_logits, targets, weight=weights)
                loss = loss + 0.2 * F.cross_entropy(auxiliary_logits, targets, weight=weights)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(trainable, 5.0)
                optimizer.step()
                total_loss += float(loss.detach().item()) * targets.numel()
                count += targets.numel()
            measured = evaluate(model, valid_loader, device)
            record = {
                "epoch": epoch,
                "trainLoss": total_loss / count,
                "mainOnly": measured["mainOnly"],
                "withTrajectoryAuxiliary": measured["withTrajectoryAuxiliary"],
                "withTrajectoryAuxiliaryAllStrokesReversed": measured["withTrajectoryAuxiliaryAllStrokesReversed"],
                "directionTop1Consistency": measured["directionTop1Consistency"],
                "top1Delta": measured["top1Delta"],
                "top5Delta": measured["top5Delta"],
                "reversedDirectionTop1Delta": measured["reversedDirectionTop1Delta"],
                "reversedDirectionTop5Delta": measured["reversedDirectionTop5Delta"],
                "auxiliaryWeight": measured["auxiliaryWeight"],
                "auxiliaryWeightMin": measured["auxiliaryWeightMin"],
                "auxiliaryWeightMax": measured["auxiliaryWeightMax"],
                "validationSourceSampleIds": measured["sourceSampleIds"],
                "validationTargets": measured["targets"],
            }
            history.write(json.dumps(record, ensure_ascii=False) + "\n")
            history.flush()
            saved = {
                "model": model.state_dict(), "optimizer": optimizer.state_dict(), "epoch": epoch,
                "run": run, "metrics": record, "torchRngState": torch.get_rng_state(),
            }
            torch.save(saved, args.output / "latest.pt")
            (args.output / "latest.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
            for key in ("top1", "top5"):
                score = float(measured["withTrajectoryAuxiliary"][key])
                if score > best_scores[key]:
                    best_scores[key] = score
                    torch.save(saved, args.output / f"best-{key}.pt")
                    (args.output / f"best-{key}.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
            print(json.dumps({
                "epoch": epoch,
                "trainLoss": record["trainLoss"],
                "mainTop1": measured["mainOnly"]["top1"],
                "mainTop5": measured["mainOnly"]["top5"],
                "finalTop1": measured["withTrajectoryAuxiliary"]["top1"],
                "finalTop5": measured["withTrajectoryAuxiliary"]["top5"],
                "reversedFinalTop1": measured["withTrajectoryAuxiliaryAllStrokesReversed"]["top1"],
                "reversedFinalTop5": measured["withTrajectoryAuxiliaryAllStrokesReversed"]["top5"],
                "directionTop1Consistency": measured["directionTop1Consistency"],
                "top1Delta": measured["top1Delta"],
                "top5Delta": measured["top5Delta"],
                "auxiliaryWeight": measured["auxiliaryWeight"],
                "auxiliaryWeightMin": measured["auxiliaryWeightMin"],
                "auxiliaryWeightMax": measured["auxiliaryWeightMax"],
            }, ensure_ascii=False), flush=True)
    summary = {
        "status": "COMPLETED", "epochs": args.epochs,
        "primaryCheckpointSHA256": run["primaryCheckpointSHA256"],
        "primaryClassifierUpdated": False, "outerTestRead": False,
        "bestInnerValidationFinalTop1": best_scores["top1"],
        "bestInnerValidationFinalTop5": best_scores["top5"],
        "selectionWarning": "Inner-validation best is development-only and is not an independent final performance estimate.",
        "run": run,
    }
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
