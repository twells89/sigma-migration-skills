#!/usr/bin/env python3
"""Shared logic for ThoughtSpot<->Sigma migration: a column RESOLVER derived from
the model TML, plus viz<->element mappers.

The migration reads a ThoughtSpot Liveboard's visualizations and rebuilds each as
a Sigma workbook element off a denormalized data-model element ("<root> View")
surfaced through a master table. Column display names differ between the tools:
ThoughtSpot keeps the worksheet/model column name (e.g. "Category"); the converted
Sigma denorm element suffixes joined-table columns with the relationship name
(e.g. "Category (PRODUCT_DIM)"). Rather than hardcode that mapping, `build_resolver`
derives it from the model TML itself, so it works for ANY model.
"""
import json, re, secrets, string

SIGMA_LOWERCASE_WORDS = {'a','an','the','and','but','or','for','nor','so','yet',
                         'at','by','in','of','on','to','up','as','into','via','per'}

def sigma_display_name(s):
    """Replicates the converter's sigmaDisplayName (SNAKE/camel -> Title Case,
    keeping small connector words lowercase)."""
    s = s or ""
    s = re.sub(r'([a-z])([A-Z])', r'\1_\2', s)
    s = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1_\2', s)
    words = [w for w in s.lower().split('_') if w]
    return ' '.join(w.capitalize() if (i == 0 or w not in SIGMA_LOWERCASE_WORDS) else w
                    for i, w in enumerate(words))

def nid(p="el"):
    return p + "-" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(8))

# Hidden grouped SOURCE tables emitted for scatter/bubble charts. A measure-vs-
# measure scatter sourced directly off the shared denorm master ("m-ofv") with
# NO grouping over-plots/collapses (every row becomes a point). The correct,
# live-verified shape (qlik-to-sigma build-sigma-workbook.py, bead ry0n) is to
# bind the scatter to a hidden grouped source (one row per point dim). These get
# parked on whatever page carries the master (visibleAsSource:False → no layout
# slot). drain_scatter_sources() empties this onto that page after element build.
_SCATTER_SRC = []

def drain_scatter_sources():
    """Pop the hidden grouped scatter-source tables accumulated by _element_core.
    Call after building every element, then extend the master's page with the
    result (they must live on the SAME page as the m-ofv master they source)."""
    out = list(_SCATTER_SRC)
    _SCATTER_SRC.clear()
    return out

_CUR = {"USD": "$", "CAD": "$", "AUD": "$", "NZD": "$", "EUR": "€", "GBP": "£",
        "JPY": "¥", "CNY": "¥", "INR": "₹", "KRW": "₩", "BRL": "R$"}

def ts_format_to_sigma(pattern, currency_iso=None):
    """Map a ThoughtSpot column `format_pattern` (Java DecimalFormat, e.g. '#,##0.00',
    '0.0%') + optional `currency_type.iso_code` to a Sigma column format. The pattern
    never carries a currency symbol (that's currency_type) — so a '$' only appears
    when the source actually set a currency. Returns None if neither is set."""
    if not pattern and not currency_iso:
        return None
    pct = "%" in (pattern or "")
    core = (pattern or "").replace("%", "")
    decimals = len(core.split(".")[1]) if "." in core else (2 if currency_iso else 0)
    grp = "," if (not pattern or "," in core or currency_iso) else ""
    if currency_iso and not pct:
        sym = _CUR.get(currency_iso.upper(), currency_iso.upper() + " ")
        return {"kind": "number", "formatString": f"{sym}{grp}.{decimals}f", "currencySymbol": sym}
    return {"kind": "number", "formatString": f"{grp}.{decimals}{'%' if pct else 'f'}"}

def build_resolver(model_root):
    """model_root = the `model:`/`worksheet:` dict from a ThoughtSpot model TML.
    Returns { model_column_name: {"measure": bool, "ofv": <denorm display name>,
    "friendly": <paren-free alias>} }. The denorm element names joined-dim columns
    "<Field> (<TABLE>)" and fact columns "<Field>"; the root (fact) table is the
    one carrying the joins."""
    mts = model_root.get("model_tables") or model_root.get("tables") or []
    fact = None
    for t in mts:
        if t.get("joins"):
            fact = t["name"]; break
    if not fact and mts:
        fact = mts[0]["name"]
    resolver = {}
    for c in model_root.get("columns", model_root.get("worksheet_columns", [])):
        cid = c.get("column_id", "")
        props = c.get("properties") or {}
        ctype = (c.get("type") or props.get("column_type") or "").upper()
        iso = (props.get("currency_type") or {}).get("iso_code")
        fmt = ts_format_to_sigma(props.get("format_pattern"), iso)
        is_formula = False
        table = field = None
        if "::" in cid:                       # physical column
            table, phys = cid.split("::", 1)
            field = sigma_display_name(phys)
            ofv = field if table == fact else f"{field} ({table})"
            name = c.get("name", field)
        elif c.get("formula_id"):             # formula column (lives on the fact element)
            name = c.get("name", c["formula_id"])
            ofv = name
            is_formula = True
        else:
            continue
        friendly = re.sub(r'\s+', ' ', name.replace("(", "").replace(")", "")).strip()
        resolver[name] = {"measure": ctype == "MEASURE", "ofv": ofv, "friendly": friendly, "fmt": fmt,
                          "agg": (str(props.get("aggregation") or "").upper() or None),
                          "is_formula": is_formula, "table": table, "field": field}
    resolver["__model_formulas__"] = model_formula_map(model_root)
    resolver["__fact__"] = fact
    return resolver

# ── ThoughtSpot side: a viz spec -> a Liveboard visualization dict (fixtures) ─
def ts_viz(idx, spec):
    dims, meas = spec.get("dims", []), spec["measures"]
    search = " ".join(f"[{c}]" for c in dims + meas)
    out_cols = list(dims) + [f"Total {m}" for m in meas]
    a = {"name": spec["name"], "tables": [{"id": "__MODEL_NAME__", "name": "__MODEL_NAME__",
            "fqn": "__MODEL_FQN__"}], "search_query": search,
         "answer_columns": [{"name": c} for c in out_cols],
         "table": {"table_columns": [{"column_id": c} for c in out_cols],
                   "ordered_column_ids": out_cols}}
    if spec["chart"] == "TABLE":
        a["display_mode"] = "TABLE_MODE"
    else:
        x = (dims or out_cols)[0]
        a["chart"] = {"type": spec["chart"], "chart_columns": [{"column_id": c} for c in out_cols],
                      "axis_configs": [{"x": [x], "y": [f"Total {m}" for m in meas]}]}
        a["display_mode"] = "CHART_MODE"
    return {"id": f"Viz_{idx}", "answer": a}

# ── Migration side: parse a Liveboard viz -> {name, chart, dims, measures} ────
def _strip_total(c):
    return c[len("Total "):] if c.startswith("Total ") else c

