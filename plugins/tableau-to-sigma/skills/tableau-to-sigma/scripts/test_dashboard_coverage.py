#!/usr/bin/env python3

import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import dashboard_coverage


SOURCE = """
<workbook>
  <dashboards>
    <dashboard name="Overview"><zones><zone id="1"/></zones></dashboard>
    <dashboard name="Operations"><zones><zone id="2"/></zones></dashboard>
    <dashboard name="Parameter Host"><zones><zone id="3"/></zones></dashboard>
    <dashboard name="Actually Empty"><zones/></dashboard>
  </dashboards>
  <windows>
    <window class="dashboard" name="Overview"/>
    <window class="dashboard" name="Operations"/>
    <window class="worksheet" hidden="true" name="Parameter Host"/>
  </windows>
</workbook>
"""


def spec(names):
    return {
        "name": "Fixture",
        "document": {
            "schemaVersion": 1,
            "kind": "workbook",
            "pages": [
                {"id": f"p{index}", "name": name}
                for index, name in enumerate(names)
            ],
            "elements": [],
            "layout": "",
        },
    }


class DashboardCoverageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.twb = self.root / "source.twb"
        self.workbook = self.root / "spec.json"
        self.twb.write_text(SOURCE, encoding="utf-8")

    def tearDown(self):
        self.temporary.cleanup()

    def write_spec(self, names):
        self.workbook.write_text(json.dumps(spec(names)), encoding="utf-8")

    def test_full_scope_fails_on_missing_visible_dashboard(self):
        self.write_spec(["Overview"])
        result = dashboard_coverage.evaluate(
            self.twb,
            self.workbook,
            {"mode": "full", "provenance": "full-workbook"},
        )
        self.assertEqual("fail", result["status"])
        self.assertEqual(["Operations"], result["missing_dashboards"])
        self.assertEqual(["Overview", "Operations"], result["visible_source_dashboards"])

    def test_full_scope_passes_when_complete(self):
        self.write_spec(["Overview", "Operations"])
        result = dashboard_coverage.evaluate(
            self.twb,
            self.workbook,
            {"mode": "full", "provenance": "full-workbook"},
        )
        self.assertEqual("pass", result["status"])

    def test_only_stated_selected_scope_can_exclude_dashboard(self):
        self.write_spec(["Overview"])
        result = dashboard_coverage.evaluate(
            self.twb,
            self.workbook,
            {"mode": "selected", "provenance": "stated", "dashboards": ["Overview"]},
        )
        self.assertEqual("pass", result["status"])
        self.assertEqual(["Operations"], result["scope_excluded_dashboards"])
        inferred = dashboard_coverage.evaluate(
            self.twb,
            self.workbook,
            {"mode": "selected", "provenance": "inferred", "dashboards": ["Overview"]},
        )
        self.assertEqual("fail", inferred["status"])

    def test_story_points_are_required_pages_in_full_scope(self):
        story_plan = self.root / "story-plan.json"
        story_plan.write_text(
            json.dumps(
                [
                    {
                        "story": "Executive Story",
                        "points": [
                            {
                                "id": "1",
                                "caption": "Where we landed",
                                "captured_sheet": "Overview",
                                "sheet_kind": "dashboard",
                            }
                        ],
                    }
                ]
            ),
            encoding="utf-8",
        )
        self.write_spec(["Overview", "Operations"])
        missing = dashboard_coverage.evaluate(
            self.twb,
            self.workbook,
            {"mode": "full", "provenance": "full-workbook"},
            story_plan,
        )
        self.assertEqual(["Where we landed"], missing["missing_story_points"])
        self.write_spec(["Overview", "Operations", "Where we landed"])
        complete = dashboard_coverage.evaluate(
            self.twb,
            self.workbook,
            {"mode": "full", "provenance": "full-workbook"},
            story_plan,
        )
        self.assertEqual("pass", complete["status"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
