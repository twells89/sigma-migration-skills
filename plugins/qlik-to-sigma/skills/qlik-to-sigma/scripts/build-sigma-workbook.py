#!/usr/bin/env python3
"""build-sigma-workbook — Phase 4 of qlik-to-sigma: author + POST the Sigma
workbook from the DISCOVERY artifacts (charts.json + layout.json + denorm.json).
No baked-in sheets, charts, or column lists — everything comes from the app.

    python3 build-sigma-workbook.py \
      --charts WORK/charts.json --layout WORK/layout.json --denorm WORK/denorm.json \
      --dm-id <dataModelId> --denorm-element-id <elementId> \
      --name "Retail Orders" [--folder <folderId>] \
      [--dry-run] [--out wb-result.json] [--spec-out wb-spec.json] \
      [--layout-out layout.xml] [--element-map element-map.json]

What it builds:
  - A hidden "Data" page with one master table (every denorm column) sourced
    from the data-model denorm element — the single source for every chart.
  - One Sigma page PER QLIK SHEET (layout.json order), each chart placed by
    mapping the Qlik sheet's cell grid (col/row/colspan/rowspan on a
    columns×rows grid, default 24×12) 1:1 onto Sigma's 24-col grid with a
    row-scale of 2 (min — so KPI titles and axis labels render; KPIs are
    bumped to ≥5 grid rows, the title-clip threshold).
  - Chart kinds from the Qlik vizType (barchart/linechart/piechart/combochart/
    table/kpi). `auto-chart` is resolved by shape: no dims → KPI; ≥2 dims →
    grouped table; 1 temporal dim → line; else bar.
  - Qlik measure expressions are translated token-wise (Sum/Avg/Min/Max/Count,
    Count(DISTINCT …) → CountDistinct, simple Set Analysis {<F={v}>} →
    Sum(If(...)), arithmetic combinations like Sum(a)/Sum(b)). Untranslatable
    charts are skipped + reported (gap-scout them).
  - Qlik qNumFormat → Sigma formatString ($#,##0 → $,.0f, #0.0% → ,.1%, …).
  - Qlik's associative model hides unmatched/null dimension rows
    (qNullSuppression). Faithful default: a hidden Not(IsNull(dim)) bool col +
    include-[true] list filter per suppressed dim. QLIK_KEEP_UNMATCHED=1 keeps
    the null rows instead (warehouse-faithful).
  - Sorts: an explicit Qlik sort (qSortCriterias / qSortBy / interColumnSortOrder)
    wins; else tables + bar charts default to first-measure-descending (Qlik's
    auto-chart behavior). Grouped-table sort nests INSIDE groupings[0].sort —
    element-level sort 400s on grouped tables (verified 2026-06-10).

Outputs: wb-result.json {workbookId, pages, elements, skipped}, layout XML
(multi-<Page> fragment for put-layout.rb), element-map.json (Sigma element ↔
Qlik object, incl. dims/measures — feeds the Phase-6 freshness + bucket parity).
With --dry-run nothing is POSTed.

Env (live mode): SIGMA_BASE_URL + SIGMA_API_TOKEN.
"""
import json, os, re, sys, time, argparse, urllib.request

MASTER_ID, MASTER = "m-master", "Master"
_SCATTER_SRC = []   # hidden grouped source tables emitted for scatter-charts (added to the Data page)
KEEP_UNMATCHED = os.environ.get("QLIK_KEEP_UNMATCHED", "") == "1"
ROW_SCALE = 2          # min row-scale; Qlik rows are ~3x shorter than Sigma's
KPI_MIN_ROWS = 5       # Sigma kpi-chart clips its title below ~5 grid rows
TEMPORAL = re.compile(r"DATE|MONTH|YEAR|QUARTER|WEEK|DAY", re.I)
NATIVE = {"barchart": "bar-chart", "linechart": "line-chart", "piechart": "pie-chart",
          "combochart": "combo-chart", "scatterplot": "scatter-chart",
          "table": "table", "kpi": "kpi-chart", "pivot-table": "pivot-table",
          "map": "region-map"}

_ids = {}
def nid(prefix):
    _ids[prefix] = _ids.get(prefix, 0) + 1
    return f"{prefix}{_ids[prefix]}"

def api_post(path, body):
    BASE = os.environ["SIGMA_BASE_URL"]; TOK = os.environ["SIGMA_API_TOKEN"]
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": "Bearer " + TOK, "Content-Type": "application/json",
                 "Accept": "application/json"})
    for attempt in range(6):
        try:
            return urllib.request.urlopen(req).read().decode()
        except urllib.error.HTTPError as e:
            detail = e.read().decode()
            if e.code == 429 and attempt < 5:  # Cloudflare 1015 rate limit: transient, retryable
                wait = min(120, 30 * (2 ** attempt))
                print(f"HTTP 429 on POST {path} -- backing off {wait}s (attempt {attempt+1}/6)", file=sys.stderr)
                time.sleep(wait)
                continue
            print("HTTP", e.code, detail[:800], file=sys.stderr); raise

def sigma_fmt(qfmt, name=""):
    """Qlik qNumFormat.qFmt -> Sigma formatString. Falls back to a name heuristic."""
    if qfmt:
        dec = 0
        if "." in qfmt:
            dec = len(re.sub(r"[^0#]", "", qfmt.split(".", 1)[1]))
        if "%" in qfmt: return {"kind": "number", "formatString": f",.{dec}%"}
        pre = "$" if qfmt.lstrip().startswith("$") else ""
        return {"kind": "number", "formatString": f"{pre},.{dec}f"}
    if re.search(r"%|margin|rate", name, re.I): return {"kind": "number", "formatString": ",.1%"}
    if re.search(r"revenue|profit|amount|value|cost|price", name, re.I):
        return {"kind": "number", "formatString": "$,.0f"}
    return {"kind": "number", "formatString": ",.0f"}

