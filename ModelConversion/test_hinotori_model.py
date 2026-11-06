import unittest

import torch

from hinotori_model import HinotoriRetrievalModel


class HinotoriModelTests(unittest.TestCase):
    def test_formula_path_returns_229_retrieval_scores_and_groups(self):
        model = HinotoriRetrievalModel(embedding_dimension=8, hidden_dimension=8, point_count=3)
        traces = [torch.tensor([[0.0, 0.0], [1.0, 0.0]]), torch.tensor([[0.0, 1.0], [1.0, 1.0]])]
        anchors = [torch.tensor([[[0.0, 0.0], [1.0, 0.0], [0.0, 0.0]]]) for _ in range(229)]
        classes = torch.arange(229, dtype=torch.int64)
        logits, groups, affinity = model.formula_retrieval_logits(traces, anchors, classes)
        self.assertEqual(tuple(logits.shape), (len(groups), 229))
        self.assertEqual(tuple(affinity.shape), (2, 2))
        self.assertEqual(sorted(index for group in groups for index in group), [0, 1])

    def test_group_encoding_rejects_wrong_point_contract(self):
        model = HinotoriRetrievalModel(embedding_dimension=4, hidden_dimension=4, point_count=3)
        with self.assertRaisesRegex(ValueError, "canonical"):
            model.encode_groups([torch.zeros(1, 2, 2)])


if __name__ == "__main__":
    unittest.main()
