# Tables

Recipe book for `table`, `pivot-table`, and `input-table` elements + style and trap guidance. The full schemas live in the OpenAPI — fetch any element kind by its `kind` value:

```bash
jq --arg k pivot-table 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

Swap `pivot-table` for `table` or `input-table` to inspect the others.

The `table` element is the most common element kind and the primary way data enters a workbook — charts, KPIs, and other elements usually point their `source` at a table.

## Basic shape

```yaml
id: sales-table
kind: table
name: Sales Data
source:
  kind: warehouse-table
  connectionId: <conn-uuid>
  path: [DATABASE, SCHEMA, TABLE]
columns:
  - id: col-1
    name: Column Name
    formula: "[TABLE/column_name]"
  - id: col-2
    name: Total
    formula: Sum([Column Name])
order: [col-1, col-2]
```

See `sources.md` for all source kinds and `formulas.md` for the column-reference rules. Every column needs `id`, `name`, `formula`; optional `format` (see `formatting.md`).

For the `table` kind, `name` is a plain string. The styled title-section object (with `text`, styling, and `noDataText`) applies to `pivot-table` and `input-table` — see those sections below.

## Common optional fields

### `order`

Array of column IDs controlling left-to-right display order. Defaults to declaration order.

### `groupings`

Pivot / aggregation views without changing element kind:

```yaml
groupings:
  - id: by-region
    groupBy: [col-region]
    calculations: [col-total, col-profit]   # MUST be aggregate columns (Sum/Count/…)
    sort: [{ columnId: col-total, direction: descending }]   # optional
```

> **A `table` with no `groupings` shows raw DETAIL rows.** This is the #1 migration bug for aggregated source vizzes: a Tableau worksheet with a dimension on Rows + `SUM(...)` is an *aggregated* query, so its Sigma `table` MUST carry a `groupings` entry. Without it the table renders every warehouse row (e.g. "9,676,896 rows"), the dimension repeats, and `Sum(If(...))` columns read `$0` per row. If a "summary" table renders the base row count, it's missing `groupings`. (Charts don't need this — they aggregate by their axis/`value` binding; only `table` does.)
>
> **`calculations` columns must be AGGREGATE expressions** (`Sum([Amt])`, `CountDistinct([Id])`, …). A conditional aggregate is a **row-level** column `If(cond, [val], 0)` wrapped in `Sum(...)` at the grouping — i.e. `Sum([Cur Amt])` where `Cur Amt = If(flag = "Cur", [Tcv], 0)`. Do **not** put a *passthrough of an already-aggregated* column in `calculations`; it re-aggregates to **"multiple values"** in every group cell. (Verified 2026-06-15.)
>
> **Multiple `groupings` on one element NEST hierarchically** (array order = levels: `[by-region, by-flag]` ⇒ region→flag, not two independent rollups). For two *independent* group-bys (e.g. one table by Region and another by Flag) give each its **own source element**, or let a chart aggregate the second one by axis. (Verified 2026-06-15.)
>
> **Hide support/detail columns that are not on a grouping shelf.** A visible
> row-level measure outside `groupBy` / `calculations` can expose expandable
> detail alongside the grouped result, making a summary table appear to have
> hundreds of thousands of rows even though the aggregate cell is correct.
> Keep the raw measure for formulas when needed, but set `hidden: true`; show
> only grouping dimensions and aggregate calculations.
>
> **Exclude a NULL/unwanted bucket** with an element list filter on the dimension — this is how a Tableau view filter maps: `filters: [{ id: f, columnId: col-flag, kind: list, mode: include, values: ["Cur FYTD", "Prior FYTD"] }]`. (A grouped bar that includes the NULL bucket is the classic "giant first bar" artifact.)

### Visible-column budget

For an on-page lookup or operational list, keep roughly ten or fewer columns
visible. Put the stable key/name first, retain only decision-critical fields,
and move secondary attributes to a row-selection-driven detail table or
`single-row-container`. Above that width the first column and scan path tend to
truncate; cut columns rather than widening the page. This is an editorial
default, not an API limit—wide exact-detail exports and source-parity
migrations can be legitimate exceptions.

### `filters` — element-level column filters

`filters` is an **element-owned** array on `table`, `pivot-table`, `input-table`, charts, KPIs, and maps. Each entry scopes that element's rows. This is **not** the same as a `kind: control` element's `filters[]` (which is only `{ source, columnId }` wiring — see `controls.md`).

OpenAPI kinds (compiled workbook spec / Create workbook spec → Table.filters):

| `kind` | Typical column type | Purpose |
|---|---|---|
| `list` | text / number / date / boolean | Include or exclude discrete values |
| `top-n` | text / number / date | Rank and keep top/bottom N or percentile |
| `number-range` | number | Inclusive numeric bounds |
| `date-range` | date | Fixed or relative date window (same `mode` family as date-range **controls**) |
| `text-match` | text | String compare / contains / like / regexp |
| `hierarchy` | hierarchy | Include/exclude hierarchy paths (beta in product UI) |

Common fields on every entry: required `id` + `columnId` + `kind`; optional `state: enabled | disabled`. Most kinds also take `includeNulls: always | never | when-no-value-is-selected`.

> **One element filter per column.** To filter the same column twice, combine with a control or a quick filter in the UI — do not stack two `filters[]` entries on one `columnId`.
>
> Prefer a **control** when the user should change the predicate interactively. Prefer an **element filter** when the cut is fixed (migration view filters, top-N caps, scrubbing NULL buckets).

#### `list`

```yaml
filters:
  - id: f-flag
    columnId: col-flag
    kind: list
    mode: include            # include | exclude
    values: ["Cur FYTD", "Prior FYTD"]   # string | number | boolean | ISO date; null allowed
