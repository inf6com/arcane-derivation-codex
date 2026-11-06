#!/usr/bin/env python3
"""Check Core ML/PyTorch parity on the source-disjoint inner validation set."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
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
        EMBEDDING_DIMENSION,
    )
    from ModelConversion.train_hinotori_raster_classifier import collate_rasters, collate_stroke_set, model_forward, split_fingerprint
except ImportError:
    from hinotori_direct_dataset import DirectAnchorDataset
    from hinotori_raster_classifier import (
        HinotoriMobileRasterClassifier,
        HinotoriRasterClassifier,
        HinotoriScaleSpaceClassifier,
        HinotoriSEClassifier,
        HinotoriStrokeSetClassifier,
        EMBEDDING_DIMENSION,
    )
    from train_hinotori_raster_classifier import collate_rasters, collate_stroke_set, model_forward, split_fingerprint


MODEL_TYPES = {
    "HinotoriRasterClassifier": HinotoriRasterClassifier,
    "HinotoriMobileRasterClassifier": HinotoriMobileRasterClassifier,
    "HinotoriScaleSpaceClassifier": HinotoriScaleSpaceClassifier,
    "HinotoriSEClassifier": HinotoriSEClassifier,
    "HinotoriStrokeSetClassifier": HinotoriStrokeSetClassifier,
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        raise FileExistsError(f"refusing to overwrite parity report: {args.report}")
    checkpoint_bytes = args.checkpoint.read_bytes()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    run = checkpoint.get("run", {})
    if manifest.get("checkpointSHA256") != hashlib.sha256(checkpoint_bytes).hexdigest():
        raise ValueError("Core ML manifest checkpoint hash does not match the supplied checkpoint")
    if manifest.get("format") != "hinotori-raster-symbol-coreml-v2" or manifest.get("architecture") != run.get("architecture"):
        raise ValueError("Core ML manifest and checkpoint model contracts differ")
    outputs = manifest.get("output")
    if not isinstance(outputs, dict) or set(outputs) != {"classLogits", "queryEmbedding"}:
        raise ValueError("Core ML manifest must declare both classLogits and queryEmbedding")
    if outputs["classLogits"].get("shape") != [1, 229] or outputs["queryEmbedding"].get("shape") != [1, EMBEDDING_DIMENSION]:
        raise ValueError("Core ML manifest output shapes do not match the 229-class and embedding contract")
    model_type = MODEL_TYPES.get(run.get("architecture"))
    if model_type is None:
        raise ValueError(f"unsupported checkpoint architecture: {run.get('architecture')!r}")
    data = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "valid")
    if split_fingerprint(data) != run.get("validSourceFingerprint"):
        raise ValueError("inner-validation source fingerprint differs from training checkpoint")
    stroke_set = run["architecture"] == "HinotoriStrokeSetClassifier"
    fixed_stroke_count = (
        run.get("input", {}).get("maxStrokesInFitAndValidation") if stroke_set else None
    )
    if stroke_set and (not isinstance(fixed_stroke_count, int) or fixed_stroke_count < 1):
        raise ValueError("stroke-set checkpoint has no valid fixed Core ML stroke dimension")
    data_loader = DataLoader(data, batch_size=1, shuffle=False, collate_fn=collate_stroke_set if stroke_set else collate_rasters)
    model = model_type().eval()
    model.load_state_dict(checkpoint["model"], strict=True)
    coreml = ct.models.MLModel(str(args.package), compute_units=ct.ComputeUnit.CPU_ONLY)
    reference_top1_correct = coreml_top1_correct = 0
    reference_top5_correct = coreml_top5_correct = 0
    top1_pairwise_matches = top5_pairwise_matches = 0
    total = 0
    maximum_absolute_error = 0.0
    maximum_relative_error = 0.0
    maximum_absolute_embedding_error = 0.0
    mismatched_sources: list[str] = []
    with torch.inference_mode():
        for inputs, labels, sources in data_loader:
            if stroke_set:
                pytorch_logits, pytorch_embedding = model_forward(model, inputs)
                images, points, reversed_points, valid = inputs
                if points.shape[1] > fixed_stroke_count:
                    raise ValueError(
                        f"sample {sources[0]} has {points.shape[1]} strokes; Core ML contract allows {fixed_stroke_count}"
                    )
                padding = fixed_stroke_count - points.shape[1]
                if padding:
                    points = torch.nn.functional.pad(points, (0, 0, 0, 0, 0, padding))
                    reversed_points = torch.nn.functional.pad(reversed_points, (0, 0, 0, 0, 0, padding))
                    valid = torch.nn.functional.pad(valid, (0, padding))
                coreml_inputs = {
                    "inkRaster": images.numpy().astype(np.float32, copy=False),
                    "strokePoints": points.numpy().astype(np.float32, copy=False),
                    "reversedStrokePoints": reversed_points.numpy().astype(np.float32, copy=False),
                    "strokeValid": valid.numpy().astype(np.float32, copy=False),
                }
            else:
                pytorch_logits, pytorch_embedding = model_forward(model, inputs)
                coreml_inputs = {"inkRaster": inputs.numpy().astype(np.float32, copy=False)}
            coreml_values = coreml.predict(coreml_inputs)
            coreml_logits = np.asarray(coreml_values["classLogits"], dtype=np.float32).reshape(1, -1)
            if coreml_logits.shape != (1, 229) or not np.isfinite(coreml_logits).all():
                raise ValueError(f"Core ML returned invalid class logits for {sources[0]}")
            coreml_embedding = np.asarray(coreml_values["queryEmbedding"], dtype=np.float32).reshape(1, -1)
            if coreml_embedding.shape != (1, EMBEDDING_DIMENSION) or not np.isfinite(coreml_embedding).all():
                raise ValueError(f"Core ML returned invalid queryEmbedding for {sources[0]}")
            reference = pytorch_logits.cpu().numpy().astype(np.float32, copy=False)
            reference_embedding = pytorch_embedding.cpu().numpy().astype(np.float32, copy=False)
            if reference_embedding.shape != (1, EMBEDDING_DIMENSION) or not np.isfinite(reference_embedding).all():
                raise ValueError(f"PyTorch returned invalid embedding for {sources[0]}")
            maximum_absolute_embedding_error = max(
                maximum_absolute_embedding_error,
                float(np.abs(reference_embedding - coreml_embedding).max()),
            )
            absolute = np.abs(reference - coreml_logits)
            relative = absolute / np.maximum(np.abs(reference), 1e-6)
            maximum_absolute_error = max(maximum_absolute_error, float(absolute.max()))
            maximum_relative_error = max(maximum_relative_error, float(relative.max()))
            reference_order = np.argsort(-reference, axis=1)
            coreml_order = np.argsort(-coreml_logits, axis=1)
            target = int(labels.item())
            reference_top1 = int(reference_order[0, 0]) == target
            coreml_top1 = int(coreml_order[0, 0]) == target
            reference_top5 = target in reference_order[0, :5]
            coreml_top5 = target in coreml_order[0, :5]
            pairwise_top1 = int(reference_order[0, 0]) == int(coreml_order[0, 0])
            pairwise_top5 = set(reference_order[0, :5].tolist()) == set(coreml_order[0, :5].tolist())
            reference_top1_correct += int(reference_top1)
            coreml_top1_correct += int(coreml_top1)
            reference_top5_correct += int(reference_top5)
            coreml_top5_correct += int(coreml_top5)
            top1_pairwise_matches += int(pairwise_top1)
            top5_pairwise_matches += int(pairwise_top5)
            if not pairwise_top1 or reference_top5 != coreml_top5:
                mismatched_sources.append(str(sources[0]))
            total += 1
    if total != len(data) or total == 0:
        raise ValueError(f"validation sample count mismatch: processed {total}, expected {len(data)}")
    report = {
        "format": "hinotori-raster-coreml-parity-v2",
        "package": str(args.package),
        "checkpointSHA256": hashlib.sha256(checkpoint_bytes).hexdigest(),
        "computeUnits": "CPU_ONLY; parity validation, not ANE validation",
        "validationSourceFingerprint": split_fingerprint(data),
        "sampleCount": total,
        "pytorchTop1Correct": reference_top1_correct,
        "coreMLTop1Correct": coreml_top1_correct,
        "pytorchTop5Correct": reference_top5_correct,
        "coreMLTop5Correct": coreml_top5_correct,
        "top1PairwiseMatchCount": top1_pairwise_matches,
        "top5SetPairwiseMatchCount": top5_pairwise_matches,
        "pytorchSelectedCheckpointMetrics": {
            key: checkpoint.get("metrics", {}).get(key)
            for key in ("epoch", "top1", "top5", "macroRecallSupportedClasses")
        },
        "pytorchTop1": reference_top1_correct / total,
        "pytorchTop5": reference_top5_correct / total,
        "coreMLTop1": coreml_top1_correct / total,
        "coreMLTop5": coreml_top5_correct / total,
        "maximumAbsoluteLogitError": maximum_absolute_error,
        "maximumRelativeLogitError": maximum_relative_error,
        "maximumAbsoluteEmbeddingError": maximum_absolute_embedding_error,
        "mismatchedSources": mismatched_sources,
        "ANEStatus": "not measured; this run used CPU_ONLY on the development Mac",
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"report": str(args.report), **{key: report[key] for key in (
        "sampleCount", "pytorchSelectedCheckpointMetrics", "coreMLTop1", "coreMLTop5",
        "maximumAbsoluteLogitError", "maximumRelativeLogitError", "maximumAbsoluteEmbeddingError", "ANEStatus"
    )}}, ensure_ascii=False))


if __name__ == "__main__":
    main()
