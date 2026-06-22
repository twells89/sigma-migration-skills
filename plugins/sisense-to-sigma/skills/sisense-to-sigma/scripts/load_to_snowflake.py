#!/usr/bin/env python3
"""
Extract a Sisense ElastiCube's tables (SQL endpoint, CSV) and load them into
Snowflake CSA.<schema> via the `snow` CLI (connection `tj`).

Preserves original column names as quoted identifiers so the Sigma DM and the
Sisense Live model line up 1:1.

Usage:
  python3 load_to_snowflake.py --cube "Sample ECommerce" \
      --model ~/sisense-migration/discovery/model_Sample_ECommerce.json \
      --schema SISENSE_ECOMMERCE
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.parse

WORK = os.path.expanduser("~/sisense-migration/load")
os.makedirs(WORK, exist_ok=True)

BASE = os.environ["SISENSE_BASE_URL"].rstrip("/")
TOKEN = os.environ["SISENSE_API_TOKEN"]

# Sisense column type code -> Snowflake type
TYPEMAP = {18: "VARCHAR", 8: "NUMBER(38,0)", 5: "FLOAT", 4: "DATE",
           6: "TIMESTAMP_NTZ", 31: "DATE", 0: "VARCHAR"}


# The SQL endpoint caps a default (no-LIMIT) response at 5000 rows, but honors a
# large explicit LIMIT and returns the full table in one shot. Do NOT paginate
# with OFFSET — ElastiCube SQL has no stable order across pages, so OFFSET pages
# overlap/skip rows (same row count, corrupted aggregates). One big LIMIT is both
# correct and faster.
ROW_CAP = 100_000_000


def sql_csv(cube, base_query):
    """Fetch a full SELECT in one request via a large LIMIT; return CSV text."""
    url = f"{BASE}/api/datasources/{urllib.parse.quote(cube)}/sql"
    out = subprocess.run(
        ["curl", "-sk", "--max-time", "600", "-G", url,
         "-H", f"Authorization: Bearer {TOKEN}",
         "--data-urlencode", f"query={base_query} LIMIT {ROW_CAP}",
         "--data-urlencode", "format=csv"],
        capture_output=True, text=True, check=True).stdout
    if out.lstrip().startswith("{") and '"error"' in out[:80]:
        raise RuntimeError(f"Sisense SQL error: {out[:200]}")
    return out


def snow(q):
    subprocess.run(["snow", "sql", "-c", "tj", "-q", q],
                   check=True, capture_output=True, text=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cube", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--schema", required=True)
    a = ap.parse_args()

    model = json.load(open(os.path.expanduser(a.model)))
    snow(f"CREATE SCHEMA IF NOT EXISTS CSA.{a.schema};")
    snow(f"CREATE STAGE IF NOT EXISTS CSA.{a.schema}.LOAD_STAGE;")

    tables = []
    for ds in model["datasets"]:
        for t in ds.get("schema", {}).get("tables", []):
            # skip custom-SQL / derived tables — the Sigma DM recomputes those as
            # SQL elements over the base tables (don't materialize them here)
            if (t.get("expression") or {}).get("expression"):
                print(f"  skip (custom-SQL, computed in Sigma): {t['name']}")
                continue
            tables.append(t)

    for t in tables:
        name = t["name"]
        cols = [c for c in t["columns"]]
        # build SELECT with fully-qualified, bracketed identifiers
        sel = ", ".join(f"[{name}].[{c['name']}]" for c in cols)
        query = f"SELECT {sel} FROM [{name}]"
        csv_text = sql_csv(a.cube, query)
        path = os.path.join(WORK, f"{name}.csv")
        open(path, "w").write(csv_text)
        nrows = csv_text.count("\n") - 1
        print(f"  extracted {name}: {nrows} rows -> {path}")

        # DDL preserving original column names (quoted)
        coldefs = ", ".join(
            f'"{c["name"]}" {TYPEMAP.get(c["type"], "VARCHAR")}' for c in cols)
        fq = f'CSA.{a.schema}."{name.upper()}"'
        snow(f"CREATE OR REPLACE TABLE {fq} ({coldefs});")
        snow(f"PUT 'file://{path}' @CSA.{a.schema}.LOAD_STAGE "
             f"OVERWRITE=TRUE AUTO_COMPRESS=TRUE;")
        snow(f"COPY INTO {fq} FROM @CSA.{a.schema}.LOAD_STAGE/{name}.csv.gz "
             f"FILE_FORMAT=(TYPE=CSV SKIP_HEADER=1 "
             f"FIELD_OPTIONALLY_ENCLOSED_BY='\"' EMPTY_FIELD_AS_NULL=TRUE) "
             f"ON_ERROR=ABORT_STATEMENT;")
        print(f"  loaded   {fq}")

    print("done.")


if __name__ == "__main__":
    main()
