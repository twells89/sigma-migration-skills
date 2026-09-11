# DAX → Sigma measure-translation playbook

> A field-tested catalog of how Power BI DAX measures map to Sigma formulas,
> what restructuring each requires, and the traps that silently produce wrong
> numbers. Distilled from the KitchenSink / Employee-Dashboard migrations
> (validated 2026-05-31 against Power BI `executeQueries` DAX on workbook
> an example workbook). Pairs with `dax-to-sigma-coverage.md`
> (the 94-expression coverage spike) — that doc buckets *coverage*; this doc is
> the *how-to* with verified recipes.

Quick map of which Sigma surface a measure lives in:

| DAX measure type | Sigma home | Why |
|---|---|---|
| Simple aggregate | chart/KPI value formula, or DM metric | scalar, context-free |
| Single-predicate `CALCULATE` | `SumIf` / `CountIf` / boolean-mask `Sum(If(...))` | predicate = mask |
| `% of total` (`ALL`) | `PercentOfTotal(agg, "grand_total")` | first-class function |
| `ALLEXCEPT` / grand-total-on-every-row | `GrandTotal(agg)` / `Subtotal(agg,"grand_total")` | repeats total per row |
| Time-intelligence YTD (`TOTALYTD`) | **grouped level table** + `CumulativeSum` | reset is grouping-driven |
| Prior-period (`SAMEPERIODLASTYEAR`/`DATEADD`) | `DateLookback(agg, [dateCol], n, "year"\|"day")` | direct analog |
| `RANKX` | `Rank()` inside a grouped element | window-in-grouping only |
| `RELATED` / `LOOKUPVALUE` | `[Base/REL/Field]` if related, else `Lookup(...)` | join-driven |
| `USERELATIONSHIP` (dynamic join swap) | no equivalent — materialize a parallel element | static joins |

---

## 1. The `color: {by, column}` series shape (line/bar split)

A chart splits into one series per category **iff** it carries a `color` block:

```json
"color": { "by": "category", "column": "<colId>" }
```

- This is *persisted* in the workbook spec (like the native `trellis` facet —
  see below — but unlike tooltip, which stays UI-only: `_tooltip_ui_only`).
- **Small multiples → native `trellis` (NOT UI-only).** The old
  `feedback_sigma_trellis_ui_only` belief predates the `rowsBy`/`columnsBy` finding
  (#460/#462): a spec-authored `element.trellis` DOES bind the facet on the
  readback-safe kinds (bar/line/area/combo/scatter/donut). `build-workbook-from-pbir.rb`
  detects a visual's PBI **"Small multiples"** field well (`SmallMultiples`
  projection role) and calls the shared `TrellisEmit.apply` (pie→donut; kpi/pivot/
  table stay flat). See `docs/sigma-trellis-chart-support.md` +
  `docs/trellis-cross-converter-plan.md`.
- Removing the `color` block collapses the chart to a **single series**.
- **Line builder default = single series** (`beads-sigma-c07`): a line chart
  should NOT emit `color` unless the source PBI visual has a Legend/Series
  binding. Per-year, per-region etc. coloring is the exception, opted into
  explicitly — never the default.

### TRAP — `color` was also doing your grouping reset

When `color:{by:category,column:l-year}` is the *only* thing introducing the
Year dimension, removing it also removes the grouping that a `CumulativeSum`
relies on to reset (see §4). Fix the data (precomputed grouped column), not the
color split. Don't keep a 2-series chart just to get a per-year reset.

---

## 1b. Reference DM metrics as `[Metrics/<name>]`, never `[Master/Metric]`

> Live-verified reference contract. The failed `[Master/Metric]` probe tested a
> column namespace, not Sigma's reserved metric namespace.

A data-model **metric** (e.g. `Absence Hours Per Head`) flows through to a
workbook master and shows up in the master's AVAILABLE METRICS (`describe`) and
in the Sigma UI measure picker. Reference it in a workbook formula as
`[Metrics/<metric name>]`, using the metric's display name rather than its ID.
`[MasterName/Metric Name]` is a column lookup, so `POST/PUT /v2/workbooks/spec`
rejects that invalid form with `400 dependency not found` even when the metric
exists. The error does not establish that the metric is unavailable.

