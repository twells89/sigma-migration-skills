#!/usr/bin/env python3
"""Unit tests for converter/hex_yaml.py — the .hex.yaml parser.

Offline, stdlib + PyYAML only. Covers the shape validation (loud failure on a
non-Hex-export YAML file), the SQL/METRIC/EXPLORE cell parsers, the
unsupported-cellType warn-and-skip path (never silently dropped), and the
appLayout -> tabs/rows/columns walk.

Run: python3 tests/test_hex_yaml.py   (exit 0 = pass)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
CONVERTER = os.path.join(SKILL, "converter")
sys.path.insert(0, CONVERTER)

import hex_yaml  # noqa: E402


def _write_yaml(text):
    f = tempfile.NamedTemporaryFile(mode="w", suffix=".hex.yaml", delete=False, encoding="utf-8")
    f.write(text)
    f.close()
    return f.name


def test_load_project_valid():
    path = _write_yaml("meta:\n  title: Demo\ncells: []\n")
    doc = hex_yaml.load_project(path)
    assert doc["meta"]["title"] == "Demo"
    assert doc["cells"] == []


def test_load_project_rejects_non_mapping():
    path = _write_yaml("- 1\n- 2\n")
    try:
        hex_yaml.load_project(path)
        assert False, "expected HexParseError for a non-mapping top level"
    except hex_yaml.HexParseError:
        pass


def test_load_project_requires_meta_and_cells():
    path = _write_yaml("meta:\n  title: Demo\n")
    try:
        hex_yaml.load_project(path)
        assert False, "expected HexParseError for missing 'cells'"
    except hex_yaml.HexParseError as e:
        assert "cells" in str(e)


def test_load_project_requires_cells_list():
    path = _write_yaml("meta: {}\ncells:\n  foo: bar\n")
    try:
        hex_yaml.load_project(path)
        assert False, "expected HexParseError for non-list 'cells'"
    except hex_yaml.HexParseError as e:
        assert "list" in str(e)


def test_project_title_default_and_explicit():
    assert hex_yaml.project_title({}) == "Untitled Hex Project"
    assert hex_yaml.project_title({"meta": {}}) == "Untitled Hex Project"
    assert hex_yaml.project_title({"meta": {"title": "Commerce Dashboard"}}) == "Commerce Dashboard"


def test_data_connection_ids_skips_entries_without_id():
    doc = {"sharedAssets": {"dataConnections": [
        {"dataConnectionId": "conn-1"},
        {"name": "no id here"},
        {"dataConnectionId": "conn-2"},
    ]}}
    assert hex_yaml.data_connection_ids(doc) == ["conn-1", "conn-2"]
    assert hex_yaml.data_connection_ids({}) == []


def test_parse_sql_cell_defaults_and_column_cleaning():
    cell = {
        "cellId": "c1",
        "cellLabel": "Orders",
        "config": {
            "source": "SELECT 1",
            "dataConnectionId": "conn-1",
            "dataFrameCell": True,
            "tableDisplayConfig": {"columnProperties": [
                {"originalName": "Order ID"},
                {"originalName": "row-index-0"},
                {"originalName": None},
            ]},
        },
    }
    parsed = hex_yaml.parse_sql_cell(cell)
    assert parsed["cell_id"] == "c1"
    assert parsed["result_variable"] == "query_result"  # not configured -> default
    assert parsed["data_connection_id"] == "conn-1"
    assert parsed["is_dataframe_cell"] is True
    assert parsed["columns"] == ["Order ID"]  # synthetic row-index + blank dropped


def test_parse_metric_cell_title_fallback_chain():
    # explicit title wins
    c1 = {"cellId": "c1", "cellLabel": "Label1", "config": {"title": "Total Revenue"}}
    assert hex_yaml.parse_metric_cell(c1)["title"] == "Total Revenue"
    # no title -> cellLabel
    c2 = {"cellId": "c2", "cellLabel": "Label2", "config": {}}
    assert hex_yaml.parse_metric_cell(c2)["title"] == "Label2"
    # neither -> "Metric"
    c3 = {"cellId": "c3", "config": {}}
    assert hex_yaml.parse_metric_cell(c3)["title"] == "Metric"


def test_parse_explore_cell_extracts_chart_config():
    cell = {
        "cellId": "c1", "cellLabel": "Chart",
        "config": {"dataframe": "df1", "spec": {
            "fields": [{"channel": "base-axis", "value": "Region"}],
            "viewType": "CHART", "visualizationType": "explore",
            "chartConfig": {"series": [{"type": "bar"}], "orientation": "horizontal"},
        }},
    }
    parsed = hex_yaml.parse_explore_cell(cell)
    assert parsed["dataframe"] == "df1"
    assert parsed["fields"] == [{"channel": "base-axis", "value": "Region"}]
    assert parsed["series"] == [{"type": "bar"}]
    assert parsed["orientation"] == "horizontal"
    # missing config/spec/chartConfig sub-keys degrade to [] / None, never KeyError
    empty = hex_yaml.parse_explore_cell({"cellId": "c2"})
    assert empty["fields"] == [] and empty["series"] == [] and empty["series_groups"] == []


def test_parse_cells_dispatches_and_warns_on_unsupported():
    doc = {"cells": [
        {"cellId": "c1", "cellType": "SQL", "cellLabel": "Q", "config": {"source": "SELECT 1"}},
        {"cellId": "c2", "cellType": "METRIC", "cellLabel": "M", "config": {}},
        {"cellId": "c3", "cellType": "EXPLORE", "cellLabel": "E", "config": {}},
        {"cellId": "c4", "cellType": "CODE", "cellLabel": "Python cell"},
    ]}
    parsed, warnings = hex_yaml.parse_cells(doc)
    kinds = {p["cell_id"]: p["kind"] for p in parsed}
    assert kinds == {"c1": "sql", "c2": "metric", "c3": "explore"}
    assert len(warnings) == 1
    assert "Python cell" in warnings[0] and "cellType='CODE'" in warnings[0]
    assert "Python (CODE) cells" in warnings[0]


def test_parse_app_layout_walks_tabs_rows_columns():
    doc = {"appLayout": {"tabs": [
        {"name": "Overview", "rows": [
            {"columns": [
                {"start": 0, "end": 60, "elements": [
                    {"type": "CELL", "cellId": "c1"},
                    {"type": "TEXT", "cellId": "c2"},  # not a CELL -> excluded
                    {"type": "CELL"},                   # CELL with no cellId -> excluded
                ]},
                {"elements": [{"type": "CELL", "cellId": "c3"}]},  # no start/end -> defaults
            ]},
        ]},
        {"rows": []},  # no name -> defaults to "Page 1"
    ]}}
    tabs = hex_yaml.parse_app_layout(doc)
    assert len(tabs) == 2
    assert tabs[0]["name"] == "Overview"
    col0, col1 = tabs[0]["rows"][0]["columns"]
    assert col0["start"] == 0 and col0["end"] == 60 and col0["cell_ids"] == ["c1"]
    assert col1["start"] == 0 and col1["end"] == 120 and col1["cell_ids"] == ["c3"]
    assert tabs[1]["name"] == "Page 1"
    assert hex_yaml.parse_app_layout({}) == []


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
