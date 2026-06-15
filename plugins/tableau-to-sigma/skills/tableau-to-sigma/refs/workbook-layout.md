# Workbook Layout Reference

> **Spec shape lives in `sigma-workbooks`.** This file is Tableau-conversion-specific: Ruby layout generation, multi-series chart patterns, dashboard-translation idioms. For the canonical workbook spec shape (element kinds, sources, controls, formulas, formatting), read the `sigma-workbooks` skill's `reference/specification/`. Treat that as the source of truth — when this file disagrees, the sigma-workbooks reference wins.

Layout is always generated with Ruby. Never hand-write layout XML.

## Grid system

Sigma uses a 24-column CSS grid. Rows are numbered from 1 and use span-style notation:
- `gridColumn="1 / 25"` — full width (columns 1 through 24)
- `gridColumn="1 / 13"` — left half
- `gridColumn="13 / 25"` — right half
- `gridRow="1 / 7"` — rows 1 through 6 (6 units tall)

Row heights are relative units (auto). KPIs are ~6 units tall, charts 12-18 units.

## Layout XML structure

The layout is a **single top-level field on the workbook spec** — NOT a per-page field.
It is one XML string containing all pages concatenated, each identified by the server-assigned page ID.

```json
{
  "name": "My Workbook",
  "layout": "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Page type=\"grid\" ...>...</Page>\n<Page ...>...</Page>",
  "pages": [
    {"id": "Hn2bYOjeRL", "name": "Overview", "elements": [...]},
    {"id": "gAPPHE3kaD", "name": "Product",  "elements": [...]}
  ]
}
```

**Critical:** Do NOT set `layout` on individual page objects. The API silently ignores per-page
layout fields — the workbook will appear unstyled even though PUT returns `success: true`.
Strip any `layout` key from page objects before writing the PUT body.

### Page tag — required attributes

Each page in the layout XML must use this exact format, with the server-assigned page `id`:

```xml
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="Hn2bYOjeRL">
  ...
</Page>
```

A bare `<Page>` tag without `type`, `gridTemplateColumns`, `gridTemplateRows`, and `id` is ignored.

### LayoutElement — for plain elements (charts, tables, KPIs)

```xml
<LayoutElement elementId="abc123" gridColumn="1 / 25" gridRow="1 / 7"/>
```

### GridContainer — for container elements that wrap children

```xml
<GridContainer elementId="container-id" type="grid"
  gridColumn="1 / 25" gridRow="1 / 9"
  gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <LayoutElement elementId="kpi-1-id" gridColumn="1 / 7" gridRow="1 / 9"/>
  <LayoutElement elementId="kpi-2-id" gridColumn="7 / 13" gridRow="1 / 9"/>
  <LayoutElement elementId="kpi-3-id" gridColumn="13 / 19" gridRow="1 / 9"/>
  <LayoutElement elementId="kpi-4-id" gridColumn="19 / 25" gridRow="1 / 9"/>
</GridContainer>
```

**Critical:** Container elements MUST use `<GridContainer>`, not `<LayoutElement type="grid">`.
Using `<LayoutElement>` for a container causes empty containers to appear in the published workbook.

**Critical — inner KPI row spans must match the container outer span.** `gridTemplateRows="auto"`
does NOT fill available container height — rows size to content minimum. A KPI at `gridRow="1 / 2"`
inside an 8-row container renders as a tiny sliver with truncated names. Always set the inner
`gridRow` end value equal to the container's outer end value (e.g., container at `1 / 9` → KPIs
at `1 / 9`).

## Ruby helpers

```ruby
require 'yaml'
require 'date'
require 'json'

def gc(eid, c0, c1, r0, r1, inner)
  "<GridContainer elementId=\"#{eid}\" type=\"grid\" " \
  "gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\" " \
  "gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\">\n#{inner}\n</GridContainer>"
end

def le(eid, c0, c1, r0, r1)
  "  <LayoutElement elementId=\"#{eid}\" gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\"/>"
end

# page_id is the server-assigned page ID (e.g. "Hn2bYOjeRL"), NOT the page name
def page_xml(page_id, *children)
  header = "<Page type=\"grid\" gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\" id=\"#{page_id}\">"
  [header, *children, "</Page>"].join("\n")
end
```

## Reading the .twb dashboard layout

Run `scripts/parse-twb-layout.rb` on `workbook-content.twb` (from PAT-mode Phase 1)
to get a per-zone JSON. Each chart zone surfaces:

| Field | Source | Use for |
|---|---|---|
| `caption` | zone `name` attr | element name in the Sigma spec |
| `x_pct` / `y_pct` / `w_pct` / `h_pct` | zone position | layout XML `gridColumn` / `gridRow` |
| `chart_kind` | worksheet `<mark class="…">` + Rows/Cols shelves | Sigma element `kind` (bar / line / pie / region-map / point-map / scatter / **pivot-table** / **table** / automatic). Text/Square mark with dims on BOTH shelves ⇒ `pivot-table`; one shelf only ⇒ `table` |
| `rows_shelf` / `cols_shelf` | worksheet `<rows>` / `<cols>` | Structured shelf summary: `{ fields: [...], dim_count, measure_count, has_measure_names }`. Drives the pivot-table vs flat-table decision. `fields[].role` ∈ `dim` / `measure` / `measure-names`; `fields[].guid` resolves to a column caption via `columns_by_guid` in `<dashboard-layout-meta>.json` |
| `is_crosstab` | derived | Convenience boolean — true when `chart_kind` came out as `pivot-table` |
| `sort` | worksheet `<sort>` element | bar/line `xAxis.sort` — **only set the Sigma sort when this is non-null**; if Tableau has no explicit sort, leave the xAxis unsorted so Sigma uses natural order (alphabetical / chronological) |
| `filters` | worksheet `<filter>` elements | Phase 2.5 candidates. Note: `[Action (Foo)]` filters are dashboard cross-filter actions, not value filters — usually skip these |
| `aggregations` | `<column-instance derivation="…">` per column | the agent's truth source for measure aggregation. `Sum` is default for measures; `Avg` / `Min` / `Max` / `Median` / `CountD` are explicit overrides → use the matching Sigma aggregator. `Month-Trunc` / `Year-Trunc` / `Day-Trunc` → wrap the column with `DateTrunc("month", …)` etc. in the chart formula |
| `channels` | worksheet `<encodings>` block | color/size/detail/label channel assignments. A `color` channel with a categorical column = multi-series — use the `If([…] = "Foo", …, Null)` pattern per category. Without this, single-dim bar/line charts get built where Tableau actually had stacked or color-broken-out series |
| `mark_class` | raw `<mark class="…">` | fallback context when `chart_kind: automatic` — agent reads the PNG to decide |
| `geo_role` | column `semantic-role` attr | `regionType` mapping for `region-map` (see "Tableau geographic role → Sigma regionType" below) |

This is more reliable than inferring chart type from the view CSV.

### Zone `kind` values (zone-level type-v2)

| Zone `kind` | Tableau type-v2 | Map to Sigma element |
|---|---|---|
| `chart` | (no type-v2, has worksheet name) | A chart element — use `chart_kind` field for kind |
| `title` | `title` | `text` element with `body: "## <Dashboard name>"` |
| `text` | `text` | `text` element (free annotation) |
| `filter` | `filter` | `control` element on the master table (list / date-range / etc.) |
| `parameter` | `paramctrl` | `control` of `controlType: "segmented"` or `number` / `slider` |
| `legend` | `color` | Usually automatic in Sigma — drop unless explicitly free-floating |
| `spacer` | `empty` | Leave the grid range empty (no Sigma element) |
| `container` | `layout-basic` / `layout-flow` | Pure layout — only affects grid spans, no Sigma element |
| `dashboard-object` | `dashboard-object` | Generic — usually an `image` element |

### `chart_kind` values (chart-tile level, from `<mark class="...">`)

