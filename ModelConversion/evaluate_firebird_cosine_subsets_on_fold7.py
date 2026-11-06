#!/usr/bin/env python3
"""Evaluate provisional font-derived similarity groups after Fold-07 ranking."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_spatial_pyramid import HinotoriSpatialPyramidAngularMargin
from train_hinotori_raster_classifier import collate_rasters


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_provisional_groups(path: Path, label_kinds_path: Path, vocabulary: list[str]) -> tuple[dict[str, set[str]], str, int]:
    kind_bytes = label_kinds_path.read_bytes()
    kind_data = json.loads(kind_bytes)
    entries = kind_data["entries"]
    mapped_labels = [entry.get("label") for entry in entries]
    if len(mapped_labels) != 229 or len(set(mapped_labels)) != 229 or set(mapped_labels) != set(vocabulary):
        raise ValueError("glyph mapping does not cover the exact Fold-07 label set")
    scalar_to_label: dict[str, str] = {}
    for entry in entries:
        scalar = entry.get("unicodeScalar")
        label = entry.get("label")
        if scalar is not None:
            if scalar in scalar_to_label and scalar_to_label[scalar] != label:
                raise ValueError(f"ambiguous vocabulary glyph mapping for {scalar}")
            scalar_to_label[scalar] = label
    vocabulary_set = set(vocabulary)
    groups: list[set[str]] = []
    with path.open(encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            glyphs = row["symbols"].split("、")
            if len(glyphs) < 5 or len(glyphs) != len(set(glyphs)):
                raise ValueError(f"malformed or undersized provisional group {row.get('merged_group')}")
            labels: set[str] = set()
            for glyph in glyphs:
                if len(glyph) != 1:
                    raise ValueError(f"group contains a non-single-codepoint glyph: {glyph!r}")
                label = scalar_to_label.get(f"U+{ord(glyph):04X}")
                if label is None or label not in vocabulary_set:
                    raise ValueError(f"group glyph is absent from the verified Fold-07 vocabulary: {glyph!r}")
                labels.add(label)
            if len(labels) != len(glyphs):
                raise ValueError(f"two displayed glyphs map to one Fold-07 label in group {row.get('merged_group')}")
            groups.append(labels)
    if not groups:
        raise ValueError("provisional similarity table has no groups")

    expansions = {label: {label} for label in vocabulary}
    for group in groups:
        for label in group:
            expansions[label].update(group)
    if len(groups) != 87:
        raise ValueError(f"expected the selected provisional 87-group table, found {len(groups)} groups")
    return expansions, hashlib.sha256(kind_bytes).hexdigest(), len(groups)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--label-kinds", type=Path, required=True)
    parser.add_argument("--similarity-groups", type=Path, required=True)
    parser.add_argument("--fold7-checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples-csv", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()
    if args.output.exists() or args.samples_csv.exists():
        raise FileExistsError("refusing to overwrite an existing Fold-07 evaluation artifact")
    if args.batch_size < 1 or not torch.backends.mps.is_available():
        raise RuntimeError("A positive batch size and available MPS device are required; CPU fallback is prohibited")

    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary = json.loads(vocabulary_bytes)["labels"]
    if len(vocabulary) != 229 or len(set(vocabulary)) != 229:
        raise ValueError("expected the exact 229-label Fold-07 vocabulary")
    expansions, label_kinds_hash, group_count = read_provisional_groups(
        args.similarity_groups, args.label_kinds, vocabulary
    )
    checkpoint_bytes = args.fold7_checkpoint.read_bytes()
    checkpoint = torch.load(args.fold7_checkpoint, map_location="cpu", weights_only=False)
    run = checkpoint.get("run", {})
    if run.get("task") != "229-way isolated handwritten symbol classification":
        raise ValueError("Fold-07 checkpoint task mismatch")
    if run.get("vocabularySHA256") != hashlib.sha256(vocabulary_bytes).hexdigest():
        raise ValueError("Fold-07 checkpoint and supplied ordered vocabulary hashes differ")
    if run.get("trainTeachersSHA256") != sha256_file(args.teachers):
        raise ValueError("Fold-07 checkpoint and direct-teacher file hashes differ")
    if run.get("sourceSplitSHA256") != sha256_file(args.source_split):
        raise ValueError("Fold-07 checkpoint and source-split file hashes differ")
    if run.get("validSourceFingerprint") is None:
        raise ValueError("Fold-07 checkpoint has no source-disjoint validation provenance")

    training = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "train")
    validation = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "valid")
    for row in training.rows + validation.rows:
        class_index = row["classIndex"]
        if not isinstance(class_index, int) or not 0 <= class_index < len(vocabulary) or row.get("label") != vocabulary[class_index]:
            raise ValueError("Fold-07 teacher label/index does not match the verified vocabulary order")
    validation_sources = {str(row["sourceSampleId"]) for row in validation.rows}
    source_split = json.loads(args.source_split.read_text(encoding="utf-8"))["sourceSplit"]
    train_sources = {source for source, split in source_split.items() if split == "train"}
    if validation_sources & train_sources:
        raise ValueError("Fold-07 source-level train/validation leakage detected")
    fingerprint = hashlib.sha256("\n".join(sorted(validation_sources)).encode("utf-8")).hexdigest()
    if fingerprint != run["validSourceFingerprint"]:
        raise ValueError("Fold-07 validation source fingerprint differs from checkpoint provenance")
    if run.get("trainAnchorCount") is not None and run["trainAnchorCount"] != len(training):
        raise ValueError("Fold-07 training direct-teacher count differs from checkpoint provenance")
    if run.get("validAnchorCount") is not None and run["validAnchorCount"] != len(validation):
        raise ValueError("Fold-07 direct-teacher counts differ from checkpoint provenance")

    model = HinotoriSpatialPyramidAngularMargin()
    model.load_state_dict(checkpoint["model"], strict=True)
    model.eval().to(torch.device("mps"))
    loader = DataLoader(validation, batch_size=args.batch_size, shuffle=False, collate_fn=collate_rasters)

    exact1 = exact5 = hit1 = hit5 = 0
    count1 = count5 = inv_size1 = inv_size5 = sample_count = 0
    per_symbol: dict[str, dict[str, int]] = {}
    sample_rows: list[dict[str, object]] = []
    with torch.inference_mode():
        for images, targets, source_ids in loader:
            logits, _ = model(images.to("mps"))
            ordered = logits.topk(5, dim=1).indices.cpu().tolist()
            for target, top, source_id in zip(targets.tolist(), ordered, source_ids):
                dataset_index = sample_count
                truth = vocabulary[target]
                predicted = [vocabulary[index] for index in top]
                candidate1 = expansions[predicted[0]]
                candidate5 = set().union(*(expansions[label] for label in predicted))
                exact_top1 = top[0] == target
                exact_top5 = target in top
                similar_top1 = truth in candidate1
                similar_top5 = truth in candidate5
                exact1 += int(exact_top1)
                exact5 += int(exact_top5)
                hit1 += int(similar_top1)
                hit5 += int(similar_top5)
                count1 += len(candidate1)
                count5 += len(candidate5)
                inv_size1 += int(similar_top1) / len(candidate1)
                inv_size5 += int(similar_top5) / len(candidate5)
                item = per_symbol.setdefault(truth, {"count": 0, "exactTop1": 0, "exactTop5": 0, "similarCoverageAt1": 0, "similarCoverageAt5": 0})
                item["count"] += 1
                item["exactTop1"] += int(exact_top1)
                item["exactTop5"] += int(exact_top5)
                item["similarCoverageAt1"] += int(similar_top1)
                item["similarCoverageAt5"] += int(similar_top5)
                row = validation.rows[dataset_index]
                if row["sourceSampleId"] != source_id:
                    raise RuntimeError("validation source order changed between dataset and inference batch")
                sample_rows.append({
                    "sampleIndex": dataset_index,
                    "sourceSampleId": row["sourceSampleId"],
                    "trueLabel": truth,
                    "top1Label": predicted[0],
                    "top5Labels": " | ".join(predicted),
                    "exactTop1": exact_top1,
                    "exactTop5": exact_top5,
                    "top1CandidateCount": len(candidate1),
                    "similarCoverageAt1": similar_top1,
                    "top1SimilarCandidates": " | ".join(sorted(candidate1)),
                    "top5CandidateCount": len(candidate5),
                    "similarCoverageAt5": similar_top5,
                    "top5SimilarCandidates": " | ".join(sorted(candidate5)),
                })
                sample_count += 1
    if sample_count != len(validation):
        raise RuntimeError(f"validation output count mismatch: {sample_count} != {len(validation)}")

    result = {
        "schema": "firebird-cosine-similarity-groups-fold07-inner-validation-v1",
        "task": "evaluate the provisional 87-group symbol relation as a candidate expansion after the exact Fold-07 classifier",
        "warning": "Similarity coverage is candidate-set coverage, not exact symbol accuracy. The provisional groups were built from typeset glyph cosine similarity, not human semantic annotations; this validation measures coverage only and does not establish semantic equivalence. Outer-test data was not read.",
        "groupPolicy": "For each classifier candidate, union all provisional groups containing its label and retain the label itself. Top-5 expansion unions the expansions of the five classifier outputs. Labels absent from the table remain singleton candidates.",
        "inputs": {
            "similarityGroups": str(args.similarity_groups),
            "similarityGroupsSHA256": sha256_file(args.similarity_groups),
            "similarityGroupCount": group_count,
            "labelKindsSHA256": label_kinds_hash,
            "vocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
            "fold7Checkpoint": str(args.fold7_checkpoint),
            "fold7CheckpointSHA256": hashlib.sha256(checkpoint_bytes).hexdigest(),
            "fold7Epoch": checkpoint.get("epoch"),
            "fold7Architecture": run.get("model", run.get("architecture")),
            "fitTeachersSHA256": sha256_file(args.teachers),
            "sourceSplitSHA256": sha256_file(args.source_split),
            "validationSources": len(validation_sources),
            "validationSymbols": sample_count,
            "validSourceFingerprint": fingerprint,
        },
        "metrics": {
            "exactTop1": exact1 / sample_count,
            "exactTop5": exact5 / sample_count,
            "similarCoverageAt1": hit1 / sample_count,
            "similarCoverageAt5": hit5 / sample_count,
            "meanCandidateCountAt1": count1 / sample_count,
            "meanCandidateCountAt5": count5 / sample_count,
            "meanInverseCandidateSetSizeAt1": inv_size1 / sample_count,
            "meanInverseCandidateSetSizeAt5": inv_size5 / sample_count,
        },
        "perTrueSymbol": per_symbol,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.samples_csv.parent.mkdir(parents=True, exist_ok=True)
    with args.samples_csv.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(sample_rows[0]))
        writer.writeheader()
        writer.writerows(sample_rows)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result["metrics"], ensure_ascii=False))


if __name__ == "__main__":
    main()
