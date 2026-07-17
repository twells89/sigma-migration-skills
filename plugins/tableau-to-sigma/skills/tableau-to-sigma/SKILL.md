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

> ## ⛔ STEP 0 — MANDATORY environment preflight (do this before any other step)
> On the **first run in a session**, run the doctor and read its output **before**
> touching Tableau discovery or the converter:
> - macOS / Linux / Git Bash: `bash scripts/doctor.sh`
> - Windows PowerShell: `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1`
>
> It checks Ruby/Python/Node/bash and flags the Python "Store stub" + CRLF with exact fixes.
> **If the doctor reports a missing runtime (exit 1): STOP.** Present its fix to the user
> and get their OK — **do not** self-install a runtime, download an unpinned binary, or
> edit the machine's PATH on your own initiative. That is a hard-to-reverse, outward-facing
> action to confirm first, not improvise mid-run. Node in particular: on locked-down
> Windows use the no-admin path in `refs/environment.md` (#5), and let the **user** run it.
> Details: `refs/environment.md`.

> ## ⛔ STEP 1 — THE ONE PATH (there is a single entry point; do not improvise one)
> After the doctor, **always run the orchestrator** — it chains every phase
> (discover → gates → DM → workbook → layout → two-pass parity → cleanup) in one
> process and self-gates:
> ```
> ruby scripts/migrate-tableau.rb --workbook "<name>" --connection <id>
> ```
> - **Pass the Tableau `/#/views/…` share URL straight to `--workbook` (quote it).**
>   The orchestrator resolves the workbook LUID from the URL's `contentUrl` slug in
>   process (`find_workbook_by_content_url`). A workbook's display name almost always
>   differs from its slug ("High Risk Bets" vs `HighRiskBets`), so **never** hand-roll
>   `name:eq:` REST filters or page the workbook list to find the LUID yourself — that
>   field-cost a full 500-workbook scan on a cold run. Just give it the URL.
> - **Flag cheatsheet — use the EXACT flags (do not guess or grep `opts.on`).** When a
>   STOP routes you to a script directly, these are the ones people trip on:
>   `migrate-tableau.rb --out DIR` (the workdir flag is **`--out`**, not `--workdir`);
>   `validate-spec.rb <spec.json> --type dm|workbook` (spec is a **positional** arg, no `--spec`);
>   `put-layout.rb --workbook ID` (**not** `--workbook-id`) and it reads `SIGMA_API_TOKEN`
>   from the env — `export SIGMA_API_TOKEN=$(ruby -rjson -e 'print JSON.parse(File.read(ENV["WORK"]+"/auth.json"))["SIGMA_API_TOKEN"]')` first.
> - **Do NOT hand-drive the per-phase scripts, and do NOT hand-author DM/workbook
>   JSON, UNLESS an orchestrator STOP message explicitly routes you there** (e.g.
>   "CONVERTER STOP", the exit-4 workbook handoff). The per-phase table further
>   down is a **map for understanding and recovery, not a menu** — picking scripts
>   off it à la carte is the #1 way runs go inconsistent (the run-state audit
>   silently no-ops when you bypass the orchestrator).
> - **"Done" is not something you decide — it is a file on disk.** The migration
>   is complete **only** when this exits 0:
>   ```
>   ruby scripts/verify-complete.rb --workdir <WORK>
>   ```
>   A clean **PASS 1 (exit 12) is NOT done** — it means "run `--finalize`". Never
>   report success, hand off, or write a completion summary until
>   `verify-complete.rb` prints ✅ DONE. Nothing else counts as green.
> - **This is a PRODUCTION migration, not a demo — regardless of who is watching
>   or why (hackathon, POC, "just a demo", a `…-demo/` folder in a path).** The bar
>   is EXACT parity against the same warehouse (see the parity note below), always.
>   When you hit a wall, you have exactly two moves: **follow the STOP/handoff the
>   orchestrator printed**, or **surface the blocker plainly and stop.** You may
>   NEVER take a third path — do **not** propose or build a "lighter", "simplified",
>   "good-enough-for-the-demo", "quick version", or reduced-scope workbook to get
>   past a blocker, and do not drop tiles/filters/calcs to make a run look finished.
>   Cutting fidelity to escape a struggle is a **worse failure than stopping**: it
>   ships something that looks done but silently isn't. If a lighter scope is
>   genuinely wanted, the **user** decides that explicitly — you never volunteer it.
> - **An orchestrator STOP is an instruction to YOU (the agent), not a handoff to a
>   human — keep going.** A non-zero exit that routes you (e.g. the **exit-4 workbook
>   handoff**, "CONVERTER STOP") is the sanctioned authorization to do the next step
>   yourself: author the spec it names and **re-enter the gated spine** (for exit 4:
>   `--reuse-dm <id> --wb-spec <path>`). "The data model is posted" is **not** a
>   finish line — a DM without its workbook is an incomplete migration. Do not report
>   done, ask the user to build the workbook, or wait for a human at these STOPs;
>   the only finish line is `verify-complete.rb` exit 0 (above).
> - **Credentials:** if you are **not** on Claude Code, the orchestrator will stop
>   at step 0 telling you to run `ruby scripts/setup.rb` once — that is expected;
>   do it (in a real terminal) rather than working around the auth error.

> **Model fit & vision requirements — `refs/model-fit.md`.** Design fidelity depends on
> the driving agent, not just the environment. One-line rule: **pixel-fidelity claims
> require image input; very-large workbooks on non-top-tier models require asking the
> user once before proceeding.** A text-only agent must record the visual verdict as
> not-executable (named degradation), never `pass`. The mandatory Phase 0 checkpoint
> (complexity bucket × model tier → ask-once) and the honest tier-introspection rules
> are in `refs/model-fit.md` — read it before Phase 0 on any multi-dashboard workbook.

Convert a Tableau datasource into a Sigma data model, then build a Sigma workbook
that mirrors the Tableau dashboard layout as closely as possible.

> **🚧 GATE convention.** A step marked **🚧 GATE** is backed by a script that
> *fails the run* if the step was skipped — it is not advisory. Every 🚧 GATE
> requires an **artifact** (a file on disk) and a downstream check that refuses
> to proceed without it. If a step is important but merely prose, it will get
> skipped under load — so the load-bearing steps are gated, one marker per real
> gate. Current gates: **Phase 1d source dashboard-read** (`png-read.json` →
> `assert-dashboard-read.rb`, enforced again inside `build-charts-from-signals.rb`),
> **Phase 6 source-parity** and **Phase 6f visual render** (`assert-phase6-ran.rb`).

**Read ALL of the following before replying or taking any action. Do not make assumptions about skill conventions, prompts, or global instructions — read the files.**
- `refs/operating-contract.md` — **READ FIRST.** The non-negotiable guardrails: obtain the source render + calcs, build from the source's own logic (not `SUM(col)`), render + value-check EVERY page against the source, never ship empty or waive silently, don't spin. This is what keeps a run on the rails.
- `refs/composition-recipe.md` — composition pass (hero/panels/carded KPIs + brand-from-source), value-fidelity rules (materialized `(copy)` calc columns, exact aggregate/population, period filter), controls/params rebuild, and the spec/API gotchas that otherwise cost round-trips.
- `refs/column-gotchas.md` — column naming rules and special-character landmines
- `refs/data-model-spec.md` — data model JSON schema, element format, relationship format
- `refs/workbook-layout.md` — Ruby layout generation (mandatory), multi-series chart patterns
- `refs/story-points.md` — Tableau stories → one Sigma page per story point (`build-story-pages.rb`)
- `refs/blending.md` — data-blend detection + routing decision tree (same-warehouse repoint / VDS materialize / flag)
- `refs/window-functions.md` — Tableau window/table calcs → Sigma-native window math (WINPROBE-validated mapping table, two-level helper shape, sort/partition/week-anchor rules, manual residues)
- `refs/coverage-matrix.md` — converter-wide Tableau→Sigma coverage matrix (every construct → Sigma output + status: ✅ spec / 🧩 workbook pattern / 🔐 reported / 🟡 verify / ❌ flagged / ⛔ silent gap). Static companion to the per-workbook `scan-workbook-gaps.rb` readout.
- `refs/source-anchors.md` — the **measured value bar**: why source-value anchors exist (two field migrations shipped wrong NUMBERS behind passing visual verdicts), the `source-anchors.json` schema, canonicalization rules, and a worked example.
- `refs/orchestration.md` — orchestration/runbook guidance (see that file).
- `refs/performance.md` — performance guidance (see that file).

