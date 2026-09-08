<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Split from refs/workbook-layout.md (E9.3 phase-scoped refs, 2026-07-27): this file owns UI-only property limits, supported element kinds, per-kind field requirements (KPI, pivot, table, pie/donut, text, image, container, histogram), and control elements. Siblings: twb-zone-mapping.md (.twb zone tables), layout-grid.md (grid + layout XML), chart-patterns.md (multi-series + maps). -->

# Element kinds — field requirements + controls

> **Read at Phase 5** (workbook element + control building). Spec shape lives in
> `sigma-workbooks` — this file is Tableau-conversion-specific; when it
> disagrees with the sigma-workbooks reference, that reference wins.

## Visual formatting properties NOT available via spec API

The following properties are **UI-only** — the API silently drops any field you add for these,
and they do not appear in GET responses even after being set in the UI. Apply them manually in
the chart editor after publish.

| Property | Set via spec? | How to apply post-publish |
|---|---|---|
| Bar chart orientation (horizontal vs vertical) | **Yes** — `"orientation": "horizontal"` on the `bar-chart` (omit for the default vertical) | n/a — set in spec |
| Trellis (small multiples / panel charts) | **Yes on supported chart kinds** | `build-charts-from-signals.rb` collapses detected repeated worksheets to one chart with `trellis.rowsBy` or `columnsBy`; unsupported kinds remain explicit sibling elements |
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
| `waterfall-chart` | Tableau Gantt Bar with an explicit `RUNNING_SUM` signature; verify the bound y-series is the delta |
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
| `navigation` | Story-point/page navigation; story conversion emits a manual page list |
| `progress` | Released value/progress surface; emit only when Tableau exposes an unambiguous value/goal semantic |
| `page-break` | Released print break; Tableau dashboard XML has no reliable authored-break signal |
| `repeated-container` | Released record repeater; Tableau small multiples remain chart `trellis`, not a record repeater |
| `tabbed-container` | Released alternate-view container; use only when mutually-exclusive view membership and labels are known |
| `divider` / `button` | Thin rules and dashboard actions (`button` remains workspace-gated) |

> **`pie-chart` not `pie`, `donut-chart` not `donut`.** The API rejects `"kind": "pie"` and `"kind": "donut"` with `Invalid kind`. Always use the `-chart` suffix for these two. The official example library shows the wrong values — do not follow it.

Not published via the workbook spec: `box-chart`. Keep Tableau box plots as an
explicit quartile/reference-mark or table fallback; never emit that kind.
Gantt timelines/candlesticks remain manual (only Gantt Bar + `RUNNING_SUM`
maps to waterfall). Invalid map-like kinds (rejected with `Invalid kind`):
`bubble-map`, `geo-map`, `heat-map`, `choropleth-map`, `us-map`, `map`. Use
`region-map` or `point-map`.

See `refs/workbook-code-release-gaps.md` for the source-semantics gate on
navigation, drill controls, repeaters, tabs, page breaks, progress, and panels.

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
- `rowsBy`: array of **objects** `{"columnId": "col-id"}` — row groupings (left axis)
- `columnsBy`: array of **objects** `{"columnId": "col-id"}` — column pivots (top axis)

> **`columnsBy[].sort` WORKS** (live-verified 2026-07-07 on the live-migration run — POST + PUT round-trip cleanly and the pivot honors the sort). An earlier version of this file claimed PUT returned HTTP 400 `sort shape not supported on columnsBy`; that claim is stale — do not burn a round-trip re-verifying it. Shape: `columnsBy: [{"columnId": "col-id", "sort": {...}}]` (same sort object as `rowsBy`). **Do not use `{id}` on these shelves** — that shape is a 400. Without a `sort`, Sigma orders pivot columns by the natural order of the underlying column values: alphabetical for strings, numeric for numbers, chronological for dates. **Integer-sort-key tip (still useful as an alternative for value-order control):** pre-compute an integer sort key column (e.g. `Month([Master/Order Date])` returns 1-12 and sorts chronologically) and use that as the `columnsBy` field instead of a string — `MonthName()` (string) sorts alphabetically (April, August, December, …); `Month()` (integer) sorts Jan→Dec.

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
  "rowsBy":    [{"columnId": "pcy-cat"}, {"columnId": "pcy-year"}],
  "columnsBy": [{"columnId": "pcy-month"}]
}
```

**`conditionalFormats`** — Conditional formatting on pivot-table / table columns. Two supported types.

> **Verified 2026-05-24 against a live Sigma org during audit-run-2.** The
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
  "color": {"columnId": "dim-region"},
  "value": {"columnId": "mea-sales"}
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
  "color":     {"columnId": "dim-seg"},
  "value":     {"columnId": "mea-sales"},
  "holeValue": {"columnId": "mea-sales2"}
}
```

`holeValue` is optional — donuts render fine without it. When set, it must reference a column ID, not a literal float (`"holeValue": 0.5` is rejected with `Invalid object: number`).

> **`holeValue.columnId` must NOT equal `value.columnId`.** If both point at the same column ID, the API rejects the collision. Define a second column with a distinct ID — same formula is fine — as `mea-sales2` above. Channel pointers use `{ columnId }`, not `{ id }`.

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

