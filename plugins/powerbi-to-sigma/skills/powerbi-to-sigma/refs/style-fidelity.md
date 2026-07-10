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
A PBI card renders a big value in the theme accent with a gray caption **below** it.
The KPI emit reproduces that: `value.color` = `rec['value_color']` (or the palette
accent), `name` = `{text, color:{kind:theme, ref:colors-textNeutral}}`, and
`layout.titleOrient: bottom`.

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

## 5. Number "K"/thousands — known approximation (NOT auto-transformed)
PBI "display units: Thousands, 0 dp" (`$121K`, `$8K`) is **fixed** thousands scaling.
Sigma's compact `formatString` uses d3 `s` = **significant figures**, so:
- `$,.2s` renders `$121,347` → `$120K` (2 sig figs drops the 1) and `$8,358` → `$8.4K`.
- No d3 `formatString` reproduces PBI's whole-thousands-K across all magnitudes.

The exact match is a display hack — divide the measure by 1000 and add a literal `K`
suffix (`Sum(...)/1000`, `format: {prefix:"$", suffix:"K", formatString:",.0f"}` →
`$121K`). It changes the value's semantics (now in thousands), so the converter does
**not** apply it silently — it emits the standard format and this is the documented
gotcha. Apply the hack per-KPI in the UI if a pixel match is required.

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
