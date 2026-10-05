# Composition: making the design choice

A workbook spec that compiles cleanly and has correct data can still be unusable. Layout, element choice, label clarity, whether to add a comparison vs current state — these are design decisions, not API ones. This skill provides verified geometric patterns and a small set of content-prescriptive archetypes as opinionated starting points — good defaults, not templates to apply blindly. Genuinely ambiguous structural choices (scope, audience, what to group or sort on, single- vs multi-page) still get punted to the user, exactly as before — see the ladder and the ask-section that follow.

## Calibrate scope to the request

Build the simplest workbook that fully answers the request. Let the ask set the complexity — not a template, and not a sense of what a dashboard "should" have. Both directions fail: a bare table dumped on a page when the user wanted a dashboard, and an unrequested multi-page layout with joins and a KPI row when the user asked for one number.

A rough sizing ladder (starting points, not rules):

- **A single thing** — "show total revenue", "a table of orders", "one KPI" →
  one element in a simple full-width layout. Current code representation
  requires `document.layout` even for one element; simplicity means one
  placement, not relying on auto-arrange.
- **A focused view** — "revenue over time with a region filter" → a few elements plus a control; light layout.
- **A dashboard** — "a sales dashboard", "an exec overview" → the fuller pattern is appropriate: a KPI row up top, one or two charts, a supporting table, controls, explicit layout XML, and the base/source table on a hidden page (see `visibility: hidden` in `reference/specification/schema.md`, and the master-detail pattern below for a worked example). This is the tier where polish is the point.

For concrete shapes at any tier, don't assemble from memory. Fetch a real workbook's spec (`GET /v2/workbooks/{id}/spec`, Steps 1–2) and read the relevant feature docs — a live spec shows current, valid, org-idiomatic structure, including the layout XML the OpenAPI doesn't model. Size up only when the request asks for it.

## When to stop and ask the user

Defer to the user any time the prompt admits more than one reasonable interpretation. Signals:

- **Open-ended request.** "Build me a sales dashboard" leaves dozens of decisions unmade — audience, time scope, level of detail, what decision the dashboard should support.
- **The data could be sliced multiple ways.** If revenue can be broken out by region OR product OR month OR channel and the prompt doesn't specify, pick the most-obvious one *and* surface that choice (see below) — but for a real ambiguity, just ask.
- **Page-shape ambiguity.** Single page or multi-page? Executive summary vs. operator detail? Don't guess if the answer changes the entire workbook.
- **You're about to make a structural decision the user can't easily revert.** Reordering elements is easy; deciding "this needs three pages" and threading sources across them is harder to undo.

When you do ask, keep it specific. "What would you like the dashboard to look like?" is useless. Better:

- *"Is this for an executive briefing or operator detail? Affects whether I use KPIs and ranked bars or a searchable detail surface."*
- *"Should this support a weekly meeting (current-state snapshot) or an investigation (drillable detail)?"*
- *"What decision should the viewer be able to make after looking at this?"*

## Surface your decisions in the final summary

Agents quietly choose: how many KPIs, which chart kinds, multi-page vs single, what to group on, what to sort by. The user can't see those choices from the rendered workbook alone. Always include a one-paragraph summary at the end of the run listing the structural choices you made and inviting redirection.

Example: *"Built a single-page dashboard with 4 KPIs across the top, a revenue-by-region ranked bar, and a supporting store-detail table. Used Sales Amount over Net Orders for the headline metric. Tell me if you want any of these changed — different KPI mix, multi-page split, a different sort, etc."*

## Patterns

Several layout patterns are wired into a shared composition engine
(`scripts/lib/composition.rb`). They take a flat array of elements — each
`{ id:, role: }` or `{ id:, kind: }` — and emit the `<Element
elementId="..." gridColumn="a / b" gridRow="c / d"/>` lines for a single
`<Page>`'s worth of layout XML. Wrap the engine's output in a `<Page
id="<pageId>" ...>` block, then place the assembled XML — one shared prolog
plus one `<Page>` block per page — in **`document.layout`**, NOT
`pages[].layout` (which silently no-ops and falls back to auto-arrange). See
`reference/specification/layout.md` for the `<Page>`/`<Container>` wrapper
and this document-level placement. Elements are grouped into horizontal
bands by `role`; a band with no elements is skipped and the next band simply
starts where the last one left off, so array order doesn't matter — only the
role tag does.

