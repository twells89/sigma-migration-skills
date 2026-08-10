# Canonical migration phase schema

Every converter skill in this repo walks the same arc, but each tool's
SKILL.md numbers and names its phases differently (numbering grew organically
per tool and is load-bearing — scripts, gates, and memory notes reference the
local numbers). **Do NOT renumber any skill's phases.** This document is the
cross-skill Rosetta stone: when you need "the parity gate" or "the reuse
check" in an unfamiliar skill, look up its local name here.

## The canonical arc

| # | Canonical step | What it is |
|---|---|---|
| C1 | **Assess** | Inventory/scope the source estate; feature-gap scan; pick targets |
| C2 | **Discover** | Pull the actual source artifacts (model + report/dashboard defs, warehouse columns) |
| C3 | **Reuse-check** | Before creating a DM, look for an existing Sigma DM with the same signature (avoid sprawl) |
| C4 | **Convert** | Source model → Sigma data-model JSON (MCP `convert_*` tool or in-repo converter) |
| C5 | **Post-DM gate** | POST the DM, read back real element/column ids — hard gate before any workbook work |
| C6 | **Build workbook** | Report/dashboard → Sigma workbook spec wired to the DM ids, with every element completely placed in the layout on the create write |
| C7 | **Layout safety** | Preserve the complete layout on every write; make the final write layout-safe and last (stacked ≠ done; any write that omits layout wipes it) |
| C8 | **Parity hard gate** | Source values vs Sigma values (vs warehouse where possible) — mandatory, never skip |
| C9 | **Security / RLS** | Port detected RLS/CLS to Sigma user-attributes + DM filters (detect always; apply opt-in) |
| C10 | **Enhance** | Post-publish polish, UI-only features, optional extras |

## Per-skill mapping

Local phase numbers/names as of 2026-06-10 (verify against the SKILL.md if it
has been edited since).

| Canonical | tableau-to-sigma | powerbi-to-sigma | qlik-to-sigma | quicksight-to-sigma | looker-to-sigma | cognos-to-sigma | thoughtspot-to-sigma |
|---|---|---|---|---|---|---|---|
| C1 Assess | Phase 0a gap-scan + 0a-scout + 0b mode + Phase 0 cost (also tableau-assessment skill) | powerbi-assessment skill | qlik-assessment skill | quicksight-assessment skill | Phase 0 — Assess (also looker-assessment) | cognos-assessment skill | thoughtspot-assessment skill |
| C2 Discover | Phase 1 (datasource) + Phase 2 (warehouse cols) + Phase 2.5 (view filters) | Phase 1 — Connect + Phase 2 — Extract | Phase 1 — Discover (qlik-cli) | Phase 1 — Auth + Phase 2 — Discover | Phase 1 — Discover (1d = RLS scan) | Phase 0 — Discover (CA REST) | Pipeline step 1 — Discover |
| C3 Reuse-check | Phase 1.5 (+1.5b shape preflight) | Phase 3.5 | Phase 2.5 | Phase 3.5 | Phase 2.5 | Phase 1.5 | Step 2.5 |
| C4 Convert | Phase 3 — Build the data model spec | Phase 3 — Convert (MCP) | Phase 2 — Translate | Phase 3 — Convert (MCP gate) | Phase 2 — Convert the LookML model | Phase 1 — Convert the Data Module | Pipeline step 2 — Convert the model |
| C5 Post-DM gate | Phase 4 — POST the data model | Phase 4 — Post the data model | Phase 3 — Build the Sigma DM | Phase 4 — Fixup + POST | Phase 2 (2c POST + readback) | Phase 2 — POST + read back ids (hard gate) | step 2 (POST + readback) + step 3 — Resolve columns |
| C6 Build workbook | Phase 5 — Build the Sigma workbook | Phase 5 — Build the workbook | Phase 4 — Build the workbook | Phase 5 — Build the workbook | Phase 3 — Convert the dashboards | Phase 3 — Convert the report | Pipeline step 4 — Build workbooks |
| C7 Layout | within Phase 5 (5c/5d layout passes) | Phase 5d — Layout | within Phase 4 (build-sigma-workbook.py) | Phase 6 — Layout | within Phase 3 (newspaper layout) | within Phase 3 (apply-layout.mjs) | Pipeline step 5 — Layout (LAST write) |
| C8 Parity hard gate | Phase 6 — Verify (hard-gated by assert-phase6-ran.rb) | Phase 6 — Verify (mandatory) | Phase 5 — Parity (hard gate) | Phase 7 — Parity (hard gate) | Phase 4 — Verify parity (3-way, MANDATORY) | Phase 4 — Verify parity (hard gate) | Pipeline step 6 — Parity |
| C9 Security/RLS | "Security: RLS/CLS" section (unnumbered) | "Security: RLS/CLS" section | "Security: RLS/CLS" section | "Security: RLS/CLS" section | Phase 1d scan + Phase 1.5 RLS decision gate (before building) | "Security: RLS/CLS" section | "Security: RLS/CLS" section |
| C10 Enhance | **Phase E (opt-in)** — `--enhance` on migrate-tableau.rb (shared enhance-scan/apply engine) | **Phase E (opt-in)** — `--enhance` on migrate-powerbi.rb (same shared engine) + Phase 7 Bookmarks | — | — | Phase 5 — Enhance (UI-only features) | — | — |

