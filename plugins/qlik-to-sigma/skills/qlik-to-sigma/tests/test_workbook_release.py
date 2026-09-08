#!/usr/bin/env python3
"""Focused workbook-as-code release coverage for the Qlik builder."""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
BUILDER = os.path.join(SKILL, "scripts", "build-sigma-workbook.py")

DENORM = {"element": {"columns": [
    {"name": "Category", "formula": "[Custom SQL/CATEGORY]"},
    {"name": "Region", "formula": "[Custom SQL/REGION]"},
    {"name": "City", "formula": "[Custom SQL/CITY]"},
    {"name": "Revenue", "formula": "[Custom SQL/REVENUE]"},
    {"name": "Cost", "formula": "[Custom SQL/COST]"},
]}}
SORT = {"interColumnSortOrder": [], "dimensions": [[]], "measures": [{}]}


def chart(cid, viz, dims=None, measures=None, **extra):
    dims = dims or []
    measures = measures or ["Sum(REVENUE)"]
    row = {
        "id": cid, "vizType": viz, "title": extra.pop("title", cid),
        "dimensions": [[d] for d in dims], "dimLabels": [None] * len(dims),
        "dimNullSuppression": [False] * len(dims),
        "measures": measures, "measureLabels": [None] * len(measures),
        "measureFmts": [None] * len(measures), "sort": SORT,
    }
    row.update(extra)
    return row


CHARTS = [
    chart("wf", "waterfallchart", ["CATEGORY"], title="Revenue waterfall"),
    chart("gauge", "gauge", [], title="Capacity", gauge={"min": 10, "max": 90, "shape": "ring"}),
    chart("box", "boxplot", ["CATEGORY"], title="Revenue distribution"),
    chart("styled", "barchart", ["CATEGORY"], title="Styled drill chart",
          legend={"show": False, "dock": "right"},
          presentation={"orientation": "horizontal", "grouping": "normalized", "showLabels": False},
          drillGroups=[{"dimensionIndex": 0, "fields": ["REGION", "CITY"],
                        "labels": ["Region", "City"]}]),
    chart("scatter", "scatterplot", ["CATEGORY"],
          measures=["Sum(REVENUE)", "Sum(COST)"], title="Revenue vs cost",
          color={"mode": "primary"}),
    {"id": "lb", "vizType": "listbox", "title": "Region", "dimensions": [],
     "measures": [], "listbox": {"field": "REGION", "label": "Region", "tags": []}},
    {"id": "fp", "vizType": "filterpane", "title": "Filters", "dimensions": [],
     "measures": [], "children": ["lb"]},
    chart("tab-bar", "barchart", ["CATEGORY"], title="Bar tab"),
    chart("tab-line", "linechart", ["CATEGORY"], title="Line tab"),
    {"id": "tabs", "vizType": "container", "title": "Alternate views",
     "dimensions": [], "measures": [], "children": ["tab-bar", "tab-line"],
     "childLabels": ["Bar", "Line"]},
]


def cell(oid, col, row, width=8, height=4):
    return {"objectId": oid, "col": col, "row": row, "colspan": width, "rowspan": height}


