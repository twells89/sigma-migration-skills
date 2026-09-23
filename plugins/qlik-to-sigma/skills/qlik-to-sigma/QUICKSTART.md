author: Sigma Computing
summary: Migrating from Qlik made easy — convert Qlik Sense apps to Sigma with Claude Code
id: developers_migrating_from_qlik_made_easy
categories: Developers, Migration, AI
environments: Web
status: Draft
feedback link: https://github.com/sigmacomputing/quickstarts-public/issues

# Migrating from Qlik Sense to Sigma made easy

## Introduction & why it matters
Duration: 2

Rebuilding Qlik Sense apps in a new BI tool by hand is slow and error-prone — you
re-derive the data model from the load script, re-type every master measure, and
hope the numbers still tie out.

This quickstart automates the whole path with **your coding agent** (Claude Code,
Cursor, Cortex Code, …) + a set of Qlik→Sigma skills: it discovers a Qlik app,
translates its master measures and expressions to Sigma formulas, builds a Sigma data
model and matching workbook, and **verifies data parity** against the same warehouse —
typically to the cent.

positive
: These skills are **agent-neutral** — each is a `SKILL.md` plus `scripts/`. `AGENTS.md` at the repo root maps each task to its skill, and the scripts auto-load credentials from `~/.sigma-migration/env`, so they run the same under any agent. Where this guide says "Claude Code," substitute your agent.

positive
: The Sigma side reads your warehouse **live**, so the migrated workbook stays current with no reload/extract step — a difference you'll see in the parity check when new rows land.

positive
: Qlik conversion has two supported runtime profiles. `auto` prefers Ruby and
falls back to Python when Ruby is unavailable. The no-Ruby profile requires
**Python 3 + Node** (Node runs the vendored converter); select it explicitly
with `--runtime-profile python`. See `PYTHON_RUNTIME.md`.

## Who this is for
Duration: 1

- Sigma SEs and technical CSMs
- Migration partners
- Qlik developers evaluating a move to Sigma

You do **not** need to be a Sigma or Qlik internals expert — the skills carry the
domain knowledge. You need either live Qlik access or a corectl unbuild export,
plus a Sigma org whose connection reaches the same warehouse the Qlik app loads from.

## Prerequisites
Duration: 2

