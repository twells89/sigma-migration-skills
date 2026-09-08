# ThoughtSpot Liveboard → Sigma workbook — spec shapes

The exact Sigma workbook-spec shapes the builder (`ts_common.py` /
`migrate.py`) emits, all live-verified (POST → readback). Get these wrong and
Sigma either 400s at POST or **silently degrades** (pivot collapses to one
cell, KPI fails validation only at POST, sorts dropped).

> **The workbook body is `document`-wrapped, not flat** (verified live 2026-08-03,
> including on `POST /v2/workbooks/spec/verify` 2026-08-04): outer metadata is
> `{name, folderId, description?}` and the required inner shape is
> `document:{schemaVersion, kind:"workbook", pages, elements, layout}`.
> `document.elements[]` is one flat collection; pages are metadata-only and
> MUST NOT contain `elements`. Layout is authoritative and must place every
> element exactly once. Data-model specs (`POST /v2/dataModels/spec`) remain flat
> and retain their existing `pages[].elements` shape.

## Chart-kind map

| ThoughtSpot | Sigma | Notes |
|---|---|---|
| KPI | `kpi-chart` | value is `{"columnId": c}` — NOT `{"id": c}` |
| COLUMN / BAR / STACKED_* | `bar-chart` | `orientation` enum is `"horizontal"`-only; omit for vertical |
| LINE | `line-chart` | |
| PIE / DONUT | `donut-chart` | TS renders pies as donuts; `value`/`color` use `{"id": c}` — NOT `{"columnId": c}` |
| AREA / STACKED_AREA | `area-chart` | |
| WATERFALL | `waterfall-chart` | native x/y shape; advanced subtotal fields require source split/multi-series semantics |
| SCATTER / BUBBLE | `scatter-chart` | two measures x/y + optional category `color` |
| LINE_COLUMN | `combo-chart` | first measure bare string in `yAxis.columnIds`, rest `{"columnId", "type": "line"}` |
| GEO_AREA / GEO_BUBBLE | `region-map` | `region: {id, regionType}`; regionType inferred from the geo field name |
| PIVOT_TABLE | `pivot-table` | see below |
| TABLE / ADVANCED_COLUMN | grouped `table` | see below |
| WHISKER_SCATTER (box plot) | flagged `table` | explicit fallback: published Sigma workbook schema has no box-chart kind |
| funnel / treemap / heat-map / sankey / gauge | flagged `table` fallback | data preserved; no misleading chart coercion |

## The asymmetric column-ref shapes (the #1 trap)

- **KPI**: `"value": {"columnId": cid}` (kpis.md docs are stale; `{id}` fails at POST,
  validate-spec misses it).
- **Donut/pie**: `"value": {"columnId": vid}, "color": {"columnId": cid}` (same pointer key as KPI).
- **Pivot**: `rowsBy`/`columnsBy` are arrays of **`{id}` objects**, `values` is an
  array of **bare column-id strings**. Omitting rowsBy/columnsBy silently collapses
  the pivot to a single grand-total cell.
- **Grouped table**: `"groupings": [{"id", "groupBy": [dimId], "calculations": [measureIds]}]`.

## Column ORDER (tables)

