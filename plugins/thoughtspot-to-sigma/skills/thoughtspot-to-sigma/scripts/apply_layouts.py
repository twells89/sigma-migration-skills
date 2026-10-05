#!/usr/bin/env python3
"""Apply layout to migrated Sigma workbooks — from the Liveboard's OWN tile
geometry when available, else a clean auto grid.

The released workbook API requires flat document.elements and explicit
document.layout placement. New workbooks assemble layout before POST; edits GET
and PUT the complete document because a partial PUT erases omitted fields.

Geometry mapping (ThoughtSpot layout.tiles → Sigma grid):
  - ThoughtSpot Liveboards use a 12-column grid; Sigma uses 24 → scale x/width ×2.
  - Rows: ROW_SCALE (min 2). 1:1 row mapping makes chart bands too short and
    Sigma SUPPRESSES axis category labels / KPI titles on short bands — same
    fix as looker-to-sigma's ROW_SCALE=2 (beads-sigma-tkkv). Override with
    TS_ROW_SCALE (values < 2 are clamped to 2).

Usage: python3 apply_layouts.py [--workdir DIR]   # all workbooks in <workdir>/migrate_out.json
       python3 apply_layouts.py <wbId> ...        # specific workbooks (auto grid)
Env: SIGMA_BASE_URL plus caller/browser/client auth; TS_WORKDIR (default for
--workdir), TS_ROW_SCALE
"""
import argparse, json, os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import code_rep  # workbook code-rep document-wrapper adapter (nested GET/PUT shape)
import sigma_rest

TS_GRID_COLS = 12                                   # ThoughtSpot Liveboard grid
COL_SCALE = 24 // TS_GRID_COLS                      # → Sigma's 24-col grid
ROW_SCALE = max(2, int(os.environ.get("TS_ROW_SCALE", "2") or 2))

def req(method, path, body=None):
    try:
        raw = sigma_rest.request(
            method.lower(),
            path,
            body=body,
            accept="application/json",
            binary=True,
        )
        return raw.decode()
    except (sigma_rest.SigmaError, SystemExit) as exc:
        raise RuntimeError(f"{method} {path}: {exc}") from exc

# ---- container-banded layout (layout-playbook.md, verified 2026-06-10) -----
# Spec side: a `kind: container` placeholder element per band + a header text
# element. Layout side: canonical live <Container> tags wrapping <Element> tags
# with CONTAINER-RELATIVE coordinates (rows restart at 1).
HEADER_STYLE = {"backgroundColor": "#0F172A", "borderRadius": "round"}
HEADER_ROWS = 3

def _le(eid, c0, c1, r0, r1):
    return f'  <Element elementId="{eid}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>'

def _gc(cid, r0, r1, inner):
    return (f'<Container elementId="{cid}" type="grid" gridColumn="1 / 25" '
            f'gridRow="{r0} / {r1}" gridTemplateColumns="repeat(24, 1fr)" '
            f'gridTemplateRows="auto">\n{inner}\n</Container>')

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
    header_id = f"{page_id}-band-hdr"
    header_text_id = f"{page_id}-band-hdrtext"
    extra.append({"id": header_id, "kind": "container", "style": dict(HEADER_STYLE)})
    extra.append({"id": header_text_id, "kind": "text",
                  "body": f'# <span style="color: #FFFFFF">{title}</span>'})
    children.append(_gc(header_id, 1, 1 + HEADER_ROWS,
                        _le(header_text_id, 1, 25, 1, 1 + HEADER_ROWS)))
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
        cid = f"{page_id}-band-{n}"
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

