---
name: powerbi-to-sigma
description: Convert a Power BI report + semantic model into a Sigma data model and matching dashboard. Use when the user has a Power BI report (in Power BI Service / Fabric, or a .pbix/.pbit file) and wants to recreate it in Sigma. Covers connecting to Power BI with no Entra app, extracting the model (TMSL) + report layout (PBIR/Report-Layout), converting via the sigma-data-model MCP, posting the data model + workbook via REST, and parity verification. Can also author dashboards back INTO Power BI via the Fabric write API.
user-invocable: true
---

## Verifying a change locally

Run **both** test directories — this plugin keeps suites in `scripts/` AND `tests/`:

```bash
cd plugins/powerbi-to-sigma/skills/powerbi-to-sigma
for t in scripts/test-*.rb tests/*.rb; do ruby "$t" >/dev/null 2>&1 || echo "FAIL $t"; done
for t in scripts/test-*.py tests/test-*.py; do python3 "$t" >/dev/null 2>&1 || echo "FAIL $t"; done
```

Globbing only `scripts/test-*.rb` reports an accurate-looking count while skipping
`tests/test-grounding.rb` — that omission once merged a change that left `main` red on 7
assertions. `scripts/test-suite-registration.rb` enforces that every suite in both
directories is also registered in CI, so a new suite cannot be added and silently never run.


# Power BI → Sigma

> **Windows / first run — run the environment doctor before anything else:**
> `bash scripts/doctor.sh` (macOS/Linux/Git Bash) or `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1` (Windows).
> It checks Ruby/Python/Node/bash and flags the Python "Store stub" + CRLF with exact fixes. Details: `refs/environment.md`.