def parse_ts_viz(v, resolver=None):
    a = v.get("answer")
    if not a:
        return None
    cols = [c["name"] for c in a.get("answer_columns", [])]
    # Column ORDER must follow the TML's table.ordered_column_ids (the order the
    # user arranged) — answer_columns is alphabetical, which scrambles multi-
    # measure tables (e.g. Region Performance: Gross Profit before Net Revenue).
    ordered = (a.get("table") or {}).get("ordered_column_ids") or []
    if ordered:
        known = set(cols)
        cols = [c for c in ordered if c in known] + [c for c in cols if c not in set(ordered)]
    af = {f["name"]: f.get("expr", "") for f in (a.get("formulas") or []) if f.get("name")}
    mf = (resolver or {}).get("__model_formulas__") or {}
    dims, measures, mtypes, row_formulas, flagged = [], [], {}, {}, []

    def add_formula_col(name, expr):
        cls = formula_class(expr)
        if cls == "row":
            dims.append(name)
            row_formulas[name] = expr
        else:
            measures.append(name)
            mtypes[name] = {"kind": cls, "expr": expr}
            if cls == "window":
                flagged.append({"name": name, "fn": window_fn_name(expr)})

    for c in cols:
        if c in af:                                   # answer-level formula
            add_formula_col(c, af[c])
            continue
        hit = False
        for prefix, agg in (("Total ", "SUM"), ("Average ", "AVERAGE"),
                            ("Min ", "MIN"), ("Max ", "MAX")):
            if c.startswith(prefix):
                base = c[len(prefix):]
                ent = (resolver or {}).get(base) or {}
                info = {"kind": "plain", "agg": agg}
                if ent.get("is_formula"):
                    mexpr = mf.get(base, "")
                    if formula_class(mexpr) == "row":   # e.g. "Total Avg Order Value"
                        info["needs_row_calc"] = True
                    else:
                        info = {"kind": "aggregate", "expr": mexpr}
                measures.append(base)
                mtypes[base] = info
                hit = True
                break
        if hit:
            continue
        mts = _TIMESHIFT_RE.match(c)                   # e.g. "sales(this year)" / "sales(last year)"
        if mts:
            base = re.sub(r'^(Total|Average|Min|Max)\s+', '', mts.group(1).strip(), flags=re.I)
            measures.append(c)
            mtypes[c] = {"kind": "timeshift", "base": base, "period": _timeshift_period(mts.group(2))}
            continue
        mg = _GROWTH_RE.match(c)                        # e.g. "Growth of Total sales" — ordered window
        if mg:
            measures.append(c)
            mtypes[c] = {"kind": "growth", "base": re.sub(r'^Total\s+', '', mg.group(1).strip(), flags=re.I)}
            flagged.append({"name": a.get("name", ""), "fn": "period-over-period growth"})
            continue
        ent = (resolver or {}).get(c)
        if ent and ent.get("is_formula"):             # bare model formula (e.g. Order Count)
            add_formula_col(c, mf.get(c, ""))
            continue
        if ent and ent.get("measure"):                # bare model measure (uses model agg)
            measures.append(c)
            mtypes[c] = {"kind": "plain", "agg": ent.get("agg") or "SUM"}
            continue
        dims.append(c)

    chart_node = a.get("chart") or {}
    ctype = chart_node.get("type", "TABLE")
    if a.get("display_mode") == "TABLE_MODE":
        ctype = "TABLE"
    # Axis configs: honor the chart's own x ordering and color/series dim.
    ax = (chart_node.get("axis_configs") or [{}])[0] or {}
    xs = [d for d in (ax.get("x") or []) if d in dims]
    if xs:
        dims = xs + [d for d in dims if d not in xs]
    color = next((d for d in (ax.get("color") or []) if d in dims), None)
    if color:
        dims = [d for d in dims if d != color] + [color]    # color dim LAST
    cond_formats = parse_conditional_formats(a)
    if cond_formats and ctype not in ("TABLE", "ADVANCED_COLUMN"):
        # mappable CF but the host isn't a table — Sigma conditionalFormats only ride
        # pivot/input tables, so we can't attach it to a chart → flag instead.
        flagged.append({"name": a.get("name", ""), "fn": "conditional formatting"})
        cond_formats = []
    elif not cond_formats and has_cf_rule(a):
        # CF present but it's a gradient/data-bar variant we don't map → flag.
        flagged.append({"name": a.get("name", ""), "fn": "conditional formatting"})
    # A ThoughtSpot title with a `{{token}}` (a filter/parameter reference) is a
    # DYNAMIC title. A Sigma element `name` is a plain string in the spec — there's
    # no title-templating — so it would render the literal `{{token}}`. Flag it
    # (flag-not-drop) so the migration surfaces that the title won't update live,
    # rather than shipping a confusing literal.
    if re.search(r"\{\{.*?\}\}", a.get("name", "") or ""):
        flagged.append({"name": a.get("name", ""), "fn": "dynamic title"})
    # `top N` / `bottom N` → that count; a BARE `top`/`bottom` (no number) defaults
    # to 10 in ThoughtSpot (verified live: `[sales] by [product] top` → 10 rows).
    sq = a.get("search_query", "") or ""
    mtop = re.search(r"\btop\s+(\d+)\b", sq, re.I)
    topn = int(mtop.group(1)) if mtop else (10 if re.search(r"\btop\b", sq, re.I) else None)
    # The viz's date column = the one carrying a date-scope dot token (`[date].'this
    # year'`, `[date].2021`, `[date].monthly`…). Used to build SumIf conditions for
    # period-shifted measures.
    dcm = re.search(r"\[([^\]]+)\]\s*\.\s*('|\d{4}\b|month|week|day|year|quarter|hour|daily|monthly|weekly|yearly|quarterly|this|last|next)", sq, re.I)
    date_col = dcm.group(1) if dcm else None
    # When the viz has period-shifted MEASURES (sales(this year)/(last year) — a `vs`
    # comparison), the relative-date tokens are bound to those measures, NOT the whole
    # viz. Applying them as element filters would AND contradictory years → "No data".
    filters = parse_filters(sq)
    if any((mtypes.get(m) or {}).get("kind") == "timeshift" for m in measures):
        filters = [f for f in filters if f.get("kind") != "reldate"]
    return {"name": a.get("name", "Viz"), "chart": ctype, "dims": dims, "measures": measures,
            "filters": filters, "sorts": parse_sorts(a),
            "mtypes": mtypes, "row_formulas": row_formulas, "flagged": flagged,
            "color_dim": color, "topn": topn, "date_col": date_col, "conditional_formats": cond_formats,
            "refmarks": parse_refmarks(a, measures, dims),
            "measure_color": parse_measure_color(a, measures),
            "af_names": sorted(af.keys())}

# ── Reference / threshold lines (gap A) ──────────────────────────────────────
# ThoughtSpot draws a target value or limit range as a line on a chart via two
# routes: (1) `answer.conditional_formatting` with a per-metric `simple_threshold`
# / `range` carrying an operator, value(s) and a HEX color; (2) the chart's own
# `client_state_v2` JSON, which encodes them under `referenceLines` /
# `refLines` (each {value|expr, label, color, axis}). Both are surfaced here as
# {value, label, color, axis} dicts; the builder (ts_refmarks) turns each into a
# Sigma refMark. Defensive about the exact key spelling (the public TML docs do
# not expose the client_state internals — same posture as parse_sorts).
def _client_states(a):
    out = []
    for holder in (a.get("chart") or {}), (a.get("table") or {}):
        for key in ("client_state_v2", "client_state"):
            raw = holder.get(key) or ""
            if isinstance(raw, dict):
                out.append(raw); continue
            if not str(raw).strip():
                continue
            try:
                out.append(json.loads(raw, strict=False))
            except (ValueError, TypeError):
                continue
    return out

def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

def parse_refmarks(a, measures, dims):
    """→ [{value(float|str), label, color, axis('series'|'axis'), col(optional)}].
    A threshold on a MEASURE → a y/series line; on a dimension → an x/axis line."""
    out = []
    measure_set = set(measures)
    # (1) conditional_formatting metrics with a threshold operator that draws a line
    for met in (a.get("conditional_formatting") or {}).get("metric", []) \
            if isinstance(a.get("conditional_formatting"), dict) \
            else (a.get("conditional_formatting") or []):
        if not isinstance(met, dict):
            continue
        col = _strip_total(met.get("column_id") or met.get("column") or "")
        rules = met.get("simple_threshold") or met.get("thresholds") or met.get("range") or []
        if isinstance(rules, dict):
            rules = [rules]
        for r in rules:
            if not isinstance(r, dict):
                continue
            val = r.get("value")
            if val is None:
                val = r.get("min") if r.get("min") is not None else r.get("max")
            n = _num(val)
            if n is None:
                continue
            axis = "axis" if col and col not in measure_set and col in dims else "series"
            out.append({"value": n, "label": r.get("label") or met.get("label") or col,
                        "color": r.get("color") or met.get("color"), "axis": axis, "col": col})
    # (2) client_state reference lines
    for cs in _client_states(a):
        if not isinstance(cs, dict):
            continue
        for rl in (cs.get("referenceLines") or cs.get("refLines") or []):
            if not isinstance(rl, dict) or rl.get("show") is False:
                continue
            val = rl.get("value")
            n = _num(val)
            formula = n if n is not None else (rl.get("expr") or rl.get("formula"))
            if formula in (None, ""):
                continue
            ax = (rl.get("axis") or rl.get("axisType") or "Y").upper()
            out.append({"value": formula, "label": rl.get("label") or rl.get("name"),
                        "color": rl.get("color"), "axis": "axis" if ax.startswith("X") else "series",
                        "col": _strip_total(rl.get("columnId") or rl.get("column") or "")})
    return out

