#!/usr/bin/env python3
"""Materialize deterministic weak-teacher subsets for every Hinotori label.

Each usable formula belongs to every subset whose visual-symbol multiset,
derived from its final LaTeX, contains that label.  This is formula-level
membership only; it does not invent a stroke-to-symbol assignment.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path


CONTRACT = "hinotori-latex-membership-subsets-v1"


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def canonical_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def build_subsets(teachers: Path, output: Path) -> dict[str, object]:
    vocabulary_document = json.loads((teachers / "vocabulary.json").read_text(encoding="utf-8"))
    labels = vocabulary_document.get("labels")
    if not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229 or labels != sorted(labels):
        raise ValueError("vocabulary.json must contain 229 unique sorted labels")
    if any(not isinstance(label, str) or not label for label in labels):
        raise ValueError("vocabulary labels must be nonempty strings")
    vocabulary = {label: index for index, label in enumerate(labels)}

    members: list[list[dict[str, str]]] = [[] for _ in labels]
    usable_count = 0
    excluded_count = 0
    seen: set[tuple[str, str]] = set()
    for split in ("train", "valid"):
        for row_number, row in enumerate(read_jsonl(teachers / f"{split}-weak-symbol-teachers.jsonl"), start=1):
            source = row.get("sourceSampleId")
            symbols = row.get("visualSymbols")
            unsupported = row.get("unsupportedTokens")
            if not isinstance(source, str) or not source or not isinstance(symbols, list) or not isinstance(unsupported, list):
                raise ValueError(f"{split}:{row_number}: invalid weak teacher row")
            key = (split, source)
            if key in seen:
                raise ValueError(f"{split}:{row_number}: duplicate sourceSampleId {source}")
            seen.add(key)
            if unsupported:
                excluded_count += 1
                continue
            if not symbols or any(not isinstance(symbol, str) or symbol not in vocabulary for symbol in symbols):
                raise ValueError(f"{split}:{row_number}: usable formula has invalid visualSymbols")
            usable_count += 1
            membership = {vocabulary[symbol] for symbol in symbols}
            for class_index in membership:
                members[class_index].append({"split": split, "sourceSampleId": source})

    output.mkdir(parents=True, exist_ok=True)
    index_rows: list[dict[str, object]] = []
    for class_index, label in enumerate(labels):
        entries = sorted(members[class_index], key=lambda item: (item["split"], item["sourceSampleId"]))
        document = {
            "contract": CONTRACT,
            "classIndex": class_index,
            "label": label,
            "memberFormulaCount": len(entries),
            "members": entries,
        }
        filename = f"class-{class_index:03d}.json"
        payload = canonical_bytes(document)
        (output / filename).write_bytes(payload)
        index_rows.append({
            "classIndex": class_index,
            "label": label,
            "memberFormulaCount": len(entries),
            "memberSHA256": hashlib.sha256(payload).hexdigest(),
            "file": filename,
        })

    manifest = {
        "contract": CONTRACT,
        "vocabularySHA256": hashlib.sha256(canonical_bytes(labels)).hexdigest(),
        "formulaUniverse": {
            "definition": "all train and valid weak teachers whose final LaTeX maps fully to the fixed 229-symbol vocabulary",
            "usableFormulaCount": usable_count,
            "excludedUnsupportedFormulaCount": excluded_count,
        },
        "membershipDefinition": "a formula is a member when its LaTeX-derived visualSymbols contains the label at least once",
        "subsets": index_rows,
    }
    (output / "manifest.json").write_bytes(canonical_bytes(manifest))
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = build_subsets(args.teachers, args.output)
    print(json.dumps({"status": "COMPLETED", "usableFormulaCount": manifest["formulaUniverse"]["usableFormulaCount"], "subsetCount": len(manifest["subsets"])}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
