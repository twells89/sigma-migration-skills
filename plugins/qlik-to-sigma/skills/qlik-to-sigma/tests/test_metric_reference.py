#!/usr/bin/env python3
"""DM-metric references in the qlik workbook builder (leverage the semantic layer
instead of duplicating aggregations). Offline, creds-free.

build-sigma-workbook.py prefers a governed `[Metrics/<name>]` reference over
re-deriving a measure's aggregation inline, when the measure's translated inline
aggregate matches a metric on the denorm element the master sources. Match is by
FORMULA equivalence (strip the master prefix so `Sum([Master/Net Revenue])` equals
a metric's `Sum([Net Revenue])`) — via the shared binder (shared/lib/metric_binding.py).
SAFE: no `--dm-spec`, no match, or a metric in a different formula representation
(e.g. Qlik-form `Count(DISTINCT ...)` vs the inline's `CountDistinct(...)`) all fall
back to inline. Without `--dm-spec` the output is byte-identical to before.

Run: python3 tests/test_metric_reference.py   (exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
BUILDER = os.path.join(SKILL, "scripts", "build-sigma-workbook.py")

DENORM = {"element": {"id": "el-x", "columns": [
    {"name": "Region",      "formula": "[Custom SQL/REGION]"},
    {"name": "Net Revenue", "formula": "[Custom SQL/NET_REVENUE]"},
    {"name": "Order Id",    "formula": "[Custom SQL/ORDER_ID]"},
]}}

_SORT = {"interColumnSortOrder": [], "dimensions": [[]], "measures": [{}]}

# a table with two measures: a plain Sum (will match a metric) and a
# Count(DISTINCT) (translates to CountDistinct — the DM metric is Qlik-form, so it
# must NOT match and must stay inline).
CHARTS = [{
    "id": "tbl", "vizType": "table", "title": "Rev by Region", "sheet": None,
    "dimensions": [["REGION"]], "dimLabels": [None], "dimNullSuppression": [False],
    "measures": ["Sum(NET_REVENUE)", "Count(DISTINCT ORDER_ID)"],
    "measureLabels": ["Total Net Revenue", "Distinct Orders"],
    "measureFmts": [None, None], "sort": _SORT,
}]

# metrics as build-sigma-dm.py would host them on the denorm element
METRICS = [
    {"name": "Net Revenue", "formula": "Sum([Net Revenue])"},          # matches Sum(NET_REVENUE)
    {"name": "Order Count", "formula": "Count(DISTINCT [Order Id])"},  # Qlik-form → no match
    {"name": "Unrelated",   "formula": "Sum([Nonexistent Col])"},      # matches nothing
]


def build(with_metrics):
    with tempfile.TemporaryDirectory() as d:
        cp = os.path.join(d, "charts.json"); json.dump(CHARTS, open(cp, "w"))
        dp = os.path.join(d, "denorm.json"); json.dump(DENORM, open(dp, "w"))
        sp = os.path.join(d, "wb.json")
        cmd = [sys.executable, BUILDER, "--charts", cp, "--denorm", dp,
               "--dm-id", "dm-x", "--denorm-element-id", "el-x", "--name", "QT",
               "--dry-run", "--spec-out", sp, "--out", os.path.join(d, "r.json"),
               "--layout-out", os.path.join(d, "l.xml"),
               "--element-map", os.path.join(d, "em.json")]
        if with_metrics:
            dm = {"name": "t", "schemaVersion": 1, "pages": [{"id": "pg", "name": "P",
                  "elements": [{"id": "el-x", "name": "Custom SQL", "metrics": METRICS}]}]}
            dmp = os.path.join(d, "dm-spec.json"); json.dump(dm, open(dmp, "w"))
            cmd += ["--dm-spec", dmp]
        r = subprocess.run(cmd, capture_output=True, text=True)
        assert r.returncode == 0, f"builder failed:\n{r.stderr}"
        spec = json.load(open(sp))
        # every measure/dim column formula keyed by column name, across data pages
        cols = {}
        for pg in spec["pages"]:
            for el in pg["elements"]:
                for c in el.get("columns", []):
                    cols[c.get("name")] = c["formula"]
        return cols


def test_fallback_without_dm_spec():
    cols = build(with_metrics=False)
    assert cols["Total Net Revenue"].startswith("Sum("), cols["Total Net Revenue"]
    assert not any(str(v).startswith("[Metrics/") for v in cols.values()), cols
    print("[ok] no --dm-spec → inline (byte-identical fallback)")


def test_matched_measure_binds_to_metric():
    cols = build(with_metrics=True)
    assert cols["Total Net Revenue"] == "[Metrics/Net Revenue]", cols["Total Net Revenue"]
    print("[ok] matched aggregate → [Metrics/Net Revenue] (governed, no re-derive)")


def test_countdistinct_form_mismatch_falls_back():
    cols = build(with_metrics=True)
    # metric is Qlik-form Count(DISTINCT ...); inline is CountDistinct(...) → no match
    assert cols["Distinct Orders"].startswith("CountDistinct("), cols["Distinct Orders"]
    assert "[Metrics/" not in cols["Distinct Orders"], cols["Distinct Orders"]
    print("[ok] Count(DISTINCT) metric vs CountDistinct inline → inline fallback (safe)")


def test_unmatched_metric_never_referenced():
    cols = build(with_metrics=True)
    assert not any(v == "[Metrics/Unrelated]" for v in cols.values()), cols
    print("[ok] non-matching metric → never referenced (no false positive)")


if __name__ == "__main__":
    test_fallback_without_dm_spec()
    test_matched_measure_binds_to_metric()
    test_countdistinct_form_mismatch_falls_back()
    test_unmatched_metric_never_referenced()
    print("ALL PASS")
