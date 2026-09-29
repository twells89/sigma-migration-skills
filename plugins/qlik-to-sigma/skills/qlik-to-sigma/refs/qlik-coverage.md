# Qlik → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill qlik --out refs/qlik-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing (beads-sigma-kvza).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 77 documented constructs across 6 dimensions; 13 live-verified.

## Visualization / chart kind

_Qlik object vizType -> Sigma workbook element kind. Covers the complete documented native Qlik chart and text-based visualization set that is data-bound (filter panes are covered by the control catalog). The single source of truth for build-sigma-workbook.py's chart classifier. `auto-chart` is NOT in this table — it is resolved compositionally by shape (no dims -> KPI; >=2 dims -> grouped table; 1 temporal dim -> line; else bar), a cited predicate in build_element._

Authoritative source: <https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/visualizations.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `barchart` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/BarChart/bar-chart.htm) | `bar-chart` | ✅ y · 2026-07-13 | warn+skip |
| `linechart` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/LineChart/line-chart.htm) | `line-chart` | ✅ y · 2026-07-13 | warn+skip |
| `piechart` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/PieChart/pie-chart.htm) | `pie-chart` | 🟡 n | warn+skip |
| `combochart` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/ComboChart/combo-chart.htm) | `combo-chart` | ✅ y · 2026-07-13 | warn+skip |
| `scatterplot` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/ScatterPlot/scatter-plot.htm) | `scatter-chart` | 🟡 n | warn+skip |
| `table` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Table/table.htm) | `table` | ✅ y · 2026-07-13 | warn+skip |
| `kpi` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/KPI/KPI.htm) | `kpi-chart` | ✅ y · 2026-07-13 | warn+skip |
| `pivot-table` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/PivotTable/pivot-table.htm) | `pivot-table` | 🟡 n | warn+skip |
| `map` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Map/Map.htm) | `region-map` | ✅ y · 2026-09-29 | warn+skip |
| | | | | _Layer-aware: prefer an authored AreaLayer whose field maps to a released Sigma regionType; otherwise emit a PointLayer only when explicit latitude+longitude fields exist. Location-name points without coordinates are retained as source evidence but never guessed, and multi-layer overlays are reported because Sigma workbook map elements author one layer per element._ |
| `waterfallchart` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/WaterfallChart/waterfall-chart.htm) | `waterfall-chart` | 🟡 n | warn+skip |
| | | | | _Direct released workbook-as-code kind; preserves the Qlik dimension and ordered measures on xAxis/yAxis._ |
| `gauge` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Gauge/gauge-chart.htm) | `progress` | 🟡 n | warn+skip |
| | | | | _A Qlik value gauge maps to Sigma progress (value mode; bar/ring shape) using formula-string min/max/value fields._ |
| `boxplot` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/BoxPlot/box-plot.htm) | `box-chart` | 🟡 n | warn+skip |
| | | | | _Native Sigma box chart; the first dimension is the category axis and an optional second dimension splits the boxes._ |
| `bulletchart` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/BulletChart/bullet-chart.htm) | `progress` | 🟡 n | warn+explicit approximation |
| | | | | _Sigma progress preserves the primary value and range but not Qlik's per-dimension bullet repetition, target expression, or qualitative segments._ |
| `distributionplot` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Mashups/Content/Sense_Mashups/Create/Visualizations/Distributionplot/distributionplot.htm) | `box-chart` | 🟡 n | warn+skip |
| | | | | _Sigma box chart with all points shown preserves Qlik's value distribution and optional bounding box._ |
| `histogram` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Histogram/histogram.htm) | `bar-chart` | 🟡 n | warn+explicit approximation |
| | | | | _Sigma bar chart emits frequency by numeric value; Qlik's automatic/custom bin boundaries require manual recreation._ |
| `mekkochart` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Mekko-Chart/mekko-chart.htm) | `bar-chart` | 🟡 n | warn+explicit approximation |
| | | | | _Normalized stacked bars preserve group/category contribution; variable group width is not available in Sigma._ |
| `treemap` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/TreeMap/treemap.htm) | `bar-chart` | 🟡 n | warn+explicit approximation |
| | | | | _Stacked bars preserve dimensions and measure contribution; Sigma has no native treemap layout._ |

## Number format

_Qlik qNumFormat.qFmt (an Excel-style number mask) -> Sigma column format (D3 formatString). The mapping is COMPOSITIONAL — sigma_fmt() parses the mask: '$' prefix -> currency, '%' -> percent, and the count of 0/# digits after '.' -> decimals. These rows are PINNED PARSER EXAMPLES that a test asserts sigma_fmt() reproduces, grounding the parser against documented qNumFormat semantics. The old name-substring currency guess (revenue|profit|... -> $,.0f) and the silent ,.0f default were REMOVED (beads-sigma-kvza) — an absent qFmt now yields no format + a loud note._

