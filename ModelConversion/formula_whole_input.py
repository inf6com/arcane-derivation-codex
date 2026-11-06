#!/usr/bin/env python3
"""Read MathWriting expressions as whole-formula FormulaInput v1 records.

This module is intentionally limited to the first implementation block of the
whole-formula recognizer: the data contract between InkML and a future model.
It never reads ``symbols`` as training input and never creates per-symbol or
9-grid records.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


INKML_NAMESPACE = "http://www.w3.org/2003/InkML"
INK = {"ink": INKML_NAMESPACE}
SPEC_VERSION = "inf6-formula-input-v1"
MODEL_FEATURE_DTYPE = "float32"
MODEL_FEATURE_DIMENSION = 2
TRACE_GEOMETRY_CONTRACT_VERSION = "inf6-formula-whole-trace-geometry-v4-9f"
TRACE_GEOMETRY_FEATURE_DIMENSION = 9
EXPECTED_COUNTS = {"train": 229_864, "valid": 15_674, "test": 7_644, "symbols": 6_423, "synthetic": 396_014}
NUMBER = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?")


@dataclass(frozen=True)
class FormulaPoint:
    x: float
    y: float
    t: float | None = None


@dataclass(frozen=True)
class FormulaBounds:
    minX: float
    minY: float
    maxX: float
    maxY: float


@dataclass(frozen=True)
class FormulaCoordinateSpec:
    origin: str
    axis: str
    unit: str
    scale: str
    timeUnit: str | None
    parityStatus: str


@dataclass(frozen=True)
class FormulaInput:
    traces: tuple[tuple[FormulaPoint, ...], ...]
    traceOrder: tuple[int, ...]
    sourceBounds: FormulaBounds
    coordinateSpec: FormulaCoordinateSpec
    specVersion: str = SPEC_VERSION


class FormulaInputError(ValueError):
    """Raised when an InkML sample cannot satisfy FormulaInput v1."""


def _float32(value: float) -> float:
    """Convert through IEEE-754 binary32, matching Swift's `Float`."""
    import struct

    return struct.unpack("<f", struct.pack("<f", value))[0]


def model_features(formula: FormulaInput) -> tuple[tuple[tuple[float, float], ...], ...]:
    """Return the ragged `[trace][point][x,y]` float32-compatible features.

    T remains available in the evidence record, but is excluded from model
    features until InkML and PencilKit time semantics are proven equivalent.
    The values are converted through IEEE-754 binary32 so Python-side checks
    exercise the same precision contract as Swift's `Float` conversion.
    """
    return tuple(
        tuple((_float32(point.x), _float32(point.y)) for point in trace)
        for trace in formula.traces
    )


def trace_geometry_features(formula: FormulaInput) -> tuple[tuple[float, ...], ...]:
    """Return the v4 per-trace geometry side tensor in trace-write order.

    Every value is calculated from the already normalized FormulaInput XY
    coordinates, never from timestamps. The nine values are minX, minY,
    maxX, maxY, arithmetic point-centroid X/Y, extent X/Y, and normalized
    trace-write progress. A one-trace formula has progress 0. No trace is
    sorted, dropped, or inferred: empty traces are a malformed FormulaInput.
    """
    trace_count = len(formula.traces)
    if trace_count == 0:
        raise FormulaInputError("trace geometry requires at least one trace")
    denominator = max(trace_count - 1, 1)
    features: list[tuple[float, ...]] = []
    for index, trace in enumerate(formula.traces):
        if not trace:
            raise FormulaInputError(f"trace geometry received empty trace at index {index}")
        xs = [point.x for point in trace]
        ys = [point.y for point in trace]
        min_x, max_x = min(xs), max(xs)
        min_y, max_y = min(ys), max(ys)
        centroid_x = sum(xs) / len(xs)
        centroid_y = sum(ys) / len(ys)
        features.append(tuple(_float32(value) for value in (
            min_x, min_y, max_x, max_y,
            centroid_x, centroid_y,
            max_x - min_x, max_y - min_y,
            index / denominator,
        )))
    return tuple(features)


def _annotations(root: ET.Element) -> dict[str, str]:
    values: dict[str, str] = {}
    for element in root.findall("ink:annotation", INK):
        kind = element.attrib.get("type")
        if kind:
            values[kind] = (element.text or "").strip()
    return values


def _channels(root: ET.Element) -> tuple[list[str], dict[str, str]]:
    elements = root.findall("ink:traceFormat/ink:channel", INK)
    names = [element.attrib.get("name", "").upper() for element in elements]
    if names[:2] != ["X", "Y"]:
        raise FormulaInputError(f"traceFormat must start with X,Y, got {names!r}")
    if any(name not in {"X", "Y", "T"} for name in names):
        raise FormulaInputError(f"unsupported trace channel in {names!r}")
    if len(names) not in {2, 3} or len(set(names)) != len(names):
        raise FormulaInputError(f"traceFormat must contain X,Y and optional T once, got {names!r}")
    units = {name: element.attrib.get("units", "") for name, element in zip(names, elements)}
    return names, units


