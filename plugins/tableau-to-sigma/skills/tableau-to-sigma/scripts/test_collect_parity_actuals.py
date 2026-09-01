#!/usr/bin/env python3
"""Creds-free tests for REST parity-actual collection."""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "collect-parity-actuals.py"
SPEC = importlib.util.spec_from_file_location("collect_parity_actuals", SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class CollectParityActualsTest(unittest.TestCase):
    def setUp(self):
        self.original_request_raw = collector._request_raw
        self.original_send = collector.sigma_rest._send
        self.original_auth_token = collector.sigma_rest.auth_token
        self.original_refresh_token = collector.sigma_rest.refresh_token
        self.saved_env = {
            key: os.environ.get(key)
            for key in (
                "SIGMA_BASE_URL",
                "SIGMA_API_TOKEN",
                "SIGMA_CLIENT_ID",
                "SIGMA_CLIENT_SECRET",
            )
        }

    def tearDown(self):
        collector._request_raw = self.original_request_raw
        collector.sigma_rest._send = self.original_send
        collector.sigma_rest.auth_token = self.original_auth_token
        collector.sigma_rest.refresh_token = self.original_refresh_token
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    @staticmethod
    def response(status, body=b""):
        return collector.sigma_rest._Resp(status, body)

    def test_documented_export_paginates_with_row_limit_and_offset(self):
        posts = []
        downloads = {}

        def fake_request(method, path, *, deadline, body=None, accept="application/json", **_):
            if method == "post":
                payload = json.loads(body)
                posts.append(payload)
                query_id = f"q{len(posts)}"
                if payload["offset"] == 0:
                    downloads[query_id] = b"Region,Sales\nEast,10\nWest,20\n"
                elif payload["offset"] == 3:
                    downloads[query_id] = b"Region,Sales\nNorth,30\n"
                else:
                    self.fail(f"unexpected offset {payload['offset']}")
                return self.response(200, json.dumps({"queryId": query_id}))
            query_id = path.split("/")[-2]
            return self.response(200, downloads[query_id])

        collector._request_raw = fake_request
        headers, rows = collector.export_all_pages(
            "wb-1",
            "el-1",
            fmt="csv",
            page_size=2,
            deadline=collector.Deadline(10),
            max_rows=None,
            poll_interval=0,
        )

        self.assertEqual(["Region", "Sales"], headers)
        self.assertEqual(
            [["East", "10"], ["West", "20"], ["North", "30"]], rows
        )
        self.assertEqual([0, 3], [post["offset"] for post in posts])
        self.assertTrue(all(post["rowLimit"] == 2 for post in posts))
        self.assertTrue(all(post["runAsynchronously"] is True for post in posts))

    def test_pivot_uses_paginated_json_and_emits_existing_actual_rows_shape(self):
        formats = []
        payloads = {
            0: [{"Region": "East", "Sales": "10"}, {"Region": "West", "Sales": "20"}],
            3: [{"Region": "North", "Sales": "30"}],
        }
        query_payload = {}

        def fake_request(method, path, *, deadline, body=None, accept="application/json", **_):
            if method == "post":
                payload = json.loads(body)
                formats.append(payload["format"]["type"])
                query_id = f"q-{payload['offset']}"
                query_payload[query_id] = payloads[payload["offset"]]
                return self.response(200, json.dumps({"queryId": query_id}))
            query_id = path.split("/")[-2]
            return self.response(200, json.dumps(query_payload[query_id]))

        collector._request_raw = fake_request
        chart = {
            "chart": "Pivot",
            "sigma_element_id": "pivot-1",
            "sigma_kind": "pivot-table",
            "sigma_columns": ["c-region", "c-sales"],
        }
        element = {
            "id": "pivot-1",
            "kind": "pivot-table",
            "columns": [
                {"id": "c-region", "name": "Region"},
                {"id": "c-sales", "name": "Sales"},
            ],
        }

        rows = collector.collect_chart(
            chart,
            {"pivot-1": element},
            "wb-1",
            2,
            collector.Deadline(10),
            None,
            0,
        )

        self.assertEqual(
            [["East", 10.0], ["West", 20.0], ["North", 30.0]], rows
        )
        self.assertEqual(["json", "json"], formats)

    def test_download_poll_accepts_204_then_data_and_times_out(self):
        responses = [
            self.response(204),
            self.response(200, b"A\nvalue\n"),
        ]

        def fake_request(*_args, **_kwargs):
            return responses.pop(0)

        collector._request_raw = fake_request
        body = collector.poll_download(
            "q1",
            accept="text/csv",
            deadline=collector.Deadline(1),
            poll_interval=0,
        )
        self.assertEqual(b"A\nvalue\n", body)

        collector._request_raw = lambda *_args, **_kwargs: self.response(204)
        with self.assertRaises(collector.CollectionTimeout):
            collector.poll_download(
                "q2",
                accept="text/csv",
                deadline=collector.Deadline(0.01),
                poll_interval=0.002,
            )

    def test_authenticated_transport_refreshes_once_on_401(self):
        os.environ["SIGMA_BASE_URL"] = "https://stub.invalid"
        os.environ["SIGMA_CLIENT_ID"] = "id"
        os.environ["SIGMA_CLIENT_SECRET"] = "secret"
        state = {"token": "stale", "refreshes": 0, "calls": []}

        collector.sigma_rest.auth_token = lambda: state["token"]

        def refresh():
            state["refreshes"] += 1
            state["token"] = "fresh"
            return "fresh"

        def send(method, url, headers, body, timeout):
            state["calls"].append(
                {"method": method, "url": url, "headers": headers, "timeout": timeout}
            )
            if len(state["calls"]) == 1:
                return self.response(401, b"expired")
            return self.response(200, b'{"ok":true}')

        collector.sigma_rest.refresh_token = refresh
        collector.sigma_rest._send = send

        response = collector._request_raw(
            "get", "/v2/test", deadline=collector.Deadline(5)
        )

        self.assertEqual(200, response.status)
        self.assertEqual(1, state["refreshes"])
        self.assertEqual("Bearer stale", state["calls"][0]["headers"]["Authorization"])
        self.assertEqual("Bearer fresh", state["calls"][1]["headers"]["Authorization"])
        self.assertLessEqual(state["calls"][1]["timeout"], 5)

    def test_empty_displayed_tile_is_a_hard_collection_failure(self):
        def fake_request(method, path, *, deadline, body=None, **_):
            if method == "post":
                return self.response(200, b'{"queryId":"q-empty"}')
            return self.response(200, b"Region,Sales\n")

        collector._request_raw = fake_request
        chart = {
            "chart": "Empty Tile",
            "sigma_element_id": "el-empty",
            "sigma_kind": "bar-chart",
            "sigma_columns": ["x", "y"],
        }
        element = {
            "id": "el-empty",
            "kind": "bar-chart",
            "columns": [{"id": "x", "name": "Region"}, {"id": "y", "name": "Sales"}],
        }
        with self.assertRaisesRegex(
            collector.CollectionError, "exports zero data rows"
        ):
            collector.collect_chart(
                chart,
                {"el-empty": element},
                "wb",
                100,
                collector.Deadline(5),
                None,
                0,
            )

    def test_column_mismatch_and_whole_element_cap_fail_closed(self):
        with self.assertRaisesRegex(collector.CollectionError, "missing planned column"):
            collector.map_columns(["Region"], [["East"]], ["Sales"])

        downloads = {}

        def fake_request(method, path, *, deadline, body=None, **_):
            if method == "post":
                query_id = "q-cap"
                downloads[query_id] = b"Region\nEast\nWest\n"
                return self.response(200, b'{"queryId":"q-cap"}')
            return self.response(200, downloads[path.split("/")[-2]])

        collector._request_raw = fake_request
        with self.assertRaisesRegex(collector.CollectionError, "exceeds --max-rows"):
            collector.export_all_pages(
                "wb",
                "el",
                fmt="csv",
                page_size=2,
                deadline=collector.Deadline(5),
                max_rows=1,
                poll_interval=0,
            )

    def test_collect_returns_every_chart_or_a_fail_closed_marker(self):
        plan = {
            "charts": [
                {
                    "chart": "Good",
                    "sigma_element_id": "good",
                    "sigma_kind": "bar-chart",
                    "sigma_columns": ["x"],
                },
                {
                    "chart": "Empty",
                    "sigma_element_id": "empty",
                    "sigma_kind": "bar-chart",
                    "sigma_columns": ["x"],
                },
            ]
        }
        spec = {
            "workbookId": "wb",
            "latestDocumentVersion": 3,
            "document": {
                "elements": [
                    {"id": "good", "columns": [{"id": "x", "name": "X"}]},
                    {"id": "empty", "columns": [{"id": "x", "name": "X"}]},
                ]
            }
        }
        original_collect_chart = collector.collect_chart

        def fake_collect(chart, *_args, **_kwargs):
            if chart["chart"] == "Good":
                return [["A"]]
            raise collector.CollectionError("displayed tile 'Empty' exports zero data rows")

        collector.collect_chart = fake_collect
        self.addCleanup(setattr, collector, "collect_chart", original_collect_chart)
        collector._request_raw = lambda *_args, **_kwargs: self.response(
            200,
            b'{"workbookId":"wb","latestDocumentVersion":3,"document":{}}',
        )

        actuals, failures = collector.collect(
            plan,
            spec,
            workbook_id="wb",
            page_size=100,
            timeout=5,
            pool=2,
            poll_interval=0,
        )

        self.assertEqual({"Good": [["A"]]}, actuals)
        self.assertEqual("empty-displayed-tile", failures["Empty"]["status"])
        self.assertEqual({"Good", "Empty"}, set(actuals) | set(failures))

    def test_stale_or_unversioned_workbook_readback_fails_before_exports(self):
        collector._request_raw = lambda *_args, **_kwargs: self.response(
            200, b'{"latestDocumentVersion":8,"document":{}}'
        )
        with self.assertRaisesRegex(collector.CollectionError, "stale workbook readback"):
            collector.validate_live_document_version(
                {"workbookId": "wb", "latestDocumentVersion": 7},
                "wb",
                collector.Deadline(5),
            )
        with self.assertRaisesRegex(collector.CollectionError, "freshness cannot be proven"):
            collector.validate_live_document_version(
                {"workbookId": "wb"},
                "wb",
                collector.Deadline(5),
            )

    def test_main_writes_name_keyed_rows_and_markers_and_returns_nonzero(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        plan_path = root / "parity-plan.json"
        spec_path = root / "wb-readback.json"
        out_path = root / "parity-actuals.json"
        plan_path.write_text(
            json.dumps({"charts": [{"chart": "Good"}, {"chart": "Empty"}]}),
            encoding="utf-8",
        )
        spec_path.write_text('{"document":{"elements":[]}}', encoding="utf-8")
        out_path.write_text('{"Old":[["keep"]]}', encoding="utf-8")
        original_collect = collector.collect
        collector.collect = lambda *_args, **_kwargs: (
            {"Good": [["East", 10.0]]},
            {
                "Empty": {
                    "status": "empty-displayed-tile",
                    "reason": "zero data rows",
                }
            },
        )
        self.addCleanup(setattr, collector, "collect", original_collect)

        code = collector.main(
            [
                "--plan",
                str(plan_path),
                "--workbook-id",
                "wb",
                "--workbook-spec",
                str(spec_path),
                "--out",
                str(out_path),
                "--drift-warn-minutes",
                "0",
            ]
        )

        self.assertEqual(1, code)
        artifact = json.loads(out_path.read_text(encoding="utf-8"))
        self.assertEqual([["keep"]], artifact["Old"])
        self.assertEqual([["East", 10.0]], artifact["Good"])
        self.assertEqual("empty-displayed-tile", artifact["Empty"]["status"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
