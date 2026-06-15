---
name: tableau-to-sigma
description: >-
  Convert a Tableau datasource or workbook into a Sigma data model and matching
  dashboard. Use when the user has a Tableau datasource, TDS file, or Tableau
  workbook and wants to recreate it in Sigma. Discovery, calc-field translation,
  data model + workbook creation via REST API, layout generation, and parity
  verification — driven by `scripts/*.rb`.
user-invocable: true
---

# Tableau → Sigma Conversion

Convert a Tableau datasource into a Sigma data model, then build a Sigma workbook
that mirrors the Tableau dashboard layout as closely as possible.

**Read ALL of the following before replying or taking any action. Do not make assumptions about skill conventions, prompts, or global instructions — read the files.**
- `refs/column-gotchas.md` — column naming rules and special-character landmines
- `refs/data-model-spec.md` — data model JSON schema, element format, relationship format
- `refs/workbook-layout.md` — Ruby layout generation (mandatory), multi-series chart patterns
- `refs/story-points.md` — Tableau stories → one Sigma page per story point (`build-story-pages.rb`)
- `refs/blending.md` — data-blend detection + routing decision tree (same-warehouse repoint / VDS materialize / flag)
- `refs/window-functions.md` — Tableau window/table calcs → Sigma-native window math (WINPROBE-validated mapping table, two-level helper shape, sort/partition/week-anchor rules, manual residues)
- `refs/coverage-matrix.md` — converter-wide Tableau→Sigma coverage matrix (every construct → Sigma output + status: ✅ spec / 🧩 workbook pattern / 🔐 reported / 🟡 verify / ❌ flagged / ⛔ silent gap). Static companion to the per-workbook `scan-workbook-gaps.rb` readout.

**For canonical workbook spec shape** (element kinds, source kinds, controls, formulas, formatting), defer to the companion **`sigma-workbooks`** skill (install it if you haven't — it's the canonical Sigma workbook spec reference). This skill restates only the Tableau-conversion-specific patterns; everything else (KPI fields, color channel, pivot-table shape, manual sources, container styling, YAML default, etc.) lives there. Read its `reference/specification/` whenever you need the current spec surface.

---

## One command (orchestrated path)

```bash
eval "$(scripts/get-token.sh)"
# PASS 1 — discover → gap gate → DM-reuse scan → DM → workbook → layout → parity plan
ruby scripts/migrate-tableau.rb \
  --workbook "<name>" --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
  [--db CSA --schema TJ] [--name '<prefix>'] [--row-scale 1.5] \
  [--reuse-dm [ID]] [--force] [--yes]
# … pass 1 auto-fills <workdir>/parity-actuals.json via the pooled CSV-export
#   collector (collect-parity-actuals.rb); run the printed mcp-v2 queries for
#   the REMAINING charts only (pivot grids) and merge them in …
# PASS 2 — finalize: phase6 verify + cleanup-orphans + census-aware hard gate
ruby scripts/migrate-tableau.rb --workbook "<name>" \
  --finalize --actuals <workdir>/parity-actuals.json [--allow-missing-tiles N]
```

Chains the scripted spine (discover → scan-workbook-gaps → discover-columns →
find-or-pick-dm → DM build/validate/post → build-charts-from-signals → workbook
post-and-readback → build-dashboard-layout + put-layout → phase6-parity →
cleanup-orphan-workbooks + assert-phase6-ran) and STOPS with exact instructions
wherever agent judgment is genuinely required. Phase 1 is **interleaved**:
Tableau discovery + gap scan run as a background lane while the pure-Sigma-side
read-only phases (1.6 DM-reuse scan, 2 warehouse columns) run concurrently; the
lanes join before anything consumes discovery output, so every designed
stop/gate fires exactly as in the serial flow. A `PHASE TIMINGS` summary line
prints at every terminal exit so the speedup stays visible. Exit codes: `10` = OPEN QUESTIONS
(re-run with `--yes`/`--answers`), `11` = ❌-unhandled gap-scan features (close via
gap-scout or `--force`), `12` = pass 1 done, parity PENDING (collect mcp-v2 actuals,
then `--finalize`), `4` = DM posted but the workbook layer needs the agent path,
`3` = a gate failed, `14` = migration GREEN + Phase E proposals pending
acceptance, `0` = ALL gates green (only reachable via `--finalize`).
DM-reuse defaults to BUILD NEW — candidates are printed; `--reuse-dm` opts in.
Optional `--enhance [--enhance-accept <ids|all-low-risk>]` runs Phase E
(opt-in) after all gates are green — see the Phase E section below.

**Still manual by design (the orchestrator stops and tells you):**
- **Parity actuals (pivot grids only)** — pass 1 now collects actuals for every
  exportable chart itself: `collect-parity-actuals.rb` pools the element CSV
  exports (`POST /v2/workbooks/{wb}/export` → poll → download, 5-wide, under
  `sigma_rest`'s auto-refresh) straight into `parity-actuals.json`. Only
  pivot-tables stay agent-mediated (their CSV export is the WIDE grid, not the
  long row/col/value tuples the plan compares) — pass 1 prints exactly those
  `mcp__sigma-mcp-v2__query` calls; merge their rows into the same file.
- **Empty-view-CSV recovery** — a view that exports an empty CSV produces no
  chart; surfaced at the OPEN-QUESTIONS checkpoint AND by the tile census at
  `--finalize` (exit 7 → rebuild the chart manually or explain with
  `--allow-missing-tiles`, naming the zones in your report).
- **Master-level calc overrides** — when the workbook layer exits 4 naming a
  field like `master/ship speed category`, translate the Tableau calc (see
  `calc-fields.json`) and re-run the same command with
  `--master-col 'Name=<Sigma formula>'`.
- **Shared relative-date filters** — a dashboard-wide filter like
  `'Order Date ' = this year` only surfaces as a uniform parity DIVERGE (every
  Sigma value too big). Fix: expose the date key on the DM if the converter
  consumed it, add a master boolean (e.g. `[Order Year] = Year(Today())`) plus a
  master `filters: [{id, columnId, kind: list, mode: include, values: [true]}]`
  entry — it propagates to every chart sourcing the master — then re-query and
  re-`--finalize`. (Validated live on Orders Conversion Test, 2026-06-10.)
- **❌-unhandled gap features** — gap-scout subagent or `--force` (degraded).
- **DM-reuse shape preflight** — when `--reuse-dm` hits a differently-shaped DM
  the workbook gate exits 4; run Phase 1.5b (`inspect-dm-shape.rb`) and the
  agent path against the reused DM.

## Scripts

The conversion is driven by `scripts/*.rb`. Each script encapsulates one mechanical
phase. You compose them; the agent's role is judgment (which DM/workbook shape,
which calc translation, which layout) — not orchestration.

