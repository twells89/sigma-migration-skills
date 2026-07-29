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

> **Status: offline-complete; live parity not yet claimed.** The private-API
> shapes (card definitions, Beast Mode text, page layout) are **doc-confirmed**
> against Domo's OpenAPI, official docs, and independent reference
> implementations (see `refs/connection.md`), and the skill's offline test
> suites pass hermetically. The public OAuth path is documented and stable.
> **What remains live**: a field-path check on first contact with a real
> instance (private endpoints can vary by Domo version) and a live parity run
> against a real Sigma workbook. Neither is claimed done here — this skill
> defers both, consistent with this repo's rule of never calling a conversion
> validated until it passes live parity for that instance.
> **Compliance:** before a production run, confirm with the customer's Domo
> account team that programmatic extraction for migration is acceptable — see
> `refs/connection.md` "Compliance note".

**Read ALL of the following before replying or taking any action:**
- `refs/connection.md` — Domo auth (OAuth public API + developer access token for private API)
- `refs/beast-mode-to-sigma.md` — Beast Mode (MySQL SQL) → Sigma formula mapping
- `refs/card-to-element.md` — **Domo card → Sigma element map. Read before Phase 5.** Rule 0 (Summary Number → KPI, never a table) is the #1 fidelity fix; also covers filtering + no-liberties discipline.
- `refs/layout-visual-qa.md` — the Phase 5e visual QA gate

General workbook-spec and data-model-spec authoring idioms (grid layout
mechanics, chart/control shapes, DM column/relationship shapes) are deferred to
the **`sigma-workbooks`** and **`sigma-data-models`** skills — this skill covers
only what's Domo-specific: extraction, Beast Mode translation, and the
card→element map.

---

## The one big idea

**Beast Mode is MySQL-dialect SQL.** Domo's calc-field language routes straight
through the existing `mcp__sigma-data-model__convert_sql_to_sigma_formula` tool —
no bespoke parser like Power BI's DAX. The formula layer is nearly free. The work
that remains is *extraction* (getting card defs + Beast Mode text + layout out of
Domo) and *layout/binding* (cards → Sigma elements on a 24-col grid).

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
| `scripts/convert-beast-modes.rb` | 2 | Beast Mode → Sigma: Domo-specific normalize + classify + POST-lint around `convert_sql_to_sigma_formula` |
| `scripts/find-or-pick-dm.rb` *(vendored)* | 2.5 | Score existing Sigma data models against a signature and recommend reuse (non-destructive) |
| `scripts/build-dm.rb` | 3 | DataSet schema + projection calc columns → Sigma DM spec (clean display names); honors a Phase-2.5 reuse decision |
| `post-and-readback.rb` *(vendored)* | 4 | POST DM/WB + capture server element IDs / column labels |
| `scripts/build-workbook.rb` | 5 | Cards → Sigma chart/table/KPI element specs (`chart-specs.json`) + controls |
| `build-workbook-spec.rb` *(vendored)* | 5 | Assemble master + pages from `chart-specs.json` + `dm-ids.json` → POST-ready workbook spec |
| `scripts/qa-check.rb` | 5e | Domo-specific spec gate: KPI-not-count-of-id, filter fan-out, no bar-as-table, text-wrap, gridlines-off |
| `scripts/build-domo-layout.rb` | 5d | Domo card geometry → zone-schema `dashboard-layout.json` (relative-normalized) |
| `build-dashboard-layout.rb` *(vendored)* | 5d | Zone JSON → 24-col grid XML |
| `put-layout.rb` *(vendored)* | 5d | PUT layout to workbook |
| `verify-parity.rb` *(vendored)* | 6 | Compare Domo `query/execute` aggregations vs Sigma `query` |
| `assert-phase6-ran.rb` *(vendored)* | 6 | Hard gate before declaring GREEN (run with `--workdir`) |

