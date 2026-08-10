---
name: excel-to-sigma
description: >-
  Convert an Excel (.xlsx) workbook — especially a planning / budget / forecast
  data-entry model — into a Sigma data model + workbook. Use when the user has
  an Excel file (formal Tables, pivots, charts, or a cell-formula budget model)
  and wants to recreate it in Sigma. Covers formal-Table discovery, Excel-formula
  translation, and the input-table → warehouse-view → data-model pattern that
  preserves data entry. Requires a Sigma SIGMA_API_TOKEN and (for the data-entry
  half) a write-enabled Sigma connection.
user-invocable: true
---

# Excel → Sigma Conversion

> Phase numbering is local to this skill; the canonical Assess→Discover→Reuse→
> Convert→Post-DM→Build→Layout→Parity→Security→Enhance arc and this skill's
> mapping live in `docs/phase-schema.md` (full clone only).

> **STATUS: input-table data-entry path VALIDATED end-to-end (2026-06-08).** The
> full chain — Excel formal Table → Sigma input table → warehouse view → data
> model reading `FROM` that view → section rollups — was proven with **exact
> parity** on a representative 540-row forecast model. The read/output half (DM +
> workbook from a landed seed) was validated earlier (2026-06-03). The discovery
> + formula-translation layer is designed and spiked, not yet a one-shot
> converter — see `refs/excel-translation.md`. Graduated from
> `twells89/excel-to-sigma` into this marketplace; workbook POSTs use the
> released `code_rep` document wrapper (same as every sibling converter).

<!-- mandatory-pre-read -->
**Read before acting (load more refs only when the phase needs them):**
- `refs/input-tables.md` — validated input-table workflow + API-vs-UI split (source-swap goes through a warehouse view, not a direct DM source binding).
- `refs/excel-translation.md` — translation surface, formal-Table MVP rule, grain selection.
- `refs/sigma-build-gotchas.md` — DM/workbook wire rules incl. released document wrapper.
<!-- /mandatory-pre-read -->

Phase-scoped (load on demand): `refs/macro-handling.md` (`.xlsm`),
`refs/model-taxonomy.md` + `refs/forecast-recipes.md` (cell-drawn planning),
`refs/research-recipes.md` + `refs/research-template-coa.md` (equity-research fleets).
Companion authoring: `sigma-workbooks` (in `sigma-authoring`) + the Sigma OpenAPI.

---

## The one big idea

Excel planning models are **data-entry tools**, not dashboards. Forecasters type
numbers into budget sheets; formulas roll them into an income statement. The
faithful Sigma translation keeps that data entry alive — which is exactly what
**input tables** are for.

The decisive structural insight (validated): in well-structured enterprise
workbooks, the value lives in **formal Excel Tables** at a tidy grain. Most of the
thousands of `INDEX/MATCH/SUMIFS` formulas are **wide→long reshaping**, not
business logic — they *evaporate* when the data lands at that grain in a Sigma DM.
What's left ("report" sheets drawn in cells) is rebuilt by hand, same as any
migration.

So the migration is two halves:

1. **Read / output half** — the formal Table(s) become DM elements; the income-
   statement SUMIFS become grouped DM metrics + workbook charts. (Build against a
   seed first; see `refs/excel-translation.md`.)
2. **Data-entry half** — the formal Table that forecasters edit becomes a Sigma
   **input table**; the DM re-points to read from it. (See `refs/input-tables.md`.)

---

## Preserve the inputs — never ship a read-only port

**A spreadsheet is an app people type into. If the conversion is read-only, you've
demoted it.** Don't default every table to a read-only DM element. Classify each
source table by *how it's used* and route accordingly:

| Source table is… | → Sigma | Editable? |
|---|---|---|
| **Entered** (users type values: budget inputs, a tracker, subscriptions) | **input table** (empty / CSV / linked) | ✅ like Excel/Sheets |
| **Derived** (formula rollups: the income statement, SUMIFS summaries) | read-only DM element + metrics | ❌ recomputes |
| **Reference dim** (lookup lists users maintain) | input table if maintained, else read-only | depends |

A Phase-0 heuristic: a formal Table that's *fed by* formulas/other sheets and only
*read* downstream = **derived**; a Table whose cells are typed values with no
inbound formula = **entered**. Route entered → input-table builder, derived →
read-only DM/metric builder. When unsure, ask the user how they use that sheet.

### What's actually buildable via API today (validated 2026-06-10 by MCP query)

