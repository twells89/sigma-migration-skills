author: tjwells
id: usecases_tableau_to_sigma_migration
summary: Migrate a Tableau dashboard to a Sigma workbook end-to-end using Claude Code and the tableau-to-sigma skill — data model, controls, charts, layout, and parity verification.
categories: Use-cases
environments: web
status: Draft
feedback link: https://github.com/sigmacomputing/sigmaquickstarts/issues
tags: default
lastUpdated: 2026-05-28

<!-- NOTES TO THE QUICKSTART AUTHOR:
1: Replace `author:` with your handle before publish.
2: `id:` becomes the URL slug — keep it stable once shipped.
3: Status starts as Draft; flip to Published after review.
4: All screenshots referenced below are stubs — capture fresh PNGs during
   your dry-run conversion and drop them in assets/. Filenames assumed:
     assets/tts_arch.png          — one-line skill architecture diagram
     assets/tts_dashboard_src.png — the Tableau dashboard you're converting
     assets/tts_phase1d_png.png   — Tableau dashboard PNG inside Claude Code
     assets/tts_gap_report.png    — gaps-report.md screenshot
     assets/tts_dm_picker.png     — find-or-pick-dm.rb output
     assets/tts_layout_grid.png   — final Sigma workbook layout
     assets/tts_parity_pass.png   — phase6-parity.rb 5/5 pass
     assets/tts_hard_gate.png     — assert-phase6-ran.rb [OK] all gates pass
5: Replace example workbook names ("Orders Overview") with whatever you use
   in the live demo.
-->

# Tableau → Sigma: One-Workbook Migration with Claude Code

## Overview
Duration: 5

This QuickStart **QS** walks through migrating a single Tableau dashboard to a Sigma workbook using **your coding agent** (Claude Code, Cursor, Cortex Code, …) and the **tableau-to-sigma skill**. You'll point your agent at a Tableau dashboard URL and watch it discover the workbook structure, build (or reuse) a Sigma data model, generate the workbook spec, position the layout to mirror the source dashboard, and verify chart-level data parity against Tableau before declaring done.

The skill is a structured set of Ruby scripts and an `SKILL.md` runbook that your agent follows phase-by-phase. It's been hardened against the four most common conversion regressions — silent Phase 6 skip, orphan workbooks left in the customer's My Documents, runtime errors past the gate, and the auto-stack single-column layout fallback. A final hard-gate script (`assert-phase6-ran.rb`) refuses to declare success unless every check passes.

![tts_arch](assets/tts_arch.png)

<aside class="positive">
<strong>IMPORTANT:</strong><br> The migration is bidirectional in one direction only — Tableau is the source, Sigma is the target. Sigma is always the live warehouse; Tableau may be reading a frozen <code>.hyper</code> extract. Live-vs-extract drift is expected and the skill handles it via <code>--extract-mode</code> parity (see Phase 6).
</aside>

