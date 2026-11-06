#!/usr/bin/env python3
"""Compare frozen Top-1/Top-5 checkpoints and validation-only score fusion."""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import io
import itertools
import json
import math
import random
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import CLASS_COUNT
from evaluate_hinotori_symbol_holdout import model_for
from train_hinotori_raster_classifier import collate_rasters


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_model(path: Path, device: torch.device, vocabulary: list[str]) -> tuple[torch.nn.Module, dict[str, object], str]:
    raw = path.read_bytes()
    checkpoint = torch.load(io.BytesIO(raw), map_location="cpu", weights_only=False)
    run = checkpoint.get("run", {})
    if run.get("task") != "isolated_symbol_exact_classification" or run.get("classCount") != CLASS_COUNT:
        raise ValueError(f"checkpoint task/class count mismatch: {path}")
    if run.get("classLabelsByIndex") != vocabulary:
        raise ValueError(f"checkpoint vocabulary mismatch: {path}")
    model = model_for(str(run.get("architecture")), device)
    model.load_state_dict(checkpoint["model"])
    model.eval()
    return model, checkpoint, hashlib.sha256(raw).hexdigest()


def collect(model: torch.nn.Module, loader: DataLoader, device: torch.device, embeddings: bool) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor | None, list[str]]:
    all_scores: list[torch.Tensor] = []
    all_labels: list[torch.Tensor] = []
    all_embeddings: list[torch.Tensor] = []
    all_sources: list[str] = []
    with torch.inference_mode():
        for images, labels, sources in loader:
            logits, embedding = model(images.to(device))
            all_scores.append(logits.cpu())
            all_labels.append(labels.cpu())
            all_sources.extend(sources)
            if embeddings:
                all_embeddings.append(embedding.cpu())
    if not all_scores:
        raise ValueError("evaluation split is empty")
    return torch.cat(all_scores), torch.cat(all_labels), torch.cat(all_embeddings) if embeddings else None, all_sources


def fit_prototypes(model: torch.nn.Module, loader: DataLoader, device: torch.device) -> torch.Tensor:
    dimension = int(getattr(model, "embedding_dimension", 128))
    sums = torch.zeros((CLASS_COUNT, dimension), dtype=torch.float32, device=device)
    counts = torch.zeros(CLASS_COUNT, dtype=torch.float32, device=device)
    with torch.inference_mode():
        for images, labels, _ in loader:
            _, embeddings = model(images.to(device))
            labels = labels.to(device)
            sums.index_add_(0, labels, embeddings)
            counts.index_add_(0, labels, torch.ones_like(labels, dtype=torch.float32))
    if (counts == 0).any():
        raise ValueError(f"prototype training split misses class indices: {torch.where(counts == 0)[0].tolist()}")
    return F.normalize(sums / counts[:, None], dim=1).cpu()


def select_temperature(scores: torch.Tensor, labels: torch.Tensor) -> tuple[float, float]:
    candidates = torch.logspace(math.log10(0.03), math.log10(20.0), steps=241, dtype=torch.float64)
    scores = scores.double()
    labels = labels.long()
    best: tuple[float, float] | None = None
    for temperature in candidates.tolist():
        loss = float(F.cross_entropy(scores / temperature, labels).item())
        if best is None or loss < best[1]:
            best = (temperature, loss)
    if best is None:
        raise AssertionError("temperature grid unexpectedly empty")
    return best


def metric(probability: torch.Tensor, labels: torch.Tensor, vocabulary: list[str]) -> dict[str, object]:
    if probability.shape != (labels.numel(), CLASS_COUNT):
        raise ValueError("probability matrix does not match the 229-class task")
    ranked = probability.topk(5, dim=1).indices
    predicted = ranked[:, 0]
    confusion = torch.bincount(labels * CLASS_COUNT + predicted, minlength=CLASS_COUNT**2).reshape(CLASS_COUNT, CLASS_COUNT)
    support = confusion.sum(1)
    observed = support > 0
    errors = Counter((int(gold), int(guess)) for gold, guess in zip(labels.tolist(), predicted.tolist()) if gold != guess)
    return {
        "sampleCount": int(labels.numel()),
        "top1Correct": int((predicted == labels).sum()),
        "top1": float((predicted == labels).double().mean()),
        "top5Correct": int((ranked == labels[:, None]).any(1).sum()),
        "top5": float((ranked == labels[:, None]).any(1).double().mean()),
        "macroRecallObservedClasses": float((confusion.diag()[observed].double() / support[observed]).mean()),
        "observedClasses": int(observed.sum()),
        "unsupportedClassIndices": torch.where(~observed)[0].tolist(),
        "classSupportByIndex": support.tolist(),
        "negativeLogLikelihood": float(F.nll_loss(probability.clamp_min(1e-12).log(), labels).item()),
        "mostFrequentConfusions": [
            {"truthIndex": truth, "truth": vocabulary[truth], "predictionIndex": guess,
             "prediction": vocabulary[guess], "count": count}
            for (truth, guess), count in errors.most_common(50)
        ],
    }


