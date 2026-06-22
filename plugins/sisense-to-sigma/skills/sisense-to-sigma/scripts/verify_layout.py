#!/usr/bin/env python3
"""
Layout-parity gate for a Sisense -> Sigma migration.

`verify_parity.py` proves the DATA matches. This proves the LAYOUT came over
correctly — a structural check that the emitted Sigma `layout` reproduces the
Sisense dashboard's arrangement (and, for auto-arranged stacks, that the result
is a clean, valid grid). Run it alongside the data-parity gate.

For every Sisense widget that maps to a Sigma element it asserts:
  - PLACED      every mapped widget is placed exactly once; no orphan refs
  - GRID        nothing escapes the 24-col grid; spans are positive
  - NO-OVERLAP  no two elements occupy the same grid cell
  - ORDER       reading order (top->bottom, left->right) matches Sisense
  - SIDE-BY-SIDE  widgets in the same Sisense cell stay on the same Sigma row
  - WIDTH       relative widths are preserved (a 50% Sisense widget ~= half grid)

Emits a GREEN/RED table and exits non-zero on any failure — do not claim the
layout migrated until GREEN.

Usage: python3 verify_layout.py <dashboards.json> <sigma_workbook_spec.json>
  dashboards.json        : the discover.py bundle (widgets + layout inlined)
  sigma_workbook_spec.json: the convert.py dashboard output
"""
import json, re, sys

GRID_COLS = 24

def parse_layout(xml):
    """elementId -> (col_start, col_end, row_start, row_end). Skips containers."""
    out = {}
    for eid, gc, gr in re.findall(
            r'<LayoutElement elementId="([^"]+)" gridColumn="([^"]+)" gridRow="([^"]+)"', xml):
        cs, ce = (int(x) for x in gc.split(" / "))
        rs, re_ = (int(x) for x in gr.split(" / "))
        out[eid] = (cs, ce, rs, re_)
    return out

def sisense_order(dashboards):
    """Sisense widgets in author reading order, with their cell index + width.
    Returns [(widgetid, cell_key, width_pct)] where cell_key groups widgets that
    sit side-by-side in the same Sisense cell."""
    seq, ck = [], 0
    for d in dashboards:
        for col in (d.get("layout") or {}).get("columns", []):
            for cell in col.get("cells", []):
                subs = cell.get("subcells", [])
                for sub in subs:
                    for el in sub.get("elements", []):
                        if el.get("widgetid"):
                            seq.append((el["widgetid"], ck, sub.get("width", 100)))
                ck += 1
    return seq

def widget_to_element(dashboards, spec):
    """Recover widgetid -> sigma elementId by replaying convert's title match.
    convert.py names every viz element after the widget title, so map on title
    in author order (titles can repeat; consume left-to-right)."""
    # build title -> [elementIds] in spec order (pmain viz only, skip controls)
    from collections import defaultdict, deque
    by_title = defaultdict(deque)
    for p in spec["pages"]:
        for e in p["elements"]:
            if e.get("kind") == "control" or e["id"] == "master":
                continue
            by_title[e.get("name")].append(e["id"])
    wid2elem = {}
    for d in dashboards:
        for w in d.get("widgets", []):
            t = w.get("title")
            if by_title.get(t):
                wid2elem[w.get("oid")] = by_title[t].popleft()
    return wid2elem

