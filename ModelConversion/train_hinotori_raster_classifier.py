#!/usr/bin/env python3
"""Train/evaluate the order-invariant 229-class Hinotori raster model.

The source-disjoint ``valid`` source partition selects checkpoints and is a
development metric, not a final test score. The checkpoint contains the exact
split fingerprint and per-class confusion evidence needed to reproduce it.
"""
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

from hinotori_direct_dataset import DirectAnchorDataset, collate_direct_anchors
from hinotori_raster_classifier import CLASS_COUNT, RASTER_SIZE, HinotoriMobileRasterClassifier, HinotoriRasterClassifier, HinotoriScaleSpaceClassifier, HinotoriSEClassifier, HinotoriStrokeSetClassifier, rasterize_group

POINT_COUNT = 128


def collate_rasters(samples: list[dict[str, object]]) -> tuple[Tensor, Tensor, list[str]]:
    batch = collate_direct_anchors(samples)
    points = batch["points"]
    stroke_padding = batch["strokePadding"]
    labels = batch["classIndices"]
    sources = batch["sourceSampleIds"]
    if (
        not isinstance(points, Tensor)
        or not isinstance(stroke_padding, Tensor)
        or stroke_padding.shape != points.shape[:2]
        or stroke_padding.dtype != torch.bool
        or not isinstance(labels, Tensor)
        or not isinstance(sources, list)
    ):
        raise TypeError("direct-anchor batch has an invalid schema")
    # ``collate_direct_anchors`` pads variable stroke counts with an all-zero
    # stroke. Remove those entries before rasterization: zero is a valid
    # canonical coordinate, so rasterize_group cannot infer padding from data.
    images = torch.stack([
        rasterize_group(group[~stroke_padding[row]])
        for row, group in enumerate(points)
    ])
    return images, labels, sources


def collate_stroke_set(samples: list[dict[str, object]]) -> tuple[tuple[Tensor, Tensor, Tensor, Tensor], Tensor, list[str]]:
    batch = collate_direct_anchors(samples)
    points = batch["points"]
    padding = batch["strokePadding"]
    labels = batch["classIndices"]
    sources = batch["sourceSampleIds"]
    if not isinstance(points, Tensor) or not isinstance(padding, Tensor) or padding.dtype != torch.bool:
        raise TypeError("direct-anchor stroke batch has an invalid schema")
    if points.ndim != 4 or points.shape[2:] != (POINT_COUNT, 2) or padding.shape != points.shape[:2]:
        raise ValueError("direct-anchor trajectories do not match the 128-point stroke contract")
    if not torch.isfinite(points).all() or padding.all(dim=1).any():
        raise ValueError("stroke-set batch contains non-finite coordinates or an empty symbol")
    images = torch.stack([rasterize_group(group[~padding[row]]) for row, group in enumerate(points)])
    valid = (~padding).to(torch.float32)
    inputs = (images, points, points.flip(dims=(2,)), valid)
    return inputs, labels, sources


def augment_rasters(images: Tensor) -> Tensor:
    """Apply small label-preserving affine variation to training rasters only."""
    if images.ndim != 4 or images.shape[1:] != (1, RASTER_SIZE, RASTER_SIZE):
        raise ValueError(f"images must have shape [batch,1,{RASTER_SIZE},{RASTER_SIZE}]")
    batch_size = images.shape[0]
    angle = (torch.rand(batch_size, dtype=images.dtype) * 2.0 - 1.0) * 0.08
    scale = 0.90 + torch.rand(batch_size, dtype=images.dtype) * 0.20
    translate = torch.rand((batch_size, 2), dtype=images.dtype) * 0.12 - 0.06
    cosine, sine = torch.cos(angle) * scale, torch.sin(angle) * scale
    theta = torch.zeros((batch_size, 2, 3), dtype=images.dtype)
    theta[:, 0, 0], theta[:, 0, 1] = cosine, -sine
    theta[:, 1, 0], theta[:, 1, 1] = sine, cosine
    theta[:, :, 2] = translate
    grid = nn.functional.affine_grid(theta, images.shape, align_corners=False)
    return nn.functional.grid_sample(images, grid, mode="bilinear", padding_mode="zeros", align_corners=False)