### microstrategy-to-sigma

MicroStrategy uses "Phase" numbering and is documented here rather than as an
8th table column (it joined after the table was set). Its local mapping:

| Canonical | microstrategy-to-sigma |
|---|---|
| C1 Assess | microstrategy-assessment skill |
| C2 Discover | Phase 0 — Discover + Phase 1 — Extract the bundle |
| C3 Reuse-check | Phase 2.6 — Reuse an existing DM? (mstr-dm-signature.py + find-or-pick-dm.rb) |
| C4 Convert | Phase 2 — Convert → Sigma specs |
| C5 Post-DM gate | Phase 3 — POST + read back ids (hard gate) |
| C6 Build workbook | Phase 4 — Re-emit with real ids, POST |
| C7 Layout | within Phase 4 (`put-layout.rb`, LAST write) |
| C8 Parity hard gate | Phase 5 — Verify parity (hard gate) + Phase 6 finalize |
| C9 Security/RLS | "Security: RLS/CLS" section |
| C10 Enhance | — |

### sisense-to-sigma

Sisense uses "Phase" numbering (it joined after the table was set). Its local
mapping:

| Canonical | sisense-to-sigma |
|---|---|
| C1 Assess | sisense-assessment skill + `scan_gaps.py` (gap scout) |
| C2 Discover | Phase 1 — Discover (`discover.py`) |
| C3 Reuse-check | Phase 2 — reuse an existing DM on the same warehouse tables before POST |
| C4 Convert | Phase 2/3 — Convert model + dashboards → Sigma specs |
| C5 Post-DM gate | Phase 2 — POST + read back real ids |
| C6 Build workbook | Phase 3 — emit workbook with read-back ids, POST |
| C7 Layout | within Phase 3 (`build_layout` → `layout` XML, LAST write) |
| C8 Parity hard gate | Phase 4 — Verify parity (`verify_parity.py` data + `verify_layout.py` layout) |
| C9 Security/RLS | Phase 1.5 — RLS scan (opt-in: `detect_rls.py` + `apply_sigma_rls.py`) |
| C10 Enhance | — (defer to `sigma-workbooks`) |

### gooddata-to-sigma

GoodData Cloud / .CN uses "Phase" numbering (it joined after the table was
set). Its local mapping:

| Canonical | gooddata-to-sigma |
|---|---|
| C1 Assess | Phase 0 — Assess (gooddata-assessment skill) + Phase 1b gap-scout (`scan_gaps.py`, MAQL coverage) |
| C2 Discover | Phase 1 — Discover (`discover.py`, declarative layout export: LDM + analytics model) |
| C3 Reuse-check | Phase 1c — Reuse check (`find-or-pick-dm.rb`) before POSTing a new DM |
| C4 Convert | Phase 2 — Data model (`convert.py`; MAQL metrics → Sigma formulas via `maql.py`) |
| C5 Post-DM gate | Phase 2 — POST `/v2/dataModels/spec` + read back server-assigned ids (hard gate) |
| C6 Build workbook | Phase 3 — Workbook (`build_workbook.py`: insights → charts/KPIs/pivots) |
| C7 Layout | within Phase 3 — apply the dashboard grid layout as the LAST write |
| C8 Parity hard gate | Phase 4 — Parity vs the same warehouse |
| C9 Security/RLS | Phase 6 — RLS (user data filters → Sigma user attributes; detect always, apply opt-in) |
| C10 Enhance | Phase 6 — theme registry + final visual-QA (defer idioms to `sigma-workbooks`) |

Notes:

- **Looker runs the RLS gate early** (before building, C9 ahead of C4) by
  design — porting `access_filter`/`sql_always_where` changes what gets built.
  Every other skill detects during convert and applies after parity.
- **ThoughtSpot uses "Pipeline steps" not "Phases"**; its one numbered phase
  heading is "Step 2.5" (reuse).
