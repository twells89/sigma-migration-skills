#!/usr/bin/env python3
"""Grounding test for the QlikView (.qvw) "-prj" migration path.

Offline (no Sigma): runs qlik-prj-discover.py over the committed real-schema fixture
and asserts it produces the Qlik-Sense-shaped discovery artifacts the rest of the
pipeline (convert -> data model -> workbook) consumes — so QlikView reuses that
machinery unchanged. The LIVE end-to-end (DM + workbook POST, 0 error columns,
faithful render) is exercised by a full `migrate-qlik.rb --prj` run in review.

The fixture's chart XML uses the AUTHENTIC QlikView schema (<GraphProperties> /
<GraphMode> / ChartDimensionDataDef / ArrayOfMainExpressionData), and the same
parser was validated against a genuine QVSource .qvw -prj export.

Run: python3 tests/test_qlikview_prj.py   (exit 0 = pass)
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "qlikview-retail-prj")


def _discover():
    d = tempfile.mkdtemp()
    r = subprocess.run(["python3", os.path.join(SCRIPTS, "qlik-prj-discover.py"),
                        "--prj", FIX, "--out", d], capture_output=True, text=True)
    assert r.returncode == 0, "qlik-prj-discover failed:\n" + r.stdout + r.stderr
    load = lambda n: json.load(open(os.path.join(d, n)))
    assert os.path.exists(os.path.join(d, "script.qvs")), "script.qvs not emitted"
    return load("charts.json"), load("layout.json"), load("converter-input.json"), load("measures.json")


def test_charts():
    charts, _, _, _ = _discover()
    by_id = {c["id"]: c for c in charts}
    assert len(charts) == 4, [c["id"] for c in charts]
    # GraphMode -> vizType mapping (bar/pie/line/straight-table)
    assert {c["vizType"] for c in charts} == {"barchart", "piechart", "linechart", "table"}, \
        {c["id"]: c["vizType"] for c in charts}
    bar = by_id["CH01"]
    assert bar["vizType"] == "barchart" and bar["title"] == "Net Revenue by Category"
    assert bar["dimensions"] == [["CATEGORY"]] and bar["measures"] == ["Sum(NET_REVENUE)"]
    assert bar["measureLabels"] == ["Net Revenue"]
    tbl = by_id["CH04"]
    assert tbl["vizType"] == "table" and len(tbl["measures"]) == 3   # multi-measure table


def test_layout():
    _, layout, _, _ = _discover()
    assert len(layout) == 1
    sh = layout[0]
    assert sh["title"] == "Executive Overview" and sh["columns"] == 24
    cells = {c["objectId"]: c for c in sh["cells"]}
    assert set(cells) == {"CH01", "CH02", "CH03", "CH04"}
    for c in cells.values():                      # a real grid rect, in-bounds
        assert 0 <= c["col"] < 24 and c["col"] + c["colspan"] <= 24
        assert c["row"] >= 0 and c["rowspan"] >= 1
    # 2x2 -> two distinct columns and two distinct rows
    assert len({c["col"] for c in cells.values()}) == 2
    assert len({c["row"] for c in cells.values()}) == 2


def test_converter_input():
    _, _, conv, measures = _discover()
    assert {t["name"] for t in conv["tables"]} == {"ORDER_FACT", "CUSTOMER_DIM", "PRODUCT_DIM"}
    assert len(conv["masterMeasures"]) >= 3 and all("qDef" in m for m in conv["masterMeasures"])
    assert len(measures) >= 3 and all("expr" in m for m in measures)


def test_delegation():
    # migrate-qlik.rb --prj must auto-detect a -prj folder and hand off to discovery.
    src = open(os.path.join(SCRIPTS, "migrate-qlik.rb")).read()
    assert "qlik-prj-discover.py" in src and "opts[:from] = disc_dir" in src, \
        "migrate-qlik.rb --prj does not delegate to qlik-prj-discover.py"


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted((n, f) for n, f in globals().items() if n.startswith("test_")):
        try:
            fn(); print(f"ok  {name}")
        except AssertionError as e:
            fails += 1; print(f"FAIL {name}: {e}")
    sys.exit(1 if fails else 0)
