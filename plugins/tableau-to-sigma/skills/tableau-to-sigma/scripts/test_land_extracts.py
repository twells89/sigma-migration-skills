#!/usr/bin/env python3
"""Offline tests for scripts/land-extracts.py pure functions (2026-07-08).

Deterministic + offline: no Snowflake, no Sigma, no tableauhyperapi — the pure
layer (sanitization, table naming, type-tag mapping, per-value converters,
manifest shape) must be importable and correct WITHOUT the heavy deps
installed. Name cases come straight from a 10-workbook live migration
(skills-test-run/landing-manifest.json): GUID-suffixed tables, fact!sales,
HexStates.shp, leading-digit shapefiles, EXTRACT/SHEET1 generics.

Usage:  python3 scripts/test_land_extracts.py
"""
import datetime
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "land_extracts", os.path.join(HERE, "land-extracts.py"))
le = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(le)

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)
    print(f"  {'PASS' if cond else 'FAIL'}  {msg}")


print("Part A — module imports with NO heavy deps loaded")
for m in ("tableauhyperapi", "pandas", "snowflake", "snowflake.connector"):
    check(m not in sys.modules,
          f"importing land-extracts does not import {m} (pure layer stays pure)")

print("Part B — clean_ident (live-run cases)")
check(le.clean_ident("Orders_ECFCA1FB690A41FE803BC071773BA862") == "ORDERS",
      "GUID suffix stripped: Orders_<32hex> -> ORDERS")
check(le.clean_ident("fact!sales_4D2A5EA188224DF38988B52C7CDA4737") == "FACT_SALES",
      "fact!sales_<GUID> -> FACT_SALES")
check(le.clean_ident("HexStates.shp_E344E8491F784CDD9892CCFB8935C3C8") == "HEXSTATES_SHP",
      "HexStates.shp_<GUID> -> HEXSTATES_SHP")
check(le.clean_ident("2 Group outlines.shp_99EEC23FE2D64DDBA7FE7D2FAE4CDD6B")
      == "C_2_GROUP_OUTLINES_SHP",
      "leading digit guarded: 2 Group outlines.shp -> C_2_GROUP_OUTLINES_SHP")
check(le.clean_ident("uk_group_population.csv_351ECDD659DD4379A31F67AFC21AE5AD")
      == "UK_GROUP_POPULATION_CSV",
      "uk_group_population.csv_<GUID> -> UK_GROUP_POPULATION_CSV")
check(le.clean_ident("Country/Region") == "COUNTRY_REGION",
      "separators collapse: Country/Region -> COUNTRY_REGION")
check(le.clean_ident("a  -  b") == "A_B", "runs of separators collapse to one _")
check(le.clean_ident("") == "COL" and le.clean_ident("!!!") == "COL",
      "empty / all-symbols fall back to COL")
check(le.clean_ident("Sales", upper=False) == "Sales", "upper=False preserves case")

print("Part C — generic-table detection + sf_table_name")
check(le.is_generic_table_name("EXTRACT"), "EXTRACT is generic")
check(le.is_generic_table_name("SHEET1"), "SHEET1 is generic")
check(le.is_generic_table_name("EXTRACT_EXTRACT_EXTRACT"),
      "Extract (Extract.Extract) cleans to a generic name (live radar-chart case)")
check(le.is_generic_table_name("MIGRATED_DATA"), "MIGRATED_DATA is generic")
check(not le.is_generic_table_name("ORDERS"), "ORDERS is meaningful")
check(not le.is_generic_table_name("FACT_SALES"), "FACT_SALES is meaningful")

used = set()
check(le.sf_table_name("Extract", "World Indicators", "VV", used)
      == "VV_WORLD_INDICATORS",
      "generic hyper table takes the datasource caption: VV_WORLD_INDICATORS")
check(le.sf_table_name("Orders_ECFCA1FB690A41FE803BC071773BA862",
                       "Sample - EU Superstore", "VV", used) == "VV_ORDERS",
      "meaningful hyper table keeps its own name: VV_ORDERS")
check(le.sf_table_name("Orders_895AA2C82D0D4A479148EFCE815AE252",
                       "Another DS", "VV", used) == "VV_ORDERS_2",
      "name collision dedupes with _2")
check(le.sf_table_name("Extract (Extract.Extract)_2363FB1A4F434CB184243B518D96DB24",
                       "Radar Football Stats", "VV", used) == "VV_RADAR_FOOTBALL_STATS",
      "generic-token compound name falls back to caption (VV_RADAR_FOOTBALL_STATS)")
