#!/usr/bin/env python3
"""Compare frozen 229-symbol raster and stroke-geometry models on one holdout."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import io
import json
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from hinotori_direct_dataset import DirectAnchorDataset, collate_direct_anchors
from hinotori_hog_classifier import HinotoriHOGClassifier
from hinotori_raster_classifier import CLASS_COUNT, HinotoriRasterClassifier
from hinotori_stroke_geometry_classifier import HinotoriStrokeGeometryClassifier
from train_hinotori_raster_classifier import collate_rasters


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def model_for(architecture: str, device: torch.device) -> torch.nn.Module:
    if architecture == "HinotoriRasterClassifier":
        return HinotoriRasterClassifier().to(device)
    if architecture == "HinotoriStrokeGeometryClassifier":
        return HinotoriStrokeGeometryClassifier().to(device)
    if architecture == "HinotoriHOGClassifier":
        return HinotoriHOGClassifier().to(device)
    raise ValueError(f"unsupported checkpoint architecture: {architecture}")


def infer(model: torch.nn.Module, batch: dict[str, object] | tuple[torch.Tensor, torch.Tensor, list[str]], device: torch.device) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    if isinstance(batch, tuple):
        images, labels, _ = batch
        logits, embeddings = model(images.to(device))
        return logits, embeddings, labels
    points = batch["points"].to(device)
    stroke_padding = batch["strokePadding"].to(device)
    point_padding = batch["pointPadding"].to(device)
    logits, embeddings = model(points, stroke_padding, point_padding)
    return logits, embeddings, batch["classIndices"]


def metrics(scores: torch.Tensor, labels: torch.Tensor, vocabulary: list[str]) -> dict[str, object]:
    if scores.ndim != 2 or scores.shape != (labels.numel(), CLASS_COUNT):
        raise ValueError("scores do not satisfy the 229-class contract")
    top = scores.topk(5, dim=1).indices
    predicted = top[:, 0]
    confusion = torch.bincount(labels * CLASS_COUNT + predicted, minlength=CLASS_COUNT**2).reshape(CLASS_COUNT, CLASS_COUNT)
    support = confusion.sum(1)
    observed = support > 0
    recall = confusion.diag()[observed].double() / support[observed]
    errors = Counter((int(gold), int(guess)) for gold, guess in zip(labels.tolist(), predicted.tolist()) if gold != guess)
    return {
        "sampleCount": int(labels.numel()),
        "top1Correct": int((predicted == labels).sum()),
        "top1": float((predicted == labels).double().mean()),
        "top5Correct": int((top == labels[:, None]).any(1).sum()),
        "top5": float((top == labels[:, None]).any(1).double().mean()),
        "macroRecallObservedClasses": float(recall.mean()),
        "observedTestClasses": int(observed.sum()),
        "unsupportedClasses": torch.where(~observed)[0].tolist(),
        "classSupport": support.tolist(),
        "confusionMatrix": confusion.tolist(),
        "mostFrequentConfusions": [
            {"truthIndex": a, "truth": vocabulary[a], "predictionIndex": b,
             "prediction": vocabulary[b], "count": n}
            for (a, b), n in errors.most_common(50)
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--fit-teachers", type=Path, required=True)
    parser.add_argument("--fit-source-split", type=Path, required=True)
    parser.add_argument("--test-teachers", type=Path, required=True)
    parser.add_argument("--test-source-split", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--checkpoint-dir", type=Path, action="append", required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for this evaluation")
    if args.report.exists():
        raise FileExistsError(f"refusing to overwrite evaluation report: {args.report}")
    vocab_doc = json.loads(args.vocabulary.read_text(encoding="utf-8"))
    vocabulary = vocab_doc.get("labels") if isinstance(vocab_doc, dict) else None
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain exactly 229 unique ordered labels")

    fit_map = json.loads(args.fit_source_split.read_text(encoding="utf-8"))["sourceSplit"]
    test_map = json.loads(args.test_source_split.read_text(encoding="utf-8"))["sourceSplit"]
    fit_sources = {s for s, role in fit_map.items() if role == "train"}
    inner_sources = {s for s, role in fit_map.items() if role == "valid"}
    test_sources = set(test_map)
    if fit_sources & inner_sources or (fit_sources | inner_sources) & test_sources:
        raise ValueError("fit train, inner validation, and outer-test source IDs must be disjoint")
    train = DirectAnchorDataset(args.fit_teachers, args.fit_source_split, args.dataset_root, 128, "train")
    test = DirectAnchorDataset(args.test_teachers, args.test_source_split, args.dataset_root, 128, "valid")
    if {int(row["classIndex"]) for row in train.rows} != set(range(CLASS_COUNT)):
        raise ValueError("fit train must cover all 229 classes")
    device = torch.device("mps")
    data_by_kind = {
        "raster": {
            "train": DataLoader(train, batch_size=128, shuffle=False, collate_fn=collate_rasters),
            "test": DataLoader(test, batch_size=128, shuffle=False, collate_fn=collate_rasters),
        },
        "geometry": {
            "train": DataLoader(train, batch_size=64, shuffle=False, collate_fn=collate_direct_anchors),
            "test": DataLoader(test, batch_size=64, shuffle=False, collate_fn=collate_direct_anchors),
        },
    }
    models: dict[str, object] = {}
    for directory in args.checkpoint_dir:
        family: dict[str, object] = {}
        for filename in ("best.pt", "best-top5.pt"):
            checkpoint_path = directory / filename
            raw = checkpoint_path.read_bytes()
            checkpoint = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=False)
            metadata = checkpoint.get("run", {})
            architecture = metadata.get("architecture")
            if metadata.get("task") != "isolated_symbol_exact_classification":
                raise ValueError(f"checkpoint task mismatch: {checkpoint_path}")
            kind = "raster" if architecture in {"HinotoriRasterClassifier", "HinotoriHOGClassifier"} else "geometry" if architecture == "HinotoriStrokeGeometryClassifier" else None
            if kind is None:
                raise ValueError(f"unsupported architecture in {checkpoint_path}: {architecture}")
            model = model_for(architecture, device)
            model.load_state_dict(checkpoint["model"])
            model.eval()

            embedding_dimension = int(getattr(model, "embedding_dimension", 128))
            prototype_sum = torch.zeros((CLASS_COUNT, embedding_dimension), dtype=torch.float32, device=device)
            prototype_count = torch.zeros(CLASS_COUNT, dtype=torch.float32, device=device)
            with torch.inference_mode():
                for batch in data_by_kind[kind]["train"]:
                    _, embeddings, labels = infer(model, batch, device)
                    labels = labels.to(device)
                    prototype_sum.index_add_(0, labels, embeddings)
                    prototype_count.index_add_(0, labels, torch.ones_like(labels, dtype=torch.float32))
                prototypes = F.normalize(prototype_sum / prototype_count[:, None], p=2, dim=1)

                logits_all, embeddings_all, labels_all = [], [], []
                for batch in data_by_kind[kind]["test"]:
                    logits, embeddings, labels = infer(model, batch, device)
                    logits_all.append(logits.cpu())
                    embeddings_all.append(embeddings.cpu())
                    labels_all.append(labels.cpu())
            logits = torch.cat(logits_all)
            embeddings = torch.cat(embeddings_all)
            labels = torch.cat(labels_all)
            prototype_scores = F.normalize(embeddings, p=2, dim=1).to(device) @ prototypes.T
            family[filename] = {
                "architecture": architecture,
                "selectedEpoch": int(checkpoint["epoch"]),
                "checkpointSHA256": hashlib.sha256(raw).hexdigest(),
                "methods": {
                    "classifier": metrics(logits, labels, vocabulary),
                    "fitTrainPrototypeCosine": metrics(prototype_scores.cpu(), labels, vocabulary),
                },
            }
        models[directory.name] = family
    report = {
        "task": "229-class isolated direct-symbol recognition",
        "fold": "fold-04",
        "protocol": "source-grouped outer holdout; checkpoints selected using inner validation; all model checkpoints frozen before outer-test evaluation; no test score selection.",
        "dataset": {
            "fitTrainSources": len(fit_sources), "innerValidationSources": len(inner_sources),
            "outerTestSources": len(test_sources), "sourceOverlap": 0,
            "prototypeSamples": len(train), "outerTestSamples": len(test),
            "testObservedClasses": len({int(row["classIndex"]) for row in test.rows}),
            "testTeacherSHA256": sha256(args.test_teachers),
            "testSourceSplitSHA256": sha256(args.test_source_split),
            "vocabularySHA256": sha256(args.vocabulary),
            "prototypeRule": "per-checkpoint fit-train embeddings only; inner validation and outer test excluded",
        },
        "models": models,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("x", encoding="utf-8") as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
