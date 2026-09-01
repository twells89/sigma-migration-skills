#!/usr/bin/env python3
"""Build the Orders Executive Overview workbook spec from the proven data model."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def column(column_id, name, formula, format_=None):
    value = {"id": column_id, "name": name, "formula": formula}
    if format_:
        value["format"] = format_
    return value


def kpi(element_id, name, formula, format_):
    value_id = f"{element_id}-value"
    return {
        "id": element_id,
        "kind": "kpi-chart",
        "name": name,
        "source": {"kind": "table", "elementId": "orders-master"},
        "columns": [column(value_id, name, formula, format_)],
        "value": {"columnId": value_id, "fontSize": 28, "color": "#1F2937"},
        "layout": {"anchor": "middle", "titleOrient": "top"},
    }


def build(data_model_id: str, element_id: str, folder_id: str) -> dict:
    currency = {"kind": "number", "formatString": "$,.0f"}
    integer = {"kind": "number", "formatString": ",.0f"}
    percent = {"kind": "number", "formatString": ",.1%"}
    master_columns = [
        column("m-order-id", "Order Id", "[ORDER_FACT/Order Id]"),
        column("m-net-revenue", "Net Revenue", "[ORDER_FACT/Net Revenue]", currency),
        column("m-net-profit", "Net Profit", "[ORDER_FACT/Net Profit]", currency),
        column("m-gross-revenue", "Gross Revenue", "[ORDER_FACT/Gross Revenue]", currency),
        column("m-gross-profit", "Gross Profit", "[ORDER_FACT/Gross Profit]", currency),
        column("m-is-returned", "Is Returned", "[ORDER_FACT/Is Returned]"),
        column("m-ship-speed", "Ship Speed Category", "[ORDER_FACT/Ship Speed Category]"),
        column(
            "m-order-date",
            "Order Date",
            "[ORDER_FACT/DATE_DIM (Order Date)/Full Date]",
            {"kind": "datetime", "formatString": "%Y-%m-%d"},
        ),
        column("m-region", "Customer Region", "[ORDER_FACT/CUSTOMER_DIM/Region]"),
        column(
            "m-lifetime-revenue",
            "Customer Lifetime Revenue",
            "[ORDER_FACT/CUSTOMER_DIM/Lifetime Revenue]",
            currency,
        ),
        column(
            "m-tier",
            "Customer Value Tier",
            'If([Customer Lifetime Revenue] >= 5000, "Platinum", '
            '[Customer Lifetime Revenue] >= 2000, "Gold", '
            '[Customer Lifetime Revenue] >= 500, "Silver", "Bronze")',
        ),
    ]
    master = {
        "id": "orders-master",
        "kind": "table",
        "name": "Orders Data",
        "source": {
            "kind": "data-model",
            "dataModelId": data_model_id,
            "elementId": element_id,
        },
        "columns": master_columns,
        "visibleAsSource": False,
    }

    elements = [
        master,
        {
            "id": "overview-title",
            "kind": "text",
            "body": (
                "<span style=\"font-size:18px;\">"
                "Orders — Executive Overview</span>"
            ),
        },
        kpi(
            "kpi-net-revenue",
            "Net Revenue",
            "Sum([Orders Data/Net Revenue])",
            currency,
        ),
        kpi(
            "kpi-net-profit",
            "Net Profit",
            "Sum([Orders Data/Net Profit])",
            currency,
        ),
        kpi(
            "kpi-total-orders",
            "Total Orders",
            "CountDistinct([Orders Data/Order Id])",
            integer,
        ),
        kpi(
            "kpi-gross-margin",
            "Gross Margin %",
            "Sum([Orders Data/Gross Profit]) / Sum([Orders Data/Gross Revenue])",
            percent,
        ),
        kpi(
            "kpi-return-rate",
            "Return Rate",
            "Sum([Orders Data/Is Returned]) / Count([Orders Data/Order Id])",
            percent,
        ),
        {
            "id": "chart-revenue-trend",
            "kind": "line-chart",
            "name": "Net Revenue by Month",
            "source": {"kind": "table", "elementId": "orders-master"},
            "columns": [
                column(
                    "trend-month",
                    "Month",
                    'DateTrunc("month", [Orders Data/Order Date])',
                    {"kind": "datetime", "formatString": "%B %Y"},
                ),
                column(
                    "trend-revenue",
                    "Net Revenue",
                    "Sum([Orders Data/Net Revenue])",
                    currency,
                ),
            ],
            "xAxis": {
                "columnId": "trend-month",
                "sort": {"by": "trend-month", "direction": "ascending"},
            },
            "yAxis": {"columnIds": ["trend-revenue"]},
            "color": {"by": "single", "value": "#4E79A7"},
            "legend": {"visibility": "hidden"},
            "refMarks": [
                {
                    "type": "line",
                    "axis": "series",
                    "value": {"type": "formula", "formula": "5000"},
                    "line": {"color": "#9CA3AF", "width": 1},
                    "label": {"visibility": "shown", "text": ""},
                }
            ],
        },
        {
            "id": "chart-revenue-region",
            "kind": "bar-chart",
            "name": "Net Revenue by Region",
            "source": {"kind": "table", "elementId": "orders-master"},
            "columns": [
                column("region-name", "Region", "[Orders Data/Customer Region]"),
                column(
                    "region-revenue",
                    "Net Revenue",
                    "Sum([Orders Data/Net Revenue])",
                    currency,
                ),
            ],
            "xAxis": {
                "columnId": "region-name",
                "sort": {"by": "region-revenue", "direction": "descending"},
            },
            "yAxis": {"columnIds": ["region-revenue"]},
            "orientation": "horizontal",
            "color": {"by": "single", "value": "#4E79A7"},
            "legend": {"visibility": "hidden"},
            "dataLabel": {"labels": "shown", "labelDisplay": "all"},
        },
        {
            "id": "chart-gross-ship",
            "kind": "bar-chart",
            "name": "Gross Revenue by Ship Speed",
            "source": {"kind": "table", "elementId": "orders-master"},
            "columns": [
                column(
                    "ship-category",
                    "Ship Speed Category",
                    "[Orders Data/Ship Speed Category]",
                ),
                column(
                    "ship-revenue",
                    "Gross Revenue",
                    "Sum([Orders Data/Gross Revenue])",
                    currency,
                ),
            ],
            "xAxis": {
                "columnId": "ship-category",
                "sort": {"by": "ship-revenue", "direction": "descending"},
                "format": {
                    "labels": {
                        "labelAngle": 0,
                        "fontSize": 7,
                        "allowLongerLabels": True,
                    }
                },
            },
            "yAxis": {"columnIds": ["ship-revenue"]},
            "color": {"by": "single", "value": "#4E79A7"},
            "legend": {"visibility": "hidden"},
            "dataLabel": {"labels": "shown", "labelDisplay": "all"},
        },
        {
            "id": "chart-margin-tier",
            "kind": "bar-chart",
            "name": "Gross Margin % by Customer Tier",
            "source": {"kind": "table", "elementId": "orders-master"},
            "columns": [
                column(
                    "tier-name",
                    "Customer Value Tier",
                    "[Orders Data/Customer Value Tier]",
                ),
                column(
                    "tier-margin",
                    "Gross Margin %",
                    "Sum([Orders Data/Gross Profit]) / Sum([Orders Data/Gross Revenue])",
                    percent,
                ),
            ],
            "xAxis": {
                "columnId": "tier-name",
                "sort": {"by": "tier-margin", "direction": "descending"},
            },
            "yAxis": {"columnIds": ["tier-margin"]},
            "orientation": "horizontal",
            "color": {"by": "single", "value": "#4E79A7"},
            "legend": {"visibility": "hidden"},
            "dataLabel": {
                "labels": "shown",
                "labelDisplay": "all",
                "valueFormat": "percent",
            },
        },
    ]

    layout = """<?xml version="1.0" encoding="utf-8"?>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="data-page">
  <Element elementId="orders-master" gridColumn="1 / 25" gridRow="1 / 20"/>
