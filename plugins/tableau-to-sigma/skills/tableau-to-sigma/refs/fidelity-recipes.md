# Fidelity recipes — the delta → spec-fix catalog for the Phase 5g RCF loop

> This is the codified **"spec surface the builder doesn't touch."** The one-shot builder
> emits structure; the exemplar migrations reached near-exact parity by iterating a
> render→compare→fix loop and reaching for these fixes. Each entry is a **delta you see in
> the render** → **the spec change that closes it**, every shape live-verified. Use it as the
> lookup table during Phase 5g: after you `record` a `spec-fixable` delta, find its row here,
> author the patch, and `apply-patch` it.
>
> Companion refs — do not duplicate, cross-reference: `composition-recipe.md` (the composition
> pass + value-fidelity + the full spec/API gotcha list), `layout-visual-qa.md` (the visual
> rubric this loop scores against), `control-parity.md` (control wiring + flip test),
> `sigma-workbooks/reference/specification/styling.md` (authoritative style field set).

## How to apply a fix (the single layout-preserving PUT)

Never hand-PUT a partial spec — that wipes the layout (the trap that cost passes in both
exemplars). Author a **patch** (a partial spec that names only what changes) and let
`fidelity-loop.rb apply-patch` GET the full live spec, deep-merge your patch into it, and PUT
the whole thing back — the layout rides through untouched. Arrays of elements merge **by
`elementId`/`id`**, so a patch naming one element's `style` leaves its siblings alone:

```bash
# patch.json — ONLY the delta:
# { "settings": { "theme": { "overrides": { "categoricalScheme": ["#0e7c7b","#14b8a6","#f2a900"] } } } }
ruby scripts/fidelity-loop.rb apply-patch --workdir <WORK> \
  --patch patch.json --resolves e2,e3        # marks those ledger entries resolved on success
```

`apply-patch` re-runs the column-type guard + layout lint + control lint after the PUT, so a
fix that introduces an `error` column or a dead zone fails the pass instead of shipping.

---

## Catalog (delta → fix)

Each row: **the visible delta** · the spec path · notes/gotcha.

### Canvas, theme & palette
- **Page/canvas background wrong color** → `settings.theme.overrides.colorOverrides: [{ name: "backgroundCanvas", color: "#RRGGBB" }]` (`document.settings.theme`).
- **Chart series / donut-pie slice colors are generic** → `settings.theme.overrides.categoricalScheme: [...]` — a **positional** array applied in category-sort order. This is the **only** spec path to donut/pie slice colors (per-element `color.scheme` is silently dropped on donut/pie). Extract the source hexes from the `.twb` (`composition-recipe.md` §"Extract brand colors").
- **Series colors INVERTED / swapped across members** (Top-500 gold on the Bottom-500 series) → the scheme must be **ordered ascending by member** so `scheme[i]` binds to the i-th category in Sigma's sort order. Where the `.twb` carries an explicit member→color map (`<encoding attr='color' type='palette'><map to='#hex'><bucket>…`), the builder now pins per-chart `color.scheme` AND orders `settings.theme.overrides.categoricalScheme` mechanically (PR-12, `scripts/lib/series_colors.rb`); check `formats-emitted.json` → `series_color_maps` (`pinned|theme|unpinned`) before hand-fixing a `palette_match` delta. Frequency-ranked palettes only apply when no explicit map exists.
- **Fonts don't match the source** → `settings.theme.overrides.fonts.{textFont, dataFont}`. Map the Tableau family to a web-safe family (Tableau "Tableau Book"/"Benton"→`Inter`/`Helvetica Neue`; a serif → `Georgia`). Only families Sigma ships round-trip.
- **Accent sprayed on every tile** (AI tell) → pull the tint back to the header band + the hero KPI only; default the rest to the neutral surface. See `layout-visual-qa.md` §3.

