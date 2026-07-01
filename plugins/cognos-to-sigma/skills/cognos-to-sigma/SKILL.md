---
name: cognos-to-sigma
description: >-
  Migrate IBM Cognos Analytics content to Sigma. Use when the user has a Cognos
  Data Module, Framework Manager package, report (Report Studio / CA Reporting),
  or dashboard (exploration) and wants to recreate it in Sigma. Converts Data
  Module JSON → Sigma data model and report-spec XML → Sigma workbook, translating
  the Cognos expression DSL and flagging constructs with no clean Sigma analog.
  Dashboards (exploration JSON) are hand-authored per refs/dashboard-migration.md
  (tabs → separate Sigma pages). Discovery via the CA REST API.
user-invocable: true
---

# Cognos → Sigma migration

> **Windows / first run — run the environment doctor before anything else:**
> `bash scripts/doctor.sh` (macOS/Linux/Git Bash) or `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1` (Windows).
> It checks Ruby/Python/Node/bash and flags the Python "Store stub" + CRLF with exact fixes. Details: `refs/environment.md`.

## Preflight the workbook spec before POST (mandatory)

Before POSTing any workbook spec, run `ruby scripts/lib/preflight_lint.rb <spec.json>` — it exits 1 with a precise message on the two migration-killer bugs: a `table` with aggregate columns + dimensions but **no `groupings`** (renders raw detail rows), and a malformed `control` (missing `id`/`controlId`/`controlType` or nesting value fields under a `value` object instead of flat, a non-double-nested `source`, or a list control wired to neither `source` nor `filters` — a filters-only list control is valid). Fix every violation first — never POST past it, and **never conclude a feature is "unsupported" from an `Invalid kind` error** (it means the inner fields are wrong). Verified shapes: `sigma-workbooks` `controls.md` / `tables.md`.

## Phase 0a — Choose where to build (ask first when no destination given)

Don't silently land the migrated data model + workbook in My Documents.
If the user didn't supply a destination (no `--folder <id>`), ASK before building:

1. `node scripts/pick-destination.mjs list` → `{ workspaces, folders (editable, with parentName), myDocuments }`
2. Let the user pick ONE: a **workspace** (its `id` lands content in the workspace root),
   an existing **folder**, **My Documents** (when non-null — null for service tokens), or
   **create a new folder**: `node scripts/pick-destination.mjs create --name "<name>" [--parent <workspace-or-folder-id>]`
3. Pass the chosen id as `--folder <id>`. `folderId` accepts a workspace id or a folder id.

If a destination is already supplied, honor it silently — don't ask.

Convert a Cognos **Data Module** into a Sigma **data model**, then convert the Cognos
**report** that sits on it into a matching Sigma **workbook**. Translate what maps
cleanly; **flag what doesn't** (runtime macros, running-totals, localization) instead
of emitting wrong logic.

> Read `refs/` before relying on shapes: `design-notes.md` (translation surface + scope),
> `format-shapes.md` (the real CA Data-Module JSON + report-spec XML structures),
> `expression-dsl.md` (the Cognos-expression → Sigma-formula mapping table),
> `dashboard-migration.md` (Cognos **dashboards** / exploration JSON → Sigma: tabs→pages,
> the Akamai bridge, the dataset-query data path, all-SQL DM pattern — the converter does
> NOT do dashboards).
> For the canonical Sigma data-model + workbook spec shapes, defer to the companion
> `sigma-data-models` / `sigma-workbooks` skills.

---

## One command (orchestrated path)

```bash
node scripts/migrate-cognos.mjs \
  --module <module.json> --report <report.xml> \
  --connection <SIGMA_CONNECTION_ID> \
  [--folder <SIGMA_FOLDER_ID>] \
  [--database CSA --schema TJ] [--name '<prefix>'] \
  [--reuse-dm [ID]] [--expected expected.json] [--yes]
```

