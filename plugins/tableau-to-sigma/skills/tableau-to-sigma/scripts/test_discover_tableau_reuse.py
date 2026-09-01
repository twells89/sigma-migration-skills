import importlib.util
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "discover-tableau-reuse.py"
spec = importlib.util.spec_from_file_location("discover_tableau_reuse", SCRIPT)
reuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)


def source_artifacts():
    model = {
        "pages": [
            {
                "elements": [
                    {
                        "name": "ORDER_FACT",
                        "source": {
                            "kind": "warehouse-table",
                            "path": ["ACME", "SALES", "ORDER_FACT"],
                        },
                        "columns": [
                            {"name": "ORDER_ID"},
                            {"name": "REGION"},
                            {"name": "SALES"},
                            {"name": "UNUSED"},
                        ],
                    }
                ]
            }
        ]
    }
    layout = [
        {
            "dashboard": "Executive",
            "zones": [
                {
                    "kind": "chart",
                    "chart_kind": "bar",
                    "caption": "Sales by Region",
                    "rows_shelf": {
                        "fields": [
                            {"guid": "SALES", "role": "measure", "derivation": "sum"}
                        ]
                    },
                    "cols_shelf": {
                        "fields": [
                            {"guid": "REGION", "role": "dim", "derivation": "none"}
                        ]
                    },
                },
                {
                    "kind": "filter",
                    "filter_column_caption": "Region",
                    "rows_shelf": {"fields": []},
                    "cols_shelf": {"fields": []},
                },
            ],
        }
    ]
    meta = {
        "columns_by_guid": {
            "REGION": {"caption": "Region"},
            "SALES": {"caption": "Sales"},
        }
    }
    return model, layout, meta


def dm_spec(*, table=("ACME", "SALES", "ORDER_FACT"), columns=("REGION", "SALES")):
    return {
        "pages": [
            {
                "elements": [
                    {
                        "source": {"kind": "warehouse-table", "path": list(table)},
                        "columns": [{"name": name} for name in columns],
                    }
                ]
            }
        ]
    }


def workbook_spec(dm_id="dm-good", *, visual_name="Sales by Region"):
    return {
        "name": "Executive",
        "document": {
            "pages": [
                {"id": "data", "name": "Data", "visibility": "hidden"},
                {"id": "main", "name": "Executive"},
            ],
            "elements": [
                {
                    "id": "master",
                    "kind": "table",
                    "source": {
                        "kind": "data-model",
                        "dataModelId": dm_id,
                        "elementId": "fact",
                    },
                },
                {"id": "chart", "kind": "bar-chart", "name": visual_name},
                {"id": "control", "kind": "control", "name": "Region"},
            ],
        },
    }


class FakeApi:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def request(self, method, path, **_kwargs):
        self.calls.append((method, path))
        key = path
        if path.startswith("/v2/dataModels?"):
            key = "/v2/dataModels"
        elif path.startswith("/v2/workbooks?"):
            key = "/v2/workbooks"
        value = self.routes[key]
        if isinstance(value, Exception):
            raise value
        return value


