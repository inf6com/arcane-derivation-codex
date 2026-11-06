#!/usr/bin/env python3
"""Fine-tune the pair-overlap ViT with fit-only synthetic and handwriting views."""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from torch.utils.data import DataLoader

from train_firebird_pair_overlap_vit import (
    PairDataset,
    PairOverlapViT,
    canonicalize,
    evaluate,
    font_pair_records,
    sha256,
    target_scores,
)


IMAGE_SHAPE = (2, 64, 64)
IMAGE_BYTES = int(np.prod(IMAGE_SHAPE))


class CombinedCorpus:
    """Read-only index across the source font, synthetic, and hand banks."""

    def __init__(self, banks: list[np.ndarray]):
        if not banks or any(bank.ndim != 4 or bank.shape[1:] != IMAGE_SHAPE for bank in banks):
            raise ValueError("all banks must have shape [N,2,64,64]")
        self.banks = banks
        self.ends = np.cumsum([len(bank) for bank in banks]).tolist()
        self.starts = [0, *self.ends[:-1]]

    def __len__(self) -> int:
        return self.ends[-1]

    def __getitem__(self, index: int) -> np.ndarray:
        if index < 0 or index >= len(self):
            raise IndexError(index)
        bank_index = int(np.searchsorted(self.ends, index, side="right"))
        return self.banks[bank_index][index - self.starts[bank_index]]


def load_indexed_bank(bank_path: Path, index_path: Path) -> tuple[np.ndarray, list[dict]]:
    rows = [json.loads(line) for line in index_path.read_text(encoding="utf-8").splitlines() if line]
    if bank_path.stat().st_size != len(rows) * IMAGE_BYTES:
        raise ValueError(f"raster bank byte count disagrees with index: {bank_path}")
    bank = np.memmap(bank_path, mode="r", dtype=np.uint8, shape=(len(rows), *IMAGE_SHAPE))
    if any(int(row.get("imageIndex", -1)) != i for i, row in enumerate(rows)):
        raise ValueError(f"imageIndex is not contiguous in {index_path}")
    if any(np.asarray(bank[i]).max() == 0 for i in range(len(rows))):
        raise ValueError(f"empty raster in {bank_path}")
    return bank, rows


def canonical_bank(bank: np.ndarray) -> np.ndarray:
    result = np.empty((len(bank), *IMAGE_SHAPE), dtype=np.uint8)
    for i in range(len(bank)):
        result[i] = canonicalize(np.asarray(bank[i]))
    return result


def deterministic_hand_pairs(rows: list[dict], canonical: np.ndarray, offset: int,
                             seed: int) -> tuple[np.ndarray, dict]:
    by_label: dict[int, list[int]] = defaultdict(list)
    for image_index, row in enumerate(rows):
        by_label[int(row["vocabularyIndex"])].append(image_index)
    labels = sorted(by_label)
    pairs: list[tuple[int, int, float, float, float]] = []
    class_pair_count = 0
    for left_pos, label_a in enumerate(labels):
        for label_b in labels[left_pos + 1:]:
            choices_a, choices_b = by_label[label_a], by_label[label_b]
            digest = hashlib.sha256(f"{seed}:{label_a}:{label_b}".encode()).digest()
            row_a = choices_a[int.from_bytes(digest[:8], "big") % len(choices_a)]
            row_b = choices_b[int.from_bytes(digest[8:16], "big") % len(choices_b)]
            score = target_scores(canonical[row_a], canonical[row_b])
            pairs.append((offset + row_a, offset + row_b, *score.tolist()))
            class_pair_count += 1
    if not pairs:
        raise ValueError("handwriting source produced no cross-label pairs")
    return np.asarray(pairs, dtype=np.float32), {
        "images": len(rows), "labels": len(by_label), "crossLabelPairs": class_pair_count,
        "pairSampling": "one deterministic image pair for each observed unordered label pair",
        "writerIdentityUsed": False,
    }


