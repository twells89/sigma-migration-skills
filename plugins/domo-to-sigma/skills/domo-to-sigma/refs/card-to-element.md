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

---

## Full card-type → element map

**The card's top-level `type` is almost always `"kpi"`** — that is Domo's umbrella
type for analyzer viz cards, NOT a signal that the tile is a single number. The
real viz kind lives in the **`chartType`** string, and those tokens are
**`badge_`-prefixed** (`badge` is a *universal prefix* on analyzer chart tokens,
not a standalone single-value token). Officially confirmed tokens:
`badge_vert_bar` (vertical bar) and `badge_xyscatterplot` (scatter). The others
below (`badge_horiz_bar`, `badge_datagrid`, `badge_line`, `badge_pie`, …) are
**plausible-but-unconfirmed** naming conventions.

**Detect on the SUBSTRING, not an exhaustive enum.** Key off the substrings
`*bar*`, `*line*`, `*pie*`, `*scatter*`, `datagrid`/`table`,
`singlevalue`/`summary` inside the `chartType` string. The PNG stays
authoritative; use this table to translate once you've read the image.

| Domo card (what the PNG shows) | `chartType` substring / token | Sigma element `kind` | Notes |
|---|---|---|---|
| **Single big number** (see Rule 0) | `singlevalue`, `summary` (e.g. `badge_singlevalue`) | `kpi-chart` | Rule 0. |
| **Table** (rows are the point) | `datagrid`, `table` (e.g. `badge_datagrid`) | `table` | Only when the grid itself is the content, not a summary number. |
| **Pivot table** | `pivot` (e.g. `badge_pivottable`) | `pivot-table` | Needs both `rowsBy` **and** `columnsBy` — see `feedback_sigma_pivot_rowsby_columnsby`. |
| Bar (vertical) | `badge_vert_bar` ✓ **confirmed** (`*bar*`) | `bar-chart` | orientation vertical. |
| Bar (horizontal) | `badge_horiz_bar` (`*bar*`) | `bar-chart` | set horizontal orientation — see `sigma-bar-orientation-and-datelookback`. |
| Line | `*line*` (e.g. `badge_line`) | `line-chart` | |
| Area / stacked area | `*area*` (e.g. `badge_stackedarea`) | `area-chart` | |
| Combo (bar + line) | `combo`, `barline` | `combo-chart` | explicit `yAxis2`; `columnIds` a subset — see `sigma-combo-dual-axis`. |
| Pie / Donut | `*pie*` (e.g. `badge_pie`) | `donut-chart` | value uses `value.id` (NOT `columnId`) — opposite of KPI. |
| Gauge (dial) | `gauge`, `dialgauge` | `kpi-chart` | Sigma has no dial; render as KPI + note the gauge target as a follow-up. |
| Scatter / Bubble | `badge_xyscatterplot` ✓ **confirmed** (`*scatter*`, `bubble`) | `scatter-chart` | both axes measures; dimension → color. |
| Heatmap | `heatmap` | `pivot-table` w/ conditional format, or `heatmap` if available | confirm element support. |
| Funnel / Waterfall / Treemap / Sunburst / Sankey | various | closest Sigma kind + **warn** | Sigma may lack an exact match; pick nearest and flag in Phase 5e, don't silently substitute. |
| Text / Title card | `text`, `title` | text element | |
| Image / logo / drawing (static asset, no data columns) | `image`, `logo`, `drawing`, `picture` (substring, on `chartType` **only**) | `image` | Inline data-URI: `{id, kind:'image', url:"data:image/png;base64,<b64>"}` from the staged capture (`discovery/png/cards/<cardId>.png`, written by `domo-capture-visuals.rb`'s `capture_card`/`render_card_png`; `card['_pngPath']` overrides). No hosting needed — mirrors the tableau pattern (`build-charts-from-signals.rb:6655`); PNG/JPEG data-URIs POST + render cleanly. **Do not** also key off "no data columns + a staged PNG exists" — capture-visuals renders a PNG for every card on a page (filter widgets, text/title cards included), so that combination silently misroutes non-image cards. `richtext` is excluded (stays a text element — see the Text/Title row above). Tier B / PNG not captured, or chartType doesn't match → falls back to the text-placeholder path + a Phase-5e warning ("export from Domo UI and embed manually") — never ship an empty/broken image element. |
| Map (geo) | `map`, `choropleth` | Sigma map element if available, else table + warn | |

If a Domo `chartType` substring isn't in this table, **read the PNG, pick the
nearest Sigma kind, and emit a Phase-5e warning** — never guess silently (see
fidelity discipline below).

---

## Domo bar chart → Sigma **bar-chart**, NOT a table with data bars

Reported bug: a Domo bar chart came out as a Sigma **table with in-cell data
bars**. These are two different things — don't substitute one for the other.

- A **real bar chart** has `chartType` = a `badge_*bar*` token (e.g.
  `badge_vert_bar`, `badge_horiz_bar`). Emit a Sigma **`kind: bar-chart`** with
  `xAxis` / `yAxis` bindings (orientation per
  `sigma-bar-orientation-and-datelookback`). This is the correct target.
- Sigma **table data bars** (`kind: table` + `conditionalFormats[].type:
  dataBars`) are reserved **only** for a real Domo `badge_datagrid`/table card
  that has in-cell bars via its own `conditionalFormats[]` (see
  `sigma-table-databars-spec`). Detect that case from the Domo card's
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
- Theme default: `themeOverrides.tableStyles.textStyles.*.textWrap`.

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
- **Match layout weight from the captured geometry** (`discovery/layout/…`),
  not an equal-weight auto-grid — the hero viz keeps its size.
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
