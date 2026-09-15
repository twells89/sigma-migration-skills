<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. migrate-looker.py — per-flag behaviour, decision points, exit codes. -->

# Orchestration — `migrate-looker.py` behaviour in detail

The canonical invocation and THE ONE PATH rule live on the spine (`../SKILL.md`
§ONE COMMAND). This file carries the per-decision detail.

- **Decision points are flags with safe defaults, never silent:** `detect_rls.py`
  runs first — RLS findings STOP the command (exit 10, nothing posted) until you
  either port them via `apply_sigma_rls.py` (Phase 1.5) or re-run with `--yes`
  (proceed WITHOUT RLS — loud + recorded). The DM-reuse check (Phase 2.5) always
  runs and PRINTS candidates+scores. **Default is BUILD-NEW** — reuse only when
  you pin one with `--reuse-dm <id>`. (Auto-reuse keyed on *table* coverage could
  adopt a DM missing a *column* the workbook needs → the workbook POST then 400s
  `Dependency not found`; that footgun is now opt-in via `--reuse-auto`.) Skip the
  scan entirely with `--skip-dm-reuse-check`. The folder is auto-resolved + printed.
- **Performance scan (Phase 2b) — don't port slow SQL blind:** the converter turns every
  `derived_table` into ONE Sigma Custom SQL element with the SQL carried through verbatim
  (nested derived views inline as stacked CTEs into a single element), so a slow Looker derived
  table stays slow in Sigma. `detect_derived_perf.py` runs after the RLS gate (scoped to the
  migrated explore) and prints per-derived-table recommendations — `materialize` /
  `rebuild-as-element` / `leave-inline` — to `derived-perf.json`. It is **informational, never
  blocks** (unlike RLS), and is silent when there are no derived tables. `--materialize-derived
  auto` then triggers a Sigma materialization for the flagged element(s) after the DM is built
  (`all` = every Custom-SQL element); default `off` = recommend only. The recurring **schedule is
  UI-only** (Element ⋮ → Materialization), so this triggers/monitors and, when an element isn't
  materialization-configured yet, prints the exact UI handoff. Post-migration, rank which
  materializations actually pay off by warehouse credit with the **`sigma-materialization-advisor`**
  skill.
- **Complex-model hazard gate:** after workbook generation,
  `detect_modeling_hazards.py` blocks relationships/joins between already-grouped
  SQL elements, additive consumption of broadcast rate/ratio values, and rolling
  calculations without a sorted date grain. Findings feed `agg-semantics.json`
  (final gate 19); rebuild at one explicit grain or record a justified resolution.
- **Dynamic LookML parameters stay workbook-local:** deterministic finite-enum
  branches become manual segmented controls plus `[controlId]` formulas. The
  builder never emits the API-rejected workbook→DM `parameters` binding.
  `dynamic-controls.json` records emitted and static-default outcomes.
- **Source repointing:** if the LookML `sql_table_name` points at a DB.SCHEMA the
  Sigma connection doesn't serve (e.g. dev `DEMO_DB.DEMO.*` vs the connection's
  `QUICKSTARTS.LOOKER_RETAIL_ANALYTICS.*`), pass
  `--source-swap FROM_DB.FROM_SCHEMA=TO_DB.TO_SCHEMA` (repeatable). A not-yet-indexed
  schema (catalog miss) self-heals — `post_dm.py` auto-syncs and retries once.
  Don't know the FROM? `--auto-source-swap-to TO_DB.TO_SCHEMA` asks Looker what
  DB.SCHEMA the explore's connection targets (`GET /connections`) and builds the
  swap for you (production-safe; needs `~/.looker/looker.ini`).
- **No local checkout? `--project <id>`** pulls the LookML over the Looker REST API
  (model + views) instead of `--lookml-dir`. Requires DEVELOP permission on the
  project (Looker only serves raw LookML in the dev workspace); without it the
  command fails loud and tells you to clone the Git repo and use `--lookml-dir`.
  `scripts/looker_project.py` is the standalone helper (`pull` / `connection`).
- **Converter — zero-config, local, no MCP.** A self-contained converter bundle
  ships in the skill at `converter/lookml.mjs` and is the default: conversion runs
  locally via `node` with no clone, no `npm install`, no network, no MCP. A dev's
  own build still wins when set — `CONVERTER_SRC` (`src/lookml.ts` via tsx) or
  `CONVERTER_PATH` (`build/lookml.js`), both auto-located. Refresh the vendored
  bundle with `tools/vendor-converters.sh` (see `converter/PROVENANCE.json`). Only
  if the bundle is missing AND no build is found does the command fall back to the
  MCP path: it writes `<workdir>/convert-request.json` (the exact
  `convert_lookml_to_sigma` arguments) and exits 3 — call the tool, save its JSON,
  re-run with `--converted <file>`.
- **Parity is fully scripted** (the Phase-4 gate below): ACTUAL = Sigma CSV
  export per chart; EXPECTED = a Looker inline query (live) or a
  SOURCE-LookML-derived re-aggregation of the master's warehouse rows (offline —
  measure semantics from the `.view.lkml` `type:`, independent of the builder's
  formulas). Then `phase6-parity-looker.rb --finalize` + `assert-phase6-ran.rb`
  run automatically. Both per-chart fetch sides run in a **bounded 4-wide thread
  pool** (measured 24.3s → 5.8s on the 5-chart fixture); set
  `LOOKER_PARITY_WORKERS=1` to serialize on a loaded warehouse (max is clamped
  to 4 — warehouse-friendly bursts only).
- Exit codes: `0` GREEN · `3` MCP convert request emitted · `10` RLS decision
  needed · `2` built but a gate FAILED. `--dry-run` = no Sigma POSTs.
