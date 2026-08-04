# Beast Mode → Sigma formula mapping

Beast Mode is **MySQL-dialect SQL**. The primary translation path is the vendored
`converter/sql.mjs` (`scripts/convert-beast-modes.rb --convert`, running locally
via `node` — no MCP call, no network; see Track E,
`docs/superpowers/specs/2026-08-03-domo-sql-formula-vendoring-design.md`). This
doc is the **pre-processing + verification layer**: normalizations to apply
first, the function-by-function map to sanity-check the converter's output, and
the gotchas that the generic SQL converter won't know are Domo-specific.

Source of truth: Domo "Beast Mode Functions Reference Guide" (captured 2026-06-02).

---

## Translation is delegated — this ref is the Domo-specific wrapper

The actual SQL→Sigma translation runs through the vendored `converter/sql.mjs`
(`lookSqlToSigmaRules`/`lookConvertExpression`, re-vendored periodically from
`sigma-data-model-mcp`'s `src/formulas.ts` — same functions the
`convert_sql_to_sigma_formula` MCP tool itself calls) — it is the **single
source of truth** and already handles `CASE WHEN`, `IN` lists, `DATEDIFF`,
arithmetic, and `snake_case` → `[Title Case]` column references. Don't
re-implement those. This ref is the **Domo-specific PRE-normalization +
POST-lint** layer that `scripts/convert-beast-modes.rb` implements around that
call.

⚠️ The **`CEILING`/`FLOOR`-are-aggregates** trap (below) must be applied as a
**POST override** — the generic converter treats `CEILING`/`FLOOR` as math
rounding, so you have to rewrite its output to `Round(Max(...))` / `Round(Min(...))`
after the fact.

---

## Projection vs aggregate (query structure)

"**Projection**" is a Domo **query-structure** term, not a function class — it's
where a non-aggregated, row-level expression lands in the query. Classify each
Beast Mode by *where it lives*, which decides where it goes in Sigma:

| Domo query structure | What it is | Sigma target |
|---|---|---|
| **Projection** (row-level, non-aggregated) | lands in the query's `projection` list | a Sigma **data-model calc column** |
| **Aggregate** (top-level `SUM`/`COUNT`/`AVG`/…) | wraps the whole expression | a Sigma **workbook / element aggregate** |
| **Window / analytic** (`… OVER (…)`) | ranks / running totals | Sigma window function — place deliberately, see below |
| **FIXED / LOD** (`FIXED (BY …)`) | level-of-detail | Sigma level-of-detail — do NOT flatten |

The discovery step classifies each Beast Mode via the standalone Beast Mode
template's API flags — **no SQL parsing** (see `refs/connection.md`):
- `analytic: true` → window/analytic
- `aggregated: true` → aggregate
- neither → projection (row-level calc column)
- expression contains `FIXED(…)` → LOD

### Window / analytic Beast Modes
Domo window functions — `RANK() OVER`, `SUM() OVER (PARTITION BY …)`, running
totals — are **OFF by default in Beast Mode (CSM / support-gated)**. That's a
real reason "projection window" Beast Modes often don't carry over, and why you
may see them referenced but erroring in the source. Map them to Sigma
`Rank` / `SumOver` / `CountOver` — **but** those **silently error in
workbook-master and DM calc columns** (see `feedback_sigma_window_functions`).
Place them deliberately (in a context where the `*Over` family works) and
**warn** — never silently drop them.

---

## Normalize BEFORE translating

Apply these to the raw Beast Mode string first:

1. **Strip backtick / bracket identifier quoting** → Sigma uses `[Column Name]`.
   `` `Sales` `` and `` `Operating Budget` `` → `[Sales]`, `[Operating Budget]`.
2. **`WEEKDAY` day-numbering mismatch.** Do NOT rewrite the SQL — `WEEKDAY(...)`
   converts cleanly on its own to Sigma's `Weekday(...)` by name. But MySQL
   `WEEKDAY()` (0=Monday..6=Sunday) and Sigma `Weekday()` (1=Sunday..7=Saturday)
   use genuinely different numbering, so a name-clean translation can still be
   a silent VALUE mismatch. Flag with a warning naming the override:
   `Mod(Weekday([col])+5,7)` reproduces MySQL's exact numbering from Sigma's
   `Weekday()` output.
