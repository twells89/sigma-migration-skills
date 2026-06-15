#!/usr/bin/env python3
"""extract-pbir.py — pull a Power BI report's PBIR and emit a normalized signals.json.

The PBI analog of tableau-to-sigma's parse-twb-layout.rb. Given a PBIR report
folder (already on disk from a Fabric getDefinition, e.g. /tmp/pbir) OR a live
(workspaceId, reportId) to fetch, it walks the report definition and emits one
normalized record per visual: chart kind, the field bindings per role
(x / y / color / value / rows / columns), and canvas position (x,y,w,h) plus the
page geometry. That normalized signals.json is the single input to
build-workbook-from-pbir.rb.

PBIR (Power BI Enhanced Report) on-disk shape (see research/powerbi-visual-layout.md §2c):
    <Report>.Report/definition/
      pages/pages.json                  -> pageOrder, activePageName
      pages/<pg>/page.json              -> displayName, width, height
      pages/<pg>/visuals/<id>/visual.json -> position{x,y,z,width,height}, visual.visualType, visual.query.queryState

Field bindings live under visual.query.queryState.<Role>.projections[].queryRef
(e.g. "EMPLOYEES.Total Salary"); Role is Category/Y/Values/Rows/Columns/Series/etc.

Usage:
    # from an already-extracted PBIR folder (no network):
    python3 scripts/extract-pbir.py --pbir-dir /tmp/pbir --out /tmp/pbir/signals.json

    # fetch a live report first (device-code, cached token), then extract:
    python3 scripts/extract-pbir.py --workspace <wsId> --report <reportId> \
        --pbir-dir /tmp/pbir --out /tmp/pbir/signals.json

Idempotent: re-running overwrites signals.json; a fetch only re-downloads when
--workspace/--report are given (otherwise it parses whatever is on disk).
"""
import argparse, base64, json, os, sys, time

CLIENT_ID = "ea0616ba-638b-4df5-95b9-636659ae5121"  # Power BI Desktop public client
AUTHORITY = "https://login.microsoftonline.com/organizations"
SCOPES    = ["https://api.fabric.microsoft.com/.default"]
CACHE     = "/tmp/pbiauth/cache.bin"
FAB_BASE  = "https://api.fabric.microsoft.com/v1"

# PBIR visualType -> Sigma element kind (research/powerbi-visual-layout.md §4e).
VISUAL_KIND = {
    "card": "kpi", "multiRowCard": "kpi", "kpi": "kpi", "gauge": "kpi",
    "textbox": "text", "actionButton": "text",
    "lineChart": "line", "areaChart": "area", "stackedAreaChart": "area",
    "barChart": "bar", "clusteredBarChart": "bar", "stackedBarChart": "bar",
    "columnChart": "bar", "clusteredColumnChart": "bar", "stackedColumnChart": "bar",
    "hundredPercentStackedColumnChart": "bar",
    "lineClusteredColumnComboChart": "combo", "lineStackedColumnComboChart": "combo",
    "pieChart": "pie", "donutChart": "donut", "scatterChart": "scatter",
    "tableEx": "table", "pivotTable": "pivot-table", "matrix": "pivot-table",
    "slicer": "control",
    "map": "map", "filledMap": "map", "shapeMap": "map", "azureMap": "map",
}

# PBI bar families: *Bar* visuals render HORIZONTALLY; *Column* visuals render
# vertically (Sigma's default). Sigma's bar-chart `orientation` field accepts
# ONLY "horizontal" — vertical is expressed by omitting the field; sending
# "vertical" is rejected (invalid_request). Verified via /v2/workbooks/{id}/spec
# PUT round-trip 2026-06-02.
HBAR_TYPES = {"barChart", "clusteredBarChart", "stackedBarChart",
              "hundredPercentStackedBarChart"}

# Stacking: PBI clustered -> Sigma "none" (side-by-side), stacked -> "stacked",
# 100% -> "normalized". The Sigma `stacking` enum is none|stacked|normalized
# (OpenAPI BarChart.stacking; "normalized" = "stack scaled to 100%"). "100" is
# NOT valid — the API rejects it as "Invalid value: string" (beads-sigma-pi8v).
# IMPORTANT: emit "none" explicitly — a multi-series Sigma bar defaults to
# STACKED, so a clustered PBI chart comes out stacked otherwise.
STACKED_TYPES = {"stackedBarChart", "stackedColumnChart", "stackedAreaChart",
                 "hundredPercentStackedBarChart", "hundredPercentStackedColumnChart"}