| Script | Purpose |
|---|---|
| `scripts/migrate-tableau.rb` | **The one command** — chains the whole scripted spine (gap gate → DM-reuse scan → DM → workbook → layout → two-pass parity → cleanup + census gate) and stops with exact instructions where agent judgment is required. See "One command" above. |
| `scripts/setup.rb` | One-time Sigma credential setup |
| `scripts/get-token.sh` | Exchange `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` for `SIGMA_API_TOKEN` (~1h TTL) |
| `scripts/setup-tableau.rb` | One-time Tableau PAT setup (only needed for PAT mode — see `refs/tableau-rest.md`) |
| `scripts/get-tableau-token.sh` | One-shot signin → exports `TABLEAU_AUTH_TOKEN` + `TABLEAU_SITE_ID` |
| `scripts/tableau-discover.rb` | PAT-mode Phase 1 discovery in one CLI: workbook + views + VDS metadata + GraphQL + .twb content. ONE unified fetch pool (default 5, `--pool N`, longest-job-first) with 429/timeout backoff + 401 re-mint; always writes per-task `timings.json`. Measured 61.8s → 13.7–18.9s on the 7-view reference workbook |
| `scripts/scan-workbook-gaps.rb` | **Phase 0a (mandatory):** scan a `.twb` and emit `gaps-report.md` + `gaps.json` categorising every feature into ✅ auto / ⚠️ hint / 🛠 manual / ❌ unhandled. Run BEFORE any other phase. Also detects multi-datasource **data blends** (secondary `datasource-dependencies` + linking fields) and writes `blend-plan.json` with a per-blend route — same-warehouse-repoint / materialize-via-vds / flag-unreachable (decision tree: `refs/blending.md`). |
| `scripts/gap-scout.md` | **Phase 0a-scout:** subagent prompt + protocol for resolving ❌ Unhandled gaps. Main agent spawns one scout per gap via the Agent tool. |
| `scripts/validate-sigma-formula.rb` | Scout primitive: POST a tiny test workbook with a candidate formula, read back column types, return JSON `{ status: ok|error }`. Auto-expands the DM element's columns onto the test master so candidate refs to real data resolve. |
| `scripts/scout-validate-and-persist.rb` | Scout wrapper: call validate-sigma-formula, on success append the rule to `~/.tableau-to-sigma/learned-rules.yaml` (customer's HOME, never the skill repo), on failure write `~/.tableau-to-sigma/escalations/<ts>-<slug>.yaml` AND return an opt-in `escalate-gap.py` command (confirm-before-file). |
| `scripts/escalate-gap.py` | Shared opt-in issue filer. Dry-run by default (drafts the issue + dedupes against open issues/beads); files only with `--yes`. Routes by gap category: converter→`sigma-data-model-manager`+`sigma-data-model-mcp` (mirrored), builder/skill→`sigma-migration-skills`. |
| `scripts/learned-rules.rb` | Loader module: reads `~/.tableau-to-sigma/learned-rules.yaml` at startup. Customer-discovered rules apply BEFORE the built-in translators in `build-charts-from-signals.rb`. |
| `scripts/parse-twb-layout.rb` | Parse a `.twb` XML file into a per-dashboard zone list plus a sister `*-meta.json` (worksheets + shared_filters + parameters + column_aliases). Per chart zone surfaces: position (`x/y/w/h%`), `chart_kind`, `mark_class`, `geo_role`, `sort`, `filters` (with resolved column captions + member values + action-vs-value flag), `aggregations`, `channels`, `formats` (Tableau format strings → Sigma d3-format with paren-negative handling), `calculations`, `dual_axis` (synchronized-axes detection), `ref_marks` (reference lines/bands/trendlines), `filter_column_caption`. Detects Tableau **stories** (both `<story>` and storyboard-dashboard shapes): flags storyboard dashboards `is_story: true` and writes `story-plan.json` (story → ordered points with captions + captured sheets) — when present, run `build-story-pages.rb`. Bin calc columns surface `bin_size`/`bin_peg`. |
| `scripts/build-charts-from-signals.rb` | Generate Sigma chart-element specs from parse-twb-layout output + view CSVs + master-column map. Auto-translates: column aliases → `Switch(…)` calc, parameter-driven CASE/IF chains → `Switch([ctl-param-x], …)` with controlId rewrite per page, table calcs (INDEX/LOOKUP/TOTAL/RANK/ZN/IIF/COUNTD) → Sigma equivalents, `DATEPART('iso-year')` → Thursday-of-ISO-week `Year(DateAdd(...))` composition, `FINDNTH` → `SplitToArray`/`ArraySlice`/`ArrayJoin` composition, Tableau bins → native `BinFixed`/`BinRange` recipe, **nested `{FIXED}` LODs → helper-element chain** (innermost LOD = helper element 1, outer consumes `[LOD Helper k/Value]`; machine-readable sidecar `<out>-lod-chains.json`), Tableau formats (p%.%/C1033%/`(neg)`) → Sigma d3-format. Honors `--page-per-worksheet`, `--auto-controls`. Loads customer learned-rules first. Writes `*-actions.md` companion listing Tableau action filters for post-publish cross-filter setup. |
| `scripts/extract-custom-sql.rb` | Phase 1f: pull Custom SQL blocks behind a workbook via Metadata GraphQL + .twb XML fallback. Output → `/tmp/<name>/custom-sql.json`. |
| `scripts/lib/tableau_rest.rb` | Ruby wrapper for the Tableau REST endpoints the skill uses |
| `scripts/estimate-cost.rb` | Predict input/output token cost from workbook + datasource metadata |
| `scripts/fetch-view-data.rb` | Parse pre-fetched view CSVs into a signals manifest (distinct values, date min/max, agg hints) |
| `scripts/discover-warehouse-columns.rb` | Parallel-fetch Sigma column metadata for N table inodeIds |
| `scripts/probe-custom-sql-columns.rb` | **Phase 1e.1:** when discover-columns 404s (catalog miss), probe column names + types via a one-shot Custom-SQL probe workbook that SELECTs INFORMATION_SCHEMA, exports CSV, and self-destructs. ~6s end-to-end. Saves ~120s on every Custom-SQL fallback vs. POST-fail-cleanup column-name guessing. |
| `scripts/find-prior-cache.rb` | **Phase 1d-cache (Phase -1):** detect cached Tableau-discovery + Sigma-conversion artifacts from prior `audit-run-*` or `converter-test` runs so re-conversions skip discovery (~3 min saved). |
| `scripts/remap-wb-spec-to-dm-ids.rb` | When a DM is re-POSTed and element IDs churn, remaps a cached `wb-spec.json` to the new IDs via name-based matching. Optional `--rename` for renamed elements. |
| `scripts/extract-calc-fields.rb` | Phase 1e: pull every Tableau calc field (with formula) via Metadata API (`POST /api/metadata/graphql`); falls back to `.twb` XML when Metadata API is unavailable. Drops VDS dependency. Caches to `<wb-dir>/calc-fields.json`. |
| `scripts/validate-spec.rb` | DM or workbook spec validator. Accepts `--type` and `--dm-context` |
| `scripts/post-and-readback.rb` | POST a DM or workbook spec, parse YAML response, GET back the spec, emit element ID map. Also runs a universal **column-type guard** afterward: any column whose formula resolved to type `error` aborts the script with exit 2 and the failing formula. Catches silent-error columns the validator doesn't pattern-match (typo refs, `IsIn`, unsupported functions) without waiting for Phase 6. Then the shared **layout lint** (exit 3) and **control lint** (`scripts/lib/control_lint.rb`, exit 4 — dead controls / ghost targets / partial same-page reach; honors the `<workdir>/control-scope.json` sidecar, `--skip-control-lint` escape). |
| `scripts/lib/preflight_lint.rb` | **MANDATORY before any workbook POST** — static lint of the spec that catches the two EDNA-class failure modes with a precise message instead of the opaque `Invalid kind: control` / a silently-detail-rendered table: (T1) a `table` with aggregate columns + dimensions but **no `groupings`** → renders raw 9.6M detail rows; (T2) a grouping calculation that passes through an already-aggregated column → "multiple values"; (C1/C2) a `control` missing `id`/`controlId`/`controlType` or the flat list value fields (`source` double-nest, `mode`, `selectionMode`, `values`). `ruby scripts/lib/preflight_lint.rb <spec.json>` (exit 1 on violations). Fix all violations before POST. Verified shapes: `sigma-workbooks` `controls.md`/`tables.md`. |
| `scripts/put-layout.rb` | Apply a layout XML to an existing workbook (strips read-only fields) |
| `scripts/auto-parity-plan.rb` | Phase 6a: auto-build a parity plan by matching Sigma chart elements to Tableau view CSVs (with `--rename` for renamed tiles). Output → `/tmp/<name>/parity-plan.json` wrapped as `{ extract, charts: [...] }` |
| `scripts/verify-parity.rb` | Phase 6c: diff expected (Tableau) vs actual (Sigma) per chart. `--extract-mode` switches to structural comparison (bucket count + dim set + sort) with value-drift tolerance for hasExtracts=true workbooks |
| `scripts/assert-phase6-ran.rb` | **Conversion hard gate (7 gates)** — exits 0 only when ALL seven pass: (1) Phase 6 ran and parity-final.json shows status=PASS at the required rate, (2) no uncleaned orphan workbooks (posted-workbooks.jsonl has ≤1 entry OR cleanup-marker.json shows a successful non-dry-run cleanup), (3) the live workbook's `/columns` endpoint shows no column with `type=error` (catches circular refs / runtime errors introduced after the initial POST's column-type guard), (4) a non-empty top-level layout XML is applied (beads-sigma-bw3), (5) tile census — parity-final.json's `tile_census` shows no unexplained dashboard zones without a matching chart (catches the empty-view-CSV N-1-charts escape, bead gjhe; `--allow-missing-tiles N` for legitimately unbuildable zones). Exits 1 for missing parity sentinel, 2 for parity FAIL / extract-mode-without-flag / charts_total==0, 4 for uncleaned orphans, 5 for live type=error columns, 6 for missing layout, 7 for census failure, 8 for layout-lint violations (gate 6, `lib/layout_lint.rb`, `--skip-layout-lint`), 9 for control-lint violations (gate 7, `lib/control_lint.rb` — dead controls / ghost targets / partial reach / control-scope coverage; `--skip-control-lint`, `--control-scope PATH`). Subagent flows MUST call this as their final step. |
| `scripts/probe-controls.rb` | **Phase 6 (optional) — control flip test**: per control, export one in-closure element CSV with and without `parameters:{controlId: <first non-default value>}` (must differ) and, with `--check-out-of-closure`, one out-of-closure element (must NOT differ). Runtime proof the wiring works; the static check is gate 7. Shared, vendored byte-identical (md5 discipline). See `refs/control-parity.md`. |
| `scripts/cleanup-orphan-workbooks.rb` | Delete orphan workbooks left by spec-iteration retries. Reads `<workdir>/posted-workbooks.jsonl`, keeps the most-recent ID, deletes the rest via `DELETE /v2/files/{id}`. Writes `cleanup-marker.json` so the hard gate can confirm cleanup ran (and wasn't `--dry-run`). Idempotent (404 on delete is treated as success). See beads-sigma-38a. |
| `scripts/build-dashboard-layout.rb` | **MANDATORY in Phase 5d** (dashboard-fidelity mode) — auto-build the Sigma layout XML from the parsed Tableau zone tree (`dashboard-layout.json`) + the workbook readback IDs (`wb-ids.json`). Positions each chart at the grid cell derived from its zone's x/y/w/h%. Without this step, the workbook PUTs without a top-level layout and Sigma renders elements as a single-column stack — see `assert-phase6-ran.rb` gate 4 (beads-sigma-bw3). |
| `scripts/build-story-pages.rb` | **Story workbooks only** — when `parse-twb-layout.rb` wrote `story-plan.json`, emit one Sigma page per story point: pass 1 (`--spec`/`--out`) appends caption-named pages (annotation text atop + cloned elements with fresh ids/controlIds) to the workbook spec pre-POST; pass 2 (`--wb-ids`/`--layout-out`) emits the banded per-page layout + container sidecar post-readback. See `refs/story-points.md`. |
| `scripts/export-chart-png.rb` | Phase 6d (visual) **drill-down only** — per-element PNGs for diagnosing a chart-level regression (dropped log scale, missing data labels, wrong kind, palette drift). **NOT the primary visual gate:** the mandatory check is **full-dashboard ↔ full-dashboard** — render the whole Sigma page with `sigma-export-png.py --page <pageId>` and compare it to the FULL source dashboard image (Tableau MCP `get-view-image` on the *dashboard view*, not each worksheet). Per-element screenshots miss layout/relationship defects (overlaps, dead zones, stranded controls, wrong relative sizing). See `refs/layout-visual-qa.md`; loop-fix-and-re-render until the full page matches the source — never declare done on HTTP 200. |
| `scripts/pick-destination.rb` | **Phase 0b:** list build destinations (`list` → workspaces + editable folders + My Documents) and create folders (`create --name [--parent]`). Drives the "where should this land?" prompt when no `--folder`/`SIGMA_FOLDER_ID` is given. `folderId` accepts a workspace id (workspace root) or a folder id. Shared across the migration skills. |
| `scripts/find-or-pick-dm.rb` | Phase 1.5: scan existing DMs in the org and recommend reuse when one already covers the workbook's columns. Score = 0.7·column-overlap + 0.2·table-overlap + 0.1·metric-overlap. Parallel-fetches DM specs (~2s for 50 DMs). Output: `dm-match.json` with ranked candidates + recommendation. Non-destructive. Reuse skips Phase 2 + 3 entirely. `--auto-pick` flag (with tie-window safety) skips the user-confirm step when there's a clear winner. |
| `scripts/inspect-dm-shape.rb` | Phase 1.5b (MANDATORY when reusing): inspect the reused DM's element graph and emit a denormalization plan classifying every column as `fact` (direct ref) or `dim` (needs Lookup). Output: `dm-denorm-plan.json` with the exact Lookup formula per dim column. Eliminates the 2–3 min spec-rework loop when the reused DM has separate dim elements (a non-pre-denormalized DM shape). |
| `scripts/scan-customer-style.rb` | Phase 0c: sample N recent workbooks in the customer's Sigma org and aggregate style signals (color palettes, number-format strings, layout grids, chart-kind mix, dataLabel preference, element naming case, density). Lets the converter emit specs that match house conventions instead of generic defaults. |
| `scripts/dev/phase-timer.sh` | **Dev / profiling only — do NOT source in customer conversions.** Source helper for phase timing when iterating on the skill itself; emits `▶`/`■` log lines per phase and a `phase-timings.json` summary. Only invoke when the user explicitly asks for timing data ("time it", "where did the minutes go", "profile"). Usage: `phase_start "<name>"` / `phase_end` around each phase, `phase_report` at the end. **Across multiple Bash tool-call blocks**, export `PHASE_TIMINGS_TMP=<path>` BEFORE the first source so the helper appends across blocks. |
| `scripts/lib/layout.rb` | Layout-XML helpers (`gc`, `le`, `page_xml`, `assemble`) — `require`'d by per-workbook layout configs |
| `scripts/enhance-scan.rb` | **Phase E (opt-in) part 1 — SCAN (read-only).** Source signals + built spec + live element exports → `enhancements.json` candidates `{id, category, evidence, proposed, risk, verdict_hint, patch}` + descoped propose-in-UI notes. Shared Phase-E engine, vendored byte-identical across plugins (md5 discipline). |
| `scripts/enhance-apply.rb` | **Phase E (opt-in) part 2 — APPLY (accept-only, clone-first).** Clones the parity workbook as `"<name> — Enhanced"` (1:1 artifact never written), applies ONLY `--accept`-ed candidates one at a time, each gated by an untouched-element clone-vs-original spot-check (auto-revert on shift). Writes `enhance-report.json`. Shared engine, byte-identical twin of the tableau/powerbi copy. |

---

## Prerequisites

### Sigma credentials

Run the setup script once:

```bash
ruby scripts/setup.rb
```

It writes credentials to two places: `~/.claude/settings.json` (which Claude
Code auto-loads) and `~/.sigma-migration/env` (a neutral, sourceable file any
other agent or plain shell can use). The scripts fall back to the neutral file
automatically when the env vars aren't already set, so the skill works under
any agent.
<!-- agents:claude-only -->
On Claude Code, open a new session (or run `! source ~/.claude/settings.json`)
so the env vars are live — no manual sourcing needed thereafter.
<!-- /agents:claude-only -->
<!-- agents:non-claude
On other agents (Cursor, Cortex Code, plain shell), the scripts auto-source
`~/.sigma-migration/env` for you. To have the vars live in your own shell too,
run `source ~/.sigma-migration/env` once per session.
agents:end -->

Required env vars:
- `SIGMA_BASE_URL` — e.g. `https://aws-api.sigmacomputing.com`
- `SIGMA_CLIENT_ID`
- `SIGMA_CLIENT_SECRET`

Fetch a token at the start of each phase that needs one:

```bash
eval "$(scripts/get-token.sh)"
```

> Tokens live ~1 hour. Re-run when a curl returns 401. Never use
> `TOKEN=$(eval "$(scripts/get-token.sh)")` — `$()` creates a subshell where
> the exported var dies immediately. Keep eval + curl in the same `bash -c '...'`
> invocation.

> **Inline Python inside bash — DON'T.** Triple-nested escapes (`f"...{e.get(\\\"name\\\")}..."` inside `python3 -c "..."` inside `bash -c '...'`) silently break. Instead **always write a `.py` file with `Write` and call it via `python3 file.py`.** Same rule for any inline script over ~5 lines: write it to disk, then exec. It's not slower, it's deterministic, and the file becomes a reusable artifact. (Same applies to Ruby — prefer `ruby file.rb` over `ruby -e '...'`.)

### Tableau access — two modes

The skill supports two transports for Tableau-side discovery. **Prefer the
API/PAT path** — it is dramatically faster (measured on "Orders Conversion
Test", 7 views: **61.8s serial → 13.7–18.9s** with the unified fetch pool, zero
rate-limiting at pool 5). The MCP is the **no-PAT fallback only** (each MCP
fetch is a separate agent tool turn; the PAT CLI does everything in one
process).

| Mode | When to use | Setup |
|---|---|---|
| **PAT (REST)** — preferred | A Tableau PAT is available (run `setup-tableau.rb` once). Also the only path to `.twb` content (layout-hint extraction, embedded datasources) | `ruby scripts/setup-tableau.rb` once, then `eval "$(scripts/get-tableau-token.sh)"` per session |
| **MCP** — fallback | No PAT can be provisioned, and `mcp__tableau__*` tools are loaded in the session | None — host handles auth |

**PAT mode in one command:**

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/tableau-discover.rb \
  --workbook-id <luid> \
  --out /tmp/<name>   # [--pool N] (default 5)
```

Produces the same artifacts as MCP-driven Phase 1 in a single run: `get-workbook.json`,
`workbook-content.twb`, `ds-metadata.json` + `graphql-fields.json` (VDS field list + GraphQL
formulas), `views/*.csv`, the dashboard PNG, **and `timings.json`** (per-task
start/duration/attempts — always written; it's the evidence trail for any future
"discovery is slow" report). Downstream scripts in Phases 2–6 are unchanged.
Full endpoint inventory and gotchas in `refs/tableau-rest.md`.

`--datasource-name` / `--datasource-luid` are **optional** — the script parses the
downloaded `.twb` for the first non-Parameters `<datasource caption='X'>` and looks it up
on the site automatically. Pass `--no-auto-ds` to disable, or `--datasource-luid` to force
a specific datasource when the workbook has multiple (`--datasource-luid` must be the
**full UUID** — the REST filter has no prefix matching).

**How the pool works (and why 5):** every fetch after the initial workbook GET
(.twb, VDS read-metadata, GraphQL fields, all view CSVs, dashboard PNG) goes
through ONE shared pool of 5 threads, enqueued longest-job-first — the PNG
render is the longest single fetch, so it starts at t≈0 and hides behind the
CSV batch. **5 is the measured sweet spot; 8 risks long-tail stragglers** — at
8 threads a contended VizQL session parked one CSV fetch for ~40s (56s total
run vs. 13.7–18.9s at 5). The pool keeps 429/timeout exponential backoff and
single-flight 401 re-mint machinery as insurance even though neither fired at
pool 5 in validation. Also note Tableau's **~60s server-side render cache**:
a view rendered within the last minute returns much faster, so back-to-back
runs land at the fast end of the range and cold-cache runs at the slow end —
don't read a 5s spread between runs as a regression.

> **One signin attempt only.** Tableau Cloud invalidates a PAT after 4 consecutive failed
> signins. `get-tableau-token.sh` runs exactly once; never wrap it in a retry loop.

---

## Phase 0a — Scan the workbook for feature gaps (MANDATORY)

Run the gap scanner against the customer's `.twb` *before* anything else. It
inventories every workbook feature the skill currently handles vs. doesn't, so
the agent can plan around real translation gaps instead of discovering them
mid-conversion.

```bash
ruby scripts/scan-workbook-gaps.rb /tmp/<name>/workbook-content.twb
# writes <name>-workbook-content-gaps-report.md + <name>-workbook-content-gaps.json
```

Categories emitted:
- **✅ Auto** — translated end-to-end without intervention
- **⚠️ Hint** — agent gets a copy-paste-ready Sigma formula in WARN lines
- **🛠 Manual** — customer wires up post-publish (action filters, ref-marks)
- **❌ Unhandled** — feature is used in the .twb but the skill does not yet
  cover it; the agent should escalate via the `gap-scout` subagent OR file
  an issue at github.com/twells89/sigma-skills-staging

Share the markdown report with the customer up front to set expectations.
Save the JSON for the subagent.

## Phase 0b — Choose where to build (MANDATORY when no destination given)

Never silently dump the migrated data model + workbook into an auto-picked
folder. If the user did **not** supply a destination (no `--folder <id>` on
`migrate-tableau.rb` and no `SIGMA_FOLDER_ID`), ASK first:

1. List candidates:
   ```bash
   ruby scripts/pick-destination.rb list
   # -> { "workspaces":[{id,name}], "folders":[{id,name,parentId,parentName}], "myDocuments": <id|null> }
   ```
2. Present the options to the user and let them pick ONE:
   - a **workspace** (content lands in the workspace root — pass its `id` as the folder)
   - an existing **folder** (use its `id`; `parentName` shows its workspace)
   - **My Documents** (only when `myDocuments` is non-null — null for service-account tokens)
   - **create a new folder** (optionally inside a chosen workspace/folder):
     ```bash
     ruby scripts/pick-destination.rb create --name "<name>" [--parent <workspace-or-folder-id>]
     # -> { "id", "name", "parentId" }
     ```
3. Pass the chosen id to the migration as `--folder <id>` — it flows into both
   the DM and workbook POSTs.

`folderId` accepts a workspace id (lands in the root) **or** a folder id. If the
user already passed `--folder` / `SIGMA_FOLDER_ID`, honor it silently — do NOT ask.

> **Data blending:** when the scanner writes `blend-plan.json`, route each
> blend BEFORE Phase 2 using its `route` field — (a) `same-warehouse-repoint`
> → one DM, both sources as elements + relationship on the linking fields
> (deep-walk `connectionId` incl. `joins[].left/right` when repointing);
> (b) `materialize-via-vds` → run the **tableau-vds-to-cdw** skill to land the
> secondary in the primary's warehouse first; (c) `flag-unreachable` → keep
> manual, report the linking fields. Full decision tree: `refs/blending.md`.

> **Story points:** when `parse-twb-layout.rb` writes `story-plan.json`
> (Phase 1d), plan one Sigma page per story point and run
> `scripts/build-story-pages.rb` in Phase 5 (spec pass) and Phase 5d (layout
> pass). Storyboard dashboards are flagged `is_story: true` in
> `dashboard-layout.json` — do NOT build a regular page from the flipboard
> chrome. See `refs/story-points.md`.

### Phase 0a-scout — spawn the gap-scout subagent for unhandled features

> **MANDATORY, parallelizable.** As soon as the gap scanner produces `gaps.json`,
> read the `detected_features` array and **spawn one `gap-scout` Agent per row
> whose `status` is `unhandled`** (and optionally for high-volume `hint` rows).
> Use `run_in_background: true` so the scout runs in parallel with the rest of
> conversion — by the time you reach Phase 5, the scout has either persisted a
> rule or escalated. Don't read the gap report and proceed without doing this.

For every `❌ Unhandled` row in the gap report (and for high-volume `⚠️ Hint`
rows worth automating), spawn a `gap-scout` subagent via the Agent tool. Each
scout takes ONE gap, proposes a Sigma translation, validates against the
customer's Sigma site via `scripts/validate-sigma-formula.rb`, and:
- on success → writes the rule to `~/.tableau-to-sigma/learned-rules.yaml`
  (the customer's home dir — `git pull` of the skill cannot clobber it).
  All future workbook conversions on this machine pick up the rule via
  `scripts/learned-rules.rb` automatically.
- on failure → writes to `~/.tableau-to-sigma/escalations/` and returns an
  **opt-in** `escalate-gap.py` command. Filing a tracking issue is never
  automatic: run the returned `escalation.dry_run_cmd` to draft the issue
  (shows target repo + dedupe), show the user, and only re-run with `--yes`
  if they accept. Calc-field gaps route to the converter repos
  (`sigma-data-model-manager` + `sigma-data-model-mcp`, mirrored) with a
  cross-linked bead. See "Opt-in issue filing" in `scripts/gap-scout.md`.

The build script (`build-charts-from-signals.rb`) loads learned rules at
startup; matching rules apply *before* the built-in translators, so customer-
discovered translations override defaults. See `scripts/gap-scout.md` for the
full subagent prompt + procedure.

Customer-local files always live under `~/.tableau-to-sigma/`:
- `learned-rules.yaml`   — accumulated translation rules
- `escalations/*.yaml`   — gaps the scout couldn't solve
- (override path for testing with `TABLEAU_TO_SIGMA_HOME` env var)

### Phase 0b — Pick the conversion mode (MANDATORY, ask the customer)

Before building anything, **ask the customer which mode they want**. There is
no good default — picking the wrong one wastes the whole conversion.

| Mode | When | Output |
|---|---|---|
| **Dashboard fidelity** (default for dashboard URLs like `/views/<WB>/<Dashboard>`) | Customer wants the source dashboard recreated 1:1 in Sigma | One Sigma page with all charts positioned in the same grid as Tableau; shared filters as page-level controls; layout XML mirrors the dashboard's zone tree |
| **Page-per-worksheet** (default for `/sheets/<Sheet>` URLs OR when the customer says "split it up") | Customer wants each worksheet adjustable independently, OR the dashboard is too dense to recreate cleanly | One Sigma page per Tableau worksheet; shared filters duplicated on each page |

When the customer's URL is a dashboard URL and they haven't explicitly said
"split into pages," the agent MUST ask: "Want me to recreate the dashboard
1:1 (all 6 tiles on one page) or break each worksheet into its own Sigma
page?" Don't assume.

For dashboard mode, `build-charts-from-signals.rb` is invoked WITHOUT
`--page-per-worksheet` — that emits the legacy flat-array output. Then a
separate layout script positions the chart elements in a grid matching the
Tableau dashboard's zone x/y/w/h percentages (parse-twb-layout already
extracts these).

For page-per-worksheet mode, pass `--page-per-worksheet`.

---

## Phase 0 — Estimate cost up front

Before committing to the conversion, predict the agent token cost. Useful for
quoting and for bucketing workbooks (small/medium/large/very-large) in a
multi-workbook migration.

```bash
# Pre-fetch workbook + datasource metadata
mcp__tableau__get-workbook  workbookId="<luid>"            > /tmp/<name>/get-workbook.json
mcp__tableau__get-datasource-metadata  datasourceLuid="..." > /tmp/<name>/ds-metadata.json

ruby scripts/estimate-cost.rb \
  --workbook /tmp/<name>/get-workbook.json \
  --datasource /tmp/<name>/ds-metadata.json
```

The estimator emits a JSON record with `features` (dashboards, sheets, calc
fields, custom SQL bytes) and `estimate` (complexity bucket, input/output
token counts, USD cost). Coefficients are heuristic and should be calibrated
against ~10 measured conversions before use in customer quotes.

---

## Phase 1 — Discover the Tableau datasource structure

### 1a. Resolve the name the customer gave you

The customer's name may be a **datasource**, a **workbook**, or a **dashboard view inside a workbook**. Tableau Cloud's search and list endpoints partition by content type, so you have to try each before declaring no match.

```
# Workbook by name
mcp__tableau__search-content   terms="<name>"   filter.contentTypes=["workbook"]

# Dashboard view by name — falls back to workbook owner via the view's response
mcp__tableau__list-views       filter="name:eq:<name>"

# Datasource by name
mcp__tableau__search-content   terms="<name>"   filter.contentTypes=["datasource"]
mcp__tableau__list-datasources
```

If the workbook search returns nothing, **try `list-views` next** — the customer almost certainly named a dashboard sheet (e.g. "Orders Overview") that lives inside a differently-named workbook ("Orders Conversion Test"). The view response includes the parent workbook's LUID.

### 1b. Find workbooks sourced from a datasource

```
mcp__tableau__search-content   terms="<datasource name>"   filter.contentTypes=["workbook"]
```

> **Check `hasExtracts` on the search result.** When `hasExtracts: true` on a workbook
> (and especially on its datasource), the Tableau view CSVs reflect a **frozen snapshot**
> of the warehouse — not its current state. Sigma always reads the live warehouse, so the
> absolute counts in Tableau views will diverge from Sigma values, even when the chart
> *structure* (dimensions, aggregations, breakdowns) is identical.

### 1c. Get workbook views

```
mcp__tableau__get-workbook   workbookId="<luid>"
```

Returns the list of views (sheets) with their `id` and `name`. Record all view IDs.

### 1d-cache. Reuse prior conversion artifacts when present (PHASE -1)

Before re-running tableau-discover / fetch-view-data / parse-twb-layout, check
for cached artifacts from a previous run. The standalone Workforce conversion
on 2026-05-22 found cached audit-run-1 artifacts in
`/tmp/audit-run-1/workforce/` (views CSVs, view PNGs, signature, dm-spec,
wb-spec, dashboard layout meta) — re-running discovery cost ~3 minutes that
could have been zero.

```bash
ruby scripts/find-prior-cache.rb --name <workbook-slug> --out /tmp/<name>/prior-cache.json
```

The script searches `/tmp/audit-run-*/<name>/`, `/tmp/converter-test/<name>/`,
and `/tmp/<name>/` for: views CSVs, views PNGs, `workbook-content.twb`,
gaps-report, dashboard-layout JSON, get-workbook.json, dm-spec.json /
wb-spec.json (and their ID maps), and the workbook signature. Output is a
JSON map of artifact name → absolute path (or null).

**Use the cached artifacts as-is** when they exist and the workbook hasn't
changed — copy them into your working directory (or symlink) and skip the
corresponding fetch step. The DM/wb specs become your reference for ID
mapping after a re-POST (see `scripts/remap-wb-spec-to-dm-ids.rb`).

### 1d. Retrieve view data and images

Two different fetches with very different cost profiles. **Don't conflate them.**

- **`get-view-data` (CSVs)** — cheap, no VizQL session contention. **Fire all view CSVs in parallel** in a single batch.
- **`get-view-image` (PNGs)** — expensive, hits VizQL session contention. Most 401s come from firing multiple image requests simultaneously (or alongside other view calls).

**What to actually fetch:**

| Need | Source | How |
|---|---|---|
| Dashboard layout (grid, chart positions, title, filter shelf) | The dashboard view's PNG | 1 `get-view-image` call |
| Each chart's dimensions, measures, aggregation | Each sheet's CSV | All sheets in parallel via `get-view-data` |
| Distinct values + date min/max for Phase 2.5 filter detection | Each sheet's CSV | Same parallel batch |
| What an individual sheet looks like in isolation | Sheet PNG | **Skip by default** — fetch one only if you need to disambiguate a tile whose dashboard title is misleading or truncated |

Save each fetched CSV to `/tmp/<name>/views/<viewId>.csv` and parse them with:

```bash
ruby scripts/fetch-view-data.rb /tmp/<name>/views /tmp/<name>/signals.json
```

The output (`signals.json`) contains, per view, a `columns` map with `kind`
(dimension / numeric / date), `distinct_count`, sampled `distinct` values,
numeric ranges, and `aggregation_hints` parsed from CSV headers like
"Sum of Gross Revenue" or "Distinct count of Order Id".

**The reliable fetch pattern:**

1. Fire `get-view-data` calls in parallel batches, but **cap each batch at ~4 concurrent calls**. CSVs survive concurrency far better than image fetches, but 7-way batches have produced 6×401 from VizQL contention in the wild (verified 2026-05-22). For >4 views, split into back-to-back batches of 4 (e.g., 7 views → batch of 4, then batch of 3 in the next message).

   > **This is the single biggest perf win in the whole conversion.** Measured 2026-05-22: 7 view-CSVs sequentially = ~200s (~28s per call, range 19–40s). Same 7 calls fired in two batches of 4+3 = ~60-70s (vs. ~45s for an unrestricted batch when no contention hits — but unrestricted goes catastrophically slow once it does, because every 401 retry happens solo). Skipping parallelization entirely is responsible for ~2.5 min of the historical ~9-min conversion runtime. Send each batch as a single message with N `mcp__tableau__get-view-data` tool-call blocks side-by-side; do NOT send them in separate messages.
2. Fetch **only the dashboard view's PNG** with `get-view-image`. Solo — no other view calls in flight.
3. If a specific tile's dashboard title looks wrong or truncated, fetch that one sheet's PNG solo to disambiguate.

If `get-view-data` returns 401 for a view, retry that view solo (the contention almost always clears within a second or two); if it 401s on the solo retry, skip it.

> **Do not parallel-fire `get-view-image` calls.** Even if the CSVs succeeded in parallel, concurrent image requests still 401 due to VizQL session contention. Images are always solo.

> **Reading the dashboard image is MANDATORY before writing the workbook spec in Phase 5.** The CSV headers tell you a chart's dimensions and measures; they do NOT tell you (a) the chart's *kind* (a `Category, Count` CSV could back a bar OR a pie OR a donut), (b) any text annotations (titles, section headers, footnotes), or (c) the filter shelf. Skipping the image read is the most common Phase 5 mistake — you ship a workbook that has the right numbers but is missing tiles the source dashboard actually rendered.

**Phase 1d checklist — confirm before moving on:**

- [ ] Opened the dashboard PNG and listed every tile, including non-chart tiles (text, filter shelves, legends, image placeholders)
- [ ] Decided the chart kind of each tile from the image, not just the CSV header (bar / line / pie / donut / kpi / map / **pivot-table** / table)
- [ ] **For any text-mark / crosstab-looking tile, confirmed pivot vs flat:** Tableau dims on BOTH the Rows AND Cols shelves ⇒ Sigma `pivot-table` (with `rowsBy` / `columnsBy` / `values`). Dims on Rows only ⇒ Sigma `table`. `parse-twb-layout.rb` sets `is_crosstab: true` and `chart_kind: pivot-table` automatically when shelves carry dims on both sides — trust that signal over the visual `Square`/`Text` mark which is the same for both.
- [ ] Noted every text element on the dashboard surface (page title, section headers, free-text annotations)
- [ ] Noted every dashboard-level filter or parameter control (date range, list, segmented buttons)

Use the dashboard image to understand:
- How many KPIs are in the header row and what they measure
- Which chart types are used (bar, line, scatter, map, small multiples, **pie / donut**)
- The rough grid layout of each page (columns × rows) — count the rows; this is what your layout XML needs to match
- **Page titles, section headers, and any free-text annotations on the dashboard surface** — these are real content (not metadata) and need to be recreated as `text` elements in the Sigma spec. The page tab name (`page['name']`) is *not* a substitute; it only appears in the tab bar, not on the canvas. If the Tableau dashboard shows a heading like "Orders Dashboard" at the top of the page, add a `text` element with `body: "## Orders Dashboard"` and reserve a row for it in the layout.
- **The filter shelf.** Tableau dashboards usually have visible filter controls (a date range slider, a region list, a state list). These appear as `control` elements in the Sigma workbook — never just as Phase 2.5 element-level filters, because that strips the user-facing control surface.

**Alternative / supplement: parse the `.twb` zone tree.** If you have `workbook-content.twb` from PAT-mode Phase 1, run:

```bash
ruby scripts/parse-twb-layout.rb /tmp/<name>/workbook-content.twb /tmp/<name>/dashboard-layout.json
```

It emits a per-dashboard zone list with `caption`, `view_ref`, `x/y/w/h` in percent, **and `chart_kind` extracted from each worksheet's `<mark>` element + Rows/Cols shelves** (`bar` / `line` / `pie` / `scatter` / `map-region` / `map-point` / `pivot-table` / `table` / `automatic` / `other`). For text-mark worksheets, the parser disambiguates `pivot-table` (dims on both shelves — Tableau crosstab) from flat `table` (dims on one shelf — detail list) via the `rows_shelf` / `cols_shelf` summary; `build-charts-from-signals.rb` honors this and emits `rowsBy` / `columnsBy` / `values` for crosstabs. This is more reliable than inferring chart type from the view CSV — the CSV headers can't distinguish bar-vs-pie or pivot-vs-flat-table. Map every zone in the output to a Sigma element using the tables in `refs/workbook-layout.md` (`Reading the .twb dashboard layout` section).

> **Maps:** if `parse-twb-layout.rb` emits `chart_kind: map-region` or `chart_kind: map-point` for any zone, do NOT build a bar chart. Use Sigma's `region-map` / `point-map` element kinds. The Tableau geographic role (`semantic-role` on the column) translates to Sigma's `regionType` via the table in `refs/workbook-layout.md`. Sigma's region types are US-only except for `country` — non-US state/county/ZIP data falls back to a sorted bar chart or, if lat/long is available, a `point-map`.

> **`chart_kind: automatic`:** Tableau's "Automatic" mark picks a default for the encodings. It usually renders as a bar but is not deterministic. When you see `automatic`, fetch the dashboard PNG and look at that specific tile to decide the Sigma kind.

Sigma spec supports: `bar-chart`, `line-chart`, `area-chart`, `combo-chart`, `scatter-chart`, `kpi-chart`, `pie-chart`, `donut-chart`, `region-map`, `point-map`, `table`, `pivot-table`, `control`, `text`, `image`, `container`.

> **Common kind mistakes — all three are rejected by the API:**
> - `"kpi"` → must be `"kpi-chart"`
> - `"pie"` → must be `"pie-chart"`
> - `"donut"` → must be `"donut-chart"`
>
> The official Sigma example library shows `kpi`, `pie`, and `donut` — all three are wrong. The validator (`scripts/validate-spec.rb`) flags them, but do not rely on it: write the correct kind from the start.

Does **not** support via the spec API: bullet chart, gantt.

**Maps are fully spec-supported.** Use `region-map` for choropleths (US state / county / ZIP / CBSA / country fills) and `point-map` for lat/long bubble or symbol maps. See `refs/workbook-layout.md` "Map elements" for the field shape, the exact set of valid `regionType` values, and the color-channel rules.

**Trellis (small multiples) is supported in Sigma but configured UI-only.** Build the chart with the right dimensions via spec, then trellis it manually post-publish.

> **Log-scale axes round-trip through the spec.** `parse-twb-layout.rb` extracts
> `axis_formats[].scale: "log"` from each worksheet's `<axes>` block, and
> `build-charts-from-signals.rb` emits it as
> `element.yAxis.format.scale = { type: "log", domain: {min, max} }` whenever
> `range_type == "fixed"`. **If you hand-write the workbook spec instead of
> running build-charts-from-signals.rb, you MUST copy this manually** —
> otherwise the chart silently degrades to linear scale (OCT lost the Monthly
> Trend log axis this way on 2026-05-24). Always grep
> `dashboard-layout-meta.json` for `"scale": "log"` before declaring Phase 5
> done.

Control types supported: `list`, `date-range`, `text`, `text-area`, `segmented`, `number`, `number-range`, `slider`, `range-slider`, `top-n`.
See `refs/workbook-layout.md` for full control element spec patterns.

### 1e. Discover calculated fields (Metadata API + .twb fallback)

Calculated field formulas are required to translate calc cols into Sigma DM
formula columns. The converter pulls them via the **Tableau Metadata API
(GraphQL)** as the primary path. Metadata API is independent of VDS — it
works even when VDS is disabled on the customer's site. **VDS is NOT used for
calc discovery anymore.**

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/extract-calc-fields.rb \
  --workbook-luid <luid> \
  --out /tmp/<name>/calc-fields.json \
  [--twb /tmp/<name>/workbook-content.twb]   # used if metadata-api fails
```

The script caches its result to `--out` and reuses it (< 1h old) on subsequent
runs unless you pass `--refresh`. Downstream phases read from the cache.

**Fallback order (`--source auto` is the default):**
1. **Metadata API** (`POST /api/metadata/graphql`) — returns formula +
   dependency graph + role + datatype + aggregation + isHidden.
2. **`.twb` XML parse** — returns formula only (no resolved field-name
   dependency graph; `depends_on` is `[]` on this path). LOD formulas are
   still captured because they live in the `<calculation formula='...'/>`
   attribute verbatim.

Both produce the same JSON shape so downstream phases don't care which path
fired. Force a specific source with `--source metadata` or `--source twb`.

Output schema (`calc-fields.json`):

```json
{
  "workbook_luid": "...",
  "workbook_name": "...",
  "source": "metadata-api" | "twb-xml-fallback",
  "generated_at": "2026-05-26T...",
  "n_calcs": 1391,
  "n_lods": 162,
  "n_requires_custom_sql": 174,
  "calcs": [
    {
      "name": "Profit Ratio",
      "datasource": "Orders+",
      "formula": "SUM([Profit]) / SUM([Sales])",
      "role": "MEASURE",
      "data_type": "REAL",
      "aggregation": null,
      "is_hidden": false,
      "is_lod": false,
      "depends_on": ["Profit", "Sales"],
      "requires_custom_sql": false,
      "translation_notes": []
    }
  ]
}
```

Each calc record carries:
- `name`, `formula`, `role`, `data_type`, `aggregation`, `is_hidden` — direct from Tableau
- `is_lod` — `true` for `{FIXED/INCLUDE/EXCLUDE}` expressions
- `depends_on` — referenced field names (metadata-api path only)
- `requires_custom_sql` — `true` ONLY for the **manual window residues**
  (`WINDOW_MEDIAN/PERCENTILE/CORR/COVAR(P)/VAR(P)/STDEVP`, `PREVIOUS_VALUE`,
  `SIZE`, `FIRST`, `LAST`, `RANK_UNIQUE/MODIFIED`) and `{INCLUDE/EXCLUDE}`
  LODs. The mainstream window/table-calc family (`WINDOW_SUM/AVG/MIN/MAX/
  COUNT/STDEV`, `RUNNING_*`, `RANK`/`RANK_DENSE`/`RANK_PERCENTILE`, `INDEX`,
  `LOOKUP`, `TOTAL`) is **AUTO-TRANSLATED** by `build-charts-from-signals.rb`
  into Sigma-NATIVE window math emitted as CHART-element viz formulas on the
  yAxis — single DM base element, zero Custom SQL (WINPROBE-validated
  930/930 cells; full mapping table in `refs/window-functions.md`). The
  functions still CANNOT be Sigma DM calc columns (silent `error` type) and
  the `*Over` family is `Unknown function` everywhere — the chart yAxis is
  the only valid placement.
- `translation_notes` — common Tableau→Sigma gotchas to apply during the
  Phase 3 DM build: `IIF`→`If`, `COUNTD`→`CountDistinct`, IF/ELSEIF chains
  ending in literal need `Coalesce` wraps on nullable inputs (Tableau
  collapses NULL into ELSE; Sigma `If(NULL >= …, …)` returns NULL), the
  per-function window mapping (`refs/window-functions.md`), and the
  Custom-SQL escalation for the manual window residues only.

If the workbook has > 1000 calcs on a single page or the GraphQL response
exceeds ~5 MB, the API may truncate. In that case re-run with
`--source twb`, which parses the cached `.twb` directly and is bounded only
by file size.

Translate the calc fields into the DM (Phase 3) using the original Tableau
formula as the source of truth, NOT the warehouse column the calc happens
to reference. Example: a Tableau "Customer Value Tier" calc that buckets
`Lifetime Revenue` must be re-derived in Sigma from `LIFETIME_REVENUE`, not
pulled from a same-named `LOYALTY_TIER` warehouse column.

### 1e.1. Warehouse-table source rejected? Fall back to Custom SQL

> **Verified 2026-05-24** against the `tj-wells-1989` org during audit-run-1.
> Two agents (Superstore, NASA) hit `Source not found: warehouse table
> 'TJ.PUBLIC.XXX' on connection 'YYY'` POSTing a DM element whose
> `source.kind: "warehouse-table"` pointed at a table that physically existed
> in the warehouse and was queryable via `mcp__sigma-mcp-v2__query`. This is
> a **Sigma static-catalog visibility** issue: the `warehouse-table` source
> path requires the table to be indexed in Sigma's internal catalog, which
> does NOT auto-refresh after every warehouse-side landing (VDS write, dbt
> run, manual CREATE TABLE). There is currently no public API to force a
> catalog refresh; the UI's "Refresh schema" action on the connection page
> is the only mechanism, and you usually can't drive it from the conversion
> agent.

The fallback is to source the same table via Custom SQL:

```json
{
  "id": "el-orders",
  "kind": "table",
  "name": "Orders",
  "source": {
    "kind": "sql",
    "connectionId": "<connection-id>",
    "statement": "SELECT * FROM TJ.PUBLIC.NASA_GISS_LOTI"
  },
  "columns": [
    { "id": "c-year", "name": "Year", "formula": "[Custom SQL/YEAR]" },
    { "id": "c-temp", "name": "Temp Anomaly", "formula": "[Custom SQL/TEMP_ANOMALY]" }
  ]
}
```

This works because Custom SQL bypasses the catalog entirely — the connection
just executes the statement and Sigma reads whatever columns come back. The
trade-offs vs `warehouse-table` are:

> **Don't guess column names.** Sigma's spec API does not expose the columns
> of a SQL element until you've already declared them in the spec, which is a
> chicken-and-egg problem during the fallback. Run
> `scripts/probe-custom-sql-columns.rb` to resolve real column names + types
> via an INFORMATION_SCHEMA query through a one-shot probe workbook (auto-
> created, exported as CSV, deleted; ~6s end-to-end):
>
> ```bash
> ruby scripts/probe-custom-sql-columns.rb \
>   --connection-id <id> \
>   --table-path DB.SCHEMA.TABLE \
>   [--dialect snowflake|postgres|bigquery|redshift|sqlserver] \
>   --out /tmp/<name>/probe-columns.json
> ```
>
> Validated 2026-05-24 against TJ.PUBLIC.SUPERSTORE_ORDERS — 19 columns
> resolved in 7s. **Saves ~120s on every Custom SQL fallback** vs.
> POST-fail-cleanup-retrying on column-name permutations (CUSTOMER_ID vs
> CUST_ID vs ID vs RECORD_ID…). Don't skip this step.


- column-level lineage is hidden (Sigma sees one opaque SQL statement)
- per-column governance / CLS doesn't auto-apply
- the warehouse-side query optimizer treats it as a sub-select

For a customer-facing conversion these trade-offs are acceptable; for a
"production" DM build, ask the customer to refresh the Sigma connection's
schema in the UI and retry with `warehouse-table`.

### 1f. Extract Custom SQL (PAT mode)

If the source workbook uses Custom SQL — either as the entire datasource or
mixed alongside warehouse tables — run:

```bash
ruby scripts/extract-custom-sql.rb \
  --workbook-luid <wb-luid> \
  --twb /tmp/<name>/workbook-content.twb \
  --out /tmp/<name>/custom-sql.json
```

The script tries two paths:
1. **Metadata GraphQL API** for `CustomSQLTable` nodes downstream of the workbook (works for both published-datasource Custom SQL and embedded Custom SQL).
2. **`.twb` XML fallback** for embedded `<relation type='text'>` blocks (covers cases the Metadata API hasn't crawled yet).

Output is a JSON array, one entry per Custom SQL block, with `query` (the raw SQL text), `connectionType`, and downstream workbook/datasource pointers. If the array is non-empty, build the DM in Phase 3 with **Custom SQL elements** (`kind: "sql"`) sourcing the actual SQL — not warehouse-table references.

> **MCP-mode caveat.** This script needs PAT-mode env vars (`TABLEAU_AUTH_TOKEN`, etc.). If you only have MCP available, you cannot pull custom SQL — that's a real gap; switch to PAT mode for any workbook the customer says uses custom SQL.

---

## Phase 1.5 — Check for an existing DM the workbook can reuse (DO THIS FIRST)

Before running Phase 2 (warehouse column discovery) and Phase 3 (DM build), check whether the customer's Sigma org **already has a data model** that satisfies the workbook's needs. Reusing an existing DM:

- Avoids DM sprawl (customers complain when they end up with a 4th "Orders" DM)
- Cuts Phase 2 + Phase 3 entirely on the reuse path — typically the heaviest 2–3 minutes of a conversion

```bash
# Inputs:
#   workbook-signature.json — derived from Phase 1 .twb parse + view CSV headers
#     { tableau_workbook, warehouse_tables: [FQNs], referenced_columns: [...], measures: [...] }
ruby scripts/find-or-pick-dm.rb \
  --workbook-signature /tmp/<name>/workbook-signature.json \
  --out /tmp/<name>/dm-match.json \
  --limit 100 \
  [--min-score 0.6]   # default; below: build new
  [--force-new]        # bypass scan entirely
```

The picker parallel-fetches DM specs (10 concurrent threads — ~2s for 50 DMs vs ~15s serial). Scoring weights: column overlap 0.7, source-table FQN 0.2, metric overlap 0.1. Output thresholds:

| Score | Action |
|---|---|
| ≥ 0.85 | auto-reuse the recommended DM, skip Phase 2 + 3 |
| 0.6 – 0.85 | ambiguous — **ask the user** before reusing; surface the candidates from `dm-match.json` |
| < 0.6 | no usable match; proceed to Phase 2 + 3 |

Surface this in your conversation with the user:

> "Found existing DM `<name>` covering N/M of the columns this workbook references. Reuse this DM? It would skip ~2–3 min of conversion time but the workbook will inherit X extra columns (sample: ...). Reply `yes` to reuse, `no` to build new, or `show` to see other candidates."

When reusing, jump straight from Phase 1.5 to Phase 5 — the workbook spec's table elements set `source: { kind: data-model, dataModelId: <recommended_dm_id>, elementId: <chosen-element-id> }` and use formula prefixes derived from the existing DM's element name (e.g. `[Plugs Sales/Revenue]`).

The picker is **non-destructive** — it never modifies any DM. The downstream phase decides reuse vs build.

### Phase 1.5b — DM-shape preflight (MANDATORY when reusing)

> **Before writing the workbook spec, inspect the reused DM's element graph.** Skipping this is the single biggest source of conversion-time waste — a workbook POST that fails with `Cannot resolve columns on table master: dependency not found: formula reference customer_dim/region` forces 2–3 minutes of spec-rework.

Run:
```bash
ruby scripts/inspect-dm-shape.rb \
  --dm-id <recommended_dm_id> \
  --out /tmp/<name>/dm-denorm-plan.json
```

The plan classifies every column on the DM as either:
- **`location: "fact"`** — already on the fact element, reference directly as `[Master/<col>]`
- **`location: "dim"`** — lives on a separate dim element, must use `Lookup([<DimElement>/<col>], [Master/<FK>], [<DimElement>/<PK>])`

For each dim column in `dm-denorm-plan.json`, the script provides the exact Lookup formula. When writing the workbook master table:
1. The primary master table sources from the fact element (use the `fact_element.id` from the plan).
2. For each dim element referenced by the workbook's worksheets, add a **hidden master table** sourcing that dim element (`visibleAsSource: false`).
3. Master-column formulas use the plan's `column_resolution["<col>"].formula` verbatim.

The plan also surfaces `unmatched_dim_elements` — dim elements with no detectable FK on the fact (often calendar tables). If a worksheet references columns from one of these, you'll need to manually identify the join key.

Measured 2026-05-22 against the same Tableau workbook in two consecutive conversions: the run that skipped this preflight rewound 130s (21.5% of total) on the failed-POST rework path. The plan computes in ~1s and eliminates that overhead.

---

## Phase 2 — Discover actual warehouse column names

> **This step is mandatory. Do not skip it or infer column names from Tableau.**
> **Skip Phase 2 entirely if Phase 1.5 recommended a DM you reused.**

Tableau display names ("Sub-Category", "Country/Region") are NOT the same as
warehouse column names ("SUB_CATEGORY", "COUNTRY_REGION" in Snowflake;
`sub_category` / `country_region` in lowercase-by-default Postgres / Databricks;
`subCategory` / `countryRegion` in case-preserved BigQuery). Using the
display name as the warehouse name produces "dependency not found" errors at
publish time.

**Warehouse-agnostic discovery — use Sigma's REST API or MCP**, NOT the
warehouse-specific CLI (`snow sql DESCRIBE TABLE`, `bq show`, `databricks
catalogs`, etc.):

```bash
# 1. Find the connection ID (any warehouse — Snowflake / BigQuery / Databricks / etc.)
curl -sH "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections" | jq '.entries[] | {id, name, type}'

# 2. Find the table inodeId (Sigma indexes warehouse tables in its catalog)
curl -sH "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/<connectionId>/tables" | jq '.entries[] | {inodeId, path}'

# 3. List columns — PER feedback_sigma_columns_api_endpoint, the endpoint is
#    /v2/connections/tables/<inodeId>/columns (no connectionId in the path).
curl -sH "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/tables/<inodeId>/columns" | jq '.entries[] | {name, type}'
```

Or the equivalent MCP tools (preferred when available):
- `mcp__sigma-mcp-v2__describe` on a connection table → returns column names + types
- `mcp__sigma-mcp-v2__search` with `entityTypes=["table"]` to find inodeIds by name

The provided helper script wraps the REST call with parallel fan-out and the
"response key is `entries`, not `columns`" gotcha pre-handled. It works
against any Sigma connection regardless of underlying warehouse:

```bash
eval "$(scripts/get-token.sh)" && \
ruby scripts/discover-warehouse-columns.rb /tmp/<name>/columns \
  <inodeId1> <inodeId2> ...
```

Convenience: for a single table by `<db>.<schema>.<table>` path (instead of
inodeId), use `discover-columns.rb` — it does the inode lookup automatically
and emits a JSON column list:

```bash
ruby scripts/discover-columns.rb --connection-id <id> \
  --table-path TJ.PUBLIC.ORDERS --out /tmp/<name>/orders-cols.json
# (or any warehouse path: my_project.my_dataset.orders, main.public.orders, etc.)
```

If `discover-columns.rb` returns 404 — meaning the table physically exists in
the warehouse but is not in Sigma's static catalog — the fallback is to source
via Custom SQL (see Phase 1e.1 "Warehouse-table source rejected? Fall back to
Custom SQL"). There is no public API today to force a Sigma catalog refresh;
only the UI's "Refresh schema" action on the connection page can do that.

The script:
- runs all column-fetches in parallel,
- handles the "response key is `entries`, not `columns`" gotcha,
- writes one `<inodeId>.json` per table into the output dir.

The friendly names returned are the **exact** values to use in DM element formulas: `[TABLE_NAME/Column Name]`.

Find table inodeIds via Sigma search:

```
mcp__sigma-mcp-v2__search   query="<table name>"   entityTypes=["table"]
```

---

## Phase 2.5 — Detect view-level filters (mandatory)

> **Two sources, in order of authority:**
> 1. **`parse-twb-layout.rb`'s `*-meta.json`** — `shared_filters` (workbook-level filter shelf) and per-chart `zone.filters` (worksheet-level) carry resolved column captions, member-value lists, and an `is_action` flag distinguishing value filters from cross-chart action filters. `build-charts-from-signals.rb --auto-controls` translates list / relative-date / number-range shared filters into Sigma controls per page automatically.
> 2. **View CSV ↔ warehouse diff** (legacy fallback) — for `.twbx`-less workbooks or when the agent suspects the parser missed a filter, compare distinct values in the view CSV against the warehouse.

The diff method is still mandatory for any workbook where you don't have the `.twb` content. When you DO have it, trust the parser's filter output first — it carries member values that the CSV can't reveal.

For every dimension column on every view, compare:

| Source                         | Query                                              |
|--------------------------------|----------------------------------------------------|
| **View CSV signals** (Phase 1d) | Read `signals.json` — `columns.<col>.distinct`, `numeric_range`, `kind` |
| **Warehouse** (after Phase 2)  | `SELECT DISTINCT <col>` / `SELECT MIN, MAX <date>` via `mcp__sigma-mcp-v2__query` (`type: "connection"` with the table inodeId) |

Any value present in the warehouse but missing from the CSV implies a filter on that column.

```sql
SELECT MIN("DATE") AS min_date, MAX("DATE") AS max_date,
       COUNT(DISTINCT DATE_TRUNC('quarter', "DATE")) AS qtr_count
FROM "connection"."<table-inodeId>"
```

### Common patterns

| View CSV symptom | Likely Tableau filter | Sigma translation |
|---|---|---|
| Only some values of a categorical column appear | "Keep only" / dimension filter | `list` control with `mode: "include"`, or element-level filter |
| Date min/max is narrower than warehouse | Date / relative-date filter | `date-range` control — `mode: "current"` + `unit: "year"\|"quarter"\|...` for relative; `mode: "between"` with explicit `startDate`/`endDate` for fixed |
| Numeric column is bounded | Range filter | `number-range` or `range-slider` control, or element-level filter |
| Only top N items by some measure | Top-N filter | `top-n` control or element-level `top-n` filter (see `refs/workbook-layout.md`) |

### Where to apply the filter

Prefer a **workbook-level control filtering the master table** — every chart that sources from master inherits the filter, matching how a Tableau dashboard filter works. Use **element-level filters** only when the filter is fixed and shouldn't be user-adjustable (a hard-coded slice).

```json
"filters": [{"source": {"kind": "table", "elementId": "master"}, "columnId": "<master-col-id>"}]
```

> **A relative-date filter that "rolls forward" in Tableau** ("this year", "last 30 days", "year to date") must be translated as a relative `date-range` control (`mode: "current"`, `unit: ...`) — not a fixed start/end date. Hard-coding `startDate`/`endDate` freezes the filter to today's date and breaks tomorrow.

> **Phase 6 will not catch a missed filter on its own.** Data parity in Phase 6 compares Sigma rows to Tableau rows for the dimensions you query — if your Sigma chart includes extra rows the CSV never had, the comparison only flags missing rows from Tableau, not extra rows in Sigma. Always sanity-check distinct values and date ranges side-by-side before declaring parity.

---

## Phase 3 — Build the data model spec

Write the spec to `/tmp/<name>/dm-spec.json`. Full schema is in
`refs/data-model-spec.md`.

### Critical rules

1. **Endpoint**: `POST /v2/dataModels/spec` — NOT `/v2/workbooks/spec`.
2. **`folderId` is required.** Find it via `GET /v2/files?typeFilters=workbook` — `parentId` on any of your workbooks.
3. **Top-level shape uses `pages: [{elements: [...]}]`, NOT a bare `elements: [...]` at root.** The API rejects root-level `elements` with `pages: Invalid array: undefined`. Even if your DM only has one logical page (typical), still wrap the elements under a single page:
   ```json
   {
     "name": "Orders",
     "folderId": "<folder>",
     "schemaVersion": 1,
     "pages": [
       {
         "id": "p-data",
         "name": "Data",
         "elements": [ { /* warehouse-table or sql element */ } ]
       }
     ]
   }
   ```
   This is the same shape `refs/data-model-spec.md` documents; the abbreviated examples below show only the element body — wrap them in `pages: [{elements: [...]}]` before POSTing.
3. **Column name special characters** — read `refs/column-gotchas.md`. Rename any column whose `name` contains `/` ("Country/Region" → `"Country"`, "State/Province" → `"State"`).
4. **Element name = formula prefix**. The `name` field on a DM element (e.g. `"Orders"`) becomes the prefix in all workbook formulas that reference it: `[Orders/Sales]`. Choose clean, stable names.
5. **Relationships go on the source element**, not the target. See `refs/data-model-spec.md`.
6. **Column formulas use the warehouse table name as prefix**: path `["CSA", "Tableau Test", "ORDERS"]` → formula `"[ORDERS/Column Name]"`.

### When to use a Custom SQL element instead of a calc column

> **Sigma window functions silently fail in DM calc columns and in workbook master (grouping-table) calc columns** — `CumulativeSum`, `Rank`, `Lag`, etc. POST successfully but resolve as `error` on GET, and the `*Over` family (`SumOver`/`RankOver`/`MaxOver`/...) is `Unknown function` in every spec context. **But they are FIRST-CLASS as CHART-element viz formulas on the yAxis** (WINPROBE-validated 2026-06-12, 930/930 cells): `build-charts-from-signals.rb` auto-emits the whole mainstream window/table-calc family that way — `RUNNING_*`→`Cumulative*`, bounded `WINDOW_*`→`Moving*`, share→`PercentOfTotal(agg, "grand_total")`, pareto→`CumulativeSum(PercentOfTotal(...))`, `RANK*`→`Rank/RankDense/RankPercentile(agg, "desc")`, `INDEX()`→`RowNumber()`, `LOOKUP(±n)`→`Lag/Lead`, unbounded `WINDOW_MAX/MIN/SUM`/`TOTAL`→hidden two-level grouped helper. Cumulative/rank formulas follow the chart's `xAxis.sort` (Tableau `<computed-sort>` is carried via a hidden companion measure) and auto-partition by the chart color dim. **Full mapping table + the broadcast-down/week-anchor gotchas: `refs/window-functions.md`.** The design rule stands: never write window functions as DM or master calc columns.

> **`{FIXED ...}` LODs are AUTO-TRANSLATED — no Custom SQL needed.** When a
> `{FIXED [dims] : AGG([m])}` calc is plotted as a chart/KPI measure,
> `build-charts-from-signals.rb` emits a hidden TWO-LEVEL grouped helper
> element on the Data page (`visibleAsSource:false`; inner grouping = the
> FIXED dims computing the LOD aggregate, outer grouping = the chart's dims
> computing the 2nd-stage aggregate over the inner GROUP values) and the chart
> sources the helper, `Max()`-ing the outer calc (a chart re-aggregates a
> grouped source at BASE grain with group calcs replicated per row — Max over
> identical replicas is exact; verified live 2026-06-12). ⚠ Carried chart dims
> must be functionally dependent on the FIXED dims (e.g. Customer Segment per
> Customer Id) — the build emits a per-chart verify warning. The same helper
> machinery handles **grain-aware averages**: `Avg` of a dim-table column
> (Tableau relationship semantics evaluate it at the dim table's NATIVE grain,
> including entities with no fact rows) sources the DM dim element directly.
> NEVER write these as `SumOver`/`CountOver` master or DM calc columns — they
> silently error.

Any Tableau calc whose `requires_custom_sql: true` (from Phase 1e) — that is, a **manual window residue** (`WINDOW_MEDIAN/PERCENTILE/CORR/COVAR(P)/VAR(P)/STDEVP`, `PREVIOUS_VALUE`, `SIZE`, `FIRST`, `LAST`, `RANK_UNIQUE/MODIFIED`, or a compute-using/addressing variant beyond Table(Across)/simple partitions) or an `{INCLUDE/EXCLUDE}` LOD (those need the chart-grouping context) — must be implemented as a **Sigma Custom SQL data-model element**. (The mainstream `WINDOW_*`/`RUNNING_*`/`RANK*`/`INDEX`/`LOOKUP`/`TOTAL` family no longer routes here — it is auto-emitted as Sigma-native chart formulas, `refs/window-functions.md`.)

```json
{
  "id": "el-orders-windowed",
  "kind": "table",
  "name": "Orders With Window Calcs",
  "source": {
    "connectionId": "<connection-id>",
    "kind": "sql",
    "statement": "SELECT o.ORDER_ID, o.REGION, o.SALES,\n  SUM(o.SALES) OVER (PARTITION BY o.REGION) AS REGION_TOTAL_SALES,\n  RANK() OVER (PARTITION BY o.REGION ORDER BY o.SALES DESC) AS SALES_RANK_IN_REGION,\n  SUM(o.SALES) OVER (ORDER BY o.ORDER_DATE ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUNNING_SALES\nFROM ANALYTICS.PUBLIC.ORDERS o"
  },
  "columns": [
    { "id": "c-order-id",      "name": "Order Id",            "formula": "[Custom SQL/ORDER_ID]" },
    { "id": "c-region",        "name": "Region",              "formula": "[Custom SQL/REGION]" },
    { "id": "c-sales",         "name": "Sales",               "formula": "[Custom SQL/SALES]" },
    { "id": "c-region-total",  "name": "Region Total Sales",  "formula": "[Custom SQL/REGION_TOTAL_SALES]" },
    { "id": "c-sales-rank",    "name": "Sales Rank in Region","formula": "[Custom SQL/SALES_RANK_IN_REGION]" },
    { "id": "c-running-sales", "name": "Running Sales",       "formula": "[Custom SQL/RUNNING_SALES]" }
  ]
}
```

Key points:
- `source.kind` is `"sql"` (not `"warehouse-table"`).
- `source.statement` is the raw SQL text (the field name is `statement`, NOT `sql`). Use the warehouse dialect for the underlying connection (Snowflake, BigQuery, etc.).
- Column formula prefix is `[Custom SQL/<ALIAS_FROM_SELECT_LIST>]`. The alias is whatever you wrote in the `SELECT ... AS NAME` clause. **Use UPPERCASE aliases** (matches Snowflake's default identifier casing); Sigma's column lookup is case-sensitive against the SQL output.
- Every column you want to expose in the DM needs both a SELECT-list entry in the SQL AND a corresponding `columns[]` entry on the DM element.
- Translation hints from `extract-calc-fields.rb`:
  - `RUNNING_*` / bounded `WINDOW_*` / `RANK*` / `INDEX` / `LOOKUP` / `TOTAL` — **do NOT route here anymore**: auto-emitted as Sigma-native chart viz formulas (`refs/window-functions.md`). The ANSI `OVER(...)` forms below are the fallback ONLY for the manual residues (`WINDOW_MEDIAN`/`WINDOW_PERCENTILE`/`PREVIOUS_VALUE`/`SIZE`/non-default addressing): e.g. `WINDOW_MEDIAN(SUM([X]))` → `MEDIAN(X) OVER (<partition>)`, `PREVIOUS_VALUE` → recursive logic in SQL.
  - `{FIXED [Dim] : SUM([X])}` → `SUM(X) OVER (PARTITION BY Dim)` or a pre-aggregated subquery joined back — **fallback only**: when the LOD is plotted as a chart/KPI measure it is AUTO-TRANSLATED via the hidden two-level helper element (see the callout above), no Custom SQL needed
  - **Nested LODs** (`{FIXED A : AVG({FIXED A, B : SUM([X])})}`) → a helper-element CHAIN, not one formula: innermost LOD = helper element 1 (grouped by its dims, aggregate as `Value`), each outer level consumes `[LOD Helper k/Value]` via a relationship on the shared dims. `build-charts-from-signals.rb` decomposes these automatically into `<out>-lod-chains.json` (innermost first) — build one grouped element (or Custom SQL `GROUP BY` subquery) per level. **Each outer level's source MUST carry `groupingId` pointing at the inner element's grouping** — a plain `{kind: table, elementId}` source reads BASE-grain rows with the aggregate repeated per row, so outer Avg/Median/Count silently come out row-weighted (caught live: 969.82 row-weighted vs 687.81 correct on CSA.TJ.ORDER_FACT). Live-verified pattern (exact parity vs warehouse SQL), 2026-06-11.

When a workbook mixes plain calcs with window calcs, you can have BOTH kinds of DM elements in the same data model: one `warehouse-table` element for everything plain, plus one or more `sql` elements for the window/LOD calcs, related by key. Charts source from whichever element has the columns they need.

> **DM PUT reassigns element IDs.** Combining a `warehouse-table` element with a `sql` element in the same DM works fine, but every PUT of the DM spec churns IDs — so plan to capture IDs once with `post-and-readback.rb`, build the workbook from those IDs, and avoid editing the DM in flight.

### Translate Tableau calc fields here

Each calc from `calc-fields.json` (Phase 1e) becomes a DM calc column (or a workbook-level
calc on the master table, depending on grain). For calc columns that wrap a NULLABLE source
in an IF/ELSEIF chain, **wrap with `Coalesce` to match Tableau's null-fallthrough behavior**.

Example — Tableau:

```
IF [Lifetime Revenue] >= 5000 THEN "Platinum" ELSEIF >= 2000 THEN "Gold" ELSEIF >= 500 THEN "Silver" ELSE "Bronze" END
```

Sigma DM calc column on Order Fact (since the bucket depends on a joined dim):

```
If(Coalesce(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]), -1) >= 5000, "Platinum",
  If(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]) >= 2000, "Gold",
    If(Lookup([Customer Dim/Lifetime Revenue], [Customer Key], [Customer Dim/Customer Key]) >= 500, "Silver", "Bronze")))
```

Without `Coalesce(-1)` orphan-joined rows produce a NULL bucket instead of falling into "Bronze"
the way Tableau's ELSE does — and parity will diverge.

### Validate before posting

```bash
ruby scripts/validate-spec.rb --type datamodel /tmp/<name>/dm-spec.json
```

Catches: formula prefix mismatches, bare refs not matching a sibling, `kpi`/`pie`/`donut` kind
mistakes, `rgb(...)` color strings (Cloudflare WAF blocks), missing yAxis on
bar/line/area/combo/scatter, missing color+value on pie/donut, donut `holeValue.id` matching
`value.id` (silent element drop), pivot-table missing rowsBy (single grand-total row), and
nested-If on date functions without IsNull guard.

Exit 0 = clean, exit 1 = errors printed to stdout.

---

## Phase 4 — POST the data model

```bash
eval "$(scripts/get-token.sh)" && \
ruby scripts/post-and-readback.rb --type datamodel \
  --spec /tmp/<name>/dm-spec.json \
  --out /tmp/<name>/dm-ids.json
```

The script:
- POSTs the spec,
- parses the YAML response (the spec endpoints return YAML by default),
- immediately GETs the spec back to retrieve server-assigned element IDs,
- writes a clean JSON map: `{dataModelId, pages: [{id, name, elements: [{id, kind, name}]}]}`.

Record the `dataModelId` and element IDs. The `dm-ids.json` is used by the
workbook validator (Phase 5) to accept `[Order Fact/...]` cross-source refs.

On error: read the message → fix the offending column formula → re-validate → re-POST.

---

## Phase 5 — Build the Sigma workbook

### 5a-auto. Run build-charts-from-signals first

For most workbooks, `build-charts-from-signals.rb` produces a usable starting spec:

```bash
ruby scripts/build-charts-from-signals.rb \
  --tableau-dir /tmp/<name> \
  --layout /tmp/<name>/dashboard-layout.json \
  --meta /tmp/<name>/dashboard-layout-meta.json \
  --master-map /tmp/<name>/master-columns.json \
  --master-element-id master \
  --auto-controls --page-per-worksheet \
  --title "<Workbook Title>" \
  --out /tmp/<name>/chart-specs.json
```

What the build script auto-handles (no agent action needed):
- ✅ chart-kind from `mark` class (bar/line/area/pie/scatter/map)
- ✅ sort direction from `<sort>` (xAxis.sort emitted only when Tableau sorted)
- ✅ aggregator from `column-instance derivation` (Sum/Avg/CountD/Median)
- ✅ DateTrunc for `Month-Trunc`/`Year-Trunc` dimensions
- ✅ Tableau format strings → Sigma d3-format (incl. paren-negative)
- ✅ Column aliases → `Switch(...)` calc on the chart's dim column
- ✅ Shared-view filters → per-page Sigma controls (list/date-range/number-range)
- ✅ Parameters (list domain) → segmented controls
- ✅ Parameter-driven CASE/IF chains → `Switch([ctl-param-X], ...)` calc
- ✅ Table calcs INDEX/LOOKUP/TOTAL/RANK/ZN/IIF/COUNTD → Sigma equivalents
- ✅ Synchronized-axis worksheets → `combo-chart` kind w/ two yAxis groups
- ✅ Customer-discovered learned-rules from `~/.tableau-to-sigma/learned-rules.yaml`

What WARN lines mean — act on each one:
- `'X' parameter-driven calc … → translated to Switch: …` — already emitted, no action needed
- `'X' Tableau table-calc … → Sigma: ...` — copy-paste the formula into a master column if it's used by multiple charts
- `'X' learned-rule applied to … → Sigma: ...` — already emitted, no action needed
- `'X' has Tableau reference marks (...)` — manually add Sigma `referenceMarks` to the chart post-publish (see beads-sigma-7ak)
- `'X' has a color channel on …` — multi-series fan-out: agent emits one yAxis per category in the chart spec
- `'X' has N Tableau action filter(s) — skipped` — read `<out>-actions.md` and wire Sigma cross-element filtering manually
- `'X' detected as dual-axis` — auto-emitted as combo-chart; verify the right kind in the readback
- `parameter '...' is a numeric range — skipped auto-control` — add a number control by hand (blocked on beads-sigma-ebw)

### 5a. Write the workbook spec

> **`folderId` is required here too.**

#### The two-page rule — master always on a dedicated "Data" page

> **MANDATORY.** Every workbook spec MUST have at least two pages: one named `Data`
> containing the master table, and one or more *content* pages containing charts,
> controls, and text. Charts on content pages source the master via cross-page
> `"elementId": "master"` references. **Do not** place the master alongside charts
> on a content page — it shows up as a giant table on the dashboard, and users
> have to manually delete it post-publish.

Spec skeleton (two pages, master on `Data`, all charts on `Orders Overview`):

```json
{
  "name": "Orders Overview",
  "folderId": "<folder-id>",
  "schemaVersion": 1,
  "pages": [
    {
      "id": "page-data",
      "name": "Data",
      "elements": [
        {
          "id": "master",
          "kind": "table",
          "name": "Master",
          "visibleAsSource": false,
          "source": {
            "kind": "data-model",
            "dataModelId": "<dataModelId>",
            "elementId": "<elementId from dm-ids.json>"
          },
          "columns": [
            { "id": "m-sales", "formula": "[Order Fact/Sales]", "name": "Sales" }
          ],
          "order": ["m-sales"]
        }
      ]
    },
    {
      "id": "page-overview",
      "name": "Orders Overview",
      "elements": [
        { "id": "txt-title", "kind": "text", "body": "# Orders Dashboard" },
        {
          "id": "el-ctl-date",
          "kind": "control",
          "controlId": "ctl-date",
          "name": "Order Date",
          "controlType": "date-range",
          "selectionMode": "ranges",
          "source": { "kind": "source" },
          "mode": "between",
          "filters": [{ "source": { "kind": "table", "elementId": "master" }, "columnId": "m-order-date" }],
          "includeNulls": "when-no-value-is-selected"
        },
        {
          "id": "el-kpi-sales",
          "kind": "kpi-chart",
          "source": { "kind": "table", "elementId": "master" },
          "columns": [{ "id": "k-sales", "formula": "Sum([Master/Sales])", "name": "Total Sales" }],
          "value": { "columnId": "k-sales" }
        }
      ]
    }
  ]
}
```

Rules:
- Master `kind` is `table`, `visibleAsSource: false`, sourced from the DM element.
- Master-column formulas use the DM element's `name` as prefix (`[Order Fact/Sales]`, not the element ID).
- Charts and controls source the master with `"elementId": "master"` regardless of which page they live on — cross-page references are fully supported.
- Chart-column formulas use the master table's `name` as prefix (`[Master/Sales]`).
- Layout XML must produce **one `<Page>` tag per page**, including a tiny full-width `<LayoutElement elementId="master" .../>` inside the Data page's `<Page>`.

> **Control element skeleton — every field is required.** First POSTs commonly
> fail with `Invalid kind: "control"` because one of these is missing. The
> shape above (the `el-ctl-date` example) is the minimum the API accepts:
>
> - `kind: "control"` and a distinct `id` + `controlId` (they share a
>   namespace — use `id: "el-ctl-X"`, `controlId: "ctl-X"` to avoid the
>   `Duplicate id` error).
> - `controlType` — one of: `list`, `date-range`, `text`, `text-area`,
>   `segmented`, `number`, `number-range`, `slider`, `range-slider`, `top-n`.
> - `selectionMode` — typically `ranges` (date-range), `single` (segmented /
>   list), `multiple` (list with checkboxes).
> - `source: { kind: "source" }` — yes, the literal string `"source"`. This
>   tells Sigma the control is its own source (not bound to a table column for
>   its option set).
> - `mode` — `between` for date-range, `current` for relative-date, `include`
>   for list, `=` / `<` / `>` etc. for number.
> - `filters: [{ source: { kind: "table", elementId: <id> }, columnId: <id> }]`
>   — wires the control to the master-table column(s) it filters. Repeatable
>   to filter multiple charts.
> - `includeNulls: "when-no-value-is-selected"` — sane default; otherwise rows
>   with NULL on the filtered column drop out of every chart whenever the
>   control is unset.
>
> Full surface (range-slider, segmented options, top-n) in the
> `sigma-workbooks` skill's `reference/specification/controls.md`.

> **Master-table column scope.** Default: pull every column you've already denormalized
> in the DM into the master with passthrough formulas. The master is cheap; amending it
> later for a new control requires a workbook spec edit even though no chart breaks.

> **KPI kind is `kpi-chart`, not `kpi`. Pie is `pie-chart`. Donut is `donut-chart`.**
> The validator catches this; don't rely on it.

```json
{
  "kind": "kpi-chart",
  "source": { "kind": "table", "elementId": "master" },
  "columns": [
    { "id": "k-sales", "formula": "Sum([Master/Sales])", "name": "Total Sales",
      "format": {"kind": "number", "formatString": "$,.0f"} }
  ],
  "value": { "columnId": "k-sales" }
}
```

See `refs/workbook-layout.md` for chart patterns, multi-series formulas, and map shapes.

### 5b. Validate the workbook spec

```bash
ruby scripts/validate-spec.rb --type workbook \
  --dm-context /tmp/<name>/dm-ids.json \
  /tmp/<name>/wb-spec.json
```

`--dm-context` lets the validator accept `[Order Fact/...]` cross-source refs (where
"Order Fact" is a DM element name from Phase 4). Without it, every cross-source ref is
flagged as unknown.

### 5c. POST the workbook + readback

```bash
ruby scripts/post-and-readback.rb --type workbook \
  --spec /tmp/<name>/wb-spec.json \
  --out /tmp/<name>/wb-ids.json
```

> **Element IDs may or may not survive POST.** Workbook-spec POST often preserves readable
> string element IDs verbatim, but this is not contractual. Data-model-spec POST always
> reassigns IDs. Either way, the readback is the source of truth — use IDs from `wb-ids.json`
> when wiring layout XML.

### 5d. Build layout XML (MANDATORY)

> **Skip this step and Sigma renders every tile as a single-column stack** —
> the CoCo regression (beads-sigma-bw3). `assert-phase6-ran.rb` gate 4
> rejects any workbook without a non-empty top-level `layout` XML.

**Preferred path — auto-layout from the parsed Tableau zone tree:**

```bash
ruby scripts/build-dashboard-layout.rb \
  --layout /tmp/<name>/dashboard-layout.json \
  --wb-ids /tmp/<name>/wb-ids.json \
  --out /tmp/<name>/layout.xml
# If any chart tile was renamed from its Tableau title, pass the same
# --rename "Tableau name=Sigma name" pairs you give the parity scripts —
# otherwise the renamed tile silently drops out of the layout (bead ddbq).
# Row heights are scaled 1.5x by default (--row-scale) so Sigma doesn't
# suppress axis/pie labels on short tiles (bead tkkv); proportions are kept.

ruby scripts/put-layout.rb \
  --workbook <workbookId> \
  --layout /tmp/<name>/layout.xml
```

`build-dashboard-layout.rb` walks the dashboard's zones, converts each
zone's `x_pct`/`y_pct`/`w_pct`/`h_pct` into Sigma 24-column grid spans,
and stretches adjacent tiles to fill empty columns where Tableau had
legend/filter shelves Sigma doesn't render. Band heights are multiplied by
`--row-scale` (default 1.5 — Tableau zone ratios mapped 1:1 onto a 32-row
page produce tiles short enough that Sigma suppresses axis and pie labels;
1.43× was the empirically sufficient minimum, looker's builder uses 2×). This is the dashboard-fidelity
path — chart positions mirror the source PNG.

**Hand-rolled path — page-per-worksheet OR when zone parsing fails:**

For the few cases where the parser can't produce a usable layout (e.g.,
workbooks with no `<dashboard>` element, or a layout you want to redesign),
write a per-workbook layout config that `require`s the helper library.
Never hand-write layout XML directly.

> **PUT /v2/workbooks/{id}/spec wipes the top-level `layout` string.** If you
> re-PUT the workbook spec after a formula fix (or any other spec edit), the
> existing layout is **erased** and the workbook reverts to a single
> auto-stacked column. Two ways to avoid the round trip:
> 1. **Preferred:** re-emit the layout XML in the same PUT body — set
>    `spec.layout` to the assembled XML string before PUTting.
> 2. Or PUT layout separately AFTER spec via `scripts/put-layout.rb`. That
>    script GETs the spec, replaces just the layout field, and PUTs back. Cost:
>    one extra round trip (~5-15s) and an export to confirm.
>
> The OCT standalone conversion lost 18s on this round trip; document the
> pattern up front.

```ruby
# /tmp/<name>/build-layout.rb
require 'json'
$LOAD_PATH.unshift File.expand_path('scripts/lib', __dir__)  # or absolute path
require 'layout'
include SigmaLayout

# Element IDs from Phase 5c
ids = JSON.parse(File.read('/tmp/<name>/wb-ids.json'))
e = ids['pages'][0]['elements'].each_with_object({}) { |x, h| h[x['id']] = x['id'] }

xml = assemble(
  page_xml('page-dashboard',
    le(e['title-text'],     1, 25,  1,  3),
    le(e['el-kpi-1'],       1,  7,  3,  9),
    le(e['el-kpi-2'],       7, 13,  3,  9),
    le(e['el-chart-1'],     1, 13,  9, 21),
    le(e['el-chart-2'],    13, 25,  9, 21)
  ),
  page_xml('page-data', le('master', 1, 25, 1, 21))
)

File.write('/tmp/<name>/layout.xml', xml)
```

Layout helpers (in `scripts/lib/layout.rb`): `gc(eid, c0, c1, r0, r1, inner)` for
`<GridContainer>`, `le(eid, c0, c1, r0, r1)` for `<LayoutElement>`, `page_xml(page_id, *children)`
to wrap a page, `assemble(*pages)` to add the XML prologue.

See `refs/workbook-layout.md` for typical page layouts (4 KPIs + line chart + 2 bars,
multi-row containers, etc.) and rules (`<GridContainer>` for nesting, KPI inner `gridRow`
must match container outer span).

### 5e. PUT the layout

```bash
ruby scripts/put-layout.rb \
  --workbook <workbookId> \
  --layout /tmp/<name>/layout.xml
```

The script:
- GETs the current workbook spec,
- replaces per-page `layout` with a single top-level `layout` (per-page layouts are silently dropped),
- strips read-only fields (`workbookId`, `url`, `ownerId`, `createdBy`, `updatedBy`, `createdAt`, `updatedAt`, `latestDocumentVersion`),
- aborts if any `elementId=""` appears in the XML,
- PUTs the full payload back.

PUT preserves existing element IDs. Only newly-added elements get new IDs.

### 5f. Compile-check every element (MANDATORY)

```bash
ruby scripts/verify-workbook.rb <workbookId>
```

POST is permissive — it accepts specs whose column formulas don't actually resolve at query time. Those failures surface as string literals in the compiled SQL (`'Unknown column "[X]"'` / `'Circular column reference to [X]'`), and the UI renders the element as empty. `post-and-readback.rb`'s column-type guard catches **some** of these (columns whose type resolves as `error`), but not all. `verify-workbook.rb` asks the server's compiler directly via `GET /v2/workbooks/{id}/elements/{eid}/query` and greps the markers — catches everything the spec-level validator misses. **Parallel-fetches all elements** (5 threads + 429 backoff) — ~1.3s for an 11-element workbook vs ~4s for the legacy `verify-workbook.sh`.

Exit codes:
- `0` — every queryable element compiles clean
- `1` — one or more elements have unresolved/circular formula references; fix the offending columns in the spec, re-PUT, re-verify
- `2` — setup error (missing env, bad workbook ID)

Control elements and other non-queryable kinds are correctly skipped.

This step is mandatory and must run before declaring the conversion done.

---

## Phase 6 — Verify chart data matches Tableau (MANDATORY — hard-gated)

> **A conversion is not complete until `scripts/assert-phase6-ran.rb` exits 0.** This is a *hard gate*, not a guideline. `phase6-parity.rb --finalize` writes `/tmp/<name>/parity-final.json` as a sentinel; `assert-phase6-ran.rb` reads it and exits non-zero if Phase 6 was skipped, ran in extract-mode without permission, or failed parity. Subagent flows (cluster followers via `tableau-assessment`) MUST run the assertion as their final step before writing the result line — without it, an agent can silently skip Phase 6 entirely and self-report `charts_pass: 0, charts_total: 0` to slip past the GREEN check. See `beads-sigma-4pm` for the regression that motivated the gate.

> **PUT returning `success: true` is not verification.** It only proves the spec parsed. Two recent customer-visible bugs reached the customer because Phase 6 was skipped: a window-function calc compiling silently as `error` and a pie chart wired to the wrong dimension. Compile-clean from `verify-workbook.rb` is also not parity verification — that only confirms each formula resolves, not that the numbers match.

> **If `mcp__sigma-mcp-v2__query` errors with an auth-related message mid-Phase-6**, the Sigma MCP session has staled. Re-call `mcp__sigma-mcp-v2__begin_session` and retry the query. Do NOT skip Phase 6 because of a recoverable auth error — that's the 2026-05-22 cluster-follower regression.

### 6 — one-step (preferred)

```bash
ruby scripts/phase6-parity.rb \
  --tableau /tmp/<name> \
  --workbook-id <sigma-workbook-id>
# add --extract-mode --extract-tol 0.30 when source workbook has a .hyper extract
```

This runs everything below as one command: builds the plan, fetches Sigma
actuals via the workbook elements API, runs the verifier, prints a
pass/fail summary, writes `/tmp/<name>/parity-final.json`. Exits non-zero
on divergence. Use this as the default — the per-step path below is for
debugging.

After it finishes, **always** run the hard gate:

```bash
# If you POSTed multiple workbooks during the conversion (e.g., iterative
# spec retries), clean up the orphans first — POST is create-only and each
# retry leaves an orphan in the customer's My Documents:
ruby scripts/cleanup-orphan-workbooks.rb --workdir /tmp/<name>

# Then run the hard gate:
ruby scripts/assert-phase6-ran.rb --tableau /tmp/<name>
# add --allow-extract when running parity in extract-mode
```

The gate checks five independent things and rejects on any failure:

1. **Phase 6 ran** — `parity-final.json` exists with status=PASS at the
   required rate.
2. **No orphan workbooks** — `posted-workbooks.jsonl` has ≤1 entry, OR
   `cleanup-marker.json` shows a successful non-dry-run cleanup. This
   closes the 2026-05-28 regression where a customer ended up with three
   workbooks (one final + two orphans from iterative POSTs).
3. **No `type=error` columns on the live workbook** — fetches
   `/v2/workbooks/{id}/columns` and rejects any column whose type
   resolved to `error`. Catches circular references, unknown column
   refs, unsupported functions — anything that renders an error banner
   in the Sigma UI but slipped past the initial POST's guard because it
   was introduced by a later PUT (layout update, spec edit during error
   recovery).
4. **Layout applied** — fetches `/v2/workbooks/{id}/spec` and rejects
   when the top-level `layout` field is empty or has fewer than 2
   `<LayoutElement>` tags. Catches the CoCo regression where the agent
   forgot to PUT a layout and Sigma rendered every tile as a
   single-column stack instead of the dashboard grid.
5. **Tile census** — reads `tile_census` from `parity-final.json`
   (emitted by `phase6-parity.rb --finalize` when
   `dashboard-layout.json` is present): "X zones, Y charts built,
   Z unmatched". Rejects when any source dashboard zone has no
   matching chart in the parity plan — the empty-view-CSV escape
   where the builder silently emitted N-1 charts and every other
   gate still passed (bead gjhe). Renamed tiles must be explained
   via `--rename` on `phase6-parity.rb`; legitimately unbuildable
   zones via `--allow-missing-tiles N` (name them in your report).

Exit 0 means the conversion is allowed to declare GREEN. Any other exit
code means downgrade to YELLOW (parity skipped or incomplete, orphans
left, runtime errors visible, layout missing) or RED (parity failed).
See beads-sigma-4pm, beads-sigma-38a, beads-sigma-bw3.

> **POST vs PUT for spec updates.** `POST /v2/workbooks/spec` is
> create-only. After the first successful POST returns a workbook ID,
> every subsequent spec update MUST use `PUT /v2/workbooks/{id}/spec`
> against that ID. Re-POSTing creates a duplicate workbook in the
> customer's My Documents — and the gate will fail until you run
> `cleanup-orphan-workbooks.rb`. `post-and-readback.rb` now prints a
> loud warning on second+ invocation listing the prior IDs and the
> exact PUT command to use instead.

`scripts/post-and-readback.rb` now prints a "NEXT STEP — Phase 6" prompt
with the exact invocation at the end of every workbook POST, so the agent
sees the reminder right after the spec lands. Don't ignore it.

### 6a. Auto-build a parity plan

Don't hand-write the plan. Use the auto-builder, which matches Sigma chart-element names to Tableau view CSVs and emits a plan keyed by chart:

```bash
ruby scripts/auto-parity-plan.rb \
  --tableau /tmp/<name> \
  --workbook-spec /tmp/<name>/wb-spec.json \
  --workbook-id <sigma-workbook-id> \
  --out /tmp/<name>/parity-plan.json
```

On `--finalize`, `phase6-parity.rb` also writes a `tile_census` field into `parity-final.json` (zones vs charts built vs unmatched, read from `dashboard-layout.json`) — gate 5 of `assert-phase6-ran.rb` fails on unmatched zones.

The output is wrapped as `{ "extract": <bool>, "charts": [...] }` — the `extract` flag is set automatically from `get-workbook.json`'s `hasExtracts` field when the workbook itself is extract-backed. If a Sigma chart was renamed from its Tableau title (e.g., the pie tile renamed from "Order Channel vs Ship Method" → "Orders by Category"), pass `--rename "Order Channel vs Ship Method=Orders by Category"` so the auto-matcher pairs them.

> **Extract status is also visible on the workbook's datasource.** `auto-parity-plan.rb` only reads workbook-level `hasExtracts`. If the underlying datasource has an extract but the workbook attribute is `false`, you'll have to flip the `extract` field by hand OR pass `--extract-mode` to verify-parity.rb.

### 6b. Fetch Sigma actuals

**Pooled collection first (the fast path).** `phase6-parity.rb` pass 1 runs
`scripts/collect-parity-actuals.rb` automatically: it pools the element CSV
exports (`POST /v2/workbooks/{wb}/export` → poll `GET /v2/query/{q}/download`,
5-wide, with the discovery pool's backoff pattern, under `lib/sigma_rest`'s
auto-refresh) and fills `parity-actuals.json` for every chart kind except
pivot-tables — the export returns exactly the plotted channels with column
display names as headers, in the long form the plan compares (verified on the
40-chart fat workbook: grouped "level" tables included; pivot CSV export is
the WIDE grid, so pivots stay agent-mediated). ~40 charts collect in well
under a minute vs ~6 minutes of serial MCP queries.

For every REMAINING chart (pass 1 prints exactly those), query Sigma via the MCP tool. **Fire all N chart queries in a SINGLE parallel tool-use batch** — one message with N `mcp__sigma-mcp-v2__query` tool blocks side-by-side. Each individual query takes ~5–20s; parallel cap is bounded by the slowest one, sequential is N × that.

```
mcp__sigma-mcp-v2__query  type="workbook"  workbookId="<wbId>"
  sql='SELECT "<dim-col-id>", ROUND("<measure-col-id>"::numeric, 2) FROM "workbook"."<element-id>" ORDER BY 1'
```

The plan file pre-populates `sql_template` and `workbookId` on each chart — just run the SQL and paste the resulting rows under `"actual": { "rows": [...] }`.

> **DO NOT try to fetch actuals via REST.** `POST /v2/workbooks/{wb}/query` does not exist (returns `errorcause: UnmatchedHandler` with empty body — silent failure). The MCP path is canonical. An earlier version of `auto-parity-plan.rb` tried this REST endpoint with a silent-rescue clause; that was a bug, removed in beads-sigma-s04.

> **A chart element's SQL view exposes only that chart's own columns.** A `WHERE "m-order-date-key" BETWEEN ...` against `el-rev-by-region` fails with `Unresolved column`. Two ways to handle:
> - Query the master table directly (`FROM "workbook"."master"`) and aggregate in SQL.
> - Skip the filter and compare what the chart shows. Workbook control filters are not applied at API-query time, so a `type="workbook"` SQL query against a chart element returns the full unfiltered dataset.

### 6c. Run the verifier

```bash
# Strict (default): exact value comparison
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json

# Extract mode: structural comparison only, tolerant of value drift
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json --extract-mode
ruby scripts/verify-parity.rb --plan /tmp/<name>/parity-plan.json --extract-mode --extract-tol 0.50
```

Output: per-chart `PASS` or `DIVERGE`. Exit 0 on full pass, 1 on any divergence.

### 6d. Extract handling

When the Tableau workbook (or its datasource) has `hasExtracts: true`, the view CSVs reflect a **frozen snapshot** of the warehouse from the last extract refresh. Sigma queries the warehouse live, so the absolute values WILL drift — that's expected, not a bug. `--extract-mode` shifts the check to:

- ✓ same number of buckets (rows in the chart)
- ✓ same set of dimension values
- ✓ same sort order on the dimension
- ⚠ measure values within `--extract-tol` (default 30%) — anything outside is flagged but does NOT fail the check; review case-by-case

If the customer expects Tableau-extract numbers to match Sigma-live numbers exactly, the answer is to refresh the Tableau extract before exporting CSVs OR to point Sigma at the same snapshot via a saved query. Otherwise live-vs-extract divergence is structural, not a parity bug.

> **Cross-extract drift parity rule.** If the workbook uses a Tableau extract (`hasExtracts: true` on the workbook OR its datasource), values WILL diverge from live warehouse data on time-dimension axes — extracts typically lag the warehouse by months or years (e.g. extract last refreshed in 2024 vs live Snowflake data through 2027). **Parity divergence in this case is expected, not a converter bug.** Tier the affected charts YELLOW with `error_summary: "extract-vs-live drift"`. `scan-workbook-gaps.rb` flags this as a `manual: Cross-extract drift` gap during Phase 0 so the agent sets expectations up front.

### 6e. Triage divergences (strict mode)

| Symptom | Likely cause |
|---|---|
| Numbers wrong by a constant factor | Aggregation mismatch (Sum vs Avg vs CountDistinct) |
| Wrong dimension values | `[Master/...]` formula references the wrong column |
| Date axis has 24 buckets where Tableau shows 12 | Cross-year month rollup — see `refs/column-gotchas.md` |
| Sigma chart shows extra dim values Tableau never displays | Missed Phase 2.5 filter — apply the filter as `date-range`/`list`/`top-n` |
| Bucket values differ but ratios match | Wrong source column — see Phase 3 "Translate Tableau calc fields here". A `Customer Value Tier` Tableau calc-derived from `Lifetime Revenue` must NOT be replaced by a warehouse `LOYALTY_TIER` column |
| Empty result / column resolves as `error` | `mcp__sigma-mcp-v2__describe` on the element; type `error` means the formula failed to compile (often `IsIn`, unsupported window function, or missing-column ref) |
| Numbers consistently within ±X% across all buckets | Extract drift — switch to `--extract-mode` if the source workbook has `hasExtracts: true` |

#### Trust the CSV, not the dashboard caption

A Tableau dashboard's chart title is hardcoded text on the dashboard, not derived from
the underlying view. When a Tableau author replaces a chart's data without updating the
title, the caption lies. **The view's `get-view-data` CSV is the source of truth** —
build the Sigma chart against the CSV's actual columns and pick a truthful Sigma name,
even if it disagrees with what's printed above the bars in Tableau.

#### Phantom `--metric-["..."]` columns

`mcp__sigma-mcp-v2__query` with `type="workbook"` appends synthetic columns of the form
`--metric-["<colId>"]` whose values look like `Column "X.--metric-[...]" does not exist.`.
Harmless — your explicitly-SELECTed columns return correct values alongside the noise.

### 6f. Visual verification (PNG screenshots) — MANDATORY

> **Phase 6f is MANDATORY. GREEN tier requires `screenshot_path` non-null and Read-back of the Sigma PNG export.** CSV value parity confirms the *data* matches; it does NOT catch visual regressions (log-scale axis silently dropped, missing data labels, stacked-vs-grouped bar mix-up, palette drift, heatmap rendered as bars). Two recent customer-visible failures — including the "Rise of Global Temperatures" heatmap regression — shipped because Phase 6f was treated as optional polish instead of a hard gate. The orchestrator's batch brief (`tableau-assessment/scripts/orchestrate-batch.rb`) now embeds the same requirement for every subagent it spawns; standalone conversions must apply it manually.

After workbook PUT and before declaring GREEN you MUST:
1. POST `/v2/workbooks/{wb}/export` with body `{pageId, format: {type: "png", pixelWidth: 1920, pixelHeight: 1500}}`.
2. Poll `GET /v2/query/{q}/download` until content-type is `image/png` and save to `/tmp/<name>/sigma-render.png`.
3. Read `sigma-render.png` via the Read tool and visually compare against the source dashboard PNG you read in Phase 1d (and any per-sheet PNGs).
4. Record `screenshot_path` in your conversion result. Any visual divergence forces YELLOW (or RED if a tile is missing or unreadable).

> **Visual QA is a mandatory gate — never skip, never declare done on HTTP 200.** A workbook that POSTs cleanly and passes CSV parity can still be visually broken (overlapping tiles, clipped titles, dead zones, floating filters; Sigma's grid has no z-order). After `export-chart-png.rb` renders the pages/elements:
> 1. **Read each PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking, no dead zones, controls placed in-band, no clipped titles, even heights, right chart kind/format). Pair with the Tableau MCP `get-view-image` for source-vs-target.
> 2. Fix any failure in the spec — for multi-page workbooks use `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) — then **re-render and re-read**.
> 3. Loop until the render passes inspection.

```bash
ruby scripts/export-chart-png.rb \
  --workbook <workbookId> \
  --out-dir /tmp/<name>/screenshots/ \
  --width 1400 --height 700
```

Output: one PNG per chart-shaped element, plus a `_manifest.json` mapping element ID → file path, status, and bytes. Pair with the Tableau MCP `get-view-image` (or your own `.twb` view screenshots) for source-vs-target diffs.

The script uses Sigma's `POST /v2/workbooks/{wb}/export` (returns `queryId`) followed by `GET /v2/query/{q}/download` (PNG bytes, ~10–12s typical). All charts export in parallel; the script polls each queryId until ready. Element kinds covered: bar/line/area/combo/scatter/pie/donut, kpi-chart, region-map, point-map, pivot-table, table. Tooltip and other UI-only features (see [[feedback-sigma-trellis-ui-only]], [[feedback-sigma-tooltip-ui-only]]) won't appear in the export because they don't render through the spec API.

When to escalate to a visual check rather than just CSV parity:
- The Tableau source had log-scale axes, custom min/max, or non-trivial number formats (`-66l`)
- The chart had data labels turned on (`-cst`)
- The chart had reference lines/bands/trendlines (`-7ak`, `-2th`)
- The conversion uses dual-axis combo (`-d73`) — verify the right-hand series is line-shaped, not all bars
- Any time you're uncertain whether a feature round-tripped — visual diff is the highest-confidence final check

> **Cross-ref:** the orchestrator batch brief generated by `tableau-assessment/scripts/orchestrate-batch.rb` embeds Phase 6f verbatim (the >>>>>> CRITICAL — VISUAL FIDELITY REQUIREMENT <<<<<< block) and ties GREEN tier to non-null `screenshot_path`. Standalone (non-batch) conversions must apply Phase 6f by hand — there is no auto-runner.

> **Known render-vs-spec drift on log-scale axes.** A `yAxis.format.scale: {type: "log"}` spec persists correctly via PUT/GET, and the interactive Sigma UI renders log-scaled. The Phase 6f PNG export endpoint, however, renders the y-axis linearly (verified 2026-05-24 on OCT v2's Monthly Trend export). This is a render-side limitation of the export endpoint, not a converter regression — confirm log behavior in the live workbook before downgrading parity. When the source Tableau chart had a log axis and the Sigma PNG shows linear, note YELLOW with `error_summary: "log-axis export-renders-linear"` and link the live workbook URL; do NOT re-emit the chart spec.

---

### 6 (optional) — Control flip test

When the workbook has controls (or you just repaired/hand-wired any), get
runtime evidence that they actually filter — the lints above are static:

```bash
ruby scripts/probe-controls.rb --workbook-id <wb> --check-out-of-closure
```

Per control it exports one in-closure element CSV with and without
`parameters:{<controlId>: <first non-default value>}` (must differ) and one
out-of-closure element (must NOT differ). Optional Phase-6 step, not the
mandatory inner loop — the mandatory static check is `assert-phase6-ran.rb`
gate 7 (control lint). Auto-pick needs a list/segmented/switch control; pass
`--value <controlId>=<value>` for date/range controls. See
`refs/control-parity.md` for the lint/probe design and the MCP-vs-export
answer (MCP applies saved control defaults and has NO parameter mechanism;
only the export API's `parameters` map can flip a control programmatically).

## Phase E (opt-in) — Enhance

**OFF by default, everywhere.** Phase E never runs in batch/headless mode
without the explicit `--enhance` flag, and it only ever starts from a
**parity-verified** workbook (all Phase 6 gates green). It is powered by the
shared engine vendored byte-identically into the covered plugins
(`scripts/enhance-scan.rb` + `scripts/enhance-apply.rb` — md5 discipline,
same as `escalate-gap.py`).

```bash
# at --finalize, after gates are green:
ruby scripts/migrate-tableau.rb --workbook "<name>" --finalize \
  --actuals <workdir>/parity-actuals.json \
  --enhance                       # scan only → exit 14 with proposals
# present each candidate to the user (one AskUserQuestion checklist), then:
ruby scripts/migrate-tableau.rb --workbook "<name>" --finalize \
  --actuals <workdir>/parity-actuals.json \
  --enhance --enhance-accept all-low-risk    # or: id1,id2,...
```

The contract (trial-validated, 2026-06-10):

1. **Clone-first.** `enhance-apply.rb` GETs the parity workbook's spec and
   POSTs it as `"<name> — Enhanced"`. The 1:1 parity artifact is **never
   written** (the report records its `updatedAt` before/after as proof).
2. **Scan-then-propose.** `enhance-scan.rb` reads source signals (workdir
   artifacts: `calc-fields.json`, `dashboard-layout.json`, `migrate-state.json`,
   view CSVs) + the built spec + live element exports, and emits
   `enhancements.json` — each candidate `{id, category, evidence, proposed,
   risk, verdict_hint, patch}`. **Nothing applies without acceptance**:
   interactive runs present a per-item checklist (AskUserQuestion); headless
   runs pass `--enhance-accept id1,id2` or `--enhance-accept all-low-risk`.
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
  switch, default = parity grain; (c) **drill switcher** — segmented control +
  `If()` dimension switch where a finer dim exists (medium risk: heuristic
  hierarchy pairing); (d) **map restoration** (PBI signals) — point-map with
  `Switch()` centroid synthesis (medium risk: centroids must be filled into
  the patch before apply).
- **fidelity-polish** — null-bucket labeling (`Coalesce → "No <Dim>"`),
  month/date axis canonicalization (`MakeDate`; medium risk on multi-year
  sources — intentionally un-pools), stale-source freshness note (time-boxed
  wording), title corrections from source captions.

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

## Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| `Expecting UUID at 0.folderId but instead got: undefined` | `folderId` missing from spec | Find with `GET /v2/files?typeFilters=workbook` → `parentId` |
| `Invalid kind: 'kpi' \| 'pie' \| 'donut'` | Used Sigma example library naming | Replace with `kpi-chart` / `pie-chart` / `donut-chart`; the validator catches this |
| Element kind rejected, unknown | Guessed an unsupported kind | `GET /v2/workbooks/<existing-id>/spec` and read `kind` fields of real elements |
| `dependency not found: formula reference 'orders/country region'` | Slash in column `name` field | Rename the column to "Country" before saving the DM spec |
| All columns on a table fail together | One bad formula poisons the element | Find the specific bad ref in the error message; fix only that column |
| `jq: parse error: Invalid numeric literal` | Sigma spec endpoints return YAML | Use `post-and-readback.rb` (it parses YAML); never pipe spec responses to `jq` |
| Validator flags `[X/col]` as unknown prefix on a workbook spec | `--dm-context` not passed | Re-run with `--dm-context /tmp/<name>/dm-ids.json` |
| `401` on `get-view-data` in parallel batch | VizQL session contention — batches of 5+ trigger this | Cap batches at 4. Retry that view solo after 1-2s (PAT-mode `tableau-discover.rb` does this automatically); if still 401, skip — view is inaccessible |
| `401` on `get-view-image` | Always solo, never parallel with other view calls | Retry the image solo, no concurrent requests |
| `429` on Tableau view image | Rate limited | Wait and retry |
| Column fetch returns empty list | Response key is `entries`, not `columns` | Use `discover-warehouse-columns.rb` (handles this) |
| PUT returns `invalid_request` with no field named | Read-only metadata fields included in PUT body | Use `put-layout.rb` (strips them) |
| PUT returns `Invalid 1: schemaVersion, got undefined` | `schemaVersion` stripped from PUT body | Keep `schemaVersion`; the script preserves it |
| Layout PUT rejected, some elements not visible | `elementId=""` in layout XML | Script aborts on this; check the per-workbook layout config for nil IDs and guard with `.compact` |
| Layout has elements stacked vertically | No layout XML provided, or wrong IDs | Read IDs from `wb-ids.json` (Phase 5c readback), not your spec |
| KPI names invisible / truncated inside container | Inner `gridRow` smaller than container's outer span — `gridTemplateRows="auto"` does NOT expand | Set inner KPI `gridRow` end = container outer end |
| Empty containers visible on page | Container elements in spec but layout XML uses `<LayoutElement>` not `<GridContainer>` for them | Use `gc(...)` helper, not `le(...)`, for elements that wrap children |
| Wrong endpoint — workbook created instead of data model | Used `--type workbook` instead of `--type datamodel` | Delete the workbook; re-POST with the right `--type` |
| Bar chart renders vertical but Tableau shows horizontal | Orientation is UI-only — `"orientation": "horizontal"` silently dropped | Set post-publish: chart editor → Properties → Chart type → Horizontal |
| Sigma chart shows dim values Tableau's view never had | Missed Phase 2.5 filter | Diff CSV signals vs warehouse; add the filter as control/element-level |
| Axis label rotation / dashboard title alignment | UI-only fields | Set in element editor post-publish |
| `mcp__sigma-mcp-v2__query` returns "Table X not found" | Workbook queries don't resolve element names as table refs | Use `type: "connection"` with raw inodeId for unfiltered warehouse queries |
| `Unresolved column: <name>` on workbook/datamodel query | These surfaces expose **column IDs**, not display names | `describe` the element first; use the quoted IDs from the DDL |
| `Duplicate id: 'ctl-xxx'` on workbook POST | A control element's `id` matches its `controlId` (same namespace) | Use distinct values: `id: "el-ctl-region"`, `controlId: "ctl-region"` |
| Integer date key column renders as number axis | `ORDER_DATE_KEY` stored as YYYYMMDD integer | Cast in workbook column: `Date(Left(Text([Master/ORDER_DATE_KEY]), 4) & "-" & Mid(..., 5, 2) & "-" & Right(..., 2))`. `DateParse()` and `ToText()` do not exist in Sigma. |
| Sigma line chart shows 24 month-year buckets where Tableau shows 12 month names | Tableau MONTH part collapses across years; Sigma `DateTrunc("month", ...)` preserves year | See `refs/column-gotchas.md` "Cross-year month rollup" |
| Parity DIVERGE: bucket values differ but ratios match | Wrong source column for a Tableau calc | Calc-derived buckets must be re-derived from the same source the Tableau calc used (see `calc-fields.json` from Phase 1e), not from a same-named warehouse column |
| Calc-extracted formula uses `IIF`/`COUNTD`/LOD | Tableau syntax that's not 1:1 with Sigma | `IIF(c,t,e)` → `If(c,t,e)`; `COUNTD(x)` → `CountDistinct(x)`; LOD expressions need a per-case Sigma equivalent (window, Lookup, or pre-aggregation) |
| Ruby heredoc inside `bash -c '...'` fails with backslash errors | Bash's single-quoted block reaches into the heredoc | Write Ruby to a file with the `Write` tool and run `ruby /tmp/script.rb` |


## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_tableau_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for Tableau:** calculated fields using `USERNAME()`/`ISMEMBEROF('group')`/`USERATTRIBUTE('attr')` (translated to `CurrentUserEmail()` / `CurrentUserInTeam("group")` / `CurrentUserAttributeText("attr")`). Cross-element (dim-attribute) RLS is reported with a warning to apply on the owning element/derived view.

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

