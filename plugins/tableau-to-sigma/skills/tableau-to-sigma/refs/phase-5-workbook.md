<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 5 — build the Sigma workbook (5a-5f) -->

## Phase 5 — Build the Sigma workbook

### 5a-auto. Run build-charts-from-signals first

> **🚧 GATE:** this script exits 1 unless `<workdir>/png-read.json` exists (the Phase 1d dashboard-read artifact). If it blocks, go back to Phase 1d — Read the dashboard PNG and write `png-read.json` — don't reach for `--skip-dashboard-read` unless the PNG is genuinely unavailable.

For most workbooks, `build-charts-from-signals.rb` produces a usable starting spec:

```bash
ruby scripts/build-charts-from-signals.rb \
  --tableau-dir <WORK> \
  --layout <WORK>/dashboard-layout.json \
  --meta <WORK>/dashboard-layout-meta.json \
  --master-map <WORK>/master-columns.json \
  --master-element-id master \
  --auto-controls --page-per-worksheet \
  --title "<Workbook Title>" \
  --out <WORK>/chart-specs.json \
  --coverage-out <WORK>/coverage.json
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
- ✅ Parameter-driven **metric/measure switching** (a "Select Metric" param picking which measure a chart shows) → list control + `Switch()` bound as the chart MEASURE — see the recipe below
- ✅ Table calcs INDEX/LOOKUP/TOTAL/RANK/ZN/IIF/COUNTD → Sigma equivalents
- ✅ Synchronized-axis worksheets → `combo-chart` kind w/ two yAxis groups
- ✅ Customer-discovered learned-rules from `~/.tableau-to-sigma/learned-rules.yaml`

### Parameter-driven metric/measure switching — recipe + gotchas (READ if a chart's measure is param-controlled)
A very common Tableau idiom: a **parameter** (e.g. "Select Metric": Sales / Profit / Quantity, or Job-Losses "Type": Total / U.S.-born / Immigrant) drives which measure a chart shows, via a calc like
`SUM(CASE [Parameters].[P] WHEN 0 THEN [A] WHEN 1 THEN [B] END)` or `IF [Parameters].[P]="Rev" THEN SUM([Rev]) ELSE SUM([Cost]) END`.

**Target Sigma shape:** a **list/segmented control** seeded from the parameter's members + a `Switch([ctl-param-<slug>], …)` **bound as the chart's MEASURE** (`build-charts` does this via `rewire_param_switch!`). Two branch shapes, handled differently:
- branches are **bare columns** (`THEN [A]`) → measure becomes `Sum(Switch([ctl], …, [A], …))` (shelf aggregate wraps the Switch);
- branches are **already aggregated** (`THEN SUM([A])`) → measure becomes the `Switch(…, Sum([A]), …)` itself (no double aggregation).

**Gotchas that make it "look broken" — verify these:**
1. **The control must actually drive the measure.** The build now binds the metric-switch measure automatically — the chart's measure formula should be `Sum(Switch([ctl-param-…], …))` (bare-branch CASE) or `Switch([ctl-param-…], …, Sum([A]), …)` (per-branch aggregate), NOT `Sum([Master/<calc>])`. Build log confirms: `measure '…' is a parameter-driven metric switch — bound to the control-driven Switch on the yAxis`. If you instead see a bare `Sum([Master/<calc>])` measure (calc didn't auto-translate — compound/inequality condition, LOD-wrapped or other-calc branch), hand-author it: materialize the branch columns, set the measure to the `Switch`, per the shapes above.
2. **Numeric-coded params with display aliases** (Tableau member `value='0.'` aliased to "Total Job Losses"). The `Switch` compares the control's VALUE to the `WHEN` keys — so the control's option **values** must equal the `WHEN` literals (`"0"`/`"1"`/…), with the aliases as **labels**. If the control shows friendly labels but the Switch never matches (chart shows blank/else), align the control's option values to the `WHEN` keys (or rewrite the `Switch` keys to the alias labels). This is the #1 cause of a wired-but-blank metric switch — CHECK IT.
3. **`SUM(CASE …)` (CASE inside the aggregate)** and **per-branch `SUM()`** both translate; the outer aggregate comes from the chart shelf, so don't hand-wrap a second time.
4. If the calc doesn't auto-translate (compound/inequality condition, LOD-wrapped branch, branch referencing another calc), the build emits a manual note — hand-author the control + `Switch` measure per the shape above, then re-verify with #1 and #2.

### Workbook controls that drive data-model calculations

Control formula scope is document-local. A workbook control named
`ctl-param-region` does **not** drive a data-model calculation that references a
data-model control merely because the IDs or captions match. The workbook
control must target the data-model control explicitly:

```json
"parameters": [
  {
    "kind": "data-model",
    "dataModelId": "<posted-data-model-id>",
    "controlId": "<readback data-model controlId>"
  }
]
```

The orchestrator adds this binding after the data-model readback and records
`<WORK>/dm-control-bindings.json`. Never replace it with a workbook formula
reference to the data-model control. Workbook calculations may reference the
workbook control as `[<workbook controlId>]`; data-model calculations reference
their local data-model control, and `parameters[]` is the bridge between them.

The same document boundary applies to **dynamic text in a title**. Tableau
serializes a displayed parameter in a worksheet title as
`<[Parameters].[Parameter 1 3]>`; Sigma renders that literally, so it must be
translated to `{{[<controlId>]}}` — and only against a control the **workbook**
carries. Dynamic text cannot reach a data-model control, so when a parameter was
converted into a data-model control only, `build-charts-from-signals.rb`
substitutes the parameter's current value instead and records why. `validate-spec.rb`
fails the spec if any raw Tableau token would reach POST.

### Migration coverage — WARN vs NOTE (read this before reacting to log volume)
The build prints two prefixes (bead beads-sigma-59mk). **`NOTE`** = a success
confirmation or a verify-nudge — NOT a gap (`translated inline:` / `decomposed:` /
`learned-rule applied` / `auto-emitted … verify` / `sort carried`). **`WARN`** =
an actual drop or degradation that needs a decision. Historically every note was
prefixed `WARN`, so a clean conversion read like a pile of failures — that volume
is what fuels the "it drops a lot" perception; it is not the gap count.

The build also writes **`coverage.json`** (`--coverage-out`, aggregating the WARN
lines + dropped controls + inferred-kind tiles + nested-LOD chains) and
`migrate-tableau.rb` prints ONE **MIGRATION COVERAGE** readout that leads with what
carried over (only a `dropped` component is truly absent; `approximated`/`degraded`
still land with their data). `WARN` count == coverage gap count by construction.

What the remaining message types mean — act on each one:
- `NOTE 'X' … translated inline / decomposed / learned-rule applied` — already emitted, no action.
- `NOTE 'X' auto-emitted … verify / detected as dual-axis` — built; eyeball it against the source PNG.
- `WARN 'X' … could not be auto-decomposed — dropped from the grid` — re-author the calc manually (a `dropped` coverage gap).
- `WARN 'X' … STAYS MANUAL` — degraded: copy the printed Sigma formula into a master column.
- `WARN 'X' has Tableau reference marks (...) not auto-emitted` — add Sigma `referenceMarks` post-publish (beads-sigma-7ak).
- `'X' has N Tableau action filter(s) — skipped` — read `<out>-actions.md` and wire Sigma cross-element filtering manually.
- `parameter '...' is a numeric range — skipped auto-control` — add a number control by hand (beads-sigma-ebw).
- `DATASOURCE-level filter 'X' (always-on) … Recorded needs-master-default` (#483) — an always-on Tableau data-source filter (a virtual-connection `<shared-view>` database-domain filter such as `company_active = true`) whose column is not a charted dimension. It is **NOT optional** and renders nothing on any dashboard, so a visual check can't catch a miss. **Apply it as a workbook-wide default filter on the master element** — an element-level `filters` entry `{id, columnId, kind:"list", mode:"include", values:[…]}` on the `master` table (the `id` is REQUIRED — the spec endpoint 400s `filters[N].id: Invalid string: undefined` without it; use a deterministic slug like `flt-master-0`) (so every element sourcing it inherits the scope) — NOT an open `values:[]` control, which widens it back to everything. The **datasource-filter gate** (`scripts/assert-datasource-filters.rb`, run at `migrate-tableau.rb --finalize` and standalone) blocks GREEN until it is applied (an `is_active_flag` filter must be applied, not merely surfaced as a control). Escape hatch: `--skip-datasource-filters "<reason>"`.

### Multi-metric region dashboard (READ if a control's `png-read.json` mixes `target_tiles` and `highlight_tiles`)

When Phase 1d recorded a list control that **filters** some tiles (`target_tiles`) but only **highlights/re-colors** others (`highlight_tiles`) — e.g. a Region control that filters the Trend/Top panels but leaves the Year-on-Year bars showing all regions — build to the **multi-metric region dashboard recipe** in `refs/fidelity-recipes.md` (two masters `master`/`masterAll`, latest-year + real-entity conditional measure, grouped top-N, highlight color column, dual-axis trend, thin aligned header bands). Skipping it is the regression that ships region-aggregate rows as "countries", all-years sums, and bars collapsed to one region.

### 5a. Write the workbook spec

> **`folderId` is required here too.**

> **The workbook body is `document`-wrapped, not flat (verified live 2026-08-03,
> including on `POST /v2/workbooks/spec/verify` 2026-08-04).** `schemaVersion`,
> `pages`, `kind`, and `layout` all nest under a top-level `document` key; only
> ownership/location metadata (`name`, `folderId`, `ownerId`) stays outside it.
> The old flat body (these fields at the request root) now 400s fleet-wide.
> Data-model specs (`POST /v2/dataModels/spec`) are unaffected and remain flat
> — do not wrap those. `shared/lib/code_rep.{rb,py,mjs}` (`Sigma::CodeRep.wrap`)
> is the canonical adapter; reads tolerate both shapes, writes always nest.

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
  "document": {
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
}
```

