"""Apply the shipped Hinotori position ordering to held-out direct-anchor records.

The direct annotations provide symbol-instance boundaries only for this
conditional symbol-classification evaluation. Position rules use raw InkML
source bounds and model-ranked labels from other annotated instances in the
same formula. They do not inspect ground-truth neighbor labels.
"""
from __future__ import annotations

import json
import math
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
from typing import Any

INK = {"ink": "http://www.w3.org/2003/InkML"}


def _read_trace_bounds(path: Path, required_ids: set[int]) -> dict[int, tuple[float, float, float, float]]:
    root = ET.parse(path).getroot()
    result: dict[int, tuple[float, float, float, float]] = {}
    for trace in root.findall("ink:trace", INK):
        raw_id = trace.get("id")
        if raw_id is None:
            raise ValueError(f"{path}: trace without id")
        trace_id = int(raw_id)
        if trace_id not in required_ids:
            continue
        if trace_id in result:
            raise ValueError(f"{path}: duplicate required trace id {trace_id}")
        xs: list[float] = []
        ys: list[float] = []
        for sample in (trace.text or "").strip().split(","):
            fields = sample.split()
            if len(fields) < 2:
                raise ValueError(f"{path}: malformed XY in trace {trace_id}")
            x, y = float(fields[0]), float(fields[1])
            if not math.isfinite(x) or not math.isfinite(y):
                raise ValueError(f"{path}: non-finite XY in trace {trace_id}")
            xs.append(x)
            ys.append(y)
        if not xs:
            raise ValueError(f"{path}: required trace {trace_id} is empty")
        result[trace_id] = (min(xs), min(ys), max(xs), max(ys))
    missing = required_ids - result.keys()
    if missing:
        raise ValueError(f"{path}: required trace IDs are missing: {sorted(missing)}")
    return result


def _overlap(lhs: tuple[float, float, float, float], rhs: tuple[float, float, float, float], axis: str) -> bool:
    if axis == "x":
        return lhs[0] <= rhs[2] and rhs[0] <= lhs[2]
    return lhs[1] <= rhs[3] and rhs[1] <= lhs[3]


