# Tableau window / table calcs → Sigma-native window math

**Status: WINPROBE-validated 2026-06-12 (bead beads-sigma-427).** Every mapping
below was proven live against org `tj-wells-1989` / `CSA.TJ` with **930/930
cells exact** vs warehouse SQL ground truth, on **ONE data-model base element
with ZERO Custom SQL elements**. Regression fixture:
`corpus/tableau/winprobe-window-functions/` (Tableau wb
`aa126c36-608a-402c-9733-2c83797bc65c` on the 10ay/dataflow site).

## The family rule (load-bearing) — CORRECTED 2026-07-15

What gates a window function is the **function family, NOT where the formula
lives**. The earlier "chart yAxis is the ONLY verified context" rule was wrong;
it over-generalized the `*Over` restriction (below) onto the whole native family.

- **Sigma-native window functions** (`Cumulative*`, `Moving*`, `Rank`,
  `RankDense`, `RankPercentile`, `RowNumber`, `Lag`, `Lead`, `PercentOfTotal`)
  resolve to real Snowflake `OVER(...)` in **every** calc-column context tested:
  chart-element viz formulas on the yAxis, workbook-table calc columns (both
  **grouped** and **ungrouped / "master"**), **and data-model-element calc
  columns**. Live-verified 2026-07-15 by `scripts/probe-window-contexts.rb`
  (9 functions × 3 contexts, resolve-vs-error on the live CSV export against the
  WINPROBE Base DM). Originally surfaced by a customer report that MovingSum
  worked in a table calc column, contradicting the old rule.
- The `*Over` family (`SumOver`, `MaxOver`, `RankOver`, `CountOver`, …) is
  **`Unknown function` in every spec context** — never emit those. This is the
  ONLY window restriction, and it holds across all three contexts above.

**What the converter emits:** `build-charts-from-signals.rb` places these on the
chart yAxis — verified, and the default. Table / DM-element calc columns are
**equally valid** targets: prefer one when a windowed measure must live in a
table rather than a chart, instead of forcing a hidden helper-element workaround.
The Phase-6 actuals collector reads the plotted axis/encoding columns, so
auto-emitted measures land on the yAxis *for collection* — a collector detail,
not a Sigma capability limit.

> **Gate:** negative-capability claims ("X silently errors in context Y") must
> be re-proven by running `scripts/probe-window-contexts.rb`, never asserted
> from a point-in-time memory. This section was corrected exactly because the
> old claim rode a cited memory without a re-probe.

Cumulative/rank functions **follow the chart's `xAxis.sort`** and
**auto-partition by the chart's color/series dim**. Tableau's
`<computed-sort>` ("sort field X by measure Y") must therefore be carried into
`xAxis.sort` — `build-charts-from-signals.rb` adds a hidden companion
aggregate column and targets the sort at it when the sort measure isn't
plotted (pareto / rank charts).

## The mapping table (all auto-emitted by build-charts-from-signals.rb)

| Tableau | Sigma | Notes |
|---|---|---|
| `RUNNING_SUM(agg)` | `CumulativeSum(agg)` | follows xAxis sort |
| `RUNNING_AVG / MAX / MIN / COUNT(agg)` | `CumulativeAvg / Max / Min / Count(agg)` | |
| `WINDOW_AVG(agg, -n, 0)` | `MovingAvg(agg, n)` | Tableau bounds are (first, last) offsets; Sigma takes positive back[, fwd] counts |
| `WINDOW_*(agg, -n, m)` | `Moving*(agg, n, m)` | SUM/MAX/MIN/COUNT same pattern |
| `WINDOW_STDEV(agg, -n[, m])` | `MovingStdDev(agg, n[, m])` | |
| `agg / WINDOW_SUM(agg)` (unbounded, same agg) | `PercentOfTotal(agg, "grand_total")` | share-of-total |
| same, but Tableau's window is PARTITIONED (compute-using a subset of the view dims) | `PercentOfTotal(agg, "parent_grouping")` — or `"row"`/`"column"` on pivots (normalize within each pivot row/column) | **the common per-partition percentage** ("% within each direction/category"). `parent_grouping` is live-verified in the sibling powerbi-to-sigma skill; `"column"` was live-verified here 2026-07-10 (a 4-direction × N-preset pivot whose cells sum to 100% per column). A `grand_total`-only mapping silently mis-normalizes every partitioned calc — two independent field runs hit this. |
| `RUNNING_SUM(agg) / TOTAL(agg)` (same agg) | `CumulativeSum(PercentOfTotal(agg, "grand_total"))` | pareto; accumulation follows xAxis sort |
| `RANK(agg)` / `RANK_DENSE` / `RANK_PERCENTILE` | `Rank / RankDense / RankPercentile(agg, "desc")` | **Tableau defaults to DESC, Sigma to asc — the direction arg is mandatory** |
| `INDEX()` | `RowNumber()` | |
| `LOOKUP(agg, -n)` | `Lag(agg, n)` | negative offset = backward = Lag (the pre-2026-06-12 Lag/Lead mapping was reversed) |
| `LOOKUP(agg, n)` | `Lead(agg, n)` | |
| unbounded `WINDOW_MAX / MIN / SUM(agg)`, standalone `TOTAL(agg)` | hidden **two-level grouped helper** | see below |

