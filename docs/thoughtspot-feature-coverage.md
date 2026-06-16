# ThoughtSpot → Sigma feature-coverage matrix

A deliberate "kitchen-sink" stress test: build TS content exercising **every** TS
feature, migrate it through `thoughtspot-to-sigma`, and score each feature. Run
against live trial `team2.thoughtspot.cloud` over the retail star model
`d09e27fd` (CSA.TJ). Established + closed 2026-06-16.

**Verdicts:** ✅ faithful (migrates with parity) · 🟡 flagged degrade (no Sigma
equivalent → sensible down-convert **and the migration flags it**) · ❌ gap
(should work, doesn't). All ❌ found below were FIXED + re-validated this round.

## Charts (24 TS chart types)

| TS chart type | Sigma kind | verdict | evidence |
|---|---|---|---|
| KPI | kpi-chart | ✅ | wb ee2e9596 |
| COLUMN / BAR | bar-chart | ✅ | wb ee2e9596 |
| LINE | line-chart | ✅ | wb ee2e9596 |
| AREA / STACKED_AREA | area-chart | ✅ | wb ee2e9596 (stacked via color dim) |
| STACKED_COLUMN / STACKED_BAR | bar-chart | ✅ | wb ee2e9596 (stacked render) |
| LINE_COLUMN | combo-chart | ✅ | wb ee2e9596 |
| PIE / DONUT | donut-chart | ✅ | wb ee2e9596 |
| SCATTER | scatter (grouped) | ✅ | wb ee2e9596 (distinct points, no collapse) |
| BUBBLE | scatter + size well | ✅ | wb ee2e9596 |
| GEO_AREA | region-map | ✅ | wb ee2e9596 (US choropleth) |
| GEO_BUBBLE | region-map | 🟡 | choropleth not bubbles; point-map needs lat/long TS doesn't supply for a region name — region-map is the faithful degrade |
| PIVOT_TABLE | pivot-table | ✅ | wb ee2e9596 |
| TABLE / ADVANCED_COLUMN | table | ✅ | wb ee2e9596 |
| WATERFALL, FUNNEL, TREEMAP, HEATMAP, HISTOGRAM, GAUGE, SANKEY, PARETO, CANDLESTICK, SPIDER_WEB | table **+ `[<TYPE> → table: no Sigma chart equivalent]`** | 🟡 (was ❌ silent bar) | **FIXED** ts_common.py `_NO_SIGMA_EQUIV` + `_element_core`; flagged table. NOTE: Sigma the product HAS waterfall in the UI, but it is **not in the workbook spec API kind enum** (verified: `waterfall`/`waterfall-chart` → "Invalid kind"), so the spec-based converter can't emit it. Revisit when Sigma adds it to the spec |

## Calculations / formulas (live value-parity)

| class | example | verdict | evidence |
|---|---|---|---|
| Row arithmetic | `GROSS_REVENUE - DISCOUNT` | ✅ | parity to 2dp |
| Row conditional (text) | `if(QTY>10) then 'Bulk' else 'Single'` | ✅ (was ❌ `[Single]`) | **FIXED** thoughtspot.ts `tsWrapColumnRefs`; live `If([Quantity]>10,"Bulk","Single")` → "Single" |
| safe_divide / ratio | `safe_divide(profit,rev)` | ✅ | parity 8dp |
| String (concat/substr) | `concat(first,' ',last)` | ✅ | live |
| Date (year/month/datediff) | `year(date)` | ✅ | live |
| Logical / in-set | `category in {'Electronics','Apparel'}` | ✅ (was ❌ always `[No]`) | **FIXED** same; live `In([Category],"Electronics","Apparel")` → Yes:10/No:15 |
| Aggregate ratio-of-sums | `sum(profit)/sum(rev)` | ✅ | routed to metric, parity |
| Aggregate funcs (avg/min/max) | `average(rev)` | ✅ | parity |
| Distinct count | `unique count(customer)` | ✅ (was ❌ POST-fail) | **FIXED** thoughtspot.ts space-syntax normalize; live `CountDistinct([Customer Key])` → 26 |
| Conditional aggregate | `sum_if(returned=1, rev)` | ✅ | arg-swap correct, parity |
| Window (cumulative_sum/rank/moving_avg) | `cumulative_sum(rev)` | 🟡 (was ❌ silent) | **FIXED** — now emits a warning (Sigma window fns don't resolve in DM elements; recompute in a workbook grouped element) |
| Relative time-intel (`'this year'`/`'last year'`/`'last N quarters'`) + `vs` | `[date].'this year'`, `sales(last year) vs (this year)` | ✅ (was ❌ unhandled) | **FIXED #126** — today-anchored `Year()`/`DateAdd()` boolean filter; period-shifted measures → `SumIf`; `vs` → two-series chart. Live: full 16-viz "Sample Retail - Sales Performance" migrates, Sales Last Year=$183,096,071 exact. `growth of`/waterfall flagged (ordered window) |
| Date buckets `Month(date)`/`Week(date)` | line/area time axis | ✅ #123 | `DateTrunc` calc col; proven single + multi-table |
| Year filter `[date].YYYY` | `[date].2021` | ✅ #124 | `Year()` list filter |
| Bare `top`/`bottom` | `top [sales] by [product]` | ✅ #125 | defaults to 10 (TS default) |
| **RLS** (rls_rules) | row-level security rule | 🟡 (was ❌ silent-drop) | **FIXED** thoughtspot.ts now DETECTS + warns with the rule text + remediation; full auto-port (user-attr + DM filter) via apply_sigma_rls.py is a follow-up |

## Interactivity / formatting

| feature | verdict | evidence |
|---|---|---|
| Liveboard filter → interactive control | ✅ | wb ab4d2020 — Region list + Full Date date-range, both render + wired to master |
| Control on a column no viz surfaces | ✅ (was ❌ workbook 400) | **FIXED** ts_common.py `liveboard_controls` denorm-qualified formula; live wb ab4d2020 (2 controls, was "Dependency not found") |
| Reference / target line → refMarks | ✅ | wrapped value + label.visibility:shown, renders |
| Sorting | ✅ | xAxis.sort carries |
| Number / currency / percent format | ✅ | `$`/`%`/thousands render |
| Colors (by-category + by-measure) | ✅ | category legend + measure gradient |
| Conditional formatting | ✅ (was ❌ silent-drop) | **MAPPED** — TS `client_state` `conditionalFormatting.rows[]` (operator/value/solidBackground) → Sigma `conditionalFormats` (`type:single`, condition, value, `style.backgroundColor`). The host table is emitted as a `pivot-table` (CF only rides pivot/input tables). Live-verified coloring renders. Gradient/data-bar variants still flagged |
| Dynamic / expression title | 🟡 (flagged) | a `{{token}}` title is now FLAGGED (`[FLAGGED: dynamic title not converted]`) — Sigma element titles are plain strings in the spec, no title-templating; flag-not-drop so the literal isn't shipped silently |

## Gaps found → fixed this round

1. **thoughtspot.ts `tsWrapColumnRefs`** — single-quoted string literals were wrapped as column refs (`'Bulk'`→`[Bulk]`), corrupting every `if/then/else` text branch + `in {…}` set. Now masked + emitted double-quoted. *(highest impact)*
2. **ts_common.py `liveboard_controls`** — a control on an un-surfaced column emitted `[OFV/<col>]` (master referencing itself) → workbook 400. Now denorm-qualified `[<view>/<ofv col>]`. *(blocking)*
3. **thoughtspot.ts agg normalize** — TS `unique count(` / `count distinct(` (space) → `[Unique] Count(...)` hard-failed the DM POST. Now normalized to `CountDistinct`.
4. **ts_common.py `_element_core`** — 10 exotic chart types silently became bar-charts. Now flagged degrade-to-table.
5. **thoughtspot.ts** — window functions passed through with no warning; RLS rules silently dropped. Both now warn.
6. **ts_common.py** — conditional formatting silently dropped → now flagged.

**Follow-ups (documented, lower priority):** full CF→pivot-table conditionalFormats map; full RLS auto-port; GEO_BUBBLE point-map (needs lat/long); dynamic-title interpolation.
