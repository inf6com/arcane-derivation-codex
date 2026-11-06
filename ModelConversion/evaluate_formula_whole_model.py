#!/usr/bin/env python3
"""Evaluate one selected whole-formula checkpoint on one split.

The training script never opens ``test``. This evaluator is intentionally
explicit about the split so that valid-gate evaluation and the final test
evaluation cannot be confused. It performs teacher-forced token accuracy and
greedy sequence decoding, then writes a manifest and a report. A checkpoint
does not pass the operational adoption gate unless it produces at least one
exact valid expression, reaches the declared token/EOS gates, and produces no
structurally malformed decoded expression.
"""
from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader

try:
    from ModelConversion.formula_whole_model import (
        FormulaWholeModel,
        MAX_LABEL_TOKENS,
        load_tokenizer,
        model_input_contract,
        require_checkpoint_input_contract,
        tokenize_structure,
        verify_execution_device,
    )
    from ModelConversion.train_formula_whole_model import FormulaWholeDataset, collate, syntax_masked_cross_entropy
except ImportError:
    from formula_whole_model import FormulaWholeModel, MAX_LABEL_TOKENS, load_tokenizer, model_input_contract, require_checkpoint_input_contract, tokenize_structure, verify_execution_device
    from train_formula_whole_model import FormulaWholeDataset, collate, syntax_masked_cross_entropy


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for i, left_char in enumerate(left, start=1):
        current = [i]
        for j, right_char in enumerate(right, start=1):
            current.append(min(
                current[-1] + 1,
                previous[j] + 1,
                previous[j - 1] + (left_char != right_char),
            ))
        previous = current
    return previous[-1]


