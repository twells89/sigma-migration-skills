#!/usr/bin/env python3
"""
pbi_import_to_snowflake.py — Land an Import-mode Power BI semantic model's
source tables into Snowflake, generically.

This is the "data track" that a warehouse-native tool (e.g. Sigma) needs when a
.pbix imports its data from Excel / Power Query / flat files and has no live
warehouse behind it. It does NOT convert model logic (measures/relationships) —
that is the job of the powerbi->sigma converter. It produces real Snowflake
tables + a manifest mapping (pbi_table.column -> sf_table.COLUMN) so the
converted model can be repointed onto the warehouse.

Pipeline:
  1. Silent-auth to Power BI + Fabric (cached MSAL token, no device-code prompt).
  2. Resolve workspace + dataset (by name or id); optionally upload a .pbix first.
  3. Read the model structure via TMSL getDefinition (version-independent):
     enumerate tables + columns + dataTypes.
     - SKIP auto date tables (DateTableTemplate_/LocalDateTable_) and any table
       whose columns are ALL calculated (pure calc tables).
     - Within a kept table, land only STORED columns (skip calculated columns —
       those are DAX logic, recreated in Sigma).
  4. Extract rows per table via /executeQueries (DAX `EVALUATE`), with automatic
     integer-key band pagination (executeQueries silently truncates ~48k
     rows/response) -> CSV in out/<dataset>/.
  5. Generate load.sql (typed DDL from TMSL + PUT/COPY) and, unless --dry-run,
     execute it via `snow sql`.
  6. Emit manifest.json for the repoint step.

No customer/identifiable data is embedded here — target db/schema are CLI args.
"""
import argparse, os, sys, json, csv, base64, time, re, subprocess
try:
    import truststore; truststore.inject_into_ssl()  # corp TLS inspection
except Exception:
    pass
import msal, requests
from requests.adapters import HTTPAdapter
try:
    from urllib3.util.retry import Retry
except Exception:
    from requests.packages.urllib3.util.retry import Retry

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import sigma_rest

# Corp TLS inspection resets long connections intermittently -> retry POST/GET.
SESS = requests.Session()
_retry = Retry(total=5, connect=5, read=5, backoff_factor=1.5,
               status_forcelist=(429, 500, 502, 503, 504),
               allowed_methods=frozenset(["GET", "POST"]))
SESS.mount("https://", HTTPAdapter(max_retries=_retry))

CLIENT_ID = "ea0616ba-638b-4df5-95b9-636659ae5121"  # public Power BI Desktop client
PBI_BASE = "https://api.powerbi.com/v1.0/myorg"
FABRIC_BASE = "https://api.fabric.microsoft.com/v1"
BAND_MAX = int(os.environ.get("PBI_BAND_MAX", "45000"))  # under executeQueries' silent truncation ceiling


# ---- auth ----------------------------------------------------------------
# #347: resolve the authority + cache at CALL time so --tenant (set in main()
# after this module is imported) targets a guest/B2B tenant, with a per-tenant
# cache file so the guest token doesn't collide with the home token.
def _tenant():
    return os.environ.get("PBI_TENANT", "organizations")


def _authority():
    return "https://login.microsoftonline.com/" + _tenant()


def _cache_path():
    if os.environ.get("PBI_TOKEN_CACHE"):
        return os.environ["PBI_TOKEN_CACHE"]
    t = _tenant()
    return "/tmp/pbiauth/cache.bin" if t == "organizations" else f"/tmp/pbiauth/cache-{t}.bin"


def _app():
    path = _cache_path()
    cache = msal.SerializableTokenCache()
    if os.path.exists(path):
        cache.deserialize(open(path).read())
    app = msal.PublicClientApplication(CLIENT_ID, authority=_authority(), token_cache=cache)
    return app, cache, path

def get_tokens():
    app, cache, CACHE = _app()
    accts = app.get_accounts()
    def acq(scope):
        for a in accts:
            r = app.acquire_token_silent([scope], account=a)
            if r and "access_token" in r:
                return r["access_token"]
        return None
    pbi = acq("https://analysis.windows.net/powerbi/api/.default")
    fab = acq("https://api.fabric.microsoft.com/.default")
    if not pbi or not fab:
        flow = app.initiate_device_flow(scopes=["https://analysis.windows.net/powerbi/api/.default"])
        print(">>> LOGIN: " + flow["verification_uri"] + "  CODE " + flow["user_code"], file=sys.stderr)
        app.acquire_token_by_device_flow(flow)
        accts = app.get_accounts()
        pbi = acq("https://analysis.windows.net/powerbi/api/.default")
        fab = acq("https://api.fabric.microsoft.com/.default")
    if cache.has_state_changed:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        open(CACHE, "w").write(cache.serialize())
    if not (pbi and fab):
        sys.exit("could not acquire tokens")
    return pbi, fab

