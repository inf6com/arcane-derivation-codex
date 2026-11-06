import unittest

import torch

from hinotori_coreml_compatible import HinotoriAffinityCoreML, HinotoriRetrievalCoreML
from hinotori_model import HinotoriRetrievalModel
from hinotori_retrieval import class_retrieval_logits


class HinotoriCoreMLCompatibleTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(17)
        self.model = HinotoriRetrievalModel(embedding_dimension=8, hidden_dimension=8, point_count=3).eval()
        self.classes = torch.arange(229, dtype=torch.int64)
        self.anchors = torch.randn(229, 2, 3, 2)
        self.anchor_valid = torch.ones(229, 2)

    def test_affinity_view_matches_existing_singleton_path(self):
        points = torch.randn(1, 4, 3, 2)
        valid = torch.tensor([[1.0, 1.0, 1.0, 0.0]])
        view = HinotoriAffinityCoreML(self.model)
        observed_affinity, observed_embeddings = view(points, valid)
        expected_embeddings = self.model.encode_groups([points[0, index:index + 1] for index in range(3)])
        expected_affinity = self.model.group_proposer(expected_embeddings.unsqueeze(0), torch.zeros((1, 3), dtype=torch.bool))[0]
        self.assertTrue(torch.allclose(observed_embeddings[:3], expected_embeddings, atol=1e-6, rtol=1e-6))
        self.assertTrue(torch.allclose(observed_affinity[:3, :3], expected_affinity, atol=1e-6, rtol=1e-6))

    def test_retrieval_view_matches_existing_class_retrieval(self):
        query = torch.randn(1, 2, 3, 2)
        query_valid = torch.tensor([[1.0, 1.0]])
        view = HinotoriRetrievalCoreML(self.model, self.classes)
        observed, query_embeddings, anchor_embeddings = view(query, query_valid, self.anchors, self.anchor_valid)
        expected_query = self.model.encode_groups([query[0]])
        expected_anchor = self.model.encode_groups([self.anchors[index] for index in range(229)])
        expected = class_retrieval_logits(expected_query, expected_anchor, self.classes, 229, self.model.temperature)
        self.assertTrue(torch.allclose(query_embeddings, expected_query, atol=1e-6, rtol=1e-6))
        self.assertTrue(torch.allclose(anchor_embeddings, expected_anchor, atol=1e-6, rtol=1e-6))
        self.assertTrue(torch.allclose(observed, expected, atol=1e-6, rtol=1e-6))


if __name__ == "__main__":
    unittest.main()
