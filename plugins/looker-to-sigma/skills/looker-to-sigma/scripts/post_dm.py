#!/usr/bin/env python3
"""POST a Sigma data-model spec to /v2/dataModels/spec.

- Swaps any placeholder connectionId in the spec for the full connection UUID
  ($SIGMA_CONNECTION_ID). convert_dm.mjs writes a placeholder; use the FULL UUID
  here (a short prefix → "Source not found: warehouse table ...").
- Auto-picks a writable folder (folderId is required), preferring one whose name
  mentions LOOKER / MIGRATION / TEST; override with --folder-id.
- The spec endpoints return YAML, not JSON — don't json.load the response.

Usage:
  SIGMA_CONNECTION_ID=<full-uuid> python3 post_dm.py <spec.json> [--folder-id <id>]

Sigma auth is resolved by scripts/lib/sigma_rest.py: a valid bearer is reused,
then the browser keychain is refreshed, with client credentials as fallback.
"""
import argparse, json, os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import sigma_rest
from warehouse_column_refs import apply as ground_warehouse_refs

FULL_CONN = os.environ.get("SIGMA_CONNECTION_ID")


class SigmaApiError(RuntimeError):
    def __init__(self, status, body, detail):
        self.status = status
        self.code = status  # compatibility with the old urllib HTTPError shape
        self.body = body
        super().__init__(detail)


def api(method, path, body=None):
    try:
        # Accept text so YAML spec responses retain the existing return shape.
        # sigma_rest owns proactive refresh and a single refresh/retry on 401.
        raw = sigma_rest.request(
            method.lower(),
            path,
            body=json.dumps(body) if body is not None else None,
            accept="*/*",
        )
    except sigma_rest.SigmaError as exc:
        detail = str(exc)
        match = re.search(r" -> (\d+)[^\n]*\n?(.*)", detail, re.DOTALL)
        status = int(match.group(1)) if match else None
        err_body = match.group(2) if match else detail
        print("HTTP", status or "AUTH", method, path, "->", err_body[:1000], file=sys.stderr)
        raise SigmaApiError(status, err_body, detail) from exc
    except SystemExit as exc:
        raise SigmaApiError(None, str(exc), str(exc)) from exc
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return raw  # YAML/text


def sync_missing_schemas(err_body):
    """POSTMORTEM 2026-06-18 (#2): a first-time DM POST against a schema the Sigma
    connection hasn't indexed yet fails with
      "Source not found: warehouse table 'DB.SCHEMA.TABLE' on connection <id>"
    even though the schema exists in the warehouse. The fix the operator ran by
    hand was POST /v2/connections/{id}/sync {"path":["DB","SCHEMA"]}. Do it
    automatically: parse every DB.SCHEMA out of the error and sync each once.
    Returns the set of (db, schema) pairs synced (empty if none parseable)."""
    if not FULL_CONN:
        return set()
    # 'DB.SCHEMA.TABLE' — DB and SCHEMA are the path to sync (table is discovered).
    pairs = set()
    for m in re.finditer(r"warehouse table '([^']+)'", err_body):
        parts = m.group(1).split(".")
        if len(parts) >= 3:
            pairs.add((parts[0], parts[1]))
    for db, schema in sorted(pairs):
        print(f"   auto-sync: POST /v2/connections/{FULL_CONN}/sync "
              f"path=[{db}, {schema}] (catalog not yet indexed)", file=sys.stderr)
        try:
            api("POST", f"/v2/connections/{FULL_CONN}/sync", {"path": [db, schema]})
        except SigmaApiError as e:
            print(f"   WARN: sync of {db}.{schema} returned {e.code} — "
                  "continuing (schema may already be syncing)", file=sys.stderr)
    return pairs


def post_dm_with_sync(spec):
    """POST the DM spec; on a 'Source not found' 400, sync the named schema(s)
    on the connection and retry once (the sync is async-but-fast for the
    table-discovery case the postmortem hit)."""
    try:
        return api("POST", "/v2/dataModels/spec", spec)
    except SigmaApiError as e:
        body = getattr(e, "body", "")
        if e.code == 400 and "Source not found" in body:
            synced = sync_missing_schemas(body)
            if synced:
                print(f"   synced {len(synced)} schema(s) — retrying DM POST", file=sys.stderr)
                return api("POST", "/v2/dataModels/spec", spec)
        raise


