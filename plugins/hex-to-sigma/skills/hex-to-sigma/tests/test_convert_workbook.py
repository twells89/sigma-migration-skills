#!/usr/bin/env python3
"""Unit tests for converter/convert_workbook.py — Hex METRIC/EXPLORE cells +
appLayout -> Sigma workbook spec.

Offline, stdlib + PyYAML only. Covers KPI + cartesian/pie chart element
shapes, the axis-sort mapping (live-verified 2026-07-30 — without it Sigma
defaults to an alphabetical dimension sort), the top-n filter emission, the
loud warn-and-skip paths (missing fields, unmapped series types,
combo/multi-series), and the Hex 0-120 -> Sigma 24-col layout grid scaling.
See corpus/hex/commerce/ for the full-fixture end-to-end regression.

Run: python3 tests/test_convert_workbook.py   (exit 0 = pass)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
CONVERTER = os.path.join(SKILL, "converter")
sys.path.insert(0, CONVERTER)

import convert_workbook  # noqa: E402
import sigma_ids  # noqa: E402

DM_ID, DM_ELEMENT_ID = "dm-1", "el-native-sql"
COLUMNS_BY_VARIABLE = {"query_result": {"Country": "col-country", "Revenue": "col-revenue",
                                         "Category": "col-category"}}
CORPUS_GOLDEN = os.path.normpath(os.path.join(
    SKILL, "../../../../corpus/hex/commerce/golden/workbook.json"
))


# --- build_metric_element ----------------------------------------------------

def test_build_metric_element_basic():
    sigma_ids.reset_ids()
    cell = {"cell_id": "c1", "label": "Total Revenue", "title": "Total Revenue",
            "value_variable_name": "query_result", "value_column": "Revenue",
            "value_aggregate": "Sum", "display_format": {"format": "CURRENCY"}}
    warnings = []
    el = convert_workbook.build_metric_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el["kind"] == "kpi-chart"
    assert el["name"] == "Total Revenue"
    assert el["source"] == {"kind": "data-model", "dataModelId": DM_ID, "elementId": DM_ELEMENT_ID}
    assert len(el["columns"]) == 1
    assert el["columns"][0]["formula"] == "Sum([Custom SQL/Revenue])"
    assert el["value"] == {"columnId": el["columns"][0]["id"]}
    assert el["columns"][0]["format"]["kind"] == "number"
    assert warnings == []


def test_build_metric_element_missing_value_column_warns():
    warnings = []
    cell = {"cell_id": "c1", "label": "M", "title": "M", "value_variable_name": None,
            "value_column": None, "value_aggregate": None, "display_format": None}
    el = convert_workbook.build_metric_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el is None
    assert any("no value column configured" in w for w in warnings)


def test_build_metric_element_unknown_column_warns():
    warnings = []
    cell = {"cell_id": "c1", "label": "M", "title": "M", "value_variable_name": "query_result",
            "value_column": "Nope", "value_aggregate": "Sum", "display_format": None}
    el = convert_workbook.build_metric_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el is None
    assert any("'Nope'" in w and "not found" in w for w in warnings)


# --- _axis_sort / _top_n_filter ----------------------------------------------

def test_axis_sort_mappings():
    assert convert_workbook._axis_sort({"sort": {"mode": "cross-axis-descending"}}, "ax", "meas") == \
        {"by": "meas", "direction": "descending"}
    assert convert_workbook._axis_sort({"sort": {"mode": "cross-axis-ascending"}}, "ax", "meas") == \
        {"by": "meas", "direction": "ascending"}
    assert convert_workbook._axis_sort({"sort": {"mode": "value-descending"}}, "ax", "meas") == \
        {"by": "ax", "direction": "descending"}
    assert convert_workbook._axis_sort({}, "ax", "meas") is None
    assert convert_workbook._axis_sort({"sort": {"mode": "unrecognized"}}, "ax", "meas") is None


def test_top_n_filter_plain_pattern_no_warning():
    warnings = []
    field = {"lump": {"predicate": {"op": "LTE", "arg": 10}, "orderDirection": "desc"}}
    filt = convert_workbook._top_n_filter(field, "meas-col", warnings, "Chart")
    assert filt["kind"] == "top-n" and filt["columnId"] == "meas-col" and filt["rowCount"] == 10
    assert warnings == []


def test_top_n_filter_unusual_pattern_warns_but_still_emits():
    warnings = []
    field = {"lump": {"predicate": {"op": "GTE", "arg": 5}, "orderDirection": "asc"}}
    filt = convert_workbook._top_n_filter(field, "meas-col", warnings, "Chart")
    assert filt is not None
    assert any("isn't a plain top-N-descending pattern" in w for w in warnings)


def test_top_n_filter_absent_lump_returns_none():
    assert convert_workbook._top_n_filter({}, "meas-col", [], "Chart") is None


# --- build_explore_element ---------------------------------------------------

def _bar_cell(orientation=None, sort_mode=None):
    x_field = {"channel": "base-axis", "value": "Country"}
    if sort_mode:
        x_field["sort"] = {"mode": sort_mode}
    return {
        "cell_id": "c1", "label": "Revenue by Country", "dataframe": "query_result",
        "series": [{"type": "bar"}], "orientation": orientation,
        "fields": [x_field, {"channel": "cross-axis", "value": "Revenue", "aggregation": "Sum"}],
    }


def test_build_explore_element_bar_chart_basic():
    sigma_ids.reset_ids()
    warnings = []
    el = convert_workbook.build_explore_element(_bar_cell(), DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el["kind"] == "bar-chart"
    assert "columnId" in el["xAxis"]
    assert el["yAxis"]["columnIds"], el
    assert "orientation" not in el
    assert warnings == []


def test_build_explore_element_horizontal_orientation():
    sigma_ids.reset_ids()
    el = convert_workbook.build_explore_element(_bar_cell(orientation="horizontal"), DM_ID, DM_ELEMENT_ID,
                                                 COLUMNS_BY_VARIABLE, [])
    assert el["orientation"] == "horizontal"


def test_build_explore_element_axis_sort_applied():
    sigma_ids.reset_ids()
    el = convert_workbook.build_explore_element(_bar_cell(sort_mode="cross-axis-descending"), DM_ID,
                                                 DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, [])
    assert el["xAxis"]["sort"] == {"by": el["yAxis"]["columnIds"][0], "direction": "descending"}


def test_build_explore_element_pie_chart():
    sigma_ids.reset_ids()
    cell = {"cell_id": "c1", "label": "Revenue by Category", "dataframe": "query_result",
            "series": [{"type": "pie"}], "orientation": None,
            "fields": [{"channel": "color", "value": "Category"},
                       {"channel": "cross-axis", "value": "Revenue", "aggregation": "Sum"}]}
    el = convert_workbook.build_explore_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, [])
    assert el["kind"] == "pie-chart"
    assert "columnId" in el["color"] and "columnId" in el["value"]
    assert "xAxis" not in el and "yAxis" not in el


def test_build_explore_element_multi_series_warns():
    warnings = []
    cell = {"cell_id": "c1", "label": "Combo", "dataframe": "query_result",
            "series": [{"type": "bar"}, {"type": "line"}], "orientation": None, "fields": []}
    el = convert_workbook.build_explore_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el is None
    assert any("combo/multi-series" in w for w in warnings)


def test_build_explore_element_unknown_series_type_warns():
    warnings = []
    cell = {"cell_id": "c1", "label": "Histo", "dataframe": "query_result",
            "series": [{"type": "histogram"}], "orientation": None, "fields": []}
    el = convert_workbook.build_explore_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el is None
    assert any("documented gap" in w and "histogram" in w for w in warnings)


def test_build_explore_element_unknown_catalog_type_warns():
    warnings = []
    cell = {"cell_id": "c1", "label": "Mystery", "dataframe": "query_result",
            "series": [{"type": "future-chart"}], "orientation": None, "fields": []}
    el = convert_workbook.build_explore_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el is None
    assert any("absent from the grounded viz catalog" in w for w in warnings)


def test_build_explore_element_box_is_plugin_gated():
    warnings = []
    cell = {"cell_id": "c1", "label": "Distribution", "dataframe": "query_result",
            "series": [{"type": "boxplot"}], "orientation": None, "fields": []}
    el = convert_workbook.build_explore_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el is None
    assert any("gated" in w and "plugin" in w for w in warnings)


def test_build_explore_element_missing_axis_fields_warns():
    warnings = []
    cell = {"cell_id": "c1", "label": "Bare", "dataframe": "query_result",
            "series": [{"type": "bar"}], "orientation": None, "fields": []}
    el = convert_workbook.build_explore_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings)
    assert el is None
    assert any("missing a base-axis or cross-axis field" in w for w in warnings)


def test_build_explore_element_top_n_filter_from_lump():
    sigma_ids.reset_ids()
    cell = _bar_cell()
    cell["fields"][0]["lump"] = {"predicate": {"op": "LTE", "arg": 10}, "orderDirection": "desc"}
    el = convert_workbook.build_explore_element(cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, [])
    assert el["filters"][0]["kind"] == "top-n" and el["filters"][0]["rowCount"] == 10


def test_build_explore_element_legend_and_static_color():
    sigma_ids.reset_ids()
    cell = _bar_cell()
    cell["series"] = [{"type": "bar", "color": {"staticValue": "#4C78A8"}}]
    cell["settings"] = {"legend": {"position": "right"}}
    el = convert_workbook.build_explore_element(
        cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, []
    )
    assert el["kind"] == "bar-chart"
    assert el["legend"] == {"position": "right"}
    assert el["color"] == {"by": "single", "value": "#4C78A8"}


def test_build_explore_element_waterfall_is_loud_not_in_source_gap():
    cell = _bar_cell()
    cell["series"] = [{"type": "waterfall"}]
    warnings = []
    el = convert_workbook.build_explore_element(
        cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, warnings
    )
    assert el is None
    assert any("documented gap" in warning and "public export schema" in warning
               for warning in warnings)


def test_build_explore_element_hidden_legend():
    cell = _bar_cell()
    cell["settings"] = {"legend": {"position": "none"}}
    el = convert_workbook.build_explore_element(
        cell, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, []
    )
    assert el["legend"] == {"visibility": "hidden"}


# --- build_layout_xml ---------------------------------------------------------

def test_build_layout_xml_scales_hex_grid_to_sigma_grid():
    tab = {"rows": [{"columns": [{"start": 0, "end": 120, "cell_ids": ["c1"]}]}]}
    xml = convert_workbook.build_layout_xml("page-1", tab, {"c1": "el-1"})
    assert '<Page type="grid"' in xml and 'id="page-1"' in xml
    assert '<Element elementId="el-1"' in xml
    assert "<LayoutElement" not in xml
    assert 'gridColumn="1 / 25"' in xml  # 0-120 Hex scale -> 1-25 Sigma grid lines (24 cols)


def test_build_layout_xml_skips_unmapped_cells():
    tab = {"rows": [{"columns": [{"start": 0, "end": 60, "cell_ids": ["missing"]}]}]}
    xml = convert_workbook.build_layout_xml("page-1", tab, {})
    assert "<Element" not in xml


def test_build_layout_xml_uses_hex_cell_height():
    tab = {"rows": [{"columns": [{
        "start": 0, "end": 120, "cell_ids": ["c1"],
        "cells": [{"cell_id": "c1", "height": 400}],
    }]}]}
    xml = convert_workbook.build_layout_xml("page-1", tab, {"c1": "el-1"})
    assert 'gridRow="1 / 11"' in xml


# --- build_workbook (integration) --------------------------------------------

def test_build_workbook_integration():
    sigma_ids.reset_ids()
    doc = {
        "cells": [
            {"cellId": "m1", "cellType": "METRIC", "cellLabel": "Total Revenue",
             "config": {"title": "Total Revenue", "valueVariableName": "query_result",
                        "valueColumn": "Revenue", "valueAggregate": "Sum"}},
            {"cellId": "e1", "cellType": "EXPLORE", "cellLabel": "Revenue by Country",
             "config": {"dataframe": "query_result", "spec": {
                 "fields": [{"channel": "base-axis", "value": "Country"},
                            {"channel": "cross-axis", "value": "Revenue", "aggregation": "Sum"}],
                 "chartConfig": {"series": [{"type": "bar"}]}}}},
        ],
        "appLayout": {"tabs": [{"name": "Overview", "rows": [
            {"columns": [{"start": 0, "end": 60, "elements": [{"type": "CELL", "cellId": "m1"}]}]},
            {"columns": [{"start": 0, "end": 120, "elements": [{"type": "CELL", "cellId": "e1"}]}]},
        ]}]},
    }
    result = convert_workbook.build_workbook(doc, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, "Demo WB")
    wb = result["workbook"]
    assert wb["name"] == "Demo WB"
    assert "schemaVersion" not in wb and "pages" not in wb
    workbook_doc = wb["document"]
    page = workbook_doc["pages"][0]
    assert page["name"] == "Overview"
    assert "elements" not in page  # workbook pages are metadata-only
    assert len(workbook_doc["elements"]) == 2
    assert {e["kind"] for e in workbook_doc["elements"]} == {"kpi-chart", "bar-chart"}
    assert all("_hex_cell_id" not in e for e in workbook_doc["elements"])
    assert workbook_doc["layout"].count("<Element") == 2
    assert "<LayoutElement" not in workbook_doc["layout"]
    assert "layout" not in page
    assert result["stats"] == {"metric_cells": 1, "explore_cells": 1, "elements": 2}
    assert result["warnings"] == []


def test_build_workbook_all_tabs_and_unplaced_elements_have_authoritative_layout():
    sigma_ids.reset_ids()
    doc = {
        "cells": [
            {"cellId": "m1", "cellType": "METRIC", "cellLabel": "One",
             "config": {"valueVariableName": "query_result", "valueColumn": "Revenue"}},
            {"cellId": "m2", "cellType": "METRIC", "cellLabel": "Two",
             "config": {"valueVariableName": "query_result", "valueColumn": "Revenue"}},
            {"cellId": "m3", "cellType": "METRIC", "cellLabel": "Unplaced",
             "config": {"valueVariableName": "query_result", "valueColumn": "Revenue"}},
        ],
        "appLayout": {
            "fullWidth": True,
            "tabs": [
                {"name": "Overview", "rows": [{"columns": [{
                    "start": 0, "end": 120,
                    "elements": [{"type": "CELL", "cellId": "m1"}],
                }]}]},
                {"name": "Details", "rows": [{"columns": [{
                    "start": 0, "end": 120,
                    "elements": [{"type": "CELL", "cellId": "m2", "explorable": True}],
                }]}]},
            ],
        },
    }
    result = convert_workbook.build_workbook(
        doc, DM_ID, DM_ELEMENT_ID, COLUMNS_BY_VARIABLE, "Tabs", "folder-1"
    )
    wb = result["workbook"]
    workbook_doc = wb["document"]
    assert wb["folderId"] == "folder-1"
    assert [page["name"] for page in workbook_doc["pages"]] == ["Overview", "Details"]
    assert all("elements" not in page for page in workbook_doc["pages"])
    assert len(workbook_doc["elements"]) == 3
    assert workbook_doc["layout"].count("<Page ") == 2
    assert workbook_doc["layout"].count("<Element") == 3
    assert "<LayoutElement" not in workbook_doc["layout"]
    assert workbook_doc["settings"]["navigation"]["pageTabsInViewMode"] == "shown"
    assert workbook_doc["settings"]["theme"]["overrides"]["pageWidth"] == "full"
    assert any("explorable/drill" in warning for warning in result["warnings"])
    assert any("absent from appLayout" in warning for warning in result["warnings"])


def test_commerce_golden_is_current_shape_with_total_layout_membership():
    with open(CORPUS_GOLDEN, encoding="utf-8") as fh:
        golden = json.load(fh)
    workbook = golden["workbook"]
    workbook_doc = convert_workbook.code_rep.document(workbook)
    assert workbook["name"] == "Commerce Dashboard"
    assert "document" in workbook
    assert all("elements" not in page for page in workbook_doc["pages"])
    assert len(workbook_doc["elements"]) == 6
    assert workbook_doc["layout"].count("<Element") == 6
    assert "<LayoutElement" not in workbook_doc["layout"]
    pairs = convert_workbook.code_rep.workbook_elements_with_pages(workbook)
    assert len(pairs) == 6
    assert all(page is not None for _, page in pairs)
    assert {element["id"] for element, _ in pairs} == {
        element["id"] for element in workbook_doc["elements"]
    }


if __name__ == "__main__":
    fails = 0
    for name, fn in sorted((n, f) for n, f in globals().items() if n.startswith("test_")):
        try:
            fn()
            print(f"ok  {name}")
        except AssertionError as e:
            fails += 1
            print(f"FAIL {name}: {e}")
    sys.exit(1 if fails else 0)