### Containers, cards & bands
- **Section card / tint / header band missing** → wrap the section in a `kind: container` with `style.{backgroundColor, borderRadius, borderColor, borderWidth, padding}`. (`borderColor`/`borderWidth` are incompatible with `padding: none`.)
- **A chart floats over a colored band and clips the tint** → set the element's own `style.backgroundColor: "#00000000"` (transparent) so the band shows through.
- **Full-width colored title bar** → a `container` with `style.backgroundColor` holding the title text. A text element alone **cannot** make a full-width bar (inline HTML has no full-bleed background).
- **Card-in-card** (a chart wrapped in its own card *inside* a band) → remove the inner card; separate levels with spacing/type, not nested containers.

### Text, chips & legends
- **Styled title / chip / pill / legend key** → markdown + hex `<span>` idioms. Inline HTML is whitelisted to `<u> <sub> <sup> <span> <a>` only; **`<div>` is rejected**; `<span style>` allows only `color`/`background-color`/`font-size`/`font-family`. Center/right via `<p style="text-align:center|right">`; **`text-align:left` is rejected** (it's the default — use a plain span). Full idiom set: `sigma-workbooks` styling.md.
- **White title invisible on a light page** → build the intended header **band** (colored container) so the white reads, OR recolor. Never emit invisible white-on-light.
- **Redundant legend on a chart that shares one with a sibling** → `legend.visibility: hidden` on the duplicate.

### KPIs & hero numbers
- **KPI hero number too small / not the focal point** → `value.fontSize` up + transparent element `style` + widen the tile's `layout.anchor`/grid span.
- **KPI value in the wrong format** (`$473.0k` vs source `$473.0K`) → emit an **exact-format text-formula column** (e.g. an uppercase-K suffix builder) and point the KPI value at it; don't rely on the number-format enum when the source uses a non-standard suffix. Format basics: money `$,.0f`; compact `$,.2s`. A KPI printing plain-raw where the source shows `$`/`%` is now a builder bug, not an RCF chore — the build maps the worksheet pill format and the column's `.twb` `default-format` mechanically (see §"Number & date formats" + `formats-emitted.json`).
- **KPI shows its own title *and* the card label** (duplicated) → set the KPI value-column `name: ' '` (single space; `''` re-derives the title).
- **KPI title clipped** → the tile is < ~5 grid rows; grow `gridRow`. Sparkline/comparison KPIs need ~8+ rows. NOTE on KPI sparklines + comparison/delta badges (live-probed 2026-07-11): the spec ACCEPTS `comparison`/`trend` FORMATTING blocks (spec/verify 200), but there is **no create-spec property that binds** the comparison column / trend axis, and the PUT rejects formatting-without-binding (`comparison.display: requires a comparison column or period comparison on the KPI`). Classify `ui-only` for creation; once a user binds it in the UI, the styling round-trips.

### Number & date formats (mechanical since PR-12)
- The one-shot build emits source formats mechanically: the worksheet's own pill `text-format`
  first, then the column's `.twb` `default-format` (the fix for KPIs printing raw where the
  source shows `$`), then master-map/name-heuristic. ONE translator: `scripts/lib/format_map.rb`
  (parser + builder both delegate). Per-tile coverage lands in **`formats-emitted.json`** next to
  the chart-spec output — `entries[]` (source format string → emitted format, `mapped|unmapped`;
  an unmapped source string is **recorded, never guessed**) + `series_color_maps[]`. Read it
  before hand-fixing a `numbers_formatted` delta.
- Mapping table (Tableau → Sigma d3-format):

  | Tableau source | Sigma format |
  |---|---|
  | `p0.0%` / `#,##0.0%` | `,.1%` |
  | `$#,##0.00` / `€#,##0` / `C1033` | `$,.2f` / `$,.0f` + `currencySymbol` |
  | `#,##0` / `0.00` | `,.0f` / `,.2f` |
  | `pos;(neg)` | leading `(` sign modifier (parens on negative) |
  | `#,##0,,,B` (scale-comma + suffix) | not d3-expressible → exact-format scaled column (KPI recipe above) |
  | `yyyy-MM-dd` / `MMM yyyy` / `MMMM d, yyyy` | `%Y-%m-%d` / `%b %Y` / `%B %-d, %Y` |

