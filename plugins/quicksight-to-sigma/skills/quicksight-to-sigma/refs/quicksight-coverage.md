# Quicksight → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill quicksight --out refs/quicksight-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing (beads-sigma-kvza).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 44 documented constructs across 4 dimensions; 6 live-verified.

## Visualization / chart kind

_QuickSight Definition.Sheets[].Visuals[] visual type -> Sigma workbook element kind. SINGLE SOURCE OF TRUTH for build-workbook-from-quicksight.rb's KIND / QS_FALLBACK / QS_UNSUPPORTED dispatch. Three row classes: (1) NATIVE — a row with no `unsupported_reason` maps directly to a Sigma kind (goes into KIND); Gauge/Funnel/TreeMap are native-dispatch approximations (Sigma has no gauge/funnel/treemap element, so they reuse kpi-chart / bar-chart) and carry a `notes` rationale. (2) FALLBACK — `fallback:true` + `unsupported_reason`: Sigma has no native kind, so the visual is DATA-MIGRATED as `sigma` (table/bar) with a loud warning (goes into QS_FALLBACK + QS_UNSUPPORTED). (3) DROP — `sigma:null` + `unsupported_reason` and no fallback: no underlying dim+measure to migrate, so the visual is dropped with a loud warning (goes into QS_UNSUPPORTED only). All three are already loud; this catalog makes the mapping data-driven and cited._

