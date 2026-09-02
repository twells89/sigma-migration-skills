# Domo card → Sigma element mapping

This is the **Phase 5 chart map**: how each Domo card becomes a Sigma workbook
element. The single most important rule is at the top — it is the one that has
bitten every Domo migration so far.

> **Authoritative signal is the PNG.** The Domo `chartType` string narrows the
> choice, but the per-card render (`discovery/png/cards/<cardId>.png`) is what
> you decide from. Read it before you pick an element kind. A tile that shows
> one big number is a KPI **no matter what the underlying card type is.**

---

## ⭐ Rule 0 — Summary Number → Sigma **KPI**, never a table

**Every Domo visualization card — including a Table card — carries a "Summary
Number":** a single aggregate value (column + aggregation + label + number
format) rendered large at the top of the tile. Authors routinely build what
*looks* like a KPI tile by dropping a table (or bar/line) card on the dashboard
and letting the prominent Summary Number carry the meaning. Domo can also size
the tile so only that number shows.
(See [Configuring Your Chart Summary Number](https://knowledge.domo.com/Visualize/Adding_Cards_to_Domo/KPI_Cards/KPI_Card_Building_Part_2%3A_The_Analyzer/07Configuring_Your_Chart_Summary_Number).)

Sigma has no "table that displays as a summary number" mode. If you port such a
card as a Sigma **table**, you get an ugly one-row (or many-row) grid where the
customer expected a big number. **This is the #1 fidelity complaint.** Emit a
`kpi-chart` instead.

### When to emit a KPI (either tier)
Treat a card as a KPI if **any** of these hold:
- The rendered PNG shows **a single large number** as the tile's content
  (with maybe a small label / secondary figure) — this is the decisive signal.
- The Domo card type is a **Single Value** card (Single Value Gauge, "Summary
  Number" card) — `chartType` tokens seen: `badge`, `singlevalue`, `summary`.
- It's a **table/chart card that is displayed on the dashboard as its Summary
  Number** — i.e. the card's Summary Number is enabled and the tile is small /
  the rows aren't the point.

When in doubt between KPI and a 1-row table, **choose KPI.** A KPI that should
have been a table is a smaller error than the reverse (which is what shipped).

### What to pull from the Summary Number config (Tier A card def)
The card definition's summary-number block gives you everything a Sigma KPI
needs — do **not** re-derive it. The confirmed paths (Shape A `Component`):
| Domo summary-number field | Confirmed path | Use for Sigma KPI |
|---|---|---|
| summary value column | `summaryNumber.columns[].column` | the value column |
| aggregation (`SUM`/`AVG`/`COUNT`/`MIN`/`MAX`/…) | `summaryNumber.columns[].aggregation` | wrap the column in the matching Sigma aggregate (`Sum`/`Avg`/`Count`/…) — **but see the COUNT-of-id rule with the shape block below** |
| label | `summaryNumber.columns[].alias` | the KPI `name` |
| number format (currency / percent / abbreviated / decimals) | `summaryNumber.columns[].format` | the KPI column `format` (see number-format map below) |

On **Tier B** (PNG only), read the number, its label, and its format straight
off the render, and infer the aggregate from the label ("Total …" → Sum,
"Avg …" → Avg, "# of …" / "Count of …" → Count).

### Sigma KPI element shape (verified live on aws-api, 2026-06)
```jsonc
{
  "id": "<eid>",
  "kind": "kpi-chart",
  "name": "Total Sales",                          // the summary-number label
  "source": { "elementId": "m-master", "kind": "table" },
  "columns": [
    { "id": "v-total-sales",
      "formula": "Sum([Master/Sales Amount])",    // summary MEASURE wrapped in its aggregate, WITH source prefix
      "name": "Total Sales",
      "format": { "type": "number", "decimalPlaces": 0 } }
  ],
  "value": { "columnId": "v-total-sales" }         // ⚠ columnId, NOT id
}
```

> **A KPI's value is the summary number's `aggregation` applied to its `column` —
> NEVER `Count` of the row-key/id. Domo TABLE cards default their summary number
> to `COUNT` of the bound (usually id/first) column; if the extracted
> summaryNumber has `aggregation: COUNT` on an id-like key
> (`_defaultCountSuspect: true` from discovery), treat it as Domo's default and
> use the card's authored measure instead.**
>
> The formula MUST carry the source prefix — `Sum([<Source>/Measure])`, e.g.
> `Sum([Master/Sales Amount])`. A bare `Count([id])` with no prefix is Sigma's
> **#1 KPI error** (and doubly wrong here: it counts a row-key, not a measure).

Load-bearing details (each has burned a prior build):
- **`value` takes `{"columnId": …}`, not `{"id": …}`.** Posting `value.id` is
  rejected at POST (`value.columnId: Invalid string: undefined`). Donut/pie use
  `value.id`; KPI is the exception. See `feedback_sigma_kpi_value_columnid`.
- **Hide the title** when the Domo tile has no label (or you want the number to
  dominate): set `"name": " "` — a single space. `""` re-derives a title from
  the column. See `feedback_sigma_kpi_hide_title`.
- **Give KPI tiles enough height.** `kpi-chart` auto-hides its title below
  ~5 grid rows (~150px); size KPI elements ≥ that in Phase 5d or the label
  silently disappears. See `feedback_sigma_kpi_label_height`.
- A row of Domo summary tiles → a **row of individual `kpi-chart` elements**,
  one per number, laid side by side (not one multi-column table).

### ⚠️ The sparkline / trend — set expectation, do NOT downgrade
A common field-feedback ask: a Domo summary number with a little trend spark. **Sigma's
`kpi-chart` trend sparkline + period comparison are UI-only bindings on this
org/API — they do not render from the workbook spec** (the `trend`/`comparison`
objects carry formatting only, and `columns[].sparkline` is stripped on
readback). See `sigma-kpi-trend-comparison-ui-only`.

So:
- **Still emit the KPI.** Missing spark support is **not** a reason to fall back
  to a table — a plain KPI number is far closer to the source than a grid.
- If the source tile had a spark/trend, add a Phase-5e warning: *"KPI '<name>':
  Domo showed a trend sparkline — bind the trend column in the Sigma editor
  (spec cannot carry it)."* Do not silently drop it and do not fake it with a
  table.

### Companion KPI — a Summary Number beside a chart/table, not instead of it (bead 08sf)

Rule 0 above covers the card where the Summary Number **is** the whole card
(no real grouping, ≤1 column) — that becomes a `kpi-chart` and nothing else.
But Domo also prints a Summary Number above a card that **is** a genuine
chart or table — a bar chart with a real `groupBy`, say, still shows a big
"Total Sales" number above its bars. Sigma's chart/table elements have no
summary slot to carry that, so the fix is a **second, separate `kpi-chart`
element** — a companion — built from the *same* Summary Number config Rule 0
uses (same measure/aggregation/format resolution, including the COUNT-of-id
guard), rather than replacing the primary chart/table. The companion's `id`
is always the primary element's `id` + `-summary` so it never collides. If
the card's own primary chart/table element itself fails to build (e.g. no
resolvable measure), the companion is dropped too — a standalone KPI with no
primary beside it would be confusing, not a fix. When no resolvable column
exists for the companion (independent of whether the primary built), the
headline value is dropped with a named warning rather than silently emitted
as a broken `Count([Master/])`.

**Layout placement:** `build-domo-layout.rb` gives the companion its own zone.
When source geometry is known (API geometry or `layout-observed.json`), the
companion and its primary chart are nested in one source-card container, with
the summary above the plot just as Domo renders it. When geometry is unknown,
the fallback kind-aware composition still places companions in a shared KPI
band; that fallback is intentionally reasonable rather than presented as
pixel-faithful.

### Row limit → Sigma top-n filter (bead 2ef7)

A Domo card's row **limit** ("Top 25 by revenue") has no query-level analog
in Sigma — porting the card without translating it just renders every
warehouse row instead of the limited set (live-validated: 872 rows instead of
25). The fix is an **element-level `top-n` filter**:
```jsonc
"filters": [{
  "id": "topn-<elementId>", "columnId": "<first measure column id>",
  "kind": "top-n", "rankingFunction": "rank", "mode": "top-n", "rowCount": 25
}]
```
- Ranked by the **first measure column** on the element (mirrors the
  existing "sort by first measure" convention used for axis-chart x-axis
  sorting).
- Sigma's top-n `rowCount` is a **descending-only, static number literal** —
  it cannot bind to a control, and an *ascending* Domo `orderBy` has no
  equivalent, so it is left alone rather than silently reversed.
- No measure column on the element → nothing to rank by → no filter is
  emitted (never a `columnId: nil` filter).

### One sub-master per non-dominant DataSet (bead ziht)

Domo cards on the same page are frequently bound to **different DataSets** —
a customer-dimension card sitting next to an order-fact chart. Every element
this converter builds sources a single shared `master` table, built from
whichever DataSet the page's cards use most (the **dominant** DataSet). A
card bound to any *other* DataSet references columns `master` doesn't have —
posting it unmodified 400s the **entire** workbook (`Dependency not found:
'master/region'`, live-validated).

The fix: resolve the card's own DataSet to its **live Sigma data-model
element** (via the posted DM's readback, `dm-ids.json`, cross-referenced with
`dm-spec.json`'s `_datasetId` tags) and build it a **hidden sub-master** —
the same auto-passthrough shape (every column of the live element, by name)
the primary `master` gets, named `master-<datasetId>`. The card's element is
then retargeted: its `source.elementId` points at the sub-master instead of
`master`, and every `[Master/...]` formula reference is rewritten to
`[<sub-master name>/...]`. One sub-master per non-dominant DataSet **actually
used** by a card — not one per DataSet in the data model.

The sub-master itself is not a page element a user would browse to; it is
carried through `chart-specs.json`'s top-level **`data_elements`** key and
must land on the workbook's Data page alongside `master` (both the live
`build-workbook-spec.rb` path and `migrate-domo.rb --offline`'s local
assembly fold this key in) — a visible element retargeted to it would
otherwise reference an id that doesn't exist on any page.

When no live data-model element is yet resolvable for the card's DataSet
(no `dm-ids.json`/`dm-spec.json` pair posted yet), the card is **skipped with
a named warning** instead of silently mis-bound to the wrong master — rebuild
it by hand, or re-run once the data model has posted.

---

## Full card-type → element map

**The card's top-level `type` is almost always `"kpi"`** — that is Domo's umbrella
type for analyzer viz cards, NOT a signal that the tile is a single number.
Worse, **`type` itself is not stable across API surfaces**: the public `GET
/v1/cards` reports `type: "chart"` for the exact same card the private API
reports `type: "kpi"` for. **Never key an element-kind decision on `type`.** The
real viz kind lives in **`metadata.chartType`** (private read) / `chartType`
(public create body) — key on that instead.

### ⚠️ `chartType` is a STRICT enum — exact-match it, never substring

Live validation (2026-07-30) probed Domo's `ChartType` enum exhaustively by
creating real cards. **It rejects unknown values outright** — `POST
/v1/cards/chart` 400s with `No enum constant com.domo.phoenix.model.ChartType.
<token>` for a bad token. That means two things for this map:

1. **Every token below is either a confirmed-valid enum value or explicitly
   flagged as fabricated** — nothing here is a guessed naming convention anymore.
2. **Substring matching is actively harmful**, not just imprecise:
   `badge_line_bar` is a **combo** chart, but contains the substring
   `badge_line`, which a `*line*` substring rule sends straight to `line-chart`.
   `badge_symbol_bar` is also a combo (bar + symbol overlay), but contains
   `_bar`, which a `*bar*` substring rule sends to a plain `bar-chart`. Both are
   wrong element kinds shipped confidently. **Exact-match the full token**
   against the table below.

**The documented fallback for an unmapped token:** fall back to whatever
upstream extraction's own best-effort kind hint says; if that's also absent or
unrecognized, emit a `bar-chart` and a loud Phase-5e warning naming the card and
the raw `chartType` string so a human verifies it against the PNG — **never
guess silently and never drop the card.** (`scripts/build-workbook.rb`'s
`chart_kind_for`/`CHART_TYPE_MAP` implement exactly this: exact match →
upstream hint → warned bar-chart default.)

### Four previously-documented tokens do not exist

This map used to carry `badge_datagrid`, `badge_pivottable`, `badge_stackedarea`,
and `badge_line` as "plausible-but-unconfirmed" tokens. Probing card creation
proved all four are **invalid** — `ChartType` has no such members:

| Documented (WRONG) | Verdict | Real token |
|---|---|---|
| `badge_datagrid` | ❌ invalid | `badge_table` |
| `badge_pivottable` | ❌ invalid | none confirmed yet — see note below |
| `badge_stackedarea` | ❌ invalid | none confirmed yet — see note below |
| `badge_line` | ❌ invalid | `badge_symbolline` / `badge_curved_symbolline` / `badge_trendline` |

If a card in extracted data carries one of these four, **that is an upstream
extraction bug** (or stale/synthetic test data) — `build-workbook.rb` flags it
loudly rather than mapping it, and the extraction path should be checked.
Neither a valid pivot-table nor a valid stacked-area `ChartType` token has been
observed yet (live or via probing); don't invent one — if/when a real instance
produces a pivot or area-family card, capture the actual token before adding a
row for it.

### The verified map (exact match on the full token)

Every token below has been observed accepted by Domo — either by creating a
card with it directly, or as a real `metadata.chartType` value on a live
instance (2026-07-30 validation, 48 cards / 22 distinct chartTypes). Sigma
`kind` strings are verified against the `sigma-workbooks` skill
(`plugins/sigma-authoring/skills/sigma-workbooks`) unless noted otherwise.

| `chartType` (exact) | Sigma `kind` | Verified? | Notes |
|---|---|---|---|
| `badge_vert_bar` | `bar-chart` | ✅ kind verified | vertical, `stacking: none`. |
| `badge_horiz_bar` | `bar-chart` | ✅ kind verified | `orientation: horizontal`. |
| `badge_vert_stackedbar` | `bar-chart` | ✅ kind verified | `stacking: stacked`. |
| `badge_vert_multibar` | `bar-chart` | ✅ kind verified | grouped/clustered, `stacking: none`. |
| `badge_horiz_multibar` | `bar-chart` | ✅ kind verified | `orientation: horizontal`, `stacking: none`. |
| `badge_horiz_100pct` | `bar-chart` | ✅ kind verified | `orientation: horizontal`, `stacking: normalized` (Sigma's percent-stacked variant — the literal string is `normalized`, NOT `"100"`). |
| `badge_vert_nestedbar` | `bar-chart` | ⚠️ approximated | Sigma's cartesian axis has no native 2-level nested category shelf; degrades to a flat grouped bar (the outer grouping tier is lost) — warned, not silent. |
| `badge_symbolline` | `line-chart` | ✅ kind verified | line with point markers; marker styling itself is a chart-style detail, not a distinct kind. |
| `badge_curved_symbolline` | `line-chart` | ✅ kind verified | curved/smoothed variant — same kind as above; curve styling is a line-style detail. |
| `badge_trendline` | `line-chart` | ✅ kind verified | single metric over time. |
| `badge_two_trendline` | `line-chart` | ✅ kind verified | two series on one line chart. |
| `badge_xyscatterplot` | `scatter-chart` | ✅ kind verified, **confirmed live by card creation** | both axes are measures; see `sigma-workbooks/reference/specification/charts.md` — a scatter must bind to a **grouping**, or every point collapses to one x. |
| `badge_bubble` | `scatter-chart` | ✅ kind verified | scatter + `size` channel; bind the `BUBBLESIZE`-mapped column to `size`. |
| `badge_pie` | `pie-chart` | ✅ kind verified | Sigma has a **distinct** `pie-chart` kind (not just `donut-chart`) — `value`+`color`, no hole/holeValue/innerRadius. `value` uses `value.id` (NOT `columnId`) — opposite of a KPI. `pie-chart` does **not** support native `trellis` (silently stripped) — emit `donut-chart` if faceting is required. |
| `badge_donut` | `donut-chart` | ✅ kind verified, **confirmed live by card creation** | same `value`/`color` shape as pie, plus optional `holeValue`/`innerRadius`. Supports native `trellis`. |
| `badge_singlevalue` | `kpi-chart` | ✅ kind verified, **confirmed live by card creation** | Rule 0. |
| `badge_table` | `table` | ✅ kind verified, **confirmed live by card creation** | the REAL table token — `badge_datagrid` does not exist. |
| `badge_map` | `region-map` (default) | ✅ kind verified, ⚠️ per-card judgment | Sigma's real map kinds are `geography-map` / `point-map` / `region-map` — a bare `map` kind is **confirmed invalid** (rejected `400`). This converter defaults to `region-map` and infers `regionType` (`country` / `us-state` / `us-county` / `us-zipcode` / `us-cbsa` / `ca-province`) from the geography column's name; when it can't classify the column (a custom territory code, a non-US subdivision, etc.) it degrades honestly to a table + warns rather than emit a broken map spec. A lat/long pair should use `point-map` instead — not currently auto-detected. |
| `badge_line_bar` | `combo-chart` | ✅ kind verified, **confirmed live by card creation** | bar + line combo. First measure → `bar` series, second → `line` series (Domo's enum doesn't say which is which; this is a documented heuristic, flagged if the measure count isn't 2). `yAxis2` needed only if the two series need different scales. |
| `badge_line_stackedbar` | `combo-chart` | ✅ kind verified | line + **stacked** bar combo — same series heuristic, plus `stacking: stacked` on the bar side. |
| `badge_symbol_bar` | `combo-chart` | ✅ kind verified | bar + a `scatter`-shaped symbol series (not a plain bar — the `_bar` substring is a trap here). |
| `badge_treemap` | `bar-chart` | ❌ **no native equivalent** | see below. |
| `badge_word_cloud` | `table` | ❌ **no native equivalent** | see below. |
| `badge_calendar` | `table` | ❌ **no native equivalent** | see below. |
| `badge_filledgauge` | `progress` or `kpi-chart` | ✅ conditional released mapping | Emit ring `progress` only when explicit `CURRENT` + `TARGET` roles ground value/max and no card-local filter/date window would be lost; otherwise retain KPI + warn. |
| `badge_pop_bar_line` | `combo-chart` | ❌ **no native equivalent** | see below. |
| `badge_vert_symbol_overlay` | `combo-chart` | ❌ **no native equivalent** | see below. |

### No native Sigma equivalent — do not silently substitute a bar chart

Five observed tokens have **no true Sigma equivalent**. `CHART_TYPE_MAP` in
`build-workbook.rb` still names the closest honest degradation (never a bare,
unexplained bar chart), and `build_element` **always** emits a specific, loud
Phase-5e warning naming the card and the gap — this is a hard requirement, not
a nice-to-have:

| `chartType` | Why Sigma has no match | Closest honest degradation |
|---|---|---|
| `badge_treemap` | No `treemap` kind was found anywhere in the sigma-workbooks skill (not in its documented kinds, and not in the confirmed-invalid list either — it is simply **unverified**; do not assume it exists). | `bar-chart`, sorted descending by measure — keeps relative magnitude, loses the area-proportional hierarchy. |
| `badge_word_cloud` | No word-cloud kind exists. | A flat term + frequency `table`. |
| `badge_calendar` | No calendar-heatmap kind exists. | A flat date + value `table`. |
| `badge_pop_bar_line` | Sigma has no automatic period-over-period comparison primitive. | `combo-chart` (bar = current period, line = prior period) — the two periods must be modeled as two explicit measures; the automatic date-shift is lost. |
| `badge_vert_symbol_overlay` | No actual-vs-target dial/overlay kind exists (and `gauge` itself is invalid — see above). | `combo-chart` (bar + a `scatter` marker series) approximates the visual; a true actual-vs-target dial is not representable. |

**Follow-up, not handled by this converter today:** closing this gap for real —
a genuine treemap, word cloud, calendar heatmap, or unsupported dial rendered in
Sigma — is a candidate for a **Sigma custom plugin** (see the
`sigma-plugin-development` skill for how those are built). That is tracked as
future work, not something `build-workbook.rb` attempts; its job is to degrade
honestly and warn loudly, never to silently ship a bar chart in place of a
gauge.

### Still using PNG + judgment (not yet a confirmed `chartType` token)

These card types have not been observed with a confirmed live `chartType`
token, so a substring-free exact match isn't possible for them yet — fall back
to the PNG:

| Domo card (what the PNG shows) | Sigma element `kind` | Notes |
|---|---|---|
| Heatmap | `pivot-table` w/ conditional format | Sigma has no standalone `heatmap` kind (confirmed invalid). |
| Funnel / Sunburst / Sankey | closest Sigma kind + **warn** | No grounded released mapping in this converter; treat like the no-native-equivalent table above. |
| Waterfall | reviewed fallback + **warn** | Sigma now publishes `waterfall-chart`, but this converter has no confirmed Domo `chartType` token and role payload for it. Do not guess a token or emit native waterfall from PNG appearance alone. |
| Text / Title card | text element | |
| Image / logo / drawing (static asset, no data columns) | `image` | Inline data-URI: `{id, kind:'image', url:"data:image/png;base64,<b64>"}` from the staged capture (`discovery/png/cards/<cardId>.png`, written by `domo-capture-visuals.rb`'s `capture_card`/`render_card_png`; `card['_pngPath']` overrides). No hosting needed — mirrors the tableau pattern (`build-charts-from-signals.rb:6655`); PNG/JPEG data-URIs POST + render cleanly. **Do not** also key off "no data columns + a staged PNG exists" — capture-visuals renders a PNG for every card on a page (filter widgets, text/title cards included), so that combination silently misroutes non-image cards. `richtext` is excluded (stays a text element — see the Text/Title row above). Tier B / PNG not captured, or chartType doesn't match → falls back to the text-placeholder path + a Phase-5e warning ("export from Domo UI and embed manually") — never ship an empty/broken image element. |

These rows key on substrings of `chartType` (`image`/`logo`/`drawing`/`picture`,
`text`/`title`) as a still-unconfirmed heuristic for a **different signal**
than the analyzer viz enum above — Domo's static-asset/text cards may not even
route through the same `ChartType` enum family, so this is deliberately kept
separate rather than folded into the exact-match table.

If a Domo `chartType` isn't in any table above, **read the PNG, pick the
nearest Sigma kind, and emit a Phase-5e warning** — never guess silently (see
fidelity discipline below).

### Column → visual-role binding (`main.columns[].mapping`)

Live validation confirmed each column on a card's `main` subscription carries a
**`mapping`** field binding it to a visual role — use this to bind axes/series
instead of guessing by position or by aggregation presence. Confirmed
vocabulary (10 values): `ITEM` (category/x), `VALUE` (measure), `SERIES`
(split/color), `XTIME`, `BUBBLESIZE`, `CATEGORY`, `CURRENT`, `TARGET`, `DATE`,
`EVENT`. `CURRENT`/`TARGET` together strongly imply a gauge/progress visual (see
`badge_filledgauge` above). `build-workbook.rb`'s `split_cols` honors `mapping`
per-column when present, falling back to the aggregation/groupBy heuristic for
any column that doesn't carry one.

### 6-column grid → Sigma's 24-column grid

Domo's card grid (`preferredFullWidth`/`preferredFullHeight` on the create API)
is **6 columns wide**, confirmed by the write-path enum (`1..6`; a `12` is
rejected with *"height and width must have values between 1 and 6"*). Sigma's
layout grid is 24 columns, so **the scale factor is 4×**, not 1×. (Layout itself
is owned by `build-domo-layout.rb`/`lib/layout.rb` — this is documented here
because it's a load-bearing fact about the same card records this map
consumes, not a layout-builder change.)

---

## Domo bar chart → Sigma **bar-chart**, NOT a table with data bars

Reported bug: a Domo bar chart came out as a Sigma **table with in-cell data
bars**. These are two different things — don't substitute one for the other.

- A **real bar chart** has `chartType` exactly `badge_vert_bar`,
  `badge_horiz_bar`, `badge_vert_stackedbar`, `badge_vert_multibar`,
  `badge_horiz_multibar`, or `badge_horiz_100pct` — see the verified map above.
  Emit a Sigma **`kind: bar-chart`** with `xAxis` / `yAxis` bindings
  (orientation/stacking per the exact token — `sigma-bar-orientation-and-datelookback`).
  This is the correct target.
- Sigma **table data bars** (`kind: table` + `conditionalFormats[].type:
  dataBars`) are reserved **only** for a real Domo `badge_table` card that has
  in-cell bars via its own `conditionalFormats[]` (see
  `sigma-table-databars-spec`; `badge_datagrid` is NOT a valid token — see the
  fabricated-tokens note above). Detect that case from the Domo card's
  `conditionalFormats[]`, not from the fact that the data would "fit" in a table.
- **Never substitute a table+dataBars for a bar chart.** A grid where the source
  showed bars is a fidelity failure (checked in the Phase 5e QA list below).

---

## Formatting fidelity

Three reported bugs, all formatting, all spec-settable:

### Column display names (bug #4)
Raw snake_case column names come through when the author's clean label is
ignored. Use the Domo **alias** as the display name, in this priority order:
- **Shape A:** `chartBody.columns[].alias` / `summaryNumber.columns[].alias`.
- **Shape B:** the equivalent alias on `definition.subscriptions.main.columns[]`.
- **Fall back** to the raw `column`, then run it through
  `format_sigma_display_name` (snake_case → Title Case) only as a last resort.

Never emit the raw `column` when an `alias` exists.

### Table text wrap (bug #5)
Long-text table cells that overflow are fixable in the spec — this is **not**
UI-only. Set it per-column or via the theme default:
- Per column: `columns[].style.textWrap: "wrap"` (enum `wrap | clip`).
- Theme default: `settings.theme.overrides.tableStyles.textStyles.*.textWrap`.

Set `"wrap"` on long-text columns so they don't clip.

### Axis / gridline defaults (bug #8)
Domo charts render visually clean; Sigma's defaults show gridlines and axis
labels, so a faithful port looks busier than the source. Default new charts to:
- **Gridlines off:** `xAxis.format.marks: "none"` and `yAxis.format.marks:
  "none"` (enum `none | tick | grid | both`).
- **Match the source's axis-label visibility:** if Domo hid a label, set
  `format.labels: "hidden"` (or `format.visibility: "hidden"`) on that axis.

Only turn marks/labels back on where the source PNG actually showed them.

---

## Filtering fidelity

Feedback: *"filtering got better in some places but not others."* The cause is
inconsistent handling of the two filter levels — port **both**, every time:

1. **Page/dashboard filters** (Domo "Page Filters" / filter cards) → Sigma
   **workbook controls**, bound to the target element(s). A control that targets
   a viz can silently no-op — bind the control to a **table** element or the
   underlying source, not directly to a KPI/bar (see
   `feedback_sigma_control_filter_target_must_be_table`).
2. **Card-level filters** (the filter clauses inside each card definition) →
   element/source filters on that element. Translate the Domo filter object
   (`{column, operator, values}`; operators `IN/NOT_IN/EQUALS/…/BETWEEN/CONTAINS`
   — see `refs/connection.md`) to a Sigma filter. Remember **`IN` → a chain of
   `or` equalities** — Sigma has no `IsIn` (`feedback_sigma_formula_isin`); a raw
   `IN` silently blanks the column.

Watch the known silent-drop traps so a filter doesn't vanish:
- **pivot-table** element filters are silently dropped — apply the filter on the
  source instead (`feedback_sigma_pivot_filter_silently_dropped`).
- A top-N / element filter on a source element **propagates** to dependents
  (`feedback_sigma_source_element_filter_propagates`) — place it deliberately.

After build, **diff the filter inventory**: every Domo page filter and every
card filter clause should have a corresponding Sigma control or element filter.
List any you dropped and why — never drop silently.

---

## Fidelity discipline — no "taking liberties"

Feedback: *"taking liberties in some places."* The build must **reproduce**, not
redesign. Rules:
- **One Domo card → one Sigma element.** Don't merge, split, drop, or invent
  cards. If a card can't be represented, emit it as the nearest kind **and warn**
  — don't quietly omit it or replace it with something prettier.
- **Keep the source's numbers, labels, and formats.** Pull the label and number
  format from the card def / PNG; don't relabel or reformat to taste.
- **Match layout weight from the captured geometry** (`discovery/cards.json`'s
  x/y/w/h, via `discovery/dashboard-layout.json`), not an equal-weight
  auto-grid — the hero viz keeps its size.
- Every deviation from the source (unsupported chart kind, dropped filter,
  UI-only spark) goes in the **Phase 5e warnings list**, surfaced to the user.
  A migration with 6 honest warnings beats one that silently took liberties.

---

## Phase 5e QA checklist additions (Domo-specific)

Add these to the mandatory layout-visual-qa gate:
- [ ] **Every Domo summary-number tile has a Sigma `kpi-chart`** — count them in
      the source PDF and count `kpi-chart` elements in the spec; they must match.
      Zero KPIs when the source has summary tiles = **fail**.
- [ ] No Sigma **table** element stands where the Domo tile showed a single
      number.
- [ ] **No KPI's value formula is `Count` / `CountDistinct` of the DM primary /
      row-key column** — that's Domo's default summary aggregate, not the authored
      measure (see the COUNT-of-id rule under Rule 0).
- [ ] **Filter fan-out:** every element on a page responds to each page control —
      no element is left un-bound (a control silently no-ops if not wired to it).
- [ ] Every Domo page filter → a Sigma control; every card filter → an element
      filter (filter-inventory diff is clean).
- [ ] **No Sigma `table` + `dataBars` stands where the Domo card was a bar
      chart** — a `badge_*bar*` card must be a `bar-chart` (see the bar-vs-table
      rule above).
- [ ] **Long-text table columns carry `textWrap: "wrap"`** (bug #5) so cells
      don't clip.
- [ ] **Chart axes default to `format.marks: "none"`** (gridlines off) unless the
      source PNG actually showed gridlines (bug #8).
- [ ] Any KPI that had a Domo spark/trend carries a "bind trend in UI" warning.
- [ ] **`chartType` was matched EXACTLY**, never by substring — spot-check a
      `badge_line_bar` (combo) and a `badge_symbol_bar` (combo) card didn't get
      mis-routed to `line-chart` / `bar-chart` respectively.
- [ ] Every card whose `chartType` is one of the five no-native-equivalent tokens
      (`badge_treemap`, `badge_word_cloud`, `badge_calendar`,
      `badge_pop_bar_line`, `badge_vert_symbol_overlay`) carries a Phase-5e
      warning naming the gap — never a silent, unexplained bar chart.
- [ ] Every `badge_filledgauge` either has explicit `CURRENT` + `TARGET` roles
      and emitted native `progress`, or carries the named KPI-fallback warning.
