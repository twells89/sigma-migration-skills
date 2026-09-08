<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Split from refs/workbook-layout.md (E9.3 phase-scoped refs, 2026-07-27): this file owns multi-series chart patterns (trellis, area, combo, scatter, refMarks, trendlines, axis format, dual-axis, data labels) and map elements. Siblings: twb-zone-mapping.md (.twb zone tables), layout-grid.md (grid + layout XML), element-kinds.md (element/control field requirements). -->

# Chart patterns — multi-series + maps

> **Read at Phase 5** (chart building). Spec shape lives in `sigma-workbooks` —
> this file is Tableau-conversion-specific; when it disagrees with the
> sigma-workbooks reference, that reference wins.

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
- `label.visibility` **must be `"shown"`** on a `refMarks` label. Although the UI exposes a hide toggle, the **spec API rejects `"hidden"`** with `Invalid value: object` (verified; the readback shows `shown`). To visually de-emphasize a reference line, keep `visibility: "shown"` and give it a short `label.text` (e.g. `"Avg monthly"`) rather than trying to hide it. `label.text` is optional — Sigma renders a sensible default when absent.
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
- **Dual-axis contract** (live-verified 2026-07-10): `yAxis.columnIds` lists **ALL** series (typed `{columnId, type}` entries on combo charts); `yAxis2.columnIds` is a **plain-string subset** naming which of those series ride the right axis. A `yAxis2` id absent from `yAxis` → 400 `"'<id>' is not listed on yAxis.columnIds"`; a typed object inside `yAxis2` → 400 `"Invalid string: object"`. Element-level `filters[*]` entries also require an explicit `id` (400 `"filters[N].id: Invalid string: undefined"` without one).

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

> **Disregard older guidance that said "Sigma spec does not support maps."** Both kinds are real spec elements, persist on round-trip, and render correctly when published. Verified May 2026 against `ab12cd34-...` (`region-map`/`us-state` and `us-zipcode`) with live data parity confirmed via `mcp__sigma-mcp-v2__query`.

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
  "region": {"columnId": "rm-state", "regionType": "us-state"},
  "label":  [{"columnId": "rm-count"}]
}
```

| Field | Required | Shape | Notes |
|---|---|---|---|
| `region` | yes | `{columnId, regionType}` | `columnId` is the column ID holding the region key |
| `label` | optional | array `[{columnId}, ...]` | Values rendered on each region; usually the measure |
| `tooltip` | optional | array `[{columnId}, ...]` | Extra columns shown on hover (e.g., active count, avg salary) |
| `color` | optional | `{by: "category", column: <colId>}` or `{by: "scale", column: <colId>}` | Two spec-supported modes. **`by: "category"`** — categorical fill, one color per category; column must be a **different** column from `region.columnId` (the API rejects reuse with "Column X is referenced from both 'region' and 'color'"). **`by: "scale"`** — sequential value-gradient fill (Tableau-style choropleth heat scale) **IS spec-supported** (live-verified 2026-07-07: a us-state choropleth with a white→navy sequential fill rendered correctly and round-tripped through GET; 49/49 state values exact). An earlier version of this file claimed gradients were UI-only — that claim is stale. **`by: "value"` remains rejected** with HTTP 400 — use `by: "scale"` for value-driven fills. With `color` omitted the map renders a uniform fill (NOT auto value-based heat). |
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
  "latitude":  {"columnId": "p-lat"},
  "longitude": {"columnId": "p-lng"},
  "size":      {"columnId": "p-sz"},
  "color":     {"by": "category", "column": "p-cat"},
  "label":     [{"columnId": "p-sz"}]
}
```

| Field | Required | Shape |
|---|---|---|
| `latitude` | yes | `{columnId}` — object, not array |
| `longitude` | yes | `{columnId}` |
| `size` | optional | `{columnId}` — bubble size encodes a measure |
| `color` | optional | `{by: "category", column: <colId>}` — same shape as bar/line color (`by: "value"` is **rejected** on `point-map`; only category coloring is wired up via spec) |
| `label` | optional | array `[{columnId}, ...]` |

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
