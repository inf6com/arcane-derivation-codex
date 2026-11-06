#!/usr/bin/env python3
"""Extract only `normalizedLabel` (+ sampleId) from every MathWriting-2024
whole-formula InkML file, for tokenizer design. No stroke coordinates are
read or written: this does not touch the `FormulaInput v1` contract and does
not overlap with the local automation loop's PencilKit-parity work.

Usage:
    python3 extract_normalized_labels.py \
        --dataset-root /Volumes/ORICO/Developer/inf6-training/dataset \
        --output normalized-labels.jsonl
"""
from __future__ import annotations

import argparse
import json
import xml.etree.ElementTree as ET
from pathlib import Path

INKML_NAMESPACE = "http://www.w3.org/2003/InkML"
INK = {"ink": INKML_NAMESPACE}


def read_label(path: Path) -> tuple[str, str] | None:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return None
    sample_id = None
    label = None
    for element in root.findall("ink:annotation", INK):
        kind = element.attrib.get("type")
        if kind == "sampleId":
            sample_id = (element.text or "").strip()
        elif kind == "normalizedLabel":
            label = (element.text or "").strip()
    if sample_id is None or label is None:
        return None
    return sample_id, label


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True, help="directory containing mathwriting-2024/")
    parser.add_argument("--output", type=Path, required=True, help="output JSONL path")
    args = parser.parse_args()

    root = args.dataset_root / "mathwriting-2024"
    counts = {}
    with args.output.open("w", encoding="utf-8") as out:
        for split in ("train", "valid", "test"):
            split_root = root / split
            n = 0
            missing = 0
            for entry in sorted(split_root.iterdir()):
                if not entry.name.endswith(".inkml"):
                    continue
                result = read_label(entry)
                if result is None:
                    missing += 1
                    continue
                sample_id, label = result
                out.write(json.dumps({"split": split, "sampleId": sample_id, "normalizedLabel": label}, ensure_ascii=False) + "\n")
                n += 1
            counts[split] = {"written": n, "missingAnnotation": missing}
            print(f"{split}: wrote {n}, missing {missing}")

    print(json.dumps(counts, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