def controls_band(control_ids, row=1):
    """Lay out interactive controls (gap C) edge-to-edge in a single full-width
    band — ThoughtSpot Liveboard filters apply globally, so they sit above the
    tiles (Sigma's grid has no z-order; floating them over charts would stack).
    Returns (items, next_row). Each control is ~3 rows tall."""
    items, n = [], len(control_ids)
    if not n:
        return items, row
    for i, cid in enumerate(control_ids):
        c0 = 1 + (24 * i // n); c1 = 1 + (24 * (i + 1) // n)
        items.append([cid, c0, c1, row, row + 3])
    return items, row + 3

def _layout_element_ids(layout):
    """Return element references in layout order, including container owners."""
    return re.findall(r'\belementId="([^"]+)"', str(layout or ""))


def _page_element_ids(layout):
    """Return {page_id: [element_id, ...]}; layout, never pages[], owns placement."""
    return code_rep.workbook_page_element_ids({"layout": layout})


def _is_generated_band(el):
    eid = str(el.get("id", ""))
    return el.get("kind") in ("container", "text") and bool(
        re.search(r"-band-(?:hdr|hdrtext|\d+)$", eid)
    )


def _prefix_items(ids, row):
    """Lay full-width chrome (for example auto navigation) in short rows."""
    out = []
    for eid in ids or []:
        out.append([eid, 1, 25, row, row + 3])
        row += 3
    return out, row


def build_layout(spec, tiles=None, controls=None, page_specs=None, data_element_ids=None):
    """Build authoritative layout for a flat workbook document.

    ``pages`` are metadata only and ``elements`` is workbook-global. ``page_specs``
    carries the migration-time ownership that old ``pages[].elements`` used to
    encode: [{page_id, element_ids, tiles?, controls?, prefix_ids?}].
    Returns (layout_xml, extra_spec_elements).
    """
    pages = spec["pages"]
    elements = [e for e in spec.get("elements", []) if isinstance(e, dict)]
    by_id = {e.get("id"): e for e in elements if e.get("id")}
    data = next((p for p in pages if p.get("name") == "Data"), None)
    content_pages = [p for p in pages if p is not data]
    existing = _page_element_ids(spec.get("layout"))

    if data_element_ids is None:
        data_element_ids = [
            eid for eid in existing.get((data or {}).get("id"), []) if eid in by_id
        ]
        if not data_element_ids:
            data_element_ids = [
                e["id"] for e in elements
                if e.get("id") == "m-ofv" or e.get("visibleAsSource") is False
            ]
    data_set = set(data_element_ids or [])

    if page_specs is None:
        page_specs = []
        for i, page in enumerate(content_pages):
            ids = [eid for eid in existing.get(page.get("id"), []) if eid in by_id]
            if not ids and i == 0:
                ids = [
                    e["id"] for e in elements
                    if e.get("id") not in data_set and not _is_generated_band(e)
                    and e.get("kind") not in ("container", "control")
                ]
            page_specs.append({
                "page_id": page["id"],
                "element_ids": ids,
                "tiles": tiles if i == 0 else None,
                "controls": (
                    list(controls or []) if i == 0 and controls is not None
                    else [eid for eid in ids if (by_id.get(eid) or {}).get("kind") == "control"]
                ),
            })

    lines = ['<?xml version="1.0" encoding="utf-8"?>']
    if data and data_element_ids:
        lines.append(f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{data["id"]}">')
        row = 1
        for eid in data_element_ids:
            lines.append(f'  <Element elementId="{eid}" gridColumn="1 / 25" gridRow="{row} / {row + 20}"/>')
            row += 20
        lines.append('</Page>')
    extra = []
    pages_by_id = {p.get("id"): p for p in content_pages}
    for ps in page_specs:
        page_id = ps["page_id"]
        main = pages_by_id[page_id]
        ids = list(ps.get("element_ids") or [])
        ptiles = ps.get("tiles")
        if ptiles:
            items = tiles_items(ptiles, kinds={eid: (by_id.get(eid) or {}).get("kind")
                                               for eid in ids})
        else:
            elems = [{"id": eid, "kind": (by_id.get(eid) or {}).get("kind")}
                     for eid in ids
                     if (by_id.get(eid) or {}).get("kind") not in ("container", "control")]
            if elems:
                print("⚠ layout: no ThoughtSpot tile geometry (layout.tiles absent) — "
                      "SYNTHESIZED an auto grid; placement is NOT source-faithful, review it.",
                      file=sys.stderr)
            items = auto_items(elems)

        prefix = []
        ctl_items, next_row = controls_band(list(ps.get("controls") or []))
        prefix.extend(ctl_items)
        more, next_row = _prefix_items(ps.get("prefix_ids"), next_row)
        prefix.extend(more)
        if prefix and items:
            shift = next_row - min(i[3] for i in items)
            items = [[i[0], i[1], i[2], i[3] + shift, i[4] + shift] for i in items]
        items = prefix + items
        title = main.get("name") or "Dashboard"
        page_xml, page_extra = banded_page(page_id, items, title)
        lines.append(page_xml)
        extra.extend(page_extra)
    return "\n".join(lines) + "\n", extra


def prepare_document(spec, *, tiles=None, controls=None, page_specs=None,
                     data_element_ids=None):
    """Return a complete current workbook document with exact-once placement."""
    doc = code_rep.document(spec)
    doc = {**doc, "kind": doc.get("kind") or "workbook"}
    doc["pages"] = [
        {k: v for k, v in page.items() if k != "elements"}
        for page in doc.get("pages", [])
    ]
    doc["elements"] = [
        e for e in code_rep.workbook_elements(spec) if not _is_generated_band(e)
    ]
    layout, extra = build_layout(
        doc, tiles=tiles, controls=controls, page_specs=page_specs,
        data_element_ids=data_element_ids,
    )
    doc["elements"].extend(extra)
    doc["layout"] = layout

    declared = [e.get("id") for e in doc["elements"] if e.get("id")]
    placed = _layout_element_ids(layout)
    duplicate_declared = sorted({eid for eid in declared if declared.count(eid) > 1})
    duplicate_placed = sorted({eid for eid in placed if placed.count(eid) > 1})
    missing = sorted(set(declared) - set(placed))
    ghosts = sorted(set(placed) - set(declared))
    if duplicate_declared or duplicate_placed or missing or ghosts:
        raise ValueError(
            "layout must place every flat document element exactly once "
            f"(duplicate elements={duplicate_declared}, duplicate placements={duplicate_placed}, "
            f"unplaced={missing}, undeclared={ghosts})"
        )
    return doc

def apply(wb, tiles=None, controls=None, page_specs=None, data_element_ids=None):
    # Preserve the complete live document. PUT accepts exactly {document: ...};
    # sending response metadata beside it is invalid, and rebuilding only pages
    # would erase settings, panels, overlays, agents, or unknown future fields.
    raw = json.loads(req("GET", f"/v2/workbooks/{wb}/spec"))
    doc = prepare_document(
        raw, tiles=tiles, controls=controls, page_specs=page_specs,
        data_element_ids=data_element_ids,
    )
    put_body = {"document": doc}
    resp = req("PUT", f"/v2/workbooks/{wb}/spec", json.dumps(put_body))
    return "workbookId" in resp

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", default=None, help="dir holding migrate_out.json (default $TS_WORKDIR or ./ts-migration)")
    ap.add_argument("workbooks", nargs="*", help="specific workbook ids (auto grid; skips the manifest)")
    a = ap.parse_args()
    if a.workbooks:
        jobs = [(wb, None, None, None, None) for wb in a.workbooks]
    else:
        wd = os.path.abspath(os.path.expanduser(a.workdir or os.environ.get("TS_WORKDIR")
                             or os.path.join(os.getcwd(), "ts-migration")))
        manifest = os.path.join(wd, "migrate_out.json")
        m = json.load(open(manifest))
        results = m.get("results", m)          # new manifest nests under "results"
        jobs = [(r["workbook"], r.get("tiles"), r.get("controls"),
                 r.get("layoutPages"), r.get("dataElements"))
                for r in results.values() if r.get("workbook")]
    ok = 0
    for wb, tiles, controls, page_specs, data_element_ids in jobs:
        try:
            apply(
                wb, tiles=tiles, controls=controls, page_specs=page_specs,
                data_element_ids=data_element_ids,
            )
            ok += 1
            has_source_tiles = any(p.get("tiles") for p in (page_specs or [])) or bool(tiles)
            print(f"✓ laid out {wb} ({'TML tiles' if has_source_tiles else 'auto grid'})")
        except Exception as e:
            print(f"✗ {wb}: {e}")
    print(f"\n{ok}/{len(jobs)} workbooks laid out")

if __name__ == "__main__":
    main()
