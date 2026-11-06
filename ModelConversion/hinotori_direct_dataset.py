"""Direct-anchor dataset and batching for Hinotori retrieval training."""
from __future__ import annotations

import json
from pathlib import Path

import torch
from torch import Tensor
from torch.utils.data import Dataset

from hinotori_inkml import (
    canonical_group_tensor,
    canonical_temporal_group_tensor,
    read_inkml_temporal_traces,
    read_inkml_traces,
    select_annotated_group,
)


class DirectAnchorDataset(Dataset[dict[str, object]]):
    """Read direct annotations as retrieval anchors from official train InkML."""

    def __init__(self, teachers_path: Path, source_split_path: Path, mathwriting_root: Path, point_count: int, split: str, temporal: bool = False):
        if split not in {"train", "valid"} or point_count < 1:
            raise ValueError("split must be train or valid and point_count positive")
        rows = [json.loads(line) for line in teachers_path.read_text(encoding="utf-8").splitlines() if line]
        source_split = json.loads(source_split_path.read_text(encoding="utf-8")).get("sourceSplit")
        if not isinstance(source_split, dict) or any(value not in {"train", "valid", "excluded"} for value in source_split.values()):
            raise ValueError("source split must map every source to train, valid, or explicitly excluded")
        missing = {str(row.get("sourceSampleId")) for row in rows} - set(source_split)
        if missing:
            raise ValueError(f"source split is missing direct anchor sources: {sorted(missing)[:3]}")
        self.rows = [row for row in rows if source_split[str(row["sourceSampleId"])] == split]
        if not self.rows:
            raise ValueError(f"direct {split} anchor set is empty")
        self.inkml_dir = mathwriting_root / "train"
        if not self.inkml_dir.is_dir():
            raise ValueError(f"missing MathWriting official train directory: {self.inkml_dir}")
        self.point_count = point_count
        self.temporal = temporal

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, object]:
        row = self.rows[index]
        source = row.get("sourceSampleId")
        indices = row.get("strokeIndices")
        class_index = row.get("classIndex")
        if not isinstance(source, str) or not isinstance(indices, list) or not all(isinstance(value, int) for value in indices) or not isinstance(class_index, int):
            raise ValueError(f"invalid direct anchor row at index {index}")
        path = self.inkml_dir / f"{source}.inkml"
        if not path.is_file():
            raise ValueError(f"direct anchor InkML is missing: {path}")
        if self.temporal:
            traces = read_inkml_temporal_traces(path)
            selected = select_annotated_group(traces, indices)
            group = canonical_temporal_group_tensor(selected, self.point_count)
            raster_group = canonical_group_tensor([stroke[:, :2] for stroke in selected], self.point_count)
        else:
            group = canonical_group_tensor(select_annotated_group(read_inkml_traces(path), indices), self.point_count)
            raster_group = None
        sample = {"points": group, "classIndex": class_index, "sourceSampleId": source, "strokeIndices": indices}
        if raster_group is not None:
            sample["rasterPoints"] = raster_group
        return sample


def collate_direct_anchors(samples: list[dict[str, object]]) -> dict[str, object]:
    """Pad direct groups without dropping strokes or trajectory points."""
    if not samples:
        raise ValueError("cannot collate an empty batch")
    groups = [sample.get("points") for sample in samples]
    if not all(isinstance(group, Tensor) and group.ndim == 3 and group.shape[-1] == 2 for group in groups):
        raise ValueError("all samples need [stroke,point,2] tensors")
    point_counts = {group.shape[1] for group in groups}
    if len(point_counts) != 1:
        raise ValueError("all direct groups must use one canonical point count")
    max_strokes = max(group.shape[0] for group in groups)
    point_count = point_counts.pop()
    points = torch.zeros((len(groups), max_strokes, point_count, 2), dtype=torch.float32)
    stroke_padding = torch.ones((len(groups), max_strokes), dtype=torch.bool)
    point_padding = torch.ones((len(groups), max_strokes, point_count), dtype=torch.bool)
    for row, group in enumerate(groups):
        stroke_count = group.shape[0]
        points[row, :stroke_count] = group
        stroke_padding[row, :stroke_count] = False
        point_padding[row, :stroke_count] = False
    return {
        "points": points,
        "strokePadding": stroke_padding,
        "pointPadding": point_padding,
        "classIndices": torch.tensor([sample["classIndex"] for sample in samples], dtype=torch.int64),
        "sourceSampleIds": [sample["sourceSampleId"] for sample in samples],
    }
