#!/usr/bin/env python3
"""qlik-discover — Phase 1 of qlik-to-sigma.

Extracts a Qlik Cloud app's structure via qlik-cli (Engine + REST) into the
JSON that mcp__sigma-data-model__convert_qlik_to_sigma consumes, plus the
sheet/chart inventory, the per-sheet CELL GRID (layout), the app's freshness
metadata, and a Qlik-engine snapshot of the app's KPI totals — everything the
downstream build steps need, with no hand-edits.

    python3 qlik-discover.py --app <appId> [--context <ctx>] [--out discovery]
                             [--pool 8] [--skip-eval]
                             [--defer-snapshot | --snapshot-only]

Outputs in --out/:
  script.qvs            raw load script (the data-model source of truth)
  measures.json         master measures  [{title, expr}]
  dimensions.json       master dimensions [{title, expr}]
  charts.json           chart objects: vizType, title, sheet, dims (raw defs +
                        labels + nullSuppression), measures (exprs + labels +
                        Qlik number formats), sort
  layout.json           per-sheet cell grid: [{sheetId, title, rank, columns,
                        rows, cells:[{objectId, type, col, row, colspan, rowspan}]}]
  app-meta.json         REST item record: name, lastReloadTime, hasSectionAccess,
                        isDirectQueryMode — feeds the source-freshness preflight
  snapshot.json         Qlik-engine eval of every sheet KPI expression + Max() of
                        date-ish fact fields + per-chart distinct-bucket counts —
                        the app's IN-MEMORY totals, used to report staleness vs
                        the live warehouse before any parity
  converter-input.json  ready for convert_qlik_to_sigma (tables + masterMeasures + masterDimensions)
  timings.json          ALWAYS written — per-stage wall-clock + retry counts, the
                        evidence trail for any future "discovery is slow" report
                        (--snapshot-only writes timings-snapshot.json instead)

PERFORMANCE (measured on app ec9a73e3, 46 objects, 2026-06-11): the serial
version took ~55-64s; almost all of it was the per-object `properties` loop
(46 × ~1.2s engine round-trips) plus the serial KPI/max-date evals. Everything
network-bound now runs through ONE shared thread pool (--pool, default 8 —
measured 4.7× on the properties batch; each qlik-cli call opens its own
engine session so calls are independent). Customer apps at 40+ objects scale
linearly in pool width, not object count.

Snapshot deferral: the engine snapshot (KPI evals + max-date + bucket counts)
is only CONSUMED at the orchestrator's Phase-6 freshness banner, and the app's
in-memory totals cannot change without a reload — so `--defer-snapshot` skips
it here and `--snapshot-only` computes JUST it (reading charts.json etc. from
--out) as a background lane concurrent with Phases 2-4. snapshot.json is
written atomically so a polling orchestrator never observes a half-written file.

Requires qlik-cli on PATH and an active context (`qlik context use <ctx>`).
Discovery is STRICTLY READ-ONLY: master items are enumerated via
`qlik app measure ls` / `qlik app dimension ls` + per-item `properties`
(the old temp MeasureList/DimensionList object create→rm briefly SAVED the
app — bumping its modifiedDate on every discovery; eliminated 2026-06-11).
The app is NEVER reloaded and NEVER written.

Transient engine failures ("session closed", "could not connect to engine",
websocket drops, 429s) are retried with exponential backoff — expected
occasionally at 8-wide concurrency, and Qlik Cloud throttles NEW engine
sessions after rapid bursts (observed live 2026-06-11: back-to-back pool-8
runs → "could not connect to engine" on 3/46 objects). Any per-object fetch
still empty after the pooled pass is retried SERIALLY after a cooldown, and
discovery ABORTS (exit 4) if anything is still missing — an incomplete
charts.json must never silently become an incomplete Sigma workbook.
"""
import json, os, re, subprocess, sys, argparse, threading, time
from concurrent.futures import ThreadPoolExecutor