# ── Per-measure color scale (gap B) ──────────────────────────────────────────
# A by-measure color encoding: a conditional_formatting `range` on a measure (a
# low→high gradient) or a per-column color set in client_state columnProperties.
# Surfaced as {col, scheme(list[hex])}; the builder turns it into a Sigma
# color:{by:scale} on a DUPLICATE measure column (a column can't be on both the
# value/yAxis well and the color well). By-dimension category colors already
# flow through `color_dim` → color:{by:category}.
def parse_measure_color(a, measures):
    measure_set = set(measures)
    # conditional_formatting range gradient on a measure
    cf = a.get("conditional_formatting")
    metrics = cf.get("metric", []) if isinstance(cf, dict) else (cf or [])
    for met in metrics if isinstance(metrics, list) else []:
        if not isinstance(met, dict):
            continue
        col = _strip_total(met.get("column_id") or met.get("column") or "")
        if col not in measure_set:
            continue
        rng = met.get("range") or met.get("gradient")
        scheme = [r.get("color") for r in rng if isinstance(r, dict) and r.get("color")] \
            if isinstance(rng, list) else None
        if scheme and len(scheme) >= 2:
            return {"col": col, "scheme": scheme}
    # client_state per-column color → single-hue scale on that measure
    for cs in _client_states(a):
        for cp in (cs.get("columnProperties") or []) if isinstance(cs, dict) else []:
            if not isinstance(cp, dict):   # real TML: columnProperties entries are not always objects
                continue
            prop = cp.get("columnProperty")
            prop = prop if isinstance(prop, dict) else {}
            hue = prop.get("color") or prop.get("columnColor")
            col = _strip_total(cp.get("columnId") or "")
            if hue and col in measure_set:
                return {"col": col, "scheme": ["#ffffff", hue]}
    # NOTE: a real TS `conditional_formatting` rule has the shape
    # {rule:[{range:{min,max}, color, plotAsBand}]} — that is per-value CONDITIONAL
    # FORMATTING (color a value band), NOT a measure gradient or a reference line.
    # We intentionally do NOT map it to color:{by:scale} or a refMark (that would be
    # semantically wrong); it falls through to None / no-op until a genuine gradient
    # (a list of {color} stops) or reference line is present. Verified against live
    # team2 Liveboards (Sample Retail, Performance Tracking) 2026-06-15.
    return None

def has_cf_rule(a):
    """True if the viz carries ThoughtSpot per-cell CONDITIONAL FORMATTING
    ({rule:[{range:{min,max}, color, plotAsBand}]}, or a client_state columnProperty
    conditionalFormatting). Sigma's `conditionalFormats` exist only on
    pivot-table/input-table — NOT the `kind:table` a TS table maps to — so we can't
    attach it without changing the element kind. Flag it (flag-not-drop) so the
    migration surfaces the loss instead of silently dropping the cell coloring."""
    cf = a.get("conditional_formatting")
    if isinstance(cf, dict) and cf.get("rule"):
        return True
    for cs in _client_states(a):
        if not isinstance(cs, dict):
            continue
        for cp in (cs.get("columnProperties") or []):
            if not isinstance(cp, dict):
                continue
            prop = cp.get("columnProperty") if isinstance(cp.get("columnProperty"), dict) else {}
            if cp.get("conditionalFormatting") or prop.get("conditionalFormatting"):
                return True
    return False

# ThoughtSpot CF operator → Sigma conditionalFormats `condition`.
_TS_CF_OP = {"LESS_THAN": "<", "GREATER_THAN": ">", "LESS_THAN_EQUAL": "<=", "LESS_THAN_OR_EQUAL": "<=",
             "GREATER_THAN_EQUAL": ">=", "GREATER_THAN_OR_EQUAL": ">=", "EQUAL": "=", "EQUALS": "=",
             "NOT_EQUAL": "!=", "NOT_EQUALS": "!=", "BETWEEN": "Between", "NOT_BETWEEN": "NotBetween"}

def _cf_num(v):
    try:
        return float(v) if v not in (None, "") and "." in str(v) else int(v)
    except (TypeError, ValueError):
        return v

def parse_conditional_formats(a):
    """Real TS per-cell conditional formatting lives in client_state columnProperties:
    `columnProperty.conditionalFormatting.rows[] = {operator, value, solidBackgroundAttrs:{color}}`.
    Map SOLID-background threshold rules → [{col, condition, value, color}] (the col is the
    measure display name, paren/Total-stripped). Gradient/data-bar rows return nothing (the
    caller flags those). Sigma carries these as conditionalFormats on a pivot-table."""
    out = []
    for cs in _client_states(a):
        if not isinstance(cs, dict):
            continue
        for cp in (cs.get("columnProperties") or []):
            if not isinstance(cp, dict):
                continue
            col = _strip_total(cp.get("columnId") or "")
            prop = cp.get("columnProperty") if isinstance(cp.get("columnProperty"), dict) else {}
            cf = prop.get("conditionalFormatting") or cp.get("conditionalFormatting") or {}
            for row in (cf.get("rows") or []):
                if not isinstance(row, dict):
                    continue
                op = _TS_CF_OP.get(str(row.get("operator", "")).upper())
                color = ((row.get("solidBackgroundAttrs") or {}).get("color")
                         or (row.get("solidColorAttrs") or {}).get("color"))
                if not (op and color and col):
                    continue                      # gradient / data-bar / unmapped → skip (flagged)
                if op in ("Between", "NotBetween"):
                    val = [_cf_num(row.get("min", row.get("value"))), _cf_num(row.get("max"))]
                else:
                    val = _cf_num(row.get("value"))
                out.append({"col": col, "condition": op, "value": val, "color": color})
    return out

def parse_sorts(a):
    """Carry the answer's sorts: (1) `sort by [Col] descending` tokens in the
    search query; (2) sortInfo entries in the table/chart client_state(_v2)
    JSON. Returns [{"col": <model column name>, "direction": asc|desc}],
    deduped (first wins). 'Total X' columns resolve to the measure name X."""
    out = []
    for m in re.finditer(r"sort\s+by\s+\[([^\]]+)\]\s*(descending|ascending)?",
                         a.get("search_query", ""), re.I):
        out.append({"col": _strip_total(m.group(1)),
                    "direction": (m.group(2) or "ascending").lower()})
    for holder in (a.get("table") or {}), (a.get("chart") or {}):
        for key in ("client_state_v2", "client_state"):
            raw = holder.get(key) or ""
            if not raw.strip():
                continue
            try:
                cs = json.loads(raw, strict=False)
            except (ValueError, TypeError):
                continue
            for si in (cs.get("sortInfo") or []) if isinstance(cs, dict) else []:
                col = si.get("columnId") or si.get("columnName") or si.get("name")
                if not col:
                    continue
                asc = si.get("isAscending", si.get("ascending", si.get("sortAscending", True)))
                out.append({"col": _strip_total(col),
                            "direction": "ascending" if asc else "descending"})
    seen, res = set(), []
    for s in out:
        if s["col"] in seen:
            continue
        seen.add(s["col"]); res.append(s)
    return res

def parse_filters(search_query):
    """Extract simple filter clauses from a ThoughtSpot search query:
    `[Col] = 'val'`, `[Col] != 'val'`, `[Col] = 'a' 'b'`. ThoughtSpot lowercases
    string literals in the query (case-insensitive match); we title-case single
    words as a best-effort for case-sensitive warehouses."""
    out = []
    for m in re.finditer(r"\[([^\]]+)\]\s*(=|!=)\s*((?:'[^']*'\s*)+)", search_query):
        col, op = m.group(1), m.group(2)
        vals = [v.title() if v.islower() else v for v in re.findall(r"'([^']*)'", m.group(3))]
        out.append({"col": col, "mode": "include" if op == "=" else "exclude", "values": vals})
    # ThoughtSpot date-scope token `[date].2021` = a calendar-year filter.
    for m in re.finditer(r"\[([^\]]+)\]\s*\.\s*(\d{4})\b", search_query):
        out.append({"col": m.group(1), "mode": "include", "values": [int(m.group(2))], "year": True})
    # Relative date scopes `[date].'this year'` / `'last year'` / `'last 4 quarters'`
    # → a today-anchored boolean filter (built in sigma_element where the date ref
    # is known). Unrecognized scopes carry rel=… and get flagged there.
    for m in _RELDATE_TOKEN_RE.finditer(search_query):
        out.append({"col": m.group(1), "kind": "reldate", "rel": m.group(2).strip()})
    return out

