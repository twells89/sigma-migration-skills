# frozen_string_literal: true
# test_richness.rb — run directly: ruby shared/lib/test_richness.rb
require 'json'
require_relative 'richness'
$failures = 0
def check(desc); ok = yield; puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}"); $failures += 1 unless ok; end

# Deep-sort hashes/arrays so twin/golden comparison is key-order-independent.
def sort_deep(o)
  case o
  when Hash then o.keys.sort.each_with_object({}) { |k, h| h[k] = sort_deep(o[k]) }
  when Array then o.map { |e| sort_deep(e) }
  else o
  end
end

check('SURFACES: all 5 richness surfaces are GO') do
  expected = %i[agent ai_insight dynamic_grain filter_row wide_pivot]
  Richness::SURFACES.keys.sort == expected.sort && Richness::SURFACES.values.all? { |v| v == true }
end

# --- ai_insight -------------------------------------------------------------

check('ai_insight: default model + body contains the CallText(...) formula') do
  el = Richness.ai_insight(id: 'ai-rev', prompt: 'Summarize revenue trends for the period.')
  el['id'] == 'ai-rev' && el['kind'] == 'text' &&
    el['body'].include?('{{ Replace(CallText("SNOWFLAKE.CORTEX.COMPLETE", "llama3.1-8b", ' \
                         '"Summarize revenue trends for the period.") , \'"\', "") }}')
end
check('ai_insight: custom model is used verbatim') do
  el = Richness.ai_insight(id: 'ai-rev2', model: 'mistral-large2', prompt: 'Say hi.')
  el['body'].include?('CallText("SNOWFLAKE.CORTEX.COMPLETE", "mistral-large2", "Say hi.")')
end
check('ai_insight: no separate connection argument — CallText warehouse fn is the FIRST arg') do
  el = Richness.ai_insight(id: 'ai-rev3', prompt: 'x')
  el['body'] =~ /CallText\("SNOWFLAKE\.CORTEX\.COMPLETE",\s*"[^"]+",\s*"[^"]*"\)/
end
check('ai_insight: id required') do
  begin; Richness.ai_insight(id: '', prompt: 'x'); false
  rescue ArgumentError; true; end
end
check('ai_insight: prompt required') do
  begin; Richness.ai_insight(id: 'x', prompt: ''); false
  rescue ArgumentError; true; end
end
check('ai_insight: NO-GO surface -> opt-in marker, never a faked summary') do
  el = Richness.ai_insight(id: 'ai-rev', prompt: 'x', surfaces: Richness::SURFACES.merge(ai_insight: false))
  el == { 'opt_in' => true, 'id' => 'ai-rev' }
end

# --- grain_control / trend_dimension ---------------------------------------

check('grain_control: segmented control, Week/Month/Day, default Month') do
  ctl = Richness.grain_control(id: 'GrainCtl')
  ctl == {
    'id' => 'GrainCtl', 'kind' => 'control', 'controlId' => 'GrainCtl-ctl',
    'name' => 'Grain', 'controlType' => 'segmented', 'selectionMode' => 'single',
    'value' => 'Month',
    'source' => { 'kind' => 'manual', 'valueType' => 'text', 'values' => %w[Week Month Day] }
  }
end
check('grain_control: element id and controlId are DISTINCT (Duplicate id 400 fix)') do
  ctl = Richness.grain_control(id: 'GrainCtl')
  ctl['id'] != ctl['controlId'] && ctl['id'] == 'GrainCtl' && ctl['controlId'] == 'GrainCtl-ctl'
end
check('grain_control: control_id: override is honored and still distinct from id') do
  ctl = Richness.grain_control(id: 'GrainCtl', control_id: 'GrainCtlHandle')
  ctl['id'] == 'GrainCtl' && ctl['controlId'] == 'GrainCtlHandle'
end
check('grain_control: id required') do
  begin; Richness.grain_control(id: ''); false
  rescue ArgumentError; true; end
end
check('grain_control: NO-GO surface -> opt-in marker') do
  ctl = Richness.grain_control(id: 'GrainCtl', surfaces: Richness::SURFACES.merge(dynamic_grain: false))
  ctl == { 'opt_in' => true, 'id' => 'GrainCtl' }
