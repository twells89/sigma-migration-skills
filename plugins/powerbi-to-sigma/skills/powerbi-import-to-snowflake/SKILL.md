---
name: powerbi-import-to-snowflake
description: Land an Import-mode Power BI model's source data into Snowflake so a warehouse-native tool (Sigma) can query it. Use when a .pbix / semantic model is Import mode over Excel / Power Query / flat files (no live warehouse behind it) and a migration needs the data physically in a warehouse first. This is the DATA track that runs BEFORE powerbi-to-sigma converts the model logic. Not for DirectQuery models (those already point at a warehouse) and not a logic/DAX converter.
user-invocable: true
---

# Power BI (Import mode) → Snowflake

Sigma is warehouse-native: it has no in-memory import engine, so every table,
column, and metric resolves as live SQL against a connected warehouse. When a
`.pbix` **imports** its data from Excel / Power Query / flat files, that data
lives only in Power BI's VertiPaq store — there is no warehouse table for Sigma
to point at. This skill extracts that data and lands it in Snowflake, then hands
off to `powerbi-to-sigma` for the model logic.

**Two tracks, one migration** (this skill is track 1):

```
1. DATA   (this skill)      Import-mode .pbix  → Snowflake tables + manifest
2. LOGIC  (powerbi-to-sigma) model.bim (DAX/relationships) → Sigma data model
3. REPOINT                  DM sources → the landed Snowflake tables  → live parity
```

Track 3 is automatic when column names line up — this skill's landed column
names **byte-match** what `powerbi-to-sigma`'s converter emits (see
`refs/naming-alignment.md`), so no remapping is needed.

> Skip this skill for **DirectQuery** models — they already query a warehouse.
> Only Import-mode (or mixed, for the Import tables) needs data landing.

> **Also the designated remediation for non-warehouse sources.** When
> `powerbi-to-sigma`'s converter flags a table sourced from a **Fabric Dataflow /
> Lakehouse / OneLake / Dataverse / file** (`stats.nonWarehouseSourcedTables` +
> `⛔` warnings), this skill is the fix: it enumerates tables via TMSL and
> extracts rows via `executeQueries`, so it lands the **already-materialized**
> data regardless of the upstream connector (a dataflow-fed Import model works
> unchanged). Then repoint with `convert-model.rb --table-map manifest.json`.

## What it does

`scripts/pbi_import_to_snowflake.py` (generic — no hardcoded schemas):

1. **Auth** — silent MSAL (Power BI + Fabric scopes), cached, device-code fallback.
2. **Resolve** — workspace + dataset by name/id; or `--pbix` uploads the file first
   via the Power BI REST `/imports` endpoint.
3. **Enumerate** — model tables/columns/`dataType` via TMSL `getDefinition`
   (version-independent; `INFO.TABLES()` fails on old compat levels). Skips
   auto date tables and calculated/binary columns (see `refs/what-gets-landed.md`).
4. **Extract** — rows via `/executeQueries` (DAX `SELECTCOLUMNS`), with automatic
   integer-key **band pagination** (executeQueries silently truncates ~48k rows).
5. **Load** — typed DDL + `PUT`/`COPY` via `snow sql`, with `GRANT`s.
6. **Sync** — `--sigma-connection <id>` registers the new tables with Sigma
   (`POST /v2/connections/<id>/sync`) so the DM POST resolves them immediately.
   The co-located `scripts/lib/sigma_rest.py` reuses a valid token, refreshes a
   stored browser session before client-credential fallback, honors token age,
   and retries one HTTP 401.
7. **Manifest** — `out/<dataset>/manifest.json`: `pbi_table.col → sf_table.COLUMN`.

## Run

```bash
# dry run — extract + generate load.sql, do not touch Snowflake
python scripts/pbi_import_to_snowflake.py \
  --dataset "<dataset name or id>" \
  --target-db <DB> --target-schema <SCHEMA> --dry-run

# full: extract → land → grant → sync into Sigma
python scripts/pbi_import_to_snowflake.py \
  --dataset "<dataset name or id>" \
  --target-db <DB> --target-schema <SCHEMA> \
  --sf-conn <snow-cli-connection> \
  --sigma-connection <sigma-connection-uuid>
```

Useful flags: `--pbix <file>` (upload first), `--only "A,B"` (subset),
`--limit-rows N` (cheap smoke test), `--grant-role <ROLE>` (default `PUBLIC`),
`PBI_BAND_MAX=<n>` (force/soften pagination — testing).

Requires: `msal`, `requests`, `truststore` (corp TLS); the Snowflake CLI
(`snow`) configured. Sigma sync is optional. When `--sigma-connection` is set,
configure `SIGMA_BASE_URL` plus either a valid `SIGMA_API_TOKEN`, a browser
session saved by `scripts/browser-login.sh`, or `SIGMA_CLIENT_ID` /
`SIGMA_CLIENT_SECRET` for unattended fallback. Missing Sigma auth skips sync
without undoing the completed Snowflake landing; per-table sync errors are
reported and the remaining tables continue. Power BI/Fabric auth remains the
separate device-code path described in `../powerbi-to-sigma/SKILL.md`.

## Verifying a change locally

The Sigma sync transport tests are credentials-free and make no network calls:

```bash
python3 scripts/test_pbi_import_sigma_auth.py
```

## Then hand off

1. Convert the model with `powerbi-to-sigma` (or locally, pointing at your converter build:
   `CONVERTER_PATH=<.../build/powerbi.js> node scripts/run_converter.mjs <model.bim> <sigma-conn-id> <DB> <SCHEMA> dm.json`).
2. POST the DM — sources resolve against the landed tables (names align).
3. Verify parity — query the DM and compare to the PBI `executeQueries` golden.
   Validated end-to-end on Microsoft's Retail Analysis Sample: 923,371 SALES rows,
   live Sigma DM total `$41,013,686.95` == PBI golden, to the cent.

## Gotchas (read `refs/` before a real run)

- `refs/naming-alignment.md` — why landed columns must match `sigmaPhysicalName`.
- `refs/what-gets-landed.md` — skip rules (auto date tables, calc + binary columns).
- `refs/sync-and-grant.md` — new tables 404 on DM POST until GRANT + connection sync.
- `refs/pagination.md` — the ~48k executeQueries truncation and band strategy.
- `refs/metric-query-quirk.md` — converted metrics don't resolve via ad-hoc
  `metric()` SQL (they render in the workbook UI); sum base columns for parity.
