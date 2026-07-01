---
name: quicksight-to-sigma
description: Convert an Amazon QuickSight analysis or dashboard into a Sigma data model and matching dashboard. Use when the user has a QuickSight analysis/dashboard and wants to recreate it in Sigma. Covers AWS-CLI extraction of the analysis definition + datasets + data sources, calc-field / data-prep translation via the local vendored converter (the convert_quicksight_to_sigma MCP tool is a manual fallback only), posting the data model + workbook via the Sigma REST API, layout, and parity verification against the same warehouse.
user-invocable: true
---

# QuickSight → Sigma

> **Windows / first run — run the environment doctor before anything else:**
> `bash scripts/doctor.sh` (macOS/Linux/Git Bash) or `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1` (Windows).
> It checks Ruby/Python/Node/bash and flags the Python "Store stub" + CRLF with exact fixes. Details: `refs/environment.md`.

## Preflight the workbook spec before POST (mandatory)

Before POSTing any workbook spec, run `ruby scripts/lib/preflight_lint.rb <spec.json>` — it exits 1 with a precise message on the two migration-killer bugs: a `table` with aggregate columns + dimensions but **no `groupings`** (renders raw detail rows), and a malformed `control` (missing `id`/`controlId`/`controlType` or nesting value fields under a `value` object instead of flat, a non-double-nested `source`, or a list control wired to neither `source` nor `filters` — a filters-only list control is valid). Fix every violation first — never POST past it, and **never conclude a feature is "unsupported" from an `Invalid kind` error** (it means the inner fields are wrong). Verified shapes: `sigma-workbooks` `controls.md` / `tables.md`.

## Phase 0 — Choose where to build (ask first when no destination given)

Don't silently land the migrated data model + workbook in an auto-picked folder.
If the user didn't supply a destination (no `--folder <id-or-name>`), ASK before building:

1. `ruby scripts/pick-destination.rb list` → `{ workspaces, folders (editable, with parentName), myDocuments }`
2. Let the user pick ONE: a **workspace** (its `id` lands content in the workspace root),
   an existing **folder**, **My Documents** (when non-null — null for service tokens), or
   **create a new folder**: `ruby scripts/pick-destination.rb create --name "<name>" [--parent <workspace-or-folder-id>]`
3. Pass the chosen id as `--folder <id>` (the downstream `--fixup` step requires a folderId).

If a destination is already supplied, honor it silently — don't ask.

> Status: **foundation** (converter MCP + browser shipped 2026-05-28).
> Beads: converter = `beads-sigma-j5e`; CustomSql/DIRECT_QUERY fixup = `beads-sigma-vy4k`.
> Defers to: `sigma-workbooks` (canonical workbook spec), `sigma-data-models` (DM spec), the local vendored converter (`converter/quicksight.mjs`, exporting `convertQuickSightToSigma` — the `convert_quicksight_to_sigma` MCP tool is a manual fallback only), and the shared vendor-neutral Sigma-side scripts (`post-and-readback.rb`, `put-layout.rb`, `find-or-pick-dm.rb`, `verify-parity.rb`) reused across the migration skills.

## What's proven (the happy path)
```
1. AUTH      AWS CLI → QuickSight (Enterprise edition REQUIRED); Sigma creds via get-token.sh
2. DISCOVER  describe-analysis-definition + describe-data-set(s) + describe-data-source(s)  → quicksight-discover.py → signals.json
3. CONVERT   local vendored converter (converter/quicksight.mjs via node) — analysis.json + dataset jsons + connectionId → Sigma DM JSON   [MCP only as manual fallback]
4. POST DM   fixup (name elements + passthrough cols, rewrite sql refs, schemaVersion=1) → validate → POST /v2/dataModels/spec
5. WORKBOOK  master tables per DM element + chart elements mirroring the QS visuals → POST /v2/workbooks/spec
6. LAYOUT    QS grid x,y,w,h → 24-col layout XML → put-layout.rb
7. VERIFY    sigma-mcp-v2 query each element returns real rows; Phase 6 parity vs the QuickSight aggregation    [hard gate]
```

See `refs/migration-test-slate.md` for the complexity taxonomy + 20-dashboard test slate that grounds the converter's coverage and known gaps.

## Step 0 — Front door: resolve the connection once (`scripts/intake.rb`)

Resolve the Sigma warehouse connection a SINGLE time up front so no phase free-searches
`/v2/connections` (the token sink):

