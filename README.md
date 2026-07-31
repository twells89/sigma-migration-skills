# Sigma migration skills

A **plugin marketplace** of skills for migrating BI tools to
[Sigma](https://www.sigmacomputing.com/). Each plugin is a pair of skills — a
**converter** (rebuild the content in Sigma) and an **assessment** (inventory,
complexity, and a value/cost shortlist) — validated end-to-end with **parity
checked against the source warehouse**, not just a best-effort port.

**Works with any coding agent.** Install it as a [Claude Code](https://claude.com/claude-code)
plugin, or use it from Cursor, Cortex Code, and others via [`AGENTS.md`](AGENTS.md) — the
skills themselves are agent-neutral (a `SKILL.md` + `scripts/`), and credentials load from a
shared `~/.sigma-migration/env` under any agent.

## Install

**Claude Code** — add the marketplace and install the plugins you need:

```text
/plugin marketplace add twells89/sigma-migration-skills
/plugin install sigma-authoring@sigma-migration-skills      # companion Sigma spec — install alongside any converter
/plugin install tableau-to-sigma@sigma-migration-skills
/plugin install powerbi-to-sigma@sigma-migration-skills
/plugin install qlik-to-sigma@sigma-migration-skills
/plugin install thoughtspot-to-sigma@sigma-migration-skills
/plugin install quicksight-to-sigma@sigma-migration-skills
/plugin install cognos-to-sigma@sigma-migration-skills
/plugin install looker-to-sigma@sigma-migration-skills
/plugin install microstrategy-to-sigma@sigma-migration-skills
/plugin install sisense-to-sigma@sigma-migration-skills
/plugin install gooddata-to-sigma@sigma-migration-skills
/plugin install domo-to-sigma@sigma-migration-skills
/plugin install hex-to-sigma@sigma-migration-skills
```

**Other agents (Cursor, Cortex Code, …)** — clone the repo and point your agent at the
skill folders; [`AGENTS.md`](AGENTS.md) maps each task to its skill. For example, Cortex Code:

```bash
git clone https://github.com/twells89/sigma-migration-skills
cortex skill add sigma-migration-skills/plugins/tableau-to-sigma/skills/tableau-to-sigma
```

**Connect the Sigma MCP server (required).** These skills drive your Sigma org through the
**Sigma MCP server** — connect it in your coding agent following Sigma's official guide:
**[Use the Sigma MCP server](https://help.sigmacomputing.com/docs/use-sigma-mcp-server)**.
It's how the agent reads/queries Sigma (e.g. the parity gate) and builds + validates the
migrated data model and workbook. Install it alongside the plugins, before running a migration.

Then just describe what you want migrated — e.g. *"migrate this Power BI report to Sigma"* —
and the skill drives discovery → translation → build → parity.

## What's in the marketplace

| Plugin | Source tool | Skills it installs |
|---|---|---|
| [`tableau-to-sigma`](plugins/tableau-to-sigma/) | Tableau | `tableau-to-sigma`, `tableau-assessment`, `tableau-vds-to-cdw` |
| [`powerbi-to-sigma`](plugins/powerbi-to-sigma/) | Power BI | `powerbi-to-sigma`, `powerbi-assessment`, `powerbi-import-to-snowflake` |
| [`qlik-to-sigma`](plugins/qlik-to-sigma/) | Qlik Sense / Cloud + QlikView (`.qvw` via `-prj`) | `qlik-to-sigma`, `qlik-assessment` |
| [`thoughtspot-to-sigma`](plugins/thoughtspot-to-sigma/) | ThoughtSpot | `thoughtspot-to-sigma`, `thoughtspot-assessment` |
| [`quicksight-to-sigma`](plugins/quicksight-to-sigma/) | Amazon QuickSight | `quicksight-to-sigma`, `quicksight-assessment` |
| [`cognos-to-sigma`](plugins/cognos-to-sigma/) | IBM Cognos Analytics | `cognos-to-sigma`, `cognos-assessment` |
| [`looker-to-sigma`](plugins/looker-to-sigma/) | Looker | `looker-to-sigma`, `looker-assessment` |
| [`microstrategy-to-sigma`](plugins/microstrategy-to-sigma/) | MicroStrategy (Strategy One) | `microstrategy-to-sigma`, `microstrategy-assessment` |
| [`sisense-to-sigma`](plugins/sisense-to-sigma/) | Sisense (ElastiCube / Live) | `sisense-to-sigma`, `sisense-assessment` |
| [`gooddata-to-sigma`](plugins/gooddata-to-sigma/) | GoodData Cloud / .CN | `gooddata-to-sigma`, `gooddata-assessment` |
| [`domo-to-sigma`](plugins/domo-to-sigma/) | Domo | `domo-to-sigma` |
| [`hex-to-sigma`](plugins/hex-to-sigma/) | Hex | `hex-to-sigma` |

In Claude Code, installed skills are namespaced — e.g. `/powerbi-to-sigma:powerbi-assessment`.

The `tableau-to-sigma` plugin bundles a third skill, **`tableau-vds-to-cdw`** — a
data-landing bridge for when a Tableau datasource's data lives only inside Tableau (a
published extract / VDS feed) and isn't yet in the warehouse Sigma reads. It pulls the data
via the VizQL Data Service API and lands it in your cloud warehouse — **Snowflake** or **Databricks**, optionally on a schedule —
so the converter has a warehouse-native table to build on. `tableau-assessment` flags the
datasources that need it.

The `powerbi-to-sigma` plugin bundles the equivalent bridge, **`powerbi-import-to-snowflake`** —
for **Import-mode** Power BI models whose data lives inside the `.pbix` / semantic model
(Excel, Power Query, flat files) rather than a live warehouse. It reads the model definition
via Fabric `getDefinition`, extracts the stored table rows through the Power BI
`executeQueries` API, and lands them as typed tables in **Snowflake** — the data track that
runs *before* `powerbi-to-sigma` converts the model logic. DirectQuery models already point
at a warehouse and don't need it.

## The shared shape

Every converter follows the same phased flow:

```
Discover   →  pull the source model + report/sheets/dashboards
Translate  →  measures/calcs/expressions → Sigma formulas (a converter handles the bulk;
              a gap-scout sub-agent validates the hard cases against the live Sigma API)
Data model →  build the Sigma data model (tables + relationships + metrics), reconciled to the warehouse
Workbook   →  rebuild the pages/visuals as a Sigma workbook (layout applied last)
Parity     →  query Sigma vs the source warehouse — GREEN only on a match
```

Each plugin's `skills/<name>/SKILL.md` is the entry point; `refs/` holds the spec
gotchas and `scripts/` the pipeline. Skills are self-contained — no external paths to wire up.
The canonical phase arc and a per-skill phase-number mapping live in
[`docs/phase-schema.md`](docs/phase-schema.md).

## Corpus

[`corpus/`](corpus/README.md) is a regression corpus: real (demo-data) source
artifacts for every tool — .twb, .bim, classic + PBIR report JSON, Qlik app
metadata, ThoughtSpot TML, QuickSight describes, Cognos modules/reports,
LookML — with **golden converter outputs** and a runner. Smoke-test converter
or builder changes without a live tenant:

```
corpus/run-corpus.sh --check      # no creds needed; CI-safe
```

## Requirements

- **A coding agent that runs skills** (Claude Code, Cursor, Cortex Code, …).
- The **[Sigma MCP server](https://help.sigmacomputing.com/docs/use-sigma-mcp-server)** connected in your agent — how the agent reads/queries your Sigma org and builds + validates the migrated data model and workbook. Follow Sigma's setup guide.
- **No converter to install** — each skill bundles its data-model converter (`convert_*_to_sigma`) and runs it **locally by default** (no network, no data egress). A [hosted converter MCP](https://github.com/twells89/sigma-data-model-mcp) is available as an **optional, opt-in fallback** that sends the source spec off-machine.
- A **Sigma API token** and a Sigma **connection** pointing at the same warehouse as the source content (needed for the parity gate).
- Per-tool source access — see each plugin's `refs/connection.md` (e.g. `qlik-cli` for Qlik; device-code / Fabric `getDefinition` for Power BI).

## Provenance

The reference migrations and example IDs throughout these skills come from the author's
own Sigma + Snowflake test tenant (a retail/workforce star schema). They're included as
**worked examples** — substitute your own connection, data model, and folder IDs.

## License

[MIT](LICENSE).
