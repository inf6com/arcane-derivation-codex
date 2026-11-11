#!/usr/bin/env python3
"""Export the selected Fold-07 Firebird isolated-symbol classifier to Core ML.

The neural network emits exact 229-class logits and its normalized 128-D glyph
embedding. The 87 provisional similarity groups are a separate deterministic
candidate-expansion artifact; this converter records and hashes that artifact
but does not falsely encode the Swift rule as a neural-network layer.
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
from torch.nn import functional as F

from hinotori_raster_classifier import CLASS_COUNT, EMBEDDING_DIMENSION, RASTER_SIZE
from hinotori_spatial_pyramid import HinotoriSpatialPyramidAngularMargin


class Fold7Outputs(nn.Module):
    def __init__(self, model: HinotoriSpatialPyramidAngularMargin):
        super().__init__()
        self.model = model

    def forward(self, ink_raster: Tensor) -> tuple[Tensor, Tensor]:
        feature_map = self.model.features(ink_raster)
        pyramids = [F.adaptive_avg_pool2d(feature_map, size).flatten(1) for size in (1, 2, 4)]
        embedding = F.normalize(self.model.spatial_projection(torch.cat(pyramids, dim=1)), p=2, dim=1)
        logits = F.linear(embedding, F.normalize(self.model.class_prototypes, p=2, dim=1)) * self.model.scale
        return logits, embedding


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--label-manifest", type=Path, required=True)
    parser.add_argument("--similarity-groups", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package = args.output
    out = package.parent
    manifest_path = out / "HinotoriFold7CoreML.manifest.json"
    vocabulary_out = out / "HinotoriFold7Vocabulary.json"
    similarity_out = out / "HinotoriPrototypeCosineSimilarityGroups.json"
    if any(path.exists() for path in (package, manifest_path, vocabulary_out, similarity_out)):
        raise FileExistsError("refusing to overwrite an existing Hinotori Fold-07 export artifact")

    checkpoint_bytes = args.checkpoint.read_bytes()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    checkpoint_run = checkpoint.get("run")
    run = json.loads(args.run.read_text(encoding="utf-8"))
    if not isinstance(checkpoint_run, dict) or checkpoint.get("epoch") != 26:
        raise ValueError("checkpoint is not the selected Fold-07 epoch-26 artifact")
    if checkpoint_run.get("model") != "HinotoriSpatialPyramidAngularMargin":
        raise ValueError("checkpoint architecture is not the selected Fold-07 spatial-pyramid model")
    if run.get("model") != checkpoint_run.get("model") or run.get("task") != "229-way isolated handwritten symbol classification":
        raise ValueError("training run metadata does not identify the same isolated-symbol network")
    vocabulary_bytes = args.vocabulary.read_bytes()
    vocabulary = json.loads(vocabulary_bytes)
    labels = vocabulary.get("labels")
    if (not isinstance(labels, list) or len(labels) != CLASS_COUNT or len(set(labels)) != CLASS_COUNT
            or any(not isinstance(label, str) or not label for label in labels)
            or sha256(vocabulary_bytes) != checkpoint_run.get("vocabularySHA256")):
        raise ValueError("the ordered 229-label vocabulary does not match the checkpoint")

    label_manifest_bytes = args.label_manifest.read_bytes()
    label_manifest = json.loads(label_manifest_bytes)
    entries = label_manifest.get("entries")
    if (label_manifest.get("schema") != "firebird-symbol-rendering-kind-manifest-v1"
            or not isinstance(entries, list) or len(entries) != CLASS_COUNT
            or [entry.get("label") for entry in entries] != labels
            or [entry.get("index") for entry in entries] != list(range(CLASS_COUNT))):
        raise ValueError("the typeset glyph manifest does not define the checkpoint's ordered vocabulary")
    glyph_to_label: dict[str, str] = {}
    for entry in entries:
        scalar = entry.get("unicodeScalar")
        if scalar is None:
            continue
        if not isinstance(scalar, str) or not scalar.startswith("U+"):
            raise ValueError(f"invalid Unicode scalar for class {entry['label']}")
        glyph = chr(int(scalar[2:], 16))
        if glyph in glyph_to_label:
            raise ValueError(f"typeset glyph manifest maps Unicode {scalar} more than once")
        glyph_to_label[glyph] = entry["label"]

    groups_bytes = args.similarity_groups.read_bytes()
    with args.similarity_groups.open(encoding="utf-8-sig", newline="") as stream:
        import csv
        groups = list(csv.DictReader(stream))
    if len(groups) != 87:
        raise ValueError(f"expected exactly 87 approved provisional groups, got {len(groups)}")
    similarity_records = []
    observed_group_ids: set[str] = set()
    for row in groups:
        group_id = row["merged_group"]
        if group_id in observed_group_ids:
            raise ValueError(f"duplicate provisional similarity group {group_id}")
        observed_group_ids.add(group_id)
        members = row["symbols"].split("、")
        if len(members) != int(row["symbol_count"]) or len(set(members)) != len(members):
            raise ValueError(f"malformed symbol membership in provisional group {group_id}")
        if any(len(glyph) != 1 or glyph not in glyph_to_label for glyph in members):
            raise ValueError(f"unmapped glyph in provisional similarity group {group_id}")
        similarity_records.append({
            "groupID": int(group_id),
            "labels": [glyph_to_label[glyph] for glyph in members],
            "displayGlyphs": members,
        })
    similarity_document = {
        "schema": "hinotori-fold7-prototype-cosine-groups-v1",
        "sourceContract": "cycle662-groups-under-15",
        "sourceCSV_SHA256": sha256(groups_bytes),
        "labelManifestSHA256": sha256(label_manifest_bytes),
        "vocabularySHA256": sha256(vocabulary_bytes),
        "groups": similarity_records,
    }
    similarity_bytes = (json.dumps(similarity_document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

    model = HinotoriSpatialPyramidAngularMargin().eval()
    model.load_state_dict(checkpoint["model"], strict=True)
    exported_model = Fold7Outputs(model).eval()
    example = torch.zeros((1, 1, RASTER_SIZE, RASTER_SIZE), dtype=torch.float32)
    traced = torch.jit.trace(exported_model, example, strict=True, check_trace=True)
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name="inkRaster", shape=tuple(example.shape))],
        outputs=[ct.TensorType(name="classLogits"), ct.TensorType(name="queryEmbedding")],
        convert_to="neuralnetwork",
        minimum_deployment_target=ct.target.iOS13,
    )
    spec = converted.get_spec()
    inputs = {feature.name: feature for feature in spec.description.input}
    outputs = {feature.name: feature for feature in spec.description.output}
    if set(inputs) != {"inkRaster"} or set(outputs) != {"classLogits", "queryEmbedding"}:
        raise ValueError("converted Core ML interface does not match the exact classifier contract")
    outputs["classLogits"].type.multiArrayType.shape[:] = [1, CLASS_COUNT]
    outputs["queryEmbedding"].type.multiArrayType.shape[:] = [1, EMBEDDING_DIMENSION]
    if list(inputs["inkRaster"].type.multiArrayType.shape) != [1, 1, 64, 64]:
        raise ValueError("converted raster input shape differs from [1,1,64,64]")
    if list(outputs["classLogits"].type.multiArrayType.shape) != [1, CLASS_COUNT]:
        raise ValueError("converted class-logit output shape differs from [1,229]")
    if list(outputs["queryEmbedding"].type.multiArrayType.shape) != [1, EMBEDDING_DIMENSION]:
        raise ValueError("converted embedding output shape differs from [1,128]")

    out.mkdir(parents=True, exist_ok=True)
    ct.models.utils.save_spec(spec, str(package))
    vocabulary_out.write_bytes(vocabulary_bytes)
    similarity_out.write_bytes(similarity_bytes)
    metrics = checkpoint.get("metrics", {})
    manifest = {
        "schema": "hinotori-fold7-spatial-pyramid-coreml-v1",
        "productModelName": "火の鳥",
        "task": "229-way isolated handwritten symbol classification",
        "architecture": "HinotoriSpatialPyramidAngularMargin",
        "checkpoint": {"path": str(args.checkpoint), "sha256": sha256(checkpoint_bytes), "epoch": 26},
        "vocabulary": {"file": vocabulary_out.name, "sha256": sha256(vocabulary_bytes), "labels": CLASS_COUNT},
        "input": {"name": "inkRaster", "dtype": "float32", "shape": [1, 1, 64, 64], "preprocessing": "rasterize_group from hinotori_raster_classifier.py; canonical isotropic scale; fixed 3x3 dilation"},
        "outputs": {"classLogits": {"shape": [1, CLASS_COUNT]}, "queryEmbedding": {"shape": [1, EMBEDDING_DIMENSION], "l2Normalized": True}},
        "classifierLogitScale": float(run["arcFaceScale"]),
        "similarity": {"file": similarity_out.name, "sha256": sha256(similarity_bytes), "sourceCSV_SHA256": sha256(groups_bytes), "groupCount": len(groups), "role": "for each selected Hinotori ensemble Top-5 class, expand only its catalog groups; rank other members by query-embedding cosine similarity to normalized class prototypes; merge overlapping memberships by label and retain group IDs; cosine values are candidate-ordering evidence, not ensemble probabilities"},
        "selectedInnerValidation": metrics.get("classifier", {}),
        "outerTestRead": False,
        "conversion": {"coremltools": ct.__version__, "torch": torch.__version__, "python": platform.python_version(), "format": "neuralNetwork", "weightStoragePrecision": "float32", "computePrecision": "float16", "minimumDeploymentTarget": "iOS13", "computeUnitPreference": "CPU_AND_NEURAL_ENGINE", "aneDispatchVerified": False},
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"model": str(package), "manifest": str(manifest_path), "checkpointSHA256": manifest["checkpoint"]["sha256"], "epoch": 26, "groups": len(groups), "metrics": metrics.get("classifier"), "aneDispatchVerified": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
