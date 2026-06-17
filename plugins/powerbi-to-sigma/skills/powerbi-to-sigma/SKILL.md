---
name: powerbi-to-sigma
description: Convert a Power BI report + semantic model into a Sigma data model and matching dashboard. Use when the user has a Power BI report (in Power BI Service / Fabric, or a .pbix/.pbit file) and wants to recreate it in Sigma. Covers connecting to Power BI with no Entra app, extracting the model (TMSL) + report layout (PBIR/Report-Layout), converting via the sigma-data-model MCP, posting the data model + workbook via REST, and parity verification. Can also author dashboards back INTO Power BI via the Fabric write API.
user-invocable: true
---

# Power BI → Sigma

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

> Status: **foundation** (validated end-to-end 2026-05-31 on the "Employee Dashboard" workforce report).
> Beads: build = `beads-sigma-cs2`; converter gaps = `j89` (M-Snowflake path), `tkd` (element names / schemaVersion / folderId).
> Defers to: `sigma-workbooks` (canonical workbook spec), `sigma-data-models` (DM spec), the `convert_powerbi_to_sigma` MCP tool, and `tableau-to-sigma/scripts/*` (reused verbatim for posting + layout + parity).

## What's proven (the happy path, validated once)
```
1. CONNECT   device-code login, well-known PowerBI-Desktop client, NO Entra app   → scripts/fabric-extract.py
2. EXTRACT   Fabric getDefinition?format=TMSL → model.bim   (+ .pbix Report/Layout for visuals)
3. CONVERT   convert_powerbi_to_sigma MCP (model.bim + connectionId + db/schema) → Sigma DM JSON
4. POST DM   fix spec (schemaVersion + folderId/ownerId + element names) → POST /v2/dataModels/spec
5. WORKBOOK  Data page (master tables per DM element) + chart elements → POST /v2/workbooks/spec
6. LAYOUT    PBIX/PBIR visual x,y,w,h → 24-col grid XML → put-layout.rb
7. VERIFY    sigma-mcp-v2 query each element returns real rows; Phase 6 = compare vs PBI executeQueries (DAX)
```

## Phase 1 — Connect (no Entra app required)
The corporate tenant blocks Entra app creation, Git integration, and XMLA (PPU). The working path:
- `scripts/fabric-extract.py` — device-code via well-known public client **`ea0616ba-638b-4df5-95b9-636659ae5121`** (Power BI Desktop), scope `https://api.fabric.microsoft.com/.default`. User signs in once at the device URL; token cached.
- **`truststore.inject_into_ssl()` is mandatory** (first line) — corp TLS inspection on `api.fabric.microsoft.com`; uses macOS keychain CA.
- See `refs/connection.md` for the full recipe + surprises (works on My-workspace, device-code not CA-blocked).

## Phase 2 — Extract (FAST DISCOVERY — designed for 30-50 workspace / 20-40 report estates)
- **Model**: `getDefinition?format=TMSL` (202 LRO → poll `Location`) → base64 `model.bim` part = the TMSL/TOM JSON the MCP eats. Works even on My-workspace.
- **One concurrent fetch, not two serial scripts.** The model TMSL and the report definition are INDEPENDENT artifacts — `fabric-extract.py --report <id|name> --report-out-dir DIR [--report-bundle PATH]` fires both `getDefinition` LROs concurrently (shared pool, **hard cap 4 per principal** — Fabric throttles getDefinition; >4 risks 429 long-tails). LRO polling is **0.5s-first + backoff (1s, 2s, then Retry-After capped at 4s)** instead of sleeping the full Retry-After before the first status check — Fabric routinely advertises `Retry-After: 20` for definitions that are ready in <2s. `--report-bundle` writes the flat `{part: text}` JSON that `migrate-powerbi.rb --pbir` accepts directly.
- **Skip estate enumeration when you know the workspace** (you usually do): `--workspace <id|name>`. A workspace ID is 2 cheap GETs; the old serial walk of every workspace was 15-30s at 30-50 workspaces. Without `--workspace`, enumeration fans out **8-wide** (cheap metadata GETs, not LROs) → **~2-3s** for a 30-50 ws estate, and the result is **session-cached** at `/tmp/pbiauth/estate-map.json` (override `PBI_ESTATE_CACHE`), invalidated automatically on any name miss; `--no-cache` bypasses.
- **Measured (live, 2026-06-11, EMPLOYEE DASHBOARD)**: old serial path (fabric-extract + extract-pbir) = **46.3s**; new concurrent fetch = **5.1s cold / 3.6-3.9s warm-cache** — byte-identical output parts. Every run writes a per-task **`timings.json`** to `--out-dir` (the evidence trail; always emitted).
- **Batch / fleet extraction** (the assessment path): `fabric-extract-batch.py --reports "A,B,C" [--workspace W] [--all] --out-root DIR --pool 4` flattens each report into two artifact tasks (model TMSL + report definition) and pools them 4-wide; each report's bound model resolves via the Power BI REST `datasetId` (name-match fallback). Measured: 3 reports (6 artifacts) = **7.5s wall** vs ~16s serial-equivalent fast-polling and **~2.3 min** on the old per-report serial path. Output per report: `model/`, `report/`, `report-bundle.json` + a root `manifest.json` and `timings.json`.
- **Layout**: a `.pbix` is a zip; `Report/Layout` is **UTF-16LE** JSON with per-visual `x,y,w,h` (canvas px, 1280×720 default). The model in a `.pbix` is a *binary* `DataModel` blob — NOT usable; get the model via getDefinition or a `.pbit`'s `DataModelSchema`.
- See `refs/powerbi-visual-layout.md` for the Report/Layout & PBIR parsers and the visualType→Sigma-kind table. The shared fetch layer (token, fast LRO, pooled fetch, estate cache, timings) lives in `scripts/pbi_fabric.py`.

