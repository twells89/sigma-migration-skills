#!/usr/bin/env python3
"""Offline regression for Qlik-app-shaped build-sigma-workbook.py behaviours:
Resolver's calculated-dimension wrapper forms, translate_measure's set-analysis
clear-only note + display-formatting-wrapper reduction + rejections,
date_field's tag/format/name fallback chain, and build_element's map region-
grain fallback, untitled-KPI naming, and DM-metric-binding (KPI stays inline,
non-KPI charts bind). Also a light import-level check on build-qlik-
accounting.py's status catalogs.

Harness style follows tests/test_corectl_unbuild.py: module-level test_*
functions, SCRIPTS on sys.path, hyphenated scripts loaded via importlib, same
ok/FAIL runner.

build-sigma-workbook.py already defines MASTER / MASTER_ID at import time
(line ~50) — this test does not set them.

Run: python3 tests/test_qlik_app_shapes.py
"""
import importlib.util
import os
import re
import sys


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
sys.path.insert(0, SCRIPTS)


def load_module(filename, name):
    path = os.path.join(SCRIPTS, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_build_sigma_workbook():
    return load_module("build-sigma-workbook.py", "build_sigma_workbook_test")


def load_qlik_discover():
    return load_module("qlik-discover.py", "qlik_discover_test")


# ---------------------------------------------------------------------------
# 1) Resolver — bare-field calculated-dimension wrapper forms
# ---------------------------------------------------------------------------
def test_resolver_resolves_bare_field_wrapper_forms_and_rejects_functions():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("Category", "CATEGORY"), ("SubCategory", "SUBCATEGORY")])
    assert resolver("Category") == "Category"
    assert resolver("=Category") == "Category"
    assert resolver("=[SubCategory]") == "SubCategory"
    assert resolver("=Upper(Category)") is None


# ---------------------------------------------------------------------------
# 2) translate_measure — clear-only set analysis (note + plain aggregate) vs a
#    real value-set (unchanged Sum(If(...)) shape)
# ---------------------------------------------------------------------------
def test_translate_measure_clear_only_set_records_note_value_set_unchanged():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("NetAmount", "NETAMOUNT"), ("Period", "PERIOD")])

    module.TRANSLATION_NOTES.clear()
    result = module.translate_measure("Sum({<Period=>}NetAmount)", resolver)
    assert result == f"Sum([{module.MASTER}/NetAmount])"
    assert len(module.TRANSLATION_NOTES) == 1
    assert "ignore selections on Period" in module.TRANSLATION_NOTES[0]
    module.TRANSLATION_NOTES.clear()

    result2 = module.translate_measure('Sum({<Period={"2024-01"}>} NetAmount)', resolver)
    assert result2 is not None
    assert result2.startswith("Sum(If(")
    assert f"[{module.MASTER}/NetAmount]" in result2
    module.TRANSLATION_NOTES.clear()


# ---------------------------------------------------------------------------
# 3) translate_measure — display-formatting wrapper reduces to its one
#    aggregate; mixed aggregates and an unknown function stay untranslated
# ---------------------------------------------------------------------------
def test_translate_measure_display_wrapper_and_rejections():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("NetAmount", "NETAMOUNT")])

    module.TRANSLATION_NOTES.clear()
    expr = ("=If(\r\nSum(NetAmount) >= 1000000,\n'$' & Num(Sum(NetAmount)/1000000, '#,##0.0') & 'M',\n"
            "'$' & Num(Sum(NetAmount), '#,##0'))")
    result = module.translate_measure(expr, resolver)
    assert result == f"Sum([{module.MASTER}/NetAmount])"
    module.TRANSLATION_NOTES.clear()

    mixed = "If(Sum(NetAmount)>1,'$'&Num(Sum(Qty)),'x')"
    assert module.translate_measure(mixed, resolver) is None

    unknown_fn = "Sum(NetAmount) & GetCurrentSelections()"
    assert module.translate_measure(unknown_fn, resolver) is None
    module.TRANSLATION_NOTES.clear()


