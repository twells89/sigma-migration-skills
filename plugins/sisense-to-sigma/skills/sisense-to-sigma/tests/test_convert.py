#!/usr/bin/env python3
"""Offline regression tests for the converter — runs against the bundled
fixtures (no network). Run: python3 tests/test_convert.py"""
import sys, os, json
HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import convert as C

FIX = os.path.join(HERE, "..", "fixtures")
model = json.load(open(os.path.join(FIX, "model_ecommerce.json")))
dashboards = json.load(open(os.path.join(FIX, "dashboards.json")))
CONN = "00000000-0000-0000-0000-000000000000"

passed = failed = 0
def ok(label, cond):
    global passed, failed
    passed += 1 if cond else 0
    failed += 0 if cond else 1
    if not cond:
        print(f"  FAIL {label}")

# --- model -> DM ---
spec, flags = C.convert_model(model, CONN, "SISENSE_ECOMMERCE", "CSA")
els = spec["pages"][0]["elements"]
ok("model: 4 elements", len(els) == 4)
ok("model: all warehouse-table (no custom-sql in ecommerce)",
   all(e["source"]["kind"] == "warehouse-table" for e in els))
ok("model: 3 relationships on fact", sum(len(e.get("relationships", [])) for e in els) == 3)
ok("model: fact element is last (after dims)", els[-1].get("relationships"))
ok("model: clean star has only direction-heuristic flags (no custom-SQL/errors)",
   all("join direction" in f["reason"] for f in flags))
# with cardinality directions supplied, no flags at all
spec2, flags2 = C.convert_model(model, CONN, "SISENSE_ECOMMERCE", "CSA",
   directions={frozenset({("Commerce","Country ID"),("Country","Country ID")}):"Commerce",
               frozenset({("Commerce","Category ID"),("Category","Category ID")}):"Commerce",
               frozenset({("Commerce","Brand ID"),("Brand","Brand ID")}):"Commerce"})
ok("model: cardinality-resolved directions -> no flags", flags2 == [])
ok("model: warehouse path uses db+schema+TABLE",
   els[0]["source"]["path"][:2] == ["CSA", "SISENSE_ECOMMERCE"])
ok("model: column formula prefix is phys table",
   els[-1]["columns"][0]["formula"].startswith("[COMMERCE/"))

# --- dashboard -> workbook ---
dm_info = {"dataModelId": "dm-x", "factElementId": "fact-x", "factName": "Commerce"}
wb, dflags = C.convert_dashboard(
    [d for d in dashboards if d.get("title") == "ECommerce Overview (Live)"], model, dm_info)
page_els = wb["pages"][1]["elements"]
controls = [e for e in page_els if e["kind"] == "control"]
viz = [e for e in page_els if e["kind"] != "control"]
kinds = [e["kind"] for e in viz]
ok("wb: master data element present", wb["pages"][0]["elements"][0]["id"] == "master")
ok("wb: 6 viz elements", len(viz) == 6)
ok("wb: has kpi-chart", "kpi-chart" in kinds)
ok("wb: has bar-chart", "bar-chart" in kinds)
ok("wb: has line-chart", "line-chart" in kinds)
ok("wb: has pie-chart", "pie-chart" in kinds)
ok("wb: dashboard filters -> controls", len(controls) == 2 and all(c["controlType"]=="list" for c in controls))
ok("wb: control bound to master + has default values", controls[0]["filters"][0]["source"]["elementId"]=="master" and controls[0]["values"])
ok("wb: viz source the master", all(e["source"]["elementId"] == "master" for e in viz))
ok("wb: master cols are cross-ref or own (no bare warehouse path)",
   all("formula" in c for c in wb["pages"][0]["elements"][0]["columns"]))

# --- layout: Sisense columnar grid -> Sigma grid XML ---
import re, xml.dom.minidom as _M
def parse_layout(xml):
    """elementId -> (col_start, col_end, row_start, row_end)."""
    out = {}
    for eid, gc, gr in re.findall(
            r'<LayoutElement elementId="([^"]+)" gridColumn="([^"]+)" gridRow="([^"]+)"', xml):
        cs, ce = (int(x) for x in gc.split(" / "))
        rs, re_ = (int(x) for x in gr.split(" / "))
        out[eid] = (cs, ce, rs, re_)
    return out

lay = wb["layout"]
_M.parseString("<r>" + lay.split("?>", 1)[1] + "</r>")        # raises if malformed
ok("layout: present + well-formed XML", lay.startswith("<?xml") and "pmain" in lay and "pdata" in lay)
P = parse_layout(lay)
all_ids = {e["id"] for e in viz} | {e["id"] for e in controls} | {"master"}
ok("layout: every element placed exactly once", all(i in P for i in all_ids))
ok("layout: no orphan placement refs", all(eid in all_ids for eid in P))
ok("layout: grid is 24-col (no element exceeds col 25)", all(ce <= 25 for _, ce, _, _ in P.values()))
# the Live dashboard's 2 KPIs auto-arrange into one card row, side by side
kpi_ids = [e["id"] for e in viz if e["kind"] == "kpi-chart"]
krows = {P[i][2] for i in kpi_ids}
ok("layout: KPIs share one row (cards, not a stack)", len(krows) == 1)
ok("layout: KPIs sit side by side (distinct columns)", len({P[i][0] for i in kpi_ids}) == len(kpi_ids))

# faithful path: a 2-column Sisense layout must port as two side-by-side stacks
multicol = {"title": "MC", "oid": "mc", "filters": [],
    "layout": {"type": "columnar", "columns": [
        {"width": 60, "cells": [{"subcells": [{"width": 100, "elements": [
            {"widgetid": "wA", "height": 512}]}]}]},
        {"width": 40, "cells": [{"subcells": [{"width": 100, "elements": [
            {"widgetid": "wB", "height": 512}]}]}]}]},
    "widgets": [
        {"oid": "wA", "type": "chart/column", "title": "A", "metadata": {"panels": [
            {"name": "categories", "items": [{"jaql": {"dim": "[Commerce.Category ID]", "title": "Cat"}}]},
            {"name": "values", "items": [{"jaql": {"dim": "[Commerce.Revenue]", "agg": "sum", "title": "Rev"}}]}]}},
        {"oid": "wB", "type": "chart/line", "title": "B", "metadata": {"panels": [
            {"name": "x-axis", "items": [{"jaql": {"dim": "[Commerce.Category ID]", "title": "Cat"}}]},
            {"name": "values", "items": [{"jaql": {"dim": "[Commerce.Revenue]", "agg": "sum", "title": "Rev"}}]}]}}]}
wb2, _ = C.convert_dashboard([multicol], model, dm_info)
viz2 = [e for e in wb2["pages"][1]["elements"] if e["kind"] != "control"]
P2 = parse_layout(wb2["layout"])
a_id, b_id = viz2[0]["id"], viz2[1]["id"]
ok("faithful: 2 cols -> wider col gets more grid (60/40 split)",
   (P2[a_id][1] - P2[a_id][0]) > (P2[b_id][1] - P2[b_id][0]))
ok("faithful: columns side by side, both start at row 1",
   P2[a_id][2] == 1 and P2[b_id][2] == 1 and P2[a_id][0] == 1 and P2[b_id][0] == P2[a_id][1])

# --- coverage classification flags the unmappable ---
rows = C.classify_dashboard(dashboards)
tags = {r["tag"] for r in rows}
ok("classify: treemap/sunburst -> MANUAL present", "MANUAL" in tags)
ok("classify: AUTO present", "AUTO" in tags)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
