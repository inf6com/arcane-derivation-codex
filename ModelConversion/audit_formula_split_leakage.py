#!/usr/bin/env python3
"""Measure train/valid source, exact-input, target, and near-target overlap.

The CLI has no test argument and opens only MathWriting-2024/train and valid.
Near-target means normalized LaTex character 3-gram Jaccard >= threshold; it is
not represented as source provenance because this InkML contract exposes no
provenance annotation beyond sampleId.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

INK = {"ink": "http://www.w3.org/2003/InkML"}


def record(path: Path) -> tuple[str, str, str]:
    root = ET.parse(path).getroot()
    annotations = {e.attrib.get("type", ""): (e.text or "").strip() for e in root.findall("ink:annotation", INK)}
    source_id = annotations.get("sampleId", "")
    label = annotations.get("normalizedLabel", "")
    if not source_id or not label:
        raise ValueError(f"missing sampleId or normalizedLabel: {path}")
    traces = "\n".join((e.text or "").strip() for e in root.findall("ink:trace", INK))
    if not traces:
        raise ValueError(f"missing trace input: {path}")
    return source_id, label, hashlib.sha256(traces.encode("utf-8")).hexdigest()


def grams(label: str) -> set[str]:
    padded = f"  {label}  "
    return {padded[index:index + 3] for index in range(max(len(padded) - 2, 1))}


def summarize(root: Path) -> dict[str, object]:
    sources: dict[str, list[str]] = defaultdict(list)
    inputs: dict[str, list[str]] = defaultdict(list)
    input_labels: dict[str, set[str]] = defaultdict(set)
    targets: dict[str, list[str]] = defaultdict(list)
    target_grams: dict[str, set[str]] = {}
    counts = Counter()
    for path in sorted(root.glob("*.inkml")):
        source_id, label, input_hash = record(path)
        sources[source_id].append(path.name)
        inputs[input_hash].append(path.name)
        input_labels[input_hash].add(label)
        targets[label].append(path.name)
        target_grams[label] = grams(label)
        counts["script"] += label.count("^") + label.count("_")
        counts["digit"] += sum(label.count(digit) for digit in "0123456789")
        counts["targetCharacters"] += len(label)
    return {
        "pathCount": sum(len(v) for v in sources.values()),
        "sources": sources,
        "inputs": inputs,
        "inputLabels": input_labels,
        "targets": targets,
        "targetGrams": target_grams,
        "counts": counts,
    }


def overlap(left: dict[str, list[str]], right: dict[str, list[str]]) -> dict[str, object]:
    keys = sorted(set(left).intersection(right))
    return {"count": len(keys), "examples": [{"key": key, "train": left[key][:3], "valid": right[key][:3]} for key in keys[:20]]}


def input_label_conflicts(split: dict[str, object]) -> dict[str, object]:
    """Report exact serialized-trace inputs assigned more than one target."""
    inputs = split["inputs"]
    labels = split["inputLabels"]
    conflicts = [
        {"inputSHA256": key, "labels": sorted(labels[key]), "examples": inputs[key][:3]}
        for key in sorted(inputs)
        if len(labels[key]) > 1
    ]
    return {"count": len(conflicts), "examples": conflicts[:20]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--near-target-jaccard", type=float, default=0.9)
    args = parser.parse_args()
    if not 0 < args.near_target_jaccard <= 1:
        raise ValueError("--near-target-jaccard must be in (0, 1]")
    root = args.dataset_root / "mathwriting-2024"
    train, valid = summarize(root / "train"), summarize(root / "valid")
    exact_targets = set(train["targets"]).intersection(valid["targets"])
    gram_index: dict[str, list[str]] = defaultdict(list)
    for train_label, train_grams in train["targetGrams"].items():
        for gram in train_grams:
            gram_index[gram].append(train_label)
    near_pairs = []
    for valid_label, valid_grams in valid["targetGrams"].items():
        if valid_label in exact_targets:
            continue
        shared = Counter(candidate for gram in valid_grams for candidate in gram_index.get(gram, ()))
        best_label, best_score = None, 0.0
        for train_label, intersection in shared.items():
            train_grams = train["targetGrams"][train_label]
            union = len(valid_grams | train_grams)
            score = intersection / union if union else 1.0
            if score > best_score:
                best_label, best_score = train_label, score
        if best_score >= args.near_target_jaccard:
            near_pairs.append({"validTarget": valid_label, "trainTarget": best_label, "jaccard": best_score})
    report = {
        "status": "COMPLETED",
        "splitPolicy": "train and valid only; test is not opened",
        "sourceProvenance": "sampleId is the only source identifier available in the parsed InkML annotations; no original-formula provenance field exists.",
        "train": {"pathCount": train["pathCount"], "labelCharacters": train["counts"]["targetCharacters"], "scriptRate": train["counts"]["script"] / max(train["counts"]["targetCharacters"], 1), "digitRate": train["counts"]["digit"] / max(train["counts"]["targetCharacters"], 1)},
        "valid": {"pathCount": valid["pathCount"], "labelCharacters": valid["counts"]["targetCharacters"], "scriptRate": valid["counts"]["script"] / max(valid["counts"]["targetCharacters"], 1), "digitRate": valid["counts"]["digit"] / max(valid["counts"]["targetCharacters"], 1)},
        "overlap": {"sourceId": overlap(train["sources"], valid["sources"]), "completeTraceInput": overlap(train["inputs"], valid["inputs"]), "completeTarget": overlap(train["targets"], valid["targets"])},
        "withinSplitInputLabelConflict": {
            "definition": "identical serialized InkML trace text assigned more than one normalizedLabel within one split",
            "train": input_label_conflicts(train),
            "valid": input_label_conflicts(valid),
        },
        "nearTarget": {"definition": "normalized LaTex character 3-gram Jaccard", "threshold": args.near_target_jaccard, "count": len(near_pairs), "examples": near_pairs[:20]}
    }
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"sourceId": report["overlap"]["sourceId"]["count"], "input": report["overlap"]["completeTraceInput"]["count"], "target": report["overlap"]["completeTarget"]["count"], "near": len(near_pairs)}))


if __name__ == "__main__":
    main()
