#!/usr/bin/env python3
"""Tests for the deterministic verify-parity expected projection."""

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "parity-plan-to-expected.py"
SPEC = importlib.util.spec_from_file_location("parity_plan_to_expected", SCRIPT)
transformer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transformer)


class ParityPlanToExpectedTest(unittest.TestCase):
    def test_projects_name_keyed_rows_in_plan_order(self):
        result = transformer.transform(
            {
                "charts": [
                    {"chart": "KPI", "expected": [[104.0]]},
                    {
                        "chart": "Trend",
                        "expected": [["Jan", 10.0], ["Feb", 20.0]],
                    },
                ]
            }
        )
        self.assertEqual(
            {
                "KPI": [[104.0]],
                "Trend": [["Jan", 10.0], ["Feb", 20.0]],
            },
            result,
        )
        self.assertEqual(["KPI", "Trend"], list(result))

    def test_rejects_empty_duplicate_or_malformed_coverage(self):
        invalid = [
            {"charts": []},
            {"charts": [{"chart": "KPI", "expected": []}]},
            {
                "charts": [
                    {"chart": "KPI", "expected": [[1]]},
                    {"chart": "KPI", "expected": [[2]]},
                ]
            },
            {"charts": [{"chart": "KPI", "expected": [None]}]},
        ]
        for plan in invalid:
            with self.subTest(plan=plan):
                with self.assertRaises(transformer.TransformError):
                    transformer.transform(plan)


if __name__ == "__main__":
    unittest.main(verbosity=2)