def _trace_values(text: str, channel_count: int) -> Iterable[list[float]]:
    stripped = text.strip()
    if not stripped:
        raise FormulaInputError("trace contains no coordinate points")
    chunks = re.split(r"\s*,\s*", stripped)
    for chunk in chunks:
        tokens = chunk.split()
        if not tokens:
            raise FormulaInputError("trace contains an empty coordinate point")
        invalid = [token for token in tokens if NUMBER.fullmatch(token) is None]
        if invalid:
            raise FormulaInputError(
                "unsupported non-absolute coordinate token(s) "
                f"{invalid!r}; only absolute numeric X Y [T] points are supported"
            )
        if len(tokens) != channel_count:
            raise FormulaInputError(f"trace point has {len(tokens)} values, expected {channel_count}")
        values = [float(token) for token in tokens]
        if not all(math.isfinite(value) for value in values):
            raise FormulaInputError("trace contains a non-finite coordinate")
        yield values


def load_formula_input(path: Path) -> tuple[FormulaInput, dict[str, str]]:
    """Parse one complete InkML expression without symbol segmentation."""
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as error:
        raise FormulaInputError(f"cannot parse {path}: {error}") from error

    annotations = _annotations(root)
    sample_id = annotations.get("sampleId")
    if not sample_id:
        raise FormulaInputError(f"{path} has no sampleId annotation")
    if path.stem != sample_id:
        raise FormulaInputError(f"filename/sampleId mismatch: {path.stem!r} != {sample_id!r}")
    normalized_label = annotations.get("normalizedLabel")
    if not normalized_label:
        raise FormulaInputError(f"{path} has no normalizedLabel annotation")

    channels, channel_units = _channels(root)
    traces: list[tuple[FormulaPoint, ...]] = []
    for element in root.findall("ink:trace", INK):
        points = []
        for values in _trace_values(element.text or "", len(channels)):
            point = {name.lower(): value for name, value in zip(channels, values)}
            points.append(FormulaPoint(x=point["x"], y=point["y"], t=point.get("t")))
        if not points:
            raise FormulaInputError(f"{path} contains an empty trace")
        traces.append(tuple(points))
    if not traces:
        raise FormulaInputError(f"{path} contains no traces")

    points = [point for trace in traces for point in trace]
    x_min, x_max = min(point.x for point in points), max(point.x for point in points)
    y_min, y_max = min(point.y for point in points), max(point.y for point in points)

    x_span = x_max - x_min
    y_span = y_max - y_min
    square_span = max(x_span, y_span)
    # Use one isotropic scale and center the shorter axis inside a unit square.
    # Independent axis scaling would erase the source aspect ratio: a wide X
    # and a tall X would become identical model inputs.  A constant axis is
    # represented at the center, preserving the same padding rule.
    x_padding = (square_span - x_span) / (2.0 * square_span) if square_span else 0.0
    y_padding = (square_span - y_span) / (2.0 * square_span) if square_span else 0.0

    def normalized(value: float, lower: float, padding: float) -> float:
        return 0.5 if square_span == 0.0 else (value - lower) / square_span + padding

    normalized_traces = tuple(
        tuple(
            FormulaPoint(
                x=normalized(point.x, x_min, x_padding),
                y=normalized(point.y, y_min, y_padding),
                t=point.t,
            )
            for point in trace
        )
        for trace in traces
    )
    source_bounds = FormulaBounds(minX=x_min, minY=y_min, maxX=x_max, maxY=y_max)
    coordinate_spec = FormulaCoordinateSpec(
        origin="source-bounds-min",
        axis="x-right,y-down",
        unit="InkML X/Y channel units",
        scale="isotropic-bounds-to-[0,1]-square-with-centered-padding",
        timeUnit=channel_units.get("T") or None,
        parityStatus="UNVERIFIED_WITH_PENCILKIT",
    )
    return FormulaInput(
        traces=normalized_traces,
        traceOrder=tuple(range(len(normalized_traces))),
        sourceBounds=source_bounds,
        coordinateSpec=coordinate_spec,
    ), {
        "sampleId": sample_id,
        "normalizedLabel": normalized_label,
        "splitTagOriginal": annotations.get("splitTagOriginal", ""),
        "inkCreationMethod": annotations.get("inkCreationMethod", ""),
        "traceCount": str(len(traces)),
        "pointCount": str(len(points)),
        "xRange": json.dumps([x_min, x_max], separators=(",", ":")),
        "yRange": json.dumps([y_min, y_max], separators=(",", ":")),
        "timeUnit": channel_units.get("T", ""),
        "coordinateParity": "UNVERIFIED_WITH_PENCILKIT",
    }


def _formula_input_json(value: FormulaInput) -> dict[str, object]:
    return {
        "traces": [[asdict(point) for point in trace] for trace in value.traces],
        "traceOrder": list(value.traceOrder),
        "sourceBounds": asdict(value.sourceBounds),
        "coordinateSpec": asdict(value.coordinateSpec),
        "specVersion": value.specVersion,
    }


