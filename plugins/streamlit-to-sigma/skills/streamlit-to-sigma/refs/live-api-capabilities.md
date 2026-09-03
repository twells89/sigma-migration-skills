# Live workbook API capabilities

Last probed: **2026-08-27** against the current compiled public OpenAPI and a
live Sigma organization. Treat the OpenAPI as the shape contract and the live
probe as the entitlement/host contract.

## Confirmed action field changes

These replacements are required. The old fields are rejected or silently
discarded:

| Capability | Current field | Old field |
|---|---|---|
| Run Python element | `codeElementId` | `element` (rejected) |
| Selected-row column value | `columnId` | `column` (rejected) |
| Selected-row range minimum | `minColumnId` | `min` (silently discarded) |
| Selected-row range maximum | `maxColumnId` | `max` (silently discarded) |

Live create/readback preserved:

```json
{"type": "column", "columnId": "column-id"}
```

and:

```json
{
  "type": "column-range",
  "minColumnId": "minimum-column-id",
  "maxColumnId": "maximum-column-id"
}
```

Use `converter/api_capabilities.py`; do not transcribe older shapes.

## Deferred filters and browser downloads

Live readback confirmed the deferred form pattern:

- visible staging control has a value-list source but no `filters`;
- hidden target control has the real `filters` binding;
- Apply uses `set-control-value` with
  `value: {type: control, control: <staging-controlId>}`;
- Reset clears both with
  `scope: {type: control, controlId: <controlId>}`.

The `controlId` key is significant. An older `{type: control, control: ...}`
clear-scope shape is not the current readback contract.

Browser CSV download is public-spec authorable:

```json
{
  "effect": "export",
  "channel": "download",
  "source": {"type": "element", "element": "table-element-id"},
  "format": {"type": "csv"}
}
```

This maps a Streamlit `download_button` over a displayed dataframe directly;
do not substitute a refresh action.

Table custom sort uses the target key `elementId` and:

```json
{
  "type": "level",
  "columns": [
    {
      "columnId": "table-column-id",
      "direction": "descending",
      "nulls": "last"
    }
  ]
}
```

For a Streamlit sort selector whose direction varies by option, attach an
`on-change` action to the control and branch to one `custom-sort` effect per
option with `if-else`.

## Native forms and input-table writes

The public workbook schema includes `kind: form`. Static fields support text,
number, date, checkbox, choice, and file-upload inputs, validation, defaults,
footer CTAs, and actions. `set-form-values` targets a `formElementId`;
submitted values use `{type: form-field, fieldId: ...}`. `reset-form` resets
the host form.

Live `/verify` accepted a native form plus `set-form-values`.

Input-table actions are public:

- `insert-rows` — non-linked input tables only
- `update-rows` — linked or non-linked input tables
- `delete-rows` — non-linked input tables only

All three require target input-table column IDs, not display names. Update and
delete row selectors can use a primary-key map, a target-table formula, or a
column match. A combined live `/verify` probe passed. Browser-triggered
warehouse mutation remains a hard gate; the automated browser did not have a
Sigma UI session, so do not call writeback complete from verification alone.

## Navigation, links, tabs, selection, and chat

Live `/verify` accepted:

- `navigate` to a current-workbook page or element
- `open-url` with `_self`, `_blank`, or `_parent`
- `select-tab` by zero-based index or next/previous direction
- `clear-chat-element-messages`

Use these for `st.switch_page`, `st.page_link`, `st.link_button`, wizard steps,
and explicit chat reset. Tables/charts also expose `on-select`; selected values
must use `columnId` or `minColumnId`/`maxColumnId`.

A popover trigger button cannot also have actions. Live `/verify` rejected that
host combination; use the overlay's `triggerElementId` metadata instead.

`call-api` requires an existing governed API connector. The probed organization
had none, so no runtime claim is made.

## Python and `code-output`

The OpenAPI now exposes a downstream source for one named `sigma.output()`:

```json
{
  "kind": "code-output",
  "elementId": "python-element-id",
  "output": "output_name"
}
```

This can connect a Python element to a table/chart/pivot and can reduce some
`python-transform` gaps to `python-element-candidate`.

It is **capability-gated**, not generally automatic:

- the live test workspace rejected `kind: code` with
  `` `code` elements are not enabled for this workspace ``;
- it rejected `source.kind: code-output` with
  `` `code-output` sources are not enabled for this workspace ``;
- no accessible workbook in that organization exposed a Python/code-output
  readback to use as runtime evidence.

Before lowering Python:

1. Probe a minimal code element and code-output source with `/verify`.
2. Confirm a Python-enabled, write-capable connection and writeback destination.
3. Never execute copied Streamlit code during discovery.
4. Require review of packages, side effects, external access, and identity.
5. Run the Python element, query the named output, and GET the workbook spec
   before marking the path supported.

## Workbook agents and chat

Dedicated endpoints can:

- list agents across the organization (`GET /v2/workbookAgents`);
- list agents in one workbook;
- run an existing agent with a stateless message history.

Live list and run calls returned HTTP 200. The run honored `maxTurns`,
`maxOutputTokens`, metadata, and a text response format.

Workbook code representation can also author `document.agents` and `kind: chat`
elements. A live workbook round-tripped both. Dedicated endpoints still do not
create agents independently of a workbook spec. Streamlit AI/chat apps therefore
remain capability-gated: create/reuse the workbook agent, publish, and validate
its data sources, tools, and responses before claiming parity.

A live Streamlit migration created a workbook agent over filtered retail-order
and policy-document tables. The run endpoint completed a warehouse query
(`5,009` distinct orders) and separately grounded a policy answer in the named
return-risk document. This proves agent/chat authoring plus data-source tool use;
it does not prove every Streamlit agent framework is mechanically equivalent.

Distinguish observed runtime from declared infrastructure:

- `SNOWFLAKE.CORTEX.COMPLETE(...)` is an LLM completion, not a Cortex Agent.
- A project that contains `CREATE CORTEX AGENT` but calls `COMPLETE` at runtime
  has an architecture mismatch.
- Never claim Cortex Analyst/Search tool parity from an unused agent definition.
- Map the actual grounding tables and instructions to `document.agents`, then
  run representative structured-data and policy-grounding prompts.

## Stored procedures remain UI-finish

Procedure permissions and connection sync can make procedures appear in Sigma's
editor, but public workbook GET still omits the UI-authored action. Public
POST/PUT rejects an inline stored-procedure effect on tested button and table
hosts. Keep this `manual-ui-finish` until a public round-trip succeeds.
