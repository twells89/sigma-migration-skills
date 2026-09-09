# Metabase REST API — extraction surface

Everything this skill needs is on Metabase's first-class REST API — open source and
Pro/EE alike. No private endpoints. Written from the public API docs
(`<host>/api/docs` on any instance ≥ v48) and **validated read-side against a live
production estate (Metabase Cloud v1.61.4, 7,023 cards / 1,548 dashboards)**. The
conversion semantics were subsequently live-validated end to end; the released
wrapped workbook payload is regression-tested and still passes through the
mandatory per-run POST/readback/parity gates. Modern instances return `dataset_query` in
**pMBQL** form and often include a `legacy_query` JSON string — see
`mbql-shapes.md` § pMBQL.

## Auth (two options)

| Method | How | Notes |
|---|---|---|
| **API key** (preferred, v49+) | Admin → Settings → **Authentication → API keys** → create key (group: Administrators for full read). Send header `x-api-key: <key>` | Durable; the right choice for an engagement |
| **Session token** | `POST /api/session {"username": "...", "password": "..."}` → `{"id": "<token>"}`. Send header `X-Metabase-Session: <token>` | Sessions expire (default 14 days, sooner with SSO); on 401 re-login |

`scripts/get-metabase-session.sh` captures either into `MB_BASE` / `MB_KEY` /
`MB_SESSION` env vars. All requests below are plain `GET`s — read-only.

## Endpoints used

| Need | Endpoint | Notes |
|---|---|---|
| Probe / version | `GET /api/session/properties` | `version.tag` — no auth needed for basic properties |
| Databases | `GET /api/database` | `data[]` of `{id, name, engine}` — find the warehouse conn (e.g. `snowflake`) |
| **Schema metadata** | `GET /api/database/{id}/metadata` | tables + **fields with ids** — REQUIRED: MBQL refs fields by integer id; this is the id→column map. Each field: `{id, name, display_name, base_type, semantic_type, fk_target_field_id, table_id}`; each table: `{id, name, schema, fields[]}` |
| Collections (folder tree) | `GET /api/collection` | flat list with `location` path (`/3/7/`); `personal_owner_id` ≠ null = personal space |
| Collection items | `GET /api/collection/{id}/items?models=card&models=dashboard&models=dataset` | paginated (`limit`/`offset`, default 50ish); `data[]` of `{id, model, name}` |
| **Card (question/model) def** | `GET /api/card/{id}` | the full definition incl `dataset_query` (MBQL or native), `display`, `visualization_settings`, `result_metadata` — see `refs/mbql-shapes.md` |
| **All cards (bulk)** | `GET /api/card` | unpaginated — returns EVERY card **with its full definition** in one response (~110MB for 7k cards on the reference estate). Stream to disk, then split locally (`metabase-assessment/scripts/mb-bulk-split.py`). This beats the per-item walk by ~60× on big estates |
| **Single field** | `GET /api/field/{id}` | field-id → `{name, display_name, table_id, base_type}`. The fallback when `/api/database/{id}/metadata` 403s on a scoped key — **worked even for restricted DBs on the reference estate**. Resolution chain: db metadata → card `result_metadata` → `GET /api/field/{id}` → names from the SQL when native |
| **Dashboard def** | `GET /api/dashboard/{id}` | `dashcards[]` with grid geometry + embedded `card` + `parameter_mappings`; top-level `parameters[]`, `tabs[]` |
| Search | `GET /api/search?q=...&models=card` | quick lookup by name |
| Recent views | `GET /api/activity/recents` | thin usage signal (see assessment skill's `usage-telemetry.md`) |

## Version-shape gotchas (handle both)

- **`dashcards` vs `ordered_cards`** — renamed in ~v48. Old shape uses
  `ordered_cards[].sizeX/sizeY`; new uses `dashcards[].size_x/size_y`. The
  converter accepts both.
- **Models**: v50+ marks them `type: "model"` on the card; v46–49 use
  `dataset: true`. Older "metrics"/"segments" (`/api/legacy-metric`,
  `["metric", id]` / `["segment", id]` MBQL refs) still appear in old cards;
  v50+ adds first-class metric cards (`type: "metric"`).
- **Dashboard grid** is **24 columns** wide on current versions (older ~v44-
  exports used 18 — detect by max `col + size_x` if layout looks compressed).
- **Serialization export** (YAML bundles via `/api/ee/serialization/export`) is
  **Pro/EE-only** — do not depend on it; the REST walk above works on OSS.

## Offline mode

Every converter input is a plain JSON file (`card.json`, `dashboard.json`,
`metadata.json`), so the whole pipeline runs against files on disk — a customer
can mail you `GET` outputs without granting access. `scripts/metabase-discover.sh`
writes exactly these files.
