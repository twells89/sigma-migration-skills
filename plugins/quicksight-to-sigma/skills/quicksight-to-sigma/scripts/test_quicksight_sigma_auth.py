#!/usr/bin/env python3
"""Credential-free coverage for QuickSight's plugin-local Sigma live paths."""

import json
import os
from pathlib import Path
import sys
import time
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))

import sigma_rest
import apply_sigma_rls


class QuickSightSigmaAuthTest(unittest.TestCase):
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
        self.calls = []
        self.queue = []
        self.provider_calls = 0
        sigma_rest._token_override = None
        sigma_rest._minted_at = None
        sigma_rest._refresh_inflight = False
        sigma_rest._validated_bases.clear()

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
        return sigma_rest._Resp(status, payload)

    def provider(self, token="browser-token"):
        self.provider_calls += 1
        return {
            "SIGMA_API_TOKEN": token,
            "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }

    def env(self, extra=None):
        values = {"SIGMA_BASE_URL": self.BASE}
        values.update(extra or {})
        return mock.patch.dict(os.environ, values, clear=True)

    def test_valid_caller_token_is_reused(self):
        self.queue = [(200, '{"ok":true}')]
        with self.env({"SIGMA_API_TOKEN": "caller-token"}), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ), mock.patch.object(
            sigma_rest,
            "token_provider_result",
            side_effect=AssertionError("provider called for a valid token"),
        ):
            self.assertEqual({"ok": True}, apply_sigma_rls.api("GET", "/v2/test"))

        self.assertEqual("Bearer caller-token", self.calls[0]["headers"]["Authorization"])

    def test_browser_only_session_authenticates_without_client_credentials(self):
        self.queue = [(200, '{"ok":true}')]
        with self.env(), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ), mock.patch.object(
            sigma_rest, "token_provider_result", side_effect=self.provider
        ):
            self.assertEqual({"ok": True}, apply_sigma_rls.api("GET", "/v2/test"))
            self.assertNotIn("SIGMA_CLIENT_ID", os.environ)

        self.assertEqual("Bearer browser-token", self.calls[0]["headers"]["Authorization"])
        self.assertEqual(1, self.provider_calls)

    def test_known_stale_token_refreshes_before_request(self):
        stale = sigma_rest._iso_z(
            time.time() - sigma_rest.TOKEN_TTL_SECONDS - 1
        )
        self.queue = [(200, '{"ok":true}')]
        with self.env(
            {"SIGMA_API_TOKEN": "known-old", "SIGMA_TOKEN_MINTED_AT": stale}
        ), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ), mock.patch.object(
            sigma_rest,
            "token_provider_result",
            side_effect=lambda: self.provider("age-refreshed"),
        ):
            self.assertEqual({"ok": True}, apply_sigma_rls.api("GET", "/v2/test"))

        self.assertEqual("Bearer age-refreshed", self.calls[0]["headers"]["Authorization"])
        self.assertEqual(1, self.provider_calls)

    def test_one_401_refreshes_and_retries_once(self):
        self.queue = [(401, "expired"), (200, '{"ok":true}')]
        with self.env({"SIGMA_API_TOKEN": "expired-token"}), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ), mock.patch.object(
            sigma_rest,
            "token_provider_result",
            side_effect=lambda: self.provider("retry-token"),
        ):
            self.assertEqual({"ok": True}, apply_sigma_rls.api("GET", "/v2/test"))

        self.assertEqual(
            ["Bearer expired-token", "Bearer retry-token"],
            [call["headers"]["Authorization"] for call in self.calls],
        )
        self.assertEqual(1, self.provider_calls)

    def test_second_401_is_surfaced_without_third_request(self):
        self.queue = [(401, "expired"), (401, "still unauthorized")]
        with self.env({"SIGMA_API_TOKEN": "expired-token"}), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ), mock.patch.object(
            sigma_rest,
            "token_provider_result",
            side_effect=lambda: self.provider("retry-token"),
        ):
            with self.assertRaisesRegex(SystemExit, "still unauthorized"):
                apply_sigma_rls.api("GET", "/v2/test")

        self.assertEqual(2, len(self.calls))
        self.assertEqual(1, self.provider_calls)

    def test_rls_json_body_and_text_response_contract_are_preserved(self):
        self.queue = [(200, "schemaVersion: 1\n")]
        with self.env({"SIGMA_API_TOKEN": "caller-token"}), mock.patch.object(
            sigma_rest, "_send", side_effect=self.send
        ):
            result = apply_sigma_rls.api("PUT", "/v2/dataModels/dm/spec", {"x": 1})

        self.assertEqual("schemaVersion: 1\n", result)
        self.assertEqual(json.dumps({"x": 1}), self.calls[0]["body"])

    def test_all_plugin_local_helpers_delegate_sigma_auth(self):
        rls_source = (HERE / "apply_sigma_rls.py").read_text(encoding="utf-8")
        self.assertIn("import sigma_rest", rls_source)
        self.assertIn("sigma_rest.request(", rls_source)
        self.assertNotIn("urllib.request", rls_source)
        self.assertNotIn("SIGMA_API_TOKEN", rls_source)

        for filename in (
            "post-and-readback.rb",
            "put-layout.rb",
            "validate-sigma-formula.rb",
        ):
            with self.subTest(filename=filename):
                source = (HERE / filename).read_text(encoding="utf-8")
                self.assertIn("Sigma.request(", source)
                self.assertNotIn("req['Authorization']", source)
                self.assertNotIn('ENV.fetch("SIGMA_API_TOKEN")', source)
                self.assertNotIn("ENV.fetch('SIGMA_API_TOKEN')", source)

        scout_source = (HERE / "scout-validate-and-persist.rb").read_text(
            encoding="utf-8"
        )
        self.assertIn("validate-sigma-formula.rb", scout_source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
