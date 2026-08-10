# Forecast / planning recipes (proven on the FY P&L build, 2026-06-17)

The Sigma spec patterns for an **actuals + driver-grown + manual** model. All
live-verified to exact parity (Net Income −$135,372.84, EBITDA $62,327.16). Pair
with `refs/model-taxonomy.md` (which architecture) and `sigma-build-gotchas.md`.

## 1. Closed-form growth — no recursion

Excel's `forecast = prior × (1+rate)` recursion is a **closed form**:
`forecast[n] = base × (1+rate)^n` where `n` = months after the base (Jun=0). So a
DM custom-SQL element computes it directly — no window functions, no recursion:

```sql
-- spine: one row per (line × forecast month) with base/n/kind/default rate
with spine(line_item, section, month, month_num, month_end, n, kind, default_rate, manual_value, june_base) as (
  values ('Subscription Revenue','Revenue','Jul-26',7,'2026-07-31'::date,1,'growth',0.03,NULL,503000.00), ...
)
select section, line_item, month, month_num, month_end,
  case kind when 'manual' then manual_value when 'flat' then june_base
       else june_base * power(1+default_rate, n) end as amount,
  'Forecast' as period
from spine
```

`^` is the power operator in Sigma workbook formulas (`[June Base] * (1 + [Rate]) ^ [N]`); `power()` in warehouse SQL.

## 2. Override pattern — defaults that stay editable

To make rates/manual cells editable *and* correct before any seed, the forecast
reads `Coalesce([editable input], [default])`:

```
Eff Rate   = Coalesce([Rate], [Default Rate])          -- from an editable rates input table
Eff Manual = Coalesce([Manual Entry], [Manual Value])  -- from an editable manual input table
Amount     = If([Kind] = "manual", [Eff Manual],
                [Kind] = "flat",   [June Base],
                [June Base] * (1 + [Eff Rate]) ^ [N])
```

Unseeded → uses defaults (parity holds); user edits a cell → their value wins and
everything recomputes. The editable inputs are **input tables** joined to the
spine (left-outer, on Line Item [+ Month Num for manual]).

## 3. Combine actuals + forecast — `union`

One P&L fact = union of the live actuals and the forecast. **Both legs must be
wrapped workbook `table` elements** — a `data-model` (or raw input-table) leg
*inside* a `union`/`join` is rejected:
`400 "data-model source requires owning element's columns"`. So wrap each DM/spine
element in a passthrough `table` first (`actuals`, `forecastWrap`/`forecast`).

```yaml
source:
  kind: union          # NOTE: union has no `name` field → outputs are referenced
  sources:             #       as [Union of 2 Sources/Col] downstream
    - { kind: table, elementId: actuals }
    - { kind: table, elementId: forecast }
  matches:
    - { outputColumnName: Section, sourceColumns: ["[Section]", "[Section]"] }   # bare refs, one per leg
    - { outputColumnName: Amount,  sourceColumns: ["[Amount]",  "[Amount]"] }
    # … Line Item, Month, Month Num, Month End, Period
```

Add a `Period` column on each leg (`"Actual"` / `"Forecast"` literal) so the
combined fact carries it. Row-flag calc columns on the combined element drive
cross-section roll-ups:
`Revenue Amt = If([Section]="Revenue",[Amount],0)`, COGS/OpEx/Below likewise →
`EBITDA = Sum(Rev)-Sum(COGS)-Sum(OpEx)`, `Net Income = … - Sum(Below)`.

## 4. Actual vs Forecast, visible — pivot column grouping

Mirror Excel's `ACTUALS | FORECAST` header band: outer `columnsBy` on `Period`,
then `Month`:

```yaml
columnsBy:
  - { id: p_period, sort: { direction: ascending } }   # Actual < Forecast
  - { id: p_month,  sort: { direction: ascending } }
```

(Row order: carry `Section Order`/`Line Order` columns and sort `rowsBy` with
`{ by: <orderCol>, aggregation: min, direction: ascending }`.)

A **trend ref-line** at the actual/forecast boundary does *not* work cleanly: a
`refMark` value is a number/columnId, not a date, and the x-axis is a date — skip
it; the pivot grouping is the reliable cue.

## 5. Plumbing goes on a hidden page

Intermediate elements (`actuals`, `forecastWrap`/`forecast`, `spineWrap`, the
`union`) are sources, not visuals. Unplaced elements **auto-append to the canvas**
(`visibleAsSource:false` does *not* remove them) — put them on a second page with
`visibility: hidden`. Visuals on the main page source them by `elementId`
across pages fine.

## 6. Layout + input-table gotchas (cost real time)

- **Layout only sticks via `wb-rep push`.** A direct `POST`/`PUT` of `pages[].layout`
  is silently replaced by Sigma's auto-arrange. Edit `_layout.xml` in the rep and push.
- **Input-table data-entry columns lose `name`/`format` on readback.** Any re-pull→push
  (or GET→PUT) drops them, which then breaks join keys (`Column reference not found:
  '[Line Item]'`). Re-add `name` (and `format`) on every input-table column before pushing.
- **Input-table data load is UI-only** (paste/CSV + Publish); no REST endpoint yet.
  Seed CSVs cover the editable rates (5 rows) + manual cells (24 rows); defaults keep
  parity until seeded.
- **Workbook controls are filter controls, not free parameters.** A `controlType:number`
  referenced in a calc formula is rejected (`Invalid kind: control`); a true parameter
  needs a data-model control + `parameters` binding. Use an **editable input table** for
  adjustable rates instead (proven), unless/until you wire DM parameters.
