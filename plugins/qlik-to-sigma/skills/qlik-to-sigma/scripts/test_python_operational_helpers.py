#!/usr/bin/env python3
"""Credential-free tests for the Python Qlik operational helpers."""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path

import cleanup_orphan_workbooks
import control_lint
import find_or_pick_dm
import flip_gate
import layout_lint
import preflight_warehouse
import put_layout
import record_visual_check
import render_integrity
import verify_anchors


def workbook(elements: list[dict], layout: str) -> dict:
    return {
        "document": {
            "schemaVersion": 1,
            "kind": "workbook",
            "pages": [{"id": "page-1", "name": "Overview"}],
            "elements": elements,
            "layout": layout,
        }
    }


class WarehousePreflightTests(unittest.TestCase):
    def test_resolves_catalog_case_aliases_and_expression_inputs(self) -> None:
        reconcile = [
            {
                "qlikTable": "Orders",
                "sourceTable": "orders",
                "fields": [
                    {
                        "qlikField": "Customer",
                        "realColumn": "customer_id",
                        "isExpression": False,
                    },
                    {
                        "qlikField": "Customer Label",
                        "realColumn": "Upper(Customer)",
                        "isExpression": True,
                        "expressionColumns": ["Customer"],
                    },
                ],
            }
        ]
        resolved, report = preflight_warehouse.preflight_tables(
            reconcile,
            connection_id="conn",
            database="Analytics",
            schema="Public",
            catalog_paths=[
                {
                    "connectionId": "conn",
                    "path": ["ANALYTICS", "PUBLIC", "ORDERS"],
                }
            ],
            lookup=lambda _connection, _path: {
                "kind": "table",
                "inodeId": "inode-1",
            },
            list_columns=lambda _inode: [{"name": "CUSTOMER_ID"}],
        )
        self.assertEqual([], report["errors"])
        self.assertEqual("ANALYTICS.PUBLIC.ORDERS", resolved[0]["sourceTable"])
        self.assertEqual("CUSTOMER_ID", resolved[0]["fields"][0]["realColumn"])
        self.assertEqual(
            ["customer_id"],
            resolved[0]["fields"][1]["expressionColumnsResolved"],
        )

    def test_rejects_ambiguous_table_leaf(self) -> None:
        path, error = preflight_warehouse.path_for_table(
            ["DB", "PUBLIC", "ORDERS"],
            "conn",
            [
                {"connectionId": "conn", "path": ["DB1", "S1", "ORDERS"]},
                {"connectionId": "conn", "path": ["DB2", "S2", "ORDERS"]},
            ],
        )
        self.assertIsNone(path)
        self.assertIn("ambiguous", error or "")


class WorkbookLintTests(unittest.TestCase):
    def test_render_integrity_requires_a_chart_value_binding(self) -> None:
        bad = workbook(
            [
                {
                    "id": "chart-1",
                    "kind": "bar-chart",
                    "name": "Revenue",
                    "columns": [{"id": "category", "formula": "[Data/Region]"}],
                }
            ],
            '<Page id="page-1"><Element elementId="chart-1" '
            'gridColumn="1 / 25" gridRow="1 / 9"/></Page>',
        )
        good = workbook(
            [
                {
                    "id": "chart-1",
                    "kind": "bar-chart",
                    "name": "Revenue",
                    "columns": [
                        {"id": "category", "formula": "[Data/Region]"},
                        {"id": "value", "formula": "Sum([Data/Revenue])"},
                    ],
                }
            ],
            '<Page id="page-1"><Element elementId="chart-1" '
            'gridColumn="1 / 25" gridRow="1 / 9"/></Page>',
        )
        self.assertEqual("FAIL", render_integrity.lint(bad)["status"])
        self.assertEqual("PASS", render_integrity.lint(good)["status"])

    def test_layout_lint_flags_empty_band(self) -> None:
        spec = workbook(
            [{"id": "band-1", "kind": "container", "name": "Main"}],
            '<Page id="page-1"><Container elementId="band-1" '
            'gridColumn="1 / 25" gridRow="1 / 10"></Container></Page>',
        )
        violations = layout_lint.lint(spec)
        self.assertTrue(
            any("band under-filled" in violation for violation in violations),
            violations,
        )

    def test_control_lint_proves_reach_and_catches_dead_control(self) -> None:
        layout = (
            '<Page id="page-1">'
            '<Element elementId="master" gridColumn="1 / 25" gridRow="1 / 11"/>'
            '<Element elementId="chart" gridColumn="1 / 25" gridRow="11 / 19"/>'
            '<Element elementId="control" gridColumn="1 / 7" gridRow="19 / 21"/>'
            "</Page>"
        )
        elements = [
            {
                "id": "master",
                "kind": "table",
                "name": "Data",
                "columns": [{"id": "region", "formula": "[Source/Region]"}],
            },
            {
                "id": "chart",
                "kind": "bar-chart",
                "name": "Revenue",
                "source": {"kind": "table", "elementId": "master"},
                "columns": [
                    {"id": "region", "formula": "[Data/Region]"},
                    {"id": "revenue", "formula": "Sum([Data/Revenue])"},
                ],
            },
            {
                "id": "control",
                "kind": "control",
                "name": "Region",
                "controlId": "ctl-region",
                "controlType": "list",
                "filters": [
                    {
                        "source": {"kind": "table", "elementId": "master"},
                        "columnId": "region",
                    }
                ],
            },
        ]
        self.assertEqual([], control_lint.lint(workbook(elements, layout)))
        elements[-1] = {**elements[-1], "filters": []}
        violations = control_lint.lint(workbook(elements, layout))
        self.assertTrue(
            any("dead control" in violation for violation in violations),
            violations,
        )

    def test_layout_put_preserves_document_and_injects_idempotently(self) -> None:
        source = workbook(
            [{"id": "chart-1", "kind": "bar-chart", "name": "Revenue"}],
            '<Page id="page-1"/>',
        )
        xml = (
            '<Page id="page-1"><Container elementId="band-1" '
            'gridColumn="1 / 25" gridRow="1 / 10"/></Page>'
        )
        payload, count = put_layout.apply_layout(
            source,
            xml,
            {
                "page-1": [
                    {"id": "band-1", "kind": "container", "name": "Main"},
                    {"id": "chart-1", "kind": "bar-chart", "name": "Duplicate"},
                ],
                "missing-page": [
                    {"id": "ignored", "kind": "text", "name": "Ignored"}
                ],
            },
        )
        document = payload["document"]
        self.assertEqual(1, count)
        self.assertEqual(xml, document["layout"])
        self.assertEqual(
            ["chart-1", "band-1"],
            [element["id"] for element in document["elements"]],
        )


