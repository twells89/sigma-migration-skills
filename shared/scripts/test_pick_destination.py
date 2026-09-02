#!/usr/bin/env python3
"""Offline tests for the shared Python destination picker."""
import importlib.util
import io
import json
import pathlib
import unittest
from contextlib import redirect_stdout


SCRIPT = pathlib.Path(__file__).with_name("pick_destination.py")
SPEC = importlib.util.spec_from_file_location("pick_destination", SCRIPT)
picker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(picker)


class DestinationPickerTest(unittest.TestCase):
    def setUp(self):
        self.original_call = picker.call
        self.routes = {}
        self.calls = []
        picker.call = self.fake_call

    def tearDown(self):
        picker.call = self.original_call

    def fake_call(self, method, path, body=None):
        self.calls.append((method, path, body))
        return self.routes.get((method, path), {})

    def route(self, method, path, response):
        self.routes[(method, path)] = response

    def test_my_documents_uses_member_home_folder_id(self):
        self.route("GET", "/v2/whoami", {"userId": "member-1"})
        self.route(
            "GET",
            "/v2/members/member-1",
            {"homeFolderId": "home-folder-id"},
        )

        self.assertEqual("home-folder-id", picker.my_documents_id())
        self.assertEqual(
            [
                ("GET", "/v2/whoami", None),
                ("GET", "/v2/members/member-1", None),
            ],
            self.calls,
        )

    def test_legacy_fallback_uses_folder_id_not_parent_id(self):
        self.route("GET", "/v2/whoami", {"userId": "member-1"})
        self.route("GET", "/v2/members/member-1", {})
        self.route(
            "GET",
            "/v2/members/member-1/files?typeFilters=folder&limit=500",
            {
                "entries": [
                    {
                        "id": "my-documents-id",
                        "parentId": "wrong-parent-id",
                        "name": "My Documents",
                    }
                ]
            },
        )

        self.assertEqual("my-documents-id", picker.my_documents_id())

    def test_list_exposes_authoritative_my_documents_id(self):
        self.route("GET", "/v2/whoami", {"userId": "member-1"})
        self.route(
            "GET",
            "/v2/members/member-1",
            {"homeFolderId": "home-folder-id"},
        )
        self.route(
            "GET",
            "/v2/workspaces?limit=500",
            {"entries": [{"workspaceId": "workspace-1", "name": "Sales"}]},
        )
        self.route(
            "GET",
            "/v2/files?typeFilters=folder&limit=500",
            {
                "entries": [
                    {
                        "id": "folder-1",
                        "name": "Reports",
                        "parentId": "workspace-1",
                        "permission": "edit",
                    }
                ]
            },
        )
        output = io.StringIO()

        with redirect_stdout(output):
            picker.cmd_list()

        result = json.loads(output.getvalue())
        self.assertEqual("home-folder-id", result["myDocuments"])
        self.assertEqual("Sales", result["folders"][0]["parentName"])

    def test_create_defaults_parent_to_home_folder(self):
        self.route("GET", "/v2/whoami", {"userId": "member-1"})
        self.route(
            "GET",
            "/v2/members/member-1",
            {"homeFolderId": "home-folder-id"},
        )
        self.route(
            "POST",
            "/v2/files",
            {
                "id": "new-folder",
                "name": "Migrated",
                "parentId": "home-folder-id",
            },
        )
        output = io.StringIO()

        with redirect_stdout(output):
            picker.cmd_create(["--name", "Migrated"])

        post = self.calls[-1]
        self.assertEqual(
            {"type": "folder", "name": "Migrated", "parentId": "home-folder-id"},
            post[2],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