PCT_STACKED_TYPES = {"hundredPercentStackedBarChart", "hundredPercentStackedColumnChart"}

def _stacking(vtype):
    if vtype in PCT_STACKED_TYPES: return "normalized"
    if vtype in STACKED_TYPES: return "stacked"
    return "none"


def _fetch_pbir(ws, report, out_dir):
    """Download a report's PBIR parts into out_dir via Fabric getDefinition.

    Fast discovery: LRO polling is 0.5s-first + backoff (pbi_fabric.lro) instead
    of sleeping the full Retry-After before the first status check; a per-task
    timings.json lands next to the parts."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import pbi_fabric as fab  # injects truststore (corp TLS inspection — mandatory)
    tm = fab.Timings()
    tok = tm.timed("auth", lambda: fab.get_token())
    if not tok:
        sys.exit("AUTH FAIL — no token")
    try:
        defn = tm.timed("report-def", lambda: fab.fetch_definition(
            tok, ws, "reports", report, None, label="report getDefinition"))
    except RuntimeError as e:
        sys.exit(str(e))
    fab.write_parts(defn, out_dir, flatten=False)
    t = tm.write(os.path.join(out_dir, "timings.json"), status="ok", report=report)
    print(f"[extract-pbir] fetched PBIR -> {out_dir} "
          f"({t['totalSeconds']}s: " + "  ".join(f"{x['task']}={x['seconds']}s" for x in t["tasks"]) + ")",
          file=sys.stderr)


def _role_bindings(query_state):
    """{Role: [queryRef, ...]} from visual.query.queryState.

    bead hjke(c): a date-hierarchy role carries one projection PER LEVEL
    (Year/Quarter/Month/Day); the drilled-to level is flagged `active`. When any
    projection in a role carries an active flag, keep only the active one(s) so a
    day-drilled line binds Day instead of collapsing to the first level (Year).
    """
    out = {}
    for role, blk in (query_state or {}).items():
        projs = [p for p in blk.get("projections", []) if isinstance(p, dict)]
        active = [p for p in projs if p.get("active") is True]
        if active and len(active) < len(projs):
            print(f"[extract-pbir] drill: role {role} has {len(projs)} hierarchy level(s); "
                  f"using active level only", file=sys.stderr)
            projs = active
        refs = [p.get("queryRef") or p.get("nativeQueryRef") for p in projs]
        out[role] = [r for r in refs if r]
    return out


def _obj_flag(visual, key):
    """objects.<key>[0].properties.show.expr.Literal.Value -> True/False/None.

    bead n9u9 (labels) / ry0n (legend): PBI stores per-visual toggles as string
    literals 'true'/'false'; absent means tool default -> None (callers keep
    their back-compat behavior on None)."""
    for item in visual.get("objects", {}).get(key, []):
        v = item.get("properties", {}).get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        if v is not None:
            return str(v).strip("'").lower() == "true"
    return None


def _textbox_body(visual):
    """Best-effort text body for textbox/card-title visuals."""
    objs = visual.get("objects", {})
    for key in ("general", "text"):
        for item in objs.get(key, []):
            t = item.get("properties", {}).get("text", {}).get("expr", {}).get("Literal", {}).get("Value")
            if t:
                return t.strip("'")
    return None


def _visual_title(visual):
    """The PBI visual's title text (objects.title[].properties.text.expr.Literal.Value).
    Returns None when the title is hidden/unset so callers can fall back."""
    for item in visual.get("objects", {}).get("title", []):
        props = item.get("properties", {})
        # respect an explicit show:false
        show = props.get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        t = props.get("text", {}).get("expr", {}).get("Literal", {}).get("Value")
        if t and show != "false":
            return t.strip("'")
    return None


# bead f972: PBI aggregation function codes (query OrderBy / sortDefinition
# Aggregation.Function) -> the function name PBI uses in aggregated queryRefs
# ("Sum(ABSENCE_RECORDS.HOURS)").
AGG_FUNC = {0: "Sum", 1: "Avg", 2: "Min", 3: "Max", 4: "Count", 5: "CountNonNull"}


def _expr_queryref(expr):
    """Best-effort queryRef string from a PBI field expression (Measure/Column/
    Aggregation shapes). Returns None for shapes we don't model (hierarchies)."""
    if not isinstance(expr, dict):
        return None
    if "Aggregation" in expr:
        inner = _expr_queryref(expr["Aggregation"].get("Expression"))
        fn = AGG_FUNC.get(expr["Aggregation"].get("Function"), "Sum")
        return f"{fn}({inner})" if inner else None
    for k in ("Measure", "Column"):
        if k in expr:
            ent = (expr[k].get("Expression") or {}).get("SourceRef", {}).get("Entity")
            prop = expr[k].get("Property")
            if prop:
                return f"{ent}.{prop}" if ent else prop
    return None