Rules:
- Master `kind` is `table`, `visibleAsSource: false`, sourced from the DM element.
- Master-column formulas use the DM element's `name` as prefix (`[Order Fact/Sales]`, not the element ID).
- Charts and controls source the master with `"elementId": "master"` regardless of which page they live on — cross-page **source** references (chart → master) resolve fine.
- Chart-column formulas use the master table's `name` as prefix (`[Master/Sales]`).
- Layout XML must produce **one `<Page>` tag per page**, including a tiny full-width `<Element elementId="master" .../>` inside the Data page's `<Page>` (one entry **per master instance** when per-page masters are on — see below).

> **⚠️ Per-page masters (PLAN-v3 PR-17, flag-staged).** A control filter *propagates
> along source chains, not page boundaries* — so when **multiple content pages share
> ONE master**, every page's controls compose on that one master: flipping page A's
> control silently refilters page B's tiles (V5.6-CONTROLS-AUDIT D11; reproduced live
> 2026-07-19 — Overview flip dropped BOTH pages 5266→2220 rows). The static control
> lint (gate 7) can't see it (it walks the global source closure). **Fix:** pass
> `--per-page-masters` to `migrate-tableau.rb` (or `build-workbook-spec.rb`). Each
> content page that draws on the master then gets its **own** clone on the Data page
> (`master-<page-slug>`, `<helper-id>-<page-slug>`; column ids preserved so control
> `filters[].columnId` still resolves), and that page's charts/controls/helpers are
> repointed to it — a control now filters only its own page's tiles (live-verified:
> the other page held at 5266 rows). The transform (`scripts/lib/per_page_masters.rb`)
> is a **final structural pass, self-gating**: a NO-OP unless ≥2 content pages use the
> master, so single-page and single-dashboard workbooks stay byte-identical to the
> shared-master build. **Default OFF** for one release — opt in per migration.

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

