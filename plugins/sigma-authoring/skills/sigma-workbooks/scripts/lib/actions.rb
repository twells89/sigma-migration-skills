# frozen_string_literal: true
#
# actions.rb — thin, spec-authorable builders for buttons, input tables
# (write-back), and the action effects that connect them. Ruby 2.6+, stdlib
# only. Golden-tested output lives in scripts/lib/testdata/actions_golden.json
# (see test_actions.rb).
#
#   require_relative 'lib/actions'
#   btn = Actions.button(id: 'btn-log', text: 'Log note',
#                         effects: [Actions.insert_rows_effect(table_element_id: 'annotations', values: {...})])
#   tbl = Actions.input_table_empty(id: 'annotations', connection_id: WRITE, columns: [...])
#
# Live-verified shape facts (verified live against a real Sigma org, building
# a multi-KPI command-center-style workbook with buttons + an append-only-log
# input table):
#   - `inputMode` on an input-table element is MANDATORY. Omit it and
#     the POST masked-fails as `Invalid kind:"input-table"` — a misleading
#     message; the real cause is the missing inputMode. Both input_table_*
#     builders below always emit it and default to `"view"`. No inputMode value
#     enables published data entry; that is a UI-only element permission.
#   - Empty input table: source:{kind:"empty",connectionId:<WRITE conn>}.
#     Linked input table: source:{kind:"linked",from:<parent element id>,
#     connectionId:<WRITE conn>} — the parent element (`from`) may live on a
#     DIFFERENT (read-only) connection than the write-back table itself
#     (verified: a Sample-DB pivot fed a write-conn linked table). System
#     columns (e.g. CREATED_AT/CREATED_BY) take no `type` and are auto-filled
#     by Sigma — callers pass them as bare {'id'=>...} column entries and
#     never include them in insert-rows `values`.
#   - Button: {id, kind:"button", text, appearance:"filled"|"outline",
#     actions:[{id, trigger:"on-click", effects:[...]}]}. `action_id:`
#     defaults to "a-<id>" (deterministic — no time/random) so callers don't
#     have to invent a second id for the single action most buttons carry;
#     pass action_id: explicitly for a different handle.
#   - Effects verified live: insert-rows (values is a pass-through Hash of
#     colId => {type:"control",control:} | {type:"constant",value:{type:"text",value:}}
#     entries — this module does not reshape `values`, callers build it),
#     clear-control (this builder emits page scope only —
#     scope:{type:"page",pageId:}), set-control-value (constant text value).
#
# NOT renamed in the 2026-08-26 action field rename — probe-confirmed that the
# `*Id` form is REJECTED and the bare name is still required, so do not "fix"
# these: `set-control-value.control`, `navigate` target.page,
# `refresh-element` target.element, and the {type:"control",control:} value
# source used inside `values`.
#
# All builders are gated through Actions::SURFACES (same discipline as
# richness.rb/styling.rb): a NO-GO flip on `button`/`input_table_empty`/
# `input_table_linked` returns {'opt_in'=>true,'id'=>id} (never a faked
# element); a NO-GO flip on `effects` (the 3 effect builders share one gate —
# they're trivial shape helpers, not independently-risky surfaces) returns
# {} (never a faked effect spliced into a caller's actions: array).

require 'json'

