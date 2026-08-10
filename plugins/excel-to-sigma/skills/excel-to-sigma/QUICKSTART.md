# Excel → Sigma — Quickstart

End-to-end on the bundled sample fixture. ~10 min; three of the steps are clicks.

## 0. Setup
```bash
cd <this skill>/scripts
python3 -m venv .venv && .venv/bin/pip install openpyxl python-dateutil
# Sigma creds in ~/.sigma-migration/env  (SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET)
```

## 1. Make (or bring) an Excel model
```bash
.venv/bin/python make-sample-forecast.py        # writes "Sample Forecast.xlsx" (540-row formal Table + dims + a SUMPRODUCT report)
```
Or point the next steps at a real `.xlsx`.

## 2. Discover
```bash
.venv/bin/python xlsx-discover.py "Sample Forecast.xlsx"
```
Lists formal Tables, their grain, pivots/charts, and a formula census. Confirm the
fact Table + grain with the user.

## 3. Extract the paste-ready seed
```bash
.venv/bin/python xlsx-to-input-csv.py "Sample Forecast.xlsx" --table tblForecast --out forecast_input_paste.csv
```
Entry columns only, UPPER_SNAKE_CASE headers, dates as ISO. (System columns are
excluded — Sigma auto-populates them.)

## 4. Build the input-table structure  (API)
```bash
.venv/bin/python build-input-table-wb.py --name "Forecast Entry" --connection cb2f5180-… \
  --columns REGION:text,BRANCH:text,SUB_BRANCH:text,MONTH_DATE:datetime,CATEGORY_CODE:number,FORECAST_AMOUNT:number
```
> Builds the empty input-table **structure** (API). Loading the rows is a UI step
> (CSV paste) until the bulk-seed API lands. **Don't use `--linked` for a shippable
> table** — linked context columns don't resolve via POST ("multiple values");
> build linked input tables in the UI. See `refs/input-tables.md`.

## 5. Load data + view  (UI — see refs/input-tables.md)
1. Open the workbook → the input table → **paste** `forecast_input_paste.csv`.
2. **Publish** (data commits to the warehouse only on publish).
3. Input-table element → **Warehouse views → Create new** → copy the
   `database.schema.view` path.

## 6. Build the DM on the view  (API)
```bash
.venv/bin/python build-dm-on-view.py --view SIGMA_WRITE_DB.SIGMA_WRITE.FORECAST_ENTRY \
  --connection cb2f5180-… --categories-from "Sample Forecast.xlsx"
# prints the dataModelId
```

## 7. Verify parity
Query the DM's report element grouped by Statement Section (Sigma MCP) and compare
to the targets the discover step computed. The fixture's targets:
Revenue **10,902,533** · Contract Costs **−5,603,043** · Admin **−2,221,185** ·
Allocation **−415,557** · Net Contribution **2,662,748**.

> Validated run (2026-06-08): exact parity on all sections. workbook
> `cb6c53ef-…`, view `SIGMA_WRITE_DB.SIGMA_WRITE.FORECAST_ENTRY`, DM `04e462d8-…`.

---

# Worked example B — actuals + driver-grown + manual P&L (one-shot builder)

For a "report drawn in cells" planning model (live actuals + assumption-driven
forecast + manual cells) — the FP&A case. `xlsx-discover.py` now prints a
**cell-level model map** (ACTUAL / DRIVER_GROWTH / MANUAL / FLAT / DERIVED); after
confirming intent (read-only / editable / what-if — see `refs/model-taxonomy.md`),
drive the whole build from a **model-plan JSON**:

```bash
# dry run: local parity + emits dm_spec.json / wb_spec.json / seed CSVs to /tmp/fcst-build
.venv/bin/python build-forecast-model.py sample-model-plan.json
# build live (DM + workbook with union[actuals,forecast], KPIs, Actual|Forecast pivot, trend, editable rate+manual tables)
.venv/bin/python build-forecast-model.py --post sample-model-plan.json
```

The forecast is computed (`base × (1+rate)^n`); editable rate/manual input tables
override via `Coalesce(input, default)`, so **parity holds before any seeding**
(verified: Revenue 6,961,218.48 · EBITDA 62,327.16 · **Net Income −135,372.84**).
Then: paste `rate_seed.csv` / `manual_seed.csv` into the two editable tables +
Publish to make them live; run `wb-rep push` for the designed layout (the POST
lands auto-arranged). See `refs/forecast-recipes.md`.

If `.xlsm`: run `macro-classify.py` first (`refs/macro-handling.md`) — surface
FLAG/ACTION macros before building.

> Note: delete a test workbook/DM via `DELETE /v2/files/{inodeId}` (not
> `/v2/workbooks/{id}`, which 404s).

---

## Worked example C — equity-research model (broker / FactSet house template)

For a sell-side research model (line-items × YEARS, statement sections; e.g. a FactSet-style broker model). Generate the synthetic fixture, then convert it:

```bash
# fake, no-customer-data fixture (Acme Widgets NV): plug-cycle + %-literal + Lag + #REF! + MIXED
.venv/bin/python make-sample-research-model.py                       # -> scripts/Sample Research Model.xlsx

# infer the two-layer plan (hard-coded grid + ONE canonical formula per derived line)
.venv/bin/python infer-canonical-formulas.py "Sample Research Model.xlsx" \
    --sheet="FY results" --first-row=7 --last-row=45 --out plan.json

# build DM (data page) + workbook (computation + transpose + display pivot)
.venv/bin/python build-research-model.py plan.json --conn <writeConn> --folder <id> --post
```

The report shows `input / derived / ratio` counts, live-verified vs frozen formula
cells, and resolved anchors. Verified end-to-end: the synthetic fixture round-trips
to **100% cell parity**, and a real broker equity-research model rebuilt to **100.00% parity
(3,263/3,263 cells), ~81% live Sigma formulas** — far simpler than a hand build (one
column per line, not per-year `User`/`Calc`/`(1)` triplets). See `refs/research-recipes.md`.

**A fleet of similar files** (the ~850-file case) → `batch-convert.py` fingerprints,
maps to the chart-of-accounts (`coa.json`), converts, parity-gates, and emits a triage
manifest (AUTO_PARITY / NEEDS_REVIEW / FAILED) + the top unmapped labels to grow the COA:

```bash
.venv/bin/python batch-convert.py /path/to/models/ --sheet="FY results" --out manifest.json
```
See `refs/research-template-coa.md`.
