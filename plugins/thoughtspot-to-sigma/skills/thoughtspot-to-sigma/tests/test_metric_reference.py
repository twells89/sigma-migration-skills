#!/usr/bin/env python3
"""DM-metric references in the thoughtspot workbook builder (leverage the semantic
layer instead of duplicating aggregations). Offline, creds-free.

ts_common._element_core's `mref` prefers a governed `[Metrics/<name>]` reference
over re-deriving a measure's aggregate inline, when the measure's inline aggregate
matches a metric referenceable on the master (the `resolver["__metrics__"]` list
migrate.py resolves via metric_binding.available_metrics over the denorm view's
source.elementId chain). Match is by FORMULA equivalence (strip the "OFV" master
prefix). SAFE: no metrics / no match / synthesized timeshift-growth-window measures
fall back to inline; empty is byte-identical (the existing test_grounding suite runs
with resolver={} and is unaffected).

Run: python3 tests/test_metric_reference.py   (exit 0 = pass)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "lib"))
import ts_common as t  # noqa: E402
import metric_binding as mb  # noqa: E402

KPI = {"name": "Rev", "chart": "KPI", "dims": [], "measures": ["Revenue"],
       "mtypes": {"Revenue": {"agg": "SUM"}}}


def _formula(resolver):
    el = t.sigma_element(dict(KPI), resolver)
    return el["columns"][0]["formula"]


def test_fallback_without_metrics():
    """resolver has no __metrics__ (the state every existing test runs in) → inline."""
    f = _formula({})
    assert f.startswith("Sum(") and "[Metrics/" not in f, f
    print("[ok] no __metrics__ → inline (byte-identical fallback):", f)


def test_matched_measure_binds_to_metric():
    f = _formula({"__metrics__": [{"name": "Total Revenue", "formula": "Sum([Revenue])"}]})
    assert f == "[Metrics/Total Revenue]", f
    print("[ok] matched aggregate → [Metrics/Total Revenue] (governed, no re-derive)")


def test_nonmatching_metric_ignored():
    f = _formula({"__metrics__": [{"name": "Other", "formula": "Sum([Something Else])"}]})
    assert f.startswith("Sum(") and "[Metrics/" not in f, f
    print("[ok] non-matching metric → inline (no false positive)")


def test_available_metrics_walks_view_chain():
    """The migrate.py resolution half: a denorm '<X> View' element (0 own metrics)
    inherits its base fact's metrics via source.elementId — exactly what migrate.py
    feeds into resolver["__metrics__"]."""
    els = {
        "view": {"id": "view", "name": "Order Fact View", "metrics": [],
                 "source": {"elementId": "fact"}},
        "fact": {"id": "fact", "name": "Order Fact",
                 "metrics": [{"name": "Net Revenue", "formula": "Sum([Net Revenue])"}]},
    }
    got = mb.available_metrics("view", els)
    assert got == [{"name": "Net Revenue", "formula": "Sum([Net Revenue])"}], got
    print("[ok] available_metrics walks the denorm-view → base-fact source.elementId chain")


if __name__ == "__main__":
    test_fallback_without_metrics()
    test_matched_measure_binds_to_metric()
    test_nonmatching_metric_ignored()
    test_available_metrics_walks_view_chain()
    print("ALL PASS")
