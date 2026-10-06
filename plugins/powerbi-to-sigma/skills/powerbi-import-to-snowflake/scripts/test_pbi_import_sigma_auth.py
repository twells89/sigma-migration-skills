#!/usr/bin/env python3
"""Credentials-free Sigma sync auth tests for pbi_import_to_snowflake.py."""

import contextlib
import importlib.util
import io
import json
import os
import sys
import time
import types
import unittest
from pathlib import Path

# The sync seam does not use MSAL. Keep this credentials-free unit test runnable
# on the repository's base Python even when the optional Power BI runtime has
# not been bootstrapped yet.
try:
    import msal  # noqa: F401
except ImportError:
    sys.modules["msal"] = types.ModuleType("msal")


HERE = Path(__file__).resolve().parent
TARGET = HERE / "pbi_import_to_snowflake.py"


def load_target():
    spec = importlib.util.spec_from_file_location("pbi_import_sigma_auth_target", TARGET)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


target = load_target()
sigma_rest = target.sigma_rest


class SigmaSyncAuthTest(unittest.TestCase):
    BASE = "https://api.eu.azure.sigmacomputing.com"
    ENV_KEYS = (
        "SIGMA_BASE_URL",
        "SIGMA_API_TOKEN",
        "SIGMA_TOKEN_MINTED_AT",
        "SIGMA_AUTH_METHOD",
        "SIGMA_AUTH_MODE",
        "SIGMA_CLIENT_ID",
        "SIGMA_CLIENT_SECRET",
        "SIGMA_WORKDIR",
        "SIGMA_ALLOW_INSECURE_BASE_URL",
    )

    def setUp(self):
        self.saved_env = {key: os.environ.get(key) for key in self.ENV_KEYS}
        self.original_neutral_env = sigma_rest.NEUTRAL_ENV
        self.original_send = sigma_rest._send
        self.original_provider = sigma_rest.token_provider_result
        sigma_rest.NEUTRAL_ENV = "/nonexistent/pbi-import-auth-test-env"
        self.calls = []
        self.queue = []
        self.provider_calls = 0
        self.reset()
        sigma_rest._send = self.send

    def tearDown(self):
        sigma_rest.NEUTRAL_ENV = self.original_neutral_env
        sigma_rest._send = self.original_send
        sigma_rest.token_provider_result = self.original_provider
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

    def reset(self, extra=None):
        for key in self.ENV_KEYS:
            os.environ.pop(key, None)
        os.environ["SIGMA_BASE_URL"] = self.BASE
        os.environ.update(extra or {})
        self.reset_client()
        self.calls = []
        self.queue = []
        self.provider_calls = 0

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

    def provider(self, token="browser-token", method="browser"):
        self.provider_calls += 1
        return {
            "SIGMA_API_TOKEN": token,
            "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": method,
        }

    @staticmethod
    def plan(*names):
        return [{"sf_name": name} for name in names]

    def sync(self, *names):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = target.sigma_sync(
                self.plan(*names), "DB", "LANDING", "connection-1"
            )
        return result, stderr.getvalue()

    def test_valid_caller_token_is_reused_on_configured_cloud_host(self):
        self.reset({"SIGMA_API_TOKEN": "caller-token"})
        self.queue = [(200, "{}")]
        sigma_rest.token_provider_result = lambda: self.fail(
            "valid caller token must not invoke the provider"
        )

        result, output = self.sync("SALES")

        self.assertIsNone(result)
        self.assertIn("[sigma-sync] SALES -> ok", output)
        self.assertEqual(1, len(self.calls))
        self.assertEqual(
            self.BASE + "/v2/connections/connection-1/sync",
            self.calls[0]["url"],
        )
        self.assertEqual(
            {"path": ["DB", "LANDING", "SALES"]},
            json.loads(self.calls[0]["body"]),
        )
        self.assertEqual(
            "Bearer caller-token", self.calls[0]["headers"]["Authorization"]
        )

    def test_browser_only_auth_needs_no_client_credentials(self):
        sigma_rest.token_provider_result = self.provider
        self.queue = [(200, "{}")]

        _, output = self.sync("ORDERS")

        self.assertIn("[sigma-sync] ORDERS -> ok", output)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(
            "Bearer browser-token", self.calls[0]["headers"]["Authorization"]
        )
        self.assertNotIn("SIGMA_CLIENT_ID", os.environ)

    def test_client_credentials_remain_supported_as_provider_fallback(self):
        self.reset(
            {
                "SIGMA_CLIENT_ID": "client-id",
                "SIGMA_CLIENT_SECRET": "client-secret",
            }
        )
        sigma_rest.token_provider_result = lambda: self.provider(
            "client-token", "client-credentials"
        )
        self.queue = [(200, "{}")]

        _, output = self.sync("CUSTOMERS")

        self.assertIn("[sigma-sync] CUSTOMERS -> ok", output)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(
            "Bearer client-token", self.calls[0]["headers"]["Authorization"]
        )
        self.assertEqual("client-credentials", os.environ["SIGMA_AUTH_METHOD"])

    def test_known_stale_token_refreshes_before_sync_request(self):
        self.reset(
            {
                "SIGMA_API_TOKEN": "known-old",
                "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(
                    time.time() - sigma_rest.TOKEN_TTL_SECONDS - 1
                ),
            }
        )
        sigma_rest.token_provider_result = lambda: self.provider("age-refreshed")
        self.queue = [(200, "{}")]

        _, output = self.sync("DATES")

        self.assertIn("[sigma-sync] DATES -> ok", output)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(
            "Bearer age-refreshed", self.calls[0]["headers"]["Authorization"]
        )

    def test_401_refreshes_once_and_retries_with_browser_token(self):
        self.reset({"SIGMA_API_TOKEN": "expired-token"})
        sigma_rest.token_provider_result = lambda: self.provider("retry-token")
        self.queue = [(401, "expired"), (200, "{}")]

        _, output = self.sync("PRODUCTS")

        self.assertIn("[sigma-sync] PRODUCTS -> ok", output)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(
            ["Bearer expired-token", "Bearer retry-token"],
            [call["headers"]["Authorization"] for call in self.calls],
        )

    def test_second_401_is_reported_and_later_tables_continue(self):
        self.reset({"SIGMA_API_TOKEN": "expired-token"})
        sigma_rest.token_provider_result = lambda: self.provider("retry-token")
        self.queue = [
            (401, "expired"),
            (401, "still unauthorized"),
            (200, "{}"),
        ]

        result, output = self.sync("BAD_TABLE", "GOOD_TABLE")

        self.assertIsNone(result)
        self.assertIn("[sigma-sync] BAD_TABLE -> POST /v2/connections/", output)
        self.assertIn("-> 401", output)
        self.assertIn("[sigma-sync] GOOD_TABLE -> ok", output)
        self.assertEqual(3, len(self.calls))
        self.assertEqual(1, self.provider_calls)

    def test_unavailable_sigma_auth_skips_optional_sync(self):
        sigma_rest.token_provider_result = lambda: (_ for _ in ()).throw(
            sigma_rest.SigmaAuthError("no browser or client auth")
        )

        result, output = self.sync("SALES")

        self.assertIsNone(result)
        self.assertIn("Sigma auth unavailable — skipping sync", output)
        self.assertEqual([], self.calls)

    def test_sync_source_has_no_inline_sigma_host_or_token_exchange(self):
        source = TARGET.read_text(encoding="utf-8")
        self.assertIn("import sigma_rest", source)
        self.assertIn("sigma_rest.request(", source)
        self.assertNotIn("aws-api.sigmacomputing.com", source)
        self.assertNotIn('"grant_type": "client_credentials"', source)
        self.assertNotIn('os.environ.get("SIGMA_CLIENT_SECRET")', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
