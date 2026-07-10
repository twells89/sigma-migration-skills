# Style fidelity — reproducing the PBI report's *look* in Sigma

The converter has always reproduced **data + layout**; this ref covers the **visual
style** layer that used to be dropped (so a migrated workbook read as "the right
charts, plain"). Everything here is derived from the report's PBIR — the extractor
captures the signals, the builder emits the Sigma equivalents. No UI editing.

## What's captured (extract-pbir.py)

| Signal | PBIR source | Field on the record |
|---|---|---|
| Report theme name | `definition/report.json` → `themeCollection.baseTheme.name` (e.g. `CY24SU10`) | top-level `signals['theme']` |
| Card value color | card visual `objects.labels[].properties.color` | `rec['value_color']` |
| Matrix/tableEx totals | matrix/tableEx default (honor explicit `total.show=false`) | `rec['show_totals']` |
| Data-label toggle | `objects.labels.show` | `rec['data_labels']` (pre-existing) |
| Number display units | `objects.labels/callout[].properties.labelDisplayUnits` (absent ⇒ PBI default `Auto`) | `rec['display_units']` (`auto`/`none`/`thousands`/…) |
| Card callout alignment | `objects.callout/labels[].properties.alignment` | `rec['value_align']` |

## What's emitted (build-workbook-from-pbir.rb)

### 1. Workbook theme (`lib/pbi_theme.rb`)
Every PBI migration emits a top-level `themeName: Light` + `themeOverrides`:
`hasCards: shown` (card chrome), `elementBorder` (subtle 1px), `borderRadius: round`,
and `categoricalScheme` = the report theme's **data-color sequence**. The palette
**order matters** — Sigma assigns `scheme[i]` to the i-th category/series exactly as
PBI colors by legend order, so donut/pie slices and multi-series charts line up.
`colors.highlight` = `scheme[0]` colors single-series charts (line, single-measure bar).
Unknown/absent theme → PBI's current default (`CY24SU10`).

### 2. KPI card fidelity
A PBI card renders a big value in the theme accent with a gray caption **below** it,
**centered** in the card. The KPI emit reproduces that: `value.color` =
`rec['value_color']` (or the palette accent), `name` = `{text, color:{kind:theme,
ref:colors-textNeutral}}`, `layout.titleOrient: bottom`, and `layout.anchor`
(centered by default — see §6). All handled by `lib/pbi_style.rb`.

### 3. Pivot grand totals
PBI matrices/tableEx show a **Grand Total** row by default. A grouped Sigma `table`
**cannot** render one, but a `pivot-table` can — so when `rec['show_totals']` is set,
a single/multi-dimension grouped table is **re-expressed as a pivot-table**
(`rowsBy`=dims, `values`=measures) with `totals: {showGrandTotals: shown,
grandTotalFontWeight: bold, totalPosition: last}`. Ratio measures (`Sum/Sum`) total
correctly because the pivot recomputes them at the total level (not a naive average).

### 3b. Donut/pie label style (percent-of-total)
PBI's pie/donut detail-label style (`objects.labels.labelStyle`, e.g. "Category,
percent of total") is captured as `rec['label_style']` and mapped to the donut
`dataLabel.labelDisplay` (`color-percent` / `percent` / `color-value`), with
`precision: 1` for percent modes — so a percent-of-total donut migrates as `%`, not
raw `$`. Only emitted when PBI named a style (absent → value labels, as before).

### 4. Donut/pie null → `(Blank)` (color-order fix)
PBI labels a null slice `(Blank)` and sorts it **first**, so its color lands on
`scheme[0]`. Sigma sorts null **last**, which misaligns the whole palette on
donut/pie (per-element `color.scheme` is silently dropped there — the workbook
`categoricalScheme` is the only lever). The donut emit wraps a bare dimension ref as
`Coalesce([dim], "(Blank)")`, which both matches PBI's label and sorts ahead of
letters (`(` < `A`) — so every slice gets the color PBI gave it.

## 5. Number abbreviation ("K"/"M") — now auto-emitted (`lib/pbi_style.rb`)
PBI cards and charts default to **display units "Auto"**, which abbreviates large
values (`$126K`, `$1.2M`). PBI *serializes `labelDisplayUnits` only when non-default*,
so an **absent** signal means Auto ⇒ abbreviate. The builder honors this:

- `rec['display_units']` absent (`nil`) or anything but `none` → **abbreviate** the
  element's **measure** columns; explicit `none` → keep full precision.
- **KPI** value columns → `$,.3s` (3 sig figs keeps a 6-digit value honest:
  `$125,916` → `$126k`, not `$130k`). **Chart** data labels → `$,.2s` (denser).
- Currency `$` prefix is preserved; **percents/ratios are never abbreviated**
  (`.1%` untouched, and an *unformatted* ratio like a bare YoY% is left alone —
  abbreviating `0.26` → `260m` would be wrong).
- An unformatted **sibling** measure (e.g. a "Prior Year" column with no format)
  inherits the element's currency so it abbreviates consistently with its peers.
- **Tables keep full precision** — PBI matrices/tableEx show full numbers
  (`$17,581`), so `table`/`pivot-table` measure columns are **not** abbreviated.

**Known approximation (irreducible via `formatString`):** Sigma's compact format is
d3 `s` notation — **lowercase** `k`/`M` and **significant-figures** based, so it can't
reproduce PBI's *uppercase whole-thousands* exactly (`$84,760` → `$84.8k`, where PBI
shows `$85K`). The only exact match is the divide-by-1000 + literal-`K`-suffix hack,
which changes the value's semantics (now stored in thousands) and breaks tooltips/axes
— so the builder emits the honest `s` format and this residual is documented, not
silently hacked. (Prior versions skipped abbreviation entirely; the compact `s` form
is a strictly closer match and is now the default.)

