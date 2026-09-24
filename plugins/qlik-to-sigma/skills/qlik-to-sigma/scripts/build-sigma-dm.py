#!/usr/bin/env python3
r"""build-sigma-dm — Phase 3 of qlik-to-sigma: author + POST the Sigma data model
from the ACTUAL pipeline artifacts (no app-specific table maps or SQL baked in).

    python3 build-sigma-dm.py \
      --converter-out WORK/converter-out.json \   # convert_qlik_to_sigma output (star + metrics + relationships)
      --reconcile     WORK/reconcile.json \       # reconcile-columns.py output (Qlik field -> real warehouse column)
      --denorm        WORK/denorm.json \          # gen-denorm-sql.py output (the denormalized SQL element)
      --name "Retail Orders (Qlik->Sigma)" \
      [--measures WORK/measures.json]             # master measures (to keep original Qlik expr as description)
      [--folder <folderId>]                       # else auto-resolve (prefers a TEST/MIGRATION folder)
      [--dry-run] [--out WORK/dm-result.json] [--spec-out WORK/dm-spec.json]

What it ships (the proven pattern from the validated migrations, generalized):
  1. The converter's warehouse-table STAR elements, REPOINTED via reconcile.json:
     element path tail Qlik-table -> real warehouse table, column formulas
     [REAL_TABLE/<real col display>] with the Qlik field name kept as the column's
     display name. Relationships reference column IDS, so they survive the repoint.
  2. The DENORMALIZED custom-SQL element (gen-denorm-sql.py) — the bulletproof
     master for workbook charts (reproduces the LOAD-script joins + renames).
  3. The converter's translated METRICS, hosted on the denorm element (which
     carries every field, so no cross-element errors). Metrics whose refs don't
     resolve on the denorm columns are dropped + reported.
  The converter's auto "Dim View" derived elements are NOT shipped — the denorm
  SQL element supersedes them (see beads-sigma-hsua: multi-fact View bloat).

Prints a JSON result: {dataModelId, denormElementId, folderId, folderName,
metricsKept, metricsDropped, columnsDropped, denormOnlyColumns}. With --dry-run nothing is POSTed
     (dataModelId=null) and the spec lands in --spec-out. Calculated LOAD fields
     are denorm-only because warehouse-table elements can reference only physical columns.

Env (live mode): SIGMA_BASE_URL + SIGMA_API_TOKEN (eval "$(scripts/vendor/get-token.sh)").
"""
import json, os, re, sys, time, argparse, urllib.request

# Sigma's display-name rule (verified live 2026-06-10): lowercase particles
# unless first word — DAYS_TO_SHIP -> "Days to Ship".
SIGMA_LOWERCASE = {"a","an","the","and","but","or","for","nor","so","yet",
                   "at","by","in","of","on","to","up","as","into","via","per"}
def disp(c):
    words = [w for w in c.lower().split("_") if w]
    return " ".join(w if (i and w in SIGMA_LOWERCASE) else w.capitalize()
                    for i, w in enumerate(words))

def api(method, path, body=None):
    BASE = os.environ["SIGMA_BASE_URL"]; TOK = os.environ["SIGMA_API_TOKEN"]
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
        headers={"Authorization": "Bearer " + TOK, "Content-Type": "application/json",
                 "Accept": "application/json"})
    raw = None
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read().decode()
            break
        except urllib.error.HTTPError as e:
            detail = e.read().decode()
            if e.code == 429 and attempt < 5:  # Cloudflare 1015 rate limit: transient, retryable
                wait = min(120, 30 * (2 ** attempt))
                print(f"HTTP 429 on {method} {path} -- backing off {wait}s (attempt {attempt+1}/6)", file=sys.stderr)
                time.sleep(wait)
                continue
            print("HTTP", e.code, "on", method, path, "->", detail[:800], file=sys.stderr); raise
    try:
        return json.loads(raw or "{}")
    except json.JSONDecodeError:
        return raw  # spec POSTs can return YAML

