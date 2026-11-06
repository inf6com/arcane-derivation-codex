#!/usr/bin/env python3
"""Shape/wiring smoke test for FormulaWholeModel — NOT an accuracy evaluation.

This proves the encoder/decoder/masking/greedy-decode code is wired
correctly (forward pass runs, loss decreases, the model can memorize two
known examples) using the same two fixed InkML fixtures the FormulaInput v1
parity fixture already uses. It says nothing about real handwriting
recognition accuracy: two examples cannot generalize. Real training needs
the full train split and a GPU this cloud sandbox does not have.
"""
from __future__ import annotations

import sys
from pathlib import Path

import torch
from torch import nn

sys.path.insert(0, str(Path(__file__).parent))

try:  # `python3 -m ModelConversion.smoke_test_formula_whole_model` from the repo root
    from ModelConversion.formula_whole_input import load_formula_input, model_features, trace_geometry_features
    from ModelConversion.formula_whole_model import (
        FormulaWholeModel,
        FormulaTokenizer,
        MAX_TRACES,
        load_tokenizer,
        prepare_traces,
        prepare_trace_geometry,
    )
except ImportError:  # run directly from inside ModelConversion/
    from formula_whole_input import load_formula_input, model_features, trace_geometry_features
    from formula_whole_model import (
        FormulaWholeModel,
        FormulaTokenizer,
        MAX_TRACES,
        load_tokenizer,
        prepare_traces,
        prepare_trace_geometry,
    )

HERE = Path(__file__).parent
# On-device layout: this file lives in ModelConversion/; the fixed InkML
# fixtures live in ModelConversion/formula-whole-input-fixtures/, and the
# shared tokenizer artifact (built by the local automation loop) lives in
# runs/agent-control/ at the repo root.
FIXTURES_DIR = HERE / "formula-whole-input-fixtures"
TOKENIZER_PATH = HERE.parent / "runs" / "agent-control" / "formula-whole-label-tokenizer-20260927.json"


def load_example(name: str, tokenizer: FormulaTokenizer):
    formula, metadata = load_formula_input(FIXTURES_DIR / f"{name}.inkml")
    traces = model_features(formula)
    tokens = tokenizer.encode(metadata["normalizedLabel"])
    return prepare_traces(traces), prepare_trace_geometry(list(trace_geometry_features(formula))), torch.tensor(tokens, dtype=torch.long)


def collate(examples: list[tuple[torch.Tensor, torch.Tensor, torch.Tensor]]):
    batch = len(examples)
    max_traces = max(t.shape[0] for t, _, _ in examples)
    max_len = max(y.shape[0] for _, _, y in examples)
    traces_out = torch.zeros(batch, max_traces, examples[0][0].shape[1], 2)
    geometry_out = torch.zeros(batch, max_traces, examples[0][1].shape[1])
    trace_mask = torch.ones(batch, max_traces, dtype=torch.bool)
    tokens_out = torch.zeros(batch, max_len, dtype=torch.long)
    token_mask = torch.ones(batch, max_len, dtype=torch.bool)
    for i, (traces, geometry, tokens) in enumerate(examples):
        traces_out[i, : traces.shape[0]] = traces
        geometry_out[i, : geometry.shape[0]] = geometry
        trace_mask[i, : traces.shape[0]] = False
        tokens_out[i, : tokens.shape[0]] = tokens
        token_mask[i, : tokens.shape[0]] = False
    return traces_out, geometry_out, trace_mask, tokens_out, token_mask


def main() -> int:
    tokenizer = load_tokenizer(TOKENIZER_PATH)
    print(f"tokenizer: {tokenizer.vocab_size} tokens")

    examples = [load_example("wholeformula-fixture-a", tokenizer), load_example("wholeformula-fixture-b", tokenizer)]
    traces, geometry, trace_mask, tokens, token_mask = collate(examples)
    print("traces shape", tuple(traces.shape), "tokens shape", tuple(tokens.shape))
    assert traces.shape[1] <= MAX_TRACES

    torch.manual_seed(0)
    model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=64, heads=4, dim_feedforward=128)
    # lr=3e-3 previously "passed" at 200 steps, but that was a coincidence of
    # a chaotic training basin at this toy scale: switching the feature
    # extraction to model_features() (an ~1e-8 float32 rounding change, see
    # formula-whole-model-implementation-20260927.md) flipped it to a
    # non-memorizing basin at the same step count. Swept seeds 0-2 x
    # lr in {3e-3, 1e-3} x steps in {200, 400}: lr=1e-3 for >=300 steps
    # converges to exact match on both fixtures and stays converged for all
    # three seeds tried, so it is used here instead of tuning to one run's
    # noise. This is still just a wiring smoke test, not an accuracy result.
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3)
    criterion = nn.CrossEntropyLoss(ignore_index=tokenizer.pad_id, label_smoothing=0.1)

    target_input = tokens[:, :-1]
    target_output = tokens[:, 1:]
    target_input_mask = token_mask[:, :-1]

    losses = []
    for step in range(300):
        model.train()
        optimizer.zero_grad()
        logits = model(traces, geometry, trace_mask, target_input, target_input_mask)
        loss = criterion(logits.reshape(-1, logits.shape[-1]), target_output.reshape(-1))
        loss.backward()
        optimizer.step()
        losses.append(loss.item())
        if step % 40 == 0 or step == 299:
            print(f"step {step:3d} loss {loss.item():.4f}")

    assert losses[-1] < losses[0], "loss did not decrease at all: forward/backward wiring is broken"

    decoded = model.greedy_decode(traces, geometry, trace_mask, tokenizer, max_length=tokens.shape[1] + 4)
    expected_labels = ["x^{2}", "-"]
    results = []
    for row, expected in zip(decoded, expected_labels):
        predicted = tokenizer.decode(row)
        results.append((expected, predicted, predicted == expected))
        print(f"expected={expected!r} predicted={predicted!r} exactMatch={predicted == expected}")

    print(
        {
            "status": "PASS" if all(ok for _, _, ok in results) else "FAIL",
            "note": "memorization smoke test on 2 fixed examples only; not an accuracy measurement",
            "firstLoss": losses[0],
            "lastLoss": losses[-1],
        }
    )
    return 0 if all(ok for _, _, ok in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