end

check('trend_dimension: exact Switch(...) string (Task-1 verified pattern)') do
  Richness.trend_dimension(grain_control_id: 'GrainCtl-ctl', date_ref: '[Src/Date]') ==
    'Switch([GrainCtl-ctl],"Week",DateTrunc("week",[Src/Date]),' \
    '"Month",DateTrunc("month",[Src/Date]),DateTrunc("day",[Src/Date]))'
end
check('trend_dimension: references grain_control\'s controlId (not its element id)') do
  ctl = Richness.grain_control(id: 'GrainCtl')
  dim = Richness.trend_dimension(grain_control_id: ctl['controlId'], date_ref: '[Src/Date]')
  dim.include?("[#{ctl['controlId']}]") && !dim.include?("[#{ctl['id']}]")
end
check('trend_dimension: grain_control_id required') do
  begin; Richness.trend_dimension(grain_control_id: '', date_ref: '[Src/Date]'); false
  rescue ArgumentError; true; end
end
check('trend_dimension: date_ref required') do
  begin; Richness.trend_dimension(grain_control_id: 'GrainCtl-ctl', date_ref: ''); false
  rescue ArgumentError; true; end
end
check('trend_dimension: NO-GO surface -> empty string') do
  Richness.trend_dimension(grain_control_id: 'GrainCtl-ctl', date_ref: '[Src/Date]',
                            surfaces: Richness::SURFACES.merge(dynamic_grain: false)) == ''
end

# --- filter_row --------------------------------------------------------------

FILTER_CONTROLS = [
  { id: 'ctl-region', control_id: 'RegionCtl', name: 'Region', source_element_id: 'src',
    column_id: 'col-region', filter_targets: [{ element_id: 'detail-tbl', column_id: 'dt-region' }] },
  { id: 'ctl-category', control_id: 'CategoryCtl', name: 'Category', source_element_id: 'src',
    column_id: 'col-category', filter_targets: [
      { element_id: 'detail-tbl', column_id: 'dt-category' },
      { element_id: 'master-chart', column_id: 'mc-category' }
    ] }
].freeze

check('filter_row: emits one list-control element per descriptor, bound to the base') do
  rows = Richness.filter_row(controls: FILTER_CONTROLS)
  rows.length == 2 &&
    rows[0] == {
      'id' => 'ctl-region', 'kind' => 'control', 'controlId' => 'RegionCtl',
      'name' => 'Region', 'controlType' => 'list', 'mode' => 'include',
      'selectionMode' => 'single', 'values' => [],
      'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'src' },
                    'columnId' => 'col-region' },
      'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'detail-tbl' }, 'columnId' => 'dt-region' }]
    }
end
check('filter_row: a control can filter multiple target elements') do
  rows = Richness.filter_row(controls: FILTER_CONTROLS)
  rows[1]['filters'] == [
    { 'source' => { 'kind' => 'table', 'elementId' => 'detail-tbl' }, 'columnId' => 'dt-category' },
    { 'source' => { 'kind' => 'table', 'elementId' => 'master-chart' }, 'columnId' => 'mc-category' }
  ]
end
check('filter_row: empty controls list -> empty array') do
  Richness.filter_row(controls: []) == []
end
check('filter_row: NO-GO surface -> empty array') do
  Richness.filter_row(controls: FILTER_CONTROLS, surfaces: Richness::SURFACES.merge(filter_row: false)) == []
end

# --- wide_pivot --------------------------------------------------------------

PIVOT_COLUMNS = [
  { 'id' => 'piv-region', 'name' => 'Region', 'formula' => '[Src/Region]' },
  { 'id' => 'piv-category', 'name' => 'Category', 'formula' => '[Src/Category]' },
  { 'id' => 'piv-revenue', 'name' => 'Revenue', 'formula' => 'Sum([Src/Revenue])' },
  { 'id' => 'piv-orders', 'name' => 'Orders', 'formula' => 'Sum([Src/Orders])' },
  { 'id' => 'piv-margin', 'name' => 'Margin', 'formula' => 'Avg([Src/Margin])' }
].freeze

