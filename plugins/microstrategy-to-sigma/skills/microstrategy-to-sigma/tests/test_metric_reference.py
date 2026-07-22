#!/usr/bin/env python3
"""DM-metric references in the microstrategy workbook builder (leverage the
semantic layer instead of duplicating aggregations). Offline, creds-free.

convert.py builds the DM (metrics on the join element) then the workbook in one
process; a metric column prefers a governed `[Metrics/<name>]` reference over
re-deriving the aggregation inline, when its expanded inline aggregate matches a
metric on the join element — via the shared binder (scripts/lib/metric_binding.py;
formula-equivalence match, master prefix = --join-element-name, default "Orders").
SAFE: composite/ratio metrics (which the workbook expands inline while the DM keeps
[MetricName] refs) and any non-match fall back to inline; empty metrics are a no-op.

Run: python3 tests/test_metric_reference.py   (exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
CONV = os.path.join(SKILL, "scripts", "convert.py")
BUNDLE = os.path.join(SKILL, "fixtures", "bundle.json")
AE_WINNERS = os.path.join(SKILL, "fixtures", "ae_winners.json")


def _convert():
    with tempfile.TemporaryDirectory() as d:
        wb = os.path.join(d, "wb.json"); dm = os.path.join(d, "dm.json")
        r = subprocess.run(
            [sys.executable, CONV, "--bundle", BUNDLE, "--connection-id", "conn-x",
             "--database", "DEMO_DB", "--folder-id", "fld-x", "--ae-winners", AE_WINNERS,
             "--out-dm", dm, "--out-wb", wb, "--out-layout", os.path.join(d, "l.xml"),
             "--control-scope-out", os.path.join(d, "cs.json")],
            capture_output=True, text=True, cwd=d)
        assert r.returncode == 0, "convert.py failed:\n" + r.stderr
        return json.load(open(wb)), json.load(open(dm))


def _cols(wb):
    return [c for pg in wb["pages"] for el in pg["elements"] for c in el.get("columns", [])]


def _dm_metric_names(dm):
    return {m["name"] for pg in dm["pages"] for el in pg["elements"] for m in (el.get("metrics") or [])}


def test_matched_measures_bind_to_metrics():
    """Simple-aggregate metric columns (Sum/CountDistinct) → [Metrics/<name>]."""
    wb, dm = _convert()
    refs = {c["formula"] for c in _cols(wb) if str(c["formula"]).startswith("[Metrics/")}
    assert "[Metrics/Total Net Revenue]" in refs, refs
    assert "[Metrics/Order Count]" in refs, refs      # CountDistinct binds (same repr both sides)
    # every emitted [Metrics/<name>] must name a metric that actually exists on the DM
    names = _dm_metric_names(dm)
    for r in refs:
        nm = r[len("[Metrics/"):-1]
        assert nm in names, f"referenced non-existent metric {nm!r}; DM has {sorted(names)}"
    print("[ok] matched aggregates → governed [Metrics/<name>] refs:", sorted(refs))


def test_ratio_metric_stays_inline():
    """A composite/ratio metric (Profit Margin Pct) is expanded inline in the workbook
    and must NOT bind to itself (representations differ → safe fallback)."""
    wb, _ = _convert()
    for c in _cols(wb):
        if c.get("name") == "Profit Margin Pct":
            assert not str(c["formula"]).startswith("[Metrics/"), c["formula"]
            print("[ok] ratio 'Profit Margin Pct' → inline fallback:", c["formula"])
            return
    # ratio may not appear on any report in the fixture — that's fine, nothing to assert
    print("[ok] ratio not present on a report (nothing to bind)")


def test_no_false_positive():
    """No column references a metric name absent from the DM (formula match, not name)."""
    wb, dm = _convert()
    names = _dm_metric_names(dm)
    bad = [c["formula"] for c in _cols(wb)
           if str(c["formula"]).startswith("[Metrics/") and c["formula"][len("[Metrics/"):-1] not in names]
    assert not bad, bad
    print("[ok] no [Metrics/<name>] ref points at a non-existent metric")


if __name__ == "__main__":
    test_matched_measures_bind_to_metrics()
    test_ratio_metric_stays_inline()
    test_no_false_positive()
    print("ALL PASS")
