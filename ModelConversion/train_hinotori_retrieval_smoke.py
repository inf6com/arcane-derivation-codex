#!/usr/bin/env python3
"""Run one real MPS optimization step for the Hinotori retrieval design.

This is an implementation smoke test, not an accuracy evaluation and not a
model-release path.  It refuses to run unless MPS is actually available.
"""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import torch

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_inkml import read_inkml_traces
from hinotori_model import HinotoriRetrievalModel
from hinotori_training import direct_grouping_loss, direct_retrieval_loss, weak_class_presence_loss, weak_formula_loss
from hinotori_weak_dataset import WeakFormulaDataset


def direct_grouping_example(teachers: Path, source_split: Path, mathwriting_root: Path) -> tuple[list[torch.Tensor], list[list[int]]]:
    rows = [json.loads(line) for line in teachers.read_text(encoding="utf-8").splitlines() if line]
    split = json.loads(source_split.read_text(encoding="utf-8"))["sourceSplit"]
    by_source: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        if split[row["sourceSampleId"]] == "train":
            by_source[row["sourceSampleId"]].append(row)
    source = next(source for source, entries in sorted(by_source.items()) if len(entries) > 1)
    traces_by_id = read_inkml_traces(mathwriting_root / "train" / f"{source}.inkml")
    ids = sorted(traces_by_id)
    positions = {trace_id: position for position, trace_id in enumerate(ids)}
    return [traces_by_id[trace_id] for trace_id in ids], [[positions[index] for index in entry["strokeIndices"]] for entry in by_source[source]]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--membership-subsets", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for Hinotori training smoke and is unavailable")
    torch.manual_seed(20261003)
    device = torch.device("mps")
    direct_path = args.teachers / "direct-symbol-teachers.jsonl"
    vocabulary_path = args.teachers / "vocabulary.json"
    direct_train = DirectAnchorDataset(direct_path, args.source_split, args.mathwriting_root, 32, "train")
    weak_train = WeakFormulaDataset(args.teachers / "train-weak-symbol-teachers.jsonl", args.mathwriting_root, vocabulary_path, args.source_split, "train")
    weak_by_class, membership_metadata = weak_train.materialized_class_stage_indices(args.membership_subsets)
    model = HinotoriRetrievalModel().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3)
    bank = [direct_train[index]["points"] for index in range(len(direct_train))]
    bank_classes = torch.tensor([direct_train[index]["classIndex"] for index in range(len(direct_train))], dtype=torch.int64, device=device)
    query = [direct_train[index]["points"] for index in range(8)]
    query_classes = torch.tensor([direct_train[index]["classIndex"] for index in range(8)], dtype=torch.int64, device=device)
    traces, annotations = direct_grouping_example(direct_path, args.source_split, args.mathwriting_root)
    stage_class = next(class_index for class_index, indices in weak_by_class.items() if indices)
    weak = weak_train[weak_by_class[stage_class][0]]
    optimizer.zero_grad(set_to_none=True)
    retrieval = direct_retrieval_loss(model, query, query_classes, bank, bank_classes)
    grouping = direct_grouping_loss(model, traces, annotations)
    weak_loss = weak_formula_loss(model, weak["traces"], weak["targetCounts"], bank, bank_classes)
    stage_logits, _, _ = model.formula_retrieval_logits(weak["traces"], bank, bank_classes)
    presence = weak_class_presence_loss(stage_logits, stage_class)
    total = retrieval + grouping + weak_loss + presence
    total.backward()
    optimizer.step()
    if not torch.isfinite(total):
        raise RuntimeError("non-finite Hinotori smoke loss")
    report = {"contract": "hinotori-retrieval-v1", "mode": "MPS_IMPLEMENTATION_SMOKE_NOT_EVALUATION", "mpsBuilt": True, "mpsAvailable": True,
              "directBankCount": len(bank), "weakFormulaCountAvailable": len(weak_train), "weakUnsupportedExcluded": weak_train.excluded_unsupported,
              "stageClass": stage_class, "membershipSubsets": membership_metadata,
              "loss": {"directRetrieval": float(retrieval.detach().cpu()), "directGrouping": float(grouping.detach().cpu()), "weakMultiset": float(weak_loss.detach().cpu()), "weakClassPresence": float(presence.detach().cpu()), "total": float(total.detach().cpu())}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
