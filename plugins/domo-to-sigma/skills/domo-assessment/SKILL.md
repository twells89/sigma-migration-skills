---
name: domo-assessment
description: >-
  Inventory a Domo instance via its public Governance/DomoStats system datasets
  (and, when reachable, the private card-definition API) to produce a
  value/cost-ranked migration-readiness readout — environment counts, Beast
  Mode complexity, PDP/DataFlow structural flags, usage-driven value, and a
  migration shortlist + plan. Use to scope a Domo→Sigma migration or audit BI
  sprawl. Read-only; never posts to Sigma; hands off to `domo-to-sigma`.
user-invocable: true
---

# Domo Assessment

> **STATUS: offline-complete (hermetic fixture pipeline, both governance
> tiers); live not yet validated.** The four pipeline scripts run end-to-end
> against committed Tier A / Tier B fixtures (`bash run-offline.sh`) and the
> repo test suite. What remains live: confirming the exact governance-dataset
> names/column schemas on first contact with a real Domo instance (see
> "Open work" below) — this skill defers that, consistent with this repo's
> rule of never calling something validated until it's proven live.

**Read first:**
- `refs/governance-datasets.md` — which Governance/DomoStats system datasets
  power which section, the SQL query pattern, and the offline fixture filenames
- `refs/complexity-scoring.md` — the Domo convertibility rubric (Beast Mode
  bucketing + card-type coverage + structural flags)
- `refs/output-shapes.md` — exact JSON shapes each stage reads/writes
- `refs/readout-template.md` — the `readout.md` section layout
- `../domo-to-sigma/SKILL.md` — the conversion skill this feeds into; auth recipe

## The key idea
Domo's admin-installable **DomoStats** and **Governance Datasets** connectors
materialize the instance's own metadata (DataSets, DataFlows, Pages, Cards,
Users, PDP policies, Activity Log) as ordinary DataSets — queryable via the
**public**, documented `POST /v1/datasets/query/execute/{id}` endpoint with
plain MySQL SQL. That's Domo's analog of Tableau Admin Insights: no
private-API scraping is required just to build an inventory. Card-level Beast
Mode SQL text (the real complexity signal) is only visible either through a
`DOMO_DEV_TOKEN` against the private card-definition API, or — on instances
where it's installed — through a public `Beast Modes` governance dataset.
Whichever is reachable determines the assessment's **tier**:

- **Tier A** — Beast Mode SQL is visible. Every card's Beast Modes are
  bucketed auto/manual/unhandled (same `convert_sql_to_sigma_formula` coverage
  rules `domo-to-sigma` uses) and folded into cost/score.
- **Tier B** — public API only. Beast Mode buckets are forced to zero; cost/
  score are driven by structural flags (PDP, DataFlow-sourced) and usage only.
  The shortlist is directional, not precise (see `refs/complexity-scoring.md` §4).

Score/tag math is identical on both tiers (spec-fixed, not tool-tunable) and
matches the vocabulary of the other `*-assessment` skills: `cost = 10·unhandled
+ 3·manual + 1·hint`, `value` = usage-driven when an Activity Log dataset is
installed else a Beast-Mode-count proxy, `score = value / (1 + cost)`, tagged
`migrate-first` / `easy-win` / `moderate` / `needs-gap-scout` / `retire`.

**Read-only.** Every live call is a `GET` or a `POST .../query/execute` SELECT
against a Domo-owned system dataset. Nothing in Domo is created, edited, or
deleted. **No Sigma credentials are used or required anywhere in this skill**
— the assessment never authenticates to Sigma and never posts anything to it;
every artifact is local JSON/Markdown until a human shares it deliberately.

## When to use / Not for
Use this to scope a Domo→Sigma migration, prioritize which cards/pages to
convert first, or audit Domo sprawl (duplicate dashboards, dead content,
who's-using-what). **Not for** running the actual conversion (that's
`domo-to-sigma`), auditing PDP/sharing ACLs in depth (counts only — see "Open
work"), or a hands-on effort estimate (the scoring is a directional heuristic,
not a quote — see `refs/complexity-scoring.md`).

