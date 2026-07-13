# Qlik → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill qlik --out refs/qlik-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing (beads-sigma-kvza).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 22 documented constructs across 4 dimensions; 11 live-verified.

## Visualization / chart kind

_Qlik object vizType -> Sigma workbook element kind. The single source of truth for build-sigma-workbook.py's chart classifier. `auto-chart` is NOT in this table — it is resolved compositionally by shape (no dims -> KPI; >=2 dims -> grouped table; 1 temporal dim -> line; else bar), a cited predicate in build_element._

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
| `map` | [doc](https://help.qlik.com/en-US/sense/Subsystems/Hub/Content/Sense_Hub/Visualizations/Map/Map.htm) | `region-map` | 🟡 n | warn+skip |
| | | | | _build_element refuses to guess a region grain and warns+skips if it cannot resolve one._ |

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

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
