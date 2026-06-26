author: Sigma Computing
summary: Migrating from IBM Cognos made easy — convert Cognos Analytics Data Modules and reports to Sigma with Claude Code
id: developers_migrating_from_cognos_made_easy
categories: Developers, Migration, AI
environments: Web
status: Draft
feedback link: https://github.com/sigmacomputing/quickstarts-public/issues

# Migrating from IBM Cognos Analytics to Sigma made easy

## Introduction & why it matters
Duration: 2

Rebuilding IBM Cognos content in a new BI tool by hand is slow and error-prone — you
re-derive the semantic layer from the Data Module, re-type every calculation in a new
expression language, and hope the numbers still tie out.

This quickstart automates the whole path with **your coding agent** (Claude Code,
Cursor, Cortex Code, …) + a set of Cognos→Sigma skills: it discovers Cognos content,
translates the Cognos expression DSL to Sigma formulas, builds a Sigma data model and a
matching workbook (lists, crosstabs, charts, **and maps**), and **verifies data parity**
against the same warehouse — typically to the cent.

positive
: These skills are **agent-neutral** — each is a `SKILL.md` plus `scripts/`. `AGENTS.md` at the repo root maps each task to its skill, and the scripts auto-load credentials, so they run the same under any agent. Where this guide says "Claude Code," substitute your agent.

positive
: The Sigma side reads your warehouse **live**, so the migrated workbook stays current with no scheduled refresh/extract — a difference you'll see in the parity check when new rows land.

## Who this is for
Duration: 1

- Sigma SEs and technical CSMs
- Migration partners
- Cognos authors evaluating a move to Sigma

You do **not** need to be a Sigma or Cognos internals expert — the skills carry the
domain knowledge. You do need access to a Cognos Analytics instance and a Sigma org whose
connection reaches the same warehouse the Cognos content reports on.

## Prerequisites
Duration: 2

- **A coding agent that runs skills** — Claude Code (CLI or desktop), Cursor, Cortex Code, etc.
- **Cognos Analytics 11.1+ REST access** (on-prem or CA on Cloud). Base path is `<host>/bi/v1`
  (**not** `/api/v1`). Auth = a logged-in session: a **session cookie** + the **`X-XSRF-Token`**
  header. On IBMid-SSO trials you can't log in headlessly — grab a live browser session
  (DevTools → Network → any `…/bi/v1/…` request → **Copy as cURL**) and feed it to
  `scripts/get-cognos-session.sh`.
- **Sigma API credentials** (`SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`).
- A **Sigma connection to the same warehouse** the Cognos content reports on (for true parity).
- The **`convert_cognos_to_sigma`** + **`convert_cognos_report_to_sigma`** converters (part of
  the sigma-data-model MCP), or the bundled `converter/` (Node + `fast-xml-parser`).

