#!/usr/bin/env python3
"""Credential-free auth/retry tests for sigma-export-png.py."""

import importlib.util
import pathlib
import sys
import tempfile
import types
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("sigma-export-png.py")
SPEC = importlib.util.spec_from_file_location("sigma_export_png", SCRIPT)
export_png = importlib.util.module_from_spec(SPEC)
requests_stub = types.ModuleType("requests")
requests_stub.post = None
requests_stub.get = None
requests_stub.exceptions = types.SimpleNamespace(Timeout=type("Timeout", (Exception,), {}))
with mock.patch.dict(sys.modules, {"requests": requests_stub}):
    SPEC.loader.exec_module(export_png)
PNG = b"\x89PNG\r\n\x1a\nrendered"


class Response:
    def __init__(self, status, body=b"", text="", payload=None, content_type=""):
        self.status_code = status
        self.content = body
        self.text = text
        self._payload = payload or {}
        self.headers = {"Content-Type": content_type}

    def json(self):
        return self._payload


class SigmaExportPngAuthTest(unittest.TestCase):
    def argv(self, out):
        return [
            "sigma-export-png.py",
            "--workbook",
            "wb-1",
            "--page",
            "page-1",
            "--out",
            str(out),
        ]

    def test_fresh_provider_token_and_one_401_retry_for_post_and_poll(self):
        post_responses = [
            Response(401, text="expired"),
            Response(200, payload={"queryId": "q-1"}),
        ]
        get_responses = [
            Response(401, text="expired"),
            Response(200, body=PNG, content_type="image/png"),
        ]
        post_auth = []
        get_auth = []

        def fake_post(url, headers, json, timeout):
            post_auth.append(headers["Authorization"])
            return post_responses.pop(0)

        def fake_get(url, headers, timeout):
            get_auth.append(headers["Authorization"])
            return get_responses.pop(0)

        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp, "render.png")
            with mock.patch.object(
                export_png.sigma_rest, "base_url", return_value="https://sigma.example/"
            ), mock.patch.object(
                export_png.sigma_rest, "auth_token", return_value="initial-browser"
            ), mock.patch.object(
                export_png.sigma_rest,
                "refresh_token",
                side_effect=["post-browser", "poll-browser"],
            ) as refresh, mock.patch.object(
                export_png.requests, "post", side_effect=fake_post
            ), mock.patch.object(
                export_png.requests, "get", side_effect=fake_get
            ), mock.patch.object(
                export_png.sys, "argv", self.argv(out)
            ):
                export_png.main()

            self.assertEqual(PNG, out.read_bytes())

        self.assertEqual(
            ["Bearer initial-browser", "Bearer post-browser"], post_auth
        )
        self.assertEqual(["Bearer post-browser", "Bearer poll-browser"], get_auth)
        self.assertEqual(2, refresh.call_count)

    def test_poll_timeout_still_retries(self):
        get_responses = [
            export_png.requests.exceptions.Timeout(),
            Response(200, body=PNG, content_type="image/png"),
        ]

        def fake_get(url, headers, timeout):
            response = get_responses.pop(0)
            if isinstance(response, Exception):
                raise response
            return response

        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp, "render.png")
            with mock.patch.object(
                export_png.sigma_rest, "base_url", return_value="https://sigma.example"
            ), mock.patch.object(
                export_png.sigma_rest, "auth_token", return_value="caller-token"
            ), mock.patch.object(
                export_png.sigma_rest, "refresh_token", return_value="browser-token"
            ), mock.patch.object(
                export_png.requests,
                "post",
                return_value=Response(200, payload={"queryId": "q-1"}),
            ), mock.patch.object(
                export_png.requests, "get", side_effect=fake_get
            ), mock.patch.object(
                export_png.time, "sleep"
            ) as sleep, mock.patch.object(
                export_png.sys, "argv", self.argv(out)
            ):
                export_png.main()

            self.assertEqual(PNG, out.read_bytes())
            sleep.assert_called_once_with(3)

    def test_five_poll_500s_keep_existing_hard_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp, "render.png")
            with mock.patch.object(
                export_png.sigma_rest, "base_url", return_value="https://sigma.example"
            ), mock.patch.object(
                export_png.sigma_rest, "auth_token", return_value="caller-token"
            ), mock.patch.object(
                export_png.sigma_rest, "refresh_token", return_value="browser-token"
            ), mock.patch.object(
                export_png.requests,
                "post",
                return_value=Response(200, payload={"queryId": "q-1"}),
            ), mock.patch.object(
                export_png.requests, "get", return_value=Response(500)
            ) as get, mock.patch.object(
                export_png.time, "sleep"
            ), mock.patch.object(
                export_png.sys, "argv", self.argv(out)
            ):
                with self.assertRaisesRegex(SystemExit, "HTTP 500 x5"):
                    export_png.main()

            self.assertEqual(5, get.call_count)


if __name__ == "__main__":
    unittest.main(verbosity=2)
