#!/usr/bin/env python3
"""Compare a classifier head with fit-only cosine class prototypes.

The source-disjoint validation partition is for method selection only. This
script does not inspect a test partition and refuses source overlap.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

try:
    from ModelConversion.hinotori_direct_dataset import DirectAnchorDataset
    from ModelConversion.hinotori_raster_classifier import (
        HinotoriMobileRasterClassifier,
        HinotoriRasterClassifier,
        HinotoriScaleSpaceClassifier,
        HinotoriSEClassifier,
        HinotoriStrokeSetClassifier,
    )
    from ModelConversion.train_hinotori_raster_classifier import (
        collate_rasters,
        collate_stroke_set,
        model_forward,
        split_fingerprint,
    )
except ImportError:
    from hinotori_direct_dataset import DirectAnchorDataset
    from hinotori_raster_classifier import (
        HinotoriMobileRasterClassifier,
        HinotoriRasterClassifier,
        HinotoriScaleSpaceClassifier,
        HinotoriSEClassifier,
        HinotoriStrokeSetClassifier,
    )
    from train_hinotori_raster_classifier import (
        collate_rasters,
        collate_stroke_set,
        model_forward,
        split_fingerprint,
    )


MODEL_TYPES = {
    "HinotoriRasterClassifier": HinotoriRasterClassifier,
    "HinotoriMobileRasterClassifier": HinotoriMobileRasterClassifier,
    "HinotoriScaleSpaceClassifier": HinotoriScaleSpaceClassifier,
    "HinotoriSEClassifier": HinotoriSEClassifier,
    "HinotoriStrokeSetClassifier": HinotoriStrokeSetClassifier,
}
BLEND_WEIGHTS = tuple(index / 10 for index in range(11))


def collect(
    model: torch.nn.Module,
    teachers: Path,
    source_split: Path,
    dataset_root: Path,
    split: str,
    stroke_set: bool,
) -> tuple[np.ndarray, list[str], np.ndarray, np.ndarray]:
    dataset = DirectAnchorDataset(teachers, source_split, dataset_root, 128, split)
    loader = DataLoader(
        dataset,
        batch_size=32,
        shuffle=False,
        collate_fn=collate_stroke_set if stroke_set else collate_rasters,
    )
    labels: list[np.ndarray] = []
    sources: list[str] = []
    logits: list[np.ndarray] = []
    embeddings: list[np.ndarray] = []
    with torch.inference_mode():
        for inputs, target, source_ids in loader:
            scores, vectors = model_forward(model, inputs)
            labels.append(target.cpu().numpy())
            sources.extend(source_ids)
            logits.append(scores.cpu().numpy())
            embeddings.append(vectors.cpu().numpy())
    return (
        np.concatenate(labels),
        sources,
        np.concatenate(logits),
        np.concatenate(embeddings),
    )


def metrics(scores: np.ndarray, targets: np.ndarray) -> dict[str, float]:
    order = np.argsort(-scores, axis=1)
    return {
        "top1": float(np.mean(order[:, 0] == targets)),
        "top5": float(np.mean([int(target) in row[:5] for target, row in zip(targets, order, strict=True)])),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument(
        "--prototype-directory",
        type=Path,
        help="Optional new directory for an atomic fit-only float32 class-prototype artifact.",
    )
    args = parser.parse_args()
    if args.report.exists():
        raise FileExistsError(f"refusing to overwrite report: {args.report}")
    if args.prototype_directory is not None and args.prototype_directory.exists():
        raise FileExistsError(f"refusing to overwrite prototype artifact: {args.prototype_directory}")

    raw_checkpoint = args.checkpoint.read_bytes()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    run = checkpoint.get("run")
    if not isinstance(run, dict) or run.get("task") != "isolated_symbol_exact_classification":
        raise ValueError("checkpoint does not declare isolated-symbol exact classification")
    if run.get("classCount") != 229:
        raise ValueError("checkpoint must declare exactly 229 classes")
    model_type = MODEL_TYPES.get(run.get("architecture"))
    if model_type is None:
        raise ValueError(f"unsupported architecture: {run.get('architecture')!r}")
    vocabulary = run.get("classLabelsByIndex")
    if not isinstance(vocabulary, list) or len(vocabulary) != 229 or len(set(vocabulary)) != 229:
        raise ValueError("checkpoint must contain 229 unique ordered class labels")

    model = model_type().eval()
    model.load_state_dict(checkpoint["model"], strict=True)
    stroke_set = run["architecture"] == "HinotoriStrokeSetClassifier"
    fit_y, fit_sources, fit_logits, fit_embeddings = collect(
        model, args.teachers, args.source_split, args.dataset_root, "train", stroke_set
    )
    valid_y, valid_sources, valid_logits, valid_embeddings = collect(
        model, args.teachers, args.source_split, args.dataset_root, "valid", stroke_set
    )
    fit_fingerprint = split_fingerprint(
        DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "train")
    )
    valid_fingerprint = split_fingerprint(
        DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "valid")
    )
    if fit_fingerprint != run.get("trainSourceFingerprint"):
        raise ValueError("fit source fingerprint differs from checkpoint")
    if valid_fingerprint != run.get("validSourceFingerprint"):
        raise ValueError("validation source fingerprint differs from checkpoint")
    overlap = set(fit_sources) & set(valid_sources)
    if overlap:
        raise ValueError(f"fit/validation source overlap: {sorted(overlap)[:3]}")
    if fit_logits.shape != (len(fit_y), 229) or valid_logits.shape != (len(valid_y), 229):
        raise ValueError("checkpoint emitted logits with an invalid shape")
    if fit_embeddings.ndim != 2 or valid_embeddings.shape[1] != fit_embeddings.shape[1]:
        raise ValueError("checkpoint emitted incompatible embedding dimensions")
    if not np.isfinite(fit_logits).all() or not np.isfinite(valid_logits).all():
        raise ValueError("checkpoint emitted non-finite class scores")
    if not np.isfinite(fit_embeddings).all() or not np.isfinite(valid_embeddings).all():
        raise ValueError("checkpoint emitted non-finite embeddings")

    centroids = np.stack([fit_embeddings[fit_y == index].mean(axis=0) for index in range(229)])
    support = np.bincount(fit_y, minlength=229)
    if (support == 0).any():
        missing = [vocabulary[index] for index in np.flatnonzero(support == 0)]
        raise ValueError(f"fit split has no samples for classes: {missing}")
    centroids /= np.maximum(np.linalg.norm(centroids, axis=1, keepdims=True), 1e-12)
    cosine_scores = valid_embeddings @ centroids.T
    logit_span = float(np.median(np.ptp(valid_logits, axis=1)))
    cosine_span = float(np.median(np.ptp(cosine_scores, axis=1)))
    if not np.isfinite(logit_span) or not np.isfinite(cosine_span) or cosine_span <= 0:
        raise ValueError("cannot calibrate score scales from finite fit/validation outputs")
    scaled_cosine = cosine_scores * (logit_span / cosine_span)

    sweep = []
    for weight in BLEND_WEIGHTS:
        combined = (1.0 - weight) * valid_logits + weight * scaled_cosine
        sweep.append({"prototypeWeight": weight, **metrics(combined, valid_y)})
    report = {
        "format": "hinotori-fit-embedding-prototype-comparison-v1",
        "task": "229-class isolated-symbol exact classification",
        "checkpoint": str(args.checkpoint),
        "checkpointSHA256": hashlib.sha256(raw_checkpoint).hexdigest(),
        "architecture": run["architecture"],
        "epoch": checkpoint.get("metrics", {}).get("epoch"),
        "fitSamples": len(fit_y),
        "validationSamples": len(valid_y),
        "fitSourceFingerprint": fit_fingerprint,
        "validationSourceFingerprint": valid_fingerprint,
        "sourceOverlap": 0,
        "embeddingDimension": int(fit_embeddings.shape[1]),
        "prototypeDefinition": "Per-class arithmetic mean of fit embeddings, then L2 normalization; cosine similarity to the validation query embedding.",
        "scoreScale": {
            "method": "median validation logit span divided by median validation cosine-score span; labels are not used",
            "cosineMultiplier": logit_span / cosine_span,
        },
        "blendWeightsEvaluatedOnInnerValidation": list(BLEND_WEIGHTS),
        "sweepOnInnerValidationOnly": sweep,
        "classifierOnly": sweep[0],
        "prototypeOnly": sweep[-1],
        "fitClassSupportMin": int(support.min()),
        "fitClassSupportMax": int(support.max()),
        "zeroFitClassCount": int((support == 0).sum()),
        "validationRole": "method selection only; not a final test result",
        "outerTestRead": False,
    }
    prototype_artifact = None
    if args.prototype_directory is not None:
        destination = args.prototype_directory
        destination.parent.mkdir(parents=True, exist_ok=True)
        prototype_bytes = np.asarray(centroids, dtype="<f4", order="C").tobytes(order="C")
        prototype_digest = hashlib.sha256(prototype_bytes).hexdigest()
        prototype_manifest = {
            "format": "hinotori-fit-class-embedding-prototypes-v1",
            "task": "isolated_symbol_exact_class_similarity",
            "checkpointSHA256": hashlib.sha256(raw_checkpoint).hexdigest(),
            "architecture": run["architecture"],
            "epoch": checkpoint.get("metrics", {}).get("epoch"),
            "prototypeDefinition": "Arithmetic mean of fit-only embeddings for each class, followed by L2 normalization.",
            "prototypeFile": "class-prototypes.f32le",
            "prototypeSHA256": prototype_digest,
            "dtype": "float32-little-endian",
            "shape": [229, int(fit_embeddings.shape[1])],
            "embeddingDimension": int(fit_embeddings.shape[1]),
            "classCount": 229,
            "classSupport": support.astype(int).tolist(),
            "classLabelsByIndex": vocabulary,
            "vocabularySHA256": run.get("vocabularySHA256"),
            "fitSampleCount": int(len(fit_y)),
            "fitSourceFingerprint": fit_fingerprint,
            "validationSourceFingerprint": valid_fingerprint,
            "sourceOverlap": 0,
            "validationUsedToConstructPrototypes": False,
            "outerTestRead": False,
        }
        with tempfile.TemporaryDirectory(prefix=f".{destination.name}.", dir=destination.parent) as temporary:
            staged = Path(temporary) / destination.name
            staged.mkdir()
            (staged / "class-prototypes.f32le").write_bytes(prototype_bytes)
            manifest_bytes = (json.dumps(prototype_manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            (staged / "manifest.json").write_bytes(manifest_bytes)
            if hashlib.sha256((staged / "class-prototypes.f32le").read_bytes()).hexdigest() != prototype_digest:
                raise IOError("staged prototype binary hash mismatch")
            os.rename(staged, destination)
        prototype_artifact = str(destination)
        report["fitPrototypeArtifact"] = {
            "directory": prototype_artifact,
            "manifest": str(destination / "manifest.json"),
            "binary": str(destination / "class-prototypes.f32le"),
            "sha256": prototype_digest,
        }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "report": str(args.report),
        "checkpointSHA256": report["checkpointSHA256"],
        "fitSamples": len(fit_y),
        "validationSamples": len(valid_y),
        "classifierOnly": sweep[0],
        "prototypeOnly": sweep[-1],
        "sourceOverlap": 0,
        "fitPrototypeArtifact": prototype_artifact,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
