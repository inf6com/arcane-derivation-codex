import unittest

import torch

from hinotori_weak_multiset import sinkhorn_multiset_loss


class WeakMultisetTests(unittest.TestCase):
    def test_matching_retrieval_logits_have_lower_loss(self):
        counts = torch.zeros(1, 229)
        counts[0, 7] = 1
        counts[0, 13] = 1
        matching = torch.full((1, 2, 229), -8.0)
        matching[0, 0, 7] = 8.0
        matching[0, 1, 13] = 8.0
        reversed_logits = torch.full((1, 2, 229), -8.0)
        reversed_logits[0, :, 2] = 8.0
        self.assertLess(sinkhorn_multiset_loss(matching, counts), sinkhorn_multiset_loss(reversed_logits, counts))

    def test_loss_has_gradient_for_retrieval_logits(self):
        logits = torch.randn(1, 3, 229, requires_grad=True)
        counts = torch.zeros(1, 229)
        counts[0, 5] = 2
        counts[0, 21] = 1
        loss = sinkhorn_multiset_loss(logits, counts)
        loss.backward()
        self.assertTrue(torch.isfinite(loss))
        self.assertIsNotNone(logits.grad)
        self.assertTrue(torch.isfinite(logits.grad).all())

    def test_empty_multiset_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "nonempty"):
            sinkhorn_multiset_loss(torch.zeros(1, 1, 229), torch.zeros(1, 229))


if __name__ == "__main__":
    unittest.main()