See `refs/chart-patterns.md` for chart patterns and multi-series formulas and map shapes; `refs/element-kinds.md` for per-kind field requirements and controls.

### 5a.1 Visible-dashboard coverage gate

Before workbook POST, `dashboard-coverage.rb` / `.py` reads the source TWB's
visible dashboard windows directly and compares them with the built Sigma page
names. In full-workbook mode, every non-empty visible dashboard is required. A
selected run may omit another visible dashboard only when
`dashboard-scope.json` records `mode:"selected"` with `provenance:"stated"` or
`"cli"`.

This gate is intentionally independent of `dashboard-layout.json`: a parser or
scope bug that omitted a tab from the layout cannot use that same omission as
proof that the tab was out of scope. Hidden parameter-host dashboards and truly
empty dashboard debris remain excluded; text-only visible dashboards remain
required. When `story-plan.json` exists, every in-scope story-point caption is
also a required Sigma page; until `build-story-pages.rb` has produced those
pages the gate stops rather than silently dropping the story.

### 5b. Validate the workbook spec

```bash
ruby scripts/validate-spec.rb --type workbook \
  --dm-context <WORK>/dm-ids.json \
  <WORK>/wb-spec.json
```

`--dm-context` lets the validator accept `[Order Fact/...]` cross-source refs (where
"Order Fact" is a DM element name from Phase 4). Without it, every cross-source ref is
flagged as unknown.

