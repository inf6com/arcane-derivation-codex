import unittest

import torch

from hinotori_latent_training import class_absence_loss, direct_membership_loss, weak_multiset_loss


class LatentTrainingTests(unittest.TestCase):
    def test_weak_loss_prefers_matching_active_class_mass(self):
        logits = torch.full((2, 229), -20.0)
        logits[0, 3] = 20.0
        logits[1, 7] = 20.0
        target = torch.zeros(229)
        target[3] = 1
        target[7] = 1
        matching = weak_multiset_loss(logits, torch.ones(2), target)
        wrong = weak_multiset_loss(logits, torch.ones(2), torch.zeros(229).scatter_(0, torch.tensor([4, 8]), 1))
        self.assertLess(matching, wrong)

    def test_direct_membership_prefers_correct_affinity(self):
        correct = torch.tensor([[1.0, 0.9, 0.1], [0.9, 1.0, 0.1], [0.1, 0.1, 1.0]])
        wrong = torch.tensor([[1.0, 0.1, 0.9], [0.1, 1.0, 0.9], [0.9, 0.9, 1.0]])
        self.assertLess(direct_membership_loss(correct, [[0, 1], [2]]), direct_membership_loss(wrong, [[0, 1], [2]]))

    def test_absence_loss_penalizes_target_class_mass(self):
        absent = torch.full((2, 229), -20.0)
        absent[:, 5] = -30.0
        present = torch.full((2, 229), -20.0)
        present[:, 5] = 20.0
        self.assertLess(class_absence_loss(absent, torch.ones(2), 5), class_absence_loss(present, torch.ones(2), 5))


if __name__ == "__main__":
    unittest.main()
