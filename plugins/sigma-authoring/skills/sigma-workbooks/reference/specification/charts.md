# Charts

Chart elements: `line-chart`, `bar-chart`, `donut-chart`. This file is a **recipe book** for chart specs and the style choices that go with each kind. The OpenAPI is the source of truth for every field — chart schemas are inlined behind their `kind` discriminator, so fetch one by its kind:

```bash
# Swap `bar-chart` for any kind: line-chart, area-chart, combo-chart, scatter-chart, donut-chart, pie-chart
jq --arg k bar-chart 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

The field lists below are curated, not exhaustive — use the recipe above to discover the full shape of any field.

All three share the same skeleton: a `source`, a `columns` array, and axis/value pointers that reference column IDs. Formulas on a chart that sources another element must use the source's prefix (`[<SourceName>/col]`) — see `formulas.md`.

---

## Line chart (revenue over time)

```yaml
id: sales-over-time
kind: line-chart
name: Sales over time
source:
  kind: table
  elementId: sales-table
columns:
  - id: col-month
    name: Month
    formula: DateTrunc("month", [Master/Date])
    format:
      kind: datetime
      formatString: "%b %Y"
  - id: col-sales
    name: Sales
    formula: Sum([Master/Sales Amount])
    format:
      kind: number
      formatString: "$,.0f"
xAxis:
  columnId: col-month
yAxis:
  columnIds:
    - col-sales
```

- `xAxis` — single `{ columnId, sort?, format? }`
- `yAxis` — single `{ columnIds: [<colId>, ...], format? }`. On any cartesian chart, a `columnIds` entry may be an object `{ columnId, type }` (`type`: `bar` | `line` | `area` | `scatter`) to set that series' shape — most useful on `combo-chart`
- `xAxis.sort` shape: `{ by: <colId>, direction: ascending | descending }`
- Optional `format` on each axis configures title, labels, marks, and scale — it's inlined on `xAxis.format` / `yAxis.format`; inspect it via the kind recipe above rather than transcribing the whole object

## Bar chart (revenue by category)

Same axis shape as line-chart. Adds `stacking`.

```yaml
id: sales-by-region
kind: bar-chart
name: Sales by region
source:
  kind: table
  elementId: sales-table
columns:
  - id: col-region
    name: Region
    formula: "[Master/Store Region]"
  - id: col-sales
    name: Sales
    formula: Sum([Master/Sales Amount])
    format:
      kind: number
      formatString: "$,.0f"
xAxis:
  columnId: col-region
  sort:
    by: col-sales
    direction: descending
yAxis:
  columnIds:
    - col-sales
stacking: none
```

`stacking`: `none` | `stacked` | `normalized` (the percent-stacked variant — `"100"` is rejected by the API; live-verified 2026-06-11).

## Bar chart with custom category colors

> **Channel exclusivity:** a column can sit on **only one channel**. Putting the same column on both `color` and an axis (`yAxis`/`xAxis`) is a 400 — `Column 'X' is referenced from both 'yAxis' and 'color'; a column can only be on one channel at a time` (live-verified 2026-06-26 on `scatter-chart`). To color a chart *by its measure*, either drop `color` or add a **second column with the same formula** and bind that to `color` (same pattern as the donut `value`/`holeValue` rule below). To color by category, point `color` at the dimension column, not the measure.

`bar-chart` accepts an optional `color` channel with three variants:

```yaml
# Single fixed color
color:
  by: single
  value: "#3b82f6"

# One color per category (positional — see below)
color:
  by: category
  column: col-region
  scheme: ["#3b82f6", "#ef4444", "#10b981", "#f59e0b"]

# Continuous scale across a measure
color:
  by: scale
  column: col-sales
  scheme: ["#fef3c7", "#fbbf24", "#dc2626"]
  domain: { min: 0, max: 10000, mid: 5000 }   # `mid` is optional; its presence makes the gradient diverging, otherwise sequential
```

**Recipe — pin specific categories to specific colors:**

`scheme` is a **positional** array: Sigma assigns colors to categories in the order they appear on the axis, not by category name. To pin Electronics → blue, Apparel → red, Home → green, control the sort order alongside the color array:

```yaml
kind: bar-chart
name: Revenue by category
columns:
  - id: col-cat
    name: Category
    formula: "[Sales/Product Category]"
  - id: col-sales
    name: Revenue
    formula: Sum([Sales/Revenue])
    format:
      kind: number
      formatString: "$,.0f"