class Resolver:
    """Raw Qlik field name -> master-column display name (via the denorm element)."""
    def __init__(self, denorm_cols):
        self.raw_to_disp = {}
        for dn, raw in denorm_cols:
            self.raw_to_disp[raw.upper()] = dn
            self.raw_to_disp[dn.upper().replace(" ", "_")] = dn
    def __call__(self, qlik_name):
        if not qlik_name: return None
        k = str(qlik_name).upper()
        return self.raw_to_disp.get(k) or self.raw_to_disp.get(k.replace(" ", "_"))

def translate_measure(expr, resolve):
    """Qlik measure expression -> Sigma formula over the master, or None.
    Token-wise: handles aggregates, Count(DISTINCT), simple Set Analysis, and
    arithmetic combinations of those (Sum(a)/Sum(b), Sum(a)/Count(DISTINCT b))."""
    e = str(expr or "").strip().lstrip("=").strip()
    if not e: return None
    unresolved = []
    def ref(f):
        d = resolve(f)
        if d is None: unresolved.append(f)
        return f"[{MASTER}/{d}]"
    def set_analysis(m):
        agg, cf, op, vals_raw, xf = (m.group(1).capitalize(), m.group(2),
                                     m.group(3), m.group(4), m.group(5))
        conds = []
        for val in (v.strip() for v in vals_raw.split(",")):
            val = val.strip("'\"")
            if not val or re.search(r"[*?<>=$()]", val):
                # search mask / $(var) / operator inside the set: no clean
                # row-wise equivalent -- flag instead of emitting wrong semantics
                unresolved.append(vals_raw); return m.group(0)
            lit = val if re.fullmatch(r"-?\d+(\.\d+)?", val) else f'"{val}"'
            conds.append(f"{ref(cf)} {'<>' if op == '-=' else '='} {lit}")
        cond = (" and " if op == "-=" else " or ").join(conds)
        if len(conds) > 1: cond = f"({cond})"
        inner = f"If({cond}, {ref(xf)})"
        return f"CountDistinct({inner})" if agg == "Count" and m.group(0).upper().find("DISTINCT") >= 0 \
            else f"{agg}({inner})"
    # 1) simple Set Analysis  Agg({<F={v,...}>} [DISTINCT] X)  (also F-={...} exclusion)
    e = re.sub(r"\b(Sum|Avg|Min|Max|Count)\s*\(\s*\{\s*<\s*([A-Za-z0-9_]+)\s*(-?=)\s*\{([^}]*)\}\s*>\s*\}\s*(?:DISTINCT\s+)?([A-Za-z0-9_]+)\s*\)",
               set_analysis, e, flags=re.I)
    # 2) Count(DISTINCT X)
    e = re.sub(r"\bCount\s*\(\s*DISTINCT\s+([A-Za-z0-9_]+)\s*\)",
               lambda m: f"CountDistinct({ref(m.group(1))})", e, flags=re.I)
    # 3) plain Agg(FIELD)
    e = re.sub(r"\b(Sum|Avg|Min|Max|Count)\s*\(\s*([A-Za-z0-9_]+)\s*\)",
               lambda m: f"{m.group(1).capitalize()}({ref(m.group(2))})", e, flags=re.I)
    if unresolved: return None
    # anything left that looks like a bare Qlik field/function = untranslated
    leftovers = re.sub(r'"[^"]*"|\[[^\]]*\]|\b(?:CountDistinct|Sum|Avg|Min|Max|Count|If|and|or)\b', "", e)
    if re.search(r"[A-Za-z_]{2,}", leftovers): return None
    return e

def date_field(info, raw):
    """Date-typed Qlik field? Engine layout tags ($date/$timestamp) are
    authoritative; the qNumFormat date pattern and the raw warehouse column
    name are fallbacks. Matters because a Sigma `list` control whose filter
    target is a datetime column posts fine but Sigma SILENTLY STRIPS the
    target (estate-repair gotcha) — date fields need date-range controls."""
    tags = [str(t).lower() for t in (info.get("tags") or [])]
    if "$date" in tags or "$timestamp" in tags: return True
    if "$text" in tags: return False              # tagged, and tagged non-date
    fmt = (info.get("numFmt") or "").upper()
    if re.search(r"[DMY]{2,}[-./ ]", fmt): return True
    return bool(re.search(r"(^|_)(DATE|DT|TIMESTAMP)(_|$)", str(raw or "").upper()))

