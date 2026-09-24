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
