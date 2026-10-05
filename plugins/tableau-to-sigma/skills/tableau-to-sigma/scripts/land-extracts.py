#!/usr/bin/env python3
"""land-extracts.py — land embedded Tableau extracts (.twbx hyper payloads) into Snowflake.

When every datasource in a workbook federates over an EMBEDDED payload
(excel-direct / textscan / hyper / ogrdirect — no live warehouse connection),
the Sigma data model has nothing to point at until the frozen extract itself is
landed. This script reads every table of every .hyper in the .twbx payload via
the Tableau Hyper API, maps hyper files to datasources (by federated-name
prefix against the .twb), sanitizes names to UPPER_SNAKE, writes typed tables
via snowflake-connector write_pandas, verifies zero-loss row counts, optionally
syncs each table into the Sigma catalog, and emits landing-manifest.json
(table + column lineage) that Phase 3 consumes for path remapping.

TYPE DISCIPLINE (the bugs from a 2026-07 10-workbook live migration, fixed at READ time):
  * hyper DATE          -> datetime.date          (lands DATE)
  * hyper TIMESTAMP(_TZ)-> pandas datetime64      (lands TIMESTAMP_NTZ/_TZ)
  * hyper GEOGRAPHY     -> CAST(col AS TEXT) in the SELECT (WKT string)
  * hyper INTERVAL      -> per-VALUE str()        (no pandas/SF interval type)
  * everything else     -> native, UNTOUCHED
  Never astype(str) a whole object column: that turns Python None into the
  string 'None'. Python None must land as SQL NULL — while genuine 'None'
  STRING category values (Hospital-ER "no referral", eco-certification levels)
  pass through byte-identical. Native columns are never rewritten, so both
  contracts hold by construction.

EXACT-PARITY CONSEQUENCE: the landed tables are byte-identical to the frozen
extract Tableau rendered from, so downstream parity checks run in EXACT mode —
drift tolerance must be refused, not offered. See refs/extract-landing.md.

Usage (one workbook):
  python3 scripts/land-extracts.py \
    --twbx /tmp/wb/workbook-content.twbx --twb /tmp/wb/workbook-content.twb \
    --db <DATABASE> --schema <LANDING_SCHEMA> --prefix ER \
    --account <SNOWFLAKE_ACCOUNT> --user <SERVICE_USER> \
    --key-path <path/to/rsa_key.p8> \
    --role CLAUDE_BUILDER_ROLE --warehouse COMPUTE_WH \
    --sigma-connection-id <uuid> --manifest-out /tmp/wb/landing-manifest.json

--twbx also accepts a directory: either a directory of .twbx files, or a
directory of per-workbook dirs (each holding a .twb + extracted .hyper
payloads, e.g. a discovery workdir). --dry-run parses + plans (names, types,
column maps) without connecting to Snowflake.

Dependencies (import errors print a remediation line, not a stack trace):
  pip install tableauhyperapi 'pandas>=2.0,<3' pyarrow snowflake-connector-python
  # pandas is pinned <3 and pyarrow is explicit: snowflake-connector's
  # write_pandas needs pyarrow and does not yet support pandas 3.x (an
  # unpinned `pip install pandas` grabs 3.x and write_pandas fails to import).
The pure functions (sanitization, type mapping, manifest building) are
importable and testable WITHOUT those installed — see test_land_extracts.py.
"""
import argparse
import glob
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from collections import OrderedDict
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import sigma_rest  # noqa: E402

PIP_HINT = "pip install tableauhyperapi 'pandas>=2.0,<3' pyarrow snowflake-connector-python"

# ---------------------------------------------------------------------------
# Pure functions — no third-party imports; unit-tested offline.
# ---------------------------------------------------------------------------

GUID_RE = re.compile(r"_[0-9A-F]{32}$", re.I)
# Cleaned hyper table names that say nothing about the data — such tables are
# named after the datasource caption instead. Token-wise: "Extract
# (Extract.Extract)" cleans to EXTRACT_EXTRACT_EXTRACT which is just as generic
# as EXTRACT (observed in a live migration's radar-chart hyper).
GENERIC_TOKENS = {"EXTRACT", "SHEET1", "SHEET", "DATA", "MIGRATED"}


