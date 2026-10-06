#!/usr/bin/env python3
"""Credential-free tests for the canonical Sigma token provider."""

import contextlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import tempfile
import unittest
import urllib.error
from unittest import mock


MODULE_PATH = os.path.join(os.path.dirname(__file__), "get_token.py")
SPEC = importlib.util.spec_from_file_location("sigma_get_token", MODULE_PATH)
get_token = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(get_token)

BASE = "https://api.sigmacomputing.com"
MINTED = "2026-10-05T20:00:00Z"


class JsonResponse(io.BytesIO):
    def __init__(self, payload):
        super().__init__(json.dumps(payload).encode("utf-8"))

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class TokenProviderTest(unittest.TestCase):
    def env(self, **values):
        base = {"SIGMA_BASE_URL": BASE}
        base.update(values)
        return mock.patch.dict(os.environ, base, clear=True)

    def test_auto_prefers_valid_browser_cache_over_client_credentials(self):
        keychain = {
            "refresh-token": "refresh-old",
            "access-token": "cached-token",
            "access-expiry": "2000",
            "access-minted-at": MINTED,
        }
        with self.env(SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token.time, "time", return_value=1000), \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda result: result) as verify, \
             mock.patch.object(get_token, "_mint_client_credentials") as client:
            result = get_token.mint_token()

        self.assertEqual("cached-token", result.token)
        self.assertEqual("browser", result.auth_method)
        self.assertEqual(MINTED, result.minted_at)
        verify.assert_called_once_with(result)
        client.assert_not_called()

    def test_explicit_client_mode_skips_browser(self):
        expected = get_token.TokenResult(BASE, "client-token", MINTED, "client-credentials")
        with self.env(
            SIGMA_AUTH_MODE="browser",
            SIGMA_CLIENT_ID="id",
            SIGMA_CLIENT_SECRET="secret",
        ), mock.patch.object(get_token, "_mint_browser_refresh") as browser, \
             mock.patch.object(get_token, "_mint_client_credentials", return_value=expected), \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda result: result) as verify:
            result = get_token.mint_token("client-credentials")

        self.assertEqual(expected, result)
        verify.assert_called_once_with(expected)
        browser.assert_not_called()

    def test_auto_falls_back_to_client_credentials_without_browser_session(self):
        with self.env(SIGMA_CLIENT_ID="client-id", SIGMA_CLIENT_SECRET="client-secret"), \
             mock.patch.object(get_token, "_keychain_backend", return_value=None), \
             mock.patch.object(
                 get_token.urllib.request,
                 "urlopen",
                 return_value=JsonResponse({"access_token": "client-token"}),
             ) as urlopen, \
             mock.patch.object(get_token, "_verify_token", side_effect=lambda result: result), \
             mock.patch.object(get_token.time, "time", return_value=1000):
            result = get_token.mint_token()

        self.assertEqual("client-token", result.token)
        self.assertEqual("client-credentials", result.auth_method)
        request = urlopen.call_args.args[0]
        self.assertEqual(f"{BASE}/v2/auth/token", request.full_url)
        self.assertTrue(request.headers["Authorization"].startswith("Basic "))

    def test_auto_falls_back_when_browser_refresh_returns_no_access_token(self):
        keychain = {
            "refresh-token": "refresh-old",
            "access-expiry": "0",
            "client-id": "browser-client",
            "token-url": "https://auth.sigmacomputing.com/oauth/token",
        }
        responses = [
            JsonResponse({"error": "invalid_grant"}),
            JsonResponse({"access_token": "fallback-client-token"}),
        ]
        with self.env(SIGMA_CLIENT_ID="client-id", SIGMA_CLIENT_SECRET="client-secret"), \
             mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(
                 get_token.urllib.request, "urlopen", side_effect=responses
             ), mock.patch.object(
                 get_token, "_verify_token", side_effect=lambda result: result
             ), contextlib.redirect_stderr(io.StringIO()):
            result = get_token.mint_token()

        self.assertEqual("fallback-client-token", result.token)
        self.assertEqual("client-credentials", result.auth_method)

    def test_whoami_verification_succeeds_with_bearer_header(self):
        result = get_token.TokenResult(BASE, "minted-token", MINTED, "browser")
        opener = mock.Mock()
        opener.open.return_value = JsonResponse(
            {"userId": "user-1", "organizationId": "org-1"}
        )

        with mock.patch.object(
            get_token.urllib.request, "build_opener", return_value=opener
        ) as build_opener:
            verified = get_token._verify_token(result)

        self.assertEqual(result, verified)
        handler = build_opener.call_args.args[0]
        self.assertIsInstance(handler, get_token._RejectRedirects)
        request = opener.open.call_args.args[0]
        self.assertEqual(f"{BASE}/v2/whoami", request.full_url)
        self.assertEqual("GET", request.get_method())
        self.assertEqual("Bearer minted-token", request.headers["Authorization"])

    def test_whoami_verification_rejects_401_and_403_without_leaking_token(self):
        result = get_token.TokenResult(BASE, "secret-bearer", MINTED, "browser")
        for status in (401, 403):
            with self.subTest(status=status):
                opener = mock.Mock()
                opener.open.side_effect = urllib.error.HTTPError(
                    f"{BASE}/v2/whoami", status, "auth failed", {}, None
                )
                with mock.patch.object(
                    get_token.urllib.request, "build_opener", return_value=opener
                ):
                    with self.assertRaisesRegex(
                        get_token.TokenProviderError, str(status)
                    ) as raised:
                        get_token._verify_token(result)
                self.assertNotIn(result.token, str(raised.exception))

    def test_whoami_verification_rejects_non_json_without_leaking_token(self):
        result = get_token.TokenResult(
            BASE, "secret-non-json-bearer", MINTED, "client-credentials"
        )
        opener = mock.Mock()
        opener.open.return_value = io.BytesIO(b"<html>not JSON</html>")

        with mock.patch.object(
            get_token.urllib.request, "build_opener", return_value=opener
        ):
            with self.assertRaisesRegex(
                get_token.TokenProviderError, "not valid JSON"
            ) as raised:
                get_token._verify_token(result)

        self.assertNotIn(result.token, str(raised.exception))

    def test_whoami_verification_refuses_redirect_without_following_it(self):
        result = get_token.TokenResult(
            BASE, "secret-redirect-bearer", MINTED, "client-credentials"
        )
        opener = mock.Mock()
        opener.open.side_effect = urllib.error.HTTPError(
            f"{BASE}/v2/whoami",
            302,
            "Found",
            {"Location": "https://attacker.example/collect"},
            None,
        )

        with mock.patch.object(
            get_token.urllib.request, "build_opener", return_value=opener
        ) as build_opener:
            with self.assertRaisesRegex(
                get_token.TokenProviderError, "refused HTTP 302 redirect"
            ) as raised:
                get_token._verify_token(result)

        self.assertIsInstance(
            build_opener.call_args.args[0], get_token._RejectRedirects
        )
        opener.open.assert_called_once()
        self.assertNotIn(result.token, str(raised.exception))

    def test_browser_refresh_caches_metadata_and_rotates_refresh_token(self):
        keychain = {
            "refresh-token": "refresh-old",
            "access-token": "expired-token",
            "access-expiry": "999",
            "client-id": "browser-client",
            "token-url": "https://auth.sigmacomputing.com/oauth/token",
        }
        writes = []

        def set_value(_backend, key, value):
            writes.append((key, value))
            keychain[key] = value
            return True

        payload = {
            "access_token": "fresh-browser-token",
            "refresh_token": "refresh-new",
            "expires_in": 3600,
        }
        with mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token, "_kc_set", side_effect=set_value), \
             mock.patch.object(
                 get_token.urllib.request, "urlopen", return_value=JsonResponse(payload)
             ) as urlopen:
            result = get_token._mint_browser_refresh(BASE, now=1000)

        self.assertEqual("fresh-browser-token", result.token)
        self.assertEqual("browser", result.auth_method)
        self.assertEqual("1970-01-01T00:16:40Z", result.minted_at)
        self.assertEqual(("refresh-token", "refresh-new"), writes[0])
        self.assertEqual(
            ["access-token", "access-minted-at", "access-expiry"],
            [name for name, _value in writes[1:]],
        )
        self.assertEqual("4540", keychain["access-expiry"])
        body = urlopen.call_args.args[0].data.decode("utf-8")
        self.assertIn("grant_type=refresh_token", body)
        self.assertIn("refresh_token=refresh-old", body)

    def test_browser_cache_avoids_network(self):
        keychain = {
            "refresh-token": "refresh",
            "access-token": "cached",
            "access-expiry": "2000",
            "access-minted-at": MINTED,
        }
        with mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token.urllib.request, "urlopen") as urlopen:
            result = get_token._mint_browser_refresh(BASE, now=1000)

        self.assertEqual("cached", result.token)
        urlopen.assert_not_called()

    def test_rotated_refresh_token_must_be_persisted(self):
        keychain = {
            "refresh-token": "refresh-old",
            "access-expiry": "0",
            "client-id": "browser-client",
            "token-url": "https://auth.sigmacomputing.com/oauth/token",
        }
        payload = {
            "access_token": "fresh-token",
            "refresh_token": "refresh-new",
        }
        with mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token, "_kc_set", return_value=False), \
             mock.patch.object(
                 get_token.urllib.request, "urlopen", return_value=JsonResponse(payload)
             ):
            with self.assertRaisesRegex(
                get_token.BrowserUnavailable, "replacement could not be stored"
            ):
                get_token._mint_browser_refresh(BASE, now=1000)

    def test_unsafe_base_url_is_rejected_before_auth_resolution(self):
        with self.env(SIGMA_BASE_URL="https://api.sigmacomputing.com.evil.test"), \
             mock.patch.object(get_token, "_keychain_backend") as backend:
            with self.assertRaisesRegex(get_token.SecurityError, "non-Sigma host"):
                get_token.mint_token()
        backend.assert_not_called()

    def test_unknown_sigma_subdomain_is_not_accepted_as_an_api_base(self):
        with self.env(SIGMA_BASE_URL="https://unpublished.sigmacomputing.com"):
            with self.assertRaisesRegex(get_token.SecurityError, "not a published"):
                get_token.mint_token()

    def test_unsafe_stored_token_url_is_rejected_without_client_fallback(self):
        keychain = {
            "refresh-token": "refresh",
            "access-expiry": "0",
            "client-id": "browser-client",
            "token-url": "https://evil.test/oauth/token",
        }
        with self.env(SIGMA_CLIENT_ID="id", SIGMA_CLIENT_SECRET="secret"), \
             mock.patch.object(get_token, "_keychain_backend", return_value="libsecret"), \
             mock.patch.object(get_token, "_kc_get", side_effect=lambda _b, key: keychain.get(key, "")), \
             mock.patch.object(get_token, "_mint_client_credentials") as client:
            with self.assertRaisesRegex(get_token.SecurityError, "non-Sigma host"):
                get_token.mint_token()
        client.assert_not_called()

    def test_invalid_access_token_alphabet_is_rejected(self):
        with self.assertRaisesRegex(get_token.SecurityError, "unexpected characters"):
            get_token._validate_access_token("token;echo-pwned")

    def test_auth_json_is_backward_compatible_private_and_has_metadata(self):
        result = get_token.TokenResult(BASE, "access-token", MINTED, "browser")
        with tempfile.TemporaryDirectory() as workdir:
            path = get_token._write_auth_json(workdir, result)
            with open(path, encoding="utf-8") as handle:
                payload = json.load(handle)

            self.assertEqual("access-token", payload["SIGMA_API_TOKEN"])
            self.assertEqual(BASE, payload["SIGMA_BASE_URL"])
            self.assertEqual(MINTED, payload["SIGMA_TOKEN_MINTED_AT"])
            self.assertEqual("browser", payload["SIGMA_AUTH_METHOD"])
            self.assertNotIn("refresh_token", payload)
            if os.name != "nt":
                self.assertEqual(0o600, stat.S_IMODE(os.stat(path).st_mode))

    def test_existing_caller_token_is_not_treated_as_a_refresh_credential(self):
        with self.env(SIGMA_API_TOKEN="caller-token"), \
             mock.patch.object(get_token, "_keychain_backend", return_value=None):
            with self.assertRaisesRegex(
                get_token.TokenProviderError, "no Sigma authentication"
            ):
                get_token.mint_token()

    def test_neutral_env_supplies_missing_migration_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "env")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    "export SIGMA_BASE_URL='https://api.sigmacomputing.com'\n"
                    "export SIGMA_CLIENT_ID='neutral-id'\n"
                    "export SIGMA_CLIENT_SECRET='neutral secret'\n"
                    "export SIGMA_API_TOKEN='must-not-be-loaded'\n"
                )
            with mock.patch.dict(os.environ, {}, clear=True):
                get_token._load_neutral_env(path)
                self.assertEqual(BASE, os.environ["SIGMA_BASE_URL"])
                self.assertEqual("neutral-id", os.environ["SIGMA_CLIENT_ID"])
                self.assertEqual("neutral secret", os.environ["SIGMA_CLIENT_SECRET"])
                self.assertNotIn("SIGMA_API_TOKEN", os.environ)

    def test_explicit_environment_wins_over_neutral_env(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "env")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("export SIGMA_CLIENT_ID='from-file'\n")
            with mock.patch.dict(
                os.environ, {"SIGMA_CLIENT_ID": "from-environment"}, clear=True
            ):
                get_token._load_neutral_env(path)
                self.assertEqual("from-environment", os.environ["SIGMA_CLIENT_ID"])

    def test_platform_selects_only_native_keychain_backend(self):
        def which(command):
            return f"/fake/{command}"

        with mock.patch.object(get_token.shutil, "which", side_effect=which):
            self.assertEqual("macos", get_token._keychain_backend("darwin"))
            self.assertEqual("libsecret", get_token._keychain_backend("linux"))
            self.assertIsNone(get_token._keychain_backend("win32"))

    def test_python_free_shell_fallback_emits_metadata_and_validates_token(self):
        script = os.path.join(os.path.dirname(__file__), "get-token.sh")
        with tempfile.TemporaryDirectory() as bindir:
            tools = {
                "dirname": '#!/bin/sh\n/usr/bin/dirname "$@"\n',
                "base64": "#!/bin/sh\n/bin/cat >/dev/null\nprintf Y3JlZHM=\n",
                "tr": "#!/bin/sh\n/bin/cat\n",
                "curl": '#!/bin/sh\nprintf \'{"access_token":"shell-token"}\\n\'\n',
                "jq": "#!/bin/sh\n/bin/cat >/dev/null\nprintf shell-token\\n\n",
                "date": "#!/bin/sh\nprintf 2026-10-05T20:00:00Z\\n\n",
            }
            for name, contents in tools.items():
                path = os.path.join(bindir, name)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(contents)
                os.chmod(path, 0o755)

            env = {
                "PATH": bindir,
                "SIGMA_BASE_URL": BASE,
                "SIGMA_CLIENT_ID": "id",
                "SIGMA_CLIENT_SECRET": "secret",
                "SIGMA_AUTH_MODE": "auto",
            }
            proc = subprocess.run(
                ["/bin/bash", script],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("export SIGMA_API_TOKEN=shell-token", proc.stdout)
        self.assertIn("export SIGMA_TOKEN_MINTED_AT=2026-10-05T20:00:00Z", proc.stdout)
        self.assertIn("export SIGMA_AUTH_METHOD=client-credentials", proc.stdout)

    def test_browser_shell_helpers_emit_mint_metadata(self):
        scripts = ("browser-login.sh", "refresh-token.sh")
        for name in scripts:
            with self.subTest(name=name):
                path = os.path.join(os.path.dirname(__file__), name)
                with open(path, encoding="utf-8") as handle:
                    source = handle.read()
                self.assertIn("export SIGMA_TOKEN_MINTED_AT=", source)
                self.assertIn("export SIGMA_AUTH_METHOD=", source)
                self.assertIn("^[A-Za-z0-9._~+/=-]+$", source)


if __name__ == "__main__":
    unittest.main()
