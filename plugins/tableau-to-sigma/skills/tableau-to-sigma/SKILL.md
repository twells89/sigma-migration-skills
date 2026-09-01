---
name: tableau-to-sigma
description: >-
  Convert a Tableau datasource or workbook into a Sigma data model and matching
  dashboard. Use when the user has a Tableau datasource, TDS file, or Tableau
  workbook and wants to recreate it in Sigma. Discovery, calc-field translation,
  data model + workbook creation via REST API, layout generation, and parity
  verification — driven by the selected Ruby or Python runtime profile.
user-invocable: true
---

# Tableau → Sigma Conversion

> ## ⛔ STEP 0 — MANDATORY environment bootstrap (before any other step)
> On the **first run on a machine**, run the ONE bootstrap command — idempotent,
> non-interactive, no admin, never echoes credentials:
> - macOS / Linux / Git Bash: `bash scripts/bootstrap.sh --workdir <WORK>`
> - Windows PowerShell: `powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 -WorkDir <WORK>`
>
> It resolves a supported runtime profile from `runtime-capabilities.json`,
> installs only that profile's missing dependencies (user-scoped, never admin),
> persists credentials with the matching setup script, ends in a doctor run
> (`doctor.json`), and writes
> the **bootstrap sentinel** (`bootstrap.json`).
> Both orchestrators REFUSE to start without sentinel +
> doctor-green. **NEVER hand-install a runtime or edit PATH yourself** — if
> bootstrap reports no admin-free route, surface its message to the user and
> stop. Dry run: `--check` / `-Check`. Details: `refs/environment.md`.

