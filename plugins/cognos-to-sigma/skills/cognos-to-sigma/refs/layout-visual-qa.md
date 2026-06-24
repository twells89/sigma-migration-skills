# Layout Visual QA — mandatory render-and-inspect gate

Shared across all `*-to-sigma` migration plugins. A workbook that POSTs cleanly (HTTP 200)
and passes numeric/CSV parity can still be **wrong** — overlapping tiles, clipped titles, dead
zones, orphaned filters, a render that looks nothing like the source, or a layout that reads as
generic AI-templated output. The export API renders exactly what a user sees, so the only
reliable check is to **render each page to PNG and actually read the image** before declaring the
migration done.

> **The rule that triggered this gate:** Sigma's grid layout has **no z-order**. Source tools
> with floating/absolute canvases (Qlik's associative listboxes & filterpanes, Power BI free-form
> visuals, QuickSight FreeForm, Tableau floating zones) routinely place a **filter/legend/listbox
> on top of a chart**. Preserving those coordinates 1:1 makes the two elements render *stacked on
> the same cell*. The build scripts now resolve this deterministically (controls lifted to their
> own band; `decollide_bands` tiles any remaining 2-D overlap edge-to-edge) — but novel layouts
> can still slip through, which is why this human/agent visual gate is mandatory.

## Mandatory loop (run after the workbook is POSTed, before you call it done)

1. **Render the FULL Sigma page** (the whole dashboard, one image — not per-element) at a
   realistic width:
   `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600`
   (Contract: `POST /v2/workbooks/{id}/export` → poll `/v2/query/{q}/download`. Plugins that ship
   their own renderer — `export-chart-png.rb`, `compare.py` — use the same contract.)
1b. **Render the FULL SOURCE dashboard** as ONE image and compare full-dashboard ↔ full-dashboard:
   Tableau MCP `get-view-image` on the **dashboard view** (not each worksheet); Power BI page
   export; MicroStrategy `export-dossier-pdf.py`; the equivalent source export each plugin
   captures in discovery. Place the two full images side by side. **Compare dashboard-to-dashboard,
   never element-by-element** — per-element screenshots (e.g. `export-chart-png.rb`) miss
   layout/relationship defects (overlaps, dead zones, a control stranded outside its chart, wrong
   relative sizing) and are NOT a substitute for the full-page comparison. Use per-element PNGs
   only as a drill-down after a full-page mismatch.
2. **Read both full PNGs** and check the Sigma render against the source AND the three rubrics
   below (source-fidelity → structural → design-quality, in that order).