# ---------------------------------------------------------------------------
# 4) date_field — tags win; then qNumFormat; then raw column-name fallback
# ---------------------------------------------------------------------------
def test_date_field_uses_tags_then_format_then_name():
    module = load_build_sigma_workbook()
    date_field = module.date_field
    assert date_field({"tags": ["$numeric", "$integer"]}, "Order_year") is False
    assert date_field({"tags": ["$date", "$numeric"]}, "whatever") is True
    assert date_field({}, "ORDER_DATE") is True
    assert date_field({"tags": ["$ascii", "$text"]}, "whatever") is False


# ---------------------------------------------------------------------------
# 5a) build_element — map with no recognized region grain -> grouped table +
#     loud EXPLICIT APPROXIMATION warning; a recognized grain (State) with a
#     measure still becomes region-map
# ---------------------------------------------------------------------------
def test_build_element_map_falls_back_to_table_without_recognized_grain():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("City", "CITY")])
    warnings = []
    c = {"id": "map-city", "vizType": "map", "title": "City Map",
         "dimensions": [["City"]], "measures": []}
    el = module.build_element(c, resolver, warnings)
    assert el is not None and el["kind"] == "table"
    assert any("EXPLICIT APPROXIMATION" in w for w in warnings)


def test_build_element_map_with_recognized_grain_stays_region_map():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("State", "STATE"), ("NetAmount", "NETAMOUNT")])
    warnings = []
    c = {"id": "map-state", "vizType": "map", "title": "State Map",
         "dimensions": [["State"]], "measures": ["Sum(NetAmount)"]}
    el = module.build_element(c, resolver, warnings)
    assert el is not None and el["kind"] == "region-map"


# ---------------------------------------------------------------------------
# 5b) build_element — an untitled KPI takes its element name from the measure
#     label, not the vizType
# ---------------------------------------------------------------------------
def test_build_element_untitled_kpi_uses_measure_label_as_name():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("NetAmount", "NETAMOUNT")])
    warnings = []
    c = {"id": "kpi-1", "vizType": "kpi", "title": None,
         "dimensions": [], "measures": ["Sum(NetAmount)"],
         "measureLabels": ["Net Revenue"]}
    el = module.build_element(c, resolver, warnings)
    assert el is not None
    assert el["name"] == "Net Revenue"
    assert el["name"] != "kpi"


# ---------------------------------------------------------------------------
# 5c) build_element + metrics — a KPI's value column stays inline (kpi-chart
#     values must never be a bare [Metrics/...] ref); a non-KPI chart (bar)
#     with the SAME measure DOES bind to the governed metric.
# ---------------------------------------------------------------------------
def test_build_element_kpi_stays_inline_bar_chart_binds_metric():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("NetAmount", "NETAMOUNT"), ("City", "CITY")])
    metrics = [{"name": "Net Revenue Metric", "formula": "Sum([NetAmount])"}]

    kpi_c = {"id": "kpi-1", "vizType": "kpi", "title": "Net Revenue",
             "dimensions": [], "measures": ["Sum(NetAmount)"],
             "measureLabels": ["Net Revenue"]}
    kpi_el = module.build_element(kpi_c, resolver, [], metrics=metrics)
    kpi_col = next(col for col in kpi_el["columns"] if col["id"] == kpi_el["value"]["columnId"])
    assert "Sum(" in kpi_col["formula"]
    assert not kpi_col["formula"].startswith("[Metrics/")

    bar_c = {"id": "bar-1", "vizType": "barchart", "title": "Revenue by City",
             "dimensions": [["City"]], "measures": ["Sum(NetAmount)"]}
    bar_el = module.build_element(bar_c, resolver, [], metrics=metrics)
    bar_col = next(col for col in bar_el["columns"] if col["id"] in bar_el["yAxis"]["columnIds"])
    assert bar_col["formula"].startswith("[Metrics/")


