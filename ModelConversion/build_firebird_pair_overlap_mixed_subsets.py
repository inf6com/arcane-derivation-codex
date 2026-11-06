#!/usr/bin/env python3
"""Generate 229 direct visual-overlap neighborhoods from font and hand candidates."""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch

from build_firebird_pair_overlap_subsets import visible_label
from finetune_firebird_pair_overlap_gapfill import canonical_bank, load_indexed_bank
from train_firebird_pair_overlap_vit import PairOverlapViT, SCALES, pairwise_target_scores, sha256


def score_pairs(model: PairOverlapViT, features: torch.Tensor,
                pair_positions: list[tuple[int, int]], device: torch.device) -> np.ndarray:
    predictions = []
    with torch.inference_mode():
        for start in range(0, len(pair_positions), 8192):
            batch = pair_positions[start:start + 8192]
            ia = torch.tensor([item[0] for item in batch], dtype=torch.long, device=device)
            ib = torch.tensor([item[1] for item in batch], dtype=torch.long, device=device)
            predictions.append(model.score_embeddings(features[ia], features[ib]).cpu().numpy())
    return np.concatenate(predictions) if predictions else np.empty((0, len(SCALES)), dtype=np.float32)


def summarize_metrics(predictions: np.ndarray, targets: np.ndarray) -> dict:
    result = {}
    for dimension, size in enumerate(SCALES):
        predicted, target = predictions[:, dimension], targets[:, dimension]
        positive, guessed = target >= .5, predicted >= .5
        tp = int(np.sum(positive & guessed))
        fp = int(np.sum(~positive & guessed))
        fn = int(np.sum(positive & ~guessed))
        tn = int(np.sum(~positive & ~guessed))
        result[str(size)] = {
            "mae": float(np.mean(np.abs(predicted - target))),
            "balancedAccuracyAtHalf": float(.5 * (tp / max(tp + fn, 1) + tn / max(tn + fp, 1))),
            "precisionAtHalf": float(tp / max(tp + fp, 1)),
            "recallAtHalf": float(tp / max(tp + fn, 1)),
            "truePositive": tp, "falsePositive": fp, "falseNegative": fn,
            "trueNegative": tn, "evaluatedImagePairs": len(target),
        }
    result["macroMAE"] = float(np.mean([result[str(size)]["mae"] for size in SCALES]))
    result["macroBalancedAccuracyAtHalf"] = float(np.mean(
        [result[str(size)]["balancedAccuracyAtHalf"] for size in SCALES]))
    return result