xAxis:
  columnId: col-cat
  sort:
    by: col-cat
    direction: ascending
yAxis:
  columnIds:
    - col-sales
color:
  by: category
  column: col-cat
  scheme: ["#3b82f6", "#ef4444", "#10b981"]
```

For category-by-name binding rather than position, use a derived column with an `If(...)` that emits the categories in a known order, then sort by that order.

## Donut

Uses `value` and `color` instead of `xAxis` / `yAxis`.

```yaml
id: sales-by-family
kind: donut-chart
name: Sales by product family
source:
  kind: table
  elementId: sales-table
columns:
  - id: col-family
    name: Family
    formula: "[Master/Product Family]"
  - id: col-sales
    name: Sales
    formula: Sum([Master/Sales Amount])
    format:
      kind: number
      formatString: "$,.0f"
value:
  columnId: col-sales
color:
  columnId: col-family
  sort:
    by: col-sales
    direction: descending
```

`holeValue` is optional. When set, it references one of the donut's columns by ID — that column's aggregated value drives the hole label/render — not a literal number. **It must be a different column than `value.columnId`** — a column can only sit on one channel at a time, and the API rejects the collision with a 400 (`Column 'X' is referenced from both 'value' and 'holeValue'`). For a center label that shows the same metric, add a second column with the same formula:

```yaml
holeValue:
  columnId: col-sales-hole    # distinct column, e.g. formula: Sum([Master/Sales Amount])
```

Donut/pie channel pointers use **`columnId`, not `id`**. `{ id: col-sales }` is a 400 (`Invalid kind: "donut-chart"` / `"pie-chart"`).

Related donut-only fields (all round-trip): `innerRadius` (hole size as a ratio of the outer radius, default 0.6) and `hole.value` styling (`fontWeight`, `color`, `visibility`) for the center label.

## Element-level filters (Top-N, etc.)

Charts take the same `filters` array as tables — the top-N example in `tables.md` applies to `bar-chart`, `line-chart`, and `donut-chart` without changes.

Top 10 regions by `Sales` on a bar chart:

```yaml
filters:
  - id: top-10
    columnId: col-sales
    kind: top-n
    rankingFunction: rank
    mode: top-n
    rowCount: 10
    includeNulls: when-no-value-is-selected
```

`rowCount` takes a number literal — it cannot be bound to a control (see `controls.md`, "Where Control Bindings Apply").

## Cartesian-only optional features

These apply to `bar-chart`, `line-chart`, `area-chart`, `scatter-chart`, and `combo-chart`. Use the kind recipe at the top of this file to read the full operator and styling enums for any of them.

### `refMarks` — reference lines and bands

```yaml
refMarks:
  - type: line
    axis: series              # axis = x-axis, series = primary y, series2 = secondary y
    value: { type: formula, formula: "Avg([Master/Sales])" }   # see value shape below
    line: { color: "#ef4444", width: 2 }
    label: { visibility: shown, text: "Threshold" }            # visibility REQUIRED
  - type: band
    axis: series
    value: { type: formula, formula: "800" }
    endValue: { type: formula, formula: "1200" }               # required for bands
```

> **`value` must be the wrapped object `{ type: formula, formula: "<expr>" }`** — verified live 2026-06-15. A bare number/string (`value: 1000`) and `{ type: static, value: 1000 }` are both rejected with the opaque `refMarks[0]: Invalid value: object`. A **constant** is expressed as a formula string, e.g. a 45% target line: `value: { type: formula, formula: "0.45" }`. `label.visibility` must be `shown` (omitting it, or `hidden`, also trips `Invalid value: object`).

### `trendlines` — regression overlays

```yaml
trendlines:
  - columnId: col-sales       # which series to fit
    model: linear             # linear | quadratic | polynomial | exponential | logarithmic | power
    line: { color: "#336699", width: 2 }
    label: { visibility: shown, text: "Sales trend" }
