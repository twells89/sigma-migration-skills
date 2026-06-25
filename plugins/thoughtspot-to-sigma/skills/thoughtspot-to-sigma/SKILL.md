---
name: thoughtspot-to-sigma
description: Convert a ThoughtSpot model/worksheet and its Liveboards into a Sigma data model and matching dashboards. Use when the user has a ThoughtSpot instance (or exported TML) and wants to recreate it in Sigma. Covers discovery (TML export), data-model conversion, workbook build, layout, and parity verification driven by scripts/.
user-invocable: true
---

# ThoughtSpot → Sigma migration

## Preflight the workbook spec before POST (mandatory)

Before POSTing any workbook spec, run `ruby scripts/lib/preflight_lint.rb <spec.json>` — it exits 1 with a precise message on the two migration-killer bugs: a `table` with aggregate columns + dimensions but **no `groupings`** (renders raw detail rows), and a malformed `control` (missing `id`/`controlId`/`controlType` or nesting value fields under a `value` object instead of flat, a non-double-nested `source`, or a list control wired to neither `source` nor `filters` — a filters-only list control is valid). Fix every violation first — never POST past it, and **never conclude a feature is "unsupported" from an `Invalid kind` error** (it means the inner fields are wrong). Verified shapes: `sigma-workbooks` `controls.md` / `tables.md`.

## Phase 0 — Choose where to build (ask first when no destination given)

Don't silently land the migrated data model + workbook in an auto-picked folder.
If the user didn't supply a destination (no `SIGMA_FOLDER_ID`), ASK before building:

1. `python3 scripts/pick_destination.py list` → `{ workspaces, folders (editable, with parentName), myDocuments }`
2. Let the user pick ONE: a **workspace** (its `id` lands content in the workspace root),
   an existing **folder**, **My Documents** (when non-null — null for service tokens), or
   **create a new folder**: `python3 scripts/pick_destination.py create --name "<name>" [--parent <workspace-or-folder-id>]`
3. Export the chosen id as `SIGMA_FOLDER_ID=<id>`. `folderId` accepts a workspace id or a folder id.

If `SIGMA_FOLDER_ID` is already set, honor it silently — don't ask.

Recreate a ThoughtSpot **model/worksheet** as a Sigma **data model**, and its
**Liveboards** as Sigma **workbooks**, with parity verified against the live
warehouse.

## Auth
ThoughtSpot REST v2 needs `TS_HOST` + `TS_TOKEN`. On an SSO trial with no local
password, open `${TS_HOST}/api/rest/2.0/auth/session/token` in the logged-in
browser tab (or Develop → REST Playground) and copy the `token`. For a service
identity, enable Trusted Auth (Develop → Customizations → Security Settings) and
POST `username`+`secret_key` to `auth/token/full`. Sigma side uses
`SIGMA_BASE_URL` + `SIGMA_API_TOKEN` (vendored `scripts/get-token.sh`).
Trials often sit behind corp TLS — the Python helpers use an unverified SSL
context (curl uses the system store and works).

## ONE COMMAND (preferred): migrate-thoughtspot.py

The whole pipeline — discover → DM-reuse check → convert → DM → workbooks →
layout → **source-freshness preflight** → **scripted parity + hard gate** — as a
single command (mirrors qlik-to-sigma's `migrate-qlik.rb`). Gates are never
bypassed: the command exits non-zero if parity or `assert-phase6-ran.rb` fails.

```bash
export TS_HOST TS_TOKEN SIGMA_CONNECTION_ID TS_DB TS_SCHEMA   # + Sigma creds (token auto-minted from ~/.sigma-migration/env)
python3 scripts/migrate-thoughtspot.py --model <TS_MODEL_ID> [--liveboard <ID> ...] \
       [--name PREFIX] [--workdir DIR]
# offline (fixtures, no TS instance):
python3 scripts/migrate-thoughtspot.py --model-tml fixtures/retail-analytics-model.tml \
       --liveboard-tml fixtures/retail-analytics-liveboard.tml --workdir /tmp/ts-run
```

- **Decision points are flags with safe defaults, never silent:** the DM-reuse
  scan (step 2.5) runs automatically before convert and PRINTS the chosen
  candidate + score (or why none matched). The default is now **reuse-first** —
  it auto-reuses an existing DM that covers all the model's warehouse table(s)
  (and, through a score tie, a column-superset DM), collapsing duplicate-DM
  sprawl and skipping convert+POST. Opt out with `--no-reuse` (always build new)
  or pin a specific model with `--reuse-dm <id>`. The Sigma folder is
  auto-resolved and printed when `SIGMA_FOLDER_ID` is unset.
- **Freshness first:** before any side-by-side it prints the TS model/Liveboard
  modified times + a cheap `searchdata` aggregate probe vs a live warehouse
  snapshot (offline runs note the TS side unavailable), so staleness/model drift
  never masquerades as a conversion bug.
- **Parity is fully scripted:** ACTUAL = Sigma CSV export per chart; EXPECTED =
  `ts_lib.searchdata` ground truth (live) or a source-TML-derived re-aggregation
  of the master's warehouse rows (offline — agg from the TML's own
  `headline_aggregation`, independent of the builder). Then
  `phase6-parity-thoughtspot.rb --finalize` + `assert-phase6-ran.rb` run
  automatically.