> ## ⛔ STEP 1 — THE ONE PATH (a single entry point; do not improvise one)
> After the bootstrap, **always run the orchestrator** — it chains every phase
> in one process and self-gates:
> ```
> # Use the entrypoint selected in doctor.json:
> ruby scripts/migrate-tableau.rb --workbook "<name>" --connection <id>
> # or, when selectedProfile=python:
> python3 scripts/migrate-tableau.py --workbook "<name>" --connection <id> …
> ```
> - **Pass the Tableau `/#/views/…` share URL straight to `--workbook` (quote it).**
>   The orchestrator resolves the workbook LUID from the URL's `contentUrl` slug
>   in process. Display names diverge from slugs, so **never** hand-roll
>   `name:eq:` filters or page the workbook list — that field-cost a
>   500-workbook scan. Give it the URL.
> - **Flag cheatsheet — use the EXACT flags for the selected entrypoint:**
>   `migrate-tableau.rb --out DIR` (the workdir flag is **`--out`**, not `--workdir`);
>   `migrate-tableau.py --out DIR` uses the same workdir flag;
>   `validate-spec.rb <spec.json> --type dm|workbook` (spec is a **positional** arg, no `--spec`);
>   `put-layout.rb --workbook ID` (**not** `--workbook-id`), reading `SIGMA_API_TOKEN` from the env.
> - **Do NOT hand-drive the per-phase scripts or hand-author DM/workbook JSON
>   UNLESS an orchestrator STOP explicitly routes you there** (e.g. "CONVERTER
>   STOP", the exit-4 handoff). The script map is **not a menu** — à-la-carte
>   scripts are the #1 way runs go inconsistent.
> - **"Done" is not something you decide — it is a file on disk.** The migration
>   is complete **only** when the selected runtime's completion gate
>   (`verify-complete.rb` or `verify-complete.py`) exits 0 / prints ✅ DONE.
>   A clean **PASS 1 (exit 12) is NOT done** — it means
>   "run `--finalize`". Never report success or write a completion summary before.
>   Completion also requires complete accounting: every formula in
>   `formula-audit.json` and every object in `source-object-census.json` has one
>   terminal disposition in `MIGRATION_REPORT.md` / `migration-result.json`.
> - **This is a PRODUCTION migration, not a demo.** The bar is EXACT parity
>   against the same warehouse, always. At a wall: follow the printed
>   STOP/handoff, or surface the blocker plainly and stop — NEVER a third
>   "lighter/simplified" path; only the **user** may descope. Verbatim rule:
>   `refs/operating-contract.md` §Never negotiate fidelity down.
> - **An orchestrator STOP is an instruction to YOU (the agent), not a handoff
>   to a human — keep going.** A routing exit authorizes you to do the next
>   step yourself and re-enter the gated spine; the only finish line is
>   `verify-complete.rb` exit 0. Verbatim rule: `refs/gates.md`.
> - **At the exit-4 handoff, PATCH the auto-built `<WORK>/wb-spec.json` — do NOT
>   rewrite it** (a from-scratch rewrite drifts controlIds and fails
>   control-lint wholesale — the #1 way this handoff spirals; prefer
>   `--master-col` for master-level calcs). Full handoff discipline:
>   `refs/gates.md` §Exit-4.
> - **Credentials:** the orchestrator stops at step 0 telling you to run the
>   selected runtime's `scripts/setup.rb` or `scripts/setup.py` once — do that
>   rather than working around auth
>   (`refs/environment.md` §Credentials).

> ## Runtime selection
> `auto` prefers the supported Ruby profile when Ruby is available and falls
> back to the supported Python profile when Ruby cannot be installed or
> resolved. To require the no-Ruby path, pass `--runtime-profile python`
> (`-RuntimeProfile python` in PowerShell). The Python profile requires Python
> and Node; it does not require Ruby. Bash launches bootstrap on macOS/Linux,
> while PowerShell launches it on Windows. Full Python invocation, artifacts,
> and fail-closed behavior: **`PYTHON_RUNTIME.md`**.

> **Model fit & vision — `refs/model-fit.md`** (read before Phase 0 on any
> multi-dashboard workbook): pixel-fidelity claims require image input;
> very-large workbooks on non-top-tier models → ask the user once; a
> text-only agent records the visual verdict as not-executable, never `pass`.

> **🚧 GATE convention.** A 🚧 GATE step is backed by a script that *fails the
> run* if the step was skipped — an **artifact** (a file on disk) plus a
> downstream check that refuses to proceed without it. Catalog: **`refs/gates.md`**.

<!-- mandatory-pre-read -->
**Mandatory pre-read — exactly ONE file: `refs/operating-contract.md`** (the
non-negotiable guardrails: obtain the source render + calcs, build from the
source's own logic, render + value-check EVERY page, never ship empty or waive
silently, don't spin). Everything else is read **at the phase that consumes
it** — the phase table below names the refs per phase.
<!-- /mandatory-pre-read -->
*(Redirect: the old flat 13-ref pre-read list became the "Read at this phase"
column; per-script catalog: `refs/script-map.md`.)*

**For canonical workbook spec shape** (element kinds, controls, formulas,
formatting), defer to the companion **`sigma-workbooks`** skill
(**`sigma-authoring`** plugin — install it alongside; this converter assumes
it); this skill restates only Tableau-conversion-specific patterns.

---

## Step −1 — Mission intake (MANDATORY — before anything else)

Restate the user's request as `<workdir>/mission.json` (schema + rules +
kickoff template in **`MIGRATION_REQUEST.md`**): source, connection,
destination, landing target, workbook scope — each marked `stated` or
`inferred`. **Any `inferred` field → STOP and confirm with the user before
building** (field evidence: invented scope has invalidated entire runs). The
orchestrator **consumes a STATED dashboard scope** (E9.6: `scope.dashboards`,
or a single-view `/#/views/` URL in `scope.value`) — it threads onto
`--dashboard` end-to-end; see `refs/orchestration.md` §Single-invocation flow.

## Step 0 — Bootstrap + doctor (MANDATORY — the orchestrator gates on it)

Run the bootstrap FIRST (STEP 0 banner above). It ends with the doctor
(`doctor.json` + the `bootstrap.json` sentinel); both orchestrators refuse to
start until both pass. Re-verify: `bash scripts/doctor.sh --workdir <WORK>`
(PowerShell: `scripts\doctor.ps1 -WorkDir <WORK>`). Gate impossible in your
environment (e.g. a sandbox) → waive explicitly and name it in your report:
`migrate-tableau.rb … --skip-doctor-gate "<reason>"`.

## Step 0.1 — Front door: resolve the connection once (`scripts/intake.rb`)

The Ruby profile can use `ruby scripts/intake.rb --workdir <WORK>
--tool tableau-to-sigma --mode live
--source "<workbook>"` resolves the Sigma warehouse connection a SINGLE time
(caches `<WORK>/connection.json`, read by the orchestrator when `--connection`
is omitted — point `--out` at the same `<WORK>`). With multiple connections it
asks — **it never guesses**; `--rank-workbook-id <LUID>` auto-resolves by
warehouse fingerprint. `--source` keys front-door triage: retire-tagged in the
assessment plan (`--plan`, or auto-found `<WORK>/migration-plan.json`) →
refuse, exit 7 — override only with an attributable `--triage-override
"<who>: <why>"` (ledgered in `offramps.jsonl`, never silent);
low-rank/blocked/consolidation WARN and proceed; no plan → one offer line,
never a block. Full flags, precedence, ranking, triage:
`refs/phase-0-scope.md` §Step 0.1. Credentials: `refs/environment.md`
§Credentials.

The Python profile requires `--connection` explicitly and performs strict
GET-only reuse discovery inside `migrate-tableau.py`; it never guesses among
multiple compatible objects.

## One command (orchestrated path)

> **⏱ Invocation (G2/W2.5):** full pass = 5–20+ min. Default: `--wait` (ONE
> tool call; tool timeout ≥ 25 min) — inner exit code passes through verbatim;
> **exit 26** = budget up, run STILL ALIVE (pid+log printed; re-run to
> re-attach — never a failure). Detached: poll only on a `migrate-state.json`
> transition, else ≥90s. Bare 2-min Bash kills runs (exit 143); check `$?`.

```bash
# Supported no-Ruby path — auto reuse, extract routing, workbook build, and
# REST parity collection are fail-closed:
python3 scripts/migrate-tableau.py \
  --workbook "<name-or-share-URL>" \
  --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
  --db <DB> --schema <SCHEMA> --landing <DB.SCHEMA-or-n/a> --out <WORK>

# PASS 1 — discover → gap gate → DM-reuse scan → DM → workbook → layout → parity plan
ruby scripts/migrate-tableau.rb \
  --workbook "<name>" --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
  [--db <DB> --schema <SCHEMA>] [--name '<prefix>'] [--row-scale 1.5] \
  [--reuse-dm [ID]] [--force] [--yes]
# … gap scan writes <workdir>/formula-audit.json + source-object-census.json …
# … pass 1 auto-fills <workdir>/parity-actuals.json (collect-parity-actuals.rb);
#   run the printed mcp-v2 queries for the REMAINING charts (pivot grids) only …
# PASS 2 — finalize: phase6 verify + cleanup-orphans + census-aware report/gate
ruby scripts/migrate-tableau.rb --workbook "<name>" \
  --finalize --actuals <workdir>/parity-actuals.json [--allow-missing-tiles N]
# … writes MIGRATION_REPORT.md + migration-result.json; incomplete accounting fails …
```

> **`--db`/`--schema` (always together) — there is NO default database.** The
> orchestrator resolves: your flags → the landing manifest → the workbook's own
> `<connection dbname=/schema=>` attributes — and **hard-stops asking** when
> none resolve, never guessing: a fabricated pair 404s every table at DM POST.

> **🚧 PASS 1 WAITS for you twice:** (1d) Read the dashboard PNG, write
> `<workdir>/png-read.json` `"verified": true` — the run continues (exit 18 on
> deadline; schema `refs/phase-1-discover.md`; no PNG →
> `--skip-dashboard-read "<r>"`). (tail, W2.6) discharge the visual verdict
> per the banner → a cold run chains `--finalize` in-process
> (`SIGMA_VISUAL_VERDICT_TIMEOUT_S`, 0=skip).

> **Converter backend — LOCAL by default (`converter/tableau.mjs`, no
> network); the hosted converter uploads the `.twb` and runs ONLY with
> explicit `--converter hosted` / `SIGMA_CONVERTER_ALLOW_HOSTED=1`. No
> converter at all? Re-enter the GATED spine — never hand-POST raw specs.**
> Mechanics + spec re-entry placeholders: `refs/orchestration.md` §Converter
> backend.

> **Parity is EXACT for warehouse-backed migrations — never blame "drift."**
> Sigma queries the **same warehouse** Tableau reads; a value gap is a real bug
> (missing view filter / NULL bucket / ungrouped table / wrong aggregate), not
> freshness. `extract-mode` is **only** for `hasExtracts=true` workbooks,
> explicitly flagged. Do not declare GREEN while a table renders
> base-row-count detail or a NULL-dominant bucket — run
> `scripts/lib/preflight_lint.rb` first.

Chains the scripted spine (discover → gap scan → columns → DM reuse/build/POST
→ workbook → layout → parity → cleanup + final gate), STOPS with exact
instructions wherever agent judgment is genuinely required, and prints a
`PHASE TIMINGS` line at every terminal exit; Phase 1 is interleaved. **Exit
codes (10/11/12/16/4/3/14/0 + 18 wait deadline, 19 scope mismatch, 26
`--wait` budget w/ run alive): `refs/gates.md` + `refs/orchestration.md`
§Single-invocation flow.** Most-misread code: **12 = pass 1 done, NOT
done-done — run `--finalize`**.

## Scripts

**`migrate-tableau.rb` and `migrate-tableau.py` compose the selected profile**
(STEP 1) — run exactly the entrypoint recorded in `doctor.json`. Invoke another
script directly **only when an orchestrator STOP
tells you to**. *(Redirect — E9 diet: the one-line index AND full per-script
contracts live in **`refs/script-map.md`**.)*

### The final gate (`assert-phase6-ran.rb` / `assert-phase6-ran.py`)

The conversion hard gate. *(Redirect — E9 diet: the full exit-code table moved
verbatim to **`refs/gates.md`**.)* Subagent flows MUST call this gate as their
final step; it exits 0 only when ALL gates pass.

---

## Prerequisites

> **⛔ NEVER hand-roll a signin `curl` — for Sigma OR Tableau.** The scripts
> are the sanctioned AND classifier-friendly route. **One signin attempt
> only** — Tableau Cloud invalidates a PAT after 4 failed signins;
> `get-tableau-token.sh` runs exactly once, never in a retry loop. Setup, env
> vars, token lifetimes, PAT-vs-MCP modes, hand-driven discovery:
> **`refs/environment.md` §Credentials**; endpoints + signin gotchas:
> `refs/tableau-rest.md`.

---

## The workflow (progressive disclosure)

This spine is the **map**: every phase, its one command, its gate, and the
refs to read **at that phase** (load nothing ahead of its phase). The
orchestrated path runs 0a–6 for you; reach for a phase ref when you drive a
phase by hand or need to understand why it stopped.

| # | Phase | One command / action | Gate → artifact | Read at this phase |
|---|---|---|---|---|
| −1 | Mission intake | write `mission.json` | inferred fields confirmed | `MIGRATION_REQUEST.md` |
| 0 | Preflight + intake | `bootstrap.sh`; `doctor.sh`; `intake.rb` | `bootstrap.json` + `doctor.json` + `connection.json` | `refs/environment.md`, `refs/model-fit.md`, `refs/orchestration.md` (contexts) |
| 0a | **Gap scan** (mandatory) | `scan-workbook-gaps.rb` | `gaps.json` + `formula-audit.json` + `source-object-census.json` — ❌ features → scout or `--force`; every source formula/object starts an accounting row | `refs/phase-0-scope.md`, `refs/coverage-matrix.md`, `refs/blending.md` (blends) |
| 0b | Destination + mode (ask) | `pick-destination.rb` | folder id + conversion mode | `refs/phase-0-scope.md` |
| 0c | Scope/cost sign-off | `estimate-cost.rb --workdir` | `cost-estimate.json` + run-state ack (`cost_estimate_acknowledged`) | `refs/phase-0-scope.md`, `refs/model-fit.md` §3, `refs/performance.md` |
| 1 | Discover the source | `tableau-discover.rb` (PAT) or MCP | `get-workbook.json`, `views/*.csv`, `.twb` | `refs/phase-1-discover.md`, `refs/tableau-rest.md`, `refs/multi-datasource.md`, `refs/object-model.md`, `refs/story-points.md`, `refs/extract-landing.md` |
| 1d | **🚧 Dashboard read + anchors** | `get-view-image` (solo) → **Read** → write `png-read.json` + `source-anchors.json` | 🚧 `png-read.json` (`assert-dashboard-read.rb`) + ≥5 anchors (final gate exit 18) | `refs/phase-1-discover.md`, `refs/source-anchors.md`, `refs/twb-zone-mapping.md` |
| 1.5 | Reuse an existing DM | `find-or-pick-dm.rb` | `dm-match.json` (reuse-first) | `refs/phase-1_5-dm-reuse.md`, `refs/modeling-strategy.md` |
| 2 | Warehouse column names | `discover-warehouse-columns.rb` | real column ids | `refs/phase-2-columns-filters.md`, `refs/column-gotchas.md` |
| 2.5 | View-level filters (mandatory) | detect from CSV distinct values | filters applied at the right grain | `refs/phase-2-columns-filters.md` |
| 3 | Build the DM spec | author → `validate-spec.rb --type datamodel` | clean `dm-spec.json` + `join-plan.json` probed (exit 23) + `semantic-edits.json` proven (exit 27) | `refs/phase-3-datamodel.md`, `refs/data-model-spec.md`, `refs/window-functions.md`, `refs/blending.md`, `refs/multi-datasource.md` |
| 4 | POST the DM + **read back** | `post-and-readback.rb --type datamodel` | `dm-ids.json` (server ids) | `refs/phase-4-post-dm.md` |
| 5 | Build workbook | `build-charts-from-signals.rb` → `post-and-readback` → `build-dashboard-layout.rb` → `put-layout.rb` | `preflight_lint` clean; body = metadata + `document{pages(metadata only),elements(flat),layout(required)}`; layout owns pages, places each element once, and is the **LAST write**; LOD/aggregation audits resolved | `refs/phase-5-workbook.md`, `refs/workbook-code-release-gaps.md`, `refs/chart-patterns.md`, `refs/layout-grid.md`, `refs/story-points.md` |
| 6 | **🚧 Parity + anchors + ground truth + visual** | `phase6-parity.rb`; `verify-anchors.rb`; ground-truth trio; then finalization and the gate sequence | 🚧 `parity-final.json` PASS + `anchors-verdict.json` + per-tile `numeric_parity` (exit 25) + recorded visual verdict + full `run-state.json` + `MIGRATION_REPORT.md` / `migration-result.json` with complete source-object and formula accounting | `refs/phase-6-parity.md`, `refs/source-anchors.md`, `refs/ground-truth-oracle.md`, `refs/gates.md`, `refs/migration-report-format.md`, `refs/blind-grader-brief.md`, `refs/visual-similarity.md`, `refs/control-parity.md`, `refs/orchestration.md` (verifier) |
| 5g | **RCF fidelity loop** | `fidelity-loop.rb` render → compare → fix until clean | 🚧 (default-on) `fidelity-ledger.json` no unresolved spec-fixable deltas (gate 8d) | `refs/phase-5g-rcf.md`, `refs/fidelity-rubric.md`, `refs/fidelity-recipes.md`, `refs/layout-visual-qa.md` |
| E | Enhance (opt-in) | `enhance-scan.rb` → `enhance-apply.rb` | cloned "— Enhanced" workbook | `refs/phase-e-enhance.md`, `refs/postpublish-interactivity.md` |
| — | Security RLS/CLS | detect always; apply opt-in | `apply_sigma_rls.py` | `refs/security-rls.md` |

On ANY nonzero exit or waiver: `refs/gates.md`. On a STOP naming a script:
`refs/script-map.md`. On a failure loop: `refs/troubleshooting.md`.

## Hard-gate kernels (full stanzas live in the phase refs + `refs/gates.md`)

- **🚧 Phase 1a — ANY numeric Tableau URL MUST go through `resolve-project.rb`
  first.** Exit 0 → migrate exactly what it lists; **exit 2 → STOP and ask
  with the printed candidates — never guess** (a wrong guess field-cost 6
  hours). Full rationale: `refs/phase-1-discover.md` §Phase 1a.
- **🚧 Phase 1d — dashboard-read + source-value anchors.** Read the source PNG
  → write `png-read.json` (EVERY tile + `kind`) AND transcribe printed numbers
  into `source-anchors.json` **exactly as printed**, ≥5, **anchor EVERY tile**
  (else `coverage_waivers` at transcription). Phase 6 verifies each anchor
  (final gate exit 18) — two field migrations shipped wrong numbers behind
  passing visual verdicts. Schema: `refs/source-anchors.md`; gate +
  draft-seeding: `refs/phase-1-discover.md`.
- **Phase 6f — your own read is the fix loop, NOT the verdict.** A pass needs
  a sha-bound **blind grade** from a FRESH context-free grader
  (`refs/blind-grader-brief.md`, exactly four parameters, NOTHING else),
  recorded via `record-visual-check.rb --blind-grade`. Protocol + finishing
  gate sequence: `refs/phase-6-parity.md` §Phase 6f. **Not done until
  `assert-phase6-ran.rb` exits 0**, then `verify-complete.rb` prints ✅ DONE.
- **Waiver discipline — waivers are for impossibilities, not obstacles.** >2
  quality waivers caps at YELLOW (exit 19); data-class residuals can never be
  waived; a third waiver means stop and fix. Verbatim: `refs/gates.md`.
- **Verdict model (PR-14) — GREEN / YELLOW / PARTIAL is derived, never
  self-reported.** GREEN needs an EMPTY `degradation-ledger.json`; any scope
  cut caps at PARTIAL; `verify-complete.rb` exits 6 if your report contradicts
  the derivation — quote the ledger verbatim. Full model: `refs/gates.md`.

---

## Security: RLS/CLS — `refs/security-rls.md`

RLS/CLS is **never silently dropped and never silently ported** — the converter
only detects and reports (`result.security[]`); this skill provisions + applies
AFTER the model is posted (non-empty → `security.json`; ask **Port**
(recommended) / Customize / Skip via `apply_sigma_rls.py`; **Skip is loud** —
all rows visible to everyone). Full flow + the
`USERNAME()`/`ISMEMBEROF`/`USERATTRIBUTE` mapping: `refs/security-rls.md`.
