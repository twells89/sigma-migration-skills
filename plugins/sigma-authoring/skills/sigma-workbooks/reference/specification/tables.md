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
> **Exclude a NULL/unwanted bucket** with an element list filter on the dimension — this is how a Tableau view filter maps: `filters: [{ id: f, columnId: col-flag, kind: list, mode: include, values: ["Cur FYTD", "Prior FYTD"] }]`. (A grouped bar that includes the NULL bucket is the classic "giant first bar" artifact.)

### `filters` (top-N, element-level row filters)

```yaml
filters:
  - id: top-20
    columnId: col-revenue
    kind: top-n
    rankingFunction: rank
    mode: top-n
    rowCount: 20
    includeNulls: when-no-value-is-selected
```

> **`rowCount` takes a number literal only** — it cannot be parametrized by a control. `rowCount: "[TopN]"` is rejected. Control bindings apply to filter **values**, not to structural fields like `rowCount`, `rankingFunction`, `mode`, or `kind`. To vary the cap interactively, duplicate the element per cap.

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
  - id: piv-cloud
columnsBy:
  - id: piv-env
    sort:
      direction: descending
```

`values` (required) is the measure column array — the cells of the pivot. `rowsBy` and `columnsBy` place dimension columns explicitly on the row and column shelves; each item is `{ id, sort? }`, where `sort` is `{ direction: ascending | descending, by?, aggregation? }` (`by` can be a column ID or `"row-count"`). Columns not listed on either shelf still render as available dimensions.

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

---

# Input tables

The `input-table` element is an editable table — users type values directly into cells, backed by a provisioned warehouse table. Required fields: `id`, `kind`, `source`, `inputMode`.

`inputMode` controls who can edit and where:

- `edit` — workbook editors only, in draft mode
- `explore` — users with explore permission or greater, in published view
- `view` — all users, in published view

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
