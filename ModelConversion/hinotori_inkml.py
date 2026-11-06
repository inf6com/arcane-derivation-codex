"""Canonical trajectory input for Hinotori retrieval training.

This is the sole InkML reader for the new classifier.  Direct annotation
stroke indices are matched to InkML ``trace id`` exactly; no positional remap
or inferred symbol boundary is allowed.
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

import torch
from torch import Tensor

INK = {"ink": "http://www.w3.org/2003/InkML"}


def read_inkml_traces(path: Path) -> dict[int, Tensor]:
    """Read XY trajectories keyed by their declared InkML trace ids."""
    root = ET.parse(path).getroot()
    traces: dict[int, Tensor] = {}
    for element in root.findall("ink:trace", INK):
        raw_id = element.get("id")
        if raw_id is None:
            raise ValueError(f"{path}: trace without id")
        try:
            trace_id = int(raw_id)
        except ValueError as error:
            raise ValueError(f"{path}: noninteger trace id {raw_id!r}") from error
        if trace_id in traces:
            raise ValueError(f"{path}: duplicate trace id {trace_id}")
        points: list[list[float]] = []
        for sample in (element.text or "").strip().split(","):
            fields = sample.split()
            if len(fields) < 2:
                raise ValueError(f"{path}: trace {trace_id} has malformed sample {sample!r}")
            try:
                points.append([float(fields[0]), float(fields[1])])
            except ValueError as error:
                raise ValueError(f"{path}: trace {trace_id} has nonnumeric XY") from error
        if not points:
            raise ValueError(f"{path}: trace {trace_id} has no points")
        traces[trace_id] = torch.tensor(points, dtype=torch.float32)
    if not traces:
        raise ValueError(f"{path}: contains no traces")
    return traces


def select_annotated_group(traces: dict[int, Tensor], stroke_indices: list[int]) -> list[Tensor]:
    """Select exactly the direct-annotation traces, preserving its order."""
    if not stroke_indices or len(stroke_indices) != len(set(stroke_indices)):
        raise ValueError("stroke_indices must be nonempty and unique")
    missing = [index for index in stroke_indices if index not in traces]
    if missing:
        raise ValueError(f"direct annotation refers to absent trace ids: {missing}")
    return [traces[index] for index in stroke_indices]


def resample_stroke(points: Tensor, sample_count: int) -> Tensor:
    """Resample an XY trajectory by arc length without altering its endpoints."""
    if points.ndim != 2 or points.shape[1] != 2 or points.shape[0] < 1 or sample_count < 1:
        raise ValueError("points must be nonempty [point,2] and sample_count positive")
    if points.shape[0] == 1:
        return points.expand(sample_count, -1)
    lengths = (points[1:] - points[:-1]).norm(dim=1)
    # Consecutive duplicate samples carry zero arc length.  Remove them before
    # selecting segments so an endpoint target can never divide by a zero
    # segment length.
    keep = torch.cat((torch.ones(1, dtype=torch.bool, device=points.device), lengths > 0))
    points = points[keep]
    if points.shape[0] == 1:
        return points.expand(sample_count, -1)
    lengths = (points[1:] - points[:-1]).norm(dim=1)
    cumulative = torch.cat((torch.zeros(1, dtype=points.dtype, device=points.device), lengths.cumsum(dim=0)))
    total = cumulative[-1]
    if total == 0:
        return points[:1].expand(sample_count, -1)
    targets = torch.linspace(0, total, sample_count, dtype=points.dtype, device=points.device)
    upper = torch.searchsorted(cumulative, targets, right=True).clamp(1, points.shape[0] - 1)
    lower = upper - 1
    segment = cumulative[upper] - cumulative[lower]
    weight = ((targets - cumulative[lower]) / segment).unsqueeze(1)
    return points[lower] + weight * (points[upper] - points[lower])


def canonical_group_tensor(strokes: list[Tensor], point_count: int) -> Tensor:
    """Translate and isotropically scale a direct group, then resample it."""
    if not strokes or point_count < 1 or any(stroke.ndim != 2 or stroke.shape[1] != 2 or stroke.shape[0] < 1 for stroke in strokes):
        raise ValueError("strokes must be nonempty XY trajectories and point_count positive")
    all_points = torch.cat(strokes, dim=0)
    lower, upper = all_points.amin(dim=0), all_points.amax(dim=0)
    extent = (upper - lower).amax()
    # A one-point or repeated-point trajectory is observable input (for example
    # a dot).  Its canonical geometry is exactly the origin sequence: there is
    # no scale to estimate, so no invented scale is introduced.
    if extent == 0:
        return torch.stack([torch.zeros((point_count, 2), dtype=stroke.dtype, device=stroke.device) for stroke in strokes])
    center = (lower + upper) / 2
    return torch.stack([resample_stroke((stroke - center) / extent, point_count) for stroke in strokes])


def read_inkml_temporal_traces(path: Path) -> dict[int, Tensor]:
    """Read X/Y/T InkML traces, preserving elapsed time and trace identity."""
    root = ET.parse(path).getroot()
    channels = [element.get("name") for element in root.findall(".//ink:traceFormat/ink:channel", INK)]
    if not channels or any(name not in channels for name in ("X", "Y", "T")):
        raise ValueError(f"{path}: InkML traceFormat must declare X, Y, and T")
    positions = {name: channels.index(name) for name in ("X", "Y", "T")}
    traces: dict[int, Tensor] = {}
    for element in root.findall("ink:trace", INK):
        raw_id = element.get("id")
        if raw_id is None:
            raise ValueError(f"{path}: trace without id")
        try:
            trace_id = int(raw_id)
        except ValueError as error:
            raise ValueError(f"{path}: noninteger trace id {raw_id!r}") from error
        if trace_id in traces:
            raise ValueError(f"{path}: duplicate trace id {trace_id}")
        samples: list[list[float]] = []
        for raw_sample in (element.text or "").strip().split(","):
            fields = raw_sample.split()
            if len(fields) < len(channels):
                raise ValueError(f"{path}: trace {trace_id} sample omits declared channels")
            try:
                samples.append([float(fields[positions[name]]) for name in ("X", "Y", "T")])
            except ValueError as error:
                raise ValueError(f"{path}: trace {trace_id} contains a nonnumeric X/Y/T value") from error
        if not samples:
            raise ValueError(f"{path}: trace {trace_id} has no points")
        trace = torch.tensor(samples, dtype=torch.float32)
        if not torch.isfinite(trace).all():
            raise ValueError(f"{path}: trace {trace_id} contains non-finite X/Y/T")
        traces[trace_id] = trace
    if not traces:
        raise ValueError(f"{path}: contains no traces")
    return traces


def canonical_temporal_group_tensor(strokes: list[Tensor], point_count: int) -> Tensor:
    """Return [stroke,point,5]: normalized XY, local phase, symbol time, duration ratio."""
    if not strokes or point_count < 2 or any(stroke.ndim != 2 or stroke.shape[1] != 3 or stroke.shape[0] < 1 for stroke in strokes):
        raise ValueError("strokes must be nonempty [point,3] X/Y/T traces and point_count at least two")
    all_xy = torch.cat([stroke[:, :2] for stroke in strokes])
    lower, upper = all_xy.amin(0), all_xy.amax(0)
    extent = (upper - lower).amax()
    if extent == 0:
        canonical_xy = [torch.zeros_like(stroke[:, :2]) for stroke in strokes]
    else:
        center = (lower + upper) / 2
        canonical_xy = [(stroke[:, :2] - center) / extent for stroke in strokes]
    cleaned: list[tuple[Tensor, Tensor]] = []
    for stroke, xy in zip(strokes, canonical_xy):
        raw_time = stroke[:, 2] - stroke[0, 2]
        # Preserve the recorded path order. Repair small timestamp jitter for
        # interpolation without sorting points or changing their geometry.
        time = torch.cummax(raw_time, dim=0).values
        keep = torch.cat((torch.ones(1, dtype=torch.bool), time[1:] > time[:-1]))
        cleaned.append((time[keep], xy[keep]))
    durations = torch.stack([time[-1] for time, _ in cleaned]).clamp_min(0)
    positive_durations = durations[durations > 0]
    reference_duration = positive_durations.median() if positive_durations.numel() else torch.tensor(1.0)
    starts = torch.tensor([stroke[0, 2] for stroke in strokes], dtype=torch.float32)
    symbol_start = starts.amin()
    symbol_end = torch.stack([stroke[0, 2] + time[-1] for stroke, (time, _) in zip(strokes, cleaned)]).amax()
    symbol_duration = (symbol_end - symbol_start).clamp_min(1.0)
    result: list[Tensor] = []
    phase = torch.linspace(0, 1, point_count, dtype=torch.float32)
    for stroke, (time, xy), duration in zip(strokes, cleaned, durations):
        if time.numel() == 1 or time[-1] <= 0:
            sampled_xy = xy[:1].expand(point_count, -1)
            sampled_time = torch.zeros_like(phase)
        else:
            sampled_time = phase * time[-1]
            target_time = sampled_time
            upper_index = torch.searchsorted(time, target_time, right=True).clamp(1, time.numel() - 1)
            lower_index = upper_index - 1
            span = (time[upper_index] - time[lower_index]).clamp_min(torch.finfo(time.dtype).eps)
            ratio = ((target_time - time[lower_index]) / span).unsqueeze(1)
            sampled_xy = xy[lower_index] + ratio * (xy[upper_index] - xy[lower_index])
        duration_ratio = torch.log1p(duration / reference_duration.clamp_min(1.0))
        duration_channel = duration_ratio.expand(point_count, 1)
        absolute_time_phase = ((stroke[0, 2] + sampled_time - symbol_start) / symbol_duration).clamp(0, 1)
        result.append(torch.cat((sampled_xy, phase[:, None], absolute_time_phase[:, None], duration_channel), dim=1))
    return torch.stack(result)
