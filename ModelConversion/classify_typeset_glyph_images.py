#!/usr/bin/env python3
"""Classify 229 typeset glyph rasters and partition them by shared image-model output."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import torch

from hinotori_spatial_pyramid import HinotoriSpatialPyramidAngularMargin


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_images(raw_path: Path, manifest_path: Path, vocabulary_path: Path) -> tuple[dict[str, Any], torch.Tensor]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    vocabulary = json.loads(vocabulary_path.read_text(encoding="utf-8"))
    labels = vocabulary.get("labels")
    if manifest.get("schema") != "hinotori-typeset-glyph-raster-v1":
        raise ValueError("typeset raster manifest schema mismatch")
    if vocabulary.get("version") != "symbol229-v1" or not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229:
        raise ValueError("expected the unique symbol229-v1 vocabulary")
    if manifest.get("labels") != labels or manifest.get("vocabularySHA256") != digest(vocabulary_path.read_bytes()):
        raise ValueError("raster manifest vocabulary does not match the model vocabulary")
    if manifest.get("rasterSize") != 64 or manifest.get("inputValues") != "row-major UInt8: 0 background, 1 ink":
        raise ValueError("raster input contract mismatch")
    data = raw_path.read_bytes()
    if len(data) != 229 * 64 * 64 or any(value not in (0, 1) for value in data):
        raise ValueError("expected exactly 229 binary 64x64 images")
    images = torch.frombuffer(bytearray(data), dtype=torch.uint8).reshape(229, 1, 64, 64).float()
    return manifest, images


def classify(raw_path: Path, manifest_path: Path, vocabulary_path: Path, checkpoint_path: Path, output_path: Path, device_name: str) -> dict[str, Any]:
    if output_path.exists():
        raise FileExistsError(f"refusing to overwrite existing result: {output_path}")
    if device_name != "mps" or not torch.backends.mps.is_available():
        raise RuntimeError("typeset image inference requires the configured MPS device; no CPU fallback is permitted")
    manifest, images = load_images(raw_path, manifest_path, vocabulary_path)
    vocabulary_data = vocabulary_path.read_bytes()
    labels = json.loads(vocabulary_data)["labels"]
    checkpoint_data = checkpoint_path.read_bytes()
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    run = checkpoint.get("run", {})
    if run.get("model") != "HinotoriSpatialPyramidAngularMargin" or run.get("task") != "229-way isolated handwritten symbol classification":
        raise ValueError(f"checkpoint is not the expected handwritten raster classifier: {run.get('model')} / {run.get('task')}")
    if run.get("vocabularySHA256") != digest(vocabulary_data):
        raise ValueError("checkpoint vocabulary hash does not match the supplied vocabulary")
    if run.get("input", {}).get("kind") != "order-independent binary ink raster" or run["input"].get("size") != 64:
        raise ValueError("checkpoint input is not the 64x64 raster image contract")
    model = HinotoriSpatialPyramidAngularMargin()
    model.load_state_dict(checkpoint["model"], strict=True)
    model.eval().to(torch.device("mps"))
    with torch.inference_mode():
        logits, _ = model(images.to(torch.device("mps")))
        predictions = logits.argmax(dim=1).cpu().tolist()
    groups: dict[int, list[int]] = {}
    records = []
    for source_index, predicted_index in enumerate(predictions):
        groups.setdefault(predicted_index, []).append(source_index)
        records.append({
            "sourceIndex": source_index,
            "sourceLabel": labels[source_index],
            "recognizedLabel": labels[predicted_index],
            "exactLabelMatch": source_index == predicted_index,
        })
    subsets = [
        {"recognizerOutput": labels[predicted], "members": [labels[index] for index in members]}
        for predicted, members in sorted(groups.items())
    ]
    assigned = [label for subset in subsets for label in subset["members"]]
    if len(assigned) != 229 or set(assigned) != set(labels):
        raise RuntimeError("predicted-output subsets do not form an exact partition of the 229 source glyphs")
    correct = sum(record["exactLabelMatch"] for record in records)
    return {
        "schema": "hinotori-typeset-image-recognition-subsets-v1",
        "task": "partition the 229 typeset glyph images by the class emitted by the Hinotori raster image recognizer",
        "trainingDomain": "handwritten isolated symbols",
        "inferenceDomain": "font-rendered typeset glyphs",
        "font": {"postScriptName": manifest["fontPostScriptName"], "sha256": manifest["fontSHA256"]},
        "rasterManifestSHA256": digest(manifest_path.read_bytes()),
        "checkpoint": {"path": str(checkpoint_path), "sha256": digest(checkpoint_data), "epoch": checkpoint.get("epoch"), "architecture": run.get("model")},
        "inference": {"device": "MPS", "imageCount": 229, "exactTop1": correct, "exactTop1Rate": correct / 229},
        "groupingRule": "Each typeset input glyph belongs to the subset named by its single argmax class output. This is an image-recognizer-induced partition; no pairwise distance, nearest-neighbor ranking, or transitive closure is used.",
        "interpretation": "Exploratory cross-domain output only. The model was selected on handwritten validation data, and its 229 typeset-image Top-1 accuracy must be inspected before treating these output subsets as a valid similarity classification.",
        "subsets": subsets,
        "perGlyphRecognition": records,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raster", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--vocabulary", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", choices=("mps",), default="mps")
    args = parser.parse_args()
    result = classify(args.raster, args.manifest, args.vocabulary, args.checkpoint, args.output, args.device)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"classified 229 typeset glyph images on MPS into {len(result['subsets'])} predicted-output subsets")


if __name__ == "__main__":
    main()
