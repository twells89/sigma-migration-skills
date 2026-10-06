#!/usr/bin/env python3
"""Credential-free dual-mode auth tests for sigma_rest.py."""

import json
import os
import tempfile
import unittest
from unittest import mock

import sigma_rest


BASE = "https://api.sigmacomputing.com"
PROVIDER = {
    "SIGMA_API_TOKEN": "browser-refreshed-token",
    "SIGMA_TOKEN_MINTED_AT": "2026-10-05T20:00:00Z",
    "SIGMA_AUTH_METHOD": "browser",
}


class SigmaRestDualAuthTest(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(
            os.environ,
            {"SIGMA_BASE_URL": BASE, "SIGMA_API_TOKEN": "caller-token"},
            clear=True,
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        sigma_rest._token_override = None
        sigma_rest._minted_at = None
        sigma_rest._refresh_inflight = False
        sigma_rest._validated_bases.clear()

    def test_unknown_age_caller_token_waits_for_401_then_refreshes_without_client_id(self):
        responses = [
            sigma_rest._Resp(401, "unauthorized"),
            sigma_rest._Resp(200, '{"ok":true}'),
        ]
        authorizations = []

        def send(_method, _url, headers, _body, _timeout):
            authorizations.append(headers["Authorization"])
            return responses.pop(0)

        with mock.patch.object(sigma_rest, "_send", side_effect=send), mock.patch.object(
            sigma_rest, "token_provider_result", return_value=PROVIDER
        ):
            result = sigma_rest.request("get", "/v2/whoami")

        self.assertEqual({"ok": True}, result)
        self.assertEqual(
            ["Bearer caller-token", "Bearer browser-refreshed-token"],
            authorizations,
        )
        self.assertEqual("browser", os.environ["SIGMA_AUTH_METHOD"])

    def test_known_stale_token_refreshes_proactively_without_client_id(self):
        os.environ["SIGMA_TOKEN_MINTED_AT"] = "2000-01-01T00:00:00Z"
        with mock.patch.object(
            sigma_rest, "token_provider_result", return_value=PROVIDER
        ):
            self.assertEqual("browser-refreshed-token", sigma_rest.auth_token())

    def test_second_401_is_not_retried(self):
        responses = [
            sigma_rest._Resp(401, "unauthorized"),
            sigma_rest._Resp(401, "still unauthorized"),
        ]
        with mock.patch.object(
            sigma_rest, "_send", side_effect=lambda *_args: responses.pop(0)
        ), mock.patch.object(
            sigma_rest, "token_provider_result", return_value=PROVIDER
        ):
            with self.assertRaises(sigma_rest.SigmaError):
                sigma_rest.request("get", "/v2/whoami")
        self.assertEqual([], responses)

    def test_auth_json_prefers_provider_metadata_over_file_mtime(self):
        with tempfile.TemporaryDirectory() as workdir:
            with open(os.path.join(workdir, "auth.json"), "w", encoding="utf-8") as handle:
                json.dump(
                    {
                        "SIGMA_API_TOKEN": "file-token",
                        "SIGMA_BASE_URL": BASE,
                        "SIGMA_TOKEN_MINTED_AT": "2026-10-05T20:00:00Z",
                        "SIGMA_AUTH_METHOD": "browser",
                    },
                    handle,
                )
            os.environ.pop("SIGMA_API_TOKEN")
            sigma_rest._load_auth_json(cwd=workdir)

        self.assertEqual("2026-10-05T20:00:00Z", os.environ["SIGMA_TOKEN_MINTED_AT"])
        self.assertEqual("browser", os.environ["SIGMA_AUTH_METHOD"])


if __name__ == "__main__":
    unittest.main()
