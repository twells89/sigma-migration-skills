# Controls

Recipe book for the control element family and the patterns that wire them up. The OpenAPI is the source of truth for every field; this file adds the wiring patterns it doesn't teach.

Controls are interactive filter elements — lists, date pickers, text inputs, sliders, etc. They live in the page's `elements` array alongside tables and charts, **not** nested inside them. The wiring (which column a control filters, which downstream elements respond) is the part the OpenAPI doesn't teach — that's what this file is for.

**Every `controlType` wires up the same way** (`controlId` + `filters`, below); they differ only in the widget and its (flat top-level) value fields. So treat the per-type sections below as illustrations of the *wiring*, **not a catalog of what's supported** — a `controlType` you don't see here works the same way. The set also grows over time, so get the current list from the spec rather than hardcoding it:

```bash
jq -r '[.. | objects | select(.properties?.controlType?.enum) | .properties.controlType.enum[0]] | unique[]' /tmp/sigma-api.json
```

## Control Element Fields

A `control` element has exactly these fields:

| Field | Required | Notes |
|---|---|---|
| `kind` | yes | Always `control` |
| `id` | yes | Element ID — must be unique on the page |
| `controlId` | yes | Formula reference name (e.g., `RegionFilter`) — keep distinct from `id`. This is the human-meaningful handle used when referring to the control's value from formulas. |
| `controlType` | yes | Any value the recipe above returns. Determines the widget and filter behavior. |
| `filters` | — | Array of `{ source, columnId }` — connects the control to the column(s) it filters. `source` is `{ kind: table, elementId: ... }`. |
| `source` | list/segmented | Where the widget's VALUE LIST comes from. Double-nested: `{ kind: source, source: { kind: table, elementId: ... }, columnId: ... }`. |
| `mode` | list | `include` \| `exclude`. **Flat top-level field.** |
| `selectionMode` | list | `single` \| `multiple`. **Flat top-level field.** |
| `values` | list | Default selection (`[]` = all). **Flat top-level field.** |
| `parameters` | — | Array, for binding the control to a data-model control (parameter). |
| `name` | — | Display label. |
| `style` | — | Presentation options for the widget. |

The value/widget fields (`mode`, `selectionMode`, `values`, range bounds, etc.) are **flat top-level siblings of `controlType`**, NOT nested in a separate "value object" — verified against a live workbook 2026-06-15. Different `controlType`s carry different value fields (the per-type recipes below show which), but they are always flat. Omitting them — or nesting them — yields the opaque `Invalid kind: "control"` rejection.

`filters[]` items are `{ source: { kind: table, elementId: ... }, columnId: ... }`. The `columnId` is the column on the target element to filter.

---

## List

A single- or multi-select list control over a column's values.

```yaml
kind: control
id: ctrl-region          # element id — distinct from controlId
controlId: region        # formula handle
name: Store region
controlType: list
mode: include            # include | exclude   (TOP-LEVEL, not nested)
selectionMode: multiple  # single | multiple   (TOP-LEVEL)
values: []               # default selection, [] = all   (TOP-LEVEL)
source:                  # where the control's VALUE LIST comes from (note the double nesting)
  kind: source
  source:
    kind: table
    elementId: sales-master
  columnId: col-region
filters:                 # the TARGETS it filters — one entry per element+column it controls
  - source:
      kind: table
      elementId: sales-by-region
    columnId: scoped-col-region
```

> **Verified working shape** (pulled from a live, successfully-POSTed workbook 2026-06-15). A list control carries `source` / `mode` / `selectionMode` / `values` as **flat top-level siblings** — NOT inside a nested "value object." The single most common mistake is omitting `source`/`mode`/`selectionMode`/`values` (or nesting them); Sigma then rejects the element with the opaque catch-all `Invalid kind: "control"`, which means **the inner fields are wrong, NOT that controls are unsupported** (see `reference/workflows/validate.md`). `segmented` and `hierarchy` are the other list-style widgets — same wiring (value-list `source` + `filters` targets).

> **A control cannot bind to a map element** (`point-map` / `region-map` / `geography-map`). Pointing a list control's `source` (value list) or a `filters[]` target at a map element fails the POST with `Dependency not found: '<mapElementId>'` (live-verified 2026-06-26). Back the control with a real `table` element (e.g. a small dimension/directory table on the same column) for both the value list and the filter target. To also scope the map, filter it indirectly (e.g. drive the map's source element off the same filtered table, or apply the predicate in the data model) rather than targeting the map element directly.