def build_control(lb, resolve, mcol_id, raw_of, warnings, scope, unbound, seen_fields):
    """One Qlik listbox (standalone or filterpane child) -> one Sigma control
    (control-targeting wave, workstream B). Qlik's associative model is GLOBAL:
    any field selection filters every chart on every sheet. Every chart in this
    workbook sources the single master table, so ONE filter entry on the master
    propagates to all of them across all pages (the proven shape:
    filters:[{source:{kind:table, elementId}, columnId}]) — exactly the Qlik
    semantics; the sidecar asserts it via mustReach over every queryable
    element on every page (filled after page assembly). Date-typed fields
    become date-range controls (list-on-datetime targets get silently
    stripped). Alternate-state listboxes have no Sigma equivalent: recorded in
    the sidecar's `unbound` as MANUAL, never silently dropped. Returns the
    element or None."""
    info = lb.get("listbox") or {}
    field = info.get("field")
    state = info.get("state")
    label = info.get("label") or lb.get("title") or field
    sig = f"{lb['vizType']} {lb['id']} field {field!r}"
    if not field:
        warnings.append(f"control '{lb['id']}': listbox has no field — skipped")
        unbound.append({"sourceName": sig, "status": "unbound", "reason": "listbox has no field"})
        return None
    if state and state != "$":
        warnings.append(f"control '{label}' (field {field}): ALTERNATE STATE '{state}' — "
                        "Sigma has no alternate-state equivalent; flagged MANUAL (not emitted)")
        unbound.append({"sourceName": sig, "status": "manual",
                        "reason": f"alternate state '{state}' has no Sigma equivalent — port by hand "
                                  "(e.g. duplicated charts + a dedicated control) if the analysis needs it"})
        return None
    if field in seen_fields:
        # the same field filters globally — a second listbox on it (another
        # sheet's filterpane) is the SAME control; Sigma controlIds are unique.
        unbound.append({"sourceName": sig, "status": "duplicate",
                        "reason": f"same field as control '{seen_fields[field]}' — one global Sigma "
                                  "control already covers every sheet (Qlik associative semantics)"})
        return None
    dn = resolve(field)
    if dn is None or dn not in mcol_id:
        warnings.append(f"control '{label}': field '{field}' not on the denorm element — "
                        "skipped (resolve the field and wire manually)")
        unbound.append({"sourceName": sig, "status": "unbound",
                        "reason": f"field '{field}' does not resolve to a denorm-element column; "
                                  "dropped loudly rather than wired to a wrong column or shipped dead"})
        return None
    cid = mcol_id[dn]
    ctl_id = re.sub(r"[^A-Za-z0-9]", "", str(dn).title()) + "Filter"
    seen_fields[field] = ctl_id
    el = {"id": "el-" + re.sub(r"[^a-z0-9]", "", str(lb["id"]).lower()),
          "kind": "control", "controlId": ctl_id, "name": label or dn,
          "filters": [{"source": {"kind": "table", "elementId": MASTER_ID}, "columnId": cid}]}
    if date_field(info, raw_of.get(dn)):
        # date-range needs no `source` (the column comes from the filter
        # binding) but DOES require a flat `mode` — without it the POST fails
        # with the misleading "Invalid kind: control" (live-verified 2026-06-12;
        # the widget shape is picked by mode, see sigma-workbooks controls.md).
        el.update({"controlType": "date-range", "mode": "between",
                   "includeNulls": "when-no-value-is-selected"})
    else:
        el.update({"controlType": "list", "mode": "include", "selectionMode": "multiple",
                   "values": [],
                   "source": {"kind": "source",
                              "source": {"kind": "table", "elementId": MASTER_ID}, "columnId": cid}})
    # CONTRACT entry (lib/control_lint.rb header): scope "page" covers the
    # same-page reach check; mustReach (every queryable element id on every
    # page, filled after assembly) makes the lint statically assert Qlik's
    # GLOBAL associative reach.
    scope.append({"controlId": ctl_id, "sourceName": sig, "status": "wired",
                  "controlType": el["controlType"], "scope": "page", "mustReach": [],
                  "wired": [{"elementId": MASTER_ID, "columnId": cid}]})
    return el

def control_subcell(cell, i, n):
    """Split a filterpane's sheet cell among its N child listbox controls —
    vertically when the pane is taller than wide, else horizontally."""
    if n <= 1:
        return cell
    if cell.get("rowspan", 1) >= cell.get("colspan", 1):
        h = cell["rowspan"] / n
        return {**cell, "row": cell["row"] + i * h, "rowspan": h}
    w = cell["colspan"] / n
    return {**cell, "col": cell["col"] + i * w, "colspan": w}

def qlik_sort(c, dim_ids, meas_ids):
    """Explicit Qlik sort -> (columnId, direction) or None."""
    s = c.get("sort") or {}
    order = s.get("interColumnSortOrder") or []
    ndims = len(dim_ids)
    for idx in order:
        if idx < ndims and idx < len(s.get("dimensions", [])):
            crit = (s["dimensions"][idx] or [{}])[0] if s["dimensions"][idx] else {}
            if crit.get("qSortByNumeric") in (1, -1):
                return dim_ids[idx], "ascending" if crit["qSortByNumeric"] == 1 else "descending"
            if crit.get("qSortByAscii") in (1, -1):
                return dim_ids[idx], "ascending" if crit["qSortByAscii"] == 1 else "descending"
        elif idx >= ndims and (idx - ndims) < len(meas_ids):
            mb = (s.get("measures") or [{}] * len(meas_ids))[idx - ndims] or {}
            if mb.get("qSortByNumeric") in (1, -1):
                return meas_ids[idx - ndims], "ascending" if mb["qSortByNumeric"] == 1 else "descending"
    return None

# Qlik measure color schemes -> Sigma `scheme` arrays (low->high). 'dg'/'dc' are
# Qlik's diverging palettes, 'sg'/'sc' the sequential ones; reverseScheme flips.
QLIK_MSCHEME = {
    "dg": ["#a50026", "#f46d43", "#fee090", "#74add1", "#313695"],  # diverging red->blue
    "dc": ["#a50026", "#f46d43", "#fee090", "#74add1", "#313695"],
    "sg": ["#ffffcc", "#fd8d3c", "#bd0026"],                        # sequential
    "sc": ["#ffffcc", "#fd8d3c", "#bd0026"],
}

