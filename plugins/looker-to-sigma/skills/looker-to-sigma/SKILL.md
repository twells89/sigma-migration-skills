---
name: looker-to-sigma
description: >-
  Convert a Looker instance (LookML semantic model + dashboards) into a Sigma
  data model and matching workbook(s). Use when the user has Looker content —
  LookML projects, explores, or dashboards (user-defined OR LookML-defined) —
  and wants to recreate it in Sigma. Discovery via the Looker REST API 4.0 /
  Looker MCP server (or LookML files offline), model conversion via the
  convert_lookml_to_sigma converter, dashboard → workbook conversion from the
  Looker Dashboard API JSON, build via the Sigma REST API, and 3-way parity
  verification against the source warehouse — driven by `scripts/*`.
user-invocable: true
---

# Looker → Sigma Conversion

## Phase 0 — Choose where to build (ask first when no destination given)

Don't silently land the migrated data model + workbook in an auto-picked folder.
If the user didn't supply a destination (no `--folder <id>` and no `SIGMA_FOLDER_ID`), ASK before building:

1. `python3 scripts/pick_destination.py list` → `{ workspaces, folders (editable, with parentName), myDocuments }`
2. Let the user pick ONE: a **workspace** (its `id` lands content in the workspace root),
   an existing **folder**, **My Documents** (when non-null — null for service tokens), or
   **create a new folder**: `python3 scripts/pick_destination.py create --name "<name>" [--parent <workspace-or-folder-id>]`
3. Pass the chosen id as `--folder <id>`. `folderId` accepts a workspace id or a folder id.

If a destination is already supplied, honor it silently — don't ask.

Convert a Looker LookML semantic model into a Sigma data model, then build Sigma
workbook(s) that mirror the Looker dashboards (user-defined OR LookML-defined) as
closely as possible — and verify the numbers match Looker AND the warehouse.

**Read ALL of the following before replying or taking any action. Do not make assumptions about skill conventions, prompts, or global instructions — read the files.**
- `refs/dashboard-contract.md` — the normalized Looker Dashboard JSON contract both the live API fetch and the offline LookML parse produce. The dashboard pipeline is source-agnostic; it only sees this contract.
- `refs/looker-dashboard-layout.md` — the deep desk study: Looker layout modes, newspaper→24-col grid math, tile-type / filter-type maps, and the full translation-hazard catalog (Liquid, `merged_results`, table calcs, view/explore field resolution, cross-filtering). **This is the design backbone of the dashboard pipeline.**
- `refs/layered-lookml.md` — layered/derived LookML: derived tables on derived tables, cross-view `${view.SQL_TABLE_NAME}` refs (CTE inlining vs `LOOKER_SCRATCH` placeholders), CTE-continuation fragments, incremental/persisted PDTs → the **Sigma materialization handoff**, dimension_group edge cases, and untranslatable formatting measures. **Read before converting any project with `derived_table:` views.**

**For canonical spec shape** (data-model element kinds, workbook element kinds, controls, formulas, formatting), defer to the companion **`sigma-data-models`** and **`sigma-workbooks`** skills. This skill restates only the Looker-conversion-specific patterns.

---

## The two artifacts, two pipelines

Looker has two independent layers; convert them separately.

| Layer | Source (production = API-first) | Converter | Sigma output |
|---|---|---|---|
| **Semantic model** | LookML views+model (Looker API/MCP, or files offline) | `mcp__sigma-data-model__convert_lookml_to_sigma` | data model |
| **Dashboards** | `GET /dashboards/{id}` JSON — covers **user-defined (UDD) AND LookML dashboards** | `fetch_looker_dashboard.py` → contract → `build_workbook.py` | workbook |

**Critical — UDD is the primary path.** Most real Looker dashboards are **user-defined
(UDD)** — built in the UI, NOT in any LookML file. They are reachable ONLY via the Looker
API, which returns UDD and LookML dashboards as the **same** `Dashboard` JSON
(`dashboard_elements[]` + `dashboard_layouts[]` + `dashboard_filters[]`). So the dashboard
converter keys off that API JSON, not LookML. `.dashboard.lookml` parsing is a secondary,
offline-only path that normalizes into the same contract.

---

## ONE COMMAND (preferred): migrate-looker.py

The whole pipeline — parse → **RLS gate** → convert → **DM-reuse check** → DM
POST + readback → workbook build (layout inline) → **source-freshness
preflight** → **scripted parity + hard gate** — as a single command (mirrors
qlik-to-sigma's `migrate-qlik.rb` / thoughtspot's `migrate-thoughtspot.py`).
Gates are never bypassed: the command exits non-zero if parity or
`assert-phase6-ran.rb` fails.

```bash
# env: SIGMA_CONNECTION_ID = the FULL warehouse-connection UUID (NOT a short
# prefix) — required unless --reuse-dm. Persist it once via the tableau plugin's
# `ruby scripts/setup.rb` (writes ~/.sigma-migration/env, which this command
# auto-sources) or export it for the run:
export SIGMA_CONNECTION_ID=<full-connection-uuid>
# offline (.dashboard.lookml + view files; the fixture pair works end-to-end):
python3 scripts/migrate-looker.py --lookml-dir fixtures/skilltest-orders \
    --dashboard fixtures/skilltest-orders/skilltest_orders.dashboard.lookml \
    [--name PREFIX] [--workdir /tmp/look-run]
# live (UDD or LookML dashboard, ~/.looker/looker.ini configured):
python3 scripts/migrate-looker.py --lookml-dir /path/to/lookml \
    --dashboard-id <id> [--explore <name>] [--name PREFIX] [--workdir DIR]
```

- **Decision points are flags with safe defaults, never silent:** `detect_rls.py`
  runs first — RLS findings STOP the command (exit 10, nothing posted) until you
  either port them via `apply_sigma_rls.py` (Phase 1.5) or re-run with `--yes`
  (proceed WITHOUT RLS — loud + recorded). The DM-reuse check (Phase 2.5) always
  runs and PRINTS candidates+scores; default is build-new, reuse only via an
  explicit `--reuse-dm <id>`. The folder is auto-resolved and printed.
- **Converter paths:** `CONVERTER_SRC` (patched `src/lookml.ts` via tsx) or
  `CONVERTER_PATH` (`build/lookml.js`) — both auto-located; with neither, the
  command writes `<workdir>/convert-request.json` (the exact
  `convert_lookml_to_sigma` MCP arguments) and exits 3 — call the tool, save its
  JSON, re-run with `--converted <file>` (mirrors thoughtspot's exit-3 design).
- **Parity is fully scripted** (the Phase-4 gate below): ACTUAL = Sigma CSV
  export per chart; EXPECTED = a Looker inline query (live) or a
  SOURCE-LookML-derived re-aggregation of the master's warehouse rows (offline —
  measure semantics from the `.view.lkml` `type:`, independent of the builder's
  formulas). Then `phase6-parity-looker.rb --finalize` + `assert-phase6-ran.rb`
  run automatically. Both per-chart fetch sides run in a **bounded 4-wide thread
  pool** (measured 24.3s → 5.8s on the 5-chart fixture); set
  `LOOKER_PARITY_WORKERS=1` to serialize on a loaded warehouse (max is clamped
  to 4 — warehouse-friendly bursts only).
