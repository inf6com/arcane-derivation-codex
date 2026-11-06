import math
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import torch

try:  # `python3 -m unittest ModelConversion.test_formula_whole_model` from the repo root
    from ModelConversion.formula_whole_model import (
        MAX_TRACES,
        MODEL_INPUT_CONTRACT_VERSION,
        POINTS_PER_TRACE,
        TRACE_GEOMETRY_FEATURE_DIMENSION,
        FormulaWholeModel,
        TooManyTracesError,
        load_tokenizer,
        model_input_contract,
        prepare_traces,
        prepare_trace_geometry,
        require_checkpoint_input_contract,
        verify_execution_device,
        resample_trace,
        syntax_allowed_mask,
    )
except ImportError:  # discovered/run directly from inside ModelConversion/
    from formula_whole_model import (
        MAX_TRACES,
        MODEL_INPUT_CONTRACT_VERSION,
        POINTS_PER_TRACE,
        TRACE_GEOMETRY_FEATURE_DIMENSION,
        FormulaWholeModel,
        TooManyTracesError,
        load_tokenizer,
        model_input_contract,
        prepare_traces,
        prepare_trace_geometry,
        require_checkpoint_input_contract,
        verify_execution_device,
        resample_trace,
        syntax_allowed_mask,
    )

HERE = Path(__file__).parent
# On-device layout: this file lives in ModelConversion/; the shared tokenizer
# artifact (built by the local automation loop) lives in
# runs/agent-control/ at the repo root, not alongside this script.
TOKENIZER_PATH = HERE.parent / "runs" / "agent-control" / "formula-whole-label-tokenizer-20260927.json"
STRUCTURE_TOKENIZER_PATH = HERE.parent / "runs" / "agent-control" / "formula-whole-structure-tokenizer-20260927.json"


class ResampleTraceTests(unittest.TestCase):
    def test_output_length_is_always_points_per_trace(self):
        for raw in ([(0.0, 0.0)], [(0.0, 0.0), (1.0, 1.0)], [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]):
            self.assertEqual(len(resample_trace(raw, count=8)), 8)

    def test_single_point_trace_repeats_the_point(self):
        result = resample_trace([(0.3, 0.7)], count=5)
        self.assertEqual(result, [(0.3, 0.7)] * 5)

    def test_endpoints_are_included_on_a_straight_line(self):
        result = resample_trace([(0.0, 0.0), (10.0, 0.0)], count=5)
        self.assertEqual(result[0], (0.0, 0.0))
        self.assertEqual(result[-1], (10.0, 0.0))
        # Equal arc-length spacing on a straight line: linear in x.
        for i, (x, y) in enumerate(result):
            self.assertAlmostEqual(x, 10.0 * i / 4, places=9)
            self.assertAlmostEqual(y, 0.0, places=9)

    def test_zero_length_trace_repeats_the_first_point_instead_of_dividing_by_zero(self):
        result = resample_trace([(2.0, 2.0), (2.0, 2.0), (2.0, 2.0)], count=4)
        self.assertEqual(result, [(2.0, 2.0)] * 4)


class PrepareTracesTests(unittest.TestCase):
    def test_selected_contract_is_128_point_float32_tensor(self):
        self.assertEqual(POINTS_PER_TRACE, 128)
        self.assertEqual(MODEL_INPUT_CONTRACT_VERSION, "inf6-formula-whole-trace-v4-128pt-geometry9")
        self.assertEqual(model_input_contract()["shape"], "[trace,128,2]")
        self.assertEqual(model_input_contract()["dtype"], "float32")
        self.assertEqual(model_input_contract()["traceGeometryShape"], "[trace,9]")
        self.assertEqual(model_input_contract()["traceGeometryFeatureDimension"], TRACE_GEOMETRY_FEATURE_DIMENSION)

    def test_shape_is_fixed_regardless_of_raw_point_counts(self):
        traces = [[(0.0, 0.0), (1.0, 1.0)], [(0.5, 0.5)] * 100]
        tensor = prepare_traces(traces)
        self.assertEqual(tuple(tensor.shape), (2, POINTS_PER_TRACE, 2))
        self.assertEqual(tensor.dtype, torch.float32)

    def test_too_many_traces_raises_instead_of_silently_truncating(self):
        traces = [[(0.0, 0.0), (1.0, 1.0)]] * (MAX_TRACES + 1)
        with self.assertRaises(TooManyTracesError):
            prepare_traces(traces)

    def test_geometry_shape_and_normalized_range_are_enforced(self):
        tensor = prepare_trace_geometry([(0.0, 0.1, 0.2, 0.3, 0.1, 0.2, 0.2, 0.2, 0.0)])
        self.assertEqual(tuple(tensor.shape), (1, TRACE_GEOMETRY_FEATURE_DIMENSION))
        with self.assertRaisesRegex(ValueError, "requires 9 features"):
            prepare_trace_geometry([(0.0,)])
        with self.assertRaisesRegex(ValueError, "normalized to \\[0,1\\]"):
            prepare_trace_geometry([(0.0, 0.1, 1.2, 0.3, 0.1, 0.2, 0.2, 0.2, 0.0)])