Authoritative source: <https://docs.aws.amazon.com/quicksight/latest/APIReference/API_Visual.html>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `KPIVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_KPIVisual.html) | `kpi-chart` | ✅ y · 2026-07-13 | native |
| | | | | _Single-value KPI tile._ |
| `BarChartVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_BarChartVisual.html) | `bar-chart` | ✅ y · 2026-07-13 | native |
| | | | | _BarsArrangement -> Sigma bar stacking (compositional, qs_bars_stacking)._ |
| `LineChartVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_LineChartVisual.html) | `line-chart` | ✅ y · 2026-07-13 | native |
| `PieChartVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_PieChartVisual.html) | `pie-chart` | ✅ y · 2026-07-13 | native |
| | | | | _Mapped to donut-chart in code only when DonutOptions.ArcOptions.ArcThickness is present and != WHOLE (compositional)._ |
| `ComboChartVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_ComboChartVisual.html) | `combo-chart` | 🟡 n | native |
| `ScatterPlotVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_ScatterPlotVisual.html) | `scatter-chart` | 🟡 n | native |
| | | | | _Sigma scatter axis is a GROUPING axis; the builder binds it to a hidden grouped source (compositional)._ |
| `TableVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_TableVisual.html) | `table` | 🟡 n | native |
| `PivotTableVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_PivotTableVisual.html) | `pivot-table` | 🟡 n | native |
| | | | | _pivot-table columnsBy/rowsBy sorts are not spec-expressible (warned + skipped)._ |
| `GaugeChartVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_GaugeChartVisual.html) | `kpi-chart` | 🟡 n | native-approximation |
| | | | | _Sigma has no gauge element kind; a gauge surfaces a single value -> kpi-chart (mirrors the PBI builder)._ |
| `FunnelChartVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FunnelChartVisual.html) | `bar-chart` | 🟡 n | native-approximation |
| | | | | _Sigma has no funnel element kind; category+measure reads as bars -> bar-chart._ |
| `TreeMapVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_TreeMapVisual.html) | `bar-chart` | 🟡 n | native-approximation |
| | | | | _Sigma has no treemap element kind; category+measure -> bar-chart._ |
| `FilledMapVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilledMapVisual.html) | `region-map` | 🟡 n | native |
| | | | | _Region NAME (state/country/city/zip) -> Sigma region-map; regionType inferred from the geo column name (compositional, region_type_for)._ |
| `GeospatialMapVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_GeospatialMapVisual.html) | `region-map` | 🟡 n | native |
| | | | | _region-map by default; becomes point-map in code only when an explicit latitude+longitude field pair is present (compositional, latlong_pair)._ |
| `WaterfallVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_WaterfallVisual.html) | `bar-chart` | 🟡 n | data-migrate-as-fallback+warn |
| | | | | _Data-migrated (dims+measures) as a bar-chart with a loud per-visual warning._ |
| `HistogramVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_HistogramVisual.html) | `bar-chart` | 🟡 n | data-migrate-as-fallback+warn |
| `HeatMapVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_HeatMapVisual.html) | `table` | 🟡 n | data-migrate-as-fallback+warn |
| `BoxPlotVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_BoxPlotVisual.html) | `table` | 🟡 n | data-migrate-as-fallback+warn |
| `SankeyDiagramVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_SankeyDiagramVisual.html) | `table` | 🟡 n | data-migrate-as-fallback+warn |
| `WordCloudVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_WordCloudVisual.html) | `table` | 🟡 n | data-migrate-as-fallback+warn |
| `RadarChartVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_RadarChartVisual.html) | `table` | 🟡 n | data-migrate-as-fallback+warn |
| `LayerMapVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_LayerMapVisual.html) | — (no Sigma equivalent) | 🟡 n | drop+warn |
| `InsightVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_InsightVisual.html) | — (no Sigma equivalent) | 🟡 n | drop+warn |
| | | | | _A single-computation MAX/MIN narrative is reproduced as a Sigma dynamic text element (compositional, qs_insight_text) — otherwise dropped._ |
| `CustomContentVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_CustomContentVisual.html) | — (no Sigma equivalent) | 🟡 n | drop+warn |
| `PluginVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_PluginVisual.html) | — (no Sigma equivalent) | 🟡 n | drop+warn |
| `EmptyVisual` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_EmptyVisual.html) | — (no Sigma equivalent) | 🟡 n | drop+warn |

## Number format

_QuickSight FormatConfiguration.NumericFormatConfiguration variant -> Sigma column number format (D3 formatString in {kind:number, formatString}). IMPORTANT: these rows DOCUMENT the D3 targets a real QuickSight FormatConfiguration would map to; the builder does NOT yet parse FormatConfiguration, so today fmt_for() consumes NONE of these rows — it returns nil (no format) and appends a LOUD 'no source format found' warning so a Sigma format can be applied by hand. This replaces the removed disease: a column-NAME substring guess (case name when /revenue|profit|cost|.../ -> '$,.0f'; /margin|pct|percent|.../ -> '.1%') with a silent ',.0f' else-default. Name-substring format guessing is GONE and must never return. When FormatConfiguration parsing is added, wire it through these cited rows._

Authoritative source: <https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumericFormatConfiguration.html>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `CurrencyDisplayFormatConfiguration` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_CurrencyDisplayFormatConfiguration.html) | `$,.2f` | 🟡 n | warn+unformatted |
| | | | | _Currency with thousands separator, 2 decimals (QS default). DecimalPlacesConfiguration overrides the decimals._ |
| `CurrencyDisplayFormatConfiguration_0` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_CurrencyDisplayFormatConfiguration.html) | `$,.0f` | 🟡 n | warn+unformatted |
| | | | | _Currency, 0 decimals (DecimalPlacesConfiguration.DecimalPlaces=0)._ |
| `PercentageDisplayFormatConfiguration` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_PercentageDisplayFormatConfiguration.html) | `,.1%` | 🟡 n | warn+unformatted |
| | | | | _Percentage, 1 decimal. Sigma % multiplies a 0-1 ratio by 100, matching QS._ |
| `NumberDisplayFormatConfiguration` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumberDisplayFormatConfiguration.html) | `,.0f` | 🟡 n | warn+unformatted |
| | | | | _Plain number, thousands separator, 0 decimals (integer). DecimalPlacesConfiguration overrides the decimals._ |
| `NumberDisplayFormatConfiguration_2` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumberDisplayFormatConfiguration.html) | `,.2f` | 🟡 n | warn+unformatted |
| | | | | _Plain number, 2 decimals._ |

## Aggregation

_QuickSight measure AggregationFunction -> Sigma aggregate function. Covers the SimpleNumericalAggregation enum values the builder resolves for NumericalMeasureField (nested SimpleNumericalAggregation) and CategoricalMeasureField (plain-string COUNT/DISTINCT_COUNT). SINGLE SOURCE OF TRUTH for the AGG hash. The old code silently defaulted an unmapped aggregation to Sum() (meas_col) / Avg() (reference-line) — that is now a LOUD warn + neutralize. Compositional constructs stay as cited code and are NOT in this flat table: the filtered *If variants (SumIf/AvgIf/CountIf/CountDistinctIf/MinIf/MaxIf) and the scalar/aggregate function-name rewrites live in qs_expr_to_sigma() (function-head substitution, longest-first, negative-lookbehind guarded). QuickSight aggregations with no simple Sigma equivalent (STDEV/STDEVP/VAR/VARP/PERCENTILE) are intentionally absent -> they hit the loud fallback._

Authoritative source: <https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumericalAggregationFunction.html>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `SUM` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumericalAggregationFunction.html) | `Sum` | ✅ y · 2026-07-13 | warn+neutralize |
| | | | | _Filtered SumIf handled compositionally in qs_expr_to_sigma._ |
| `AVERAGE` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumericalAggregationFunction.html) | `Avg` | ✅ y · 2026-07-13 | warn+neutralize |
| `MIN` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumericalAggregationFunction.html) | `Min` | 🟡 n | warn+neutralize |
| `MAX` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumericalAggregationFunction.html) | `Max` | 🟡 n | warn+neutralize |
| `COUNT` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_CategoricalAggregationFunction.html) | `Count` | 🟡 n | warn+neutralize |
| | | | | _CategoricalMeasureField AggregationFunction is a plain string ('COUNT'), honored verbatim._ |
| `DISTINCT_COUNT` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_CategoricalAggregationFunction.html) | `CountDistinct` | 🟡 n | warn+neutralize |
| | | | | _Hardcoding COUNT here once turned every QS DISTINCT_COUNT KPI into a non-distinct Count (RCA #2)._ |
| `MEDIAN` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_NumericalAggregationFunction.html) | `Median` | 🟡 n | warn+neutralize |

## Control / filter

_QuickSight sheet-level FilterControl / ParameterControl wrap type -> Sigma control kind. SINGLE SOURCE OF TRUTH for build_qs_control's list-vs-date-range decision. Only the date pickers are special: DateTimePicker / RelativeDateTime -> a Sigma date-range control (a `list` control bound to a datetime column is silently STRIPPED by the spec API on POST, so a date target MUST be a date-range control). Everything else (Dropdown/List/Slider/TextField/TextArea) is a categorical `list` control — the DOCUMENTED default, not a silent guess. One compositional override stays as cited code (NOT in this table): a control whose TARGET COLUMN NAME matches /(^|_)(date|dt|timestamp)(_|$)/ is also forced to date-range, because a list control on a datetime column is dead. A what-if scalar parameter control (no bound column) has no Sigma list-control equivalent and is recorded unbound/manual (its default value is inlined)._

Authoritative source: <https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilterControl.html>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `Dropdown` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilterDropDownControl.html) | `list` | 🟡 n | list |
| | | | | _FilterDropDownControl / ParameterDropDownControl bound to a dataset column._ |
| `List` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilterListControl.html) | `list` | 🟡 n | list |
| `Slider` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilterSliderControl.html) | `list` | 🟡 n | list |
| | | | | _Numeric slider bound to a column becomes a Sigma list control (Sigma range slider is a UI re-author)._ |
| `TextField` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilterTextFieldControl.html) | `list` | 🟡 n | list |
| `TextArea` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilterTextAreaControl.html) | `list` | 🟡 n | list |
| `DateTimePicker` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilterDateTimePickerControl.html) | `date-range` | 🟡 n | n/a |
| | | | | _A list control on a datetime column is stripped by the spec API -> must be a date-range control._ |
| `RelativeDateTime` | [doc](https://docs.aws.amazon.com/quicksight/latest/APIReference/API_FilterRelativeDateTimeControl.html) | `date-range` | 🟡 n | n/a |
| | | | | _Relative date control -> Sigma date-range._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
