---
name: tableau-assessment
description: Take inventory of a Tableau Cloud site and produce a migration-readiness readout — environment counts, licenses, datasource mix, refresh history, per-workbook usage, per-workbook complexity (via .twb gap-scan), and a value/cost-ranked migration shortlist. Use when a user wants to scope a Tableau→Sigma migration, audit BI sprawl, or pick which workbooks to convert first. Lightweight (~90s) MCP-driven pre-scoping; complements Hakkoda's deeper Assessment App rather than replacing it.
user-invocable: true
---

# Tableau Assessment

Surveys a Tableau **Cloud** site via the Tableau Admin Insights project (MCP) and the
workbook-content REST endpoint (PAT) — or a self-hosted **Tableau Server** site via REST
only (`inventory-rest.rb`; no Admin Insights, so no usage/refresh stats). Emits a markdown readout + JSON inventory
the user can hand to a Sigma rep, a Hakkoda engagement, or directly to the
`tableau-to-sigma` skill for conversion of the shortlisted workbooks.

> **Warehouse-agnostic.** This skill (and the downstream `tableau-to-sigma`
> conversion skill) makes no assumption about which warehouse Sigma is reading
> from — BigQuery, Databricks, Snowflake, Postgres, SQL Server, Redshift,
> Synapse, and Oracle are all treated the same way at the Sigma API layer
> (connections → tables → columns → query). Worked examples in this skill use
> Snowflake because that's where the dev / audit fixtures live, but the
> Sigma-side patterns transfer to any supported warehouse. The only
> warehouse-specific surface is the optional `--snowflake-conn` reconciliation
> flag on `migration-plan.rb` (see "Multi-warehouse considerations" below for
> the equivalent on other warehouses).

---

## Privacy posture (READ FIRST, surface to the customer)

**This skill reads workbook metadata, not warehouse data.** What crosses Anthropic's
API on its way through Claude:

| Crosses Anthropic API | Stays local |
|---|---|
| Aggregate counts (workbook count, user count, datasource counts) | View CSVs (this skill never fetches them) |
| Workbook names, owner emails, project names | Warehouse rows (this skill never queries them) |
| `User License Type` and login dates from Admin Insights | Customer database credentials |
| Refresh job results, durations, error messages | The customer's actual reports' values |
| `.twb` XML for each workbook (calc-field definitions, custom SQL, layout) | `.hyper` extract data files (skipped on download) |

**This is a weaker posture than Hakkoda's "stays in Snowflake" app.** Hakkoda's
Snowflake Native App keeps everything inside the customer's Snowflake account. This
skill — like every other Claude Code skill — sends what it reads through the
Anthropic API to Claude. The user should be told this before running.

The skill writes outputs to a local directory (`/tmp/assessment-<sitename>/` by
default) and does NOT upload them anywhere. If the customer wants the readout
shared with a Sigma rep, that's a deliberate `Share` action, not automatic.

See `PRIVACY.md` for the full disclosure to share with customer privacy/legal review.

---

## When to use this skill

- A Tableau customer wants a 5-minute scoping view before booking a Hakkoda 1-hour assessment
- A Sigma SE preparing for a discovery call wants a pre-built migration shortlist
- A customer is deciding which Tableau workbooks to retire vs. migrate
- A `tableau-to-sigma` invocation needs a Phase 0 inventory of the source site

**Not for**: Replacing Hakkoda's full Assessment App readout (pricing scenarios,
permissions audit, dataset similarity at depth). Those still live in Hakkoda.

---

## Scripts overview

| Script | Purpose |
|---|---|
| `scripts/setup-tableau.sh` | Symlink to the tableau-to-sigma PAT setup wizard |
| `scripts/get-tableau-token.sh` | Symlink to the tableau-to-sigma token-refresh wrapper |
| `scripts/probe-admin-insights.rb` | Confirm the Admin Insights project is visible (gates whether license/refresh/usage sections run) |
| `scripts/inventory-rest.rb` | **Tableau Server fallback** for Phases 1–2: build `inventory.json` (`mode: rest-server`, counts + per-workbook sheet_count, `usage_available: false`) from the plain REST workbooks/views/datasources endpoints. No usage/refresh (needs Admin Insights or the Server repository DB). |
| `scripts/fetch-all-twbs.rb` | Parallel download of all workbook `.twb` files via REST (PAT mode only) |
| `scripts/aggregate-complexity.rb` | Run `scan-workbook-gaps.rb` (from tableau-to-sigma) against every `.twb`; emit `complexity.json`. Also derives a **predicted-parity %** + A–D band per workbook (y9rd.6): an occurrence-weighted roll-up of the gap-scanner's status tiers (`auto`=1.0, `hint`=0.85, `manual`=0.5, `unhandled`=0.0) — a *pre-migration prediction* from static `.twb` signal, NOT the post-migration measured value-parity score (`verify-parity.rb`). Flags hard workbooks (band C/D) before any conversion. |
| `scripts/build-shortlist.rb` | Cross-tabulate usage × complexity; rank by `value / (1 + cost)`; emit `shortlist.json` (carries `predicted_parity_pct` + `parity_band`) |
| `scripts/render-readout.rb` | Compose final `readout.md` from `inventory.json` + `complexity.json` + `shortlist.json` |
| `scripts/migration-plan.rb` | Phase 6: combine shortlist + data-sources + .twb warehouse-table extraction into `migration-plan.json` with per-workbook `recommended_path` (`tableau-to-sigma` / `vds-to-snowflake` / `retire` / `blocked`), DM clusters (Jaccard ≥ 0.5 on shared warehouse tables + fact-table overlap), and a suggested first batch. Input contract for the conversion handoff. |
| `scripts/consolidation-candidates.rb` | Phase 6b: within each shared-datasource pool, score workbook-variant similarity (actually-used fields, sheet/zone structure, filter sets, gap-scan feature profile, name-stem heuristics) and emit `consolidation-candidates.json` — groups of workbooks that could collapse into ONE Sigma workbook + a control. `--decide` records the user's per-group choice into `migration-plan.json`. Pure analysis; no Tableau/Sigma writes. |
| `scripts/orchestrate-batch.rb` | Phase 7 (optional): produce a `batch-plan.json` with wave-style scheduling for parallel `tableau-to-sigma` subagent execution. Cluster leaders run first to build/pick their DM; followers reuse via `find-or-pick-dm.rb` + `inspect-dm-shape.rb`. Continue-on-failure. Outputs ready-to-fire `agent_brief` strings for the conversation-layer to pass into `Agent()` calls. |

