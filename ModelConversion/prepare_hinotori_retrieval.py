#!/usr/bin/env python3
"""Create a reproducible preflight manifest for Hinotori retrieval training.

This program does not train a classifier.  It verifies that the generated weak
multiset teachers, direct retrieval anchors, vocabulary, and source-level split
all refer to one compatible 229-class contract.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    vocabulary_document = json.loads((args.teachers / "vocabulary.json").read_text(encoding="utf-8"))
    vocabulary = vocabulary_document.get("labels")
    if not isinstance(vocabulary, list) or len(vocabulary) != 229 or len(set(vocabulary)) != 229:
        raise ValueError("vocabulary.json must contain exactly 229 unique labels")
    if vocabulary != sorted(vocabulary):
        raise ValueError("vocabulary order is not deterministic")
    vocab_index = {label: index for index, label in enumerate(vocabulary)}

    direct = read_jsonl(args.teachers / "direct-symbol-teachers.jsonl")
    split_document = json.loads(args.source_split.read_text(encoding="utf-8"))
    source_split = split_document.get("sourceSplit")
    if not isinstance(source_split, dict) or any(value not in {"train", "valid"} for value in source_split.values()):
        raise ValueError("source split must map sources to train or valid")
    weak_train = read_jsonl(args.teachers / "train-weak-symbol-teachers.jsonl")
    weak_valid = read_jsonl(args.teachers / "valid-weak-symbol-teachers.jsonl")
    direct_sources: dict[str, list[dict[str, object]]] = defaultdict(list)
    direct_class_counts = {"train": Counter(), "valid": Counter()}
    for row in direct:
        source = row.get("sourceSampleId")
        label = row.get("label")
        class_index = row.get("classIndex")
        if not isinstance(source, str) or not isinstance(label, str) or class_index != vocab_index.get(label):
            raise ValueError(f"invalid direct teacher: {row!r}")
        split = source_split.get(source)
        if split not in {"train", "valid"}:
            raise ValueError(f"direct source missing from source split: {source}")
        direct_sources[source].append(row)
        direct_class_counts[split][label] += 1
    if not direct_sources:
        raise ValueError("direct retrieval bank is empty")

    def weak_summary(rows: list[dict[str, object]]) -> dict[str, object]:
        usable = 0
        unusable = 0
        class_counts: Counter[str] = Counter()
        for row in rows:
            source, symbols, unsupported = row.get("sourceSampleId"), row.get("visualSymbols"), row.get("unsupportedTokens")
            if not isinstance(source, str) or not isinstance(symbols, list) or not isinstance(unsupported, list):
                raise ValueError(f"invalid weak teacher: {row!r}")
            if unsupported:
                unusable += 1
                continue
            if not symbols:
                raise ValueError(f"usable weak teacher has no visual symbols: {source}")
            if any(symbol not in vocab_index for symbol in symbols):
                raise ValueError(f"weak teacher has unknown class: {source}")
            usable += 1
            class_counts.update(symbols)
        return {"formulaCount": len(rows), "usableFormulaCount": usable, "excludedFormulaCount": unusable,
                "classOccurrences": {label: class_counts[label] for label in vocabulary},
                "missingClasses": [label for label in vocabulary if not class_counts[label]]}

    # Retrieval anchors exist only inside the official formula train split.
    # Their source-disjoint split is separate from the official formula-level
    # train/valid split used by weak supervision and retains all 229 labels in
    # the retrieval-bank training side.
    weak = {"train": weak_summary(weak_train), "valid": weak_summary(weak_valid)}
    report = {
        "status": "READY_FOR_TRAINING_IMPLEMENTATION_SMOKE_ONLY",
        "contract": "hinotori-retrieval-v1",
        "vocabularyCount": len(vocabulary),
        "vocabularySHA256": hashlib.sha256(json.dumps(vocabulary, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest(),
        "directAnchorCount": len(direct),
        "directAnchorSourceCount": len(direct_sources),
        "directAnchorSourceSplit": str(args.source_split),
        "directAnchorsBySplit": {split: {"count": sum(direct_class_counts[split].values()),
                                          "missingClasses": [label for label in vocabulary if not direct_class_counts[split][label]],
                                          "classCounts": {label: direct_class_counts[split][label] for label in vocabulary}}
                                 for split in ("train", "valid")},
        "weakTeachers": weak,
        "requiredNextImplementation": [
            "trajectory embedding encoder f",
            "direct-anchor embedding bank and cosine retrieval",
            "group proposer g over formula strokes",
            "optimal-transport multiset loss against weak teachers",
            "anchor group-membership and metric losses",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
