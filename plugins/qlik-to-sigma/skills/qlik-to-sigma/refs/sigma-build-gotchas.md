# Sigma build gotchas (Qlik→Sigma) — learned the hard way

Every rule here cost an iteration on the first validated migration. They are the
difference between a POST that 2xx's but renders `error` columns / wrong numbers,
and a migration that matches the warehouse to the cent.

## Converter input — feed the Qlik MODEL, not the warehouse
`convert_qlik_to_sigma` builds relationships from **shared field names**. The Qlik
LOAD script renames/drops fields precisely to avoid associative collisions, so the
*post-rename* model yields a clean star. Raw warehouse column names re-introduce the
collisions the LOAD script removed:
- `CITY`/`STATE`/`REGION` shared across CUSTOMER_DIM + STORE_DIM → spurious dim↔dim relationships.
- `UNIT_COST`/`UNIT_PRICE` shared ORDER_FACT + PRODUCT_DIM → spurious join.
- Keys that don't match (`ORDER_STORE_KEY` vs `STORE_KEY`) → *missing* relationships.

So: build the converter `tables` input from the Qlik load-script field names
(`ORDER_STORE_KEY AS STORE_KEY`, `REGION AS CUSTOMER_REGION`, drop `UNIT_COST` from dims).
Result on the first run: exactly 5 clean relationships, 12 metrics, 1 Set-Analysis warning.

## Reconcile to real warehouse columns before POST
The converter assumes Qlik field == warehouse column, but the LOAD renamed some.
When you author the final DM against `warehouse-table` elements, point the renamed
ones back at real columns:
`STORE_KEY→ORDER_STORE_KEY`, `DATE_KEY→ORDER_DATE_KEY`, `CUSTOMER_REGION/STORE_REGION→REGION`,
`PROMO_CHANNEL→CHANNEL`. Relationships reference column **ids**, so repointing a
column's formula keeps the join intact. (Alternatively make every element a custom-SQL
element reproducing the LOAD — then Qlik names resolve verbatim; see below.)

## Custom-SQL element (the LOAD-script analog)
A Qlik LOAD `SELECT ... AS ... FROM t` becomes a Sigma SQL element. Rules:
- `source: { "connectionId": "...", "kind": "sql", "statement": "<SQL>" }`
  — the field is **`statement`**, NOT `sql`. (`sql` → `400 source.statement: Invalid string: undefined`.)
- Column formula = **`[Custom SQL/<RAW_SQL_ALIAS>]`** (the element auto-names itself
  "Custom SQL"; the alias is the raw SQL output column, e.g. `NET_REVENUE`).
  Do **NOT** use bare `[Net Revenue]` for the base columns — that creates empty
  `Calc`/`Calc (1)` columns that all type as `error`.
- Give each column a `name` (the display name) so workbook refs read cleanly.
- A **denormalized** SQL element (fact LEFT JOIN all dims) is the most reliable
  master for workbook charts — one element with every dimension + measure, so charts
  just group by `[col]`. This is the same pattern Sigma's own Power-BI import uses.

## Metrics
- Use Sigma functions: **`CountDistinct([Order Id])`**, not `Count(DISTINCT ...)`.
- Reference columns by bracketed display name: `Sum([Net Revenue])`.
- Place a metric on the element that owns its referenced columns (ORDER_FACT).
- `metric('<id>', t)` in a `sigma-mcp-v2` data-model query returns **"Missing Metric"**
  even for ids that `describe` lists under AVAILABLE METRICS (confirmed 2026-06-03).
  For parity, **aggregate the element's raw columns directly** —
  `SELECT SUM("<netRevColId>"), COUNT(DISTINCT "<orderIdColId>"), SUM("<netProfitColId>")/SUM("<netRevColId>") FROM "datamodel"."<elementId>" t`
  (get the opaque colIds from `describe(datamodel-element)`). The metric formulas are
  still valid — the failure is only the `metric()` resolver. The REST export API
  (`POST /v2/workbooks/{id}/export` → poll `GET /v2/query/{queryId}/download`) is an
  equally good parity path and reads the workbook element's *applied* aggregation.

