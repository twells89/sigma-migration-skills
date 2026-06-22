# Layout Visual QA — mandatory render-and-inspect gate

Shared across all `*-to-sigma` migration plugins. A workbook that POSTs cleanly (HTTP 200)
and passes numeric/CSV parity can still be visually broken — **overlapping tiles, clipped
titles, dead zones, orphaned filters**. The export API renders exactly what a user sees, so
the only reliable check is to **render each page to PNG and actually read the image** before
declaring the migration done.

> **The rule that triggered this gate:** Sigma's grid layout has **no z-order**. Source tools
> with floating/absolute canvases (Qlik's associative listboxes & filterpanes, Power BI free-form
> visuals, QuickSight FreeForm, Tableau floating zones) routinely place a **filter/legend/listbox
> on top of a chart**. Preserving those coordinates 1:1 makes the two elements render *stacked on
> the same cell*. The build scripts now resolve this deterministically (controls lifted to their
> own band; `decollide_bands` tiles any remaining 2-D overlap edge-to-edge) — but novel layouts
> can still slip through, which is why this human/agent visual gate is mandatory.

## Mandatory loop (run after the workbook is POSTed, before you call it done)

1. **Render every page** to PNG at a realistic width:
   `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600`
   (Plugins that ship their own renderer — `export-chart-png.rb`, `compare.py` — may use it;
   the contract is identical: `POST /v2/workbooks/{id}/export` → poll `/v2/query/{q}/download`.)
2. **Read each PNG** and check it against the rubric below.
3. **Fix** any failure (re-band, resize, move a control into its chart's container, shorten a
   map title) by editing the spec — for large multi-page workbooks use
   `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit element files → push) — then
   **re-render and re-read**.
4. **Loop until the render passes inspection.** Declare the migration done on a *clean render*,
   never on an HTTP 200.

## Source-fidelity parity (run BEFORE the quality rubric)

Clean ≠ faithful. A workbook can be perfectly laid out and still look nothing like the
dashboard it migrated. This check compares the render against the **source's own
appearance**, captured in Phase 1.1 as `source_dossier.pdf` (MSTR: `export-dossier-pdf.py`;
other plugins have an equivalent source export). Put the Sigma page PNG and the source page
side-by-side and verify, page-for-page:

- [ ] **Same element set** — every viz on the source page exists on the Sigma page (none dropped, none invented).
- [ ] **Same arrangement** — relative position holds (a 3-column source stays 3-column; KPIs that sit under a chart stay under it). Pixel-exact isn't required; the *grouping and reading order* are.
- [ ] **Matching chart KIND** — source KPI → Sigma `kpi-chart` (not a 1-row table); source horizontal bar → horizontal bar; microchart/indicator → the closest Sigma equivalent (conditional-formatted table / data bars), not a generic bar. The dossier's `visualizationType` (`kpi`, `microcharts`, `combo_chart`, `grid`, …) is the spec to match.
- [ ] **KPI shows the source's VALUE** — confirm the big number equals what the source card shows (often a latest-period stat, not a windowed Sum — see SKILL.md Phase 1.1). A KPI that's structurally a KPI but shows the wrong metric FAILS.
- [ ] **Controls / selector panels present** — source filter panels, attribute/metric selectors, and chapter filters have Sigma equivalents (controls or an inherited base filter). An interactive source page rebuilt as a static grid FAILS.
- [ ] **Branding bands** — header strips, logos, greeting/title bands present, OR explicitly descoped *with the user* and recorded.

A render that diverges on any unchecked box is a FAIL even when row parity is green — fix the
spec and re-compare. **Known spec ceilings** (don't loop on them — note them as editor
follow-ups): KPI sparklines and comparison/delta badges are UI-only (`sigma-workbooks`
`kpis.md`); source-tool chrome (theme toggles, native nav) has no spec equivalent. When the
user scopes styling down ("layout + metrics, skip branding"), record exactly what was
descoped in the final summary — never drop it silently.

## Pass/fail rubric (read the PNG against every item)

- [ ] **No overlaps / no stacking.** No two elements occupy the same cell; no filter, legend, or
      listbox sits on top of a chart or KPI. (This is the #1 failure for floating-canvas sources.)
- [ ] **No dead zones.** The page title never shares a band with a chart; bands are stacked edge
      to edge; no giant empty tile (usually an over-tall table — size to content).
- [ ] **Controls placed correctly.** A global filter sits in a top control band; a control scoped
      to one chart lives *inside that chart's container*, never floating loose on the page.
- [ ] **No clipped titles/values.** KPI bands are ≥ 5 grid rows (titles hide below that); side
      charts are ≥ 6 columns wide (narrower truncates the title); table tiles show all rows
      without cutting off the summary bar.
- [ ] **Even heights.** Charts in one band share an inner row span; sibling chart bands match.
- [ ] **Right chart kind & formatting.** The rendered viz matches the source (no silently-dropped
      log scale, data labels, `$`/`%` formats, or palette).

## Building clean in the first place (so the gate rarely fails)

Group every page into horizontal **band containers** — never a flat list of `<LayoutElement>`s:
header band → control band → KPI band → chart rows → detail row. Verified container contract:

- Spec side: a `kind: container` placeholder element per band.
- Layout side: a `<GridContainer>` (NOT `<LayoutElement type="grid">`, which silently drops
  children); child `gridRow`/`gridColumn` are **container-relative** (restart at 1);
  `gridTemplateRows="auto"`; every `elementId` must match a real spec element (mismatch =
  silent drop); GET before a layout PUT (POST reassigns ids; PUT preserves them).

| Band | Container span | Children |
|---|---|---|
| Header | rows `1 / 4`, style `#0F172A` + `round` | full-width title text, inner `1 / 25` |
| Control row | 3 rows | controls side-by-side, inner row `1 / 4` |
| KPI row | ≥ 5 rows | N KPIs side-by-side, equal col spans |
| Chart row | 11–12 rows | 2–3 charts side-by-side, identical inner row span, each ≥ 6 cols |
| Detail table | content + summary (~4 rows + ~0.7/row) | never a fixed 20 (dead space) |

## Known render caveats (not fixable via spec — keep titles short, drop redundant legends)

- **point-map / region-map**: the element `name` and legend render *overlaid on the map canvas*;
  a long title collides with legend chips. No legend/title-position knob in the OpenAPI.
- KPI titles hide below ~5 grid rows. Container style knobs that round-trip: backgroundColor,
  borderRadius, borderColor, borderWidth, padding (`borderColor/Width` incompatible with
  `padding: none`).

_Base patterns verified 2026-06-10 on tj-wells-1989 (workbooks bc24d476, 3e23b761, 9733fcd9)
against a known-good native layout (Chart Zoo Enhanced v4, 39a8f826)._
