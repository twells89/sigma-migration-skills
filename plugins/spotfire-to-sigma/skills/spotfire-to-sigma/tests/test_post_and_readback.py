#!/usr/bin/env python3
"""Offline census and server-ID remap tests."""

import copy
import json
import os
import sys
import unittest


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
sys.path.insert(0, SCRIPTS)

import post_and_readback  # noqa: E402


def dm_spec():
    return {
        "name": "Fixture model",
        "schemaVersion": 1,
        "pages": [{
            "id": "model",
            "name": "Model",
            "elements": [{
                "id": "local-sales",
                "kind": "table",
                "name": "Sales",
                "source": {
                    "kind": "warehouse-table",
                    "connectionId": "connection",
                    "path": ["ANALYTICS", "PUBLIC", "SALES"],
                },
                "columns": [
                    {
                        "id": "local-region",
                        "name": "Region",
                        "formula": "[SALES/REGION]",
                    },
                    {
                        "id": "local-revenue",
                        "name": "Revenue",
                        "formula": "Sum([SALES/REVENUE])",
                    },
                ],
            }],
        }],
    }


def remapped_readback():
    value = copy.deepcopy(dm_spec())
    element = value["pages"][0]["elements"][0]
    element["id"] = "server-element-sales"
    element["columns"][0]["id"] = "server-column-region"
    element["columns"][1]["id"] = "server-column-revenue"
    # Formula normalization must not make a stable-name census fail.
    element["columns"][1]["formula"] = "Sum( [SALES/REVENUE] )"
    return value


