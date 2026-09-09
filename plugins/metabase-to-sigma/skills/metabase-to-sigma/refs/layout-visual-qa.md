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
   `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out <WORK>/visual-qa/<page>.png --w 1600`
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
   the companion **sigma-workbooks** skill's `scripts/wb-rep.rb` (full-clone path: `plugins/sigma-authoring/skills/sigma-workbooks/scripts/wb-rep.rb`; pull → edit element files → push) — then
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


### 1b. STYLE CHECKLIST — required to record a visual PASS (v5.3, gate 8b)

`record-visual-check.rb --verdict pass` now REQUIRES `--checklist` covering six dimensions, each
judged against the SOURCE image (not your intent, not your memory of the fix). Round 5 proved
gestalt self-passes ship renders an exacting owner rejects — attest each dimension separately,
and be harsh: a "mostly" is a `fail`.

- `element_titles_hidden` — no element-title chrome the source hides ("Area Ch…", "Student Bar
  Chart"); no truncated titles anywhere.
- `palette_match` — pick 3-5 swatches off the source (series fill, background, accent) and eyeball
  them against the render; a teal source with navy/lavender output is a `fail`, as is a
  categorical palette leaking onto a monochrome chart.
- `composition_match` — same canvas grid and proportions (a wide 2-panel source must not become a
  portrait stack); section headers sit ADJACENT to their charts; no dead zones or overflow bands.
- `chart_shapes_match` — every tile keeps its chart family AND encoding (dot strips stay dot
  strips, pill bars stay pill bars); verified per tile, not per page.
- `labels_legible` — no truncated/clipped labels, values, or rows/columns; no leaked control stubs
  or raw data-prep tables on the canvas.
- `numbers_formatted` — percent decimals, currency, and delta chips print as the source prints
  them.

Any `fail` ⇒ the verdict is `divergent` (the recorder refuses a pass; the gate re-checks stale or
hand-edited verdicts). `na` is only for dimensions the page genuinely lacks (e.g. no numbers).

**Blind countersignature (PR-9).** Your checklist is necessary but no longer sufficient: a `pass`
also requires `--blind-grade <workdir>/blind-grade.json` — the verdict of a FRESH context-free
subagent that received only the two image paths + the rubric (`refs/blind-grader-brief.md`). The
grade is sha256-bound to the images and its per-tile chart-family readings are cross-checked
against the mechanical kind census; gate 8b refuses a self-attested pass with the remedy named.

**Recording `divergent` is not free.** A recorded `divergent` verdict passes gate 8b as RECORDED
(the comparison happened and the gaps are acknowledged), but the divergence is **budget-counted**:
`assert-phase6-ran.rb` injects `visual-divergent` into the waiver census, where it spends the same
exit-19 waiver budget as any quality waiver — so a divergent-visual run can still complete, but it
cannot ride to GREEN alongside 2 other waivers, and the budget line names it. GREEN requires the
budget to hold: fix the gaps, re-render, re-record `pass` — or accept YELLOW with the divergence
named in the report. Full verdict-capping (`divergent` caps the run at PARTIAL) is planned as
PLAN-v3 PR-14 and is not built yet; until then the budget is the cap.

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

Group every page into horizontal **band containers** — never a flat list of `<Element>`s:
header band → control band → KPI band → chart rows → detail row. Verified container contract:

- Spec side: a `kind: container` placeholder element per band.
- Layout side: a `<Container>` (NOT `<Element type="grid">`, which silently drops
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
in-cell bars with `conditionalFormats: [{type: dataBars, columnIds: [<aggregate col id>], scheme: [<tint>, <hue>]}]`
(also spec-authorable, also commonly dropped). The scheme must DERIVE from the source — the worksheet's
`heat_scheme` ramp, else `[mix(dominant, white, 88%), dominant]` from the theme's categoricalScheme;
never the Sigma default royal `#1a70f1` (round-4 defect). See sigma-workbooks `tables.md` for the full field set.

## Known render caveats (not fixable via spec — keep titles short, drop redundant legends)

- **point-map / region-map**: the element `name` and legend render *overlaid on the map canvas*;
  a long title collides with legend chips. No legend/title-position knob in the OpenAPI.
- KPI titles hide below ~5 grid rows. Container style knobs that round-trip: backgroundColor,
  borderRadius, borderColor, borderWidth, padding (`borderColor/Width` incompatible with
  `padding: none`).

## Render 500 / CSV-export ceiling — the pivot `totals` key (bisect)

A pivot-table element that carries a **`totals`** key **500s its CSV export** — a platform
ceiling, not a data defect. Live probe matrix (v5.4, small landed table, 5 single-pivot pages):

| pivot value | no `totals` | with `totals` |
|---|---|---|
| plain `Sum`            | CSV ✅ · PNG ✅ | CSV **500** · PNG ✅ |
| `PercentOfTotal`       | CSV ✅ · PNG ✅ | CSV **500** · PNG ✅ |
| ratio-of-sums (`a/b`)  | CSV ✅ · PNG ✅ | — |

**The key's PRESENCE is the sole trigger** — value type is irrelevant (plain sum, PercentOfTotal,
and ratio/division all export fine WITHOUT `totals`; both totals-bearing variants 500). Ratio /
`PercentOfTotal` values are **NOT** a trigger. **PNG renders tolerate the `totals` key** (all five
variants rendered), so a totals-bearing pivot still renders with hidden grand totals — but its CSV
export (verify-anchors' pivot pooling, `collect-parity-actuals`) is dead.

**Mechanism (v5.4; wording + sidecar reachability corrected v5.4.9):** generated pivots CARRY the
`totals` key from build onward (the chart builder stamps it; style-normalize re-adds it on
readback) — the only totals-free window is verify-anchors' strip bracket:
- `verify-anchors.rb` brackets its live pivot CSV exports — capture + strip each pivot's `totals`
  (one PUT), export against totals-free pivots, then restore (ensure; network-level PUT failures
  are rescued too, not just HTTP errors). It persists the captured totals to
  `<workdir>/anchors-restore-pivot-totals.json` BEFORE stripping and deletes it after a successful
  restore — a hard kill or failed restore is then repaired at the ship step with full fidelity
  (incl. `showSubtotals`), not the lossy grand-totals-only default.
- `put-layout.rb --apply-pivot-totals` is the ship-step REPAIR pass once the gates are green
  (`migrate-tableau.rb --finalize` runs it automatically and passes `--workdir`; run it by hand on
  the manual/recovery path): any pivot still lacking a `totals` key gets `showGrandTotals:hidden`.
  An optional `*-pivot-totals.json` sidecar — globbed from the `--layout` dir, the `--workdir`,
  and the cwd — overrides per element id (e.g. preserves a source pivot's deliberately SHOWN
  grand totals).
- `verify-visual-tiles.rb` / `verify-dashboard-visual.rb` NAME this ceiling on a render 500 instead
  of an opaque MISSING.

**Bisect a render/export 500:** strip the `totals` key first (or run the totals-free export) — if
it clears, this ceiling is the cause; do **not** waive the gate. Only if it persists totals-free is
it a genuine unbounded-dimension / service issue.

_Base patterns verified 2026-06-10 on a live Sigma org (three field workbooks)
against a known-good native-layout reference workbook._