def structurally_valid(expression: str) -> bool:
    stack: list[str] = []
    pairs = {"}": "{"}
    try:
        tokens = tokenize_structure(expression)
    except ValueError:
        return False
    for token in tokens:
        if token == "{":
            stack.append(token)
        elif token == "}":
            if not stack or stack.pop() != pairs[token]:
                return False
    if stack or tokens[-1:] in (["^"], ["_"]):
        return False
    for index, token in enumerate(tokens):
        if token in ("^", "_") and (index + 1 >= len(tokens) or tokens[index + 1] == "}"):
            return False
    begins = []
    cursor = 0
    while True:
        begin = expression.find("\\begin{", cursor)
        end = expression.find("\\end{", cursor)
        if begin < 0 and end < 0:
            break
        if begin >= 0 and (end < 0 or begin < end):
            close = expression.find("}", begin + 7)
            if close < 0:
                return False
            begins.append(expression[begin + 7 : close])
            cursor = close + 1
        else:
            close = expression.find("}", end + 5)
            if close < 0 or not begins or begins.pop() != expression[end + 5 : close]:
                return False
            cursor = close + 1
    return not begins


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--split", choices=("train", "valid", "test"), required=True)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument(
        "--d-model",
        type=int,
        default=None,
        help="only for checkpoints written before modelArchitecture was persisted; must match the trained dimension exactly",
    )
    parser.add_argument("--device", default="mps", help="mps by default; CPU requires measured MPS unavailability or --cpu-comparison")
    parser.add_argument("--cpu-comparison", action="store_true", help="explicit CPU-only control evaluation for a measured MPS/CPU comparison; never a production candidate")
    parser.add_argument("--max-samples", type=int, default=None)
    parser.add_argument(
        "--product-exact-match-min",
        type=float,
        default=None,
        help="required declared whole-formula greedy exact-match threshold for product adoption; absent means benchmark-only and cannot pass adoption",
    )
    args = parser.parse_args()

    if args.product_exact_match_min is not None and args.product_exact_match_min != 1.0:
        raise ValueError("product whole-formula evaluation requires --product-exact-match-min 1.0")

    started_at = time.time()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output_dir / "evaluation-manifest.json"
    manifest = {
        "status": "RUNNING",
        "startedAtUnix": started_at,
        "split": args.split,
        "testReadPolicy": "train is diagnostic; test is permitted only for the final one-time evaluation after valid adoption gate",
        "datasetRoot": str(args.dataset_root),
        "tokenizer": str(args.tokenizer),
        "checkpoint": str(args.checkpoint),
        "config": {"batchSize": args.batch_size, "dModelOverride": args.d_model, "device": args.device, "maxSamples": args.max_samples},
        "inputContract": model_input_contract(),
    }
    write_json(manifest_path, manifest)

    try:
        manifest["executionDeviceEvidence"] = verify_execution_device(args.device, cpu_comparison=args.cpu_comparison)
        manifest["executionRole"] = "cpu-comparison-control" if args.cpu_comparison else "production-candidate"
        write_json(manifest_path, manifest)
        tokenizer = load_tokenizer(args.tokenizer)
        checkpoint_contract = require_checkpoint_input_contract(args.checkpoint)
        manifest["checkpointContract"] = checkpoint_contract
        architecture = checkpoint_contract.get("modelArchitecture")
        if architecture is None:
            if args.d_model is None:
                raise ValueError(
                    "checkpoint has no modelArchitecture; supply its measured --d-model explicitly. "
                    "New checkpoints must persist modelArchitecture."
                )
            architecture = {
                "vocabSize": tokenizer.vocab_size,
                "dModel": args.d_model,
                "heads": 4,
                "dimFeedforward": 256,
                "dropout": 0.1,
            }
        elif args.d_model is not None and args.d_model != architecture.get("dModel"):
            raise ValueError(
                f"--d-model {args.d_model} conflicts with checkpoint dModel {architecture.get('dModel')}"
            )
        if architecture.get("vocabSize") != tokenizer.vocab_size:
            raise ValueError(
                f"checkpoint vocabSize {architecture.get('vocabSize')} differs from tokenizer {tokenizer.vocab_size}"
            )
        manifest["modelArchitecture"] = architecture
        dataset = FormulaWholeDataset(args.dataset_root / "mathwriting-2024" / args.split, tokenizer, limit=args.max_samples)
        manifest["pathCount"] = len(dataset)
        write_json(manifest_path, manifest)
        model = FormulaWholeModel(
            vocab_size=tokenizer.vocab_size,
            d_model=architecture["dModel"],
            heads=architecture["heads"],
            dim_feedforward=architecture["dimFeedforward"],
            dropout=architecture["dropout"],
        )
        state = torch.load(args.checkpoint, map_location=args.device, weights_only=True)
        model.load_state_dict(state)
        model.to(args.device)
        model.eval()
        loader = DataLoader(dataset, batch_size=args.batch_size, shuffle=False, collate_fn=collate, num_workers=0)
        criterion = nn.CrossEntropyLoss(ignore_index=tokenizer.pad_id, label_smoothing=0.0)

        teacher_correct = 0
        teacher_tokens = 0
        total_loss = 0.0
        exact_matches = 0
        eos_count = 0
        malformed_count = 0
        distances: list[int] = []
        normalized_distances: list[float] = []
        output_lengths: list[int] = []
        samples: list[dict[str, object]] = []
        malformed_samples: list[dict[str, object]] = []
        length_buckets: dict[str, list[int]] = {"0-10": [0, 0], "11-20": [0, 0], "21+": [0, 0]}

        with torch.inference_mode():
            for batch_index, (traces, geometry, trace_mask, tokens, token_mask, labels) in enumerate(loader):
                traces, geometry, trace_mask = traces.to(args.device), geometry.to(args.device), trace_mask.to(args.device)
                tokens, token_mask = tokens.to(args.device), token_mask.to(args.device)
                target_input = tokens[:, :-1]
                target_output = tokens[:, 1:]
                target_input_mask = token_mask[:, :-1]
                logits = model.syntax_masked_forward(traces, geometry, trace_mask, target_input, target_input_mask, tokenizer)
                per_token_loss = syntax_masked_cross_entropy(logits, target_output, tokenizer.pad_id, criterion.label_smoothing)
                loss = per_token_loss[target_output != tokenizer.pad_id].mean()
                if not torch.isfinite(loss):
                    raise FloatingPointError(f"non-finite syntax-aware validation loss at batch {batch_index}: {loss.item()}")
                non_pad = target_output != tokenizer.pad_id
                teacher_correct += ((logits.argmax(dim=-1) == target_output) & non_pad).sum().item()
                teacher_tokens += non_pad.sum().item()
                total_loss += loss.item() * non_pad.sum().item()

                # Do not truncate a prediction at target length + 4: that
                # turns a valid late-EOS prediction into a false malformed
                # result.  MAX_LABEL_TOKENS is the measured train bound.
                decoded_rows = model.greedy_decode(traces, geometry, trace_mask, tokenizer, max_length=MAX_LABEL_TOKENS)
                for row, label in zip(decoded_rows, labels):
                    predicted = tokenizer.decode(row)
                    exact = predicted == label
                    exact_matches += int(exact)
                    bucket = "0-10" if len(label) <= 10 else "11-20" if len(label) <= 20 else "21+"
                    length_buckets[bucket][0] += 1
                    length_buckets[bucket][1] += int(exact)
                    has_eos = tokenizer.eos_id in row
                    eos_count += int(has_eos)
                    valid_structure = structurally_valid(predicted)
                    malformed_count += int(not valid_structure)
                    if not valid_structure and len(malformed_samples) < 20:
                        malformed_samples.append({"label": label, "prediction": predicted, "exact": exact, "hasEOS": has_eos})
                    distance = edit_distance(predicted, label)
                    distances.append(distance)
                    normalized_distances.append(distance / max(len(label), 1))
                    output_lengths.append(len(predicted))
                    if len(samples) < 20:
                        samples.append({"label": label, "prediction": predicted, "exact": exact, "hasEOS": has_eos, "structurallyValid": valid_structure})
                if (batch_index + 1) % 100 == 0:
                    print(json.dumps({"batch": batch_index + 1, "processed": min((batch_index + 1) * args.batch_size, len(dataset))}))

        total = len(dataset)
        criteria = {
            "exactMatchRateMin": args.product_exact_match_min,
            "exactMatchRateByTargetLengthMin": None,
            "teacherForcedTokenAccuracyMin": 0.85,
            "eosRateMin": 0.95,
            "malformedStructureRateMax": 0.0,
        }
        metrics = {
            "count": total,
            "teacherForcedLossPerToken": total_loss / max(teacher_tokens, 1),
            "teacherForcedTokenAccuracy": teacher_correct / max(teacher_tokens, 1),
            "exactMatch": exact_matches / max(total, 1),
            "exactMatchCount": exact_matches,
            "exactMatchByTargetLength": {
                bucket: {
                    "count": counts[0],
                    "exactMatchCount": counts[1],
                    "exactMatchRate": counts[1] / max(counts[0], 1),
                }
                for bucket, counts in length_buckets.items()
            },
            "eosRate": eos_count / max(total, 1),
            "malformedStructureRate": malformed_count / max(total, 1),
            "editDistanceMean": statistics.mean(distances) if distances else 0.0,
            "editDistanceMedian": statistics.median(distances) if distances else 0.0,
            "normalizedEditDistanceMean": statistics.mean(normalized_distances) if normalized_distances else 0.0,
            "outputLengthMean": statistics.mean(output_lengths) if output_lengths else 0.0,
            "outputLengthMedian": statistics.median(output_lengths) if output_lengths else 0.0,
        }
        passed = (
            args.split == "valid"
            and criteria["exactMatchRateMin"] is not None
            and metrics["exactMatch"] >= criteria["exactMatchRateMin"]
            and metrics["teacherForcedTokenAccuracy"] >= criteria["teacherForcedTokenAccuracyMin"]
            and metrics["eosRate"] >= criteria["eosRateMin"]
            and metrics["malformedStructureRate"] <= criteria["malformedStructureRateMax"]
        )
        report = {
            "status": "COMPLETED",
            "split": args.split,
            "checkpoint": str(args.checkpoint),
            "metrics": metrics,
            "acceptanceCriteria": criteria,
            "adoptionGate": "PASS" if passed else "FAIL",
            "samples": samples,
            "malformedSamples": malformed_samples,
            "elapsedSeconds": time.time() - started_at,
            "testReadPolicy": "test remains unopened by train/valid evaluation" if args.split in ("train", "valid") else "final test evaluation completed once",
        }
        report_path = args.output_dir / "evaluation-report.json"
        write_json(report_path, report)
        manifest.update({"status": "COMPLETED", "completedAtUnix": time.time(), "report": str(report_path), "adoptionGate": report["adoptionGate"], "metrics": metrics})
        write_json(manifest_path, manifest)
        print(json.dumps({"adoptionGate": report["adoptionGate"], **metrics}))
        return 0
    except (Exception, KeyboardInterrupt) as error:
        status = "CANCELLED" if isinstance(error, KeyboardInterrupt) else "FAILED"
        manifest.update({"status": status, "failedAtUnix": time.time(), "failure": str(error) or status})
        write_json(manifest_path, manifest)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
