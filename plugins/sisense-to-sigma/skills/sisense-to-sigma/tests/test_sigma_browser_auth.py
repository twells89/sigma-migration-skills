#!/usr/bin/env python3
"""Creds-free browser OAuth contracts for Sisense Sigma transports."""

import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent / "scripts"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


post_spec = load("post_sisense_spec_auth_test", "post-sisense-spec.py")
verify_parity = load("verify_sisense_parity_auth_test", "verify_parity.py")
migrate = load("migrate_sisense_auth_test", "migrate-sisense.py")
sigma_rest = post_spec.sigma_rest


class SigmaBrowserAuthTest(unittest.TestCase):
    ENV_KEYS = (
        "SIGMA_BASE_URL",
        "SIGMA_API_TOKEN",
        "SIGMA_TOKEN_MINTED_AT",
        "SIGMA_AUTH_METHOD",
        "SIGMA_CLIENT_ID",
        "SIGMA_CLIENT_SECRET",
        "SIGMA_ALLOW_INSECURE_BASE_URL",
        "SIGMA_WORKDIR",
    )

    def setUp(self):
        self.saved_env = {key: os.environ.get(key) for key in self.ENV_KEYS}
        self.original_send = sigma_rest._send
        self.original_provider = sigma_rest.token_provider_result
        self.reset_auth()
        for key in self.ENV_KEYS:
            os.environ.pop(key, None)
        os.environ["SIGMA_BASE_URL"] = "https://api.sigmacomputing.com"
        self.calls = []
        self.provider_calls = 0

    def tearDown(self):
        sigma_rest._send = self.original_send
        sigma_rest.token_provider_result = self.original_provider
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

    def provider(self, token="browser-token"):
        self.provider_calls += 1
        return {
            "SIGMA_API_TOKEN": token,
            "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }

    def send_queue(self, responses):
        queue = list(responses)

        def fake_send(method, url, headers, body, timeout):
            self.calls.append(
                {
                    "method": method,
                    "url": url,
                    "headers": dict(headers),
                    "body": body,
                    "timeout": timeout,
                }
            )
            status, payload = queue.pop(0)
            return sigma_rest._Resp(status, payload)

        sigma_rest._send = fake_send

    def test_post_client_supports_browser_only_auth_and_preserves_yaml(self):
        sigma_rest.token_provider_result = self.provider
        self.send_queue([(200, b"dataModelId: dm-browser\n")])

        result = post_spec.Client(None, None).request(
            "POST", "/v2/dataModels/spec", {"name": "DM"}
        )

        self.assertEqual({"dataModelId": "dm-browser"}, result)
        self.assertEqual(1, self.provider_calls)
        self.assertNotIn("SIGMA_CLIENT_ID", os.environ)
        self.assertEqual(
            "Bearer browser-token",
            self.calls[0]["headers"]["Authorization"],
        )
        self.assertEqual('{"name": "DM"}', self.calls[0]["body"])

    def test_post_client_reuses_valid_token_without_provider(self):
        os.environ["SIGMA_API_TOKEN"] = "valid-token"
        sigma_rest.token_provider_result = lambda: self.fail(
            "valid token must not invoke the provider"
        )
        self.send_queue([(200, json.dumps({"workbookId": "wb-valid"}))])

        result = post_spec.Client(None, None).request(
            "POST", "/v2/workbooks/spec", {"name": "WB"}
        )

        self.assertEqual({"workbookId": "wb-valid"}, result)
        self.assertEqual(
            "Bearer valid-token",
            self.calls[0]["headers"]["Authorization"],
        )

    def test_post_client_refreshes_once_on_401_without_client_credentials(self):
        os.environ["SIGMA_API_TOKEN"] = "expired-token"
        sigma_rest.token_provider_result = self.provider
        self.send_queue(
            [(401, b"expired"), (200, b'{"dataModelId":"dm-fresh"}')]
        )

        result = post_spec.Client(None, None).request(
            "POST", "/v2/dataModels/spec", {"name": "DM"}
        )

        self.assertEqual({"dataModelId": "dm-fresh"}, result)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(2, len(self.calls))
        self.assertNotIn("SIGMA_CLIENT_ID", os.environ)

    def test_parity_transport_supports_browser_only_auth(self):
        sigma_rest.token_provider_result = self.provider
        self.send_queue([(200, b'{"queryId":"query-browser"}')])

        result = verify_parity.SigmaParityTransport().request(
            "POST", "/v2/workbooks/wb/export", {"elementId": "chart"}
        )

        self.assertEqual({"queryId": "query-browser"}, result)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(
            "Bearer browser-token",
            self.calls[0]["headers"]["Authorization"],
        )
        self.assertNotIn("SIGMA_CLIENT_ID", os.environ)

    def test_parity_transport_refreshes_browser_token_once_on_401(self):
        os.environ["SIGMA_API_TOKEN"] = "expired-token"
        sigma_rest.token_provider_result = self.provider
        self.send_queue(
            [
                (401, b"expired"),
                (200, json.dumps({"queryId": "query-browser"})),
            ]
        )

        result = verify_parity.SigmaParityTransport().request(
            "POST", "/v2/workbooks/wb/export", {"elementId": "chart"}
        )

        self.assertEqual({"queryId": "query-browser"}, result)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(2, len(self.calls))
        self.assertEqual(
            ["Bearer expired-token", "Bearer browser-token"],
            [call["headers"]["Authorization"] for call in self.calls],
        )
        self.assertNotIn("SIGMA_CLIENT_ID", os.environ)

    def test_parity_transport_second_401_is_not_retried(self):
        os.environ["SIGMA_API_TOKEN"] = "expired-token"
        sigma_rest.token_provider_result = self.provider
        self.send_queue([(401, b"expired"), (401, b"still unauthorized")])

        with self.assertRaisesRegex(sigma_rest.SigmaError, "401"):
            verify_parity.SigmaParityTransport().request(
                "GET", "/v2/query/query-browser/download", binary=True
            )

        self.assertEqual(1, self.provider_calls)
        self.assertEqual(2, len(self.calls))

    def test_post_client_refreshes_known_old_token_before_send(self):
        os.environ.update(
            {
                "SIGMA_API_TOKEN": "known-old",
                "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(
                    time.time() - sigma_rest.TOKEN_TTL_SECONDS - 1
                ),
            }
        )
        sigma_rest.token_provider_result = self.provider
        self.send_queue([(200, b'{"userId":"fresh"}')])

        result = post_spec.Client(None, None).request("GET", "/v2/whoami")

        self.assertEqual({"userId": "fresh"}, result)
        self.assertEqual(1, self.provider_calls)
        self.assertEqual(
            "Bearer browser-token",
            self.calls[0]["headers"]["Authorization"],
        )

    def test_orchestrator_initialization_accepts_browser_only_auth(self):
        sigma_rest.token_provider_result = self.provider
        with tempfile.TemporaryDirectory() as workdir:
            migrate.load_sigma_env(Path(workdir))

            self.assertEqual("browser-token", os.environ["SIGMA_API_TOKEN"])
            self.assertEqual(str(Path(workdir).resolve()), os.environ["SIGMA_WORKDIR"])
        self.assertEqual(1, self.provider_calls)
        self.assertNotIn("SIGMA_CLIENT_ID", os.environ)

    def test_rls_and_table_scout_have_no_static_sigma_bearer_transport(self):
        for filename in ("apply_sigma_rls.py", "fetch_inodes.py"):
            with self.subTest(script=filename):
                source = (SCRIPTS / filename).read_text(encoding="utf-8")
                self.assertIn("sigma_rest.request(", source)
                self.assertNotIn('os.environ["SIGMA_API_TOKEN"]', source)
                self.assertNotIn('"Authorization": "Bearer "', source)
                self.assertNotIn('["curl"', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
