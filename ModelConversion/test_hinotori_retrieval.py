import torch
import unittest
from hinotori_retrieval import class_retrieval_logits, top_candidates


def anchors():
    values = torch.eye(229, dtype=torch.float32)
    labels = torch.arange(229, dtype=torch.long)
    return values, labels


class HinotoriRetrievalTests(unittest.TestCase):
    def test_duplicate_anchor_changes_existing_class_score(self):
        values, labels = anchors()
        query = values[0:1]
        original = class_retrieval_logits(query, values, labels, 229, 0.1)
        duplicated = class_retrieval_logits(
            query, torch.cat((values, values[0:1])),
            torch.cat((labels, labels[0:1])), 229, 0.1,
        )
        self.assertAlmostEqual((duplicated[0, 0] - original[0, 0]).item(), torch.log(torch.tensor(2.0)).item(), places=5)
        torch.testing.assert_close(duplicated[0, 1:], original[0, 1:])

    def test_exact_anchor_is_top_candidate(self):
        values, labels = anchors()
        scores, indices = top_candidates(values[17:18], values, labels, 229, 0.1)
        self.assertEqual(indices[0, 0].item(), 17)
        self.assertGreater(scores[0, 0], scores[0, 1])

    def test_missing_class_fails_instead_of_smoothing(self):
        values, labels = anchors()
        with self.assertRaisesRegex(ValueError, "no anchors"):
            class_retrieval_logits(values[:1], values[:-1], labels[:-1], 229, 0.1)


if __name__ == "__main__":
    unittest.main()