Authoritative source: <https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Scripting/FormattingFunctions/Num.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `$#,##0` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Scripting/FormattingFunctions/Num.htm) | `$,.0f` | ✅ y · 2026-07-13 | n/a |
| | | | | _Currency, no decimals._ |
| `$#,##0.00` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Scripting/FormattingFunctions/Num.htm) | `$,.2f` | 🟡 n | n/a |
| | | | | _Currency, 2 decimals._ |
| `#,##0` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Scripting/FormattingFunctions/Num.htm) | `,.0f` | 🟡 n | n/a |
| | | | | _Thousands-separated integer._ |
| `#,##0.0%` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Scripting/FormattingFunctions/Num.htm) | `,.1%` | 🟡 n | n/a |
| | | | | _Percent, 1 decimal._ |
| `0.00%` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Scripting/FormattingFunctions/Num.htm) | `,.2%` | 🟡 n | n/a |
| | | | | _Percent, 2 decimals._ |

## Aggregation

_Qlik aggregation function -> Sigma aggregate function, used token-wise by translate_measure. `qlik_fn` is matched case-insensitively; `sigma` is the emitted function. Count(DISTINCT X) is a distinct row (Qlik spells distinct as an inline keyword, Sigma as a separate function). Compositional forms are NOT in this table and stay as cited predicates in translate_measure: simple Set Analysis {<F={v}>} -> If(); arithmetic combinations Sum(a)/Sum(b); and (dropped+flagged) Aggr/Rank/Above/Peek/$()-vars/FirstSortedValue._

Authoritative source: <https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/aggregation-functions.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `sum` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/BasicAggregationFunctions/Sum.htm) | `Sum` | ✅ y · 2026-07-13 | warn+skip |
| `avg` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/BasicAggregationFunctions/Avg.htm) | `Avg` | ✅ y · 2026-07-13 | warn+skip |
| `min` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/BasicAggregationFunctions/Min.htm) | `Min` | 🟡 n | warn+skip |
| `max` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/BasicAggregationFunctions/Max.htm) | `Max` | 🟡 n | warn+skip |
| `count` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/CounterAggregationFunctions/Count.htm) | `Count` | 🟡 n | warn+skip |
| `count_distinct` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/CounterAggregationFunctions/Count.htm) | `CountDistinct` | ✅ y · 2026-07-13 | warn+skip |
| | | | | _Qlik Count(DISTINCT X) -> Sigma CountDistinct(X)._ |

## Control / filter

_Qlik filter/listbox field kind -> Sigma control kind. Only the date case is special: a Sigma `list` control whose target is a datetime column posts fine but Sigma SILENTLY STRIPS the target (dead control) — so date fields become date-range controls. Date detection is COMPOSITIONAL (engine tags $date/$timestamp are authoritative; qNumFormat date pattern + column name are fallbacks) and stays as the cited predicate date_field(). Alternate-state listboxes have no Sigma equivalent -> flagged MANUAL (not emitted); a field not on the denorm element -> skipped+warned._

Authoritative source: <https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Filterpane/filter-pane.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `date` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Filterpane/filter-pane.htm) | `date-range` | ✅ y · 2026-07-13 | n/a |
| | | | | _Field the date_field() predicate tags as date/timestamp — a datetime-bound list control is silently stripped by Sigma._ |
| `field` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Filterpane/filter-pane.htm) | `list` | ✅ y · 2026-07-13 | n/a |
| | | | | _Categorical list control (documented default)._ |

## scalar-function

_Qlik scalar and string-aggregate expression grounding used by normalize-qlik-expressions.py after the vendored converter runs. `translation_status=exact` rows are safe token-level mappings; `approximated` rows are retained only with an explicit warning; `needs-review` rows are removed from the patched converter output. Qlik row-level `&` is exact concatenation and is intentionally distinct from aggregate Concat(), which is not safe to auto-port because DISTINCT/TOTAL/set scope and ordering require chart context._

