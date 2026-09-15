#!/usr/bin/env python3
"""DM-metric references (leverage the semantic layer instead of duplicating aggregations).

build_workbook prefers a governed `[Metrics/<name>]` reference over re-deriving a measure's
aggregation inline, when the measure's inline aggregate matches a metric defined on the source
DM element. Match is by FORMULA equivalence (strip the master prefix so `Sum([Data/Net Revenue])`
equals a metric's `Sum([Net Revenue])`) — naming-independent and SAFE: ratios, filtered measures,
custom/ad-hoc measures, non-matching metrics, and the no-metrics path all fall back to inline.

Metric names/formulas reach build_workbook via the `--dm-elements` payload (migrate-looker reads
them from the posted/reused DM spec). With no metrics passed (this suite's control + all other
offline suites + the golden) output is byte-identical to before. No live warehouse.

Run: python3 tests/test_metric_reference.py   (exit 0 = pass)
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

# metrics whose formulas match the grouped_table fixture's Sum/CountDistinct measures
# (master prefix stripped) — mirrors what migrate-looker reads off the DM spec.
METRICS = [{"id": "el-x", "name": "Order Fact View", "metrics": [
    {"name": "Net Revenue", "formula": "Sum([Net Revenue])"},
    {"name": "Orders", "formula": "CountDistinct([Order Id])"}]}]


def build(dm_elements=None, fixture="look_grouped_table", kind="table"):
    with tempfile.TemporaryDirectory() as d:
        op = os.path.join(d, "wb.json")
        cmd = [sys.executable, os.path.join(SCRIPTS, "build_workbook.py"),
               os.path.join(FIX, f"{fixture}.contract.json"),
               "--views", VIEWS, "--dm-element-name", "Order Fact View", "--out", op]
        if dm_elements is not None:
            dep = os.path.join(d, "dm-elements.json")
            json.dump(dm_elements, open(dep, "w"))
            cmd.append(f"--dm-elements={dep}")
        r = subprocess.run(cmd, capture_output=True, text=True)
        assert r.returncode == 0, f"build_workbook failed:\n{r.stderr}"
        spec = json.load(open(op))
        t = [e for e in code_rep.workbook_elements(spec)
             if e.get("kind") == kind and e.get("name") != "Data"][0]
        return {c.get("name"): c["formula"] for c in t["columns"]}


def test_fallback_without_metrics():
    """No metrics passed → inline aggregates (byte-identical to prior behavior)."""
    cols = build(None)
    assert cols["Total Net Revenue"].startswith("Sum("), cols["Total Net Revenue"]
    assert cols["Distinct Order Count"].startswith("CountDistinct("), cols["Distinct Order Count"]
    assert not any(str(v).startswith("[Metrics/") for v in cols.values()), cols
    print("[ok] no metrics passed → inline (byte-identical fallback)")


def test_metric_ref_when_matched_on_pivot_values():
    """A measure matching a DM metric → [Metrics/<name>] where that is VALID: pivot values.

    Retargeted from the grouped-table fixture (beads-sigma-w22s). A grouped table's
    `groupings.calculations` must hold a real aggregate; a [Metrics/<name>] ref there is a
    passthrough of an already-aggregated column, renders 'multiple values', and preflight_lint
    T2 rejects it — so the old expectation asserted a spec that could never be POSTed. A
    pivot-table's `values` are aggregated cells with no `groupings`, so the governed ref is
    both valid and reachable there.
    """
    cols = build(METRICS, fixture="look_pivot_table", kind="pivot-table")
    assert cols["Total Net Revenue"] == "[Metrics/Net Revenue]", cols["Total Net Revenue"]
    print("[ok] matched aggregate on a pivot value → [Metrics/<name>] (governed, no re-derive)")


def test_grouped_table_calculations_stay_inline():
    """The grouped-table path must NOT use the governed ref (preflight T2 would reject it).

    Full gate coverage — including that preflight_lint accepts the result — lives in
    tests/test_grouped_metric_ref_preflight.py.
    """
    cols = build(METRICS, fixture="look_grouped_table", kind="table")
    assert not any(str(v).startswith("[Metrics/") for v in cols.values()), cols
    assert cols["Total Net Revenue"].startswith("Sum("), cols["Total Net Revenue"]
    print("[ok] grouped-table calculations stay inline aggregates")


def test_ratio_falls_back_to_inline():
    """A ratio measure with no exact-formula metric match stays inline (safe)."""
    aov = build(METRICS)["Average Order Value"]
    assert aov.startswith("1.0 *") and "[Metrics/" not in aov, aov
    print("[ok] ratio (no exact match) → inline fallback")


def test_unmatched_metric_is_ignored():
    """A metric that doesn't match any measure's formula must NOT be referenced."""
    cols = build([{"id": "el-x", "name": "Order Fact View",
                   "metrics": [{"name": "Unrelated", "formula": "Sum([Something Else])"}]}])
    assert cols["Total Net Revenue"].startswith("Sum(") and "[Metrics/" not in cols["Total Net Revenue"], cols
    print("[ok] non-matching metric → inline (no false positive)")


if __name__ == "__main__":
    test_fallback_without_metrics()
    test_metric_ref_when_matched_on_pivot_values()
    test_grouped_table_calculations_stay_inline()
    test_ratio_falls_back_to_inline()
    test_unmatched_metric_is_ignored()
    print("ALL PASS")
