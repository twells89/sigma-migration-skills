---
name: looker-to-sigma
description: >-
  Convert a Looker instance (LookML semantic model + dashboards) into a Sigma
  data model and matching workbook(s). Use when the user has Looker content —
  LookML projects, explores, or dashboards (user-defined OR LookML-defined) —
  and wants to recreate it in Sigma. Discovery via the Looker REST API 4.0 /
  Looker MCP server (or LookML files offline), model conversion via the
  local vendored LookML converter (convert_lookml_to_sigma MCP tool as a
  manual fallback), dashboard → workbook conversion from the
  Looker Dashboard API JSON, build via the Sigma REST API, and 3-way parity
  verification against the source warehouse — driven by `scripts/*`.
user-invocable: true
---

# Looker → Sigma Conversion

> **Windows / first run — run the environment doctor before anything else:**
> `bash scripts/doctor.sh` (macOS/Linux/Git Bash) or `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1` (Windows).
> It checks Ruby/Python/Node/bash and flags the Python "Store stub" + CRLF with exact fixes. Details: `refs/environment.md`.

Convert a Looker LookML semantic model into a Sigma data model, then build Sigma
workbook(s) that mirror the Looker dashboards (user-defined OR LookML-defined) as
closely as possible — and verify the numbers match Looker AND the warehouse.

<!-- mandatory-pre-read -->
**Mandatory pre-read — exactly ONE file: `refs/operating-contract.md`** (the
non-negotiable fidelity guardrails: render + value-check EVERY page against the
source, never ship empty or silently drop a tile, don't spin — surface
blockers). Everything else is read **at the phase that consumes it** — the
phase table below names the refs per phase.
<!-- /mandatory-pre-read -->

**For canonical spec shape** (data-model element kinds, workbook element kinds, controls, formulas, formatting), defer to the companion **`sigma-data-models`** and **`sigma-workbooks`** skills. This skill restates only the Looker-conversion-specific patterns.

---

## The two artifacts, two pipelines

Looker has two independent layers; convert them separately.

| Layer | Source (production = API-first) | Converter | Sigma output |
|---|---|---|---|
| **Semantic model** | LookML views+model (Looker API/MCP, or files offline) | local vendored `converter/lookml.mjs` (run in-process via `node`; the `convert_lookml_to_sigma` MCP tool is a manual fallback only) | data model |
| **Dashboards** | `GET /dashboards/{id}` JSON — covers **user-defined (UDD) AND LookML dashboards** | `fetch_looker_dashboard.py` → contract → `build_workbook.py` | workbook |
| **Looks** | `GET /looks/{id}` (LookWithQuery) — a single saved query | `fetch_looker_look.py` → the **same contract** (one tile) → `build_workbook.py` | workbook |

**Critical — UDD is the primary path.** Most real Looker dashboards are **user-defined
(UDD)** — built in the UI, NOT in any LookML file. They are reachable ONLY via the Looker
API, which returns UDD and LookML dashboards as the **same** `Dashboard` JSON
(`dashboard_elements[]` + `dashboard_layouts[]` + `dashboard_filters[]`). So the dashboard
converter keys off that API JSON, not LookML. `.dashboard.lookml` parsing is a secondary,
offline-only path that normalizes into the same contract. Looks are a thin add on the same
pipeline — detail in `refs/phase-3-workbook.md` §Looks.

---

## ONE COMMAND (preferred): migrate-looker.py

