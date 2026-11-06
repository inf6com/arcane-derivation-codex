import json
import tempfile
import unittest
from pathlib import Path

from build_hinotori_subsets import build_subsets
from hinotori_weak_dataset import WeakFormulaDataset, collate_weak_formulas


class WeakFormulaDatasetTests(unittest.TestCase):
    def test_keeps_raw_strokes_and_latex_multiset_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "train").mkdir()
            (root / "train" / "formula.inkml").write_text('<ink xmlns="http://www.w3.org/2003/InkML"><trace id="9">0 0,1 0</trace><trace id="2">1 1,1 2</trace></ink>', encoding="utf-8")
            vocabulary = root / "vocabulary.json"
            vocabulary.write_text(json.dumps({"labels": ["x"] + [f"l{index}" for index in range(228)]}), encoding="utf-8")
            source_split = root / "source-split.json"
            source_split.write_text(json.dumps({"sourceSplit": {"formula": "train", "skip": "valid"}}), encoding="utf-8")
            teachers = root / "teachers.jsonl"
            teachers.write_text(json.dumps({"sourceSampleId": "formula", "visualSymbols": ["x", "x"], "unsupportedTokens": []}) + "\n" + json.dumps({"sourceSampleId": "skip", "visualSymbols": [], "unsupportedTokens": ["\\unknown"]}) + "\n", encoding="utf-8")
            dataset = WeakFormulaDataset(teachers, root, vocabulary, source_split, "train")
            batch = collate_weak_formulas([dataset[0]])
        self.assertEqual(len(dataset), 1)
        self.assertEqual(dataset.excluded_unsupported, 1)
        self.assertEqual(dataset.excluded_heldout, 1)
        self.assertEqual(len(batch["traces"][0]), 2)
        self.assertEqual(batch["targetCounts"][0, 0].item(), 2.0)

    def test_empty_batch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            collate_weak_formulas([])

    def test_balanced_indices_interleave_classes_without_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "train").mkdir()
            for source in ("a", "b", "c"):
                (root / "train" / f"{source}.inkml").write_text('<ink xmlns="http://www.w3.org/2003/InkML"><trace id="0">0 0,1 0</trace></ink>', encoding="utf-8")
            labels = ["a", "b"] + [f"l{index}" for index in range(227)]
            (root / "vocabulary.json").write_text(json.dumps({"labels": labels}), encoding="utf-8")
            (root / "source-split.json").write_text(json.dumps({"sourceSplit": {}}), encoding="utf-8")
            teachers = root / "teachers.jsonl"
            teachers.write_text("\n".join([
                json.dumps({"sourceSampleId": "a", "visualSymbols": ["a"], "unsupportedTokens": []}),
                json.dumps({"sourceSampleId": "b", "visualSymbols": ["b"], "unsupportedTokens": []}),
                json.dumps({"sourceSampleId": "c", "visualSymbols": ["a", "b"], "unsupportedTokens": []}),
            ]) + "\n", encoding="utf-8")
            dataset = WeakFormulaDataset(teachers, root, root / "vocabulary.json", root / "source-split.json", "train")
        self.assertEqual(sorted(dataset.balanced_indices()), [0, 1, 2])
        # The first round covers both observed classes; formula c covers b
        # while also carrying a, so it is selected before b's singleton row.
        self.assertEqual(dataset.balanced_indices()[:2], [0, 2])
        self.assertEqual(dataset.sampling_metadata["observedClassCount"], 2)
        self.assertEqual(dataset.class_stage_indices()[0], [0, 2])
        self.assertEqual(dataset.class_stage_indices()[1], [2, 1])

    def test_materialized_memberships_match_post_source_split_teachers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "ink" / "train").mkdir(parents=True)
            for source in ("a", "b", "heldout"):
                (root / "ink" / "train" / f"{source}.inkml").write_text('<ink xmlns="http://www.w3.org/2003/InkML"><trace id="0">0 0,1 0</trace></ink>', encoding="utf-8")
            labels = ["a", "b"] + [f"l{index:03d}" for index in range(227)]
            teachers_root = root / "teachers"
            teachers_root.mkdir()
            (teachers_root / "vocabulary.json").write_text(json.dumps({"labels": labels}), encoding="utf-8")
            rows = [
                {"sourceSampleId": "a", "visualSymbols": ["a"], "unsupportedTokens": []},
                {"sourceSampleId": "b", "visualSymbols": ["a", "b"], "unsupportedTokens": []},
                {"sourceSampleId": "heldout", "visualSymbols": ["b"], "unsupportedTokens": []},
            ]
            (teachers_root / "train-weak-symbol-teachers.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            (teachers_root / "valid-weak-symbol-teachers.jsonl").write_text("", encoding="utf-8")
            source_split = root / "source-split.json"
            source_split.write_text(json.dumps({"sourceSplit": {"heldout": "valid"}}), encoding="utf-8")
            subsets = root / "subsets"
            build_subsets(teachers_root, subsets)
            dataset = WeakFormulaDataset(teachers_root / "train-weak-symbol-teachers.jsonl", root / "ink", teachers_root / "vocabulary.json", source_split, "train")
            memberships, metadata = dataset.materialized_class_stage_indices(subsets)
            schedule, schedule_metadata = dataset.class_conditioned_schedule(subsets)
        self.assertEqual(memberships[0], [0, 1])
        self.assertEqual(memberships[1], [1])
        self.assertEqual(metadata["sourceSplitExcludedMembershipCount"], 1)
        self.assertEqual(metadata["missingClassIndices"], list(range(2, 229)))
        self.assertEqual(schedule[:4].tolist(), [[0, 0, 0], [1, 1, 0], [2, -1, 0], [3, -1, 0]])
        self.assertEqual(schedule[229].tolist(), [0, 1, 1])
        self.assertEqual(schedule_metadata["weakPairCount"], 3)
        self.assertEqual(schedule_metadata["directOnlyClassIndices"], list(range(2, 229)))


if __name__ == "__main__":
    unittest.main()
