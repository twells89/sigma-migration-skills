#!/usr/bin/env python3
r"""qlik-prj-discover.py — QlikView (.qvw) "-prj" project folder -> Qlik-Sense-shaped
discovery artifacts, so the SAME convert -> data-model -> workbook pipeline
(migrate-qlik.rb --from-discovery) runs unchanged.

QlikView .qvw binaries have no parser and QlikView has no Cloud/REST API. The
developer-opt-in <name>-prj/ project folder is the migration surface:
  QlikViewProject.xml  -> the manifest + <SHEETS> with per-object <Rect> geometry
                          (sheet membership + absolute-canvas layout, z-ordered)
  LoadScript.txt       -> the data model (tables/fields, incl. AS renames)
  CH<id>.xml           -> chart objects: <GraphMode> (type), <Dimensions>
                          (ChartDimensionDataDef/PseudoDef), <Expressions>
                          (ArrayOfMainExpressionData/.../Definition + Label)
  SH<id>.xml           -> sheet <Name>

Emits, into --out, the exact artifact set migrate-qlik.rb --from-discovery consumes:
  script.qvs, converter-input.json, charts.json, measures.json, layout.json

QlikView delivers what a -prj folder actually carries: the data model + the charts'
types/dims/measures + the sheet layout. There is no live engine, so there is no
Qlik-side value snapshot (parity is warehouse-only downstream). Relationships are
inferred from shared field names (a -prj folder carries no row counts).

Usage:  python3 qlik-prj-discover.py --prj <path/to/Name-prj> --out <workdir>
"""
import argparse, glob, json, os, re, sys
import xml.etree.ElementTree as ET

# QlikView <GraphMode> -> Sigma vizType. Sigma's supported set (viz-kind catalog,
# consumed by build-sigma-workbook.py): barchart linechart combochart piechart
# scatterplot table pivot-table kpi map. QlikView has 13 chart types; ALL are mapped
# here. The 5 with NO native Sigma equivalent (radar/grid/gauge/block/funnel/mekko)
# map to the closest kind and are flagged `approx` -> a LOUD per-chart warning, so a
# fidelity gap is never silent. Keys are NORMALIZED (GRAPH_MODE_ prefix stripped,
# non-letters removed, uppercased) so constant-name variants still resolve.
#   value = (sigma vizType, approximated?)
GRAPHMODE_VIZ = {
    "BAR": ("barchart", False),
    "LINE": ("linechart", False),
    "COMBO": ("combochart", False),
    "PIE": ("piechart", False),
    "SCATTER": ("scatterplot", False),
    "STRAIGHTTABLE": ("table", False),
    "PIVOTTABLE": ("pivot-table", False),
    "GAUGE": ("kpi", True),        # single-value gauge -> KPI
    "RADAR": ("linechart", True),  # polar line/area -> line
    "GRID": ("scatterplot", True), # 2-dim grid w/ size/colour -> scatter
    "BLOCK": ("barchart", True),   # block/treemap -> bar (Sigma set has no treemap)
    "FUNNEL": ("barchart", True),  # ranked stages -> bar
    "MEKKO": ("barchart", True),   # marimekko (variable-width stacked) -> bar
}
# Substring fallbacks for constant-name variants (checked most-specific first).
_VIZ_KEYWORDS = [
    ("STRAIGHT", ("table", False)), ("PIVOT", ("pivot-table", False)),
    ("COMBO", ("combochart", False)), ("BAR", ("barchart", False)),
    ("LINE", ("linechart", False)), ("PIE", ("piechart", False)),
    ("SCATTER", ("scatterplot", False)), ("XY", ("scatterplot", False)),
    ("RADAR", ("linechart", True)), ("GRID", ("scatterplot", True)),
    ("GAUGE", ("kpi", True)), ("SPEED", ("kpi", True)), ("METER", ("kpi", True)),
    ("BLOCK", ("barchart", True)), ("FUNNEL", ("barchart", True)),
    ("MEKKO", ("barchart", True)), ("TABLE", ("table", False)),
]
GRID_COLS = 24


