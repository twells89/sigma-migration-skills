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
                        date-ish fact fields, per-chart bucket counts, and
                        evaluated hypercube rows — the app's IN-MEMORY values
                        used for strict chart parity
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qlik_load_script import parse_tables
from qlik_object_props import effective_chart_properties

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
    if out.returncode != 0:
        # Warn on ANY non-zero exit — including parse_json=False calls like the
        # load-script fetch, whose failure was previously swallowed silently.
        sys.stderr.write(f"WARN {' '.join(str(x) for x in args)} -> {((out.stderr or out.stdout) or '')[:200]}\n")
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


def _legend(props):
    """Normalize the authored legend fields the Sigma builder can preserve."""
    raw = props.get("legend")
    if not isinstance(raw, dict):
        return None
    show = raw.get("show")
    if show is None:
        show = raw.get("showLegend")
    dock = raw.get("dock") or raw.get("position")
    out = {}
    if show is not None:
        out["show"] = bool(show)
    if dock:
        out["dock"] = str(dock).lower()
    return out or None


def _presentation(props):
    """Normalize only released chart presentation fields; never copy CSS."""
    data_point = props.get("dataPoint") or {}
    bar_grouping = props.get("barGrouping") or {}
    orientation = props.get("orientation")
    grouping = props.get("grouping") or bar_grouping.get("grouping")
    show_labels = data_point.get("showLabels")
    if show_labels is None:
        show_labels = props.get("showLabels")
    out = {}
    if orientation:
        out["orientation"] = str(orientation).lower()
    if grouping:
        out["grouping"] = str(grouping).lower()
    if show_labels is not None:
        out["showLabels"] = bool(show_labels)
    line_type = props.get("lineType")
    if line_type:
        out["lineType"] = str(line_type).lower()
    donut = props.get("donut") or {}
    if isinstance(donut, dict) and donut.get("showAsDonut") is not None:
        out["showAsDonut"] = bool(donut["showAsDonut"])
    return out or None


def _combo_series(measure):
    """Return the authored Qlik combo-series type; absent means Qlik's bar default."""
    qdef = measure.get("qDef") or {}
    raw = measure.get("series") or qdef.get("series")
    if isinstance(raw, dict):
        raw = raw.get("type")
    raw = raw or measure.get("representation") or qdef.get("representation") or "bar"
    return "line" if str(raw).lower() == "line" else "bar"


def _content_fields(props, qtype):
    """Static Qlik content that must survive even though it has no hypercube."""
    if qtype != "text-image":
        return {}
    markdown = props.get("markdown")
    return {"markdown": markdown} if isinstance(markdown, str) and markdown.strip() else {}


def _gauge(props):
    """Normalize Qlik gauge value-range/presentation fields."""
    raw = props.get("gauge") or {}
    if not isinstance(raw, dict):
        raw = {}
    out = {}
    for key in ("min", "max"):
        value = raw.get(key)
        if value is None:
            value = props.get(key)
        if value is not None:
            out[key] = value
    shape = raw.get("shape") or raw.get("presentation") or props.get("shape")
    if shape:
        out["shape"] = shape
    return out or None


def _drill_groups(qdims):
    """Capture every authored Qlik drill hierarchy, not just its active level."""
    out = []
    for i, dd in enumerate(qdims):
        qdef = dd.get("qDef") or {}
        fields = [f for f in (qdef.get("qFieldDefs") or []) if f]
        if qdef.get("qGrouping") == "H" or len(fields) > 1:
            labels = qdef.get("qFieldLabels") or []
            out.append({"dimensionIndex": i, "fields": fields, "labels": labels})
    return out


def _container(props):
    """Best-effort Qlik container children + tab labels from engine properties."""
    content = props.get("content") or {}
    raw = props.get("children") or props.get("cells") or content.get("children") or []
    children, labels = [], []
    for child in raw:
        if isinstance(child, str):
            cid, label = child, None
        elif isinstance(child, dict):
            info = child.get("qInfo") or {}
            meta = child.get("qMeta") or child.get("qMetaDef") or {}
            cid = child.get("name") or child.get("id") or child.get("qId") or info.get("qId")
            label = child.get("label") or child.get("title") or meta.get("title")
        else:
            continue
        if cid:
            children.append(cid)
            labels.append(label)
    return children, labels


def _trellis_field(d):
    """Facet field from a Qlik trellis dimension def (string / qDef / libId)."""
    if isinstance(d, str):
        return d
    qd = (d or {}).get("qDef") or {}
    return (qd.get("qFieldDefs") or [None])[0] or (d or {}).get("qLibraryId") or (d or {}).get("field")


