# Metabase REST endpoints used by metabase-assessment

All read-only `GET`s against the first-class public API (`<host>/api/...`) —
works on open source and Pro/EE alike, v46+. Auth is one plain header, either:

| Method | Header | Notes |
|---|---|---|
| **API key** (preferred, v49+) | `x-api-key: $MB_KEY` | Admin → Settings → Authentication → API keys. Durable. A 403 means the key's **group** lacks collection read perms — ask for a key in a group with view access (Administrators for a full scan). |
| **Session token** | `X-Metabase-Session: $MB_SESSION` | From `POST /api/session {"username","password"}`. Expires (14-day default, sooner with SSO) — on 401 re-login and re-run (the walk is resumable). |

## Fast path (default — production-validated, 7k-card estate in ~1 minute)

The per-item collection walk took **>1 hour** on a 7,023-card / 1,548-dashboard
Metabase Cloud estate. The rewritten `discover-metabase.sh` uses bulk endpoints:

| Need | Endpoint | Notes |
|---|---|---|
| Probe / version | `GET /api/session/properties` | `version.tag` — works without auth; tells you whether `view_count` will exist (v50+) |
| Collection tree | `GET /api/collection?archived=false` | flat list; `personal_owner_id != null` (or `is_personal`) = personal space — skipped by default → `<out>/collections.json` |
| **ALL cards (bulk)** | `GET /api/card` | EVERY card **with its full definition** in one response (~110MB for 7k cards) — streamed to disk, split locally by `mb-bulk-split.py split-cards` into `<out>/specs/{id}.card.json` + `databases.txt`. Falls back to the legacy walk if unavailable |
| Dashboard list | `GET /api/dashboard` | shallow list `{id, name, collection_id, archived}` → `<out>/dashboards.list.json` |
| **Dashboard defs (parallel)** | `GET /api/dashboard/{id}` | ~16 concurrent, resumable (on-disk specs skipped), `--max-dashboards N` to cap; `dashcards[]` (⚠ pre-v48: `ordered_cards[]`) + `parameters[]` + `tabs[]` + `view_count` (v50+) → `<out>/specs/{id}.dashboard.json` |
| **Schema metadata** | `GET /api/database/{id}/metadata` | once per referenced database → `<out>/metadata/{id}.metadata.json`. **403 on scoped keys is recorded, not fatal** — fallback chain below |
| Field-id fallback | `GET /api/field/{id}` | when metadata 403s: card `result_metadata` first, then this endpoint (**worked even for restricted DBs on the reference estate**), then names from the SQL when native |
| Sandboxing probe (EE) | `GET /api/mt/gtap` | Pro/EE only — 404 on OSS (silently ignored); non-empty array → `sandboxes.json`, surfaced as needs-review |
| Recent views (thin) | `GET /api/activity/recents` | not used for ranking — see `usage-telemetry.md` |

Legacy walk (`--walk`, or automatic fallback): `GET
/api/collection/{id}/items?models=card&models=dashboard&models=dataset&limit=100&offset=N`
per collection, then per-item GETs — keep for pre-bulk instances only.

Format note: modern instances (Cloud v1.61+) return `dataset_query` in
**pMBQL** (`{"lib/type":"mbql/query","stages":[…]}`); the scorer normalizes via
`pmbql-normalize.mjs` at intake. Sniff the `lib/type` key per card — a list may
mix formats across versions.

## What is NOT available here

- **Per-artifact usage history** (views over time, per-user reach) — `view_count`
  (v50+) is a lifetime counter only; rich audit is the Pro/EE "Usage analytics"
  collection. Pre-v50 OSS has essentially nothing. See `usage-telemetry.md`.
- **Serialization export** (`/api/ee/serialization/export`, YAML bundles) is
  Pro/EE-only — this skill never depends on it; the REST walk above works on OSS.
- **Warehouse data** — this skill never calls `/api/card/{id}/query` or
  `/api/dataset`; definitions only, never results.
