#!/usr/bin/env python3
"""Train the MPS-only Hinotori retrieval model on direct and weak teachers.

Each optimization step combines: (1) direct-anchor retrieval geometry,
(2) direct stroke-group affinity, and (3) one final-LaTeX symbol-multiset
teacher.  It has no trainable 229-way output head.
"""
from __future__ import annotations

import argparse
import json
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import torch

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_inkml import read_inkml_traces
from hinotori_model import HinotoriRetrievalModel
from hinotori_anchor_loss import direct_anchor_metric_loss
from hinotori_training import direct_grouping_loss, weak_class_presence_loss, weak_formula_loss
from hinotori_weak_dataset import WeakFormulaDataset


def class_complete_bank(dataset: DirectAnchorDataset) -> tuple[list[torch.Tensor], torch.Tensor, set[int]]:
    """Return every direct symbol exemplar as the class retrieval bank.

    A class's handwritten variants (for example one-, two-, and three-stroke
    ``\\sqrt``) are all legitimate anchors.  Collapsing them to one exemplar
    discards the very variation the retrieval model must recognize.
    """
    groups: list[torch.Tensor] = []
    classes: list[int] = []
    for index in range(len(dataset)):
        sample = dataset[index]
        class_index = sample["classIndex"]
        points = sample["points"]
        if not isinstance(class_index, int) or not isinstance(points, torch.Tensor):
            raise ValueError("direct anchor classIndex must be int")
        groups.append(points)
        classes.append(class_index)
    observed = set(classes)
    missing = sorted(set(range(229)) - observed)
    if missing:
        raise ValueError(f"training direct anchors are missing classes: {missing}")
    return groups, torch.tensor(classes, dtype=torch.int64), set(range(len(groups)))


def grouped_direct_examples(teachers_path: Path, source_split_path: Path) -> list[tuple[str, list[list[int]]]]:
    """Return validated direct grouping specifications without loading InkML.

    Direct symbol entries can legitimately overlap when they are independent
    recognition anchors, but an affinity target requires one unambiguous owner
    per trace.  Such a formula is excluded from this loss rather than merging
    entries or inventing a stroke partition.
    """
    split = json.loads(source_split_path.read_text(encoding="utf-8")).get("sourceSplit")
    if not isinstance(split, dict):
        raise ValueError("source split has no sourceSplit map")
    by_source: dict[str, list[dict[str, object]]] = defaultdict(list)
    for line in teachers_path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        row = json.loads(line)
        source = row.get("sourceSampleId")
        if not isinstance(source, str) or split.get(source) != "train":
            continue
        by_source[source].append(row)
    examples: list[tuple[str, list[list[int]]]] = []
    for source, rows in sorted(by_source.items()):
        if len(rows) < 2:
            continue
        groups: list[list[int]] = []
        for row in rows:
            indices = row.get("strokeIndices")
            if not isinstance(indices, list) or not indices or not all(isinstance(value, int) for value in indices):
                raise ValueError(f"invalid direct grouping annotation for {source}")
            groups.append(indices)
        owned = [trace for group in groups for trace in group]
        if len(owned) != len(set(owned)):
            continue
        if not any(len(group) > 1 for group in groups):
            continue
        examples.append((source, groups))
    if not examples:
        raise ValueError("no multi-symbol direct formulas for affinity supervision")
    return examples


def load_grouped_direct_example(source: str, stroke_groups: list[list[int]], mathwriting_root: Path) -> tuple[list[torch.Tensor], list[list[int]]]:
    """Load exactly one validated affinity example for one optimization step."""
    traces_by_id = read_inkml_traces(mathwriting_root / "train" / f"{source}.inkml")
    trace_ids = sorted(traces_by_id)
    position = {trace_id: index for index, trace_id in enumerate(trace_ids)}
    if any(trace_id not in position for group in stroke_groups for trace_id in group):
        raise ValueError(f"direct grouping annotation refers to missing InkML trace: {source}")
    return [traces_by_id[trace_id] for trace_id in trace_ids], [[position[trace_id] for trace_id in group] for group in stroke_groups]


