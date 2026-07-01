author: Sigma Computing
summary: Migrating from Amazon QuickSight made easy — convert QuickSight analyses to Sigma with your coding agent
id: developers_migrating_from_quicksight_made_easy
categories: Developers, Migration, AI
environments: Web
status: Draft
feedback link: https://github.com/sigmacomputing/quickstarts-public/issues

# Migrating from Amazon QuickSight to Sigma made easy

## Introduction & why it matters
Duration: 2

Manually rebuilding a QuickSight analysis in another tool means re-creating each
dataset and its data-prep, re-writing every calculated field, re-laying-out each
sheet — then proving the numbers still match.

This quickstart automates it with **your coding agent** (Claude Code, Cursor, Cortex
Code, …) + a set of QuickSight→Sigma skills: it extracts the analysis definition,
datasets, and data sources over the AWS CLI, translates calculated fields and
data-prep transforms to Sigma, builds a Sigma data model + workbook, lays it out,
and **verifies data parity** against the same warehouse.

positive
: These skills are **agent-neutral** — each is a `SKILL.md` plus `scripts/`. `AGENTS.md` at the repo root maps each task to its skill, and the scripts auto-load credentials, so they run the same under any agent. Where this guide says "Claude Code," substitute your agent.

negative
: **Enterprise edition is required.** The `describe-analysis-definition` / `describe-dashboard-definition` / `describe-data-set` APIs this migration depends on are **Enterprise-only** — a Standard-edition QuickSight account rejects them and there is no extraction path. Confirm your edition before you start.

## Who this is for
Duration: 1

- Sigma SEs and technical CSMs
- Migration partners
- QuickSight authors evaluating a move to Sigma

The skills carry the QuickSight calc-field, visual, and Sigma-spec knowledge. You
need AWS-CLI access to the QuickSight account (Enterprise) and a Sigma org whose
connection reaches the same warehouse the datasets query.

## Prerequisites
Duration: 2

- **A coding agent that runs skills** — Claude Code (CLI or desktop), Cursor, Cortex Code, etc.
- **Python 3** and **Ruby** (the discovery script is Python; the build pipeline is Ruby).
- **AWS CLI v2**, configured for the QuickSight account (see auth below).
- **An Enterprise-edition QuickSight account** + the analysis (or dashboard) id you want to migrate.
- **Sigma API credentials** (`SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`).
- A **Sigma connection to the same warehouse** the datasets use (its `connection_id` feeds the converter), and a target **folder id**.
- The **QuickSight → Sigma converter** — ships **inside the skill** as a prebuilt local bundle (`converter/quicksight.mjs`) and runs **in-process via `node`** (no clone, no `npm install`, no network, **no data egress** — your analysis/dataset JSON never leaves your machine). This is the default and works out of the box; it requires only `node` on PATH. A dev's own converter build wins via `--mcp-dir` / `$QS_MCP_DIR`. The hosted `sigma-data-model` MCP's `convert_quicksight_to_sigma` tool is **only** a manual fallback: if the bundle *and* `node` are both unavailable the orchestrator stops (exit 10) and prints the exact MCP call for you to run, then resume with `--converted`.

## The two-skill ecosystem
Duration: 2

| Skill | Role |
|---|---|
| **`quicksight-assessment`** | Inventory a QuickSight account + score per-analysis complexity: visual-type mix, calc-field count, window-function detection, dataset source types, RLS → value/cost-ranked shortlist. Run first. |
| **`quicksight-to-sigma`** | The conversion: extract analysis + datasets → translate calc fields → build Sigma data model + workbook → layout → parity-verify. |

Same `value/(1+cost)` shortlist math and `migrate-first / easy-win / moderate /
needs-gap-scout / retire` tags as the Tableau and Power BI migration skills.

## Installation & setup
Duration: 5

1. **Clone the skills / install the plugin** so your agent can see both skills
   (`quicksight-to-sigma` and `quicksight-assessment`). For Claude Code, install
   the `quicksight-to-sigma` plugin; for other agents, point the agent at the
   skill folders — `AGENTS.md` at the repo root indexes every skill.
2. **AWS auth** — configure the AWS CLI for the QuickSight account:
   ```bash
   # SSO orgs:
   aws sso login --profile <profile>
   # Okta-fronted orgs: gimme-aws-creds writes a usable profile
   gimme-aws-creds --profile <profile>
   # confirm:
   aws sts get-caller-identity --profile <profile>
   ```
   Note the **identity region is usually `us-east-1`** — the analysis/dataset/data-source
   resources are read from the identity region, not necessarily the data region.
3. **Sigma credentials** — export `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` (or
   write the neutral `~/.sigma-migration/env` the scripts auto-source under any
   agent). `scripts/get-token.sh` exchanges them for a `SIGMA_API_TOKEN`.