## 6. KPI card alignment (`layout.anchor`)
PBI stat cards center their callout. The KPI emit sets `layout.anchor` from
`rec['value_align']` (`left`→`start`, `right`→`end`, `center`→`middle`), defaulting to
**`middle`** when PBI didn't specify — centered stat cards are the house default for
migrations and match the common PBI card look. Set an explicit PBI alignment to
override. (`PbiStyle.kpi_anchor`.)

## 7. Presentation table style (`tableStyle`)
PBI matrices/tableEx read as roomy, lightly-ruled "presentation" tables, not Sigma's
dense spreadsheet grid. Every migrated `table`/`pivot-table` gets
`tableStyle: {preset: presentation, cellSpacing: medium, gridLines: horizontal,
banding: shown}` (does not clobber an explicitly-set style).
(`PbiStyle.presentation_table!`.)

## 8. Other PBIR-derived formats — roadmap (what else the report file carries)
The PBIR encodes more visual style than we port today. Prioritized by value ×
reliability (all mechanical reads of `visual.objects[...].properties`):

| Signal | PBIR source | Sigma target | Status |
|---|---|---|---|
| Decimal precision | `labelPrecision` | `formatString` `.Nf` decimals | planned |
| Legend position | `legend.position` (`Top`/`Right`/…) | chart legend `position` | planned (`show` already ported) |
| Axis titles / visibility | `categoryAxis/valueAxis.showAxisTitle`, `.titleText`, `.show` | chart axis `title`, `visibility` | planned |
| Explicit series colors | `dataPoint[].properties.fill` per series | `color.scheme` (bar/line/combo) | partial (theme palette by order) |
| Title font / size / color | `title.properties.{fontSize,fontColor,alignment}` | element `titleFont` / `themeOverrides.titleFont` | planned |
| Y-axis gridlines | `valueAxis.gridlineShow` | chart gridlines | planned |
| Negative-number / currency-symbol / separators | number-format structured props | `format` structured fields (`prefix`,`currencySymbol`,…) | planned |
| Total label / subtotal toggles | matrix `subTotals`, `total.label` | pivot `totals` | partial |
| Page/canvas background | `section.objects.background` | `themeOverrides.colorOverrides.backgroundCanvas` | planned |

Conditional formatting (background/font scales, rules, data bars) is **already**
ported (`rec['conditional_formats']` → Sigma `conditionalFormats`).

## 9. Recovering style the PBIR omits — the PNG fallback
Some style never reaches the PBIR: it's a **theme default** PBI doesn't serialize
(the `$126K` abbreviation is exactly this — `labelDisplayUnits` was absent), a
report-theme JSON we can't resolve to hex, or an org theme applied at view time. When
a signal is absent, the **source render** is ground truth. The Phase-5e compare
already exports the PBI pages (`export-pbi-pages.py`, PNG→PDF fallback); that image
can also be **sampled** to recover style the file dropped:

| Recover from PNG | How | Feeds |
|---|---|---|
| KPI accent / series palette (hex) | sample dominant non-neutral pixels in each KPI value / chart mark region | `value.color`, `themeOverrides.categoricalScheme` |
| Whether values are abbreviated + case | OCR/needle a KPI tile: does it read `$126K` vs `$125,916`? | confirm `display_units` when `nil` |
| Value/label alignment | centroid of the value text within its card bbox | `layout.anchor` |
| Data-label / legend presence | detect label glyphs / legend swatches in the render | confirm `data_labels`/`legend` when `nil` |

