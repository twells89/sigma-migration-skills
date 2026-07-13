# Microstrategy → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill microstrategy --out refs/microstrategy-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing (beads-sigma-kvza).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 25 documented constructs across 4 dimensions; 3 live-verified.

## Visualization / chart kind

_WIRED into scripts/convert.py (build_workbook_spec, beads-sigma-kvza). Each dossier chapter's PRIMARY visualizationType is resolved through this catalog. Axis-bindable chart types (bar_chart/line_chart/area_chart) with a dimension + a measure emit the matching Sigma CHART element (dim -> xAxis, metrics -> yAxis). `grid`/`compound_grid`/`heat_map` map to a Sigma table. A chart type with no wired emission yet (kpi/pie/ring/combo/bubble/multi_metric_kpi) or an UNMAPPED type falls to a Sigma table with a LOUD warning (data preserved, never a silent wrong chart). MSTR chart definitions bind the dataset's row attributes as dims and its column metrics as measures (retrieve-document/definition). `build`: validated = LIVE-verified against CSA.TJ; roadmap = wired mapping, emission pending; fallback = intentional table (no Sigma analog)._

Authoritative source: <https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `grid` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/webhelp/lang_1033/Content/Displaying_a_visual_representation_of_your_data__V.htm) | `table` | ✅ y · 2026-07-13 | flagged-table |
| | | | | _Pivot when crossTab:true. The ONLY type on the validated build path — convert.py collapses each chapter to a Sigma table._ |
| `kpi` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/intro_kpi_viz.htm) | `kpi-chart` | 🟡 n | flagged-table |
| | | | | _Highest-volume unbuilt type in the demo sweep; currently collapses to a table._ |
| `bar_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `bar-chart` | ✅ y · 2026-07-13 | flagged-table |
| `line_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/AdvancedReportingGuide/WebHelp/Lang_1033/Content/Line.htm) | `line-chart` | ✅ y · 2026-07-13 | flagged-table |
| `area_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `area-chart` | 🟡 n | flagged-table |
| `pie_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MCG-Workstation/en-us/Content/Creating_a_graph_with_pies_or_rings.htm) | `pie-chart` | 🟡 n | flagged-table |
| `ring_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MCG-Workstation/en-us/Content/Creating_a_graph_with_pies_or_rings.htm) | `donut-chart` | 🟡 n | flagged-table |
| | | | | _MSTR ring = pie/donut variant._ |
| `combo_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `combo-chart` | 🟡 n | flagged-table |
| `bubble_chart` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `scatter-chart` | 🟡 n | flagged-table |
| | | | | _Size slot -> Sigma scatter._ |
| `multi_metric_kpi` | [doc](https://www2.microstrategy.com/producthelp/Current/Library/en-us/Content/intro_kpi_viz.htm) | `kpi-chart` | 🟡 n | flagged-table |
| | | | | _One Sigma KPI per metric._ |
| `compound_grid` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/webhelp/lang_1033/Content/Displaying_a_visual_representation_of_your_data__V.htm) | `table` | 🟡 n | flagged-table |
| `heat_map` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/viz_gallery.htm) | `table` | 🟡 n | flagged-table |
| | | | | _Size+color tile grid has no Sigma analog -> flagged table._ |

## Number format

_MicroStrategy metric number-format CATEGORY (Fixed / Currency / Percent / Number / Scientific — the documented Number-format categories) -> Sigma column number format (D3 formatString in {kind:number, formatString}). convert.py.metric_display_format() reads the metric's EXPLICIT MicroStrategy format (metricFormatType / format.values property block) via _mstr_format_category() and resolves the category here. A 'reserved'/'general'/empty format block means 'inherit default' = NO explicit format: the metric ships UNFORMATTED with a LOUD note. This REPLACES the beads-sigma-kvza disease — the old code guessed a $/%/integer format from the metric NAME (pct|percent|margin|ratio|rate) or fact-column NAME (REVENUE|PROFIT|COST|AMOUNT|PRICE, QUANTITY|UNITS|COUNT) with a silent None fallback; that name/column-substring guessing is GONE. Custom (user format-string) masks are not in this flat table — they would be parsed by a cited predicate if MicroStrategy supplied one (the modeling-API bundles seen so far carry empty format blocks)._

