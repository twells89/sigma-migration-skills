# Equity-research model recipes (broker / FactSet house-template models)

The archetype for **sell-side equity-research models** — a covered-company model with
line-items down the rows, **YEARS across the columns**, grouped into statement sections
(PROFIT AND LOSS, PER SHARE DATA, EVALUATION, BALANCE SHEET, CHANGE IN NET DEBT, …). One
analyst maintains each; a single sell-side desk covers hundreds off **one house template** (can be ~850). This is a different shape from the FP&A forecast archetype in
`refs/forecast-recipes.md` (months across, actuals+driver-grown+manual, input-table entry).

**Validated end-to-end on a real broker equity-research model: 100.00% cell parity (3,263/3,263
cells across 24 years), 0 wrong, with ~81% of derived cells as LIVE Sigma formulas.** Built
entirely via REST — `infer-canonical-formulas.py` → plan JSON → `build-research-model.py`.

## The one big idea (why the hand build bloats, and the fix)

A hand build of one of these tends to explode: in the validated model, the manual P&L pivot had **97
columns** — every line item split into `X User` / `X Calc` / `X (1)` triplets with
`Coalesce([X User],[X Calc])` chains (some circular, one a literal placeholder) — because the
*same line is a hardcode in some years and a formula in others* (analyst overrides), and they
tried to honour every per-year exception. Per Share Data, done right, used **one formula per
line for all years** and stayed small. That is the whole lesson.

**Architecture (the clean version):**

1. **Data page** — *every typed number in the grid* as inline `VALUES` custom-SQL, WIDE:
   one row per YEAR, one column per line item (`c<row>` safe id). A typed cell is *always*
   data — a historical actual OR a forecast-year override; you never classify override-vs-actual.
2. **Computation table** — one calc COLUMN per line item (making each line a column, not a
   pivot row, is what lets each carry its OWN formula):
   - input line → `[data/c<row>]`
   - derived line → `Coalesce([data/c<row>], <ONE canonical formula>)` — the typed override
     wins automatically; the formula fills the blanks. **Exactly one Coalesce, one formula,
     all years. No `User`/`Calc`/`(1)` triplets.**
3. **Long** — a `transpose` (column-to-row) unpivot of the computation table → `(Year, LineId,
   Value)`.
4. **Labeled** — join Long ⋈ a line-dim (id → label / section / order).
5. **Display pivot** — `rowsBy` Section→Line Item (ordered), `columnsBy` Year, `Sum(Value)`.

## Canonical-formula inference (`infer-canonical-formulas.py`)

- **Year-relative normalisation.** Rewrite each Excel formula's refs to `(col_offset, row)` —
  offset 0 = same year, −1 = prior. Resolve `row` → the line item. Cells that differ only by
  which year-column collapse to the **same canonical key**; the row's formula is the **modal**
  key. `=F13-F8` → `[Gross profit] - [Turnover]`; `=F13/E13-1` → `[X]/Lag([X],1,[Year]) - 1`.
- **Refs are `[c<row>]` safe ids, not labels** — labels carry `/`, `%`, `&` which break Sigma
  refs. A line-dim maps `c<row>` → the real label for display.
- **Sigma idioms:** `Lag([c],k,[Year])` for prior-year (% change, CAGR); `[a]/[b]` for ratios;
  `^` for power; Excel `IF`→`If`, `SUM`→`Sum`; Excel `101%`→`(101*0.01)`.

## The three hard problems and how they're handled

1. **Plug cycles.** History types COGS→computes Gross profit; the forecast types Gross
   profit→computes COGS. One formula per row makes that a *static* cycle Sigma rejects. Detect
   cycles (incl. same-period self-refs; `Lag`/`Lead` prior-period refs are NOT cycles) from the
   **rendered** formulas, and **demote the most-typed cycle member to carried data** ("start
   from the hard-coded values"). It becomes a `[data/c]` leaf; the rest stay live.
2. **Blank-as-zero.** Excel treats a blank as 0 in `+`/`−`; Sigma propagates null. So **additive
   canonicals wrap each ref in `Coalesce(ref, 0)`** — the sum computes live and matches Excel.
   Ratios/products stay strict (a null there is real).
3. **Per-year structural differences & the parity gate (the trust anchor).** Simulate the WHOLE
   model exactly as Sigma evaluates it (topological, null-propagating), compare to Excel's
   cached values, and **freeze the Excel value into the data page for any cell the live formula
   doesn't reproduce** (via the `Coalesce`, that cell shows the correct number). Result:
   **displayed parity = 100%** — every cell is either live-verified or cached-frozen; never a
   silent wrong number. A line whose one canonical is wrong in >25% of its years is flagged
   `NEEDS_REVIEW` (a genuine "this line's formula varies" signal), but still shows correct values.

## Build gotchas (verified live via the REST API)

- **`transpose` element takes NO explicit `name`** — Sigma auto-names it `Transpose of <source>`;
  its own columns must self-reference that auto name (`[Transpose of Calc/Year]`). Passthrough
  (non-merged) columns come through by their original name; the two new columns are named by
  `columnLabelForMergedColumns` / `columnLabelForValues`.
- A **data-model element can't be a `join`/`union` leg** — wrap it in a workbook `table` first
  (the line-dim → `Dim` wrapper).
- **No unary `+`** (`=+B8` → strip), **no `#,##0.0` format strings** (Sigma rejects; use its
  format objects or omit), **column names with `/` break refs** (use `c<row>` ids).
- **DM element formulas** = `[Custom SQL/<alias>]`; DM element `kind:"table"` + `source.kind:"sql"`.
- **FactSet cruft to strip** (log, don't silently drop): the `__FDSCACHE__` sheet, thousands of
  junk named ranges, `#REF!`/`#N/A`, external `[n]!` links. Don't trust cached values for
  broken-forecast years (they cache to `#REF!`) — rebuild from formula text.

## Verify

Export the `long` element to CSV and compare every `(c<row>, year)` to the Excel cached grid
(`data_only=True`) within €0.01 / 0.1%. Target: 0 wrong, 0 blank-where-Excel-has-a-value. Also
confirm the result is far smaller than a hand build (one column per line, not per-year triplets).