_NUM = lambda fs: {"kind": "number", "formatString": fs}
KIND = {"KPI": "kpi-chart", "COLUMN": "bar-chart", "BAR": "bar-chart", "LINE": "line-chart",
        "STACKED_COLUMN": "bar-chart", "STACKED_BAR": "bar-chart",
        "AREA": "area-chart", "STACKED_AREA": "area-chart",
        "ADVANCED_COLUMN": "table", "TABLE": "table"}

# ThoughtSpot chart types Sigma cannot faithfully reproduce → flagged degrade to
# table (see _element_core). Keep in sync with the assessment's unsupported list.
_NO_SIGMA_EQUIV = {"WATERFALL", "FUNNEL", "TREEMAP", "HEATMAP", "HISTOGRAM", "GAUGE",
                   "SANKEY", "PARETO", "CANDLESTICK", "SPIDER_WEB", "RADAR"}

def _region_type(name):
    # Infer a Sigma region-map regionType from the geo dimension's name. Sigma's
    # regionType enum (OpenAPI): country, us-state, us-county, us-zipcode, us-cbsa,
    # us-postal-place, ca-province. Default to us-postal-place (the most permissive
    # name-based bucket) for free city/place names.
    n = (name or "").lower()
    if re.search(r"country|nation", n):            return "country"
    if re.search(r"\bstate\b|province_state", n):  return "us-state"
    if re.search(r"county", n):                    return "us-county"
    if re.search(r"zip|postal_?code|postcode", n): return "us-zipcode"
    if re.search(r"cbsa|metro", n):                return "us-cbsa"
    if re.search(r"province", n):                  return "ca-province"
    return "us-postal-place"

def _fmt(entry):
    # Honor the column's actual ThoughtSpot format_pattern when present; otherwise
    # a neutral grouped number — do NOT invent a currency symbol the source lacked.
    return entry.get("fmt") or _NUM(",.0f")

def _resolve(resolver, base):
    return resolver.get(base) or {"measure": True, "ofv": base, "friendly": re.sub(r'[()]', '', base).strip()}

# ── ThoughtSpot date buckets (Month(date)/Week(date)/…) → Sigma DateTrunc ─────
# A TS Liveboard time axis is a bucketed date column — `Month(date)`, `Week(date)`,
# `Quarter(date)`, `Year(date)`, etc. (also the `.monthly`/`.weekly` search tokens
# resolve to these in answer_columns). Sigma has no such pseudo-column, so we
# materialize a DateTrunc("<grain>", <date col>) calc column on the master and
# reference THAT. Without this the bucket name falls through as an unknown column
# and the workbook POST 400s ("dependency not found: …/month(date)").
_DATE_BUCKET_RE = re.compile(
    r'^\s*(month|week|quarter|year|day|hour|monthly|weekly|quarterly|yearly|daily)\s*\(\s*([^)]+?)\s*\)\s*$', re.I)
_BUCKET_GRAIN = {"month": "month", "monthly": "month", "week": "week", "weekly": "week",
                 "quarter": "quarter", "quarterly": "quarter", "year": "year", "yearly": "year",
                 "day": "day", "daily": "day", "hour": "hour"}

def date_bucket(name):
    """'Month(date)' → ('month','date'); None for non-bucket names."""
    m = _DATE_BUCKET_RE.match(name or "")
    if not m:
        return None
    g = _BUCKET_GRAIN.get(m.group(1).lower())
    return (g, m.group(2).strip()) if g else None

def _bucket_friendly(name):
    """Paren-free master-column name for a date bucket (parens collide with Sigma
    function-call syntax in a column ref). 'Month(date)' → 'Month of date'."""
    b = date_bucket(name)
    return f"{b[0].title()} of {re.sub(r'[()]', '', b[1]).strip()}" if b else None

# ── ThoughtSpot relative time-intelligence (search-query tokens) ──────────────
# TS time scopes are anchored to TODAY (verified live team2 2026-06-16: 'this
# year'=2026): `[date].'this year'`/'last year'/'last N quarters|months|...' is a
# rolling window; a measure can also be period-shifted in answer_columns
# (`sales(this year)` / `sales(last year)`). We translate a scope to a boolean
# Year()/DateAdd() condition over the date column — applied as an element filter,
# or wrapped into a SumIf for a shifted measure. `Growth of X` (period-over-period)
# needs an ordered window we can't express on a chart element → flagged.
_RELDATE_TOKEN_RE = re.compile(r"\[([^\]]+)\]\s*\.\s*'\s*((?:this|last|next|prior|previous)\b[^']*?)\s*'", re.I)
_TIMESHIFT_RE = re.compile(r"^(.*?)\s*\(\s*(this year|last year|prior year|previous year)\s*\)\s*$", re.I)
_GROWTH_RE = re.compile(r"^\s*growth\s+of\s+(.+?)\s*$", re.I)

def reldate_condition(rel, dateref):
    """A TS relative-date scope → a Sigma boolean over a date column ref, anchored
    to Today(). None if unrecognized (caller flags it)."""
    r = re.sub(r"\s+", " ", (rel or "").lower().strip())
    if r == "this year":                       return f"Year({dateref}) = Year(Today())"
    if r in ("last year", "prior year", "previous year"): return f"Year({dateref}) = Year(Today()) - 1"
    if r == "next year":                       return f"Year({dateref}) = Year(Today()) + 1"
    m = re.match(r"last (\d+) (year|quarter|month|week|day)s?$", r)
    if m:                                       return f'{dateref} >= DateAdd("{m.group(2)}", -{m.group(1)}, Today())'
    return None

def _timeshift_period(p):
    return "this" if "this" in (p or "").lower() else "last"

# Sigma refMark axes: a measure/Y threshold → "series"; a dimension/X line →
# "axis". value MUST be the wrapped {type:formula, formula} form (a bare number
# 400s) and label.visibility must be "shown" (qlik-to-sigma qlik_refmarks, bead-
# verified 2026-06-15).
def ts_refmarks(refmark_specs):
    out = []
    for r in refmark_specs or []:
        val = r.get("value")
        if isinstance(val, float) and val.is_integer():
            formula = str(int(val))                 # 80000.0 → "80000" (clean axis label)
        elif isinstance(val, (int, float)):
            formula = repr(val)
        else:
            formula = str(val or "")
        if not formula.strip():
            continue
        rm = {"type": "line", "axis": r.get("axis") or "series",
              "value": {"type": "formula", "formula": formula},
              "line": {"color": r.get("color") or "#ef4444", "width": 2}}
        if r.get("label"):
            rm["label"] = {"visibility": "shown", "text": str(r["label"])}
        out.append(rm)
    return out

# Charts that take an x/y axis (refMarks apply) vs the donut/pie/table/kpi kinds
# where a reference line has no axis to hang on.
_AXIS_KINDS = {"bar-chart", "line-chart", "area-chart", "combo-chart", "scatter-chart"}

def _apply_measure_color(el, spec, resolver):
    """gap B — by-measure color scale → color:{by:scale} on a DUPLICATE measure
    column (a column can't sit on both the yAxis and color wells). Only for axis
    charts that don't already carry a category color (color_dim)."""
    mc = spec.get("measure_color")
    if not mc or el.get("kind") not in _AXIS_KINDS or el.get("color"):
        return
    base = next((c for c in el.get("columns", []) if c.get("name") == mc["col"]), None)
    if not base:
        return
    dup_id = nid("c")
    dup = {"id": dup_id, "formula": base["formula"], "name": base["name"] + " (color)"}
    if base.get("format"):
        dup["format"] = base["format"]
    el["columns"].append(dup)
    el["color"] = {"by": "scale", "column": dup_id, "scheme": list(mc["scheme"])}

