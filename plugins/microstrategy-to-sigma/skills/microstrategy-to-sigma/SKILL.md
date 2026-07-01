---
name: microstrategy-to-sigma
description: >-
  Migrate MicroStrategy (Strategy One) content to Sigma. Use when the user has
  MicroStrategy dossiers, reports, or a classic schema (attributes / facts /
  metrics) and wants to recreate them in Sigma. Extracts the dossier + full
  semantic model over the MSTR REST API into a bundle, converts it to a Sigma
  data model + workbook, reproduces Analytical-Engine row-collapse quirks
  deterministically, and verifies row-level parity. Live-validated with exact
  parity on the classic-schema grid path.
user-invocable: true
---

# MicroStrategy → Sigma migration

> **Windows / first run — run the environment doctor before anything else:**
> `bash scripts/doctor.sh` (macOS/Linux/Git Bash) or `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1` (Windows).
> It checks Ruby/Python/Node/bash and flags the Python "Store stub" + CRLF with exact fixes. Details: `refs/environment.md`.

## Preflight the workbook spec before POST (mandatory)

Before POSTing any workbook spec, run `ruby scripts/lib/preflight_lint.rb <spec.json>` — it exits 1 with a precise message on the two migration-killer bugs: a `table` with aggregate columns + dimensions but **no `groupings`** (renders raw detail rows), and a malformed `control` (missing `id`/`controlId`/`controlType` or nesting value fields under a `value` object instead of flat, a non-double-nested `source`, or a list control wired to neither `source` nor `filters` — a filters-only list control is valid). Fix every violation first — never POST past it, and **never conclude a feature is "unsupported" from an `Invalid kind` error** (it means the inner fields are wrong). Verified shapes: `sigma-workbooks` `controls.md` / `tables.md`.

## Converter architecture (read if you know the other migration skills)

Unlike the **Group-A** converters (tableau, powerbi, qlik, quicksight, looker,
thoughtspot, cognos) — which share the vendored `sigma-data-model-mcp` engine
(`converter/*.mjs`, with the hosted `convert_*` MCP tool as a fallback) — this
skill uses a **self-contained Python converter that ships in `scripts/`**
(`convert.py`). It runs locally via `python3`; there is **no vendored `.mjs`
bundle, no `convert_microstrategy_to_sigma` MCP tool, and no `--converter` /
`*_MCP_DIR` override** — those concepts do not apply here. Nothing about the model
conversion leaves your machine.

## Phase 0a — Choose where to build (ask first; `--folder-id` is required downstream)

Don't pick the destination folder for the user. `convert.py` requires `--folder-id`,
so resolve it WITH the user before building:

1. `python3 scripts/pick_destination.py list` → `{ workspaces, folders (editable, with parentName), myDocuments }`
2. Let the user pick ONE: a **workspace** (its `id` lands content in the workspace root),
   an existing **folder**, **My Documents** (when non-null — null for service tokens), or
   **create a new folder**: `python3 scripts/pick_destination.py create --name "<name>" [--parent <workspace-or-folder-id>]`
3. Pass the chosen id as `--folder-id <id>`. `folderId` accepts a workspace id or a folder id.

If the user already named a destination, honor it silently — don't ask.

Extract a MicroStrategy **dossier + its full semantic model** into one
`bundle.json`, convert it to a Sigma **data model** (table sources + joins +
metrics) and a matching **workbook**, then **verify row-level parity** against
the numbers MicroStrategy itself reports. Translate what maps cleanly; **flag
what doesn't** (unmapped viz types → flagged tables) instead of emitting wrong
logic.

> **Validated**: exact parity (19/19 + 30/30 + 3/3 rows) on a live Strategy One
> trial against Snowflake — classic-schema path, grid reports, incl. a
> `Count<Distinct=True>` metric, a compound margin metric, and an
> Analytical-Engine row-collapse report. Chart-viz emission and the newer
> "Data Model" object are roadmap (`refs/design-notes.md`).

> Read `refs/` before relying on shapes: `mstr-rest-api.md` (every verified
> REST gotcha — changesets, locks, lowercase response headers, session-bound
> dossier flows), `ae-row-collapse.md` (the one MSTR behavior no clean SQL
> reproduces, and the pinning workflow), `viz-type-mapping.md` (dossier viz →
> Sigma element lookup), `design-notes.md` (architecture + modeling gotchas +
> roadmap), `control-parity.md` (shared control-targeting contract: the
> control lint, the control-scope.json sidecar, and the flip test). For
> canonical Sigma spec shapes, defer to the companion `sigma-data-models` /
> `sigma-workbooks` skills.