class DecisionAndAccountingHelperTests(unittest.TestCase):
    def test_flip_gate_classifies_probe_results(self) -> None:
        results = [
            {"control": "ok", "result": "PASS"},
            {"control": "skip", "result": "SKIP", "note": "date"},
        ]
        decision, information = flip_gate.decide(0, results)
        self.assertEqual("ok", decision)
        self.assertEqual(["ok"], information["passes"])
        self.assertEqual(0, flip_gate.derive_rc(results))
        self.assertEqual(
            "error",
            flip_gate.decide(1, [{"control": "x", "result": "SKIP"}])[0],
        )

    def test_dm_reuse_requires_a_full_column_superset_for_auto_pick(self) -> None:
        signature = {
            "app": "Orders",
            "warehouse_tables": ["DB.PUBLIC.ORDERS"],
            "referenced_columns": ["ORDER_ID", "REVENUE"],
            "measures": [],
        }
        candidates = find_or_pick_dm.score_candidates(
            signature,
            [
                {
                    "dm_id": "dm-complete",
                    "dm_name": "Orders",
                    "tables": ["DB.PUBLIC.ORDERS"],
                    "columns": ["ORDERID", "REVENUE", "REGION"],
                    "column_captions": {
                        "ORDERID": "ORDER_ID",
                        "REVENUE": "REVENUE",
                        "REGION": "REGION",
                    },
                    "metrics": [],
                    "raw_element_count": 1,
                }
            ],
        )
        decision = find_or_pick_dm.decide(
            signature,
            candidates,
            min_score=0.6,
            auto_pick=True,
            auto_pick_threshold=0.5,
            tie_window=0.05,
            pool_total=1,
            pool_fetched=1,
        )
        self.assertTrue(decision["auto_picked"])
        self.assertEqual("dm-complete", decision["recommended_dm_id"])
        self.assertEqual(["ORDER_ID", "REVENUE"], candidates[0]["shared_columns"])

    def test_single_workbook_cleanup_is_a_safe_noop(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workdir = Path(temporary)
            (workdir / "posted-workbooks.jsonl").write_text(
                json.dumps({"id": "wb-one", "name": "Only"}) + "\n",
                encoding="utf-8",
            )
            calls = []
            result = cleanup_orphan_workbooks.cleanup(
                workdir,
                "wb-one",
                dry_run=False,
                requester=lambda method, path: calls.append((method, path)),
                input_stream=io.StringIO(),
                output_stream=io.StringIO(),
                error_stream=io.StringIO(),
            )
            self.assertEqual(0, result)
            self.assertEqual([], calls)
            marker = json.loads(
                (workdir / "cleanup-marker.json").read_text(encoding="utf-8")
            )
            self.assertEqual("wb-one", marker["kept"])

    def test_visual_checklist_and_anchor_number_parsing(self) -> None:
        checklist = record_visual_check.parse_checklist(
            ",".join(
                f"{key}=pass" for key in record_visual_check.CHECKLIST_KEYS
            )
        )
        self.assertEqual(
            set(record_visual_check.CHECKLIST_KEYS), set(checklist or {})
        )
        with self.assertRaises(ValueError):
            record_visual_check.parse_checklist("palette_match=maybe")
        self.assertTrue(verify_anchors.matches("$1.2K", 1200.0))
        self.assertTrue(verify_anchors.matches("12.5%", 0.125))


if __name__ == "__main__":
    unittest.main()