## Modes
- **Live REST** — the public `api.domo.com` OAuth API, plus (Tier A only) the
  private developer-token card API. Auth prereqs (see
  `../domo-to-sigma/refs/connection.md`):
  ```bash
  export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=... DOMO_INSTANCE=<instance>
  export DOMO_DEV_TOKEN=...        # omit for Tier B
  eval "$(../domo-to-sigma/scripts/get-domo-token.sh)"
  ```
- **Offline fixtures** — `--from-fixtures fixtures/tier-a` or
  `fixtures/tier-b`. No auth, no network, no Sigma credentials. This is how the
  skill's own test suite and `run-offline.sh` validate the pipeline.

Every pipeline script accepts `--from-fixtures DIR` to switch modes; omit it
to run live.

## Phases
0. **Probe** — `ruby scripts/probe-governance.rb --out <dir>` (live) or
   `--from-fixtures fixtures/<tier> --out <dir>` (offline). **This is the
   real preflight for this assessment** — it is what decides Tier A vs Tier B
   and whether audit (Activity Log) scope is available, and writes
   `probe.json` with its reasoning. It is not `doctor.sh`/`bootstrap.sh` (see
   "Scripts" below for why those exist but aren't part of this flow).
1. **Discover** — `ruby scripts/discover-domo.rb --out <dir>` (live) or
   `--from-fixtures fixtures/<tier> --out <dir>` (offline). Reads the
   governance tables (each stage re-resolves them itself rather than trusting
   `probe.json`'s handles — see the script's header) and writes
   `inventory.json` (datasets/pages/cards/users, with per-card PDP/DataFlow
   flags and, Tier A only, parsed Beast Mode refs) + `usage.json` (per-card
   views/distinct-viewers, only when an Activity Log table was reachable).
2. **Score — the differentiator** — `ruby scripts/score-coverage.rb --in <dir>
   --out <dir>`. Scores every card into value/cost/score/tag per
   `refs/complexity-scoring.md`, clusters cards by shared dataset, rolls pages
   up to a recommended path, and best-effort shells out to
   `scripts/dup-dashboards.py` for duplicate/consolidation detection. Writes
   `complexity.json`, `shortlist.json`, `migration-plan.json`.
3. **Render** — `ruby scripts/render-readout.rb --in <dir> --out <dir>`.
   Turns the JSON artifacts into `readout.md` (plain Markdown, no HTML) per
   `refs/readout-template.md`.
4. **Hand off** — to `domo-to-sigma`, passing `migration-plan.json` (ask the
   user which cards/pages to migrate first — `shortlist.json` is the ranked
   order).

## How to run
```bash
# offline, one command, both tiers — the pipeline's own green-bar check
bash run-offline.sh

# live, one directory, all four stages
OUT=/tmp/domo-assessment-<instance>
ruby scripts/probe-governance.rb   --out "$OUT"
ruby scripts/discover-domo.rb      --out "$OUT"
ruby scripts/score-coverage.rb     --in  "$OUT" --out "$OUT"
ruby scripts/render-readout.rb     --in  "$OUT" --out "$OUT"
```
`--in`/`--out` may be the same directory (as shown) — that's how the pipeline
is meant to run. Offline, point every stage's fixture flag at the same tier
directory, e.g. `--from-fixtures fixtures/tier-a`.

## Scripts
| Script | Phase | Purpose |
|---|---|---|
| `scripts/probe-governance.rb` | 0 | Preflight: detect Tier A/B + audit scope; writes `probe.json`. |
| `scripts/discover-domo.rb` | 1 | Enumerate datasets/pages/cards/users from the governance tables; writes `inventory.json` + `usage.json`. |
| `scripts/score-coverage.rb` | 2 | Score every card (value/cost/score/tag), cluster + page rollup; shells `dup-dashboards.py`; writes `complexity.json`/`shortlist.json`/`migration-plan.json`. |
| `scripts/render-readout.rb` | 3 | Render `readout.md` from the JSON artifacts. |
| `scripts/dup-dashboards.py` | 2 (called by score-coverage.rb) | Tool-neutral duplicate/consolidation detector, shared across the `*-assessment` family. Best-effort — a failure here never fails the run. |
| `scripts/doctor.sh` / `scripts/doctor.ps1` | — | **Not part of this assessment's flow.** Vendored from the `*-to-sigma` skill family for cross-skill consistency and to serve a future Sigma hand-off; they check for **Sigma credentials**, which this read-only assessment never needs. This assessment's real preflight is `probe-governance.rb`. |
| `scripts/bootstrap.sh` / `scripts/bootstrap.ps1` | — | Same note as `doctor.sh` — vendored, not part of this flow, requires Sigma creds. |

## Refs
| Ref | Covers |
|---|---|
| `refs/governance-datasets.md` | Which Governance/DomoStats dataset powers which readout section, the `SELECT ... FROM table` query pattern, offline fixture filenames, and degradation rules. |
| `refs/complexity-scoring.md` | The full scoring rubric: Beast Mode bucket regexes, card-type coverage (future refinement), structural-flag rules, and Tier A/B degradation. |
| `refs/output-shapes.md` | Exact JSON shape of every file each stage reads/writes (`probe.json` through `migration-plan.json`) and `readout.md`'s section list. |
| `refs/readout-template.md` | The `{{placeholder}}` / `{{#key}}...{{/key}}` template `render-readout.rb` fills in. |

## Deliverables (in `<out>/`)
- `probe.json` — tier decision (A/B), audit-scope flag, which governance
  datasets were reachable, and the reasoning trace.
- `inventory.json` — datasets/pages/cards/users, with per-card PDP/DataFlow
  structural flags and (Tier A) parsed Beast Mode refs; shape-suspect warnings
  when a governance table's schema doesn't match expectations.
- `usage.json` — per-card views/distinct-viewers (only written when an
  Activity Log governance table was reachable).
- `complexity.json` — every card scored: `n_auto`/`n_hint`/`n_manual`/
  `n_unhandled`, `value`/`cost`/`score`, `tag`, plus a rollup (`by_tag`,
  `totals`, `pct_auto`).
- `shortlist.json` — the same artifacts, re-sorted for migration order
  (`migrate-first`/`easy-win` first, then score descending).
- `migration-plan.json` — dataset clusters, per-page recommended path
  (`convert`/`gap-scout`/`retire`), and duplicate/consolidation groups. The
  hand-off contract to `domo-to-sigma`.
- `readout.md` — the human-readable summary (Markdown only, no HTML).

Nothing in this directory is uploaded anywhere — sharing is a deliberate action.

## Live validation
**Not yet done.** The pipeline is validated hermetically against the
committed fixtures (`fixtures/tier-a`, `fixtures/tier-b`) via `run-offline.sh`
and the `test/` suite — both tiers produce all expected tags (`retire`,
`needs-gap-scout`, etc.) and the correct `tier` value. **The live
governance-dataset field-path check against a real Domo instance is
DEFERRED and NOT validated** — dataset names are believed stable but the
column schemas in `refs/governance-datasets.md` are reconstructed from
docs/community and must be confirmed on first live contact (query
`GET /v1/datasets/{id}` to read the real schema before trusting the inventory
SQL). Do not represent this skill as live-parity-proven until that check runs
against a real instance.

## Hand off to domo-to-sigma
After the readout, present the user the shortlist (which cards/pages to
migrate first) and invoke `domo-to-sigma` with `migration-plan.json`'s
clusters (cards sharing a dataset migrate together onto one Sigma data
model) and each page's `recommended_path`.

## Open work
- **Live field-path confirmation** (see "Live validation" above) — the
  single biggest open item before this skill can be called live-validated.
- **Card-type coverage histogram** — recorded per-card (`inventory.json`
  `cards[].type`) but not yet folded into cost; `refs/complexity-scoring.md`
  §2 documents the intended auto/manual/unhandled card-type buckets for a
  future pass.
- **Card-level filter/drill-path/link and DDX-brick flags** are Tier-A-only
  signals sourced from the private card-definition API
  (`fixtures/tier-a/card-defs.json` models the shape) but `discover-domo.rb`
  doesn't parse them yet — not folded into `n_manual`/`n_unhandled` in v1.
- **DataFlow transform depth** is flagged `unhandled` (a DataFlow-sourced
  dataset adds +1 unhandled) but not measured — depth/complexity of the
  DataFlow itself is out of scope for v1.
- **Folder/group ACL audit** (who can see what) is out of scope — counts only.
- **Groups** has no offline fixture yet (`fixtures/*/groups.json` doesn't
  exist) — a missing table degrades exactly like an uninstalled connector
  would live, so this doesn't block a run, but group counts aren't currently
  exercised offline.