```

#### `top-n`

Two shapes (OpenAPI oneOf) — **row count** vs **percentile**:

```yaml
filters:
  - id: top-20
    columnId: col-revenue
    kind: top-n
    rankingFunction: rank          # rank | rank-dense | row-number
    mode: top-n                    # top-n | bottom-n
    rowCount: 20                   # number literal only — not a control binding
    includeNulls: when-no-value-is-selected
  - id: top-decile
    columnId: col-revenue
    kind: top-n
    rankingFunction: rank-percentile   # rank-percentile | cume-dist
    mode: top-percentile               # top-percentile | bottom-percentile
    percentile: 10
    includeNulls: when-no-value-is-selected
```

> **`rowCount` / `percentile` take number literals only** — `rowCount: "[TopN]"` is rejected. Control bindings apply to filter **values**, not structural fields (`rowCount`, `percentile`, `rankingFunction`, `mode`, `kind`). To vary the cap interactively, use a `controlType: top-n` control (`controls.md`) or duplicate the element per cap.
>
> A `top-n` (or other element filter) on a **parent directory does not flow
> through to a linked input table** (live generate-app verification). Cap the
> warehouse or SQL source — or a child table — *before* the `kind: linked`
> queue. See `input-tables.md`.

#### `number-range`

```yaml
filters:
  - id: f-qty
    columnId: col-quantity
    kind: number-range
    min: 4
    max: 10
    includeNulls: when-no-value-is-selected
```

Bounds are inclusive. Either bound may be omitted.

#### `date-range`

Same `mode` vocabulary as date-range **controls** (`between` | `on` | `before` | `after` | `last` | `next` | `current` | `custom`) with the same flat fields (`startDate`/`endDate`, `date`, `value`+`unit`+`includeToday`, relative `{ op, unit, value }` objects). See `controls.md` → Date Range for the mode table and examples; on an element filter they sit on the filter object (with `kind: date-range`), not on a control:

```yaml
filters:
  - id: f-last-90
    columnId: col-order-date
    kind: date-range
    mode: last
    value: 90
    unit: day
    includeToday: true
    includeNulls: when-no-value-is-selected
  - id: f-fy
    columnId: col-order-date
    kind: date-range
    mode: between
    startDate: "2026-01-01"
    endDate: "2026-03-31"
```

#### `text-match`

```yaml
filters:
  - id: f-name
    columnId: col-product-name
    kind: text-match
    mode: contains    # equals | does-not-equal | contains | does-not-contain |
                      # starts-with | does-not-start-with | ends-with | does-not-end-with |
                      # like | not-like | matches-regexp | does-not-match-regexp
    value: "Geek Squad"
    case: insensitive               # sensitive | insensitive
    includeNulls: when-no-value-is-selected
```

> OpenAPI uses `equals` / `does-not-equal` (not the Help UI labels "Equal to" / "Not equal to").

#### `hierarchy`

```yaml
filters:
  - id: f-geo
    columnId: col-geo-hierarchy
    kind: hierarchy
    mode: include                   # include | exclude
    values:
      - ["West"]
      - ["East", "New York"]        # each entry is a root→leaf path
```

Requires a real hierarchy-typed column. For interactive hierarchy picking across elements, prefer `controlType: hierarchy` (`controls.md`).

#### Inspect live shapes

```bash
# After fetching the compiled OpenAPI to /tmp/sigma-api.json (see SKILL.md):
jq --arg k table '
  first(.. | objects | select(.properties?.kind?.enum==[$k]))
  | .properties.filters