| `chart_kind` | Tableau mark | Sigma element `kind` |
|---|---|---|
| `bar` | `Bar` | `bar-chart` |
| `line` | `Line` | `line-chart` |
| `area` | `Area` | `area-chart` |
| `pie` | `Pie` | `pie-chart` |
| `scatter` | `Circle` / `Shape` | `scatter-chart` |
| `pivot-table` | `Square` / `Text` **with dims on BOTH Rows AND Cols shelves** (or Measure-Names crosstab) | `pivot-table` (emit `rowsBy` / `columnsBy` / `values`) |
| `table` | `Square` / `Text` with dims on ONE shelf only (flat detail list) | `table` |
| `map-region` | `Multipolygon` / `Polygon` / `Filled` / `Map` / has `<geometry>` | `region-map` |
| `map-point` | (has `Latitude` + `Longitude` columns) | `point-map` |
| `automatic` | `Automatic` | **Verify visually** — Tableau picks the default for the encodings; usually bar but not deterministic |
| `other` | unknown / unhandled | Open the dashboard PNG and decide manually |

> **`automatic` is not a Sigma kind.** When the parser emits `chart_kind: automatic`, fetch the dashboard view image, look at the tile, and pick the right Sigma kind. Tableau's "Automatic" mark adapts to whatever the worksheet's encodings imply — there's no deterministic mapping.

> **Pivot tables vs flat tables — don't downgrade a crosstab.** A Tableau crosstab (mark `Text` or `Square` with dimensions on BOTH Rows AND Cols shelves) MUST become a Sigma `pivot-table`, not a `table`. The parser decides via `dim_count` on each shelf: ≥1 real dim on both ⇒ `chart_kind: pivot-table`. The Measure-Names pattern (one dim shelf + Measure Names placeholder on the other + ≥2 measures on the worksheet) also resolves to `pivot-table`. A flat Text-mark detail list (dims on Rows only, nothing on Cols) stays as `chart_kind: table`. If you see a Tableau crosstab landing in Sigma as a plain table, the regression is upstream — inspect `rows_shelf` / `cols_shelf` on the zone JSON; the `is_crosstab` flag is the canonical signal.

### Percent (Tableau .twb) → Sigma 24-col grid

The parser emits `x_pct`, `y_pct`, `w_pct`, `h_pct` in percent of dashboard.
Convert to Sigma grid spans:

| Tableau % range | Sigma cols (24-col grid) |
|---|---|
| 0 – 25% | `1 / 7` |
| 25 – 50% | `7 / 13` |
| 50 – 75% | `13 / 19` |
| 75 – 100% | `19 / 25` |
| 0 – 33% (thirds) | `1 / 9` |
| 33 – 67% | `9 / 17` |
| 67 – 100% | `17 / 25` |
| 0 – 50% (halves) | `1 / 13` |
| 50 – 100% | `13 / 25` |
| 0 – 100% (full) | `1 / 25` |

For arbitrary percents, the conversion is `c0 = round(x_pct/100 * 24) + 1`,
`c1 = round((x_pct + w_pct)/100 * 24) + 1`. Snap to the table values above when
within ~3% to keep the layout aligned to common grid breakpoints.

Rows: Sigma rows are relative — use the row-sizing guide later in this file
(KPI 8–9 rows, bar chart 12–13 rows, hero line/area 13+ rows). A Tableau
dashboard at 100% height with two stacked rows of charts maps to ~12 Sigma
rows per chart row.

### Tableau dashboard object → Sigma element

| Tableau dashboard object | Sigma equivalent |
|---|---|
| Horizontal / Vertical Container | Use grid spans directly — no Sigma object |
| Blank (spacer) | Leave the grid range empty |
| Image | `image` element with `url` |
| Web Page | `image` with screenshot URL — no live-embed spec equivalent |
| Text annotation | `text` element (markdown `body`) |
| Filter shelf (single filter) | `control` element (`list` / `date-range` / `number-range` etc.) on the master table |
| Parameter control | `control` of `controlType: "segmented"` (radio buttons) or `number` / `slider` |
| Color legend (chart-internal) | Automatic in Sigma — don't recreate |
| Color legend (free-floating) | Optional `text` element + `color` channel on the chart |
| Dashboard title | `text` element with `body: "## <Title>"` |

---

## Typical page layout: 4 KPIs + line chart + 2 bar charts

```ruby
# Read the current spec (server-assigned IDs required)
spec = YAML.safe_load(File.read('/tmp/current-spec.yaml'), permitted_classes: [Date, Time])

# Find the Overview page and extract element IDs by name
overview = spec['pages'].find { |p| p['name'] == 'Overview' }
els = overview['elements'].each_with_object({}) { |e, h| h[e['name']] = e['id'] }

container_id  = els['KPI Row']        # container element
kpi1_id       = els['Total Sales']
kpi2_id       = els['Total Profit']
kpi3_id       = els['Profit Ratio']
kpi4_id       = els['Sales per Customer']
line_id       = els['Monthly Sales by Segment']
bar1_id       = els['Monthly Sales by Category']
bar2_id       = els['Sales by Ship Mode']

# Container spans outer rows 1-9 (8 units). Inner KPIs MUST span rows 1-9 to fill the container.
# Using 1/2 here would render KPIs as a tiny sliver — names invisible.
kpi_inner = [
  le(kpi1_id,  1,  7, 1, 9),
  le(kpi2_id,  7, 13, 1, 9),
  le(kpi3_id, 13, 19, 1, 9),
  le(kpi4_id, 19, 25, 1, 9)
].join("\n")

overview_layout = "<Page>\n" \
  "#{gc(container_id, 1, 25, 1, 9, kpi_inner)}\n" \
  "#{le(line_id,  1, 25,  9, 22)}\n" \
  "#{le(bar1_id,  1, 13, 22, 34)}\n" \
  "#{le(bar2_id, 13, 25, 22, 34)}\n" \
  "</Page>"
```

## Other canonical page layouts

### Title + filter shelf + 2×3 chart grid

The most common Tableau-derived layout: dashboard title at the top, a row of
filter controls beneath it, and 6 charts in a 2-row × 3-column grid.

```ruby
overview_layout = page_xml(
  'page-overview',
  le('title-text',         1, 25,  1,  3),     # title bar (full width)

  le('el-ctl-date',        1,  9,  3,  6),     # 3 controls horizontal
  le('el-ctl-region',      9, 17,  3,  6),
  le('el-ctl-state',      17, 25,  3,  6),

  le('el-chart-1',         1,  9,  6, 18),     # row 1 of charts
  le('el-chart-2',         9, 17,  6, 18),
  le('el-chart-3',        17, 25,  6, 18),

  le('el-chart-4',         1,  9, 18, 30),     # row 2 of charts
  le('el-chart-5',         9, 17, 18, 30),
  le('el-chart-6',        17, 25, 18, 30)
)
```

### Title + filter sidebar (left) + content

Alternative when the Tableau dashboard has filters stacked vertically on the
left. The sidebar takes ~6 cols; the content grid takes the remaining 18.

```ruby
overview_layout = page_xml(
  'page-overview',
  le('title-text',     1, 25,  1,  3),

  le('el-ctl-date',    1,  7,  3,  9),         # sidebar — 3 controls stacked
  le('el-ctl-region',  1,  7,  9, 15),
  le('el-ctl-state',   1,  7, 15, 21),

  le('el-chart-1',     7, 25,  3, 15),         # content area: 2 cols × 2 rows
  le('el-chart-2',     7, 16, 15, 27),
  le('el-chart-3',    16, 25, 15, 27)
)
```

### Title + 4 KPIs + hero + 2×2 grid

Useful when the source dashboard has a KPI strip up top (executive overview pattern):

```ruby
kpi_inner = [
  le('kpi-1',  1,  7, 1, 9),
  le('kpi-2',  7, 13, 1, 9),
  le('kpi-3', 13, 19, 1, 9),
  le('kpi-4', 19, 25, 1, 9)
].join("\n")

overview_layout = page_xml(
  'page-overview',
  le('title-text',         1, 25,  1,  3),
  gc('kpi-row',            1, 25,  3, 11, kpi_inner),
  le('el-hero',            1, 25, 11, 24),     # full-width hero chart
  le('el-chart-1',         1, 13, 24, 36),     # 2×2 grid
  le('el-chart-2',        13, 25, 24, 36),
  le('el-chart-3',         1, 13, 36, 48),
  le('el-chart-4',        13, 25, 36, 48)
)
```

