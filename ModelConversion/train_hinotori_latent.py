#!/usr/bin/env python3
"""MPS-only weak-primary training for latent 229-symbol decomposition."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import torch

from hinotori_anchor_loss import direct_anchor_metric_loss
from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_direct_membership_dataset import direct_membership_examples
from hinotori_latent_model import LatentHinotoriModel
from hinotori_latent_training import class_absence_loss, direct_membership_loss, weak_multiset_loss
from hinotori_weak_dataset import WeakFormulaDataset


def full_anchor_bank(dataset: DirectAnchorDataset) -> tuple[list[torch.Tensor], torch.Tensor]:
    groups: list[torch.Tensor] = []
    classes: list[int] = []
    for index in range(len(dataset)):
        row = dataset[index]
        points, class_index = row.get("points"), row.get("classIndex")
        if not isinstance(points, torch.Tensor) or not isinstance(class_index, int):
            raise ValueError("invalid direct anchor")
        groups.append(points)
        classes.append(class_index)
    missing = sorted(set(range(229)) - set(classes))
    if missing:
        raise ValueError(f"direct training anchors are missing classes: {missing}")
    return groups, torch.tensor(classes, dtype=torch.int64)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--initial-checkpoint", type=Path, help="Load model weights from a completed different class stage without resuming its optimizer or step schedule.")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--steps", type=int, required=True)
    parser.add_argument("--class-index", type=int, required=True, help="The 229-class stage whose weak subset is trained.")
    parser.add_argument("--resume", action="store_true", help="Resume model and optimizer state from --checkpoint.")
    parser.add_argument("--checkpoint-every", type=int, default=100)
    parser.add_argument("--learning-rate", type=float, default=1e-4)
    parser.add_argument("--weak-weight", type=float, default=1.0)
    parser.add_argument("--absence-weight", type=float, default=1.0)
    parser.add_argument("--membership-weight", type=float, default=1.0)
    parser.add_argument("--direct-retrieval-weight", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=20261004)
    args = parser.parse_args()
    if args.resume and args.initial_checkpoint is not None:
        raise ValueError("--resume and --initial-checkpoint are mutually exclusive")
    if args.steps < 1 or args.checkpoint_every < 1 or args.learning_rate <= 0 or not 0 <= args.class_index < 229:
        raise ValueError("steps, checkpoint-every, and learning-rate must be positive")
    if min(args.weak_weight, args.absence_weight, args.membership_weight, args.direct_retrieval_weight) < 0:
        raise ValueError("loss weights must be nonnegative")
    if args.weak_weight + args.absence_weight + args.membership_weight + args.direct_retrieval_weight == 0:
        raise ValueError("at least one loss weight must be positive")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for latent Hinotori training and is unavailable")
    torch.manual_seed(args.seed)
    device = torch.device("mps")
    direct_path = args.teachers / "direct-symbol-teachers.jsonl"
    direct = DirectAnchorDataset(direct_path, args.source_split, args.mathwriting_root, 32, "train")
    stage_direct_indices = [index for index in range(len(direct)) if direct[index].get("classIndex") == args.class_index]
    if not stage_direct_indices:
        raise ValueError(f"direct train set has no anchors for class index {args.class_index}")
    weak = WeakFormulaDataset(args.teachers / "train-weak-symbol-teachers.jsonl", args.mathwriting_root, args.teachers / "vocabulary.json", args.source_split, "train")
    stage_indices = weak.class_stage_indices()[args.class_index]
    stage_complement_indices = weak.class_stage_complement_indices()[args.class_index]
    if not stage_indices:
        raise ValueError(f"weak train set has no formulas for class index {args.class_index}")
    if not stage_complement_indices:
        raise ValueError(f"weak train set has no complement formulas for class index {args.class_index}")
    stage_step_count = max(len(stage_indices), len(stage_complement_indices))
    if args.steps > stage_step_count:
        raise ValueError(f"steps {args.steps} exceeds class-stage positive/negative schedule length {stage_step_count}")
    model = LatentHinotoriModel().to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate)
    anchors, anchor_classes = full_anchor_bank(direct)
    anchor_classes = anchor_classes.to(device)
    membership_examples = direct_membership_examples(direct_path, args.source_split, args.mathwriting_root)
    history: list[dict[str, float]] = []
    start_step = 0
    initial_checkpoint = None
    if args.initial_checkpoint is not None:
        if not args.initial_checkpoint.is_file():
            raise ValueError(f"initial checkpoint is missing: {args.initial_checkpoint}")
        initial = torch.load(args.initial_checkpoint, map_location="cpu", weights_only=False)
        if initial.get("contract") != "hinotori-latent-weak-primary-negative-v2" or initial.get("mpsRequired") is not True:
            raise ValueError("initial checkpoint has an incompatible contract")
        state = initial.get("modelState")
        if not isinstance(state, dict):
            raise ValueError("initial checkpoint is missing modelState")
        model.load_state_dict(state)
        initial_checkpoint = str(args.initial_checkpoint)
    elif args.resume:
        if not args.checkpoint.is_file():
            raise ValueError(f"resume checkpoint is missing: {args.checkpoint}")
        saved = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
        if saved.get("contract") != "hinotori-latent-weak-primary-negative-v2" or saved.get("mpsRequired") is not True:
            raise ValueError("resume checkpoint has an incompatible contract")
        start_step = saved.get("nextStep")
        state, optimizer_state = saved.get("modelState"), saved.get("optimizerState")
        if not isinstance(start_step, int) or start_step < 0 or not isinstance(state, dict) or not isinstance(optimizer_state, dict):
            raise ValueError("resume checkpoint is missing nextStep, modelState, or optimizerState")
        if saved.get("classIndex") != args.class_index:
            raise ValueError("resume checkpoint belongs to a different class stage")
        if start_step + args.steps > stage_step_count:
            raise ValueError("resumed step range exceeds class-stage weak count")
        model.load_state_dict(state)
        optimizer.load_state_dict(optimizer_state)
        for parameter_group in optimizer.param_groups:
            parameter_group["lr"] = args.learning_rate
    for local_step in range(args.steps):
        step = start_step + local_step
        weak_sample = weak[stage_indices[step % len(stage_indices)]]
        traces, target = weak_sample.get("traces"), weak_sample.get("targetCounts")
        if not isinstance(traces, list) or not isinstance(target, torch.Tensor):
            raise ValueError("invalid weak sample")
        absent_sample = weak[stage_complement_indices[step % len(stage_complement_indices)]]
        absent_traces, absent_target = absent_sample.get("traces"), absent_sample.get("targetCounts")
        if not isinstance(absent_traces, list) or not isinstance(absent_target, torch.Tensor) or absent_target[args.class_index].item() != 0:
            raise ValueError("invalid class-complement weak sample")
        direct_traces, direct_groups = membership_examples[step % len(membership_examples)]
        direct_sample = direct[stage_direct_indices[step % len(stage_direct_indices)]]
        query, query_class = direct_sample.get("points"), direct_sample.get("classIndex")
        if not isinstance(query, torch.Tensor) or not isinstance(query_class, int):
            raise ValueError("invalid direct sample")
        optimizer.zero_grad(set_to_none=True)
        logits, active, _ = model.weak_logits(traces, anchors, anchor_classes)
        weak_loss = weak_multiset_loss(logits, active, target) if args.weak_weight else torch.zeros((), device=device)
        absent_logits, absent_active, _ = model.weak_logits(absent_traces, anchors, anchor_classes)
        absence_loss = class_absence_loss(absent_logits, absent_active, args.class_index) if args.absence_weight else torch.zeros((), device=device)
        _, _, affinity = model.latent_instances(direct_traces)
        membership_loss = direct_membership_loss(affinity, direct_groups) if args.membership_weight else torch.zeros((), device=device)
        direct_embeddings = model.encode_groups([query])
        anchor_embeddings = model.encode_groups(anchors)
        retrieval_loss = direct_anchor_metric_loss(direct_embeddings, torch.tensor([query_class], device=device), anchor_embeddings, anchor_classes, model.temperature) if args.direct_retrieval_weight else torch.zeros((), device=device)
        total = args.weak_weight * weak_loss + args.absence_weight * absence_loss + args.membership_weight * membership_loss + args.direct_retrieval_weight * retrieval_loss
        if not torch.isfinite(total):
            raise RuntimeError(f"non-finite loss at step {step}")
        total.backward()
        optimizer.step()
        measurement = {"step": float(step + 1), "weak": float(weak_loss.detach().cpu()), "absence": float(absence_loss.detach().cpu()), "membership": float(membership_loss.detach().cpu()), "directRetrieval": float(retrieval_loss.detach().cpu()), "total": float(total.detach().cpu())}
        if (local_step + 1) % args.checkpoint_every == 0 or local_step + 1 == args.steps:
            history.append(measurement)
            args.checkpoint.parent.mkdir(parents=True, exist_ok=True)
            torch.save({"contract": "hinotori-latent-weak-primary-negative-v2", "mpsRequired": True, "classIndex": args.class_index, "nextStep": step + 1, "modelState": model.state_dict(), "optimizerState": optimizer.state_dict(), "weakSampling": weak.sampling_metadata}, args.checkpoint)
    report = {"contract": "hinotori-latent-weak-primary-negative-v2", "status": "MPS_TRAINING_NOT_EVALUATION", "mpsRequired": True, "classIndex": args.class_index, "classStageWeakFormulaCount": len(stage_indices), "classStageComplementFormulaCount": len(stage_complement_indices), "classStageScheduleStepCount": stage_step_count, "classStageDirectAnchorCount": len(stage_direct_indices), "classStageMembershipFormulaCount": len(membership_examples), "resumed": args.resume, "initialCheckpoint": initial_checkpoint, "startStep": start_step, "steps": args.steps, "nextStep": start_step + args.steps, "weakTrainFormulaCount": len(weak), "directAnchorCount": len(direct), "anchorBankCount": len(anchors), "lossWeights": {"weak": args.weak_weight, "absence": args.absence_weight, "membership": args.membership_weight, "directRetrieval": args.direct_retrieval_weight}, "history": history}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