def _norm_mode(mode):
    """GRAPH_MODE_STRAIGHT_TABLE -> STRAIGHTTABLE (prefix stripped, letters only)."""
    up = (mode or "").upper()
    up = up[len("GRAPH_MODE_"):] if up.startswith("GRAPH_MODE_") else up
    return "".join(ch for ch in up if ch.isalpha())

warnings = []


def _text(el):
    """Inner text of an element, unwrapping QlikView's <v> value wrapper."""
    if el is None:
        return ""
    v = el.find("v")
    if v is not None and v.text is not None:
        return v.text.strip()
    return (el.text or "").strip()


# ── LOAD script -> tables + post-rename fields (mirrors the vendored converter) ──
def parse_load_script(script):
    s = re.sub(r"/\*.*?\*/", " ", script, flags=re.S)
    s = re.sub(r"(?m)^[ \t]*//.*$", " ", s)
    tables = []
    block = re.compile(
        r"(?:^|\n)[ \t]*(?:([A-Za-z_]\w*)\s*:\s*)?(?:[A-Za-z]+[ \t]+)?"
        r"\b(?:LOAD|SQL\s+SELECT)\b(.*?)(?:\b(?:FROM|RESIDENT|INLINE|AUTOGENERATE)\b(.*?))?;",
        re.S | re.I)
    for m in block.finditer(s):
        label, body, tail = m.group(1), m.group(2) or "", m.group(3) or ""
        fields = []
        for raw in _split_top(body):
            f = raw.strip()
            if not f or f == "*":
                continue
            am = re.search(r"\s+AS\s+(.+)$", f, re.I | re.S)
            if am:
                f = am.group(1).strip()
            f = re.sub(r'^[\["\']+|[\]"\']+$', "", f).strip()
            if not re.match(r"^[A-Za-z_][\w ]*$", f):
                continue
            fields.append(f)
        if not fields:
            continue
        name = label
        if not name:
            fm = re.search(r"\[[^\]]*?([A-Za-z0-9_]+)\.(?:qvd|csv|txt|xlsx?)\b", tail, re.I) \
                or re.search(r"\b([A-Za-z0-9_]+)\s*$", tail)
            name = fm.group(1) if fm else "Table%d" % (len(tables) + 1)
        tables.append({"name": name, "fields": fields})
    return tables


def _split_top(s, sep=","):
    out, depth, start, q = [], 0, 0, ""
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = ""
            continue
        if c in "\"'":
            q = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == sep and depth == 0:
            out.append(s[start:i]); start = i + 1
    out.append(s[start:])
    return [x.strip() for x in out]


# ── QlikViewProject.xml -> sheets + per-object geometry ──────────────────────
def parse_project(root):
    sheets = []
    for i, ps in enumerate(root.iter("PrjSheetProperties")):
        sid = (ps.findtext("SheetId") or "SH%02d" % (i + 1)).split("\\")[-1]
        objs = []
        for fp in ps.iter("PrjFrameParentDef"):
            oid = (fp.findtext("ObjectId") or "").split("\\")[-1]
            rect = fp.find("Rect")
            if not oid or rect is None:
                continue
            objs.append({
                "objectId": oid,
                "left": int(rect.findtext("Left") or 0),
                "top": int(rect.findtext("Top") or 0),
                "width": int(rect.findtext("Width") or 1),
                "height": int(rect.findtext("Height") or 1),
                "zed": int(fp.findtext("ZedLevel") or 0),
            })
        sheets.append({"sheetId": sid, "objects": objs, "rank": i})
    return sheets


# ── CH<id>.xml -> chart type + dimensions + measures ─────────────────────────
def parse_chart(root):
    mode = (root.findtext(".//GraphMode") or "").strip()   # nested in real files
    frame_name = root.find("./GraphLayout/Frame/Name")
    title = _text(frame_name)

    dims = []
    for dd in root.iter("ChartDimensionDataDef"):
        pd = dd.find("PseudoDef")
        name = _text(pd.find("Name")) if pd is not None else ""
        dtype = (pd.findtext("Type") if pd is not None else "") or "IS_FIELD"
        label = _text(dd.find("Title")) or name
        nullsup = (dd.findtext("NullSuppression") or "false").lower() == "true"
        if name:
            dims.append({"name": name, "type": dtype, "label": label, "nullSup": nullsup})

    measures = []
    for md in root.iter("MainExpressionData"):
        ed = md.find("./Data/ExpressionData")
        ev = md.find("./Data/ExpressionVisual")
        definition = _text(ed.find("Definition")) if ed is not None else ""
        if not definition:
            continue
        label = _text(ev.find("Label")) if ev is not None else ""
        as_bar = (ev.findtext("ShowAsBar") if ev is not None else "") == "true"
        as_line = (ev.findtext("ShowAsLine") if ev is not None else "") == "true"
        measures.append({
            "def": re.sub(r"^=", "", definition).strip(),   # drop leading '='
            "label": label or ("Expr %d" % (len(measures) + 1)),
            "asBar": as_bar, "asLine": as_line,
        })
    return {"mode": mode, "title": title, "dims": dims, "measures": measures}