long_cap = "X" * 60
check(le.sf_table_name("Extract", long_cap, "P", set()) == "P_" + "X" * 40,
      "caption-derived names clip the caption at 40 chars")

print("Part D — type-tag -> landing action")
for tag, want in [("DATE", "date"), ("TIMESTAMP", "timestamp"),
                  ("TIMESTAMP_TZ", "timestamp"), ("GEOGRAPHY", "geography-cast"),
                  ("INTERVAL", "stringify"), ("TEXT", "native"),
                  ("BIG_INT", "native"), ("DOUBLE", "native"),
                  ("BOOL", "native"), ("NUMERIC", "native"), (None, "native")]:
    check(le.plan_column(tag) == want, f"plan_column({tag!r}) == {want!r}")

print("Part E — build_column_plan (dedupe + shape)")
plan = le.build_column_plan([
    ("Order Date", "DATE"), ("Country/Region", "TEXT"),
    ("Country Region", "TEXT"), ("Geometry", "GEOGRAPHY")])
check([e["landed"] for e in plan]
      == ["ORDER_DATE", "COUNTRY_REGION", "COUNTRY_REGION_2", "GEOMETRY"],
      "landed names cleaned + deduped in order")
check(plan[0]["action"] == "date" and plan[3]["action"] == "geography-cast",
      "actions ride along per column")
check(set(plan[0]) == {"orig", "landed", "action"}, "plan entries carry orig/landed/action")

print("Part F — per-value converters: None -> NULL, never the string 'None'")


class FakeHyperDate:
    """Stands in for tableauhyperapi.Date (has .to_date())."""

    def to_date(self):
        return datetime.date(2024, 1, 2)


class FakeHyperTimestamp:
    def to_datetime(self):
        return datetime.datetime(2024, 1, 2, 3, 4, 5)


check(le.to_py_date(None) is None, "to_py_date(None) is None (lands NULL)")
check(le.to_py_date(FakeHyperDate()) == datetime.date(2024, 1, 2),
      "hyper Date -> datetime.date via to_date()")
check(le.to_py_date(datetime.date(2020, 5, 5)) == datetime.date(2020, 5, 5),
      "already-a-date passes through")
check(le.to_py_datetime(None) is None, "to_py_datetime(None) is None (lands NULL)")
check(le.to_py_datetime(FakeHyperTimestamp()) == datetime.datetime(2024, 1, 2, 3, 4, 5),
      "hyper Timestamp -> datetime via to_datetime()")
check(le.to_str_or_none(None) is None, "to_str_or_none(None) is None — NOT 'None'")
check(le.to_str_or_none(42) == "42", "to_str_or_none stringifies real values")

# THE 'None'-vs-NULL CONTRACT (the exact live-run bug, pinned here):
# astype(str) on a whole object column turns Python None into the string
# 'None' — 24 date columns landed as TEXT and NULLs landed as 'None' in the
# live run and needed post-hoc repair. The fix: 'native' columns are NEVER
# rewritten, so (a) Python None stays None -> SQL NULL, and (b) a GENUINE
# 'None' string category value (ER department_referral, eco_certification)
# passes through byte-identical.
check(le.plan_column("TEXT") == "native",
      "'None'-preservation: TEXT columns are native — never rewritten")

print("Part G — apply_column_actions (needs pandas; skipped when absent)")
try:
    import pandas as pd
except ImportError:
    pd = None
    print("  SKIP  pandas not installed — pure-layer contract already covered above")
if pd is not None:
    df = pd.DataFrame({
        "REFERRAL": ["None", None, "Cardiology"],          # genuine 'None' category!
        "ORDER_DATE": [FakeHyperDate(), None, FakeHyperDate()],
        "CREATED_AT": [FakeHyperTimestamp(), None, FakeHyperTimestamp()],
    })
    plan_g = [{"orig": "Referral", "landed": "REFERRAL", "action": "native"},
              {"orig": "Order Date", "landed": "ORDER_DATE", "action": "date"},
              {"orig": "Created At", "landed": "CREATED_AT", "action": "timestamp"}]
    le.apply_column_actions(df, plan_g, pd)
    check(df["REFERRAL"].tolist()[0] == "None",
          "genuine 'None' STRING category value preserved untouched")
    check(df["REFERRAL"].tolist()[1] is None,
          "Python None in a native column stays None (lands NULL)")
    check(df["ORDER_DATE"].tolist()[0] == datetime.date(2024, 1, 2),
          "DATE column converted to datetime.date at read time")
    check(df["ORDER_DATE"].tolist()[1] is None,
          "None in a DATE column stays None (lands NULL)")
    check(str(df["CREATED_AT"].dtype).startswith("datetime64"),
          "TIMESTAMP column becomes pandas datetime64")
    check(pd.isna(df["CREATED_AT"].iloc[1]),
          "None in a TIMESTAMP column becomes NaT (lands NULL)")

