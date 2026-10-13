#!/usr/bin/env python3
"""Offline converter tests; no credentials or third-party packages."""
import copy
import json
import os
import re
import sys
import unittest
from xml.dom import minidom


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SKILL, "scripts"))
import convert  # noqa: E402
import validate_manifest  # noqa: E402


def load(name):
    with open(os.path.join(SKILL, "fixtures", name), encoding="utf-8") as handle:
        return json.load(handle)


class ConvertTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = load("spotfire-manifest.json")
        cls.source_map = load("source-map.json")
        errors, warnings = validate_manifest.validate_manifest(cls.manifest)
        if errors or warnings:
            raise AssertionError(
                "rich fixture is not authoritative manifest v1: %r / %r" %
                (errors, warnings)
            )
        cls.result = convert.convert_manifest(cls.manifest, cls.source_map)

    def test_data_model_uses_only_explicit_landed_sources(self):
        elements = self.result["data_model"]["pages"][0]["elements"]
        self.assertEqual(4, len(elements))
        self.assertTrue(all(
            element["source"]["kind"] == "warehouse-table"
            for element in elements
        ))
        self.assertEqual(
            {
                ("ANALYTICS", "SPOTFIRE", "SALES"),
                ("ANALYTICS", "SPOTFIRE", "CUSTOMERS"),
                ("ANALYTICS", "SPOTFIRE", "TARGETS"),
                ("ANALYTICS", "SPOTFIRE", "CUSTOMER_SCORES"),
            },
            {tuple(element["source"]["path"]) for element in elements},
        )
        sales = next(element for element in elements if element["name"] == "Sales")
        margin = next(column for column in sales["columns"]
                      if column["name"] == "Margin")
        self.assertIn("If(", margin["formula"])
        self.assertEqual(1, len(sales.get("relationships", [])))

    def test_missing_source_map_fails_before_emission(self):
        source_map = copy.deepcopy(self.source_map)
        del source_map["tables"]["table:scores"]
        with self.assertRaisesRegex(
                convert.SourceMapError, "Scores.*explicit source-map"):
            convert.convert_manifest(self.manifest, source_map)

    def test_incomplete_target_mapping_fails_closed(self):
        source_map = {
            "tables": {
                table["source_id"]: {
                    "table": table["source_id"].split(":")[-1].upper()
                }
                for table in self.manifest["model"]["tables"]
            }
        }
        with self.assertRaisesRegex(
                convert.SourceMapError, "connectionId is missing"):
            convert.convert_manifest(self.manifest, source_map)

    def test_workbook_is_wrapped_flat_and_has_all_native_visuals(self):
        workbook = self.result["workbook"]
        self.assertIn("document", workbook)
        self.assertNotIn("pages", workbook)
        document = workbook["document"]
        self.assertTrue(all("elements" not in page
                            for page in document["pages"]))
        kinds = [element["kind"] for element in document["elements"]]
        for kind in (
            "table", "pivot-table", "kpi-chart", "bar-chart", "line-chart",
            "area-chart", "combo-chart", "pie-chart", "donut-chart",
            "scatter-chart",
        ):
            self.assertIn(kind, kinds)
        self.assertNotIn("Spotfire Mod", [
            element.get("name") for element in document["elements"]
        ])
        charts = [
            element for element in document["elements"]
            if element["kind"].endswith("-chart")
        ]
        self.assertTrue(all(
            element["source"]["elementId"].startswith(
                "scatter-source-" if element["kind"] == "scatter-chart"
                else "source-"
            )
            for element in charts
        ))
        scatter = next(
            element for element in charts
            if element["kind"] == "scatter-chart"
        )
        self.assertIn("groupingId", scatter["source"])
        grouped_source = next(
            element for element in document["elements"]
            if element["id"] == scatter["source"]["elementId"]
        )
        self.assertFalse(grouped_source["visibleAsSource"])
        self.assertTrue(grouped_source["groupings"])
        self.assertNotIn("colorBy", json.dumps(document))

    def test_filters_become_controls_and_unbound_properties_stay_loud(self):
        controls = [
            element for element in self.result["workbook"]["document"]["elements"]
            if element["kind"] == "control"
        ]
        self.assertEqual(2, len(controls))
        self.assertEqual(
            len(controls), len({control["controlId"] for control in controls})
        )
        self.assertEqual(
            {"list", "date-range"},
            {control["controlType"] for control in controls},
        )
        region = next(control for control in controls
                      if control["name"] == "Region")
        self.assertEqual("table", region["filters"][0]["source"]["kind"])
        self.assertNotIn("Forecast Scenario", {
            control["name"] for control in controls
        })
        self.assertIn(
            "SPOTFIRE-DOCUMENT-PROPERTY-CONSUMER-REVIEW",
            {gap["code"] for gap in self.result["gaps"]},
        )

    def test_layout_is_well_formed_complete_and_24_columns(self):
        document = self.result["workbook"]["document"]
        layout = document["layout"]
        minidom.parseString("<root>%s</root>" % layout.split("?>", 1)[1])
        placed = re.findall(
            r'<Element elementId="([^"]+)" gridColumn="(\d+) / (\d+)" '
            r'gridRow="(\d+) / (\d+)"/>',
            layout,
        )
        ids = [element["id"] for element in document["elements"]]
        self.assertEqual(sorted(ids), sorted(row[0] for row in placed))
        self.assertEqual(len(ids), len({row[0] for row in placed}))
        self.assertTrue(all(
            1 <= int(c0) < int(c1) <= 25
            for _element, c0, c1, _r0, _r1 in placed
        ))

    def test_pixel_and_normalized_bounds_use_same_grid(self):
        normalized = convert.normalized_grid_bounds(
            {"bounds": {"x": 0.25, "y": 0.5, "width": 0.5, "height": 0.25}}
        )
        pixels = convert.normalized_grid_bounds(
            {"bounds": {"x": 300, "y": 400, "width": 600, "height": 200}},
            page_width=1200, page_height=800,
        )
        self.assertEqual(normalized, pixels)

    def test_unsupported_features_are_structured_and_loud(self):
        codes = {gap["code"] for gap in self.result["gaps"]}
        self.assertTrue({
            "SPOTFIRE-VISUAL-UNSUPPORTED",
            "SPOTFIRE-MOD-UNSUPPORTED",
            "SPOTFIRE-SCRIPT-UNSUPPORTED",
            "SPOTFIRE-DATA-FUNCTION-UNSUPPORTED",
            "SPOTFIRE-SECURITY-REVIEW",
            "SPOTFIRE-EXPORT-ERROR",
        } <= codes)

    def test_relation_column_id_arrays_emit_every_key_pair(self):
        manifest = copy.deepcopy(self.manifest)
        relation = manifest["model"]["relations"][0]
        relation["left"]["column_ids"].append("column:sales.customer-id")
        relation["right"]["column_ids"].append(
            "column:customers.customer-id"
        )
        result = convert.convert_manifest(manifest, self.source_map)
        sales = next(
            element
            for element in result["data_model"]["pages"][0]["elements"]
            if element["name"] == "Sales"
        )
        self.assertEqual(2, len(sales["relationships"][0]["keys"]))

    def test_cross_table_calculated_column_fails_closed(self):
        manifest = copy.deepcopy(self.manifest)
        sales = manifest["model"]["tables"][0]
        sales["columns"].append({
            "source_id": "column:sales.segment",
            "name": "Segment from customer",
            "unsupported": [],
            "export_errors": [],
            "data_type": "string",
            "spotfire_data_type": "String",
            "external_name": None,
            "calculated": True,
            "expression": "[Customers].[Segment]",
            "properties": {},
        })
        result = convert.convert_manifest(manifest, self.source_map)
        sales_dm = next(
            element
            for element in result["data_model"]["pages"][0]["elements"]
            if element["name"] == "Sales"
        )
        self.assertNotIn(
            "Segment from customer",
            {column["name"] for column in sales_dm["columns"]},
        )
        self.assertIn(
            "SPOTFIRE-CROSS-TABLE-CALC-UNSUPPORTED",
            {gap["code"] for gap in result["gaps"]},
        )

    def test_authoritative_nested_manifest_shape_is_consumed(self):
        with open(
            os.path.join(HERE, "fixtures", "valid_manifest.json"),
            encoding="utf-8",
        ) as handle:
            manifest = json.load(handle)
        source_map = {
            "connectionId": "connection",
            "database": "ANALYTICS",
            "schema": "PUBLIC",
            "tables": {"table:sales": {"table": "SALES"}},
        }
        result = convert.convert_manifest(manifest, source_map)
        element = result["data_model"]["pages"][0]["elements"][0]
        self.assertEqual("Sales", element["name"])
        self.assertEqual(
            ["ANALYTICS", "PUBLIC", "SALES"], element["source"]["path"]
        )
        revenue = next(column for column in element["columns"]
                       if column["name"] == "Revenue")
        self.assertEqual("[SALES/REVENUE]", revenue["formula"])
        self.assertEqual("Commerce (from Spotfire)", result["workbook"]["name"])
        self.assertTrue({
            "SPOTFIRE-SCRIPT-UNSUPPORTED",
            "SPOTFIRE-DATA-FUNCTION-UNSUPPORTED",
            "SPOTFIRE-MOD-UNSUPPORTED",
            "SPOTFIRE-SECURITY-REVIEW",
            "SPOTFIRE-BOOKMARK-UNSUPPORTED",
        } <= {gap["code"] for gap in result["gaps"]})

    def test_exporter_provenance_map_is_not_mistaken_for_warehouse_map(self):
        with open(
            os.path.join(HERE, "fixtures", "valid_manifest.json"),
            encoding="utf-8",
        ) as handle:
            manifest = json.load(handle)
        with open(
            os.path.join(
                SKILL,
                "refs",
                "spotfire-manifest-provenance.example.json",
            ),
            encoding="utf-8",
        ) as handle:
            provenance = json.load(handle)
        with self.assertRaisesRegex(
                convert.SourceMapError, "explicit source-map entry"):
            convert.convert_manifest(
                manifest, provenance,
                connection_id="connection", database="D", schema="S",
            )


if __name__ == "__main__":
    unittest.main()