> ## ⛔ STEP 1 — THE ONE PATH (do not improvise a workbook)
> This conversion runs through **one orchestrator** that builds every chart and
> **verifies each one's data against Power BI before it's done**:
> ```
> ruby scripts/migrate-powerbi.rb --tmsl <model.bim> --pbir <report-bundle.json> --connection <id> --out <WORK>
> ```
> - **You need the model (TMSL) + report layout (PBIR) first. Get them by
>   CONNECTING to Power BI — do NOT ask the user to hand them over and do NOT
>   proceed without them.** Run the device-code login (no Entra app):
>   ```
>   python scripts/fabric-extract.py --report "<report name>" [--workspace "<ws id|name>"] \
>     --out-dir <WORK> --report-out-dir <WORK> --report-bundle <WORK>/report-bundle.json
>   ```
>   It prints a **device code + `https://microsoft.com/devicelogin`** — tell the
>   user to open that URL and enter the code (one sign-in; token caches). Then run
>   the orchestrator with the extracted `--tmsl`/`--pbir`. Full recipe: `refs/connection.md`.
> - **COMPOSITE / live-connected reports → prefer the local `.pbix` (the orchestrator
>   PROMPTS for it).** Many reports are Power BI **composite** models (local tables +
>   a reference to a shared/remote dataset) or are thin reports live-connected to a
>   shared dataset. For these, `getDefinition` of the report's bound model is
>   **INCOMPLETE** (it misses the report-local measures/calc tables, or isn't a
>   resolvable standalone model), and Power BI **blocks export-to-`.pbix`** for
>   live-connected reports, so device-auth can't download it. The COMPLETE model is
>   in the author's local `.pbix`. The orchestrator DETECTS this (Fabric-path TMSL
>   shows DirectQuery/`entity`/remote-dataset references) and STOPS with an OPEN
>   QUESTION (exit 10) asking for the local `.pbix` — do **not** silently build a DM
>   from the incomplete model. Ask the user for the file and re-run with `--pbix`
>   (offline tell in a `.pbix`: its `Connections` member's `RemoteArtifacts`). Only
>   pass `--allow-incomplete-model` if the user knowingly accepts the partial model.
> - **FULLY-LOCAL `.pbix` (no Fabric / no tenant / not published).** When the user
>   has only a local `.pbix` on disk, skip the CONNECT/EXTRACT steps entirely — run
>   the orchestrator with `--pbix` and it extracts BOTH halves locally (Phase 0):
>   ```
>   ruby scripts/migrate-powerbi.rb --pbix <file.pbix> --connection <id> --database <DB> --schema <SCHEMA> --out <WORK>
>   ```
>   - **Model:** `scripts/extract-model-pbix.py` reads the `.pbix`'s binary VertiPaq
>     `DataModel` with **pbixray** and emits a TMSL `model.bim` (same shape `--tmsl`
>     eats), including DAX calculated tables (`pbixray.dax_tables`) as calculated
>     partitions rather than fake warehouse tables. pbixray must be installed —
>     its `xpress9`/`xmhuffman` deps ship broken
>     sdists and must be **built from source**; one-time setup in `refs/local-pbix.md`.
>     Without pbixray the model half exits with a clear install hint (the report half
>     and the Fabric `--tmsl` path are unaffected).
>   - **Report:** `scripts/extract-report-classic.py --pbix <file>` unzips the
>     `Report/Layout` member (a single **UTF-16LE** classic `sections[]` doc) — no
>     Fabric. It also accepts `--report-layout <file>` for an already-extracted Layout.
>   - Import-mode `.pbix` with no live warehouse to point at? Land the frozen data
>     first (see the Import-mode → Snowflake data-landing skill), then pass that
>     connection/db/schema here.
> - **NEVER hand-author a workbook JSON and `curl`-POST it to `/v2/workbooks`, and
>   never lay out empty "placeholder" pages.** That bypasses the DAX conversion,
>   chart build, and parity gate and ships an EMPTY workbook (invented page names,
>   no elements) — the #1 way this migration fails. If you cannot extract the
>   model (no Fabric access / not published), **STOP and tell the user you need to
>   connect to Power BI (device-code) or that the report must be published** — do
>   not fall back to a hand-built shell.
> - **"Done" is not "pages exist."** The migration is complete only when
>   `ruby scripts/verify-complete.rb --workdir <WORK>` prints ✅ DONE — i.e. the
>   `assert-phase6-ran` parity gate passed with real chart elements. An empty or
>   placeholder workbook is never done, no matter how it looks.
> - Small/older models (e.g. running on Haiku): if the report is large or complex,
>   say so and confirm scope with the user before building — don't silently
>   degrade to a partial shell.

## Preflight the workbook spec before POST (mandatory)

Before POSTing any workbook spec, run `ruby scripts/lib/preflight_lint.rb <spec.json>` — it exits 1 with a precise message on the two migration-killer bugs: a `table` with aggregate columns + dimensions but **no `groupings`** (renders raw detail rows), and a malformed `control` (missing `id`/`controlId`/`controlType` or nesting value fields under a `value` object instead of flat, a non-double-nested `source`, or a list control wired to neither `source` nor `filters` — a filters-only list control is valid). Fix every violation first — never POST past it, and **never conclude a feature is "unsupported" from an `Invalid kind` error** (it means the inner fields are wrong). Verified shapes: `sigma-workbooks` `controls.md` / `tables.md`.

## Phase 0 — Choose where to build (ask first when no destination given)

Don't silently land the migrated data model + workbook in an auto-picked folder.
If the user didn't supply a destination (no `--folder <id>`), ASK before building:

1. `ruby scripts/pick-destination.rb list` → `{ workspaces, folders (editable, with parentName), myDocuments }`
2. Let the user pick ONE: a **workspace** (its `id` lands content in the workspace root),
   an existing **folder**, **My Documents** (when non-null — null for service tokens), or
   **create a new folder**: `ruby scripts/pick-destination.rb create --name "<name>" [--parent <workspace-or-folder-id>]`
3. Pass the chosen id as `--folder <id>`. `folderId` accepts a workspace id or a folder id.

If a destination is already supplied, honor it silently — don't ask.

> **READ FIRST — `refs/operating-contract.md`**: the fidelity guardrails (render + value-check EVERY page against the source; never ship empty or silently drop a tile; don't spin — surface blockers).
> **Modeling strategy — `refs/modeling-strategy.md`**: faithful star reproduction is the DEFAULT (parity is the gate); an upstream OBT or Sigma-native materialization is an OPT-IN optimization for hot, join-heavy dashboards, re-verified against the same parity oracle. The converter never auto-flattens. (Measured: flat beats live-join joins by 1.35–2.5× on join queries, but is neutral/worse join-free.)
> Status: **foundation** (validated end-to-end 2026-05-31 on the "Employee Dashboard" workforce report).
> Beads: build = `beads-sigma-cs2`; converter gaps = `j89` (M-Snowflake path), `tkd` (element names / schemaVersion / folderId).
> Defers to: `sigma-workbooks` (canonical workbook spec), `sigma-data-models` (DM spec), the `convert_powerbi_to_sigma` MCP tool, and `tableau-to-sigma/scripts/*` (reused verbatim for posting + layout + parity).

## What's proven (the happy path, validated once)
```
1. CONNECT   device-code login, well-known PowerBI-Desktop client, NO Entra app   → scripts/fabric-extract.py
2. EXTRACT   Fabric getDefinition?format=TMSL → model.bim   (+ .pbix Report/Layout for visuals)
3. CONVERT   local vendored converter (converter/powerbi.mjs via node) — model.bim + connectionId + db/schema → Sigma DM JSON   [MCP only as manual fallback]
4. POST DM   fix spec (schemaVersion + folderId/ownerId + element names) → POST /v2/dataModels/spec
5. WORKBOOK  Data page (master tables per DM element) + chart elements → POST /v2/workbooks/spec
6. LAYOUT    PBIX/PBIR visual x,y,w,h → 24-col grid XML → put-layout.rb
7. VERIFY    sigma-mcp-v2 query each element returns real rows; Phase 6 = compare vs PBI executeQueries (DAX)
```

## Step 0 — Front door: resolve the connection once (`scripts/intake.rb`)

Resolve the Sigma warehouse connection a SINGLE time up front so no phase free-searches
`/v2/connections` (the token sink):

```bash
ruby scripts/intake.rb --workdir <WORK> --tool powerbi-to-sigma --mode file \
  [--connection <id>] [--name <connection-name-substring>]
```

Caches `<WORK>/connection.json` (the orchestrator reads it when `--connection` is omitted —
point `--out` at the same `<WORK>`) and writes `intake.json` (run-start + mode for
run-duration / audit). Multiple connections + no id/name → it lists them and asks you to pick;
never guesses. (Power BI input is almost always `--mode file` — TMSL + PBIR exports.)

> **ASK FOR SOURCE DASHBOARD SCREENSHOTS UP FRONT (file mode).** Layout is inferred from the
> export's `x,y,w,h` **coordinates only** — never from an image — and those free-form/absolute
> PBI coords lose the arrangement Sigma's grid needs. In `--mode file` there is **no live report
> to auto-render** (`export-pbi-pages.py` needs a live `reportId` on Fabric capacity + a Power BI-
> audience token + PNG not tenant-disabled), so the Phase 5e visual-compare, source-anchor (gate 13)
> and visual-similarity (gate 14) gates have nothing to check against and **self-skip** — layout
> errors ship unseen (field-caught). `intake.rb` prints an `[ASSIST]` block for this; act on it:
> **before building, `AskUserQuestion` the user for a screenshot of EACH source dashboard page (one
> PNG per page) and land them in `<WORK>/dashboards/`.** That path ARMS the visual gates (they
> discover `<WORK>/dashboards/*.png`). If the user has none, proceed but **waive** the visual gates
> at Phase 6 with a stated reason (`--skip-anchors-gate`/`--skip-visual-similarity "<reason>"`) —
> never a silent skip. Headless (`--yes`/`--answers`): skip the prompt and waive with a stated reason.

## Phase 1 — Connect (no Entra app required)
The corporate tenant blocks Entra app creation, Git integration, and XMLA (PPU). The working path:
- `scripts/fabric-extract.py` — device-code via well-known public client **`ea0616ba-638b-4df5-95b9-636659ae5121`** (Power BI Desktop), scope `https://api.fabric.microsoft.com/.default`. User signs in once at the device URL; token cached.
- **`truststore.inject_into_ssl()` is mandatory** (first line) — corp TLS inspection on `api.fabric.microsoft.com`; uses macOS keychain CA.
- See `refs/connection.md` for the full recipe + surprises (works on My-workspace, device-code not CA-blocked).
- **Alternative connector (optional):** where the model is on PPU/Fabric capacity, the [Power BI Modeling MCP](https://github.com/microsoft/powerbi-modeling-mcp) reaches it over **XMLA from macOS** (no Entra app, no secrets) and can `ExportTMSL` the model the converter eats — useful when `getDefinition` REST is unavailable or for ad-hoc model exploration. Setup + two-stage connect recipe in `refs/pbi-modeling-mcp.md`. Not the default; device-code above is.

## Phase 2 — Extract (FAST DISCOVERY — designed for 30-50 workspace / 20-40 report estates)
- **Model**: `getDefinition?format=TMSL` (202 LRO → poll `Location`) → base64 `model.bim` part = the TMSL/TOM JSON the MCP eats. Works even on My-workspace.
- **One concurrent fetch, not two serial scripts.** The model TMSL and the report definition are INDEPENDENT artifacts — `fabric-extract.py --report <id|name> --report-out-dir DIR [--report-bundle PATH]` fires both `getDefinition` LROs concurrently (shared pool, **hard cap 4 per principal** — Fabric throttles getDefinition; >4 risks 429 long-tails). LRO polling is **0.5s-first + backoff (1s, 2s, then Retry-After capped at 4s)** instead of sleeping the full Retry-After before the first status check — Fabric routinely advertises `Retry-After: 20` for definitions that are ready in <2s. `--report-bundle` writes the flat `{part: text}` JSON that `migrate-powerbi.rb --pbir` accepts directly.
- **Skip estate enumeration when you know the workspace** (you usually do): `--workspace <id|name>`. A workspace ID is 2 cheap GETs; the old serial walk of every workspace was 15-30s at 30-50 workspaces. Without `--workspace`, enumeration fans out **8-wide** (cheap metadata GETs, not LROs) → **~2-3s** for a 30-50 ws estate, and the result is **session-cached** at `/tmp/pbiauth/estate-map.json` (override `PBI_ESTATE_CACHE`), invalidated automatically on any name miss; `--no-cache` bypasses.
- **Measured (live, 2026-06-11, EMPLOYEE DASHBOARD)**: old serial path (fabric-extract + extract-pbir) = **46.3s**; new concurrent fetch = **5.1s cold / 3.6-3.9s warm-cache** — byte-identical output parts. Every run writes a per-task **`timings.json`** to `--out-dir` (the evidence trail; always emitted).
- **Batch / fleet extraction** (the assessment path): `fabric-extract-batch.py --reports "A,B,C" [--workspace W] [--all] --out-root DIR --pool 4` flattens each report into two artifact tasks (model TMSL + report definition) and pools them 4-wide; each report's bound model resolves via the Power BI REST `datasetId` (name-match fallback). Measured: 3 reports (6 artifacts) = **7.5s wall** vs ~16s serial-equivalent fast-polling and **~2.3 min** on the old per-report serial path. Output per report: `model/`, `report/`, `report-bundle.json` + a root `manifest.json` and `timings.json`.
- **Layout**: a `.pbix` is a zip; `Report/Layout` is **UTF-16LE** JSON with per-visual `x,y,w,h` (canvas px, 1280×720 default). `extract-report-classic.py --pbix <file>` unzips + decodes it locally (or `--report-layout <file>` for an extracted Layout).
- **Local `.pbix` DataModel is now extractable** (no Fabric): the `.pbix`'s `DataModel` is a *binary* VertiPaq blob — `extract-model-pbix.py --pbix <file>` reads it with **pbixray** (measures/schema/relationships/M + `dax_tables`) and emits a TMSL `model.bim` the converter eats. See `refs/local-pbix.md` (incl. the pbixray from-source install for its broken `xpress9`/`xmhuffman` deps). getDefinition / a `.pbit`'s `DataModelSchema` remain alternatives when Fabric is reachable.
- See `refs/powerbi-visual-layout.md` for the Report/Layout & PBIR parsers and the visualType→Sigma-kind table. The shared fetch layer (token, fast LRO, pooled fetch, estate cache, timings) lives in `scripts/pbi_fabric.py`.
- **Style fidelity — `refs/style-fidelity.md`**: reproducing the PBI report's *look*, not just its data. The extractor captures the report theme name, card value color, and matrix totals; the builder emits a Sigma `settings.theme.name`/`settings.theme.overrides` (palette from `lib/pbi_theme.rb` — drives donut/pie + series colors), KPI-card styling (`value.color` + `titleOrient: bottom`), a donut null→`(Blank)` coalesce so the palette maps per-slice like PBI, and re-expresses a totals-bearing tableEx/matrix as a `pivot-table` with a grand-total row. **Table/matrix conditional formatting** (color scales, font-color scales, data bars, and rules/thresholds) is carried onto the Sigma table as element-level `conditionalFormats` (`extract-pbir.py` `_conditional_formats` → `lib/pbi_conditional_formats.rb`): gradient→`backgroundScale`/`fontScale`, dataBars→`dataBars`, rules→one `single` per band (ranges via `condition: formula`). Field-value (DAX-measure-driven) CF and un-mappable rule shapes (cross-column, else-default) are recorded to `coverage.json` (never silently dropped). Also documents the one deliberate non-transform (PBI thousands-K number format).

## Phase 2.5 — SOURCE-FRESHNESS PREFLIGHT (import-mode models, bead fmte)
Import-mode PBI models are **frozen snapshots**; Sigma reads the LIVE warehouse. Before any parity side-by-side, capture the dataset's freshness so staleness deltas are called out UP FRONT (mirrors qlik-to-sigma Phase 1.5):

```bash
"$PY" scripts/pbi-freshness.py --workspace <wsId|me> --dataset <datasetId> \
  --tmsl model.bim --out $WORK/freshness.json
```

Pulls the refresh history (`GET datasets/{id}/refreshes` via the cached token) — last successful refresh + **FAILED refreshes** (expired warehouse creds are the classic cause; surfaced loudly) — plus a cheap `executeQueries` row-count/max-date snapshot per table (the per-table probes run **4-wide in parallel** — a 6-table model snapshots in one round-trip's wall time). The preflight is **NON-BLOCKING**: it is only CONSUMED at Phase 6/7 parity, so `run.sh` (stage 1.5) and `migrate-powerbi.rb` (Phase 1.5) launch it as a **background lane concurrent with Convert/Build** and join it (replaying its log) right before parity — 3-8s of Power BI round-trips off the critical path. A run that stops at a gate leaves the detached probe to finish; the resume run reuses the written `freshness.json`. Phase 6/7 parity is then **LED by the staleness banner**, and deltas classify **MATCH / STALE-EXPLAINED / DIVERGENT — only DIVERGENT blocks** (a "Sigma shows more data" delta on a stale snapshot is explained, not a conversion error). `migrate-powerbi.rb` also always writes per-phase **`timings.json`** and prints a `PHASE TIMINGS` line at every terminal exit.

## Phase 3 — Convert (local, zero-config)
The conversion runs **locally by default**: `migrate-powerbi.rb` executes the vendored
converter bundle (`converter/powerbi.mjs`, `convertPowerBIToSigma`) in-process via a `node`
shim — no clone, no `npm install`, no network, **no MCP, no data egress**. A dev's own build
wins via `--mcp-dir` / `$PBI_MCP_DIR`. Only if the bundle is **also** absent does it gate
(exit 10) with instructions to run the `convert_powerbi_to_sigma` MCP tool **manually** and
resume with `--converter-out`. The hosted MCP is a fallback, not the default path.

`convertPowerBIToSigma(model_json, connection_id, database, schema)`.

> **Databricks / lower-case warehouses (beads-sigma-lanq.7):** physical identifiers default to
> UPPER (Snowflake/BigQuery fold that way). Databricks/Spark store identifiers **lower-case** and
> bind only against a lower-cased warehouse path, so an UPPER path fails at POST with
> `Source not found`. `migrate-powerbi.rb` reads the resolved connection's `type` from
> `connection.json` and passes `warehouseType` to the converter automatically; the flag
> **`--warehouse-type databricks`** forces it (use this if the connection was passed with
> `--connection <id>`, since that path doesn't populate the type). The element name and
> `[Table/Col]` formula refs stay UPPER (Sigma-internal) — only `source.path` + column physical
> names fold to the warehouse case. A single `--schema` also no longer collapses a multi-schema
> model (beads-sigma-lanq.6): it's applied as a repoint only on a single-schema model.

> ⚠️ **`--converter-out` takes the converter's output — never a hand-authored spec.**
> The flag exists so you can run the converter (the fallback `convert_powerbi_to_sigma`
> MCP tool when the local bundle is unavailable), save its
> result, and resume the pipeline with it (`convert-model.rb --converter-out <that file>`).
> It is **not** an invitation to write `dm-raw.json` by hand. Hand-authored specs skip
> the converter's column-name/SQL/formula-prefix guarantees and reliably produce
> `Missing "kind" field`, `source.statement: undefined`, and `dependency not found`
> errors (validate-spec.rb now catches the first two, but the right fix is to feed it
> real converter output). If the MCP tool is unavailable, STOP and gate — don't fabricate.

- DAX measures → Sigma metrics. ~70% mechanical; see `refs/dax-to-sigma-coverage.md` and `fixtures/MANIFEST.md` (test oracle: 94 DAX expressions bucketed a/b/c).
- **DAX calculated retail calendars:** explicit
  `ADDCOLUMNS(CALENDAR(DATE(...),DATE(...)),...)` tables synthesize a SQL date
  spine; complex event columns become Sigma calculated columns. Covered:
  `VAR/RETURN`, `IF`/`SWITCH`, `WEEKDAY` return types, `EDATE`/`EOMONTH`,
  `DATE`, and arithmetic used by Black Friday, Easter, Back-to-School, and
  Christmas logic. `CALENDARAUTO`, dynamic bounds, and unsupported
  `GENERATE`/`ROW` remain blocked. The orchestrator fails before POST on
  placeholder SQL, calendar `NULL AS`, or dropped calculated-table columns;
  `--yes` cannot bypass it. An intentional exception requires
  `--allow-incomplete-calculated-tables "<reason>"`.
- **PromoteHeaders**: if `pbi-dm-signature.py` reports `promoted_header_tables` (the model's M-query used `Table.PromoteHeaders`), the warehouse table's real columns are auto-named (`C1`, `C2`, …) with the semantic names in row 0 — the TMSL `sourceColumn` names will NOT resolve. Verify the landed table's real columns and remap with `convert-model.rb --table-map` (in Sigma formulas the columns appear as `C 1`, `C 2`, … and in JOIN SQL alias them, e.g. `c.C2 AS CUSTOMER_NAME`).
- **Known gap `j89`**: the Snowflake `Snowflake.Databases(...) + Navigation` M pattern isn't parsed → pass `database`/`schema` explicitly until fixed.
- **Non-warehouse sources (Fabric Dataflow / Lakehouse / OneLake / Dataverse / file)**: when a table's M source is a `PowerPlatform.Dataflows` / `Lakehouse.Contents` / `CommonDataService` / `Excel.Workbook`-style connector, the data is NOT in a warehouse Sigma can query and the dataflow's transform logic is NOT in the semantic model (so it can't be translated). The converter flags each such table with a `⛔` warning + a placeholder path and reports `stats.nonWarehouseSourcedTables`; `migrate-powerbi.rb` surfaces a **`non_warehouse_source` decision** at the checkpoint. **Handoff:** run the **`powerbi-import-to-snowflake`** skill to land the data (it works for Import-mode models — the dataflow already materialized the rows), then re-run **Phase 3 Build** with `convert-model.rb --table-map <manifest.json>` — the loader reads the landing manifest directly (no manual map) and repoints the elements. The `powerbi-assessment` readout flags these tables up front under "Data-source patterns".
- **DAX gaps → gap-scout**: for measures the converter buckets `b` (restructure) or `c` (no-equivalent) — `RANKX`, `ALLEXCEPT`, `SUMMARIZE`, `USERELATIONSHIP`, `PATH*` — spawn the **gap-scout** sub-agent (`scripts/gap-scout.md`): it proposes a Sigma translation, validates it against the live API (`scripts/scout-validate.py`), and persists the rule to `~/.powerbi-to-sigma/learned-rules.yaml` (loaded by `scripts/learned-rules.py`) so future conversions auto-apply it. Time-intelligence (YTD/SPLY) is usually translatable — see `refs/measure-patterns.md`, not the scout.

## Phase 3.5 — Reuse an existing DM? (avoid sprawl — the reuse-first DM gate every converter runs before building)
Before posting a NEW data model, check whether an existing Sigma DM already
covers the same warehouse tables (don't add a 4th near-identical "Orders" DM):
```
python3 scripts/pbi-dm-signature.py --bim /tmp/pbix/model.bim --out $WORK/dm-signature.json
ruby scripts/find-or-pick-dm.rb --workbook-signature $WORK/dm-signature.json \
  --out $WORK/dm-match.json --auto-pick     # exit 0 = candidate ≥ min-score
```
`pbi-dm-signature.py` derives `{warehouse_tables (DB.SCHEMA.TABLE from the M
nav), referenced_columns, measures}` from the model.bim. If a candidate scores
high AND there's no tie, `--auto-pick` recommends reuse (sets `auto_picked:true`
— WARN about inherited columns/RLS/metrics); on a tie it falls back to ASK. To
reuse: skip Phase 4, point the workbook masters at the matched `recommended_dm_id`
+ its element ids (describe it), and continue at Phase 5. Otherwise post new.

## Phase 4 — Post the data model
The converter output (`sigmaDataModel`) needs 3 fixups before `POST /v2/dataModels/spec` (gap `tkd`):
1. **`schemaVersion: 1`** at top level (else `schemaVersion: Invalid 1: undefined`).
2. **`folderId` + `ownerId`** at top level — pull from a reference DM (the **tableau-to-sigma reuse logic**, `find-or-pick-dm.rb`).
3. **Element `name`** on each base warehouse-table element (= `source.path[-1]`) — the converter only names joined View elements, but workbook masters reference DM elements by name.
   > These joined View elements are query-time joins Sigma runs in the warehouse. For *why* Sigma modeling differs and when to consider an upstream OBT / Sigma-native materialization instead (an opt-in optimization, not something this skill does automatically), see `refs/modeling-strategy.md`. When the converted model has ≥2 joins, the orchestrator prints a one-line MODELING ADVISORY pointing there.
Then: `tableau-to-sigma/scripts/post-and-readback.rb --type datamodel`. See `refs/spec-fixups.md`.

> **What Phase 4 "validation" catches — and what it does NOT (read before trusting a clean DM).**
> `validate-spec.rb` is spec-**shape** only (kinds, formula function names, ref prefixes — no
> warehouse). After the POST, `post-and-readback.rb` fetches `GET /v2/dataModels/{id}/columns` and
> **halts (exit 2) on any column that resolves to `type "error"`, before the workbook is built** —
> catching bad refs, missing physical columns, and non-existent functions. It does **NOT** catch a
> column that resolves to its *declared* type here but fails at actual **query time**: a physical-name
> **case** mismatch on a case-sensitive-stored warehouse (Databricks stores lower-case — `beads-sigma-lanq.7`),
> a wrong per-table **schema** (`beads-sigma-lanq.6`), or an **ungranted schema**. Those surface only at
> Phase 6 — so a model that looks "validated" here can still error *after* the workbook exists (the
> delete-and-recreate trap). **A clean Phase 4 is not a warehouse-resolution guarantee.** If Phase 6
> shows `type "error"` columns Phase 4 didn't, suspect warehouse **casing / schema / grants** first,
> and confirm the connection identity can read every schema the model spans. (Follow-up `beads-sigma-q48b`:
> an optional pre-workbook query-probe that runs one live query per DM element to surface these early.)

## Phase 5 — Build the workbook
- **Data page**: one hidden `table` master per DM element used (`source: {kind:data-model, dataModelId, elementId}`, columns `[ElementName/Col]`).
- **Chart elements** source from a master (`source:{kind:table, elementId:<master>}`), columns `[dim, meas]`:
  - bar/line: `xAxis:{columnId}`, `yAxis:{columnIds:[...]}`
  - pie/donut: `color:{id}`, `value:{id}`
  - waterfall/gauge: native `waterfall-chart` / ring `progress`; never coerce them to bar/KPI.
  - maps: Azure Maps `X`/`Y` roles become longitude/latitude on a native
    `point-map`; `Size` controls bubble size and `Series`/`Legend` controls
    categorical color. Other map types use explicit coordinates or TMSL
    `dataCategory` metadata for point/region-map resolution.
  - a proven chart hierarchy emits `controlType:drill`; a visible categorical legend on a supported chart emits `controlType:legend`. Emit neither unless every source/target column resolves.
  - text: `{kind:text, body:"## ..."}`
  - measure formula wraps the master col: `CountDistinct([Master/Col])`, `Sum([Master/Col])`, date dim `DateTrunc("month",[Master/Col])`.
- `POST /v2/workbooks/spec` (post-and-readback `--type workbook`). Chart-element shapes mirror `tableau-to-sigma/scripts/build-charts-from-signals.rb`. **The body is an outer metadata envelope plus `document`** (verified live 2026-08-03, including on `/verify` 2026-08-04): `name`/`folderId` stay outside; `document` owns `schemaVersion`, `kind:"workbook"`, metadata-only `pages`, one flat `elements` collection, required authoritative `layout`, settings, panels, and overlays. Every element must occur exactly once in layout. Never put workbook elements back under a page (data-model specs are unchanged and remain nested). `post-and-readback.rb` preserves the complete workbook document on write. See `refs/spec-fixups.md` and `refs/workbook-code-release-gaps.md`.

## Phase 5c — Coverage report (NEVER silently drop a component)
The build **never silently drops** what it can't resolve — every drop, downgrade,
and approximation is recorded to `$WORK/coverage.json` and surfaced as ONE
consolidated **MIGRATION COVERAGE** readout (the doctrine the RLS section already
states, extended to visuals). `migrate-powerbi.rb` prints it automatically after
the workbook POST; for a standalone `build-workbook-from-pbir.rb` run pass
`--coverage-out` and read the file. The report **leads with what carried over**
(an approximated treemap→bar or a degraded missing-field visual still lands with
its data; only a `dropped` visual is truly absent) so the common "it drops a lot"
perception — usually just gaps that were never surfaced in one place — is
answered with the real number.

- `severity`: `dropped` (no element built) · `degraded` (built, lost a role/field/sort) · `approximated` (built as a substituted Sigma kind, e.g. treemap/funnel → bar).
- `recoverable: true` items carry a concrete **action** (supply `--image-map`, add a joined master, re-point a drill level, supply a geo column). In an interactive run they print as an **ASSISTANCE AVAILABLE** block — present them to the user (one `AskUserQuestion` checklist: *recover* vs *accept*). Under `--yes`/`--answers` they take the accept default and are recorded as accepted degradations.
- `recoverable: false` items are genuine Sigma spec limitations (for example, region maps have no categorical legend) — reported, never asked about.
- The recoverable items are **hard-gated** at Phase 5e: `assert-visual-compare.rb --coverage` will not go GREEN until each is recovered or explicitly acknowledged.

## Phase 5d — Layout (do NOT skip — stacked ≠ done)
Map each visual's `x,y,w,h` → 24-col grid (`COL_UNIT = page_w/24`, `ROW_UNIT ≈ 30`) → single `document.layout` XML (one `<Page>` per page, server page IDs) → `tableau-to-sigma/scripts/put-layout.rb`. Math + snap rules in `research/powerbi-visual-layout.md §4`.

## Phase 5e — VISUAL COMPARE vs the SOURCE (MANDATORY — numbers lie about looks)
Phase 6 proves the NUMBERS; this phase proves the PAGES. A conversion shipped
with exact query parity and still looked broken (collapsed KPIs, stacked bars
that should be clustered, alphabetical months) — caught only by putting full
pages next to the Power BI renders. Do this BEFORE Phase 6, every run:

1. Export the SOURCE pages: `"$PY" scripts/export-pbi-pages.py --report <reportId> [--workspace <groupId>] [--tenant <guid|url>] --out-dir $WORK/visual-qa`
   (PNG is commonly tenant-disabled — the script falls through to PDF and **rasterizes it to per-page `powerbi-page{N}.png`** so the downstream `Read` needs no poppler. Guest/B2B report in another tenant? pass `--tenant <guid|report-url>`.)
   > **`ExportToFile` is the ONLY documented way to render a PBI page programmatically** — and it's
   > what this script uses (**Power BI-audience** scope `analysis.windows.net/powerbi/api/.default`,
   > via the shared `pbi_fabric` per-tenant cache — don't reuse the Fabric-audience token or it 404s;
   > see `pbi-export-pages-token-audience`). Because the cache is shared, once you've completed the
   > Fabric extraction sign-in for the same tenant this second audience is usually **silent** (no
   > extra device-code prompt). If the workspace isn't on **Fabric/PPU/premium capacity** (or export
   > is tenant-disabled / fails), the script **soft-fails (exit 3)** with a reason + the Phase-6
   > waiver to use — it does NOT crash the run; the compare falls back to a structural check. **There is
   > no other agent-driven render path:** the Power BI **Modeling MCP is model/DAX-only** (no visuals),
   > there is **no PBI `get-view-image` MCP tool** (Tableau has one; Power BI does not), and Power BI
   > **Embedded** screenshotting needs an Entra app + embed token this corporate tenant blocks. So:
   > run `ExportToFile` whenever you have a live report on capacity; otherwise fall back to the user.
   **No live report / export 404s / all formats tenant-disabled (the file-mode default):** you can't
   auto-pull the source render — fall back to the **user-supplied screenshots** requested at Step 0
   (`<WORK>/dashboards/*.png`). If they weren't provided at intake, `AskUserQuestion` for them now
   before comparing; if genuinely unavailable, waive gates 13/14 at Phase 6 with a stated reason.
2. Export EVERY Sigma page: `"$PY" scripts/sigma-export-png.py --workbook <wbId> --page <pageId> --out $WORK/visual-qa/sigma-<page>.png`.
3. **Read both images for each page, side by side.** Check, per page: same
   elements in the same spots; charts show MARKS (not just axes); clustered vs
   stacked matches the source; axis order (months Jan→Dec, not alphabetical);
   KPI tiles show value AND label; no giant decorative text; no dead bands.
4. Write `$WORK/visual-qa/visual-compare.json`: `[{page, verdict: PASS|ACCEPTED|FAIL, deltas: ["…"]}]`
   — ACCEPTED means the user explicitly OK'd a listed delta (e.g. zip
   choropleth instead of PBI's bubble map; theme colors). FAIL = fix and re-export.
5. Gate: `ruby scripts/assert-visual-compare.rb --dir $WORK/visual-qa --signals $WORK/signals.json --coverage $WORK/coverage.json`
   must print GREEN before Phase 6 may be declared. `--coverage` cross-checks the
   Phase 5c ledger: every **recoverable** gap must be acknowledged — its visual
   named in a page's `deltas[]` (or an explicit `acceptedGaps` list) — so a
   recoverable drop can never ship unnoticed.
6. **Measured bars (feed the Phase-6 anchors + visual-similarity gates 13/14).**
   Steps 3–5 are human judgment; these two are deterministic and MUST also run:
   - **Source anchors.** While reading each source page, transcribe its printed
     values into `$WORK/source-anchors.json` — **≥5 anchors, EXACTLY as printed**
     (every KPI, the top-3 of each ranked list/table, one representative bucket
     per chart; schema: `refs/source-anchors.md`). Land the source page PNG at a
     path the gate discovers so the bar arms: set it as `source_png` in
     `png-read.json`, **or** copy it to `$WORK/dashboards/source.png` (the export
     already lands per-page `visual-qa/powerbi-page{N}.png` — copy the matching page).
     Then verify against the live workbook:
     `ruby scripts/verify-anchors.rb --workdir $WORK --workbook-id <wbId>` → `anchors-verdict.json` (must pass).
   - **Visual-similarity floor.** `"$PY" scripts/visual-similarity.py --source <sourcePagePng> --render $WORK/visual-qa/sigma-<page>.png --json-out $WORK/visual-similarity.json` — a deterministic ink/layout floor beneath the human compare.
   A genuinely stale or untranscribable source is waived at the Phase-6 gate with
   `--skip-anchors-gate`/`--skip-visual-similarity "<reason>"` (waiver-budgeted). See `refs/source-anchors.md`, `refs/visual-similarity.md`.

Layout escalation if the compare fails on arrangement: the builder's default
`--layout clean` preserves the source positions inside a normalized grid; use
`--layout pbi` for literal 1:1 canvas geometry; `--layout banded` is legacy.

## Phase 5f — Visual QA (mandatory gate — never skip)
A workbook that POSTs 200 and passes numeric parity can still be visually broken — **overlapping tiles, clipped KPI titles, dead zones, filters floating over charts.** Power BI free-form/absolute visual coords float over each other and Sigma's grid has no z-order; the shared layout lib now de-overlaps bands (`decollide_bands`), but this visual gate is the safety net.

1. Render every page to PNG: `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600` (or use `scripts/assert-visual-compare.rb` for source-vs-target).
2. **Read each PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking, no dead zones, controls in their own band, no clipped titles, even heights, right chart kind/format).
3. Fix any failure in the spec — for multi-page workbooks use the companion **sigma-workbooks** skill's `scripts/wb-rep.rb` (full-clone: `plugins/sigma-authoring/skills/sigma-workbooks/scripts/wb-rep.rb`; pull → edit → push) — then **re-render and re-read**.
4. Declare the migration done on a **clean render**, not on HTTP 200.

## Phase 6 — Verify (mandatory)
- `sigma-mcp-v2 query` each element → confirm real rows (not blank).
- **Two ways to get the `expected` (source-of-truth) side — pick by whether you can reach Power BI online:**
  - **Warehouse-SQL oracle (DEFAULT for warehouse-backed models — OFFLINE, no Power BI):** the warehouse is what BOTH PBI and Sigma read, so the aggregate computed directly in SQL is a valid independent expected value. No `api.powerbi.com`, Entra app, or workspace/dataset id.
    ```
    ruby scripts/build-oracle-sql.rb --in oracle-input.json --out chart-oracle-sql.json   # DAX→SQL (aggregate measures); --dm-spec seeds fqn
    # run each `sql` via mcp__sigma-mcp-v2__query {type:connection, connectionId:<the DM's conn>} → save rows to parity-expected.json
    ruby scripts/phase6-parity-pbi.rb --local-sql --expected parity-expected.json --workbook-id <wb> --out plan.json
    # collect Sigma actuals (one MCP query per chart) → parity-actuals.json, then --finalize (below)
    ```
    `build-oracle-sql.rb` covers SUM/AVG/MIN/MAX/COUNT/DISTINCTCOUNT/COUNTROWS + DIVIDE with an optional GROUP BY; anything else (RANKX/CALCULATE/time-intel) is flagged `supported:false` → use the online path or waive it. **Pass an explicit `column_map`** when columns are renamed/auto-named (`Table.PromoteHeaders` → C1/C2, see `pbi-dm-signature.py`); without one it falls back to a NAME→UPPER_SNAKE heuristic and warns.
  - **Online DAX (high-fidelity / import-only models):** PBI `POST /v1.0/myorg/groups/{ws}/datasets/{id}/executeQueries` (DAX) via `--emit-dax`, vs the same Sigma aggregation. DAX-only; breaks under service-principal if RLS; needs the workspace/dataset (auto-wired from `freshness.json`).
    - **XMLA fallback (when `executeQueries` REST is blocked but the model is on capacity):** run the same measure through the Power BI Modeling MCP — `dax_query_operations Execute` on an `Initial Catalog`-bound connection — and diff against the Sigma actuals identically. Recipe in `refs/pbi-modeling-mcp.md`. This also catches **silently mis-modeled source measures** (e.g. time-intel over an inactive date relationship returns a flat total in Power BI) that a SQL oracle wouldn't flag.
- **Finalize (both paths):** `ruby scripts/phase6-parity-pbi.rb --finalize --plan plan.json --actuals parity-actuals.json --out-dir <dir>` → writes `parity-final.json` (`source` records which oracle was used).
- Hard gate: `ruby scripts/assert-phase6-ran.rb --workdir <dir> --workbook-id <wb>` — incl. layout lint (6), **control lint (7**: dead controls / ghost targets / partial same-page reach / `control-scope.json` coverage; `--skip-control-lint` escape; see `refs/control-parity.md`**)**, and the MEASURED bars wired in Phase 5e: **gate 13 (source-anchor values** — arms when a source PNG is on disk; needs `source-anchors.json` ≥5 + a passing `anchors-verdict.json`; `--skip-anchors-gate "<reason>"`**)** and **gate 14 (visual-similarity floor** — `visual-similarity.json`; `--skip-visual-similarity "<reason>"`**)**. No source PNG on disk → both self-SKIP (stated), never a silent pass.
- Optional flip test when the report has slicers→controls: `ruby scripts/probe-controls.rb --workbook-id <wb> --check-out-of-closure` — runtime proof a control actually filters (in-closure export changes under a non-default `parameters` value, out-of-closure doesn't). MCP query can NOT flip controls (defaults only) — export API `parameters` is the only mechanism.

## Phase 7 — Bookmarks → per-bookmark workbooks (optional)
PBI bookmarks that **show/hide** or **spotlight** visuals map to Sigma as a
workbook over the bookmark's *visible subset*:
```
python3 scripts/extract-bookmarks.py --pbir-dir /tmp/pbir --out $WORK/bookmarks.json   # or --report-json (classic)
python3 scripts/build-bookmark-workbooks.py --signals $WORK/signals.json \
  --bookmarks $WORK/bookmarks.json --master-map $WORK/master-map.json \
  --data-model <dmId> --folder-id <uuid> --name-prefix "<Report>" --out-dir $WORK/bm
# then POST each $WORK/bm/<name>/workbook-spec.json + put-layout
```
- `extract-bookmarks.py` normalizes each bookmark → `{hidden[], spotlight[], filters_raw}` (reads `definition/bookmarks/*.bookmark.json` shape: `explorationState.sections.<p>.visualContainers.<v>.singleVisual.display.mode` = hidden|spotlight|maximize).
- spotlight → keep ONLY the spotlighted visuals (focus); else all-minus-hidden. The all-visible bookmark = the base workbook.
- **Filter-state bookmarks** (`filters_raw:true`): the `explorationState` filter JSON isn't auto-applied — bake those values as element `filters` / control defaults per the agent's judgment.
- Validated 2026-06-02 on Retail Trends: Overview(8)/KPIs-Only(3)/Trend-Spotlight(1) → 3 workbooks, screenshot-verified.
- `build-bookmark-workbooks.py` is **shared** (lives in `tableau-to-sigma/scripts`, symlinked here) and **vendor-neutral**: `--build-script` selects the signals→workbook builder; a normalized state's `filters: {col:[vals]}` is baked as a `list` filter (`{columnId, kind:list, mode:include, values}`) onto the Data-page **master** so every chart inherits it (page-filter semantics — verified end-to-end). Tableau's analog (Custom Views) feeds the same builder via `tableau-to-sigma/scripts/extract-custom-views.py` — note: Tableau REST exposes custom-view *metadata* only, not filter *values* (opaque state), so Tableau filter recovery needs the view-data-diff technique.

## Phase E (opt-in) — Enhance

**OFF by default, everywhere.** Phase E never runs in batch/headless mode
without the explicit `--enhance` flag on `migrate-powerbi.rb`, and it only
ever starts from a **parity-verified** workbook (Phase 6 PASS). Full contract
(design interview, detectors, layout checklist): `refs/phase-e-enhance.md` +
`refs/app-recommendation-signals.md`. Shared engine:
`enhance-scan.rb` / `enhance-select.rb` / `enhance-app-plan.rb` /
`enhance-apply.rb` + `scripts/lib/enhance_options.rb`.

```bash
ruby scripts/migrate-powerbi.rb ... --yes \
  --enhance                       # scan only → exit 14 with proposals
# run the design interview (refs/phase-e-enhance.md), then:
ruby scripts/enhance-select.rb --enhancements <workdir>/enhancements.json \
  --option <option-id> --out <workdir>/enhance-selection.json
ruby scripts/migrate-powerbi.rb ... --yes \
  --enhance --enhance-accept "$(ruby scripts/enhance-select.rb \
    --enhancements <workdir>/enhancements.json \
    --option <option-id> --print-accept)"
```

Power BI–specific detector notes (on top of the shared catalog):

- **grain switcher** restores the PBI date-hierarchy drill intent.
- **map restoration** — a map that genuinely lacks coordinates and a
  region-typed field, and was therefore approximated as a bar, can become a
  point-map with `Switch()` centroid synthesis (medium risk; centroids must
  be filled into the patch before apply). Azure Maps with bound `X`/`Y`
  coordinates already become point maps during the normal Phase 5 build.
- **freshness note** is fed by the Phase 2.5 freshness preflight
  (`freshness.json`).
- DM-metric promotion is not an enhancement candidate here: the normal
  workbook build already binds formula-equivalent metrics through
  `[Metrics/<metric name>]`.

**Phase 7 Bookmarks** remain a separate post-parity path — do not fold them
into Phase E.

### Phase E layout placement + HARD screenshot checklist

Follow the shared checklist in `refs/phase-e-enhance.md` (container bands,
layout lint exit 4, full-page PNG gate). The "PHASEE PBI Employee Dashboard"
regression is why every applied item lands in the container system — never
appended at the page foot.
## Reverse direction — author INTO Power BI
The Fabric API is symmetric: `POST .../semanticModels` (TMSL parts) + `POST .../reports` (PBIR) create live items. Same device-code token (`user_impersonation` covers writes). Needs a Fabric-capacity workspace. See `scripts/fabric-auth-check.py` for the write-capability/capacity check.

## Scripts — the conversion pipeline
The conversion is script-driven (mirrors `tableau-to-sigma/scripts/`). `scripts/run.sh` orchestrates connect → extract → convert → post-DM → build-workbook → layout → parity; it runs every deterministic stage and STOPS at the two MCP gates (the `convert_powerbi_to_sigma` conversion and the `sigma-mcp-v2` actuals collection) with a clear instruction, then resume any stage with `--from <stage>`. All scripts are idempotent and re-run-safe.

**Python prereq:** the Microsoft-auth scripts (`fabric-extract.py`, `extract-pbir.py` live-fetch, `phase6-parity-pbi.rb`'s DAX harness) need `msal` + `requests` + `truststore` — pinned in `scripts/requirements.txt`. The LOCAL `.pbix` model front door (`extract-model-pbix.py` / `migrate-powerbi.rb --pbix`) additionally needs **pbixray** — NOT in `requirements.txt` because its `xpress9`/`xmhuffman` deps ship broken sdists and must be built from source (see `refs/local-pbix.md`; `doctor.sh` reports its presence + the install command). Everything else (including `extract-report-classic.py --pbix`) is stdlib-only. `run.sh` **bootstraps a venv at `<work-dir>/.venv` automatically** when no suitable interpreter is found; override with `$PBI_PY` (or `migrate-powerbi.rb --python`). **Converter — zero-config, local, no MCP.** A self-contained converter bundle ships in the skill at `converter/powerbi.mjs` and is the default: `migrate-powerbi.rb` runs `convertPowerBIToSigma` in-process via a `node` shim with no clone, no `npm install`, no network, no MCP. A dev's own build still wins via `--mcp-dir`/`$PBI_MCP_DIR` (or `~/Desktop/sigma-data-model-mcp`, `~/sigma-data-model-mcp`). Refresh the bundle with `tools/vendor-converters.sh`. Only if the bundle is **also** absent does it gate (exit 10) with instructions to run the `convert_powerbi_to_sigma` MCP **tool** and resume with `--converter-out`.

| Script | Stage | What it does |
|---|---|---|
| `pbi_fabric.py` | 1 (shared lib) | FAST-DISCOVERY layer: cached token, **0.5s-first + backoff LRO polling**, pooled concurrent `getDefinition` (cap 4/principal), **8-wide estate enumeration** + `/tmp/pbiauth/estate-map.json` session cache (auto-invalidated on name miss), per-task `timings.json`. |
| `fabric-extract.py` | 1 extract | Model TMSL **and** (`--report`) the report definition fetched CONCURRENTLY; `--workspace <id\|name>` skips estate enumeration; `--report-bundle` emits the `migrate-powerbi.rb --pbir` flat bundle. Measured 46.3s → 3.6-5.1s. |
| `fabric-extract-batch.py` | 1 batch | Fleet extraction: every requested report → 2 artifact tasks (model TMSL + report def) on ONE 4-wide pool; report→model binding via PBI REST `datasetId` (name-match fallback); `manifest.json` + `timings.json`. 3 reports = 7.5s measured. |
| `extract-pbir.py` | 1 extract | Fetch a report's PBIR (or parse one already on disk) → normalized `signals.json` (per-visual `sigma_kind` + role bindings + x/y/w/h). Live fetch uses the `pbi_fabric` fast LRO path. The PBI analog of `parse-twb-layout.rb`. |
| `extract-report-classic.py` | 0/1 extract | Normalizes a CLASSIC single-file report layout → the same `signals.json` schema. Inputs: `--report-json` (UTF-8, Fabric getDefinition), **`--pbix <file>`** (unzips the zip's UTF-16LE `Report/Layout`), or **`--report-layout <file>`** (an extracted Layout). The dependency-free LOCAL report front door — no Fabric. |
| `extract-model-pbix.py` | 0 extract | LOCAL model front door: reads a `.pbix`'s binary VertiPaq `DataModel` with **pbixray** and emits a TMSL `model.bim` (schema→columns, dax_measures→measures, dax_columns→calc cols, dax_tables→calculated partitions, relationships, power-query M→partitions). Exits with a clear "pbixray required" install hint if it's absent. Setup: `refs/local-pbix.md`. |
| `pbi-freshness.py` | 1.5 preflight | SOURCE-FRESHNESS: refresh history (incl. FAILED/creds-expired refreshes) + cheap executeQueries row-count/max-date snapshot (**4-wide parallel per-table probes**) → `freshness.json`. Launched **non-blocking** by run.sh/migrate-powerbi.rb (consumed at parity). Leads the parity output; deltas classify MATCH / STALE-EXPLAINED / DIVERGENT (bead fmte). |
| `export-pbi-pages.py` | 5e compare | SOURCE page renders via ExportToFile (PNG → PDF fallback, **PDF rasterized to per-page PNG** via pypdfium2 so `Read` needs no poppler) for the mandatory visual compare; `--tenant` for guest/B2B; soft-fails (exit 3) with a waiver hint when export is unavailable instead of crashing. |
| `sigma-export-png.py` | 5e/5f compare | Renders a built Sigma page to PNG (`--workbook <id> --page <pageId> --out … --w 1600`) for the source-vs-target compare AND the Phase 5f Visual QA read (checked against `refs/layout-visual-qa.md`). |
| `assert-visual-compare.rb` | 5e gate | HARD GATE: blocks Phase 6 unless visual-compare.json has a PASS/ACCEPTED verdict (with explained deltas) for every content page. |
| `convert-model.rb` | 2–3 convert/post | MODE A prints the exact `convert_powerbi_to_sigma` MCP call for a `model.bim`; MODE B takes the converter output and applies the 3 fixups (schemaVersion + folderId/ownerId via a ref-DM harvest + base-element names) → postable DM spec. |
| `build-workbook-from-pbir.rb` | 4 build | `signals.json` + a `master-map.json` → full workbook spec + 24-col layout XML. Applies the measure-translation patterns in `refs/measure-patterns.md`; **line charts default to a single series** (`beads-sigma-c07`) unless PBI bound a Series/Legend role. **Carries the PBI visual sort** (`f972` — PBIR `query.sortDefinition` / classic `prototypeQuery.OrderBy` → chart `xAxis.sort`/`color.sort`; grouped table → `groupings[0].sort` — element-level sort is rejected on grouped tables). Analog of `build-charts-from-signals.rb`. **Writes `coverage.json`** (`--coverage-out`): every dropped/degraded/approximated component aggregated (Phase 5c) — nothing silently dropped. |
| `phase6-parity-pbi.rb` | 7 parity | executeQueries(DAX) adapter: `--emit-dax` runs the PBI side and writes the parity plan's `expected` rows; `--finalize` injects Sigma actuals and runs the shared `verify-parity.rb`. The PBI analog of Tableau's view-CSV parity adapter. |
| `enhance-scan.rb` | E scan (opt-in) | **Phase E — SCAN (read-only).** Source signals + built spec + live exports → `enhancements.json` (`candidates`, `app_options`, `signals`, descoped notes). |
| `enhance-select.rb` | E select (opt-in) | **Phase E — SELECT.** Design-interview answer → `enhance-selection.json` / `--print-accept` list for apply. No Sigma writes. |
| `enhance-app-plan.rb` | E plan (opt-in) | **Phase E — APP PLAN.** Archetype option + architecture choices → `app-plan.json` (validate with `schemas/app-plan.schema.json`). No Sigma writes. |
| `enhance-apply.rb` | E apply (opt-in) | **Phase E — APPLY (accept-only, clone-first).** Clones `"<name> — Enhanced"`, applies `--accept`-ed candidates one at a time with parity-unchanged spot-check. |

The agent authors one PBI-specific artifact: `master-map.json` (maps each PBI Entity → a Data-page master element and each `Entity.Field` queryRef → `{ref, agg}`), which encodes the DM element ids + DAX-measure→Sigma-aggregator decisions. Everything else is mechanical.

**DM metric references (leverage the semantic layer, don't duplicate it).** `migrate-powerbi.rb` attaches each master's DM metrics (name + original bare formula) to `master-map.json`, and `build-workbook-from-pbir.rb`'s `measure_formula` prefers a governed **`[Metrics/<name>]`** reference over its inline aggregate when they match by formula equivalence (strip the master `id` prefix so `CountDistinct([master-emp/Headcount])` equals a metric's `CountDistinct([Headcount])`) — via the shared binder `scripts/lib/metric_binding.rb`. SAFE: chained/ratio metrics (migrate inlines them with parens), implicit column aggregations with no matching metric, and any non-match fall back to inline; a master with no metrics is byte-identical. Verified: `scripts/test-metric-reference.rb`.

**Validated unattended end-to-end 2026-05-31** against the KitchenSink (PBI report/model pair on the demo warehouse): `run.sh` drove extract → convert (MCP gate) → post-DM (26 cols, 0 errors) → build → post-WB → **layout** into a throwaway DM + workbook in the demo Sigma org. `assert-phase6-ran.rb` passed all 4 gates: **0 `error` columns** (34 live cols), grouped `Department Summary` table (6 depts, real ranked rows), **single-series** YTD line (2025 Jul–Dec = `3536,7412,10932,14700,18080,21844`, parity-exact vs PBI), pivot with `rowsBy`/`values`, and a 12-element grid layout that **survived the final write** (no single-column wipe). Throwaway items deleted after.

> **Phase 5 time-intelligence tradeoff (`beads-sigma-c07`):** the builder emits PBI line charts as a **single series** (`xAxis`=month, `yAxis`=`CumulativeSum(Sum(...))`, **no `color` block**). A continuous `CumulativeSum` reproduces a within-year YTD exactly (2025 matched PBI to the unit) but does NOT reset at the Jan year boundary. For a true `TOTALYTD` per-year-reset on one line, precompute a year-partitioned YTD in a hidden grouped level table and plot it with `Max()` (recipe in `refs/measure-patterns.md §4`). Never reproduce the reset by adding `color:{by:category,column:year}` — that renders TWO lines, diverging from PBI's one.

## Reuse, don't reinvent (and packaging)
These vendor-agnostic Sigma-side scripts are reused: `get-token.sh`, `lib/sigma_rest.rb`, `post-and-readback.rb`, `put-layout.rb`, `find-or-pick-dm.rb`, `validate-spec.rb`, `verify-parity.rb`, `cleanup-orphan-workbooks.rb`. In the repo they are **symlinks** into `tableau-to-sigma/scripts/` (DRY), but symlinks break when the skill is downloaded standalone — so always ship via **`./package.sh`**, which dereferences every symlink into a real file and vendors the out-of-tree reference docs into `refs/vendored/`. The result (`dist/powerbi-to-sigma/`) is fully self-contained: 0 symlinks, the whole pipeline runs from inside the bundle. The shared core is being extracted to `sigma-conversion-core` (`beads-sigma-6k9`); until then, package before distributing.


## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_powerbi_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for Power BI:** `model.roles[].tablePermissions[].filterExpression` (DAX RLS to attribute/team/email) and `columnPermissions` object-level security (to CLS). Role MEMBERSHIP is bound in the Power BI Service (not the model file) — assign it in Sigma.

**Flow (only runs when `result.security` is non-empty — zero overhead otherwise):**
1. **Convert + post** the data model as usual. Capture the `dataModelId` and the converter's `result.security[]` (write it to `security.json`).
2. **Gate (opt-in/out, default _Port_).** Show a plain-English summary of each detected rule + recommended Sigma mapping, then ask: **Port** (recommended) / **Customize** (review per-rule attribute/team mapping + username-to-email reconciliation) / **Skip** (migrated model shows ALL rows to everyone). Reuse-first: existing Sigma user attributes/teams are matched before creating new ones.
3. **Provision + apply** with the shared engine:
   ```bash
   eval "$(scripts/get-token.sh)"
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId>            # plan only (default)
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId> --provision --apply
   ```
   `--provision` creates missing user attributes / teams; `--apply` PATCHes the boolean RLS calc column + fail-closed `filters` entry and the `columnSecurities` (CLS) onto the matching element.
4. **Assign membership.** Assign per-user attribute values / team membership from the source tool's group/role membership (the converter reports the attribute/team names; the values come from the source's user mapping).

**Skip is loud:** opting out leaves the migrated model with NO RLS — all rows visible to everyone. Confirm before skipping.
