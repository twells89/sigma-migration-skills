"""actions.py — Python twin of shared/lib/actions.rb. Thin, spec-authorable
builders for buttons, input tables (write-back), and the action effects that
connect them -- the "Component C" piece of docs/superpowers/specs/
2026-07-29-ws4-agent-gradient-actions-design.md. Byte-identical output
(shared/lib/testdata/actions_golden.json).

    import actions
    btn = actions.button(id="btn-log", text="Log note",
                          effects=[actions.insert_rows_effect(table="annotations", values={...})])
    tbl = actions.input_table_empty(id="annotations", connection_id=WRITE, columns=[...])

Live-verified shape facts (design doc "Live-verified shape facts"; reference
build: /private/tmp/.../scratchpad/build-plugs-command-center.rb, symbols
btn_reset/btn_preset/btn_log/targets/annotations), verified on a Plugs
command-center workbook on a test org:
  - `inputMode: "edit"` on an input-table element is MANDATORY. Omit it and
    the POST masked-fails as `Invalid kind:"input-table"` -- a misleading
    message; the real cause is the missing inputMode. Both input_table_*
    builders below always emit it.
  - Empty input table: source={kind:"empty",connectionId:<WRITE conn>}.
    Linked input table: source={kind:"linked",from:<parent element id>,
    connectionId:<WRITE conn>} -- the parent element (`from`) may live on a
    DIFFERENT (read-only) connection than the write-back table itself
    (verified: a Sample-DB pivot fed a write-conn linked table). System
    columns (e.g. CREATED_AT/CREATED_BY) take no `type` and are auto-filled
    by Sigma -- callers pass them as bare {"id": ...} column entries and
    never include them in insert-rows `values`.
  - Button: {id, kind:"button", text, appearance:"filled"|"outline",
    actions:[{id, trigger:"on-click", effects:[...]}]}. `action_id` defaults
    to "a-<id>" (deterministic -- no time/random) so callers don't have to
    invent a second id for the single action most buttons carry; pass
    action_id= explicitly for a different handle.
  - Effects verified live: insert-rows (values is a pass-through dict of
    colId -> {type:"control",control:} | {type:"constant",value:{type:"text",value:}}
    entries -- this module does not reshape `values`, callers build it),
    clear-control (an ELEMENT-scoped clear-control masked-failed the button
    live -- only page scope is verified, so this builder only emits
    scope={type:"page",page:}), set-control-value (constant text value).

All builders are gated through SURFACES (same discipline as richness.py/
styling.py): a NO-GO flip on `button`/`input_table_empty`/`input_table_linked`
returns {"opt_in": True, "id": id} (never a faked element); a NO-GO flip on
`effects` (the 3 effect builders share one gate -- they're trivial shape
helpers, not independently-risky surfaces) returns {} (never a faked effect
spliced into a caller's actions: array).
"""

SURFACES = {
    "button": True,             # {kind:"button"} + actions:[{trigger,effects}] -- WS4 GO (Plugs command-center reference build)
    "input_table_empty": True,  # input-table, source.kind:"empty" -- WS4 GO; inputMode:"edit" mandatory (masked-error fix)
    "input_table_linked": True, # input-table, source.kind:"linked" (cross-connection from a read-only parent) -- WS4 GO
    "effects": True,            # insert-rows / clear-control / set-control-value shape helpers -- WS4 GO, one gate for all 3
}


def button(id, text, effects, appearance="filled", trigger="on-click", action_id=None, surfaces=None):
    """Returns a `button` element: {id, kind:"button", text, appearance,
    actions:[{id, trigger, effects}]}. `effects` is a pass-through list --
    build entries with insert_rows_effect/clear_control_effect/
    set_control_value_effect (or already-shaped dicts) and pass them here
    verbatim; this builder never reshapes them. `action_id` defaults to the
    deterministic "a-<id>" when omitted (None) -- pass action_id="" or any
    other string explicitly to use a different handle. NO-GO surface ->
    {"opt_in": True, "id": id}.
    """
    s = SURFACES if surfaces is None else surfaces
    if not id:
        raise ValueError("id required")
    if not text:
        raise ValueError("text required")
    if not s["button"]:
        return {"opt_in": True, "id": id}
    aid = "a-%s" % id if action_id is None else action_id
    return {
        "id": id,
        "kind": "button",
        "text": text,
        "appearance": appearance,
        "actions": [{"id": aid, "trigger": trigger, "effects": effects}],
    }


