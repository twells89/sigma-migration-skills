#!/usr/bin/env python3
"""build_workbook.py — GoodData insights + dashboard → Sigma workbook spec.

Binds to the already-migrated Sigma data model (the DM convert.py produced).
A hidden **master detail table** sources the DM fact element at row grain; every
KPI/chart/pivot sources the master. A dashboard's relative date filter becomes a
single Sigma **date-range control** that filters the master's date column — the
filter then propagates down the source lineage to every element (KPIs, charts,
AND the pivot, which can't honor a direct element filter). This mirrors GoodData,
where the dashboard `filterContext` is one control over all widgets, and keeps
the result interactive rather than baking the predicate into each measure.

Measures are resolved by recursively inlining the metric MAQL down to fact
aggregates; refs are then rewritten to the master's columns ([Data/Col]). A
`view`/`trend` attribute on a *related* dataset resolves to a master column fed
by the cross-element reference [FACT/REL/Dim].

Usage:
  python3 build_workbook.py --workspace gd_workspace.json \
     --data-model-id <uuid> --fact-element <elId> --fact-name ORDER_FACT \
     --rel-name EL_CUSTOMER --fact-dataset order --folder-id <uuid> --out wb_spec.json
"""
import argparse, copy, json, re, sys, os, subprocess
from xml.sax.saxutils import quoteattr

# ── documentation-grounded mapping catalogs (SINGLE SOURCE OF TRUTH) ─────────
# Every enumerable classifier map below is loaded from refs/catalogs/<dimension>.json
# — cited rows (GoodData source doc + Sigma target + sigma_verified), complete
# coverage, and a LOUD fallback (flag) on anything unmapped. NO inline mapping literal
# may bypass these catalogs (grep-enforced by tests/test_grounding.py). The
# human-readable coverage matrix in refs/gooddata-coverage.md is GENERATED from these
# files. Loader: shared/lib/coverage_catalog.py (synced to scripts/lib/). Compositional
# logic — gd_fmt() mask parser, detect_filter(), the MAQL resolve(), and the
# BY ALL/WITHIN/FOR hard-MAQL flagging — STAYS as cited code (see each site).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import coverage_catalog as _cc  # noqa: E402
import code_rep as _cr          # noqa: E402  workbook document/envelope adapter
import metric_binding as _mb    # noqa: E402  shared DM-metric binder ([Metrics/<name>] over inline re-derive)
_CAT_DIR = _cc.default_catalog_dir(__file__)
VIZ_CAT  = _cc.load(_CAT_DIR, "viz-kind")        # GoodData visualizationUrl -> Sigma element kind
AGG_CAT  = _cc.load(_CAT_DIR, "aggregation")     # MAQL scalar aggregate fn  -> Sigma aggregate fn
FMT_CAT  = _cc.load(_CAT_DIR, "number-format")   # GoodData format mask      -> Sigma format (documents gd_fmt)
CTRL_CAT = _cc.load(_CAT_DIR, "control")         # dashboard filter          -> Sigma control (documents detect_filter)
FEATURE_CAT = _cc.load(_CAT_DIR, "workbook-feature")  # released workbook structural surfaces

# MAQL scalar aggregate fn -> Sigma aggregate, DERIVED from the aggregation catalog
# (same rows maql.py loads, so the two copies can't drift). Keys upper-cased to match
# the (SUM|AVG|MIN|MAX|MEDIAN) regex; COUNT is carried for coverage but resolved
# compositionally below (COUNT of an attribute -> CountDistinct).
AGG = {r["source"].upper(): r["sigma"] for r in AGG_CAT.rows if r.get("sigma")}

# GoodData visualizationUrl -> Sigma element, DERIVED from the viz-kind catalog.
# The six plain chart types drive CHART; rows with sigma:null are the FLAGGED set
# (no faithful Sigma equivalent -> flag, never guess). local:headline / local:table
# carry their Sigma kind in the catalog for coverage but are matched by NAME in the
# classifier (structural KPI / table-or-pivot build), not through CHART.
_CHART_KINDS = {
    "bar-chart", "line-chart", "area-chart", "donut-chart", "pie-chart",
    "waterfall-chart",
}
CHART = {r["source"]: r["sigma"] for r in VIZ_CAT.rows if r.get("sigma") in _CHART_KINDS}
FLAGGED = {r["source"] for r in VIZ_CAT.rows if r.get("sigma") is None}

