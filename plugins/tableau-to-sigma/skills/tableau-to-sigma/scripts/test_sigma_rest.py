#!/usr/bin/env python3
"""Contract/spec test for sigma_rest.py (P1 Ruby->Python port).

Creds-free, network-free: the HTTP layer (sigma_rest._send) is monkeypatched.
Encodes the observable behaviour of sigma_rest.rb — credential-bootstrap
precedence, auth.json + BOM handling, the token-exchange request shape, and the
401 refresh-once-then-retry loop — so the twin can't silently drift.
"""
import json
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
# sigma_rest.py lives in scripts/lib/ once fanned out; fall back to shared/lib
# for local dev before sync. (Mirrors report-telemetry.py's dual-path import.)
for _cand in (
    os.path.join(_HERE, "lib"),
    os.path.abspath(os.path.join(_HERE, "..", "..", "..", "..", "..", "shared", "lib")),
):
    if os.path.isfile(os.path.join(_cand, "sigma_rest.py")):
        sys.path.insert(0, _cand)
        break

import sigma_rest  # noqa: E402


class Base(unittest.TestCase):
    # env keys we mutate — snapshot + restore so cases don't bleed.
    KEYS = ["SIGMA_BASE_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET",
            "SIGMA_API_TOKEN", "SIGMA_WORKDIR"]

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in self.KEYS}
        for k in self.KEYS:
            os.environ.pop(k, None)
        # reset module state
        sigma_rest._token_override = None
        sigma_rest._refresh_inflight = False
        self._sends = []
        self._queue = []
        sigma_rest._send = self._fake_send  # monkeypatch the HTTP seam
        self._orig_neutral = sigma_rest.NEUTRAL_ENV

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        sigma_rest.NEUTRAL_ENV = self._orig_neutral

    def _fake_send(self, method, url, headers, body, timeout):
        self._sends.append({"method": method, "url": url, "headers": headers,
                            "body": body, "timeout": timeout})
        status, resp_body = self._queue.pop(0)
        return sigma_rest._Resp(status, resp_body)

    def enqueue(self, status, body):
        self._queue.append((status, body if isinstance(body, (bytes, str)) else json.dumps(body)))


class BaseUrl(Base):
    def test_returns_env(self):
        os.environ["SIGMA_BASE_URL"] = "https://x.example"
        self.assertEqual(sigma_rest.base_url(), "https://x.example")

    def test_raises_when_unset(self):
        with self.assertRaises(sigma_rest.SigmaError):
            sigma_rest.base_url()


class NeutralEnv(Base):
    def _write(self, text):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        self.addCleanup(os.remove, path)
        sigma_rest.NEUTRAL_ENV = path
        return path

    def test_parses_export_and_strips_quotes(self):
        self._write("export SIGMA_CLIENT_ID=abc\nSIGMA_CLIENT_SECRET='sec ret'\nSIGMA_BASE_URL=\"https://b\"\n")
        sigma_rest._load_neutral_env()
        self.assertEqual(os.environ["SIGMA_CLIENT_ID"], "abc")
        self.assertEqual(os.environ["SIGMA_CLIENT_SECRET"], "sec ret")
        self.assertEqual(os.environ["SIGMA_BASE_URL"], "https://b")

    def test_existing_env_wins(self):
        self._write("SIGMA_BASE_URL=https://from-file\n")
        os.environ["SIGMA_CLIENT_ID"] = "already"  # presence short-circuits the load
        os.environ["SIGMA_BASE_URL"] = "https://from-env"
        sigma_rest._load_neutral_env()
        self.assertEqual(os.environ["SIGMA_BASE_URL"], "https://from-env")

    def test_skipped_when_client_id_present(self):
        self._write("SIGMA_CLIENT_SECRET=fromfile\n")
        os.environ["SIGMA_CLIENT_ID"] = "present"
        sigma_rest._load_neutral_env()
        self.assertNotIn("SIGMA_CLIENT_SECRET", os.environ)


