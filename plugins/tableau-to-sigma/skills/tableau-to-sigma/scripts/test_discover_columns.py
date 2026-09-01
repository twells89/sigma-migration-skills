#!/usr/bin/env python3
"""Creds-free contract tests for discover-columns.py."""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "discover-columns.py"
SPEC = importlib.util.spec_from_file_location("discover_columns", SCRIPT)
discover_columns = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(discover_columns)


class DiscoverColumnsTest(unittest.TestCase):
    def setUp(self):
        self.original_request = discover_columns.sigma_rest.request
        self.calls = []
        self.responses = []
        discover_columns.sigma_rest.request = self.fake_request

    def tearDown(self):
        discover_columns.sigma_rest.request = self.original_request

    def fake_request(self, method, path, body=None, **_kwargs):
        self.calls.append({"method": method, "path": path, "body": body})
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response

    def test_lookup_and_token_pagination_preserve_output_contract(self):
        self.responses = [
            {"kind": "table", "inodeId": "inode-1"},
            {
                "entries": [
                    {
                        "name": "Order ID",
                        "type": {"type": "NUMBER(38,0)"},
                        "ordinal": 1,
                    }
                ],
                "nextPageToken": "50/α",
            },
            {
                "entries": [{"name": "MiXeD 名", "type": "VarChar"}],
                "nextPageToken": None,
            },
        ]

        pages = []
        result = discover_columns.discover(
            "connection-1",
            "Raw DB.Case Schema.Order Table",
            on_page=pages.append,
        )

        self.assertEqual(
            {
                "connection_id": "connection-1",
                "path": ["Raw DB", "Case Schema", "Order Table"],
                "inode_id": "inode-1",
                "columns": [
                    {"name": "Order ID", "type": "NUMBER(38,0)"},
                    {"name": "MiXeD 名", "type": "VarChar"},
                ],
            },
            result,
        )
        self.assertEqual(2, len(pages))
        self.assertEqual(
            {
                "method": "post",
                "path": "/v2/connection/connection-1/lookup",
                "body": '{"path":["Raw DB","Case Schema","Order Table"]}',
            },
            self.calls[0],
        )
        self.assertEqual(
            "/v2/connections/tables/inode-1/columns?limit=1000",
            self.calls[1]["path"],
        )
        self.assertEqual(
            "/v2/connections/tables/inode-1/columns?"
            "limit=1000&pageToken=50%2F%CE%B1",
            self.calls[2]["path"],
        )

    def test_raw_warehouse_entries_are_not_normalized_or_trimmed(self):
        raw = [
            {"name": "  Sales-Δ  ", "type": "decimal(12, 4)", "extra": True}
        ]
        self.responses = [{"entries": raw}]

        self.assertEqual(
            raw,
            discover_columns.list_warehouse_columns("inode-raw"),
        )

    def test_next_page_fallback_uses_page_parameter(self):
        self.responses = [
            {"entries": [{"name": "A", "type": "TEXT"}], "nextPage": 2},
            {"entries": [{"name": "B", "type": "DATE"}], "nextPage": None},
        ]

        columns = discover_columns.list_warehouse_columns("inode-2")

        self.assertEqual(["A", "B"], [column["name"] for column in columns])
        self.assertEqual(
            "/v2/connections/tables/inode-2/columns?limit=1000&page=2",
            self.calls[1]["path"],
        )

    def test_repeated_cursor_fails_instead_of_returning_partial_columns(self):
        self.responses = [
            {"entries": [{"name": "A", "type": "TEXT"}], "nextPageToken": "x"},
            {"entries": [{"name": "B", "type": "TEXT"}], "nextPageToken": "x"},
        ]

        with self.assertRaisesRegex(
            discover_columns.DiscoveryError,
            "refusing a partial column list",
        ):
            discover_columns.list_warehouse_columns("inode-repeat")

    def test_malformed_page_fails_closed(self):
        for response in (None, [], {}, {"entries": [None]}):
            with self.subTest(response=response):
                self.responses = [response]
                with self.assertRaises(discover_columns.DiscoveryError):
                    discover_columns.list_warehouse_columns("inode-bad")

    def test_invalid_lookup_fails_closed(self):
        for lookup in (
            None,
            {},
            {"kind": "table", "inodeId": ""},
            {"kind": "schema", "inodeId": "inode"},
        ):
            with self.subTest(lookup=lookup):
                self.responses = [lookup]
                with self.assertRaises(discover_columns.DiscoveryError):
                    discover_columns.discover("connection", "DB.SCHEMA.TABLE")

    def test_main_writes_exact_json_shape_only_after_all_pages_succeed(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "columns.json"
            self.responses = [
                {"kind": "table", "inodeId": "inode"},
                {
                    "entries": [{"name": "A B", "type": {"type": "TIMESTAMP"}}],
                    "nextPageToken": None,
                },
            ]
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = discover_columns.main(
                    [
                        "--connection-id",
                        "conn",
                        "--table-path",
                        "DB.Schema.Table",
                        "--out",
                        str(out),
                    ]
                )

            self.assertEqual(0, code)
            self.assertEqual(
                {
                    "connection_id": "conn",
                    "path": ["DB", "Schema", "Table"],
                    "inode_id": "inode",
                    "columns": [{"name": "A B", "type": "TIMESTAMP"}],
                },
                json.loads(out.read_text(encoding="utf-8")),
            )
            self.assertIn("wrote", stdout.getvalue())

    def test_main_returns_nonzero_and_writes_nothing_on_api_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "columns.json"
            self.responses = [
                {"kind": "table", "inodeId": "inode"},
                {
                    "entries": [{"name": "A", "type": "TEXT"}],
                    "nextPageToken": "next",
                },
                discover_columns.sigma_rest.SigmaError(
                    "GET /columns -> 500 failure"
                ),
            ]
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code = discover_columns.main(
                    [
                        "--connection-id",
                        "conn",
                        "--table-path",
                        "DB.SCHEMA.TABLE",
                        "--out",
                        str(out),
                    ]
                )

            self.assertEqual(1, code)
            self.assertFalse(out.exists())
            self.assertIn("FATAL", stderr.getvalue())

    def test_lookup_404_preserves_catalog_miss_exit_code(self):
        path = "/v2/connection/conn/lookup"
        self.responses = [
            discover_columns.sigma_rest.SigmaError(
                f"POST {path} -> 404 Not Found\nmissing"
            )
        ]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = discover_columns.main(
                [
                    "--connection-id",
                    "conn",
                    "--table-path",
                    "DB.SCHEMA.TABLE",
                ]
            )

        self.assertEqual(4, code)
        self.assertIn("not found in Sigma's catalog", stderr.getvalue())
        self.assertIn("/sync", stderr.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
