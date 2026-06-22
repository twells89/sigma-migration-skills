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

Convert a **Sisense** data model + dashboards into a Sigma **data model** +
**workbook**. Pull the model schema export and the widget definitions over REST,
translate JAQL / widget types / filters, emit the specs, then **verify parity**
against numbers from Sisense's own JAQL engine. Translate what maps cleanly;
**flag what doesn't** (custom JAQL functions, BloX/plugin widgets, scripted
widgets) — never emit confidently-wrong logic.

> **Status — LIVE-VALIDATED (2026-06-17).** A full end-to-end migration of the
> Sisense *Sample ECommerce* model + dashboard was run and **verified at exact
> data parity**: Sisense ElastiCube → Sisense Live-on-Snowflake → Snowflake
> (`CSA.SISENSE_ECOMMERCE`) → Sigma data model (`de8a93d3`/`fee42fdc`) → Sigma
> workbook (`d9312472`). Total Revenue **$39,759,625.515**, Total Quantity
> **91,206**, and the joined Revenue-by-Category breakdown all match Sisense
> JAQL exactly. The converter (`jaql_expr.py` + `convert.py`) was exercised
> against an 18-widget coverage corpus (every chart type + JAQL formula/level/
> top-N/break-by). Known refinements: pie-chart `color` spec + bar `topN`
> display-limit (values correct; display cap not yet enforced). Still flag —
> never fake — treemap/sunburst (no native Sigma equivalent) and unsupported
> JAQL functions. See `refs/design-notes.md`.

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
- **Sigma API token** — `eval "$(scripts/get-token.sh)"` (uses
  `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET`/`SIGMA_BASE_URL` or
  `~/.sigma-migration/env`).
- **A Sigma connection to the warehouse holding the source data.** Parity only
  means something when Sigma reads the same data Sisense did. For ElastiCube
  (ECCloud) sources this means **landing the data in Snowflake first** and
  pointing both tools at it — see `refs/design-notes.md` ("Snowflake-parity").
- **Python 3** (stdlib only).

## Phase 0 — Assess (optional)
Run the `sisense-assessment` skill for an estate inventory + converter-coverage
scoring before committing to conversions.

**Gap scout (run each time).** `scan_gaps.py <dashboards.json>` measures
converter coverage (AUTO/HINT/MANUAL/UNHANDLED + flagged JAQL) and appends every
gap to a `learned-rules.json` ledger. It is the **flag-never-fake gate**: run it
at convert time and again at the done-gate (`--strict` exits non-zero while any
MANUAL/UNHANDLED/flagged gap is unresolved). For a gap with no clean Sigma
translation, `escalate-gap.py` (opt-in, dry-run by default) drafts a tracking
issue — file it only on `--yes`.

## Phase 1 — Discover  ✅ working
```sh
eval "$(scripts/sisense-auth.sh)"
python3 scripts/discover.py --out ~/sisense-migration        # all cubes + dashboards
python3 scripts/discover.py --out ~/sisense-migration --cube "Sample ECommerce"
```
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

## Phase 3 — Convert dashboards  ✅ live-validated
`convert.py dashboard` → workbook spec: widget `type` → element
(`pivot2`→pivot-table, `indicator`→KPI, `chart/*`→chart, `tablewidget`→table),
panel JAQL → formulas via `jaql_expr.py`, filters → controls.

**Layout comes over too.** Sisense's `layout.columns[]` (vertical strips →
`cells[]` stacked → `subcells[]` side-by-side → `elements[]` by `widgetid`+px
height) is translated into Sigma's top-level `layout` XML (24-col grid,
`<LayoutElement gridColumn gridRow/>`). A real multi-column/subcell layout is
ported **faithfully** — column %widths → proportional grid spans, side-by-side
stays side-by-side. A degenerate single full-width stack (Sisense's default) is
**auto-arranged** into something clean: leading KPIs flow into rows of up to 4
cards, charts go 2-up, and trends/tables/pivots span full width. Controls
(from dashboard filters) are placed as a flat row at the top — **not** a
`<GridContainer>`, which Sigma rejects unless its `elementId` points to a real
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
- **Gap scout** — re-run `scan_gaps.py --strict`; no unresolved MANUAL/UNHANDLED/
  flagged gap may remain unaccounted-for.

## Phase 5 — Repoint + enhance
Wire workbook → DM. Layout is already ported by `convert.py dashboard` (Phase 3)
— review it in Sigma and nudge spans if a chart needs more room; defer deeper
polish (themes, conditional formatting) to `sigma-workbooks`.

## Flag, never fake
Custom JAQL functions, BloX/plugin/scripted widgets, import-time
`modelingTransformations`, and any unmapped viz are surfaced as loud flags in
the conversion report — not silently approximated.