def viz_for(chart):
    mode, meas = chart["mode"], chart["measures"]
    title = chart["title"] or "?"
    norm = _norm_mode(mode)
    viz, approx = GRAPHMODE_VIZ.get(norm, (None, None))
    if viz is None:                                  # variant name -> substring match
        for kw, mapped in _VIZ_KEYWORDS:
            if kw in norm:
                viz, approx = mapped
                break
    if viz is None:                                  # truly unknown -> loud fallback
        warnings.append("chart '%s': unmapped GraphMode %r -> barchart (review)" % (title, mode))
        return "barchart"
    # Combo override: a GENUINE bar-only/line-only split promotes bar/line -> combo.
    # (Real QlikView charts set ShowAsBar AND ShowAsLine true by default, so a plain
    #  "both true" is noise, not a combo — hence the "-only" test.)
    if viz in ("barchart", "linechart") \
       and any(m["asBar"] and not m["asLine"] for m in meas) \
       and any(m["asLine"] and not m["asBar"] for m in meas):
        return "combochart"
    if approx:
        warnings.append("chart '%s': QlikView %s has no exact Sigma equivalent -> approximated as %s (review)"
                        % (title, mode or "?", viz))
    return viz


# ── absolute-canvas Rects -> 24-col grid cells (aspect-preserving) ───────────
def quantize(objects):
    if not objects:
        return 0, []
    min_l = min(o["left"] for o in objects)
    min_t = min(o["top"] for o in objects)
    max_r = max(o["left"] + o["width"] for o in objects)
    span = max(max_r - min_l, 1)
    unit = span / GRID_COLS                      # px per grid column (square cells)
    cells, max_row = [], 0
    for o in sorted(objects, key=lambda x: x["zed"]):
        col = max(0, min(GRID_COLS - 1, round((o["left"] - min_l) / unit)))
        colspan = max(1, min(GRID_COLS - col, round(o["width"] / unit)))
        row = max(0, round((o["top"] - min_t) / unit))
        rowspan = max(1, round(o["height"] / unit))
        cells.append({"objectId": o["objectId"], "col": col, "row": row,
                      "colspan": colspan, "rowspan": rowspan})
        max_row = max(max_row, row + rowspan)
    return max_row, cells


