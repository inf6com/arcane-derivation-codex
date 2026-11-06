#!/usr/bin/env python3
"""Train a source-disjoint formula-frame stroke grouping model on MPS."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import time
from dataclasses import dataclass
from pathlib import Path

import torch
from torch import Tensor

from hinotori_formula_segmenter import HinotoriFormulaSegmenter, direct_pair_targets, resample_formula_strokes
from hinotori_inkml import read_inkml_traces


@dataclass
class Example:
    source: str
    points: Tensor
    target: Tensor
    supervised: Tensor


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_examples(teachers_path: Path, split_path: Path, inkml_root: Path, point_count: int, maximum_strokes: int) -> tuple[dict[str, list[Example]], dict[str, object]]:
    split_doc = json.loads(split_path.read_text(encoding="utf-8"))
    split = split_doc.get("sourceSplit")
    if not isinstance(split, dict) or any(value not in {"train", "valid", "test"} for value in split.values()):
        raise ValueError("sourceSplit must map source IDs to train/valid/test")
    by_source: dict[str, list[dict[str, object]]] = {}
    for line in teachers_path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        row = json.loads(line)
        source = row.get("sourceSampleId")
        if not isinstance(source, str) or source not in split:
            raise ValueError("direct teacher references a source absent from the fit split")
        if split[source] in {"train", "valid"}:
            by_source.setdefault(source, []).append(row)

    output: dict[str, list[Example]] = {"train": [], "valid": []}
    excluded = {"single_teacher_source": 0, "overlapping_or_unannotated_pair_set": 0}
    for source, rows in sorted(by_source.items()):
        if len(rows) < 2:
            excluded["single_teacher_source"] += 1
            continue
        trace_map = read_inkml_traces(inkml_root / "train" / f"{source}.inkml")
        trace_ids = sorted(trace_map)
        if len(trace_ids) > maximum_strokes:
            raise ValueError(f"{source} has {len(trace_ids)} strokes, above declared maximum {maximum_strokes}")
        position = {trace_id: index for index, trace_id in enumerate(trace_ids)}
        groups: list[list[int]] = []
        for row in rows:
            raw = row.get("strokeIndices")
            if not isinstance(raw, list) or not raw or any(not isinstance(value, int) or value not in position for value in raw):
                raise ValueError(f"{source} has invalid direct stroke membership")
            groups.append([position[value] for value in raw])
        owned = [index for group in groups for index in group]
        if len(owned) != len(set(owned)) or not any(len(group) > 1 for group in groups):
            excluded["overlapping_or_unannotated_pair_set"] += 1
            continue
        target, supervised = direct_pair_targets(len(trace_ids), groups)
        if not supervised.any() or not (target[supervised] == 1).any() or not (target[supervised] == 0).any():
            raise ValueError(f"{source} does not contain both positive and negative supervised pairs")
        example = Example(source, resample_formula_strokes([trace_map[index] for index in trace_ids], point_count), target, supervised)
        output[split[source]].append(example)

    if not output["train"] or not output["valid"]:
        raise ValueError("both train and source-disjoint inner-validation grouping examples are required")
    metadata = {
        "fitTeacherSHA256": sha256(teachers_path),
        "sourceSplitSHA256": sha256(split_path),
        "trainFormulaCount": len(output["train"]),
        "validFormulaCount": len(output["valid"]),
        "trainSupervisedPairs": sum(int(item.supervised.sum()) for item in output["train"]),
        "validSupervisedPairs": sum(int(item.supervised.sum()) for item in output["valid"]),
        "trainSameSymbolPairs": sum(int(item.target[item.supervised].sum()) for item in output["train"]),
        "validSameSymbolPairs": sum(int(item.target[item.supervised].sum()) for item in output["valid"]),
        "excluded": excluded,
        "outerTestRead": False,
    }
    return output, metadata


def pack(batch: list[Example], maximum_strokes: int, device: torch.device) -> tuple[Tensor, Tensor, Tensor, Tensor]:
    count = max(item.points.shape[0] for item in batch)
    if count > maximum_strokes:
        raise ValueError("batch exceeds maximum strokes")
    points = torch.zeros((len(batch), count, batch[0].points.shape[1], 2), dtype=torch.float32)
    valid = torch.zeros((len(batch), count), dtype=torch.float32)
    targets = torch.zeros((len(batch), count, count), dtype=torch.float32)
    supervised = torch.zeros((len(batch), count, count), dtype=torch.bool)
    for i, item in enumerate(batch):
        n = item.points.shape[0]
        points[i, :n] = item.points
        valid[i, :n] = 1
        targets[i, :n, :n] = item.target
        supervised[i, :n, :n] = item.supervised
    return tuple(value.to(device) for value in (points, valid, targets, supervised))


def pair_metrics(model: HinotoriFormulaSegmenter, examples: list[Example], maximum_strokes: int, threshold: float, device: torch.device) -> dict[str, float | int]:
    tp = fp = fn = correct_pairs = pair_count = exact = 0
    model.eval()
    with torch.no_grad():
        for item in examples:
            points, valid, target, supervised = pack([item], maximum_strokes, device)
            logits = model(points, valid)[0]
            predicted = logits > threshold
            gold = target[0].bool()
            mask = supervised[0]
            tp += int((predicted & gold & mask).sum())
            fp += int((predicted & ~gold & mask).sum())
            fn += int((~predicted & gold & mask).sum())
            correct_pairs += int(((predicted == gold) & mask).sum())
            pair_count += int(mask.sum())

            n = item.points.shape[0]
            parent = list(range(n))
            def root(value: int) -> int:
                while parent[value] != value:
                    parent[value] = parent[parent[value]]
                    value = parent[value]
                return value
            for left in range(n):
                for right in range(left + 1, n):
                    if bool(predicted[left, right]):
                        a, b = root(left), root(right)
                        if a != b:
                            parent[b] = a
            indices = torch.where(item.supervised.any(dim=0))[0].tolist()
            exact += int(all((root(i) == root(j)) == bool(item.target[i, j]) for i in indices for j in indices if i != j))
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"threshold": threshold, "supervisedPairCount": pair_count, "pairPrecision": precision, "pairRecall": recall, "pairF1": f1, "pairAccuracy": correct_pairs / pair_count if pair_count else 0.0, "exactAnnotatedPartitionFormulaCount": exact, "exactAnnotatedPartitionAccuracy": exact / len(examples)}


def _average_linkage_merges(affinity: Tensor) -> list[tuple[float, int, int]]:
    count = affinity.shape[0]
    # MPS-to-CPU conversion must keep float32; casting float32 MPS tensors to
    # float64 in the transfer path can corrupt values on the installed build.
    scores = affinity.detach().to(device="cpu").tolist()
    cluster_ids = list(range(count))
    pair_sums = [row[:] for row in scores]
    pair_counts = [[1] * count for _ in range(count)]
    merges: list[tuple[float, int, int]] = []
    while len(cluster_ids) > 1:
        best_score = -float("inf")
        best_left = best_right = -1
        for left in range(len(cluster_ids) - 1):
            for right in range(left + 1, len(cluster_ids)):
                mean = pair_sums[left][right] / pair_counts[left][right]
                if mean > best_score:
                    best_score, best_left, best_right = mean, left, right
        if not (best_score == best_score and abs(best_score) != float("inf")):
            raise RuntimeError("non-finite average-link affinity")
        left_id, right_id = cluster_ids[best_left], cluster_ids[best_right]
        merges.append((best_score, left_id, right_id))
        cluster_ids[best_left] = min(cluster_ids[best_left], cluster_ids[best_right])
        for other in range(len(cluster_ids)):
            if other in (best_left, best_right):
                continue
            pair_sums[best_left][other] += pair_sums[best_right][other]
            pair_sums[other][best_left] = pair_sums[best_left][other]
            pair_counts[best_left][other] += pair_counts[best_right][other]
            pair_counts[other][best_left] = pair_counts[best_left][other]
        pair_sums.pop(best_right)
        for row in pair_sums:
            row.pop(best_right)
        pair_counts.pop(best_right)
        for row in pair_counts:
            row.pop(best_right)
        cluster_ids.pop(best_right)
    return merges


def partition_metrics(
    model: HinotoriFormulaSegmenter,
    examples: list[Example],
    maximum_strokes: int,
    device: torch.device,
    thresholds: tuple[float, ...],
) -> list[dict[str, float | int]]:
    if not thresholds or any(not torch.isfinite(torch.tensor(value)) for value in thresholds):
        raise ValueError("partition thresholds must be nonempty and finite")
    counts = {threshold: {"tp": 0, "fp": 0, "fn": 0, "exact": 0} for threshold in thresholds}
    model.eval()
    with torch.no_grad():
        for item in examples:
            points, valid, target, supervised = pack([item], maximum_strokes, device)
            logits = model(points, valid)[0, : item.points.shape[0], : item.points.shape[0]]
            affinity = (logits + logits.transpose(0, 1)) * 0.5
            merges = _average_linkage_merges(affinity)
            target_cpu = target[0, : item.points.shape[0], : item.points.shape[0]].bool().cpu()
            supervised_cpu = supervised[0, : item.points.shape[0], : item.points.shape[0]].cpu()
            known = torch.where(supervised_cpu.any(dim=0))[0].tolist()
            for threshold in thresholds:
                parent = list(range(item.points.shape[0]))
                def root(index: int) -> int:
                    while parent[index] != index:
                        parent[index] = parent[parent[index]]
                        index = parent[index]
                    return index
                for score, left_id, right_id in merges:
                    if score <= threshold:
                        break
                    left_root, right_root = root(left_id), root(right_id)
                    if left_root != right_root:
                        parent[right_root] = left_root
                predicted = torch.tensor([[root(i) == root(j) for j in range(len(parent))] for i in range(len(parent))])
                target_mask = target_cpu & supervised_cpu
                stats = counts[threshold]
                stats["tp"] += int((predicted & target_mask).sum())
                stats["fp"] += int((predicted & ~target_cpu & supervised_cpu).sum())
                stats["fn"] += int((~predicted & target_mask).sum())
                stats["exact"] += int(all((root(i) == root(j)) == bool(target_cpu[i, j]) for i in known for j in known if i != j))
    result = []
    for threshold in thresholds:
        stats = counts[threshold]
        precision = stats["tp"] / (stats["tp"] + stats["fp"]) if stats["tp"] + stats["fp"] else 0.0
        recall = stats["tp"] / (stats["tp"] + stats["fn"]) if stats["tp"] + stats["fn"] else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        result.append({
            "threshold": threshold,
            "supervisedPairCount": sum(int(item.supervised.sum()) for item in examples),
            "pairPrecision": precision,
            "pairRecall": recall,
            "pairF1": f1,
            "exactAnnotatedPartitionFormulaCount": stats["exact"],
            "exactAnnotatedPartitionAccuracy": stats["exact"] / len(examples),
        })
    return result


def main() -> int:
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=80)
    parser.add_argument("--patience", type=int, default=12)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--maximum-strokes", type=int, default=80)
    parser.add_argument("--point-count", type=int, default=32)
    parser.add_argument("--learning-rate", type=float, default=0.001)
    parser.add_argument("--positive-pair-weight", type=float)
    parser.add_argument("--ranking-loss-weight", type=float, default=0.0)
    parser.add_argument("--ranking-margin", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=20261105)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite run directory: {args.output}")
    if min(args.epochs, args.patience, args.batch_size, args.maximum_strokes, args.point_count) < 1 or args.learning_rate <= 0:
        raise ValueError("training parameters must be positive")
    if not torch.isfinite(torch.tensor(args.ranking_loss_weight)) or args.ranking_loss_weight < 0:
        raise ValueError("ranking-loss weight must be finite and nonnegative")
    if not torch.isfinite(torch.tensor(args.ranking_margin)) or args.ranking_margin <= 0:
        raise ValueError("ranking margin must be finite and positive")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required; CPU training is not permitted")

    torch.manual_seed(args.seed)
    random.seed(args.seed)
    device = torch.device("mps")
    datasets, data_metadata = load_examples(args.teachers, args.source_split, args.mathwriting_root, args.point_count, args.maximum_strokes)
    positive = data_metadata["trainSameSymbolPairs"]
    total = data_metadata["trainSupervisedPairs"]
    negative = total - positive
    if positive <= 0 or negative <= 0:
        raise ValueError("training split must contain positive and negative pairs")
    positive_weight = args.positive_pair_weight if args.positive_pair_weight is not None else negative / positive
    if not torch.isfinite(torch.tensor(positive_weight)) or positive_weight <= 0:
        raise ValueError("positive-pair weight must be finite and positive")
    partition_thresholds = (-2.0, -1.0, -0.5, 0.0, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 6.0, 8.0, 12.0)

    model = HinotoriFormulaSegmenter(args.point_count).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate)
    args.output.mkdir(parents=True)
    contract = "hinotori-formula-frame-pair-segmenter-v3" if args.ranking_loss_weight > 0 else "hinotori-formula-frame-pair-segmenter-v2"
    run = {"contract": contract, "architecture": "shared-1d-convolutional-stroke-encoder-plus-symmetric-pair-MLP", "device": "mps", "seed": args.seed, "pointCount": args.point_count, "maximumFormulaStrokes": args.maximum_strokes, "positivePairWeight": positive_weight, "rankingLossWeight": args.ranking_loss_weight, "rankingMargin": args.ranking_margin, "partitionThresholds": partition_thresholds, "checkpointSelection": "inner-valid exact average-link partition count, then cluster-pair F1", "data": data_metadata}
    (args.output / "run.json").write_text(json.dumps(run, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    best = (-1, -1.0)
    best_epoch = 0
    stale = 0
    history: list[dict[str, object]] = []
    rng = random.Random(args.seed)
    for epoch in range(1, args.epochs + 1):
        model.train()
        order = list(range(len(datasets["train"])))
        rng.shuffle(order)
        epoch_loss = 0.0
        step_count = 0
        for start in range(0, len(order), args.batch_size):
            batch = [datasets["train"][i] for i in order[start:start + args.batch_size]]
            points, valid, targets, supervised = pack(batch, args.maximum_strokes, device)
            optimizer.zero_grad(set_to_none=True)
            logits = model(points, valid)
            loss = torch.nn.functional.binary_cross_entropy_with_logits(
                logits[supervised], targets[supervised],
                pos_weight=torch.tensor(positive_weight, dtype=logits.dtype, device=device),
            )
            ranking_loss = torch.zeros((), dtype=logits.dtype, device=device)
            if args.ranking_loss_weight > 0:
                known_positive = targets.bool() & supervised
                known_negative = ~targets.bool() & supervised
                positive_floor = logits.masked_fill(~known_positive, float("inf")).amin(dim=-1)
                negative_ceiling = logits.masked_fill(~known_negative, -float("inf")).amax(dim=-1)
                rankable = known_positive.any(dim=-1) & known_negative.any(dim=-1)
                if not rankable.any():
                    raise ValueError("batch has no anchor with both positive and negative pair supervision")
                ranking_loss = torch.nn.functional.softplus(
                    args.ranking_margin - (positive_floor[rankable] - negative_ceiling[rankable])
                ).mean()
                loss = loss + args.ranking_loss_weight * ranking_loss
            if not torch.isfinite(loss):
                raise RuntimeError(f"non-finite grouping loss at epoch {epoch}")
            loss.backward()
            optimizer.step()
            epoch_loss += float(loss.detach().cpu())
            step_count += 1

        threshold_scores = partition_metrics(model, datasets["valid"], args.maximum_strokes, device, partition_thresholds)
        calibrated = max(threshold_scores, key=lambda row: (int(row["exactAnnotatedPartitionFormulaCount"]), float(row["pairF1"]), -abs(float(row["threshold"]))))
        row = {"epoch": epoch, "trainLoss": epoch_loss / step_count, "validPartitionThresholds": threshold_scores, "selectedValidationPartition": calibrated}
        history.append(row)
        with (args.output / "metrics.jsonl").open("a", encoding="utf-8") as output:
            output.write(json.dumps(row, ensure_ascii=False) + "\n")
        score = (int(calibrated["exactAnnotatedPartitionFormulaCount"]), float(calibrated["pairF1"]))
        if score > best:
            best, best_epoch, stale = score, epoch, 0
            checkpoint_path = args.output / "best.pt"
            temporary = args.output / "best.pt.tmp"
            torch.save({"contract": run["contract"], "modelState": model.state_dict(), "epoch": epoch, "threshold": calibrated["threshold"], "validation": calibrated, "data": data_metadata, "run": run}, temporary)
            temporary.replace(checkpoint_path)
        else:
            stale += 1
        print(json.dumps(row, ensure_ascii=False), flush=True)
        if stale >= args.patience:
            break

    best_checkpoint = torch.load(args.output / "best.pt", map_location=device, weights_only=False)
    model.load_state_dict(best_checkpoint["modelState"], strict=True)
    final = {
        "contract": run["contract"],
        "mode": "MPS_TRAINED_INNER_VALID_EVALUATION_OUTER_TEST_UNOPENED",
        "bestEpoch": best_epoch,
        "bestThreshold": best_checkpoint["threshold"],
        "bestValidation": best_checkpoint["validation"],
        "bestValidationPartition": best_checkpoint["validation"],
        "epochsCompleted": len(history),
        "elapsedSeconds": time.monotonic() - started,
        "data": data_metadata,
        "history": history,
        "outerTestRead": False,
    }
    (args.output / "summary.json").write_text(json.dumps(final, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
