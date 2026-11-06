#!/usr/bin/env python3
"""Score every same-font symbol pair with the held-out pair-overlap ViT."""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch

from train_firebird_pair_overlap_vit import PairOverlapViT, SCALES, pairwise_target_scores, sha256


def visible_label(item: dict) -> str:
    """Return a readable table label when a Unicode combining mark has no base glyph."""
    combining_names = {"\\dot": "点アクセント", "\\hat": "山形アクセント",
                       "\\overline": "上線", "\\tilde": "チルダ",
                       "\\underline": "下線", "\\vec": "ベクトル矢印"}
    if item.get("kind") == "unicode-combining":
        return combining_names[item["label"]]
    if item.get("kind") == "math-structure":
        return "分数構造"
    return chr(int(item["unicodeScalar"][2:], 16))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--vocabulary", type=Path, default=Path("runs/agent-control/cycle621-firebird-label-kinds.json"))
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--output-name", default="similarity-subsets.json")
    parser.add_argument("--threshold", type=float, default=.5)
    args = parser.parse_args()
    if not 0.0 < args.threshold < 1.0:
        raise ValueError("threshold must be strictly between zero and one")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited.")
    manifest_bytes = args.manifest.read_bytes()
    vocabulary_bytes = args.vocabulary.read_bytes()
    manifest = json.loads(manifest_bytes)
    vocabulary_manifest = json.loads(vocabulary_bytes)
    rows = manifest["rows"]
    report = json.loads((args.run / "training-report.json").read_text())
    if report.get("schema") != "firebird-symmetric-shape-pair-vit-v3":
        raise ValueError("checkpoint is not a pair-level overlap ViT")
    if hashlib.sha256(manifest_bytes).hexdigest() != report["corpusManifestSHA256"]:
        raise ValueError("checkpoint and authoritative glyph manifest differ")
    if vocabulary_manifest.get("vocabularySHA256") != manifest.get("vocabularySHA256"):
        raise ValueError("glyph corpus and authoritative 229-label vocabulary differ")
    canonical_path = args.run / "canonical-contour-skeleton.u8"
    if sha256(canonical_path) != report["canonicalCorpusSHA256"]:
        raise ValueError("canonical glyph corpus hash mismatch")
    if canonical_path.stat().st_size != len(rows) * 2 * 64 * 64:
        raise ValueError("canonical glyph corpus has an invalid byte size")

    vocabulary_entries = vocabulary_manifest["entries"]
    vocab = {int(item["index"]): item["label"] for item in vocabulary_entries}
    display = {int(item["index"]): visible_label(item) for item in vocabulary_entries}
    if len(vocab) != 229 or set(vocab) != set(range(229)):
        raise ValueError("authoritative vocabulary is not the complete ordered 229-label set")
    by_font_label: dict[str, dict[int, int]] = defaultdict(dict)
    generation_fonts = set(report["generationFontFiles"])
    for row_id, row in enumerate(rows):
        index = int(row["vocabularyIndex"])
        if row["fontFileSHA256"] in generation_fonts:
            by_font_label[row["fontFileSHA256"]].setdefault(index, row_id)
    if set(vocab) - {int(row["vocabularyIndex"]) for row in rows} != {97}:
        raise ValueError("unexpected non-rasterized vocabulary labels")

    model = PairOverlapViT()
    checkpoint = torch.load(args.run / "firebird-pair-overlap-vit.pt", map_location="cpu", weights_only=True)
    model.load_state_dict(checkpoint["state_dict"], strict=True)
    device = torch.device("mps")
    model.to(device).eval()
    corpus = np.memmap(canonical_path, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    pair_scores: dict[tuple[int, int], list[dict]] = defaultdict(list)
    validation_predictions, validation_targets = [], []
    with torch.inference_mode():
        for font_hash in report["generationFontFiles"]:
            entries = sorted(by_font_label.get(font_hash, {}).items())
            if len(entries) < 2:
                continue
            labels = [index for index, _ in entries]
            row_ids = [row_id for _, row_id in entries]
            font_images = np.asarray(corpus[row_ids], dtype=np.uint8)
            target_matrix = pairwise_target_scores(font_images)
            embeddings = []
            for start in range(0, len(row_ids), 256):
                x = torch.from_numpy(np.array(corpus[row_ids[start:start + 256]], copy=True)).to(
                    device=device, dtype=torch.float32
                )
                embeddings.append(model.encode(x))
            features = torch.cat(embeddings)
            pair_positions = [(i, j) for i in range(len(labels)) for j in range(i + 1, len(labels))]
            for start in range(0, len(pair_positions), 8192):
                batch = pair_positions[start:start + 8192]
                target_batch = np.asarray([target_matrix[i, j] for i, j in batch], dtype=np.float32)
                ia = torch.tensor([item[0] for item in batch], device=device)
                ib = torch.tensor([item[1] for item in batch], device=device)
                scores = model.score_embeddings(features[ia], features[ib]).cpu().numpy()
                validation_predictions.append(scores)
                validation_targets.append(target_batch)
                for (i, j), score in zip(batch, scores):
                    a, b = labels[i], labels[j]
                    pair_scores[(a, b)].append({"fontFileSHA256": font_hash,
                                                "scaleScores": {str(size): float(value)
                                                                for size, value in zip(SCALES, score)},
                                                "meanScaleScore": float(np.mean(score)),
                                                "rasterTeacherMean": float(np.mean(target_matrix[i, j]))})

    predictions = np.concatenate(validation_predictions)
    targets = np.concatenate(validation_targets)
    scale_metrics = {}
    for index, size in enumerate(SCALES):
        truth, pred = targets[:, index], predictions[:, index]
        positive, predicted_positive = truth >= .5, pred >= .5
        tp = int(np.sum(positive & predicted_positive))
        fp = int(np.sum(~positive & predicted_positive))
        fn = int(np.sum(positive & ~predicted_positive))
        tn = int(np.sum(~positive & ~predicted_positive))
        scale_metrics[str(size)] = {
            "mae": float(np.mean(np.abs(pred - truth))),
            "balancedAccuracyAtHalf": float(.5 * (tp / max(tp + fn, 1) + tn / max(tn + fp, 1))),
            "precisionAtHalf": float(tp / max(tp + fp, 1)),
            "recallAtHalf": float(tp / max(tp + fn, 1)),
            "truePositive": tp, "falsePositive": fp, "falseNegative": fn,
            "trueNegative": tn, "evaluatedPairs": len(truth)}
    scale_metrics["macroMAE"] = float(np.mean([scale_metrics[str(size)]["mae"] for size in SCALES]))
    scale_metrics["macroBalancedAccuracyAtHalf"] = float(np.mean(
        [scale_metrics[str(size)]["balancedAccuracyAtHalf"] for size in SCALES]))

    edges = []
    for (a, b), font_evidence in sorted(pair_scores.items()):
        scores = np.asarray([item["meanScaleScore"] for item in font_evidence], dtype=np.float32)
        teacher_scores = np.asarray([item["rasterTeacherMean"] for item in font_evidence], dtype=np.float32)
        median = float(np.median(scores))
        teacher_median = float(np.median(teacher_scores))
        passing = int(np.sum(scores >= args.threshold))
        teacher_passing = int(np.sum(teacher_scores >= .5))
        required = max(2, int(np.ceil(len(scores) * .5)))
        accepted = len(scores) >= 10 and median >= args.threshold and passing >= required
        teacher_accepted = len(scores) >= 10 and teacher_median >= .5 and teacher_passing >= required
        edge = {"indexA": a, "symbolA": vocab[a], "displayA": display[a],
                          "indexB": b, "symbolB": vocab[b], "displayB": display[b],
                          "generationFontCount": len(scores), "medianSharedShapeScore": median,
                          "medianRasterTeacherScore": teacher_median,
                          "fontsAtLeastHalf": passing, "requiredPassingFonts": required,
                          "rasterTeacherFontsAtLeastHalf": teacher_passing,
                          "rasterTeacherAccepted": teacher_accepted,
                          "modelAccepted": accepted, "fontEvidence": font_evidence}
        if accepted:
            edges.append(edge)
        pair_scores[(a, b)] = [edge]

    eligible_pair_evidence = [values[0] for values in pair_scores.values()
                              if values[0]["generationFontCount"] >= 10]
    accepted_model = [edge for edge in eligible_pair_evidence if edge["modelAccepted"]]
    accepted_teacher = [edge for edge in eligible_pair_evidence if edge["rasterTeacherAccepted"]]
    accepted_model_keys = {(edge["indexA"], edge["indexB"]) for edge in accepted_model}
    accepted_teacher_keys = {(edge["indexA"], edge["indexB"]) for edge in accepted_teacher}
    accepted_intersection = len(accepted_model_keys & accepted_teacher_keys)

    neighbors = {index: set() for index in range(229)}
    for edge in edges:
        neighbors[edge["indexA"]].add(edge["indexB"])
        neighbors[edge["indexB"]].add(edge["indexA"])
    subsets = []
    edge_map = defaultdict(list)
    for edge in edges:
        edge_map[edge["indexA"]].append(edge)
        edge_map[edge["indexB"]].append(edge)
    for focus in range(229):
        member_indices = [focus, *sorted(neighbors[focus])]
        subsets.append({"focusIndex": focus, "focus": vocab.get(focus, "\\frac"),
                        "focusDisplay": display.get(focus, "∕"),
                        "members": [{"index": index, "symbol": vocab.get(index, "\\frac"),
                                     "display": display.get(index, "∕")} for index in member_indices],
                        "directPairEvidence": edge_map[focus]})
    output = {"schema": "firebird-symmetric-shape-pair-vit-subsets-v3",
              "status": "candidate-pseudo-label-evaluated",
              "task": "229-label direct neighborhoods using symmetric minimum shared contour/skeleton coverage.",
              "targetDefinition": report["targetDefinition"],
              "pairAcceptance": f"Per-font mean model score across 64/32/16 must be >={args.threshold:.3f} in at least half of 40 generation fonts, with median >={args.threshold:.3f}; minimum 10 available fonts.",
              "modelAcceptanceThreshold": args.threshold,
              "checkpoint": str(args.run / "firebird-pair-overlap-vit.pt"),
              "checkpointSHA256": sha256(args.run / "firebird-pair-overlap-vit.pt"),
              "canonicalCorpusSHA256": report["canonicalCorpusSHA256"],
              "vocabularyManifestSHA256": hashlib.sha256(vocabulary_bytes).hexdigest(),
              "validationFontFiles": report["validationFontFiles"],
              "generationFontFiles": report["generationFontFiles"],
              "outerTestOpened": False, "humanReviewedPairGold": False,
              "acceptedDirectPairCount": len(edges),
              "heldoutFontRasterTargetMetrics": scale_metrics,
              "pairDecisionAgreementAgainstRasterThreshold": {
                  "eligiblePairs": len(eligible_pair_evidence),
                  "modelAcceptedPairs": len(accepted_model_keys),
                  "rasterAcceptedPairs": len(accepted_teacher_keys),
                  "truePositive": accepted_intersection,
                  "falsePositive": len(accepted_model_keys - accepted_teacher_keys),
                  "falseNegative": len(accepted_teacher_keys - accepted_model_keys),
                  "precision": accepted_intersection / max(len(accepted_model_keys), 1),
                  "recall": accepted_intersection / max(len(accepted_teacher_keys), 1)},
              "labelsWithNeighbors": sum(bool(neighbors[i]) for i in neighbors),
              "labelsWithoutNeighbors": sum(not neighbors[i] for i in neighbors),
              "subsets": subsets, "acceptedPairEvidence": edges,
              "limitations": ["Targets are explicit normalized raster overlap, not human semantic part annotations.",
                              "Font-heldout validation measures agreement with the raster target definition.",
                              "This is an image-based visual grouping; it does not use handwritten strokes or expression position.",
                              "The structural fraction label has no standalone glyph and remains a singleton."]}
    output_path = args.run / args.output_name
    output_path.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n")
    table = ["# 火の鳥・活字の輪郭／骨格類似部分集合", "",
             f"229記号。採用直接ペア {len(edges)}、近傍あり {output['labelsWithNeighbors']}、近傍なし {output['labelsWithoutNeighbors']}。", "",
             "各行は中心記号と、直接の類似候補です。推移閉包はしていません。", "",
             "| 行 | 中心記号 | 類似部分集合 |", "|---:|---|---|"]
    for subset in subsets:
        members = "、".join(item["display"] for item in subset["members"])
        table.append(f"| {subset['focusIndex'] + 1} | {subset['focusDisplay']} | {members} |")
    output_path.with_suffix(".md").write_text("\n".join(table) + "\n")
    print(json.dumps({"output": str(output_path), "labels": len(subsets),
                      "acceptedPairs": len(edges), "labelsWithNeighbors": output["labelsWithNeighbors"],
                      "labelsWithoutNeighbors": output["labelsWithoutNeighbors"]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