`--folder` is optional: when omitted, the DM + workbook land in **your My
Documents** (resolved automatically via `GET /v2/whoami`). To target a shared
folder, look its id up first — `GET /v2/files?typeFilters=folder&limit=500`
(match on `name`/`path`) — and pass `--folder <id>`. **The converter is zero-config:**
a self-contained bundle ships in the skill at `converter/cli.mjs` and runs via plain
`node` — no `npm install`, no `tsx`, no network, no MCP (needs only Node ≥ 18). Devs
editing the TS source can rebuild it with `tools/vendor-converters.sh`; if the bundle
is ever missing the orchestrator falls back to `tsx cli.ts` (one `npm install`).

Chains every phase below in one process: module convert → DM-reuse scan
(reuse-first: auto-reuses an existing DM covering all the report's source
tables; `--reuse-dm` pins one, `--skip-reuse-scan` forces build-new) → DM
post-and-readback (hard gate) → report convert `--dm` → remap → workbook
post-and-readback (hard gate) → apply-layout (readback-verified) → parity.
Inputs are the exported module JSON + report XML (Phase 0 / `cognos-discover.sh`
gets them from a live CA). `--name` prefixes both the DM and workbook names.

Parity is two-pass when `--expected` isn't supplied up front: pass 1 auto-exports
every element to CSV via the Sigma REST export API → `<workdir>/sigma-actuals.json`
(keys `"<Element>/<Column>" = sum`, `"<Element>/rows" = count`), prints the
`assert-parity --plan` mcp-v2 query list, then exits 10 with resume instructions.
When two elements share a display name (a report can render the same query twice,
e.g. two "Sheet 1 — qMain" tables), their parity keys are disambiguated with an
elementId suffix — `"<Element> [<elementId>]/<Column>"` — so BOTH verify; copy
the exact keys from `sigma-actuals.json` into `expected.json`.
Build `expected.json` from the **Cognos** report's numbers (same keys, subset ok)
and resume:

```bash
node scripts/migrate-cognos.mjs --resume --out <workdir> --expected expected.json
```

Exit codes: `0` = PARITY GREEN (`assert-parity --check` passed — the only green
exit); `10` = stopped for human input (OPEN QUESTIONS or expected values needed;
state saved); `3` = built but parity RED; anything else = a gate failed. A
freshness banner prints before any side-by-side: Sigma queries the LIVE
warehouse while `expected.json` is a Cognos snapshot — re-capture before calling
drift a bug.

**Still manual by design (the orchestrator stops and tells you):** the expected
parity numbers (they must come from the Cognos report — never invented),
flagged-expression rework (gap-scout), and RLS porting (`security.json` →
`apply_sigma_rls.py`, see "Security" — detected rules are surfaced at the
checkpoint, never silently ported or dropped).

---

## Prerequisites

- **Cognos Analytics 11.1+** REST access (on-prem or CA on Cloud). Base path is
  `<host>/bi/v1` (NOT `/api/v1`). Auth = a logged-in session: a **session cookie** +
  the **`X-XSRF-Token`** header. On IBMid-SSO trials you can't log in headlessly —
  grab a live session from the browser (DevTools → Network → any `coreBundle.js`-initiated
  `bi/v1/...` XHR → **Copy as cURL**) and capture it with `scripts/get-cognos-session.sh`
  (paste the **whole** Cookie header — incl. the Akamai `_abck`/`bm_sz`/`bm_sv`/`ak_bmsc`
  cookies, or the WAF returns 441). CAoC sessions are short-lived: an `HTTP 441` means
  re-login + re-copy. The **durable** path for a real engagement is a CA API key/service
  credential where the tenant allows it — prefer it over session replay.
- **Sigma** API token (via the `sigma-api` skill) to POST the data model + workbook.
- **Node** for the converter (`converter/`: `npm install` once).

---

## Phase 0b — Discover (CA REST)

**Work in batch windows.** CAoC sessions die in MINUTES — never walk an estate one
object per agent turn (each re-auth costs the human a browser round-trip). The moment
you have a hot session, pull EVERYTHING you might need in one burst with
`cognos-batch-fetch.sh`, then work offline from its disk cache:

