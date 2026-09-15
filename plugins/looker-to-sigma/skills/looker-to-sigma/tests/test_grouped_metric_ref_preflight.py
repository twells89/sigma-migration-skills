#!/usr/bin/env python3
"""A grouped table's calculations must never be a [Metrics/<name>] passthrough.

build_workbook prefers a governed `[Metrics/<name>]` reference over re-deriving a measure's
aggregate inline. That is correct for a KPI or an ungrouped value, but INVALID inside a
grouped table's `groupings.calculations`: Sigma needs a real aggregate expression there, and
a passthrough of an already-aggregated column renders 'multiple values'. `preflight_lint`
rule T2 rejects it, so the orchestrator dies at "workbook preflight failed" and no workbook
is ever written — every Looker dashboard with a grouped table whose measures match DM metric
names is unbuildable.

Regression for beads-sigma-w22s, found by a live E2E fixture run: the Channel Summary table
emitted `[Metrics/Order Count]` / `[Metrics/Total Net Revenue]` where the committed golden
holds `CountDistinct([Data Scope 2/Order Id])` / `Sum([Data Scope 2/Net Revenue])`.

Run: python3 tests/test_grouped_metric_ref_preflight.py   (exit 0 = pass)
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

# Metrics whose formulas match the grouped_table fixture's measures (master prefix stripped),
# mirroring what migrate-looker reads off a posted/reused DM spec.
METRICS = [{"id": "el-x", "name": "Order Fact View", "metrics": [
    {"name": "Net Revenue", "formula": "Sum([Net Revenue])"},
    {"name": "Orders", "formula": "CountDistinct([Order Id])"}]}]

FAILURES = []


def build_spec(dm_elements):
    """Build the grouped-table fixture and return (spec_path_contents, tmpdir-kept path)."""
    d = tempfile.mkdtemp()
    op = os.path.join(d, "wb.json")
    cmd = [sys.executable, os.path.join(SCRIPTS, "build_workbook.py"),
           os.path.join(FIX, "look_grouped_table.contract.json"),
           "--views", VIEWS, "--dm-element-name", "Order Fact View", "--out", op]
    dep = os.path.join(d, "dm-elements.json")
    json.dump(dm_elements, open(dep, "w"))
    cmd.append(f"--dm-elements={dep}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    assert r.returncode == 0, f"build_workbook failed:\n{r.stderr}"
    return json.load(open(op)), op


def test_no_metric_passthrough_in_grouping_calculations():
    """Every id in groupings.calculations must resolve to a real aggregate, not [Metrics/...]."""
    spec, _ = build_spec(METRICS)
    tables = [e for e in code_rep.workbook_elements(spec)
              if e.get("kind") == "table" and e.get("name") != "Data"]
    checked = 0
    for t in tables:
        by_id = {c["id"]: c for c in t.get("columns") or []}
        for g in t.get("groupings") or []:
            for cid in g.get("calculations") or []:
                f = str((by_id.get(cid) or {}).get("formula", ""))
                checked += 1
                if f.startswith("[Metrics/"):
                    FAILURES.append(
                        f"table '{t.get('name')}' grouping calculation {cid} "
                        f"('{(by_id.get(cid) or {}).get('name')}') is a metric passthrough: {f}")
    assert checked, "fixture produced no grouping calculations — test would vacuously pass"
    if FAILURES:
        for m in FAILURES:
            print(f"  FAIL {m}")
    else:
        print(f"[ok] {checked} grouping calculation(s), none a [Metrics/...] passthrough")


def test_preflight_lint_accepts_the_built_spec():
    """The real gate: preflight_lint must exit 0 on a grouped table built with DM metrics."""
    spec, path = build_spec(METRICS)
    r = subprocess.run(["ruby", os.path.join(SCRIPTS, "lib", "preflight_lint.rb"), path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        FAILURES.append("preflight_lint rejected the built spec")
        print(f"  FAIL preflight_lint exit={r.returncode}")
        for ln in (r.stdout + r.stderr).splitlines():
            if ln.strip():
                print(f"       {ln.strip()[:160]}")
    else:
        print("[ok] preflight_lint exit 0 on a grouped table built with DM metrics")


def test_ungrouped_metric_ref_still_preferred():
    """Guard against over-correcting: the governed ref must survive where it is valid."""
    spec, _ = build_spec(METRICS)
    kpis = [e for e in code_rep.workbook_elements(spec) if "kpi" in str(e.get("kind"))]
    refs = [c["formula"] for e in kpis for c in (e.get("columns") or [])
            if str(c.get("formula", "")).startswith("[Metrics/")]
    print(f"[ok] {len(kpis)} kpi element(s); {len(refs)} governed metric ref(s) retained "
          f"(informational — fixture may have no KPI tile)")


if __name__ == "__main__":
    test_no_metric_passthrough_in_grouping_calculations()
    test_preflight_lint_accepts_the_built_spec()
    test_ungrouped_metric_ref_still_preferred()
    if FAILURES:
        print(f"\n{len(FAILURES)} FAILURE(S)")
        sys.exit(1)
    print("\nALL PASS")