- Exit codes: `0` GREEN · `3` MCP convert request emitted (call the tool, re-run
  with `--converted <workdir>/converted.json`) · `2` built but a gate FAILED ·
  `10`-free (no interactive checkpoint; RLS is reported by the converter and
  ported post-model via `apply_sigma_rls.py` as below). `--dry-run` = no Sigma
  POSTs (discovery + reuse scan + local convert / MCP request only).

## Manual phases: migrate.py (the per-phase pipeline the one-command wraps)
```
export TS_HOST TS_TOKEN SIGMA_BASE_URL SIGMA_API_TOKEN \
       SIGMA_CONNECTION_ID SIGMA_FOLDER_ID TS_DB TS_SCHEMA
python3 scripts/migrate.py --model <TS_MODEL_ID> [--liveboard <ID> ...] \
       [--name PREFIX] [--workdir DIR] [--reuse-dm <dataModelId>]
```
`migrate.py` runs the whole pipeline with **no hardcoded ids or paths** and
migrates every Liveboard that reads the model (or just the `--liveboard` ones).

### Discovery speed (customer scale — 20-40+ liveboard estates)
Liveboard selection used to **export every Liveboard TML in the org** serially
and grep for the model name — O(org-size), measured 19.2s on a 33-liveboard
trial org and linear from there (a 200-liveboard org ≈ 2 min per model).
Re-engineered 2026-06-11:
- **Dependency API first**: `ts_lib.dependents(model_id)` asks `metadata/search`
  (`include_dependent_objects`) which liveboards READ the model — verified live
  (13 candidates of 33 org liveboards) — so only candidates are exported.
- **Parallel + disk-cached TML export**: `ts_lib.export_tml_many()` exports
  candidates on a ThreadPool(4) with a disk cache keyed
  `(metadata_id, modified-epoch-ms)` (`$TS_TML_CACHE`, default
  `~/.sigma-migration/ts-tml-cache`; hits/misses logged). Measured:
  **19.2s → 1.7s cold / 0.2s warm**, and re-runs after the MCP-converter
  exit-3 resume are all cache hits.
- **Concurrent lane**: the selection + export runs as a lane UNDER convert +
  DM POST in `migrate.py` (joined before workbook builds), so on warm paths it
  costs ~0 wall-clock.
- **One keep-alive session per thread** (`http.client`): no per-request TLS
  handshake. (The TS Cloud edge WAF rejects UA-less requests with an HTML 403
  — `ts_lib` always sends a User-Agent.)
- **Fallback (patch point)**: when `dependents()` returns `None` (older TS
  builds without `dependent_objects` in `metadata/search`), `migrate.py`
  falls back to export-all-then-grep — still parallel + cached, but
  O(org-size), and it SAYS so. If a customer estate hits this, extend
  `ts_lib.dependents()` for their TS version (the patch point is marked in
  `collect_liveboards`, `scripts/migrate.py`).
All artifacts (manifest, TML, parity files) land in `--workdir`
(default `$TS_WORKDIR` or `./ts-migration`, created if missing). `--name` is a
prefix applied to BOTH the data model and every workbook; workbooks and pages
are named after the Liveboard's **display name** (resolved from its TML, never
the UUID).

**Converter paths** (no unvendored build required):
- `CONVERTER_PATH` set (a local `sigma-data-model-mcp` `build/thoughtspot.js`)
  → fully scripted one-shot via `convert_model.mjs`.
- `CONVERTER_PATH` unset → **MCP fallback**: migrate.py writes
  `<workdir>/model.tml` + `<workdir>/convert-request.json` (the exact
  `mcp__sigma-data-model__convert_thoughtspot_to_sigma` arguments), prints the
  instructions, and exits 3. Call the MCP tool, save its JSON output to
  `<workdir>/converted.json`, and re-run the same command with
  `--converted <workdir>/converted.json` to continue the pipeline.

