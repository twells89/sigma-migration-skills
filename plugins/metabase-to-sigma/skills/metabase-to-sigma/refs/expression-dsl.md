# Metabase expressions → Sigma formulas

Unlike every other source tool in this family, Metabase expressions arrive
**already parsed**: MBQL is nested JSON arrays (`["+", ["field", 72, null], 5]`),
so `converter/metabase.ts` (`translateMbqlExpr`) walks a tree — no regex DSL
parsing. The custom-expression *text* a user typed (`[Price] - [Cost]`) is never
stored; only the MBQL tree is.

Modern instances emit **pMBQL** clauses (`[op, {opts}, …args]` — opts second);
`pmbql-normalize.mjs` rewrites them to the legacy shapes below at intake, so
every row in this table is expressed in legacy clause order. See
`mbql-shapes.md` § pMBQL.

## Translated (automatic)

| MBQL op | Sigma | Notes |
|---|---|---|
| `["field", id, opts]` | `[Display Name]` / `[TABLE/Display Name]` | id → name via `fieldIndex`; `join-alias` → the joined element prefix; `temporal-unit` wraps in `DateTrunc("month", x)` |
| `["expression", "Name"]` | `[Name]` | sibling custom-column ref |
| `+ - * /` | `+ - * /` | n-ary in MBQL → left-fold binary |
| `["case", [[c1,v1],[c2,v2]], {"default": d}]` | `If(c1, v1, If(c2, v2, d))` | |
| `["coalesce", a, b, …]` | `Coalesce(a, b, …)` | |
| `["concat", a, b, …]` | `Concat(a, b, …)` | |
| `["substring", s, start, len]` | `Mid(s, start, len)` | both 1-indexed |
| `["trim"/"ltrim"/"rtrim", s]` | `Trim/LTrim/RTrim(s)` | |
| `["upper"/"lower", s]` | `Upper/Lower(s)` | |
| `["length", s]` | `Len(s)` | |
| `["replace", s, find, repl]` | `Replace(s, find, repl)` | literal find (not regex) |
| `["regex-match-first", s, pat]` | `RegexpExtract(s, pat)` | |
| `["split-part", s, delim, n]` | `SplitPart(s, delim, n)` | |
| `["round"/"floor"/"ceil"/"abs"/"sqrt"/"exp", x]` | `Round/Floor/Ceiling/Abs/Sqrt/Exp(x)` | |
| `["text", x]` / `["float", x]` / `["integer", x]` | `Text(x)` / `Number(x)` / `Int(x)` | v50+ casts |
| `["date", x]` | `DateTrunc("day", x)` | date(x) = day-truncated datetime |
| `["in"/"not-in", f, a, b, …]` | `(f = a or f = b or …)` / `(f != a and …)` | pMBQL multi-value ops (also appear in server `legacy_query`) |
| `["power", x, y]` | `Power(x, y)` | |
| `["log", x]` | `Log(x, 10)` | Metabase `log` is base-10 |
| `["datetime-add", d, n, "unit"]` | `DateAdd("unit", n, d)` | unit string passes through |
| `["datetime-subtract", d, n, "unit"]` | `DateAdd("unit", -n, d)` | |
| `["datetime-diff", a, b, "unit"]` | `DateDiff("unit", a, b)` | |
| `["get-year"/"get-month"/"get-day"/"get-hour"/"get-quarter", d]` | `DatePart("year"/…, d)` | `get-day-of-week` → `DatePart("dayofweek", d)` |
| `["now"]` | `Now()` | |
| `["relative-datetime", -30, "day"]` | `DateAdd("day", -30, Today())` | inside filters |
| `= != < <= > >=` | `= != < <= > >=` | `["=", f, v1, v2]` (multi-value) → `(f = v1 or f = v2)` — Sigma has **no `IsIn`** (and **no `Or()`/`And()` functions** — infix only, live-verified) |
| `["between", x, lo, hi]` | `Between(x, lo, hi)` | |
| `["and"/"or"/"not", …]` | infix `(… and …)` / `(… or …)` / `Not(…)` | |
| `["is-null"/"not-null", x]` | `IsNull(x)` / `IsNotNull(x)` | `is-empty`/`not-empty` add `Or x = ""` for text |
| `["starts-with"/"ends-with"/"contains", s, sub]` | `StartsWith/EndsWith/Contains(s, sub)` | `does-not-contain` → `Not(Contains(…))`; default case-insensitive in Metabase — wrapped in `Lower()` unless `{"case-sensitive": true}` |
| `["time-interval", f, -30, "day"]` | `f >= DateAdd("day", -30, Today())` | "previous 30 days" filter idiom; `"current"` → `DateTrunc(unit, f) = DateTrunc(unit, Today())` |
| `["inside", lat, lon, …]` | lat/lon `Between` pair | map box filter |

## Aggregations

| MBQL | Sigma | Notes |
|---|---|---|
| `["count"]` | `Count()` | row count |
| `["sum"/"avg"/"min"/"max"/"median", f]` | `Sum/Avg/Min/Max/Median(f)` | |
| `["distinct", f]` | `CountDistinct(f)` | |
| `["stddev", f]` | `StdDev(f)` | sample |
| `["var", f]` | `Variance(f)` | |
| `["percentile", f, 0.95]` | `Percentile(f, 0.95)` | |
| `["count-where", cond]` | `CountIf(cond)` | condition only — no field arg |
| `["sum-where", f, cond]` | `SumIf(f, cond)` | **field first** in both |
| `["share", cond]` | `CountIf(cond) / Count()` | ratio of matching rows; format `,.2%` |
| `["aggregation-options", inner, {name…}]` | inner | wrapper supplies the metric's name |

## Flagged — never faked (warning + readable placeholder)

| MBQL | Why | What to do |
|---|---|---|
| `["cum-sum"/"cum-count", f]` | running totals need a window scope Sigma defines on the *consuming element* | rebuild with `CumulativeSum` in the date-grouped workbook element (proven pattern — see powerbi DateLookback note) |
| `["offset", expr, -1]` (v50+) | lag/lead window fn | rebuild with `Lag`/window calc in the consuming element |
| `["segment", id]` | saved-segment ref — definition lives in another object | inline the segment's own MBQL (discovery fetches `/api/segment/{id}`; auto-inline is a roadmap item) |
| `["metric", id]` (legacy) | saved-metric ref | same — inline from `/api/legacy-metric/{id}` |
| `binning` opts on a breakout | numeric histogram buckets | recreate with `BinFixed`/`BinCount` in the workbook element |
| `["day-name"/"month-name"/"quarter-name", x]` | localized name lookup — no confirmed Sigma fn | rebuild with a `case`/If chain or a Sigma Text format (observed 10× on a 7k-card estate) |
| multi-stage query (pMBQL `stages` > 1 / legacy `source-query`) | a sub-query, not an expression | rebuild as chained Sigma elements; converter flags + skips (14 of 7,023 observed) |
| native `{{tag}}` of type `dimension` ("field filter") | expands to a whole WHERE clause at runtime | becomes a Sigma control on the target column + element filter; plain `text`/`number`/`date` tags → `=`-parameter controls (converted) |
| `click_behavior` | cross-filter / drill links | Sigma actions — manual follow-up |
| `smartscalar`/`trend` comparison | auto previous-period delta | KPI value converts; add a Sigma comparison manually |

> MBQL `["value", v, …]` literal wrappers unwrap transparently. Unknown ops emit
> `/* unmapped: <op> */` placeholders + a loud warning — never silent, never guessed.
