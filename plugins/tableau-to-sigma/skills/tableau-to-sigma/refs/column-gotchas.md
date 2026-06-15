# Column Naming Gotchas

## Sigma auto-normalizes raw → friendly names on POST

Sigma transforms a column's raw warehouse name into a "friendly name" for formula references, **and the POST validator silently rewrites your formula refs to match**. Verified May 2026 against `aws-api.sigmacomputing.com` — POSTed a DM with four different references to the same column and read the spec back:

| Submitted formula | Server stored as |
|---|---|
| `[ORDER_FACT/ORDER_ID]` | `[ORDER_FACT/Order Id]` |
| `[ORDER_FACT/order_id]` | `[ORDER_FACT/Order Id]` |
| `[ORDER_FACT/Order Id]` | `[ORDER_FACT/Order Id]` |
| `[ORDER_FACT/Order_Id]` | `[ORDER_FACT/Order Id]` |

Two normalization rules combine:
1. **Special chars** stripped — `/`, `-`, `.`, `[`, `]`, leading/trailing whitespace.
2. **Casing and word boundaries** — `ALL_CAPS_WITH_UNDERSCORES` → title-cased with spaces; `camelCase` → split on case boundaries.

Examples observed: `DATE` → `Date`, `UNIT PRICE` → `Unit Price`, `ORDER_ID` → `Order ID`, `V userId` → `V User Id`, `Net/Gross` → `Net Gross`.

**Practical impact for tableau-to-sigma:** the skill emits raw warehouse refs like `[ORDER_FACT/ORDER_ID]` and they work because of this auto-fix. **Don't fight it** — emit the raw warehouse name, let Sigma normalize. The readback will show you the canonical friendly name if you ever need to write a cross-element ref or controlId.

> **The auto-fix doesn't cover everything.** Some edge cases still produce `Unknown column "[X]"` strings in the compiled SQL — invisible at POST time. Always run `scripts/verify-workbook.rb <workbookId>` after PUT to catch the residue. See Phase 5f in SKILL.md.

**Alternate verification: `mcp__sigma-mcp-v2__describe`.** When you want to inspect a single element's compiled column types + resolved formulas without running the bash script, `describe` with `type: workbook-element` returns DDL like `"col-id" number -- "Friendly Name" | Formula: <resolved formula>`. Columns whose type comes back as `error` are the silent-failure case the auto-normalizer didn't fix. Useful during iterative spec authoring.

## The slash problem

Sigma uses `/` as the source-prefix separator in formula references: `[TableName/ColumnName]`.
If a column's `name` field itself contains `/`, every formula that references it becomes unresolvable.

**Tableau display names that contain slashes (common):**
- "Country/Region" → rename to `"Country"`
- "State/Province" → rename to `"State"`

**Rule:** Before writing the data model spec, rename any column whose `name` contains `/`.
Do it once in the data model; all downstream workbook formulas inherit the clean name.

## Tableau display names ≠ warehouse column names

Tableau stores a human-readable "display name" that is almost never the actual warehouse column name. The exact transform varies by warehouse:

| Tableau display | Snowflake (UPPER_SNAKE) | BigQuery / Databricks / Postgres (lower_snake) | Case-preserving connectors (camelCase) |
|---|---|---|---|
| Sub-Category | SUB_CATEGORY | sub_category | subCategory |
| Country/Region | COUNTRY_REGION | country_region | countryRegion |
| Order Date | ORDER_DATE | order_date | orderDate |
| Customer Name | CUSTOMER_NAME | customer_name | customerName |

**Rule:** Always fetch actual column names from the Sigma connection API — it's uniform across warehouses:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/tables/<inodeId>/columns" \
  | jq '[.entries[] | {name, dataType}]'