**Offline mode** (no live ThoughtSpot needed): `--model-tml <file>` +
`--liveboard-tml <file>` read exported TML from disk — `fixtures/` ships a real
exported pair (`retail-analytics-model.tml` + `retail-analytics-liveboard.tml`,
the CSA.TJ retail star) so the full convert→post→build→layout path can be
exercised end-to-end without a TS trial:
```
python3 scripts/migrate.py --model-tml fixtures/retail-analytics-model.tml \
  --liveboard-tml fixtures/retail-analytics-liveboard.tml --workdir /tmp/ts-offline
```

## Pipeline (what migrate.py does)
1. **Discover** — `ts_discover.py [<id> <type>]` lists models + Liveboards or
   summarizes one (chart types, search queries, lineage). `metadata/search` +
   `metadata/tml/export`.
2. **Convert the model** — export the model TML and run it through
   `convert_thoughtspot_to_sigma` (`convert_model.mjs` imports the built converter;
   the browser tool / MCP also work). ThoughtSpot exports the **`model:`** format
   (joins inline on `model_tables[].joins[]`, `[TABLE::COL]` formula refs,
   `col.properties.column_type`) — the converter handles it. POST to
   `/v2/dataModels/spec`; then read the posted DM spec to find the denormalized
   **"<root> View"** element (surfaces joined-dim columns via `[base/REL/Field]`).