def _sort_signal(visual):
    """bead f972: visual.query.sortDefinition.sort[0] -> {queryRef, direction}.

    PBIR carries the visual's sort as query.sortDefinition.sort[]: each entry is
    {field: <field expr>, direction: "Ascending"|"Descending"}. Resolve the sorted
    field back to a bound projection's queryRef (exact field-expression match
    first — projections carry the same `field` object — then a derived
    Entity.Property fallback) so the builder can map it to a Sigma column id."""
    sd = (visual.get("query") or {}).get("sortDefinition") or {}
    entries = sd.get("sort") or []
    if not entries:
        return None
    first = entries[0]
    direction = "desc" if str(first.get("direction", "")).lower().startswith("desc") else "asc"
    fld = first.get("field")
    qs = (visual.get("query") or {}).get("queryState") or {}
    for _role, blk in qs.items():
        for p in blk.get("projections", []):
            if isinstance(p, dict) and p.get("field") == fld:
                qr = p.get("queryRef") or p.get("nativeQueryRef")
                if qr:
                    return {"queryRef": qr, "direction": direction}
    qr = _expr_queryref(fld)
    return {"queryRef": qr, "direction": direction} if qr else None


def _proj_format(proj):
    """Best-effort numeric format carried on a projection (PBIR rarely inlines it,
    but newer exports may). Returns a Sigma-ish format hint string or None."""
    fmt = proj.get("format") or proj.get("formatString")
    return fmt if isinstance(fmt, str) and fmt else None


def _literal(prop):
    """Unwrap a PBI property's literal value: {expr:{Literal:{Value:"'x'"}}} -> "x".
    Numeric literals come through as "400D"/"0.45L" — strip the type suffix."""
    if not isinstance(prop, dict):
        return None
    v = (prop.get("expr") or {}).get("Literal", {}).get("Value")
    if v is None:
        return None
    s = str(v).strip()
    if s.startswith("'") and s.endswith("'"):
        return s[1:-1]
    # numeric literal with a trailing type tag (D=double, L=long, M=decimal)
    m = __import__("re").fullmatch(r"(-?\d+(?:\.\d+)?)[DLMF]?", s)
    return m.group(1) if m else s


def _color_literal(prop):
    """A PBI color property is either a flat literal ('#RRGGBB') or a themed
    solid color {solid:{color:{expr:{Literal:{Value:"'#...'"}}}}}. Return the hex
    string or None."""
    if not isinstance(prop, dict):
        return None
    direct = _literal(prop)
    if direct and str(direct).startswith("#"):
        return direct
    solid = (prop.get("solid") or {}).get("color")
    return _color_literal(solid) if solid else None


# bead (A) reference lines: PBI analytics-pane lines live in the visual's
# `objects` under axis-scoped keys. Each is a list of instances; each instance's
# `properties` carries {value, displayName, lineColor, show, ...}. A `value`
# literal -> a constant Sigma refMark; a measure-bound line (no flat value) is
# flagged via expr (the builder formula-wraps it). axis maps to Sigma's
# refMarks.axis: y-axis lines -> 'series', x-axis lines -> 'axis'.
REFLINE_OBJECT_AXIS = {
    "y1AxisReferenceLine": "series", "yAxisReferenceLine": "series",
    "y2AxisReferenceLine": "series2",
    "xAxisReferenceLine": "axis",
    "referenceLine": "series",          # generic (cartesian) constant line
}


