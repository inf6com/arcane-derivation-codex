#!/usr/bin/env python3
"""Convert a frozen 229-class Hinotori raster checkpoint to Core ML.

This export creates a device-deployable package; it does not prove ANE
execution. Physical-iPad compute-plan and latency measurements are recorded by
the separate device validation path.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
from pathlib import Path

import coremltools as ct
import torch
from torch import Tensor, nn

try:
    from ModelConversion.hinotori_raster_classifier import (
        CLASS_COUNT,
        EMBEDDING_DIMENSION,
        RASTER_SIZE,
        HinotoriMobileRasterClassifier,
        HinotoriRasterClassifier,
        HinotoriScaleSpaceClassifier,
        HinotoriSEClassifier,
        HinotoriStrokeSetClassifier,
    )
except ImportError:
    from hinotori_raster_classifier import (
        CLASS_COUNT,
        EMBEDDING_DIMENSION,
        RASTER_SIZE,
        HinotoriMobileRasterClassifier,
        HinotoriRasterClassifier,
        HinotoriScaleSpaceClassifier,
        HinotoriSEClassifier,
        HinotoriStrokeSetClassifier,
    )


MODEL_TYPES = {
    "HinotoriRasterClassifier": HinotoriRasterClassifier,
    "HinotoriMobileRasterClassifier": HinotoriMobileRasterClassifier,
    "HinotoriScaleSpaceClassifier": HinotoriScaleSpaceClassifier,
    "HinotoriSEClassifier": HinotoriSEClassifier,
    "HinotoriStrokeSetClassifier": HinotoriStrokeSetClassifier,
}


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class ClassifierOutputs(nn.Module):
    """Expose exact-class logits and the feature vector used for similarity."""

    def __init__(self, classifier: nn.Module):
        super().__init__()
        self.classifier = classifier

    def forward(self, ink_raster: Tensor, *stroke_inputs: Tensor) -> tuple[Tensor, Tensor]:
        logits, embedding = self.classifier(ink_raster, *stroke_inputs)
        return logits, embedding


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True, help="Exact vocabulary file used during training.")
    parser.add_argument("--output", type=Path, required=True, help="New .mlpackage path; existing paths are never overwritten.")
    parser.add_argument("--compute-precision", choices=("float16", "float32"), default="float16")
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite existing Core ML package: {args.output}")
    labels_path = args.output.parent / "HinotoriVocabulary.json"
    manifest_path = args.output.parent / "HinotoriRasterCoreML.manifest.json"
    if labels_path.exists() or manifest_path.exists():
        raise FileExistsError("refusing to overwrite an existing vocabulary or manifest")
    raw_checkpoint = args.checkpoint.read_bytes()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    run = checkpoint.get("run")
    if not isinstance(run, dict) or run.get("task") != "isolated_symbol_exact_classification":
        raise ValueError("checkpoint does not declare isolated-symbol exact classification")
    if run.get("classCount") != CLASS_COUNT:
        raise ValueError("checkpoint class count is not exactly 229")
    model_type = MODEL_TYPES.get(run.get("architecture"))
    if model_type is None:
        raise ValueError(f"unsupported checkpoint architecture: {run.get('architecture')!r}")
    labels = run.get("classLabelsByIndex")
    if not isinstance(labels, list) or len(labels) != CLASS_COUNT or len(set(labels)) != CLASS_COUNT:
        raise ValueError("checkpoint must contain an ordered vocabulary of 229 unique labels")
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary_document = json.loads(vocabulary_bytes)
    supplied_labels = vocabulary_document.get("labels") if isinstance(vocabulary_document, dict) else None
    if supplied_labels != labels or sha256_bytes(vocabulary_bytes) != run.get("vocabularySHA256"):
        raise ValueError("supplied vocabulary bytes and ordered labels must exactly match the training checkpoint")
    model_state = checkpoint.get("model")
    if not isinstance(model_state, dict):
        raise ValueError("checkpoint has no model state")
    model = model_type().eval()
    model.load_state_dict(model_state, strict=True)
    export_model = ClassifierOutputs(model).eval()
    raster_example = torch.zeros((1, 1, RASTER_SIZE, RASTER_SIZE), dtype=torch.float32)
    model_inputs = [raster_example]
    coreml_inputs = [ct.TensorType(name="inkRaster", shape=(1, 1, RASTER_SIZE, RASTER_SIZE))]
    input_contract = run.get("input", {})
    if run["architecture"] == "HinotoriStrokeSetClassifier":
        max_strokes = input_contract.get("maxStrokesInFitAndValidation")
        if not isinstance(max_strokes, int) or max_strokes < 1:
            raise ValueError("stroke-set checkpoint must declare a positive fixed stroke dimension")
        point_shape = (1, max_strokes, 128, 2)
        model_inputs.extend((torch.zeros(point_shape, dtype=torch.float32),
                             torch.zeros(point_shape, dtype=torch.float32),
                             torch.ones((1, max_strokes), dtype=torch.float32)))
        coreml_inputs.extend((ct.TensorType(name="strokePoints", shape=point_shape),
                              ct.TensorType(name="reversedStrokePoints", shape=point_shape),
                              ct.TensorType(name="strokeValid", shape=(1, max_strokes))))
    exported = torch.export.export(export_model, tuple(model_inputs)).run_decompositions({})
    precision = ct.precision.FLOAT16 if args.compute_precision == "float16" else ct.precision.FLOAT32
    converted = ct.convert(
        exported,
        inputs=coreml_inputs,
        outputs=[ct.TensorType(name="classLogits"), ct.TensorType(name="queryEmbedding")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=precision,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    converted.save(str(args.output))
    spec = converted.get_spec()
    input_features = {feature.name: feature for feature in spec.description.input}
    output_features = {feature.name: feature for feature in spec.description.output}
    expected_input_features = (
        {"inkRaster", "strokePoints", "reversedStrokePoints", "strokeValid"}
        if run["architecture"] == "HinotoriStrokeSetClassifier"
        else {"inkRaster"}
    )
    if set(input_features) != expected_input_features or set(output_features) != {"classLogits", "queryEmbedding"}:
        raise ValueError("converted Core ML feature names differ from the declared inference contract")
    expected_shapes = {
        feature.name: list(shape)
        for feature, shape in zip(coreml_inputs, [tuple(value.shape) for value in model_inputs], strict=True)
    }
    for name, expected_shape in expected_shapes.items():
        actual_shape = list(input_features[name].type.multiArrayType.shape)
        if actual_shape != expected_shape:
            raise ValueError(f"converted Core ML input {name} shape differs: expected {expected_shape}, got {actual_shape}")
    output_shape = list(output_features["classLogits"].type.multiArrayType.shape)
    if output_shape != [1, CLASS_COUNT]:
        raise ValueError(f"converted output shape must be [1,229], got {output_shape}")
    embedding_shape = list(output_features["queryEmbedding"].type.multiArrayType.shape)
    if embedding_shape != [1, EMBEDDING_DIMENSION]:
        raise ValueError(f"converted queryEmbedding shape must be [1,{EMBEDDING_DIMENSION}], got {embedding_shape}")
    labels_bytes = vocabulary_bytes
    labels_path.write_bytes(labels_bytes)
    manifest = {
        "format": "hinotori-raster-symbol-coreml-v2",
        "task": "isolated_symbol_exact_classification",
        "classCount": CLASS_COUNT,
        "modelPackage": args.output.name,
        "coreMLManifestSHA256": sha256_bytes((args.output / "Manifest.json").read_bytes()),
        "checkpointSHA256": sha256_bytes(raw_checkpoint),
        "architecture": run["architecture"],
        "selectedEpoch": checkpoint.get("epoch"),
        "selectedValidationMetrics": {
            key: checkpoint.get("metrics", {}).get(key)
            for key in ("epoch", "sampleCount", "top1", "top5", "macroRecallSupportedClasses", "supportedClassCount")
        },
        "input": ({
            "kind": "global ink raster and order/direction invariant stroke set",
            "features": [
                {"name": "inkRaster", "dtype": "float32", "shape": [1, 1, RASTER_SIZE, RASTER_SIZE], "inkValue": 1.0, "backgroundValue": 0.0},
                {"name": "strokePoints", "dtype": "float32", "shape": [1, input_contract.get("maxStrokesInFitAndValidation"), 128, 2]},
                {"name": "reversedStrokePoints", "dtype": "float32", "shape": [1, input_contract.get("maxStrokesInFitAndValidation"), 128, 2]},
                {"name": "strokeValid", "dtype": "float32", "shape": [1, input_contract.get("maxStrokesInFitAndValidation")]},
            ],
            "strokeOrderEncoding": False,
            "strokeDirection": "forward and reversed stroke embeddings are averaged",
            "strokeAggregation": "masked mean and max",
            "rasterizer": "rasterize_group in hinotori_raster_classifier.py",
        } if run["architecture"] == "HinotoriStrokeSetClassifier" else {
            "name": "inkRaster", "dtype": "float32", "shape": [1, 1, RASTER_SIZE, RASTER_SIZE],
            "kind": "binary order-invariant ink raster", "inkValue": 1.0, "backgroundValue": 0.0,
            "rasterizer": "rasterize_group in hinotori_raster_classifier.py",
        }),
        "output": {
            "classLogits": {"dtype": "float32", "shape": [1, CLASS_COUNT], "vocabularyFile": labels_path.name,
                            "vocabularyFileSHA256": sha256_bytes(labels_bytes), "checkpointVocabularySHA256": run["vocabularySHA256"],
                            "serializedVocabularySHA256": sha256_bytes(labels_bytes)},
            "queryEmbedding": {"dtype": "float32", "shape": [1, EMBEDDING_DIMENSION], "meaning": "L2-normalized shape feature for downstream similarity ranking"},
        },
        "conversion": {
            "coremltools": ct.__version__,
            "torch": torch.__version__,
            "python": platform.python_version(),
            "minimumDeploymentTarget": "iOS17",
            "computePrecision": args.compute_precision,
            "ANEStatus": "unverified; package conversion and compute-unit preference are not proof of ANE dispatch",
        },
        "training": {"device": run.get("device"), "seed": run.get("seed"),
                     "fitSourceFingerprint": run.get("trainSourceFingerprint"),
                     "validationSourceFingerprint": run.get("validSourceFingerprint"),
                     "validationRole": run.get("validRole")},
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"package": str(args.output), "manifest": str(manifest_path), "checkpointSHA256": manifest["checkpointSHA256"],
                      "architecture": run["architecture"], "outputShapes": {"classLogits": output_shape, "queryEmbedding": embedding_shape},
                      "validation": manifest["selectedValidationMetrics"], "ANEStatus": manifest["conversion"]["ANEStatus"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