`build-workbook-from-pbir.rb` receives the data-model readback metric census and
uses `[Metrics/<name>]` when an emitted aggregate is formula-equivalent to a
referenceable metric. It keeps the aggregate inline when no metric matches or a
column/metric name collision caused the metric to disappear from readback.

Practical rule for the builder: never emit a workbook column whose formula is a
bare `[Master/<DM metric name>]`. Emit `[Metrics/<metric name>]` only from the
readback-confirmed census; otherwise emit the aggregate body over master column
references. The separate mcp-v2 `metric('<id>', t)` query path can still fail
when a metric depends on a constant-key `m:m` relationship; that query caveat
does not change the workbook formula namespace.

---

## 2. The cross-element-ref-returns-NULL trap (and workarounds)

When a DM/workbook measure references a column reached through a relationship,
the *form* of the reference matters and several forms silently yield NULL.

**The rule** (memory `feedback_sigma_cross_element_ref_form`): cross-element
refs use the **triple-segment** form `[BaseElement/REL_NAME/Field]`, never the
parenthesized friendly form `[Field (REL_NAME)]` — parens collide with
function-call syntax and the bracket parser never resolves them, leaving a
`type:error / Unknown name` column.

**The NULL trap specifically:** a measure like
`DIVIDE([Total Absence Hours],[Headcount])` where `[Headcount]` counts a column
in a *different* element. Three ways it goes wrong and the workarounds:

1. **Constant denominator** (cheapest, when the denominator is a known scalar):
   `Sum([ABS/Hours]) / 363`. Used for `p-perhead` in the KitchenSink. Exact, but
   hardcodes the headcount — re-derive if the population changes.
2. **Relationship-backed DM metric**: define the
   ratio as a DM **metric** with a constant-key join to ALL employees, e.g.
   `Sum([Hours]) / CountDistinct([ABSENCE_RECORDS/Absence -> All Employees/Employee Id])`.
   Reference a readback-confirmed metric in workbook formulas through
   `[Metrics/<metric name>]`; do not treat it as a plain master column or inline
   a relationship-dependent body at the wrong grain. Verify the metric separately
   through the workbook because the mcp-v2 `metric('<id>', t)` query path can fail
   to resolve this constant-key relationship shape.
3. **Constant-key join element**: add a relationship from the fact to a
   single-row "all employees count" element so the denominator travels with every
   fact row. Heaviest, but fully dynamic.

Verify which one you got by `describe`-ing the element and `query`-ing — a NULL
column or a `type:error` in the DDL is the tell.

---

## 3. `ALLEXCEPT` / grand-total-on-every-row → `GrandTotal()`

PBI pattern: a measure that shows the *same* total on every row of a grouped
visual regardless of the row's grouping, e.g.

```DAX
Sick Hours := CALCULATE([Total Absence Hours], ALLEXCEPT(ABSENCE_RECORDS, ...))
              -- filtered to Sick, ignoring the row's Absence Type
```

PBI renders `14539.7` (grand-total sick) on **every** absence-type row.

A plain `SumIf([ABS/Hours], [ABS/Absence Type] = "Sick")` only shows the value
on the Sick row (NULL elsewhere) — because the SumIf still respects the row's
grouping. **Wrap it in `GrandTotal`** to lift it out of the row grouping:

```
GrandTotal(SumIf([ABS/Hours], [ABS/Absence Type] = "Sick"))
```

`GrandTotal(agg)` = `Subtotal(agg, "grand_total")`: it repeats the all-rows
aggregate on every row. This is the clean Sigma mirror of `ALLEXCEPT` /
`ALL`-context overrides. **Verified:** Personal/PTO/Sick all = 14539.7, matching
PBI exactly. Sigma docs: `sigma-computing/grandtotal`.