> The Domo-specific scripts — `convert-beast-modes.rb` (2), `find-or-pick-dm.rb`
> integration (2.5), `build-dm.rb` (3), `build-workbook.rb` + `qa-check.rb` (5),
> `build-domo-layout.rb` (5d), plus `get-domo-token.sh`, `lib/domo_rest.rb`,
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
- `discovery/png/cards/<cardId>.png` — per-card visual reference
- `discovery/png/pages/<pageId>.pdf` — full-page source image for the QA gate

Tier A (dev token) does this automatically via the card render endpoint. **Tier B:
export the same PNGs/PDF from the Domo UI into those same paths** — the build and
QA steps consume them identically (see `refs/connection.md` "Visual capture").
Either way, **READ these images** before and during Phase 5.

---

## Phase 2 — Translate Beast Modes

`ruby scripts/convert-beast-modes.rb` → feeds each Beast Mode SQL string through
`convert_sql_to_sigma_formula`. Apply the normalizations in
`refs/beast-mode-to-sigma.md` FIRST (strip backticks, `WEEKDAY`→`DAYOFWEEK`,
flag aggregate `CEILING`/`FLOOR`, reject unsupported `SQRT`/`CONVERT_TZ`).
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

---

## Phases 4–6 — turnkey (one command)

**Run the whole build-and-post pipeline with the orchestrator — do NOT hand-chain the individual scripts (hand-chaining is what caused the field drift: an off-script agent reassembled the spec with wrong refs/formats and skipped the layout, producing a single-column stack):**

```
ruby scripts/migrate-domo.rb                                    # live: discover → … → assert-phase6 (creds in ENV; see refs/connection.md)
ruby scripts/migrate-domo.rb --offline <fixtureDir> --out <dir> # offline dry-run over a discovery-shaped fixture
```

`migrate-domo.rb` chains every phase below — one log line per phase, a `run-state.json` ledger, fail-fast, idempotent (`--force` to redo), Windows-safe (argv shell-outs, no inline bash). It folds in the `build-dm` + DM `post-and-readback` that `build-workbook-spec.rb` requires. `--offline` proves the deterministic build end-to-end against a fixture, writing `workbook-spec.json` + a `layout-2d.flag` (`grid`|`stack`) computed from the **real** layout engine — so you can confirm a true 2D grid (not a stack), inline logos, and `decimalPlaces` formats with no creds.

The phase sections below document what the orchestrator runs **internally** — read them to understand or debug a phase, not to run them by hand.

## Phase 4 — Post DM

Reuse `post-and-readback.rb`: POST to `/v2/dataModels/spec`, GET back, capture
server element IDs, verify zero error columns.

---

## Phase 5 — Workbook

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

### Phase 5d — Layout
`ruby scripts/build-domo-layout.rb` turns `discovery/cards.json` geometry (from
Phase 1a's `merge_geometry`) + `discovery/pages.json` names into
`discovery/dashboard-layout.json`. Reuse `build-dashboard-layout.rb` +
`put-layout.rb`: feed that file → 24-col grid, preserving relative position and
the hero viz's weight.

### Phase 5e — Layout visual QA (MANDATORY gate)
Run the layout-visual-qa loop (`refs/layout-visual-qa.md`): render the full Sigma
page to PNG and compare it **side-by-side against the Domo full-page PDF**
(`discovery/png/pages/<pageId>.pdf`) plus the per-card PNGs. Check the
source-fidelity → structural → design-quality rubrics, fix the spec, re-render,
and loop until the render passes. Declare done on a *clean render*, never on HTTP 200.

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

## Open questions — resolve on first instance access

See `refs/connection.md` for the current confidence level on each private
endpoint. The blockers that most change the skill: (1) does the dev token reach
`/api/content/v1/cards`? (2) exact card-def JSON shape; (3) page-layout geometry
units. Until confirmed on a live instance, treat Phases 1/2/5 as unvalidated.
