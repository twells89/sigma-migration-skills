#!/usr/bin/env python3
"""Creds-free tests for ThoughtSpot's real Sigma transport path."""

import importlib.util
import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


migrate = load_module("migrate_thoughtspot_auth_target", HERE / "migrate.py")
get_token = load_module("thoughtspot_get_token_auth_target", HERE / "get_token.py")


class MigrateThoughtSpotSigmaAuthTest(unittest.TestCase):
    BASE = "https://api.sigmacomputing.com"
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
        self.original_neutral_env = migrate.sigma_rest.NEUTRAL_ENV
        migrate.sigma_rest.NEUTRAL_ENV = "/nonexistent/thoughtspot-auth-test-env"
        self.reset_client()
        self.calls = []
        self.queue = []

    def tearDown(self):
        migrate.sigma_rest.NEUTRAL_ENV = self.original_neutral_env
        self.reset_client()
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def reset_client():
        migrate.sigma_rest._token_override = None
        migrate.sigma_rest._minted_at = None
        migrate.sigma_rest._refresh_inflight = False
        migrate.sigma_rest._validated_bases.clear()

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
        return migrate.sigma_rest._Resp(status, response_body)

    @staticmethod
    def exports(result):
        return {
            "SIGMA_API_TOKEN": result.token,
            "SIGMA_TOKEN_MINTED_AT": result.minted_at,
            "SIGMA_AUTH_METHOD": result.auth_method,
        }

    def test_valid_bearer_is_reused_and_raw_json_contract_is_preserved(self):
        self.queue = [(200, {"userId": "caller"})]
        env = {"SIGMA_BASE_URL": self.BASE, "SIGMA_API_TOKEN": "caller-token"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            migrate.sigma_rest, "_send", side_effect=self.send
        ), mock.patch.object(
            migrate.sigma_rest, "token_provider_result"
        ) as provider:
            raw = migrate.sigma("GET", "/v2/whoami")

        self.assertEqual({"userId": "caller"}, json.loads(raw))
        self.assertEqual("Bearer caller-token", self.calls[0]["headers"]["Authorization"])
        provider.assert_not_called()

    def test_raw_csv_download_is_not_json_parsed_or_reformatted(self):
        csv_body = 'Region,"Revenue"\r\nWest,"1,234.50"\r\n'
        self.queue = [(200, csv_body)]
        env = {"SIGMA_BASE_URL": self.BASE, "SIGMA_API_TOKEN": "caller-token"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            migrate.sigma_rest, "_send", side_effect=self.send
        ):
            raw = migrate.sigma("GET", "/v2/query/q/download")

        self.assertEqual(csv_body, raw)

    def test_browser_only_provider_authenticates_without_client_credentials(self):
        self.queue = [(200, {"userId": "browser-user"})]
        browser_result = get_token.TokenResult(
            self.BASE,
            "browser-token",
            migrate.sigma_rest._iso_z(time.time()),
            "browser",
        )

        def provider_exports():
            return self.exports(get_token.mint_token())

        with mock.patch.dict(
            os.environ, {"SIGMA_BASE_URL": self.BASE}, clear=True
        ), mock.patch.object(
            get_token, "_load_neutral_env"
        ), mock.patch.object(
            get_token, "_mint_browser_refresh", return_value=browser_result
        ) as browser, mock.patch.object(
            get_token, "_mint_client_credentials"
        ) as client, mock.patch.object(
            get_token, "_verify_token", side_effect=lambda result: result
        ), mock.patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            side_effect=provider_exports,
        ), mock.patch.object(
            migrate.sigma_rest, "_send", side_effect=self.send
        ):
            result = json.loads(migrate.sigma("GET", "/v2/whoami"))
            auth_method = os.environ.get("SIGMA_AUTH_METHOD")

        self.assertEqual({"userId": "browser-user"}, result)
        self.assertEqual("browser", auth_method)
        self.assertEqual("Bearer browser-token", self.calls[0]["headers"]["Authorization"])
        browser.assert_called_once_with(self.BASE)
        client.assert_not_called()

    def test_client_credentials_are_the_browser_provider_fallback(self):
        self.queue = [(200, {"userId": "service-user"})]
        client_result = get_token.TokenResult(
            self.BASE,
            "client-token",
            migrate.sigma_rest._iso_z(time.time()),
            "client-credentials",
        )
        env = {
            "SIGMA_BASE_URL": self.BASE,
            "SIGMA_CLIENT_ID": "client-id",
            "SIGMA_CLIENT_SECRET": "client-secret",
        }

        def provider_exports():
            return self.exports(get_token.mint_token())

        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            get_token, "_load_neutral_env"
        ), mock.patch.object(
            get_token,
            "_mint_browser_refresh",
            side_effect=get_token.BrowserUnavailable("no keychain session"),
        ) as browser, mock.patch.object(
            get_token, "_mint_client_credentials", return_value=client_result
        ) as client, mock.patch.object(
            get_token, "_verify_token", side_effect=lambda result: result
        ), mock.patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            side_effect=provider_exports,
        ), mock.patch.object(
            migrate.sigma_rest, "_send", side_effect=self.send
        ):
            result = json.loads(migrate.sigma("GET", "/v2/whoami"))

        self.assertEqual({"userId": "service-user"}, result)
        self.assertEqual("Bearer client-token", self.calls[0]["headers"]["Authorization"])
        browser.assert_called_once_with(self.BASE)
        client.assert_called_once_with(self.BASE, "client-id", "client-secret")

    def test_known_stale_bearer_refreshes_before_the_request(self):
        self.queue = [(200, {"ok": True})]
        stale_at = migrate.sigma_rest._iso_z(
            time.time() - migrate.sigma_rest.TOKEN_TTL_SECONDS - 60
        )
        provider_result = {
            "SIGMA_API_TOKEN": "proactive-token",
            "SIGMA_TOKEN_MINTED_AT": migrate.sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }
        env = {
            "SIGMA_BASE_URL": self.BASE,
            "SIGMA_API_TOKEN": "stale-token",
            "SIGMA_TOKEN_MINTED_AT": stale_at,
        }
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            return_value=provider_result,
        ) as provider, mock.patch.object(
            migrate.sigma_rest, "_send", side_effect=self.send
        ):
            result = json.loads(migrate.sigma("GET", "/v2/test"))

        self.assertEqual({"ok": True}, result)
        self.assertEqual("Bearer proactive-token", self.calls[0]["headers"]["Authorization"])
        provider.assert_called_once()

    def test_401_refreshes_once_and_retries_with_browser_token(self):
        self.queue = [(401, "expired"), (200, {"ok": True})]
        provider_result = {
            "SIGMA_API_TOKEN": "retry-token",
            "SIGMA_TOKEN_MINTED_AT": migrate.sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }
        env = {"SIGMA_BASE_URL": self.BASE, "SIGMA_API_TOKEN": "expired-token"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            return_value=provider_result,
        ) as provider, mock.patch.object(
            migrate.sigma_rest, "_send", side_effect=self.send
        ):
            result = json.loads(migrate.sigma("GET", "/v2/test"))

        self.assertEqual({"ok": True}, result)
        self.assertEqual(
            ["Bearer expired-token", "Bearer retry-token"],
            [call["headers"]["Authorization"] for call in self.calls],
        )
        provider.assert_called_once()

    def test_second_401_fails_without_a_second_refresh_or_third_request(self):
        self.queue = [(401, "expired"), (401, "still unauthorized")]
        provider_result = {
            "SIGMA_API_TOKEN": "retry-token",
            "SIGMA_TOKEN_MINTED_AT": migrate.sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }
        env = {"SIGMA_BASE_URL": self.BASE, "SIGMA_API_TOKEN": "expired-token"}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            migrate.sigma_rest,
            "token_provider_result",
            return_value=provider_result,
        ) as provider, mock.patch.object(
            migrate.sigma_rest, "_send", side_effect=self.send
        ):
            with self.assertRaisesRegex(RuntimeError, "401"):
                migrate.sigma("GET", "/v2/test")

        self.assertEqual(2, len(self.calls))
        provider.assert_called_once()

    def test_auth_bootstrap_is_lazy_for_offline_and_dry_run_paths(self):
        with tempfile.TemporaryDirectory() as workdir, mock.patch.dict(
            os.environ, {}, clear=True
        ), mock.patch.object(
            migrate.sigma_rest, "token_provider_result"
        ) as provider:
            migrate.ensure_sigma_env(workdir)
            self.assertEqual(workdir, os.environ["SIGMA_WORKDIR"])

        provider.assert_not_called()

    def test_sigma_live_paths_do_not_read_a_static_token(self):
        for name in (
            "migrate.py",
            "scout-validate.py",
            "apply_sigma_rls.py",
            "apply_layouts.py",
            "compare.py",
        ):
            source = (HERE / name).read_text(encoding="utf-8")
            with self.subTest(script=name):
                self.assertIn("import sigma_rest", source)
                self.assertIn("sigma_rest.request(", source)
                self.assertNotIn('os.environ["SIGMA_API_TOKEN"]', source)

        orchestrator = (HERE / "migrate-thoughtspot.py").read_text(encoding="utf-8")
        self.assertIn("migrate.ensure_sigma_env(workdir)", orchestrator)
        self.assertNotIn('("SIGMA_BASE_URL", "SIGMA_API_TOKEN")', orchestrator)


if __name__ == "__main__":
    unittest.main(verbosity=2)
