#!/usr/bin/env python3
"""extract-report-classic.py — adapter for the CLASSIC single-file report.json.

Some Power BI reports come back from Fabric getDefinition as the legacy
single `report.json` (top-level `sections[]` with `visualContainers[]`, each
carrying a `config` JSON string) rather than the new exploded PBIR
(`definition/pages/<pg>/visuals/<id>/visual.json`). extract-pbir.py only
handles the new layout; this adapter normalizes the classic shape into the
SAME signals.json schema so build-workbook-from-pbir.rb can consume it.

Classic report.json shape:
  sections[] : { name, displayName, width, height, visualContainers[] }
    visualContainers[] : { x, y, width, height, z, config(JSON string) }
      config : { name, singleVisual:{ visualType, projections:{Role:[{queryRef}]},
                                      objects:{ title[], general[] (textbox) } } }

Usage:
  python3 extract-report-classic.py --report-json /tmp/pbir-orders/report.json \
      --out /tmp/pbir-orders/signals.json
"""
import argparse, json, re, sys

# Same visualType -> Sigma element kind table as extract-pbir.py.
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

# *Bar* = horizontal, *Column* = vertical (Sigma default). Sigma's bar-chart
# `orientation` accepts only "horizontal"; vertical = omit the field.
# PBI visualType -> Sigma `stacking` enum (none|stacked|normalized). Classic
# files encode it in the TYPE NAME; without an explicit value Sigma defaults
# multi-series bars to STACKED, corrupting clustered PBI charts (customer
# catch on the Retail sample's clustered variance chart).
def _stacking(vtype):
    v = (vtype or "")
    if v.startswith("hundredPercentStacked"):
        return "normalized"
    if v.startswith("stacked"):
        return "stacked"
    return "none"


HBAR_TYPES = {"barChart", "clusteredBarChart", "stackedBarChart",
              "hundredPercentStackedBarChart"}

# Geo/map visuals bind Series(=location dim) + Size(=measure). The bar branch of
# the builder reads Category/Axis/X (dim) and Y/Values (measure), so remap —
# but ONLY for map visuals (bead ry0n): on a scatterChart, Size is the real
# bubble-size role and Series the legend; remapping them corrupts the scatter.
ROLE_REMAP = {
    "Size": "Y",
    "Location": "Category",
}
MAP_TYPES = {"map", "filledMap", "shapeMap", "azureMap"}


# Aggregation.Function enum -> modern queryRef wrapper (Sum(Table.Col)).
_AGG_FN = {0: "Sum", 1: "Avg", 2: "Min", 3: "Max", 4: "Count"}


def _select_alias_map(sv):
    """Legacy classic layouts (PBIX vintage ~2017 and earlier, e.g. the MS
    'Retail Analysis Sample') bind projections by POSITIONAL aliases
    ('select', 'select1', ...) instead of qualified 'Table.Field' refs. The
    alias is prototypeQuery.Select[].Name, and that entry's Column/Measure/
    Aggregation expression carries the real Entity.Property (Entity via the
    From[] alias table). Map alias -> qualified ref; for modern classic files
    Name already IS the qualified ref, so the mapping is an identity."""
    pq = sv.get("prototypeQuery") or {}
    ents = {f.get("Name"): f.get("Entity") for f in pq.get("From", []) if isinstance(f, dict)}

    def qualify(expr):
        src = ((expr.get("Expression") or {}).get("SourceRef") or {}).get("Source")
        ent = ents.get(src)
        prop = expr.get("Property")
        return f"{ent}.{prop}" if ent and prop else None

    out = {}
    for sel in pq.get("Select", []):
        if not isinstance(sel, dict) or not sel.get("Name"):
            continue
        ref = None
        if "Column" in sel or "Measure" in sel or "HierarchyLevel" in sel:
            ref = qualify(sel.get("Column") or sel.get("Measure") or sel.get("HierarchyLevel") or {})
        elif "Aggregation" in sel:
            agg = sel["Aggregation"]
            inner = (agg.get("Expression") or {}).get("Column") or {}
            base = qualify(inner)
            fn = _AGG_FN.get(agg.get("Function"))
            ref = f"{fn}({base})" if base and fn else base
        if ref:
            out[sel["Name"]] = ref
    return out


