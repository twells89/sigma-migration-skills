#!/usr/bin/env python3
"""Phase 1-3 inventory extractor for the powerbi-assessment skill.

READ-ONLY. Surveys a Power BI / Fabric tenant (what the signed-in user can
reach) and writes raw JSON the Ruby renderers consume:

  <out>/inventory.json   — environment + per-model + per-report metadata
  <out>/raw-tmsl/<ws>__<model>.tmsl     — decoded TMSL for each semantic model
  <out>/raw-pbir/<ws>__<report>.json    — decoded PBIR report.json for each report

Auth is the no-Entra-app device-code recipe from
powerbi-to-sigma/refs/connection.md — well-known PowerBI Desktop public client,
truststore.inject_into_ssl() (mandatory on corp TLS), persistent token cache at
/tmp/pbiauth/cache.bin. acquire_token_silent first; only falls back to device
flow if the cache is cold (and --no-interactive forbids that).

The Fabric-audience token covers /v1 Fabric calls. The Power BI REST audience
(refresh history) needs a *second* token at analysis.windows.net scope; we
acquire it lazily and degrade gracefully (refresh history = null) if it 401s.

Usage:
  /tmp/pbiauth/bin/python scripts/fabric-inventory.py --out /tmp/pbi-assessment-<tenant>
  ... [--no-interactive]  [--workspaces id1,id2]  [--limit-models N]
"""

import truststore; truststore.inject_into_ssl()  # MANDATORY — corp root CA via macOS keychain
import sys, os, json, time, base64, argparse, re, atexit
import requests
import msal

CACHE = "/tmp/pbiauth/cache.bin"
CLIENT_ID = "ea0616ba-638b-4df5-95b9-636659ae5121"  # well-known PowerBI Desktop public client
AUTHORITY = "https://login.microsoftonline.com/organizations"
FABRIC_SCOPE = ["https://api.fabric.microsoft.com/.default"]
PBI_SCOPE = ["https://analysis.windows.net/powerbi/api/.default"]
FABRIC_BASE = "https://api.fabric.microsoft.com/v1"
PBI_BASE = "https://api.powerbi.com/v1.0/myorg"

_cache = msal.SerializableTokenCache()
if os.path.exists(CACHE):
    _cache.deserialize(open(CACHE).read())
atexit.register(lambda: open(CACHE, "w").write(_cache.serialize()) if _cache.has_state_changed else None)
_app = msal.PublicClientApplication(CLIENT_ID, authority=AUTHORITY, token_cache=_cache)


def _jwt_aud(tok):
    try:
        p = tok.split(".")[1]; p += "=" * (-len(p) % 4)
        return json.loads(base64.urlsafe_b64decode(p)).get("aud")
    except Exception:
        return "?"


