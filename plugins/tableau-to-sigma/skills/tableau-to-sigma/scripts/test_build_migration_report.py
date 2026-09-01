import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "build-migration-report.py"
spec = importlib.util.spec_from_file_location("build_migration_report", SCRIPT)
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class BuildMigrationReportTest(unittest.TestCase):
    def test_report_surfaces_blocking_gate_without_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            fixtures = {
                "mission.json": {
                    "source": {"value": "Fixture", "provenance": "stated"},
                    "sigma_connection": {"value": "Connection", "provenance": "stated"},
                    "destination": {"value": "Folder", "provenance": "stated"},
                    "landing": {"value": "n/a", "provenance": "stated"},
                    "scope": {"value": ["Overview"], "provenance": "stated"},
                },
                "migration-result.json": {
                    "status": "BLOCKED",
                    "dataModelId": "dm-1",
                    "workbookId": "wb-1",
                    "gates": {"numeric_parity": True, "blind_visual_grade": False},
                    "failures": ["blind visual mismatch"],
                },
                "parity-final.json": {"status": "PASS", "differences": []},
                "visual-similarity-final.json": {"pass": True, "score_overall": 0.9},
                "semantic-edits.json": {"match": True},
                "source-object-census.json": {
                    "summary": {"complete": True, "total": 1},
                    "objects": [
                        {
                            "type": "formula",
                            "id": "calc-1",
                            "name": "Metric",
                            "status": "migrated",
                        }
                    ],
                },
                "conv-meta.json": {"warnings": [], "workbookPatterns": [], "security": []},
            }
            for name, value in fixtures.items():
                (workdir / name).write_text(json.dumps(value), encoding="utf-8")
            report = reporter.report(workdir)
            self.assertIn("**Verdict:** BLOCKED", report)
            self.assertIn("PASS — numeric parity", report)
            self.assertIn("FAIL — blind visual grade", report)
            self.assertIn("blind visual mismatch", report)
            self.assertIn("| formula | calc-1 | Metric | migrated |", report)


if __name__ == "__main__":
    unittest.main()