</Page>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="overview-page">
  <Element elementId="overview-title" gridColumn="10 / 18" gridRow="1 / 3"/>
  <Element elementId="kpi-net-revenue" gridColumn="1 / 6" gridRow="3 / 7"/>
  <Element elementId="kpi-net-profit" gridColumn="6 / 11" gridRow="3 / 7"/>
  <Element elementId="kpi-total-orders" gridColumn="11 / 16" gridRow="3 / 7"/>
  <Element elementId="kpi-gross-margin" gridColumn="16 / 21" gridRow="3 / 7"/>
  <Element elementId="kpi-return-rate" gridColumn="21 / 25" gridRow="3 / 7"/>
  <Element elementId="chart-revenue-trend" gridColumn="1 / 25" gridRow="7 / 18"/>
  <Element elementId="chart-revenue-region" gridColumn="1 / 7" gridRow="18 / 27"/>
  <Element elementId="chart-gross-ship" gridColumn="7 / 17" gridRow="18 / 27"/>
  <Element elementId="chart-margin-tier" gridColumn="17 / 25" gridRow="18 / 27"/>
</Page>
"""
    spec = {
        "name": "Orders Executive Overview — Python Migration",
        "folderId": folder_id,
        "description": (
            "Ruby-free Tableau migration proof. Source logic, value anchors, "
            "readback, and visual parity are gated in the migration workdir."
        ),
        "document": {
            "schemaVersion": 1,
            "kind": "workbook",
            "elements": elements,
            "pages": [
                {
                    "id": "data-page",
                    "name": "Data",
                    "visibility": "hidden",
                    "pageWidth": "full",
                },
                {
                    "id": "overview-page",
                    "name": "Executive Overview",
                    "pageWidth": "full",
                    "backgroundColor": "#FFFFFF",
                },
            ],
            "layout": layout,
            "settings": {
                "theme": {
                    "name": "Light",
                    "overrides": {"categoricalScheme": ["#4E79A7"]},
                }
            },
        },
    }
    validate(spec)
    return spec


def validate(spec: dict) -> None:
    document = spec["document"]
    elements = document["elements"]
    ids = [element["id"] for element in elements]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate element IDs")
    column_ids = [
        column_["id"]
        for element in elements
        for column_ in element.get("columns") or []
    ]
    if len(column_ids) != len(set(column_ids)):
        raise ValueError("duplicate column IDs")
    placed = re.findall(r'elementId="([^"]+)"', document["layout"])
    if sorted(placed) != sorted(ids):
        raise ValueError("layout must place every element exactly once")
    for element in elements:
        for column_ in element.get("columns") or []:
            if not column_.get("formula"):
                raise ValueError(f"{element['id']}/{column_['id']} has no formula")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-model-id", required=True)
    parser.add_argument("--element-id", required=True)
    parser.add_argument("--folder-id", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        spec = build(args.data_model_id, args.element_id, args.folder_id)
        Path(args.out).write_text(
            json.dumps(spec, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 1
    print(f"wrote {args.out} ({len(spec['document']['elements'])} elements)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