> For other grain overrides: `Subtotal(agg, "parent_grouping")` mirrors an
> `ALLEXCEPT` that keeps the *outer* grouping; `PercentOfTotal(agg, level)`
> covers the ratio forms (`grand_total` / `parent_grouping` / `row`).

---

## 4. Single-sawtooth YTD via a precomputed grouped column

PBI `TOTALYTD(SUM(...), 'Date'[Date])` is a continuous YTD that **drops back to
the January value at each year boundary** — one line, sawtooth shape. Target
(verified vs PBI): 2025 Jul→Dec `3536,7412,10932,14700,18080,21844`;
2026 Jan→May `3604,7124,9664,11084,12203.5`.

Sigma has no scalar YTD measure. `CumulativeSum` is the building block, but its
**reset is grouping-driven**: "when used in a grouped table the function is
applied to each grouping above the level of the cumulative sum independently"
(`sigma-computing/cumulativesum`). So the year reset only happens if **Year is a
grouping above Month**.

### The working recipe (verified)

1. **Precompute** in a hidden grouped "level table" (`visibleAsSource:false`),
   sourced from the fact master, with **two nested groupings**:
   ```json
   "groupings": [
     { "id": "ys-g-year",  "groupBy": ["ys-year"],  "calculations": [] },
     { "id": "ys-g-month", "groupBy": ["ys-month"], "calculations": ["ys-ytd"] }
   ]
   ```
   columns: `Year` = `Year([ABS/Date])`, `Month` = `DateTrunc("month",[ABS/Date])`,
   `ys-ytd` = `CumulativeSum(Sum([ABS/Hours]))`. The outer Year grouping makes
   CumulativeSum reset every January. Querying this element directly returns the
   exact sawtooth.

2. **Plot it as a SINGLE series.** Point the line chart at the level table,
   group by Month only, and aggregate the precomputed YTD with **`Max()`** (or
   `Avg`/`Min` — each month already has exactly one value):
   ```
   xAxis: month   yAxis: Max([YTDSRC/YTD Absence Hours])   (NO color block)
   ```

### TRAPS that bit us (so the next migration doesn't repeat them)

- **`Sum()` over a level table re-explodes it.** Wrapping the precomputed YTD in
  `Sum(...)` in the downstream chart re-scans the underlying ungrouped rows and
  returns ~1.8M-scale garbage. Use `Max()` (the per-month value is unique).
- **Internal `groupings` on the line element do NOT nest for the reset.** Adding
  `[Year outer, Month inner]` groupings directly on the *line chart* (instead of
  a separate level table) collapses to the xAxis (month-only) grouping —
  CumulativeSum then runs continuously and never resets (Jan 2026 came out 25448
  instead of 3604). The reset must be materialized in a *separate* grouped
  element first.
- **Don't fix the render by keeping `color:{by,column:year}`.** That gives the
  right numbers but renders two lines, not the one continuous sawtooth PBI shows.
- **X-axis: keep the column a true `datetime`, let the time axis sort natively,
  and match PBI's label granularity with the format string.** Bind
  `xAxis: { columnId }` with NO custom `sort` block — a datetime x renders a
  continuous, chronologically-ordered time axis by default; an added
  `xAxis.sort` block can fight that ordering. **The axis-label format is a
  separate decision from the data:** PBI's YTD line labels the axis with the
  **month only** (`Jul, Aug, … Dec, Jan, … May`) — the year boundary is conveyed
  by the sawtooth drop, not by a label. Sigma's default `%b %Y` shows "Jul 2025,
  …, Jan 2026" which reads as a divergence even though the data is identical. Set
  the month column's `format.formatString` to **`%b`** to mirror PBI. The
  underlying values stay distinct datetimes (2025-07 ≠ 2026-01), so chronological
  order and the 11 distinct points are preserved — only the tick *label* changes.
  Note: the MCP `query` tool returns raw datetimes and cannot show you the
  rendered label format or axis order — those are visual properties; confirm them
  in the rendered chart.