# ---- resolve -------------------------------------------------------------
def resolve_workspace(fab, name_or_id):
    r = SESS.get(f"{FABRIC_BASE}/workspaces", headers={"Authorization": f"Bearer {fab}"})
    r.raise_for_status()
    wss = r.json()["value"]
    if not name_or_id:  # default: My workspace (Personal)
        w = next((w for w in wss if w.get("type") == "Personal"), None)
        return w["id"], w["displayName"]
    for w in wss:
        if name_or_id in (w["id"], w.get("displayName")):
            return w["id"], w["displayName"]
    sys.exit(f"workspace not found: {name_or_id}")

def resolve_dataset(pbi, name_or_id, pbix=None):
    H = {"Authorization": f"Bearer {pbi}"}
    def find():
        r = SESS.get(f"{PBI_BASE}/datasets", headers=H); r.raise_for_status()
        for d in r.json()["value"]:
            if name_or_id in (d["id"], d["name"]):
                return d["id"]
        return None
    ds = find()
    if ds:
        return ds
    if pbix:
        disp = name_or_id if not name_or_id.count("-") == 4 else os.path.splitext(os.path.basename(pbix))[0]
        with open(pbix, "rb") as f:
            r = SESS.post(f"{PBI_BASE}/imports?datasetDisplayName={disp}&nameConflict=CreateOrOverwrite",
                              headers=H, files={"file": (os.path.basename(pbix), f)})
        r.raise_for_status()
        imp = r.json()["id"]
        for _ in range(120):
            time.sleep(5)
            st = SESS.get(f"{PBI_BASE}/imports/{imp}", headers=H).json()
            if st.get("importState") == "Succeeded":
                return st["datasets"][0]["id"]
            if st.get("importState") == "Failed":
                sys.exit(f"pbix import failed: {json.dumps(st)[:400]}")
        sys.exit("pbix import timed out")
    sys.exit(f"dataset not found and no --pbix given: {name_or_id}")

# ---- model structure via TMSL -------------------------------------------
def get_model(fab, ws, ds):
    H = {"Authorization": f"Bearer {fab}"}
    r = SESS.post(f"{FABRIC_BASE}/workspaces/{ws}/semanticModels/{ds}/getDefinition?format=TMSL", headers=H)
    if r.status_code == 200:
        res = r.json()
    elif r.status_code == 202:
        loc = r.headers["Location"]; res = None
        for _ in range(40):
            time.sleep(3)
            s = SESS.get(loc, headers=H); st = s.json().get("status")
            if st == "Succeeded":
                res = SESS.get(loc + "/result", headers=H).json(); break
            if st == "Failed":
                sys.exit(f"getDefinition LRO failed: {s.text[:300]}")
        if not res:
            sys.exit("getDefinition timed out")
    else:
        sys.exit(f"getDefinition {r.status_code}: {r.text[:300]}")
    for p in res["definition"]["parts"]:
        if p["path"].endswith("model.bim") or p["path"].endswith(".bim"):
            return json.loads(base64.b64decode(p["payload"]))
    sys.exit("no model.bim in TMSL definition")

AUTO_DATE = re.compile(r"^(DateTableTemplate_|LocalDateTable_)")
CALC_TYPES = {"calculated", "calculatedTableColumn"}
# TMSL dataType -> Snowflake type
SF_TYPE = {
    "int64": "NUMBER(38,0)", "double": "FLOAT", "decimal": "NUMBER(38,4)",
    "string": "VARCHAR", "boolean": "BOOLEAN", "dateTime": "TIMESTAMP_NTZ",
}

def clean_ident(name):
    """Table physical name — matches the PBI->Sigma converter's tableName.toUpperCase()
    (converter uses plain uppercase for tables), with non-alnum->_ for SQL safety."""
    s = re.sub(r"[^0-9A-Za-z]+", "_", name).strip("_").upper()
    if not s:
        s = "TBL"
    if s[0].isdigit():
        s = "_" + s
    return s