```bash
export COGNOS_BASE="https://<host>/bi/v1"
export COGNOS_COOKIE="<cookie string>"   export COGNOS_XSRF="<x-xsrf-token>"

# THE BATCH WINDOW — walk the tree + fetch ALL module/report specs, 4-wide
# (hard cap — Akamai WAF; modest bursts only), into a resumable disk cache
# (default ~/.cognos/batch-cache, override with --out / $COGNOS_CACHE_DIR):
scripts/cognos-batch-fetch.sh batch [--root <folderId>]
# Session died mid-run? It exits 4 with "SESSION DIED — N of M specs fetched";
# re-auth (re-copy a HOT cookie) and re-run the SAME command — it RESUMES from
# the manifest + cache (already-fetched specs, keyed id+modificationTime, are
# never re-fetched). Exit 0 = the whole estate is cached.

# Single-artifact runs go through the SAME cache — unchanged modificationTime
# = cache HIT, ONE metadata request, no spec re-fetch:
scripts/cognos-batch-fetch.sh one module <moduleId> > m.json
scripts/cognos-batch-fetch.sh one report <reportId> > r.xml
```

`cognos-discover.sh` (`list`/`module`/`report`) remains for ad-hoc pokes at a live
session, but prefer the batch + cache path for anything beyond a couple of objects.
And keep pushing for the **durable path**: a CA **API key / service credential**
(where the tenant allows it) removes the session-death problem entirely — batch
windows are the workaround for session-replay auth, not a substitute for asking.

- Samples folder, modules, and reports are discovered by walking `GET /objects/{id}/items`.
- **Data Module spec**: `GET /bi/v1/metadata/modules/{id}` (NOT `/modules/{id}`, which is empty).
- **Report spec**: `GET /bi/v1/objects/{id}?fields=specification` → the `specification` string is the report XML.
- **Dashboard spec**: `GET /bi/v1/objects/{id}?fields=specification` → the `specification` string is **exploration JSON** (not XML). This is a different artifact the converter does NOT handle — hand-author per **`refs/dashboard-migration.md`**. ⚠️ A Cognos dashboard's **tabs (`spec.layout.items[]`) must become separate Sigma pages** — never flatten all widgets onto one page.
- **Akamai/CAF wall**: plain `curl` of `/bi/v1` can return **441/403** (TLS fingerprinting) even with a good cookie/API key. Use the headed-Chrome Puppeteer bridge in `refs/dashboard-migration.md` for dashboard pulls + the dataset-query data path.
- Prefer **warehouse-backed** modules (built on a Data server connection) over file-backed
  ones — they carry complete schemas. File-backed modules (uploaded `.xlsx`) are a
  *land-in-warehouse-first* case (see Verify/parity).

## Phase 1 — Convert the Data Module → Sigma data model

```bash
# zero-config: the self-contained bundle runs via plain node (no npm install, no tsx)
node converter/cli.mjs path/to/module.json --connection <SIGMA_CONN> --database <DB> --schema <SCHEMA>
# (dev fallback, only if editing the TS source: cd converter && npm install && node --import tsx/esm cli.ts …)
```
Emits the Sigma data-model JSON on stdout; stats + warnings on stderr. Read the
warnings aloud to the user — they are the parts that need manual authoring
(running-totals, cross-element metrics, FIXED-LOD-style calcs, localization).

## Phase 1.5 — Reuse an existing DM? (avoid sprawl — mirrors tableau Phase 1.5 / powerbi Phase 3.5)