T0 = time.time()
STAGES = {}          # stage name -> seconds (timings.json evidence trail)
RETRIES = {"n": 0}
_LOCK = threading.Lock()
# Global cap on CONCURRENT qlik-cli engine sessions (set from --pool in main).
# Several pmaps run at once (master measures + dimensions + top-level fetches),
# so without one shared gate the burst is pools ADDED together (~19 sessions) —
# which is what trips Qlik Cloud's new-session throttle. One semaphore makes
# --pool the true total, whatever shape the fan-out has.
_SEM = threading.Semaphore(8)

# On-prem (client-managed) Qlik Sense: point QLIK_BIN at scripts/qlik-onprem-shim.py
# (qlik-cli is Cloud-only; the shim speaks the same command subset over QRS + Engine).
QLIK_BIN = os.environ.get("QLIK_BIN", "qlik")

TRANSIENT_RX = re.compile(
    r"session closed|socket: close|websocket|connection reset|broken pipe"
    r"|unexpected EOF|timed? ?out|temporarily unavailable"
    r"|could not connect to engine|too many (requests|sessions)|429|rate limit", re.I)


class stage:
    """Record a stage's wall-clock into STAGES (concurrent stages overlap)."""
    def __init__(self, name): self.name = name
    def __enter__(self): self.t0 = time.time(); return self
    def __exit__(self, *_):
        with _LOCK:
            STAGES[self.name] = round(STAGES.get(self.name, 0.0) + time.time() - self.t0, 3)


def qlik_run(args, attempts=4):
    """Run qlik-cli with retry + exponential backoff on transient engine
    errors. Safe to retry: discovery is read-only. Backoff is exponential
    (1s/2s/4s) because Qlik Cloud throttles new engine sessions after rapid
    bursts — a fixed 0.5s retry just re-hits the throttle."""
    out = None
    for attempt in range(attempts):
        with _SEM:
            out = subprocess.run([QLIK_BIN, *args], capture_output=True, text=True)
        if out.returncode == 0:
            return out
        if attempt < attempts - 1 and TRANSIENT_RX.search((out.stderr or "") + (out.stdout or "")):
            with _LOCK:
                RETRIES["n"] += 1
            time.sleep(min(8.0, 2.0 ** attempt))
            continue
        return out
    return out


def qlik(*args, parse_json=True):
    out = qlik_run(list(args))
    if out.returncode != 0 and parse_json:
        sys.stderr.write(f"WARN {' '.join(args)} -> {out.stderr[:160]}\n")
    if not parse_json:
        return out.stdout
    try:
        return json.loads(out.stdout or "null")
    except json.JSONDecodeError:
        return None


def _reflines(refline):
    """Normalize a Qlik object's refLine config -> {x:[...], y:[...]} of
    {show,label,color,value,expr}. refLinesX = X-axis lines, refLines = Y/measure."""
    def conv(arr):
        out = []
        for r in (arr or []):
            e = r.get("refLineExpr") or {}
            out.append({"show": r.get("show", True),
                        "label": r.get("label") or e.get("label"),
                        "color": r.get("color") or (r.get("paletteColor") or {}).get("color"),
                        "value": e.get("value"), "expr": e.get("label")})
        return out
    return {"x": conv(refline.get("refLinesX")), "y": conv(refline.get("refLines"))}


def awrite(path, obj):
    """Atomic JSON write — orchestrators poll for these files from a
    concurrent lane and must never observe a half-written artifact."""
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)


def pmap(fn, items, pool):
    """Parallel map preserving order. Submitted from the main thread only —
    no nested submit-and-wait, so no executor deadlock."""
    if not items:
        return []
    with ThreadPoolExecutor(max_workers=max(1, pool)) as ex:
        return list(ex.map(fn, items))


