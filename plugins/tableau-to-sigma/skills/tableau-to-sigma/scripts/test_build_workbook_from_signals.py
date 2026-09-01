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

    def test_adjacent_percentage_boxes_share_one_grid_boundary(self):
        left = builder_module.WorkbookBuilder.placement(
            "left",
            {"x_pct": 0, "y_pct": 0, "w_pct": 20, "h_pct": 10},
        )
        right = builder_module.WorkbookBuilder.placement(
            "right",
            {"x_pct": 20, "y_pct": 0, "w_pct": 20, "h_pct": 10},
        )
        self.assertIn('gridColumn="1 / 6"', left)
        self.assertIn('gridColumn="6 / 11"', right)

    def test_dashboard_canvas_scales_full_height_to_bounded_rows(self):
        layout, meta = self.signals()
        layout[0]["canvas_px"] = {"w": 1200, "h": 800}
        line_zone = next(
            zone
            for zone in layout[0]["zones"]
            if zone.get("id") == "sales-line"
        )
        line_zone["y_pct"] = 60
        line_zone["h_pct"] = 40
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
        )
        spec, report = instance.build()
        self.assertEqual("complete", report["status"])
        line = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "line-chart"
        )
        visible_page = next(
            page
            for page in spec["document"]["layout"].split("</Page>")
            if "page-executive-overview" in page
        )
        self.assertIn('gridTemplateRows="repeat(28, auto)"', visible_page)
        self.assertIn(
            f'<Element elementId="{line["id"]}"', visible_page
        )
        line_placement = next(
            row
            for row in visible_page.splitlines()
            if f'elementId="{line["id"]}"' in row
        )
        self.assertIn('gridRow="18 / 29"', line_placement)
        self.assertEqual(
            20,
            builder_module.WorkbookBuilder.dashboard_row_units(
                {"canvas_px": {"w": 1200, "h": 100}}
            ),
        )
        self.assertEqual(
            36,
            builder_module.WorkbookBuilder.dashboard_row_units(
                {"canvas_px": {"w": 1200, "h": 5000}}
            ),
        )

    def test_adjacent_kpi_title_text_is_chart_managed_but_main_title_remains(self):
        layout, meta = self.signals()
        layout[0]["zones"].append(
            {
                "id": "sales-kpi-title",
                "kind": "text",
                "x_pct": 0,
                "y_pct": 12,
                "w_pct": 24,
                "h_pct": 4,
                "text_runs": [{"text": "  Total   Sales  ", "font_size": 12}],
            }
        )
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
        )
        spec, report = instance.build()
        self.assertEqual("complete", report["status"])
        texts = [
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "text"
        ]
        self.assertEqual(1, len(texts))
        self.assertEqual(
            '# <span style="font-size: 20px">Executive Overview</span>',
            texts[0]["body"],
        )
        managed = next(
            row
            for row in report["dispositions"]
            if row["zoneId"] == "sales-kpi-title"
        )
        self.assertEqual("chart-managed-title", managed["status"])
        kpi = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "kpi-chart"
        )
        self.assertEqual(kpi["id"], managed["elementId"])
        self.assertEqual("Total Sales", kpi["name"])
        self.assertEqual(
            {},
            builder_module.WorkbookBuilder.kpi_managed_title_zones(
                {
                    "zones": [
                        {
                            "id": "main-title",
                            "kind": "text",
                            "x_pct": 0,
                            "y_pct": 0,
                            "w_pct": 100,
                            "h_pct": 8,
                            "text_runs": [{"text": "Executive Overview"}],
                        },
                        {
                            "id": "full-width-kpi",
                            "kind": "chart",
                            "chart_kind": "kpi",
                            "caption": "Executive Overview",
                            "x_pct": 0,
                            "y_pct": 8,
                            "w_pct": 100,
                            "h_pct": 20,
                        },
                    ]
                },
                "Executive Overview",
            ),
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

    def build_dm_case(self, zones, columns, dm_spec):
        instance = builder_module.WorkbookBuilder(
            [
                {
                    "dashboard": "Relationship Resolution",
                    "emit_page": True,
                    "zones": zones,
                }
            ],
            {"columns_by_guid": columns},
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
            dm_spec=dm_spec,
        )
        return instance.build()

    def build_zone(self, zone, columns):
        zone = {
            "x_pct": 0,
            "y_pct": 0,
            "w_pct": 100,
            "h_pct": 100,
            "filters": [],
            **zone,
        }
        instance = builder_module.WorkbookBuilder(
            [
                {
                    "dashboard": "Synthetic Shapes",
                    "emit_page": True,
                    "zones": [zone],
                }
            ],
            {"columns_by_guid": columns},
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
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

    def test_user_aggregated_kpi_stays_in_chart_grouping_context(self):
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
                            "columns": [
                                {"id": "dm-order-date", "name": "Order Date"},
                                {"id": "dm-region", "name": "Region"},
                                {"id": "dm-sales", "name": "Sales"},
                                {"id": "dm-profit", "name": "Profit"},
                            ],
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
        self.assertEqual(
            "Sum([Master/Profit]) / Sum([Master/Sales])",
            kpi["columns"][0]["formula"],
        )
        master = spec["document"]["elements"][0]
        self.assertEqual(
            {"Profit", "Sales"},
            {
                column["name"]
                for column in master["columns"]
                if column["name"] in {"Profit", "Sales"}
            },
        )

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

    def test_dm_spec_resolves_direct_source_column_by_guid(self):
        sales_guid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        spec, report = self.build_dm_case(
            [
                {
                    "id": "sales-kpi",
                    "kind": "chart",
                    "chart_kind": "kpi",
                    "caption": "Sales",
                    "rows_shelf": shelf(field(sales_guid, "measure", "sum")),
                    "cols_shelf": shelf(),
                    "filters": [],
                }
            ],
            {sales_guid: {"caption": "Sales", "datatype": "real"}},
            {
                "sigmaDataModel": {
                    "pages": [
                        {
                            "elements": [
                                {
                                    "id": "fact",
                                    "source": {
                                        "kind": "warehouse-table",
                                        "path": ["SCHEMA", "FACT"],
                                    },
                                    "columns": [
                                        {
                                            "id": (
                                                "inode-NORM0001/"
                                                "AAAAAAAA-BBBB-CCCC-DDDD-EEEE~suffix"
                                            ),
                                            "name": "Sales",
                                            "formula": "[FACT/Sales]",
                                        },
                                    ],
                                }
                            ]
                        }
                    ]
                }
            },
        )
        self.assertEqual("complete", report["status"])
        master = spec["document"]["elements"][0]
        self.assertEqual("[FACT/Sales]", master["columns"][0]["formula"])

    def test_dm_spec_resolves_related_column_by_guid(self):
        region_guid = "11111111-2222-3333-4444-555555555555"
        sales_guid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        spec, report = self.build_dm_case(
            [
                {
                    "id": "sales-region",
                    "kind": "chart",
                    "chart_kind": "bar",
                    "caption": "Sales by Region",
                    "rows_shelf": shelf(field(sales_guid, "measure", "sum")),
                    "cols_shelf": shelf(field(region_guid, "dim", "none")),
                    "filters": [],
                }
            ],
            {
                sales_guid: {"caption": "Sales", "datatype": "real"},
                region_guid: {"caption": "Region", "datatype": "string"},
            },
            {
                "pages": [
                    {
                        "elements": [
                            {
                                "id": "fact",
                                "name": "FACT",
                                "columns": [
                                    {"id": sales_guid, "name": "Sales"}
                                ],
                                "relationships": [
                                    {
                                        "id": "region-rel",
                                        "name": "Customer",
                                        "targetElementId": "customer",
                                        "keys": [],
                                    }
                                ],
                            },
                            {
                                "id": "customer",
                                "name": "CUSTOMER",
                                "columns": [
                                    {
                                        "id": (
                                            "inode-NORM0002/"
                                            "11111111-2222-3333-4444-5555~suffix"
                                        ),
                                        "name": "Sales Territory",
                                    }
                                ],
                            },
                        ]
                    }
                ]
            },
        )
        self.assertEqual("complete", report["status"])
        master = spec["document"]["elements"][0]
        self.assertEqual(
            {"[FACT/Sales]", "[FACT/Customer/Sales Territory]"},
            {column["formula"] for column in master["columns"]},
        )

    def test_dm_spec_blocks_ambiguous_related_caption_matches(self):
        sales_guid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        _spec, report = self.build_dm_case(
            [
                {
                    "id": "sales-region",
                    "kind": "chart",
                    "chart_kind": "bar",
                    "caption": "Sales by Region",
                    "rows_shelf": shelf(field(sales_guid, "measure", "sum")),
                    "cols_shelf": shelf(field("REGION", "dim", "none")),
                    "filters": [],
                }
            ],
            {
                sales_guid: {"caption": "Sales", "datatype": "real"},
                "REGION": {"caption": "Region", "datatype": "string"},
            },
            {
                "pages": [
                    {
                        "elements": [
                            {
                                "id": "fact",
                                "name": "FACT",
                                "columns": [
                                    {"id": sales_guid, "name": "Sales"}
                                ],
                                "relationships": [
                                    {
                                        "id": "billing-rel",
                                        "name": "Billing Customer",
                                        "targetElementId": "billing",
                                    },
                                    {
                                        "id": "shipping-rel",
                                        "name": "Shipping Customer",
                                        "targetElementId": "shipping",
                                    },
                                ],
                            },
                            {
                                "id": "billing",
                                "name": "BILLING_CUSTOMER",
                                "columns": [{"id": "billing-region", "name": "Region"}],
                            },
                            {
                                "id": "shipping",
                                "name": "SHIPPING_CUSTOMER",
                                "columns": [{"id": "shipping-region", "name": "Region"}],
                            },
                        ]
                    }
                ]
            },
        )
        self.assertEqual("blocked", report["status"])
        residue = next(
            item
            for item in report["residues"]
            if item["zoneId"] == "sales-region"
        )
        self.assertEqual(
            "ambiguous-master-source-field", residue["reasonCode"]
        )
        self.assertEqual(2, len(residue["signals"]["candidates"]))

    def test_dm_spec_blocks_absent_source_graph_match(self):
        _spec, report = self.build_dm_case(
            [
                {
                    "id": "lifetime-kpi",
                    "kind": "chart",
                    "chart_kind": "kpi",
                    "caption": "Lifetime Value",
                    "rows_shelf": shelf(
                        field("LIFETIME_VALUE", "measure", "sum")
                    ),
                    "cols_shelf": shelf(),
                    "filters": [],
                }
            ],
            {
                "LIFETIME_VALUE": {
                    "caption": "Lifetime Value",
                    "datatype": "real",
                }
            },
            {
                "pages": [
                    {
                        "elements": [
                            {
                                "id": "fact",
                                "name": "FACT",
                                "columns": [{"id": "sales", "name": "Sales"}],
                            }
                        ]
                    }
                ]
            },
        )
        self.assertEqual("blocked", report["status"])
        residue = next(
            item
            for item in report["residues"]
            if item["zoneId"] == "lifetime-kpi"
        )
        self.assertEqual(
            "unbound-master-source-field", residue["reasonCode"]
        )

    def test_dm_spec_resolves_unique_semantic_date_role_to_full_date(self):
        date_guid = "99999999-aaaa-bbbb-cccc-dddddddddddd"
        sales_guid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        spec, report = self.build_dm_case(
            [
                {
                    "id": "sales-date",
                    "kind": "chart",
                    "chart_kind": "line",
                    "caption": "Monthly Sales",
                    "rows_shelf": shelf(field(sales_guid, "measure", "sum")),
                    "cols_shelf": shelf(field(date_guid, "dim", "tmn")),
                    "filters": [],
                }
            ],
            {
                sales_guid: {"caption": "Sales", "datatype": "real"},
                date_guid: {"caption": "Order Date", "datatype": "date"},
            },
            {
                "pages": [
                    {
                        "elements": [
                            {
                                "id": "fact",
                                "name": "FACT",
                                "columns": [
                                    {"id": sales_guid, "name": "Sales"}
                                ],
                                "relationships": [
                                    {
                                        "id": "order-date-rel",
                                        "name": "DATE_DIM (Order Date)",
                                        "targetElementId": "order-date",
                                    },
                                    {
                                        "id": "ship-date-rel",
                                        "name": "Ship Date",
                                        "targetElementId": "ship-date",
                                    },
                                ],
                            },
                            {
                                "id": "order-date",
                                "name": "ORDER_DATE_DIM",
                                "columns": [
                                    {"id": "date-key", "name": "Date Key"},
                                    {"id": "full-date", "name": "Full Date"},
                                ],
                            },
                            {
                                "id": "ship-date",
                                "name": "SHIP_DATE_DIM",
                                "columns": [
                                    {"id": "ship-full-date", "name": "Full Date"}
                                ],
                            },
                        ]
                    }
                ]
            },
        )
        self.assertEqual("complete", report["status"])
        master = spec["document"]["elements"][0]
        self.assertIn(
            "[FACT/DATE_DIM (Order Date)/Full Date]",
            {column["formula"] for column in master["columns"]},
        )

    def test_area_chart_uses_canonical_cartesian_shape(self):
        spec, report = self.build_zone(
            {
                "id": "area",
                "kind": "chart",
                "chart_kind": "area",
                "caption": "Sales Area",
                "cols_shelf": shelf(field("DATE", "dim", "tmn")),
                "rows_shelf": shelf(field("SALES", "measure", "sum")),
            },
            {
                "DATE": {"caption": "Order Date", "datatype": "date"},
                "SALES": {"caption": "Sales", "datatype": "real"},
            },
        )
        self.assertEqual("complete", report["status"])
        area = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "area-chart"
        )
        self.assertEqual(area["columns"][0]["id"], area["xAxis"]["columnId"])
        self.assertEqual(
            [area["columns"][1]["id"]], area["yAxis"]["columnIds"]
        )

    def test_pie_and_donut_use_value_and_color_id_channels(self):
        for source_kind in ("pie", "donut"):
            with self.subTest(source_kind=source_kind):
                spec, report = self.build_zone(
                    {
                        "id": source_kind,
                        "kind": "chart",
                        "chart_kind": source_kind,
                        "caption": "Sales Mix",
                        "cols_shelf": shelf(),
                        "rows_shelf": shelf(field("SALES", "measure", "sum")),
                        "channels": {"color": {"column": "REGION"}},
                    },
                    {
                        "REGION": {"caption": "Region", "datatype": "string"},
                        "SALES": {"caption": "Sales", "datatype": "real"},
                    },
                )
                self.assertEqual("complete", report["status"])
                chart = next(
                    element
                    for element in spec["document"]["elements"]
                    if element["kind"] == f"{source_kind}-chart"
                )
                self.assertEqual(
                    chart["columns"][1]["id"], chart["value"]["id"]
                )
                self.assertEqual(
                    chart["columns"][0]["id"], chart["color"]["id"]
                )
                self.assertNotIn("xAxis", chart)

    def test_dual_axis_emits_combo_with_secondary_axis_subset(self):
        spec, report = self.build_zone(
            {
                "id": "combo",
                "kind": "chart",
                "chart_kind": "line",
                "caption": "Sales and Profit",
                "dual_axis": True,
                "cols_shelf": shelf(field("DATE", "dim", "tmn")),
                "rows_shelf": shelf(
                    field("SALES", "measure", "sum"),
                    field("PROFIT", "measure", "sum"),
                ),
            },
            {
                "DATE": {"caption": "Order Date", "datatype": "date"},
                "SALES": {"caption": "Sales", "datatype": "real"},
                "PROFIT": {"caption": "Profit", "datatype": "real"},
            },
        )
        self.assertEqual("complete", report["status"])
        combo = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "combo-chart"
        )
        y_ids = [item["columnId"] for item in combo["yAxis"]["columnIds"]]
        self.assertEqual(2, len(y_ids))
        self.assertTrue(
            all(item["type"] == "line" for item in combo["yAxis"]["columnIds"])
        )
        self.assertEqual([y_ids[1]], combo["yAxis2"]["columnIds"])

    def test_pivot_and_table_preserve_shelf_roles(self):
        spec, report = self.build_zone(
            {
                "id": "pivot",
                "kind": "chart",
                "chart_kind": "pivot-table",
                "caption": "Sales Pivot",
                "rows_shelf": shelf(
                    field("REGION", "dim", "none"),
                    field("SALES", "measure", "sum"),
                ),
                "cols_shelf": shelf(field("DATE", "dim", "tyr")),
            },
            {
                "REGION": {"caption": "Region", "datatype": "string"},
                "DATE": {"caption": "Order Date", "datatype": "date"},
                "SALES": {"caption": "Sales", "datatype": "real"},
            },
        )
        self.assertEqual("complete", report["status"])
        pivot = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "pivot-table"
        )
        by_name = {column["name"]: column["id"] for column in pivot["columns"]}
        self.assertEqual([{"id": by_name["Region"]}], pivot["rowsBy"])
        self.assertEqual([{"id": by_name["Order Date"]}], pivot["columnsBy"])
        self.assertEqual([by_name["Sales"]], pivot["values"])

        table_spec, table_report = self.build_zone(
            {
                "id": "table",
                "kind": "chart",
                "chart_kind": "table",
                "caption": "Regions",
                "rows_shelf": shelf(field("REGION", "dim", "none")),
                "cols_shelf": shelf(),
            },
            {"REGION": {"caption": "Region", "datatype": "string"}},
        )
        self.assertEqual("complete", table_report["status"])
        table = next(
            element
            for element in table_spec["document"]["elements"]
            if element["id"].startswith("chart-")
        )
        self.assertEqual("table", table["kind"])
        self.assertEqual([table["columns"][0]["id"]], table["order"])

    def test_scatter_builds_and_binds_a_safe_grouped_source(self):
        spec, report = self.build_zone(
            {
                "id": "scatter",
                "kind": "chart",
                "chart_kind": "scatter",
                "caption": "Sales vs Profit",
                "cols_shelf": shelf(field("SALES", "measure", "sum")),
                "rows_shelf": shelf(field("PROFIT", "measure", "avg")),
                "channels": {"detail": {"column": "REGION"}},
            },
            {
                "REGION": {"caption": "Region", "datatype": "string"},
                "SALES": {"caption": "Sales", "datatype": "real"},
                "PROFIT": {"caption": "Profit", "datatype": "real"},
            },
        )
        self.assertEqual("complete", report["status"])
        scatter = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "scatter-chart"
        )
        grouped = next(
            element
            for element in spec["document"]["elements"]
            if element["id"] == scatter["source"]["elementId"]
        )
        self.assertEqual(
            grouped["groupings"][0]["id"], scatter["source"]["groupingId"]
        )
        self.assertEqual(
            [grouped["columns"][0]["id"]],
            grouped["groupings"][0]["groupBy"],
        )
        self.assertEqual(
            [column["id"] for column in grouped["columns"][1:]],
            grouped["groupings"][0]["calculations"],
        )
        self.assertTrue(
            all(
                column["formula"].startswith(f"[{grouped['name']}/")
                for column in scatter["columns"]
            )
        )

    def test_scatter_without_point_dimension_stays_a_residue(self):
        _spec, report = self.build_zone(
            {
                "id": "scatter",
                "kind": "chart",
                "chart_kind": "scatter",
                "caption": "Unsafe Scatter",
                "cols_shelf": shelf(field("SALES", "measure", "sum")),
                "rows_shelf": shelf(field("PROFIT", "measure", "avg")),
            },
            {
                "SALES": {"caption": "Sales", "datatype": "real"},
                "PROFIT": {"caption": "Profit", "datatype": "real"},
            },
        )
        self.assertEqual("blocked", report["status"])
        self.assertEqual(
            "unsafe-scatter-source", report["residues"][0]["reasonCode"]
        )

    def test_region_map_requires_and_maps_verified_geography_role(self):
        spec, report = self.build_zone(
            {
                "id": "region-map",
                "kind": "chart",
                "chart_kind": "map-region",
                "caption": "Sales by State",
                "geo_role": "geo:state",
                "cols_shelf": shelf(field("STATE", "dim", "none")),
                "rows_shelf": shelf(field("SALES", "measure", "sum")),
            },
            {
                "STATE": {"caption": "State", "datatype": "string"},
                "SALES": {"caption": "Sales", "datatype": "real"},
            },
        )
        self.assertEqual("complete", report["status"])
        region_map = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "region-map"
        )
        self.assertEqual("us-state", region_map["region"]["regionType"])
        self.assertEqual(
            region_map["columns"][0]["id"], region_map["region"]["id"]
        )
        self.assertEqual(
            region_map["columns"][1]["id"], region_map["color"]["column"]
        )

        _spec, blocked = self.build_zone(
            {
                "id": "region-map",
                "kind": "chart",
                "chart_kind": "map-region",
                "caption": "Unverified Regions",
                "cols_shelf": shelf(field("STATE", "dim", "none")),
                "rows_shelf": shelf(field("SALES", "measure", "sum")),
            },
            {
                "STATE": {"caption": "State", "datatype": "string"},
                "SALES": {"caption": "Sales", "datatype": "real"},
            },
        )
        self.assertEqual("blocked", blocked["status"])
        self.assertEqual(
            "unverified-region-map", blocked["residues"][0]["reasonCode"]
        )

    def test_point_map_requires_unique_latitude_and_longitude_fields(self):
        spec, report = self.build_zone(
            {
                "id": "point-map",
                "kind": "chart",
                "chart_kind": "map-point",
                "caption": "Locations",
                "cols_shelf": shelf(field("LONGITUDE", "measure", "avg")),
                "rows_shelf": shelf(field("LATITUDE", "measure", "avg")),
            },
            {
                "LATITUDE": {
                    "caption": "Latitude (generated)",
                    "datatype": "real",
                },
                "LONGITUDE": {
                    "caption": "Longitude (generated)",
                    "datatype": "real",
                },
            },
        )
        self.assertEqual("complete", report["status"])
        point_map = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "point-map"
        )
        self.assertEqual(
            point_map["columns"][0]["id"], point_map["latitude"]["id"]
        )
        self.assertEqual(
            point_map["columns"][1]["id"], point_map["longitude"]["id"]
        )
        _spec, blocked = self.build_zone(
            {
                "id": "point-map",
                "kind": "chart",
                "chart_kind": "map-point",
                "caption": "Missing Longitude",
                "cols_shelf": shelf(),
                "rows_shelf": shelf(field("LATITUDE", "measure", "avg")),
            },
            {
                "LATITUDE": {
                    "caption": "Latitude",
                    "datatype": "real",
                }
            },
        )
        self.assertEqual("blocked", blocked["status"])
        self.assertEqual(
            "unverified-point-map", blocked["residues"][0]["reasonCode"]
        )

    def test_filter_controls_use_master_target_and_canonical_value_sources(self):
        layout, meta = self.signals()
        meta["columns_by_guid"]["AMOUNT"] = {
            "caption": "Amount",
            "datatype": "real",
        }
        layout[0]["zones"].append(
            {
                "id": "amount-filter",
                "kind": "filter",
                "view_ref": "AMOUNT",
                "filter_column_caption": "Amount",
                "filter_column_datatype": "real",
                "x_pct": 60,
                "y_pct": 8,
                "w_pct": 20,
                "h_pct": 8,
            }
        )
        instance = builder_module.WorkbookBuilder(
            layout,
            meta,
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
        )
        spec, report = instance.build()
        self.assertEqual("complete", report["status"])
        controls = {
            element["name"]: element
            for element in spec["document"]["elements"]
            if element["kind"] == "control"
        }
        region = controls["Region"]
        self.assertEqual("list", region["controlType"])
        self.assertEqual(
            {"kind": "table", "elementId": "master"},
            region["filters"][0]["source"],
        )
        self.assertEqual(
            region["filters"][0]["columnId"], region["source"]["columnId"]
        )
        self.assertEqual(
            {"kind": "table", "elementId": "master"},
            region["source"]["source"],
        )
        self.assertEqual("date-range", controls["Order Date"]["controlType"])
        self.assertEqual("between", controls["Order Date"]["mode"])
        self.assertEqual("number-range", controls["Amount"]["controlType"])

    def test_parameter_control_and_dynamic_text_share_the_control_handle(self):
        spec, report = self.build_zone(
            {
                "id": "parameter",
                "kind": "parameter",
                "view_ref": "SCENARIO",
                "filter_column_caption": "Scenario",
            },
            {"SCENARIO": {"caption": "Scenario", "datatype": "string"}},
        )
        self.assertEqual("complete", report["status"])
        control = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "control"
        )
        self.assertEqual("text", control["controlType"])
        self.assertEqual("equals", control["mode"])
        self.assertFalse(control["showOperators"])

        layout = [
            {
                "dashboard": "Parameters",
                "emit_page": True,
                "zones": [
                    {
                        "id": "parameter",
                        "kind": "parameter",
                        "view_ref": "SCENARIO",
                        "filter_column_caption": "Scenario",
                        "x_pct": 0,
                        "y_pct": 0,
                        "w_pct": 30,
                        "h_pct": 10,
                    },
                    {
                        "id": "dynamic-title",
                        "kind": "text",
                        "x_pct": 0,
                        "y_pct": 10,
                        "w_pct": 100,
                        "h_pct": 10,
                        "text_runs": [
                            {
                                "text": "Scenario: <[SCENARIO]>",
                                "font_size": 18,
                            }
                        ],
                    },
                ],
            }
        ]
        instance = builder_module.WorkbookBuilder(
            layout,
            {
                "columns_by_guid": {
                    "SCENARIO": {
                        "caption": "Scenario",
                        "datatype": "string",
                    }
                }
            },
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
        )
        dynamic_spec, dynamic_report = instance.build()
        self.assertEqual("complete", dynamic_report["status"])
        dynamic_control = next(
            element
            for element in dynamic_spec["document"]["elements"]
            if element["kind"] == "control"
        )
        text = next(
            element
            for element in dynamic_spec["document"]["elements"]
            if element["kind"] == "text"
        )
        self.assertIn(
            f"{{{{[{dynamic_control['controlId']}]}}}}", text["body"]
        )

    def test_dynamic_aggregate_text_and_safe_style_are_canonical(self):
        spec, report = self.build_zone(
            {
                "id": "dynamic-text",
                "kind": "text",
                "text_align": "center",
                "text_runs": [
                    {
                        "text": "Sales: <SUM([SALES])>",
                        "color": "#336699",
                        "bold": True,
                    }
                ],
            },
            {"SALES": {"caption": "Sales", "datatype": "real"}},
        )
        self.assertEqual("complete", report["status"])
        text = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "text"
        )
        self.assertNotIn("name", text)
        self.assertIn("{{Sum([Master/Sales])}}", text["body"])
        self.assertIn('<span style="color: #336699">', text["body"])
        self.assertTrue(text["body"].startswith('<p style="text-align: center">'))

    def test_uncontrolled_dynamic_field_text_stays_a_typed_residue(self):
        _spec, report = self.build_zone(
            {
                "id": "dynamic-text",
                "kind": "text",
                "text_runs": [{"text": "Region: <[REGION]>"}],
            },
            {"REGION": {"caption": "Region", "datatype": "string"}},
        )
        self.assertEqual("blocked", report["status"])
        self.assertEqual(
            "unbound-dynamic-text", report["residues"][0]["reasonCode"]
        )
        self.assertEqual(
            "one same-page filter or parameter control",
            report["residues"][0]["signals"]["tokens"][0]["needed"],
        )

    def test_hosted_image_emits_and_local_artifact_blocks(self):
        spec, report = self.build_zone(
            {
                "id": "logo",
                "kind": "image",
                "caption": "Logo",
                "image_file_url": "https://assets.example.test/logo.png",
                "image_path": "images/logo.png",
                "is_scaled": True,
            },
            {},
        )
        self.assertEqual("complete", report["status"])
        image = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "image"
        )
        self.assertEqual(
            "https://assets.example.test/logo.png", image["url"]
        )
        self.assertEqual({"fit": "contain"}, image["style"])
        self.assertEqual("Logo", image["alt"])

        _spec, blocked = self.build_zone(
            {
                "id": "local-logo",
                "kind": "image",
                "image_path": "images/logo.png",
            },
            {},
        )
        self.assertEqual("blocked", blocked["status"])
        self.assertEqual(
            "unsupported-image-artifact", blocked["residues"][0]["reasonCode"]
        )

    def test_exact_navigation_button_maps_to_cross_page_action(self):
        layout = [
            {
                "dashboard": "Overview",
                "emit_page": True,
                "zones": [
                    {
                        "id": "go-detail",
                        "kind": "dashboard-object",
                        "button_intent": "navigate",
                        "button_nav_target": "Detail",
                        "button_nav_target_class": "dashboard",
                        "button_caption": "View detail",
                        "x_pct": 0,
                        "y_pct": 0,
                        "w_pct": 20,
                        "h_pct": 10,
                    }
                ],
            },
            {
                "dashboard": "Detail",
                "emit_page": True,
                "zones": [
                    {
                        "id": "detail-title",
                        "kind": "text",
                        "text_runs": [{"text": "Detail"}],
                        "x_pct": 0,
                        "y_pct": 0,
                        "w_pct": 100,
                        "h_pct": 10,
                    }
                ],
            },
        ]
        instance = builder_module.WorkbookBuilder(
            layout,
            {"columns_by_guid": {}},
            data_model_id="dm",
            element_id="fact",
            folder_id="folder",
            data_model_element_name="FACT",
        )
        spec, report = instance.build()
        self.assertEqual("complete", report["status"])
        button = next(
            element
            for element in spec["document"]["elements"]
            if element["kind"] == "button"
        )
        detail_page = next(
            page
            for page in spec["document"]["pages"]
            if page["name"] == "Detail"
        )
        self.assertEqual(
            {
                "effect": "navigate",
                "target": {"type": "page", "page": detail_page["id"]},
            },
            button["actions"][0]["effects"][0],
        )

    def test_ambiguous_tableau_interactions_keep_specific_evidence(self):
        _spec, report = self.build_zone(
            {
                "id": "action-chart",
                "kind": "chart",
                "chart_kind": "bar",
                "caption": "Action Source",
                "cols_shelf": shelf(field("REGION", "dim", "none")),
                "rows_shelf": shelf(field("SALES", "measure", "sum")),
                "filters": [
                    {
                        "kind": "action",
                        "is_action": True,
                        "raw_param": "[Action (Region)]",
                    }
                ],
            },
            {
                "REGION": {"caption": "Region", "datatype": "string"},
                "SALES": {"caption": "Sales", "datatype": "real"},
            },
        )
        self.assertEqual("blocked", report["status"])
        residue = next(
            item
            for item in report["residues"]
            if item["reasonCode"] == "unbound-tableau-interaction"
        )
        self.assertEqual(
            "filter-or-highlight", residue["signals"]["actionType"]
        )
        self.assertIn(
            "target element and column",
            residue["signals"]["evidenceNeeded"],
        )

        _spec, button_report = self.build_zone(
            {
                "id": "url-action",
                "kind": "dashboard-object",
                "button_intent": "url",
                "button_caption": "Open",
            },
            {},
        )
        self.assertEqual("blocked", button_report["status"])
        self.assertEqual(
            "unsupported-tableau-button-action",
            button_report["residues"][0]["reasonCode"],
        )
        self.assertEqual(
            ["exact URL", "open target"],
            button_report["residues"][0]["signals"]["evidenceNeeded"],
        )

    def test_cli_writes_structured_residues_and_no_spec_for_unsupported_zone(self):
        layout, meta = self.signals()
        layout[0]["zones"].append(
            {
                "id": "unsupported",
                "kind": "chart",
                "chart_kind": "other",
                "caption": "Unsupported Shape",
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
            next(item for item in report["residues"] if item["zoneId"] == "unsupported")[
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
        self.assertIn("unsupported-tableau-button-action", by_code)
        self.assertIn("unbound-tableau-interaction", by_code)
        self.assertEqual(
            {"pie"},
            {
                item["chartKind"]
                for item in by_code["unbound-tableau-interaction"]
                if item["zoneKind"] == "chart"
                and item["chartKind"] == "pie"
            },
        )
        self.assertEqual(
            {"toggle"},
            {
                item.get("signals", {}).get("actionType")
                for item in by_code["unsupported-tableau-button-action"]
                if item["zoneKind"] == "dashboard-object"
            },
        )


if __name__ == "__main__":
    unittest.main()
