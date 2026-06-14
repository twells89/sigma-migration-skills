#!/usr/bin/env python3
"""Apply layout to migrated Sigma workbooks — from the Liveboard's OWN tile
geometry when available, else a clean auto grid.

Sigma stacks elements vertically unless a top-level spec.layout is set, and the
layout must be the LAST write (a bare spec PUT wipes it).

Geometry mapping (ThoughtSpot layout.tiles → Sigma grid):
  - ThoughtSpot Liveboards use a 12-column grid; Sigma uses 24 → scale x/width ×2.
  - Rows: ROW_SCALE (min 2). 1:1 row mapping makes chart bands too short and
    Sigma SUPPRESSES axis category labels / KPI titles on short bands — same
    fix as looker-to-sigma's ROW_SCALE=2 (beads-sigma-tkkv). Override with
    TS_ROW_SCALE (values < 2 are clamped to 2).

Usage: python3 apply_layouts.py [--workdir DIR]   # all workbooks in <workdir>/migrate_out.json
       python3 apply_layouts.py <wbId> ...        # specific workbooks (auto grid)
Env: SIGMA_BASE_URL, SIGMA_API_TOKEN, TS_WORKDIR (default for --workdir), TS_ROW_SCALE
"""
import argparse, json, os, ssl, sys, urllib.request, urllib.error
_SSL = ssl._create_unverified_context()

TS_GRID_COLS = 12                                   # ThoughtSpot Liveboard grid
COL_SCALE = 24 // TS_GRID_COLS                      # → Sigma's 24-col grid
ROW_SCALE = max(2, int(os.environ.get("TS_ROW_SCALE", "2") or 2))

def req(method, path, body=None):
    base = os.environ["SIGMA_BASE_URL"]; tok = os.environ["SIGMA_API_TOKEN"]
    r = urllib.request.Request(base + path, data=(body.encode() if body else None), method=method,
        headers={"Authorization": "Bearer " + tok, "Accept": "application/json",
                 **({"Content-Type": "application/json"} if body else {})})
    try:
        return urllib.request.urlopen(r, context=_SSL).read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code}: {e.read().decode()[:300]}")

# ---- container-banded layout (layout-playbook.md, verified 2026-06-10) -----
# Spec side: a `kind: container` placeholder element per band + a header text
# element. Layout side: <GridContainer> (NOT <LayoutElement type="grid">, which
# silently drops children) wrapping <LayoutElement>s with CONTAINER-RELATIVE
# coordinates (rows restart at 1).
HEADER_STYLE = {"backgroundColor": "#0F172A", "borderRadius": "round"}
HEADER_ROWS = 3

def _le(eid, c0, c1, r0, r1):
    return f'  <LayoutElement elementId="{eid}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>'

def _gc(cid, r0, r1, inner):
    return (f'<GridContainer elementId="{cid}" type="grid" gridColumn="1 / 25" '
            f'gridRow="{r0} / {r1}" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto">\n{inner}\n</GridContainer>')

GRID_COLS = 24
MIN_BAND_FILL = 0.60     # must mirror lib/layout_lint.rb MIN_BAND_FILL


def _band_fill(items):
    covered = [False] * GRID_COLS
    for it in items:
        for c in range(it[1], it[2]):
            if 1 <= c <= GRID_COLS:
                covered[c - 1] = True
    return sum(covered) / GRID_COLS


def _reflow_bands(bands):
    """Python port of lib/layout.rb reflow_bands (tableau/pbi/quicksight
    plugins, phase-e layout quality): when any band's items cover <60% of the
    grid columns — e.g. a half-width trailing Liveboard tile — redistribute
    the page's items across the same number of bands evenly and tile each band
    edge-to-edge at its original height. Pages whose bands all fill >=60% keep
    the source-tile geometry exactly. Keeps the layout-lint gate
    (lib/layout_lint.rb, 'band under-filled') GREEN by construction."""
    if not any(_band_fill(b["items"]) < MIN_BAND_FILL for b in bands):
        return bands
    heights = [b["r1"] - b["r0"] for b in bands]
    items = [it for b in bands for it in sorted(b["items"], key=lambda i: (i[3], i[1]))]
    k = len(items)
    nb = min(len(bands), k)
    base, rem = divmod(k, nb)
    sizes = [base + (1 if bi >= nb - rem else 0) for bi in range(nb)]
    out, idx, cursor = [], 0, 1
    fallback_h = max([h for h in heights if h] or [8])
    for bi, n in enumerate(sizes):
        band_items = items[idx:idx + n]
        idx += n
        h = max(heights[bi] if bi < len(heights) and heights[bi] else fallback_h, 4)
        new_items = [[it[0],
                      1 + int(GRID_COLS * j / n + 0.5),
                      1 + int(GRID_COLS * (j + 1) / n + 0.5),
                      cursor, cursor + h]
                     for j, it in enumerate(band_items)]
        out.append({"r0": cursor, "r1": cursor + h, "items": new_items})
        cursor += h
    return out