MASTER_ID = "master_detail"
MASTER_NAME = "Data"            # downstream refs resolve as [Data/Column]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--data-model-id", required=True)
    ap.add_argument("--fact-element", required=True)
    ap.add_argument("--fact-name", required=True)
    ap.add_argument("--rel-name", required=True)
    ap.add_argument("--fact-dataset", required=True)
    ap.add_argument("--folder-id", required=True)
    ap.add_argument("--dashboard", default=None, help="migrate only this dashboard id (+ its filterContext)")
    ap.add_argument("--feature-gaps-out", default=None,
                    help="optional JSON ledger for released workbook features and loud gaps")
    ap.add_argument("--dm-spec", default=None,
                    help="DM spec JSON (convert.py --out). When present, a measure whose inline "
                         "aggregate matches a metric on the fact element binds to a governed "
                         "[Metrics/<name>] reference instead of re-deriving it inline. Absent → "
                         "inline, byte-identical to before.")
    ap.add_argument("--out", default="wb_spec.json")
    a = ap.parse_args()
    P = a.fact_name  # element-name prefix for the master's own (DM-sourced) formulas

    # DM metrics referenceable on the master (it sources the fact element): a measure
    # whose translated inline aggregate matches one binds to [Metrics/<name>] (governed)
    # instead of re-deriving it. No --dm-spec → empty list → every measure stays inline
    # (byte-identical). Resolution + formula-equivalence matching live in the shared
    # binder (scripts/lib/metric_binding.py). --fact-element must be the DM element id
    # convert.py assigned (CREATE preserves ids), so it keys into the spec's elements.
    metrics = []
    if a.dm_spec and os.path.exists(a.dm_spec):
        try:
            _dm = json.load(open(a.dm_spec))
            _by_id = {e.get("id"): e for pg in _dm.get("pages", []) for e in (pg.get("elements") or [])}
            metrics = _mb.available_metrics(a.fact_element, _by_id)
        except (ValueError, OSError) as e:
            print(f"--dm-spec unreadable ({e}); measures stay inline", file=sys.stderr)

    layout = json.load(open(a.workspace)); ldm = layout["ldm"]; an = layout["analytics"]
    # symbol tables
    attr = {}; fact = {}; metric_maql = {}
    for d in ldm["datasets"]:
        for at in d.get("attributes", []): attr[at["id"]] = {"title": at["title"], "ds": d["id"]}
        for f in d.get("facts", []): fact[f["id"]] = {"title": f["title"], "ds": d["id"]}
    metric_fmt = {}
    for m in an.get("metrics", []):
        metric_maql[m["id"]] = (m.get("content") or {}).get("maql", "")
        metric_fmt[m["id"]] = (m.get("content") or {}).get("format")
    ds_table = {d["id"]: d["dataSourceTableId"]["id"] for d in ldm["datasets"] if d.get("dataSourceTableId")}

    # GoodData metric format mask -> Sigma formatString (kind:number). COMPOSITIONAL
    # parser (NOT a flat lookup): decimals from the digits after '.', currency from a
    # LITERAL '$'/'€' in the mask, percent from a literal '%'. Returns None only when
    # the mask is absent — never a name-substring currency/percent guess. Grounded &
    # cited by refs/catalogs/number-format.json (FMT_CAT) + GoodData metric-formatting
    # + Sigma format-numbers docs; see refs/gooddata-coverage.md.
    def gd_fmt(g):
        if not g:
            return None
        dec = 0
        if "." in g:
            dec = len(g.split(".", 1)[1].split("%")[0].rstrip("0")) or len(g.split(".", 1)[1].split("%")[0])
        cur = "$" if "$" in g else ("€" if "€" in g else "")
        if "%" in g:
            return {"kind": "number", "formatString": f",.{dec}%"}
        return {"kind": "number", "formatString": f"{cur},.{dec}f"}

    # the fact's own YYYYMMDD date-key column on the DM fact element (robust — no
    # dependency on the export's relationship `sources`, which GoodData can drop)
    fds = next((d for d in ldm["datasets"] if d["id"] == a.fact_dataset), None)
    mk = re.search(r"(\w*DATE_KEY)\b", json.dumps(fds or {}), re.I)
    dkey = f"[{P}/{mk.group(1).replace('_', ' ').title()}]" if mk else None

    flags = []
    feature_events = []

    def feature(source, context, status="emitted", detail=None):
        """Resolve and record one released workbook feature decision."""
        row = FEATURE_CAT.resolve(source)
        if row is None:
            warnings = []
            FEATURE_CAT.resolve_or_warn(source, warnings, context=context)
            flags.extend({"feature": source, "context": context, "reason": warning}
                         for warning in warnings)
        event = {
            "source": source,
            "target": (row or {}).get("sigma"),
            "context": context,
            "status": status,
        }
        if detail:
            event["detail"] = detail
        feature_events.append(event)
        return row

    def widget_iid(it):
        """Insight id from declarative-model or Analytics-as-Code widgets."""
        widget = it.get("widget") or it
        insight = widget.get("insight") or widget.get("visualization")
        if isinstance(insight, str):
            return insight
        if isinstance(insight, dict):
            ident = insight.get("identifier") or insight
            if isinstance(ident, dict):
                return ident.get("id")
        return None

    def dashboard_views(dash):
        """Normalize a dashboard into source tabs.

        Legacy declarative dashboards own one ``layout.sections`` collection.
        Newer GoodData Analytics-as-Code dashboards expose ``tabs`` where each
        tab owns its own sections. Those are top-level pages, not regional
        tabbed containers.
        """
        content = dash.get("content") or {}
        tabs = content.get("tabs") or dash.get("tabs") or []
        if tabs:
            out = []
            for n, tab in enumerate(tabs, 1):
                tab_layout = tab.get("layout") or {}
                out.append({
                    "id": (tab.get("localIdentifier") or tab.get("id")
                           or f"tab-{n}"),
                    "name": tab.get("title") or tab.get("name") or f"Tab {n}",
                    "sections": tab.get("sections") or tab_layout.get("sections") or [],
                    "filters": tab.get("filters") or [],
                })
            return out
        layout_ = content.get("layout") or {}
        return [{
            "id": dash.get("id") or "dashboard",
            "name": dash.get("title") or dash.get("id") or "Dashboard",
            "sections": layout_.get("sections") or content.get("sections") or [],
            "filters": [],
        }]

    def section_items(section):
        return section.get("items") or section.get("widgets") or []

    # --dashboard scoping
    target_iids = None
    if a.dashboard:
        dash = next((d for d in an.get("analyticalDashboards", []) if d["id"] == a.dashboard), None)
        if dash:
            target_iids = {
                widget_iid(it)
                for view in dashboard_views(dash)
                for sec in view["sections"]
                for it in section_items(sec)
                if widget_iid(it)
            }

    # a dashboard's relative date filter -> a Sigma date-range control spec.
    # "this month" == {relative, granularity month, from 0, to 0} -> mode current.
    # COMPOSITIONAL parse (NOT a flat lookup); grounded & cited by
    # refs/catalogs/control.json (CTRL_CAT) + GoodData date-filters + Sigma
    # control-types docs. Only relative date filters are emitted this pass; a
    # relative filter with no resolvable date key is flagged downstream, not dropped.
    def detect_filter(dash):
        ref = (dash["content"].get("filterContextRef") or {}).get("identifier", {}).get("id")
        fc = next((f for f in an.get("filterContexts", []) if f["id"] == ref), None)
        if not fc:
            return None
        for fl in fc["content"].get("filters", []):
            df = fl.get("dateFilter")
            if df and df.get("type") == "relative":
                g = (df.get("granularity") or "").lower()
                unit = next((u for u in ("year", "quarter", "month", "week", "day") if u in g), None)
                if not unit:
                    continue
                if df.get("from") == 0 and df.get("to") == 0:
                    return {"mode": "current", "unit": unit}
                n = -int(df.get("from"))                      # from==to==-n => last n (current+offset)
                if df.get("from") == df.get("to") and n > 0:
                    return {"mode": "last", "value": n, "unit": unit, "includeToday": False}
        return None

    # master column accumulator (built after element scan so we know which dims are used)
    needed_xdims = set()   # attribute ids on related datasets that elements reference

    def dim_ref(attr_id):
        a_ = attr[attr_id]
        if a_["ds"] != a.fact_dataset:
            needed_xdims.add(attr_id)
        return f"[{MASTER_NAME}/{a_['title']}]"

    # recursively resolve a metric's MAQL to a Sigma aggregate over the DM fact element.
    # Scalar aggregate fn -> Sigma via the AGG map (derived from refs/catalogs/
    # aggregation.json); COUNT-of-attribute -> CountDistinct compositionally. The hard
    # MAQL surface (BY ALL / WITHIN / FOR) is NOT flat-mappable -> return None to flag
    # it (cited code; see refs/maql-mapping.md + GoodData MAQL docs). Callers surface
    # the flag loudly ("measure uses workbook-level MAQL"), never fake a value.
    def resolve(maql):
        body = re.sub(r"^\s*SELECT\s+", "", " ".join(maql.split()), flags=re.I).strip()
        if re.search(r"BY ALL|WITHIN|\bFOR \b", body, re.I):
            return None  # flagged context/time
        out = re.sub(r"COUNT\(\s*\{attribute/([^}]+)\}\s*\)",
                     lambda m: f"CountDistinct([{P}/{attr[m.group(1)]['title']}])", body, flags=re.I)
        out = re.sub(r"\{fact/([^}]+)\}", lambda m: f"[{P}/{fact[m.group(1)]['title']}]", out)
        out = re.sub(r"(SUM|AVG|MIN|MAX|MEDIAN)\(([^()]*)\)",
                     lambda m: f"{AGG[m.group(1).upper()]}({m.group(2)})", out, flags=re.I)
        out = re.sub(r"\{metric/([^}]+)\}", lambda m: f"({resolve(metric_maql[m.group(1)])})", out)
        return out

    # rewrite a DM-fact-element formula ([FACT/Col] or [FACT/REL/Dim]) onto the master ([Data/Col])
    def to_master(formula):
        if formula is None:
            return None
        return re.sub(rf"\[{re.escape(P)}/(?:[^/\]]+/)?([^\]]+)\]", rf"[{MASTER_NAME}/\1]", formula)

    insights = {i["id"]: i for i in an["visualizationObjects"]}
    # CHART / FLAGGED are derived at module scope from refs/catalogs/viz-kind.json.
    SRC_DM = {"kind": "data-model", "dataModelId": a.data_model_id, "elementId": a.fact_element}
    SRC_M = {"kind": "table", "elementId": MASTER_ID}
    page_elements = []
    support_elements = []
    repeat_children = {}
    cid = lambda n: re.sub(r'[^a-z0-9]', '_', n.lower())

    def bucket_items(ins, kinds):
        return [
            it
            for bucket in (ins.get("content") or {}).get("buckets", [])
            if bucket.get("localIdentifier") in kinds
            for it in bucket.get("items", [])
        ]

    def measure_item(it):
        measure = it.get("measure") or {}
        definition = measure.get("definition") or {}
        md = definition.get("measureDefinition") or {}
        ident = (md.get("item") or {}).get("identifier") or {}
        mid = ident.get("id")
        if not mid or mid not in metric_maql:
            return None
        return mid, measure.get("title", mid), resolve(metric_maql[mid])

    def attribute_id(it):
        attribute = it.get("attribute") or it.get("visualizationAttribute") or {}
        display_form = attribute.get("displayForm") or {}
        ident = display_form.get("identifier") or display_form
        raw = ident.get("id") if isinstance(ident, dict) else None
        return raw.rsplit(".", 1)[0] if raw else None

    def measures_of(ins, kinds=("measures",)):
        out = []
        for it in bucket_items(ins, set(kinds)):
            parsed = measure_item(it)
            if parsed:
                out.append(parsed)
        return out

    def dims_of(ins, kinds):
        return [
            aid for aid in
            (attribute_id(it) for it in bucket_items(ins, kinds))
            if aid in attr
        ]

    def source_legend(ins, context):
        controls = ((ins.get("content") or {}).get("properties") or {}).get("controls") or {}
        raw = controls.get("legend")
        if raw is None:
            return None
        if not isinstance(raw, dict):
            flags.append({"feature": "legend", "context": context,
                          "reason": f"legend metadata must be an object, got {raw!r}"})
            feature("legend", context, status="gap", detail="non-object legend metadata")
            return None
        out = {}
        enabled = raw.get("enabled")
        if isinstance(enabled, bool):
            out["visibility"] = "shown" if enabled else "hidden"
        elif enabled is not None:
            flags.append({"feature": "legend", "context": context,
                          "reason": f"unknown legend enabled value {enabled!r}"})
        position = raw.get("position")
        if position is not None:
            position = str(position).lower()
            if position in {"top", "bottom", "left", "right"}:
                out["position"] = position
            else:
                flags.append({"feature": "legend", "context": context,
                              "reason": f"unknown legend position {position!r}"})
        unknown = sorted(set(raw) - {"enabled", "position", "responsive"})
        if unknown:
            flags.append({"feature": "legend", "context": context,
                          "reason": f"unsupported legend properties {unknown}"})
        if out:
            feature("legend", context)
        return out or None

    def source_style(ins, context):
        content = ins.get("content") or {}
        props = content.get("properties") or {}
        controls = props.get("controls") or {}
        candidates = [
            content.get("style"),
            props.get("style"),
            controls.get("style"),
        ]
        raw = next((candidate for candidate in candidates
                    if isinstance(candidate, dict)), None)
        if raw is None:
            return None
        color = raw.get("backgroundColor")
        if color is None:
            unknown = sorted(set(raw) - {"backgroundColor"})
            if unknown:
                flags.append({"feature": "visual-style", "context": context,
                              "reason": f"unsupported style properties {unknown}"})
            return None
        if (not isinstance(color, str) or not color.strip()
                or re.search(r"\{\{|\{%|\$\{", color)):
            flags.append({"feature": "visual-style", "context": context,
                          "reason": f"dynamic/invalid backgroundColor {color!r} omitted"})
            feature("visual-style", context, status="gap",
                    detail="background color was not a resolved literal")
            return None
        feature("visual-style", context)
        return {"backgroundColor": color.strip()}

    for iid, ins in insights.items():
        if target_iids is not None and iid not in target_iids: continue  # --dashboard scope
        url = ins["content"]["visualizationUrl"]; title = ins["title"]
        if url in FLAGGED:
            row = VIZ_CAT.resolve(url) or {}
            gate = row.get("release_gate")
            reason = (f"{url} is capability-gated ({gate}); no native element emitted"
                      if gate else f"{url} has no Sigma equivalent → migrate as table or skip")
            flags.append({"insight": iid, "url": url, "reason": reason})
            if gate:
                feature("box-chart", f"insight {iid}", status="gap", detail=reason)
            continue
        meas = measures_of(ins, ("measures", "columns") if url == "local:repeater"
                           else ("measures",))
        if any(f is None for _, _, f in meas):
            flags.append({"insight": iid, "reason": "measure uses workbook-level MAQL (BY ALL / FOR)"}); continue
        mcols = []
        for m, t, f in meas:
            # Prefer a governed [Metrics/<name>] ref when this inline aggregate matches a
            # DM metric by formula equivalence; safe no-op (inline) otherwise.
            c = {"id": cid(t) or m, "formula": _mb.metric_ref_or_inline(to_master(f), MASTER_NAME, metrics), "name": t}
            fmt = gd_fmt(metric_fmt.get(m))
            if fmt: c["format"] = fmt
            mcols.append(c)

        emitted = []
        if url == "local:headline":          # KPI
            if not mcols:
                flags.append({"insight": iid, "url": url,
                              "reason": "headline has no resolvable measure"})
                continue
            emitted.append({"id": iid, "kind": "kpi-chart", "name": title, "source": SRC_M,
                            "columns": mcols[:1], "value": {"columnId": mcols[0]["id"]}})
        elif url == "local:table":            # table (flat) or pivot-table (has columns shelf)
            rows = dims_of(ins, {"attribute", "view"}); colshelf = dims_of(ins, {"columns"})
            dcols = [{"id": cid(attr[a_]["title"]), "formula": dim_ref(a_), "name": attr[a_]["title"]} for a_ in rows + colshelf]
            if colshelf:                      # pivot
                emitted.append({"id": iid, "kind": "pivot-table", "name": title, "source": SRC_M,
                    "columns": dcols + mcols, "values": [c["id"] for c in mcols],
                    "rowsBy": [{"columnId": cid(attr[a_]["title"])} for a_ in rows],
                    "columnsBy": [{"columnId": cid(attr[a_]["title"])} for a_ in colshelf]})
            else:                             # flat aggregated table
                emitted.append({"id": iid, "kind": "table", "name": title, "source": SRC_M,
                    "columns": dcols + mcols,
                    "groupings": [{"id": "g", "groupBy": [c["id"] for c in dcols], "calculations": [c["id"] for c in mcols]}]})
        elif url == "local:repeater":
            # GoodData's primary Rows attribute is genuinely data-bound repeat
            # semantics. Build a grouped table source, a native repeated
            # container, and one text child per configured Columns field. A
            # View-by sparkline is a separate mini-chart semantic and remains a
            # loud gap; the row/card repetition is still faithful.
            rows = dims_of(ins, {"rows", "attribute"})
            column_items = bucket_items(ins, {"columns"})
            column_attrs = [
                aid for aid in (attribute_id(it) for it in column_items)
                if aid in attr
            ]
            view_by = dims_of(ins, {"view", "viewBy"})
            if len(rows) != 1 or not column_items:
                reason = ("repeater requires exactly one resolvable Rows attribute "
                          "and at least one Columns item")
                flags.append({"insight": iid, "url": url, "reason": reason})
                feature("repeater", f"insight {iid}", status="gap", detail=reason)
                continue
            dcols = [
                {"id": cid(attr[aid]["title"]), "formula": dim_ref(aid),
                 "name": attr[aid]["title"]}
                for aid in rows + column_attrs
            ]
            source_id = f"{iid}_repeat_source"
            source_name = f"{title} Repeat Source"
            repeat_source = {
                "id": source_id, "kind": "table", "name": source_name,
                "source": SRC_M, "columns": dcols + mcols,
                "groupings": [{
                    "id": f"{cid(iid)}_repeat_group",
                    "groupBy": [c["id"] for c in dcols],
                    "calculations": [c["id"] for c in mcols],
                }],
                "visibleAsSource": False,
            }
            support_elements.append(repeat_source)
            child_columns = dcols[len(rows):] + mcols
            if not child_columns:
                reason = "repeater Columns bucket has no resolvable attribute or measure"
                flags.append({"insight": iid, "url": url, "reason": reason})
                feature("repeater", f"insight {iid}", status="gap", detail=reason)
                support_elements.pop()
                continue
            children = []
            for n, column in enumerate(child_columns, 1):
                child_id = f"{iid}_repeat_cell_{n}"
                children.append(child_id)
                page_elements.append({
                    "id": child_id,
                    "kind": "text",
                    "body": "{{[%s repeated container/%s]}}" %
                            (source_name, column["name"]),
                })
            repeated = {
                "id": iid, "kind": "repeated-container", "name": title,
                "source": {"kind": "table", "elementId": source_id},
                "arrangement": "list", "cardSize": "small", "noDataText": "No rows",
            }
            repeat_children[iid] = children
            emitted.append(repeated)
            feature("repeater", f"insight {iid}")
            if view_by:
                reason = ("GoodData repeater View by inline charts have no equivalent "
                          "inside a Sigma repeated-container card; numeric/text columns preserved")
                flags.append({"insight": iid, "feature": "repeater-inline-chart",
                              "reason": reason})
                feature("repeater-inline-chart", f"insight {iid}",
                        status="gap", detail=reason)
        elif url in CHART:                    # bar/column/line/area/donut/pie
            kind = CHART[url]; dims = dims_of(ins, {"view", "trend", "segment", "stack"})  # line/area use "trend"
            dcols = [{"id": cid(attr[a_]["title"]), "formula": dim_ref(a_), "name": attr[a_]["title"]} for a_ in dims]
            el = {"id": iid, "kind": kind, "name": title, "source": SRC_M, "columns": dcols + mcols}
            if kind in ("donut-chart", "pie-chart"):
                if not mcols:
                    flags.append({"insight": iid, "url": url,
                                  "reason": f"{url} has no resolvable measure"})
                    continue
                el["value"] = {"columnId": mcols[0]["id"]}
                if dcols: el["color"] = {"columnId": dcols[0]["id"]}
            else:
                if not dcols or not mcols:
                    flags.append({"insight": iid, "url": url,
                                  "reason": f"{url} needs a dimension and measure to bind axes"})
                    continue
                el["xAxis"] = {"columnId": dcols[0]["id"]}
                el["yAxis"] = {"columnIds": [c["id"] for c in mcols]}
                if url == "local:bar": el["orientation"] = "horizontal"
                if kind == "waterfall-chart":
                    el["waterfallShape"] = {
                        "calculation": "sum", "connectorLine": "shown"}
                    el["startPoint"] = {
                        "value": {"type": "constant", "value": 0},
                        "visibility": "hidden",
                    }
                    el["grouping"] = "stacked"
                    feature("waterfall", f"insight {iid}")
            emitted.append(el)
        else:
            flags.append({"insight": iid, "url": url, "reason": f"unmapped visualizationUrl {url}"})
            continue

        for element in emitted:
            legend = source_legend(ins, f"insight {iid}")
            if legend and element.get("kind", "").endswith("-chart"):
                element["legend"] = legend
            elif legend:
                flags.append({"insight": iid, "feature": "legend",
                              "reason": "legend metadata present on a non-chart element; omitted"})
            style = source_style(ins, f"insight {iid}")
            if style:
                element["style"] = style
            page_elements.append(element)

    # ---- MASTER detail table: row-grain source for every element above ----
    # Build ONLY the columns the elements actually reference ([Data/<name>]), so a
    # column that doesn't exist on the DM fact element (e.g. an attribute the DM
    # predates) can't sneak in as a broken ref. Candidates: every fact/attribute of
    # the fact dataset ([FACT/name]) + every related dim used ([FACT/REL/name]).
    candidates = {}   # display name -> DM-fact-element formula
    for f in (fds or {}).get("facts", []): candidates[f["title"]] = f"[{P}/{f['title']}]"
    for at in (fds or {}).get("attributes", []): candidates[at["title"]] = f"[{P}/{at['title']}]"
    for aid in needed_xdims:
        a_ = attr[aid]; candidates[a_["title"]] = f"[{P}/{ds_table[a_['ds']]}/{a_['title']}]"
    used = set(re.findall(rf"\[{re.escape(MASTER_NAME)}/([^\]]+)\]",
                          json.dumps([e.get("columns", [])
                                      for e in page_elements + support_elements])))
    mseen = {}; mcolumns = []
    def mcol(name, formula):
        c = cid(name)
        if c not in mseen:
            mseen[c] = {"id": c, "name": name, "formula": formula}; mcolumns.append(mseen[c])
        return c
    for name in sorted(used):
        if name in candidates: mcol(name, candidates[name])
        else: flags.append({"column": name, "reason": "referenced by an element but not found on the DM fact element"})
    order_date_cid = None
    if dkey:
        # parse the YYYYMMDD integer key into a real date for the date-range control
        order_date_cid = mcol("Order Date",
            f"MakeDate(Floor({dkey} / 10000), Floor(Mod({dkey}, 10000) / 100), Mod({dkey}, 100))")
    master_el = {"id": MASTER_ID, "kind": "table", "name": MASTER_NAME, "source": SRC_DM,
                 "columns": mcolumns, "visibleAsSource": False}

    # ---- date-range controls (one per dashboard that has a relative date filter) ----
    dash_control = {}   # dashboard id -> control element
    for d in an.get("analyticalDashboards", []):
        if a.dashboard and d["id"] != a.dashboard:
            continue
        filt = detect_filter(d)
        if filt and order_date_cid:
            ctl = {"id": f"ctl_{cid(d['id'])}"[:60], "kind": "control",
                   "controlId": f"date_{cid(d['id'])}"[:60], "name": "Order Date",
                   "controlType": "date-range",
                   "filters": [{"source": {"kind": "table", "elementId": MASTER_ID}, "columnId": order_date_cid}]}
            ctl.update({k: v for k, v in filt.items()})   # flat top-level mode/unit/value/...
            dash_control[d["id"]] = ctl
        elif filt and not order_date_cid:
            flags.append({"dashboard": d["id"], "reason": "relative date filter present but no YYYYMMDD date key found to build a date control"})

    # ---- TIME_INTEL: FOR PREVIOUS/NEXT metrics -> date-grouped trend + DateLookback ----
    date_for_di = {}
    for d in ldm["datasets"]:
        for r in d.get("references", []):
            for s in r.get("sources", []):
                if (s.get("target") or {}).get("type") == "date":
                    date_for_di[s["target"]["id"]] = (d["id"], s["column"])
    UNITS = {"day", "week", "month", "quarter", "year"}

    def date_ref(di_id):
        ds_id, scol = date_for_di[di_id]
        return f"[{P}/{ds_table[ds_id]}/{scol.replace('_', ' ').title()}]"

    for m in an.get("metrics", []):
        if a.dashboard: break  # trend metric isn't a dashboard widget; skip in single-dashboard mode
        mm = metric_maql.get(m["id"], "")
        fp = re.search(r"FOR\s+(PREVIOUS|NEXT)\(\s*\{label/([^.}]+)\.(\w+)\}(?:\s*,\s*(\d+))?\s*\)", mm, re.I)
        base = re.search(r"\{metric/([^}]+)\}", mm)
        if not (fp and base):
            continue
        direction, di_id, gran, n = fp.group(1).lower(), fp.group(2), fp.group(3).lower(), int(fp.group(4) or 1)
        if di_id not in date_for_di or gran not in UNITS:
            flags.append({"metric": m["id"], "reason": f"FOR {direction}: date dim/granularity not resolvable"}); continue
        base_formula = resolve(metric_maql[base.group(1)])
        if base_formula is None:
            flags.append({"metric": m["id"], "reason": "FOR PREVIOUS base metric not translatable"}); continue
        off = n if direction == "previous" else -n
        eid = cid(m["id"])
        page_elements.append({"id": eid, "kind": "table", "name": m.get("title") or m["id"], "source": SRC_DM,
            "columns": [
                {"id": "ti_period", "name": gran.capitalize(), "formula": f'DateTrunc("{gran}", {date_ref(di_id)})'},
                {"id": "ti_base", "name": base.group(1), "formula": base_formula},
                {"id": "ti_prior", "name": m.get("title") or m["id"],
                 "formula": f'DateLookback({base_formula}, [{gran.capitalize()}], {off}, "{gran}")'}],
            "groupings": [{"id": "ti_g", "groupBy": ["ti_period"], "calculations": ["ti_base", "ti_prior"]}]})

    # ---- RELEASED STRUCTURE + AUTHORITATIVE LAYOUT --------------------------
    # GoodData dashboards use a 12-col grid (widget size.xl.gridWidth); Sigma
    # uses 24 cols. Dashboard tabs are pages, not tabbed-container regions.
    # Pages carry metadata only, every element lives in document.elements, and
    # the required layout is the sole page/container membership authority.
    elem_by_id = {e["id"]: e for e in page_elements}
    KPI_H, BODY_H, CTL_H, NAV_H, GAP = 6, 13, 3, 2, 1

    # GoodData attribute hierarchies ground drill *intent*, but the released
    # workbook spec does not publish the source/category/target binding needed
    # for a working drill control. Keep the gap loud; never add inert chrome.
    for hierarchy in an.get("attributeHierarchies", []):
        hid = hierarchy.get("id") or hierarchy.get("title") or "unnamed"
        reason = ("attribute hierarchy grounds drill-down intent, but no "
                  "authorable Sigma drill binding is published")
        flags.append({"feature": "drill", "hierarchy": hid, "reason": reason})
        feature("attribute-hierarchy-drill", f"hierarchy {hid}",
                status="gap", detail=reason)

    page_defs = []
    for d in an.get("analyticalDashboards", []):
        if a.dashboard and d["id"] != a.dashboard:
            continue
        views = dashboard_views(d)
        content = d.get("content") or {}
        if content.get("filterPanel") or content.get("filterBar"):
            reason = ("GoodData filter chrome is not equivalent to a Sigma "
                      "document header/sidebar panel")
            flags.append({"dashboard": d["id"], "feature": "panels",
                          "reason": reason})
            feature("panels", f"dashboard {d['id']}",
                    status="gap", detail=reason)
        for view in views:
            for section in view["sections"]:
                if section.get("pageBreakAfter") or section.get("printPageBreakAfter"):
                    reason = ("GoodData has no documented print-page-break field; "
                              "unrecognized section marker was not promoted")
                    flags.append({"dashboard": d["id"], "feature": "page-break",
                                  "reason": reason})
                    feature("page-break", f"dashboard {d['id']}",
                            status="gap", detail=reason)
                for item in section_items(section):
                    widget = item.get("widget") or item
                    interactions = widget.get("interactions") or []
                    for interaction in interactions:
                        reason = ("dashboard interaction target is unresolved; "
                                  "no cross-document navigation was invented")
                        flags.append({
                            "dashboard": d["id"],
                            "feature": "navigation-interaction",
                            "interaction": interaction,
                            "reason": reason,
                        })
                        feature(
                            "navigation-interaction",
                            f"dashboard {d['id']} widget {widget_iid(item)}",
                            status="gap", detail=reason)
            present = list(dict.fromkeys([
                widget_iid(it)
                for sec in view["sections"]
                for it in section_items(sec)
                if widget_iid(it) in elem_by_id
            ]))
            if not present:
                continue
            pid = cid("%s_%s" % (d.get("title") or d["id"], view["id"]))
            page_defs.append({
                "id": pid,
                "name": (view["name"] if len(views) > 1
                         else d.get("title") or view["name"]),
                "dashboard": d,
                "view": view,
                "sourceIds": present,
                "hasTabs": len(views) > 1,
            })
            if view["filters"]:
                reason = ("tab-local Analytics-as-Code filters are present but "
                          "not represented in declarative filterContexts")
                flags.append({"dashboard": d["id"], "tab": view["id"],
                              "feature": "tab-filter", "reason": reason})
                feature("tab-filter", f"dashboard {d['id']} tab {view['id']}",
                        status="gap", detail=reason)

    if any(page["hasTabs"] for page in page_defs):
        feature("dashboard-tabs", "GoodData dashboard tabs")

    assigned_source_ids = set()
    assigned_element_ids = set()
    flat_content = []
    xml_pages = []

    def layout_element(element_id, col, cspan, row, rspan, indent="  "):
        return (
            f"{indent}<Element elementId={quoteattr(str(element_id))} "
            f'gridColumn="{col} / {col+cspan}" gridRow="{row} / {row+rspan}"/>'
        )

    def page_xml(pid, placed):
        rows = []
        for element_id, col, cspan, row, rspan, children in placed:
            if children:
                inner = "\n".join(
                    layout_element(child, 1, 12, 1 + n * 3, 3, "    ")
                    for n, child in enumerate(children)
                )
                rows.append(
                    f"  <Container elementId={quoteattr(str(element_id))} "
                    f'type="grid" gridColumn="{col} / {col+cspan}" '
                    f'gridRow="{row} / {row+rspan}" '
                    'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">\n'
                    f"{inner}\n  </Container>"
                )
            else:
                rows.append(layout_element(element_id, col, cspan, row, rspan))
        return (
            f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto" id={quoteattr(str(pid))}>\n'
            + "\n".join(rows) + "\n</Page>"
        )

    def layout_for(view, id_map, start_row):
        placed = []; row = start_row
        for sec in view["sections"]:
            items = [it for it in section_items(sec) if widget_iid(it) in id_map]
            if not items: continue
            col = 1; maxh = 0
            for it in items:
                iid = id_map[widget_iid(it)]
                gw = (((it.get("size") or {}).get("xl") or {}).get("gridWidth")) or 6
                cspan = max(2, min(24, int(gw) * 2))
                if col + cspan > 25:
                    col = 1; row += maxh + GAP; maxh = 0
                h = KPI_H if elem_by_id[iid]["kind"] == "kpi-chart" else BODY_H
                children = repeat_children.get(iid, [])
                placed.append((iid, col, cspan, row, h, children))
                col += cspan; maxh = max(maxh, h)
            row += maxh + GAP
        return placed

    pages = [{"id": page["id"], "name": page["name"]} for page in page_defs]
    page_labels = [{"pageId": page["id"], "label": page["name"]} for page in page_defs]
    seen_source = {}
    for page in page_defs:
        id_map = {}
        for source_id in page["sourceIds"]:
            element = elem_by_id[source_id]
            if source_id in seen_source:
                # Flat elements may occur in layout exactly once. If GoodData
                # reuses one insight widget on multiple tabs, duplicate the
                # element rather than reusing an id in two Page blocks.
                new_id = f"{source_id}_{page['id']}"
                element = copy.deepcopy(element)
                element["id"] = new_id
                elem_by_id[new_id] = element
                if source_id in repeat_children:
                    new_children = []
                    for child_id in repeat_children[source_id]:
                        child = copy.deepcopy(elem_by_id[child_id])
                        child["id"] = f"{child_id}_{page['id']}"
                        elem_by_id[child["id"]] = child
                        flat_content.append(child)
                        assigned_element_ids.add(child["id"])
                        new_children.append(child["id"])
                    repeat_children[new_id] = new_children
            else:
                seen_source[source_id] = page["id"]
            id_map[source_id] = element["id"]
            flat_content.append(element)
            assigned_source_ids.add(source_id)
            assigned_element_ids.add(element["id"])
            for child_id in repeat_children.get(element["id"], []):
                if child_id not in assigned_element_ids:
                    flat_content.append(elem_by_id[child_id])
                    assigned_element_ids.add(child_id)

        placed = []
        start = 1
        if page["hasTabs"]:
            nav = {
                "id": f"nav_{page['id']}", "kind": "navigation",
                "mode": "auto", "pageLabels": page_labels,
            }
            flat_content.append(nav)
            assigned_element_ids.add(nav["id"])
            placed.append((nav["id"], 1, 24, start, NAV_H, []))
            start += NAV_H + GAP
        ctl = dash_control.get(page["dashboard"]["id"])
        if ctl:
            control = copy.deepcopy(ctl)
            control["id"] = f"{ctl['id']}_{page['id']}"
            control["controlId"] = f"{ctl['controlId']}_{page['id']}"
            flat_content.append(control)
            assigned_element_ids.add(control["id"])
            placed.append((control["id"], 1, 8, start, CTL_H, []))
            start += CTL_H + GAP
        placed += layout_for(page["view"], id_map, start)
        xml_pages.append(page_xml(page["id"], placed))

    # "Data" page: the master detail table + any orphan (FOR PREVIOUS) elements
    orphans = [
        e for e in page_elements
        if e["id"] not in assigned_element_ids
        and e["id"] not in {
            child for children in repeat_children.values() for child in children
        }
    ]
    orphan_child_ids = [
        child
        for parent in orphans
        for child in repeat_children.get(parent["id"], [])
    ]
    orphan_children = [elem_by_id[child] for child in orphan_child_ids]
    data_els = [master_el] + support_elements + orphans + orphan_children
    flat_content = data_els + flat_content
    placed, row = [], 1
    for e in data_els:
        if e["id"] in orphan_child_ids:
            continue
        h = KPI_H if e["kind"] == "kpi-chart" else BODY_H
        placed.append((e["id"], 1, 24, row, h,
                       repeat_children.get(e["id"], [])))
        row += h + GAP
    pages.insert(0, {"id": "data", "name": "Data"})
    xml_pages.insert(0, page_xml("data", placed))

    document = {
        "schemaVersion": 1,
        "kind": "workbook",
        "pages": pages,
        "elements": flat_content,
        "overlays": [],
        # GoodData dashboard sections are in-canvas layout, not Sigma header /
        # sidebar chrome. Keep the released collection explicit and do not
        # fabricate panel semantics.
        "panels": [],
        "layout": "\n".join(xml_pages),
    }
    if any(page["hasTabs"] for page in page_defs):
        document["settings"] = {
            "navigation": {"pageTabsInViewMode": "shown"}
        }
    spec = _cr.wrap(
        document,
        {"name": layout.get("name") or "GoodData Migration",
         "folderId": a.folder_id},
    )

    # Hard local invariant: every flat element appears exactly once in required
    # layout and no page carries a legacy nested elements collection.
    flat_ids = [e["id"] for e in _cr.workbook_elements(spec)]
    placed_ids = [
        eid
        for ids in _cr.workbook_page_element_ids(spec).values()
        for eid in ids
    ]
    if (len(flat_ids) != len(set(flat_ids))
            or sorted(flat_ids) != sorted(placed_ids)
            or len(placed_ids) != len(set(placed_ids))):
        raise ValueError(
            "authoritative layout must place every flat workbook element exactly once")
    if any("elements" in page for page in _cr.document(spec)["pages"]):
        raise ValueError("workbook pages must contain metadata only")

    # Pin LF output so corpus goldens are byte-identical on Windows as well as
    # Unix. Python's default text mode translates "\n" to CRLF on Windows.
    with open(a.out, "w", newline="\n") as output:
        json.dump(spec, output, indent=2)
    if a.feature_gaps_out:
        with open(a.feature_gaps_out, "w", newline="\n") as output:
            json.dump({
                "version": 1,
                "source": "gooddata",
                "features": feature_events,
                "gaps": flags,
            }, output, indent=2)
    n_ctl = len(dash_control)
    print(f"workbook -> {a.out}: {len(pages)} page(s), {len(flat_content)} elements, "
          f"{len(mcolumns)} master cols, {n_ctl} date control(s), {len(flags)} flagged")

    # gate 7 (control-wiring lint): FAIL the build if a control does not filter
    # every same-page KPI/chart (partial reach), is dead (no resolving target),
    # or points at a ghost element. Runs the shared, proven
    # scripts/lib/control_lint.rb on the just-built spec — the same hard gate the
    # other converters ship — so a control that "only filters the table, not the
    # KPIs/charts" can never ship silently. No live API needed (lints the spec).
    # (Runtime flip proof / gate 7b needs a live-posted workbook; the agent runs
    # probe-controls.rb after POST — see SKILL.md.)
    _cl = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "control_lint.rb")
    if os.path.exists(_cl):
        _lint = subprocess.run(["ruby", _cl, a.out], capture_output=True, text=True)
        sys.stdout.write(_lint.stdout)
        sys.stderr.write(_lint.stderr)
        if _lint.returncode != 0:
            sys.stderr.write(
                "\n[FAIL] gate 7 (control lint): control-wiring violation(s) above. A control "
                "must target the page's SOURCE element so Sigma propagates the filter to EVERY "
                "element (KPIs + charts + tables), not just one. Fix the wiring before shipping.\n")
            sys.exit(9)
    else:
        sys.stderr.write(
            "[WARN] gate 7: scripts/lib/control_lint.rb not vendored — control wiring UNLINTED "
            "(re-vendor; SHA-1 discipline)\n")
    page_members = _cr.workbook_page_element_ids(spec)
    for p in pages:
        print(f"   page '{p['name']}': {len(page_members.get(p['id'], []))} elements")
    for fl in flags: print("   FLAG", fl)


if __name__ == "__main__":
    main()