print("Part H — ds_captions + match_ds")
TWB = """<?xml version='1.0' encoding='utf-8'?>
<workbook>
  <datasources>
    <datasource caption='Radar Football Stats' name='federated.0ekaykw02fhokp0zlnc6r0'/>
    <datasource name='Parameters'/>
    <datasource caption='Hospital ER' name='federated.1l186hf0cxun5t1gww5oi1'/>
    <datasource name='federated.uncaptioned'/>
  </datasources>
</workbook>
"""
with tempfile.NamedTemporaryFile("w", suffix=".twb", delete=False) as f:
    f.write(TWB)
    twb_path = f.name
try:
    caps = le.ds_captions(twb_path)
    check("Parameters" not in caps, "Parameters datasource skipped")
    check(caps.get("federated.0ekaykw02fhokp0zlnc6r0") == "Radar Football Stats",
          "caption read from the .twb")
    check(caps.get("federated.uncaptioned") == "federated.uncaptioned",
          "caption falls back to the datasource name")
    name, cap = le.match_ds("/x/federated_0ekaykw02fhokp0zlnc6r0.hyper", caps)
    check((name, cap) == ("federated.0ekaykw02fhokp0zlnc6r0", "Radar Football Stats"),
          "hyper filename prefix-matches its federated datasource")
    name, cap = le.match_ds("/x/unrelated_thing.hyper", caps)
    check((name, cap) == ("unrelated_thing", "unrelated_thing"),
          "no match falls back to the hyper basename")
finally:
    os.unlink(twb_path)

print("Part I — manifest entry shape (Phase 3 contract)")
entry = le.manifest_entry("er-visits", "federated.abc", "Hospital ER",
                          "/tmp/x/federated_abc.hyper", "Extract",
                          "ANALYTICS.LANDING.ER_HOSPITAL_ER", 9216,
                          {"Date": "DATE_1"})
check(list(entry.keys()) == ["slug", "datasource", "caption", "hyper",
                             "hyper_table", "sf_table", "rows", "columns"],
      "manifest entry keys exactly match the reference landing-manifest.json")
check(entry["hyper"] == "federated_abc.hyper", "hyper is the basename only")
check(entry["columns"] == {"Date": "DATE_1"}, "columns is the orig->landed map")

print("Part J — ds_hyper_map: dbname→caption recovers GUID-named hypers")
# GUID-named .hyper whose caption ("ZQXKPnullREV2005 Extract") shares no tokens
# with the filename — match_ds falls back to the GUID stem, but the federated
# named-connection's dbname carries the real .hyper name.
TWB = """<?xml version='1.0' encoding='utf-8'?>
<workbook><datasources>
  <datasource caption='Parameters' name='Parameters'/>
  <datasource caption='ZQXKPnullREV2005 Extract' name='federated.rev'>
    <connection class='federated'><named-connections><named-connection name='n1'>
      <connection class='hyper' dbname='Data/dataengine_0vr0bc01wliy3712xve51.hyper' schema='Extract'/>
    </named-connection></named-connections></connection>
  </datasource>
  <datasource caption='1. Metric Series Extract' name='federated.wb'>
    <connection class='federated'><named-connections><named-connection name='n2'>
      <connection class='hyper' dbname='dataengine_0tb9dex1oka5x010ueapg.hyper'/>
    </named-connection></named-connections></connection>
  </datasource>
</datasources></workbook>"""
with tempfile.NamedTemporaryFile("w", suffix=".twb", delete=False) as tf:
    tf.write(TWB)
    twb_path2 = tf.name