### Week alignment

Tableau week-trunc is **Sunday-anchored**; Sigma `DateTrunc("week")` follows
the warehouse week start (Monday on Snowflake). Use the verified arithmetic
(`Weekday()` / `DatePart("weekday")` is 1 = Sunday):

```
DateAdd("day", 1 - Weekday([Master/Order Date]), DateTrunc("day", [Master/Order Date]))
```

### Unbounded partitioned WINDOW_MAX / MIN / SUM → two-level helper

A constant-per-partition window aggregate cannot be a single chart formula.
`build_window_helper` emits a hidden grouped element
(`visibleAsSource: false`) sourcing the master:

- **outer grouping (g1)** = the partition dims (chart color dim / pivot
  `rowsBy`; a constant `All Rows = 1` key when unpartitioned), computing the
  stage aggregates (`Max([value])` / `Min([value])` / `Sum([value])`)
- **inner grouping (g2)** = the addressing dims (chart x dim / pivot
  `columnsBy`), computing the window's operand (`Sum([Master/X])`)

The chart/pivot sources the helper and references the stage column via
`Max([Helper/Stage])` (or `Min` for WINDOW_MIN). **NEVER `Sum` — the
broadcast-down gotcha:** group calcs broadcast to base-grain rows when a chart
re-aggregates a grouped source, so `Sum` multiplies the constant by the row
count; `Max`/`Min` over identical replicas is exact.

### Measure Names / Measure Values long format

Tableau exports Measure-Names worksheets as LONG rows
(`Measure Names, <dim>, Measure Values`). build-charts dissolves the shape
into ONE multi-measure chart (one yAxis column per measure, **named with the
verbatim Tableau measure label** — `auto-parity-plan.rb` pivots the long CSV
to wide and matches by display name). Validated 384/384 on the WINPROBE
weekly funnel (CountD + Sum + ratio calc per week).

## STAYS MANUAL — flag, never guess

No validated mapping; `extract-calc-fields.rb` keeps `requires_custom_sql`
for these and build-charts emits a STAYS MANUAL warning:

- `WINDOW_MEDIAN`, `WINDOW_PERCENTILE`, `WINDOW_CORR`, `WINDOW_COVAR(P)`,
  `WINDOW_VAR(P)`, `WINDOW_STDEVP`
- `PREVIOUS_VALUE`, `SIZE()`, `FIRST()`, `LAST()` (incl. as window bounds) —
  but `FIRST()/LAST()` used as a row filter has a recipe, see Complex composites
- `RANK_MODIFIED` (no modified-rank variant in Sigma). **`RANK_UNIQUE` is NOT
  fully manual** — build-charts rewrites it to `RowNumber()` (a sort-dependent
  approximation); see the Top-N composite below for the sharp edge + recipe.
- shifted windows (`WINDOW_*(agg, 1, 3)` — first > 0 or last < 0)
- any compute-using / addressing variant beyond the default `Table (Across)`
  or a simple one-dim partition: "restart every", pane-relative addressing,
  compute-along-a-non-axis-dim. Detect and flag.