def domain_decision(scores: list[float], targets: list[float], threshold: float) -> dict:
    if not scores:
        return {
            "observations": 0,
            "requiredPassing": 0,
            "medianModelScore": None,
            "modelPassing": 0,
            "medianRasterOverlapTarget": None,
            "targetPassing": 0,
            "eligible": False,
            "modelAccepted": False,
            "rasterTargetAccepted": False,
        }
    model = np.asarray(scores, dtype=np.float32)
    target = np.asarray(targets, dtype=np.float32)
    required = int(np.ceil(len(model) * .5))
    accepted = (len(model) >= 10 and float(np.median(model)) >= threshold
                and int(np.sum(model >= threshold)) >= required)
    target_accepted = (len(target) >= 10 and float(np.median(target)) >= .5
                       and int(np.sum(target >= .5)) >= int(np.ceil(len(target) * .5)))
    return {
        "observations": len(model), "requiredPassing": required,
        "medianModelScore": float(np.median(model)),
        "modelPassing": int(np.sum(model >= threshold)),
        "medianRasterOverlapTarget": float(np.median(target)),
        "targetPassing": int(np.sum(target >= .5)),
        "eligible": len(model) >= 10,
        "modelAccepted": accepted,
        "rasterTargetAccepted": target_accepted,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--base-run", type=Path,
                        default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3"))
    parser.add_argument("--font-manifest", type=Path,
                        default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--font-shapes", type=Path,
                        default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3/canonical-contour-skeleton.u8"))
    parser.add_argument("--vocabulary", type=Path,
                        default=Path("runs/agent-control/cycle621-firebird-label-kinds.json"))
    parser.add_argument("--hand-valid-bank", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/handwriting-valid-shapes.u8"))
    parser.add_argument("--hand-valid-index", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/handwriting-valid-shapes.jsonl"))
    parser.add_argument("--threshold", type=float, default=.525)
    parser.add_argument("--output-name", default="similarity-subsets-mixed.json")
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited.")
    if not 0 < args.threshold < 1:
        raise ValueError("threshold must be between zero and one")

    training_report = json.loads((args.run / "training-report.json").read_text(encoding="utf-8"))
    base_report = json.loads((args.base_run / "training-report.json").read_text(encoding="utf-8"))
    manifest_bytes = args.font_manifest.read_bytes()
    vocabulary_bytes = args.vocabulary.read_bytes()
    manifest = json.loads(manifest_bytes)
    vocabulary_manifest = json.loads(vocabulary_bytes)
    if (training_report.get("schema") != "firebird-symmetric-shape-pair-vit-gapfill-v1"
            or training_report.get("baseCheckpointSHA256") != sha256(args.base_run / "firebird-pair-overlap-vit.pt")
            or hashlib.sha256(manifest_bytes).hexdigest() != base_report.get("corpusManifestSHA256")
            or vocabulary_manifest.get("vocabularySHA256") != manifest.get("vocabularySHA256")):
        raise ValueError("mixed checkpoint, base font corpus, and vocabulary provenance mismatch")
    rows = manifest["rows"]
    canonical_path = args.base_run / "canonical-contour-skeleton.u8"
    if (canonical_path.stat().st_size != len(rows) * int(np.prod((2, 64, 64)))
            or sha256(canonical_path) != base_report["canonicalCorpusSHA256"]):
        raise ValueError("held-out font candidate corpus does not match the base model")
    vocab_entries = vocabulary_manifest["entries"]
    labels = {int(item["index"]): str(item["label"]) for item in vocab_entries}
    display = {int(item["index"]): visible_label(item) for item in vocab_entries}
    if len(labels) != 229 or set(labels) != set(range(229)):
        raise ValueError("candidate set must use the complete ordered 229-label vocabulary")

    by_font_label: dict[str, dict[int, int]] = defaultdict(dict)
    generation_fonts = set(base_report["generationFontFiles"])
    for row_id, row in enumerate(rows):
        font_hash = str(row["fontFileSHA256"])
        if font_hash in generation_fonts:
            by_font_label[font_hash].setdefault(int(row["vocabularyIndex"]), row_id)
    font_bank = np.memmap(canonical_path, mode="r", dtype=np.uint8,
                          shape=(len(rows), 2, 64, 64))
    model = PairOverlapViT()
    model.load_state_dict(torch.load(args.run / "firebird-pair-overlap-vit.pt",
                                     map_location="cpu", weights_only=True)["state_dict"], strict=True)
    device = torch.device("mps")
    model.to(device).eval()

    pair_scores: dict[tuple[int, int], dict[str, list[float]]] = defaultdict(
        lambda: {"fontModel": [], "fontTarget": [], "handModel": [], "handTarget": []})
    all_font_predictions, all_font_targets = [], []
    with torch.inference_mode():
        for font_hash in base_report["generationFontFiles"]:
            entries = sorted(by_font_label.get(font_hash, {}).items())
            if len(entries) < 2:
                continue
            font_labels = [label for label, _ in entries]
            row_ids = [row_id for _, row_id in entries]
            images = np.asarray(font_bank[row_ids], dtype=np.uint8)
            target_matrix = pairwise_target_scores(images)
            feature_parts = []
            for start in range(0, len(row_ids), 256):
                image_batch = torch.from_numpy(np.array(font_bank[row_ids[start:start + 256]], copy=True)).to(
                    device=device, dtype=torch.float32)
                feature_parts.append(model.encode(image_batch))
            features = torch.cat(feature_parts)
            positions = [(i, j) for i in range(len(font_labels)) for j in range(i + 1, len(font_labels))]
            predictions = score_pairs(model, features, positions, device)
            targets = np.asarray([target_matrix[i, j] for i, j in positions], dtype=np.float32)
            all_font_predictions.append(predictions)
            all_font_targets.append(targets)
            for (i, j), score, target in zip(positions, predictions, targets):
                key = tuple(sorted((font_labels[i], font_labels[j])))
                pair_scores[key]["fontModel"].append(float(np.mean(score)))
                pair_scores[key]["fontTarget"].append(float(np.mean(target)))

    hand_source, hand_rows = load_indexed_bank(args.hand_valid_bank, args.hand_valid_index)
    if any(row.get("split") != "inner-valid" or row.get("modality") != "handwriting-direct-teacher"
           for row in hand_rows):
        raise ValueError("hand candidate bank must contain only direct inner-validation handwriting")
    hand_images = canonical_bank(hand_source)
    by_hand_label: dict[int, list[int]] = defaultdict(list)
    for image_index, row in enumerate(hand_rows):
        by_hand_label[int(row["vocabularyIndex"])].append(image_index)
    hand_model_predictions, hand_targets = [], []
    all_hand_predictions, all_hand_targets = [], []
    with torch.inference_mode():
        for label_a in sorted(by_hand_label):
            rows_a = by_hand_label[label_a]
            for label_b in sorted(x for x in by_hand_label if x > label_a):
                rows_b = by_hand_label[label_b]
                # Score every available pair of independent symbol instances, in bounded batches.
                images_a = torch.from_numpy(hand_images[rows_a].astype(np.float32)).to(device)
                images_b = torch.from_numpy(hand_images[rows_b].astype(np.float32)).to(device)
                features_a = model.encode(images_a)
                features_b = model.encode(images_b)
                positions = [(i, j) for i in range(len(rows_a)) for j in range(len(rows_b))]
                predictions = score_pairs(model, torch.cat((features_a, features_b)),
                                          [(i, len(rows_a) + j) for i, j in positions], device)
                targets = np.asarray([pairwise_target_scores(np.stack((hand_images[rows_a[i]],
                                                                        hand_images[rows_b[j]])))[0, 1]
                                      for i, j in positions], dtype=np.float32)
                target_vectors = targets
                means = np.mean(predictions, axis=1)
                pair_scores[(label_a, label_b)]["handModel"].extend(means.tolist())
                pair_scores[(label_a, label_b)]["handTarget"].extend(np.mean(target_vectors, axis=1).tolist())
                all_hand_predictions.append(predictions)
                all_hand_targets.append(target_vectors)

    if not all_font_predictions or not all_hand_predictions:
        raise ValueError("candidate data did not yield both font and handwriting pairs")
    font_metrics = summarize_metrics(np.concatenate(all_font_predictions), np.concatenate(all_font_targets))
    hand_metrics = summarize_metrics(np.concatenate(all_hand_predictions), np.concatenate(all_hand_targets))

    edges = []
    for (label_a, label_b), evidence in sorted(pair_scores.items()):
        font_decision = domain_decision(evidence["fontModel"], evidence["fontTarget"], args.threshold)
        hand_decision = domain_decision(evidence["handModel"], evidence["handTarget"], args.threshold)
        accepted = bool(font_decision["modelAccepted"] or hand_decision["modelAccepted"])
        edge = {
            "indexA": label_a, "symbolA": labels[label_a], "displayA": display[label_a],
            "indexB": label_b, "symbolB": labels[label_b], "displayB": display[label_b],
            "fontCandidateEvidence": font_decision,
            "handwritingInnerValidationEvidence": hand_decision,
            "acceptedFrom": [name for name, result in (("font", font_decision),
                                                        ("handwriting", hand_decision))
                             if result.get("modelAccepted")],
            "modelAccepted": accepted,
        }
        if accepted:
            edges.append(edge)

    neighbors = {index: set() for index in range(229)}
    edge_map: dict[int, list[dict]] = defaultdict(list)
    for edge in edges:
        neighbors[edge["indexA"]].add(edge["indexB"])
        neighbors[edge["indexB"]].add(edge["indexA"])
        edge_map[edge["indexA"]].append(edge)
        edge_map[edge["indexB"]].append(edge)
    subsets = []
    for focus in range(229):
        member_indices = [focus, *sorted(neighbors[focus])]
        subsets.append({
            "focusIndex": focus, "focus": labels[focus], "focusDisplay": display[focus],
            "members": [{"index": index, "symbol": labels[index], "display": display[index]}
                        for index in member_indices],
            "directPairEvidence": edge_map[focus],
        })

    output = {
        "schema": "firebird-symmetric-shape-pair-vit-mixed-candidates-v1",
        "status": "candidate-pseudo-labels-from-fit-trained-vit",
        "task": "direct, symmetric visual-overlap neighborhoods over the 229-label vocabulary",
        "acceptanceThreshold": args.threshold,
        "acceptanceRule": "A pair is included when at least one candidate domain has >=10 observations, median ViT score >= threshold, and at least half its observations >= threshold. Font observations are one per held-out generation font; handwriting observations are distinct labeled image pairs from Fold-07 inner validation.",
        "checkpoint": str(args.run / "firebird-pair-overlap-vit.pt"),
        "checkpointSHA256": sha256(args.run / "firebird-pair-overlap-vit.pt"),
        "baseCheckpointSHA256": training_report["baseCheckpointSHA256"],
        "fontCandidateFiles": base_report["generationFontFiles"],
        "handwritingCandidate": {
            "bankSHA256": sha256(args.hand_valid_bank),
            "images": len(hand_rows),
            "formulaSources": len({row["sourceSampleId"] for row in hand_rows}),
            "split": "Fold-07 inner-valid; never used for optimizer updates or epoch selection",
        },
        "fontCandidateMetricsAgainstRasterTarget": font_metrics,
        "handwritingCandidateMetricsAgainstRasterTarget": hand_metrics,
        "acceptedDirectPairCount": len(edges),
        "labelsWithNeighbors": sum(bool(neighbors[i]) for i in neighbors),
        "labelsWithoutNeighbors": sum(not neighbors[i] for i in neighbors),
        "outerTestOpened": False,
        "humanSemanticGold": False,
        "subsets": subsets,
        "acceptedPairEvidence": edges,
        "limitations": [
            "Targets are synthetic pixel-overlap measurements from contour/skeleton raster images, not human semantic annotations.",
            "Font and handwriting candidate metrics report agreement with that raster target; candidate lists remain unverified semantic proposals.",
            "The structural fraction token has no independent glyph image and remains a singleton.",
        ],
    }
    output_path = args.run / args.output_name
    if output_path.exists():
        raise FileExistsError(f"refusing to overwrite candidate output: {output_path}")
    output_path.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n",
                           encoding="utf-8")
    table = ["# 火の鳥・ViT類似記号部分集合（活字＋手書き候補）", "",
             f"229記号。直接候補ペア {len(edges)}、近傍あり {output['labelsWithNeighbors']}、近傍なし {output['labelsWithoutNeighbors']}。", "",
             f"活字候補 macro MAE {font_metrics['macroMAE']:.4f}、手書き候補 macro MAE {hand_metrics['macroMAE']:.4f}。数値は画素重なり教師との一致で、意味上の正解率ではありません。", "",
             "| 行 | 中心記号 | 類似部分集合 |", "|---:|---|---|"]
    for subset in subsets:
        table.append(f"| {subset['focusIndex'] + 1} | {subset['focusDisplay']} | "
                     + "、".join(member["display"] for member in subset["members"]) + " |")
    output_path.with_suffix(".md").write_text("\n".join(table) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(output_path), "labels": len(subsets),
                      "acceptedPairs": len(edges), "labelsWithNeighbors": output["labelsWithNeighbors"],
                      "fontMacroMAE": font_metrics["macroMAE"],
                      "handwritingMacroMAE": hand_metrics["macroMAE"]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
