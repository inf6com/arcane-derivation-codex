#!/usr/bin/env python3
"""Numerically validate a FormulaWholeTraceDecoder Core ML candidate.

This deliberately uses real held-out MathWriting validation inks.  It never
opens the test split and never treats Core ML conversion as successful merely
because the package loads.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

try:
    from ModelConversion.formula_whole_model import MAX_LABEL_TOKENS, MAX_TRACES, POINTS_PER_TRACE, TRACE_GEOMETRY_FEATURE_DIMENSION, FormulaWholeModel, load_tokenizer
    from ModelConversion.train_formula_whole_model import FormulaWholeDataset, collate
except ImportError:
    from formula_whole_model import MAX_LABEL_TOKENS, MAX_TRACES, POINTS_PER_TRACE, TRACE_GEOMETRY_FEATURE_DIMENSION, FormulaWholeModel, load_tokenizer
    from train_formula_whole_model import FormulaWholeDataset, collate


def fixed_inputs(traces, geometry, tokens, tokenizer):
    if traces.shape[0] != 1 or tokens.shape[0] != 1:
        raise ValueError("Core ML validation accepts one formula at a time")
    trace_count = traces.shape[1]
    prefix_length = tokens.shape[1] - 1
    result_traces = torch.zeros((1, MAX_TRACES, POINTS_PER_TRACE, 2), dtype=torch.float32)
    result_geometry = torch.zeros((1, MAX_TRACES, TRACE_GEOMETRY_FEATURE_DIMENSION), dtype=torch.float32)
    trace_valid = torch.zeros((1, MAX_TRACES), dtype=torch.float32)
    target_tokens = torch.full((1, MAX_LABEL_TOKENS), tokenizer.pad_id, dtype=torch.long)
    target_valid = torch.zeros((1, MAX_LABEL_TOKENS), dtype=torch.float32)
    result_traces[:, :trace_count] = traces
    result_geometry[:, :trace_count] = geometry
    trace_valid[:, :trace_count] = 1.0
    target_tokens[:, :prefix_length] = tokens[:, :-1]
    target_valid[:, :prefix_length] = 1.0
    return result_traces, result_geometry, trace_valid, target_tokens, target_valid, prefix_length


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--count", type=int, default=16)
    parser.add_argument("--max-abs-diff", type=float, default=2e-4)
    args = parser.parse_args()
    if args.count < 1:
        raise ValueError("--count must be positive")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite evidence: {args.output}")
    tokenizer = load_tokenizer(args.tokenizer)
    dataset = FormulaWholeDataset(args.dataset_root / "mathwriting-2024" / "valid", tokenizer, limit=args.count)
    torch_model = FormulaWholeModel(tokenizer.vocab_size, 128, 4, 256, 0.1).eval()
    torch_model.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True), strict=True)
    coreml = ct.models.MLModel(str(args.model), compute_units=ct.ComputeUnit.CPU_ONLY)
    samples = []
    maximum = 0.0
    all_ranks_match = True
    for index in range(len(dataset)):
        traces, geometry, _trace_mask, tokens, _token_mask, labels = collate([dataset[index]])
        fixed_traces, fixed_geometry, trace_valid, target_tokens, target_valid, prefix_length = fixed_inputs(traces, geometry, tokens, tokenizer)
        with torch.inference_mode():
            reference = torch_model(fixed_traces, fixed_geometry, trace_valid < 0.5, target_tokens, target_valid < 0.5).numpy()
        output = coreml.predict({
            "traces": fixed_traces.numpy(),
            "traceGeometry": fixed_geometry.numpy(),
            "traceValid": trace_valid.numpy(),
            "targetTokens": target_tokens.numpy().astype(np.int32),
            "targetValid": target_valid.numpy(),
        })["tokenLogits"]
        difference = float(np.max(np.abs(output - reference)))
        ranks_match = bool(np.array_equal(output.argmax(axis=-1), reference.argmax(axis=-1)))
        maximum = max(maximum, difference)
        all_ranks_match = all_ranks_match and ranks_match
        samples.append({"index": index, "label": labels[0], "prefixLength": prefix_length, "maxAbsDiff": difference, "rankMatch": ranks_match})
    report = {
        "status": "COMPLETED",
        "split": "valid",
        "testReadPolicy": "test split not opened",
        "count": len(dataset),
        "maxAbsDiff": maximum,
        "rankMatchAll": all_ranks_match,
        "acceptance": {"maxAbsDiff": args.max_abs_diff, "rankMatchAll": True},
        "adoptionGate": "PASS" if maximum <= args.max_abs_diff and all_ranks_match else "FAIL",
        "samples": samples,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in ("count", "maxAbsDiff", "rankMatchAll", "adoptionGate")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
