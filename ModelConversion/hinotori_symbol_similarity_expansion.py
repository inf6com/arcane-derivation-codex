"""Add coordinate-independent similar-symbol choices before spatial ranking."""
from __future__ import annotations

from functools import lru_cache
import json
import math
from pathlib import Path
from typing import Any


def add_similarity_expansions(
    candidate_records: list[dict[str, Any]],
    vocabulary_path: Path,
    catalog_path: Path,
    displayed_candidate_count: int = 5,
) -> list[dict[str, Any]]:
    """Expand only from model labels and a fixed vocabulary; accepts no geometry."""
    if displayed_candidate_count < 1:
        raise ValueError("displayed candidate count must be positive")
    vocabulary_document = json.loads(vocabulary_path.read_text(encoding="utf-8"))
    labels = vocabulary_document.get("labels")
    if vocabulary_document.get("version") != "hinotori-v1" or not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229:
        raise ValueError("similarity expansion requires the exact Hinotori vocabulary")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    if catalog.get("schema") != "hinotori-symbol-similarity-groups-v3" or catalog.get("sourceVocabularyContract") != "hinotori-v1":
        raise ValueError("similarity catalog contract mismatch")
    if catalog.get("featureDistanceContract") != "query-to-class-centroid-cosine-distance-v1":
        raise ValueError("similarity feature-distance contract mismatch")
    distance_bands = catalog.get("distanceBandThresholds")
    if not isinstance(distance_bands, dict):
        raise ValueError("similarity catalog is missing measured distance-band thresholds")
    near_max = distance_bands.get("nearMaximumDistance")
    middle_max = distance_bands.get("middleMaximumDistance")
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) for value in (near_max, middle_max)) or not 0.0 <= near_max <= middle_max <= 2.0:
        raise ValueError("similarity catalog has invalid measured distance-band thresholds")
    groups = catalog.get("groups")
    if not isinstance(groups, list) or not groups:
        raise ValueError("similarity catalog has no groups")
    seen_group_ids: set[str] = set()
    for group in groups:
        group_id, members = group.get("id"), group.get("labels")
        if not isinstance(group_id, str) or not group_id or group_id in seen_group_ids:
            raise ValueError("similarity catalog has an invalid or duplicate group ID")
        seen_group_ids.add(group_id)
        if not isinstance(members, list) or len(members) < 2 or len(set(members)) != len(members) or not all(member in labels for member in members):
            raise ValueError(f"similarity group {group_id} has invalid vocabulary membership")

    output: list[dict[str, Any]] = []
    for record in candidate_records:
        ranked = record.get("modelCandidateClassIndices")
        if not isinstance(ranked, list) or len(ranked) != 229 or set(ranked) != set(range(229)):
            raise ValueError("similarity expansion requires each complete actual 229-class ranking")
        distances = record.get("classFeatureDistances")
        if record.get("featureDistanceContract") != "query-to-class-centroid-cosine-distance-v1" or not isinstance(distances, list) or len(distances) != 229 or any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not 0.0 <= value <= 2.0 for value in distances):
            raise ValueError("similarity expansion requires 229 measured query-to-class feature distances")
        displayed = ranked[:displayed_candidate_count]
        displayed_labels = [labels[index] for index in displayed]
        groups_by_label: dict[str, list[str]] = {}
        matched_model_by_label: dict[str, list[int]] = {}
        for group in groups:
            hits = [index for index, label in zip(displayed, displayed_labels) if label in group["labels"]]
            if not hits:
                continue
            for label in group["labels"]:
                groups_by_label.setdefault(label, []).append(group["id"])
                matched_model_by_label.setdefault(label, []).extend(hits)
        supplements: list[dict[str, Any]] = []
        supplements_by_class: dict[int, dict[str, Any]] = {}
        for group in groups:
            for label in group["labels"]:
                if label not in groups_by_label or label in displayed_labels:
                    continue
                class_index = labels.index(label)
                supplements_by_class[class_index] = {
                    "classIndex": class_index,
                    "label": label,
                    "featureDistance": float(distances[class_index]),
                    "distanceBand": distance_band(float(distances[class_index]), near_max, middle_max),
                    "distanceMetric": "query-to-class-centroid-cosine-distance-v1",
                    "matchedGroupIDs": groups_by_label[label],
                    "matchedModelCandidateClassIndices": sorted(set(matched_model_by_label[label])),
                    "origin": "shape-similarity-expansion",
                    "modelRankInOfflineFullRanking": ranked.index(class_index) + 1,
                    "hasModelScoreInDisplayedCandidates": False,
                    "evidence": "catalog similarity relation authorizes suggestion; ordered by measured query-to-class-centroid cosine distance in Hinotori learned feature space; lower means closer; distance is not confidence; position is evaluated separately; user confirmation required",
                }
        supplements = sorted(supplements_by_class.values(), key=lambda item: (item["featureDistance"], item["classIndex"]))
        measured_similarity_distances = [
            {
                "classIndex": class_index,
                "label": labels[class_index],
                "distance": float(distances[class_index]),
                "distanceBand": distance_band(float(distances[class_index]), near_max, middle_max),
                "matchedGroupIDs": groups_by_label[label],
            }
            for class_index, label in sorted(
                ((labels.index(label), label) for label in groups_by_label),
                key=lambda pair: (float(distances[pair[0]]), pair[0]),
            )
        ]
        item = dict(record)
        item["similarityExpansionSchema"] = catalog["schema"]
        item["similarityExpansionRuleVersion"] = "hinotori-symbol-similarity-v3"
        item["similarityExpansionInputCandidateClassIndices"] = displayed
        item["similaritySupplementCandidates"] = supplements
        item["measuredSimilarityDistances"] = measured_similarity_distances
        item["similaritySupplementCandidateClassIndices"] = [candidate["classIndex"] for candidate in supplements]
        item["similarityExpandedDisplayCandidateClassIndices"] = displayed + item["similaritySupplementCandidateClassIndices"]
        output.append(item)
    return output


def distance_band(distance: float, near_maximum: float, middle_maximum: float) -> str:
    """Map the measured cosine distance to the calibrated error-distance tier."""
    if not math.isfinite(distance) or not 0.0 <= distance <= 2.0:
        raise ValueError("feature distance must be finite and within [0, 2]")
    if distance <= near_maximum:
        return "near"
    if distance <= middle_maximum:
        return "middle"
    return "far"


@lru_cache(maxsize=8)
def _read_similarity_catalog(catalog_path: Path) -> dict[str, Any]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    if catalog.get("schema") != "hinotori-symbol-similarity-groups-v3" or catalog.get("sourceVocabularyContract") != "hinotori-v1":
        raise ValueError("similarity catalog contract mismatch")
    if catalog.get("featureDistanceContract") != "query-to-class-centroid-cosine-distance-v1":
        raise ValueError("similarity feature-distance contract mismatch")
    if not isinstance(catalog.get("groups"), list) or not catalog["groups"]:
        raise ValueError("similarity catalog has no groups")
    return catalog


def direct_similarity_labels(label: str, catalog_path: Path) -> set[str]:
    """Return direct group neighbors only; overlapping groups are not traversed."""
    groups = _read_similarity_catalog(catalog_path)["groups"]
    neighbors = {label}
    for group in groups:
        members = group.get("labels")
        if not isinstance(members, list) or len(members) < 2 or not all(isinstance(member, str) for member in members):
            raise ValueError("similarity catalog contains an invalid group")
        if label in members:
            neighbors.update(members)
    return neighbors