def clean_ident(s, upper=True):
    """Sanitize an identifier: strip a _<32-hex-GUID> suffix, non-alnum -> _,
    collapse runs, guard leading digits (C_ prefix), uppercase."""
    s = GUID_RE.sub("", s or "")
    s = re.sub(r"[^0-9A-Za-z]+", "_", s).strip("_")
    s = re.sub(r"_+", "_", s)
    if not s:
        s = "COL"
    if s[0].isdigit():
        s = "C_" + s
    return s.upper() if upper else s


def is_generic_table_name(cleaned):
    """True when a CLEANED hyper table name carries no meaning (EXTRACT,
    SHEET1, EXTRACT_EXTRACT_EXTRACT, DATA...) and the datasource caption should
    name the landed table instead."""
    tokens = [t for t in cleaned.split("_") if t]
    return bool(tokens) and all(t in GENERIC_TOKENS or t.isdigit() for t in tokens)


def sf_table_name(hyper_table, ds_caption, prefix, used_names):
    """Landed table name: meaningful hyper table -> PREFIX_TABLE; generic
    (EXTRACT/SHEET1/...) -> PREFIX_<datasource-caption-clean>. Deduped with _2,
    _3... suffixes against used_names (mutated)."""
    tclean = clean_ident(hyper_table)
    cap_clean = clean_ident(str(ds_caption))[:40]
    base = f"{prefix}_{cap_clean}" if is_generic_table_name(tclean) else f"{prefix}_{tclean}"
    name, n = base, 2
    while name in used_names:
        name = f"{base}_{n}"
        n += 1
    used_names.add(name)
    return name


def plan_column(type_tag_name):
    """Map a hyper column type-tag NAME to a landing action:
      'geography-cast' -> CAST(col AS TEXT) in the SELECT (WKT)
      'date'           -> per-value hyper Date -> datetime.date
      'timestamp'      -> per-value hyper Timestamp -> datetime, then datetime64
      'stringify'      -> per-VALUE str() (INTERVAL; None stays None)
      'native'         -> untouched (None -> NULL; 'None' strings preserved)
    """
    t = (type_tag_name or "").upper()
    if t == "GEOGRAPHY":
        return "geography-cast"
    if t == "DATE":
        return "date"
    if t in ("TIMESTAMP", "TIMESTAMP_TZ"):
        return "timestamp"
    if t == "INTERVAL":
        return "stringify"
    return "native"


def build_column_plan(columns):
    """columns: [(orig_name, type_tag_name)] ->
    [{'orig','landed','action'}], landed names cleaned + deduped (_2 suffixes)."""
    plan, used = [], set()
    for orig, tag in columns:
        landed = clean_ident(orig)
        base, k = landed, 2
        while landed in used:
            landed = f"{base}_{k}"
            k += 1
        used.add(landed)
        plan.append({"orig": orig, "landed": landed, "action": plan_column(tag)})
    return plan


# Per-VALUE converters. None ALWAYS maps to None (-> SQL NULL); this is the
# read-time fix for the astype(str) bug that landed 'None' strings and TEXT
# dates in the live run.
def to_py_date(v):
    if v is None:
        return None
    return v.to_date() if hasattr(v, "to_date") else v


def to_py_datetime(v):
    if v is None:
        return None
    return v.to_datetime() if hasattr(v, "to_datetime") else v


def to_str_or_none(v):
    return None if v is None else str(v)


def apply_column_actions(df, plan, pd=None):
    """Apply per-column converters to an object-dtype DataFrame IN PLACE.
    'native' and 'geography-cast' columns are never rewritten — Python None
    stays None (lands NULL) and genuine 'None' category strings pass through
    byte-identical."""
    if pd is None:
        import pandas as pd  # caller context always has it; tests may inject
    for entry in plan:
        c, action = entry["landed"], entry["action"]
        if action == "date":
            df[c] = df[c].map(to_py_date)
        elif action == "timestamp":
            converted = df[c].map(to_py_datetime)
            try:
                df[c] = pd.to_datetime(converted)
            except Exception:
                # mixed-tz or exotic values: keep python datetimes; write_pandas
                # with use_logical_type still lands them as TIMESTAMP.
                df[c] = converted
        elif action == "stringify":
            df[c] = df[c].map(to_str_or_none)
    return df


