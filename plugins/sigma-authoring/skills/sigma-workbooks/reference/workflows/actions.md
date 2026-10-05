# Actions — buttons, effects, and write-back workflows

Buttons wire a user click to one or more **effects** — insert rows into an
input table, reset a control, set a control's value, or open/close a modal.
They live in flat `document.elements[]`; layout places them.

> **Action identifier fields — which ones carry an `Id` suffix.** The
> 2026-08-26 rename gave identifier properties the referenced resource type
> plus an `Id` suffix. Verified by A/B creates plus `GET .../spec` readback
> diffs against a live org. The renamed ones are documented per-effect below;
> what follows is the part that is easy to get wrong.
>
> **These were deliberately NOT renamed.** The bare name is still the only
> accepted spelling and the `*Id` form is **rejected** — so don't "regularise"
> them for consistency:
>
> | still bare | not this |
> |---|---|
> | `set-control-value.control` | ~~`controlId`~~ |
> | `navigate` `target: {type: page, page:}` | ~~`pageId`~~ |
> | `refresh-element` `target: {type: element, element:}` | ~~`elementId`~~ |
> | value source `{type: control, control:}` | ~~`controlId`~~ |
>
> Note `clear-control`'s scope *does* use `controlId`, while
> `set-control-value` keeps a bare `control`. That asymmetry is real, not a
> documentation slip.

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
        tableElementId: annotations
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
effects in the same action run together off the same click. On the wire, actions
are stored at the workbook level but read and written **projected onto their
host element**, so you author them inline on the element as shown. Every
sequence entry requires a stable `id` — unique across the workbook's actions,
preserved verbatim across read and write.

### Hosts and their triggers

Which trigger a host accepts, confirmed 2026-08-08 against the live OpenAPI
(`CommonElement` variants — grep each element kind for an `actions` property):

| Host | Trigger |
|---|---|
| `button` element | `on-click` |
| `image` element | `on-click` |
| `table`, `pivot-table`, `kpi-chart`, and every chart/map kind **except `waterfall-chart`** | `on-select` |
| Modal/drawer overlay (`document.overlays`) | `on-primary-cta-click`, `on-secondary-cta-click`, `on-close` |

> **`waterfall-chart` has no `actions` property in the current OpenAPI** — every
> other chart and map kind (bar/line/area/scatter/combo/pie/donut charts, point/
> region/geography maps) does. Don't assume "every chart" is uniform; verify a
> specific chart kind before building a waterfall drill-down.

Enumerate the live trigger and effect sets yourself rather than trusting any
static list (including this one) to stay current:

```bash
# all effect kinds currently modeled:
jq -c '[.. | objects | select(.properties?.effect?.enum?) | .properties.effect.enum[0]] | unique' /tmp/sigma-api.json
# element kinds that carry an `actions` array (i.e. can host actions at all) —
# `kind` and `actions` sit in separate `allOf` segments of the same schema
# object, so match on a sibling segment rather than the same `properties` dict:
jq -c '[.. | objects | select(.allOf?) | select(any(.allOf[]?; .properties?.actions?)) |
  (.allOf[] | select(.properties?.kind?.enum?) | .properties.kind.enum[0])] | unique' /tmp/sigma-api.json
```

## Verified effects

The API exposes **twelve** effects. All twelve are now live-verified — see
*Navigation, refresh, and row-editing effects* below for the nine covered outside
this section. These three round-tripped and rendered correctly on a live test-org
build:

### `insert-rows` — write a row into an input table

```yaml
effect: insert-rows
tableElementId: annotations    # an input-table element's id
values:
  an-note: { type: control, control: NoteCtl }
  an-tag:  { type: constant, value: { type: text, value: "manual" } }
```

`values` is a map of the input table's **own column ids** to a value descriptor
— see *value sources* below for the two shapes exercised here (`control`,
`constant`) and the rest of the tagged union the OpenAPI models:
- `{ type: control, control: <controlId> }` — the current value of a control.
- `{ type: constant, value: { type: text, value: <literal> } }` — a hard-coded
  literal.

