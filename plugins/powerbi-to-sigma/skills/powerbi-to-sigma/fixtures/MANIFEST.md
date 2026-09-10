# Power BI → Sigma Test Fixtures — Manifest / Oracle

TMSL `.bim` semantic-model fixtures for testing a Power BI → Sigma converter.
All share the real workforce model in `/tmp/pbix/model_clean.bim`:
`compatibilityLevel: 1600`, three Snowflake-backed import tables
(`EMPLOYEES`, `ABSENCE_RECORDS`, `SAFETY_INCIDENTS`) using the exact
`Snowflake.Databases("gxb98765.snowflakecomputing.com","SIGMA_WH")` →
`DEMO_DB` db → `DEMO` schema → table M source pattern. Fixtures 02/05/06 add a
`DimDate` calculated date table (and 05 a `DeptSummary` calculated table).

Buckets reference `research/dax-to-sigma-coverage.md`:
**(a)** mechanical syntax rewrite · **(b)** needs data-model / element
restructuring · **(c)** no Sigma equivalent.

Sigma formula convention: `[Table/Column]` = column on an element sourced from
that warehouse table; `Lookup(...)` for cross-element refs when no relationship
exists. Time-intelligence / ranking translations assume a **grouped element**
(grouping table or pivot), not a scalar measure — that grouping requirement is
itself the (b) restructuring.

---

## fixture_01_mechanical.bim — bucket (a)

| Name | Kind | DAX | Expected Sigma | Bucket | Notes / Gotchas |
|---|---|---|---|---|---|
| Total Salary | measure | `SUM(EMPLOYEES[ANNUAL_SALARY])` | `Sum([Employees/Annual Salary])` | a | Coverage row 1. |
| Avg Salary | measure | `AVERAGE(EMPLOYEES[ANNUAL_SALARY])` | `Avg([Employees/Annual Salary])` | a | |
| Headcount | measure | `COUNTROWS(EMPLOYEES)` | `Count([Employees/Employee Id])` | a | Coverage row 2 caveat: `Count` skips nulls; EMPLOYEE_ID is the PK so OK. `COUNTROWS` counts physical rows. |
| Distinct Departments | measure | `DISTINCTCOUNT(EMPLOYEES[DEPARTMENT])` | `CountDistinct([Employees/Department])` | a | |
| Active Headcount | measure | `CALCULATE(COUNTROWS(EMPLOYEES), EMPLOYEES[STATUS]="Active")` | `CountIf([Employees/Status]="Active")` | a | Single-predicate CALCULATE (coverage row 6). **Sigma `CountIf` takes ONE logical arg** — the 2-arg `CountIf([col],[cond])` form errors at query time (beads-sigma-862). |
| Total Comp Estimate | measure | `SUMX(EMPLOYEES, EMPLOYEES[ANNUAL_SALARY]*1.25)` | `Sum([Employees/Annual Salary]*1.25)` | a | SUMX collapses (coverage row 10). |
| Avg Years To Today | measure | `AVERAGEX(EMPLOYEES, DATEDIFF(EMPLOYEES[HIRE_DATE], TODAY(), YEAR))` | `Avg(DateDiff("year", [Employees/Hire Date], Today()))` | a | AVERAGEX + DATEDIFF + TODAY. **NEW**: `DATEDIFF`/`TODAY` not in coverage doc. |
| Pct Active | measure | `DIVIDE([Active Headcount], [Headcount])` | `[Active Headcount] / [Headcount]` (or `Divide(...)`) | a | Measure-on-measure ref. |
| Status Label | measure | `SWITCH(TRUE(), [Pct Active]>=0.9,"Healthy", [Pct Active]>=0.7,"Watch","At Risk")` | nested `If([Pct Active]>=0.9,"Healthy", If([Pct Active]>=0.7,"Watch","At Risk"))` | a | `SWITCH(TRUE(), ...)` → chained `If` (coverage MVP row). |
| Full Name | calc col | `EMPLOYEES[FIRST_NAME] & " " & EMPLOYEES[LAST_NAME]` | `Concat([First Name], " ", [Last Name])` or `[First Name] & " " & [Last Name]` | a | `&` string concat. **NEW**: concat operator not explicitly in coverage doc. |
| Salary Band | calc col | nested `IF` on ANNUAL_SALARY | nested `If(...)` | a | |
| Employee Department | calc col (ABSENCE) | `RELATED(EMPLOYEES[DEPARTMENT])` | `[Employees/Department]` if relationship exists, else `Lookup(...)` | a | Coverage row 8. Relationship exists → direct ref. |
| Manager Lookup | calc col (ABSENCE) | `LOOKUPVALUE(EMPLOYEES[ROLE], EMPLOYEES[EMPLOYEE_ID], ABSENCE_RECORDS[EMPLOYEE_ID])` | `Lookup([Employees/Role], [Employee Id], [Employees/Employee Id])` | a | Coverage row 8 LOOKUPVALUE form. |
| Total Absence Hours / Absence Records / Approved Absence Hours / Avg Absence Hours | measures (ABSENCE) | SUM / COUNTROWS / CALCULATE(...APPROVED=TRUE()) / AVERAGE | `Sum`, `Count([Absence Id])`, `SumIf([Hours], [Approved])`, `Avg([Hours])` | a | Approved is boolean → bare truthy predicate. |
| Incident Count / Max Severity Rows | measures (INCIDENT) | DISTINCTCOUNT / `MAXX(..., IF(SEVERITY="High",1,0))` | `CountDistinct([Incident Id])` / `Max(If([Severity]="High",1,0))` | a | MAXX with row IF body collapses. |

