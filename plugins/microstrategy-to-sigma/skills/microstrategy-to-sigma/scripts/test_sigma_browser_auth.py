#!/usr/bin/env python3
"""Creds-free browser OAuth contracts for MicroStrategy Sigma live paths."""

import importlib.util
import json
import os
import time
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify_parity = load("microstrategy_verify_parity_auth_test", "verify_parity.py")
scout_validate = load("microstrategy_scout_validate_auth_test", "scout-validate.py")
scout_gate = load("microstrategy_scout_gate_auth_test", "scout-gate-readback.py")
sigma_request = load("microstrategy_sigma_request_auth_test", "sigma-request.py")
get_token = load("microstrategy_get_token_auth_test", "get_token.py")
sigma_rest = verify_parity.sigma_rest


class SigmaBrowserAuthTest(unittest.TestCase):
    BASE = "https://api.sigmacomputing.com"
    ENV_KEYS = (
        "SIGMA_BASE_URL",
        "SIGMA_API_TOKEN",
        "SIGMA_TOKEN_MINTED_AT",
        "SIGMA_AUTH_METHOD",
        "SIGMA_AUTH_MODE",
        "SIGMA_CLIENT_ID",
        "SIGMA_CLIENT_SECRET",
        "SIGMA_ALLOW_INSECURE_BASE_URL",
        "SIGMA_WORKDIR",
    )

    def setUp(self):
        self.saved_env = {key: os.environ.get(key) for key in self.ENV_KEYS}
        self.original_send = sigma_rest._send
        self.original_provider = sigma_rest.token_provider_result
        self.original_neutral_env = sigma_rest.NEUTRAL_ENV
        sigma_rest.NEUTRAL_ENV = "/nonexistent/microstrategy-auth-test-env"
        for key in self.ENV_KEYS:
            os.environ.pop(key, None)
        os.environ["SIGMA_BASE_URL"] = self.BASE
        self.reset_auth()
        self.calls = []
        self.queue = []
        self.provider_calls = 0

    def tearDown(self):
        sigma_rest._send = self.original_send
        sigma_rest.token_provider_result = self.original_provider
        sigma_rest.NEUTRAL_ENV = self.original_neutral_env
        self.reset_auth()
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def reset_auth():
        sigma_rest._token_override = None
        sigma_rest._minted_at = None
        sigma_rest._refresh_inflight = False
        sigma_rest._validated_bases.clear()

    def browser_provider(self, token="browser-token"):
        self.provider_calls += 1
        return {
            "SIGMA_API_TOKEN": token,
            "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }

    def send(self, method, url, headers, body, timeout):
        self.calls.append(
            {
                "method": method,
                "url": url,
                "headers": dict(headers),
                "body": body,
                "timeout": timeout,
            }
        )
        status, payload = self.queue.pop(0)
        if isinstance(payload, (dict, list)):
            payload = json.dumps(payload)
        return sigma_rest._Resp(status, payload)

    def test_valid_bearer_is_reused_and_parity_keeps_status_and_raw_bytes(self):
        os.environ["SIGMA_API_TOKEN"] = "caller-token"
        sigma_rest.token_provider_result = lambda: self.fail(
            "a valid caller bearer must not invoke the provider"
        )
        self.queue = [(202, b"export pending")]
        sigma_rest._send = self.send

        status, payload = verify_parity.api(
            "GET", "/v2/query/query-1/download", raw=True
        )

        self.assertEqual(202, status)
        self.assertEqual(b"export pending", payload)
        self.assertEqual(
            "Bearer caller-token", self.calls[0]["headers"]["Authorization"]
        )

    def test_browser_only_auth_works_for_formula_scout(self):
        sigma_rest.token_provider_result = self.browser_provider
        self.queue = [(200, {"entries": []})]
        sigma_rest._send = self.send

        status, payload = scout_validate.api("GET", "/v2/dataModels/dm/spec")

        self.assertEqual(200, status)
        self.assertEqual({"entries": []}, json.loads(payload))
        self.assertEqual(1, self.provider_calls)
        self.assertNotIn("SIGMA_CLIENT_ID", os.environ)
        self.assertEqual(
            "Bearer browser-token", self.calls[0]["headers"]["Authorization"]
        )

    def test_client_credentials_are_the_browser_provider_fallback(self):
        client_result = get_token.TokenResult(
            self.BASE,
            "client-token",
            sigma_rest._iso_z(time.time()),
            "client-credentials",
        )
        os.environ.update(
            {
                "SIGMA_CLIENT_ID": "client-id",
                "SIGMA_CLIENT_SECRET": "client-secret",
            }
        )

        def provider_exports():
            result = get_token.mint_token()
            return {
                "SIGMA_API_TOKEN": result.token,
                "SIGMA_TOKEN_MINTED_AT": result.minted_at,
                "SIGMA_AUTH_METHOD": result.auth_method,
            }

        self.queue = [(200, {"entries": []})]
        sigma_rest._send = self.send
        sigma_rest.token_provider_result = provider_exports
        with mock.patch.object(get_token, "_load_neutral_env"), mock.patch.object(
            get_token,
            "_mint_browser_refresh",
            side_effect=get_token.BrowserUnavailable("no keychain session"),
        ) as browser, mock.patch.object(
            get_token, "_mint_client_credentials", return_value=client_result
        ) as client, mock.patch.object(
            get_token, "_verify_token", side_effect=lambda result: result
        ):
            status, _ = scout_gate.api("GET", "/v2/workbooks/wb/columns")

        self.assertEqual(200, status)
        self.assertEqual("Bearer client-token", self.calls[0]["headers"]["Authorization"])
        browser.assert_called_once_with(self.BASE)
        client.assert_called_once_with(self.BASE, "client-id", "client-secret")

    def test_known_old_token_refreshes_before_the_live_readback(self):
        os.environ.update(
            {
                "SIGMA_API_TOKEN": "known-old",
                "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(
                    time.time() - sigma_rest.TOKEN_TTL_SECONDS - 1
                ),
            }
        )
        sigma_rest.token_provider_result = self.browser_provider
        self.queue = [(200, {"entries": []})]
        sigma_rest._send = self.send

        status, _ = scout_gate.api("GET", "/v2/workbooks/wb/columns")

        self.assertEqual(200, status)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(
            "Bearer browser-token", self.calls[0]["headers"]["Authorization"]
        )

    def test_401_refreshes_once_and_preserves_parity_text_response(self):
        os.environ["SIGMA_API_TOKEN"] = "expired-token"
        sigma_rest.token_provider_result = self.browser_provider
        self.queue = [(401, b"expired"), (200, b'{"queryId":"query-1"}')]
        sigma_rest._send = self.send

        status, payload = verify_parity.api(
            "POST",
            "/v2/workbooks/wb/export",
            {"elementId": "chart", "format": {"type": "csv"}},
        )

        self.assertEqual(200, status)
        self.assertEqual('{"queryId":"query-1"}', payload)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(
            ["Bearer expired-token", "Bearer browser-token"],
            [call["headers"]["Authorization"] for call in self.calls],
        )

    def test_second_401_is_returned_without_a_third_request(self):
        os.environ["SIGMA_API_TOKEN"] = "expired-token"
        sigma_rest.token_provider_result = self.browser_provider
        self.queue = [(401, b"expired"), (401, b"still unauthorized")]
        sigma_rest._send = self.send

        status, payload = verify_parity.api("GET", "/v2/workbooks/wb/spec")

        self.assertEqual(401, status)
        self.assertEqual("still unauthorized", payload)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(2, len(self.calls))

    def test_raw_spec_helper_uses_shared_transport_without_reformatting(self):
        os.environ["SIGMA_API_TOKEN"] = "caller-token"
        raw = b"workbookId: wb-raw\n"
        self.queue = [(200, raw)]
        sigma_rest._send = self.send

        payload = sigma_request.api(
            "POST", "/v2/workbooks/spec", '{"name":"Workbook"}'
        )

        self.assertEqual(raw, payload)
        self.assertEqual('{"name":"Workbook"}', self.calls[0]["body"])
        self.assertEqual("*/*", self.calls[0]["headers"]["Accept"])

    def test_raw_spec_helper_refreshes_once_on_401(self):
        os.environ["SIGMA_API_TOKEN"] = "expired-token"
        sigma_rest.token_provider_result = self.browser_provider
        self.queue = [(401, b"expired"), (200, b"workbookId: wb-fresh\n")]
        sigma_rest._send = self.send

        payload = sigma_request.api(
            "POST", "/v2/workbooks/spec", '{"name":"Workbook"}'
        )

        self.assertEqual(b"workbookId: wb-fresh\n", payload)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(2, len(self.calls))

    def test_plugin_live_paths_do_not_read_a_static_bearer(self):
        for filename in (
            "verify_parity.py",
            "scout-validate.py",
            "scout-gate-readback.py",
            "sigma-request.py",
        ):
            source = (HERE / filename).read_text(encoding="utf-8")
            with self.subTest(script=filename):
                self.assertIn("sigma_rest", source)
                self.assertNotIn('os.environ["SIGMA_API_TOKEN"]', source)
                self.assertNotIn("urllib.request", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
