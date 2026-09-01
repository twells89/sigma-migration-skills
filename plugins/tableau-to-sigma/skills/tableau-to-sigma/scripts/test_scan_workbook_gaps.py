import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCANNER = HERE / "scan-workbook-gaps.py"

UNSAFE_WORKBOOK = """\
<?xml version='1.0' encoding='utf-8'?>
<workbook>
  <datasources>
    <datasource name='orders' caption='Orders'>
      <connection class='snowflake' server='warehouse-a' dbname='ANALYTICS'>
        <relation name='Union' type='union'>
          <relation name='orders_2025' type='table' table='[ORDERS_2025]' />
          <relation name='unsafe_sql' type='text'>select * from legacy</relation>
        </relation>
      </connection>
      <metadata-records>
        <metadata-record class='column'><remote-name>SALES</remote-name></metadata-record>
      </metadata-records>
      <column name='[Sales]' caption='Sales' />
      <column name='[Calculation_Script]' caption='Scripted Risk'>
        <calculation class='tableau' formula='SCRIPT_REAL([Sales])' />
      </column>
      <column name='[Calculation_Security]' caption='User Entitlement'>
        <calculation class='tableau' formula='USERNAME() = &quot;allowed@example.com&quot;' />
      </column>
      <column name='[Calculation_CycleA]' caption='Cycle A'>
        <calculation class='tableau' formula='[Calculation_CycleB] + 1' />
      </column>
      <column name='[Calculation_CycleB]' caption='Cycle B'>
        <calculation class='tableau' formula='[Calculation_CycleA] + 1' />
      </column>
      <column name='[Calculation_Missing]' caption='Missing Dependency'>
        <calculation class='tableau' formula='[Calculation_Gone] + [Sales]' />
      </column>
    </datasource>
    <datasource name='targets' caption='Targets'>
      <connection class='postgres' server='warehouse-b' dbname='PLAN'>
        <relation name='targets' type='table' table='[TARGETS]' />
      </connection>
      <column name='[Region]' caption='Region' />
      <column name='[Target]' caption='Target' />
    </datasource>
  </datasources>
  <worksheets>
    <worksheet name='Unsafe Sheet'>
      <table><view>
        <datasources>
          <datasource name='orders' />
          <datasource name='targets' />
        </datasources>
        <datasource-dependencies datasource='orders'>
          <column name='[Region]' caption='Region' />
          <column name='[Calculation_Script]' />
          <column name='[Calculation_Security]' />
          <column name='[Calculation_CycleA]' />
          <column name='[Calculation_Missing]' />
        </datasource-dependencies>
        <datasource-dependencies datasource='targets'>
          <column name='[Region]' caption='Region' />
          <column name='[Target]' caption='Target' />
        </datasource-dependencies>
      </view></table>
      <mark class='Bar' />
    </worksheet>
  </worksheets>
  <dashboards>
    <dashboard name='Overview'><zones><zone name='Unsafe Sheet' /></zones></dashboard>
  </dashboards>
</workbook>
"""

SAFE_UNION_WORKBOOK = """\
<?xml version='1.0' encoding='utf-8'?>
<workbook>
  <datasources>
    <datasource name='orders' caption='Orders'>
      <connection class='snowflake' server='warehouse-a' dbname='ANALYTICS'>
        <relation name='Union' type='union'>
          <relation name='orders_2025' type='table' table='[ORDERS_2025]' />
          <relation name='orders_2026' type='table' table='[ORDERS_2026]' />
        </relation>
      </connection>
      <metadata-records>
        <metadata-record class='column'><remote-name>SALES</remote-name></metadata-record>
        <metadata-record class='column'><remote-name>Table Name</remote-name></metadata-record>
      </metadata-records>
      <column name='[Sales]' caption='Sales' />
    </datasource>
  </datasources>
  <worksheets>
    <worksheet name='Union Sheet'>
      <table><view><datasources><datasource name='orders' /></datasources></view></table>
      <mark class='Bar' />
    </worksheet>
  </worksheets>
  <dashboards>
    <dashboard name='Overview'><zones><zone name='Union Sheet' /></zones></dashboard>
  </dashboards>
</workbook>
"""


