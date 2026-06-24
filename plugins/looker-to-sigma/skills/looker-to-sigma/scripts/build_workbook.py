#!/usr/bin/env python3
"""Dashboard contract -> Sigma workbook spec (LOCAL generation; does not POST).

Consumes the normalized contract from parse_lookml_dashboard.py plus the
explore's view .lkml files (to classify each view.field as a measure or a
dimension and derive its Sigma formula). Emits a /v2/workbooks/spec body:
  - a hidden "Data" page with a master table sourced from a data-model element
  - a dashboard page with one element per Looker tile (kpi/bar/area/line/donut/table)
  - controls from dashboard filters
  - a newspaper -> 24-col grid layout XML string

The data-model id / element id / connection id are pluggable (defaults are
placeholders so the spec generates locally); wire them to a real converted DM
before POSTing. Tile->kind, filter->control, and layout maps follow
refs/dashboard-contract.md and research/looker-dashboard-layout.md.
"""
import argparse, json, os, re, secrets, string, sys, glob

def sid(p="el"): return p + "-" + "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(8))
def disp(seg):  return " ".join(w.capitalize() for w in str(seg).split("_"))
def leaf(field): return field.split(".")[-1]            # users.traffic_source -> traffic_source

# dimension_group timeframe expansion — MIRRORS the DM converter (lookml.ts
# TIMEFRAME_MAP / DEFAULT_TIMEFRAMES): a `dimension_group: order_date` with >1
# timeframes becomes DM columns "Order Date Raw" / "Order Date Date" /
# "Order Date Month" / ...; with <=1 timeframes it stays ONE raw column named
# after the physical SQL column. Dashboard filters routinely reference the
# BARE group name (`order_fact.order_date`) while tiles reference expanded
# fields (`order_fact.order_date_month`) — both must resolve to a real DM
# column display name or the filter binding dies.
TIMEFRAME_SUFFIX = {"raw": "Raw", "time": "Time", "date": "Date", "week": "Week",
                    "month": "Month", "quarter": "Quarter", "year": "Year"}
DEFAULT_TIMEFRAMES = ["raw", "time", "date", "week", "month", "quarter", "year"]

TILE_KIND = {
    "single_value": "kpi-chart", "looker_column": "bar-chart", "looker_bar": "bar-chart",
    "looker_area": "area-chart", "looker_line": "line-chart", "looker_pie": "pie-chart",
    "looker_donut_multiples": "donut-chart", "table": "table", "looker_grid": "table",
    "looker_scatter": "scatter-chart",
}
AGG = {"average": "Avg", "sum": "Sum", "min": "Min", "max": "Max", "median": "Median"}

# ── LookML value_format_name / value_format -> Sigma column format ──────────
# Sigma columns carry an optional `format` object — for numbers:
#   {"kind": "number", "formatString": "<d3-format>"}  (see sigma-workbooks
#   reference/specification/formatting.md). LookML measures declare their display
#   via a named format (`value_format_name`) or a custom Excel-style mask
#   (`value_format`). Map the common named formats to d3 format strings; fall
#   back to a best-effort translation of a custom mask.
VALUE_FORMAT_NAME_MAP = {
    "usd":          "$,.2f",
    "usd_0":        "$,.0f",
    "gbp":          "£,.2f",
    "gbp_0":        "£,.0f",
    "eur":          "€,.2f",
    "eur_0":        "€,.0f",
    "percent_0":    ",.0%",
    "percent_1":    ",.1%",
    "percent_2":    ",.2%",
    "percent_3":    ",.3%",
    "percent_4":    ",.4%",
    "decimal_0":    ",.0f",
    "decimal_1":    ",.1f",
    "decimal_2":    ",.2f",
    "decimal_3":    ",.3f",
    "decimal_4":    ",.4f",
    "id":           "d",            # plain integer, no thousands separator
}

def custom_value_format_to_d3(mask):
    """Best-effort translate a LookML custom value_format (Excel-style mask) to a
    d3 format string. Handles the common shapes: currency prefix, thousands
    separator, fixed decimals, and percent. Returns None if nothing recognizable."""
    if not mask: return None
    m = mask.strip().strip('"')
    is_pct = m.endswith("%")
    sym = ""
    if m[:1] in "$£€¥": sym = m[0]
    has_thousands = "," in m
    dec = 0
    dm = re.search(r"\.(0+|#+)", m)        # ".00" or ".##" -> 2 decimals
    if dm: dec = len(dm.group(1))
    thou = "," if has_thousands else ""
    if is_pct:
        return f"{thou}.{dec}%"
    if sym or has_thousands or dec:
        return f"{sym}{thou}.{dec}f"
    return None

def snowflake_mask_to_format(mask):
    """Snowflake/Oracle TO_CHAR numeric mask -> Sigma format object (or None).
    9 = optional digit, 0 = forced digit, $/£/€/¥ = currency, ',' = thousands,
    '.' = decimal point. Date/text masks return None (loud-warning path)."""
    m = re.sub(r"^FM", "", (mask or "").strip(), flags=re.I)
    if not m or not re.fullmatch(r"[\s$£€¥90,.]+", m):
        return None
    decm = re.search(r"\.([90]+)", m)
    dec = len(decm.group(1)) if decm else 0
    cur = re.search(r"[$£€¥]", m)
    sep = "," if "," in m else ""
    if cur:
        return {"kind": "number", "formatString": f"{cur.group(0)}{sep}.{dec}f",
                "currencySymbol": cur.group(0)}
    if re.search(r"[90]", m):
        return {"kind": "number", "formatString": f"{sep}.{dec}f"}
    return None

def sigma_format_for(value_format_name, value_format):
    """Resolve a LookML measure's format -> a Sigma column `format` object (or None)."""
    fs = None
    if value_format_name:
        fs = VALUE_FORMAT_NAME_MAP.get(value_format_name.strip().lower())
    if fs is None and value_format:
        fs = custom_value_format_to_d3(value_format)
    if not fs: return None
    return {"kind": "number", "formatString": fs}


# ── Looker continuous (by-value) color schemes -> Sigma `scheme` arrays ──────
# Looker's `color_application.collection_id` names a built-in continuous palette.
# Sigma's color:{by:scale} takes an explicit `scheme` array (low->high). Map the
# common Looker collections to representative low->high stops; an unknown
# collection falls back to a neutral sequential ramp. `reverse` flips it. A
# `color_application.custom.colors` array (UI-picked custom ramp) wins outright.
LOOKER_CONT_SCHEME = {
    "default":            ["#f7fbff", "#6baed6", "#08306b"],  # sequential blue
    "blues":              ["#f7fbff", "#6baed6", "#08306b"],
    "sequential":         ["#ffffcc", "#fd8d3c", "#bd0026"],
    "sequential0":        ["#ffffcc", "#fd8d3c", "#bd0026"],
    "diverging":          ["#a50026", "#fee090", "#313695"],  # red-yellow-blue
    "diverging0":         ["#a50026", "#fee090", "#313695"],
    "legacy_diverging":   ["#a50026", "#fee090", "#313695"],
}
LOOKER_CONT_FALLBACK = ["#ffffcc", "#fd8d3c", "#bd0026"]


def looker_color_scheme(color):
    """color_application -> Sigma continuous `scheme` (low->high) for by-measure.
    Honors a custom ramp + `reverse`; else maps the named collection."""
    ca = (color or {}).get("colorApplication") or {}
    custom = ca.get("custom") or {}
    scheme = None
    if isinstance(custom.get("colors"), list) and custom["colors"]:
        scheme = [c for c in custom["colors"] if isinstance(c, str)]
    if not scheme:
        key = str(ca.get("collectionId") or ca.get("paletteId") or "").lower()
        scheme = list(LOOKER_CONT_SCHEME.get(key, LOOKER_CONT_FALLBACK))
    else:
        scheme = list(scheme)
    if ca.get("reverse"):
        scheme.reverse()
    return scheme


def looker_cat_palette(color):
    """Explicit categorical palette Looker declared, low->high, or None. Prefers
    a `colors` array; falls back to the ordered values of `series_colors`."""
    c = color or {}
    pal = [x for x in (c.get("palette") or []) if isinstance(x, str)]
    if pal:
        return pal
    sc = c.get("seriesColors") or {}
    if sc:
        return [v for v in sc.values() if isinstance(v, str)] or None
    return None


# ── parse view files: classify fields as measure (agg + base col) or dimension ──
def parse_join_aliases(model_files):
    """Map a Looker explore join's alias to its underlying view via `from:`.
      explore: order_fact { join: order_date { from: date_dim ... } }
    → {"order_date": "date_dim"}. A dashboard field references the join ALIAS
    (order_date.order_month), but the view file defines the dim under the VIEW
    name (date_dim). Without this map the field can't be resolved to a DM column
    and the tile gets dropped (the `from:`-alias gap). Aliases without `from:`
    (alias == view) are skipped — they already resolve."""
    aliases = {}
    for path in model_files:
        try:
            txt = re.sub(r"#[^\n]*", "", open(path).read())
        except OSError:
            continue
        # join: <alias> { ... from: <view> ... }  (brace-bounded so a later
        # join's from: can't bleed into an earlier alias)
        for m in re.finditer(r"join:\s*(\w+)\s*\{(.*?)\}", txt, re.DOTALL):
            alias, body = m.group(1), m.group(2)
            fm = re.search(r"\bfrom:\s*(\w+)", body)
            if fm and fm.group(1) != alias:
                aliases[alias] = fm.group(1)
    return aliases