def fuse_on_validation(names: tuple[str, ...], probabilities: dict[str, torch.Tensor], labels: torch.Tensor) -> tuple[tuple[float, ...], float]:
    steps = 20
    best_weights: tuple[float, ...] | None = None
    best_loss = float("inf")
    for allocation in itertools.product(range(steps + 1), repeat=len(names)):
        if sum(allocation) != steps:
            continue
        weights = tuple(value / steps for value in allocation)
        mixture = sum(weight * probabilities[name] for weight, name in zip(weights, names))
        loss = float(F.nll_loss(mixture.clamp_min(1e-12).log(), labels).item())
        if loss < best_loss:
            best_weights, best_loss = weights, loss
    if best_weights is None:
        raise AssertionError("validation simplex search produced no weights")
    return best_weights, best_loss


def source_cluster_intervals(predictions: dict[str, torch.Tensor], labels: torch.Tensor, sources: list[str], seed: int) -> dict[str, dict[str, list[float] | int]]:
    if len(sources) != labels.numel() or any(not source for source in sources):
        raise ValueError("source IDs do not align with outer-test labels")
    grouped: dict[str, list[int]] = {}
    for index, source in enumerate(sources):
        grouped.setdefault(source, []).append(index)
    if len(grouped) < 2:
        raise ValueError("cluster bootstrap requires at least two source formula groups")
    names = tuple(grouped)
    support = {name: len(indices) for name, indices in grouped.items()}
    correct: dict[str, dict[str, tuple[int, int]]] = {}
    for predictor, scores in predictions.items():
        ranked = scores.topk(5, dim=1).indices
        top1 = ranked[:, 0] == labels
        top5 = (ranked == labels[:, None]).any(1)
        correct[predictor] = {
            name: (int(top1[indices].sum()), int(top5[indices].sum()))
            for name, indices in grouped.items()
        }
    rng = random.Random(seed)
    samples: dict[str, list[list[float]]] = {name: [[], []] for name in predictions}
    for _ in range(2000):
        selected = rng.choices(names, k=len(names))
        denominator = sum(support[name] for name in selected)
        if denominator == 0:
            raise AssertionError("empty source bootstrap sample")
        for predictor in predictions:
            top1_count = sum(correct[predictor][name][0] for name in selected)
            top5_count = sum(correct[predictor][name][1] for name in selected)
            samples[predictor][0].append(top1_count / denominator)
            samples[predictor][1].append(top5_count / denominator)
    intervals: dict[str, dict[str, list[float] | int]] = {}
    for predictor, dimensions in samples.items():
        values: dict[str, list[float] | int] = {"sourceGroupCount": len(names)}
        for metric_name, rates in zip(("top1", "top5"), dimensions):
            rates.sort()
            values[metric_name + "95PercentileCI"] = [rates[49], rates[1949]]
        intervals[predictor] = values
    return intervals


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--fit-teachers", type=Path, required=True)
    parser.add_argument("--fit-source-split", type=Path, required=True)
    parser.add_argument("--test-teachers", type=Path, required=True)
    parser.add_argument("--test-source-split", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--cnn-top1-checkpoint", type=Path, required=True)
    parser.add_argument("--cnn-top5-checkpoint", type=Path, required=True)
    parser.add_argument("--hog-top1-checkpoint", type=Path, required=True)
    parser.add_argument("--hog-top5-checkpoint", type=Path, required=True)
    parser.add_argument("--fold-name", default="fold-05")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; CPU fallback is prohibited")
    if args.report.exists():
        raise FileExistsError(f"refusing to overwrite report: {args.report}")

    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary = json.loads(vocabulary_bytes).get("labels")
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain 229 unique labels")
    fit_roles = json.loads(args.fit_source_split.read_text(encoding="utf-8"))["sourceSplit"]
    test_roles = json.loads(args.test_source_split.read_text(encoding="utf-8"))["sourceSplit"]
    if set(fit_roles.values()) != {"train", "valid"} or set(test_roles.values()) != {"valid"}:
        raise ValueError("fit split must contain train/valid roles and outer test must contain valid-role sources")
    train_sources = {source for source, role in fit_roles.items() if role == "train"}
    valid_sources = {source for source, role in fit_roles.items() if role == "valid"}
    test_sources = set(test_roles)
    if train_sources & valid_sources or (train_sources | valid_sources) & test_sources:
        raise ValueError("train, validation, and outer test source groups must be disjoint")

    train = DirectAnchorDataset(args.fit_teachers, args.fit_source_split, args.dataset_root, 128, "train")
    valid = DirectAnchorDataset(args.fit_teachers, args.fit_source_split, args.dataset_root, 128, "valid")
    test = DirectAnchorDataset(args.test_teachers, args.test_source_split, args.dataset_root, 128, "valid")
    if {int(row["classIndex"]) for row in train.rows} != set(range(CLASS_COUNT)):
        raise ValueError("fit-train data must cover all 229 classes")
    if set(str(row["sourceSampleId"]) for row in test.rows) - test_sources:
        raise ValueError("outer-test teacher contains source IDs absent from its source split")
    train_loader = DataLoader(train, batch_size=64, shuffle=False, collate_fn=collate_rasters)
    valid_loader = DataLoader(valid, batch_size=64, shuffle=False, collate_fn=collate_rasters)
    test_loader = DataLoader(test, batch_size=64, shuffle=False, collate_fn=collate_rasters)
    device = torch.device("mps")

    checkpoint_paths = {
        "cnnTop1": args.cnn_top1_checkpoint, "cnnTop5": args.cnn_top5_checkpoint,
        "hogTop1": args.hog_top1_checkpoint, "hogTop5": args.hog_top5_checkpoint,
    }
    models: dict[str, torch.nn.Module] = {}
    checkpoints: dict[str, dict[str, object]] = {}
    checkpoint_hashes: dict[str, str] = {}
    for name, path in checkpoint_paths.items():
        models[name], checkpoints[name], checkpoint_hashes[name] = load_model(path, device, vocabulary)
    if any(checkpoints[name]["run"].get("architecture") != "HinotoriRasterClassifier" for name in ("cnnTop1", "cnnTop5")):
        raise ValueError("CNN checkpoints must be residual raster classifiers")
    if any(checkpoints[name]["run"].get("architecture") != "HinotoriHOGClassifier" for name in ("hogTop1", "hogTop5")):
        raise ValueError("HOG checkpoints must be HOG linear classifiers")

    prototypes = {name: fit_prototypes(models[name], train_loader, device) for name in ("cnnTop1", "cnnTop5")}
    raw_scores: dict[str, dict[str, torch.Tensor]] = {}
    valid_labels: torch.Tensor | None = None
    test_labels: torch.Tensor | None = None
    test_source_ids: list[str] | None = None
    for name, model in models.items():
        valid_logits, observed_valid, valid_embeddings, _ = collect(model, valid_loader, device, name.startswith("cnn"))
        test_logits, observed_test, test_embeddings, observed_sources = collect(model, test_loader, device, name.startswith("cnn"))
        if valid_labels is None:
            valid_labels, test_labels = observed_valid, observed_test
        if not torch.equal(valid_labels, observed_valid) or not torch.equal(test_labels, observed_test):
            raise ValueError("candidate checkpoints produced misaligned labels")
        if test_source_ids is None:
            test_source_ids = observed_sources
        elif test_source_ids != observed_sources:
            raise ValueError("candidate checkpoints produced misaligned source groups")
        raw_scores[name + "Classifier"] = {"valid": valid_logits, "test": test_logits}
        if name.startswith("cnn"):
            if valid_embeddings is None or test_embeddings is None:
                raise AssertionError("CNN embeddings were not collected")
            raw_scores[name + "FitTrainPrototype"] = {
                "valid": F.normalize(valid_embeddings, dim=1) @ prototypes[name].T,
                "test": F.normalize(test_embeddings, dim=1) @ prototypes[name].T,
            }
    if valid_labels is None or test_labels is None or test_source_ids is None:
        raise ValueError("validation or outer test is empty")

    calibrated_valid: dict[str, torch.Tensor] = {}
    calibrated_test: dict[str, torch.Tensor] = {}
    calibration: dict[str, dict[str, object]] = {}
    for name, scores in raw_scores.items():
        temperature, nll = select_temperature(scores["valid"], valid_labels)
        calibrated_valid[name] = torch.softmax(scores["valid"] / temperature, dim=1)
        calibrated_test[name] = torch.softmax(scores["test"] / temperature, dim=1)
        calibration[name] = {"temperature": temperature, "validationNLL": nll,
                             "validationMetrics": metric(calibrated_valid[name], valid_labels, vocabulary)}

    fusion_reports: dict[str, dict[str, object]] = {}
    test_results: dict[str, object] = {}
    test_probabilities: dict[str, torch.Tensor] = {}
    for name, probability in calibrated_test.items():
        test_probabilities[name] = probability
    for criterion, names in (
        ("top1Selected", ("cnnTop1Classifier", "cnnTop1FitTrainPrototype", "hogTop1Classifier")),
        ("top5Selected", ("cnnTop5Classifier", "cnnTop5FitTrainPrototype", "hogTop5Classifier")),
    ):
        weights, nll = fuse_on_validation(names, calibrated_valid, valid_labels)
        valid_fused = sum(weight * calibrated_valid[name] for weight, name in zip(weights, names))
        test_fused = sum(weight * calibrated_test[name] for weight, name in zip(weights, names))
        fused_name = criterion + "Fusion"
        test_probabilities[fused_name] = test_fused
        fusion_reports[criterion] = {
            "components": list(names), "weights": dict(zip(names, weights)),
            "validationNLL": nll, "validationMetrics": metric(valid_fused, valid_labels, vocabulary),
        }
        test_results[fused_name] = metric(test_fused, test_labels, vocabulary)
        for name in names:
            test_results[name] = metric(calibrated_test[name], test_labels, vocabulary)

    report = {
        "task": "229-class isolated direct-symbol recognition",
        "fold": args.fold_name,
        "protocol": "All four checkpoints were frozen using inner-validation Top-1 or Top-5 selection. Per-score temperature and two separate convex mixture weights were selected only on source-disjoint inner validation by NLL. The 500-example outer test was not used in selection.",
        "dataset": {
            "fitTrainSamples": len(train), "innerValidationSamples": len(valid), "outerTestSamples": len(test),
            "fitTrainSources": len(train_sources), "innerValidationSources": len(valid_sources), "outerTestSources": len(test_sources),
            "outerTestObservedClasses": len({int(row["classIndex"]) for row in test.rows}),
            "fitTeacherSHA256": sha256(args.fit_teachers), "fitSourceSplitSHA256": sha256(args.fit_source_split),
            "testTeacherSHA256": sha256(args.test_teachers), "testSourceSplitSHA256": sha256(args.test_source_split),
            "vocabularySHA256": hashlib.sha256(vocabulary_bytes).hexdigest(), "sourceOverlap": 0,
        },
        "checkpoints": {name: {"path": str(path), "epoch": int(checkpoints[name]["epoch"]), "sha256": checkpoint_hashes[name]}
                        for name, path in checkpoint_paths.items()},
        "calibration": calibration,
        "validationFusion": fusion_reports,
        "outerTest": test_results,
        "sourceClusterBootstrap2000": source_cluster_intervals(test_probabilities, test_labels, test_source_ids, seed=20261123),
        "scope": "Isolated symbol classification only. These are not complete formula recognition, position-rule, similarity-neighbour, or ANE measurements.",
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("x", encoding="utf-8") as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(json.dumps({
        "fold": report["fold"],
        "outerTest": {
            name: {key: values[key] for key in ("sampleCount", "top1Correct", "top1", "top5Correct", "top5", "macroRecallObservedClasses", "negativeLogLikelihood")}
            for name, values in test_results.items()
        },
        "selectedWeights": {key: value["weights"] for key, value in fusion_reports.items()},
        "sourceClusterBootstrap2000": report["sourceClusterBootstrap2000"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