---

## 5. Mechanical one-to-one translations (no restructuring)

| DAX | Sigma | Notes |
|---|---|---|
| `SUM(T[A])` | `Sum([T/A])` | prefix differs, mechanical |
| `COUNTROWS(T)` | `Count([T/PK])` | pick a non-null PK; `Count` skips nulls |
| `COUNTROWS` of distinct | `CountDistinct([T/Key])` | |
| `CALCULATE(SUM(T[A]), T[R]="X")` | `SumIf([T/A], [T/R]="X")` | single-predicate; chain with `And` |
| `DIVIDE([Total], CALCULATE([Total], ALL(T)))` | `PercentOfTotal(Sum([T/A]), "grand_total")` | grouped/pivot/viz only |
| `SUMX(T, T[Q]*T[P])` | `Sum([T/Q]*[T/P])` | aggregates take row expressions; `AVERAGEX`→`Avg`, `MAXX`→`Max` |
| `RELATED(C[City])` | `[C/City]` (if related) else `Lookup([C/City],[T/Key],[C/Key])` | `Lookup` = `RELATED`/`LOOKUPVALUE` |
| `WEEKNUM([Date], 2)` (Mon-start) | `Floor((DateDiff("day", DateTrunc("year",[Date]), [Date]) + Mod(Weekday(DateTrunc("year",[Date])) + 5, 7)) / 7) + 1` | Excel-style week-of-year. **Do NOT use `DatePart("week")`** — it's ISO and DIVERGES at year boundaries (WEEKNUM('2021-01-01',2)=1 but ISO=53; '2019-12-30'=53 but ISO=1). `return_type 1`/default (Sun-start) uses the `+6` offset. Verified EXACT vs PBI on 9 boundary dates. |

## 6. Translations needing a date-grouped consumer

| DAX | Sigma | Requires |
|---|---|---|
| `RANKX(ALL(P), [Total Sales])` | `Rank(Sum([T/A]), "desc")` | inside a grouped element; to reuse as a measure across visuals, materialize a per-key aggregate and `Lookup` it. `RankOver`/window-rank silently fails in DM-element calc cols. |
| `SAMEPERIODLASTYEAR` | `DateLookback(Sum([T/A]), [Month of Date], 1, "year")` | consuming element grouped on a date-trunc column |
| `DATEADD('Date'[Date], -30, DAY)` | `DateLookback(Sum([T/A]), [Day of Date], 30, "day")` | same shape as prior-period |
| `TOTALYTD` | grouped `CumulativeSum`, §4 | nested Year▸Month grouping + single-series plot |

## 7. The "hard" DAX is migratable via a child element — `dax-restructure-patterns.rb`

The patterns once parked as (c) ("no Sigma path") are actually (b): they need a
new **data-model element** (custom-SQL or a child grouped table), not a formula
rewrite. `scripts/dax-restructure-patterns.rb` is a reusable library of pure
generators (DAX shape in → postable Sigma DM element out) + a `classify(dax)`
shape detector so this runs unattended. Validated end-to-end against the Comp &
Distribution model (DM `8c342d40`, all parity-exact vs PBI `executeQueries`).

