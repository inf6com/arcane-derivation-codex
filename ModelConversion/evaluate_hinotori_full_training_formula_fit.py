#!/usr/bin/env python3
"""Evaluate Hinotori's complete official weak-formula training split.

The metric is formula-level multiset agreement: proposed stroke groups are
classified against the complete 229-class retrieval bank, then their predicted
symbol multiset is compared with the final-LaTeX teacher multiset. This does
not claim stroke-to-symbol alignment or held-out generalization.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import time

import torch

from hinotori_direct_dataset import DirectAnchorDataset
from hinotori_inkml import canonical_group_tensor
from hinotori_model import HinotoriRetrievalModel
from hinotori_retrieval import class_retrieval_logits
from hinotori_weak_dataset import WeakFormulaDataset


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def decode_affinity_cpu(affinity_logits: torch.Tensor, trace_count: int) -> list[list[int]]:
    """Decode the same >0 affinity graph as decode_groups with one CPU transfer."""
    if affinity_logits.ndim != 2 or affinity_logits.shape[0] != affinity_logits.shape[1] or not 1 <= trace_count <= affinity_logits.shape[0]:
        raise ValueError("affinity matrix dimensions do not match formula traces")
    matrix = affinity_logits[:trace_count, :trace_count].detach().to(device="cpu")
    if not torch.isfinite(matrix).all():
        raise ValueError("valid formula affinity matrix contains non-finite values")
    parent = list(range(trace_count))

    def find(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    edges = torch.triu(matrix > 0.0, diagonal=1).nonzero(as_tuple=False).tolist()
    for left, right in edges:
        left_root, right_root = find(left), find(right)
        if left_root != right_root:
            parent[right_root] = left_root
    groups: dict[int, list[int]] = {}
    for index in range(trace_count):
        groups.setdefault(find(index), []).append(index)
    return list(groups.values())


def infer_formula_batch(
    model: HinotoriRetrievalModel,
    samples: list[dict[str, object]],
    anchor_groups: list[torch.Tensor],
    anchor_classes: torch.Tensor,
    anchor_embeddings: torch.Tensor,
) -> list[tuple[list[int], int]]:
    """Batch encoder and retrieval work while preserving per-formula grouping."""
    if not samples:
        raise ValueError("formula inference batch must not be empty")
    trace_lists: list[list[torch.Tensor]] = []
    singleton_groups: list[torch.Tensor] = []
    ranges: list[tuple[int, int]] = []
    cursor = 0
    for sample in samples:
        traces = sample.get("traces")
        targets = sample.get("targetCounts")
        if not isinstance(traces, list) or not traces or not isinstance(targets, torch.Tensor) or targets.shape != (229,):
            raise ValueError("weak formula batch contains invalid traces or target multiset")
        trace_lists.append(traces)
        singleton_groups.extend(canonical_group_tensor([trace], model.point_count) for trace in traces)
        ranges.append((cursor, cursor + len(traces)))
        cursor += len(traces)
    stroke_embeddings = model.encode_groups(singleton_groups)
    maximum_traces = max(end - start for start, end in ranges)
    device = stroke_embeddings.device
    padded_embeddings = torch.zeros((len(samples), maximum_traces, stroke_embeddings.shape[1]), dtype=stroke_embeddings.dtype, device=device)
    padding = torch.ones((len(samples), maximum_traces), dtype=torch.bool, device=device)
    for batch_index, (start, end) in enumerate(ranges):
        count = end - start
        padded_embeddings[batch_index, :count] = stroke_embeddings[start:end]
        padding[batch_index, :count] = False
    affinity = model.group_proposer(padded_embeddings, padding)
    groupings = [decode_affinity_cpu(affinity[index], end - start) for index, (start, end) in enumerate(ranges)]
    proposed_groups: list[torch.Tensor] = []
    group_counts: list[int] = []
    for traces, grouping in zip(trace_lists, groupings):
        groups = [canonical_group_tensor([traces[trace_index] for trace_index in member_indices], model.point_count) for member_indices in grouping]
        group_counts.append(len(groups))
        proposed_groups.extend(groups)
    grouped_embeddings = model.encode_groups(proposed_groups)
    logits = class_retrieval_logits(grouped_embeddings, anchor_embeddings, anchor_classes, 229, model.temperature)
    predictions = logits.argmax(dim=1).detach().cpu().tolist()
    result: list[tuple[list[int], int]] = []
    cursor = 0
    for group_count in group_counts:
        result.append(([int(value) for value in predictions[cursor:cursor + group_count]], group_count))
        cursor += group_count
    if cursor != len(predictions):
        raise ValueError("batched formula candidate rows do not match the proposed group count")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--shard-size", type=int, default=128)
    parser.add_argument("--formula-batch-size", type=int, default=16)
    parser.add_argument("--anchor-batch-size", type=int, default=64)
    args = parser.parse_args()
    if args.shard_size < 1 or args.formula_batch_size < 1 or args.anchor_batch_size < 1:
        raise ValueError("shard-size, formula-batch-size, and anchor-batch-size must be positive")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for full Hinotori training-data evaluation")
    for path in (args.teachers / "train-weak-symbol-teachers.jsonl", args.teachers / "direct-symbol-teachers.jsonl", args.teachers / "vocabulary.json", args.source_split, args.checkpoint):
        if not path.is_file():
            raise FileNotFoundError(f"required evaluation input is missing: {path}")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    weak = WeakFormulaDataset(
        args.teachers / "train-weak-symbol-teachers.jsonl",
        args.mathwriting_root,
        args.teachers / "vocabulary.json",
        args.source_split,
        "train",
    )
    direct = DirectAnchorDataset(
        args.teachers / "direct-symbol-teachers.jsonl",
        args.source_split,
        args.mathwriting_root,
        32,
        "train",
    )
    teacher_vocabulary = json.loads((args.teachers / "vocabulary.json").read_text(encoding="utf-8"))
    hinotori_vocabulary_path = Path(__file__).resolve().parent.parent / "Models" / "Hinotori" / "HinotoriVocabulary.json"
    hinotori_vocabulary = json.loads(hinotori_vocabulary_path.read_text(encoding="utf-8"))
    labels = hinotori_vocabulary.get("labels")
    if (
        teacher_vocabulary.get("version") != "symbol229-v1"
        or hinotori_vocabulary.get("version") != "hinotori-v1"
        or not isinstance(labels, list)
        or len(labels) != 229
        or len(set(labels)) != 229
        or teacher_vocabulary.get("labels") != labels
    ):
        raise ValueError("teacher and Hinotori vocabularies are not the same ordered 229 labels")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("contract") != "hinotori-retrieval-v1" or checkpoint.get("mpsRequired") is not True:
        raise ValueError("checkpoint is not a Hinotori MPS training artifact")
    model = HinotoriRetrievalModel().to("mps")
    model.load_state_dict(checkpoint["modelState"], strict=True)
    model.eval()

    anchor_groups = [direct[index]["points"] for index in range(len(direct))]
    anchor_classes = torch.tensor([int(row["classIndex"]) for row in direct.rows], dtype=torch.int64, device="mps")
    anchor_parts: list[torch.Tensor] = []
    with torch.inference_mode():
        for start in range(0, len(anchor_groups), args.anchor_batch_size):
            anchor_parts.append(model.encode_groups(anchor_groups[start:start + args.anchor_batch_size]))
    anchor_embeddings = torch.cat(anchor_parts, dim=0)
    if anchor_embeddings.shape[0] != len(anchor_groups) or set(anchor_classes.detach().cpu().tolist()) != set(range(229)):
        raise ValueError("full official training retrieval bank does not cover all 229 classes")

    shard_paths = sorted(args.output_dir.glob("predictions-*.jsonl"))
    manifest_path = args.output_dir / "manifest.json"
    input_manifest = {
        "contract": "hinotori-full-training-formula-fit-evaluation-v1",
        "checkpointSHA256": sha256(args.checkpoint),
        "teacherSHA256": sha256(args.teachers / "train-weak-symbol-teachers.jsonl"),
        "directTeacherSHA256": sha256(args.teachers / "direct-symbol-teachers.jsonl"),
        "sourceSplitSHA256": sha256(args.source_split),
        "vocabularySHA256": sha256(args.teachers / "vocabulary.json"),
        "hinotoriVocabularySHA256": sha256(hinotori_vocabulary_path),
        "expectedFormulaCount": len(weak),
        "shardSize": args.shard_size,
        "formulaBatchSize": args.formula_batch_size,
        "anchorBatchSize": args.anchor_batch_size,
    }
    if manifest_path.exists():
        existing_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if existing_manifest != input_manifest:
            # The first interrupted run used the mathematically identical
            # single-formula implementation before batching was added. Permit
            # only that exact manifest migration; data/model identity and all
            # shard semantics must remain unchanged.
            legacy_manifest = dict(input_manifest)
            legacy_manifest.pop("formulaBatchSize")
            if existing_manifest != legacy_manifest or not shard_paths:
                raise ValueError("existing evaluation manifest does not match the requested inputs and execution contract")
            temporary_manifest = manifest_path.with_suffix(".json.tmp")
            with temporary_manifest.open("x", encoding="utf-8") as output:
                output.write(json.dumps(input_manifest, ensure_ascii=False, indent=2) + "\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary_manifest, manifest_path)
    else:
        if shard_paths or list(args.output_dir.glob("predictions-*.jsonl.tmp")):
            raise ValueError("prediction shards exist without a matching evaluation manifest")
        with manifest_path.open("x", encoding="utf-8") as output:
            output.write(json.dumps(input_manifest, ensure_ascii=False, indent=2) + "\n")
            output.flush()
            os.fsync(output.fileno())
    target_total = [0] * 229
    predicted_total = [0] * 229
    matched_by_class = [0] * 229
    matched_total = 0
    exact_formula_count = 0
    total_predicted_symbols = 0
    total_target_symbols = 0
    formula_count = 0
    group_count_equal = 0
    started = time.monotonic()

    expected_start = 0
    for shard_path in shard_paths:
        try:
            prefix, raw_start, raw_end = shard_path.stem.split("-")
            shard_start, shard_end = int(raw_start), int(raw_end)
        except ValueError as error:
            raise ValueError(f"invalid prediction shard name: {shard_path.name}") from error
        if prefix != "predictions" or shard_start != expected_start or shard_end != min(shard_start + args.shard_size, len(weak)):
            raise ValueError(f"prediction shards are not a contiguous prefix: {shard_path.name}")
        rows = [json.loads(line) for line in shard_path.read_text(encoding="utf-8").splitlines() if line]
        if len(rows) != shard_end - shard_start:
            raise ValueError(f"prediction shard row count is incomplete: {shard_path}")
        for offset, row in enumerate(rows):
            index = shard_start + offset
            teacher = weak.rows[index]
            if row.get("formulaIndex") != index or row.get("sourceSampleId") != teacher.get("sourceSampleId"):
                raise ValueError(f"prediction shard identity mismatch at formula index {index}")
            target_values = [0] * 229
            predicted_values = [0] * 229
            for key, counts in (("targetCounts", target_values), ("predictedCounts", predicted_values)):
                mapping = row.get(key)
                if not isinstance(mapping, dict):
                    raise ValueError(f"saved prediction has invalid {key} at formula index {index}")
                for raw_class, count in mapping.items():
                    class_index = int(raw_class)
                    if not 0 <= class_index < 229 or type(count) is not int or count < 1:
                        raise ValueError(f"saved prediction has invalid {key} entry at formula index {index}")
                    counts[class_index] = count
            expected_counts = [0] * 229
            for label in teacher["visualSymbols"]:
                expected_counts[weak.index[label]] += 1
            if target_values != expected_counts or row.get("exactMultisetMatch") is not (target_values == predicted_values):
                raise ValueError(f"saved prediction does not match authoritative teacher at formula index {index}")
            formula_count += 1
            exact_formula_count += int(target_values == predicted_values)
            group_count_equal += int(row.get("proposedGroupCount") == sum(target_values))
            matched_total += sum(min(predicted_values[c], target_values[c]) for c in range(229))
            total_predicted_symbols += sum(predicted_values)
            total_target_symbols += sum(target_values)
            for class_index in range(229):
                target_total[class_index] += target_values[class_index]
                predicted_total[class_index] += predicted_values[class_index]
                matched_by_class[class_index] += min(target_values[class_index], predicted_values[class_index])
        expected_start = shard_end

    for shard_start in range(expected_start, len(weak), args.shard_size):
        shard_end = min(shard_start + args.shard_size, len(weak))
        shard_path = args.output_dir / f"predictions-{shard_start:06d}-{shard_end:06d}.jsonl"
        temporary_path = shard_path.with_suffix(".jsonl.tmp")
        staged: list[dict[str, object]] = []
        with torch.inference_mode():
            for batch_start in range(shard_start, shard_end, args.formula_batch_size):
                batch_end = min(batch_start + args.formula_batch_size, shard_end)
                samples = [weak[index] for index in range(batch_start, batch_end)]
                predictions = infer_formula_batch(
                    model, samples, anchor_groups, anchor_classes, anchor_embeddings
                )
                for offset, (sample, (predicted_labels, proposed_group_count)) in enumerate(zip(samples, predictions)):
                    index = batch_start + offset
                    target_counts = sample["targetCounts"]
                    if not isinstance(target_counts, torch.Tensor) or target_counts.shape != (229,):
                        raise ValueError(f"weak formula {index} has invalid target multiset")
                    predicted_counts = [0] * 229
                    for class_index in predicted_labels:
                        if not 0 <= class_index < 229:
                            raise ValueError(f"weak formula {index} produced an invalid class index")
                        predicted_counts[class_index] += 1
                    if proposed_group_count != len(predicted_labels):
                        raise ValueError(f"weak formula {index} prediction count differs from its proposed groups")
                    target_values = [int(value) for value in target_counts.tolist()]
                    matched = sum(min(predicted_counts[c], target_values[c]) for c in range(229))
                    exact = predicted_counts == target_values
                    formula_count += 1
                    exact_formula_count += int(exact)
                    group_count_equal += int(proposed_group_count == sum(target_values))
                    matched_total += matched
                    total_predicted_symbols += sum(predicted_counts)
                    total_target_symbols += sum(target_values)
                    for class_index in range(229):
                        target_total[class_index] += target_values[class_index]
                        predicted_total[class_index] += predicted_counts[class_index]
                        matched_by_class[class_index] += min(target_values[class_index], predicted_counts[class_index])
                    staged.append({
                        "formulaIndex": index,
                        "sourceSampleId": sample["sourceSampleId"],
                        "targetCounts": {str(c): n for c, n in enumerate(target_values) if n},
                        "predictedCounts": {str(c): n for c, n in enumerate(predicted_counts) if n},
                        "proposedGroupCount": proposed_group_count,
                        "targetSymbolCount": sum(target_values),
                        "exactMultisetMatch": exact,
                    })
        with temporary_path.open("x", encoding="utf-8") as output:
            for row in staged:
                output.write(json.dumps(row, ensure_ascii=False) + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, shard_path)
        elapsed = time.monotonic() - started
        print(f"evaluated={formula_count}/{len(weak)} exact={exact_formula_count} elapsed_seconds={elapsed:.1f}", flush=True)

    if formula_count != len(weak) or total_target_symbols == 0 or total_predicted_symbols == 0:
        raise ValueError("full formula evaluation did not cover the complete nonempty training split")
    precision = matched_total / total_predicted_symbols
    recall = matched_total / total_target_symbols
    report = {
        "contract": "hinotori-full-training-formula-fit-evaluation-v1",
        "status": "COMPLETED",
        "mode": "FULL_OFFICIAL_TRAIN_WEAK_FORMULAS_IN_SAMPLE",
        "checkpoint": str(args.checkpoint),
        "checkpointSHA256": sha256(args.checkpoint),
        "checkpointNextWeakPair": checkpoint.get("nextWeakPair"),
        "checkpointTotalWeakPairs": checkpoint.get("classSchedule", {}).get("pairCount") if isinstance(checkpoint.get("classSchedule"), dict) else 1531255,
        "evaluatedFormulaCount": formula_count,
        "excludedUnsupportedFormulaCount": weak.excluded_unsupported,
        "excludedOfficialValidSourceFormulaCount": weak.excluded_heldout,
        "directTrainingAnchorCount": len(direct),
        "directTrainingAnchorClassCoverage": len(set(anchor_classes.detach().cpu().tolist())),
        "formulaExactMultisetAccuracy": exact_formula_count / formula_count,
        "formulaExactMultisetCorrect": exact_formula_count,
        "microSymbolMultisetPrecision": precision,
        "microSymbolMultisetRecall": recall,
        "microSymbolMultisetF1": 2 * precision * recall / (precision + recall) if precision + recall else 0.0,
        "multisetIntersectionCount": matched_total,
        "predictedSymbolCount": total_predicted_symbols,
        "targetSymbolCount": total_target_symbols,
        "proposedGroupCountEqualsTargetSymbolCountRate": group_count_equal / formula_count,
        "perClassSymbolMultiset": [
            {
                "classIndex": class_index,
                "label": labels[class_index],
                "targetCount": target_total[class_index],
                "predictedCount": predicted_total[class_index],
                "matchedCount": matched_by_class[class_index],
                "precision": matched_by_class[class_index] / predicted_total[class_index] if predicted_total[class_index] else 0.0,
                "recall": matched_by_class[class_index] / target_total[class_index] if target_total[class_index] else 0.0,
            }
            for class_index in range(229)
        ],
        "elapsedSeconds": time.monotonic() - started,
        "interpretation": "This is full training-fit measurement on the official train weak-formula split. The model was optimized using these source formulas. Formula-level LaTeX symbol multisets support exact multiset and micro count metrics, but do not provide verified stroke-to-symbol alignments; no symbol-level Top-K is claimed for this split.",
        "artifacts": {"predictionShards": [str(path) for path in sorted(args.output_dir.glob("predictions-*.jsonl"))]},
    }
    report_path = args.output_dir / "report.json"
    with report_path.open("x", encoding="utf-8") as output:
        output.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        output.flush()
        os.fsync(output.fileno())
    print(json.dumps({key: report[key] for key in (
        "evaluatedFormulaCount", "formulaExactMultisetAccuracy", "microSymbolMultisetPrecision",
        "microSymbolMultisetRecall", "microSymbolMultisetF1", "elapsedSeconds"
    )}, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
