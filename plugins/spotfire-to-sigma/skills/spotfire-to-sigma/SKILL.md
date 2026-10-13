---
name: spotfire-to-sigma
description: Convert an authoritative Spotfire model and analysis manifest into a Sigma data model and workbook, with POST/readback gates and warehouse verification.
---

# Spotfire → Sigma

This foundation supports authoritative extraction, deterministic conversion,
Sigma POST/readback, and warehouse execution verification. It does **not**
claim Spotfire source parity. A normal live run stops at exit `16` after the
warehouse gate until rendered source-visual evidence is supplied.

## Phase 0 — Assess (C1)
Use the sibling `spotfire-assessment` skill for estate inventory and
shortlisting. It accepts the same authoritative single-document manifest used
here. For one selected analysis, run `scripts/scan_gaps.py` or let the
orchestrator write `gap-report.json`.

## Phase 1 — Discover (C2)
Export through the public `Spotfire.Dxp.Application` API:

```text
OutputPath=/secure/export/spotfire-manifest.json
ProvenancePath=/secure/export/spotfire-manifest-provenance.json
SourceDxpPath=/secure/source/analysis.dxp
ExecutionContext=analyst
```

The manifest is authoritative only when `authority.authoritative=true`,
`api_surface=Spotfire.Dxp.Application`, and `dxp_raw_used=false`. Validate it:

```bash
python3 scripts/validate_manifest.py spotfire-manifest.json \
  --provenance-map spotfire-manifest-provenance.json
```

`spotfire-manifest-provenance.json` is exporter API evidence. It is not the
warehouse map. Create a customer warehouse target map conforming to
`refs/spotfire-source-map.schema.json`; this maps imported, embedded,
on-demand, and data-function outputs to landed warehouse tables.
Dry-run may report an unavailable DXP hash, but live mode requires
`SourceDxpPath` so the manifest, resumed Sigma objects, and visual evidence are
bound to the exact source bytes.

## Phase 1.5 — Reuse-check (C3)
The orchestrator writes `workbook-signature.json` and runs
`find-or-pick-dm.rb`. A safe auto-pick is read back and census-checked. An
ambiguous recommendation stops at exit `15`; rerun with either
`--reuse-dm <id>` or `--force-new-dm`. Every decision is recorded in
`dm-reuse-decision.json`.

## Phase 2 — Convert (C4)
`convert.py` consumes manifest v1 (`model.tables`, `model.relations`,
`presentation.pages`, `presentation.filtering_schemes`, `automation`, and
`security`). It translates supported formulas and visuals, preserves nested
layout, and emits loud gaps for unsupported scripts, data functions, mods,
markings, bookmarks, and security work.

Run a no-write conversion:

```bash
python3 scripts/migrate_spotfire.py \
  --manifest spotfire-manifest.json \
  --source-map warehouse-source-map.json \
  --workdir ./spotfire-migration \
  --dry-run
```

Dry-run never calls Sigma, never performs the reuse scan, and never stamps
success.

## Phase 3 — Post data model and read back (C5) ← HARD GATE
Live mode POSTs the DM or reads the explicitly selected reusable DM, then
checks the element/column census and rejects every `type=error` column.
`datamodel-ids.json` records server IDs. The workbook is rebuilt against those
server DM and element IDs; client-generated IDs are never trusted.

## Phase 4 — Build, lint, POST, and read back workbook (C6) ← HARD GATE
Before POST, live mode runs preflight, layout, and control lints. It calls the
workbook verify endpoint, POSTs the workbook, reads it back, verifies its
element/column census, and scans the paginated columns endpoint for errors.

```bash
python3 scripts/migrate_spotfire.py \
  --manifest spotfire-manifest.json \
  --source-map warehouse-source-map.json \
  --folder-id <sigma-folder-id> \
  --workdir ./spotfire-migration
```

Authentication uses `SIGMA_BASE_URL` plus an existing `SIGMA_API_TOKEN` or
`SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET`; the vendored REST transport refreshes
and retries one unauthorized request.

## Phase 5 — Layout (C7)
Layout is nested under each source visual and converted to Sigma's 24-column
grid. It is authored after every element and control as the **last write** in
the single posted workbook spec, then checked by `layout_lint.rb`. Source/Sigma
rendered comparison remains a separate evidence gate; see
`refs/layout-visual-qa.md`.

## Phase 6 — Warehouse verification and source checkpoint (C8) ← HARD GATE
`build-parity-plan.rb` inventories visible queryable elements.
`verify-warehouse.rb` exports each one from the posted workbook and requires
non-empty, column-resolvable data with no query-error cells.

The resulting banner is always **WAREHOUSE VERIFICATION ONLY — NOT SOURCE
PARITY**. `run-state.json` records `verified_against=warehouse`,
`parity_complete=true`, and `source_parity_claimed=false`. Without proven
rendered Spotfire evidence, the run finishes incomplete with exit `16` after
all requested POST/readback/warehouse work has completed.

Capture evidence from that exact posted workbook, then rerun against the same
workdir with `--resume-live`; the orchestrator re-reads the persisted DM and
workbook IDs instead of POSTing replacements.

An external visual comparison may be supplied with
`--source-visual-evidence`. The JSON must identify the posted `workbook_id`,
the source artifact SHA-256, a positive all-pass visual census, and non-empty
evidence records (one SHA-bound PASS record for every manifest page containing
visuals). This proves the visual-comparison checkpoint only; it still does not
turn warehouse verification into source-value parity.

If `completion-gaps.json` is non-empty, completion also requires
`--gap-decisions <ledger.json>`. The ledger must contain one `resolved` or
`accepted` decision with a non-empty reason for every exact
`object_type`/`object_id`/`warning_id` tuple. Broad waivers are rejected; a
missing ledger stops at exit `17`.

## Security: RLS / CLS (C9)
The exporter and converter preserve security signals and require manual review
because a loaded document cannot prove every Spotfire library ACL or external
security rule. Never infer or silently fabricate Sigma RLS/CLS from an
`unknown` signal.

## Gaps
Unsupported source features remain in `gap-report.json` and
`conversion-gaps.json`. Never fake a feature or treat local spec generation as
a completed migration.

Exit codes: `0` dry-run or all configured gates complete; `2` failed gate;
`15` reuse decision required; `16` warehouse passed but source visual evidence
is still required; `17` per-gap decisions are still required.
