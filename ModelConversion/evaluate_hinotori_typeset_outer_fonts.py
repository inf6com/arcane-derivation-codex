#!/usr/bin/env python3
"""Evaluate the frozen Hinotori typeset head on untouched font files using MPS."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ModelConversion"))
from hinotori_raster_classifier import HinotoriStrokeSetClassifier
from train_hinotori_typeset_auxiliary_head import FontBank, raster_embeddings


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def metrics(rows: list[dict], predictions: np.ndarray, labels: np.ndarray,
            font_hashes: list[str], class_indices: list[int], seed: int) -> dict:
    top1 = predictions[:, 0] == labels
    top5 = (predictions[:, :5] == labels[:, None]).any(axis=1)
    per_class = {}
    for class_index in sorted(set(labels.tolist())):
        selected = labels == class_index
        per_class[str(class_index)] = float(top1[selected].mean())
    per_font = {}
    for font_hash in sorted(set(font_hashes)):
        selected = np.asarray(font_hashes) == font_hash
        per_font[font_hash] = {
            "examples": int(selected.sum()),
            "top1": float(top1[selected].mean()),
            "top5": float(top5[selected].mean()),
        }

    # Font-cluster bootstrap preserves within-font dependence.
    rng = np.random.default_rng(seed)
    groups = [np.flatnonzero(np.asarray(font_hashes) == key) for key in sorted(per_font)]
    boot = np.empty((10_000, 2), dtype=np.float64)
    for index in range(len(boot)):
        sampled = rng.integers(0, len(groups), size=len(groups))
        selected = np.concatenate([groups[group] for group in sampled])
        boot[index] = (top1[selected].mean(), top5[selected].mean())
    ci = np.quantile(boot, [0.025, 0.975], axis=0)
    observed_classes = sorted(set(labels.tolist()))
    return {
        "examples": int(len(labels)),
        "fontFiles": len(per_font),
        "vocabularyClasses": len(class_indices),
        "observedClasses": len(observed_classes),
        "classesWithoutOuterExamples": len(class_indices) - len(observed_classes),
        "top1Micro": float(top1.mean()),
        "top5Micro": float(top5.mean()),
        "top1MacroObservedClasses": float(np.mean([per_class[str(i)] for i in observed_classes])),
        "top1MacroFonts": float(np.mean([row["top1"] for row in per_font.values()])),
        "top5MacroFonts": float(np.mean([row["top5"] for row in per_font.values()])),
        "fontClusterBootstrap95CI": {
            "top1Micro": [float(ci[0, 0]), float(ci[1, 0])],
            "top5Micro": [float(ci[0, 1]), float(ci[1, 1])],
            "replicates": len(boot),
            "seed": seed,
        },
        "perFont": per_font,
        "perObservedClassTop1": per_class,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20261106)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite evaluation artifact: {args.output}")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is unavailable; refusing CPU evaluation")

    device = torch.device("mps")
    manifest_path = ROOT / "runs/agent-control/cycle622-firebird-mac-font-glyphs.json"
    bank_path = ROOT / "runs/agent-control/cycle622-firebird-mac-font-glyphs.u8"
    split_path = ROOT / "runs/hinotori-typeset-auxiliary-head-strokeset-verified-20261105/font-split.json"
    metrics_path = ROOT / "runs/hinotori-typeset-auxiliary-head-strokeset-verified-20261105/metrics.json"
    head_path = ROOT / "runs/hinotori-typeset-auxiliary-head-strokeset-verified-20261105/typeset-head-best-top1.pt"
    base_path = ROOT / "runs/hinotori-raster-holdout-v2-20261103/fold-07/stroke-set/best.pt"
    vocabulary_path = ROOT / "Models/Hinotori/TypesetAuxiliaryHead/HinotoriTypesetVocabulary.json"
    paths = (manifest_path, bank_path, split_path, metrics_path, head_path, base_path, vocabulary_path)
    for path in paths:
        if not path.is_file():
            raise FileNotFoundError(path)

    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    split = json.loads(split_path.read_text(encoding="utf-8"))
    prior = json.loads(metrics_path.read_text(encoding="utf-8"))
    vocabulary = json.loads(vocabulary_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != "firebird-mac-font-glyph-raster-v1":
        raise ValueError("unexpected font corpus schema")
    if split.get("corpusManifestSHA256") != sha256(manifest_path):
        raise ValueError("font partition belongs to another corpus manifest")
    fit_hashes = set(split["fitFontFileSHA256"])
    validation_hashes = set(split["validationFontFileSHA256"])
    eligible = [row for row in manifest["rows"] if row.get("kind") == "unicode-glyph"]
    all_hashes = {row["fontFileSHA256"] for row in eligible}
    outer_hashes = all_hashes - fit_hashes - validation_hashes
    if fit_hashes & validation_hashes or fit_hashes & outer_hashes or validation_hashes & outer_hashes:
        raise ValueError("font-file partitions overlap")
    if len(fit_hashes) != 202 or len(validation_hashes) != 10 or len(outer_hashes) != 40:
        raise ValueError(f"unexpected partition sizes fit={len(fit_hashes)} validation={len(validation_hashes)} outer={len(outer_hashes)}")
    if len(manifest["rows"]) != int(manifest["renderedImageCount"]):
        raise ValueError("manifest row count mismatch")
    if bank_path.stat().st_size != len(manifest["rows"]) * 64 * 64:
        raise ValueError("font raster bank size mismatch")
    if len(vocabulary["labels"]) != 222:
        raise ValueError("bundled vocabulary is not the trained 222-class vocabulary")
    supported_indices = [int(value) for value in vocabulary["supportedVocabularyIndices"]]

    head_checkpoint = torch.load(head_path, map_location="cpu", weights_only=False)
    if head_checkpoint.get("baseCheckpointSHA256") != sha256(base_path):
        raise ValueError("auxiliary head was trained against a different Fold7 checkpoint")
    if head_checkpoint.get("fontManifestSHA256") != sha256(manifest_path):
        raise ValueError("auxiliary head was trained against a different font corpus")
    if set(head_checkpoint["fitFontHashes"]) != fit_hashes or set(head_checkpoint["validationFontHashes"]) != validation_hashes:
        raise ValueError("saved training split does not match the head checkpoint")
    if head_checkpoint["supportedVocabularyIndices"] != supported_indices:
        raise ValueError("model vocabulary differs from packaged vocabulary")
    if head_checkpoint.get("primaryModelParametersUpdated") is not False:
        raise ValueError("expected a frozen-base auxiliary head")

    model_checkpoint = torch.load(base_path, map_location="cpu", weights_only=False)
    model = HinotoriStrokeSetClassifier().to(device)
    model.load_state_dict(model_checkpoint["model"], strict=True)
    model.eval()
    for parameter in model.parameters():
        parameter.requires_grad_(False)
    head = nn.Linear(128, len(supported_indices)).to(device)
    head.load_state_dict(head_checkpoint["state_dict"], strict=True)
    head.eval()

    dataset = FontBank(eligible, bank_path, len(manifest["rows"]), outer_hashes, "outer")
    loader = DataLoader(dataset, batch_size=512, shuffle=False, num_workers=0)
    predicted_local: list[np.ndarray] = []
    observed_labels: list[np.ndarray] = []
    local_to_global = torch.tensor(supported_indices, dtype=torch.long, device=device)
    with torch.inference_mode():
        for images, labels in loader:
            embeddings = raster_embeddings(model, images.to(device)).float()
            logits = head(embeddings)
            local_top5 = logits.topk(5, dim=1).indices
            predicted_local.append(local_to_global[local_top5].cpu().numpy())
            observed_labels.append(labels.numpy())
    predictions = np.concatenate(predicted_local)
    labels = np.concatenate(observed_labels).astype(np.int64)
    expected_labels = np.asarray([int(row["vocabularyIndex"]) for row in dataset.rows], dtype=np.int64)
    font_hashes = [row["fontFileSHA256"] for row in dataset.rows]
    if not np.array_equal(labels, expected_labels):
        raise RuntimeError("evaluation loader changed sample order or labels")
    unsupported = ~np.isin(labels, np.asarray(supported_indices))
    if unsupported.any():
        raise ValueError(f"outer split contains {int(unsupported.sum())} labels unsupported by the trained head")
    torch.mps.synchronize()

    result = {
        "schema": "hinotori-typeset-outer-font-evaluation-v1",
        "result": "measured",
        "checkpointSHA256": sha256(head_path),
        "baseCheckpointSHA256": sha256(base_path),
        "fontManifestSHA256": sha256(manifest_path),
        "trainingSelectionValidation": {
            "top1": prior["heldOutFonts"]["top1"],
            "top5": prior["heldOutFonts"]["top5"],
            "fontFiles": prior["heldOutFonts"]["distinctFontFiles"],
        },
        "outerTest": metrics(dataset.rows, predictions, labels, font_hashes,
                             supported_indices, args.seed),
        "protocol": {
            "device": "mps",
            "fontFileDisjointFromFitAndSelection": True,
            "fitFontFiles": len(fit_hashes),
            "selectionFontFiles": len(validation_hashes),
            "outerFontFiles": len(outer_hashes),
            "outerFontsUsedForTrainingOrModelSelection": False,
            "unsupportedGlyphsExcludedBeforeEvaluation": False,
            "checkpointChanged": False,
            "seed": args.seed,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"outerTest": result["outerTest"], "protocol": result["protocol"]}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
