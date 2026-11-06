#!/usr/bin/env python3
"""Compare consensus-U-Net pair IoU with direct glyph-map IoU on held-out fonts."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


LEVELS = (64, 32, 16, 8, 4)
PAIRS = (
    ("X/x", "U+0058", "U+0078"),
    ("S/s", "U+0053", "U+0073"),
    ("M/m", "U+004D", "U+006D"),
    ("V/v", "U+0056", "U+0076"),
    ("Z/2", "U+005A", "U+0032"),
    ("A/𝔸", "U+0041", "U+1D538"),
)


def pyramid(mask: np.ndarray) -> list[np.ndarray]:
    output = []
    for side in LEVELS:
        block = 64 // side
        pooled = mask.reshape(side, block, side, block).mean(axis=(1, 3))
        output.append(pooled >= 0.5)
    return output


def iou(left: np.ndarray, right: np.ndarray) -> float:
    intersection = np.logical_and(left, right).sum()
    union = np.logical_or(left, right).sum()
    return float(intersection / union) if union else 0.0


def compare_pairs(rows, validation_fonts, raw_bank, shape_bank, vocabulary, model_pairs):
    by_scalar = {entry.get("unicodeScalar"): int(entry["index"])
                 for entry in vocabulary["entries"]}
    indices = {}
    for index, row in enumerate(rows):
        if row["fontFileSHA256"] in validation_fonts:
            indices.setdefault((row["fontFileSHA256"], int(row["vocabularyIndex"])), index)
    results = []
    for name, scalar_a, scalar_b in PAIRS:
        if scalar_a not in by_scalar or scalar_b not in by_scalar:
            continue
        label_a, label_b = by_scalar[scalar_a], by_scalar[scalar_b]
        common_fonts = sorted({font for font, label in indices if label == label_a}
                              & {font for font, label in indices if label == label_b})
        model = next((item for item in model_pairs if item["pair"] == name), None)
        per_font = []
        for offset, font in enumerate(common_fonts):
            a_index = indices[(font, label_a)]
            b_index = indices[(font, label_b)]
            raw_a = pyramid(raw_bank[a_index] > 0)
            raw_b = pyramid(raw_bank[b_index] > 0)
            shape_a = pyramid(np.any(shape_bank[a_index] > 0, axis=0))
            shape_b = pyramid(np.any(shape_bank[b_index] > 0, axis=0))
            raw_scores = [iou(a, b) for a, b in zip(raw_a, raw_b)]
            shape_scores = [iou(a, b) for a, b in zip(shape_a, shape_b)]
            model_scores = (model["perFontIoU"][offset]["iouByResolution64_32_16_8_4"]
                            if model and offset < len(model["perFontIoU"]) else None)
            per_font.append({
                "fontFileSHA256": font,
                "rawInkIoUByResolution64_32_16_8_4": raw_scores,
                "contourSkeletonIoUByResolution64_32_16_8_4": shape_scores,
                "unetConsensusIoUByResolution64_32_16_8_4": model_scores,
            })
        summaries = {}
        for key in ("rawInkIoUByResolution64_32_16_8_4",
                    "contourSkeletonIoUByResolution64_32_16_8_4",
                    "unetConsensusIoUByResolution64_32_16_8_4"):
            matrices = [item[key] for item in per_font if item[key] is not None]
            if matrices:
                array = np.asarray(matrices, dtype=np.float64)
                summaries[key] = {
                    "medianByResolution64_32_16_8_4": np.median(array, axis=0).tolist(),
                    "medianEqualWeightMean": float(np.median(array.mean(axis=1))),
                    "passingAtMeanIoU0_5": int((array.mean(axis=1) >= 0.5).sum()),
                    "commonFontCount": int(len(array)),
                }
            else:
                summaries[key] = None
        results.append({"pair": name, "commonValidationFonts": len(common_fonts),
                        "summary": summaries, "perFont": per_font})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite baseline report: {args.output}")
    corpus = Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json")
    raw_path = Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.u8")
    shape_path = Path("runs/agent-control/cycle624-firebird-part-similarity-v1/contour-skeleton-corpus.u8")
    split_path = Path("runs/agent-control/cycle625-firebird-pair-overlap-v2/training-report.json")
    vocab_path = Path("runs/agent-control/cycle621-firebird-label-kinds.json")
    rows = json.loads(corpus.read_text())["rows"]
    split = json.loads(split_path.read_text())
    report = json.loads((args.run / "training-report.json").read_text())
    vocabulary = json.loads(vocab_path.read_text())
    n = len(rows)
    raw_bank = np.memmap(raw_path, mode="r", dtype=np.uint8, shape=(n, 64, 64))
    shape_bank = np.memmap(shape_path, mode="r", dtype=np.uint8, shape=(n, 2, 64, 64))
    validations = set(split["validationFontFiles"])
    result = {
        "schema": "firebird-consensus-unet-input-baseline-v1",
        "run": str(args.run),
        "validationFontCount": len(validations),
        "levels": list(LEVELS),
        "rawInkDefinition": "normalized grayscale raster > 0, average-pooled within each scale block, then threshold >= 0.5",
        "contourSkeletonDefinition": "union of contour and medial-skeleton channels, average-pooled within each scale block, then threshold >= 0.5",
        "modelMetric": "cycle650 U-Net consensus-map prediction IoU, aligned by sorted validation font hashes",
        "outerTestOpened": False,
        "pairs": compare_pairs(rows, validations, raw_bank, shape_bank, vocabulary,
                               report["validationKnownPairDiagnostics"]),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(args.output),
                      "pairs": [{"pair": p["pair"], "fonts": p["commonValidationFonts"],
                                 "raw": p["summary"]["rawInkIoUByResolution64_32_16_8_4"],
                                 "shape": p["summary"]["contourSkeletonIoUByResolution64_32_16_8_4"],
                                 "unet": p["summary"]["unetConsensusIoUByResolution64_32_16_8_4"]}
                                for p in result["pairs"]]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