class DiscoverTableauReuseTest(unittest.TestCase):
    def setUp(self):
        model, layout, meta = source_artifacts()
        self.signature = reuse.derive_signature(model, layout, meta)

    def test_signature_uses_layout_references_not_every_converter_column(self):
        self.assertEqual(
            ["REGION", "SALES"],
            self.signature["referenced_columns"],
        )
        self.assertEqual(
            ["ACME.SALES.ORDER_FACT"],
            self.signature["warehouse_tables"],
        )
        self.assertEqual(["Executive"], self.signature["dashboard_names"])
        self.assertEqual(
            ["bar:SALESBYREGION", "control:REGION"],
            self.signature["visuals"],
        )
        self.assertEqual("layout", self.signature["evidence"]["column_basis"])

    def test_unique_compatible_dm_and_workbook_are_selected_with_gets_only(self):
        api = FakeApi(
            {
                "/v2/dataModels": {
                    "entries": [
                        {"dataModelId": "dm-good", "name": "Orders"},
                        {"dataModelId": "dm-partial", "name": "Orders old"},
                    ]
                },
                "/v2/dataModels/dm-good/spec": dm_spec(),
                "/v2/dataModels/dm-partial/spec": dm_spec(columns=("REGION",)),
                "/v2/workbooks": {
                    "entries": [
                        {"workbookId": "wb-good", "name": "Executive"},
                        {"workbookId": "wb-wrong", "name": "Executive copy"},
                    ]
                },
                "/v2/workbooks/wb-good/spec": workbook_spec(),
                "/v2/workbooks/wb-wrong/spec": workbook_spec(
                    visual_name="Different chart"
                ),
            }
        )
        result = reuse.discover(self.signature, api=api)
        self.assertEqual("selected", result["status"])
        self.assertEqual("dm-good", result["data_model"]["selected_id"])
        self.assertEqual("wb-good", result["workbook"]["selected_id"])
        self.assertTrue(all(method == "get" for method, _path in api.calls))
        self.assertFalse(
            any(
                method in {"post", "put", "patch", "delete"}
                for method, _path in api.calls
            )
        )

    def test_two_fully_compatible_data_models_fail_closed_and_emit_both(self):
        api = FakeApi(
            {
                "/v2/dataModels": {
                    "entries": [
                        {"dataModelId": "dm-a", "name": "Orders A"},
                        {"dataModelId": "dm-b", "name": "Orders B"},
                    ]
                },
                "/v2/dataModels/dm-a/spec": dm_spec(),
                "/v2/dataModels/dm-b/spec": dm_spec(),
            }
        )
        result = reuse.discover(
            self.signature,
            mode="data-model",
            api=api,
        )
        self.assertEqual("no_selection", result["status"])
        self.assertIsNone(result["data_model"]["selected_id"])
        self.assertIn("refusing to break the tie", result["data_model"]["rationale"])
        self.assertEqual(
            {"dm-a", "dm-b"},
            {item["id"] for item in result["data_model"]["candidates"]},
        )

    def test_explicit_ids_are_read_back_and_selected_only_when_compatible(self):
        compatible_api = FakeApi(
            {
                "/v2/dataModels/dm-explicit/spec": dm_spec(),
                "/v2/workbooks/wb-explicit/spec": workbook_spec("dm-explicit"),
            }
        )
        result = reuse.discover(
            self.signature,
            data_model_id="dm-explicit",
            workbook_id="wb-explicit",
            api=compatible_api,
        )
        self.assertEqual("selected", result["status"])
        self.assertEqual(
            [
                ("get", "/v2/dataModels/dm-explicit/spec"),
                ("get", "/v2/workbooks/wb-explicit/spec"),
            ],
            compatible_api.calls,
        )

        incompatible_api = FakeApi(
            {"/v2/dataModels/dm-explicit/spec": dm_spec(columns=("REGION",))}
        )
        result = reuse.discover(
            self.signature,
            mode="data-model",
            data_model_id="dm-explicit",
            api=incompatible_api,
        )
        self.assertEqual("no_selection", result["status"])
        self.assertIsNone(result["data_model"]["selected_id"])
        self.assertEqual(
            ["SALES"],
            result["data_model"]["candidates"][0]["missing_columns"],
        )

    def test_spec_fetch_failure_makes_pool_incomplete_and_blocks_selection(self):
        api = FakeApi(
            {
                "/v2/dataModels": {
                    "entries": [
                        {"dataModelId": "dm-good", "name": "Orders"},
                        {"dataModelId": "dm-hidden", "name": "Unreadable"},
                    ]
                },
                "/v2/dataModels/dm-good/spec": dm_spec(),
                "/v2/dataModels/dm-hidden/spec": RuntimeError("forbidden"),
            }
        )
        result = reuse.discover(
            self.signature,
            mode="data-model",
            api=api,
        )
        self.assertEqual("no_selection", result["status"])
        self.assertIn("uniqueness cannot be proven", result["data_model"]["rationale"])
        self.assertEqual(
            "dm-hidden",
            result["data_model"]["pool"]["spec_failures"][0]["id"],
        )

    def test_duplicate_expected_visuals_are_counted_not_collapsed(self):
        signature = {
            **self.signature,
            "visuals": ["bar:SALESBYREGION", "bar:SALESBYREGION"],
        }
        scored = reuse.score_workbook(
            signature,
            {"workbookId": "wb", "name": "Executive"},
            workbook_spec(),
            "dm-good",
        )
        self.assertEqual("partial", scored["match"])
        self.assertEqual(0.5, scored["visual_match"])
        self.assertEqual(["bar:SALESBYREGION"], scored["missing_visuals"])

    def test_suffix_qualified_table_match_is_compatible(self):
        candidate = {"dataModelId": "dm", "name": "Orders"}
        scored = reuse.score_data_model(
            self.signature,
            candidate,
            dm_spec(table=("SALES", "ORDER_FACT")),
        )
        self.assertEqual("compatible", scored["match"])
        self.assertEqual(1.0, scored["table_match"])


if __name__ == "__main__":
    unittest.main()
