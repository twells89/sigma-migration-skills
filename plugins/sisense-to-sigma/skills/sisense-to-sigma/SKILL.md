---
name: sisense-to-sigma
description: >-
  Migrate Sisense to Sigma. Use when the user has a Sisense instance —
  ElastiCube or Live data models and dashboards — and wants to recreate them in
  Sigma. Pulls the source live over the Sisense REST API (data model schema
  export + dashboards/widgets), converts the model to a Sigma data model and the
  dashboards to a Sigma workbook (pivot2→pivot-table, indicator→KPI,
  chart/*→chart, filters→controls), translates JAQL formulas to Sigma formulas,
  and verifies data parity by running JAQL against Sisense and comparing to the
  Sigma query. For a full migration it lands the source data in Snowflake so
  both tools read the same warehouse. Translates what maps cleanly and flags
  what doesn't (custom JAQL, BloX/plugin widgets, scripted dashboards) instead
  of emitting wrong logic.
user-invocable: true
---

# Sisense → Sigma migration

> **Windows / first run — run the environment doctor before anything else:**
> `bash scripts/doctor.sh` (macOS/Linux/Git Bash) or `powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1` (Windows).
> It checks Ruby/Python/Node/bash and flags the Python "Store stub" + CRLF with exact fixes. Details: `refs/environment.md`.

Convert a **Sisense** data model + dashboards into a Sigma **data model** +
**workbook**. Pull the model schema export and the widget definitions over REST,
translate JAQL / widget types / filters, emit the specs, then **verify parity**
against numbers from Sisense's own JAQL engine. Translate what maps cleanly;
**flag what doesn't** (custom JAQL functions, BloX/plugin widgets, scripted
widgets) — never emit confidently-wrong logic.

> **Status — LIVE-VALIDATED (2026-06-17).** A full end-to-end migration of the
> Sisense *Sample ECommerce* model + dashboard was run and **verified at exact
> data parity**: Sisense ElastiCube → Sisense Live-on-Snowflake → Snowflake
> (`DEMO_DB.SISENSE_ECOMMERCE`) → Sigma data model (`<dm-id>`s) → Sigma
> workbook (`d9312472`). Total Revenue **$39,759,625.515**, Total Quantity
> **91,206**, and the joined Revenue-by-Category breakdown all match Sisense
> JAQL exactly. The converter (`jaql_expr.py` + `convert.py`) was exercised
> against an 18-widget coverage corpus (every chart type + JAQL formula/level/
> top-N/break-by). Known refinements: pie-chart `color` spec + bar `topN`
> display-limit (values correct; display cap not yet enforced). Still flag —
> never fake — treemap/sunburst (no native Sigma equivalent) and unsupported
> JAQL functions. See `refs/design-notes.md`.

> ## ⛔ THE ONE PATH (do not improvise a workbook)
> Run the phases below **in order** — Discover → Convert model → Convert
> dashboards → **Verify (Phase 4)**. Rules:
> - **NEVER hand-author a DM/workbook JSON and `curl`-POST it, and never lay out
>   empty "placeholder" pages.** Post only the specs `convert.py` produces. If you
>   can't reach Sisense (no host/token), **STOP and tell the user to
>   authenticate** — do not build a shell.
> - **Both verify gates must be GREEN with REAL elements before you're done.**
>   `verify_parity.py` and `verify_layout.py` now **refuse a vacuous pass** — a
>   workbook with zero widgets/checks is RED, not "0/0 GREEN". A migration with
>   nothing to verify is not done.
>
> **READ FIRST — `refs/operating-contract.md`**: the fidelity guardrails (render + value-check EVERY page against the source; never ship empty or silently drop a tile; don't spin — surface blockers).
> **Modeling strategy — `refs/modeling-strategy.md`**: faithful reproduction of the source model is the DEFAULT (parity is the gate); an upstream OBT or Sigma-native materialization is an OPT-IN optimization for hot, join-heavy dashboards, re-verified against the same parity oracle. The converter never auto-flattens.
> Read `refs/` before relying on shapes: `sisense-rest-api.md` (validated
> endpoint map + auth + the access-key-vs-token gotcha), `jaql-mapping.md`
> (JAQL → Sigma formula + what's flagged), `widget-type-mapping.md` (widget →
> Sigma element coverage), `design-notes.md` (architecture, the Snowflake-parity
> requirement, hard problems, the Layout translator), `layout-visual-qa.md` (the
> render-and-inspect gate). For canonical Sigma spec shapes, defer to the
> `sigma-data-models` / `sigma-workbooks` skills.

---

## Prerequisites

- **Sisense access.** Email + password or a bearer API token. Run
  `eval "$(scripts/sisense-auth.sh)"` — reads `SISENSE_BASE_URL` +
  `SISENSE_EMAIL`/`SISENSE_PASSWORD` (or a stored `SISENSE_API_TOKEN`) from the
  env or `~/.sigma-migration/sisense.env`. **Use a bearer token, not an
  access-key public key** (that's for SSO/embed — see `refs/sisense-rest-api.md`).
- **Sigma authentication** — set `SIGMA_BASE_URL`, then preferably run
  `eval "$(bash scripts/browser-login.sh)"` once from an interactive terminal.
  The co-located `scripts/lib/sigma_rest.py` reuses a current bearer or the
  keychain refresh session; `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` are the
  unattended fallback. Known-old tokens refresh proactively, and live requests
  refresh and retry once on HTTP 401. See `refs/environment.md`.
- **A Sigma connection to the warehouse holding the source data.** Parity only
  means something when Sigma reads the same data Sisense did. For ElastiCube
  (ECCloud) sources this means **landing the data in Snowflake first** and
  pointing both tools at it — see `refs/design-notes.md` ("Snowflake-parity").
- **Python 3** (stdlib only).

## Converter architecture (read if you know the other migration skills)

Unlike the **Group-A** converters (tableau, powerbi, qlik, quicksight, looker,
thoughtspot, cognos) — which share the vendored `sigma-data-model-mcp` engine
(`converter/*.mjs`, with the hosted `convert_*` MCP tool as a fallback) — this
skill uses a **self-contained Python converter that ships in `scripts/`**
(`convert.py` + `jaql_expr.py`). It runs locally via `python3`; there is **no
vendored `.mjs` bundle, no `convert_sisense_to_sigma` MCP tool, and no
`--converter` / `*_MCP_DIR` override** — those concepts do not apply here. Nothing
about the model conversion leaves your machine.

`migrate-sisense.py` is the one-command wrapper for these phases. Use it for a
full migration; the individual scripts remain intervention/resume tools:

```bash
python3 scripts/migrate-sisense.py --cube "Sample ECommerce" \
  --connection-id <sigma-connection-id> --database <DB> --schema <SCHEMA> \
  --folder-id <sigma-folder-id> --workdir /tmp/sisense-run
# Existing REST export / offline fixture:
python3 scripts/migrate-sisense.py --from-discovery <dir> \
  --connection-id <id> --database <DB> --schema <SCHEMA> \
  --folder-id <id> --workdir /tmp/sisense-run [--dry-run]
```

It retains every phase artifact, requires explicit RLS and visual-waiver
decisions, and declares completion only after strict JAQL parity, readback,
render health, shared hard gates, and the census-backed migration report are
GREEN. Exit 10 is an unresolved RLS decision; exit 2 is a failed migration.

### Core scripts

| Script | Role |
|---|---|
| `migrate-sisense.py` | One-command discovery → conversion → POST/readback → layout/parity/render → security/accounting/report/shared-gate orchestration. |
| `discover.py` | Pull model and dashboard source artifacts. |
| `scan_gaps.py` | Human coverage report plus deterministic structured object/gap census. |
| `convert.py` | Convert model (`model`) and dashboards (`dashboard`). |
| `post-sisense-spec.py` | Idempotent Sigma DM/workbook POST-or-readback helper; writes authoritative IDs/readbacks and tracks posted workbooks. |
| `build-sisense-parity.py` | Build grounded JAQL/warehouse checks and normalize `verify_parity.py` output into `parity-final.json`; zero executable checks is RED. |
| `build-sisense-accounting.py` / `build-sisense-control-scope.py` | Reconcile every model/dashboard object and source filter into the census, coverage, control census, and static control-scope contracts. |
| `finalize-sisense-report.py` / `verify-complete.rb` | All-page PNG health + tile-aware similarity, degradation/report freshness, and final all-pass completion verification. |
| `verify_parity.py` | Data-value parity gate. |
| `verify_layout.py` | Structural layout parity gate. |
| `detect_rls.py` / `apply_sigma_rls.py` | Discover and explicitly provision row-level security. |

## Phase 0 — Assess (optional)
Run the `sisense-assessment` skill for an estate inventory + converter-coverage
scoring before committing to conversions.

**Gap scout (run each time).** `scan_gaps.py <dashboards.json> --model
<model.json> --out gap-report.json` measures converter coverage and accounts for
every source model table/column/relation/transformation plus every
dashboard/widget/filter. The deterministic report contains stable object ids,
status, evidence, provenance, summary counts, and unresolved gaps; the existing
human stdout and `learned-rules.json` append ledger remain available. It is the
**flag-never-fake gate**: run it at convert time and again at the shared
done-gate (`--strict` exits non-zero while any MANUAL/UNHANDLED/flagged gap is
unresolved). For a gap with no clean Sigma translation, `escalate-gap.py`
(opt-in, dry-run by default) drafts a tracking issue — file it only on `--yes`.
Durable support boundaries and evidence requirements live in
`refs/open-items.md`.

## Phase 1 — Discover  ✅ working
```sh
eval "$(scripts/sisense-auth.sh)"
python3 scripts/discover.py --out ~/sisense-migration        # all cubes + dashboards
python3 scripts/discover.py --out ~/sisense-migration --cube "Sample ECommerce"
```
> **Windows:** run these with the `py` launcher (`py -3 scripts/…py`), not a bare
> `python3`. A bare `python`/`python3` on Windows often resolves to the Microsoft
> Store *App Execution Alias* stub, which silently does nothing. Disable those
> aliases (Settings → Apps → Advanced app settings → App execution aliases) or use
> `py -3`. Child steps reuse the running interpreter (`sys.executable`).
Writes `~/sisense-migration/discovery/`: `elasticubes.json`,
`model_<title>.json` (full schema export), `dashboards.json` (widgets inlined).

## Phase 1.5 — RLS scan (optional, opt-in)
`detect_rls.py "<cube>"` checks the cube's Sisense **data-security** rules and
maps them to Sigma row-level security. **Zero-overhead + never silent:** with no
rules it prints nothing and exits 0; with rules it prints the recommended
mapping (a per-column **user attribute** + a `CurrentUserAttributeText("<col>")
= [<Col>]` row filter) and, with `--out security.json`, writes a converter-style
`security[]`. Porting is **opt-in** — `apply_sigma_rls.py --from-security
security.json --dm-id <id>` is reuse-first and **plan-only by default**, mutating
only on explicit `--provision`/`--apply` (then assign per-user values via
`POST /v2/user-attributes/{id}/users` — member values are flagged, never faked).
This is the same tool-agnostic apply path every sibling RLS port uses.

## Phase 2 — Convert the model  ✅ live-validated
`convert.py model` → Sigma DM spec from `model_<title>.json`: each
`schema.tables[]` → DM element (plain table → warehouse source; table with
`expression` → Custom-SQL element, SQL verbatim + flagged), `relations[]` → DM
relationships, column `type` codes → Sigma types. Targets the Snowflake
connection holding the landed data. **Reuse-first:** before POSTing, check for an
existing Sigma data model on the same warehouse tables and reuse it rather than
creating DM sprawl.

**POST + read back real ids.** POST the DM spec, then GET
`/v2/dataModels/{id}/spec` and **read back** the server-assigned element + column
ids — the workbook's Master element sources the fact element by its read-back
id, never the client-side one (DM POST reassigns ids; workbook CREATE preserves
them).

**DM metric references (emit-first — leverage the semantic layer, don't duplicate it).**
Sisense has no source-side metrics, so pass `convert.py model … --dashboards dashboards.json`
and the model step **EMITs** a governed metric per JAQL measure (`harvest_metrics` →
`{name, formula:"<Agg>([<Col>])"}`) onto the DM element(s) that carry the columns. Then
`convert.py dashboard … --dm-spec sigma_dm_spec.json` prefers a **`[Metrics/<name>]`**
reference over the inline aggregate when they match by formula equivalence (strip the
`Master` prefix so `Sum([Master/Revenue])` equals a metric's `Sum([Revenue])`) — via the
shared binder `scripts/lib/metric_binding.py`. The reference binds only to the DM's ACTUAL
metrics (from `--dm-spec`), so a workbook never points at an absent metric. SAFE:
`J.Unsupported` measures are skipped; no `--dashboards`/`--dm-spec` → inline, byte-identical.
Verified: `tests/test_metric_reference.py`.

## Phase 3 — Convert dashboards  ✅ live-validated
`convert.py dashboard` → current workbook code-representation request:
outer metadata (`name`) plus a nested `document`. Workbook pages are
**metadata-only**, elements live once in the flat `document.elements[]`
collection, and required `document.layout` is the authoritative page-membership
map. (Data-model specs are intentionally unchanged and retain
`pages[].elements`.) Widget `type` → element
(`pivot2`→pivot-table, `indicator`→KPI, `chart/*`→chart, `tablewidget`→table),
panel JAQL → formulas via `jaql_expr.py`, filters → controls.

Released feature mappings are source-gated: `chart/waterfall` maps to native
`waterfall-chart`; explicit legend visibility/position and literal widget/canvas
backgrounds are retained; and `indicator/gauge` maps to native `progress` only
with a complete explicit min/value/max range. Box plots stay workspace-gated.
Sisense drill/JTD, Tabber, filter-panel chrome, page breaks, and repeaters remain
**loud gaps** until discovery provides a safely authorable equivalent. See
`refs/workbook-code-release-gaps.md` and the executable
`refs/catalogs/workbook-feature.json`.

**Layout comes over too, and is required.** Sisense's `layout.columns[]` (vertical strips →
`cells[]` stacked → `subcells[]` side-by-side → `elements[]` by `widgetid`+px
height) is translated into Sigma's `layout` XML (24-col grid,
`<Element gridColumn gridRow/>`), which lives on the workbook spec's
`document` object (`document.layout` — the workbook body is `document`-wrapped
as of 2026-08-03; DM specs are unaffected and retain their page-nested
elements). Every flat workbook element must occur exactly once in layout, and
every metadata page must have one `<Page>` block; conversion fails closed on
missing, orphan, or duplicate membership. A real multi-column/subcell layout is
ported **faithfully** — column %widths → proportional grid spans, side-by-side
stays side-by-side. A degenerate single full-width stack (Sisense's default) is
**auto-arranged** into something clean: leading KPIs flow into rows of up to 4
cards, charts go 2-up, and trends/tables/pivots span full width. Controls
(from dashboard filters) are placed as a flat row at the top — **not** a
`<Container>`, which Sigma rejects unless its `elementId` points to a real
container element in the spec. Element IDs are preserved on workbook CREATE, so
the layout refs resolve. The `layout` XML is the **last write** in the workbook
spec — emitted after every element is positioned, so it reflects the final
arrangement (no separate post-hoc layout PUT needed; CREATE preserves the ids
the layout references). See `refs/design-notes.md` ("Layout").

## Phase 4 — Verify parity  ✅ live-validated
Two gates, both must be **GREEN** before claiming done:
- **Data** — `verify_parity.py` runs each widget's JAQL (`POST
  /api/datasources/{ds}/jaql`) and compares to the warehouse SQL Sigma compiles
  to (+ a Sigma `query` spot-check). Proves the numbers match.
- **Layout** — `verify_layout.py <dashboards.json> <sigma_workbook_spec.json>`
  proves the arrangement came over: every mapped widget placed exactly once, no
  orphan refs, inside the 24-col grid, no overlaps, reading order preserved,
  side-by-side widgets stay on one row, relative widths preserved. Data parity
  alone does **not** check any of this.
- **Visual QA** — structural-green is not visually-correct. Render each page with
  `sigma-export-png.py` and read it against `refs/layout-visual-qa.md` (compare
  to the Sisense source PNG). Declare done on a clean render, not an HTTP 200.
- **Gap scout** — re-run `scan_gaps.py <dashboards.json> --model <model.json>
  --out gap-report.json --strict`; no unresolved MANUAL/UNHANDLED/flagged gap
  may remain unaccounted-for. Preserve `gap-report.json` and the other phase
  artifacts; the forthcoming one-command wrapper must use the same shared
  hard-gate completion contract rather than a parallel success path.

## Phase 5 — Repoint + enhance
Wire workbook → DM. Layout is already ported by `convert.py dashboard` (Phase 3)
— review it in Sigma and nudge spans if a chart needs more room; defer deeper
polish (themes, conditional formatting) to `sigma-workbooks`.

## Flag, never fake
Custom JAQL functions, BloX/plugin/scripted widgets, import-time
`modelingTransformations`, and any unmapped viz are surfaced as loud flags in
the conversion report — not silently approximated.
