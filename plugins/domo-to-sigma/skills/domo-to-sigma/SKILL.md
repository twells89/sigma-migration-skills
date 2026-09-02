---
name: domo-to-sigma
description: >-
  Convert a Domo dashboard (pages + cards + DataSets + Beast Modes) into a Sigma
  data model and matching workbook. Use when the user has a Domo instance and
  wants to recreate a dashboard in Sigma. Discovery via Domo's public + private
  APIs, Beast Mode (MySQL-dialect SQL) → Sigma formula translation, a reuse
  check before building a new data model, data model + workbook creation via
  the Sigma REST API, layout generation, Domo PDP → Sigma row-level-security
  detection, and parity verification against the same warehouse — driven by
  `scripts/*.rb`.
user-invocable: true
---

# Domo → Sigma Conversion

> **Status: GOLD — live end-to-end validated (2026-08-10).** The gold acceptance
> run migrated a purpose-built 16-card Domo executive dashboard to a live Sigma
> workbook and passed **28/28 strict value-parity checks (100%) with zero
> exclusions**, a fresh context-free **6/6 visual PASS**, clean live column/layout/
> control lint, and `assert-phase6-ran.rb` exit 0 / GREEN with an empty degradation
> ledger (no scope cuts, waivers, or residuals). The earlier Tier-A validation
> remains part of the evidence base: 48 cards / 24 chart types / 81 Beast Modes,
> plus the purpose-built cards, against a real Domo instance. It answered all
> three former open questions and **disproved several doc-inferred shapes** in
> `refs/connection.md` — card enumeration, the summary-number path, and
> page-layout geometry were all wrong.
> **Read `refs/live-validation-2026-07-30.md` before trusting any private-API
> shape**; where it and `refs/connection.md` disagree, live-validation wins.
> The public OAuth path is documented and stable. Gold proves the converter's
> live baseline; each customer migration must still run its own Phase-6 value,
> visual, layout, and security gates rather than inheriting the fixture's result.
> **Compliance:** before a production run, confirm with the customer's Domo
> account team that programmatic extraction for migration is acceptable — see
> `refs/connection.md` "Compliance note".

**Read ALL of the following before replying or taking any action:**
<!-- mandatory-pre-read -->
- `refs/connection.md` — Domo auth (OAuth public API + developer access token for private API)
- `refs/beast-mode-to-sigma.md` — Beast Mode (MySQL SQL) → Sigma formula mapping
- `refs/card-to-element.md` — **Domo card → Sigma element map. Read before Phase 5.** Rule 0 (Summary Number → KPI, never a table) is the #1 fidelity fix; also covers filtering + no-liberties discipline.
<!-- /mandatory-pre-read -->

Phase-scoped (read at its phase, not upfront): at **Phase 5e**, read
`refs/layout-visual-qa.md` — the visual QA gate — before grading the layout.

General workbook-spec and data-model-spec authoring idioms (grid layout
mechanics, chart/control shapes, DM column/relationship shapes) are deferred to
the **`sigma-workbooks`** and **`sigma-data-models`** skills — this skill covers
only what's Domo-specific: extraction, Beast Mode translation, and the
card→element map.

---

## The one big idea

**Beast Mode is MySQL-dialect SQL.** Domo's calc-field language routes through the
vendored `converter/sql.mjs` (`scripts/convert-beast-modes.rb --convert`,
running locally via `node` — no MCP call, no network) — no bespoke parser
like Power BI's DAX.