3. **Reject / flag unsupported functions** (no longer supported in Beast Mode, so
   they shouldn't appear, but guard anyway): `SQRT`, `CONVERT_TZ`, `MICROSECOND`.
   If present, warn — likely a legacy formula. (`WEEKDAY` is excluded from this
   generic loop — it gets its own targeted day-numbering warning above instead,
   since it DOES have a real Sigma equivalent and isn't actually unsupported.)
4. **Flag the aggregate `CEILING` / `FLOOR` trap** — see below. These are NOT math
   rounding in Beast Mode.
5. **Decide row vs aggregate context.** If a top-level aggregate (`SUM`, `AVG`,
   `COUNT`, …) wraps the expression, the result is a workbook/element aggregate;
   otherwise it's a row-level DM calc column. Domo decides this implicitly by the
   card's grouping — we must make it explicit.

---

## ⚠️ Top gotchas (Domo-specific, the SQL converter won't catch these)

| Beast Mode | Looks like | Actually is | Sigma |
|---|---|---|---|
| `CEILING(Budget)` | math ceiling | **aggregate**: rounded `MAX` | `Round(Max([Budget]))` |
| `FLOOR(Budget)` | math floor | **aggregate**: rounded `MIN` | `Round(Min([Budget]))` |
| `POWER(Values,2)` | per-row power | per-row power, but **sums per series** if multi-series | `Power([Values],2)` (handle series via grouping) |
| `WEEKDAY(d)` | MySQL WEEKDAY (0=Mon..6=Sun) | converts by NAME to `Weekday([d])`, but Sigma's numbering is DIFFERENT (1=Sun..7=Sat) — a silent VALUE mismatch, not just an off-by-one | `Weekday([d])`; override to `Mod(Weekday([d])+5,7)` to preserve MySQL's exact day numbers |
| `SQRT(x)` | square root | **unsupported** in Beast Mode | use `Power([x], 0.5)` if it appears |
| Summary Number Beast Mode | a column | must be aggregated to be a summary | maps to a Sigma **KPI** element — see `refs/card-to-element.md` Rule 0 (KPI, never a table) |
| `SUM(SUM([x]) FIXED (BY [Region]))` | a nested aggregate | **level-of-detail** (LOD) | Sigma **level-of-detail** — do NOT flatten to a plain aggregate; flag for review (see `lod_conditional_inner`) |

---

## Aggregate functions

| Beast Mode | Sigma | Notes |
|---|---|---|
| `SUM(x)` | `Sum([x])` | |
| `SUM(DISTINCT x)` | `Sum(Distinct ...)` | no direct Sigma form — pre-distinct then sum, or warn |
| `AVG(x)` | `Avg([x])` | |
| `COUNT(x)` | `Count([x])` | |
| `COUNT(DISTINCT x)` | `CountDistinct([x])` | |
| `APPROXIMATE_COUNT_DISTINCT(x)` | `CountDistinct([x])` | Sigma has no approx-distinct; exact is fine for parity |
| `MIN(x)` | `Min([x])` | unrounded |
| `MAX(x)` | `Max([x])` | unrounded |
| `CEILING(x)` | `Round(Max([x]))` | **aggregate = rounded MAX** |
| `FLOOR(x)` | `Round(Min([x]))` | **aggregate = rounded MIN** |
| `STDDEV_POP(x)` | `StdDevPop([x])` | |
| `VAR_POP(x)` | `VarPop([x])` | |
| `HLL_SKETCH_INIT/EXTRACT/MERGE/MERGE_PARTIAL` | `CountDistinct([x])` (collapse) | HLL++ approx-distinct sketches; Sigma has no sketch type — collapse the whole sketch pipeline to an exact distinct count, warn |

---

## Mathematical functions

| Beast Mode | Sigma |
|---|---|
| `ABS(x)` | `Abs([x])` |
| `MOD(x, n)` | `[x] % n` or `Mod([x], n)` |
| `POWER(x, n)` | `Power([x], n)` |
| `RAND()` | `Random()` |
| `ROUND(x)` / `ROUND(x, d)` | `Round([x])` / `Round([x], d)` |

(`SQRT` removed from Beast Mode — if seen, `Power([x], 0.5)`.)

---

## Logical functions

| Beast Mode | Sigma |
|---|---|
| `CASE WHEN c THEN a ELSE b END` | `If(c, a, b)` |
| `CASE WHEN c1 THEN 1 WHEN c2 THEN 2 END` | **native multi-pair** `If(c1, 1, c2, 2, null)` — no nesting needed |
| `CASE col WHEN x THEN a WHEN y THEN b END` | `If([col]=x, a, [col]=y, b, null)` |
| `col IN (v1, v2, ...)` | **`[col]=v1 or [col]=v2 ...`** — Sigma has **no `IsIn`** (see `feedback_sigma_formula_isin`) |
| `col LIKE '%TX%'` | `Contains([col], "TX")` |
| `col LIKE 'TX%'` | `StartsWith([col], "TX")` |
| `col LIKE '%TX'` | `EndsWith([col], "TX")` |
| `col LIKE '_hn%'` | regex: `RegexpMatch([col], "^.hn.*")` (`_`→`.`, `%`→`.*`) |
| `IFNULL(x, d)` | `Coalesce([x], d)` |
| `NULLIF(a, b)` | `If([a]=[b], null, [a])` |

### Multi-condition `If` — the "IF with multiple conditions chokes" fix
Sigma's `If` is **natively multi-pair**: `If(c1, v1, c2, v2, …, else)`. You do
**NOT** nest `If`s for a multi-branch `CASE`. Two rules that cause the "chokes"
failure when broken:
- **All value branches must return the SAME type.** Mixed types (e.g. a number in
  one branch, a string in another) **throw**. Cast so every branch matches.
- **`and` / `or` / `not` must be INFIX operators**, e.g. `[a] > 1 and [b] < 2`.
  The function-call forms `And(…)` / `Or(…)` / `Not(…)` **silently null the row**
  — they don't error, the result just goes blank.

---

## String functions

| Beast Mode | Sigma |
|---|---|
| `CONCAT(a, ' ', b)` | `[a] & " " & [b]` |
| `INSTR(col, 's')` | `Find([col], "s")` (1-based, mind index base) |
| `LEFT(col, n)` | `Left([col], n)` |
| `RIGHT(col, n)` | `Right([col], n)` |
| `LENGTH(col)` | `Length([col])` |
| `LOWER(col)` | `Lower([col])` |
| `UPPER(col)` | `Upper([col])` |
| `REPLACE(col, 'a', 'b')` | `Replace([col], "a", "b")` |
| `SUBSTRING(col, pos, len)` | `Mid([col], pos, len)` (1-based pos in both) |
| `TRIM(col)` | `Trim([col])` |

---

## Date and time functions

Beast Mode date functions are MySQL-flavored. Sigma date functions take a **unit
string** (`"day"`, `"month"`, `"year"`, …) and use **format tokens** (`YYYY`,
`MM`, `DD`) rather than MySQL `%` specifiers — see the specifier table below.

| Beast Mode | Sigma |
|---|---|
| `NOW()` / `CURRENT_TIMESTAMP()` / `SYSDATE()` | `Now()` |
| `CURDATE()` / `CURRENT_DATE()` | `Today()` |
| `CURTIME()` / `CURRENT_TIME()` | `Now()` (time-of-day; Sigma has no pure time type) |
| `DATE(d)` | `DateTrunc("day", [d])` |
| `TIME(d)` | extract via format; no pure time type |
| `YEAR(d)` | `Year([d])` |
| `MONTH(d)` | `Month([d])` |
| `MONTHNAME(d)` | `DateFormat([d], "MMMM")` |
| `DAY(d)` / `DAYOFMONTH(d)` | `Day([d])` |
| `DAYNAME(d)` | `DateFormat([d], "dddd")` |
| `DAYOFWEEK(d)` | `Weekday([d])` (1=Sunday) |
| `DAYOFYEAR(d)` | `DateDiff("day", DateTrunc("year",[d]), [d]) + 1` |
| `HOUR(d)` / `MINUTE(d)` / `SECOND(d)` | `Hour([d])` / `Minute([d])` / `Second([d])` |
| `QUARTER(d)` | `Quarter([d])` |
| `WEEK(d, mode)` | `Week([d])` — Sigma week start is config; mode 11=Sun, 22=Mon, map accordingly |
| `YEARWEEK(d, mode)` | `Year([d]) & DateFormat([d],"WW")` (compose) |
| `DATE_ADD(d, interval n unit)` / `ADDDATE` | `DateAdd("unit", n, [d])` |
| `DATE_SUB(d, interval n unit)` / `SUBDATE` | `DateAdd("unit", -n, [d])` |
| `ADDTIME(t, secs)` | `DateAdd("second", secs, [t])` |
| `SUBTIME(t, secs)` | `DateAdd("second", -secs, [t])` |
| `DATEDIFF(a, b)` | `DateDiff("day", [b], [a])` (mind arg order: BM is `(end, start)`) |
| `TIMEDIFF(a, b)` | `DateDiff("second", [b], [a])` |
| `PERIOD_ADD(YYYYMM, n)` | add months then reformat `YYYYMM` |
| `PERIOD_DIFF(YYYYMM1, YYYYMM2)` | `DateDiff("month", ...)` after parsing the YYYYMM ints to dates |
| `LAST_DAY(d)` | `DateAdd("day", -1, DateAdd("month", 1, DateTrunc("month", [d])))` |
| `DATE_FORMAT(d, fmt)` | `DateFormat([d], <translated tokens>)` — see specifier table |
| `TIME_FORMAT(d, fmt)` | `DateFormat([d], <translated tokens>)` (hours/min/sec only) |
| `STR_TO_DATE(s, fmt)` | `DateParse([s], <translated tokens>)` |
| `UNIX_TIMESTAMP(d)` | `DateDiff("second", MakeDate(1970,1,1), [d])` |
| `FROM_UNIXTIME(n, fmt)` | `DateFormat(DateAdd("second", [n], MakeDate(1970,1,1)), <tokens>)` |
| `TO_DAYS(d)` / `FROM_DAYS(n)` | `DateDiff("day", MakeDate(0,1,1), [d])` / inverse — rarely needed; warn |
| `TIME_TO_SEC(d)` / `SEC_TO_TIME(n)` | arithmetic; no pure time type — warn |
| `TIMESTAMP(d)` | `[d]` cast to datetime — usually a no-op in Sigma |

> **Date construction:** Sigma's `Date()` is a **1-arg cast** (string/expr → date type). To build a date from year/month/day, use **`MakeDate(y, m, d)`** — never `Date(y, m, d)` (a 3-arg `Date(...)` fails the workbook/DM export).

### MySQL `DATE_FORMAT` specifier → Sigma `DateFormat` token

| MySQL | Means | Sigma token |
|---|---|---|
| `%Y` | 4-digit year | `YYYY` |
| `%y` | 2-digit year | `YY` |
| `%m` | month 01–12 | `MM` |
| `%c` | month 1–12 | `M` |
| `%b` | abbr month | `MMM` |
| `%M` | full month | `MMMM` |
| `%d` | day 01–31 | `DD` |
| `%e` | day 1–31 | `D` |
| `%a` | abbr weekday | `ddd` |
| `%W` | full weekday | `dddd` |
| `%H` | hour 00–23 | `HH` |
| `%h` / `%I` | hour 01–12 | `hh` |
| `%i` | minute | `mm` |
| `%s` | second | `ss` |
| `%p` | AM/PM | `A` |
| `%T` | `%H:%i:%s` | `HH:mm:ss` |
| `%j` | day of year | (compute) |

---

## Translation workflow (per Beast Mode)

1. Normalize (backticks, WEEKDAY, unsupported, aggregate CEILING/FLOOR, context).
2. `ruby scripts/convert-beast-modes.rb --convert` runs the vendored
   `converter/sql.mjs` against every normalized string in one local `node`
   invocation (no MCP call).
3. Cross-check the result against the tables above; apply the Domo-specific
   gotchas the generic SQL converter misses (CEILING/FLOOR aggregates, `IN`→`or`,
   `DATEDIFF` arg order, format-specifier translation).
4. Validate the column posts without an error type (`diagnose_sigma_save_error`
   if it fails; remember `*Over` window-function limits per
   `feedback_sigma_window_functions`).
