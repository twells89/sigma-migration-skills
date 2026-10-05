#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SKILL = Path(__file__).resolve().parents[1]
MIGRATE = SKILL / "scripts" / "migrate-streamlit.py"

spec = importlib.util.spec_from_file_location("migrate_streamlit", MIGRATE)
migrate = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(migrate)

TOKEN_PROVIDER = SKILL / "scripts" / "get_token.py"
provider_spec = importlib.util.spec_from_file_location(
    "streamlit_sigma_get_token", TOKEN_PROVIDER
)
get_token = importlib.util.module_from_spec(provider_spec)
assert provider_spec.loader
provider_spec.loader.exec_module(get_token)


class SafetyGateTest(unittest.TestCase):
    def test_yaml_spec_response_fallback_preserves_ids(self):
        api = object.__new__(migrate.SigmaAPI)
        api.base_url = "https://aws-api." + "sigma" + "computing.com"
        api.token = "test"
        with patch.object(
            migrate.sigma_rest,
            "request",
            return_value=b"success: true\nworkbookId: wb-123\n",
        ) as request:
            result = api.request("POST", "/v2/workbooks/spec", {"x": 1})
        self.assertEqual(result["workbookId"], "wb-123")
        request.assert_called_once_with(
            "POST",
            "/v2/workbooks/spec",
            body='{"x": 1}',
            accept="application/json",
            binary=True,
        )

    def test_insecure_base_url_is_rejected_before_token_request(self):
        env = {
            "SIGMA_BASE_URL": "http://attacker.example",
            "SIGMA_API_TOKEN": "pre-minted",
        }
        with patch.dict(os.environ, env, clear=True):
            with patch.object(migrate.sigma_rest, "_send") as send:
                with self.assertRaisesRegex(RuntimeError, "must use https"):
                    migrate.SigmaAPI()
                send.assert_not_called()

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
                "validate-then-migrate",
            )
            self.assertTrue(project["recommendation"]["recommended"])
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
            self.assertEqual(
                project["recommendation"]["decision"],
                "migrate-with-redesign",
            )
            self.assertTrue(project["recommendation"]["recommended"])

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
                    def load_data():
                        return conn.query(f"SELECT * FROM {table}")
                    load_data()
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
                ["migrate-now", "resolve-then-migrate"],
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


