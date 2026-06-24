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

## Who this is for
Duration: 1

- Sigma SEs and technical CSMs
- Migration partners
- Qlik developers evaluating a move to Sigma

You do **not** need to be a Sigma or Qlik internals expert — the skills carry the
domain knowledge. You do need access to a Qlik Cloud tenant and a Sigma org whose
connection reaches the same warehouse the Qlik app loads from.

## Prerequisites
Duration: 2

- **A coding agent that runs skills** — Claude Code (CLI or desktop), Cursor, Cortex Code, etc.
- **qlik-cli** on your PATH (official; reaches both the REST API and the Engine/qix API — the Engine API is required for sheet/chart definitions, the data model, and the load script). Install the GitHub-release binary from `qlik-oss/qlik-cli`.
  - **On-prem (client-managed) Qlik Sense instead of Cloud?** Skip qlik-cli — it's
    Cloud-only. Use the bundled shim `qlik-onprem-shim.py` (QRS + Engine
    WebSocket, same command surface) instead. It ships **inside this skill**, in the
    same `scripts/` folder as everything else: `scripts/qlik-onprem-shim.py` and the
    auth guide `refs/connection-onprem.md` are **relative to the skill directory**
    (the folder this QUICKSTART lives in — `plugins/qlik-to-sigma/skills/qlik-to-sigma/`
    in the source repo, `qlik-migration-skills/qlik-to-sigma/` in the published
    quickstart). Don't create a qlik-cli context — follow
    **[On-prem setup](#on-prem-setup-client-managed-qlik-sense)** below in place of
    Installation steps 4–5. A shim-driven discovery is verified output-identical to a
    qlik-cli run on the same app. QlikView ≠ Qlik Sense: not covered.
- **Qlik Cloud access** — an API key *or* an OAuth client (Admin → OAuth). For creating/round-tripping content, an **M2M impersonation** client is ideal (acts as a real user so content is visible).
- **Sigma API credentials** (`SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`).
- A **Sigma connection to the same warehouse** the Qlik app loads from (for true parity).
- The **`convert_qlik_to_sigma`** converter (part of the sigma-data-model MCP).

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
3. **Sigma credentials** — export `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` (or run `ruby scripts/setup.rb` in the tableau-to-sigma skill, which writes a neutral `~/.sigma-migration/env` the scripts auto-source under any agent). The skill's `scripts/vendor/get-token.sh` exchanges them for a `SIGMA_API_TOKEN`.
4. **Qlik context** — create a qlik-cli context (do this in your own terminal so the secret stays out of any transcript):
   ```bash
   # API key (acts as you):
   qlik context create sigma-migration --server https://<tenant>.<region>.qlikcloud.com --api-key 'KEY'
   # OR M2M impersonation (acts as a chosen user → content is owned-by/visible-to them):
   #   token = POST {tenant}/oauth/token  grant_type=urn:qlik:oauth:user-impersonation
   #           user_lookup={field:"subject"|"email", value:...}
   #   then: qlik context create impersonate --server <tenant> --api-key '<impersonation-token>'
   qlik context use sigma-migration
   ```
5. **Verify:** `qlik item ls --resourceType app --limit 5` returns your apps.

## On-prem setup (client-managed Qlik Sense)
Duration: 5

negative
: **Skip this whole section if you're on Qlik Cloud** — you already did Installation steps 4–5. This section *replaces* steps 4–5 for client-managed Qlik Sense Enterprise on Windows. `qlik-cli` is Cloud-only, so there is **no qlik-cli context and no `qlik context create`** on-prem — the bundled shim provides the same command surface over the on-prem APIs.

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
4. **Verify** (the shim's equivalent of step 5):
   ```bash
   python3 scripts/qlik-onprem-shim.py item ls --resourceType app --limit 5
   ```
   This should list your on-prem apps. From here **every step below runs unchanged** — wherever the guide says a `qlik ...` command or `--context <ctx>`, the shim handles it via `QLIK_BIN` (no context flag needed).

positive
: The shim's Engine/QIX layer is **live-verified** (output-identical to qlik-cli on the same app). The QRS layer + on-prem auth bootstrap are code-complete but newer — if a first connection misbehaves, expect to debug auth/ports here, not in discovery or conversion. Without QRS only `appName`/`lastReloadTime` metadata degrade; discovery still completes.

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

In Claude Code, point the `qlik-to-sigma` skill at an app. The whole pipeline is ONE
command (`ruby scripts/migrate-qlik.rb --app <id> --connection <sigma-conn> --yes`) —
it chains these phases (each also independently runnable from `scripts/*`):

1. **Discover** (`qlik-discover.py`) — pull the load script (data model), master
   measures/dimensions (via an Engine `MeasureList`/`DimensionList`), sheet/chart
   defs + per-sheet **cell grids** (layout), and the app's **freshness** metadata
   (lastReloadTime + an engine snapshot of the KPI totals) into `converter-input.json`
   and friends. The freshness preflight then tells you up front when the Qlik app is
   stale and Sigma (live warehouse) will show more data.
2. **Reconcile** (`reconcile-columns.py`) — auto-derive the Qlik-field → real-warehouse
   column map from the load script's `AS` aliases (`ORDER_STORE_KEY AS STORE_KEY`).
3. **Translate** — `convert_qlik_to_sigma` turns master measures into Sigma metrics and
   builds relationships from shared keys. **Set Analysis** → Sigma `SumIf`/`CountIf`.
4. **Build the data model** (`gen-denorm-sql.py` + `build-sigma-dm.py`) — a clean star
   plus a denormalized SQL element; POST to `/v2/dataModels/spec`.
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
- **Workbook layout** is a separate top-level XML step (1-based grid lines).
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

## The techniques worth carrying forward
Duration: 1

- **Assess first** — convert the high-value, low-effort apps before the long tail.
- **Reconcile from the load script** — the `AS` aliases *are* the column map.
- **Treat the warehouse as the source of truth** — Sigma reads it live; parity is the gate.
- **Set Analysis → `SumIf`** — most Qlik selection logic maps cleanly.
- **Scale with `batch-migrate`** — a tenant of apps in one pass.

Next: run `qlik-assessment` on your tenant, pick the shortlist, and let `qlik-to-sigma`
convert the top N.