> ✅ **UPDATED 2026-07-30 — the historical "NOT nearly free" finding is
> RESOLVED, with a calibrated result, not a swing to "it just works."** A live
> measurement on 81 real Beast Modes originally found 74% translating to
> invalid Sigma: `CASE WHEN` (71% of formulas) wasn't converted to `If()` at
> all, and `COUNT(DISTINCT x)` rendered `DISTINCT` as a column reference. Both
> are fixed upstream (sigma-data-model-mcp PR #115), and a third defect this
> fix surfaced — Domo's real ALL-CAPS backtick-quoted columns coming back
> double-bracketed (`[[Net Revenue]]`) — is also fixed (PR #116). Re-measured
> on the deduplicated **74-distinct-formula** corpus. Both columns below were
> measured with the identical harness and identical `normalize_bm` steps
> (backticks → `[brackets]` AND `WEEKDAY` → `DAYOFWEEK`), so they are
> genuinely comparable:
>
> | metric | before | after |
> |---|---|---|
> | matched a rule | 0 | 37 |
> | leaked `[Distinct]` | 5 | 0 |
> | `And()`/`Or()` call form | 52 | 0 |
> | `Today()()` | 21 | 0 |
> | residual raw `CASE` in output | 54 | 0 |
> | residual untranslated infix | — | 1, honestly reported |
>
> **Accurate framing: 37/74 (50%) now match a converter rule exactly.** The
> rest fall through to the generic expression converter, which no longer
> *corrupts* them (no leaked `[Distinct]`, no `And()`/`Or()` call-form nulls,
> no `Today()()`, no raw `CASE` residue, no double-bracketing) but does not
> *fully translate* every shape either — infix `LIKE` still has no Sigma
> equivalent and is correctly reported as unconverted rather than silently
> shipped. Because `convert-beast-modes.rb` correctly DROPS entries without a
> `sigmaFormula` rather than shipping bad output, a Beast Mode using an
> untranslatable construct still needs the `formula-overrides.json` sidecar —
> that mechanism is unchanged and still the right escape hatch, it is just no
> longer load-bearing for CASE WHEN or COUNT(DISTINCT). One more thing to
> budget for, now FIXED (2026-08-03, bead beads-sigma-nrml):
> `convert-beast-modes.rb` used to rewrite `WEEKDAY(...)` to `DAYOFWEEK(...)`
> "for parity," which was *counterproductive* — `WEEKDAY(...)` converts
> cleanly on its own (Sigma has `Weekday()` by that exact name), but
> `Dayofweek(...)` is **not** a real Sigma function. That rewrite is gone;
> `WEEKDAY(...)` now passes through unchanged. But a second, more serious
> issue surfaced during that fix and is verified against both vendors'
> docs: MySQL `WEEKDAY()` (0=Monday..6=Sunday) and Sigma `Weekday()`
> (1=Sunday..7=Saturday) use genuinely different numbering, so a name-clean
> translation can still be a silent VALUE mismatch. `normalize_bm` now flags
> this with a warning naming the exact override — `Mod(Weekday([col])+5,7)`
> — rather than auto-rewriting; see the note in `scripts/convert-beast-modes.rb`.
> Full evidence and the exact before/after outputs: `refs/live-validation-2026-07-30.md`.

The other work is *extraction* (card defs + Beast Mode text + layout out of Domo)
and *layout/binding* (cards → Sigma elements on a 24-col grid; note Domo's own card
grid is only 6 wide, so widths scale ×4).

---

## Scripts

| Script | Phase | Purpose |
|---|---|---|
| `scripts/doctor.sh` / `scripts/doctor.ps1` *(vendored)* | 0 | Environment preflight → `doctor.json` (macOS/Linux/Git-Bash / Windows PowerShell) |
| `scripts/assert-doctor-ran.rb` *(vendored)* | 0 | Gate: the build phases refuse to start until `doctor.json` passes |
| `scripts/setup.rb` *(vendored)* | prereq | Store Sigma credentials once (any shell) |
| `scripts/get_token.py` *(vendored)* | prereq | Shell-neutral Sigma token → `auth.json` (bash / PowerShell / cmd) |
| `scripts/get-domo-token.sh` | prereq | OAuth2 client-credentials → Domo public-API bearer token |
| `scripts/lib/domo_rest.rb` | prereq | Domo REST wrapper (public + private), auto token refresh |
| `scripts/domo-discover.rb` | 1 | Enumerate DataSets, pages, cards; pull schemas + (private) card defs + Beast Modes |
| `scripts/domo-capture-visuals.rb` | 1b | Render per-card PNG + full-page PDF, normalize card geometry → layout JSON (design-fidelity reference) |
| `scripts/convert-beast-modes.rb` | 2 | Beast Mode → Sigma: Domo-specific normalize + classify + POST-lint around the vendored `converter/sql.mjs` (`--convert`) |
| `scripts/find-or-pick-dm.rb` *(vendored)* | 2.5 | Score existing Sigma data models against a signature and recommend reuse (non-destructive) |
| `scripts/preflight-columns.rb` | 2.9 | Check every mapped dataset's Domo columns against the REAL warehouse table schema (live Sigma catalog lookup); reports gaps + auto-suggests (never auto-applies) a derivation formula for a known pattern |
| `scripts/build-dm.rb` | 3 | DataSet schema + projection calc columns → Sigma DM spec (clean display names); honors a Phase-2.5 reuse decision |
| `post-and-readback.rb` *(vendored)* | 4 | POST DM/WB + capture server element IDs / column labels |
| `scripts/derive-presentation-overrides.rb` | 5 (pre) | Source facts (discovery + early Domo card-data) → **layout-safe** styling sidecars (`kpi-format-overrides.json`, `chart-axis-overrides.json`, `category-order-overrides.json`) so Domo-faithful compact KPIs / axes / category order are automatic, not hand-authored. Preserves any operator-authored sidecar already on disk. |
| `scripts/build-workbook.rb` | 5 | Cards → Sigma chart/table/KPI element specs (`chart-specs.json`) + controls |
| `build-workbook-spec.rb` *(vendored)* | 5 | Assemble master + pages from `chart-specs.json` + `dm-ids.json` → POST-ready workbook spec |
| `scripts/qa-check.rb` | 5e | Domo-specific spec gate: KPI-not-count-of-id, filter fan-out, no bar-as-table, text-wrap, gridlines-off |
| `scripts/build-domo-layout.rb` | 5d | Domo card geometry → zone-schema `dashboard-layout.json` (relative-normalized) |
| `build-dashboard-layout.rb` *(vendored)* | 5d | Zone JSON → 24-col grid XML |
| `put-layout.rb` *(vendored)* | 5d | PUT layout to workbook |
| `verify-parity.rb` *(vendored)* | 6 | Compare Domo `query/execute` aggregations vs Sigma `query` → `parity-score.json` (`tiles_*`) |
| `scripts/build-parity-exclusions.rb` | 6 | Derives `parity-plan-exclusions.json` from machine facts in `warnings.json` (today: refused date windows). Carries the originating warning as evidence; **aborts** rather than excluding a runaway share of the pool |
| `scripts/phase6-parity-domo.rb` | 6 | **Finalizer.** Runs `verify-parity.rb`, derives the gate contract (`charts_*`/`status`) into `parity-final.json`, and refuses to emit one when the plan silently omits chartable tiles |
| `assert-phase6-ran.rb` *(vendored)* | 6 | Hard gate before declaring GREEN (run with `--workdir`) |

> The Domo-specific scripts — `convert-beast-modes.rb` (2), `find-or-pick-dm.rb`
> integration (2.5), `build-dm.rb` (3), `build-workbook.rb` + `qa-check.rb` (5),
> `build-domo-layout.rb` (5d), `phase6-parity-domo.rb` + `build-parity-exclusions.rb` (6), plus `get-domo-token.sh`, `lib/domo_rest.rb`,
> `lib/domo_sigma_util.rb`, `domo-discover.rb`, `domo-capture-visuals.rb` — ship
> with unit + end-to-end tests under `test/`. A final live field-path check on
> first instance contact is still recommended.
>
> Scripts marked *(vendored)* are shared across migration skills, not
> Domo-specific. Most (`doctor.sh` / `doctor.ps1` / `get_token.py` / `setup.rb` /
> `assert-phase6-ran.rb` / `find-or-pick-dm.rb`) are synced byte-identical from
> this repo's `shared/` canonical via `tools/sync-shared.rb` — edit `shared/`,
> never here. `post-and-readback.rb`, `build-workbook-spec.rb`,
> `build-dashboard-layout.rb`, `put-layout.rb`, and `verify-parity.rb` are
> refreshed straight from `tableau-to-sigma`'s current scripts instead (they're
> source-agnostic — operate on Sigma DM/workbook specs, no `.twb` parsing).
> `assert-doctor-ran.rb` is vendored in-plugin (pinned from `tableau-to-sigma`)
> and not yet promoted to `shared/`. Fix upstream and re-sync/re-copy in every
> case; don't diverge the local copy.

---

## Step 0 — Environment doctor (MANDATORY — the build phases gate on it)

Run the environment doctor FIRST. It reports missing runtimes (ruby / python /
node / bash) with per-OS fixes — flagging the known Windows footguns (the Python
"Store stub", a missing bash, `core.autocrlf` mangling shebangs) — **and** writes
a machine-readable `doctor.json` fingerprint to `~/.sigma-migration/doctor.json`.
`build-dm.rb` (Phase 3, the first build step) refuses to start until a **passing**
`doctor.json` exists, so a broken environment stops here with an explicit fix
instead of the run improvising around a missing runtime (the #1 cause of
cross-user / cross-OS drift).

macOS / Linux / Git-Bash:
```bash
bash scripts/doctor.sh
```

Windows PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
```

If the doctor cannot pass in your environment and you must proceed anyway, waive
the gate explicitly and name the reason in your report:
`SIGMA_SKIP_DOCTOR_GATE="<reason>" ruby scripts/build-dm.rb`.

---

## Prerequisites

### Sigma credentials
Sigma is the migration *target*, so a Sigma token is needed to POST the DM /
workbook. Mint it in a **shell-neutral** way (works in bash, PowerShell, and cmd):
```bash
ruby scripts/setup.rb                     # one-time — stores Sigma creds (any shell)
python scripts/get_token.py --workdir .   # → ./auth.json (a live token; .gitignored)
```
The Ruby build scripts read `auth.json` from the current directory (or
`$SIGMA_WORKDIR`) automatically, so run them from this skill dir. An explicit
`SIGMA_API_TOKEN` in the environment always wins. On bash you can still use the
env-var idiom if you prefer: `eval "$(python scripts/get_token.py --print-export)"`.

### Domo access — see `refs/connection.md`
Two surfaces, both usually needed:
1. **Public API** (`api.domo.com`) — OAuth2 client (`DOMO_CLIENT_ID` / `DOMO_CLIENT_SECRET`). Gives DataSet schemas, CSV export, SQL execute, page/card IDs, users/groups.
2. **Private API** (`{instance}.domo.com/api/...`) — a **developer access token** (Admin → Security → Access Tokens). Gives card definitions, Beast Mode text, page layout. **Undocumented — confirm shapes on first contact.**

```bash
export DOMO_CLIENT_ID=...  DOMO_CLIENT_SECRET=...
export DOMO_INSTANCE=acme           # for {instance}.domo.com
export DOMO_DEV_TOKEN=...           # private-API access token (optional but needed for full fidelity)
eval "$(scripts/get-domo-token.sh)" # sets DOMO_ACCESS_TOKEN (public)
```

---

## Phase 0 — Confirm access fidelity

Before scoping, determine which extraction tier is available:
- **Tier A (full):** developer token reaches `/api/content/v1/cards` → auto-extract card defs + Beast Modes. Aim for this.
- **Tier B (degraded):** public API only → DataSet schemas + CSV + card IDs, but **no** card defs/Beast Modes/layout. Fall back to **PNG-read** of each card + manual chart-kind tagging.

Run `ruby scripts/domo-discover.rb --probe` to detect the tier.

---

## Phase 1 — Discover

`ruby scripts/domo-discover.rb --pages <id,...>` →
- DataSets used by the target pages (schema: column names + types)
- Card list per page + per-card definition (Tier A) or PNG (Tier B)
- Beast Mode formulas (Tier A)
- Page layout (collections + card geometry)

Outputs `discovery/datasets.json`, `discovery/cards.json`, `discovery/pages.json`,
`discovery/beast-modes.json`.

---

## Phase 1b — Capture visuals + layout (design fidelity)

**This is the step that prevents generically-templated output.** Rebuilding from
DataSets + chart-type strings alone is why early Domo migrations "didn't look
good." Capture a true visual so the build has something to match; real card
geometry (x/y/w/h) is a separate, earlier capture — see Phase 1a's
`domo-discover.rb --pages` (`DomoSigma.merge_geometry` copies it onto
`discovery/cards.json`), the ONE geometry source:

`ruby scripts/domo-capture-visuals.rb --pages <id,...>` →
- `discovery/png/cards/<cardId>.png` — per-card visual reference (chart/KPI cards)
- `discovery/png/cards/<cardId>.pdf` — per-card reference for **table** cards
  (`parts=image` returns 400 for a table; only `parts=imagePDF` works)
- `discovery/png/pages/<pageId>.pdf` — full-page source image, **when available**

Tier A (dev token) does this automatically via the card render endpoint. **Tier B:
export the same PNGs/PDF from the Domo UI into those same paths** — the build and
QA steps consume them identically (see `refs/connection.md` "Visual capture").
Either way, **READ these images** before and during Phase 5.

### ⚠️ ASK THE OPERATOR FOR A PAGE SCREENSHOT — layout depends on it

**No page-render endpoint was found.** `/api/content/v1/pages/{pageId}/render` is a
hard **404**, as is every variant probed (v2/v3, stacks, export, image) — so the
full-page PDF above often will not exist. Treat this as "not found", not proven
absent: Domo's private surface is undocumented, and the `brycewc/domo-product-apis`
Postman collection reportedly carries a **Get Layout** request that has not yet been
confirmed. If you find a working path, document it here first. the script records
`discovery/page-visual-unavailable.json` when it can't get one.

That matters more than it sounds, because **Domo's API exposes NO layout geometry
for a classic page** (live-validated 2026-07-30 — see
`refs/live-validation-2026-07-30.md`):
- `preferredFullWidth` / `preferredFullHeight` are accepted on card create but
  **persist nowhere** — absent from every readback
- `sizes[].size` comes back `""` for API-created cards (a human resizing a card in
  the UI is what sets `small`/`medium`/`large`)
- `collections[]` (sectioning) has no reachable write endpoint
- even card **creation order does not control page order**

> **⚠️ NARROWED 2026-07-30 — this is true for a *classic* page, not for every
> page.** `refs/page-layout-v4.md` — corroborated on two independent live Domo
> tenants — found a page style, **v4-inline**, where geometry (and `HEADER`
> section-divider position) IS readable and exact via the API:
> `pageLayoutV4.standard.template[]` joined to `content[]` on `contentKey` (grid
> is 60-wide, so Domo → Sigma scales ×0.4). A page qualifies if `pageLayoutV4` is
> present in its stacks response with `includeV4PageLayouts=true` — read
> `refs/page-layout-v4.md` for the full three-page-style taxonomy before assuming
> a page is "classic." That ref also records two defects that WERE found and ARE
> now fixed: `domo_rest.rb`'s `cards_for_page` now requests the v4 payload, and
> `DomoSigma.merge_pagelayoutv4_geometry` (`scripts/lib/domo_sigma_util.rb`)
> correctly performs the `content[]`/`standard.template[]` join. A v4-inline page
> now gets real geometry automatically via `merge_geometry`/
> `build_dashboard_for_page` — no extra agent action needed, same as any other
> page. Do NOT route a v4-inline page to the classic/screenshot-request flow
> below — that flow is correctly reserved for pages that genuinely have no
> `pageLayoutV4` and no legacy `x`/`y`/`w`/`h`.

So for a page without readable v4 geometry the ONLY route to real layout fidelity
is a human-supplied image. **Explicitly ask the operator:**

> "Domo's API doesn't expose this page's layout. Can you paste or export a
> screenshot of the page? I'll read the arrangement from it so the Sigma dashboard
> matches. Without one I'll compose a clean default layout instead."

Then READ the image and transcribe what you see into
**`discovery/layout-observed.json`** (schema + preference order documented in
`scripts/build-domo-layout.rb`). Mark it `_source: "observed-from-screenshot"` —
it is a model reading an image, and must never be presented as API-derived truth.

**If no screenshot is provided, do NOT fake geometry and do not stack.** The layout
builder composes a clean default instead, in this house order:

> **controls at the top → KPIs → charts → tables**

i.e. a full-width control band, then a compact KPI row (KPIs are short — never a
chart-sized band each), then charts 2-up, then tables/pivots full width. This is the
same composition the `sigma-workbooks` / `branded-dashboard-format` authoring skills
use; see `refs/layout-visual-qa.md`.

Geometry preference order used by Phase 5d, highest first:
1. real API x/y/w/h pixel geometry (`pageLayoutV4` present — see the narrowing
   note above; blocked by two open code defects documented in
   `refs/page-layout-v4.md`)
2. `discovery/layout-observed.json` (read from a screenshot)
3. `collections[]` + a non-empty `size` token
4. the element-kind default composition above
5. last-resort ordered stack — always warns LOUDLY, never silent

---

## Phase 2 — Translate Beast Modes

Three scripted steps, no agent/MCP call in the loop (`migrate-domo.rb` runs all
three automatically):
```bash
ruby scripts/convert-beast-modes.rb            # normalize → discovery/formulas.pending.json
ruby scripts/convert-beast-modes.rb --convert  # vendored converter/sql.mjs fills sigmaFormula/converted/warnings, locally via node
ruby scripts/convert-beast-modes.rb --lint     # validate → discovery/formulas.json
```
`--convert` resolves the converter via a 3-tier ladder: the vendored bundle
(default, no MCP/network), a local `sigma-data-model-mcp` build via
`--mcp-dir`/`DOMO_MCP_DIR` (explicit dev opt-in only), or — last resort, bundle
or `node` absent — exit 10 with the manual `convert_sql_to_sigma_formula`
+ `--converter-out` fallback instructions. Applies the normalizations in
`refs/beast-mode-to-sigma.md` FIRST (strip backticks, flag the `WEEKDAY`
day-numbering mismatch (MySQL vs. Sigma disagree — override to
`Mod(Weekday([col])+5,7)`), flag aggregate `CEILING`/`FLOOR`, reject
unsupported `SQRT`/`CONVERT_TZ`).
Outputs `discovery/formulas.json` (Beast Mode id → Sigma formula).

---

## Phase 2.5 — Reuse check

Before creating a new data model, score existing Sigma data models against this
migration's shape and reuse a strong match rather than adding another DM:
```bash
ruby scripts/find-or-pick-dm.rb --workbook-signature discovery/dm-signature.json \
  --out discovery/dm-match.json
```
Phase 3 (`build-dm.rb`) picks up `discovery/dm-match.json` automatically and
reuses `recommended_dm_id` **only when `auto_picked` is true** — i.e. the top
candidate covers all source tables (or is a full column-superset), the same
bar the sibling cognos/looker converters apply. On a confirmed auto-pick it
writes `discovery/dm-reuse.json` recording the reused data-model id and
**skips POSTing a fresh DM spec** entirely. When `auto_picked` is false (a
merely-scored-but-ambiguous candidate, a wide tie, or no signature supplied),
Phase 3 proceeds to build new as documented below. Never auto-reuse a partial
match silently — surface the picker's warning about inherited columns/RLS/
metrics before committing to reuse.

---

## Phase 3 — Data model

`ruby scripts/build-dm.rb` → one DM element per DataSet (flat table) + calc
columns from translated Beast Modes. No star schema unless a DataFlow join is in
scope (out of scope for v1 — DataSets are treated as opaque source tables).

**Pre-flight (Phase 2.9, runs automatically via `migrate-domo.rb`):**
`ruby scripts/preflight-columns.rb` checks every mapped dataset's Domo columns against the
real warehouse table's schema before `build-dm.rb` will proceed — a Domo DataSet routinely
carries columns (derived/computed, or a drifted landed copy) that the mapped warehouse table
doesn't have, which otherwise only surfaces as an opaque `POST /v2/dataModels/spec` 400. Any
gap is reported by name in `discovery/column-preflight.json`, with an auto-*suggested* (never
auto-applied) `columnOverrides` entry when a known derivable pattern matches (e.g. a YYYYMMDD
integer date key). Resolve via `excludeColumns`/`columnOverrides` in `dataset-map.json`, then
re-run. Waivable like the doctor-gate: `SIGMA_SKIP_COLUMN_PREFLIGHT="<reason>"`.

Note the one accepted gap: a human-authored `columnOverrides` entry is trusted as "resolved" as
soon as it's present — the formula it contains is NOT independently re-checked against the
warehouse, so an override that itself references a column the warehouse doesn't have will still
only surface as an opaque error at DM POST time, same as before this pre-flight existed.

---

## Phases 4–6 — turnkey (one command)

**Run the whole build-and-post pipeline with the orchestrator — do NOT hand-chain the individual scripts (hand-chaining is what caused the field drift: an off-script agent reassembled the spec with wrong refs/formats and skipped the layout, producing a single-column stack):**

```
ruby scripts/migrate-domo.rb                                    # live: discover → … → assert-phase6 (creds in ENV; see refs/connection.md)
ruby scripts/migrate-domo.rb --offline <fixtureDir> --out <dir> # offline dry-run over a discovery-shaped fixture
```

`migrate-domo.rb` chains every phase below — one log line per phase, a `run-state.json` ledger, fail-fast, idempotent (`--force` to redo), Windows-safe (argv shell-outs, no inline bash). It folds in the `build-dm` + DM `post-and-readback` that `build-workbook-spec.rb` requires. `--offline` proves the deterministic build end-to-end against a fixture, writing `workbook-spec.json` + a `layout-2d.flag` (`grid`|`stack`) computed from the **real** layout engine — so you can confirm a true 2D grid (not a stack), inline logos, and `decimalPlaces` formats with no creds.

For a GREEN live run, pass the full source screenshot:

```bash
ruby scripts/migrate-domo.rb ... --source-dashboard-png /path/source.png
```

The orchestrator stages it, renders Sigma, and finalizes strict value parity.
If `<out>/blind-grade.json` is absent, it writes
`<out>/visual-grade-request.json`, stamps `record-visual-check` as `waiting`,
and exits **20** (resumable, not failed). The driving agent must launch a fresh
context-free vision grader from that request, then rerun the **same command**;
the rerun validates the image hashes, records the six-dimension verdict, and
continues through `assert-phase6-ran.rb` automatically. No JSON hand-edit or
special finalize command is allowed. A provider can make this literally one
process by passing `--visual-grader /path/adapter`; the executable receives the
request JSON path as its only argument and must write its `output_json`.

The phase sections below document what the orchestrator runs **internally** — read them to understand or debug a phase, not to run them by hand.

## Phase 4 — Post DM

Reuse `post-and-readback.rb`: POST to `/v2/dataModels/spec`, GET back, capture
server element IDs, verify zero error columns.

---

## Phase 5 — Workbook

**Phase 5 (pre) — presentation overrides (automatic, runs before build-workbook).**
`migrate-domo.rb` runs `scripts/derive-presentation-overrides.rb` first (live:
after an early `collect-parity-expected.rb`, which reads Domo card-data only and
needs no Sigma). It derives the **layout-safe** styling sidecars the builders
consume — Domo-style compact KPI display, compact currency axes, source category
order, and (when screenshot geometry is present) KPI title/subtitle blocks —
from source facts, so a customer run reproduces the gold-path styling without
hand-authored files. It only writes sidecars that don't already exist (an
operator's hand-authored sidecar always wins) and never fails the run.
Screenshot-backed chart and KPI headers are safe because the observed-layout
path nests each header with its primary element inside one source-card container. The
`domo/orders-presentation` corpus case pins this derivation offline/creds-free.

`ruby scripts/build-workbook.rb` → map each card to a Sigma element, following
**`refs/card-to-element.md`** (the chart map). **Read the per-card PNG from
`discovery/png/cards/` while mapping** — the image disambiguates chart kind and
formatting that the chartType string alone misses.

**For EVERY card, decide the element kind FIRST (Rule 0 in the ref):**
> Does the Domo tile show a single big **Summary Number**? → emit a `kpi-chart`,
> **never a table.** This is the failure mode that shipped: Domo lets any card
> (including a table) display as a summary number, and porting it as a Sigma
> table produces an ugly grid where a big number was expected. When torn between
> KPI and a 1-row table, choose KPI. Missing sparkline support is NOT a reason to
> fall back to a table — emit the KPI and warn that the trend must be bound in
> the UI.

Then translate the rest per the ref:
- Domo chart type → Sigma chart kind (full table in `refs/card-to-element.md`)
- **KPI value guard:** a KPI's value is the summary number's aggregate of the
  authored **measure** (with a source prefix, e.g. `Sum([Master/Sales Amount])`) —
  **never `Count`/`CountDistinct` of the DM primary/row-key column** (that's Domo's
  default summary aggregate). See `refs/card-to-element.md` Rule 0 COUNT-of-id rule.
- **Bar vs table:** a `badge_*bar*` card → Sigma `bar-chart`, **NOT** a
  `table` + dataBars. See `refs/card-to-element.md` bar-vs-table rule.
- axis / series / sort / Top-N binding
- pivot cards → `rowsBy` + `columnsBy` arrays
- page filters → workbook controls; card-level filter clauses → element filters
  (port **both** levels — see the ref's Filtering fidelity section)
- **No liberties:** one card → one element; reproduce labels/formats/layout; every
  unsupported/dropped item → a Phase-5e warning, never a silent substitution

**Workbook-as-code release contract:** read
`refs/workbook-code-release-gaps.md` and the machine-readable
`refs/catalogs/{viz-kind,workbook-feature}.json`. Workbook payloads are outer
metadata plus `document:{schemaVersion,kind,pages,elements,layout,...}`;
`document.pages` is metadata-only, `document.elements` is flat, and the required
layout is the sole page-membership authority. Layout XML emitted by Domo uses
the live `<Element>` / `<Container>` tags; the historical `LayoutElement` /
`GridContainer` aliases are accepted only while reading old artifacts and are
rejected if they escape an emission boundary. Data models are deliberately
unchanged (`pages[].elements`). Released target capabilities are not permission
to invent source intent: this converter emits grounded multi-page navigation,
explicit v4 page breaks/headers, and bounded CURRENT/TARGET progress. Waterfall,
legend/drill wiring, panels, tabbed/repeated containers, and ungrounded styling
remain loud gaps; `box-chart` remains entitlement-gated.

### Phase 5d — Layout
`ruby scripts/build-domo-layout.rb` turns `discovery/cards.json` geometry (from
Phase 1a's `merge_geometry`) + `discovery/pages.json` names into
`discovery/dashboard-layout.json`. Reuse `build-dashboard-layout.rb` +
`put-layout.rb`: feed that file → 24-col grid, preserving relative position and
the hero viz's weight.

**Classic Domo pages carry no geometry at all** — so this phase runs the preference
chain documented in Phase 1b above (API geometry → `layout-observed.json` from a
screenshot → collections+size tokens → clean default composition → warned stack).
If you skipped asking for a screenshot in Phase 1b, go back and ask: it is the
difference between a faithful layout and a reasonable guess.

A `layout-2d.flag` of `"grid"` means the engine produced a 2D grid rather than a
stack — it does NOT mean the composition is good. Bands must also be well-filled:
`layout_lint` fails an under-filled band (e.g. a lone element covering 12 of 24
columns leaves dead space), so a single element in a band should be widened to fill
it or paired with its neighbour.

### Phase 5e — Layout visual QA (MANDATORY gate)
Run the layout-visual-qa loop (`refs/layout-visual-qa.md`): render the full Sigma
page to PNG and compare it **side-by-side against the Domo full-page PDF**
(`discovery/png/pages/<pageId>.pdf`) plus the per-card PNGs. Check the
source-fidelity → structural → design-quality rubrics, fix the spec, re-render,
and loop until the render passes. Declare done on a *clean render*, never on HTTP 200.
In the orchestrated path, fulfill `visual-grade-request.json` with a fresh
context-free grader per `refs/blind-grader-brief.md`; exit 20 means WAITING for
that evidence, not a failed migration and not permission to waive the gate.

Plus the Domo-specific gate from `refs/card-to-element.md`:
- **Every Domo summary-number tile → a Sigma `kpi-chart`.** Count summary tiles
  in the source PDF vs `kpi-chart` elements in the spec — they must match. Zero
  KPIs when the source has summary tiles is an automatic **fail**.
- No Sigma table stands where the Domo tile showed a single number.
- Filter-inventory diff is clean (every page filter → control, every card filter
  → element filter).

---

## Phase 6 — Parity (hard-gated)

Pull ground-truth aggregations from Domo's **public** `POST /v1/datasets/query/execute/{id}`
(stable) and compare to Sigma `query`. Run `assert-phase6-ran.rb` before declaring
GREEN. Do NOT rely on the private API for parity data.

## Phase 6 — Security (RLS)

**Detect Domo PDP (Personalized Data Permissions) policies always.** Every
DataSet pulled in Phase 1 is scanned for a `permission`/`pdp` policy block
(PDP policies detected from each DataSet's permission metadata, written to
discovery/rls-todo.json) with a warning — **never silently dropped**. A
PDP-bearing DataSet with no corresponding Sigma mapping is a fidelity gap, not a
clean migration.

> NOTE (deferred-live): detection fires only once Phase-1 discovery is extended
> to request each DataSet's permission block (`?parts=core,permission`); the
> field-path is unconfirmed against a live instance, so today `rls-todo.json`
> is populated only when discovery already carries a `permission`/`pdp` field.

**Apply as Sigma row-level security opt-in.** Porting a detected policy to Sigma
user attributes + DM row filters happens only when asked, never automatically —
confirm the predicate semantics with the customer's Domo admin before enabling it
for any audience beyond the migration operator.

---

## Phase 7 — Cleanup

Delete orphan test workbooks (`/v2/files/<id>`).

---

## Open questions — RESOLVED 2026-07-30

All three former blockers were answered by live contact. Full evidence in
`refs/live-validation-2026-07-30.md`:

1. **Does the dev token reach `/api/content/v1/cards`?** — **Yes.** Tier A is
   reachable. OAuth bearer tokens are 401 on every private path; the two
   credentials are not interchangeable.
2. **Exact card-def JSON shape** — there are **three** distinct shapes, and the
   previously-documented "Shape A" is the public *create body*, not a read
   response. The summary number lives at `definition.subscriptions.big_number`.
3. **Page-layout geometry units** — classic pages have **no x/y/w/h at all**.
   Layout is `collections[]` (titled sections with `cardIndices[]`) plus a
   per-card T-shirt `size` token, on a **6-column** Domo grid (so Domo→Sigma
   width scales ×4).

That former open bar is now closed by the 2026-08-10 gold acceptance run.
Customer-specific source shapes remain subject to the same hard gates; do not
generalize one fixture's pass to another tenant without rerunning them.