For an introduction to the Sigma side of the workbook spec, see [Sigma Workbooks](https://help.sigmacomputing.com/docs/workbooks-overview) in the help center.

### Target Audience
Sigma SEs, technical CSMs, and migration partners running 1:1 Tableau-to-Sigma conversions for customers — or scoping a batch migration with the companion `tableau-assessment` skill.

### Prerequisites

<ul>
  <li><strong>A coding agent that runs skills</strong> — Claude Code (CLI or desktop), Cursor, Cortex Code, etc. These skills are <strong>agent-neutral</strong>: each is a <code>SKILL.md</code> plus <code>scripts/</code>, indexed by <code>AGENTS.md</code> at the repo root. For Claude Code, the skill ships as a directory under <code>~/.claude/skills/tableau-to-sigma/</code>; other agents read the skill folder directly. Where this guide says "Claude," substitute your agent.</li>
  <li><strong>Sigma API credentials</strong> — client ID + secret. Run <code>ruby scripts/setup.rb</code> once; it writes them to both <code>~/.claude/settings.json</code> (Claude Code auto-loads it) and a neutral <code>~/.sigma-migration/env</code> that the scripts auto-source under any agent.</li>
  <li><strong>Tableau access</strong> — either the Tableau MCP tools loaded in your agent session (preferred) or a Tableau Personal Access Token via <code>ruby scripts/setup-tableau.rb</code> (PAT mode fallback). PAT mode is required when you need the workbook's <code>.twb</code> XML (most conversions).</li>
  <li>A target Tableau workbook you're authorized to convert. Sample dashboards live at <a href="https://public.tableau.com/app/profile/tableau.docs.team">Tableau Public's docs profile</a> if you don't have one handy.</li>
  <li>The source workbook's underlying tables must be reachable via a Sigma connection (Snowflake, BigQuery, Databricks, Redshift, Postgres, etc.). If the data only lives inside a Tableau extract, land it first with the <strong><code>tableau-vds-to-cdw</code></strong> sibling skill — see the decision tree in the next section.</li>
</ul>

<aside class="positive">
<strong>IMPORTANT:</strong><br> Use non-production resources when running the QuickStart for the first time. The skill creates a real Sigma workbook (and, in error-recovery scenarios, may iterate via PUT to update it).
</aside>

<button>[Sigma Free Trial](https://www.sigmacomputing.com/free-trial/)</button>

### What You'll Learn
<ul>
  <li>How to invoke the <code>tableau-to-sigma</code> skill from Claude Code with a single dashboard URL.</li>
  <li>What each conversion phase does — discovery, gap scan, DM reuse check, spec build, parity verification.</li>
  <li>How to read the gap report and accept / override the proposed Sigma translations.</li>
  <li>How the four hard-gate checks (parity ran, no orphans, no runtime errors, layout applied) prevent silent regressions.</li>
  <li>When to fall back to a hand-written layout vs the auto-layout from <code>build-dashboard-layout.rb</code>.</li>
</ul>

### What You'll Build
A live Sigma workbook that visually mirrors a Tableau dashboard, sourced from your warehouse via a Sigma data model, with every chart's data verified against the Tableau view CSV.

![tts_layout_grid](assets/tts_layout_grid.png)

![Footer](assets/sigma_footer.png)
<!-- END OF OVERVIEW -->

## **The Tableau Migration Skill Family**
Duration: 5

`tableau-to-sigma` is the centerpiece, but three skills work hand-in-hand to cover the full migration lifecycle — from site inventory at the start through ongoing data refresh after cutover. Knowing which skill to reach for at each step saves hours of dead ends.

<ul>
  <li><strong><code>tableau-assessment</code></strong> — <em>Phase 0: scoping</em>. Point it at a Tableau Cloud site and it inventories everything in ~90 seconds — environment counts, licenses, datasource mix, refresh history, per-workbook usage, per-workbook complexity (via a <code>.twb</code> gap-scan), and a value/cost-ranked migration shortlist. Run this BEFORE you commit to a conversion plan; the output tells you which workbooks convert clean today, which need redesign, and which to leave on Tableau. Complements (does not replace) Hakkoda's deeper Assessment App. Also emits the cluster plan that <code>tableau-to-sigma</code> consumes for batch runs.</li>
  <li><strong><code>tableau-to-sigma</code></strong> — <em>Phases 1–6: the conversion</em>. The subject of this QuickStart. Takes a single workbook URL (or a cluster plan from <code>tableau-assessment</code>) and produces a live Sigma workbook with verified parity. Hardened against the four most-common silent regressions via a four-gate finalize check.</li>
  <li><strong><code>tableau-vds-to-cdw</code></strong> — <em>Phase 0.5: data landing, when needed</em>. Extracts a published Tableau datasource via the VizQL Data Service (VDS) API and lands it in your cloud warehouse — Snowflake (stored procedure + External Access Integration) or Databricks (serverless notebook on Unity Catalog), optionally scheduled for ongoing refresh. Reach for this when a customer's data lives <em>only</em> inside Tableau (extracts, Tableau Prep outputs, Web Data Connector feeds) and isn't already in the warehouse Sigma reads. Sigma needs warehouse-native data; this skill is the bridge.</li>
</ul>

<aside class="positive">
<strong>IMPORTANT:</strong><br> The decision tree below tells you when each skill applies. Don't run <code>tableau-to-sigma</code> until you've confirmed the underlying warehouse tables are reachable by Sigma — and don't run <code>tableau-vds-to-cdw</code> unless you actually need to (most customer data is already in the warehouse).
</aside>

![Alt text](assets/horizonalline.png)

**Decision tree — which skill, when:**

<ul>
  <li><strong>Migrating 1 workbook, data is in the warehouse</strong> → <code>tableau-to-sigma</code> only. Skip assessment.</li>
  <li><strong>Migrating 1 workbook, data is in a Tableau extract / not in the warehouse</strong> → <code>tableau-vds-to-cdw</code> first to land the data, then <code>tableau-to-sigma</code>.</li>
  <li><strong>Migrating 10+ workbooks (any data source)</strong> → start with <code>tableau-assessment</code> to inventory, classify, and cluster. Then run <code>tableau-to-sigma</code> in batch mode using the emitted cluster plan. Add <code>tableau-vds-to-cdw</code> per-datasource where warehouse coverage is missing.</li>
  <li><strong>Auditing BI sprawl / scoping a migration without committing</strong> → <code>tableau-assessment</code> only. Output is a shareable readout HTML + ranked workbook list. No Sigma artifacts created.</li>
  <li><strong>Just converting a Tableau datasource (TDS / TDSX) to a Sigma data model, no workbook</strong> → use the more general <code>sigma-data-model</code> converter (lives in the <code>sigma-skills</code> repo). It accepts pasted YAML / JSON / TDS XML and emits a Sigma DM spec. Out of scope for <code>tableau-to-sigma</code>, which is workbook-centric.</li>
</ul>

![Alt text](assets/horizonalline.png)

**Typical end-to-end flow for a customer migration:**

<ol>
  <li><code>tableau-assessment</code> against the customer's Tableau Cloud site → readout HTML, ranked shortlist, cluster plan</li>
  <li>Per cluster: confirm warehouse data coverage; run <code>tableau-vds-to-cdw</code> for any datasource Sigma can't reach</li>
  <li><code>tableau-to-sigma</code> per workbook (or in batch via <code>orchestrate-batch.rb</code> firing parallel subagents)</li>
  <li>Per-workbook GREEN/YELLOW/RED tier emitted into <code>batch-results.jsonl</code>; share with the customer</li>
</ol>

![Footer](assets/sigma_footer.png)
<!-- END OF SECTION -->

## **Install and Configure the Skill**
Duration: 10

The skill ships in the `sigma-migration-skills` repo. Install depends on your agent:

**Claude Code** (plugin marketplace):
```console
/plugin marketplace add twells89/sigma-migration-skills
/plugin install tableau-to-sigma@sigma-migration-skills
```

**Other agents (Cursor, Cortex Code, …):** clone the repo and point your agent at the skill folder — `AGENTS.md` at the repo root maps each task to its skill. No marketplace step needed.

```console
git clone https://github.com/twells89/sigma-migration-skills
# then open the repo in your agent; the skill lives at
#   plugins/tableau-to-sigma/skills/tableau-to-sigma/
```

Run the two setup scripts once per machine (from the skill's `scripts/` directory):

```console
ruby scripts/setup.rb
ruby scripts/setup-tableau.rb
```

`setup.rb` writes `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, and `SIGMA_CLIENT_SECRET`; `setup-tableau.rb` writes your Tableau site URL + PAT name + token. Both write to **`~/.claude/settings.json`** (Claude Code auto-loads it) **and** a neutral **`~/.sigma-migration/env`** that the scripts auto-source under any agent — so credentials work the same everywhere. Both prompt interactively and only need to run once.

<aside class="negative">
<strong>NOTE:</strong><br> Tokens are 1-hour bearer tokens fetched on demand via <code>scripts/get-token.sh</code>. Never hard-code tokens in scripts — every long-running script in the skill re-fetches on cold start.
</aside>

![Alt text](assets/horizonalline.png)

Verify the install. In **Claude Code**, start a fresh session and type:

```console
/tableau-to-sigma
```

Your agent should respond with the skill's preamble — a short summary of phases and a prompt for a Tableau dashboard URL. In **other agents**, ask it to read the skill's `SKILL.md` and begin a Tableau→Sigma migration.

![Footer](assets/sigma_footer.png)
<!-- END OF SECTION -->

## **Phase 1 — Discovery**
Duration: 10

Hand Claude a Tableau dashboard URL — e.g.:

```console
/tableau-to-sigma https://10ay.online.tableau.com/#/site/yoursite/views/OrdersDashboard/Overview
```

Claude resolves the URL to a workbook LUID and runs `scripts/tableau-discover.rb` in one shot. The script does, in parallel:

<ul>
  <li><strong>Workbook + views metadata</strong> — <code>GET /api/3.x/sites/{site}/workbooks/{luid}</code></li>
  <li><strong>VDS field list + Metadata GraphQL formulas</strong> — every datasource field including calculated fields</li>
  <li><strong>Workbook <code>.twbx</code> download</strong>, with the inner <code>.twb</code> XML extracted</li>
  <li><strong>View CSVs</strong> — every dashboard view fetched in concurrent batches of 4 (VizQL throttling guard)</li>
  <li><strong>Dashboard PNG</strong> — fetched solo after the CSVs to avoid VizQL session contention</li>
</ul>

The output lands in `/tmp/<workbook-slug>/`:

```console
/tmp/orders-conv/
  get-workbook.json
  workbook-content.twb
  ds-metadata.json
  graphql-fields.json
  views/<view-luid>.csv     (one per dashboard tile)
  views/<dashboard>.png     (the dashboard image)
```

Claude then **reads the dashboard PNG via the multimodal tool** before writing any spec — this is mandatory per the skill's Phase 1d checklist. CSV headers don't tell you bar-vs-pie, dual-axis-vs-single, or what controls live on the dashboard's filter shelf.

![tts_phase1d_png](assets/tts_phase1d_png.png)

![Alt text](assets/horizonalline.png)

In parallel with the PNG read, Claude runs `scripts/scan-workbook-gaps.rb` against the `.twb` to inventory every Tableau feature the workbook uses and classify each as:

<ul>
  <li><strong>✅ Auto:</strong> the skill translates end-to-end with no intervention</li>
  <li><strong>⚠️ Hint:</strong> the skill emits a WARN with a copy-paste Sigma formula; agent reviews</li>
  <li><strong>🛠 Manual:</strong> post-publish setup required (typically cross-chart action filters)</li>
  <li><strong>❌ Unhandled:</strong> feature not yet covered — the gap-scout subagent attempts an autonomous translation against the customer's Sigma org, persists the rule on success, escalates on failure</li>
</ul>

The report (`<workbook>-gaps-report.md`) is the first thing to share with the customer. It sets honest expectations before a single Sigma element is created.

![tts_gap_report](assets/tts_gap_report.png)

![Footer](assets/sigma_footer.png)
<!-- END OF SECTION -->

## **Phase 1.5 — Data Model Reuse**
Duration: 5

Before building a new data model, the skill scans your Sigma org for an existing DM that already covers the workbook's columns. `scripts/find-or-pick-dm.rb` parallel-fetches up to 25 DM specs and scores each against the workbook's signature:

<ul>
  <li><strong>Column overlap</strong> (0.7 weight) — how many of the workbook's referenced columns exist on the candidate DM</li>
  <li><strong>Source-table FQN overlap</strong> (0.2 weight) — does the DM source from the same warehouse tables</li>
  <li><strong>Metric overlap</strong> (0.1 weight)</li>
</ul>

A score ≥ 0.85 auto-reuses the DM (saves Phases 2-3 — typically the heaviest 2-3 minutes of the conversion). A score between 0.6 and 0.85 prompts the operator. Below 0.6, the skill builds new.

![tts_dm_picker](assets/tts_dm_picker.png)

When reusing a DM, the mandatory next step is `scripts/inspect-dm-shape.rb`. This inspects the DM's element graph and emits a per-column resolution plan classifying each workbook-referenced column as either:

<ul>
  <li><strong><code>location: "fact"</code></strong> — direct reference, formula <code>[Master/Column Name]</code></li>
  <li><strong><code>location: "dim"</code></strong> — Lookup required, with the exact formula shown verbatim</li>
</ul>

This eliminates the 2-3 minute spec-rework loop that previously hit when a reused DM had separate dim elements and the agent assumed a flat fact.

![Footer](assets/sigma_footer.png)
<!-- END OF SECTION -->

## **Phase 5 — Build the Sigma Workbook**
Duration: 15

With the DM resolved (reused or freshly built), Claude composes the workbook spec. For a single-dashboard URL the default is **dashboard-fidelity mode** — every Tableau tile maps to a Sigma element, positioned in the same grid.

The spec follows three mandatory rules — surfaced loudly in the skill's SKILL.md and the spec validator:

<ul>
  <li><strong>Two pages, always.</strong> A hidden <code>Data</code> page holds the master table (sourced from the DM); a content page holds the charts, controls, and text. Co-locating master + charts puts a giant table on the dashboard the customer has to delete.</li>
  <li><strong>Master is the single source.</strong> Every chart element sets <code>source: {kind: "table", elementId: "master"}</code>, regardless of which page it lives on. Cross-page references are fully supported.</li>
  <li><strong>POST once, PUT for every update.</strong> <code>POST /v2/workbooks/spec</code> is create-only. Re-POSTing during error recovery creates a duplicate workbook in the customer's My Documents — exactly the regression that motivated the orphan-cleanup tooling.</li>
</ul>

<aside class="positive">
<strong>IMPORTANT:</strong><br> The skill auto-emits <code>chart_kind</code> for every Tableau worksheet from its <code>&lt;mark&gt;</code> class + Rows/Cols shelves. Coverage:
<br>
<ul>
  <li><code>bar</code> / <code>line</code> / <code>area</code> / <code>pie</code> / <code>scatter</code> — straightforward 1:1</li>
  <li><code>pivot-table</code> — Text/Square mark with dims on BOTH shelves, or the Measure-Names crosstab pattern. Emits Sigma <code>pivot-table</code> with <code>rowsBy</code> / <code>columnsBy</code> / <code>values</code>.</li>
  <li><code>kpi</code> — Text/Square mark with zero dims and a single measure (Tableau "scorecard"). Emits Sigma <code>kpi-chart</code> with <code>value</code>.</li>
  <li><code>table</code> — Text mark with dims on one shelf only (flat detail list).</li>
  <li><code>map-region</code> / <code>map-point</code> — choropleth and lat/long maps.</li>
</ul>
</aside>

After the workbook POST + readback, Claude builds and applies the layout:

```console
ruby scripts/build-dashboard-layout.rb \
  --layout /tmp/<name>/dashboard-layout.json \
  --wb-ids /tmp/<name>/wb-ids.json \
  --out /tmp/<name>/layout.xml

ruby scripts/put-layout.rb \
  --workbook <workbook-id> \
  --layout /tmp/<name>/layout.xml
```

`build-dashboard-layout.rb` walks each Tableau zone, converts its `x_pct` / `y_pct` / `w_pct` / `h_pct` into Sigma 24-column grid spans, and stretches adjacent tiles to close gaps where Tableau had legend or filter zones Sigma doesn't render. **Skipping this step makes Sigma render every tile in a single-column auto-stack** — the regression the hard gate catches.

![tts_layout_grid](assets/tts_layout_grid.png)

![Footer](assets/sigma_footer.png)
<!-- END OF SECTION -->

## **Phase 6 — Parity Verification**
Duration: 10

The conversion is not complete until every chart's Sigma values match Tableau's view CSV. `scripts/phase6-parity.rb` runs in two passes:

<ul>
  <li><strong>Pass 1</strong> — auto-builds a parity plan by matching Sigma chart-element names to Tableau view CSVs; emits per-chart SQL queries.</li>
  <li><strong>Pass 2</strong> — finalize: Claude fires the listed Sigma queries in a single parallel MCP batch, the script verifies row-level equality (or structural-only with measure-drift tolerance when <code>--extract-mode</code> is set), and writes <code>parity-final.json</code>.</li>
</ul>

```console
ruby scripts/phase6-parity.rb --tableau /tmp/<name> --workbook-id <id>
# ... agent collects actuals via mcp__sigma-mcp-v2__query ...
ruby scripts/phase6-parity.rb --tableau /tmp/<name> --finalize \
  --actuals /tmp/<name>/parity-actuals.json
```

![tts_parity_pass](assets/tts_parity_pass.png)

![Alt text](assets/horizonalline.png)

The conversion is gated by `scripts/assert-phase6-ran.rb`, which checks **four** independent things:

<ol>
  <li><strong>Phase 6 ran</strong> — <code>parity-final.json</code> exists with <code>status=PASS</code> at the required pass-rate</li>
  <li><strong>No orphan workbooks</strong> — <code>posted-workbooks.jsonl</code> has ≤ 1 entry, or <code>cleanup-marker.json</code> shows a successful non-dry-run cleanup</li>
  <li><strong>No <code>type=error</code> columns</strong> on the live workbook — catches circular references and runtime errors introduced after the initial POST</li>
  <li><strong>Real layout applied</strong> — the workbook spec's top-level <code>layout</code> field is non-empty and isn't Sigma's auto-stack signature</li>
</ol>

```console
ruby scripts/assert-phase6-ran.rb --tableau /tmp/<name>
```

![tts_hard_gate](assets/tts_hard_gate.png)

Exit 0 means the conversion may declare GREEN. Any non-zero exit means downgrade to YELLOW or RED with a documented reason.

![Footer](assets/sigma_footer.png)
<!-- END OF SECTION -->

## **Common Issues and Fixes**
Duration: 5

<ul>
  <li><strong>Three workbooks in My Documents.</strong> POST is create-only; each retry creates a new workbook. Run <code>ruby scripts/cleanup-orphan-workbooks.rb --workdir /tmp/&lt;name&gt;</code> to delete all-but-the-most-recent ID via <code>DELETE /v2/files/{id}</code>.</li>
  <li><strong>Single-column auto-stack layout.</strong> Sigma's server auto-generates a left-half stacked layout when a workbook is POSTed without one. <code>assert-phase6-ran.rb</code> gate 4 catches this; fix by running <code>build-dashboard-layout.rb</code> + <code>put-layout.rb</code>.</li>
  <li><strong>Chart renders blank in Sigma but spec compiled.</strong> A column resolved to <code>type=error</code> — typo'd ref, <code>IsIn()</code>, a window function in a calc column. Run <code>verify-workbook.rb</code> for the diagnostic; <code>mcp__sigma-mcp-v2__describe</code> on the element shows which column is broken.</li>
  <li><strong>Pivot table appears as a flat table.</strong> Verify <code>parse-twb-layout.rb</code> emitted <code>chart_kind: pivot-table</code>. If it emitted <code>table</code> instead, the source worksheet had dims on only one shelf — that's a flat detail list, not a crosstab.</li>
  <li><strong>KPI tile missing from Sigma.</strong> If a Tableau scorecard parsed as something other than <code>chart_kind: kpi</code>, the worksheet probably had a hidden dim on a shelf (color encoding, detail). Inspect <code>rows_shelf</code> / <code>cols_shelf</code> on the zone JSON.</li>
  <li><strong>Sigma MCP query 401s mid-Phase 6.</strong> The MCP session has staled. Re-call <code>mcp__sigma-mcp-v2__begin_session</code> and retry the query. Do not abandon Phase 6 over a recoverable auth error.</li>
  <li><strong>"Table not found" / "Connection has no access" during Phase 2.</strong> The warehouse table the Tableau workbook reads isn't in any Sigma connection your user can reach. Either (a) ask the customer to grant Sigma access to the existing warehouse table, or (b) land the Tableau datasource into a fresh warehouse table using the sibling <strong><code>tableau-vds-to-cdw</code></strong> skill, then re-run <code>tableau-to-sigma</code>. The skill explicitly bails before authoring a broken spec.</li>
</ul>

![Footer](assets/sigma_footer.png)
<!-- END OF SECTION -->

## **Scaling Up — Batch Conversion**
Duration: 5

For multi-workbook migrations (10+ workbooks at once), `tableau-to-sigma` is one of three skills you'll use together — see *The Tableau Migration Skill Family* earlier in this QuickStart for the full picture. The batch flow specifically pairs the converter with the **`tableau-assessment`** skill:

<ol>
  <li><strong><code>tableau-assessment</code></strong> inventories the customer's Tableau Cloud site (workbooks, datasources, refresh history, license posture, per-workbook complexity from a <code>.twb</code> gap-scan) and emits two artifacts: a shareable readout HTML for the customer conversation, and a <code>batch-plan.json</code> with wave-by-wave subagent briefs. Workbooks are clustered by shared warehouse tables so workbooks that should share a DM build a leader DM first and followers reuse it.</li>
  <li>For any cluster whose data <em>isn't</em> already in the warehouse, run <strong><code>tableau-vds-to-cdw</code></strong> per datasource before kicking off the cluster's conversion wave. Sigma needs warehouse-native data; the converter can't operate on a Tableau-extract-only datasource.</li>
  <li>The conversation-layer agent fires each conversion wave as a parallel batch of <code>Agent()</code> calls, each carrying a self-contained brief generated by <strong><code>tableau-to-sigma</code></strong>'s <code>scripts/orchestrate-batch.rb</code> companion in <code>tableau-assessment</code>. Cluster leaders build the DM; followers reuse it via <code>find-or-pick-dm.rb</code> + <code>inspect-dm-shape.rb</code>. Continue-on-failure semantics mean a single broken workbook doesn't block the rest of the batch.</li>
</ol>

Per-follower real time is typically 6-8 min — saves the 2-3 minutes of Phase 2+3 plus most of Phase 1 by reusing the leader's discovery artifacts.

<aside class="negative">
<strong>NOTE:</strong><br> Each subagent runs the full hard gate at the end of its conversion. Subagents that fail any gate self-report YELLOW or RED in <code>batch-results.jsonl</code> with a specific error_summary — the orchestrator never silently declares done. Per-subagent results feed back into a final batch summary the customer can review tier-by-tier.
</aside>

![Footer](assets/sigma_footer.png)
<!-- END OF SECTION -->

## What we've covered
Duration: 5

In this QuickStart we:

<ul>
  <li>Mapped the three Tableau migration skills — <code>tableau-assessment</code> for scoping, <code>tableau-to-sigma</code> for conversion, <code>tableau-vds-to-cdw</code> for data landing — and the decision tree for picking the right one</li>
  <li>Installed and configured the <code>tableau-to-sigma</code> skill for Claude Code</li>
  <li>Ran Phase 1 discovery against a real Tableau dashboard — workbook metadata, view CSVs, .twb XML, dashboard PNG</li>
  <li>Read the gap report to set expectations before authoring a spec</li>
  <li>Reused an existing Sigma data model (or built a new one) via the picker + denormalization plan</li>
  <li>Composed the Sigma workbook spec — master on a hidden Data page, charts + controls on the content page</li>
  <li>Built and applied the dashboard layout XML from Tableau zone percentages</li>
  <li>Ran Phase 6 parity verification with the mandatory four-gate hard check</li>
  <li>Cleaned up orphan workbooks and confirmed no runtime errors made it past the gate</li>
  <li>Saw how the same converter scales to batch via <code>tableau-assessment</code>'s cluster plan and the orchestrator's wave-based subagent flow</li>
</ul>

The end-result is a live Sigma workbook with verified data parity against the source Tableau dashboard, ready to share with the customer — and a clear path to scale the same conversion to dozens or hundreds of workbooks with the rest of the skill family.

![tts_layout_grid](assets/tts_layout_grid.png)

<!-- THE FOLLOWING ADDITIONAL RESOURCES IS REQUIRED AS IS FOR ALL QUICKSTARTS -->
**Additional Resource Links**

[Blog](https://www.sigmacomputing.com/blog/)<br>
[Community](https://community.sigmacomputing.com/)<br>
[Help Center](https://help.sigmacomputing.com/hc/en-us)<br>
[QuickStarts](https://quickstarts.sigmacomputing.com/)<br>

Be sure to check out all the latest developments at [Sigma's First Friday Feature page!](https://quickstarts.sigmacomputing.com/firstfridayfeatures/)
<br>

[<img src="./assets/twitter.png" width="75"/>](https://twitter.com/sigmacomputing)&emsp;
[<img src="./assets/linkedin.png" width="75"/>](https://www.linkedin.com/company/sigmacomputing)&emsp;
[<img src="./assets/facebook.png" width="75"/>](https://www.facebook.com/sigmacomputing)

![Footer](assets/sigma_footer.png)
<!-- END OF WHAT WE COVERED -->
<!-- END OF QUICKSTART -->