## fixture_02_time_intelligence.bim — buckets (a)/(b)

| Name | Kind | DAX | Expected Sigma | Bucket | Notes / Gotchas |
|---|---|---|---|---|---|
| Total Absence Hours | measure | `SUM(ABSENCE_RECORDS[HOURS])` | `Sum([Absence Records/Hours])` | a | baseline |
| YTD Absence Hours | measure | `TOTALYTD(SUM(...HOURS), DimDate[Date])` | grouped element: group Year > Month, aggregate `Sum([Hours])`, calc col `CumulativeSum(Sum([Hours]))` resetting per Year | **b** | Coverage row 3. No scalar YTD; needs grouped table. |
| MTD Absence Hours | measure | `TOTALMTD(SUM(...HOURS), DimDate[Date])` | grouped Month > Day, `CumulativeSum` resets per Month | **b** | Same shape as YTD, finer grain. |
| PY Absence Hours | measure | `CALCULATE(SUM(...HOURS), SAMEPERIODLASTYEAR(DimDate[Date]))` | `DateLookback(Sum([Hours]), [Month of Date], 1, "year")` | a | Coverage row 4. Needs date-truncated grouping column. |
| Absence Hours 30d Ago | measure | `CALCULATE(SUM(...HOURS), DATEADD(DimDate[Date], -30, DAY))` | `DateLookback(Sum([Hours]), [Day of Date], 30, "day")` | a | Coverage row 5. |
| YoY Absence Hours Pct | measure | `DIVIDE([Total]-[PY], [PY])` | `([Total Absence Hours]-[PY Absence Hours]) / [PY Absence Hours]` | a | Inherits PY's (b) grouping requirement transitively. |
| Incident Count | measure | DISTINCTCOUNT | `CountDistinct([Incident Id])` | a | |
| PY Incident Count | measure | `CALCULATE(DISTINCTCOUNT, SAMEPERIODLASTYEAR(...))` | `DateLookback(CountDistinct([Incident Id]), [Month of Date], 1, "year")` | a | |
| YTD Incident Count | measure | `TOTALYTD(DISTINCTCOUNT, DimDate[Date])` | grouped + `CumulativeSum` of distinct count | **b** | DistinctCount inside cumulative is fine in a grouped table. |
| Incident MoM Delta | measure | `DISTINCTCOUNT - CALCULATE(DISTINCTCOUNT, DATEADD(...,-1,MONTH))` | `CountDistinct([Incident Id]) - DateLookback(CountDistinct([Incident Id]), [Month of Date], 1, "month")` | a | |

## fixture_03_filter_context.bim — buckets (a)/(b)