```

Trendlines are rejected when the chart has no `xAxis`, uses stacking on bar/area/combo, or has a `color` channel — discover those constraints by submitting and reading the error.

### `dataLabel` — value labels on marks

```yaml
dataLabel:
  labels: shown               # shown | hidden
  labelDisplay: all            # auto | minimum | maximum | min-max | all
  valueFormat: percent
  totals: { display: shown }
```

For `combo-chart`, optional `seriesDataLabel` is a map keyed by layer shape (`bar`, `line`, `area`, `scatter`) with per-shape overrides:

```yaml
seriesDataLabel:
  bar: { labelDisplay: maximum }
  line: { labelDisplay: all }
```

## Combo charts (mixed series + secondary axis)

A `combo-chart` mixes bar/line/area/scatter series on one plot. Set each series' shape with the `{ columnId, type }` form on `yAxis.columnIds`, and put series that need a different scale on the secondary axis `yAxis2`. **`yAxis2.columnIds` must be a subset of `yAxis.columnIds`** — list the column on both, with `yAxis2` marking which series render against the right axis (a `yAxis2` entry missing from `yAxis` is a 400: `'X' is not listed on yAxis.columnIds`):

```yaml
kind: combo-chart
xAxis:
  columnId: col-month
yAxis:                          # ALL series live here, each with its shape
  columnIds:
    - { columnId: col-revenue, type: bar }
    - { columnId: col-margin-pct, type: line }
yAxis2:                         # subset of yAxis.columnIds that renders on the right axis
  columnIds:
    - col-margin-pct
  format:
    visibility: shown           # set to `hidden` to hide the axis (no other fields on that branch)
```

Per-series styling:

- `seriesLineAreaStyle` — **list** of `{ columnId, style }` for line/area layers (not a map keyed by column id). Duplicate `columnId`s are rejected.
- `seriesPointStyle` — marker shape/size for points
- `seriesDataLabel` — per-shape data-label overrides (above)

```yaml
seriesLineAreaStyle:
  - columnId: col-margin-pct
    style:
      interpolation: monotone
```

Chart-wide fallbacks `barStyle`, `lineAreaStyle`, `pointStyle`, and `gap` also exist. Inspect the kind recipe for the full sub-field set of any of these.

### More cartesian options

Each of these is a top-level key on cartesian charts; one-liner here, full sub-fields via the kind recipe at the top of this file.

- `orientation: horizontal` on `bar-chart` — horizontal bars. Omit for the default vertical bars.
- `trellis: { rowsBy | columnsBy: [{ columnId }] }` — **native small multiples / faceting, authorable from spec** (see the "Trellis / small multiples" section below). This is the `rowsBy`/`columnsBy` form. Do NOT confuse it with the legacy `trellis: { column, row, share?, tileSize? }` *styling* object, which only styles a UI-configured trellis and whose facet `columnId`/`id` binding is silently stripped — use `rowsBy`/`columnsBy` to bind the facet from spec.
- `legend` — legend placement and styling (details below).
- `tooltip: { columnNames?, multiSeries?, valueFormat? }` — hover-tooltip content. Support is config-dependent (live-verified 2026-06-11): `columnNames` round-trips broadly; `multiSeries` round-trips on line charts but is silently stripped on bar-with-color; `valueFormat` is rejected or stripped in most configurations. Verify the readback after setting anything beyond `columnNames`.

(Trendlines and `refMarks` are covered above.)

### Legend controls

The legend has two branches. Hide it with exactly
`legend: {visibility: hidden}`. Otherwise configure `position`
(`auto`, edges, or corners), `color`, and `fontSize`; optionally hide the color
legend, size legend, or header independently:

```yaml
legend:
  position: bottom
  fontSize: 12
  color: "#475569"
  colorLegend: hidden
  sizeLegend: hidden
  header: hidden
