# Calculated Columns

Calculated columns are columns whose value is derived from a formula rather than read from the warehouse. They live in the same `columns` array as warehouse columns on an element.

## Shape

```json
{
  "id": "<short-id>",
  "name": "Profit",
  "formula": "[Revenue] - [Cost]"
}
```

A calc column has no warehouse-column ID prefix — its `id` is a generated short alphanumeric, not `inode-<22>/COL`. The `formula` is what makes it a calc column.

## Formula references

- **Within the same element** — bare `[Column Name]` (case-sensitive, must match a column's `name` field on the same element).
- **Cross-element** — `[Element Name/Column Name]`. The element name is the source element's `name`.
- **From a warehouse-table source** — `[TABLE_NAME/Column Display Name]` where `TABLE_NAME` is the last segment of the source's `path` (uppercase, as it appears in the warehouse).

A calc column **cannot reference itself**, even transitively — the server rejects circular references.

## The `*Over` window functions don't work — but the native family does

The `*Over` family — `CountOver`, `SumOver`, `RowNumberOver`, `RankOver`, `MaxOver`, `MinOver` — is **not a valid spec formula**. In a data-model element calc column a DM-spec POST **hard-rejects** them (400 Bad Request); in a workbook calc column they resolve to `Unknown function` at query time. Never emit the `*Over` names from a spec.

The Sigma-**native** window family — `CumulativeSum` / `CumulativeAvg` / `CumulativeMax` / `CumulativeMin` / `CumulativeCount`, `MovingSum` / `MovingAvg` / `MovingMax` / `MovingMin` / `MovingStdDev`, `Rank` / `RankDense` / `RankPercentile`, `RowNumber`, `Lag`, `Lead`, `PercentOfTotal` — **does** work. Live-verified 2026-07-15: each compiles to real warehouse `OVER(...)` in a DM-element calc column, in a grouped workbook table, and in an ungrouped workbook "master" table sourced from a data model. There is **no** inherited DM-side restriction on DM-sourced workbook tables. Prefer these over the `*Over` names.

### Workarounds (only when there is no native equivalent)

| If you need… | Do this |
|---|---|
| A running total, moving window, rank, or row number | Use the native form (`CumulativeSum` / `MovingAvg` / `Rank` / `RowNumber` / `Lag` / `Lead` / `PercentOfTotal`) — it works directly in a DM-element or workbook calc column. |
| An `*Over`-only construct with no native equivalent | Push it to a `sql` source — write the window function in SQL once, expose the result as a regular warehouse column. |
| A simple cumulative metric | `CumulativeSum(...)` in a calc column, or a model metric with `Sum / Count / etc.` |

### Side effect to know about

When a calc column on a DM element is set to an unsupported formula and the model is saved via API, **the element's column IDs may be reassigned** on the next read. Always re-`GET` the spec after a save before composing any update — don't trust your last-known IDs.

## Common errors

- **"Invalid column reference"** — bare `[col]` where a prefix was needed, or a misspelling. Re-check column names against the source via `discover.md`.
- **Column shows `error` icon, formula looks fine** — likely an `*Over` function (`SumOver`/`CountOver`/…). Switch to the native window function (`CumulativeSum`/`MovingAvg`/`Rank`/`Lag`/…), which resolves in calc columns.
- **Chart that references this column blanks out** — the calc column is in error state. Fix the formula; the chart will recover on the next render.

See `formulas.md` (in the `sigma-workbooks` skill) for the full formula language reference, including the function list. The data-model side uses the same formula syntax with the constraints noted here.
