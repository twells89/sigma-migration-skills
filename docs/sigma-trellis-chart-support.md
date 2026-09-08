# Sigma native `trellis` — chart-kind support matrix

Which Sigma viz kinds support the **native trellis** element property — the
spec-authorable small-multiples facet — and how each orientation behaves.

The native trellis binds a **categorical column** to a facet shelf on a single
viz element:

```jsonc
{
  "kind": "bar-chart",
  "columns": [ { "id": "col-cat", "formula": "[Master/Category]" }, ... ],
  "trellis": {
    "rowsBy":    [ { "columnId": "col-cat" } ],   // vertical  — one facet per member, stacked in rows
    "columnsBy": [ { "columnId": "col-cat" } ]     // horizontal — one facet per member, side by side
  }
}
```

- `rowsBy` alone → vertical small-multiples.
- `columnsBy` alone → horizontal small-multiples.
- both, referencing **two different** columns → a 2-D grid (rows × columns).
- The facet reference key is **`columnId`** (a `columns[]` id on the element).
  Note this differs from the `pivot-table` element's *own* `rowsBy`/`columnsBy`
  cross-tab shelves, which key on `columnId` and are a separate mechanism (see below).

> This is distinct from the legacy `trellis: { column, row, share?, tileSize? }`
> *styling* object, which only styles a UI-configured trellis and whose facet
> binding is silently stripped. The `rowsBy`/`columnsBy` form **does** bind the
> facet from spec on the supported kinds.

## How this was verified

For each chart kind a minimal two-page workbook was POSTed live to
`POST /v2/workbooks/spec` (Data page: a source table with a few-member category
dimension + an x dimension + a numeric measure; content page: one element of the
kind with `trellis` referencing the category column). Then
`GET /v2/workbooks/{id}/spec` was read back and the `trellis` key compared to
what was sent, and representative cases were rendered to PNG via the export API.

**Primary signal = does the readback preserve the `trellis` key.** A kind that
supports it round-trips the key byte-for-byte; a kind that does not returns
`200` on POST but **silently drops** the key on readback (and renders a single,
un-faceted chart). Render was used as confirmation on the positive cases (facets
appear) and on a stripped case (pie renders flat).

## Coverage matrix

| Chart kind        | `rowsBy` (POST / readback / render) | `columnsBy` | 2-D grid | Notes |
|-------------------|-------------------------------------|-------------|----------|-------|
| **bar-chart**     | 200 / **preserved** / facets render | preserved (200) | preserved (200) | Full support. `stacking: stacked` and `stacking: normalized` variants both preserve trellis (200 / preserved). |
| **line-chart**    | 200 / **preserved** / facets render | preserved (200) | preserved (200) | Full support. |
| **area-chart**    | 200 / **preserved**                 | (cartesian — same as bar/line) | (same) | Full support; shares the cartesian shape. |
| **combo-chart**   | 200 / **preserved**                 | (cartesian) | (same) | Full support; shares the cartesian shape. |
| **scatter-chart** | 200 / **preserved**                 | (cartesian) | (same) | Key round-trips. Caveat: a scatter must bind to a grouping to render correctly (unrelated to trellis) — validate the render separately. |
| **donut-chart**   | 200 / **preserved** / facets render | (circular — same as rowsBy) | (same) | **Supported** — one donut per facet member renders. |
| **pie-chart**     | 200 / **STRIPPED** / renders flat   | **STRIPPED** (200) | **STRIPPED** (200) | **NOT supported.** POST succeeds, key is dropped on readback, render is a single un-faceted pie. Use `donut-chart` if a trellis is required. |
| **kpi-chart**     | 200 / **STRIPPED**                  | —           | —        | **NOT supported.** Key dropped on readback. |
| **pivot-table**   | 200 / **STRIPPED**                  | —           | —        | **NOT supported** as a `trellis` key. The pivot's *own* element-level `rowsBy`/`columnsBy` shelves (keyed on `columnId`) are the native cross-tab faceting — use those instead. |
| **table**         | 200 / **STRIPPED**                  | —           | —        | **NOT supported.** Key dropped on readback. |

