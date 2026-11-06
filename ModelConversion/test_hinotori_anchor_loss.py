import unittest

import torch

from hinotori_anchor_loss import direct_anchor_metric_loss


class AnchorMetricLossTests(unittest.TestCase):
    def test_same_class_alignment_has_lower_loss(self):
        anchors = torch.tensor([[1.0, 0.0], [0.0, 1.0]])
        classes = torch.tensor([3, 8], dtype=torch.int64)
        aligned = torch.tensor([[1.0, 0.0], [0.0, 1.0]])
        swapped = torch.tensor([[0.0, 1.0], [1.0, 0.0]])
        self.assertLess(
            direct_anchor_metric_loss(aligned, classes, anchors, classes),
            direct_anchor_metric_loss(swapped, classes, anchors, classes),
        )

    def test_missing_positive_anchor_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "same class"):
            direct_anchor_metric_loss(
                torch.tensor([[1.0, 0.0]]),
                torch.tensor([4], dtype=torch.int64),
                torch.tensor([[1.0, 0.0]]),
                torch.tensor([5], dtype=torch.int64),
            )

    def test_loss_has_gradient(self):
        query = torch.randn(2, 4, requires_grad=True)
        anchors = torch.randn(3, 4)
        loss = direct_anchor_metric_loss(query, torch.tensor([2, 7]), anchors, torch.tensor([2, 7, 7]))
        loss.backward()
        self.assertTrue(torch.isfinite(query.grad).all())


if __name__ == "__main__":
    unittest.main()
