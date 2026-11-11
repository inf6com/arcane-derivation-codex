#!/usr/bin/env python3
"""Attach the trained 222-class typeset head to Fold-07's frozen raster graph.

The result accepts only the canonical 64x64 ink raster. The copied graph is
pruned after Fold-07's raster projection, then one linear auxiliary head is
appended. The handwritten model and its logits are not changed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.proto import FeatureTypes_pb2, MIL_pb2


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def tensor_type(data_type: int, shape: list[int]):
    result = MIL_pb2.Value()
    result.type.tensorType.dataType = data_type
    result.type.tensorType.rank = len(shape)
    for size in shape:
        result.type.tensorType.dimensions.add().constant.size = size
    return result.type


def add_const(block, name: str, values: np.ndarray) -> None:
    values = np.asarray(values, dtype=np.float16, order="C")
    operation = block.operations.add()
    operation.type = "const"
    output = operation.outputs.add()
    output.name = name
    output.type.CopyFrom(tensor_type(MIL_pb2.FLOAT16, list(values.shape)))
    value = operation.attributes["val"]
    value.type.CopyFrom(output.type)
    value.immediateValue.tensor.bytes.values = values.tobytes(order="C")
    name_value = operation.attributes["name"]
    name_value.type.tensorType.dataType = MIL_pb2.STRING
    name_value.immediateValue.tensor.strings.values.append(name)


def add_linear(block, feature_name: str, weight_name: str, bias_name: str, output_name: str) -> None:
    operation = block.operations.add()
    operation.type = "linear"
    for key, value in (("x", feature_name), ("weight", weight_name), ("bias", bias_name)):
        operation.inputs[key].arguments.add().name = value
    output = operation.outputs.add()
    output.name = output_name
    output.type.CopyFrom(tensor_type(MIL_pb2.FLOAT16, [1, 222]))
    name_value = operation.attributes["name"]
    name_value.type.tensorType.dataType = MIL_pb2.STRING
    name_value.immediateValue.tensor.strings.values.append("hinotori_typeset_auxiliary_logits")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-package", type=Path, required=True)
    parser.add_argument("--base-manifest", type=Path, required=True)
    parser.add_argument("--weights-json", type=Path, required=True)
    parser.add_argument("--output-package", type=Path, required=True)
    parser.add_argument("--output-manifest", type=Path, required=True)
    parser.add_argument("--output-vocabulary", type=Path, required=True)
    args = parser.parse_args()
    if args.output_package.exists() or args.output_manifest.exists() or args.output_vocabulary.exists():
        raise FileExistsError("refusing to overwrite a previously generated typeset Core ML artifact")

    base_manifest = json.loads(args.base_manifest.read_text(encoding="utf-8"))
    weights = json.loads(args.weights_json.read_text(encoding="utf-8"))
    if base_manifest.get("format") != "hinotori-raster-symbol-coreml-v2" or base_manifest.get("architecture") != "HinotoriStrokeSetClassifier":
        raise ValueError("base Core ML artifact is not the declared Fold-07 StrokeSet raster graph")
    if base_manifest.get("checkpointSHA256") != weights.get("baseCheckpointSHA256"):
        raise ValueError("auxiliary head and frozen Fold-07 Core ML raster encoder checkpoint hashes differ")
    if weights.get("schema") != "hinotori-typeset-auxiliary-head-weights-v1":
        raise ValueError("unexpected exported typeset head tensor schema")
    indices = weights.get("supportedVocabularyIndices")
    labels = weights.get("labels")
    if (not isinstance(indices, list) or len(indices) != 222 or len(set(indices)) != 222 or
            not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229):
        raise ValueError("typeset output indices or ordered vocabulary do not match the 222/229 contract")
    if weights.get("weightShape") != [222, 128] or weights.get("biasShape") != [222]:
        raise ValueError("exported typeset head tensor shapes do not match the Core ML linear contract")
    weight = np.asarray(weights["weight"], dtype=np.float16)
    bias = np.asarray(weights["bias"], dtype=np.float16)
    if weight.shape != (222, 128) or bias.shape != (222,) or not np.isfinite(weight).all() or not np.isfinite(bias).all():
        raise ValueError("exported typeset head weights are malformed or non-finite")

    model_path = args.base_package / "Data/com.apple.CoreML/model.mlmodel"
    model_manifest_path = args.base_package / "Manifest.json"
    weights_path = args.base_package / "Data/com.apple.CoreML/weights/weight.bin"
    if not model_path.is_file() or not model_manifest_path.is_file() or not weights_path.is_file():
        raise FileNotFoundError("base Fold-07 Core ML package is incomplete")
    spec = ct.models.utils.load_spec(str(model_path))
    if spec.WhichOneof("Type") != "mlProgram":
        raise ValueError("base model is not a Core ML ML Program")
    program = spec.mlProgram
    if list(program.functions.keys()) != ["main"]:
        raise ValueError("base model does not expose the expected single main function")
    function = program.functions["main"]
    block = function.block_specializations[function.opset]
    if len(function.inputs) != 4 or function.inputs[0].name != "inkRaster":
        raise ValueError("base Core ML raster graph input contract changed")
    if [value.name for value in spec.description.input] != ["inkRaster", "strokePoints", "reversedStrokePoints", "strokeValid"]:
        raise ValueError("base model interface inputs do not match the frozen Fold-07 contract")
    if [value.name for value in spec.description.output] != ["classLogits", "queryEmbedding"]:
        raise ValueError("base model interface outputs changed")

    projection_index = next((index for index, operation in enumerate(block.operations)
                             if any(output.name == "relu_cast_fp16" for output in operation.outputs)), None)
    if projection_index is None or block.operations[projection_index].type != "relu":
        raise ValueError("frozen raster projection output is absent from the base Core ML graph")
    raster_operations = list(block.operations[:projection_index + 1])
    allowed = {"inkRaster"}
    for operation in raster_operations:
        for argument in operation.inputs.values():
            for reference in argument.arguments:
                if reference.name not in allowed:
                    raise ValueError(f"raster-only graph depends on unexpected input/intermediate: {reference.name}")
        allowed.update(output.name for output in operation.outputs)
    if "relu_cast_fp16" not in allowed:
        raise ValueError("raster projection output is not reachable from inkRaster")

    del block.operations[:]
    for operation in raster_operations:
        block.operations.add().CopyFrom(operation)
    del function.inputs[:]
    raster_input = function.inputs.add()
    raster_input.name = "inkRaster"
    raster_input.type.tensorType.dataType = MIL_pb2.FLOAT16
    raster_input.type.tensorType.rank = 4
    for size in (1, 1, 64, 64):
        raster_input.type.tensorType.dimensions.add().constant.size = size

    add_const(block, "hinotori_typeset_head_weight", weight)
    add_const(block, "hinotori_typeset_head_bias", bias)
    add_linear(block, "relu_cast_fp16", "hinotori_typeset_head_weight", "hinotori_typeset_head_bias", "typesetLogits")
    del block.outputs[:]
    block.outputs.append("typesetLogits")
    del spec.description.input[:]
    input_description = spec.description.input.add()
    input_description.name = "inkRaster"
    input_description.type.multiArrayType.shape.extend([1, 1, 64, 64])
    input_description.type.multiArrayType.dataType = FeatureTypes_pb2.ArrayFeatureType.FLOAT16
    del spec.description.output[:]
    output_description = spec.description.output.add()
    output_description.name = "typesetLogits"
    output_description.type.multiArrayType.shape.extend([1, 222])
    output_description.type.multiArrayType.dataType = FeatureTypes_pb2.ArrayFeatureType.FLOAT16

    args.output_package.parent.mkdir(parents=True, exist_ok=True)
    ct.models.utils.save_spec(spec, str(args.output_package), weights_dir=str(weights_path.parent))
    args.output_vocabulary.parent.mkdir(parents=True, exist_ok=True)
    vocabulary = {"schema": "hinotori-typeset-supported-vocabulary-v1",
                  "baseVocabularySHA256": base_manifest["output"]["classLogits"]["vocabularyFileSHA256"],
                  "labels": [labels[index] for index in indices],
                  "supportedVocabularyIndices": indices,
                  "baseClassCount": 229}
    args.output_vocabulary.write_text(json.dumps(vocabulary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    output_package_manifest = args.output_package / "Data/com.apple.CoreML/model.mlmodel"
    output_package_weights = args.output_package / "Data/com.apple.CoreML/weights/weight.bin"
    manifest = {
        "schema": "hinotori-typeset-auxiliary-coreml-v1",
        "modelName": "HinotoriTypesetAuxiliaryHead",
        "task": "supplemental candidate ranking for verified standalone typeset glyph classes",
        "primaryClassifierChanged": False,
        "headCheckpointSHA256": weights["headCheckpointSHA256"],
        "baseCheckpointSHA256": weights["baseCheckpointSHA256"],
        "frozenRasterEncoder": {"modelName": "HinotoriStrokeSetClassifier", "architecture": base_manifest["architecture"],
                                "selectedEpoch": base_manifest["selectedEpoch"], "checkpointSHA256": base_manifest["checkpointSHA256"]},
        "input": {"name": "inkRaster", "dtype": "float16", "shape": [1, 1, 64, 64],
                  "contract": "HinotoriStrokeSetInput.buildRasterOnly; canonical isotropic scale; binary ink; fixed 3x3 dilation"},
        "output": {"name": "typesetLogits", "dtype": "float16", "shape": [1, 222],
                   "ranking": "descending raw typeset logits; calibrated and probability-fused with the handwritten classifier by HinotoriSymbolCandidateEnsemble"},
        "vocabulary": {"file": args.output_vocabulary.name, "sha256": sha256(args.output_vocabulary), "supportedLabels": 222, "baseLabels": 229},
        "developmentEvidence": {"metricsFile": "runs/hinotori-typeset-auxiliary-head-strokeset-verified-20261105/metrics.json",
                                "heldOutFontTop1": 0.8710575103759766, "heldOutFontTop5": 0.9965986609458923,
                                "Fold07InnerValidTop10UnionCoverage": 0.95333331823349,
                                "primaryTop1": 0.5866666436195374, "primaryTop5Coverage": 0.9244444370269775,
                                "newlyRecoveredOf450": 13, "outerTestOpened": False,
                                "interpretation": "candidate coverage only; not corrected exact-class accuracy"},
        "primaryOutputInvariant": True,
        "computeUnitsRequestedByApp": "cpuAndNeuralEngine",
        "aneDispatchVerified": False,
        "coreMLModelSHA256": sha256(output_package_manifest),
        "coreMLWeightsSHA256": sha256(output_package_weights),
    }
    args.output_manifest.parent.mkdir(parents=True, exist_ok=True)
    args.output_manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"outputPackage": str(args.output_package), "supportedLabels": 222,
                      "headCheckpointSHA256": weights["headCheckpointSHA256"],
                      "coreMLModelSHA256": manifest["coreMLModelSHA256"], "aneDispatchVerified": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