---

## Prerequisites

- **MicroStrategy REST access** — `MSTR_BASE_URL` (the Library root, e.g.
  `https://<host>/MicroStrategyLibrary`), `MSTR_USERNAME`, `MSTR_PASSWORD`
  (+ optional `MSTR_PROJECT_ID`), exported or in `~/.sigma-migration/env`.
  Auth is session-based (`POST /api/auth/login`, loginMode 1) — there is no
  API-key concept; `scripts/mstr.py` handles it.
- **Sigma API token** — `eval "$(scripts/get-token.sh)"` (uses
  `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`, same neutral-cred pattern as the
  sibling skills). If those Sigma creds aren't set yet (fresh machine, no prior
  migration), run `ruby scripts/setup.rb` once — it prompts for the Sigma
  base URL / client id / secret (+ optional connection id) and writes them to
  both `~/.claude/settings.json` and `~/.sigma-migration/env`, so `get-token.sh`
  and every sibling skill pick them up. (Source-side MSTR creds are separate —
  see the MicroStrategy bullet above.)
- **The same warehouse on both sides.** Sigma reads the warehouse live; parity
  only means something when the Sigma connection reaches the database
  MicroStrategy queries.
- **Python 3** (stdlib only; `resolve_ae_winners.py` and parity readback also
  want `PyYAML` for Sigma's YAML spec responses) and **Ruby** (the shared
  gate stack: `put-layout.rb`, `assert-phase6-ran.rb`, `probe-controls.rb`,
  `scripts/lib/*.rb` — vendored byte-identical across the sibling plugins).

## Phase 0b — Discover

Run the sibling **`microstrategy-assessment`** skill for an estate-wide
inventory (reports/dossiers, viz histogram, complexity tags) — its
`inventory.json` lists dossier ids. Or quick-check connectivity and pick a
dossier by hand:

```bash
python3 scripts/mstr.py                          # login probe + project list
# dossiers: see assessment, or GET /api/searches/results?type=55 via mstr.py
```

### Phase 0.5 — Source type: classic schema vs Quick Cube (branch here)

Check what backs the dossier's dataset before extracting. `GET /objects/{datasetId}?type=3` →
`subtype`:

- **Classic schema / Mosaic Data Model** (live warehouse-backed) → the normal path. Continue to Phase 1; `extract.py` reads the semantic model.
- **Quick Cube / super-cube** (`subtype 779`, or a dataset whose source is a file import — `Row Count - <name>.xlsx` metric, no live warehouse connection) → **there is no warehouse semantic model to convert.** The model lives inside the in-memory cube. This is a **data rehost + rebuild**, not a semantic auto-conversion — set expectations accordingly and don't claim `convert.py` drove it.

  **Decide first (ask the customer):** if the cube has a real upstream system of record, prefer pointing Sigma at that live warehouse source. **Rehosting the cube copies a point-in-time snapshot** into the customer's warehouse — it does not stay fresh unless something re-feeds it. Only rehost when there's no live source (demo/prototype cubes, locked-down trials, managed metrics without formulas).

  **If rehosting**, the cube's *data* still extracts cleanly even though its model doesn't:
  1. Pull all rows via the cube instance API — `POST /v2/cubes/{id}/instances?offset&limit` for page 1 (returns `instanceId` + `definition.grid` + `data`), then `GET /v2/cubes/{id}/instances/{iid}?offset` to page. Element lists in each response are page-scoped. Flatten attributes-on-rows + metrics-on-columns into one table.
  2. `COPY` it into the warehouse the Sigma connection reaches (quote identifiers to preserve display names; `DATE_FORMAT`/`FIELD_OPTIONALLY_ENCLOSED_BY` for messy CSV; `GRANT SELECT` to the connection role + schema sync — see `sigma-data-models`).
  3. **Rejoin the normal flow at Phase 3** with a `warehouse-table` source. Skip Phase 1/2 (no bundle to extract) — build the DM + workbook directly, and lean hard on Phase 1.1's source-PDF capture + execute-instance value truth (a cube's KPIs are often a latest-period stat, and a chapter date filter drives the row subsets).
  4. **Emit REAL charts, not labeled-table stubs.** The `convert.py` classic path currently falls back to flagged tables for chart vizzes (roadmap) — **do NOT carry that fallback into a path-B hand build.** Map each `visualizationType` (`refs/viz-type-mapping.md`) to its Sigma element via the `sigma-workbooks` skill: `kpi`→`kpi-chart`, `bar_chart`→`bar-chart`, `combo_chart`→`combo-chart`, `grid`→`table`/`pivot-table`, `microcharts`→`pivot-table` with `conditionalFormats`/data bars. These all build via the workbook spec (proven live on Retail Insights — kpi/bar/combo/pivot). A table is the fallback ONLY for a genuinely unmappable type, and you say so.
  5. **Gates:** `assert-phase6-ran.rb` is wired for the classic path — in path B it does not apply, but you still MUST run the **parity gate** and the **source-fidelity Visual QA gate** (compare the render to `source_dossier.pdf`, every page). Don't declare done on HTTP 200.

  > **Known ceiling — be honest in the writeup:** a cube's *derived* metrics (e.g. an "Inventory Performance" ratio, or non-additive aggregations) carry their formula only inside the cube — they do NOT reduce from the rehosted base columns. Recover exact definitions via Workstation export / ODBC, or approximate and **label the approximation**. Never silently ship a guessed metric as exact.