def _preferred(group_id: str, symbol: dict[str, Any], others: list[dict[str, Any]]) -> list[str]:
    x0, y0, x1, y1 = symbol["bounds"]
    above = any(other["bounds"][3] < y0 for other in others)
    below = any(other["bounds"][1] > y1 for other in others)
    if group_id == "horizontal-bar":
        if above and below:
            return [r"\frac", "-", r"\underline", r"\overline"]
        if above:
            return [r"\underline", "-", r"\frac", r"\overline"]
        if below:
            return [r"\overline", "-", r"\frac", r"\underline"]
        return []
    if group_id == "dot-mark":
        if below:
            return [r"\dot", ".", r"\cdot", r"\vdots"]
        left = any(other["bounds"][2] < x0 and _overlap(other["bounds"], symbol["bounds"], "y") for other in others)
        right = any(other["bounds"][0] > x1 and _overlap(other["bounds"], symbol["bounds"], "y") for other in others)
        return [r"\cdot", ".", r"\dot", r"\vdots"] if left and right else []
    if group_id == "punctuation-mark":
        aligned_above = any(other["bounds"][3] < y0 and _overlap(other["bounds"], symbol["bounds"], "x") for other in others)
        aligned_below = any(other["bounds"][1] > y1 and _overlap(other["bounds"], symbol["bounds"], "x") for other in others)
        baseline = [other for other in others if (other["bounds"][2] < x0 or other["bounds"][0] > x1) and _overlap(other["bounds"], symbol["bounds"], "y")]
        is_below_baseline = bool(baseline) and (y0 + y1) / 2 > min((item["bounds"][1] + item["bounds"][3]) / 2 for item in baseline)
        if aligned_above and is_below_baseline:
            return [";", ":", ","]
        if aligned_above or aligned_below:
            return [":", ";", ","]
        if is_below_baseline:
            return [",", ";", ":"]
        return []
    if group_id == "postfix-or-accent-mark":
        base_below = any(other["bounds"][1] > y1 and _overlap(other["bounds"], symbol["bounds"], "x") for other in others)
        base_lower_left = any(other["bounds"][2] < x0 and other["bounds"][1] > y1 for other in others)
        if base_lower_left:
            return [r"\prime", r"\hat", r"\tilde", r"\vec"]
        if base_below:
            return [r"\hat", r"\tilde", r"\vec", r"\prime"]
        return []
    if group_id == "scalable-set-operator":
        upper = any(other["bounds"][3] < y0 and _overlap(other["bounds"], symbol["bounds"], "x") for other in others)
        lower = any(other["bounds"][1] > y1 and _overlap(other["bounds"], symbol["bounds"], "x") for other in others)
        left = any(other["bounds"][2] < x0 and _overlap(other["bounds"], symbol["bounds"], "y") for other in others)
        right = any(other["bounds"][0] > x1 and _overlap(other["bounds"], symbol["bounds"], "y") for other in others)
        if upper and lower:
            return [r"\bigcap", r"\cap", r"\bigcup", r"\cup", r"\bigoplus", r"\oplus", r"\bigvee", r"\vee", r"\bigwedge", r"\wedge", r"\prod"]
        if left and right:
            return [r"\cap", r"\bigcap", r"\cup", r"\bigcup", r"\oplus", r"\bigoplus", r"\vee", r"\bigvee", r"\wedge", r"\bigwedge", r"\prod"]
        return []
    if group_id == "operand-scope-operator":
        covered = any(other["bounds"][0] >= x0 and other["bounds"][2] <= x1 and _overlap(other["bounds"], symbol["bounds"], "y") for other in others)
        left = any(other["bounds"][2] < x0 and _overlap(other["bounds"], symbol["bounds"], "y") for other in others)
        right = any(other["bounds"][0] > x1 and _overlap(other["bounds"], symbol["bounds"], "y") for other in others)
        upper = any(other["bounds"][3] < y0 and _overlap(other["bounds"], symbol["bounds"], "x") for other in others)
        lower = any(other["bounds"][1] > y1 and _overlap(other["bounds"], symbol["bounds"], "x") for other in others)
        if covered:
            return [r"\sqrt", "=", r"\sum", r"\int", r"\iint", r"\oint"]
        if left and right:
            return ["=", r"\sqrt", r"\sum", r"\int", r"\iint", r"\oint"]
        if upper and lower and right:
            return [r"\sum", r"\int", r"\iint", r"\oint", "=", r"\sqrt"]
        return []
    if group_id == "letter-digit-confusable":
        neighbor_labels = [item["topLabel"] for item in others]
        if any(len(label) == 1 and label.isdecimal() for label in neighbor_labels):
            return ["0", "O", "o"]
        if any(len(label) == 1 and label.isupper() for label in neighbor_labels):
            return ["O", "o", "0"]
        if any(len(label) == 1 and label.islower() for label in neighbor_labels):
            return ["o", "O", "0"]
    return []