def main():
    dashboards = json.load(open(sys.argv[1]))
    dashboards = dashboards if isinstance(dashboards, list) else [dashboards]
    spec = json.load(open(sys.argv[2]))
    P = parse_layout(spec.get("layout", ""))
    wid2elem = widget_to_element(dashboards, spec)
    seq = sisense_order(dashboards)

    rows, failed = [], 0
    def check(label, cond, detail=""):
        nonlocal failed
        rows.append((("GREEN" if cond else "RED"), label, detail))
        if not cond:
            failed += 1

    # PLACED — every mapped, layout-present widget has exactly one placement
    placeable = [(wid, ck, w) for (wid, ck, w) in seq if wid in wid2elem]
    elem_ids = [wid2elem[wid] for wid, _, _ in placeable]
    missing = [e for e in elem_ids if e not in P]
    check("PLACED: every mapped widget placed", not missing,
          f"unplaced={missing}" if missing else f"{len(elem_ids)} placed")
    # non-widget placements that are legitimate: the data-page source (`master`)
    # and dashboard-filter controls (placed in the top GridContainer)
    legit = {"master"} | {e["id"] for p in spec["pages"] for e in p["elements"]
                          if e.get("kind") == "control"}
    orphans = [e for e in P if e not in set(elem_ids) and e not in legit]
    check("PLACED: no orphan layout refs", not orphans, f"orphans={orphans}" if orphans else "")

    placed = [(wid2elem[wid], ck, w) for wid, ck, w in placeable if wid2elem[wid] in P]

    # GRID — within 24 cols, positive spans
    bad = [e for e, _, _ in placed
           if not (1 <= P[e][0] < P[e][1] <= GRID_COLS + 1 and P[e][2] < P[e][3])]
    check("GRID: 24-col, positive spans", not bad, f"bad={bad}" if bad else "")

    # NO-OVERLAP — no two elements share a grid cell
    overlaps = []
    for i in range(len(placed)):
        ei = placed[i][0]; ci0, ci1, ri0, ri1 = P[ei]
        for j in range(i + 1, len(placed)):
            ej = placed[j][0]; cj0, cj1, rj0, rj1 = P[ej]
            if ci0 < cj1 and cj0 < ci1 and ri0 < rj1 and rj0 < ri1:
                overlaps.append((ei, ej))
    check("NO-OVERLAP: elements don't collide", not overlaps,
          f"{len(overlaps)} overlap(s): {overlaps[:3]}" if overlaps else "")

    # ORDER — Sigma reading order (row then col) matches Sisense author order
    by_reading = sorted(placed, key=lambda t: (P[t[0]][2], P[t[0]][0]))
    check("ORDER: reading order preserved",
          [e for e, _, _ in by_reading] == [e for e, _, _ in placed],
          "Sigma top->bottom/left->right == Sisense author order")

    # SIDE-BY-SIDE — widgets in one Sisense cell share a Sigma row start
    sbs_ok = True; sbs_detail = ""
    from itertools import groupby
    for ck, grp in groupby(placed, key=lambda t: t[1]):
        g = list(grp)
        if len(g) > 1:
            rstarts = {P[e][2] for e, _, _ in g}
            if len(rstarts) != 1:
                sbs_ok = False; sbs_detail = f"cell {ck} split across rows {rstarts}"
    check("SIDE-BY-SIDE: same Sisense cell -> same Sigma row", sbs_ok, sbs_detail)

    # WIDTH — within a multi-widget cell, Sisense width order must not be INVERTED
    # in the grid. Near-equal widths (e.g. 34/33/33, integer thirds) legitimately
    # map to equal grid spans, so only flag a genuine inversion: Sisense says i is
    # meaningfully wider than j (by > one grid column's worth of %), yet the grid
    # makes i narrower than j.
    width_ok = True; width_detail = ""
    TOL = 100.0 / GRID_COLS                      # one 24-col slice ~ this many %-points
    for ck, grp in groupby(placed, key=lambda t: t[1]):
        g = list(grp)
        if len(g) > 1:
            sis = [w for _, _, w in g]
            sig = [P[e][1] - P[e][0] for e, _, _ in g]
            for i in range(len(g)):
                for j in range(len(g)):
                    if sis[i] - sis[j] > TOL and sig[i] < sig[j]:
                        width_ok = False
                        width_detail = f"cell {ck}: sisense {sis} vs grid {sig} (#{i} should be >= #{j})"
    check("WIDTH: relative widths preserved (no inversions)", width_ok, width_detail)

    w = max(len(l) for _, l, _ in rows)
    print(f"\nLayout parity — {len(placed)} elements placed\n" + "-" * (w + 30))
    for status, label, detail in rows:
        mark = "\033[92m✓\033[0m" if status == "GREEN" else "\033[91m✗\033[0m"
        print(f"  {mark} {status:5} {label:<{w}}  {detail}")
    print("-" * (w + 30))
    print("RED" if failed else "GREEN", f"({failed} failure(s))" if failed else "(all checks passed)")
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
