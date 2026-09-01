#!/usr/bin/env python3
"""Contract/spec test for tableau_rest.py (P1 Ruby->Python port).

Creds-free, network-free: the HTTP layer (tableau_rest._send) is monkeypatched.
Encodes the observable behaviour of tableau_rest.rb — credential bootstrap,
override/env precedence, PAT signin shape, the 401 refresh-once loop, the
single-vs-array collection normalisation, and the paged datasource fallback.
"""
import base64  # noqa: F401 (parity symmetry with sigma test; harmless)
import json
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
for _cand in (
    os.path.join(_HERE, "lib"),
    os.path.abspath(os.path.join(_HERE, "..", "..", "..", "..", "..", "shared", "lib")),
):
    if os.path.isfile(os.path.join(_cand, "tableau_rest.py")):
        sys.path.insert(0, _cand)
        break

import tableau_rest as tr  # noqa: E402


class Base(unittest.TestCase):
    KEYS = ["TABLEAU_SERVER_URL", "TABLEAU_SITE_ID", "TABLEAU_AUTH_TOKEN",
            "TABLEAU_API_VERSION", "TABLEAU_PAT_NAME", "TABLEAU_PAT_SECRET",
            "TABLEAU_SITE_CONTENT_URL", "TABLEAU_INSECURE_TLS"]

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in self.KEYS}
        for k in self.KEYS:
            os.environ.pop(k, None)
        tr._token_override = None
        tr._site_id_override = None
        tr._refresh_inflight = False
        self._sends = []
        self._queue = []
        tr._send = self._fake_send
        self._orig_neutral = tr.NEUTRAL_ENV

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        tr.NEUTRAL_ENV = self._orig_neutral

    def _fake_send(self, method, url, headers, body, timeout):
        self._sends.append({"method": method, "url": url, "headers": headers,
                            "body": body, "timeout": timeout})
        status, resp_body = self._queue.pop(0)
        return tr._Resp(status, resp_body)

    def enqueue(self, status, body):
        self._queue.append((status, body if isinstance(body, (bytes, str)) else json.dumps(body)))

    def ready(self, **over):
        os.environ["TABLEAU_SERVER_URL"] = over.get("server", "https://ten.online.tableau.com")
        os.environ["TABLEAU_SITE_ID"] = over.get("site", "site-luid")
        os.environ["TABLEAU_AUTH_TOKEN"] = over.get("tok", "tok")


class Config(Base):
    def test_server_url_raises_when_unset(self):
        with self.assertRaises(tr.TableauError):
            tr.server_url()

    def test_api_version_default(self):
        self.assertEqual(tr.api_version(), "3.22")

    def test_api_version_override(self):
        os.environ["TABLEAU_API_VERSION"] = "3.24"
        self.assertEqual(tr.api_version(), "3.24")

    def test_base_path(self):
        self.ready()
        self.assertEqual(tr.base_path(), "/api/3.22/sites/site-luid")

    def test_overrides_beat_env(self):
        self.ready()
        tr._token_override = "OVR"
        tr._site_id_override = "site-ovr"
        self.assertEqual(tr.auth_token(), "OVR")
        self.assertEqual(tr.site_id(), "site-ovr")


class NeutralEnv(Base):
    def _write(self, text):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        self.addCleanup(os.remove, path)
        tr.NEUTRAL_ENV = path

    def test_loads_when_pat_secret_absent(self):
        self._write("export TABLEAU_PAT_NAME=mypat\nTABLEAU_PAT_SECRET='sh sh'\n")
        tr._load_neutral_env()
        self.assertEqual(os.environ["TABLEAU_PAT_NAME"], "mypat")
        self.assertEqual(os.environ["TABLEAU_PAT_SECRET"], "sh sh")

    def test_skipped_when_pat_secret_present(self):
        self._write("TABLEAU_PAT_NAME=fromfile\n")
        os.environ["TABLEAU_PAT_SECRET"] = "present"
        tr._load_neutral_env()
        self.assertNotIn("TABLEAU_PAT_NAME", os.environ)


