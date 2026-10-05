# Sources (non-warehouse)

Recipe book for source kinds other than `warehouse-table`. For the canonical schema of any source kind, pull it by its `kind` value (`warehouse-table`, `sql`, `table`, `data-model`, `join`, `union`, `transpose`, `csv-table`, `metric-view`, `semantic-view`):

```bash
jq --arg k join 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

Every element with columns has a `source` that defines where its data comes from. This file focuses on the **patterns** and **formula-prefix conventions** for each non-warehouse source kind — the parts the OpenAPI alone won't teach.

**For warehouse-table** — the most common source — see the dedicated `sources-warehouse.md`. It's loaded by default because nearly every workbook uses it.

**For discovery** (finding connection IDs, paths, data model IDs, element IDs) see `reference/workflows/discover.md`.

---

## table (cross-element reference)

Sources another element in the same workbook. This is the most common source kind for charts, KPIs, and derived tables.

```yaml
kind: table
elementId: <id of another element on some page>
```

Column formulas reference that element's columns using its `name`:
- Element named "Sales Table" → `[Sales Table/Revenue]`

## data-model

References an element from an existing data model. **Prefer this source kind when the user's org has relevant data models** — it inherits the data model's joins, filters, and column-level security, which is usually closer to what the user wants than re-deriving from raw warehouse tables. Discover available models with `GET /v2/dataModels`; if none are relevant, fall back to `warehouse-table` rather than trying to manufacture a model.

```yaml
kind: data-model
dataModelId: <data-model-uuid>
elementId: <element-uuid within that model>
```

Optionally add `groupingId` to apply one of the model element's groupings.

Resolve `elementId` and the element's exposed column names with `GET /v2/dataModels/{id}/elements` (see `reference/workflows/discover.md`). Columns reached through a relationship carry a `(SOURCE)` join-leg suffix that formulas must reproduce exactly.

## join

Joins multiple sources into one logical source via an array of `joins`. Each leg (`primarySource`, `left`, `right`) can be any source kind, so warehouse tables, other elements, and data-model elements can be joined interchangeably.

Only `joins` (with each entry's `left`, `right`, `columns`) is required. `primarySource` is optional — if omitted, Sigma infers it as the source that appears on the left of some join but never on the right. Each join's `name` (used as the formula prefix — `[<name>/column]`; defaults to the right source's name) and `joinType` (defaults to inner) are also optional.

```yaml
kind: join
name: Sales Star
primarySource:
  kind: warehouse-table
  connectionId: <conn-uuid>
  path: [DB, SCHEMA, F_POS]
joins:
  - name: Sales
    joinType: left-outer
    left:
      kind: warehouse-table
      connectionId: <conn-uuid>
      path: [DB, SCHEMA, F_POS]
    right:
      kind: warehouse-table
      connectionId: <conn-uuid>
      path: [DB, SCHEMA, F_SALES]
    columns:
      - left: "[Order Number]"
        right: "[Order Number]"
```

Each entry in a join's top-level `columns[]` is a join-key pair (`left`/`right`, with an optional `op` for non-equi joins) — a different shape from an element's `columns[]` (see below). Pull `joinType` values and the column-pair shape from the spec via the recipe at the top.

### Join groupings

A join leg that references another workbook table can pin one of that table's
groupings with `groupingId`:

```yaml
left:
  kind: table
  elementId: orders-summary
  groupingId: by-customer