```

Do not combine `visibility: hidden` with fields from the configured branch.

## Scatter

A `scatter-chart` is **measure-vs-measure**, one point per dimension value — fundamentally different from `bar-chart`. The trap (verified the hard way): if you put an aggregate measure (`Sum(...)`) directly on `xAxis`/`yAxis` of a scatter sourced from a flat table, Sigma's scatter axis is a *grouping* axis, so the aggregate evaluates **per row** and every point collapses to one x. A spec like this **POSTs cleanly but renders wrong** — POST success does NOT prove a correct scatter.

The correct shape binds the scatter to a **grouping**: source a table element that groups by the point dimension and pre-computes the x/y/(size) aggregates, then point the scatter at that grouping with `source.groupingId` and reference the grouped columns with raw refs. (Verified against a UI-built scatter, 2026-06-15.)

```yaml
# 1) a (hidden) grouped source table: one row per point dimension
- id: scatter-src
  kind: table
  name: Rep Performance            # unique name — raw refs resolve as [Rep Performance/Col]
  source: { kind: table, elementId: master }
  columns:
    - { id: g-rep, name: Sales Rep, formula: "[Data/Sales Rep Name]" }
    - { id: g-mpct, name: Margin %, formula: "(Sum([Data/Revenue])-Sum([Data/Cost]))/Sum([Data/Revenue])" }
    - { id: g-rev,  name: Revenue,  formula: "Sum([Data/Revenue])" }
    - { id: g-qty,  name: Quantity, formula: "Sum([Data/Quantity])" }
  groupings:
    - { id: grp-rep, groupBy: [g-rep], calculations: [g-mpct, g-rev, g-qty] }
  visibleAsSource: false
# 2) the scatter binds to that grouping; columns are RAW refs to the grouped values
- id: scatter
  kind: scatter-chart
  name: Sales vs Margin by Sales Rep
  source: { kind: table, elementId: scatter-src, groupingId: grp-rep }
  columns:
    - { id: s-rep,  formula: "[Rep Performance/Sales Rep]" }
    - { id: s-mpct, formula: "[Rep Performance/Margin %]" }
    - { id: s-rev,  formula: "[Rep Performance/Revenue]" }
    - { id: s-qty,  formula: "[Rep Performance/Quantity]" }
  xAxis: { columnId: s-mpct }       # x = a measure (Margin %)
  yAxis: { columnIds: [s-rev] }     # y = a measure (Revenue)
  color: { by: category, column: s-rep }   # point identity — one mark per rep
  size:  { columnId: s-qty }        # optional bubble size; pointers use `columnId`, not `id`
