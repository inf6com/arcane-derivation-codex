#!/usr/bin/env python3
"""Compare one checkpoint's CPU and MPS forward outputs on the same valid batch.

This is an inference-only backend audit.  It reads the explicitly selected
``valid`` input batch, never opens ``test``, changes no weights, and records
encoder memory, decoder logits, syntax-masked logits, and teacher-forced loss
differences for CPU versus MPS.
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


def run(model: FormulaWholeModel, traces: torch.Tensor, geometry: torch.Tensor, trace_mask: torch.Tensor, tokens: torch.Tensor, tokenizer) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, float]:
    target_input, target_output = tokens[:, :-1], tokens[:, 1:]
    target_mask = target_input == tokenizer.pad_id
    with torch.inference_mode():
        memory, memory_mask = model.encoder(traces, geometry, trace_mask)
        logits = model.decoder(target_input, memory, memory_mask, target_mask)
        allowed = syntax_allowed_mask(target_input, tokenizer)
        masked_logits = logits.masked_fill(~allowed, torch.finfo(logits.dtype).min)
        loss = nn.CrossEntropyLoss(ignore_index=tokenizer.pad_id)(masked_logits.reshape(-1, masked_logits.shape[-1]), target_output.reshape(-1))
    return memory, logits, masked_logits, float(loss.item())


def max_difference(cpu: torch.Tensor, mps: torch.Tensor) -> float:
    return float((cpu - mps.detach().cpu()).abs().max().item())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--d-model", type=int, default=128)
    args = parser.parse_args()

    mps_evidence = verify_execution_device("mps")
    tokenizer = load_tokenizer(args.tokenizer)
    contract = require_checkpoint_input_contract(args.checkpoint)
    dataset = FormulaWholeDataset(args.dataset_root / "mathwriting-2024" / "valid", tokenizer, limit=args.batch_size)
    traces, geometry, trace_mask, tokens, token_mask, _labels = collate([dataset[index] for index in range(len(dataset))])
    del token_mask
    state = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    cpu_model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=args.d_model, heads=4, dim_feedforward=256, dropout=0.1)
    cpu_model.load_state_dict(state)
    cpu_model.eval()
    mps_model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=args.d_model, heads=4, dim_feedforward=256, dropout=0.1).to("mps")
    mps_model.load_state_dict(state)
    mps_model.eval()

    cpu_memory, cpu_logits, cpu_masked_logits, cpu_loss = run(cpu_model, traces, geometry, trace_mask, tokens, tokenizer)
    mps_memory, mps_logits, mps_masked_logits, mps_loss = run(mps_model, traces.to("mps"), geometry.to("mps"), trace_mask.to("mps"), tokens.to("mps"), tokenizer)
    report = {
        "status": "COMPLETED",
        "checkpoint": str(args.checkpoint),
        "checkpointSHA256": sha256(args.checkpoint),
        "checkpointContract": contract,
        "devices": {"cpu": "cpu", "mps": mps_evidence},
        "input": {"split": "valid", "batchSize": len(dataset), "testOpened": False},
        "comparison": {
            "encoderMemoryMaxAbsoluteDifference": max_difference(cpu_memory, mps_memory),
            "decoderLogitsMaxAbsoluteDifference": max_difference(cpu_logits, mps_logits),
            "syntaxMaskedLogitsMaxAbsoluteDifference": max_difference(cpu_masked_logits, mps_masked_logits),
            "teacherForcedLossCPU": cpu_loss,
            "teacherForcedLossMPS": mps_loss,
            "teacherForcedLossAbsoluteDifference": abs(cpu_loss - mps_loss),
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
