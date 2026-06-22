#!/usr/bin/env python3
"""
Automated parity gate for a Sisense -> Sigma migration.

For each check it runs the SAME aggregate two ways and asserts they match:
  - Sisense:   POST /api/datasources/{ds}/jaql           (the source of truth)
  - Warehouse: the SQL Sigma's DM/workbook compiles to   (what Sigma serves)
Sigma reads the warehouse, so Sisense-JAQL == warehouse proves the data pipeline
end-to-end; a thin Sigma-workbook spot-check (via the Sigma MCP `query`) confirms
the workbook formulas compile to that same aggregate.

Emits a GREEN/RED table + parity_keys.json and exits non-zero on any mismatch —
do not claim a migration done until GREEN.

Scope: this gate checks DATA only. Layout fidelity (did the dashboard's
arrangement come over?) is a separate gate — see `verify_layout.py`. Run both.

Env: SISENSE_BASE_URL/SISENSE_API_TOKEN; `snow` CLI connection (default "tj").
Usage: python3 verify_parity.py <checks.json> [--snow-conn tj]
checks.json: [{"label","datasource","jaql":[...],"snowflake_sql","tol":0.01}]
"""
import json, os, subprocess, sys

def sisense_jaql(datasource, metadata):
    ds = datasource.replace(" ", "%20").replace("(", "%28").replace(")", "%29")
    out = subprocess.run(["curl", "-sk", "--max-time", "120", "-X", "POST",
        f'{os.environ["SISENSE_BASE_URL"].rstrip("/")}/api/datasources/{ds}/jaql',
        "-H", f'Authorization: Bearer {os.environ["SISENSE_API_TOKEN"]}',
        "-H", "Content-Type: application/json",
        "-d", json.dumps({"datasource": datasource, "metadata": metadata})],
        capture_output=True, text=True).stdout
    d = json.loads(out)
    if d.get("error"):
        return ("ERROR", d.get("details"))
    v = d.get("values") or []
    if not v:
        return []
    # single row -> flat list of cell dicts; grouped -> list of rows (lists)
    if isinstance(v[0], dict):
        return [c.get("data") for c in v]
    return [(r[0].get("data"), r[-1].get("data")) for r in v]

def snowflake(sql, conn):
    out = subprocess.run(["snow", "sql", "-c", conn, "--format", "json", "-q", sql],
                         capture_output=True, text=True,
                         env={**os.environ, "PATH": "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")})
    try:
        rows = json.loads(out.stdout)
    except Exception:
        return ("ERROR", out.stdout[-200:] + out.stderr[-200:])
    if len(rows) == 1:
        return list(rows[0].values())
    return [tuple(r.values()) for r in rows]

def approx(a, b, tol):
    if a is None or b is None:
        return a == b
    try:
        return abs(float(a) - float(b)) <= tol * max(1.0, abs(float(b)))
    except (TypeError, ValueError):
        return str(a).strip() == str(b).strip()

def cmp_result(sis, snow, tol):
    if not isinstance(sis, list) or not isinstance(snow, list):
        return False
    if sis and isinstance(sis[0], tuple):  # grouped: compare as sorted maps
        return sorted((str(k), round(float(v), 2)) for k, v in sis) == \
               sorted((str(k), round(float(v), 2)) for k, v in snow)
    return len(sis) == len(snow) and all(approx(a, b, tol) for a, b in zip(sis, snow))

def run(checks, conn):
    results, ok = [], True
    for c in checks:
        sis = sisense_jaql(c["datasource"], c["jaql"])
        snow = snowflake(c["snowflake_sql"], conn)
        match = cmp_result(sis, snow, c.get("tol", 0.01))
        ok = ok and match
        results.append({"label": c["label"], "sisense": sis, "warehouse": snow,
                        "verdict": "GREEN" if match else "RED"})
    json.dump(results, open("parity_keys.json", "w"), indent=2)
    for r in results:
        s = r["sisense"] if not (isinstance(r["sisense"], list) and len(r["sisense"]) > 6) else f"[{len(r['sisense'])} rows]"
        w = r["warehouse"] if not (isinstance(r["warehouse"], list) and len(r["warehouse"]) > 6) else f"[{len(r['warehouse'])} rows]"
        print(f"  [{r['verdict']}] {r['label']:32} sisense={s}  warehouse={w}")
    print(f"\n{sum(1 for r in results if r['verdict']=='GREEN')}/{len(results)} GREEN")
    return ok

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    conn = sys.argv[sys.argv.index("--snow-conn") + 1] if "--snow-conn" in sys.argv else "tj"
    sys.exit(0 if run(json.load(open(sys.argv[1])), conn) else 1)
