import unittest

from build_hinotori_anchor_split import build_split


class AnchorSplitTests(unittest.TestCase):
    def test_keeps_every_class_in_train_without_source_leakage(self):
        rows = [{"sourceSampleId": f"source-{index}", "classIndex": index} for index in range(229)]
        rows += [{"sourceSampleId": "shared", "classIndex": 0}, {"sourceSampleId": "shared", "classIndex": 1}]
        split = build_split(rows, valid_fraction=0.2)
        train_classes = {row["classIndex"] for row in rows if split[row["sourceSampleId"]] == "train"}
        self.assertEqual(train_classes, set(range(229)))
        self.assertIn(split["shared"], {"train", "valid"})

    def test_missing_class_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "cover"):
            build_split([{"sourceSampleId": "one", "classIndex": 0}])


if __name__ == "__main__":
    unittest.main()