def drop_join_key_passthroughs(spec):
    """Guard: drop derived-view columns that pass a relationship's OWN join key across
    the join (formula [Base/REL_NAME/<target key col>]). A cross-element passthrough of
    a join key compiles to type "error" in Sigma (the base element already carries that
    value; Sigma degrades the ref on readback). The MCP lookml converter's denormalized
    element can still emit one — strip it here with a WARN before POSTing."""
    rel_keys = {}   # relationship name -> set of target-key DISPLAY names
    elements = [e for p in spec.get("pages", []) for e in (p.get("elements") or [])]
    by_id = {e.get("id"): e for e in elements}
    for el in elements:
        for rel in (el.get("relationships") or []):
            tgt = by_id.get(rel.get("targetElementId")) or {}
            tcols = {c.get("id"): c for c in (tgt.get("columns") or [])}
            names = rel_keys.setdefault(rel.get("name") or "", set())
            for k in (rel.get("keys") or []):
                c = tcols.get(k.get("targetColumnId"))
                if not c:
                    continue
                d = c.get("name")
                if not d:
                    m = re.match(r"\[([^\]]+)\]$", c.get("formula") or "")
                    if m:
                        d = m.group(1).split("/")[-1]
                if d:
                    names.add(d)
    for el in elements:
        cols = el.get("columns") or []
        kept = []
        for c in cols:
            m = re.match(r"\[([^/\]]+)/([^/\]]+)/([^\]]+)\]$", c.get("formula") or "")
            if m and m.group(3) in rel_keys.get(m.group(2), set()):
                print(f"WARN: dropping join-key passthrough column {c.get('id')} "
                      f"({c.get('formula')}) on element {el.get('name') or el.get('id')} — "
                      f"cross-element passthrough of a join key compiles to type=error in Sigma",
                      file=sys.stderr)
                if el.get("order"):
                    el["order"] = [o for o in el["order"] if o != c.get("id")]
                continue
            kept.append(c)
        if len(kept) != len(cols):
            el["columns"] = kept
    return spec


def apply_source_swap(spec, swaps):
    """POSTMORTEM 2026-06-18 (#3): LookML `sql_table_name` can point at a
    DB.SCHEMA that the target Sigma connection doesn't serve (e.g. dev
    'DEMO_DB.DEMO.*' vs the connection's 'QUICKSTARTS.LOOKER_RETAIL_ANALYTICS.*').
    The converter faithfully carries the source path through, so the DM POST
    400s. --source-swap FROM_DB.FROM_SCHEMA=TO_DB.TO_SCHEMA rewrites every
    warehouse-table source path (deep-walked: elements AND nested join sources)
    whose first two path segments match. Repeatable.

    swaps: list of ((from_db, from_schema), (to_db, to_schema)) tuples."""
    n = [0]

    def walk(o):
        if isinstance(o, dict):
            p = o.get("path")
            if isinstance(p, list) and len(p) >= 2:
                for (fdb, fsch), (tdb, tsch) in swaps:
                    if str(p[0]).upper() == fdb.upper() and str(p[1]).upper() == fsch.upper():
                        o["path"] = [tdb, tsch] + p[2:]
                        n[0] += 1
                        break
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(spec)
    if n[0]:
        for (fdb, fsch), (tdb, tsch) in swaps:
            print(f"   source-swap: {fdb}.{fsch} → {tdb}.{tsch}", file=sys.stderr)
        print(f"   rewrote {n[0]} warehouse-table source path(s)", file=sys.stderr)
    else:
        print(f"   WARN: --source-swap supplied but matched 0 source paths "
              "(check the FROM DB.SCHEMA matches the spec)", file=sys.stderr)
    return spec


def parse_swap(s):
    try:
        frm, to = s.split("=", 1)
        fdb, fsch = frm.split(".", 1)
        tdb, tsch = to.split(".", 1)
        return ((fdb.strip(), fsch.strip()), (tdb.strip(), tsch.strip()))
    except ValueError:
        sys.exit(f"FATAL: --source-swap must be FROM_DB.FROM_SCHEMA=TO_DB.TO_SCHEMA, got {s!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spec")
    ap.add_argument("--folder-id")
    ap.add_argument("--source-swap", action="append", default=[],
                    help="FROM_DB.FROM_SCHEMA=TO_DB.TO_SCHEMA — repoint warehouse "
                         "source paths to the connection's catalog. Repeatable.")
    a = ap.parse_args()

    spec = json.load(open(a.spec))
    if a.source_swap:
        spec = apply_source_swap(spec, [parse_swap(s) for s in a.source_swap])
    spec = drop_join_key_passthroughs(spec)

    # rewrite every connectionId (placeholder or short prefix) to the full UUID
    if FULL_CONN:
        s = re.sub(r'("connectionId"\s*:\s*)"[^"]*"', rf'\1"{FULL_CONN}"', json.dumps(spec))
        spec = json.loads(s)
    else:
        print("WARN: SIGMA_CONNECTION_ID unset — posting spec connectionId as-is", file=sys.stderr)

    folder = a.folder_id
    if not folder:
        files = api("GET", "/v2/files?typeFilters=folder&limit=200")
        entries = files.get("entries", files.get("data", [])) if isinstance(files, dict) else []
        for f in entries:
            if any(k in (f.get("name", "") or "").upper() for k in ("LOOKER", "MIGRATION", "TEST")):
                folder = f["id"]; break
        if not folder and entries:
            folder = entries[0]["id"]
    print("folderId:", folder, file=sys.stderr)
    if folder:
        spec["folderId"] = folder

    grounding = ground_warehouse_refs(spec, api)
    modes = ", ".join(f"{cid}={'friendly' if value else 'physical'}"
                      for cid, value in grounding["connectionModes"].items())
    print(f"connection naming: {modes}; grounded {grounding['rewritten']} formula(s), "
          f"re-keyed {grounding['rekeyed']} id(s), re-prefixed {grounding['reprefixed']} ref(s)",
          file=sys.stderr)

    res = post_dm_with_sync(spec)
    print(json.dumps(res, indent=2)[:600] if isinstance(res, dict) else str(res)[:600])


if __name__ == "__main__":
    main()
