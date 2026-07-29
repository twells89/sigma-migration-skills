# Composition: making the design choice

A workbook spec that compiles cleanly and has correct data can still be unusable. Layout, element choice, label clarity, whether to add a comparison vs current state — these are design decisions, not API ones. This skill used to claim no opinions on any of that; it now has two verified composition patterns (below) as opinionated starting points — good defaults, not templates to apply blindly. Genuinely ambiguous structural choices (scope, audience, what to group or sort on, single- vs multi-page) still get punted to the user, exactly as before — see the ladder and the ask-section that follow.

## Calibrate scope to the request

Build the simplest workbook that fully answers the request. Let the ask set the complexity — not a template, and not a sense of what a dashboard "should" have. Both directions fail: a bare table dumped on a page when the user wanted a dashboard, and an unrequested multi-page layout with joins and a KPI row when the user asked for one number.

A rough sizing ladder (starting points, not rules):

- **A single thing** — "show total revenue", "a table of orders", "one KPI" → one element. Skip explicit layout XML; auto-arrange is fine for a single element or a uniform stack of tables.
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

- *"Is this for an executive briefing or operator detail? Affects whether I use KPIs at top or a ranked detail table."*
- *"Should this support a weekly meeting (current-state snapshot) or an investigation (drillable detail)?"*
- *"What decision should the viewer be able to make after looking at this?"*

## Surface your decisions in the final summary

Agents quietly choose: how many KPIs, which chart kinds, multi-page vs single, what to group on, what to sort by. The user can't see those choices from the rendered workbook alone. Always include a one-paragraph summary at the end of the run listing the structural choices you made and inviting redirection.

Example: *"Built a single-page dashboard with 4 KPIs across the top, a revenue-by-region bar chart, and a ranked store table sorted descending by revenue. Used Sales Amount over Net Orders for the headline metric. Tell me if you want any of these changed — different KPI mix, multi-page split, a different sort, etc."*

## Patterns

Two layout patterns are wired into a shared composition engine (`shared/lib/composition.rb`, with a byte-identical Python twin `shared/lib/composition.py`). Both take a flat array of elements — each `{ id:, role: }` or `{ id:, kind: }` — and emit the `<LayoutElement elementId="..." gridColumn="a / b" gridRow="c / d"/>` lines for a single `<Page>`'s worth of layout XML. Wrap the engine's output in a `<Page id="<pageId>" ...>` block, then place the assembled XML — one shared prolog plus one `<Page>` block per page — in the **workbook-top-level `layout` field**, NOT `pages[].layout` (which silently no-ops and falls back to auto-arrange). See `reference/specification/layout.md` for the `<Page>`/`<GridContainer>` wrapper and this workbook-level placement. Elements are grouped into horizontal bands by `role`; a band with no elements is skipped and the next band simply starts where the last one left off, so array order doesn't matter — only the role tag does.

Role resolution: give an element an explicit `role:`, or let `kind:` infer one — `kpi-chart` → `:kpi`; `table` / `pivot-table` / `input-table` → `:table`; any other kind (every chart kind) defaults to `:supporting`. `:hero`, `:control`, `:insight`, `:master`, and `:detail` are **never** inferred — tag those explicitly. An untagged element infers to `:supporting` — `:exec` places that (merged into its final `:supporting`+`:table` band), but `:master_detail` does NOT: it only consumes `:control`, `:master`, and `:detail`, so an untagged (or explicitly `:kpi`/`:hero`/`:insight`/`:supporting`/`:table`) element passed to `:master_detail` is a role the pattern doesn't place.

An unrecognized explicit role raises (`compose: unknown role <x> for element <id>`) rather than silently dropping the element — and, separately, a *recognized* role the chosen pattern simply doesn't consume now raises too (`compose: role <role> (element <id>) is not used by pattern <pattern>`), e.g. tagging something `:master` and composing with `:exec`, or leaving something `:kpi`/untagged and composing with `:master_detail`. Neither case silently vanishes from the layout anymore.

Within a band, elements split the available width evenly (`band()`, the same helper both patterns use) — the element count in any one band must evenly divide `page_cols` (default 24: 1, 2, 3, 4, 6, 8, 12, or 24 elements fit cleanly). An uneven count raises `ArgumentError` (Ruby) / `ValueError` (Python) rather than producing a lopsided or clipped layout — pick a clean count, or drop to hand-written layout XML for an odd one.

### `exec` — KPI-strip dashboard

Use this for the "dashboard" tier of the sizing ladder above: an exec overview, a sales dashboard, anything shaped like "a few headline numbers, one dominant chart, supporting detail." It is not the only shape a dashboard can take — it's the default starting point when nothing about the request argues for something else.

Role → band, top to bottom (each optional; skipped if empty):

| Role | Band height | Notes |
|------|-------------|-------|
| `:control` | 2 | Filters for the page. Thin, full-width if one control; split evenly if several. |
| `:kpi` | 6 | The KPI strip — an even split across every `:kpi` element. This is the headline-numbers row. |
| `:insight` | 3 | Optional narrative/callout band (a text element, a small annotation) between the KPIs and the hero. |
| `:hero` | 12 | The dominant visual. Tag exactly **one** element `:hero` — `band()` will split the width evenly across *however many* `:hero` elements you pass, so more than one turns this into side-by-side heroes rather than one dominant chart. |
| `:supporting` + `:table` | 9 | Merged into one final band and split evenly across whatever's left — secondary charts and the detail table together. |

Call:

```ruby
require_relative 'shared/lib/composition'

elements = [
  { id: 'kpi1', role: :kpi }, { id: 'kpi2', role: :kpi },
  { id: 'kpi3', role: :kpi }, { id: 'kpi4', role: :kpi },
  { id: 'hero', role: :hero }, { id: 'tbl', role: :table }
]
Composition.compose(elements, pattern: :exec)
```

