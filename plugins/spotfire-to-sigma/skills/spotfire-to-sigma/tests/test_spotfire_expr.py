#!/usr/bin/env python3
"""Stdlib-only tests for the fail-closed Spotfire expression translator."""
import os
import sys
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import spotfire_expr as expression  # noqa: E402


class SpotfireExpressionTests(unittest.TestCase):
    def assert_formula(self, source, expected, kind=None):
        result = expression.translate(source)
        self.assertTrue(result.supported, result.as_dict())
        self.assertEqual(expected, result.formula)
        if kind:
            self.assertEqual(kind, result.kind)
        return result

    def assert_unsupported(self, source, warning_id):
        result = expression.translate(source)
        self.assertFalse(result.supported, result.as_dict())
        self.assertEqual(warning_id, result.warning_id)
        self.assertTrue(result.reason)

    def test_arithmetic_comparison_and_boolean(self):
        self.assert_formula(
            "([Revenue] - [Cost]) / [Revenue]",
            "((([Revenue] - [Cost])) / [Revenue])",
            "dimension",
        )
        self.assert_formula(
            "[Revenue] > 100 And [Region] <> \"West\"",
            "(([Revenue] > 100) And ([Region] != \"West\"))",
        )

    def test_if_case_and_null_handling(self):
        self.assert_formula(
            "If(IsNull([Revenue]), 0, [Revenue])",
            "If(IsNull([Revenue]), 0, [Revenue])",
        )
        self.assert_formula(
            "Case When [Revenue] > 100 Then \"High\" Else \"Low\" End",
            "If(([Revenue] > 100), \"High\", \"Low\")",
        )
        self.assert_formula(
            "Case [Region] When \"East\" Then 1 Else 0 End",
            "If(([Region] = \"East\"), 1, 0)",
        )
        self.assert_formula(
            "SN([Region], \"Unknown\")",
            "Coalesce([Region], \"Unknown\")",
        )
        self.assert_formula(
            "[Region] Is Not Null",
            "IsNotNull([Region])",
        )

    def test_aggregates_dates_and_strings(self):
        self.assert_formula(
            "UniqueCount([Customer ID])",
            "CountDistinct([Customer ID])",
            "measure",
        )
        self.assert_formula(
            "DateAdd(\"month\", 1, [Order Date])",
            "DateAdd(\"month\", 1, [Order Date])",
        )
        self.assert_formula(
            "Concatenate(Upper([Region]), \" / \", Trim([Product]))",
            "Concat(Upper([Region]), \" / \", Trim([Product]))",
        )

    def test_qualified_columns_are_normalized_and_retained_as_provenance(self):
        result = self.assert_formula(
            "Sum([Sales].[Revenue])",
            "Sum([Revenue])",
            "measure",
        )
        self.assertEqual(("Sales.Revenue",), result.references)

    def test_only_plain_partition_over_forms_are_accepted(self):
        self.assert_formula(
            "Sum([Revenue]) OVER ([Region])",
            "Sum([Revenue]) Over ([Region])",
            "measure",
        )
        self.assert_formula(
            "Sum([Revenue]) OVER (Intersect([Region], [Product]))",
            "Sum([Revenue]) Over ([Region], [Product])",
            "measure",
        )
        self.assert_unsupported(
            "Sum([Revenue]) OVER (Previous([Region]))",
            "SPOTFIRE-EXPR-OVER-NAVIGATOR-UNSUPPORTED",
        )
        self.assert_unsupported(
            "[Revenue] OVER ([Region])",
            "SPOTFIRE-EXPR-OVER-NONAGGREGATE",
        )

    def test_unknowns_are_loud(self):
        self.assert_unsupported(
            "Rank([Revenue])",
            "SPOTFIRE-EXPR-FUNCTION-UNSUPPORTED",
        )
        self.assert_unsupported(
            "If([Revenue], 1)",
            "SPOTFIRE-EXPR-ARITY",
        )
        self.assert_unsupported("", "SPOTFIRE-EXPR-EMPTY")


if __name__ == "__main__":
    unittest.main()