## Row sizing guide

| Content | Typical row span |
|---|---|
| KPI row container (single row of KPIs) | 8–9 outer rows |
| KPI row container (two rows of KPIs) | 12–14 outer rows |
| Wide line/area chart | 13 rows |
| Bar chart (half-width) | 12–13 rows |
| Data table | 15–20 rows |

> **Critical — KPI inner row span must equal the container outer span.**
> `gridTemplateRows="auto"` inside a GridContainer does NOT expand rows to fill
> the container height. If your KPIs use `gridRow="1 / 2"` inside a container
> that spans 6 outer rows, the KPIs render as a tiny sliver — names invisible,
> values barely readable.
>
> **Rule:** inner `gridRow` end value must match the container's outer row span.
> Container at `gridRow="1 / 9"` (8 outer rows) → KPIs inside at `gridRow="1 / 9"`.
>
> For two rows of KPIs in one container (container outer `1 / 13`):
> - First row: inner `gridRow="1 / 7"` (6 inner units)
> - Second row: inner `gridRow="7 / 13"` (6 inner units)

## Multi-series chart patterns

### Small multiples / trellis

Sigma supports trellis (small multiples / panel charts) on bar, line, area, scatter, pie, donut, and combo charts — but **only via the chart editor UI**. POST/PUT silently drop every trellis-shaped field tried so far (`trellisRow`, `trellisColumn`, `trellisRows`, `trellisColumns`, `trellisBy`, `format.trellis`, top-level `trellis`). A trellis applied via the UI also does not appear in GET; the spec returns only the un-trellised chart.

**Workflow for a Tableau view that uses trellis:**

1. Build the chart via spec with the trellising dimension(s) listed in `columns` (so they're available in the chart's column pool) — but reference only `xAxis` / `yAxis` in the spec.
2. After PUT, open the chart in the editor → **Trellis** panel → drag the dimension into Trellis row / column.
3. The chart's data parity stays correct (Phase 6 validation works against the un-trellised aggregates the spec exposes); only the visual paneling needs manual setup.

If you need a spec-only approximation (no manual UI step) and the panel-by dimension has few values, fall back to a multi-series line chart — one series per panel value:

```json
{
  "kind": "line-chart",
  "name": "Monthly Sales by Segment",
  "columns": [
    {"id": "ov-date", "formula": "DateTrunc(\"month\", [Master/Order Date])", "name": "Month"},
    {"id": "ov-cons", "formula": "Sum(If([Master/Segment] = \"Consumer\", [Master/Sales], Null))", "name": "Consumer"},
    {"id": "ov-corp", "formula": "Sum(If([Master/Segment] = \"Corporate\", [Master/Sales], Null))", "name": "Corporate"},
    {"id": "ov-home", "formula": "Sum(If([Master/Segment] = \"Home Office\", [Master/Sales], Null))", "name": "Home Office"}
  ],
  "yAxis": {"columnIds": ["ov-cons", "ov-corp", "ov-home"]},
  "xAxis": {"columnId": "ov-date"}
}
```

**Breaking change 2026-05-21:** `xAxis` takes a singular `columnId` (string); `yAxis` takes plural `columnIds` (array). The OLD `xAxis: {id: ...}` / `yAxis: [{id: ...}]` shape is rejected by the live API on new POSTs. `yAxis` is still the correct field name (not `measures`).

`xAxis` is the canonical x-axis field for both `bar-chart` and `line-chart`. `dimension` is accepted by the API but is not the canonical form. Prefer `xAxis` for both.

```json
{
  "kind": "bar-chart",
  "xAxis": {"columnId": "bar-city"},
  "yAxis": {"columnIds": ["bar-sales"]}
}
```

```json
{
  "kind": "line-chart",
  "xAxis": {"columnId": "lc-month"},
  "yAxis": {"columnIds": ["lc-sales"]}
}
```

All `yAxis` entries are shown as separate series.

**Color channel on `bar-chart` / `line-chart`.** Both kinds accept an element-level `color` object that encodes a category column as series color. Verified May 2026 — the field persists on round-trip and the element renders the per-category breakdown:

```json
{
  "kind": "bar-chart",
  "columns": [
    {"id": "bar-region", "name": "Region",   "formula": "[Master/Region]"},
    {"id": "bar-seg",    "name": "Segment",  "formula": "[Master/Segment]"},
    {"id": "bar-sales",  "name": "Sales",    "formula": "Sum([Master/Sales])"}
  ],
  "xAxis": {"columnId": "bar-region"},
  "yAxis": {"columnIds": ["bar-sales"]},
  "color": {"by": "category", "column": "bar-seg"}
}
```

`color.by` is `"category"`, `color.column` is the column ID to encode as the color dimension.

If you need an explicit one-series-per-category breakdown instead (e.g., for stacked totals where you want a known fixed series set), use multiple `yAxis` entries with `If()` formulas:

```json
{ "id": "cons", "formula": "Sum(If([Master/Segment] = \"Consumer\", [Master/Sales], Null))", "name": "Consumer" },
{ "id": "corp", "formula": "Sum(If([Master/Segment] = \"Corporate\", [Master/Sales], Null))", "name": "Corporate" }
```

**Bar chart stacking.** Add `"stacking"` to control how multiple `yAxis` series are rendered:

```json
{
  "kind": "bar-chart",
  "stacking": "stacked",
  "xAxis": {"columnId": "bar-region"},
  "yAxis": {"columnIds": ["bar-cons", "bar-corp"]}
}
```

`stacking` values: `"none"` (default, grouped), `"stacked"` (absolute), `"normalized"` (100% stacked). Live-verified 2026-06-15 — `"100"` / `"percent"` are **rejected** (`Invalid value: string`); the 100%-stacked value is `"normalized"`.

### Area chart

Same spec as `line-chart` with `"kind": "area-chart"`. Supports `stacking` with the same values:

```json
{
  "kind": "area-chart",
  "columns": [
    {"id": "a-date",    "formula": "DateTrunc(\"month\", [Master/Order Date])", "name": "Month"},
    {"id": "a-revenue", "formula": "Sum([Master/Sales])", "name": "Revenue"}
  ],
  "xAxis": {"columnId": "a-date"},
  "yAxis": {"columnIds": ["a-revenue"]},
  "stacking": "none"
}
```

### Combo chart (bar + line overlay)

Uses `"kind": "combo-chart"`. All `yAxis` entries default to bars. Add `"type": "line"` to any
entry to render that series as a line instead:

```json
{
  "kind": "combo-chart",
  "columns": [
    {"id": "c-channel", "formula": "[Master/Channel]",     "name": "Channel"},
    {"id": "c-rev",     "formula": "Sum([Master/Revenue])", "name": "Revenue"},
    {"id": "c-orders",  "formula": "Count([Master/OrderId])", "name": "Orders"}
  ],
  "xAxis": {"columnId": "c-channel"},
  "yAxis": {"columnIds": ["c-rev", {"columnId": "c-orders", "type": "line"}]}
}
```

Combo-chart `yAxis.columnIds` is a **mixed array** — bare strings default to bar; objects `{ "columnId": "...", "type": "line" }` override the series type. Verified against the live API 2026-05-21.

### Scatter chart

Uses `"kind": "scatter-chart"`. `xAxis` takes a single column ID; `yAxis` is an array and **supports multiple measures** — each becomes an independent y-axis series plotted against the same x-axis:

```json
{
  "kind": "scatter-chart",
  "columns": [
    {"id": "s-profit", "formula": "Sum([Master/Profit])", "name": "Profit"},
    {"id": "s-sales",  "formula": "Sum([Master/Sales])",  "name": "Sales"},
    {"id": "s-qty",    "formula": "Sum([Master/Quantity])", "name": "Quantity"},
    {"id": "s-cat",    "formula": "[Master/Category]",    "name": "Category"}
  ],
  "xAxis": {"columnId": "s-sales"},
  "yAxis": {"columnIds": ["s-profit", "s-qty"]}
}
```