def pick_folder(explicit):
    """Resolve the target folder. Prefers an editable TEST/MIGRATION folder, then
    any editable folder. (The old version's `... or True` made the permission
    check a no-op — fixed: only edit/contribute folders are candidates.)"""
    if explicit:
        return explicit, None
    files = api("GET", "/v2/files?typeFilters=folder&limit=200")
    entries = [f for f in files.get("entries", files.get("data", []))
               if f.get("type") == "folder"
               and (f.get("permission") in ("edit", "contribute") or f.get("permission") is None)]
    pick = next((f for f in entries
                 if "TEST" in f.get("name", "").upper() or "MIGRATION" in f.get("name", "").upper()),
                entries[0] if entries else None)
    if not pick:
        sys.exit("no editable folder found — pass --folder <id>")
    return pick["id"], pick.get("name")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--converter-out", required=True)
    ap.add_argument("--reconcile", required=True)
    ap.add_argument("--denorm", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--measures")
    ap.add_argument("--folder")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--out", default="dm-result.json")
    ap.add_argument("--spec-out", default="dm-spec.json")
    a = ap.parse_args()

    conv = json.load(open(a.converter_out))
    cmodel = conv.get("model") or conv.get("sigmaDataModel") or conv
    reconcile = json.load(open(a.reconcile))
    denorm = json.load(open(a.denorm))["element"]
    measures = json.load(open(a.measures)) if a.measures and os.path.exists(a.measures) else []

    # --- 1. repoint the converter's warehouse-table star via reconcile ---------
    # reconcile: [{qlikTable, sourceTable, fields:[{qlikField, realColumn, isExpression}]}]
    rec_by_upper = {t["qlikTable"].upper(): t for t in reconcile}
    def real_table(t):  # ORDER_FACT.csv -> ORDER_FACT; db.schema.T -> T
        return re.sub(r"\.csv$", "", t["sourceTable"], flags=re.I).split(".")[-1].strip('"')

    # collect the converter's metrics BEFORE stripping them off the elements
    all_metrics = [m for el in cmodel.get("pages", [{}])[0].get("elements", [])
                   for m in (el.get("metrics") or [])]

    elements, columns_dropped, denorm_only = [], [], []
    for el in cmodel.get("pages", [{}])[0].get("elements", []):
        src = el.get("source", {})
        if src.get("kind") != "warehouse-table":
            continue  # skip the converter's derived "View" elements (denorm supersedes them)
        path = list(src.get("path") or [])
        rec = rec_by_upper.get((path[-1] if path else "").upper())
        if rec and not rec["sourceTable"].upper().startswith(("RESIDENT", "INLINE", "AUTOGENERATE", "?")):
            rt = real_table(rec)
            # Match converter columns to Qlik fields on a separator/case-free key: the
            # converter splits camelCase (OrderID -> "Order Id") while
            # disp() splits only on underscores ("Orderid").
            norm = lambda v: re.sub(r"[^a-z0-9]", "", str(v).lower())
            field_by_disp = {norm(f["qlikField"]): f for f in rec["fields"]}
            new_cols, order = [], []
            for c in el.get("columns", []):
                m = re.match(r"\[([^/\]]+)/([^\]]+)\]$", c.get("formula", ""))
                f = field_by_disp.get(norm(m.group(2))) if m else None
                if f is None:
                    new_cols.append(c); order.append(c["id"]); continue
                if f.get("isExpression"):
                    # A warehouse-table element can only reference physical columns.
                    # The calculated field is preserved on the custom-SQL denorm
                    # element, which is the workbook's source of truth.
                    denorm_only.append(f"{rec['qlikTable']}.{f['qlikField']}")
                    continue
                if f["realColumn"] == "*":
                    columns_dropped.append(f"{rec['qlikTable']}.{f['qlikField']} (*)")
                    continue
                new_cols.append({"id": c["id"], "name": disp(f["qlikField"]),
                                 "formula": f"[{rt}/{disp(f['realColumn'])}]"})
                order.append(c["id"])
            el["columns"] = new_cols
            el["order"] = order
            el["source"]["path"] = path[:-1] + [rt]
            el["name"] = rec["qlikTable"]
        el.pop("metrics", None)  # metrics are hosted on the denorm element below
        elements.append(el)

    # --- 2. metrics -> denorm element (keep only those whose refs resolve) -----
    # Resolve metric refs separator/case-free (the converter splits camelCase:
    # [Net Amount]; the denorm column is disp()'d: "Netamount") and rewrite
    # each ref to the denorm column's actual display name.
    _norm = lambda v: re.sub(r"[^a-z0-9]", "", str(v).lower())
    denorm_by_norm = {_norm(c["name"]): c["name"] for c in denorm["columns"]}
    denorm_disp = {c["name"].lower() for c in denorm["columns"]}
    src_expr = {m.get("title"): m.get("expr") or m.get("qDef") for m in measures}
    kept, dropped = [], []
    seen_metric = set()
    for m in all_metrics:
        if m.get("name") in seen_metric: continue
        seen_metric.add(m.get("name"))
        refs = [r.split("/")[-1] for r in re.findall(r"\[([^\]]+)\]", m.get("formula", ""))]
        # Qlik-only residue the converter could not translate ($(var) expansion,
        # inter-record/ranking/Aggr functions) POST-blocks the WHOLE spec with a
        # 400 -- drop + report instead of emitting an invalid formula
        body = re.sub(r"\[[^\]]*\]", "", m.get("formula", ""))
        qlik_only = re.search(r"\$\(|\b(?:Rank|HRank|Aggr|Above|Below|Peek|Previous|RowNo|FirstSortedValue)\s*\(", body, re.I)
        if refs and not qlik_only and all(_norm(r) in denorm_by_norm for r in refs):
            m["formula"] = re.sub(
                r"\[([^\]/]+)\]", lambda x: f"[{denorm_by_norm.get(_norm(x.group(1)), x.group(1))}]",
                m.get("formula", ""))
            if src_expr.get(m.get("name")):
                m.setdefault("description", f"Qlik: {src_expr[m['name']]}")
            kept.append(m)
        else:
            dropped.append(m.get("name"))
    if kept:
        denorm["metrics"] = kept
    elements.append(denorm)

    spec = {"name": a.name, "schemaVersion": 1,
            "pages": [{"id": "pg-dm", "name": "Page 1", "elements": elements}]}
    json.dump(spec, open(a.spec_out, "w"), indent=2)

    result = {"dataModelId": None, "denormElementId": denorm["id"], "folderId": a.folder,
              "folderName": None, "metricsKept": len(kept), "metricsDropped": dropped,
              "columnsDropped": columns_dropped, "denormOnlyColumns": denorm_only,
              "starElements": len(elements) - 1}
    if a.dry_run:
        print(f"DRY RUN: spec -> {a.spec_out} ({len(elements)} elements, {len(kept)} metrics on denorm)",
              file=sys.stderr)
    else:
        folder_id, folder_name = pick_folder(a.folder)
        body = dict(spec); body["folderId"] = folder_id
        res = api("POST", "/v2/dataModels/spec", body)
        dm_id = res.get("dataModelId") or res.get("id") if isinstance(res, dict) else \
            (re.search(r"dataModelId:\s*(\S+)", str(res)) or [None, None])[1]
        if not dm_id:
            sys.exit(f"FATAL: DM POST returned no id: {str(res)[:300]}")
        # Sigma reassigns element ids on POST — read back the persisted denorm
        # element id (the custom-SQL element auto-names to "Custom SQL").
        els = api("GET", f"/v2/dataModels/{dm_id}/elements")
        persisted = next((e for e in els.get("entries", [])
                          if e.get("name") == "Custom SQL"), None) or \
                    next(iter(els.get("entries", [])), {})
        result.update(dataModelId=dm_id, folderId=folder_id, folderName=folder_name,
                      denormElementId=persisted.get("elementId") or persisted.get("id") or denorm["id"])
    json.dump(result, open(a.out, "w"), indent=2)
    print(json.dumps(result))

if __name__ == "__main__":
    main()