The target field is **`tableElementId`**, not `table`. The live OpenAPI
(`components.schemas.Actions`) requires `[effect, tableElementId, values]`
for `insert-rows`. Sending `table:` instead fails every element oneOf and
Sigma reports the masked `Invalid kind: "button"`.

**Never include a system column** (`ID`/`CREATED_AT`/`CREATED_BY`/`UPDATED_AT`/
`UPDATED_BY`) in `values` — Sigma auto-fills those; see *the append-only-log
pattern* below.

### `clear-control` — reset a control (page scope only)

```yaml
effect: clear-control
scope: { type: page, pageId: pg }
usePublishedValue: true
```

The OpenAPI's `scope` discriminator has **four** shapes — `{ type: control,
controlId: <controlId> }` (clear one control), `{ type: container,
containerElementId: <containerElementId> }` (clear every control in a
container), `{ type: page, pageId: <pageId> }` (clear every control on a
page, or the current page when `pageId` is omitted in the schema), and `{
type: workbook }` (clear every control in the whole workbook). **Page scope
with an explicit `pageId` is the live-verified shape.** A stale `page:` key
is dropped on GET readback (leaving `{ type: page }` with no target) and
click then fails with `No target page is selected in the action.` Until
`control`/`container`/`workbook` scope is independently re-verified, build
resets around `page` scope with `pageId` only.

### `set-control-value` — set a control programmatically

```yaml
effect: set-control-value
control: RegionFilter
value: { type: constant, value: { type: text, value: "West" } }
```

The only verified `value` shape is a constant text value (e.g. a quick-filter
preset or `""` to blank a wizard field). Useful paired with a
`list`/`segmented` control to give users a one-click shortcut into a known
filter state.

An action-agent step is a separate host: `/verify` also accepts
`value: { type: agent-input, inputName: <name> }` there. That proves the step
shape only; it does not prove that the agent will invoke it or that the control
will accept the supplied value at runtime.

### Resetting a create wizard after it writes

A new-record modal keeps its control values after the row is inserted. Reset
the fields on the same button, ordered after `insert-rows` because the write
reads those controls:

```yaml
effects:
  - effect: insert-rows
    tableElementId: scenarios
    values:
      name:  { type: control, control: newName }
      owner: { type: control, control: newOwner }
  - effect: set-control-value
    control: newName
    value: { type: constant, value: { type: text, value: "" } }
  - effect: set-control-value
    control: newStrategy
    value: { type: constant, value: { type: text, value: "Baseline" } }
  - effect: close-overlay
```

Do not use page-scoped `clear-control` for this. Overlay content lives in flat
`document.elements`; page scope resolves to the host page and can clear
unrelated controls such as an active-scenario selector. Use per-control,
constant `set-control-value` effects, then close the overlay last.

Click the deployed button once and prove both outcomes: the row landed and the
fields reset. Readback proves only that the effect shapes persisted.

### Actions write workflow events; they do not bulk-populate tables

Use `insert-rows` for deliberate runtime submissions—a note, request, scenario
header, or audit event. It is not a supported initial-load mechanism for a
planning grid or imported dataset. A union or join also cannot write rows; it
only composes a downstream read path. Route row creation through
`../specification/input-tables.md` before authoring actions.

## Overlays: `open-overlay` / `close-overlay` (modal **and** drawer)

Modal and drawer metadata lives in `document.overlays`, not
`document.pages`. Drawer overlays slide from an edge and modals center. Their
content elements remain in flat `document.elements` and layout assigns them.
Both use the same effects:

```yaml
document:
  elements:
    - { id: btn-open, kind: button, text: Open detail }
    - { id: modal-body, kind: text, body: Detail }
  pages:
    - id: pg
      name: Main
  overlays:
    - id: modal-detail
      type: modal
      name: Detail
      modal:
        width: medium
        header: { title: Detail }
```

```yaml
# on the trigger button (lives on the main page)
effect: open-overlay
overlayId: modal-detail    # overlay metadata id, not an element id

