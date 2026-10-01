#!/usr/bin/env python3
"""A2 on the workbook builder's own REST helpers (api_post / api_put).

build-sigma-workbook.py talks to Sigma directly instead of through
lib/sigma_rest.request, so it must enforce the same rules itself: the bearer
token only goes to a validated https://*.sigmacomputing.com base, the path must
be a relative API path, and the transport can never open a file:// URL — even
under SIGMA_ALLOW_INSECURE_BASE_URL=1, which relaxes only the host check.

Creds-free and network-free: urllib.request.urlopen is replaced with a recorder,
so a request that slips past validation is caught without leaving the process.
"""
import importlib.util
import os
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
BUILDER = SKILL / "scripts" / "build-sigma-workbook.py"
ENV_KEYS = ("SIGMA_BASE_URL", "SIGMA_API_TOKEN", "SIGMA_ALLOW_INSECURE_BASE_URL")


def load_builder():
    spec = importlib.util.spec_from_file_location("qlik_build_sigma_workbook", BUILDER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BuilderUrlSafety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.builder = load_builder()

    def setUp(self):
        self._saved_env = {k: os.environ.get(k) for k in ENV_KEYS}
        for key in ENV_KEYS:
            os.environ.pop(key, None)
        os.environ["SIGMA_API_TOKEN"] = "pre-minted"
        sigma_rest = sys.modules.get("sigma_rest")
        if sigma_rest is not None:
            sigma_rest._validated_bases.clear()
        self.opened = []
        self._real_urlopen = urllib.request.urlopen
        urllib.request.urlopen = self._record_urlopen

    def tearDown(self):
        urllib.request.urlopen = self._real_urlopen
        for key, value in self._saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _record_urlopen(self, request, *args, **kwargs):
        self.opened.append(getattr(request, "full_url", request))
        raise AssertionError("urllib.request.urlopen must not be called directly")

    def test_put_refuses_non_sigma_host(self):
        os.environ["SIGMA_BASE_URL"] = "https://evil.example"
        with self.assertRaises(SystemExit):
            self.builder.api_put("/v2/workbooks/wb-1", {"document": {}})
        self.assertEqual(self.opened, [])

    def test_post_refuses_non_sigma_host(self):
        os.environ["SIGMA_BASE_URL"] = "https://evil.example"
        with self.assertRaises(SystemExit):
            self.builder.api_post("/v2/workbooks", {"document": {}})
        self.assertEqual(self.opened, [])

    def test_put_refuses_absolute_path(self):
        os.environ["SIGMA_BASE_URL"] = "https://aws-api.sigmacomputing.com"
        with self.assertRaises(ValueError):
            self.builder.api_put("https://evil.example/v2/workbooks/wb-1", {})
        self.assertEqual(self.opened, [])

    def test_sigma_host_goes_through_the_safe_opener(self):
        os.environ["SIGMA_BASE_URL"] = "https://aws-api.sigmacomputing.com/"
        sigma_rest = self.builder._sigma_api()
        sent = []

        class FakeResponse:
            def read(self):
                return b'{"workbookId": "wb-1"}'

        class FakeOpener:
            def open(self, request):
                sent.append((request.get_method(), request.full_url,
                             request.get_header("Authorization")))
                return FakeResponse()

        real_opener = sigma_rest._http_opener
        sigma_rest._http_opener = FakeOpener
        self.addCleanup(setattr, sigma_rest, "_http_opener", real_opener)
        out = self.builder.api_put("/v2/workbooks/wb-1", {"document": {}})
        self.assertEqual(out, '{"workbookId": "wb-1"}')
        self.assertEqual(sent, [("PUT", "https://aws-api.sigmacomputing.com/v2/workbooks/wb-1",
                                 "Bearer pre-minted")])
        self.assertEqual(self.opened, [])

    def test_file_url_never_read_even_with_override(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write("SECRET-FILE-CONTENTS")
            secret = handle.name
        self.addCleanup(os.unlink, secret)
        os.environ["SIGMA_ALLOW_INSECURE_BASE_URL"] = "1"
        os.environ["SIGMA_BASE_URL"] = "file://" + secret + "#"
        with self.assertRaises((SystemExit, OSError, ValueError)) as caught:
            self.builder.api_put("/v2/workbooks/wb-1", {})
        self.assertNotIn("SECRET-FILE-CONTENTS", str(caught.exception))
        self.assertEqual(self.opened, [])


if __name__ == "__main__":
    unittest.main()