def input_table_empty(id, connection_id, columns, name=None, surfaces=None):
    """Returns an `input-table` element sourced empty (a fresh write-back
    table, e.g. an append-only log): {id, kind:"input-table",
    inputMode:"edit", source:{kind:"empty",connectionId:}, columns:}.
    `inputMode:"edit"` is ALWAYS emitted -- it is mandatory (see module
    docstring's masked-error note). `columns` is passed through verbatim
    (already-shaped column entries, including bare {"id":"CREATED_AT"}
    system-column entries with no `type`). `name` (optional; a text-style
    dict or plain string, caller's choice -- passed through verbatim) is
    OMITTED entirely when not given, not emitted as None. NO-GO surface ->
    {"opt_in": True, "id": id}.
    """
    s = SURFACES if surfaces is None else surfaces
    if not id:
        raise ValueError("id required")
    if not connection_id:
        raise ValueError("connection_id required")
    if not columns:
        raise ValueError("columns required")
    if not s["input_table_empty"]:
        return {"opt_in": True, "id": id}
    out = {
        "id": id,
        "kind": "input-table",
        "inputMode": "edit",
        "source": {"kind": "empty", "connectionId": connection_id},
        "columns": columns,
    }
    if name is not None:
        out["name"] = name
    return out


def input_table_linked(id, from_, connection_id, columns, name=None, surfaces=None):
    """Returns an `input-table` element sourced linked from a parent element
    (e.g. a write-back "targets" table keyed off a read-only pivot):
    {id, kind:"input-table", inputMode:"edit", source:{kind:"linked",from:,
    connectionId:}, columns:}. `from_` is the PARENT element's id --
    verified live to work even when the parent sits on a different
    (read-only) connection than `connection_id` (the write connection this
    table itself lives on). Same `columns`/`name` pass-through contract as
    input_table_empty. NO-GO surface -> {"opt_in": True, "id": id}.
    """
    s = SURFACES if surfaces is None else surfaces
    if not id:
        raise ValueError("id required")
    if not from_:
        raise ValueError("from required")
    if not connection_id:
        raise ValueError("connection_id required")
    if not columns:
        raise ValueError("columns required")
    if not s["input_table_linked"]:
        return {"opt_in": True, "id": id}
    out = {
        "id": id,
        "kind": "input-table",
        "inputMode": "edit",
        "source": {"kind": "linked", "from": from_, "connectionId": connection_id},
        "columns": columns,
    }
    if name is not None:
        out["name"] = name
    return out


def insert_rows_effect(table, values, surfaces=None):
    """Returns an `insert-rows` effect dict: {effect, table, values}.
    `values` is a pass-through dict of colId -> {type:"control",control:} |
    {type:"constant",value:{type:"text",value:}} entries (or any other
    already-shaped value descriptor) -- never reshaped here; system columns
    (CREATED_AT/CREATED_BY) are never included, Sigma auto-fills them.
    NO-GO surface -> {} (never a faked effect spliced into a caller's
    actions: array).
    """
    s = SURFACES if surfaces is None else surfaces
    if not table:
        raise ValueError("table required")
    if not s["effects"]:
        return {}
    return {"effect": "insert-rows", "table": table, "values": values}


def clear_control_effect(page, surfaces=None):
    """Returns a `clear-control` effect dict: {effect,
    scope:{type:"page",page:}, usePublishedValue:True}. Page scope ONLY --
    an element-scoped clear-control masked-failed the button live (design
    doc), so this builder never emits any other scope shape. NO-GO
    surface -> {}.
    """
    s = SURFACES if surfaces is None else surfaces
    if not page:
        raise ValueError("page required")
    if not s["effects"]:
        return {}
    return {"effect": "clear-control", "scope": {"type": "page", "page": page}, "usePublishedValue": True}


def set_control_value_effect(control, text, surfaces=None):
    """Returns a `set-control-value` effect dict: {effect, control,
    value:{type:"constant",value:{type:"text",value:text}}}. `text` is
    always wrapped as a constant text value (the only shape verified live --
    see design doc's btn_preset example). NO-GO surface -> {}.
    """
    s = SURFACES if surfaces is None else surfaces
    if not control:
        raise ValueError("control required")
    if not text:
        raise ValueError("text required")
    if not s["effects"]:
        return {}
    return {
        "effect": "set-control-value",
        "control": control,
        "value": {"type": "constant", "value": {"type": "text", "value": text}},
    }