4. **Verify discovery** runs:
   ```bash
   python3 scripts/quicksight-discover.py \
     --account-id <ACCOUNT_ID> --region us-east-1 --profile <profile> \
     --analysis-id <ANALYSIS_ID> --out-dir ~/quicksight-migration/<name>
   ```
   It prints a summary (datasets, data-source types, calc fields, parameters,
   per-sheet visual kinds) and writes `signals.json` + raw defs.

## Run the conversion
Duration: 10

Point the `quicksight-to-sigma` skill at an analysis. Phases:

1. **Discover** (`quicksight-discover.py`) — AWS CLI → `describe-analysis-definition`
   + datasets + data sources → `signals.json` and raw JSON.
2. **Convert** — runs **locally by default**: the vendored converter bundle
   (`converter/quicksight.mjs`, `convertQuickSightToSigma`) executes in-process via
   `node` over the analysis + dataset jsons + your Sigma `connection_id` — no clone,
   no network, no MCP. Only if that bundle (and a dev's `--mcp-dir`/`$QS_MCP_DIR`
   build) are both absent does `convert-model.rb --emit-mcp` print the
   `convert_quicksight_to_sigma` MCP call as a **manual fallback**; run it yourself
   and save the returned Sigma data-model JSON, then resume with `--converted`.
3. **Build the data model** — `convert-model.rb --fixup` (names elements, rewrites
   sql refs, `schemaVersion: 1`, folder) → validate → POST to `/v2/dataModels/spec`;
   verify every column has a concrete type (no `error` columns).
4. **Build the workbook** — `build-workbook-from-quicksight.rb` recreates the QS
   sheets/visuals as Sigma elements + a visualId→element map → POST `/v2/workbooks/spec`.
5. **Layout** — `build-quicksight-layout.rb` maps the QS 1-based grid to Sigma's
   24-col layout → `put-layout.rb`.
6. **Verify parity** — query each element via `sigma-mcp-v2` and compare against the
   QuickSight aggregation. The `assert-phase6-ran.rb` hard gate must pass before GREEN.

positive
: Between steps 2 and 3 the skill runs a **DM-reuse check** (Phase 3.5: `qs-dm-signature.py` + `find-or-pick-dm.rb`): it scores the org's existing Sigma data models against the datasets' tables/columns and on a strong match asks reuse-vs-new — skipping the DM build and avoiding sprawl.

positive
: For many accounts, the assessment's migration plan clusters analyses by shared dataset so you reuse one Sigma data model across a batch.

## Understanding the output
Duration: 3

- **Assessment readout** (`quicksight-assessment`) — per-analysis complexity buckets
  (easy/medium/hard → auto/manual/unhandled), visual-kind histogram, calc-field /
  window-function counts, dataset source types, RLS flags, and a ranked shortlist.
- **Converter coverage:** KPI/bar/line/donut/pie visuals + RelationalTable / CustomSql /
  JoinInstruction / DataTransforms + ~40 calc-field functions convert cleanly. Window /
  table-calc functions, the exotic visual zoo (maps, sankey, insight ML, custom content,
  plugin), and FilterGroups degrade to placeholders / a warning manifest — partial, not failed.
- **Parity check** — GREEN only when the Sigma query results match the QuickSight aggregation.

## Reference & gotchas
Duration: 3

- **Enterprise-only definition APIs** — Standard editions can't be extracted.
- **Identity region** — usually `us-east-1`; pass `--region` accordingly.
- **CustomSql / DIRECT_QUERY fixup** (`beads-sigma-vy4k`) — those DM elements come back
  nameless with raw sql refs; the `--fixup` step names them and rewrites refs to
  `[Custom SQL/<ALIAS>]`. Don't post the raw converter output.
- **Workbook element refs** are `[<source element name>/<col>]`.
- **pie/donut** use `color:{id}` + `value:{id}`, not `xAxis`/`yAxis`.
- **Layout grid is 1-based** in QuickSight — offset by 1 before scaling to Sigma's grid.
- See `refs/migration-test-slate.md` for the full complexity taxonomy + 20-dashboard slate.

## The techniques worth carrying forward
Duration: 1

- **Assess first** — complexity buckets tell you effort before you touch an analysis.
- **Extract analysis + datasets together** — the analysis gives the visuals, the datasets give the semantics + data-prep.
- **Treat the warehouse as the source of truth** — parity is the gate, not POST success.
- **Cluster by dataset** — migrate a family of analyses onto one Sigma data model.

Next: run `quicksight-assessment` on your account, pick the shortlist, and let
`quicksight-to-sigma` convert the top N.
