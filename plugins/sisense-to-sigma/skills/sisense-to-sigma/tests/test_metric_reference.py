#!/usr/bin/env python3
"""DM-metric EMIT + reference for sisense (bead 7bun.11 — emit-first). Offline, creds-free.

Sisense has no source-side metrics, so `harvest_metrics` pulls a governed metric per
dashboard JAQL measure, `convert_model(..., metrics=…)` EMITs them onto the DM
element(s) that carry the columns, and `convert_dashboard(..., dm_metrics=…)` prefers a
`[Metrics/<name>]` reference over the inline aggregate (formula-equivalence via the
shared binder scripts/lib/metric_binding.py; strip the "Master" prefix). Reference is
gated on the DM's ACTUAL metrics so a workbook never points at an absent metric. SAFE:
no metrics → inline, byte-identical.

This is a true emit→reference round-trip, in-process (mirrors tests/test_convert.py).
Run: python3 tests/test_metric_reference.py   (exit 0 = pass)
"""
import sys, os, json

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "lib"))
import convert as C  # noqa: E402
import metric_binding as mb  # noqa: E402

FIX = os.path.join(HERE, "..", "fixtures")
CONN = "00000000-0000-0000-0000-000000000000"
MODEL = json.load(open(os.path.join(FIX, "model_ecommerce.json")))
DASHBOARDS = json.load(open(os.path.join(FIX, "dashboards.json")))

fails = []
def ok(label, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {label}")
    if not cond:
        fails.append(label)


def fact_of(spec):
    els = spec["pages"][0]["elements"]
    return max(els, key=lambda e: len(e.get("columns", [])))


def measure_formulas(dm_metrics):
    dm_info = {"dataModelId": "dm-x", "factElementId": FACT_ID, "factName": "Commerce"}
    wb, _ = C.convert_dashboard(LIVE, MODEL, dm_info, dm_metrics=dm_metrics)
    cols = [c for pg in wb["pages"] for el in pg["elements"] for c in el.get("columns", [])]
    return [str(c["formula"]) for c in cols]


LIVE = [d for d in DASHBOARDS if "Live" in (d.get("title") or "")][:1] or DASHBOARDS[:1]

# ---- EMIT: harvest_metrics + convert_model(metrics=…) puts metrics on the fact -----
harvested = C.harvest_metrics(LIVE)
ok("EMIT: harvest_metrics found dashboard measures", len(harvested) > 0)
spec, _ = C.convert_model(MODEL, CONN, "SISENSE_ECOMMERCE", "DEMO_DB", metrics=harvested)
fact = fact_of(spec)
FACT_ID = fact["id"]
fact_mets = fact.get("metrics") or []
ok("EMIT: metrics attached to the fact element", len(fact_mets) > 0)
# every emitted metric references only columns that exist on the element (no broken metric)
fact_cols = {c["name"] for c in fact["columns"]}
ok("EMIT: each emitted metric references only real fact columns",
   all(C._metric_ref_cols(m["formula"]) <= fact_cols for m in fact_mets))

# a plain Sum(Revenue) measure should have produced a metric with formula Sum([Revenue])
rev_metric = next((m for m in fact_mets if m["formula"] == "Sum([Revenue])"), None)
ok("EMIT: Sum([Revenue]) metric emitted", rev_metric is not None)

# ---- REFERENCE: bind workbook measures to the DM's actual metrics -------------------
by_id = {e["id"]: e for e in spec["pages"][0]["elements"]}
dm_metrics = mb.available_metrics(FACT_ID, by_id)

bound = measure_formulas(dm_metrics)
inline = measure_formulas(None)

if rev_metric:
    want = f"[Metrics/{rev_metric['name']}]"
    ok(f"REFERENCE: a Sum([Master/Revenue]) measure binds to {want}", want in bound)
ok("REFERENCE: with metrics, at least one measure became a [Metrics/<name>] ref",
   any(f.startswith("[Metrics/") for f in bound))

# ---- fallback: no dm_metrics → inline, no metric refs (byte-identical) --------------
ok("fallback: no dm_metrics → Sum([Master/Revenue]) stays inline",
   any(f == "Sum([Master/Revenue])" for f in inline))
ok("fallback: no dm_metrics → no [Metrics/<name>] refs",
   not any(f.startswith("[Metrics/") for f in inline))

if fails:
    print("FAILURES:\n  - " + "\n  - ".join(fails))
    sys.exit(1)
print("ALL PASS — sisense EMITs DM metrics from JAQL + binds workbook measures to [Metrics/<name>]")
