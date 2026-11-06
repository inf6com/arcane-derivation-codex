import unittest
import json
import tempfile
from pathlib import Path

import torch

from hinotori_model import HinotoriRetrievalModel
from hinotori_training import direct_grouping_loss, direct_retrieval_loss, weak_class_presence_loss, weak_formula_loss
from train_hinotori_retrieval import grouped_direct_examples, load_grouped_direct_example


def anchors() -> tuple[list[torch.Tensor], torch.Tensor]:
    return [torch.tensor([[[0.0, 0.0], [1.0, 0.0], [0.0, 0.0]]]) for _ in range(229)], torch.arange(229, dtype=torch.int64)


class TrainingWiringTests(unittest.TestCase):
    def test_direct_retrieval_loss_has_gradient(self):
        model = HinotoriRetrievalModel(8, 8, 3)
        groups, classes = anchors()
        loss = direct_retrieval_loss(model, groups[:2], classes[:2], groups, classes)
        loss.backward()
        self.assertTrue(torch.isfinite(loss))
        self.assertIsNotNone(model.encoder.output.weight.grad)

    def test_direct_grouping_loss_has_gradient(self):
        model = HinotoriRetrievalModel(8, 8, 3)
        traces = [torch.tensor([[0.0, 0.0], [1.0, 0.0]]), torch.tensor([[0.0, 1.0], [1.0, 1.0]]), torch.tensor([[0.0, 2.0], [1.0, 2.0]])]
        loss = direct_grouping_loss(model, traces, [[0, 1], [2]])
        loss.backward()
        self.assertTrue(torch.isfinite(loss))
        self.assertIsNotNone(model.group_proposer.projection.weight.grad)

    def test_direct_grouping_rejects_one_sided_pair_targets(self):
        model = HinotoriRetrievalModel(8, 8, 3)
        traces = [torch.tensor([[0.0, 0.0], [1.0, 0.0]]), torch.tensor([[0.0, 1.0], [1.0, 1.0]])]
        with self.assertRaisesRegex(ValueError, "both same-symbol"):
            direct_grouping_loss(model, traces, [[0], [1]])

    def test_weak_formula_loss_has_gradient(self):
        model = HinotoriRetrievalModel(8, 8, 3)
        groups, classes = anchors()
        target = torch.zeros(229)
        target[3] = 1
        loss = weak_formula_loss(model, [torch.tensor([[0.0, 0.0], [1.0, 0.0]])], target, groups, classes)
        loss.backward()
        self.assertTrue(torch.isfinite(loss))

    def test_weak_class_presence_loss_has_gradient(self):
        logits = torch.randn((3, 229), requires_grad=True)
        loss = weak_class_presence_loss(logits, 17)
        loss.backward()
        self.assertTrue(torch.isfinite(loss))
        self.assertIsNotNone(logits.grad)

    def test_grouping_examples_exclude_overlapping_direct_groups(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "train").mkdir()
            source = "formula"
            valid = "valid"
            ink = '<ink xmlns="http://www.w3.org/2003/InkML"><trace id="0">0 0,1 0</trace><trace id="1">1 0,2 0</trace><trace id="2">2 0,3 0</trace></ink>'
            (root / "train" / f"{source}.inkml").write_text(ink, encoding="utf-8")
            (root / "train" / f"{valid}.inkml").write_text(ink, encoding="utf-8")
            teachers = root / "teachers.jsonl"
            teachers.write_text("\n".join([
                json.dumps({"sourceSampleId": source, "strokeIndices": [0, 1]}),
                json.dumps({"sourceSampleId": source, "strokeIndices": [1]}),
                json.dumps({"sourceSampleId": valid, "strokeIndices": [0, 1]}),
                json.dumps({"sourceSampleId": valid, "strokeIndices": [2]}),
            ]) + "\n", encoding="utf-8")
            split = root / "split.json"
            split.write_text(json.dumps({"sourceSplit": {source: "train", valid: "train"}}), encoding="utf-8")
            examples = grouped_direct_examples(teachers, split)
            self.assertEqual(len(examples), 1)
            self.assertEqual(examples[0], (valid, [[0, 1], [2]]))
            traces, groups = load_grouped_direct_example(*examples[0], root)
            self.assertEqual(len(traces), 3)
            self.assertEqual(groups, [[0, 1], [2]])


if __name__ == "__main__":
    unittest.main()