def ds_captions(twb_path):
    """datasource name -> caption map from a .twb (skips Parameters)."""
    root = ET.parse(twb_path).getroot()
    out = OrderedDict()
    for ds in root.findall("./datasources/datasource"):
        n = ds.get("name", "")
        if n == "Parameters":
            continue
        out[n] = ds.get("caption") or n
    return out


def ds_hyper_map(twb_path):
    """Map each embedded .hyper basename -> (datasource name, caption), read from
    the federated named-connection's <connection ... dbname='...hyper'>. This is
    the RELIABLE hyper→datasource link: the extract .hyper file is GUID-named
    (DATAENGINE_0tb9...) and shares no tokens with the caption ("Region"), so
    match_ds' filename-substring heuristic falls back to the GUID stem — which is
    exactly the "tables landed under GUID names" failure. dbname carries the real
    .hyper filename, so this recovers the caption. Skips the Parameters
    datasource; returns {} on any parse error (caller falls back to match_ds)."""
    out = {}
    try:
        root = ET.parse(twb_path).getroot()
    except Exception:
        return out
    for ds in root.findall("./datasources/datasource"):
        name = ds.get("name", "")
        if name == "Parameters":
            continue
        caption = ds.get("caption") or name
        for conn in ds.findall(".//connection[@dbname]"):
            base = os.path.basename(conn.get("dbname") or "")
            if base.lower().endswith(".hyper"):
                out.setdefault(base, (name, caption))
    return out


def match_ds(hyper_file, captions):
    """Match a hyper filename to a datasource (name, caption) by normalized
    prefix/substring; falls back to (basename, basename)."""
    base = os.path.basename(hyper_file).rsplit(".hyper", 1)[0]
    norm = re.sub(r"[^0-9a-z]", "", base.lower())
    best = None
    for name, cap in captions.items():
        for cand in (name, cap):
            c = re.sub(r"[^0-9a-z]", "", str(cand).lower())
            if c and (c.startswith(norm) or norm.startswith(c) or c in norm or norm in c):
                if best is None or len(c) > best[2]:
                    best = (name, cap, len(c))
    return (best[0], best[1]) if best else (base, base)


def manifest_entry(slug, ds_name, caption, hyper_path, hyper_table, sf_fqn, rows, colmap):
    """One landing-manifest.json entry — the exact shape Phase 3 consumes."""
    return {
        "slug": slug,
        "datasource": ds_name,
        "caption": str(caption),
        "hyper": os.path.basename(hyper_path),
        "hyper_table": hyper_table,
        "sf_table": sf_fqn,
        "rows": rows,
        "columns": colmap,
    }


def discover_workbooks(path):
    """Resolve --twbx into workbook units: [{'slug','twbx','root'}].
    Accepts one .twbx file, a directory of .twbx files (direct or one level
    down), a single extracted workbook dir (has a .twb at top level), or a
    directory of extracted workbook dirs."""
    p = os.path.abspath(os.path.expanduser(path))
    if os.path.isfile(p):
        if not p.lower().endswith(".twbx"):
            sys.exit(f"--twbx: {path} is not a .twbx file (or a directory)")
        return [{"slug": os.path.splitext(os.path.basename(p))[0], "twbx": p, "root": None}]
    if not os.path.isdir(p):
        sys.exit(f"--twbx: {path} not found")
    twbxs = sorted(glob.glob(os.path.join(p, "*.twbx"))) + \
        sorted(glob.glob(os.path.join(p, "*", "*.twbx")))
    if twbxs:
        return [{"slug": os.path.splitext(os.path.basename(t))[0], "twbx": t, "root": None}
                for t in twbxs]
    if glob.glob(os.path.join(p, "*.twb")):  # a single extracted workbook dir
        return [{"slug": os.path.basename(p.rstrip(os.sep)), "twbx": None, "root": p}]
    units = []
    for d in sorted(os.listdir(p)):
        sub = os.path.join(p, d)
        if os.path.isdir(sub) and (glob.glob(os.path.join(sub, "**", "*.hyper"), recursive=True)
                                   or glob.glob(os.path.join(sub, "*.twb"))):
            units.append({"slug": d, "twbx": None, "root": sub})
    if units:
        return units
    if glob.glob(os.path.join(p, "**", "*.hyper"), recursive=True):
        return [{"slug": os.path.basename(p.rstrip(os.sep)), "twbx": None, "root": p}]
    sys.exit(f"--twbx: no .twbx / .twb / .hyper payloads found under {path}")


