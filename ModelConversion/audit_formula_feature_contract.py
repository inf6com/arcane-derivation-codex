#!/usr/bin/env python3
"""Audit the complete FormulaInput v1 -> model-feature contract.

This reads every human InkML expression in the requested splits, applies the
same parser and x/y-only float32 feature conversion used by training, and
stores only aggregate shape/range evidence plus a few deterministic examples.
It never reads the excluded symbols/synthetic splits.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from collections import Counter
from pathlib import Path

from ModelConversion.formula_whole_input import MODEL_FEATURE_DIMENSION, MODEL_FEATURE_DTYPE, FormulaInputError, load_formula_input, model_features


def inkml_files(root: Path):
    with os.scandir(root) as entries:
        for entry in entries:
            if entry.is_file() and entry.name.endswith(".inkml"):
                yield Path(entry.path)


def audit_split(root: Path, sample_limit: int) -> dict[str, object]:
    count = 0
    parsed = 0
    errors: list[dict[str, str]] = []
    trace_count = Counter()
    total_points = 0
    min_points_per_trace: int | None = None
    max_points_per_trace = 0
    min_feature = math.inf
    max_feature = -math.inf
    examples: list[dict[str, object]] = []
    for path in inkml_files(root):
        count += 1
        try:
            formula, metadata = load_formula_input(path)
            features = model_features(formula)
        except FormulaInputError as error:
            if len(errors) < 20:
                errors.append({"path": str(path), "error": str(error)})
            continue
        parsed += 1
        point_counts = [len(trace) for trace in features]
        trace_count[len(features)] += 1
        total_points += sum(point_counts)
        if point_counts:
            minimum = min(point_counts)
            min_points_per_trace = minimum if min_points_per_trace is None else min(min_points_per_trace, minimum)
            max_points_per_trace = max(max_points_per_trace, max(point_counts))
        if any(len(point) != MODEL_FEATURE_DIMENSION for trace in features for point in trace):
            raise AssertionError(f"feature dimension mismatch: {path}")
        values = [value for trace in features for point in trace for value in point]
        if not all(math.isfinite(value) and 0.0 <= value <= 1.0 for value in values):
            raise AssertionError(f"feature value out of normalized range: {path}")
        min_feature = min(min_feature, min(values))
        max_feature = max(max_feature, max(values))
        if len(examples) < sample_limit:
            examples.append({"sampleId": metadata["sampleId"], "traceCount": len(features), "pointCounts": point_counts, "featureDimension": MODEL_FEATURE_DIMENSION})
    return {
        "path": str(root),
        "count": count,
        "parsed": parsed,
        "errors": errors,
        "traceCountHistogram": {str(key): value for key, value in sorted(trace_count.items())},
        "totalPoints": total_points,
        "totalFloat32Features": total_points * MODEL_FEATURE_DIMENSION,
        "minPointsPerTrace": min_points_per_trace,
        "maxPointsPerTrace": max_points_per_trace,
        "featureRange": [min_feature, max_feature] if parsed else None,
        "raggedShape": {"axes": ["trace", "point", "feature"], "featureDimension": MODEL_FEATURE_DIMENSION, "dtype": MODEL_FEATURE_DTYPE},
        "examples": examples,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True, help="directory containing mathwriting-2024/")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.dataset_root / "mathwriting-2024"
    result = {
        "format": "inf6-formula-whole-feature-contract-audit-v1",
        "specVersion": "inf6-formula-input-v1",
        "modelFeatureDType": MODEL_FEATURE_DTYPE,
        "modelFeatureDimension": MODEL_FEATURE_DIMENSION,
        "splits": {split: audit_split(root / split, sample_limit=3) for split in ("train", "valid", "test")},
        "excludedSplits": ["symbols", "synthetic"],
        "status": "PASS",
    }
    if any(split_result["errors"] for split_result in result["splits"].values()):
        result["status"] = "FAIL"
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "output": str(args.output), "splits": {key: value["parsed"] for key, value in result["splits"].items()}}, ensure_ascii=False))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
