#!/usr/bin/env python3
"""Export the trained Hinotori retrieval computations without changing them.

The output directory contains two Core ML programs and the exact direct-anchor
bank they require.  The programs cannot be used with another checkpoint or
another anchor label map: both hashes are recorded in the manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

try:
    from ModelConversion.hinotori_coreml_compatible import HinotoriAffinityCoreML, HinotoriRetrievalCoreML
    from ModelConversion.hinotori_direct_dataset import DirectAnchorDataset
    from ModelConversion.hinotori_model import HinotoriRetrievalModel
except ImportError:
    from hinotori_coreml_compatible import HinotoriAffinityCoreML, HinotoriRetrievalCoreML
    from hinotori_direct_dataset import DirectAnchorDataset
    from hinotori_model import HinotoriRetrievalModel


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_array(path: Path, array: np.ndarray, dtype: str) -> None:
    """Write one explicitly typed, little-endian C-order tensor for iOS."""
    converted = np.asarray(array, dtype=np.dtype(dtype), order="C")
    path.write_bytes(converted.tobytes(order="C"))


def direct_anchor_bank(dataset: DirectAnchorDataset) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    samples = [dataset[index] for index in range(len(dataset))]
    groups = [sample["points"] for sample in samples]
    classes = torch.tensor([sample["classIndex"] for sample in samples], dtype=torch.int64)
    if not all(isinstance(group, torch.Tensor) and group.ndim == 3 and group.shape[1:] == (32, 2) for group in groups):
        raise ValueError("direct anchors do not meet the Hinotori point contract")
    max_strokes = max(group.shape[0] for group in groups)
    points = torch.zeros((len(groups), max_strokes, 32, 2), dtype=torch.float32)
    valid = torch.zeros((len(groups), max_strokes), dtype=torch.float32)
    for index, group in enumerate(groups):
        points[index, :group.shape[0]] = group
        valid[index, :group.shape[0]] = 1.0
    return points, valid, classes


def export_program(module: torch.nn.Module, args: tuple[torch.Tensor, ...], inputs: list[ct.TensorType], outputs: list[ct.TensorType], output: Path, compute_precision: ct.precision) -> None:
    exported = torch.export.export(module.eval(), args).run_decompositions({})
    converted = ct.convert(exported, inputs=inputs, outputs=outputs, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17, compute_precision=compute_precision)
    converted.save(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--teachers", type=Path, required=True)
    parser.add_argument("--source-split", type=Path, required=True)
    parser.add_argument("--mathwriting-root", type=Path, required=True)
    parser.add_argument("--max-formula-strokes", type=int, required=True)
    parser.add_argument("--compute-precision", choices=("float32", "float16"), default="float32")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.max_formula_strokes < 1:
        raise ValueError("max-formula-strokes must be positive")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite existing output: {args.output}")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("contract") != "hinotori-retrieval-v1":
        raise ValueError("checkpoint is not HinotoriRetrievalModel")
    state = checkpoint.get("modelState")
    if not isinstance(state, dict):
        raise ValueError("checkpoint has no modelState")
    vocabulary_path = args.teachers / "vocabulary.json"
    vocabulary_bytes = vocabulary_path.read_bytes()
    vocabulary = json.loads(vocabulary_bytes)
    labels = vocabulary.get("labels") if isinstance(vocabulary, dict) else None
    if not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229 or any(not isinstance(label, str) for label in labels):
        raise ValueError("Hinotori vocabulary must contain exactly 229 unique labels")
    dataset = DirectAnchorDataset(args.teachers / "direct-symbol-teachers.jsonl", args.source_split, args.mathwriting_root, 32, "train")
    anchor_points, anchor_valid, anchor_classes = direct_anchor_bank(dataset)
    model = HinotoriRetrievalModel().eval()
    model.load_state_dict(state, strict=True)
    affinity = HinotoriAffinityCoreML(model).eval()
    retrieval = HinotoriRetrievalCoreML(model, anchor_classes).eval()
    compute_precision = ct.precision.FLOAT16 if args.compute_precision == "float16" else ct.precision.FLOAT32
    formula_points = torch.zeros((1, args.max_formula_strokes, 32, 2), dtype=torch.float32)
    formula_valid = torch.zeros((1, args.max_formula_strokes), dtype=torch.float32)
    formula_valid[:, 0] = 1.0
    query_points = torch.zeros((1, anchor_points.shape[1], 32, 2), dtype=torch.float32)
    query_valid = torch.zeros((1, anchor_points.shape[1]), dtype=torch.float32)
    query_valid[:, 0] = 1.0
    args.output.mkdir(parents=True)
    # NPZ requires a ZIP/NumPy decoder which is not part of the iOS runtime.
    # Ship the exact tensors as explicit little-endian arrays instead; their
    # dimensions, dtype and SHA-256 values are all fixed in the manifest.
    points_path = args.output / "HinotoriAnchorPoints.f32le"
    valid_path = args.output / "HinotoriAnchorStrokeValid.f32le"
    classes_path = args.output / "HinotoriAnchorClasses.i64le"
    vocabulary_output_path = args.output / "HinotoriVocabulary.json"
    write_array(points_path, anchor_points.numpy(), "<f4")
    write_array(valid_path, anchor_valid.numpy(), "<f4")
    write_array(classes_path, anchor_classes.numpy(), "<i8")
    vocabulary_output_path.write_bytes(vocabulary_bytes)
    export_program(affinity, (formula_points, formula_valid), [ct.TensorType(name="tracePoints", shape=formula_points.shape, dtype=np.float32), ct.TensorType(name="traceValid", shape=formula_valid.shape, dtype=np.float32)], [ct.TensorType(name="affinityLogits", dtype=np.float32), ct.TensorType(name="strokeEmbeddings", dtype=np.float32)], args.output / "HinotoriAffinity.mlpackage", compute_precision)
    export_program(retrieval, (query_points, query_valid, anchor_points, anchor_valid), [ct.TensorType(name="queryPoints", shape=query_points.shape, dtype=np.float32), ct.TensorType(name="queryStrokeValid", shape=query_valid.shape, dtype=np.float32), ct.TensorType(name="anchorPoints", shape=anchor_points.shape, dtype=np.float32), ct.TensorType(name="anchorStrokeValid", shape=anchor_valid.shape, dtype=np.float32)], [ct.TensorType(name="classLogits", dtype=np.float32), ct.TensorType(name="queryEmbedding", dtype=np.float32), ct.TensorType(name="anchorEmbeddings", dtype=np.float32)], args.output / "HinotoriRetrieval.mlpackage", compute_precision)
    manifest = {"format": "hinotori-retrieval-coreml-v1", "computePrecision": args.compute_precision, "checkpoint": str(args.checkpoint), "checkpointSHA256": sha256(args.checkpoint), "vocabulary": {"path": vocabulary_output_path.name, "sha256": sha256(vocabulary_output_path), "classes": 229}, "anchorBank": {"count": int(anchor_points.shape[0]), "maxStrokes": int(anchor_points.shape[1]), "pointCount": 32, "pointDimension": 2, "classes": 229, "arrays": {"anchorPoints": {"path": points_path.name, "sha256": sha256(points_path), "dtype": "float32-le", "shape": list(anchor_points.shape)}, "anchorStrokeValid": {"path": valid_path.name, "sha256": sha256(valid_path), "dtype": "float32-le", "shape": list(anchor_valid.shape)}, "anchorClasses": {"path": classes_path.name, "sha256": sha256(classes_path), "dtype": "int64-le", "shape": list(anchor_classes.shape)} }}, "affinity": {"model": "HinotoriAffinity.mlpackage", "inputs": {"tracePoints": [1, args.max_formula_strokes, 32, 2], "traceValid": [1, args.max_formula_strokes]}, "outputs": {"affinityLogits": [args.max_formula_strokes, args.max_formula_strokes], "strokeEmbeddings": [args.max_formula_strokes, 128]}}, "retrieval": {"model": "HinotoriRetrieval.mlpackage", "inputs": {"queryPoints": [1, int(anchor_points.shape[1]), 32, 2], "queryStrokeValid": [1, int(anchor_points.shape[1])], "anchorPoints": list(anchor_points.shape), "anchorStrokeValid": list(anchor_valid.shape)}, "outputs": {"classLogits": [1, 229], "queryEmbedding": [1, 128], "anchorEmbeddings": [int(anchor_points.shape[0]), 128]}}, "decodeContract": "Swift must reject a formula with more than maxFormulaStrokes, evaluate affinityLogits > 0 only for traceValid == 1, find connected components, canonicalize each component identically to hinotori_inkml.canonical_group_tensor, reject groups above anchorBank.maxStrokes, then invoke HinotoriRetrieval with the manifest-hashed little-endian anchor bank arrays. No alternate recognizer is permitted."}
    (args.output / "HinotoriCoreML.manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