def pmap_complete(fetch, items, pool, key, what):
    """pmap `fetch` (which returns a truthy dict or None) over items, then
    retry any empty result SERIALLY after a cooldown — Qlik Cloud throttles
    new engine sessions after rapid bursts, and the pooled pass can lose a few
    items even with per-call retries (observed live: 3/46 object `properties`
    failed with 'could not connect to engine'). ABORTS (exit 4) if anything is
    still missing: a silently incomplete discovery (missing sheets/charts)
    must never become a silently incomplete Sigma workbook."""
    res = pmap(fetch, items, pool)
    missing = [i for i, r in enumerate(res) if not r]
    if missing:
        sys.stderr.write(f"WARN {what}: {len(missing)}/{len(items)} pooled fetch(es) empty — "
                         f"serial retry after 5s cooldown (engine session throttle)\n")
        time.sleep(5)
        for i in missing:
            res[i] = fetch(items[i])
    still = [str(key(items[i])) for i, r in enumerate(res) if not r]
    if still:
        sys.stderr.write(f"FATAL {what}: no properties for {len(still)} item(s) after pooled + "
                         f"serial retries: {', '.join(still[:8])}\n"
                         f"       The engine is refusing new sessions (throttle/capacity). "
                         f"Re-run, or use a smaller --pool (e.g. 4).\n")
        sys.exit(4)
    return res


# ---- master items: READ-ONLY enumeration (measure/dimension ls + properties) ----
def enumerate_master(app, ctx_args, kind, pool):
    """kind: 'measure' or 'dimension'. Returns list of {title, expr}.
    `qlik app {measure,dimension} ls` is read-only (verified: returns
    [{qId,title}]); the expression comes from per-item `properties`
    (qMeasure.qDef / qDim.qFieldDefs), fetched in parallel."""
    items = qlik("app", kind, "ls", "-a", app, "--json", *ctx_args) or []

    prop_list = pmap_complete(
        lambda it: qlik("app", kind, "properties", it.get("qId"), "-a", app, *ctx_args),
        items, pool, key=lambda it: it.get("qId"), what=f"master-{kind} properties")

    def shape(it, props):
        oid = it.get("qId")
        if kind == "measure":
            body = props.get("qMeasure") or {}
            expr, label = body.get("qDef"), body.get("qLabel")
        else:
            body = props.get("qDim") or {}
            defs = body.get("qFieldDefs") or []
            expr, label = (defs[0] if defs else ""), body.get("title")
        title = (props.get("qMetaDef") or {}).get("title") or it.get("title") or label or oid
        # keep the library id: charts reference master items by qLibraryId
        # (md-*/mm-*) and the workbook builder must resolve id -> expr/title
        return {"id": oid, "title": title, "expr": expr or ""}

    return [shape(it, props) for it, props in zip(items, prop_list)]


# ---- load-script → tables/fields (best-effort) ----
def split_fields(s):
    """Split a LOAD field list on top-level commas only (paren-depth aware), so
    function-built fields like `Dual(MONTH_NAME, MONTH_NUMBER) AS MONTH` stay
    one token instead of shedding a bogus duplicate column."""
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            parts.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append("".join(cur))
    return parts

def parse_script(qvs):
    tables = []
    # Match  Label:\n LOAD <fields> (FROM|RESIDENT|SQL|AUTOGENERATE|INLINE)
    for m in re.finditer(r'(\w+)\s*:\s*\n\s*LOAD\b(.*?)(?:\bFROM\b|\bRESIDENT\b|\bSQL\b|\bSELECT\b|\bAUTOGENERATE\b|\bINLINE\b)',
                         qvs, re.IGNORECASE | re.DOTALL):
        name, body = m.group(1), m.group(2)
        fields = []
        for tok in split_fields(body):
            tok = tok.strip().strip(";").strip()
            if not tok: continue
            mm = re.search(r'\bAS\s+"?([A-Za-z0-9_]+)"?\s*$', tok, re.IGNORECASE)  # alias wins
            if mm:
                fields.append(mm.group(1))
            else:
                mm2 = re.match(r'"?([A-Za-z0-9_]+)"?$', tok)
                if mm2: fields.append(mm2.group(1))
        if fields:
            tables.append({"name": name, "noOfRows": 0, "fields": [{"name": f} for f in fields]})
    return tables


