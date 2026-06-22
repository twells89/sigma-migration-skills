# JAQL → Sigma formula mapping

JAQL (JSON Analytical Query Language) is how Sisense encodes dimensions,
measures, and filters inside widget panels. This is the workbook-side
translation surface (`scripts/jaql_expr.py`). **Verify against real widget JAQL**
once a sample dashboard exists — the trial has 0 dashboards.

## Item shapes
```jsonc
// simple aggregated measure
{ "jaql": { "dim": "[Commerce.Revenue]", "agg": "sum", "title": "Total Revenue" } }

// formula measure with context (each [tokenN] resolves to a sub-item)
{ "jaql": { "formula": "SUM([Rev]) / SUM([Cost])",
            "context": { "[Rev]": { "dim": "[Commerce.Revenue]" },
                         "[Cost]": { "dim": "[Commerce.Cost]" } } } }

// dimension with level (date)
{ "jaql": { "dim": "[Commerce.Date]", "level": "months" } }
```

## Aggregation map
| JAQL `agg`     | Sigma     |
|----------------|-----------|
| `sum`          | `Sum`     |
| `count`        | `Count`   |
| `countdistinct`| `CountDistinct` |
| `avg`          | `Avg`     |
| `min` / `max`  | `Min`/`Max` |

## Function map (starter — extend + verify)
| JAQL function          | Sigma |
|------------------------|-------|
| arithmetic `+ - * /`   | same |
| `RANK(...)`            | `Rank(...)` (grouped) — verify partition semantics |
| `RSUM(...)`            | `CumulativeSum(...)` over an ordered grouping |
| `PREV(...)` / `PAST`   | `Lag(...)` / DateLookback in a date-grouped element |
| `GROWTH`, `GROWTHPAST` | derived (current−prev)/prev — verify |
| filtered measure (`context` w/ a filter member) | `SumIf`/`CountIf` style |

## Flag (don't fake)
- Custom plugin JAQL functions, deeply nested `context` measures, statistical
  functions without a clean Sigma equivalent → surface in the conversion report.
- Lean on the shared `convert_sql_to_sigma_formula` MCP translator for the
  math/agg core where the JAQL formula is SQL-like.