def _reference_lines(visual):
    """PBI analytics-pane constant lines -> [{axis, value|expr, label, color, show}].
    Best-effort: PBIR records each line as objects.<key>[].properties with a
    `value` literal (constant) and optional displayName/lineColor."""
    out = []
    objs = visual.get("objects", {})
    for key, axis in REFLINE_OBJECT_AXIS.items():
        for item in objs.get(key, []):
            props = item.get("properties", {}) if isinstance(item, dict) else {}
            show = _literal(props.get("show", {}))
            if str(show).lower() == "false":
                continue
            value = _literal(props.get("value", {}))
            label = _literal(props.get("displayName", {})) or _literal(props.get("text", {}))
            color = _color_literal(props.get("lineColor", {})) or _color_literal(props.get("color", {}))
            if value is None:
                continue   # measure-bound / styling-only line — skip (no constant to plot)
            out.append({"axis": axis, "value": value,
                        "label": label, "color": color})
    return out


def _trend_line(visual):
    """PBI 'Trend line' analytics toggle (objects.trend show:true) -> {model}.
    PBI only offers a linear trend; Sigma's trendlines[].model = 'linear'."""
    for item in visual.get("objects", {}).get("trend", []):
        props = item.get("properties", {}) if isinstance(item, dict) else {}
        show = _literal(props.get("show", {}))
        if str(show).lower() == "true":
            return {"model": "linear"}
    return None


def _measure_color(visual):
    """bead (B) by-measure color: PBI 'Color saturation' / conditional fill-by-value
    on a bar/column/combo. PBIR encodes it under objects.dataPoint[].properties.fill
    as a fillRule whose gradient stops bind a measure (FieldDef/Aggregation), OR a
    flat colorSaturation. Returns {queryRef, scheme[], reverse} or None — the builder
    duplicates that measure onto a color:{by:scale} channel.

    We don't reproduce PBI's exact stops; we map to a 3-stop sequential scheme
    (low->high) and let the agent tune in Sigma. The signal we need is just WHICH
    measure drives the saturation."""
    objs = visual.get("objects", {})
    for item in objs.get("dataPoint", []) + objs.get("colorSaturation", []):
        props = item.get("properties", {}) if isinstance(item, dict) else {}
        fill = props.get("fill") or props.get("fillRule") or props.get("colorSaturation") or {}
        # the fillRule carries the driving measure under a FieldDef/Aggregation
        rule = (fill.get("fillRule") if isinstance(fill, dict) else None) or fill
        qr = _fillrule_measure(rule)
        if qr:
            stops = (rule.get("linearGradient2") or rule.get("linearGradient3") or {}) if isinstance(rule, dict) else {}
            lo = _color_literal((stops.get("min") or {}).get("color", {})) if isinstance(stops, dict) else None
            hi = _color_literal((stops.get("max") or {}).get("color", {})) if isinstance(stops, dict) else None
            scheme = [c for c in (lo, hi) if c] or ["#ffffcc", "#fd8d3c", "#bd0026"]
            return {"queryRef": qr, "scheme": scheme, "reverse": False}
    return None


def _fillrule_measure(rule):
    """The queryRef of the measure a fillRule's gradient binds, or None."""
    if not isinstance(rule, dict):
        return None
    # gradient stops nest the field under .min/.mid/.max .value, OR the rule
    # carries a top-level Aggregation/Measure under .field.
    for grad_key in ("linearGradient2", "linearGradient3"):
        grad = rule.get(grad_key)
        if isinstance(grad, dict):
            for stop in ("min", "mid", "max"):
                fld = (grad.get(stop) or {}).get("value") or (grad.get(stop) or {}).get("field")
                qr = _expr_queryref(fld) if fld else None
                if qr:
                    return qr
    fld = rule.get("field") or rule.get("expr")
    return _expr_queryref(fld) if fld else None


