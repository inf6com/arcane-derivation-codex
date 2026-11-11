#!/usr/bin/env python3
"""Calibrate the frozen Fold-07 and typeset candidate heads on inner validation.

This produces the calibration artifact consumed by the app's Hinotori
candidate ensemble. It never reads an outer-test split and never updates either
model checkpoint. Run on the contracted MPS environment.
"""
from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
from pathlib import Path
import sys

import torch
from torch import nn
from torch.nn import functional as F
from torch.utils.data import DataLoader

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ModelConversion"))
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import HinotoriStrokeSetClassifier, rasterize_group
from hinotori_spatial_pyramid import HinotoriSpatialPyramidAngularMargin
from train_hinotori_typeset_auxiliary_head import raster_embeddings


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def temperature_for(logits: torch.Tensor, labels: torch.Tensor) -> tuple[float, float]:
    grid = torch.logspace(math.log10(0.03), math.log10(20.0), steps=481, dtype=torch.float64)
    scores = logits.double()
    targets = labels.long()
    losses = torch.stack([F.cross_entropy(scores / temperature, targets) for temperature in grid])
    index = int(losses.argmin())
    return float(grid[index]), float(losses[index])


def ranking_metrics(scores: torch.Tensor, labels: torch.Tensor) -> dict[str, float | int]:
    indices = scores.topk(5, dim=1).indices
    top1 = indices[:, 0]
    return {
        "top1Correct": int((top1 == labels).sum()),
        "top1": float((top1 == labels).double().mean()),
        "top5Correct": int((indices == labels[:, None]).any(1).sum()),
        "top5": float((indices == labels[:, None]).any(1).double().mean()),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, default=Path("/Volumes/ORICO/Developer/inf6-training/dataset/mathwriting-2024"))
    parser.add_argument("--batch-size", type=int, default=48)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite calibration artifact: {args.output}")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; CPU calibration is prohibited")

    fold_dir = ROOT / "runs/hinotori-raster-holdout-v2-20261103/fold-07"
    fold_checkpoint = ROOT / "runs/hinotori-spatial-pyramid-20261104/fold-07/best-classifier-top1.pt"
    typeset_dir = ROOT / "runs/hinotori-typeset-auxiliary-head-strokeset-verified-20261105"
    base_checkpoint = ROOT / "runs/hinotori-raster-holdout-v2-20261103/fold-07/stroke-set/best.pt"
    head_checkpoint = typeset_dir / "typeset-head-best-top5.pt"
    fold_manifest_path = ROOT / "Models/Hinotori/Fold07SpatialPyramid/HinotoriFold7CoreML.manifest.json"
    typeset_vocab_path = ROOT / "Models/Hinotori/TypesetAuxiliaryHead/HinotoriTypesetVocabulary.json"
    labels_path = ROOT / "Models/Hinotori/Fold07SpatialPyramid/HinotoriFold7Vocabulary.json"
    required = (fold_checkpoint, base_checkpoint, head_checkpoint, fold_manifest_path, typeset_vocab_path, labels_path,
                fold_dir / "fit-teachers.jsonl", fold_dir / "stroke-set-source-split.json", args.mathwriting_root / "train")
    for path in required:
        if not path.exists():
            raise FileNotFoundError(path)

    device = torch.device("mps")
    fold_bytes = fold_checkpoint.read_bytes()
    fold_state = torch.load(fold_checkpoint, map_location="cpu", weights_only=False)
    fold_manifest = json.loads(fold_manifest_path.read_text(encoding="utf-8"))
    vocabulary = json.loads(labels_path.read_text(encoding="utf-8"))["labels"]
    if len(vocabulary) != 229 or len(set(vocabulary)) != 229:
        raise ValueError("Fold-07 vocabulary must contain 229 unique labels")
    if hashlib.sha256(fold_bytes).hexdigest() != fold_manifest["checkpoint"]["sha256"]:
        raise ValueError("Fold-07 checkpoint differs from the app manifest")
    if fold_state["epoch"] != fold_manifest["checkpoint"]["epoch"]:
        raise ValueError("Fold-07 checkpoint epoch differs from the app manifest")

    base_bytes = base_checkpoint.read_bytes()
    head_bytes = head_checkpoint.read_bytes()
    typeset_vocab = json.loads(typeset_vocab_path.read_text(encoding="utf-8"))
    supported = [int(value) for value in typeset_vocab["supportedVocabularyIndices"]]
    if len(supported) != 222 or len(set(supported)) != 222 or not set(supported).issubset(range(229)):
        raise ValueError("typeset head must map 222 distinct indices into the 229-label vocabulary")
    base_state = torch.load(base_checkpoint, map_location="cpu", weights_only=False)
    head_state = torch.load(head_checkpoint, map_location="cpu", weights_only=False)
    if head_state["baseCheckpointSHA256"] != hashlib.sha256(base_bytes).hexdigest():
        raise ValueError("typeset head was trained from a different frozen raster encoder")
    if head_state["state_dict"].get("weight", torch.empty(0)).shape != (222, 128):
        raise ValueError("typeset auxiliary head must have shape [222,128]")
    if head_state["supportedVocabularyIndices"] != supported:
        raise ValueError("typeset head and bundled vocabulary order differ")

    dataset = DirectAnchorDataset(
        fold_dir / "fit-teachers.jsonl", fold_dir / "stroke-set-source-split.json",
        args.mathwriting_root, 128, "valid"
    )
    source_split = json.loads((fold_dir / "stroke-set-source-split.json").read_text(encoding="utf-8"))["sourceSplit"]
    if any(source_split[row["sourceSampleId"]] != "valid" for row in dataset.rows):
        raise ValueError("calibration set includes a non-validation source")

    fold_model = HinotoriSpatialPyramidAngularMargin().eval()
    fold_model.load_state_dict(fold_state["model"], strict=True)
    fold_model.to(device)
    base_model = HinotoriStrokeSetClassifier().eval()
    base_model.load_state_dict(base_state["model"], strict=True)
    base_model.to(device)
    auxiliary_head = nn.Linear(128, 222)
    auxiliary_head.load_state_dict(head_state["state_dict"], strict=True)
    auxiliary_head.to(device).eval()

    fold_logits: list[torch.Tensor] = []
    typeset_logits: list[torch.Tensor] = []
    targets: list[int] = []
    source_ids: list[str] = []
    for start in range(0, len(dataset), args.batch_size):
        samples = [dataset[index] for index in range(start, min(start + args.batch_size, len(dataset)))]
        images = torch.stack([rasterize_group(sample["points"]) for sample in samples]).to(device)
        labels = torch.tensor([int(sample["classIndex"]) for sample in samples], dtype=torch.long, device=device)
        with torch.inference_mode():
            embeddings = fold_model.encode(images)
            primary = fold_model.cosine_logits(embeddings)
            type_features = raster_embeddings(base_model, images)
            local_typeset = auxiliary_head(type_features)
        fold_logits.append(primary.float().cpu())
        typeset_logits.append(local_typeset.float().cpu())
        targets.extend(labels.cpu().tolist())
        source_ids.extend(str(sample["sourceSampleId"]) for sample in samples)

    fold_scores = torch.cat(fold_logits)
    local_typeset_scores = torch.cat(typeset_logits)
    labels = torch.tensor(targets, dtype=torch.long)
    fold_temperature, fold_nll = temperature_for(fold_scores, labels)
    typeset_targets_by_global = {global_index: local_index for local_index, global_index in enumerate(supported)}
    supported_mask = torch.tensor([int(label) in typeset_targets_by_global for label in labels], dtype=torch.bool)
    local_targets = torch.tensor([typeset_targets_by_global[int(label)] for label in labels[supported_mask]], dtype=torch.long)
    typeset_temperature, typeset_nll = temperature_for(local_typeset_scores[supported_mask], local_targets)

    fold_probabilities = F.softmax(fold_scores.double() / fold_temperature, dim=1)
    local_typeset_probabilities = F.softmax(local_typeset_scores.double() / typeset_temperature, dim=1)
    typeset_probabilities = torch.zeros_like(fold_probabilities)
    typeset_probabilities[:, supported] = local_typeset_probabilities
    best_weight = None
    best_nll = float("inf")
    for fold_weight in torch.linspace(0, 1, 1001, dtype=torch.float64).tolist():
        mixture = fold_weight * fold_probabilities + (1 - fold_weight) * typeset_probabilities
        loss = float(F.nll_loss(mixture.clamp_min(1e-15).log(), labels))
        if loss < best_nll:
            best_weight, best_nll = fold_weight, loss
    if best_weight is None:
        raise RuntimeError("ensemble mixture calibration did not produce a weight")
    fused = best_weight * fold_probabilities + (1 - best_weight) * typeset_probabilities

    outer_test_path = fold_dir / "test-teachers.jsonl"
    if not outer_test_path.is_file():
        raise FileNotFoundError(outer_test_path)
    outer_test = json.loads((fold_dir / "test-source-split.json").read_text(encoding="utf-8"))["sourceSplit"]
    valid_sources = set(source_ids)
    if valid_sources.intersection(outer_test):
        raise ValueError("inner-validation and outer-test source IDs overlap")

    report = {
        "schema": "hinotori-candidate-ensemble-calibration-v1",
        "ensembleName": "Hinotori Candidate Ensemble",
        "task": "229-class isolated handwritten symbol candidate ranking",
        "calibration": {
            "method": "temperature-calibrated softmax probability mixture; weights selected by validation negative log likelihood",
            "fold7CheckpointSHA256": sha256(fold_checkpoint),
            "typesetBaseCheckpointSHA256": sha256(base_checkpoint),
            "typesetHeadCheckpointSHA256": sha256(head_checkpoint),
            "fold7Temperature": fold_temperature,
            "typesetTemperature": typeset_temperature,
            "fold7Weight": best_weight,
            "typesetWeight": 1 - best_weight,
            "sourceSplitSHA256": sha256(fold_dir / "stroke-set-source-split.json"),
            "teacherSHA256": sha256(fold_dir / "fit-teachers.jsonl"),
            "vocabularySHA256": sha256(labels_path),
            "typesetSupportedClassIndices": supported,
        },
        "innerValidation": {
            "sampleCount": len(targets),
            "sourceCount": len(valid_sources),
            "sourceIDs": sorted(valid_sources),
            "fold7NLLAtTemperature": fold_nll,
            "typesetNLLOnSupportedExamplesAtTemperature": typeset_nll,
            "fold7": ranking_metrics(fold_scores, labels),
            "typesetSupported": ranking_metrics(local_typeset_scores[supported_mask], local_targets),
            "unionTop10Recall": float(((fold_scores.topk(5, dim=1).indices == labels[:, None]).any(1) | (torch.tensor(supported)[local_typeset_scores.topk(5, dim=1).indices] == labels[:, None]).any(1)).double().mean()),
            "ensemble": ranking_metrics(fused, labels),
            "ensembleNLL": best_nll,
        },
        "outerTest": {"opened": False, "sourceSplitSHA256": sha256(fold_dir / "test-source-split.json")},
        "provenance": {
            "fold7ModelName": "Hinotori Fold-07 spatial-pyramid handwritten classifier",
            "typesetModelName": "Hinotori typeset auxiliary classifier",
            "typesetUnsupportedLabels": [vocabulary[index] for index in range(229) if index not in set(supported)],
            "device": "MPS",
            "torchVersion": torch.__version__,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "innerValidation": report["innerValidation"], "calibration": report["calibration"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