def read_xml(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return ET.fromstring(f.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prj", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    prj, out = a.prj, a.out
    if not os.path.isdir(prj):
        sys.exit("FATAL: --prj dir not found: %s" % prj)
    os.makedirs(out, exist_ok=True)

    def find(pat):
        return sorted(glob.glob(os.path.join(prj, pat)) + glob.glob(os.path.join(prj, "**", pat), recursive=True))

    # 1) LOAD script -> tables + script.qvs
    scripts = find("LoadScript.txt") or find("*.qvs")
    if not scripts:
        sys.exit('FATAL: no LoadScript.txt/.qvs under %s (enable "Create project folder" in QlikView Desktop)' % prj)
    script_text = open(scripts[0], "r", encoding="utf-8-sig").read()
    with open(os.path.join(out, "script.qvs"), "w") as f:
        f.write(script_text)
    tables = parse_load_script(script_text)

    # 2) project manifest -> sheets + object geometry (fall back to a single synthetic sheet)
    projs = find("QlikViewProject.xml")
    sheets = parse_project(read_xml(projs[0])) if projs else []

    # 3) charts: parse every CH*.xml, key by object id (file stem, minus any _<num> suffix)
    chart_by_id = {}
    for cf in find("CH*.xml"):
        stem = os.path.splitext(os.path.basename(cf))[0]       # CH01 or CH02_888518682
        base = stem.split("_")[0]                              # CH01 / CH02
        try:
            chart_by_id[base] = (stem, parse_chart(read_xml(cf)))
        except ET.ParseError as e:
            warnings.append("chart %s: XML parse error (%s) — skipped" % (stem, e))

    # sheet titles from SH*.xml
    sheet_title = {}
    for sf in find("SH*.xml"):
        base = os.path.splitext(os.path.basename(sf))[0].split("_")[0]
        try:
            sheet_title[base] = root_name(read_xml(sf))
        except ET.ParseError:
            pass

    # If no manifest, synthesize one sheet holding all charts in a simple grid.
    if not sheets:
        objs, x = [], 0
        for base in chart_by_id:
            objs.append({"objectId": base, "left": (x % 2) * 2000, "top": (x // 2) * 1200,
                         "width": 1950, "height": 1180, "zed": x})
            x += 1
        sheets = [{"sheetId": "SH01", "objects": objs, "rank": 0}]

    charts, layout, seen_meas = [], [], {}
    for sh in sheets:
        _, cells = quantize(sh["objects"])
        laid = []
        for cell in cells:
            oid = cell["objectId"]
            if oid not in chart_by_id:
                warnings.append("sheet %s: object %s is not a chart (CH*) — skipped in layout"
                                % (sh["sheetId"], oid))
                continue
            stem, ch = chart_by_id[oid]
            viz = viz_for(ch)
            charts.append({
                "id": oid, "vizType": viz, "title": ch["title"] or oid,
                "sheet": sh["sheetId"],
                "dimensions": [[d["name"]] for d in ch["dims"]],
                "dimLabels": [d["label"] for d in ch["dims"]],
                "dimNullSuppression": [d["nullSup"] for d in ch["dims"]],
                "measures": [m["def"] for m in ch["measures"]],
                "measureLabels": [m["label"] for m in ch["measures"]],
                "measureFmts": [None for _ in ch["measures"]],
                "sort": {"interColumnSortOrder": [],
                         "dimensions": [[] for _ in ch["dims"]],
                         "measures": [{"qExpression": {}} for _ in ch["measures"]]},
            })
            laid.append({"objectId": oid, "type": viz, "col": cell["col"], "row": cell["row"],
                         "colspan": cell["colspan"], "rowspan": cell["rowspan"]})
            for m in ch["measures"]:
                seen_meas.setdefault(m["def"], m["label"])
        rows = max([c["row"] + c["rowspan"] for c in laid], default=1)
        layout.append({"sheetId": sh["sheetId"],
                       "title": sheet_title.get(sh["sheetId"], sh["sheetId"]),
                       "rank": sh["rank"], "columns": GRID_COLS, "rows": rows, "cells": laid})

    master_measures = [{"title": lbl, "qDef": d} for d, lbl in seen_meas.items()]
    app_name = re.sub(r"-prj$", "", os.path.basename(os.path.normpath(prj))) or "QlikView App"

    conv_input = {"appName": app_name, "tables": [
        {"name": t["name"], "noOfRows": 0, "fields": [{"name": n} for n in t["fields"]]} for t in tables],
        "masterMeasures": master_measures, "masterDimensions": []}
    measures = [{"title": lbl, "expr": d} for d, lbl in seen_meas.items()]

    _write(out, "converter-input.json", conv_input)
    _write(out, "charts.json", charts)
    _write(out, "measures.json", measures)
    _write(out, "layout.json", layout)

    warnings.append("QlikView -prj: relationships inferred from shared field names only "
                    "(a -prj folder carries no row counts) — review join directions.")
    print("QlikView -prj discovery: %d table(s), %d chart(s) on %d sheet(s), %d measure(s)"
          % (len(tables), len(charts), len(sheets), len(master_measures)))
    for w in warnings:
        print("  ! " + w)


def root_name(root):
    n = root.find("Name")
    return (n.text or "").strip() if n is not None else ""


def _write(out, name, obj):
    with open(os.path.join(out, name), "w") as f:
        json.dump(obj, f, indent=2)


if __name__ == "__main__":
    main()