```

`color` always takes the `{ by: single|category|scale, column, ... }` form (see "Bar chart with custom category colors") — a bare `{ id }` / `{ columnId }` is rejected. **Validate a scatter by querying it for >1 distinct x**, not by POST status alone.

## Trellis / small multiples

A **trellis** (small multiples) repeats the same viz once per member of a categorical dimension. Sigma authors this natively from spec with the element-level `trellis` property — **ONE viz element**, the facet dimension added as a `columns[]` entry, and `rowsBy` / `columnsBy` pointing at that column by `columnId`. Do **not** clone one element per member.

```jsonc
{
  "id": "el-revenue-by-subregion",
  "kind": "bar-chart",
  "source": { "kind": "table", "elementId": "master" },
  "columns": [
    { "id": "c-cat", "name": "Region",     "formula": "[Master/Region]" },
    { "id": "c-x",   "name": "Sub-Region", "formula": "[Master/Sub-Region]" },
    { "id": "c-y",   "name": "Revenue",    "formula": "Sum([Master/Revenue])" }
  ],
  "xAxis": { "columnId": "c-x" },
  "yAxis": { "columnIds": ["c-y"] },
  "trellis": { "rowsBy": [ { "columnId": "c-cat" } ] }
}
```

With a 3-member `Region` (Region A / Region B / Region C), this renders one bar panel per region, stacked in rows.

- `rowsBy` alone → **vertical** small multiples (panels stacked in rows).
- `columnsBy` alone → **horizontal** small multiples (panels side by side).
- **both**, pointing at **two different** columns → a **2-D grid** (rows × columns).
- The facet reference key is **`columnId`** (a `columns[]` id on the element). Pivot-table `rowsBy`/`columnsBy` cross-tab shelves use the same `columnId` key — they are a different *mechanism* (shelves, not small-multiples), not a different pointer field.

### Supported chart kinds (emit `trellis` for these only)

The native `trellis` key round-trips (survives readback and renders faceted) on exactly these kinds:

| Kind | Trellis |
|------|---------|
| `bar-chart` (incl. `stacking: stacked` / `normalized`) | ✅ supported |
| `line-chart` | ✅ supported |
| `area-chart` | ✅ supported |
| `combo-chart` | ✅ supported |
| `scatter-chart` | ✅ key round-trips (validate the grouping/render separately — see the Scatter section) |
| `donut-chart` | ✅ supported (one donut per member) |
| `pie-chart` | ❌ **stripped** → emit a `donut-chart` instead |
| `kpi-chart` | ❌ stripped → fan out to N sibling KPI elements |
| `pivot-table` | ❌ stripped → use the pivot's own `rowsBy`/`columnsBy` shelves |
| `table` | ❌ stripped → keep flat / model the facet as a grouping |

The empirical coverage matrix (how each kind was verified live, POST + readback + render) is the source of truth: **`docs/sigma-trellis-chart-support.md`**.

### Fallbacks for the unsupported kinds

- **`pie-chart` → `donut-chart`.** Pie and donut are both circular (`value` + `color`), but only donut trellises. If the intent is a faceted pie, emit a `donut-chart` with the same `trellis`.
- **`kpi-chart` → N sibling KPIs.** There is no native KPI trellis. For "one KPI per category," lay out N separate `kpi-chart` elements, one filtered to each member.
- **`pivot-table` → its own shelves.** The pivot's element-level `rowsBy`/`columnsBy` cross-tab shelves (keyed on `columnId`) already are the native faceting — do not add a separate `trellis` key.
- **`table` → keep flat** or add the facet as an extra grouping/row dimension.

### ⚠️ Silent-stripping caveat — ALWAYS re-read and verify

Sigma returns **`200` on POST even for the unsupported kinds**, then **silently drops the `trellis` key** on readback and renders a single un-faceted chart — no error. **POST success is NOT proof the trellis applied.** Any spec that emits a native `trellis` must GET the workbook spec back after create and assert the element still carries its `trellis` key (with the same axis) before treating the trellis as applied; if it was stripped, fall back to the routes above. (Converters do this with a round-trip survival guard.)

## Other chart kinds

Per the OpenAPI, these are all valid `kind` values; documented examples for the most common are above. The shape mirrors the `bar-chart`/`line-chart` pattern (`source`, `columns`, `xAxis`, `yAxis`). Inspect any of them with the kind recipe at the top of this file:

- `area-chart`, `combo-chart` — same shape as `bar-chart`/`line-chart`, just a different `kind` (and `combo-chart` adds the series configs above).
- `scatter-chart` — **NOT the same as bar-chart.** It is measure-vs-measure with the dimension as the point identity, and it must bind to a **grouping** or every point collapses to one x. See the Scatter section below.
- `pie-chart` — like `donut-chart` (`value` + `color`), but without the donut-only `hole` / `holeValue` / `innerRadius` / `trellis` keys.
- `pivot-table` — uses `values` instead of `yAxis`; useful for cross-tab analysis. See `tables.md`.
- `waterfall-chart` — same `source`/`columns`/`xAxis`/`yAxis` skeleton as `bar-chart`, plus running-total fields (`startPoint`, `splitBy`, `grouping`, `waterfallColors`, `waterfallShape`). **Gotcha (live-verified 2026-08-03, re-confirmed 2026-08-04 against the corrected `document`-wrapped request body):** `waterfallShape.subtotal`/`endTotal` reject with a 400 unless the chart has `splitBy` or 2+ `yAxis.columnIds` — reproduces exactly as documented; `visibility: shown`/`hidden` are not the issue (both 400 identically without the escape hatch, both pass with it).

### Waterfall

`waterfall-chart` is a first-class OpenAPI element kind. Its shared chart
surface includes `source`, `columns`, axes, legend, tooltip, labels, filters,
style, and reference marks. Waterfall-specific fields are:

- `startPoint` — starting bar/anchor configuration;
- `splitBy` — separates the running series;
- `grouping` — subtotal grouping behavior;
- `waterfallColors` — increase/decrease/total colors;
- `waterfallShape` — subtotal/end-total visibility and shape;
- `color` — waterfall color channel.

Pull the live sub-schemas before authoring because these are tagged/nested
objects, not free-form styling. Preserve the existing restriction:
`waterfallShape.subtotal`/`endTotal` require `splitBy` or multiple y-series.

### Box charts: unsupported/pending

Do not emit a box plot/box-and-whisker element. The live workbook OpenAPI has
no `box-chart` element kind. Keep requests for one pending or use an explicitly
approved alternative; do not infer support from UI concepts or stale docs.

For element-level reference of `kind: "text"` (free-form Markdown blocks), see `content-elements.md`.

---

## Natively supported chart kinds that converters still degrade (verified live 2026-08-26)

**treemap, sankey, funnel, gauge and box charts are NATIVE.** Several converters
still route them to a plugin, to a `bar-chart`, or drop them outright, on the
belief that Sigma has no equivalent. That belief is out of date. Each shape below
was confirmed against a real org via `POST /v2/workbooks/spec/verify`, and
`treemap-chart` additionally via a real create + spec readback.

| kind | required beyond `id`/`kind`/`source`/`columns` | shape |
|---|---|---|
| `treemap-chart` | `category` | `category: {columnId: <dim col>}` |
| `gauge-chart`   | `value`    | `value: {columnId: <measure col>}` |
| `sankey-chart`  | `stages`, `value` | `stages: [{columnId: <dim col>}]`, `value: {columnId: <measure col>}` |
| `funnel-chart`  | `stage`, `series` | `stage: {columnId: <dim col>}`, `series: {columnId: <measure col>}` |
| `box-chart`     | `yAxis`    | `yAxis: {columnIds: [<measure col>]}` |

```yaml
# live-verified: {"valid": true}, created, and read back intact
- id: tm
  kind: treemap-chart
  source: { kind: data-model, dataModelId: <dm>, elementId: <el> }
  columns:
    - { id: cDim, formula: '[Master/Category]' }
    - { id: cMea, formula: 'Sum([Master/Revenue])' }
  category: { columnId: cDim }  # the ONLY pointer treemap accepts (`id` is a 400)
