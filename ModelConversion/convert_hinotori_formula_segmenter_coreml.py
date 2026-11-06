#!/usr/bin/env python3
"""Convert and numerically validate the selected stroke-group model."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

from hinotori_formula_segmenter import HinotoriFormulaSegmenter


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(bytes.fromhex(sha256(path)))
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--partition-threshold", type=float, required=True)
    args = parser.parse_args()
    if not np.isfinite(args.partition_threshold):
        raise ValueError("partition threshold must be finite")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite Core ML package: {args.output}")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    contract = checkpoint.get("contract")
    if contract not in {
        "hinotori-formula-frame-pair-segmenter-v1",
        "hinotori-formula-frame-pair-segmenter-v2",
        "hinotori-formula-frame-pair-segmenter-v3",
    }:
        raise ValueError("checkpoint contract is not the selected Hinotori formula segmenter")
    if contract != "hinotori-formula-frame-pair-segmenter-v1" and float(checkpoint["threshold"]) != args.partition_threshold:
        raise ValueError("partition threshold must match the checkpoint's inner-validation selection")
    model = HinotoriFormulaSegmenter().eval()
    model.load_state_dict(checkpoint["modelState"], strict=True)
    maximum_strokes = int(checkpoint["run"]["maximumFormulaStrokes"])
    point_count = int(checkpoint["run"]["pointCount"])
    points = torch.zeros((1, maximum_strokes, point_count, 2), dtype=torch.float32)
    valid = torch.zeros((1, maximum_strokes), dtype=torch.float32)
    valid[:, :7] = 1
    generator = torch.Generator().manual_seed(20261105)
    points[:, :7] = torch.rand((1, 7, point_count, 2), generator=generator) - 0.5
    with torch.no_grad():
        expected = model(points, valid).numpy()
    exported = torch.export.export(model, (points, valid)).run_decompositions({})
    converted = ct.convert(
        exported,
        inputs=[
            ct.TensorType(name="formulaPoints", shape=points.shape, dtype=np.float32),
            ct.TensorType(name="strokeValid", shape=valid.shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="affinityLogits", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted.save(args.output)
    # Keep the numerical parity check on CPU so platform-specific GPU/ANE
    # dispatch does not contaminate the converter comparison.
    compiled = ct.models.MLModel(str(args.output), compute_units=ct.ComputeUnit.CPU_ONLY)
    prediction = compiled.predict({"formulaPoints": points.numpy(), "strokeValid": valid.numpy()})
    observed = np.asarray(prediction["affinityLogits"], dtype=np.float32)
    if observed.shape != expected.shape or not np.isfinite(observed).all():
        raise ValueError("Core ML segmenter returned an invalid output shape or non-finite logits")
    valid_strokes = valid.numpy()[0] > 0.5
    valid_pairs = np.logical_and(valid_strokes[:, None], valid_strokes[None, :])
    expected_pairs = expected[0][valid_pairs]
    observed_pairs = observed[0][valid_pairs]
    pair_errors = np.abs(expected_pairs - observed_pairs)
    max_abs_error = float(np.max(pair_errors))
    mean_abs_error = float(np.mean(pair_errors))
    decision_flips = int(np.logical_xor(
        expected_pairs > args.partition_threshold,
        observed_pairs > args.partition_threshold,
    ).sum())
    if max_abs_error > 0.08 or decision_flips != 0:
        raise ValueError(
            "Float16 Core ML conversion changes active pair decisions or exceeds "
            f"the active-pair tolerance: maxAbs={max_abs_error}, flips={decision_flips}"
        )
    manifest = {
        "format": "hinotori-formula-frame-pair-segmenter-coreml-v2",
        "modelName": "HinotoriFormulaSegmenter",
        "task": "formula stroke pair grouping; not glyph classification",
        "architecture": "shared-1d-convolutional-stroke-encoder-plus-symmetric-pair-MLP",
        "checkpointSHA256": sha256(args.checkpoint),
        "selectedEpoch": int(checkpoint["epoch"]),
        "validationThreshold": float(checkpoint["threshold"]),
        "trainingConfig": checkpoint["run"],
        "trainingData": checkpoint["data"],
        "input": {
            "formulaPoints": {"dtype": "float32", "shape": [1, maximum_strokes, point_count, 2], "coordinateFrame": "formula-wide center translation and uniform max-extent scale; preserve inter-stroke position and scale"},
            "strokeValid": {"dtype": "float32", "shape": [1, maximum_strokes]},
        },
        "output": {"affinityLogits": {"dtype": "float32", "shape": [1, maximum_strokes, maximum_strokes], "symmetric": True}},
        "decode": {"algorithm": "average-linkage", "positivePairLogitThreshold": args.partition_threshold, "userMustConfirmCandidates": True},
        "conversion": {"coremltools": ct.__version__, "torch": torch.__version__, "computePrecision": "float16", "numericalComparison": {"scope": "valid stroke pairs only", "pairCount": int(valid_pairs.sum()), "maxAbsError": max_abs_error, "meanAbsError": mean_abs_error, "decisionFlipsAtSelectedThreshold": decision_flips}, "ANEStatus": "unverified; hardware dispatch requires physical-device profiling"},
        "outerTestRead": False,
        "packageTreeSHA256": tree_sha256(args.output),
    }
    manifest_path = args.output.parent / "HinotoriFormulaSegmenter.manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"package": str(args.output), "manifest": str(manifest_path), "maxAbsError": max_abs_error, "meanAbsError": mean_abs_error, "sha256": manifest["packageTreeSHA256"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