def _projections(sv, vt=None):
    # bead hjke(c): classic configs record the drilled-to hierarchy level in
    # singleVisual.activeProjections — prefer it over the full level list so a
    # day-drilled line binds Day instead of collapsing to Year.
    act = sv.get("activeProjections", {}) or {}
    smap = _select_alias_map(sv)
    out = {}
    for role, items in (sv.get("projections", {}) or {}).items():
        a = act.get(role) or []
        arefs = [smap.get(it["queryRef"], it["queryRef"]) for it in a
                 if isinstance(it, dict) and it.get("queryRef")]
        refs = [smap.get(it["queryRef"], it["queryRef"]) for it in items
                if isinstance(it, dict) and it.get("queryRef")]
        if arefs and arefs != refs:
            print(f"[classic] drill: role {role} -> active projection {arefs} "
                  f"(of {len(refs)} level(s))", file=sys.stderr)
            refs = arefs
        if refs:
            key = ROLE_REMAP.get(role, role) if vt in MAP_TYPES else role
            out[key] = refs
    return out


def _title(sv):
    for it in sv.get("objects", {}).get("title", []):
        props = it.get("properties", {})
        show = props.get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        t = props.get("text", {}).get("expr", {}).get("Literal", {}).get("Value")
        if t and show != "false":
            return t.strip("'")
    return None


def _obj_flag(sv, key):
    """objects.<key>[0].properties.show.expr.Literal.Value -> True/False/None
    (bead n9u9 data labels / ry0n legend; same shape as extract-pbir.py)."""
    for it in sv.get("objects", {}).get(key, []):
        v = it.get("properties", {}).get("show", {}).get("expr", {}).get("Literal", {}).get("Value")
        if v is not None:
            return str(v).strip("'").lower() == "true"
    return None


def _sort_signal(sv):
    """bead f972: classic sort -> {queryRef, direction asc|desc} or None.

    Classic configs carry the visual's sort in prototypeQuery.OrderBy[]:
    {Direction: 1|2 (1=Ascending, 2=Descending), Expression: <field expr>}.
    The Expression is structurally IDENTICAL to one of prototypeQuery.Select[]'s
    entries (minus its Name/NativeReferenceName) — and that Select's `Name` is the
    exact queryRef the projections bind ("ABSENCE_RECORDS.Absence Count",
    "Sum(ABSENCE_RECORDS.HOURS)"), so match by expression equality."""
    pq = sv.get("prototypeQuery") or {}
    ob = pq.get("OrderBy") or []
    if not ob:
        return None
    first = ob[0]
    direction = "desc" if first.get("Direction") == 2 else "asc"
    expr = first.get("Expression")
    for sel in pq.get("Select", []):
        if not isinstance(sel, dict):
            continue
        sel_expr = {k: v for k, v in sel.items() if k not in ("Name", "NativeReferenceName")}
        if sel_expr == expr and sel.get("Name"):
            # resolve legacy 'selectN' aliases the same way projections do
            ref = _select_alias_map(sv).get(sel["Name"], sel["Name"])
            return {"queryRef": ref, "direction": direction}
    return None


def _textbox_body(sv):
    for para in sv.get("objects", {}).get("general", []):
        paras = para.get("properties", {}).get("paragraphs", [])
        for p in paras:
            for run in p.get("textRuns", []):
                v = run.get("value")
                if v:
                    return v
    return None