Role resolution: give an element an explicit `role:`, or let `kind:` infer one — `kpi-chart` → `:kpi`; `table` / `pivot-table` / `input-table` → `:table`; any other kind (every chart kind) defaults to `:supporting`. `:hero`, `:control`, `:insight`, `:master`, and `:detail` are **never** inferred — tag those explicitly. An untagged element infers to `:supporting` — `:exec` places that (merged into its final `:supporting`+`:table` band), but `:master_detail` does NOT: it only consumes `:control`, `:master`, and `:detail`, so an untagged (or explicitly `:kpi`/`:hero`/`:insight`/`:supporting`/`:table`) element passed to `:master_detail` is a role the pattern doesn't place.

An unrecognized explicit role raises (`compose: unknown role <x> for element <id>`) rather than silently dropping the element — and, separately, a *recognized* role the chosen pattern simply doesn't consume now raises too (`compose: role <role> (element <id>) is not used by pattern <pattern>`), e.g. tagging something `:master` and composing with `:exec`, or leaving something `:kpi`/untagged and composing with `:master_detail`. Neither case silently vanishes from the layout anymore.

Within a band, elements split the available width evenly by default (`band()`).
The element count in an even band must divide `page_cols` (default 24: 1, 2,
3, 4, 6, 8, 12, or 24 elements fit cleanly). When visual priority is
asymmetric, use a named split or explicit validated widths instead of
hand-writing column boundaries; the widths must match the element count and
sum to `page_cols`.

### Named horizontal splits and mosaic

`Composition.band(..., split:)` accepts `:full`, `:pair_16_8`,
`:pair_14_10`, `:pair_17_7`, `:pair_8_16`, `:pair_7_17`, `:halves`, and
`:trio`, or an explicit array of positive widths. Names describe widths on the
default 24-column grid; layout XML still uses one-based boundaries ending at
25. `Composition.compose(..., band_splits: { <band-role>: <split> })` applies
the same vocabulary to a selected pattern band while leaving every other band
at its existing default.

- `:full` — one element spanning all 24 columns.
- `:pair_16_8`, `:pair_14_10`, `:pair_17_7` (and their reversed forms) —
  primary/supporting pairs. Pick the ordering that puts the primary element on
  the intended side.
- `:halves` — only when both elements are true peers or the two halves are the
  same conceptual block.
- `:trio` — three true peers at 8/8/8.

For one deep view beside two shallow views, use
`Composition.mosaic(primary:, top_right:, bottom_right:, r0:)`. It emits the
primary at columns 1–15 for 16 rows, with two 10-column, 8-row elements stacked
at columns 15–25. This is a named composition, not a reason to put unrelated
charts into a decorative grid.

### `exec` — KPI-strip dashboard

Use this for the "dashboard" tier of the sizing ladder above: an exec overview, a sales dashboard, anything shaped like "a few headline numbers, one dominant chart, supporting detail." It is not the only shape a dashboard can take — it's the default starting point when nothing about the request argues for something else.

Operational generate-app workbooks are **not** this pattern. Classify via
`generate-apps.md` and compose from that type's job (the editable grid or
queue is the page). Do not wrap a planning/approval/allocation/exception
fixture in `pattern: :exec` + `Styling.header`, and do not substitute
`styling.md`'s command-center KPI-in-hero idiom as "the exception look."

Role → band, top to bottom (each optional; skipped if empty):

