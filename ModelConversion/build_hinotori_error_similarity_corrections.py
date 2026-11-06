#!/usr/bin/env python3
"""Add measured direct-symbol Top-1 error pairs as distance-tiered suggestions."""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import statistics
from typing import Any


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise FileNotFoundError(f"inference candidate records are missing: {path}")
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    if not rows:
        raise ValueError("inference candidate records are empty")
    return rows


def build_corrections(records: list[dict[str, Any]], labels: list[str], catalog: dict[str, Any]) -> dict[str, Any]:
    if catalog.get("schema") != "hinotori-symbol-similarity-groups-v3" or catalog.get("sourceVocabularyContract") != "hinotori-v1":
        raise ValueError("base similarity catalog contract mismatch")
    groups = catalog.get("groups")
    if not isinstance(groups, list) or not groups:
        raise ValueError("base similarity catalog has no groups")
    seen_ids: set[str] = set()
    represented: set[tuple[int, int]] = set()
    for group in groups:
        group_id, members = group.get("id"), group.get("labels")
        if not isinstance(group_id, str) or not group_id or group_id in seen_ids:
            raise ValueError("base similarity catalog contains an invalid or duplicate group ID")
        seen_ids.add(group_id)
        if not isinstance(members, list) or len(members) < 2 or len(set(members)) != len(members) or not all(member in labels for member in members):
            raise ValueError(f"base similarity group {group_id} has invalid labels")
        indices = [labels.index(member) for member in members]
        represented.update(tuple(sorted((lhs, rhs))) for offset, lhs in enumerate(indices) for rhs in indices[offset + 1:])

    error_target_distances: list[float] = []
    pair_distances: dict[tuple[int, int], list[float]] = defaultdict(list)
    for row_number, row in enumerate(records, start=1):
        ranking = row.get("modelCandidateClassIndices")
        target = row.get("targetClassIndex")
        distances = row.get("classFeatureDistances")
        if not isinstance(ranking, list) or len(ranking) != len(labels) or set(ranking) != set(range(len(labels))):
            raise ValueError(f"record {row_number}: expected a complete ranked vocabulary")
        if type(target) is not int or not 0 <= target < len(labels):
            raise ValueError(f"record {row_number}: invalid targetClassIndex")
        if not isinstance(distances, list) or len(distances) != len(labels) or any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0.0 <= value <= 2.0 for value in distances):
            raise ValueError(f"record {row_number}: expected 229 finite measured feature distances")
        predicted = ranking[0]
        if predicted == target:
            continue
        target_distance = float(distances[target])
        error_target_distances.append(target_distance)
        pair_distances[tuple(sorted((predicted, target)))].append(target_distance)
    if not error_target_distances:
        raise ValueError("there are no measured Top-1 errors from which to build corrections")

    # Tertile cutoffs of the measured true-class distances on Top-1 errors.
    near_maximum, middle_maximum = statistics.quantiles(error_target_distances, n=3)
    additions: list[dict[str, Any]] = []
    represented_error_pairs = 0
    for (lhs, rhs), distances in sorted(pair_distances.items()):
        if (lhs, rhs) in represented:
            represented_error_pairs += 1
            continue
        median_distance = statistics.median(distances)
        band = "near" if median_distance <= near_maximum else "middle" if median_distance <= middle_maximum else "far"
        additions.append({
            "id": f"training-error-{band}-{lhs:03d}-{rhs:03d}",
            "labels": [labels[lhs], labels[rhs]],
            "source": "random-direct-teacher-top1-errors",
            "observations": len(distances),
            "medianTrueClassFeatureDistance": median_distance,
        })

    result = dict(catalog)
    result["purpose"] = (
        str(catalog.get("purpose", "")).rstrip()
        + " Direct-symbol Top-1 errors mined from a reproducibly sampled training set add correction relations. "
        "Every offered label retains its exact class; query-specific measured feature distance assigns near/middle/far tiers and orders suggestions; user confirmation remains required."
    )
    result["distanceBandThresholds"] = {
        "contract": "training-direct-teacher-top1-error-distance-tertiles-v1",
        "nearMaximumDistance": near_maximum,
        "middleMaximumDistance": middle_maximum,
        "sourceErrorCount": len(error_target_distances),
        "cutoffMethod": "statistics.quantiles(method=exclusive, n=3) over cosine distance from each misclassified query embedding to its true-class train-anchor centroid",
        "warning": "Cutoffs and mined relations are training-fit diagnostics; they are not independent validation thresholds.",
    }
    result["trainingErrorCorrection"] = {
        "contract": "hinotori-direct-teacher-top1-error-correction-v1",
        "totalTop1Errors": len(error_target_distances),
        "uniqueUnorderedErrorPairs": len(pair_distances),
        "pairsAlreadyRepresentedByBaseCatalog": represented_error_pairs,
        "newDistanceTieredGroups": len(additions),
        "distanceBandDefinition": "Per-group tier uses the median true-class feature distance observed for that error pair. At inference, each individual alternative receives its own query-specific near/middle/far tier and is ordered by its measured distance.",
        "dataUseWarning": "Mined from a random sample drawn from direct-symbol training annotations; this improves training-error coverage and does not establish held-out generalization.",
    }
    result["groups"] = list(groups) + additions
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--records", type=Path, required=True, help="actual inference JSONL containing targets, Top-1 rankings, and classFeatureDistances")
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--base-catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    vocabulary = json.loads(args.vocabulary.read_text(encoding="utf-8"))
    labels = vocabulary.get("labels")
    if vocabulary.get("version") != "hinotori-v1" or not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229:
        raise ValueError("expected the exact 229-label Hinotori vocabulary")
    catalog = json.loads(args.base_catalog.read_text(encoding="utf-8"))
    result = build_corrections(load_jsonl(args.records), labels, catalog)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result["trainingErrorCorrection"], ensure_ascii=False))
    print(json.dumps(result["distanceBandThresholds"], ensure_ascii=False))


if __name__ == "__main__":
    main()
