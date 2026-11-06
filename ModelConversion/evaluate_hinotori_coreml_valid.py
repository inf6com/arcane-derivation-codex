#!/usr/bin/env python3
"""Compare a Core ML Hinotori artifact with its checkpoint on direct held-out symbols."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import time

import coremltools as ct
import numpy as np
import torch

try:
    from ModelConversion.hinotori_direct_dataset import DirectAnchorDataset
    from ModelConversion.hinotori_model import HinotoriRetrievalModel
    from ModelConversion.hinotori_retrieval import class_retrieval_logits
except ImportError:
    from hinotori_direct_dataset import DirectAnchorDataset
    from hinotori_model import HinotoriRetrievalModel
    from hinotori_retrieval import class_retrieval_logits


def manifest_array(artifact: Path, entry: dict[str, object], dtype: str) -> np.ndarray:
    path = artifact / str(entry["path"])
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != entry["sha256"]:
        raise ValueError(f"artifact array SHA-256 mismatch: {path}")
    shape = tuple(int(value) for value in entry["shape"])
    # Core ML's Python bridge requires writable, contiguous NumPy inputs.
    array = np.frombuffer(data, dtype=np.dtype(dtype)).copy()
    if array.size != int(np.prod(shape)):
        raise ValueError(f"artifact array size does not match manifest: {path}")
    return array.reshape(shape)


def update_hits(hits: dict[int, int], ranked: np.ndarray, target: int) -> None:
    for k in hits:
        if target in ranked[:k]:
            hits[k] += 1


def metrics(hits: dict[int, int], count: int) -> dict[str, float]:
    return {f"top{k}": hits[k] / count if count else 0.0 for k in hits}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--checkpoint-contract", choices=("hinotori-retrieval-v1", "symbol229-retrieval-v1"), required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        raise FileExistsError(f"refusing to overwrite evaluation report: {args.report}")

    manifest_path = args.artifact / "HinotoriCoreML.manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("format") != "hinotori-retrieval-coreml-v1":
        raise ValueError("artifact is not a Hinotori Core ML v1 package")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("contract") != args.checkpoint_contract:
        raise ValueError("checkpoint contract does not match the explicitly selected evaluation contract")
    if hashlib.sha256(args.checkpoint.read_bytes()).hexdigest() != manifest.get("checkpointSHA256"):
        raise ValueError("Core ML package was exported from a different checkpoint")

    direct_path = args.teachers / "direct-symbol-teachers.jsonl"
    train = DirectAnchorDataset(direct_path, args.source_split, args.mathwriting_root, 32, "train")
    valid = DirectAnchorDataset(direct_path, args.source_split, args.mathwriting_root, 32, "valid")
    arrays = manifest["anchorBank"]["arrays"]
    anchor_points = manifest_array(args.artifact, arrays["anchorPoints"], "<f4")
    anchor_valid = manifest_array(args.artifact, arrays["anchorStrokeValid"], "<f4")
    anchor_classes = manifest_array(args.artifact, arrays["anchorClasses"], "<i8")
    train_classes = np.asarray([int(train[index]["classIndex"]) for index in range(len(train))], dtype="<i8")
    if not np.array_equal(anchor_classes, train_classes):
        raise ValueError("artifact anchor class order differs from the direct training split")
    max_strokes = int(manifest["anchorBank"]["maxStrokes"])
    if anchor_points.shape[0] != len(train) or anchor_points.shape[1] != max_strokes:
        raise ValueError("artifact anchor bank dimensions do not match its manifest or training split")

    model = HinotoriRetrievalModel().eval()
    model.load_state_dict(checkpoint["modelState"], strict=True)
    train_groups = [train[index]["points"] for index in range(len(train))]
    with torch.inference_mode():
        reference_anchors = model.encode_groups(train_groups)
    reference_classes = torch.from_numpy(anchor_classes.astype(np.int64, copy=True))
    temperature = model.temperature
    retrieval_path = args.artifact / "HinotoriRetrieval.mlpackage"
    coreml = ct.models.MLModel(str(retrieval_path), compute_units=ct.ComputeUnit.CPU_ONLY)

    hits_reference = {1: 0, 2: 0, 3: 0, 5: 0}
    hits_coreml = {1: 0, 2: 0, 3: 0, 5: 0}
    confusion: Counter[tuple[int, int]] = Counter()
    supported = 0
    unsupported = 0
    top1_matches = 0
    maximum_absolute_difference = 0.0
    absolute_difference_sum = 0.0
    compared_logit_count = 0
    started = time.monotonic()

    for index in range(len(valid)):
        sample = valid[index]
        points = sample["points"]
        target = int(sample["classIndex"])
        if points.shape[0] > max_strokes:
            unsupported += 1
            continue

        query_points = np.zeros((1, max_strokes, 32, 2), dtype=np.float32)
        query_valid = np.zeros((1, max_strokes), dtype=np.float32)
        query_points[0, :points.shape[0]] = points.numpy()
        query_valid[0, :points.shape[0]] = 1.0
        prediction = coreml.predict({
            "queryPoints": query_points,
            "queryStrokeValid": query_valid,
            "anchorPoints": anchor_points,
            "anchorStrokeValid": anchor_valid,
        })
        observed = np.asarray(prediction["classLogits"], dtype=np.float32).reshape(229)

        with torch.inference_mode():
            query = model.encode_groups([points])
            reference = class_retrieval_logits(query, reference_anchors, reference_classes, 229, temperature).cpu().numpy().reshape(229)
        difference = np.abs(observed - reference)
        maximum_absolute_difference = max(maximum_absolute_difference, float(difference.max()))
        absolute_difference_sum += float(difference.sum())
        compared_logit_count += difference.size
        reference_ranked = np.argsort(-reference)
        observed_ranked = np.argsort(-observed)
        update_hits(hits_reference, reference_ranked, target)
        update_hits(hits_coreml, observed_ranked, target)
        top1_matches += int(int(reference_ranked[0]) == int(observed_ranked[0]))
        confusion[(target, int(observed_ranked[0]))] += 1
        supported += 1
        if (index + 1) % 100 == 0:
            print(f"evaluated={index + 1}/{len(valid)} supported={supported} unsupported={unsupported}", flush=True)

    denominator = len(valid)
    report = {
        "status": "COMPLETED",
        "evaluation": "HELD_OUT_DIRECT_SYMBOLS",
        "checkpoint": str(args.checkpoint),
        "checkpointSHA256": hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
        "checkpointContract": args.checkpoint_contract,
        "artifact": str(args.artifact),
        "computePrecision": manifest.get("computePrecision", "float32"),
        "coreMLComputeUnit": "CPU_ONLY",
        "directTrainingAnchorCount": len(train),
        "validSymbolCount": denominator,
        "supportedValidCount": supported,
        "unsupportedValidCount": unsupported,
        "denominatorIncludesUnsupported": True,
        "referencePyTorch": metrics(hits_reference, denominator),
        "coreML": metrics(hits_coreml, denominator),
        "coreMLTop1MatchCountAgainstPyTorch": top1_matches,
        "coreMLTop1MatchRateAgainstPyTorch": top1_matches / supported if supported else 0.0,
        "maxAbsoluteLogitDifference": maximum_absolute_difference,
        "meanAbsoluteLogitDifference": absolute_difference_sum / compared_logit_count if compared_logit_count else 0.0,
        "mostFrequentCoreMLConfusions": [
            {"actualClass": actual, "predictedClass": predicted, "count": count}
            for (actual, predicted), count in confusion.most_common(30)
        ],
        "elapsedSeconds": time.monotonic() - started,
        "interpretation": "This held-out direct-symbol evaluation isolates retrieval with ground-truth symbol segmentation. It does not measure formula grouping or position/similarity postprocessing.",
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "referencePyTorch": report["referencePyTorch"],
        "coreML": report["coreML"],
        "top1MatchRateAgainstPyTorch": report["coreMLTop1MatchRateAgainstPyTorch"],
        "maxAbsoluteLogitDifference": maximum_absolute_difference,
        "unsupportedValidCount": unsupported,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