class Refresh(Base):
    def _creds(self):
        os.environ["TABLEAU_SERVER_URL"] = "https://ten.online.tableau.com"
        os.environ["TABLEAU_PAT_NAME"] = "patname"
        os.environ["TABLEAU_PAT_SECRET"] = "patsecret"
        os.environ["TABLEAU_SITE_CONTENT_URL"] = "acme"

    def test_signin_request_shape(self):
        self._creds()
        self.enqueue(200, {"credentials": {"token": "NEWTOK", "site": {"id": "site-9"}}})
        tok = tr.refresh_token()
        self.assertEqual(tok, "NEWTOK")
        self.assertEqual(tr._site_id_override, "site-9")
        s = self._sends[0]
        self.assertEqual(s["method"], "POST")
        self.assertEqual(s["url"], "https://ten.online.tableau.com/api/3.22/auth/signin")
        self.assertEqual(s["headers"]["Content-Type"], "application/xml")
        self.assertIn('personalAccessTokenName="patname"', s["body"])
        self.assertIn('personalAccessTokenSecret="patsecret"', s["body"])
        self.assertIn('<site contentUrl="acme"/>', s["body"])

    def test_non_2xx_raises(self):
        self._creds()
        self.enqueue(401, "bad pat")
        with self.assertRaises(tr.TableauAuthError):
            tr.refresh_token()

    def test_missing_pat_raises(self):
        os.environ["TABLEAU_SERVER_URL"] = "https://ten.online.tableau.com"
        with self.assertRaises(tr.TableauAuthError):
            tr.refresh_token()


class Request(Base):
    def test_get_json_and_auth_header(self):
        self.ready()
        self.enqueue(200, {"ok": 1})
        out = tr.request("get", "/api/3.22/sites/x/workbooks")
        self.assertEqual(out, {"ok": 1})
        self.assertEqual(self._sends[0]["headers"]["X-Tableau-Auth"], "tok")
        self.assertEqual(self._sends[0]["url"],
                         "https://ten.online.tableau.com/api/3.22/sites/x/workbooks")

    def test_binary_returns_bytes(self):
        self.ready()
        self.enqueue(200, b"\x89PNG")
        self.assertEqual(tr.request("get", "/x", accept="*/*", binary=True), b"\x89PNG")

    def test_empty_body_none(self):
        self.ready()
        self.enqueue(200, "")
        self.assertIsNone(tr.request("get", "/x"))

    def test_non_json_accept_text(self):
        self.ready()
        self.enqueue(200, "col\n1")
        self.assertEqual(tr.request("get", "/x", accept="*/*"), "col\n1")

    def test_401_refreshes_once_then_retries(self):
        self.ready()
        os.environ["TABLEAU_PAT_NAME"] = "p"
        os.environ["TABLEAU_PAT_SECRET"] = "s"
        os.environ["TABLEAU_SITE_CONTENT_URL"] = "acme"
        self.enqueue(401, "expired")
        self.enqueue(200, {"credentials": {"token": "FRESH", "site": {"id": "s2"}}})
        self.enqueue(200, {"ok": True})
        out = tr.request("get", "/x")
        self.assertEqual(out, {"ok": True})
        self.assertEqual(len(self._sends), 3)
        self.assertEqual(self._sends[2]["headers"]["X-Tableau-Auth"], "FRESH")

    def test_401_without_pat_not_retried(self):
        self.ready()  # no PAT name -> cannot refresh
        self.enqueue(401, "expired")
        with self.assertRaises(tr.TableauError):
            tr.request("get", "/x")
        self.assertEqual(len(self._sends), 1)

    def test_unsupported_method(self):
        self.ready()
        with self.assertRaises(ValueError):
            tr.request("patch", "/x")


