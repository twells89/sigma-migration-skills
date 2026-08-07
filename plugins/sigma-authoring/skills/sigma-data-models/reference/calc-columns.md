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
- **Cross-element** — **use `Lookup()`. Do not use the bare `[Element Name/Column Name]` form.**
  See the warning immediately below: the bare form is accepted at PUT, reports a
  clean type, and then returns NULL for every row.
- **From a warehouse-table source** — `[TABLE_NAME/Column Display Name]` where `TABLE_NAME` is the last segment of the source's `path` (uppercase, as it appears in the warehouse).

A calc column **cannot reference itself**, even transitively — the server rejects circular references.

### ⚠️ Cross-element refs: `Lookup()` only — the bare form silently returns NULL

A bare cross-element reference in a DM calc column — `[Other Element/Column]` —
**compiles clean and then evaluates to NULL for every row.** It is accepted at
PUT, `/columns` reports a normal type with `error: null`, and nothing surfaces a
problem at any layer you can inspect. The dashboard just quietly shows nothing.

Measured 2026-08-06 on a two-element model with a defined relationship, 906 fact
rows, two calc columns identical in intent:

| Formula | Non-null rows |
|---|---|
| `[Customer Dim/Region]` (bare) | **0 / 906** |
| `Lookup([Customer Dim/Region], [Customer Key], [Customer Dim/Customer Key])` | **872 / 906** |

Both reported `type: text`, `error: null`. Always write:

```
Lookup(<value from the other element>, <local key>, <other element's key>)
```

The local key column must already exist on this element.

Two caveats that matter at scale:

1. **Orphan rows return NULL.** The 34-row gap above is genuine — fact rows whose
   key is absent from the dimension. If you are porting logic from a tool whose
   `ELSE` branch swallowed NULLs (Tableau does: `NULL >= 5000` falls through),
   wrap it: `Coalesce(Lookup(...), "Bronze")`. Otherwise you get a NULL bucket
   where the source had a default.
2. **`Lookup()` returns ONE ARBITRARY match per key.** On a non-unique join key
   the pick is nondeterministic and silent. Confirm the target key is unique
   before relying on it.

There is no supported bare-reference form to fall back to. If `Lookup()` cannot
express what you need, push the join into a `sql` source instead.

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