| Name | Kind | DAX | Expected Sigma | Bucket | Notes / Gotchas |
|---|---|---|---|---|---|
| Total Salary / Avg Salary | measures | SUM / AVERAGE | `Sum`/`Avg` | a | |
| Salary Pct of Total | measure | `DIVIDE([Total Salary], CALCULATE([Total Salary], ALL(EMPLOYEES)))` | `PercentOfTotal(Sum([Annual Salary]), "grand_total")` | a | Coverage row 7. Must run in a grouped table/viz. |
| Salary Pct of Dept | measure | `DIVIDE([Total Salary], CALCULATE([Total Salary], ALLEXCEPT(EMPLOYEES, EMPLOYEES[DEPARTMENT])))` | `PercentOfTotal(Sum([Annual Salary]), "parent_grouping", 1)` | a→b | Coverage row 7. Requires the consuming table be grouped by Department as the parent grouping — borderline (b). |
| Company Avg Salary | measure | `CALCULATE(AVERAGE(...), ALL(EMPLOYEES))` | grand-total average; in a grouped table use `Avg` at grand-total scope or a windowless reference | **b** | `ALL()` to strip all filter context has no scalar Sigma form; needs ungrouped/grand-total element. |
| Avg Salary vs Dept | measure | `[Avg Salary] - CALCULATE(AVERAGE(...), ALLEXCEPT(...,DEPARTMENT))` | `Avg([Annual Salary]) - <dept-level avg via parent grouping>` | b | Compares row avg to dept avg — needs grouping context. |
| High Earner Count | measure | `CALCULATE(COUNTROWS, FILTER(EMPLOYEES, ANNUAL_SALARY>100000))` | `CountIf([Annual Salary]>100000)` | a | FILTER with non-equality constant predicate → single-arg `CountIf` mask (beads-sigma-862; 2-arg form errors). |
| Above Avg Earner Count | measure | `CALCULATE(COUNTROWS, FILTER(EMPLOYEES, ANNUAL_SALARY > [Company Avg Salary]))` | row value vs an aggregate → needs windowed compare (`[Annual Salary] > <grand-total avg>`) | **b** | FILTER predicate references a measure (aggregate) → can't be a simple row mask; coverage doc flags FILTER-with-aggregate as refuse/restructure. |
| Active FullTime Salary | measure | `CALCULATE(SUM, STATUS="Active", EMPLOYMENT_TYPE="Full-Time")` | `SumIf([Annual Salary], [Status]="Active" And [Employment Type]="Full-Time")` | a | Multi-predicate CALCULATE → `And` (coverage row 6). |
| Total Absence Hours | measure | SUM | `Sum` | a | |
| Absence Hours Pct of Total | measure | `DIVIDE(SUM, CALCULATE(SUM, ALL(ABSENCE_RECORDS)))` | `PercentOfTotal(Sum([Hours]), "grand_total")` | a | |
| Sick Hours | measure | `CALCULATE(SUM, ABSENCE_TYPE="Sick")` | `SumIf([Hours], [Absence Type]="Sick")` | a | |
| Long Absence Hours | measure | `CALCULATE(SUM, FILTER(..., HOURS>=8))` | `SumIf([Hours], [Hours]>=8)` | a | non-equality FILTER on a constant. |
| Incident Count | measure | DISTINCTCOUNT | `CountDistinct` | a | |
| Incident Pct of Total | measure | `DIVIDE([Incident Count], CALCULATE([Incident Count], ALL(SAFETY_INCIDENTS)))` | `PercentOfTotal(CountDistinct([Incident Id]), "grand_total")` | a | |
| Incident Pct of Dept | measure | `DIVIDE(..., CALCULATE(..., ALLEXCEPT(...,DEPARTMENT)))` | `PercentOfTotal(CountDistinct([Incident Id]), "parent_grouping", 1)` | a→b | grouped-by-Department required. |
| High Severity Incidents | measure | `CALCULATE([Incident Count], FILTER(..., SEVERITY<>"Low"))` | `CountDistinctIf([Incident Id], [Severity]<>"Low")` or `CountDistinct(If([Severity]<>"Low",[Incident Id],null))` | a | `<>` inequality predicate. |

## fixture_04_iterators_rank_var.bim — buckets (b), VAR/RETURN, nested iterators