```

Or use the wrapper `scripts/discover-columns.rb --connection-id <id> --table-path <db>.<schema>.<table>` which resolves the inodeId for you and works the same against any warehouse Sigma supports.

Never infer warehouse column names from Tableau display names.

## Sub-Category hyphen

"Sub-Category" is a valid column `name` in the data model spec. Hyphens are fine.
The formula reference `[Orders/Sub-Category]` works correctly.

## Cascading failures

If one column formula is invalid, the entire element (table) fails — not just that column.
The error message names the specific bad ref. Fix only that ref and retry; don't rebuild the whole element.

## Column ID format

Column IDs in a data model spec can be any unique string. The server reassigns them on POST, so your
IDs are just for cross-referencing within the JSON file you're writing. Short readable IDs like
`"col-sales"` or `"met-profit-ratio"` are fine.

## Metrics vs columns

Metrics are aggregate formulas that live alongside columns but reference column names without a table prefix:
```json
{"id": "met-sales", "formula": "Sum([Sales])", "name": "Total Sales"}
```
Note: `[Sales]` not `[ORDERS/Sales]` — within the same element, bare refs work.

## Integer date keys (YYYYMMDD format)

Warehouses commonly store dates as integers in `YYYYMMDD` format (e.g., `20240115`) — a Snowflake habit, but it shows up in BigQuery, Databricks, Postgres, and SQL Server schemas too.
Sigma line charts treat these as plain numbers — the axis shows integer values instead of dates
and the trend renders incorrectly.

**Rule:** Cast integer date keys to proper dates at the workbook column level by building an ISO
string and passing it to `Date()`:

```json
{"id": "col-date", "formula": "Date(Left(Text([Master/ORDER_DATE_KEY]), 4) & \"-\" & Mid(Text([Master/ORDER_DATE_KEY]), 5, 2) & \"-\" & Right(Text([Master/ORDER_DATE_KEY]), 2))", "name": "Order Date"}
```

Key points:
- `Text()` is the correct string conversion function — `ToText()` does not exist in Sigma
- `Date()` takes a single ISO date string (`"YYYY-MM-DD"`) — it does not accept 3 separate arguments
- `DateParse(text, format)` DOES exist in Sigma and returns a datetime (verified 2026-06-15) — but it parses a **text** input with an **strftime** format (e.g. `DateParse(Text([YYYYMMDD]), "%Y%m%d")`), not a Java/Tableau format string. The Tableau converter emits it for `DATEPARSE` (with the format auto-rewritten to strftime). `Date("YYYY-MM-DD")` is still the simplest path for an ISO-string column.
- `Mid()` is 1-indexed (position 5 gives the month digits of a YYYYMMDD integer)

Do this in the workbook master table column, not in the data model — keep the integer column
as-is in the data model (useful for filtering/sorting) and cast only where you need a date axis.

## Tableau IF/ELSE-catches-null vs Sigma If

Tableau's `IF x >= 5000 THEN "Platinum" ELSEIF x >= 2000 THEN "Gold" … ELSE "Bronze" END`
sends NULL `x` to the ELSE branch — `NULL >= 5000` evaluates to NULL, every comparison
falls through, and the ELSE arm fires. Sigma's `If(NULL >= 5000, ..., ...)` returns NULL,
not the false-arm. The downstream symptom is an extra NULL bucket on a chart that has no
NULL bucket in Tableau, plus skewed totals in the Tableau-equivalent ELSE bucket.

This shows up most often after a `Lookup()` for orphan-joined fact rows (no matching dim
key → null lookup → null bucket).

**Fix — wrap the lookup with `Coalesce`:**

```json
{
  "formula": "Coalesce(Lookup([Customer Dim/Customer Value Tier], [Customer Key], [Customer Dim/Customer Key]), \"Bronze\")"
}
```

Or coalesce the base measure before the comparison chain:

```json
{
  "formula": "If(Coalesce([Lifetime Revenue], -1) >= 5000, \"Platinum\", If(Coalesce([Lifetime Revenue], -1) >= 2000, \"Gold\", If(Coalesce([Lifetime Revenue], -1) >= 500, \"Silver\", \"Bronze\")))"
}
```

Use whichever default value lands the null rows in the same bucket Tableau's ELSE was
catching them in (-1 forces "Bronze" for the lifetime-revenue tier; pick a value below
all thresholds).

### Worse case: null misbucketed into the literal else string

The same null-propagation pattern causes a **silent misbucketing** when the formula is a
chain of equality checks on a nullable source, and the final else returns a string
literal instead of a comparison. Example — categorizing weekday names from a nullable date:

```
If(Weekday([Ship Date]) = 1, "1 Sunday",
  If(Weekday([Ship Date]) = 2, "2 Monday",
    ...
    If(Weekday([Ship Date]) = 6, "6 Friday",
       "7 Saturday")))   // ← every null Ship Date lands here, silently