try:
    hm = le.ds_hyper_map(twb_path2)
    check(hm.get("dataengine_0vr0bc01wliy3712xve51.hyper") == ("federated.rev", "ZQXKPnullREV2005 Extract"),
          "GUID hyper → (name, caption) via dbname")
    check(hm.get("dataengine_0tb9dex1oka5x010ueapg.hyper") == ("federated.wb", "1. Metric Series Extract"),
          "second GUID hyper mapped (dbname without a path prefix)")
    check("Parameters" not in [v[0] for v in hm.values()], "Parameters datasource skipped")
    # The heuristic match_ds would MISS these (no shared tokens) — proving the map
    # is what recovers the clean caption.
    caps = le.ds_captions(twb_path2)
    guessed = le.match_ds("dataengine_0vr0bc01wliy3712xve51.hyper", caps)
    check(guessed[1] != "ZQXKPnullREV2005 Extract",
          "match_ds alone falls back to the GUID (confirms the map is load-bearing)")
finally:
    os.unlink(twb_path2)

print("Part K — Sigma catalog sync delegates auth + one-401 retry to sigma_rest")
calls = []
original_base_url = le.sigma_rest.base_url
original_auth_token = le.sigma_rest.auth_token
original_request = le.sigma_rest.request
try:
    le.sigma_rest.base_url = lambda: "https://api.sigmacomputing.com"
    le.sigma_rest.auth_token = lambda: "caller-or-browser-token"

    def fake_sigma_request(method, path, body=None, **_kwargs):
        payload = json.loads(body)
        calls.append((method, path, payload))
        if payload["path"][-1] == "BAD_TABLE":
            raise le.sigma_rest.SigmaError("POST sync -> 500 fixture")
        return {}

    le.sigma_rest.request = fake_sigma_request
    ok, failed = le.sigma_sync_tables(
        "connection-1", ["GOOD_TABLE", "BAD_TABLE"], "DB", "LANDING"
    )
    check((ok, failed) == (1, 1),
          "catalog sync preserves per-table success/failure accounting")
    check(calls == [
        ("post", "/v2/connections/connection-1/sync",
         {"path": ["DB", "LANDING", "GOOD_TABLE"]}),
        ("post", "/v2/connections/connection-1/sync",
         {"path": ["DB", "LANDING", "BAD_TABLE"]}),
    ], "catalog sync sends the existing endpoint/body through sigma_rest.request")
finally:
    le.sigma_rest.base_url = original_base_url
    le.sigma_rest.auth_token = original_auth_token
    le.sigma_rest.request = original_request

print("Part L — Sigma catalog sync resolves neutral-file auth despite empty env")
saved_env = {key: os.environ.get(key) for key in (
    "HOME", "SIGMA_BASE_URL", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET"
)}
with tempfile.TemporaryDirectory() as home:
    neutral_dir = os.path.join(home, ".sigma-migration")
    os.makedirs(neutral_dir)
    with open(os.path.join(neutral_dir, "env"), "w", encoding="utf-8") as fh:
        fh.write(
            "SIGMA_BASE_URL='https://api.sigmacomputing.com'\n"
            "SIGMA_CLIENT_ID='file-id'\n"
            "SIGMA_CLIENT_SECRET='file-secret'\n"
        )
    os.environ["HOME"] = home
    os.environ["SIGMA_CLIENT_ID"] = ""
    os.environ.pop("SIGMA_BASE_URL", None)
    os.environ.pop("SIGMA_CLIENT_SECRET", None)
    le.sigma_rest.base_url = lambda: os.environ["SIGMA_BASE_URL"]
    le.sigma_rest.auth_token = lambda: (
        os.environ["SIGMA_CLIENT_ID"], os.environ["SIGMA_CLIENT_SECRET"]
    )
    le.sigma_rest.request = lambda *_args, **_kwargs: {}
    try:
        ok, failed = le.sigma_sync_tables(
            "connection-1", ["GOOD_TABLE"], "DB", "LANDING"
        )
        check((ok, failed) == (1, 0), "neutral-file Sigma auth passes sync preflight")
        check(os.environ["SIGMA_CLIENT_ID"] == "file-id",
              "empty client id is filled from the neutral file")
    finally:
        le.sigma_rest.base_url = original_base_url
        le.sigma_rest.auth_token = original_auth_token
        le.sigma_rest.request = original_request
for key, value in saved_env.items():
    if value is None:
        os.environ.pop(key, None)
    else:
        os.environ[key] = value

source = open(os.path.join(HERE, "land-extracts.py"), encoding="utf-8").read()
check("client_credentials" not in source and "def sigma_token(" not in source,
      "landing path no longer mints client credentials or owns a static token")

print()
if fails:
    print(f"{len(fails)} FAILURE(S):")
    for f in fails:
        print(f"  - {f}")
    sys.exit(1)
print("ALL PASS")
