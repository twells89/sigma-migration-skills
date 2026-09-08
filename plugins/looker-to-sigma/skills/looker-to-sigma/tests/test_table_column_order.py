#!/usr/bin/env python3
"""Table column ORDER + HIDDEN-column fidelity (Looker viz order vs. data order).

Looker exposes two column orders for a table: `query.fields` (the Data-tab order, which
forces dimensions before measures) and `vis_config.column_order` (the Visualization
order the user set by dragging columns). The migration must reproduce the VIZ order.

Columns hidden from the visualization stay IN the query, so a hidden DIMENSION still
sets the GROUP-BY grain (and therefore every measure value). They must be hidden in
Sigma's presentation, NEVER dropped — dropping a hidden dimension would silently change
the numbers.

Drives the REAL build_workbook.py against the vendored skilltest-looks fixtures with
in-memory-patched contracts (`columnOrder` / `hiddenFields` — exactly what
fetch_looker_dashboard.normalize_element now emits). No live warehouse.

Run: python3 tests/test_table_column_order.py   (exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "skilltest-looks")
VIEWS = os.path.join(FIX, "views")
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))
import code_rep  # noqa: E402

# display names build_workbook derives via disp(leaf(field)) for the grouped_table fixture
REGION, CATEGORY = "Region", "Category"
TNR, DOC, AOV = "Total Net Revenue", "Distinct Order Count", "Average Order Value"


def _load(name):
    return json.load(open(os.path.join(FIX, f"look_{name}.contract.json")))


def build(contract):
    with tempfile.TemporaryDirectory() as d:
        cp = os.path.join(d, "c.json")
        op = os.path.join(d, "wb.json")
        json.dump(contract, open(cp, "w"))
        r = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS, "build_workbook.py"), cp,
             "--views", VIEWS, "--dm-element-name", "Order Fact View", "--out", op],
            capture_output=True, text=True)
        assert r.returncode == 0, f"build_workbook failed:\n{r.stderr}"
        return json.load(open(op)), (r.stdout + r.stderr)


def _element(spec, kind):
    els = [e for e in code_rep.workbook_elements(spec)
           if e.get("kind") == kind and e.get("name") != "Data"]
    assert len(els) == 1, f"expected one {kind}, got {[e.get('kind') for e in els]}"
    return els[0]


def _names(el):
    return [c.get("name") for c in el.get("columns", [])]


def _grouping(el):
    g = (el.get("groupings") or [{}])[0]
    idname = {c["id"]: c.get("name") for c in el.get("columns", [])}
    return ([idname.get(i) for i in g.get("groupBy", [])],
            [idname.get(i) for i in g.get("calculations", [])])


def test_fallback_no_column_order():
    """No columnOrder → columns stay in query.fields order (current behavior)."""
    spec, _ = build(_load("grouped_table"))
    t = _element(spec, "table")
    assert _names(t) == [REGION, CATEGORY, TNR, DOC, AOV], _names(t)
    print("[ok] fallback: fields order preserved when no columnOrder")


def test_reorder_measure_first_interleaved():
    """columnOrder wins: a measure can lead and dims/measures interleave freely."""
    c = _load("grouped_table")
    c["elements"][0]["columnOrder"] = [
        "order_fact.total_net_revenue", "customer_dim.region",
        "order_fact.average_order_value", "product_dim.category",
        "order_fact.distinct_order_count"]
    t = _element(build(c)[0], "table")
    assert _names(t) == [TNR, REGION, AOV, CATEGORY, DOC], _names(t)
    gb, calc = _grouping(t)
    assert gb == [REGION, CATEGORY], gb          # both dims still grouped (in display order)
    assert calc == [TNR, AOV, DOC], calc         # measures in display order
    print("[ok] reorder: columns follow columnOrder; grouping membership intact")


def test_partial_column_order_appends_rest():
    """Fields absent from columnOrder append in fields order (Looker appends new fields)."""
    c = _load("grouped_table")
    c["elements"][0]["columnOrder"] = ["order_fact.average_order_value", "customer_dim.region"]
    t = _element(build(c)[0], "table")
    # listed first (AOV, Region), then the remainder in fields order (Category, TNR, DOC)
    assert _names(t) == [AOV, REGION, CATEGORY, TNR, DOC], _names(t)
    print("[ok] partial columnOrder: listed first, remainder in fields order")


def test_hidden_dimension_preserves_grain():
    """A hidden DIMENSION is hidden in Sigma but STAYS in groupBy (grain unchanged)."""
    c = _load("grouped_table")
    c["elements"][0]["hiddenFields"] = ["customer_dim.region"]
    spec, log = build(c)
    t = _element(spec, "table")
    col = {c_["name"]: c_ for c_ in t["columns"]}
    assert col[REGION].get("hidden") is True, "hidden dim column must carry hidden:true"
    assert col[CATEGORY].get("hidden") in (None, False), "visible dim must not be hidden"
    gb, _ = _grouping(t)
    assert REGION in gb, "hidden dimension MUST remain in groupBy (grain preservation)"
    assert "hidden" in log.lower() and "group-by" in log.lower(), \
        "expected a grain-preservation warning mentioning the group-by"
    print("[ok] hidden dim: hidden:true but kept in groupBy + warned")


def test_hidden_measure_flagged_not_dropped():
    """A hidden MEASURE is flagged hidden but still emitted as a calculation column."""
    c = _load("grouped_table")
    c["elements"][0]["hiddenFields"] = ["order_fact.average_order_value"]
    t = _element(build(c)[0], "table")
    col = {c_["name"]: c_ for c_ in t["columns"]}
    assert col[AOV].get("hidden") is True, "hidden measure column must carry hidden:true"
    _, calc = _grouping(t)
    assert AOV in calc, "hidden measure still a calculation (present, just hidden)"
    print("[ok] hidden measure: hidden:true, still a calculation")


def test_custom_column_labels():
    """Viz series_labels (contract columnLabels) override the default humanized name."""
    c = _load("grouped_table")
    c["elements"][0]["columnLabels"] = {
        "customer_dim.region": "Sales Region",
        "order_fact.total_net_revenue": "Revenue ($)"}
    t = _element(build(c)[0], "table")
    names = _names(t)
    assert "Sales Region" in names, names             # relabeled dimension
    assert "Revenue ($)" in names, names              # relabeled measure
    assert REGION not in names and TNR not in names, names  # defaults replaced
    assert CATEGORY in names, names                   # unlabeled column keeps its default
    print("[ok] custom labels: viz series_labels override default column names")


def test_pivot_reorder_rows():
    """Pivot rowsBy order follows columnOrder; the pivot field stays on the column shelf."""
    c = _load("pivot_table")
    el = c["elements"][0]
    # add a 2nd row dimension so row order is observable (fixture ships only one)
    el["fields"] = ["customer_dim.region", "product_dim.category", "order_fact.total_net_revenue"]
    c["fieldMeta"]["product_dim.category"] = {"category": "dimension"}
    # viz order puts Category BEFORE Region
    el["columnOrder"] = ["product_dim.category", "customer_dim.region", "order_fact.total_net_revenue"]
    p = _element(build(c)[0], "pivot-table")
    idname = {col["id"]: col.get("name") for col in p["columns"]}
    rows = [idname.get(r.get("columnId") or r.get("id")) for r in p.get("rowsBy", [])]
    vals = [idname.get(v) for v in p.get("values", [])]
    cols_shelf = [idname.get(cb.get("columnId") or cb.get("id")) for cb in p.get("columnsBy", [])]
    assert rows == [CATEGORY, REGION], rows          # rowsBy follows columnOrder
    assert vals == [TNR], vals                       # measure on the value shelf
    assert cols_shelf == ["Order Channel"], cols_shelf  # pivot stays on the column shelf
    print("[ok] pivot: rowsBy follows columnOrder; pivot stays on column shelf")


if __name__ == "__main__":
    test_fallback_no_column_order()
    test_reorder_measure_first_interleaved()
    test_partial_column_order_appends_rest()
    test_hidden_dimension_preserves_grain()
    test_hidden_measure_flagged_not_dropped()
    test_custom_column_labels()
    test_pivot_reorder_rows()
    print("ALL PASS")