negative
: CAoC (Cognos on Cloud) sessions are short-lived and sit behind Akamai bot-protection — a copied session can return **HTTP 441** within minutes (the SPA's `X-CA-SSO: 441` header is the re-auth signal), and curl replay may be rejected outright. Re-login + re-copy a *hot* session, or use a **CA API key / service credential** where the tenant allows it (the durable path).

## The two-skill ecosystem
Duration: 2

| Skill | Role |
|---|---|
| **`cognos-assessment`** | Inventory a Cognos estate + score per-artifact migration complexity against the converter's exact coverage (which calcs/charts auto-convert vs. flag — macros, running-total/rank, treemap/network/word-cloud, FM `.cpf`, drill-through) → a value/cost-ranked shortlist. Run this first to decide what to migrate. |
| **`cognos-to-sigma`** | The conversion: discover → convert Data Module + report → POST + read back ids → wire the workbook to the model → parity-verify. |

Both mirror the Tableau / Power BI / Qlik migration skills: same shortlist math and the
same `migrate-first / easy-win / needs-review` tagging.

## Installation & setup
Duration: 5

1. **Add the marketplace and install the plugin** (Claude Code):
   ```text
   /plugin marketplace add twells89/sigma-migration-skills
   /plugin install cognos-to-sigma@sigma-migration-skills
   ```
   Installs both skills, namespaced — e.g. `/cognos-to-sigma:cognos-assessment`.
   **Other agents (Cursor, Cortex Code, …):** clone the repo and point your agent at
   `plugins/cognos-to-sigma/skills/…`; `AGENTS.md` indexes every skill.
2. **Sigma credentials** — export `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`; the skill's
   `scripts/get-token.sh` exchanges them for a `SIGMA_API_TOKEN`.
3. **Capture a live Cognos session** — required before any discovery/extraction. See the
   dedicated **"Capture a Cognos session (Copy as cURL)"** step below — do it first.
4. **Verify the converter offline** (no Cognos access needed):
   ```bash
   cd converter && npm install && npm test   # converts every bundled real-IBM-sample fixture
   ```

## Capture a Cognos session (Copy as cURL) — REQUIRED
Duration: 4

Cognos has no headless login on IBMid-SSO trials, and CA-on-Cloud sits behind **Akamai
bot-protection**. So **every** discovery/extraction call needs a **live browser session**,
captured with **Copy as cURL**. Do this first — nothing else works without it.

1. Log in to Cognos in Chrome and open the dashboard/report you're migrating.
2. **DevTools → Network**, click any request to `…/bi/v1/…` (e.g. a `…/data` or
   `…/objects/…` call), then **right-click → Copy → Copy as cURL**.
3. From that cURL, save the **full `Cookie` header** (the whole `-b '…'` value, including the
   Akamai cookies `_abck` / `bm_sz` / `bm_sv` / `ak_bmsc`) to `~/.cognos/cookie.txt`, and note
   the **`X-XSRF-TOKEN`** value. Then:
   ```bash
   export COG_BASE="https://<host>/bi/v1"  COG_XSRF="<X-XSRF-TOKEN value>"
   eval "$(scripts/get-cognos-session.sh)"
   cog_get "/objects/.public_folders/items?fields=defaultName,type,id"   # smoke test
   ```

negative
: **The cookie is the whole point — not the API key.** A CA API key authenticates (201) but Akamai still **441/403**s every content call, because the wall is **TLS/JA3 fingerprinting**, not auth. Curl can't look like Chrome, so even a perfect cookie may be rejected on replay. The session is also short-lived (minutes) — if you get **HTTP 441**, re-copy a *hot* cURL.

positive
: **Akamai-walled tenant (curl keeps 441'ing) or migrating a dashboard?** Drive a **headed Chrome via Puppeteer** with the copied cookies injected — real-browser TLS passes Akamai, and you can screenshot the live dashboard as a visual target and replay its `/bi/v1/datasets/{id}/data` queries to pull rows. Full recipe in **`refs/dashboard-migration.md`**.

## Prepare demo data (optional)
Duration: 3

No Cognos instance handy? The converter ships with **real IBM sample** fixtures
(Great Outdoors, GO sales performance, Telco churn, a banking crosstab, a multi-chart
sales overview) in `fixtures/` — `npm test` converts them all. For a **parity** demo,
land IBM's published `GOSALES` / `GOSALESDW` sample databases into the warehouse your
Sigma connection reads, and point the converter at a Cognos report built on them.

## Run the conversion
Duration: 10

In Claude Code, point the `cognos-to-sigma` skill at a Data Module + report. The skill
runs these phases (`scripts/*`):

1. **Discover** (`cognos-batch-fetch.sh` / `cognos-discover.sh`) — pull the **Data Module
   JSON** (`GET /bi/v1/metadata/modules/{id}`) and **report-spec XML**
   (`GET /bi/v1/objects/{id}?fields=specification`). For anything beyond a couple of
   objects use `cognos-batch-fetch.sh batch`: it fetches the whole estate in one
   hot-session window (4-wide, resumable disk cache keyed id+modificationTime) — a
   dead session resumes instead of restarting, and single-artifact runs (`one`) are
   served from the same cache.
2. **Convert the Data Module** (`cli.ts <module.json>`) — query subjects → warehouse-table
   elements, items → columns/metrics, calculations → Sigma formulas (`total..for`→`SumOver`,
   `if/then/else`→`If`, date/string fns), relationships → DM relationships.
3. **POST + read back** (`post-and-readback.mjs --type datamodel`) — POST to
   `/v2/dataModels/spec`, read it back, and **fail on any `type=error` column** (a 200 POST
   isn't proof — formulas can fail to resolve at query time).
4. **Convert the report + wire it** (`cli.ts <report.xml> --dm <id>` →
   `remap-wb-to-dm-ids.mjs`) — lists→tables, crosstabs→pivots, charts→bar/line/pie/etc.,
   `tiledmap`→region-map/point-map, prompts→controls. `remap-wb-to-dm-ids.mjs` rewrites the
   workbook's `source.elementId` placeholders to the real posted element ids.
5. **POST the workbook** (`post-and-readback.mjs --type workbook`) → `/v2/workbooks/spec`,
   error-column gate re-run.
6. **Verify parity** (`assert-parity.mjs`) — `--plan` emits per-element SQL; run it, then
   `--check` compares the actuals to the Cognos source. **GREEN only when `--check` passes.**

positive
: Between steps 2 and 3 the skill runs a **DM-reuse check** (Phase 1.5: `cognos-dm-signature.py` + `find-or-pick-dm.rb`): it scores the org's existing Sigma data models against the module's tables/columns and on a strong match asks reuse-vs-new — skipping the POST and avoiding DM sprawl.

positive
: Run `cognos-assessment` first on the whole estate to rank what's worth migrating and surface the manual-work gaps *before* you start.

## Understanding the output
Duration: 3

- **Assessment readout** (`cognos-assessment`) — per-artifact complexity, a converter-coverage
  score (% auto-migratable), a named gap list (with the *reason* + remediation per gap), and a
  ranked shortlist, rendered as a branded HTML report.
- **Conversion warnings** — the converter **flags, never fakes**: runtime macros, running-total /
  rank / lag-lead, `GetResourceString`, composite joins, and unsupported viz (treemap / network /
  word-cloud → a flagged table) come out as warnings to re-author, not wrong logic.
- **Parity check** — the migration is GREEN only when Sigma's numbers match the warehouse
  (the skill hard-gates on this).

## Reference & gotchas
Duration: 3

`refs/` collects the hard-won rules, including:

- **Column formula prefix = the warehouse table tail** — `[ORDER_FACT/Net Revenue]`, not the
  element display name (wrong prefix → "dependency not found" at POST).
- **Pivot** `values` are **bare column-id strings** (not `{id}` objects); `rowsBy`/`columnsBy`
  are `{id}` objects.
- **Charts** map by slot: `categories`→`xAxis`, `values`/`size`→`yAxis` (aggregated by
  `rollupMethod`), `series`/`color`→`color`; pie/donut use `value`+`color`.
- **Maps** — `tiledmap` lat/long slots → `point-map`; named-location slots → `region-map`
  (`regionType` defaults to `country`, flagged to confirm).
- **Workbook POST responses are YAML**, not JSON — parse the `workbookId` accordingly.
- **Sessions:** CAoC `HTTP 441` = re-login + re-copy the full cookie; prefer a CA API key.
  Batch everything you need into one hot-session window (`cognos-batch-fetch.sh batch`)
  — it resumes from its disk cache after a 441 instead of restarting.

## The techniques worth carrying forward
Duration: 1

- **Assess first** — convert the high-value, low-effort artifacts before the long tail.
- **Treat the warehouse as the source of truth** — Sigma reads it live; parity is the gate.
- **Flag, never fake** — the parts with no clean Sigma analog come back as warnings, not
  silently-wrong formulas.
- **Read back + remap** — POST reassigns ids; `remap-wb-to-dm-ids.mjs` re-wires the workbook.

Next: run `cognos-assessment` on your estate, pick the shortlist, and let `cognos-to-sigma`
convert the top N.
