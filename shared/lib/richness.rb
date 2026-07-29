# frozen_string_literal: true
#
# richness.rb — Ruby twin of shared/lib/richness.py. Independent, optional
# "richness" pieces for a dashboard page — each helper emits ONE
# spec-authorable fragment, never a whole workbook/page. Consumed by callers
# that already have Composition/Styling output and want to layer in an
# AI-generated insight, a dynamic date-grain control+dimension, a filter row,
# a wide (non-crosstab) pivot table, or a workbook AI agent + chat element.
# Ruby 2.6, stdlib only. Twins emit byte-identical output
# (shared/lib/testdata/richness_golden.json).
#
#   require_relative 'lib/richness'
#   Richness.ai_insight(id: 'ai-1', prompt: 'Say hello.')
#   ctl = Richness.grain_control(id: 'GrainCtl')
#   dim = Richness.trend_dimension(grain_control_id: 'GrainCtl', date_ref: '[Src/Date]')
#   ag = Richness.agent(id: 'ag-1', name: 'Analyst', instructions: 'Be helpful.', data_source_ids: ['src'])
#   chat = Richness.chat(id: 'chat-1', agent_id: 'ag-1')
#
# GO/NO-GO provenance (.superpowers/sdd/richness-task-1-report.md, workbook
# 05cd3ac1-c8cc-4252-bad6-38b33d87bf45):
#   - CallText/AI-insight: GO. CallText's real signature is
#     CallText(<warehouse_function_name>, ...args) — there is NO separate
#     connection argument (an earlier plan/spec assumption was wrong; this is
#     the corrected shape). Working connection+model verified live: the
#     Sigma Sample Database Snowflake connection, model "llama3.1-8b"
#     (mistral-large2 also returned real text at the raw-SQL probe stage).
#     GO here means "the formula shape is spec-legal and Sigma-side proven to
#     render real text on a configured connection" — it does NOT mean every
#     target org has Cortex enabled. This helper therefore ALWAYS emits the
#     formula when its surface is GO; never fabricate a canned summary
#     in code — the org's own warehouse computes the real text, or the
#     element renders blank until Cortex is configured there.
#   - Dynamic grain (Switch+DateTrunc): GO. Switching the control across
#     Month/Week/Day changed the exported distinct-bucket count exactly as
#     expected (Month=3, Week=14, Day=90 over 90 days of demo data).
#   - filter_row reuses the already-GO master-detail control->element-filter
#     shape (verify-master-detail-e2e.rb), not a new Task-1 richness surface.
#   - wide_pivot reuses the already-GO general pivot-table rowsBy/columnsBy/
#     values shape (sigma-workbooks tables.md; build_workbook.py precedent:
#     rowsBy/columnsBy are [{"id":...}] shelves, values is a plain id-string
#     list) — also not a new Task-1 richness surface.
# All four are gated through SURFACES below anyway (not just the two actual
# Task-1 richness surfaces) so a future regression/deprecation on ANY of
# them can be flipped off in one place, same discipline as styling.rb.
#
# Task-6 live-build fixes (.superpowers/sdd/richness-task-6-report.md,
# workbooks 71ea81cc-bcd6-4039-994c-4a4f8fdd847c /
# c22aab85-0c50-4595-a3b9-b1fb0e7fc6a3): two 400s surfaced running this
# module for real, previously only worked around in the caller, now fixed
# IN the shared module:
#   - wide_pivot 400'd ("Invalid kind: \"pivot-table\"" — a misleading
#     message; the real cause is a pivot-table element with no `columns`
#     array). Fixed by adding a required `columns:` param — an already-
#     shaped [{'id'=>,'name'=>,'formula'=>}, ...] array per tables.md's
#     pivot recipe, emitted verbatim on the element. `rows_by`/`values` now
#     reference these columns' OWN ids, not the source element's column ids.
#   - grain_control 400'd ("controlId: Duplicate id: '<id>'") when the same
#     string was reused for both the control element's `id` and its
#     `controlId`. Fixed by adding a `control_id:` param (default
#     "<id>-ctl") so the two always differ; trend_dimension's
#     `grain_control_id:` must be given that `controlId` (not the element
#     `id`) — see its docstring below.
#
# WS4 Task-1 addition — agent + chat (docs/superpowers/specs/
# 2026-07-29-ws4-agent-gradient-actions-design.md, "Live-verified shape
# facts"): the Sigma workbook AI agent is a workbook-TOP-LEVEL `agents:[]`
# array entry (not a page element), verified live building a Plugs
# command-center workbook (reference build: build-plugs-command-center.rb).
# Read-only analyst = the entry OMITS `tools` entirely. The page-level
# `chat` element just references the agent's id. Sigma's AI-agent feature is
# an org-level toggle — when it's off for a target org, callers should
# degrade to a static text element with sample prompts rather than POST a
# chat element that will masked-fail; that fallback pattern is documented in
# the actions/agent workflow doc, not re-derived here.

require 'json'