3. **Fix** any failure (re-band, resize, move a control into its chart's container, shorten a
   map title) by editing the spec — for large multi-page workbooks use
   `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit element files → push) — then
   **re-render and re-read**.
4. **Loop until the render passes inspection.** Declare the migration done on a *clean render*,
   never on an HTTP 200.

## 1. Source-fidelity parity (run BEFORE the quality rubrics)

Clean ≠ faithful. A workbook can be perfectly laid out and still look nothing like the dashboard
it migrated. This check compares the render against the **source's own appearance**, captured as a
full-page source export in discovery (Tableau dashboard image, Power BI page export, MicroStrategy
`source_dossier.pdf`, etc.). Put the Sigma page PNG and the source page side-by-side and verify,
page-for-page:

- [ ] **Same element set** — every viz on the source page exists on the Sigma page (none dropped, none invented).
- [ ] **Same arrangement** — relative position holds (a 3-column source stays 3-column; KPIs that sit under a chart stay under it). Pixel-exact isn't required; the *grouping and reading order* are.
- [ ] **Matching chart KIND** — source KPI → Sigma `kpi-chart` (not a 1-row table); source horizontal bar → horizontal bar; microchart/indicator → the closest Sigma equivalent (conditional-formatted table / data bars), not a generic bar. The source's declared `visualizationType` (`kpi`, `microcharts`, `combo_chart`, `grid`, …) is the spec to match.
- [ ] **KPI shows the source's VALUE** — confirm the big number equals what the source card shows (often a latest-period stat, not a windowed Sum). A KPI that's structurally a KPI but shows the wrong metric FAILS.
- [ ] **Controls / selector panels present** — source filter panels, attribute/metric selectors, and chapter filters have Sigma equivalents (controls or an inherited base filter). An interactive source page rebuilt as a static grid FAILS.
- [ ] **Branding bands** — header strips, logos, greeting/title bands present, OR explicitly descoped *with the user* and recorded.

A render that diverges on any unchecked box is a FAIL even when row parity is green — fix the spec
and re-compare. **Known spec ceilings** (don't loop on them — note them as editor follow-ups): KPI
sparklines and comparison/delta badges are UI-only (`sigma-workbooks` `kpis.md`); source-tool
chrome (theme toggles, native nav) has no spec equivalent. When the user scopes styling down
("layout + metrics, skip branding"), record exactly what was descoped in the final summary — never
drop it silently.

## 2. Structural rubric (read the PNG against every item)

- [ ] **No overlaps / no stacking.** No two elements occupy the same cell; no filter, legend, or
      listbox sits on top of a chart or KPI. (This is the #1 failure for floating-canvas sources.)
- [ ] **No dead zones.** The page title never shares a band with a chart; bands are stacked edge
      to edge; no giant empty tile (usually an over-tall table — size to content).
- [ ] **Controls placed correctly.** A global filter sits in a top control band; a control scoped
      to one chart lives *inside that chart's container*, never floating loose on the page.
- [ ] **No clipped titles/values.** KPI bands are ≥ 5 grid rows (titles hide below that); side
      charts are ≥ 6 columns wide (narrower truncates the title); table tiles show all rows
      without cutting off the summary bar.
- [ ] **Trend/comparison KPIs are tall enough to show the spark.** A KPI stacks title → value →
      comparison → sparkline and drops the lower items first when short, so a KPI carrying a
      sparkline or delta needs ~8+ grid rows (~240px), not 5. If you built a sparkline but the
      render shows only the number, grow the tile's `gridRow` span and re-export before concluding
      it failed — a too-short tile makes a real spark look missing.
- [ ] **Even heights.** Charts in one band share an inner row span; sibling chart bands match.
- [ ] **Right chart kind & formatting.** The rendered viz matches the source (no silently-dropped
      log scale, data labels, `$`/`%` formats, or palette).

## 3. Design-quality rubric (read AFTER the structural pass)

> **Fidelity wins ties.** These checks make a *faithful* migration also look intentional rather
> than generically AI-templated. They are tie-breakers for the converter's own **defaults** — never
> a license to override the source. If the source dashboard deliberately uses equal-width tiles, a
> flat KPI strip, or centered text, **keep it**; the source-fidelity rubric (§1) outranks polish.
> Apply a design fix only where the converter picked a default and the source didn't dictate
> otherwise. (Derived from the AI design anti-patterns catalog.)

- [ ] **Focal point exists.** The page's signature element — the source's hero viz, or the primary
      KPI — reads as the most important thing (larger span or stronger position), not one cell in a
      uniform grid. *AI tell: every tile the same size and visual weight; "generic dashboard."*
- [ ] **Proportion follows priority.** Two tiles share a row at equal width only when they're true
      peers (a KPI strip, a real side-by-side comparison). A primary chart outweighs a supporting
      one; a 50/50 split of unequal-priority content reads as indecisive. *AI tell: automatic
      equal-width rows.*
- [ ] **Pages don't all open the same way.** In a multi-page workbook, not every page leads with an
      identical KPI band — each page opens with the thing it's actually for. *AI tell: every screen
      starts with the same metric strip; feels templated.*
- [ ] **Grid breaks where purpose changes.** Section layout shifts when the content's job shifts,
      instead of repeating one 2–3-chart row down the whole page. *AI tell: "spreadsheet of cards."*
- [ ] **Accent color is reserved, not sprayed.** Background tint / accent lives on the header band
      and meaningful emphasis (state, the hero KPI) — not a pale wash on every container. When every
      surface gets a touch of accent, nothing stands out. *AI tell: decorative accent overuse.*
- [ ] **Status colors are tuned, not raw defaults.** Conditional-format / KPI semantic colors fit
      the palette while preserving meaning; not unmodified saturated red/green badge defaults. *AI
      tell: oversaturated framework-default status colors.*
- [ ] **Typographic hierarchy.** Header → section title → KPI value → label form a clear scale (size,
      weight, contrast); not every heading and number competing at the same visual volume. *AI tell:
      flat typography; "feels like a form, not an application."*
- [ ] **Alignment is intentional.** Left for text, natural for numbers; centering reserved for
      genuine moments of emphasis, not applied to every section. *AI tell: centered text everywhere;
      every section reads like a landing page.*
- [ ] **Containers are for bands, not decoration.** No chart wrapped in its own card *inside* a band
      container (card-in-card flattens hierarchy). Separate content levels with spacing, type, and
      dividers before adding another container. *AI tell: nested cards.*
- [ ] **Tables use the presentation style.** `table` / `pivot-table` elements carry
      `tableStyle: {preset: presentation}` (roomier than the dense `spreadsheet` default) unless the
      source is a true data grid; any source in-cell **data bars** are carried over (`dataBars`).

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
| KPI row | ≥ 5 rows (≥ 8 if KPIs carry a sparkline/comparison) | N KPIs side-by-side, equal col spans (true peers → equal is correct here) |
| Chart row | 11–12 rows | 2–3 charts side-by-side, identical inner row span, each ≥ 6 cols |
| Detail table | content + summary (~4 rows + ~0.7/row) | never a fixed 20 (dead space) |

**Design defaults that keep the render off the anti-pattern list** (apply only where the source
doesn't dictate otherwise — §3 fidelity caveat):

- **Give the hero its weight.** When a page has one signature viz (the source's largest/top viz, or
  the primary trend), span it wider than its neighbors instead of forcing it into an equal split.
  Equal col spans are right for a KPI strip and true comparisons — not for everything.
- **Vary multi-page openings.** Don't auto-prepend an identical KPI band to every page; lead each
  page with its own primary content.
- **Reserve the accent.** Tint the header band and the hero KPI, not every container. Default the
  rest to the neutral surface.
- **Let type carry hierarchy.** Header title > section titles > KPI values > labels — don't flatten
  everything to one size.

**Table style — default to `presentation`.** Set `tableStyle: {preset: presentation}` on every
`table` / `pivot-table` element (roomier rows, lighter grid lines — matches how most source BI tools
present tables and reads better than Sigma's dense `spreadsheet` default). Keep `spreadsheet` only when
the source is explicitly a dense data grid. This is spec-authorable and round-trips but is **frequently
dropped** in migrations — set it deliberately. While you're styling the table, carry over any source
in-cell bars with `conditionalFormats: [{type: dataBars, columnIds: [<aggregate col id>], scheme: ["#a4dfc0","#4caf7d"]}]`
(also spec-authorable, also commonly dropped). See sigma-workbooks `tables.md` for the full field set.

## Known render caveats (not fixable via spec — keep titles short, drop redundant legends)

- **point-map / region-map**: the element `name` and legend render *overlaid on the map canvas*;
  a long title collides with legend chips. No legend/title-position knob in the OpenAPI.
- KPI titles hide below ~5 grid rows. Container style knobs that round-trip: backgroundColor,
  borderRadius, borderColor, borderWidth, padding (`borderColor/Width` incompatible with
  `padding: none`).

_Base patterns verified 2026-06-10 on tj-wells-1989 (workbooks bc24d476, 3e23b761, 9733fcd9)
against a known-good native layout (Chart Zoo Enhanced v4, 39a8f826)._
