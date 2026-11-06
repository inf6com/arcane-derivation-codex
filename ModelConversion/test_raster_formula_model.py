#!/usr/bin/env python3
"""Byte-parity test for the only raster input contract."""
from __future__ import annotations
import hashlib
from pathlib import Path
from formula_whole_input import load_formula_input
from raster_formula_model import rasterize_formula_v1

ROOT = Path(__file__).resolve().parents[1]
fixture = ROOT / "runs/agent-control/cycle349-raster-python-fixture.pgm"
sample = ROOT / "ModelConversion/formula-whole-input-fixtures/wholeformula-fixture-a.inkml"
formula, _ = load_formula_input(sample)
actual = rasterize_formula_v1(formula)
expected = fixture.read_bytes()
if actual != expected:
    raise SystemExit(f"FormulaRasterV1 byte mismatch expected={hashlib.sha256(expected).hexdigest()} actual={hashlib.sha256(actual).hexdigest()}")
if hashlib.sha256(actual).hexdigest() != "a6aa3c1af8d6b0b27357bc104435ee0b5f636a2b5f2104395758fbb26f388b97":
    raise SystemExit("unexpected FormulaRasterV1 fixture hash")
print("FORMULA_RASTER_V1_PARITY_OK")