## Workbook spec
- Master table (on a hidden "Data" page) sourcing a DM element needs **all three**:
  `source: { "dataModelId": "<dm>", "elementId": "<elem>", "kind": "data-model" }`
  plus a `columns: [{id, name, formula: "[<DM element name>/<col display name>]"}]` array
  (omitting `columns` → `400 columns: Invalid array: undefined`).
- Charts source the master: `source: { "elementId": "m-ofv", "kind": "table" }`,
  formulas `Sum([OFV/Net Revenue])` (`OFV` = the master's `name`).
- **kpi-chart**: `columns:[{id,formula,name,format}]` + `value:{columnId}` — NOT
  `value:{id}`; the live API 400s with `value.columnId: Invalid string: undefined`
  (validate-spec misses it; pie/donut `value` keeps `{id}` — the key differs by kind).
- **bar-chart / line-chart**: `columns:[dimCol, measCol]` + `xAxis:{columnId}` + `yAxis:{columnIds:[...]}`.
- Number format: `format:{kind:"number","formatString":"$,.0f"}` (or `,.1%`, `,.0f`).

## Workbook master references DM columns by DISPLAY NAME
A workbook master table sourcing a data-model element references its columns as
`[<DM element name>/<column DISPLAY name>]` — e.g. `[Custom SQL/Net Revenue]`,
**not** the raw SQL alias `[Custom SQL/NET_REVENUE]` (→ `400 dependency not found`).
The chart formulas then use `[<master name>/<col>]`, e.g. `Sum([OFV/Net Revenue])`.

## Building the Qlik SOURCE fixture: charts must be `auto-chart`
(Only relevant when building a Qlik app to migrate FROM, not for reading one.)
Concrete chart types created via the API (`barchart`/`linechart`/`table`) render
**blank** (title/frame only) without Qlik's full native nebula property tree —
impractical to author blind. Use `qInfo.qType: "auto-chart"` + `visualization:
"auto-chart"` + the hypercube (dims+measures, each with a `cId`) + `showTitles`/
`title`. `auto-chart` == the "Chart suggestions ON" renderer; it draws straight
from the hypercube and auto-picks the viz. KPIs render fine as concrete `kpi`.
Also: a Qlik sheet only renders charts that are its **children** (`qChildren` in a
GenericObjectEntry, sheet needs `qChildListDef`), and API-created *sheets* don't
list in the hub — graft onto a **UI-created native sheet** instead.

## Aggregating elements need an explicit dimension→measure declaration
- **bar/line**: `xAxis.columnId` + `yAxis.columnIds`.
- **table**: a `groupings` array — `groupings: [{ id, groupBy: [<dim col ids>],
  calculations: [<measure col ids>] }]`. WITHOUT it, a `table` with dim +
  `Sum(...)` columns renders **one row per source row** (no roll-up). With it, the
  table groups by `groupBy` and aggregates `calculations` (a "level table"). This
  is the faithful match for a Qlik straight-table / Tableau text-table.
- **pivot-table**: `rowsBy` + `columnsBy` (`[{id}]`) + `values` (see feedback_sigma_pivot_rowsby_columnsby).
- KPIs need ≥5 grid-rows of height or the title clips.

## Sorting a GROUPED table — sort lives INSIDE the grouping (verified 2026-06-10)
Element-level `sort:[{columnId,direction}]` works only on UNGROUPED tables. On a table
with `groupings`, the POST 400s with `Sort column not found` for **both** groupBy and
calculation column ids. The shape that posts, round-trips on GET (gains `nulls:
"connection-default"`), and actually orders the groups is the sort nested in the
grouping entry:
`groupings: [{id, groupBy: [...], calculations: [...], sort: [{columnId: <calc or dim col id>, direction: "descending"}]}]`.
Charts keep using `xAxis.sort: {by, direction}` / pie-donut `color.sort`.

## Excluding a null/unmatched group — element list-filter
To drop a null dimension bucket (e.g. fact rows whose FK didn't match a dim under a
LEFT JOIN), add an element filter (verified shape):
`filters:[{id, columnId:<dim col id>, kind:"list", mode:"include", values:[...real values...]}]`.
`mode:"include"` with the explicit value list excludes null/unmatched.

## Layout is a SEPARATE step — don't skip it
Posting chart elements WITHOUT a layout makes Sigma auto-stack them full-width
(formatting is fine, arrangement is not). Apply a 24-col grid as a single
`document.layout` XML string (NOT per-page), via the vendored `scripts/vendor/put-layout.rb`:
```
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-overview">
  <Element elementId="<id>" gridColumn="1 / 9"  gridRow="1 / 4"/>   <!-- KPI -->
  ...
</Page>
```
Grid lines are **1-based** (24 cols → lines 1..25; full width = `1 / 25`). 0-based
coords → `400 Invalid element position`. `put-layout.rb` GETs the spec (Accept:
application/json → JSON), deletes per-page layouts, sets `document.layout`, strips
read-only fields, PUTs back. Map the Qlik sheet's cell rectangle to grid lines.

**Multi-page layout** = multiple `<Page>` nodes concatenated in the ONE
`document.layout` string (after the single `<?xml …?>` declaration) — one `<Page id=…>`
per workbook page, matched by page id. Verified live (6-page workbook, 2026-06-10).
A Qlik sheet's cell grid (`columns`×`rows`, usually 24×N) maps 1:1 onto Sigma's
24-col grid: `gridColumn = col+1 / col+colspan+1`, `gridRow = row*2+1 /
(row+rowspan)*2+1` (row-scale ≥2; bump KPIs to ≥5 rows for the title).

## API quirks
- `POST /v2/dataModels/spec` and `/v2/workbooks/spec` **return YAML, not JSON**
  (`success: true\nworkbookId: ...`). Don't `json.loads` the response; parse YAML or grep.
- POST body for DM (unaffected, stays flat): `{folderId, schemaVersion:1, name, pages:[...]}`.
  **For workbook, the body is `document`-wrapped** (verified live 2026-08-03, including on
  `/verify` 2026-08-04): `{name, folderId, document: {schemaVersion:1, pages:[...]}}` — the
  old flat `{name, folderId, schemaVersion:1, pages:[...]}` now 400s. Don't confuse the two
  surfaces; only the workbook one wraps.
- Element/column ids are **reassigned on save** — always `describe(datamodel)` →
  `describe(datamodel-element)` to get the real ids before querying.

## Set Analysis → SumIf (VALIDATED)
`Sum({<IS_HOLIDAY={1}>} NET_REVENUE)` → **`SumIf([OFV/Net Revenue], [OFV/Is Holiday] = 1)`**
works exactly (verified: 3,314.99 == Snowflake). Put the flag column on the same
(denormalized) element so it's not cross-element. Pattern generalizes: Set Analysis
`{<Field={v}>}` → `SumIf(measure, [Field] = v)` / `CountIf(...)`.

## Varied chart-type shapes (all verified to persist + render)
- **pie-chart / donut-chart**: `value:{columnId:<measureCol>}` + `color:{columnId:<dimCol>}` (NOT xAxis/yAxis). Donut `holeValue:{columnId:<a DIFFERENT col>}` (e.g. an Orders count) — if holeValue.columnId == value.columnId the API rejects the collision. `{ id }` on these channels is a 400.
- **combo-chart**: `xAxis:{columnId}` + `yAxis:{columnIds:[<barColId>, {columnId:<lineColId>, type:"line"}]}` — bare string = left/bar, object = right/line.
- bar/line/area/scatter: xAxis + yAxis.columnIds.
Qlik source charts are `auto-chart` (only thing that renders via API); the Sigma target
can use the full range — so a migration can *upgrade* viz types (category share → pie, etc.).

## Multi-page workbook + extending the denorm element
One workbook, N pages: `pages:[{id,name,elements}, ...]` with a hidden Data page holding
the master. To add fields for new pages, PUT the DM spec with the SQL element's
`source.statement` extended + new `{id,name,formula:"[Custom SQL/<RAW>]"}` columns —
in place (keeps element/column ids, so existing workbooks stay intact).

## Verified reference artifacts (first migration)
- Data model `d44b8ee2-9849-4cea-b5b9-37404ef83ae5` · workbook `34e16b0c-60ab-40db-b6b3-661a64030ef8`
- Org: the demo Sigma org, folder `<folder-id>`, connection `<connection-id>` (Snowflake DEMO_DB.DEMO)
- Parity (Sigma == Snowflake == Qlik): Net Revenue 105,108.75 · Orders 613 · Net Profit 65,561.32 · Margin 62.37%.
