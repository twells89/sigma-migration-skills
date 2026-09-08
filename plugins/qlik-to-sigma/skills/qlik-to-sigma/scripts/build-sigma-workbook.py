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
  - Chart kinds from the complete documented Qlik vizType catalog, with loud
    explicit approximations where Sigma has no equivalent. `auto-chart` is
    resolved by shape: no dims → KPI; ≥2 dims → grouped table; 1 temporal dim
    → line; else bar.
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
Also writes workbook-coverage.json and refuses to POST (or pass a dry run) when
there are zero queryable elements or any authored queryable source visual was
not rebuilt. With --dry-run nothing is POSTed.

Env (live mode): SIGMA_BASE_URL + SIGMA_API_TOKEN.
"""
import json, os, re, sys, time, argparse, urllib.request

MASTER_ID, MASTER = "m-master", "Master"
_SCATTER_SRC = []   # hidden grouped source tables emitted for scatter-charts (added to the Data page)
KEEP_UNMATCHED = os.environ.get("QLIK_KEEP_UNMATCHED", "") == "1"
ROW_SCALE = 2          # min row-scale; Qlik rows are ~3x shorter than Sigma's
KPI_MIN_ROWS = 5       # Sigma kpi-chart clips its title below ~5 grid rows
TEMPORAL = re.compile(r"DATE|MONTH|YEAR|QUARTER|WEEK|DAY", re.I)
# ── documentation-grounded mapping catalogs (SINGLE SOURCE OF TRUTH) ─────────
# viz/aggregation/control maps are LOADED from refs/catalogs/<dimension>.json —
# cited rows, live-verified Sigma targets, loud fallback on anything unmapped.
# NO inline mapping literal may bypass these (grep-enforced by tests/test_grounding.py).
# The human-readable matrix in refs/qlik-coverage.md is GENERATED from these files.
# Loader: shared/lib/coverage_catalog.py (synced to scripts/lib/). Mirrors the
# beads-sigma-93ps contract: catalog = data, code = thin resolver/predicates.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import coverage_catalog as _cc  # noqa: E402
import trellis_emit as _te      # noqa: E402  shared native-trellis emitter (supported-kind gate + fallbacks)
import metric_binding as _mb    # noqa: E402  shared DM-metric binder ([Metrics/<name>] over inline re-derive)
import code_rep as _cr          # noqa: E402  workbook code-rep document-wrapper adapter (nested POST shape)

# Native-trellis round-trip sidecar records (element_id/kind/name/axis/columnId).
# Populated by emit_trellis; written to native-trellis-emitted.json ONLY when a
# trellis was actually emitted — a non-trellis app stays byte-identical (no file).
# Sigma silently STRIPS an unsupported trellis on readback, so verify-trellis-
# survived.rb re-reads the posted spec and asserts each of these survived.
_TRELLIS_RECORDS = []
_CAT_DIR = _cc.default_catalog_dir(__file__)
VIZ_CAT  = _cc.load(_CAT_DIR, "viz-kind")       # Qlik vizType     -> Sigma element kind
AGG_CAT  = _cc.load(_CAT_DIR, "aggregation")    # Qlik agg fn      -> Sigma aggregate fn
CTRL_CAT = _cc.load(_CAT_DIR, "control")        # Qlik field kind  -> Sigma control kind
FEATURE_CAT = _cc.load(_CAT_DIR, "workbook-feature")  # composition / interaction surfaces
# number-format is COMPOSITIONAL (sigma_fmt parses the qNumFormat mask); its
# catalog (refs/catalogs/number-format.json) pins the parser to documented
# examples via tests/test_grounding.py rather than a flat lookup.

# Qlik vizType -> Sigma element kind (auto-chart resolved by shape in build_element).
NATIVE = {r["source"]: r["sigma"] for r in VIZ_CAT.rows}
# Qlik aggregation fn -> Sigma aggregate fn (token-wise in translate_measure). The
# recognized non-distinct fns drive the regex alternation; Count(DISTINCT) is separate.
_AGG_TO_SIGMA = {r["source"]: r["sigma"] for r in AGG_CAT.rows}
_AGG_ALT = "|".join(sorted(r["source"] for r in AGG_CAT.rows if r["source"] != "count_distinct"))
def _agg_sigma(qlik_fn):
    return _AGG_TO_SIGMA.get(str(qlik_fn).lower(), str(qlik_fn).capitalize())

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

def sigma_fmt(qfmt, name="", warnings=None):
    """Qlik qNumFormat.qFmt (an Excel-style mask) -> Sigma format object, or None.
    PARSER ONLY: a leading '$' -> currency, '%' -> percent, and the count of 0/#
    after '.' -> decimals (qNumFormat grammar:
    help.qlik.com/.../Scripting/FormattingFunctions/Num.htm; mapping pinned by
    refs/catalogs/number-format.json + tests/test_grounding.py).
    An ABSENT qFmt yields None — ship the numeric value UNFORMATTED + a loud note.
    The old name-substring currency guess (revenue|profit|... -> $,.0f) and the
    silent ,.0f default were REMOVED (beads-sigma-kvza): no judgement-based guessing."""
    if qfmt:
        dec = 0
        if "." in qfmt:
            dec = len(re.sub(r"[^0#]", "", qfmt.split(".", 1)[1]))
        if "%" in qfmt: return {"kind": "number", "formatString": f",.{dec}%"}
        pre = "$" if qfmt.lstrip().startswith("$") else ""
        return {"kind": "number", "formatString": f"{pre},.{dec}f"}
    if warnings is not None and name:
        warnings.append(f"⚠ number-format: measure '{name}' has no Qlik qNumFormat — shipped "
                        f"UNFORMATTED (no name-substring currency guess, no silent default). "
                        f"Apply a Sigma column format if a specific display is needed.")
    return None

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
        agg, cf, op, vals_raw, xf = (_agg_sigma(m.group(1)), m.group(2),
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
        _cd = _AGG_TO_SIGMA.get("count_distinct", "CountDistinct")
        return f"{_cd}({inner})" if agg == _agg_sigma("count") and m.group(0).upper().find("DISTINCT") >= 0 \
            else f"{agg}({inner})"
    # aggregation function names + Sigma targets come from refs/catalogs/aggregation.json
    _cd = _AGG_TO_SIGMA.get("count_distinct", "CountDistinct")
    # 1) simple Set Analysis  Agg({<F={v,...}>} [DISTINCT] X)  (also F-={...} exclusion)
    e = re.sub(r"\b(" + _AGG_ALT + r")\s*\(\s*\{\s*<\s*([A-Za-z0-9_]+)\s*(-?=)\s*\{([^}]*)\}\s*>\s*\}\s*(?:DISTINCT\s+)?([A-Za-z0-9_]+)\s*\)",
               set_analysis, e, flags=re.I)
    # 2) Count(DISTINCT X)
    e = re.sub(r"\bCount\s*\(\s*DISTINCT\s+([A-Za-z0-9_]+)\s*\)",
               lambda m: f"{_cd}({ref(m.group(1))})", e, flags=re.I)
    # 3) plain Agg(FIELD)
    e = re.sub(r"\b(" + _AGG_ALT + r")\s*\(\s*([A-Za-z0-9_]+)\s*\)",
               lambda m: f"{_agg_sigma(m.group(1))}({ref(m.group(2))})", e, flags=re.I)
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
    # control kind is documentation-grounded (refs/catalogs/control.json): a
    # date-typed field -> date-range, everything else -> the documented `list`
    # default. date_field() (engine tags/format/name) is the cited predicate.
    _ctype = CTRL_CAT.target("date") if date_field(info, raw_of.get(dn)) else CTRL_CAT.target("field")
    if _ctype == "date-range":
        # date-range needs no `source` (the column comes from the filter
        # binding) but DOES require a flat `mode` — without it the POST fails
        # with the misleading "Invalid kind: control" (live-verified 2026-06-12;
        # the widget shape is picked by mode, see sigma-workbooks controls.md).
        el.update({"controlType": _ctype, "mode": "between",
                   "includeNulls": "when-no-value-is-selected"})
    else:
        el.update({"controlType": _ctype, "mode": "include", "selectionMode": "multiple",
                   "values": [],
                   "source": {"kind": "source",
                              "source": {"kind": "table", "elementId": MASTER_ID}, "columnId": cid}})
    # CONTRACT entry (lib/control_lint.rb header): scope "page" covers the
    # same-page reach check; mustReach (every queryable element id on every
    # page, filled after assembly) makes the lint statically assert Qlik's
    # GLOBAL associative reach.
    scope.append({"controlId": ctl_id, "sourceName": sig, "status": "wired",
                  "controlType": el["controlType"], "scope": "page", "mustReach": [],
                  "synthesized": bool(lb.get("_synth")),
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
QLIK_PRIMARY = "#4477AA"
QLIK_SINGLE = {3: "#BDBDBD"}

def qlik_color(color, dim_ids, mids, el):
    """Map a Qlik chart color encoding to a Sigma `color` channel, or None.
    byMeasure -> color:{by:scale} on a DUPLICATE measure column (a column can't
    be on both yAxis and color); byDimension -> color:{by:category} on the dim."""
    c = color or {}
    mode = c.get("mode")
    if mode == "primary":
        literal = c.get("color") or (c.get("paletteColor") or {}).get("color")
        return {"by": "single", "value": literal or QLIK_PRIMARY}
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
    if mode == "byDimension" and dim_ids:
        base = next((col for col in el["columns"] if col["id"] == dim_ids[0]), None)
        if not base: return None
        cid = nid("clr")
        el["columns"].append({"id": cid, "formula": base["formula"],
                              "name": base["name"] + " (color)"})
        return {"by": "category", "column": cid}
    if mode == "byExpression":
        literal = c.get("singleColor")
        if isinstance(literal, str) and literal.startswith("#"):
            return {"by": "single", "value": literal}
        return {"by": "single", "value": QLIK_SINGLE.get(literal, "#BDBDBD")}
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
            raw_color = r.get("color")
            line_color = raw_color if isinstance(raw_color, str) else ({2: "#46C646"}.get(raw_color))
            rm = {"type": "line", "axis": axis,
                  "value": {"type": "formula", "formula": formula},
                  "line": {"color": line_color or "#EF4444", "width": 2}}
            if r.get("label"):
                rm["label"] = {"visibility": "shown", "text": r["label"]}
            out.append(rm)
    return out


def apply_presentation(el, c):
    """Apply only Qlik presentation fields with released Sigma equivalents."""
    legend = c.get("legend")
    chart_kind = el.get("kind", "").endswith("-chart") or el.get("kind") in {
        "region-map", "point-map", "geography-map"
    }
    if chart_kind and isinstance(legend, dict):
        out = {}
        show = legend.get("show")
        if show is False:
            out["visibility"] = "hidden"
        dock = str(legend.get("dock") or "").lower()
        if show is not False and dock in ("top", "bottom", "left", "right"):
            out["position"] = dock
        elif show is True:
            out["visibility"] = "shown"
        if out:
            el["legend"] = out

    presentation = c.get("presentation") or {}
    if el.get("kind") == "bar-chart":
        grouping = str(presentation.get("grouping") or "").lower()
        if grouping in ("stacked", "stack"):
            el["stacking"] = "stacked"
        elif grouping in ("normalized", "stacked100", "100%"):
            el["stacking"] = "normalized"
        elif grouping in ("grouped", "clustered") and len(el.get("yAxis", {}).get("columnIds", [])) > 1:
            # The live API accepts "none" only when there are multiple series;
            # single-series grouped bars are represented by omitting stacking.
            el["stacking"] = "none"
    if presentation.get("showLabels") is not None and el.get("kind", "").endswith("-chart"):
        el["dataLabel"] = {
            "labels": "shown" if presentation.get("showLabels") else "hidden"
        }
    return el

# ---- native trellis (small multiples) — detection + emission ---------------
# Qlik has TWO trellis shapes, both of which faithfully become Sigma's NATIVE
# element `trellis` (ONE viz element + rowsBy/columnsBy facet — NOT N cloned
# charts):
#   (a) CHART-LEVEL trellis — a chart (bar/line/area/combo/…) whose properties
#       carry a trellis dimension that splits the one chart into a panel grid.
#       qlik-discover records this as chart["trellis"].
#   (b) TRELLIS-CONTAINER object — a native "trellis container"/"grid container"
#       whose single child chart is repeated per member of a facet dimension.
#       Recorded as vizType "trellis-container"/"sn-trellis-container" with the
#       base chart in children[] and the facet in ["trellis"].
# The discovered signal is converter-neutral:
#   chart["trellis"] = {"field": <qlik dim def / libId>, "orientation":
#                       "rows"|"cols"|"grid", "secondary": <optional 2nd dim>,
#                       "label": <optional axis label>}
# EMISSION is delegated to the shared TrellisEmit (supported-kind gate + the
# pie->donut / kpi->siblings / pivot->shelves / table->flat fallbacks) — no
# per-tool trellis logic. When a chart carries NO trellis signal every function
# here is a no-op, so a non-trellis app builds BYTE-IDENTICAL to before.
_TRELLIS_KINDS = ("trellis-container", "sn-trellis-container")

def trellis_child_ids(charts):
    """Object ids that are the BASE child of some trellis-container — they are
    emitted THROUGH their container (one faceted element), never standalone."""
    return {ch for ct in charts.values() if ct.get("vizType") in _TRELLIS_KINDS
            for ch in (ct.get("children") or [])}

def trellis_base(c, charts, warnings):
    """A Qlik trellis-CONTAINER -> its base child chart carrying the container's
    facet signal, so the normal build path emits ONE faceted element. A plain
    chart (container or not) is returned unchanged. Returns None to skip."""
    if c.get("vizType") not in _TRELLIS_KINDS:
        return c
    base = next((charts.get(k) for k in (c.get("children") or []) if charts.get(k)), None)
    if base is None:
        warnings.append(f"trellis-container '{c.get('title') or c['id']}': no base child chart "
                        "discovered — skipped (nothing to facet)")
        return None
    b = json.loads(json.dumps(base))        # don't mutate the shared charts record
    b["id"] = c["id"]                        # keep the container's layout slot + element id
    if c.get("title"): b["title"] = c["title"]
    b["trellis"] = c.get("trellis") or base.get("trellis")   # container facet wins
    return b

def emit_trellis(el, c, resolve, warnings):
    """Attach Sigma's native `trellis` to a built element from the Qlik trellis
    signal, via the shared TrellisEmit. No-op (byte-identical) when the chart has
    no signal. Records the emit for the readback survival guard."""
    sig = c.get("trellis")
    if not isinstance(sig, dict) or not sig:
        return
    field = sig.get("field")
    dn = resolve(field) if field else None
    if not dn:
        warnings.append(f"trellis on '{el.get('name')}': facet field {field!r} not on the denorm "
                        "element — chart left un-trellised (flat), not faceted on a wrong column")
        return
    kind = el.get("kind")
    # Scatter's Qlik shape sources a HIDDEN grouped table (not the master), so a
    # bare [Master/<facet>] facet column would dangle — defer it loudly.
    if el.get("source", {}).get("elementId") != MASTER_ID:
        warnings.append(f"trellis on '{el.get('name')}' ({kind}): base element sources a derived "
                        "table (e.g. scatter's grouped source) — native trellis DEFERRED (facet the "
                        "grouped source by hand); chart left flat")
        return
    # Supported-kind gate lives ONCE in TrellisEmit. Unsupported kinds strip the
    # key silently on readback → take the documented fallback (leave flat).
    if not _te.trellises(kind):
        follow = ("N sibling KPIs is the correct faceted shape" if kind == "kpi-chart"
                  else "pivot uses its own rowsBy/columnsBy shelves" if kind == "pivot-table"
                  else "no native table trellis")
        warnings.append(f"trellis on '{el.get('name')}': base kind '{kind}' does NOT support a native "
                        f"trellis (Sigma strips the key on readback) — left FLAT ({follow})")
        return
    if kind == "pie-chart":
        warnings.append(f"trellis on '{el.get('name')}': base is a PIE — converted to DONUT "
                        "(pie silently strips the trellis key on readback; donut supports it) before faceting")
    # Add the facet dimension as a column (reuse an existing column of the same
    # display name if the chart already plots it).
    el.setdefault("columns", [])
    facet_col = next((col for col in el["columns"]
                      if str(col.get("name", "")).strip().casefold() == str(dn).strip().casefold()), None)
    if facet_col is None:
        facet_col = {"id": nid("tr"), "name": sig.get("label") or dn, "formula": f"[{MASTER}/{dn}]"}
        el["columns"].append(facet_col)
    ids = facet_col["id"]
    orientation = sig.get("orientation") or "cols"
    # A secondary facet field -> a true 2-D grid (rowsBy × columnsBy).
    sec = sig.get("secondary")
    if sec:
        sdn = resolve(sec)
        if sdn:
            scol = {"id": nid("tr"), "name": sdn, "formula": f"[{MASTER}/{sdn}]"}
            el["columns"].append(scol)
            ids = [facet_col["id"], scol["id"]]
            orientation = "grid"
        else:
            warnings.append(f"trellis on '{el.get('name')}': secondary facet {sec!r} not on the "
                            "denorm element — emitted a single-axis trellis (no 2-D grid)")
    _te.apply(el, ids, orientation)          # sets el['trellis'] (or flips pie->donut)
    axis_key = next(iter(el["trellis"].keys()))
    _TRELLIS_RECORDS.append({"element_id": el["id"], "kind": el["kind"], "name": el.get("name"),
                             "axis": axis_key, "columnId": facet_col["id"]})
    warnings.append(f"native trellis: '{el.get('name')}' -> ONE {el['kind']} element with "
                    f"trellis.{axis_key} (orientation={orientation}, facet column {facet_col['id']})")

def build_element(c, resolve, warnings, metrics=None):
    """One Qlik chart object -> one Sigma element (or None + warning). `metrics`
    (DM metrics referenceable on the master) lets a measure bind to a governed
    [Metrics/<name>] reference; None/empty keeps every measure inline."""
    title = c.get("title") or c.get("vizType")
    dims_raw = [(d[0] if isinstance(d, list) else d) for d in (c.get("dimensions") or [])]
    dim_disp = [resolve(d) for d in dims_raw]
    labels = c.get("dimLabels") or [None] * len(dims_raw)
    nsup = c.get("dimNullSuppression") or [True] * len(dims_raw)
    mexprs = c.get("measures") or []
    if c.get("vizType") == "histogram" and not mexprs and dims_raw:
        # Qlik histograms have one numeric dimension and calculate frequency
        # implicitly. Sigma has no histogram/bin shelf, so retain the frequency
        # signal as a loud per-value bar approximation rather than dropping it.
        mexprs = [f"Count({dims_raw[0]})"]
    mlabels = c.get("measureLabels") or [None] * len(mexprs)
    mfmts = c.get("measureFmts") or [None] * len(mexprs)
    for drill in (c.get("drillGroups") or []):
        fields = drill.get("fields") or []
        if len(fields) > 1:
            warnings.append(
                f"'{title}': Qlik drill hierarchy {' > '.join(fields)} keeps active level "
                f"'{fields[0]}' only; MANUAL GAP — Sigma hierarchy controls require "
                "validated hierarchy metadata and cannot safely be synthesized from chart fields")

    # kind
    vt = c.get("vizType")
    if vt == "auto-chart":
        if not dims_raw and mexprs: kind = "kpi-chart"
        elif len(dims_raw) >= 2:    kind = "table"
        elif dims_raw and TEMPORAL.search(dims_raw[0] or ""): kind = "line-chart"
        else: kind = "bar-chart"
    else:
        mapping = VIZ_CAT.resolve(vt)
        kind = mapping.get("sigma") if mapping else None
        if kind is None:
            if not (dims_raw and mexprs):
                warnings.append(f"skip '{title}' ({vt}): no native Sigma kind"); return None
            kind = "bar-chart"
            warnings.append(f"'{title}' ({vt}) approximated as bar-chart")
        elif mapping.get("approximation"):
            warnings.append(f"'{title}' ({vt}) EXPLICIT APPROXIMATION: {mapping.get('notes')}")

    presentation = c.get("presentation") or {}
    if vt == "piechart" and presentation.get("showAsDonut"):
        kind = "donut-chart"
    elif vt == "linechart" and presentation.get("lineType") == "area":
        kind = "area-chart"
    elif vt == "combochart" and c.get("seriesTypes") and set(c["seriesTypes"]) == {"bar"}:
        # Sigma normalizes an all-bar combo back to bar+line on readback.
        # A multi-series bar chart preserves the Qlik rendering exactly.
        kind = "bar-chart"
    elif vt == "combochart" and c.get("seriesTypes") and set(c["seriesTypes"]) == {"line"}:
        kind = "line-chart"
    if kind == "bar-chart" and presentation.get("orientation") == "horizontal":
        warnings.append(
            f"'{title}' (barchart) HORIZONTAL ORIENTATION GAP: current Sigma workbook "
            "spec rejects bar-chart.orientation; emitted the valid default vertical orientation")

    if dims_raw and any(d is None for d in dim_disp):
        warnings.append(f"skip '{title}': dim(s) {dims_raw} not on the denorm element"); return None

    cols, mids, mnames = [], [], []
    for i, mexpr in enumerate(mexprs):
        f = translate_measure(mexpr, resolve)
        if f is None:
            warnings.append(f"'{title}': measure not translated: {mexpr}")
            continue
        # Prefer a governed [Metrics/<name>] ref when this inline aggregate matches a
        # DM metric by formula equivalence; safe no-op (inline) otherwise.
        f = _mb.metric_ref_or_inline(f, MASTER, metrics)
        mname = mlabels[i] or (title if kind == "kpi-chart" else f"Measure {i+1}")
        cid = nid("y")
        _mcol = {"id": cid, "formula": f, "name": mname}
        _fmt = sigma_fmt(mfmts[i], mname, warnings)
        if _fmt: _mcol["format"] = _fmt
        cols.append(_mcol)
        mids.append(cid); mnames.append(mname)
    if not mids:
        warnings.append(f"skip '{title}': no translatable measures"); return None

    el = {"id": "el-" + re.sub(r"[^a-z0-9]", "", str(c["id"]).lower()),
          "kind": kind, "name": title,
          "source": {"elementId": MASTER_ID, "kind": "table"}}

    if kind == "progress":
        gauge = c.get("gauge") or {}
        progress = {"id": el["id"], "kind": "progress", "name": title,
                    "mode": "value", "value": cols[0]["formula"]}
        for key, default in (("min", "0"), ("max", "100")):
            progress[key] = str(gauge.get(key, default))
        shape = str(gauge.get("shape") or gauge.get("presentation") or "").lower()
        progress["shape"] = "ring" if shape in ("ring", "circular", "radial") else "bar"
        return progress

    if kind == "kpi-chart":
        el["columns"] = cols
        el["value"] = {"columnId": mids[0]}   # value.columnId, NOT value.id (live API 400s)
        return apply_presentation(el, c)

    if not dims_raw:
        warnings.append(f"skip '{title}' ({vt}): released {kind} mapping requires a dimension")
        return None

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
    if sort is None and kind in ("table", "bar-chart", "line-chart", "area-chart", "combo-chart") and mids:
        sort = (mids[0], "descending")   # Qlik auto-chart default: by measure, desc

    if kind == "table":
        # Aggregating table needs explicit groupings or it renders 1 row/source row
        el["groupings"] = [{"id": nid("g"), "groupBy": dim_ids, "calculations": mids}]
        if sort: el["groupings"][0]["sort"] = [{"columnId": sort[0], "direction": sort[1]}]
        return apply_presentation(el, c)
    if kind == "region-map":
        # Qlik map layer dim -> Sigma region-map; only emit when the region
        # grain is recognizable (else flag, never guess a wrong regionType)
        dname = (dims_raw[0] or "").upper()
        rtype = "us-state" if "STATE" in dname else ("country" if "COUNTRY" in dname else None)
        if rtype is None:
            warnings.append(f"skip '{title}' (map): region grain '{dims_raw[0]}' not recognized (us-state/country)")
            return None
        el["region"] = {"columnId": dim_ids[0], "regionType": rtype}
        el["color"] = {"by": "scale", "column": mids[0]}
        return apply_presentation(el, c)
    if kind == "pivot-table":
        # cross-tab: first dim -> rowsBy, remaining dims -> columnsBy,
        # measures -> values (bare column-id strings; shelves use {columnId})
        el["values"] = mids
        el["rowsBy"] = [{"columnId": dim_ids[0]}]
        if len(dim_ids) > 1:
            el["columnsBy"] = [{"columnId": d} for d in dim_ids[1:]]
        return apply_presentation(el, c)
    if kind in ("pie-chart", "donut-chart"):
        el["value"] = {"columnId": mids[0]}; el["color"] = {"columnId": dim_ids[0]}
        el["dataLabel"] = {"labels": "shown"}
        return apply_presentation(el, c)
    if kind == "combo-chart":
        series = c.get("seriesTypes") or ["bar"] * len(mids)
        y = [{"columnId": m, "type": series[i] if i < len(series) else "bar"}
             for i, m in enumerate(mids)]
        el["xAxis"] = {"columnId": dim_ids[0]}; el["yAxis"] = {"columnIds": y}
        if sort: el["xAxis"]["sort"] = {"by": sort[0], "direction": sort[1]}
        return apply_presentation(el, c)
    if kind == "box-chart":
        el["xAxis"] = {"columnId": dim_ids[0]}
        el["yAxis"] = {"columnIds": mids}
        if len(dim_ids) > 1:
            el["splitBy"] = {"columnId": dim_ids[1]}
        if vt == "distributionplot":
            el["boxShape"] = {"points": "all-points"}
        return apply_presentation(el, c)
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
                s_sz = _raw(mids[2]); scols.append(s_sz); sc["size"] = {"columnId": s_sz["id"]}
            sc["columns"] = scols
            cc = qlik_color(c.get("color"), [s_dim["id"]], [s_x["id"], s_y["id"]], sc)
            if cc: sc["color"] = cc
            rm = qlik_refmarks(c)
            if rm: sc["refMarks"] = rm   # e.g. a Margin Target line at x=0.45
            return apply_presentation(sc, c)
        # <2 measures or no dim: fall back to a plain dim-on-x cartesian
        el["xAxis"] = {"columnId": dim_ids[0] if dim_ids else mids[0]}
        el["yAxis"] = {"columnIds": mids}
        return apply_presentation(el, c)
    # bar / line
    el["xAxis"] = {"columnId": dim_ids[0]}
    el["yAxis"] = {"columnIds": mids}
    if sort: el["xAxis"]["sort"] = {"by": sort[0], "direction": sort[1]}
    if kind in ("bar-chart", "waterfall-chart"):
        el["dataLabel"] = {"labels": "shown"}
    cc = qlik_color(c.get("color"), dim_ids, mids, el)
    if cc: el["color"] = cc
    if vt in ("mekkochart", "treemap") and len(dim_ids) > 1:
        # Preserve the nested category as a series. Mekko's variable width and
        # treemap's tiled geometry remain explicit visual gaps in the catalog.
        el["color"] = {"by": "category", "column": dim_ids[1]}
        el["stacking"] = "normalized" if vt == "mekkochart" else "stacked"
    rm = qlik_refmarks(c)
    if rm: el["refMarks"] = rm
    return apply_presentation(el, c)


def build_content_element(c):
    """One source-less Qlik content object -> one source-less Sigma element."""
    if c.get("vizType") != "text-image":
        return None
    title = c.get("title") or "Text"
    markdown = str(c.get("markdown") or "").strip()
    body = f"### {title}"
    if markdown:
        body += "\n\n" + markdown
    return {"id": "el-" + re.sub(r"[^a-z0-9]", "", str(c["id"]).lower()),
            "kind": "text", "name": title, "body": body}


def build_tabbed_container(c, charts, resolve, warnings, metrics=None):
    """Qlik container -> Sigma tabbed-container plus one built child per tab."""
    child_ids = c.get("children") or []
    labels = c.get("childLabels") or []
    built, sources, tabs = [], [], []
    for i, child_id in enumerate(child_ids):
        child = charts.get(child_id)
        if child is None:
            warnings.append(
                f"container '{c.get('title') or c['id']}': child {child_id!r} was not "
                "discovered — tab omitted")
            continue
        if child.get("vizType") == "container":
            warnings.append(
                f"container '{c.get('title') or c['id']}': nested container child "
                f"{child_id!r} is unsupported — tab omitted")
            continue
        el = build_element(child, resolve, warnings, metrics)
        if el is None:
            continue
        emit_trellis(el, child, resolve, warnings)
        built.append(el)
        sources.append(child)
        label = labels[i] if i < len(labels) else None
        tabs.append({"name": label or child.get("title") or f"Tab {len(tabs) + 1}"})
    if not built:
        warnings.append(
            f"container '{c.get('title') or c['id']}': no convertible children — "
            "explicit tabbed-container gap")
        return None, None, [], []
    element_id = "el-" + re.sub(r"[^a-z0-9]", "", str(c["id"]).lower())
    spec_element = {"id": element_id, "kind": "tabbed-container", "tabs": tabs}
    layout_element = {**spec_element, "_tabChildren": [el["id"] for el in built]}
    return spec_element, layout_element, built, sources


def emap_entry(el, source, page_id):
    """Parity sidecar row for both data-bound charts and source-less elements."""
    columns = el.get("columns") or []
    return {
        "elementId": el["id"], "pageId": page_id, "kind": el["kind"],
        "name": el.get("name") or source.get("title") or source.get("vizType"),
        "valueColumnName": columns[0].get("name") if columns else None,
        "qlik": {
            "objectId": source["id"],
            "dims": [(d[0] if isinstance(d, list) else d)
                     for d in (source.get("dimensions") or [])],
            "measures": source.get("measures") or [],
            "nullSuppression": source.get("dimNullSuppression") or [],
            "drillGroups": source.get("drillGroups") or [],
        },
    }


def source_visual_ids(charts, sheets):
    """Visuals the source app promises to rebuild, in authored sheet order.

    Static text/images and filter objects are not queryable visuals. A container
    promises its chart children; a trellis container promises one faceted chart
    under the container id, matching trellis_base().
    """
    ids = []
    def add(candidate):
        if not candidate:
            return
        viz = candidate.get("vizType")
        if viz in ("filterpane", "listbox", "sheet", "singlepublic", "appprops",
                   "LoadModel", "measure", "dimension", "masterobject", "sheetlist"):
            return
        if viz == "container":
            for child_id in candidate.get("children") or []:
                child = charts.get(child_id)
                if child and ((child.get("measures") or []) or (child.get("dimensions") or [])):
                    ids.append(child_id)
            return
        if viz in _TRELLIS_KINDS:
            if candidate.get("children"):
                ids.append(candidate["id"])
            return
        if (candidate.get("measures") or []) or (candidate.get("dimensions") or []):
            ids.append(candidate["id"])

    if sheets:
        for sheet in sheets:
            for cell in sorted(sheet.get("cells") or [], key=lambda item: (item.get("row", 0), item.get("col", 0))):
                add(charts.get(cell.get("objectId")))
    else:
        trellis_owned = trellis_child_ids(charts)
        for candidate in charts.values():
            if candidate.get("id") in trellis_owned:
                continue
            add(candidate)
    return list(dict.fromkeys(ids))


# ---- container-banded layout (layout-playbook.md, verified 2026-06-10) -----
# Spec side: a `kind: container` placeholder element per band (+ a header text
# element). Layout side: canonical <Container> wrapping canonical <Element>
# children whose coordinates are CONTAINER-RELATIVE (rows restart at 1).
HEADER_STYLE = {"backgroundColor": "#0F172A", "borderRadius": "round"}
HEADER_ROWS = 3

def _le(eid, c0, c1, r0, r1):
    return f'  <Element elementId="{eid}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>'

def _gc(cid, c0, c1, r0, r1, inner):
    return (f'<Container elementId="{cid}" type="grid" gridColumn="{c0} / {c1}" '
            f'gridRow="{r0} / {r1}" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto">\n{inner}\n</Container>')


def _tc(cid, child_ids, c0, c1, r0, r1):
    """Tabbed-container layout; tabs bind to element.tabs positionally."""
    tabs = []
    for eid in child_ids:
        tabs.append(
            '  <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">\n'
            f'{_le(eid, 1, 25, 1, max(2, r1 - r0 + 1))}\n'
            '  </Tab>')
    return (f'<TabbedContainer elementId="{cid}" type="tabbed-container" '
            f'gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}">\n'
            + "\n".join(tabs) + "\n</TabbedContainer>")


def _item_layout(item, relative_r0=None):
    """Render a normal leaf or a Qlik-container-derived tabbed container."""
    eid, c0, c1, r0, r1 = item[:5]
    if relative_r0 is not None:
        r0, r1 = r0 - relative_r0 + 1, r1 - relative_r0 + 1
    meta = item[5] if len(item) > 5 else {}
    children = meta.get("_tabChildren") if isinstance(meta, dict) else None
    return _tc(eid, children, c0, c1, r0, r1) if children else _le(eid, c0, c1, r0, r1)


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
        out.append([[it[0], 1 + round(24 * j / n), 1 + round(24 * (j + 1) / n), r0, r1, *it[5:]]
                    for j, it in enumerate(sorted(band, key=lambda i: (i[1], i[3])))])
    return out

def banded_page(page_id, items, title, id_prefix=None, navigation_id=None):
    """Header band + one full-width Container per row band, children
    container-relative. Returns (page_xml, extra_spec_elements)."""
    pfx = id_prefix or f"band-{page_id}"
    extra, children = [], []
    offset = 0
    if navigation_id:
        children.append(_le(navigation_id, 1, 25, 1, 4))
        offset = 3
    if title:
        hdr, txt = f"{pfx}-hdr", f"{pfx}-hdrtext"
        extra.append({"id": hdr, "kind": "container", "style": dict(HEADER_STYLE)})
        extra.append({"id": txt, "kind": "text",
                      "body": f'# <span style="color: #FFFFFF">{title}</span>'})
        children.append(_gc(hdr, 1, 25, 1 + offset, 1 + offset + HEADER_ROWS,
                            _le(txt, 1, 25, 1, 1 + HEADER_ROWS)))
        offset += HEADER_ROWS
    if items:
        offset += 1 - min(i[3] for i in items)  # first band starts under the header
    for n, band in enumerate(_decollide_bands(_cluster_bands(items)), 1):
        if len(band) == 1 and (band[0][2] - band[0][1]) / 24 < 0.60:
            item = band[0]
            band = [[item[0], 1, 25, *item[3:]]]
        cid = f"{pfx}-{n}"
        extra.append({"id": cid, "kind": "container"})
        r0 = min(i[3] for i in band); r1 = max(i[4] for i in band)
        inner = "\n".join(_item_layout(i, relative_r0=r0) for i in band)
        children.append(_gc(cid, 1, 25, r0 + offset, r1 + offset, inner))
    body = "\n".join(children)
    return (f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto" id="{page_id}">\n{body}\n</Page>', extra)

def grid_layout(page_id, sheet, placed, navigation_id=None):
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
            charts.append([el["id"], c0, c1, r0, r1, el])
    items, row = [], 1
    if ctls:
        n = len(ctls)
        for i, eid in enumerate(ctls):
            cc0 = 1 + round(24 * i / n); cc1 = 1 + round(24 * (i + 1) / n)
            items.append([eid, cc0, cc1, row, row + 3])
        row += 3
    if charts:
        shift = row - min(c[3] for c in charts)   # drop charts below the controls band
        items += [[c[0], c[1], c[2], c[3] + shift, c[4] + shift, *c[5:]] for c in charts]
    return banded_page(page_id, items, sheet.get("title"), navigation_id=navigation_id)

def auto_layout(page_id, elems, title=None, navigation_id=None):
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
            items.append([e["id"], c0, c1, row, row + 3, e])
        row += 3
    if kpis:
        w = 24 // len(kpis)
        for i, e in enumerate(kpis):
            c0 = 1 + i * w; c1 = c0 + w if i < len(kpis) - 1 else 25
            items.append([e["id"], c0, c1, row, row + 5, e])
        row += 5
    for i in range(0, len(charts), 2):
        pair = charts[i:i + 2]
        for j, e in enumerate(pair):
            c0 = 1 if j == 0 else 13; c1 = 13 if (j == 0 and len(pair) > 1) else 25
            items.append([e["id"], c0, c1, row, row + 11, e])
        row += 11
    return banded_page(page_id, items, title or "Overview", navigation_id=navigation_id)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--charts", required=True)
    ap.add_argument("--layout")
    ap.add_argument("--denorm", required=True)
    ap.add_argument("--dm-id", required=True)
    ap.add_argument("--denorm-element-id", required=True)
    ap.add_argument("--dm-spec", default=None,
                    help="DM spec JSON (build-sigma-dm.py --spec-out). When present, a measure "
                         "whose inline aggregate matches a metric on the denorm element binds to "
                         "a governed [Metrics/<name>] reference instead of re-deriving it inline. "
                         "Absent (or on the DM-reuse path) → inline, byte-identical to before.")
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
    ap.add_argument("--coverage-out", default=None,
                    help="source-visual coverage report (default: workbook-coverage.json next to --spec-out)")
    ap.add_argument("--synth-controls", choices=["auto", "all", "off"], default="auto",
                    help="Cross-filter controls to approximate Qlik's GLOBAL associative model when the "
                         "source app lacks filter widgets (Sigma has no authorable chart-mark click-filter, "
                         "so controls are the mechanism). auto (default): synthesize a control bar from the "
                         "most-used chart DIMENSION fields ONLY when the app has zero filterpanes/listboxes "
                         "(no regression to apps that already have them — e.g. fills QlikView -prj + "
                         "filterpane-less Sense). all: also top up apps that have some filters, to "
                         "--synth-controls-max. off: strict port (only real Qlik filter widgets).")
    ap.add_argument("--synth-controls-max", type=int, default=6,
                    help="Cap on synthesized cross-filter controls (default 6).")
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
    promised_visual_ids = source_visual_ids(charts, sheets)
    denorm = json.load(open(a.denorm))["element"]
    denorm_cols = [(c["name"], (re.search(r"\[Custom SQL/(.+)\]", c["formula"]) or [None, c["name"]])[1])
                   for c in denorm["columns"]]
    resolve = Resolver(denorm_cols)

    # DM metrics referenceable on the master (it sources the denorm element): a
    # measure whose translated inline aggregate matches one binds to [Metrics/<name>]
    # (governed) instead of re-deriving it. No dm-spec / DM-reuse path → empty list
    # → every measure stays inline (byte-identical). Resolution + formula-equivalence
    # matching live in the shared binder (shared/lib/metric_binding.py).
    metrics = []
    if a.dm_spec and os.path.exists(a.dm_spec):
        try:
            _dm = json.load(open(a.dm_spec))
            _by_id = {e.get("id"): e for pg in _dm.get("pages", []) for e in (pg.get("elements") or [])}
            metrics = _mb.available_metrics(a.denorm_element_id, _by_id)
        except (ValueError, OSError) as e:
            warnings_dm_spec = f"--dm-spec unreadable ({e}); measures stay inline"
            print(warnings_dm_spec, file=sys.stderr)

    master = {"id": MASTER_ID, "name": MASTER, "kind": "table",
              "source": {"dataModelId": a.dm_id, "elementId": a.denorm_element_id, "kind": "data-model"},
              "columns": [{"id": f"o{i}", "name": dn, "formula": f"[Custom SQL/{dn}]"}
                          for i, (dn, _raw) in enumerate(denorm_cols)]}

    # Workbook-as-code keeps pages as metadata only. Elements are one flat
    # document collection and layout XML is the sole page-membership authority.
    # (Data-model code representation is deliberately unchanged and remains
    # page-nested; the --dm-spec reader above is therefore still nested.)
    warnings, pages, elements, page_elements, layout_pages, emap = (
        [], [], [], {}, [], [])
    pages.append({"id": "page-data", "name": "Data", "visibility": "hidden"})
    elements.append(master)
    page_elements["page-data"] = [master]

    CHARTY = set(VIZ_CAT.sources()) | {"auto-chart"}
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

    # --- Synthesize cross-filter controls (associative-model approximation) ------
    # Qlik cross-filters on ANY field via the global associative model; Sigma has
    # no authorable chart-mark click-filter, so we recreate the "select anywhere,
    # filter everywhere" UX with controls on the shared master. We fabricate a
    # filterpane + child listboxes INTO `charts` (from the most-used chart
    # dimension fields) so the normal controls_for/grid_layout/placement paths and
    # control_lint handle them unchanged. auto: only when the app has zero real
    # filter widgets (no regression); all: also top up; off: skip. Chart-mark
    # click-filter stays a Sigma UI step (documented, not spec-authorable).
    n_synth = 0
    if a.synth_controls != "off":
        real_fields, real_signals = set(), 0
        for c in charts.values():
            vt = c.get("vizType")
            if vt == "listbox":
                real_signals += 1
                f = (c.get("listbox") or {}).get("field")
                if f: real_fields.add(f)
            elif vt == "filterpane":
                real_signals += 1
                for ch in (c.get("children") or []):
                    f = ((charts.get(ch) or {}).get("listbox") or {}).get("field")
                    if f: real_fields.add(f)
        if a.synth_controls == "all" or real_signals == 0:
            usage, labels = {}, {}
            for c in charts.values():
                if c.get("vizType") not in CHARTY:
                    continue
                dlabs = c.get("dimLabels") or []
                for i, grp in enumerate(c.get("dimensions") or []):
                    f = grp[0] if isinstance(grp, list) else grp
                    if not f or not re.match(r"^[A-Za-z_][\w ]*$", str(f)):
                        continue                                   # skip expression dims
                    if f in real_fields or re.search(r"(^|_)(KEY|ID)$", str(f).upper()):
                        continue                                   # already filtered / join-key
                    dn = resolve(f)
                    if dn is None or dn not in mcol_id:
                        continue                                   # must resolve to a master column
                    usage[f] = usage.get(f, 0) + 1
                    labels.setdefault(f, dlabs[i] if i < len(dlabs) and dlabs[i] else f)
            ranked = sorted(usage, key=lambda f: (-usage[f], str(f)))[:max(0, a.synth_controls_max)]
            if ranked:
                kids = []
                for f in ranked:
                    lid = "synth-lb-" + re.sub(r"[^a-z0-9]", "", str(f).lower())
                    charts[lid] = {"id": lid, "vizType": "listbox", "title": labels[f],
                                   "_synth": True,
                                   "listbox": {"field": f, "label": labels[f], "state": None}}
                    kids.append(lid)
                charts["synth-fp"] = {"id": "synth-fp", "vizType": "filterpane", "title": "Filters",
                                      "_synth": True, "children": kids}
                n_synth = len(kids)
                if sheets:
                    sheets[0].setdefault("cells", []).insert(
                        0, {"objectId": "synth-fp", "col": 0, "row": 0, "colspan": 24, "rowspan": 2})
                warnings.append(
                    f"synthesized {n_synth} cross-filter control(s) from chart dimensions "
                    f"(associative-model approximation; --synth-controls={a.synth_controls}): "
                    + ", ".join(labels[f] for f in ranked)
                    + " - in-chart mark-click filtering remains a Sigma UI step (not spec-authorable)")

    # Base children owned by a trellis-container are emitted THROUGH the
    # container (one faceted element), never standalone.
    tr_children = trellis_child_ids(charts)
    container_children = {
        child for candidate in charts.values() if candidate.get("vizType") == "container"
        for child in (candidate.get("children") or [])
    }
    nav_elements = []
    if sheets:
        for si, sheet in enumerate(sheets):
            pid = f"pg-{si + 1}"
            elems, placed = [], []
            for cell in sorted(sheet["cells"], key=lambda c: (c["row"], c["col"])):
                c = charts.get(cell["objectId"])
                if c is None: continue
                if cell["objectId"] in tr_children: continue   # emitted via its container
                if cell["objectId"] in container_children: continue  # emitted in its parent's tab
                if c["vizType"] in ("filterpane", "listbox"):
                    if not c.get("_synth"): n_signals += 1   # synthesized controls aren't source signals
                    ctls = controls_for(c)
                    for i, ctl in enumerate(ctls):
                        elems.append(ctl)
                        placed.append((control_subcell(cell, i, len(ctls)), ctl))
                    n_controls += len(ctls)
                    continue
                if c["vizType"] == "text-image":
                    el = build_content_element(c)
                    elems.append(el); placed.append((cell, el))
                    continue
                if c["vizType"] == "container":
                    tc, tc_layout, children, sources = build_tabbed_container(
                        c, charts, resolve, warnings, metrics)
                    if tc is None:
                        continue
                    elems.extend([tc, *children])
                    placed.append((cell, tc_layout))
                    emap.extend(emap_entry(child, source, pid)
                                for child, source in zip(children, sources))
                    continue
                # Resolve a trellis-container to its base child chart (carrying
                # the container's facet); a plain chart passes through unchanged.
                c = trellis_base(c, charts, warnings)
                if c is None: continue
                if c["vizType"] not in CHARTY and not (c.get("measures") or c.get("dimensions")):
                    warnings.append(f"skip '{cell['objectId']}' ({c['vizType']}): not a chart"); continue
                el = build_element(c, resolve, warnings, metrics)
                if el is None: continue
                emit_trellis(el, c, resolve, warnings)   # native trellis (no-op if no signal)
                elems.append(el); placed.append((cell, el))
                emap.append(emap_entry(el, c, pid))
            if not elems: continue
            nav = None
            if len(sheets) > 1:
                nav = {"id": f"nav-{pid}", "kind": "navigation", "mode": "auto",
                       "pageLabels": []}
                elems.insert(0, nav)
                nav_elements.append(nav)
            xml, extra = grid_layout(pid, sheet, placed,
                                     navigation_id=nav["id"] if nav else None)
            page_els = elems + extra
            pages.append({"id": pid, "name": sheet["title"]})
            elements.extend(page_els)
            page_elements[pid] = page_els
            layout_pages.append(xml)
    else:
        # no sheet layout discovered — build every data-bound chart, auto-layout;
        # filterpanes/listboxes still become controls (top band). Children of a
        # filterpane are skipped standalone (the pane emits them).
        pid, elems, layout_elems = "pg-1", [], []
        child_ids = {ch for c in charts.values() if c["vizType"] == "filterpane"
                     for ch in (c.get("children") or [])}
        for c in charts.values():
            if c["id"] in tr_children or c["id"] in container_children:
                continue   # child emitted through its owning composition object
            if c["vizType"] == "filterpane" or (c["vizType"] == "listbox" and c["id"] not in child_ids):
                if not c.get("_synth"): n_signals += 1   # synthesized controls aren't source signals
                ctls = controls_for(c)
                elems.extend(ctls)
                layout_elems.extend(ctls)
                n_controls += len(ctls)
                continue
            if c["vizType"] == "text-image":
                el = build_content_element(c)
                elems.append(el)
                layout_elems.append(el)
                continue
            if c["vizType"] == "container":
                tc, tc_layout, children, sources = build_tabbed_container(
                    c, charts, resolve, warnings, metrics)
                if tc is None:
                    continue
                elems.extend([tc, *children])
                layout_elems.append(tc_layout)
                emap.extend(emap_entry(child, source, pid)
                            for child, source in zip(children, sources))
                continue
            c = trellis_base(c, charts, warnings)   # container -> its base child chart
            if c is None: continue
            if not ((c.get("measures") or []) or (c.get("dimensions") or [])): continue
            el = build_element(c, resolve, warnings, metrics)
            if el is None: continue
            emit_trellis(el, c, resolve, warnings)   # native trellis (no-op if no signal)
            elems.append(el)
            layout_elems.append(el)
            emap.append(emap_entry(el, c, pid))
        xml, extra = auto_layout(pid, layout_elems)
        page_els = elems + extra
        pages.append({"id": pid, "name": "Overview"})
        elements.extend(page_els)
        page_elements[pid] = page_els
        layout_pages.append(xml)

    page_labels = [{"pageId": page["id"], "label": page["name"]} for page in pages
                   if page["id"] != "page-data"]
    for nav in nav_elements:
        nav["pageLabels"] = page_labels

    # Scatter charts emit a hidden grouped SOURCE table (one row per point dim);
    # park them on the hidden Data page next to the master. Workbook-as-code
    # requires every flat element to be placed exactly once, even hidden source
    # tables, so each receives a deterministic Data-page layout slot.
    if _SCATTER_SRC:
        elements.extend(_SCATTER_SRC)
        page_elements["page-data"].extend(_SCATTER_SRC)

    data_layout = []
    for i, element in enumerate(page_elements["page-data"]):
        r0 = 1 + i * 14
        data_layout.append(
            f'  <Element elementId="{element["id"]}" '
            f'gridColumn="1 / 25" gridRow="{r0} / {r0 + 14}"/>')
    layout_pages.insert(
        0,
        '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
        'gridTemplateRows="auto" id="page-data">\n'
        + "\n".join(data_layout) + "\n</Page>")

    layout_xml = '<?xml version="1.0" encoding="utf-8"?>\n' + "\n".join(layout_pages)
    element_ids = [e.get("id") for e in elements]
    layout_ids = re.findall(r'\belementId="([^"]+)"', layout_xml)
    duplicate_elements = sorted({eid for eid in element_ids if element_ids.count(eid) > 1})
    duplicate_layout = sorted({eid for eid in layout_ids if layout_ids.count(eid) > 1})
    missing_layout = sorted(set(element_ids) - set(layout_ids))
    unknown_layout = sorted(set(layout_ids) - set(element_ids))
    if duplicate_elements or duplicate_layout or missing_layout or unknown_layout:
        raise SystemExit(
            "FATAL: workbook layout must place every flat element exactly once; "
            f"duplicate elements={duplicate_elements}, duplicate layout refs={duplicate_layout}, "
            f"unplaced={missing_layout}, unknown refs={unknown_layout}")

    document = {"schemaVersion": 1, "kind": "workbook", "pages": pages,
                "elements": elements, "layout": layout_xml}
    spec = {"name": a.name, "document": document}
    if a.folder:
        spec["folderId"] = a.folder
    json.dump(spec, open(a.spec_out, "w"), indent=2)
    open(a.layout_out, "w").write(layout_xml)
    json.dump(emap, open(a.element_map, "w"), indent=2)
    # native-trellis-emitted.json — round-trip guard sidecar. Written ONLY when a
    # native trellis was actually emitted (a non-trellis app stays byte-identical:
    # no file). Sigma silently STRIPS an unsupported trellis on readback, and this
    # build path does NOT re-read the posted spec, so the guard is external:
    # verify-trellis-survived.rb re-reads GET /v2/workbooks/{id}/spec and asserts
    # each element below still carries its `trellis.<axis>` key.
    if _TRELLIS_RECORDS:
        nt_path = os.path.join(os.path.dirname(os.path.abspath(a.spec_out)), "native-trellis-emitted.json")
        json.dump({"version": 1, "source": "qlik", "elements": _TRELLIS_RECORDS},
                  open(nt_path, "w"), indent=2)
        print(f"wrote {nt_path} ({len(_TRELLIS_RECORDS)} native trellis element(s) — "
              "verify survives readback with verify-trellis-survived.rb)", file=sys.stderr)
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
    must = [e["id"] for pid, page_els in page_elements.items() if pid != "page-data"
            for e in page_els if e.get("kind") in QUERYABLE]
    for sc in scope:
        if sc.get("status") == "wired":
            sc["mustReach"] = must
    scope_path = a.control_scope_out or os.path.join(
        os.path.dirname(os.path.abspath(a.spec_out)), "control-scope.json")
    json.dump({"version": 1, "source": "qlik", "sourceFilterSignals": n_signals,
                "synthesizedCount": sum(1 for sc in scope if sc.get("synthesized")),
                "controls": scope, "unbound": unbound},
               open(scope_path, "w"), indent=2)

    built_visual_ids = list(dict.fromkeys(
        entry.get("qlik", {}).get("objectId") for entry in emap
        if entry.get("qlik", {}).get("objectId")))
    unbuilt_visual_ids = [object_id for object_id in promised_visual_ids
                          if object_id not in built_visual_ids]
    coverage_path = a.coverage_out or os.path.join(
        os.path.dirname(os.path.abspath(a.spec_out)), "workbook-coverage.json")
    coverage = {
        "sourceVisuals": len(promised_visual_ids),
        "sourceVisualIds": promised_visual_ids,
        "queryableElements": len(emap),
        "builtSourceVisualIds": built_visual_ids,
        "unbuiltSourceVisualIds": unbuilt_visual_ids,
        "status": "PASS" if promised_visual_ids and not unbuilt_visual_ids and emap else "FAIL",
    }
    json.dump(coverage, open(coverage_path, "w"), indent=2)

    n_elem = len(elements) - 1
    result = {"workbookId": None, "pages": len(pages), "elements": n_elem,
              "queryableElements": len(emap), "sourceVisuals": len(promised_visual_ids),
              "unbuiltSourceVisuals": unbuilt_visual_ids, "coverageFile": coverage_path,
              "kpis": sum(1 for e in emap if e["kind"] == "kpi-chart"),
              "controls": n_controls, "controlScope": scope_path,
              "nativeTrellis": len(_TRELLIS_RECORDS),
              "warnings": warnings, "layoutFile": a.layout_out, "elementMap": a.element_map}
    if coverage["status"] != "PASS":
        for w in warnings: print("   WARN:", w, file=sys.stderr)
        json.dump(result, open(a.out, "w"), indent=2)
        if not promised_visual_ids:
            reason = ("no queryable source visuals were found in the discovery artifacts "
                      "(the workbook would contain only the hidden Data page)")
        elif not emap:
            reason = "zero queryable Sigma elements were built (the workbook would contain only the hidden Data page)"
        else:
            reason = "source visual(s) were not rebuilt: " + ", ".join(unbuilt_visual_ids)
        raise SystemExit(
            f"FATAL: workbook source-coverage gate failed: {reason}. "
            f"No workbook was posted; inspect {coverage_path} and the WARN lines above.")
    if a.dry_run:
        print(f"DRY RUN: spec -> {a.spec_out} ({len(pages)} pages, {n_elem} elements)", file=sys.stderr)
    else:
        # Workbook code-rep POSTs require the nested `document` envelope
        # (verified live 2026-08-03/04: a flat body 400s) — wrap the flat
        # spec built above before sending it over the wire.
        post_body = _cr.wrap(_cr.document(spec), _cr.metadata(spec))
        res = api_post("/v2/workbooks/spec", post_body)
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
