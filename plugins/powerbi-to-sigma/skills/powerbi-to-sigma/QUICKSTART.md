author: Sigma Computing
summary: Migrating from Power BI made easy — convert Power BI reports to Sigma with Claude Code
id: developers_migrating_from_powerbi_made_easy
categories: Developers, Migration, AI
environments: Web
status: Draft
feedback link: https://github.com/sigmacomputing/quickstarts-public/issues

# Migrating from Power BI to Sigma made easy

## Introduction & why it matters
Duration: 2

Manually rebuilding Power BI reports in another tool means re-creating the semantic
model, re-writing every DAX measure, and re-laying-out each page — then proving the
numbers still match.

This quickstart automates it with **your coding agent** (Claude Code, Cursor, Cortex
Code, …) + a set of Power BI→Sigma skills: it extracts the semantic model (TMSL) and
report layout (PBIR) from Fabric, translates DAX measures to Sigma formulas, builds a
Sigma data model + workbook, and **verifies data parity** against the same warehouse.

positive
: These skills are **agent-neutral** — each is a `SKILL.md` plus `scripts/`. `AGENTS.md` at the repo root maps each task to its skill, and the scripts auto-load credentials from `~/.sigma-migration/env`, so they run the same under any agent. Where this guide says "Claude Code," substitute your agent.

positive
: DAX → Sigma is the heart of this migration. ~70% of measures are *mechanical* (direct rewrites); time-intelligence (YTD, same-period-last-year, running totals) maps to Sigma's `DateLookback`/`CumulativeSum` in a date-grouped element; only a small genuine tail has no equivalent.

## Who this is for
Duration: 1

- Sigma SEs and technical CSMs
- Migration partners
- Power BI developers evaluating a move to Sigma

The skills carry the DAX and Sigma-spec knowledge. You need access to a Power BI /
Fabric tenant and a Sigma org whose connection reaches the same warehouse the semantic
model queries (import or DirectQuery).

## Prerequisites
Duration: 2

- **A coding agent that runs skills** — Claude Code (CLI or desktop), Cursor, Cortex Code, etc.
- **Python 3** — the Microsoft-auth scripts need `msal`, `requests`, and `truststore`
  (pinned in `scripts/requirements.txt`). You don't have to install them by hand:
  `scripts/run.sh` bootstraps a virtualenv at `<work-dir>/.venv` automatically when no
  suitable interpreter is found. To set one up yourself (or point at an existing one):
  ```bash
  python3 -m venv .venv && .venv/bin/pip install -r scripts/requirements.txt
  export PBI_PY=$PWD/.venv/bin/python   # every script honors $PBI_PY
  ```
- **Power BI / Fabric access** — you do **not** need to register an Entra app. The skill uses **device-code auth** with the well-known Power BI Desktop public client, which works against *My workspace* and any workspace you can access.
- **Sigma API credentials** (`SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`)
- A **Sigma connection to the same warehouse** the model uses (for parity)
- The **Power BI → Sigma converter** — ships **inside the skill** as a prebuilt local bundle (`converter/powerbi.mjs`) and runs **in-process via `node`** (no clone, no `npm install`, no network, **no data egress** — your `model.bim` never leaves your machine). This is the default and works out of the box; it requires only `node` on PATH. A dev's own converter build wins via `--mcp-dir` / `$PBI_MCP_DIR`. The hosted `sigma-data-model` MCP is **only** a manual fallback: if the bundle *and* `node` are both unavailable the orchestrator stops (exit 10) and prints the exact `convert_powerbi_to_sigma` call for you to run, then resume with `--converter-out`.

negative
: Two API audiences are involved — **Fabric** (`api.fabric.microsoft.com`) for `getDefinition` (TMSL/PBIR) and **Power BI REST** (`analysis.windows.net/powerbi`) for refresh history, Activity Events, and `executeQueries` (DAX parity). The skill acquires both from one device-code session; corporate TLS requires `truststore.inject_into_ssl()`.

## The two-skill ecosystem
Duration: 2

| Skill | Role |
|---|---|
| **`powerbi-assessment`** | Inventory a Fabric tenant + score per-report complexity: DAX-convertibility buckets (a/b/c), visual-kind coverage, RLS roles, DirectQuery, warehouse sources parsed from M → value/cost-ranked shortlist. Run first. |
| **`powerbi-to-sigma`** | The conversion: extract TMSL+PBIR → translate DAX → build Sigma data model + workbook → parity-verify via `executeQueries`. |

Same `value/(1+cost)` shortlist math and `migrate-first / easy-win / moderate /
needs-gap-scout / retire` tags as the Tableau and Qlik migration skills.