def _files(split_root: Path) -> Iterable[Path]:
    with os.scandir(split_root) as entries:
        for entry in entries:
            if entry.is_file() and entry.name.endswith(".inkml"):
                yield Path(entry.path)


def _scan_count(split_root: Path) -> int:
    return sum(1 for _ in _files(split_root))


def _validate_split(split_root: Path, parse_samples: bool) -> dict[str, object]:
    count = 0
    parsed = 0
    errors: list[dict[str, str]] = []
    trace_total = 0
    point_total = 0
    first_sample: dict[str, object] | None = None
    for path in _files(split_root):
        count += 1
        if not parse_samples:
            continue
        try:
            formula, metadata = load_formula_input(path)
        except FormulaInputError as error:
            if len(errors) < 20:
                errors.append({"path": str(path), "error": str(error)})
            continue
        parsed += 1
        trace_total += len(formula.traces)
        point_total += sum(len(trace) for trace in formula.traces)
        if first_sample is None:
            first_sample = {"path": str(path), "metadata": metadata, "formulaInput": _formula_input_json(formula)}
    return {
        "path": str(split_root),
        "count": count,
        "parsed": parsed if parse_samples else None,
        "traceTotal": trace_total if parse_samples else None,
        "pointTotal": point_total if parse_samples else None,
        "firstSample": first_sample,
        "errors": errors,
    }


def audit_dataset(dataset_root: Path, output_path: Path) -> dict[str, object]:
    expected_root = dataset_root / "mathwriting-2024"
    if not expected_root.is_dir():
        raise FormulaInputError(f"dataset root is not mathwriting-2024: {expected_root}")

    splits = {}
    for split in ("train", "valid", "test", "symbols", "synthetic"):
        split_root = expected_root / split
        if not split_root.is_dir():
            raise FormulaInputError(f"missing split directory: {split_root}")
        # Only the whole-formula human splits are parsed into FormulaInput v1.
        # symbols is measured as an excluded reference set, never as input.
        splits[split] = _validate_split(split_root, parse_samples=split in {"train", "valid", "test"})
        splits[split]["expectedCount"] = EXPECTED_COUNTS[split]
        splits[split]["countMatchesExpected"] = splits[split]["count"] == EXPECTED_COUNTS[split]

    train = splits["train"]
    valid = splits["valid"]
    test = splits["test"]
    report: dict[str, object] = {
        "status": "PASS" if all(
            splits[name]["countMatchesExpected"] and (not splits[name]["errors"])
            for name in ("train", "valid", "test", "symbols", "synthetic")
        ) else "FAIL",
        "implementationBlock": "whole-formula-inkml-to-formula-input-v1",
        "dataset": str(expected_root),
        "inputPolicy": {
            "train": "229864 complete InkML expressions; direct whole-formula input",
            "valid": "15674 complete InkML expressions; validation only",
            "test": "7644 complete InkML expressions; final evaluation only",
            "symbols": "excluded; measured only to prove split separation",
            "synthetic": "excluded; measured only to prove split separation",
        },
        "specVersion": SPEC_VERSION,
        "coordinateContract": {
            "sourceBoundsIncluded": True,
            "coordinateSpecIncluded": True,
            "normalization": "isotropic-bounds-to-[0,1]-square-with-centered-padding",
            "timeChannel": "preserved when InkML declares T; unit recorded from traceFormat",
            "parityStatus": "UNVERIFIED_WITH_PENCILKIT",
            "blockingReason": "existing PencilKit canonical path retains raw points/sourceBounds and does not yet prove the same whole-formula normalization, T omission/handling, or dtype/shape contract",
        },
        "splits": splits,
        "integrity": {
            "trainCount": train["count"],
            "validCount": valid["count"],
            "testCount": test["count"],
            "trainParsed": train["parsed"],
            "validParsed": valid["parsed"],
            "testParsed": test["parsed"],
            "allWholeFormulaSplitsParsed": all(splits[name]["parsed"] == splits[name]["count"] for name in ("train", "valid", "test")),
            "symbolsUsedAsInput": False,
            "syntheticUsedAsInput": False,
        },
        "readiness": "BLOCKED_INPUT_CONTRACT_PARITY",
        "nextBlock": "establish one coordinate/time/dtype/shape contract shared by InkML and PencilKit, then train a sequence-to-sequence whole-formula recognizer from FormulaInput v1 and normalizedLabel",
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True, help="directory containing mathwriting-2024/")
    parser.add_argument("--output", type=Path, required=True, help="JSON artifact path")
    args = parser.parse_args(argv)
    try:
        report = audit_dataset(args.dataset_root, args.output)
    except FormulaInputError as error:
        print(f"formula whole-input audit failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"status": report["status"], "output": str(args.output), "train": report["integrity"]["trainCount"], "trainParsed": report["integrity"]["trainParsed"]}, ensure_ascii=False))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
