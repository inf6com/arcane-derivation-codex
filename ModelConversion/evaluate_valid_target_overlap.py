#!/usr/bin/env python3
"""Evaluate a fixed checkpoint on valid targets seen or unseen in train.

Only MathWriting-2024/train and valid are opened.  Target overlap is a label
property, not unobserved source provenance.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import statistics
from collections import defaultdict
from pathlib import Path

import torch
from torch.utils.data import DataLoader

try:
    from ModelConversion.evaluate_formula_whole_model import structurally_valid
    from ModelConversion.formula_whole_input import load_formula_input
    from ModelConversion.formula_whole_model import FormulaWholeModel, load_tokenizer, require_checkpoint_input_contract, verify_execution_device
    from ModelConversion.train_formula_whole_model import FormulaWholeDataset, collate
except ImportError:
    from evaluate_formula_whole_model import structurally_valid
    from formula_whole_input import load_formula_input
    from formula_whole_model import FormulaWholeModel, load_tokenizer, require_checkpoint_input_contract, verify_execution_device
    from train_formula_whole_model import FormulaWholeDataset, collate


def train_targets(root: Path) -> set[str]:
    values: set[str] = set()
    for path in sorted(root.glob("*.inkml")):
        _formula, metadata = load_formula_input(path)
        values.add(metadata["normalizedLabel"])
    return values


def blank() -> dict[str, object]:
    return {"count": 0, "teacherTokens": 0, "teacherCorrect": 0, "exact": 0, "eos": 0, "malformed": 0, "scriptTokens": 0, "scriptErrors": 0, "digitTokens": 0, "digitErrors": 0, "targetLengths": [], "traceCounts": []}


def finalize(value: dict[str, object]) -> dict[str, float | int]:
    count, tokens = int(value["count"]), int(value["teacherTokens"])
    return {"count": count, "teacherForcedTokenAccuracy": int(value["teacherCorrect"]) / max(tokens, 1), "greedyExactMatch": int(value["exact"]) / max(count, 1), "greedyExactCount": int(value["exact"]), "eosRate": int(value["eos"]) / max(count, 1), "malformedRate": int(value["malformed"]) / max(count, 1), "scriptTokenErrorRate": int(value["scriptErrors"]) / max(int(value["scriptTokens"]), 1), "digitTokenErrorRate": int(value["digitErrors"]) / max(int(value["digitTokens"]), 1), "targetLengthMean": statistics.mean(value["targetLengths"]) if value["targetLengths"] else 0.0, "traceCountMean": statistics.mean(value["traceCounts"]) if value["traceCounts"] else 0.0}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--d-model", type=int, default=128)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--valid-limit", type=int, default=None, help="deterministic sorted valid prefix; use only for a matching proxy run")
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()
    tokenizer = load_tokenizer(args.tokenizer)
    require_checkpoint_input_contract(args.checkpoint)
    root = args.dataset_root / "mathwriting-2024"
    seen_targets = train_targets(root / "train")
    valid = FormulaWholeDataset(root / "valid", tokenizer, limit=args.valid_limit)
    loader = DataLoader(valid, batch_size=args.batch_size, shuffle=False, collate_fn=collate, num_workers=0)
    model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=args.d_model, heads=4, dim_feedforward=256, dropout=0.1)
    model.load_state_dict(torch.load(args.checkpoint, map_location=args.device, weights_only=True))
    model.to(args.device).eval()
    script_ids = {tokenizer.token_to_id[token] for token in ("^", "_")}
    digit_ids = {tokenizer.token_to_id[token] for token in "0123456789"}
    groups = {"targetSeenInTrain": blank(), "targetUnseenInTrain": blank()}
    with torch.inference_mode():
        for traces, geometry, trace_mask, tokens, token_mask, labels in loader:
            traces, geometry, trace_mask, tokens, token_mask = traces.to(args.device), geometry.to(args.device), trace_mask.to(args.device), tokens.to(args.device), token_mask.to(args.device)
            target = tokens[:, 1:]
            logits = model.syntax_masked_forward(traces, geometry, trace_mask, tokens[:, :-1], token_mask[:, :-1], tokenizer)
            prediction = logits.argmax(dim=-1)
            decoded = model.greedy_decode(traces, geometry, trace_mask, tokenizer)
            for index, label in enumerate(labels):
                value = groups["targetSeenInTrain" if label in seen_targets else "targetUnseenInTrain"]
                mask = target[index] != tokenizer.pad_id
                errors = prediction[index].ne(target[index])
                value["count"] += 1
                value["teacherTokens"] += int(mask.sum().item())
                value["teacherCorrect"] += int((~errors & mask).sum().item())
                value["scriptTokens"] += sum(int((target[index] == token_id).sum().item()) for token_id in script_ids)
                value["scriptErrors"] += sum(int((errors & (target[index] == token_id)).sum().item()) for token_id in script_ids)
                value["digitTokens"] += sum(int((target[index] == token_id).sum().item()) for token_id in digit_ids)
                value["digitErrors"] += sum(int((errors & (target[index] == token_id)).sum().item()) for token_id in digit_ids)
                predicted = tokenizer.decode(decoded[index])
                value["exact"] += int(predicted == label)
                value["eos"] += int(tokenizer.eos_id in decoded[index])
                value["malformed"] += int(not structurally_valid(predicted))
                value["targetLengths"].append(len(label))
                value["traceCounts"].append(int((~trace_mask[index]).sum().item()))
    criteria = {"teacherForcedTokenAccuracyMin": 0.85, "greedyExactMatchMin": 0.10, "eosRateMin": 0.95, "malformedRateMax": 0.0}
    finalized = {key: finalize(value) for key, value in groups.items()}
    unseen = finalized["targetUnseenInTrain"]
    passed = unseen["teacherForcedTokenAccuracy"] >= criteria["teacherForcedTokenAccuracyMin"] and unseen["greedyExactMatch"] >= criteria["greedyExactMatchMin"] and unseen["eosRate"] >= criteria["eosRateMin"] and unseen["malformedRate"] <= criteria["malformedRateMax"]
    contract = {"overlapDefinition": "valid normalizedLabel exact match in any train normalizedLabel", "requiredGroup": "targetUnseenInTrain", "criteria": criteria}
    report = {"status": "COMPLETED", "splitPolicy": "train and valid only; test is not opened", "checkpoint": str(args.checkpoint), "validLimit": args.valid_limit, "executionDeviceEvidence": verify_execution_device(args.device), **contract, "contractSHA256": hashlib.sha256(json.dumps(contract, sort_keys=True).encode("utf-8")).hexdigest(), "groups": finalized, "adoptionGate": "PASS" if passed else "FAIL"}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report["groups"], ensure_ascii=False))


if __name__ == "__main__":
    main()
