#!/usr/bin/env python3
"""Generate targeted raster-font variants for symbols with sparse typeface support.

Variants are derived only from fit-font glyphs. They are counted as training
views, never as independent fonts. Existing gap-fill assets are read-only.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def resolution_view(image: np.ndarray, resolution: int, threshold: float) -> np.ndarray:
    source = torch.from_numpy(image.astype(np.float32, copy=False))[None]
    reduced = F.interpolate(source, size=(resolution, resolution), mode="area")
    binary = (reduced >= threshold).to(torch.float32)
    expanded = F.interpolate(binary, size=(64, 64), mode="nearest")[0]
    return expanded.to(torch.uint8).numpy()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--font-manifest", type=Path,
                        default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--font-shapes", type=Path,
                        default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3/canonical-contour-skeleton.u8"))
    parser.add_argument("--font-report", type=Path,
                        default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3/training-report.json"))
    parser.add_argument("--coverage", type=Path,
                        default=Path("runs/agent-control/cycle634-complete-font-coverage-audit/symbols.csv"))
    parser.add_argument("--existing-bank", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/synthetic-font-shapes.u8"))
    parser.add_argument("--existing-index", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/synthetic-font-shapes.jsonl"))
    parser.add_argument("--target-unique-views", type=int, default=10)
    args = parser.parse_args()

    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite output: {args.output}")
    if args.target_unique_views < 2:
        raise ValueError("target-unique-views must be at least 2")
    for path in (args.font_manifest, args.font_shapes, args.font_report, args.coverage,
                 args.existing_bank, args.existing_index):
        if not path.is_file():
            raise FileNotFoundError(path)

    manifest_bytes = args.font_manifest.read_bytes()
    font_manifest = json.loads(manifest_bytes)
    report_bytes = args.font_report.read_bytes()
    fit_fonts = set(json.loads(report_bytes)["fitFontFiles"])
    rows = font_manifest["rows"]
    shape_size = len(rows) * 2 * 64 * 64
    if (font_manifest.get("schema") != "firebird-mac-font-glyph-raster-v1"
            or args.font_shapes.stat().st_size != shape_size):
        raise ValueError("authoritative font-shape bank does not match the manifest")

    coverage: dict[int, dict] = {}
    with args.coverage.open(encoding="utf-8", newline="") as stream:
        for row in csv.DictReader(stream):
            coverage[int(row["vocabularyIndex"])] = row
    if len(coverage) != 228:
        raise ValueError("complete font coverage audit must contain 228 drawable labels")

    existing_rows = [json.loads(line) for line in args.existing_index.read_text(encoding="utf-8").splitlines() if line]
    if args.existing_bank.stat().st_size != len(existing_rows) * 2 * 64 * 64:
        raise ValueError("existing synthetic bank size does not match its index")
    existing = np.memmap(args.existing_bank, mode="r", dtype=np.uint8,
                         shape=(len(existing_rows), 2, 64, 64))
    base = np.memmap(args.font_shapes, mode="r", dtype=np.uint8,
                     shape=(len(rows), 2, 64, 64))

    fit_glyphs: dict[int, list[tuple[str, int, dict]]] = defaultdict(list)
    seen_file_symbol: set[tuple[int, str]] = set()
    for row in rows:
        label = int(row["vocabularyIndex"])
        font_hash = str(row["fontFileSHA256"])
        key = (label, font_hash)
        if font_hash in fit_fonts and key not in seen_file_symbol:
            seen_file_symbol.add(key)
            fit_glyphs[label].append((font_hash, int(row["imageIndex"]), row))

    existing_by_label: dict[int, list[int]] = defaultdict(list)
    for row_id, row in enumerate(existing_rows):
        existing_by_label[int(row["vocabularyIndex"])].append(row_id)

    target_labels = {
        index for index, row in coverage.items()
        if int(row["fontFileCount"]) < args.target_unique_views
    }
    # Use the same complete-audit definition of sparse support as cycle 635.
    all_font_sparse = {index for index, row in coverage.items() if int(row["fontFileCount"]) < 10}
    if target_labels != all_font_sparse:
        raise ValueError("target threshold must match the audited sparse-font rule (10 files)")

    # Candidate views span useful raster scales and antialias coverage thresholds.
    resolutions = (10, 12, 14, 18, 20, 24, 28, 40, 48, 56)
    thresholds = (0.25, 0.40, 0.55, 0.70)
    generated: list[tuple[dict, np.ndarray]] = []
    per_label: dict[int, dict] = {}
    for label in sorted(target_labels):
        source_rows = sorted(fit_glyphs.get(label, []), key=lambda item: item[0])
        if not source_rows:
            raise ValueError(f"sparse glyph {label} has no fit-font source glyph")
        known_hashes: set[str] = set()
        unique_count = 0
        for _, image_index, _ in source_rows:
            key = hashlib.sha256(np.asarray(base[image_index]).tobytes()).hexdigest()
            if key not in known_hashes:
                known_hashes.add(key)
                unique_count += 1
        for existing_id in existing_by_label.get(label, []):
            image = np.asarray(existing[existing_id])
            key = hashlib.sha256(image.tobytes()).hexdigest()
            if key not in known_hashes:
                known_hashes.add(key)
                unique_count += 1

        initial_unique = unique_count
        attempted = 0
        for resolution in resolutions:
            for threshold in thresholds:
                for font_hash, image_index, row in source_rows:
                    if unique_count >= args.target_unique_views:
                        break
                    attempted += 1
                    image = resolution_view(np.asarray(base[image_index]), resolution, threshold)
                    if not np.any(image):
                        continue
                    key = hashlib.sha256(image.tobytes()).hexdigest()
                    if key in known_hashes:
                        continue
                    known_hashes.add(key)
                    generated.append(({
                        "label": str(row["label"]),
                        "vocabularyIndex": label,
                        "modality": "synthetic-font-resolution-variant",
                        "parentFontFileSHA256": font_hash,
                        "parentFamilyName": str(row["familyName"]),
                        "parentPostScriptName": str(row["postScriptName"]),
                        "parentImageIndex": image_index,
                        "effectiveResolution": resolution,
                        "coverageThreshold": threshold,
                        "independentFontStyle": False,
                    }, image))
                    unique_count += 1
                if unique_count >= args.target_unique_views:
                    break
            if unique_count >= args.target_unique_views:
                break
        if unique_count < args.target_unique_views:
            raise ValueError(
                f"could generate only {unique_count}/{args.target_unique_views} unique views for label {label}"
            )
        per_label[label] = {
            "symbol": str(source_rows[0][2]["label"]),
            "completeAuditFontFiles": int(coverage[label]["fontFileCount"]),
            "fitFontFiles": len(source_rows),
            "uniqueViewsBefore": initial_unique,
            "additionalUniqueViews": unique_count - initial_unique,
            "uniqueViewsAfter": unique_count,
            "candidateVariantsExamined": attempted,
        }

    args.output.mkdir(parents=True)
    bank_path = args.output / "synthetic-font-gap-variants.u8"
    index_path = args.output / "synthetic-font-gap-variants.jsonl"
    bank = np.memmap(bank_path, mode="w+", dtype=np.uint8,
                     shape=(len(generated), 2, 64, 64))
    with index_path.open("w", encoding="utf-8") as stream:
        for row_id, (metadata, image) in enumerate(generated):
            bank[row_id] = image
            stream.write(json.dumps({"imageIndex": row_id, **metadata}, ensure_ascii=False) + "\n")
    bank.flush()

    result = {
        "schema": "firebird-targeted-synthetic-font-resolution-gap-v1",
        "target": "For every drawable symbol supported by fewer than 10 source font files in the full Mac audit, increase unique fit-font raster views to 10 where fit glyph sources permit.",
        "interpretation": "Generated raster views are synthetic resolution/coverage variants, not independent font files, font families, or new author styles.",
        "inputs": {
            "fontManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
            "fitReportSHA256": hashlib.sha256(report_bytes).hexdigest(),
            "fontCoverageSHA256": digest(args.coverage),
            "fontShapeBankSHA256": digest(args.font_shapes),
            "existingSyntheticBankSHA256": digest(args.existing_bank),
            "existingSyntheticIndexSHA256": digest(args.existing_index),
        },
        "threshold": {"sparseSourceFontFileCount": 10, "targetUniqueRasterViewsPerSymbol": args.target_unique_views},
        "generation": {
            "labels": len(per_label),
            "additionalUniqueViews": len(generated),
            "resolutionsConsidered": list(resolutions),
            "coverageThresholdsConsidered": list(thresholds),
            "usesOnlyFitFontGlyphs": True,
            "usesValidationOrGenerationFonts": False,
            "countsAsIndependentFontStyles": False,
        },
        "perLabel": {str(k): v for k, v in per_label.items()},
        "referencedHandwritingGapFill": "runs/agent-control/cycle635-font-handwriting-gap-fill/handwriting-fit-shapes.u8",
        "handwritingInnerValidationMustRemainEvaluationOnly": True,
        "artifacts": {"bank": str(bank_path), "index": str(index_path)},
        "outerTestOpened": False,
    }
    result["artifactSHA256"] = {p.name: digest(p) for p in (bank_path, index_path)}
    (args.output / "manifest.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n",
                                                encoding="utf-8")
    table = ["# 火の鳥：不足字形の合成解像度バリエーション", "",
             "完全フォント監査で10未満の記号だけを対象にし、fit側の実フォント字形から追加画像を生成しました。これは新しいフォントファイルや独立した書体数ではなく、解像度・被覆率を変えた学習用ラスタ画像です。", "",
             "| 記号 | 実フォント数 | fit実フォント数 | 生成前の固有画像数 | 追加画像 | 生成後の固有画像数 |", "|---|---:|---:|---:|---:|---:|"]
    for _, value in sorted(per_label.items()):
        table.append(f"| {value['symbol']} | {value['completeAuditFontFiles']} | {value['fitFontFiles']} | {value['uniqueViewsBefore']} | {value['additionalUniqueViews']} | {value['uniqueViewsAfter']} |")
    table += ["", f"追加生成: {len(generated)}枚 / 対象記号: {len(per_label)}。手書きfit画像は cycle635 の別バンクを参照し、内側検証画像は学習へ混ぜていません。外側テストは開いていません。", ""]
    (args.output / "README.md").write_text("\n".join(table), encoding="utf-8")
    print(json.dumps({"output": str(args.output), "sparseLabels": len(per_label),
                      "additionalUniqueViews": len(generated), "targetUniqueViewsPerSymbol": args.target_unique_views,
                      "outerTestOpened": False}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
