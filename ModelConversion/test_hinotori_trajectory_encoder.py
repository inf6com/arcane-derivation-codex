import unittest

import torch

from hinotori_trajectory_encoder import TrajectoryGroupEncoder


class TrajectoryGroupEncoderTests(unittest.TestCase):
    def test_reversing_points_within_a_stroke_preserves_embedding(self):
        torch.manual_seed(42)
        model = TrajectoryGroupEncoder(16, hidden_dimension=8).eval()
        points = torch.tensor([[[[0.0, 0.0], [0.2, 0.4], [1.0, 0.5], [1.2, 0.1]]]])
        stroke_padding = torch.tensor([[False]])
        point_padding = torch.tensor([[[False, False, False, False]]])
        with torch.no_grad():
            forward = model(points, stroke_padding, point_padding)
            reversed_stroke = model(points.flip(dims=[2]), stroke_padding, point_padding)
        self.assertTrue(torch.allclose(forward, reversed_stroke, atol=1e-6))

    def test_emits_unit_retrieval_embeddings(self):
        model = TrajectoryGroupEncoder(16, hidden_dimension=8)
        points = torch.tensor([[[[0.0, 0.0], [1.0, 1.0], [0.0, 0.0]], [[2.0, 0.0], [0.0, 0.0], [0.0, 0.0]]]])
        stroke_padding = torch.tensor([[False, False]])
        point_padding = torch.tensor([[[False, False, True], [False, True, True]]])
        embedding = model(points, stroke_padding, point_padding)
        self.assertEqual(tuple(embedding.shape), (1, 16))
        self.assertTrue(torch.allclose(embedding.norm(dim=-1), torch.ones(1), atol=1e-6))

    def test_rejects_padded_stroke_with_points(self):
        model = TrajectoryGroupEncoder(8, hidden_dimension=4)
        with self.assertRaisesRegex(ValueError, "padded strokes"):
            model(
                torch.zeros(1, 1, 1, 2),
                torch.tensor([[True]]),
                torch.tensor([[[False]]]),
            )

    def test_rejects_empty_group(self):
        model = TrajectoryGroupEncoder(8, hidden_dimension=4)
        with self.assertRaisesRegex(ValueError, "at least one stroke"):
            model(
                torch.zeros(1, 1, 1, 2),
                torch.tensor([[True]]),
                torch.tensor([[[True]]]),
            )


if __name__ == "__main__":
    unittest.main()