def qlik_eval(app, ctx_args, expr):
    """Evaluate one expression via the engine (read-only). Returns the raw value string or None."""
    out = qlik_run(["app", "eval", expr, "-a", app, *ctx_args])
    lines = [l for l in out.stdout.splitlines() if l.strip()]
    return lines[1].strip() if out.returncode == 0 and len(lines) >= 2 else None


def _resolve_title(props, app, ctx_args):
    """A chart title may be a STATIC string or a Qlik string-expression
    ({qStringExpression:{qExpr:"='Total Revenue = ' & num(Sum(...))"}}). Return a
    plain string: static as-is, dynamic EVALUATED via the engine to its rendered
    text (a snapshot — matches what Qlik shows). Without this the dict reached the
    builder as the element name and the title rendered broken/blank."""
    for t in [(props.get("qMetaDef") or {}).get("title"), props.get("title")]:
        if isinstance(t, str) and t.strip():
            return t
        if isinstance(t, dict):
            qexpr = (t.get("qStringExpression") or {}).get("qExpr")
            if qexpr:
                val = qlik_eval(app, ctx_args, qexpr)
                if val not in (None, ""):
                    return val
    return None


def bucket_expr(dims):
    """The distinct-bucket-count expression Phase 6 compares per chart —
    MUST stay in sync with migrate-qlik.rb's bucket parity (same string)."""
    if len(dims) == 1:
        return f"Count(distinct [{dims[0]}])"
    return "Count(distinct " + "&'|'&".join(f"[{d}]" for d in dims) + ")"


def compute_snapshot(app, ctx, charts, tables, app_meta, pool, skip_eval):
    """The Qlik-engine snapshot (source-freshness preflight input): every
    on-sheet KPI expression, Max() of date-ish fact fields, and per-chart
    distinct-bucket counts — all evaluated against the app's IN-MEMORY data
    (cannot change without a reload, hence safely deferrable). All evals run
    through the shared pool."""
    snapshot = {"lastReloadTime": app_meta.get("lastReloadTime"),
                "kpis": [], "maxDates": [], "buckets": []}
    if skip_eval:
        return snapshot

    kpi_jobs, seen = [], set()
    for c in charts:
        if not (c["sheet"] and c["measures"] and not c["dimensions"]):
            continue
        expr = c["measures"][0]
        if not expr or expr in seen:
            continue
        seen.add(expr)
        kpi_jobs.append((expr, c["title"] or (c["measureLabels"] or [None])[0]))

    date_jobs = []
    if tables:
        fact = max(tables, key=lambda t: sum(1 for f in t["fields"] if f["name"].upper().endswith("_KEY")))
        date_jobs = [f["name"] for f in fact["fields"] if "DATE" in f["name"].upper()][:2]

    # per-chart bucket counts (deduped by expr): Phase 6's bucket parity used to
    # eval these serially against the engine at the end of the run — precompute
    # them here so the deferred-snapshot lane absorbs that cost too.
    bucket_jobs, bseen = [], set()
    for c in charts:
        dims = [(d[0] if isinstance(d, list) else d) for d in (c.get("dimensions") or [])]
        dims = [d for d in dims if d]
        if not (c.get("sheet") and dims and c.get("measures")):
            continue
        expr = bucket_expr(dims)
        if expr in bseen:
            continue
        bseen.add(expr)
        bucket_jobs.append(expr)

    jobs = [("kpi", e, t) for e, t in kpi_jobs] + \
           [("maxDate", f"Max({f})", f) for f in date_jobs] + \
           [("bucket", e, None) for e in bucket_jobs]
    vals = pmap(lambda j: qlik_eval(app, ctx, j[1]), jobs, pool)
    for (kind, expr, label), val in zip(jobs, vals):
        if kind == "kpi":
            snapshot["kpis"].append({"expr": expr, "title": label, "value": val})
        elif kind == "maxDate":
            snapshot["maxDates"].append({"field": label, "value": val})
        else:
            snapshot["buckets"].append({"expr": expr, "value": val})
    return snapshot