Uses `"kind": "image"`. No `source`, `columns`, or axes. The `url` field accepts **either** a
public remote URL **or an inline `data:image/png;base64,…` data URI** — data URIs POST cleanly
and render in both the app and PNG exports (live-verified 2026-07-10 against three ~100–200 KB
embedded PNGs; RE-verified 2026-07-11 in the stale-classification probe batch alongside
page/container `backgroundImage` data URIs; an earlier revision of this file claimed
hosted-URL-only, and a field run substituted plain text for a source's title art because it
trusted that claim — the docs still say "external URL only" and the docs are wrong).

**Mechanical path (v5.0):** build-charts-from-signals now does this automatically — every
Tableau bitmap zone is extracted from the .twbx to `<workdir>/assets/`, emitted as an
`img-<zoneid>` data-URI element, recorded in `<workdir>/image-assets.json`, and placed by
build-dashboard-layout at the zone's geometry. Full-canvas backgrounds (`is_background`) are
withheld from the grid and routed to page/container `backgroundImage`.

**Migrating Tableau image zones (logos, stylized titles, decorative art):** the source's bitmaps
ship inside the .twbx (`unzip -l workbook-content.twbx | grep -iE 'png|jpe?g'`). Extract each,
base64 it, and emit an image element:

```bash
b64=$(base64 < extracted/Image/title-art.png | tr -d '\n')
# → {"id": "img-title", "kind": "image", "url": "data:image/png;base64,'"$b64"'"}
```

```json
{
  "id": "img-logo",
  "kind": "image",
  "url": "https://example.com/logo.png"
}
```

> **Layering caveat:** Tableau floats images BEHIND other zones (z-stacked); Sigma's grid layout
> REJECTS overlapping elements, so background art cannot be layered under a chart or text as an
> image ELEMENT. But **pages and containers accept `backgroundImage`** — live-probed 2026-07-11:
> `page.backgroundImage = {url: <data URI or external URL>, style: {fit: contain|cover|none|
> scale-down|stretch, horizontalAlign/verticalAlign, tiling}}` POSTs, survives readback, and
> RENDERS behind the page's elements (data URI included — the docs' "external URL only" wording
> is wrong for backgroundImage too). Containers take the same shape alongside `style`. So the
> Tableau full-canvas designed-background pattern (Figma/PPT card art — parse-twb-layout flags
> these `is_background: true`, assets in `image-assets.json`) maps DIRECTLY to page/container
> backgroundImage. Composite art + text into one image only when the art must sit between two
> specific elements rather than behind a whole page/container.

In layout XML, image elements use a standard `<Element>`:
```xml
<Element elementId="img-logo" gridColumn="1 / 9" gridRow="1 / 9"/>
```

### Divider element

`{"id": …, "kind": "divider", "direction": "horizontal|vertical", "style": {"color": "#hex6",
"width": 1-4, "strokeStyle": "solid|dashed|dotted"}}` — live-verified POST + readback
2026-07-11. The stroke centers in its grid cell, so a 1-row `<Element>` renders a clean
hairline. This is the native target for Tableau's thin filled rules (spacers / childless
containers / blank-text bars ≤12px with a fill — `ZoneCensus.divider_zone?`); the layout
builder emits them automatically (`dv-<page>-<zone>` ids). Unfilled thin zones are true gaps
and stay dropped.

### Button element (workspace-gated)

`kind: "button"` ({text, appearance filled|outline|text, fillColor/fontColor, actions:
[{trigger: "on-click", effects: [{effect: "open-url", openTarget: "_self|_blank|_parent",
url}]}]}) is in the OpenAPI and passes spec/verify, but the live PUT is FEATURE-FLAGGED per
workspace (probed 2026-07-11: 400 "`button` elements are not enabled for this workspace").
Default emission for Tableau navigation buttons is therefore a **text-pill link**
(`[**Label**](url)` + pill background); set `SIGMA_BUTTON_ELEMENTS=on` to emit real buttons
on workspaces with the flag. Either way the URL is the placeholder
`https://nav.invalid/#page=<name>` — put-layout.rb rewrites it to the live workbook page URL
after publish (the URL doesn't exist until the POST returns). Export/toggle buttons emit
nothing (named residue in coverage.json).

### Container element

Uses `"kind": "container"`. Children are nested inside it via `<Container>` in the layout
XML (see the Container section in `refs/layout-grid.md`). Style + background image are spec-supported (live-probed
2026-07-11: pill radius + border + data-URI backgroundImage all render):

```json
{
  "id": "kpi-row",
  "kind": "container",
  "style": { "backgroundColor": "#112233", "borderRadius": "pill",
             "borderWidth": 2, "borderColor": "#52BAEE" },
  "backgroundImage": { "url": "data:image/png;base64,…", "style": { "fit": "cover" } }
}
```

`style` rules: `borderRadius` enum `square|round|pill`; `borderWidth` 1–3; border fields cannot
combine with `padding: 'none'` (schema-enforced XOR). This is the native target for Tableau
zone-style fills, borders, and the FCP `corner-radius` surface (parse-twb-layout emits
`fill_color`/`border_*`/`corner_radius` per zone; radius/height > 0.3 → `pill`, else `round`).

**Element titles can be hidden via spec**: `"name": { "visibility": "hidden" }` (live-probed,
survives readback, renders untitled) — use for Tableau tiles with hidden titles instead of
blank-name hacks.

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

Controls are fully supported via the spec API. In addition to the established
list/date/text/number/slider/top-N types below, the release publishes
`controlType: "drill"`. Tableau drill paths are detected, but the converter
does not emit an unattached drill control: each ordered category must align to
the correct target chart column IDs. Wire that mapping manually and verify
every target until the extractor can prove the alignment.

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