Design: a `pbi-style-from-png.py` enrichment that runs **only when the PBIR signal is
`nil`** and a source render exists — it never overrides an explicit PBIR value, and it
degrades to the documented defaults when no render is available (as here: this
tenant's `ExportToFile` 404s, so we relied on the `nil`→abbreviate/centered defaults).
**Not yet implemented** — the color path (sampling the KPI accent + categorical
palette) is the highest-value first cut, since theme-hex is the least reliable PBIR
signal.

## 6. Conditional formatting (table / matrix)
PBI table & matrix conditional formatting (`objects.values[]` backColor/fontColor +
`objects.columnFormatting[]` dataBars, each scoped by `selector.metadata` = the
target column queryRef) is captured by `extract-pbir.py` (`_conditional_formats`)
as `rec['conditional_formats']` and emitted by `build-workbook-from-pbir.rb` via
`lib/pbi_conditional_formats.rb` as element-level Sigma `conditionalFormats`.
Grammar confirmed against real PBIR (a Fabric round-trip + Microsoft BCApps /
fabric-toolbox reports); the Sigma output was POSTed + rendered live (backgroundScale
white→blue, fontScale red→green, in-cell dataBars, and rules→single red/yellow/green
threshold banding — verified 2026-07-10). PBI serializes color scales as a
`FillRule` (`linearGradient2/3`), rules as a `Conditional`/`Cases` expression, and
data bars under a separate `columnFormatting[]` key.

| PBI mode | PBIR shape | Sigma `conditionalFormats` |
|---|---|---|
| Color scale — background | `values[].backColor…FillRule.FillRule.linearGradient2/3` | `type: backgroundScale`, `columnIds`, `scheme` (min[,mid],max) |
| Color scale — font | `values[].fontColor…linearGradient2/3` | `type: fontScale`, `columnIds`, `scheme` |
| Data bars | `columnFormatting[].dataBars.{positiveColor,negativeColor}` | `type: dataBars`, `columnIds`, `scheme` = `[negative, positive]` |
| Rules / thresholds | `values[].…expr.Conditional.Cases[]` — each `{Condition (Comparison / And-range), Value(color)}` | one `type: single` per band: a single comparison → native `condition` (`=` `!=` `>` `>=` `<` `<=`) + `value`; a two-sided And-range → `condition: formula` `"[Col] >= lo and [Col] < hi"`. Cross-column, compound (Or/nested), and else-`Default` cases → coverage |
| **Field value** (a DAX measure returns the hex) | `values[].backColor…expr.Measure` (no FillRule/Conditional) | **coverage** (`approximated`, recoverable) — the measure lives in the model, not the report; re-create as a `formula`-condition `single` once translated |

Notes: (1) the CF target (`selector.metadata`) is entity-qualified, so the emitter
resolves it to a built column id by exact match then a **leaf-name** fallback.
(2) Sigma data bars are **sign-colored** (negative/positive), not a value gradient
— for a value gradient over a column use a color scale (`backgroundScale`), see
`sigma-workbooks/reference/specification/tables.md`. (3) A CF whose target column
isn't in the migrated table, and the two non-mappable modes, are recorded to
`coverage.json` — CF is **never silently dropped**. Regression:
`scripts/test-conditional-formats.rb` (+ real fixtures under
`fixtures/conditional_formats/`).

## Verification
- `theme: CY24SU10`, card `value_color: #118DFF`, tableEx `show_totals: True` round-trip
  through `extract-pbir.py` (live-checked against the Retail Performance & Trends report).
- Cold builder run emits `themeName`/`themeOverrides` (CY24SU10 palette), KPI
  `value.color`+`titleOrient`, donut `Coalesce(..., "(Blank)")`, and the tableEx→pivot
  totals re-expression — 0 dropped/degraded in coverage.
- §5–§7 (`lib/pbi_style.rb`): `scripts/test-pbi-style.rb` (26 assertions, offline)
  pins the abbreviation/anchor/presentation logic. Live-verified on the Retail
  Performance & Trends workbook (2026-07-10): KPIs render `$126k` / `$84.8k` centered,
  chart labels `$37k`/`$49k`, and the Region table in the presentation preset — matching
  the PBI source (POST → `GET /spec` round-trip → PNG export compared to the source).
