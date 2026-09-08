#!/usr/bin/env python3
"""Validate the focused QuickSight workbook-code release golden."""
import json
import re
import sys

spec = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(spec) == {"name", "document"}
doc = spec["document"]
assert doc["schemaVersion"] == 1 and doc["kind"] == "workbook"
assert all("elements" not in page for page in doc["pages"])
assert doc["panels"] == [] and doc["overlays"] == []
assert set(re.findall(r"</?([A-Za-z][A-Za-z0-9]*)\b", doc["layout"])) == {
    "Page", "Element", "Container",
}

elements = doc["elements"]
ids = [element["id"] for element in elements]
placed = re.findall(r'\belementId="([^"]+)"', doc["layout"])
assert sorted(ids) == sorted(placed)
assert len(placed) == len(set(placed))

by_kind = {}
for element in elements:
    by_kind.setdefault(element["kind"], []).append(element)

waterfall = by_kind["waterfall-chart"][0]
assert waterfall["splitBy"]["columnId"]
assert waterfall["waterfallShape"]["connectorLine"] == "shown"
assert waterfall["legend"] == {"visibility": "hidden"}  # live API: cannot mix
# visibility:'hidden' with legend content (position) -- oneOf branch is either
# {visibility:'hidden'} alone, or {position,...} with no visibility field.
assert by_kind["progress"][0]["max"] == "500"
assert len(by_kind["navigation"]) == 2
assert by_kind["control"][0]["controlType"] == "drill"
assert by_kind["repeated-container"][0]["source"]["groupingId"]
assert len(by_kind["page-break"]) == 2
assert "box-chart" not in by_kind
assert any(element.get("name") == "Distribution" and element["kind"] == "table"
           for element in elements)

for page_break in by_kind["page-break"]:
    match = re.search(
        rf'elementId="{re.escape(page_break["id"])}"[^>]*gridRow="(\d+) / (\d+)"',
        doc["layout"],
    )
    assert match and int(match.group(2)) - int(match.group(1)) == 1

print("QuickSight workbook-code golden: PASS")