| DAX pattern | Generator | Sigma element it emits | Verified |
|---|---|---|---|
| `CONCATENATEX(VALUES(T[g]), T[txt], sep, …)` | `concatenatex_listagg` | `sql`: `LISTAGG(DISTINCT txt, sep) WITHIN GROUP (ORDER BY …) GROUP BY g` (+ a `COUNT(DISTINCT)` companion) | role lists + per-dept counts 10/8/8/10/11/8 match PBI |
| `CALCULATE(<agg on B>, TREATAS(VALUES(A[k]), B[k]))` | `treatas_virtual_rel` | `sql`: explicit `B JOIN A ON B.k=A.k … GROUP BY A[grp]` — materializes the virtual relationship as a real join | absence-by-dept 8666/4569.2/… exact |
| disconnected `GENERATESERIES` bands + "% in band" | `banded_grouping` | `sql`: range-join fact into a `VALUES` band spine, `COUNT(*)` per band (feed `PercentOfTotal` in the viz) | 183/120/32/6 per band, sums to pop |
| `COUNTROWS(FILTER(T, T[p]=EARLIER(T[p]) && T[m]>EARLIER(T[m])))+1` | `earlier_rank_column` | calc column `RankDense([m],"desc",[p])` | max rank 82 matches |
| `SUMX(TOPN(n, VALUES(T[g]), [m], DESC), [m])` | `topn_sumx` | `sql`: `SELECT g, <agg> AS t … GROUP BY g QUALIFY ROW_NUMBER() OVER (ORDER BY <agg> DESC) <= n` — keeps the top-n groups; sum them via `GrandTotal(Sum([t]))` in the viz | "Top 5 Role Salary" — same 5 ROLEs in same rank order as PBI (Software Engineer▸VP Sales▸Sales Manager▸Forklift Operator▸Solutions Consultant); residual delta = live-vs-cached snapshot drift (365 vs 363 rows), not logic |
| `ADDCOLUMNS(CALENDAR(DATE(a),DATE(b)), "Year",YEAR([Date]), …)` | converter (calc-table branch) | `sql` date-spine element: Snowflake `GENERATOR(ROWCOUNT=>N)` + `DATEADD('day',SEQ4(),start)`; simple date parts stay in SQL, complex derived expressions become sibling Sigma calculated columns | DimDate = **3287 rows, 2018-01-01..2026-12-31**; retail fixture covers Black Friday, Easter, Back to School, and Christmas without NULL columns |

### Calculated retail calendars

For an explicit, literal-bound `CALENDAR`, the converter now keeps the physical
date spine small and translates derived `ADDCOLUMNS` expressions through the
same DAX formula path used for calculated columns. This covers common retail
calendar building blocks:

| DAX | Sigma calculated column |
|---|---|
| `WEEKDAY([Date], 1)` | `Weekday([Date])` (Sunday=1) |
| `WEEKDAY([Date], 2)` / `11` | `Mod(Weekday([Date]) + 5, 7) + 1` (Monday=1) |
| `WEEKDAY([Date], 3)` | `Mod(Weekday([Date]) + 5, 7)` (Monday=0) |
| `EDATE([Date], n)` | `DateAdd("month", n, [Date])` |
| `EOMONTH([Date], n)` | `EndOfMonth(DateAdd("month", n, [Date]))` |
| `VAR ... RETURN`, `IF`, `SWITCH(TRUE())`, `DATE`, `MOD`, `INT` | inlined/mechanical formula rewrites |

The regression oracle is `fixtures/fixture_10_retail_calendar.bim`. It computes
Black Friday by weekday/day range, Easter with Gregorian computus, a
Back-to-School window, and Christmas.

Do not guess at model-dependent table bounds. `CALENDARAUTO()`, dynamic
`CALENDAR(MIN(...),MAX(...))` bounds, and unsupported `GENERATE`/`ROW` table
constructors remain blocked. `migrate-powerbi.rb` stops before posting if a
calculated table contains placeholder SQL, `NULL AS`, or dropped columns;
`--yes` cannot waive it. Only
`--allow-incomplete-calculated-tables "<reason>"` records an explicit exception.

### The TREATAS trap that actually mattered (verify, don't assume)
`Absence Hours (High Earners)` *looked* like a sophisticated P90-threshold
TREATAS filter. Probing PBI (`COUNTROWS(HighEarners)` = **363** = full
population) proved the authored DAX is **degenerate**: the `[P90 Salary]` measure
inside `FILTER(ALL(EMPLOYEES), SALARY >= [P90 Salary])` context-transitions so the
predicate is true for every employee — the measure just returns
`Total Absence Hours`. **The faithful migration is therefore a plain
absence-by-dept sum, and that's a feature of doing real parity, not a shortcut.**
Lesson: when a TREATAS/context measure resists 2–3 SQL interpretations, query the
PBI *intermediate* (`COUNTROWS` of the filtered set, the threshold value) to learn
what the measure actually computes before building the Sigma element.