## Phase 1 — Extract the bundle

```bash
python3 scripts/extract.py <dossierId> bundle.json
```

Walks dossier definition → dataset reports (`showExpressionAs=tokens`) →
referenced attributes / metrics (compound bases included via a second pass) /
facts / logical tables / hierarchy relationships. The bundle is the converter
contract — `fixtures/bundle.json` is a real, validated example.

### Phase 1.1 — Capture the SOURCE visual + the values it actually shows (mandatory)

The bundle gives you the data model and *which* vizzes exist; it does **not**
tell you what the dossier *looks like* or what each viz actually *displays*.
Both are required for a faithful migration — skip this and you will rebuild the
right numbers in the wrong dashboard (and sometimes the wrong numbers). Two
captures:

```bash
# (a) Pixel-faithful PDF of the live dossier — the layout/branding/arrangement reference.
python3 scripts/export-dossier-pdf.py <dossierId> source_dossier.pdf
```

**READ `source_dossier.pdf`** before composing anything. Note, per page: the
element arrangement (columns/rows, what sits next to what), each viz's real
chart KIND (a "microcharts" or "kpi" type is not a bar table), branding/header
bands, and any controls/selector panels.

```bash
# (b) Execute the dossier instance and pull each visualization's grid + DISPLAYED values.
#     The static definition's panelStacks carry NO grid metrics — you must execute:
#       POST /dossiers/{id}/instances            (v1; v2 404s) -> mid
#       GET  /v2/dossiers/{id}/instances/{mid}/chapters/{chapKey}/visualizations/{vizKey}
#     Per-viz response gives definition.grid (rows/columns/metrics) + data.metricValues.
```

> **A page's top-level `visualizations[]` is ALWAYS empty in the static
> definition — the real vizzes live in `panelStacks[].panels[].visualizations[]`
> (each carries `key`, `name`, `visualizationType`). NEVER conclude a page "has
> no visualizations" and emit a stub/placeholder from the empty page-level list
> — that is a bug, not an empty page. Walk panelStacks recursively (see
> `convert.py:_walk_viz_keys`), then execute each `key` for its grid+values. A
> page that looks empty means you read the wrong field.** (This is the
> single most common way a migrated page comes out blank.)

Capture each viz's **actual displayed values** as the parity baseline. Two
traps this surfaces that the bundle hides:

- **KPI / stat cards are frequently a *latest-period* value, not a windowed
  aggregate.** A "Total Sales" KPI may show the most recent day's value with a
  prior-period delta + sparkline — NOT `Sum` over the filter window. Match the
  number the card shows; don't assume the aggregation.
- **Chapter-level filters drive every viz.** A chapter filter (e.g. `Date
  Between …`) found via `…/instances/{mid}/definition` → `chapters[].filters`
  (NOT in the static `/definition`) is the reason row counts and totals look
  "filtered." Apply the equivalent as a page/base filter so all elements inherit
  it (a hidden base table with the filter, sourced by every element, is the
  cleanest propagation).

Sparklines and KPI comparison/delta badges are **UI-only in the Sigma spec API**
(see `sigma-workbooks` `kpis.md`) — reproduce the big-number value via formula,
and flag the sparkline/badge as a one-click editor follow-up rather than
claiming spec parity.

## Phase 2 — Convert → Sigma specs

```bash
python3 scripts/convert.py --bundle bundle.json \
  --connection-id <SIGMA_CONNECTION_ID> --database <DB> --folder-id <FOLDER_ID> \
  [--inode-map inodes.json]        # physical table name -> inode tail, optional
```