def load_neutral_env():
    """Parse ~/.sigma-migration/env (`export KEY='value'` lines) — the
    agent-neutral cred file setup.rb writes; mirrors get-token.sh's fallback."""
    out = {}
    path = os.path.expanduser("~/.sigma-migration/env")
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.strip())
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        out[k] = v
    return out


def env_or_neutral(key):
    return os.environ.get(key) or load_neutral_env().get(key)


# ---------------------------------------------------------------------------
# Guarded third-party imports — a clear remediation line, never a stack trace.
# ---------------------------------------------------------------------------

def _require(module, why):
    try:
        return __import__(module)
    except ImportError:
        sys.exit(f"FATAL: python module '{module}' is not installed ({why}).\n"
                 f"  Fix:  {PIP_HINT}")


def _require_hyper():
    _require("tableauhyperapi", "reads the .hyper extract tables")
    from tableauhyperapi import Connection, HyperProcess, Telemetry
    return HyperProcess, Connection, Telemetry


def _require_pandas():
    return _require("pandas", "builds the typed DataFrames write_pandas lands")


def _require_snowflake():
    _require("snowflake.connector", "writes the landed tables")
    import snowflake.connector
    from snowflake.connector.pandas_tools import write_pandas
    return snowflake.connector, write_pandas


# ---------------------------------------------------------------------------
# Snowflake + Sigma I/O
# ---------------------------------------------------------------------------

def load_private_key(key_path):
    """Load (and validate) the key-pair BEFORE any long-running work.

    Field-caught failure mode: a passphrase-ENCRYPTED key with no
    SNOWFLAKE_KEY_PASSPHRASE set only exploded ~10 minutes into the run, deep
    inside the landing, with a raw cryptography TypeError — and agents then
    (correctly) got blocked trying to hunt for a passphrase in credential
    stores. Fail FAST with the remediation instead. Called as a preflight at
    argument-parse time and again by connect_snowflake.
    """
    _require("cryptography", "loads the key-pair for --key-path auth "
                             "(ships with snowflake-connector-python)")
    from cryptography.hazmat.primitives import serialization
    passphrase = os.environ.get("SNOWFLAKE_KEY_PASSPHRASE")
    with open(os.path.expanduser(key_path), "rb") as f:
        pem = f.read()
    try:
        return serialization.load_pem_private_key(
            pem, password=passphrase.encode() if passphrase else None)
    except TypeError:
        sys.exit(
            f"FATAL: the private key at {key_path} is PASSPHRASE-ENCRYPTED and "
            "SNOWFLAKE_KEY_PASSPHRASE is not set.\n"
            "  ASK THE USER for the passphrase (or for an unencrypted service key) — "
            "do NOT scan the machine, env files, or keychain for one.\n"
            "  Then: export SNOWFLAKE_KEY_PASSPHRASE='<passphrase>' and re-run.")
    except ValueError as e:
        sys.exit(f"FATAL: could not parse the private key at {key_path}: {e}\n"
                 "  Expected a PEM (PKCS#8) RSA key — regenerate or point --key-path at the right file.")