- The reuse-check rows all mirror the same convention ("mirrors tableau
  Phase 1.5 / powerbi Phase 3.5") — if you add a new converter skill, keep
  that cross-reference and add a row here.
- Regression-test converter changes against `corpus/` (see corpus/README.md)
  before relying on a live tenant.
- **Phase E (C10) is OPT-IN ONLY and shared.** tableau-to-sigma and
  powerbi-to-sigma vendor a byte-identical engine
  (`scripts/enhance-scan.rb` + `scripts/enhance-apply.rb` — md5 discipline,
  same as escalate-gap.py) triggered exclusively by `--enhance` on their
  one-command orchestrators. It never runs in batch/headless without the
  flag; nothing applies without `--enhance-accept`; it clones the
  parity-verified workbook ("<name> — Enhanced") and never touches the 1:1
  artifact; every applied item is gated by a parity-unchanged spot-check
  that auto-reverts on divergence. Other skills should adopt the same
  vendored engine + flag convention when they grow a Phase E.

### hex-to-sigma

Hex uses "Phase" numbering (it joined after the table was set, and its
discovery step is unique in the family — file-based, not a REST walk; see
its `SKILL.md` for why). Its local mapping:

| Canonical | hex-to-sigma |
|---|---|
| C1 Assess | `hex-assessment` skill (stub) |
| C2 Discover | Phase 1 — Parse the `.hex.yaml` export (`converter/hex_yaml.py`) — no REST walk; Hex's API doesn't expose cell content |
| C3 Reuse-check | Phase 1.5 — `find-or-pick-dm.rb` (vendored unmodified) |
| C4 Convert | Phase 2 — `converter/convert_dm.py` (SQL cells → native-SQL DM element) + `converter/convert_workbook.py` (METRIC/EXPLORE cells → workbook elements, layout baked in) |
| C5 Post-DM gate | Phase 3 — `post-and-readback.rb` (vendored pattern, not source-tool-specific) |
| C6 Build workbook | Phase 4 — `post-and-readback.rb --type workbook` |
| C7 Layout | within Phase 4/5 — layout baked into the workbook spec at convert time (no separate put-layout step; Hex's full `appLayout` is known upfront, unlike Metabase) |
| C8 Parity hard gate | Phase 6 — `assert-phase6-ran.rb` |
| C9 Security/RLS | "Security: RLS/CLS" section — not yet implemented, gap documented |
| C10 Enhance | — |

### domo-to-sigma

Domo uses "Phase" numbering (it joined after the mapping table was set). Its local mapping:

| Canonical | domo-to-sigma |
|---|---|
| C1 Assess | Phase 0 — Assess (domo-assessment skill) + Tier A/B probe (`domo-discover.rb --probe`) |
| C2 Discover | Phase 1 — Discover (`domo-discover.rb`: DataSets, cards, Beast Modes, summary numbers) |
| C3 Reuse-check | Phase 2.5 — Reuse check (`find-or-pick-dm.rb`) before POSTing a new DM |
| C4 Convert | Phase 3 — Data model (`build-dm.rb`; Beast Modes → formulas via `convert-beast-modes.rb` + the shared SQL-formula converter) |
| C5 Post-DM gate | Phase 4 — POST the DM + read back server ids (`post-and-readback.rb`, hard gate) |
| C6 Build workbook | Phase 5 — Workbook (`build-workbook.rb`: cards → charts/KPIs/pivots; Summary Number → KPI) |
| C7 Layout | Phase 5 — apply the dashboard grid layout as the LAST write (`put-layout.rb`) |
| C8 Parity hard gate | Phase 6 — Parity vs the same warehouse (`verify-parity.rb`, hard-gated by `assert-phase6-ran.rb`) |
| C9 Security/RLS | Phase 6 — RLS (Domo PDP policies → Sigma row-level security; detect always, apply opt-in) |
| C10 Enhance | Phase 5e — visual QA + KPI-count parity (defer idioms to `sigma-workbooks`) |

### mode-to-sigma

Mode uses "Phase" numbering (it joined after the mapping table was set). Its
local mapping:

| Canonical | mode-to-sigma |
|---|---|
| C1 Assess | `mode-assessment` skill (scaffolded; not registered in `marketplace.json`/`AGENTS.md` this release — SP1 ships the converter only) |
| C2 Discover | Phase 0 — Discover (`mode-discover.rb`: Queries, Charts, Filters + a live run to sample each Query's output columns) |
| C3 Reuse-check | Phase 1 — Reuse check (`build-dm.rb`'s `mode-signature.json` + `find-or-pick-dm.rb --auto-pick`) |
| C4 Convert | Phase 2 — Build the Data Model (`build-dm.rb`: every Query → one `sql`-kind table element, raw SQL verbatim — no formula translation needed) |
| C5 Post-DM gate | Phase 3 — Post + read back (`post-dm.rb`, hard gate) |
| C6 Build workbook | Phase 4 — Build the workbook + layout (`build-mode-workbook.rb`: hidden Data page + visible Report page) |
| C7 Layout | within Phase 4 — notebook-flow layout baked in as the last write before POST (no separate layout PUT) |
| C8 Parity hard gate | Phase 5 — Parity (`verify-parity.rb`, hard-gated by `assert-phase6-ran.rb`); the separate visual-render sub-gate (gate 8) is honestly waived in v1 (`--skip-visual-gate` — no Mode UI render capability), but the parity comparison itself is never skipped |
| C9 Security/RLS | "Security: RLS/CLS" section — Mode has no row/column-level security on query results; access control is Space/Report visibility only |
| C10 Enhance | — |

### excel-to-sigma

Excel uses "Phase" numbering from its staging repo. Its local mapping:

| Canonical | excel-to-sigma |
|---|---|
| C1 Assess | — (no assessment skill yet; pick the `.xlsx` / fleet dir directly) |
| C2 Discover | Phase 0 — Discover (`xlsx-discover.py`; Phase 0b macros, 0c model map, 0d template fingerprint) |
| C3 Reuse-check | Phase 2 — reuse / extend an existing DM at the same grain before POSTing a new one |
| C4 Convert | Phase 1–2 — seed extract + read/output DM; Phase 3–4 input-table + warehouse-view source-swap |
| C5 Post-DM gate | Phase 2 — POST DM + read back server-assigned ids (`map_dm*`) before workbook build |
| C6 Build workbook | Phase 5 — workbook builders (`build-input-table-wb.py` / `build-forecast-model.py` / `build-research-model.py`) |
| C7 Layout | within Phase 5 — stacked notebook-flow `layout` assembled as the last write inside `workbook_wire.wire_workbook` before POST (released `code_rep` document wrapper) |
| C8 Parity hard gate | Phase 0c/0d simulate-and-freeze + Phase 2/4 section rollups + research `batch-convert.py` AUTO_PARITY; never skipped |
| C9 Security/RLS | "Security: RLS / CLS" — Excel has no native RLS/CLS to port; detect workbook/sheet protection only |
| C10 Enhance | — |