Single-measure yAxis (`"yAxis": {"columnIds": ["s-profit"]}`) is also valid — same array shape, one entry.

### Reference marks (`refMarks`)

Cartesian charts (`bar-chart`, `line-chart`, `area-chart`, `combo-chart`, `scatter-chart`) accept a `refMarks` array for reference lines. Verified live shape (from a UI-built workbook readback 2026-05-22):

```json
"refMarks": [
  {
    "type": "line",
    "axis": "series",
    "value": { "type": "constant", "value": 500 },
    "label": { "visibility": "shown", "text": "Target" }
  },
  {
    "type": "line",
    "axis": "series",
    "value": { "type": "formula", "formula": "Avg([T/Gross])" },
    "label": { "visibility": "shown", "text": "Avg gross" }
  }
]
```

Key facts:
- **`value` is a wrapped object, not a bare number.** Upstream `sigma-workbooks` charts.md shows `value: 1000` — that shape is rejected by the live API. Use `{ "type": "constant", "value": <number> }` or `{ "type": "formula", "formula": "<expr>" }`.
- `value.type: "column"` (with `columnId`) is also rejected — wrap the column in a `formula` instead.
- `axis` is `"series"` for the measure axis (Y), `"series2"` for combo-chart's secondary axis, `"axis"` for the X axis.
- `label.visibility` is `"shown"` or `"hidden"`. `label.text` is optional — Sigma renders a sensible default when absent.
- For `type: "band"` — wait for engineering to confirm via another UI-built readback (see `beads-sigma-7ak`).

#### Trendlines (verified 2026-05-22)

`trendlines` is a **separate field** on the chart element, sibling to `refMarks`. Canonical shape from a UI-built workbook readback:

```yaml
trendlines:
  - columnId: NunneVlI8N        # the y-axis measure column being modeled
    model: linear               # linear verified; logarithmic/exponential/polynomial/quadratic/power per docs (unverified)
    label: { visibility: shown }  # toggles the model-name label on the line
    value: { visibility: shown }  # toggles the equation / R² readout
    caption: {}                   # optional caption object
```

Differences from upstream `sigma-workbooks` charts.md:
- Docs frame `label` as `{ visibility, text }` and don't mention `value` or `caption`. The live readback has **separate** `label` and `value` visibility toggles plus a `caption` object. `text` on `label` is unverified.
- Docs show `line: { color, width }`. The canonical readback omits it — may be accepted but not the default; treat as unverified.
- Only `model: linear` is end-to-end verified. Other model names are passed through identically and emitted with a per-chart WARN to verify visually.

`tableau-to-sigma`'s `build-charts-from-signals.rb` auto-emits Tableau `<reference-line>` elements with formula in `{average, median, max, min, sum, count}` as Sigma `refMarks` with formula values, and Tableau `<trendline-model>` elements as Sigma `trendlines` (column = primary measure, model name passed through). Bands, distributions, and percentage-bands are still surfaced as WARN for manual editor wiring.

#### Axis format (`xAxis.format` / `yAxis.format`, verified 2026-05-22)

Both axes accept an optional `format` object. Verified shape from a UI-built workbook readback:

```yaml
xAxis:
  columnId: <dim_id>
  format:
    marks: tick                   # toggle tick marks
    scale:
      type: time                  # time (datetime axis) | linear | log
      zero: false

yAxis:
  columnIds: [<meas_id>]
  format:
    scale:
      type: log                   # linear (default) | log
      domain: { min: <n>, max: <n> }
      zero: true
```

**Per-column number format lives on the column entry, NOT on the axis.** Verified shape:

```yaml
columns:
  - id: <meas_id>
    formula: '[Metrics/Total Revenue]'
    format:
      kind: number                # number | datetime | percent
      formatString: "$,.2f"       # d3-format syntax
      currencySymbol: "$"
```

`build-charts-from-signals.rb` already emits per-column `format` from Tableau format strings via `tableau_format_to_sigma()` — verified shape matches the live API. **Axis-level scale (log/domain/min/max) is now auto-emitted** (2026-05-22, verified against "Orders Conversion Test" workbook).

Tableau emits axis range/scale overrides inside the worksheet style block:

```xml
<style-rule element='axis'>
  <encoding attr='space' class='0'
            scope='rows'                  scope='rows'→yAxis, 'cols'→xAxis
            class='0'                     0=primary, 1=secondary (dual-axis)
            scale='log'                   log scale (otherwise linear)
            range-type='fixed'            'fixed' honors min/max, 'automatic' omits domain
            min='1000.0' max='21015.17'   numeric bounds
            field='...' field-type='quantitative' />
</style-rule>
```

`parse-twb-layout.rb` extracts these into `axis_formats: [{scope, class, scale, range_type, min, max, field}]` on each chart zone. `build-charts-from-signals.rb` consumes them and emits `xAxis.format.scale` / `yAxis.format.scale`. Currently only `class='0'` (primary axis) is emitted; `class='1'` (secondary right axis on dual-axis combo) is parsed but not emitted because the Sigma-side right-axis format field is still unverified.

#### Dual-axis combo charts (verified 2026-05-22, retraction of prior "UI-only" finding)

Sigma **does** persist dual-axis combo charts via the spec — the bare-string-vs-object form of `yAxis.columnIds` entries is the axis assignment signal. Verified against a UI-built dual-axis combo chart (workbookUrlId `5xKqmuAXGooHxRgFrdk6VY`) where the left axis shows revenue ($500K–$1M log scale, bars) and the right axis shows margin (0–0.6 line):

```yaml
yAxis:
  columnIds:
    - <primary_measure_id>              # bare string → PRIMARY (left) axis, bar series
    - columnId: <secondary_measure_id>  # object form → SECONDARY (right) axis
      type: line                        # mark type for the secondary series
  format:
    scale:
      type: log
      domain: { min: 500000, max: 1000000 }
      zero: true
```

Key facts:
- **Bare string in `columnIds` = primary axis** (left). Mark type is the chart's `kind` default (bar for combo-chart).
- **`{columnId, type}` object in `columnIds` = secondary axis** (right). `type` overrides the mark shape (`line` typical, also `bar`/`area`/`scatter`).
- The right axis **auto-scales by default** — no explicit `axis: right` field is needed because the object form *is* the signal.
- `yAxis.format` governs the **left axis only**. How to customize the right-axis scale (log/min/max/zero) via spec is **unverified** — likely either a `secondaryYAxis.format` / `yAxis2.format` field or another nested form. Don't speculate; probe when needed.

`build-charts-from-signals.rb` already emits the correct dual-axis combo shape when Tableau dual-axis is detected (shipped in `33f1f35`).

**Earlier (incorrect) framing** held that dual-axis was UI-only like trellis/tooltip — that was based on misreading the spec. The object-form entry in `columnIds` is the field; the spec persists dual-axis fully for the rendering case.

#### Tooltips — confirmed UI-only (verified 2026-05-22)

Tooltip customization is **UI-only**, like trellis. We verified this by deliberately customizing the tooltip panel in a UI-built workbook and re-fetching the spec via the REST API — no `tooltip:` field was written back at any level (chart element, column entry, or page). Sigma's spec API does not persist tooltip config.

**Do not speculatively emit `tooltip:` fields** — they'll be silently dropped. Tableau workbooks with custom tooltips should be flagged with a WARN so the conversion agent can configure the tooltip manually in the Sigma editor post-conversion.

#### Data labels (`dataLabel`, verified 2026-05-22)

`dataLabel` is a separate chart-element field. The minimum required shape — what Sigma writes when the user just enables "show data labels" with no further customization — is **literally one field**:

```yaml
dataLabel:
  labels: shown    # shown | hidden
```

Optional sub-fields documented in upstream `sigma-workbooks/charts.md` (`labelDisplay`, `valueFormat`, `totals`, plus `seriesDataLabel` on combo-charts) only appear when the user customizes further; omit them on the default-on case. `text` and per-mark formatting are unverified.

