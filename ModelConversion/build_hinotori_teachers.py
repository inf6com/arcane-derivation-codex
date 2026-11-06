#!/usr/bin/env python3
"""Build the only teacher artifacts allowed by the 229-symbol classifier.

It never rasterizes ink, decodes LaTeX, or invents a stroke-to-token mapping.
Direct annotations remain direct; formula labels become weak visual-symbol
multisets only when every visual token is in the fixed 229-class vocabulary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path


COMMAND = re.compile(r"\\[A-Za-z]+|\\[^A-Za-z\s]")
STRUCTURAL_COMMANDS = {"\\left", "\\right", "\\begin", "\\end", "\\mathrm", "\\text", "\\operatorname"}
STRUCTURAL_CHARACTERS = {"^", "_", "{", "}", " ", "\t", "\n", "\r"}
INK = {"ink": "http://www.w3.org/2003/InkML"}


class DirectTeacherConflict(ValueError):
    def __init__(self, conflicts: list[dict[str, object]]):
        self.conflicts = conflicts
        super().__init__(f"direct teacher contains {len(conflicts)} overlapping stroke assignments")


def read_vocab(symbols: Path) -> list[str]:
    labels: list[str] = []
    for number, line in enumerate(symbols.read_text(encoding="utf-8").splitlines(), start=1):
        record = json.loads(line)
        label = record.get("label")
        if not isinstance(label, str) or not label:
            raise ValueError(f"symbols.jsonl:{number}: invalid label")
        labels.append(label)
    vocab = sorted(set(labels))
    if len(vocab) != 229:
        raise ValueError(f"expected exactly 229 labels, found {len(vocab)}")
    return vocab


def parse_visual_tokens(label: str, vocabulary: set[str]) -> tuple[list[str], list[str]]:
    """Return visual 229 tokens and unsupported lexical units without guessing."""
    tokens: list[str] = []
    unsupported: list[str] = []
    position = 0
    while position < len(label):
        character = label[position]
        if character == "\\":
            command = COMMAND.match(label, position)
            if command is None:
                unsupported.append(label[position:position + 1])
                position += 1
                continue
            unit = command.group(0)
            position = command.end()
            if unit in STRUCTURAL_COMMANDS:
                continue
            # MathWriting's direct-symbol vocabulary includes \mathbb{X} as
            # one class; consume it as one lexical unit, never as braces.
            if unit == "\\mathbb" and position + 2 < len(label) and label[position] == "{" and label[position + 2] == "}":
                unit = f"\\mathbb{{{label[position + 1]}}}"
                position += 3
            if unit in vocabulary:
                tokens.append(unit)
            else:
                unsupported.append(unit)
            continue
        position += 1
        if character in STRUCTURAL_CHARACTERS:
            continue
        if character in vocabulary:
            tokens.append(character)
        else:
            unsupported.append(character)
    return tokens, unsupported


def inkml_label(path: Path) -> str:
    root = ET.parse(path).getroot()
    found = [((node.text or "").strip()) for node in root.findall("ink:annotation", INK) if node.attrib.get("type") == "normalizedLabel"]
    if len(found) != 1 or not found[0]:
        raise ValueError(f"{path}: expected one nonempty normalizedLabel")
    return found[0]


def direct_teachers(symbols: Path, vocabulary: set[str]) -> tuple[list[dict[str, object]], dict[str, object]]:
    rows: list[dict[str, object]] = []
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for number, line in enumerate(symbols.read_text(encoding="utf-8").splitlines(), start=1):
        record = json.loads(line)
        source, indices, label = record.get("sourceSampleId"), record.get("strokeIndices"), record.get("label")
        if not isinstance(source, str) or not isinstance(indices, list) or not indices or not isinstance(label, str):
            raise ValueError(f"symbols.jsonl:{number}: invalid direct teacher")
        if label not in vocabulary or any(not isinstance(index, int) or index < 0 for index in indices) or len(indices) != len(set(indices)):
            raise ValueError(f"symbols.jsonl:{number}: invalid direct teacher values")
        row = {"sourceSampleId": source, "strokeIndices": indices, "classIndex": sorted(vocabulary).index(label), "label": label}
        grouped[source].append(row)
    # One stroke cannot silently belong to two distinct direct symbols. Drop
    # only annotations touching a conflicted stroke; preserve unrelated direct
    # symbols from the same formula source.
    conflicted_sources: list[dict[str, object]] = []
    for source, entries in grouped.items():
        unique = {(tuple(entry["strokeIndices"]), entry["label"]): entry for entry in entries}
        owner: dict[int, str] = {}
        conflicts: list[dict[str, object]] = []
        conflicted_strokes: set[int] = set()
        for entry in unique.values():
            for index in entry["strokeIndices"]:
                prior = owner.setdefault(index, entry["label"])
                if prior != entry["label"]:
                    conflicts.append({"strokeIndex": index, "firstLabel": prior, "secondLabel": entry["label"]})
                    conflicted_strokes.add(index)
        retained = [entry for entry in unique.values() if not set(entry["strokeIndices"]) & conflicted_strokes]
        rows.extend(retained)
        if conflicts:
            excluded_annotations = [entry for entry in unique.values() if set(entry["strokeIndices"]) & conflicted_strokes]
            conflicted_sources.append({
                "sourceSampleId": source,
                "reason": "only annotations touching strokes assigned to multiple labels were excluded",
                "conflicts": conflicts,
                "excludedAnnotations": excluded_annotations,
                "retainedAnnotationCount": len(retained),
            })
    return rows, {"records": len(rows), "sourceFormulaCount": len({row["sourceSampleId"] for row in rows}), "sourcesWithConflicts": conflicted_sources}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--splits", choices=("train", "valid"), nargs="+", default=["train", "valid"])
    parser.add_argument("--direct-only", action="store_true", help="build official isolated-symbol teachers without scanning formula-level weak labels")
    args = parser.parse_args()
    root = args.dataset_root / "mathwriting-2024"
    symbols = root / "symbols.jsonl"
    vocab = read_vocab(symbols)
    vocabulary = set(vocab)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    direct, direct_report = direct_teachers(symbols, vocabulary)
    vocab_bytes = json.dumps({"version": "hinotori-v1", "labels": vocab}, ensure_ascii=False, separators=(",", ":")).encode()
    (args.output_dir / "vocabulary.json").write_bytes(vocab_bytes)
    (args.output_dir / "direct-symbol-teachers.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in direct), encoding="utf-8")
    report: dict[str, object] = {
        "status": "COMPLETED", "vocabularyCount": len(vocab),
        "vocabularySHA256": hashlib.sha256(vocab_bytes).hexdigest(),
        "direct": direct_report, "splits": {},
        "mode": "official isolated-symbol annotations only" if args.direct_only else "direct annotations and formula-level weak labels",
    }
    for split in ([] if args.direct_only else args.splits):
        rows: list[dict[str, object]] = []
        unsupported = 0
        for path in sorted((root / split).glob("*.inkml")):
            label = inkml_label(path)
            tokens, bad = parse_visual_tokens(label, vocabulary)
            row = {"sourceSampleId": path.stem, "normalizedLabel": label, "visualSymbols": tokens, "unsupportedTokens": bad}
            rows.append(row)
            unsupported += bool(bad)
        target = args.output_dir / f"{split}-weak-symbol-teachers.jsonl"
        target.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")
        report["splits"][split] = {"formulaCount": len(rows), "usableCount": len(rows) - unsupported, "unsupportedCount": unsupported, "output": str(target)}
    (args.output_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