| Role | Band height | Notes |
|------|-------------|-------|
| `:control` | 2 | Filters for the page. Thin, full-width if one control; split evenly if several. |
| `:kpi` | 6 | The KPI strip — an even split across every `:kpi` element. This is the headline-numbers row. |
| `:insight` | 3 | Optional narrative/callout band (a text element, a small annotation) between the KPIs and the hero. |
| `:hero` | 12 | The dominant visual. Tag exactly **one** element `:hero`; multiple hero-role elements become a pair/row (even by default or according to `band_splits`) and no longer establish one focal point. |
| `:supporting` + `:table` | 13 | Merged into one final content band and split across whatever is left — enough height for a useful chart or roughly seven table rows. |

Call:

```ruby
require_relative 'scripts/lib/composition'

elements = [
  { id: 'kpi1', role: :kpi }, { id: 'kpi2', role: :kpi },
  { id: 'kpi3', role: :kpi }, { id: 'kpi4', role: :kpi },
  { id: 'hero', role: :hero }, { id: 'tbl', role: :table }
]
Composition.compose(elements, pattern: :exec)
```

produces a 4-up KPI strip (each 6 of 24 columns, row 1–7), a full-width hero
(row 7–19), and a full-width table (row 19–32) — the exact shape golden-tested
in `scripts/lib/testdata/composition_exec_golden.txt`.

### `master-detail` — pick one, see its detail

Use this when the request is shaped like "browse/pick from a list or chart, see the detail for the one selected" — a directory next to a drill-down table, "click a region to see its orders," an index/detail pairing. This is a different shape from `exec`: there's no KPI strip, just one selection surface and one surface that responds to it.

Role → band, top to bottom:

| Role | Band height | Notes |
|------|-------------|-------|
| `:control` | 2 | Optional thin, full-width row. If omitted, the master/detail band below starts at row 1 instead of row 3. |
| `:master` + `:detail` | 14 | Share one tall band, split evenly. With exactly one of each on the default 24-column grid, that's master at columns 1–13 and detail at 13–25. |

`:master` and `:detail` are resolved **only** from an explicit `role:` — never inferred from `kind:`. A bar chart or a table can be either side of this pattern (or neither, in a different pattern), so the engine can't guess which one is the selection surface.

Call:

```ruby
elements = [
  { id: 'ctl', role: :control },
  { id: 'master-chart', role: :master, kind: 'bar-chart' },
  { id: 'detail-tbl', role: :detail, kind: 'table' }
]
Composition.compose(elements, pattern: :master_detail)
```

(note the pattern name is the symbol `:master_detail`, underscore — the hyphen is only in prose) produces a full-width control row (row 1–3), then master at columns 1–13 and detail at columns 13–25 sharing row 3–17 — see `scripts/lib/testdata/composition_master_detail_golden.txt`. Drop the `:control` element and the master/detail band starts at row 1 instead.

**Critical semantics — verified live against a real Sigma org (2026-07-28), not just spec-shape-valid:**

- **The control filters the detail element only.** Wire it as a `filters[]` entry on the control pointing at the detail table — `{ source: { kind: table, elementId: <detail-element-id> }, columnId: <dimension-column> }` (see `reference/specification/controls.md`). Do not add the master to that `filters[]` array.
- **The master stays whole.** It is the selection surface the viewer picks from, not a filtered view of the current pick — it must keep rendering every category/row, not just the selected one. Live proof: setting the control's value and exporting the master still returns every category with its correct (unfiltered) totals. This is the intended shape, not a bug to "fix" by also filtering the master.
- **Put the underlying source table on a hidden page** (`pages[].visibility: hidden`, `reference/specification/schema.md`) and have both the master and the detail `source` from it via `elementId` — same rationale as any base table: it's plumbing the pattern needs, not a deliverable the viewer should see directly.
- **Selection-to-detail is spec-authorable.** Put an `on-select` action on the
  master and use `set-control-value` with a `[Selection/<Column>]` formula to
  update the stable-key control; a `set-single-row-container` effect can target
  a single-record detail surface directly. See `actions.md` → *Selection
  scope*. Keep the control → detail filter wiring above so exports and
  programmatic parameter tests use the same key. Verify the deployed click:
  schema acceptance alone does not prove the selected value reached the
  detail.

### `ledger` — find a record, then inspect it

