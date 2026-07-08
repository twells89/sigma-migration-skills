#!/usr/bin/env python3
"""Contract test for pick_destination.py (P1 leaf port).

Creds-free, network-free: sigma_rest.request is monkeypatched with canned API
responses. Verifies the list shaping (workspace id fallback, edit-only folder
filter, parentName join, myDocuments resolution) and create arg parsing / body.
"""
import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "lib"))
import pick_destination as pd  # noqa: E402
import sigma_rest  # noqa: E402


class Base(unittest.TestCase):
    def setUp(self):
        self._orig = sigma_rest.request
        self._routes = {}
        self._posts = []
        sigma_rest.request = self._fake
        pd.sigma_rest = sigma_rest  # ensure the module ref points at our patched one

    def tearDown(self):
        sigma_rest.request = self._orig

    def _fake(self, method, path, body=None, **kw):
        if method == "post":
            self._posts.append({"path": path, "body": body})
            return self._routes.get(("post", path), {})
        if ("get", path) in self._routes:
            r = self._routes[("get", path)]
            if isinstance(r, Exception):
                raise r
            return r
        raise sigma_rest.SigmaError(f"unrouted GET {path}")

    def route(self, method, path, resp):
        self._routes[(method, path)] = resp

    def run_main(self, argv):
        buf = io.StringIO()
        with redirect_stdout(buf):
            pd.main(argv)
        return buf.getvalue()


class ListCmd(Base):
    def _base_routes(self):
        self.route("get", "/v2/whoami", {"userId": "u1"})
        self.route("get", "/v2/members/u1/files?typeFilters=folder&limit=500",
                   {"entries": [{"id": "md1", "name": "My Documents"}]})
        self.route("get", "/v2/workspaces?limit=500",
                   {"entries": [{"workspaceId": "ws1", "name": "Sales"},
                                {"id": "ws2", "name": "Ops"}]})
        self.route("get", "/v2/files?typeFilters=folder&limit=500",
                   {"entries": [
                       {"id": "f1", "name": "Editable", "parentId": "ws1", "permission": "edit"},
                       {"id": "f2", "name": "ReadOnly", "parentId": "ws1", "permission": "view"},
                   ]})

    def test_list_shape(self):
        self._base_routes()
        out = json.loads(self.run_main(["list"]))
        # workspaceId falls back to id
        self.assertEqual([w["id"] for w in out["workspaces"]], ["ws1", "ws2"])
        # only edit-permission folders; parentName joined from workspaces
        self.assertEqual(len(out["folders"]), 1)
        self.assertEqual(out["folders"][0]["id"], "f1")
        self.assertEqual(out["folders"][0]["parentName"], "Sales")
        self.assertEqual(out["myDocuments"], "md1")

    def test_default_argv_is_list(self):
        self._base_routes()
        self.assertEqual(self.run_main([]), self.run_main(["list"]))

    def test_my_documents_none_for_service_token(self):
        self.route("get", "/v2/whoami", {})  # no userId
        self.route("get", "/v2/workspaces?limit=500", {"entries": []})
        self.route("get", "/v2/files?typeFilters=folder&limit=500", {"entries": []})
        out = json.loads(self.run_main(["list"]))
        self.assertIsNone(out["myDocuments"])

    def test_errors_swallowed_to_empty(self):
        # whoami raises -> myDocuments None; workspaces raise -> empty lists
        self.route("get", "/v2/whoami", sigma_rest.SigmaError("boom"))
        self.route("get", "/v2/workspaces?limit=500", sigma_rest.SigmaError("boom"))
        self.route("get", "/v2/files?typeFilters=folder&limit=500", sigma_rest.SigmaError("boom"))
        out = json.loads(self.run_main(["list"]))
        self.assertEqual(out, {"workspaces": [], "folders": [], "myDocuments": None})


class CreateCmd(Base):
    def test_create_with_parent(self):
        self.route("post", "/v2/files", {"id": "new1", "name": "Migrated", "parentId": "ws1"})
        out = json.loads(self.run_main(["create", "--name", "Migrated", "--parent", "ws1"]))
        self.assertEqual(out, {"id": "new1", "name": "Migrated", "parentId": "ws1"})
        self.assertEqual(json.loads(self._posts[0]["body"]),
                         {"type": "folder", "name": "Migrated", "parentId": "ws1"})

    def test_create_defaults_parent_to_my_documents(self):
        self.route("get", "/v2/whoami", {"userId": "u1"})
        self.route("get", "/v2/members/u1/files?typeFilters=folder&limit=500",
                   {"entries": [{"id": "md1", "name": "My Documents"}]})
        self.route("post", "/v2/files", {"id": "n", "name": "X", "parentId": "md1"})
        self.run_main(["create", "--name", "X"])
        self.assertEqual(json.loads(self._posts[0]["body"])["parentId"], "md1")

    def test_create_requires_name(self):
        with self.assertRaises(SystemExit):
            self.run_main(["create", "--parent", "ws1"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
