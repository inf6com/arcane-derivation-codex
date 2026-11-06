#!/usr/bin/env python3
"""Audit train-only structural teachers and their supervised-symbol join coverage."""
from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path


def walk(node: dict, depth: int, depths: Counter, kinds: Counter) -> None:
    kinds[node["k"]] += 1
    depths[depth] += 1
    for value in node.values():
        if isinstance(value, list):
            for child in value:
                if isinstance(child, dict) and "k" in child:
                    walk(child, depth + 1, depths, kinds)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--teacher-report", type=Path, required=True)
    parser.add_argument("--symbols", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    report = json.loads(args.teacher_report.read_text(encoding="utf-8"))
    # Failed labels are a required audit output for unsupported grammar.  The
    # accepted subset may still be inspected, but is never eligible for model
    # training while this count is nonzero.

    source_ids: set[str] = set()
    token_counts = Counter()
    relation_counts = Counter()
    ast_kinds = Counter()
    ast_depths = Counter()
    formula_count = 0
    total_tokens = 0
    for line in args.teachers.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        formula_count += 1
        source_ids.add(record["sampleId"])
        total_tokens += len(record["visualTokens"])
        token_counts.update(record["visualTokens"])
        relation_counts.update(edge[2] for edge in record["relations"])
        walk(record["ast"], 0, ast_depths, ast_kinds)
    if formula_count != report["accepted"]:
        raise ValueError(f"teacher line count {formula_count} != report accepted {report['accepted']}")

    annotations_by_source: dict[str, list[dict]] = defaultdict(list)
    for line in args.symbols.read_text(encoding="utf-8").splitlines():
        annotation = json.loads(line)
        required = ("sourceSampleId", "strokeIndices", "label")
        if any(key not in annotation for key in required):
            raise ValueError(f"invalid symbol annotation: {annotation!r}")
        annotations_by_source[annotation["sourceSampleId"]].append(annotation)
    joinable = sorted(set(annotations_by_source) & source_ids)
    unjoinable = sorted(set(annotations_by_source) - source_ids)
    relation_required_by_schema = {
        "baseline", "superscript", "subscript", "numerator", "denominator",
        "radicand", "radical-index", "matrix-row", "matrix-cell", "delimiter",
    }
    observed_relations = set(relation_counts)
    output = {
        "teacherInputSHA256": report["inputSHA256"],
        "teacherOutputSHA256": report["outputSHA256"],
        "teacherFormulaCount": formula_count,
        "teacherFailedLabels": report["failed"],
        "teacherFailureSamples": report["errors"][:20],
        "trainingAdmissible": report["failed"] == 0,
        "visualTokenCount": total_tokens,
        "visualTokenVocabulary": len(token_counts),
        "visualTokenFrequency": dict(sorted(token_counts.items())),
        "relationFrequency": dict(sorted(relation_counts.items())),
        "astKindFrequency": dict(sorted(ast_kinds.items())),
        "astDepthFrequency": {str(key): value for key, value in sorted(ast_depths.items())},
        "requiredRelationKinds": sorted(relation_required_by_schema),
        "missingRequiredRelationKinds": sorted(relation_required_by_schema - observed_relations),
        "symbolAnnotations": sum(map(len, annotations_by_source.values())),
        "symbolAnnotatedFormulaCount": len(annotations_by_source),
        "symbolJoinableFormulaCount": len(joinable),
        "symbolJoinRate": len(joinable) / len(annotations_by_source) if annotations_by_source else 0,
        "symbolJoinableAnnotationCount": sum(len(annotations_by_source[key]) for key in joinable),
        "symbolUnjoinableSourceSampleIDs": unjoinable,
    }
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(output, ensure_ascii=False))


if __name__ == "__main__":
    main()