3. **Resolve columns** — `ts_common.build_resolver(model_root)` derives the
   ThoughtSpot-column → Sigma-denorm-column map **from the model TML itself**
   (replicates the converter's `sigmaDisplayName`; joined dims get a `(TABLE)`
   suffix, fact columns don't). No hardcoded registry → works for any model.
4. **Build workbooks** — per Liveboard, map each visualization
   (`answer.search_query` + `chart.type`) to a Sigma element off the master table.
   Chart map: KPI→kpi-chart, COLUMN/BAR/STACKED→bar-chart, LINE→line-chart, PIE/DONUT→
   **donut-chart** (ThoughtSpot renders pies as donuts), PIVOT_TABLE→pivot-table,
   TABLE→grouped table, AREA→area-chart, SCATTER/BUBBLE→scatter-chart (x/y measures
   + optional category color), LINE_COLUMN→combo-chart (first measure bars, rest
   line), GEO_AREA/GEO_BUBBLE→**region-map** (regionType inferred from the geo field
   name; Sigma auto-colors from the measure). No native Sigma kind for funnel /
   waterfall / treemap / heat-map / sankey → those fall back to bar-chart (flagged
   in the assessment). All chart kinds verified live (POST→readback) 2026-06-07.
   Search-query filters (`[Col]='v'`) → element list-filters. TML **sorts**
   (`sort by [Col]` tokens + `client_state` sortInfo) carry into the specs, and
   table column ORDER follows the answer's `ordered_column_ids` (never the
   alphabetical `answer_columns` or the chart's `chart_columns`).
   Aggregate formulas (`sum(x)/sum(y)`, `sqrt(sum())`) become DM **metrics**; column
   formats come from the TML `format_pattern`/`currency_type`. KPI value uses
   `{"columnId": c}`; donut `value`/`color` use `{"id": c}`; grouped tables need
   `groupings:[{groupBy, calculations}]`. Full spec shapes:
   **`refs/liveboard-to-workbook.md`** (charts) + **`refs/model-conversion-rules.md`** (DM).
5. **Layout** — `apply_layouts.py` maps the Liveboard's OWN `layout.tiles`
   geometry (x/y/w/h on ThoughtSpot's 12-col grid) onto Sigma's 24-col grid
   (cols ×2, rows ×ROW_SCALE min 2 so axis/KPI labels render), as the **LAST**
   write (a bare spec PUT wipes layout). Falls back to a clean auto grid when
   the TML has no tiles.
6. **Parity (HARD GATE)** — `phase6-parity-thoughtspot.rb` two-pass: PASS 1
   reads the workbook spec and emits per-chart fetch instructions (Sigma ACTUAL
   via `mcp__sigma-mcp-v2__query`; EXPECTED via `ts_lib.searchdata` ground
   truth, or warehouse SQL when offline); PASS 2 `--finalize` runs
   `verify-parity.rb` and writes the `parity-final.json` sentinel. Then run
   `ruby scripts/assert-phase6-ran.rb --workdir <dir> --workbook-id <wb>` —
   it must **exit 0** before declaring the migration GREEN.
7. **Visual QA (HARD GATE)** — **never skip, never declare done on HTTP 200.** A
   workbook that POSTs cleanly and passes parity can still be visually broken
   (overlapping tiles, clipped KPI titles, dead zones, orphaned filters; Sigma's
   grid has no z-order — the build de-overlaps bands via `_decollide_bands`, but
   this visual gate is the safety net). After `compare.py` renders the Sigma
   element/page PNGs (side-by-side vs the TS viz):
   1. **Read each Sigma PNG** and check it against `refs/layout-visual-qa.md` (no
      overlaps/stacking, no dead zones, controls placed in-band, no clipped
      titles, even heights, right chart kind/format).
   2. Fix any failure in the spec — for multi-page workbooks use
      `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) —
      then **re-render and re-read**.
   3. Loop until the render passes inspection.

## Step 2.5 — Reuse an existing DM? (between convert and POST — mirrors tableau Phase 1.5 / powerbi Phase 3.5)

Before step 2 POSTs a NEW data model, check whether an existing Sigma DM already covers
the same warehouse tables (don't add a 4th near-identical DM for the same star):

```bash
python3 scripts/ts-dm-signature.py --tml model.tml \
  --database $TS_DB --schema $TS_SCHEMA --out dm-signature.json
ruby scripts/find-or-pick-dm.rb --workbook-signature dm-signature.json \
  --out dm-match.json --auto-pick           # exit 0 = candidate ≥ min-score
```

`ts-dm-signature.py` derives `{warehouse_tables, referenced_columns, measures}` from the
exported model TML (`model_tables[].fqn` is a TS guid, so pass the same `TS_DB`/`TS_SCHEMA`
you export for `migrate.py`). **`migrate.py` does all of this automatically** (Phase 2.5 via
`auto_pick_dm`) before convert — it auto-reuses when the top candidate covers ALL the model's
warehouse tables (`table_match` 1.0), taking a column-superset match even through a score
tie (the tie is duplicate-DM sprawl to collapse, not an ambiguity), and PRINTS the choice +
inherited-column warning. Opt out with `--no-reuse`; pin one with `--reuse-dm <id>`. When
driving the picker by hand:
- **Top candidate covers all tables (`table_match` 1.0), score ≥ 0.6** → reuse: run a
  **shape preflight** first — read the candidate DM's spec back and confirm every column the
  Liveboards reference resolves on the element you'll wire to (no `type=error` columns;
  the denormalized "<root> View" element vs separate dims) — then skip the DM POST and
  build the workbooks (step 4) against the matched `recommended_dm_id` + its element ids.
  WARN about inherited columns/RLS/metrics. (A DM that does NOT cover every table is never
  auto-reused — its denorm view can't satisfy the missing column refs.)
- **No table-covering candidate** → POST new and TELL the user no reusable DM was found.

## Scripts
- `migrate-thoughtspot.py` — **ONE-COMMAND orchestrator** (preferred entry):
  chains discovery, the DM-reuse check, `migrate.py`, the freshness preflight,
  and the scripted parity + hard gate; exit 0 only when every gate is GREEN
- `migrate.py` — the per-phase pipeline the one-command wraps: model → DM →
  migrate its Liveboards (parameterized: `--workdir`, `--name` prefix,
  `--converted` MCP output, offline `--model-tml`/`--liveboard-tml`,
  `--reuse-dm` to skip convert+POST and build against an existing DM)
- `convert_model.mjs` — model TML → Sigma DM spec (imports a local converter
  build via `CONVERTER_PATH`; without one, migrate.py emits the MCP request instead)
- `phase6-parity-thoughtspot.rb` — parity orchestrator (two-pass; writes the
  `parity-final.json` sentinel) + `verify-parity.rb` (comparator)
- `assert-phase6-ran.rb` — **hard gate** (vendored byte-identical across the 5
  plugins): parity ran + PASS, no orphan workbooks, no `type=error`
  columns, layout applied, layout lint (gate 6), control lint (gate 7 — dead
  controls / ghost targets / partial same-page reach / `control-scope.json`
  coverage; `--skip-control-lint`; see `refs/control-parity.md`). Run with
  `--workdir <dir> --workbook-id <wb>`; exit 0 required before GREEN
- `probe-controls.rb` — optional flip test for Liveboard-filter→control
  wiring: in-closure export must change under a non-default `parameters`
  value, out-of-closure must not (`--check-out-of-closure`). Shared, vendored
  byte-identical
- `ts-dm-signature.py` — step 2.5: model TML → DM-reuse signature for `find-or-pick-dm.rb`
- `find-or-pick-dm.rb` — step 2.5: scan existing Sigma DMs, recommend reuse (0.7·column +
  0.2·table + 0.1·metric overlap; `--auto-pick` w/ tie-window). Shared vendor-neutral copy
  (canonical: tableau-to-sigma; needs `scripts/lib/sigma_rest.rb`). Non-destructive.
- `ts_lib.py` — ThoughtSpot REST v2 (whoami/search/export_tml/import_tml/searchdata)
- `ts_discover.py` — inventory / per-object summary
- `ts_common.py` — `build_resolver` (from model TML), viz↔element mappers, format/currency mapping
- `apply_layouts.py` — layout pass (run LAST): TML tile geometry → Sigma 24-col
  grid, auto-grid fallback; `--workdir` reads the manifest
- `compare.py` — visual + structural compare (TS viz PNG vs Sigma element PNG → HTML); **mandatory visual-QA gate** — read each rendered Sigma PNG against `refs/layout-visual-qa.md` and loop until clean
- `ts_screenshot.py` — per-viz PNG export from ThoughtSpot; detects blank /
  connection-error placeholder renders (near-uniform image or non-PNG error
  body) and reports them as ✗ failures, never ✓
- `gap-scout.md` + `scout-validate.py` + `learned-rules.py` — formula gap-scout (validate + persist unhandled-TML translations)
- `get-token.sh` — Sigma token; `get-ts-token.sh` — ThoughtSpot Trusted-Auth service token

## Worked example
The CSA.TJ retail star (ORDER_FACT + 5 dims) → ThoughtSpot model "Retail Analytics"
→ converted Sigma DM (6-table star + Order Fact View) → 11 themed Liveboards
migrated to 11 Sigma workbooks, parity exact (Net Revenue 108,797.85; by-category,
region, quarter all match to the cent). Per-run ids land in `<workdir>/migrate_out.json`.

## Reference docs & fixtures
- `refs/model-conversion-rules.md` — model TML → DM rules (joins/formulas/display
  names/formats, TS_DB/TS_SCHEMA fqn gotcha, MCP request shape)
- `refs/liveboard-to-workbook.md` — workbook spec shapes (KPI `{columnId}` vs
  donut `{id}`, groupings, pivot rowsBy/columnsBy, sorts, layout geometry math,
  rename gotcha)
- `fixtures/` — real exported TML pair from the team2 trial
  (`retail-analytics-model.tml` 6-table star + `retail-analytics-liveboard.tml`
  5-viz Liveboard with layout.tiles) — drives the offline mode above and the
  converter's regression diet.

## Notes
- `convert_thoughtspot_to_sigma` is the converter (MCP github.com/twells89/sigma-data-model-mcp
  + browser sigma-data-model-manager) — keep both in lockstep.
- **Rename gotcha**: `PATCH /v2/workbooks/{id}` silently no-ops for renames
  (200, name unchanged) — rename via `PATCH /v2/files/{id} {"name": …}`
  (delete and unarchive are files-side too).
- TML export embeds raw control chars in JSON → parse with `json.loads(..., strict=False)`.
- System/sample objects are FORBIDDEN to export (only own content).


## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_thoughtspot_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for ThoughtSpot:** `rls_rules` on the model/worksheet or per table (`ts_username` to `CurrentUserEmail()`, `ts_groups` to `CurrentUserInTeam`), multiple rules OR-combined. The converter emits each as a `result.security[]` entry `{kind:'rls', name, expression, table?}`.

> ⚠️ The `rls_rules` TML shape + the `ts_username`/`ts_groups` mapping are validated against a **synthetic** rule (no Liveboard in the team2 trial uses RLS). Treat the auto-mapping as best-effort and use **Customize** to review each rule against the real source before applying.

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


---

## Telemetry (after the final gate passes)

**Tell the user this in the conversation before running anything:**

> "Migration complete. Before I wrap up, I'd like to send an anonymous usage ping so we can track which migration skills are being used. It records: tool name, your Sigma region, an anonymized org fingerprint (a hash of your client ID — not the credential itself), migration duration, and success. No workbook names, SQL, column names, or any customer data is included. See [TELEMETRY.md](https://github.com/twells89/sigma-migration-telemetry/blob/main/TELEMETRY.md) for the exact payload. Just say 'skip' if you'd prefer not to send it."

If the user does not object, run:

```bash
python3 scripts/report-telemetry.py --tool thoughtspot-to-sigma --duration <elapsed_seconds>
# on failure: python3 scripts/report-telemetry.py --tool thoughtspot-to-sigma --duration <elapsed_seconds> --failed
```