`build-charts-from-signals.rb` auto-emits `dataLabel: { labels: shown }` when ANY of these Tableau signals is present:

1. Label or Text encoding channel populated (drag-to-shelf)
2. Worksheet-level "Show Mark Labels" toggle. Tableau XML (verified 2026-05-22 against "Orders Conversion Test"):

```xml
<pane><style><style-rule element='mark'>
  <format attr='mark-labels-show' value='true' />
</style-rule></style></pane>
```

`parse-twb-layout.rb` surfaces this as `mark_labels_show: true` on the chart zone; the emitter ORs it with the encoding-channel path.

### Map elements

Sigma supports two map kinds via spec: **`region-map`** (choropleth — fills named geographic regions) and **`point-map`** (lat/long bubbles or symbols).

> **Disregard older guidance that said "Sigma spec does not support maps."** Both kinds are real spec elements, persist on round-trip, and render correctly when published. Verified May 2026 against `cb2f5180-...` (`region-map`/`us-state` and `us-zipcode`) with live data parity confirmed via `mcp__sigma-mcp-v2__query`.

#### region-map (choropleth)

```json
{
  "kind": "region-map",
  "name": "Employees by State",
  "source": {"kind": "table", "elementId": "master"},
  "columns": [
    {"id": "rm-state", "formula": "[Master/State]",              "name": "State"},
    {"id": "rm-count", "formula": "Count([Master/Employee ID])", "name": "Employees"}
  ],
  "region": {"id": "rm-state", "regionType": "us-state"},
  "label":  [{"id": "rm-count"}]
}
```

| Field | Required | Shape | Notes |
|---|---|---|---|
| `region` | yes | `{id, regionType}` | `id` is the column ID holding the region key |
| `label` | optional | array `[{id}, ...]` | Values rendered on each region; usually the measure |
| `tooltip` | optional | array `[{id}, ...]` | Extra columns shown on hover (e.g., active count, avg salary) |
| `color` | optional | `{by: "category", column: <colId>}` | Categorical fill (one color per category, NOT a gradient) — column must be a **different** column from `region.id` (the API rejects reuse with "Column X is referenced from both 'region' and 'color'"). `by: "value"` is **rejected** with HTTP 400. With `color` omitted the map renders a uniform fill (NOT auto value-based heat). To get a Tableau-style red→blue divergent gradient heat scale, the customer must configure it in the Sigma editor after publish — it is UI-only today. Verified 2026-05-24 against `tj-wells-1989`. |
| `size` | — | silently dropped | Choropleths don't size; the API accepts and drops it |

**Valid `regionType` values (verified May 2026 — POST round-trips them):**