def write_timings(out_dir, mode, pool, n_objects=None):
    name = "timings-snapshot.json" if mode == "snapshot-only" else "timings.json"
    awrite(os.path.join(out_dir, name),
           {"mode": mode, "pool": pool, "total_seconds": round(time.time() - T0, 3),
            "objects": n_objects, "retries": RETRIES["n"],
            "stages": dict(sorted(STAGES.items()))})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--context")
    ap.add_argument("--out", default="discovery")
    ap.add_argument("--pool", type=int, default=8,
                    help="shared fetch/eval pool width (default 8 — measured 4.7x on the "
                         "per-object properties batch; 'session closed' retries cover the "
                         "occasional dropped engine session)")
    ap.add_argument("--skip-eval", action="store_true",
                    help="skip the Qlik-engine snapshot evals (snapshot.json gets empty lists)")
    ap.add_argument("--defer-snapshot", action="store_true",
                    help="write everything EXCEPT snapshot.json — run --snapshot-only later "
                         "(or concurrently) to produce it; in-memory totals can't change "
                         "without a reload, so deferral is exact")
    ap.add_argument("--snapshot-only", action="store_true",
                    help="compute ONLY snapshot.json from an existing --out dir "
                         "(charts.json / converter-input.json / app-meta.json)")
    a = ap.parse_args()
    global _SEM
    _SEM = threading.Semaphore(max(1, a.pool))  # ONE cap across every pmap
    ctx = ["--context", a.context] if a.context else []
    os.makedirs(a.out, exist_ok=True)

    # ---- snapshot-only lane: read prior artifacts, eval, write atomically ----
    if a.snapshot_only:
        with stage("snapshot"):
            charts = json.load(open(os.path.join(a.out, "charts.json")))
            conv = json.load(open(os.path.join(a.out, "converter-input.json")))
            app_meta = json.load(open(os.path.join(a.out, "app-meta.json"))) \
                if os.path.exists(os.path.join(a.out, "app-meta.json")) else {}
            snapshot = compute_snapshot(a.app, ctx, charts, conv.get("tables") or [],
                                        app_meta, a.pool, a.skip_eval)
            awrite(os.path.join(a.out, "snapshot.json"), snapshot)
        write_timings(a.out, "snapshot-only", a.pool)
        print(f"snapshot: {len(snapshot['kpis'])} KPI(s), {len(snapshot['maxDates'])} max-date(s), "
              f"{len(snapshot['buckets'])} bucket count(s) in {time.time() - T0:.1f}s "
              f"(pool={a.pool}, retries={RETRIES['n']}) -> {a.out}/snapshot.json")
        return

    # ---- full discovery: ONE shared pool covers every engine/REST fetch ----
    # Independent top-level fetches (script, REST item record, master-item ls,
    # object ls) start together; the per-object/per-item properties batches are
    # then mapped over the same pool width.
    results = {}
    def _script():
        with stage("script"):
            results["script"] = qlik("app", "script", "get", "-a", a.app, *ctx, parse_json=False)

    def _items():
        with stage("app-meta"):
            items = qlik("item", "ls", "--resourceType", "app", "--limit", "200", *ctx) or []
            rec = next((i for i in items if i.get("resourceId") == a.app), {})
            results["app_meta"] = rec.get("resourceAttributes") or {}

    def _measures():
        with stage("master-measures"):
            results["measures"] = enumerate_master(a.app, ctx, "measure", a.pool)

    def _dimensions():
        with stage("master-dimensions"):
            results["dimensions"] = enumerate_master(a.app, ctx, "dimension", a.pool)

    def _objects():
        with stage("object-ls"):
            results["objs"] = qlik("app", "object", "ls", "-a", a.app, "--json", *ctx) or []

    with stage("parallel-fetch"):
        with ThreadPoolExecutor(max_workers=5) as top:
            futs = [top.submit(f) for f in (_script, _items, _measures, _dimensions, _objects)]
            for f in futs:
                f.result()

        # per-object properties — the dominant cost (46 × ~1.2s serial on the
        # fixture app); pool-8 measured 4.7×. Each qlik-cli call is its own
        # engine session, so width is bounded by tenant session limits, not
        # correctness; transient 'session closed' is retried in qlik_run.
        objs = results["objs"]
        with stage("object-properties"):
            prop_list = pmap_complete(
                lambda o: qlik("app", "object", "properties", o.get("qId"), "-a", a.app, *ctx),
                objs, a.pool, key=lambda o: o.get("qId"), what="object properties")
        all_props = {o.get("qId"): p for o, p in zip(objs, prop_list)}

    script = results["script"] or ""
    open(os.path.join(a.out, "script.qvs"), "w").write(script)
    tables = parse_script(script)
    measures, dims_raw = results["measures"], results["dimensions"]
    awrite(os.path.join(a.out, "measures.json"), measures)
    awrite(os.path.join(a.out, "dimensions.json"), dims_raw)
    app_meta = results["app_meta"]
    awrite(os.path.join(a.out, "app-meta.json"), app_meta)

    # sheets first, so each chart can be annotated with its sheet
    charts, sheets, obj_sheet = [], [], {}
    for o in objs:
        oid, qtype = o.get("qId"), o.get("qType")
        if qtype != "sheet": continue
        props = all_props[oid]
        cells = [{"objectId": c.get("name"), "type": c.get("type"),
                  "col": c.get("col", 0), "row": c.get("row", 0),
                  "colspan": c.get("colspan", 1), "rowspan": c.get("rowspan", 1)}
                 for c in (props.get("cells") or [])]
        for c in cells: obj_sheet[c["objectId"]] = oid
        sheets.append({"sheetId": oid,
                       "title": (props.get("qMetaDef") or {}).get("title") or oid,
                       "rank": props.get("rank", 0),
                       "columns": props.get("columns", 24), "rows": props.get("rows", 12),
                       "cells": cells})
    sheets.sort(key=lambda s: (s["rank"] is None, s["rank"]))
    awrite(os.path.join(a.out, "layout.json"), sheets)

    # Filterpane children (control-targeting wave, workstream B): a filterpane's
    # listboxes are CHILD objects — not in its properties. `qlik app object
    # layout` evaluates the object's layout incl. qChildList.qItems. Fetched
    # through the same pool (filterpanes are few).
    fp_ids = [o.get("qId") for o in objs if o.get("qType") == "filterpane"]
    def _fp_children(fid):
        lay = qlik("app", "object", "layout", fid, "-a", a.app, *ctx) or {}
        items = ((lay.get("qChildList") or {}).get("qItems")) or []
        return [it.get("qInfo", {}).get("qId") for it in items if it.get("qInfo", {}).get("qId")]
    with stage("filterpane-children"):
        fp_children = dict(zip(fp_ids, pmap(_fp_children, fp_ids, a.pool)))

    # Listbox field metadata from the EVALUATED layout (qListObject.qDimensionInfo):
    # qTags carries the field's type tags ($date/$timestamp) — the workbook builder
    # needs them to emit a date-range control instead of a list (a list control's
    # filter targets on a datetime column get SILENTLY STRIPPED by Sigma). Also the
    # only source of field/title for pane children that `app object ls` omits.
    known_ids = {o.get("qId") for o in objs}
    lb_ids = [o.get("qId") for o in objs if o.get("qType") == "listbox"]
    lb_ids += [c for kids in fp_children.values() for c in kids if c not in known_ids]
    def _lb_meta(lid):
        lay = qlik("app", "object", "layout", lid, "-a", a.app, *ctx) or {}
        lo = lay.get("qListObject") or {}
        di = lo.get("qDimensionInfo") or {}
        return {"field": (di.get("qGroupFieldDefs") or [None])[0],
                "label": di.get("qFallbackTitle"),
                "title": (lay.get("title") or di.get("qFallbackTitle")),
                "state": lo.get("qStateName") or lay.get("qStateName"),
                "tags": di.get("qTags") or [],
                "numFmt": (di.get("qNumFormat") or {}).get("qFmt")}
    with stage("listbox-meta"):
        lb_meta = dict(zip(lb_ids, pmap(_lb_meta, lb_ids, a.pool)))

    for o in objs:
        oid, qtype = o.get("qId"), o.get("qType")
        if qtype == "sheet": continue
        props = all_props[oid]
        hc = props.get("qHyperCubeDef", {})
        # Carry the object's sort definition so the workbook build can reproduce it:
        # per-dimension qSortCriterias (qSortByNumeric/qSortByAscii/qSortByExpression),
        # per-measure qSortBy, and the column precedence (qInterColumnSortOrder).
        # Empty lists/{} mean "Qlik default" — the builder should only emit a Sigma
        # sort (xAxis.sort / groupings[0].sort) when one is present.
        sort = {
            "interColumnSortOrder": hc.get("qInterColumnSortOrder") or [],
            "dimensions": [ (dd.get("qDef", {}).get("qSortCriterias") or []) for dd in hc.get("qDimensions", []) ],
            "measures":   [ (mm.get("qSortBy") or {}) for mm in hc.get("qMeasures", []) ],
        }
        qdims, qmeas = hc.get("qDimensions", []), hc.get("qMeasures", [])
        if not qdims and not qmeas:
            # map objects carry their hypercube on a layer (gaLayers[].qHyperCubeDef),
            # not the top-level object -- surface the first layer that has one
            for layer in (props.get("gaLayers") or []):
                lhc = layer.get("qHyperCubeDef") or {}
                if lhc.get("qDimensions") or lhc.get("qMeasures"):
                    hc = lhc
                    qdims, qmeas = lhc.get("qDimensions", []), lhc.get("qMeasures", [])
                    break
        rec = {
            "id": oid, "vizType": qtype,
            "title": _resolve_title(props, a.app, ctx),
            "sheet": obj_sheet.get(oid),
            "dimensions": [ (dd.get("qDef", {}).get("qFieldDefs") or [dd.get("qLibraryId")]) for dd in qdims ],
            "dimLabels": [ ((dd.get("qDef", {}).get("qFieldLabels") or [None]) or [None])[0] for dd in qdims ],
            "dimNullSuppression": [ bool(dd.get("qNullSuppression")) for dd in qdims ],
            "measures":   [ (mm.get("qDef", {}).get("qDef") or mm.get("qLibraryId")) for mm in qmeas ],
            "measureLabels": [ mm.get("qDef", {}).get("qLabel") for mm in qmeas ],
            "measureFmts": [ (mm.get("qDef", {}).get("qNumFormat") or {}).get("qFmt") for mm in qmeas ],
            "sort": sort,
            # color encoding (byMeasure gradient / byDimension category) so the
            # builder can reproduce the Qlik chart's color, not default it.
            "color": props.get("color"),
            # reference lines (e.g. a "Margin Target" at x=0.45). refLinesX sit on
            # the X axis, refLines on the measure/Y axis. The builder emits Sigma
            # refMarks from these. value comes from refLineExpr.value (a constant)
            # or refLineExpr.label (an expression string).
            "refLines": _reflines(props.get("refLine") or {}),
        }
        # Filter objects (control-targeting wave): a listbox's field lives on
        # qListObjectDef (NOT the hypercube), and an alternate-state object
        # carries qStateName — the workbook builder turns these into Sigma list
        # controls (default state) or flags them manual (alternate state).
        if qtype == "listbox":
            lod = props.get("qListObjectDef") or {}
            ldef = lod.get("qDef") or {}
            meta = lb_meta.get(oid) or {}
            rec["listbox"] = {
                "field": (ldef.get("qFieldDefs") or [None])[0] or lod.get("qLibraryId")
                         or meta.get("field"),
                "label": (ldef.get("qFieldLabels") or [None])[0] or rec["title"]
                         or meta.get("label"),
                "state": lod.get("qStateName") or props.get("qStateName") or meta.get("state"),
                "tags": meta.get("tags") or [],
                "numFmt": meta.get("numFmt"),
            }
        elif qtype == "filterpane":
            rec["children"] = fp_children.get(oid, [])
            rec["state"] = props.get("qStateName")
        charts.append(rec)
    # Pane children that `app object ls` did NOT list as standalone objects:
    # synthesize their listbox records from the evaluated layouts so the
    # workbook builder still emits one control per pane field.
    for fid, kids in fp_children.items():
        for kid in kids:
            if kid in known_ids:
                continue
            meta = lb_meta.get(kid) or {}
            charts.append({"id": kid, "vizType": "listbox",
                           "title": meta.get("title"),
                           "sheet": obj_sheet.get(fid),
                           "dimensions": [], "dimLabels": [], "dimNullSuppression": [],
                           "measures": [], "measureLabels": [], "measureFmts": [],
                           "sort": {},
                           "listbox": {"field": meta.get("field"),
                                       "label": meta.get("label"),
                                       "state": meta.get("state"),
                                       "tags": meta.get("tags") or [],
                                       "numFmt": meta.get("numFmt")}})
    awrite(os.path.join(a.out, "charts.json"), charts)

    # converter input (feed the Qlik MODEL field names; simple dims are skipped by converter)
    CALC = re.compile(r'^=|\b(If|Sum|Count|Avg|Concat|Year|Month|Day|Left|Right|Upper|Lower|Trim)\s*\(', re.I)
    master_dims = [{"title": d["title"], "fieldDef": d["expr"]} for d in dims_raw if CALC.search(d["expr"] or "")]
    conv = {"appName": app_meta.get("name") or a.app, "tables": tables,
            "masterMeasures": [{"title": m["title"], "qDef": m["expr"]} for m in measures],
            "masterDimensions": master_dims}
    awrite(os.path.join(a.out, "converter-input.json"), conv)

    # engine snapshot — inline unless deferred (a --snapshot-only lane picks it up)
    snapshot = None
    if a.defer_snapshot:
        # ensure no STALE snapshot.json survives from a prior run — the
        # orchestrator polls for this file as the lane-completion signal.
        try:
            os.unlink(os.path.join(a.out, "snapshot.json"))
        except FileNotFoundError:
            pass
    else:
        with stage("snapshot"):
            snapshot = compute_snapshot(a.app, ctx, charts, tables, app_meta, a.pool, a.skip_eval)
        awrite(os.path.join(a.out, "snapshot.json"), snapshot)

    mode = "defer-snapshot" if a.defer_snapshot else "full"
    write_timings(a.out, mode, a.pool, n_objects=len(objs))

    on_sheet = sum(1 for c in charts if c["sheet"])
    print(f"tables={len(tables)} measures={len(measures)} dimensions={len(dims_raw)} "
          f"(calc={len(master_dims)}) charts={len(charts)} (on-sheet={on_sheet}) sheets={len(sheets)} -> {a.out}/")
    if snapshot and snapshot["kpis"]:
        print("snapshot:", "; ".join(f"{k['title']}={k['value']}" for k in snapshot["kpis"][:6]))
    elif a.defer_snapshot:
        print("snapshot: DEFERRED (run --snapshot-only as a concurrent lane; "
              "consumed at the Phase-6 freshness banner)")
    print(f"lastReloadTime={app_meta.get('lastReloadTime', '?')}")
    print(f"timing: {time.time() - T0:.1f}s wall (pool={a.pool}, retries={RETRIES['n']}; "
          f"per-stage breakdown in timings.json)")
    print("Next: scripts/migrate-qlik.rb runs the whole pipeline from this directory in one command.")

if __name__ == "__main__":
    main()