def get_token(scopes, interactive=True, label=""):
    """acquire_token_silent first (works headless); device flow only if cold."""
    for acct in _app.get_accounts():
        s = _app.acquire_token_silent(scopes, account=acct)
        if s and "access_token" in s:
            return s["access_token"]
    if not interactive:
        return None
    flow = _app.initiate_device_flow(scopes=scopes)
    if "user_code" not in flow:
        return None
    print("=" * 60, file=sys.stderr)
    print(f"SIGN IN ({label or scopes[0]})", file=sys.stderr)
    print(f">>> {flow['verification_uri']}  code: {flow['user_code']}", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    res = _app.acquire_token_by_device_flow(flow)
    return res.get("access_token")


def fab(tok, path, method="GET"):
    url = FABRIC_BASE + path
    fn = requests.post if method == "POST" else requests.get
    return fn(url, headers={"Authorization": f"Bearer {tok}"})


def get_definition_tmsl(tok, ws, model_id):
    """POST getDefinition?format=TMSL, follow the 202 LRO, return decoded model TMSL JSON."""
    url = (f"{FABRIC_BASE}/workspaces/{ws}/semanticModels/{model_id}"
           f"/getDefinition?format=TMSL")
    pr = requests.post(url, headers={"Authorization": f"Bearer {tok}"})
    body = None
    if pr.status_code == 200:
        body = pr.json()
    elif pr.status_code == 202:
        op = pr.headers.get("Location")
        for _ in range(30):
            time.sleep(int(pr.headers.get("Retry-After", "2")))
            sr = requests.get(op, headers={"Authorization": f"Bearer {tok}"})
            st = sr.json().get("status")
            if st == "Succeeded":
                rr = requests.get(op + "/result", headers={"Authorization": f"Bearer {tok}"})
                body = rr.json(); break
            if st in ("Failed", "Undetermined"):
                return None
    else:
        return None
    if not body:
        return None
    for p in body.get("definition", {}).get("parts", []):
        if p["path"].endswith(".tmsl") or p["path"].endswith(".bim") or "model" in p["path"]:
            try:
                return json.loads(base64.b64decode(p["payload"]).decode("utf-8", "replace"))
            except Exception:
                continue
    # fall back to first part
    parts = body.get("definition", {}).get("parts", [])
    if parts:
        try:
            return json.loads(base64.b64decode(parts[0]["payload"]).decode("utf-8", "replace"))
        except Exception:
            return None
    return None


def get_report_pbir(tok, ws, report_id):
    """POST getDefinition (PBIR) for a report; return the report.json definition dict."""
    url = f"{FABRIC_BASE}/workspaces/{ws}/reports/{report_id}/getDefinition"
    pr = requests.post(url, headers={"Authorization": f"Bearer {tok}"})
    body = None
    if pr.status_code == 200:
        body = pr.json()
    elif pr.status_code == 202:
        op = pr.headers.get("Location")
        for _ in range(30):
            time.sleep(int(pr.headers.get("Retry-After", "2")))
            sr = requests.get(op, headers={"Authorization": f"Bearer {tok}"})
            st = sr.json().get("status")
            if st == "Succeeded":
                rr = requests.get(op + "/result", headers={"Authorization": f"Bearer {tok}"})
                body = rr.json(); break
            if st in ("Failed", "Undetermined"):
                return None
    else:
        return None
    if not body:
        return None
    parts = {}
    for p in body.get("definition", {}).get("parts", []):
        try:
            parts[p["path"]] = base64.b64decode(p["payload"]).decode("utf-8", "replace")
        except Exception:
            pass
    return parts


# ----------------------------------------------------------------------------
# TMSL complexity analysis
# ----------------------------------------------------------------------------

# DAX function classification → coverage bucket. From research/dax-to-sigma-coverage.md
# and fixtures/MANIFEST.md. a=mechanical, b=restructuring, c=no-equivalent.
DAX_BUCKET_A = [
    "SUM", "AVERAGE", "COUNT", "COUNTA", "MIN", "MAX", "DISTINCTCOUNT",
    "COUNTROWS", "SUMX", "AVERAGEX", "MAXX", "MINX", "DIVIDE", "IF", "SWITCH",
    "RELATED", "LOOKUPVALUE", "SAMEPERIODLASTYEAR", "DATEADD", "DATEDIFF",
    "TODAY", "NOW", "ISBLANK", "CONCATENATE", "CALCULATE",  # CALCULATE handled by predicate below
]
# Restructuring (need a grouped element / parallel join / pre-aggregate)
DAX_BUCKET_B = [
    "TOTALYTD", "TOTALQTD", "TOTALMTD", "RANKX", "RANK", "USERELATIONSHIP",
    "ALL", "ALLEXCEPT", "ALLSELECTED", "VALUES", "SUMMARIZE", "ADDCOLUMNS",
    "CALENDAR", "CALENDARAUTO", "RELATEDTABLE", "EARLIER", "EARLIEST",
    "TOPN", "GENERATE", "CROSSJOIN", "NATURALINNERJOIN",
]
# No clean Sigma equivalent (dynamic context swap, path hierarchies)
DAX_BUCKET_C = [
    "PATH", "PATHITEM", "PATHCONTAINS", "PATHLENGTH",
]

FUNC_RE = re.compile(r"\b([A-Z][A-Z0-9]*)\s*\(")


def classify_measure(expr):
    """Return ('a'|'b'|'c', set_of_funcs). Worst bucket present wins (c>b>a)."""
    if not expr:
        return "a", set()
    up = expr.upper()
    funcs = set(FUNC_RE.findall(up))
    bucket = "a"
    if any(f in DAX_BUCKET_C for f in funcs):
        bucket = "c"
    elif any(f in DAX_BUCKET_B for f in funcs):
        bucket = "b"
    # VAR/RETURN blocks that reference ALL-family already caught by B; a bare
    # VAR/RETURN that just inlines stays (a).
    return bucket, funcs


def analyze_tmsl(tmsl):
    """Extract complexity signals from a TMSL/TOM model dict."""
    model = tmsl.get("model", tmsl)
    tables = model.get("tables", [])
    out = {
        "table_count": 0,
        "calc_table_count": 0,
        "measure_count": 0,
        "calc_column_count": 0,
        "rls_role_count": len(model.get("roles", [])),
        "import_tables": 0,
        "directquery_tables": 0,
        "warehouse_sources": [],
        "dax_buckets": {"a": 0, "b": 0, "c": 0},
        "measures": [],          # [{name, bucket, len, funcs}]
        "measure_total_chars": 0,
        "max_measure_chars": 0,
    }
    wh = set()
    for t in tables:
        out["table_count"] += 1
        partitions = t.get("partitions", [])
        is_calc_table = any(p.get("source", {}).get("type") == "calculated" for p in partitions)
        if is_calc_table:
            out["calc_table_count"] += 1
        for p in partitions:
            src = p.get("source", {})
            mode = p.get("mode", "")
            if mode == "directQuery":
                out["directquery_tables"] += 1
            elif mode in ("import", ""):
                out["import_tables"] += 1
            # parse M expression for warehouse sources
            expr = src.get("expression", "")
            if isinstance(expr, list):
                expr = "\n".join(expr)
            for m in re.finditer(r'(Snowflake|Sql|AmazonRedshift|GoogleBigQuery|Databricks|PostgreSQL|Oracle)\.[A-Za-z]+\(\s*"?([^",)]+)', expr or ""):
                wh.add(f"{m.group(1)}:{m.group(2)}")
        for m in t.get("measures", []):
            expr = m.get("expression", "")
            if isinstance(expr, list):
                expr = "\n".join(expr)
            bucket, funcs = classify_measure(expr)
            out["measure_count"] += 1
            out["dax_buckets"][bucket] += 1
            ln = len(expr or "")
            out["measure_total_chars"] += ln
            out["max_measure_chars"] = max(out["max_measure_chars"], ln)
            out["measures"].append({
                "name": m.get("name"), "bucket": bucket, "chars": ln,
                "funcs": sorted(funcs),
            })
        for c in t.get("columns", []):
            if c.get("type") == "calculated":
                out["calc_column_count"] += 1
                expr = c.get("expression", "")
                if isinstance(expr, list):
                    expr = "\n".join(expr)
                bucket, _ = classify_measure(expr)
                out["dax_buckets"][bucket] += 1
    out["warehouse_sources"] = sorted(wh)
    return out


VISUAL_KIND_RE = re.compile(r'"visualType"\s*:\s*"([^"]+)"')


def analyze_pbir(parts):
    """parts: {path: text}. Count pages, visuals, visual-kind histogram."""
    out = {"page_count": 0, "visual_count": 0, "visual_kinds": {}, "custom_visuals": []}
    # PBIR enhanced report format: pages under definition/pages/<page>/page.json,
    # visuals under .../visuals/<id>/visual.json. Older inlined report.json has
    # sections[].visualContainers[].config.
    page_dirs = set()
    for path, text in parts.items():
        if "/pages/" in path and path.endswith("page.json"):
            page_dirs.add(path.split("/pages/")[1].split("/")[0])
        if path.endswith("visual.json") or path.endswith("report.json"):
            for vt in VISUAL_KIND_RE.findall(text):
                out["visual_count"] += 1
                out["visual_kinds"][vt] = out["visual_kinds"].get(vt, 0) + 1
                # custom visuals carry a GUID-ish / non-standard type token
                if vt and (len(vt) > 25 or vt.startswith("PBI_CV_") or "_" in vt and vt.isupper()):
                    out["custom_visuals"].append(vt)
    out["page_count"] = len(page_dirs)
    # Legacy single report.json with explicit sections / visualContainers
    if out["page_count"] == 0:
        for path, text in parts.items():
            if path.endswith("report.json") or path.endswith(".json"):
                try:
                    doc = json.loads(text)
                except Exception:
                    continue
                secs = doc.get("sections")
                if isinstance(secs, list):
                    out["page_count"] = max(out["page_count"], len(secs))
                    for s in secs:
                        for vc in s.get("visualContainers", []):
                            cfg = vc.get("config", "")
                            try:
                                cfgd = json.loads(cfg) if isinstance(cfg, str) else cfg
                                vt = (cfgd.get("singleVisual", {}) or {}).get("visualType")
                                if vt:
                                    out["visual_count"] += 1
                                    out["visual_kinds"][vt] = out["visual_kinds"].get(vt, 0) + 1
                            except Exception:
                                pass
    out["custom_visuals"] = sorted(set(out["custom_visuals"]))
    return out


def fetch_report_dataset_map(pbi_tok, ws):
    """Power BI REST /reports returns datasetId; the Fabric /reports endpoint
    does not. Returns {reportId: datasetId} or {} on failure."""
    if not pbi_tok:
        return {}
    url = f"{PBI_BASE}/groups/{ws}/reports"
    r = requests.get(url, headers={"Authorization": f"Bearer {pbi_tok}"})
    if r.status_code != 200:
        return {}
    return {x["id"]: x.get("datasetId") for x in r.json().get("value", [])}


def fetch_refresh_history(pbi_tok, ws, model_id):
    """Power BI REST audience. Returns list of refresh records or None on 401/err."""
    if not pbi_tok:
        return None
    url = f"{PBI_BASE}/groups/{ws}/datasets/{model_id}/refreshes?$top=10"
    r = requests.get(url, headers={"Authorization": f"Bearer {pbi_tok}"})
    if r.status_code != 200:
        return None
    recs = r.json().get("value", [])
    return [{"status": x.get("status"), "startTime": x.get("startTime"),
             "endTime": x.get("endTime"), "refreshType": x.get("refreshType")}
            for x in recs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--no-interactive", action="store_true",
                    help="fail rather than launch a device-code flow (headless / CI)")
    ap.add_argument("--workspaces", default=None, help="comma-sep workspace ids to limit to")
    ap.add_argument("--limit-models", type=int, default=0, help="cap models scanned (0=all)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(os.path.join(args.out, "raw-tmsl"), exist_ok=True)
    os.makedirs(os.path.join(args.out, "raw-pbir"), exist_ok=True)

    interactive = not args.no_interactive
    tok = get_token(FABRIC_SCOPE, interactive=interactive, label="Fabric")
    if not tok:
        print("NO_TOKEN — token cache cold and interactive disabled (or device flow blocked).",
              file=sys.stderr)
        sys.exit(2)
    print(f"[auth] Fabric token aud={_jwt_aud(tok)}", file=sys.stderr)
    pbi_tok = get_token(PBI_SCOPE, interactive=interactive, label="Power BI REST")
    if pbi_tok:
        print(f"[auth] Power BI REST token aud={_jwt_aud(pbi_tok)}", file=sys.stderr)
    else:
        print("[auth] Power BI REST token unavailable — refresh history will be null", file=sys.stderr)

    r = fab(tok, "/workspaces")
    if r.status_code != 200:
        print(f"[/workspaces] {r.status_code} {r.text[:300]}", file=sys.stderr)
        sys.exit(3)
    workspaces = r.json().get("value", [])
    if args.workspaces:
        keep = set(args.workspaces.split(","))
        workspaces = [w for w in workspaces if w["id"] in keep]

    inv = {
        "tenant": {
            "generated_at": time.strftime("%Y-%m-%d"),
            "fabric_aud": _jwt_aud(tok),
            "refresh_history_available": pbi_tok is not None,
            "workspace_count": len(workspaces),
        },
        "workspaces": [],
        "semantic_models": [],
        "reports": [],
        "environment_overview": {
            "workspaces": len(workspaces), "on_capacity_workspaces": 0,
            "semantic_models": 0, "reports": 0, "dashboards": 0,
            "dataflows": 0, "lakehouses": 0, "warehouses": 0, "notebooks": 0,
            "other_items": 0,
        },
    }

    models_scanned = 0
    for w in workspaces:
        ws_id, ws_name = w["id"], w.get("displayName", w["id"])
        on_cap = bool(w.get("capacityId"))
        if on_cap:
            inv["environment_overview"]["on_capacity_workspaces"] += 1
        type_counts = {}
        items = []
        ri = fab(tok, f"/workspaces/{ws_id}/items")
        if ri.status_code == 200:
            items = ri.json().get("value", [])
        for it in items:
            t = it.get("type", "Unknown")
            type_counts[t] = type_counts.get(t, 0) + 1
        inv["workspaces"].append({
            "id": ws_id, "name": ws_name, "on_capacity": on_cap,
            "capacityId": w.get("capacityId"), "item_type_counts": type_counts,
        })
        eo = inv["environment_overview"]
        eo["semantic_models"] += type_counts.get("SemanticModel", 0)
        eo["reports"] += type_counts.get("Report", 0)
        eo["dashboards"] += type_counts.get("Dashboard", 0)
        eo["dataflows"] += type_counts.get("Dataflow", 0) + type_counts.get("DataflowGen2", 0)
        eo["lakehouses"] += type_counts.get("Lakehouse", 0)
        eo["warehouses"] += type_counts.get("Warehouse", 0)
        eo["notebooks"] += type_counts.get("Notebook", 0)
        eo["other_items"] += sum(c for k, c in type_counts.items() if k not in (
            "SemanticModel", "Report", "Dashboard", "Dataflow", "DataflowGen2",
            "Lakehouse", "Warehouse", "Notebook"))

        # --- semantic models ---
        rm = fab(tok, f"/workspaces/{ws_id}/semanticModels")
        models = rm.json().get("value", []) if rm.status_code == 200 else []
        for m in models:
            if args.limit_models and models_scanned >= args.limit_models:
                break
            mid, mname = m["id"], m.get("displayName", m["id"])
            print(f"[model] {ws_name}/{mname}", file=sys.stderr)
            tmsl = get_definition_tmsl(tok, ws_id, mid)
            entry = {
                "id": mid, "name": mname, "workspace": ws_name, "workspace_id": ws_id,
                "on_capacity": on_cap,
            }
            if tmsl:
                safe = re.sub(r"\W+", "_", f"{ws_name}__{mname}")
                open(os.path.join(args.out, "raw-tmsl", safe + ".tmsl"), "w").write(
                    json.dumps(tmsl, indent=2))
                entry.update(analyze_tmsl(tmsl))
            else:
                entry["tmsl_error"] = "getDefinition failed or returned no parts"
            entry["refresh_history"] = fetch_refresh_history(pbi_tok, ws_id, mid)
            inv["semantic_models"].append(entry)
            models_scanned += 1

        # --- reports ---
        rr = fab(tok, f"/workspaces/{ws_id}/reports")
        reports = rr.json().get("value", []) if rr.status_code == 200 else []
        # Fabric /reports omits datasetId; recover the linkage from PBI REST.
        report_ds = fetch_report_dataset_map(pbi_tok, ws_id)
        for rep in reports:
            rid, rname = rep["id"], rep.get("displayName", rep["id"])
            print(f"[report] {ws_name}/{rname}", file=sys.stderr)
            entry = {
                "id": rid, "name": rname, "workspace": ws_name, "workspace_id": ws_id,
                "dataset_id": rep.get("datasetId") or report_ds.get(rid),
            }
            parts = get_report_pbir(tok, ws_id, rid)
            if parts:
                safe = re.sub(r"\W+", "_", f"{ws_name}__{rname}")
                open(os.path.join(args.out, "raw-pbir", safe + ".json"), "w").write(
                    json.dumps(parts, indent=2))
                entry.update(analyze_pbir(parts))
            else:
                entry["pbir_error"] = "getDefinition failed or returned no parts"
            inv["reports"].append(entry)

    # Duplicate / consolidation candidates — flag reports that are the same
    # dashboard rebuilt (shared semantic model / warehouse source + overlapping
    # visual set + near-identical name), so the estate migrates ONCE instead of
    # N times. Shared, tool-neutral detector (importlib because the filename has
    # a hyphen). Only signals actually present in the inventory are fed in:
    #   sources = the report's semantic model name + its warehouse sources
    #             (datasets/models/warehouse tables the report reads)
    #   viz     = the report's visual-kind tokens
    # `fields` and per-report `usage` are NOT exposed by the PBIR inventory, so
    # they are deliberately omitted (never fabricated).
    import importlib.util
    _dd_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dup-dashboards.py")
    _spec = importlib.util.spec_from_file_location("dup_dashboards", _dd_path)
    _dd = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_dd)
    _models_by_id = {m["id"]: m for m in inv["semantic_models"]}
    _norm_dash = []
    for rep in inv["reports"]:
        m = _models_by_id.get(rep.get("dataset_id")) or {}
        sources = []
        if m.get("name"):
            sources.append(m["name"])
        sources += (m.get("warehouse_sources") or [])
        d = {"id": rep.get("id"), "name": rep.get("name")}
        if sources:
            d["sources"] = sources
        viz = list((rep.get("visual_kinds") or {}).keys())
        if viz:
            d["viz"] = viz
        _norm_dash.append(d)
    inv["duplicate_dashboards"] = _dd.detect(_norm_dash)

    open(os.path.join(args.out, "inventory.json"), "w").write(json.dumps(inv, indent=2))
    eo = inv["environment_overview"]
    print(f"\nWROTE {os.path.join(args.out, 'inventory.json')}", file=sys.stderr)
    print(f"  workspaces={eo['workspaces']} ({eo['on_capacity_workspaces']} on capacity)", file=sys.stderr)
    print(f"  semantic_models={eo['semantic_models']}  reports={eo['reports']}  "
          f"dashboards={eo['dashboards']}  dataflows={eo['dataflows']}  "
          f"lakehouses={eo['lakehouses']}", file=sys.stderr)
    print(f"  models scanned for TMSL: {models_scanned}", file=sys.stderr)
    _ds = inv["duplicate_dashboards"]["summary"]
    if _ds["duplicate_groups"]:
        print(f"  duplicate/consolidation: {_ds['duplicate_groups']} group(s) across "
              f"{_ds['dashboards_in_groups']} reports — avoids {_ds['conversions_avoided']} "
              f"redundant migration(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
