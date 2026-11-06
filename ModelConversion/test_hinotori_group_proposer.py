import unittest
import torch
from hinotori_group_proposer import direct_pair_targets, StrokePairAffinity, affinity_loss, decode_groups


class GroupProposerTests(unittest.TestCase):
    def test_direct_pair_targets_only_supervise_annotated_traces(self):
        target, mask = direct_pair_targets(5, [[0, 2], [1]])
        self.assertTrue(mask[0, 2])
        self.assertEqual(target[0, 2].item(), 1.0)
        self.assertTrue(mask[0, 1])
        self.assertEqual(target[0, 1].item(), 0.0)
        self.assertFalse(mask[3, 4])

    def test_overlap_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "belongs"):
            direct_pair_targets(3, [[0, 1], [1, 2]])

    def test_masked_pairs_are_not_used_by_loss(self):
        model = StrokePairAffinity(4)
        logits = model(torch.randn(1, 4, 4), torch.tensor([[False, False, False, True]]))
        targets, mask = direct_pair_targets(4, [[0, 1], [2]])
        loss = affinity_loss(logits, targets.unsqueeze(0), mask.unsqueeze(0))
        self.assertTrue(torch.isfinite(loss))

    def test_decoder_uses_learned_probability_not_geometry(self):
        logits = torch.tensor([[0.0, 2.0, -2.0], [2.0, 0.0, -2.0], [-2.0, -2.0, 0.0]])
        self.assertEqual(decode_groups(logits, torch.tensor([False, False, False])), [[0, 1], [2]])

    def test_decoder_rejects_nonfinite_unmasked_logits(self):
        with self.assertRaisesRegex(ValueError, "finite"):
            decode_groups(torch.tensor([[0.0, float("nan")], [float("nan"), 0.0]]), torch.tensor([False, False]))


if __name__ == "__main__":
    unittest.main()
