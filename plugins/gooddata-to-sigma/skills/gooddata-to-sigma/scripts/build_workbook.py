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
import argparse, json, re, sys, os

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
import metric_binding as _mb    # noqa: E402  shared DM-metric binder ([Metrics/<name>] over inline re-derive)
_CAT_DIR = _cc.default_catalog_dir(__file__)
VIZ_CAT  = _cc.load(_CAT_DIR, "viz-kind")        # GoodData visualizationUrl -> Sigma element kind
AGG_CAT  = _cc.load(_CAT_DIR, "aggregation")     # MAQL scalar aggregate fn  -> Sigma aggregate fn
FMT_CAT  = _cc.load(_CAT_DIR, "number-format")   # GoodData format mask      -> Sigma format (documents gd_fmt)
CTRL_CAT = _cc.load(_CAT_DIR, "control")         # dashboard filter          -> Sigma control (documents detect_filter)

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
_CHART_KINDS = {"bar-chart", "line-chart", "area-chart", "donut-chart", "pie-chart"}
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

    # --dashboard scoping
    _wid = lambda it: (((it.get("widget") or {}).get("insight") or {}).get("identifier") or {}).get("id")
    target_iids = None
    if a.dashboard:
        dash = next((d for d in an.get("analyticalDashboards", []) if d["id"] == a.dashboard), None)
        if dash:
            target_iids = {_wid(it) for sec in dash["content"].get("layout", {}).get("sections", [])
                           for it in sec.get("items", []) if _wid(it)}

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
    page_elements = []; flags = []
    cid = lambda n: re.sub(r'[^a-z0-9]', '_', n.lower())

    def measures_of(ins):
        out = []
        for b in ins["content"]["buckets"]:
            if b["localIdentifier"] == "measures":
                for it in b["items"]:
                    mid = it["measure"]["definition"]["measureDefinition"]["item"]["identifier"]["id"]
                    out.append((mid, it["measure"].get("title", mid), resolve(metric_maql[mid])))
        return out

    def dims_of(ins, kinds):
        out = []
        for b in ins["content"]["buckets"]:
            if b["localIdentifier"] in kinds:
                for it in b["items"]:
                    aid = it["attribute"]["displayForm"]["identifier"]["id"].rsplit(".", 1)[0]
                    out.append(aid)
        return out

    for iid, ins in insights.items():
        if target_iids is not None and iid not in target_iids: continue  # --dashboard scope
        url = ins["content"]["visualizationUrl"]; title = ins["title"]
        if url in FLAGGED:
            flags.append({"insight": iid, "url": url, "reason": f"{url} has no Sigma equivalent → migrate as table or skip"}); continue
        meas = measures_of(ins)
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

        if url == "local:headline":          # KPI
            page_elements.append({"id": iid, "kind": "kpi-chart", "name": title, "source": SRC_M,
                "columns": mcols[:1], "value": {"columnId": mcols[0]["id"]}})
        elif url == "local:table":            # table (flat) or pivot-table (has columns shelf)
            rows = dims_of(ins, {"attribute", "view"}); colshelf = dims_of(ins, {"columns"})
            dcols = [{"id": cid(attr[a_]["title"]), "formula": dim_ref(a_), "name": attr[a_]["title"]} for a_ in rows + colshelf]
            if colshelf:                      # pivot
                page_elements.append({"id": iid, "kind": "pivot-table", "name": title, "source": SRC_M,
                    "columns": dcols + mcols, "values": [c["id"] for c in mcols],
                    "rowsBy": [{"id": cid(attr[a_]["title"])} for a_ in rows],
                    "columnsBy": [{"id": cid(attr[a_]["title"])} for a_ in colshelf]})
            else:                             # flat aggregated table
                page_elements.append({"id": iid, "kind": "table", "name": title, "source": SRC_M,
                    "columns": dcols + mcols,
                    "groupings": [{"id": "g", "groupBy": [c["id"] for c in dcols], "calculations": [c["id"] for c in mcols]}]})
        elif url in CHART:                    # bar/column/line/area/donut/pie
            kind = CHART[url]; dims = dims_of(ins, {"view", "trend", "segment", "stack"})  # line/area use "trend"
            dcols = [{"id": cid(attr[a_]["title"]), "formula": dim_ref(a_), "name": attr[a_]["title"]} for a_ in dims]
            el = {"id": iid, "kind": kind, "name": title, "source": SRC_M, "columns": dcols + mcols}
            if kind in ("donut-chart", "pie-chart"):
                el["value"] = {"id": mcols[0]["id"]}
                if dcols: el["color"] = {"id": dcols[0]["id"]}
            else:
                if dcols: el["xAxis"] = {"columnId": dcols[0]["id"]}
                el["yAxis"] = {"columnIds": [c["id"] for c in mcols]}
                if url == "local:bar": el["orientation"] = "horizontal"
            page_elements.append(el)
        else:
            flags.append({"insight": iid, "url": url, "reason": f"unmapped visualizationUrl {url}"})

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
                          json.dumps([e.get("columns", []) for e in page_elements])))
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

    # ---- LAYOUT: one Sigma page per GoodData dashboard, control on top ----
    # GoodData dashboards use a 12-col grid (widget size.xl.gridWidth); Sigma uses
    # 24 cols. Map section→row band, gridWidth→column span (×2). The control sits in
    # its own band above the widgets. Applied as the LAST write (a bare spec without
    # it stacks every element full-width). The master detail table + any FOR PREVIOUS
    # trend live on a separate "Data" page.
    elem_by_id = {e["id"]: e for e in page_elements}
    KPI_H, BODY_H, CTL_H, GAP = 6, 13, 3, 1

    def widget_iid(it):
        return (((it.get("widget") or {}).get("insight") or {}).get("identifier") or {}).get("id")

    dash_of = {}
    for d in an.get("analyticalDashboards", []):
        for sec in d["content"].get("layout", {}).get("sections", []):
            for it in sec.get("items", []):
                iid = widget_iid(it)
                if iid and iid in elem_by_id and iid not in dash_of:
                    dash_of[iid] = d["id"]

    def page_xml(pid, placed):
        rows = "\n".join(f'  <LayoutElement elementId="{e}" gridColumn="{c} / {c+cs}" gridRow="{r} / {r+rs}"/>'
                         for e, c, cs, r, rs in placed)
        return f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{pid}">\n{rows}\n</Page>'

    def layout_for(d, present, start_row):
        placed = []; row = start_row
        for sec in d["content"].get("layout", {}).get("sections", []):
            items = [it for it in sec.get("items", []) if widget_iid(it) in present]
            if not items: continue
            col = 1; maxh = 0
            for it in items:
                iid = widget_iid(it)
                gw = (((it.get("size") or {}).get("xl") or {}).get("gridWidth")) or 6
                cspan = max(2, min(24, int(gw) * 2))
                if col + cspan > 25:
                    col = 1; row += maxh + GAP; maxh = 0
                h = KPI_H if elem_by_id[iid]["kind"] == "kpi-chart" else BODY_H
                placed.append((iid, col, cspan, row, h)); col += cspan; maxh = max(maxh, h)
            row += maxh + GAP
        return placed

    pages, xml_pages = [], []
    for d in an.get("analyticalDashboards", []):
        present = [iid for iid in elem_by_id if dash_of.get(iid) == d["id"]]
        if not present: continue
        pid = cid(d.get("title") or d["id"])
        ctl = dash_control.get(d["id"])
        els = ([ctl] if ctl else []) + [elem_by_id[iid] for iid in present]
        placed = []; start = 1
        if ctl:
            placed.append((ctl["id"], 1, 8, 1, CTL_H)); start = 1 + CTL_H + GAP
        placed += layout_for(d, set(present), start)
        pages.append({"id": pid, "name": d.get("title") or d["id"], "elements": els})
        xml_pages.append(page_xml(pid, placed))

    # "Data" page: the master detail table + any orphan (FOR PREVIOUS) elements
    orphans = [e for e in page_elements if e["id"] not in dash_of]
    data_els = [master_el] + orphans
    placed, row = [], 1
    placed.append((MASTER_ID, 1, 24, row, BODY_H)); row += BODY_H + GAP
    for e in orphans:
        h = KPI_H if e["kind"] == "kpi-chart" else BODY_H
        placed.append((e["id"], 1, 24, row, h)); row += h + GAP
    pages.append({"id": "data", "name": "Data", "elements": data_els})
    xml_pages.append(page_xml("data", placed))

    spec = {"name": layout.get("name") or "GoodData Migration", "schemaVersion": 1, "folderId": a.folder_id,
            "pages": pages, "layout": "\n".join(xml_pages)}
    json.dump(spec, open(a.out, "w"), indent=2)
    n_ctl = len(dash_control)
    print(f"workbook -> {a.out}: {len(pages)} page(s), {len(page_elements)} elements, "
          f"{len(mcolumns)} master cols, {n_ctl} date control(s), {len(flags)} flagged")
    for p in pages: print(f"   page '{p['name']}': {len(p['elements'])} elements")
    for fl in flags: print("   FLAG", fl)


if __name__ == "__main__":
    main()
