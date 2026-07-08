# MAQL → Sigma formula mapping (research spike, verified June 2026)

MAQL (Multidimensional Analytical Query Language) is GoodData's metric language
and the **single biggest engineering surface** of this migration — the
DAX-time-intel / LookML-measure class of risk. This doc is the translation
contract; the converter rides the existing `convert_*_to_sigma_formula`
plumbing plus a MAQL parser, and logs anything unmapped via gap-scout
(flag, never fake).

## Grammar essentials

A metric is always `SELECT <expr>` returning a number. Objects are referenced
by typed id:

| MAQL | Means |
|---|---|
| `{fact/revenue}` | a fact (row-level numeric) |
| `{metric/gross_profit}` | another metric (nestable) |
| `{label/region}` / `{attribute/region}` | a dimension / its label |
| `# ...` | comment |

## Mapping table

| MAQL construct | Example | Sigma |
|---|---|---|
| Aggregation of a fact | `SELECT SUM({fact/qty})` | `Sum([Dataset/Qty])` |
| Other aggregations | `AVG/MIN/MAX/MEDIAN/COUNT` | `Avg/Min/Max/Median/Count` |
| Row-level arithmetic in agg | `SELECT SUM({fact/qty}*{fact/price})` | `Sum([Qty]*[Price])` |
| Metric reference (nesting) | `SELECT {metric/revenue} - {metric/cost}` | reference the other DM metrics: `[Revenue] - [Cost]` |
| Filtered metric | `SELECT {metric/rev} WHERE {label/color}="red"` | `SumIf` / conditional aggregate, or a filtered DM metric |
| Ratio | `SELECT {metric/rev} / {metric/rev} BY ALL {attr/region}` | share-of-total → windowed agg / Level-style total |
| **`BY` context** | `SELECT SUM({fact/rev}) BY {attr/region}` | controls aggregation grain → Sigma grouping / `Level`-scoped aggregate |
| **`BY ALL`** | `SELECT SUM({fact/rev}) BY ALL {attr/region}` | ignore that dimension → grand-total / `Total()`-style window |
| **`WITHIN`** | `... WITHIN {attr/category}` | partition aggregate → windowed agg partitioned by the attribute |
| Ranking | `TOP(n)` / `BOTTOM(n)`, rank filters | Sigma top-N element filter or `Rank()` |
| **Time: prior period** | `SELECT {metric/rev} FOR PREVIOUS({date.month})` | `DateLookback` in a date-grouped element (proven PBI time-intel approach) |
| `FOR PREVIOUS(x, n)` | n periods ago | `DateLookback(..., n, "month")` |
| `FOR NEXT` | forward shift | forward `DateLookback` (negative offset) |
| Period-over-period | derived from the two above | current vs `DateLookback` ratio in a date-grouped tile |

## Context keywords are the crux

`BY` / `BY ALL` / `WITHIN` redefine the aggregation grain independent of the
report's grouping — Sigma has no 1:1 keyword. They map to a **combination of
element grouping + windowed/Level-scoped aggregates**, and the right target
depends on the consuming insight's buckets. This is exactly the enterprise-class
"context-dependent aggregation" trap; expect iteration and lean on parity
(not structure) to confirm.

## Flag, never fake — expected UNHANDLED set

Surface these as loud flags instead of guessing:

- Metrics whose computation has **no clean warehouse-SQL equivalent** (GoodData
  FlexQuery / extensible-analytics-only behavior).
- Deeply nested `BY/WITHIN` stacks where the grain can't be reconstructed from
  the insight context alone.
- `FOR` time transforms on non-standard / fiscal date dimensions until the date
  dimension mapping is confirmed live.
- Anything the parser doesn't recognize → `UNHANDLED` + the raw MAQL, logged to
  learned-rules and (opt-in) escalated as a gap issue.

## Build order for the translator

1. Plain aggregations + arithmetic + metric nesting (covers the majority).
2. `WHERE` filters → conditional aggregates.
3. `BY` / `BY ALL` / `WITHIN` context (the hard third).
4. `FOR PREVIOUS/NEXT` time intel (reuse DateLookback recipe).
5. Ranking / ratios.

Measure coverage with gap-scout from day one — same discipline as the calc-gap
closure rounds on the other converters.
