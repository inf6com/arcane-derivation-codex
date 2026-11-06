import unittest

from ModelConversion.formula_whole_input import (
    FormulaBounds,
    FormulaCoordinateSpec,
    FormulaInput,
    FormulaInputError,
    FormulaPoint,
    _trace_values,
    model_features,
    trace_geometry_features,
)


class TraceGrammarTests(unittest.TestCase):
    def test_model_features_are_ragged_float32_compatible_xy_only(self):
        formula = FormulaInput(
            traces=((FormulaPoint(0.123456789, 0.5, 7.0), FormulaPoint(1.0, 0.25, 8.0)),),
            traceOrder=(0,),
            sourceBounds=FormulaBounds(0.0, 0.25, 1.0, 0.5),
            coordinateSpec=FormulaCoordinateSpec("source-bounds-min", "x-right,y-down", "test", "unit", "seconds", "TEST"),
        )
        features = model_features(formula)
        self.assertEqual(len(features), 1)
        self.assertEqual(len(features[0]), 2)
        self.assertEqual(len(features[0][0]), 2)
        self.assertEqual(features[0][0][0], 0.12345679104328156)
        self.assertEqual(features[0][0][1], 0.5)

    def test_trace_geometry_uses_normalized_bounds_centroid_extent_and_write_progress(self):
        formula = FormulaInput(
            traces=(
                (FormulaPoint(0.0, 0.7), FormulaPoint(0.2, 0.9), FormulaPoint(0.4, 0.5)),
                (FormulaPoint(0.8, 0.3), FormulaPoint(1.0, 0.3), FormulaPoint(1.0, 0.1)),
            ),
            traceOrder=(0, 1),
            sourceBounds=FormulaBounds(0.0, 0.1, 1.0, 0.9),
            coordinateSpec=FormulaCoordinateSpec("source-bounds-min", "x-right,y-down", "test", "unit", None, "TEST"),
        )
        self.assertEqual(
            trace_geometry_features(formula),
            (
                (0.0, 0.5, 0.4000000059604645, 0.8999999761581421, 0.20000000298023224, 0.699999988079071, 0.4000000059604645, 0.4000000059604645, 0.0),
                (0.800000011920929, 0.10000000149011612, 1.0, 0.30000001192092896, 0.9333333373069763, 0.23333333432674408, 0.20000000298023224, 0.20000000298023224, 1.0),
            ),
        )

    def test_single_trace_geometry_has_zero_write_progress(self):
        formula = FormulaInput(
            traces=((FormulaPoint(0.0, 0.5), FormulaPoint(1.0, 0.5)),),
            traceOrder=(0,),
            sourceBounds=FormulaBounds(0.0, 0.5, 1.0, 0.5),
            coordinateSpec=FormulaCoordinateSpec("source-bounds-min", "x-right,y-down", "test", "unit", None, "TEST"),
        )
        self.assertEqual(trace_geometry_features(formula)[0][-1], 0.0)

    def test_absolute_coordinates_are_parsed_without_token_loss(self):
        self.assertEqual(list(_trace_values("0 1 2, 3 4 5", 3)), [[0.0, 1.0, 2.0], [3.0, 4.0, 5.0]])

    def test_unknown_token_is_rejected_instead_of_discarded(self):
        with self.assertRaisesRegex(FormulaInputError, "unsupported non-absolute coordinate token"):
            list(_trace_values("0 junk 1", 2))

    def test_empty_point_is_rejected(self):
        with self.assertRaisesRegex(FormulaInputError, "empty coordinate point"):
            list(_trace_values("0 1,,2 3", 2))

    def test_quote_delta_notation_is_rejected(self):
        with self.assertRaisesRegex(FormulaInputError, "unsupported non-absolute coordinate token"):
            list(_trace_values("0 1,\" 2", 2))


if __name__ == "__main__":
    unittest.main()