# on a close button (typically inside the modal itself)
effect: close-overlay
```

`open-overlay` requires `overlayId`; `close-overlay` takes no other fields (it
closes whatever overlay is open).

Per the OpenAPI, `overlayId` must reference an entry in `document.overlays`;
pointing it at an ordinary page or element is invalid.

> **Layout gotcha:** an overlay needs its own `<Page>`
> block in `document.layout`, with the overlay id. When you build
> the layout by string-appending, append the overlay `<Page>` *after* you finish
> splicing elements into the main page — a naive `layout.replace("</Page>", …)`
> with no count limit hits **every** `</Page>`, which surfaces as the confusing
> `Duplicate layout element id '<id>': the same element cannot appear more than
> once in the layout`. That error is about your layout string, not your elements.

## Navigation, refresh, and row-editing effects

**Spec-verified 2026-08-05 — read the exact bar below before relying on these.**
Each shape passed `POST /v2/workbooks/spec/verify`, was created for real via
`POST /v2/workbooks/spec`, and came back byte-intact from `GET .../spec` on a
single test workbook whose page render was visually confirmed by PNG export.

> **What that does NOT cover: the actual effect firing.** No button was clicked.
> So it is proven that Sigma *accepts, persists, and renders* these effects — and
> **not** that a click opens the URL, switches the tab, refreshes the element, or
> **mutates a row**. `update-rows` / `delete-rows` are the ones to be careful
> about: their write behavior (which rows match, what gets set, whether the
> delete lands) is **entirely unverified here** — only the instruction's shape is.
> Confirm any write-back flow against a real click and a real row before shipping
> it, same discipline as the rest of this doc.

### `open-url` — open an external link

```yaml
effect: open-url
url: https://example.com      # supports dynamic-text {{formula}} references
openTarget: _blank            # _self | _blank | _parent  (REQUIRED)
```

`openTarget` is **required** — omitting it is a 400. `url` is optional in the
schema, which makes a `url`-less `open-url` a silent no-op; always set it.

### `navigate` — jump to a page or element in *this* workbook

```yaml
effect: navigate
target: { type: page, page: pg-detail }      # or { type: element, element: <elementId> }
```

Use this for in-workbook page jumps rather than an `open-url` to a page URL.

### `select-tab` — drive a `tabbed-container` from a button

```yaml
effect: select-tab
tabbedContainerElementId: tc   # the tabbed-container ELEMENT's id
selectedTab: { type: tab, index: 1 }              # 0-BASED index into tabs[]
# or:        { type: direction, direction: next } # next | previous
```

`index` is **0-based** — `index: 1` selects the *second* tab. Both `selectedTab`
variants verified. This is how you build "next / back" wizard steps over a
tabbed container without extra pages.

### `refresh-element` — re-run one element's query

```yaml
effect: refresh-element
target: { type: element, element: itbl }
```

`target` is an object (not a bare id) and its only documented `type` is `element`.

### `update-rows` / `delete-rows` — edit existing input-table rows

The write-back counterparts to `insert-rows`. Both require a `whichRows`
selector; `update-rows` also takes the same `values` map as `insert-rows`.

```yaml
# Update every row matching a formula
effect: update-rows
tableElementId: itbl
whichRows: { type: formula, formula: '[note] = "x"' }
values:
  amount: { type: constant, value: { type: number, value: 1 } }
```

```yaml
# Update exactly one row by primary key
effect: update-rows
tableElementId: itbl
whichRows:
  type: single-row
  primaryKeys:
    ID: { type: constant, value: { type: text, value: abc } }
values:
  amount: { type: constant, value: { type: number, value: 2 } }
