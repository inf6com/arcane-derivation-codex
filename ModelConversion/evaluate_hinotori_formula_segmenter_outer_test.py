#!/usr/bin/env python3
"""One-time evaluation of a frozen formula segmenter on source-disjoint test data."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import torch

from hinotori_formula_segmenter import HinotoriFormulaSegmenter, direct_pair_targets, resample_formula_strokes
from hinotori_inkml import read_inkml_traces
from train_hinotori_formula_segmenter import Example, _average_linkage_merges, pack


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_test_examples(teachers_path: Path, fit_split_path: Path, test_split_path: Path, inkml_root: Path, point_count: int, maximum_strokes: int):
    fit_split = json.loads(fit_split_path.read_text(encoding="utf-8")).get("sourceSplit")
    test_sources = json.loads(test_split_path.read_text(encoding="utf-8")).get("sourceSplit")
    if not isinstance(fit_split, dict) or any(value not in {"train", "valid", "test"} for value in fit_split.values()):
        raise ValueError("fit sourceSplit must map source IDs to train/valid/test")
    if not isinstance(test_sources, dict) or any(value != "valid" for value in test_sources.values()):
        raise ValueError("separate outer-test source list must map each held-out source to valid")
    if set(fit_split).intersection(test_sources):
        raise ValueError("outer-test sources overlap with the frozen fit source split")
    rows_by_source: dict[str, list[dict[str, object]]] = {}
    for line in teachers_path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        row = json.loads(line)
        source = row.get("sourceSampleId")
        if not isinstance(source, str) or source not in test_sources:
            raise ValueError("outer-test teacher references a source absent from the separate held-out source list")
        rows_by_source.setdefault(source, []).append(row)
    examples: list[Example] = []
    excluded_single = excluded_overlap = 0
    for source, rows in sorted(rows_by_source.items()):
        if len(rows) < 2:
            excluded_single += 1
            continue
        # These source-disjoint outer-holdout IDs are drawn from MathWriting's
        # original train directory; the holdout is defined by the project split.
        traces = read_inkml_traces(inkml_root / "train" / f"{source}.inkml")
        trace_ids = sorted(traces)
        if len(trace_ids) > maximum_strokes:
            raise ValueError(f"{source} has {len(trace_ids)} strokes, above maximum {maximum_strokes}")
        position = {trace_id: index for index, trace_id in enumerate(trace_ids)}
        groups: list[list[int]] = []
        for row in rows:
            raw = row.get("strokeIndices")
            if not isinstance(raw, list) or not raw or any(not isinstance(value, int) or value not in position for value in raw):
                raise ValueError(f"{source} has invalid direct stroke membership")
            groups.append([position[value] for value in raw])
        owned = [index for group in groups for index in group]
        if len(owned) != len(set(owned)) or not any(len(group) > 1 for group in groups):
            excluded_overlap += 1
            continue
        targets, supervised = direct_pair_targets(len(trace_ids), groups)
        if not supervised.any() or not targets[supervised].bool().any() or not (~targets[supervised].bool()).any():
            raise ValueError(f"{source} lacks positive or negative supervised pairs")
        points = resample_formula_strokes([traces[index] for index in trace_ids], point_count)
        examples.append(Example(source, points, targets, supervised))
    if not examples:
        raise ValueError("no eligible outer-test formula annotations")
    return examples, {"formulaCount": len(examples), "supervisedPairCount": sum(int(x.supervised.sum()) for x in examples), "excludedSingleTeacherSources": excluded_single, "excludedOverlappingOrUnannotatedSources": excluded_overlap}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--fit-source-split", type=Path, required=True)
    parser.add_argument("--test-source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite outer-test report: {args.output}")
    if not torch.backends.mps.is_built() or not torch.backends.mps.is_available():
        raise RuntimeError("MPS is required for model evaluation; CPU fallback is prohibited")
    checkpoint = torch.load(args.checkpoint, map_location="mps", weights_only=False)
    if checkpoint.get("contract") != "hinotori-formula-frame-pair-segmenter-v2":
        raise ValueError("outer-test evaluation requires the frozen v2 pair segmenter candidate")
    threshold = float(checkpoint["threshold"])
    run = checkpoint["run"]
    examples, counts = load_test_examples(args.teachers, args.fit_source_split, args.test_source_split, args.mathwriting_root, int(run["pointCount"]), int(run["maximumFormulaStrokes"]))
    model = HinotoriFormulaSegmenter(int(run["pointCount"])).to("mps")
    model.load_state_dict(checkpoint["modelState"], strict=True)
    model.eval()
    tp = fp = fn = exact = overmerge_only = oversplit_only = both = 0
    per_formula: list[dict[str, object]] = []
    with torch.no_grad():
        for item in examples:
            points, valid, target, supervised = pack([item], int(run["maximumFormulaStrokes"]), torch.device("mps"))
            n = item.points.shape[0]
            logits = model(points, valid)[0, :n, :n]
            merges = _average_linkage_merges((logits + logits.transpose(0, 1)) * 0.5)
            parent = list(range(n))
            def root(index: int) -> int:
                while parent[index] != index:
                    parent[index] = parent[parent[index]]
                    index = parent[index]
                return index
            for score, left, right in merges:
                if score <= threshold:
                    break
                left_root, right_root = root(left), root(right)
                if left_root != right_root:
                    parent[right_root] = left_root
            gold = target[0, :n, :n].bool().cpu()
            mask = supervised[0, :n, :n].cpu()
            predicted = torch.tensor([[root(i) == root(j) for j in range(n)] for i in range(n)])
            tp += int((predicted & gold & mask).sum())
            fp += int((predicted & ~gold & mask).sum())
            fn += int((~predicted & gold & mask).sum())
            known = torch.where(mask.any(dim=0))[0].tolist()
            over = under = False
            for i in known:
                for j in known:
                    if i >= j or not bool(mask[i, j]):
                        continue
                    same = root(i) == root(j)
                    expected = bool(gold[i, j])
                    over |= same and not expected
                    under |= not same and expected
            is_exact = not over and not under
            exact += int(is_exact)
            if over and under:
                both += 1
            elif over:
                overmerge_only += 1
            elif under:
                oversplit_only += 1
            per_formula.append({"sourceSampleId": item.source, "exactPartition": is_exact, "overmerge": over, "oversplit": under})
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    report = {
        "contract": "hinotori-formula-segmenter-outer-test-v1",
        "checkpointSHA256": sha256(args.checkpoint),
        "checkpointEpoch": int(checkpoint["epoch"]),
        "partitionThreshold": threshold,
        "mps": {"torch": torch.__version__, "built": torch.backends.mps.is_built(), "available": torch.backends.mps.is_available()},
        "data": {**counts, "teacherSHA256": sha256(args.teachers), "fitSourceSplitSHA256": sha256(args.fit_source_split), "outerTestSourceListSHA256": sha256(args.test_source_split), "outerTestUsedOnce": True},
        "metrics": {"exactAnnotatedPartitionFormulaCount": exact, "exactAnnotatedPartitionAccuracy": exact / len(examples), "pairPrecision": precision, "pairRecall": recall, "pairF1": f1, "overmergeOnlyFormulaCount": overmerge_only, "oversplitOnlyFormulaCount": oversplit_only, "bothErrorFormulaCount": both},
        "perFormula": per_formula,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "data": counts, "metrics": report["metrics"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
