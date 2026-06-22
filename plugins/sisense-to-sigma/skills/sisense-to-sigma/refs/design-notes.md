# Design notes — sisense-to-sigma

## Status (2026-06-17) — production-hardened, live-validated
End-to-end **live-validated at exact parity** on Sample ECommerce (DM + 7-element
workbook; Total Revenue $39,759,625.515, monthly trend, joined category
breakdown all match Sisense JAQL). Built and tested:
- `discover.py` — live pull (auth, model schema export, dashboards). ✅
- `convert.py model` — DM spec; warehouse-table + **custom-SQL tables** (ElastiCube
  SQL → warehouse SQL, flagged); relationships; parameterized db/schema. ✅
- `convert.py dashboard` — **generic** widget→workbook emit (Master data element +
  kpi/bar/line/area/pie/scatter/pivot→grouped-table/table), JAQL formulas via
  `jaql_expr`, top-N filters, money formatting. ✅
- `jaql_expr.py` — aggs, ratio/nested formulas, date-level→DateTrunc, top-N;
  flags filtered/scoped measures + `PREV/PAST/RSUM/...`. 19 unit tests. ✅
- `verify_parity.py` — automated gate (Sisense JAQL vs warehouse), GREEN/RED. ✅
- `sisense-assessment/assess.py` — inventory + converter-coverage scoring. ✅
- Offline regression: `tests/test_jaql.py` (19) + `tests/test_convert.py` (17)
  against bundled `fixtures/`. ✅

### Gaps closed (2026-06-18)
- **Two live round-trips at exact parity.** ECommerce (clean star) AND Healthcare
  (8 tables, snowflake schema, a custom-SQL derived table) both landed in
  Snowflake + DM-parity-verified end-to-end.
- **Custom-SQL tables convert and run.** ElastiCube SQL → Sigma `sql` element
  (`statement` field, `[Custom SQL/Col]` formula prefix, quoted output aliases);
  Healthcare's "Conditions time of stay" matches Sisense exactly (still flagged
  for human SQL verification — dialect functions may differ).
- **Dashboard filters → Sigma controls.** Member/date/numeric filters become
  list/date-range/number-range controls bound to the Master, with default
  selections carried; validated (filtered total = $3,735,431.72, exact).
- **Relationship direction is cardinality-accurate** via `--verify-card`
  (unique-key side = dimension); snowflake schemas handled; width fallback now
  flags each relation for verification. No fanout (Admissions stays 5000).
- **Dashboard layout now ports** (2026-06-22). The workbook spec emits a Sigma
  `layout` XML: faithful for structured columnar layouts, clean auto-arrange
  (KPI card rows + 2-up charts + full-width trends/tables) for the default
  single-column stack. Previously the converter emitted no layout and Sigma just
  stacked everything. See "Layout" below.

### Remaining limitations (smaller)
- Widget-level filters beyond top-N, conditional formatting, drill, RLS/data
  security: not converted.
- `--verify-card` needs the base data already in the warehouse; derived/custom-SQL
  tables can't be probed (their relations fall back to the flagged width heuristic).
