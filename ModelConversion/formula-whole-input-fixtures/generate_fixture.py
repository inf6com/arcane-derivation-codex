#!/usr/bin/env python3
"""Generate the FormulaInput v1 parity fixture from fixed InkML files.

This calls formula_whole_input.load_formula_input directly (the real,
tested parser) instead of re-deriving the normalization math by hand, so the
Swift-side fixture cannot silently drift from the Python reference.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).parent
MODEL_CONVERSION = HERE.parent
sys.path.insert(0, str(MODEL_CONVERSION))

from formula_whole_input import (
    TRACE_GEOMETRY_CONTRACT_VERSION,
    TRACE_GEOMETRY_FEATURE_DIMENSION,
    load_formula_input,
    _formula_input_json,
    model_features,
    trace_geometry_features,
)
from formula_whole_model import MODEL_INPUT_CONTRACT_VERSION, model_input_contract, prepare_traces

cases = ["wholeformula-fixture-a", "wholeformula-fixture-b"]
out = {}
for case in cases:
    formula, metadata = load_formula_input(HERE / f"{case}.inkml")
    out[case] = {
        "metadata": metadata,
        "formulaInput": _formula_input_json(formula),
        "modelTensor": prepare_traces([list(trace) for trace in model_features(formula)]).tolist(),
        "traceGeometry": [list(trace) for trace in trace_geometry_features(formula)],
    }

out["modelInputContract"] = model_input_contract()
out["modelInputContract"]["version"] = MODEL_INPUT_CONTRACT_VERSION
out["traceGeometryContract"] = {
    "version": TRACE_GEOMETRY_CONTRACT_VERSION,
    "dtype": "float32",
    "shape": "[trace,9]",
    "featureDimension": TRACE_GEOMETRY_FEATURE_DIMENSION,
    "normalization": "FormulaInput-v1-normalized-xy",
    "features": ["minX", "minY", "maxX", "maxY", "centroidX", "centroidY", "extentX", "extentY", "traceWriteProgress"],
}

(HERE / "formula-whole-input-fixture.json").write_text(
    json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print(json.dumps({case: out[case]["formulaInput"]["sourceBounds"] for case in cases}, indent=2))