- **Sigma date-time formats are d3-time (strftime) strings** — `%B %-d, %Y`. Moment-style token
  strings (`"MMM D, YYYY"`) are NOT a format language to Sigma: every non-`%` character prints
  **literally**, so the tile renders the text `MMM D, YYYY` instead of a date (live-run
  finding). Never author one; `format_map` refuses (returns nil → recorded unmapped) any string
  it can't fully tokenize into `%`-directives.
- **`displayNullAs` exists on number formats** — `{kind: 'number', formatString: ',.0f',
  displayNullAs: '—'}` renders nulls as the literal. Use it when the source shows a dash/blank
  for null cells; the translator maps a quoted 4th Tableau format segment (`…;;;"—"`) to it.

### Status, thresholds & tables
- **Status chip / traffic-light cell** → `conditionalFormats` `type: single` with a **flat** `condition`/`value` (not nested).
- **Reference line / band / trendline** (Tableau analytics-pane marks) → NATIVE `refMarks` + `trendlines` (live-probed 2026-07-11: POST + readback + PNG render all green). Shapes: `refMarks: [{type: 'line'|'band', axis: 'axis'|'series'|'series2', value: {type: 'constant', value: N} | {type: 'column', columnId, func} | {type: 'formula', formula}, endValue: {…} (band only)}]`; `trendlines: [{columnId, model: linear|quadratic|polynomial|exponential|logarithmic|power}]`. Emit from parse-twb-layout's `ref_marks`. The computed-boolean + 2-color `scheme` trick is now only the fallback for layered-mark effects refMarks can't express.
- **Table too dense vs the source's roomy grid** → `tableStyle.{preset: presentation, cellSpacing, textStyles}`. `presentation` is the default to reach for; keep `spreadsheet` only for a true data grid.
- **In-cell data bars dropped** → `conditionalFormats: [{type: dataBars, columnIds: [<agg col id>], scheme: [<tint>, <hue>]}]`. **Scheme comes from the SOURCE, never a literal**: use the worksheet's parsed `heat_scheme` ramp when present, else derive `[mix(dominant, white, 88%), dominant]` from `settings.theme.overrides.categoricalScheme[0]`. The Sigma default royal `#1a70f1` family is the round-4 defect — never fall back to it. dataBars scheme is `[negative, positive]`, NOT a value gradient (probed) — value-shaded bars are a Sigma ceiling; add a parallel `backgroundScale` for the shading.
- **Ranked pivot (rank order + numbered rank header)** — the 3-round alphabetical-pivot fix. Ranks down ROWS: hidden `SORT_ORD` column (`ROW_NUMBER() OVER (ORDER BY <bias> DESC, <label>)` in the feed) + `rowsBy: [{id: <label col>, sort: {direction: 'ascending', by: <SORT_ORD id>, aggregation: 'min'}}]`; tie-blank labels via `CASE WHEN ROW_NUMBER() OVER (PARTITION BY RNK ...) = 1 THEN TO_VARCHAR(RNK) ELSE '' END`. Ranks across COLUMNS: numeric `RNK` as the OUTER columnsBy level renders the numbered 1..N header AND merges ties into spanning cells (exact Tableau look) — REQUIRES `totals.showSubtotals: 'when-collapsed'` ('hidden' is rejected; without it per-rank "N total" columns appear). **Constant-sort-key guard (the round-4 opus trap)**: never `sort.by` a `PercentOfTotal(…,"row")` column on a rowsBy sort (or `"column"` on columnsBy) — the key is constant across that axis, verify accepts it, and the pivot silently sorts alphabetically; sort by the inner aggregate instead. Top-N pivots need the PRE-FILTERED SOURCE table (element filters don't prune pivots — bisect-proven); build-charts mechanizes this (`-topn-src` helpers + `topn-members.json`).
- **Table at order-grain but source shows a rollup** → build a hidden grouped rollup element and source the table from it via `groupingId`.
- **Sort** → NATIVE (the old "spec sorts silently dropped" rule is STALE — re-probed 2026-07-11: axis sort POSTs, survives readback, and renders in the sorted order). Charts: `xAxis.sort: {by: <columnId>, direction: ascending|descending, aggregation?}`; tables: `sort: [{columnId, direction, nulls?}]`. Keep the `top-n` rank-filter ONLY for truncation (top-N), not as a sort substitute.
- **Pivot grand totals / subtotals** → NATIVE `totals: {showGrandTotals: shown|hidden, showSubtotals: always|when-collapsed, totalPosition: first|last, …colors/fontWeight}` (live-probed 2026-07-11: `showGrandTotals: 'hidden'` renders with no grand-total row). Supersedes the earlier failed 2-shape grand-total-hiding attempts. **CSV-EXPORT CEILING (v5.4, probe-isolated):** a pivot carrying a `totals` key **500s its CSV export** — the key's PRESENCE is the sole trigger (value type is irrelevant; plain `Sum`, `PercentOfTotal`, and ratio-of-sums all export fine WITHOUT it; both totals-bearing variants 500). **PNG renders tolerate it.** Pivots CARRY the `totals` key from build onward; `verify-anchors.rb` strips-then-restores it around its pivot CSV exports (the only totals-free window; captured totals persisted to `<workdir>/anchors-restore-pivot-totals.json` until restored), and `put-layout.rb --apply-pivot-totals` repairs any pivot left totals-less as the final PUT (auto-run by `--finalize` with `--workdir`; run by hand on the manual path — an optional `*-pivot-totals.json` sidecar in the workdir/--layout dir/cwd overrides per element id). Full matrix + bisect: `refs/layout-visual-qa.md` → "Render 500 / CSV-export ceiling".

### Chart kind, marks & axes
- **Wrong chart kind** (source horizontal bar rendered as a vertical bar, KPI rendered as a 1-row table, heatmap as bars) → set the element `kind` to the source's declared `visualizationType` equivalent; for bar orientation see `refs/window-functions.md`/coverage-matrix and the bar-orientation enum note in memory.
- **Bar/line color missing** → `color = {by, column, scheme}` (not a bare `{scheme}`); single-series charts omit `color` entirely.
- **Donut center total missing** → `holeValue: {id: <a column whose id ≠ value's>}` (equal ids silently drop the element).
- **Dropped log scale** → `yAxis.format.scale: {type: log}`. KNOWN CEILING: the PNG export endpoint renders log axes **linearly** even though the live UI is correct — verify in the live workbook; note YELLOW `log-axis export-renders-linear`, do NOT re-emit.

### Controls & parameters
- **Source has parameters/quick-filters but the workbook has 0 controls** → rebuild them (`composition-recipe.md` §"Controls & parameters"): list control, date-range control, wire `filters` to the base tables. This is a **functional** dimension — see the rubric.
- **Dropdown vs segmented mismatch** → `controlType: list` (dropdown) vs a segmented/`button` control; match the source widget. Number-control refs are safe in `[ControlId]` arithmetic; date/list control refs hit the variant bug.
- **`d3`/`strftime` format mismatch** → map the source's format token to Sigma's `d3`-format / d3-time string (money `$,.0f`, compact `$,.2s`, date `%b %Y`). Date-times take d3-time `%`-directives ONLY — a moment-style `MMM YYYY` prints literally (see §"Number & date formats").

---

## When NOT to loop (classify and move on)

These are **ceilings**, not spec-fixable — `record` them `ui-only` / `sigma-capability` so the
ledger flows them to the report instead of blocking the gate:

- KPI sparklines, comparison/delta badges (binding is UI-only; formatting blocks spec-round-trip — see §KPIs, probed 2026-07-11).
- Tooltip beyond `columnNames`; trellis facet-column binding (UI-only — schema-confirmed 2026-07-11: the spec `trellis` object is facet STYLING only `{column/row: {border,labels,title}, share, tileSize}`; no property binds a facet column).
- `useAsFilter` (chart-as-filter), pie percent-labels (`valueFormat:'percent'`) — silently dropped.
- point-map/region-map title+legend overlap (no position knob).
- Log-axis PNG export renders linear (render-side, not a spec defect).
- Pivot **`totals` key 500s the CSV export** (not the render) — do NOT waive a pivot-export/anchors 500 as a service outage; it is this ceiling. The pipeline handles it automatically (strip during verification via `verify-anchors.rb`; re-hide at ship via `put-layout.rb --apply-pivot-totals`). See §"Pivot grand totals / subtotals" and `refs/layout-visual-qa.md`.

---

## Live-verified recipes (2026-07 10-workbook live migration)

Validated end-to-end on the 10-workbook / 30-dashboard live-migration migration (10/10 GREEN,
~620 exact value checks). Each recipe rendered correctly, round-tripped through GET, and
reproduced the source's numbers exactly. The transferable one-line rules also ship in the
learned-rules starter pack (`learned/starter-rules.yaml`) — this section is the spec-shaped
detail behind them.

### Floating bars — waterfall / candlestick / gantt (white-base recipe)
Stacked bar with an invisible base series **named `zz base`** — Sigma stacks the
**last-sorted** color category at the bottom, so the sort-name trick is load-bearing (rename
it and the bars stop floating). Base value = the bar's offset (waterfall running total /
candle low / gantt start); visible series = the span. Base color = the card background
(`#FFFFFF` — `color.scheme` rejects 8-digit `#RRGGBBAA` hex, so true transparency is out).