Emits `sigma_dm_spec.json` (one table element per logical table, derived
left-outer joins, a consumable join element, token-parsed metrics with derived
display formats) + `sigma_workbook_spec.json` (one page per dossier chapter,
grouped tables mirroring each report template, **controls** from the dossier's
filter signals, banded-layout container elements) + `parity_keys.json` +
`layout.xml` + `control-scope.json`. The workbook spec carries
`{{DATA_MODEL_ID}}` / element-id placeholders until Phase 4 re-runs with real
ids.

**Controls** (`refs/control-parity.md` is the contract): MSTR dossiers DECLARE
selector targets (`selectors[].targets` = viz keys) — the strongest
source-scope signal of any BI tool — so each selector becomes a Sigma control
whose `filters` wire to exactly the table elements built from the declared
vizzes; chapter filter panels cover every element on their chapter's page.
Verified shapes baked in: filter targets only on TABLE elements; controls
AFTER their targets in spec order; date attributes → `date-range` with flat
`mode: between` (list-on-datetime targets are silently stripped); **numeric
attributes bind through a hidden `Text()` cast column** (a list-control filter
target on a NUMERIC column also posts 200 and reads back `filters: null` —
live-verified 2026-06-12). Panel selectors are navigation, not filters —
flagged MANUAL in the sidecar, never silently dropped. `control-scope.json`
carries `sourceFilterSignals` + per-control declared scope/`mustReach` for
gate 7.

Conversion patterns to know (details in `refs/`): grids group by the
attribute's KEY form and label with `Max([DESC])`; dim-keyed groupings get an
`exclude [null]` filter to mirror MSTR's inner joins; metrics referencing
metrics are inlined in workbook context, `[Name]`-referenced in DM context.

## Phase 2.5 — AE row-collapse resolution (only when flagged)

If any report has an attribute whose DESC form differs from its key (the
converter's grouping output makes this visible — and `resolve_ae_winners.py`
detects it itself), MicroStrategy's Analytical Engine collapses non-unique key
groups to one representative row that **cannot be derived from the model**:

```bash
eval "$(scripts/get-token.sh)"
python3 scripts/resolve_ae_winners.py --connection-id <id> --database <DB> \
  --folder-id <folderId> --out ae_winners.json
python3 scripts/convert.py ... --ae-winners ae_winners.json
```

It re-executes the affected reports in MSTR, computes the clean warehouse
groups via a throwaway Sigma probe workbook, pins each winner empirically, and
the converter emits a deterministic SQL element reproducing the grid. Read
`refs/ae-row-collapse.md` — this is the single biggest parity trap.
(Fixture path: `fixtures/ae_winners.json` carries the winners pinned during
the live validation, so the bundled fixture runs end-to-end without a
Strategy One instance.)

## Phase 2.6 — Reuse an existing DM? (avoid sprawl — the reuse-first DM gate every converter runs before building)

Before POSTing a new data model, score the org's existing Sigma DMs against this
dossier's tables/columns and reuse on a strong match — don't create a 4th
near-identical model:

```bash
python3 scripts/mstr-dm-signature.py --dm-spec sigma_dm_spec.json --out dm-signature.json
eval "$(scripts/get-token.sh)"
ruby scripts/find-or-pick-dm.rb --workbook-signature dm-signature.json \
  --out dm-match.json [--auto-pick]
```

`mstr-dm-signature.py` derives `{warehouse_tables, referenced_columns, measures}`
from the Phase-2 `sigma_dm_spec.json`. `find-or-pick-dm.rb` scores each existing
DM (0.7·column + 0.2·table + 0.1·metric overlap):

- **Score ≥ 0.6** → **ASK the user** reuse-vs-new: surface the candidate name,
  matched cols (N/M), and the inherited-extras warning from `dm-match.json`. On
  reuse, **skip the Phase 3 POST** and point Phase 4's workbook at the reused
  `dataModelId`.
- **Below threshold** → build new (continue to Phase 3). Non-destructive; never
  auto-reuses without confirmation unless `--auto-pick` (with tie-window safety).

## Phase 3 — POST the data model + read back ids (hard gate)

```bash
eval "$(scripts/get-token.sh)"
curl -s -X POST "$SIGMA_BASE_URL/v2/dataModels/spec" \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" -H "Content-Type: application/json" \
  -d @sigma_dm_spec.json            # -> dataModelId
curl -s "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/spec" \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" > dm_readback.yaml
```

