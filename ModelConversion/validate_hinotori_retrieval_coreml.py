#!/usr/bin/env python3
"""Numerically compare exported Hinotori Core ML programs with PyTorch."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

try:
    from ModelConversion.hinotori_coreml_compatible import HinotoriAffinityCoreML, HinotoriRetrievalCoreML
    from ModelConversion.hinotori_model import HinotoriRetrievalModel
except ImportError:
    from hinotori_coreml_compatible import HinotoriAffinityCoreML, HinotoriRetrievalCoreML
    from hinotori_model import HinotoriRetrievalModel


def maximum_difference(observed: np.ndarray, expected: torch.Tensor) -> float:
    reference = expected.detach().cpu().numpy()
    if not np.array_equal(np.isposinf(observed), np.isposinf(reference)) or not np.array_equal(np.isneginf(observed), np.isneginf(reference)) or not np.array_equal(np.isnan(observed), np.isnan(reference)):
        raise ValueError("Core ML and PyTorch differ in their non-finite output mask")
    finite = np.isfinite(reference)
    return float(np.max(np.abs(observed[finite].astype(np.float32) - reference[finite]))) if finite.any() else 0.0


def load_manifest_array(artifact: Path, entry: dict[str, object], dtype: str) -> np.ndarray:
    path = artifact / str(entry["path"])
    observed_hash = __import__("hashlib").sha256(path.read_bytes()).hexdigest()
    if observed_hash != entry["sha256"]:
        raise ValueError(f"anchor array hash mismatch: {path}")
    shape = tuple(int(value) for value in entry["shape"])
    array = np.fromfile(path, dtype=np.dtype(dtype))
    if array.size != int(np.prod(shape)):
        raise ValueError(f"anchor array size does not match manifest: {path}")
    return array.reshape(shape)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-abs-diff", type=float, default=1e-5)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite verification report: {args.output}")
    manifest = json.loads((args.artifact / "HinotoriCoreML.manifest.json").read_text(encoding="utf-8"))
    if manifest.get("format") != "hinotori-retrieval-coreml-v1":
        raise ValueError("artifact does not declare Hinotori Core ML contract")
    vocabulary_entry = manifest.get("vocabulary")
    if not isinstance(vocabulary_entry, dict):
        raise ValueError("artifact has no Hinotori vocabulary contract")
    vocabulary_path = args.artifact / str(vocabulary_entry.get("path"))
    vocabulary_bytes = vocabulary_path.read_bytes()
    if __import__("hashlib").sha256(vocabulary_bytes).hexdigest() != vocabulary_entry.get("sha256"):
        raise ValueError("Hinotori vocabulary hash mismatch")
    vocabulary = json.loads(vocabulary_bytes)
    labels = vocabulary.get("labels") if isinstance(vocabulary, dict) else None
    if not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229 or any(not isinstance(label, str) for label in labels):
        raise ValueError("Hinotori vocabulary does not contain exactly 229 unique labels")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = HinotoriRetrievalModel().eval()
    model.load_state_dict(checkpoint["modelState"], strict=True)
    arrays = manifest["anchorBank"]["arrays"]
    anchor_points = torch.from_numpy(load_manifest_array(args.artifact, arrays["anchorPoints"], "<f4"))
    anchor_valid = torch.from_numpy(load_manifest_array(args.artifact, arrays["anchorStrokeValid"], "<f4"))
    anchor_classes = torch.from_numpy(load_manifest_array(args.artifact, arrays["anchorClasses"], "<i8")).to(torch.int64)
    retrieval = HinotoriRetrievalCoreML(model, anchor_classes).eval()
    affinity = HinotoriAffinityCoreML(model).eval()
    formula_shape = tuple(manifest["affinity"]["inputs"]["tracePoints"])
    trace_points = torch.zeros(formula_shape, dtype=torch.float32)
    trace_points[:, :min(2, formula_shape[1])] = anchor_points[0, :1].expand(1, min(2, formula_shape[1]), -1, -1)
    trace_valid = torch.zeros(tuple(manifest["affinity"]["inputs"]["traceValid"]), dtype=torch.float32)
    trace_valid[:, :min(2, formula_shape[1])] = 1.0
    query_points = anchor_points[:1]
    query_valid = anchor_valid[:1]
    with torch.inference_mode():
        reference_affinity, reference_strokes = affinity(trace_points, trace_valid)
        reference_logits, reference_query, reference_anchors = retrieval(query_points, query_valid, anchor_points, anchor_valid)
    core_affinity = ct.models.MLModel(str(args.artifact / "HinotoriAffinity.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    core_retrieval = ct.models.MLModel(str(args.artifact / "HinotoriRetrieval.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    affinity_output = core_affinity.predict({"tracePoints": trace_points.numpy(), "traceValid": trace_valid.numpy()})
    retrieval_output = core_retrieval.predict({"queryPoints": query_points.numpy(), "queryStrokeValid": query_valid.numpy(), "anchorPoints": anchor_points.numpy(), "anchorStrokeValid": anchor_valid.numpy()})
    differences = {"affinityLogits": maximum_difference(affinity_output["affinityLogits"], reference_affinity), "strokeEmbeddings": maximum_difference(affinity_output["strokeEmbeddings"], reference_strokes), "classLogits": maximum_difference(retrieval_output["classLogits"], reference_logits), "queryEmbedding": maximum_difference(retrieval_output["queryEmbedding"], reference_query), "anchorEmbeddings": maximum_difference(retrieval_output["anchorEmbeddings"], reference_anchors)}
    report = {"status": "COMPLETED", "contract": "hinotori-retrieval-coreml-v1", "checkpoint": str(args.checkpoint), "artifact": str(args.artifact), "maxAbsDiff": max(differences.values()), "differences": differences, "top1Matches": bool(np.array_equal(retrieval_output["classLogits"].argmax(axis=1), reference_logits.detach().cpu().numpy().argmax(axis=1))), "acceptance": {"maxAbsDiff": args.max_abs_diff, "top1Matches": True}}
    report["adoptionGate"] = "PASS" if report["maxAbsDiff"] <= args.max_abs_diff and report["top1Matches"] else "FAIL"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"maxAbsDiff": report["maxAbsDiff"], "top1Matches": report["top1Matches"], "adoptionGate": report["adoptionGate"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