class CheckpointContractTests(unittest.TestCase):
    def test_checkpoint_without_contract_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "best.pt"
            checkpoint.touch()
            with self.assertRaisesRegex(ValueError, "no input-contract record"):
                require_checkpoint_input_contract(checkpoint)

    def test_checkpoint_with_exact_contract_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "best.pt"
            checkpoint.touch()
            (checkpoint.parent / "checkpoint-contract.json").write_text(
                json.dumps({"checkpoint": checkpoint.name, "inputContract": model_input_contract()}), encoding="utf-8"
            )
            self.assertEqual(require_checkpoint_input_contract(checkpoint)["inputContract"], model_input_contract())


class ExecutionDeviceTests(unittest.TestCase):
    def test_cpu_is_allowed_only_when_mps_is_measured_unavailable(self):
        with mock.patch("torch.backends.mps.is_built", return_value=True), mock.patch(
            "torch.backends.mps.is_available", return_value=False
        ):
            self.assertEqual(verify_execution_device("cpu")["mpsAvailable"], False)

    def test_cpu_is_rejected_when_mps_is_available(self):
        with mock.patch("torch.backends.mps.is_built", return_value=True), mock.patch(
            "torch.backends.mps.is_available", return_value=True
        ):
            with self.assertRaisesRegex(RuntimeError, "CPU execution is forbidden"):
                verify_execution_device("cpu")

    def test_explicit_cpu_comparison_is_allowed_when_mps_is_available(self):
        with mock.patch("torch.backends.mps.is_built", return_value=True), mock.patch(
            "torch.backends.mps.is_available", return_value=True
        ):
            evidence = verify_execution_device("cpu", cpu_comparison=True)
            self.assertTrue(evidence["cpuComparison"])

    def test_mps_request_surfaces_unavailability(self):
        with mock.patch("torch.backends.mps.is_built", return_value=True), mock.patch(
            "torch.backends.mps.is_available", return_value=False
        ):
            with self.assertRaisesRegex(RuntimeError, "MPS was requested but is unavailable"):
                verify_execution_device("mps")


class TokenizerTests(unittest.TestCase):
    def test_loads_shared_artifact_and_round_trips(self):
        tokenizer = load_tokenizer(TOKENIZER_PATH)
        self.assertEqual(tokenizer.vocab_size, 93)
        label = "x^{2}+y=1"
        encoded = tokenizer.encode(label)
        self.assertEqual(encoded[0], tokenizer.bos_id)
        self.assertEqual(encoded[-1], tokenizer.eos_id)
        self.assertEqual(tokenizer.decode(encoded), label)

    def test_out_of_vocabulary_character_is_an_error_not_a_silent_unk(self):
        tokenizer = load_tokenizer(TOKENIZER_PATH)
        with self.assertRaises(ValueError):
            tokenizer.encode("あ")  # a Japanese character never appears in normalizedLabel


class ModelForwardShapeTests(unittest.TestCase):
    def test_forward_pass_produces_logits_shaped_for_the_vocabulary(self):
        tokenizer = load_tokenizer(TOKENIZER_PATH)
        model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=32, heads=4, dim_feedforward=64)
        traces = torch.zeros(2, 3, POINTS_PER_TRACE, 2)
        geometry = torch.zeros(2, 3, TRACE_GEOMETRY_FEATURE_DIMENSION)
        trace_mask = torch.zeros(2, 3, dtype=torch.bool)
        target_input = torch.tensor([[tokenizer.bos_id, 10, 11], [tokenizer.bos_id, 12, tokenizer.pad_id]])
        target_mask = torch.tensor([[False, False, False], [False, False, True]])
        logits = model(traces, geometry, trace_mask, target_input, target_mask)
        self.assertEqual(tuple(logits.shape), (2, 3, tokenizer.vocab_size))
        self.assertTrue(torch.isfinite(logits).all())

    def test_geometry_shape_mismatch_fails_before_encoder_computation(self):
        tokenizer = load_tokenizer(TOKENIZER_PATH)
        model = FormulaWholeModel(vocab_size=tokenizer.vocab_size, d_model=32, heads=4, dim_feedforward=64)
        traces = torch.zeros(1, 2, POINTS_PER_TRACE, 2)
        geometry = torch.zeros(1, 2, TRACE_GEOMETRY_FEATURE_DIMENSION - 1)
        trace_mask = torch.zeros(1, 2, dtype=torch.bool)
        target = torch.tensor([[tokenizer.bos_id]])
        with self.assertRaisesRegex(ValueError, "trace geometry shape"):
            model(traces, geometry, trace_mask, target, torch.zeros_like(target, dtype=torch.bool))