' /tmp/sigma-api.json
```

Human reference: Create workbook spec → Table.filters on the help site (`/reference/create-workbook-spec`). Product behavior overview: Data element filters (`/docs/data-element-filters`).

### `conditionalFormats` — cell coloring, gradients, and **data bars**

`conditionalFormats` works on `kind: table` (verified live 2026-06-24 — POST accepted, round-trips, and renders), not just `pivot-table` / `input-table`. The most-requested variant is **`dataBars`** — in-cell horizontal bars scaled to the column's value — which migrations frequently *drop* even though it's fully spec-authorable:

```yaml
conditionalFormats:
  - type: dataBars
    columnIds: [t-rev]                 # one or more aggregate/calculation columns
    scheme: ["#a4dfc0", "#4caf7d"]     # 2+ hex stops (low→high gradient); optional
    # optional: domain (value range), order, valueLabels
```

Place it at the element level (sibling of `columns` / `groupings`), targeting the grouping's calculation column(s) by id. Other variants (`single` threshold rules, `backgroundScale`, `fontScale`) are below. Pull the full per-type field set with the `conditionalFormats` property via the `kind`-form recipe at the top.

> **Round-trip caveat:** data bars **authored via spec** persist on `GET`. Data bars **added in the Sigma editor** may *not* appear in `GET /spec` (observed on a converted workbook) — so don't infer "the source had no data bars" from a readback. When migrating, author them explicitly.

### `tableStyle` — presentation preset, spacing, grid lines, banding

`tableStyle` is an element-level object on `table` / `pivot-table`. The default is the dense **spreadsheet** grid; `preset: presentation` switches to the roomier, lighter "presentation" look (taller rows, softer borders) that source BI tools often use for dashboard tables. **Spec-authorable, round-trips, and renders** (verified live 2026-06-24) — but, like data bars, an editor-set value may be absent from `GET /spec`, so author it explicitly when migrating.

```yaml
kind: table
tableStyle:
  preset: presentation          # 'spreadsheet' (default) | 'presentation'
  cellSpacing: medium           # extra-small | small | medium | large
  gridLines: horizontal         # none | vertical | horizontal | all
  banding: shown                # row banding: shown | hidden
  # also: bandingColor, outerBorder, headerDividerColor, autofitColumns,
  #       heavyVerticalDividers / heavyHorizontalDividers (pivot only), textStyles
```

All fields are optional; omit `preset` for the spreadsheet default. Pull the full enum set via the `kind`-form recipe at the top.

### `columnSecurities`

Column-level security on a table element uses the same `columnSecurities` criteria shapes as a data-model table element — see `sigma-data-models/reference/column-level-security.md`. Confirmed byte-identical against the live OpenAPI schema (2026-08-03), and confirmed live create + readback round-trips exactly. This field is only present on `table`, not `pivot-table` or `input-table`.

---

# Pivot tables

The `pivot-table` element is a sibling of `table` for cross-tab analysis — measure cells aggregated across one or more row/column dimensions.

## Shape

```yaml
id: deployments-pivot
kind: pivot-table
name: Deployments by cloud and env
source:
  kind: table
  elementId: deployments-source
columns:
  - id: piv-cloud
    name: Cloud
    formula: "[Deployments/Cloud]"
  - id: piv-env
    name: Environment
    formula: "[Deployments/Environment]"
  - id: piv-count
    name: Deployments
    formula: CountDistinct([Deployments/Deployment UUID])
    format:
      kind: number
      formatString: ",.0f"
values: [piv-count]
rowsBy:
  - columnId: piv-cloud
columnsBy:
  - columnId: piv-env
    sort:
      direction: descending
```

`values` (required) is the measure column array — the cells of the pivot. `rowsBy` and `columnsBy` place dimension columns explicitly on the row and column shelves; each item is `{ columnId, sort? }`, where `sort` is `{ direction: ascending | descending, by?, aggregation? }` (`by` can be a column ID or `"row-count"`). **Do not use `{ id }` on these shelves** — that shape is a 400 (`Invalid kind: "pivot-table"`). Columns not listed on either shelf still render as available dimensions.

## `conditionalFormats` — threshold coloring on cells

Available on `table`, `pivot-table`, and `input-table` (the `table` support is verified live — see the table `conditionalFormats` note above). Apply background/text styling per cell based on column values. Variants include `single`, `backgroundScale`, `fontScale`, and `dataBars` — covering threshold rules, gradient scales, font-color scales, and inline data bars. Inspect the OpenAPI for the full operator + style enums (use the `conditionalFormats` property on the element schema).

**Recipe — red/green threshold coloring on a revenue column:**

```yaml
conditionalFormats:
  - type: single
    columnIds: [col-revenue]
    condition: ">"
    value: 1000
    style:
      backgroundColor: "#22c55e"
  - type: single
    columnIds: [col-revenue]
    condition: "<"
    value: 100
    style:
      backgroundColor: "#ef4444"
