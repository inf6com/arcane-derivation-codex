import tempfile
import unittest
from pathlib import Path

import torch

from hinotori_inkml import canonical_group_tensor, read_inkml_traces, resample_stroke, select_annotated_group


class InkmlInputTests(unittest.TestCase):
    def test_declared_trace_ids_are_used_not_document_positions(self):
        document = '''<ink xmlns="http://www.w3.org/2003/InkML"><trace id="7">0 0,2 0</trace><trace id="3">0 1,2 1</trace></ink>'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.inkml"
            path.write_text(document, encoding="utf-8")
            strokes = select_annotated_group(read_inkml_traces(path), [3, 7])
        self.assertEqual(strokes[0][0].tolist(), [0.0, 1.0])
        self.assertEqual(strokes[1][-1].tolist(), [2.0, 0.0])

    def test_group_tensor_is_translation_and_scale_invariant(self):
        original = [torch.tensor([[0.0, 0.0], [2.0, 0.0]]), torch.tensor([[1.0, 1.0]])]
        moved = [stroke * 5 + torch.tensor([10.0, -3.0]) for stroke in original]
        self.assertTrue(torch.allclose(canonical_group_tensor(original, 4), canonical_group_tensor(moved, 4)))

    def test_missing_direct_trace_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "absent"):
            select_annotated_group({0: torch.zeros(1, 2)}, [1])

    def test_observed_dot_has_a_defined_zero_geometry(self):
        dot = canonical_group_tensor([torch.tensor([[4.0, 7.0], [4.0, 7.0]])], 3)
        self.assertTrue(torch.equal(dot, torch.zeros(1, 3, 2)))

    def test_repeated_endpoint_has_no_zero_length_division(self):
        result = resample_stroke(torch.tensor([[0.0, 0.0], [1.0, 0.0], [1.0, 0.0]]), 8)
        self.assertTrue(torch.isfinite(result).all())
        self.assertTrue(torch.equal(result[0], torch.tensor([0.0, 0.0])))
        self.assertTrue(torch.equal(result[-1], torch.tensor([1.0, 0.0])))


if __name__ == "__main__":
    unittest.main()
