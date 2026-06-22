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
| C6 | **Build workbook** | Report/dashboard → Sigma workbook spec wired to the DM ids |
| C7 | **Layout** | Apply the grid layout as the LAST write (stacked ≠ done; bare spec PUT wipes layout) |
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