```bash
ruby scripts/intake.rb --workdir <WORK> --tool quicksight-to-sigma --mode live \
  [--connection <id>] [--name <connection-name-substring>]
```

Caches `<WORK>/connection.json` (the orchestrator reads it when `--connection` is omitted —
point `--out` at the same `<WORK>`) and writes `intake.json` (run-start + mode feed the
telemetry ping). Multiple connections + no id/name → it lists them and asks you to pick;
never guesses.

## One command (preferred): `scripts/migrate-quicksight.rb`

The single-process orchestrator chains every phase below — discover (live AWS or `--from-fixtures <dir>`), convert (**zero-config**: the self-contained `converter/quicksight.mjs` bundle vendored in the skill runs `convertQuickSightToSigma` locally via `node` — no clone, no npm, no MCP; a dev's `--mcp-dir`/`$QS_MCP_DIR` build still wins; refresh with `tools/vendor-converters.sh`; only if the bundle is also absent does `convert-model.rb --emit-mcp` gate + `--converted` resume apply), the **Phase 3.5 DM-reuse check** (`qs-dm-signature.py` + `find-or-pick-dm.rb`; **reuse-first** — auto-reuses an existing DM covering all the analysis's source tables, `--reuse-dm <id>` pins one, `--skip-reuse-check` forces build new), fixup `--folder-id` → validate → post-and-readback, workbook build, layout, then the **two-pass Phase 7 parity** (`phase6-parity-quicksight.rb` emits the per-chart query list and gates; write `parity-expected.json` + `parity-actuals.json` and re-run the SAME command — phases 1–5 skip automatically) and the `assert-phase6-ran.rb --workdir` hard gate:

```bash
ruby scripts/migrate-quicksight.rb \
  --analysis-id <ID> --account-id <ACCT> --region us-east-1 --profile <P> \
  --connection <SIGMA_CONN_UUID> --folder <FOLDER_ID> \
  [--database DB --schema SCH] [--name "My Dashboard"] [--out DIR] [--yes]
# offline / fixtures: swap the first line for --from-fixtures fixtures/
```

Exit 0 = parity + hard gate green; exit 10 = a gate (converter MCP / parity collection / OPEN QUESTIONS) printed its exact resume command; exit 3 = parity fail. Each phase prints a visible header — it is not a black box. The per-script phases below remain the reference for running any stage by hand.

`--folder` accepts a folder **id or exact name** (name is looked up via `/v2/files`; ambiguous names abort with candidates). Re-running the same command with the same `--out` after a mid-run crash is **idempotent**: a DM/workbook already posted by that workdir is detected (dm-readback.json / wb-id.txt), verified live, and reused — never duplicated. Use a fresh `--out` for a fresh build.

## Phase 1 — Auth

**QuickSight (AWS CLI).**
- The `describe-analysis-definition`, `describe-dashboard-definition`, and `describe-data-set` APIs are **Enterprise-edition only**. A Standard-edition account rejects them — there is no extraction path on Standard. Confirm the edition first.
- QuickSight's **identity region is often `us-east-1`** even when the data lives elsewhere; the analysis/dataset/data-source resources are read from the identity region. Pass `--region us-east-1` unless you know the account is regionalized differently.
- Auth is whatever the AWS CLI / boto3 is already configured with: a named `--profile`, SSO (`aws sso login`), or — for Okta-fronted orgs — `gimme-aws-creds` writing a profile. The discovery script uses an **in-process boto3 client when boto3 is importable** (one session for the whole run) and only **falls back to shelling out to `aws quicksight ...`** when it isn't — boto3 is NOT a hard dependency, and `QS_FORCE_CLI=1` forces the CLI path.
- You need the account id (`aws sts get-caller-identity`) and the analysis (or dashboard) id.

**Sigma.** Same as the other migration skills: `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` → `scripts/get-token.sh` exchanges them for a `SIGMA_API_TOKEN`. You also need a **Sigma connection** that reaches the same warehouse the QuickSight datasets query (its `connection_id` feeds the converter), and a target **folder id**.

## Phase 2 — Discover

```bash
python3 scripts/quicksight-discover.py \
  --account-id <ACCOUNT_ID> --region <REGION> --profile <PROFILE> \
  --analysis-id <ANALYSIS_ID> \
  --out-dir ~/quicksight-migration/<name>
# (or --dashboard-id <DASHBOARD_ID> instead of --analysis-id)
```