| Name | Kind | DAX | Expected Sigma | Bucket | Notes / Gotchas |
|---|---|---|---|---|---|
| Total Salary | measure | SUM | `Sum` | a | |
| Dept Salary Rank | measure | `RANKX(ALL(EMPLOYEES[DEPARTMENT]), [Total Salary], , DESC, DENSE)` | table grouped by Department with `Sum([Annual Salary])`, add calc col `RankDense()` ordered desc | **b** | Coverage row 11. Portable-measure RANKX → materialise per-dept aggregate element + `Lookup` to reuse. **Gotcha**: `RankOver` silently fails in DM-element calc cols — use a workbook calc column. |
| Salary Variance From Mean | measure | `VAR CompanyMean=CALCULATE(AVG,ALL(...)) VAR DeptMean=AVG RETURN DeptMean-CompanyMean` | split into two columns (grand-total avg, group avg) then subtract; `Avg([Annual Salary]) - <grand-total avg>` | **b** | VAR/RETURN → multiple Sigma columns (coverage MVP: refuse/split). `ALL()` grand-total needs structural support. |
| Weighted Salary Score | measure | `SUMX(EMPLOYEES, ANNUAL_SALARY * RANKX(ALL(EMPLOYEES[EMPLOYEE_ID]), ANNUAL_SALARY, , DESC))` | nested iterator: per-row rank then weighted sum — needs a rank calc column on a per-employee element, then `Sum([Annual Salary]*[Salary Rank])` | **b** | Nested iterator (SUMX over RANKX). No single-formula path; two-step. |
| Total Absence Hours | measure | SUM | `Sum` | a | |
| Dept Absence Rank | measure | `RANKX(ALL(ABSENCE_RECORDS[DEPARTMENT]), [Total Absence Hours], , DESC, DENSE)` | grouped-by-Dept + `RankDense()` | b | as Dept Salary Rank. |
| Absence Hours Above Dept Avg | measure | `VAR DeptAvg=AVERAGEX(VALUES(EMPLOYEE_ID), CALCULATE(SUM)) VAR ThisTotal=SUM RETURN ThisTotal-DeptAvg` | per-employee aggregate element, then group avg; `Sum([Hours]) - <per-employee avg>` | **b** | AVERAGEX over VALUES = average of per-employee sums → needs a pre-aggregated element. |
| Incident Count | measure | DISTINCTCOUNT | `CountDistinct` | a | |
| Dept Incident Rank | measure | `RANKX(ALL(SAFETY_INCIDENTS[DEPARTMENT]), [Incident Count], , DESC, DENSE)` | grouped-by-Dept + `RankDense()` | b | |
| Severity Weighted Score | measure | `SUMX(SAFETY_INCIDENTS, SWITCH(SEVERITY,"High",3,...))` | `Sum(If([Severity]="High",3, If([Severity]="Medium",2, If([Severity]="Low",1,0))))` | a | SUMX over SWITCH body collapses to `Sum(chained If)`. |

## fixture_05_relationships_hard.bim — buckets (b)/(c), inactive relationships, calc tables

| Name | Kind | DAX | Expected Sigma | Bucket | Notes / Gotchas |
|---|---|---|---|---|---|
| Tenure Days | calc col | `DATEDIFF(HIRE_DATE, IF(ISBLANK(TERMINATION_DATE), TODAY(), TERMINATION_DATE), DAY)` | `DateDiff("day", [Hire Date], If(IsNull([Termination Date]), Today(), [Termination Date]))` | a | `ISBLANK`→`IsNull`. **NEW**: ISBLANK/DATEDIFF/TODAY not in coverage doc. |
| Manager Name | calc col | two `LOOKUPVALUE`s self-join on MANAGER_ID→EMPLOYEE_ID | self-join element (Employees→Employees on Manager Id) then `[Mgr/First Name] & " " & [Mgr/Last Name]`, or `Lookup` against a manager element | **b** | Self-referencing lookup → needs a second (aliased) Employees element/join. |
| Absence Hours On Record | calc col | `SUMX(RELATEDTABLE(ABSENCE_RECORDS), HOURS)` | `Sum([Absence Records/Hours])` via the relationship (a rollup/lookup-agg column on the Employees element) | **b** | `RELATEDTABLE` rollup → Sigma rollup aggregate over the related element; relationship must exist. **Gotcha**: rollup over an external relation has Sigma-side limits. |
| Employee Tenure At Absence | calc col (ABSENCE) | `DATEDIFF(RELATED(EMPLOYEES[HIRE_DATE]), ABSENCE_RECORDS[DATE], DAY)` | `DateDiff("day", [Employees/Hire Date], [Date])` | a | RELATED inside DATEDIFF; relationship exists → direct ref. |
| Incident Department | calc col (INCIDENT) | `RELATED(EMPLOYEES[DEPARTMENT])` | `[Employees/Department]` | a | |
| Headcount | measure | COUNTROWS | `Count([Employee Id])` | a | |
| Hires In Period | measure | `CALCULATE(COUNTROWS, USERELATIONSHIP(HIRE_DATE, DimDate[Date]))` | activate the HIRE_DATE→DimDate join (active here) and group by date; no formula-time relationship swap in Sigma | **b** | Coverage row 9. HIRE_DATE rel is active in this fixture; the measure forces it. |
| Terminations In Period | measure | `CALCULATE(COUNTROWS, USERELATIONSHIP(TERMINATION_DATE, DimDate[Date]))` | **inactive** TERMINATION_DATE→DimDate rel must be materialised as a separate join/element; aggregate against that | **b (→c boundary)** | Coverage row 9. The hardest case: Sigma can't swap an inactive join at evaluation time — build a parallel TerminationDate-based element. Converter should emit "needs data-model design decision". |
| Net Headcount Change | measure | `[Hires In Period] - [Terminations In Period]` | difference of the two restructured measures | b | inherits both relationship restructurings. |
| Avg Tenure Days | measure | `AVERAGE(EMPLOYEES[Tenure Days])` | `Avg([Tenure Days])` | a | aggregates the calc column. |
| (DimDate) | calc table | `ADDCOLUMNS(CALENDAR(...), "Year", YEAR(...), ...)` | Sigma date dimension / generated calendar element or warehouse date table | b | Calculated table → no warehouse source; build a date element or join a real DATE_DIM. |
| (DeptSummary) | calc table | `SUMMARIZE(EMPLOYEES, DEPARTMENT, "Dept Headcount", COUNTROWS, "Dept Avg Salary", AVERAGE)` | a grouping/aggregate **element** sourced from the Employees element, grouped by Department | **b** | Calculated table = materialised aggregate. Maps to a grouped DM element, not a formula. |