def direct_queries_by_class(dataset: DirectAnchorDataset) -> dict[int, list[int]]:
    """Return every direct anchor available for each class-stage query."""
    queries: dict[int, list[int]] = {class_index: [] for class_index in range(229)}
    for row_index in range(len(dataset)):
        class_index = dataset[row_index]["classIndex"]
        if not isinstance(class_index, int) or not 0 <= class_index < 229:
            raise ValueError("direct query has invalid classIndex")
        queries[class_index].append(row_index)
    return queries


def load_stage_batch(
    schedule_entries: list[tuple[int, torch.Tensor]],
    weak: WeakFormulaDataset,
    affinity_examples: list[tuple[str, list[list[int]]]],
    mathwriting_root: Path,
    data_workers: int,
) -> list[tuple[int, int, int, tuple[list[torch.Tensor], list[list[int]]], dict[str, object] | None]]:
    """Read one optimizer batch concurrently while preserving schedule order."""
    def load(row_position: int, schedule_row: torch.Tensor) -> tuple[int, int, int, tuple[list[torch.Tensor], list[list[int]]], dict[str, object] | None]:
        stage_class, weak_row, stage_visit = (int(value) for value in schedule_row.tolist())
        affinity_source, affinity_stroke_groups = affinity_examples[row_position % len(affinity_examples)]
        affinity = load_grouped_direct_example(affinity_source, affinity_stroke_groups, mathwriting_root)
        weak_sample = weak[weak_row] if weak_row >= 0 else None
        return stage_class, weak_row, stage_visit, affinity, weak_sample

    workers = min(len(schedule_entries), data_workers)
    with ThreadPoolExecutor(max_workers=workers) as executor:
        return list(executor.map(lambda item: load(*item), schedule_entries))


