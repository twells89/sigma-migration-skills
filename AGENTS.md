# AGENTS.md — sigma-migration-skills

Migration skills for moving BI tools (**Tableau, Power BI, Qlik, ThoughtSpot,
QuickSight, Looker, Cognos, MicroStrategy, Sisense, GoodData, Domo, Hex**) to
**Sigma**: per-tool *converters* (source → Sigma data model + workbook, with
warehouse parity verification) and read-only *assessments* (tenant inventory →
migration-readiness readout + shortlist).

This repo is packaged as a Claude Code plugin marketplace, but the skills are
agent-neutral: each is a `SKILL.md` (instructions) plus `scripts/` (Ruby/Python/
shell) and `refs/`. Any coding agent (Cursor, Cortex Code, etc.) can run them by
reading the relevant `SKILL.md` and executing its scripts.

**First-time / non-Claude agents:** read [`docs/agent-entry.md`](docs/agent-entry.md)
for install shapes, companion `sigma-authoring`, path rules, and MCP stance.

## How to use a skill

1. Pick the skill from the index below that matches the user's intent.
   Prefer `gold` / `live` over `foundation` / `scaffold` unless the user is
   explicitly building out a scaffold.
2. **Read that skill's `SKILL.md` in full first** — it is the source of truth for
   the phased workflow. The `refs/*.md` next to it cover details.
3. Run its scripts **from the skill directory** (script paths are relative, e.g.
   `scripts/setup.rb`). `cd` into the skill dir, then invoke.
4. Install / load the companion **`sigma-authoring`** plugin alongside any
   converter (`sigma-workbooks` + `sigma-data-models`).

Maturity labels (`gold` / `live` / `foundation` / `scaffold`) are defined in
[`docs/agent-entry.md`](docs/agent-entry.md).

## Skill index