- **A coding agent that runs skills** — Claude Code (CLI or desktop), Cursor, Cortex Code, etc.
- **qlik-cli** on your PATH for live discovery (official; reaches both the REST API and the Engine/qix API). If the customer supplies a standard `corectl unbuild` folder instead, qlik-cli and live Qlik access are not required; use `--unbuild <dir>`.
  - **On-prem (client-managed) Qlik Sense instead of Cloud?** Skip qlik-cli — it's
    Cloud-only. Use the bundled shim `qlik-onprem-shim.py` (QRS + Engine
    WebSocket, same command surface) instead. It ships **inside this skill**, in the
    same `scripts/` folder as everything else: `scripts/qlik-onprem-shim.py` and the
    auth guide `refs/connection-onprem.md` are **relative to the skill directory**
    (the folder this QUICKSTART lives in — `plugins/qlik-to-sigma/skills/qlik-to-sigma/`
    in the source repo, `qlik-migration-skills/qlik-to-sigma/` in the published
    quickstart). Don't create a qlik-cli context — follow
    **[On-prem setup](#on-prem-setup-client-managed-qlik-sense)** below in place of
    Installation steps 6–7. A shim-driven discovery is verified output-identical to a
    qlik-cli run on the same app — though that verification was against Qlik *Cloud*
    (identical QIX protocol); the on-prem auth/QRS path is unproven live (see the
    note in the On-prem setup section). QlikView ≠ Qlik Sense: `.qvw` apps migrate
    via the developer-opt-in `-prj` project folder — `python3
    scripts/migrate-qlik.py --prj <Name-prj> --connection <ID>` (or the
    selected Ruby entrypoint) runs the full pipeline (**data model +
    workbook**, laid out from the `-prj` sheet geometry). With no live Qlik
    engine, the default warehouse-executability check stays non-strict/RED;
    pass independently queried values through `--warehouse-expected` for strict
    completion — see the QlikView note in SKILL.md.
- **Qlik Cloud access for live discovery** — an API key *or* an OAuth client (Admin → OAuth). For creating/round-tripping content, an **M2M impersonation** client is ideal (acts as a real user so content is visible). Not required for `--unbuild`.
- **Sigma API credentials** (`SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`).
- A **Sigma connection to the same warehouse** the Qlik app loads from (for true parity). The skill discovers its tables and columns through Sigma REST, so no Snowflake credentials, SQL CLI, or MCP are required.
- The **`convert_qlik_to_sigma`** converter — ships inside the skill as a local vendored bundle (`converter/qlik.mjs`, run in-process via `node`, no clone/npm/network); the sigma-data-model MCP tool of the same name is only a manual fallback if the bundle is somehow missing.

negative
: A *plain* M2M OAuth client can authenticate and discover apps, but it (a) only sees content in spaces it's a member of and (b) cannot reload apps that use space data-connections. Use an API key or an M2M-impersonation client for anything beyond read-only discovery.

## The two-skill ecosystem
Duration: 2

| Skill | Role |
|---|---|
| **`qlik-assessment`** | Inventory a tenant + score per-app migration complexity (expression convertibility, chart-type coverage, Section Access / DirectQuery flags) → a value/cost-ranked shortlist. Run this first to decide what to migrate. |
| **`qlik-to-sigma`** | The conversion: discover → reconcile columns → translate expressions → build Sigma data model + workbook → parity-verify → screenshot. |

Both mirror the Tableau and Power BI migration skills: same `value/(1+cost)` shortlist
math and the same `migrate-first / easy-win / moderate / needs-gap-scout / retire` tags.

## Installation & setup
Duration: 5

1. **Clone the skills** (sparse checkout of the migration folder):
   ```bash
   git clone --filter=blob:none --sparse https://github.com/sigmacomputing/quickstarts-public
   cd quickstarts-public && git sparse-checkout set qlik-migration-skills
   ```
2. **Make the skills available to your agent:**
   - **Claude Code** — symlink them in:
     ```bash
     ln -s "$PWD/qlik-migration-skills/qlik-to-sigma"   ~/.claude/skills/qlik-to-sigma
     ln -s "$PWD/qlik-migration-skills/qlik-assessment" ~/.claude/skills/qlik-assessment
     ```
   - **Other agents (Cursor, Cortex Code, …)** — no install step; open the repo and point your agent at the skill folder. `AGENTS.md` at the repo root indexes every skill.
3. **Bootstrap and doctor** — from the Qlik conversion skill directory, select
   the supported Python profile to run with no Ruby (Node remains required):
   ```bash
   bash scripts/bootstrap.sh --runtime-profile python --workdir <WORK>
   bash scripts/doctor.sh --runtime-profile python --workdir <WORK>
   ```
   Windows PowerShell: `scripts\bootstrap.ps1 -RuntimeProfile python -WorkDir
   <WORK>` and `scripts\doctor.ps1 -RuntimeProfile python -WorkDir <WORK>`.
   `--runtime-profile auto` uses Ruby when healthy and otherwise falls back to
   Python.
4. **Sigma credentials** — export `SIGMA_CLIENT_ID` /
   `SIGMA_CLIENT_SECRET`, then persist them with the selected profile:
   ```bash
   python3 scripts/setup.py --from-env
   python3 scripts/vendor/get_token.py --workdir <WORK>  # optional token file
   ```
   Interactive setup is `python3 scripts/setup.py`; the Ruby profile's
   `setup.rb` and `vendor/get-token.sh` remain supported. Both profiles write
   the same neutral `~/.sigma-migration/env`.
5. **Sigma connection** — resolve it once and cache it in the workdir:
   ```bash
   python3 scripts/intake.py --workdir <WORK> --tool qlik-to-sigma \
     --mode live [--connection <id>] [--name <name-substring>]
   ```
   Multiple matches write `connection-candidates.json` and stop; pick one and
   rerun with `--connection`.
6. **Destination** — if the user did not supply one, list choices and ask:
   ```bash
   python3 scripts/pick_destination.py list
   python3 scripts/pick_destination.py create --name "<name>" \
     [--parent <workspace-or-folder-id>]
   ```
   Pass the chosen id to `--folder`; never guess.
7. **Qlik context** — create a qlik-cli context (do this in your own terminal so the secret stays out of any transcript):
   ```bash
   # API key (acts as you):
   qlik context create sigma-migration --server https://<tenant>.<region>.qlikcloud.com --api-key 'KEY'
   # OR M2M impersonation (acts as a chosen user → content is owned-by/visible-to them):
   #   token = POST {tenant}/oauth/token  grant_type=urn:qlik:oauth:user-impersonation
   #           user_lookup={field:"subject"|"email", value:...}
   #   then: qlik context create impersonate --server <tenant> --api-key '<impersonation-token>'
   qlik context use sigma-migration
   ```
8. **Verify:** `qlik item ls --resourceType app --limit 5` returns your apps.

## On-prem setup (client-managed Qlik Sense)
Duration: 5

negative
: **Skip this whole section if you're on Qlik Cloud** — you already did Installation steps 7–8. This section *replaces* steps 7–8 for client-managed Qlik Sense Enterprise on Windows. `qlik-cli` is Cloud-only, so there is **no qlik-cli context and no `qlik context create`** on-prem — the bundled shim provides the same command surface over the on-prem APIs.

All paths below are **relative to the skill directory** — the folder that holds this QUICKSTART, `SKILL.md`, `scripts/`, and `refs/`. `cd` into it first so `scripts/...` and `refs/...` resolve and `$PWD` is correct:

```bash
cd plugins/qlik-to-sigma/skills/qlik-to-sigma   # source repo layout
#   (published quickstart: cd qlik-migration-skills/qlik-to-sigma)
ls scripts/qlik-onprem-shim.py refs/connection-onprem.md   # both should exist
```

1. **Install the Engine transport:**
   ```bash
   pip3 install websocket-client      # PEP 668 machines: add --user, or use a venv
   ```
2. **Configure auth** per [`refs/connection-onprem.md`](refs/connection-onprem.md) — two supported paths:
   - **Certificates** (best for automation): QMC → Certificates → export PEMs; the skill machine needs ports **4242** (QRS) + **4747** (Engine) open to the server.
   - **JWT virtual proxy**: admin adds a JWT virtual proxy; everything stays on **443**.

   Either way, put the env in `~/.sigma-migration/qlik-onprem.env` (the ref has a copy-paste block for each path) and `source` it. Use a **read-access service account** on the streams in scope.
   ```bash
   source ~/.sigma-migration/qlik-onprem.env
   ```
3. **Point the pipeline at the shim** — `qlik-discover.py` honors `QLIK_BIN`:
   ```bash
   export QLIK_BIN="$PWD/scripts/qlik-onprem-shim.py"
   ```
4. **Verify** (the shim's equivalent of Installation step 7):
   ```bash
   python3 scripts/qlik-onprem-shim.py item ls --resourceType app --limit 5
   ```
   This should list your on-prem apps. From here **every step below runs unchanged** — wherever the guide says a `qlik ...` command or `--context <ctx>`, the shim handles it via `QLIK_BIN` (no context flag needed).

positive
: The shim's command/output layer is verified **output-identical to qlik-cli — against a live Qlik *Cloud* tenant** (the QIX protocol is identical on-prem, so the command-parsing and output-shaping logic carries over). The **on-prem-specific path has not yet been run live**: certificate/JWT auth, the QRS layer (Cloud has no QRS), and the Engine transport against an on-prem server are code-complete but unproven end-to-end — **your engagement is the first live test.** If a first connection misbehaves, expect to debug auth/ports/proxy here, not in discovery or conversion. Failure is bounded: without QRS, only `appName`/`lastReloadTime`/Section-Access metadata degrade — discovery still completes off the Engine layer.

## Prepare demo data (optional)
Duration: 3

If you don't have a Qlik app to migrate, build one against your warehouse (e.g. a
Snowflake retail star: `ORDER_FACT` + `CUSTOMER_DIM` / `PRODUCT_DIM` / `STORE_DIM` /
`DATE_DIM`). Create a Qlik **shared space**, a Snowflake **data connection**, an app
with a load script, a few **master measures** (e.g. `Sum(NET_REVENUE)`, set-analysis
`Sum({<IS_HOLIDAY={1}>} NET_REVENUE)`), and a sheet of charts. Make sure your Sigma
connection points at the same schema.

## Run the conversion
Duration: 10

In your coding agent, point the `qlik-to-sigma` skill at an app. Run the
front door selected in `<WORK>/doctor.json`; do not hand-drive the phases.
The supported no-Ruby live command is:

```bash
python3 scripts/migrate-qlik.py \
  --app <id> --context <qlik-cli-context> \
  --connection <sigma-connection-id> \
  --database <database> --schema <schema> \
  --folder <sigma-folder-id> --out <WORK> --yes
```

The Ruby profile remains supported as `ruby scripts/migrate-qlik.rb` with the
same source, connection, warehouse, destination, and workdir flags. The Python
entrypoint also reads `<WORK>/connection.json`, so `--connection` may be omitted
after `intake.py`; neither path guesses among connections.

For a credentials-free, network-free offline conversion, create doctor evidence
in the explicit offline mode first:

```bash
export SIGMA_OFFLINE_DRY_RUN=1
bash scripts/bootstrap.sh --runtime-profile python --workdir <WORK>
python3 scripts/migrate-qlik.py \
  --from-discovery fixtures/retail-orders \
  --connection 00000000-0000-0000-0000-000000000000 \
  --database DEMO_DB --schema DEMO \
  --dry-run --yes --out <WORK>
```

Unset `SIGMA_OFFLINE_DRY_RUN` before any live build.

Both entrypoints chain these phases:

1. **Discover** (`qlik-discover.py`) — pull the load script (data model), master
   measures/dimensions (via an Engine `MeasureList`/`DimensionList`), sheet/chart
   defs + per-sheet **cell grids** (layout), and the app's **freshness** metadata
   (lastReloadTime + an engine snapshot of the KPI totals) into `converter-input.json`
   and friends. The freshness preflight then tells you up front when the Qlik app is
   stale and Sigma (live warehouse) will show more data.
   For an offline `corectl unbuild`, use `--unbuild <dir>` instead of `--app`;
   nested `qChildren` are flattened into the same charts/layout artifacts.
2. **Reconcile** (`reconcile-columns.py`) — auto-derive the Qlik-field → real-warehouse
   column map from the load script's `AS` aliases (`ORDER_STORE_KEY AS STORE_KEY`).
   `preflight-warehouse.rb` then resolves the tables and columns through the supplied
   Sigma connection's REST catalog, without direct warehouse access.
3. **Convert** — the local vendored converter (`converter/qlik.mjs` via `node`, no clone/
   npm/network/MCP/data-egress) runs `convertQlikToSigma`, turning master measures into
   Sigma metrics and building relationships from shared keys. **Set Analysis** → Sigma
   `SumIf`/`CountIf`. A dev build wins via `QLIK_MCP_DIR`; the hosted
   `convert_qlik_to_sigma` MCP tool is only a manual fallback if no converter is found.
4. **Build the data model** (`gen-denorm-sql.py` + `build-sigma-dm.py`) — a clean star
   plus a denormalized SQL element. Supported row-wise LOAD expressions such as
   `If(Match(...))` compile to SQL `CASE`; unsupported expressions block rather than
   disappear. The DM and workbook are dry-compiled and source-coverage-linted before
   the first POST to `/v2/dataModels/spec`.
5. **Build the workbook** (`build-sigma-workbook.py`) — one Sigma page per Qlik sheet,
   KPIs/charts/tables translated from each object's hypercube; `put-layout.rb` applies
   the Qlik cell grid mapped onto Sigma's 24-col grid.
6. **Verify parity** — freshness banner first, then metric-by-metric values AND
   per-chart bucket counts vs the Qlik engine (so suppressed-null-bucket mismatches
   surface even when the shared cells match).

positive
: Before building a new data model (Phase 2.5), the skill runs a **DM-reuse check** (`qlik-dm-signature.py` + `scripts/vendor/find-or-pick-dm.rb`): it scores the org's existing Sigma data models against the app's tables/columns and on a strong match asks reuse-vs-new — avoiding DM sprawl and skipping the build entirely.

positive
: For a whole tenant, `batch-migrate.py` converts many apps in one pass (one Sigma workbook each), reusing a shared data model.

## Understanding the output
Duration: 3

- **Assessment readout** (`qlik-assessment`) — per-app complexity (expression buckets,
  chart-type coverage, Section Access / DirectQuery flags) and a ranked shortlist.
- **Parity check** — the migration is GREEN only when Sigma's numbers match the
  warehouse (the skill hard-gates on this).
- **Screenshots** (`qlik-screenshot.py`) — before/after PNGs (Qlik's reporting API
  exports a single visualization as PNG; whole-sheet export is PDF).

## Reference & gotchas
Duration: 3

`refs/sigma-build-gotchas.md` collects the hard-won rules, including:

- **Feed the converter the Qlik *model*** (post-load-script field names), not raw
  warehouse tables — the renames are what produce a clean star.
- **SQL element**: source field is `statement` (not `sql`); column formula
  `[Custom SQL/<RAW_ALIAS>]`.
- **Tables aggregate via `groupings`** (`groupBy` + `calculations`); bar/line via
  `xAxis`/`yAxis`; pie/donut via `value`+`color`; combo via dual-axis `yAxis.columnIds`.
- **Workbook layout** is a separate `document.layout` XML step (1-based grid lines) —
  the workbook body is `document`-wrapped as of 2026-08-03; see `refs/sigma-build-gotchas.md`.
- **Building Qlik fixtures:** charts created via the API render only as `auto-chart`
  (concrete `bar`/`line`/`pie` come up blank); sheets must be UI-created (or impersonated)
  to list in the hub; copy an app to clone its data without a reload.
- **"tables=0" / empty data model = the identity can't read the app's load script.**
  Discovery fetches the app's load script (the data-model source of truth) via the
  Qlik engine `GetScript`. If the connecting identity doesn't own the app (someone
  else's app, unpublished), `GetScript` returns `GENERIC ACCESS DENIED` and discovery
  now **hard-fails** (`FATAL: load script is empty`, exit 3) instead of silently
  building an empty model. Fix: run discovery as the **app owner**, copy/transfer the
  app so your identity owns it, or publish it to a managed space your identity can read.
  This is the #1 cause of a Qlik migration "running but producing nothing useful" —
  the M2M client must act as a user who can actually read the app (see Prerequisites).
  DirectQuery apps legitimately have no load script and are exempt.
- **Empty `measures.json` is not an empty app.** In a corectl export, charts can be
  inline children of a sheet under `qChildren`; `--unbuild` recursively extracts them.
- **A Data-only workbook cannot pass.** `workbook-coverage.json` must show every
  authored queryable source visual rebuilt and at least one queryable Sigma element,
  in dry-run and live modes.

## The techniques worth carrying forward
Duration: 1

- **Assess first** — convert the high-value, low-effort apps before the long tail.
- **Reconcile from the load script** — the `AS` aliases *are* the column map.
- **Treat the warehouse as the source of truth** — Sigma reads it live; parity is the gate.
- **Set Analysis → `SumIf`** — most Qlik selection logic maps cleanly.
- **Scale with `batch-migrate`** — a tenant of apps in one pass.

Next: run `qlik-assessment` on your tenant, pick the shortlist, and let `qlik-to-sigma`
convert the top N.
