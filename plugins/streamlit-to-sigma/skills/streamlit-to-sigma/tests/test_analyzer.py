#!/usr/bin/env python3
import json
import sys
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL))

from converter import analyze_project  # noqa: E402
from converter.analyzer import infer_sql_columns  # noqa: E402


class AnalyzerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = SKILL / "fixtures" / "simple-retail"
        cls.ir = analyze_project(cls.fixture)

    def test_project_and_query_discovery(self):
        self.assertEqual(self.ir.project_name, "streamlit-retail-fixture")
        self.assertEqual(self.ir.main_file, "streamlit_app.py")
        self.assertEqual(len(self.ir.pages), 1)
        self.assertEqual(len(self.ir.queries), 1)
        self.assertEqual(self.ir.queries[0].function, "load_sales")
        self.assertEqual(
            self.ir.queries[0].columns,
            ["Order Date", "Region", "Category", "Order Id", "Revenue", "Profit"],
        )
        self.assertFalse(self.ir.queries[0].dynamic)

    def test_controls_and_elements(self):
        self.assertEqual(len(self.ir.controls), 1)
        control = self.ir.controls[0]
        self.assertEqual(control.label, "Region")
        self.assertEqual(control.column, "Region")
        self.assertTrue(control.sidebar)

        kinds = [item.kind for item in self.ir.elements]
        self.assertEqual(kinds.count("metric"), 3)
        self.assertEqual(kinds.count("bar-chart"), 1)
        self.assertEqual(kinds.count("table"), 1)
        self.assertIn("text", kinds)
        chart = next(item for item in self.ir.elements if item.kind == "bar-chart")
        self.assertIn({"kind": "tab", "name": "Overview"}, chart.context)
        metrics = [item for item in self.ir.elements if item.kind == "metric"]
        column_contexts = [
            next(context for context in item.context if context["kind"] == "column")
            for item in metrics
        ]
        self.assertEqual([context["index"] for context in column_contexts], [0, 1, 2])
        self.assertEqual(len({context["group"] for context in column_contexts}), 1)

    def test_ir_is_serializable_and_provenanced(self):
        body = json.dumps(self.ir.to_dict())
        self.assertIn("streamlit_app.py", body)
        self.assertTrue(all(item.provenance.line > 0 for item in self.ir.elements))

    def test_distinct_select_columns_are_inferred(self):
        self.assertEqual(
            infer_sql_columns(
                "SELECT DISTINCT REGION, CATEGORY AS product_category FROM sales"
            ),
            ["REGION", "product_category"],
        )


if __name__ == "__main__":
    unittest.main()
