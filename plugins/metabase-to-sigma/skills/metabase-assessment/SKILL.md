---
name: metabase-assessment
description: Take inventory of a Metabase instance and produce a migration-readiness readout — collection-tree counts, per-artifact conversion complexity (scored against the Metabase→Sigma converter's exact coverage), an estate-wide auto-migration percentage, a named gap analysis, and an effort/wave plan. Use when a user wants to scope a Metabase→Sigma migration, audit Metabase sprawl, or pick which models / questions / dashboards to convert first. Read-only, all-free, ~Tableau-assessment-style pre-scoping that complements (does not replace) a deeper paid engagement.
user-invocable: true
---

# Metabase Assessment

Surveys a Metabase instance (open source or Pro/EE, v46+) via its first-class
REST API (`/api`) and produces a branded, share-friendly HTML readout plus a
JSON inventory. The differentiator versus a generic BI audit is
**converter-coverage scoring**: every model, question (card), and dashboard is
classified auto-convert vs. flagged using the *same* rules the
`metabase-to-sigma` converter (`converter/metabase.ts`, `translateMbqlExpr`)
actually applies — so the readout's auto-migration % reflects what the tool
will really do, not a hand-wave.

> **Read-only.** This skill only issues `GET`s against the Metabase API. It
> never POSTs, modifies, runs, or schedules anything in Metabase — and it never
> touches Sigma. It can also run fully offline against card/dashboard JSON
> files already on disk.

> **All free.** Everything here — inventory, scoring, the HTML readout — is part
> of the open migration tooling. There is no paid tier to upsell. For a deeper
> hands-on engagement (permissions audit, sandboxing/RLS port, live parity
> testing), point the customer at a Sigma SE.

> **Tableau is the reference point.** This skill mirrors the structure and tone
> of the `tableau-assessment` skill (environment counts → coverage → effort →
> readout). If you've run that, this will feel familiar; the Metabase-specific
> work is all in the coverage scorer.

---

## Privacy posture (READ FIRST, surface to the customer)

**This skill reads content metadata and definitions, not warehouse data.**

| Crosses the LLM API | Stays in Metabase / local |
|---|---|
| Aggregate counts (model / question / dashboard / collection counts) | Warehouse rows (this skill never runs a query) |
| Object names, collection path, type, `view_count` (v50+) | Database credentials (Metabase never exposes them via these endpoints anyway) |
| Card JSON (MBQL trees, **native SQL text**, expressions, viz settings) | The customer's actual query *results* |
| Dashboard JSON (grid layout, parameters, click behaviors) | User PII beyond creator ids on objects |
| Database **schema** metadata (table/field names + ids — required to resolve MBQL field refs) | — |

When an agent reads these artifacts, their contents enter that agent provider's
model context. Tell the user this before running. Outputs are written to a local
`/tmp/metabase-assessment-<env>/` directory and uploaded nowhere — sharing is a
deliberate action, not automatic. See `PRIVACY.md` for the full disclosure.

---

## When to use this skill

- A Metabase customer wants a fast scoping view before committing to a migration.
- A Sigma SE preparing for a discovery call wants a pre-built conversion shortlist.
- A customer is deciding which Metabase questions/dashboards to retire vs. migrate.
- A `metabase-to-sigma` conversion needs a Phase 0 inventory of the source estate.

**Not for**: running live Metabase questions, extracting warehouse data, or
making any change to the Metabase instance.

---

## Modes

| Mode | Setup | Use when |
|---|---|---|
| **Live (REST)** | `MB_BASE` + (`MB_KEY` or `MB_SESSION`) env (see below) | Real estate scan against a running Metabase (OSS or Pro/EE) |
| **Offline (files)** | A directory of `*.card.json` + `*.dashboard.json` already on disk | No live access; scoring a sample set or an export the customer mailed you |

Both modes feed the same scorer + renderer. The bundled `fixtures/` let you
validate the whole pipeline offline.

---

## Phase 0 — Connect / probe access

Live mode needs one of two auth shapes (both are plain request headers):

```bash
export MB_BASE="https://<host>"            # no trailing /api — the script adds it

# Option A (preferred, v49+): an API key from Admin → Settings → Authentication → API keys
export MB_KEY="mb_..."                     # sent as `x-api-key`

# Option B: a session token from POST /api/session {"username","password"}
export MB_SESSION="<token>"                # sent as `X-Metabase-Session`

# Cheap probe — prints the instance version, no auth strictly required:
bash scripts/discover-metabase.sh --probe
```

If an authenticated request 401s, the session expired (sessions default to 14
days, sooner with SSO) — re-login and re-export `MB_SESSION`, or switch to an
API key. If an API-key request 403s, the key's **group** lacks read access to
the collections — ask the admin for a key in a group with view rights
(Administrators for a full scan). The discovery script surfaces a clear
token-expiry note rather than dumping a stack trace.

Offline mode needs no auth — skip straight to Phase 2 pointing the scorer at
the file directory.

---

## Phase 1 — Discover the estate (live mode)

```bash
bash scripts/discover-metabase.sh --out /tmp/metabase-assessment-<env>
# include per-user personal collections too (skipped by default):
bash scripts/discover-metabase.sh --out /tmp/metabase-assessment-<env> --include-personal
# useful caps / knobs: --concurrency 16  --max-dashboards N  --skip-cards  --walk
```

`discover-metabase.sh` uses the **bulk fast path** (production-validated: a
7,023-card / 1,548-dashboard Metabase Cloud estate in ~1 minute — the old
per-item walk took >1 hour on the same estate):

1. `GET /api/collection` → collection names + personal flags
2. **`GET /api/card`** — EVERY card with its full definition in ONE response
   (~110MB for 7k cards), streamed to disk and split locally by
   `scripts/mb-bulk-split.py` → `<out>/specs/<id>.card.json`
3. `GET /api/dashboard` (shallow list) + **parallel** `GET /api/dashboard/{id}`
   (default 16 concurrent, resumable) → `<out>/specs/<id>.dashboard.json`
4. each **referenced database**, once → `GET /api/database/{id}/metadata`
   → `<out>/metadata/<db>.metadata.json` (the integer-field-id → column map the
   converter requires). A **403 on a scoped key is recorded, not fatal** —
   field resolution falls back to card `result_metadata`, then
   `GET /api/field/{id}` (works even for restricted DBs).

It emits `<out>/inventory.json` =
`{ environment: {...counts}, artifacts: [ {id,type,name,collection,view_count,specFile} ] }`.

Notes baked into the script:
- **Fallback walk** — `--walk` (or automatically when bulk `GET /api/card`
  isn't available) uses the old paginated per-collection item walk; default
  page size 100.
- **Personal collections** — skipped by default (`personal_owner_id != null`);
  `--include-personal` overrides. Personal sandboxes are usually retire-not-
  migrate content and they dominate raw counts.
- **Token expiry** — on a 401 it writes a `token_expired: true` flag into
  `inventory.json` and stops gracefully so you can re-auth and re-run (already
  fetched specs on disk are skipped — resumable).
- **`view_count`** — recorded when the instance exposes it on card/dashboard
  responses (**v50+**). Pre-v50 OSS exposes essentially no usage data via REST
  (see `refs/usage-telemetry.md`); treat usage as a known gap and request the
  Pro/EE Usage analytics export from the admin.
- **Sandboxing (EE)** — probes `GET /api/mt/gtap` once; on Pro/EE with
  sandboxes defined it saves `sandboxes.json` (surfaced as a needs-review
  item); on OSS the 404 is silently ignored.

---

## Phase 2 — Score converter coverage (THE differentiator)

```bash
node scripts/score-coverage.mjs --in /tmp/metabase-assessment-<env>/specs --out /tmp/metabase-assessment-<env>
# offline against the bundled fixtures:
node scripts/score-coverage.mjs --in fixtures --out /tmp/metabase-assessment-<env>
```

For every `*.card.json` and `*.dashboard.json`, the scorer classifies features
into four buckets — **auto / hint / manual / unhandled** — by detecting the
*exact* gap signals the converter flags. It does NOT re-implement the
converter; MBQL is plain JSON, so it recurses the `dataset_query` trees and
matches op names against `translateMbqlExpr`'s translated-vs-flagged tables
(`refs/expression-dsl.md` in the sibling converter skill). Each detected gap is
recorded with a count **and** the specific reason + remediation.

### Card signals (mirror `metabase.ts` / `expression-dsl.md`)

| Bucket | Signal | Why |
|---|---|---|
| `auto` | MBQL table source, breakouts, translated aggregations (`count/sum/avg/min/max/median/distinct/stddev/var/percentile/count-where/sum-where/share`), translated expression & filter ops (arithmetic, `case`, `coalesce`, string fns, date fns, casts, `in`/`not-in`, comparison/`between`/`time-interval`…); native-SQL cards (→ DM `sql` element) with plain `text`/`number`/`date`/`boolean` template tags (same `{{}}` syntax in Sigma); single-rule conditional formatting; displays `table/bar/row/line/area/combo/scatter/pie/scalar/smartscalar/pivot/map/funnel/gauge/waterfall/sankey` | translated cleanly by the converter (pMBQL is normalized at intake) |
| `hint` | nested-card source (`source-table: "card__N"`); `dimension`-type **field-filter** template tags; `{{#card}}` tags; optional `[[…]]` SQL blocks; explicit MBQL `joins` | convert fine, but review (source ordering, control wiring, join fan-out) |
| `manual` | `binning` opts on a breakout (numeric histogram); `["segment", id]` / legacy `["metric", id]` refs (definitions live in other objects — inline needed); `click_behavior`; `snippet` template tags; gradient/range conditional formatting; `object` detail views; multi-stage queries | converter passes through + warns; brief re-creation in Sigma |
| `unhandled` | `cum-sum` / `cum-count` / `offset` aggregations (window scope lives on the consuming element); `progress` display; sandboxing policies (EE); any unmapped MBQL op | converter emits a flagged placeholder + loud warning |

### Dashboard signals

| Bucket | Signal | Why |
|---|---|---|
| `auto` | dashcards whose card `display` is supported (24-col grid maps 1:1 to Sigma); text/heading virtual cards (markdown passes through); `parameters` → Sigma controls; `tabs` → workbook pages | converter emits clean elements |
| `manual` | `click_behavior` on a dashcard (cross-filter / drill link) | re-implement as a Sigma action |
| `unhandled` | dashcards whose card `display` is `progress` | data preserved as a flagged table; choose an approved replacement |

### Output

`<out>/coverage.json` — per artifact:
`{ id, type, name, n_features, n_auto, n_hint, n_manual, n_unhandled, complexity, gaps:[{signal,count,bucket,reason,remediation}], view_count, uses_cards, value, cost, score, tag }`
plus an estate roll-up: `{ pct_auto_migratable, gap_histogram, by_complexity, by_tag, totals, usage_available }`.

Scoring (same framework as every `*-assessment` skill):
`cost = 10·n_unhandled + 3·n_manual + 1·n_hint`;
`value = 10 × view_count` when the instance exposes `view_count` on
cards/dashboards (v50+), else `10 × n_features` (proxy — see usage-telemetry ref);
`score = value / (1 + cost)`.
Complexity: `n_unhandled>0 → high`; else `n_manual>0 → medium`; else `low`.
Tags: `n_unhandled≥1 → needs-review`; `(manual+unhandled)==0 → migrate-first`;
`score≥10 → easy-win`; else `moderate`.

---

## Phase 3 — Effort / wave plan

The scorer's roll-up feeds a simple wave plan (computed in `render-report.mjs`):

- **Wave 1 — migrate-first / easy-win.** Low-complexity models + questions +
  dashboards, no unhandled features. These are the pilot.
- **Wave 2 — moderate.** Medium complexity (manual setup, no unhandled) —
  convert with light review.
- **Wave 3 — needs-review.** Any artifact with an unhandled feature: a
  cumulative/offset calc, a progress viz, a sandboxing
  policy. Each needs a human decision before conversion.

**Models migrate before the dashboards (and questions) that use them** — a
question sourced from `card__N` and a dashboard's dashcards both point at the
migrated model's DM element. The dependency is detectable from each card's
`dataset_query.source-table` (`card__N` refs) and each dashboard's dashcard
`card_id`s; the scorer records it as `uses_cards` and the renderer sequences
models ahead of dependents within each wave.

---

## Phase 4 — Render the HTML readout

```bash
node scripts/render-report.mjs --out /tmp/metabase-assessment-<env>
# → writes /tmp/metabase-assessment-<env>/readout.html
```

Reads `inventory.json` (if present) + `coverage.json` and emits a standalone,
brand-styled `readout.html` (~6 sections, Sigma palette, print-friendly):

1. **Executive summary** — estate size, auto-migration %, headline finding.
2. **Estate inventory** — counts by type, artifact table (with views when v50+).
3. **Coverage & auto-migration** — auto/hint/manual/unhandled breakdown, % auto.
4. **Gap analysis** — named artifacts + the specific gap + why + remediation.
5. **Effort / wave plan** — the 3 waves, models sequenced before dependents.
6. **Next steps** — pilot recommendation, what to request from the admin.

All-free framing throughout; no paid upsell.

---

## Phase 5 — Hand off (optional)

After the readout, you can hand the shortlist to the `metabase-to-sigma`
converter skill for the migrate-first artifacts. The coverage JSON's
per-artifact `specFile` points the converter straight at the card/dashboard
JSON it already fetched — and `metadata/<db>.metadata.json` is exactly the
`--metadata` file the converter requires for field-id resolution. No
re-discovery.

> Do not auto-convert. Surface the shortlist and let the user choose.

---

## Scripts overview

| Script | Purpose |
|---|---|
| `scripts/discover-metabase.sh` | Bulk fast path: `GET /api/card` (all definitions in one response, split locally) + `GET /api/dashboard` list + parallel per-dashboard GETs + per-database schema metadata, emit `inventory.json`. Production-validated: 7k-card estate in ~1 minute. Auth via `MB_KEY` (x-api-key) or `MB_SESSION`. Read-only, resumable, token-expiry aware, skips personal collections by default; `--walk` = legacy per-collection walk. |
| `scripts/mb-bulk-split.py` | Local companion (stdlib-only): splits the bulk card payload into per-card specs, builds artifact records + `databases.txt`, filters dashboard fetch lists (resumable). Never talks to the network. |
| `scripts/pmbql-normalize.mjs` | pMBQL ("lib/" MBQL) → legacy MBQL normalizer (byte-identical copy of the converter's — the converter test suite guards the sync). |
| `scripts/score-coverage.mjs` | Classify every card/dashboard auto/hint/manual/unhandled against the converter's exact gap signals by walking the (normalized) MBQL JSON trees; per-artifact complexity + estate roll-up. Production-validated on 8,571 artifacts. |
| `scripts/render-report.mjs` | Emit the branded standalone `readout.html`. Zero-dependency. |

## Refs

| Ref | Contents |
|---|---|
| `refs/mb-rest.md` | The Metabase REST endpoints this skill uses + the two auth shapes. |
| `refs/scoring-rubric.md` | Every gap signal, what it means, which bucket, and the remediation text shown in the readout. |
| `refs/usage-telemetry.md` | Honest investigation of Metabase usage stats: `view_count` (v50+) and `/api/activity/recents` are thin; rich audit is Pro/EE "Usage analytics"; pre-v50 OSS has essentially nothing. |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `discover-metabase.sh --probe` fails | `MB_BASE` wrong / instance unreachable | Probe hits `GET /api/session/properties` — verify the base URL (no trailing `/api`) |
| Authenticated requests 401 | `MB_SESSION` expired (14-day default, sooner with SSO) | Re-login (`POST /api/session`) and re-export, or switch to an API key (`MB_KEY`) |
| API-key requests 403 | The key's **group** lacks collection read permissions | Ask the admin for a key in a group with view access (Administrators for a full scan) |
| `inventory.json` has `token_expired: true` | Auth died mid-walk | Re-auth, re-run — on-disk specs are skipped (resumable) |
| `score-coverage.mjs` finds 0 artifacts | `--in` points at the wrong dir | Point at the `specs/` dir (live) or `fixtures/` (offline) |
| Dashboard scores 0 dashcards | Pre-v48 instance returns `ordered_cards` (with `sizeX/sizeY`), not `dashcards` | The scorer handles both shapes — if counts still look wrong, check the raw JSON for a third variant |
| `view_count` all blank / value falls back to feature counts | Instance is pre-v50 (OSS exposes no view counts before that) | Expected — see `refs/usage-telemetry.md`; request the Pro/EE Usage analytics export from the admin |
| Personal-collection content missing from the inventory | Skipped by default | Re-run with `--include-personal` |