module Actions
  SURFACES = {
    button: true,             # {kind:"button"} + actions:[{trigger,effects}] — verified GO live
    input_table_empty: true,  # input-table, source.kind:"empty" — verified GO live; inputMode required
    input_table_linked: true, # input-table, source.kind:"linked" (cross-connection from a read-only parent) — verified GO live
    effects: true             # insert-rows / clear-control / set-control-value shape helpers — verified GO live, one gate for all 3
  }.freeze

  # Returns a `button` element: {id, kind:"button", text, appearance,
  # actions:[{id, trigger, effects}]}. `effects` is a pass-through array —
  # build entries with insert_rows_effect/clear_control_effect/
  # set_control_value_effect (or already-shaped Hashes) and pass them here
  # verbatim; this builder never reshapes them. `action_id:` defaults to
  # the deterministic "a-<id>" when omitted (nil) — pass action_id: '' or
  # any other string explicitly to use a different handle. NO-GO surface ->
  # {'opt_in'=>true,'id'=>id}.
  def self.button(id:, text:, effects:, appearance: 'filled', trigger: 'on-click', action_id: nil, surfaces: SURFACES)
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'text required' if text.to_s.empty?
    return { 'opt_in' => true, 'id' => id } unless surfaces[:button]

    aid = action_id.nil? ? "a-#{id}" : action_id
    {
      'id' => id,
      'kind' => 'button',
      'text' => text,
      'appearance' => appearance,
      'actions' => [{ 'id' => aid, 'trigger' => trigger, 'effects' => effects }]
    }
  end

  # Returns an `input-table` element sourced empty (a fresh write-back table,
  # e.g. an append-only log): {id, kind:"input-table", inputMode:"view",
  # source:{kind:"empty",connectionId:}, columns:}. `inputMode` is always
  # emitted and defaults to `"view"`; pass `"edit"` or `"explore"` through
  # `input_mode:` when needed. It does not grant published data entry.
  # `columns` is passed through verbatim (already-shaped column
  # entries, including bare {'id'=>'CREATED_AT'} system-column entries with
  # no `type`). `name:` (optional; a text-style Hash or plain string, caller's
  # choice — passed through verbatim) is OMITTED entirely when not given, not
  # emitted as nil. NO-GO surface -> {'opt_in'=>true,'id'=>id}.
  def self.input_table_empty(id:, connection_id:, columns:, name: nil, input_mode: 'view', surfaces: SURFACES)
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'connection_id required' if connection_id.to_s.empty?
    raise ArgumentError, 'columns required' if columns.nil? || columns.empty?
    raise ArgumentError, 'input_mode must be edit, explore, or view' unless %w[edit explore view].include?(input_mode)
    return { 'opt_in' => true, 'id' => id } unless surfaces[:input_table_empty]

    out = {
      'id' => id,
      'kind' => 'input-table',
      'inputMode' => input_mode,
      'source' => { 'kind' => 'empty', 'connectionId' => connection_id },
      'columns' => columns
    }
    out['name'] = name unless name.nil?
    out
  end

  # Returns an `input-table` element sourced linked from a parent element
  # (e.g. a write-back "targets" table keyed off a read-only pivot):
  # {id, kind:"input-table", inputMode:"view", source:{kind:"linked",from:,
  # connectionId:}, columns:}. `from` is the PARENT element's id — verified
  # live to work even when the parent sits on a different (read-only)
  # connection than `connection_id` (the write connection this table itself
  # lives on). Same `columns`/`name:` pass-through contract as
  # input_table_empty. `input_mode:` defaults to `"view"` and accepts
  # `"edit"` or `"explore"`. NO-GO surface -> {'opt_in'=>true,'id'=>id}.
  def self.input_table_linked(id:, from:, connection_id:, columns:, name: nil, input_mode: 'view', surfaces: SURFACES)
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'from required' if from.to_s.empty?
    raise ArgumentError, 'connection_id required' if connection_id.to_s.empty?
    raise ArgumentError, 'columns required' if columns.nil? || columns.empty?
    raise ArgumentError, 'input_mode must be edit, explore, or view' unless %w[edit explore view].include?(input_mode)
    return { 'opt_in' => true, 'id' => id } unless surfaces[:input_table_linked]

    out = {
      'id' => id,
      'kind' => 'input-table',
      'inputMode' => input_mode,
      'source' => { 'kind' => 'linked', 'from' => from, 'connectionId' => connection_id },
      'columns' => columns
    }
    out['name'] = name unless name.nil?
    out
  end

  # Returns an `insert-rows` effect Hash: {effect, tableElementId, values}.
  # The OpenAPI field is `tableElementId` (the target input-table element's
  # id). A stale `table:` key fails every WorkbookElement oneOf and Sigma
  # reports the masked `Invalid kind: "button"`. `values` is a pass-through
  # Hash of colId => {type:"control",control:} |
  # {type:"constant",value:{type:"text",value:}} entries (or any other
  # already-shaped value descriptor) — never reshaped here; system columns
  # (CREATED_AT/CREATED_BY) are never included, Sigma auto-fills them.
  # NO-GO surface -> {} (never a faked effect spliced into a caller's
  # actions: array).
  def self.insert_rows_effect(table_element_id:, values:, surfaces: SURFACES)
    raise ArgumentError, 'table_element_id required' if table_element_id.to_s.empty?
    return {} unless surfaces[:effects]

    { 'effect' => 'insert-rows', 'tableElementId' => table_element_id, 'values' => values }
  end

  # Returns a `clear-control` effect Hash: {effect,
  # scope:{type:"page",pageId:}, usePublishedValue:true}. The OpenAPI field
  # is `pageId` (not `page`). A stale `page:` key is dropped on GET
  # readback, and click then fails with "No target page is selected in the
  # action." Page scope only — but note the reason has changed: the old
  # "an element-scoped clear-control masked-failed the button live" finding
  # was recorded while this builder still emitted the PRE-RENAME key names.
  # Re-probed 2026-08-26, control scope ({type:"control",controlId:}) and
  # container scope ({type:"container",containerElementId:}) BOTH create and
  # read back cleanly, so what masked-failed was the rejected key, not the
  # scope type. Widening this builder to those scopes is a safe follow-up.
  # NO-GO surface -> {}.
  def self.clear_control_effect(page_id:, surfaces: SURFACES)
    raise ArgumentError, 'page_id required' if page_id.to_s.empty?
    return {} unless surfaces[:effects]

    { 'effect' => 'clear-control', 'scope' => { 'type' => 'page', 'pageId' => page_id }, 'usePublishedValue' => true }
  end

  # Returns a `set-control-value` effect Hash: {effect, control,
  # value:{type:"constant",value:{type:"text",value:text}}}. `text` is
  # always wrapped as a constant text value (the only shape verified live).
  # NO-GO surface -> {}.
  def self.set_control_value_effect(control:, text:, surfaces: SURFACES)
    raise ArgumentError, 'control required' if control.to_s.empty?
    raise ArgumentError, 'text required' if text.nil?
    return {} unless surfaces[:effects]

    {
      'effect' => 'set-control-value',
      'control' => control,
      'value' => { 'type' => 'constant', 'value' => { 'type' => 'text', 'value' => text } }
    }
  end
end