def _trellis_sig(props):
    """Best-effort: extract a NATIVE Qlik CHART-LEVEL trellis signal from an
    object's engine properties -> the converter-neutral
    {field, orientation, secondary?, label?}, or None when the object carries no
    trellis. The build path (build-sigma-workbook.py: emit_trellis) turns this
    into Sigma's native element `trellis` (rowsBy/columnsBy) via the shared
    TrellisEmit. Keys checked are `trellis` / `trellising` (the chart's
    Appearance>Trellis block). An enabled block names the facet dimension
    (qFieldDefs / qLibraryId) and, optionally, a 2nd dim + a rows/columns config
    -> a 2-D grid. Never raises; returns None on anything unrecognized so a
    non-trellis app's charts.json is byte-identical."""
    try:
        t = props.get("trellis") or props.get("trellising")
        if not isinstance(t, dict) or not t:
            return None
        if t.get("enabled") is False or t.get("show") is False:
            return None
        dims = t.get("dimensions") or t.get("qDimensions") or []
        field = _trellis_field(dims[0]) if dims else (t.get("field") or t.get("dimensionField"))
        if not field:
            return None
        sig = {"field": field}
        if t.get("orientation") in ("rows", "cols", "grid"):
            sig["orientation"] = t["orientation"]
        elif t.get("rows") and not t.get("columns"):
            sig["orientation"] = "rows"   # a fixed single column of stacked panels
        else:
            sig["orientation"] = "cols"   # Qlik wraps one trellis dim into a column grid
        sec = _trellis_field(dims[1]) if len(dims) > 1 else t.get("secondaryField")
        if sec:
            sig["secondary"] = sec
            sig["orientation"] = "grid"
        if t.get("label"):
            sig["label"] = t["label"]
        return sig
    except Exception:
        return None


def _trellis_container(props, hc):
    """Best-effort: a native Qlik TRELLIS-CONTAINER ("trellis container"/"grid
    container", qType sn-trellis-container) -> (child_ids, signal) so the build
    path emits ONE faceted element from the container's base child chart. The
    child chart id(s) come from `children` / `cells` / `qChildList`; the facet
    dimension comes from the container's own first hypercube dimension (or a
    `trellis`/`dimensions` block). Returns ([], None) when unrecognized."""
    try:
        kids = []
        for k in (props.get("children") or props.get("cells") or []):
            cid = k.get("name") if isinstance(k, dict) else k
            if cid:
                kids.append(cid)
        if not kids:
            cl = (props.get("qChildList") or {}).get("qItems") or []
            kids = [it.get("qInfo", {}).get("qId") for it in cl if it.get("qInfo", {}).get("qId")]
        sig = _trellis_sig(props)
        if sig is None:
            qdims = hc.get("qDimensions") or []
            field = _trellis_field(qdims[0].get("qDef")) if qdims else None
            if field:
                sig = {"field": field, "orientation": "cols"}
        return kids, sig
    except Exception:
        return [], None


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


# ---- load-script → final warehouse-backed tables/fields ----
def parse_script(qvs):
    return parse_tables(qvs)


def qlik_eval(app, ctx_args, expr):
    """Evaluate one expression via the engine (read-only). Returns the raw value string or None."""
    out = qlik_run(["app", "eval", expr, "-a", app, *ctx_args])
    lines = [l for l in out.stdout.splitlines() if l.strip()]
    return lines[1].strip() if out.returncode == 0 and len(lines) >= 2 else None