- pie emitted as `pie-chart` with `{id}` refs (this org's API); donut/holeValue untested.

## Architecture (phases, mirroring the sibling converters)

- **Phase 0 — Assess.** `sisense-assessment` inventories the estate (cubes,
  dashboards, widget-type histogram, JAQL complexity) and scores each dashboard
  against converter coverage. Read-only.
- **Phase 1 — Discover.** `discover.py` pulls the model schema export + the
  dashboards/widgets bundle over REST. ✅ working.
- **Phase 2 — Convert model.** ElastiCube datasets → Sigma data model. Each
  `schema.tables[]` becomes a DM element: plain tables → warehouse table
  sources; tables with a non-null `expression` → Custom-SQL elements (SQL
  preserved verbatim, flagged). `relations[]` → DM relationships. Column `type`
  codes → Sigma column types.
- **Phase 3 — Convert dashboards.** Each widget → a workbook element
  (`pivot2`→pivot-table, `indicator`→KPI, `chart/*`→chart, `tablewidget`→table).
  Panel JAQL → workbook formulas via `jaql_expr.py`; dashboard + widget filters →
  controls. Translate what maps; **flag** custom JAQL functions, BloX/plugin
  widgets, scripted widgets. **Layout is ported here too** — see "Layout" below.
- **Phase 4 — Parity.** Run each widget's JAQL via `POST /api/datasources/{ds}/jaql`
  and compare to the Sigma element's query. GREEN gate before claiming done.
- **Phase 5 — Repoint + enhance.** Wire the workbook to the DM. Layout is
  already emitted in Phase 3; review and nudge in Sigma, defer deeper polish to
  `sigma-workbooks`.

## Layout

Sisense and Sigma model layout very differently, and porting it is what made the
output stop looking like a flat dump of charts.

**Sisense** (`dashboard.layout`, `type: "columnar"`): `columns[]` are vertical
strips with a `%` `width`; each column has `cells[]` stacked top-to-bottom; each
cell has `subcells[]` placed left-to-right (each a `%` of the column); each
subcell holds `elements[]` keyed by `widgetid` with a px `height`.

**Sigma** (top-level `layout`, a single XML string): one `<Page type="grid"
gridTemplateColumns="repeat(24, 1fr)">` per page; elements positioned by
`<LayoutElement elementId gridColumn="start / end" gridRow="start / end"/>` where
**`end` is exclusive** (full width = `1 / 25`). A `<GridContainer>` can group a
sub-grid, but its `elementId` MUST reference a real container element in the
spec — Sigma rejects a synthetic id ("not a valid container"), so we don't emit
one; controls go flat instead (see below). Element IDs we choose are
**preserved on workbook CREATE**, so the layout's `elementId` refs resolve
without a readback.

`build_layout()` in `convert.py` does the translation:
- **Faithful** (`_faithful`) when the Sisense layout has real structure (>1
  column, or any cell with >1 subcell): column `%`widths → proportional grid
  spans via `_alloc` (largest-remainder split summing to exactly 24); each
  top-level column is an independent vertical stack placed side-by-side;
  subcells split a column horizontally; cells stack. The author's arrangement
  is reproduced.
- **Auto-arrange** (`_auto_arrange`) when the layout is Sisense's degenerate
  default — one full-width column of stacked full-width widgets (porting that
  verbatim is an ugly tall stack). Leading KPIs flow into rows of up to 4 cards,
  remaining charts go 2-up, and `WIDE_KINDS` (line/area trends, tables, pivots)
  span full width.
- Dashboard-filter **controls** are placed as a flat row of `<LayoutElement>`s
  at the top (one equal column-slice each) — never a `<GridContainer>`, which
  Sigma rejects without a backing container element (live-found 2026-06-22).
- px height → grid rows via `PX_PER_ROW` (≈42px/row, so Sisense's 512 default ≈
  12 rows); KPIs are pinned to a short `KPI_ROWS` card regardless of px.
- Tunables at the top of the layout section: `GRID_COLS`, `PX_PER_ROW`,
  `KPI_ROWS`, `CTRL_ROWS`, `MIN_VIZ_ROWS`, `WIDE_KINDS`.

Note: the bundled fixtures are single-column stacks, so they exercise the
auto-arrange path; `tests/test_convert.py` includes an inline 2-column dashboard
to cover the faithful path.

**Layout has its own parity gate** — `verify_layout.py <dashboards.json>
<sigma_workbook_spec.json>`. Data parity (`verify_parity.py`) checks the numbers
only; this checks the arrangement: every mapped widget placed exactly once, no
orphan refs (`master` + controls excepted), inside the 24-col grid, no overlaps,
reading order preserved, side-by-side widgets share a Sigma row, relative widths
preserved. GREEN on both bundled fixtures (auto-arrange) and a **live-built**
multi-subcell dashboard (faithful) — validated 2026-06-22 against trial
`signup-jnzavd0c` (dashboard "ECommerce — Executive Layout (built)": a KPI card
row + 2-up charts + full-width trend + full-width bar ported exactly).

## RLS (optional, opt-in)

Sisense **data security** rules (per-cube, per-column member restrictions, via
`GET /api/elasticubes/{server}/{cube}/datasecurity`) port to Sigma row-level
security. `detect_rls.py` is zero-overhead and silent when a cube has none;
when it finds rules it emits a converter-style `security[]`
(`CurrentUserAttributeText("<col>") = Text([<col>])` + a per-column user
attribute). **The `Text(...)` wrap is load-bearing:** without it a *numeric*
restricted column (e.g. an ID) compares text-to-number and silently matches
nothing. Porting is opt-in via the tool-agnostic `apply_sigma_rls.py`
(reuse-first, plan-only by default; mutates only on `--provision`/`--apply`;
per-user member values are flagged for assignment, never faked).

**Live-validated 2026-06-22** (exact restricted parity, querying as a member
with the attribute assigned):
- text column — `gender = Male` → $6,158,653.81 / 142,599 rows (1 gender visible)
- numeric column — `Country ID = 1` → $6,880,013.42 / 104,803 rows (1 country)
both exactly matching the Snowflake ground truth, vs the unrestricted $39.76M.

## Visual QA — render-and-inspect gate

`verify_layout.py` proves the grid is structurally sound (no overlaps, all
placed, reading order, no width inversions). It does NOT prove the page *looks*
right. After POST, render each page with `sigma-export-png.py` and read it
against `refs/layout-visual-qa.md` (compare to the Sisense source PNG). Validated
2026-06-22: the migrated Executive-Layout workbook rendered with the exact
Sisense arrangement (KPI card row → 2-up charts → full-width trend → full-width
bar) and live data. (Sisense's own dashboard UI showed "No Results" for the
same source — a Sisense REST-widget rendering quirk, NOT a migration issue; the
Sigma render is the source of truth for "did the layout come over".)

## The Snowflake-parity requirement (full migrations)

Sisense sample cubes live in Sisense's **ECCloud** storage — Sigma can't read
that. A *full* migration with real parity needs **both tools reading the same
warehouse**. Plan:

1. **Land the source data in Snowflake.** Load the Sisense sample dataset(s)
   into the shared demo warehouse (Snowflake `CSA.TJ`, the connection the other
   migration skills use). One schema per cube, e.g. `CSA.TJ.SISENSE_ECOMMERCE_*`.
2. **Make Sisense read Snowflake (Live).** Add a Snowflake connection in Sisense
   and build the source dashboard on a **Live** model over those same tables —
   so the Sisense side and the Sigma side query byte-identical data. (Reuses the
   existing sample-schema table structure from the model export.)
3. **Sigma DM targets the same Snowflake connection.** Phase-2 emits a DM whose
   sources are the `CSA.TJ.SISENSE_*` tables. Parity is then exact, not
   approximate.

Decision pending with the user: which sample cube to use as the first
end-to-end fixture (ECommerce is smallest: 4 datasets / 3 relations), and
whether to load via the Snowflake MCP / connector creds already on this machine.

## Hard problems / flags (don't fake)
- **JAQL custom formulas** with rich `context` (nested measures, `PREV`, `PAST`,
  `RSUM`, `RANK`, filtered measures) — translate the common ones, flag the rest.
- **BloX / plugin / scripted widgets** — no Sigma equivalent; flag.
- **ElastiCube import-time transforms** (`modelingTransformations`) — may encode
  ETL that belongs upstream in the warehouse; surface, don't silently inline.
- **Column type code map** — only `18`=text confirmed; complete the map from a
  populated cube before trusting numeric/date conversions.

## Graduation target
`sigma-migration-skills/plugins/sisense-to-sigma/`. Feature parity with the
sibling converters is met and live-validated (model + dashboard + JAQL +
filters→controls + layout + data/layout/visual-QA gates + gap-scout + opt-in
RLS). Remaining to physically graduate: move under `plugins/`, wire shared
governance (manifest, ref-index uses the `refs/`-prefixed link form CI checks),
and open the PR.