def run_scanner(
    workbook: str,
    *,
    report_name: str | None = "gaps.md",
    env: dict[str, str] | None = None,
):
    temporary = tempfile.TemporaryDirectory()
    directory = Path(temporary.name)
    twb = directory / "workbook-content.twb"
    twb.write_text(workbook, encoding="utf-8")
    command = [sys.executable, str(SCANNER), str(twb)]
    report = directory / (
        report_name if report_name is not None else "workbook-content-gaps-report.md"
    )
    if report_name is not None:
        command.append(str(report))
    completed = subprocess.run(
        command,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    return temporary, directory, report, completed


class ScanWorkbookGapsTest(unittest.TestCase):
    def test_cli_emits_fail_closed_gaps_formula_audit_and_census_inputs(self):
        temporary, directory, report, completed = run_scanner(UNSAFE_WORKBOOK)
        self.addCleanup(temporary.cleanup)
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertTrue(report.is_file())
        gaps_path = directory / "gaps.json"
        audit_path = directory / "formula-audit.json"
        blend_path = directory / "blend-plan.json"
        self.assertTrue(gaps_path.is_file())
        self.assertTrue(audit_path.is_file())
        self.assertTrue(blend_path.is_file())

        gaps = json.loads(gaps_path.read_text(encoding="utf-8"))
        audit = json.loads(audit_path.read_text(encoding="utf-8"))
        self.assertEqual(audit, gaps["formula_audit"])
        self.assertEqual(
            {
                "Workbook",
                "Worksheets",
                "Dashboards",
                "Datasources",
                ".twb size",
            },
            set(gaps["workbook"]),
        )
        self.assertIsInstance(gaps["detected_features"], list)
        by_name = {row["name"]: row for row in gaps["detected_features"]}

        refused_union = by_name[
            "Union datasource (underivable / nested — NOT converted)"
        ]
        self.assertEqual("unhandled", refused_union["status"])
        self.assertEqual(["Unsafe Sheet"], refused_union["worksheets"])
        unsupported_blend = by_name["Data blending (flag-unreachable)"]
        self.assertEqual("unhandled", unsupported_blend["status"])
        self.assertEqual(["Unsafe Sheet"], unsupported_blend["worksheets"])
        self.assertEqual(
            "unhandled",
            by_name["Converter-refused or unmapped calculated fields"]["status"],
        )
        self.assertEqual(
            "unhandled",
            by_name["Tableau row-level security / user calculations"]["status"],
        )
        self.assertTrue(
            any(name.startswith("Circular calculated-field dependency") for name in by_name)
        )
        self.assertEqual(
            "unhandled",
            by_name["Missing internal calculated-field dependencies"]["status"],
        )

        # Existing source-object-census matching needs a formula collection plus
        # stable calculation/internal identifiers and datasource identity.
        self.assertEqual(5, len(audit["formulas"]))
        for row in audit["formulas"]:
            self.assertIsInstance(row["formula"], str)
            self.assertTrue(row["internal_name"])
            self.assertTrue(row["calculation"])
            self.assertTrue(row["datasource"])
            self.assertIn(row["status"], audit["counts"])
        security = next(
            row for row in audit["formulas"] if row["calculation"] == "User Entitlement"
        )
        self.assertEqual("rls", security["status"])
        self.assertEqual("needs-review", security["terminal_status"])
        blend = json.loads(blend_path.read_text(encoding="utf-8"))["blends"][0]
        self.assertEqual("flag-unreachable", blend["route"])
        self.assertEqual(["Region"], blend["linking_fields"])

    def test_derivable_root_union_remains_a_hint_not_a_false_blocker(self):
        temporary, directory, _report, completed = run_scanner(SAFE_UNION_WORKBOOK)
        self.addCleanup(temporary.cleanup)
        self.assertEqual(0, completed.returncode, completed.stderr)
        gaps = json.loads((directory / "gaps.json").read_text(encoding="utf-8"))
        unions = [
            row
            for row in gaps["detected_features"]
            if row["name"].startswith("Union datasource")
        ]
        self.assertEqual(
            [
                {
                    "name": "Union datasource (wildcard, converter-emitted)",
                    "status": "hint",
                    "count": 1,
                    "blurb": (
                        "Root wildcard union is emitted; verify member column matching."
                    ),
                    "worksheets": ["Union Sheet"],
                }
            ],
            unions,
        )
        self.assertEqual([], gaps["formula_audit"]["formulas"])
        self.assertEqual(100.0, gaps["formula_audit"]["coverage_pct"])

    def test_missing_formula_runtime_writes_error_audit_and_unhandled_gap(self):
        env = os.environ.copy()
        env["NODE_BIN"] = "/definitely/missing/tableau-node"
        temporary, directory, _report, completed = run_scanner(
            SAFE_UNION_WORKBOOK.replace(
                "<column name='[Sales]' caption='Sales' />",
                """<column name='[Sales]' caption='Sales' />
      <column name='[Calculation_Total]' caption='Total Sales'>
        <calculation class='tableau' formula='SUM([Sales])' />
      </column>""",
            ),
            env=env,
        )
        self.addCleanup(temporary.cleanup)
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("formula audit FAILED CLOSED", completed.stderr)
        gaps = json.loads((directory / "gaps.json").read_text(encoding="utf-8"))
        audit = json.loads(
            (directory / "formula-audit.json").read_text(encoding="utf-8")
        )
        self.assertEqual("ERROR", audit["status"])
        self.assertEqual(1, audit["expected_formula_count"])
        blocker = next(
            row
            for row in gaps["detected_features"]
            if row["name"] == "Converter-backed formula audit unavailable"
        )
        self.assertEqual("unhandled", blocker["status"])
        self.assertEqual(1, blocker["count"])

    def test_malformed_xml_still_emits_gate_consumable_fail_closed_artifacts(self):
        temporary, directory, _report, completed = run_scanner(
            "<workbook><datasources><datasource name='broken'></workbook>"
        )
        self.addCleanup(temporary.cleanup)
        self.assertEqual(0, completed.returncode, completed.stderr)
        gaps = json.loads((directory / "gaps.json").read_text(encoding="utf-8"))
        blocker = next(
            row
            for row in gaps["detected_features"]
            if row["name"] == "Workbook XML could not be parsed"
        )
        self.assertEqual("unhandled", blocker["status"])
        self.assertEqual("ERROR", gaps["formula_audit"]["status"])
        self.assertEqual(
            gaps["formula_audit"],
            json.loads(
                (directory / "formula-audit.json").read_text(encoding="utf-8")
            ),
        )

    def test_default_output_names_match_positional_ruby_cli_contract(self):
        temporary, directory, report, completed = run_scanner(
            SAFE_UNION_WORKBOOK, report_name=None
        )
        self.addCleanup(temporary.cleanup)
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual("workbook-content-gaps-report.md", report.name)
        self.assertTrue(report.is_file())
        self.assertTrue((directory / "workbook-content-gaps-report.json").is_file())


if __name__ == "__main__":
    unittest.main()