Invalid element kinds (rejected `400 "Invalid kind"` — not part of the workbook
spec API in this org): `box`, `heatmap`, `gauge`, `funnel`, `waterfall`,
`single-value`, `geography`, `map`. There is no trellis story for these because
the kinds themselves don't exist in the spec.

### Key surprises

1. **`pie-chart` does NOT support trellis, but `donut-chart` does** — despite
   both being circular (`value` + `color`) charts. The trellis key is silently
   stripped from a pie on readback and the render is a single flat pie; a donut
   with the identical trellis renders one donut per facet member. If a source
   tool has a faceted pie, emit a **donut** in Sigma (or route to post-publish).
2. **Stripping is silent** — every non-supporting kind still returns `200` on
   POST. POST success is **not** proof of trellis support; the readback is. Any
   converter that emits native trellis must re-read the spec and confirm the
   `trellis` key survived.
3. **`pivot-table` / `table`** never trellis via the `trellis` key. For a pivot,
   the element's own `rowsBy`/`columnsBy` cross-tab shelves already provide the
   equivalent small-multiples layout.

## Converter guidance

**Emit native `trellis` (`rowsBy` / `columnsBy` / both) for these kinds only:**

- `bar-chart` (including `stacking: stacked` / `normalized`)
- `line-chart`
- `area-chart`
- `combo-chart`
- `scatter-chart` (trellis round-trips; verify the grouping/render separately)
- `donut-chart`

For those, translate a source-tool small-multiples / trellis / "by" facet to a
**single** viz element with the facet dimension added as a column and
`trellis.rowsBy` (vertical) or `trellis.columnsBy` (horizontal), using
`{ "columnId": "<facet-col-id>" }`. A 2-D facet maps to both keys pointing at
two distinct columns.

**Do NOT emit `trellis` for these — it is accepted but silently dropped:**

| Kind | What to do instead |
|------|--------------------|
| `pie-chart` | Prefer emitting a **`donut-chart`** when the source is a faceted pie (donut trellises natively). If a pie is mandatory, **keep it flat** and route the faceting to a **post-publish** step (build the small-multiples in the editor), or replicate one element per member in layout. |
| `kpi-chart` | Keep flat. For "one KPI per category," fan out to **N sibling KPI elements** (one per member) in the layout instead of a single trellised KPI — there is no native KPI trellis. |
| `pivot-table` | Use the pivot's **own** `rowsBy`/`columnsBy` cross-tab shelves (keyed on `columnId`) — that is the native equivalent; do not add a separate `trellis` key. |
| `table` | Keep flat, or model the facet as an extra grouping/row dimension. No native table trellis. |

**Always confirm the round-trip.** Because unsupported kinds return `200` and
drop the key, the emit path should GET the spec back after create and assert the
`trellis` key is present on the element before treating the native trellis as
applied; if it was stripped, fall back to the post-publish route above.

## Neutral reference example

Source table `Master` with `Category` (3 members: Region A / B / C), `Sub-Region`
(x-axis dimension) and `Revenue` (measure). A vertically trellised bar chart:

```jsonc
{
  "id": "el-revenue-by-subregion",
  "kind": "bar-chart",
  "source": { "elementId": "master", "kind": "table" },
  "columns": [
    { "id": "c-cat", "formula": "[Master/Category]",   "name": "Category" },
    { "id": "c-x",   "formula": "[Master/Sub-Region]", "name": "Sub-Region" },
    { "id": "c-y",   "formula": "Sum([Master/Revenue])", "name": "Revenue" }
  ],
  "xAxis": { "columnId": "c-x" },
  "yAxis": { "columnIds": ["c-y"] },
  "trellis": { "rowsBy": [ { "columnId": "c-cat" } ] }
}
```

Swap `rowsBy` → `columnsBy` for horizontal small-multiples, or supply both
(pointing at two different columns) for a 2-D grid.
