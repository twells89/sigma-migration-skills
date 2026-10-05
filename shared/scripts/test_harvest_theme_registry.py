#!/usr/bin/env python3
"""Credential-free auth/retry tests for harvest-theme-registry.py."""

import importlib.util
import io
import json
import os
import pathlib
import unittest
import urllib.error
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("harvest-theme-registry.py")
SPEC = importlib.util.spec_from_file_location("harvest_theme_registry", SCRIPT)
harvest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harvest)


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class HarvestThemeRegistryAuthTest(unittest.TestCase):
    def test_get_token_uses_shared_dual_mode_provider(self):
        env = {"SIGMA_BASE_URL": "https://api.us-a.aws.sigmacomputing.com"}
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            harvest.sigma_rest, "refresh_token", return_value="browser-token"
        ) as refresh:
            self.assertEqual("browser-token", harvest.get_token(env))
            refresh.assert_called_once_with()
            self.assertEqual(env["SIGMA_BASE_URL"], os.environ["SIGMA_BASE_URL"])

    def test_api_refreshes_once_on_401_and_preserves_429_retry(self):
        tokens = ["expired-token"]
        seen_auth = []
        sleeps = []
        responses = [
            urllib.error.HTTPError("https://sigma/x", 401, "unauthorized", {}, None),
            urllib.error.HTTPError(
                "https://sigma/x", 429, "rate limited", {"Retry-After": "0"}, None
            ),
            FakeResponse(json.dumps({"ok": True}).encode("utf-8")),
        ]

        def fake_urlopen(req, timeout):
            seen_auth.append(req.get_header("Authorization"))
            response = responses.pop(0)
            if isinstance(response, Exception):
                raise response
            return response

        def fake_refresh():
            tokens.append("fresh-browser-token")
            return tokens[-1]

        with mock.patch.object(
            harvest.sigma_rest, "auth_token", side_effect=lambda: tokens[-1]
        ), mock.patch.object(
            harvest.sigma_rest, "refresh_token", side_effect=fake_refresh
        ) as refresh, mock.patch.object(
            harvest.urllib.request, "urlopen", side_effect=fake_urlopen
        ), mock.patch.object(
            harvest.time, "sleep", side_effect=lambda seconds: sleeps.append(seconds)
        ):
            result = harvest.api("https://sigma", "/x")

        self.assertEqual({"ok": True}, result)
        self.assertEqual(
            [
                "Bearer expired-token",
                "Bearer fresh-browser-token",
                "Bearer fresh-browser-token",
            ],
            seen_auth,
        )
        refresh.assert_called_once_with()
        self.assertEqual([0.0], sleeps)

    def test_inline_client_credentials_flow_is_absent(self):
        self.assertNotIn("client_credentials", SCRIPT.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
