---
name: tableau-to-sigma
description: >-
  Convert a Tableau datasource or workbook into a Sigma data model and matching
  dashboard. Use when the user has a Tableau datasource, TDS file, or Tableau
  workbook and wants to recreate it in Sigma. Discovery, calc-field translation,
  data model + workbook creation via REST API, layout generation, and parity
  verification — driven by `scripts/*.rb`.
user-invocable: true
---

# Tableau → Sigma Conversion

> ## ⛔ STEP 0 — MANDATORY environment bootstrap (before any other step)
> On the **first run on a machine**, run the ONE bootstrap command — idempotent,
> non-interactive, no admin, never echoes credentials:
> - macOS / Linux / Git Bash: `bash scripts/bootstrap.sh --workdir <WORK>`
> - Windows PowerShell: `powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 -WorkDir <WORK>`
>
> It verifies/activates/installs ruby + python3 (+ Pillow/numpy/requests) + node
> (user-scoped only — winget/scoop on Windows, brew/rbenv/fnm-aware elsewhere),
> persists creds from env vars (`setup.rb --from-env`), finishes with a doctor
> run (`doctor.json`), and writes the **bootstrap sentinel** (`bootstrap.json`).
> `intake.rb` and `migrate-tableau.rb` REFUSE to start without sentinel +
> doctor-green. **NEVER hand-install a runtime or edit PATH yourself** — if
> bootstrap reports no admin-free route, surface its message to the user and
> stop. Dry run: `--check` / `-Check` (reports what WOULD install, changes
> nothing). Details: `refs/environment.md`.