> ## ⛔ THE ONE PATH (do not improvise a workbook)
> `migrate-looker.py` is the single entry point; it only reaches GREEN when the
> `assert-phase6-ran` hard gate passes with real charts. Rules:
> - **NEVER hand-drive the per-phase scripts, hand-author a DM/workbook JSON, or
>   `curl`-POST to `/v2/workbooks` / lay out empty "placeholder" pages** — that
>   bypasses parity + the gate and ships an EMPTY workbook (the #1 failure mode).
>   If Looker isn't reachable (no `~/.looker/looker.ini` / API creds), **STOP and
>   tell the user to authenticate** — do not build a shell.
> - **"Done" is a file on disk, not "pages exist."** Complete only when
>   `ruby scripts/verify-complete.rb --workdir <WORK>` prints ✅ DONE (the gate
>   stamped `phase6-success.json`). An empty workbook is never done. Before
>   that check, run `ruby scripts/build-migration-report.rb --workdir <WORK>`
>   and its `--check` mode: every source object and field/formula finding must
>   have one terminal disposition in `MIGRATION_REPORT.md`,
>   `migration-result.json`, and `source-object-census.json`.

The whole pipeline — parse → **RLS gate** → convert → **DM-reuse check** → DM
POST + readback → workbook build (layout inline) → **source-freshness
preflight** → **scripted parity + hard gate** — as a single command. Gates are
never bypassed: the command exits non-zero if parity or `assert-phase6-ran.rb`
fails.

```bash
# env: SIGMA_CONNECTION_ID = the FULL warehouse-connection UUID (NOT a short
# prefix) — required unless --reuse-dm. Persist it once via the tableau plugin's
# `ruby scripts/setup.rb` (writes ~/.sigma-migration/env, which this command
# auto-sources) or export it for the run:
export SIGMA_CONNECTION_ID=<full-connection-uuid>
# offline (.dashboard.lookml + view files; the fixture pair works end-to-end):
python3 scripts/migrate-looker.py --lookml-dir fixtures/skilltest-orders \
    --dashboard fixtures/skilltest-orders/skilltest_orders.dashboard.lookml \
    [--name PREFIX] [--workdir /tmp/look-run]
# live (UDD or LookML dashboard, ~/.looker/looker.ini configured):
python3 scripts/migrate-looker.py --lookml-dir /path/to/lookml \
    --dashboard-id <id> [--explore <name>] [--name PREFIX] [--workdir DIR]
# live (a single Look → a one-tile workbook: grouped table / KPI / pivot / chart):
python3 scripts/migrate-looker.py --lookml-dir /path/to/lookml \
    --look-id <id> [--explore <name>] [--name PREFIX] [--workdir DIR]
```

Exit codes: `0` GREEN · `3` converter request emitted · `10` RLS decision needed ·
`2` built but a gate FAILED. `--dry-run` = no Sigma POSTs. *(Redirect — E9 diet:
every decision flag, its default, and why it defaults that way —
`--reuse-dm`/`--reuse-auto`, `--materialize-derived`, `--source-swap`,
`--project`, `CONVERTER_SRC`/`CONVERTER_PATH`, parity worker pool — moved
verbatim to **`refs/orchestration.md`**.)*

---

## Scripts

**`scripts/migrate-looker.py` composes every phase below** — run it, not the
per-phase scripts. Invoke another script directly **only when an orchestrator
STOP tells you to**. *(Redirect — E9 diet: the full per-script contract catalog
moved verbatim to **`refs/script-map.md`**.)*

**Test-fixture builders are not migration steps.** `build_looker_dashboard.py` /
`build_looker_dashboard2.py` / `build_looker_look.py` **author** Looker content to
convert against. **Never run them against a customer's Looker.**

---

## Prerequisites

Looker API 4.0 via `~/.looker/looker.ini` (`client_credentials`); Sigma via
`eval "$(scripts/get-token.sh)"` (~1h TTL). *(Redirect — E9 diet: ini shape, the
:19999→443 self-heal, TLS/truststore, required Looker permissions, and the
one-time Looker-side warehouse connection moved verbatim to
**`refs/credentials.md`**.)*

> **Inline Python/Node inside bash — DON'T.** Triple-nested escapes silently break.
> Write a `.py`/`.mjs` file and call it. Never `TOKEN=$(eval "$(scripts/get-token.sh)")`
> — `$()` is a subshell where the exported var dies.

---

## The workflow (progressive disclosure)

This spine is the **map**: every phase, its one command, its gate, and the refs
to read **at that phase** (load nothing ahead of its phase). `migrate-looker.py`
runs 0a–4 for you; reach for a phase ref when you drive a phase by hand or need
to understand why it stopped.

| # | Phase | One command / action | Gate → artifact | Read at this phase |
|---|---|---|---|---|
| 0a | Destination (ask when not given) | `python3 scripts/pick_destination.py list` | chosen workspace/folder id → `--folder <id>` | `refs/phase-0-scope.md` |
| 0b.1 | **Input completeness (run FIRST)** | `python3 scripts/check_input_completeness.py <dir>` | partial-input verdict in numbers — informational, never blocks | `refs/phase-0-scope.md` |
| 0b.2 | Scope the estate | System Activity (`i__looker`) usage history | ranked migration shortlist | `refs/lookml-remodeling.md`, `refs/open-items.md` |
| 0c | **Readiness audit (mandatory, creds-free)** | `node scripts/audit-lookml-readiness.mjs` | `lookml-readiness.json` + field/formula censuses — **exit 1 = blocked, a hard pre-POST stop** | `refs/phase-0-scope.md` |
| 1 | Discover the Looker content | `fetch_looker_dashboard.py` / `fetch_looker_look.py` (live) or `parse_lookml_dashboard.py` (offline) | normalized contract JSON | `refs/phase-1-discover.md`, `refs/dashboard-contract.md` |
| 1d | RLS scan (cheap, silent if none) | `python3 scripts/detect_rls.py <dir>` | findings summary; silent + exit 0 when no RLS | `refs/security-rls.md` |
| 1.5 | **RLS decision gate — BEFORE building** | `apply_sigma_rls.py` (port) or re-run with `--yes` | exit 10 until ported or explicitly waived — **a skip is loud and recorded** | `refs/security-rls.md` |
| 2 | Convert the semantic model | `node scripts/convert_dm.mjs` | `dm-spec.json` + `…-warnings.json` sidecar | `refs/phase-2-datamodel.md`, `refs/modeling-strategy.md`, `refs/looker-coverage.md`, `refs/layered-lookml.md` (**required for any project with `derived_table:` views**) |
| 2b | Derived-table performance scan | `python3 scripts/detect_derived_perf.py` | `derived-perf.json` — informational, never blocks | `refs/phase-2-datamodel.md` |
| 2.5 | Reuse an existing DM? (reuse-first) | `find-or-pick-dm.rb` → `shape-preflight.rb` | `dm-match.json`; **default is BUILD-NEW** — shape preflight exit 2 = unsafe reuse | `refs/phase-2-datamodel.md` |
| 2c–2d | POST the DM + verify | `python3 scripts/post_dm.py <spec.json>` | server ids; **no `type=error` columns** | `refs/phase-2-datamodel.md` |
| 3 | Build the workbook spec | `python3 scripts/build_workbook.py` | `preflight_lint.rb` clean before any POST | `refs/phase-3-workbook.md`, `refs/looker-dashboard-layout.md`, `refs/workbook-code-release-gaps.md` |
| 3h | Complex-model hazard gate | `python3 scripts/detect_modeling_hazards.py` | `agg-semantics.json` (gate 19); unresolved entries exit 2 | `refs/modeling-hazards.md` |
| 4 | **Parity + the hard gate** | `phase6-parity-looker.rb --finalize`; `assert-phase6-ran.rb` | `parity-final.json` PASS + gate **exit 0** | `refs/phase-4-parity.md`, `refs/control-parity.md` |
| 4a | **Visual QA — render BOTH, read both** | `looker-render-dashboard.py` + `sigma-export-png.py` | ≥5 source anchors (gate 13) + visual-similarity floor (gate 14) | `refs/phase-4-parity.md`, `refs/source-anchors.md`, `refs/layout-visual-qa.md`, `refs/visual-similarity.md` |
| 5 | Enhance (post-publish, UI-only) | manual, in the Sigma UI | expectations set up front | `refs/postpublish-ui.md`, `refs/phase-e-enhance.md`, `refs/app-recommendation-signals.md` |
| — | Report + declare done | `build-migration-report.rb --check`; `verify-complete.rb` | ✅ DONE + complete source-object accounting | `refs/migration-report-format.md` |

On a converter gap: **Gap scout** below. On an error/symptom: `refs/troubleshooting.md`.
On a STOP naming a script: `refs/script-map.md`.

## Hard-gate kernels (full stanzas live in the phase refs)

- **🚧 Phase 0b.1 — never judge convertibility from a partial export.** A partial
  LookML export converts "successfully" and looks catastrophic: every unexported
  joined view becomes a `LOOKER_SCRATCH.<VIEW>` placeholder with its own loud
  warning, so hundreds of warnings read as *"this tool cannot convert our model."*
  That is a **missing-input problem, not a capability problem** — reporting the
  first as the second has already cost credibility on a live migration. Run
  `check_input_completeness.py` and trust its counts over any hand grep. Full
  rationale: `refs/phase-0-scope.md` §0b.1.
- **🚧 Phase 1.5 — RLS is never silently dropped and never silently ported.**
  `detect_rls.py` findings STOP the run (exit 10, nothing posted) until you either
  port them (`apply_sigma_rls.py`) or re-run with `--yes` to proceed WITHOUT RLS —
  loud and recorded in the Phase 4 summary, per finding. **Skip is loud** — all rows
  visible to everyone. Full flow: `refs/security-rls.md`.
- **🚧 Phase 2.5 — a reused DM must pass `shape-preflight.rb`.** It checks the three
  things a spec POST won't: the element isn't `visibleAsSource:false`, needed columns
  resolve, and every relationship reached through is 1:1 (non-unique target key →
  silent fan-out). Visibility/coverage hard-fail (exit 2). **Default is BUILD-NEW**;
  auto-reuse is opt-in (`--reuse-auto`) because table-coverage matching can adopt a DM
  missing a needed *column* → the workbook POST 400s `Dependency not found`.
- **Preflight every workbook spec before POST.** `ruby scripts/lib/preflight_lint.rb <spec.json>`
  exits 1 on the two migration-killer bugs: a `table` with aggregate columns + dimensions but
  **no `groupings`** (renders raw detail rows), and a malformed `control`. Fix every violation
  first — never POST past it, and **never conclude a feature is "unsupported" from an
  `Invalid kind` error** (it means the inner fields are wrong). Verified shapes:
  `sigma-workbooks` `controls.md` / `tables.md`.
- **Phase 3 — the layout is authoritative, and the body is `document`-wrapped.**
  `build_workbook.py` emits a required **newspaper → 24-col grid layout** XML string that
  places every flat element exactly once. Pages carry metadata ONLY — page membership comes
  from that layout, so the layout is the last word on structure and an element missing from
  it simply does not render. `schemaVersion`, `pages`, `kind`, `layout` and flat `elements`
  all nest under a top-level **`document`** key; workbook `name`/`folderId` stay outside it.
  (The Phase-2 DM POST to `/v2/dataModels/spec` is a different surface and remains flat.)
  Full shape + the tile/filter maps: `refs/phase-3-workbook.md`.
- **🚧 Phase 4 — parity and visual QA are both mandatory; HTTP 200 is not done.**
  `assert-phase6-ran.rb` refuses GREEN unless parity ran and PASSED, no orphan
  workbooks, no `type=error` columns, a real layout is applied, layout lint (gate 6)
  and control lint (gate 7) pass, the ≥5 source anchors verify (gate 13) and the
  visual-similarity floor holds (gate 14). With no source PNG on disk both self-SKIP
  **stated, never a silent pass**. Full sequence: `refs/phase-4-parity.md`.

---

## Gap scout — when the converter can't translate a LookML construct

When `convert_lookml_to_sigma` only approximates or drops a LookML measure/construct (a ratio /
`${measure}`-ref measure, a `type: percentile`, a filtered count, a Liquid `{% parameter %}`
measure), spawn the **gap scout** subagent to find a Sigma formula that resolves on the live site,
then persist it so the next dashboard reuses it. The full runbook (when to spawn, the spawn
prompt, the LookML→Sigma candidate table, opt-in issue filing) is in **`scripts/gap-scout.md`** —
read it before spawning.

- `scripts/scout-validate.py` validates a candidate against a real DM element (builds a throwaway
  test workbook, checks the column's resolved type, deletes it) and persists a win to
  `~/.looker-to-sigma/learned-rules.yaml` (`scripts/learned-rules.py` loads + applies it).
- On failure it returns an `escalation` block. Filing a GitHub issue is **opt-in /
  confirm-before-file** — run `escalation.dry_run_cmd` (files nothing; drafts the issue + dedupes),
  show the user, and only run `escalation.file_cmd` (`escalate-gap.py … --yes`) if they accept.
  LookML construct gaps are **converter** gaps and mirror to both converter repos with a bead.

This is also a lightweight way to **validate a migrated DM/workbook**: point `scout-validate.py`
at the denorm element to confirm a suspect formula resolves (no `type:error` column) before
declaring Phase 4 green.