### 5c. POST the workbook + readback

```bash
ruby scripts/post-and-readback.rb --type workbook \
  --spec <WORK>/wb-spec.json \
  --out <WORK>/wb-ids.json
```

> **Element IDs may or may not survive POST.** Workbook-spec POST often preserves readable
> string element IDs verbatim, but this is not contractual. Data-model-spec POST always
> reassigns IDs. Either way, the readback is the source of truth — use IDs from `wb-ids.json`
> when wiring layout XML.

### 5d. Build layout XML (MANDATORY)

> **Skip this step and Sigma renders every tile as a single-column stack** —
> the CoCo regression (beads-sigma-bw3). `assert-phase6-ran.rb` gate 4
> rejects any workbook without a non-empty `layout` XML (`document.layout`
> in the current wrapped shape — see 5a).

**Preferred path — auto-layout from the parsed Tableau zone tree:**

```bash
ruby scripts/build-dashboard-layout.rb \
  --layout <WORK>/dashboard-layout.json \
  --wb-ids <WORK>/wb-ids.json \
  --out <WORK>/layout.xml
# If any chart tile was renamed from its Tableau title, pass the same
# --rename "Tableau name=Sigma name" pairs you give the parity scripts —
# otherwise the renamed tile silently drops out of the layout (bead ddbq).
# Row heights are scaled 1.5x by default (--row-scale) so Sigma doesn't
# suppress axis/pie labels on short tiles (bead tkkv); proportions are kept.

ruby scripts/put-layout.rb \
  --workbook <workbookId> \
  --layout <WORK>/layout.xml
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

> **PUT /v2/workbooks/{id}/spec wipes the `layout` string** (`document.layout`
> in the current wrapped shape). If you re-PUT the workbook spec after a
> formula fix (or any other spec edit), the existing layout is **erased** and
> the workbook reverts to a single auto-stacked column. Two ways to avoid the
> round trip:
> 1. **Preferred:** re-emit the layout XML in the same PUT body — set
>    `document.layout` to the assembled XML string before PUTting.
> 2. Or PUT layout separately AFTER spec via `scripts/put-layout.rb`. That
>    script GETs the spec, replaces just the layout field, and PUTs back. Cost:
>    one extra round trip (~5-15s) and an export to confirm.
>
> The OCT standalone conversion lost 18s on this round trip; document the
> pattern up front.

```ruby
# <WORK>/build-layout.rb
require 'json'
$LOAD_PATH.unshift File.expand_path('scripts/lib', __dir__)  # or absolute path
require 'layout'
include SigmaLayout

# Element IDs from Phase 5c
ids = JSON.parse(File.read('<WORK>/wb-ids.json'))
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

File.write('<WORK>/layout.xml', xml)
```

Layout helpers (in `scripts/lib/layout.rb`): `gc(eid, c0, c1, r0, r1, inner)` for
`<Container>`, `le(eid, c0, c1, r0, r1)` for `<Element>`, `page_xml(page_id, *children)`
to wrap a page, `assemble(*pages)` to add the XML prologue.

See `refs/layout-grid.md` for typical page layouts (4 KPIs + line chart + 2 bars,
multi-row containers, etc.) and rules (`<Container>` for nesting, KPI inner `gridRow`
must match container outer span).

### 5e. PUT the layout

```bash
ruby scripts/put-layout.rb \
  --workbook <workbookId> \
  --layout <WORK>/layout.xml
```

The script:
- GETs the current workbook spec,
- replaces per-page `layout` with a single `document.layout` (per-page layouts are silently dropped),
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

