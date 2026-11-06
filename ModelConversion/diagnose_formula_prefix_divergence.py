#!/usr/bin/env python3
"""Compare teacher-forced and greedy prefixes on one real whole-formula checkpoint.

The split is explicit so that the diagnostic can inspect held-out validation
errors without silently substituting training examples.  Test is deliberately
not accepted here.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

try:
    from ModelConversion.formula_whole_model import FormulaWholeModel, MAX_LABEL_TOKENS, load_tokenizer, syntax_allowed_mask, verify_execution_device
    from ModelConversion.train_formula_whole_model import FormulaWholeDataset
except ImportError:
    from formula_whole_model import FormulaWholeModel, MAX_LABEL_TOKENS, load_tokenizer, syntax_allowed_mask, verify_execution_device
    from train_formula_whole_model import FormulaWholeDataset


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--split", choices=("train", "valid"), required=True)
    parser.add_argument("--max-samples", type=int, default=16)
    parser.add_argument("--start-index", type=int, default=0)
    parser.add_argument("--d-model", type=int, default=128)
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()
    tokenizer = load_tokenizer(args.tokenizer)
    device_evidence = verify_execution_device(args.device)
    split_root = args.dataset_root / "mathwriting-2024" / args.split
    dataset = FormulaWholeDataset(split_root, tokenizer)
    if args.start_index < 0 or args.start_index + args.max_samples > len(dataset):
        raise ValueError(
            f"requested [{args.start_index}, {args.start_index + args.max_samples}) outside {args.split} size {len(dataset)}"
        )
    model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=args.d_model, heads=4, dim_feedforward=256, dropout=0.1).to(args.device)
    model.load_state_dict(torch.load(args.checkpoint, map_location=args.device, weights_only=True))
    model.eval()
    results: list[dict[str, object]] = []
    for index in range(args.start_index, args.start_index + args.max_samples):
        traces, tokens, label = dataset[index]
        encoded = tokenizer.encode(label)
        reversible = tokenizer.encode(tokenizer.decode(encoded)) == encoded
        if not reversible:
            raise ValueError(f"non-reversible tokenization at train index {index}: {label!r}")
        traces = traces.unsqueeze(0).to(args.device)
        trace_padding = torch.zeros((1, traces.shape[1]), dtype=torch.bool, device=args.device)
        teacher = tokens[:-1].unsqueeze(0).to(args.device)
        target = tokens[1:].tolist()
        with torch.inference_mode():
            memory, memory_mask = model.encoder(traces, trace_padding)
            teacher_logits = model.decoder(teacher, memory, memory_mask, torch.zeros_like(teacher, dtype=torch.bool))
            teacher_mask = syntax_allowed_mask(teacher, tokenizer)
            teacher_logits = teacher_logits.masked_fill(~teacher_mask, torch.finfo(teacher_logits.dtype).min)
            teacher_argmax = teacher_logits.argmax(dim=-1)[0].tolist()
            greedy = [tokenizer.bos_id]
            steps: list[dict[str, object]] = []
            first_divergence: int | None = None
            for position, expected in enumerate(target):
                prefix = torch.tensor([greedy], dtype=torch.long, device=args.device)
                greedy_logits = model.decoder(prefix, memory, memory_mask, torch.zeros_like(prefix, dtype=torch.bool))
                greedy_mask = syntax_allowed_mask(prefix, tokenizer)
                greedy_logits = greedy_logits.masked_fill(~greedy_mask, torch.finfo(greedy_logits.dtype).min)
                chosen = int(greedy_logits[0, -1].argmax().item())
                teacher_choice = teacher_argmax[position]
                teacher_allowed = teacher_mask[0, position].nonzero(as_tuple=False).flatten().tolist()
                greedy_allowed = greedy_mask[0, -1].nonzero(as_tuple=False).flatten().tolist()
                branch = chosen != expected
                if branch and first_divergence is None:
                    first_divergence = position
                steps.append({
                    "position": position,
                    "target": tokenizer.tokens[expected],
                    "teacherPrefixArgmax": tokenizer.tokens[teacher_choice],
                    "teacherPrefixCorrect": teacher_choice == expected,
                    "teacherTargetAllowed": bool(teacher_mask[0, position, expected].item()),
                    "teacherTargetLogit": float(teacher_logits[0, position, expected].item()),
                    "teacherArgmaxLogit": float(teacher_logits[0, position, teacher_choice].item()),
                    "teacherAllowedTokens": [tokenizer.tokens[token] for token in teacher_allowed],
                    "greedyPrefix": tokenizer.decode(greedy),
                    "greedyPrefixArgmax": tokenizer.tokens[chosen],
                    "greedyTargetAllowed": bool(greedy_mask[0, -1, expected].item()),
                    "greedyTargetLogit": float(greedy_logits[0, -1, expected].item()),
                    "greedyArgmaxLogit": float(greedy_logits[0, -1, chosen].item()),
                    "greedyAllowedTokens": [tokenizer.tokens[token] for token in greedy_allowed],
                    "greedyChoseEOS": chosen == tokenizer.eos_id,
                })
                greedy.append(chosen)
                if chosen == tokenizer.eos_id or len(greedy) >= MAX_LABEL_TOKENS:
                    break
            results.append({"index": index, "label": label, "latexLength": len(label), "traceCount": int(traces.shape[1]), "pointCount": int(traces.shape[1] * traces.shape[2]), "tokenizationReversible": reversible, "firstDivergence": first_divergence, "steps": steps})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"status": "COMPLETED", "deviceEvidence": device_evidence, "checkpoint": str(args.checkpoint), "split": args.split, "startIndex": args.start_index, "count": len(results), "records": results}, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
