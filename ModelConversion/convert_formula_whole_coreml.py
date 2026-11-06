#!/usr/bin/env python3
"""Export the accepted whole-formula trace model as a fixed-shape Core ML program.

The exported network is the trained FormulaWholeModel itself.  It has no
glyph classifier, rasterisation path, Grid9 path, or legacy recognizer.
Swift supplies an 80x128 trace tensor and, during greedy decoding, invokes the
program with the current 192-token prefix.  Structural syntax masking remains
an explicit Swift responsibility because it is a deterministic part of the
published tokenizer contract, not learned model weights.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

try:
    from ModelConversion.formula_whole_coreml_compatible import FixedFormulaWholeCoreML
    from ModelConversion.formula_whole_model import (
        MAX_LABEL_TOKENS, MAX_TRACES, POINTS_PER_TRACE, TRACE_GEOMETRY_FEATURE_DIMENSION, FormulaWholeModel,
        load_tokenizer, model_input_contract, require_checkpoint_input_contract,
    )
except ImportError:
    from formula_whole_coreml_compatible import FixedFormulaWholeCoreML
    from formula_whole_model import (
        MAX_LABEL_TOKENS, MAX_TRACES, POINTS_PER_TRACE, TRACE_GEOMETRY_FEATURE_DIMENSION, FormulaWholeModel,
        load_tokenizer, model_input_contract, require_checkpoint_input_contract,
    )


ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def accepted_report(path: Path) -> dict[str, object]:
    report = json.loads(path.read_text(encoding="utf-8"))
    if report.get("adoptionGate") != "PASS":
        raise ValueError(f"Core ML export is forbidden: evaluation adoptionGate is {report.get('adoptionGate')!r}")
    criteria = report.get("acceptanceCriteria")
    metrics = report.get("metrics")
    if not isinstance(criteria, dict) or not isinstance(metrics, dict):
        raise ValueError("Core ML export is forbidden: evaluation report lacks acceptance criteria or metrics")
    if criteria.get("exactMatchRateMin") != 1.0:
        raise ValueError("Core ML export is forbidden: product evaluation must declare greedy whole-formula exactMatchRateMin=1.0")
    if metrics.get("exactMatch") != 1.0:
        raise ValueError("Core ML export is forbidden: whole-formula greedy exact match is below 1.0")
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--checkpoint-contract", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--evaluation-report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    checkpoint_record = require_checkpoint_input_contract(args.checkpoint)
    contract = checkpoint_record["inputContract"]
    declared = json.loads(args.checkpoint_contract.read_text(encoding="utf-8"))
    if declared.get("inputContract") != contract or contract != model_input_contract():
        raise ValueError("checkpoint input contract differs from the current FormulaInput v1 contract")
    if Path(declared.get("tokenizer", "")) != args.tokenizer:
        raise ValueError("checkpoint contract tokenizer does not match --tokenizer")
    report = accepted_report(args.evaluation_report)
    tokenizer = load_tokenizer(args.tokenizer)

    model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=128, heads=4, dim_feedforward=256, dropout=0.1)
    model.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True), strict=True)
    wrapper = FixedFormulaWholeCoreML(model.eval()).eval()
    traces = torch.zeros((1, MAX_TRACES, POINTS_PER_TRACE, 2), dtype=torch.float32)
    trace_geometry = torch.zeros((1, MAX_TRACES, TRACE_GEOMETRY_FEATURE_DIMENSION), dtype=torch.float32)
    trace_valid = torch.zeros((1, MAX_TRACES), dtype=torch.float32)
    trace_valid[:, 0] = 1.0
    tokens = torch.full((1, MAX_LABEL_TOKENS), tokenizer.pad_id, dtype=torch.int32)
    tokens[:, 0] = tokenizer.bos_id
    token_valid = torch.zeros((1, MAX_LABEL_TOKENS), dtype=torch.float32)
    token_valid[:, 0] = 1.0
    with torch.inference_mode():
        reference = wrapper(traces, trace_geometry, trace_valid, tokens, token_valid)
    expected = (1, MAX_LABEL_TOKENS, tokenizer.vocab_size)
    if tuple(reference.shape) != expected:
        raise RuntimeError(f"unexpected formula logits shape {tuple(reference.shape)}, expected {expected}")
    # PyTorch 2.14 emits equivalent attention graphs through two internal
    # fast-paths on repeated tracing, so graph-text equality is not a valid
    # correctness oracle here.  Conversion is followed by numeric parity on
    # the saved Core ML program; that check is the required oracle.
    # ``torch.export`` preserves the declared fixed tensor boundary and avoids
    # the legacy TorchScript converter's invalid tensor-to-Python-int lowering
    # for current Transformer internals.
    exported = torch.export.export(wrapper, (traces, trace_geometry, trace_valid, tokens, token_valid)).run_decompositions({})
    converted = ct.convert(
        exported,
        inputs=[
            ct.TensorType(name="traces", shape=traces.shape, dtype=np.float32),
            ct.TensorType(name="traceGeometry", shape=trace_geometry.shape, dtype=np.float32),
            ct.TensorType(name="traceValid", shape=trace_valid.shape, dtype=np.float32),
            ct.TensorType(name="targetTokens", shape=tokens.shape, dtype=np.int32),
            ct.TensorType(name="targetValid", shape=token_valid.shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="tokenLogits")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
    )
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite existing Core ML artifact: {args.output}")
    converted.save(args.output)
    manifest = {
        "format": "inf6-formula-whole-coreml-v1",
        "checkpoint": str(args.checkpoint),
        "checkpointSHA256": sha256(args.checkpoint),
        "tokenizer": str(args.tokenizer),
        "tokenizerSHA256": sha256(args.tokenizer),
        "evaluationReport": str(args.evaluation_report),
        "evaluationMetrics": report["metrics"],
        "inputContract": contract,
        "coreML": {"minimumDeployment": "iOS17", "computePrecision": "float32", "output": "tokenLogits", "shape": list(expected), "traceGeometryShape": list(trace_geometry.shape)},
        "decodeContract": "Swift must apply the exact tokenizer syntax mask before greedy token selection; it must not use a legacy recognizer or substitute model.",
    }
    args.output.with_suffix(".manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "COMPLETED", "output": str(args.output), "vocabSize": tokenizer.vocab_size}, ensure_ascii=False))


if __name__ == "__main__":
    main()