def extract(pbir_dir):
    defn = os.path.join(pbir_dir, "definition")
    if not os.path.isdir(defn):
        sys.exit(f"no definition/ under {pbir_dir} — is this a PBIR folder?")
    pages_meta = json.load(open(os.path.join(defn, "pages", "pages.json")))
    page_order = pages_meta.get("pageOrder", [])
    out_pages = []
    for pname in page_order:
        pdir = os.path.join(defn, "pages", pname)
        page = json.load(open(os.path.join(pdir, "page.json")))
        visuals = []
        vroot = os.path.join(pdir, "visuals")
        for vid in sorted(os.listdir(vroot)) if os.path.isdir(vroot) else []:
            vf = os.path.join(vroot, vid, "visual.json")
            if not os.path.exists(vf):
                continue
            v = json.load(open(vf))
            pos = v.get("position", {})
            visual = v.get("visual", {})
            vtype = visual.get("visualType", "unknown")
            qs = visual.get("query", {}).get("queryState", {})
            # per-field numeric format (queryRef -> format string), when PBIR inlines it
            formats = {}
            for _role, _blk in (qs or {}).items():
                for _p in _blk.get("projections", []):
                    if isinstance(_p, dict):
                        _qr = _p.get("queryRef") or _p.get("nativeQueryRef")
                        _f = _proj_format(_p)
                        if _qr and _f:
                            formats[_qr] = _f
            rec = {
                "visual_id": v.get("name", vid),
                "visual_type": vtype,
                "title": _visual_title(visual),
                "sigma_kind": VISUAL_KIND.get(vtype, "bar"),
                "orientation": "horizontal" if vtype in HBAR_TYPES else None,
                "stacking": _stacking(vtype) if VISUAL_KIND.get(vtype) in ("bar", "area") else None,
                "x": pos.get("x", 0), "y": pos.get("y", 0),
                "w": pos.get("width", 0), "h": pos.get("height", 0),
                "z": pos.get("z", 0),
                "parent_group": v.get("parentGroupName"),
                "bindings": _role_bindings(qs),
                # bead f972: visual sort ({queryRef, direction asc|desc}) or None
                "sort": _sort_signal(visual),
                "formats": formats,
                # bead n9u9: PBI data-label toggle (objects.labels show) — true/false/None
                "data_labels": _obj_flag(visual, "labels"),
                # bead ry0n: PBI legend toggle (objects.legend show) — true/false/None
                "legend": _obj_flag(visual, "legend"),
                # bead (A) reference lines: PBI analytics-pane constant lines ->
                # Sigma refMarks (wrapped value, label.visibility:'shown').
                "ref_lines": _reference_lines(visual),
                # bead (A) trend line: PBI 'Trend line' analytics toggle.
                "trend_line": _trend_line(visual),
                # bead (B) by-measure color: 'Color saturation' / FX fill-by-value
                # -> Sigma color:{by:scale, column:<dup measure>, scheme}.
                "measure_color": _measure_color(visual),
            }
            if rec["sigma_kind"] == "text":
                rec["text"] = _textbox_body(visual)
            visuals.append(rec)
        visuals.sort(key=lambda r: (r["y"], r["x"]))
        # Visual-interaction overrides (slicer "edit interactions"): page.json
        # carries them as visualInteractions[{source, target, type}] ONLY when an
        # author edited them (absent = PBI defaults: slicers filter the page).
        # Normalized here so the workbook builder can honor a "NoFilter" edit
        # when wiring control targets (control-targeting wave, workstream B).
        interactions = []
        for ia in (page.get("visualInteractions") or []):
            if isinstance(ia, dict) and ia.get("source") and ia.get("target"):
                interactions.append({"source": ia["source"], "target": ia["target"],
                                     "type": str(ia.get("type", "")).lower()})
        out_pages.append({
            "page_id": page.get("name", pname),
            "page_title": page.get("displayName", pname),
            "page_w": page.get("width", 1280),
            "page_h": page.get("height", 720),
            "visuals": visuals,
            "interactions": interactions,
        })
    return {"source": "pbir", "pbir_dir": pbir_dir, "pages": out_pages}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pbir-dir", default="/tmp/pbir")
    ap.add_argument("--workspace", help="fetch live report from this workspace id first")
    ap.add_argument("--report", help="fetch this report id first")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    if a.workspace and a.report:
        os.makedirs(a.pbir_dir, exist_ok=True)
        _fetch_pbir(a.workspace, a.report, a.pbir_dir)
    signals = extract(a.pbir_dir)
    out = a.out or os.path.join(a.pbir_dir, "signals.json")
    json.dump(signals, open(out, "w"), indent=2)
    nvis = sum(len(p["visuals"]) for p in signals["pages"])
    print(f"[extract-pbir] {len(signals['pages'])} page(s), {nvis} visual(s) -> {out}", file=sys.stderr)
    for p in signals["pages"]:
        for v in p["visuals"]:
            print(f"  {p['page_id']:>6} {v['visual_type']:>22} -> {v['sigma_kind']:<11} "
                  f"{ {k: vv for k, vv in v['bindings'].items()} }", file=sys.stderr)


if __name__ == "__main__":
    main()
