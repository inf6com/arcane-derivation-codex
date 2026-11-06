#!/usr/bin/env python3
"""Measure information lost by the current whole-formula trace feature contract.

This audit opens only train and valid InkML files. It does not read the frozen
test split. Resampling error is the nearest-sampled-point Euclidean distance
in the isotropically normalized [0,1] coordinate space, measured from every
source point to the fixed resampled points. Both the current feature count
and a 64-point comparison are reported; the model source is not changed by
this diagnostic.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import time
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

try:
    from ModelConversion.formula_whole_input import load_formula_input, model_features
    from ModelConversion.formula_whole_model import MAX_TRACES, POINTS_PER_TRACE, resample_trace
except ImportError:
    from formula_whole_input import load_formula_input, model_features
    from formula_whole_model import MAX_TRACES, POINTS_PER_TRACE, resample_trace


def bucket_length(value: int) -> str:
    return "0-10" if value <= 10 else "11-20" if value <= 20 else "21+"


def bucket_trace_count(value: int) -> str:
    if value <= 8:
        return "1-8"
    if value <= 16:
        return "9-16"
    if value <= 32:
        return "17-32"
    if value <= 64:
        return "33-64"
    if value <= MAX_TRACES:
        return "65-80"
    return "81+"


def nearest_sample_error(source: list[tuple[float, float]], sampled: list[tuple[float, float]]) -> list[float]:
    source_array = np.asarray(source, dtype=np.float32)
    sampled_array = np.asarray(sampled, dtype=np.float32)
    distances = source_array[:, None, :] - sampled_array[None, :, :]
    return np.sqrt(np.min(np.sum(distances * distances, axis=2), axis=1)).tolist()


def pearson(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) != len(ys) or len(xs) < 2:
        return None
    x_mean = statistics.mean(xs)
    y_mean = statistics.mean(ys)
    numerator = sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys))
    x_variance = sum((x - x_mean) ** 2 for x in xs)
    y_variance = sum((y - y_mean) ** 2 for y in ys)
    denominator = math.sqrt(x_variance * y_variance)
    return numerator / denominator if denominator else None


def summarize(values: list[float]) -> dict[str, float]:
    if not values:
        return {"count": 0, "mean": 0.0, "median": 0.0, "p95": 0.0, "max": 0.0}
    array = np.asarray(values, dtype=np.float64)
    return {
        "count": len(values),
        "mean": float(np.mean(array)),
        "median": float(np.quantile(array, 0.5, method="linear")),
        "p95": float(np.quantile(array, 0.95, method="linear")),
        "max": float(np.max(array)),
    }


def _audit_path_chunk(arguments: tuple[list[str], int, int]) -> dict[str, object]:
    """Parse and measure a bounded path chunk in a separate process.

    XML parsing dominates this audit. Keeping the worker result to primitive
    lists and counters preserves exact train/valid aggregates while allowing
    independent files to be parsed concurrently.
    """
    path_names, current_count, comparison_count = arguments
    trace_counts: list[int] = []
    points_per_trace: list[int] = []
    formula_points: list[int] = []
    current_errors: list[float] = []
    comparison_errors: list[float] = []
    formula_current_errors: list[float] = []
    formula_comparison_errors: list[float] = []
    label_lengths: list[int] = []
    trace_count_buckets: Counter[str] = Counter()
    point_count_buckets: Counter[str] = Counter()
    length_buckets: dict[str, dict[str, list[float]]] = defaultdict(lambda: {"current": [], "comparison": []})
    path_count_over_limit = 0
    trace_count_over_limit = 0

    for path_name in path_names:
        formula, metadata = load_formula_input(Path(path_name))
        traces = model_features(formula)
        trace_count = len(traces)
        trace_counts.append(trace_count)
        trace_count_buckets[bucket_trace_count(trace_count)] += 1
        path_count_over_limit += int(trace_count > MAX_TRACES)
        trace_count_over_limit += max(0, trace_count - MAX_TRACES)
        label_length = len(metadata["normalizedLabel"])
        label_lengths.append(label_length)
        per_formula_current: list[float] = []
        per_formula_comparison: list[float] = []
        total_points = 0
        for trace in traces:
            source = list(trace)
            point_count = len(source)
            total_points += point_count
            points_per_trace.append(point_count)
            if point_count <= 32:
                point_count_buckets["1-32"] += 1
            elif point_count <= 64:
                point_count_buckets["33-64"] += 1
            else:
                point_count_buckets["65+"] += 1
            current_distance = nearest_sample_error(source, resample_trace(source, current_count))
            comparison_distance = nearest_sample_error(source, resample_trace(source, comparison_count))
            current_errors.extend(current_distance)
            comparison_errors.extend(comparison_distance)
            per_formula_current.extend(current_distance)
            per_formula_comparison.extend(comparison_distance)
        formula_points.append(total_points)
        formula_current_errors.append(statistics.mean(per_formula_current))
        formula_comparison_errors.append(statistics.mean(per_formula_comparison))
        length_bucket = bucket_length(label_length)
        length_buckets[length_bucket]["current"].extend(per_formula_current)
        length_buckets[length_bucket]["comparison"].extend(per_formula_comparison)

    return {
        "traceCounts": trace_counts,
        "pointsPerTrace": points_per_trace,
        "formulaPoints": formula_points,
        "currentErrors": current_errors,
        "comparisonErrors": comparison_errors,
        "formulaCurrentErrors": formula_current_errors,
        "formulaComparisonErrors": formula_comparison_errors,
        "labelLengths": label_lengths,
        "traceCountBuckets": dict(trace_count_buckets),
        "pointCountBuckets": dict(point_count_buckets),
        "lengthBuckets": {key: dict(value) for key, value in length_buckets.items()},
        "formulaCountOverMaxTraces": path_count_over_limit,
        "traceCountOverMaxTraces": trace_count_over_limit,
    }


def audit_split(split_root: Path, current_count: int, comparison_count: int) -> dict[str, object]:
    paths = sorted(split_root.glob("*.inkml"))
    chunk_size = 1024
    chunks = [
        [str(path) for path in paths[index : index + chunk_size]]
        for index in range(0, len(paths), chunk_size)
    ]
    trace_counts: list[int] = []
    points_per_trace: list[int] = []
    formula_points: list[int] = []
    current_errors: list[float] = []
    comparison_errors: list[float] = []
    formula_current_errors: list[float] = []
    formula_comparison_errors: list[float] = []
    label_lengths: list[int] = []
    trace_count_buckets: Counter[str] = Counter()
    point_count_buckets: Counter[str] = Counter()
    length_buckets: dict[str, dict[str, list[float]]] = defaultdict(lambda: {"current": [], "comparison": []})
    path_count_over_limit = 0
    trace_count_over_limit = 0

    worker_count = min(8, max(1, len(chunks)))
    with ProcessPoolExecutor(max_workers=worker_count) as executor:
        results = executor.map(_audit_path_chunk, ((chunk, current_count, comparison_count) for chunk in chunks))
        for result in results:
            trace_counts.extend(result["traceCounts"])
            points_per_trace.extend(result["pointsPerTrace"])
            formula_points.extend(result["formulaPoints"])
            current_errors.extend(result["currentErrors"])
            comparison_errors.extend(result["comparisonErrors"])
            formula_current_errors.extend(result["formulaCurrentErrors"])
            formula_comparison_errors.extend(result["formulaComparisonErrors"])
            label_lengths.extend(result["labelLengths"])
            trace_count_buckets.update(result["traceCountBuckets"])
            point_count_buckets.update(result["pointCountBuckets"])
            for bucket, values in result["lengthBuckets"].items():
                length_buckets[bucket]["current"].extend(values["current"])
                length_buckets[bucket]["comparison"].extend(values["comparison"])
            path_count_over_limit += result["formulaCountOverMaxTraces"]
            trace_count_over_limit += result["traceCountOverMaxTraces"]

    return {
        "pathCount": len(paths),
        "featureContract": {
            "actualModelPointsPerTrace": POINTS_PER_TRACE,
            "auditedCurrentPointsPerTrace": current_count,
            "comparisonPointsPerTrace": comparison_count,
            "shape": f"[trace,{current_count},2]",
            "maxTraces": MAX_TRACES,
        },
        "traceCount": summarize([float(value) for value in trace_counts]),
        "traceCountBuckets": dict(sorted(trace_count_buckets.items())),
        "traceLimit": {
            "formulaCountOverMaxTraces": path_count_over_limit,
            "traceCountOverMaxTraces": trace_count_over_limit,
        },
        "pointsPerTrace": summarize([float(value) for value in points_per_trace]),
        "pointsPerTraceBuckets": dict(sorted(point_count_buckets.items())),
        "pointsPerFormula": summarize([float(value) for value in formula_points]),
        "resamplingError": {
            "current": summarize(current_errors),
            "comparison": summarize(comparison_errors),
            "relativeMeanReduction": 1.0 - statistics.mean(comparison_errors) / max(statistics.mean(current_errors), 1e-12),
        },
        "resamplingErrorByLabelLength": {
            bucket: {
                "current": summarize(values["current"]),
                "comparison": summarize(values["comparison"]),
                "relativeMeanReduction": 1.0
                - statistics.mean(values["comparison"]) / max(statistics.mean(values["current"]), 1e-12),
            }
            for bucket, values in sorted(length_buckets.items())
        },
        "correlation": {
            "labelCharacterLengthVsFormulaMeanCurrentResamplingError": pearson(label_lengths, formula_current_errors),
            "labelCharacterLengthVsFormulaMeanComparisonResamplingError": pearson(label_lengths, formula_comparison_errors),
            "traceCountVsFormulaMeanCurrentResamplingError": pearson([float(value) for value in trace_counts], formula_current_errors),
            "pointsPerFormulaVsFormulaMeanCurrentResamplingError": pearson([float(value) for value in formula_points], formula_current_errors),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--current-points", type=int, default=POINTS_PER_TRACE)
    parser.add_argument("--comparison-points", type=int, default=64)
    args = parser.parse_args()
    if args.current_points < 2 or args.comparison_points < 2:
        raise ValueError("point counts must be at least 2")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    started = time.time()
    root = args.dataset_root / "mathwriting-2024"
    report = {
        "status": "COMPLETED",
        "splitPolicy": "train and valid only; test is not opened",
        "datasetRoot": str(args.dataset_root),
        "config": {"currentPoints": args.current_points, "comparisonPoints": args.comparison_points, "maxTraces": MAX_TRACES},
        "splits": {
            "train": audit_split(root / "train", args.current_points, args.comparison_points),
            "valid": audit_split(root / "valid", args.current_points, args.comparison_points),
        },
        "elapsedSeconds": time.time() - started,
    }
    report_path = args.output_dir / "formula-feature-loss-report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": report["status"], "trainCount": report["splits"]["train"]["pathCount"], "validCount": report["splits"]["valid"]["pathCount"], "elapsedSeconds": report["elapsedSeconds"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
