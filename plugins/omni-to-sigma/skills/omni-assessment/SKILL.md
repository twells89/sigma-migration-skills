---
name: omni-assessment
description: Inventory an Omni model directory or instance and produce a migration-readiness readout — topic scores, query-view hazards, and a shortlist. Read-only.
---

# Omni migration assessment (read-only)

Assessments never write to Omni or post to Sigma. Hand the shortlist to
`omni-to-sigma` (one topic, then one dashboard).

## Phase 0 — Connect

Offline: a model directory is enough. Live (optional): `OMNI_BASE_URL` and
`OMNI_API_TOKEN`. Personal tokens see only what that user can see.

## Phase 1 — Inventory

```bash
ruby scripts/omni-inventory.rb --model-dir <dir> --out inventory.json
```

Optional `--documents documents.json` (a `GET /api/v1/documents` payload) to
count dashboards without calling the API. Dedup document names with
`scripts/dup-dashboards.py` when the payload is large.

Live listing runs only when both Omni env vars are set and `--documents` was
not passed. It records `live.error` and still writes the file.

## Phase 2 — Score + shortlist

`complexity` is views + 2×topics + 3×query views + documents. `shortlist` is
topics sorted by measure count plus join count. Query views are hazards, not
v0 convert targets. Pick the top topic, then convert with `omni-to-sigma`.