## Installation & setup
Duration: 5

1. **Install the skills.** They ship as a Claude Code **plugin marketplace** (two skills per plugin: the converter + the assessment).
   - **Claude Code** — add the marketplace and install the plugin:
     ```text
     /plugin marketplace add twells89/sigma-migration-skills
     /plugin install powerbi-to-sigma@sigma-migration-skills
     ```
     Installed skills are namespaced — e.g. `/powerbi-to-sigma:powerbi-assessment`.
   - **Other agents (Cursor, Cortex Code, …)** — clone the repo and point your agent at the skill folder; `AGENTS.md` at the repo root maps each task to its skill:
     ```bash
     git clone https://github.com/twells89/sigma-migration-skills
     # e.g. Cortex Code:
     cortex skill add sigma-migration-skills/plugins/powerbi-to-sigma/skills/powerbi-to-sigma
     ```
   The two skills live at `plugins/powerbi-to-sigma/skills/{powerbi-to-sigma,powerbi-assessment}/`. Run each skill's scripts **from its own skill directory** — script paths are relative (e.g. `scripts/fabric-auth-check.py`).
2. **Sigma credentials** — run `ruby scripts/setup.rb` (in the tableau-to-sigma skill) once. It writes both `~/.claude/settings.json` and a neutral, sourceable `~/.sigma-migration/env` (mode 0600), which every script auto-loads under any agent. (Or just `export SIGMA_BASE_URL` / `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` yourself.) `scripts/get-token.sh` exchanges them for a ~1h `SIGMA_API_TOKEN`.
3. **Power BI auth** — from the `powerbi-to-sigma` skill dir, run the device-code flow
   (use the venv interpreter from the Prerequisites step — it has `msal`/`truststore`):
   ```bash
   ${PBI_PY:-python3} scripts/fabric-auth-check.py   # opens device-code login, caches token at /tmp/pbiauth/cache.bin
   ```
   Sign in with an account that can see the target workspace.
4. **Verify:** from the `powerbi-assessment` skill dir, `python3 scripts/fabric-inventory.py` lists your workspaces + items (reuses the cached token — no second login).

## Prepare demo data (optional)
Duration: 3

If you don't have a report to migrate, build a small model against your warehouse: a
fact + a few dimension tables (Power Query M sources pointing at, say, Snowflake), a
handful of DAX measures (`SUM`, `DIVIDE`, a `CALCULATE` with a single filter,
`TOTALYTD`), and a one-page report with a few visuals. Make sure your Sigma connection
points at the same schema.

## Run the conversion
Duration: 10

Just tell your agent *"migrate this Power BI report to Sigma"* and point it at a
report/dataset — the skill drives the phases below. There are two ways to run them:

**One-shot (recommended).** `scripts/migrate-powerbi.rb` runs the entire pipeline
in a single Ruby process — fewer agent turns, lower token cost — without becoming a
black box: every phase prints a header + concise result, and genuine human decision
points (e.g. a DAX measure the converter can't translate) surface as a structured
**OPEN QUESTIONS** block (exit code `10`) instead of being silently auto-resolved.
Each phase is checkpointed, so you can answer the questions and resume.

```bash
eval "$(scripts/get-token.sh)"   # Sigma token in env first (or rely on ~/.sigma-migration/env)
ruby scripts/migrate-powerbi.rb \
  --tmsl   /path/to/Model.tmsl \
  --pbir   /path/to/Report.json \
  --connection <SIGMA_CONN_UUID> --database <DB> --schema <SCHEMA> \
  --ref-dm <referenceDataModelId> \
  [--name "Sales Overview (from Power BI)"] [--folder <id>] [--yes] \
  [--enhance [--enhance-accept all-low-risk]]   # Phase E (opt-in, default OFF)
# exit 0 = done (parity pass) · 10 = decisions needed · 3 = parity fail
# exit 14 = parity PASS + Phase E proposals pending --enhance-accept
```

**Phase E (opt-in) — Enhance.** After parity passes, `--enhance` scans the source
signals + built workbook and proposes trial-validated enhancements (period-comparison
KPIs, grain switcher restoring the PBI date drill, selection controls, map
restoration, null-label/freshness polish). Nothing is applied without
`--enhance-accept`; accepted items land on a **clone** named "<name> — Enhanced"
(the parity workbook is never touched), one at a time, each gated by an
untouched-element parity spot-check that auto-reverts on any shift. See the
SKILL.md "Phase E (opt-in) — Enhance" section.

**Phase-by-phase** (`scripts/run.sh`, or drive the scripts directly) when you want to
inspect or hand-tune each stage. The phases:

1. **Extract** (`fabric-extract.py`) — device-code → Fabric `getDefinition` →
   **TMSL** (tables, measures, calc columns, RLS, M sources) + **PBIR** (pages, visuals,
   field bindings). Classic single-`report.json` reports are handled too:
   `run.sh` auto-detects the legacy shape (no `definition/` folder) and branches to
   `extract-report-classic.py`.
2. **Translate** — `convert_powerbi_to_sigma` maps the model + DAX to a Sigma spec.
   Apply the required POST fixups (`schemaVersion`, folderId, element name).
3. **Build the data model** — POST to `/v2/dataModels/spec`; verify every column has a
   concrete type (no `error` columns).
4. **Build the workbook** — recreate the report pages/visuals as Sigma elements +
   layout.
5. **Verify parity** — `phase6-parity-pbi.rb` runs the original measures via Power BI
   `executeQueries` (DAX) and compares to Sigma `query`.

positive
: **Reuse a data model instead of adding sprawl.** Before posting a new DM, the skill derives a signature of the report's warehouse tables/columns/measures (`pbi-dm-signature.py`) and checks for an existing Sigma DM that already covers them (`find-or-pick-dm.rb`). For a batch, the assessment's migration plan clusters reports by shared semantic model so one Sigma data model serves the whole family.

## Understanding the output
Duration: 3

- **Assessment readout** (`powerbi-assessment`) — per-report DAX buckets (a/b/c), visual
  histogram, RLS/DirectQuery flags, warehouse sources, and a ranked shortlist. Rendered
  as `readout.md` (`render-readout.rb`) **and** a customer-facing, share-friendly
  **Sigma-branded `readout.html`** (`render-readout-html.rb`).
- **Estimated migration effort (tokens / $)** — the HTML readout includes a cost estimate
  (Opus and Sonnet) for converting the shortlist, derived from a measured per-report
  token model (`refs/token-model.json`) × report count + items flagged for review.
- **DAX buckets:** **a** = mechanical direct rewrite (~70%); **b** = restructure (grouped
  element / parallel join / pre-aggregation — e.g. `RANKX`, `ALLEXCEPT`, `SUMMARIZE`);
  **c** = no Sigma equivalent (rare — `PATH` hierarchies, dynamic context).
- **Parity check** — GREEN only when `executeQueries` DAX results match Sigma.

## Reference & gotchas
Duration: 3

- **Extraction with no Entra app** — device-code + well-known client + `truststore`; works on *My workspace*.
- **PBIR vs classic report.json** — newer reports are exploded PBIR; older ones are a single `report.json` with `sections[]` — `run.sh` detects and branches automatically (`extract-report-classic.py`).
- **Spec fixups** — three required edits before POST (`schemaVersion: 1`, real `folderId`, element `name`).
- **Time-intelligence DAX** is translatable (not part of the (c) tail) via `DateLookback`/`CumulativeSum` on a date-grouped workbook element.
- **Hard DAX → gap-scout sub-agent** — measures the converter buckets `b`/`c` (`RANKX`, `ALLEXCEPT`, `SUMMARIZE`, `USERELATIONSHIP`, …) are handed to a gap-scout (`scripts/gap-scout.md`): it proposes a Sigma translation, **validates it against the live Sigma API** (`scout-validate.py`), and persists the rule to `~/.powerbi-to-sigma/learned-rules.yaml` so future runs auto-apply it. When the scout hits a genuine converter gap it can **(opt-in) file a GitHub issue** so the gap gets fixed upstream — it always confirms before filing.
- **Bookmarks → per-state workbooks** (optional Phase 7) — PBI show/hide & spotlight bookmarks become one Sigma workbook per visible subset (`extract-bookmarks.py` + the shared `build-bookmark-workbooks.py`); filter-state bookmarks bake their values as a page-level `list` filter.
- **Writing layout back to Power BI** (reverse path) uses Fabric `updateDefinition` with an allow-listed parts set.

## The techniques worth carrying forward
Duration: 1

- **Assess first** — DAX buckets tell you effort before you touch a report.
- **Extract model + report together** — TMSL gives the semantics, PBIR gives the layout.
- **Treat the warehouse as the source of truth** — parity via `executeQueries` is the gate.
- **Cluster by semantic model** — migrate a family of reports onto one Sigma data model.

Next: run `powerbi-assessment` on your tenant, pick the shortlist, and let
`powerbi-to-sigma` convert the top N.
