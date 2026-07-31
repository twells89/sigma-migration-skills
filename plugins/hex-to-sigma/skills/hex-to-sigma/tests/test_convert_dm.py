#!/usr/bin/env python3
"""Unit tests for converter/convert_dm.py — Hex SQL cells -> Sigma data model.

Offline, stdlib + PyYAML only. Covers the SELECT-clause cross-check guard
(live-verified 2026-07-30: a stale cached column not in the SELECT list 400s
at POST — "dependency not found"), the native-SQL element shape, and the
trailing-semicolon fixup. See corpus/hex/commerce/ for the full-fixture
end-to-end regression (run via corpus/run-corpus.sh --check hex).

Run: python3 tests/test_convert_dm.py   (exit 0 = pass)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
CONVERTER = os.path.join(SKILL, "converter")
sys.path.insert(0, CONVERTER)

import convert_dm  # noqa: E402
import sigma_ids  # noqa: E402


def _sql_cell(cell_id="c1", label="Query", statement='SELECT "A", "B" FROM t',
              columns=("A", "B"), result_variable="query_result", data_connection_id="conn-1"):
    return {
        "cellId": cell_id, "cellType": "SQL", "cellLabel": label,
        "config": {
            "source": statement,
            "resultVariableName": result_variable,
            "dataConnectionId": data_connection_id,
            "tableDisplayConfig": {"columnProperties": [{"originalName": c} for c in columns]},
        },
    }


def _doc(*cells):
    return {"meta": {"title": "Demo"}, "cells": list(cells)}


def test_select_clause_output_names_extracts_before_from():
    names = convert_dm._select_clause_output_names('SELECT "A", "B" FROM t JOIN "C" ON "C"."id" = t.id')
    assert names == {"A", "B"}, names


def test_select_clause_output_names_none_without_from():
    assert convert_dm._select_clause_output_names("SELECT 1") is None


def test_build_dm_basic_sql_cell():
    sigma_ids.reset_ids()
    doc = _doc(_sql_cell())
    result = convert_dm.build_dm(doc, "conn-uuid", "Demo DM")
    dm = result["dataModel"]
    assert dm["name"] == "Demo DM"
    page = dm["pages"][0]
    assert len(page["elements"]) == 1
    element = page["elements"][0]
    assert element["kind"] == "table"
    assert element["source"] == {"kind": "sql", "connectionId": "conn-uuid", "statement": 'SELECT "A", "B" FROM t'}
    names = [c["name"] for c in element["columns"]]
    assert names == ["A", "B"]
    formulas = [c["formula"] for c in element["columns"]]
    assert formulas == ["[Custom SQL/A]", "[Custom SQL/B]"]
    assert element["order"] == [c["id"] for c in element["columns"]]
    assert result["stats"] == {"sql_cells": 1, "elements": 1, "columns": 2}
    assert set(result["columns_by_variable"]["query_result"]) == {"A", "B"}
    assert result["warnings"] == []


def test_build_dm_drops_stale_columns_with_warning():
    sigma_ids.reset_ids()
    # "Brand ID" is cached in columnProperties but only appears in a JOIN...ON
    # clause, never in the SELECT list (the live-verified corpus/hex/commerce bug).
    doc = _doc(_sql_cell(
        statement='SELECT "A" FROM t JOIN brands b ON b."Brand ID" = t.brand_id',
        columns=("A", "Brand ID"),
    ))
    result = convert_dm.build_dm(doc, "conn-uuid", "Demo DM")
    element = result["dataModel"]["pages"][0]["elements"][0]
    names = [c["name"] for c in element["columns"]]
    assert names == ["A"], names
    assert result["stats"]["columns"] == 1
    assert any("Brand ID" in w and "stale" in w for w in result["warnings"]), result["warnings"]


def test_build_dm_skips_empty_source_cell():
    sigma_ids.reset_ids()
    doc = _doc(_sql_cell(statement="   "))
    result = convert_dm.build_dm(doc, "conn-uuid", "Demo DM")
    assert result["dataModel"]["pages"][0]["elements"] == []
    assert result["stats"] == {"sql_cells": 1, "elements": 0, "columns": 0}
    assert any("empty source" in w for w in result["warnings"])


def test_build_dm_strips_trailing_semicolon():
    sigma_ids.reset_ids()
    doc = _doc(_sql_cell(statement='SELECT "A" FROM t;  '))
    result = convert_dm.build_dm(doc, "conn-uuid", "Demo DM")
    element = result["dataModel"]["pages"][0]["elements"][0]
    assert element["source"]["statement"] == 'SELECT "A" FROM t'


def test_build_dm_folder_id_optional():
    sigma_ids.reset_ids()
    doc = _doc(_sql_cell())
    with_folder = convert_dm.build_dm(doc, "conn-uuid", "Demo DM", folder_id="fld-1")
    assert with_folder["dataModel"]["folderId"] == "fld-1"
    without_folder = convert_dm.build_dm(doc, "conn-uuid", "Demo DM")
    assert "folderId" not in without_folder["dataModel"]


def test_build_dm_ignores_non_sql_cells():
    sigma_ids.reset_ids()
    doc = _doc(
        _sql_cell(),
        {"cellId": "c2", "cellType": "METRIC", "cellLabel": "M", "config": {}},
    )
    result = convert_dm.build_dm(doc, "conn-uuid", "Demo DM")
    assert result["stats"]["sql_cells"] == 1  # the METRIC cell never reaches build_dm's sql_cells count


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