def qlik_color(color, dim_ids, mids, el):
    """Map a Qlik chart color encoding to a Sigma `color` channel, or None.
    byMeasure -> color:{by:scale} on a DUPLICATE measure column (a column can't
    be on both yAxis and color); byDimension -> color:{by:category} on the dim."""
    c = color or {}
    mode = c.get("mode")
    if mode == "byMeasure" and mids:
        scheme = list(QLIK_MSCHEME.get(c.get("measureScheme"), QLIK_MSCHEME["sg"]))
        if c.get("reverseScheme"): scheme.reverse()
        base = next((col for col in el["columns"] if col["id"] == mids[0]), None)
        if not base: return None
        cid = nid("clr")
        dup = {"id": cid, "formula": base["formula"], "name": base["name"] + " (color)"}
        if base.get("format"): dup["format"] = base["format"]
        el["columns"].append(dup)
        return {"by": "scale", "column": cid, "scheme": scheme}
    if mode in ("byDimension", "byExpression") and dim_ids:
        return {"by": "category", "column": dim_ids[0]}
    return None

def qlik_refmarks(c):
    """Qlik reference lines -> Sigma refMarks. X-axis lines -> axis 'axis',
    measure/Y lines -> 'series'. value MUST be the wrapped {type:formula,...}
    form (a bare number 400s); label.visibility must be 'shown'. Verified
    2026-06-15."""
    rl = c.get("refLines") or {}
    out = []
    for axis, key in (("axis", "x"), ("series", "y")):
        for r in (rl.get(key) or []):
            if r.get("show") is False:
                continue
            val = r.get("value")
            formula = str(val) if isinstance(val, (int, float)) else (r.get("expr") or "")
            if not formula:
                continue
            rm = {"type": "line", "axis": axis,
                  "value": {"type": "formula", "formula": formula},
                  "line": {"color": r.get("color") or "#ef4444", "width": 2}}
            if r.get("label"):
                rm["label"] = {"visibility": "shown", "text": r["label"]}
            out.append(rm)
    return out

