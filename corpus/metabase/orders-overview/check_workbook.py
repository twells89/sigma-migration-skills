#!/usr/bin/env python3
"""Behavioral pins for the Metabase workbook corpus golden."""

import json
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
raw = json.loads((HERE / "golden" / "workbook.json").read_text(encoding="utf-8"))
workbook = raw["workbook"]
doc = workbook["document"]
elements = doc["elements"]

assert doc["kind"] == "workbook"
assert all("elements" not in page for page in doc["pages"])
assert any(page.get("name") == "Data" and page.get("visibility") == "hidden"
           for page in doc["pages"])

layout = doc["layout"]
assert "<Page " in layout and "<Element " in layout
assert "<LayoutElement" not in layout and "<GridContainer" not in layout
positioned = re.findall(r'<Element\b[^>]*\belementId="([^"]+)"', layout)
declared = [element["id"] for element in elements]
assert len(positioned) == len(declared)
assert len(positioned) == len(set(positioned))

by_kind = {}
for element in elements:
    by_kind.setdefault(element["kind"], []).append(element)

pie = by_kind["pie-chart"][0]
assert set(pie["value"]) == {"columnId"}
assert set(pie["color"]) >= {"columnId"}

pivot = by_kind["pivot-table"][0]
assert pivot["rowsBy"] and pivot["columnsBy"]
assert all(set(item) >= {"columnId"} and "id" not in item
           for item in pivot["rowsBy"] + pivot["columnsBy"])
assert all(isinstance(value, str) for value in pivot["values"])

funnel = by_kind["funnel-chart"][0]
assert set(funnel["stage"]) == {"columnId"}
assert set(funnel["series"]) == {"columnId"}

index = {element["id"]: i for i, element in enumerate(elements)}
for control in by_kind["control"]:
    for target in control.get("filters", []):
        assert index[target["source"]["elementId"]] < index[control["id"]]

print("metabase workbook code-representation checks: PASS")
