#!/usr/bin/env python3
"""Contract tests for FormulaRasterV1 instance-slot target ordering."""
import unittest

from formula_instance_slots import _slot_key


class FormulaInstanceSlotOrderTests(unittest.TestCase):
    def test_slot_order_uses_visual_geometry_not_stroke_suffix(self):
        left = {"instanceId": "formula:9-10", "bbox512": [10, 80, 25, 100]}
        right = {"instanceId": "formula:0", "bbox512": [90, 80, 105, 100]}
        self.assertEqual([row["instanceId"] for row in sorted([right, left], key=_slot_key)], ["formula:9-10", "formula:0"])

    def test_instance_identity_breaks_only_coincident_geometry_ties(self):
        first = {"instanceId": "formula:1", "bbox512": [10, 20, 30, 40]}
        second = {"instanceId": "formula:0", "bbox512": [10, 20, 30, 40]}
        self.assertEqual([row["instanceId"] for row in sorted([first, second], key=_slot_key)], ["formula:0", "formula:1"])


if __name__ == "__main__":
    unittest.main()
