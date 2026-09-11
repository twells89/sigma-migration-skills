# DAX → Sigma Formula Coverage Spike

> Tracking issue: `beads-sigma-bjb`

## Question

Should we add a `convert_dax_to_sigma_formula` MCP tool alongside the existing
`convert_tableau_formula_to_sigma` / `convert_sql_to_sigma_formula` reference
implementations, to support a future Power BI → Sigma converter skill?

## Method

Desk research + hand translation. Ten DAX measures spanning the five categories
called out in the brief (simple aggregates, time intelligence, filter context,
relationships, iterators). Each is translated to Sigma's formula language and
bucketed:

- **(a) Mechanical** — direct one-to-one or near-one-to-one rewrite. The
  converter only needs syntax-level transforms.
- **(b) Requires data-model restructuring** — translation is possible, but only
  if the surrounding data model is reshaped first (e.g. adding a join, building
  a grouped element, materialising a per-dimension aggregate). The formula text
  alone isn't enough.
- **(c) No Sigma equivalent** — the underlying semantic doesn't exist in Sigma.

References used: `sigma-workbooks/reference/specification/formulas.md`,
`sigma-data-models/reference/calc-columns.md`, Sigma-Docs MCP entries for
`PercentOfTotal`, `CumulativeSum`, `DateLookback`, `Lookup`, `DateAdd`,
period-over-period analysis.

### Pre-finding: the "reference implementations" don't exist as MCP tools

The brief assumed `convert_tableau_formula_to_sigma` and
`convert_sql_to_sigma_formula` were callable MCP tools. They are not — the
`Sigma-MCP` server exposes `begin_session`, `search`, `list_documents`,
`describe`, `query`, and `create_workbook`. Nothing else.

The `tableau-to-sigma` skill (`tableau-to-sigma/SKILL.md`) does **not** wire any
formula-conversion tool into its pipeline. Its formula-translation step is
entirely "agent reads `formulas.md`, hand-writes Sigma formulas, validates by
posting the spec and running `describe`/`query` after publish." So the
recommendation below has to address: should there be such a tool *at all*?

---

## Worked examples

For brevity each example assumes a workbook table named `Sales` with columns
`Amount`, `Qty`, `Price`, `Region`, `OrderID`, `OrderDate`, `ShipDate`,
`CustomerKey`, `Category`; and a `Customer` element with `CustomerKey`, `City`.
Where a Sigma formula references `[Sales/...]` it is a calc column on an
element sourced from `Sales`; bare `[col]` references mean a sibling column on
the same element. All Sigma formulas were checked against the function
reference, not executed live.

