---
name: powerbi-assessment
description: Take inventory of a Power BI / Fabric tenant and produce a migration-readiness readout — environment counts, per-semantic-model DAX complexity (measures / calc columns / calc tables / RLS / DirectQuery / warehouse sources from M), per-report visual complexity, refresh history, a DAX-convertibility score against the Sigma coverage buckets, and a value/cost-ranked migration shortlist. Use when a user wants to scope a Power BI→Sigma migration, audit BI sprawl, or pick which reports to convert first. READ-ONLY — never writes to Power BI or posts to Sigma. Lightweight, device-code auth (no Entra app). Feeds the powerbi-to-sigma conversion skill.
user-invocable: true
---

# Power BI / Fabric Assessment

Surveys a Power BI / Fabric tenant — **what the signed-in user can access** —
via the Fabric REST API and the Power BI REST API, authenticated through a
Microsoft first-party public client (device-code, no Entra app registration).
Emits a markdown readout + JSON inventory + a value/cost-ranked migration
shortlist the user can hand to a Sigma rep or directly to the
`powerbi-to-sigma` conversion skill.

This is the Power-BI sibling of `tableau-assessment` — same file layout, same
readout sections, same privacy discipline, same value/cost shortlist scoring —
adapted to Power BI's two-artifact world (semantic model + report).

> **READ-ONLY.** Every call is a GET (plus one read-only Scanner-API `POST
> getInfo` *probe* with an empty body). The skill **never** writes to Power BI
> and **never** posts to Sigma. It does not edit anything outside its output
> directory.

> **Warehouse-agnostic.** Power BI models source from many warehouses
> (Snowflake, BigQuery, Databricks, Redshift, Synapse, Postgres, …). The skill
> parses the warehouse host out of each model's M (Power Query) expression and
> reports it; the downstream `powerbi-to-sigma` converter re-points Sigma at the
> same tables regardless of which warehouse it is. Worked examples here use
> Snowflake because that's where the dev fixtures live.

---

## Privacy posture (READ FIRST, surface to the customer)

**This skill reads report / model metadata, not warehouse data.** What crosses
Anthropic's API on its way through Claude:

| Crosses Anthropic API | Stays local |
|---|---|
| Aggregate counts (workspace / model / report counts) | Warehouse rows (never queried) |
| Model names, report names, workspace names | Power BI / Entra credentials |
| **Full TMSL** — DAX measure/calc-column expressions + **RLS role definitions** | Actual report cell values |
| **PBIR** — visual configuration / page structure | `.pbix` binary model blobs |
| Warehouse host names parsed from M | Warehouse credentials |
| Refresh job results | |

> **Broader / more sensitive than Tableau's `.twb`.** We pull **full TMSL
> (DAX + RLS role definitions)** and **PBIR (visual config)**. If RLS roles or
> DAX encode business-sensitive logic, that text crosses the API. Tell the
> customer before running. See `PRIVACY.md` for the full disclosure.

---

## When to use this skill

- A Power BI customer wants a fast scoping view before a deeper migration engagement
- A Sigma SE preparing for a discovery call wants a pre-built migration shortlist
- A customer is deciding which Power BI reports to retire vs. migrate
- A `powerbi-to-sigma` invocation needs a Phase 0 inventory of the source tenant

---

## Setup (one-time)

```bash
# venv already exists at /tmp/pbiauth from powerbi-to-sigma; if not:
python3 -m venv /tmp/pbiauth
/tmp/pbiauth/bin/pip install -r scripts/requirements.txt   # msal, requests, truststore
```

> **Windows:** the venv layout differs — use `Scripts\` instead of `bin/` (e.g.
> `python -m venv \tmp\pbiauth` then `\tmp\pbiauth\Scripts\pip.exe install -r
> scripts\requirements.txt`, and `\tmp\pbiauth\Scripts\python.exe` in place of
> `/tmp/pbiauth/bin/python` everywhere below). The `powerbi-to-sigma` orchestrator
> (`migrate-powerbi.rb`, `phase6-parity-pbi.rb`) already probes both layouts and
> falls back to `PyResolve` — this note is only for the manual commands on this page.

Auth reuses the working recipe documented in
`powerbi-to-sigma/refs/connection.md`: well-known PowerBI Desktop public client
`ea0616ba-638b-4df5-95b9-636659ae5121`, scope
`https://api.fabric.microsoft.com/.default`, `truststore.inject_into_ssl()`
mandatory (corp TLS), token cache at `/tmp/pbiauth/cache.bin`. The scripts call
`acquire_token_silent` first — if a cached token exists (it does after any
`powerbi-to-sigma` run), **no interaction is needed**. Pass `--no-interactive`
to forbid the device-code fallback entirely (headless / CI).

---

## Scripts overview