- `us-state` — 50 US states (+ DC)
- `us-county` — US counties
- `us-zipcode` — US ZIP codes (note: **not** `us-zip` — that's rejected)
- `us-cbsa` — US Core-Based Statistical Areas (note: **not** `us-msa` — that's rejected)
- `country` — country names / ISO codes

**Rejected `regionType` values:** `us-zip`, `us-msa`, `us-congressional-district`, `world-country`, `state`, `province`, `continent`. All return `pages[N].elements[N].region.regionType: Invalid value: string`.

#### Tableau geographic role → Sigma `regionType`

`parse-twb-layout.rb` surfaces the worksheet's `semantic-role` attribute when one
is set. Translate to a Sigma `regionType` like this:

| Tableau `semantic-role` | Sigma `regionType` | Notes |
|---|---|---|
| `[Country].[ISO3166_2]` | `country` | Country names or ISO codes; Sigma's only non-US region type |
| `[Country].[Country]` | `country` | Same — alternate role naming |
| `[State].[Name]` | `us-state` | Only valid if the data is US states. Non-US states → no spec equivalent, fall back to bar chart |
| `[State/Province].[Name]` | `us-state` | Same restriction — US only |
| `[County].[Country].[Name]` | `us-county` | US counties; non-US → bar-chart fallback |
| `[Zip Code].[Country].[Zip]` | `us-zipcode` | US ZIP only; note: **`us-zipcode`**, not `us-zip` |
| `[Area Code].[Country].[Area]` | `us-cbsa` | Closest match for metro-area-ish encodings; verify the data is CBSA-shaped first |
| `[City].[Country].[Name]` | (no spec) | Fall back to bar chart or to `point-map` if lat/long are also present |

> **Non-US dataset with state / county / ZIP encoding:** Sigma's region-map types are US-only except for `country`. Drop to a sorted descending bar chart or, if you have lat/long, a `point-map`. Document the fallback in the Sigma chart's name so the user knows why it's not a map.

> **Both `latitude` and `longitude` columns present:** prefer `point-map` over `region-map`. Lat/long is more precise than a region rollup, and Sigma's point-map renders directly without needing a region-type match.

#### point-map (lat/long bubbles)

```json
{
  "kind": "point-map",
  "name": "Stores by location",
  "source": {"kind": "table", "elementId": "master"},
  "columns": [
    {"id": "p-lat",  "formula": "[Master/Lat]",            "name": "Lat"},
    {"id": "p-lng",  "formula": "[Master/Long]",           "name": "Long"},
    {"id": "p-sz",   "formula": "Sum([Master/Revenue])",   "name": "Revenue"},
    {"id": "p-cat",  "formula": "[Master/Region]",         "name": "Region"}
  ],
  "latitude":  {"id": "p-lat"},
  "longitude": {"id": "p-lng"},
  "size":      {"id": "p-sz"},
  "color":     {"by": "category", "column": "p-cat"},
  "label":     [{"id": "p-sz"}]
}
```

| Field | Required | Shape |
|---|---|---|
| `latitude` | yes | `{id}` — object, not array |
| `longitude` | yes | `{id}` |
| `size` | optional | `{id}` — bubble size encodes a measure |
| `color` | optional | `{by: "category", column: <colId>}` — same shape as bar/line color (`by: "value"` is **rejected** on `point-map`; only category coloring is wired up via spec) |
| `label` | optional | array `[{id}, ...]` |

> **Invalid map kinds.** The API rejects `bubble-map`, `geo-map`, `heat-map`, `choropleth-map`, `us-map`, and `map` with `Invalid kind`. Use `region-map` or `point-map` only.

#### When to fall back to a bar chart

If your geo dimension doesn't fit one of the five `regionType` values above (e.g., "Sales by City" with no lat/long), use a bar chart sorted descending instead:

```json
{
  "kind": "bar-chart",
  "name": "Sales by City",
  "columns": [
    {"id": "bar-city",  "formula": "[Master/City]",       "name": "City"},
    {"id": "bar-sales", "formula": "Sum([Master/Sales])", "name": "Sales"}
  ],
  "yAxis": {"columnIds": ["bar-sales"]},
  "xAxis": {"columnId": "bar-city", "sort": {"by": "bar-sales", "direction": "descending"}}
}
```

## Visual formatting properties NOT available via spec API

The following properties are **UI-only** — the API silently drops any field you add for these,
and they do not appear in GET responses even after being set in the UI. Apply them manually in
the chart editor after publish.

| Property | Set via spec? | How to apply post-publish |
|---|---|---|
| Bar chart orientation (horizontal vs vertical) | **Yes** — `"orientation": "horizontal"` on the `bar-chart` (omit for the default vertical) | n/a — set in spec |
| Trellis (small multiples / panel charts) on any chart kind | No | Chart editor → Trellis panel → drag dimension to Trellis row / column / by-series |
| Axis label rotation (0°, 45°, 90°) | No | Chart editor → Format → X-axis → Label rotation |
| Series color | No (not yet) | Chart editor → Properties → Color |
| Chart color palette | No | Chart editor → Properties → Color |
| Font size / axis title | No | Chart editor → Format tab |
| Text element alignment (center / right) | **Yes (since 2026-06-11)** | Inline HTML in `body`: `<p style="text-align: center">…</p>` (also `right`/`left`). Round-trips through GET/PUT — live-verified 2026-06-11. Combines with `<span>` color/font-size styling. Pre-fix UI-set alignment did not serialize; re-apply once via spec or UI and it sticks. |

**`"orientation": "horizontal"` makes a horizontal bar chart and round-trips through GET** (live-verified 2026-06-15). The enum accepts `"horizontal"` only — omit the field entirely for the default vertical orientation (`"orientation": "vertical"` is rejected).

**Series `color` on `yAxis` entries is silently accepted but not persisted.** PUT succeeds without error but GET strips the field. Expected shape for when this is wired up:
```json
"yAxis": {"columnIds": ["col-revenue", {"columnId": "col-orders", "type": "line"}]}
```

Per-series chart type for combo-chart goes in the `yAxis.columnIds` entry as `{"columnId": "...", "type": "line"}` (verified 2026-05-21). Per-series color is still chart-editor-only; the new docs note `seriesDataLabel` exists for combo-chart per-shape label customization — check `jq '.components.schemas.SeriesDataLabel' /tmp/sigma-api.json` for the shape if you need it.

## Element kinds supported

| Sigma kind | Tableau equivalent / use |
|---|---|
| `kpi-chart` | Big number / scorecard |
| `line-chart` | Line chart, small multiples (trellis applied via UI; or multi-series approximation) |
| `area-chart` | Area chart (filled line) |
| `bar-chart` | Bar chart, horizontal bar, histogram |
| `combo-chart` | Dual-axis / combination chart (bar + line) |
| `scatter-chart` | Scatter / bubble chart |
| `pie-chart` | Pie chart |
| `donut-chart` | Donut / ring chart |
| `region-map` | Filled / choropleth map (Tableau filled map, symbol-by-region) |
| `point-map` | Lat/long bubble or symbol map (Tableau symbol map with generated or stored coords) |
| `table` | Crosstab, text table |
| `pivot-table` | Pivot / crosstab |
| `control` | Dashboard filter, parameter (all types — see Control elements below) |
| `text` | Text / markdown block |
| `image` | Embedded image |
| `container` | Card group / container (wraps other elements) |

> **`pie-chart` not `pie`, `donut-chart` not `donut`.** The API rejects `"kind": "pie"` and `"kind": "donut"` with `Invalid kind`. Always use the `-chart` suffix for these two. The official example library shows the wrong values — do not follow it.

Not supported via spec API: bullet chart, gantt. Invalid map-like kinds (rejected with `Invalid kind`): `bubble-map`, `geo-map`, `heat-map`, `choropleth-map`, `us-map`, `map`. Use `region-map` or `point-map`.

Trellis (small multiples / panel charts) is supported in Sigma but **UI-only** — see the "Small multiples / trellis" section above for the workflow.

## Element-type field requirements

### KPI elements

> **`kpi-chart`, not `kpi`.** The API rejects `"kind": "kpi"` with `"Invalid kind: 'kpi'"`.

KPI elements require a `value` field referencing one column ID:

```json
{
  "kind": "kpi-chart",
  "columns": [{"id": "k-sales", "formula": "Sum([Master/Sales])", "name": "Total Sales", "format": {"kind": "number", "formatString": "$,.0f"}}],
  "value": {"columnId": "k-sales"}
}
```

Omitting `value` causes `"Invalid object: ...value, got undefined"`.

### Column format reference

Every column can carry an optional `format` object. Common patterns:

**Number formats** (`kind: "number"`, d3-format strings):

| `formatString` | Example output |
|---|---|
| `"$,.0f"` | $1,234 |
| `"$,.2f"` | $1,234.56 |
| `",.0f"` | 1,234 |
| `",.2%"` | 12.34% |

**Datetime formats** (`kind: "datetime"`, strftime strings):

| `formatString` | Example output |
|---|---|
| `"%Y-%m-%d"` | 2026-04-21 |
| `"%b %Y"` | Apr 2026 |
| `"%B %Y"` | April 2026 |
| `"%Y-%m-%d %H:%M"` | 2026-04-21 14:30 |

```json
{"id": "col-date", "formula": "DateTrunc(\"month\", [Master/Order Date])", "name": "Month",
 "format": {"kind": "datetime", "formatString": "%b %Y"}}
```

### Pivot table elements

Use `rowsBy`, `columnsBy`, and `values`. **Do NOT use `rows` or `columnGroups`** — the API accepts them silently but the pivot does not render correctly.

- `values`: array of **string** column IDs
- `rowsBy`: array of **objects** `{"id": "col-id"}` — row groupings (left axis)
- `columnsBy`: array of **objects** `{"id": "col-id"}` — column pivots (top axis)

> **`columnsBy[].sort` is NOT supported.** PUT returns HTTP 400 `sort shape not supported on columnsBy`. Sigma orders pivot columns by the natural order of the underlying column values: alphabetical for strings, numeric for numbers, chronological for dates / integers used as a date-of-year key. To control column order, pre-compute an integer sort key column (e.g. `Month([Master/Order Date])` returns 1-12 and sorts chronologically) and use that as the `columnsBy` field instead of a string. Today's Superstore lesson: `MonthName()` (string) sorted alphabetically (April, August, December, …) until swapped to `Month()` (integer) which sorted Jan→Dec. Verified 2026-05-24.

```json
{
  "kind": "pivot-table",
  "columns": [
    {"id": "pcy-cat",   "formula": "[Master/Category]",                        "name": "Category"},
    {"id": "pcy-year",  "formula": "DateTrunc(\"year\", [Master/Order Date])",  "name": "Year"},
    {"id": "pcy-month", "formula": "DateTrunc(\"month\", [Master/Order Date])", "name": "Month"},
    {"id": "pcy-sales", "formula": "Sum([Master/Sales])",                       "name": "Sales"}
  ],
  "values":    ["pcy-sales"],
  "rowsBy":    [{"id": "pcy-cat"}, {"id": "pcy-year"}],
  "columnsBy": [{"id": "pcy-month"}]
}
```

**`conditionalFormats`** — Conditional formatting on pivot-table / table columns. Two supported types.

> **Verified 2026-05-24 against `tj-wells-1989` org during audit-run-2.** The
> field that holds the column IDs is **`columnIds`**, NOT `columns`. The first
> POST in audit-run-1 (NASA agent) failed with HTTP 400 `Invalid request` when
> using `columns`; the second succeeded with `columnIds` and round-trips
> cleanly through GET. This file previously documented `columns` — it was
> wrong. The graduated `sigma-workbooks/reference/specification/tables.md`
> already uses `columnIds`; staging is now consistent.

`dataBars` — renders colored bars proportional to cell values:

```json
{
  "conditionalFormats": [{
    "type": "dataBars",
    "columnIds": ["pcy-sales", "pcy-profit"],
    "scheme": ["#FF9D99", "#A0CBE8"],
    "includeValues": true,
    "includeSubtotals": false
  }]
}
```

`backgroundScale` — applies a color gradient across cell values (diverging or sequential scale). Use this on a `pivot-table` to render a heatmap-equivalent of a Tableau heatmap view:

```json
{
  "conditionalFormats": [{
    "type": "backgroundScale",
    "columnIds": ["pcy-margin"],
    "scheme": ["#8C0D25", "#FFFFFF", "#134B85"],
    "includeValues": true
  }]
}
```

> **Use hex (`#RRGGBB`) colors, not `rgb(...)`.** Verified May 2026 — `rgb(140,13,37)` in any spec field gets blocked by Sigma's Cloudflare WAF with HTTP 403 (interpreted as a SQL-injection-like pattern). Hex strings pass cleanly. This applies to every spec field that takes a color string, not just `backgroundScale.scheme`.

### Table element extras

These fields are accepted on `table` (and master table) elements:

**`visibleAsSource: false`** — Hides the element from being browsable as a standalone table in the
workbook. **Always set this on the master/data table** — it should be a source for charts, not
a table users can navigate to directly:

```json
{
  "kind": "table",
  "name": "Master",
  "visibleAsSource": false,
  "source": { "kind": "data-model", "dataModelId": "<id>", "elementId": "<id>" },
  "columns": [...]
}
```

**`order`** — Explicit column display order. Value is an array of column IDs. Without it, column
order is undefined and may differ from the Tableau source:

```json
{
  "kind": "table",
  "columns": [...],
  "order": ["col-channel", "col-ship", "col-status", "col-revenue", "col-orderid", "col-datekey"]
}
```

**`groupings`** — Row groupings with subtotals (equivalent to Tableau row-level subtotals). Each
entry specifies which columns to group by and which to aggregate:

```json
{
  "groupings": [{
    "id": "grp-dept",
    "groupBy": ["col-department"],
    "calculations": ["col-total-hours", "col-cost"],
    "sort": [{"columnId": "col-total-hours", "direction": "descending", "nulls": "connection-default"}]
  }]
}
```

**`summary`** — Column IDs to show in a summary/footer row at the bottom of the table:

```json
{ "summary": ["col-revenue", "col-orders"] }
```

**`style`** — Table border styling:

```json
{ "style": {"borderRadius": "round", "borderColor": "#E0E0E0", "borderWidth": 1} }
```

### Pie and donut elements

> **`pie-chart` and `donut-chart`** — NOT `pie` / `donut`. Both are rejected by the API with `Invalid kind`.

Both use `color` for the dimension (slice category) and `value` for the measure. Donut accepts an optional `holeValue` for the center label.

```json
{
  "kind": "pie-chart",
  "columns": [
    {"id": "dim-region", "formula": "[Master/Region]", "name": "Region"},
    {"id": "mea-sales",  "formula": "Sum([Master/Sales])", "name": "Sales"}
  ],
  "color": {"id": "dim-region"},
  "value": {"id": "mea-sales"}
}
```

```json
{
  "kind": "donut-chart",
  "columns": [
    {"id": "dim-seg",    "formula": "[Master/Segment]", "name": "Segment"},
    {"id": "mea-sales",  "formula": "Sum([Master/Sales])", "name": "Sales"},
    {"id": "mea-sales2", "formula": "Sum([Master/Sales])", "name": "Sales Total"}
  ],
  "color":     {"id": "dim-seg"},
  "value":     {"id": "mea-sales"},
  "holeValue": {"id": "mea-sales2"}
}
```

`holeValue` is optional — donuts render fine without it. When set, it must reference a column ID, not a literal float (`"holeValue": 0.5` is rejected with `Invalid object: number`).

> **`holeValue.id` must NOT equal `value.id`.** If both point at the same column ID, POST returns success but the entire donut element is silently dropped from the saved spec (verified May 2026). Define a second column with a distinct ID — same formula is fine — as `mea-sales2` above.

### Text element

Uses `"kind": "text"`. The `body` field is a plain markdown string. No `source`, `columns`, or axes.

```json
{
  "id": "txt-header",
  "kind": "text",
  "body": "## Sales Overview\n\nThis dashboard covers order performance by region and segment."
}
```

**Use a text element to recreate Tableau dashboard titles and section headers.** Renaming the
page (`page['name']`) only changes the tab label; it does not put a heading on the canvas.
If the Tableau dashboard image shows a title at the top, add `{ "kind": "text", "body": "# Title" }`
and reserve the top ~2 grid rows for it in the layout XML.

**Alignment is spec-able as of 2026-06-11** (previously UI-only). Wrap the content in inline
HTML: `<p style="text-align: center">…</p>` (also `right`/`left`). Live-verified: POSTs cleanly,
survives GET→PUT cycles, and combines with `<span style="color/font-size">` styling. Bare
markdown (`# Heading`) still renders left-aligned — alignment must be expressed in the HTML form.

### Image element

Uses `"kind": "image"`. The `url` field is a public remote image URL. No `source`, `columns`, or axes.

```json
{
  "id": "img-logo",
  "kind": "image",
  "url": "https://example.com/logo.png"
}
```

In layout XML, image elements use a standard `<LayoutElement>`:
```xml
<LayoutElement elementId="img-logo" gridColumn="1 / 9" gridRow="1 / 9"/>
```

### Container element

Uses `"kind": "container"`. The element spec has no extra fields — children are nested inside it via `<GridContainer>` in the layout XML (see GridContainer section above).

```json
{
  "id": "kpi-row",
  "kind": "container"
}
```

### Histogram

Use a regular `bar-chart` with a manual `If()` bucketing formula as the `xAxis` column and `Count()` as the `yAxis` measure:

```json
{
  "kind": "bar-chart",
  "columns": [
    {"id": "bucket", "formula": "If([Master/Sales] < 100, \"$0-$100\", If([Master/Sales] < 500, \"$100-$500\", \"$500+\"))", "name": "Sales Bucket"},
    {"id": "cnt",    "formula": "Count()", "name": "Orders"}
  ],
  "xAxis": {"columnId": "bucket"},
  "yAxis": {"columnIds": ["cnt"]}
}
```

## Control elements

Controls are fully supported via the spec API. There are 9 control types.

### Filter targets

Every control that filters data uses a `filters` array. The source in each filter entry can point to either a warehouse table directly or a workbook element:

```json
// Warehouse table (connectionId + path)
"filters": [{"source": {"kind": "warehouse-table", "connectionId": "<id>", "path": ["SCHEMA", "CATALOG", "TABLE"]}, "columnId": "COLUMN_NAME"}]

// Workbook element column (server-assigned element and column IDs)
"filters": [{"source": {"kind": "table", "elementId": "<element-id>"}, "columnId": "<server-col-id>"}]
```

### list — dropdown / multi-select

Manual source (fixed static values):

```json
{
  "kind": "control", "controlId": "filter-order", "name": "Order ID",
  "controlType": "list",
  "mode": "include", "selectionMode": "multiple", "values": [],
  "source": {"kind": "manual", "valueType": "text"},
  "filters": [{"source": {"kind": "warehouse-table", "connectionId": "<id>", "path": [...]}, "columnId": "ORDER_ID"}]
}
```

Dynamic source (values populated from a column):

```json
{
  "kind": "control", "controlId": "filter-region", "name": "Region",
  "controlType": "list",
  "mode": "include", "selectionMode": "multiple", "values": [],
  "source": {"kind": "source", "source": {"kind": "table", "elementId": "<master-id>"}, "columnId": "<col-region-id>"},
  "filters": [{"source": {"kind": "table", "elementId": "<master-id>"}, "columnId": "<col-region-id>"}]
}
```

### date-range

```json
{
  "kind": "control", "controlId": "filter-date", "name": "Order Date",
  "controlType": "date-range", "mode": "between",
  "includeNulls": "when-no-value-is-selected",
  "filters": [{"source": {"kind": "warehouse-table", "connectionId": "<id>", "path": [...]}, "columnId": "ORDER_DATE"}]
}
```

**Default value.** Two shapes, depending on whether you want a relative or fixed window:

```json
// Relative: "current year", "year to date", etc. — rolls forward over time
"mode": "current",
"unit": "year"
```

```json
// Fixed: explicit start/end dates — does not change as time passes
"mode": "between",
"startDate": "2026-01-01T00:00:00Z",
"endDate": "2026-12-31T23:59:59Z"
```

`unit` for relative defaults: `"year"`, `"quarter"`, `"month"`, `"week"`, `"day"` (likely also `"hour"` / `"minute"` for time-of-day filters; verify by setting in UI and round-tripping).

`startDate` / `endDate` are ISO 8601 timestamps with explicit timezone (UTC `Z` suffix is what Sigma round-trips). Top-level fields on the control object — NOT nested inside `value` / `default` / similar.

> **`value: {min, max}` is silently dropped.** A natural-looking shape like
> `"value": {"min": "2026-01-01", "max": "2026-12-31"}` is accepted by POST/PUT
> without error, GET strips it on round-trip, and the control renders with no
> default. Tableau dashboards translated as fixed date filters will look like
> they're missing their default after publish — confirm by GET-ing the control
> and checking for `startDate` / `endDate` at the top level.

### text — single-line text filter

```json
{
  "kind": "control", "controlId": "filter-schema", "name": "Schema",
  "controlType": "text", "mode": "equals", "case": "insensitive",
  "includeNulls": "when-no-value-is-selected", "showOperators": false,
  "filters": [{"source": {"kind": "table", "elementId": "<element-id>"}, "columnId": "<col-id>"}]
}
```

### text-area — multi-line text input

```json
{
  "kind": "control", "controlId": "filter-text-area",
  "controlType": "text-area",
  "filters": [{"source": {"kind": "warehouse-table", "connectionId": "<id>", "path": [...]}, "columnId": "ORDER_ID"}]
}
```

### segmented — parameter / radio buttons

Manual values (most common for parameters):

```json
{
  "kind": "control", "controlId": "p_date_dimension", "name": "Time Period",
  "controlType": "segmented",
  "source": {"kind": "manual", "valueType": "text", "values": ["Month", "Quarter", "Year"], "labels": [null, null, null]},
  "value": "Quarter"
}
```

Dynamic source (values from a column):

```json
{
  "kind": "control", "controlId": "Ship-Mode", "name": "Ship Mode",
  "controlType": "segmented",
  "source": {"kind": "source", "source": {"kind": "warehouse-table", "connectionId": "<id>", "path": [...]}, "columnId": "SHIP_MODE"},
  "value": null
}
```

Segmented controls have no `filters` — they act as parameters referenced in element formulas via `controlId`:

```
Sum(If([p_date_dimension] = "Month", [Sales], Null))
```

### number — exact number match

```json
{
  "kind": "control", "controlId": "filter-qty", "name": "Quantity",
  "controlType": "number", "mode": "=",
  "includeNulls": "when-no-value-is-selected",
  "filters": [{"source": {"kind": "table", "elementId": "<element-id>"}, "columnId": "<col-id>"}]
}
```

### number-range — from/to number inputs

```json
{
  "kind": "control", "controlId": "filter-sales-range", "name": "Sales Range",
  "controlType": "number-range",
  "includeNulls": "when-no-value-is-selected",
  "filters": [{"source": {"kind": "warehouse-table", "connectionId": "<id>", "path": [...]}, "columnId": "SALES"}]
}
```

### slider — single-handle numeric control

> **Corrected 2026-06-15.** The earlier note that `controlType: slider` "does not exist" was **wrong** — it came from a probe that omitted the required `mode` field, so the `Invalid kind: "control"` rejection was misread as "unsupported type." `slider` is a valid `controlType` (it is in the OpenAPI enum, builds in the UI, and POSTs cleanly). A single-handle slider carries **flat top-level** `low`/`high` (track bounds), a `mode` comparator (`<=` / `>=` / `=` / `<` / `>` — which rows the handle keeps), and a **scalar** `value` (handle position). Live-verified by reading back a UI-built slider **and** a successful POST.

```json
{
  "kind": "control", "controlId": "slider-sales", "name": "Sales",
  "controlType": "slider",
  "low": 0, "high": 100000, "mode": "<=", "value": 33755,
  "includeNulls": "when-no-value-is-selected",
  "filters": [{"source": {"kind": "warehouse-table", "connectionId": "<id>", "path": [...]}, "columnId": "SALES"}]
}
```

> A nested `value: {low, high}` object is rejected with `Invalid kind: control`; the fields are flat. The most common mistake is omitting `mode` — the element is rejected without it even when `low`/`high`/`value` are present.

### range-slider — range with two handles

> **Live-verified 2026-06-15.** A two-handle `range-slider` carries flat `low`/`high` (the band) and an optional `max`; all round-trip through GET (`max` auto-derives from `high` if omitted). A valid, first-class alternative to `number-range` for a bounded numeric band.

```json
{
  "kind": "control", "controlId": "range-slider-sales", "name": "Sales Range",
  "controlType": "range-slider", "low": 0, "high": 100, "max": 100,
  "includeNulls": "when-no-value-is-selected",
  "filters": [{"source": {"kind": "warehouse-table", "connectionId": "<id>", "path": [...]}, "columnId": "SALES"}]
}
```

### top-n — filter to top or bottom N items

```json
{
  "kind": "control", "controlId": "top-n-products", "name": "Top N",
  "controlType": "top-n", "rankingFunction": "rank", "mode": "top-n",
  "includeNulls": "when-no-value-is-selected",
  "filters": [{"source": {"kind": "table", "elementId": "<element-id>"}, "columnId": "<col-id>"}]
}
```

### Element-level top-n filter (on charts)

To hard-code a top-N filter on a chart element (not user-adjustable), add a `filters` array to the element:

```json
{
  "kind": "bar-chart",
  "columns": [...],
  "xAxis": {"columnId": "PRODUCT_NAME", "sort": {"by": "nZea2N896k", "direction": "descending"}},
  "yAxis": {"columnIds": ["nZea2N896k"]},
  "filters": [{
    "id": "top-10-filter",
    "columnId": "nZea2N896k",
    "kind": "top-n",
    "rankingFunction": "row-number",
    "mode": "top-n",
    "rowCount": 10,
    "includeNulls": "never"
  }]
}
```

## Full spec assembly with layout

```ruby
# Merge layout into a copy of the current spec, then PUT
spec = YAML.safe_load(File.read('/tmp/current-spec.yaml'), permitted_classes: [Date, Time])

# Build per-page XML using server-assigned IDs
pages_by_name = spec['pages'].each_with_object({}) { |p, h| h[p['name']] = p }

overview_xml  = page_xml(pages_by_name['Overview']['id'],  ...)
product_xml   = page_xml(pages_by_name['Product']['id'],   ...)
# ...

# Set ONE top-level layout field — remove any layout from page objects
spec['pages'].each { |p| p.delete('layout') }
spec['layout'] = [
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
  overview_xml,
  product_xml
].join("\n")

File.write('/tmp/workbook-with-layout.json', JSON.pretty_generate(spec))
```

Then PUT:
```bash
curl -s -X PUT \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/workbook-with-layout.json \
  "$SIGMA_BASE_URL/v2/workbooks/<workbookId>/spec"
```

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Using `"kind": "kpi"` | `"Invalid kind: 'kpi'"` | The correct kind is `"kpi-chart"` — never `"kpi"` |
| Using `"kind": "pie"` | `"Invalid kind: 'pie'"` | The correct kind is `"pie-chart"` — the official example library is wrong here |
| Using `"kind": "donut"` | `"Invalid kind: 'donut'"` | The correct kind is `"donut-chart"` — the official example library is wrong here |
| KPI names invisible or truncated inside container | Inner `gridRow` too small — e.g., `1 / 2` inside a 6-row container | Set inner end value = container outer end value: container `1 / 9` → KPIs `1 / 9` |
| KPIs appear as a tiny sliver at top of container | Same root cause as above | Same fix — match inner row span to container outer span |
| Setting `layout` on each page object instead of top-level | PUT returns success but UI shows no layout change | Set `spec['layout']` once at the top level; strip `layout` from all page objects |
| Bare `<Page>` tag without `type`/`id` attributes | Layout ignored silently | Use `<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="<pageId>">` |
| Using `measures` instead of `yAxis` on bar/line charts | `"Invalid array: ...yAxis, got undefined"` | Replace `measures` with `yAxis` |
| KPI missing `value` field | `"Invalid object: ...value, got undefined"` | Add `"value": {"columnId": "<col-id>"}` to every `kpi-chart` element |
| Using `rows`/`columnGroups` on a pivot table | API accepts silently but pivot does not render | Use `rowsBy`/`columnsBy` (object arrays) and `values` (string array) |
| Using IDs from POST body instead of GET response | Layout elements don't appear | Always GET spec after POST to get real IDs |
| `<LayoutElement>` for a container | Empty container visible | Use `<GridContainer>` for elements that have children |
| Hand-writing layout XML | Off-grid sizing, overlapping elements | Use Ruby helpers; let math determine positions |
| Overlapping row ranges | Elements hidden behind each other | Draw row ranges on paper; ensure no two elements share rows on the same column span |
| Fallback `els.values[N]` when page has fewer elements than expected | `elementId=""` in XML — PUT rejected with `invalid_request` | Guard with `(le(id, ...) if id)` and call `.compact` on the children array before passing to `page_xml` |
| Using `dimension` on a `line-chart` | Works but is non-canonical | Use `xAxis` for both `bar-chart` and `line-chart` |
