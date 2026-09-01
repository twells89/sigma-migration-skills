import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE / "assert-phase6-ran.py"


class AssertPhase6RanTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.workdir = Path(self.temporary.name)
        self.source_png = self.workdir / "source.png"
        self.target_png = self.workdir / "target.png"
        self.blind_grade = self.workdir / "blind-grade.json"
        self.source_png.write_bytes(b"source image bytes")
        self.target_png.write_bytes(b"target image bytes")

        self.formula_audit = {
            "status": "PASS",
            "expected_formula_count": 1,
            "formulas": [
                {
                    "internal_name": "[Calculation_1]",
                    "caption": "Total Sales",
                    "calculation": "Total Sales",
                    "status": "spec",
                }
            ],
            "counts": {
                "spec": 1,
                "verify": 0,
                "chart_only": 0,
                "rls": 0,
                "not_converted": 0,
                "unmapped": 0,
            },
        }
        self.census_objects = [
            {
                "type": "formula",
                "id": "[Calculation_1]",
                "name": "Total Sales",
                "status": "migrated",
                "evidence": [{"artifact": "formula-audit.json"}],
            },
            {
                "type": "dashboard",
                "id": "overview",
                "name": "Overview",
                "status": "migrated",
                "evidence": [{"artifact": "workbook-readback.json"}],
            },
        ]
        self.write_good_fixtures()

    def tearDown(self):
        self.temporary.cleanup()

    def write_json(self, name, value):
        path = self.workdir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def load_json(self, name):
        return json.loads((self.workdir / name).read_text(encoding="utf-8"))

    def write_good_fixtures(self):
        self.write_json(
            "mission.json",
            {
                field: {"value": f"fixture-{field}", "provenance": "stated"}
                for field in (
                    "source",
                    "sigma_connection",
                    "destination",
                    "landing",
                    "scope",
                )
            },
        )
        profile = {
            "requested": "python",
            "selected": "python",
            "required_runtimes": ["python", "node", "bash"],
        }
        self.write_json(
            "doctor.json",
            {
                "pass": True,
                "runtime_profile": profile,
                "runtimes": {
                    "ruby": False,
                    "python": True,
                    "node": True,
                    "bash": True,
                },
            },
        )
        self.write_json(
            "bootstrap.json",
            {"doctor_pass": True, "runtime_profile": profile},
        )
        self.write_json("dm-ids.json", {"dataModelId": "dm-1"})
        self.write_json("datamodel-readback.json", {"pages": [{"id": "model"}]})
        self.write_json(
            "datamodel-readback-verdict.json",
            {
                "pass": True,
                "missing_elements": [],
                "dropped_columns": {},
                "error_columns": [],
            },
        )
        self.write_json("wb-ids.json", {"workbookId": "wb-1"})
        self.write_json(
            "workbook-readback.json",
            {"document": {"pages": [{"id": "overview"}], "elements": [{"id": "kpi"}]}},
        )
        self.write_json(
            "workbook-readback-verdict.json",
            {
                "pass": True,
                "missing_elements": [],
                "dropped_columns": {},
                "error_columns": [],
            },
        )
        self.write_json(
            "gaps.json",
            {"detected_features": [], "formula_audit": self.formula_audit},
        )
        self.write_json("formula-audit.json", self.formula_audit)
        self.write_json(
            "source-object-census.json",
            {
                "summary": {"complete": True, "total": len(self.census_objects)},
                "objects": self.census_objects,
            },
        )
        self.write_json(
            "parity-final.json",
            {"status": "PASS", "match": True, "differences": []},
        )
        anchors = [
            {"id": f"a{index}", "label": f"KPI {index}", "raw": str(index)}
            for index in range(1, 6)
        ]
        self.write_json(
            "source-anchors.json",
            {"anchors": anchors, "coverage_waivers": []},
        )
        self.write_json(
            "anchors-verdict.json",
            {
                "pass": True,
                "checked": 5,
                "matched": 5,
                "missing": [],
                "tiles_all_nonempty": True,
                "anchor_coverage": {
                    "covered": 1,
                    "displayed": 1,
                    "uncovered": [],
                },
            },
        )
        self.write_json(
            "visual-similarity-final.json",
            {
                "pass": True,
                "score_overall": 0.8,
                "threshold": 0.45,
                "source_health": {
                    "status": "PASS",
                    "path": str(self.source_png),
                },
                "render_health": {
                    "status": "PASS",
                    "path": str(self.target_png),
                },
            },
        )
        self.write_json(
            "blind-grade.json",
            {
                "verdict": "pass",
                "source_png": str(self.source_png),
                "target_png": str(self.target_png),
                "source_sha256": hashlib.sha256(
                    self.source_png.read_bytes()
                ).hexdigest(),
                "target_sha256": hashlib.sha256(
                    self.target_png.read_bytes()
                ).hexdigest(),
                "dimensions": {
                    "composition_match": {
                        "verdict": "pass",
                        "evidence": "blind fixture",
                    },
                    "chart_shapes_match": {
                        "verdict": "pass",
                        "evidence": "blind fixture",
                    },
                },
            },
        )
        self.write_json("conv-meta.json", {"security": []})
        self.write_json(
            "security-decision.json",
            {"decision": "not-required", "rules_detected": 0},
        )
        self.write_json(
            "semantic-edits.json",
            {"kind": "semantic-edits", "edits": [], "match": True},
        )
        self.write_json(
            "migration-result.json",
            {
                "schema_version": 1,
                "verdict": "GREEN",
                "summary": {
                    "total": len(self.census_objects),
                    "accounted": len(self.census_objects),
                    "complete": True,
                    "counts": {
                        "migrated": 2,
                        "approximated": 0,
                        "needs-review": 0,
                        "skipped": 0,
                        "not-applicable": 0,
                    },
                },
                "source_objects": self.census_objects,
                "checks": [
                    {"name": "source-accounting", "status": "PASS"},
                    {"name": "parity", "status": "PASS"},
                    {"name": "render", "status": "PASS"},
                ],
                "gates": {"numeric_parity": True, "visual_floor": True},
                "failures": [],
            },
        )
        (self.workdir / "MIGRATION_REPORT.md").write_text(
            "\n".join(
                [
                    "# Migration Report",
                    "",
                    "Verdict: **GREEN**",
                    "",
                    "Accounting: **2/2** source objects have exactly one terminal status.",
                    "",
                    "| Type | ID | Name | Terminal status |",
                    "| --- | --- | --- | --- |",
                    "| formula | [Calculation_1] | Total Sales | migrated |",
                    "| dashboard | overview | Overview | migrated |",
                    "",
                ]
            ),
            encoding="utf-8",
        )

    def run_gate(self):
        return subprocess.run(
            [
                sys.executable,
                str(GATE),
                "--workdir",
                str(self.workdir),
                "--blind-grade",
                str(self.blind_grade),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_gate_failure(self, code, gate):
        completed = self.run_gate()
        self.assertEqual(code, completed.returncode, completed.stderr)
        self.assertIn(f"gate {gate}", completed.stderr)
        self.assertIn(f"exit {code}", completed.stderr)
        self.assertFalse((self.workdir / "phase6-success-python.json").exists())

    def test_all_gates_pass_and_write_hash_bound_success_marker(self):
        completed = self.run_gate()
        self.assertEqual(0, completed.returncode, completed.stderr)
        marker = self.load_json("phase6-success-python.json")
        self.assertTrue(marker["complete"])
        self.assertEqual("python", marker["runtime_profile"])
        self.assertEqual("GREEN", marker["verdict"])
        self.assertEqual("dm-1", marker["dataModelId"])
        self.assertEqual("wb-1", marker["workbookId"])
        self.assertEqual(
            hashlib.sha256(self.blind_grade.read_bytes()).hexdigest(),
            marker["blind_grade_sha256"],
        )
        self.assertEqual(13, len(marker["gates"]))

    def test_mission_requires_stated_nonempty_fields_exit_40(self):
        mission = self.load_json("mission.json")
        mission["scope"]["provenance"] = "inferred"
        self.write_json("mission.json", mission)
        self.assert_gate_failure(40, "mission")

    def test_doctor_and_bootstrap_must_select_same_healthy_python_profile_exit_41(self):
        bootstrap = self.load_json("bootstrap.json")
        bootstrap["runtime_profile"]["selected"] = "ruby"
        self.write_json("bootstrap.json", bootstrap)
        self.assert_gate_failure(41, "environment")

    def test_missing_selected_runtime_fails_environment_exit_41(self):
        doctor = self.load_json("doctor.json")
        doctor["runtimes"]["node"] = False
        self.write_json("doctor.json", doctor)
        self.assert_gate_failure(41, "environment")

    def test_data_model_readback_errors_exit_42(self):
        verdict = self.load_json("datamodel-readback-verdict.json")
        verdict["error_columns"] = [{"column": "Broken"}]
        self.write_json("datamodel-readback-verdict.json", verdict)
        self.assert_gate_failure(42, "data-model-readback")

    def test_workbook_readback_drop_exit_43(self):
        verdict = self.load_json("workbook-readback-verdict.json")
        verdict["dropped_columns"] = {"KPI": ["Revenue"]}
        self.write_json("workbook-readback-verdict.json", verdict)
        self.assert_gate_failure(43, "workbook-readback")

    def test_unvalidated_gap_exit_44(self):
        self.write_json(
            "gaps.json",
            {
                "detected_features": [
                    {"name": "Unsupported table calc", "status": "unhandled"}
                ],
                "formula_audit": self.formula_audit,
            },
        )
        self.assert_gate_failure(44, "gaps")

    def test_gap_resolution_requires_validation_evidence(self):
        self.write_json(
            "gaps.json",
            {
                "detected_features": [
                    {"name": "Unsupported table calc", "status": "unhandled"}
                ],
                "formula_audit": self.formula_audit,
            },
        )
        self.write_json(
            "gap-resolutions.json",
            {
                "resolutions": {
                    "Unsupported table calc": {"status": "validated"}
                }
            },
        )
        self.assert_gate_failure(44, "gaps")

    def test_formula_without_terminal_census_disposition_exit_45(self):
        census = self.load_json("source-object-census.json")
        census["objects"][0]["id"] = "different"
        census["objects"][0]["name"] = "Different"
        self.write_json("source-object-census.json", census)
        self.assert_gate_failure(45, "formula-accounting")

    def test_numeric_parity_failure_exit_46(self):
        self.write_json(
            "parity-final.json",
            {
                "status": "FAIL",
                "match": False,
                "differences": [{"path": "$.revenue"}],
            },
        )
        self.assert_gate_failure(46, "parity")

    def test_anchor_staleness_or_empty_tiles_exit_47(self):
        verdict = self.load_json("anchors-verdict.json")
        verdict["checked"] = 4
        verdict["tiles_all_nonempty"] = False
        self.write_json("anchors-verdict.json", verdict)
        self.assert_gate_failure(47, "anchors")

    def test_uncovered_anchor_tile_requires_named_waiver_exit_47(self):
        verdict = self.load_json("anchors-verdict.json")
        verdict["anchor_coverage"] = {
            "covered": 1,
            "displayed": 2,
            "uncovered": [{"tile": "Map"}],
        }
        self.write_json("anchors-verdict.json", verdict)
        self.assert_gate_failure(47, "anchors")

    def test_uncovered_anchor_tile_with_named_waiver_is_accepted(self):
        verdict = self.load_json("anchors-verdict.json")
        verdict["anchor_coverage"] = {
            "covered": 1,
            "displayed": 2,
            "uncovered": [{"tile": "Map"}],
        }
        self.write_json("anchors-verdict.json", verdict)
        source = self.load_json("source-anchors.json")
        source["coverage_waivers"] = [
            {"tile": "Map", "reason": "source tile has no anchorable value"}
        ]
        self.write_json("source-anchors.json", source)
        completed = self.run_gate()
        self.assertEqual(0, completed.returncode, completed.stderr)

    def test_machine_visual_floor_failure_exit_48(self):
        visual = self.load_json("visual-similarity-final.json")
        visual["pass"] = False
        visual["score_overall"] = 0.2
        self.write_json("visual-similarity-final.json", visual)
        self.assert_gate_failure(48, "visual-similarity")

    def test_blind_grade_is_bound_to_current_visual_inputs_exit_49(self):
        self.target_png.write_bytes(b"changed after grading")
        self.assert_gate_failure(49, "blind-grade")

    def test_nonpassing_blind_dimension_exit_49(self):
        grade = self.load_json("blind-grade.json")
        grade["dimensions"]["chart_shapes_match"]["verdict"] = "fail"
        self.write_json("blind-grade.json", grade)
        self.assert_gate_failure(49, "blind-grade")

    def test_detected_security_requires_explicit_safe_decision_exit_50(self):
        self.write_json(
            "conv-meta.json",
            {
                "security": [
                    {"kind": "rls", "source": "USERNAME()", "elementName": "Orders"}
                ]
            },
        )
        self.assert_gate_failure(50, "security")

    def test_loud_security_skip_is_accepted(self):
        reason = "user explicitly accepted unrestricted rows"
        self.write_json(
            "conv-meta.json",
            {"security": [{"kind": "rls", "source": "USERNAME()"}]},
        )
        self.write_json(
            "security-decision.json",
            {
                "decision": "skip",
                "rules_detected": 1,
                "reason": reason,
                "acknowledges_all_rows_visible": True,
            },
        )
        result = self.load_json("migration-result.json")
        result["verdict"] = "YELLOW"
        self.write_json("migration-result.json", result)
        report_path = self.workdir / "MIGRATION_REPORT.md"
        report = report_path.read_text(encoding="utf-8")
        report_path.write_text(
            report.replace("Verdict: **GREEN**", "Verdict: **YELLOW**")
            + f"\n## Security\n\n- Skip: {reason}\n",
            encoding="utf-8",
        )
        completed = self.run_gate()
        self.assertEqual(0, completed.returncode, completed.stderr)

    def test_security_skip_cannot_be_reported_green_exit_52(self):
        self.write_json(
            "conv-meta.json",
            {"security": [{"kind": "rls", "source": "USERNAME()"}]},
        )
        self.write_json(
            "security-decision.json",
            {
                "decision": "skip",
                "rules_detected": 1,
                "reason": "explicit fixture skip",
                "acknowledges_all_rows_visible": True,
            },
        )
        self.assert_gate_failure(52, "report")

    def test_unproven_semantic_edit_exit_51(self):
        self.write_json(
            "semantic-edits.json",
            {
                "match": True,
                "edits": [
                    {
                        "edit_description": "drop LEFT JOIN",
                        "claim": "no-op",
                    }
                ],
            },
        )
        self.assert_gate_failure(51, "semantic-edits")

    def test_incomplete_or_drifting_report_exit_52(self):
        result = self.load_json("migration-result.json")
        result["summary"]["accounted"] = 1
        self.write_json("migration-result.json", result)
        self.assert_gate_failure(52, "report")

    def test_report_markdown_must_name_every_source_object_exit_52(self):
        report = (self.workdir / "MIGRATION_REPORT.md").read_text(encoding="utf-8")
        (self.workdir / "MIGRATION_REPORT.md").write_text(
            report.replace("Total Sales", "(omitted)"),
            encoding="utf-8",
        )
        self.assert_gate_failure(52, "report")

    def test_unreadable_report_returns_report_exit_not_traceback(self):
        (self.workdir / "MIGRATION_REPORT.md").write_bytes(b"\xff\xfe\xff")
        self.assert_gate_failure(52, "report")

    def test_failure_removes_stale_success_marker(self):
        self.assertEqual(0, self.run_gate().returncode)
        mission = self.load_json("mission.json")
        mission["source"]["value"] = ""
        self.write_json("mission.json", mission)
        self.assert_gate_failure(40, "mission")


if __name__ == "__main__":
    unittest.main()