| Script | Lang | Purpose | Reused from tableau-assessment? |
|---|---|---|---|
| `scripts/fabric-inventory.py` | Python | Phase 1-3: workspaces + items + per-model TMSL complexity + per-report PBIR complexity + refresh history → `inventory.json`, `raw-tmsl/`, `raw-pbir/` | **New** (PBI auth + TMSL/PBIR parsing has no Tableau analog) |
| `scripts/probe-admin.py` / `probe-admin.rb` | Python / Ruby | Probe whether the user has the **Fabric Administrator** role (Activity Events + Scanner APIs); degrade gracefully | **Adapted** from `probe-admin-insights.rb` (the parse-and-decide shape) |
| `scripts/score-complexity.rb` | Ruby | Derive per-report DAX/visual complexity (a/b/c → auto/manual/unhandled) → `complexity.json` | **New** (DAX-bucket logic), but emits the tableau-compatible `n_auto/n_hint/n_manual/n_unhandled` shape |
| `scripts/build-shortlist.rb` | Ruby | Cross-tab usage × complexity; `score = value/(1+cost)` → `shortlist.json` | **Adapted** — same scoring formula & tag rules; PBI value-source + complexity-only fallback added |
| `scripts/render-readout.rb` | Ruby | Compose `readout.md` from the JSON files | **Adapted** — `md_table`/`section_block`/`md_cell` helpers reused verbatim; gather-body is PBI-specific |
| `scripts/migration-plan.rb` | Ruby | Per-report `recommended_path` + DM clusters (by shared semantic model) → `migration-plan.json` | **Adapted** — same contract shape; clustering keyed on shared model instead of `.twb`-table Jaccard |

> **What was reused vs rewritten:** the renderer's templating helpers and the
> shortlist's value/cost scoring + tag vocabulary are lifted from
> `tableau-assessment` (vendor-agnostic). The auth layer, TMSL/PBIR parsing, DAX
> classification, and the model-centric clustering are new because Power BI's
> data shape (separate model + report, DAX instead of Tableau calcs) has no
> direct Tableau equivalent. `render-readout.rb` and `build-shortlist.rb` were
> **adapted in place** rather than symlinked, because the section bodies and the
> value-source logic differ enough that a symlink would force per-vendor
> branching into the shared file.

---

## Modes

| Mode | Setup | Coverage | Use when |
|---|---|---|---|
| **User-delegated** *(default)* | Cached token only | Environment + per-model DAX complexity + per-report visuals + refresh + **complexity-only** shortlist | Any user; the common case |
| **Fabric Admin** | User has the Fabric Administrator role | Adds usage/adoption (views, distinct users) → **usage-weighted** shortlist, and tenant-wide sprawl (Scanner API) | Tenant admin running the scope themselves |

The skill probes the admin role once and degrades to complexity-only on 403 —
it never fails because the user isn't an admin.

---

## Phase 0 — Probe access

```bash
# 0a. Can we get a token at all? (silent — uses the cache)
/tmp/pbiauth/bin/python scripts/fabric-inventory.py --out /tmp/pbi-assessment-<tenant> --limit-models 1 --no-interactive
#   NO_TOKEN on exit 2 → cache is cold; run any powerbi-to-sigma extract once to
#   seed it, or drop --no-interactive to sign in via device code.

# 0b. Fabric Administrator? (gates the usage section)
/tmp/pbiauth/bin/python scripts/probe-admin.py --no-interactive | ruby scripts/probe-admin.rb
#   exit 0 → admin (usage available). exit 3 → complexity-only (the common case).
```

---

## Phase 1-3 — Inventory + complexity (always runs)

```bash
/tmp/pbiauth/bin/python scripts/fabric-inventory.py --out /tmp/pbi-assessment-<tenant>
ruby scripts/score-complexity.rb --out /tmp/pbi-assessment-<tenant>
```

`fabric-inventory.py` does, per workspace:
- `GET /v1/workspaces` (+ `capacityId` → on-capacity flag)
- `GET /v1/workspaces/{id}/items` → counts by type
- `GET /v1/workspaces/{id}/semanticModels` then per model
  `POST .../getDefinition?format=TMSL` (202 LRO — polled) → table / measure /
  calc-column / calc-table counts, RLS role count, import-vs-DirectQuery,
  warehouse sources parsed from M, and **DAX complexity** (per-measure bucket
  a/b/c classification + measure length).
- `GET /v1/workspaces/{id}/reports` then per report
  `POST .../getDefinition` (PBIR) → page count, visual count, visual-kind
  histogram, custom-visual usage. Report → model linkage (`dataset_id`) is
  recovered from the **Power BI REST** `/groups/{ws}/reports` endpoint (the
  Fabric endpoint omits it — see `refs/fabric-fields.md`).

`score-complexity.rb` maps DAX buckets onto the tableau-compatible
`auto/manual/unhandled` tiers (`a→auto`, `b→manual`, `c→unhandled`) and folds
in calc tables, RLS roles, and unsupported custom visuals.

### DAX-convertibility scoring

Each measure is classified against `research/dax-to-sigma-coverage.md`'s buckets,
using `powerbi-to-sigma/fixtures/MANIFEST.md` as the worked rubric:

- **a — mechanical** (~70% of typical measures): direct Sigma-formula rewrite
  (SUM, COUNTROWS, single-predicate CALCULATE, SAMEPERIODLASTYEAR, DATEADD,
  RELATED/LOOKUPVALUE, SUMX, DIVIDE, IF/SWITCH, DATEDIFF/TODAY/ISBLANK, `&`).
