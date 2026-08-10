# Spreadsheet model taxonomy + the architecture decision

The hard part of Excel→Sigma isn't the mechanical build — it's **classifying the
model**: which parts are live actuals, which are driver-grown, which are typed
inputs, which are derived. That classification is mostly deterministic; the
*architecture* it implies depends on **how the model is used**, which isn't in the
file — so you **detect, propose a model map, then ask a few intent questions**.

This is the path that handles "report drawn in cells" workbooks (no formal Table)
— the common FP&A case the formal-Table router (`refs/excel-translation.md`) skips.

## Detect — the cell-level classifier (`xlsx-discover.py`)

For every formula/value cell on a non-Table sheet, `classify_report_cells` emits:

| Class | Excel signal | Sigma target |
|---|---|---|
| **ACTUAL** | `SUMIFS`/`SUMIF`/`SUMPRODUCT` over a transaction tab | live read-only DM element off that source |
| **DRIVER_GROWTH** | `=prior_cell * (1 ± Assumptions!rate)` | closed-form `base × (1+rate)^n` (rate from the drivers) |
| **MANUAL** | numeric literal sitting in a row that's otherwise formula-driven | editable input table (one cell per line×period) |
| **FLAT** | `=single_prior_cell` (carried) | `= base` |
| **DERIVED** | arithmetic of sibling cells / `IF` margins (totals, %s) | workbook calc columns |

It also reports the **actuals source** sheet (SUMIFS targets) and the
**driver/assumptions** sheet (the `(1±rate)` refs). Example, FY P&L model:

```
P&L: DERIVED=111, ACTUAL=60, DRIVER-grown=30, MANUAL=24, FLAT=6
  → actuals source: Data        (= live read-only DM element)
  → drivers:        Assumptions  (= editable rates table / controls)
```

That map *is* the architecture: **union [live ACTUAL] + [forecast]**, where
forecast = DRIVER_GROWTH + MANUAL + FLAT, and DERIVED becomes workbook calcs.

## The decision — ask intent (don't guess)

The classification is fixed; the *build* hinges on one question. Present the
detected model map, then ask (use the recommended-default pattern):

**1. How is this model used?** (the load-bearing question)

| Answer | Actuals | Forecast | Drivers |
|---|---|---|---|
| **Read-only report** | live DM | computed, baked | reference table |
| **Editable plan** | live DM | editable input table(s) | reference table |
| **Live what-if model** (recommended for FP&A) | live DM | computed via closed-form | **editable rates + manual cells** that recompute |

**2. Which detected inputs stay editable?** (pre-fill from MANUAL + driver detection: the growth rates, the manual cells, or both)

**3. Actuals: live or snapshot?** (default **live** — re-query the source, matching Excel's `SUMIFS`)

Keep it to these. Everything else (grain, sections, line order, parity targets)
is derivable. The questions are *informed by* the model map, so the agent looks
like it understands the spreadsheet — it does.

## Build + the trust gate

Build per `refs/forecast-recipes.md` for the chosen architecture, then **assert
parity to the cent** against the spreadsheet's cached totals (e.g. Net Income,
EBITDA, Total Revenue). The parity gate is what makes the output trustworthy
regardless of how the questions were answered — never call a migration done
without it.

## Macros

If `.xlsm`, run the **macro gate** (`refs/macro-handling.md`) in the same discovery
pass — macros often *are* the "how it's used" answer (a `CommitForecast` button ⇒
this is an editable plan with scenario history).