| # | Category | DAX | Sigma equivalent | Bucket | Notes |
|---|---|---|---|---|---|
| 1 | Simple aggregate | `Total Sales := SUM(Sales[Amount])` | `Sum([Sales/Amount])` | (a) Mechanical | Trivial. Argument prefix differs (`[Sales/Amount]` vs `Sales[Amount]`) but is mechanical given the source-element name. |
| 2 | Simple aggregate | `Order Count := COUNTROWS(Sales)` | `Count([Sales/OrderID])` *(if `OrderID` is non-null)* — otherwise `Count(*)` is not supported by Sigma's formula language at column level; use a guaranteed-non-null PK. | (a) Mechanical | Caveat: `Count([col])` skips nulls. `COUNTROWS` counts all physical rows. Pick a PK / surrogate key column. The converter must know the table's PK or warn. |
| 3 | Time intelligence | `YTD Sales := TOTALYTD(SUM(Sales[Amount]), 'Date'[Date])` | In a grouped table: outer grouping on `Year(...)`, inner grouping on `Month of Date`, with `Sum([Sales/Amount])` aggregated and a calc column `CumulativeSum(Sum([Sales/Amount]))`. | (b) Restructuring | Sigma has no scalar "year-to-date" measure. The semantic only exists inside a grouped table where `CumulativeSum` resets at the parent grouping (`sigma-computing/cumulativesum`, "split into different groupings, the cumulative sum is calculated for each year independently"). Converter must emit a "build a grouped element this way" instruction, not just a formula. |
| 4 | Time intelligence | `PY Sales := CALCULATE(SUM(Sales[Amount]), SAMEPERIODLASTYEAR('Date'[Date]))` | `DateLookback(Sum([Sales/Amount]), [Month of Date], 1, "year")` | (a) Mechanical | Direct analog. Requires the consuming element to be grouped on a date-truncated column. Same shape as `DATEADD`. |
| 5 | Time intelligence | `Sales 30d Ago := CALCULATE(SUM(Sales[Amount]), DATEADD('Date'[Date], -30, DAY))` | `DateLookback(Sum([Sales/Amount]), [Day of Date], 30, "day")` | (a) Mechanical | Same shape as #4. `DateAdd` exists in Sigma but for date arithmetic on a column, not for shifting an aggregation context — the right mapping is `DateLookback`. |
| 6 | Filter context | `Sales East := CALCULATE(SUM(Sales[Amount]), Sales[Region] = "East")` | `SumIf([Sales/Amount], [Sales/Region] = "East")` *(or)* `Sum(If([Sales/Region] = "East", [Sales/Amount], 0))` | (a) Mechanical | The single-predicate form of `CALCULATE` is exactly Sigma's `SumIf` / boolean-mask `Sum`. Multi-predicate `CALCULATE(..., a, b, c)` chains as `SumIf(amount, a And b And c)`. |
| 7 | Filter context | `% of Total := DIVIDE([Total Sales], CALCULATE([Total Sales], ALL(Sales)))` | `PercentOfTotal(Sum([Sales/Amount]), "grand_total")` | (a) Mechanical | Sigma has a first-class `PercentOfTotal` for grand-total, row, column, parent-grouping. `ALL(Sales)` ≈ `"grand_total"`; `ALLEXCEPT(Sales, Sales[Category])` ≈ `"parent_grouping"` with a parameter. Caveat: must run inside a grouped table / pivot / viz, not a flat scalar measure. |
| 8 | Relationships | `Customer City := RELATED(Customer[City])` *(calc column on Sales)* | If a `Customer ↔ Sales` relationship exists in the data model: `[Customer/City]` directly. Otherwise: `Lookup([Customer/City], [Sales/CustomerKey], [Customer/CustomerKey])`. | (a) Mechanical | `Lookup` is a clean direct map for `RELATED` / `LOOKUPVALUE`. The converter just needs to know whether the key relationship exists — if not, it emits the `Lookup` form. |
| 9 | Relationships | `Sales by Ship Date := CALCULATE([Total Sales], USERELATIONSHIP('Date'[Date], Sales[ShipDate]))` | No native equivalent. Best approximations: (i) build a second join in the data model from `Date` to `Sales[ShipDate]` (a separate relationship element), then aggregate against that; (ii) for a single hardcoded date, `Sum(If([Sales/ShipDate] = <const>, [Amount], 0))`. | (b) Restructuring (closer to (c) for the dynamic-swap semantic) | DAX's `USERELATIONSHIP` *swaps* an inactive relationship per evaluation. Sigma joins are statically defined; you can't pick a join at formula-evaluation time. Materialising a parallel "ShipDate-based" element gives the right numbers but doubles the model surface. Converter should refuse and emit a structured "needs data-model design decision" message. |
| 10 | Iterators | `Revenue := SUMX(Sales, Sales[Qty] * Sales[Price])` | `Sum([Sales/Qty] * [Sales/Price])` | (a) Mechanical | Sigma aggregates accept arbitrary row-level expressions, so `SUMX(Table, expr)` collapses to `Sum(expr)`. Same idea for `AVERAGEX` → `Avg(...)` and `MAXX` → `Max(...)`. |
| 11 | Iterators | `Product Rank := RANKX(ALL(Product), [Total Sales])` | In a table grouped by `Product` with `Sum([Sales/Amount])` aggregated, add a calc column `Rank()` (or `RankDense()`). | (b) Restructuring | DAX's `RANKX` is a measure: it can be evaluated in any visual context and ranks dynamically. Sigma's `Rank()` only works *within* a grouping in a specific element. To use it as a "measure" reusable across visuals, you must materialise a per-product aggregate element and reference it via `Lookup`. Window-style ranking (`RankOver`) silently fails inside DM-element calc columns (`sigma-data-models/reference/calc-columns.md`) — flag this in the tool's output. |

> Note: that's 11 rows because #5 (DATEADD) and #4 (SAMEPERIODLASTYEAR) are
> both worth showing — the brief asks for 10 but lists DATEADD explicitly under
> time intelligence. If we collapse them to one row the count is 10. Bucket
> totals below treat them as one.

## Bucket totals (out of 10)