produces a 4-up KPI strip (each 6 of 24 columns, row 1–7), a full-width hero (row 7–19), and a full-width table (row 19–28) — the exact shape golden-tested in `shared/lib/testdata/composition_exec_golden.txt`.

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

(note the pattern name is the symbol `:master_detail`, underscore — the hyphen is only in prose) produces a full-width control row (row 1–3), then master at columns 1–13 and detail at columns 13–25 sharing row 3–17 — see `shared/lib/testdata/composition_master_detail_golden.txt`. Drop the `:control` element and the master/detail band starts at row 1 instead.

**Critical semantics — verified live against a real Sigma org (2026-07-28, `shared/scripts/verify-master-detail-e2e.rb`), not just spec-shape-valid:**

- **The control filters the detail element only.** Wire it as a `filters[]` entry on the control pointing at the detail table — `{ source: { kind: table, elementId: <detail-element-id> }, columnId: <dimension-column> }` (see `reference/specification/controls.md`). Do not add the master to that `filters[]` array.
- **The master stays whole.** It is the selection surface the viewer picks from, not a filtered view of the current pick — it must keep rendering every category/row, not just the selected one. Live proof: setting the control's value and exporting the master still returns every category with its correct (unfiltered) totals. This is the intended shape, not a bug to "fix" by also filtering the master.
- **Put the underlying source table on a hidden page** (`pages[].visibility: hidden`, `reference/specification/schema.md`) and have both the master and the detail `source` from it via `elementId` — same rationale as any base table: it's plumbing the pattern needs, not a deliverable the viewer should see directly.
- **Clicking the master to set the control's value is a manual UI step — there is no spec node for it.** The spec-authorable half of this pattern is only the control → detail `filters[]` binding above; "clicking a mark sets a control's value" has no representation in the workbook spec and has to be wired by hand in the Sigma UI after the workbook is built. (For automated verification instead of a manual click, the control's value can be driven programmatically through the export API's `parameters` map — see `reference/workflows/validate.md` — but that's a test-time convenience, not a substitute for the real UI interaction.)

### Other defaults

Two general, pattern-independent authoring defaults still apply no matter which composition pattern (or none) is in play:

- **Sort ranked tables by the ranking metric, descending.** "Top 10 stores by revenue" or "top products" implies ranking by the metric in view, highest first — sorting alphabetically by name is rarely what the request meant.
- **Don't expose intermediate/staging joins as visible elements.** A join or blend built only to feed other elements is plumbing, not a deliverable — keep it on a hidden page (or off the dashboard entirely), same rationale as a source/base table.

**Styling:** once a page is composed, apply a professional look on top — theme, chart color, KPI accent, number format, header/card containers — via the shared `Styling` module; see `reference/specification/styling.md`'s *Composition styling* section.

## Richness — optional building blocks

Everything below is a **menu, not a fixed template.** Each capability is independent and
optional — usable alone, in any combination, or not at all. None of it is auto-applied:
offer what fits the request and let the user choose, the same calibrate/ask ethos as the
rest of this doc. This is not a clone of any one dashboard's branded look — no logos, no
imposed layout, no house style forced onto every workbook. Reach for these when the
request calls for polish; a plain KPI-and-chart page (composed with `:exec`, or with no
pattern at all) is still a completely valid answer on its own.

Each item below emits one spec fragment — via `shared/lib/richness.rb` (Ruby canonical,
byte-identical `shared/lib/richness.py` twin) or the existing `shared/lib/kpi_card.rb`/
`.py` — that drops into whatever layout is already being built. None of them assemble a
whole page by themselves.

### Comparative KPI cards (+ optional value styling)

The house default for a KPI is comparative: a value column plus a `comparisonColumn`
rendered as a Δ badge (see `refs/kpi-comparison.md` and `KpiCard.build`/`kpi_card.build`).
That comparison is itself optional — a plain single-value KPI is a valid, simpler choice;
calling `KpiCard.build` with no `comparison_column_id` emits a plain card, no Δ badge.

On top of that, `KpiCard.build`/`kpi_card.build` takes two further optional kwargs —
`value_color:` / `value_font_size:` — that accent the number itself:
`value: {columnId: ..., color: '#FDE047', fontSize: 44}`. Leave both `nil` (the default)
and the emitted card is byte-identical to a call that never knew these kwargs existed.
Live-verified: the color renders as a genuinely distinct hue against the default black,
and the font-size change is directly measurable in the rendered PNG, not just accepted on
POST.

### AI-insight callout (opt-in, org-dependent)

`Richness.ai_insight(id:, model:, prompt:)` / `richness.ai_insight(...)` builds a `text`
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

`Richness.wide_pivot(id:, source_element_id:, rows_by:, values:)` emits a `pivot-table`
biased wide rather than crosstabbed: `rowsBy` takes the row shelves, `columnsBy` is always
`[]`, and `values` is a plain list of metric column-id strings (not `{id: ...}` objects —
matching the existing pivot precedent). Grand totals are a UI-only setting, not a spec
field, so this helper doesn't emit or guess one. Reach for this when the request wants a
wide detail table rather than a small-multiple crosstab; a regular table, or a pivot with
`columnsBy` populated, are equally valid alternatives depending on what's actually asked
for.

### Composition pattern choice: `:overview` as one more option

`Composition.compose`/`compose` (see *Patterns* above) offers a third pattern alongside
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

This is **one composition choice among three** (`:exec`, `:master_detail`, `:overview`) —
plus hand-placed layout XML when none of the three fits. Nothing about a "dashboard"
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
