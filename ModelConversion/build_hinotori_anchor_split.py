#!/usr/bin/env python3
"""Create a source-disjoint direct-anchor split with all 229 classes in train."""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path


def build_split(rows: list[dict[str, object]], valid_fraction: float = 0.2) -> dict[str, str]:
    """Move deterministic sources to valid only when train keeps every class."""
    if not 0 < valid_fraction < 1:
        raise ValueError("valid_fraction must be between zero and one")
    by_source: dict[str, list[dict[str, object]]] = defaultdict(list)
    counts: Counter[int] = Counter()
    for row in rows:
        source, class_index = row.get("sourceSampleId"), row.get("classIndex")
        if not isinstance(source, str) or not isinstance(class_index, int) or not 0 <= class_index < 229:
            raise ValueError("direct anchors require sourceSampleId and classIndex in [0,229)")
        by_source[source].append(row)
        counts[class_index] += 1
    if set(counts) != set(range(229)):
        missing = sorted(set(range(229)) - set(counts))
        raise ValueError(f"direct anchors do not cover all 229 classes: {missing}")
    target = round(len(rows) * valid_fraction)
    valid_count = 0
    split = {source: "train" for source in by_source}
    for source in sorted(by_source, key=lambda value: hashlib.sha256(value.encode("utf-8")).digest()):
        source_counts = Counter(int(row["classIndex"]) for row in by_source[source])
        if valid_count + len(by_source[source]) > target:
            continue
        if any(counts[class_index] - count < 1 for class_index, count in source_counts.items()):
            continue
        split[source] = "valid"
        valid_count += len(by_source[source])
        counts.subtract(source_counts)
    if any(counts[class_index] < 1 for class_index in range(229)):
        raise AssertionError("split construction lost train class coverage")
    return split


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--anchors", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.anchors.read_text(encoding="utf-8").splitlines() if line]
    split = build_split(rows)
    report = {"contract": "hinotori-retrieval-v1", "sourceSplit": split,
              "anchorCounts": {name: sum(1 for row in rows if split[str(row["sourceSampleId"])] == name) for name in ("train", "valid")},
              "sourceCounts": {name: sum(1 for value in split.values() if value == name) for name in ("train", "valid")}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