Use this content archetype when the page's job is record lookup: a customer
directory, workbook catalog, asset list, case finder, or any request phrased as
“find/browse/search records.” This intent is specific enough to select
`:ledger` without asking the user to design the page geometry.

The content contract, top to bottom:

1. **Header:** a task title paired with one compact dynamic records chip. The
   chip uses `CountDistinct([<Source>/<declared grain key>])`, not `Count()`, so
   a source fanout cannot silently inflate the label.
2. **Toolbar:** lead with a `controlType: text`, `mode: contains`,
   `case: insensitive` search wired to the record-name column. Add secondary
   filters only when the request or data supplies a real lookup dimension.
3. **Results:** use a normal table today. Keep the name/stable key first and
   show no more than about ten visible columns; move the rest into detail.
4. **Detail:** put an `on-select` action on the results table. Set a stable-key
   control from `[Selection/<Key>]` and filter a detail table, or target a
   `single-row-container` with `set-single-row-container`.
5. **Trailing KPI strip:** use only domain-relevant totals or rates already
   implied by the request/data. Do not invent a generic three-status strip.

The table-to-control half is ordinary code representation:

```yaml
actions:
  - id: select-record
    trigger: on-select
    effects:
      - effect: set-control-value
        control: selectedRecord
        selectionMode: replace
        value: { type: formula, formula: "[Selection/Record ID]" }
```

Use the current OpenAPI shape for `set-single-row-container` when choosing that
detail surface; its effect requires `target` and `value`. Do not invent a
`rowClick` property on the table.

The published OpenAPI includes `repeated-container` with
`arrangement: list`, but bound child formulas still fail the release-contract
replay probe. Until that probe turns green, do not claim the “under 200 rows →
card feed” branch is code-authorable; use the table at every row count. Once
the probe passes create/readback/render, use list cards below 200 records and a
table at 200 or more.

`Composition.compose(elements, pattern: :ledger)` uses explicit roles:
`:ledger_header`, `:ledger_count`, `:ledger_toolbar`, `:ledger_results`,
optional `:ledger_detail`, and `:ledger_kpi`. The header/count and
results/detail bands can use named asymmetric splits; empty optional detail or
KPI bands collapse without leaving a hole.

### Operational app patterns

`workbench`, `queue_rail`, and `builder_preview` are asymmetric,
work-surface-first patterns for generate-app. They deliberately do not use
kind inference or even-split the primary row:

- `:workbench` — `:context` gets 8/24 columns and `:work_surface` 16/24;
- `:queue_rail` — `:queue` gets 17/24 and `:rail` 7/24;
- `:builder_preview` — `:builder` gets 7/24 and `:preview` 17/24.

Each optional side expands to full width when its partner is absent.
`:app_header`, `:action_bar`, `:summary`, and `:footer` provide the
surrounding bands supported by the relevant pattern. These roles are
explicit; passing a dashboard role such as `:kpi` or `:hero` raises instead
of silently dropping it.

Load [`app-compositions.md`](app-compositions.md) for the design manifest,
role/height tables, visual-language rules, and PNG failure gate. The semantic
planning/allocation/approval/exception fixture remains separate from the
visual pattern.

### Other defaults

Two general, pattern-independent authoring defaults still apply no matter which composition pattern (or none) is in play:

- **Use a ranked horizontal bar for categorical comparison.** “Top 10 stores by
  revenue” or “top products” is a chart-selection request, not permission to
  dump a generic sorted table. Sort a supporting detail/lookup table by the
  ranking metric when exact values or row-level inspection are also needed.
- **Don't expose intermediate/staging joins as visible elements.** A join or blend built only to feed other elements is plumbing, not a deliverable — keep it on a hidden page (or off the dashboard entirely), same rationale as a source/base table.

**Styling:** once a page is composed, apply a professional look on top — theme, chart color, KPI accent, number format, header/card containers — via the shared `Styling` module; see `reference/specification/styling.md`'s *Composition styling* section.

### Editorial pass

These are review rules, not hard schema validation. Migration fidelity and
purpose-built operational surfaces can justify an exception, but a
from-scratch page should not violate them accidentally.