check('wide_pivot: pivot-table with columns, rowsBy, columnsBy:[], values (metric id strings)') do
  piv = Richness.wide_pivot(id: 'piv-1', source_element_id: 'src',
                             columns: PIVOT_COLUMNS,
                             rows_by: [{ 'id' => 'piv-region' }, { 'id' => 'piv-category' }],
                             values: %w[piv-revenue piv-orders piv-margin])
  piv == {
    'id' => 'piv-1', 'kind' => 'pivot-table',
    'source' => { 'kind' => 'table', 'elementId' => 'src' },
    'columns' => PIVOT_COLUMNS,
    'rowsBy' => [{ 'id' => 'piv-region' }, { 'id' => 'piv-category' }],
    'columnsBy' => [],
    'values' => %w[piv-revenue piv-orders piv-margin]
  }
end
check('wide_pivot: columns is a non-empty array (Invalid-kind 400 fix)') do
  piv = Richness.wide_pivot(id: 'piv-1', source_element_id: 'src', columns: PIVOT_COLUMNS,
                             rows_by: [{ 'id' => 'piv-region' }, { 'id' => 'piv-category' }],
                             values: %w[piv-revenue piv-orders piv-margin])
  piv['columns'].is_a?(Array) && !piv['columns'].empty?
end
check('wide_pivot: columnsBy is always [] (wide, not crosstab)') do
  Richness.wide_pivot(id: 'piv-2', source_element_id: 'src', columns: [{ 'id' => 'c1', 'formula' => '[Src/C1]' }],
                       rows_by: [{ 'id' => 'c1' }], values: ['c2'])['columnsBy'] == []
end
check('wide_pivot: id required') do
  begin
    Richness.wide_pivot(id: '', source_element_id: 'src', columns: PIVOT_COLUMNS, rows_by: [], values: [])
    false
  rescue ArgumentError; true; end
end
check('wide_pivot: source_element_id required') do
  begin
    Richness.wide_pivot(id: 'p', source_element_id: '', columns: PIVOT_COLUMNS, rows_by: [], values: [])
    false
  rescue ArgumentError; true; end
end
check('wide_pivot: columns required (nil 400 fix)') do
  begin; Richness.wide_pivot(id: 'p', source_element_id: 'src', columns: nil, rows_by: [], values: []); false
  rescue ArgumentError; true; end
end
check('wide_pivot: columns required (empty array 400 fix)') do
  begin; Richness.wide_pivot(id: 'p', source_element_id: 'src', columns: [], rows_by: [], values: []); false
  rescue ArgumentError; true; end
end
check('wide_pivot: NO-GO surface -> opt-in marker') do
  piv = Richness.wide_pivot(id: 'piv-1', source_element_id: 'src', columns: PIVOT_COLUMNS, rows_by: [], values: [],
                             surfaces: Richness::SURFACES.merge(wide_pivot: false))
  piv == { 'opt_in' => true, 'id' => 'piv-1' }
end

# --- agent / chat -------------------------------------------------------------

AGENT_TOOLS = [
  { 'toolId' => 't-log-note', 'kind' => 'action', 'name' => 'Log note', 'description' => 'Insert a review note.',
    'steps' => [{ 'kind' => 'effect', 'effect' => 'insert-rows', 'table' => 'annotations',
                  'value' => { 'type' => 'agent-input', 'inputName' => 'note' } }] }
].freeze

check('agent: read-only analyst (tools: []) OMITS the tools key entirely') do
  el = Richness.agent(id: 'ag-1', name: 'Analyst', instructions: 'Be a helpful retail analyst.',
                       data_source_ids: ['src'])
  el == {
    'id' => 'ag-1', 'name' => 'Analyst', 'instructions' => 'Be a helpful retail analyst.',
    'dataSources' => [{ 'kind' => 'table', 'elementId' => 'src' }]
  } && !el.key?('tools')
