#!/usr/bin/env python3
"""Create provenance-preserving fit/validation data for sparse glyphs.

Font resolution views and annotated handwritten glyphs are emitted as separate
modalities. Synthetic views retain their parent font identity and never count
as additional font styles. Only the source-disjoint Fold-07 fit/inner-valid
teachers are read; outer-test teachers are not opened.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ModelConversion"))
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import rasterize_group
from train_firebird_part_similarity import shape_channels


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def shape_view(image: np.ndarray, resolution: int) -> np.ndarray:
    if image.shape != (2, 64, 64) or resolution not in (16, 32):
        raise ValueError("expected a 2x64x64 font glyph and a 16/32 resolution view")
    scale = 64 // resolution
    reduced = image.reshape(2, resolution, scale, resolution, scale).max(axis=(2, 4))
    return np.repeat(np.repeat(reduced, scale, axis=1), scale, axis=2)


def direct_shape(dataset: DirectAnchorDataset, index: int) -> np.ndarray:
    sample = dataset[index]
    raster = rasterize_group(sample["points"]).unsqueeze(0)
    maps = shape_channels(raster).mul_(255).round().to(torch.uint8)[0]
    return maps.cpu().numpy()


def write_shape_bank(path: Path, rows: list[tuple[dict, np.ndarray]]) -> None:
    bank = np.memmap(path, mode="w+", dtype=np.uint8, shape=(len(rows), 2, 64, 64))
    with path.with_suffix(".jsonl").open("w", encoding="utf-8") as stream:
        for index, (metadata, image) in enumerate(rows):
            if image.shape != (2, 64, 64) or not np.isfinite(image).all():
                raise ValueError(f"invalid shape image at row {index}")
            bank[index] = image
            stream.write(json.dumps({"imageIndex": index, **metadata}, ensure_ascii=False) + "\n")
    bank.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path,
                        default=Path("/Volumes/ORICO/Developer/inf6-training/dataset/mathwriting-2024"))
    parser.add_argument("--font-manifest", type=Path,
                        default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--font-shapes", type=Path,
                        default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3/canonical-contour-skeleton.u8"))
    parser.add_argument("--font-report", type=Path,
                        default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3/training-report.json"))
    parser.add_argument("--font-coverage", type=Path,
                        default=Path("runs/agent-control/cycle634-complete-font-coverage-audit/symbols.csv"))
    parser.add_argument("--fit-teachers", type=Path,
                        default=Path("runs/hinotori-raster-holdout-v2-20261103/fold-07/fit-teachers.jsonl"))
    parser.add_argument("--source-split", type=Path,
                        default=Path("runs/hinotori-raster-holdout-v2-20261103/fold-07/fit-source-split.json"))
    parser.add_argument("--vocabulary", type=Path,
                        default=Path("runs/agent-control/cycle621-firebird-label-kinds.json"))
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite gap-fill corpus: {args.output}")
    for path in (args.dataset_root / "train", args.font_manifest, args.font_shapes,
                 args.font_report, args.font_coverage, args.fit_teachers,
                 args.source_split, args.vocabulary):
        if not path.exists():
            raise FileNotFoundError(path)

    manifest_bytes = args.font_manifest.read_bytes()
    font_manifest = json.loads(manifest_bytes)
    report = json.loads(args.font_report.read_text(encoding="utf-8"))
    vocab = json.loads(args.vocabulary.read_text(encoding="utf-8"))
    entries = vocab.get("entries")
    if (font_manifest.get("schema") != "firebird-mac-font-glyph-raster-v1"
            or len(entries or []) != 229
            or font_manifest.get("vocabularySHA256") != vocab.get("vocabularySHA256")
            or report.get("corpusManifestSHA256") != sha256(args.font_manifest)
            or args.font_shapes.stat().st_size != len(font_manifest["rows"]) * 2 * 64 * 64):
        raise ValueError("font corpus, ordered vocabulary, or shape bank provenance mismatch")
    if report.get("schema") != "firebird-symmetric-shape-pair-vit-v3":
        raise ValueError("unexpected font-fit report")

    label_by_index = {int(row["index"]): str(row["label"]) for row in entries}
    if set(label_by_index) != set(range(229)):
        raise ValueError("the official 229-label vocabulary is not contiguous")
    label_index = {label: index for index, label in label_by_index.items()}
    coverage = {}
    with args.font_coverage.open(encoding="utf-8", newline="") as stream:
        for row in csv.DictReader(stream):
            coverage[int(row["vocabularyIndex"])] = row
    drawable_indices = set(label_index for label_index in range(229)
                           if entries[label_index]["kind"] != "math-structure")
    if set(coverage) != drawable_indices or len(drawable_indices) != 228:
        raise ValueError("full font support audit must cover exactly 228 drawable vocabulary entries")

    fit_font_files = set(report["fitFontFiles"])
    font_rows = [row for row in font_manifest["rows"] if row["fontFileSHA256"] in fit_font_files]
    font_bank = np.memmap(args.font_shapes, mode="r", dtype=np.uint8,
                          shape=(len(font_manifest["rows"]), 2, 64, 64))
    sparse_indices = {index for index, row in coverage.items()
                      if int(row["fontFileCount"]) < 10}
    synthetic_rows: list[tuple[dict, np.ndarray]] = []
    fit_font_file_support: dict[int, set[str]] = defaultdict(set)
    fit_font_face_support: dict[int, set[str]] = defaultdict(set)
    fit_font_parent_rows: dict[int, int] = Counter()
    for row in font_rows:
        index = int(row["vocabularyIndex"])
        if index in drawable_indices:
            fit_font_file_support[index].add(row["fontFileSHA256"])
            fit_font_face_support[index].add(row["postScriptName"])
        if index in sparse_indices and index in drawable_indices:
            fit_font_parent_rows[index] += 1
            base = np.array(font_bank[int(row["imageIndex"])], copy=True)
            for resolution in (16, 32):
                synthetic_rows.append(({
                    "label": label_by_index[index], "vocabularyIndex": index,
                    "modality": "synthetic-font-resolution-view",
                    "parentFontFileSHA256": row["fontFileSHA256"],
                    "parentPostScriptName": row["postScriptName"],
                    "parentImageIndex": int(row["imageIndex"]),
                    "effectiveResolution": resolution,
                    "independentFontStyle": False,
                }, shape_view(base, resolution)))

    source_split = json.loads(args.source_split.read_text(encoding="utf-8"))["sourceSplit"]
    fit_teacher_rows = [json.loads(line) for line in args.fit_teachers.read_text(encoding="utf-8").splitlines() if line]
    missing_sources = sorted({str(row["sourceSampleId"]) for row in fit_teacher_rows} - set(source_split))
    if missing_sources:
        raise ValueError(f"fit source split omits teacher sources: {missing_sources[:3]}")
    fit_dataset = DirectAnchorDataset(args.fit_teachers, args.source_split, args.dataset_root,
                                      point_count=128, split="train", temporal=False)
    valid_dataset = DirectAnchorDataset(args.fit_teachers, args.source_split, args.dataset_root,
                                       point_count=128, split="valid", temporal=False)
    # Keep the structural fraction operator out of isolated-glyph image learning.
    train_rows: list[tuple[dict, np.ndarray]] = []
    valid_rows: list[tuple[dict, np.ndarray]] = []
    handwriting_train_counts: Counter[int] = Counter()
    handwriting_train_sources: dict[int, set[str]] = defaultdict(set)
    handwriting_valid_counts: Counter[int] = Counter()
    handwriting_valid_sources: dict[int, set[str]] = defaultdict(set)
    structural_fraction_train = structural_fraction_valid = 0
    for dataset, output_rows, counts, sources, split_name in (
        (fit_dataset, train_rows, handwriting_train_counts, handwriting_train_sources, "fit-train"),
        (valid_dataset, valid_rows, handwriting_valid_counts, handwriting_valid_sources, "inner-valid"),
    ):
        for i, teacher in enumerate(dataset.rows):
            label = str(teacher["label"])
            if label not in label_index:
                raise ValueError(f"handwriting label is not in the official vocabulary: {label}")
            index = label_index[label]
            if int(teacher["classIndex"]) != index:
                raise ValueError(f"handwriting class index disagrees with official vocabulary: {label}")
            if label == "\\frac":
                if split_name == "fit-train": structural_fraction_train += 1
                else: structural_fraction_valid += 1
                continue
            output_rows.append(({
                "label": label, "vocabularyIndex": index,
                "modality": "handwriting-direct-teacher",
                "sourceSampleId": str(teacher["sourceSampleId"]),
                "strokeIndices": teacher["strokeIndices"],
                "split": split_name,
                "teacherSHA256": sha256(args.fit_teachers),
            }, direct_shape(dataset, i)))
            counts[index] += 1
            sources[index].add(str(teacher["sourceSampleId"]))

    args.output.mkdir(parents=True)
    write_shape_bank(args.output / "synthetic-font-shapes.u8", synthetic_rows)
    write_shape_bank(args.output / "handwriting-fit-shapes.u8", train_rows)
    write_shape_bank(args.output / "handwriting-valid-shapes.u8", valid_rows)

    coverage_path = args.output / "symbol-coverage.csv"
    with coverage_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["vocabularyIndex", "symbol", "isStructural", "allFontFiles",
                         "fitFontFiles", "fitFontFaces", "syntheticResolutionViews",
                         "handwritingFitSamples", "handwritingFitFormulaSources",
                         "handwritingInnerValidSamples", "handwritingInnerValidFormulaSources",
                         "gapStatus"])
        for index in range(229):
            label = label_by_index[index]
            structural = label == "\\frac"
            font_files = int(coverage[index]["fontFileCount"]) if index in coverage else 0
            views = sum(1 for row, _ in synthetic_rows if row["vocabularyIndex"] == index)
            if structural:
                status = "structural-token; no standalone font glyph"
            elif font_files < 10 and handwriting_train_counts[index] > 0:
                status = "sparse-typeface support supplemented by fit handwriting and marked resolution views"
            elif font_files < 10:
                status = "sparse-typeface support; no fit handwriting sample"
            elif handwriting_train_counts[index] == 0:
                status = "font-supported; no fit handwriting sample"
            else:
                status = "font and fit handwriting present"
            writer.writerow([index, label, structural, font_files,
                             len(fit_font_file_support[index]), len(fit_font_face_support[index]),
                             views, handwriting_train_counts[index], len(handwriting_train_sources[index]),
                             handwriting_valid_counts[index], len(handwriting_valid_sources[index]), status])

    report_out = {
        "schema": "firebird-fit-only-synthetic-font-and-handwriting-gap-fill-v1",
        "inputs": {
            "fontManifestSHA256": sha256(args.font_manifest),
            "fontShapeBankSHA256": sha256(args.font_shapes),
            "fontFitReportSHA256": sha256(args.font_report),
            "fontCoverageAuditSHA256": sha256(args.font_coverage),
            "fitTeacherSHA256": sha256(args.fit_teachers),
            "fitSourceSplitSHA256": sha256(args.source_split),
            "vocabularySHA256": sha256(args.vocabulary),
        },
        "fontFitSourceFiles": len(fit_font_files),
        "syntheticFontResolutionViews": {
            "rows": len(synthetic_rows), "targetLabels": len(sparse_indices),
            "resolutions": [16, 32],
            "parentFontRows": sum(fit_font_parent_rows.values()),
            "countAsIndependentFontStyles": False,
            "targetRule": "all glyphs with fewer than 10 distinct source font files in the complete audit",
        },
        "handwriting": {
            "fitImages": len(train_rows), "fitFormulaSources": len({row["sourceSampleId"] for row, _ in train_rows}),
            "innerValidImages": len(valid_rows), "innerValidFormulaSources": len({row["sourceSampleId"] for row, _ in valid_rows}),
            "fractionStructuralFitTeachersExcludedFromRaster": structural_fraction_train,
            "fractionStructuralInnerValidTeachersExcludedFromRaster": structural_fraction_valid,
            "outerTestTeachersOpened": False,
            "fitTeacherRowsRead": len(fit_teacher_rows),
        },
        "support": {
            "labels": 229,
            "labelsWithFontSupport": 228,
            "labelsWithFitHandwriting": sum(bool(handwriting_train_counts[i]) for i in range(229)),
            "labelsWithBothFontAndHandwriting": sum(bool(fit_font_file_support[i]) and bool(handwriting_train_counts[i]) for i in range(229)),
            "labelsWithNoFitHandwriting": [label_by_index[i] for i in range(229) if not handwriting_train_counts[i]],
            "labelsWithOneOrFewerFitFontFiles": [label_by_index[i] for i in sorted(drawable_indices) if len(fit_font_file_support[i]) <= 1],
            "syntheticViewsDoNotIncreaseIndependentFontCounts": True,
        },
        "artifacts": {
            "symbolCoverage": str(coverage_path),
            "syntheticFontShapeBank": str(args.output / "synthetic-font-shapes.u8"),
            "handwritingFitShapeBank": str(args.output / "handwriting-fit-shapes.u8"),
            "handwritingInnerValidShapeBank": str(args.output / "handwriting-valid-shapes.u8"),
        },
        "note": "This is a fit-only gap-fill corpus artifact. It does not claim independent font-style diversity or model improvement; the generated banks must be consumed by the pair model and evaluated on untouched inner-valid sources before adoption.",
    }
    report_out["artifactSHA256"] = {
        path.name: sha256(path) for path in args.output.iterdir() if path.is_file()
    }
    (args.output / "manifest.json").write_text(json.dumps(report_out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["# Firebird fit-only font and handwriting gap-fill corpus", "",
             "This artifact adds targeted low-resolution views for sparse-font glyphs and rasterized direct handwriting. It preserves the original font/sample identities and uses only Fold-07 fit-train plus inner-valid teachers.", "",
             f"- Fit font files: {len(fit_font_files)}", f"- Sparse-font labels targeted: {len(sparse_indices)}",
             f"- Synthetic 16/32px raster views: {len(synthetic_rows)} (not independent fonts)",
             f"- Handwriting fit images: {len(train_rows)}", f"- Handwriting inner-valid images: {len(valid_rows)}",
             f"- Structural fraction examples kept outside standalone-glyph rasterization: fit {structural_fraction_train}, inner-valid {structural_fraction_valid}",
             f"- Outer-test teachers opened: no", "",
             "`symbol-coverage.csv` contains all 229 vocabulary entries. `\frac` is a structural command without a standalone font glyph; it is therefore not fabricated as a font image. The fit and inner-valid handwriting banks are separate. Synthetic resolution views remain linked to their parent PostScript face and source font file; they do not increase independent-style counts.", "",
             "These are prepared data, not a trained or improved model. The pair trainer must consume the fit banks, and adoption requires a same-source held-out comparison using the untouched inner-valid bank.", ""]
    (args.output / "README.md").write_text("\n".join(lines), encoding="utf-8")
    print(json.dumps(report_out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