def extract(report):
    out_pages = []
    for s in report.get("sections", []):
        visuals = []
        for vc in s.get("visualContainers", []):
            cfg = json.loads(vc.get("config", "{}"))
            sv = cfg.get("singleVisual", {})
            vt = sv.get("visualType", "unknown")
            # bead a1cv: image visuals are static assets (StaticResources). Emit a
            # kind='image' record carrying the registered-resource name — the
            # builder turns it into a Sigma image element when --image-map
            # supplies a hosted URL for it, and skips it (with a note) otherwise.
            if vt == "image":
                # resource name lives at objects.general[].properties.imageUrl
                # .expr.ResourcePackageItem.ItemName (classic) — regex fallback
                # for any RegisteredResources path form.
                m = re.search(r'"ItemName":\s*"([^"]+)"', json.dumps(cfg)) \
                    or re.search(r"RegisteredResources/([\w.\-]+)", json.dumps(cfg))
                ipos = (cfg.get("layouts", [{}])[0] or {}).get("position", {})
                rec = {
                    "visual_id": f"p{len(out_pages)}v{len(visuals)}image",
                    "visual_type": vt, "title": None, "sigma_kind": "image",
                    "orientation": None,
                    "x": vc.get("x") or ipos.get("x", 0), "y": vc.get("y") or ipos.get("y", 0),
                    "w": vc.get("width") or ipos.get("width", 0), "h": vc.get("height") or ipos.get("height", 0),
                    "z": vc.get("z") or ipos.get("z", 0), "parent_group": None, "bindings": {},
                    "sort": None, "formats": {}, "data_labels": None, "legend": None,
                    "resource": m.group(1) if m else None,
                }
                visuals.append((cfg.get("name"), rec))
                continue
            # position: prefer vc top-level x/y/w/h, fall back to config layouts
            x = vc.get("x"); y = vc.get("y"); w = vc.get("width"); h = vc.get("height")
            if x is None:
                pos = (cfg.get("layouts", [{}])[0] or {}).get("position", {})
                x, y, w, h = pos.get("x", 0), pos.get("y", 0), pos.get("width", 0), pos.get("height", 0)
            rec = {
                # bead npo0: classic config `name`s are NOT unique in pre-2018
                # files (truncated visualContainer strings collide) and the
                # builder derives element ids from visual_id — synthesize a
                # deterministic page/index id instead of trusting cfg name.
                "visual_id": f"p{len(out_pages)}v{len(visuals)}{vt[:8]}",
                "visual_type": vt,
                "title": _title(sv),
                "sigma_kind": VISUAL_KIND.get(vt, "bar"),
                "orientation": "horizontal" if vt in HBAR_TYPES else None,
                "x": x or 0, "y": y or 0, "w": w or 0, "h": h or 0,
                "z": vc.get("z", 0),
                "parent_group": None,
                "bindings": _projections(sv, vt),
                # bead f972: visual sort ({queryRef, direction asc|desc}) or None
                "sort": _sort_signal(sv),
                "stacking": _stacking(vt) if VISUAL_KIND.get(vt) in ("bar", "area") else None,
                "formats": {},
                # bead n9u9: PBI data-label toggle (objects.labels show) — true/false/None
                "data_labels": _obj_flag(sv, "labels"),
                # bead ry0n: PBI legend toggle (objects.legend show) — true/false/None
                "legend": _obj_flag(sv, "legend"),
            }
            if rec["sigma_kind"] == "text":
                rec["text"] = _textbox_body(sv)
            visuals.append((cfg.get("name"), rec))
        visuals.sort(key=lambda nr: (nr[1]["y"], nr[1]["x"]))
        # Visual-interaction overrides ("edit interactions"): the classic
        # section config (JSON string) carries visualInteractions[{source,
        # target, type}] ONLY when an author edited them; source/target are
        # config names — remapped here onto the synthesized visual_ids the
        # builder keys on (control-targeting wave, workstream B). Numeric
        # types: 3 = none/no-filter (the exemption the builder honors);
        # 1/2 = filter/highlight (both still filter-like — kept verbatim).
        name_to_id = {n: r["visual_id"] for n, r in visuals if n}
        interactions = []
        try:
            scfg = json.loads(s.get("config") or "{}")
        except (TypeError, ValueError):
            scfg = {}
        for ia in (scfg.get("visualInteractions") or []):
            src, tgt = name_to_id.get(ia.get("source")), name_to_id.get(ia.get("target"))
            if not (src and tgt):
                continue
            t = ia.get("type")
            interactions.append({"source": src, "target": tgt,
                                 "type": "none" if t in (3, "3", "none", "noFilter") else str(t).lower()})
        out_pages.append({
            "page_id": s.get("name"),
            "page_title": s.get("displayName", s.get("name")),
            "page_w": s.get("width", 1280),
            "page_h": s.get("height", 720),
            "visuals": [r for _n, r in visuals],
            "interactions": interactions,
        })
    return {"source": "report.json-classic", "pages": out_pages}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report-json", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    report = json.load(open(a.report_json))
    signals = extract(report)
    json.dump(signals, open(a.out, "w"), indent=2)
    nvis = sum(len(p["visuals"]) for p in signals["pages"])
    print(f"[classic] {len(signals['pages'])} page(s), {nvis} visual(s) -> {a.out}", file=sys.stderr)
    for p in signals["pages"]:
        for v in p["visuals"]:
            print(f"  {v['visual_type']:>14} -> {v['sigma_kind']:<6} {v['bindings']}", file=sys.stderr)


if __name__ == "__main__":
    main()