```

`Weekday(NULL)` is NULL; `NULL = 1` is NULL (treated as false); every comparison falls
through to the literal `"7 Saturday"`. The output table now has correctly-bucketed
weekdays for non-null rows AND null-shipping orders piled into Saturday — with no error
indication anywhere. Verified May 2026: 53 rows with `Ship Date Key` null all rendered as
"7 Saturday" until a null guard was added.

**Fix — wrap the entire chain with an outer null guard so nulls return Null instead of
falling through to the else:**

```json
{
  "formula": "If(IsNull([Ship Date]), Null, If(Weekday([Ship Date]) = 1, \"1 Sunday\", If(Weekday([Ship Date]) = 2, \"2 Monday\", If(Weekday([Ship Date]) = 3, \"3 Tuesday\", If(Weekday([Ship Date]) = 4, \"4 Wednesday\", If(Weekday([Ship Date]) = 5, \"5 Thursday\", If(Weekday([Ship Date]) = 6, \"6 Friday\", \"7 Saturday\")))))))"
}
```

Apply this defensively to every nested-If categorization formula whose source column
might be null — date-derived dimensions (Weekday/Month/Year), lookup-derived fields,
and any column that could carry NULL from an orphan join.

## Cross-year month rollup (Tableau MONTH part vs Sigma DateTrunc)

A Tableau dimension built from `MONTH([Order Date])` (the date *part*, not a truncation)
produces 12 month-name buckets that aggregate across **all years** in the data — January
2024 and January 2025 collapse into a single "January" point.

Sigma's `DateTrunc("month", [date])` does **not** do this. It preserves the year, so the
same data renders as 24 month-year points (Jan 2024, Jan 2025, …) instead of 12.

When the Tableau view CSV shows month names without years (e.g. `"Month of Order Date Key,Gross Revenue\nJanuary,1224.88\n..."`),
the original chart is using the part-extraction form. To match it in Sigma, synthesize a
single-year date inside the formula so all years share an axis:

```json
{
  "id": "mr-month",
  "formula": "Date(\"2024-\" & Mid(Text([Master/Order Date Key]), 5, 2) & \"-01\")",
  "name": "Month",
  "format": {"kind": "datetime", "formatString": "%B"}
}
```

The year `"2024-"` is arbitrary — any constant works because it's stripped by the `%B`
format. Same trick adapts to `Year`-stripped quarters (use a fixed year and the quarter's
first month) or weeks (fixed year + ISO week).

If the Tableau CSV shows month-year together (`"January 2024,664.94\n..."`), the chart is
using `DateTrunc` and you don't need this workaround — plain `DateTrunc("month", [Master/Order Date])`
matches.

> **Always confirm by inspecting the CSV before picking a formula.** Tableau worksheet titles
> ("Monthly Revenue Trend") don't tell you which form is in use; the CSV does.

## Integer columns as boolean predicates in `If(...)` fail at render

Sigma's SQL compiler accepts `If([Is Returned], 1, 0)` when `[Is Returned]` is a
Snowflake `NUMBER(1,0)` (bit-like) column — `verify-workbook.rb` reports the
chart compiles **clean** because the column type comes back as `number`, not
`error`. But at render time Sigma throws `Invalid Query: Argument 1 invalid`
and the chart blanks out.

**Fix — rewrite as an explicit comparison:**

```json
{"formula": "If([Is Returned] = 1, 1, 0)"}
```

Apply to any integer/bit column used as the first argument of `If()`. The same
pattern breaks `Switch([Some Int Col], ...)` — wrap in an explicit comparison
or `Text()` cast as needed.

**Detection — verify-workbook does NOT catch this.** Sigma reports the formula
as compiling to a valid `number` type during PUT readback. Only Phase 6f's
`POST /v2/workbooks/{wb}/export` + PNG inspection catches the render-time
failure (the chart exports as an empty plot area). Always run Phase 6f when an
`If()` predicate is an integer column. Verified 2026-05-24 against OCT's
`Is Returned` column on `TJ.PUBLIC.SUPERSTORE_ORDERS`.

## YAML response from spec endpoints

`POST /v2/dataModels/spec` and `POST /v2/workbooks/spec` return **YAML**, not JSON.
Piping to `jq` causes `parse error: Invalid numeric literal`.

Parse with Ruby:
```bash
ruby -r yaml -r json -r date -e \
  "puts JSON.pretty_generate(YAML.safe_load(STDIN.read, permitted_classes:[Date,Time]))"
```