```

```yaml
# Delete every row matching a formula
effect: delete-rows
tableElementId: itbl
whichRows: { type: formula, formula: '[note] = "x"' }
```

`whichRows` has **four** variants (re-verified 2026-08-08 against the live
codec — an earlier pass here missed the fourth) — `{type: formula, formula}`,
`{type: single-row, primaryKeys}`, `{type: current-row}`, and `{type:
column-match, columnId, condition, value?}`: a column where-clause, e.g. `{
type: column-match, columnId: status, condition: "=", value: {...} }`.
`condition` is one of `IsNull` / `IsNotNull` (no `value`), `=` / `!=` / `>` /
`>=` / `<` / `<=` / `Contains` / `NotContains` / `StartsWith` / `EndsWith`
(`value` required), or `Between` / `NotBetween` (`low`/`high` required instead
of `value`).

For an action-agent tool, `primaryKeys` and the `values` map must use the target
input-table element's own column IDs. Do not copy friendly names or IDs from a
derived table/chart that reads from the input table; Sigma may report those as
`bad column` during `/verify`.

> **`current-row` is not reachable from a page-level button.** It rejects with
> `current-row selector requires the action host to be within the target input
> table` — the effect only makes sense on a row-scoped host (a row action inside
> the table itself). Attempting to author that host as a `kind: button` entry in
> the input table's `columns[]` fails with a **masked, misleading** error —
> `document.pages[0]: Invalid type: "page"` — because a button isn't a valid
> column shape, and the mismatch surfaces against the page schema instead of the
> column. For button-driven edits use `formula` or `single-row`; treat the
> row-scoped host as UI-only until someone verifies a spec shape for it.

### `open-document` — open another workbook or report, optionally passing controls

```yaml
effect: open-document
documentId: <inodeId>          # the target workbook/report inode id
documentType: workbook         # workbook | report  (REQUIRED — selects the route)
openTarget: _blank             # _self | _blank | _parent  (REQUIRED)
targetControls:                # optional: seed the target's controls
  Region: { type: constant, value: { type: text, value: West } }
```

`targetControls` maps the **target document's** control `variableName` to a value
resolved against *this* workbook — the spec-authorable way to deep-link into
another workbook already filtered. `documentType` is required and picks the
runtime route, so a `report` opened as `workbook` (or vice versa) is a real bug,
not a cosmetic mismatch.

## `value` sources — the full tagged union (`set-control-value`, `insert-rows`/`update-rows`)

`insert-rows`/`update-rows`'s `values` map and `set-control-value`'s `value`
share one tagged union. Confirmed 2026-08-08 against the live OpenAPI, the
top-level `type` is one of **seven**: `constant`, `control`, `formula`,
`column`, `column-range`, `formula-range`, `agent-input`. This repo has only
exercised `control` and `constant` live (above) — the other five are
spec-documented but not independently verified here:

- `{ type: control, control: <controlId> }` — a control's current value.
- `{ type: constant, value: {...} }` — a hard-coded literal. **`value` here is
  itself tagged**, not a bare scalar: `{ type: text | number | boolean | date,
  value: <literal-or-null> }`, or a list variant (`text-list` / `number-list` /
  `date-list` / `boolean-list`), or a range variant (`number-range` /
  `date-range` — there is no `boolean-range` or `text-range`).
- `{ type: formula, formula: <string> }` — a formula string, evaluated live.
- `{ type: column, ... }` / `{ type: column-range, ... }` — a column value from
  the current context. Only valid inside an `on-select` action (see *Selection
  scope* below).
- `{ type: formula-range, ... }` — a formula-derived range.
- `{ type: agent-input, inputName }` — reserved for an agent tool's `steps[]`
  (see `reference/specification/agents.md`); on a regular button or modal
  action this is rejected.

## Selection scope (`on-select` only)

An `on-select` action (any table/pivot/chart/map host, per *Hosts and their
triggers* above) can reference the row or mark the user selected: a `column` /
`column-range` value source, or a `[Selection/<Column>]` formula reference
inside a value or a URL.

```yaml
- id: drill-region
  trigger: on-select
  effects:
    - effect: set-control-value
      control: region
      value: { type: formula, formula: "[Selection/Region]" }