# ---------------------------------------------------------------------------
# 6) build-qlik-accounting.py — status catalogs (import-level only)
# ---------------------------------------------------------------------------
def test_build_qlik_accounting_status_catalogs():
    module = load_module("build-qlik-accounting.py", "build_qlik_accounting_test")
    assert {"story", "slide", "action-button"} <= set(module.NO_SIGMA_EQUIVALENT)
    assert {"businessmodel", "colormap"} <= set(module.STRUCTURAL)


def test_python_orchestrator_display_match_mirrors_ruby():
    lib = os.path.join(SCRIPTS, "lib")
    if lib not in sys.path:
        sys.path.insert(0, lib)
    spec = importlib.util.spec_from_file_location("migrate_qlik_py_test", os.path.join(SCRIPTS, "migrate-qlik.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    cases = [("$529.2M", 529247958.49, True), ("$837.0", 837.00313, True), ("$529.3M", 529247958.49, False),
             ("632313", 632313, True), ("$1.2B", 1249000000, True), ("abc", 1, False), (None, 1, False)]
    for shown, number, expected in cases:
        assert module.display_match(shown, number) is expected, (shown, number)


# ---------------------------------------------------------------------------
# 7) grid_layout — reflow chart/KPI columns onto the extent freed by lifted
#    controls (e.g. a Qlik LEFT filter rail), and leave a no-controls sheet's
#    mapping byte-identical to the un-reflowed formula.
# ---------------------------------------------------------------------------
def _cell(col, row, colspan, rowspan=2):
    return {"col": col, "row": row, "colspan": colspan, "rowspan": rowspan}


def test_grid_layout_reflows_onto_extent_freed_by_lifted_controls():
    module = load_build_sigma_workbook()
    # An 84-col sheet: a LEFT filter rail (3 stacked listboxes in cols 0-16)
    # beside 4 KPIs and 2 charts that only ever occupy cols 16-84.
    sheet = {"columns": 84, "rows": 12, "title": "Overview"}
    placed = [
        (_cell(0, 0, 16), {"id": "ctl1", "kind": "control"}),
        (_cell(0, 3, 16), {"id": "ctl2", "kind": "control"}),
        (_cell(0, 6, 16), {"id": "ctl3", "kind": "control"}),
        (_cell(16, 0, 17, 3), {"id": "kpi1", "kind": "kpi-chart"}),
        (_cell(33, 0, 17, 3), {"id": "kpi2", "kind": "kpi-chart"}),
        (_cell(50, 0, 17, 3), {"id": "kpi3", "kind": "kpi-chart"}),
        (_cell(67, 0, 17, 3), {"id": "kpi4", "kind": "kpi-chart"}),
        (_cell(16, 4, 34, 6), {"id": "chart1", "kind": "bar-chart"}),
        (_cell(50, 4, 34, 6), {"id": "chart2", "kind": "bar-chart"}),
    ]
    xml, _extra = module.grid_layout("pg-1", sheet, placed)
    starts = dict(re.findall(r'elementId="(\w+)" gridColumn="(\d+) / \d+"', xml))
    ends = dict(re.findall(r'elementId="(\w+)" gridColumn="\d+ / (\d+)"', xml))
    # the freed columns (0-16) are absorbed: the first KPI/chart now starts
    # at col 1 and the last KPI/chart now reaches col 25 -- not the ~1/6-in,
    # ~5/6-out gap the unmodified [0, qcols] mapping would leave
    assert starts["kpi1"] == "1" and starts["chart1"] == "1"
    assert ends["kpi4"] == "25" and ends["chart2"] == "25"


def test_grid_layout_without_controls_matches_unreflowed_mapping():
    module = load_build_sigma_workbook()
    sheet = {"columns": 24, "rows": 12, "title": "Overview"}
    placed = [
        (_cell(0, 0, 12, 4), {"id": "left", "kind": "bar-chart"}),
        (_cell(12, 0, 12, 4), {"id": "right", "kind": "table"}),
    ]
    xml, _extra = module.grid_layout("pg-1", sheet, placed)
    qcols = sheet["columns"]
    for eid, col, colspan in (("left", 0, 12), ("right", 12, 12)):
        c0 = round(col * 24 / qcols) + 1
        c1 = round((col + colspan) * 24 / qcols) + 1
        assert re.search(rf'elementId="{eid}" gridColumn="{c0} / {c1}"', xml)


# ---------------------------------------------------------------------------
# 8) qlik-discover.py's _listbox_label — an explicit listbox/pane-child title
#    wins over the field's qFieldLabels override, which wins over the field's
#    evaluated fallback title (== the raw field name)
# ---------------------------------------------------------------------------
def test_listbox_label_prefers_title_then_field_label_then_fallback():
    module = load_qlik_discover()
    assert module._listbox_label("Quarter", ["Fiscal Q"], {"label": "Order_quarter"}) == "Quarter"
    assert module._listbox_label(None, ["Fiscal Q"], {"label": "Order_quarter"}) == "Fiscal Q"
    assert module._listbox_label(None, None, {"label": "Order_quarter"}) == "Order_quarter"
    assert module._listbox_label("", [], {"label": "Order_quarter"}) == "Order_quarter"


# ---------------------------------------------------------------------------
# 9) build_element — AUTO NUMBER FORMAT: Qlik qType "U" (its "Auto" format,
#    i.e. no explicit qFmt) falls back to a d3 auto-abbreviate format; a
#    display-formatting wrapper's captured "$" prefix carries through; tables
#    keep full precision; charts without measureFmtTypes (old discovery
#    output / fixtures) are unchanged.
# ---------------------------------------------------------------------------
def test_build_element_auto_number_format_from_qlik_auto_type():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("NetAmount", "NETAMOUNT"), ("City", "CITY")])

    plain_kpi = {"id": "kpi-plain", "vizType": "kpi", "title": "Net Revenue",
                 "dimensions": [], "measures": ["Sum(NetAmount)"],
                 "measureLabels": ["Net Revenue"], "measureFmtTypes": ["U"]}
    el = module.build_element(plain_kpi, resolver, [])
    col = next(c for c in el["columns"] if c["id"] == el["value"]["columnId"])
    assert col.get("format") == {"kind": "number", "formatString": ",.4s"}

    wrapped_kpi = {"id": "kpi-wrapped", "vizType": "kpi", "title": "Net Revenue",
                   "dimensions": [], "measureLabels": ["Net Revenue"],
                   "measures": ["=If(Sum(NetAmount)>=1000000,'$'&Num(Sum(NetAmount)/1000000,"
                                "'#,##0.0')&'M','$'&Num(Sum(NetAmount),'#,##0'))"],
                   "measureFmtTypes": ["U"]}
    el2 = module.build_element(wrapped_kpi, resolver, [])
    col2 = next(c for c in el2["columns"] if c["id"] == el2["value"]["columnId"])
    assert col2.get("format") == {"kind": "number", "formatString": "$,.4s"}

    table_c = {"id": "tbl-1", "vizType": "table", "title": "Orders",
               "dimensions": [["City"]], "measures": ["Sum(NetAmount)"],
               "measureFmtTypes": ["U"]}
    el3 = module.build_element(table_c, resolver, [])
    tbl_col = next(c for c in el3["columns"] if c["formula"].startswith("Sum("))
    assert "format" not in tbl_col

    kpi_no_types = {"id": "kpi-old", "vizType": "kpi", "title": "Net Revenue",
                    "dimensions": [], "measures": ["Sum(NetAmount)"],
                    "measureLabels": ["Net Revenue"]}
    el4 = module.build_element(kpi_no_types, resolver, [])
    col4 = next(c for c in el4["columns"] if c["id"] == el4["value"]["columnId"])
    assert "format" not in col4

    bar_c = {"id": "bar-1", "vizType": "barchart", "title": "Net by City",
             "dimensions": [["City"]], "measures": ["Sum(NetAmount)"],
             "measureLabels": ["Net"], "measureFmtTypes": ["U"]}
    el5 = module.build_element(bar_c, resolver, [])
    bar_col = next(c for c in el5["columns"] if c["formula"].startswith("Sum("))
    assert bar_col.get("format") == {"kind": "number", "formatString": ",.4~s"}


