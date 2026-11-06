#!/usr/bin/env python3
"""Measure whether real FormulaInput trace counts can support direct LaTeX CTC."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from ModelConversion.formula_whole_model import load_tokenizer
from ModelConversion.train_formula_whole_model import FormulaWholeDataset


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-samples", type=int, default=16)
    args = parser.parse_args()
    tokenizer = load_tokenizer(args.tokenizer)
    dataset = FormulaWholeDataset(args.dataset_root / "mathwriting-2024/train", tokenizer, limit=args.max_samples)
    records = []
    invalid = []
    for index in range(len(dataset)):
        traces, tokens, label = dataset[index]
        target = tokens[1:-1]
        repeats = sum(target[position].item() == target[position - 1].item() for position in range(1, len(target)))
        required_steps = len(target) + repeats
        record = {"index": index, "label": label, "traceCount": int(traces.shape[0]), "targetTokenCount": len(target), "adjacentRepeatedTargets": repeats, "ctcRequiredInputSteps": required_steps, "feasible": int(traces.shape[0]) >= required_steps}
        records.append(record)
        if not record["feasible"]:
            invalid.append(record)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"status":"COMPLETED", "model":"encoder-only CTC over real FormulaInput trace sequence", "split":"train only; test not opened", "count":len(records), "blankToken":"CTC blank is distinct from final-LaTex tokens", "records":records, "invalidTargetCount":len(invalid), "invalidTargets":invalid, "decision":"REJECTED" if invalid else "FEASIBLE_FOR_MINIMAL_TRAIN16", "reason":"CTC requires input steps >= target tokens plus adjacent-repeat separators; FormulaInput has one encoder time step per trace."}, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
