#!/usr/bin/env python3
"""Whole-formula raster/AST batches; never accepts pre-cut symbol rasters."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import torch

from formula_structure_decoder import (
    FormulaStructureTeacherDataset,
    VisualVocabulary,
    build_visual_vocabulary,
    collate_formula_structure,
)
from formula_whole_input import load_formula_input
from formula_whole_model import FormulaTokenizer, load_tokenizer
from raster_formula_model import raster_tensor


class FormulaStructureRasterDataset:
    """One full FormulaRasterV1 and one AST/LaTeX teacher per sample ID."""
    def __init__(self, teachers: Path, split_root: Path, tokenizer: FormulaTokenizer, visual_vocabulary: VisualVocabulary) -> None:
        self.structure = FormulaStructureTeacherDataset(teachers, tokenizer, visual_vocabulary)
        self.split_root = split_root

    def __len__(self) -> int:
        return len(self.structure)

    def __getitem__(self, index: int) -> dict[str, Any]:
        row = self.structure[index]
        sample_id = row["sampleId"]
        formula, metadata = load_formula_input(self.split_root / f"{sample_id}.inkml")
        if metadata["sampleId"] != sample_id:
            raise ValueError(f"{sample_id}: formula source identity mismatch")
        expected_latex = self.structure.latex_tokenizer.decode(row["latexIds"].tolist())
        if metadata["normalizedLabel"] != expected_latex:
            raise ValueError(f"{sample_id}: InkML normalizedLabel and AST teacher latex differ")
        return {**row, "raster": raster_tensor(formula)}


def collate_formula_structure_rasters(rows: list[dict[str, Any]], latex_pad_id: int, visual_pad_id: int) -> dict[str, Any]:
    batch = collate_formula_structure(rows, latex_pad_id, visual_pad_id)
    raster = torch.stack([row["raster"] for row in rows])
    if raster.shape != (len(rows), 1, 512, 512):
        raise ValueError("full formula batch must be FormulaRasterV1 [B,1,512,512]")
    batch["raster"] = raster
    return batch


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--split-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--count", type=int, default=2)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    tokenizer = load_tokenizer(args.tokenizer)
    visual = build_visual_vocabulary(args.teachers)
    dataset = FormulaStructureRasterDataset(args.teachers, args.split_root, tokenizer, visual)
    if not 0 < args.count <= len(dataset):
        raise ValueError("count must select a non-empty in-range prefix")
    batch = collate_formula_structure_rasters([dataset[index] for index in range(args.count)], tokenizer.pad_id, visual.pad_id)
    report = {
        "format": "inf6-formula-structure-raster-batch-v1",
        "formulaCount": len(dataset),
        "sampleIds": batch["sampleIds"],
        "rasterShape": list(batch["raster"].shape),
        "latexShape": list(batch["latexIds"].shape),
        "visualShape": list(batch["visualIds"].shape),
        "containsPrecutSymbolRaster": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
