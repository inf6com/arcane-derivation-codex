#!/usr/bin/env python3
"""Measure whether direct symbol teachers support ordered prefix decoding."""
from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

from hinotori_inkml import read_inkml_traces


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.teachers.read_text(encoding="utf-8").splitlines() if line]
    by_source: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        source, indices = row.get("sourceSampleId"), row.get("strokeIndices")
        if not isinstance(source, str) or not isinstance(indices, list) or not all(isinstance(value, int) for value in indices):
            raise ValueError("invalid direct teacher row")
        by_source[source].append(row)
    counts: Counter[str] = Counter()
    group_lengths: Counter[int] = Counter()
    sources_with_multiple_groups = 0
    trace_order_matches_x_order = 0
    trace_order_compared = 0
    examples: list[dict[str, object]] = []
    overlapping_sources: list[dict[str, object]] = []
    for source, groups in sorted(by_source.items()):
        if len(groups) < 2:
            continue
        path = args.mathwriting_root / "train" / f"{source}.inkml"
        traces = read_inkml_traces(path)
        sources_with_multiple_groups += 1
        group_data: list[dict[str, object]] = []
        used: set[int] = set()
        overlap: set[int] = set()
        for row in groups:
            indices = row["strokeIndices"]
            if any(index not in traces for index in indices):
                raise ValueError(f"{source}: annotation refers to absent trace")
            group_lengths[len(indices)] += 1
            sorted_indices = sorted(indices)
            if indices == sorted_indices:
                counts["annotationIndicesAscending"] += 1
            if sorted_indices == list(range(sorted_indices[0], sorted_indices[-1] + 1)):
                counts["groupTraceIdsContiguous"] += 1
            overlap.update(used.intersection(indices))
            used.update(indices)
            x_left = min(float(traces[index][:, 0].min()) for index in indices)
            group_data.append({"label": row.get("label"), "strokeIndices": indices, "minimumTraceId": min(indices), "xLeft": x_left})
        if overlap:
            if len(overlapping_sources) < 20:
                overlapping_sources.append({"sourceSampleId": source, "overlappingTraceIds": sorted(overlap), "groups": group_data})
            counts["overlappingAnnotatedSources"] += 1
            counts["overlappingAnnotatedGroups"] += len(group_data)
            continue
        trace_order = [item["label"] for item in sorted(group_data, key=lambda item: item["minimumTraceId"])]
        x_order = [item["label"] for item in sorted(group_data, key=lambda item: item["xLeft"])]
        trace_order_compared += 1
        if trace_order == x_order:
            trace_order_matches_x_order += 1
        elif len(examples) < 20:
            examples.append({"sourceSampleId": source, "traceIdOrder": trace_order, "xLeftOrder": x_order, "groups": group_data})
    total_groups = sum(group_lengths.values())
    report = {
        "status": "COMPLETED",
        "scope": "direct symbol teachers with at least two annotated groups",
        "sourcesWithMultipleAnnotatedGroups": sources_with_multiple_groups,
        "annotatedGroupCount": total_groups,
        "groupStrokeLengthHistogram": {str(key): value for key, value in sorted(group_lengths.items())},
        "maximumObservedGroupStrokeCount": max(group_lengths, default=0),
        "annotationIndicesAscendingCount": counts["annotationIndicesAscending"],
        "groupTraceIdsContiguousCount": counts["groupTraceIdsContiguous"],
        "traceIdOrderMatchesSpatialLeftToRightCount": trace_order_matches_x_order,
        "traceIdOrderComparedCount": trace_order_compared,
        "traceIdOrderMatchesSpatialLeftToRightRate": trace_order_matches_x_order / trace_order_compared if trace_order_compared else None,
        "overlappingAnnotatedSourceCount": counts["overlappingAnnotatedSources"],
        "overlappingAnnotatedGroupCount": counts["overlappingAnnotatedGroups"],
        "overlappingExamples": overlapping_sources,
        "nonMatchingExamples": examples,
        "interpretation": "InkML trace ids are neither timestamps nor reading order. This report measures their disagreement with the required spatial left-to-right reading order; the classifier must learn leftmost symbol membership from direct stroke groups and coordinates.",
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