LAYOUT = [
    {"sheetId": "s1", "title": "Overview", "rank": 0, "columns": 24, "rows": 12,
     "cells": [
         cell("fp", 0, 0, 24, 2), cell("wf", 0, 2), cell("gauge", 8, 2),
         cell("box", 16, 2), cell("styled", 0, 6, 12), cell("scatter", 12, 6, 12),
     ]},
    {"sheetId": "s2", "title": "Details", "rank": 1, "columns": 24, "rows": 12,
     "cells": [cell("tabs", 0, 0, 24, 10)]},
]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        charts = os.path.join(tmp, "charts.json")
        denorm = os.path.join(tmp, "denorm.json")
        layout = os.path.join(tmp, "layout.json")
        spec_out = os.path.join(tmp, "spec.json")
        json.dump(CHARTS, open(charts, "w"))
        json.dump(DENORM, open(denorm, "w"))
        json.dump(LAYOUT, open(layout, "w"))
        run = subprocess.run([
            sys.executable, BUILDER, "--charts", charts, "--layout", layout,
            "--denorm", denorm, "--dm-id", "dm-x", "--denorm-element-id", "el-x",
            "--name", "Release", "--folder", "folder-x", "--dry-run",
            "--spec-out", spec_out, "--out", os.path.join(tmp, "result.json"),
            "--layout-out", os.path.join(tmp, "layout.xml"),
            "--element-map", os.path.join(tmp, "elements.json"),
        ], capture_output=True, text=True)
        assert run.returncode == 0, run.stderr
        spec = json.load(open(spec_out))

    assert spec["name"] == "Release" and spec["folderId"] == "folder-x"
    assert set(spec) == {"name", "folderId", "document"}
    doc = spec["document"]
    assert doc["schemaVersion"] == 1 and doc["kind"] == "workbook"
    assert doc["layout"] and all("elements" not in page for page in doc["pages"])
    assert "<Element " in doc["layout"] and "<Container " in doc["layout"]
    assert "<LayoutElement" not in doc["layout"] and "<GridContainer" not in doc["layout"]
    elements = {element["id"]: element for element in doc["elements"]}
    ids = list(elements)
    layout_ids = re.findall(r'\belementId="([^"]+)"', doc["layout"])
    assert sorted(ids) == sorted(layout_ids)
    assert len(layout_ids) == len(set(layout_ids)), "every element must be placed exactly once"

    assert elements["el-wf"]["kind"] == "waterfall-chart"
    assert elements["el-wf"]["xAxis"]["columnId"]
    progress = elements["el-gauge"]
    assert progress["kind"] == "progress"
    assert (progress["min"], progress["max"], progress["shape"]) == ("10", "90", "ring")
    assert isinstance(progress["value"], str) and "source" not in progress
    box = elements["el-box"]
    assert box["kind"] == "box-chart"
    assert box["xAxis"]["columnId"] and box["yAxis"]["columnIds"]

    styled = elements["el-styled"]
    assert styled["legend"] == {"visibility": "hidden"}
    assert "orientation" not in styled and styled["stacking"] == "normalized"
    assert "HORIZONTAL ORIENTATION GAP" in run.stderr
    assert styled["dataLabel"]["labels"] == "hidden"
    assert "MANUAL GAP" in run.stderr and "REGION > CITY" in run.stderr

    navs = [element for element in doc["elements"] if element["kind"] == "navigation"]
    assert len(navs) == 2
    assert all(nav["mode"] == "auto" and nav["pageLabels"] == [
        {"pageId": "pg-1", "label": "Overview"},
        {"pageId": "pg-2", "label": "Details"},
    ] for nav in navs)

    tabs = elements["el-tabs"]
    assert tabs == {"id": "el-tabs", "kind": "tabbed-container",
                    "tabs": [{"name": "Bar"}, {"name": "Line"}]}
    assert '<TabbedContainer elementId="el-tabs"' in doc["layout"]
    assert doc["layout"].count('elementId="el-tabbar"') == 1
    assert doc["layout"].count('elementId="el-tabline"') == 1

    control = elements["el-lb"]
    target = control["filters"][0]
    assert target["source"] == {"kind": "table", "elementId": "m-master"}
    assert target["columnId"] == "o1"
    value_source = control["source"]["source"]
    assert value_source == {"kind": "table", "elementId": "m-master"}

    scatter = elements["el-scatter"]
    grouped = elements["el-scatter-src"]
    assert scatter["source"]["groupingId"] == grouped["groupings"][0]["id"]
    assert scatter["source"]["elementId"] == grouped["id"]
    assert scatter["color"] == {"by": "single", "value": "#4477AA"}
    print("ALL PASS")


if __name__ == "__main__":
    main()
