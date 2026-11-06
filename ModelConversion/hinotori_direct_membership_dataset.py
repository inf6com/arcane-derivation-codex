"""Direct formula relations for latent Hinotori training.

The direct annotations are auxiliary structural evidence.  Stroke membership
is class-independent: a pair of strokes belongs to the same written symbol or
it does not.  Every class stage therefore uses the same real, non-overlapping
direct relations instead of incorrectly requiring an annotated multi-symbol
formula for the current class.
"""
from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

import torch

from hinotori_inkml import read_inkml_traces


def direct_membership_examples(
    teachers_path: Path,
    source_split_path: Path,
    mathwriting_root: Path,
) -> list[tuple[list[torch.Tensor], list[list[int]]]]:
    """Return every non-overlapping direct stroke-membership relation."""
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

    examples: list[tuple[list[torch.Tensor], list[list[int]]]] = []
    for source, rows in sorted(by_source.items()):
        if len(rows) < 2:
            continue
        traces_by_id = read_inkml_traces(mathwriting_root / "train" / f"{source}.inkml")
        trace_ids = sorted(traces_by_id)
        position = {trace_id: index for index, trace_id in enumerate(trace_ids)}
        groups: list[list[int]] = []
        for row in rows:
            indices = row.get("strokeIndices")
            if not isinstance(indices, list) or not all(isinstance(value, int) and value in position for value in indices):
                raise ValueError(f"invalid direct grouping annotation for {source}")
            groups.append([position[value] for value in indices])
        owned = [trace for group in groups for trace in group]
        if len(owned) != len(set(owned)):
            continue
        if not any(len(group) > 1 for group in groups):
            continue
        examples.append(([traces_by_id[trace_id] for trace_id in trace_ids], groups))
    if not examples:
        raise ValueError("no direct membership formulas in the train split")
    return examples
