#!/usr/bin/env python3
"""Structural, visual-layout, and recorded numeric-oracle checks."""

import json
import pathlib
import re
import sys

case = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
workbook_path = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else case / "golden" / "workbook.json"
workdir = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
workbook = json.loads(workbook_path.read_text())
oracle = json.loads((case / "parity-oracle.json").read_text())
doc = workbook["document"]
elements = doc["elements"]


def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


require(doc["kind"] == "workbook", "canonical workbook kind")
require(all("elements" not in page for page in doc["pages"]), "pages are metadata-only")
require(len(doc["pages"]) == 2, "Data + dashboard pages")
require(len(elements) == 9, "expected master, four controls, pivot, title, and layout chrome")

controls = [element for element in elements if element.get("kind") == "control"]
require(len(controls) == 4, "all four Tableau controls emitted")
parameter = next(element for element in controls if element.get("name") == "Summary $ Choose")
require(parameter["source"]["values"] == ["1", "2", "3"], "parameter source values")
require(
    parameter["source"]["labels"] == oracle["visual"]["parameter_labels"],
    "parameter aliases match recorded source labels",
)

pivots = [element for element in elements if element.get("kind") == "pivot-table"]
require(len(pivots) == 1, "source crosstab lowers to one pivot-table")
pivot = pivots[0]
require("totals" not in pivot, "native grand totals retained for the source crosstab")
switch_columns = [
    column
    for column in pivot.get("columns", [])
    if column.get("name") == "Summary $" and column.get("formula", "").startswith("Switch(")
]
require(len(switch_columns) == 1, "measure-switch parameter controls the pivot value")
require(
    f"[{parameter['controlId']}]" in switch_columns[0]["formula"],
    "switch formula references the emitted parameter control",
)

layout = doc["layout"]
placements = re.findall(r'elementId="([^"]+)"', layout)
ids = [element["id"] for element in elements]
require(sorted(placements) == sorted(ids), "every element is placed exactly once")
require(len(placements) == len(set(placements)), "layout has no duplicate placements")

pivot_line = next(line for line in layout.splitlines() if f'elementId="{pivot["id"]}"' in line)
require('gridColumn="6 / 25"' in pivot_line, "pivot occupies the right content region")
for control in controls:
    control_line = next(line for line in layout.splitlines() if f'elementId="{control["id"]}"' in line)
    require('gridColumn="1 / 6"' in control_line, f"{control['name']} remains in the left rail")

numeric = oracle["numeric"]
require(numeric["status"] == "recorded", "numeric oracle is explicitly recorded, not fabricated")
for assertion in numeric["assertions"]:
    require(assertion["before"] > 0 and assertion["after"] > 0, "recorded numeric values are nonzero")

if workdir:
    ir = json.loads((workdir / "workbook-ir.json").read_text())
    plan = json.loads((workdir / "workbook-compile-plan.json").read_text())
    require(ir["kind"] == "tableau-workbook-ir", "canonical source IR emitted")
    require(len(ir["workbook"]["pages"]) == 1, "IR carries one Tableau dashboard")
    require(len(ir["workbook"]["pages"][0]["zones"]) == 6, "all source zones are accounted for")
    require(plan["kind"] == "tableau-workbook-compile-plan", "compile plan emitted")
    require(plan["summary"]["blocking"] == 0, "no unsupported constructs remain")
    require(plan["summary"]["controls_lowered"] == 5, "global parameter plus page control instances lower deterministically")
    require(
        any(item.get("rule") == "viz.pivot.v1" for item in plan["visuals"]),
        "compile plan selects the pivot lowering rule",
    )

print("PASS: deterministic workbook structural, visual-layout, and recorded numeric gates")
