"""richness.py — Python twin of shared/lib/richness.rb. Independent,
optional "richness" pieces for a dashboard page -- each helper emits ONE
spec-authorable fragment, never a whole workbook/page. Byte-identical output
(shared/lib/testdata/richness_golden.json).

    import richness
    richness.ai_insight(id="ai-1", prompt="Say hello.")
    ctl = richness.grain_control(id="GrainCtl")
    dim = richness.trend_dimension(grain_control_id="GrainCtl", date_ref="[Src/Date]")
    ag = richness.agent(id="ag-1", name="Analyst", instructions="Be helpful.", data_source_ids=["src"])
    chat = richness.chat(id="chat-1", agent_id="ag-1")

GO/NO-GO provenance (.superpowers/sdd/richness-task-1-report.md, workbook
05cd3ac1-c8cc-4252-bad6-38b33d87bf45):
  - CallText/AI-insight: GO. CallText's real signature is
    CallText(<warehouse_function_name>, ...args) -- there is NO separate
    connection argument (an earlier plan/spec assumption was wrong; this is
    the corrected shape). Working connection+model verified live: the Sigma
    Sample Database Snowflake connection, model "llama3.1-8b" (mistral-large2
    also returned real text at the raw-SQL probe stage). GO here means "the
    formula shape is spec-legal and Sigma-side proven to render real text on
    a configured connection" -- it does NOT mean every target org has Cortex
    enabled. This helper therefore ALWAYS emits the formula when its surface
    is GO; never fabricate a canned summary in code -- the org's own
    warehouse computes the real text, or the element renders blank until
    Cortex is configured there.
  - Dynamic grain (Switch+DateTrunc): GO. Switching the control across
    Month/Week/Day changed the exported distinct-bucket count exactly as
    expected (Month=3, Week=14, Day=90 over 90 days of demo data).
  - filter_row reuses the already-GO master-detail control->element-filter
    shape (verify-master-detail-e2e.rb), not a new Task-1 richness surface.
  - wide_pivot reuses the already-GO general pivot-table rowsBy/columnsBy/
    values shape (sigma-workbooks tables.md; build_workbook.py precedent:
    rowsBy/columnsBy are [{"id":...}] shelves, values is a plain id-string
    list) -- also not a new Task-1 richness surface.
All four are gated through SURFACES below anyway (not just the two actual
Task-1 richness surfaces) so a future regression/deprecation on ANY of them
can be flipped off in one place, same discipline as styling.py.

Task-6 live-build fixes (.superpowers/sdd/richness-task-6-report.md,
workbooks 71ea81cc-bcd6-4039-994c-4a4f8fdd847c /
c22aab85-0c50-4595-a3b9-b1fb0e7fc6a3): two 400s surfaced running this
module for real, previously only worked around in the caller, now fixed IN
the shared module:
  - wide_pivot 400'd ("Invalid kind: \"pivot-table\"" -- a misleading
    message; the real cause is a pivot-table element with no `columns`
    array). Fixed by adding a required `columns` param -- an already-shaped
    [{"id":,"name":,"formula":}, ...] array per tables.md's pivot recipe,
    emitted verbatim on the element. `rows_by`/`values` now reference these
    columns' OWN ids, not the source element's column ids.
  - grain_control 400'd ("controlId: Duplicate id: '<id>'") when the same
    string was reused for both the control element's `id` and its
    `controlId`. Fixed by adding a `control_id` param (default "<id>-ctl")
    so the two always differ; trend_dimension's `grain_control_id` must be
    given that `controlId` (not the element `id`) -- see its docstring
    below.

WS4 Task-1 addition -- agent + chat (docs/superpowers/specs/
2026-07-29-ws4-agent-gradient-actions-design.md, "Live-verified shape
facts"): the Sigma workbook AI agent is a workbook-TOP-LEVEL `agents:[]`
array entry (not a page element), verified live building a Plugs
command-center workbook (reference build: build-plugs-command-center.rb).
Read-only analyst = the entry OMITS `tools` entirely. The page-level `chat`
element just references the agent's id. Sigma's AI-agent feature is an
org-level toggle -- when it's off for a target org, callers should degrade
to a static text element with sample prompts rather than POST a chat
element that will masked-fail; that fallback pattern is documented in the
actions/agent workflow doc, not re-derived here.
"""

