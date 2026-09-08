#!/usr/bin/env python3
"""Focused Aug-2026 workbook-as-code release regression."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SKILL, "scripts"))
import convert as C  # noqa: E402


def panel(name, items):
    return {"name": name, "items": [{"jaql": item} for item in items]}


def main():
    model = json.load(open(os.path.join(SKILL, "fixtures", "model_ecommerce.json")))
    waterfall = {
        "oid": "wf", "type": "chart/waterfall", "title": "Revenue Bridge",
        "style": {
            "legend": {"enabled": False, "position": "right"},
            "backgroundColor": "#F4F7FB",
        },
        "drilldownOptions": {"categories": ["Category", "Brand"]},
        "metadata": {"panels": [
            panel("categories", [{"dim": "[Commerce.Category ID]", "title": "Category"}]),
            panel("values", [{"dim": "[Commerce.Revenue]", "agg": "sum",
                              "title": "Revenue"}]),
        ]},
    }
    gauge = {
        "oid": "gauge", "type": "indicator", "subtype": "indicator/gauge",
        "title": "Goal Progress", "style": {"min": 0, "max": 100},
        "metadata": {"panels": [
            panel("value", [{"dim": "[Commerce.Revenue]", "agg": "sum",
                             "title": "Revenue"}]),
        ]},
    }
    gated_box = {
        "oid": "box", "type": "chart/boxplot", "title": "Revenue Distribution",
        "style": {}, "metadata": {"panels": []},
    }
    dashboard = {
        "title": "Release Features", "filters": [],
        "style": {"backgroundColor": "#FFFFFF"},
        "widgets": [waterfall, gauge, gated_box],
        "layout": {"type": "columnar", "columns": [{
            "width": 100,
            "cells": [
                {"subcells": [{"width": 100, "elements": [
                    {"widgetid": "wf", "height": 420},
                ]}]},
                {"subcells": [{"width": 100, "elements": [
                    {"widgetid": "gauge", "height": 180},
                ]}]},
                {"subcells": [{"width": 100, "elements": [
                    {"widgetid": "box", "height": 420},
                ]}]},
            ],
        }]},
    }
    dm_info = {"dataModelId": "dm-x", "factElementId": "fact-x",
               "factName": "Commerce"}
    spec, flags = C.convert_dashboard([dashboard], model, dm_info)

    assert spec["name"] == "ECommerce Overview (from Sisense)"
    assert "document" in spec and "pages" not in spec and "elements" not in spec
    doc = C.code_rep.document(spec)
    assert doc["kind"] == "workbook" and doc["schemaVersion"] == 1
    assert all("elements" not in page for page in doc["pages"])
    elements = C.code_rep.workbook_elements(spec)
    assert all(el in doc["elements"] for el in elements)

    wf = next(el for el in elements if el.get("name") == "Revenue Bridge")
    assert wf["kind"] == "waterfall-chart"
    assert wf["waterfallShape"] == {"calculation": "sum",
                                    "connectorLine": "shown"}
    assert wf["legend"] == {"visibility": "hidden", "position": "right"}
    assert wf["style"] == {"backgroundColor": "#F4F7FB"}

    progress = next(el for el in elements if el.get("name") == "Goal Progress")
    assert progress["kind"] == "progress"
    assert progress["mode"] == "value" and progress["shape"] == "ring"
    assert progress["min"] == "0" and progress["max"] == "100"
    assert progress["value"].startswith("Sum(")
    assert "source" not in progress and "columns" not in progress

    assert not any(el.get("kind") == "box-chart" for el in elements)
    assert any(f.get("type") == "chart/boxplot" and "workspace-gated" in f["reason"]
               for f in flags)
    assert any(f.get("feature") == "drill" for f in flags)
    assert any(
        entry.get("name") == "backgroundCanvas" and entry.get("color") == "#FFFFFF"
        for entry in doc["settings"]["theme"]["overrides"]["colorOverrides"]
    )

    placed = [
        element_id
        for page_ids in C.code_rep.workbook_page_element_ids(spec).values()
        for element_id in page_ids
    ]
    ids = [el["id"] for el in elements]
    assert sorted(placed) == sorted(ids)
    assert len(placed) == len(set(placed))

    # Data-model code representation deliberately remains page-nested.
    dm, _ = C.convert_model(model, "connection-x")
    assert "document" not in dm and "elements" not in dm
    assert dm["pages"][0]["elements"]

    rows = {
        row["source"]: row
        for row in json.load(open(os.path.join(
            SKILL, "refs", "catalogs", "workbook-feature.json"
        )))["rows"]
    }
    for key in ("widget-drilldown-options", "jump-to-dashboard",
                "tabber-widget", "print-page-break",
                "dashboard-filter-panel", "repeated-container",
                "box-and-whisker"):
        assert rows[key]["sigma"] is None
        assert rows[key]["no_sigma_equiv"] is True
    assert rows["box-and-whisker"]["release_gate"]

    print("ALL PASS")


if __name__ == "__main__":
    main()