def qlik_chart_rows(app, ctx_args, chart):
    """Read one chart's evaluated hypercube rows through qlik-cli."""
    data = qlik(
        "app", "object", "data", str(chart.get("id")),
        "-a", app, *ctx_args, "--json",
    )

    def matrices(value):
        found = []
        if isinstance(value, dict):
            matrix = value.get("qMatrix")
            if isinstance(matrix, list):
                found.append(matrix)
            for child in value.values():
                found.extend(matrices(child))
        elif isinstance(value, list):
            for child in value:
                found.extend(matrices(child))
        return found

    def pivot_matrices(value):
        found = []
        if isinstance(value, dict):
            matrix = value.get("qData")
            if isinstance(matrix, list) and matrix and all(
                isinstance(row, list) for row in matrix
            ):
                found.append(matrix)
            for child in value.values():
                found.extend(pivot_matrices(child))
        elif isinstance(value, list):
            for child in value:
                found.extend(pivot_matrices(child))
        return found

    rows = []
    sizes = []
    areas = []

    def collect_sizes(value):
        if isinstance(value, dict):
            size = value.get("qSize")
            if isinstance(size, dict) and isinstance(size.get("qcy"), int):
                sizes.append(size["qcy"])
            area = value.get("qArea")
            if (
                isinstance(area, dict)
                and isinstance(area.get("qTop"), int)
                and isinstance(area.get("qHeight"), int)
            ):
                areas.append((area["qTop"], area["qHeight"]))
            for child in value.values():
                collect_sizes(child)
        elif isinstance(value, list):
            for child in value:
                collect_sizes(child)

    collect_sizes(data)
    dimension_count = len(chart.get("dimensions") or [])
    straight_matrices = matrices(data)
    pivot = not straight_matrices
    for matrix in straight_matrices or pivot_matrices(data):
        for raw_row in matrix:
            if not isinstance(raw_row, list):
                continue
            row = []
            for index, cell in enumerate(raw_row):
                if (
                    not isinstance(cell, dict)
                    or cell.get("qIsNull")
                    or cell.get("qType") == "U"
                ):
                    row.append(None)
                elif (pivot or index >= dimension_count) and isinstance(
                    cell.get("qNum"), (int, float)
                ):
                    row.append(cell["qNum"])
                else:
                    row.append(cell.get("qText"))
            rows.append(row)
    expected_rows = (
        max(sizes)
        if sizes
        else max((top + height for top, height in areas), default=None)
    )
    starts_at_zero = not areas or min(top for top, _height in areas) == 0
    return {
        "rows": rows,
        "complete": bool(
            rows
            and expected_rows is not None
            and len(rows) >= expected_rows
            and starts_at_zero
        ),
        "expectedRows": expected_rows,
        "pivot": pivot,
    }


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
    on-sheet KPI expression, Max() of date-ish fact fields, per-chart
    distinct-bucket counts, and complete evaluated hypercube rows — all against
    the app's IN-MEMORY data (cannot change without a reload, hence safely
    deferrable). All reads run through the shared pool."""
    snapshot = {"lastReloadTime": app_meta.get("lastReloadTime"),
                "kpis": [], "maxDates": [], "buckets": [], "chartData": []}
    if skip_eval:
        return snapshot

    kpi_jobs, seen = [], set()
    for c in charts:
        if not (c["sheet"] and c["measures"] and not c["dimensions"]):
            continue
        for index, expr in enumerate(c["measures"]):
            if not expr or expr in seen:
                continue
            seen.add(expr)
            labels = c.get("measureLabels") or []
            label = labels[index] if index < len(labels) else None
            kpi_jobs.append((expr, label or c.get("title") or expr))

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
    chart_jobs = [
        chart
        for chart in charts
        if chart.get("sheet")
        and chart.get("dimensions")
        and chart.get("measures")
    ]
    chart_values = pmap(
        lambda chart: qlik_chart_rows(app, ctx, chart),
        chart_jobs,
        pool,
    )
    for chart, result in zip(chart_jobs, chart_values):
        result = result or {}
        snapshot["chartData"].append({
            "objectId": chart.get("id"),
            "title": chart.get("title") or chart.get("id"),
            "dimensionCount": len(chart.get("dimensions") or []),
            "measureCount": len(chart.get("measures") or []),
            "rows": result.get("rows") or [],
            "complete": result.get("complete") is True,
            "expectedRows": result.get("expectedRows"),
            "pivot": result.get("pivot") is True,
        })
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
            out = qlik_run(["app", "script", "get", "-a", a.app, *ctx])
            results["script"] = out.stdout if out.returncode == 0 else ""
            results["script_error"] = None if out.returncode == 0 else ((out.stderr or out.stdout) or "unknown error").strip()[:200]

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

    # HARD FAIL if the load script — the data-model source of truth — is empty.
    # A silent empty script yields tables=0 and a Sigma data model with no data
    # (the "migration ran but produced nothing useful" failure). The usual cause
    # is GetScript "GENERIC ACCESS DENIED": the app is owned by another user /
    # unpublished and the connecting identity lacks read rights. DirectQuery apps
    # legitimately carry no load script, so they are exempt.
    if not script.strip() and not app_meta.get("isDirectQueryMode"):
        sys.stderr.write("\nFATAL: load script is empty — cannot build a data model (tables=0).\n")
        if results.get("script_error"):
            sys.stderr.write(f"  GetScript failed: {results['script_error']}\n")
        sys.stderr.write(
            "  The load script is the data-model source of truth; without it the converter\n"
            "  produces an empty model. Most common cause: the connecting identity cannot read\n"
            "  this app (owned by another user / unpublished -> 'GENERIC ACCESS DENIED').\n"
            "  Fix one of: (a) run discovery as the app OWNER, (b) copy/transfer the app so the\n"
            "  connecting identity owns it, or (c) publish it to a managed space that identity\n"
            "  can read. (DirectQuery apps have no script and are exempt.)\n")
        sys.exit(3)

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

    # Standard Qlik containers also keep their tabs in evaluated child lists on
    # some engine versions. Preserve that source composition signal so the
    # workbook builder can emit a real tabbed-container instead of flattening.
    container_ids = [o.get("qId") for o in objs if o.get("qType") == "container"]
    def _container_meta(cid):
        lay = qlik("app", "object", "layout", cid, "-a", a.app, *ctx) or {}
        kids, labels = _container(lay)
        if not kids:
            items = ((lay.get("qChildList") or {}).get("qItems")) or []
            kids, labels = _container({"children": items})
        return {"children": kids, "labels": labels}
    with stage("container-children"):
        container_meta = dict(zip(container_ids, pmap(_container_meta, container_ids, a.pool)))

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
        effective, effective_type = effective_chart_properties(props, qtype)
        hc = effective.get("qHyperCubeDef", {})
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
            "id": oid, "vizType": effective_type,
            "title": _resolve_title(effective, a.app, ctx) or _resolve_title(props, a.app, ctx),
            "sheet": obj_sheet.get(oid),
            "dimensions": [ (dd.get("qDef", {}).get("qFieldDefs") or [dd.get("qLibraryId")]) for dd in qdims ],
            "dimLabels": [ ((dd.get("qDef", {}).get("qFieldLabels") or [None]) or [None])[0] for dd in qdims ],
            "dimNullSuppression": [ bool(dd.get("qNullSuppression")) for dd in qdims ],
            "measures":   [ (mm.get("qDef", {}).get("qDef") or mm.get("qLibraryId")) for mm in qmeas ],
            "measureLabels": [ mm.get("qDef", {}).get("qLabel") for mm in qmeas ],
            "measureFmts": [
                ((mm.get("qNumFormat") or mm.get("qDef", {}).get("qNumFormat") or {}).get("qFmt"))
                for mm in qmeas
            ],
            "sort": sort,
            # color encoding (byMeasure gradient / byDimension category) so the
            # builder can reproduce the Qlik chart's color, not default it.
            "color": effective.get("color"),
            # reference lines (e.g. a "Margin Target" at x=0.45). refLinesX sit on
            # the X axis, refLines on the measure/Y axis. The builder emits Sigma
            # refMarks from these. value comes from refLineExpr.value (a constant)
            # or refLineExpr.label (an expression string).
            "refLines": _reflines(effective.get("refLine") or {}),
        }
        legend = _legend(effective)
        if legend:
            rec["legend"] = legend
        presentation = _presentation(effective)
        if presentation:
            rec["presentation"] = presentation
        if effective_type == "combochart":
            rec["seriesTypes"] = [_combo_series(measure) for measure in qmeas]
        rec.update(_content_fields(effective, effective_type))
        drills = _drill_groups(qdims)
        if drills:
            rec["drillGroups"] = drills
        if qtype == "gauge":
            gauge = _gauge(props)
            if gauge:
                rec["gauge"] = gauge
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
        elif qtype in ("sn-trellis-container", "trellis-container", "grid-container"):
            # Native trellis container: normalize to vizType "trellis-container"
            # (the build path's emit_trellis faceting shape) + carry the base
            # child chart id(s) and the facet signal.
            kids, tsig = _trellis_container(props, hc)
            rec["vizType"] = "trellis-container"
            rec["children"] = kids
            if tsig:
                rec["trellis"] = tsig
        elif qtype == "container":
            kids, labels = _container(props)
            if not kids:
                meta = container_meta.get(oid) or {}
                kids, labels = meta.get("children") or [], meta.get("labels") or []
            rec["children"] = kids
            rec["childLabels"] = labels
        else:
            # Chart-level native trellis (Appearance>Trellis): faceting one chart
            # into a panel grid. Only added when present -> byte-identical charts.json
            # for the (overwhelmingly common) non-trellis object.
            tsig = _trellis_sig(props)
            if tsig:
                rec["trellis"] = tsig
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
    print("Next: scripts/migrate-qlik.py runs the no-Ruby pipeline from this directory "
          "(migrate-qlik.rb remains supported).")

if __name__ == "__main__":
    main()
