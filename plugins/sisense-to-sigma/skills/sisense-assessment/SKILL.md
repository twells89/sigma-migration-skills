---
name: sisense-assessment
description: >-
  Take inventory of a Sisense estate and produce a migration-readiness readout —
  ElastiCube/Live model counts, dashboard counts, a widget-type histogram, JAQL
  complexity, dataset/connection mix, and per-dashboard AUTO / HINT / MANUAL /
  UNHANDLED tags scored against the sisense-to-sigma converter's actual
  coverage. Use when a user wants to scope a Sisense→Sigma migration, audit BI
  sprawl, or pick which dashboards to convert first. Read-only, all-free
  pre-scoping over the Sisense REST API.
user-invocable: true
---

# Sisense Assessment

Surveys a Sisense estate over REST and produces a JSON inventory + markdown
readout. The differentiator versus a generic BI audit is **converter-coverage
classification**: every dashboard is scored against the *same* coverage the
`sisense-to-sigma` converter actually applies
(`../sisense-to-sigma/refs/widget-type-mapping.md`), so the readout reflects
what the tool will really do.

> **Read-only.** Lists models, dashboards, and widget metadata. It never writes
> to Sisense and never touches Sigma. See `PRIVACY.md` and surface it to the
> customer before running.

> **All free.** Inventory, scoring, readout — part of the open migration
> tooling. For a deeper engagement (security audit, live parity testing), point
> the customer at a Sigma SE.

> **Status:** scaffold. Discovery (shared with the converter) is live; the
> scoring/readout in `scripts/assess.py` is not built yet.

## Phase 0 — Connect
`eval "$(../sisense-to-sigma/scripts/sisense-auth.sh)"` — bearer token or
email+password (see `../sisense-to-sigma/refs/sisense-rest-api.md`).

## Phase 1 — Inventory + score
```sh
python3 scripts/assess.py --out ~/sisense-migration
```
Reuses the converter's `discover.py` bundle, then emits:
- `assessment.json` — counts, widget-type histogram, JAQL-complexity buckets,
  per-dashboard coverage tag (AUTO / HINT / MANUAL / UNHANDLED).
- `assessment.md` — ranked migration shortlist (value vs. effort).
