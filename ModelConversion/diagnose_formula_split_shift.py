#!/usr/bin/env python3
"""Diagnose train/valid distribution shift without opening the test split.

The diagnostic fingerprints every selected InkML file, summarizes the real
input and normalized-label distributions, and measures teacher-forced errors
for a fixed checkpoint on train (a deterministic prefix sample) and valid.
The CLI intentionally accepts only ``train`` and ``valid`` so this diagnostic
cannot read the frozen test split by accident.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import time
from collections import Counter, defaultdict
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader

try:
    from ModelConversion.formula_whole_model import FormulaWholeModel, load_tokenizer, require_checkpoint_input_contract, tokenize_structure
    from ModelConversion.formula_whole_input import load_formula_input
    from ModelConversion.train_formula_whole_model import FormulaWholeDataset, collate
except ImportError:
    from formula_whole_model import FormulaWholeModel, load_tokenizer, require_checkpoint_input_contract, tokenize_structure
    from formula_whole_input import load_formula_input
    from train_formula_whole_model import FormulaWholeDataset, collate


def percentile(values: list[int], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.floor(fraction * (len(ordered) - 1)))
    return float(ordered[index])


def syntax_role(token: str) -> str:
    if token in {"{", "}"}:
        return "group_delimiter"
    if token in {"^", "_"}:
        return "script_marker"
    if token in {"&", "\\\\"}:
        return "matrix_separator"
    if token in {"(", ")", "[", "]", "|", ","}:
        return "visual_delimiter"
    if token in {"+", "-", "=", "."}:
        return "operator_or_punctuation"
    if token.startswith("\\"):
        return "latex_command"
    if token.startswith("<"):
        return "sequence_control"
    return "literal"


def summarize_split(split_root: Path, tokenizer, teacher_limit: int | None) -> dict[str, object]:
    paths = sorted(split_root.glob("*.inkml"))
    label_char_lengths: list[int] = []
    label_token_lengths: list[int] = []
    trace_counts: list[int] = []
    point_counts: list[int] = []
    points_per_trace: list[int] = []
    token_frequency: Counter[str] = Counter()
    matrix_count = 0
    split_fingerprint = hashlib.sha256()
    sample_hashes: list[dict[str, str]] = []

    for path in paths:
        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        split_fingerprint.update(path.name.encode("utf-8"))
        split_fingerprint.update(b"\0")
        split_fingerprint.update(bytes.fromhex(digest))
        if len(sample_hashes) < 8:
            sample_hashes.append({"file": path.name, "sha256": digest})
        formula, metadata = load_formula_input(path)
        label = metadata["normalizedLabel"]
        tokens = tokenize_structure(label)
        tokenizer.encode(label)
        label_char_lengths.append(len(label))
        label_token_lengths.append(len(tokens))
        trace_counts.append(len(formula.traces))
        point_count = sum(len(trace) for trace in formula.traces)
        point_counts.append(point_count)
        points_per_trace.extend(len(trace) for trace in formula.traces)
        token_frequency.update(tokens)
        matrix_count += int("\\begin{matrix}" in label)

    return {
        "pathCount": len(paths),
        "sourceHash": {
            "algorithm": "sha256(file bytes), sorted filename+digest aggregate",
            "splitFingerprint": split_fingerprint.hexdigest(),
            "sampleFileHashes": sample_hashes,
        },
        "label": {
            "character": {
                "mean": statistics.mean(label_char_lengths),
                "median": statistics.median(label_char_lengths),
                "p95": percentile(label_char_lengths, 0.95),
                "max": max(label_char_lengths),
            },
            "structureToken": {
                "mean": statistics.mean(label_token_lengths),
                "median": statistics.median(label_token_lengths),
                "p95": percentile(label_token_lengths, 0.95),
                "max": max(label_token_lengths),
            },
            "matrixCount": matrix_count,
            "matrixRate": matrix_count / max(len(paths), 1),
            "tokenFrequency": dict(token_frequency.most_common()),
        },
        "input": {
            "traceCount": {
                "mean": statistics.mean(trace_counts),
                "median": statistics.median(trace_counts),
                "p95": percentile(trace_counts, 0.95),
                "max": max(trace_counts),
            },
            "pointCountPerFormula": {
                "mean": statistics.mean(point_counts),
                "median": statistics.median(point_counts),
                "p95": percentile(point_counts, 0.95),
                "max": max(point_counts),
            },
            "pointsPerTrace": {
                "mean": statistics.mean(points_per_trace),
                "median": statistics.median(points_per_trace),
                "p95": percentile(points_per_trace, 0.95),
                "max": max(points_per_trace),
            },
        },
        "teacherForcedSampleLimit": teacher_limit,
    }


def evaluate_teacher_forced(split_root: Path, tokenizer, checkpoint: Path, d_model: int, batch_size: int, device: str, limit: int | None) -> dict[str, object]:
    require_checkpoint_input_contract(checkpoint)
    dataset = FormulaWholeDataset(split_root, tokenizer, limit=limit)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False, collate_fn=collate, num_workers=0)
    model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=d_model, heads=4, dim_feedforward=256, dropout=0.1)
    model.load_state_dict(torch.load(checkpoint, map_location=device, weights_only=True))
    model.to(device)
    model.eval()
    criterion = nn.CrossEntropyLoss(ignore_index=tokenizer.pad_id, reduction="none")
    total_loss = 0.0
    total_tokens = 0
    total_correct = 0
    buckets: dict[str, dict[str, int]] = defaultdict(lambda: {"examples": 0, "tokens": 0, "errors": 0})
    matrix_buckets: dict[str, dict[str, int]] = defaultdict(lambda: {"examples": 0, "tokens": 0, "errors": 0})
    token_buckets: dict[str, dict[str, int]] = defaultdict(lambda: {"tokens": 0, "errors": 0})
    role_buckets: dict[str, dict[str, int]] = defaultdict(lambda: {"tokens": 0, "errors": 0})
    length_role_buckets: dict[str, dict[str, dict[str, int]]] = defaultdict(
        lambda: defaultdict(lambda: {"tokens": 0, "errors": 0})
    )
    with torch.inference_mode():
        for traces, geometry, trace_mask, tokens, token_mask, labels in loader:
            traces, geometry, trace_mask = traces.to(device), geometry.to(device), trace_mask.to(device)
            tokens, token_mask = tokens.to(device), token_mask.to(device)
            logits = model.syntax_masked_forward(traces, geometry, trace_mask, tokens[:, :-1], token_mask[:, :-1], tokenizer)
            target = tokens[:, 1:]
            non_pad = target != tokenizer.pad_id
            prediction = logits.argmax(dim=-1)
            losses = criterion(logits.reshape(-1, logits.shape[-1]), target.reshape(-1)).reshape(target.shape)
            total_loss += losses[non_pad].sum().item()
            total_tokens += non_pad.sum().item()
            total_correct += ((prediction == target) & non_pad).sum().item()
            for index, label in enumerate(labels):
                bucket = "0-10" if len(label) <= 10 else "11-20" if len(label) <= 20 else "21+"
                row_mask = non_pad[index]
                errors = int(((prediction[index] != target[index]) & row_mask).sum().item())
                token_count = int(row_mask.sum().item())
                buckets[bucket]["examples"] += 1
                buckets[bucket]["tokens"] += token_count
                buckets[bucket]["errors"] += errors
                matrix_bucket = "matrix" if "\\begin{matrix}" in label else "nonMatrix"
                matrix_buckets[matrix_bucket]["examples"] += 1
                matrix_buckets[matrix_bucket]["tokens"] += token_count
                matrix_buckets[matrix_bucket]["errors"] += errors
                for position in row_mask.nonzero(as_tuple=False).flatten().tolist():
                    target_token = tokenizer.tokens[int(target[index, position].item())]
                    is_error = int(prediction[index, position].item() != target[index, position].item())
                    token_buckets[target_token]["tokens"] += 1
                    token_buckets[target_token]["errors"] += is_error
                    role = syntax_role(target_token)
                    role_buckets[role]["tokens"] += 1
                    role_buckets[role]["errors"] += is_error
                    length_role_buckets[bucket][role]["tokens"] += 1
                    length_role_buckets[bucket][role]["errors"] += is_error
    for group in (buckets, matrix_buckets, token_buckets, role_buckets):
        for values in group.values():
            values["accuracy"] = 1.0 - values["errors"] / max(values["tokens"], 1)
            values["errorRate"] = values["errors"] / max(values["tokens"], 1)
    for role_group in length_role_buckets.values():
        for values in role_group.values():
            values["accuracy"] = 1.0 - values["errors"] / max(values["tokens"], 1)
            values["errorRate"] = values["errors"] / max(values["tokens"], 1)
    return {
        "sampleCount": len(dataset),
        "teacherForcedLossPerToken": total_loss / max(total_tokens, 1),
        "teacherForcedTokenAccuracy": total_correct / max(total_tokens, 1),
        "teacherForcedTokenErrorRate": 1.0 - total_correct / max(total_tokens, 1),
        "byTargetLength": dict(buckets),
        "byMatrixPresence": dict(matrix_buckets),
        "byTargetToken": dict(sorted(token_buckets.items(), key=lambda item: (-item[1]["tokens"], item[0]))),
        "bySyntaxRole": dict(sorted(role_buckets.items())),
        "byTargetLengthAndSyntaxRole": {
            bucket: dict(sorted(role_group.items())) for bucket, role_group in sorted(length_role_buckets.items())
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--train-teacher-limit", type=int, default=4096)
    parser.add_argument("--valid-teacher-limit", type=int, default=None)
    parser.add_argument("--d-model", type=int, default=128)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()
    started = time.time()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    tokenizer = load_tokenizer(args.tokenizer)
    split_root = args.dataset_root / "mathwriting-2024"
    train_summary = summarize_split(split_root / "train", tokenizer, args.train_teacher_limit)
    valid_summary = summarize_split(split_root / "valid", tokenizer, args.valid_teacher_limit)
    train_teacher = evaluate_teacher_forced(split_root / "train", tokenizer, args.checkpoint, args.d_model, args.batch_size, args.device, args.train_teacher_limit)
    valid_teacher = evaluate_teacher_forced(split_root / "valid", tokenizer, args.checkpoint, args.d_model, args.batch_size, args.device, args.valid_teacher_limit)
    report = {
        "status": "COMPLETED",
        "splitPolicy": "train and valid only; test is not a permitted CLI choice",
        "datasetRoot": str(args.dataset_root),
        "checkpoint": str(args.checkpoint),
        "tokenizer": str(args.tokenizer),
        "config": {"dModel": args.d_model, "batchSize": args.batch_size, "device": args.device},
        "distributions": {"train": train_summary, "valid": valid_summary},
        "teacherForced": {"train": train_teacher, "valid": valid_teacher},
        "elapsedSeconds": time.time() - started,
    }
    (args.output_dir / "split-shift-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": report["status"], "trainCount": train_summary["pathCount"], "validCount": valid_summary["pathCount"], "trainTeacher": train_teacher["teacherForcedTokenAccuracy"], "validTeacher": valid_teacher["teacherForcedTokenAccuracy"], "elapsedSeconds": report["elapsedSeconds"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