def _apply_refmarks(el, spec):
    """gap A — attach Sigma refMarks for axis charts."""
    if el.get("kind") not in _AXIS_KINDS:
        return
    rm = ts_refmarks(spec.get("refmarks"))
    if rm:
        el["refMarks"] = rm

def sigma_element(spec, resolver, master="OFV"):
    """Build the element, then apply any ThoughtSpot search-query filters as
    Sigma element list-filters (adds the filter column if not already present).
    Also: TS `top N` search tokens become a Sigma top-n element filter, and
    window-formula tiles get a loud [FLAGGED: …] title (flag-not-drop, bead 5d9k)."""
    el = _element_core(spec, resolver, master)
    if spec.get("topn") and el.get("kind") != "kpi-chart" and spec.get("measures"):
        mname = spec["measures"][0]
        mcol = next((c for c in el["columns"] if c.get("name") in (mname, "Total " + mname)), None)
        if mcol:
            el.setdefault("filters", []).append({"id": nid(), "columnId": mcol["id"],
                "kind": "top-n", "rankingFunction": "rank", "mode": "top-n",
                "rowCount": spec["topn"]})
    if spec.get("flagged"):
        fns = ", ".join(sorted({f["fn"] for f in spec["flagged"]}))
        el["name"] = f"{el['name']} [FLAGGED: {fns} not converted]"
    # Show value labels on bar/pie/donut (Sigma defaults them OFF). Lines stay clean.
    if el.get("kind") in ("bar-chart", "pie-chart", "donut-chart"):
        el["dataLabel"] = {"labels": "shown"}
    # A grouped scatter sources a hidden grouped table (not the master), so its
    # search-query filters must be applied to that SOURCE (pre-grouping, master
    # grain) — a [OFV/…] ref on the scatter element itself would not resolve.
    grp = el.get("source", {}).get("groupingId")
    ftarget = next((s for s in _SCATTER_SRC if s["id"] == el["source"].get("elementId")), el) if grp else el
    for f in spec.get("filters", []):
        e = _resolve(resolver, f["col"])
        if f.get("kind") == "reldate":
            # `[date].'this year'` / `'last 4 quarters'` → a today-anchored boolean
            # calc column + a filter to true (Year()/DateAdd over the date column).
            cond = reldate_condition(f["rel"], f"[{master}/{e['friendly']}]")
            if not cond:
                el["name"] = el["name"] + f" [FLAGGED: date scope '{f['rel']}' not converted]"
                continue
            cname = f"{f['rel'].title()} ({e['friendly']})"
            existing = next((c for c in ftarget["columns"] if c.get("name") == cname), None)
            col_id = existing["id"] if existing else nid("f")
            if not existing:
                ftarget["columns"].append({"id": col_id, "formula": cond, "name": cname})
            ftarget.setdefault("filters", []).append({"id": nid(), "columnId": col_id, "kind": "list",
                                                 "mode": "include", "values": [True]})
            continue
        if f.get("year"):
            # `[date].2021` → filter on a Year(<date>) calc column (a list filter on a
            # datetime column is silently dropped; Year() yields a clean integer match).
            yname = f"Year of {e['friendly']}"
            existing = next((c for c in ftarget["columns"] if c.get("name") == yname), None)
            col_id = existing["id"] if existing else nid("f")
            if not existing:
                ftarget["columns"].append({"id": col_id, "formula": f"Year([{master}/{e['friendly']}])", "name": yname})
            ftarget.setdefault("filters", []).append({"id": nid(), "columnId": col_id, "kind": "list",
                                                 "mode": "include", "values": f["values"]})
            continue
        existing = next((c for c in ftarget["columns"] if c.get("name") == f["col"]), None)
        if existing:
            col_id = existing["id"]
        else:
            col_id = nid("f"); ftarget["columns"].append({"id": col_id, "formula": f"[{master}/{e['friendly']}]", "name": f["col"]})
        ftarget.setdefault("filters", []).append({"id": nid(), "columnId": col_id, "kind": "list",
                                             "mode": f["mode"], "values": f["values"]})
    _apply_sorts(el, spec)
    _apply_measure_color(el, spec, resolver)   # gap B: by-measure color scale
    _apply_refmarks(el, spec)                  # gap A: reference / threshold lines
    return el

def _apply_sorts(el, spec):
    """TML sorts → Sigma. Verified shapes (looker-to-sigma build_workbook.py,
    live POST + readback + render, 2026-06-10):
      bar/line/area/scatter/combo : xAxis.sort  = {by: <colId>, direction}
      pie/donut                   : color.sort  = {by: <colId>, direction}
      UNGROUPED table             : element sort = [{columnId, direction}]
      GROUPED table               : groupings[0].sort = [{columnId, direction}]
        (element-level sort on a grouped table 400s with "Sort column not found")
    """
    for si, s in enumerate(spec.get("sorts") or []):
        col = next((c for c in el.get("columns", [])
                    if c.get("name") in (s["col"], "Total " + s["col"])), None)
        if not col:
            continue
        d = s["direction"]; k = el.get("kind")
        if k in ("bar-chart", "line-chart", "area-chart", "scatter-chart", "combo-chart"):
            if si == 0 and "xAxis" in el:
                el["xAxis"]["sort"] = {"by": col["id"], "direction": d}
        elif k in ("pie-chart", "donut-chart"):
            if si == 0 and "color" in el:
                el["color"]["sort"] = {"by": col["id"], "direction": d}
        elif k == "table":
            if el.get("groupings"):
                el["groupings"][0].setdefault("sort", []).append({"columnId": col["id"], "direction": d})
            else:
                el.setdefault("sort", []).append({"columnId": col["id"], "direction": d})

