---
name: looker-assessment
description: >-
  Take inventory of a Looker instance and produce a migration-readiness readout —
  model / explore / project / connection (dialect) / Look / dashboard (UDD vs
  LookML) / user / group / folder counts, per-dashboard complexity (vis-type mix,
  pivots, table calcs, merged results, custom viz, Liquid, filters), usage from
  Looker's System Activity model, and a value/cost-ranked migration shortlist. Use
  to scope a Looker→Sigma migration or audit BI sprawl. Looker REST API 4.0 driven
  (read-only); hands off to looker-to-sigma.
user-invocable: true
---

# Looker Assessment

> **STATUS: working inventory (Looker REST API 4.0 driven, live-validated on
> `example.cloud.looker.com`).** Mirrors `tableau-assessment` / `qlik-assessment`:
> same `value / (1 + cost)` scoring, same
> `migrate-first / easy-win / moderate / needs-gap-scout / retire` tags, and the
> byte-identical Sigma-branded HTML readout theme.

**Read first:**
- `refs/complexity-scoring.md` — the Looker convertibility rubric (vis-type + feature buckets)
- `refs/output-shapes.md` — exact `inventory.json` shape the renderer consumes
- `../looker-to-sigma/SKILL.md` — the conversion skill this feeds into; auth recipe
- `PRIVACY.md` — read-only posture

## The key idea
The same translation rules that drive `convert_lookml_to_sigma` + the dashboard
builder (`../looker-to-sigma/scripts/build_workbook.py`) also **predict migration
effort**: bucket each dashboard tile's vis-type and hard-to-migrate features
against Sigma's coverage. Pivots / table calcs / Liquid → `manual` (a brief
post-conversion step in Sigma); merged results / marketplace-or-custom viz →
`unhandled` (no direct Sigma equivalent — review). Usage (the value axis) comes
from Looker's own **System Activity** model, which Looker exposes well (unlike most
BI tools where usage telemetry is the weak spot).

**Read-only.** Only `GET`s and System Activity inline queries
(`POST /queries/run/json` against `model: system__activity`). No object is created,
edited, or deleted; no warehouse content query is ever run.

**UDD and LookML dashboards convert through the same path.** `GET /dashboards/{id}`
returns user-defined (UI-built) and LookML dashboards as the same JSON shape, so the
assessment treats them identically and just records the `kind` for reporting. UDD is
the primary path.

## Auth & environment
Looker API3 credentials in `~/.looker/looker.ini`:

```ini
[Looker]
base_url=https://<host>.cloud.looker.com
client_id=...
client_secret=...
verify_ssl=true
```