class AuthJson(Base):
    def _workdir(self, payload, bom=False, corrupt=False):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        raw = "not json{" if corrupt else json.dumps(payload)
        data = ("﻿" + raw) if bom else raw
        with open(os.path.join(d, "auth.json"), "w", encoding="utf-8") as fh:
            fh.write(data)
        return d

    def test_reads_token_and_base_from_cwd(self):
        d = self._workdir({"SIGMA_API_TOKEN": "tok123", "SIGMA_BASE_URL": "https://b"})
        sigma_rest._load_auth_json(cwd=d)
        self.assertEqual(os.environ["SIGMA_API_TOKEN"], "tok123")
        self.assertEqual(os.environ["SIGMA_BASE_URL"], "https://b")

    def test_env_token_wins(self):
        d = self._workdir({"SIGMA_API_TOKEN": "fromfile"})
        os.environ["SIGMA_API_TOKEN"] = "fromenv"
        sigma_rest._load_auth_json(cwd=d)
        self.assertEqual(os.environ["SIGMA_API_TOKEN"], "fromenv")

    def test_bom_tolerated(self):
        d = self._workdir({"SIGMA_API_TOKEN": "tokbom"}, bom=True)
        sigma_rest._load_auth_json(cwd=d)
        self.assertEqual(os.environ["SIGMA_API_TOKEN"], "tokbom")

    def test_corrupt_tolerated(self):
        d = self._workdir({}, corrupt=True)
        sigma_rest._load_auth_json(cwd=d)  # must not raise
        self.assertNotIn("SIGMA_API_TOKEN", os.environ)

    def test_workdir_takes_precedence_over_cwd(self):
        cwd = self._workdir({"SIGMA_API_TOKEN": "cwdtok"})
        wd = self._workdir({"SIGMA_API_TOKEN": "wdtok"})
        os.environ["SIGMA_WORKDIR"] = wd
        sigma_rest._load_auth_json(cwd=cwd)
        self.assertEqual(os.environ["SIGMA_API_TOKEN"], "wdtok")


class AuthTokenPrecedence(Base):
    def test_override_beats_env(self):
        os.environ["SIGMA_API_TOKEN"] = "envtok"
        sigma_rest._token_override = "overtok"
        self.assertEqual(sigma_rest.auth_token(), "overtok")

    def test_env_used_when_no_override(self):
        os.environ["SIGMA_API_TOKEN"] = "envtok"
        self.assertEqual(sigma_rest.auth_token(), "envtok")

    def test_refresh_when_neither(self):
        os.environ["SIGMA_BASE_URL"] = "https://b"
        os.environ["SIGMA_CLIENT_ID"] = "id"
        os.environ["SIGMA_CLIENT_SECRET"] = "sec"
        self.enqueue(200, {"access_token": "minted"})
        self.assertEqual(sigma_rest.auth_token(), "minted")


class RefreshToken(Base):
    def _creds(self):
        os.environ["SIGMA_BASE_URL"] = "https://b"
        os.environ["SIGMA_CLIENT_ID"] = "myid"
        os.environ["SIGMA_CLIENT_SECRET"] = "mysecret"

    def test_exchange_request_shape(self):
        self._creds()
        self.enqueue(200, {"access_token": "T"})
        tok = sigma_rest.refresh_token()
        self.assertEqual(tok, "T")
        s = self._sends[0]
        self.assertEqual(s["method"], "POST")
        self.assertEqual(s["url"], "https://b/v2/auth/token")
        self.assertEqual(s["body"], "grant_type=client_credentials")
        self.assertEqual(s["headers"]["Content-Type"], "application/x-www-form-urlencoded")
        import base64
        self.assertEqual(s["headers"]["Authorization"],
                         "Basic " + base64.b64encode(b"myid:mysecret").decode())

    def test_caches_to_override_and_env(self):
        self._creds()
        self.enqueue(200, {"access_token": "T2"})
        sigma_rest.refresh_token()
        self.assertEqual(sigma_rest._token_override, "T2")
        self.assertEqual(os.environ["SIGMA_API_TOKEN"], "T2")

    def test_non_2xx_raises(self):
        self._creds()
        self.enqueue(401, "nope")
        with self.assertRaises(sigma_rest.SigmaAuthError):
            sigma_rest.refresh_token()

    def test_missing_access_token_raises(self):
        self._creds()
        self.enqueue(200, {"nope": 1})
        with self.assertRaises(sigma_rest.SigmaAuthError):
            sigma_rest.refresh_token()

    def test_missing_creds_raises(self):
        os.environ["SIGMA_BASE_URL"] = "https://b"  # no client id/secret
        with self.assertRaises(sigma_rest.SigmaAuthError):
            sigma_rest.refresh_token()


