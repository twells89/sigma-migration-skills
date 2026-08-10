#!/usr/bin/env python3
"""Offline smoke: workbook builders must emit the released code_rep wire shape."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts" / "lib"
sys.path.insert(0, str(LIB))

import code_rep  # noqa: E402
import workbook_wire  # noqa: E402


class TestWorkbookWire(unittest.TestCase):
    def test_wire_wraps_document_and_flattens_elements(self):
        draft = {
            "name": "Forecast Entry",
            "folderId": "00000000-0000-0000-0000-000000000001",
            "description": "test",
            "schemaVersion": 1,
            "pages": [{
                "id": "entryPage",
                "name": "Entry",
                "elements": [
                    {"id": "inputTable", "kind": "input-table", "name": "Entry"},
                    {"id": "spine", "kind": "table", "name": "Spine"},
                ],
            }],
        }
        body = workbook_wire.wire_workbook(draft)

        self.assertIn("document", body)
        self.assertNotIn("pages", body)
        self.assertNotIn("elements", body)
        self.assertNotIn("layout", body)
        self.assertEqual(body["name"], "Forecast Entry")
        self.assertEqual(body["folderId"], draft["folderId"])

        doc = body["document"]
        self.assertEqual(doc["schemaVersion"], 1)
        self.assertEqual(doc["kind"], "workbook")
        self.assertEqual([p["id"] for p in doc["pages"]], ["entryPage"])
        self.assertNotIn("elements", doc["pages"][0])
        self.assertEqual([e["id"] for e in doc["elements"]], ["inputTable", "spine"])
        self.assertIn("<Page", doc["layout"])
        self.assertIn('id="entryPage"', doc["layout"])
        self.assertIn('elementId="inputTable"', doc["layout"])
        self.assertIn("<Element", doc["layout"])
        self.assertNotIn("<LayoutElement", doc["layout"])

        # Round-trip through the shared adapter stays nested.
        again = code_rep.wrap(code_rep.document(body), extra=code_rep.metadata(body))
        self.assertEqual(again["document"]["elements"][0]["id"], "inputTable")

    def test_already_wrapped_is_idempotent_enough(self):
        draft = {
            "name": "X",
            "document": {
                "schemaVersion": 1,
                "kind": "workbook",
                "pages": [{"id": "p1", "name": "P"}],
                "elements": [{"id": "e1", "kind": "table"}],
                "layout": '<Page id="p1"><Element elementId="e1"/></Page>',
            },
        }
        body = workbook_wire.wire_workbook(draft)
        self.assertEqual(body["document"]["elements"][0]["id"], "e1")
        self.assertIn("<Element", body["document"]["layout"])


if __name__ == "__main__":
    unittest.main()
