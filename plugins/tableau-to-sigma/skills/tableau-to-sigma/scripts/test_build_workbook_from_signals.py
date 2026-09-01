import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "build-workbook-from-signals.py"
PARSER = HERE / "parse-twb-layout.py"
ROOT = HERE.parents[4]
CORPUS_TWB = ROOT / "corpus" / "tableau" / "orders-overview" / "workbook-content.twb"

module_spec = importlib.util.spec_from_file_location("build_workbook_from_signals", SCRIPT)
builder_module = importlib.util.module_from_spec(module_spec)
sys.modules[module_spec.name] = builder_module
module_spec.loader.exec_module(builder_module)


def shelf(*fields):
    return {"fields": list(fields)}


def field(guid, role, derivation):
    value = {"guid": guid, "role": role, "derivation": derivation}
    if role == "measure":
        value["discrete"] = False
    return value


class BuildWorkbookFromSignalsTest(unittest.TestCase):
    def test_percentage_formats_use_number_kind(self):
        self.assertEqual(
            {"kind": "number", "formatString": ",.1%"},
            builder_module.sigma_format("p0.0%"),
        )

    def signals(self):
        meta = {
            "columns_by_guid": {
                "ORDER_DATE": {
                    "caption": "Order Date",
                    "datatype": "date",
                },
                "REGION": {"caption": "Region", "datatype": "string"},
                "SALES": {"caption": "Sales", "datatype": "real"},
            },
            "column_formats": {"Sales": "$#,##0.00"},
        }
        layout = [
            {
                "dashboard": "Executive Overview",
                "emit_page": True,
                "brand_palette": ["#336699", "#f06719"],
                "zones": [
                    {
                        "id": "root",
                        "kind": "container",
                        "x_pct": 0,
                        "y_pct": 0,
                        "w_pct": 100,
                        "h_pct": 100,
                    },
                    {
                        "id": "title",
                        "kind": "text",
                        "x_pct": 0,
                        "y_pct": 0,
                        "w_pct": 100,
                        "h_pct": 8,
                        "text_runs": [
                            {"text": "Executive Overview", "font_size": 20}
                        ],
                    },
                    {
                        "id": "date-filter",
                        "kind": "filter",
                        "x_pct": 0,
                        "y_pct": 8,
                        "w_pct": 30,
                        "h_pct": 8,
                        "filter_column_caption": "Order Date",
                        "filter_column_datatype": "date",
                    },
                    {
                        "id": "region-filter",
                        "kind": "filter",
                        "x_pct": 30,
                        "y_pct": 8,
                        "w_pct": 30,
                        "h_pct": 8,
                        "filter_column_caption": "Region",
                        "filter_column_datatype": "string",
                    },
                    {
                        "id": "sales-kpi",
                        "kind": "chart",
                        "chart_kind": "kpi",
                        "caption": "Total Sales",
                        "x_pct": 0,
                        "y_pct": 16,
                        "w_pct": 24,
                        "h_pct": 18,
                        "rows_shelf": shelf(field("SALES", "measure", "sum")),
                        "cols_shelf": shelf(),
                        "filters": [],
                    },
                    {
                        "id": "sales-bar",
                        "kind": "chart",
                        "chart_kind": "bar",
                        "caption": "Sales by Region",
                        "x_pct": 24,
                        "y_pct": 16,
                        "w_pct": 38,
                        "h_pct": 40,
                        "rows_shelf": shelf(field("SALES", "measure", "sum")),
                        "cols_shelf": shelf(field("REGION", "dim", "none")),
                        "filters": [],
                        "mark_labels_show": True,
                        "sort": {"direction": "DESC"},
                    },
                    {
                        "id": "sales-line",
                        "kind": "chart",
                        "chart_kind": "line",
                        "caption": "Monthly Sales",
                        "x_pct": 62,
                        "y_pct": 16,
                        "w_pct": 38,
                        "h_pct": 40,
                        "rows_shelf": shelf(field("SALES", "measure", "sum")),
                        "cols_shelf": shelf(field("ORDER_DATE", "dim", "tmn")),
                        "filters": [],
                    },
                ],
            }
        ]
        return layout, meta

    def build(self):
        layout, meta = self.signals()
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm-live",
            element_id="fact-live",
            folder_id="folder-live",
            data_model_element_name="FACT",
        )
        return instance.build()

    def test_builds_complete_flat_native_workbook_with_layout_last(self):
        spec, residues = self.build()
        self.assertEqual("complete", residues["status"])
        self.assertEqual([], residues["residues"])
        document = spec["document"]
        self.assertEqual("layout", list(document)[-1])
        self.assertTrue(all("elements" not in page for page in document["pages"]))

        elements = document["elements"]
        self.assertEqual(
            {
                "table",
                "text",
                "control",
                "kpi-chart",
                "bar-chart",
                "line-chart",
            },
            {element["kind"] for element in elements},
        )
        master = elements[0]
        self.assertEqual(
            {
                "kind": "data-model",
                "dataModelId": "dm-live",
                "elementId": "fact-live",
            },
            master["source"],
        )
        self.assertEqual(
            {
                "[FACT/Order Date]",
                "[FACT/Region]",
                "[FACT/Sales]",
            },
            {column["formula"] for column in master["columns"]},
        )

        kpi = next(element for element in elements if element["kind"] == "kpi-chart")
        self.assertEqual(
            "Sum([Master/Sales])",
            kpi["columns"][0]["formula"],
        )
        line = next(element for element in elements if element["kind"] == "line-chart")
        self.assertEqual(
            'DateTrunc("month", [Master/Order Date])',
            line["columns"][0]["formula"],
        )
        bar = next(element for element in elements if element["kind"] == "bar-chart")
        self.assertEqual({"labels": "shown"}, bar["dataLabel"])
        self.assertEqual(
            "descending",
            bar["xAxis"]["sort"]["direction"],
        )

        controls = [element for element in elements if element["kind"] == "control"]
        date_control = next(item for item in controls if item["name"] == "Order Date")
        list_control = next(item for item in controls if item["name"] == "Region")
        self.assertEqual("date-range", date_control["controlType"])
        self.assertEqual("between", date_control["mode"])
        self.assertEqual("list", list_control["controlType"])
        self.assertEqual("source", list_control["source"]["kind"])
        self.assertEqual("master", list_control["source"]["source"]["elementId"])

        builder_module.validate_spec(spec)
        placed = document["layout"].count("elementId=")
        self.assertEqual(len(elements), placed)
        self.assertLess(
            document["layout"].index('id="page-data"'),
            document["layout"].index('id="page-executive-overview'),
        )

    def test_unbound_field_blocks_instead_of_emitting_broken_chart(self):
        layout, meta = self.signals()
        chart = next(
            zone
            for zone in layout[0]["zones"]
            if zone.get("id") == "sales-line"
        )
        chart["cols_shelf"] = shelf(field("MISSING_DATE", "dim", "tmn"))
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
        )
        _spec, report = instance.build()
        self.assertEqual("blocked", report["status"])
        residue = next(
            item for item in report["residues"] if item["zoneId"] == "sales-line"
        )
        self.assertEqual("unbound-chart-field", residue["reasonCode"])
        self.assertEqual(["MISSING_DATE"], residue["signals"]["fields"])

    def test_user_aggregated_kpi_prefers_matching_data_model_metric(self):
        layout, meta = self.signals()
        meta["columns_by_guid"].update(
            {
                "PROFIT": {"caption": "Profit", "datatype": "real"},
                "MARGIN_CALC": {
                    "caption": "Margin Ratio",
                    "datatype": "real",
                    "formula": "SUM([PROFIT]) / SUM([SALES])",
                },
            }
        )
        layout[0]["zones"].append(
            {
                "id": "margin-kpi",
                "kind": "chart",
                "chart_kind": "kpi",
                "caption": "Margin Ratio",
                "x_pct": 0,
                "y_pct": 56,
                "w_pct": 25,
                "h_pct": 20,
                "rows_shelf": shelf(
                    field("MARGIN_CALC", "measure", "usr")
                ),
                "cols_shelf": shelf(),
                "filters": [],
            }
        )
        formula_audit = {
            "formulas": [
                {
                    "id": "calc-margin",
                    "internal_name": "[MARGIN_CALC]",
                    "caption": "Margin Ratio",
                    "status": "spec",
                    "sigma_formula": "Sum([Profit]) / Sum([Sales])",
                }
            ]
        }
        dm_spec = {
            "pages": [
                {
                    "elements": [
                        {
                            "id": "local-fact",
                            "kind": "table",
                            "name": "FACT",
                            "metrics": [
                                {
                                    "id": "metric-margin",
                                    "name": "Margin Ratio",
                                    "formula": "Sum([Profit]) / Sum([Sales])",
                                }
                            ],
                        }
                    ]
                }
            ]
        }
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="posted-fact",
            folder_id="folder",
            data_model_element_name="FACT",
            formula_audit=formula_audit,
            dm_spec=dm_spec,
        )
        spec, report = instance.build()
        self.assertEqual("complete", report["status"])
        kpi = next(
            element
            for element in spec["document"]["elements"]
            if element.get("name") == "Margin Ratio"
            and element.get("kind") == "kpi-chart"
        )
        self.assertEqual("[Master/Margin Ratio]", kpi["columns"][0]["formula"])
        master = spec["document"]["elements"][0]
        metric_column = next(
            column for column in master["columns"] if column["name"] == "Margin Ratio"
        )
        self.assertEqual("[Metrics/Margin Ratio]", metric_column["formula"])

    def test_user_aggregated_kpi_without_metric_uses_qualified_translation(self):
        layout, meta = self.signals()
        meta["columns_by_guid"]["PROFIT"] = {
            "caption": "Profit",
            "datatype": "real",
        }
        meta["columns_by_guid"]["PROFIT_CALC"] = {
            "caption": "Total Profit",
            "datatype": "real",
            "formula": "SUM([PROFIT])",
        }
        kpi = next(
            zone for zone in layout[0]["zones"] if zone.get("id") == "sales-kpi"
        )
        kpi["caption"] = "Total Profit"
        kpi["rows_shelf"] = shelf(field("PROFIT_CALC", "measure", "user"))
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
            formula_audit={
                "formulas": [
                    {
                        "id": "calc-profit",
                        "internal_name": "[PROFIT_CALC]",
                        "caption": "Total Profit",
                        "status": "spec",
                        "sigma_formula": "Sum([Profit])",
                    }
                ]
            },
        )
        spec, report = instance.build()
        self.assertEqual("complete", report["status"])
        emitted = next(
            element
            for element in spec["document"]["elements"]
            if element.get("name") == "Total Profit"
        )
        self.assertEqual(
            "Sum([Master/Profit])", emitted["columns"][0]["formula"]
        )

    def test_user_calculated_bar_dimension_qualifies_all_source_references(self):
        layout, meta = self.signals()
        meta["columns_by_guid"].update(
            {
                "SHIP_DAYS": {"caption": "Ship Days", "datatype": "integer"},
                "DELIVERY_BAND": {
                    "caption": "Delivery Band",
                    "datatype": "string",
                    "formula": (
                        'IF [SHIP_DAYS] <= 2 THEN "Fast" ELSE "Standard" END'
                    ),
                },
            }
        )
        bar = next(
            zone for zone in layout[0]["zones"] if zone.get("id") == "sales-bar"
        )
        bar["caption"] = "Sales by Delivery Band"
        bar["cols_shelf"] = shelf(field("DELIVERY_BAND", "dim", "none"))
        formula_audit = {
            "formulas": [
                {
                    "id": "calc-band",
                    "internal_name": "[DELIVERY_BAND]",
                    "caption": "Delivery Band",
                    "status": "spec",
                    "sigma_formula": (
                        'If([Ship Days] <= 2, "Fast", "Standard")'
                    ),
                }
            ]
        }
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
            formula_audit=formula_audit,
        )
        spec, report = instance.build()
        self.assertEqual("complete", report["status"])
        emitted = next(
            element
            for element in spec["document"]["elements"]
            if element.get("name") == "Sales by Delivery Band"
        )
        dimension = emitted["columns"][0]
        self.assertEqual(
            'If([Master/Ship Days] <= 2, "Fast", "Standard")',
            dimension["formula"],
        )
        master = spec["document"]["elements"][0]
        self.assertIn(
            "[FACT/Ship Days]",
            {column["formula"] for column in master["columns"]},
        )
        self.assertNotIn(
            "[FACT/Delivery Band]",
            {column["formula"] for column in master["columns"]},
        )

    def test_user_calculation_with_unmapped_reference_remains_a_residue(self):
        layout, meta = self.signals()
        meta["columns_by_guid"]["SEGMENT_CALC"] = {
            "caption": "Segment Band",
            "datatype": "string",
            "formula": "IF [MISSING] > 0 THEN \"A\" ELSE \"B\" END",
        }
        bar = next(
            zone for zone in layout[0]["zones"] if zone.get("id") == "sales-bar"
        )
        bar["cols_shelf"] = shelf(field("SEGMENT_CALC", "dim", "none"))
        formula_audit = {
            "formulas": [
                {
                    "id": "calc-segment",
                    "internal_name": "[SEGMENT_CALC]",
                    "caption": "Segment Band",
                    "status": "spec",
                    "sigma_formula": 'If([Unknown Input] > 0, "A", "B")',
                }
            ]
        }
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
            formula_audit=formula_audit,
        )
        _spec, report = instance.build()
        residue = next(
            item for item in report["residues"] if item["zoneId"] == "sales-bar"
        )
        self.assertEqual("blocked", report["status"])
        self.assertEqual(
            "unmapped-user-calculation-reference", residue["reasonCode"]
        )
        self.assertEqual(
            ["Unknown Input"], residue["signals"]["references"]
        )

    def test_cli_writes_structured_residues_and_no_spec_for_unsupported_zone(self):
        layout, meta = self.signals()
        layout[0]["zones"].append(
            {
                "id": "pie",
                "kind": "chart",
                "chart_kind": "pie",
                "caption": "Sales Mix",
                "x_pct": 0,
                "y_pct": 56,
                "w_pct": 50,
                "h_pct": 40,
                "rows_shelf": shelf(field("SALES", "measure", "sum")),
                "cols_shelf": shelf(field("REGION", "dim", "none")),
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout_path = root / "dashboard-layout.json"
            meta_path = root / "dashboard-layout-meta.json"
            output_path = root / "wb-spec.json"
            residues_path = root / "residues.json"
            layout_path.write_text(json.dumps(layout), encoding="utf-8")
            meta_path.write_text(json.dumps(meta), encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--layout",
                    str(layout_path),
                    "--meta",
                    str(meta_path),
                    "--data-model-id",
                    "dm",
                    "--element-id",
                    "fact",
                    "--data-model-element-name",
                    "FACT",
                    "--folder-id",
                    "folder",
                    "--out",
                    str(output_path),
                    "--residues-out",
                    str(residues_path),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(2, completed.returncode, completed.stderr)
            self.assertFalse(output_path.exists())
            report = json.loads(residues_path.read_text(encoding="utf-8"))
        self.assertEqual("blocked", report["status"])
        self.assertFalse(report["outputWritten"])
        self.assertEqual(
            "unsupported-chart-kind",
            next(item for item in report["residues"] if item["zoneId"] == "pie")[
                "reasonCode"
            ],
        )

    def test_real_parser_fixture_fails_closed_with_named_unsupported_shapes(self):
        self.assertTrue(CORPUS_TWB.is_file(), CORPUS_TWB)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            layout_path = root / "dashboard-layout.json"
            output_path = root / "wb-spec.json"
            residues_path = root / "workbook-residues.json"
            parsed = subprocess.run(
                [
                    sys.executable,
                    str(PARSER),
                    str(CORPUS_TWB),
                    str(layout_path),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, parsed.returncode, parsed.stderr)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--layout",
                    str(layout_path),
                    "--meta",
                    str(root / "dashboard-layout-meta.json"),
                    "--data-model-id",
                    "dm",
                    "--element-id",
                    "fact",
                    "--data-model-element-name",
                    "ORDER_FACT",
                    "--folder-id",
                    "folder",
                    "--out",
                    str(output_path),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(2, completed.returncode, completed.stderr)
            self.assertFalse(output_path.exists())
            report = json.loads(residues_path.read_text(encoding="utf-8"))

        self.assertEqual("blocked", report["status"])
        by_code = {}
        for residue in report["residues"]:
            by_code.setdefault(residue["reasonCode"], []).append(residue)
        self.assertIn("unsupported-chart-kind", by_code)
        self.assertIn("unsupported-zone-kind", by_code)
        self.assertIn("unsupported-chart-filter", by_code)
        self.assertEqual(
            {"pie"},
            {
                item["chartKind"]
                for item in by_code["unsupported-chart-kind"]
                if item["zoneKind"] == "chart"
            },
        )
        self.assertEqual(
            {"toggle"},
            {
                item.get("signals", {}).get("button_intent")
                for item in by_code["unsupported-zone-kind"]
                if item["zoneKind"] == "dashboard-object"
            },
        )


if __name__ == "__main__":
    unittest.main()
