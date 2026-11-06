#!/usr/bin/env python3
"""Migrate the persisted Symbol229 checkpoint metadata to Hinotori in a new artifact."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import torch

from hinotori_model import HinotoriRetrievalModel


OLD_CONTRACT = "symbol229-retrieval-v1"
NEW_CONTRACT = "hinotori-retrieval-v1"
OLD_STAGE = "symbol229-shared-retrieval-membership-batch-pass-v2"
NEW_STAGE = "hinotori-shared-retrieval-membership-batch-pass-v2"


def state_digest(state: dict[str, torch.Tensor]) -> str:
    digest = hashlib.sha256()
    for key in sorted(state):
        tensor = state[key].detach().cpu().contiguous()
        digest.update(key.encode("utf-8"))
        digest.update(str(tensor.dtype).encode("ascii"))
        digest.update(json.dumps(list(tensor.shape)).encode("ascii"))
        digest.update(tensor.view(torch.uint8).numpy().tobytes())
    return digest.hexdigest()


def rename_metadata(value: object) -> object:
    if isinstance(value, dict):
        return {key: rename_metadata(item) for key, item in value.items()}
    if isinstance(value, list):
        return [rename_metadata(item) for item in value]
    if isinstance(value, str):
        return value.replace("symbol229-", "hinotori-")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not args.checkpoint.is_file():
        raise FileNotFoundError(f"checkpoint does not exist: {args.checkpoint}")
    if args.output.exists() or args.report.exists():
        raise FileExistsError("migration output and report paths must not already exist")

    source_bytes = args.checkpoint.read_bytes()
    source = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    if source.get("contract") != OLD_CONTRACT or source.get("stageContract") != OLD_STAGE:
        raise ValueError("checkpoint does not have the exact legacy contracts this migration supports")
    if source.get("mpsRequired") is not True:
        raise ValueError("checkpoint is not marked as an MPS-trained artifact")
    state = source.get("modelState")
    if not isinstance(state, dict) or not all(isinstance(value, torch.Tensor) for value in state.values()):
        raise ValueError("checkpoint modelState is missing or malformed")

    model = HinotoriRetrievalModel()
    model.load_state_dict(state, strict=True)
    before_state_hash = state_digest(state)

    migrated = dict(source)
    migrated["contract"] = NEW_CONTRACT
    migrated["stageContract"] = NEW_STAGE
    migrated["classSchedule"] = rename_metadata(source.get("classSchedule"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(migrated, args.output)

    reopened = torch.load(args.output, map_location="cpu", weights_only=False)
    if reopened.get("contract") != NEW_CONTRACT or reopened.get("stageContract") != NEW_STAGE:
        raise ValueError("migrated checkpoint did not retain the Hinotori contracts")
    model.load_state_dict(reopened["modelState"], strict=True)
    after_state_hash = state_digest(reopened["modelState"])
    if before_state_hash != after_state_hash:
        raise ValueError("model weights changed during metadata migration")

    report = {
        "operation": "EXPLICIT_CHECKPOINT_METADATA_MIGRATION",
        "sourcePath": str(args.checkpoint),
        "sourceSHA256": hashlib.sha256(source_bytes).hexdigest(),
        "outputPath": str(args.output),
        "outputSHA256": hashlib.sha256(args.output.read_bytes()).hexdigest(),
        "sourceContract": OLD_CONTRACT,
        "outputContract": NEW_CONTRACT,
        "sourceStageContract": OLD_STAGE,
        "outputStageContract": NEW_STAGE,
        "modelStateSHA256BeforeAndAfter": before_state_hash,
        "strictHinotoriStateLoad": True,
        "nextWeakPair": source.get("nextWeakPair"),
        "trainingStatePreserved": all(key in reopened for key in ("optimizerState", "generatorState", "classSchedule")),
    }
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