| Intent | Skill | Maturity | Path (read its `SKILL.md`) |
|---|---|---|---|
| Convert a Tableau datasource/workbook → Sigma | `tableau-to-sigma` | gold | `plugins/tableau-to-sigma/skills/tableau-to-sigma/` |
| Scope/assess a Tableau site for migration | `tableau-assessment` | live | `plugins/tableau-to-sigma/skills/tableau-assessment/` |
| Land a Tableau published-datasource/extract in Snowflake or Databricks | `tableau-vds-to-cdw` | live | `plugins/tableau-to-sigma/skills/tableau-vds-to-cdw/` |
| Convert a Power BI report + semantic model → Sigma (DAX translation) | `powerbi-to-sigma` | live | `plugins/powerbi-to-sigma/skills/powerbi-to-sigma/` |
| Scope/assess a Power BI / Fabric tenant | `powerbi-assessment` | live | `plugins/powerbi-to-sigma/skills/powerbi-assessment/` |
| Land an Import-mode Power BI model's data in Snowflake (before converting) | `powerbi-import-to-snowflake` | live | `plugins/powerbi-to-sigma/skills/powerbi-import-to-snowflake/` |
| Convert a Qlik Sense / Qlik Cloud app → Sigma | `qlik-to-sigma` | live | `plugins/qlik-to-sigma/skills/qlik-to-sigma/` |
| Scope/assess a Qlik Cloud tenant | `qlik-assessment` | foundation | `plugins/qlik-to-sigma/skills/qlik-assessment/` |
| Convert a ThoughtSpot model + Liveboards → Sigma (TML) | `thoughtspot-to-sigma` | live | `plugins/thoughtspot-to-sigma/skills/thoughtspot-to-sigma/` |
| Scope/assess a ThoughtSpot instance | `thoughtspot-assessment` | foundation | `plugins/thoughtspot-to-sigma/skills/thoughtspot-assessment/` |
| Convert an Amazon QuickSight analysis/dashboard → Sigma | `quicksight-to-sigma` | foundation | `plugins/quicksight-to-sigma/skills/quicksight-to-sigma/` |
| Scope/assess a QuickSight instance | `quicksight-assessment` | foundation | `plugins/quicksight-to-sigma/skills/quicksight-assessment/` |
| Convert a Looker (LookML model + dashboards) → Sigma | `looker-to-sigma` | live | `plugins/looker-to-sigma/skills/looker-to-sigma/` |
| Scope/assess a Looker instance | `looker-assessment` | live | `plugins/looker-to-sigma/skills/looker-assessment/` |
| Convert an IBM Cognos data module + report → Sigma | `cognos-to-sigma` | live | `plugins/cognos-to-sigma/skills/cognos-to-sigma/` |
| Scope/assess a Cognos Analytics instance | `cognos-assessment` | foundation | `plugins/cognos-to-sigma/skills/cognos-assessment/` |
| Convert a MicroStrategy dossier + semantic model → Sigma | `microstrategy-to-sigma` | live | `plugins/microstrategy-to-sigma/skills/microstrategy-to-sigma/` |
| Scope/assess a MicroStrategy (Strategy One) instance | `microstrategy-assessment` | foundation | `plugins/microstrategy-to-sigma/skills/microstrategy-assessment/` |
| Convert a Sisense (ElastiCube / Live model + dashboards) → Sigma | `sisense-to-sigma` | live | `plugins/sisense-to-sigma/skills/sisense-to-sigma/` |
| Scope/assess a Sisense instance | `sisense-assessment` | scaffold | `plugins/sisense-to-sigma/skills/sisense-assessment/` |
| Convert a GoodData Cloud / .CN workspace (LDM + MAQL + insights + dashboards) → Sigma | `gooddata-to-sigma` | live | `plugins/gooddata-to-sigma/skills/gooddata-to-sigma/` |
| Scope/assess a GoodData workspace | `gooddata-assessment` | live | `plugins/gooddata-to-sigma/skills/gooddata-assessment/` |
| Convert a Domo dashboard (DataSets + Beast Modes + cards) → Sigma | `domo-to-sigma` | gold | `plugins/domo-to-sigma/skills/domo-to-sigma/` |
| Scope/assess a Domo instance | `domo-assessment` | foundation | `plugins/domo-to-sigma/skills/domo-assessment/` |
| Land Domo API/upload/sample DataSets in Snowflake (before converting) | `domo-import-to-snowflake` | foundation | `plugins/domo-to-sigma/skills/domo-import-to-snowflake/` |
| Convert a Hex project (SQL/METRIC cells, EXPLORE charts, app layout) → Sigma | `hex-to-sigma` | live | `plugins/hex-to-sigma/skills/hex-to-sigma/` |
| Scope/assess a Hex instance | `hex-assessment` | scaffold | `plugins/hex-to-sigma/skills/hex-assessment/` |
| Convert a Mode Report (SQL Queries + Charts) → Sigma | `mode-to-sigma` | foundation | `plugins/mode-to-sigma/skills/mode-to-sigma/` |
| Author / repair Sigma workbooks (canonical spec) | `sigma-workbooks` | live | `plugins/sigma-authoring/skills/sigma-workbooks/` |
| Author / repair Sigma data models (canonical spec) | `sigma-data-models` | live | `plugins/sigma-authoring/skills/sigma-data-models/` |
| Convert a Streamlit source project → Sigma | `streamlit-to-sigma` | gold | `plugins/streamlit-to-sigma/skills/streamlit-to-sigma/` |
| Scope/assess a Streamlit instance | `streamlit-assessment` | scaffold | `plugins/streamlit-to-sigma/skills/streamlit-assessment/` |

Assessments are read-only (never write to the source or post to Sigma); run one
to pick what to convert, then hand off to the matching converter.

Each converter's phase numbering is local to its SKILL.md — the canonical
Assess → Discover → Reuse-check → Convert → Post-DM gate → Build workbook →
Layout → Parity → Security → Enhance arc, with the per-skill phase-number
mapping, is in [`docs/phase-schema.md`](docs/phase-schema.md). Never renumber
a skill's phases.

## Governance (keep skills consistent)

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Enforced by CI:

- **Shared infra** lives in [`shared/`](shared/) (single source of truth) and is
  vendored byte-identical into each plugin. Edit the canonical copy, then
  `ruby tools/sync-shared.rb`. `tools/check-shared.rb` fails CI on drift.
