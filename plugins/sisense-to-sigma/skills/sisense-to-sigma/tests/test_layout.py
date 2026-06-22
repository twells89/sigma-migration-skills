#!/usr/bin/env python3
"""Offline test for the layout-parity gate (verify_layout.py). Converts the
bundled fixtures + an inline 2-column dashboard, then runs the gate and asserts
GREEN. Run: python3 tests/test_layout.py"""
import sys, os, json, subprocess, tempfile
HERE = os.path.dirname(__file__)
SCRIPTS = os.path.join(HERE, "..", "scripts")
sys.path.insert(0, SCRIPTS)
import convert as C

FIX = os.path.join(HERE, "..", "fixtures")
model = json.load(open(os.path.join(FIX, "model_ecommerce.json")))
dm_info = {"dataModelId": "dm-x", "factElementId": "fact-x", "factName": "Commerce"}

passed = failed = 0
def ok(label, cond, extra=""):
    global passed, failed
    passed += 1 if cond else 0
    failed += 0 if cond else 1
    print(("  ok  " if cond else "  FAIL ") + label + (f"  {extra}" if extra and not cond else ""))

def run_gate(dashboards, spec):
    with tempfile.TemporaryDirectory() as td:
        dp = os.path.join(td, "dash.json"); sp = os.path.join(td, "spec.json")
        json.dump(dashboards, open(dp, "w")); json.dump(spec, open(sp, "w"))
        r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "verify_layout.py"), dp, sp],
                           capture_output=True, text=True)
        return r.returncode, r.stdout

# --- fixtures: auto-arrange path ---
dashboards = json.load(open(os.path.join(FIX, "dashboards.json")))
spec, _ = C.convert_dashboard(dashboards, model, dm_info)
rc, out = run_gate(dashboards, spec)
ok("auto-arrange fixtures -> layout gate GREEN", rc == 0 and "GREEN (all" in out, out)

# --- controls must be placed FLAT, never in a <GridContainer> ---
# (Sigma rejects a GridContainer whose elementId isn't a real container element.)
import re as _re
ctrl_ids = [e["id"] for e in spec["pages"][1]["elements"] if e.get("kind") == "control"]
lay = spec.get("layout", "")
ok("controls present in this fixture", len(ctrl_ids) >= 1, f"found {len(ctrl_ids)}")
ok("layout emits NO <GridContainer>", "GridContainer" not in lay)
placed_ids = set(_re.findall(r'<LayoutElement elementId="([^"]+)"', lay))
ok("every control placed as a flat LayoutElement", all(c in placed_ids for c in ctrl_ids),
   f"missing={[c for c in ctrl_ids if c not in placed_ids]}")

# --- inline 2-column dashboard: faithful path ---
def chart(oid, wtype, panel):
    return {"oid": oid, "type": wtype, "title": oid, "metadata": {"panels": [
        {"name": panel, "items": [{"jaql": {"dim": "[Commerce.Category ID]", "title": "Cat"}}]},
        {"name": "values", "items": [{"jaql": {"dim": "[Commerce.Revenue]", "agg": "sum", "title": "Rev"}}]}]}}
multicol = [{"title": "MC", "oid": "mc", "filters": [],
    "layout": {"type": "columnar", "columns": [
        {"width": 60, "cells": [{"subcells": [{"width": 100, "elements": [{"widgetid": "wA", "height": 512}]}]}]},
        {"width": 40, "cells": [{"subcells": [{"width": 100, "elements": [{"widgetid": "wB", "height": 512}]}]}]}]},
    "widgets": [chart("wA", "chart/column", "categories"), chart("wB", "chart/line", "x-axis")]}]
spec2, _ = C.convert_dashboard(multicol, model, dm_info)
rc2, out2 = run_gate(multicol, spec2)
ok("faithful 2-col dashboard -> layout gate GREEN", rc2 == 0 and "GREEN (all" in out2, out2)

# --- negative control: a corrupted layout (overlap) must go RED ---
bad = json.loads(json.dumps(spec2))
import re
# collapse every element onto the same grid cell -> guaranteed overlap
bad["layout"] = re.sub(r'gridColumn="[^"]+" gridRow="[^"]+"',
                       'gridColumn="1 / 13" gridRow="1 / 13"', bad["layout"])
rc3, out3 = run_gate(multicol, bad)
ok("corrupted layout (overlap) -> gate RED", rc3 != 0 and "NO-OVERLAP" in out3 and "RED" in out3)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