def main() -> int:
    started_at = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--membership-subsets", type=Path, required=True, help="Verified LaTeX-membership subset artifact generated from the same weak teachers.")
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--initial-checkpoint", type=Path, help="Load model weights for a new weak-training run without resuming its optimizer or schedule.")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--weak-steps", type=int, required=True, help="Number of class-conditioned membership pairs to consume; 1531255 is one complete membership pass.")
    parser.add_argument("--batch-size", type=int, default=16, help="Membership pairs accumulated into one MPS optimizer update.")
    parser.add_argument("--data-workers", type=int, default=8, help="Concurrent InkML readers for each optimizer batch.")
    parser.add_argument("--checkpoint-every", type=int, default=2048, help="Persist state after this many consumed membership pairs; must be positive.")
    parser.add_argument("--resume", action="store_true", help="Resume exactly from the supplied checkpoint.")
    parser.add_argument("--learning-rate", type=float, default=1e-3)
    parser.add_argument("--direct-retrieval-weight", type=float, default=1.0)
    parser.add_argument("--direct-grouping-weight", type=float, default=1.0)
    parser.add_argument("--weak-multiset-weight", type=float, default=1.0)
    parser.add_argument("--weak-class-presence-weight", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=20261003)
    args = parser.parse_args()
    if args.resume and args.initial_checkpoint is not None:
        raise ValueError("--resume and --initial-checkpoint are mutually exclusive")
    if args.weak_steps < 1 or args.batch_size < 1 or args.data_workers < 1 or args.checkpoint_every < 1 or args.learning_rate <= 0:
        raise ValueError("weak-steps, batch-size, data-workers, checkpoint-every, and learning-rate must be positive")
    if min(args.direct_retrieval_weight, args.direct_grouping_weight, args.weak_multiset_weight, args.weak_class_presence_weight) < 0:
        raise ValueError("loss weights must be nonnegative")
    if args.direct_retrieval_weight + args.direct_grouping_weight + args.weak_multiset_weight + args.weak_class_presence_weight == 0:
        raise ValueError("at least one loss weight must be positive")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for Hinotori training and is unavailable")

    torch.manual_seed(args.seed)
    generator = torch.Generator().manual_seed(args.seed)
    device = torch.device("mps")
    direct_path = args.teachers / "direct-symbol-teachers.jsonl"
    vocabulary_path = args.teachers / "vocabulary.json"
    direct = DirectAnchorDataset(direct_path, args.source_split, args.mathwriting_root, 32, "train")
    weak = WeakFormulaDataset(args.teachers / "train-weak-symbol-teachers.jsonl", args.mathwriting_root, vocabulary_path, args.source_split, "train")
    model = HinotoriRetrievalModel().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate)
    bank, bank_classes, _ = class_complete_bank(direct)
    bank_classes = bank_classes.to(device)
    queries_by_class = direct_queries_by_class(direct)
    class_schedule, class_schedule_metadata = weak.class_conditioned_schedule(args.membership_subsets)
    affinity_examples = grouped_direct_examples(direct_path, args.source_split)
    history: list[dict[str, float]] = []
    start_step = 0
    if args.initial_checkpoint is not None:
        if not args.initial_checkpoint.is_file():
            raise ValueError(f"initial checkpoint is missing: {args.initial_checkpoint}")
        initial = torch.load(args.initial_checkpoint, map_location="cpu", weights_only=False)
        if initial.get("contract") != "hinotori-retrieval-v1" or initial.get("mpsRequired") is not True:
            raise ValueError("initial checkpoint has an incompatible contract")
        state = initial.get("modelState")
        if not isinstance(state, dict):
            raise ValueError("initial checkpoint is missing modelState")
        model.load_state_dict(state)
    elif args.resume:
        if not args.checkpoint.is_file():
            raise ValueError(f"resume checkpoint is missing: {args.checkpoint}")
        checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
        if checkpoint.get("contract") != "hinotori-retrieval-v1" or checkpoint.get("mpsRequired") is not True:
            raise ValueError("resume checkpoint has an incompatible contract")
        start_step = checkpoint.get("nextWeakPair")
        generator_state = checkpoint.get("generatorState")
        if not isinstance(start_step, int) or not isinstance(generator_state, torch.Tensor) or start_step < 0:
            raise ValueError("resume checkpoint is missing nextWeakStep or generatorState")
        if checkpoint.get("classSchedule") != class_schedule_metadata or checkpoint.get("stageContract") != "hinotori-shared-retrieval-membership-batch-pass-v2":
            raise ValueError("resume checkpoint has a different weak sampling schedule")
        if start_step + args.weak_steps > len(class_schedule):
            raise ValueError("resumed weak-step range exceeds class-conditioned membership schedule")
        model.load_state_dict(checkpoint["modelState"])
        optimizer.load_state_dict(checkpoint["optimizerState"])
        # A resumed phase may intentionally use a different learning rate.
        # The checkpoint optimizer state otherwise silently restores the prior
        # rate despite the explicit command-line contract.
        for parameter_group in optimizer.param_groups:
            parameter_group["lr"] = args.learning_rate
        generator.set_state(generator_state)
    elif args.weak_steps > len(class_schedule):
        raise ValueError(f"weak-steps {args.weak_steps} exceeds class-conditioned membership schedule size {len(class_schedule)}")

    consumed = 0
    optimizer_updates = 0
    while consumed < args.weak_steps:
        pair_count = min(args.batch_size, args.weak_steps - consumed)
        entries = [(start_step + consumed + offset, class_schedule[start_step + consumed + offset]) for offset in range(pair_count)]
        stage_batch = load_stage_batch(entries, weak, affinity_examples, args.mathwriting_root, args.data_workers)
        optimizer.zero_grad(set_to_none=True)
        anchor_embeddings = model.encode_groups(bank)
        zero = torch.zeros((), device=device)
        retrieval_total = zero
        grouping_total = zero
        multiset_total = zero
        presence_total = zero
        staged_classes: list[int] = []
        for stage_class, weak_row, stage_visit, (traces, annotations), weak_sample in stage_batch:
            staged_classes.append(stage_class)
            stage_direct = queries_by_class[stage_class]
            retrieval = zero
            if args.direct_retrieval_weight and len(stage_direct) > 1:
                query_row = stage_direct[stage_visit % len(stage_direct)]
                query_embeddings = model.encode_groups([bank[query_row]])
                retrieval = direct_anchor_metric_loss(
                    query_embeddings,
                    torch.tensor([stage_class], dtype=torch.int64, device=device),
                    torch.cat((anchor_embeddings[:query_row], anchor_embeddings[query_row + 1:])),
                    torch.cat((bank_classes[:query_row], bank_classes[query_row + 1:])),
                    model.temperature,
                )
            grouping = direct_grouping_loss(model, traces, annotations) if args.direct_grouping_weight else zero
            multiset = zero
            presence = zero
            if weak_row >= 0:
                if not isinstance(weak_sample, dict):
                    raise ValueError("class-stage weak sample was not loaded")
                target_counts = weak_sample.get("targetCounts")
                weak_traces = weak_sample.get("traces")
                if not isinstance(target_counts, torch.Tensor) or not isinstance(weak_traces, list) or target_counts[stage_class].item() < 1:
                    raise ValueError("class-stage weak sample does not contain its staged class")
                if args.weak_multiset_weight:
                    multiset = weak_formula_loss(model, weak_traces, target_counts, bank, bank_classes, anchor_embeddings)
                if args.weak_class_presence_weight:
                    stage_logits, _, _ = model.formula_retrieval_logits(weak_traces, bank, bank_classes, anchor_embeddings)
                    presence = weak_class_presence_loss(stage_logits, stage_class)
            retrieval_total = retrieval_total + retrieval
            grouping_total = grouping_total + grouping
            multiset_total = multiset_total + multiset
            presence_total = presence_total + presence
        total = (args.direct_retrieval_weight * retrieval_total + args.direct_grouping_weight * grouping_total + args.weak_multiset_weight * multiset_total + args.weak_class_presence_weight * presence_total) / pair_count
        if not torch.isfinite(total):
            raise RuntimeError(f"non-finite loss after membership pair {start_step + consumed}")
        total.backward()
        optimizer.step()
        consumed += pair_count
        optimizer_updates += 1
        completed = start_step + consumed
        measured = {"nextWeakPair": float(completed), "optimizerUpdate": float(optimizer_updates), "batchPairCount": float(pair_count), "stageClassMin": float(min(staged_classes)), "stageClassMax": float(max(staged_classes)), "directRetrieval": float((retrieval_total / pair_count).detach().cpu()), "directGrouping": float((grouping_total / pair_count).detach().cpu()), "weakMultiset": float((multiset_total / pair_count).detach().cpu()), "weakClassPresence": float((presence_total / pair_count).detach().cpu()), "total": float(total.detach().cpu())}
        if consumed % args.checkpoint_every == 0 or consumed == args.weak_steps:
            history.append(measured)
            args.checkpoint.parent.mkdir(parents=True, exist_ok=True)
            torch.save({"contract": "hinotori-retrieval-v1", "mpsRequired": True, "stageContract": "hinotori-shared-retrieval-membership-batch-pass-v2", "nextWeakPair": completed, "batchSize": args.batch_size, "dataWorkers": args.data_workers, "learningRate": args.learning_rate, "lossWeights": {"directRetrieval": args.direct_retrieval_weight, "directGrouping": args.direct_grouping_weight, "weakMultiset": args.weak_multiset_weight, "weakClassPresence": args.weak_class_presence_weight}, "classSchedule": class_schedule_metadata, "modelState": model.state_dict(), "optimizerState": optimizer.state_dict(), "generatorState": generator.get_state()}, args.checkpoint)

    report = {"contract": "hinotori-retrieval-v1", "mode": "MPS_TRAINING_NOT_EVALUATION", "stageContract": "hinotori-shared-retrieval-membership-batch-pass-v2", "mpsBuilt": True, "mpsAvailable": True, "initialCheckpoint": str(args.initial_checkpoint) if args.initial_checkpoint is not None else None, "weakPairsThisRun": args.weak_steps, "nextWeakPair": start_step + args.weak_steps, "batchSize": args.batch_size, "dataWorkers": args.data_workers, "optimizerUpdates": optimizer_updates, "elapsedSeconds": time.monotonic() - started_at, "learningRate": args.learning_rate, "lossWeights": {"directRetrieval": args.direct_retrieval_weight, "directGrouping": args.direct_grouping_weight, "weakMultiset": args.weak_multiset_weight, "weakClassPresence": args.weak_class_presence_weight}, "classSchedule": class_schedule_metadata, "weakTrainFullyMapped": len(weak), "weakUnsupportedExcluded": weak.excluded_unsupported, "weakHeldoutSourceExcluded": weak.excluded_heldout, "directTrainAnchors": len(direct), "classCompleteTrainingBank": len(bank), "directQueryNoLeaveOneOutClassIndices": [class_index for class_index, indices in queries_by_class.items() if len(indices) < 2], "weakMissingClassIndices": class_schedule_metadata["directOnlyClassIndices"], "history": history}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