def build_element(c, resolve, warnings):
    """One Qlik chart object -> one Sigma element (or None + warning)."""
    title = c.get("title") or c.get("vizType")
    dims_raw = [(d[0] if isinstance(d, list) else d) for d in (c.get("dimensions") or [])]
    dim_disp = [resolve(d) for d in dims_raw]
    labels = c.get("dimLabels") or [None] * len(dims_raw)
    nsup = c.get("dimNullSuppression") or [True] * len(dims_raw)
    mexprs = c.get("measures") or []
    mlabels = c.get("measureLabels") or [None] * len(mexprs)
    mfmts = c.get("measureFmts") or [None] * len(mexprs)

    # kind
    vt = c.get("vizType")
    if vt == "auto-chart":
        if not dims_raw and mexprs: kind = "kpi-chart"
        elif len(dims_raw) >= 2:    kind = "table"
        elif dims_raw and TEMPORAL.search(dims_raw[0] or ""): kind = "line-chart"
        else: kind = "bar-chart"
    else:
        kind = NATIVE.get(vt)
        if kind is None:
            if not (dims_raw and mexprs):
                warnings.append(f"skip '{title}' ({vt}): no native Sigma kind"); return None
            kind = "bar-chart"
            warnings.append(f"'{title}' ({vt}) approximated as bar-chart")

    if dims_raw and any(d is None for d in dim_disp):
        warnings.append(f"skip '{title}': dim(s) {dims_raw} not on the denorm element"); return None

    cols, mids, mnames = [], [], []
    for i, mexpr in enumerate(mexprs):
        f = translate_measure(mexpr, resolve)
        if f is None:
            warnings.append(f"'{title}': measure not translated: {mexpr}")
            continue
        mname = mlabels[i] or (title if kind == "kpi-chart" else f"Measure {i+1}")
        cid = nid("y")
        cols.append({"id": cid, "formula": f, "name": mname, "format": sigma_fmt(mfmts[i], mname)})
        mids.append(cid); mnames.append(mname)
    if not mids:
        warnings.append(f"skip '{title}': no translatable measures"); return None

    el = {"id": "el-" + re.sub(r"[^a-z0-9]", "", str(c["id"]).lower()),
          "kind": kind, "name": title,
          "source": {"elementId": MASTER_ID, "kind": "table"}}

    if kind == "kpi-chart":
        el["columns"] = cols
        el["value"] = {"columnId": mids[0]}   # value.columnId, NOT value.id (live API 400s)
        return el

    dim_ids = []
    for i, d in enumerate(dim_disp):
        cid = nid("x")
        cols.insert(i, {"id": cid, "formula": f"[{MASTER}/{d}]", "name": labels[i] or d})
        dim_ids.append(cid)
    el["columns"] = cols

    # associative-model null suppression (per suppressed dim)
    filters = []
    if not KEEP_UNMATCHED:
        for i, d in enumerate(dim_disp):
            if not nsup[i]: continue
            b = nid("nn")
            hidden_col = {"id": b, "formula": f"Not(IsNull([{MASTER}/{d}]))",
                          "name": f"{labels[i] or d} Matched"}
            if kind == "table": hidden_col["hidden"] = True
            el["columns"].append(hidden_col)
            filters.append({"id": nid("f"), "columnId": b, "kind": "list",
                            "mode": "include", "values": [True]})
    if filters: el["filters"] = filters

    sort = qlik_sort(c, dim_ids, mids)
    if sort is None and kind in ("table", "bar-chart") and mids:
        sort = (mids[0], "descending")   # Qlik auto-chart default: by measure, desc

    if kind == "table":
        # Aggregating table needs explicit groupings or it renders 1 row/source row
        el["groupings"] = [{"id": nid("g"), "groupBy": dim_ids, "calculations": mids}]
        if sort: el["groupings"][0]["sort"] = [{"columnId": sort[0], "direction": sort[1]}]
        return el
    if kind == "region-map":
        # Qlik map layer dim -> Sigma region-map; only emit when the region
        # grain is recognizable (else flag, never guess a wrong regionType)
        dname = (dims_raw[0] or "").upper()
        rtype = "us-state" if "STATE" in dname else ("country" if "COUNTRY" in dname else None)
        if rtype is None:
            warnings.append(f"skip '{title}' (map): region grain '{dims_raw[0]}' not recognized (us-state/country)")
            return None
        el["region"] = {"id": dim_ids[0], "regionType": rtype}
        el["color"] = {"by": "scale", "column": mids[0]}
        return el
    if kind == "pivot-table":
        # cross-tab: first dim -> rowsBy, remaining dims -> columnsBy,
        # measures -> values (bare column-id strings; rowsBy/columnsBy = {id})
        el["values"] = mids
        el["rowsBy"] = [{"id": dim_ids[0]}]
        if len(dim_ids) > 1:
            el["columnsBy"] = [{"id": d} for d in dim_ids[1:]]
        return el
    if kind == "pie-chart":
        el["value"] = {"id": mids[0]}; el["color"] = {"id": dim_ids[0]}
        el["dataLabel"] = {"labels": "shown"}
        return el
    if kind == "combo-chart":
        y = [mids[0]] + [{"columnId": m, "type": "line"} for m in mids[1:]]
        el["xAxis"] = {"columnId": dim_ids[0]}; el["yAxis"] = {"columnIds": y}
        return el
    if kind == "scatter-chart":
        # A Qlik scatterplot is measure-vs-measure with the dimension as the POINT
        # identity (Qlik measure order = x, y, size). Sigma's scatter axis is a
        # GROUPING axis: putting an aggregate (Sum(...)) directly on xAxis makes it
        # evaluate per-row and every point collapses to one x — the spec POSTs but
        # renders wrong (bead ry0n; verified 2026-06-15 — 64 rep points vs 1).
        # Correct, UI-verified shape: bind the scatter to a hidden grouped SOURCE
        # table (one row per point dim) and reference the grouped columns with raw
        # refs; the dim stays on color:{by:category} so points don't merge.
        if len(mids) >= 2 and dim_ids:
            cname = {col["id"]: col["name"] for col in el["columns"]}
            src_id = el["id"] + "-src"
            src_name = "Scatter Source " + re.sub(r"[^A-Za-z0-9]", "", str(c["id"]))[-6:]
            grp_id = src_id + "-g"
            src = {"id": src_id, "kind": "table", "name": src_name,
                   "source": {"elementId": MASTER_ID, "kind": "table"},
                   "columns": el["columns"],
                   "groupings": [{"id": grp_id, "groupBy": dim_ids, "calculations": mids}],
                   "visibleAsSource": False}
            if el.get("filters"): src["filters"] = el["filters"]   # carry null-suppression
            _SCATTER_SRC.append(src)
            def _raw(colid):
                return {"id": el["id"] + "-" + colid, "formula": f"[{src_name}/{cname[colid]}]",
                        "name": cname[colid]}
            s_dim, s_x, s_y = _raw(dim_ids[0]), _raw(mids[0]), _raw(mids[1])
            scols = [s_dim, s_x, s_y]
            sc = {"id": el["id"], "kind": "scatter-chart", "name": title,
                  "source": {"elementId": src_id, "kind": "table", "groupingId": grp_id},
                  "xAxis": {"columnId": s_x["id"]}, "yAxis": {"columnIds": [s_y["id"]]},
                  "color": {"by": "category", "column": s_dim["id"]}}
            if len(mids) >= 3:
                s_sz = _raw(mids[2]); scols.append(s_sz); sc["size"] = {"id": s_sz["id"]}
            sc["columns"] = scols
            rm = qlik_refmarks(c)
            if rm: sc["refMarks"] = rm   # e.g. a Margin Target line at x=0.45
            return sc
        # <2 measures or no dim: fall back to a plain dim-on-x cartesian
        el["xAxis"] = {"columnId": dim_ids[0] if dim_ids else mids[0]}
        el["yAxis"] = {"columnIds": mids}
        return el
    # bar / line
    el["xAxis"] = {"columnId": dim_ids[0]}
    el["yAxis"] = {"columnIds": mids}
    if sort: el["xAxis"]["sort"] = {"by": sort[0], "direction": sort[1]}
    if kind == "bar-chart": el["dataLabel"] = {"labels": "shown"}
    cc = qlik_color(c.get("color"), dim_ids, mids, el)
    if cc: el["color"] = cc
    rm = qlik_refmarks(c)
    if rm: el["refMarks"] = rm
    return el

# ---- container-banded layout (layout-playbook.md, verified 2026-06-10) -----
# Spec side: a `kind: container` placeholder element per band (+ a header text
# element). Layout side: <GridContainer> (NOT <LayoutElement type="grid">,
# which silently drops children) wrapping <LayoutElement>s whose coordinates
# are CONTAINER-RELATIVE (rows restart at 1).
HEADER_STYLE = {"backgroundColor": "#0F172A", "borderRadius": "round"}
HEADER_ROWS = 3

def _le(eid, c0, c1, r0, r1):
    return f'  <LayoutElement elementId="{eid}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>'

def _gc(cid, c0, c1, r0, r1, inner):
    return (f'<GridContainer elementId="{cid}" type="grid" gridColumn="{c0} / {c1}" '
            f'gridRow="{r0} / {r1}" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto">\n{inner}\n</GridContainer>')

def _cluster_bands(items):
    """Cluster [eid,c0,c1,r0,r1] items into horizontal bands by row overlap."""
    bands = []
    for it in sorted(items, key=lambda i: (i[3], i[1])):
        if bands and it[3] < bands[-1]["r1"]:
            bands[-1]["items"].append(it)
            bands[-1]["r1"] = max(bands[-1]["r1"], it[4])
        else:
            bands.append({"r0": it[3], "r1": it[4], "items": [it]})
    return [b["items"] for b in bands]