## fixture_06_kitchen_sink.bim — mixed (a)/(b), dense realistic model

Combines: simple aggregates, single/multi-predicate CALCULATE, % of total &
parent-grouping, SUMX, SWITCH calc col, DATEDIFF/ISBLANK/TODAY tenure col,
RELATEDTABLE rollup col, TOTALYTD & SAMEPERIODLASTYEAR time-intel, RANKX,
USERELATIONSHIP on inactive HIRE_DATE rel, and two VAR/RETURN measures
(`Retention Rate`, `Incident Risk Index`). See per-pattern rows above; the
same Sigma translations and buckets apply. Notable:

| Name | DAX | Expected Sigma | Bucket | Notes |
|---|---|---|---|---|
| Retention Rate | `VAR Started=[Headcount] VAR StillActive=[Active Headcount] RETURN DIVIDE(StillActive, Started)` | `[Active Headcount] / [Headcount]` | a | trivial VAR/RETURN that inlines (unlike fixture_04's, which need ALL/restructuring). |
| Incident Risk Index | `VAR Total=DISTINCTCOUNT VAR Weighted=SUMX(..., [Severity Score]) RETURN DIVIDE(Weighted, Total)` | `Sum([Severity Score]) / CountDistinct([Incident Id])` | a | SUMX over a calc col + distinct count; inlines to two aggregates. |
| Absence Hours Per Head | `DIVIDE([Total Absence Hours], [Headcount])` | **refuse**: structured warning — reproduce via constant-key (All Key=1) Lookup join to EMPLOYEES, then `Sum([Hours]) / CountDistinct([ABSENCE_RECORDS/Absence -> All Employees/Employee Id])` (denominator = GLOBAL headcount) | **b** | cross-table measure ratio (Absence vs Employees). `[Headcount]` lives on EMPLOYEES → a same-element `[A]/[B]` metric resolves NULL. Converter now drops it + warns rather than ship a null metric (beads-sigma-m1a). |

---

## fixture_10_retail_calendar.bim — retail event date dimension

An explicit 2024–2026 `ADDCOLUMNS(CALENDAR(...))` date dimension with the
customer-reported retail events. The table constructor remains bucket **(b)**
because Sigma must synthesize a queryable date-spine SQL element; once that
spine exists, each derived event expression below is a mechanical **(a)**
calculated-column translation.

| Name | DAX shape | Expected Sigma | Bucket | Notes |
|---|---|---|---|---|
| Year | `YEAR([Date])` | SQL date-spine column `EXTRACT(YEAR FROM d)` | a | Keep simple date parts in the generated SQL. |
| WeekdayMon | `WEEKDAY([Date], 2)` | `Mod(Weekday([Date]) + 5, 7) + 1` | a | DAX return type 2 is Monday=1; Sigma `Weekday` is Sunday=1. |
| MonthEnd | `EOMONTH([Date], 0)` | `EndOfMonth(DateAdd("month", 0, [Date]))` | a | Preserve the month-offset argument. |
| NextMonth | `EDATE([Date], 1)` | `DateAdd("month", 1, [Date])` | a | |
| IsBlackFriday | `VAR WeekdayNumber=WEEKDAY(...,2) RETURN MONTH=11 && WeekdayNumber=5 && DAY BETWEEN 23 AND 29` | inlined `If`-free boolean formula using `Month`, Monday-based `Weekday`, and `Day` | a | Friday between Nov 23–29 is Black Friday for every Gregorian year. |
| IsEaster | Gregorian computus in `VAR`/`RETURN`, `MOD`, `INT`, `DATE` | inlined `Mod`/`Int` arithmetic ending in `[Date] = MakeDate(...)` | a | Exercises a movable holiday without a hard-coded lookup table. |
| IsBackToSchool | August or Sep 1–15 predicate | `Month([Date]) = 8 Or (Month([Date]) = 9 And Day([Date]) <= 15)` | a | Representative configurable retail window. |
| IsChristmas | `[Date] = DATE(YEAR([Date]),12,25)` | `[Date] = MakeDate(Year([Date]), 12, 25)` | a | Fixed-date event. |
| RetailEvent | `SWITCH(TRUE(), Black Friday predicate, ..., "Regular")` | nested `If(...)` label formula | a | Exercises event labeling in the calculated-table path. |

Regression contract: the converted `DimRetailDate` element must contain all ten
columns, its SQL must contain neither `_placeholder` nor `NULL AS`, and its
warnings must not report dropped calculated-table columns.

---

## Patterns NOT covered by `dax-to-sigma-coverage.md` (gaps worth a spike)

The coverage doc analysed 10 representative measures. These fixture patterns go
beyond it and should be added as new worked rows / spike cases:

1. **`DATEDIFF(a, b, unit)` + `TODAY()`** (fixtures 01, 05, 06) — date arithmetic
   producing a number, distinct from `DateAdd`/`DateLookback`. Maps to Sigma
   `DateDiff("unit", a, b)` / `Today()`. Mechanical (a), but unanalysed.
2. **`ISBLANK` → `IsNull`** (fixtures 05, 06) — null handling inside `If`. (a),
   unanalysed.
3. **String concat `&`** (fixtures 01, 05, 06) — `&` → Sigma `&` or `Concat`. (a),
   unanalysed.
4. **`SWITCH` with a value (not `SWITCH(TRUE(), ...)`)** (fixtures 04, 06
   Severity Score) — value-form switch → chained `If`. Coverage doc mentions
   SWITCH only via the `TRUE()` form.
5. **`RELATEDTABLE` + `SUMX` rollup calc column** (fixtures 05, 06) — a
   row-context rollup over the many-side, distinct from scalar `RELATED`. Needs a
   Sigma rollup/lookup-aggregate; (b). Not in coverage doc.
6. **`SUMMARIZE` / `ADDCOLUMNS+CALENDAR` calculated tables** (fixtures 02, 05,
   06) — whole-table DAX with no warehouse source. The coverage doc only covered
   measures and calc columns, never calculated tables. (b)/(c) — a real gap.
7. **`VALUES(...)` inside `AVERAGEX`** (fixture 04 Absence Hours Above Dept Avg)
   — iterating distinct values of a column = per-key pre-aggregation. (b), not in
   coverage doc.
8. **Nested iterators (`SUMX` over `RANKX`)** (fixture 04 Weighted Salary Score)
   — coverage doc covers SUMX and RANKX separately but not composed; the
   composition forces a two-element pipeline. (b).
9. **Cross-table measure ratios** (fixture 06 Absence Hours Per Head) —
   dividing an Absence aggregate by an Employees aggregate requires a common
   grouping grain; not addressed. (b).
10. **`USERELATIONSHIP` on a self-referencing relationship** is implied but the
    coverage doc's row 9 only covered the date-table case; the manager self-join
    (`Manager Name`) is a distinct sub-case.

## Self-test

`python3 validate.py` → all 6 fixtures PASS;
**81 measures + 13 calculated columns = 94 DAX expressions** total.