Before POSTing a NEW data model in Phase 2, check whether an existing Sigma DM already
covers the same warehouse tables (don't add a 4th near-identical DM for the same module):

```bash
python3 scripts/cognos-dm-signature.py --dm-spec dm.json --out dm-signature.json
eval "$(scripts/get-token.sh)"
ruby scripts/find-or-pick-dm.rb --workbook-signature dm-signature.json \
  --out dm-match.json --auto-pick           # exit 0 = candidate ≥ min-score
```

`cognos-dm-signature.py` derives `{warehouse_tables, referenced_columns, measures}` from
the Phase-1 converter output (`dm.json` — the Sigma DM JSON, BEFORE it is POSTed). Decision:
- **Score ≥ 0.6** → **ASK the user** reuse-vs-new: surface the candidate name, matched cols
  (N/M), and the inherited-extras warning from `dm-match.json`. If they reuse, run a
  **shape preflight** first — read the candidate DM's spec back and confirm every column
  the report references resolves on the element you'll wire to (no `type=error` columns;
  fact vs separate-dim location) — then **skip Phase 2** and run Phase 3 against the
  matched `recommended_dm_id` (remap to ITS element ids/names in `remap-wb-to-dm-ids.mjs`).
  With `--auto-pick` a clear winner (no tie within 0.05) skips the prompt — still WARN
  about inherited columns/RLS/metrics.
- **Score < 0.6** → POST new (Phase 2) and TELL the user no reusable DM was found.

## Phase 2 — POST the data model + read back ids (hard gate)

```bash
eval "$(scripts/get-token.sh)"                 # Sigma SIGMA_BASE_URL + SIGMA_API_TOKEN
node scripts/post-and-readback.mjs --type datamodel --spec dm.json \
  --folder <folderId> --out dm-map.json
```
POSTs to `/v2/dataModels/spec`, reads the spec back, and **fails on any `type=error`
column** (a spec can POST 200 yet have formulas that don't resolve at query time — the
readback scan is what catches it; it checks every element incl. the derived view).
`dm-map.json` carries the real `dataModelId` + element ids (Sigma reassigns them on POST).
Do not proceed past a non-zero exit.

## Phase 3 — Convert the report → Sigma workbook, wired to the DM

```bash
node --import tsx/esm cli.ts ../path/to/report.xml --dm <dataModelId> > wb.json
node scripts/remap-wb-to-dm-ids.mjs --wb wb.json --dm-id <dataModelId> --out wb.remapped.json
node scripts/post-and-readback.mjs --type workbook --spec wb.remapped.json --folder <folderId>
node scripts/apply-layout.mjs --workbook <workbookId>          # clean dashboard grid
```
Each Cognos **list/crosstab/chart/map** becomes the matching Sigma element sourced from
the migrated DM element. The converter emits each element's `source.elementId` as the
query **subject name** (a placeholder) — `remap-wb-to-dm-ids.mjs` rewrites those to the
real ids from Phase 2's readback (matched by element name). Then post-and-readback POSTs
the workbook and re-runs the error-column gate. **`apply-layout.mjs` then gives the page a
clean 24-col grid** (controls on top, content stacked full-width with per-kind heights) —
Sigma auto-arrange otherwise squishes every element to the same height. It writes the
top-level `spec.layout` XML (matched to readback ids) and confirms it survives readback.
**It then runs the shared layout-quality lint as a gate** (`scripts/lib/layout_lint.rb`,
vendored byte-identical; cognos shells out to ruby) on the final readback spec — flags
raw-id element display names, controls orphaned outside containers, and generic Sigma
auto-page titles (e.g. a `"Page1"` header) — exit 4 on violations; `--skip-layout-lint`
bypasses.

## Phase 4 — Verify parity (hard gate — the real proof)

```bash
node scripts/assert-parity.mjs --plan --type workbook --id <workbookId>   # emits per-element SQL
# run each via mcp-v2 query (or the Sigma query API), save totals to actual.json
node scripts/assert-parity.mjs --check --actual actual.json --expected cognos.json --tol 0.01
```
A migration is **GREEN only when** (a) `assert-parity --check` passes AND (b) the workbook
came back with a clean layout (`apply-layout.mjs` reported `layoutOnReadback: true`) — never
on a 200 POST alone. Layout cleanliness is part of parity: matching numbers on a squished,
auto-stacked dashboard isn't a faithful migration.
`cognos.json` = the numbers from the Cognos report (or the source warehouse). For real
parity, land the Cognos source DB in the warehouse Sigma reads (the GO samples are the
canonical IBM `GOSALES`/`GOSALESDW` DBs — published, loadable), then confirm the Cognos
report's numbers match the migrated Sigma workbook to the cent.