Scripts that need warehouse-table data (the MCP query-datasource calls against
Admin Insights) are NOT scripts — the agent fires those directly per the recipes
in this SKILL.md, because MCP tool calls only work from the agent's context.

---

## Modes

| Mode | Setup | Coverage | Use when |
|---|---|---|---|
| **MCP-only** | None — just Tableau MCP loaded as Site Admin | Environment + Licenses + Datasource mix + Refresh + Usage | Quick pre-scope; customer hasn't issued a PAT |
| **MCP + PAT** *(recommended)* | `ruby scripts/setup-tableau.sh` once (~30s) | Adds per-workbook complexity scan + ranked migration shortlist | Real migration planning; full readout |

The user driving the skill MUST have Site Admin role in Tableau — Admin Insights
is only published to that group by default. The skill probes this and surfaces a
clear error if Admin Insights isn't visible.

---

## Phase 0 — Probe access

Confirm the user has the access the skill needs. Two checks, in order:

```bash
# 0a. Tableau MCP loaded? Try a cheap call:
mcp__tableau__list-workbooks   limit=1
# If "tool not found" → MCP isn't loaded. Skill cannot run.
# If 401/403 → user signed in but lacks site-level read access.

# 0b. Admin Insights visible?
ruby scripts/probe-admin-insights.rb
# Calls mcp__tableau__search-content for "Admin Insights"; reports which of the
# 10 expected datasources are reachable. Exits 1 if zero are reachable (user is
# not a Site Admin → can run only the Section 1 inventory below).
```

If only the basic inventory runs (Section 1 below), surface a banner in the readout:

> "Run this as a Tableau Site Admin to unlock license, refresh, and usage
> sections. Currently running with limited access."

---

## Scope filters — usage window + personal sandbox exclusion

Every TS Events / Site Content query in this skill applies two default filters
so the readout reflects current relevance, not lifetime noise:

| Filter | Default | Why | How to override |
|---|---|---|---|
| **Usage window** | `Event Date >= today - 90 days` on every TS Events query | Tableau Cloud's `TS Events` Admin Insights datasource only retains ~90 days anyway, but the filter makes the window **explicit** in the readout and lets you tighten it to 30 days for pilot-picking. Without an explicit `Event Date` filter, "all time" silently means whatever the customer's site retention is. | Set `USAGE_DAYS=30` (or any positive int) in env before running the agent's Admin Insights queries; surface in the readout header as "Usage window: last N days". |
| **Personal Space exclusion** | `Top Parent Project Name != "Personal Space"` on Site Content workbook/datasource queries | Tableau Cloud's per-user sandbox project is full of one-off / draft / never-shared workbooks. On a 793-dashboard site, this often hides ~30-50% of the count. | Set `INCLUDE_PERSONAL=1` to keep them in the inventory. |

> **There is no `Is Archived` field on Tableau Cloud's Admin Insights Site
> Content datasource** — verified against `read-metadata` on a live site. The
> Tableau Cloud REST `/workbooks` endpoint already filters out truly archived
> /deleted workbooks server-side, so no client filter is needed for that. The
> "archived" concept the customer might mean is usually either (a) personal
> sandbox content (handled by the Personal Space exclusion above) or (b)
> workbooks moved to a project the customer calls "Archive" / "Old" / "Retired"
> — add those project names to `--exclude-projects` if surfaced.

Compute the relative date in the orchestration shell, e.g.
`MIN_DATE=$(date -v-90d +%Y-%m-%d)` (BSD/macOS) or
`MIN_DATE=$(date -d '90 days ago' +%Y-%m-%d)` (GNU/Linux), then substitute into
the `QUANTITATIVE_DATE` filter shape shown in the queries below.