```json
{ "kind": "bar-chart", "xAxis": {"columnIds": ["c-stage"]},
  "yAxis": {"columnIds": ["c-base", "c-span"]}, "stacking": "stack",
  "color": {"by": "category", "column": "c-series",
            "scheme": ["#FFFFFF", "#4e79a7"]} }
```
- Series names: base column/category `zz base` (sorts last → stacks bottom), span series any name.
- Candlestick: split span into up/down measures for green/red; tighten `yAxis.format.scale.domain` (e.g. 34–48). No high/low wicks — single mark layer; record `sigma-capability`.
- **Positive-domain only.** Stacking splits pos/neg, so floating bars *crossing zero* are impossible — fall back to signed diverging bars (up/down/total colors + labels) and record `sigma-capability`.

### Waffle / gridplot — pivot + `backgroundScale`
10×10 pivot (row bucket × col bucket via SQL `ROW_NUMBER` division) with a computed
`FILLED` 0/1 flag driving the fill:

```json
{ "kind": "pivot-table", "values": ["c-filled"],
  "rowsBy": [{"columnId": "c-row"}], "columnsBy": [{"columnId": "c-col"}],
  "conditionalFormats": [{ "type": "backgroundScale", "columnIds": ["c-filled"],
    "scheme": ["#e8eaed", "#0e7c7b"], "includeValues": true }] }
```
**`includeValues: false` silently kills the whole format** — keep `true`; cell values cannot
be hidden via spec (ship them visible rather than lose the fill). 13 filled cells = 13% exact.