## Date Range

A date-range control filters one or more date columns. The widget shape is determined by `mode`, and each mode takes different additional fields — all of them **flat top-level siblings of `controlType`** (verified against a live workbook 2026-06-15; a nested `value:{mode,unit}` object is rejected with `Invalid kind: "control"`). No `source` is needed — the column is defined by the `filters` binding.

```yaml
kind: control
id: ctrl-date
controlId: DateFilter
name: Date range
controlType: date-range
filters:
  - source:
      kind: table
      elementId: sales-table
    columnId: col-date
```

`mode` and its parameters are flat top-level fields. `includeNulls`: `always` | `never` | `when-no-value-is-selected`.

### Modes

| Mode | Extra fields | Use for |
|---|---|---|
| `between` | `startDate?`, `endDate?` (ISO 8601) | Inclusive range. Both fields optional — omitting them shows the picker with no preset. |
| `last` | `value` (number), `unit`, `includeToday` (bool) | "Last N days/weeks/months." |
| `next` | `value`, `unit`, `includeToday` | "Next N days/weeks/months." |
| `current` | `unit` | "This year/quarter/month/week/day." |
| `on` | `date` (ISO 8601) | Exact date match. |
| `before` | `date` | Strictly before a fixed date. |
| `after` | `date` | Strictly after a fixed date. |
| `custom` | `startDate`, `endDate` (each: ISO string OR `{ op, unit, value }` for relative) | Mixed fixed/relative bounds. |

`unit` values: `year`, `quarter`, `month`, `week-starting-sunday`, `week-starting-monday`, `day`, `hour`, `minute`.

For relative `startDate` / `endDate` shapes (used in `custom` mode):

```yaml
op: now-minus
unit: day
value: 30
```

`op`: `now-minus` or `now-plus`.

### Mode Examples

These show the flat fields each `mode` carries — all top-level siblings of `controlType` (shown without the wrapping control element for brevity).

**Last 70 days:**

```yaml
mode: last
value: 70
unit: day
includeToday: true
```

**This quarter:**

```yaml
mode: current
unit: quarter
```

**Fixed range:**

```yaml
mode: between
startDate: "2026-01-01"
endDate: "2026-03-31"
```

**Last 90 days through today (custom mode with relative bounds):**

```yaml
mode: custom
startDate:
  op: now-minus
  unit: day
  value: 90
endDate:
  op: now-minus
  unit: day
  value: 0
```

## Text

Single-line text filter. (`text-area` is the multi-line variant — same wiring, different widget.)

```yaml
kind: control
id: ctrl-search
controlId: SearchText
name: Search
controlType: text
filters:
  - source:
      kind: table
      elementId: sales-table
    columnId: col-product-name
```

The text control carries the match `mode` and the search string as flat top-level fields. `mode` values include `equals`, `does-not-equal`, `contains`, `does-not-contain`, `starts-with`, `ends-with`, `like`, `matches-regexp`, and their negations.

### Entry (write) text controls — 4 fields are mandatory

The `text`/`text-area` shape above is for **filtering** a downstream column. A
`text`/`text-area` control used the other way — capturing free-typed input for
a formula or an action effect's `values` (e.g. a "review note" field feeding an
`insert-rows` effect, see `reference/workflows/actions.md`'s append-only-log
pattern) — needs **four additional flat fields** or the element **masked-fails**
as the opaque `Invalid kind: "control"`, which reads like the control kind itself
is broken:

```yaml
kind: control
id: note-ctl
controlId: NoteCtl
name: Add a review note
controlType: text-area          # or: text
mode: equals
case: insensitive
includeNulls: when-no-value-is-selected
showOperators: false
```

| Field | Value (verified) | Notes |
|---|---|---|
| `mode` | `equals` | Same field name as the filter-mode above; `equals` is the verified entry-control value. |
| `case` | `insensitive` | Case sensitivity for the (unused, in an entry context) match. |
| `includeNulls` | `when-no-value-is-selected` | Same enum as the date-range control's `includeNulls`. |
| `showOperators` | `false` | Hides the operator picker — this control is for typing a value, not building a filter expression. |