class SigmaAPIAuthTest(unittest.TestCase):
    BASE = "https://api.sigmacomputing.com"

    def setUp(self):
        self._neutral_env = migrate.sigma_rest.NEUTRAL_ENV
        migrate.sigma_rest.NEUTRAL_ENV = "/nonexistent/streamlit-auth-test-env"
        self._reset_client()

    def tearDown(self):
        migrate.sigma_rest.NEUTRAL_ENV = self._neutral_env
        self._reset_client()

    @staticmethod
    def _reset_client():
        migrate.sigma_rest._token_override = None
        migrate.sigma_rest._minted_at = None
        migrate.sigma_rest._refresh_inflight = False
        migrate.sigma_rest._validated_bases.clear()

    @staticmethod
    def _provider_exports():
        result = get_token.mint_token()
        return {
            "SIGMA_API_TOKEN": result.token,
            "SIGMA_TOKEN_MINTED_AT": result.minted_at,
            "SIGMA_AUTH_METHOD": result.auth_method,
        }

    @staticmethod
    def _sender(queue, calls):
        def send(method, url, headers, body, timeout):
            calls.append(
                {
                    "method": method,
                    "url": url,
                    "headers": headers,
                    "body": body,
                    "timeout": timeout,
                }
            )
            status, response_body = queue.pop(0)
            if isinstance(response_body, (dict, list)):
                response_body = json.dumps(response_body)
            return migrate.sigma_rest._Resp(status, response_body)

        return send

    def test_pre_minted_token_is_reused_without_provider_mint(self):
        calls = []
        queue = [(200, {"userId": "user-1"})]
        env = {
            "SIGMA_BASE_URL": self.BASE,
            "SIGMA_API_TOKEN": "caller-token",
        }
        with patch.dict(os.environ, env, clear=True), patch.object(
            migrate.sigma_rest,
            "_send",
            side_effect=self._sender(queue, calls),
        ), patch.object(migrate.sigma_rest, "token_provider_result") as provider:
            api = migrate.SigmaAPI()
            result = api.request("GET", "/v2/whoami")

        self.assertEqual({"userId": "user-1"}, result)
        self.assertEqual("caller-token", api.token)
        self.assertEqual("Bearer caller-token", calls[0]["headers"]["Authorization"])
        provider.assert_not_called()

    def test_browser_provider_route_is_used_without_client_credentials(self):
        calls = []
        queue = [(200, {"userId": "browser-user"})]
        minted = migrate.sigma_rest._iso_z(time.time())
        browser_result = get_token.TokenResult(
            self.BASE, "browser-token", minted, "browser"
        )
        with patch.dict(os.environ, {"SIGMA_BASE_URL": self.BASE}, clear=True), patch.object(
            get_token, "_load_neutral_env"
        ), patch.object(
            get_token, "_mint_browser_refresh", return_value=browser_result
        ) as browser, patch.object(
            get_token, "_mint_client_credentials"
        ) as client, patch.object(
            get_token, "_verify_token", side_effect=lambda result: result
        ), patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            side_effect=self._provider_exports,
        ), patch.object(
            migrate.sigma_rest,
            "_send",
            side_effect=self._sender(queue, calls),
        ):
            api = migrate.SigmaAPI()
            result = api.request("GET", "/v2/whoami")
            auth_method = os.environ.get("SIGMA_AUTH_METHOD")

        self.assertEqual({"userId": "browser-user"}, result)
        self.assertEqual("browser-token", api.token)
        self.assertEqual("browser", auth_method)
        self.assertEqual("Bearer browser-token", calls[0]["headers"]["Authorization"])
        browser.assert_called_once()
        client.assert_not_called()

    def test_client_credentials_are_fallback_through_provider(self):
        calls = []
        queue = [(200, {"userId": "service-user"})]
        minted = migrate.sigma_rest._iso_z(time.time())
        client_result = get_token.TokenResult(
            self.BASE, "client-token", minted, "client-credentials"
        )
        env = {
            "SIGMA_BASE_URL": self.BASE,
            "SIGMA_CLIENT_ID": "client-id",
            "SIGMA_CLIENT_SECRET": "client-secret",
        }
        with patch.dict(os.environ, env, clear=True), patch.object(
            get_token, "_load_neutral_env"
        ), patch.object(
            get_token,
            "_mint_browser_refresh",
            side_effect=get_token.BrowserUnavailable("no keychain session"),
        ) as browser, patch.object(
            get_token, "_mint_client_credentials", return_value=client_result
        ) as client, patch.object(
            get_token, "_verify_token", side_effect=lambda result: result
        ), patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            side_effect=self._provider_exports,
        ), patch.object(
            migrate.sigma_rest,
            "_send",
            side_effect=self._sender(queue, calls),
        ):
            api = migrate.SigmaAPI()
            result = api.request("GET", "/v2/whoami")
            auth_method = os.environ.get("SIGMA_AUTH_METHOD")

        self.assertEqual({"userId": "service-user"}, result)
        self.assertEqual("client-token", api.token)
        self.assertEqual("client-credentials", auth_method)
        self.assertEqual("Bearer client-token", calls[0]["headers"]["Authorization"])
        browser.assert_called_once()
        client.assert_called_once_with(self.BASE, "client-id", "client-secret")

    def test_known_stale_token_is_refreshed_before_request(self):
        calls = []
        queue = [(200, {"ok": True})]
        old_stamp = migrate.sigma_rest._iso_z(
            time.time() - migrate.sigma_rest.TOKEN_TTL_SECONDS - 60
        )
        fresh_stamp = migrate.sigma_rest._iso_z(time.time())
        provider_result = {
            "SIGMA_API_TOKEN": "proactive-token",
            "SIGMA_TOKEN_MINTED_AT": fresh_stamp,
            "SIGMA_AUTH_METHOD": "browser",
        }
        env = {
            "SIGMA_BASE_URL": self.BASE,
            "SIGMA_API_TOKEN": "known-stale-token",
            "SIGMA_TOKEN_MINTED_AT": old_stamp,
        }
        with patch.dict(os.environ, env, clear=True), patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            return_value=provider_result,
        ) as provider, patch.object(
            migrate.sigma_rest,
            "_send",
            side_effect=self._sender(queue, calls),
        ):
            api = migrate.SigmaAPI()
            result = api.request("GET", "/v2/test")

        self.assertEqual({"ok": True}, result)
        self.assertEqual("proactive-token", api.token)
        self.assertEqual("Bearer proactive-token", calls[0]["headers"]["Authorization"])
        provider.assert_called_once()

    def test_401_refreshes_once_and_retries_with_provider_token(self):
        calls = []
        queue = [(401, "expired"), (200, {"ok": True})]
        provider_result = {
            "SIGMA_API_TOKEN": "retry-token",
            "SIGMA_TOKEN_MINTED_AT": migrate.sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }
        env = {
            "SIGMA_BASE_URL": self.BASE,
            "SIGMA_API_TOKEN": "expired-token",
        }
        with patch.dict(os.environ, env, clear=True), patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            return_value=provider_result,
        ) as provider, patch.object(
            migrate.sigma_rest,
            "_send",
            side_effect=self._sender(queue, calls),
        ):
            api = migrate.SigmaAPI()
            result = api.request("GET", "/v2/test")

        self.assertEqual({"ok": True}, result)
        self.assertEqual("retry-token", api.token)
        self.assertEqual(
            ["Bearer expired-token", "Bearer retry-token"],
            [call["headers"]["Authorization"] for call in calls],
        )
        provider.assert_called_once()

    def test_orchestrator_has_no_inline_token_exchange_or_static_transport(self):
        source = MIGRATE.read_text(encoding="utf-8")
        self.assertNotIn("/v2/auth/token", source)
        self.assertNotIn("client_credentials", source)
        self.assertNotIn("urllib.request", source)
        self.assertIn("sigma_rest.request(", source)


if __name__ == "__main__":
    unittest.main()
