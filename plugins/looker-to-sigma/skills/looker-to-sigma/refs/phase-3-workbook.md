<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Phase 3 — dashboards -> workbook spec: build, the spec gotcha catalog, POST + verify. -->

# Phase 3 — Convert the dashboards (UDD = primary)

For each Looker dashboard, fetch its contract (Phase 1b), then build a Sigma workbook spec.

### 3a. Build the workbook spec

```bash
python3 scripts/build_workbook.py /tmp/<name>/<dash>.contract.json \
  --views /path/to/lookml/views \
  --dm-id <dataModelId> \
  --element-id <denorm-element-id> \
  --dm-element-name "<DM element display name>" \
  --folder-id <writable-folder-id> \
  --out /tmp/<name>/<dash>.workbook.json
```

(`contract` is positional. `--dm-element-name` is the display name of the data-model element
the master table pulls from; `--master-name` defaults to `Data`. The generated spec has
placeholder defaults for any flag you omit, so it always generates locally — fill in the real
ids before POSTing.)

`build_workbook.py` consumes the contract + the explore's view `.lkml` files (to classify each
`view.field` as a measure — agg + base col — or a dimension, and derive the Sigma formula) and
emits a `/v2/workbooks/spec` body:
- a **hidden "Data" page** with a master table sourced from the DM element,
- one metadata-only page per Looker dashboard tab (or one dashboard page),
- a flat **`document.elements`** collection with one element per Looker tile,
- **controls** from the dashboard filters,
- a required, authoritative **newspaper → 24-col grid layout** XML string that
  places every flat element exactly once.

> **The body above is `document`-wrapped, not flat** (verified live 2026-08-03, including
> on `POST /v2/workbooks/spec/verify` 2026-08-04): `schemaVersion`, `pages`, `kind`, and
> `layout`, and flat `elements` all nest under a top-level `document` key; workbook
> metadata (`name`, `folderId`) stays outside it. Pages contain metadata only;
> page membership comes from the required layout.
> The Phase-2 DM POST (`/v2/dataModels/spec`) is a different surface and remains flat.

Tile-type, filter-type, and layout maps are in `refs/dashboard-contract.md` and
`refs/looker-dashboard-layout.md` — **do not duplicate them; defer there.** Summary:

| Looker tile `type:` | Sigma kind |
|---|---|
| `single_value` | `kpi-chart` |
| `looker_column` | `bar-chart` (vertical) |
| `looker_bar` | `bar-chart` + `orientation: horizontal` (Looker `looker_bar` = horizontal bars) |
| `looker_line` | `line-chart` |
| `looker_area` | `area-chart` |
| `looker_pie` | `pie-chart` |
| `looker_donut_multiples` | `donut-chart` (single ring) + warn |
| `looker_scatter` | `scatter-chart` |
| `looker_waterfall` | native `waterfall-chart` for dimension + measure; measure-only warns + skips |
| `looker_grid` / `table` | `table` |
| `text` | `text` (markdown body) |
| `looker_boxplot` | none until released `box-chart` is published — drop + loud gate |
| `looker_map` / geo / funnel / timeline / wordcloud / sankey / custom viz | none — approximate or drop + warn |

Released workbook feature mappings and deliberate gaps (legend, progress,
navigation/tabs, drill, page-break, panels, repeaters, styling, and box-chart)
are cataloged in `refs/catalogs/workbook-feature.json` and summarized in
`refs/workbook-code-release-gaps.md`. Emit only when the source carries the
documented intent; a released Sigma capability is not by itself permission to
invent source behavior.

