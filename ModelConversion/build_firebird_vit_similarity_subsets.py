#!/usr/bin/env python3
"""Build disjoint subsets from direction-independent ViT confusion evidence.

An observed confusion in either direction creates an undirected pair edge.
Complete-link merging prevents unsupported transitive membership.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path

import numpy as np
import torch

from train_firebird_typeset_vit import FontGlyphViT
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import rasterize_group


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--images", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--split", type=Path, required=True)
    parser.add_argument("--class-map", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--handwriting-teachers", type=Path, required=True)
    parser.add_argument("--handwriting-source-split", type=Path, required=True)
    parser.add_argument("--handwriting-root", type=Path, required=True)
    parser.add_argument("--handwriting-split", choices=("train", "valid"), default="train")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runtime-output", type=Path)
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--confusion-rate-threshold", type=float, default=0.05)
    parser.add_argument("--minimum-confusions-in-either-direction", type=int, default=1)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite existing partition: {args.output}")
    if args.runtime_output is not None and args.runtime_output.exists():
        raise FileExistsError(f"refusing to overwrite runtime catalog: {args.runtime_output}")
    if (args.batch_size < 1 or args.minimum_confusions_in_either_direction < 1
            or not 0 < args.confusion_rate_threshold <= 1
            or not torch.backends.mps.is_available()):
        raise RuntimeError("Valid thresholds and batch size plus an available MPS device are required; CPU fallback is prohibited")

    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary = json.loads(vocabulary_bytes)["labels"]
    if len(vocabulary) != 229 or len(set(vocabulary)) != 229:
        raise ValueError("expected the exact 229-symbol vocabulary")
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    if manifest.get("schema") != "firebird-mac-font-glyph-raster-v1" or manifest.get("vocabularySHA256") != sha256(vocabulary_bytes):
        raise ValueError("font corpus schema or ordered vocabulary hash mismatch")
    rows = manifest["rows"]
    if len(rows) != manifest["renderedImageCount"] or args.images.stat().st_size != len(rows) * 64 * 64:
        raise ValueError("font raster bytes do not match the corpus manifest")

    class_map = json.loads(args.class_map.read_text(encoding="utf-8"))
    if len(class_map) != 228:
        raise ValueError(f"expected 228 font-renderable labels, got {len(class_map)}")
    vocabulary_to_class = {int(row["vocabularyIndex"]): int(row["classIndex"]) for row in class_map}
    class_to_vocabulary = {int(row["classIndex"]): int(row["vocabularyIndex"]) for row in class_map}
    if set(class_to_vocabulary) != set(range(228)):
        raise ValueError("ViT class map is not contiguous")
    if any(vocabulary[index] != row["label"] for row in class_map for index in [int(row["vocabularyIndex"])]):
        raise ValueError("ViT class map and ordered vocabulary disagree")

    split = json.loads(args.split.read_text(encoding="utf-8"))
    heldout_files = set(split["validationFontFileSHA256"])
    train_only_indices = {int(value) for value in split["singleFontFileVocabularyIndices"]}
    evaluated_indices = {int(value) for value in split["evaluatedVocabularyIndices"]}
    if not train_only_indices.isdisjoint(evaluated_indices):
        raise ValueError("a single-font label was incorrectly marked held-out evaluable")

    selected_indices = []
    selected_true = []
    selected_evidence = []
    evidence_by_vocabulary: dict[int, str] = {}
    for index, row in enumerate(rows):
        vocabulary_index = int(row["vocabularyIndex"])
        if vocabulary_index not in vocabulary_to_class:
            raise ValueError(f"font corpus label is missing from ViT map: {row['label']}")
        is_heldout = row["fontFileSHA256"] in heldout_files
        use_row = is_heldout if vocabulary_index in evaluated_indices else not is_heldout
        if use_row:
            selected_indices.append(index)
            selected_true.append(vocabulary_to_class[vocabulary_index])
            evidence = "heldout-font" if is_heldout else "fit-only-single-font"
            selected_evidence.append(evidence)
            evidence_by_vocabulary[vocabulary_index] = evidence
    if not selected_indices or set(evidence_by_vocabulary) != set(vocabulary_to_class):
        raise ValueError("ViT evidence does not cover each font-renderable vocabulary label")

    checkpoint_bytes = args.checkpoint.read_bytes()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    validation = checkpoint.get("validation")
    if not isinstance(validation, dict) or checkpoint.get("seed") != split.get("seed"):
        raise ValueError("checkpoint provenance does not match the font split seed")
    model = FontGlyphViT(len(class_map))
    model.load_state_dict(checkpoint["model"], strict=True)
    model.eval().to(torch.device("mps"))

    handwritten = DirectAnchorDataset(
        args.handwriting_teachers,
        args.handwriting_source_split,
        args.handwriting_root,
        point_count=128,
        split=args.handwriting_split,
        temporal=True,
    )
    handwritten_structural_excluded_count = sum(row.get("label") == r"\frac" for row in handwritten.rows)
    handwritten.rows = [row for row in handwritten.rows if row.get("label") != r"\frac"]
    if not handwritten.rows:
        raise ValueError("no standalone handwritten glyph teachers remain after excluding structural \\frac")
    vocabulary_index_by_label = {label: index for index, label in enumerate(vocabulary)}
    handwritten_counts: dict[int, Counter[int]] = {index: Counter() for index in vocabulary_to_class}
    handwritten_exact = handwritten_top5 = handwritten_total = 0
    handwritten_sources: set[str] = set()
    with torch.inference_mode():
        for start in range(0, len(handwritten), args.batch_size):
            samples = [handwritten[index] for index in range(start, min(start + args.batch_size, len(handwritten)))]
            images_batch = torch.stack([rasterize_group(sample["rasterPoints"]) for sample in samples]).to("mps")
            true_vocabulary_indices = []
            for offset, sample in enumerate(samples):
                row = handwritten.rows[start + offset]
                label = row.get("label")
                if not isinstance(label, str) or label not in vocabulary:
                    raise ValueError(f"handwritten teacher label is outside the verified vocabulary: {label!r}")
                if int(sample["classIndex"]) != int(row["classIndex"]):
                    raise ValueError("direct teacher class index changed while constructing its handwritten raster")
                vocabulary_index = vocabulary_index_by_label[label]
                if vocabulary_index not in vocabulary_to_class:
                    raise ValueError(f"handwritten teacher has no standalone ViT glyph class: {label}")
                true_vocabulary_indices.append(vocabulary_index)
            truth = torch.tensor(
                [vocabulary_to_class[index] for index in true_vocabulary_indices], device="mps"
            )
            logits = model(images_batch)
            predicted = logits.argmax(1)
            top5_indices = logits.topk(min(5, logits.shape[1]), dim=1).indices
            handwritten_exact += int(predicted.eq(truth).sum().item())
            handwritten_top5 += int(top5_indices.eq(truth[:, None]).any(1).sum().item())
            handwritten_total += int(truth.numel())
            for sample, source_vocabulary_index, predicted_class in zip(
                samples, true_vocabulary_indices, predicted.cpu().tolist()
            ):
                target_vocabulary_index = class_to_vocabulary[int(predicted_class)]
                handwritten_counts[source_vocabulary_index][target_vocabulary_index] += 1
                handwritten_sources.add(str(sample["sourceSampleId"]))

    predictions: dict[int, Counter[int]] = {index: Counter() for index in vocabulary_to_class}
    exact = top5 = total = 0
    heldout_exact = heldout_top5 = heldout_total = 0
    fit_only_exact = fit_only_top5 = fit_only_total = 0
    raw = np.memmap(args.images, mode="r", dtype=np.uint8, shape=(len(rows), 64, 64))
    with torch.inference_mode():
        for start in range(0, len(selected_indices), args.batch_size):
            batch_positions = selected_indices[start:start + args.batch_size]
            batch_images = torch.from_numpy(np.array(raw[batch_positions], copy=True)).unsqueeze(1).to(device="mps", dtype=torch.float32).div_(255.0)
            logits = model(batch_images)
            truth = torch.tensor(selected_true[start:start + len(batch_positions)], device="mps")
            predicted = logits.argmax(1)
            top5_indices = logits.topk(min(5, logits.shape[1]), dim=1).indices
            exact_hits = predicted.eq(truth)
            top5_hits = top5_indices.eq(truth[:, None]).any(1)
            exact += int(exact_hits.sum().item())
            top5 += int(top5_hits.sum().item())
            total += int(truth.numel())
            evidence_batch = selected_evidence[start:start + len(batch_positions)]
            heldout_mask = torch.tensor([value == "heldout-font" for value in evidence_batch], device="mps")
            fit_only_mask = ~heldout_mask
            heldout_exact += int((exact_hits & heldout_mask).sum().item())
            heldout_top5 += int((top5_hits & heldout_mask).sum().item())
            heldout_total += int(heldout_mask.sum().item())
            fit_only_exact += int((exact_hits & fit_only_mask).sum().item())
            fit_only_top5 += int((top5_hits & fit_only_mask).sum().item())
            fit_only_total += int(fit_only_mask.sum().item())
            for true_class, predicted_class in zip(truth.cpu().tolist(), predicted.cpu().tolist()):
                source_vocabulary_index = class_to_vocabulary[int(true_class)]
                predictions[source_vocabulary_index][int(predicted_class)] += 1

    source_records = []
    for vocabulary_index in sorted(vocabulary_to_class):
        counts = predictions[vocabulary_index]
        if not counts:
            raise ValueError(f"no image-recognition evidence for {vocabulary[vocabulary_index]}")
        source_records.append({
            "symbol": vocabulary[vocabulary_index],
            "imageCount": sum(counts.values()),
            "evidence": evidence_by_vocabulary[vocabulary_index],
            "recognitionCountsByLabel": {vocabulary[class_to_vocabulary[class_index]]: count for class_index, count in sorted(counts.items())},
            "handwritingImageCount": sum(handwritten_counts[vocabulary_index].values()),
            "handwritingRecognitionCountsByLabel": {
                vocabulary[target_index]: count
                for target_index, count in sorted(handwritten_counts[vocabulary_index].items())
            },
        })

    # A direction-independent subset edge is supported by a qualifying error
    # in either direction. Preserve both directional counts/rates as evidence.
    heldout_vocabulary_indices = {
        index for index, evidence in evidence_by_vocabulary.items() if evidence == "heldout-font"
    }
    adjacency = {index: set() for index in vocabulary_to_class}
    edge_strength: dict[tuple[int, int], float] = {}
    pairwise_evidence = []
    all_vocabulary_indices = sorted(vocabulary_to_class)
    for source_index in all_vocabulary_indices:
        source_counts = predictions[source_index]
        source_total = sum(source_counts.values())
        for target_index in all_vocabulary_indices:
            if target_index <= source_index:
                continue
            target_counts = predictions[target_index]
            target_total = sum(target_counts.values())
            source_to_target = source_counts.get(vocabulary_to_class[target_index], 0) / source_total
            target_to_source = target_counts.get(vocabulary_to_class[source_index], 0) / target_total
            font_mutual_rate = min(source_to_target, target_to_source)
            handwriting_source_counts = handwritten_counts[source_index]
            handwriting_target_counts = handwritten_counts[target_index]
            handwriting_source_total = sum(handwriting_source_counts.values())
            handwriting_target_total = sum(handwriting_target_counts.values())
            hand_source_to_target_count = handwriting_source_counts.get(target_index, 0)
            hand_target_to_source_count = handwriting_target_counts.get(source_index, 0)
            hand_source_to_target = hand_source_to_target_count / handwriting_source_total if handwriting_source_total else 0.0
            hand_target_to_source = hand_target_to_source_count / handwriting_target_total if handwriting_target_total else 0.0
            hand_mutual_rate = min(hand_source_to_target, hand_target_to_source)
            font_support = (
                source_index in heldout_vocabulary_indices
                and target_index in heldout_vocabulary_indices
                and max(source_to_target, target_to_source) >= args.confusion_rate_threshold
                and max(
                    source_counts.get(vocabulary_to_class[target_index], 0),
                    target_counts.get(vocabulary_to_class[source_index], 0),
                ) >= args.minimum_confusions_in_either_direction
            )
            handwriting_support = (
                max(hand_source_to_target, hand_target_to_source) >= args.confusion_rate_threshold
                and max(hand_source_to_target_count, hand_target_to_source_count) >= args.minimum_confusions_in_either_direction
            )
            if font_support or handwriting_support:
                adjacency[source_index].add(target_index)
                adjacency[target_index].add(source_index)
                edge_strength[(source_index, target_index)] = max(
                    max(source_to_target, target_to_source) if font_support else 0.0,
                    max(hand_source_to_target, hand_target_to_source) if handwriting_support else 0.0,
                )
                pairwise_evidence.append({
                    "source": "vit-font-and-handwriting-either-direction-confusion",
                    "symbols": [vocabulary[source_index], vocabulary[target_index]],
                    "fontHeldout": {
                        "sourceToTargetRate": source_to_target,
                        "targetToSourceRate": target_to_source,
                        "mutualRate": font_mutual_rate,
                        "confusionCounts": [
                            source_counts.get(vocabulary_to_class[target_index], 0),
                            target_counts.get(vocabulary_to_class[source_index], 0),
                        ],
                        "sampleCounts": [source_total, target_total],
                        "supportsPair": font_support,
                    },
                    "handwriting": {
                        "sourceToTargetRate": hand_source_to_target,
                        "targetToSourceRate": hand_target_to_source,
                        "mutualRate": hand_mutual_rate,
                        "errorCounts": [hand_source_to_target_count, hand_target_to_source_count],
                        "sampleCounts": [handwriting_source_total, handwriting_target_total],
                        "supportsPair": handwriting_support,
                    },
                })

    # Deterministic complete-link partition. Add the strongest undirected
    # confusion pairs first, but merge two existing groups only if every
    # cross-pair is an observed edge. Unlike connected components, this cannot
    # make A similar to C merely because A~B and B~C.
    groups: list[set[int]] = [{index} for index in sorted(adjacency)]
    group_of = {member: group_id for group_id, member in enumerate(sorted(adjacency))}
    for (left, right), _strength in sorted(
        edge_strength.items(), key=lambda item: (-item[1], item[0])
    ):
        left_group_id = group_of[left]
        right_group_id = group_of[right]
        if left_group_id == right_group_id:
            continue
        left_group = groups[left_group_id]
        right_group = groups[right_group_id]
        if all(b in adjacency[a] for a in left_group for b in right_group):
            merged = left_group | right_group
            groups[left_group_id] = merged
            groups[right_group_id] = set()
            for member in merged:
                group_of[member] = left_group_id
    groups = [sorted(group) for group in groups if group]
    # The fraction operator is a layout construct, not a standalone font glyph.
    # Keep it in the complete 229-label partition as an explicit singleton.
    fraction_indices = [index for index, label in enumerate(vocabulary) if label == r"\frac"]
    if len(fraction_indices) != 1 or fraction_indices[0] in vocabulary_to_class:
        raise ValueError("expected exactly one structural \\frac label outside the font-glyph class map")
    groups.append(fraction_indices)

    subsets = [
        {
            "subsetKey": vocabulary[members[0]],
            "members": [vocabulary[index] for index in members],
            "pairwiseEvidence": [
                item for item in pairwise_evidence
                if all(label in {vocabulary[index] for index in members} for label in item["symbols"])
            ],
        }
        for members in sorted(groups, key=lambda values: values[0])
    ]
    flattened = [label for subset in subsets for label in subset["members"]]
    if len(flattened) != 229 or len(set(flattened)) != 229 or set(flattened) != set(vocabulary):
        raise RuntimeError("generated subsets do not form a disjoint complete partition of all 229 labels")

    result = {
        "schema": "firebird-vit-font-and-handwriting-confusion-subsets-v4",
        "task": f"partition all 229 labels by ViT confusion on held-out font glyphs and source-disjoint handwritten {args.handwriting_split} teachers",
        "groupingRule": f"an undirected pair is linked when either font-heldout or handwritten-{args.handwriting_split} images produce at least {args.minimum_confusions_in_either_direction} confusion(s) in either direction at a rate of at least {args.confusion_rate_threshold:.6f}; both directional counts/rates are retained; deterministic strongest-edge-first complete-link merging prevents unsupported transitive membership",
        "confusionRateThreshold": args.confusion_rate_threshold,
        "minimumConfusionsInEitherDirection": args.minimum_confusions_in_either_direction,
        "pairwiseConfusionEdgeCount": len(pairwise_evidence),
        "corpus": {
            "manifestSHA256": sha256(manifest_bytes), "rasterSHA256": sha256_file(args.images),
            "fontImageCount": len(rows), "selectedFontRecognitionImageCount": total,
            "handwritingTeachersSHA256": sha256_file(args.handwriting_teachers),
            "handwritingSourceSplitSHA256": sha256_file(args.handwriting_source_split),
            "handwritingSourceCount": len(handwritten_sources), "handwritingSymbolCount": handwritten_total,
            "handwritingSplit": args.handwriting_split,
            "handwritingStructuralFractionExcludedCount": handwritten_structural_excluded_count,
        },
        "vocabulary": {"sha256": sha256(vocabulary_bytes), "labelCount": 229},
        "vit": {"checkpoint": str(args.checkpoint), "sha256": sha256(checkpoint_bytes), "epoch": checkpoint["epoch"], "architecture": "FontGlyphViT", "device": "mps"},
        "recognitionEvidence": {
            "heldoutFonts": {
                "top1": heldout_exact / heldout_total,
                "top5": heldout_top5 / heldout_total,
                "sampleCount": heldout_total,
                "classCount": len(evaluated_indices),
            },
            "singleFontFitOnly": {
                "top1FitOnlyDiagnostic": fit_only_exact / fit_only_total if fit_only_total else None,
                "top5FitOnlyDiagnostic": fit_only_top5 / fit_only_total if fit_only_total else None,
                "sampleCount": fit_only_total,
                "classCount": len(train_only_indices),
                "independentValidation": False,
            },
            "handwriting": {
                "split": args.handwriting_split,
                "top1": handwritten_exact / handwritten_total,
                "top5": handwritten_top5 / handwritten_total,
                "sampleCount": handwritten_total,
                "sourceCount": len(handwritten_sources),
                "structuralFractionExcludedCount": handwritten_structural_excluded_count,
                "evaluationRole": ("fit-only diagnostic" if args.handwriting_split == "train" else "held-out handwriting validation; repeated candidate comparison, not an untouched final test"),
            },
            "structuralSingletons": [r"\frac"],
        },
        "subsets": subsets,
        "pairwiseConfusionEvidence": pairwise_evidence,
        "perSymbolEvidence": source_records,
    }
    serialized = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(serialized, encoding="utf-8")
    if args.runtime_output is not None:
        args.runtime_output.parent.mkdir(parents=True, exist_ok=True)
        args.runtime_output.write_text(serialized, encoding="utf-8")
    print(json.dumps({"subsets": len(subsets), "labels": len(flattened), "imageTop1": exact / total, "imageTop5": top5 / total}, ensure_ascii=False))


if __name__ == "__main__":
    main()