- **Mandatory arc gates** (reuse / readback / layout-last / parity / RLS) are
  linted in every converter `SKILL.md` by `tools/lint-skills.rb` (canonical arc:
  [`docs/phase-schema.md`](docs/phase-schema.md)).
- **New skills:** `ruby tools/new-skill.rb <tool> "<Display Name>"`.
- **Parallel sessions:** claim work in beads at plugin granularity; one PR = one
  plugin; shared-lib changes are their own PR.
- **Docs taxonomy:** durable contracts vs session residue —
  [`docs/README.md`](docs/README.md). Structure follow-ups:
  [`docs/structure-roadmap.md`](docs/structure-roadmap.md).

## Corpus (regression fixtures)

`corpus/` holds per-tool source artifacts + golden converter outputs + a
runner (`corpus/run-corpus.sh --check`, creds-free). When you change a
converter or builder, run the corpus check and reconvert the affected case
(`--reconvert` prints the exact tool call; `--diff` byte-compares after id
normalization). See `corpus/README.md` for the case inventory and how to add
cases.

## Credentials (agent-neutral)

All scripts read credentials from **environment variables**. Setup writes them to
two places so they work under any agent:

- `~/.claude/settings.json` — Claude Code auto-loads this into the env.
- `~/.sigma-migration/env` — a neutral, sourceable file (`export KEY='value'`,
  mode 0600) for every other agent and plain shells.

`get-token.sh`, `get-tableau-token.sh`, and the Ruby libs (`lib/sigma_rest.rb`,
`lib/tableau_rest.rb`) **auto-source `~/.sigma-migration/env`** when the vars
aren't already set — so non-Claude agents work with no manual sourcing. Existing
env always wins.

**Sigma** (all converters): `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`,
`SIGMA_CLIENT_SECRET`. Configure once with `ruby scripts/setup.rb` (in the
tableau-to-sigma skill), or `export` them yourself. Then mint a ~1h bearer token:

```bash
bash -c 'eval "$(scripts/get-token.sh)"; <your curl using $SIGMA_API_TOKEN>'
```

> Keep the `eval` and the command in the **same** `bash -c '...'` — `$()` creates
> a subshell where the exported token dies immediately.

**Tableau** (PAT mode, when the Tableau MCP isn't available): `TABLEAU_SERVER_URL`,
`TABLEAU_SITE_CONTENT_URL`, `TABLEAU_PAT_NAME`, `TABLEAU_PAT_SECRET`. Configure
with `ruby scripts/setup-tableau.rb`; sign in with
`eval "$(scripts/get-tableau-token.sh)"`. Other source tools (Power BI, Qlik,
ThoughtSpot) have their own auth — see each skill's `SKILL.md` / `QUICKSTART.md`.

## Optional MCP servers

The **core migration pipeline uses the Sigma REST API** (via the scripts above).
MCP is **not required** to run a converter. Where available, these enhance
discovery/verification — see [`docs/agent-entry.md`](docs/agent-entry.md) §MCP:

- **Sigma MCP** — query built workbooks during parity (recommended when present).
- **Tableau MCP** — view/datasource discovery without PAT setup.
- **sigma-data-model converter** (MCP) — optional hosted fallback for
  source-formula → Sigma-formula translation; skills bundle a local converter
  by default.

Configure them in your agent's MCP config; the skills fall back to REST/CLI when
they're absent.

## Conventions that bite non-Claude agents

- **Don't inline Ruby/Python inside `bash -c`** for anything over ~5 lines —
  nested-quote escaping silently breaks. Write a `.py`/`.rb` file and exec it.
- **Scripts are relative to the skill dir** — `cd` there first.
- **Tokens expire (~1h)** — re-mint on a 401; never cache across long runs except
  via the Ruby libs, which auto-refresh.
- **No legacy `sigma-skills/` paths** — use the companion `sigma-authoring`
  skills in this repo (see [`docs/agent-entry.md`](docs/agent-entry.md)).
