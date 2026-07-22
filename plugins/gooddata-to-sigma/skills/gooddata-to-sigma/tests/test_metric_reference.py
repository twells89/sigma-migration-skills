#!/usr/bin/env python3
"""DM-metric references in the gooddata workbook builder (leverage the semantic
layer instead of duplicating aggregations). Offline, creds-free.

build_workbook.py prefers a governed `[Metrics/<name>]` reference over re-deriving
a measure's aggregation inline, when the measure's translated inline aggregate
matches a metric on the fact element the master sources — via the shared binder
(scripts/lib/metric_binding.py; formula-equivalence match, master prefix "Data").
SAFE: no `--dm-spec`, no match, and MAQL-context/ratio measures fall back to inline.

The matched-case metric formula is DERIVED from the no-`--dm-spec` build's own inline
output (stripping the "[Data/" master prefix), so the test exercises the real MAQL
translate path rather than hardcoding a fact title.

Run: python3 tests/test_metric_reference.py   (exit 0 = pass)
"""
import copy
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
BUILDER = os.path.join(SKILL, "scripts", "build_workbook.py")
FIXTURE = os.path.join(SKILL, "fixtures", "test_workspace_orders.json")

# a bar chart over one plain-Sum measure (m_gross_revenue = SELECT SUM({fact/gross_revenue}))
# and one category dim, injected into the (otherwise viz-empty) fixture.
INSIGHT = {
    "id": "ins_rev_by_channel", "title": "Rev by Channel",
    "content": {"visualizationUrl": "local:column", "buckets": [
        {"localIdentifier": "measures", "items": [
            {"measure": {"localIdentifier": "m1", "title": "Gross Revenue",
                         "definition": {"measureDefinition": {
                             "item": {"identifier": {"id": "m_gross_revenue"}}}}}}]},
        {"localIdentifier": "view", "items": [
            {"attribute": {"localIdentifier": "a1",
                           "displayForm": {"identifier": {"id": "acquisition_channel.name"}}}}]},
    ]},
}


def build(dm_spec=None):
    ws = copy.deepcopy(json.load(open(FIXTURE)))
    ws["analytics"]["visualizationObjects"] = [INSIGHT]
    with tempfile.TemporaryDirectory() as d:
        wp = os.path.join(d, "ws.json"); json.dump(ws, open(wp, "w"))
        out = os.path.join(d, "wb.json")
        cmd = [sys.executable, BUILDER, "--workspace", wp,
               "--data-model-id", "dm-x", "--fact-element", "el-x",
               "--fact-name", "ORDER_FACT", "--rel-name", "EL_CUSTOMER",
               "--fact-dataset", "order", "--folder-id", "fld-x", "--out", out]
        if dm_spec is not None:
            sp = os.path.join(d, "dm-spec.json"); json.dump(dm_spec, open(sp, "w"))
            cmd += ["--dm-spec", sp]
        r = subprocess.run(cmd, capture_output=True, text=True)
        assert r.returncode == 0, "build_workbook failed:\n" + r.stderr
        spec = json.load(open(out))
        # the injected chart element (NOT the Data-page master detail table, which
        # also carries a "Gross Revenue" column)
        for pg in spec["pages"]:
            for el in pg["elements"]:
                if el.get("id") != INSIGHT["id"]:
                    continue
                for c in el.get("columns", []):
                    if c.get("name") == "Gross Revenue":
                        return c["formula"]
        raise AssertionError("Gross Revenue measure column not found: " + json.dumps(spec))


def _dm_spec(metrics):
    return {"name": "t", "schemaVersion": 1, "pages": [{"id": "pg", "name": "P",
            "elements": [{"id": "el-x", "name": "Data", "metrics": metrics}]}]}


def test_fallback_without_dm_spec():
    f = build(None)
    assert f.startswith("Sum(") and "[Metrics/" not in f, f
    print("[ok] no --dm-spec → inline (byte-identical fallback):", f)


def test_matched_measure_binds_to_metric():
    inline = build(None)                              # real translate-path output
    metric_formula = inline.replace("[Data/", "[")    # element-relative form a DM metric uses
    f = build(_dm_spec([{"name": "Gross Revenue Metric", "formula": metric_formula}]))
    assert f == "[Metrics/Gross Revenue Metric]", f
    print("[ok] matched aggregate → [Metrics/Gross Revenue Metric] (governed, no re-derive)")


def test_unmatched_metric_never_referenced():
    f = build(_dm_spec([{"name": "Unrelated", "formula": "Sum([Nonexistent Col])"}]))
    assert f.startswith("Sum(") and "[Metrics/" not in f, f
    print("[ok] non-matching metric → inline (no false positive)")


if __name__ == "__main__":
    test_fallback_without_dm_spec()
    test_matched_measure_binds_to_metric()
    test_unmatched_metric_never_referenced()
    print("ALL PASS")
