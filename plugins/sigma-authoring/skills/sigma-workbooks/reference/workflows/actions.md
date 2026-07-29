# Actions — buttons, effects, and write-back workflows

Buttons wire a user click to one or more **effects** — insert rows into an
input table, reset a control, set a control's value, or open/close a modal.
They live in `elements[]` like any other element, not nested inside another
element.

## Button shape

```yaml
id: btn-log
kind: button
text: Log note
appearance: filled        # filled | outline
actions:
  - id: a-log
    trigger: on-click
    effects:
      - effect: insert-rows
        table: annotations
        values:
          an-note: { type: control, control: NoteCtl }
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | Element id. |
| `kind` | yes | Always `button`. |
| `text` | yes | Button label. |
| `appearance` | — | `filled` \| `outline`. |
| `actions` | yes | Array; each entry is `{ id, trigger, effects: [...] }`. `trigger: on-click` is the verified case (the OpenAPI also lists `on-select`/`on-primary-cta-click`/`on-secondary-cta-click`/`on-close` for other element/modal contexts — not exercised here). |

A button typically carries one `actions[]` entry with one or more `effects[]` —
effects in the same action run together off the same click.

## Verified effects

These three round-tripped and rendered correctly on a live test-org build:

### `insert-rows` — write a row into an input table

```yaml
effect: insert-rows
table: annotations             # an input-table element's id
values:
  an-note: { type: control, control: NoteCtl }
  an-tag:  { type: constant, value: { type: text, value: "manual" } }
```

`values` is a map of the input table's **own column ids** to a value descriptor:
- `{ type: control, control: <controlId> }` — the current value of a control.
- `{ type: constant, value: { type: text, value: <literal> } }` — a hard-coded
  literal.

**Never include a system column** (`ID`/`CREATED_AT`/`CREATED_BY`/`UPDATED_AT`/
`UPDATED_BY`) in `values` — Sigma auto-fills those; see *the append-only-log
pattern* below.

### `clear-control` — reset a control (page scope only)

```yaml
effect: clear-control
scope: { type: page, page: pg }
usePublishedValue: true
```

The OpenAPI's `scope` discriminator actually has **three** shapes —
`{ type: control, control: <controlId> }` (clear one control), `{ type:
container, container: <containerElementId> }` (clear every control in a
container), and `{ type: page, page: <pageId> }` (clear every control on a
page). **Only `page` scope is live-verified here** — an element/container-scoped
`clear-control` masked-failed the button in live testing (the button silently
didn't work; no clear error pointed at the cause). Until `control`/`container`
scope is independently re-verified, build resets around `page` scope only.

### `set-control-value` — set a control programmatically

```yaml
effect: set-control-value
control: RegionFilter
value: { type: constant, value: { type: text, value: "West" } }
```

The only verified `value` shape is a constant text value (e.g. a "quick filter
preset" button). Useful paired with a `list`/`segmented` control to give users a
one-click shortcut into a known filter state.

## Modals: `open-overlay` / `close-overlay`

A workbook page can be marked `type: modal` — a page that renders as an overlay
rather than a navigable tab. A button's effect opens/closes it:

```yaml
pages:
  - id: pg
    name: Main
    elements: [ ... , btn-open ]
  - id: modal-detail
    type: modal
    name: Detail
    elements: [ ... ]
```

```yaml
# on the trigger button (lives on the main page)
effect: open-overlay
overlayId: modal-detail    # the modal PAGE's `id`, not an element id

# on a close button (typically inside the modal itself)
effect: close-overlay
```

`open-overlay` requires `overlayId`; `close-overlay` takes no other fields (it
closes whatever overlay is open). **These two shapes are documented in the
compiled OpenAPI** (unlike `insert-rows`, which isn't inlined there as of this
writing) but were **not** part of this round's live-render probe — confirm with
a POST + PNG export before shipping a modal flow, same discipline as any other
shape in this doc.

## The append-only-log pattern

The recurring write-back shape: an **empty input table** as a log, a **control**
to capture what the user types, and a **button** that inserts a row.

```yaml
# 1. The entry control — see controls.md's "Entry (write) text controls" note:
#    these four fields are mandatory or the control masked-fails.
- id: note-ctl
  kind: control
  controlId: NoteCtl
  name: Add a review note
  controlType: text-area
  mode: equals
  case: insensitive
  includeNulls: when-no-value-is-selected
  showOperators: false

# 2. The button — inserts one row per click, reading the control's live value.
- id: btn-log
  kind: button
  text: Log note
  appearance: filled
  actions:
    - id: a-log
      trigger: on-click
      effects:
        - effect: insert-rows
          table: annotations
          values:
            an-note: { type: control, control: NoteCtl }

# 3. The log itself — an empty input table. System columns take NO `type` and
#    are auto-filled by Sigma (CREATED_AT/CREATED_BY) — never pass them in
#    insert-rows `values` above; doing so breaks the column.
- id: annotations
  kind: input-table
  inputMode: edit
  source: { kind: empty, connectionId: <WRITE_CONNECTION_ID> }
  columns:
    - id: an-note
      type: text
      name: Review note
    - id: CREATED_AT
    - id: CREATED_BY
```

Each click appends a new, timestamped, attributed row — nothing is ever
overwritten. This is the shape to reach for "log an action," "flag this record,"
or "leave a comment," anywhere a durable audit trail matters more than an
editable cell.

## Masked-error catalog

Sigma's spec validator returns the same opaque, unhelpful message for several
distinct root causes on these element kinds. If you hit one of these, check the
listed cause **first** before assuming the element kind itself is unsupported.

| Error | Real cause | Fix |
|---|---|---|
| `Invalid kind: "input-table"` | `inputMode` was omitted. | Always set `inputMode: edit` (or `explore`/`view` — see `input-tables.md`). It's technically documented as required in `tables.md`, but omitting it produces this generic message rather than a field-specific one. |
| `Invalid kind: "control"` (on a `text`/`text-area` control used for **entry**, not filtering) | One or more of `mode`, `case`, `includeNulls`, `showOperators` was omitted. | Set all four — see `controls.md`'s "Entry (write) text controls" section. |
| Button silently does nothing on click | An element/container-scoped `clear-control`. | Use `scope: { type: page, page: <id> }` only (see above). |

## Cross-links

- `shared/lib/actions.rb` / `actions.py` — `Actions.button(id:, text:, effects:,
  appearance:)`, `Actions.input_table_empty(id:, connection_id:, columns:,
  name:)`, `Actions.input_table_linked(id:, from:, connection_id:, columns:,
  name:)`, and the three effect builders `Actions.insert_rows_effect(table:,
  values:)` / `Actions.clear_control_effect(page:)` /
  `Actions.set_control_value_effect(control:, text:)` build exactly the shapes
  above (`inputMode: "edit"` always emitted; `clear_control_effect` only ever
  emits page scope). Gated behind `Actions::SURFACES`; a NO-GO flip returns
  `{opt_in: true, id:}` (element builders) or `{}` (effect builders) rather than
  a faked shape.
- `reference/specification/input-tables.md` — the write-connection requirement,
  the publish-before-query gate, and the linked-table cross-connection pattern.
- `reference/specification/controls.md` — full control-element field reference.
- `reference/specification/agents.md` — a write/action agent's `tools[].steps[]`
  reuses these same effect shapes, driven by agent input instead of a button
  click.