# ---------------------------------------------------------------------------
# 10) build_element — a horizontal Qlik bar chart emits el["orientation"] =
#     "horizontal" (the live spec accepts + persists it); a line chart's own
#     "horizontal" orientation flag (Qlik carries one; Sigma has no line-chart
#     equivalent) is ignored.
# ---------------------------------------------------------------------------
def test_build_element_horizontal_bar_sets_orientation_line_chart_ignored():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("City", "CITY"), ("NetAmount", "NETAMOUNT")])

    bar = {"id": "bar-1", "vizType": "barchart", "title": "Revenue by City",
           "dimensions": [["City"]], "measures": ["Sum(NetAmount)"],
           "presentation": {"orientation": "horizontal"}}
    bar_el = module.build_element(bar, resolver, [])
    assert bar_el["orientation"] == "horizontal"

    line = {"id": "line-1", "vizType": "linechart", "title": "Revenue by City",
            "dimensions": [["City"]], "measures": ["Sum(NetAmount)"],
            "presentation": {"orientation": "horizontal"}}
    line_el = module.build_element(line, resolver, [])
    assert "orientation" not in line_el


# ---------------------------------------------------------------------------
# 11) qlik-discover.py's _choose_map_layer — a dimensioned AreaLayer (e.g.
#     State) wins over a PointLayer (City) that precedes it; when the chosen
#     AreaLayer has no measure shelf but is colored byMeasure, its
#     byMeasureDef {key, label} becomes one synthetic measure. build_element
#     then warns about the PointLayer mapLayers records but did NOT choose.
# ---------------------------------------------------------------------------
def test_choose_map_layer_prefers_dimensioned_area_layer_with_bymeasure_color():
    module = load_qlik_discover()
    ga_layers = [
        {"type": "PointLayer",
         "qHyperCubeDef": {"qDimensions": [{"qDef": {"qFieldDefs": ["CITY"]}}], "qMeasures": []}},
        {"type": "AreaLayer",
         "qHyperCubeDef": {"qDimensions": [{"qDef": {"qFieldDefs": ["STATE"]}}], "qMeasures": []},
         "color": {"mode": "byMeasure",
                   "byMeasureDef": {"key": "m1", "label": "Revenue", "type": "libraryItem"}}},
    ]
    qdims, qmeas = module._choose_map_layer(ga_layers)
    assert qdims == [{"qDef": {"qFieldDefs": ["STATE"]}}]
    assert [(mm.get("qDef", {}).get("qDef") or mm.get("qLibraryId")) for mm in qmeas] == ["m1"]
    assert [mm.get("qDef", {}).get("qLabel") for mm in qmeas] == ["Revenue"]


def test_build_element_map_warns_on_dropped_point_layer():
    module = load_build_sigma_workbook()
    resolver = module.Resolver([("State", "STATE"), ("NetAmount", "NETAMOUNT")])
    warnings = []
    c = {"id": "map-1", "vizType": "map", "title": "Orders by State",
         "dimensions": [["State"]], "measures": ["Sum(NetAmount)"],
         "mapLayers": [
             {"type": "PointLayer", "dims": [["City"]]},
             {"type": "AreaLayer", "dims": [["State"]]},
         ]}
    el = module.build_element(c, resolver, warnings)
    assert el is not None and el["kind"] == "region-map"
    assert any("dropped" in w for w in warnings)


if __name__ == "__main__":
    failures = 0
    for name, function in sorted((name, value) for name, value in globals().items() if name.startswith("test_")):
        try:
            function()
            print("ok ", name)
        except AssertionError as error:
            failures += 1
            print("FAIL", name, error)
    sys.exit(1 if failures else 0)