- **b — restructuring**: TOTALYTD/QTD/MTD, RANKX, USERELATIONSHIP, ALL/ALLEXCEPT,
  VALUES, SUMMARIZE/ADDCOLUMNS/CALENDAR, RELATEDTABLE rollups — need a grouped
  element, a parallel join, or a pre-aggregated element.
- **c — no Sigma equivalent**: PATH hierarchies and dynamic context the formula
  language can't express. Rare.

Per-report migration-effort score = `f(DAX bucket mix, visual complexity, calc
tables, RLS)`, surfaced as `cost = 10·unhandled + 3·manual` in the shortlist.

---

## Phase 2 — Usage (Fabric Admin only; optional)

If `probe-admin.rb` exited 0, fire the **Activity Events API** for per-report
views + distinct users and write `usage.json` (shape in
`refs/output-shapes.md`):

```
GET https://api.powerbi.com/v1.0/myorg/admin/activityevents
    ?startDateTime='<UTC-day>T00:00:00.000Z'&endDateTime='<UTC-day>T23:59:59.999Z'
```

Activity Events retains ~28-30 days and is paginated by `continuationUri`. Roll
report-open events up to `{ reportId: { views, users } }`. If admin was
unavailable, **skip this** — `build-shortlist.rb` falls back to a complexity-only
proxy and the readout says so.

---

## Phase 4 — Shortlist

```bash
ruby scripts/build-shortlist.rb --out /tmp/pbi-assessment-<tenant>
```

Cross-tabulates usage with complexity. Scores each report:

- `value = views × √(distinct_users)` *(admin mode)* — or `10 × (pages +
  visuals/4)` *(complexity-only fallback)*
- `cost  = 10·unhandled + 3·manual + 1·hint`
- `score = value / (1 + cost)`

Same tag vocabulary as `tableau-assessment`: `migrate-first` / `easy-win` /
`moderate` / `needs-gap-scout` / `retire`.

---

## Phase 5 — Render the readout

```bash
ruby scripts/render-readout.rb --out /tmp/pbi-assessment-<tenant>
```

Composes the 12-section markdown report (template at
`refs/readout-template.md`). Sections: environment, workspaces, semantic-model
complexity, warehouse sources, refresh, report priority, migration shortlist,
per-report complexity, found-vs-not, privacy, hand-off, next steps.

---

## Phase 6 — Migration plan (always run)

```bash
ruby scripts/migration-plan.rb --out /tmp/pbi-assessment-<tenant>
```

Composes `migration-plan.json` — the hand-off contract for `powerbi-to-sigma`.
Each report gets a `recommended_path`:

| `recommended_path` | Means |
|---|---|
| `powerbi-to-sigma` | Ready for conversion. ≤5 manual/unhandled features. |
| `powerbi-to-sigma-with-scout` | Has no-equivalent DAX / custom visuals — needs a design decision first. |
| `retire` | Zero views (admin mode only); recommend not migrating. |
| `blocked` | >5 manual/unhandled features; needs human rework first. |

**DM clusters** are keyed on the **shared semantic model** — reports off the
same model share a Sigma data model by construction. This is cleaner and more
reliable than Tableau's `.twb`-table Jaccard clustering, because Power BI's model
*is* the semantic layer.

---

## Phase 7 — Hand off to `powerbi-to-sigma`

Present the migration-plan summary and let the user pick the next step (single
report, top-N batch, or just keep the readout). Invoke the converter in the same
conversation:

```
Skill(
  skill: "powerbi-to-sigma",
  args:  "Convert report <id> (<name>) from the just-finished assessment at
          /tmp/pbi-assessment-<tenant>. Read migration-plan.json for the
          recommended_path, blockers, warehouse_sources, and the cluster's
          shared semantic model (dataset_id). The decoded TMSL is in
          raw-tmsl/ and the PBIR in raw-pbir/ — reuse them instead of
          re-extracting."
)
```

The decoded `raw-tmsl/` and `raw-pbir/` are the converter's Phase-0 input — it
should not re-extract.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `NO_TOKEN` exit 2 with `--no-interactive` | Token cache cold | Run any `powerbi-to-sigma` extract once to seed `/tmp/pbiauth/cache.bin`, or drop `--no-interactive` to sign in |
| `CERTIFICATE_VERIFY_FAILED` | Corp TLS inspection | `truststore.inject_into_ssl()` is already the first import — ensure `truststore` is installed in the venv |
| `getDefinition` hangs / times out | 202 LRO not polled | Already handled (polls `Location` up to 30×); a very large model may need a higher poll cap |
| Report `dataset_id` null | Fabric `/reports` omits it; PBI REST token missing or My-workspace report | Acceptable — the report still inventories without model-linked DAX; see `refs/fabric-fields.md` |
| Activity Events / Scanner 403 | Not a Fabric Administrator | Expected; the skill produces a complexity-only shortlist |
| All `dax_buckets` are `a` on a model you know is complex | Model is pure simple-aggregate, OR a function name isn't in the bucket lists | Check `DAX_BUCKET_B/C` in `fabric-inventory.py`; add the function |