def connect_snowflake(args):
    connector, _ = _require_snowflake()
    kw = dict(account=args.account, user=args.user, login_timeout=30)
    if args.role:
        kw["role"] = args.role
    if args.warehouse:
        kw["warehouse"] = args.warehouse
    if args.key_path:
        from cryptography.hazmat.primitives import serialization
        priv = load_private_key(args.key_path)
        kw["private_key"] = priv.private_bytes(
            serialization.Encoding.DER,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption())
    else:
        pw = os.environ.get("SNOWFLAKE_PASSWORD")
        if not pw:
            sys.exit("FATAL: no --key-path given and SNOWFLAKE_PASSWORD is not set.\n"
                     "  Pass --key-path <rsa_key.p8> (key-pair auth) or export SNOWFLAKE_PASSWORD.")
        kw["password"] = pw
    return connector.connect(**kw)


def sigma_sync_tables(connection_id, tables, db, schema):
    """POST /v2/connections/{id}/sync {"path":[DB,SCHEMA,TABLE]} per table —
    this endpoint WORKS (verified in a 10-workbook live migration: 48/48 tables visible
    immediately, no UI 'refresh schema'). Authentication and the single 401
    refresh/retry are owned by scripts/lib/sigma_rest.py. Returns (ok, fail)
    counts."""
    try:
        sigma_rest.base_url()
        # Fail before reporting every table as an independent sync failure when
        # no provider route is usable. Unknown-age caller/browser tokens remain
        # untouched; known-stale tokens refresh through the provider.
        sigma_rest.auth_token()
    except (sigma_rest.SigmaError, SystemExit) as exc:
        sys.exit(
            "FATAL: --sigma-connection-id needs usable Sigma authentication "
            f"({exc}).\n"
            "  Run scripts/browser-login.sh once, or configure SIGMA_BASE_URL / "
            "SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET for unattended auth."
        )

    ok = fail = 0
    for tbl in tables:
        path = f"/v2/connections/{connection_id}/sync"
        try:
            sigma_rest.request(
                "post",
                path,
                body=json.dumps({"path": [db, schema, tbl]}),
            )
            good, status = True, "ok"
        except sigma_rest.SigmaError as exc:
            good, status = False, str(exc).splitlines()[0]
        ok, fail = ok + good, fail + (not good)
        print(f"SYNC {db}.{schema}.{tbl} -> {status}", flush=True)
    return ok, fail


# ---------------------------------------------------------------------------
# Landing
# ---------------------------------------------------------------------------

def find_twb(root):
    cands = sorted(glob.glob(os.path.join(root, "*.twb"))) or \
        sorted(glob.glob(os.path.join(root, "**", "*.twb"), recursive=True))
    return cands[0] if cands else None