- Exit codes: `0` GREEN · `3` MCP convert request emitted · `10` RLS decision
  needed · `2` built but a gate FAILED. `--dry-run` = no Sigma POSTs.

---

## Scripts

| Script | Purpose |
|---|---|
| `scripts/migrate-looker.py` | **ONE-COMMAND orchestrator** (preferred entry) — chains every phase below + the scripted parity hard gate; see the section above. |
| `scripts/phase6-parity-looker.rb` | **Phase 4 (parity gate):** two-pass orchestrator — PASS 1 reads the workbook spec → `parity-plan.json` + per-chart fetch instructions; PASS 2 `--finalize` runs `verify-parity.rb` and writes the **`parity-final.json` sentinel** the hard gate requires. Same contract as quicksight/thoughtspot/tableau. |
| `scripts/verify-parity.rb` | **Phase 4:** the comparator (strict set-compare with date-bucket canonicalization; `--extract-mode` tolerance variant). Vendored from the shared converter copy. |
| `scripts/assert-phase6-ran.rb` | **HARD GATE** (vendored **byte-identical** across the 5 plugins — keep the md5 in lockstep): parity ran + PASS, no orphan workbooks, no `type=error` columns, layout applied, layout lint (gate 6), **control lint (gate 7** — dead controls / ghost targets / partial same-page reach / `control-scope.json` coverage; `--skip-control-lint` escape, exit 9; see `refs/control-parity.md`**)**. `ruby scripts/assert-phase6-ran.rb --workdir <dir> --workbook-id <wb>` must **exit 0** before declaring GREEN. |
| `scripts/probe-controls.rb` | **Optional Phase-4 flip test** — runtime proof that controls actually filter: per control, exports one in-closure element CSV with and without `parameters:{controlId: <non-default value>}` (must differ) and, with `--check-out-of-closure`, an out-of-closure element (must NOT differ). Not the mandatory inner loop. Shared, vendored byte-identical. `refs/control-parity.md` has the design + the MCP-vs-export answer. |
| `scripts/get-token.sh` | Exchange `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` → `SIGMA_API_TOKEN` (~1h TTL). `eval "$(scripts/get-token.sh)"` |
| `scripts/looker_api.py` | Minimal Looker REST API 4.0 client (no SDK). Reads `~/.looker/looker.ini`, logs in via `client_credentials`, exposes `L.call(method, path, body)`. **Caches the bearer per process** (thread-safe; one login instead of one per call — ~150ms/call saved, measured 2.4x on a 10-call run) and retries once with a fresh login on 401. CLI: `python3 looker_api.py whoami` / `get <path>` / `raw GET /lookml_models`. |
| `scripts/fetch_looker_dashboard.py` | **Phase 1 (live):** `GET /dashboards/{id}` → the normalized contract (`refs/dashboard-contract.md`). Works for UDD AND LookML dashboards. Self-contained (reads `~/.looker/looker.ini`). `tileType` is read from `query.vis_config.type` (NOT `element.type`, which is always `"vis"`); `listen` from `result_maker.filterables`; layout from the **active** layout's components. |
| `scripts/parse_lookml_dashboard.py` | **Phase 1 (offline):** parse a `.dashboard.lookml` (YAML) → the SAME contract. Dev/test only; cannot see UDD dashboards. Requires PyYAML. |
| `scripts/detect_rls.py` | **Phase 1 (RLS scan):** dependency-free regex scan of a LookML dir/file (and/or model JSON) for row-level-security constructs (`access_filter`, `sql_always_where`, `access_grant`, `user_attribute`). Prints a structured summary + recommended Sigma mapping per finding (or `--json`). **Prints nothing / exits 0 when there's no RLS** (zero-overhead). `python3 detect_rls.py <lookml_dir> [--json]` |
| `scripts/apply_sigma_rls.py` | **Phase 1.5 (apply RLS):** scripted, API-driven RLS port. Reuse-first `GET /v2/user-attributes` (prints a match before creating); `--create` → `POST /v2/user-attributes`; `--assign` (+`--member-id`,`--value`) → `POST /v2/user-attributes/{id}/users`; `--field`/`--element-id` → print the verified RLS calc-col + element-filter snippet, `--apply --dm-id` → PATCH it into the DM element spec. **Read-only / plan-only by default — mutates only on an explicit `--create`/`--assign`/`--apply` flag.** Reads `$SIGMA_BASE_URL`/`$SIGMA_API_TOKEN` like `post_dm.py`. |
| `scripts/convert_dm.mjs` | **Phase 2:** run `convertLookMLToSigma` against a directory of `.lkml` files for one explore → a Sigma DM spec JSON + `…-warnings.json` sidecar. A `.model.lkml` is optional — with none it converts **view-only** (each view → standalone element; pass the WHOLE directory so cross-view `${view.SQL_TABLE_NAME}` refs resolve — see `refs/layered-lookml.md`). Bypasses the deployed MCP build (see the converter-build gotcha below). Env: `LOOKML_DIR`, `CONVERTER_SRC`; args `<exploreName> <out.json>`. |
| `scripts/lookml-dm-signature.py` | **Phase 2.5:** LookML view files → DM-reuse signature (`{warehouse_tables, referenced_columns, measures}`) for `find-or-pick-dm.rb`. Pure, no network. |
| `scripts/find-or-pick-dm.rb` | **Phase 2.5:** scan existing Sigma DMs and recommend reuse (score = 0.7·column + 0.2·table + 0.1·metric overlap; `--auto-pick` with tie-window safety). Shared vendor-neutral copy (canonical: tableau-to-sigma; needs `scripts/lib/sigma_rest.rb`). Non-destructive. |
| `scripts/post_dm.py` | **Phase 2:** POST a DM spec to `/v2/dataModels/spec` (auto-finds a writable folder, swaps in the full connection UUID). Env: `SIGMA_API_TOKEN`, `SIGMA_BASE_URL`, `SIGMA_CONNECTION_ID`; args `<spec.json>`. |
| `scripts/build_workbook.py` | **Phase 3:** dashboard contract + the explore's view `.lkml` files → a Sigma `/v2/workbooks/spec` body (hidden Data page + master table, one element per tile, controls from filters, newspaper→24-col layout XML). Generates locally; does **not** POST. Handles ratio measures, joined-col `Field (alias)` naming, table calcs, pivot-flatten + warn. Layout: a top control bar (row 0), a full-width strip of **tall** KPI tiles (height ≥ 6 so titles render), then the remaining tiles shifted down. |
| `scripts/looker-render-dashboard.py` | **Phase 4 (visual QA — SOURCE side):** render a LIVE Looker dashboard to PNG via the Looker render API (`POST /render_tasks/dashboards/{id}/png` → poll `GET /render_tasks/{task_id}` until `success` → `GET .../results`). Pairs with `sigma-export-png.py` for source-vs-migrated side-by-side. Reuses `looker_api.py` `~/.looker/looker.ini` auth. `python3 looker-render-dashboard.py <dashboard_id> [out.png] [--w 1200 --h 1600]`. |
| `scripts/sigma-export-png.py` | **Phase 4 (visual QA — MIGRATED side):** render a posted workbook page or element to PNG via `POST /v2/workbooks/{id}/export` → poll `GET /v2/query/{queryId}/download`. For side-by-side layout/render checks against the source Looker dashboard render (catches hidden KPI titles, orphaned filters, overlaps, bare-number vs `$`/`%` formats that a numeric parity check can't). **Read each migrated PNG and check it against `refs/layout-visual-qa.md` (mandatory gate — see Phase 4a).** Reads `$SIGMA_BASE_URL`/`$SIGMA_API_TOKEN`. `python3 sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/x.png` (or `--element <id>`). |
| `scripts/build_looker_dashboard.py` | **TEST-FIXTURE BUILDER (not a migration step).** Builds the "Orders Overview" UDD on `csa_thelook` via the Looker API (4 KPIs + line/column/bar/pie + grid, 3 filters wired via `result_maker.filterables.listen`). |
| `scripts/build_looker_dashboard2.py` | **TEST-FIXTURE BUILDER (not a migration step).** Builds the "Orders Deep Dive" UDD — area, pivot, table-calcs, scatter, donut, text tile — the harder dashboard surface for the converter. |
| `scripts/gap-scout.md` | **Gap scout (converter gaps):** runbook for the main agent — when/how to spawn a scout subagent for a LookML construct the converter can't translate, the LookML→Sigma candidate table, and the opt-in issue-filing flow. Read before spawning. |
| `scripts/scout-validate.py` | **Gap scout:** validate a candidate Sigma formula against a real DM element (throwaway test workbook → check column type ≠ `error` → delete), persist a win to `~/.looker-to-sigma/learned-rules.yaml`, or return an opt-in `escalation` block on failure. Also a quick "does this formula resolve?" check for Phase-4 validation. Reads `$SIGMA_BASE_URL`/`$SIGMA_API_TOKEN`. |
| `scripts/learned-rules.py` | **Gap scout:** loader for the customer-local `learned-rules.yaml` (`load()`/`apply()`); applied to LookML measure expressions before the converter/WARN fallback. Home = `~/.looker-to-sigma` (override `LOOKER_TO_SIGMA_HOME`). |
| `scripts/escalate-gap.py` | **Gap scout (shared, identical across all migration skills):** opt-in GitHub-issue filer — category→repo routing, dedupe (open issues + beads), converter-repo mirroring, bead cross-link. **Dry-run by default; files only with `--yes`.** Requires `gh`. |

> **Test-fixture builders vs migration scripts.** `build_looker_dashboard.py` /
> `build_looker_dashboard2.py` **author** Looker dashboards (migration *targets*); they are
> for standing up known demo content to convert and parity-check. Never run them against a
> customer's Looker. Everything else converts *from* Looker *to* Sigma.

---

## Prerequisites

### Looker credentials (`~/.looker/looker.ini`)

```ini
[Looker]
base_url=https://<your-instance>.cloud.looker.com:19999
client_id=<API3 client_id>
client_secret=<API3 client_secret>
verify_ssl=True
```

- **API 4.0**, key-pair-free `client_credentials` (login on `:19999` returns a bearer).
- The credential's user needs **Admin** (or at least: see models, dashboards, run queries, and
  — for the test-fixture builders or Git-deploy flow — develop + deploy).
