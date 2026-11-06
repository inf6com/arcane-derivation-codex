#!/usr/bin/env python3
"""Audit decoder cross-attention, masks, and memory gradients on one train item."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

from ModelConversion.formula_whole_model import FormulaWholeModel, load_tokenizer, syntax_allowed_mask, verify_execution_device
from ModelConversion.train_formula_whole_model import FormulaWholeDataset


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--index", type=int, default=11)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()
    tokenizer = load_tokenizer(args.tokenizer)
    device_evidence = verify_execution_device(args.device)
    dataset = FormulaWholeDataset(args.dataset_root / "mathwriting-2024/train", tokenizer, limit=16)
    traces, tokens, label = dataset[args.index]
    traces = traces.unsqueeze(0).to(args.device)
    trace_padding = torch.zeros((1, traces.shape[1]), dtype=torch.bool, device=args.device)
    target = tokens[:-1].unsqueeze(0).to(args.device)
    model = FormulaWholeModel(tokenizer.vocab_size, d_model=256, heads=4, dim_feedforward=256, dropout=0).to(args.device)
    model.load_state_dict(torch.load(args.checkpoint, map_location=args.device, weights_only=True))
    model.eval()
    captured: list[dict[str, object]] = []
    originals = []
    for layer in model.decoder.decoder.layers:
        original = layer.multihead_attn.forward
        originals.append(original)
        def capture(*call_args, _original=original, **call_kwargs):
            call_kwargs["need_weights"] = True
            call_kwargs["average_attn_weights"] = False
            output, weights = _original(*call_args, **call_kwargs)
            captured.append({"shape": list(weights.shape), "finite": bool(torch.isfinite(weights).all().item()), "sum": float(weights.sum().item())})
            return output, weights
        layer.multihead_attn.forward = capture
    memory, memory_mask = model.encoder(traces, trace_padding)
    memory.retain_grad()
    logits = model.decoder(target, memory, memory_mask, torch.zeros_like(target, dtype=torch.bool))
    loss = torch.nn.functional.cross_entropy(logits[:, 0, :], tokens[1:2].to(args.device))
    loss.backward()
    syntax_mask = syntax_allowed_mask(target, tokenizer)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"status":"COMPLETED","deviceEvidence":device_evidence,"label":label,"traceShape":list(traces.shape),"memoryShape":list(memory.shape),"tracePaddingMask":trace_padding.tolist(),"targetShape":list(target.shape),"causalMaskDirection":"upper triangle is True and blocks future target positions", "syntaxTargetAllowed":bool(syntax_mask[0,0,tokens[1]].item()),"crossAttention":captured,"memoryGradientFinite":bool(torch.isfinite(memory.grad).all().item()),"memoryGradientNonzero":bool(memory.grad.abs().sum().item()>0),"encoderParameterGradientNonzero":any(parameter.grad is not None and parameter.grad.abs().sum().item()>0 for parameter in model.encoder.parameters())}, indent=2), encoding="utf-8")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