class Collections(Base):
    def test_find_workbook_single_object_normalised(self):
        self.ready()
        # Tableau returns a bare object (not a list) for a single match.
        self.enqueue(200, {"workbooks": {"workbook": {"id": "wb1", "name": "Sales"}}})
        wb = tr.find_workbook_by_name("Sales")
        self.assertEqual(wb["id"], "wb1")
        # filter is CGI/quote_plus encoded
        self.assertIn("name%3Aeq%3ASales", self._sends[0]["url"])

    def test_find_workbook_list(self):
        self.ready()
        self.enqueue(200, {"workbooks": {"workbook": [{"id": "a"}, {"id": "b"}]}})
        self.assertEqual(tr.find_workbook_by_name("x")["id"], "a")

    def test_find_workbook_none(self):
        self.ready()
        self.enqueue(200, {"workbooks": {}})
        self.assertIsNone(tr.find_workbook_by_name("x"))

    def test_workbook_content_url_paged_fallback(self):
        self.ready()
        self.enqueue(200, {"workbooks": {}})
        self.enqueue(200, {"workbooks": {"workbook": [{"contentUrl": "other"}]},
                           "pagination": {"totalAvailable": "150"}})
        self.enqueue(200, {"workbooks": {"workbook": [{"contentUrl": "wanted", "id": "wb9"}]},
                           "pagination": {"totalAvailable": "150"}})
        hit = tr.find_workbook_by_content_url("wanted")
        self.assertEqual(hit["id"], "wb9")

    def test_connection_collections_are_normalised(self):
        self.ready()
        self.enqueue(200, {"connections": {"connection": {"id": "c1"}}})
        self.assertEqual([{"id": "c1"}], tr.workbook_connections("wb1"))
        self.enqueue(200, {"connections": {"connection": [{"id": "c2"}]}})
        self.assertEqual([{"id": "c2"}], tr.datasource_connections("ds1"))

    def test_filtered_view_data_encodes_fields_and_values(self):
        self.ready()
        self.enqueue(200, "a,b\n1,2")
        tr.view_data_filtered("view1", {"Sales Region": "West Coast"})
        self.assertIn("vf_Sales%20Region=West%20Coast", self._sends[0]["url"])

    def test_graphql_workbook_dashboards_unwraps_membership(self):
        self.ready()
        self.enqueue(200, {
            "data": {
                "workbooks": [
                    {"dashboards": [{"name": "Executive", "sheets": [{"name": "Sales"}]}]}
                ]
            }
        })
        dashboards = tr.graphql_workbook_dashboards("wb1")
        self.assertEqual("Executive", dashboards[0]["name"])

    def test_datasource_content_url_paged_fallback(self):
        self.ready()
        # filter hit empty -> fall back to paged scan; match on page 2
        self.enqueue(200, {"datasources": {}})
        self.enqueue(200, {"datasources": {"datasource": [{"contentUrl": "other"}]},
                           "pagination": {"totalAvailable": "150"}})
        self.enqueue(200, {"datasources": {"datasource": [{"contentUrl": "wanted", "id": "ds9"}]},
                           "pagination": {"totalAvailable": "150"}})
        hit = tr.find_datasource_by_content_url("wanted")
        self.assertEqual(hit["id"], "ds9")

    def test_metadata_api_available_true_false_error(self):
        self.ready()
        self.enqueue(200, {"data": {"__typename": "Query"}})
        self.assertTrue(tr.metadata_api_available())
        self.enqueue(200, {"errors": [{"message": "off"}]})
        self.assertFalse(tr.metadata_api_available())
        self.enqueue(404, "not found")
        self.assertFalse(tr.metadata_api_available())


class SslContext(Base):
    def test_returns_context_and_verifies_by_default(self):
        import ssl
        ctx = tr._ssl_context()
        self.assertIsInstance(ctx, ssl.SSLContext)
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)

    def test_insecure_flag_disables_verification(self):
        import ssl
        os.environ["TABLEAU_INSECURE_TLS"] = "1"
        ctx = tr._ssl_context()
        self.assertEqual(ctx.verify_mode, ssl.CERT_NONE)
        self.assertFalse(ctx.check_hostname)


if __name__ == "__main__":
    unittest.main(verbosity=2)
