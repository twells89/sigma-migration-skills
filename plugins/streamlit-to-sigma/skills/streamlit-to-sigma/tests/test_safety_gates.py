#!/usr/bin/env python3
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

SKILL = Path(__file__).resolve().parents[1]
MIGRATE = SKILL / "scripts" / "migrate-streamlit.py"

spec = importlib.util.spec_from_file_location("migrate_streamlit", MIGRATE)
migrate = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(migrate)


class FakeResponse:
    def __init__(self, payload: bytes):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self.payload


class SafetyGateTest(unittest.TestCase):
    def test_yaml_spec_response_fallback_preserves_ids(self):
        api = object.__new__(migrate.SigmaAPI)
        api.base_url = "https://aws-api." + "sigma" + "computing.com"
        api.token = "test"
        with patch.object(
            migrate.urllib.request,
            "urlopen",
            return_value=FakeResponse(b"success: true\nworkbookId: wb-123\n"),
        ):
            result = api.request("POST", "/v2/workbooks/spec", {"x": 1})
        self.assertEqual(result["workbookId"], "wb-123")

    def test_insecure_base_url_is_rejected_before_token_request(self):
        env = {
            "SIGMA_BASE_URL": "http://attacker.example",
            "SIGMA_CLIENT_ID": "id",
            "SIGMA_CLIENT_SECRET": "secret",
        }
        with patch.dict(os.environ, env, clear=True):
            with patch.object(migrate.urllib.request, "urlopen") as urlopen:
                with self.assertRaisesRegex(RuntimeError, "Refusing to transmit"):
                    migrate.SigmaAPI()
                urlopen.assert_not_called()

    def test_assessment_blocks_warehouse_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    def write_data():
                        return conn.query("UPDATE db.s.t SET value = 1")
                    st.title("Unsafe")
                    """
                ),
                encoding="utf-8",
            )
            output = root / "assessment.json"
            subprocess.run(
                [
                    "python3",
                    str(
                        SKILL.parent
                        / "streamlit-assessment"
                        / "scripts"
                        / "assess-streamlit.py"
                    ),
                    str(root),
                    "--out",
                    str(output),
                ],
                check=True,
            )
            report = json.loads(output.read_text())
            project = report["projects"][0]
            self.assertEqual(project["readiness"], "blocked")
            self.assertEqual(project["complexity"]["class"], "complex")
            self.assertIsNone(project["complexity"]["calendarEstimate"])
            self.assertIn("warehouse-backed", project["migrationDispositions"])
            self.assertIn("blocked", project["migrationDispositions"])
            self.assertEqual(
                project["recommendation"]["decision"],
                "defer-until-unblocked",
            )
            self.assertFalse(project["recommendation"]["recommended"])
            self.assertIn(
                "warehouse-write",
                project["recommendation"]["blockers"],
            )

    def test_assessment_emits_ease_chart_and_sigma_benefits(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                "import streamlit as st\nst.title('Simple app')\nst.metric('Orders', 1)\n",
                encoding="utf-8",
            )
            output = root / "assessment.json"
            markdown = root / "assessment.md"
            html = root / "assessment.html"
            subprocess.run(
                [
                    "python3",
                    str(
                        SKILL.parent
                        / "streamlit-assessment"
                        / "scripts"
                        / "assess-streamlit.py"
                    ),
                    str(root),
                    "--out",
                    str(output),
                    "--markdown-out",
                    str(markdown),
                    "--html-out",
                    str(html),
                ],
                check=True,
            )
            report = json.loads(output.read_text())
            project = report["projects"][0]
            self.assertEqual(project["complexity"]["class"], "lite")
            self.assertEqual(project["migrationDisposition"], "spec-native")
            self.assertEqual(
                project["recommendation"]["decision"],
                "migrate-now",
            )
            self.assertTrue(project["recommendation"]["recommended"])
            self.assertEqual(project["priorityRank"], 1)
            self.assertEqual(report["recommendationSummary"]["migrateNow"], 1)
            self.assertEqual(
                [row["class"] for row in report["migrationGuide"]["classes"]],
                ["lite", "medium", "complex"],
            )
            self.assertIn(
                "Governance",
                [item["name"] for item in report["sigmaBenefits"]],
            )
            body = markdown.read_text()
            self.assertIn("## Ease of migration", body)
            self.assertIn("## Migration recommendations", body)
            self.assertIn("**Migrate now**", body)
            self.assertIn("## Benefits of Sigma", body)
            self.assertIn("Calendar duration is not inferred", body)
            html_body = html.read_text()
            self.assertIn("Recommended migration order", html_body)
            self.assertIn("Migrate now", html_body)
            self.assertIn("Metadata-only inventory", html_body)

    def test_assessment_marks_chat_as_workbook_agent_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    from anthropic import Anthropic
                    prompt = st.chat_input("Ask")
                    if prompt:
                        Anthropic().messages.create(
                            model="example",
                            messages=[{"role": "user", "content": prompt}],
                        )
                    """
                ),
                encoding="utf-8",
            )
            output = root / "assessment.json"
            subprocess.run(
                [
                    "python3",
                    str(
                        SKILL.parent
                        / "streamlit-assessment"
                        / "scripts"
                        / "assess-streamlit.py"
                    ),
                    str(root),
                    "--out",
                    str(output),
                ],
                check=True,
            )
            project = json.loads(output.read_text())["projects"][0]
            self.assertIn(
                "workbook-agent-candidate",
                project["migrationDispositions"],
            )
            self.assertEqual(project["complexity"]["class"], "complex")

    def test_assessment_shortlist_ranks_migration_decisions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            direct = root / "direct"
            blocked = root / "blocked"
            direct.mkdir()
            blocked.mkdir()
            (direct / "streamlit_app.py").write_text(
                "import streamlit as st\nst.title('Direct candidate')\n",
                encoding="utf-8",
            )
            (blocked / "streamlit_app.py").write_text(
                textwrap.dedent(
                    """
                    import streamlit as st
                    conn = st.connection("snowflake")
                    table = st.text_input("Table")
                    conn.query(f"SELECT * FROM {table}")
                    """
                ),
                encoding="utf-8",
            )
            output = root / "assessment.json"
            subprocess.run(
                [
                    "python3",
                    str(
                        SKILL.parent
                        / "streamlit-assessment"
                        / "scripts"
                        / "assess-streamlit.py"
                    ),
                    str(blocked),
                    str(direct),
                    "--out",
                    str(output),
                ],
                check=True,
            )
            report = json.loads(output.read_text())
            self.assertEqual(
                [
                    item["recommendation"]["decision"]
                    for item in report["shortlist"]
                ],
                ["migrate-now", "defer-until-unblocked"],
            )
            self.assertEqual(
                [item["rank"] for item in report["shortlist"]],
                [1, 2],
            )

    def test_phase6_gate_dependency_closure_loads(self):
        result = subprocess.run(
            ["ruby", str(SKILL / "scripts" / "assert-phase6-ran.rb"), "--help"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("--workdir", result.stdout)


if __name__ == "__main__":
    unittest.main()
