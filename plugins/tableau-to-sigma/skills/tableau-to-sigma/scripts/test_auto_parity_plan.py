#!/usr/bin/env python3
"""Creds-free tests for the no-Ruby parity-plan builder."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "auto-parity-plan.py"
SPEC = importlib.util.spec_from_file_location("auto_parity_plan", SCRIPT)
auto_parity_plan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(auto_parity_plan)


class AutoParityPlanTest(unittest.TestCase):
    def fixture(self, csv_body="Region,Sales\nEast,100\nWest,200\n"):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "views").mkdir()
        (root / "get-workbook.json").write_text(
            json.dumps(
                {
                    "hasExtracts": "true",
                    "views": {"view": [{"id": "v1", "name": "Sales Sheet"}]},
                }
            ),
            encoding="utf-8",
        )
        (root / "views" / "v1.csv").write_text(csv_body, encoding="utf-8")
        (root / "dashboard-layout.json").write_text(
            json.dumps(
                [
                    {
                        "dashboard": "Overview",
                        "zones": [
                            {
                                "kind": "chart",
                                "caption": "Sales Sheet",
                                "display_title": "Revenue by Region",
                                "measures": ["Sales"],
                                "rows_shelf": {"dim_count": 1},
                                "cols_shelf": {"measure_count": 1},
                                "hidden_filters": [
                                    {
                                        "calc_ref": "[Calculation_1]",
                                        "caption": "Current",
                                        "filter_type": "categorical",
                                        "members": ["Yes"],
                                    }
                                ],
                            },
                            {"kind": "text", "caption": "Notes"},
                        ],
                    }
                ]
            ),
            encoding="utf-8",
        )
        (root / "chart-provenance.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "elements": {
                        "el-sales": {
                            "worksheet": "Sales Sheet",
                            "dashboard": "Overview",
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        workbook = {
            "workbookId": "wb-1",
            "latestDocumentVersion": 7,
            "document": {
                "schemaVersion": 4,
                "pages": [{"id": "p1", "name": "Overview"}],
                "elements": [
                    {
                        "id": "master",
                        "kind": "table",
                        "visibleAsSource": False,
                        "source": {"kind": "data-model"},
                    },
                    {
                        "id": "el-sales",
                        "kind": "bar-chart",
                        "name": "Revenue by Region",
                        "source": {"kind": "element", "elementId": "master"},
                        "columns": [
                            {"id": "x-region", "name": "Region"},
                            {"id": "y-sales", "name": "Sales"},
                        ],
                        "xAxis": {"columnId": "x-region"},
                        "yAxis": {"columnIds": ["y-sales"]},
                    },
                ],
                "layout": (
                    '<Page id="p1"><Element elementId="master"/>'
                    '<Element elementId="el-sales"/></Page>'
                ),
            },
        }
        spec_path = root / "wb-readback.json"
        spec_path.write_text(json.dumps(workbook), encoding="utf-8")
        return root, spec_path

    def test_builds_complete_existing_plan_contract_from_readback_and_layout(self):
        root, spec_path = self.fixture()
        plan = auto_parity_plan.build_plan(
            root,
            spec_path,
            workbook_id="wb-1",
            dashboards_scope=["overview"],
        )

        self.assertTrue(plan["extract"])
        self.assertEqual("needs_review", plan["plan_status"])
        self.assertFalse(plan["composite_stub"])
        self.assertEqual(["overview"], plan["dashboards_scope"])
        self.assertEqual(1, len(plan["charts"]))
        chart = plan["charts"][0]
        self.assertEqual("Revenue by Region", chart["chart"])
        self.assertEqual("Sales Sheet", chart["tableau_view"])
        self.assertEqual("provenance", chart["matched_via"])
        self.assertEqual(["x-region", "y-sales"], chart["sigma_columns"])
        self.assertEqual([["East", 100.0], ["West", 200.0]], chart["expected"])
        self.assertEqual("wb-1", chart["workbookId"])
        self.assertIn('"workbook"."el-sales"', chart["sql_template"])

    def test_measure_names_values_csv_is_pivoted_to_wide(self):
        root, spec_path = self.fixture(
            "Month,Measure Names,Measure Values\n"
            "Jan,Sales,10\nJan,Profit,2\nFeb,Sales,20\nFeb,Profit,4\n"
        )
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        chart = spec["document"]["elements"][1]
        chart["columns"] = [
            {"id": "x-month", "name": "Month"},
            {"id": "y-sales", "name": "Sales"},
            {"id": "y-profit", "name": "Profit"},
        ]
        spec_path.write_text(json.dumps(spec), encoding="utf-8")

        plan = auto_parity_plan.build_plan(root, spec_path)

        self.assertEqual(
            [["Jan", 10.0, 2.0], ["Feb", 20.0, 4.0]],
            plan["charts"][0]["expected"],
        )
        self.assertEqual(
            ["x-month", "y-sales", "y-profit"],
            plan["charts"][0]["sigma_columns"],
        )

    def test_hidden_filter_resolution_only_carries_when_definition_matches(self):
        root, spec_path = self.fixture()
        prior = {
            "hidden_filters": [
                {
                    "tile": "Sales Sheet",
                    "calc_ref": "[Calculation_1]",
                    "caption": "Current",
                    "filter_type": "categorical",
                    "members": ["Yes"],
                    "status": "translated",
                    "translated_to": "filter-1",
                }
            ]
        }
        plan = auto_parity_plan.build_plan(
            root, spec_path, prior_output=prior
        )
        self.assertEqual("green", plan["plan_status"])
        self.assertEqual("translated", plan["hidden_filters"][0]["status"])
        self.assertEqual("filter-1", plan["hidden_filters"][0]["translated_to"])

        layout = json.loads((root / "dashboard-layout.json").read_text())
        layout[0]["zones"][0]["hidden_filters"][0]["members"] = ["No"]
        (root / "dashboard-layout.json").write_text(json.dumps(layout))
        changed = auto_parity_plan.build_plan(
            root, spec_path, prior_output=prior
        )
        self.assertEqual("needs_review", changed["plan_status"])
        self.assertEqual("unresolved", changed["hidden_filters"][0]["status"])

    def test_missing_or_empty_displayed_tile_csv_fails_closed(self):
        for body in ("Region,Sales\n", ""):
            with self.subTest(body=body):
                root, spec_path = self.fixture(body)
                with self.assertRaisesRegex(
                    auto_parity_plan.PlanError, "empty source CSV|zero source data rows"
                ):
                    auto_parity_plan.build_plan(root, spec_path)

        root, spec_path = self.fixture()
        (root / "views" / "v1.csv").unlink()
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "missing source CSV"):
            auto_parity_plan.build_plan(root, spec_path)

    def test_unmatched_source_or_sigma_displayed_tile_fails_closed(self):
        root, spec_path = self.fixture()
        layout = json.loads((root / "dashboard-layout.json").read_text())
        layout[0]["zones"].append(
            {
                "kind": "chart",
                "caption": "Dropped Sheet",
                "measures": ["Amount"],
                "rows_shelf": {"dim_count": 1},
            }
        )
        (root / "dashboard-layout.json").write_text(json.dumps(layout))
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "no Sigma parity element"):
            auto_parity_plan.build_plan(root, spec_path)

        root, spec_path = self.fixture()
        provenance = json.loads((root / "chart-provenance.json").read_text())
        provenance["elements"]["el-sales"]["worksheet"] = "Not Displayed"
        (root / "chart-provenance.json").write_text(json.dumps(provenance))
        with self.assertRaisesRegex(auto_parity_plan.PlanError, "no Tableau view matches"):
            auto_parity_plan.build_plan(root, spec_path)

    def test_main_does_not_replace_prior_artifact_with_partial_plan(self):
        root, spec_path = self.fixture("Region,Sales\n")
        out = root / "parity-plan.json"
        out.write_text('{"sentinel":"keep"}\n', encoding="utf-8")

        code = auto_parity_plan.main(
            [
                "--tableau",
                str(root),
                "--workbook-spec",
                str(spec_path),
                "--out",
                str(out),
            ]
        )

        self.assertEqual(1, code)
        self.assertEqual({"sentinel": "keep"}, json.loads(out.read_text()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