> **Hard-won correction.** Earlier drafts claimed linked input tables were the
> "powerful path, fully API, no seed." **That was wrong — validated only by
> structure (`/elements`), never by querying the data.** A linked input table
> authored via `POST /v2/workbooks/spec` has **inherited columns that don't
> resolve** — every row shows **"multiple values"** (publish doesn't fix it;
> re-POSTing a known-good UI-built spec reproduces the break). The linked-column
> key-correlation is UI-only state the spec can't carry. See
> `refs/input-tables.md`.

So, honestly, by usage pattern:

| Need | API today? | How |
|---|---|---|
| **Edit-in-place of the migrated rows** (the common spreadsheet case) | ❌ | empty/CSV input table **structure** is API; loading the rows = UI CSV paste now, the **bulk-seed API** later |
| **Net-new entry at a grain** (blank forecast grid) | ⚠️ partial | a linked-off-spine table's PK/grain + entry columns populate via POST, but the **dimension context columns show "multiple values"** → UX is poor; build in UI for now |
| **Augment / annotate existing rows** (notes/flags beside live data) | ❌ via API | needs working linked columns → **UI-authored** |

**Bottom line today:** via API you can scaffold input-table *structure* and build
read-only DMs; making input tables actually *show the migrated data editable*
needs the UI (CSV paste / UI-built linked tables) until the bulk-seed API lands.
Don't promise "editable via API" — scaffold the structure, then hand off the
data-load/link step as a UI action (or wait for the seed API).

Design so the editable surfaces exist from day one; the seed API just fills the
"edit-in-place" case later. **Don't build a read-only model and call it a
migration.**

---

## Prerequisites

### Sigma access
```bash
# neutral cred file written by the sigma-migration setup (see refs/input-tables.md)
bash -c 'source ~/.sigma-migration/env; TOKEN=$(curl -s -X POST "$SIGMA_BASE_URL/v2/auth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=$SIGMA_CLIENT_ID&client_secret=$SIGMA_CLIENT_SECRET" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[\"access_token\"])"); <cmd>'
```
The **data-entry half requires a write-enabled connection** (input tables write
back to a `SIGDS_` schema). Confirm via `GET /v2/connections` → `writeAccess: true`.
Verified write connection on tj-wells-1989: `cb2f5180-…` (Snowflake ymb68310).

### Python
`scripts/` use `openpyxl` (+ `python-dateutil` for the fixture generator). Install
into a venv: `python3 -m venv .venv && .venv/bin/pip install openpyxl python-dateutil`.

### Optional: `snow` CLI
Used only to look up the **full path** of a Sigma-created warehouse view
(`SIGMA_WRITE_DB.<schema>.<view>`) when the UI truncates it. SSO browser-auth;
`snow sql -c default --format json -q "SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME FROM <DB>.INFORMATION_SCHEMA.VIEWS WHERE TABLE_NAME ILIKE '<view>%'"`.

---

## Phase 0 — Discover the workbook (`scripts/xlsx-discover.py`)

Walk the `.xlsx` (OOXML = a ZIP of XML; `openpyxl` reads it). Produce an inventory:

- **Formal Tables** (`xl/tables/*.xml`) — name, sheet, range, columns. These are
  the migration's Rosetta Stone: each is a DM-element / input-table candidate.
- **Pivots, charts, slicers** — count + anchor; map to `pivot-table` / chart /
  control later.
- **Formula census** — tally functions; flag the untranslatable (`OFFSET`,
  `INDIRECT`, volatile locators) and the "report drawn in cells" sheets.
- **Degenerate-column warnings** — constant / decayed columns (broken fiscal
  defaults, stale lookup spines). **Derive these, don't port them.**

State the inventory back to the user and confirm the **canonical grain** of the
fact Table before building.

### Phase 0b — Macro inventory & disposition gate (if `.xlsm`/`.xlsb`/`.xls`)

If the file is macro-enabled, run the macro pass **before building** — a dropped
macro is a silent loss of behavior (see `refs/macro-handling.md`):

```bash
python scripts/macro-classify.py <file.xlsm>          # report
python scripts/macro-classify.py --json <file.xlsm>   # contract for build steps
```

Each procedure is classified (olevba-extracted VBA) and routed: **AUTO** (covered
by the data/formula conversion or safely dropped), **CONTROL** (controls / editable
assumptions table), **ACTION** (Sigma Action — *gated on the Actions primitive*;
scaffold a placeholder + inventory entry now), or **FLAG** (external I/O / opaque —
human review). **Surface the FLAG and ACTION items to the user and get
acknowledgement before build.** Never silently omit a macro.

