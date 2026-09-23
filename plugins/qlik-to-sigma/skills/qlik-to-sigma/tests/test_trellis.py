#!/usr/bin/env python3
"""test_trellis.py — e2e for the Qlik native-trellis path in build-sigma-workbook.py.

Builds a synthetic Qlik app (charts.json + denorm.json) that carries every
trellis shape and asserts the ONE-faceted-element outcome, delegated to the
shared TrellisEmit (supported-kind gate + fallbacks):

  1. chart-level trellis (bar, cols)  -> ONE bar-chart + trellis.columnsBy
  2. chart-level trellis (line, rows) -> ONE line-chart + trellis.rowsBy
  3. faceted PIE                       -> flipped to donut-chart + trellis (pie strips it)
  4. trellis-CONTAINER wrapping a bar  -> ONE bar-chart on the CONTAINER's id;
                                          the base child is NOT emitted standalone
  5. 2-D grid (primary + secondary)    -> trellis.rowsBy AND columnsBy, 2 columns
  6. faceted KPI                       -> left FLAT (no native KPI trellis fallback)
  7. NON-trellis bar                   -> no `trellis` key (byte-identical shape)
Plus: the round-trip sidecar native-trellis-emitted.json lists exactly the
emitted (supported) elements, and re-verifies GREEN against a faithful readback
and FAILS against a stripped one (verify_trellis_survived.py).

Run: python3 tests/test_trellis.py   (exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
BUILDER = os.path.join(SCRIPTS, "build-sigma-workbook.py")
VERIFY = os.path.join(SCRIPTS, "verify_trellis_survived.py")

DENORM = {"element": {"columns": [
    {"name": "Region",   "formula": "[Custom SQL/REGION]"},
    {"name": "Category", "formula": "[Custom SQL/CATEGORY]"},
    {"name": "Month",    "formula": "[Custom SQL/MONTH]"},
    {"name": "Revenue",  "formula": "[Custom SQL/REVENUE]"},
]}}

_SORT = {"interColumnSortOrder": [], "dimensions": [[]], "measures": [{}]}


def _chart(cid, vt, dims, title, **extra):
    c = {"id": cid, "vizType": vt, "title": title, "sheet": None,
         "dimensions": [[d] for d in dims], "dimLabels": [None] * len(dims),
         "dimNullSuppression": [False] * len(dims),
         "measures": ["Sum(REVENUE)"], "measureLabels": ["Revenue"], "measureFmts": [None],
         "sort": _SORT}
    c.update(extra)
    return c


CHARTS = [
    _chart("bar-tr", "barchart", ["CATEGORY"], "Rev by Category / Region",
           trellis={"field": "REGION", "orientation": "cols", "label": "Region"}),
    _chart("line-tr", "linechart", ["MONTH"], "Rev over Month / Region",
           trellis={"field": "REGION", "orientation": "rows"}),
    _chart("pie-tr", "piechart", ["CATEGORY"], "Rev share / Region",
           trellis={"field": "REGION", "orientation": "cols"}),
    # trellis container + its base child (child must NOT emit standalone)
    _chart("cont-base", "barchart", ["CATEGORY"], "Base bar"),
    {"id": "tc-1", "vizType": "trellis-container", "title": "Container by Region",
     "children": ["cont-base"], "trellis": {"field": "REGION", "orientation": "cols"},
     "dimensions": [], "measures": [], "sort": _SORT},
    _chart("grid-tr", "barchart", ["CATEGORY"], "2-D grid",
           trellis={"field": "REGION", "secondary": "MONTH", "orientation": "cols"}),
    _chart("kpi-tr", "kpi", [], "KPI faceted",
           trellis={"field": "REGION", "orientation": "cols"}),
    _chart("plain-bar", "barchart", ["CATEGORY"], "Plain bar (no trellis)"),
]

_fail = 0


def ok(name, cond):
    global _fail
    print(("  ok  " if cond else "FAIL  ") + name)
    if not cond:
        _fail += 1


def build(charts):
    d = tempfile.mkdtemp()
    cp = os.path.join(d, "charts.json"); json.dump(charts, open(cp, "w"))
    dp = os.path.join(d, "denorm.json"); json.dump(DENORM, open(dp, "w"))
    sp = os.path.join(d, "spec.json")
    r = subprocess.run(
        [sys.executable, BUILDER, "--charts", cp, "--denorm", dp, "--dm-id", "dm-x",
         "--denorm-element-id", "el-x", "--name", "TRELLIS", "--dry-run",
         "--spec-out", sp, "--out", os.path.join(d, "res.json"),
         "--element-map", os.path.join(d, "emap.json"), "--layout-out", os.path.join(d, "l.xml")],
        capture_output=True, text=True)
    assert r.returncode == 0, "builder failed:\n" + r.stderr
    spec = json.load(open(sp))
    doc = spec["document"]
    assert all("elements" not in page for page in doc["pages"])
    els = {e["id"]: e for e in doc["elements"]}
    return els, d, (r.stdout + r.stderr)


def main():
    els, workdir, out = build(CHARTS)

    def facet_formula(el, colid):
        return next((c["formula"] for c in el["columns"] if c["id"] == colid), None)

    # 1) chart-level bar, cols -> columnsBy on a Region facet column
    e = els["el-bartr"]
    ok("bar chart-level trellis -> bar-chart kind kept", e["kind"] == "bar-chart")
    cb = e.get("trellis", {}).get("columnsBy")
    ok("bar trellis.columnsBy set", bool(cb) and "rowsBy" not in e["trellis"])
    ok("bar facet column is [Master/Region]",
       cb and facet_formula(e, cb[0]["columnId"]) == "[Master/Region]")

    # 2) line, rows -> rowsBy
    e = els["el-linetr"]
    ok("line trellis.rowsBy set (and not columnsBy)",
       e.get("trellis", {}).get("rowsBy") and "columnsBy" not in e["trellis"] and e["kind"] == "line-chart")

    # 3) pie -> donut fallback + trellis
    e = els["el-pietr"]
    ok("faceted pie flipped to donut-chart", e["kind"] == "donut-chart")
    ok("pie->donut carries trellis.columnsBy", bool(e.get("trellis", {}).get("columnsBy")))

    # 4) trellis container -> element on the CONTAINER id; child not standalone
    ok("container emits ONE element on the container id el-tc1", "el-tc1" in els)
    ok("container element is the base bar-chart + trellis",
       els["el-tc1"]["kind"] == "bar-chart" and bool(els["el-tc1"].get("trellis")))
    ok("base child NOT emitted standalone (el-contbase absent)", "el-contbase" not in els)

    # 5) 2-D grid -> rowsBy AND columnsBy, two distinct columns
    e = els["el-gridtr"]
    tr = e.get("trellis", {})
    ok("grid trellis has BOTH rowsBy and columnsBy", bool(tr.get("rowsBy")) and bool(tr.get("columnsBy")))
    ok("grid facets are two distinct columns",
       tr and tr["rowsBy"][0]["columnId"] != tr["columnsBy"][0]["columnId"])
    ok("grid rowsBy=Region, columnsBy=Month",
       tr and facet_formula(e, tr["rowsBy"][0]["columnId"]) == "[Master/Region]"
       and facet_formula(e, tr["columnsBy"][0]["columnId"]) == "[Master/Month]")

    # 6) kpi -> left flat (no native KPI trellis)
    e = els["el-kpitr"]
    ok("faceted KPI left FLAT (no trellis key, kind kpi-chart)",
       "trellis" not in e and e["kind"] == "kpi-chart")
    ok("KPI fallback warned", "does NOT support a native trellis" in out and "kpi-chart" in out)

    # 7) non-trellis bar -> no trellis key
    ok("plain bar has NO trellis key", "trellis" not in els["el-plainbar"])

    # sidecar: exactly the emitted (supported) elements, correct axis
    nt = json.load(open(os.path.join(workdir, "native-trellis-emitted.json")))
    ids = {r["element_id"]: r["axis"] for r in nt["elements"]}
    ok("sidecar lists the 5 emitted trellis elements (bar/line/pie->donut/container/grid)",
       set(ids) == {"el-bartr", "el-linetr", "el-pietr", "el-tc1", "el-gridtr"})
    ok("sidecar excludes the flat KPI + plain bar",
       "el-kpitr" not in ids and "el-plainbar" not in ids)
    ok("sidecar axis: line=rowsBy, bar=columnsBy", ids.get("el-linetr") == "rowsBy" and ids.get("el-bartr") == "columnsBy")

    # readback guard: GREEN against a faithful readback, RED against a stripped one
    if os.path.exists(VERIFY):
        spec_ok = {"document": {"pages": [{"id": "p", "name": "P"}],
                               "elements": [dict(els[i], id=i) for i in ids],
                               "layout": '<Page id="p"></Page>'}}
        rp = os.path.join(workdir, "readback-ok.json"); json.dump({"spec": spec_ok}, open(rp, "w"))
        g = subprocess.run([sys.executable, VERIFY, "--emitted", os.path.join(workdir, "native-trellis-emitted.json"),
                            "--spec", rp], capture_output=True, text=True)
        ok("verify-trellis-survived PASSES on a faithful readback", g.returncode == 0)
        # strip every trellis on the readback -> must FAIL
        spec_bad = {"document": {"pages": [{"id": "p", "name": "P"}],
                                "elements": [{"id": i, "kind": els[i]["kind"]} for i in ids],
                                "layout": '<Page id="p"></Page>'}}
        bp = os.path.join(workdir, "readback-stripped.json"); json.dump({"spec": spec_bad}, open(bp, "w"))
        b = subprocess.run([sys.executable, VERIFY, "--emitted", os.path.join(workdir, "native-trellis-emitted.json"),
                            "--spec", bp], capture_output=True, text=True)
        ok("verify-trellis-survived FAILS when Sigma strips the trellis", b.returncode != 0)
    else:
        print("  --   verify_trellis_survived.py not found; skipped readback guard assertions")

    # byte-identical: a charts.json with EVERY trellis signal removed emits no
    # trellis and no sidecar.
    flat_charts = [dict(c) for c in CHARTS if c["vizType"] != "trellis-container"]
    for c in flat_charts:
        c.pop("trellis", None)
    els2, wd2, _ = build(flat_charts)
    ok("no-signal build emits ZERO trellis keys",
       not any("trellis" in e for e in els2.values()))
    ok("no-signal build writes NO sidecar",
       not os.path.exists(os.path.join(wd2, "native-trellis-emitted.json")))

    print()
    if _fail == 0:
        print("ALL PASS — Qlik native trellis (chart-level + container; supported-kind gate; "
              "pie->donut; kpi flat; 2-D grid; readback guard; byte-identical no-op)")
        sys.exit(0)
    print("%d FAILURE(S)" % _fail)
    sys.exit(1)


if __name__ == "__main__":
    main()