Authoritative source: <https://www2.microstrategy.com/producthelp/current/MSTRWeb/webhelp/lang_1033/content/Formatting_numeric_values_in_a_visualization.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `currency` | [doc](https://www2.microstrategy.com/producthelp/current/reportdesigner/webhelp/lang_1033/content/formatting_metrics_on_a_report.htm) | `$,.2f` | 🟡 n | warn+unformatted |
| | | | | _MSTR Currency category default: currency symbol, thousands separator, 2 decimals._ |
| `percent` | [doc](https://www2.microstrategy.com/producthelp/current/reportdesigner/webhelp/lang_1033/content/formatting_metrics_on_a_report.htm) | `,.2%` | 🟡 n | warn+unformatted |
| | | | | _MSTR Percent: a stored ratio (0.275) renders as 27.50%; Sigma % format multiplies by 100 the same way._ |
| `fixed` | [doc](https://www2.microstrategy.com/producthelp/current/reportdesigner/webhelp/lang_1033/content/formatting_metrics_on_a_report.htm) | `,.2f` | 🟡 n | warn+unformatted |
| | | | | _MSTR Fixed category default: thousands separator, 2 decimal places._ |
| `number` | [doc](https://www2.microstrategy.com/producthelp/current/mstrio-py/mstrio.modeling.metric.metric_format.html) | `,.0f` | 🟡 n | warn+unformatted |
| | | | | _Plain integer with thousands separator._ |
| `scientific` | [doc](https://www2.microstrategy.com/producthelp/current/mstrio-py/mstrio.modeling.metric.metric_format.html) | `.2e` | 🟡 n | warn+unformatted |
| | | | | _MSTR Scientific -> D3 exponential._ |

## Aggregation

_MicroStrategy metric group-value function (metric expression token) -> Sigma aggregate function (`sigma`, used verbatim by metric_formula) and warehouse SQL aggregate (`sql`, the FN dict used by metric_sql when it emits AE-emulation SQL). The FN dict {source->sql} in convert.py.metric_sql is DERIVED from these rows; an unmapped function no longer silently passes through as fname.upper() — it WARNS loudly first, then emits UPPER() as a documented degraded fallback. Count with a `<Distinct=True>` parameter is COMPOSITIONAL (Count -> CountDistinct) and is resolved in metric_formula() with a cited comment, not as a separate flat row._

Authoritative source: <https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Using_group_value_functions.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `Sum` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Sum_.htm) | `Sum` | 🟡 n | warn+upper |
| `Count` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Count_.htm) | `Count` | 🟡 n | warn+upper |
| | | | | _Count<Distinct=True> is compositional -> Sigma CountDistinct (handled in metric_formula, not this flat map)._ |
| `Avg` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Avg_.htm) | `Avg` | 🟡 n | warn+upper |
| `Max` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Max_.htm) | `Max` | 🟡 n | warn+upper |
| `Min` | [doc](https://www2.microstrategy.com/producthelp/Current/FunctionsRef/Content/FuncRef/Min_.htm) | `Min` | 🟡 n | warn+upper |

## Control / filter

_Bound-column data type of a MicroStrategy dossier selector / chapter filter (Bundle.attribute_ctl_type: 'date' | 'number' | 'text', derived from the rendered DESC form's dataType) -> Sigma control kind. convert.py.emit_controls() resolves the control kind through this catalog. Only the date case is special: a Sigma `list` control whose filter target is a DATETIME *or NUMERIC* column posts 200 but Sigma SILENTLY STRIPS the target (reads back filters:null — live-verified on this converter 2026-06-12; datetime is a cross-plugin gotcha, see refs/control-parity.md). Dates become date-range controls; numbers stay `list` but bind through a hidden Text() cast; text is a plain `list`. Unresolvable source attributes / metric-qualification selectors are already recorded LOUDLY in control-scope.json (status: unbound / manual)._

Authoritative source: <https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/intro_add_filters.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `date` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/getting_started_selector.htm) | `date-range` | 🟡 n | n/a |
| | | | | _A datetime-bound list control reads back filters:null (dead control) — must be a date-range control with a flat `mode`._ |
| `number` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/getting_started_selector.htm) | `list` | 🟡 n | n/a |
| | | | | _A list-control filter target on a NUMERIC column is silently stripped by Sigma (200 on POST/PUT, filters:null on readback) — numeric selectors bind through a hidden Text() cast column._ |
| `text` | [doc](https://www2.microstrategy.com/producthelp/Current/MSTRWeb/WebHelp/Lang_1033/Content/getting_started_selector.htm) | `list` | 🟡 n | n/a |
| | | | | _Categorical list control (documented default)._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