### Phase 0c — Model map & intent (for "report drawn in cells" / planning models)

When there are **no formal Tables** (a cell-drawn P&L/budget/forecast), don't punt
to "manual rebuild." `xlsx-discover.py` now prints a **cell-level model map**:
classifies each formula/value as **ACTUAL** (SUMIFS over a data tab → live DM),
**DRIVER_GROWTH** (`prior×(1±rate)` → closed-form `base×(1+rate)^n`), **MANUAL**
(literal among formulas → editable input table), **FLAT** (`=prior` → carry), or
**DERIVED** (totals/margins → workbook calc), and names the actuals-source +
drivers sheets.

That map *is* the architecture: **union [live ACTUAL] + [forecast]**. Before
building, **present the map and ask the 3 intent questions** (read-only report /
editable plan / live what-if; which inputs editable; actuals live or snapshot) —
see `refs/model-taxonomy.md`. Then build per `refs/forecast-recipes.md` and
**assert parity to the cent** against the sheet's cached totals (the trust gate).

### Phase 0d — Template-family fingerprint & routing (financial-statement models)

Before choosing a build path, **fingerprint the file** (see `refs/research-template-coa.md`):
a **broker/FactSet equity-research model** (line-items down rows, YEARS across columns, sections
like PROFIT AND LOSS / PER SHARE DATA / BALANCE SHEET; often `__FDSCACHE__` + thousands of named
ranges) routes to the **research archetype**, NOT the FP&A forecast path:

```bash
python scripts/infer-canonical-formulas.py <file.xlsx> --sheet="FY results" \
       --first-row=7 --last-row=<end> --out plan.json     # per-file inference + parity gate
python scripts/build-research-model.py plan.json --conn <writeConn> --folder <id> [--post]
```

`infer-canonical-formulas.py` extracts the hard-coded grid + one canonical formula per derived
line, breaks plug-cycles, and simulates-and-freezes to guarantee **displayed parity = 100%**.
`build-research-model.py` posts the DM (data page) + workbook (computation + transpose + pivot).

**For a fleet of similar files off one template** (the ~850-file case), use
`scripts/batch-convert.py` — it fingerprints, maps each file's line items to a canonical
chart-of-accounts (`refs/research-template-coa.md` + `coa.json`), converts, parity-gates, and
emits a **triage manifest** (AUTO_PARITY / NEEDS_REVIEW / FAILED) with no silent truncation.
Read `refs/research-template-coa.md` first. Everything else (a cell-drawn P&L with a data tab,
SUMIFS actuals, driver growth) stays on the FP&A path below.

## Phase 1 — Pick the grain & extract the seed (`scripts/xlsx-to-input-csv.py`)

For the fact Table, emit a **paste-ready CSV** with:
- **only the data-entry columns**, headers in `UPPER_SNAKE_CASE` matching the
  Sigma input-table column names exactly (so a clipboard paste aligns 1:1),
- **no system columns** — `Row ID` / `Created at|by` / `Last updated at|by`
  auto-populate in Sigma; including them breaks the paste.

Parse Excel date serials → ISO dates here.

## Phase 2 — Build the read/output DM (against a seed) + reuse-check

Before POSTing a new DM, check whether an existing Sigma data model already
covers the same grain (same formal-Table columns / warehouse view). Prefer
reusing / extending that DM over spawning another copy — same intent as
`find-or-pick-dm.rb` in the other converters. When no match, land the seed
(inline `VALUES` custom-SQL for ≤~1k rows; PUT-to-stage + COPY INTO for larger)
and POST the DM (fact + dim elements + relationships + a flattened `*_REPORT`
join element for grouping).

**Post-DM readback (hard gate):** after `POST /v2/dataModels/spec`, GET the
live spec and map server-assigned element/column ids before any workbook build
(`build-forecast-model.py` / `build-research-model.py` already do this via
`map_dm*`). Never trust authored ids past the POST. Full build rules in
`refs/sigma-build-gotchas.md`.

## Phase 3 — Stand up the input table (`scripts/build-input-table-wb.py`)

Build the **empty input-table structure via API**; load/link the data via UI for
now (or the bulk-seed API later). See `refs/input-tables.md`.

