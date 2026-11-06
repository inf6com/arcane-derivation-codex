import json
import tempfile
import unittest
from pathlib import Path

from hinotori_direct_dataset import DirectAnchorDataset, collate_direct_anchors


class DirectAnchorDatasetTests(unittest.TestCase):
    def test_reads_exact_annotated_group_and_batches_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "train").mkdir()
            (root / "train" / "sample.inkml").write_text(
                '<ink xmlns="http://www.w3.org/2003/InkML"><trace id="0">0 0,1 0</trace><trace id="4">0 1,1 1</trace></ink>',
                encoding="utf-8",
            )
            teachers = root / "teachers.jsonl"
            teachers.write_text(json.dumps({"sourceSampleId": "sample", "strokeIndices": [4, 0], "classIndex": 17}) + "\n", encoding="utf-8")
            source_split = root / "split.json"
            source_split.write_text(json.dumps({"sourceSplit": {"sample": "train"}}), encoding="utf-8")
            dataset = DirectAnchorDataset(teachers, source_split, root, point_count=3, split="train")
            batch = collate_direct_anchors([dataset[0]])
        self.assertEqual(tuple(batch["points"].shape), (1, 2, 3, 2))
        self.assertEqual(batch["classIndices"].tolist(), [17])
        self.assertFalse(batch["strokePadding"].any())

    def test_empty_batch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            collate_direct_anchors([])


if __name__ == "__main__":
    unittest.main()