- **Size by role.** Analytic content bands normally run 10–18 grid rows;
  headers, filters, dividers, and other strips run 2–6. Split an analytic band
  that grows past roughly 20 rows. The 22/24-row operational work surfaces are
  intentional exceptions because the grid/queue is the page's job.
- **Say and chart each thing once.** Lockup, eyebrow, title, and card label must
  each carry distinct information. Do not place two charts on the same page
  that encode the same measure at the same grain.
- **Size tables from visible rows.** Use
  `Composition.table_height(rows) = ceil(3 + rows × 4/3)`. Seven visible data
  rows recommend 13 grid rows; an 11-row span clips them.
- **Cap visible table width.** Above roughly ten visible columns, the first
  column and scan path degrade. Cut columns rather than widening the page; move
  secondary fields to the selection-driven detail surface.

## Richness — optional building blocks

Everything below is a **menu, not a fixed template.** Each capability is independent and
optional — usable alone, in any combination, or not at all. None of it is auto-applied:
offer what fits the request and let the user choose, the same calibrate/ask ethos as the
rest of this doc. This is not a clone of any one dashboard's branded look — no logos, no
imposed layout, no house style forced onto every workbook. Reach for these when the
request calls for polish; a plain KPI-and-chart page (composed with `:exec`, or with no
pattern at all) is still a completely valid answer on its own.

Each item below emits one spec fragment — via `scripts/lib/richness.rb` or the existing
`scripts/lib/kpi_card.rb` — that drops into whatever layout is already being built. None
of them assemble a whole page by themselves.

### Comparative KPI cards (+ optional value styling)

The house default for a KPI is comparative: a value column plus a `comparisonColumn`
rendered as a Δ badge (see `reference/specification/comparative-kpi-card.yaml` and
`KpiCard.build`). That comparison is itself optional — a plain single-value KPI is a valid,
simpler choice; calling `KpiCard.build` with no `comparison_column_id` emits a plain card,
no Δ badge.

On top of that, `KpiCard.build` takes two further optional kwargs —
`value_color:` / `value_font_size:` — that accent the number itself:
`value: {columnId: ..., color: '#FDE047', fontSize: 44}`. Leave both `nil` (the default)
and the emitted card is byte-identical to a call that never knew these kwargs existed.
Live-verified: the color renders as a genuinely distinct hue against the default black,
and the font-size change is directly measurable in the rendered PNG, not just accepted on
POST.

### AI-insight callout (opt-in, org-dependent)

`Richness.ai_insight(id:, model:, prompt:)` builds a `text`
element whose `body` is a Cortex-backed formula:

```
{{ Replace(CallText("SNOWFLAKE.CORTEX.COMPLETE", "<model>", "<prompt>"), '"', "") }}
```

`CallText`'s real signature is `CallText(<warehouse_function_name>, ...args)` — there is
**no separate connection argument**; it runs against the referenced column's own
element/connection. `llama3.1-8b` and `mistral-large2` are live-verified against Sigma's
own Sample Database Snowflake connection, returning genuinely generated (non-echoed)
sentences, not an echo of the prompt.

**Opt-in caveat, stated plainly:** this only renders real text where the target org has a
usable Cortex model configured on its own connection. Offer it, don't force it — and
never substitute a hand-written or faked summary sentence when an org's Cortex isn't
available; an unconfigured org just sees a blank or erroring element until Cortex is set
up there. Meant to sit in a light-tint container alongside the rest of the page, not as a
load-bearing element the rest of the dashboard depends on.

### Control-driven interactivity (optional)

Two independent, optional pieces, both reusing already-verified control shapes:

- **Dynamic grain.** `Richness.grain_control(id:)` emits a `segmented` Week/Month/Day
  control (default Month); `Richness.trend_dimension(grain_control_id:, date_ref:)`
  returns the matching dimension formula for a trend chart —
  `Switch([<id>],"Week",DateTrunc("week",<date_ref>),"Month",DateTrunc("month",<date_ref>),
  DateTrunc("day",<date_ref>))`. Live-verified: switching the control across Week/Month/Day
  changed the chart's exported bucket count exactly as expected (Month=3, Week=14, Day=90
  over 90 days of data).