**Empty input table (API for structure).** POST an **empty input-table element** at
the fact grain (`source: { kind: empty, connectionId: <write-conn> }`,
`inputMode: explore`, data columns + system columns
`ID/CREATED_AT/CREATED_BY/UPDATED_AT/UPDATED_BY`). Then UI: open the input table →
**paste / upload** the Phase-1 CSV → **Publish** → **Warehouse views → Create
new**. (The CSV paste is the current bridge for the bulk-seed API.)

> **Do NOT auto-build linked input tables via the spec.** It looks like it works
> (the POST succeeds, `/elements` shows the columns) but the **inherited columns
> resolve to "multiple values"** — the linked correlation is UI-only (validated
> 2026-06-10, publish doesn't fix it). `build-input-table-wb.py --linked` only
> scaffolds the PK/grain + entry columns; the *linked context columns must be
> added in the UI*. If a usage pattern needs live context columns beside editable
> cells, build that table in the UI.

## Phase 4 — Source-swap the DM onto the view (`scripts/build-dm-on-view.py`)

Re-point (or build) the DM's fact element to `SELECT … FROM <warehouse view>` on
the write connection. Display names stay identical, so the workbook + metrics are
unchanged. This is **API**. Verify the section rollups hit the same parity targets
as Phase 2.

## Phase 5 — Build / repoint the workbook, layout last, parity

Build the dashboard pages (Forecast Summary pivot + KPIs, trend charts) per
`sigma-workbooks`, sourced from the DM. Builders author a nested
`pages[].elements` draft; **`scripts/lib/workbook_wire.py` assembles layout XML
as the last write**, then wraps via `code_rep` into the released
`{ name, folderId, document: { schemaVersion, kind, pages, elements, layout } }`
body before `POST /v2/workbooks/spec`. Do **not** POST a flat pre-document
workbook body (live API 400s). Data-model specs stay unwrapped.

Confirm every element compiles and the totals tie out (parity hard gate —
Phase 0c/0d simulate-and-freeze, Phase 2/4 section rollups, research
`batch-convert.py` AUTO_PARITY bucket). Never skip the parity comparison.

### Security: RLS / CLS

Excel workbooks have no native row-/column-level security construct to port —
access control is file-share / workbook-protection only. Detect workbook
password protection / sheet protection during Phase 0 and note it for the
customer; do not invent Sigma RLS from spreadsheet structure. If the landed
warehouse tables already carry RLS policies outside Excel, leave those to the
warehouse / Sigma admin — this skill does not apply RLS automatically.

---

## Scriptability matrix (verified vs. live OpenAPI + connections; input-table re-verified 2026-06-10)

| Step | Path |
|---|---|
| input-table **structure** (columns/types; title `name`, `tableStyle`, `sort` round-trip) | ✅ API (workbook spec) |
| **linked** input table (inherited columns resolve) | ❌ UI only — spec POST yields "multiple values" (publish doesn't fix); PK/grain + entry cols populate but linked cols don't |
| seed **data** load into an empty/CSV table (CSV upload / paste) | ⚠️ UI now — no REST endpoint; bulk-seed API in progress |
| **Publish** (commits writeback) | ⚠️ UI |
| **warehouse view** on the input table | ⚠️ UI only |
| DM **source-swap** to `FROM <view>` | ✅ API (DM spec PUT/POST) |
| read/output DM + workbook build | ✅ API |
| data validation / column protection / data-entry permission | ⚠️ UI (linked dimension columns are auto-locked) |

With **linked mode** the only mandatory UI steps are **Publish** and **Create
warehouse view** — everything else, including the grain, is scripted. Bake those
two into the run as explicit "do this, then tell me the view path" hand-offs.

---

## What this skill does NOT do (yet)

- One-shot `.xlsx` → finished migration. Phase 0–1 (discovery + formula
  translation) is spiked, not a hardened converter. The data-entry path (Phase
  3–4) is fully validated.
- Power Query / ODBC / SharePoint-Online sources — MVP assumes inline data +
  Snowflake landing (the other source paths are additive; see
  `refs/excel-translation.md`).
- `.xlsm` / VBA / macros — **detected + classified + routed** (Phase 0b,
  `scripts/macro-classify.py` + `refs/macro-handling.md`); never *executed*.
  Write-back macros (`ACTION`) are gated on the forthcoming Sigma Actions
  primitive — scaffolded as placeholders + inventory until it ships.

See `refs/excel-translation.md` for the full converter-build design and the
~60–70% pipeline reuse from `tableau-to-sigma`.