def augment_stroke_set(inputs: tuple[Tensor, Tensor, Tensor, Tensor]) -> tuple[Tensor, Tensor, Tensor, Tensor]:
    """Apply the same sampled affine transform to raster and trajectory inputs."""
    images, points, reversed_points, valid = inputs
    if points.ndim != 4 or points.shape != reversed_points.shape or points.shape[0] != images.shape[0] or points.shape[-2:] != (POINT_COUNT, 2):
        raise ValueError("stroke-set augmentation requires paired [batch,stroke,128,2] coordinates")
    batch_size = images.shape[0]
    angle = (torch.rand(batch_size, dtype=images.dtype) * 2.0 - 1.0) * 0.08
    scale = 0.90 + torch.rand(batch_size, dtype=images.dtype) * 0.20
    translate = torch.rand((batch_size, 2), dtype=images.dtype) * 0.12 - 0.06
    cosine, sine = torch.cos(angle), torch.sin(angle)
    theta = torch.zeros((batch_size, 2, 3), dtype=images.dtype)
    theta[:, 0, 0], theta[:, 0, 1] = cosine * scale, -sine * scale
    theta[:, 1, 0], theta[:, 1, 1] = sine * scale, cosine * scale
    theta[:, :, 2] = translate
    grid = nn.functional.affine_grid(theta, images.shape, align_corners=False)
    augmented_images = nn.functional.grid_sample(images, grid, mode="bilinear", padding_mode="zeros", align_corners=False)

    def transform(coordinates: Tensor) -> Tensor:
        shifted = coordinates - translate[:, None, None, :]
        x = (cosine[:, None, None] * shifted[..., 0] + sine[:, None, None] * shifted[..., 1]) / scale[:, None, None]
        y = (-sine[:, None, None] * shifted[..., 0] + cosine[:, None, None] * shifted[..., 1]) / scale[:, None, None]
        return torch.stack((x, y), dim=-1)

    return augmented_images, transform(points), transform(reversed_points), valid


def move_inputs_to_device(inputs: Tensor | tuple[Tensor, ...], device: torch.device) -> Tensor | tuple[Tensor, ...]:
    if isinstance(inputs, tuple):
        return tuple(value.to(device) for value in inputs)
    return inputs.to(device)


def model_forward(model: nn.Module, inputs: Tensor | tuple[Tensor, ...]) -> tuple[Tensor, Tensor]:
    return model(*inputs) if isinstance(inputs, tuple) else model(inputs)


def supervised_contrastive_loss(embeddings: Tensor, labels: Tensor, temperature: float = 0.1) -> Tensor:
    """Pull same-label embeddings together and separate different labels in-batch."""
    if embeddings.ndim != 2 or labels.shape != (embeddings.shape[0],) or temperature <= 0:
        raise ValueError("embeddings, labels, or contrastive temperature are invalid")
    similarities = embeddings @ embeddings.transpose(0, 1) / temperature
    self_mask = torch.eye(labels.shape[0], dtype=torch.bool, device=labels.device)
    positive_mask = labels[:, None].eq(labels[None, :]) & ~self_mask
    denominator_mask = ~self_mask
    valid_anchors = positive_mask.any(dim=1)
    if not valid_anchors.any():
        raise ValueError("supervised contrastive batch has no same-class positive pair")
    similarities = similarities.masked_fill(~denominator_mask, float("-inf"))
    log_probabilities = similarities - torch.logsumexp(similarities, dim=1, keepdim=True)
    positive_log_probability = log_probabilities.masked_fill(~positive_mask, 0.0)
    positive_counts = positive_mask.sum(dim=1).clamp_min(1)
    per_anchor = -positive_log_probability.sum(dim=1) / positive_counts
    return per_anchor[valid_anchors].mean()


def evaluate(model: nn.Module, loader: DataLoader, device: torch.device) -> dict[str, object]:
    model.eval()
    confusion = torch.zeros((CLASS_COUNT, CLASS_COUNT), dtype=torch.int64)
    total = 0
    top1 = top5 = 0
    with torch.inference_mode():
        for inputs, labels, _ in loader:
            inputs = move_inputs_to_device(inputs, device)
            labels = labels.to(device)
            logits, _ = model_forward(model, inputs)
            top = logits.topk(5, dim=1).indices
            top1 += int((top[:, 0] == labels).sum().item())
            top5 += int((top == labels[:, None]).any(dim=1).sum().item())
            total += labels.numel()
            predicted = logits.argmax(1)
            flat = labels.cpu() * CLASS_COUNT + predicted.cpu()
            confusion += torch.bincount(flat, minlength=CLASS_COUNT * CLASS_COUNT).reshape(CLASS_COUNT, CLASS_COUNT)
    if total == 0:
        raise ValueError("source-disjoint validation partition is empty")
    support = confusion.sum(1)
    present = support > 0
    per_class_recall = torch.full((CLASS_COUNT,), float("nan"), dtype=torch.float64)
    per_class_recall[present] = confusion.diag()[present].double() / support[present]
    return {
        "sampleCount": total,
        "top1": top1 / total,
        "top5": top5 / total,
        "macroRecallSupportedClasses": float(per_class_recall[present].mean().item()),
        "supportedClassCount": int(present.sum().item()),
        "unsupportedClasses": torch.where(~present)[0].tolist(),
        "classSupport": support.tolist(),
        "confusionMatrix": confusion.tolist(),
    }