def synthetic_font_pairs(rows: list[dict], synthetic_images: np.ndarray,
                         font_rows: list[dict], font_images: np.ndarray,
                         offset: int, seed: int, sibling_limit: int) -> tuple[np.ndarray, dict]:
    by_font_label: dict[str, dict[int, int]] = defaultdict(dict)
    for row_id, row in enumerate(font_rows):
        by_font_label[str(row["fontFileSHA256"])].setdefault(int(row["vocabularyIndex"]), row_id)
    fit_fonts = set(by_font_label)
    pairs: list[tuple[int, int, float, float, float]] = []
    used_rows = 0
    missing_parent = []
    for synthetic_index, row in enumerate(rows):
        parent_font = str(row.get("parentFontFileSHA256", ""))
        label = int(row["vocabularyIndex"])
        if parent_font not in fit_fonts:
            missing_parent.append(parent_font)
            continue
        siblings = [(other_label, row_id) for other_label, row_id in by_font_label[parent_font].items()
                    if other_label != label]
        siblings.sort(key=lambda pair: hashlib.sha256(
            f"{seed}:{synthetic_index}:{pair[0]}:{pair[1]}".encode()).digest())
        for _, sibling_row in siblings[:sibling_limit]:
            score = target_scores(synthetic_images[synthetic_index], font_images[sibling_row])
            pairs.append((offset + synthetic_index, sibling_row, *score.tolist()))
        used_rows += 1
    if missing_parent:
        raise ValueError(f"synthetic rows reference non-fit/unavailable parent fonts: {len(missing_parent)}")
    if not pairs:
        raise ValueError("synthetic font views produced no cross-symbol training pairs")
    return np.asarray(pairs, dtype=np.float32), {
        "syntheticImages": len(rows), "syntheticImagesPaired": used_rows,
        "parentFontFiles": len({str(row["parentFontFileSHA256"]) for row in rows}),
        "pairs": len(pairs), "maxSiblingLabelsPerView": sibling_limit,
        "pairTarget": "recomputed symmetric contour/skeleton overlap against original glyphs in the same fit font",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base-run", type=Path,
                        default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3"))
    parser.add_argument("--font-manifest", type=Path,
                        default=Path("runs/agent-control/cycle622-firebird-mac-font-glyphs.json"))
    parser.add_argument("--font-shapes", type=Path,
                        default=Path("runs/agent-control/cycle630-firebird-pair-overlap-aug-v3/canonical-contour-skeleton.u8"))
    parser.add_argument("--old-synthetic-bank", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/synthetic-font-shapes.u8"))
    parser.add_argument("--old-synthetic-index", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/synthetic-font-shapes.jsonl"))
    parser.add_argument("--new-synthetic-bank", type=Path,
                        default=Path("runs/agent-control/cycle637-synthetic-font-gap-fill-corrected/synthetic-font-gap-variants.u8"))
    parser.add_argument("--new-synthetic-index", type=Path,
                        default=Path("runs/agent-control/cycle637-synthetic-font-gap-fill-corrected/synthetic-font-gap-variants.jsonl"))
    parser.add_argument("--hand-fit-bank", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/handwriting-fit-shapes.u8"))
    parser.add_argument("--hand-fit-index", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/handwriting-fit-shapes.jsonl"))
    parser.add_argument("--hand-valid-bank", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/handwriting-valid-shapes.u8"))
    parser.add_argument("--hand-valid-index", type=Path,
                        default=Path("runs/agent-control/cycle635-font-handwriting-gap-fill/handwriting-valid-shapes.jsonl"))
    parser.add_argument("--teacher-index", type=Path,
                        default=Path("runs/hinotori-raster-holdout-v2-20261103/fold-07/fit-teachers.jsonl"))
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--learning-rate", type=float, default=0.00002)
    parser.add_argument("--sibling-limit", type=int, default=12)
    parser.add_argument("--seed", type=int, default=20261106)
    args = parser.parse_args()

    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite run: {args.output}")
    if args.epochs < 1 or args.learning_rate <= 0 or args.sibling_limit < 1:
        raise ValueError("epochs, learning rate, and sibling limit must be positive")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is required; CPU fallback is prohibited.")

    base_report_bytes = (args.base_run / "training-report.json").read_bytes()
    base_report = json.loads(base_report_bytes)
    manifest_bytes = args.font_manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    font_rows = manifest["rows"]
    if (base_report.get("schema") != "firebird-symmetric-shape-pair-vit-v3"
            or hashlib.sha256(manifest_bytes).hexdigest() != base_report["corpusManifestSHA256"]
            or args.font_shapes.stat().st_size != len(font_rows) * IMAGE_BYTES):
        raise ValueError("base checkpoint, font manifest, and canonical glyph bank provenance disagree")

    hand_fit, hand_fit_rows = load_indexed_bank(args.hand_fit_bank, args.hand_fit_index)
    hand_valid, hand_valid_rows = load_indexed_bank(args.hand_valid_bank, args.hand_valid_index)
    fit_sources = {str(row["sourceSampleId"]) for row in hand_fit_rows}
    valid_sources = {str(row["sourceSampleId"]) for row in hand_valid_rows}
    if fit_sources & valid_sources:
        raise ValueError("handwriting formula-source leakage between fit and inner validation")
    teacher_rows = [json.loads(line) for line in args.teacher_index.read_text(encoding="utf-8").splitlines() if line]
    teacher_fit_sources = {str(row["sourceSampleId"]) for row in teacher_rows}
    if not fit_sources.issubset(teacher_fit_sources) or not valid_sources.issubset(teacher_fit_sources):
        raise ValueError("rasterized hand banks contain source IDs absent from direct teacher index")

    old_synthetic, old_synthetic_rows = load_indexed_bank(args.old_synthetic_bank, args.old_synthetic_index)
    new_synthetic, new_synthetic_rows = load_indexed_bank(args.new_synthetic_bank, args.new_synthetic_index)
    synthetic_rows = old_synthetic_rows + [dict(row, imageIndex=len(old_synthetic_rows) + int(row["imageIndex"]))
                                           for row in new_synthetic_rows]
    synthetic_images = np.concatenate((old_synthetic, new_synthetic), axis=0)
    font_images = np.memmap(args.font_shapes, mode="r", dtype=np.uint8,
                            shape=(len(font_rows), *IMAGE_SHAPE))
    fit_font_set = set(base_report["fitFontFiles"])
    if any(str(row["parentFontFileSHA256"]) not in fit_font_set for row in synthetic_rows):
        raise ValueError("synthetic font variants must be derived only from the model's fit fonts")

    fit_font_hashes = set(base_report["pairTargetFontFiles"])
    train_font_pairs, train_font_counts = font_pair_records(
        font_rows, font_images, sorted(fit_font_hashes), args.seed, 30000, require_positive=True)
    valid_font_pairs, valid_font_counts = font_pair_records(
        font_rows, font_images, base_report["validationFontFiles"], args.seed + 1, 8000,
        require_positive=False)
    if train_font_counts["selectedPairRows"] != base_report["fitPairCounts"]["selectedPairRows"]:
        raise ValueError("reconstructed fit font pairs differ from the base run")
    if valid_font_counts["selectedPairRows"] != base_report["validationPairCounts"]["selectedPairRows"]:
        raise ValueError("reconstructed validation font pairs differ from the base run")
    if set(base_report["fitFontFiles"]) & (set(base_report["validationFontFiles"]) |
                                           set(base_report["generationFontFiles"])):
        raise ValueError("font-file split leakage in base report")

    synthetic_offset = len(font_rows)
    hand_fit_offset = synthetic_offset + len(synthetic_images)
    hand_valid_offset = hand_fit_offset + len(hand_fit)
    synthetic_pairs, synthetic_counts = synthetic_font_pairs(
        synthetic_rows, synthetic_images, font_rows, font_images, synthetic_offset,
        args.seed + 2, args.sibling_limit)
    canonical_hand_fit = canonical_bank(hand_fit)
    canonical_hand_valid = canonical_bank(hand_valid)
    hand_pairs, hand_counts = deterministic_hand_pairs(hand_fit_rows, canonical_hand_fit,
                                                       hand_fit_offset, args.seed + 3)
    hand_valid_pairs, hand_valid_counts = deterministic_hand_pairs(
        hand_valid_rows, canonical_hand_valid, hand_valid_offset, args.seed + 4)
    training_pairs = np.concatenate((train_font_pairs, synthetic_pairs, hand_pairs), axis=0)

    # All inputs remain separate memory-mapped banks; validation examples are indexable only by
    # evaluation records and never appear in the optimizer's pair records.
    corpus = CombinedCorpus([font_images, synthetic_images, canonical_hand_fit, canonical_hand_valid])
    device = torch.device("mps")
    model = PairOverlapViT().to(device)
    checkpoint_path = args.base_run / "firebird-pair-overlap-vit.pt"
    checkpoint_bytes = checkpoint_path.read_bytes()
    base_checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    model.load_state_dict(base_checkpoint["state_dict"], strict=True)
    baseline_font_metrics = evaluate(model, corpus, valid_font_pairs, device)
    baseline_hand_metrics = evaluate(model, corpus, hand_valid_pairs, device)

    args.output.mkdir(parents=True)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-4)
    dataset = PairDataset(corpus, training_pairs, augment=True, seed=args.seed + 5)
    loader = DataLoader(dataset, batch_size=128, shuffle=True, num_workers=0, drop_last=False)
    history: list[dict] = []
    best_epoch: int | None = None
    best_font_mae = float("inf")
    for epoch in range(1, args.epochs + 1):
        dataset.set_epoch(epoch)
        model.train()
        total_loss = 0.0
        seen = 0
        for a, b, target in loader:
            a = a.to(device=device, dtype=torch.float32)
            b = b.to(device=device, dtype=torch.float32)
            target = target.to(device=device, dtype=torch.float32)
            prediction = model(a, b)
            loss = F.smooth_l1_loss(prediction, target)
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            total_loss += float(loss.detach()) * len(target)
            seen += len(target)
        font_metrics = evaluate(model, corpus, valid_font_pairs, device)
        handwriting_metrics = evaluate(model, corpus, hand_valid_pairs, device)
        row = {"epoch": epoch, "fitLoss": total_loss / max(seen, 1),
               "trainingPairCount": seen, "fontInnerValidation": font_metrics,
               "handwritingInnerValidation": handwriting_metrics}
        history.append(row)
        payload = {"state_dict": {k: v.detach().cpu() for k, v in model.state_dict().items()},
                   "architecture": "symmetric-shape-pair-vit-v3",
                   "epoch": epoch, "validationMacroMAE": font_metrics["macroMAE"],
                   "baseCheckpointSHA256": hashlib.sha256(checkpoint_bytes).hexdigest(),
                   "seed": args.seed}
        torch.save(payload, args.output / f"epoch-{epoch:03d}.pt")
        if font_metrics["macroMAE"] < best_font_mae:
            best_font_mae = font_metrics["macroMAE"]
            best_epoch = epoch
            torch.save(payload, args.output / "firebird-pair-overlap-vit.pt")
        print(json.dumps(row, ensure_ascii=False), flush=True)

    if best_epoch is None:
        raise RuntimeError("no epoch was selected from font inner validation")
    report = {
        "schema": "firebird-symmetric-shape-pair-vit-gapfill-v1",
        "baseRun": str(args.base_run),
        "baseCheckpointSHA256": hashlib.sha256(checkpoint_bytes).hexdigest(),
        "baseCheckpointEpoch": int(base_checkpoint.get("epoch", -1)),
        "trainingData": {
            "fontPairs": train_font_counts,
            "syntheticFontPairs": synthetic_counts,
            "handwritingPairs": hand_counts,
            "totalPairs": len(training_pairs),
            "syntheticBankSHA256": [sha256(args.old_synthetic_bank), sha256(args.new_synthetic_bank)],
            "handwritingFitBankSHA256": sha256(args.hand_fit_bank),
            "handwritingFitFormulaSources": len(fit_sources),
            "outerTestOpened": False,
        },
        "validationData": {
            "fontPairs": valid_font_counts,
            "handwritingPairs": hand_valid_counts,
            "handwritingImages": len(hand_valid),
            "handwritingFormulaSources": len(valid_sources),
            "fitInnerSourceOverlap": len(fit_sources & valid_sources),
            "selectionMetric": "font inner-validation macroMAE only; handwriting metrics are reported but do not select epoch",
        },
        "baseline": {"fontInnerValidation": baseline_font_metrics,
                     "handwritingInnerValidation": baseline_hand_metrics},
        "history": history,
        "selectedEpoch": best_epoch,
        "selectedCheckpoint": str(args.output / "firebird-pair-overlap-vit.pt"),
        "selectedFontInnerValidation": history[best_epoch - 1]["fontInnerValidation"],
        "selectedHandwritingInnerValidation": history[best_epoch - 1]["handwritingInnerValidation"],
        "limitation": "Pair labels remain computed raster-overlap targets, not human semantic similarity annotations. Synthetic views do not increase independent font count.",
    }
    report["selectedDeltaVsBaseline"] = {
        "fontMacroMAE": report["selectedFontInnerValidation"]["macroMAE"] - baseline_font_metrics["macroMAE"],
        "handwritingMacroMAE": report["selectedHandwritingInnerValidation"]["macroMAE"] - baseline_hand_metrics["macroMAE"],
    }
    report["checkpointSHA256"] = sha256(args.output / "firebird-pair-overlap-vit.pt")
    (args.output / "training-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                                        encoding="utf-8")
    print(json.dumps({"stage": "complete", "selectedEpoch": best_epoch,
                      "trainingPairs": len(training_pairs),
                      "fontBaselineMacroMAE": baseline_font_metrics["macroMAE"],
                      "fontSelectedMacroMAE": report["selectedFontInnerValidation"]["macroMAE"],
                      "handBaselineMacroMAE": baseline_hand_metrics["macroMAE"],
                      "handSelectedMacroMAE": report["selectedHandwritingInnerValidation"]["macroMAE"],
                      "checkpoint": report["selectedCheckpoint"]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
