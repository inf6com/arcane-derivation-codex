#!/usr/bin/env python3
"""Calibrate the pair-subset operating threshold on the disjoint validation fonts."""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch

from train_firebird_pair_overlap_vit import PairOverlapViT, pairwise_target_scores, sha256


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--run", type=Path, required=True)
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited.")
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    report = json.loads((args.run / "training-report.json").read_text())
    if report.get("schema") != "firebird-symmetric-shape-pair-vit-v2":
        raise ValueError("checkpoint is not a pair-level overlap ViT")
    if sha256(args.manifest) != report["corpusManifestSHA256"]:
        raise ValueError("checkpoint and glyph manifest differ")
    corpus_path = args.run / "canonical-contour-skeleton.u8"
    if sha256(corpus_path) != report["canonicalCorpusSHA256"]:
        raise ValueError("canonical glyph corpus hash mismatch")
    rows = manifest["rows"]
    corpus = np.memmap(corpus_path, mode="r", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    validation_fonts = set(report["validationFontFiles"])
    by_font: dict[str, dict[int, int]] = defaultdict(dict)
    for row_id, row in enumerate(rows):
        font_hash = row["fontFileSHA256"]
        if font_hash in validation_fonts:
            by_font[font_hash].setdefault(int(row["vocabularyIndex"]), row_id)

    model = PairOverlapViT()
    checkpoint = torch.load(args.run / "firebird-pair-overlap-vit.pt", map_location="cpu", weights_only=True)
    model.load_state_dict(checkpoint["state_dict"], strict=True)
    device = torch.device("mps")
    model.to(device).eval()
    pair_predictions: dict[tuple[int, int], list[float]] = defaultdict(list)
    pair_targets: dict[tuple[int, int], list[float]] = defaultdict(list)
    with torch.inference_mode():
        for font_hash in report["validationFontFiles"]:
            entries = sorted(by_font.get(font_hash, {}).items())
            labels = [index for index, _ in entries]
            row_ids = [row_id for _, row_id in entries]
            if len(row_ids) < 2:
                continue
            images = np.asarray(corpus[row_ids], dtype=np.uint8)
            targets = pairwise_target_scores(images)
            encoded = []
            for start in range(0, len(row_ids), 256):
                x = torch.from_numpy(images[start:start + 256].copy()).to(device=device, dtype=torch.float32)
                encoded.append(model.encode(x))
            features = torch.cat(encoded)
            positions = [(i, j) for i in range(len(labels)) for j in range(i + 1, len(labels))]
            for start in range(0, len(positions), 8192):
                batch = positions[start:start + 8192]
                ia = torch.tensor([pair[0] for pair in batch], device=device)
                ib = torch.tensor([pair[1] for pair in batch], device=device)
                scores = model.score_embeddings(features[ia], features[ib]).cpu().numpy().mean(axis=1)
                for (i, j), prediction in zip(batch, scores):
                    key = (labels[i], labels[j])
                    pair_predictions[key].append(float(prediction))
                    pair_targets[key].append(float(targets[i, j].mean()))

    eligible = [key for key in pair_predictions if len(pair_predictions[key]) >= 5]
    truth = {}
    for key in eligible:
        values = np.asarray(pair_targets[key])
        truth[key] = bool(np.median(values) >= .5 and int(np.sum(values >= .5)) >= int(np.ceil(len(values) * .5)))
    grid = np.round(np.arange(.50, .951, .025), 3)
    candidates = []
    for threshold in grid:
        predicted = set()
        for key in eligible:
            values = np.asarray(pair_predictions[key])
            if np.median(values) >= threshold and int(np.sum(values >= threshold)) >= int(np.ceil(len(values) * .5)):
                predicted.add(key)
        expected = {key for key, accepted in truth.items() if accepted}
        tp = len(predicted & expected)
        fp = len(predicted - expected)
        fn = len(expected - predicted)
        precision = tp / max(tp + fp, 1)
        recall = tp / max(tp + fn, 1)
        candidates.append({"threshold": float(threshold), "predictedPairs": len(predicted),
                           "rasterTargetPairs": len(expected), "truePositive": tp,
                           "falsePositive": fp, "falseNegative": fn,
                           "precision": precision, "recall": recall,
                           "f1": 2 * precision * recall / max(precision + recall, 1e-12)})
    selected = max(candidates, key=lambda row: (row["f1"], row["precision"], row["threshold"]))
    output = {"schema": "firebird-pair-overlap-threshold-calibration-v2",
              "checkpointSHA256": sha256(args.run / "firebird-pair-overlap-vit.pt"),
              "corpusManifestSHA256": report["corpusManifestSHA256"],
              "validationFontFiles": report["validationFontFiles"],
              "validationFontCount": len(report["validationFontFiles"]),
              "minimumFontObservationsPerPair": 5,
              "eligiblePairs": len(eligible), "selected": selected,
              "thresholdSweep": candidates,
              "generationFontsUsed": False,
              "meaning": "Selects an operating threshold against the explicit raster-overlap pair target, not human semantic judgments."}
    path = args.run / "threshold-calibration.json"
    path.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(path), "selected": selected,
                      "eligiblePairs": len(eligible)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