### Function-name corrections (Sigma ≠ DAX-ish guesses)
`PERCENTILEX.INC`→`PercentileCont` (NOT `PercentileInc`); `STDEVX.P`→
`Sqrt(VariancePop(x))` (there is no `StdDevP`); `VARX.P`→`VariancePop` (NOT
`VarianceP`); `MID/SEARCH` email-domain → `SplitPart([Email],"@",2)`;
`COMBINEVALUES(sep,a,b)`→`[a] & sep & [b]`. All of `Median`, `PercentileCont`,
`VariancePop`, `Exp/Avg/Ln`, `CountIf(Contains(...))`, `RankDense(...,partition)`
are valid in DM metrics AND workbook chart formulas.

## 8. No clean Sigma equivalent — flag for design decision

- **`USERELATIONSHIP`** (per-evaluation join swap): Sigma joins are static. Build
  a parallel relationship element (e.g. a ShipDate-based join) and aggregate
  against it — doubles model surface. The converter should refuse and emit a
  "needs data-model design decision" message rather than guess. (This is the one
  genuine (c); everything in §7 is (b) and has a generator.)

## 9. Time-intelligence → a grouped/leveled DM element (or workbook element)

`SAMEPERIODLASTYEAR`, `DATEADD`, `TOTALYTD`, and hand-rolled prior-period
idioms (`VAR cy=SELECTEDVALUE(Date[Year]) RETURN CALCULATE(SUM(..),ALL(Date[Year]),Date[Year]=cy-1)`)
are **translatable** — as calc columns on a **grouped element grouped on a date
column**. This works at the **data-model layer** (a derived `table` element with
`groupings`) — NOT only in the workbook — so the converter can emit it right
where the PBI measure lived. (Verified 2026-06-02: DateLookback + CumulativeSum
calc columns on grouped DM elements posted clean and queried exact vs PBI. This
is the leveled-table case; contrast `feedback_sigma_window_functions`, which is
about window fns on FLAT/ungrouped calc cols.) What is NOT possible is a *scalar*
DM metric — these need the date grouping, which is why `convert_powerbi_to_sigma`
flags them today.

**Prior period** (`SAMEPERIODLASTYEAR` / `DATEADD` / the SELECTEDVALUE+CALCULATE+ALL
prior-year pattern) → **`DateLookback(value, date, amount, period)`**:
```
# in a table/chart grouped by a date column:
Year           = DateTrunc("year", [Master/Full Date])      # groupBy (DATE, not the int year!)
Net Revenue    = Sum([Master/Net Revenue])                  # aggregate
Net Revenue PY = DateLookback([Net Revenue], [Year], 1, "year")   # references the sibling agg + date
YoY %          = ([Net Revenue] - [Net Revenue PY]) / [Net Revenue PY]
```
groupings: `[{groupBy:[Year], calculations:[Net Revenue, Net Revenue PY, YoY %]}]`.
Constraints (Sigma docs): the `date` arg must be a **date** column (DateTrunc), the
`value` must be **unique within the date grouping** (move extra dims to other
groupings), and `period` ∈ year/quarter/month/week/day/hour/minute/second.
**Validated 2026-06-02**: this reproduced PBI's YoY on the Retail-Trends migration
to the cent (2025 +5.38%, 2026 −26.92%; PY null for the first year). The
`DateLookback` calc was applied to live workbook `01b3487c` and queried back.

**YTD** (`TOTALYTD`) → **`CumulativeSum(Sum([..]))`** in a table with **two
grouping LEVELS** — Year as a *separate outer* level, Month inner:
`groupings:[{groupBy:[Year]}, {groupBy:[Month], calculations:[Net, YTD]}]`.
The cumulative resets per outer (Year) level ONLY when Year is its own level;
putting `groupBy:[Year,Month]` in ONE level does **not** reset (it ran straight
through 2024→2025 in testing: Jan-2025 YTD came back as the 2024 total + Jan
instead of just Jan). Verified the two-level form resets correctly (Dec-2025
YTD = the 2025 total). See `dax-to-sigma-coverage.md` #3.

