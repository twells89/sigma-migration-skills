#!/usr/bin/env python3
"""Focused offline regression for the Aug-2026 workbook code release."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
VIEWS = os.path.join(SKILL, "fixtures", "skilltest-orders", "views")
sys.path.insert(0, os.path.join(HERE, "lib"))
import code_rep  # noqa: E402


def main():
    contract = {
        "id": "release",
        "title": "Release Features",
        "layoutMode": "newspaper",
        "source": "lookml",
        "tabs": [
            {"name": "overview", "label": "Overview"},
            {"name": "detail", "label": "Detail"},
        ],
        "style": {"backgroundColor": "#EEF2F7"},
        "filterPanel": {"location": "sidebar", "collapsed": False},
        "filters": [],
        "elements": [
            {
                "name": "Revenue Change", "tileType": "looker_waterfall",
                "model": "skilltest_orders", "explore": "order_fact",
                "fields": ["customer_dim.region", "order_fact.total_net_revenue"],
                "pivots": [], "filters": {}, "sorts": [], "listen": {},
                "dynamicFields": [], "legend": {"visibility": "hidden"},
                "style": {"backgroundColor": "#FFFFFF"}, "tabName": "overview",
                "layout": {"row": 0, "col": 0, "width": 12, "height": 8},
            },
            {
                "name": "Revenue Goal", "tileType": "single_value",
                "model": "skilltest_orders", "explore": "order_fact",
                "fields": ["order_fact.total_net_revenue",
                           "order_fact.average_order_value"],
                "pivots": [], "filters": {}, "sorts": [], "listen": {},
                "dynamicFields": [], "showComparison": True,
                "comparisonType": "progress", "tabName": "overview",
                "layout": {"row": 0, "col": 12, "width": 12, "height": 8},
            },
            {
                "name": "Unsupported Box", "tileType": "looker_boxplot",
                "model": "skilltest_orders", "explore": "order_fact",
                "fields": ["customer_dim.region", "order_fact.total_net_revenue"],
                "pivots": [], "filters": {}, "sorts": [], "listen": {},
                "dynamicFields": [], "tabName": "detail",
                "layout": {"row": 0, "col": 0, "width": 12, "height": 8},
            },
            {
                "name": "Details", "tileType": "table",
                "model": "skilltest_orders", "explore": "order_fact",
                "fields": ["customer_dim.region", "order_fact.total_net_revenue"],
                "pivots": [], "filters": {}, "sorts": [], "listen": {},
                "dynamicFields": [], "tabName": "detail",
                "layout": {"row": 0, "col": 12, "width": 12, "height": 8},
            },
        ],
    }

    with tempfile.TemporaryDirectory() as workdir:
        source = os.path.join(workdir, "contract.json")
        output = os.path.join(workdir, "workbook.json")
        json.dump(contract, open(source, "w"))
        run = subprocess.run(
            [sys.executable, os.path.join(HERE, "build_workbook.py"), source,
             "--views", VIEWS, "--dm-id", "dm-x", "--element-id", "dm-el",
             "--dm-element-name", "Order Fact", "--folder-id", "folder-x",
             "--out", output],
            capture_output=True, text=True,
        )
        assert run.returncode == 0, run.stdout + run.stderr
        envelope = json.load(open(output))

    assert envelope["name"] == "Release Features (from Looker)"
    assert "pages" not in envelope and "elements" not in envelope
    doc = code_rep.document(envelope)
    assert doc["schemaVersion"] == 1 and doc["kind"] == "workbook"
    assert all("elements" not in page for page in doc["pages"])
    assert [p["name"] for p in doc["pages"]] == ["Data", "Overview", "Detail"]

    elements = code_rep.workbook_elements(doc)
    ids = [el["id"] for el in elements]
    placed = [element_id
              for page_ids in code_rep.workbook_page_element_ids(doc).values()
              for element_id in page_ids]
    assert sorted(ids) == sorted(placed)
    assert len(placed) == len(set(placed))

    waterfall = next(el for el in elements if el.get("name") == "Revenue Change")
    assert waterfall["kind"] == "waterfall-chart"
    assert waterfall["waterfallShape"] == {
        "calculation": "sum", "connectorLine": "shown",
    }
    assert waterfall["legend"] == {"visibility": "hidden"}
    assert waterfall["style"]["backgroundColor"] == "#FFFFFF"

    progress = next(el for el in elements if el.get("name") == "Revenue Goal")
    assert progress["kind"] == "progress"
    assert progress["mode"] == "value" and progress["shape"] == "bar"
    assert progress["value"].startswith("Sum(") and progress["max"]
    assert not progress.get("source") and not progress.get("columns")

    assert not any(el.get("kind") == "box-chart" for el in elements)
    assert "looker_boxplot" in run.stdout and "no Sigma mapping" in run.stdout
    assert "filters_location_top:false" in run.stdout
    assert len([el for el in elements if el.get("kind") == "navigation"]) == 2
    assert doc["settings"]["navigation"]["pageTabsInViewMode"] == "shown"
    assert any(
        entry.get("name") == "backgroundCanvas" and entry.get("color") == "#EEF2F7"
        for entry in doc["settings"]["theme"]["overrides"]["colorOverrides"]
    )

    rows = {
        row["source"]: row
        for row in json.load(open(os.path.join(
            SKILL, "refs", "catalogs", "workbook-feature.json"
        )))["rows"]
    }
    for key in (
            "standalone-legend-control", "field-drill-fields", "tab-navigation-button",
            "dashboard-filter-sidebar", "page-break", "repeated-container",
            "dashboard-tabs-as-tabbed-container", "looker-boxplot"):
        assert rows[key]["sigma"] is None
        assert rows[key]["no_sigma_equiv"] is True

    print("ALL PASS")


if __name__ == "__main__":
    main()
