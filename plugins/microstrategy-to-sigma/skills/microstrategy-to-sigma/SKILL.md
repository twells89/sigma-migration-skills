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
  sibling skills).
- **The same warehouse on both sides.** Sigma reads the warehouse live; parity
  only means something when the Sigma connection reaches the database
  MicroStrategy queries.
- **Python 3** (stdlib only; `resolve_ae_winners.py` and parity readback also
  want `PyYAML` for Sigma's YAML spec responses) and **Ruby** (the shared
  gate stack: `put-layout.rb`, `assert-phase6-ran.rb`, `probe-controls.rb`,
  `scripts/lib/*.rb` — vendored byte-identical across the sibling plugins).

## Phase 0 — Discover

Run the sibling **`microstrategy-assessment`** skill for an estate-wide
inventory (reports/dossiers, viz histogram, complexity tags) — its
`inventory.json` lists dossier ids. Or quick-check connectivity and pick a
dossier by hand:

```bash
python3 scripts/mstr.py                          # login probe + project list
# dossiers: see assessment, or GET /api/searches/results?type=55 via mstr.py
```

## Phase 1 — Extract the bundle

```bash
python3 scripts/extract.py <dossierId> bundle.json
```

Walks dossier definition → dataset reports (`showExpressionAs=tokens`) →
referenced attributes / metrics (compound bases included via a second pass) /
facts / logical tables / hierarchy relationships. The bundle is the converter
contract — `fixtures/bundle.json` is a real, validated example.

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
ruby scripts/put-layout.rb --workbook <workbookId> --layout layout.xml
```

The layout PUT applies the banded layout (header band titled from the
chapter/dossier name, controls band, full-width tables) the converter emitted
— without it the workbook renders as Sigma's single-column stack and gates
4/6 fail. Read the workbook spec back the same way and confirm no
`type: error` columns. (Workbook DELETE, if you need to retry, is
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
A workbook that POSTs 200 and passes parity can still be visually broken — **overlapping tiles, clipped KPI titles, dead zones, filters over charts.** Sigma's grid has no z-order; the shared layout lib de-overlaps bands, but this visual gate is the safety net (without a top-level layout the workbook renders as a single-column stack — see the existing layout gate).

1. Render every page to PNG (token first: `eval "$(scripts/get-token.sh)"`):
   `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600`
2. **Read each PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking, no dead zones, controls in-band, no clipped titles, even heights, right chart kind/format).
3. Fix any failure in the spec — for multi-page workbooks use `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) — then **re-render and re-read**.
4. Declare the migration done on a **clean render**, not on HTTP 200.

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