- cumulative/moving formulas inside a PIVOT grid (only the two-stage helper
  shape is pivot-validated)

Multi-dim partitions beyond a single color split are **untested** — the build
emits a verify-warning when it detects one.

## Complex composites — recognize, then build (don't drop)

The hard residue of dense exec workbooks (verified against a real customer
Partner-analytics .twb, 2026-06-29). Some are auto, some manual — but all have a
known Sigma recipe, so apply it rather than leaving the tile empty.

### Top-N: `RANK_UNIQUE(<expr>) <= N` / `RANK(<expr>) <= N`
build-charts detects this idiom in two places (translate_window_calc):

**On the Filters shelf** (the real enterprise "Top 25 Partners" idiom — a boolean calc
kept on `true`). build-charts now emits a **native Sigma `kind:top-n` element
filter** — order-independent, the proper fix:
- **Clean aggregate operand** (`RANK_UNIQUE(SUM(x))<=N`) → a `kind:top-n` filter
  keyed on the ranked measure, `rowCount=N`, `rankingFunction` = `row-number`
  (RANK_UNIQUE, unique ranks) or `rank` (RANK, ties). The tile is also sorted by
  that measure DESC so the visible order matches. `<N` keeps N−1; `<=N` keeps N.
- **EXCLUDE/INCLUDE-LOD operand** (`RANK_UNIQUE(sum({EXCLUDE …}))<=N`) → **NOT
  auto-emitted** (the operand can't be translated to a measure to rank on). It is
  **surfaced** with an actionable note: build the LOD as a helper measure first
  (below), then add a `kind:top-n` filter ranked by it. Never a sort-dependent
  `RowNumber()`.
- `>=N` / `>N` (rank N-or-worse) are not a fixed-count bottom-N → surfaced, not
  auto-emitted.

**As a plotted measure on the yAxis** (rare) → `RowNumber()<=N` + the tile is
**auto-sorted** by the recorded `ranked_measure` DESC (`RowNumber()` follows the
viz sort). Prefer re-authoring as a Filters-shelf top-N.

### Period-over-period % change: `(ZN(SUM(x)) − LOOKUP(SUM(x), −1)) / ABS(LOOKUP(SUM(x), −1))`
**Now AUTO** (build-charts reduces `ZN→Coalesce(_,0)`, `ABS→Abs`, `LOOKUP(-1)→Lag`)
to a yAxis viz formula — emitted on a chart that should be sorted by the date dim:
```
(Coalesce(Sum([Master/x]), 0) - Lag(Sum([Master/x]), 1)) / Abs(Lag(Sum([Master/x]), 1))
```
Format as a percent. (One of the most common BI calcs — QoQ/MoM % change.)

### Nested LOD inside an aggregate: `COUNTD(IF {FIXED [id] : SUM([x])} <> 0 THEN [id] END)`
"Count distinct entities whose per-entity total is non-zero." No single Sigma
formula. Recipe: a FIXED-LOD **helper element** grouped by `[id]` computing
`Sum([Master/x])`, then `CountDistinct([id])` filtered to `helper <> 0` — or a
`kind:sql` element with a `GROUP BY [id] HAVING SUM(x) <> 0` subquery. This is
the helper-element chain (`<out>-lod-chains.json`); if it can't be wired,
escalate via gap-scout rather than emit a partial count.

### Positional row filters: `FIRST() == 0`, `LAST() == 0`
"Keep only the first/last row." No chart-formula mapping. Recipe: for
`LAST()==0` (latest period) use a `[date] = Max([date])` filter, or a
`RowNumber()`-desc `= 1` filter on the sorted element; verify against the source.

### Extract-based (Hyper) workbooks
If the .twb carries a Hyper extract, Tableau's numbers are a **frozen snapshot**
while Sigma reads **live** warehouse. Expect value drift — reconcile Phase-6
expected values against the live warehouse (or the same extract refresh), and
report drift as drift, NOT as a migration defect.

## Manual-residue fallback: Custom SQL

The old "every window calc needs a Custom SQL element" rule is **disproven**
for the table above — reserve `kind: "sql"` DM elements for the manual
residues, translated as ANSI `OVER(...)` (see SKILL.md Phase 3 for the
element shape).
