#!/usr/bin/env python3
"""Measure ViT-derived visual subsets on Fold-07 inner-validation predictions."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import HinotoriStrokeSetClassifier
from hinotori_spatial_pyramid import HinotoriSpatialPyramidAngularMargin
from train_hinotori_raster_classifier import collate_rasters, collate_stroke_set


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--fold7-vocabulary", type=Path, required=True)
    parser.add_argument("--partition", type=Path, required=True)
    parser.add_argument("--fold7-checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=64)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite existing evaluation: {args.output}")
    if args.batch_size < 1 or not torch.backends.mps.is_available():
        raise RuntimeError("A positive batch size and available MPS device are required; CPU fallback is prohibited")

    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary = json.loads(vocabulary_bytes)["labels"]
    if len(vocabulary) != 229 or len(set(vocabulary)) != 229:
        raise ValueError("expected the exact 229-label Fold-07 vocabulary")
    fold7_vocabulary_bytes = args.fold7_vocabulary.read_bytes()
    fold7_vocabulary = json.loads(fold7_vocabulary_bytes)["labels"]
    if fold7_vocabulary != vocabulary:
        raise ValueError("ViT and Fold-07 vocabulary label order differs")
    partition_bytes = args.partition.read_bytes()
    partition = json.loads(partition_bytes)
    if partition.get("schema") != "firebird-vit-font-and-handwriting-confusion-subsets-v3":
        raise ValueError("partition schema is not the font-plus-handwriting Firebird ViT confusion partition")
    if partition.get("vocabulary", {}).get("sha256") != hashlib.sha256(vocabulary_bytes).hexdigest():
        raise ValueError("ViT partition and Fold-07 vocabulary hashes differ")
    label_to_class = {label: index for index, label in enumerate(vocabulary)}
    member_to_subset: dict[str, set[str]] = {}
    for subset in partition.get("subsets", []):
        members = subset.get("members")
        if not isinstance(members, list) or not members:
            raise ValueError("empty or malformed visual subset")
        member_set = set(members)
        for label in members:
            if label not in label_to_class or label in member_to_subset:
                raise ValueError(f"unknown or multiply assigned subset label: {label}")
            member_to_subset[label] = member_set
    if set(member_to_subset) != set(vocabulary):
        raise ValueError("ViT subsets do not cover the exact 229-label vocabulary")

    checkpoint_bytes = args.fold7_checkpoint.read_bytes()
    checkpoint = torch.load(args.fold7_checkpoint, map_location="cpu", weights_only=False)
    run = checkpoint.get("run", {})
    if run.get("task") not in {"229-way isolated handwritten symbol classification", "isolated_symbol_exact_classification"}:
        raise ValueError("Fold-07 checkpoint task mismatch")
    if run.get("vocabularySHA256") != hashlib.sha256(vocabulary_bytes).hexdigest():
        if run.get("vocabularySHA256") != hashlib.sha256(fold7_vocabulary_bytes).hexdigest():
            raise ValueError("Fold-07 checkpoint vocabulary hash matches neither supplied ordered vocabulary")
    if run.get("trainTeachersSHA256") is not None and run.get("trainTeachersSHA256") != sha256_file(args.teachers):
        raise ValueError("Fold-07 checkpoint and direct-teacher file hashes differ")
    if run.get("sourceSplitSHA256") is not None and run.get("sourceSplitSHA256") != sha256_file(args.source_split):
        raise ValueError("Fold-07 checkpoint and source-split file hashes differ")
    if run.get("validSourceFingerprint") is None:
        raise ValueError("Fold-07 checkpoint has no source-disjoint validation provenance")

    training = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "train")
    validation = DirectAnchorDataset(args.teachers, args.source_split, args.dataset_root, 128, "valid")
    for row in training.rows + validation.rows:
        class_index = row["classIndex"]
        label = row.get("label")
        if not isinstance(class_index, int) or not 0 <= class_index < len(vocabulary) or label != vocabulary[class_index]:
            raise ValueError("Fold-07 teacher label/index does not match the verified vocabulary order")
    validation_sources = {str(row["sourceSampleId"]) for row in validation.rows}
    source_split = json.loads(args.source_split.read_text(encoding="utf-8"))["sourceSplit"]
    train_sources = {source for source, split in source_split.items() if split == "train"}
    if validation_sources & train_sources:
        raise ValueError("Fold-07 source-level train/validation leakage detected")
    def source_fingerprint(sources: set[str]) -> str:
        return hashlib.sha256("\n".join(sorted(sources)).encode("utf-8")).hexdigest()
    training_sources = {str(row["sourceSampleId"]) for row in training.rows}
    if source_fingerprint(training_sources) != run.get("trainSourceFingerprint") or source_fingerprint(validation_sources) != run.get("validSourceFingerprint"):
        raise ValueError("Fold-07 direct-teacher source fingerprints differ from checkpoint provenance")
    if run.get("trainAnchorCount") is not None and run["trainAnchorCount"] != len(training):
        raise ValueError("Fold-07 training direct-teacher count differs from checkpoint provenance")
    if run.get("validAnchorCount") is not None and run["validAnchorCount"] != len(validation):
        raise ValueError("Fold-07 validation direct-teacher count differs from checkpoint provenance")
    architecture = run.get("model", run.get("architecture"))
    if architecture == "HinotoriSpatialPyramidAngularMargin":
        model = HinotoriSpatialPyramidAngularMargin()
        collate_fn = collate_rasters
    elif architecture == "HinotoriStrokeSetClassifier":
        model = HinotoriStrokeSetClassifier()
        collate_fn = collate_stroke_set
    else:
        raise ValueError(f"unsupported Fold-07 architecture: {architecture}")
    model.load_state_dict(checkpoint["model"], strict=True)
    model.eval().to(torch.device("mps"))
    loader = DataLoader(validation, batch_size=args.batch_size, shuffle=False, collate_fn=collate_fn)

    exact_top1 = exact_top5 = subset_hit_at1 = subset_hit_at5 = 0
    precision_at1 = precision_at5 = 0.0
    candidate_count_at1 = candidate_count_at5 = 0
    sample_count = 0
    per_class: dict[str, dict[str, int]] = {}
    with torch.inference_mode():
        for model_inputs, labels, _ in loader:
            if isinstance(model_inputs, tuple):
                logits, _ = model(*(value.to("mps") for value in model_inputs))
            else:
                logits, _ = model(model_inputs.to("mps"))
            ordered = logits.topk(5, dim=1).indices.cpu().tolist()
            targets = labels.tolist()
            for target, top in zip(targets, ordered):
                true_label = vocabulary[target]
                top_labels = [vocabulary[index] for index in top]
                top1_candidates = member_to_subset[top_labels[0]]
                top5_candidates = set().union(*(member_to_subset[label] for label in top_labels))
                exact_top1 += int(top[0] == target)
                exact_top5 += int(target in top)
                hit1 = true_label in top1_candidates
                hit5 = true_label in top5_candidates
                subset_hit_at1 += int(hit1)
                subset_hit_at5 += int(hit5)
                precision_at1 += (1.0 / len(top1_candidates)) if hit1 else 0.0
                precision_at5 += (1.0 / len(top5_candidates)) if hit5 else 0.0
                candidate_count_at1 += len(top1_candidates)
                candidate_count_at5 += len(top5_candidates)
                item = per_class.setdefault(true_label, {"count": 0, "exactTop1": 0, "exactTop5": 0, "subsetHitAt1": 0, "subsetHitAt5": 0})
                item["count"] += 1
                item["exactTop1"] += int(top[0] == target)
                item["exactTop5"] += int(target in top)
                item["subsetHitAt1"] += int(hit1)
                item["subsetHitAt5"] += int(hit5)
                sample_count += 1
    if sample_count != len(validation):
        raise RuntimeError(f"validation output count mismatch: {sample_count} != {len(validation)}")

    result = {
        "schema": "firebird-vit-subset-fold07-inner-validation-v2",
        "task": "compare the selected Fold-07 exact symbol classifier with candidate coverage after ViT-derived subset expansion",
        "warning": "Subset hit rates are candidate-set coverage, not exact Top-k accuracy. Candidate-set size/reciprocal precision are reported to expose the ambiguity cost. No Fold-07 outer-test examples were read.",
        "inputs": {
            "partitionSHA256": hashlib.sha256(partition_bytes).hexdigest(),
            "vitVocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
            "fold7VocabularySHA256": hashlib.sha256(fold7_vocabulary_bytes).hexdigest(),
            "fold7Checkpoint": str(args.fold7_checkpoint),
            "fold7CheckpointSHA256": hashlib.sha256(checkpoint_bytes).hexdigest(),
            "fold7Epoch": checkpoint.get("epoch"),
            "fold7Architecture": architecture,
            "fitTeachersSHA256": sha256_file(args.teachers),
            "sourceSplitSHA256": sha256_file(args.source_split),
            "validationSources": len(validation_sources),
            "validationSymbols": sample_count,
            "validSourceFingerprint": run["validSourceFingerprint"],
        },
        "metrics": {
            "exactTop1": exact_top1 / sample_count,
            "exactTop5": exact_top5 / sample_count,
            "similaritySubsetCoverageAt1": subset_hit_at1 / sample_count,
            "similaritySubsetCoverageAt5": subset_hit_at5 / sample_count,
            "meanCandidateCountAt1": candidate_count_at1 / sample_count,
            "meanCandidateCountAt5": candidate_count_at5 / sample_count,
            "meanReciprocalCandidateCountAt1": precision_at1 / sample_count,
            "meanReciprocalCandidateCountAt5": precision_at5 / sample_count,
        },
        "perTrueSymbol": per_class,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result["metrics"], ensure_ascii=False))


if __name__ == "__main__":
    main()
