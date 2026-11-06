#!/usr/bin/env python3
"""Build a direct-symbol source holdout that excludes all prior outer tests."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from collections import Counter, defaultdict
from pathlib import Path


CLASS_COUNT = 229


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_jsonl(path: Path) -> list[dict[str, object]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def select_sources(
    candidates: list[str],
    groups: dict[str, list[dict[str, object]]],
    *,
    target_samples: int,
    seed: int,
    available_class_source_counts: Counter[int],
) -> list[str]:
    """Select whole sources for broad class coverage without emptying fit classes."""
    rng = random.Random(seed)
    rng.shuffle(candidates)
    tie_rank = {source: rank for rank, source in enumerate(candidates)}
    source_classes = {
        source: {int(row["classIndex"]) for row in groups[source]}
        for source in candidates
    }
    selected: list[str] = []
    selected_classes: set[int] = set()
    sample_count = 0
    remaining = available_class_source_counts.copy()
    while sample_count < target_samples:
        eligible: list[tuple[float, str]] = []
        for source in candidates:
            if source in selected or sample_count + len(groups[source]) > target_samples:
                continue
            classes = source_classes[source]
            if any(remaining[c] <= 1 for c in classes):
                continue
            new_classes = classes - selected_classes
            rarity_bonus = sum(1.0 / max(remaining[c], 1) for c in new_classes)
            score = len(new_classes) * 1000.0 + rarity_bonus - tie_rank[source] * 1e-9
            eligible.append((score, source))
        if not eligible:
            break
        _, chosen = max(eligible)
        selected.append(chosen)
        selected_classes.update(source_classes[chosen])
        sample_count += len(groups[chosen])
        remaining.subtract(source_classes[chosen])
    if not selected:
        raise ValueError("cannot construct a source holdout without removing a training class")
    return selected


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--exclude-test-teachers", type=Path, nargs="+", required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fold-name", default="fold-05")
    parser.add_argument("--target-test-samples", type=int, default=500)
    parser.add_argument("--target-valid-samples", type=int, default=450)
    parser.add_argument("--seed", type=int, default=20261112)
    args = parser.parse_args()
    if args.target_test_samples < 1 or args.target_valid_samples < 1:
        raise ValueError("target partition sizes must be positive")
    teacher_bytes = args.teachers.read_bytes()
    rows = [json.loads(line) for line in teacher_bytes.decode("utf-8").splitlines() if line]
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary_doc = json.loads(vocabulary_bytes)
    vocabulary = vocabulary_doc.get("labels") if isinstance(vocabulary_doc, dict) else None
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain exactly 229 unique ordered labels")
    groups: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        source = row.get("sourceSampleId")
        index = row.get("classIndex")
        if not isinstance(source, str) or not source or not isinstance(index, int) or not 0 <= index < CLASS_COUNT:
            raise ValueError("direct teachers must contain valid sourceSampleId and classIndex")
        if row.get("label") != vocabulary[index]:
            raise ValueError(f"teacher label disagrees with vocabulary at source {source}")
        groups[source].append(row)
    total_class_sources = Counter(index for group in groups.values() for index in {int(row["classIndex"]) for row in group})
    if set(total_class_sources) != set(range(CLASS_COUNT)):
        raise ValueError("direct teachers do not cover every vocabulary class")

    prior_test_sources: set[str] = set()
    prior_test_hashes: dict[str, str] = {}
    for path in args.exclude_test_teachers:
        excluded_rows = load_jsonl(path)
        source_ids = {str(row["sourceSampleId"]) for row in excluded_rows}
        prior_test_sources.update(source_ids)
        prior_test_hashes[str(path)] = digest(path.read_bytes())
    eligible_test_sources = sorted(set(groups) - prior_test_sources)
    if not eligible_test_sources:
        raise ValueError("no never-before-tested source formulas remain")

    test_sources = select_sources(
        eligible_test_sources,
        groups,
        target_samples=args.target_test_samples,
        seed=args.seed,
        available_class_source_counts=total_class_sources,
    )
    test_set = set(test_sources)
    fit_sources = sorted(set(groups) - test_set)
    fit_class_sources = Counter(index for source in fit_sources for index in {int(row["classIndex"]) for row in groups[source]})
    if set(fit_class_sources) != set(range(CLASS_COUNT)):
        raise ValueError(f"fit pool is missing classes: {sorted(set(range(CLASS_COUNT)) - set(fit_class_sources))}")
    valid_sources = select_sources(
        fit_sources.copy(),
        groups,
        target_samples=args.target_valid_samples,
        seed=args.seed + 1,
        available_class_source_counts=fit_class_sources,
    )
    valid_set = set(valid_sources)
    train_sources = set(fit_sources) - valid_set
    train_class_sources = Counter(index for source in train_sources for index in {int(row["classIndex"]) for row in groups[source]})
    if set(train_class_sources) != set(range(CLASS_COUNT)):
        raise ValueError(f"fit train is missing classes: {sorted(set(range(CLASS_COUNT)) - set(train_class_sources))}")

    output = args.output
    output.mkdir(parents=True, exist_ok=False)
    fit_rows = [row for row in rows if str(row["sourceSampleId"]) in train_sources | valid_set]
    test_rows = [row for row in rows if str(row["sourceSampleId"]) in test_set]
    fit_path = output / "fit-teachers.jsonl"
    test_path = output / "test-teachers.jsonl"
    fit_bytes = "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in fit_rows).encode("utf-8")
    test_bytes = "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in test_rows).encode("utf-8")
    fit_path.write_bytes(fit_bytes)
    test_path.write_bytes(test_bytes)
    fit_roles = {source: "train" for source in train_sources}
    fit_roles.update({source: "valid" for source in valid_set})
    fit_split_bytes = json.dumps({"sourceSplit": fit_roles}, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    test_split_bytes = json.dumps({"sourceSplit": {source: "valid" for source in test_set}}, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    fit_split_path, test_split_path = output / "fit-source-split.json", output / "test-source-split.json"
    fit_split_path.write_bytes(fit_split_bytes)
    test_split_path.write_bytes(test_split_bytes)
    class_counts = lambda sources: [sum(1 for source in sources for row in groups[source] if int(row["classIndex"]) == class_index) for class_index in range(CLASS_COUNT)]
    report = {
        "task": "229-class isolated direct-symbol recognition",
        "fold": args.fold_name,
        "seed": args.seed,
        "groupUnit": "sourceSampleId original formula; no formula is divided across partitions",
        "testConstruction": "Never-before-tested direct-teacher sources only; deterministic seeded greedy source selection maximizes newly observed class coverage while retaining every class in the fit pool.",
        "excludedPriorTestTeacherSHA256": prior_test_hashes,
        "sourceCounts": {"fitTrain": len(train_sources), "innerValid": len(valid_set), "outerTest": len(test_set)},
        "sampleCounts": {"fitTrain": sum(len(groups[s]) for s in train_sources), "innerValid": sum(len(groups[s]) for s in valid_set), "outerTest": len(test_rows)},
        "neverTestedSourcePool": len(eligible_test_sources),
        "testObservedClasses": len({int(row["classIndex"]) for row in test_rows}),
        "testAbsentClasses": sorted(set(range(CLASS_COUNT)) - {int(row["classIndex"]) for row in test_rows}),
        "classSupport": {"fitTrain": class_counts(train_sources), "innerValid": class_counts(valid_set), "outerTest": class_counts(test_set)},
        "hashes": {"sourceTeachers": digest(teacher_bytes), "vocabulary": digest(vocabulary_bytes), "fitTeachers": digest(fit_bytes), "testTeachers": digest(test_bytes), "fitSourceSplit": digest(fit_split_bytes), "testSourceSplit": digest(test_split_bytes)},
        "usage": "Use only fitTrain for optimization and prototypes, innerValid for checkpoint and fusion selection, and do not open outerTest predictions until all model and fusion choices are frozen."
    }
    (output / "manifest.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("sourceCounts", "sampleCounts", "neverTestedSourcePool", "testObservedClasses", "testAbsentClasses", "hashes")}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
