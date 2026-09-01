import copy
import importlib.util
import json
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "post-and-readback.py"
spec = importlib.util.spec_from_file_location("post_and_readback", SCRIPT)
post_and_readback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(post_and_readback)


def dm_spec():
    return {
        "name": "Orders",
        "folderId": "folder",
        "schemaVersion": 1,
        "pages": [
            {
                "id": "page",
                "name": "Main",
                "elements": [
                    {
                        "id": "fact",
                        "kind": "table",
                        "name": "ORDER_FACT",
                        "source": {
                            "kind": "warehouse-table",
                            "connectionId": "connection",
                            "path": ["CSA", "TJ", "ORDER_FACT"],
                        },
                        "columns": [
                            {
                                "id": "revenue",
                                "name": "Net Revenue",
                                "formula": "[ORDER_FACT/NET_REVENUE]",
                            }
                        ],
                        "relationships": [
                            {
                                "id": "rel",
                                "targetElementId": "dim",
                                "keys": [],
                                "derivedVia": "equivalence-proof",
                            }
                        ],
                    }
                ],
            }
        ],
    }


class FakeApi:
    def __init__(self, readback):
        self.readback = readback
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path, json.loads(body) if body else None))
        if method == "post" and path.endswith("/spec"):
            return {"dataModelId": "dm-1", "workbookId": "wb-1"}
        if path == "/v2/workbooks/spec/verify":
            return {"valid": True}
        if method == "get":
            return self.readback
        return {"success": True}


class PostAndReadbackTest(unittest.TestCase):
    def test_datamodel_strips_provenance_and_reads_back(self):
        draft = dm_spec()
        api = FakeApi(copy.deepcopy(draft))
        object_id, _, _, result = post_and_readback.post_and_readback(
            "datamodel", draft, api=api
        )
        self.assertEqual("dm-1", object_id)
        posted = api.calls[0][2]
        relationship = posted["pages"][0]["elements"][0]["relationships"][0]
        self.assertNotIn("derivedVia", relationship)
        self.assertTrue(result["pass"], result)

    def test_dropped_column_fails_census(self):
        draft = dm_spec()
        readback = copy.deepcopy(draft)
        readback["pages"][0]["elements"][0]["columns"] = []
        result = post_and_readback.verify_census(draft, readback, "datamodel")
        self.assertFalse(result["pass"])
        self.assertEqual(
            ["Net Revenue"],
            result["dropped_columns"]["ORDER_FACT"],
        )

    def test_workbook_create_calls_server_verify_first(self):
        workbook = {
            "name": "Workbook",
            "folderId": "folder",
            "document": {
                "schemaVersion": 1,
                "kind": "workbook",
                "pages": [{"id": "p", "name": "Page"}],
                "elements": [],
            },
        }
        api = FakeApi(copy.deepcopy(workbook))
        object_id, _, _, result = post_and_readback.post_and_readback(
            "workbook", workbook, api=api
        )
        self.assertEqual("wb-1", object_id)
        self.assertEqual("/v2/workbooks/spec/verify", api.calls[0][1])
        self.assertTrue(result["pass"])

    def test_workbook_readback_keys_elements_by_preserved_id(self):
        posted = {
            "document": {
                "elements": [
                    {"id": "text-1", "kind": "text", "name": "Text", "body": "Title"}
                ]
            }
        }
        readback = {
            "document": {
                "elements": [
                    {"id": "text-1", "kind": "text", "body": "Title"}
                ]
            }
        }
        result = post_and_readback.verify_census(posted, readback, "workbook")
        self.assertTrue(result["pass"], result)


if __name__ == "__main__":
    unittest.main()