def land_all(args):
    HyperProcess, Connection, Telemetry = _require_hyper()
    units = discover_workbooks(args.twbx)
    manifest, used_names = [], set()
    synced_tables = []

    sf = cur = None
    pd = write_pandas = None
    if not args.dry_run:
        pd = _require_pandas()
        _, write_pandas = _require_snowflake()
        sf = connect_snowflake(args)
        cur = sf.cursor()
        try:
            cur.execute(f"CREATE SCHEMA IF NOT EXISTS {args.db}.{args.schema}")
        except Exception as e:  # pre-provisioned schema without CREATE priv is fine
            print(f"NOTE: CREATE SCHEMA skipped ({str(e).splitlines()[0]})", flush=True)
        cur.execute(f"USE SCHEMA {args.db}.{args.schema}")

    with HyperProcess(telemetry=Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU) as hp, \
            tempfile.TemporaryDirectory(prefix="land-extracts-") as scratch:
        for i, unit in enumerate(units):
            root = unit["root"]
            if unit["twbx"]:
                root = os.path.join(scratch, f"wb{i}")
                with zipfile.ZipFile(unit["twbx"]) as z:
                    z.extractall(root)
            twb = args.twb if (args.twb and len(units) == 1) else find_twb(root)
            captions = ds_captions(twb) if twb else OrderedDict()
            hyper_by_name = ds_hyper_map(twb) if twb else {}
            if not twb:
                print(f"WARN {unit['slug']}: no .twb found — datasource captions "
                      "unavailable, falling back to hyper filenames", flush=True)
            hypers = sorted(glob.glob(os.path.join(root, "**", "*.hyper"), recursive=True))
            if not hypers:
                print(f"WARN {unit['slug']}: no .hyper payloads — was the .twbx "
                      "downloaded with ?includeExtract=true?", flush=True)
                continue
            prefix = args.prefix or clean_ident(unit["slug"])[:16]

            for hf in hypers:
                # Reliable dbname→caption map first (GUID-named hypers defeat the
                # filename heuristic); fall back to token-matching only on a miss.
                mapped = hyper_by_name.get(os.path.basename(hf))
                ds_name, ds_cap = mapped if mapped else match_ds(hf, captions)
                with Connection(hp.endpoint, hf) as hc:
                    for sname in hc.catalog.get_schema_names():
                        for tname in hc.catalog.get_table_names(sname):
                            tdef = hc.catalog.get_table_definition(tname)
                            raw_table = tname.name.unescaped
                            plan = build_column_plan(
                                [(c.name.unescaped, c.type.tag.name) for c in tdef.columns])
                            tbl = sf_table_name(raw_table, ds_cap, prefix, used_names)
                            fqn = f"{args.db}.{args.schema}.{tbl}"
                            colmap = OrderedDict((e["orig"], e["landed"]) for e in plan)

                            if args.dry_run:
                                print(f"PLAN {unit['slug']} :: {ds_cap} :: {raw_table} "
                                      f"-> {tbl} ({len(plan)} cols)", flush=True)
                                manifest.append(manifest_entry(
                                    unit["slug"], ds_name, ds_cap, hf, raw_table,
                                    fqn, None, colmap))
                                continue

                            sel = [f"CAST({c.name} AS TEXT)"
                                   if e["action"] == "geography-cast" else str(c.name)
                                   for c, e in zip(tdef.columns, plan)]
                            rows = hc.execute_list_query(
                                f'SELECT {", ".join(sel)} FROM {tname}')
                            df = pd.DataFrame(rows, columns=[e["landed"] for e in plan])
                            apply_column_actions(df, plan, pd)
                            nrows = len(df)
                            write_pandas(sf, df, tbl, database=args.db,
                                         schema=args.schema, auto_create_table=True,
                                         overwrite=True, use_logical_type=True)

                            # Zero-loss verification: the landed count must equal
                            # the DataFrame count, else abort loudly — a silent
                            # short-load poisons every parity check downstream.
                            cur.execute(f"SELECT COUNT(*) FROM {fqn}")
                            landed = cur.fetchone()[0]
                            if landed != nrows:
                                sys.exit(f"FATAL: zero-loss check failed for {fqn}: "
                                         f"extract has {nrows} rows, landed {landed}. "
                                         "Aborting — do NOT proceed to parity with a short table.")

                            manifest.append(manifest_entry(
                                unit["slug"], ds_name, ds_cap, hf, raw_table,
                                fqn, nrows, colmap))
                            synced_tables.append(tbl)
                            print(f"LANDED {unit['slug']} :: {ds_cap} :: {raw_table} "
                                  f"-> {tbl} ({nrows} rows, {len(plan)} cols)", flush=True)

    if sf:
        sf.close()

    manifest_out = args.manifest_out or "landing-manifest.json"
    if args.dry_run and not args.manifest_out:
        print(f"DRY-RUN: {len(manifest)} table(s) planned, nothing written "
              "(pass --manifest-out to save the plan)", flush=True)
    else:
        with open(manifest_out, "w") as f:
            json.dump(manifest, f, indent=1)
        print(f"MANIFEST WRITTEN {manifest_out} ({len(manifest)} tables)", flush=True)

    if args.sigma_connection_id and not args.dry_run:
        ok, fail = sigma_sync_tables(args.sigma_connection_id, synced_tables,
                                     args.db, args.schema)
        print(f"SIGMA SYNC: {ok} ok, {fail} failed", flush=True)
        if fail:
            print("  (failed tables stay invisible to Sigma until synced — retry or "
                  "sync from the connection page)", flush=True)