Use the answer's **`table.ordered_column_ids`** for column order — `answer_columns`
is alphabetical and `chart.chart_columns` follows the chart axes, both of which
scramble multi-measure tables. (`ts_common.parse_ts_viz` reorders by
`ordered_column_ids`; the converter's chart_columns order is wrong for tables.)

## Sorts

TML sorts come from `sort by [Col] desc/asc` tokens in `search_query` and
`sortInfo` entries in `client_state(_v2)` (`ts_common.parse_sorts`). Verified
Sigma shapes (same as looker-to-sigma, live POST + readback + render):

- bar/line/area/scatter/combo: `xAxis.sort = {by: <colId>, direction}`
- pie/donut: `color.sort = {by: <colId>, direction}`
- ungrouped table: element-level `sort = [{columnId, direction}]`
- grouped table: `groupings[0].sort = [{columnId, direction}]` — element-level
  sort on a grouped table 400s with "Sort column not found".

## Master-element pattern

Each workbook gets hidden "Data" page metadata and one flat master `table`
sourced from the DM's
denormalized View (`source: {dataModelId, elementId, kind: "data-model"}`);
every chart sources `{elementId: <master id>, kind: "table"}` and references
columns as `[<master name>/<friendly>]`. Never put an element filter / top-N cap
on the master — it propagates into every chart that sources it.

## Layout: TML tiles → Sigma grid

`liveboard.layout.tabs[].tiles[]` (or legacy `layout.tiles[]`) carries
`{visualization_id, x, y, width, height}` on a
**12-column** grid. Sigma layout is XML on a **24-column** grid:

- columns: ×2 → `gridColumn="{x*2+1} / {(x+width)*2+1}"`
- rows: ×`ROW_SCALE` (min **2**) → `gridRow="{y*RS+1} / {(y+height)*RS+1}"`.
  1:1 rows make bands too short: Sigma suppresses axis category labels and hides
  KPI titles below ~5 grid rows (~150px) — same fix as looker's `ROW_SCALE=2`.
- tags: use the live workbook vocabulary exactly: `<Element>` for placements
  and `<Container>` for grid bands. The verify endpoint rejects other tag names.

ThoughtSpot tabs become Sigma pages plus `navigation:{mode:auto}` elements.
They are not `tabbed-container`s: source tabs are top-level dashboard
navigation, not alternate views sharing one region.

The builder synthesizes layout before POST because the released API rejects an
unplaced element. Existing-workbook layout edits GET the complete document and
PUT exactly `{document:<complete document>}` so settings, overlays, panels,
agents, and unknown document fields survive. Never PUT a partial document.
`migrate_out.json` stores `layoutPages` (page ids, source tiles, controls, and
navigation prefixes) plus `dataElements`; `apply_layouts.py --workdir` consumes
those fields so a later pass retains every tab's authoritative membership and
geometry. Legacy manifests without them still derive membership from layout.

## Legend and drill semantics

- `chart.client_state(_v2)` is TML's opaque advanced-configuration payload.
  Recognized legend visibility/header/position spellings map only to the
  chart's published `legend` object; unknown values are omitted. ThoughtSpot
  TML has no standalone legend-control artifact, so the converter does not
  invent a `controlType: legend` element.
- TML documents `axis_configs.x` as axis column assignment, not as a persisted
  drill hierarchy. Sigma's released `controlType: drill` shape exposes only
  `id`, `kind`, `controlId`, and `controlType`—there are no authorable source,
  category, or target fields. When multiple x columns would lose interactive
  drill behavior, the first level remains on `xAxis`, deeper columns remain
  declared for data preservation, and the tile is loudly `[FLAGGED]`.

## Rename gotcha

`PATCH /v2/workbooks/{id}` **silently no-ops for renames** (200, name unchanged).
Rename through the files API instead:

```
PATCH /v2/files/{workbookId}   {"name": "New Name"}
```

(Workbook delete is also files-side: `DELETE /v2/files/{id}`; and unarchive is
`{"restore": true}`.)

## Misc verified gotchas

- Workbook POST/spec GET respond in **YAML** even with `Accept: application/json`
  — parse both.
- Show value labels on bar/donut via `dataLabel: {labels: "shown"}` (defaults OFF).
- Search-query filters `[Col] = 'val'` → element list-filters
  `{kind: "list", mode: include|exclude, columnId, values}`; TS lowercases string
  literals in the query (best-effort Title Case for case-sensitive warehouses).
- Sigma has no `IsIn` — silently errors the column and blanks the chart; use `or` chains.
- `CountOver`/`SumOver` window functions silently error in master/DM calc columns.
