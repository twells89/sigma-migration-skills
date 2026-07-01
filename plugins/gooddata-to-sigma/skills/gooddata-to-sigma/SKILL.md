---
name: gooddata-to-sigma
description: >-
  Migrate GoodData Cloud / GoodData.CN workspaces to Sigma. Use when the user
  has a GoodData workspace — datasets, MAQL metrics, insights, and analytical
  dashboards — and wants to recreate it in Sigma. Exports the workspace via the
  declarative layout API (logicalModel + analyticsModel), maps the LDM
  (datasets / attributes / facts / references) to a Sigma data model, translates
  MAQL metrics to Sigma formulas, maps insights to workbook charts/KPIs/pivots
  and dashboards to pages + layout, ports user data filters (RLS) to Sigma user
  attributes, and verifies parity against the same warehouse. Translates what
  maps cleanly and flags what doesn't (compute-engine-only metrics, exotic MAQL
  context, unsupported widgets) instead of emitting wrong logic. Legacy GoodData
  Platform (/gdc/md classic) is out of scope for now — Cloud / .CN only.
user-invocable: true
---

# GoodData → Sigma

> **Windows / first run — run the environment doctor before anything else:**
> `bash scripts/doctor.sh` (macOS/Linux/Git Bash) or `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1` (Windows).
> It checks Ruby/Python/Node/bash and flags the Python "Store stub" + CRLF with exact fixes. Details: `refs/environment.md`.

> **Status: LIVE-VALIDATED — exact parity, data model + workbook.**
> Proven end-to-end on a GoodData Cloud trial → Sigma (both on Snowflake): a
> workspace (LDM + MAQL metrics + insights + dashboard) migrated to a Sigma data
> model + workbook with **exact parity** on metrics and the relationship-backed
> by-region breakdown; the `BY ALL` share metric was correctly flagged. Build
> order, risks, and remaining work (live FOR-PREVIOUS date-intel) are in
> `refs/design-notes.md`. Still: **never claim a specific conversion works until
> it passes live parity for that workspace.**

Recreate a GoodData workspace in Sigma, in the same phase structure as the
sibling converters (Tableau, Power BI, Qlik, Cognos, MicroStrategy, SSRS, …).
This skill defers all workbook-spec authoring to the **sigma-workbooks** skill
and all data-model authoring to **sigma-data-models**.

## Read these first

- `refs/gooddata-api.md` — declarative export API, auth, LDM + analytics shape.
- `refs/maql-mapping.md` — MAQL → Sigma formula contract (the hard part).
- `refs/viz-type-mapping.md` — insight + dashboard → Sigma element mapping.
- `refs/design-notes.md` — full architecture, parity, RLS, risks, build order.

## Converter architecture (read if you know the other migration skills)

Unlike the **Group-A** converters (tableau, powerbi, qlik, quicksight, looker,
thoughtspot, cognos) — which share the vendored `sigma-data-model-mcp` engine
(`converter/*.mjs`, with the hosted `convert_*` MCP tool as a fallback) — this
skill uses a **self-contained Python converter that ships in `scripts/`**
(`convert.py` + `maql.py`). It runs locally via `python3`; there is **no vendored
`.mjs` bundle, no `convert_gooddata_to_sigma` MCP tool, and no `--converter` /
`*_MCP_DIR` override** — those concepts do not apply here. Nothing about the model
conversion leaves your machine.

## Phases

**Phase 0 — Assess.** Run the `gooddata-assessment` skill for an inventory +
readiness readout before committing to a conversion.

**Phase 1 — Discover.** `eval "$(scripts/get-token.sh)"` then
`python3 scripts/discover.py --workspace <id>` → `workspace_layout.json`
(full LDM + analytics model). Confirm counts and the MAQL-keyword / insight-type
histograms it prints.

**Phase 1b — Gap-scout (measure MAQL coverage first).**
`python3 scripts/scan_gaps.py --workspace gd_workspace.json` reports coverage by
category — AUTO (data-model metric), TIME_INTEL (→ workbook DateLookback),
CONTEXT (→ workbook grouping/Level), UNHANDLED (logged to learned-rules). Run
this before converting so coverage is known, not assumed.

**Phase 1c — Reuse check (avoid DM sprawl).** Before creating a new data model,
**reuse-check**: look for an existing Sigma DM with the same signature (same
connection + tables) and reuse/pick it (`find-or-pick-dm`) rather than POSTing a
duplicate. Only build a fresh DM when no match exists.

**Phase 2 — Data model.** `scripts/convert.py` maps LDM datasets → Sigma
warehouse-table elements (dim-before-fact; recover the path from the data-source
db/schema so parity runs on the same warehouse), attributes/facts → columns,
references → relationships, MAQL metrics → DM metrics (via `maql.py`); flagged
metrics go to `flags.json`. POST the emitted spec to `/v2/dataModels/spec`
(needs top-level `schemaVersion` + `folderId`), then **read back** the created
DM (`GET /v2/dataModels/{id}/spec`) to capture the real, server-assigned
element/column ids — a hard gate before any workbook work (POST reassigns ids).
```
python3 scripts/convert.py --workspace gd_workspace.json \
  --connection-id <sigma-conn-uuid> --db <DB> --schema <SCHEMA> \
  --folder-id <sigma-folder> --out dm_spec.json --flags flags.json
```

**Phase 3 — Workbook.** `scripts/build_workbook.py` maps insights →
kpi-chart/bar-chart (each sourcing the migrated DM fact element; charts
auto-aggregate by axis), recursively inlines metric MAQL into measure formulas,
and resolves a related-dataset `view` attribute to a cross-element reference
`[FACT/REL_NAME/Dim]` (exercises the migrated relationship). POST to
`/v2/workbooks/spec`. Defers chart/layout/theming idioms to **sigma-workbooks**.
```
python3 scripts/build_workbook.py --workspace gd_workspace.json \
  --data-model-id <dm-uuid> --fact-element <elId> --fact-name <TABLE> \
  --rel-name <REL_NAME> --fact-dataset <ds-id> --folder-id <folder> --out wb_spec.json
```
Apply the dashboard grid **layout as the LAST write** (after all elements exist;
a bare spec PUT wipes layout) — match GoodData's section/widget arrangement.

**Phase 4 — Parity.** Query the migrated DM/workbook elements vs the **same
warehouse** truth. NOTE: sigma-mcp-v2 `metric('<id>', t)` returns "Missing
Metric" (a known MCP bug) — parity-query the columns/formulas directly instead.

**Phase 5 — Repoint.** Finalize workbook element sources onto the built DM —
never skip.

**Phase 6 — RLS + enhance.** Port user data filters → Sigma user attributes via
the consolidated RLS gate; apply theme via the theme registry; final visual-QA.

## Contract: flag, never fake

Surface — never silently mis-convert — these (log to gap-scout / learned-rules,
opt-in escalate):
- MAQL with no clean warehouse equivalent (FlexQuery / compute-only).
- `BY` / `BY ALL` / `WITHIN` context that can't be reconstructed from insight grain.
- Exotic visualizations (funnel / sankey / waterfall / treemap …) → flagged table.
- `sql`-backed datasets and anything the MAQL parser tags `UNHANDLED`.

## Scope

GoodData **Cloud / .CN** (`/api/v1` declarative API). Legacy **Platform**
(`/gdc/md/{project}`, classic MAQL, MUF) is a documented fast-follow — see
`design-notes.md` — not built.