def add_position_rankings(
    candidate_records: list[dict[str, Any]],
    teachers_path: Path,
    source_split_path: Path,
    mathwriting_root: Path,
    vocabulary_path: Path,
    subset_path: Path,
) -> list[dict[str, Any]]:
    """Apply source-coordinate ordering to already similarity-expanded choices."""
    vocabulary = json.loads(vocabulary_path.read_text(encoding="utf-8"))
    labels = vocabulary.get("labels")
    if vocabulary.get("version") != "hinotori-v1" or not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229:
        raise ValueError("position ranking requires the exact Hinotori vocabulary")
    subset = json.loads(subset_path.read_text(encoding="utf-8"))
    if subset.get("schema") != "hinotori-position-sensitive-subset-v1" or subset.get("sourceVocabularyContract") != "hinotori-v1":
        raise ValueError("position ranking subset contract mismatch")
    groups = subset.get("groups")
    if not isinstance(groups, list) or not groups or not all(
        isinstance(group, dict)
        and isinstance(group.get("id"), str)
        and isinstance(group.get("labels"), list)
        and group["labels"]
        and all(isinstance(label, str) and label in labels for label in group["labels"])
        for group in groups
    ):
        raise ValueError("position ranking subset has no groups")
    by_index = {index: label for index, label in enumerate(labels)}
    by_label = {label: index for index, label in enumerate(labels)}
    split = json.loads(source_split_path.read_text(encoding="utf-8")).get("sourceSplit")
    if not isinstance(split, dict):
        raise ValueError("source split has no sourceSplit map")
    teacher_by_key: dict[tuple[str, tuple[int, ...]], dict[str, Any]] = {}
    teachers_by_source: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for line in teachers_path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        row = json.loads(line)
        source, strokes, class_index = row.get("sourceSampleId"), row.get("strokeIndices"), row.get("classIndex")
        if not isinstance(source, str) or not isinstance(strokes, list) or not strokes or not all(type(value) is int for value in strokes) or len(set(strokes)) != len(strokes):
            raise ValueError("invalid direct anchor teacher")
        if type(class_index) is not int or not 0 <= class_index < 229 or labels[class_index] != row.get("label"):
            raise ValueError(f"{source}: teacher label/index mismatch")
        key = (source, tuple(strokes))
        if key in teacher_by_key:
            raise ValueError(f"duplicate direct anchor teacher: {source}:{strokes}")
        teacher_by_key[key] = row
        if split.get(source) == "valid":
            teachers_by_source[source].append(row)

    records_by_key: dict[tuple[str, tuple[int, ...]], dict[str, Any]] = {}
    for record in candidate_records:
        source, strokes = record.get("sourceSampleId"), record.get("strokeIndices")
        if not isinstance(source, str) or not isinstance(strokes, list) or not strokes or not all(type(value) is int for value in strokes) or len(set(strokes)) != len(strokes):
            raise ValueError("candidate record is missing source identity or stroke indices")
        key = (source, tuple(strokes))
        teacher = teacher_by_key.get(key)
        if split.get(source) != "valid" or teacher is None or key in records_by_key:
            raise ValueError(f"candidate record is not a unique held-out direct anchor: {source}:{strokes}")
        if type(record.get("targetClassIndex")) is not int or record["targetClassIndex"] != teacher["classIndex"]:
            raise ValueError(f"{source}:{strokes}: inference target disagrees with direct teacher")
        model_indices = record.get("modelCandidateClassIndices")
        if not isinstance(model_indices, list) or any(type(value) is not int or not 0 <= value < 229 for value in model_indices):
            raise ValueError(f"{source}:{strokes}: invalid model ranking class index")
        if len(model_indices) != 229 or set(model_indices) != set(range(229)):
            raise ValueError(f"{source}:{strokes}: evaluation record must retain the complete 229-class model ranking")
        records_by_key[key] = record
    expected_keys = {(row["sourceSampleId"], tuple(row["strokeIndices"])) for rows in teachers_by_source.values() for row in rows}
    if records_by_key.keys() != expected_keys:
        missing = len(expected_keys - records_by_key.keys())
        extra = len(records_by_key.keys() - expected_keys)
        raise ValueError(f"held-out inference coverage mismatch: missing={missing}, extra={extra}")

    symbols_by_source: dict[str, list[dict[str, Any]]] = {}
    overlap_sources: set[str] = set()
    for source, rows in teachers_by_source.items():
        used: set[int] = set()
        overlapping = False
        for row in rows:
            ids = set(row["strokeIndices"])
            if used.intersection(ids):
                overlapping = True
            used.update(ids)
        if overlapping:
            overlap_sources.add(source)
            continue
        path = mathwriting_root / "train" / f"{source}.inkml"
        trace_bounds = _read_trace_bounds(path, used)
        symbols: list[dict[str, Any]] = []
        for row in rows:
            bounds = [trace_bounds[index] for index in row["strokeIndices"]]
            symbols.append({
                "key": (source, tuple(row["strokeIndices"])),
                "bounds": (min(item[0] for item in bounds), min(item[1] for item in bounds), max(item[2] for item in bounds), max(item[3] for item in bounds)),
            })
        symbols_by_source[source] = symbols

    output: list[dict[str, Any]] = []
    for source, rows in teachers_by_source.items():
        context = symbols_by_source.get(source, [])
        for row in rows:
            key = (source, tuple(row["strokeIndices"]))
            record = dict(records_by_key[key])
            model_indices = record["modelCandidateClassIndices"]
            model_labels = [by_index[index] for index in model_indices]
            displayed_model_indices = model_indices[:5]
            displayed_model_labels = model_labels[:5]
            similarity_candidates = record.get("similaritySupplementCandidates")
            if not isinstance(similarity_candidates, list):
                raise ValueError(f"{source}:{row['strokeIndices']}: similarity expansion must run before position ranking")
            display_supplements = [candidate.get("classIndex") for candidate in similarity_candidates]
            if any(type(index) is not int or not 0 <= index < 229 for index in display_supplements):
                raise ValueError(f"{source}:{row['strokeIndices']}: invalid similarity class index")
            if len(set(display_supplements)) != len(display_supplements) or set(displayed_model_indices) & set(display_supplements):
                raise ValueError(f"{source}:{row['strokeIndices']}: similarity choices duplicate displayed model choices")
            if record.get("similarityExpandedDisplayCandidateClassIndices") != displayed_model_indices + display_supplements:
                raise ValueError(f"{source}:{row['strokeIndices']}: similarity-stage choice order or identity changed")
            own = next((item for item in context if item["key"] == key), None)
            others = [dict(item, topLabel=by_index[records_by_key[item["key"]]["modelCandidateClassIndices"][0]]) for item in context if item["key"] != key]
            matching_group = next((group for group in groups if any(label in group["labels"] for label in displayed_model_labels)), None)
            preferred = _preferred(matching_group["id"], own, others) if own is not None and matching_group is not None else []
            eligible_labels = set(matching_group["labels"]) if matching_group is not None else set()

            def reorder_within_family(indices: list[int]) -> list[int]:
                eligible_slots = [slot for slot, index in enumerate(indices) if by_index[index] in eligible_labels]
                if not preferred or len(eligible_slots) < 2:
                    return list(indices)
                preference_rank = {label: rank for rank, label in enumerate(preferred)}
                family = sorted(
                    enumerate(indices[slot] for slot in eligible_slots),
                    key=lambda item: (preference_rank.get(by_index[item[1]], len(preferred)), item[0]),
                )
                output = list(indices)
                for slot, (_, class_index) in zip(eligible_slots, family):
                    output[slot] = class_index
                return output

            displayed_reordered_indices = reorder_within_family(displayed_model_indices)
            ordered_supplements = reorder_within_family(display_supplements)
            ordered_choices = displayed_reordered_indices + ordered_supplements
            reordered_indices = displayed_reordered_indices + model_indices[5:]
            ordered_full = reordered_indices
            record["reorderedModelCandidateClassIndices"] = reordered_indices
            record["positionAppliedFullCandidateClassIndices"] = ordered_full
            record["ruleSupplementedCandidateClassIndices"] = []
            record["fullRankingRuleSupplementStatus"] = "not-applicable-complete-229-class-ranking"
            record["displayedModelCandidateClassIndices"] = displayed_model_indices
            record["displayedReorderedModelCandidateClassIndices"] = displayed_reordered_indices
            record["displayedSimilarityCandidateClassIndices"] = display_supplements
            record["displayedPositionOrderedCandidateClassIndices"] = ordered_choices
            record["positionRuleVersion"] = "hinotori-position-rules-v1"
            record["positionRuleGroupID"] = matching_group["id"] if matching_group is not None else None
            record["positionRuleEvidence"] = (
                f"group={matching_group['id']}; similarity choices were generated before and independently of position; preferred-labels={','.join(preferred)}; raw MathWriting InkML X-right/Y-down bounds; user confirmation required"
                if preferred and matching_group is not None
                else f"group={matching_group['id']}; no sufficient position evidence; model order retained"
                if matching_group is not None
                else "outside-position-sensitive-subset; model order retained"
            )
            record["positionContextInstanceCount"] = 0 if source in overlap_sources else len(context)
            record["positionContextStatus"] = "overlapping-direct-groups-excluded" if source in overlap_sources else "direct-anchor-groups"
            if own is not None:
                record["sourceBounds"] = {"minX": own["bounds"][0], "minY": own["bounds"][1], "maxX": own["bounds"][2], "maxY": own["bounds"][3]}
            output.append(record)
    return output
