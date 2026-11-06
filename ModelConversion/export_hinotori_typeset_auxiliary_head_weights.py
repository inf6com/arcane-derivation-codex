#!/usr/bin/env python3
"""Export the already-trained Hinotori typeset head as a portable JSON tensor.

This is an artifact conversion step only. It does not train, score, or select
the head. The paired Core ML composer consumes the emitted arrays.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import torch


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head-checkpoint", type=Path, required=True)
    parser.add_argument("--fold7-checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    head_bytes = args.head_checkpoint.read_bytes()
    fold7_sha = sha256(args.fold7_checkpoint)
    checkpoint = torch.load(args.head_checkpoint, map_location="cpu", weights_only=False)
    if checkpoint.get("baseCheckpointSHA256") != fold7_sha:
        raise ValueError("typeset head was trained from a different frozen Fold-07 checkpoint")
    if checkpoint.get("primaryModelParametersUpdated") is not False:
        raise ValueError("typeset head checkpoint does not certify a frozen primary model")
    indices = checkpoint.get("supportedVocabularyIndices")
    state = checkpoint.get("state_dict")
    if (not isinstance(indices, list) or len(indices) != 222 or
            len(set(indices)) != len(indices) or any(not isinstance(i, int) or not 0 <= i < 229 for i in indices) or
            not isinstance(state, dict) or set(state) != {"weight", "bias"}):
        raise ValueError("typeset head has an invalid ordered 222-of-229 output contract")
    weight, bias = state["weight"], state["bias"]
    if tuple(weight.shape) != (222, 128) or tuple(bias.shape) != (222,):
        raise ValueError("typeset head tensor shapes are not [222,128] and [222]")
    if not torch.isfinite(weight).all() or not torch.isfinite(bias).all():
        raise ValueError("typeset head contains non-finite parameters")
    base = torch.load(args.fold7_checkpoint, map_location="cpu", weights_only=False)
    labels = base.get("run", {}).get("classLabelsByIndex")
    if not isinstance(labels, list) or len(labels) != 229 or len(set(labels)) != 229:
        raise ValueError("base checkpoint does not carry the ordered 229-label vocabulary")

    document = {
        "schema": "hinotori-typeset-auxiliary-head-weights-v1",
        "headCheckpointSHA256": hashlib.sha256(head_bytes).hexdigest(),
        "baseCheckpointSHA256": fold7_sha,
        "labels": labels,
        "supportedVocabularyIndices": indices,
        "weightShape": list(weight.shape),
        "biasShape": list(bias.shape),
        "weight": weight.detach().float().tolist(),
        "bias": bias.detach().float().tolist(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "headCheckpointSHA256": document["headCheckpointSHA256"],
                      "baseCheckpointSHA256": fold7_sha, "outputClassCount": len(indices)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
