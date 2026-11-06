import json
import tempfile
import unittest
from pathlib import Path

from build_hinotori_subsets import build_subsets


class HinotoriSubsetTests(unittest.TestCase):
    def test_a_formula_is_member_of_each_distinct_latex_symbol_subset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            teachers = root / "teachers"
            teachers.mkdir()
            labels = ["a", "b"] + [f"z{index:03d}" for index in range(227)]
            labels.sort()
            (teachers / "vocabulary.json").write_text(json.dumps({"labels": labels}), encoding="utf-8")
            (teachers / "train-weak-symbol-teachers.jsonl").write_text("\n".join([
                json.dumps({"sourceSampleId": "ab", "visualSymbols": ["a", "b", "a"], "unsupportedTokens": []}),
                json.dumps({"sourceSampleId": "a", "visualSymbols": ["a"], "unsupportedTokens": []}),
                json.dumps({"sourceSampleId": "bad", "visualSymbols": ["a"], "unsupportedTokens": ["\\unknown"]}),
            ]) + "\n", encoding="utf-8")
            (teachers / "valid-weak-symbol-teachers.jsonl").write_text(json.dumps({"sourceSampleId": "b", "visualSymbols": ["b"], "unsupportedTokens": []}) + "\n", encoding="utf-8")
            manifest = build_subsets(teachers, root / "subsets")
            a_index, b_index = labels.index("a"), labels.index("b")
            a_members = json.loads((root / "subsets" / f"class-{a_index:03d}.json").read_text())["members"]
            b_members = json.loads((root / "subsets" / f"class-{b_index:03d}.json").read_text())["members"]
        self.assertEqual(manifest["formulaUniverse"]["usableFormulaCount"], 3)
        self.assertEqual(manifest["formulaUniverse"]["excludedUnsupportedFormulaCount"], 1)
        self.assertEqual(a_members, [{"split": "train", "sourceSampleId": "a"}, {"split": "train", "sourceSampleId": "ab"}])
        self.assertEqual(b_members, [{"split": "train", "sourceSampleId": "ab"}, {"split": "valid", "sourceSampleId": "b"}])


if __name__ == "__main__":
    unittest.main()