def parse_args(argv=None):
    ap = argparse.ArgumentParser(
        description="Land embedded Tableau extracts (.twbx hyper payloads) into "
                    "Snowflake, typed correctly at read time; emit landing-manifest.json.")
    ap.add_argument("--twbx", required=True,
                    help=".twbx file, directory of .twbx files, or directory of "
                         "extracted workbook dirs")
    ap.add_argument("--twb", default=None,
                    help="explicit .twb for datasource captions (single-workbook runs; "
                         "default: the .twb inside the payload)")
    ap.add_argument("--db", required=True, help="target Snowflake database")
    ap.add_argument("--schema", required=True, help="target Snowflake schema")
    ap.add_argument("--prefix", default=None,
                    help="landed-table prefix (default: derived from the workbook slug)")
    ap.add_argument("--account", default=None, help="Snowflake account identifier")
    ap.add_argument("--user", default=None, help="Snowflake user")
    ap.add_argument("--key-path", default=None,
                    help="PEM private key (.p8) for key-pair auth; "
                         "SNOWFLAKE_KEY_PASSPHRASE env if encrypted. Omit to use "
                         "SNOWFLAKE_PASSWORD env instead")
    ap.add_argument("--role", default=None, help="Snowflake role")
    ap.add_argument("--warehouse", default=None, help="Snowflake warehouse")
    ap.add_argument("--sigma-connection-id", default=None,
                    help="Sigma connection UUID — sync each landed table into the "
                         "catalog (uses browser-first Sigma auth with client-credential "
                         "fallback through scripts/lib/sigma_rest.py)")
    ap.add_argument("--manifest-out", default=None,
                    help="landing-manifest.json path (default: ./landing-manifest.json)")
    ap.add_argument("--dry-run", action="store_true",
                    help="parse + plan (names, types, column maps) without writing "
                         "anything to Snowflake")
    args = ap.parse_args(argv)
    # v5.2.1: connection identity falls back to env / ~/.sigma-migration/env
    # (same pattern as the SIGMA_* creds) — the orchestrator's auto-landing
    # can't know the operator's Snowflake identity, and a hard argparse error
    # made auto-land unconditionally dead (review-caught). Explicit flags win.
    # v5.3: the prefix is spliced into an UNQUOTED table FQN — sanitize to
    # UPPER_SNAKE here so a raw caption with spaces can't break the COUNT(*)
    # (round-5 field-caught on a manual invocation).
    if args.prefix:
        args.prefix = re.sub(r"[^A-Za-z0-9]+", "_", args.prefix).strip("_").upper()
        if re.match(r"^\d", args.prefix):  # unquoted identifiers can't lead with a digit
            args.prefix = "T_" + args.prefix
    args.account = args.account or env_or_neutral("SNOWFLAKE_ACCOUNT")
    args.user = args.user or env_or_neutral("SNOWFLAKE_USER")
    args.key_path = args.key_path or env_or_neutral("SNOWFLAKE_KEY_PATH")
    args.role = args.role or env_or_neutral("SNOWFLAKE_ROLE")
    args.warehouse = args.warehouse or env_or_neutral("SNOWFLAKE_WAREHOUSE")
    if not args.dry_run:
        missing = [f"--{k}" for k in ("account", "user") if not getattr(args, k)]
        if missing:
            ap.error(f"{', '.join(missing)} required (flag, env, or ~/.sigma-migration/env "
                     f"SNOWFLAKE_ACCOUNT/SNOWFLAKE_USER; or use --dry-run to plan only)")
        # Key PREFLIGHT: validate the key loads NOW (seconds), not after the
        # hyper extraction has run for minutes (see load_private_key).
        if args.key_path:
            load_private_key(args.key_path)
    return args


def main(argv=None):
    land_all(parse_args(argv))


if __name__ == "__main__":
    main()