def _collide(a, b):
    """Two items collide when their column AND row ranges both overlap."""
    return a[1] < b[2] and b[1] < a[2] and a[3] < b[4] and b[3] < a[4]


def _decollide_bands(bands):
    """Sigma's grid has NO z-order: two items sharing a cell render stacked on
    each other. When a band has any pair overlapping in BOTH axes, tile its
    items edge-to-edge across the full grid width at the band's row range.
    Collision-free bands are kept as-is (clean tile geometry preserved). This is
    the universal safety net that runs after reflow on every banded_page."""
    out = []
    for b in bands:
        its = b["items"]
        if not any(_collide(its[i], its[j])
                   for i in range(len(its)) for j in range(i + 1, len(its))):
            out.append(b); continue
        r0 = min(i[3] for i in its); r1 = max(i[4] for i in its); n = len(its)
        tiled = [[it[0], 1 + int(GRID_COLS * j / n + 0.5),
                  1 + int(GRID_COLS * (j + 1) / n + 0.5), r0, r1]
                 for j, it in enumerate(sorted(its, key=lambda i: (i[1], i[3])))]
        out.append({"r0": r0, "r1": r1, "items": tiled})
    return out


def banded_page(page_id, items, title):
    """items: [eid, c0, c1, r0, r1] page-absolute. Header band + one container
    per row band (children relative; relative TS proportions preserved inside).
    Returns (page_xml, extra_spec_elements)."""
    extra, children = [], []
    extra.append({"id": "band-hdr", "kind": "container", "style": dict(HEADER_STYLE)})
    extra.append({"id": "band-hdrtext", "kind": "text",
                  "body": f'# <span style="color: #FFFFFF">{title}</span>'})
    children.append(_gc("band-hdr", 1, 1 + HEADER_ROWS, _le("band-hdrtext", 1, 25, 1, 1 + HEADER_ROWS)))
    bands = []
    for it in sorted(items, key=lambda i: (i[3], i[1])):
        if bands and it[3] < bands[-1]["r1"]:
            bands[-1]["items"].append(it)
            bands[-1]["r1"] = max(bands[-1]["r1"], it[4])
        else:
            bands.append({"r0": it[3], "r1": it[4], "items": [it]})
    bands = _reflow_bands(bands)
    bands = _decollide_bands(bands)
    offset = HEADER_ROWS + (1 - min(b["r0"] for b in bands)) if bands else HEADER_ROWS
    for n, b in enumerate(bands, 1):
        cid = f"band-{n}"
        extra.append({"id": cid, "kind": "container"})
        inner = "\n".join(_le(i[0], i[1], i[2], i[3] - b["r0"] + 1, i[4] - b["r0"] + 1)
                          for i in b["items"])
        children.append(_gc(cid, b["r0"] + offset, b["r1"] + offset, inner))
    body = "\n".join(children)
    return (f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto" id="{page_id}">\n{body}\n</Page>', extra)

def tiles_items(tiles, kinds=None):
    """ThoughtSpot tile geometry → Sigma grid items (TS 12-col units → 24).
    KPI tiles are padded to >= 5 grid rows (Sigma hides the KPI title below
    that — layout-playbook.md)."""
    items = []
    for t in tiles:
        c0 = t["x"] * COL_SCALE + 1
        c1 = min(t["x"] + t["width"], TS_GRID_COLS) * COL_SCALE + 1
        r0 = t["y"] * ROW_SCALE + 1
        r1 = (t["y"] + t["height"]) * ROW_SCALE + 1
        if (kinds or {}).get(t["element_id"]) == "kpi-chart" and r1 - r0 < 5:
            r1 = r0 + 5
        items.append([t["element_id"], c0, c1, r0, r1])
    return items

def auto_items(elems):
    """Auto grid fallback (no TML geometry): KPI strip (5+ rows, titles render),
    then charts 2-wide, 11 rows."""
    kpis = [e for e in elems if e["kind"] == "kpi-chart"]
    charts = [e for e in elems if e["kind"] not in ("kpi-chart",)]
    items, row = [], 1
    if kpis:
        w = 24 // len(kpis)
        for i, e in enumerate(kpis):
            c0 = 1 + i * w; c1 = (c0 + w) if i < len(kpis) - 1 else 25
            items.append([e["id"], c0, c1, 1, 6])
        row = 6
    for i in range(0, len(charts), 2):
        pair = charts[i:i + 2]
        for j, e in enumerate(pair):
            c0 = 1 if j == 0 else 13
            c1 = 13 if (j == 0 and len(pair) > 1) else 25
            items.append([e["id"], c0, c1, row, row + 11])
        row += 11
    return items

def build_layout(spec, tiles=None):
    """Returns (layout_xml, main_page, extra_spec_elements)."""
    pages = spec["pages"]
    data = next((p for p in pages if p.get("name") == "Data"), None)
    main = next((p for p in pages if p.get("name") != "Data"), None)
    lines = ['<?xml version="1.0" encoding="utf-8"?>']
    if data and data.get("elements"):
        mid = data["elements"][0]["id"]
        lines.append(f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{data["id"]}">')
        lines.append(f'  <LayoutElement elementId="{mid}" gridColumn="1 / 25" gridRow="1 / 21"/>')
        lines.append('</Page>')
    if tiles:
        items = tiles_items(tiles, kinds={e["id"]: e.get("kind") for e in main["elements"]})
    else:
        elems = [{"id": e["id"], "kind": e["kind"]} for e in main["elements"]
                 if e.get("kind") != "container" and not str(e.get("id", "")).startswith("band-")]
        items = auto_items(elems)
    title = main.get("name") or spec.get("name") or "Dashboard"
    page, extra = banded_page(main["id"], items, title)
    lines.append(page)
    return "\n".join(lines) + "\n", main, extra

def apply(wb, tiles=None):
    spec = json.loads(req("GET", f"/v2/workbooks/{wb}/spec"))
    xml, main, extra = build_layout(spec, tiles=tiles)
    # idempotent: drop previously-injected band elements, then add this run's
    main["elements"] = [e for e in main["elements"]
                        if not (str(e.get("id", "")).startswith("band-")
                                and e.get("kind") in ("container", "text"))] + extra
    for p in spec["pages"]:
        p.pop("layout", None)
    spec["layout"] = xml
    for k in ("workbookId", "url", "ownerId", "createdBy", "updatedBy", "createdAt",
              "updatedAt", "latestDocumentVersion"):
        spec.pop(k, None)
    resp = req("PUT", f"/v2/workbooks/{wb}/spec", json.dumps(spec))
    return "workbookId" in resp

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", default=None, help="dir holding migrate_out.json (default $TS_WORKDIR or ./ts-migration)")
    ap.add_argument("workbooks", nargs="*", help="specific workbook ids (auto grid; skips the manifest)")
    a = ap.parse_args()
    if a.workbooks:
        jobs = [(wb, None) for wb in a.workbooks]
    else:
        wd = os.path.abspath(os.path.expanduser(a.workdir or os.environ.get("TS_WORKDIR")
                             or os.path.join(os.getcwd(), "ts-migration")))
        manifest = os.path.join(wd, "migrate_out.json")
        m = json.load(open(manifest))
        results = m.get("results", m)          # new manifest nests under "results"
        jobs = [(r["workbook"], r.get("tiles")) for r in results.values() if r.get("workbook")]
    ok = 0
    for wb, tiles in jobs:
        try:
            apply(wb, tiles=tiles); ok += 1
            print(f"✓ laid out {wb} ({'TML tiles' if tiles else 'auto grid'})")
        except Exception as e:
            print(f"✗ {wb}: {e}")
    print(f"\n{ok}/{len(jobs)} workbooks laid out")

if __name__ == "__main__":
    main()