Pulls `describe-analysis-definition` (or `-dashboard-definition`) + `describe-data-set` for every `DataSetIdentifierDeclarations` entry + `describe-data-source` for each referenced source, and writes into the out-dir:
- `analysis.json` — the full describe-*-definition response (the converter's primary input).
- `datasets/<id>.json` — one per dataset (PhysicalTableMap, LogicalTableMap/transforms, calc fields, output columns).
- `datasources/<id>.json` — one per source (the `Type` tells you Snowflake / Redshift / Athena / S3 / SaaS).
- `signals.json` — normalized: per-sheet visuals (type + VisualId + title + referenced ColumnNames), calc fields, parameters, datasets, sources. Drives the convert + workbook + layout phases.
- `timings.json` — per-call wall clock + transport; **always written**.

### Fast discovery (designed for 20-40 dashboard estates sharing datasets)
- **In-process boto3 transport.** Each `aws` CLI subprocess pays a 0.4-0.7s interpreter-startup tax (measured ~0.7s wall); a 1-analysis discovery makes 4-5 calls and an estate re-pays it per dashboard. With boto3 importable, ONE session serves every call; the CLI fallback keeps zero-dependency installs working (identical call/response shapes — boto3 responses are normalized: datetimes → ISO strings, `ResponseMetadata` stripped).
- **Estate-level dataset cache** (`/tmp/qs-estate-cache/<acct>__<region>/`, override `QS_ESTATE_CACHE`): describe responses cached keyed **DataSetArn + LastUpdatedTime** — shared datasets are described ONCE per estate, not per dashboard. Freshness is validated against ONE `list-data-sets` call per process; any LastUpdatedTime mismatch (or a denied/empty listing) re-describes. **Data sources are described once, lazily** and cached without a probe (they change rarely). `--no-cache` bypasses, `--refresh-cache` forces re-describe.
- **Batch mode**: `--analysis-ids a,b,c --pool 4` (cap 8) runs per-analysis discovery in parallel into `<out-dir>/<id>/`, sharing the estate cache with single-flight de-duplication (concurrent threads needing the same dataset trigger exactly one describe).
- **Test coverage (live AWS is IAM-blocked — see below)**: `python3 scripts/tests/test-quicksight-discover.py` — 11 tests covering both transports (fake-boto3 injection + stubbed CLI), datetime normalization, cache hit/invalidation/single-flight, batch mode, and the offline fixture path. **Still awaiting live-AWS validation**: real boto3 session/profile auth, real `list-data-sets` pagination + permissions, Enterprise-edition `describe-*-definition` latency, and measured before/after numbers on a real estate. The mocked harness + the `--from-fixtures` E2E (`migrate-quicksight.rb`, parity 5/5 strict) are the offline proof.

## Phase 3 — Convert (local, zero-config)

The conversion runs **locally by default**: `migrate-quicksight.rb` executes the vendored
converter bundle (`converter/quicksight.mjs`, `convertQuickSightToSigma`) in-process via a
`node` shim over `analysis.json` + each `datasets/*.json` — no clone, no `npm install`, no
network, **no MCP, no data egress**. A dev's own build wins via `--mcp-dir` / `$QS_MCP_DIR`.
Only if the bundle is **also** absent does it gate (exit 10):

```bash
ruby scripts/convert-model.rb --emit-mcp \
  --discover-dir ~/quicksight-migration/<name> \
  --connection-id <SIGMA_CONNECTION_ID> \
  [--database <DB> --schema <SCHEMA>]
```

This prints the exact `convert_quicksight_to_sigma` MCP-tool call — `files` = `analysis.json` + each `datasets/*.json`, plus `connection_id` (and `database`/`schema` overrides if a dataset's source path is incomplete). Run that MCP tool **manually** — it is a fallback, not the default path — save its result, and resume with `--converted <mcp-tool-result.json>` (e.g. `converter-out.json`).

What the converter handles vs. what it doesn't (see `refs/migration-test-slate.md` for the full taxonomy):
- **Handled**: RelationalTable, CustomSql, JoinInstruction, DataTransforms (CreateColumns/Rename/Cast/Filter/Project), ~40 calc-field functions (`ifelse`→`If`, `switch`→nested `If`), parameters → Sigma controls. KPI / bar / line / donut/pie visuals on the workbook side.
- **Gaps (degrade to `/* TODO */` placeholder or skipped)**: window / table-calc functions (`sumOver`, `runningSum`, `rank`, `percentOfTotal`, `periodOverPeriod*`, `window*`, `percentile*Over`); S3Source & SaaSTable physical sources; analysis-level FilterGroups; ColumnConfigurations (formatting); dataset-of-datasets. Un-migratable visuals (Insight ML, CustomContent, Plugin, Sankey, map family) → emit a partial migration + warning manifest; never call these "failed".

For an untranslated calc-field expression, spawn the **gap-scout subagent** (see `scripts/gap-scout.md`): it proposes a Sigma formula, validates it against the live DM via `scripts/scout-validate-and-persist.rb`, and on success persists a rule to `~/.quicksight-to-sigma/learned-rules.yaml` (customer home — `git pull` can't clobber; the build script auto-applies it next run via `LearnedRules.load`). On failure the scout returns an **opt-in** `escalate-gap.py` command — filing a tracking issue is never automatic: run the returned `escalation.dry_run_cmd` to draft the issue (shows target repo + dedupe), show the user, and only re-run with `--yes` if they accept. Calc-field gaps route to the converter repos (`sigma-data-model-manager` + `sigma-data-model-mcp`, mirrored) with a cross-linked bead.

## Phase 3.5 — Reuse an existing DM? (avoid sprawl — mirrors tableau Phase 1.5 / powerbi Phase 3.5)

Before Phase 4 POSTs a NEW data model, check whether an existing Sigma DM already covers
the same warehouse tables (don't add a 4th near-identical "Orders" DM):

```bash
python3 scripts/qs-dm-signature.py --discover-dir ~/quicksight-migration/<name> \
  --out dm-signature.json
ruby scripts/find-or-pick-dm.rb --workbook-signature dm-signature.json \
  --out dm-match.json --auto-pick           # exit 0 = candidate ≥ min-score
```

`qs-dm-signature.py` derives `{warehouse_tables, referenced_columns}` from the Phase-2
dataset JSONs (RelationalTable FQNs; CustomSql tables lifted from the SQL's FROM/JOIN;
calc columns from CreateColumnsOperation). Decision:
- **Score ≥ 0.6** → **ASK the user** reuse-vs-new: surface the candidate name, matched cols
  (N/M), and the inherited-extras warning from `dm-match.json`. If they reuse, run a
  **shape preflight** first — read the candidate DM's spec back and confirm every column
  the analysis references resolves on the element you'll wire to (no `error` columns; fact
  vs separate-dim location) — then **skip Phase 4** and point Phase 5's masters at the
  matched `recommended_dm_id` + its element ids. With `--auto-pick` a clear winner (no tie
  within 0.05) skips the prompt — still WARN about inherited columns/RLS/metrics.
- **Score < 0.6** → build new (Phase 4) and TELL the user no reusable DM was found.

## Phase 4 — Fixup + POST the data model

The converter output needs fixups before `POST /v2/dataModels/spec` (gap `beads-sigma-vy4k`: CustomSql / DIRECT_QUERY elements come back nameless, and sql refs need rewriting):

```bash
ruby scripts/convert-model.rb --fixup \
  --in converter-out.json \
  --discover-dir ~/quicksight-migration/<name> \
  --folder-id <FOLDER_ID> \
  --out dm-spec.json
ruby scripts/validate-spec.rb --type datamodel dm-spec.json
ruby scripts/post-and-readback.rb --type datamodel --spec dm-spec.json --out dm-readback.json
```

`--fixup` forces `schemaVersion: 1`, names every element + its passthrough columns (so workbook masters can reference them), rewrites sql refs to `[Custom SQL/<ALIAS>]` form, and injects `folderId`. `post-and-readback.rb` confirms every column resolved to a concrete type — **no `error` columns**.

## Phase 5 — Build the workbook

```bash
ruby scripts/build-workbook-from-quicksight.rb \
  --analysis ~/quicksight-migration/<name>/analysis.json \
  --dm-readback dm-readback.json \
  --folder-id <FOLDER_ID> \
  --out wb-spec.json
ruby scripts/post-and-readback.rb --type workbook --spec wb-spec.json --out wb-readback.json
```

Mirrors the QuickSight visuals as Sigma elements off Data-page master tables, and emits a `wb-spec.map.json` (visualId → element-id) the layout phase consumes. Element shapes:
- Workbook element column refs use **`[<source element name>/<col>]`** (the source element name comes from the DM element name set in Phase 4).
- bar/line: `xAxis:{columnId}`, `yAxis:{columnIds:[...]}`.
- **pie/donut: `color:{id}` + `value:{id}`** (NOT xAxis/yAxis).
- KPI: a single measure formula wrapping the master column.

## Phase 6 — Layout (do NOT skip — stacked ≠ done)

```bash
ruby scripts/build-quicksight-layout.rb \
  --analysis ~/quicksight-migration/<name>/analysis.json \
  --map wb-spec.map.json \
  --out layout.xml
ruby scripts/put-layout.rb --workbook <WORKBOOK_ID> --layout layout.xml
```

Maps each QuickSight visual's grid cell → a 24-col Sigma layout. **QuickSight grid lines are 1-based** — `ColumnIndex`/`RowIndex` start at 1, so subtract 1 before scaling to the 0-based Sigma grid. Free-form / section-based QS layouts are approximated to the grid.

## Visual QA (mandatory gate — never skip)
A workbook that POSTs 200 and passes parity can still be visually broken — **overlapping tiles, clipped KPI titles, dead zones, filters over charts.** QuickSight FreeForm pixel coords can overlap and Sigma's grid has no z-order; the build collapses collisions, but this visual gate is the safety net.

1. Render every page to PNG (token first: `eval "$(scripts/get-token.sh)"`):
   `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600`
2. **Read each PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking, no dead zones, controls in their own band, no clipped titles, even heights, right chart kind/format).
3. Fix any failure in the spec — for multi-page workbooks use `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) — then **re-render and re-read**.
4. Declare the migration done on a **clean render**, not on HTTP 200.

## Phase 7 — Parity (hard gate)

```bash
# PASS 1 — plan + per-chart fetch instructions (reads the live workbook spec)
ruby scripts/phase6-parity-quicksight.rb --workdir /tmp/<name> --workbook-id <WORKBOOK_ID>
# ... run the printed mcp__sigma-mcp-v2__query calls (Sigma ACTUAL rows) and
#     compute EXPECTED rows from the warehouse with the same dim+aggregation,
#     writing parity-actuals.json + parity-expected.json into the workdir ...
# PASS 2 — verify + write the parity-final.json sentinel
ruby scripts/phase6-parity-quicksight.rb --workdir /tmp/<name> --finalize
# hard gate — must exit 0 before declaring GREEN
ruby scripts/assert-phase6-ran.rb --workdir /tmp/<name> --workbook-id <WORKBOOK_ID>
```

**POST success ≠ working.** You MUST query-verify the built elements:
- `sigma-mcp-v2 query` each element → confirm real rows (not blank / not all `error`).
- True parity: compare each Sigma aggregation against the same aggregation computed from the QuickSight side (or the warehouse). `assert-phase6-ran.rb` is a hard gate — a subagent must run it and it must pass before reporting success.
- `assert-phase6-ran.rb` runs 7 gates incl. layout lint (gate 6) and **control lint** (gate 7 — dead controls / ghost targets / partial same-page reach / `control-scope.json` coverage; `--skip-control-lint` escape; see `refs/control-parity.md`).
- Optional flip test when the dashboard had parameters/filter controls: `ruby scripts/probe-controls.rb --workbook-id <wb> --check-out-of-closure` — runtime proof controls actually filter (export API `parameters` is the only way to set a control programmatically; MCP queries see saved defaults only).
- **mcp-v2 warehouse-side (EXPECTED) queries can NOT use the raw warehouse FQN**
  (`SELECT … FROM DB.SCHEMA.TABLE` fails): with `type=connection` the table must
  be addressed as `"connection"."<inodeId>"`, where `<inodeId>` is the table's
  inode from `GET /v2/connections/{connectionId}/lookup?path=…` (or a prior DM
  spec's `source.path`). The Sigma-ACTUAL side (`type=workbook` →
  `"workbook"."<elementId>"`) follows the same quoting pattern.

## Gotchas (carry these forward)
- **Enterprise edition is mandatory** for the `describe-*-definition` APIs. Standard rejects them outright — there's no fallback extraction.
- **QuickSight identity region is usually `us-east-1`** — resources read from the identity region, not the data region.
- **CustomSql / DIRECT_QUERY converter gap (`beads-sigma-vy4k`)**: those elements come back nameless and with raw sql refs; the `--fixup` step names them + rewrites refs to `[Custom SQL/<ALIAS>]`. Don't post the converter output unfixed.
- **Workbook element refs** are `[<source element name>/<col>]`, where the source element name is the DM element name set during fixup.
- **pie/donut** use `color:{id}` + `value:{id}`, not the bar/line `xAxis`/`yAxis` shape.
- **Layout grid is 1-based** in QuickSight — offset by 1 before scaling to Sigma's grid.
- **Window/table-calc functions are a known gap** — they degrade to a `/* TODO */` placeholder; verify the graceful degradation rather than treating it as a failure, and surface it in the migration warning manifest.

### Carried forward from the first live customer run (Arine, RCA `refs/rca-arine-2026-06-17.md`)
- **`PUT /workbooks/{id}/spec` WIPES the applied layout.** Layout is applied separately by `put-layout.rb`, so **always re-run `put-layout` after every spec PUT**. Worse: a **failed** spec PUT (4xx) followed by a layout PUT leaves the workbook referencing layout elements that don't exist in the spec → the whole page renders **N/A / blank**. If metrics show N/A after an edit, check spec/layout consistency first — query the element (it usually still returns data).
- **Text element `body` rejects a bare `<p>`** — `<p> carries no non-default block style or alignment`. Use `<p class="p-small">`, `<p style="text-align: …">`, or a `#` heading / plain paragraph.
- **Dynamic text date format = strftime, UNQUOTED**: `{{Max([El/Col]) | %B %-d, %Y}}` → "June 17, 2026". Quoted formats leak the quotes; `DateFormat()` echoes the pattern literally; `Date()` doesn't strip the time.
- **QS `*_FLAG` columns are often warehouse BOOLEAN even when QS types them INTEGER** — `[flag] = 1` throws `Argument 2 invalid for '='` at query time. Verify via `/v2/connections/tables/{inode}/columns` and emit a boolean-safe predicate.
- **Database name is usually NOT in the export** (it lives in the DataSource, which `describe-dashboard-definition` omits). Resolve it via `POST /v2/connection/{connectionId}/lookup` (**singular** `connection`) with `{"path":[DB,SCHEMA,TABLE]}`, probing candidate DBs until 200. A schema not granted to the connection's role 404s even when the DB resolves.
- **Parity needs the customer's runtime control state + a rendered reference.** A customer screenshot is often filtered to a value that is NOT a saved default (e.g. `Organization = "Arine Demo Organization"` — 0 occurrences in the definition). Capture which control values are active before comparing, and request a screenshot + `describe-theme <id>` up front (the theme — hence the categorical color palette — is not in the definition export).
- **Verify without MCP via the Export API**: when the customer org isn't wired to `sigma-mcp-v2`, query an element with `POST /v2/workbooks/{wb}/export {elementId, format:{type:csv}}` → poll `GET /v2/query/{queryId}/download`. This is how you confirm real values (and filtered parity) on any org.

## Reuse, don't reinvent
These vendor-agnostic Sigma-side scripts are reused across the migration skills: `get-token.sh`, `lib/sigma_rest.rb`, `post-and-readback.rb`, `put-layout.rb`, `find-or-pick-dm.rb`, `validate-spec.rb`, `verify-parity.rb`, `cleanup-orphan-workbooks.rb`. Only the QuickSight-specific stages (`quicksight-discover.py`, `convert-model.rb`, `build-workbook-from-quicksight.rb`, `build-quicksight-layout.rb`, `phase6-parity-quicksight.rb`, `qs-dm-signature.py`) are new. `scripts/sigma-export-png.py` renders a workbook page to PNG for the mandatory **Visual QA** gate (read each image against `refs/layout-visual-qa.md`).


## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_quicksight_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for QuickSight:** `RowLevelPermissionTagConfiguration` (tag-based RLS to a user-attribute), `ColumnLevelPermissionRules` (to CLS). A `RowLevelPermissionDataSet` is flagged (its grant rows live in a separate dataset not in the export — recreate as a user attribute).

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
python3 scripts/report-telemetry.py --tool quicksight-to-sigma --duration <elapsed_seconds> --workdir <run-dir> [--mode live|file|both]
# on failure:        python3 scripts/report-telemetry.py --tool quicksight-to-sigma --duration <elapsed_seconds> --workdir <run-dir> --failed
# if the user declines: python3 scripts/report-telemetry.py --tool quicksight-to-sigma --workdir <run-dir> --declined
# --workdir writes telemetry-sent.json, the marker the GREEN telemetry gate (assert-telemetry-ran.rb) requires.
```