def _collide(a, b):
    """Two items collide when their column AND row ranges both overlap."""
    return a[1] < b[2] and b[1] < a[2] and a[3] < b[4] and b[3] < a[4]

def _decollide_bands(bands):
    """De-overlap each band. Sigma's grid has NO z-order, so two items sharing
    a cell (e.g. a Qlik listbox floated on top of a chart) render stacked on
    each other. When any pair in a band overlaps in BOTH axes, tile that band's
    items edge-to-edge across the full grid width at the band's row range.
    Collision-free bands are returned untouched (clean geometry preserved)."""
    out = []
    for band in bands:
        if not any(_collide(band[i], band[j])
                   for i in range(len(band)) for j in range(i + 1, len(band))):
            out.append(band); continue
        r0 = min(i[3] for i in band); r1 = max(i[4] for i in band)
        n = len(band)
        out.append([[it[0], 1 + round(24 * j / n), 1 + round(24 * (j + 1) / n), r0, r1]
                    for j, it in enumerate(sorted(band, key=lambda i: (i[1], i[3])))])
    return out

def banded_page(page_id, items, title, id_prefix=None):
    """Header band + one full-width GridContainer per row band, children
    container-relative. Returns (page_xml, extra_spec_elements)."""
    pfx = id_prefix or f"band-{page_id}"
    extra, children = [], []
    offset = 0
    if title:
        hdr, txt = f"{pfx}-hdr", f"{pfx}-hdrtext"
        extra.append({"id": hdr, "kind": "container", "style": dict(HEADER_STYLE)})
        extra.append({"id": txt, "kind": "text",
                      "body": f'# <span style="color: #FFFFFF">{title}</span>'})
        children.append(_gc(hdr, 1, 25, 1, 1 + HEADER_ROWS, _le(txt, 1, 25, 1, 1 + HEADER_ROWS)))
        offset = HEADER_ROWS
    if items:
        offset += 1 - min(i[3] for i in items)  # first band starts under the header
    for n, band in enumerate(_decollide_bands(_cluster_bands(items)), 1):
        cid = f"{pfx}-{n}"
        extra.append({"id": cid, "kind": "container"})
        r0 = min(i[3] for i in band); r1 = max(i[4] for i in band)
        inner = "\n".join(_le(i[0], i[1], i[2], i[3] - r0 + 1, i[4] - r0 + 1) for i in band)
        children.append(_gc(cid, 1, 25, r0 + offset, r1 + offset, inner))
    body = "\n".join(children)
    return (f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto" id="{page_id}">\n{body}\n</Page>', extra)

def grid_layout(page_id, sheet, placed):
    """Map the Qlik sheet cell grid onto Sigma's 24-col grid, then wrap each
    cell-grid row in a band container (relative proportions preserved).

    Controls (Qlik listboxes/filterpanes) are LIFTED out of their floating cell
    coords into a clean full-width band at the top: Qlik's associative model
    floats filters ON TOP of charts, and Sigma's grid has no z-order, so
    preserving those coords renders filters stacked over charts. Charts/KPIs
    keep their relative geometry below the controls band; _decollide_bands in
    banded_page is the final safety net for any chart-on-chart overlap.
    Returns (page_xml, extra_spec_elements)."""
    qcols = sheet.get("columns") or 24
    ctls, charts = [], []
    for cell, el in placed:
        c0 = round(cell["col"] * 24 / qcols) + 1
        c1 = round((cell["col"] + cell["colspan"]) * 24 / qcols) + 1
        # control_subcell splits a filterpane cell fractionally — round to grid
        r0 = int(round(cell["row"] * ROW_SCALE)) + 1
        r1 = int(round((cell["row"] + cell["rowspan"]) * ROW_SCALE)) + 1
        if el["kind"] == "kpi-chart" and (r1 - r0) < KPI_MIN_ROWS:
            r1 = r0 + KPI_MIN_ROWS
        if el["kind"] == "control":
            ctls.append(el["id"])            # float-over-chart coords discarded
        else:
            charts.append([el["id"], c0, c1, r0, r1])
    items, row = [], 1
    if ctls:
        n = len(ctls)
        for i, eid in enumerate(ctls):
            cc0 = 1 + round(24 * i / n); cc1 = 1 + round(24 * (i + 1) / n)
            items.append([eid, cc0, cc1, row, row + 3])
        row += 3
    if charts:
        shift = row - min(c[3] for c in charts)   # drop charts below the controls band
        items += [[c[0], c[1], c[2], c[3] + shift, c[4] + shift] for c in charts]
    return banded_page(page_id, items, sheet.get("title"))

def auto_layout(page_id, elems, title=None):
    """Fallback when no layout.json: header band, controls band, KPI strip band,
    then chart rows 2-wide — each a container. Returns (page_xml, extra_spec_elements)."""
    ctls = [e for e in elems if e["kind"] == "control"]
    kpis = [e for e in elems if e["kind"] == "kpi-chart"]
    charts = [e for e in elems if e["kind"] not in ("kpi-chart", "control")]
    items, row = [], 1
    if ctls:
        w = 24 // len(ctls)
        for i, e in enumerate(ctls):
            c0 = 1 + i * w; c1 = c0 + w if i < len(ctls) - 1 else 25
            items.append([e["id"], c0, c1, row, row + 3])
        row += 3
    if kpis:
        w = 24 // len(kpis)
        for i, e in enumerate(kpis):
            c0 = 1 + i * w; c1 = c0 + w if i < len(kpis) - 1 else 25
            items.append([e["id"], c0, c1, row, row + 5])
        row += 5
    for i in range(0, len(charts), 2):
        pair = charts[i:i + 2]
        for j, e in enumerate(pair):
            c0 = 1 if j == 0 else 13; c1 = 13 if (j == 0 and len(pair) > 1) else 25
            items.append([e["id"], c0, c1, row, row + 11])
        row += 11
    return banded_page(page_id, items, title or "Overview")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--charts", required=True)
    ap.add_argument("--layout")
    ap.add_argument("--denorm", required=True)
    ap.add_argument("--dm-id", required=True)
    ap.add_argument("--denorm-element-id", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--folder")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--out", default="wb-result.json")
    ap.add_argument("--spec-out", default="wb-spec.json")
    ap.add_argument("--layout-out", default="layout.xml")
    ap.add_argument("--element-map", default="element-map.json")
    ap.add_argument("--control-scope-out", default=None,
                    help="intended-scope contract for the control lint "
                         "(default: control-scope.json next to --spec-out)")
    a = ap.parse_args()

    charts = {c["id"]: c for c in json.load(open(a.charts))}

    # Resolve master-item LIBRARY IDS (md-*/mm-*) on chart hypercubes: charts
    # that use a master dimension/measure carry only its qLibraryId; substitute
    # the master item's expr (and default the label to its title) so the chart
    # builds instead of skipping with "not on the denorm element".
    workdir = os.path.dirname(os.path.abspath(a.charts))
    def _master(fname):
        fp = os.path.join(workdir, fname)
        items = json.load(open(fp)) if os.path.exists(fp) else []
        return {it["id"]: it for it in items if isinstance(it, dict) and it.get("id")}
    mdims, mmeas = _master("dimensions.json"), _master("measures.json")
    for c in charts.values():
        dims = c.get("dimensions") or []
        dlabels = c.get("dimLabels") or [None] * len(dims)
        for i, d in enumerate(dims):
            hit = mdims.get(d[0] if isinstance(d, list) else d)
            if hit:
                dims[i] = [hit["expr"]]
                if i < len(dlabels) and not dlabels[i]: dlabels[i] = hit["title"]
        if dims: c["dimLabels"] = dlabels
        meas = c.get("measures") or []
        mlabels = c.get("measureLabels") or [None] * len(meas)
        for i, mx in enumerate(meas):
            hit = mmeas.get(mx) if isinstance(mx, str) else None
            if hit:
                meas[i] = hit["expr"]
                if i < len(mlabels) and not mlabels[i]: mlabels[i] = hit["title"]
        if meas: c["measureLabels"] = mlabels
    sheets = json.load(open(a.layout)) if a.layout and os.path.exists(a.layout) else []
    denorm = json.load(open(a.denorm))["element"]
    denorm_cols = [(c["name"], (re.search(r"\[Custom SQL/(.+)\]", c["formula"]) or [None, c["name"]])[1])
                   for c in denorm["columns"]]
    resolve = Resolver(denorm_cols)

    master = {"id": MASTER_ID, "name": MASTER, "kind": "table",
              "source": {"dataModelId": a.dm_id, "elementId": a.denorm_element_id, "kind": "data-model"},
              "columns": [{"id": f"o{i}", "name": dn, "formula": f"[Custom SQL/{dn}]"}
                          for i, (dn, _raw) in enumerate(denorm_cols)]}

    warnings, pages, layout_pages, emap = [], [], [], []
    layout_pages.append(f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-data">\n'
                        f'  <LayoutElement elementId="{MASTER_ID}" gridColumn="1 / 25" gridRow="1 / 15"/>\n</Page>')
    pages.append({"id": "page-data", "name": "Data", "elements": [master]})

    CHARTY = {"kpi", "auto-chart", "barchart", "linechart", "piechart", "combochart",
              "scatterplot", "table", "pivot-table"}
    # master column id / raw warehouse column per display name — control
    # source/filter targets + date-typed detection fallback
    mcol_id = {dn: f"o{i}" for i, (dn, _raw) in enumerate(denorm_cols)}
    raw_of = {dn: raw for dn, raw in denorm_cols}
    scope, unbound, seen_fields, n_controls, n_signals = [], [], {}, 0, 0

    def controls_for(c):
        """Filterpane -> one control per child listbox; bare listbox -> one."""
        if c["vizType"] == "filterpane":
            lbs = [charts.get(ch) for ch in (c.get("children") or [])]
            lbs = [lb for lb in lbs if lb]
            if not lbs:
                warnings.append(f"filterpane '{c.get('title') or c['id']}': no child listboxes "
                                "discovered — no controls emitted")
                unbound.append({"sourceName": f"filterpane {c['id']}", "status": "unbound",
                                "reason": "no child listboxes discovered"})
            for lb in lbs:  # a pane-level alternate state applies to its children
                if c.get("state") and not (lb.get("listbox") or {}).get("state"):
                    lb.setdefault("listbox", {})["state"] = c["state"]
        else:
            lbs = [c]
        return [el for el in (build_control(lb, resolve, mcol_id, raw_of, warnings,
                                            scope, unbound, seen_fields)
                              for lb in lbs) if el]

    if sheets:
        for si, sheet in enumerate(sheets):
            pid = f"pg-{si + 1}"
            elems, placed = [], []
            for cell in sorted(sheet["cells"], key=lambda c: (c["row"], c["col"])):
                c = charts.get(cell["objectId"])
                if c is None: continue
                if c["vizType"] in ("filterpane", "listbox"):
                    n_signals += 1
                    ctls = controls_for(c)
                    for i, ctl in enumerate(ctls):
                        elems.append(ctl)
                        placed.append((control_subcell(cell, i, len(ctls)), ctl))
                    n_controls += len(ctls)
                    continue
                if c["vizType"] not in CHARTY and not (c.get("measures") or c.get("dimensions")):
                    warnings.append(f"skip '{cell['objectId']}' ({c['vizType']}): not a chart"); continue
                el = build_element(c, resolve, warnings)
                if el is None: continue
                elems.append(el); placed.append((cell, el))
                emap.append({"elementId": el["id"], "pageId": pid, "kind": el["kind"],
                             "name": el["name"], "valueColumnName": el["columns"][0].get("name"),
                             "qlik": {"objectId": c["id"],
                                      "dims": [(d[0] if isinstance(d, list) else d) for d in (c.get("dimensions") or [])],
                                      "measures": c.get("measures") or [],
                                      "nullSuppression": c.get("dimNullSuppression") or []}})
            if not elems: continue
            xml, extra = grid_layout(pid, sheet, placed)
            pages.append({"id": pid, "name": sheet["title"], "elements": elems + extra})
            layout_pages.append(xml)
    else:
        # no sheet layout discovered — build every dim+measure chart, auto-layout;
        # filterpanes/listboxes still become controls (top band). Children of a
        # filterpane are skipped standalone (the pane emits them).
        pid, elems = "pg-1", []
        child_ids = {ch for c in charts.values() if c["vizType"] == "filterpane"
                     for ch in (c.get("children") or [])}
        for c in charts.values():
            if c["vizType"] == "filterpane" or (c["vizType"] == "listbox" and c["id"] not in child_ids):
                n_signals += 1
                ctls = controls_for(c)
                elems.extend(ctls)
                n_controls += len(ctls)
                continue
            if not (c.get("measures")): continue
            el = build_element(c, resolve, warnings)
            if el is None: continue
            elems.append(el)
            emap.append({"elementId": el["id"], "pageId": pid, "kind": el["kind"],
                         "name": el["name"], "valueColumnName": el["columns"][0].get("name"),
                         "qlik": {"objectId": c["id"],
                                  "dims": [(d[0] if isinstance(d, list) else d) for d in (c.get("dimensions") or [])],
                                  "measures": c.get("measures") or [],
                                  "nullSuppression": c.get("dimNullSuppression") or []}})
        xml, extra = auto_layout(pid, [{"id": e["id"], "kind": e["kind"]} for e in elems])
        pages.append({"id": pid, "name": "Overview", "elements": elems + extra})
        layout_pages.append(xml)

    # Scatter charts emit a hidden grouped SOURCE table (one row per point dim);
    # park them on the Data page next to the master (visibleAsSource:False, so
    # they need no layout slot). build_element appended them to _SCATTER_SRC.
    if _SCATTER_SRC:
        data_page = next((p for p in pages if p["id"] == "page-data"), pages[0])
        data_page["elements"].extend(_SCATTER_SRC)

    spec = {"name": a.name, "schemaVersion": 1, "pages": pages}
    if a.folder: spec["folderId"] = a.folder
    json.dump(spec, open(a.spec_out, "w"), indent=2)
    open(a.layout_out, "w").write('<?xml version="1.0" encoding="utf-8"?>\n' + "\n".join(layout_pages))
    json.dump(emap, open(a.element_map, "w"), indent=2)
    # control-scope.json — the intended-scope contract sidecar (schema: the
    # CONTRACT block in scripts/lib/control_lint.rb + refs/control-parity.md).
    # Qlik selections are GLOBAL (associative model), so every wired control
    # gets mustReach = every queryable element on EVERY content page — the
    # lint then statically asserts the global reach, not just same-page.
    # sourceFilterSignals counts the source app's filter objects (filterpanes
    # + standalone listboxes; pane children are part of their pane's signal) —
    # >0 with zero spec controls FAILS gate 7 (the silently-dropped class this
    # change exists to kill).
    QUERYABLE = {"table", "pivot-table", "bar-chart", "line-chart", "pie-chart",
                 "donut-chart", "area-chart", "scatter-chart", "combo-chart",
                 "kpi-chart", "region-map", "point-map"}
    must = [e["id"] for p in pages if p["id"] != "page-data"
            for e in p["elements"] if e.get("kind") in QUERYABLE]
    for sc in scope:
        if sc.get("status") == "wired":
            sc["mustReach"] = must
    scope_path = a.control_scope_out or os.path.join(
        os.path.dirname(os.path.abspath(a.spec_out)), "control-scope.json")
    json.dump({"version": 1, "source": "qlik", "sourceFilterSignals": n_signals,
               "controls": scope, "unbound": unbound},
              open(scope_path, "w"), indent=2)

    n_elem = sum(len(p["elements"]) for p in pages) - 1
    result = {"workbookId": None, "pages": len(pages), "elements": n_elem,
              "kpis": sum(1 for e in emap if e["kind"] == "kpi-chart"),
              "controls": n_controls, "controlScope": scope_path,
              "warnings": warnings, "layoutFile": a.layout_out, "elementMap": a.element_map}
    if a.dry_run:
        print(f"DRY RUN: spec -> {a.spec_out} ({len(pages)} pages, {n_elem} elements)", file=sys.stderr)
    else:
        res = api_post("/v2/workbooks/spec", spec)
        try:
            wb = json.loads(res).get("workbookId")
        except json.JSONDecodeError:
            m = re.search(r"workbookId:\s*(\S+)", res)
            wb = m.group(1) if m else None
        if not wb: sys.exit(f"FATAL: workbook POST returned no id: {res[:300]}")
        result["workbookId"] = wb
    for w in warnings: print("   WARN:", w, file=sys.stderr)
    json.dump(result, open(a.out, "w"), indent=2)
    print(json.dumps(result))

if __name__ == "__main__":
    main()