def sigma_physical_name(s):
    """Column physical name — MUST byte-match the converter's sigmaPhysicalName()
    (build/sigma-ids.js) so landed warehouse columns line up with the emitted DM
    column refs (no repoint remap). camelCase/acronym/digit boundaries -> snake_case;
    already-uppercase names pass through verbatim (e.g. 'DM' -> 'DM')."""
    r = (s or "").strip()
    if re.fullmatch(r"[A-Z0-9_]+", r):
        return r
    n = re.sub(r"[^A-Za-z0-9_\s]", " ", r)
    n = re.sub(r"([a-z])([A-Z])", r"\1_\2", n)
    n = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", n)
    n = re.sub(r"([A-Za-z])([0-9])", r"\1_\2", n)
    n = re.sub(r"([0-9])([A-Za-z])", r"\1_\2", n)
    out = "_".join(p for p in re.split(r"[_\s]+", n.upper()) if p)
    return out or "COL"

def plan_tables(model, only=None):
    """Return [{pbi_name, sf_name, cols:[{pbi,sf,dtype,sftype}]}] for landable tables."""
    out = []
    for t in model.get("model", {}).get("tables", []):
        name = t["name"]
        if AUTO_DATE.match(name):
            continue
        # skip calculated cols (DAX logic, recreated in Sigma) and binary/image
        # cols (unrepresentable in a warehouse AND they break EVALUATE <table>).
        stored = [c for c in t.get("columns", [])
                  if c.get("type") not in CALC_TYPES and c.get("dataType") != "binary"]
        if not stored:  # pure calculated table
            continue
        if only and name not in only:
            continue
        cols = [{"pbi": c["name"], "sf": sigma_physical_name(c["name"]),
                 "dtype": c.get("dataType", "string"),
                 "sftype": SF_TYPE.get(c.get("dataType", "string"), "VARCHAR")}
                for c in stored]
        # dedupe cleaned column names
        seen = {}
        for c in cols:
            base = c["sf"]; n = seen.get(base, 0)
            if n:
                c["sf"] = f"{base}_{n}"
            seen[base] = n + 1
        out.append({"pbi_name": name, "sf_name": clean_ident(name), "cols": cols,
                    "hidden": t.get("isHidden", False)})
    return out

# ---- extraction ----------------------------------------------------------
def dax(pbi, ds, q):
    r = SESS.post(f"{PBI_BASE}/datasets/{ds}/executeQueries",
                      headers={"Authorization": f"Bearer {pbi}"},
                      json={"queries": [{"query": q}], "serializerSettings": {"includeNulls": True}})
    if r.status_code != 200:
        raise RuntimeError(f"{r.status_code}: {r.text[:300]}")
    return r.json()["results"][0]["tables"][0]["rows"]

def strip_key(k):
    return k.split("[", 1)[1].rstrip("]") if "[" in k else k