def _element_core(spec, resolver, master="OFV"):
    name, chart, dims, meas = spec["name"], spec["chart"], spec["dims"], spec["measures"]
    src = {"elementId": "m-ofv", "kind": "table"}
    mtypes = spec.get("mtypes") or {}
    dref = lambda b: f"[{master}/{_bucket_friendly(b) or _resolve(resolver, b)['friendly']}]"

    def mref(b):
        mt = mtypes.get(b)
        if mt and mt.get("kind") == "timeshift":      # sales(this year) / sales(last year)
            baseref = f"[{master}/{_resolve(resolver, mt['base'])['friendly']}]"
            dcol = spec.get("date_col") or "date"
            dateref = f"[{master}/{_resolve(resolver, dcol)['friendly']}]"
            yr = "Year(Today())" if mt["period"] == "this" else "Year(Today()) - 1"
            return f"SumIf({baseref}, Year({dateref}) = {yr})"
        if mt and mt.get("kind") == "growth":         # period-over-period (flagged): show base agg
            return f"Sum([{master}/{_resolve(resolver, mt['base'])['friendly']}])"
        if mt and mt.get("kind") == "aggregate":      # answer/model aggregate formula
            return ts_expr_to_sigma(mt["expr"], lambda n: dref(n))
        if mt and mt.get("kind") == "window":         # FLAGGED: inner raw aggregate fallback
            inner = window_inner_ref(mt.get("expr")) or b
            return f"Sum([{master}/{_resolve(resolver, inner)['friendly']}])"
        agg = TS_AGG_TO_SIGMA.get((mt or {}).get("agg") or "SUM", "Sum")
        return f"{agg}([{master}/{_resolve(resolver, b)['friendly']}])"

    color_dim = spec.get("color_dim")
    if color_dim and chart not in ("PIE", "DONUT", "PIVOT_TABLE", "PIVOT", "TABLE", "ADVANCED_COLUMN"):
        dims = [d for d in dims if d != color_dim]    # x-dims only; color added below
    if chart == "KPI" or (not dims and meas):
        c = nid("c") + "-v"
        ent = resolver.get(meas[0]) or {}
        dim_els = resolver.get("__dim_elements__") or {}
        tbl = ent.get("table")
        mt0 = mtypes.get(meas[0]) or {}
        plain = mt0.get("kind") in (None, "plain") and not mt0.get("needs_row_calc")
        if (plain and not spec.get("filters") and tbl
                and tbl != resolver.get("__fact__") and tbl in dim_els):
            # Dimension-grain measure (e.g. CUSTOMER_DIM.LIFETIME_REVENUE): the
            # denorm view fans each dim row across its fact rows, so aggregating
            # over OFV over-counts (chasm trap). ThoughtSpot aggregates at the
            # OWNING table's grain — source the DM's raw dim-table element.
            de = dim_els[tbl]
            agg = TS_AGG_TO_SIGMA.get(mt0.get("agg") or ent.get("agg") or "SUM", "Sum")
            return {"id": nid(), "kind": "kpi-chart", "name": name,
                    "source": {"dataModelId": resolver.get("__dm_id__"),
                               "elementId": de["id"], "kind": "data-model"},
                    "columns": [{"id": c, "formula": f"{agg}([{de['name']}/{ent['field']}])",
                                 "name": meas[0], "format": _fmt(ent)}],
                    "value": {"columnId": c}}
        return {"id": nid(), "kind": "kpi-chart", "name": name, "source": src,
                "columns": [{"id": c, "formula": mref(meas[0]), "name": meas[0],
                             "format": _fmt(_resolve(resolver, meas[0]))}], "value": {"columnId": c}}
    if chart in ("PIE", "DONUT"):
        cid = nid("c"); vid = nid("v")
        cols = [{"id": cid, "formula": dref(dims[0]), "name": dims[0]},
                {"id": vid, "formula": mref(meas[0]), "name": meas[0], "format": _fmt(_resolve(resolver, meas[0]))}]
        # ThoughtSpot renders pies as donuts → use the donut-chart kind (the hole is
        # inherent to the kind; holeValue is only an optional center-label column ref).
        return {"id": nid(), "kind": "donut-chart", "name": name, "source": src, "columns": cols,
                "value": {"id": vid}, "color": {"id": cid}}
    if chart in ("PIVOT_TABLE", "PIVOT") and len(dims) >= 2:
        rid = nid("r"); cidd = nid("k")
        cols = [{"id": rid, "formula": dref(dims[0]), "name": dims[0]},
                {"id": cidd, "formula": dref(dims[1]), "name": dims[1]}]
        mids = []
        for m in meas:
            mid = nid("m"); cols.append({"id": mid, "formula": mref(m), "name": m, "format": _fmt(_resolve(resolver, m))}); mids.append(mid)
        return {"id": nid(), "kind": "pivot-table", "name": name, "source": src, "columns": cols,
                "rowsBy": [{"id": rid}], "columnsBy": [{"id": cidd}], "values": mids}
    if chart in ("TABLE", "ADVANCED_COLUMN"):
        dids, cols, mids, midbyname = [], [], [], {}
        for d in dims:
            did = nid("d"); cols.append({"id": did, "formula": dref(d), "name": d}); dids.append(did)
        for m in meas:
            mid = nid("m"); cols.append({"id": mid, "formula": mref(m), "name": m, "format": _fmt(_resolve(resolver, m))})
            mids.append(mid); midbyname[m] = mid; midbyname[_strip_total(m)] = mid
        cfs = spec.get("conditional_formats") or []
        if cfs and dids and mids:
            # Sigma conditionalFormats ride only pivot-table/input-table — emit the CF
            # table as a pivot (rows=dims, values=measures) to carry the cell coloring.
            cfmt = []
            for r in cfs:
                tgt = midbyname.get(r["col"]) or midbyname.get(_strip_total(r["col"])) or mids[0]
                cfmt.append({"type": "single", "columnIds": [tgt], "condition": r["condition"],
                             "value": r["value"], "style": {"backgroundColor": r["color"]}})
            if cfmt:
                return {"id": nid(), "kind": "pivot-table", "name": name, "source": src, "columns": cols,
                        "rowsBy": [{"id": d} for d in dids], "values": mids, "conditionalFormats": cfmt}
        return {"id": nid(), "kind": "table", "name": name, "source": src, "columns": cols,
                "groupings": [{"id": nid(), "groupBy": dids, "calculations": mids}]}
    # Scatter / bubble — measure-vs-measure with the dimension as the POINT
    # identity (ThoughtSpot measure order = x, y, size). Sigma's scatter axis is
    # a GROUPING axis: putting an aggregate (Sum(...)) straight on xAxis makes it
    # evaluate per source row, so every point collapses to one x (or over-plots).
    # Correct, UI-verified shape (qlik bead ry0n): bind the scatter to a hidden
    # grouped SOURCE table (one row per point dim) sourced off the shared master,
    # reference the grouped columns with RAW refs, and keep the dim on
    # color:{by:category} so distinct points don't merge. BUBBLE's 3rd measure →
    # size:{id}. With no point dim, fall through to the plain axis scatter.
    if chart in ("SCATTER", "BUBBLE") and len(meas) >= 2 and dims:
        eid = nid()
        src_name = "Scatter Source " + re.sub(r'[^A-Za-z0-9]', '', eid)[-6:]
        src_id = eid + "-src"; grp_id = eid + "-g"
        # grouped source columns (live on the hidden table): dim + measures over master
        sdc = nid("c"); sxc = nid("c"); syc = nid("c")
        scols = [{"id": sdc, "formula": dref(dims[0]), "name": dims[0]},
                 {"id": sxc, "formula": mref(meas[0]), "name": meas[0], "format": _fmt(_resolve(resolver, meas[0]))},
                 {"id": syc, "formula": mref(meas[1]), "name": meas[1], "format": _fmt(_resolve(resolver, meas[1]))}]
        scalc = [sxc, syc]
        size_meas = None
        if chart == "BUBBLE" and len(meas) >= 3:
            ssz = nid("c"); size_meas = meas[2]
            scols.append({"id": ssz, "formula": mref(meas[2]), "name": meas[2],
                          "format": _fmt(_resolve(resolver, meas[2]))})
            scalc.append(ssz)
        _SCATTER_SRC.append({"id": src_id, "kind": "table", "name": src_name, "source": src,
                             "columns": scols, "visibleAsSource": False,
                             "groupings": [{"id": grp_id, "groupBy": [sdc], "calculations": scalc}]})
        # scatter element: RAW refs into the grouped source, sourced by groupingId
        def _raw(col):
            return {"id": nid("c"), "formula": f"[{src_name}/{col['name']}]", "name": col["name"]}
        r_dim, r_x, r_y = _raw(scols[0]), _raw(scols[1]), _raw(scols[2])
        cols = [r_dim, r_x, r_y]
        el = {"id": eid, "kind": "scatter-chart", "name": name,
              "source": {"elementId": src_id, "kind": "table", "groupingId": grp_id},
              "columns": cols, "xAxis": {"columnId": r_x["id"]}, "yAxis": {"columnIds": [r_y["id"]]},
              "color": {"by": "category", "column": r_dim["id"]}}
        if size_meas is not None:
            r_sz = _raw(scols[3]); cols.append(r_sz); el["size"] = {"id": r_sz["id"]}
        return el
    if chart in ("SCATTER", "BUBBLE") and len(meas) >= 2:
        # no point dimension: plain measure-vs-measure cartesian off the master
        xc = nid("c"); yc = nid("c")
        cols = [{"id": xc, "formula": mref(meas[0]), "name": meas[0], "format": _fmt(_resolve(resolver, meas[0]))},
                {"id": yc, "formula": mref(meas[1]), "name": meas[1], "format": _fmt(_resolve(resolver, meas[1]))}]
        return {"id": nid(), "kind": "scatter-chart", "name": name, "source": src, "columns": cols,
                "xAxis": {"columnId": xc}, "yAxis": {"columnIds": [yc]}}
    # Combo (column + line) — first measure as bars, remaining measures as line series.
    if chart in ("LINE_COLUMN", "LINE_STACKED_COLUMN") and dims and len(meas) >= 2:
        xc = nid("c"); cols = [{"id": xc, "formula": dref(dims[0]), "name": dims[0]}]; ycids = []
        for i, m in enumerate(meas):
            y = nid("c"); cols.append({"id": y, "formula": mref(m), "name": m, "format": _fmt(_resolve(resolver, m))})
            ycids.append(y if i == 0 else {"columnId": y, "type": "line"})
        return {"id": nid(), "kind": "combo-chart", "name": name, "source": src, "columns": cols,
                "xAxis": {"columnId": xc}, "yAxis": {"columnIds": ycids}}
    # Geographic region NAME (state/country/zip) -> region-map choropleth. Sigma
    # auto-colors from the measure column, so no separate color well is required.
    if chart in ("GEO_AREA", "GEO_BUBBLE") and dims and meas:
        gid = nid("c"); vid = nid("c")
        cols = [{"id": gid, "formula": dref(dims[0]), "name": dims[0]},
                {"id": vid, "formula": mref(meas[0]), "name": meas[0], "format": _fmt(_resolve(resolver, meas[0]))}]
        return {"id": nid(), "kind": "region-map", "name": name, "source": src, "columns": cols,
                "region": {"id": gid, "regionType": _region_type(dims[0])}}
    # ThoughtSpot chart types with NO faithful Sigma equivalent (Sigma has no
    # treemap/gauge/waterfall/funnel/sankey/histogram/candlestick/radar — verified
    # against sigma-workbooks/reference/specification/charts.md). Silently coercing
    # them to a bar-chart MISREPRESENTS the data (a funnel/gauge/sankey is not a
    # bar), so down-convert to a TABLE (data preserved + readable) and FLAG it in
    # the name — same flag-not-drop posture as window formulas — so the assessment
    # surfaces it instead of shipping a misleading chart.
    if chart in _NO_SIGMA_EQUIV:
        cols = [{"id": nid("c"), "formula": dref(d), "name": d} for d in dims]
        cols += [{"id": nid("c"), "formula": mref(m), "name": m,
                  "format": _fmt(_resolve(resolver, m))} for m in meas]
        return {"id": nid(), "kind": "table", "source": src, "columns": cols,
                "name": f"{name} [{chart} → table: no Sigma chart equivalent]"}
    x = nid("x"); cols = [{"id": x, "formula": dref(dims[0]), "name": dims[0]}]; ymids = []
    for m in meas:
        y = nid("y"); cols.append({"id": y, "formula": mref(m), "name": m, "format": _fmt(_resolve(resolver, m))}); ymids.append(y)
    el = {"id": nid(), "kind": KIND.get(chart, "bar-chart"), "name": name, "source": src,
          "columns": cols, "xAxis": {"columnId": x}, "yAxis": {"columnIds": ymids}}
    if color_dim:
        cc = nid("c"); cols.append({"id": cc, "formula": dref(color_dim), "name": color_dim})
        el["color"] = {"by": "category", "column": cc}
    return el

