#!/usr/bin/env python3
"""Credentials-free transport/auth contracts for the Qlik Python builders."""

import importlib.util
import json
import os
import sys
import time
import unittest
from pathlib import Path
from unittest import mock


SKILL = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL / "scripts"
LIB = SCRIPTS / "lib"
for candidate in (str(SCRIPTS), str(LIB)):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)

import sigma_rest


def load_script(filename, module_name):
    spec = importlib.util.spec_from_file_location(module_name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DM = load_script("build-sigma-dm.py", "qlik_builder_auth_dm")
WORKBOOK = load_script("build-sigma-workbook.py", "qlik_builder_auth_workbook")


class BuilderSigmaAuthTest(unittest.TestCase):
    BASE = "https://api.sigmacomputing.com"
    ENV_KEYS = (
        "SIGMA_BASE_URL",
        "SIGMA_API_TOKEN",
        "SIGMA_TOKEN_MINTED_AT",
        "SIGMA_AUTH_METHOD",
        "SIGMA_CLIENT_ID",
        "SIGMA_CLIENT_SECRET",
        "SIGMA_WORKDIR",
        "SIGMA_ALLOW_INSECURE_BASE_URL",
    )

    def setUp(self):
        self.saved_env = {key: os.environ.get(key) for key in self.ENV_KEYS}
        self.original_neutral_env = sigma_rest.NEUTRAL_ENV
        sigma_rest.NEUTRAL_ENV = "/nonexistent/qlik-builder-auth-test-env"
        self.reset_client()
        self.calls = []
        self.queue = []

    def tearDown(self):
        sigma_rest.NEUTRAL_ENV = self.original_neutral_env
        self.reset_client()
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def reset_client():
        sigma_rest._token_override = None
        sigma_rest._minted_at = None
        sigma_rest._refresh_inflight = False
        sigma_rest._validated_bases.clear()

    def send(self, method, url, headers, body, timeout):
        self.calls.append(
            {
                "method": method,
                "url": url,
                "headers": headers,
                "body": body,
                "timeout": timeout,
            }
        )
        status, response_body = self.queue.pop(0)
        if isinstance(response_body, (dict, list)):
            response_body = json.dumps(response_body)
        return sigma_rest._Resp(status, response_body)

    def provider_result(self, token="browser-token"):
        return {
            "SIGMA_API_TOKEN": token,
            "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }

    def test_data_model_builder_uses_shared_json_transport(self):
        self.queue = [(200, {"dataModelId": "dm-1"})]
        env = {"SIGMA_BASE_URL": self.BASE, "SIGMA_API_TOKEN": "caller-token"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ), mock.patch.object(sigma_rest, "token_provider_result") as provider:
            result = DM.api("POST", "/v2/dataModels/spec", {"name": "Orders"})

        self.assertEqual({"dataModelId": "dm-1"}, result)
        self.assertEqual("post", self.calls[0]["method"])
        self.assertEqual(self.BASE + "/v2/dataModels/spec", self.calls[0]["url"])
        self.assertEqual(json.dumps({"name": "Orders"}), self.calls[0]["body"])
        self.assertEqual("application/json", self.calls[0]["headers"]["Accept"])
        self.assertEqual("application/json", self.calls[0]["headers"]["Content-Type"])
        self.assertEqual("Bearer caller-token", self.calls[0]["headers"]["Authorization"])
        provider.assert_not_called()

    def test_builder_raw_response_contracts_are_preserved(self):
        dm_yaml = "dataModelId: dm-yaml\n"
        workbook_yaml = "workbookId: wb-yaml\n"
        self.queue = [(200, dm_yaml), (200, workbook_yaml)]
        env = {"SIGMA_BASE_URL": self.BASE, "SIGMA_API_TOKEN": "caller-token"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ):
            dm_result = DM.api("POST", "/v2/dataModels/spec", {"name": "DM"})
            workbook_result = WORKBOOK.api_post(
                "/v2/workbooks/spec", {"name": "Workbook"}
            )

        self.assertEqual(dm_yaml, dm_result)
        self.assertEqual(workbook_yaml, workbook_result)

    def test_workbook_builder_put_uses_shared_transport(self):
        raw = '{"workbookId":"wb-1"}\n'
        self.queue = [(200, raw)]
        env = {"SIGMA_BASE_URL": self.BASE, "SIGMA_API_TOKEN": "caller-token"}
        body = {"document": {"schemaVersion": 1}}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ):
            result = WORKBOOK.api_put("/v2/workbooks/wb-1/spec", body)

        self.assertEqual(raw, result)
        self.assertEqual("put", self.calls[0]["method"])
        self.assertEqual(json.dumps(body), self.calls[0]["body"])
        self.assertEqual("Bearer caller-token", self.calls[0]["headers"]["Authorization"])

    def test_both_builders_support_browser_only_auth(self):
        cases = (
            ("data-model", lambda: DM.api("GET", "/v2/whoami"), {"userId": "browser"}),
            (
                "workbook",
                lambda: WORKBOOK.api_post("/v2/workbooks/spec", {"name": "WB"}),
                '{"workbookId":"wb-browser"}',
            ),
        )
        for name, invoke, response in cases:
            with self.subTest(builder=name):
                self.reset_client()
                self.calls = []
                self.queue = [(200, response)]
                with mock.patch.dict(
                    os.environ, {"SIGMA_BASE_URL": self.BASE}, clear=True
                ), mock.patch.object(
                    sigma_rest,
                    "token_provider_result",
                    return_value=self.provider_result(),
                ) as provider, mock.patch.object(
                    sigma_rest, "_send", side_effect=self.send
                ):
                    invoke()
                    self.assertNotIn("SIGMA_CLIENT_ID", os.environ)

                self.assertEqual(
                    "Bearer browser-token",
                    self.calls[0]["headers"]["Authorization"],
                )
                provider.assert_called_once()

    def test_both_builders_refresh_once_on_401(self):
        cases = (
            ("data-model", lambda: DM.api("GET", "/v2/test"), {"ok": True}),
            (
                "workbook",
                lambda: WORKBOOK.api_post("/v2/workbooks/spec", {"name": "WB"}),
                '{"ok":true}',
            ),
        )
        for name, invoke, response in cases:
            with self.subTest(builder=name):
                self.reset_client()
                self.calls = []
                self.queue = [(401, "expired"), (200, response)]
                env = {
                    "SIGMA_BASE_URL": self.BASE,
                    "SIGMA_API_TOKEN": "expired-token",
                }
                with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
                    sigma_rest,
                    "token_provider_result",
                    return_value=self.provider_result("retry-token"),
                ) as provider, mock.patch.object(
                    sigma_rest, "_send", side_effect=self.send
                ):
                    invoke()

                self.assertEqual(
                    ["Bearer expired-token", "Bearer retry-token"],
                    [call["headers"]["Authorization"] for call in self.calls],
                )
                provider.assert_called_once()

    def test_second_401_is_not_retried_a_third_time(self):
        self.queue = [(401, "expired"), (401, "still unauthorized")]
        env = {"SIGMA_BASE_URL": self.BASE, "SIGMA_API_TOKEN": "expired-token"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            sigma_rest,
            "token_provider_result",
            return_value=self.provider_result("retry-token"),
        ) as provider, mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ):
            with self.assertRaisesRegex(sigma_rest.SigmaError, "401"):
                WORKBOOK.api_put("/v2/workbooks/wb-1/spec", {"document": {}})

        self.assertEqual(2, len(self.calls))
        provider.assert_called_once()

    def test_import_and_offline_paths_do_not_eagerly_authenticate(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            sigma_rest, "token_provider_result"
        ) as provider:
            load_script("build-sigma-dm.py", "qlik_builder_auth_dm_lazy")
            load_script("build-sigma-workbook.py", "qlik_builder_auth_workbook_lazy")

        provider.assert_not_called()

    def test_python_live_paths_do_not_read_a_static_bearer(self):
        for filename in (
            "build-sigma-dm.py",
            "build-sigma-workbook.py",
            "batch-migrate.py",
            "migrate-qlik.py",
            "scout-validate.py",
            "apply_sigma_rls.py",
        ):
            source = (SCRIPTS / filename).read_text(encoding="utf-8")
            with self.subTest(script=filename):
                self.assertIn("sigma_rest", source)
                self.assertIn("sigma_rest.request(", source)
                self.assertNotIn('os.environ["SIGMA_API_TOKEN"]', source)
                self.assertNotIn('"Authorization": "Bearer "', source)
                self.assertNotIn("urllib.request", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