def extract_table(pbi, ds, tbl, cols, limit=None):
    """Extract via explicit SELECTCOLUMNS projection (deterministic columns;
    avoids binary/image columns collapsing `EVALUATE <table>` to 1 row).
    Integer-key band pagination for tables over the truncation ceiling."""
    proj = ", ".join(f"\"{c['pbi']}\", '{tbl}'[{c['pbi']}]" for c in cols)
    def sc(table_expr):
        return dax(pbi, ds, f"EVALUATE SELECTCOLUMNS({table_expr}, {proj})")
    if limit:
        return sc(f"TOPN({int(limit)}, '{tbl}')")
    first = sc(f"'{tbl}'")
    if len(first) < BAND_MAX:
        return first
    # need pagination — pick the HIGHEST-cardinality int64 column as band key
    # (a low-cardinality key like MonthID won't split a fact table cleanly).
    int_cols = [c["pbi"] for c in cols if c["dtype"] == "int64"]
    if not int_cols:
        raise RuntimeError(f"{tbl}: >{BAND_MAX} rows and no int64 key to paginate; add a manual band")
    if len(int_cols) == 1:
        key = int_cols[0]
    else:
        card = dax(pbi, ds, "EVALUATE ROW(" +
                   ", ".join(f'"{c}", DISTINCTCOUNT(\'{tbl}\'[{c}])' for c in int_cols) + ")")[0]
        key = max(int_cols, key=lambda c: int(strip_val(card, c)))
    kq = f"'{tbl}'[{key}]"
    agg = dax(pbi, ds, f'EVALUATE ROW("mn", MINX(\'{tbl}\', {kq}), "mx", MAXX(\'{tbl}\', {kq}))')[0]
    mn, mx = int(strip_val(agg, "mn")), int(strip_val(agg, "mx"))
    print(f"[paginate] {tbl}: band key '{key}' range {mn}..{mx}", file=sys.stderr)
    rows, lo, step = [], mn, max(1, (mx - mn) // 20 + 1)
    while lo <= mx:
        hi = lo + step
        band = sc(f"FILTER('{tbl}', {kq} >= {lo} && {kq} < {hi})")
        if len(band) >= BAND_MAX:
            if step > 1:
                step = max(1, step // 2); continue
            raise RuntimeError(f"{tbl}: single-key band {key}={lo} has >={BAND_MAX} rows "
                               f"(would truncate). Needs a composite/manual band.")
        rows.extend(band); lo = hi
    return rows

def strip_val(row, name):
    for k, v in row.items():
        if strip_key(k) == name:
            return v
    raise KeyError(name)

def write_csv(path, cols, rows):
    keymap = None
    if rows:
        keymap = {strip_key(k): k for k in rows[0].keys()}
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([c["sf"] for c in cols])
        for r in rows:
            w.writerow([r.get(keymap.get(c["pbi"], c["pbi"])) if keymap else None for c in cols])

# ---- load.sql ------------------------------------------------------------
def gen_load_sql(db, schema, plan, outdir, grant_role="PUBLIC"):
    L = [f"CREATE SCHEMA IF NOT EXISTS {db}.{schema};",
         f"USE SCHEMA {db}.{schema};",
         "CREATE OR REPLACE FILE FORMAT PBI_IMPORT_CSV",
         "  TYPE=CSV SKIP_HEADER=1 FIELD_OPTIONALLY_ENCLOSED_BY='\"'",
         "  NULL_IF=('') EMPTY_FIELD_AS_NULL=TRUE TIMESTAMP_FORMAT='YYYY-MM-DD\"T\"HH24:MI:SS';", ""]
    for t in plan:
        cols = ",\n  ".join(f'{c["sf"]} {c["sftype"]}' for c in t["cols"])
        L.append(f'CREATE OR REPLACE TABLE {t["sf_name"]} (\n  {cols}\n);')
    L.append("")
    for t in plan:
        f = os.path.join(outdir, f'{t["sf_name"]}.csv')
        L.append(f'PUT file://{f} @%{t["sf_name"]} AUTO_COMPRESS=TRUE OVERWRITE=TRUE;')
    L.append("")
    for t in plan:
        L.append(f'COPY INTO {t["sf_name"]} FROM @%{t["sf_name"]} '
                 f'FILE_FORMAT=(FORMAT_NAME=PBI_IMPORT_CSV) ON_ERROR=ABORT_STATEMENT;')
    L.append("")
    # GRANTs so the Sigma connection's role can read the new tables
    # (new warehouse tables are invisible to Sigma until granted + conn-synced).
    if grant_role:
        L.append(f"GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {grant_role};")
        L.append(f"GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {grant_role};")
        L.append("")
    counts = "\nUNION ALL ".join(f"SELECT '{t['sf_name']}' t, COUNT(*) n FROM {t['sf_name']}" for t in plan)
    L.append(counts + ";")
    return "\n".join(L)

def sigma_sync(plan, db, schema, connection_id):
    """Register newly-landed tables with the Sigma connection so a DM POST can
    resolve them. Authentication and one 401 refresh/retry are owned by the
    co-located lib/sigma_rest.py. Sync remains optional: unavailable Sigma auth
    skips the step, and a per-table API error is reported without aborting the
    completed Snowflake landing."""
    try:
        sigma_rest.base_url()
        # Reuse a valid caller token. Known-stale tokens refresh proactively;
        # browser keychain state is preferred before client credentials.
        sigma_rest.auth_token()
    except (sigma_rest.SigmaError, SystemExit) as exc:
        detail = str(exc).splitlines()[0]
        print(f"[sigma-sync] Sigma auth unavailable — skipping sync: {detail}", file=sys.stderr)
        return

    for t in plan:
        try:
            sigma_rest.request(
                "post",
                f"/v2/connections/{connection_id}/sync",
                body=json.dumps({"path": [db, schema, t["sf_name"]]}),
            )
            status = "ok"
        except (sigma_rest.SigmaError, SystemExit) as exc:
            status = str(exc).splitlines()[0]
        print(f"[sigma-sync] {t['sf_name']} -> {status}", file=sys.stderr)

# ---- main ----------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True, help="dataset name or id")
    ap.add_argument("--workspace", default=None, help="workspace name or id (default: My workspace)")
    ap.add_argument("--pbix", default=None, help="upload this .pbix first if dataset absent")
    ap.add_argument("--target-db", required=True)
    ap.add_argument("--target-schema", required=True)
    ap.add_argument("--sf-conn", default="tj")
    ap.add_argument("--grant-role", default="PUBLIC", help="Snowflake role to GRANT SELECT (empty to skip)")
    ap.add_argument("--sigma-connection", default=None,
                    help="Sigma connection UUID — if set, auto-sync landed tables into Sigma after load "
                         "(uses a valid token/browser session or client-credential fallback)")
    ap.add_argument("--only", default=None, help="comma-separated PBI table names to include")
    ap.add_argument("--limit-rows", type=int, default=None, help="TOPN per table (cheap testing)")
    ap.add_argument("--dry-run", action="store_true", help="extract + gen SQL, do not execute in Snowflake")
    ap.add_argument("--tenant", default=None,
                    help="target tenant when the dataset lives in a DIFFERENT tenant than your home "
                         "tenant (guest/B2B). A raw tenant GUID, or a report URL with ctid=...")
    args = ap.parse_args()
    if args.tenant:  # #347: set before get_tokens() — authority/cache resolve at call time
        m = re.search(r"[?&]ctid=([0-9a-fA-F-]{36})", args.tenant)
        os.environ["PBI_TENANT"] = m.group(1) if m else args.tenant

    only = set(s.strip() for s in args.only.split(",")) if args.only else None
    pbi, fab = get_tokens()
    ws, wsname = resolve_workspace(fab, args.workspace)
    ds = resolve_dataset(pbi, args.dataset, args.pbix)
    print(f"[workspace] {wsname} ({ws})\n[dataset] {ds}", file=sys.stderr)

    model = get_model(fab, ws, ds)
    plan = plan_tables(model, only)
    outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", clean_ident(args.dataset).lower())
    os.makedirs(outdir, exist_ok=True)
    print(f"[plan] {len(plan)} landable tables -> {args.target_db}.{args.target_schema}", file=sys.stderr)
    for t in plan:
        print(f"   {t['pbi_name']} -> {t['sf_name']} ({len(t['cols'])} cols)"
              + ("  [hidden]" if t["hidden"] else ""), file=sys.stderr)

    manifest = {"dataset": ds, "workspace": ws, "target": f"{args.target_db}.{args.target_schema}", "tables": []}
    for t in plan:
        rows = extract_table(pbi, ds, t["pbi_name"], t["cols"], limit=args.limit_rows)
        csvpath = os.path.join(outdir, f'{t["sf_name"]}.csv')
        write_csv(csvpath, t["cols"], rows)
        print(f"[extract] {t['pbi_name']}: {len(rows)} rows -> {os.path.basename(csvpath)}", file=sys.stderr)
        manifest["tables"].append({
            "pbi_table": t["pbi_name"], "sf_table": f"{args.target_db}.{args.target_schema}.{t['sf_name']}",
            "rows": len(rows),
            "columns": [{"pbi": c["pbi"], "sf": c["sf"], "sf_type": c["sftype"]} for c in t["cols"]],
        })

    sql = gen_load_sql(args.target_db, args.target_schema, plan, outdir, args.grant_role)
    sqlpath = os.path.join(outdir, "load.sql")
    open(sqlpath, "w").write(sql)
    open(os.path.join(outdir, "manifest.json"), "w").write(json.dumps(manifest, indent=2))
    print(f"[sql] {sqlpath}\n[manifest] {os.path.join(outdir,'manifest.json')}", file=sys.stderr)

    if args.dry_run:
        print("[dry-run] skipping Snowflake load", file=sys.stderr)
        return
    print(f"[load] executing via snow sql -c {args.sf_conn}", file=sys.stderr)
    r = subprocess.run(["snow", "sql", "-c", args.sf_conn, "-f", sqlpath], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        sys.stderr.write(r.stderr); sys.exit(f"snow sql failed ({r.returncode})")

    if args.sigma_connection:
        print("[sigma-sync] registering tables with Sigma connection", file=sys.stderr)
        sigma_sync(plan, args.target_db, args.target_schema, args.sigma_connection)

if __name__ == "__main__":
    main()