- Generate an API3 key in Looker: **Admin → Users → (your user) → Edit Keys → New API3 Key**.
- Test: `python3 scripts/looker_api.py whoami` → prints HTTP 200, your display name + roles.

### Sigma credentials

`eval "$(scripts/get-token.sh)"` exchanges `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` (from
`~/.sigma-migration/env`, written by the `sigma-api` skill's `setup.rb`) for a `SIGMA_API_TOKEN`.
Also note your **full connection UUID** (`SIGMA_CONNECTION_ID`) and a writable **folderId**.

> Tokens live ~1 hour. Re-fetch when a curl returns 401. Never use
> `TOKEN=$(eval "$(scripts/get-token.sh)")` — `$()` is a subshell where the exported var dies.
> Keep `eval` + `curl` in the same `bash -c '...'` invocation.

> **Inline Python/Node inside bash — DON'T.** Triple-nested escapes silently break. Always
> write a `.py`/`.mjs` file with `Write` and call it via `python3 file.py` / `node file.mjs`.
> The scripts here already follow that rule.

### The Looker-side warehouse connection (one-time, for live parity)

Looker needs its **own** direct warehouse auth — Sigma's connection UUID is Sigma-side and
unusable for Looker. To stand up an end-to-end test pointed at the same warehouse as Sigma
(so 3-way parity is meaningful):

- **Snowflake service identity:** create a `SERVICE`-type user with **key-pair** auth (Snowflake
  blocks single-factor passwords for service users) + a role granting USAGE on the warehouse +
  the db/schema and SELECT on the tables/views.
- **Looker connection** (`POST /connections`): `uses_key_pair_auth: true`, `certificate` =
  base64 of the `.p8` private key, `file_type: ".p8"`, warehouse via
  `jdbc_additional_params=warehouse=<WH>`, host `<account>.snowflakecomputing.com`. Test via
  `PUT /connections/{name}/test`.
- **Git-backed project + model:** create a project in the **dev** workspace, add a deploy key to
  the Git repo, set the git remote via **`PATCH /projects/{id}`** (PUT 404s). All dev-workspace
  mutations need **ONE persistent session** (`PATCH /session {workspace_id: dev}`).

> This setup is only needed to build a *live* test instance. For a customer migration the Looker
> instance + connection already exist — you just read from them.

---

## Phase 0 — Assess the Looker estate

Scope the migration before converting anything — inventory models/explores/dashboards, score
complexity, and rank a migration shortlist. This is handled by the **`looker-assessment`**
sibling skill (analogous to `tableau-assessment` / `qlik-assessment`). Run it first for any
multi-dashboard migration; skip it for a single known dashboard.

---

## Phase 1 — Discover the Looker content

Three transports, in order of preference: **Looker MCP** (when wired in) → **Looker REST API
4.0** (the default here) → **offline `.lkml`** (dev/test, can't see UDDs).

### 1a. Smoke-test + list

```bash
python3 scripts/looker_api.py whoami                 # confirm auth + admin
python3 scripts/looker_api.py raw GET /lookml_models  # list models
python3 scripts/looker_api.py raw GET /dashboards     # list dashboards (UDD + LookML)
```

For a specific explore's field graph:
`python3 scripts/looker_api.py raw GET /lookml_models/<model>/explores/<explore>`.

### 1b. Pull each dashboard into the normalized contract (live)

```bash
python3 scripts/fetch_looker_dashboard.py <dashboard_id> /tmp/<name>/<dash>.contract.json
```

> **Discovery speed: already sub-second.** A dashboard pull is one login (cached
> per process) + one `GET /dashboards/{id}` — there is no estate walk to optimize.
> For many-call sessions (parity, inventory) `looker_api.py`'s per-process token
> cache removes the per-call login round-trip (~150ms each).

This hits `GET /dashboards/{id}` and normalizes into `refs/dashboard-contract.md`. It works
for UDD **and** LookML dashboards (the API returns both identically). Key extraction details
(already handled by the script):
- **`tileType` comes from `query.vis_config.type`**, not `element.type` (which is always
  `"vis"` for chart tiles, `"text"` for text tiles).
- **`listen`** (which dashboard filters a tile obeys) comes from
  `result_maker.filterables[].listen`.
- **layout** comes from the **active** layout's `dashboard_layout_components[]`
  (`row`/`column`/`width`/`height`); ignore mobile variants.
- **`dynamic_fields`** (table calcs / client-side custom measures) arrives as a **JSON string**
  — the script `json.loads` it.

### 1c. Offline path (dev/test only)

```bash
python3 scripts/parse_lookml_dashboard.py <file.dashboard.lookml> --out /tmp/<name>/<dash>.contract.json
```

Same contract shape. Cannot see UDD dashboards; LookML dashboards may also lag the live UI
state (a `.dashboard.lookml` reflects source-of-truth, the API reflects edits). **Prefer the
API.** Note: a deployed LookML dashboard does NOT auto-index for `import_lookml_dashboard`
(Looker reindexes lazily, 404 until then) — just build/discover the UDD directly.

> **No live instance?** A GCP free-trial account CANNOT provision Looker (instance quota is
> `isFixed` = 0, Sales-gated). Build/test from sample LookML + the offline path. The validated
> end-to-end run used a real `hakkoda1.cloud.looker.com` instance pointed at `CSA.TJ`.

### 1d. Scan for row-level security (RLS) — cheap, silent if none

Looker enforces row-level security in LookML, and **security is the one place a silent default
is dangerous in both directions** — silently dropping RLS exposes data; silently porting a wrong
mapping over- or under-restricts it. So scan for it during discovery, but stay out of the way
when there's nothing to decide.

```bash
python3 scripts/detect_rls.py /path/to/lookml          # the project dir (and/or a model JSON)
```

- **Zero overhead on the happy path.** `detect_rls.py` is a cheap regex scan; **if it finds no
  RLS it prints nothing and exits 0** — no prompt, no extra phase, the migration proceeds
  straight to Phase 2 unchanged.
- **If it finds RLS, it lists every finding** (construct, explore, field, `user_attribute`,
  expression) plus the recommended Sigma mapping — that output feeds the **single** RLS decision
  gate below (do NOT prompt per rule). The constructs it detects, and their Sigma targets:

  | Looker RLS construct | What it does | Sigma target |
  |---|---|---|
  | `access_filter` (explore) | maps a `user_attribute` → a field; restricts rows to the caller's allowed values | a Sigma **user attribute** + a row filter using `LookupUserAttributeText(...)` / `CurrentUserAttributeText(...)` on that field |
  | `sql_always_where` (explore) | a hardcoded SQL row filter always ANDed onto the explore | a Sigma **data-model / element filter** (if the expression references a `user_attribute` / `{{ _user_attributes[...] }}`, make it a user-attribute row filter, not a static one) |
  | `access_grant` (model) | gates explores/fields/joins by a `user_attribute`'s allowed values | **note / review** — no 1:1 analog; map to Sigma **permissions** or a user-attribute filter |
  | `user_attribute` reference | any other `_user_attributes[...]` / `user_attribute:` use | **provision** the matching Sigma user attribute (reuse if it already exists) |

> The `convert_lookml_to_sigma` converter ALSO detects `access_filter` and emits an RLS note (and
> a `CurrentUserAttributeText()` row-filter stub) in the DM spec. `detect_rls.py` is the
> discovery-time, project-wide view that drives the **decision gate** — the converter handles the
> per-spec emission once you've decided to port.

---

## Phase 1.5 — RLS decision gate (only if Phase 1d found RLS) — BEFORE building

**Skip this phase entirely when `detect_rls.py` found nothing.** When it DID find RLS, stop ONCE,
here, before POSTing the data model in Phase 2 — make it one explicit, reviewed decision, never an
invisible default.

**The whole flow is scripted and API-driven** — Sigma user attributes are fully API-supported, so
reuse-first, provisioning, and the row filter itself are all done via `apply_sigma_rls.py` (no UI
step). Keep the framing intact (one consolidated gate, opt-in/out, never-silent); only the
mechanics are now concrete.

1. **Reuse-first — check what already exists in Sigma before creating anything (scripted).** The
   customer may have already set RLS up in Sigma; don't duplicate it.
   - **Existing Sigma user attributes** — list them via the API and match by name to the Looker
     `user_attribute`s in the findings. `apply_sigma_rls.py --attr <name>` does this:
     `GET /v2/user-attributes` (read-only, no flags) and prints a **REUSE:** line with the existing
     `userAttributeId` if one matches (case-insensitive), or "no existing attribute" otherwise.
     Reuse a matching attribute rather than creating a new one.

     ```bash
     bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/apply_sigma_rls.py --attr region'
     ```
   - **Existing data models with similar RLS logic** — if a Sigma DM already filters the same
     field by the same attribute (e.g. a previously-migrated explore on the same source), reuse it
     instead of re-implementing the filter.
2. **Pre-fill a recommended plan.** Using the mapping table above, draft the per-finding Sigma
   action (which user attribute, which field, `CurrentUserAttributeText` row filter vs DM/element
   filter vs note) — reusing the existing Sigma attributes/DMs found in step 1. Preview the exact
   row-filter spec for a finding with `apply_sigma_rls.py --attr <name> --field <DisplayName>
   --element-id <denorm-element-id>` (prints the calc-col + element-filter snippet; plan-only).
3. **One consolidated confirm / edit / skip.** Present the full plan and let the user, in a SINGLE
   decision: **confirm** it as drafted, **edit** any mapping (e.g. point at a different existing
   attribute, change a field), or **skip** porting RLS entirely (they may enforce it elsewhere in
   Sigma). No per-rule nagging. `apply_sigma_rls.py` is **plan-only by default** — it mutates ONLY
   when you pass `--create` / `--assign` / `--apply`, so running it through step 1–2 never changes
   anything before the user confirms.
4. **Always record the outcome.** For every finding, note **ported / reused / skipped** in the
   migration summary (Phase 4 output) so any skipped RLS is **visible, never silent** — a reviewer
   can see exactly which Looker restriction was carried over, reused, or deliberately dropped.

Then proceed to Phase 2 and apply the confirmed plan as part of the DM build, via the SAME script:

- **Provision the user attribute** (only if nothing reusable was found in step 1):
  ```bash
  bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/apply_sigma_rls.py \
    --attr region --value West --create'                       # POST /v2/user-attributes
  ```
- **Assign a value to the member(s)** who should be restricted (the value the user attribute
  resolves to per person — assign to the member that the parity query runs AS, or RLS returns 0
  rows):
  ```bash
  bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/apply_sigma_rls.py \
    --attr region --value West --member-id <memberId> --assign'  # POST /v2/user-attributes/{id}/users
  ```
- **Apply the row filter** to the DM element — the verified spec shape (a boolean calc column
  `CurrentUserAttributeText("<attr>") = [<Field>]` + an element `filters` entry
  `{kind:list, mode:include, values:[true]}`):
  ```bash
  bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/apply_sigma_rls.py \
    --attr region --field Region --element-id <denorm-element-id> \
    --dm-id <dataModelId> --apply'                              # GET → inject → PUT /v2/dataModels/{id}/spec
  ```

Mapping recap: `access_filter` and user-attribute `sql_always_where` → the
`CurrentUserAttributeText("<attr>") = [<Field>]` row filter above; static `sql_always_where` → a
plain DM/element filter; `access_grant` → the recorded note. (Team mode =
`CurrentUserInTeam([...])`; user-email mode = `[Email] = CurrentUserEmail()`.)

> **Proof:** this exact scripted flow was validated live end-to-end 2026-06-10 (Looker hakkoda1 →
> Sigma tj-wells-1989, `csa_thelook` order_fact, `region`/West) with **exact 3-way parity** —
> Looker-restricted == Sigma-restricted == warehouse = **$38,906.82 / 220 rows**.

---

## Phase 2 — Convert the LookML semantic model

LookML views + model → Sigma data model. Resolve the explore's join graph, convert, POST,
**register the model**, and verify.

### 2a. Convert with `convert_lookml_to_sigma`

The MCP tool `mcp__sigma-data-model__convert_lookml_to_sigma(files, connectionId, exploreName,
joinStrategy)` is the primary path. Feed it the **LookML model**, NOT the warehouse tables —
the converter walks the explore's `join`s to resolve `view.field` prefixes (alias vs `from:`
view) and emits one element per resolved view plus a denormalized explore element.

> **Converter-build gotcha.** The long-running MCP server serves the **deployed** build. After
> editing `src/lookml.ts` + `npm run build`, the running MCP tool still serves the OLD code
> until it restarts. For fixed output against an edited source tree, run the converter directly:
>
> ```bash
> LOOKML_DIR=/path/to/lookml \
> CONVERTER_SRC=/path/to/sigma-data-model-mcp/src/lookml.ts \
>   node --import tsx/esm scripts/convert_dm.mjs <exploreName> /tmp/<name>/dm-spec.json
> ```
>
> `convert_dm.mjs` reads `<model>.model.lkml` + every `views/*.view.lkml`, converts the explore
> with `joinStrategy: 'relationships'`, and writes `res.model` (the return property is `.model`,
> **not** `.sigmaDataModel`). It prints stats + warnings — **read every warning.**

### 2b. Converter coverage (all live-validated 2026-06-10) — and what's still lossy

The converter handles, end-to-end and clean:
- **Dimensions** — `tier`, sql `CASE`, legacy `case:` (→ nested `If()`), `html`/`link`, custom
  `value_format`.
- **Time + duration `dimension_group`** — one column per timeframe (`DateTrunc`); duration groups
  emit `sql_start`/`sql_end` physical columns.
- **Measures** — `sum`/`count`/`count_distinct`/`avg`/`median`/`percentile`/filtered/**ratio**.
  Measure `${dimension}` refs and measure-references-measure `${measure}` (ratio) refs resolve to
  the right Sigma formula; `1.0` literals preserved; `NULLIF` → `NullIf`.
- **Joins** — snowflake (multi-hop) joins wire the FK to the correct intermediate element (not
  always the base); `full_outer` + field-limited joins; `sql_always_where` / `always_filter`.
- **Other** — `derived_table`, `parameter` + Liquid, `drill_fields`, `set`, view/group labels,
  multiple explores per model.

These 8 converter bugs were found and **FIXED in source** (branch
`tj/lookml-robustness-ratio-percentile-html-fixes`); treat them as **handled**, but know the
shapes so you recognize a regression:

| # | Bug (now fixed) | What it produced before the fix |
|---|---|---|
| BUG1 | measure `${dimension}` refs unresolved | literal `Sum([${sale price}])` + phantom `${...}` columns |
| BUG2 | multi-hop (snowflake) joins mis-wired | FK hung off the base element instead of the intermediate |
| BUG3 | ratio measures (`${measure}`, `1.0`→`0`) | phantom column + `0 * ${...}` formula |
| BUG4 | `html:`/Liquid `%}` desynced the block parser | silently dropped ALL view fields after the html dimension |
| BUG5 | `percentile` → bogus `CountIf` | wrong aggregation |
| BUG6 | filtered `type:count` with no sql | bogus phantom value column |
| BUG7 | `type:duration` dimension_group | dangling `DateDiff` (no sql_start/sql_end) |
| BUG8 | legacy `case:{when/else}` dim | passthrough to a nonexistent column |

> If the running MCP build predates these fixes, use the `convert_dm.mjs` direct path (2a)
> against a patched source tree, OR repair the spec post-hoc — but the source fixes mean **raw
> converter output now POSTs clean with no in-spec workarounds**.

**Still lossy / unsupported (documented, warned — never silent):**
- **Liquid `{% parameter %}` measures** and **manifest constants** — Looker API-deploy cache
  quirk; review.
- **`link:` / `html:` styling** — dropped (data is fine; the styling/hyperlink is lost).
- **Pivot cross-tab** → flattened to columns + warn (rebuild as a Sigma `pivot-table` in the UI).
- **Table-calc grain/sort** for window functions (rank / offset / percentile) → review.
- **`merged_results`** → a DM join or a Custom SQL element (follow `merge_result_id` to the
  source queries; >2 sources or non-equi joins → manual + warn).
- **Not yet converted:** NDT (`explore_source`), PDT `datagroup`/`persist_for`, `many_to_many`.
- **RLS (`access_filter` / `sql_always_where` / `access_grant`)** — detected at discovery
  (Phase 1d) and decided ONCE at the Phase 1.5 gate, then ported via the scripted, API-driven
  `apply_sigma_rls.py` (reuse-first user-attribute lookup → create/assign → PATCH the
  `CurrentUserAttributeText("<attr>") = [<Field>]` row filter). The converter also emits an
  `access_filter` RLS note + `CurrentUserAttributeText()` stub. Never silently dropped — the
  outcome is recorded.

> **`metric()` returns "Missing Metric" in MCP SQL** — a known Sigma quirk, not a conversion
> bug. Verify metric values via the **raw aggregate** (`Sum(...)`, `CountDistinct(...)`), not via
> `metric()`.

### Phase 2.5 — Reuse an existing DM? (run BEFORE 2c — avoid sprawl, mirrors tableau Phase 1.5 / powerbi Phase 3.5)

Before POSTing a NEW data model, check whether an existing Sigma DM already covers the
same warehouse tables (don't add a 4th near-identical "Orders" DM):

```bash
python3 scripts/lookml-dm-signature.py --lookml-dir /path/to/lookml \
  --label "<explore label>" --out /tmp/<name>/dm-signature.json
bash -c 'eval "$(scripts/get-token.sh)" && \
  ruby scripts/find-or-pick-dm.rb --workbook-signature /tmp/<name>/dm-signature.json \
    --out /tmp/<name>/dm-match.json --auto-pick'     # exit 0 = candidate ≥ min-score
```

`lookml-dm-signature.py` derives `{warehouse_tables (sql_table_name FQNs),
referenced_columns (dimension/measure names), measures}` straight from the LookML view
files — the same files you fed `convert_dm.mjs`. Decision:
- **Score ≥ 0.6** → **ASK the user** reuse-vs-new: surface the candidate name, matched
  cols (N/M), and the inherited-extras warning from `dm-match.json`. If they reuse, run a
  **shape preflight** first — read the candidate DM's spec back and confirm every column
  the dashboards reference resolves on the element you'll wire to (no `type=error`
  columns; fact vs separate-dim location) — then **skip 2c/2d** and point Phase 3's
  workbook masters at the matched `recommended_dm_id` + its element ids. With
  `--auto-pick` a clear winner (no tie within 0.05) skips the prompt — still WARN about
  inherited columns/RLS/metrics.
- **Score < 0.6** → POST new (2c) and TELL the user no reusable DM was found.

### 2c. POST the data model

```bash
bash -c 'eval "$(scripts/get-token.sh)" && \
  SIGMA_CONNECTION_ID=<full-connection-uuid> \
  python3 scripts/post_dm.py /tmp/<name>/dm-spec.json'
```

- Endpoint is `POST /v2/dataModels/spec` (NOT `/v2/workbooks/spec`).
- **Use the FULL connection UUID** (e.g. `bc0319f8-9fe0-4315-aea3-6a2d1eef0623`), not a short
  prefix — `convert_dm.mjs` writes a placeholder `connectionId`; `post_dm.py` swaps in
  `$SIGMA_CONNECTION_ID`.
- **`folderId` is required** — `post_dm.py` auto-picks a writable folder (preferring one whose
  name mentions LOOKER/MIGRATION/TEST).
- **The spec endpoints return YAML** (`success: true\nworkbookId: …`), not JSON — never
  `json.load` the response or pipe it to `jq`.

Record the returned `dataModelId` and (after a read-back) the element IDs.

### 2d. Register the model + verify

> A freshly POSTed/deployed LookML model **404s on query until you register it** (Looker side
> for the Looker model; this is the deploy flow for standing up a test instance):
>
> ```
> PATCH /session {workspace_id: dev}
> PUT  /projects/{id}/git_branch {name: <dev-branch>, ref: origin/main}   # pull pushed commits into dev
> POST /projects/{id}/validate                                            # expect 0 errors
> POST /projects/{id}/deploy_to_production                                # 204
> POST /lookml_models {name, project_name, allowed_db_connection_names:[<conn>]}
> ```
>
> LookML param gotcha: params are **not** semicolon-separated — compact
> `{ primary_key: yes; hidden: yes; sql: ... ;; }` fails ("Invalid lookml syntax") and cascades
> into bogus join/field errors. Use multi-line blocks (only `;;` terminates a `sql`).
> A refinement `view: +x` in a glob-included file fails ("Could not find a view to extend") —
> fold the param/measure into the base view.

**Verify the Sigma DM:** `mcp__sigma-mcp-v2__describe` the element (no `type=error` columns;
metric formulas resolve clean), then `mcp__sigma-mcp-v2__query` a raw aggregate and confirm it
matches the warehouse.

---

## Phase 3 — Convert the dashboards (UDD = primary)

For each Looker dashboard, fetch its contract (Phase 1b), then build a Sigma workbook spec.

### 3a. Build the workbook spec

```bash
python3 scripts/build_workbook.py /tmp/<name>/<dash>.contract.json \
  --views /path/to/lookml/views \
  --dm-id <dataModelId> \
  --element-id <denorm-element-id> \
  --dm-element-name "<DM element display name>" \
  --folder-id <writable-folder-id> \
  --out /tmp/<name>/<dash>.workbook.json
```

(`contract` is positional. `--dm-element-name` is the display name of the data-model element
the master table pulls from; `--master-name` defaults to `Data`. The generated spec has
placeholder defaults for any flag you omit, so it always generates locally — fill in the real
ids before POSTing.)

`build_workbook.py` consumes the contract + the explore's view `.lkml` files (to classify each
`view.field` as a measure — agg + base col — or a dimension, and derive the Sigma formula) and
emits a `/v2/workbooks/spec` body:
- a **hidden "Data" page** with a master table sourced from the DM element,
- a **dashboard page** with one element per Looker tile,
- **controls** from the dashboard filters,
- a **newspaper → 24-col grid layout** XML string.

Tile-type, filter-type, and layout maps are in `refs/dashboard-contract.md` and
`refs/looker-dashboard-layout.md` — **do not duplicate them; defer there.** Summary:

| Looker tile `type:` | Sigma kind |
|---|---|
| `single_value` | `kpi-chart` |
| `looker_column` / `looker_bar` | `bar-chart` |
| `looker_line` | `line-chart` |
| `looker_area` | `area-chart` |
| `looker_pie` | `pie-chart` |
| `looker_donut_multiples` | `donut-chart` (single ring) + warn |
| `looker_scatter` | `scatter-chart` |
| `looker_grid` / `table` | `table` |
| `text` | `text` (markdown body) |
| `looker_map` / geo / funnel / waterfall / boxplot / sankey / custom viz | none — approximate or drop + warn |

Newspaper layout math (a single arithmetic transform, no spatial heuristic):
`gridColumn = (col+1) / (col+1+width)`, `gridRow = (row+1) / (row+1+height)`. `tile` / `static`
/ `grid` modes need a snap heuristic (lossy) — warn + stack; see `refs/looker-dashboard-layout.md` §3.

### 3b. Workbook-spec gotchas (learned the hard way)

- **`/v2/workbooks/spec` returns YAML** — don't `json.load` the response.
- **control elements** live in `page.elements[]` with `kind: control` but REQUIRE an `id`
  (separate from `controlId`); a missing `id` → `Invalid kind: "control"`.
- **KPI `value` uses `value.columnId`** on the live API (the `sigma-workbooks`
  `example-full.yaml` shows `value.id` — the API wants `columnId`). **BUT donut/pie `value`
  uses `value.id`** (not columnId) — the two element types genuinely differ; verified by POST
  400s both ways.
- **Chart `color` channel differs by type:** bar/area/line series = `{by: "category", column:
  <id>}`; donut/pie slice = `{id: <id>, sort?}`. (A Looker pivot maps to this color channel.)
- **donut/pie use `value` + `color`, NOT `xAxis`/`yAxis`.**
- **KPI comparison (`show_comparison`) has NO spec slot** — warn, don't build. (Recommend a 2nd
  KPI tile or a UI delta post-publish.) Looker `donut_multiples` per-multiple dim is also dropped → warned.
- **Master → DM-element refs:** a master table sourcing a DM element references columns as
  `[<DM-element-NAME>/<col display>]`; tiles then reference `[<master-NAME>/<col display>]`.
- **Joined-view columns** in the denorm DM element are named `<Field> (<joinAlias>)` (Sigma
  disambiguates cross-element lookup cols) — master/tile refs must include the suffix, e.g.
  `[Order Fact/Region (customer_dim)]`.
- **Table calcs** → workbook formula columns: `running_total` → `CumulativeSum`,
  `pct_of_total`/`sum()` → `GrandTotal`, `offset(…,-1)` → `Lag`. (`build_workbook.py` translates
  these; `dynamic_fields` arrives JSON-parsed from discovery.)
- **count on a joined view** → `CountDistinct` using that view's primary key (base-view counts
  stay `Count()`).
- **Number formats carry through.** A LookML measure's `value_format_name` (`usd`, `usd_0`,
  `percent_0/1/2`, `decimal_0/1/2`, …) or custom `value_format` mask becomes the Sigma column
  `format` object — `{kind: "number", formatString: "<d3-format>"}` — on the tile's value /
  KPI-value / chart-measure / measure-table column. So a `usd` measure renders `$110,342.75`
  (not bare `110,342.75`) and a `percent_1` measure renders `12.3%`. `build_workbook.py`'s
  `build_field_index` captures each measure's format and `apply_fmt` attaches it; custom masks are
  best-effort (currency symbol / thousands separator / decimals / percent). Counts and dimensions
  get no format (raw). Without this the side-by-side render (Phase 4a) shows bare numbers where
  Looker showed `$`/`%`.

### 3c. POST the workbook + verify

POST the spec to `/v2/workbooks/spec` (returns YAML → record the `workbookId`). Then
`mcp__sigma-mcp-v2__describe` each element (no `type=error` columns) and confirm the layout
applied. **POST is create-only** — every subsequent spec edit MUST use `PUT
/v2/workbooks/{id}/spec`; re-POSTing leaves orphan workbooks in My Documents (delete via `DELETE
/v2/files/{id}`).

---

## Phase 4 — Verify parity (3-way: Looker vs Sigma vs warehouse) — MANDATORY

A conversion is not complete until the numbers tie out. Compare at **two grains**: the model's
key metrics, and per-tile.

### 4-pre. The scripted gate (canonical — what migrate-looker.py runs)

```bash
ruby scripts/phase6-parity-looker.rb --workdir /tmp/<name> --workbook-id <wb>   # PASS 1: plan
# … fetch ACTUAL (Sigma CSV export / mcp__sigma-mcp-v2__query) + EXPECTED
#   (Looker POST /queries/run/json, or the warehouse re-aggregation offline) …
#   → write parity-expected.json + parity-actuals.json (shape: {"<chart>": [[dim,val],…]})
ruby scripts/phase6-parity-looker.rb --workdir /tmp/<name> --finalize           # PASS 2: sentinel
ruby scripts/assert-phase6-ran.rb   --workdir /tmp/<name> --workbook-id <wb>    # must exit 0
```

The finalize pass writes the **`parity-final.json` sentinel**; `assert-phase6-ran.rb`
(hard gate, vendored byte-identical across the 5 plugins) refuses GREEN unless
parity ran + PASSed, no orphan workbooks were left, the live workbook has no
`type=error` columns, a real layout is applied, the layout lint passes (gate 6),
and the control lint passes (gate 7 — dead/ghost/partial controls; see
`refs/control-parity.md`). Optional runtime follow-up when controls exist:
`ruby scripts/probe-controls.rb --workbook-id <wb> --check-out-of-closure`
(flip test — in-closure export must change under a non-default control value,
out-of-closure must not). `migrate-looker.py` automates
both fetch sides and runs the gate for you. The manual 3-way checks below remain
the reference for what "parity" means.

1. **Looker** — `POST /queries/run/json` (or `run_inline_query`) for the model/explore, e.g.
   net revenue by region.
2. **Sigma** — `mcp__sigma-mcp-v2__query` against the DM element (raw aggregate, since
   `metric()` returns "Missing Metric") AND against each workbook chart element.
3. **Warehouse** — the source-of-truth `SELECT` (via the Sigma connection or `snow`).

GREEN only when all three match. The validated run produced **exact** parity to the cent —
region revenue (West 38906.82 / South 31650.98 / NE 21587.52 / MW 14966.20 / null 3231.23 =
$109,765.89) and the ratio metrics (AOV / margin / return) identical across Looker and Sigma.

### 4a. Visual QA — render BOTH dashboards to PNG and eyeball them side-by-side

Numbers tying out is necessary but not sufficient — a workbook can be GREEN on parity yet look
broken (hidden KPI titles, orphaned filters, overlapping tiles, the wrong chart kind, bare numbers
where Looker showed `$`/`%`). After POSTing, render **both** the Looker source dashboard and the
migrated Sigma workbook to PNG and inspect them side-by-side:

```bash
# (1) SOURCE — render the live Looker dashboard (reads ~/.looker/looker.ini)
python3 scripts/looker-render-dashboard.py <dashboardId> /tmp/<name>/looker-<dash>.png

# (2) MIGRATED — render the Sigma workbook page
bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/sigma-export-png.py \
  --workbook <workbookId> --page page-dash --out /tmp/<name>/sigma-<dash>.png'
```

Read both PNGs and compare tile-for-tile. Confirm: **KPI tile titles show** (the builder lays KPIs
≥ 6 rows tall — a `kpi-chart` hides its title below ~5 rows / ~150px; see
`feedback_sigma_kpi_label_height.md`), the **filters sit in a top control bar** (not orphaned at
the bottom), tiles are aligned with no large empty regions, each chart kind matches Looker, and
**number formats match** — if Looker shows `$176.85` the Sigma KPI must too (the builder carries
LookML `value_format_name` / `value_format` into the tile column `format`; see Phase 3). Iterate on
`build_workbook.py` + re-`PUT` the spec until the side-by-side render is clean.

**Visual QA is a mandatory gate — never skip, never declare done on HTTP 200.** A workbook that
POSTs cleanly and passes parity can still be visually broken (overlapping tiles, clipped KPI titles
below ~5 rows, dead zones, orphaned filters; Sigma's grid has no z-order). After rendering the
migrated pages with `sigma-export-png.py` (side-by-side vs `looker-render-dashboard.py`):
1. **Read each migrated PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking,
   no dead zones, controls placed in-band, no clipped KPI titles, even heights, right chart kind/format).
2. Fix any failure in the spec — for multi-page workbooks use
   `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) — then **re-render and re-read**.
3. Loop until the render passes inspection.

**Record the RLS outcome here.** If Phase 1d found RLS, the migration summary MUST list, per
finding, whether it was **ported / reused / skipped** (and the Sigma user attribute + filter used)
— so any skipped Looker restriction is visible to a reviewer, never silently dropped. (When RLS
is active, parity-check as a representative restricted user, not only as an admin who sees all
rows.)

> **If `mcp__sigma-mcp-v2__query` errors with an auth message mid-Phase-4**, the MCP session
> staled — re-call `mcp__sigma-mcp-v2__begin_session` and retry. Do not skip parity over a
> recoverable auth error.

---

## Phase 5 — Enhance (post-publish, UI-only features)

Some Looker features have no spec-API analog and must be wired in the Sigma UI after publish.
Set expectations up front (they appear as warnings from `build_workbook.py`):

- **Cross-filtering** (clicking a Looker bar filters siblings) → Sigma "Set as filter" actions —
  UI-only.
- **Trellis / small multiples** (incl. `looker_donut_multiples`) → Sigma trellis — UI-only; the
  spec API silently drops trellis fields.
- **Tooltips / `note_text` / `subtitle_text`** → no spec slot; concatenate into the chart title
  or add an adjacent `text` element.
- **KPI comparison** (`show_comparison`) → add a 2nd KPI tile or a UI delta.
- **Pivot cross-tab** → rebuild the flattened table as a Sigma `pivot-table` in the UI.
- **Per-tile refresh intervals** → Sigma has workbook-level scheduled refresh only — drop + warn.

---

## Gap scout — when the converter can't translate a LookML construct

When `convert_lookml_to_sigma` only approximates or drops a LookML measure/construct (a ratio /
`${measure}`-ref measure, a `type: percentile`, a filtered count, a Liquid `{% parameter %}`
measure), spawn the **gap scout** subagent to find a Sigma formula that resolves on the live site,
then persist it so the next dashboard reuses it. The full runbook (when to spawn, the spawn
prompt, the LookML→Sigma candidate table, opt-in issue filing) is in **`scripts/gap-scout.md`** —
read it before spawning.

- `scripts/scout-validate.py` validates a candidate against a real DM element (builds a throwaway
  test workbook, checks the column's resolved type, deletes it) and persists a win to
  `~/.looker-to-sigma/learned-rules.yaml` (`scripts/learned-rules.py` loads + applies it).
- On failure it returns an `escalation` block. Filing a GitHub issue is **opt-in /
  confirm-before-file** — run `escalation.dry_run_cmd` (files nothing; drafts the issue + dedupes),
  show the user, and only run `escalation.file_cmd` (`escalate-gap.py … --yes`) if they accept.
  LookML construct gaps are **converter** gaps and mirror to both converter repos with a bead.

This is also a lightweight way to **validate a migrated DM/workbook**: point `scout-validate.py`
at the denorm element to confirm a suspect formula resolves (no `type:error` column) before
declaring Phase 4 green.

---

## Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| `convert_dm.mjs` output still has the old bug shape | Edited `src/lookml.ts` but the MCP server serves the deployed build | Run `convert_dm.mjs` via `node --import tsx/esm` against the patched `src/` (or restart the MCP server) |
| Converter dropped all view fields after an `html:` dim | Stale build predating BUG4 fix | Use the patched source path; the `;;`-block pre-extraction now includes `html`/`sql_on`/etc. |
| Metric formula contains `${...}` literals or `0 *` | Stale build predating BUG1/BUG3 fixes | Patched source resolves `${dim}`/`${measure}` refs and preserves `1.0` |
| `metric()` returns "Missing Metric" in a Sigma query | Known Sigma quirk | Verify via raw aggregate (`Sum`/`CountDistinct`), not `metric()` |
| `Source not found: warehouse table …` on DM POST | Short connectionId, or table not in Sigma's static catalog | Use the FULL connection UUID; if still failing, source via a Custom SQL DM element (`kind: "sql"`) |
| `jq: parse error: Invalid numeric literal` | Sigma spec endpoints return YAML | Never pipe spec responses to `jq` / `json.load` |
| `Invalid kind: "control"` on workbook POST | Control element missing its own `id` (separate from `controlId`) | Add a distinct `id` |
| KPI POSTs 400 with `value.id` / donut POSTs 400 with `value.columnId` | The two element types use different value keys | KPI → `value.columnId`; donut/pie → `value.id` |
| Tile shows the wrong chart kind | Read `element.type` (always `"vis"`) instead of `query.vis_config.type` | `fetch_looker_dashboard.py` already reads `vis_config.type` — re-fetch the contract |
| Looker LookML deploy fails "Invalid lookml syntax" | Compact `{ a: yes; b: yes; }` params | Use multi-line blocks; only `;;` terminates a `sql` |
| LookML model 404s on query right after deploy | Model not registered | `POST /lookml_models {name, project_name, allowed_db_connection_names}` |
| `PUT /projects/{id}` 404 when setting git remote | Wrong verb | Use `PATCH /projects/{id}` |
| Looker dev-workspace mutation has no effect | The calls ran in separate processes/sessions (the bearer cache is per-process; a 401 re-login also starts a NEW session that resets the workspace to production) | Do the whole dev flow in ONE process — `looker_api.py`'s cached token keeps one session, so `PATCH /session {workspace_id: dev}` sticks for subsequent `call()`s; re-PATCH after any forced re-login |