```

The grouping changes the rows/columns exposed by that leg, so join keys and
downstream formulas must resolve against the grouped output, not the table's
ungrouped base columns. Preserve `groupingId` on readback and verify the
compiled join SQL; a structurally valid grouping does not prove the join
cardinality is correct.

**Column formula prefixes with joins** — see `formulas.md` for the full rules:
- Primary-source columns use the **join's top-level `name`**: `[Sales Star/Order Number]`
- Joined-table columns use the **join leg's `name`**: `[Sales/Cust Key]`
- Warehouse path segments are **not** used as prefixes inside a join.

## sql

A custom SQL query against a connection — `kind: sql` with `connectionId` + `statement`. Pull the shape from the spec via the recipe.

Column formulas use the literal prefix `Custom SQL` and the query's exact
output alias: `[Custom SQL/order_month]`. Do not apply warehouse friendly-name
canonicalization to SQL aliases.

Custom SQL statements can bind workbook controls with
`{{<controlId>}}`. `controlId` is the control's formula handle, not its element
`id`. Read back and query the element after POST: template text can survive
serialization even when the runtime binding or SQL type is wrong.

## csv-table

References a CSV file uploaded directly into Sigma, not a table synced from a connection.

```yaml
kind: csv-table
connectionId: <conn-uuid>
inodeId: <csv-file-inode-uuid>
```

The `inodeId` is scoped to the workbook it was uploaded into — it doesn't resolve against another workbook's copy of the same file (live-verified: reusing one elsewhere fails with `CSV table does not belong to this workbook`). No REST endpoint uploads a CSV, and `GET /v2/files` doesn't list these inodes; find one by reading an existing workbook's spec, or upload via the UI. Column formula prefix is the CSV filename, e.g. `[sigma_demo_users.csv/user_id]`.

## metric-view

References a Databricks metric view — a governed dimensions+measures object native to Databricks, not something authored through Sigma's data-model `metrics` block. Same `path`-array shape as `warehouse-table`; Sigma resolves it through a connection's object hierarchy the same way it resolves a table.

```yaml
kind: metric-view
connectionId: <conn-uuid>
path: [CATALOG, SCHEMA, METRIC_VIEW_NAME]
```

Live-verified: a real metric view builds and reads back; a bogus path is rejected server-side (`metric-view not found: ...`). This org had no REST-exposed way to introspect the view's own dimension/measure names, so populate `columns[]` from names you already know.

## semantic-view

References a Snowflake semantic view — same governed, platform-native pattern as `metric-view`. Per spec, the final `path` segment names the view's **base logical table**, distinct from the view itself.

```yaml
kind: semantic-view
connectionId: <conn-uuid>
path: [DATABASE, SCHEMA, SEMANTIC_VIEW_NAME]  # final segment = base logical table, per spec
```

A real semantic view exists and resolves in this org, but creating a workbook element against it returned `` `semantic-view` sources are not enabled for this workspace `` — a workspace-level feature flag, independent of the object being real. Unverified end-to-end here; shape above is spec evidence plus that live lookup, not a full create+readback.

## transpose

Pivots a source's rows and columns. Needs a `source` (any source kind) plus a direction config — `row-to-column` (pivot wider) or `column-to-row` (unpivot longer), each with its own fields. Pull the per-direction shape from the spec via the recipe.

## Element `columns[]` vs. join `columns[]`

Two unrelated things share the name. An element's `columns[]` is its **output columns** (each a `formula`); a join source's top-level `columns[]` is its **join keys** (`left`/`right` pairs). Don't conflate them.

## union

Combines two or more sources (`warehouse-table`, `table`, or `data-model`) into a single source whose columns are explicitly mapped via `matches[]`.

```yaml
kind: union
name: All Sales
sources:
  - kind: warehouse-table
    connectionId: <conn-uuid>
    path: [DB, SCHEMA, JULY_SALES]
  - kind: warehouse-table
    connectionId: <conn-uuid>
    path: [DB, SCHEMA, AUGUST_SALES]
matches:
  - outputColumnName: Order ID
    sourceColumns:
      - '[Order ID]'   # column from the first source
      - '[Order ID]'   # column from the second source
  - outputColumnName: Sales
    sourceColumns:
      - '[Sales]'
      - '[Sales]'
```

`sourceColumns` is an array aligned to `sources` — one entry per source, in order. `outputColumnName` becomes the column users see and the name your element formulas reference.

**Set `name` explicitly.** Formula prefixes for the consuming element use the union's `name`, e.g. `[All Sales/Order ID]`. If you omit `name`, Sigma assigns `"Union of N Sources"`; if your element also defines a column whose `name` matches an `outputColumnName`, a bare `[Order ID]` formula becomes a circular self-reference and the SQL fails to compile. See `formulas.md` > Union source.