```

`[Selection/…]` binds **only** inside an `on-select` action — elsewhere (e.g.
an `open-url` on a button's `on-click`) it stays unbound rather than erroring,
so a stray reference silently resolves to nothing instead of failing loudly.

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
          tableElementId: annotations
          values:
            an-note: { type: control, control: NoteCtl }

# 3. The log itself — an empty input table. System columns take NO `type` and
#    are auto-filled by Sigma (CREATED_AT/CREATED_BY) — never pass them in
#    insert-rows `values` above; doing so breaks the column.
- id: annotations
  kind: input-table
  inputMode: view # required; published editing is a separate UI-only setting
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
| `Invalid kind: "input-table"` | `inputMode` was omitted. | Always set `inputMode` (`view` is a safe structural default). It does not enable published editing; that is the UI-only “Set data entry permission” setting in `input-tables.md`. |
| `Invalid kind: "control"` (on a `text`/`text-area` control used for **entry**, not filtering) | One or more of `mode`, `case`, `includeNulls`, `showOperators` was omitted. | Set all four — see `controls.md`'s "Entry (write) text controls" section. |
| `Invalid kind: "button"` | `insert-rows` / `update-rows` / `delete-rows` used `table:` instead of `tableElementId`. The extra/missing property fails every `WorkbookElement` oneOf, so Sigma reports the kind as invalid. | Use `tableElementId: <input-table element id>`. |
| `Error in Clear controls` / `No target page is selected in the action` | `clear-control` used `scope: { type: page, page: }` instead of `pageId`. GET drops the stale `page:` key. | Use `scope: { type: page, pageId: <page id> }`. |
| Button silently does nothing on click | An element/container-scoped `clear-control`. | Use `scope: { type: page, pageId: <id> }` only (see above). |
| `document.pages[0]: Invalid type: "page"` | An invalid entry in some element's `columns[]` — e.g. trying to author a row-action `kind: button` as an input-table column. The mismatch is reported against the **page** schema, not the offending column. | Check the `columns[]` you last touched, not the page `type`. Row-scoped action hosts aren't spec-authorable (see `delete-rows` / `current-row` above). |
| `Duplicate layout element id '<id>'` | The layout **XML string**, not the elements — usually an unbounded `replace("</Page>", …)` that spliced the same element into every `<Page>`. | Bound the replacement (`count=1`) or append overlay pages after all element splicing. See the overlay layout gotcha above. |
| `page-break 'X' must span exactly one grid row (got height N)` | A `page-break` given a multi-row `gridRow`. | Page breaks are fixed at height 1 — use a one-row span, e.g. `gridRow="24 / 25"`. |
| Layout fails after a tag edit | A noncanonical layout node such as `<RepeatedContainer>`, `<GridContainer>`, or `<LayoutElement>`. `/verify` reports `<LayoutElement>` as `valid:false` (older versions returned HTTP 400). | Emit `<Container>` for nested grids/repeaters and `<Element>` for leaves. `<TabbedContainer>`/`<Tab>` remain valid. |
| `Dependency not found: '<x>/<col>'` (lowercased in the message) | A `{{[…]}}` reference whose **left-hand side** doesn't resolve—usually an element `id` used where the element **`name`** is required. A correct repeated-container virtual target is also affected by the current API regression. | Check the referenced element's `name`. For repeated containers the GET-readback form is `[<source element name> repeated container/<Column name>]`, but verify and POST reject that correct form as of 2026-08-08; keep it gated. See `layout.md`. |

## Cross-links

- `scripts/lib/actions.rb` — `Actions.button(id:, text:, effects:,
  appearance:)`, `Actions.input_table_empty(id:, connection_id:, columns:,
  name:, input_mode:)`, `Actions.input_table_linked(id:, from:,
  connection_id:, columns:, name:, input_mode:)`, and the three effect builders `Actions.insert_rows_effect(table_element_id:,
  values:)` / `Actions.clear_control_effect(page_id:)` /
  `Actions.set_control_value_effect(control:, text:)` build exactly the shapes
  above (`inputMode: "view"` by default with explicit `edit`/`explore`
  overrides; `clear_control_effect` only ever emits page scope). Gated behind
  `Actions::SURFACES`; a NO-GO flip returns
  `{opt_in: true, id:}` (element builders) or `{}` (effect builders) rather than
  a faked shape. **The nine effects in *Navigation, refresh, and row-editing
  effects* have no builder yet** — hand-author those shapes (they're verified,
  just not wrapped) or add a builder alongside the existing three.
- `reference/specification/input-tables.md` — the write-connection requirement,
  the publish-before-query gate, and the linked-table cross-connection pattern.
- `reference/specification/controls.md` — full control-element field reference.
- `reference/specification/agents.md` — a write/action agent's `tools[].steps[]`
  reuses these same effect shapes, driven by agent input instead of a button
  click.