# ── Liveboard filters → interactive Sigma list controls (gap C) ──────────────
# A ThoughtSpot Liveboard carries page-level filters (liveboard.filters[]) that
# apply across every tile. The OLD path turned a viz search-query clause into a
# STATIC per-element list-filter — non-interactive (no dropdown, can't change).
# An interactive Sigma control instead points its VALUE LIST at the master
# column via the double-nested source shape (verified, qlik-to-sigma
# build_control):
#   source: {kind:"source", source:{kind:"table", elementId:<master>}, columnId:<c>}
# so the dropdown populates from the data, AND carries a `filters` target so the
# selection propagates to every chart that sources the master (the single shared
# OFV master = global reach, matching the Liveboard's cross-tile semantics).
_TS_FILTER_OP = {"IN": "include", "EQ": "include", "=": "include", "EQUALS": "include",
                 "NOT_IN": "exclude", "NE": "exclude", "!=": "exclude", "NOT_EQUALS": "exclude"}

def parse_liveboard_filters(lb):
    """Liveboard page filters → [{col, mode, values, type}]. Defensive about the
    TML spelling (filters / runtime_filters; column / column_name; operator /
    type; values / value). Date columns are tagged type='date' so the builder
    emits a date-range control instead of a list."""
    out = []
    raw = lb.get("filters") or lb.get("runtime_filters") or lb.get("filter") or []
    if isinstance(raw, dict):
        raw = raw.get("filters") or raw.get("runtime_filters") or [raw]
    for f in raw:
        if not isinstance(f, dict):
            continue
        col = f.get("column") or f.get("column_name") or f.get("columnName") or f.get("name")
        if isinstance(col, list):
            col = col[0] if col else None
        if not col:
            continue
        col = _strip_total(col)
        op = str(f.get("operator") or f.get("oper") or f.get("type") or "IN").upper()
        vals = f.get("values")
        if vals is None:
            vals = f.get("value")
        if vals is None and isinstance(f.get("filter_content"), dict):
            vals = f["filter_content"].get("values")
        if isinstance(vals, (str, int, float)):
            vals = [vals]
        is_date = bool(re.search(r"date|month|year|quarter|week|day|time", col, re.I))
        out.append({"col": col, "mode": _TS_FILTER_OP.get(op, "include"),
                    "values": [v for v in (vals or []) if v not in (None, "")],
                    "type": "date" if is_date else "list"})
    return out

def liveboard_controls(lb_filters, resolver, master_el, master="OFV", denorm_name="Order Fact View"):
    """Build interactive Sigma controls from Liveboard filters. Returns a list of
    control elements; each is wired to the master so it reaches every chart that
    sources the master. Ensures the target column exists on the master element
    (adds it if a viz didn't already surface it). Dedups by column."""
    controls, seen = [], set()
    for f in lb_filters:
        col = f["col"]
        if col in seen:
            continue
        seen.add(col)
        e = _resolve(resolver, col)
        mcol = next((c for c in master_el["columns"] if c.get("name") in (e["friendly"], col)), None)
        if not mcol:
            # The master element is fed by the denorm VIEW, so a column it doesn't
            # yet surface must reference that view's column — `[<denorm view>/<ofv col>]`,
            # exactly like master_element.add_base (NOT `[OFV/<friendly>]`, which makes
            # the master reference itself and 400s the whole workbook: "Dependency not
            # found"). Any Liveboard filter on an un-surfaced column hit this.
            mcol = {"id": "ofv-%d" % len(master_el["columns"]), "name": e["friendly"],
                    "formula": f"[{denorm_name}/{e['ofv']}]"}
            master_el["columns"].append(mcol)
        cid = mcol["id"]
        ctl_id = re.sub(r"[^A-Za-z0-9]", "", col.title()) + "Filter"
        el = {"id": nid("ctl"), "kind": "control", "controlId": ctl_id, "name": col,
              "filters": [{"source": {"kind": "table", "elementId": master_el["id"]},
                           "columnId": cid}]}
        if f["type"] == "date":
            # date-range needs a flat `mode` and NO value-list source (the column
            # comes from the filter binding); a list control on a datetime target
            # is silently stripped (cross-tool gotcha).
            el.update({"controlType": "date-range", "mode": "between",
                       "includeNulls": "when-no-value-is-selected"})
        else:
            el.update({"controlType": "list", "mode": f["mode"], "selectionMode": "multiple",
                       "values": f.get("values") or [],
                       "source": {"kind": "source",
                                  "source": {"kind": "table", "elementId": master_el["id"]},
                                  "columnId": cid}})
        controls.append(el)
    return controls