**No port needed.** Modern Google-hosted Looker serves the API on the standard **443** at
`https://<host>.cloud.looker.com/api/4.0`. Older self-hosted instances used the legacy
`:19999`; if your `base_url` still carries it and that port is unreachable the client
**self-heals** — it retries on 443 and warns you to update the ini. Override the base without
editing the ini via `LOOKER_BASE_URL`. `scripts/looker_api.py` (copied in for
self-containment, byte-identical to the converter's copy) reads the ini and **caches the
bearer per process** — one login per run, not one per call — re-logging in once on a 401.
Confirm access with `python3 scripts/looker_api.py whoami`. Most counts need only a normal
role; the **System Activity** queries need a role with permission to the
`system__activity` model (admin or a role granted `see_system_activity`) — if that
permission is missing, usage falls back to 0 and dashboards score on a tile-count
proxy. Point at a different ini with `--ini PATH`.

## Phases
0. **Probe** — `python3 scripts/looker_api.py whoami` confirms auth + role. A System
   Activity test query confirms usage access (the inventory script degrades
   gracefully to proxy scoring if it's denied).
1. **Environment counts** — `GET /lookml_models` (+ explores rolled up),
   `/projects`, `/connections` (dialects), `/looks`, `/dashboards`, `/folders`,
   `/groups`, `/users`. Dashboards split UDD vs LookML by id shape (`model::name`
   = LookML).
2. **Usage (System Activity)** — `POST /queries/run/json` on `system__activity`:
   the `history` explore grouped by `dashboard.id`/`look.id` for run counts over the
   last N days, and a totals query for `user.count` (active users) + query/dashboard
   run volume. See `refs/complexity-scoring.md` for the exact field list.
3. **Per-dashboard complexity** — `GET /dashboards/{id}` per dashboard; bucket each
   tile's vis-type and detect pivots (`query.pivots`), table calcs
   (`query.dynamic_fields`, a JSON string), merged results (`merge_result_id`),
   custom/marketplace viz (vis type outside the known set), and Liquid (`{{ }}` /
   `{% %}` in the query). Count filters.
4. **Shortlist** — `cost = 10·unhandled + 3·manual + 1·hint`;
   `value = dashboard_runs × √query_runs` (tile-count proxy when cold);
   `score = value / (1 + cost)`; tag.
5. **Readout** — `looker-inventory.py` writes `inventory.json` + `readout.md`; then
   `render-readout-html.rb --out <dir>` renders the customer-facing, Sigma-branded
   `readout.html` (same theme as `tableau-assessment` / `qlik-assessment`).
6. **Hand off** — to `looker-to-sigma` (ask the user which dashboards first).

## How to run
```bash
# one pass: counts + System Activity usage + per-dashboard complexity + shortlist
python3 scripts/looker-inventory.py --out /tmp/assessment-<host> --usage-days 90
ruby   scripts/render-readout-html.rb --out /tmp/assessment-<host>
```

Flags:
- `--out DIR` — output dir (default `assessment-<host>`).
- `--usage-days N` — System Activity window (default 90); surfaced in the readout.
- `--no-deep` — skip the per-dashboard `GET /dashboards/{id}` scan (counts + usage
  only; the shortlist falls back to usage-only). Useful for a fast first pass or when
  there are hundreds of dashboards.
- `--ini PATH` — alternate `looker.ini`.

## Scripts
| Script | Phase | Purpose |
|---|---|---|
| `scripts/looker_api.py` | all | Minimal Looker API 4.0 client (copied from `looker-to-sigma` for self-containment; reads `~/.looker/looker.ini`, logs in fresh per call). |
| `scripts/looker-inventory.py` | 1–4 | Enumerate the environment, pull System Activity usage, scan per-dashboard complexity, score + tag → `inventory.json` + `readout.md`. Reuses the same tile/feature normalization as `looker-to-sigma`'s `fetch_looker_dashboard.py`. |
| `scripts/render-readout-html.rb` | 5 | Render the Sigma-branded `readout.html` from `inventory.json`. |

## Deliverables (in `<out>/`)
- `inventory.json` — environment counts, connection dialects, System Activity usage,
  per-dashboard complexity buckets, ownership rollup, feature/viz rollups, and the
  value/cost-ranked **shortlist**. The single file the renderer + `looker-to-sigma`
  consume.
- `readout.md` — compact markdown summary (written by the Python script).
- `readout.html` — customer-facing, Sigma-branded HTML report. Open in a browser or
  print to PDF to share.

Nothing in this directory is uploaded anywhere — sharing is a deliberate action.

## Live validation
Validated end-to-end against `example.cloud.looker.com` (Looker 26.8.11) on
2026-06-10: 6 models / 29 explores / 5 projects / 3 Snowflake connections / 1 Look /
8 dashboards (all UDD) / 13 folders / 3 groups. System Activity over 90 days returned
real run counts (Snowflake Operations = 22 dashboard runs / 43 queries → top of the
shortlist as `migrate-first`; Orders Overview = 2 runs / 18 queries) and 2 active
users. Per-dashboard scan correctly flagged Orders Deep Dive's pivot + table-calc
tiles as `manual`.

## Hand off to looker-to-sigma
After the readout, present the user a choice (which dashboards to migrate first) and
invoke `looker-to-sigma` with the shortlisted dashboard ids — the converter handles
the LookML model (`convert_lookml_to_sigma`) and rebuilds each dashboard from its
Looker Dashboard API JSON. The `shortlist` array in `inventory.json` is the hand-off
contract.

## Open work
- **Per-tile usage** is dashboard-level; the System Activity `history` explore can
  also break out by `query.id`/`dashboard_element` for tile-level attention if needed.
- **Folder/group ACL audit** (who can see what) is out of scope — counts only.
- Large instances (hundreds of dashboards): use `--no-deep` for the first pass, then
  deep-scan only the usage-ranked top slice.