### Diverging bars — likert scales / population pyramids
Signed measures (negate the "disagree"/left side in SQL or a calc column), one bar chart,
category color per sentiment/sex band. Bars diverge around zero natively — no special mark
needed; shares stay exact. Same recipe covers zero-crossing waterfalls (see above).

### Strip / jitter / barbell / beeswarm — scatter with computed coordinates
`scatter-plot` with a SQL-computed positional column + `size` channel:
- **Strip/jitter:** deterministic hash jitter (`MOD(ABS(HASH(id)), 100)/100.0`) on the cross axis.
- **Beeswarm:** symmetric stack — `ROW_NUMBER() OVER (PARTITION BY bin ORDER BY v)` with alternating sign.
- **Barbell/strip with magnitude:** numeric-dimension x + `size: {id: c-measure}`.
A column cannot sit on two channels (`xAxis` + `color`) — duplicate it under a second id.

### Bump chart — inverted rank axis
`yAxis.format.scale.domain` **inverted domains work**: `{"min": 5.5, "max": 0.5}` renders
rank 1 on top. Half-step over/undershoot keeps the extreme rank lines unclipped. Rank via
SQL helper (`RANK() OVER (PARTITION BY period ORDER BY v DESC)`).

### Chord / sankey — matrix-heatmap fallback (no ribbon mark exists)
Origin × destination pivot with `backgroundScale` on the flow measure preserves every flow
value exactly; for sankey add normalized stacked bars per stage for the stage shares:

```json
{ "kind": "pivot-table", "values": ["c-flow"],
  "rowsBy": [{"columnId": "c-origin"}], "columnsBy": [{"columnId": "c-dest"}],
  "conditionalFormats": [{ "type": "backgroundScale", "columnIds": ["c-flow"],
    "scheme": ["#FFFFFF", "#6a51a3"], "includeValues": true }] }
```
Record the ribbon geometry itself as `sigma-capability` (no spec or UI path).

### Hex map — us-state choropleth fallback + sequential fill
Tableau hex-tile maps (custom polygon grids) have no Sigma geometry; ship a `region-map`
`regionType: "us-state"` choropleth. Sequential value fill **is spec-supported**:

```json
{ "kind": "region-map", "region": {"id": "c-state", "regionType": "us-state"},
  "color": {"by": "scale", "column": "c-sales"} }
```
`by: "scale"` rendered a white→navy fill and round-tripped (49/49 state values exact);
`by: "value"` remains rejected (HTTP 400). `color.column` must differ from `region.id`.

### `{{formula | d3-format}}` text templating — delta badges, dynamic sentences, alerts
Text elements template live values: `{{Max([OD Rollup/Order Year Text])}}`,
`{{Sum([Master/Delta]) | +.1%}}`. **Element refs work (including cross-page); refs to a
filtering list control render `Invalid Query`** (segmented-control refs work). Template on
an element-ref formula over a helper column, never a filtering control's id. Wrap numbers
in `Text()` when concatenating into strings — `"Q" & 4` compiles but errors at render.

### KPI / control correctness rules that ride along with these recipes
- **KPI columns must inline the full aggregate** — a bare sibling-column ref compiles clean, renders null.
- **List-control filters on a NUMBER column are silently stripped on PUT** — bind to a `Text(...)` filter-key column.
- **Single-select manual list controls take scalar `value`**, not `values: []` (else filters + default drop).
- **Integer/bit predicates need explicit comparison** — `If([flag] = 1, …)`, never `If([flag], …)`.

### Multi-metric region dashboard — {Year-on-Year bars / Trend / Top-Countries} × N metrics

The proven pattern for a dashboard that repeats the same 3-panel row per metric (the Metric Series shape). Applying it is the difference between the good hand-authored result and the regressed autonomous one (region-aggregate rows shown as countries, all-years sums, bars collapsed to one region). When Phase 1d has recorded a single list control with a mix of `target_tiles` and `highlight_tiles`, this is the shape.

1. **Two master tables off the same DM element** — `master` (control-FILTERED) and `masterAll` (UNFILTERED, same columns). The Region control filters `master` only.
   - Panels in the control's `highlight_tiles` (the Year-on-Year bars) source **`masterAll`** → show every region.
   - Panels in `target_tiles` (Trend country line, Top-Countries) source **`master`** → the selected region.