> Converter note: today `convert_powerbi_to_sigma` drops these and warns. It should
> instead recognize the prior-year/YTD idioms and emit a "build a date-grouped
> element with DateLookback/CumulativeSum" instruction (bead filed). Until then,
> the agent adds them as workbook calc columns per the recipe above.

**Headline KPI from a grouped time-intel element (bead 525l).** A single-value
PBI card bound to a time-intel measure (e.g. a "Net Revenue YoY %" headline)
must consume the GROUPED element, which has one row per period — so a bare
row-level ref (`[YR/Net Revenue YoY %]`, agg `nil`) is **nondeterministic**
(null or an arbitrary period's row), and `Last(...)` depends on sort order.
The verified deterministic form is "the latest period's value":

```
Sum(If([YR/Year] = Max([YR/Year]), [YR/Net Revenue YoY %], Null))
```

`Max([Year])` finds the latest period over the whole element, the `If` nulls
every other row, and the `Sum` collapses to that single value. The same formula
is also safe in a chart **grouped by** that date column (within each group
`Max(date) = date`, so it degrades to the per-period value) — which is why
`migrate-powerbi.rb` emits it as the field's verbatim `formula`
(`build-workbook-from-pbir.rb`'s `measure_formula` hook) for every time-intel
headline/YoY/PY/YTD field-map entry, covering both the KPI and date-grouped
chart consumers. Validated live on the Retail-Trends migration (−13.58% = the
2026 YoY, matching PBI's headline card).

## 10. Bar vs Column orientation (chart fidelity)

PBI **`barChart`/`clusteredBarChart`/`stackedBarChart`** render **horizontal**;
**`columnChart`/`clusteredColumnChart`** render **vertical**. Both map to Sigma
`bar-chart`; set **`orientation: "horizontal"`** on the element for the *Bar*
family and **omit** it for the *Column* family. Sigma's `orientation` accepts
**only `"horizontal"`** — vertical is the default (field absent); sending
`"vertical"` is rejected `invalid_request`. The xAxis(category)/yAxis(value)
binding stays the same either way — the flag just flips rendering. Sigma may
*default* a single-series bar to horizontal, so emit it explicitly to match the
source. (`extract-pbir.py` HBAR_TYPES + `build-workbook-from-pbir.rb` handle this;
verified via `/v2/workbooks/{id}/spec` PUT round-trip 2026-06-02.)

---

## Cross-links

- Sigma docs: [`GrandTotal`](https://help.sigmacomputing.com/sigma-computing/docs/grandtotal),
  [`CumulativeSum`](https://help.sigmacomputing.com/sigma-computing/docs/cumulativesum),
  [`PercentOfTotal`](https://help.sigmacomputing.com/sigma-computing/docs/percentoftotal),
  [pivot subtotals](https://help.sigmacomputing.com/sigma-computing/docs/pivot-table-subtotals).
- Skill refs: `dax-to-sigma-coverage.md` (coverage buckets), `spec-fixups.md`
  (DM/workbook post fixups), `connection.md` (Phase 1–2 extract).
- Memory: `feedback_sigma_cross_element_ref_form` (triple-segment refs),
  `feedback_sigma_window_functions` (window-fn silent failures in calc cols),
  `_tooltip_ui_only` (UI-only field — contrast with `color` AND the native
  `trellis` facet, both of which ARE persisted). NOTE
  `feedback_sigma_trellis_ui_only` is STALE — the `rowsBy`/`columnsBy` trellis is
  spec-authored now (small multiples → `TrellisEmit.apply`; see above).
- Beads: `c07` (line default single series), `2tf` (invalid Master/metric probe
  for the cross-element ratio), `tkd` (post fixups).