def master_element(specs, resolver, dm_id, denorm_elem, denorm_name="Order Fact View"):
    """Master table fed by the DM denorm view. Plain columns pass through; the
    DM's row-level formula columns are NOT on the denorm view, so any row-level
    formula (model or answer) is re-materialized here as a calc column over its
    underlying master columns (recursively); aggregate/window formulas get their
    underlying raw columns surfaced (the aggregate lives on the viz element)."""
    mf = (resolver or {}).get("__model_formulas__") or {}
    seen, cols = {}, []

    def add_base(base):
        e = _resolve(resolver, base)
        if e["friendly"] not in seen:
            seen[e["friendly"]] = 1
            cols.append({"id": "ofv-%d" % len(cols), "name": e["friendly"],
                         "formula": f"[{denorm_name}/{e['ofv']}]"})
        return e["friendly"]

    def materialize(name, expr):
        fr = _resolve(resolver, name)["friendly"]
        if fr in seen:
            return fr
        seen[fr] = 1                       # reserve before recursing into deps
        formula = ts_expr_to_sigma(expr, lambda n: "[%s]" % ensure(n))
        cols.append({"id": "ofv-%d" % len(cols), "name": fr, "formula": formula or "null"})
        return fr

    def ensure(name):
        ent = (resolver or {}).get(name)
        if ent and ent.get("is_formula") and formula_class(mf.get(name, "")) == "row":
            return materialize(name, mf.get(name, ""))
        return add_base(name)

    def add_bucket(name):
        g, inner = date_bucket(name)
        fr = _bucket_friendly(name)
        if fr in seen:
            return fr
        seen[fr] = 1
        ie = _resolve(resolver, inner)
        cols.append({"id": "ofv-%d" % len(cols), "name": fr,
                     "formula": f'DateTrunc("{g}", [{denorm_name}/{ie["ofv"]}])'})
        return fr

    for s in specs:
        mtypes, rfs = s.get("mtypes") or {}, s.get("row_formulas") or {}
        for base in s.get("dims", []) + s["measures"] + [f["col"] for f in s.get("filters", [])]:
            mt = mtypes.get(base)
            if date_bucket(base):                            # Month(date)/Week(date)/… → DateTrunc
                add_bucket(base)
            elif base in rfs:                                # row-level formula dim
                materialize(base, rfs[base])
            elif mt and mt.get("kind") in ("timeshift", "growth"):  # SumIf base over a date scope
                ensure(mt["base"])
                if s.get("date_col"):
                    ensure(s["date_col"])
            elif mt and mt.get("kind") == "window":          # flagged: surface the raw measure
                inner = window_inner_ref(mt.get("expr"))
                ensure(inner) if inner else None
            elif mt and mt.get("kind") == "aggregate":       # element-level agg formula deps
                for rn in expr_refs(mt.get("expr") or ""):
                    ensure(rn)
            elif mt and mt.get("needs_row_calc"):            # e.g. "Total Avg Order Value"
                materialize(base, mf.get(base, ""))
            else:
                ensure(base)
    return {"id": "m-ofv", "name": "OFV", "kind": "table",
            "source": {"dataModelId": dm_id, "elementId": denorm_elem, "kind": "data-model"},
            "columns": cols}
# ── Answer/model formula support (fleet run 2026-06-11, bead d0qu) ───────────
# ThoughtSpot formulas appear at two levels: model TML `formulas:` (worksheet
# formulas — e.g. Order Count = count([ORDER_FACT::ORDER_ID])) and answer-level
# `answer.formulas` on a Liveboard viz (e.g. Return Rate = safe_divide(...)).
# Classification:
#   row        → materialized as a master-element calc column (if/then buckets)
#   aggregate  → translated to a Sigma aggregate formula on the viz element
#   window     → NOT converted (bead 5d9k): the tile is built from the inner
#                raw aggregate and its element name carries a [FLAGGED: …]
#                marker; parity records it as flagged, never silently dropped.
_WINDOW_RE = re.compile(
    r'\b(cumulative_sum|running_total|moving_average|moving_sum|moving_min|moving_max|'
    r'rank|dense_rank|cumulative_average|cumulative_max|cumulative_min|group_aggregate)\s*\(', re.I)
_AGG_FN_RE = re.compile(
    r'\b(sum|count_distinct|unique_count|count_not_null|count|average|avg|max|min|median|'
    r'std_deviation|stddev|variance|sum_if|count_if|average_if|max_if|min_if|unique_count_if)\s*\(', re.I)
_UNIQUE_COUNT_RE = re.compile(r'\bunique\s+count\s*\(', re.I)

TS_AGG_TO_SIGMA = {"SUM": "Sum", "AVERAGE": "Avg", "AVG": "Avg", "MIN": "Min", "MAX": "Max",
                   "COUNT": "Count", "COUNT_DISTINCT": "CountDistinct", "MEDIAN": "Median",
                   "STD_DEVIATION": "StdDev", "VARIANCE": "Variance"}

def formula_class(expr):
    if not expr:
        return "row"
    if _WINDOW_RE.search(expr):
        return "window"
    if _AGG_FN_RE.search(expr) or _UNIQUE_COUNT_RE.search(expr):
        return "aggregate"
    return "row"

def window_fn_name(expr):
    m = _WINDOW_RE.search(expr or "")
    return m.group(1).lower() if m else "window"

def window_inner_ref(expr):
    """First bracketed ref inside a window call — the raw measure to fall back to."""
    m = re.search(r'\(\s*\[([^\]]+)\]', expr or "")
    return m.group(1) if m else None

def expr_refs(expr):
    """All column refs in a TS expr, normalized to worksheet display names."""
    out = []
    for ref in re.findall(r'\[([^\]]+)\]', expr or ""):
        if "::" in ref:
            ref = sigma_display_name(ref.split("::", 1)[1].strip())
        out.append(ref)
    return out

def _balanced_two_args(s, start):
    """Given s[start:] = '( a , b )…' return (a, b, end_index) honoring nesting."""
    depth, args, cur, i = 0, [], "", start
    while i < len(s):
        ch = s[i]
        if ch == "(":
            depth += 1
            if depth > 1:
                cur += ch
        elif ch == ")":
            depth -= 1
            if depth == 0:
                args.append(cur.strip())
                return args[0] if args else "", args[1] if len(args) > 1 else "", i + 1
            cur += ch
        elif ch == "," and depth == 1:
            args.append(cur.strip()); cur = ""
        else:
            cur += ch
        i += 1
    return None, None, len(s)

def _rewrite_safe_divide(s):
    out = s
    while True:
        m = re.search(r'\bsafe_divide\s*\(', out, re.I)
        if not m:
            return out
        a, b, end = _balanced_two_args(out, m.end() - 1)
        if a is None:
            return out
        repl = f"If(IsNull({b}) or {b} = 0, null, {a} / {b})"
        out = out[:m.start()] + repl + out[end:]

def _convert_if_chain(s):
    """`if ( c ) then a else b` (chained else-if) → nested If(...). Conditions in
    the fleet/model TMLs are simple comparisons; nested-paren conditions are out
    of scope (gap-scout catches them)."""
    m = re.match(r'\s*if\s*\((.*?)\)\s*then\s*(.*?)\s*else\s*(.*)$', s, re.S | re.I)
    if not m:
        return s
    cond, then, els = m.group(1).strip(), m.group(2).strip(), m.group(3).strip()
    return f"If({cond}, {then}, {_convert_if_chain(els)})"

def ts_expr_to_sigma(expr, ref):
    """Translate a ThoughtSpot formula expr to a Sigma formula. `ref(name)` maps a
    worksheet column display name to the Sigma reference to emit. Returns None
    for window formulas (flag-not-drop, bead 5d9k)."""
    if formula_class(expr) == "window":
        return None
    s = expr.strip()
    s = re.sub(r'\[([^\]:]+)::([^\]]+)\]', lambda m: f"[{sigma_display_name(m.group(2).strip())}]", s)
    s = _convert_if_chain(s)
    # `<ref> in { "a" , "b" }` → In(<ref>, "a", "b")
    s = re.sub(r'(\[[^\]]+\])\s+in\s*\{([^}]+)\}',
               lambda m: f"In({m.group(1)}, {', '.join(v.strip() for v in m.group(2).split(','))})",
               s, flags=re.I)
    s = _UNIQUE_COUNT_RE.sub("CountDistinct(", s)
    for ts_fn, sig_fn in [("count_distinct", "CountDistinct"), ("unique_count", "CountDistinct"),
                          ("count_not_null", "CountDistinct"), ("std_deviation", "StdDev"),
                          ("average", "Avg"), ("avg", "Avg"), ("variance", "Variance"),
                          ("median", "Median"), ("sum", "Sum"), ("count", "Count"),
                          ("max", "Max"), ("min", "Min")]:
        s = re.sub(r'\b' + ts_fn + r'\s*\(', sig_fn + "(", s, flags=re.I)
    s = _rewrite_safe_divide(s)
    # Map every remaining bracketed ref through the resolver
    s = re.sub(r'\[([^\]/]+)\]', lambda m: ref(m.group(1)), s)
    return re.sub(r'\s+', ' ', s).strip()

def model_formula_map(model_root):
    """{formula display name: expr} from the model/worksheet TML."""
    out = {}
    for f in model_root.get("formulas", []) or []:
        if f.get("name") and f.get("expr"):
            out[f["name"]] = f["expr"]
    return out