class Request(Base):
    def _ready(self):
        os.environ["SIGMA_BASE_URL"] = "https://b"
        os.environ["SIGMA_API_TOKEN"] = "tok"

    def test_get_json_parsed(self):
        self._ready()
        self.enqueue(200, {"hello": "world"})
        out = sigma_rest.request("get", "/v2/x")
        self.assertEqual(out, {"hello": "world"})
        s = self._sends[0]
        self.assertEqual(s["headers"]["Authorization"], "Bearer tok")
        self.assertEqual(s["headers"]["Accept"], "application/json")
        self.assertNotIn("Content-Type", s["headers"])  # no body -> no content-type

    def test_post_sets_content_type(self):
        self._ready()
        self.enqueue(200, {})
        sigma_rest.request("post", "/v2/x", body=json.dumps({"a": 1}))
        self.assertEqual(self._sends[0]["headers"]["Content-Type"], "application/json")

    def test_empty_body_returns_none(self):
        self._ready()
        self.enqueue(200, "")
        self.assertIsNone(sigma_rest.request("get", "/v2/x"))

    def test_binary_returns_bytes(self):
        self._ready()
        self.enqueue(200, b"\x89PNG")
        out = sigma_rest.request("get", "/v2/img", binary=True)
        self.assertEqual(out, b"\x89PNG")

    def test_non_json_accept_returns_text(self):
        self._ready()
        self.enqueue(200, "a,b,c\n1,2,3")
        out = sigma_rest.request("get", "/v2/csv", accept="text/csv")
        self.assertEqual(out, "a,b,c\n1,2,3")

    def test_401_refreshes_once_then_retries(self):
        os.environ["SIGMA_BASE_URL"] = "https://b"
        os.environ["SIGMA_API_TOKEN"] = "stale"
        os.environ["SIGMA_CLIENT_ID"] = "id"
        os.environ["SIGMA_CLIENT_SECRET"] = "sec"
        self.enqueue(401, "unauthorized")            # first request
        self.enqueue(200, {"access_token": "fresh"})  # refresh exchange
        self.enqueue(200, {"ok": True})               # retried request
        out = sigma_rest.request("get", "/v2/x")
        self.assertEqual(out, {"ok": True})
        self.assertEqual(len(self._sends), 3)
        self.assertEqual(self._sends[2]["headers"]["Authorization"], "Bearer fresh")

    def test_second_401_raises(self):
        os.environ["SIGMA_BASE_URL"] = "https://b"
        os.environ["SIGMA_API_TOKEN"] = "stale"
        os.environ["SIGMA_CLIENT_ID"] = "id"
        os.environ["SIGMA_CLIENT_SECRET"] = "sec"
        self.enqueue(401, "unauthorized")
        self.enqueue(200, {"access_token": "fresh"})
        self.enqueue(401, "still unauthorized")
        with self.assertRaises(sigma_rest.SigmaError):
            sigma_rest.request("get", "/v2/x")

    def test_401_without_client_id_not_retried(self):
        self._ready()  # token but no client creds -> cannot self-mint
        self.enqueue(401, "unauthorized")
        with self.assertRaises(sigma_rest.SigmaError):
            sigma_rest.request("get", "/v2/x")
        self.assertEqual(len(self._sends), 1)

    def test_non_2xx_raises_with_context(self):
        self._ready()
        self.enqueue(404, "not found")
        with self.assertRaises(sigma_rest.SigmaError) as cm:
            sigma_rest.request("get", "/v2/missing")
        self.assertIn("404", str(cm.exception))
        self.assertIn("/v2/missing", str(cm.exception))

    def test_unsupported_method(self):
        self._ready()
        with self.assertRaises(ValueError):
            sigma_rest.request("options", "/v2/x")


if __name__ == "__main__":
    unittest.main(verbosity=2)