def split_fingerprint(dataset: DirectAnchorDataset) -> str:
    sources = sorted({str(row["sourceSampleId"]) for row in dataset.rows})
    return hashlib.sha256("\n".join(sources).encode("utf-8")).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--class-weight-power", type=float, default=0.0,
                        help="Training-only inverse-frequency exponent; 0 disables weighting, 0.5 gives inverse-square-root weights.")
    parser.add_argument("--supervised-contrastive-weight", type=float, default=0.0,
                        help="Add this multiple of supervised contrastive loss on the learned embedding; 0 disables it.")
    parser.add_argument("--architecture", choices=("residual", "mobilenet", "scale-space", "se-residual", "stroke-set"), default="residual")
    parser.add_argument("--teacher-checkpoint", type=Path,
                        help="Fit-only residual teacher checkpoint for knowledge distillation.")
    parser.add_argument("--distillation-weight", type=float, default=0.0,
                        help="Mix weight for teacher-to-student KL loss; requires --teacher-checkpoint.")
    parser.add_argument("--distillation-temperature", type=float, default=3.0)
    parser.add_argument("--seed", type=int, default=20261103)
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0 or not 0.0 <= args.class_weight_power <= 1.0 or not 0.0 <= args.supervised_contrastive_weight <= 1.0 or not 0.0 <= args.distillation_weight <= 1.0 or args.distillation_temperature <= 0:
        raise ValueError("epochs, batch size, and learning rate must be positive; loss weights must be in [0,1]")
    if (args.teacher_checkpoint is None) != (args.distillation_weight == 0.0):
        raise ValueError("a teacher checkpoint and positive distillation weight must be supplied together")
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; no CPU fallback is permitted for training")
    device = torch.device("mps")
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    if hasattr(torch.mps, "manual_seed"):
        torch.mps.manual_seed(args.seed)

    train_data = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, POINT_COUNT, "train")
    valid_data = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, POINT_COUNT, "valid")
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary_document = json.loads(vocabulary_bytes)
    vocabulary = vocabulary_document.get("labels") if isinstance(vocabulary_document, dict) else None
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or any(not isinstance(label, str) or not label for label in vocabulary):
        raise ValueError("vocabulary must contain exactly 229 nonempty ordered labels")
    if len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary labels must be unique")
    for row in train_data.rows + valid_data.rows:
        index, label = row.get("classIndex"), row.get("label")
        if not isinstance(index, int) or not 0 <= index < CLASS_COUNT or label != vocabulary[index]:
            raise ValueError(f"direct teacher class mapping disagrees with vocabulary: {row.get('sourceSampleId')}")
    train_sources = {str(row["sourceSampleId"]) for row in train_data.rows}
    valid_sources = {str(row["sourceSampleId"]) for row in valid_data.rows}
    overlap = train_sources & valid_sources
    if overlap:
        raise ValueError(f"source-level leakage between train and valid: {sorted(overlap)[:5]}")
    train_classes = {int(row["classIndex"]) for row in train_data.rows}
    if train_classes != set(range(CLASS_COUNT)):
        raise ValueError(f"training split does not cover all 229 classes: missing {sorted(set(range(CLASS_COUNT)) - train_classes)}")
    stroke_counts = [len(row.get("strokeIndices", [])) for row in train_data.rows + valid_data.rows]
    if any(count < 1 for count in stroke_counts):
        raise ValueError("fit and validation symbols must each contain at least one annotated stroke")
    max_strokes_in_fit_valid = max(stroke_counts)

    generator = torch.Generator().manual_seed(args.seed)
    collate_fn = collate_stroke_set if args.architecture == "stroke-set" else collate_rasters
    train_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=True, collate_fn=collate_fn, generator=generator)
    valid_loader = DataLoader(valid_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_fn)
    train_class_counts = torch.bincount(torch.tensor([int(row["classIndex"]) for row in train_data.rows]), minlength=CLASS_COUNT)
    if (train_class_counts == 0).any():
        raise ValueError("training split must contain every class before applying class weights")
    class_weights = train_class_counts.to(dtype=torch.float32).pow(-args.class_weight_power)
    class_weights = class_weights / class_weights.mean()
    class_weights = class_weights.to(device)
    model_type = {
        "residual": HinotoriRasterClassifier,
        "mobilenet": HinotoriMobileRasterClassifier,
        "scale-space": HinotoriScaleSpaceClassifier,
        "se-residual": HinotoriSEClassifier,
        "stroke-set": HinotoriStrokeSetClassifier,
    }[args.architecture]
    model = model_type().to(device)
    teacher = None
    teacher_sha256 = None
    if args.teacher_checkpoint is not None:
        teacher_bytes = args.teacher_checkpoint.read_bytes()
        teacher_sha256 = hashlib.sha256(teacher_bytes).hexdigest()
        teacher_document = torch.load(args.teacher_checkpoint, map_location="cpu", weights_only=False)
        teacher_run = teacher_document.get("run", {})
        if teacher_run.get("architecture") != "HinotoriRasterClassifier" or teacher_run.get("task") != "isolated_symbol_exact_classification":
            raise ValueError("distillation teacher must be a compatible HinotoriRasterClassifier checkpoint")
        if teacher_run.get("vocabularySHA256") != hashlib.sha256(vocabulary_bytes).hexdigest():
            raise ValueError("distillation teacher vocabulary differs from the current ordered 229-class vocabulary")
        if teacher_run.get("trainSourceFingerprint") != split_fingerprint(train_data):
            raise ValueError("distillation teacher was not trained on this exact fit-source partition")
        teacher = HinotoriRasterClassifier().to(device)
        teacher.load_state_dict(teacher_document["model"], strict=True)
        teacher.eval()
        for parameter in teacher.parameters():
            parameter.requires_grad_(False)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-2)
    args.output.mkdir(parents=True, exist_ok=True)
    history_path = args.output / "metrics.jsonl"
    metadata = {
        "architecture": model_type.__name__,
        "task": "isolated_symbol_exact_classification",
        "classCount": CLASS_COUNT,
        "vocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
        "classLabelsByIndex": vocabulary,
        "input": ({"kind": "global_binary_ink_raster_plus_order_invariant_stroke_set",
                   "rasterSize": RASTER_SIZE, "rasterChannels": 1,
                   "pointsPerStroke": POINT_COUNT, "pointChannels": 2,
                   "maxStrokesInFitAndValidation": max_strokes_in_fit_valid,
                   "strokeOrderEncoding": False, "strokeDirection": "forward/reverse embeddings are averaged",
                   "strokeAggregation": "masked mean and max"}
                  if args.architecture == "stroke-set" else
                  {"kind": "order_invariant_binary_ink_raster", "size": RASTER_SIZE, "channels": 1,
                   "trajectoryResamplingPointsPerStroke": POINT_COUNT,
                   "strokeOrderEncoding": False, "withinStrokeDirectionEncoding": False}),
        "learnedInputRepresentation": ("fine-near-middle-density ink scale-space; shared residual trunk; four-resolution gated pooling"
                                        if args.architecture == "scale-space" else
                                        "single binary ink raster; residual blocks with sample-conditioned squeeze-excitation channel gates"
                                        if args.architecture == "se-residual" else
                                        "raster-plus-stroke-set trajectory encoder with symmetric stroke-order and direction pooling"
                                        if args.architecture == "stroke-set" else "single binary ink raster"),
        "inferenceTarget": "Core ML conversion with measured physical-iPad ANE dispatch; ANE placement is not inferred from compute-unit preference",
        "trainAugmentation": {
            "kind": "per-sample affine transform",
            "rotationRadiansMaxAbs": 0.08,
            "scaleRange": [0.90, 1.10],
            "translationRangePerAxis": [-0.06, 0.06],
            "horizontalOrVerticalFlip": False,
        },
        "classWeighting": {
            "kind": "inverse_frequency_power",
            "power": args.class_weight_power,
            "normalization": "mean weight across the 229 training classes equals 1",
            "trainCountsByClassIndex": train_class_counts.tolist(),
        },
        "supervisedContrastiveLoss": {
            "weight": args.supervised_contrastive_weight,
            "temperature": 0.1,
            "positiveDefinition": "same class in current augmented training batch, excluding self",
        },
        "knowledgeDistillation": {
            "teacherSHA256": teacher_sha256,
            "weight": args.distillation_weight,
            "temperature": args.distillation_temperature,
            "sourcePartitionFingerprint": split_fingerprint(train_data) if teacher is not None else None,
        },
        "device": str(device),
        "seed": args.seed,
        "trainAnchorCount": len(train_data),
        "validAnchorCount": len(valid_data),
        "trainSourceCount": len(train_sources),
        "validSourceCount": len(valid_sources),
        "trainSourceFingerprint": split_fingerprint(train_data),
        "validSourceFingerprint": split_fingerprint(valid_data),
        "validRole": "checkpoint selection/development only; not a final test result",
    }
    (args.output / "run.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    best_top1 = -1.0
    best_epoch = 0
    best_top5 = -1.0
    best_top5_epoch = 0

    with history_path.open("a", encoding="utf-8") as history:
        for epoch in range(1, args.epochs + 1):
            model.train()
            cross_entropy_sum = 0.0
            objective_sum = 0.0
            distillation_sum = 0.0
            samples = 0
            for inputs, labels, _ in train_loader:
                inputs = augment_stroke_set(inputs) if isinstance(inputs, tuple) else augment_rasters(inputs)
                inputs = move_inputs_to_device(inputs, device)
                labels = labels.to(device)
                logits, embeddings = model_forward(model, inputs)
                cross_entropy = nn.functional.cross_entropy(logits, labels, weight=class_weights if args.class_weight_power > 0 else None)
                distillation_loss = torch.zeros((), dtype=logits.dtype, device=device)
                if teacher is not None:
                    with torch.no_grad():
                        teacher_logits, _ = teacher(inputs[0] if isinstance(inputs, tuple) else inputs)
                    temperature = args.distillation_temperature
                    distillation_loss = F.kl_div(
                        F.log_softmax(logits / temperature, dim=1),
                        F.softmax(teacher_logits / temperature, dim=1),
                        reduction="batchmean",
                    ) * temperature * temperature
                objective = (1.0 - args.distillation_weight) * cross_entropy + args.distillation_weight * distillation_loss
                if args.supervised_contrastive_weight > 0:
                    objective = objective + args.supervised_contrastive_weight * supervised_contrastive_loss(embeddings, labels)
                optimizer.zero_grad(set_to_none=True)
                objective.backward()
                optimizer.step()
                cross_entropy_sum += float(cross_entropy.detach().item()) * labels.numel()
                objective_sum += float(objective.detach().item()) * labels.numel()
                distillation_sum += float(distillation_loss.detach().item()) * labels.numel()
                samples += labels.numel()
            metrics = evaluate(model, valid_loader, device)
            record = {
                "epoch": epoch,
                "trainCrossEntropy": cross_entropy_sum / samples,
                "trainObjective": objective_sum / samples,
                "trainDistillationLoss": distillation_sum / samples,
                **metrics,
            }
            history.write(json.dumps(record, ensure_ascii=False) + "\n")
            history.flush()

            checkpoint = {
                "model": model.state_dict(),
                "optimizer": optimizer.state_dict(),
                "epoch": epoch,
                "bestTop1": max(best_top1, float(metrics["top1"])),
                "run": metadata,
                "metrics": record,
                "torchRngState": torch.get_rng_state(),
            }
            torch.save(checkpoint, args.output / "latest.pt")
            (args.output / "latest.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
            if float(metrics["top1"]) > best_top1:
                best_top1 = float(metrics["top1"])
                best_epoch = epoch
                torch.save(checkpoint, args.output / "best.pt")
                (args.output / "best.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
            if float(metrics["top5"]) > best_top5:
                best_top5 = float(metrics["top5"])
                best_top5_epoch = epoch
                torch.save(checkpoint, args.output / "best-top5.pt")
                (args.output / "best-top5.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
            print(json.dumps({key: record[key] for key in ("epoch", "trainCrossEntropy", "sampleCount", "top1", "top5", "macroRecallSupportedClasses", "supportedClassCount")}, ensure_ascii=False), flush=True)

    summary = {
        "selectionRule": "Preserve independent maxima for exact-class Top-1 and Top-5; do not infer one metric from the other.",
        "bestEpochByTop1": best_epoch,
        "bestTop1": best_top1,
        "bestTop1Checkpoint": str(args.output / "best.pt"),
        "top5AtBestTop1": json.loads((args.output / "best.json").read_text(encoding="utf-8"))["top5"],
        "bestEpochByTop5": best_top5_epoch,
        "bestTop5": best_top5,
        "bestTop5Checkpoint": str(args.output / "best-top5.pt"),
        "top1AtBestTop5": json.loads((args.output / "best-top5.json").read_text(encoding="utf-8"))["top1"],
        **metadata,
    }
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