class SyntaxMaskAlignmentTests(unittest.TestCase):
    def test_bos_requires_a_formula_token_before_eos(self):
        tokenizer = load_tokenizer(STRUCTURE_TOKENIZER_PATH)
        prefix = torch.tensor([[tokenizer.bos_id]])
        mask = syntax_allowed_mask(prefix, tokenizer)
        self.assertFalse(bool(mask[0, 0, tokenizer.eos_id]))
        self.assertTrue(bool(mask[0, 0, tokenizer.tokens.index("x")]))

    def test_curly_group_requires_matching_curly_closer_but_allows_visual_symbols(self):
        tokenizer = load_tokenizer(STRUCTURE_TOKENIZER_PATH)
        prefix = torch.tensor([[tokenizer.bos_id, tokenizer.token_to_id["{"]]])
        mask = syntax_allowed_mask(prefix, tokenizer)
        self.assertTrue(bool(mask[0, 1, tokenizer.token_to_id["}"]]))
        self.assertTrue(bool(mask[0, 1, tokenizer.token_to_id["]"]]))
        self.assertTrue(bool(mask[0, 1, tokenizer.token_to_id[")"]]))

    def test_script_marker_requires_an_operand_before_closure_or_eos(self):
        tokenizer = load_tokenizer(STRUCTURE_TOKENIZER_PATH)
        prefix = torch.tensor([[tokenizer.bos_id, tokenizer.token_to_id["x"], tokenizer.token_to_id["^"]]])
        mask = syntax_allowed_mask(prefix, tokenizer)
        self.assertFalse(bool(mask[0, 2, tokenizer.token_to_id["}"]]))
        self.assertFalse(bool(mask[0, 2, tokenizer.eos_id]))
        self.assertFalse(bool(mask[0, 2, tokenizer.token_to_id["^"]]))
        self.assertFalse(bool(mask[0, 2, tokenizer.token_to_id["_"]]))

    def test_matrix_environment_sequence_and_matching_end_are_masked(self):
        tokenizer = load_tokenizer(STRUCTURE_TOKENIZER_PATH)
        label = r"\begin{matrix}x\end{matrix}"
        encoded = tokenizer.encode(label)
        begin_position = encoded.index(tokenizer.token_to_id["\\begin"])
        mask = syntax_allowed_mask(torch.tensor([encoded[: begin_position + 1]]), tokenizer)
        self.assertTrue(bool(mask[0, begin_position, tokenizer.token_to_id["{"]]))
        self.assertFalse(bool(mask[0, begin_position, tokenizer.token_to_id["m"]]))

        begin_open_position = begin_position + 1
        mask = syntax_allowed_mask(torch.tensor([encoded[: begin_open_position + 1]]), tokenizer)
        self.assertTrue(bool(mask[0, begin_open_position, tokenizer.token_to_id["m"]]))
        self.assertFalse(bool(mask[0, begin_open_position, tokenizer.token_to_id["x"]]))

        end_position = encoded.index(tokenizer.token_to_id["\\end"])
        mask = syntax_allowed_mask(torch.tensor([encoded[: end_position + 1]]), tokenizer)
        self.assertTrue(bool(mask[0, end_position, tokenizer.token_to_id["{"]]))
        self.assertFalse(bool(mask[0, end_position, tokenizer.eos_id]))

        first_environment_close = encoded.index(tokenizer.token_to_id["}"], begin_open_position)
        mask = syntax_allowed_mask(torch.tensor([encoded[: first_environment_close + 1]]), tokenizer)
        self.assertFalse(bool(mask[0, first_environment_close, tokenizer.token_to_id["\\begin"]]))

        self.assertEqual(
            tuple(syntax_allowed_mask(torch.tensor([encoded[:-1]]), tokenizer).shape),
            (1, len(encoded) - 1, tokenizer.vocab_size),
        )

    def test_latex_visual_delimiters_can_cross_curly_group_boundaries(self):
        tokenizer = load_tokenizer(STRUCTURE_TOKENIZER_PATH)
        label = r"m=\frac{m_{9}}{({1\cdot\frac{v^{5}}{c^{5}})}^{4/5}}"
        prefix = torch.tensor([tokenizer.encode(label)[:-1]])
        mask = syntax_allowed_mask(prefix, tokenizer)
        self.assertEqual(tuple(mask.shape), (1, prefix.shape[1], tokenizer.vocab_size))

    def test_escaped_closing_curly_is_not_consumed_as_a_group_delimiter(self):
        tokenizer = load_tokenizer(TOKENIZER_PATH)
        label = r"[Q^{\dagger},x\}=ib^{\dagger}"
        prefix = torch.tensor([tokenizer.encode(label)[:-1]])
        mask = syntax_allowed_mask(prefix, tokenizer)
        self.assertTrue(bool(mask[0, -1, tokenizer.eos_id]))


if __name__ == "__main__":
    unittest.main()