**Table column order, labels & hidden columns.** A table's Sigma column order follows the Looker
**visualization** order (`vis_config.column_order`, captured as contract `columnOrder`), NOT
`query.fields` — the Data-tab order, which forces dimensions before measures. Fields not listed in
`column_order` append in `fields` order (Looker appends newly-added fields at the end). Column
**names** prefer the viz label (`vis_config.series_labels`, captured as `columnLabels`) over the
humanized field name — a column renamed in the visualization can differ from the Data-tab name. Columns
**hidden from the visualization** (`vis_config.hidden_fields`, captured as `hiddenFields`) get
`hidden: true` on the Sigma column — but a hidden **dimension is KEPT in `groupings.groupBy`** so
the aggregation grain (and therefore every measure value) is unchanged. Never *drop* a hidden
dimension: Looker keeps it in the query ("Hide from Visualization" doesn't re-run the query), so
dropping it would silently change the numbers. Both are additive contract keys — absent/empty →
columns stay in `fields` order, byte-identical to before. Verified: `tests/test_table_column_order.py`.

**DM metric references (leverage the semantic layer, don't duplicate it).** A table/pivot measure
column prefers a governed **`[Metrics/<name>]`** reference over re-deriving the aggregation inline,
when the measure's inline aggregate matches a metric defined on (or inherited by) the source DM
element. Match is by FORMULA equivalence — strip the master prefix so `Sum([Data/Net Revenue])`
equals a metric's `Sum([Net Revenue])` — so it's naming-independent and SAFE: ratios, filtered
measures, custom/ad-hoc measures, and any non-match fall back to the inline formula. migrate-looker
passes each element's referenceable metrics (name+formula) via `--dm-elements`, resolved through the
`source.elementId` chain (a denorm "<X> View" element inherits its base fact's metrics — Sigma
exposes them, and `[Metrics/<name>]` resolves on the denorm through the master→element chain,
verified live). Absent metrics (the offline test/golden path) → inline, byte-identical. Verified:
`tests/test_metric_reference.py`.

Newspaper layout math (a single arithmetic transform, no spatial heuristic):
`gridColumn = (col+1) / (col+1+width)`, `gridRow = (row+1) / (row+1+height)`. `tile` / `static`
/ `grid` modes need a snap heuristic (lossy) — warn + stack; see `refs/looker-dashboard-layout.md` §3.

### 3b. Workbook-spec gotchas (learned the hard way)

- **`/v2/workbooks/spec` returns YAML** — don't `json.load` the response.
- **control elements** live in flat `document.elements[]` with `kind: control` but REQUIRE an `id`
  (separate from `controlId`); a missing `id` → `Invalid kind: "control"`.
- **KPI `value` uses `value.columnId`** on the live API. Donut/pie channel pointers
  (`value`/`color`/`holeValue`) now use **`columnId` too** — `{ id }` is a 400
  (`Invalid kind: "donut-chart"` / `"pie-chart"`).
- **Chart `color` channel differs by type:** bar/area/line series = `{by: "category", column:
  <id>}`; donut/pie slice = `{columnId: <id>, sort?}`. (A Looker pivot maps to this color channel.)
- **donut/pie use `value` + `color`, NOT `xAxis`/`yAxis`.**
- **KPI comparison (`show_comparison`) has NO spec slot** — warn, don't build. (Recommend a 2nd
  KPI tile or a UI delta post-publish.) Looker `donut_multiples` per-multiple dim is also dropped → warned.
- **Master → DM-element refs:** a master table sourcing a DM element references columns as
  `[<DM-element-NAME>/<col display>]`; tiles then reference `[<master-NAME>/<col display>]`.
- **Joined-view columns** in the denorm DM element are named `<Field> (<joinAlias>)` (Sigma
  disambiguates cross-element lookup cols) — master/tile refs must include the suffix, e.g.
  `[Order Fact/Region (customer_dim)]`.
- **Cross-element relationship refs (reused relational DMs) — the form is LAYER-DEPENDENT.**
  When the converter builds the DM it flattens joined columns into one denorm element, so the
  workbook only ever does `[<element>/<col>]`. But when you **reuse an existing DM** whose
  element reaches other columns through a `relationships[]` entry (instead of a flat denorm),
  the ref form differs by where you write it (all verified live 2026-06-29):
    - **In a workbook formula** (master/tile/chart column) → `[<SourceElement>/<RelationshipName>/<col display>]`
      — uses the **relationship's `name`**. e.g. `[Plugs Fact/Plugs to Customer/Cust Region]` ✅.
    - **In a DM calc column** → `[<TargetElementName>/<col display>]` (or `Lookup([<TargetElementName>/<col>], <localKey>, [<TargetElementName>/<key>])`)
      — uses the **target element's name**, NOT the relationship name. e.g. `[Customer Dim/Cust Region]` ✅.
    - **Both layers reject the raw warehouse/staging table name** (e.g. `STG_…`/`D_CUSTOMER`)
      → the column resolves as `type=error`. The relationship `name` is whatever the DM author
      set (often a phrase like `"Plugs to Customer"`, **not** the table name) — read it from the
      DM spec's `relationships[].name`; don't guess it from the table. Two-segment guesses like
      `[<RelationshipName>/<col>]` hard-reject the whole spec POST ("dependency not found").
- **VARIANT / JSON columns — extract with DOT NOTATION, not a function.** Sigma has **no**
  `JsonExtractText()` / `CallVariant()` / `Variant()`-extraction function (those error the
  column — don't trial-and-error them). To pull a value out of a JSON/VARIANT column, write a
  **dot-notation** formula and wrap it in `Text()` to land a typed column:
  `Text([Cust Json].AGE_GROUP)`, nested `Text([Cust Json].LOYALTY_EXTRA.LOYALTY_TIER)`, array
  `Text([Cart Details].cart[0])` (0-based). Best practice is to extract **upstream in the DM**
  (the extracted column then flows into the workbook as a normal column — verified live
  2026-06-29); the UI equivalent is the column menu's **Extract columns…**. So a JSON field is
  migratable — surface it as a dot-notation column, don't leave it as raw JSON and don't block
  on it. (`Variant()`/`Json()` exist only to *cast* a column's type, not to extract.)
- **Table calcs** → workbook formula columns: `running_total` → `CumulativeSum`,
  `pct_of_total`/`sum()` → `GrandTotal`, `offset(…,-1)` → `Lag`. (`build_workbook.py` translates
  these; `dynamic_fields` arrives JSON-parsed from discovery.)
- **count on a joined view** → `CountDistinct` using that view's primary key (base-view counts
  stay `Count()`).
- **Number formats carry through.** A LookML measure's `value_format_name` (`usd`, `usd_0`,
  `percent_0/1/2`, `decimal_0/1/2`, …) or custom `value_format` mask becomes the Sigma column
  `format` object — `{kind: "number", formatString: "<d3-format>"}` — on the tile's value /
  KPI-value / chart-measure / measure-table column. So a `usd` measure renders `$110,342.75`
  (not bare `110,342.75`) and a `percent_1` measure renders `12.3%`. `build_workbook.py`'s
  `build_field_index` captures each measure's format and `apply_fmt` attaches it; custom masks are
  best-effort (currency symbol / thousands separator / decimals / percent). Counts and dimensions
  get no format (raw). Without this the side-by-side render (Phase 4a) shows bare numbers where
  Looker showed `$`/`%`.
- **Bar orientation.** Looker `looker_bar` renders **horizontal** bars, `looker_column` vertical —
  both map to a Sigma `bar-chart`. `build_workbook.py` emits `orientation: horizontal` for
  `looker_bar` and omits the key (Sigma's vertical default) for `looker_column`. Field verified:
  `sigma-workbooks` `charts.md`.
- **Grid cell visualizations (`series_cell_visualizations`).** A Looker grid can draw in-cell bars
  on a measure column, often colored by VALUE (low→high gradient). **Sigma data bars are
  SIGN-colored** — one fill for positive, one for negative (verified live 2026-06-24: the
  `Format rule` → `Data bars` UI exposes only a *Negative color* + *Positive color*, and a
  multi-stop `scheme` collapses to the single positive color). So the bar fill **cannot** vary by
  value. The mappings `build_workbook.py` emits from contract `cellVisualizations: {field:{scheme}}`:
    - Looker bar **colored by value** (a `custom_colors` palette) → Sigma **Color scale**
      (`conditionalFormats: [{type: backgroundScale, columnIds:[<calc col>], scheme:[…]}]`) — tints
      the cell low→high, reproducing Looker's value encoding — **plus a warning** (the bar+value-color
      combo isn't reproducible; flip the rule to `dataBars` if you'd rather keep a magnitude bar).
    - Looker **plain** bar (no value palette) → `conditionalFormats: [{type: dataBars, columnIds:[…]}]`
      (magnitude). Verified spec shapes: `sigma-workbooks` `tables.md`.
  **Render-only caveat:** Looker frequently does **not** return `series_cell_visualizations` from the
  dashboard/query API even when the rendered dashboard shows the bars (confirmed on dash 11 via the
  query, `result_maker`, and `dashboard_element` endpoints — all empty). That case can't be
  auto-detected from the contract, so the Phase-4a visual-QA gate is where you catch it: if the Looker
  render shows value-colored in-cell bars but the Sigma table has none, add a `backgroundScale`
  `conditionalFormat` by hand (sample the source colors for the `scheme`) and `PUT` the spec.
- **Null-presence tile filters.** `NOT NULL` / `-NULL` become an exclude-null
  list filter; `NULL` becomes include-null; EMPTY variants also include/exclude
  the empty string. Never emit these tokens as literal list values.
- **Safe update path.** Use `--update-workbook <id>` for iterative writes.
  The orchestrator stores the readback version+hash and aborts if a later UI/API
  edit changed the workbook. `--force-overwrite` is explicit and recorded.

### 3c. POST the workbook + verify

POST the spec to `/v2/workbooks/spec` (returns YAML → record the `workbookId`). Then
`mcp__sigma-mcp-v2__describe` each element (no `type=error` columns) and confirm the layout
applied. **POST is create-only** — every subsequent spec edit MUST use `PUT
/v2/workbooks/{id}/spec`; re-POSTing leaves orphan workbooks in My Documents (delete via `DELETE
/v2/files/{id}`).

---

## Looks — a thin add on the dashboard pipeline

**Looks are a thin add on the dashboard pipeline.** A Look's `.query` is the same Looker
`Query` shape a dashboard tile embeds, so `fetch_looker_look.py` synthesizes a one-tile
contract (via the shared `normalize_element`) with `filters:[]` and a full-width layout —
everything downstream (`build_workbook.py`, parity, gates) is reused unchanged. A Look with
**dimensions + measures becomes a Sigma grouped `table`** (dims → `groupings.groupBy`,
measures → `groupings.calculations`); measure-only → a KPI row; pivoted → a `pivot-table`
(rowsBy/columnsBy/values); a chart Look → the matching chart. The Look path additionally
emits `fieldMeta` (authoritative dim/measure category from the explore metadata + custom
`dynamic_fields`) so ad-hoc/custom measures classify correctly even with no local LookML.
Run it with `--look-id <id>` (see the ONE COMMAND block). A **table-only** Look verifies via
a grand-total parity target; a dimension-only detail Look has no measure to check (named
`--skip-parity-gate` waiver + the offline golden test + visual QA).

---

## Preflight the workbook spec before POST (mandatory)

Before POSTing any workbook spec, run `ruby scripts/lib/preflight_lint.rb <spec.json>` — it exits 1 with a precise message on the two migration-killer bugs: a `table` with aggregate columns + dimensions but **no `groupings`** (renders raw detail rows), and a malformed `control` (missing `id`/`controlId`/`controlType` or nesting value fields under a `value` object instead of flat, a non-double-nested `source`, or a list control wired to neither `source` nor `filters` — a filters-only list control is valid). Fix every violation first — never POST past it, and **never conclude a feature is "unsupported" from an `Invalid kind` error** (it means the inner fields are wrong). Verified shapes: `sigma-workbooks` `controls.md` / `tables.md`.