> ## ⛔ STEP 1 — THE ONE PATH (there is a single entry point; do not improvise one)
> After the bootstrap, **always run the orchestrator** — it chains every phase
> (discover → gates → DM → workbook → layout → two-pass parity → cleanup) in one
> process and self-gates:
> ```
> ruby scripts/migrate-tableau.rb --workbook "<name>" --connection <id>
> ```
> - **Pass the Tableau `/#/views/…` share URL straight to `--workbook` (quote it).**
>   The orchestrator resolves the workbook LUID from the URL's `contentUrl` slug
>   in process. Display names diverge from slugs ("High Risk Bets" vs
>   `HighRiskBets`), so **never** hand-roll `name:eq:` REST filters or page the
>   workbook list yourself — that field-cost a 500-workbook scan. Give it the URL.
> - **Flag cheatsheet — use the EXACT flags (do not guess or grep `opts.on`):**
>   `migrate-tableau.rb --out DIR` (the workdir flag is **`--out`**, not `--workdir`);
>   `validate-spec.rb <spec.json> --type dm|workbook` (spec is a **positional** arg, no `--spec`);
>   `put-layout.rb --workbook ID` (**not** `--workbook-id`), reading `SIGMA_API_TOKEN` from the env.
> - **Do NOT hand-drive the per-phase scripts, and do NOT hand-author DM/workbook
>   JSON, UNLESS an orchestrator STOP message explicitly routes you there** (e.g.
>   "CONVERTER STOP", the exit-4 workbook handoff). The script map is for
>   understanding and recovery, **not a menu** — à-la-carte scripts are the #1
>   way runs go inconsistent (the run-state audit silently no-ops when bypassed).
> - **"Done" is not something you decide — it is a file on disk.** The migration
>   is complete **only** when `ruby scripts/verify-complete.rb --workdir <WORK>`
>   exits 0 / prints ✅ DONE. A clean **PASS 1 (exit 12) is NOT done** — it means
>   "run `--finalize`". Never report success or write a completion summary before.
> - **This is a PRODUCTION migration, not a demo — regardless of who is watching
>   or why.** The bar is EXACT parity against the same warehouse, always. At a
>   wall you have exactly two moves: **follow the STOP/handoff the orchestrator
>   printed**, or **surface the blocker plainly and stop**. NEVER a third path:
>   no "lighter"/"simplified"/"good-enough-for-the-demo" builds, no dropping
>   tiles/filters/calcs to look finished. Cutting fidelity to escape a struggle
>   is a **worse failure than stopping**. If a lighter scope is wanted, the
>   **user** decides that explicitly — you never volunteer it.
> - **An orchestrator STOP is an instruction to YOU (the agent), not a handoff to
>   a human — keep going.** A routing exit (exit-4 workbook handoff, "CONVERTER
>   STOP") authorizes you to do the next step yourself: author the spec it names
>   and **re-enter the gated spine** (exit 4: `--reuse-dm <id> --wb-spec <path>`).
>   "The DM is posted" is not a finish line. Do not report done or wait for a
>   human at these STOPs; the only finish line is `verify-complete.rb` exit 0.
> - **At the exit-4 handoff, PATCH the auto-built `<WORK>/wb-spec.json` — do NOT
>   rewrite it.** Edit ONLY the fields/tiles it names, keeping every other
>   element **and every controlId** exactly as built, then re-enter with
>   `--reuse-dm <id> --wb-spec <WORK>/wb-spec.json`. A from-scratch rewrite
>   drifts controlIds from `control-scope.json` and fails control-lint wholesale
>   (the #1 way this handoff spirals). For a master-level calc, prefer
>   `--master-col` over hand-editing the tile.
> - **Credentials:** not on Claude Code → the orchestrator stops at step 0 telling
>   you to run `ruby scripts/setup.rb` once — do that (bootstrap runs it
>   `--from-env` when the vars are exported) rather than working around auth.

> **Model fit & vision requirements — `refs/model-fit.md`.** Pixel-fidelity
> claims require image input; very-large workbooks on non-top-tier models
> require asking the user once before proceeding. A text-only agent must record
> the visual verdict as not-executable (named degradation), never `pass`. Read
> `refs/model-fit.md` before Phase 0 on any multi-dashboard workbook.

Convert a Tableau datasource into a Sigma data model, then build a Sigma
workbook that mirrors the Tableau dashboard layout as closely as possible.

> **🚧 GATE convention.** A step marked **🚧 GATE** is backed by a script that
> *fails the run* if the step was skipped — not advisory. Every 🚧 GATE requires
> an **artifact** (a file on disk) and a downstream check that refuses to
> proceed without it. Current gates: **Phase 1d source dashboard-read**
> (`png-read.json` → `assert-dashboard-read.rb`, re-enforced inside
> `build-charts-from-signals.rb`), **Phase 6 source-parity** and **Phase 6f
> visual render** (`assert-phase6-ran.rb`).

**Read ALL of the following before replying or taking any action. Do not make assumptions about skill conventions, prompts, or global instructions — read the files.**
- `refs/operating-contract.md` — **READ FIRST.** The non-negotiable guardrails: obtain the source render + calcs, build from the source's own logic (not `SUM(col)`), render + value-check EVERY page against the source, never ship empty or waive silently, don't spin.
- `refs/modeling-strategy.md` — faithful reproduction is the DEFAULT (parity is the gate); an upstream OBT / Sigma-native materialization is an OPT-IN optimization for hot, join-heavy dashboards, re-verified against the same oracle. The converter never auto-flattens.
- `refs/composition-recipe.md` — composition pass (hero/panels/carded KPIs + brand-from-source), value-fidelity rules, controls/params rebuild, spec/API gotchas.
- `refs/column-gotchas.md` — column naming rules and special-character landmines
- `refs/data-model-spec.md` — data model JSON schema, element format, relationship format
- `refs/workbook-layout.md` — Ruby layout generation (mandatory), multi-series chart patterns
- `refs/story-points.md` — Tableau stories → one Sigma page per story point (`build-story-pages.rb`)
- `refs/blending.md` — data-blend detection + routing decision tree
- `refs/window-functions.md` — Tableau window/table calcs → Sigma-native window math
- `refs/coverage-matrix.md` — converter-wide Tableau→Sigma coverage matrix (static companion to `scan-workbook-gaps.rb`)
- `refs/source-anchors.md` — the **measured value bar**: `source-anchors.json` schema, canonicalization, worked example
- `refs/orchestration.md` — builder/verifier split, fresh contexts, converter backend, the still-manual list
- `refs/performance.md` — performance guidance
- `refs/script-map.md` — the full per-script detail catalog (flags, artifacts, exit codes)

**For canonical workbook spec shape** (element kinds, controls, formulas,
formatting), defer to the companion **`sigma-workbooks`** skill (in the
**`sigma-authoring`** plugin, same marketplace — install it alongside; this
converter assumes it). This skill restates only Tableau-conversion-specific
patterns.

---

## Step −1 — Mission intake (MANDATORY — before anything else)

Restate the user's request as `<workdir>/mission.json` (schema + rules in
**`MIGRATION_REQUEST.md`**): source, Sigma connection, destination, landing
target, workbook scope — each marked `stated` or `inferred`. **Any `inferred`
field → STOP and confirm with the user before building.** Field evidence: every
scope decision an agent invented has invalidated the entire run.
`MIGRATION_REQUEST.md` also carries the copy-paste kickoff template.

---

## Step 0 — Bootstrap + doctor (MANDATORY — the orchestrator gates on it)

Run the bootstrap FIRST (STEP 0 banner above). It ends with the doctor, which
writes `doctor.json` (to `~/.sigma-migration/` and `<WORK>/` with `--workdir`)
plus the `bootstrap.json` sentinel. `migrate-tableau.rb` refuses to start until
a **passing** `doctor.json` + sentinel exist — a broken environment stops here
with the exact fix instead of the run improvising around a missing runtime.
Re-verify anytime with `bash scripts/doctor.sh --workdir <WORK>` (PowerShell:
`scripts\doctor.ps1 -WorkDir <WORK>`). If the gate cannot pass in your
environment (e.g. a sandbox), waive it explicitly and name it in your report:
`migrate-tableau.rb … --skip-doctor-gate "<reason>"`.

## Step 0.1 — Front door: resolve the connection once (`scripts/intake.rb`)

Resolve the Sigma warehouse connection a SINGLE time so no phase free-searches
`/v2/connections` (the token sink):

```bash
ruby scripts/intake.rb --workdir <WORK> --tool tableau-to-sigma --mode live \
  [--connection <id>] [--name <connection-name-substring>] [--source "<workbook name>"]
```

> **Credentials are shell-neutral.** The Ruby/Python scripts mint Sigma tokens
> themselves from `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` (env or
> `~/.sigma-migration/env`) and auto-refresh — no `eval` step, any shell. For a
> hand-driven `curl`, mint explicitly: `python scripts/get_token.py --workdir
> <WORK>` writes `<WORK>/auth.json` (0600), read automatically by the scripts.
> (`eval "$(scripts/get-token.sh)"` still works in bash.)

It caches `<WORK>/connection.json` (the orchestrator reads it when
`--connection` is omitted — point `--out` at the same `<WORK>`) and writes
`intake.json`. Precedence: explicit `--connection` → cached →
`SIGMA_CONNECTION_ID` env → list once; with multiple connections it asks — it
never guesses. **Many connections?** Pass `--rank-workbook-id <LUID>`: intake
fingerprints the workbook's warehouse (type+host, no `.twb` download) and a
unique match auto-resolves, else it writes ranked `connection-candidates.json`
and asks (`scripts/rank-connections.rb` standalone; `--rank-twb <path>`
db-name tie-break). Never grep the `.twb` by hand to guess among connections.

## One command (orchestrated path)

> **⏱ Invocation rule (G2, field-caught):** a full pass runs **5–20+ minutes**.
> Launch it **in the background** (log you poll) or with a **tool timeout ≥ 20
> minutes** — the default 2-minute foreground Bash limit WILL kill the pass
> (exit 143). Check exit codes with portable `$?` (not bash-only `PIPESTATUS`).

```bash
# PASS 1 — discover → gap gate → DM-reuse scan → DM → workbook → layout → parity plan
ruby scripts/migrate-tableau.rb \
  --workbook "<name>" --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
  [--db <DB> --schema <SCHEMA>] [--name '<prefix>'] [--row-scale 1.5] \
  [--reuse-dm [ID]] [--force] [--yes]
# … pass 1 auto-fills <workdir>/parity-actuals.json (collect-parity-actuals.rb);
#   run the printed mcp-v2 queries for the REMAINING charts (pivot grids) only …
# PASS 2 — finalize: phase6 verify + cleanup-orphans + census-aware hard gate
ruby scripts/migrate-tableau.rb --workbook "<name>" \
  --finalize --actuals <workdir>/parity-actuals.json [--allow-missing-tiles N]
```

> **`--db`/`--schema` (always together) — there is NO default database.** The
> orchestrator resolves: your flags → the landing manifest → the workbook's own
> `<connection dbname=/schema=>` attributes — and **hard-stops asking** when
> none resolve. It never guesses: a fabricated pair 404s every table at DM POST.

> **🚧 Expect PASS 1 to hard-stop once for the Phase 1d dashboard-read.** The
> orchestrator fetches view CSVs but **cannot read the source dashboard PNG** —
> that's your job. On a cold run it aborts **before posting the DM** with
> "Phase 1d dashboard-read gate": fetch the dashboard PNG
> (`mcp__tableau__get-view-image`, solo), Read it, write `<workdir>/png-read.json`
> (every tile with its Sigma `kind`, + `text_elements`, `filter_shelf` — schema
> in `refs/phase-1-discover.md`), then **re-run the same PASS 1 command**
> (discovery artifacts are reused). PNG genuinely unavailable →
> `--skip-dashboard-read "<reason>"`.

> **Converter backend — LOCAL by default, zero config, never upload customer
> data silently.** A prebuilt converter ships at `converter/tableau.mjs` (pure
> function, runs via `node`, no network); a dev build wins when configured
> (`TABLEAU_MCP_BUILD`, `SIGMA_DATA_MODEL_MCP`, `scripts/dev/fetch-converter.sh`;
> refresh via `scripts/dev/vendor-converter.sh`, pinned in
> `converter/PROVENANCE.json`). The **hosted** converter uploads the `.twb` and
> is used **only** with explicit `--converter hosted` or
> `SIGMA_CONVERTER_ALLOW_HOSTED=1`. **No converter at all? Re-enter the GATED
> spine — never hand-POST raw specs:** author `dm-spec.json` (see
> `sigma-data-models`) + `wb-spec.json` (see `sigma-workbooks`; DM refs as
> `"__DM_ID__"` / `"__DM_ELEMENT__:<Name>"`, fact = `"__DM_ELEMENT__:__FACT__"`)
> and re-run with `--dm-spec <path> --wb-spec <path>` (or `--reuse-dm <id>
> --wb-spec <path>` when the DM is already posted). Full detail:
> `refs/orchestration.md` §Converter backend.

> **Parity is EXACT for warehouse-backed migrations — never blame "drift."**
> Sigma queries the **same warehouse** Tableau reads; a value gap is a real bug
> (missing view filter / NULL bucket / ungrouped table / wrong aggregate), not
> freshness. The drift-tolerance path (`extract-mode`) is **only** for
> `hasExtracts=true` workbooks and must be explicitly flagged. Do not declare
> GREEN while a table renders base-row-count detail or a NULL-dominant bucket —
> run `scripts/lib/preflight_lint.rb` on the spec first.

Chains the scripted spine (discover → scan-workbook-gaps → discover-columns →
find-or-pick-dm → DM build/validate/post → build-charts-from-signals → workbook
post-and-readback → build-dashboard-layout + put-layout → phase6-parity →
cleanup-orphan-workbooks + assert-phase6-ran) and STOPS with exact instructions
wherever agent judgment is genuinely required. Phase 1 is interleaved
(Tableau-side + Sigma-side lanes join before anything consumes discovery
output); a `PHASE TIMINGS` line prints at every terminal exit. Exit codes:
`10` = OPEN QUESTIONS (re-run with `--yes`/`--answers`), `11` = ❌-unhandled
gap-scan features (gap-scout or `--force`), `12` = pass 1 done, parity PENDING
(collect mcp-v2 actuals, then `--finalize`), `16` = pass 1 built + POSTed but
`<workdir>/manual-residues.json` carries `unbuilt` window/table-calc residue(s)
a dashboard tile plots — build each from the printed checklist, set
`status:"built"`, then `--finalize` (the final gate refuses GREEN on `unbuilt`
residues, exit 22; waiver `--accept-manual-residues "<calc,...>"`,
budget-counted), `4` = DM posted but the workbook layer needs an agent-authored
spec — re-enter with `--reuse-dm <id> --wb-spec <path>` (never hand-POST),
`3` = a gate failed, `14` = migration GREEN + Phase E proposals pending,
`0` = ALL gates green (only reachable via `--finalize`).
DM-reuse is **reuse-first** (auto-reuses a covering DM, skipping the POST);
`--reuse-dm <id>` pins one, `--skip-reuse-scan` forces build-new. Optional
`--enhance [--enhance-accept <ids|all-low-risk>]` runs Phase E after all gates
are green. **Still manual by design** (pivot-grid parity actuals,
empty-view-CSV recovery, `--master-col` overrides, gap-scout escalations,
DM-reuse shape preflight): `refs/orchestration.md` §Still manual.

## Scripts

**`migrate-tableau.rb` composes everything** (STEP 1) — the only entry point
you run cold. Invoke another script directly **only when an orchestrator STOP
tells you to**. One line each below; the FULL contract of every script (flags,
artifacts, exit codes, field rationale) is in **`refs/script-map.md`** — open
it when a STOP routes you to a script.

| Script | One line |
|---|---|
| `migrate-tableau.rb` | The one command — chains the whole gated spine; stops with exact instructions |
| `verify-complete.rb` | The single offline "are we done?" check — ✅ DONE only on gate-green; re-derives the verdict ledger (exit 6 on contradiction) |
| `lib/offramp.rb` + `offramps.jsonl` | Observability trail of every golden-path exit |
| `setup.rb` / `setup-tableau.rb` | One-time Sigma / Tableau credential setup (`--from-env` = non-interactive; bootstrap runs them) |
| `get-token.sh` / `get_token.py` | Sigma token mint (bash / shell-neutral twin → `<WORK>/auth.json`) |
| `get-tableau-token.sh` / `get-tableau-token.py` | Tableau PAT signin (bash / shell-neutral twin) |
| `bootstrap.sh` / `bootstrap.ps1` | Step-0 environment bootstrap → doctor-green + sentinel (`--check` dry run) |
| `doctor.sh` / `doctor.ps1` | Env check; writes the `doctor.json` fingerprint the orchestrator gates on |
| `assert-doctor-ran.rb` | 🚧 GATE — refuse to run without passing `doctor.json` + bootstrap sentinel |
| `assert-wb-refs-resolve.rb` | 🚧 GATE — every workbook `[Element/Column]` ref must exist in the live DM (waive `--skip-ref-check "<reason>"`) |
| `tableau-discover.rb` | PAT-mode Phase 1 discovery in one pooled CLI (13.7–18.9s on the 7-view reference) |
| `resolve-project.rb` | Phase 1a numeric-URL resolver (⛔ no guessing; exit 2 = STOP and ask) |
| `scan-workbook-gaps.rb` | Phase 0a (mandatory) gap scan → `gaps.json` / `gaps-report.md` + `blend-plan.json` |
| `gap-scout.md` | Phase 0a-scout subagent protocol for ❌ Unhandled gaps |
| `validate-sigma-formula.rb` / `scout-validate-and-persist.rb` | Scout primitives: probe a candidate formula; persist learned rules / escalations |
| `escalate-gap.py` | Opt-in issue filer (dry-run by default; `--yes` to file) |
| `learned-rules.rb` | Merges `learned/starter-rules.yaml` + `~/.tableau-to-sigma/learned-rules.yaml` |
| `parse-twb-layout.rb` | `.twb` → per-dashboard zone list + `*-meta.json` (+ `story-plan.json` for stories) |
| `build-charts-from-signals.rb` | Zones + CSVs + master map → Sigma chart specs; writes `coverage.json`; 🚧 requires `png-read.json` |
| `extract-custom-sql.rb` / `resolve-published-ds.rb` / `hydrate-custom-sql.rb` | Custom-SQL + published-DS (sqlproxy) resolution/hydration — never a phantom table |
| `lib/tableau_rest.rb` | Tableau REST wrapper |
| `estimate-cost.rb` | Phase 0c scope + token-cost estimate → `cost-estimate.json` + run-state ack |
| `fetch-view-data.rb` | View CSVs → signals manifest |
| `discover-warehouse-columns.rb` / `probe-custom-sql-columns.rb` | Phase 2 real column ids; 404 → catalog sync, then Custom-SQL probe |
| `find-prior-cache.rb` | Reuse cached discovery artifacts from prior runs |
| `remap-wb-spec-to-dm-ids.rb` | Re-point a cached wb-spec at a re-POSTed DM's new ids |
| `extract-calc-fields.rb` | Phase 1e calc fields (+ formulas) → `calc-fields.json` |
| `validate-spec.rb` | DM/workbook spec validator (`--type`, `--dm-context`) |
| `post-and-readback.rb` | POST + GET-back a spec; column-type guard, layout+control lint, same-workbook PUT discipline (exit 7 unless STOP-authorized / `--allow-manual-spec`) |
| `lib/preflight_lint.rb` | MANDATORY pre-POST lint (T1/T2 grouping, C1–C3 control shapes) |
| `put-layout.rb` | Apply layout XML to an existing workbook |
| `auto-parity-plan.rb` / `verify-parity.rb` | Phase 6a plan + 6c diff (`--extract-mode` only for hasExtracts=true) |
| `probe-equivalence.rb` | MANDATORY proof for any structural edit (join drop / collapse / filter rewrite) → `semantic-edits.json`; mismatch = FATAL; `--withdraw` for unapplied edits |
| `derive-ground-truth.rb` → `run-ground-truth.rb` → `verify-ground-truth.rb` | Phase 6 tile-grain warehouse oracle → `ground-truth-plan.json` + per-tile `numeric_parity` |
| `verify-anchors.rb` | Phase 6 measured value bar → `anchors-verdict.json` |
| `assert-phase6-ran.rb` | **The conversion hard gate** — see the gate table below |
| `fidelity-loop.rb` | Phase 5g RCF mechanics (init/render/record/apply-patch/resolve/status) → `fidelity-ledger.json` |
| `assert-run-state.rb` | Phase-chain ledger audit (`run-state.json`; `--skip-run-state "<reason>"`) |
| `probe-controls.rb` | Runtime control flip test (gate 7b) → `probe-controls/probe-results.json` |
| `cleanup-orphan-workbooks.rb` | Delete spec-iteration orphans; writes `cleanup-marker.json` |
| `build-dashboard-layout.rb` | MANDATORY Phase 5d layout XML from zones + `wb-ids.json`; emits `layout-census.json` |
| `build-story-pages.rb` | Story workbooks: one Sigma page per story point |
| `export-chart-png.rb` | Phase 6d drill-down only — the primary gate is full-dashboard vs full-dashboard |
| `pick-destination.rb` | Phase 0b destination list/create |
| `find-or-pick-dm.rb` / `inspect-dm-shape.rb` | Phase 1.5 reuse scan → `dm-match.json`; 1.5b shape preflight → `dm-denorm-plan.json` |
| `scan-customer-style.rb` | Phase 0c house-style signals |
| `dev/phase-timer.sh` | Dev/profiling only — never in customer conversions |
| `lib/layout.rb` | Layout-XML helpers |
| `enhance-scan.rb` / `enhance-apply.rb` | Phase E (opt-in) scan + accept-only clone-first apply |

### The final gate (`assert-phase6-ran.rb`) — exit-code table (load-bearing)

Exits 0 only when ALL pass. Full prose per gate: `refs/script-map.md` +
`refs/phase-6-parity.md`.

| Exit | Gate | Fails when / escape |
|---|---|---|
| 1 | parity sentinel | `parity-final.json` missing |
| 2 | parity | FAIL / extract-mode-without-flag / `charts_total==0` unbacked |
| 4 | orphans | uncleaned posted workbooks (`cleanup-orphan-workbooks.rb`) |
| 5 | live columns | any live `type=error` column |
| 6 | layout | no non-empty top-level layout applied |
| 7 | tile census | unexplained missing zones / `--allow-missing-tiles N` |
| 8 | layout lint | `lib/layout_lint.rb` / `--skip-layout-lint` |
| 9 | control lint | `lib/control_lint.rb`, `control-scope.json` / `--skip-control-lint` |
| 10 | visual render | no `sigma-render.png` or `screenshots/_manifest.json` / `--skip-visual-gate "<reason>"` |
| 13 | visual verdict | unrecorded or self-attested pass — needs sha-bound `blind_grade` (PR-9) or recorded `--no-vision-waiver` / `--skip-visual-comparison "<reason>"` |
| 14 | layout fill | `layout-census.json` dropped tile or `grid_fill_pct < --min-grid-fill` / `--skip-layout-fill "<reason>"` |
| 15 | 8d RCF ledger | unresolved spec-fixable deltas (`--require-fidelity-ledger`, default-on at `--finalize`); `--accept-residuals id,id` — data-class NEVER |
| 18 | 13 anchors | `source-anchors.json` <5 anchors or failing `anchors-verdict.json`; also `--skip-parity-gate` without passing anchors / `--skip-anchors-gate "<reason>"` |
| 19 | waiver budget | >2 quality waivers → YELLOW cap; no escape flag |
| 20 | 14 visual similarity | `visual-similarity.py` floor fail / `--skip-visual-similarity "<reason>"` |
| 21 | 7b control flip | control doesn't filter live (`probe-controls.rb`), or no evidence on an enforced run / `--skip-flip-test "<reason>"` → `--skip-control-flip` (budget-counted) |
| 22 | 15 manual residues | `manual-residues.json` still `unbuilt` / `--accept-manual-residues "<calc,...>"` (budget-counted) |
| 23 | 16 join cardinality | `join-plan.json` unprobed / non-unique Lookup target (`probe-join-keys.rb`, `--resolve <i> --how <preaggregated\|waived> --reason`); no skip flag |
| 24 | 17 LOD ledger | `lod-audit.json` suspect-alias / silently-dropped unresolved (`audit-lod-calcs.rb`); no skip flag |
| 25 | 18 ground truth | displayed tile with no `numeric_parity` match and no `coverage_waivers` entry; `diverge`/`conflict` NEVER waivable; no skip flag |
| 26 | 19 agg semantics | `agg-semantics.json` unresolved additive-over-preagg / countd-as-sum / preagg-ratio (`audit-agg-semantics.rb --how <reaggregated\|n/a\|faithful-to-source>`); no skip flag |
| 27 | 20 semantic edits | `semantic-edits.json` unproven or `match:false` (`probe-equivalence.rb`); NO waiver — revert or redesign |
| 28 | 21 chart-kind parity | live element family ≠ verified `png-read.json` kind; substitutions recorded as `kind_waivers` at read time |
| 30 | 4b layout ran | run-state shows the layout phase never entered |
| 31 | 7c controls census | source control never built, undeclared in `control-scope.json` and unnamed in `controls-waivers.json`; no skip flag |

On the all-embedded (`charts_total==0`) ANCHORS-ORACLE path, substitution also
requires per-displayed-tile anchor coverage (`anchor_coverage.covered ==
displayed`, or `coverage_waivers` naming each uncovered tile). Subagent flows
MUST call this gate as their final step.

---

## Prerequisites

> **⛔ NEVER hand-roll a signin `curl` — for Sigma OR Tableau.** Managed
> machines' permission classifiers block secret-bearing raw `curl`, and
> `curl -sf` hides the failure (a field session lost ~15 minutes to it). The
> scripts are the sanctioned AND classifier-friendly route: `setup.rb` /
> `setup-tableau.rb` once, in-process token minting everywhere, and
> `get_token.py` / `get-tableau-token.py` for hand-driven REST.

### Sigma credentials

`ruby scripts/setup.rb` once (bootstrap runs it `--from-env` when the vars are
exported). Writes `~/.claude/settings.json` (Claude Code auto-loads) and
`~/.sigma-migration/env` (neutral, auto-sourced by the scripts under any
agent). Required: `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, `SIGMA_CLIENT_SECRET`.
Tokens live ~1h — scripts auto-refresh; for hand-driven calls,
`python scripts/get_token.py --workdir <WORK>` (any shell). Shell footguns
(subshell `eval`, inline-python quoting): `refs/troubleshooting.md` §Shell.

### Tableau access — two modes

**Prefer the API/PAT path** — measured 61.8s serial → **13.7–18.9s** pooled on
the 7-view reference; the MCP is the **no-PAT fallback only** (each MCP fetch
is a separate agent turn).

| Mode | When | Setup |
|---|---|---|
| **PAT (REST)** — preferred | A Tableau PAT is available; only path to `.twb` content | `ruby scripts/setup-tableau.rb` once |
| **MCP** — fallback | No PAT, `mcp__tableau__*` tools loaded | None — host handles auth |

**PAT mode:** `migrate-tableau.rb` needs no token step (in-process mint, works
in PowerShell). Hand-driven only: `eval "$(scripts/get-tableau-token.sh)"`
(bash) or `python scripts/get-tableau-token.py --print-token`, then
`ruby scripts/tableau-discover.rb --workbook-id <luid> --out <WORK> [--pool N]`
→ same artifacts as MCP-driven Phase 1 in one run (workbook JSON, `.twb`,
`ds-metadata.json`, `graphql-fields.json`, `views/*.csv`, dashboard PNG,
`timings.json`). `--datasource-name`/`--datasource-luid` optional (auto-detect;
`--no-auto-ds` disables; LUID must be the full UUID). Pool mechanics + why 5:
`refs/tableau-rest.md` §fetch pool. Endpoint inventory: `refs/tableau-rest.md`.

> **One signin attempt only.** Tableau Cloud invalidates a PAT after 4 failed
> signins. `get-tableau-token.sh` runs exactly once; never wrap it in a retry loop.

---

## The workflow (progressive disclosure)

This spine is the **map**: every phase, its one command, its gate. The **how /
why / gotchas live in `refs/phase-*.md`** — open the ref for the phase you're
on, when you're on it (the flat version of this skill made agents drop steps).

| # | Phase | One command / action | Gate → artifact | Detail |
|---|---|---|---|---|
| 0 | Preflight + intake | `bootstrap.sh`; `doctor.sh`; `intake.rb` | `bootstrap.json` + `doctor.json` + `connection.json` | *(spine ↑)* |
| 0a | **Gap scan** (mandatory) | `scan-workbook-gaps.rb` | `gaps.json` — ❌ features → scout or `--force` | `refs/phase-0-scope.md` |
| 0b | Destination + mode (ask) | `pick-destination.rb` | folder id + conversion mode | `refs/phase-0-scope.md` |
| 0c | Scope/cost sign-off | `estimate-cost.rb --workdir` | `cost-estimate.json` + run-state ack (`cost_estimate_acknowledged`) | `refs/phase-0-scope.md` |
| 1 | Discover the source | `tableau-discover.rb` (PAT) or MCP | `get-workbook.json`, `views/*.csv`, `.twb` | `refs/phase-1-discover.md` |
| 1d | **🚧 Dashboard read + anchors** | `get-view-image` (solo) → **Read** → write `png-read.json` + `source-anchors.json` | 🚧 `png-read.json` (`assert-dashboard-read.rb`) + ≥5 anchors (final gate exit 18) | `refs/phase-1-discover.md`, `refs/source-anchors.md` |
| 1.5 | Reuse an existing DM | `find-or-pick-dm.rb` | `dm-match.json` (reuse-first) | `refs/phase-1_5-dm-reuse.md` |
| 2 | Warehouse column names | `discover-warehouse-columns.rb` | real column ids | `refs/phase-2-columns-filters.md` |
| 2.5 | View-level filters (mandatory) | detect from CSV distinct values | filters applied at the right grain | `refs/phase-2-columns-filters.md` |
| 3 | Build the DM spec | author → `validate-spec.rb --type datamodel` | clean `dm-spec.json` + `join-plan.json` probed (exit 23) + `semantic-edits.json` proven (exit 27) | `refs/phase-3-datamodel.md` |
| 4 | POST the DM + **read back** | `post-and-readback.rb --type datamodel` | `dm-ids.json` (server ids) | `refs/phase-4-post-dm.md` |
| 5 | Build the workbook | `build-charts-from-signals.rb` → `post-and-readback` → `build-dashboard-layout.rb` → `put-layout.rb` | `preflight_lint` clean; **layout is the LAST write**; `lod-audit.json` (exit 24) + `agg-semantics.json` (exit 26) resolved | `refs/phase-5-workbook.md` |
| 6 | **🚧 Parity + anchors + ground truth + visual** | `phase6-parity.rb`; `verify-anchors.rb`; ground-truth trio; then the gate sequence | 🚧 `parity-final.json` PASS + `anchors-verdict.json` + per-tile `numeric_parity` (exit 25) + recorded visual verdict + full `run-state.json` | `refs/phase-6-parity.md`, `refs/source-anchors.md`, `refs/ground-truth-oracle.md` |
| 5g | **RCF fidelity loop** | `fidelity-loop.rb` render → compare → fix until clean | 🚧 (default-on) `fidelity-ledger.json` no unresolved spec-fixable deltas (gate 8d) | `refs/phase-5g-rcf.md` |
| E | Enhance (opt-in) | `enhance-scan.rb` → `enhance-apply.rb` | cloned "— Enhanced" workbook | `refs/phase-e-enhance.md` |
| — | Security RLS/CLS | detect always; apply opt-in | `apply_sigma_rls.py` | `refs/security-rls.md` |
| — | Telemetry (final) | `report-telemetry.py` | `telemetry-sent.json` | *(spine ↓)* |

> **The orchestrated path runs 0a–6 for you** and stops with exact instructions
> where judgment is required. Reach for the per-phase refs when you drive a
> phase by hand or need to understand why it stopped.

---

## Phase stanzas (open the ref for the one you're on — READ IT AT THAT MOMENT)

### Phase 0 — scope: gap scan, destination, mode, cost — `refs/phase-0-scope.md`
`scan-workbook-gaps.rb` on the `.twb` **before anything else** (❌-unhandled →
gap-scout or `--force`); then `pick-destination.rb`, conversion mode, cost
estimate. **Then the model-fit checkpoint** (`refs/model-fit.md` §3):
large/very-large (or >1 dashboard / >30 zones / any ❌ rows / >50 calcs) on a
non-top-tier model → ask the user once; never silently proceed on very-large.

### Phase 1 — discover the source — `refs/phase-1-discover.md`
PAT mode: `tableau-discover.rb` (one pooled run). MCP is the no-PAT fallback.
Calc fields via `extract-calc-fields.rb`, Custom SQL via `extract-custom-sql.rb`.

> **🚧 GATE — Phase 1a: ANY numeric Tableau URL (project or workbook) MUST go
> through `resolve-project.rb` first.** The number is a vizportal URL id the
> REST API cannot resolve. Exit 0 → migrate exactly what it lists. **Exit 2 →
> STOP and ask the user with the printed candidates — never guess** (a wrong
> guess field-cost 6 hours on the wrong project). `/views/<slug>/<view>` share
> links: paste the whole URL as `--workbook "<url>"` — never hand the slug to a
> name lookup. Full rationale + query shapes: `refs/phase-1-discover.md`,
> `refs/tableau-rest.md`.

> **🚧 GATE — Phase 1d dashboard-read + source-value anchors.** Read the source
> dashboard PNG (solo `get-view-image`) → write `png-read.json` (EVERY tile +
> `kind`; `build-charts-from-signals.rb` refuses without it) AND transcribe the
> printed numbers into `source-anchors.json` **exactly as printed** (`"12,345B"`,
> never `12345`): every KPI, top-3 of every ranked list, one bucket value per
> chart, ≥5 total, **anchor EVERY tile** (a tile with no anchorable value gets a
> `coverage_waivers` entry at transcription time). Phase 6 verifies each anchor
> against the LIVE exports (`verify-anchors.rb`); the final gate fails (exit 18)
> on missing/unverified anchors whenever a source PNG exists. Two field
> migrations shipped wrong numbers behind passing visual verdicts — this is the
> fix. Schema + rules + worked example: `refs/source-anchors.md`. Escapes:
> `--skip-dashboard-read "<reason>"`, `--skip-anchors-gate "<reason>"` (budget-counted).

### Phase 1.5 — reuse an existing DM (do this first) — `refs/phase-1_5-dm-reuse.md`
`find-or-pick-dm.rb` scores existing DMs (reuse-first skips Phases 2–3);
differently-shaped reuse → run 1.5b `inspect-dm-shape.rb`.

### Phase 2 + 2.5 — warehouse columns + view filters — `refs/phase-2-columns-filters.md`
`discover-warehouse-columns.rb`; on 404 force a catalog sync
(`POST /v2/connections/{id}/sync`) and retry before the Custom-SQL probe. Then
**detect view-level filters (mandatory)** by diffing CSV distinct values, and
apply at the correct grain. Relative-date → native ROLLING mapping: same ref.

### Phase 3 — build the DM spec — `refs/phase-3-datamodel.md`
Author the spec (warehouse-table element for plain columns, `sql` elements for
window/LOD calcs), translate calc fields, `validate-spec.rb --type datamodel`
before POST. Schema: `refs/data-model-spec.md`. Structural edits need
`probe-equivalence.rb` proof; Lookups need `join-plan.json` probes.

### Phase 4 — POST the DM + read back — `refs/phase-4-post-dm.md`
`post-and-readback.rb --type datamodel` POSTs then GETs back the server ids the
workbook binds to (column-type guard aborts on `type=error`).

### Phase 5 — build the Sigma workbook — `refs/phase-5-workbook.md`
`build-charts-from-signals.rb` (🚧 requires `png-read.json`) →
`preflight_lint.rb` (mandatory) → `post-and-readback.rb --type workbook` →
`build-dashboard-layout.rb` → `put-layout.rb`. **Layout is the LAST write** — a
bare spec PUT wipes it. Then compile-check every element.

### Phase 6 — 🚧 parity + anchors + visual verification (hard-gated) — `refs/phase-6-parity.md`
`phase6-parity.rb` diffs Sigma actuals vs Tableau (EXACT for warehouse-backed;
`--extract-mode` only for hasExtracts=true). **Phase 6f visual is mandatory:**
render the full Sigma page and Read it against the source PNG. **Your own read
is the fix loop, not the verdict** — when you believe it matches, spawn a
**FRESH context-free blind grader** (prompt = `refs/blind-grader-brief.md` with
exactly four parameters: source PNG, render PNG, rubric path, output path;
**pass NOTHING else**), then
`record-visual-check.rb --blind-grade <WORK>/blind-grade.json` — a pass without
a passing blind grade is REFUSED (gate 8b re-verifies hash-bound). FAIL →
record `divergent`, fix, re-render, re-grade fresh. No vision-capable subagent
→ `--no-vision-waiver "<reason>"` (budget-counted). Full protocol +
no-standalone-views (anchors+warehouse oracle) + similarity floor:
`refs/phase-6-parity.md`. Finish with the gate sequence:
```bash
ruby scripts/assert-dashboard-read.rb --workdir <WORK>                  # 🚧 Phase 1d belt
ruby scripts/verify-anchors.rb --workdir <WORK> --workbook-id <wb>      # 🚧 measured value bar
ruby scripts/assert-run-state.rb --workdir <WORK>                       # 🚧 phase-chain audit
ruby scripts/assert-phase6-ran.rb --workdir <WORK> --workbook-id <wb>   # 🚧 hard gate — exit 0
```
**Not done until `assert-phase6-ran.rb` exits 0** (stamps
`phase6-success.json`, run-scoped — quote its workbook id + run id verbatim),
then `verify-complete.rb` prints ✅ DONE.

> **Waiver discipline — waivers are for impossibilities, not obstacles.** Every
> `--skip-*` / `--allow-*` / `--accept-*` / `--min-pass-rate <1` flag attests a
> verification could NOT run — not a lever to turn a red gate green. The gate
> stamps `waivers` + `waiver_count` into `parity-final.json`; **more than 2
> quality waivers caps the migration at YELLOW** (exit 19; `--skip-telemetry-gate`
> and the sanctioned builder→verifier `--skip-visual-comparison` are policy
> exclusions), and **data-class fidelity residuals can never be waived**.
> Reaching for a third waiver means: stop and fix.

> **Verdict model (PR-14) — GREEN / YELLOW / PARTIAL.** Every gate run derives
> `degradation-ledger.json` from the artifacts (`lib/degradation_ledger.rb` —
> mechanical, never self-reported) and prints ONE verdict with the ledger
> inline. **GREEN requires an EMPTY ledger.** Any non-scope-cut entry (or
> exceeded budget) → **YELLOW**. **Any scope cut caps at PARTIAL.** Stamped into
> `phase6-success.json` + `parity-final.json`; `verify-complete.rb` re-derives
> offline and **fails (exit 6) if your report contradicts it** — quote the
> ledger verbatim, never a verdict it doesn't support.

### Phase 5g — RCF (render-compare-fix) fidelity loop — `refs/phase-5g-rcf.md`
`fidelity-loop.rb` render → Read vs source + score (`refs/fidelity-rubric.md`)
→ `record` each delta → fix from `refs/fidelity-recipes.md` + `apply-patch`
(single layout-preserving PUT) → loop until `status` is clean. DEFAULT-ON gate
8d (exit 15); `--rcf-passes 0` opts out but records the named
`--skip-fidelity-gate` waiver (budget-counted). Layout build also emits
`layout-arrangement.json` (gate 8e, WARN this release, `--require-arrangement`
to enforce); gate 4b (exit 30) fails a run whose ledger shows layout never ran.

### Phase E — enhance (opt-in) — `refs/phase-e-enhance.md`
After all gates green: `enhance-scan.rb` proposes; `enhance-apply.rb` applies
only accepted candidates to a **cloned** workbook (parity artifact never mutated).

### Troubleshooting — `refs/troubleshooting.md`
Common failure modes + fixes (incl. shell footguns): `refs/troubleshooting.md`.

---

## Security: Row- & Column-Level Security (RLS/CLS) — `refs/security-rls.md`

RLS/CLS is **never silently dropped and never silently ported** — the converter
only detects and reports (`result.security[]`, `USERNAME()`/`ISMEMBEROF`/
`USERATTRIBUTE` → `CurrentUserEmail()`/`CurrentUserInTeam`/
`CurrentUserAttributeText`); this skill provisions + applies AFTER the model is
posted. Non-empty `result.security` → write `security.json`, summarize, ask
**Port** (recommended) / Customize / Skip, then `python3
scripts/apply_sigma_rls.py --from-security security.json --dm-id <id>` (plan by
default; `--provision --apply` to execute), assign membership. **Skip is loud**
— all rows visible to everyone; confirm first. Full flow: `refs/security-rls.md`.

---

## Telemetry (after the final gate passes)

**Tell the user this in the conversation before running anything:**

> "Migration complete. Before I wrap up, I'd like to send an anonymous usage ping so we can track which migration skills are being used. It records: tool name, your Sigma region, an anonymized org fingerprint (a hash of your client ID — not the credential itself), migration duration, and success. No workbook names, SQL, column names, or any customer data is included. See [TELEMETRY.md](https://github.com/twells89/sigma-migration-telemetry/blob/main/TELEMETRY.md) for the exact payload. Just say 'skip' if you'd prefer not to send it."

If the user does not object, run:

```bash
python3 scripts/report-telemetry.py --tool tableau-to-sigma --duration <elapsed_seconds> --workdir <run-dir> [--mode live|file|both]
# on failure:        python3 scripts/report-telemetry.py --tool tableau-to-sigma --duration <elapsed_seconds> --workdir <run-dir> --failed
# if the user declines: python3 scripts/report-telemetry.py --tool tableau-to-sigma --workdir <run-dir> --declined
# --workdir writes telemetry-sent.json, the marker the GREEN telemetry gate (assert-telemetry-ran.rb) requires.
```