The readback is **YAML**, with **reassigned element ids** — capture them as
`dm_element_ids.json` (`{"<element name>": "<server id>"}`). **Gate:** scan the
readback for any column with `type: error` (a spec can POST 200 yet carry
formulas that don't resolve at query time). Do not proceed on errors —
`mcp__sigma-data-model__diagnose_sigma_save_error` and the
`sigma-data-models` skill are the debugging path.

## Phase 4 — Re-emit the workbook with real ids, POST it

```bash
python3 scripts/convert.py ... --data-model-id <dataModelId> \
  --dm-element-ids dm_element_ids.json [--ae-winners ae_winners.json]
curl -s -X POST "$SIGMA_BASE_URL/v2/workbooks/spec" \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" -H "Content-Type: application/json" \
  -d @sigma_workbook_spec.json      # -> workbookId
# MANDATORY run-each-time gap-scout gate (bead beads-sigma-5l5e): the converter
# passes metric function names through, so a function with no Sigma equivalent
# surfaces HERE as a type=error column. This script STOPS (exit 11) on any
# UNSCOUTED error column — spawn a gap-scout per the printed --gap-id (see
# scripts/gap-scout.md), re-run the gate, and only proceed when it exits 0.
python3 scripts/scout-gate-readback.py --workbook-id <workbookId> --workdir <out-dir>
ruby scripts/put-layout.rb --workbook <workbookId> --layout layout.xml
```

The layout PUT applies the banded layout (header band titled from the
chapter/dossier name, controls band, full-width tables) the converter emitted
— without it the workbook renders as Sigma's single-column stack and gates
4/6 fail. The `scout-gate-readback.py` step above is the **mechanical** version
of the old "confirm no `type: error` columns" check — do NOT skip it; a broken
metric must be scouted (translated or escalated) before the workbook ships, not
waved through. (Workbook DELETE, if you need to retry, is
`DELETE /v2/files/<id>` — not `/v2/workbooks/<id>`.)

## Phase 5 — Verify parity (hard gate — the real proof)

Expected values come **from MicroStrategy, never invented**: execute each
report via `POST /api/v2/reports/{id}/instances?limit=N` and write
`expected_parity.json` (`{"<report name>": [{"keys": [...], "values": {...}}]}`
— `fixtures/expected_parity.json` is the shape). Then:

```bash
python3 scripts/verify_parity.py --workbook-id <workbookId> \
  --expected expected_parity.json --report parity_report.md
```

Exports every workbook element to CSV via the Sigma export API and compares
row-by-row (money/counts exact; ratio metrics rel 1e-6). **GREEN only when
every report PASSes** — never on a 200 POST alone. Mind freshness: Sigma reads
the live warehouse; if rows landed since the MSTR numbers were captured,
re-capture before calling a delta a failure (reconcile the delta against the
post-snapshot rows — the fixture's shared demo tables drift daily).

It also writes the gate sentinels `parity-final.json` + `wb-ids.json` next to
the report — the contract Phase 6 reads.

## Visual QA (mandatory gate — never skip)
A workbook that POSTs 200 and passes row parity can still be **the wrong
dashboard** — right numbers, wrong look. This gate has TWO parts: source
**fidelity** (does it resemble the original?) and intrinsic **quality** (is it
cleanly laid out?). Both must pass. Sigma's grid has no z-order; the shared
layout lib de-overlaps bands, but this gate is the safety net (without a
top-level layout the workbook renders as a single-column stack).

1. Render every page to PNG (token first: `eval "$(scripts/get-token.sh)"`):
   `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600`
2. **Source-fidelity check — put the Sigma PNG side-by-side with the Phase 1.1
   `source_dossier.pdf`** and compare page-for-page against the
   `refs/layout-visual-qa.md` "Source-fidelity parity" checklist: same element
   set, same relative arrangement (3-column stays 3-column), matching chart
   KINDS (KPI vs bar vs table), KPI showing the same VALUE as the source card,
   selector/control panels present, branding bands present (or explicitly
   descoped with the user). A render that looks nothing like the PDF FAILS even
   if parity is green.
3. **Quality check** — also verify each PNG against the intrinsic checklist (no
   overlaps/stacking, no dead zones, controls in-band, no clipped titles, even
   heights, right format).
4. Fix any failure in the spec — for multi-page workbooks use `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) — then **re-render and re-compare**.
5. Declare the migration done on a render that **matches the source PDF**, not on HTTP 200 and not on row-parity alone. If the user explicitly scoped styling down (e.g. "layout + metrics, skip branding"), record exactly what was descoped — don't silently drop it.

## Phase 6 — Finalize (hard gate before declaring GREEN)

```bash
ruby scripts/assert-phase6-ran.rb --workdir <dir> --workbook-id <workbookId>
```

Seven independent gates (shared, vendored byte-identical): parity ran + PASS,
no orphan workbooks, no live `type=error` columns, layout applied, tile
census (skipped — this converter does not emit one), **layout lint** (gate 6:
no raw-id titles, no orphan controls, no dead zones, no generic "Page N"
header, no under-filled bands), and **control lint** (gate 7: no dead
controls, no ghost targets, full declared reach, `control-scope.json`
coverage — an interactive dossier converting to zero controls FAILS).
Exit 0 = GREEN. Optional runtime proof after the lint passes:

```bash
ruby scripts/probe-controls.rb --workbook-id <workbookId> --check-out-of-closure
# numeric selectors bind via a hidden "<Name> (Filter)" Text() column the
# auto-picker can't see — pass --value, e.g. --value YearFilter=2024
```

---

## What converts, what's flagged (never faked)

**Converted (live-validated):** classic schema → DM (logical tables → table
elements; attribute key forms on fact+lookup → left-outer joins; heterogeneous
key columns; facts + token-parsed metrics incl. `Count<Distinct=True>` →
`CountDistinct` and compound metrics; semantic display formats) · dossier
chapters → workbook pages with grouped tables (KEY-form grouping + `Max(DESC)`
labels + null-exclude filters) · AE row-collapse reports → deterministic
pinned-winner SQL elements · **chapter filters + attribute selectors → Sigma
controls** wired to the selectors' DECLARED viz targets (gate-7-verified +
flip-tested) with banded layout.

**Flagged / roadmap:** unmapped viz types → flagged table fallback
(`refs/viz-type-mapping.md`); chart emission (kpi/bar/line/combo) extraction-
validated but build roadmap; metric-condition selectors / page-by / prompts
(metric qualification selectors land in `control-scope.json` `unbound` as
MANUAL); panel selectors (navigation — flagged MANUAL); the newer
REST-authorable "Data Model" object incl. `securityFilters` (the future RLS
port surface — until then, **ask the customer about security filters
explicitly**; never assume an estate has none just because the classic extract
doesn't carry them).

## Gotchas baked into the scripts (don't re-learn these)

- Changeset lock dangling + `DELETE /api/model/schema/lock`; reports do NOT
  use changesets; lowercase `x-mstr-ms-instance` response header; PUT
  relationships REPLACES the parent list — `refs/mstr-rest-api.md`.
- Attribute-count metrics (`Count(Customer)`) → cartesian governance aborts —
  count a fact/key column instead; compound denominators need `ZeroToNull()`
  or Snowflake kills the report — `refs/design-notes.md`.
- A list-control filter target on a DATETIME **or NUMERIC** column posts 200
  and is SILENTLY STRIPPED (`filters: null` on readback) — dates → date-range
  controls, numbers → hidden `Text()` cast column (`convert.py` handles both;
  gate 7 catches escapes).
- Python 3.13+ rejects some MSTR cloud CA certs (`VERIFY_X509_STRICT`) —
  `mstr.py` handles it.

---

## Telemetry (after the final gate passes)

**Tell the user this in the conversation before running anything:**

> "Migration complete. Before I wrap up, I'd like to send an anonymous usage ping so we can track which migration skills are being used. It records: tool name, your Sigma region, an anonymized org fingerprint (a hash of your client ID — not the credential itself), migration duration, and success. No workbook names, SQL, column names, or any customer data is included. See [TELEMETRY.md](https://github.com/twells89/sigma-migration-telemetry/blob/main/TELEMETRY.md) for the exact payload. Just say 'skip' if you'd prefer not to send it."

If the user does not object, run:

```bash
python3 scripts/report-telemetry.py --tool microstrategy-to-sigma --duration <elapsed_seconds> --workdir <run-dir> [--mode live|file|both]
# on failure:        python3 scripts/report-telemetry.py --tool microstrategy-to-sigma --duration <elapsed_seconds> --workdir <run-dir> --failed
# if the user declines: python3 scripts/report-telemetry.py --tool microstrategy-to-sigma --workdir <run-dir> --declined
# --workdir writes telemetry-sent.json, the marker the GREEN telemetry gate (assert-telemetry-ran.rb) requires.
```
