#!/usr/bin/env python3
"""Evaluate model → coordinate-free similarity → coordinate-based position."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def require_indices(value: object, field: str, line_number: int, *, count: int | None = None) -> list[int]:
    if not isinstance(value, list) or not all(type(item) is int and 0 <= item < 229 for item in value):
        raise ValueError(f"line {line_number}: {field} must contain Hinotori class indices")
    if len(set(value)) != len(value):
        raise ValueError(f"line {line_number}: {field} contains duplicate indices")
    if count is not None and len(value) != count:
        raise ValueError(f"line {line_number}: {field} must contain exactly {count} indices")
    return value


def hits(candidates: list[int], target: int, k: int) -> bool:
    return target in candidates[:k]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--records", type=Path, required=True, help="candidate JSONL from actual Hinotori inference")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.records.is_file():
        raise FileNotFoundError(f"real-inference records are unavailable: {args.records}")

    metrics = {
        "model": {k: 0 for k in (1, 5, 10, 20)},
        "similarityExpandedPool": {k: 0 for k in (1, 5, 10, 20)},
        "positionAppliedFullRanking": {k: 0 for k in (1, 5, 10, 20)},
        "displayModelTop1": 0,
        "displaySimilarityPoolRecall": 0,
        "displayPositionTop1": 0,
        "displayPositionTop5Recall": 0,
        "similarityTargetsAdded": 0,
        "positionChangedModelTop1": 0,
        "positionPromotedCorrectTop1": 0,
        "similarityCandidateCount": 0,
        "recordsWithSimilarityCandidates": 0,
        "recordsWithPositionReorder": 0,
        "positionRuleEvidenceCount": 0,
        "positionContextRecords": 0,
        "positionOverlapExcludedRecords": 0,
    }
    total = 0
    for line_number, line in enumerate(args.records.read_text(encoding="utf-8").splitlines(), start=1):
        if not line:
            continue
        record = json.loads(line)
        target = record.get("targetClassIndex")
        if type(target) is not int or not 0 <= target < 229:
            raise ValueError(f"line {line_number}: targetClassIndex must be a Hinotori class index")
        model = require_indices(record.get("modelCandidateClassIndices"), "modelCandidateClassIndices", line_number, count=229)
        if set(model) != set(range(229)):
            raise ValueError(f"line {line_number}: model ranking must retain the full Hinotori vocabulary")
        if record.get("similarityExpansionSchema") != "hinotori-symbol-similarity-groups-v3" or record.get("similarityExpansionRuleVersion") != "hinotori-symbol-similarity-v3":
            raise ValueError(f"line {line_number}: coordinate-independent similarity stage is missing or has the wrong version")
        similarity_input = require_indices(record.get("similarityExpansionInputCandidateClassIndices"), "similarityExpansionInputCandidateClassIndices", line_number, count=5)
        if similarity_input != model[:5]:
            raise ValueError(f"line {line_number}: similarity stage did not use the actual model top five")
        supplement_records = record.get("similaritySupplementCandidates")
        if not isinstance(supplement_records, list):
            raise ValueError(f"line {line_number}: similaritySupplementCandidates must be recorded")
        supplements = require_indices(record.get("similaritySupplementCandidateClassIndices"), "similaritySupplementCandidateClassIndices", line_number)
        if supplements != [item.get("classIndex") for item in supplement_records]:
            raise ValueError(f"line {line_number}: similarity provenance and class-index list disagree")
        for candidate in supplement_records:
            if candidate.get("origin") != "shape-similarity-expansion" or candidate.get("hasModelScoreInDisplayedCandidates") is not False:
                raise ValueError(f"line {line_number}: similarity candidate provenance or score status is invalid")
            matched = candidate.get("matchedModelCandidateClassIndices")
            if not isinstance(matched, list) or not matched or not set(matched).issubset(set(similarity_input)):
                raise ValueError(f"line {line_number}: similarity candidate has no valid matching model candidate")
        if set(similarity_input) & set(supplements):
            raise ValueError(f"line {line_number}: similarity stage duplicated a model candidate")
        similarity_pool = require_indices(record.get("similarityExpandedDisplayCandidateClassIndices"), "similarityExpandedDisplayCandidateClassIndices", line_number)
        if similarity_pool != similarity_input + supplements:
            raise ValueError(f"line {line_number}: similarity pool does not preserve stage order")

        position_order = require_indices(record.get("displayedPositionOrderedCandidateClassIndices"), "displayedPositionOrderedCandidateClassIndices", line_number)
        if len(position_order) != len(similarity_pool) or set(position_order) != set(similarity_pool):
            raise ValueError(f"line {line_number}: position stage must reorder the complete similarity-expanded choice set")
        position_full = require_indices(record.get("positionAppliedFullCandidateClassIndices"), "positionAppliedFullCandidateClassIndices", line_number, count=229)
        reordered_model = require_indices(record.get("displayedReorderedModelCandidateClassIndices"), "displayedReorderedModelCandidateClassIndices", line_number, count=5)
        if set(position_full) != set(range(229)) or position_full[:5] != reordered_model or set(reordered_model) != set(similarity_input):
            raise ValueError(f"line {line_number}: full model ranking must preserve its top-five candidate set and ranking contract")
        if record.get("ruleSupplementedCandidateClassIndices") != []:
            raise ValueError(f"line {line_number}: position stage must not create or relabel similarity supplements")

        for k in metrics["model"]:
            metrics["model"][k] += int(hits(model, target, k))
            metrics["similarityExpandedPool"][k] += int(hits(similarity_pool, target, k))
            metrics["positionAppliedFullRanking"][k] += int(hits(position_full, target, k))
        metrics["displayModelTop1"] += int(similarity_input[0] == target)
        metrics["displaySimilarityPoolRecall"] += int(target in similarity_pool)
        metrics["displayPositionTop1"] += int(bool(position_order) and position_order[0] == target)
        metrics["displayPositionTop5Recall"] += int(target in position_order[:5])
        metrics["similarityTargetsAdded"] += int(target in supplements and target not in similarity_input)
        metrics["positionChangedModelTop1"] += int(bool(position_order) and position_order[0] != similarity_input[0])
        metrics["positionPromotedCorrectTop1"] += int(bool(position_order) and position_order[0] == target and similarity_input[0] != target)
        metrics["similarityCandidateCount"] += len(supplements)
        metrics["recordsWithSimilarityCandidates"] += int(bool(supplements))
        metrics["recordsWithPositionReorder"] += int(position_order != similarity_pool)
        metrics["positionRuleEvidenceCount"] += int(bool(record.get("positionRuleEvidence")))
        metrics["positionContextRecords"] += int(record.get("positionContextInstanceCount", 0) > 1)
        metrics["positionOverlapExcludedRecords"] += int(record.get("positionContextStatus") == "overlapping-direct-groups-excluded")
        total += 1

    if total == 0:
        raise ValueError("no real-inference records were supplied")
    report = {
        "contract": "hinotori-sequential-similarity-position-evaluation-v1",
        "records": total,
        "topK": {
            stage: {f"top{k}": count / total for k, count in values.items()}
            for stage, values in metrics.items()
            if isinstance(values, dict)
        },
        "displayedChoiceSet": {
            "modelTop1Accuracy": metrics["displayModelTop1"] / total,
            "similarityExpandedRecall": metrics["displaySimilarityPoolRecall"] / total,
            "positionOrderedTop1Accuracy": metrics["displayPositionTop1"] / total,
            "positionOrderedTop5Recall": metrics["displayPositionTop5Recall"] / total,
            "similarityCorrectTargetsAdded": metrics["similarityTargetsAdded"],
            "positionChangedTop1Count": metrics["positionChangedModelTop1"],
            "positionPromotedCorrectTop1Count": metrics["positionPromotedCorrectTop1"],
            "similarityCandidateCount": metrics["similarityCandidateCount"],
            "recordsWithSimilarityCandidates": metrics["recordsWithSimilarityCandidates"],
            "recordsWithPositionReorder": metrics["recordsWithPositionReorder"],
        },
        "positionContext": {
            "recordsWithRuleEvidence": metrics["positionRuleEvidenceCount"],
            "recordsWithNeighborContext": metrics["positionContextRecords"],
            "overlappingDirectGroupsExcluded": metrics["positionOverlapExcludedRecords"],
        },
            "interpretation": "Similarity alternatives are generated without coordinates and remain separate from the full 229-class model ranking. Position rules reorder only labels in the matched family, independently within model top-five slots and supplemental suggestions; outside-family model ranks and the top-five candidate set are preserved. Supplemental labels carry no model score.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