**For canonical workbook spec shape** (element kinds, source kinds, controls, formulas, formatting), defer to the companion **`sigma-workbooks`** skill, which ships as the **`sigma-authoring`** plugin in this same marketplace — install it alongside this converter (it's the canonical Sigma workbook spec reference, and this converter assumes it is present). This skill restates only the Tableau-conversion-specific patterns; everything else (KPI fields, color channel, pivot-table shape, manual sources, container styling, YAML default, etc.) lives there. Read its `reference/specification/` whenever you need the current spec surface.

---

## Step −1 — Mission intake (MANDATORY — before anything else)

Restate the user's request as `<workdir>/mission.json` (schema + rules in
**`MIGRATION_REQUEST.md`**): source, Sigma connection, destination, landing
target, workbook scope — each marked `stated` (the user's words pin it) or
`inferred` (you filled it in). **Any `inferred` field → STOP and confirm with
the user before building.** Field evidence: every scope decision an agent has
invented (a guessed project, an assumed folder) has invalidated the entire run
before the first gate could fire. `MIGRATION_REQUEST.md` also carries the
copy-paste kickoff template to hand users who ask "how should I request a
migration?".

---

## Step 0 — Environment doctor (MANDATORY — the orchestrator gates on it)

Run the environment doctor FIRST. It reports missing runtimes with per-OS fixes
**and** writes a machine-readable `doctor.json` fingerprint (to
`~/.sigma-migration/doctor.json`, and to `<WORK>/doctor.json` when `--workdir` is
given). `migrate-tableau.rb` refuses to start until a **passing** `doctor.json`
exists — so a broken environment stops here with an explicit fix instead of the
run improvising around a missing runtime (the #1 cause of cross-user drift).

macOS / Linux / Git-Bash:
```bash
bash scripts/doctor.sh --workdir <WORK>
```

Windows PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1 -WorkDir <WORK>
```

If the doctor cannot pass in your environment (e.g. a Cowork sandbox missing a
runtime) and you must proceed anyway, waive the gate explicitly and name it in
your report: `migrate-tableau.rb … --skip-doctor-gate "<reason>"`.

## Step 0.1 — Front door: resolve the connection once (`scripts/intake.rb`)

Before the run, resolve the Sigma warehouse connection a SINGLE time so no phase
free-searches `/v2/connections` (the token sink):

```bash
ruby scripts/intake.rb --workdir <WORK> --tool tableau-to-sigma --mode live \
  [--connection <id>] [--name <connection-name-substring>] [--source "<workbook name>"]
```

> **Credentials are shell-neutral now.** The Ruby/Python scripts mint Sigma
> tokens themselves from `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` (env or
> `~/.sigma-migration/env`) and auto-refresh on expiry — no `eval` step needed,
> in any shell. If you hand-drive a raw `curl` and want an explicit token, mint
> one the same way in every shell (bash, PowerShell, cmd):
> `python scripts/get_token.py --workdir <WORK>` writes `<WORK>/auth.json`
> (mode 0600), which the scripts read automatically. (`eval "$(scripts/get-token.sh)"`
> still works in bash for muscle memory.)

It caches `<WORK>/connection.json` (the orchestrator reads it when `--connection` is
omitted — just point `--out` at the same `<WORK>`) and writes `intake.json` (run-start +
input mode, which feed the telemetry ping's duration and `mode`). Precedence: explicit
`--connection` → cached → `SIGMA_CONNECTION_ID` env → list once. With no id/name and
multiple connections it lists them and asks you to pick — it never guesses.

> **When there are many connections, let intake pick by the workbook's warehouse — don't inspect the `.twb` by hand.** Pass the resolved workbook LUID: `ruby scripts/intake.rb --workdir <WORK> --rank-workbook-id <LUID>`. Intake fingerprints the workbook's warehouse (`GET /workbooks/{luid}/connections` → type + host, no `.twb`/`zip` needed) and ranks the Sigma connections; a **unique type+host match auto-resolves** (e.g. a Snowflake workbook on `acct.snowflakecomputing.com` → the matching Snowflake connection), otherwise it writes a **ranked** `connection-candidates.json` with a clear top pick and asks. This replaces the field-caught pattern of downloading the `.twb` and grepping `class=`/`server=` to guess among 26 connections. (`scripts/rank-connections.rb` is the standalone ranker; `--rank-twb <path>` adds a db-name tie-break once the `.twb` is downloaded.)

## One command (orchestrated path)

```bash
# PASS 1 — discover → gap gate → DM-reuse scan → DM → workbook → layout → parity plan
# (mints its Sigma token in-process — no `eval`/bash token step, works in any shell)
ruby scripts/migrate-tableau.rb \
  --workbook "<name>" --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
  [--db CSA --schema TJ] [--name '<prefix>'] [--row-scale 1.5] \
  [--reuse-dm [ID]] [--force] [--yes]
# … pass 1 auto-fills <workdir>/parity-actuals.json via the pooled CSV-export
#   collector (collect-parity-actuals.rb); run the printed mcp-v2 queries for
#   the REMAINING charts only (pivot grids) and merge them in …
# PASS 2 — finalize: phase6 verify + cleanup-orphans + census-aware hard gate
ruby scripts/migrate-tableau.rb --workbook "<name>" \
  --finalize --actuals <workdir>/parity-actuals.json [--allow-missing-tiles N]
```

> **🚧 Expect PASS 1 to hard-stop once for the Phase 1d dashboard-read.** The orchestrator
> fetches view CSVs but **cannot read the source dashboard PNG** — that's your job. On the
> first cold run it aborts **before posting the data model** (so no stray DM) with
> "Phase 1d dashboard-read gate". When it does: fetch the dashboard view PNG with
> `mcp__tableau__get-view-image` (solo), Read it, write `<workdir>/png-read.json` (schema in
> Phase 1d — every tile with its Sigma `kind`, plus `text_elements` and `filter_shelf`), then
> **re-run the same PASS 1 command** (discovery artifacts are reused). This is the fix for the
> #1 escape: shipping a workbook with the right numbers but missing tiles the source rendered.
> If the PNG is genuinely unavailable, re-run with `--skip-dashboard-read "<reason>"`.

> **Converter backend — LOCAL by default, zero config, never upload customer data silently.**
> The mechanical path needs the Tableau→Sigma converter, which is **not a server** — it's a
> pure function (`.twb` XML → Sigma JSON) run via `node`; nothing leaves the machine. A
> **prebuilt converter ships inside the skill** at `converter/tableau.mjs` and is auto-discovered
> as the guaranteed fallback, so the local path works with **no clone, no `npm install`, no
> network** (only `node` on PATH). A developer's own build still wins when present — set
> `TABLEAU_MCP_BUILD` to a `build/tableau.js`, `SIGMA_DATA_MODEL_MCP` to a checkout, or run
> `scripts/dev/fetch-converter.sh`. Refresh the vendored copy after the converter changes with
> `scripts/dev/vendor-converter.sh` (pinned source in `converter/PROVENANCE.json`). The
> **hosted** converter (`https://sigma-data-model-mcp.onrender.com/mcp`) uploads the `.twb` to
> a third-party server and is used **only** with explicit `--converter hosted` (which overrides
> local auto-discovery) or `SIGMA_CONVERTER_ALLOW_HOSTED=1` — never on its own. See QUICKSTART
> "the data-model converter backend".
>
> **No converter available? Re-enter the GATED spine — do NOT hand-drive raw POSTs.**
> When no backend is configured, the fallback is *not* "build everything by hand and POST
> it yourself" (that skips preflight/control lint, Phase-6 parity, and the
> `assert-phase6-ran` hard gate — the exact way a workbook ships with missing controls and
> an unverified parity claim). Instead author the specs *once* and let the scripts run them:
> 1. Get the **DM spec** — normally the vendored local converter (`converter/tableau.mjs`)
>    produces this automatically; reach here only if even that can't run. In that case call
>    the hosted `sigma-data-model` MCP's `convert_tableau_to_sigma` on the `.twb` if it's
>    available to you, else author it by hand (see `sigma-data-models`).
> 2. Author the **workbook spec** (see the companion `sigma-workbooks` skill). Reference the
>    data model with placeholders the orchestrator binds to the live readback ids:
>    `"__DM_ID__"` (top-level `dataModelId`) and `"__DM_ELEMENT__:<ElementName>"` per element
>    (the fact element is `"__DM_ELEMENT__:__FACT__"`). An unresolved element ref aborts loudly.
> 3. Write `dm-spec.json` + `wb-spec.json` into the workdir and re-run the orchestrator with
>    `--dm-spec <path> --wb-spec <path>` (fresh build) — or, when the DM is **already posted**
>    (exit 4 workbook-layer handoff), `--reuse-dm <dataModelId> --wb-spec <path>`. Either way
>    the spec runs through validate → post-and-readback (preflight/control lint + column guard)
>    → layout → parity, and stops at exit 12 to collect actuals + `--finalize`. **A conversion
>    is not done until `assert-phase6-ran.rb` exits 0**, on this path too.

> **Parity is EXACT for warehouse-backed migrations — never blame "drift."** Sigma
> queries the **same warehouse** the Tableau source reads, so a value gap is a real
> bug (a missing view filter / NULL bucket, an ungrouped table, a wrong aggregate),
> NOT data freshness. The drift-tolerance path (`extract-mode`) is **only** valid for
> `hasExtracts=true` workbooks (frozen `.hyper` snapshots) and must be explicitly
> flagged. Do not attribute a gap to drift on a live-warehouse source, and do not
> declare GREEN while a table renders base-row-count detail or a chart shows a
> NULL-dominant bucket — run `scripts/lib/preflight_lint.rb` on the spec first.

Chains the scripted spine (discover → scan-workbook-gaps → discover-columns →
find-or-pick-dm → DM build/validate/post → build-charts-from-signals → workbook
post-and-readback → build-dashboard-layout + put-layout → phase6-parity →
cleanup-orphan-workbooks + assert-phase6-ran) and STOPS with exact instructions
wherever agent judgment is genuinely required. Phase 1 is **interleaved**:
Tableau discovery + gap scan run as a background lane while the pure-Sigma-side
read-only phases (1.6 DM-reuse scan, 2 warehouse columns) run concurrently; the
lanes join before anything consumes discovery output, so every designed
stop/gate fires exactly as in the serial flow. A `PHASE TIMINGS` summary line
prints at every terminal exit so the speedup stays visible. Exit codes: `10` = OPEN QUESTIONS
(re-run with `--yes`/`--answers`), `11` = ❌-unhandled gap-scan features (close via
gap-scout or `--force`), `12` = pass 1 done, parity PENDING (collect mcp-v2 actuals,
then `--finalize`), `4` = DM posted but the workbook layer needs an agent-authored spec — re-enter the gated spine with `--reuse-dm <id> --wb-spec <path>` (never hand-POST),
`3` = a gate failed, `14` = migration GREEN + Phase E proposals pending
acceptance, `0` = ALL gates green (only reachable via `--finalize`).
DM-reuse is **reuse-first** — auto-reuses an existing DM that covers all the
workbook's source tables (collapsing duplicate-DM sprawl, skipping the POST);
`--reuse-dm <id>` pins one, `--skip-reuse-scan` forces build-new.
Optional `--enhance [--enhance-accept <ids|all-low-risk>]` runs Phase E
(opt-in) after all gates are green — see the Phase E section below.

**Still manual by design (the orchestrator stops and tells you):**
- **Parity actuals (pivot grids only)** — pass 1 now collects actuals for every
  exportable chart itself: `collect-parity-actuals.rb` pools the element CSV
  exports (`POST /v2/workbooks/{wb}/export` → poll → download, 5-wide, under
  `sigma_rest`'s auto-refresh) straight into `parity-actuals.json`. Only
  pivot-tables stay agent-mediated (their CSV export is the WIDE grid, not the
  long row/col/value tuples the plan compares) — pass 1 prints exactly those
  `mcp__sigma-mcp-v2__query` calls; merge their rows into the same file.
- **Empty-view-CSV recovery** — a view that exports an empty CSV produces no
  chart; surfaced at the OPEN-QUESTIONS checkpoint AND by the tile census at
  `--finalize` (exit 7 → rebuild the chart manually or explain with
  `--allow-missing-tiles`, naming the zones in your report).
- **Master-level calc overrides** — when the workbook layer exits 4 naming a
  field like `master/ship speed category`, translate the Tableau calc (see
  `calc-fields.json`) and re-run the same command with
  `--master-col 'Name=<Sigma formula>'`.
- **Shared relative-date filters** — `build-charts-from-signals.rb` now maps
  these to Sigma's native ROLLING date-range modes directly:
  `this <period>` → `mode:current`, `last N <period>` → `mode:last`
  (`value:N`, `unit`, `includeToday`), `next N` → `mode:next`. They roll with the
  clock — no frozen dates and no manual master-boolean workaround. Only a
  shifted/spanning window (one that doesn't anchor to now) falls back to a frozen
  `mode:between`, flagged `FROZEN — re-run to refresh`. If a shared relative-date
  filter still shows a uniform parity DIVERGE (every Sigma value too big),
  confirm the date key survived into the DM and the control's `filters` target
  wiring reached the chart's source. (Rolling emission verified 2026-07-01;
  shapes per `sigma-authoring` controls.md, live 2026-06-15.)
- **❌-unhandled gap features** — gap-scout subagent or `--force` (degraded).
- **DM-reuse shape preflight** — when `--reuse-dm` hits a differently-shaped DM
  the workbook gate exits 4; run Phase 1.5b (`inspect-dm-shape.rb`) and the
  agent path against the reused DM.

## Scripts

The conversion is driven by `scripts/*.rb`. **`migrate-tableau.rb` composes them
for you** (see STEP 1 at the top) — it is the orchestrator and the only entry
point you run cold. Each other script encapsulates one mechanical phase; you
invoke one **directly only when an orchestrator STOP message tells you to**
(recovery/handoff), never as an à-la-carte alternative to the one command. The
agent's role is judgment (which DM/workbook shape, which calc translation, which
layout) inside that spine — not re-orchestrating it by hand. The table below is
the map of what the orchestrator runs.

| Script | Purpose |
|---|---|
| `scripts/migrate-tableau.rb` | **The one command** — chains the whole scripted spine (gap gate → DM-reuse scan → DM → workbook → layout → two-pass parity → cleanup + census gate) and stops with exact instructions where agent judgment is required. See "One command" above. |
| `scripts/verify-complete.rb` | **The single offline "are we done?" check** — exit 0 / ✅ DONE only when `phase6-success.json` is present (stamped by `assert-phase6-ran.rb` exit 0) and no `parity-pending.json` remains. A clean PASS 1 (exit 12) reports NOT DONE. Also prints the run's off-ramp trail. Run before claiming success. |
| `scripts/lib/offramp.rb` + `offramps.jsonl` | **Observability trail** — every point a run leaves the golden path (cred/doctor waiver, PASS-1 stop, converter-stop, workbook-handoff, degraded fast path, manual-spec) appends a structured record to `<WORK>/offramps.jsonl`. Read it (or `verify-complete.rb`) to pinpoint *where* a run defected. |
| `scripts/setup.rb` | One-time Sigma credential setup |
| `scripts/get-token.sh` | Exchange `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` for `SIGMA_API_TOKEN` (~1h TTL) — **bash only** |
| `scripts/get_token.py` | Shell-neutral twin of `get-token.sh` (bash/PowerShell/cmd): writes `<WORK>/auth.json` (0600), read automatically by the scripts |
| `scripts/doctor.sh` / `scripts/doctor.ps1` | Step-0 env check; writes `doctor.json` fingerprint the orchestrator gates on |
| `scripts/assert-doctor-ran.rb` | 🚧 GATE — refuse to run without a passing `doctor.json` |
| `scripts/assert-wb-refs-resolve.rb` | 🚧 GATE — every workbook `[Element/Column]` ref must exist in the live DM before POST (catches multi-datasource collapse → "Dependency not found"; waive `--skip-ref-check "<reason>"`) |
| `scripts/setup-tableau.rb` | One-time Tableau PAT setup (only needed for PAT mode — see `refs/tableau-rest.md`) |
| `scripts/get-tableau-token.sh` | One-shot signin → exports `TABLEAU_AUTH_TOKEN` + `TABLEAU_SITE_ID` — **bash only** |
| `scripts/get-tableau-token.py` | Shell-neutral twin (bash/PowerShell/cmd) for hand-driven Tableau REST. The orchestrator mints the Tableau token in-process (no bash) so it no longer calls either. |
| `scripts/tableau-discover.rb` | PAT-mode Phase 1 discovery in one CLI: workbook + views + VDS metadata + GraphQL + .twb content. ONE unified fetch pool (default 5, `--pool N`, longest-job-first) with 429/timeout backoff + 401 re-mint; always writes per-task `timings.json`. Measured 61.8s → 13.7–18.9s on the 7-view reference workbook |
| `scripts/resolve-project.rb` | **Phase 1a — numeric-URL resolver, project AND workbook (⛔ no guessing).** A `/workbooks/<N>` URL resolves via `Workbook.vizportalUrlId` to `{workbook_luid, name, project_luid, project_name}` (exit 0). The `/projects/<N>` number in a Tableau URL is a *vizportal URL id*; **REST Query Projects has NO numeric id** (only luid/name/contentCounts), so no REST call can resolve it — and guessing picked the WRONG project in a real field run. Resolves via Metadata GraphQL (`workbooks { luid name projectVizportalUrlId projectLuid projectName }`, + the same fields on `publishedDatasources` when the schema supports them), grouped by `projectVizportalUrlId`. Exact match → `{vizportal_id, project_luid, project_name, workbooks:[{luid,name}]}` (exit 0, `--out` JSON). No match / Metadata API off → **exit 2 with a REST candidates table: STOP and ask the user which project — NEVER assume.** Exit 3 = auth/transport (fix creds via `setup-tableau.rb`). |
| `scripts/scan-workbook-gaps.rb` | **Phase 0a (mandatory):** scan a `.twb` and emit `gaps-report.md` + `gaps.json` categorising every feature into ✅ auto / ⚠️ hint / 🛠 manual / ❌ unhandled. Run BEFORE any other phase. Also detects multi-datasource **data blends** (secondary `datasource-dependencies` + linking fields) and writes `blend-plan.json` with a per-blend route — same-warehouse-repoint / materialize-via-vds / flag-unreachable (decision tree: `refs/blending.md`). |
| `scripts/gap-scout.md` | **Phase 0a-scout:** subagent prompt + protocol for resolving ❌ Unhandled gaps. Main agent spawns one scout per gap via the Agent tool. |
| `scripts/validate-sigma-formula.rb` | Scout primitive: POST a tiny test workbook with a candidate formula, read back column types, return JSON `{ status: ok|error }`. Auto-expands the DM element's columns onto the test master so candidate refs to real data resolve. |
| `scripts/scout-validate-and-persist.rb` | Scout wrapper: call validate-sigma-formula, on success append the rule to `~/.tableau-to-sigma/learned-rules.yaml` (customer's HOME, never the skill repo), on failure write `~/.tableau-to-sigma/escalations/<ts>-<slug>.yaml` AND return an opt-in `escalate-gap.py` command (confirm-before-file). |
| `scripts/escalate-gap.py` | Shared opt-in issue filer. Dry-run by default (drafts the issue + dedupes against open issues/beads); files only with `--yes`. Routes by gap category: converter→`sigma-data-model-manager`+`sigma-data-model-mcp` (mirrored), builder/skill→`sigma-migration-skills`. |
| `scripts/learned-rules.rb` | Loader module: merges the repo-shipped starter pack (`learned/starter-rules.yaml` — live-verified rules from real runs, so no machine starts empty) with `~/.tableau-to-sigma/learned-rules.yaml` (user rules override starter rules on key collision). Customer-discovered rules apply BEFORE the built-in translators in `build-charts-from-signals.rb`; starter entries without a rewrite pattern are spec-guidance (surfaced by the CLI dump, mirrored in `refs/fidelity-recipes.md`, never blind-applied). |
| `scripts/parse-twb-layout.rb` | Parse a `.twb` XML file into a per-dashboard zone list plus a sister `*-meta.json` (worksheets + shared_filters + parameters + column_aliases). Per chart zone surfaces: position (`x/y/w/h%`), `chart_kind`, `mark_class`, `geo_role`, `sort`, `filters` (with resolved column captions + member values + action-vs-value flag), `aggregations`, `channels`, `formats` (Tableau format strings → Sigma d3-format with paren-negative handling), `calculations`, `dual_axis` (synchronized-axes detection), `ref_marks` (reference lines/bands/trendlines), `filter_column_caption`. Detects Tableau **stories** (both `<story>` and storyboard-dashboard shapes): flags storyboard dashboards `is_story: true` and writes `story-plan.json` (story → ordered points with captions + captured sheets) — when present, run `build-story-pages.rb`. Bin calc columns surface `bin_size`/`bin_peg`. |
| `scripts/build-charts-from-signals.rb` | Generate Sigma chart-element specs from parse-twb-layout output + view CSVs + master-column map. Auto-translates: column aliases → `Switch(…)` calc, parameter-driven CASE/IF chains → `Switch([ctl-param-x], …)` with controlId rewrite per page, table calcs (INDEX/LOOKUP/TOTAL/RANK/ZN/IIF/COUNTD) → Sigma equivalents, `DATEPART('iso-year')` → Thursday-of-ISO-week `Year(DateAdd(...))` composition, `FINDNTH` → `SplitToArray`/`ArraySlice`/`ArrayJoin` composition, Tableau bins → native `BinFixed`/`BinRange` recipe, **nested `{FIXED}` LODs → helper-element chain** (innermost LOD = helper element 1, outer consumes `[LOD Helper k/Value]`; machine-readable sidecar `<out>-lod-chains.json`), Tableau formats (p%.%/C1033%/`(neg)`) → Sigma d3-format. Honors `--page-per-worksheet`, `--auto-controls`. Loads customer learned-rules first. Writes `*-actions.md` companion listing Tableau action filters for post-publish cross-filter setup. **Writes `coverage.json`** (`--coverage-out`): aggregates every dropped/degraded/approximated component into one ledger (rendered by `migrate-tableau.rb`); classifies build messages so `WARN` = real gap, `NOTE` = success/verify (bead beads-sigma-59mk). |
| `scripts/extract-custom-sql.rb` | Phase 1f: pull Custom SQL blocks behind a workbook via Metadata GraphQL + .twb XML fallback. Output → `<WORK>/custom-sql.json`. |
| `scripts/resolve-published-ds.rb` | **Published-datasource (sqlproxy) resolver — the reliable chase.** For each `<connection class='sqlproxy'>` datasource, resolves the PDS by contentUrl (== the sqlproxy `dbname` / `<repository-location id>`), `GET /datasources/{id}/content`, and reads the inner `.tds`'s REAL relation — a warehouse **table** OR a Custom SQL `<relation type='text'>`. Emits a descriptor per PDS `{contentUrl, relationType, sql|table, db, schema, columns}`. Uses REST content (NOT Metadata GraphQL lineage, which lags hours on fresh PDSes and often has empty downstream links). |
| `scripts/hydrate-custom-sql.rb` | **Published-datasource (sqlproxy) hydration.** A workbook on a published DS carries only a `<connection class='sqlproxy'>` placeholder; left as-is the converter fabricates a phantom table (`CSA.TJ.SQLPROXY`) → POST "Source not found". `hydrate_pds!` (PRIMARY, `--pds`) splices the resolver's descriptor: **table** PDS → a real `<relation type='table'>` (qualified from the PDS db/schema); **Custom SQL** PDS → a `<relation type='text'>` with the SQL wrapped and its output columns projected as upper-snake aliases (`"Sales Region" AS SALES_REGION`) for Snowflake-safe casing, and **synthesized `<metadata-records>`** from the parsed SQL columns (published-DS workbooks cache none, so without this the element POSTs with 0 columns). GraphQL Custom SQL blocks (`--custom-sql`) remain a fallback. The existing converter then builds a normal element — no new DM-shaping code. `migrate-tableau.rb` runs resolve→hydrate before conversion when `HydrateCustomSql.twb_has_sqlproxy?`, and ABORTS (never fabricates a phantom) if a sqlproxy DS stays unresolved. Pure module + offline unit test `test-hydrate-custom-sql.rb`. |
| `scripts/lib/tableau_rest.rb` | Ruby wrapper for the Tableau REST endpoints the skill uses |
| `scripts/estimate-cost.rb` | Predict input/output token cost from workbook + datasource metadata |
| `scripts/fetch-view-data.rb` | Parse pre-fetched view CSVs into a signals manifest (distinct values, date min/max, agg hints) |
| `scripts/discover-warehouse-columns.rb` | Parallel-fetch Sigma column metadata for N table inodeIds |
| `scripts/probe-custom-sql-columns.rb` | **Phase 1e.1:** when discover-columns 404s (catalog miss), FIRST force a catalog sync (`POST /v2/connections/{id}/sync`, body `{"path":["DB","SCHEMA","TABLE"]}` — works, verified 2026-07-07) and retry; only if still 404 probe column names + types via a one-shot Custom-SQL probe workbook that SELECTs INFORMATION_SCHEMA, exports CSV, and self-destructs. ~6s end-to-end. Saves ~120s on every Custom-SQL fallback vs. POST-fail-cleanup column-name guessing. |
| `scripts/find-prior-cache.rb` | **Phase 1d-cache (Phase -1):** detect cached Tableau-discovery + Sigma-conversion artifacts from prior `audit-run-*` or `converter-test` runs so re-conversions skip discovery (~3 min saved). |
| `scripts/remap-wb-spec-to-dm-ids.rb` | When a DM is re-POSTed and element IDs churn, remaps a cached `wb-spec.json` to the new IDs via name-based matching. Optional `--rename` for renamed elements. |
| `scripts/extract-calc-fields.rb` | Phase 1e: pull every Tableau calc field (with formula) via Metadata API (`POST /api/metadata/graphql`); falls back to `.twb` XML when Metadata API is unavailable. Drops VDS dependency. Caches to `<wb-dir>/calc-fields.json`. |
| `scripts/validate-spec.rb` | DM or workbook spec validator. Accepts `--type` and `--dm-context` |
| `scripts/post-and-readback.rb` | POST a DM or workbook spec, parse YAML response, GET back the spec, emit element ID map. Also runs a universal **column-type guard** afterward: any column whose formula resolved to type `error` aborts the script with exit 2 and the failing formula. Catches silent-error columns the validator doesn't pattern-match (typo refs, `IsIn`, unsupported functions) without waiting for Phase 6. Then the shared **layout lint** (exit 3) and **control lint** (`scripts/lib/control_lint.rb`, exit 4 — dead controls / ghost targets / partial same-page reach; honors the `<workdir>/control-scope.json` sidecar, `--skip-control-lint` escape). **Same-workbook PUT discipline:** when the workdir already recorded a workbook id (`posted-workbooks.jsonl` / `migrate-state.json`), the spec is PUT to it in place — `--force-new-workbook "<reason>"` is the only way to POST a new one (waiver-counted). **Standalone runs on an orchestrator workdir are refused (exit 7)** unless an orchestrator STOP is on record (`manual-path-authorized.json`) or `--allow-manual-spec "<reason>"` is passed. |
| `scripts/lib/preflight_lint.rb` | **MANDATORY before any workbook POST** — static lint of the spec that catches the two enterprise-class failure modes with a precise message instead of the opaque `Invalid kind: control` / a silently-detail-rendered table: (T1) a `table` with aggregate columns + dimensions but **no `groupings`** → renders raw 9.6M detail rows; (T2) a grouping calculation that passes through an already-aggregated column → "multiple values"; (C1/C2/C3) a `control` missing `id`/`controlId`/`controlType` nesting value fields under a `value` object (must be FLAT top-level), carrying a non-double-nested `source`, or a list-type control wired to neither `source` nor `filters` (a filters-only list control is valid). `ruby scripts/lib/preflight_lint.rb <spec.json>` (exit 1 on violations). Fix all violations before POST. Verified shapes: `sigma-workbooks` `controls.md`/`tables.md`. |
| `scripts/put-layout.rb` | Apply a layout XML to an existing workbook (strips read-only fields) |
| `scripts/auto-parity-plan.rb` | Phase 6a: auto-build a parity plan by matching Sigma chart elements to Tableau view CSVs (with `--rename` for renamed tiles). Output → `<WORK>/parity-plan.json` wrapped as `{ extract, charts: [...] }` |
| `scripts/verify-parity.rb` | Phase 6c: diff expected (Tableau) vs actual (Sigma) per chart. `--extract-mode` switches to structural comparison (bucket count + dim set + sort) with value-drift tolerance for hasExtracts=true workbooks |
| `scripts/verify-anchors.rb` | **Phase 6 — the MEASURED value bar.** Loads `<workdir>/source-anchors.json` (printed source values transcribed at Phase 1d, EXACTLY as printed), pools the live workbook's element CSV exports (same export→poll→download flow as `collect-parity-actuals.rb`), and checks each anchor is present at the printed precision (`scripts/lib/anchor_values.rb` canonicalization: `"18,037B"`→(1.8037e13, ±0.5e9); `sigma_element_hint` wins, else label→element token-overlap fuzzy match, then search everywhere). Writes `anchors-verdict.json` `{checked, matched, missing:[{id,label,raw,best_candidate}], pass}` + stamps an `anchors` summary into `parity-final.json`. Exit 0 all matched / 1 with a per-miss report. An anchor value appearing NOWHERE in the exports is the loudest possible signal the data is wrong. See `refs/source-anchors.md`. |
| `scripts/assert-phase6-ran.rb` | **Conversion hard gate** — exits 0 only when ALL pass: (1) Phase 6 ran and parity-final.json shows status=PASS at the required rate, (2) no uncleaned orphan workbooks (posted-workbooks.jsonl has ≤1 entry OR cleanup-marker.json shows a successful non-dry-run cleanup), (3) the live workbook's `/columns` endpoint shows no column with `type=error` (catches circular refs / runtime errors introduced after the initial POST's column-type guard), (4) a non-empty top-level layout XML is applied (beads-sigma-bw3), (5) tile census — parity-final.json's `tile_census` shows no unexplained dashboard zones without a matching chart (catches the empty-view-CSV N-1-charts escape, bead gjhe; `--allow-missing-tiles N` for legitimately unbuildable zones), (6) layout lint, (7) control lint, **(8) Phase 6f visual render — a valid Sigma render PNG exists in the workdir (`sigma-render.png` or a `screenshots/_manifest.json` entry), proving the mandatory full-dashboard visual comparison could run. Closes the "declared done on HTTP 200 / CSV-parity-only" regression where the workbook shipped without anyone rendering the PNG**, plus (8b) a RECORDED source-vs-target visual verdict, and **(8c) layout fill / grid coverage — reads `layout-census.json` (emitted by `build-dashboard-layout.rb`) and fails any page that dropped a tile (`placed < zones`) or ships mostly empty (`grid_fill_pct < --min-grid-fill`, default 0.45); #259 item 1.** Exits 1 for missing parity sentinel, 2 for parity FAIL / extract-mode-without-flag / charts_total==0, 4 for uncleaned orphans, 5 for live type=error columns, 6 for missing layout, 7 for census failure, 8 for layout-lint violations (`lib/layout_lint.rb`, `--skip-layout-lint`), 9 for control-lint violations (`lib/control_lint.rb` — dead controls / ghost targets / partial reach / control-scope coverage; `--skip-control-lint`, `--control-scope PATH`), 10 for missing visual render (`--sigma-render PATH`, escape hatch `--skip-visual-gate "<reason>"`), 13 for an unrecorded visual verdict (`--skip-visual-comparison "<reason>"`), 14 for a layout-fill/coverage failure (`--min-grid-fill F`, escape hatch `--skip-layout-fill "<reason>"`), **15 for an unresolved Phase 5g RCF fidelity ledger (gate 8d — OPT-IN via `--require-fidelity-ledger`, which `migrate-tableau.rb --finalize` passes unless `--rcf-passes 0`: the `fidelity-ledger.json` is missing or still carries spec-fixable deltas that were never resolved; waive named residuals with `--accept-residuals id,id` — but data-class ids are NEVER accepted, and any unresolved `data`-class entry blocks whenever the ledger exists, flag or no flag)**, **18 for the source-anchor value gate (gate 13 — when a source dashboard PNG exists, `source-anchors.json` must carry ≥5 anchors and `anchors-verdict.json` must pass; also raised when `--skip-parity-gate` is passed without a passing anchors verdict — the anchors oracle replaces parity, never nothing; escape `--skip-anchors-gate "<reason>"`)**, **19 for the waiver budget (>2 quality waivers → GREEN unavailable, YELLOW cap; `waivers` + `waiver_count` stamped into parity-final.json on every run; no escape flag)**, and **20 for the measured visual-similarity floor (gate 14, behind `scripts/visual-similarity.py`; escape `--skip-visual-similarity "<reason>"`)**. Subagent flows MUST call this as their final step. |
| `scripts/fidelity-loop.rb` | **Phase 5g — RCF (render-compare-fix) loop MECHANICS.** Subcommands `init` / `render` (export the live page to `rcf-pass-N.png`, bump the pass counter, print the scored rubric + enforce the pass budget) / `record` (append a classified delta to `fidelity-ledger.json`: spec-fixable \| ui-only \| sigma-capability \| data) / `apply-patch` (a **single layout-preserving PUT** — GET the full live spec, deep-merge the agent's patch by `elementId`/`id`, PUT the whole spec back so the layout is never wiped, then re-run the column-type guard + layout/control lint) / `resolve` / `status`. The *judgment* stays with the agent (it Reads the render vs the source and authors patches from `refs/fidelity-recipes.md`); this script is only the spine. The ledger is the input to `assert-phase6-ran.rb` gate 8d (`--require-fidelity-ledger`). |
| `scripts/assert-run-state.rb` | **Phase 6 (chain audit)** — reads the per-run `run-state.json` ledger (stamped by the orchestrator's `hdr()` as it walks each phase, plus explicit `phase-1d`) and fails if any always-required phase (discover, dashboard-read, workbook, layout, parity) was never entered — catching a silent shortcut (re-run on stale artifacts, a dropped phase) the output gates can miss. A deliberately skipped phase records `status:"skip"` + reason and is not flagged. NO-OP (advisory) when `run-state.json` is absent (hand-driven manual path). Lib: `scripts/lib/run_state.rb`. Escape: `--skip-run-state "<reason>"`. |
| `scripts/probe-controls.rb` | **Phase 6 (optional) — control flip test**: per control, export one in-closure element CSV with and without `parameters:{controlId: <first non-default value>}` (must differ) and, with `--check-out-of-closure`, one out-of-closure element (must NOT differ). Runtime proof the wiring works; the static check is gate 7. Shared, vendored byte-identical (md5 discipline). See `refs/control-parity.md`. |
| `scripts/cleanup-orphan-workbooks.rb` | Delete orphan workbooks left by spec-iteration retries. Reads `<workdir>/posted-workbooks.jsonl`, keeps the most-recent ID, deletes the rest via `DELETE /v2/files/{id}`. Writes `cleanup-marker.json` so the hard gate can confirm cleanup ran (and wasn't `--dry-run`). Idempotent (404 on delete is treated as success). See beads-sigma-38a. |
| `scripts/build-dashboard-layout.rb` | **MANDATORY in Phase 5d** (dashboard-fidelity mode) — auto-build the Sigma layout XML from the parsed Tableau zone tree (`dashboard-layout.json`) + the workbook readback IDs (`wb-ids.json`). Positions each chart at the grid cell derived from its zone's x/y/w/h%. Without this step, the workbook PUTs without a top-level layout and Sigma renders elements as a single-column stack — see `assert-phase6-ran.rb` gate 4 (beads-sigma-bw3). Also emits `layout-census.json` (per page: zones / placed / dropped / grid_fill_pct) — the input to gate 8c (`--census-out PATH` to relocate). |
| `scripts/build-story-pages.rb` | **Story workbooks only** — when `parse-twb-layout.rb` wrote `story-plan.json`, emit one Sigma page per story point: pass 1 (`--spec`/`--out`) appends caption-named pages (annotation text atop + cloned elements with fresh ids/controlIds) to the workbook spec pre-POST; pass 2 (`--wb-ids`/`--layout-out`) emits the banded per-page layout + container sidecar post-readback. See `refs/story-points.md`. |
| `scripts/export-chart-png.rb` | Phase 6d (visual) **drill-down only** — per-element PNGs for diagnosing a chart-level regression (dropped log scale, missing data labels, wrong kind, palette drift). **NOT the primary visual gate:** the mandatory check is **full-dashboard ↔ full-dashboard** — render the whole Sigma page with `sigma-export-png.py --page <pageId>` and compare it to the FULL source dashboard image (Tableau MCP `get-view-image` on the *dashboard view*, not each worksheet). Per-element screenshots miss layout/relationship defects (overlaps, dead zones, stranded controls, wrong relative sizing). See `refs/layout-visual-qa.md`; loop-fix-and-re-render until the full page matches the source — never declare done on HTTP 200. |
| `scripts/pick-destination.rb` | **Phase 0b:** list build destinations (`list` → workspaces + editable folders + My Documents) and create folders (`create --name [--parent]`). Drives the "where should this land?" prompt when no `--folder`/`SIGMA_FOLDER_ID` is given. `folderId` accepts a workspace id (workspace root) or a folder id. Shared across the migration skills. |
| `scripts/find-or-pick-dm.rb` | Phase 1.5: scan existing DMs in the org and recommend reuse when one already covers the workbook's columns. Score = 0.7·column-overlap + 0.2·table-overlap + 0.1·metric-overlap. Parallel-fetches DM specs (~2s for 50 DMs). Output: `dm-match.json` with ranked candidates + recommendation. Non-destructive. Reuse skips Phase 2 + 3 entirely. `--auto-pick` flag (with tie-window safety) skips the user-confirm step when there's a clear winner. |
| `scripts/inspect-dm-shape.rb` | Phase 1.5b (MANDATORY when reusing): inspect the reused DM's element graph and emit a denormalization plan classifying every column as `fact` (direct ref) or `dim` (needs Lookup). Output: `dm-denorm-plan.json` with the exact Lookup formula per dim column. Eliminates the 2–3 min spec-rework loop when the reused DM has separate dim elements (a non-pre-denormalized DM shape). |
| `scripts/scan-customer-style.rb` | Phase 0c: sample N recent workbooks in the customer's Sigma org and aggregate style signals (color palettes, number-format strings, layout grids, chart-kind mix, dataLabel preference, element naming case, density). Lets the converter emit specs that match house conventions instead of generic defaults. |
| `scripts/dev/phase-timer.sh` | **Dev / profiling only — do NOT source in customer conversions.** Source helper for phase timing when iterating on the skill itself; emits `▶`/`■` log lines per phase and a `phase-timings.json` summary. Only invoke when the user explicitly asks for timing data ("time it", "where did the minutes go", "profile"). Usage: `phase_start "<name>"` / `phase_end` around each phase, `phase_report` at the end. **Across multiple Bash tool-call blocks**, export `PHASE_TIMINGS_TMP=<path>` BEFORE the first source so the helper appends across blocks. |
| `scripts/lib/layout.rb` | Layout-XML helpers (`gc`, `le`, `page_xml`, `assemble`) — `require`'d by per-workbook layout configs |
| `scripts/enhance-scan.rb` | **Phase E (opt-in) part 1 — SCAN (read-only).** Source signals + built spec + live element exports → `enhancements.json` candidates `{id, category, evidence, proposed, risk, verdict_hint, patch}` + descoped propose-in-UI notes. Shared Phase-E engine, vendored byte-identical across plugins (md5 discipline). |
| `scripts/enhance-apply.rb` | **Phase E (opt-in) part 2 — APPLY (accept-only, clone-first).** Clones the parity workbook as `"<name> — Enhanced"` (1:1 artifact never written), applies ONLY `--accept`-ed candidates one at a time, each gated by an untouched-element clone-vs-original spot-check (auto-revert on shift). Writes `enhance-report.json`. Shared engine, byte-identical twin of the tableau/powerbi copy. |

---

## Prerequisites

> **⛔ NEVER hand-roll a signin `curl` — for Sigma OR Tableau.** Managed
> machines' permission classifiers **block secret-bearing raw `curl`**
> invocations, and `curl -sf` hides the failure (silent empty output, no
> error) — a real field session lost ~15 minutes to a silently-failing
> hand-rolled signin before the skill's scripts worked on the first try. The
> scripts are the sanctioned route AND the classifier-friendly one:
> `setup.rb` / `setup-tableau.rb` for one-time credential setup, the
> **in-process token paths** (`lib/sigma_rest.rb` / `lib/tableau_rest.rb` —
> every orchestrated command mints its own tokens, no token step at all), and
> `get_token.py` / `get-tableau-token.py` for hand-driven REST calls.

### Sigma credentials

Run the setup script once:

```bash
ruby scripts/setup.rb
```

It writes credentials to two places: `~/.claude/settings.json` (which Claude
Code auto-loads) and `~/.sigma-migration/env` (a neutral, sourceable file any
other agent or plain shell can use). The scripts fall back to the neutral file
automatically when the env vars aren't already set, so the skill works under
any agent.
Making the vars live in your shell (do whichever applies to your agent — the
instructions are the SAME for everyone, no per-agent variants):
- **Claude Code:** open a new session (or run `! source ~/.claude/settings.json`) so the vars load — no manual sourcing needed thereafter.
- **Any other agent (Cursor, Cortex Code, plain shell):** the scripts auto-source `~/.sigma-migration/env`; to have the vars live in your own shell too, run `source ~/.sigma-migration/env` once per session.

Required env vars:
- `SIGMA_BASE_URL` — e.g. `https://aws-api.sigmacomputing.com`
- `SIGMA_CLIENT_ID`
- `SIGMA_CLIENT_SECRET`

Fetch a token at the start of each phase that needs one. **Shell-neutral (works
in bash, PowerShell, cmd):**

```
python scripts/get_token.py --workdir <WORK>
```

This writes `<WORK>/auth.json` (mode 0600); every Ruby/Python script reads it
automatically (explicit `SIGMA_API_TOKEN` in the env still wins). Tokens live
~1 hour — re-run when a call returns 401.

> **bash-only alternative:** `eval "$(scripts/get-token.sh)"` still works in
> bash. But never use `TOKEN=$(eval "$(scripts/get-token.sh)")` — `$()` creates a
> subshell where the exported var dies immediately; keep eval + curl in the same
> `bash -c '...'`. PowerShell/cmd cannot run this idiom at all — use
> `get_token.py` there.

> **Inline Python inside bash — DON'T.** Triple-nested escapes (`f"...{e.get(\\\"name\\\")}..."` inside `python3 -c "..."` inside `bash -c '...'`) silently break. Instead **always write a `.py` file with `Write` and call it via `python3 file.py`.** Same rule for any inline script over ~5 lines: write it to disk, then exec. It's not slower, it's deterministic, and the file becomes a reusable artifact. (Same applies to Ruby — prefer `ruby file.rb` over `ruby -e '...'`.)

### Tableau access — two modes

The skill supports two transports for Tableau-side discovery. **Prefer the
API/PAT path** — it is dramatically faster (measured on "Orders Conversion
Test", 7 views: **61.8s serial → 13.7–18.9s** with the unified fetch pool, zero
rate-limiting at pool 5). The MCP is the **no-PAT fallback only** (each MCP
fetch is a separate agent tool turn; the PAT CLI does everything in one
process).

| Mode | When to use | Setup |
|---|---|---|
| **PAT (REST)** — preferred | A Tableau PAT is available (run `setup-tableau.rb` once). Also the only path to `.twb` content (layout-hint extraction, embedded datasources) | `ruby scripts/setup-tableau.rb` once, then `eval "$(scripts/get-tableau-token.sh)"` per session |
| **MCP** — fallback | No PAT can be provisioned, and `mcp__tableau__*` tools are loaded in the session | None — host handles auth |

**PAT mode in one command:**

> **`migrate-tableau.rb` needs no token step** — it mints the Tableau token
> **in-process** (Ruby, no bash/`eval`), so the orchestrated path works as-is on
> Windows/PowerShell. The block below is only for **hand-driven** Tableau REST.
> Shell-neutral: `python scripts/get-tableau-token.py --print-token`. bash:

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/tableau-discover.rb \
  --workbook-id <luid> \
  --out <WORK>   # [--pool N] (default 5)
```

Produces the same artifacts as MCP-driven Phase 1 in a single run: `get-workbook.json`,
`workbook-content.twb`, `ds-metadata.json` + `graphql-fields.json` (VDS field list + GraphQL
formulas), `views/*.csv`, the dashboard PNG, **and `timings.json`** (per-task
start/duration/attempts — always written; it's the evidence trail for any future
"discovery is slow" report). Downstream scripts in Phases 2–6 are unchanged.
Full endpoint inventory and gotchas in `refs/tableau-rest.md`.

`--datasource-name` / `--datasource-luid` are **optional** — the script parses the
downloaded `.twb` for the first non-Parameters `<datasource caption='X'>` and looks it up
on the site automatically. Pass `--no-auto-ds` to disable, or `--datasource-luid` to force
a specific datasource when the workbook has multiple (`--datasource-luid` must be the
**full UUID** — the REST filter has no prefix matching).

**How the pool works (and why 5):** every fetch after the initial workbook GET
(.twb, VDS read-metadata, GraphQL fields, all view CSVs, dashboard PNG) goes
through ONE shared pool of 5 threads, enqueued longest-job-first — the PNG
render is the longest single fetch, so it starts at t≈0 and hides behind the
CSV batch. **5 is the measured sweet spot; 8 risks long-tail stragglers** — at
8 threads a contended VizQL session parked one CSV fetch for ~40s (56s total
run vs. 13.7–18.9s at 5). The pool keeps 429/timeout exponential backoff and
single-flight 401 re-mint machinery as insurance even though neither fired at
pool 5 in validation. Also note Tableau's **~60s server-side render cache**:
a view rendered within the last minute returns much faster, so back-to-back
runs land at the fast end of the range and cold-cache runs at the slow end —
don't read a 5s spread between runs as a regression.

> **One signin attempt only.** Tableau Cloud invalidates a PAT after 4 consecutive failed
> signins. `get-tableau-token.sh` runs exactly once; never wrap it in a retry loop.

---


## The workflow (progressive disclosure)

This spine is the **map**: it lists every phase, its one command, and its gate.
The **how / why / gotchas for each phase live in `refs/phase-*.md`** — open the
ref for the phase you're on, at the point you're on it. Don't try to hold all
1,600 lines of phase detail in your head; the flat version of this skill made
agents drop steps (esp. the Phase 1d dashboard-read) precisely because
everything competed for attention at once. Read the ref when you reach the step.

| # | Phase | One command / action | Gate → artifact | Detail |
|---|---|---|---|---|
| 0 | Preflight + intake | `doctor.sh`; `intake.rb` | `connection.json` | *(spine ↑)* |
| 0a | **Gap scan** (mandatory) | `scan-workbook-gaps.rb` | `gaps.json` — ❌ features → scout or `--force` | `refs/phase-0-scope.md` |
| 0b | Destination + mode (ask) | `pick-destination.rb` | folder id + conversion mode | `refs/phase-0-scope.md` |
| 1 | Discover the source | `tableau-discover.rb` (PAT) or MCP | `get-workbook.json`, `views/*.csv`, `.twb` | `refs/phase-1-discover.md` |
| 1d | **🚧 Dashboard read + anchors** | `get-view-image` (solo) → **Read** → write `png-read.json` + `source-anchors.json` | 🚧 `png-read.json` (`assert-dashboard-read.rb`) + `source-anchors.json` ≥5 anchors (final gate exit 18) | `refs/phase-1-discover.md`, `refs/source-anchors.md` |
| 1.5 | Reuse an existing DM | `find-or-pick-dm.rb` | `dm-match.json` (reuse-first) | `refs/phase-1_5-dm-reuse.md` |
| 2 | Warehouse column names | `discover-warehouse-columns.rb` | real column ids | `refs/phase-2-columns-filters.md` |
| 2.5 | View-level filters (mandatory) | detect from CSV distinct values | filters applied to the right grain | `refs/phase-2-columns-filters.md` |
| 3 | Build the DM spec | author → `validate-spec.rb --type datamodel` | clean `dm-spec.json` | `refs/phase-3-datamodel.md` |
| 4 | POST the DM + **read back** | `post-and-readback.rb --type datamodel` | `dm-ids.json` (server ids) | `refs/phase-4-post-dm.md` |
| 5 | Build the workbook | `build-charts-from-signals.rb` → `post-and-readback` → `build-dashboard-layout.rb` → `put-layout.rb` | `preflight_lint` clean; **layout is the LAST write** | `refs/phase-5-workbook.md` |
| 6 | **🚧 Parity + anchors + visual** | `phase6-parity.rb`; `verify-anchors.rb`; then `assert-dashboard-read.rb` + `assert-run-state.rb` + `assert-phase6-ran.rb` | 🚧 `parity-final.json` PASS + `anchors-verdict.json` pass + recorded visual verdict + full `run-state.json` chain | `refs/phase-6-parity.md`, `refs/source-anchors.md` |
| 5g | **RCF fidelity loop** | `fidelity-loop.rb` render → compare vs source → fix, until clean | 🚧 (opt-in) `fidelity-ledger.json` no unresolved spec-fixable deltas (gate 8d) | `refs/phase-5g-rcf.md` |
| E | Enhance (opt-in) | `enhance-scan.rb` → `enhance-apply.rb` | cloned "— Enhanced" workbook | `refs/phase-e-enhance.md` |
| — | Security RLS/CLS | detect always; apply opt-in | `apply_sigma_rls.py` | *(spine ↓)* |
| — | Telemetry (final) | `report-telemetry.py` | `telemetry-sent.json` | *(spine ↓)* |

> **The orchestrated path (`migrate-tableau.rb`, above) runs 0a–6 for you** and
> stops with exact instructions wherever agent judgment is required (the 🚧
> dashboard-read, parity actuals for pivot grids, master-calc overrides, gap
> escalations). Reach for the per-phase refs below when you drive a phase by hand
> or need to understand what the orchestrator did / why it stopped.

---

## Phase stanzas (open the ref for the one you're on)

### Phase 0 — scope: gap scan, destination, mode, cost — `refs/phase-0-scope.md`
Run `scan-workbook-gaps.rb` on the `.twb` **before anything else** (emits
`gaps-report.md` + `gaps.json`; ❌-unhandled features go to the gap-scout subagent
or `--force`). Then pick where to build (`pick-destination.rb`) and the conversion
mode, and estimate token cost. **After the gap scan + cost estimate, execute the
model-fit checkpoint** (`refs/model-fit.md` §3): large/very-large bucket (or >1
dashboard / >30 zones / any ❌ gap rows / >50 calcs) on a non-top-tier model →
ask the user once before proceeding; never silently proceed on very-large.
**Full detail, incl. blend detection + gap-scout protocol: `refs/phase-0-scope.md`.**

### Phase 1 — discover the source — `refs/phase-1-discover.md`
PAT mode: `tableau-discover.rb` fetches workbook + views + `.twb` + VDS/GraphQL +
the dashboard PNG in one pooled run. MCP mode is the no-PAT fallback. Discover
calc fields (`extract-calc-fields.rb`) and Custom SQL (`extract-custom-sql.rb`)
here. **Full detail (fetch patterns, calc discovery, custom-SQL fallback):
`refs/phase-1-discover.md`.**

> **🚧 GATE — Phase 1a: ANY numeric Tableau URL (project *or* workbook) MUST go
> through the resolver.** When the user hands you a Tableau URL like
> `.../#/site/<site>/projects/1234567` **or**
> `.../#/site/<site>/workbooks/4242001/views`, that number is a **vizportal URL
> id** the REST API cannot resolve (no REST endpoint carries it). Run
> `ruby scripts/resolve-project.rb --url "<url>"` **before anything else**.
> Exit 0 → migrate exactly the workbook(s) it lists (a workbook URL resolves
> straight to `{workbook_luid, name, project_luid, project_name}` — no
> hand-searching). **Exit 2 → STOP and ask the user, presenting the printed
> candidate list — do not proceed.** Guessing from name or recency is a **gate
> violation**: a wrong guess silently points the ENTIRE run (discovery, DM,
> workbook, parity) at the wrong content — one real field session burned 6
> hours migrating the wrong project, another burned 20 minutes hand-hunting a
> workbook it had a DIRECT link to. Query shape + why REST can't do it:
> `refs/tableau-rest.md`.
>
> **`/views/<slug>/<view>` share links (the MOST COMMON shape) are handled by the
> orchestrator directly** — paste the whole URL as `--workbook "<url>"` and
> `migrate-tableau.rb` resolves the workbook via the REST `contentUrl:eq:` filter
> (`Tableau.find_workbook_by_content_url`). Do NOT hand the slug to
> `--workbook <name>`: a workbook's display Name routinely diverges from its
> contentUrl slug, so the name lookup misses (three independent field runs each
> rediscovered this the hard way).

> **🚧 GATE — Phase 1d dashboard-read.** The CSVs give you numbers, not the
> dashboard. **Read the source dashboard PNG** (`get-view-image` on the
> *dashboard view*, solo) and write `<workdir>/png-read.json` enumerating EVERY
> tile with its Sigma `kind`, plus `text_elements` and `filter_shelf` (schema in
> `refs/phase-1-discover.md`). `build-charts-from-signals.rb` **refuses to build
> without it**; the orchestrator hard-stops **before posting the DM** if it's
> missing. Confirm with `ruby scripts/assert-dashboard-read.rb --workdir <WORK>`.
> This is the fix for the #1 escape: right numbers, missing tiles. Escape hatch
> `--skip-dashboard-read "<reason>"` (name it in your report).

> **🚧 GATE — Phase 1d source-value anchors (MANDATORY checklist item).** While
> you are reading that same PNG, **transcribe the printed numbers into
> `<workdir>/source-anchors.json` — EXACTLY as printed** (keep the raw string:
> `"18,037B"`, never `18037`; `"(12.3%)"`, never `-0.123`). Minimum anchors —
> **every KPI value, the top 3 values of every ranked list/table, and one
> representative bucket value per chart** (≥ 5 total). Schema:
>
> ```json
> {
>   "source_image": "views/<dashboardViewId>.png",
>   "transcribed_at": "2026-07-08T12:00:00Z",
>   "anchors": [
>     { "id": "a1", "panel": "TOP COUNTRIES", "label": "United States GDP",
>       "raw": "18,037B", "kind": "currency",
>       "sigma_element_hint": "Top Countries" }
>   ]
> }
> ```
>
> `kind` ∈ `currency|number|percent`; `sigma_element_hint` (optional) names the
> Sigma element the value should land in. These anchors are the **measured value
> bar**: Phase 6 runs `verify-anchors.rb`, which checks every printed value
> against the LIVE workbook's element exports at the printed precision — a
> printed source value that appears NOWHERE in the exports means the numbers are
> wrong (wrong unit/10x, wrong aggregate, collapsed buckets). The final gate
> **fails (exit 18)** whenever a source dashboard PNG exists but anchors are
> missing (< 5) or unverified/failing. Two field migrations shipped wrong
> numbers behind passing visual verdicts — this is the fix. Why + rules + worked
> example: `refs/source-anchors.md`. Escape hatch `--skip-anchors-gate
> "<reason>"` (counted against the waiver budget; name it in your report).

### Phase 1.5 — reuse an existing DM (do this first) — `refs/phase-1_5-dm-reuse.md`
`find-or-pick-dm.rb` scores existing org DMs; reuse-first collapses DM sprawl and
skips Phases 2–3. When reusing a differently-shaped DM, run the 1.5b shape
preflight (`inspect-dm-shape.rb`). **Detail: `refs/phase-1_5-dm-reuse.md`.**

### Phase 2 + 2.5 — warehouse columns + view filters — `refs/phase-2-columns-filters.md`
Resolve real warehouse column names (`discover-warehouse-columns.rb`). On a 404
(catalog miss), **force a catalog sync and retry first**: `POST
/v2/connections/{connectionId}/sync` with body `{"path":["DB","SCHEMA","TABLE"]}`
(works — verified 2026-07-07, 48/48 freshly-landed tables) — only fall back to
Custom SQL (INFORMATION_SCHEMA probe) if the retry still 404s. Then **detect
view-level filters** (mandatory) by diffing each view CSV's distinct values
against the source and apply them at the correct grain.
**Detail: `refs/phase-2-columns-filters.md`.**

### Phase 3 — build the DM spec — `refs/phase-3-datamodel.md`
Author the data-model spec (warehouse-table element for plain columns, `sql`
elements for window/LOD calcs), translate Tableau calc fields, then
`validate-spec.rb --type datamodel` before POST. Schema in `refs/data-model-spec.md`;
**workflow detail (custom-SQL element rules, calc translation, Coalesce/null
fallthrough): `refs/phase-3-datamodel.md`.**

### Phase 4 — POST the DM + read back — `refs/phase-4-post-dm.md`
`post-and-readback.rb --type datamodel` POSTs, then GETs the spec back for the
server-assigned element ids the workbook binds to (the column-type guard aborts
on any `type=error` column). **Detail: `refs/phase-4-post-dm.md`.**

### Phase 5 — build the Sigma workbook — `refs/phase-5-workbook.md`
`build-charts-from-signals.rb` (🚧 requires `png-read.json`) → `preflight_lint.rb`
(mandatory, pre-POST) → `post-and-readback.rb --type workbook` → `build-dashboard-layout.rb`
→ `put-layout.rb`. **Apply the layout as the LAST write** — a bare spec PUT wipes
it. Then compile-check every element. **Full detail (spec writing, param
metric-switch, coverage WARN vs NOTE, layout XML): `refs/phase-5-workbook.md`.**

### Phase 6 — 🚧 parity + anchors + visual verification (hard-gated) — `refs/phase-6-parity.md`
`phase6-parity.rb` diffs Sigma actuals vs Tableau (EXACT for warehouse-backed;
`--extract-mode` only for `hasExtracts=true`). **Phase 6f visual is mandatory:**
render the full Sigma page and Read it against the source dashboard PNG. Finish
with the gate sequence:
```bash
ruby scripts/assert-dashboard-read.rb --workdir <WORK>                  # 🚧 Phase 1d belt
ruby scripts/verify-anchors.rb --workdir <WORK> --workbook-id <wb>      # 🚧 measured value bar → anchors-verdict.json
ruby scripts/assert-run-state.rb --workdir <WORK>                       # 🚧 phase-chain ledger audit
ruby scripts/assert-phase6-ran.rb --workdir <WORK> --workbook-id <wb>   # 🚧 hard gate — must exit 0
```
**A conversion is NOT done until `assert-phase6-ran.rb` exits 0** (which stamps
`<WORK>/phase6-success.json`). Confirm it before claiming success with the single
offline check — `ruby scripts/verify-complete.rb --workdir <WORK>` must print
✅ DONE / exit 0. The marker is **run-scoped**: a migration may be reported
complete ONLY when `<WORK>/phase6-success.json` exists **for the current run id**
(the gate deletes a stale marker from a previous run on any failure) — quote the
marker's workbook id + run id verbatim in your report. Full detail
(raw-warehouse mode, triage, visual checklist): `refs/phase-6-parity.md`.

**No-standalone-views path (dashboard-embedded worksheets).** When the source
dashboard's worksheets are embedded-only (no standalone views to export CSVs
from), chart-by-chart CSV parity may be genuinely unavailable. The parity
oracle is then **anchors + warehouse** — `verify-anchors.rb` (printed source
values found in the live exports) plus `verify-warehouse.rb` (elements evaluate
against real warehouse data). **`--skip-parity-gate` alone is no longer a valid
combination:** the gate **rejects it (exit 18)** unless `anchors-verdict.json`
exists and passes. The anchors oracle replaces parity — never nothing.

**Visual-similarity floor (measured).** When `scripts/visual-similarity.py` is
present, the gate runs
`python3 scripts/visual-similarity.py --source <src> --render <render> --json-out <WORK>/visual-similarity.json`
and fails (exit 20) when its JSON `pass` field is false — a measured companion
to the recorded visual verdict (details: `refs/visual-similarity.md`). Escape
`--skip-visual-similarity "<reason>"` (counted as a waiver).

> **Waiver discipline — waivers are for impossibilities, not obstacles.** Every
> `--skip-*` / `--allow-*` / `--accept-*` / `--min-pass-rate <1` flag is an
> attestation that a verification could NOT run — not a lever to turn a red gate
> green. The gate now enforces this: it stamps `waivers` + `waiver_count` into
> `parity-final.json` on every run, **more than 2 quality waivers caps the
> migration at YELLOW** (exit 19 — "GREEN unavailable"; `--skip-telemetry-gate`
> and the sanctioned builder→verifier `--skip-visual-comparison` handoff are
> policy exclusions), and **data-class fidelity residuals can never be waived at
> all** — the numbers are wrong; fix or reclassify with evidence. Reaching for a
> third waiver means the run is telling you something: stop and fix.

### Phase 5g — RCF (render-compare-fix) fidelity loop — `refs/phase-5g-rcf.md`
After the workbook renders, iterate composition to convergence: `fidelity-loop.rb render`
exports the page → **Read it against the source dashboard PNG** and score every dimension
(`refs/fidelity-rubric.md`) → `record` each delta (spec-fixable / ui-only / sigma-capability /
data) → author a fix from `refs/fidelity-recipes.md` and `apply-patch` (single layout-preserving
PUT) → loop until `fidelity-loop.rb status` is clean. Opt-in hard gate: `migrate-tableau.rb
--finalize` passes `--require-fidelity-ledger` (gate 8d, exit 15) unless disabled with
`--rcf-passes 0`. **Full loop, rubric, and delta→fix catalog: `refs/phase-5g-rcf.md`,
`refs/fidelity-rubric.md`, `refs/fidelity-recipes.md`.**

### Phase E — enhance (opt-in) — `refs/phase-e-enhance.md`
After all gates are green, `enhance-scan.rb` proposes read-only enhancement
candidates; `enhance-apply.rb` applies only accepted ones to a **cloned** workbook
(the parity artifact is never mutated). **Detail: `refs/phase-e-enhance.md`.**

### Troubleshooting — `refs/troubleshooting.md`
Common failure modes + fixes: `refs/troubleshooting.md`.

---

## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_tableau_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for Tableau:** calculated fields using `USERNAME()`/`ISMEMBEROF('group')`/`USERATTRIBUTE('attr')` (translated to `CurrentUserEmail()` / `CurrentUserInTeam("group")` / `CurrentUserAttributeText("attr")`). Cross-element (dim-attribute) RLS is reported with a warning to apply on the owning element/derived view.

**Flow (only runs when `result.security` is non-empty — zero overhead otherwise):**
1. **Convert + post** the data model as usual. Capture the `dataModelId` and the converter's `result.security[]` (write it to `security.json`).
2. **Gate (opt-in/out, default _Port_).** Show a plain-English summary of each detected rule + recommended Sigma mapping, then ask: **Port** (recommended) / **Customize** (review per-rule attribute/team mapping + username-to-email reconciliation) / **Skip** (migrated model shows ALL rows to everyone). Reuse-first: existing Sigma user attributes/teams are matched before creating new ones.
3. **Provision + apply** with the shared engine:
   ```bash
   python scripts/get_token.py --workdir <WORK>   # shell-neutral; writes <WORK>/auth.json (read automatically)
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId>            # plan only (default)
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId> --provision --apply
   ```
   `--provision` creates missing user attributes / teams; `--apply` PATCHes the boolean RLS calc column + fail-closed `filters` entry and the `columnSecurities` (CLS) onto the matching element.
4. **Assign membership.** Assign per-user attribute values / team membership from the source tool's group/role membership (the converter reports the attribute/team names; the values come from the source's user mapping).

**Skip is loud:** opting out leaves the migrated model with NO RLS — all rows visible to everyone. Confirm before skipping.


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