- **Filter row.** `Richness.filter_row(controls:)` emits one or more `list` controls wired
  to a control → element `filters[]` binding — the same control-filters-target shape
  already verified for the master-detail pattern above, offered here as a standalone
  filter row rather than tied to one specific layout.

Use either, both, or neither — a page composed with no controls at all is just as valid a
choice as one with both.

### Wide pivot (optional)

`Richness.wide_pivot(id:, source_element_id:, rows_by:, values:, columns:)` emits a
`pivot-table` biased wide rather than crosstabbed: `columns` is the pivot's own column
definitions (required — see the tables.md pivot recipe), `rowsBy` takes the row shelves,
`columnsBy` is always `[]`, and `values` is a plain list of metric column-id strings (not
`{columnId: ...}` objects — matching the existing pivot shelf precedent). Grand totals are a UI-only
setting, not a spec field, so this helper doesn't emit or guess one. Reach for this when
the request wants a wide detail table rather than a small-multiple crosstab; a regular
table, or a pivot with `columnsBy` populated, are equally valid alternatives depending on
what's actually asked for.

### Composition pattern choice: `:overview` as one more option

`Composition.compose` (see *Patterns* above) offers a third pattern alongside
`:exec` and `:master_detail`: `pattern: :overview`, an optional stack of full-width bands,
each skipped if its role has no elements:

| Role | Band height | Notes |
|------|-------------|-------|
| `:header` | 3 | Optional title band. |
| `:control` | 2 | Optional filter row. |
| `:kpi` | 8 | Taller than `:exec`'s KPI band — room for a comparison badge and title without clipping. |
| `:kpi2` | 8 | Optional second KPI row (e.g. rate/percentage metrics kept visually distinct from the headline row). |
| `:trend` | 12 | A grain-driven or plain trend chart. |
| `:pivot` | 14 | A wide pivot or detail table. |
| `:base` | 9 | The base/source row — hide it if it's plumbing, not a deliverable, same convention as the rest of this doc. |

This is **one geometric composition choice** alongside `:exec`,
`:master_detail`, the record-lookup `:ledger`, and the operational patterns—
plus hand-placed layout XML when none fits. Nothing about a "dashboard"
request implies `:overview` specifically; pick whichever pattern's shape matches what was
actually asked for, or ask if that's ambiguous, same as the sizing ladder above.

### What's not here: in-card KPI sparkline (NO-GO)

A sparkline living inside a KPI card itself (title → value → Δ badge → mini trend line,
all one element) is **not currently spec-authorable.** Adding a real, non-aggregate date
dimension (e.g. `DateTrunc("month", [Src/Date])`) to a `kpi-chart`'s own `columns` — the
specific shape this round of testing targeted — still renders no line: the card shows
title, value, and the Δ badge only, with visible empty space where a spark would go.
Separately, `trend: {shape: "line"}` was **stripped outright on this readback**
(`kpi_trend: null`) — narrower than `kpis.md`'s existing claim that the bare `trend` field
alone "is accepted and persists on readback, but inert without a UI binding."

So: KPI cards in this menu are comparative (value + Δ badge), not comparative-with-spark.
If a trend needs to sit alongside a KPI, use a separate trend chart — the `:trend` band
above, or a supporting chart next to the KPI strip — rather than trying to author a
sparkline inside the KPI element itself.

This is a candidate for a later re-probe, not a closed question — other builds are
reported to achieve an in-card spark, plausibly through a data-model/Metrics-level
mechanism rather than the `kpi-chart` `trend` field tested here. Don't claim the in-card
spark works until a workbook built purely from spec (never opened in the editor) is shown
actually rendering one.

## Image-driven cases have their own composition guide

When the user provides a target screenshot or mockup, the design space is much narrower — the goal is structural fidelity to the image. See `reference/workflows/from-image.md` for the observation-first workflow that applies in that case.