2. **Point-in-time / "Top" measures must pin the period AND exclude rollup rows.** A raw `Sum([metric])` over an extract that carries region/aggregate rows AND all years yields "North America" (a region) at the top, summed across decades. Use a conditional:
   `Sum(If([Year] = <latestYearWithData> And Not IsNull([<entity-discriminator>]), [metric], null))`
   - `<entity-discriminator>` = a column that is null on aggregate rows (Metric Series: `Entity Group`; generally the dimension that only real leaf entities carry).
   - **FLAG-valued discriminator** — some extracts mark rollups by VALUE, not NULL (a flag column: `'Y'` rollup / `'N'` entity / sometimes NULL): IsNull can't express that. Declare png-read `point_in_time.rollup_flag {column, rollup_values[], entity_values[]}` and the condition becomes equality predicates instead: `([<flag>] = "N")` (entity_values, strict) or `(IsNull([<flag>]) Or Not ([<flag>] = "Y"))` (rollup_values only — NULL-flag rows kept).
   - `<latestYearWithData>` is **per metric** — verify against the landed data (Metric Series: REV/NFI = 2015, UNITS = 2014); don't assume the max year has data.
   - Field names here are caption-variant tolerant (UI caption / extract caption / landed physical all resolve); an unresolvable name is dropped LOUDLY with the master-column candidate list — never treat a silently-raw `Sum()` as acceptable.
3. **Top-Countries table is GROUPED** — `groupings:[{groupBy:[<entity>], sort:[{<measure> desc}]}]` + a `top-n` filter (`rowCount: 8`). Never emit it ungrouped (ungrouped → hundreds of raw rows).
4. **Selected-region highlight (not a filter) on the bars** — add a category column `If([New Region] = [ctl-param-region], "Selected region", "Other")` and `color: {by: category, column: <that col>, scheme: ["#c9d1d3", "#027b8e"]}` (grey / brand-teal). Bars `orientation: horizontal`, sorted by value desc.
5. **Trend = combo, Country vs World DUAL-AXIS** — Country line `Sum([metric])` on `yAxis` (rides `master`, follows the region filter); World line `Max([metric World])` on `yAxis2`, where `<metric> World` is a per-year global total. Dual axes match the source design: separate scales make the two lines TRACK each other (one shared axis pins the region line to the floor of the world total — an earlier revision of this recipe collapsed the axes and lost the source's reading). Raw 15-digit ticks are prevented by the SI column formats (`,.3~s`) on BOTH measures, not by collapsing axes. **Scope the World total to real entities** (`… WHERE <discriminator> IS NOT NULL`; with a `rollup_flag` declared, the WHERE becomes `"<FLAG>" IN (<entity_values>)` / `("<FLAG>" NOT IN (<rollup_values>) OR "<FLAG>" IS NULL)`) or it double-counts rollup rows and comes out ~10x high. An unresolvable discriminator/flag column is a LOUD banner with the landed-column candidate list — a silently-omitted WHERE is the run-2 failure mode. **Trim trailing no-data years** — a row-level `IsNotNull([metric])` bool filter (helper column + `list include:[true]`) ends each trend at its metric's last real year instead of a cliff to 0. No per-point `dataLabel`; integer Year x-axis (not a DateTrunc datetime).
6. **Bars + tables presentation:** bars `orientation: horizontal`, **sort by the VALUE column desc** (not the category name), no `dataLabel`, SI format; Top-N tables drop the passthrough Date column (+ its filter) and use SI format.

Reference implementation: session-1 `gen_wb_spec.py` (Metric Series). This recipe is the acceptance target for that class of dashboard.

## Layout composition (RCF hand-pass — multi-panel dashboards)

The one-shot layout builder is geometry-derived: it preserves the source's margins/gaps, so a mechanically-correct dashboard can still read "loose" (dead vertical space, bands floating above their charts, panels un-carded). These are `layout`/`spec` deltas the **Phase-5g RCF agent** fixes from the render — author a corrected `layout` XML (a `layout` key in the apply-patch REPLACES the whole XML; "layout-preserving" is only the default) + spec style patches, PUT, re-lint, loop. Target the clean reference:

- **Contiguous rows, no dead space** — each section-header band row sits directly above its chart row (`band gridRow="R/R+2"`, charts `gridRow="R+2/…"`), no empty rows between control→bands→charts. Collapse the geometry gaps rather than preserving them.
- **Bands aligned to their chart columns** — each header band's `gridColumn` equals the chart column beneath it (e.g. cols `1/9`, `9/17`, `17/25`), thin (~2 rows), flat tint (`backgroundColor` no border), label middle-aligned. One band must not span two chart columns.
- **Charts start at column 1** — no left gutter/indent; the grid fills `1/25`.
- **Card each panel** — wrap/style each chart with a surface (`style.{backgroundColor:'#FFFFFF', borderColor, borderWidth, borderRadius:'round'}`); set the chart's own `style.backgroundColor:'#00000000'` if it sits over a tint.
- **Semantic panel titles** — set each element's `name` to `<Metric> <SECTION>` ("REV YEAR ON YEAR" / "REV TREND" / "REV TOP ACCOUNTS"), not the raw worksheet nickname ("RevPie" / "RevRegionLine").
- **In-place PUT (`--reuse-workbook`) carries STALE layout elements** — `layout-preserve` merges the live layout, so a header/band element the *new* spec dropped (e.g. a prior page-name H1) LINGERS. When updating in place, the RCF patch must explicitly DROP the stale layout elements (author the full corrected `layout` XML without them), or the fix won't show. (A fresh POST wouldn't have the residual — this is an in-place-update-only trap.)