# GO/NO-GO map. All 5 are GO today; a NO-GO flip makes the gated helper
# return an empty/opt-in marker instead of emitting an unverified (or
# 400-rejected) shape -- never a silently-wrong fallback.
SURFACES = {
    "ai_insight": True,     # CallText/AI-insight text element (richness Task-1 GO; renders real text only where the target org's connection has Cortex configured -- NEVER a fabricated summary)
    "dynamic_grain": True,  # grain_control (segmented control) + trend_dimension (Switch+DateTrunc dimension formula) -- richness Task-1 GO
    "filter_row": True,     # list control(s) -> element filter, reusing the already-GO master-detail control/filter shape
    "wide_pivot": True,     # pivot-table rowsBy + columnsBy:[] + values, reusing the already-GO general Sigma pivot shape
    "agent": True,          # workbook-level agents[] entry + page-level {kind:"chat"} element -- WS4 Task-1 GO; org-feature-gated on the Sigma side (see agent/chat docstrings for the graceful-degrade contract)
}

DEFAULT_MODEL = "llama3.1-8b"
GRAIN_VALUES = ["Week", "Month", "Day"]
DEFAULT_GRAIN = "Month"


def ai_insight(id, prompt, model=DEFAULT_MODEL, surfaces=None):
    """Returns a `text` element whose body is a CallText/Cortex formula:
    {{ Replace(CallText("SNOWFLAKE.CORTEX.COMPLETE","<model>", "<prompt>") , '"', "") }}
    `prompt` is embedded verbatim between the outer quotes the template
    supplies -- callers wanting a formula-composed prompt (e.g. concatenating
    a live aggregate via '" & Text(Sum(...)) & "') pass that text as-is; this
    helper only supplies the CallText/Replace wrapper, never the content.
    Meant to sit in a light-tint container (caller wraps -- this helper
    builds ONLY the text element). NO-GO surface -> {"opt_in": True, "id": id}:
    the formula is withheld, never a faked/hardcoded summary string.
    """
    s = SURFACES if surfaces is None else surfaces
    if not id:
        raise ValueError("id required")
    if not prompt:
        raise ValueError("prompt required")
    if not s["ai_insight"]:
        return {"opt_in": True, "id": id}
    body = '{{ Replace(CallText("SNOWFLAKE.CORTEX.COMPLETE", "%s", "%s") , \'"\', "") }}' % (model, prompt)
    return {"id": id, "kind": "text", "body": body}


def grain_control(id, control_id=None, name="Grain", surfaces=None):
    """Returns a `segmented` control element (Week/Month/Day, default Month).
    `id` is the control ELEMENT's id; `controlId` is a SEPARATE handle that
    defaults to "<id>-ctl" when `control_id` is omitted. The two MUST
    differ -- Sigma 400s ("controlId: Duplicate id: '<id>'") when the same
    string is reused for both (Task-6 live finding). Pass the returned
    element's `controlId` (NOT its `id`) as grain_control_id= to
    trend_dimension so its Switch(...) formula references this exact
    control. NO-GO surface -> {"opt_in": True, "id": id}.
    """
    s = SURFACES if surfaces is None else surfaces
    if not id:
        raise ValueError("id required")
    if not s["dynamic_grain"]:
        return {"opt_in": True, "id": id}
    cid = control_id if control_id else "%s-ctl" % id
    return {
        "id": id,
        "kind": "control",
        "controlId": cid,
        "name": name,
        "controlType": "segmented",
        "selectionMode": "single",
        "value": DEFAULT_GRAIN,
        "source": {"kind": "manual", "valueType": "text", "values": GRAIN_VALUES},
    }


def trend_dimension(grain_control_id, date_ref, surfaces=None):
    """Returns the Switch-driven grain dimension formula string (Task-1
    verified: Month/Week/Day buckets change on export). `grain_control_id`
    is grain_control's returned `controlId` (NOT its element `id` -- the two
    are distinct handles, see grain_control above); `date_ref` is a raw
    Sigma column reference, e.g. "[Src/Date]". NO-GO surface -> "" (empty
    string -- no formula emitted).
    """
    s = SURFACES if surfaces is None else surfaces
    if not grain_control_id:
        raise ValueError("grain_control_id required")
    if not date_ref:
        raise ValueError("date_ref required")
    if not s["dynamic_grain"]:
        return ""
    return (
        'Switch([%s],"Week",DateTrunc("week",%s),'
        '"Month",DateTrunc("month",%s),DateTrunc("day",%s))'
    ) % (grain_control_id, date_ref, date_ref, date_ref)


def filter_row(controls, surfaces=None):
    """Returns a list of `list` control element specs, each bound to a base
    source column and filtering one or more target elements -- the reused
    master-detail control->element-filter shape. `controls` is a list of
    descriptor dicts (string keys, NOT final JSON -- consumed here, like
    composition.py's `elements`):
      {"id":, "control_id":, "name":, "source_element_id":, "column_id":,
       "filter_targets": [{"element_id":, "column_id":}, ...]}
    NO-GO surface -> [] (no controls emitted).
    """
    s = SURFACES if surfaces is None else surfaces
    if not s["filter_row"]:
        return []
    out = []
    for c in (controls or []):
        out.append({
            "id": c["id"],
            "kind": "control",
            "controlId": c["control_id"],
            "name": c["name"],
            "controlType": "list",
            "mode": "include",
            "selectionMode": "single",
            "values": [],
            "source": {
                "kind": "source",
                "source": {"kind": "table", "elementId": c["source_element_id"]},
                "columnId": c["column_id"],
            },
            "filters": [
                {"source": {"kind": "table", "elementId": t["element_id"]}, "columnId": t["column_id"]}
                for t in (c.get("filter_targets") or [])
            ],
        })
    return out