No `filters` binding is needed on an entry control used this way — its value is
read via `{ type: control, control: <controlId> }` from wherever it's
consumed (an action effect's `values`, a formula), not wired to filter another
element's column.

## Number Range

```yaml
kind: control
id: ctrl-amount
controlId: AmountFilter
name: Amount
controlType: number-range
filters:
  - source:
      kind: table
      elementId: sales-table
    columnId: col-amount
```

The number-range control expresses the bounds with flat top-level `low`, `high`, and an optional `step` — **not** a positional `values: [min, max]` array and **not** a nested value object.

## Sliders

`slider` and `range-slider` are both first-class `controlType` values — distinct from `number` and `number-range`. A `slider` is a single-handle widget; `range-slider` has two handles for a low/high band. The bounds and value are **flat top-level fields** (verified against a live, UI-built workbook and a successful POST, 2026-06-15) — there is no value object.

A **single-handle `slider`** carries the track bounds (`low`/`high`), a `mode` comparator describing which rows the handle keeps, and a **scalar** `value` for the handle position:

```yaml
kind: control
id: ctrl-deal-size
controlId: DealSize
name: Deal size
controlType: slider
low: 0
high: 100000
mode: "<="          # comparator: <= | >= | = | < | > — rows kept relative to the handle
value: 33755        # scalar handle position (FLAT — not a value object)
includeNulls: when-no-value-is-selected
filters:
  - source:
      kind: table
      elementId: sales-table
    columnId: col-amount
```

A **`range-slider`** drops the scalar `value`/`mode` and uses the two-handle `low`/`high` band:

```yaml
controlType: range-slider
low: 0
high: 100000        # flat low/high band; no scalar value
filters:
  - source:
      kind: table
      elementId: sales-table
    columnId: col-amount
```

> A nested `value:{low,high}` object is rejected with `Invalid kind: "control"`. The most common slider mistake is omitting `mode` — without the comparator the element is rejected even though `low`/`high`/`value` are present.

## Single-value types

`number`, `date`, `checkbox`, and `switch` are single-value controls. `checkbox` and `switch` are the boolean widgets — same value (a boolean), different presentation:

```yaml
kind: control
id: ctrl-active-only
controlId: ActiveOnly
name: Active only
controlType: switch
filters:
  - source:
      kind: table
      elementId: users-table
    columnId: col-is-active
```

## Top-N

`top-n` is a dedicated control type for "show the top N" interactions. Wire it like any other control via `filters`; the cap is a flat top-level field.

---

## One Control, Multiple Elements

A control's `filters` array can hold **multiple bindings** — one per element/column the control should filter. This is the right tool for a page-level filter that applies to several tables or charts at once. Don't make a separate control per element.

```yaml
kind: control
id: ctrl-region
controlId: RegionFilter
name: Store region
controlType: list
filters:
  - source: { kind: table, elementId: sales-table }
    columnId: col-region
  - source: { kind: table, elementId: returns-table }
    columnId: col-region
  - source: { kind: table, elementId: sales-by-region }
    columnId: col-region
```

Each binding names the target element by `elementId` and the column on that element to filter by `columnId`. The column IDs do **not** need to match across elements; they just need to exist on each target element.

## One Element, Multiple Controls

The dual pattern, and a common Sigma layout: a parent table that several controls filter, with downstream elements (KPIs, charts, secondary tables) sourcing from the parent. Filter once at the parent — every element that sources it inherits the filter automatically.

```yaml
# Parent: "sales-table". Downstream KPIs/charts source from it.
# Three controls each filter the parent on a different column.

- kind: control
  id: ctrl-region
  controlId: RegionFilter
  controlType: list
  filters:
    - source: { kind: table, elementId: sales-table }
      columnId: col-region

- kind: control
  id: ctrl-date
  controlId: DateFilter
  controlType: date-range
  filters:
    - source: { kind: table, elementId: sales-table }
      columnId: col-date

- kind: control
  id: ctrl-amount
  controlId: AmountFilter
  controlType: number-range
  filters:
    - source: { kind: table, elementId: sales-table }
      columnId: col-amount
```

Multiple controls on the same target compose with **AND** — selecting region "West" + date "Q1" narrows to the intersection. Prefer this over binding each control to every downstream element; it's less repetitive and keeps the filter chain in one place.

## Tip: `controlId` vs `id`

They are not the same and both are required:
- `id` is the element ID used internally and in `layout.md`.
- `controlId` is a human-facing handle used when referring to this control's value from formulas or downstream logic. Pick it to be meaningful (e.g., `RegionFilter`, `DateRange`).
</content>
</invoke>