def build_field_index(view_files, aliases=None):
    measures = {}   # "view.field" -> (agg_type, base_display_or_None, sql, filters)
    formats = {}    # "view.field" -> Sigma format dict (or None)
    dims = set()    # "view.field"
    view_pk = {}    # "view" -> primary-key dimension name
    yesno = set()   # "view.field" of type:yesno dims — the DM converter names
                    # their boolean calc column "<label> (T-F)"
    dim_groups = {} # "view.group" -> {"timeframes": [...], "phys": display name
                    #   of the physical column (the single-column fallback name)}
    for path in view_files:
        txt = open(path).read()
        txt = re.sub(r"#[^\n]*", "", txt)               # strip comments
        vm = re.search(r"view:\s*(\w+)", txt)
        if not vm: continue
        view = vm.group(1)
        for d in re.finditer(r"\b(dimension|dimension_group)\s*:\s*(\w+)", txt):
            dims.add(f"{view}.{d.group(2)}")
        # dimension_group blocks: capture timeframes + physical column so field
        # refs (bare group OR expanded `<group>_<timeframe>`) resolve to the DM
        # column names the converter actually emits (see TIMEFRAME_SUFFIX).
        for m in re.finditer(r"dimension_group:\s*(\w+)\s*\{", txt):
            name = m.group(1); start = m.end(); depth, i = 1, start
            while i < len(txt) and depth:
                depth += {"{": 1, "}": -1}.get(txt[i], 0); i += 1
            block = txt[start:i]
            if re.search(r"type:\s*duration\b", block):
                continue          # duration groups expand to Days/Hours/… columns
            tfm = re.search(r"timeframes:\s*\[([^\]]*)\]", block)
            tfs = ([t.strip().lower() for t in tfm.group(1).split(",") if t.strip()]
                   if tfm else list(DEFAULT_TIMEFRAMES))
            tfs = [t for t in tfs if t in TIMEFRAME_SUFFIX]
            sqlm = re.search(r"sql:\s*(.+?);;", block, re.S)
            phys = None
            if sqlm:
                r2 = re.search(r"\$\{TABLE\}\.(\w+)", sqlm.group(1))
                if r2: phys = disp(r2.group(1))
            dim_groups[f"{view}.{name}"] = {"timeframes": tfs, "phys": phys or disp(name)}
        # primary key / yesno: scan each dimension block
        for m in re.finditer(r"dimension:\s*(\w+)\s*\{", txt):
            name = m.group(1); start = m.end(); depth, i = 1, start
            while i < len(txt) and depth:
                depth += {"{": 1, "}": -1}.get(txt[i], 0); i += 1
            if re.search(r"primary_key:\s*yes", txt[start:i]):
                view_pk[view] = name
            if re.search(r"type:\s*yesno\b", txt[start:i]):
                yesno.add(f"{view}.{name}")
        # measure blocks: measure: name { ... }
        for m in re.finditer(r"measure:\s*(\w+)\s*\{", txt):
            name = m.group(1); start = m.end()
            depth, i = 1, start
            while i < len(txt) and depth:
                depth += {"{": 1, "}": -1}.get(txt[i], 0); i += 1
            block = txt[start:i]
            mtype = (re.search(r"type:\s*(\w+)", block) or [None, "count"])[1].lower()
            sqlm = re.search(r"sql:\s*(.+?);;", block, re.S)
            base = None
            if sqlm:
                s = sqlm.group(1)
                ref = re.search(r"\$\{(?:TABLE\}\.)?(\w+)\}?", s)  # ${dim} or ${TABLE}.col
                r2 = re.search(r"\$\{TABLE\}\.(\w+)", s)
                base = disp((r2 or ref).group(1)) if (r2 or ref) else None
            key = f"{view}.{name}"
            # filtered measures: filters: [dim: "yes", other: "X"] — keep the
            # (field, value) pairs so the tile formula becomes SumIf/CountIf/…
            mfilters = []
            flm = re.search(r"filters:\s*\[([^\]]*)\]", block)
            if flm:
                mfilters = re.findall(r"([\w.]+)\s*:\s*\"([^\"]*)\"", flm.group(1))
            measures[key] = (mtype, base, (sqlm.group(1).strip() if sqlm else ""), mfilters)
            # capture the measure's display format (named or custom mask)
            vfn = re.search(r"value_format_name:\s*(\w+)", block)
            vf = re.search(r'value_format:\s*"([^"]*)"', block)
            fmt = sigma_format_for(vfn.group(1) if vfn else None, vf.group(1) if vf else None)
            if fmt: formats[key] = fmt
            # TO_CHAR display-mask measure → numeric aggregate + Sigma format
            # (display-identical to the mask; value stays numeric). Unparseable
            # masks keep mtype=string and stay on the loud-warning path.
            if mtype == "string" and sqlm:
                tc = re.match(r"^TO_(?:CHAR|VARCHAR)\s*\(\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNT)\s*\("
                              r"\s*(?:\$\{TABLE\}\.)?(\w+)\s*\)\s*,\s*'([^']+)'\s*\)$",
                              sqlm.group(1).strip(), re.I | re.S)
                tfmt = snowflake_mask_to_format(tc.group(3)) if tc else None
                if tc and tfmt:
                    agg = {"sum": "sum", "avg": "average", "min": "min", "max": "max",
                           "median": "median", "count": "count"}[tc.group(1).lower()]
                    measures[key] = (agg, disp(tc.group(2)),
                                     f"{tc.group(1)}(${{TABLE}}.{tc.group(2)})", mfilters)
                    formats.setdefault(key, tfmt)
    # Register every view's fields under its join ALIAS too, so dashboard refs
    # that use the alias (order_date.order_month) resolve to the underlying view's
    # columns (date_dim's `order` dim_group). The converter already emits the
    # denorm columns under the alias, so this aligns the two sides.
    for alias, view in (aliases or {}).items():
        for f in [k for k in measures if k.startswith(view + ".")]:
            measures.setdefault(f"{alias}.{f.split('.', 1)[1]}", measures[f])
        for f in [k for k in dims if k.startswith(view + ".")]:
            dims.add(f"{alias}.{f.split('.', 1)[1]}")
        for f in [k for k in formats if k.startswith(view + ".")]:
            formats.setdefault(f"{alias}.{f.split('.', 1)[1]}", formats[f])
        for f in [k for k in yesno if k.startswith(view + ".")]:
            yesno.add(f"{alias}.{f.split('.', 1)[1]}")
        for g in [k for k in dim_groups if k.startswith(view + ".")]:
            dim_groups.setdefault(f"{alias}.{g.split('.', 1)[1]}", dim_groups[g])
        if view in view_pk:
            view_pk.setdefault(alias, view_pk[view])
    return measures, dims, view_pk, formats, yesno, dim_groups

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("contract")
    ap.add_argument("--views", required=True, help="dir of *.view.lkml for the explore")
    ap.add_argument("--dm-id", default="<DATA_MODEL_ID>")
    ap.add_argument("--element-id", default="<DENORM_ELEMENT_ID>")
    ap.add_argument("--dm-element-name", default="<DM_ELEMENT_NAME>",
                    help="display name of the data-model element the master pulls from")
    ap.add_argument("--dm-elements", default=None,
                    help="JSON file: [{id,name}] of ALL DM elements — enables one "
                         "master per explore for multi-explore dashboards (each "
                         "explore is matched to the DM element with the same "
                         "normalized name; unmatched explores fall back to "
                         "--element-id/--dm-element-name)")
    ap.add_argument("--master-name", default="Data")
    ap.add_argument("--folder-id", default="<FOLDER_ID>")
    ap.add_argument("--out", default="/tmp/workbook.spec.json")
    ap.add_argument("--strict", action="store_true",
                    help="exit non-zero when a dashboard filter cannot be bound "
                         "(default: drop the control with a loud warning)")
    a = ap.parse_args()

    dash = json.load(open(a.contract))
    # Model files live alongside or one level above the views dir — read their
    # join `from:` aliases so alias-qualified dashboard fields resolve.
    model_files = (glob.glob(os.path.join(a.views, "*.model.lkml"))
                   + glob.glob(os.path.join(a.views, "..", "*.model.lkml")))
    aliases = parse_join_aliases(model_files)
    measures, dims, view_pk, formats, yesno_dims, dim_groups = build_field_index(
        sorted(glob.glob(os.path.join(a.views, "*.view.lkml"))), aliases)
    warnings = []

    # ── per-explore masters ────────────────────────────────────────────────────
    # A Looker dashboard's tiles can hit SEVERAL explores; one master per explore,
    # each sourced from the DM element matching that explore (normalized-name
    # match against --dm-elements). Single-explore dashboards keep the original
    # ids/names ("m-master" / --master-name) so existing behavior is unchanged.
    dm_elements = []
    if a.dm_elements and os.path.exists(a.dm_elements):
        dm_elements = json.load(open(a.dm_elements))

    def _norm(s):
        return re.sub(r"[^a-z0-9]", "", (s or "").lower())

    def dm_el_for(explore):
        # Prefer the DENORMALIZED explore element ("<Explore> View") — it carries
        # every joined dimension as a native flat column, so the workbook master
        # is a single "data table with every field" rather than the base fact +
        # relationship lookups (which leave KPIs reading a thinner element and
        # force every joined ref through a relationship traversal). Fall back to a
        # bare-name match, then the orchestrator-passed denorm id.
        n = _norm(explore)
        for cand in (n + "view", n):
            for e in dm_elements:
                if e.get("name") and _norm(e["name"]) == cand:
                    return e
        return {"id": a.element_id, "name": a.dm_element_name}

    masters = {}   # explore -> {"id","name","dm_el","needed":{display: colId}}
    def master_of(explore):
        ex = explore or next(iter(masters), None)
        if ex not in masters:
            n = len(masters)
            dme = dm_el_for(ex)
            masters[ex] = {
                "id": "m-master" if n == 0 else f"m-master-{n + 1}",
                "name": a.master_name if n == 0 else f"{a.master_name} {n + 1}",
                "dm_el": dme,
                # A denormalized "<Explore> View" element exposes joined columns
                # FLAT ('<Field> (<view>)'); the base fact element only reaches
                # them through a relationship traversal. master_ref keys off this.
                "denorm": (dme.get("name") or "").endswith(" View"),
                "needed": {},
            }
            if n == 1:
                warnings.append("dashboard spans multiple explores — one master "
                                "element per explore (matched to DM elements by name)")
        return masters[ex]

    def master_ref(display, explore):
        """Master-column formula for a display name. On a DENORMALIZED element the
        joined column exists FLAT as '<Field> (<view>)', so reference it directly
        ([<dmEl>/<Field> (<view>)]). On the base fact element it is only reachable
        through the DM relationship named after the join ([<dmEl>/<view>/<Field>])."""
        mst = master_of(explore)
        dme_name = mst["dm_el"]["name"]
        m = re.match(r"^(.*) \((\w+)\)$", display or "")
        if m and not mst["denorm"]:
            return f"[{dme_name}/{m.group(2)}/{m.group(1)}]"
        return f"[{dme_name}/{display}]"

    def fmt_for(f):
        """Sigma column `format` dict for a measure field (or None). Ratio
        measures inherit their own value_format if declared; else best-effort
        percent for ratio-typed measures left unset."""
        return formats.get(f)
    def apply_fmt(col, f):
        """Attach a Sigma number format to a tile column if the LookML measure
        declared one. Mutates+returns col for chaining."""
        ff = fmt_for(f)
        if ff: col["format"] = ff
        return col

    def is_measure(f): return f in measures
    def is_ratio(f):
        """Measure whose sql references other measures or is a type:number arithmetic
        expression (e.g. AOV = revenue/orders) — has no single base column."""
        if not is_measure(f): return False
        mtype, _base, sql = measures[f][:3]
        view = f.split(".")[0]
        refs = [r for r in re.findall(r"\$\{(\w+)\}", sql or "") if f"{view}.{r}" in measures]
        body = re.sub(r"\$\{[^}]+\}", "X", sql or "")
        return bool(refs) or (mtype == "number" and bool(re.search(r"[+\-*/]", body)))
    def ratio_components(f):
        view = f.split(".")[0]
        return [f"{view}.{r}" for r in re.findall(r"\$\{(\w+)\}", measures[f][2])
                if f"{view}.{r}" in measures]
    def dimgroup_display(f):
        """DM column display name for a dimension_group field, or None when `f`
        isn't one. Mirrors the converter's timeframe expansion (lookml.ts):
        multi-timeframe groups expand to '<Group> <Suffix>' columns; a single-
        timeframe group keeps ONE raw column named after the physical column.
        Accepts the BARE group name (dashboard filters: `view.order_date`) and
        expanded timeframe fields (`view.order_date_month`). A bare-group ref
        (no timeframe) prefers the day-grain 'Date' column, then 'Raw'/'Time'."""
        view = f.split(".")[0]; lf = leaf(f)
        entry = dim_groups.get(f"{view}.{lf}"); tf = None; base = lf
        if entry is None:
            m = re.match(r"^(.*)_(\w+)$", lf)
            if m and m.group(2).lower() in TIMEFRAME_SUFFIX:
                entry = dim_groups.get(f"{view}.{m.group(1)}")
                tf, base = m.group(2).lower(), m.group(1)
            if entry is None:
                return None
        tfs = entry["timeframes"]
        if len(tfs) <= 1:
            return entry["phys"]                  # converter emits one raw column
        if tf is None or tf not in tfs:
            tf = next((t for t in ("date", "raw", "time") if t in tfs), tfs[0])
        return f"{disp(base)} {TIMEFRAME_SUFFIX[tf]}"

    def col_display(f, explore):
        """Display name of the MASTER column a field maps to. Joined-view columns
        in the denormalized DM element are disambiguated as '<Field> (<joinAlias>)'
        (the field's view prefix); base-explore-view columns are plain."""
        view = f.split(".")[0]
        suf = "" if view == explore else f" ({view})"
        if is_measure(f):
            if is_ratio(f): return None           # composite — components needed separately
            base = measures[f][1]                 # base column (None for plain count)
            return (base + suf) if base else None
        dg = dimgroup_display(f)
        if dg is not None:
            return dg + suf
        return disp(leaf(f)) + suf
    def pk_display(view, explore):
        """Display name of a view's primary-key column in the denorm element."""
        pk = view_pk.get(view)
        if not pk: return None
        return disp(pk) + ("" if view == explore else f" ({view})")
    def ratio_formula(f, explore):
        """Substitute each ${measure} with its Sigma agg formula; NULLIF→NullIf."""
        view = f.split(".")[0]
        def sub(m):
            key = f"{view}.{m.group(1)}"
            return "(" + formula_for(key, explore) + ")" if key in measures else m.group(0)
        e = re.sub(r"\$\{(\w+)\}", sub, measures[f][2])
        return re.sub(r"\bNULLIF\s*\(", "NullIf(", e, flags=re.I).replace("${TABLE}.", "").strip()
    IF_AGG = {"sum": "SumIf", "count": "CountIf", "count_distinct": "CountDistinctIf",
              "average": "AvgIf", "max": "MaxIf", "min": "MinIf"}

    def measure_filters(f):
        return measures[f][3] if is_measure(f) and len(measures[f]) > 3 else []

    def filter_condition(f, explore):
        """LookML measure filters -> Sigma condition on master columns (or None)."""
        view = f.split(".")[0]
        conds = []
        for ff, fv in measure_filters(f):
            ffq = ff if "." in ff else f"{view}.{ff}"
            fd = col_display(ffq, explore)
            if not fd: return None
            # yesno dims surface in the DM as a boolean calc named "<label> (T-F)"
            # (no "/" — slash-bearing display names are unreferenceable in Sigma)
            if ffq in yesno_dims:
                m = re.match(r"^(.*?)( \(\w+\))?$", fd)
                fd = f"{m.group(1)} (T-F){m.group(2) or ''}"
            need(fd, explore)             # the filter dim must be a master column
            ref = f"[{master_of(explore)['name']}/{fd}]"
            if fv in ("yes", "true"):    conds.append(f"{ref} = True")
            elif fv in ("no", "false"):  conds.append(f"{ref} = False")
            else:                         conds.append(f'{ref} = "{fv}"')
        if not conds: return None
        return conds[0] if len(conds) == 1 else " And ".join(f"({c})" for c in conds)

    def formula_for(f, explore):
        if is_measure(f) and is_ratio(f):
            return ratio_formula(f, explore)
        cd = col_display(f, explore)
        if is_measure(f):
            mtype = measures[f][0]; view = f.split(".")[0]; msql = measures[f][2]
            # date/time measures (MAX/MIN over a dimension_group) → Max/Min
            if mtype in ("date", "datetime", "time"):
                mm = re.match(r"\s*(MAX|MIN)\s*\(", msql or "", re.I)
                if mm and cd:
                    return f"{'Max' if mm.group(1).upper() == 'MAX' else 'Min'}([{master_of(explore)['name']}/{cd}])"
                warnings.append(f"⚠ measure '{f}' (type {mtype}) could not be translated — "
                                f"placeholder text column emitted (review: {msql})")
                return f'"⚠ {leaf(f)}: untranslated {mtype} measure"'
            # display-mask / string measures (TO_CHAR…) have NO Sigma equivalent —
            # NEVER emit a silently-wrong aggregate; placeholder + loud warning.
            if mtype == "string" or re.search(r"\bTO_(CHAR|VARCHAR)\s*\(", msql or "", re.I):
                warnings.append(f"⚠ measure '{f}' is a string/display-mask measure "
                                f"(TO_CHAR-style) with no Sigma formula equivalent — emitted a "
                                f"placeholder text column. Keep the numeric metric and apply a "
                                f"Sigma column format instead. (was: {msql})")
                return f'"⚠ {leaf(f)}: untranslated display measure"'
            # filtered measures → SumIf/CountIf/CountDistinctIf/AvgIf/MaxIf/MinIf
            cond = filter_condition(f, explore)
            if cond:
                fn = IF_AGG.get(mtype)
                if fn:
                    if mtype == "count":
                        return f"CountIf({cond})"
                    if cd:
                        return f"{fn}([{master_of(explore)['name']}/{cd}], {cond})"
                warnings.append(f"⚠ filtered measure '{f}' (type {mtype}) has no *If "
                                f"translation — filter DROPPED, review the value")
            if mtype == "count":
                # plain count on a JOINED view counts that view's entities, not fact
                # rows → CountDistinct on its PK in the denormalized element.
                if view != explore:
                    pkd = pk_display(view, explore)
                    if pkd: return f"CountDistinct([{master_of(explore)['name']}/{pkd}])"
                return "Count()"
            if mtype == "count_distinct": return f"CountDistinct([{master_of(explore)['name']}/{cd}])" if cd else "Count()"
            fn = AGG.get(mtype)
            return f"{fn}([{master_of(explore)['name']}/{cd}])" if fn and cd else "Count()"
        return f"[{master_of(explore)['name']}/{cd}]"
    def _warn_count(f, el):
        if measures.get(f, (None,))[0] == "count":
            v = f.split(".")[0]
            if v != el.get("explore") and not view_pk.get(v):
                warnings.append(f"tile '{el['name']}': '{f}' is a plain count on joined view '{v}' "
                                f"with no primary_key — used Count() (counts fact rows). Add a PK to "
                                f"'{v}' for CountDistinct parity.")

    def refline_value_formula(rl, explore):
        """A Looker reference line's value -> a Sigma refMark `value.formula`
        string. A literal number is kept as-is; a field/measure ref (`view.field`
        or `${view.field}`) is translated to the same Sigma formula the tile
        would use; a bare expr string is passed through. Returns None when there
        is nothing to anchor the line to (range/band lines)."""
        v = rl.get("value")
        if v is None:
            return None
        if isinstance(v, (int, float)):
            return str(v)
        s = str(v).strip()
        if not s:
            return None
        # numeric literal as a string?
        if re.fullmatch(r"-?\d+(\.\d+)?", s):
            return s
        # field reference (view.field or ${view.field}) -> tile formula
        fm = re.fullmatch(r"\$\{([\w.]+)\}", s) or re.fullmatch(r"([\w]+\.[\w]+)", s)
        if fm:
            f = fm.group(1)
            if f in measures or f in dims:
                return formula_for(f, explore)
        return s   # pass an arbitrary expression through untouched

    def looker_refmarks(el):
        """Looker tile reference_lines -> Sigma refMarks (cartesian charts only).
        Mirrors qlik_refmarks: value MUST be the wrapped {type:formula,formula}
        form (a bare number 400s); label.visibility must be 'shown'. Y-anchored
        value/min/max/average/median lines map to axis 'series'; range/band
        reference_types have no single-value Sigma equivalent and are warned +
        skipped rather than emitted wrong."""
        out = []
        for rl in (el.get("referenceLines") or []):
            rtype = rl.get("referenceType") or "line"
            if rtype == "range" or rl.get("rangeStart") is not None or rl.get("rangeEnd") is not None:
                warnings.append(f"tile '{el['name']}': reference RANGE/band has no single-value "
                                "Sigma refMark equivalent — skipped (add a shaded band in the UI)")
                continue
            formula = refline_value_formula(rl, el["explore"])
            if not formula:
                warnings.append(f"tile '{el['name']}': reference line ({rtype}) has no resolvable "
                                f"value — skipped")
                continue
            rm = {"type": "line", "axis": "series",
                  "value": {"type": "formula", "formula": formula},
                  "line": {"color": rl.get("color") or "#ef4444",
                           "width": int(rl["lineWidth"]) if str(rl.get("lineWidth") or "").strip().isdigit() else 2}}
            if rl.get("label"):
                rm["label"] = {"visibility": "shown", "text": rl["label"]}
            out.append(rm)
        return out

    # ── Drop tile fields that don't map to any DM column ─────────────────────
    # A dashboard can reference a field that the --lookml-dir checkout doesn't
    # define (e.g. the dashboard was built against newer LookML — live dashboard
    # 11 referenced order_fact.gross_margin_pct / distinct_order_count that aren't
    # in the local views). The converter never emits such a column, so emitting a
    # workbook ref to it POSTs 400 "Dependency not found" and sinks the WHOLE
    # workbook. Drop these fields with a loud warning instead — same philosophy as
    # the sort-field skip below and post_dm's join-key drop (never crash on one
    # dangling ref). Resolvable = a known measure / dimension / dimension_group /
    # primary key in the view files (the converter's own source of truth).
    def field_resolvable(f):
        if not f or "." not in f:
            return True                      # synthetic/unqualified — leave alone
        if is_measure(f) or f in dims:
            return True
        if dimgroup_display(f) is not None:
            return True
        view, lf = f.split(".")[0], leaf(f)
        return bool(view_pk.get(view)) and lf == view_pk[view]

    for el in dash["elements"]:
        if el.get("tileType") == "text":
            continue
        for key in ("fields", "pivots"):
            vals = el.get(key)
            if not vals:
                continue
            kept = [f for f in vals if field_resolvable(f)]
            for f in vals:
                if f not in kept:
                    warnings.append(
                        f"tile '{el.get('name')}': field '{f}' has no matching DM column "
                        "(not defined in the --lookml-dir views) — dropped to avoid a "
                        "dangling workbook ref. If the dashboard expects it, the LookML "
                        "checkout is stale vs. the live dashboard (try --project).")
            el[key] = kept
        # tile-level hard-filters on an absent field can't bind either — drop them.
        if el.get("filters"):
            el["filters"] = {fld: v for fld, v in el["filters"].items() if field_resolvable(fld)}

    # ── master columns: every dim col used + every measure base col + filter cols ──
    def need(display, explore):
        nd = master_of(explore)["needed"]
        if display and display not in nd: nd[display] = sid("col")
        return nd.get(display)
    for el in dash["elements"]:
        if el.get("tileType") == "text":      # text tiles have no query/fields
            continue
        for f in el["fields"]:
            need(col_display(f, el["explore"]), el["explore"])
            # ratio measures: pull each referenced component measure's base column
            if is_measure(f) and is_ratio(f):
                for comp in ratio_components(f):
                    need(col_display(comp, el["explore"]), el["explore"])
            # plain count on a joined view needs that view's PK column in the master
            if is_measure(f) and measures[f][0] == "count" and f.split(".")[0] != el["explore"]:
                need(pk_display(f.split(".")[0], el["explore"]), el["explore"])
        for p in (el.get("pivots") or []):       # pivot/series fields are master columns too
            need(col_display(p, el["explore"]), el["explore"])
        for fld in (el.get("filters") or {}):        # tile-level hard-filter fields
            need(col_display(fld, el["explore"]), el["explore"])
    for flt in dash["filters"]:
        fld = flt.get("dimension") or flt.get("field")
        if fld: need(col_display(fld, flt.get("explore") or fld.split(".")[0]), flt.get("explore") or fld.split(".")[0])
    # date_filter has no field; bind it to the column tiles listen it to
    for flt in dash["filters"]:
        if flt["type"] == "date_filter" and not flt.get("field"):
            for el in dash["elements"]:
                tgt = el["listen"].get(flt["name"])
                if tgt: flt["_resolvedField"] = tgt; flt["_resolvedExplore"] = el["explore"]; need(col_display(tgt, el["explore"]), el["explore"]); break

    # NOTE: master elements are MATERIALIZED at the end of main() (after the tile
    # and control loops) — tile formulas (e.g. filtered measures) can register
    # additional master columns while building.

    # ── tile -> Sigma element ──
    # Looker newspaper rows are ~40px; Sigma grid rows are ~20px. Mapping them 1:1
    # halves every tile's height — and Sigma SUPPRESSES x-axis category labels (and
    # most y gridline labels) when the chart band is that short, so migrated bar
    # charts rendered with NO category names (same short-band suppression seen on
    # tableau, beads-sigma-tkkv). Scale rows 2x so tile heights land near their
    # Looker pixel heights and axis labels render.
    ROW_SCALE = 2
    elements, layout_items = [], []
    scatter_srcs = []   # hidden grouped SOURCE tables for measure-vs-measure scatters
                        # (one row per point dim); parked on the Data page, no layout slot
    merge_srcs = []     # hidden grouped SOURCE tables for Looker merged-results tiles
                        # (secondary explore pre-grouped to the join-key grain; the
                        # primary tile Lookup()s into them — see attach_merge)

    # API-created dashboards that were never arranged in the Looker UI have
    # layout components with NULL row/column/width/height — auto-flow those
    # into a 2-across grid instead of crashing (None + int).
    _auto_flow_idx = [0]

    def _layout_of(el):
        L = el.get("layout") or {}
        if None in (L.get("row"), L.get("col"), L.get("width"), L.get("height")):
            i = _auto_flow_idx[0]; _auto_flow_idx[0] += 1
            L = {"row": (i // 2) * 8, "col": (i % 2) * 12, "width": 12, "height": 8}
            warnings.append(f"tile '{el.get('name')}': no layout coordinates on the "
                            "Looker dashboard (API-created, never arranged in the UI) — "
                            "auto-flowed to a 2-across grid")
        return L

    def attach_merge(el, base, kind, ex):
        """Auto-join a Looker merged-results tile's SECONDARY sources onto the
        primary tile via the validated Sigma blend pattern: pre-group each
        secondary explore to its join-key grain in a hidden source, then add a
        Max(Lookup(...)) measure column on the primary tile keyed on the merge
        field (Max because the looked-up value is constant within a group, so it
        survives the chart's group-by without fanning out). Falls back to a loud
        warn (primary-only, never a silent partial blend) when a secondary can't
        be resolved to a DM element, the tile kind can't carry an extra measure,
        or the join keys don't map. Verified live: order_fact ⋈ customer_dim on
        region → West $40,862.33 / 9 customers."""
        sec = el.get("_merge_sec")
        if not sec:
            return
        def sec_resolvable(sx):
            n = _norm(sx)
            return any(_norm(e.get("name") or "") in (n, n + "view") for e in dm_elements)
        def sec_measure_formula(field, sx):
            if leaf(field) == "count" and not is_measure(field):
                return "Count()"               # Looker auto-count (not in the .lkml)
            return formula_for(field, sx)
        joined, skipped = [], []
        for s in sec:
            sx = s.get("explore")
            mfs = [mf for mf in (s.get("mergeFields") or []) if mf.get("sourceField") and mf.get("refField")]
            meas = [f for f in (s.get("fields") or []) if is_measure(f) or leaf(f) == "count"]
            if not (sx and mfs and meas and sec_resolvable(sx)
                    and kind in ("bar-chart", "area-chart", "line-chart", "table")):
                skipped.append(s); continue
            sm = master_of(sx)                       # secondary passthrough master (sources its DM element)
            gid = sid("msrc"); gname = f"Merge {disp(sx)} {gid[-5:]}"
            gcols, group_ids, calc_ids, keymap, ok = [], [], [], {}, True
            for mf in mfs:
                kd = col_display(mf["sourceField"], sx)      # join key on the secondary
                rd = col_display(mf["refField"], ex)         # same key on the primary
                if not kd or not rd:
                    ok = False; break
                need(kd, sx); need(rd, ex)
                kid = sid("k")
                gcols.append({"id": kid, "formula": f"[{sm['name']}/{kd}]", "name": kd})
                group_ids.append(kid); keymap[rd] = kd
            if not ok:
                skipped.append(s); continue
            meas_out = []
            for mfield in meas:
                mid = sid("m"); mname = disp(leaf(mfield))
                # the measure's base column must exist on the secondary master so its
                # aggregate (e.g. CountDistinct([Master/Customer Key])) resolves.
                mcd = col_display(mfield, sx)
                if mcd:
                    need(mcd, sx)
                gcols.append(apply_fmt({"id": mid, "formula": sec_measure_formula(mfield, sx), "name": mname}, mfield))
                calc_ids.append(mid); meas_out.append((mname, mfield))
            merge_srcs.append({
                "id": gid, "name": gname, "kind": "table",
                "source": {"kind": "table", "elementId": sm["id"]},
                "columns": gcols,
                "groupings": [{"id": sid("g"), "groupBy": group_ids, "calculations": calc_ids}],
                "visibleAsSource": False})
            key_args = ", ".join(f"[{master_of(ex)['name']}/{rd}], [{gname}/{kd}]"
                                 for rd, kd in keymap.items())
            for mname, mfield in meas_out:
                lid = sid("ml")
                base["columns"].append(apply_fmt(
                    {"id": lid, "formula": f"Max(Lookup([{gname}/{mname}], {key_args}))", "name": mname}, mfield))
                if kind in ("bar-chart", "area-chart", "line-chart"):
                    base.setdefault("yAxis", {}).setdefault("columnIds", []).append(lid)
                elif kind == "table" and base.get("groupings"):
                    base["groupings"][0].setdefault("calculations", []).append(lid)
            joined.append((s, [m[0] for m in meas_out]))
        for s, names in joined:
            keys = ", ".join(mf["refField"] for mf in s["mergeFields"])
            warnings.append(f"✅ tile '{el['name']}': merged-results secondary '{s.get('explore')}' "
                            f"AUTO-JOINED via Sigma blend (Max(Lookup) keyed on {keys}) → added {', '.join(names)}")
        for s in skipped:
            keys = ", ".join(f"{mf.get('sourceField')}={mf.get('refField')}" for mf in (s.get("mergeFields") or []))
            warnings.append(f"⚠⚠ tile '{el['name']}': merged-results secondary '{s.get('explore')}' NOT "
                            f"auto-joined (no resolvable DM element / unsupported tile kind / unmapped keys: {keys}) — "
                            "rendered primary-only; add the join in Sigma. Never a silent partial blend.")

    for el in dash["elements"]:
        # Text/markdown tiles → Sigma text element (kind: "text"). No query, no
        # master columns, no source — just a Markdown `body` (title_text as a
        # heading + body_text). See sigma-workbooks reference/specification/text.md.
        if el["tileType"] == "text":
            eid = sid()
            title = (el.get("titleText") or "").strip()
            bodytxt = (el.get("bodyText") or "").strip()
            parts = []
            # Looker often duplicates the title as a heading in body_text; only
            # prepend title_text as an H1 if body_text doesn't already lead with it.
            first_line = bodytxt.splitlines()[0].lstrip("# ").strip().lower() if bodytxt else ""
            if title and title.lower() != first_line:
                parts.append(f"# {title}")
            if bodytxt:
                parts.append(bodytxt)
            body = "\n\n".join(parts) if parts else (el.get("name") or title or "")
            elements.append({"id": eid, "kind": "text", "body": body})
            L = _layout_of(el); c0 = L["col"] + 1; c1 = L["col"] + 1 + L["width"]
            r0 = L["row"] * ROW_SCALE + 1; r1 = r0 + L["height"] * ROW_SCALE
            layout_items.append((eid, c0, c1, r0, r1, "text"))
            continue
        kind = TILE_KIND.get(el["tileType"])
        if not kind:
            # A merged-results tile sometimes carries no resolvable vis_config.type
            # (Looker stores it on the merge query / set in the UI). Never DROP it —
            # default to bar when it has a dim, else a table — so the merged data
            # still renders and the merge warning below fires.
            if el.get("merge") and el["fields"]:
                kind = "bar-chart" if any(not is_measure(f) for f in el["fields"]) else "table"
                warnings.append(f"tile '{el['name']}': merged-results tile with no vis type — defaulted to {kind}")
            else:
                warnings.append(f"tile '{el['name']}' type '{el['tileType']}' has no Sigma mapping — skipped")
                continue
        # ── merged-results tile (Looker merge_result_id) ──────────────────────
        # Discovery captured the full merge; render the PRIMARY source here and
        # DEFER the secondary join until the tile's columns/axes are built (the
        # join adds Lookup measure columns). attach_merge() runs after the
        # kind-specific block below.
        mrg = el.get("merge")
        el["_merge_sec"] = None
        if mrg and mrg.get("sourceQueries"):
            if mrg.get("error"):
                warnings.append(f"⚠⚠ tile '{el['name']}': merged-results query could not be "
                                f"fetched ({mrg['error']}) — rendered from its primary query only; "
                                "verify the merged columns in Sigma.")
            else:
                el["_merge_sec"] = [s for s in mrg["sourceQueries"] if not s.get("isPrimary")] or None
        ex = el["explore"]
        ms = [f for f in el["fields"] if is_measure(f)]
        ds = [f for f in el["fields"] if not is_measure(f)]

        # ── measure-only grid → a row of KPI tiles ────────────────────────────
        # A Looker table/grid with NO dimensions renders one row of totals. A
        # Sigma table can't aggregate without a grouping (each row evaluates as
        # its own group → row-level values, verified live), so map it to one
        # kpi-chart per measure, splitting the tile's cell horizontally.
        # Untranslatable display-mask measures become a loud ⚠ TEXT tile —
        # never a silently-wrong number.
        if kind == "table" and ms and not ds:
            L = _layout_of(el)
            r0 = L["row"] * ROW_SCALE + 1; r1 = r0 + L["height"] * ROW_SCALE
            def _untranslatable(f):
                mt, _b, msql = measures[f][:3]
                return mt == "string" or bool(re.search(r"\bTO_(CHAR|VARCHAR)\s*\(", msql or "", re.I))
            texts = [f for f in ms if _untranslatable(f)]
            kpis = [f for f in ms if f not in texts]
            n = max(len(kpis) + (1 if texts else 0), 1)
            w = L["width"] / n
            slot = 0
            for f in kpis:
                kid = sid(); cid = sid("v")
                col = apply_fmt({"id": cid, "formula": formula_for(f, ex), "name": disp(leaf(f))}, f)
                kpi_el = {"id": kid, "kind": "kpi-chart",
                          "name": f"{el['name']} · {disp(leaf(f))}",
                          "source": {"elementId": master_of(ex)["id"], "kind": "table"},
                          "columns": [col], "value": {"columnId": cid}}
                elements.append(kpi_el)
                el.setdefault("_emitted", []).append(kpi_el)   # control-targeting (listen:)
                c0 = int(round(L["col"] + slot * w)) + 1
                c1 = int(round(L["col"] + (slot + 1) * w)) + 1
                layout_items.append((kid, c0, c1, r0, r1, "kpi-chart"))
                _warn_count(f, el); slot += 1
            if texts:
                tid = sid()
                body = "\n\n".join(
                    f"**⚠ {leaf(f)}**: display-mask measure (TO_CHAR-style) has no Sigma "
                    "equivalent — keep the numeric metric and apply a Sigma column format."
                    for f in texts)
                elements.append({"id": tid, "kind": "text", "body": body})
                c0 = int(round(L["col"] + slot * w)) + 1
                c1 = int(round(L["col"] + (slot + 1) * w)) + 1
                layout_items.append((tid, c0, c1, r0, r1, "text"))
                for f in texts:
                    warnings.append(f"⚠ tile '{el['name']}': measure '{f}' is untranslatable "
                                    "(TO_CHAR/string display mask) — emitted a WARNING TEXT tile in its place")
            warnings.append(f"tile '{el['name']}': measure-only grid → {len(kpis)} KPI tile(s)"
                            + (f" + {len(texts)} warning text tile(s)" if texts else ""))
            continue
        eid = sid()
        base = {"id": eid, "kind": kind, "name": el["name"], "source": {"elementId": master_of(ex)["id"], "kind": "table"}}
        field2cid = {}   # "view.field" -> tile column id (for sorts: resolution)

        if kind == "kpi-chart":
            vf = formula_for(ms[0], ex) if ms else "Count()"
            cid = sid("v")
            col = {"id": cid, "formula": vf, "name": el["name"]}
            if ms: apply_fmt(col, ms[0])      # carry LookML value_format -> Sigma $/%/decimals
            base["columns"] = [col]
            base["value"] = {"columnId": cid}
            if ms: _warn_count(ms[0], el)
            if el.get("showComparison"):
                warnings.append(f"tile '{el['name']}': Looker show_comparison ({el.get('comparisonType')}) — "
                                f"Sigma KPI spec has no comparison/delta slot; add a second KPI side-by-side or set it in the UI")
        elif kind == "scatter-chart":
            # both axes are measures; the (optional) dimension becomes the point split.
            xf = ms[0] if ms else None
            yf = ms[1] if len(ms) > 1 else None
            sf = ms[2] if len(ms) > 2 else None     # optional size measure
            if ds and xf and yf:
                # Sigma's scatter axis is a GROUPING axis: putting an aggregate
                # (Sum(...)) directly on xAxis makes it evaluate per source row and
                # every point collapses to one x — the spec POSTs but renders wrong
                # (proven on qlik; bead ry0n). Correct shape: bind the scatter to a
                # hidden grouped SOURCE table (one row per point dim) and reference
                # the grouped columns with RAW refs; the dim stays on
                # color:{by:category} so points don't merge.
                src_id = eid + "-src"
                src_name = master_of(ex)["name"] + " Scatter " + eid[-6:]
                grp_id = src_id + "-g"
                dimid, sxid, syid = sid("d"), sid("x"), sid("y")
                dim_col = {"id": dimid, "formula": formula_for(ds[0], ex), "name": col_display(ds[0], ex)}
                src_xcol = apply_fmt({"id": sxid, "formula": formula_for(xf, ex), "name": disp(leaf(xf))}, xf)
                src_ycol = apply_fmt({"id": syid, "formula": formula_for(yf, ex), "name": disp(leaf(yf))}, yf)
                src_cols = [dim_col, src_xcol, src_ycol]
                calc_ids = [sxid, syid]
                src_sz = None
                if sf:
                    szid = sid("s")
                    src_sz = apply_fmt({"id": szid, "formula": formula_for(sf, ex), "name": disp(leaf(sf))}, sf)
                    src_cols.append(src_sz); calc_ids.append(szid)
                scatter_srcs.append({
                    "id": src_id, "kind": "table", "name": src_name,
                    "source": {"elementId": master_of(ex)["id"], "kind": "table"},
                    "columns": src_cols,
                    "groupings": [{"id": grp_id, "groupBy": [dimid], "calculations": calc_ids}],
                    "visibleAsSource": False,
                })
                # scatter element: RAW refs to the grouped source's columns
                def _raw(col):
                    return {"id": sid("c"), "formula": f"[{src_name}/{col['name']}]", "name": col["name"]}
                r_dim, r_x, r_y = _raw(dim_col), _raw(src_xcol), _raw(src_ycol)
                scols = [r_dim, r_x, r_y]
                base["source"] = {"elementId": src_id, "kind": "table", "groupingId": grp_id}
                base["xAxis"] = {"columnId": r_x["id"]}; base["yAxis"] = {"columnIds": [r_y["id"]]}
                base["color"] = {"by": "category", "column": r_dim["id"]}
                if src_sz is not None:
                    r_sz = _raw(src_sz); scols.append(r_sz); base["size"] = {"id": r_sz["id"]}
                base["columns"] = scols
                for mf in [m for m in (xf, yf, sf) if m]: _warn_count(mf, el)
            else:
                # no point dimension (or <2 measures): a single aggregate point is
                # correct, so keep the ungrouped measure-vs-measure shape.
                xid, yid, cols = sid("x"), sid("y"), []
                xcol = {"id": xid, "formula": formula_for(xf, ex) if xf else "Count()",
                        "name": disp(leaf(xf)) if xf else "X"}
                ycol = {"id": yid, "formula": formula_for(yf, ex) if yf else "Count()",
                        "name": disp(leaf(yf)) if yf else "Y"}
                if xf: apply_fmt(xcol, xf)
                if yf: apply_fmt(ycol, yf)
                cols.append(xcol); cols.append(ycol)
                base["columns"] = cols
                base["xAxis"] = {"columnId": xid}; base["yAxis"] = {"columnIds": [yid]}
                if ds:
                    clr = sid("clr")
                    cols.append({"id": clr, "formula": formula_for(ds[0], ex), "name": col_display(ds[0], ex)})
                    base["color"] = {"by": "category", "column": clr}
                    pal = looker_cat_palette(el.get("color"))
                    if pal: base["color"]["colors"] = pal
                for mf in (ms[:2] or []): _warn_count(mf, el)
            rm = looker_refmarks(el)
            if rm: base["refMarks"] = rm
        elif kind in ("bar-chart", "area-chart", "line-chart"):
            cols, ymids = [], []
            xid = sid("x"); xf = ds[0] if ds else (el["fields"][0] if el["fields"] else None)
            cols.append({"id": xid, "formula": formula_for(xf, ex) if xf else "Count()",
                         "name": (col_display(xf, ex) if xf else None) or "Group"})
            if xf: field2cid[xf] = xid
            for mf in (ms or []):
                yid = sid("y")
                cols.append(apply_fmt({"id": yid, "formula": formula_for(mf, ex), "name": disp(leaf(mf))}, mf))
                ymids.append(yid)
                field2cid[mf] = yid
                _warn_count(mf, el)
            if not ymids:
                yid = sid("y"); cols.append({"id": yid, "formula": "Count()", "name": "Count"}); ymids.append(yid)
            base["columns"] = cols
            base["xAxis"] = {"columnId": xid}; base["yAxis"] = {"columnIds": ymids}
            # Looker `looker_bar` renders HORIZONTAL bars, `looker_column` vertical —
            # both map to a Sigma bar-chart, so carry the orientation through (Sigma's
            # default is vertical, so only set it for looker_bar; omit otherwise).
            # Verified field: sigma-workbooks charts.md ("orientation: horizontal").
            if el["tileType"] == "looker_bar":
                base["orientation"] = "horizontal"
            # Looker pivot → Sigma series via the color channel (split/stack by the
            # pivot dimension). One color channel; extra pivots → UI. Reproduce the
            # categorical palette Looker declared (series_colors / colors) when present.
            if el["pivots"]:
                pf = el["pivots"][0]
                pcid = sid("clr")
                cols.append({"id": pcid, "formula": formula_for(pf, ex), "name": col_display(pf, ex)})
                base["color"] = {"by": "category", "column": pcid}
                pal = looker_cat_palette(el.get("color"))
                if pal:
                    base["color"]["colors"] = pal
                if len(el["pivots"]) > 1:
                    warnings.append(f"tile '{el['name']}': multiple pivots {el['pivots']} — only first set as series; add the rest in Sigma UI")
            elif ms and (el.get("color") or {}).get("colorApplication"):
                # No pivot dimension but Looker colors the bars by VALUE (a
                # continuous color_application on the measure). A column can't be on
                # both yAxis and color, so DUPLICATE the (first) measure column and
                # bind color:{by:scale} to the dup with the mapped scheme. Mirrors
                # the qlik byMeasure path (qlik_color).
                base_m = next((c for c in cols if c["id"] == ymids[0]), None)
                if base_m is not None:
                    dupid = sid("clr")
                    dup = {"id": dupid, "formula": base_m["formula"],
                           "name": base_m["name"] + " (color)"}
                    if base_m.get("format"): dup["format"] = base_m["format"]
                    cols.append(dup)
                    base["color"] = {"by": "scale", "column": dupid,
                                     "scheme": looker_color_scheme(el.get("color"))}
            if el["tileType"] == "looker_donut_multiples":
                warnings.append(f"tile '{el['name']}': donut_multiples -> single donut-chart (Looker shows N donuts)")
            rm = looker_refmarks(el)
            if rm: base["refMarks"] = rm
        elif kind in ("pie-chart", "donut-chart"):
            # donut/pie use value + color (slice category), NOT xAxis/yAxis.
            catf = el["pivots"][0] if el["pivots"] else (ds[0] if ds else (el["fields"][0] if el["fields"] else None))
            valf = ms[0] if ms else None
            catid = sid("cat"); valid = sid("val")
            valcol = {"id": valid, "formula": formula_for(valf, ex) if valf else "Count()",
                      "name": (disp(leaf(valf)) if valf else "Count")}
            if valf: apply_fmt(valcol, valf)
            base["columns"] = [
                {"id": catid, "formula": formula_for(catf, ex) if catf else "Count()",
                 "name": (col_display(catf, ex) if catf else None) or "Category"},
                valcol,
            ]
            base["value"] = {"id": valid}      # donut/pie use value.id (KPI uses value.columnId)
            base["color"] = {"id": catid}
            pal = looker_cat_palette(el.get("color"))
            if pal: base["color"]["colors"] = pal
            if catf: field2cid[catf] = catid
            if valf: field2cid[valf] = valid
            if valf: _warn_count(valf, el)
            if el["tileType"] == "looker_donut_multiples":
                warnings.append(f"tile '{el['name']}': donut_multiples → single donut sliced by "
                                f"'{leaf(catf) if catf else 'category'}'; the per-multiple dimension is dropped — review in Sigma")
        elif kind == "table":
            cols, gids, cids = [], [], []
            for f in el["fields"] + (el.get("pivots") or []):
                tcol = {"id": sid("c"), "formula": formula_for(f, ex), "name": disp(leaf(f))}
                if is_measure(f):
                    apply_fmt(tcol, f); _warn_count(f, el); cids.append(tcol["id"])
                else:
                    gids.append(tcol["id"])
                cols.append(tcol)
                field2cid[f] = tcol["id"]
            base["columns"] = cols
            # A Looker table tile is an AGGREGATING query (group by dims, aggregate
            # measures). Without `groupings` a Sigma table with dim + Sum(...) columns
            # renders one row per SOURCE row (no roll-up). Verified shape (hand-PATCH
            # round-trip): groupings:[{id, groupBy:[dim col ids], calculations:[measure
            # col ids]}].
            if gids and cids:
                base["groupings"] = [{"id": sid("g"), "groupBy": gids, "calculations": cids}]
            # Looker grid cell visualizations (vis_config.series_cell_visualizations) →
            # Sigma element-level conditionalFormats on the measure's calc column.
            # KEY (verified live 2026-06-24): Sigma `dataBars` are SIGN-colored — one fill
            # for positive, one for negative — they CANNOT vary the bar color by value.
            # So when Looker colored the bars BY VALUE (a custom_colors palette), the
            # faithful reproduction is a Color scale (`backgroundScale`) that tints the
            # cell low→high, NOT a `dataBars` with a multi-stop `scheme` (Sigma collapses
            # that to a single positive color). A plain Looker bar (no value palette) →
            # `dataBars` (magnitude). Shapes verified: sigma-workbooks tables.md.
            # NOTE: Looker often does NOT expose series_cell_visualizations via the
            # dashboard/query API even when the render shows bars — that render-only case
            # can't be auto-detected here; the Phase-4 visual-QA gate flags it for a
            # manual add (see SKILL.md Phase 3b).
            cviz = el.get("cellVisualizations") or {}
            cfmts = []
            for f in el["fields"]:
                if f in cviz and field2cid.get(f) in cids:
                    scheme = (cviz[f] or {}).get("scheme")
                    if scheme:   # Looker colored the bars by value → Sigma Color scale
                        cfmts.append({"type": "backgroundScale",
                                      "columnIds": [field2cid[f]], "scheme": scheme})
                        warnings.append(
                            f"tile '{el['name']}': Looker value-colored data bars on "
                            f"'{leaf(f)}' → Sigma Color scale (cell tint by value). Sigma "
                            "data bars are sign-colored only, so a value-colored bar isn't "
                            "reproducible; switch this rule to dataBars if you prefer a "
                            "magnitude bar over the value tint.")
                    else:        # plain magnitude bar (no value palette)
                        cfmts.append({"type": "dataBars", "columnIds": [field2cid[f]]})
            if cfmts:
                base["conditionalFormats"] = cfmts
            if el.get("pivots"):
                warnings.append(f"tile '{el['name']}': pivot {el['pivots']} flattened to columns — "
                                f"rebuild as a Sigma pivot-table for true cross-tab")

        # merged-results auto-join (Looker merge_result_id) — adds the secondary
        # explore's measure(s) as Max(Lookup(...)) columns now that base is built.
        attach_merge(el, base, kind, ex)

        # tile-level hard filters → element filters (string values; date/numeric → warn)
        for fld, val in (el.get("filters") or {}).items():
            d = col_display(fld, ex)
            if "date" in leaf(fld).lower() or isinstance(val, (int, float)):
                warnings.append(f"tile '{el['name']}': filter {fld}={val} (date/numeric) — add manually in Sigma")
                continue
            col = next((c for c in base["columns"] if c["name"] == d), None)
            if not col:
                # filter-only field: the tile filters by it but doesn't display it —
                # carry it hidden so the filter works without adding a visible column.
                col = {"id": sid("c"), "formula": f"[{master_of(ex)['name']}/{d}]", "name": d, "hidden": True}
                base["columns"].append(col)
            vals = [v.strip() for v in str(val).split(",") if v.strip()]
            base.setdefault("filters", []).append(
                {"id": sid("f"), "columnId": col["id"], "kind": "list", "mode": "include", "values": vals})
        # tile sorts: -> Sigma sort. Verified shapes (live POST + readback + render,
        # 2026-06-10):
        #   bar/line/area/scatter : xAxis.sort  = {by: <colId>, direction}
        #   pie/donut             : color.sort  = {by: <colId>, direction}
        #   UNGROUPED table       : element sort = [{columnId, direction}]
        #   GROUPED table         : groupings[0].sort = [{columnId, direction}] —
        #     element-level sort on a grouped table 400s with "Sort column not found"
        #     for BOTH groupBy and calculation column ids; nesting the sort inside the
        #     grouping entry is the shape that posts, round-trips, and orders groups.
        for si, s in enumerate(el.get("sorts") or []):
            toks = str(s).split()
            sf = toks[0]
            direction = "descending" if (len(toks) > 1 and toks[1].lower().startswith("desc")) else "ascending"
            cid = field2cid.get(sf)
            if not cid:
                warnings.append(f"tile '{el['name']}': sort field '{sf}' not among the tile's columns — sort skipped")
                continue
            if kind in ("bar-chart", "area-chart", "line-chart", "scatter-chart"):
                if si == 0: base.setdefault("xAxis", {})["sort"] = {"by": cid, "direction": direction}
            elif kind in ("pie-chart", "donut-chart"):
                if si == 0: base.setdefault("color", {})["sort"] = {"by": cid, "direction": direction}
            elif kind == "table":
                if base.get("groupings"):
                    base["groupings"][0].setdefault("sort", []).append({"columnId": cid, "direction": direction})
                else:
                    base.setdefault("sort", []).append({"columnId": cid, "direction": direction})
        # Looker table calcs (dynamic_fields) → Sigma formula columns
        for dyn in (el.get("dynamicFields") or []):
            if not isinstance(dyn, dict):
                continue
            expr = dyn.get("expression") or ""
            label = dyn.get("label") or dyn.get("table_calculation") or "Calc"
            def _subfield(m):
                f = m.group(1)
                return formula_for(f, ex) if is_measure(f) else f"[{master_of(ex)['name']}/{col_display(f, ex)}]"
            sig = re.sub(r"\$\{([\w.]+)\}", _subfield, expr)
            sig = re.sub(r"\brunning_total\s*\(", "CumulativeSum(", sig)
            sig = re.sub(r"\bsum\s*\(", "GrandTotal(", sig)          # pct-of-total denominator
            sig = re.sub(r"\bmean\s*\(", "GrandTotal(", sig)
            if re.search(r"\b(rank|row|offset|pivot_\w+|percentile)\s*\(", sig):
                warnings.append(f"tile '{el['name']}': table calc '{label}' uses an unsupported "
                                f"window fn — review: {expr}")
                continue
            base.setdefault("columns", []).append({"id": sid("tc"), "formula": sig.strip(), "name": label})
        elements.append(base)
        el.setdefault("_emitted", []).append(base)   # control-targeting (listen:)

        # newspaper -> 24-col grid (rows scaled — see ROW_SCALE above)
        L = _layout_of(el); c0 = L["col"] + 1; c1 = L["col"] + 1 + L["width"]
        r0 = L["row"] * ROW_SCALE + 1; r1 = r0 + L["height"] * ROW_SCALE
        layout_items.append((eid, c0, c1, r0, r1, kind))

    # ── controls from dashboard filters (listen-scoped, never dead) ──
    # A Looker dashboard filter applies to EXACTLY the tiles that `listen:` to
    # it, on the per-tile field the listen entry names. The old emission bound
    # ONE master-level target — wrong scope (a master filter propagates into
    # EVERY tile, including non-listeners) AND shipped a dead, untargeted
    # control whenever the master display-name lookup missed. Now:
    #   * tiles are partitioned by their listen-SET; each partition that needs
    #     its own scope is re-sourced through a hidden LISTEN-SCOPE TABLE on
    #     the Data page (control filters may only target TABLE elements — a
    #     chart/KPI target 400s with "Dependency not found", live-verified),
    #     and each control targets exactly the scope tables (or the master,
    #     when every tile of the explore shares one listen-set) of the tiles
    #     that listen; non-listening tiles stay un-targeted BY DESIGN
    #   * an unbindable filter NEVER ships as a dead control: it is DROPPED
    #     with a loud warning naming the unbound field (--strict exits 2)
    #   * the intended scope contract is written to control-scope.json next to
    #     --out: per control {controlId, source_signal, intended/excluded
    #     element matchers} — the downstream coverage lint consumes it
    filter_names = {f["name"] for f in dash["filters"]}

    def listen_set(el):
        return frozenset(k for k in (el.get("listen") or {}) if k in filter_names)

    groups = {}            # (explore, listen-set) -> [contract tiles]
    explore_lsets = {}     # explore -> {listen-set, ...}
    for el in dash["elements"]:
        if not el.get("_emitted"):
            continue
        groups.setdefault((el["explore"], listen_set(el)), []).append(el)
        explore_lsets.setdefault(el["explore"], set()).add(listen_set(el))

    scope_tables = {}      # (explore, listen-set) -> {"id","name","explore","needed":{}}

    all_filters = frozenset(filter_names)

    def scope_for(ex, lset):
        """The hidden scope table for a tile partition — or None when the tile
        can stay on the master Data table. A tile stays on the master when it
        listens to EVERY dashboard filter (the controls all target the master, so
        a private scope would behave identically — this is what keeps KPIs and
        other full-listeners "built off the data table on the data tab"), when the
        explore has a single uniform listen-set, or when it listens to nothing.
        Only a SUBSET-listener (e.g. a breakdown chart that ignores its own
        grouping dimension's filter) needs its own scope so the filters it does
        NOT listen to never reach it."""
        if len(explore_lsets[ex]) == 1 or not lset or lset == all_filters:
            return None
        key = (ex, lset)
        if key not in scope_tables:
            n = len(scope_tables) + 1
            scope_tables[key] = {"id": f"scope-{n}", "explore": ex, "needed": {},
                                 "name": f"{master_of(ex)['name']} Scope {n}"}
        return scope_tables[key]

    # Re-source partitioned tiles through their scope table (formulas rewritten
    # [<Master>/…] -> [<Scope>/…]; the scope passes every master column through).
    for (ex, lset), tiles in groups.items():
        sc = scope_for(ex, lset)
        if sc is None:
            continue
        mname = master_of(ex)["name"]
        for el in tiles:
            el["_scope"] = sc
            for sp in el["_emitted"]:
                sp["source"] = {"kind": "table", "elementId": sc["id"]}
                for c in sp.get("columns", []):
                    if isinstance(c.get("formula"), str):
                        c["formula"] = c["formula"].replace(f"[{mname}/", f"[{sc['name']}/")

    controls, control_scope, dropped_controls = [], [], []
    for flt in dash["filters"]:
        fld = flt.get("dimension") or flt.get("field") or flt.get("_resolvedField")
        ctype = "date-range" if flt["type"] == "date_filter" else "list"
        cid = flt["name"].lower().replace(" ", "-")
        entry = {"controlId": cid, "name": flt["title"], "controlType": ctype,
                 "source_signal": f"looker dashboard filter '{flt['name']}' (per-tile listen: scope)",
                 "intended": [], "excluded": [], "unresolved": []}
        targets, seen_targets, domain = [], set(), None   # domain = (master, colId) for the list value source
        for el in dash["elements"]:
            emitted = el.get("_emitted") or []
            if not emitted:
                continue
            lf = (el.get("listen") or {}).get(flt["name"])
            if not lf:
                entry["excluded"].extend(
                    {"element_id": sp["id"], "element_name": sp.get("name") or el["name"],
                     "reason": "tile does not listen: to this filter (un-targeted by design)"}
                    for sp in emitted)
                continue
            d = col_display(lf, el["explore"])
            if d is None:
                warnings.append(f"⚠ filter '{flt['name']}': tile '{el['name']}' listens via "
                                f"'{lf}' which maps to no master column — tile NOT wired")
                entry["unresolved"].append({"element_name": el["name"], "field": lf})
                continue
            mcol = need(d, el["explore"])               # master carries the field
            if domain is None:
                domain = (master_of(el["explore"]), mcol)
            sc = el.get("_scope")
            if sc is not None:                          # filter lands on the scope table
                tcol = sc["needed"].setdefault(d, sid("sc"))
                tkey = (sc["id"], tcol)
            else:                                       # uniform listen-set: the master
                tcol = mcol
                tkey = (master_of(el["explore"])["id"], tcol)
            if tkey not in seen_targets:
                seen_targets.add(tkey)
                targets.append({"source": {"kind": "table", "elementId": tkey[0]},
                                "columnId": tcol})
            entry["intended"].extend(
                {"element_id": sp["id"], "element_name": sp.get("name") or el["name"],
                 "via_column": d, "target_element": tkey[0]}
                for sp in emitted)
        if not targets:
            why = (f"listening tile field(s) unresolvable: "
                   f"{', '.join(u['field'] for u in entry['unresolved'])}"
                   if entry["unresolved"] else "no tile listens: to it")
            warnings.append(f"⚠⚠ DROPPED control '{flt['name']}'"
                            + (f" (field '{fld}')" if fld else "") + f" — {why}. "
                            "A control that filters nothing never ships; fix the field "
                            "mapping or the listen: wiring, or re-run without the filter.")
            entry.update({"status": "dropped", "reason": why})
            dropped_controls.append(flt["name"])
            control_scope.append(entry)
            continue
        ctrl = {"kind": "control", "id": sid("ctrl"), "controlId": cid,
                "name": flt["title"], "controlType": ctype, "filters": targets}
        if ctype == "list":
            ctrl.update({"mode": "include", "selectionMode": "multiple", "values": [],
                         "source": {"kind": "source",
                                    "source": {"kind": "table", "elementId": domain[0]["id"]},
                                    "columnId": domain[1]}})
        else:
            ctrl["mode"] = "between"
        entry["status"] = "emitted"
        controls.append(ctrl)
        control_scope.append(entry)

    # ── layout finalize: container bands (layout-playbook.md, 2026-06-10) ──
    # The raw newspaper→grid math (above) honors Looker's pixel positions; the
    # final layout groups everything into full-width band CONTAINERS instead of
    # a flat LayoutElement list (flat layouts produce dead zones / detached
    # controls). Spec side: one `kind: container` placeholder element per band
    # plus a header text; layout side: <GridContainer> (NOT <LayoutElement
    # type="grid">, which silently drops children) whose child <LayoutElement>s
    # use CONTAINER-RELATIVE coordinates (rows restart at 1). Band order:
    #   1. header band — dark, full-width, dashboard title (rows 1-3)
    #   2. control band — dashboard filters side-by-side (Looker shows them top)
    #   3. KPI band — full-width strip of equal TALL tiles (>= 6 rows so the
    #      title renders; see memory feedback_sigma_kpi_label_height.md)
    #   4. chart row bands — newspaper rows clustered by row overlap, original
    #      columns/heights preserved inside each band
    GRID = 24
    HDR_H = 3                  # header band height (grid rows)
    CTRL_H = 3                 # control-band height (grid rows)
    KPI_H = 6                  # KPI tile height — >= 5 so the title renders
    HEADER_STYLE = {"backgroundColor": "#0F172A", "borderRadius": "round"}
    page_id = "page-dash"

    def _le(eid, c0, c1, r0, r1):
        return f'  <LayoutElement elementId="{eid}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>'

    def _gc(cid, r0, r1, inner):
        return (f'<GridContainer elementId="{cid}" type="grid" gridColumn="1 / 25" '
                f'gridRow="{r0} / {r1}" gridTemplateColumns="repeat(24, 1fr)" '
                f'gridTemplateRows="auto">\n{inner}\n</GridContainer>')

    band_els, band_xml = [], []   # spec placeholder elements / page-level XML
    page_row = 1

    # (1) header band
    band_els.append({"id": "band-hdr", "kind": "container", "style": dict(HEADER_STYLE)})
    band_els.append({"id": "band-hdrtext", "kind": "text",
                     "body": f'# <span style="color: #FFFFFF">{dash["title"]}</span>'})
    band_xml.append(_gc("band-hdr", page_row, page_row + HDR_H,
                        _le("band-hdrtext", 1, GRID + 1, 1, 1 + HDR_H)))
    page_row += HDR_H

    # (2) control band: dashboard-global filters side-by-side in one container
    if controls:
        n = len(controls)
        cw = max(1, GRID // n)
        x, inner = 1, []
        for i, c in enumerate(controls):
            c1 = (x + cw) if i < n - 1 else (GRID + 1)   # last fills to the edge
            inner.append(_le(c["id"], x, c1, 1, 1 + CTRL_H))
            x = c1
        band_els.append({"id": "band-ctl", "kind": "container"})
        band_xml.append(_gc("band-ctl", page_row, page_row + CTRL_H, "\n".join(inner)))
        page_row += CTRL_H

    # (3) KPI band: pull every KPI out of its Looker position into one strip of
    #     equal, TALL tiles — the only reliable way to keep their titles visible.
    kpi_ids = [e for (e, *_rest, k) in layout_items if k == "kpi-chart"]
    other_items = [it for it in layout_items if it[5] != "kpi-chart"]
    if kpi_ids:
        n = len(kpi_ids)
        kw = max(1, GRID // n)
        x, inner = 1, []
        for i, e in enumerate(kpi_ids):
            c1 = (x + kw) if i < n - 1 else (GRID + 1)   # last fills to the edge
            inner.append(_le(e, x, c1, 1, 1 + KPI_H))
            x = c1
        band_els.append({"id": "band-kpi", "kind": "container"})
        band_xml.append(_gc("band-kpi", page_row, page_row + KPI_H, "\n".join(inner)))
        page_row += KPI_H

    # (4) chart row bands: cluster the remaining newspaper tiles into horizontal
    #     bands by row overlap; one container per band, children relative.
    bands = []
    for it in sorted(other_items, key=lambda i: (i[3], i[1])):
        if bands and it[3] < bands[-1]["r1"]:
            bands[-1]["items"].append(it)
            bands[-1]["r1"] = max(bands[-1]["r1"], it[4])
        else:
            bands.append({"r0": it[3], "r1": it[4], "items": [it]})
    TABLE_MAX_H = 12   # table tiles sized to content, not the Looker tile box —
                       # an over-tall table band renders as a giant dead tile
                       # (layout-playbook.md rule 4)
    for bi, b in enumerate(bands, 1):
        cid = f"band-row-{bi}"
        band_els.append({"id": cid, "kind": "container"})
        h = b["r1"] - b["r0"]
        if all(k == "table" for (*_g, k) in b["items"]) and h > TABLE_MAX_H:
            h = TABLE_MAX_H
        inner = "\n".join(_le(e, c0, c1, min(r0 - b["r0"], h - 1) + 1, min(r1 - b["r0"], h) + 1)
                          for (e, c0, c1, r0, r1, _k) in b["items"])
        band_xml.append(_gc(cid, page_row, page_row + h, inner))
        page_row += h

    # ── layout XML (single top-level field; 24-col grid) ──
    layout_xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
                  f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">\n'
                  + "\n".join(band_xml) + '\n</Page>')

    spec = {
        "name": f"{dash['title']} (from Looker)", "folderId": a.folder_id, "schemaVersion": 1,
        "layout": layout_xml,
        "pages": [
            {"id": "page-data", "name": "Data", "elements": []},  # filled below
            # tiles BEFORE controls: controls now target tile columns directly
            # (per-tile listen: scope) and Sigma resolves spec dependencies in
            # array order — a control referencing a later element 400s with
            # "Dependency not found".
            {"id": page_id, "name": dash["title"], "elements": elements + controls + band_els},
        ],
    }
    master_elements = [{
        "id": m["id"], "name": m["name"], "kind": "table",
        "source": {"dataModelId": a.dm_id, "elementId": m["dm_el"]["id"], "kind": "data-model"},
        "columns": [{"id": cid, "formula": master_ref(d, ex), "name": d}
                    for d, cid in m["needed"].items()],
    } for ex, m in masters.items()]
    # listen-scope tables: full passthrough of the master (so every re-sourced
    # tile formula resolves) — control-targeted columns keep the ids registered
    # in the control loop; the rest get fresh ids.
    scope_elements = [{
        "id": sc["id"], "name": sc["name"], "kind": "table",
        "source": {"kind": "table", "elementId": master_of(ex)["id"]},
        "columns": [{"id": sc["needed"].get(d) or sid("sc"), "name": d,
                     "formula": f"[{master_of(ex)['name']}/{d}]"}
                    for d in master_of(ex)["needed"]],
    } for (ex, _lset), sc in scope_tables.items()]
    # scatter grouped sources (one row per point dim) live on the Data page next
    # to the masters — visibleAsSource:False, so they need no layout slot.
    spec["pages"][0]["elements"] = master_elements + scope_elements + scatter_srcs + merge_srcs

    open(a.out, "w").write(json.dumps(spec, indent=2))
    # intended-scope contract for the control-coverage lint — MUST be the
    # control_lint.rb CONTRACT shape (a Hash; a bare array is silently ignored
    # by the lint and every by-design exclusion would flag PARTIAL):
    #   * sourceFilterSignals = every dashboard filter (incl. dropped ones —
    #     they ARE source signals; the loud build warning + --strict cover them)
    #   * per emitted control: scope = "page" when every tile listens, else the
    #     allowlist of intended (listening) tile element ids; mustReach = those
    #     same ids as hard reach assertions; rich detail keys (intended/
    #     excluded/unresolved) ride along — the lint ignores unknown keys.
    #   * dropped controls live under "dropped" (NOT "controls" — a sidecar
    #     control absent from the spec is a gate-7 "missing control" failure;
    #     the drop is already loud at build time).
    for e in control_scope:
        if e["status"] != "emitted":
            continue
        e["sourceName"] = e["source_signal"]
        reach_ids = sorted({t["element_id"] for t in e["intended"]})
        e["mustReach"] = reach_ids
        e["scope"] = "page" if not e["excluded"] and not e["unresolved"] else reach_ids
    sidecar = {"version": 1, "source": "looker",
               "sourceFilterSignals": len(dash["filters"]),
               "controls": [e for e in control_scope if e["status"] == "emitted"],
               "dropped": [e for e in control_scope if e["status"] != "emitted"]}
    scope_path = os.path.join(os.path.dirname(os.path.abspath(a.out)), "control-scope.json")
    json.dump(sidecar, open(scope_path, "w"), indent=2)
    print(f"wrote {a.out}")
    print(f"  masters: {len(master_elements)} ({', '.join(m['name'] + ':' + str(len(m['columns'])) + ' cols' for m in master_elements)})  tiles: {len(elements)}  controls: {len(controls)}"
          + (f"  listen-scope tables: {len(scope_elements)}" if scope_elements else ""))
    print(f"  control-scope: {scope_path} ({len(controls)} emitted"
          + (f", {len(dropped_controls)} DROPPED: {', '.join(dropped_controls)}" if dropped_controls else "")
          + ")")
    for e in elements:
        print(f"    {e['kind']:11} {e.get('name', '(text)')}")
    if warnings:
        print("\n  WARNINGS:")
        for w in warnings: print("   -", w)
    if a.strict and dropped_controls:
        sys.exit(f"--strict: {len(dropped_controls)} dashboard filter(s) could not be bound: "
                 + ", ".join(dropped_controls))

if __name__ == "__main__":
    main()