def wide_pivot(id, source_element_id, rows_by, values, columns, surfaces=None):
    """Returns a `pivot-table` element biased WIDE: columns=columns
    (REQUIRED -- an already-shaped [{"id":,"name":,"formula":}, ...] array,
    the pivot's OWN columns per tables.md's pivot recipe; each `formula`
    references the source element's fields directly, e.g. "[Src/Region]"
    for a passthrough dimension or "Sum([Src/Revenue])" for a measure --
    passed through verbatim, same convention as kpi_card.build's `columns`).
    rowsBy=rows_by and values=values then reference these columns' OWN ids
    (NOT the source element's column ids) -- rows_by is already-shaped
    [{"id":...}, ...] shelf entries, values is a plain metric id-string
    list. columnsBy=[] (must be empty -- a non-crosstab pivot). Omitting
    `columns` (or passing an empty list) 400s live ("Invalid kind:
    \\"pivot-table\\"" -- a misleading message; the real cause is the
    missing `columns` array), so it's a required, non-empty param here
    (Task-6 live finding). Grand totals are a UI-only setting, not a spec
    field -- not emitted here; note it in caller docs, don't guess a field
    name. NO-GO surface -> {"opt_in": True, "id": id}.
    """
    s = SURFACES if surfaces is None else surfaces
    if not id:
        raise ValueError("id required")
    if not source_element_id:
        raise ValueError("source_element_id required")
    if not columns:
        raise ValueError("columns required")
    if not s["wide_pivot"]:
        return {"opt_in": True, "id": id}
    return {
        "id": id,
        "kind": "pivot-table",
        "source": {"kind": "table", "elementId": source_element_id},
        "columns": columns,
        "rowsBy": rows_by,
        "columnsBy": [],
        "values": values,
    }


def agent(id, name, instructions, data_source_ids, tools=None, surfaces=None):
    """Returns a workbook-level `agents[]` entry (NOT a page element -- the
    workbook spec's top-level `agents:` array; pair with `chat` below for
    the page-level element that surfaces it). `data_source_ids` map 1:1, in
    order, to `dataSources:[{"kind":"table","elementId":}, ...]`. `tools`
    empty/None (the default) means a READ-ONLY analyst -- the returned dict
    OMITS the `tools` key entirely (not `tools=[]`); this exact omission is
    the live-verified read-only shape (WS4 design doc). Pass a non-empty
    `tools` list (already-shaped {"toolId","kind":"action","name",
    "description","steps":[...]} entries) for a write/action agent -- added
    verbatim, never reshaped here. Sigma's AI-agent feature is an org-level
    gate: when it's off for the target org, the agent/chat surface degrades
    to a static element rather than a 400 (see `chat`'s docstring and the
    actions/agent workflow doc for the caller-side fallback pattern).
    NO-GO surface -> {"opt_in": True, "id": id}: never emit a faked agent.
    """
    s = SURFACES if surfaces is None else surfaces
    if not id:
        raise ValueError("id required")
    if not name:
        raise ValueError("name required")
    if not instructions:
        raise ValueError("instructions required")
    if not s["agent"]:
        return {"opt_in": True, "id": id}
    out = {
        "id": id,
        "name": name,
        "instructions": instructions,
        "dataSources": [{"kind": "table", "elementId": eid} for eid in (data_source_ids or [])],
    }
    if tools:
        out["tools"] = tools
    return out


def chat(id, agent_id, surfaces=None):
    """Returns the page-level `chat` element that surfaces an `agent`
    entry: {id, kind: "chat", agentId}. `agent_id` is the AGENT's `id` (the
    same string used in the `agents[]` entry `agent` built above), not an
    element id. Same org-feature gate as `agent` -- when Sigma AI agents are
    off for the target org, callers should degrade to a static text element
    with sample prompts instead (Connor's fallback; documented in the
    actions/agent workflow doc, not re-derived here). NO-GO surface ->
    {"opt_in": True, "id": id}: never emit a faked chat element.
    """
    s = SURFACES if surfaces is None else surfaces
    if not id:
        raise ValueError("id required")
    if not agent_id:
        raise ValueError("agent_id required")
    if not s["agent"]:
        return {"opt_in": True, "id": id}
    return {"id": id, "kind": "chat", "agentId": agent_id}