## Phase 2.5 — SOURCE-FRESHNESS PREFLIGHT (import-mode models, bead fmte)
Import-mode PBI models are **frozen snapshots**; Sigma reads the LIVE warehouse. Before any parity side-by-side, capture the dataset's freshness so staleness deltas are called out UP FRONT (mirrors qlik-to-sigma Phase 1.5):

```bash
"$PY" scripts/pbi-freshness.py --workspace <wsId|me> --dataset <datasetId> \
  --tmsl model.bim --out $WORK/freshness.json
```

Pulls the refresh history (`GET datasets/{id}/refreshes` via the cached token) — last successful refresh + **FAILED refreshes** (expired warehouse creds are the classic cause; surfaced loudly) — plus a cheap `executeQueries` row-count/max-date snapshot per table (the per-table probes run **4-wide in parallel** — a 6-table model snapshots in one round-trip's wall time). The preflight is **NON-BLOCKING**: it is only CONSUMED at Phase 6/7 parity, so `run.sh` (stage 1.5) and `migrate-powerbi.rb` (Phase 1.5) launch it as a **background lane concurrent with Convert/Build** and join it (replaying its log) right before parity — 3-8s of Power BI round-trips off the critical path. A run that stops at a gate leaves the detached probe to finish; the resume run reuses the written `freshness.json`. Phase 6/7 parity is then **LED by the staleness banner**, and deltas classify **MATCH / STALE-EXPLAINED / DIVERGENT — only DIVERGENT blocks** (a "Sigma shows more data" delta on a stale snapshot is explained, not a conversion error). `migrate-powerbi.rb` also always writes per-phase **`timings.json`** and prints a `PHASE TIMINGS` line at every terminal exit.

## Phase 3 — Convert (MCP)
`convert_powerbi_to_sigma(model_json, connection_id, database, schema)`.

> ⚠️ **`--converter-out` takes the MCP converter's output — never a hand-authored spec.**
> The flag exists so you can run the `convert_powerbi_to_sigma` MCP tool, save its
> result, and resume the pipeline with it (`convert-model.rb --converter-out <that file>`).
> It is **not** an invitation to write `dm-raw.json` by hand. Hand-authored specs skip
> the converter's column-name/SQL/formula-prefix guarantees and reliably produce
> `Missing "kind" field`, `source.statement: undefined`, and `dependency not found`
> errors (validate-spec.rb now catches the first two, but the right fix is to feed it
> real converter output). If the MCP tool is unavailable, STOP and gate — don't fabricate.

- DAX measures → Sigma metrics. ~70% mechanical; see `refs/dax-to-sigma-coverage.md` and `fixtures/MANIFEST.md` (test oracle: 94 DAX expressions bucketed a/b/c).
- **PromoteHeaders**: if `pbi-dm-signature.py` reports `promoted_header_tables` (the model's M-query used `Table.PromoteHeaders`), the warehouse table's real columns are auto-named (`C1`, `C2`, …) with the semantic names in row 0 — the TMSL `sourceColumn` names will NOT resolve. Verify the landed table's real columns and remap with `convert-model.rb --table-map` (in Sigma formulas the columns appear as `C 1`, `C 2`, … and in JOIN SQL alias them, e.g. `c.C2 AS CUSTOMER_NAME`).
- **Known gap `j89`**: the Snowflake `Snowflake.Databases(...) + Navigation` M pattern isn't parsed → pass `database`/`schema` explicitly until fixed.
- **DAX gaps → gap-scout**: for measures the converter buckets `b` (restructure) or `c` (no-equivalent) — `RANKX`, `ALLEXCEPT`, `SUMMARIZE`, `USERELATIONSHIP`, `PATH*` — spawn the **gap-scout** sub-agent (`scripts/gap-scout.md`): it proposes a Sigma translation, validates it against the live API (`scripts/scout-validate.py`), and persists the rule to `~/.powerbi-to-sigma/learned-rules.yaml` (loaded by `scripts/learned-rules.py`) so future conversions auto-apply it. Time-intelligence (YTD/SPLY) is usually translatable — see `refs/measure-patterns.md`, not the scout.

## Phase 3.5 — Reuse an existing DM? (avoid sprawl — mirrors tableau Phase 1.5)
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
Then: `tableau-to-sigma/scripts/post-and-readback.rb --type datamodel`. See `refs/spec-fixups.md`.

## Phase 5 — Build the workbook
- **Data page**: one hidden `table` master per DM element used (`source: {kind:data-model, dataModelId, elementId}`, columns `[ElementName/Col]`).
- **Chart elements** source from a master (`source:{kind:table, elementId:<master>}`), columns `[dim, meas]`:
  - bar/line: `xAxis:{columnId}`, `yAxis:{columnIds:[...]}`
  - pie/donut: `color:{id}`, `value:{id}`
  - text: `{kind:text, body:"## ..."}`
  - measure formula wraps the master col: `CountDistinct([Master/Col])`, `Sum([Master/Col])`, date dim `DateTrunc("month",[Master/Col])`.
- `POST /v2/workbooks/spec` (post-and-readback `--type workbook`). Chart-element shapes mirror `tableau-to-sigma/scripts/build-charts-from-signals.rb`.

## Phase 5d — Layout (do NOT skip — stacked ≠ done)
Map each visual's `x,y,w,h` → 24-col grid (`COL_UNIT = page_w/24`, `ROW_UNIT ≈ 30`) → single top-level `layout` XML (one `<Page>` per page, server page IDs) → `tableau-to-sigma/scripts/put-layout.rb`. Math + snap rules in `research/powerbi-visual-layout.md §4`.

## Phase 5e — VISUAL COMPARE vs the SOURCE (MANDATORY — numbers lie about looks)
Phase 6 proves the NUMBERS; this phase proves the PAGES. A conversion shipped
with exact query parity and still looked broken (collapsed KPIs, stacked bars
that should be clustered, alphabetical months) — caught only by putting full
pages next to the Power BI renders. Do this BEFORE Phase 6, every run:

1. Export the SOURCE pages: `"$PY" scripts/export-pbi-pages.py --report <reportId> --out-dir $WORK/visual-qa`
   (PNG is commonly tenant-disabled — the script falls through to PDF; per-page when pypdf is installed).
2. Export EVERY Sigma page: `"$PY" scripts/sigma-export-png.py --workbook <wbId> --page <pageId> --out $WORK/visual-qa/sigma-<page>.png`.
3. **Read both images for each page, side by side.** Check, per page: same
   elements in the same spots; charts show MARKS (not just axes); clustered vs
   stacked matches the source; axis order (months Jan→Dec, not alphabetical);
   KPI tiles show value AND label; no giant decorative text; no dead bands.
4. Write `$WORK/visual-qa/visual-compare.json`: `[{page, verdict: PASS|ACCEPTED|FAIL, deltas: ["…"]}]`
   — ACCEPTED means the user explicitly OK'd a listed delta (e.g. zip
   choropleth instead of PBI's bubble map; theme colors). FAIL = fix and re-export.
5. Gate: `ruby scripts/assert-visual-compare.rb --dir $WORK/visual-qa --signals $WORK/signals.json`
   must print GREEN before Phase 6 may be declared.

Layout escalation if the compare fails on arrangement: the builder's default
`--layout clean` preserves the source positions inside a normalized grid; use
`--layout pbi` for literal 1:1 canvas geometry; `--layout banded` is legacy.

## Phase 5f — Visual QA (mandatory gate — never skip)
A workbook that POSTs 200 and passes numeric parity can still be visually broken — **overlapping tiles, clipped KPI titles, dead zones, filters floating over charts.** Power BI free-form/absolute visual coords float over each other and Sigma's grid has no z-order; the shared layout lib now de-overlaps bands (`decollide_bands`), but this visual gate is the safety net.

1. Render every page to PNG: `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600` (or use `scripts/assert-visual-compare.rb` for source-vs-target).
2. **Read each PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking, no dead zones, controls in their own band, no clipped titles, even heights, right chart kind/format).
3. Fix any failure in the spec — for multi-page workbooks use `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) — then **re-render and re-read**.
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
- **Finalize (both paths):** `ruby scripts/phase6-parity-pbi.rb --finalize --plan plan.json --actuals parity-actuals.json --out-dir <dir>` → writes `parity-final.json` (`source` records which oracle was used).
- Hard gate: `ruby scripts/assert-phase6-ran.rb --workdir <dir> --workbook-id <wb>` — 7 gates incl. layout lint (6) and **control lint (7**: dead controls / ghost targets / partial same-page reach / `control-scope.json` coverage; `--skip-control-lint` escape; see `refs/control-parity.md`**)**.
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
ever starts from a **parity-verified** workbook (Phase 6 PASS). It is powered
by the shared engine vendored byte-identically into the covered plugins
(`scripts/enhance-scan.rb` + `scripts/enhance-apply.rb` — md5 discipline,
same as `escalate-gap.py`).

```bash
ruby scripts/migrate-powerbi.rb ... --yes \
  --enhance                       # scan only → exit 14 with proposals
# present each candidate to the user (one AskUserQuestion checklist), then:
ruby scripts/migrate-powerbi.rb ... --yes \
  --enhance --enhance-accept all-low-risk    # or: id1,id2,...
```

The contract (trial-validated, 2026-06-10):

1. **Clone-first.** `enhance-apply.rb` GETs the parity workbook's spec and
   POSTs it as `"<name> — Enhanced"`. The 1:1 parity artifact is **never
   written** (the report records its `updatedAt` before/after as proof).
2. **Scan-then-propose.** `enhance-scan.rb` reads source signals (workdir
   artifacts: `signals.json`, `freshness.json`) + the built spec + live
   element exports, and emits `enhancements.json` — each candidate
   `{id, category, evidence, proposed, risk, verdict_hint, patch}`.
   **Nothing applies without acceptance**: interactive runs present a per-item
   checklist (AskUserQuestion); headless runs pass `--enhance-accept id1,id2`
   or `--enhance-accept all-low-risk`.
3. **Apply + parity-unchanged gate.** Accepted items apply **one at a time**
   to the clone; after each, 2-3 untouched elements are spot-queried on the
   clone AND the original at the same instant (live-drift-proof) — any shift
   auto-reverts that item and flags it in `enhance-report.json`
   (applied/skipped/reverted + evidence).

Detector catalog (trial-validated; nothing speculative):

- **comparison-enrichment** — date-grouped master + revenue-like measure →
  latest-period KPI + delta-% KPI pair. KPI value columns INLINE the full
  `Sum(If(D = Max(D), v, Null))` expression — cross-column aggregate refs
  silently misevaluate in kpi-charts.
- **interactivity-recovery** — (a) list **selection controls** on
  reasonable-cardinality dims wired to the shared master (empty default =
  identical render); (b) **grain switcher** — segmented control + DateTrunc
  switch restoring the PBI date-hierarchy drill intent, default = parity
  grain; (c) **drill switcher** — segmented control + `If()` dimension switch
  where a finer dim exists (medium risk: heuristic hierarchy pairing);
  (d) **map restoration** — an `azureMap`/`filledMap` visual the migration
  approximated as a bar → point-map with `Switch()` centroid synthesis
  (medium risk: centroids must be filled into the patch before apply).
- **fidelity-polish** — null-bucket labeling (`Coalesce → "No <Dim>"`),
  month/date axis canonicalization (`MakeDate`; medium risk on multi-year
  sources — intentionally un-pools), stale-source freshness note (time-boxed
  wording, fed by the Phase 2.5 freshness preflight), title corrections from
  source captions.

**Descoped — emitted as propose-in-UI notes, never spec changes** (all
trial-proven spec-unsupported): DM-metric promotion (metric refs don't resolve
through a workbook table), chart-as-filter (`useAsFilter` silently dropped on
readback), pie percent labels (`valueFormat:'percent'` silently dropped).

### Phase E layout placement + HARD screenshot checklist

Every applied item lands in the **container system** — never appended at the
page foot (that was the "PHASEE PBI Employee Dashboard" regression):

- selection controls → the **control band** (created under the header if the
  clone lacks one);
- comparison KPIs → the **KPI band**;
- grain/drill switchers → a slim row **inside the container of the chart they
  drive**;
- migration/freshness notes → a **slim note band directly under the header**.

If the cloned parity workbook predates container layouts (no `<GridContainer>`
in its layout), `enhance-apply.rb` **regenerates a banded layout** for the
clone first (builder machinery, `scripts/lib/layout.rb`), then applies items.
The finalize runs the shared layout lint (`scripts/lib/layout_lint.rb`: no
raw-id display names, no controls outside containers, no dead zones, no
generic header-band title — "Page 1"/"Sheet N"/"Dashboard N" never titles a
dashboard; the header carries the promoted source title → source display
name → workbook name — and no band whose elements fill <60% of the grid
columns, KPI bands of ≤4 tiles exempt) and
**exits 4 on violations** — a lint-failing clone must be fixed and re-PUT
before the run may be declared done.

**HARD screenshot checklist (mandatory at finalize).** The lint is mechanical;
your eyes are the last gate. Export the clone's **full-page PNG**
(`scripts/sigma-export-png.py`) and verify EVERY item, listing each with
pass/fail in your report:

- [ ] every chart/control title is human-readable (no raw element ids)
- [ ] the page has a header band (dark, full-width, carrying the SOURCE title
      or display name — never a generic "Page 1")
- [ ] selection controls sit together in a control band near the top
- [ ] every control is adjacent to / inside the container of what it filters
      (grain/drill switchers INSIDE their chart's container)
- [ ] no orphan elements below the fold (nothing dumped at the page foot)
- [ ] no dead zones; row heights look even across each band

## Reverse direction — author INTO Power BI
The Fabric API is symmetric: `POST .../semanticModels` (TMSL parts) + `POST .../reports` (PBIR) create live items. Same device-code token (`user_impersonation` covers writes). Needs a Fabric-capacity workspace. See `scripts/fabric-auth-check.py` for the write-capability/capacity check.

## Scripts — the conversion pipeline
The conversion is script-driven (mirrors `tableau-to-sigma/scripts/`). `scripts/run.sh` orchestrates connect → extract → convert → post-DM → build-workbook → layout → parity; it runs every deterministic stage and STOPS at the two MCP gates (the `convert_powerbi_to_sigma` conversion and the `sigma-mcp-v2` actuals collection) with a clear instruction, then resume any stage with `--from <stage>`. All scripts are idempotent and re-run-safe.

**Python prereq:** the Microsoft-auth scripts (`fabric-extract.py`, `extract-pbir.py` live-fetch, `phase6-parity-pbi.rb`'s DAX harness) need `msal` + `requests` + `truststore` — pinned in `scripts/requirements.txt`. `run.sh` **bootstraps a venv at `<work-dir>/.venv` automatically** when no suitable interpreter is found; override with `$PBI_PY` (or `migrate-powerbi.rb --python`). No hardcoded developer paths: the local converter build resolves via `--mcp-dir`/`$PBI_MCP_DIR` (falling back to `~/Desktop/sigma-data-model-mcp`, `~/sigma-data-model-mcp`); without one, `migrate-powerbi.rb` gates with instructions to run the `convert_powerbi_to_sigma` MCP **tool** and resume with `--converter-out` (the default converter route).

| Script | Stage | What it does |
|---|---|---|
| `pbi_fabric.py` | 1 (shared lib) | FAST-DISCOVERY layer: cached token, **0.5s-first + backoff LRO polling**, pooled concurrent `getDefinition` (cap 4/principal), **8-wide estate enumeration** + `/tmp/pbiauth/estate-map.json` session cache (auto-invalidated on name miss), per-task `timings.json`. |
| `fabric-extract.py` | 1 extract | Model TMSL **and** (`--report`) the report definition fetched CONCURRENTLY; `--workspace <id\|name>` skips estate enumeration; `--report-bundle` emits the `migrate-powerbi.rb --pbir` flat bundle. Measured 46.3s → 3.6-5.1s. |
| `fabric-extract-batch.py` | 1 batch | Fleet extraction: every requested report → 2 artifact tasks (model TMSL + report def) on ONE 4-wide pool; report→model binding via PBI REST `datasetId` (name-match fallback); `manifest.json` + `timings.json`. 3 reports = 7.5s measured. |
| `extract-pbir.py` | 1 extract | Fetch a report's PBIR (or parse one already on disk) → normalized `signals.json` (per-visual `sigma_kind` + role bindings + x/y/w/h). Live fetch uses the `pbi_fabric` fast LRO path. The PBI analog of `parse-twb-layout.rb`. |
| `pbi-freshness.py` | 1.5 preflight | SOURCE-FRESHNESS: refresh history (incl. FAILED/creds-expired refreshes) + cheap executeQueries row-count/max-date snapshot (**4-wide parallel per-table probes**) → `freshness.json`. Launched **non-blocking** by run.sh/migrate-powerbi.rb (consumed at parity). Leads the parity output; deltas classify MATCH / STALE-EXPLAINED / DIVERGENT (bead fmte). |
| `export-pbi-pages.py` | 5e compare | SOURCE page renders via ExportToFile (PNG → PDF fallback; per-page split with pypdf) for the mandatory visual compare. |
| `sigma-export-png.py` | 5e/5f compare | Renders a built Sigma page to PNG (`--workbook <id> --page <pageId> --out … --w 1600`) for the source-vs-target compare AND the Phase 5f Visual QA read (checked against `refs/layout-visual-qa.md`). |
| `assert-visual-compare.rb` | 5e gate | HARD GATE: blocks Phase 6 unless visual-compare.json has a PASS/ACCEPTED verdict (with explained deltas) for every content page. |
| `convert-model.rb` | 2–3 convert/post | MODE A prints the exact `convert_powerbi_to_sigma` MCP call for a `model.bim`; MODE B takes the converter output and applies the 3 fixups (schemaVersion + folderId/ownerId via a ref-DM harvest + base-element names) → postable DM spec. |
| `build-workbook-from-pbir.rb` | 4 build | `signals.json` + a `master-map.json` → full workbook spec + 24-col layout XML. Applies the measure-translation patterns in `refs/measure-patterns.md`; **line charts default to a single series** (`beads-sigma-c07`) unless PBI bound a Series/Legend role. **Carries the PBI visual sort** (`f972` — PBIR `query.sortDefinition` / classic `prototypeQuery.OrderBy` → chart `xAxis.sort`/`color.sort`; grouped table → `groupings[0].sort` — element-level sort is rejected on grouped tables). Analog of `build-charts-from-signals.rb`. |
| `phase6-parity-pbi.rb` | 7 parity | executeQueries(DAX) adapter: `--emit-dax` runs the PBI side and writes the parity plan's `expected` rows; `--finalize` injects Sigma actuals and runs the shared `verify-parity.rb`. The PBI analog of Tableau's view-CSV parity adapter. |
| `enhance-scan.rb` | E scan (opt-in) | **Phase E part 1 — SCAN (read-only).** Source signals + built spec + live element exports → `enhancements.json` candidates `{id, category, evidence, proposed, risk, verdict_hint, patch}` + descoped propose-in-UI notes. Shared Phase-E engine, vendored byte-identical across plugins (md5 discipline). |
| `enhance-apply.rb` | E apply (opt-in) | **Phase E part 2 — APPLY (accept-only, clone-first).** Clones the parity workbook as `"<name> — Enhanced"` (1:1 artifact never written), applies ONLY `--accept`-ed candidates one at a time, each gated by an untouched-element clone-vs-original spot-check (auto-revert on shift). Writes `enhance-report.json`. Byte-identical twin of the tableau copy. |

The agent authors one PBI-specific artifact: `master-map.json` (maps each PBI Entity → a Data-page master element and each `Entity.Field` queryRef → `{ref, agg}`), which encodes the DM element ids + DAX-measure→Sigma-aggregator decisions. Everything else is mechanical.

**Validated unattended end-to-end 2026-05-31** against the KitchenSink (PBI report `0bebf272` / model `049863fa`, CSA.TJ): `run.sh` drove extract → convert (MCP gate) → post-DM (26 cols, 0 errors) → build → post-WB → **layout** into a throwaway DM + workbook in `tj-wells-1989`. `assert-phase6-ran.rb` passed all 4 gates: **0 `error` columns** (34 live cols), grouped `Department Summary` table (6 depts, real ranked rows), **single-series** YTD line (2025 Jul–Dec = `3536,7412,10932,14700,18080,21844`, parity-exact vs PBI), pivot with `rowsBy`/`values`, and a 12-element grid layout that **survived the final write** (no single-column wipe). Throwaway items deleted after.

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

