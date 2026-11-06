#!/usr/bin/env python3
"""Evaluate frozen raster checkpoints on one source-group outer holdout."""
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

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import CLASS_COUNT, HinotoriRasterClassifier, rasterize_group
from train_hinotori_raster_classifier import collate_rasters


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(model: HinotoriRasterClassifier, loader: DataLoader, device: torch.device) -> tuple[torch.Tensor, torch.Tensor]:
    model.eval()
    embeddings, labels = [], []
    with torch.inference_mode():
        for images, batch_labels, _ in loader:
            _, representation = model(images.to(device))
            embeddings.append(representation.cpu())
            labels.append(batch_labels.cpu())
    if not embeddings:
        raise ValueError("evaluation dataset is empty")
    return torch.cat(embeddings), torch.cat(labels)


def metrics(scores: torch.Tensor, labels: torch.Tensor, vocabulary: list[str]) -> dict[str, object]:
    if scores.ndim != 2 or scores.shape != (labels.numel(), CLASS_COUNT):
        raise ValueError("score matrix does not match the 229-class evaluation contract")
    top = scores.topk(5, dim=1).indices
    pred = top[:, 0]
    confusion = torch.zeros((CLASS_COUNT, CLASS_COUNT), dtype=torch.int64)
    confusion += torch.bincount(labels * CLASS_COUNT + pred, minlength=CLASS_COUNT**2).reshape(CLASS_COUNT, CLASS_COUNT)
    support = confusion.sum(1)
    present = support > 0
    recalls = confusion.diag()[present].double() / support[present]
    errors = Counter((int(gold), int(guess)) for gold, guess in zip(labels.tolist(), pred.tolist()) if gold != guess)
    return {
        "sampleCount": int(labels.numel()),
        "top1Correct": int((pred == labels).sum()),
        "top1": float((pred == labels).double().mean()),
        "top5Correct": int((top == labels[:, None]).any(1).sum()),
        "top5": float((top == labels[:, None]).any(1).double().mean()),
        "macroRecallObservedClasses": float(recalls.mean()),
        "observedTestClasses": int(present.sum()),
        "unsupportedClasses": torch.where(~present)[0].tolist(),
        "classSupport": support.tolist(),
        "confusionMatrix": confusion.tolist(),
        "mostFrequentConfusions": [
            {"truthIndex": a, "truth": vocabulary[a], "predictionIndex": b,
             "prediction": vocabulary[b], "count": count}
            for (a, b), count in errors.most_common(50)
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
    parser.add_argument("--checkpoint-dir", type=Path, action="append", required=True,
                        help="Repeat for each frozen model directory; evaluates best.pt and best-top5.pt.")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for this evaluation run")
    if args.report.exists():
        raise FileExistsError(f"refusing to overwrite evaluation report: {args.report}")
    vocab_doc = json.loads(args.vocabulary.read_text(encoding="utf-8"))
    vocabulary = vocab_doc.get("labels") if isinstance(vocab_doc, dict) else None
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain 229 unique ordered labels")

    fit_split = json.loads(args.fit_source_split.read_text(encoding="utf-8"))["sourceSplit"]
    test_split = json.loads(args.test_source_split.read_text(encoding="utf-8"))["sourceSplit"]
    fit_sources = {source for source, role in fit_split.items() if role == "train"}
    fit_valid_sources = {source for source, role in fit_split.items() if role == "valid"}
    test_sources = set(test_split)
    if fit_sources & fit_valid_sources or (fit_sources | fit_valid_sources) & test_sources:
        raise ValueError("fit, inner-valid, and outer-test source identifiers must be disjoint")
    train_data = DirectAnchorDataset(args.fit_teachers, args.fit_source_split, args.dataset_root, 128, "train")
    test_data = DirectAnchorDataset(args.test_teachers, args.test_source_split, args.dataset_root, 128, "valid")
    train_source_ids = {str(row["sourceSampleId"]) for row in train_data.rows}
    test_source_ids = {str(row["sourceSampleId"]) for row in test_data.rows}
    if train_source_ids & test_source_ids:
        raise ValueError("prototype source set overlaps outer test")
    if {int(row["classIndex"]) for row in train_data.rows} != set(range(CLASS_COUNT)):
        raise ValueError("prototype training data must cover all 229 classes")

    device = torch.device("mps")
    train_loader = DataLoader(train_data, batch_size=128, shuffle=False, collate_fn=collate_rasters)
    test_loader = DataLoader(test_data, batch_size=128, shuffle=False, collate_fn=collate_rasters)
    all_models: dict[str, object] = {}
    for directory in args.checkpoint_dir:
        if not directory.is_dir():
            raise FileNotFoundError(f"checkpoint directory does not exist: {directory}")
        family: dict[str, object] = {}
        for filename in ("best.pt", "best-top5.pt"):
            path = directory / filename
            if not path.is_file():
                raise FileNotFoundError(f"frozen checkpoint missing: {path}")
            raw = path.read_bytes()
            checkpoint = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=False)
            metadata = checkpoint.get("run", {})
            if metadata.get("architecture") != "HinotoriRasterClassifier" or metadata.get("task") != "isolated_symbol_exact_classification":
                raise ValueError(f"checkpoint contract mismatch: {path}")
            model = HinotoriRasterClassifier().to(device)
            model.load_state_dict(checkpoint["model"])
            # Each checkpoint gets its own class prototypes, derived solely
            # from that checkpoint's fit-train embeddings.
            prototype_sum = torch.zeros((CLASS_COUNT, 128), dtype=torch.float32, device=device)
            prototype_count = torch.zeros(CLASS_COUNT, dtype=torch.float32, device=device)
            with torch.inference_mode():
                for images, labels, _ in train_loader:
                    _, z = model(images.to(device))
                    labels = labels.to(device)
                    prototype_sum.index_add_(0, labels, z)
                    prototype_count.index_add_(0, labels, torch.ones_like(labels, dtype=torch.float32))
            prototypes = F.normalize(prototype_sum / prototype_count[:, None], p=2, dim=1)
            test_embeddings = []
            test_labels = []
            logits_batches = []
            model.eval()
            with torch.inference_mode():
                for images, labels, _ in test_loader:
                    logits, z = model(images.to(device))
                    logits_batches.append(logits.cpu())
                    test_embeddings.append(z.cpu())
                    test_labels.append(labels)
            logits = torch.cat(logits_batches)
            embeddings = torch.cat(test_embeddings)
            labels = torch.cat(test_labels)
            proto_scores = F.normalize(embeddings, p=2, dim=1).to(device) @ prototypes.T
            family[filename] = {
                "selectedEpoch": int(checkpoint["epoch"]),
                "checkpointSHA256": hashlib.sha256(raw).hexdigest(),
                "methods": {
                    "classifier": metrics(logits, labels, vocabulary),
                    "trainOnlyPrototypeCosine": metrics(proto_scores.cpu(), labels, vocabulary),
                },
            }
        all_models[directory.name] = family

    report = {
        "task": "229-class isolated direct-symbol recognition",
        "fold": "fold-03",
        "protocol": "Source-grouped outer test disjoint from fold-01 and fold-02 tests; checkpoint selection uses inner validation; test evaluated only after all checkpoints froze.",
        "dataset": {
            "fitTrainSourceCount": len(fit_sources),
            "fitInnerValidationSourceCount": len(fit_valid_sources),
            "outerTestSourceCount": len(test_sources),
            "fitTestSourceOverlap": len((fit_sources | fit_valid_sources) & test_sources),
            "testTeachersSHA256": sha256(args.test_teachers),
            "testSourceSplitSHA256": sha256(args.test_source_split),
            "vocabularySHA256": sha256(args.vocabulary),
            "prototypeFitSamples": len(train_data),
            "outerTestSamples": len(test_data),
            "outerTestObservedClasses": len({int(row["classIndex"]) for row in test_data.rows}),
            "prototypeSourceRole": "fit train only; inner validation and outer test excluded",
        },
        "models": all_models,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("x", encoding="utf-8") as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
        output.write("\n")


if __name__ == "__main__":
    main()
