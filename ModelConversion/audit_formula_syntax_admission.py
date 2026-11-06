#!/usr/bin/env python3
"""Audit character-token syntax admission for one explicit MathWriting split.

This reads only the selected split, records every checked label count, and
persists the first rejected source instead of treating a process exit as
evidence. It does not train, evaluate, or open another split.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

try:
    from ModelConversion.formula_whole_input import load_formula_input
    from ModelConversion.formula_whole_model import load_tokenizer, syntax_allowed_mask
except ImportError:
    from formula_whole_input import load_formula_input
    from formula_whole_model import load_tokenizer, syntax_allowed_mask


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--split-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite audit evidence: {args.output}")

    tokenizer = load_tokenizer(args.tokenizer)
    checked = 0
    failure: dict[str, str] | None = None
    for path in sorted(args.split_root.glob("*.inkml")):
        formula, metadata = load_formula_input(path)
        del formula
        label = metadata["normalizedLabel"]
        try:
            tokens = torch.tensor([tokenizer.encode(label)[:-1]])
            syntax_allowed_mask(tokens, tokenizer)
        except (ValueError, RuntimeError) as error:
            failure = {"file": path.name, "label": label, "error": str(error)}
            break
        checked += 1

    report = {
        "splitRoot": str(args.split_root),
        "testOpened": False,
        "checkedLabels": checked,
        "expectedLabels": len(list(args.split_root.glob("*.inkml"))),
        "status": "PASS" if failure is None else "FAIL",
        "firstFailure": failure,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if failure is None else 1


if __name__ == "__main__":
    raise SystemExit(main())