```

Condition operators include `=`, `!=`, `>`, `>=`, `<`, `<=`, `IsNull`, `IsNotNull`, `Contains`, `NotContains`, `StartsWith`, `EndsWith`, `Between`, `NotBetween`, and `formula` (arbitrary boolean). Style block supports `backgroundColor`, `color`, `bold`, `italic`, `underline`, and column-level `format` override.

GET may stringify `value` (`"0"`). Later PUTs sometimes want a number `0`
and sometimes the string — re-type from the 400 rather than echoing
readback blindly.

---

# Input tables

The `input-table` element is an editable table — users type values directly into cells, backed by a provisioned warehouse table. Required fields: `id`, `kind`, `source`, `inputMode`.

`inputMode` is required and accepts `edit`, `explore`, or `view`. It does
**not** decide whether users can type into the published workbook.

Published data entry is a separate UI-only setting on each input table:

```text
element kebab → Set data entry permission
              → Only in draft              # default
              → Only in published version
```

Live verification found that all three `inputMode` values remained inert in
published view while the permission stayed at its default. Flipping one table
made only that table editable, while `GET /spec` stayed byte-identical. Code
Rep therefore cannot set or inspect this permission. Every spec-built
writeback app needs this manual step per input table before handoff.

`source` is one of:

- `{ kind: empty, connectionId: <YOUR_CONNECTION_ID> }` — provisions a fresh, blank warehouse table.
- `{ kind: linked, from: <elementId> }` — rows are linked to another element, matched to source rows by the `key` columns. ⚠ A linked input table carries its **own** `connectionId` (the write target); it is NOT simply inherited from the parent and may differ from the parent's connection — cross-connection linking (write-conn child, read-conn parent) is supported. See `input-tables.md` → *Cross-connection linked tables*.

`columns[]` items come in four shapes (each also accepts optional `name`, `description`, `hidden`, `format`):

- **System column** — `{ id }` where `id` ∈ `ID`, `CREATED_AT`, `CREATED_BY`, `UPDATED_AT`, `UPDATED_BY`. Protocol-managed; type is fixed.
- **Key column** — `{ id, key }` binding to a source column on `source.from` (linked tables; `key` is immutable once created).
- **Editable data column** — `{ id, type }` where `type` ∈ `text`, `number`, `datetime`, `checkbox`, `multi-select`, `file`.
- **Formula column** — `{ id, formula }` for a computed column.

**Column validation (2026-06-18 release; all verified round-tripping):**

- **Single-select dropdown** — a scalar column + a fixed option list: `{ id, type: text, values: ["A", "B", "C"] }` (also `number`/`datetime`). There is **no** `single-select` type token — the `values` list is what makes it a dropdown.
- **Multi-select** — `{ id, type: multi-select, values: [...] }`. **Variant-backed** — needs a variant-capable warehouse (e.g. Snowflake).
- **Range bounds** — `{ id, type: number, range: { min, max } }` (also `datetime`, which normalizes to `…T00:00:00Z`).
- **Options from a sibling element** — `{ id, type: text, valuesFrom: { element: <elementId>, column: <columnId> } }` (single- or multi-select). Keys are `element`/`column`, **not** `elementId`/`columnId`.
- **Pills** — render a select column as pills: `{ ..., pills: single-color }` or `{ ..., pills: color-by-option }` (enum string).
- **File upload** — `{ id, type: file, maxFileNum: 3, maxFileSizeMb: 10, acceptedFileTypes: ["image/png", "application/pdf"] }`. **Variant-backed.**
- **One validation slot:** `values` / `valuesFrom` / `range` are mutually exclusive on a column — combining them is a 400.

```yaml
id: feedback-input
kind: input-table
name: Manual feedback
inputMode: edit
source:
  kind: empty
  connectionId: <YOUR_CONNECTION_ID>
columns:
  - id: ID
  - id: customer
    type: text
  - id: score
    type: number
  - id: flagged
    type: checkbox
  - id: score-bucket
    formula: If([score] >= 8, "Promoter", "Other")
```

`input-table` also supports `filters`, `conditionalFormats` (see above), `sort`, `summary`, and the styled title-section `name`/`noDataText`. Fetch the full schema with the `kind`-form recipe at the top of this doc.

Creating this element defines its structure; it does not bulk-populate rows.
For the supported population decision tree—and why unions, joins, and actions
are not interchangeable seeding strategies—read `input-tables.md` before
building a writeback workflow.
