#!/usr/bin/env python3
"""Measure CPU/MPS update divergence on one fixed valid mini-batch.

The audit is diagnostic only: it reads one selected valid batch, repeats that
batch for a bounded number of optimizer steps, and never opens test or writes
a checkpoint.  CPU and MPS begin from one identical state dictionary with the
same seed and deterministic-algorithms setting.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import torch
from torch import nn

try:
    from ModelConversion.formula_whole_model import FormulaWholeModel, load_tokenizer, require_checkpoint_input_contract, syntax_allowed_mask, verify_execution_device
    from ModelConversion.train_formula_whole_model import FormulaWholeDataset, collate
except ImportError:
    from formula_whole_model import FormulaWholeModel, load_tokenizer, require_checkpoint_input_contract, syntax_allowed_mask, verify_execution_device
    from train_formula_whole_model import FormulaWholeDataset, collate


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def update(model: FormulaWholeModel, optimizer: torch.optim.Optimizer, traces: torch.Tensor, geometry: torch.Tensor, trace_mask: torch.Tensor, tokens: torch.Tensor, tokenizer, seed: int) -> float:
    torch.manual_seed(seed)
    model.train()
    target_input, target_output = tokens[:, :-1], tokens[:, 1:]
    target_mask = target_input == tokenizer.pad_id
    optimizer.zero_grad()
    logits = model(traces, geometry, trace_mask, target_input, target_mask)
    allowed = syntax_allowed_mask(target_input, tokenizer)
    logits = logits.masked_fill(~allowed, torch.finfo(logits.dtype).min)
    loss = nn.CrossEntropyLoss(ignore_index=tokenizer.pad_id)(logits.reshape(-1, logits.shape[-1]), target_output.reshape(-1))
    loss.backward()
    optimizer.step()
    return float(loss.item())


def tensor_max_difference(left: torch.Tensor, right: torch.Tensor) -> float:
    return float((left.detach().cpu() - right.detach().cpu()).abs().max().item())


def model_max_difference(cpu: FormulaWholeModel, mps: FormulaWholeModel) -> float:
    return max(tensor_max_difference(cpu_value, mps.state_dict()[name]) for name, cpu_value in cpu.state_dict().items())


def optimizer_max_difference(cpu_model: FormulaWholeModel, cpu_optimizer: torch.optim.Optimizer, mps_model: FormulaWholeModel, mps_optimizer: torch.optim.Optimizer) -> float:
    differences: list[float] = []
    for (_cpu_name, cpu_parameter), (_mps_name, mps_parameter) in zip(cpu_model.named_parameters(), mps_model.named_parameters(), strict=True):
        cpu_state = cpu_optimizer.state[cpu_parameter]
        mps_state = mps_optimizer.state[mps_parameter]
        for key in ("exp_avg", "exp_avg_sq"):
            differences.append(tensor_max_difference(cpu_state[key], mps_state[key]))
    return max(differences, default=0.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--steps", type=int, default=16)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--d-model", type=int, default=128)
    parser.add_argument("--dropout", type=float, default=0.1, help="diagnostic-only model dropout; do not use this audit to change production training")
    args = parser.parse_args()

    if args.steps < 1:
        raise ValueError("steps must be positive")
    mps_evidence = verify_execution_device("mps")
    torch.use_deterministic_algorithms(True)
    tokenizer = load_tokenizer(args.tokenizer)
    contract = require_checkpoint_input_contract(args.checkpoint)
    dataset = FormulaWholeDataset(args.dataset_root / "mathwriting-2024" / "valid", tokenizer, limit=args.batch_size)
    traces, geometry, trace_mask, tokens, token_mask, _labels = collate([dataset[index] for index in range(len(dataset))])
    del token_mask
    state = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    cpu_model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=args.d_model, heads=4, dim_feedforward=256, dropout=args.dropout)
    cpu_model.load_state_dict(state)
    mps_model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=args.d_model, heads=4, dim_feedforward=256, dropout=args.dropout).to("mps")
    mps_model.load_state_dict(state)
    cpu_optimizer = torch.optim.AdamW(cpu_model.parameters(), lr=3e-4)
    mps_optimizer = torch.optim.AdamW(mps_model.parameters(), lr=3e-4)

    records = []
    first_parameter_divergence = None
    first_optimizer_divergence = None
    for step in range(1, args.steps + 1):
        cpu_loss = update(cpu_model, cpu_optimizer, traces, geometry, trace_mask, tokens, tokenizer, args.seed + step)
        mps_loss = update(mps_model, mps_optimizer, traces.to("mps"), geometry.to("mps"), trace_mask.to("mps"), tokens.to("mps"), tokenizer, args.seed + step)
        parameter_difference = model_max_difference(cpu_model, mps_model)
        optimizer_difference = optimizer_max_difference(cpu_model, cpu_optimizer, mps_model, mps_optimizer)
        if first_parameter_divergence is None and parameter_difference > 0.0:
            first_parameter_divergence = step
        if first_optimizer_divergence is None and optimizer_difference > 0.0:
            first_optimizer_divergence = step
        records.append({"step": step, "cpuLoss": cpu_loss, "mpsLoss": mps_loss, "lossAbsoluteDifference": abs(cpu_loss - mps_loss), "parameterMaxAbsoluteDifference": parameter_difference, "optimizerStateMaxAbsoluteDifference": optimizer_difference})

    report = {"status": "COMPLETED", "checkpoint": str(args.checkpoint), "checkpointSHA256": sha256(args.checkpoint), "checkpointContract": contract, "devices": {"cpu": "cpu", "mps": mps_evidence}, "input": {"split": "valid", "batchSize": len(dataset), "fixedMiniBatchRepeated": args.steps, "testOpened": False}, "deterministicAlgorithms": True, "seed": args.seed, "dropout": args.dropout, "steps": records, "firstParameterDivergenceStep": first_parameter_divergence, "firstOptimizerStateDivergenceStep": first_optimizer_divergence}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