Authoritative source: <https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/Functions/FunctionsInScriptsAndChartExpressions.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `row_concat_&` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/Operators/StringOperators.htm) | `&` | 🟡 n | n/a |
| | | | | _Row-level text concatenation. This is not Qlik's aggregate Concat() function._ |
| `Upper` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Upper.htm) | `Upper` | 🟡 n | needs-review |
| `Lower` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Lower.htm) | `Lower` | 🟡 n | needs-review |
| `Trim` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Trim.htm) | `Trim` | 🟡 n | needs-review |
| `LTrim` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/LTrim.htm) | `Ltrim` | 🟡 n | needs-review |
| `RTrim` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/RTrim.htm) | `Rtrim` | 🟡 n | needs-review |
| `Left` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Left.htm) | `Left` | 🟡 n | needs-review |
| `Right` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Right.htm) | `Right` | 🟡 n | needs-review |
| `Replace` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Replace.htm) | `Replace` | 🟡 n | needs-review |
| `Len` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Len.htm) | `Len` | 🟡 n | needs-review |
| `Repeat` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Repeat.htm) | `Repeat` | 🟡 n | needs-review |
| `Mid` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Mid.htm) | — (no Sigma equivalent) | 🟡 n | needs-review |
| | | | | _Qlik's start argument is 1-based. The vendored converter leaves Mid() verbatim, so no target is emitted without an explicit index-base proof._ |
| `Index` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/Index.htm) | `IndexOf (candidate only)` | 🟡 n | needs-review |
| | | | | _Qlik is 1-based, returns 0 when absent, supports nth and negative occurrences. A direct IndexOf() rename is not semantically grounded._ |
| `SubStringCount` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/StringFunctions/SubStringCount.htm) | `RegexpCount (candidate only)` | 🟡 n | needs-review |
| | | | | _Qlik searches a literal substring; Sigma RegexpCount interprets the second argument as a regular expression. Metacharacters cannot be passed through unchanged._ |
| `Year` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/DateAndTimeFunctions/Year.htm) | `Year` | 🟡 n | needs-review |
| `Month` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/DateAndTimeFunctions/Month.htm) | `Month` | 🟡 n | warn+retain numeric month |
| | | | | _Both expose month number 1-12, but Qlik also carries the MonthNames text as a dual display value. The numeric date part is retained with an explicit approximation warning._ |
| `Day` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/DateAndTimeFunctions/Day.htm) | `Day` | 🟡 n | needs-review |
| `Hour` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/DateAndTimeFunctions/Hour.htm) | `Hour` | 🟡 n | needs-review |
| `Minute` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/DateAndTimeFunctions/Minute.htm) | `Minute` | 🟡 n | needs-review |
| `Second` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/DateAndTimeFunctions/Second.htm) | `Second` | 🟡 n | needs-review |
| `Fabs` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/NumericFunctions/Fabs.htm) | `Abs` | 🟡 n | needs-review |
| `Sqrt` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/NumericFunctions/Sqrt.htm) | `Sqrt` | 🟡 n | needs-review |
| `Pow` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/NumericFunctions/Pow.htm) | `Power` | 🟡 n | needs-review |
| `Log` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/ExponentialAndLogarithmicFunctions/Log.htm) | `Ln` | 🟡 n | needs-review |
| `Log10` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/ExponentialAndLogarithmicFunctions/Log10.htm) | `Log10` | 🟡 n | needs-review |
| `Exp` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/ExponentialAndLogarithmicFunctions/Exp.htm) | `Exp` | 🟡 n | needs-review |
| `Ceil` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/GeneralNumericFunctions/Ceil.htm) | `Ceiling` | 🟡 n | needs-review |
| `Floor` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/GeneralNumericFunctions/Floor.htm) | `Floor` | 🟡 n | needs-review |
| `Round` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/GeneralNumericFunctions/Round.htm) | `Round` | 🟡 n | needs-review |
| `Fmod` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/GeneralNumericFunctions/Fmod.htm) | `Mod` | 🟡 n | needs-review |
| `Dual` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/FormattingFunctions/Dual.htm) | `numeric argument only (converter approximation)` | 🟡 n | needs-review |
| | | | | _The vendored converter keeps only the numeric argument. That silently loses Qlik's text representation and is therefore removed._ |
| `MinString` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/StringAggregationFunctions/minstring.htm) | `Min (candidate only)` | 🟡 n | needs-review |
| | | | | _Qlik performs alphabetical text ordering and returns a dual value; numeric Min is not an automatic equivalent._ |
| `MaxString` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/StringAggregationFunctions/maxstring.htm) | `Max (candidate only)` | 🟡 n | needs-review |
| | | | | _Qlik performs alphabetical text ordering and returns a dual value; numeric Max is not an automatic equivalent._ |
| `Concat` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/StringAggregationFunctions/concat.htm) | `ListAgg (candidate only)` | 🟡 n | needs-review |
| | | | | _Aggregate Concat() depends on DISTINCT/TOTAL/set scope and Qlik sort-weight semantics. It is not row-level `&`, and a token-only ListAgg rename cannot prove ordering or scope._ |
| `Only` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/ChartFunctions/BasicAggregationFunctions/only.htm) | — (no Sigma equivalent) | 🟡 n | needs-review |
| | | | | _Qlik returns the sole possible value and NULL when cardinality is not exactly one. Passing through the field or guessing Min/Max changes semantics._ |
| `<unknown-function>` | [doc](https://help.qlik.com/en-US/sense/May2026/Subsystems/Hub/Content/Sense_Hub/Scripting/Functions/FunctionsInScriptsAndChartExpressions.htm) | — (no Sigma equivalent) | 🟡 n | needs-review |
| | | | | _Fail closed: an uncataloged callable is removed from patched output and reported; it is never passed through as if Sigma supported it._ |

## workbook-feature

_Qlik workbook interaction/composition semantics -> released Sigma workbook-as-code surfaces. These rows complement viz-kind: they cover presentation, sheet navigation, containers, repeaters, print pagination, gauges, and filter panels._

Authoritative source: <https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/visualizations.htm>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `chart-legend` | [doc](https://help.qlik.com/en-US/sense-developer/May2026/Subsystems/Mashups/Content/Sense_Mashups/Create/Visualizations/Waterfall/waterfall-properties.htm) | `legend` | 🟡 n | warn+preserve chart without guessed legend |
| | | | | _Qlik legend.show/dock maps to the chart's released legend visibility/position. An independent Sigma legend control is not invented unless Qlik provides shared-control semantics._ |
| `drill-down-dimension` | [doc](https://help.qlik.com/en-US/sense-developer/May2026/Subsystems/Mashups/Content/Sense_Mashups/Create/Visualizations/dimensions.htm) | `hierarchy control (manual)` | 🟡 n | capture hierarchy + explicit manual gap |
| | | | | _Qlik qGrouping:H and every qFieldDefs level are discovered. The builder keeps the active first level and reports a manual gap: a populated Sigma hierarchy control requires validated hierarchy metadata and cannot be safely fabricated from chart fields._ |
| `chart-styling` | [doc](https://help.qlik.com/en-US/sense-developer/May2026/Subsystems/Mashups/Content/Sense_Mashups/Create/Visualizations/Waterfall/waterfall-properties.htm) | `element styling` | 🟡 n | warn+omit only the unsupported field |
| | | | | _Preserves supported orientation, stacking, data-label, color, and title/legend visibility settings; does not guess CSS or unsupported renderer fields._ |
| `sheet-tabs` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Sheets/create-sheet.htm) | `navigation` | 🟡 n | warn+retain separate pages |
| | | | | _A multi-sheet Qlik app emits an auto navigation element with page labels on every content page._ |
| `container-tabs` | [doc](https://help.qlik.com/en-US/sense/November2025/Subsystems/Hub/Content/Sense_Hub/Visualizations/Container/create-container.htm) | `tabbed-container` | 🟡 n | warn+flatten children |
| | | | | _Qlik container children and labels map positionally to TabbedContainer/Tab layout children._ |
| `trellis-repeater` | [doc](https://help.qlik.com/en-US/sense/May2025/Subsystems/Hub/Content/Sense_Hub/Visualizations/Trellis/trellis-container.htm) | `trellis` | 🟡 n | warn+flat chart |
| | | | | _Qlik chart/container repeat-by-dimension semantics map to Sigma native chart trellis. They do not map to repeated-container, whose row-card semantics differ._ |
| `row-card-repeater` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/visualizations.htm) | — (no Sigma equivalent) | 🟡 n | explicit gap |
| | | | | _No native Qlik artifact currently discovered has Sigma repeated-container's row-card semantics; do not misuse trellis as a card repeater._ |
| `print-page-break` | [doc](https://help.qlik.com/en-US/sense/May2025/Subsystems/Hub/Content/Sense_Hub/Printing/print-sheet.htm) | — (no Sigma equivalent) | 🟡 n | explicit gap |
| | | | | _Qlik discovery exposes no authored page-break object. Sigma page-break is released but is not synthesized without source print-pagination intent._ |
| `gauge-progress` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Gauge/gauge-chart.htm) | `progress` | 🟡 n | warn+KPI fallback |
| | | | | _Qlik gauge min/max/value and bar/ring presentation map to Sigma progress formula strings._ |
| `filter-panel` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Filterpane/filter-pane.htm) | `control` | ✅ y · 2026-07-13 | explicit unbound sidecar entry |
| | | | | _A Qlik filterpane is decomposed into globally-wired list/date controls; its source filters retain table elementId + columnId references._ |
| `workbook-panel` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Filterpane/filter-pane.htm) | — (no Sigma equivalent) | 🟡 n | explicit gap; preserve existing document.panels on write |
| | | | | _A Qlik filter pane is an in-canvas filtering object, not Sigma document.panels. Do not fabricate a panel. Read-modify-write tools preserve the complete document, including panels already returned by Sigma._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