class PostAndReadbackTests(unittest.TestCase):
    def test_readback_remaps_element_and_column_ids(self):
        verdict = post_and_readback.verify_readback(
            dm_spec(), remapped_readback(), "datamodel"
        )
        self.assertTrue(verdict["pass"], verdict)
        self.assertEqual(
            "server-element-sales",
            verdict["element_ids"]["local-sales"],
        )
        self.assertEqual(
            "server-element-sales",
            verdict["element_ids"]["Sales"],
        )
        self.assertEqual(
            "server-column-revenue",
            verdict["column_ids"]["local-sales/local-revenue"],
        )
        self.assertEqual(1, verdict["census"]["matched_elements"])
        self.assertEqual(2, verdict["census"]["expected_columns"])

    def test_readback_rejects_dropped_column(self):
        readback = remapped_readback()
        readback["pages"][0]["elements"][0]["columns"].pop()
        verdict = post_and_readback.verify_readback(
            dm_spec(), readback, "datamodel"
        )
        self.assertFalse(verdict["pass"])
        self.assertEqual(
            {"Sales": ["Revenue"]}, verdict["dropped_columns"]
        )

    def test_readback_rejects_stale_formula_and_source(self):
        readback = remapped_readback()
        element = readback["pages"][0]["elements"][0]
        element["columns"][1]["formula"] = "Sum([SALES/OLD_REVENUE])"
        verdict = post_and_readback.verify_readback(
            dm_spec(), readback, "datamodel"
        )
        self.assertFalse(verdict["pass"])
        self.assertTrue(any(
            "formula changed" in mismatch
            for mismatch in verdict["semantic_mismatches"]
        ))
        readback = remapped_readback()
        readback["pages"][0]["elements"][0]["source"]["path"][-1] = "OLD_SALES"
        verdict = post_and_readback.verify_readback(
            dm_spec(), readback, "datamodel"
        )
        self.assertFalse(verdict["pass"])
        self.assertEqual(["Sales"], verdict["missing_elements"])

    def test_readback_requires_relationships_and_remapped_keys(self):
        posted = dm_spec()
        posted_element = posted["pages"][0]["elements"][0]
        posted_element["relationships"] = [{
            "id": "local-relationship",
            "name": "Sales",
            "targetElementId": "local-sales",
            "keys": [{
                "sourceColumnId": "local-region",
                "targetColumnId": "local-region",
            }],
        }]
        readback = remapped_readback()
        actual_element = readback["pages"][0]["elements"][0]
        actual_element["relationships"] = [{
            "id": "server-relationship",
            "name": "Sales",
            "targetElementId": "server-element-sales",
            "keys": [{
                "sourceColumnId": "server-column-region",
                "targetColumnId": "server-column-region",
            }],
        }]
        verdict = post_and_readback.verify_readback(
            posted, readback, "datamodel"
        )
        self.assertTrue(verdict["pass"], verdict)
        actual_element["relationships"] = []
        verdict = post_and_readback.verify_readback(
            posted, readback, "datamodel"
        )
        self.assertFalse(verdict["pass"])
        self.assertTrue(any(
            "relationships" in mismatch
            for mismatch in verdict["semantic_mismatches"]
        ))

    def test_readback_rejects_type_error_from_columns_endpoint(self):
        workbook = {
            "name": "Fixture",
            "document": {
                "schemaVersion": 1,
                "kind": "workbook",
                "pages": [{"id": "page", "name": "Page"}],
                "elements": [{
                    "id": "chart",
                    "kind": "bar-chart",
                    "name": "Revenue",
                    "columns": [{
                        "id": "value",
                        "name": "Revenue",
                        "formula": "Sum([Source/Revenue])",
                    }],
                }],
                "layout": (
                    '<Page id="page"><Element elementId="chart" '
                    'gridColumn="1 / 25" gridRow="1 / 9"/></Page>'
                ),
            },
        }
        readback = copy.deepcopy(workbook)
        verdict = post_and_readback.verify_readback(
            workbook,
            readback,
            "workbook",
            endpoint_columns=[{
                "elementId": "chart",
                "columnId": "value",
                "name": "Revenue",
                "type": {"type": "error"},
                "message": "dependency not found",
            }],
        )
        self.assertFalse(verdict["pass"])
        self.assertEqual(1, len(verdict["error_columns"]))
        self.assertEqual(
            "dependency not found", verdict["error_columns"][0]["error"]
        )

    def test_readback_requires_control_semantics(self):
        workbook = {
            "name": "Fixture controls",
            "document": {
                "schemaVersion": 1,
                "kind": "workbook",
                "pages": [{"id": "page", "name": "Page"}],
                "elements": [{
                    "id": "control",
                    "kind": "control",
                    "name": "Region",
                    "controlId": "Region",
                    "controlType": "list",
                    "mode": "include",
                    "selectionMode": "multiple",
                    "includeNulls": "when-no-value-is-selected",
                    "values": ["East"],
                }],
                "layout": (
                    '<Page id="page"><Element elementId="control" '
                    'gridColumn="1 / 25" gridRow="1 / 4"/></Page>'
                ),
            },
        }
        readback = copy.deepcopy(workbook)
        verdict = post_and_readback.verify_readback(
            workbook, readback, "workbook"
        )
        self.assertTrue(verdict["pass"], verdict)
        del readback["document"]["elements"][0]["selectionMode"]
        verdict = post_and_readback.verify_readback(
            workbook, readback, "workbook"
        )
        self.assertFalse(verdict["pass"])
        self.assertIn(
            "Region.selectionMode changed on readback",
            verdict["semantic_mismatches"],
        )

    def test_workbook_post_verifies_before_write_without_real_transport(self):
        workbook = {
            "name": "Fixture",
            "document": {
                "schemaVersion": 1,
                "kind": "workbook",
                "pages": [{"id": "page", "name": "Page"}],
                "elements": [],
                "layout": '<Page id="page"></Page>',
            },
        }

        class FakeApi:
            def __init__(self):
                self.calls = []

            def request(self, method, path, body=None):
                self.calls.append((method, path, body))
                if path == "/v2/workbooks/spec/verify":
                    self.assert_document(body)
                    return {"valid": True}
                if method == "post":
                    return {"workbookId": "server-workbook"}
                if path == "/v2/workbooks/server-workbook/spec":
                    return copy.deepcopy(workbook)
                if path.startswith("/v2/workbooks/server-workbook/columns"):
                    return {"entries": []}
                raise AssertionError((method, path))

            @staticmethod
            def assert_document(body):
                parsed = json.loads(body)
                if "document" not in parsed:
                    raise AssertionError("workbook payload was not wrapped")

        api = FakeApi()
        object_id, _response, _readback, verdict = (
            post_and_readback.post_and_readback(
                "workbook", workbook, api=api
            )
        )
        self.assertEqual("server-workbook", object_id)
        self.assertTrue(verdict["pass"])
        self.assertEqual(
            [
                "/v2/workbooks/spec/verify",
                "/v2/workbooks/spec",
                "/v2/workbooks/server-workbook/spec",
                "/v2/workbooks/server-workbook/columns?limit=1000",
            ],
            [path for _method, path, _body in api.calls],
        )


if __name__ == "__main__":
    unittest.main()