## Infographic recipe pack (long-scroll analytical posters — field-derived 2026-07-10)

Three shapes the generic build gets wrong on this dashboard class; all three are
POST-verified. Use them when the shape-identity gate (9b) fails a tile.

1. **Ranked bar-table** (source: rank + row label + one BAR COLUMN per category, printed %,
   ranks 1–N) → a `pivot-table`, NOT a grouped bar chart: `rowsBy` the ranked label (pre-sorted
   by rank), `columnsBy` the category, one measure with `conditionalFormats:
   [{type: dataBars, columnIds: [<measure>], scheme: [...]}]` + `includeValues: true`. Grouped
   bars scramble rank order and lose the table reading — a real run shipped that and failed the
   owner's eye while every value matched.

2. **Rank-limited pivot source** (source shows top-N of a HIGH-CARDINALITY dimension via a
   Tableau rank≤N table calc): the rank must live in the DATA, not the element — there is NO
   renderer-honored top-n filter on a pivot's `columnsBy` (two spec shapes verified
   accepted-then-500), and an unbounded pivot dimension at ~40k+ values kills every PNG export
   for the whole workbook. Land or derive a rank-limited source (Custom SQL:
   `QUALIFY RANK() OVER (ORDER BY <bias metric> DESC) <= N` per category) and point the pivot
   at it. Keep the raw table on the hidden Data page for interactivity/drill.

3. **Per-partition percentage cells** (heatmap cells that sum to 100% per row/column):
   `PercentOfTotal(agg, "column")` / `"row"` / `"parent_grouping"` — never `grand_total`
   (see refs/window-functions.md; a grand-total-only mapping mis-normalizes every cell).

Also: title art / stylized typography ship as **data-URI image elements** (see
refs/element-kinds.md "Image element" — extraction one-liner included; background layering
is impossible, composite instead), and element titles that leak worksheet names ("Sheet 9")
must be renamed to the source's visible caption — the source shows NO inner titles on most
infographic tiles, so match the element name to the section header or the tile's on-canvas title.