| Bucket | Count | Examples |
|---|---|---|
| (a) Mechanical | **7** | SUM, COUNTROWS, SAMEPERIODLASTYEAR/DATEADD, single-predicate CALCULATE, % of total, RELATED/LOOKUPVALUE, SUMX |
| (b) Requires data-model restructuring | **3** | TOTALYTD, USERELATIONSHIP, RANKX |
| (c) No Sigma equivalent | **0** | (USERELATIONSHIP's dynamic-swap variant is on the boundary; the static-redesign workaround keeps it in (b).) |

Roughly **70% of common DAX measures translate mechanically** to Sigma formulas;
the remaining ~30% need a structural change to the consuming element or model.
Crucially, in this sample **none** of the measures has *no* Sigma path at all —
even the hardest cases (`USERELATIONSHIP`, `RANKX`) have explicit workarounds,
they just can't be expressed as a single formula string.

## Recommendation

**Yes — build `convert_dax_to_sigma_formula`, with a narrow surface and
structured "cannot translate" responses for the rest.**

Justification:

1. **70% mechanical hit rate is high enough.** A converter that handles the
   seven (a)-bucket patterns covers the majority of real Power BI dashboards,
   which lean heavily on simple aggregates, conditional CALCULATE, % of total,
   and SUMX. That's the same shape we already cover in the Tableau converter.

2. **The (b) cases benefit *more* from a tool than the (a) cases.** Hand
   translation of `TOTALYTD` or `RANKX` is where junior users are most likely
   to write a Sigma formula that "looks right" and silently produces wrong
   numbers. A tool that emits `{ ok: false, reason: "needs grouped element",
   suggested_shape: "..." }` short-circuits the wrong-by-default path.

3. **There's a real authoring pain point.** Unlike Tableau formulas (where
   `tableau-to-sigma` agents can read a TDS and hand-translate via
   `formulas.md`), DAX measures are scattered across `.pbix` files and rely on
   filter-context semantics that don't have an obvious Sigma counterpart. An
   agent without the tool will be guessing at `CALCULATE` rewrites; an agent
   with the tool can rely on a deterministic mapping.

### Minimum viable surface area (v1)

Cover these patterns mechanically and return `{ ok: true, sigma: "..." }`:

| DAX pattern | Sigma output |
|---|---|
| `SUM(T[c])`, `AVERAGE(T[c])`, `COUNT(T[c])`, `MIN/MAX(T[c])`, `DISTINCTCOUNT(T[c])` | `Sum/Avg/Count/Min/Max/CountDistinct([T/c])` |
| `COUNTROWS(T)` | `Count([T/<pk>])` — requires PK; if unknown, error |
| `SUMX(T, expr)`, `AVERAGEX(T, expr)`, `MAXX(T, expr)` | `Sum/Avg/Max(expr)` with column refs rewritten |
| `CALCULATE(agg, T[c] = v)` (single predicate) | `SumIf([T/c], pred)` / `AvgIf(...)` / `MinIf` / `MaxIf` / `CountDistinctIf([T/c], pred)` |
| `CALCULATE(COUNTROWS(T), pred)` / `CALCULATE(COUNT(T[c]), pred)` | `CountIf(pred)` — **single logical arg only**. The 2-arg `CountIf([col], pred)` form errors at query time: *Argument 1 invalid for function CountIf. Expected logical; received text.* (beads-sigma-862) |
| `CALCULATE(agg, p1, p2, ...)` (AND'd predicates) | `SumIf(col, p1 And p2 And ...)` |
| `DIVIDE(a, CALCULATE(a, ALL(T)))` | `PercentOfTotal(a, "grand_total")` |
| `DIVIDE(a, CALCULATE(a, ALLEXCEPT(T, T[d])))` | `PercentOfTotal(a, "parent_grouping", 1)` |
| `DIVIDE(<agg on T1>, <agg on T2>)` cross-table ratio | **refuse (b)**: a same-element `[A]/[B]` metric resolves the foreign aggregate as NULL. Reproduce via a constant-key (All Key=1) Lookup join to the related element so the denominator spans the FULL related set (e.g. global headcount), then divide (beads-sigma-m1a). |
| `CALCULATE(agg, SAMEPERIODLASTYEAR('Date'[Date]))` | `DateLookback(agg, [Date], 1, "year")` |
| `CALCULATE(agg, DATEADD('Date'[Date], -n, <unit>))` | `DateLookback(agg, [Date], n, <unit>)` |
| `RELATED(Other[c])`, `LOOKUPVALUE(Other[c], Other[k], T[k])` | `Lookup([Other/c], [k], [Other/k])` |
| `DATEDIFF(start, end, UNIT)` | `DateDiff("unit", start, end)` — lowercased **quoted-string unit FIRST**, then start, then end. DAX puts the unit LAST + bare; emitting `DateDiff(start, end, [UNIT])` produces a `type=error` column (beads-sigma-f0p). |
| `IF(cond, a, b)`, `SWITCH(...)`, basic arithmetic | `If(cond, a, b)` (chain `If` for `SWITCH`) |

For everything else, return a structured error:

```json
{
  "ok": false,
  "reason": "requires_grouped_element" | "requires_join_redesign" | "no_equivalent",
  "explanation": "TOTALYTD requires a grouped table with Year as the parent grouping...",
  "suggested_shape": "Group by Year > Month, aggregate Sum([T/c]), then add CumulativeSum(...)",
  "see_also": "sigma-computing/cumulativesum"
}
```

Specifically the v1 should refuse and explain rather than guess for:
`TOTALYTD`, `TOTALQTD`, `TOTALMTD`, `RANKX` (when used as a portable measure
rather than inside a single grouped table), `USERELATIONSHIP`, `EARLIER`,
`VAR`/`RETURN` blocks (split into multiple Sigma columns), `FILTER` with
non-equality predicates that include functions like `CONTAINS`/`PATHCONTAINS`.

### Cross-cutting flags the tool must surface

- `RankOver` / `SumOver` / `CountOver` silently fail inside data-model element
  calc columns and on workbook master tables sourced from a DM
  (`sigma-data-models/reference/calc-columns.md`). When the converter would
  emit one, it must add `warning: "use_in_workbook_calc_column_only"`.
- Sigma has no `CALCULATE` filter-context manipulation; filters are explicit on
  the visualization or expressed via `If` masks in the aggregate. The tool's
  docstring should state this up front so callers don't expect arbitrary
  context overrides.
- `Count([col])` excludes nulls; `COUNTROWS` does not. The converter must ask
  the caller to identify a non-null PK column (or refuse with that message).

### Alternative if we don't build the tool

A "manual translation guide" page in the (future) `powerbi-to-sigma` skill,
mirroring the worked-examples table above, plus the structured error catalogue
above as documentation. This would be lower-cost to build but pushes
filter-context-rewriting work onto every agent invocation. Given that the same
seven patterns will be hit on every Power BI conversion, the tool pays back its
implementation cost quickly.

## Conclusion

Recommend building `convert_dax_to_sigma_formula` with the v1 surface above.
Roughly 70% of measures translate mechanically; the remaining 30% are best
served by structured `{ok: false, reason, suggested_shape}` responses that
prevent silent miscompilations. The tool's value is concentrated in the hard
cases as much as the easy ones — it short-circuits the "looks right but wrong"
trap that filter-context semantics create when DAX users assume Sigma's formula
language behaves like DAX.

## 2026-09 update — calculated retail date tables

The original spike measured scalar measures and did not cover whole-table DAX.
That omission hid a distinct failure path: the calculated-table converter could
build a valid `CALENDAR` spine while emitting every complex `ADDCOLUMNS`
attribute as `NULL`. A retail model could therefore post and return dates while
Black Friday, Easter, Back-to-School, and Christmas filters returned wrong data.

Current explicit-calendar coverage:

- Literal `CALENDAR(DATE(y,m,d), DATE(y,m,d))` bounds become a queryable SQL
  date spine.
- `YEAR`/`MONTH`/`DAY`/`QUARTER` and basic date formatting stay in SQL.
- Other `ADDCOLUMNS` expressions use the calculated-column translator,
  including top-level `VAR/RETURN`, `IF`, `SWITCH(TRUE())`, boolean arithmetic,
  `DATE`, `WEEKDAY` return types 1/2/3 and 11–17, `EDATE`, `EOMONTH`, `MOD`,
  `INT`, and `FLOOR`.
- Unsupported derived columns are dropped and mark the table incomplete; they
  are never represented by a queryable-but-wrong `NULL AS` source column.
- The orchestrator blocks placeholder SQL, residual calendar `NULL AS`, and
  dropped calculated-table columns before any Sigma POST. `--yes` does not
  bypass this; an explicit
  `--allow-incomplete-calculated-tables "<reason>"` is required.

Still unsupported by design: `CALENDARAUTO()` (its bounds depend on model data),
dynamic `CALENDAR` bounds, and arbitrary `GENERATE`/`ROW`/`SELECTCOLUMNS` table
constructors. These require warehouse-aware table restructuring, not a safe
formula-only rewrite.

Regression source: `fixtures/fixture_10_retail_calendar.bim`; converter and
gate assertions: `scripts/test-retail-calendar.rb` and
`scripts/test-dax-gate.rb`.