```

### Three traps, all found by probing rather than reading

**1. `treemap-chart` rejects `value` and silently DROPS `size`.** The API's own
error says *"at least one of category or value is required"*, but sending `value`
returns `Invalid kind: "treemap-chart"`. And `size` is accepted at create then
absent from the readback — a classic silent drop. `category` is the only pointer
that both validates and persists; sizing comes from the measure in `columns`.
Assert the readback, not the status code.

**2. `Invalid kind: "X"` does NOT mean the kind is unsupported.** It is a
mislabeled UNION failure: `bar-chart`, unambiguously valid, returns the identical
error the moment any sibling property has the wrong type. Four kinds read as
"unsupported" purely because the probe sent `value: "cA"` where the schema wants
`value: {columnId: "cA"}`. To test whether a kind exists, satisfy its required
properties first, then A/B against a known-good kind with the SAME body shape.

**3. The OpenAPI under-documents these kinds.** `treemap-chart`'s union member
lists only `columns`/`id`/`kind`/`source` — `category` appears nowhere, yet it is
required in practice. `donut-chart` is likewise absent from the asset's `kind`
list despite being a real, working chart. So the asset is authoritative for what
EXISTS but not always for what a kind ACCEPTS; probe before trusting a field list.

### Converters still carrying the stale assumption

Re-routing these needs the builder to emit the per-kind pointer above, not just a
different `kind` token — swapping the token alone ships a `treemap-chart` carrying
bar-chart axis props, which is invalid. Tracked as follow-up work:

- `domo-to-sigma` — `badge_treemap` -> `bar-chart` + top-500 filter, listed in
  `NO_NATIVE_EQUIVALENT` ("no treemap `kind` was found").
- `powerbi-to-sigma` — `refs/catalogs/viz-kind.json`: `treemap`/`funnel` fold into
  the `bar` row; `sankeyDiagram` sits in the `unsupported` row (`sigma: null`), so
  it is **dropped entirely**; `gauge` -> `progress` with `shape: ring`.
- `tableau-to-sigma` / `powerbi-to-sigma` — `test-coverage-gate.rb` still states
  "Sigma has no native gauge".
- `quicksight-to-sigma` — `build-workbook-from-quicksight.rb` comment still says
  "There is NO native histogram, heat-map, treemap, box-plot". Histogram and
  heat-map remain true; treemap and box-plot do not.
