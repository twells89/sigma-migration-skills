#!/usr/bin/env python3
"""Regression for two build_workbook.py grid-fidelity fixes (PR: looker-grid-fidelity-gaps):

  1. Looker `looker_bar` tiles -> Sigma bar-chart with `orientation: horizontal`
     (`looker_column` stays vertical = no orientation key).
  2. Looker grid cell visualizations (vis_config.series_cell_visualizations) -> element-level
     `conditionalFormats`. Sigma data bars are sign-colored (can't vary bar color by value),
     so a Looker VALUE-colored bar (custom_colors palette) maps to a Color scale
     (`backgroundScale`, carrying the palette as the scheme); a plain bar (no palette)
     maps to `dataBars` (magnitude).

Plus unit coverage for the contract extractors (`_cell_viz` / `norm_cell_viz`).

Run: python3 tests/test_grid_fidelity.py   (exit 0 = pass)
"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
FIX = os.path.join(SKILL, "fixtures", "skilltest-orders")
VIEWS = os.path.join(FIX, "views")
DASH = os.path.join(FIX, "skilltest_orders.dashboard.lookml")
sys.path.insert(0, SCRIPTS)


def _find(spec, pred):
    out = []
    def walk(o):
        if isinstance(o, dict):
            if pred(o): out.append(o)
            for v in o.values(): walk(v)
        elif isinstance(o, list):
            for v in o: walk(v)
    walk(spec)
    return out


def test_extractors():
    """_cell_viz (live) and norm_cell_viz (offline) parse series_cell_visualizations."""
    import fetch_looker_dashboard as live
    import parse_lookml_dashboard as offline
    scv = {"order_fact.total_net_revenue": {"is_active": True,
                                            "palette": {"custom_colors": ["#e52592", "#1a73e8"]}},
           "order_fact.order_count": {"is_active": False}}  # inactive -> skipped
    for fn in (live._cell_viz, offline.norm_cell_viz):
        arg = {"series_cell_visualizations": scv} if fn is offline.norm_cell_viz \
              else {"series_cell_visualizations": scv}
        got = fn(arg)
        assert "order_fact.total_net_revenue" in got, (fn.__name__, got)
        assert got["order_fact.total_net_revenue"]["scheme"] == ["#e52592", "#1a73e8"], got
        assert "order_fact.order_count" not in got, ("inactive not skipped", got)
    # no block -> empty
    assert live._cell_viz({}) == {} and offline.norm_cell_viz({}) == {}
    print("[ok] extractors: _cell_viz + norm_cell_viz")


def build(contract):
    with tempfile.TemporaryDirectory() as d:
        cpath = os.path.join(d, "c.json"); opath = os.path.join(d, "wb.json")
        json.dump(contract, open(cpath, "w"))
        r = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS, "build_workbook.py"), cpath,
             "--views", VIEWS, "--dm-id", "dm-x", "--element-id", "el-x",
             "--dm-element-name", "Order Fact", "--out", opath],
            capture_output=True, text=True)
        assert r.returncode == 0, f"build_workbook failed:\n{r.stderr}"
        return json.load(open(opath))


def test_build():
    import parse_lookml_dashboard as offline
    contract = offline.parse(DASH)[0]  # parse() returns a list of dashboards

    # Patch: flip the column tile -> looker_bar; add a VALUE-colored cell viz to the table.
    bar_tile = grid_tile = None
    for el in contract["elements"]:
        if el.get("tileType") == "looker_column":
            el["tileType"] = "looker_bar"; bar_tile = el["name"]
        if el.get("tileType") == "table":
            el["cellVisualizations"] = {
                "order_fact.total_net_revenue": {"scheme": ["#e52592", "#7b4ebf", "#1a73e8"]}}
            grid_tile = el["name"]
    assert bar_tile and grid_tile, "fixture missing column/table tiles"

    spec = build(contract)

    # (1) the flipped tile is a horizontal bar-chart; the pie/other charts are NOT.
    bars = _find(spec, lambda o: o.get("kind") == "bar-chart")
    assert bars, "no bar-chart emitted"
    assert all(b.get("orientation") == "horizontal" for b in bars), \
        [(b.get("name"), b.get("orientation")) for b in bars]
    for o in _find(spec, lambda o: o.get("kind") in ("pie-chart", "line-chart", "kpi-chart")):
        assert "orientation" not in o, f"orientation leaked onto {o.get('kind')}"
    print(f"[ok] orientation: looker_bar '{bar_tile}' -> bar-chart orientation=horizontal")

    # (2a) VALUE-colored Looker bars -> Sigma Color scale (backgroundScale), NOT dataBars
    #      (Sigma data bars are sign-colored — can't vary bar color by value).
    tables = _find(spec, lambda o: o.get("kind") == "table" and o.get("conditionalFormats"))
    assert tables, "no table with conditionalFormats emitted"
    cf = tables[0]["conditionalFormats"][0]
    assert cf["type"] == "backgroundScale", f"expected backgroundScale for value palette, got {cf}"
    assert cf["scheme"] == ["#e52592", "#7b4ebf", "#1a73e8"], cf
    colids = {c["id"] for c in tables[0]["columns"]}
    assert cf["columnIds"] and set(cf["columnIds"]) <= colids, (cf["columnIds"], colids)
    print(f"[ok] color scale: value-colored grid '{grid_tile}' -> backgroundScale (scheme carried)")

    # (2b) a PLAIN Looker bar (no value palette) -> dataBars (magnitude).
    contract2 = offline.parse(DASH)[0]
    for el in contract2["elements"]:
        if el.get("tileType") == "table":
            el["cellVisualizations"] = {"order_fact.total_net_revenue": {"scheme": None}}
    spec2 = build(contract2)
    t2 = _find(spec2, lambda o: o.get("kind") == "table" and o.get("conditionalFormats"))
    assert t2 and t2[0]["conditionalFormats"][0]["type"] == "dataBars", \
        ("expected dataBars for plain bar", t2 and t2[0].get("conditionalFormats"))
    assert "scheme" not in t2[0]["conditionalFormats"][0], "plain dataBars must not carry a scheme"
    print("[ok] dataBars: plain Looker bar (no value palette) -> dataBars (magnitude)")


if __name__ == "__main__":
    test_extractors()
    test_build()
    print("ALL PASS")
