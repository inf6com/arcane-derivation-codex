#!/usr/bin/env python3
"""Validate every direct Hinotori retrieval anchor against source InkML."""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from hinotori_direct_dataset import DirectAnchorDataset


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--point-count", type=int, default=32)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report: dict[str, object] = {"contract": "hinotori-retrieval-v1", "pointCount": args.point_count, "splits": {}}
    for split in ("train", "valid"):
        dataset = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, args.point_count, split)
        class_counts: Counter[int] = Counter()
        stroke_counts: Counter[int] = Counter()
        point_total = 0
        for index in range(len(dataset)):
            sample = dataset[index]
            group = sample["points"]
            if not hasattr(group, "shape"):
                raise ValueError(f"dataset returned invalid group at {index}")
            class_counts[int(sample["classIndex"])] += 1
            stroke_counts[int(group.shape[0])] += 1
            point_total += int(group.numel() // 2)
        report["splits"][split] = {
            "anchorCount": len(dataset),
            "classCount": len(class_counts),
            "missingClasses": [class_index for class_index in range(229) if class_index not in class_counts],
            "strokeCountHistogram": dict(sorted(stroke_counts.items())),
            "canonicalPointCount": point_total,
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
