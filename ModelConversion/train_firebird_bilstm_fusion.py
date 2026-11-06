#!/usr/bin/env python3
"""Train/evaluate Firebird raster + direction-symmetrized stroke BiLSTM."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from pathlib import Path

import torch
from torch.nn import functional as F
from torch.utils.data import DataLoader

from firebird_bilstm_fusion import FirebirdBiLSTMFusion
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_raster_classifier import CLASS_COUNT, direct_class_centroids
from train_hinotori_raster_classifier import augment_stroke_set, collate_stroke_set


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def summarize(logits: torch.Tensor, labels: torch.Tensor) -> dict[str, object]:
    if logits.ndim != 2 or logits.shape[1] != CLASS_COUNT or labels.shape != (len(logits),):
        raise ValueError("evaluation does not match isolated 229-class symbol recognition")
    top = logits.topk(5, dim=1).indices
    predicted = top[:, 0]
    confusion = torch.bincount(labels * CLASS_COUNT + predicted, minlength=CLASS_COUNT**2).reshape(CLASS_COUNT, CLASS_COUNT)
    support = confusion.sum(1)
    present = support > 0
    recalls = confusion.diag()[present].double() / support[present]
    return {
        "count": int(labels.numel()),
        "top1": float((predicted == labels).float().mean().item()),
        "top5": float((top == labels[:, None]).any(dim=1).float().mean().item()),
        "macroRecallSupportedClasses": float(recalls.mean().item()),
        "supportedClassCount": int(present.sum().item()),
        "classSupport": support.tolist(),
        "confusionMatrix": confusion.tolist(),
    }


def model_inputs(inputs, device: torch.device):
    images, points, _reversed_points, valid = inputs
    return images.to(device), points.to(device), valid.to(device).bool()


@torch.inference_mode()
def evaluate(model, loader, device, centroids=None):
    model.eval()
    logits_parts, labels_parts, embedding_parts, source_ids = [], [], [], []
    for inputs, labels, sources in loader:
        images, points, valid = model_inputs(inputs, device)
        logits, embeddings = model(images, points, valid)
        logits_parts.append(logits.cpu())
        labels_parts.append(labels)
        embedding_parts.append(embeddings.cpu())
        source_ids.extend(sources)
    logits = torch.cat(logits_parts)
    labels = torch.cat(labels_parts)
    result = {"classifier": summarize(logits, labels)}
    if centroids is not None:
        prototype_logits = torch.cat(embedding_parts).to(device) @ centroids.T
        result["fitTrainPrototype"] = summarize(prototype_logits.cpu(), labels)
    result["sourceIds"] = source_ids
    result["targets"] = labels.tolist()
    result["classifierPredictions"] = logits.argmax(1).tolist()
    return result


@torch.inference_mode()
def fit_prototypes(model, loader, device):
    model.eval()
    embeddings, labels = [], []
    for inputs, targets, _ in loader:
        images, points, valid = model_inputs(inputs, device)
        embeddings.append(model.encode(images, points, valid).cpu())
        labels.append(targets)
    train_embeddings, train_labels = torch.cat(embeddings), torch.cat(labels)
    centroids = direct_class_centroids(train_embeddings.to(device), train_labels.to(device))
    return centroids


def source_fingerprint(dataset):
    sources = sorted({str(row["sourceSampleId"]) for row in dataset.rows})
    return hashlib.sha256("\n".join(sources).encode()).hexdigest(), sources


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--batch-size", type=int, default=48)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--seed", type=int, default=20261118)
    parser.add_argument("--class-weight-power", type=float, default=0.5)
    parser.add_argument("--resume-checkpoint", type=Path,
                        help="Continue this experiment from its saved latest.pt after fingerprint checks.")
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0 or not 0 <= args.class_weight_power <= 1:
        raise ValueError("epochs, batch size, learning rate, or class-weight power is invalid")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("Apple MPS is unavailable; this experiment requires MPS and has no CPU fallback")
    if args.resume_checkpoint is None and args.output.exists() and any(args.output.iterdir()):
        raise FileExistsError(f"refusing to overwrite an existing experiment: {args.output}")
    if args.resume_checkpoint is not None and not args.resume_checkpoint.is_file():
        raise FileNotFoundError(f"resume checkpoint does not exist: {args.resume_checkpoint}")
    for path in (args.teachers, args.source_split, args.vocabulary):
        if not path.is_file():
            raise FileNotFoundError(f"required input does not exist: {path}")
    args.output.mkdir(parents=True, exist_ok=True)

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.mps.manual_seed(args.seed)
    device = torch.device("mps")
    train_data = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, 128, "train")
    valid_data = DirectAnchorDataset(args.teachers, args.source_split, args.mathwriting_root, 128, "valid")
    train_fingerprint, train_sources = source_fingerprint(train_data)
    valid_fingerprint, valid_sources = source_fingerprint(valid_data)
    if set(train_sources) & set(valid_sources):
        raise ValueError("source-level leakage between fit-train and inner validation")
    vocab_bytes = args.vocabulary.read_bytes()
    vocabulary_doc = json.loads(vocab_bytes)
    vocabulary = vocabulary_doc.get("labels") if isinstance(vocabulary_doc, dict) else None
    if not isinstance(vocabulary, list) or len(vocabulary) != CLASS_COUNT or len(set(vocabulary)) != CLASS_COUNT:
        raise ValueError("vocabulary must contain 229 unique ordered labels")
    for row in train_data.rows + valid_data.rows:
        index = row.get("classIndex")
        if not isinstance(index, int) or not 0 <= index < CLASS_COUNT or row.get("label") != vocabulary[index]:
            raise ValueError("teacher class index disagrees with the fixed vocabulary")
    counts = torch.bincount(torch.tensor([int(row["classIndex"]) for row in train_data.rows]), minlength=CLASS_COUNT)
    if (counts == 0).any():
        raise ValueError("all 229 classes require fit-train teachers")

    start_epoch = 1
    generator = torch.Generator().manual_seed(args.seed)
    train_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=True, collate_fn=collate_stroke_set, generator=generator)
    fit_loader = DataLoader(train_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_stroke_set)
    valid_loader = DataLoader(valid_data, batch_size=args.batch_size, shuffle=False, collate_fn=collate_stroke_set)
    model = FirebirdBiLSTMFusion().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-2)
    weights = counts.float().pow(-args.class_weight_power)
    weights = (weights / weights.mean()).to(device)
    run = {
        "model": "FirebirdBiLSTMFusion",
        "task": "229-way isolated handwritten symbol classification",
        "architecture": "residual 64x64 ink raster encoder plus shared per-stroke bidirectional LSTM; time mean/max pooling; direction-symmetric averaging; stroke-permutation invariant mean/max pooling; late fusion; normalized 128D embedding and 229-way classifier",
        "trainingObjective": "class-weighted cross entropy",
        "inputContract": {"points": "canonical [stroke,128,2] InkML points", "raster": "64x64 union ink", "strokeOrderUsed": False, "strokeDirectionUsed": False, "withinStrokeSequenceModel": "bidirectional LSTM; original and reversed point sequences averaged"},
        "trainTeachersSHA256": sha256(args.teachers),
        "sourceSplitSHA256": sha256(args.source_split),
        "vocabularySHA256": hashlib.sha256(vocab_bytes).hexdigest(),
        "trainSourceFingerprint": train_fingerprint,
        "validSourceFingerprint": valid_fingerprint,
        "trainSourceCount": len(train_sources),
        "validSourceCount": len(valid_sources),
        "trainSymbolCount": len(train_data),
        "validSymbolCount": len(valid_data),
        "trainClassCounts": counts.tolist(),
        "optimizer": "AdamW", "learningRate": args.learning_rate,
        "weightDecay": 1e-2, "classWeightPower": args.class_weight_power,
        "seed": args.seed, "device": "MPS", "outerTestRead": False,
        "validationRole": "inner development validation; not final independent evaluation",
        "aneStatus": "not measured; Core ML conversion and physical iPad execution are separate gates",
    }
    best = {name: -1.0 for name in ("classifierTop1", "classifierTop5", "fitPrototypeTop1", "fitPrototypeTop5")}
    run_path = args.output / "run.json"
    if args.resume_checkpoint is None:
        run_path.write_text(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    else:
        if not run_path.is_file():
            raise FileNotFoundError(f"resume run metadata is missing: {run_path}")
        saved_run = json.loads(run_path.read_text(encoding="utf-8"))
        fields = ("model", "trainTeachersSHA256", "sourceSplitSHA256", "vocabularySHA256",
                  "trainSourceFingerprint", "validSourceFingerprint", "trainSourceCount",
                  "validSourceCount", "trainSymbolCount", "validSymbolCount")
        if any(saved_run.get(field) != run.get(field) for field in fields):
            raise ValueError("resume teacher, split, vocabulary, or source fingerprints differ")
        resume = torch.load(args.resume_checkpoint, map_location=device, weights_only=False)
        if resume.get("run") != saved_run:
            raise ValueError("resume checkpoint does not belong to the specified experiment")
        model.load_state_dict(resume["model"], strict=True)
        optimizer.load_state_dict(resume["optimizer"])
        start_epoch = int(resume["epoch"]) + 1
        if start_epoch > args.epochs:
            raise ValueError("resume checkpoint has already reached the requested epoch limit")
        torch.set_rng_state(resume["torchRngState"])
        for name, mode, key in (
            ("classifierTop1", "classifier", "top1"), ("classifierTop5", "classifier", "top5"),
            ("fitPrototypeTop1", "fitTrainPrototype", "top1"), ("fitPrototypeTop5", "fitTrainPrototype", "top5"),
        ):
            filename = name.replace("fitPrototype", "fit-prototype-").replace("classifier", "classifier-").lower()
            best_path = args.output / f"best-{filename}.json"
            if not best_path.is_file():
                raise FileNotFoundError(f"resume best-metric record is missing: {best_path}")
            best[name] = float(json.loads(best_path.read_text(encoding="utf-8"))[mode][key])
        generator.manual_seed(args.seed + start_epoch)
    history_path = args.output / "metrics.jsonl"
    with history_path.open("x" if args.resume_checkpoint is None else "a", encoding="utf-8") as history:
        for epoch in range(start_epoch, args.epochs + 1):
            model.train()
            loss_sum = 0.0
            correct = count = 0
            for raw_inputs, labels, _ in train_loader:
                images, points, reversed_points, valid_float = raw_inputs
                images, points, reversed_points, valid_float = augment_stroke_set((images, points, reversed_points, valid_float))
                images, points = images.to(device), points.to(device)
                valid = valid_float.to(device).bool()
                labels = labels.to(device)
                logits, _ = model(images, points, valid)
                loss = F.cross_entropy(logits, labels, weight=weights)
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
                optimizer.step()
                loss_sum += float(loss.detach().item()) * labels.numel()
                correct += int((logits.detach().argmax(1) == labels).sum().item())
                count += labels.numel()
            centroids = fit_prototypes(model, fit_loader, device)
            measured = evaluate(model, valid_loader, device, centroids)
            record = {
                "epoch": epoch,
                "trainLoss": loss_sum / count,
                "trainAccuracyDuringOptimization": correct / count,
                "classifier": measured["classifier"],
                "fitTrainPrototype": measured["fitTrainPrototype"],
                "validationSourceIds": measured["sourceIds"],
                "validationTargets": measured["targets"],
                "classifierPredictions": measured["classifierPredictions"],
            }
            history.write(json.dumps(record, ensure_ascii=False) + "\n")
            history.flush()
            checkpoint = {"model": model.state_dict(), "optimizer": optimizer.state_dict(), "epoch": epoch,
                          "run": run, "metrics": record, "torchRngState": torch.get_rng_state()}
            torch.save(checkpoint, args.output / "latest.pt")
            (args.output / "latest.json").write_text(json.dumps({k: v for k, v in record.items() if k != "confusionMatrix"}, ensure_ascii=False, indent=2) + "\n")
            for key, mode, metric_key in (
                ("classifierTop1", "classifier", "top1"), ("classifierTop5", "classifier", "top5"),
                ("fitPrototypeTop1", "fitTrainPrototype", "top1"), ("fitPrototypeTop5", "fitTrainPrototype", "top5"),
            ):
                value = float(record[mode][metric_key])
                if value > best[key]:
                    best[key] = value
                    suffix = key.replace("fitPrototype", "fit-prototype-").replace("classifier", "classifier-").lower()
                    torch.save(checkpoint, args.output / f"best-{suffix}.pt")
                    (args.output / f"best-{suffix}.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
            compact = {"epoch": epoch, "trainLoss": record["trainLoss"],
                       "classifier": {k: record["classifier"][k] for k in ("top1", "top5", "macroRecallSupportedClasses")},
                       "fitTrainPrototype": {k: record["fitTrainPrototype"][k] for k in ("top1", "top5", "macroRecallSupportedClasses")}}
            print(json.dumps(compact, ensure_ascii=False), flush=True)
    summary = {"status": "COMPLETED", "epochs": args.epochs, "bestInnerValidationMetrics": best,
               "outerTestRead": False, "run": run}
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
