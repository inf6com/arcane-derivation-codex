#!/usr/bin/env python3
"""Pretrain the whole-formula trace encoder on real MathWriting symbols.

The annotation supplies an actual source formula, its stroke indices, and an
observed symbol label. It does not supply fabricated layout or relation labels.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch
from torch import nn

from ModelConversion.formula_whole_input import load_formula_input, model_features
from ModelConversion.formula_whole_model import TraceEncoder, prepare_traces, verify_execution_device


def collect_examples(root: Path, maximum: int) -> tuple[list[torch.Tensor], list[str], list[str]]:
    samples: list[torch.Tensor] = []
    labels: list[str] = []
    sources: list[str] = []
    for line in (root / "symbols.jsonl").read_text(encoding="utf-8").splitlines():
        if len(samples) == maximum:
            break
        record = json.loads(line)
        indices, label, source = record.get("strokeIndices"), record.get("label"), record.get("sourceSampleId")
        if not isinstance(indices, list) or not indices or not isinstance(label, str) or not label or not isinstance(source, str):
            raise ValueError(f"invalid symbol annotation: {record!r}")
        formula, _ = load_formula_input(root / "train" / f"{source}.inkml")
        traces = model_features(formula)
        if any(not isinstance(index, int) or index < 0 or index >= len(traces) for index in indices):
            raise ValueError(f"out-of-range symbol stroke index: {source} {indices}")
        samples.append(prepare_traces([list(traces[index]) for index in indices]))
        labels.append(label)
        sources.append(source)
    if len(samples) != maximum:
        raise RuntimeError(f"collected {len(samples)} actual symbol records, expected {maximum}")
    return samples, labels, sources


def collate_symbol_traces(samples: list[torch.Tensor]) -> tuple[torch.Tensor, torch.Tensor]:
    points = {sample.shape[1] for sample in samples}
    if len(points) != 1:
        raise ValueError(f"incompatible point counts: {points}")
    maximum = max(sample.shape[0] for sample in samples)
    inputs = torch.zeros(len(samples), maximum, next(iter(points)), 2)
    padding = torch.ones(len(samples), maximum, dtype=torch.bool)
    for row, sample in enumerate(samples):
        inputs[row, : sample.shape[0]] = sample
        padding[row, : sample.shape[0]] = False
    return inputs, padding


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--max-records", type=int, default=16)
    parser.add_argument("--device", default="mps")
    args = parser.parse_args()
    if args.max_records < 2:
        raise ValueError("--max-records must be at least 2")
    device_evidence = verify_execution_device(args.device)
    samples, labels, source_ids = collect_examples(args.dataset_root / "mathwriting-2024", args.max_records)
    classes = sorted(set(labels))
    if len(classes) < 2:
        raise ValueError("bounded real symbol set has fewer than two observed labels")
    class_id = {label: index for index, label in enumerate(classes)}
    inputs, padding = collate_symbol_traces(samples)
    targets = torch.tensor([class_id[label] for label in labels], dtype=torch.long)
    encoder = TraceEncoder(d_model=128).to(args.device)
    classifier = nn.Linear(128, len(classes)).to(args.device)
    encoded, _ = encoder(inputs.to(args.device), padding.to(args.device))
    valid = (~padding.to(args.device)).unsqueeze(-1)
    pooled = (encoded * valid).sum(dim=1) / valid.sum(dim=1).clamp_min(1)
    loss = nn.functional.cross_entropy(classifier(pooled), targets.to(args.device))
    if not torch.isfinite(loss):
        raise FloatingPointError(f"non-finite observed-symbol loss: {loss.item()}")
    loss.backward()
    if not any(parameter.grad is not None and torch.isfinite(parameter.grad).all() for parameter in encoder.parameters()):
        raise RuntimeError("symbol objective did not produce finite encoder gradients")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(encoder.state_dict(), args.output)
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps({"status": "COMPLETED", "deviceEvidence": device_evidence, "records": len(samples), "observedClassCount": len(classes), "sourceSampleIDs": source_ids, "inputShape": list(inputs.shape), "loss": loss.item(), "encoderCheckpoint": str(args.output), "transferContract": "FormulaWholeModel.encoder state keys and tensor shapes must exactly match"}, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