---

## Phase 1 — Environment inventory (MCP, always runs)

Even without Admin Insights, the skill can produce a basic environment overview
from `mcp__tableau__search-content` and `mcp__tableau__list-workbooks`. This is
the "even broken access still produces something" floor.

```
mcp__tableau__list-workbooks                                     # → workbook count + sheetCount/hasExtracts per workbook
mcp__tableau__search-content filter.contentTypes=["datasource"]  # → datasource count
mcp__tableau__list-views                                         # → view count
```

Write the rolled-up counts to `inventory.json`'s `environment_overview` key.

### Self-hosted Tableau Server (no MCP / no Admin Insights)

Tableau Server has **no Admin Insights project** (that's a Cloud feature) and the hosted
Tableau MCP targets Cloud, so Phases 1–2 above don't apply. Instead build the inventory
from the standard REST endpoints with a PAT:

```bash
eval "$(scripts/get-tableau-token.sh)"            # negotiates the Server's REST API version
ruby scripts/inventory-rest.rb --out /tmp/assessment-<site>
```

This writes `inventory.json` (`mode: "rest-server"`) with workbook/datasource/view counts,
a per-workbook `sheet_count`, and `usage_available: false`. **Usage, license, and refresh
history are NOT available** over plain REST — they require Admin Insights (Cloud) or the
Tableau Server **repository** (the "workgroup" Postgres DB an admin must enable). Phase 3
complexity (`fetch-all-twbs.rb` + `scan-workbook-gaps.rb`) is already REST/PAT and runs
unchanged. `build-shortlist.rb` detects `usage_available: false` and ranks by complexity
(easiest first) — it will **not** tag zero-usage workbooks `retire`, since on Server a
missing access count is not evidence of disuse.

---

## Phase 2 — Admin Insights queries (MCP, requires Site Admin)

For each of the queries below, call `mcp__tableau__query-datasource` with the
listed `datasourceLuid` and `query` payload. **Run queries sequentially, not in
parallel** — VizQL session contention causes 401s under fan-out.

Field names matter — Admin Insights field naming is inconsistent and a typo
silently fails. See `refs/admin-insights-fields.md` for the verified field-name
cheat sheet. Critical: it's `Event Id`, not `Event LUID`.

### 2a. Site-content item counts → `inventory.environment_overview`

```json
{
  "datasourceLuid": "<Site Content LUID>",
  "query": { "fields": [
    { "fieldCaption": "Item Type" },
    { "fieldCaption": "Item LUID", "function": "COUNTD", "fieldAlias": "n" }
  ]}
}
```

### 2b. License breakdown → `inventory.licenses`

```json
{
  "datasourceLuid": "<TS Users LUID>",
  "query": { "fields": [
    { "fieldCaption": "User License Type" },
    { "fieldCaption": "User Site Role" },
    { "fieldCaption": "User LUID", "function": "COUNTD", "fieldAlias": "users" },
    { "fieldCaption": "Days Since Last Login", "function": "AVG", "fieldAlias": "avg_days_since_login" }
  ]}
}
```

### 2c. Content ownership → `inventory.content_ownership`

```json
{
  "datasourceLuid": "<Site Content LUID>",
  "query": { "fields": [
    { "fieldCaption": "Item Type" },
    { "fieldCaption": "Owner Email" },
    { "fieldCaption": "Item LUID", "function": "COUNTD", "fieldAlias": "n" }
  ], "filters": [{
    "field": { "fieldCaption": "Item Type" },
    "filterType": "SET",
    "values": ["Workbook", "Datasource", "Flow", "View"]
  }]}
}
```

### 2d. Datasource types + extract mix → `inventory.datasource_types`

```json
{
  "datasourceLuid": "<Site Content LUID>",
  "query": { "fields": [
    { "fieldCaption": "Data Source Content Type" },
    { "fieldCaption": "Data Source Database Type" },
    { "fieldCaption": "Is Data Extract" },
    { "fieldCaption": "Item LUID", "function": "COUNTD", "fieldAlias": "n" }
  ], "filters": [{
    "field": { "fieldCaption": "Item Type" }, "filterType": "SET", "values": ["Datasource"]
  }]}
}
```

### 2e. Refresh history → `inventory.refresh_jobs`

```json
{
  "datasourceLuid": "<Job Performance LUID>",
  "query": { "fields": [
    { "fieldCaption": "Job Type" },
    { "fieldCaption": "Final Job Result" },
    { "fieldCaption": "Job ID", "function": "COUNTD", "fieldAlias": "jobs" },
    { "fieldCaption": "Job Duration", "function": "AVG", "fieldAlias": "avg_duration_s" }
  ]}
}
```

### 2f. Workbook usage ranking → `inventory.workbook_usage`

```json
{
  "datasourceLuid": "<TS Events LUID>",
  "query": { "fields": [
    { "fieldCaption": "Workbook Name" },
    { "fieldCaption": "Number of Events", "function": "SUM", "fieldAlias": "accesses", "sortDirection": "DESC", "sortPriority": 1 },
    { "fieldCaption": "Count of Distinct Actors", "fieldAlias": "actors" }
  ], "filters": [
    { "field": { "fieldCaption": "Event Type" }, "filterType": "SET", "values": ["Access"] },
    { "field": { "fieldCaption": "Item Type" }, "filterType": "SET", "values": ["View", "Workbook"] },
    { "field": { "fieldCaption": "Event Date" }, "filterType": "QUANTITATIVE_DATE", "quantitativeFilterType": "MIN", "minDate": "<today minus USAGE_DAYS (default 90)>" }
  ]}
}
```

### 2g. Workbook inventory (size, owner, last accessed, hyperlink) → `inventory.workbook_inventory`

```json
{
  "datasourceLuid": "<Site Content LUID>",
  "query": { "fields": [
    { "fieldCaption": "Item Name" },
    { "fieldCaption": "Owner Email" },
    { "fieldCaption": "Top Parent Project Name" },
    { "fieldCaption": "Size (MB)", "function": "SUM", "fieldAlias": "size_mb" },
    { "fieldCaption": "Last Accessed At" },
    { "fieldCaption": "Is Data Extract" },
    { "fieldCaption": "Has Refresh Scheduled" },
    { "fieldCaption": "Item Hyperlink" }
  ], "filters": [
    { "field": { "fieldCaption": "Item Type" }, "filterType": "SET", "values": ["Workbook"] },
    { "field": { "fieldCaption": "Top Parent Project Name" }, "filterType": "SET", "exclude": true, "values": ["Personal Space"] }
  ]}
}
```

> Drop the `Top Parent Project Name` exclusion filter if `INCLUDE_PERSONAL=1`.
> Add additional project names to the `values` array if the customer has
> custom "Archive" / "Retired" projects to skip.

Merge the seven outputs into `<out>/inventory.json` following the schema in
`refs/output-shapes.md`.

### 2h. Per-user usage map → `users.json` (after running analyze-users.rb)

For user-population segmentation and per-user migration coverage:

```json
{
  "datasourceLuid": "<TS Users LUID>",
  "query": { "fields": [
    { "fieldCaption": "User Email" },
    { "fieldCaption": "User License Type" },
    { "fieldCaption": "User Site Role" },
    { "fieldCaption": "Days Since Last Login", "function": "MAX", "fieldAlias": "days_since" },
    { "fieldCaption": "Workbooks",  "function": "SUM", "fieldAlias": "owned_wb" },
    { "fieldCaption": "Views",      "function": "SUM", "fieldAlias": "owned_views" },
    { "fieldCaption": "Total Traffic - Views", "function": "SUM", "fieldAlias": "traffic_views" },
    { "fieldCaption": "Access Events - Views", "function": "SUM", "fieldAlias": "access_views" },
    { "fieldCaption": "Last Login Date" }
  ]}
}
```
Save the response under `<out>/raw-ts-users.json`.

Then the per-user-per-workbook access map (used to compute migration coverage):

```json
{
  "datasourceLuid": "<TS Events LUID>",
  "query": { "fields": [
    { "fieldCaption": "Actor User Name" },
    { "fieldCaption": "Workbook Name" },
    { "fieldCaption": "Number of Events", "function": "SUM", "fieldAlias": "accesses" }
  ], "filters": [
    { "field": { "fieldCaption": "Event Type" }, "filterType": "SET", "values": ["Access"] },
    { "field": { "fieldCaption": "Item Type" }, "filterType": "SET", "values": ["View", "Workbook"] },
    { "field": { "fieldCaption": "Event Date" }, "filterType": "QUANTITATIVE_DATE", "quantitativeFilterType": "MIN", "minDate": "<today minus USAGE_DAYS (default 90)>" }
  ]}
}
```
Save the response under `<out>/raw-ts-events-per-user.json`.

---

## Phase 3 — Per-workbook complexity (PAT, optional but recommended)

This is the section that differentiates the skill from Hakkoda. Hakkoda owns
assessment but not conversion; this skill ties them together by predicting
per-workbook conversion cost.

### 3a. Auth + fetch

```bash
ruby scripts/setup-tableau.sh         # one-time, prompts for PAT name + secret
eval "$(scripts/get-tableau-token.sh)" # refreshes ~hourly auth token
ruby scripts/fetch-all-twbs.rb --out /tmp/assessment-<site>
```

`fetch-all-twbs.rb` lists every workbook via REST, downloads `.twb` content in
parallel (12-thread default), and unzips any `.twbx` to extract the inner `.twb`.

For **large sites (500+ workbooks)** the script is built to handle the long-run
failure modes:

- **Resumable.** Files already on disk in `<out>/twbs/` are skipped, so a
  failed or interrupted run can just re-invoke the same command.
- **Token auto-refresh.** Background thread re-signs in every 60 min
  (`--refresh-min N`), and every request retries once after refreshing on a
  401. Long runs (1000+ workbooks, multi-hour) survive Tableau Cloud session
  timeout without manual re-auth.
- **Persistent HTTPS per worker** — measured ~2× speedup vs. the previous
  fresh-connection-per-request approach.
- **Adaptive backoff** on 429 / 502 / 503 / 504, up to 4 retries with
  exponential delay capped at 30 s.
- **Live ETA** logged every 10 workbooks: `[N/total] R wb/s  eta M minutes`.

Tuning flags:
```bash
ruby scripts/fetch-all-twbs.rb --out /tmp/assessment-<site> \
  --threads 12 \      # raise to 16-24 if customer's Tableau Cloud is fast and not throttling
  --refresh-min 60 \  # lower to 30 if customer site has strict session policy
  --limit 50          # for a sanity pass before fetching the whole site
```

Expected throughput on Tableau Cloud `10ay.online.tableau.com`: ~300 wb/min
on small workbooks, ~60-120 wb/min on a mixed corpus with several 5MB+
`.twbx` files. **If you measure < 30 wb/min on a customer's site**, suspect
network latency or large embedded extracts; lower threads to avoid 429s
rather than raising them.

### 3b. Run the gap-scanner against each workbook

```bash
ruby scripts/aggregate-complexity.rb /tmp/assessment-<site>
```

Iterates `<out>/twbs/*.twb`, runs `tableau-to-sigma/scripts/scan-workbook-gaps.rb`
on each, parses each `<luid>-gaps-report.json`, aggregates feature counts in
four buckets (auto / hint / manual / unhandled) per workbook. Writes
`complexity.json`.

### 3c. Build the migration shortlist

```bash
ruby scripts/build-shortlist.rb /tmp/assessment-<site>
```

Cross-tabulates `inventory.workbook_usage` with `complexity.json`. Scores each
workbook:

- `value = accesses × √(distinct_viewers)`
- `cost  = 10·unhandled + 3·manual + 1·hint`
- `score = value / (1 + cost)`

Writes `shortlist.json` — ranked by score, with explicit "retire" tags on
zero-access workbooks and explicit "needs gap-scout" flags on workbooks with
unhandled features.

---

## Phase 4 — Site-wide lineage via Metadata API (PAT, optional but recommended)

The Tableau Metadata API exposes the full lineage graph — workbooks, embedded /
published datasources, connection hostnames, custom SQL queries, Prep flows —
in a single GraphQL call. This unlocks the prescriptive data-source analysis
(red flags, similarity clusters, Sigma-readiness verdicts).

### 4a. Fetch the site-wide metadata graph

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/fetch-metadata-graph.rb --out /tmp/assessment-<site>
```

One POST to `/api/metadata/graphql`. Writes `metadata-graph.json` (~100–250 KB
for most sites; can grow to several MB for sites with thousands of calc fields).
Requires Site Admin role.

> **Per-workbook calc-field formulas live here.** The
> `embeddedDatasources.fields` block now includes the `formula`, `isHidden`,
> `role`, `dataType`, and `aggregation` of every `CalculatedField` — added
> 2026-05-26 so downstream conversion (`tableau-to-sigma/scripts/extract-calc-fields.rb`)
> can read calc formulas straight from the assessment dump without re-querying
> Tableau. This replaces the older VDS-based calc discovery, which fails on
> sites where VDS is disabled.

### 4b. Analyze data sources

```bash
ruby scripts/analyze-datasources.rb --out /tmp/assessment-<site>
```

For each data source (published + embedded), classifies:

| Verdict | Means |
|---|---|
| `drop-in` | Cloud warehouse natively supported by Sigma; connect directly |
| `verify-network` | Cloud type on an unrecognized host, or detected on-prem hostname; confirm Sigma can reach |
| `verify-db` | Database supported via a Sigma connector that may need extra config |
| `verify-modeling` | Federated cross-source join; review Sigma data-model relationship coverage |
| `resolve-published` | References another published datasource; resolve recursively |
| `land-in-warehouse` | File-based (Excel / CSV / Google Drive / .hyper); needs warehouse upload first. **Recommended path: use the sibling `tableau-vds-to-cdw` skill to auto-generate warehouse DDL (Snowflake or Databricks) + Sigma data model from the .tds.** |

Also emits:
- **Similarity clusters** — embedded datasources whose field-name sets overlap by ≥75% (Jaccard). Strong consolidation candidates.
- **Custom SQL inventory** — every Custom SQL block on the site with its downstream workbooks.
- **Prep flow inventory** — flow → downstream-datasource/workbook lineage, orphan detection.

Connection-type → verdict mapping is in `analyze-datasources.rb`'s constants block. Update when Sigma adds a new connector.

### 4c. Analyze user populations

```bash
ruby scripts/analyze-users.rb --out /tmp/assessment-<site>
```

Reads `raw-ts-users.json` + `raw-ts-events-per-user.json` (Phase 2h) + `shortlist.json`.
Segments users into power-user / active-creator / heavy-consumer / casual / light /
dormant / never-logged-in buckets. For each user, computes **pilot-migration coverage**
— what percent of their actual workbook accesses are covered by the top-5 pilot.

Bucket thresholds and segment definitions are in `analyze-users.rb`'s
`segment_for` function — tune for the customer's site size.

---

## Phase 5 — Render the readout

```bash
ruby scripts/render-readout.rb /tmp/assessment-<site>
```

Composes the 12-section markdown report (template at `refs/readout-template.md`).
Sections covered:

1. Environment overview
2. Licenses & cost scenario
3. Content ownership
4. Datasource patterns
5. Refresh insights
6. Workbook priority — usage-ranked
7. Migration shortlist (PAT-mode only — falls back to usage-only if MCP-only)
8. PAT-mode addendum: per-workbook complexity (PAT-mode only)
9. What the skill found vs. what it didn't
10. Privacy disclosure (links to PRIVACY.md)
11. Hand-off package contents
12. Next steps

Deliverables in `/tmp/assessment-<site>/`:

- `readout.md` — customer-facing markdown
- `inventory.json` — raw Admin Insights aggregates
- `complexity.json` — per-workbook gap counts (PAT mode)
- `shortlist.json` — ranked migration shortlist (PAT mode)
- `consolidation-candidates.json` — workbook-variant consolidation groups (Phase 6b; re-render after it runs)
- `twbs/` — cached `.twb` files (PAT mode; can be deleted after rendering)

---

## Phase 6 — Build the migration plan

After `render-readout.rb` finishes, **always** run:

```bash
ruby scripts/migration-plan.rb --out /tmp/assessment-<site>
```

This composes `migration-plan.json` from `shortlist.json`, `data-sources.json`, and the cached `.twb`s. Each workbook gets a `recommended_path`:

| `recommended_path` | What it means |
|---|---|
| `tableau-to-sigma` | Ready for conversion. ≤5 manual/unhandled features, score > 0. |
| `tableau-to-sigma-with-scout` | Needs `gap-scout` subagent runs for unhandled calc fields first. |
| `vds-to-snowflake` | Datasource (not workbook) flagged as `land-in-warehouse` or `red-flag` — best to materialize in Snowflake first, then convert the workbook on top. |
| `retire` | No usage (accesses=0); recommend not migrating. |
| `blocked` | >5 manual/unhandled features; needs human rework before automation can help. |

The plan also computes **DM clusters** — workbooks that share warehouse tables (Jaccard ≥ 0.5 + at least one shared `*_FACT`-shaped table). The bulk-conversion orchestrator uses these to share a single Sigma data model across a cluster's workbooks instead of building N redundant DMs.

---

## Phase 6b — Consolidation candidates (MANDATORY: prompt per group)

DM clusters answer "which workbooks can share one Sigma **data model**". This
phase answers the next question up the stack: which workbooks are *variants of
the same dashboard* that should become one Sigma **workbook** — e.g. regional
or yearly copies, `v2` / `final` / `Republish` clones, where the only real
difference is a filter value. In Sigma those collapse to one workbook plus a
control.

After `migration-plan.rb`, **always** run:

```bash
ruby scripts/consolidation-candidates.rb --out /tmp/assessment-<site>
```

Pure analysis (no Tableau/Sigma calls) over artifacts the assessment already
cached: per-pair it scores actually-used field overlap (from each `.twb`'s
`datasource-dependencies`, falling back to schema fields for stub workbooks),
sheet/zone structure, filter-field sets (and whether only the *values* differ),
the gap-scan feature profile from `complexity.json`, and name-stem heuristics
(shared stem after stripping copy/test/version/year tokens; Levenshtein +
token overlap). Pairs are pooled only within shared-datasource boundaries
(overlapping warehouse tables or a shared published-datasource id), grouped by
complete linkage so weak links can't chain unrelated workbooks together.

Writes `consolidation-candidates.json`. Each group carries `recommendation`:

| Recommendation | Means |
|---|---|
| `consolidate` | ≥70% actually-used-field overlap, ≥60% sheet-set similarity, same datasource, and the differences map to a control (or the variants are outright duplicates). Conservative by design — only fires on strong evidence. |
| `review` | Same datasource + meaningful overlap, but structure/field usage diverges beyond what one control parameterizes — or all members are blank publish-test stubs (keep one / retire instead). Show the user the evidence; don't auto-consolidate. |
| `keep-separate` | Considered (shared datasource, scored above the floor) but rejected. Kept in the output as evidence of what was checked. |

**Then prompt the user — one `AskUserQuestion` per `consolidate`/`review`
group** (do NOT silently fold this into the readout). Present the group's
members, the `similarity_drivers` + `differences` evidence, the proposed
control(s), and the savings (N−1 conversions avoided):

```
Group consolidation-01: "Sales — East" + "Sales — West" + "Sales — Central"
  evidence: 92% used-field overlap · identical sheets · filter 'Region' values differ
  proposal: 1 Sigma workbook + a Region list-control · saves 2 conversions
  → Consolidate into one workbook with controls (recommended)
  → Migrate as-is (3 separate workbooks)
```

For `review` groups present the same menu but do NOT pre-select; lead with the
divergence evidence. Record every answer so the conversion handoff knows:

```bash
ruby scripts/consolidation-candidates.rb --out /tmp/assessment-<site> \
  --decide consolidation-01=consolidate --decide consolidation-02=as-is
```

This updates `migration-plan.json` in place: merged members get
`recommended_path: "consolidate-into-primary"` + `consolidate_into` (the
primary's workbookId; original path preserved in `pre_consolidation_path`),
the primary gets `consolidation_role: "primary"` + `consolidation_controls`,
and the plan gains a top-level `consolidation` block. Downstream
(`tableau-to-sigma`, `orchestrate-batch.rb`) should convert ONLY the primary
and add the proposed control(s); merged members are skipped as conversions.

Re-rendering the readout after this phase (`render-readout.rb` /
`render-readout-html.rb`) adds the "Consolidation candidates" section
automatically when `consolidation-candidates.json` is present.

---

## Phase 7 — Hand off to the next skill (MANDATORY: ask the user)

**After Phase 6, the assessment agent MUST present a `AskUserQuestion` menu** so the user picks the next step. Do NOT silently end the assessment — the user is here to migrate something, surface the choice. Build the menu dynamically from `migration-plan.json`'s summary:

```
Assessment summary:
  • N workbooks total, M ready for conversion (score-ranked, top 8 below)
  • K datasources flagged for VDS→Snowflake first
  • C DM clusters detected (workbooks sharing warehouse tables)

What next?
  → Migrate top N dashboards in parallel  [tableau-to-sigma × N subagents]
  → Migrate one specific dashboard  [pick from list]
  → Land Tableau datasources in Snowflake first  [tableau-vds-to-cdw]
  → Do both: VDS first, then dashboards  [chained]
  → Just write the readout — act later
```

Use the `AskUserQuestion` tool to render this. Each option dispatches differently:

### Option A — Single dashboard

User picks one workbook. Invoke the conversion skill in the **same conversation** (not a subagent — agent stays in the assessment thread):

```
Skill(
  skill: "tableau-to-sigma",
  args:  "Convert workbook <luid> (<name>) from the just-finished assessment at /tmp/assessment-<site>. Read /tmp/assessment-<site>/migration-plan.json for the recommended_path, blockers, and warehouse_tables for this workbook. Use the cluster's denorm plan if one exists."
)
```

### Option B — Bulk parallel migration

> **Where to run this:** Option B requires the **`Agent()` tool**, which is only available to a **top-level interactive Claude Code session**. Subagents in a nested context (i.e., when this assessment itself is being driven by a parent `Agent()` call) cannot themselves spawn further `Agent()` calls — they only have `Bash + run_in_background`. If you're nested, do NOT attempt Option B from within; surface the batch-plan to the parent session and let it drive the wave fan-out.

```bash
ruby scripts/orchestrate-batch.rb \
  --plan /tmp/assessment-<site>/migration-plan.json \
  --out  /tmp/assessment-<site>/batch \
  --concurrent 3 \
  --limit 8
```

This emits `batch-plan.json` with wave-by-wave subagent briefs. The conversation-layer agent then:

1. For each wave in order, **batch its subagents into messages of `--concurrent` parallel `Agent()` calls**. Each `Agent()` gets `subagent_type: "general-purpose"` and the `agent_brief` string from the plan as its `prompt`. Set `run_in_background: true` on all of them — agents in a wave run truly in parallel and the conversation-layer waits for completion notifications.
2. After every wave completes, run `ruby /tmp/assessment-<site>/batch/aggregate-results.rb` to show the running tally and surface YELLOW (review-needed) and RED (failed) results immediately.
3. Final aggregation prints the GREEN / YELLOW / RED breakdown and per-workbook Sigma URLs.

> **Mid-batch progress** depends on Agent completion notifications, not stdout streaming. The aggregator only sees completed subagent result lines in `batch-results.jsonl` — there's no in-flight "X% done" indicator. Use the completion notifications themselves as the progress signal.

**Cluster-aware execution**: a cluster's leader subagent runs first (alone or with other clusters' leaders in parallel) so it can build/pick the DM. Followers run in the next wave reusing the leader's DM via `find-or-pick-dm.rb` + `inspect-dm-shape.rb`. Within a cluster, **leaders never run in the same wave as their own followers**. The orchestrator handles this ordering.

**Parity tiers** (continue-on-failure):
- **GREEN** — workbook posted clean (0 column-errors, `verify-workbook.rb` clean), all chart actuals strict-PASS. Ready to publish.
- **YELLOW** — workbook posted clean BUT one or more charts diverge in values. Structural conversion succeeded; review numbers before stakeholder.
- **RED** — column-type errors, POST failure, verify failure, or no actuals fetchable. Auto-files a beads ticket; batch continues.

### Option C — VDS to Snowflake first

User wants to land Tableau-managed datasources into Snowflake before dashboards. Invoke:

```
Skill(
  skill: "tableau-vds-to-cdw",
  args:  "Land these <K> datasources from /tmp/assessment-<site>/migration-plan.json (each flagged recommended_path=vds-to-snowflake) into Snowflake. After completion, workbooks that source from these datasources become candidates for tableau-to-sigma conversion."
)
```

### Option D — Both (chained)

Run Option C, then on completion run Option B. The orchestrator picks workbooks where the source datasources now exist as Snowflake tables.

### Option E — Just write the readout

End the assessment. User will pick this up later.

---

## Multi-warehouse considerations

Sigma reads from many warehouses. The Tableau-side discovery in this skill
is warehouse-neutral (Tableau Cloud's Admin Insights doesn't care where the
underlying warehouse lives). The Sigma-side reconciliation and downstream
conversion path can be steered per warehouse:

| Stage | Snowflake | BigQuery | Databricks | Postgres / SQL Server / Redshift |
|---|---|---|---|---|
| Already-landed-table check (`migration-plan.rb`) | `--snowflake-conn <name>` shells out to `snow sql --connection ...` against `INFORMATION_SCHEMA.TABLES`. | Use `--warehouse-cli bq` (see "Extending the warehouse CLI" below) — run `bq query --use_legacy_sql=false 'SELECT table_name FROM <proj>.<ds>.INFORMATION_SCHEMA.TABLES'`. | Use `--warehouse-cli databricks` — `databricks sql query` against `information_schema.tables`. | `--warehouse-cli psql` / `sqlcmd` / `psql` against `information_schema.tables` (Postgres-shaped — Redshift uses `pg_table_def`). |
| Column discovery for DM build | `mcp__sigma-mcp-v2__describe` on a connection table, OR `scripts/discover-warehouse-columns.rb` (Sigma REST). **Both warehouse-agnostic.** | Same — Sigma's `/v2/connections/tables/<inodeId>/columns` works the same. | Same. | Same. |
| `recommended_path: vds-to-snowflake` value | Default: assumes Snowflake landing. | Substitute "BigQuery" / "Databricks" / etc. in the customer-facing readout. The internal token can stay `vds-to-snowflake` for now (renaming touches downstream consumers); prefer a customer-friendly `target_warehouse` field in `migration-plan.json` next iteration. | Same. | Same. |
| Custom SQL DM elements | Snowflake dialect by default — UPPERCASE aliases match Snowflake identifier casing. | BigQuery: use backticked names, watch for case sensitivity (it's case-sensitive on table names but not on column names by default). | Databricks: lowercase identifiers; quote with backticks. | Postgres / Redshift: lowercase identifiers by default; quote with double quotes. |

### Extending the warehouse CLI

`migration-plan.rb`'s `fetch_landed_tables(snow_conn, target_schema)` shells
out to `snow sql` to enumerate already-landed tables. To support other
warehouses, follow the same shape:

```ruby
def fetch_landed_tables_bq(project, dataset)
  q = "SELECT table_name FROM `#{project}.#{dataset}.INFORMATION_SCHEMA.TABLES`"
  out = `bq query --use_legacy_sql=false --format=json #{q.shellescape}`
  return Set.new unless $?.success?
  JSON.parse(out).map { |r| r['table_name'].to_s.upcase }.to_set
rescue StandardError
  Set.new
end
```

The function contract is: return a `Set<String>` of bare table names in
uppercase. Drop it in as a new branch off `--warehouse-cli` and the
downstream `recommended_path: vds-already-landed` reconciliation works
unchanged.

### Snowflake-flavored examples

Every worked example in this SKILL.md (the `TJ.PUBLIC.*` fixture tables,
the `snow sql` reconciliation, the `--snowflake-conn` flag, the
`tableau-vds-to-cdw` sibling skill) uses Snowflake because that's
where the development corpus and audit-run fixtures live. The Sigma-side
calls (`/v2/connections`, `/v2/connections/tables/<inodeId>/columns`,
`mcp__sigma-mcp-v2__query`) are warehouse-agnostic, so a customer running
the same assessment against a BigQuery / Databricks / Postgres Tableau
deployment gets the same readout structure.

---

## Pre-Phase-6 enhancement: complexity reuse

The conversion skill's Phase 0a (`scan-workbook-gaps.rb`) produces the same gap-counts this assessment already cached in `complexity.json`. When invoking `tableau-to-sigma` from this assessment's handoff, point it at the assessment dir — the converter can skip re-scanning.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `probe-admin-insights.rb` finds 0 datasources | User is not Site Admin | Surface limited-mode banner; skip sections 2–3 |
| MCP `get-datasource-metadata` returns 401 in batch | VizQL session contention | Serialize Admin Insights metadata calls (one at a time) |
| `query-datasource` returns `Field 'X' not found` | Field-name typo (e.g., `Event LUID` instead of `Event Id`) | Check `refs/admin-insights-fields.md` |
| `fetch-all-twbs.rb` 302 redirect on `/workbooks` | Missing `Tableau.base_path` prefix | Use `Tableau.base_path + "/workbooks"`, not `/workbooks` alone |
| Tableau PAT 4 consecutive signin failures | Tableau Cloud invalidates the PAT | Mint a new PAT in Tableau settings; re-run setup |
| `aggregate-complexity.rb` skips `.twbx` workbooks | Inner `.twb` not unzipped | `fetch-all-twbs.rb` unzips automatically; rerun the fetch step |