end
check('agent: multiple data_source_ids map to multiple dataSources entries, in order') do
  el = Richness.agent(id: 'ag-1', name: 'Analyst', instructions: 'x', data_source_ids: %w[src-a src-b])
  el['dataSources'] == [{ 'kind' => 'table', 'elementId' => 'src-a' }, { 'kind' => 'table', 'elementId' => 'src-b' }]
end
check('agent: non-empty tools: is added verbatim') do
  el = Richness.agent(id: 'ag-2', name: 'Assistant', instructions: 'Act on my behalf.',
                       data_source_ids: ['src'], tools: AGENT_TOOLS)
  el['tools'] == AGENT_TOOLS && el.key?('tools')
end
check('agent: id required') do
  begin
    Richness.agent(id: '', name: 'A', instructions: 'x', data_source_ids: ['src']); false
  rescue ArgumentError; true; end
end
check('agent: name required') do
  begin
    Richness.agent(id: 'ag-1', name: '', instructions: 'x', data_source_ids: ['src']); false
  rescue ArgumentError; true; end
end
check('agent: instructions required') do
  begin
    Richness.agent(id: 'ag-1', name: 'A', instructions: '', data_source_ids: ['src']); false
  rescue ArgumentError; true; end
end
check('agent: NO-GO surface -> opt-in marker, never a faked agent') do
  el = Richness.agent(id: 'ag-1', name: 'A', instructions: 'x', data_source_ids: ['src'],
                       surfaces: Richness::SURFACES.merge(agent: false))
  el == { 'opt_in' => true, 'id' => 'ag-1' }
end

check('chat: {id, kind: chat, agentId} shape') do
  Richness.chat(id: 'chat-1', agent_id: 'ag-1') == { 'id' => 'chat-1', 'kind' => 'chat', 'agentId' => 'ag-1' }
end
check('chat: id required') do
  begin
    Richness.chat(id: '', agent_id: 'ag-1'); false
  rescue ArgumentError; true; end
end
check('chat: agent_id required') do
  begin
    Richness.chat(id: 'chat-1', agent_id: ''); false
  rescue ArgumentError; true; end
end
check('chat: NO-GO surface -> opt-in marker, never a faked chat element') do
  el = Richness.chat(id: 'chat-1', agent_id: 'ag-1', surfaces: Richness::SURFACES.merge(agent: false))
  el == { 'opt_in' => true, 'id' => 'chat-1' }
end

# --- golden ------------------------------------------------------------------

golden = JSON.parse(File.read(File.join(__dir__, 'testdata', 'richness_golden.json')))
check('helpers match richness_golden.json (sorted-key identical)') do
  actual = {
    'agent' => Richness.agent(id: 'ag-1', name: 'Analyst', instructions: 'Be a helpful retail analyst.',
                               data_source_ids: ['src']),
    'agent_with_tools' => Richness.agent(id: 'ag-2', name: 'Assistant', instructions: 'Act on my behalf.',
                                          data_source_ids: ['src'], tools: AGENT_TOOLS),
    'chat' => Richness.chat(id: 'chat-1', agent_id: 'ag-1'),
    'ai_insight' => Richness.ai_insight(id: 'ai-rev', prompt: 'Summarize revenue trends for the period.'),
    'ai_insight_custom_model' => Richness.ai_insight(id: 'ai-rev2', model: 'mistral-large2',
                                                      prompt: 'Say one nice thing about the data.'),
    'grain_control' => Richness.grain_control(id: 'GrainCtl'),
    'trend_dimension' => Richness.trend_dimension(grain_control_id: 'GrainCtl-ctl', date_ref: '[Src/Date]'),
    'filter_row' => Richness.filter_row(controls: FILTER_CONTROLS),
    'wide_pivot' => Richness.wide_pivot(id: 'piv-1', source_element_id: 'src',
                                         columns: PIVOT_COLUMNS,
                                         rows_by: [{ 'id' => 'piv-region' }, { 'id' => 'piv-category' }],
                                         values: %w[piv-revenue piv-orders piv-margin])
  }
  JSON.generate(sort_deep(actual)) == JSON.generate(sort_deep(golden))
end

exit($failures.zero? ? 0 : 1)
