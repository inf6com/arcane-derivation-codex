#!/usr/bin/env python3
"""Measure deterministic MPS behavior for one real whole-formula update.

This audit never opens a dataset split.  It uses the production model,
tokenizer, syntax mask, optimizer, and fixed tensors twice under the same
seed, then records whether the two loss values and updated state dictionaries
are bit-identical.  A deterministic-algorithms error is evidence, not a
reason to enable CPU fallback.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch import nn

try:
    from ModelConversion.formula_whole_model import FormulaWholeModel, POINTS_PER_TRACE, TRACE_GEOMETRY_FEATURE_DIMENSION, load_tokenizer, syntax_allowed_mask, verify_execution_device
except ImportError:
    from formula_whole_model import FormulaWholeModel, POINTS_PER_TRACE, TRACE_GEOMETRY_FEATURE_DIMENSION, load_tokenizer, syntax_allowed_mask, verify_execution_device


def one_update(tokenizer_path: Path, seed: int, device: str) -> tuple[float, dict[str, torch.Tensor]]:
    torch.manual_seed(seed)
    tokenizer = load_tokenizer(tokenizer_path)
    model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=128, heads=4, dim_feedforward=256, dropout=0.1).to(device)
    model.train()
    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-4)

    traces = torch.linspace(0.0, 1.0, steps=2 * 3 * POINTS_PER_TRACE * 2, dtype=torch.float32).reshape(2, 3, POINTS_PER_TRACE, 2).to(device)
    geometry = torch.linspace(0.0, 1.0, steps=2 * 3 * TRACE_GEOMETRY_FEATURE_DIMENSION, dtype=torch.float32).reshape(2, 3, TRACE_GEOMETRY_FEATURE_DIMENSION).to(device)
    trace_mask = torch.zeros(2, 3, dtype=torch.bool, device=device)
    labels = [r"x^{2}", r"\\frac{a}{b}"]
    encoded = [tokenizer.encode(label) for label in labels]
    width = max(len(row) for row in encoded)
    tokens = torch.full((len(encoded), width), tokenizer.pad_id, dtype=torch.long, device=device)
    for row_index, row in enumerate(encoded):
        tokens[row_index, : len(row)] = torch.tensor(row, dtype=torch.long, device=device)
    target_input, target_output = tokens[:, :-1], tokens[:, 1:]
    target_mask = target_input == tokenizer.pad_id
    logits = model(traces, geometry, trace_mask, target_input, target_mask)
    allowed = syntax_allowed_mask(target_input, tokenizer)
    logits = logits.masked_fill(~allowed, torch.finfo(logits.dtype).min)
    loss = nn.CrossEntropyLoss(ignore_index=tokenizer.pad_id)(logits.reshape(-1, logits.shape[-1]), target_output.reshape(-1))
    loss.backward()
    optimizer.step()
    return loss.item(), {name: value.detach().cpu().clone() for name, value in model.state_dict().items()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()

    evidence = verify_execution_device(args.device)
    torch.use_deterministic_algorithms(True)
    first_loss, first_state = one_update(args.tokenizer, args.seed, args.device)
    second_loss, second_state = one_update(args.tokenizer, args.seed, args.device)
    per_tensor_max_difference = {
        name: float((first_state[name] - second_state[name]).abs().max().item())
        for name in first_state
    }
    report = {
        "status": "PASS",
        "deviceEvidence": evidence,
        "deterministicAlgorithms": True,
        "seed": args.seed,
        "losses": [first_loss, second_loss],
        "lossBitIdentical": first_loss == second_loss,
        "maxStateDifference": max(per_tensor_max_difference.values(), default=0.0),
        "stateBitIdentical": all(value == 0.0 for value in per_tensor_max_difference.values()),
        "datasetSplitsOpened": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["lossBitIdentical"] and report["stateBitIdentical"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