## Visual QA (mandatory gate — never skip)
A workbook that POSTs 200 and passes parity ($-total / row-count) can still be visually broken — **overlapping tiles, clipped titles, dead zones, filters over charts.** Sigma's grid has no z-order; the shared layout lib de-overlaps bands, but this visual gate is the safety net (especially for crosstab→pivot sizing and map title/legend overlap).

1. Render every page to PNG (token first: `eval "$(scripts/get-token.sh)"`):
   `python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out /tmp/<page>.png --w 1600`
2. **Read each PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking, no dead zones, controls in-band, no clipped titles, even heights, right chart kind/format; short map titles).
3. Fix any failure in the spec — for multi-page workbooks use `sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (pull → edit → push) — then **re-render and re-read**.
4. Declare the migration done on a **clean render**, not on HTTP 200.

---

## What converts, what's flagged (never faked)

**Converted and live-validated:**
- **Runtime macros** (`#…# prompt(…,'token',…)` — dynamic column building, e.g. a "swap
  measure" picker) → a Sigma **`segmented` control** (values + default recovered from the
  report's `<selectValue>` options and `customControl` button configs) + a
  `Switch([promptId], …)` **wired by `controlId`** (Sigma resolves control refs by
  controlId, not display name). Both macro shapes convert: token-swap with a default
  column AND string-concat column-ref building (`'[…CY_' + prompt('pQuarter','token') + '_Revenue]'`).
- **Singletons → Sigma kpi-charts** (`value: {columnId}`, number format from the Cognos
  `dataFormat`; sibling dataItem refs materialize as supporting columns). Conditional
  up/down icon styling is NOT portable — the value is preserved and a warning names it.
- **Detail filters → element filters**: `[Col] = literal` / `[Col] in (…)` → a `list`
  filter; `[Col] = ?prompt?` → segmented control + hidden boolean match column +
  `values:[true]` filter. Filter columns are added hidden when the layout didn't show them.
- **Auto-aggregated lists → grouped tables** (`groupings: groupBy dims / calculations
  measures`); footer `Total(...)` columns are skipped with a warning (the group already
  aggregates — re-add via Sigma totals).
- **Scaled currency** (`$###.#M`-style patterns) → the nearest Sigma d3 format (SI-suffix
  `$,.3s`); percent formats → `,.N%`. **Numeric dims on a category axis** (e.g. Year) are
  Text-cast so they bind categorically, and slot `dsSort` becomes `xAxis.sort`.
- **Crosstabs → Sigma pivot-tables** (rows/columns edges → rowsBy/columnsBy, measure → values),
  **charts (RAVE2 `<vizControl>`) → Sigma chart elements** (bar/column/line/area/pie/donut/
  combo/scatter via the slot model — see `refs/format-shapes.md`) and **maps (`tiledmap`) →
  Sigma region-map / point-map**.

**Flagged with a warning (and a readable placeholder), never faked:** macros whose prompt
value set isn't recoverable from the report, **running-total / moving-* / rank / lag / lead**
(window funcs with no clean single-column analog), **GetResourceString** (localization),
composite/non-equi **joins**, **summary filters** (post-aggregation), table **sort order**
(not part of the workbook spec — apply in the UI), and Cognos viz types with no native Sigma
element (network, word-cloud, packed-bubble, treemap → flagged table). Drill-through→actions
and Framework Manager `.cpf` remain roadmap.

## Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter only **detects and reports** security in `result.security[]` (the CLI writes it to `security.json` and prints a loud `SECURITY:` line); it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for Cognos:** Data-Module **security filters** (`securityFilter` entries — top-level or per-query-subject — holding a filter expression + the CAM groups/roles they apply to). Detection is best-effort across the shape variants; **also check manually**: in the Cognos UI a data module's security filters live under the query subject's *Security filters* tab (`Properties → Security`), and Framework Manager packages carry object/data security in the `.cpf` (not parsed — inventory those by hand). Report-level security (CAM object policies on the report itself) maps to Sigma document permissions, not RLS.

**Flow (only runs when security was detected or found manually — zero overhead otherwise):**
1. **Convert + post** the data model as usual. Capture the `dataModelId` and `security.json` (write entries found manually in the same shape: `[{ "type": "row-filter", "name": …, "expression": …, "groups": […] }]`).
2. **Gate (opt-in/out, default _Port_).** Show a plain-English summary of each detected rule + recommended Sigma mapping, then ask: **Port** (recommended) / **Customize** (review per-rule attribute/team mapping + CAM-group-to-email reconciliation) / **Skip** (migrated model shows ALL rows to everyone). Reuse-first: existing Sigma user attributes/teams are matched before creating new ones.
3. **Provision + apply** with the shared engine:
   ```bash
   eval "$(scripts/get-token.sh)"
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId>            # plan only (default)
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId> --provision --apply
   ```
   `--provision` creates missing user attributes / teams; `--apply` PATCHes the boolean RLS calc column + fail-closed `filters` entry and the `columnSecurities` (CLS) onto the matching element.
4. **Assign membership.** Assign per-user attribute values / team membership from the Cognos CAM group/role membership (the rule's `groups` name them; the values come from the customer's user mapping — CAM ids are usually not emails, reconcile them).

**Skip is loud:** opting out leaves the migrated model with NO RLS — all rows visible to everyone. Confirm before skipping.

## Gap scout — close a flagged expression

For a flagged expression you want to actually resolve (a runtime macro, running-total /
rank / lag-lead, `GetResourceString`, a nested CASE, an unmapped function), spawn the
**gap-scout subagent** (`scripts/gap-scout.md`): it proposes a Sigma formula, validates it
against the customer's live Sigma via `scripts/scout-validate-and-persist.mjs`, and on
success persists the rule to `~/.cognos-to-sigma/learned-rules.json` — which the converter
CLI auto-applies *before* the built-in translator on the next run. If no formula validates,
it returns an opt-in `scripts/escalate-gap.py` command to file a tracking issue (ask first).

---

## Telemetry (after the final gate passes)

**Tell the user this in the conversation before running anything:**

> "Migration complete. Before I wrap up, I'd like to send an anonymous usage ping so we can track which migration skills are being used. It records: tool name, your Sigma region, an anonymized org fingerprint (a hash of your client ID — not the credential itself), migration duration, and success. No workbook names, SQL, column names, or any customer data is included. See [TELEMETRY.md](https://github.com/twells89/sigma-migration-telemetry/blob/main/TELEMETRY.md) for the exact payload. Just say 'skip' if you'd prefer not to send it."

If the user does not object, run:

```bash
python3 scripts/report-telemetry.py --tool cognos-to-sigma --duration <elapsed_seconds> --workdir <run-dir> [--mode live|file|both]
# on failure:        python3 scripts/report-telemetry.py --tool cognos-to-sigma --duration <elapsed_seconds> --workdir <run-dir> --failed
# if the user declines: python3 scripts/report-telemetry.py --tool cognos-to-sigma --workdir <run-dir> --declined
# --workdir writes telemetry-sent.json, the marker the GREEN telemetry gate (assert-telemetry-ran.rb) requires.
```

**Then, before declaring the migration done, run the telemetry gate** (MANDATORY — proves the
consent decision above was actually made, not skipped):

```bash
ruby scripts/assert-telemetry-ran.rb --workdir <run-dir>
# exit 0 = decision recorded (sent or declined); exit 12 = you skipped the ping — go back and ask.
# Escape hatch for unattended runs that genuinely cannot prompt: --skip-telemetry-gate "<reason>".
```