module Richness
  # GO/NO-GO map. All 5 are GO today; a NO-GO flip makes the gated helper
  # return an empty/opt-in marker instead of emitting an unverified (or
  # 400-rejected) shape — never a silently-wrong fallback.
  SURFACES = {
    ai_insight: true,     # CallText/AI-insight text element (richness Task-1 GO; renders real text only where the target org's connection has Cortex configured — NEVER a fabricated summary)
    dynamic_grain: true,  # grain_control (segmented control) + trend_dimension (Switch+DateTrunc dimension formula) — richness Task-1 GO
    filter_row: true,     # list control(s) -> element filter, reusing the already-GO master-detail control/filter shape
    wide_pivot: true,     # pivot-table rowsBy + columnsBy:[] + values, reusing the already-GO general Sigma pivot shape
    agent: true           # workbook-level agents[] entry + page-level {kind:"chat"} element — WS4 Task-1 GO; org-feature-gated on the Sigma side (see agent/chat docstrings for the graceful-degrade contract)
  }.freeze

  DEFAULT_MODEL = 'llama3.1-8b'
  GRAIN_VALUES = %w[Week Month Day].freeze
  DEFAULT_GRAIN = 'Month'

  # Returns a `text` element whose body is a CallText/Cortex formula:
  # {{ Replace(CallText("SNOWFLAKE.CORTEX.COMPLETE","<model>", "<prompt>") , '"', "") }}
  # `prompt` is embedded verbatim between the outer quotes the template
  # supplies — callers wanting a formula-composed prompt (e.g. concatenating
  # a live aggregate via `" & Text(Sum(...)) & "`) pass that text as-is; this
  # helper only supplies the CallText/Replace wrapper, never the content.
  # Meant to sit in a light-tint container (caller wraps — this helper builds
  # ONLY the text element). NO-GO surface -> {'opt_in'=>true,'id'=>id}: the
  # formula is withheld, never a faked/hardcoded summary string.
  def self.ai_insight(id:, model: DEFAULT_MODEL, prompt:, surfaces: SURFACES)
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'prompt required' if prompt.to_s.empty?
    return { 'opt_in' => true, 'id' => id } unless surfaces[:ai_insight]

    body = "{{ Replace(CallText(\"SNOWFLAKE.CORTEX.COMPLETE\", \"#{model}\", \"#{prompt}\") , '\"', \"\") }}"
    { 'id' => id, 'kind' => 'text', 'body' => body }
  end

  # Returns a `segmented` control element (Week/Month/Day, default Month).
  # `id` is the control ELEMENT's id; `controlId` is a SEPARATE handle that
  # defaults to "<id>-ctl" when `control_id:` is omitted. The two MUST
  # differ — Sigma 400s ("controlId: Duplicate id: '<id>'") when the same
  # string is reused for both (Task-6 live finding). Pass the returned
  # element's `controlId` (NOT its `id`) as `grain_control_id:` to
  # trend_dimension so its Switch(...) formula references this exact
  # control. NO-GO surface -> {'opt_in'=>true,'id'=>id}.
  def self.grain_control(id:, control_id: nil, name: 'Grain', surfaces: SURFACES)
    raise ArgumentError, 'id required' if id.to_s.empty?
    return { 'opt_in' => true, 'id' => id } unless surfaces[:dynamic_grain]

    cid = control_id.to_s.empty? ? "#{id}-ctl" : control_id
    {
      'id' => id,
      'kind' => 'control',
      'controlId' => cid,
      'name' => name,
      'controlType' => 'segmented',
      'selectionMode' => 'single',
      'value' => DEFAULT_GRAIN,
      'source' => { 'kind' => 'manual', 'valueType' => 'text', 'values' => GRAIN_VALUES }
    }
  end

  # Returns the Switch-driven grain dimension formula string (Task-1
  # verified: Month/Week/Day buckets change on export). `grain_control_id`
  # is grain_control's returned `controlId` (NOT its element `id` — the two
  # are distinct handles, see grain_control above); `date_ref` is a raw
  # Sigma column reference, e.g. "[Src/Date]". NO-GO surface -> '' (empty
  # string — no formula emitted).
  def self.trend_dimension(grain_control_id:, date_ref:, surfaces: SURFACES)
    raise ArgumentError, 'grain_control_id required' if grain_control_id.to_s.empty?
    raise ArgumentError, 'date_ref required' if date_ref.to_s.empty?
    return '' unless surfaces[:dynamic_grain]

    "Switch([#{grain_control_id}],\"Week\",DateTrunc(\"week\",#{date_ref})," \
      "\"Month\",DateTrunc(\"month\",#{date_ref}),DateTrunc(\"day\",#{date_ref}))"
  end

  # Returns an array of `list` control element specs, each bound to a base
  # source column and filtering one or more target elements — the reused
  # master-detail control->element-filter shape. `controls` is an array of
  # descriptor Hashes (symbol keys, NOT final JSON — consumed here, like
  # Composition's `elements:`):
  #   { id:, control_id:, name:, source_element_id:, column_id:,
  #     filter_targets: [{ element_id:, column_id: }, ...] }
  # NO-GO surface -> [] (no controls emitted).
  def self.filter_row(controls:, surfaces: SURFACES)
    return [] unless surfaces[:filter_row]

    (controls || []).map do |c|
      {
        'id' => c[:id],
        'kind' => 'control',
        'controlId' => c[:control_id],
        'name' => c[:name],
        'controlType' => 'list',
        'mode' => 'include',
        'selectionMode' => 'single',
        'values' => [],
        'source' => {
          'kind' => 'source',
          'source' => { 'kind' => 'table', 'elementId' => c[:source_element_id] },
          'columnId' => c[:column_id]
        },
        'filters' => (c[:filter_targets] || []).map do |t|
          { 'source' => { 'kind' => 'table', 'elementId' => t[:element_id] }, 'columnId' => t[:column_id] }
        end
      }
    end
  end

  # Returns a `pivot-table` element biased WIDE: columns: columns (REQUIRED
  # — an already-shaped [{'id'=>...,'name'=>...,'formula'=>...}, ...] array,
  # the pivot's OWN columns per tables.md's pivot recipe; each `formula`
  # references the source element's fields directly, e.g. "[Src/Region]" for
  # a passthrough dimension or "Sum([Src/Revenue])" for a measure — passed
  # through verbatim, same convention as KpiCard.build's `columns:`).
  # rowsBy: rows_by and values: values then reference these columns' OWN
  # ids (NOT the source element's column ids) — rows_by is already-shaped
  # [{"id"=>...}, ...] shelf entries, values is a plain metric id-string
  # list. columnsBy: [] (must be empty — a non-crosstab pivot). Omitting
  # `columns` (or passing an empty array) 400s live ("Invalid kind:
  # \"pivot-table\"" — a misleading message; the real cause is the missing
  # `columns` array), so it's a required, non-empty param here (Task-6 live
  # finding). Grand totals are a UI-only setting, not a spec field — not
  # emitted here; note it in caller docs, don't guess a field name. NO-GO
  # surface -> {'opt_in'=>true,'id'=>id}.
  def self.wide_pivot(id:, source_element_id:, rows_by:, values:, columns:, surfaces: SURFACES)
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'source_element_id required' if source_element_id.to_s.empty?
    raise ArgumentError, 'columns required' if columns.nil? || columns.empty?
    return { 'opt_in' => true, 'id' => id } unless surfaces[:wide_pivot]

    {
      'id' => id,
      'kind' => 'pivot-table',
      'source' => { 'kind' => 'table', 'elementId' => source_element_id },
      'columns' => columns,
      'rowsBy' => rows_by,
      'columnsBy' => [],
      'values' => values
    }
  end

  # Returns a workbook-level `agents[]` entry (NOT a page element — the
  # workbook spec's top-level `agents:` array; pair with `chat` below for the
  # page-level element that surfaces it). `data_source_ids` map 1:1, in
  # order, to `dataSources:[{kind:"table",elementId:}, ...]`. `tools:` empty
  # (the default) means a READ-ONLY analyst — the returned Hash OMITS the
  # `tools` key entirely (not `tools:[]`); this exact omission is the
  # live-verified read-only shape (WS4 design doc). Pass a non-empty
  # `tools:` array (already-shaped `{toolId,kind:"action",name,description,
  # steps:[...]}` entries) for a write/action agent — added verbatim, never
  # reshaped here. Sigma's AI-agent feature is an org-level gate: when it's
  # off for the target org, the agent/chat surface degrades to a static
  # element rather than a 400 (see `chat`'s docstring and the actions/agent
  # workflow doc for the caller-side fallback pattern). NO-GO surface ->
  # {'opt_in'=>true,'id'=>id}: never emit a faked agent.
  def self.agent(id:, name:, instructions:, data_source_ids:, tools: [], surfaces: SURFACES)
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'name required' if name.to_s.empty?
    raise ArgumentError, 'instructions required' if instructions.to_s.empty?
    return { 'opt_in' => true, 'id' => id } unless surfaces[:agent]

    out = {
      'id' => id,
      'name' => name,
      'instructions' => instructions,
      'dataSources' => (data_source_ids || []).map { |eid| { 'kind' => 'table', 'elementId' => eid } }
    }
    out['tools'] = tools unless tools.nil? || tools.empty?
    out
  end

  # Returns the page-level `chat` element that surfaces an `agent` entry:
  # {id, kind:"chat", agentId}. `agent_id` is the AGENT's `id` (the same
  # string used in the `agents[]` entry `agent` built above), not an
  # element id. Same org-feature gate as `agent` — when Sigma AI agents are
  # off for the target org, callers should degrade to a static text element
  # with sample prompts instead (Connor's fallback; documented in the
  # actions/agent workflow doc, not re-derived here). NO-GO surface ->
  # {'opt_in'=>true,'id'=>id}: never emit a faked chat element.
  def self.chat(id:, agent_id:, surfaces: SURFACES)
    raise ArgumentError, 'id required' if id.to_s.empty?
    raise ArgumentError, 'agent_id required' if agent_id.to_s.empty?
    return { 'opt_in' => true, 'id' => id } unless surfaces[:agent]

    { 'id' => id, 'kind' => 'chat', 'agentId' => agent_id }
  end
end
