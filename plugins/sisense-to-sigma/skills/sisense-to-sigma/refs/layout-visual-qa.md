# Layout Visual QA — render-and-inspect gate

Shared discipline across all `*-to-sigma` migration plugins. A workbook that
POSTs cleanly (HTTP 200) and passes numeric parity can still be visually broken
— **overlapping tiles, clipped titles, dead zones, orphaned filters**. The
export API renders exactly what a user sees, so the reliable final check is to
**render each page to PNG and actually read the image** before declaring done.

Two layers, run in order:

## 1. Structural pre-check (automated, cheap) — `verify_layout.py`

```sh
python3 scripts/verify_layout.py <dashboards.json> <sigma_workbook_spec.json>
```
This is the fast gate: every mapped widget placed exactly once, no orphan refs,
inside the 24-col grid, **no overlaps**, reading order preserved, side-by-side
widgets share a row, relative widths not inverted. It catches the mechanical
failures (collisions, dropped/duplicated elements, inverted columns) without a
render. **Must be GREEN before you spend a render.** It does NOT judge whether
the result *looks* like the Sisense dashboard — that's layer 2.

## 2. Visual gate (render + read) — `sigma-export-png.py`

```sh
python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600
```
Contract (identical to every sibling): `POST /v2/workbooks/{id}/export` → poll
`/v2/query/{q}/download`. Render every page, read each PNG, fix the spec, loop
until clean. Declare done on a *clean render*, never on an HTTP 200.

### Source-fidelity parity (clean ≠ faithful)
Capture the Sisense source for side-by-side comparison — the dashboard's own PNG
via `GET /api/v1/dashboards/{id}/export/png` (or a screenshot). Verify page-for-page:

- [ ] **Same element set** — every widget on the Sisense page exists on the Sigma page (none dropped except knowingly-flagged treemap/sunburst/map; none invented).
- [ ] **Same arrangement** — Sisense's columnar grouping + reading order holds (a row of KPI cards stays a row; a 2-up chart row stays 2-up). The faithful path reproduces this; auto-arrange re-flows a degenerate stack — confirm the re-flow reads well.
- [ ] **Matching chart KIND** — indicator → `kpi-chart` (not a 1-row table); column/bar → bar; line/area → line/area; pivot2 → grouped pivot. HINT substitutions (polar→bar, funnel→bar, map→geo) are visible and acceptable, or re-flagged.
- [ ] **KPI shows the right VALUE** — the big number equals the Sisense indicator.
- [ ] **Controls present** — Sisense dashboard filters became Sigma controls in the top band (flat row), bound to the Master so they propagate.

### Pass/fail rubric (read the PNG)
- [ ] **No overlaps / no stacking** — no two elements share a cell; no control on top of a chart.
- [ ] **No dead zones** — title never shares a band with a chart; no giant empty tile (size tables to content).
- [ ] **Controls placed correctly** — global filters in the top control band.
- [ ] **Titles legible** — widget titles not clipped.

**Known spec ceilings** (don't loop on them — note as editor follow-ups): KPI
sparklines/delta badges are UI-only; Sisense BloX/scripted widgets and
treemap/sunburst have no spec equivalent (flagged, never faked). When styling is
scoped down ("layout + metrics, skip branding"), record exactly what was
descoped in the final summary — never drop it silently.
