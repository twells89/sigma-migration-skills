#!/usr/bin/env python3
import json
import re
import sys


with open(sys.argv[1], encoding="utf-8") as handle:
    envelope = json.load(handle)

assert envelope["name"] == "Power BI Workbook Code Release"
assert "pages" not in envelope and "elements" not in envelope
document = envelope["document"]
assert document["schemaVersion"] == 1 and document["kind"] == "workbook"
assert document["layout"]
assert "<Element " in document["layout"]
assert not re.search(r"<(?:LayoutElement|GridContainer)\b", document["layout"])
assert all("elements" not in page for page in document["pages"])

elements = document["elements"]
ids = [element["id"] for element in elements]
placed = re.findall(r'\belementId="([^"]+)"', document["layout"])
assert sorted(ids) == sorted(placed)
assert len(ids) == len(set(ids)) == len(set(placed))

waterfall = next(element for element in elements if element["kind"] == "waterfall-chart")
assert waterfall["splitBy"]["columnId"]
assert waterfall["waterfallShape"] == {"calculation": "sum", "connectorLine": "shown"}
assert waterfall["legend"] == {"visibility": "hidden"}

drill = next(element for element in elements if element.get("controlType") == "drill")
assert len(drill["categories"]) == 2
assert drill["targets"][0]["source"]["elementId"] == waterfall["id"]
assert len(drill["targets"][0]["columnIds"]) == 2

legend = next(element for element in elements if element.get("controlType") == "legend")
legend_chart = next(element for element in elements if element.get("name") == "Regional Trend")
assert legend["source"]["columnId"] == "sales-region"
assert legend["targets"] == [{
    "source": {"kind": "table", "elementId": legend_chart["id"]},
    "columnId": legend_chart["color"]["column"],
}]
assert legend_chart["legend"] == {"visibility": "hidden"}

progress = next(element for element in elements if element["kind"] == "progress")
assert progress["shape"] == "ring" and progress["mode"] == "value"
assert any(element["kind"] == "navigation" and element["mode"] == "auto"
           for element in elements)

unsupported = {"box-chart", "page-break", "tabbed-container", "repeated-container"}
assert not unsupported.intersection(element["kind"] for element in elements)
assert document.get("panels", []) == []
