#!/usr/bin/env ruby
# Regression test for v5.0 multi-DS AUTO-ROUTING (three rounds' #1 recurring
# gap, mechanized). route_multi_ds! must:
#   1. leave dominant-datasource charts untouched (source + formulas),
#   2. repoint each MECHANICAL outlier chart at a lazily-created hidden
#      sub-master ("Master (<caption>)", __DM_ELEMENT__ placeholder) and
#      rewrite its [Master/…] formulas in lock-step,
#   3. give the sub-master exactly the passthrough columns its charts consume
#      (formulas [<caption>/<col>], prefix-rewritten later by the orchestrator
#      resolver when the live DM element name differs),
#   4. NOT route non-mechanical charts (source != the shared master — window/
#      LOD/two-stage helper paths keep the WARN wall),
#   5. no-op on a single-datasource plan / nil plan.
#
# Pure-function test: extracts route_multi_ds! from build-charts-from-signals.rb.
# Usage:  ruby scripts/test-multi-ds-routing.rb
require 'json'
# Ruby 2.6 floor: this test READS a sibling script and eval()s a method out
# of it, so that script's own require_relative lines never run -- the test
# must supply the polyfill itself. See shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
%w[
  strip_tableau_comments translate_sla_ratio split_top_level_args
  parse_tableau_function_call translated_calc_reference
  translate_user_agg_formula deep_gsub! route_multi_ds!
].each do |fn|
  m = SRC.match(/^def #{Regexp.escape(fn)}.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

PLAN = {
  'independent' => true,
  'datasources' => [
    { 'name' => 'federated.aaa', 'caption' => 'Main Paths',
      'worksheets' => ['Sheet A', 'Sheet B', 'Sheet C'] },
    { 'name' => 'federated.bbb', 'caption' => 'Dir Bias by Level',
      'worksheets' => ['% of total by room name'] }
  ]
}.freeze

def mk_elements
  [
    { 'id' => 'el-a', 'kind' => 'bar-chart', 'name' => 'Sheet A', '_worksheet' => 'Sheet A',
      'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => [{ 'id' => 'a-x', 'name' => 'Dir', 'formula' => '[Master/Dir]' }] },
    { 'id' => 'el-room', 'kind' => 'pivot-table', 'name' => '% of total by room name',
      '_worksheet' => '% of total by room name',
      'source' => { 'kind' => 'table', 'elementId' => 'master' },
      'columns' => [
        { 'id' => 'r-room', 'name' => 'Room Name', 'formula' => '[Master/Room Name]' },
        { 'id' => 'r-share', 'name' => 'Share', 'formula' => 'Sum([Master/Share])' }
      ] },
    # outlier worksheet but NON-mechanical (already on a helper source)
    { 'id' => 'el-helper', 'kind' => 'bar-chart', 'name' => 'helper-backed',
      '_worksheet' => '% of total by room name',
      'source' => { 'kind' => 'table', 'elementId' => 'el-room-grain-src' },
      'columns' => [{ 'id' => 'h-x', 'name' => 'X', 'formula' => '[Master/X]' }] }
  ]
end

puts 'Part 1 — outlier mechanical chart routed; dominant untouched'
els = mk_elements
data_els = []
warnings = []
routed = route_multi_ds!(els, data_els, JSON.parse(JSON.generate(PLAN)), 'master', warnings)
a = els.find { |e| e['id'] == 'el-a' }
room = els.find { |e| e['id'] == 'el-room' }
helper = els.find { |e| e['id'] == 'el-helper' }
check(routed == { '% of total by room name' => 'Dir Bias by Level' },
      "routed map names the outlier ws → caption (got #{routed.inspect})", fails)
check(a['source'] == { 'kind' => 'table', 'elementId' => 'master' } &&
      a['columns'][0]['formula'] == '[Master/Dir]',
      'dominant chart untouched (source + formulas)', fails)
check(room['source'] == { 'kind' => 'table', 'elementId' => 'submaster-dirbiasbylevel' },
      "outlier repointed at the sub-master (got #{room['source'].inspect})", fails)
check(room['columns'].map { |c| c['formula'] } ==
        ['[Master (Dir Bias by Level)/Room Name]', 'Sum([Master (Dir Bias by Level)/Share])'],
      "outlier formulas rewritten in lock-step (got #{room['columns'].map { |c| c['formula'] }.inspect})", fails)

puts
puts 'Part 2 — sub-master shape: placeholder source + exact passthrough columns'
sm = data_els.find { |e| e['id'] == 'submaster-dirbiasbylevel' }
check(!sm.nil?, 'ONE hidden sub-master emitted into data_elements', fails)
check(sm && sm['name'] == 'Master (Dir Bias by Level)' && sm['visibleAsSource'] == false,
      "sub-master named after the datasource caption, hidden (got #{sm && sm['name']})", fails)
check(sm && sm['source'] == { 'kind' => 'data-model', 'elementId' => '__DM_ELEMENT__:Dir Bias by Level' },
      'sub-master sources the DM element via the resolver placeholder', fails)
check(sm && sm['columns'].map { |c| [c['name'], c['formula']] } ==
        [['Room Name', '[Dir Bias by Level/Room Name]'], ['Share', '[Dir Bias by Level/Share]']],
      "sub-master passthrough columns = exactly what its charts consume (got #{sm && sm['columns'].inspect})", fails)

puts
puts 'Part 3 — scope cut: non-mechanical outlier chart NOT routed'
check(helper['source'] == { 'kind' => 'table', 'elementId' => 'el-room-grain-src' } &&
      helper['columns'][0]['formula'] == '[Master/X]',
      'helper-backed chart untouched (keeps the WARN wall)', fails)

puts
puts 'Part 4 — no-ops'
els2 = mk_elements
r2 = route_multi_ds!(els2, [], { 'datasources' => [PLAN['datasources'][0]] }, 'master', [])
check(r2 == {} && els2[1]['columns'][1]['formula'] == 'Sum([Master/Share])',
      'single-datasource plan → no routing', fails)
r3 = route_multi_ds!(mk_elements, [], nil, 'master', [])
check(r3 == {}, 'nil plan → no routing', fails)

puts
puts 'Part 5 — review-caught hardening (quoted captions, control retargeting, id collisions)'
# A caption with quotes/backslash/brackets must not corrupt anything (the old
# JSON-text splice raised mid-loop and left dangling sub-masters).
qplan = { 'datasources' => [
  { 'name' => 'federated.aaa', 'caption' => 'Main', 'worksheets' => ['Sheet A', 'Sheet B'] },
  { 'name' => 'federated.bbb', 'caption' => 'Sales "West" [v2]/\\raw', 'worksheets' => ['% of total by room name'] }
] }
els5 = mk_elements
de5 = []
w5 = []
r5 = route_multi_ds!(els5, de5, qplan, 'master', w5)
room5 = els5.find { |e| e['id'] == 'el-room' }
sm5 = de5.first
check(r5.size == 1 && sm5 && sm5['name'] == 'Master (Sales West v2 raw)',
      "quoted/bracketed caption routed safely, unsafe chars stripped (name=#{sm5 && sm5['name'].inspect})", fails)
check(room5['columns'][0]['formula'].include?('[Master (') &&
      !room5['columns'][0]['formula'].include?('[') == false &&
      !room5['columns'][0]['formula'].include?('\\'),
      "formula refs carry the SANITIZED caption, no escapes (got #{room5['columns'][0]['formula'].inspect})", fails)
check(sm5['source']['elementId'] == '__DM_ELEMENT__:Sales "West" [v2]/\\raw',
      'placeholder keeps the RAW caption (resolver matches normalized)', fails)

# Control retargeting: a master-targeted filter also targets the sub-master
# when it exposes the column; missing columns are named residue, not guessed.
els6 = mk_elements
de6 = []
w6 = []
ctl_reach = { 'name' => 'Room Filter', 'kind' => 'control',
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-room' }] }
ctl_miss  = { 'name' => 'Region Filter', 'kind' => 'control',
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-region' }] }
route_multi_ds!(els6, de6, JSON.parse(JSON.generate(PLAN)), 'master', w6,
                controls: [ctl_reach, ctl_miss],
                id2name: { 'm-room' => 'Room Name', 'm-region' => 'Region' })
sm6 = de6.first
sm_target = ctl_reach['filters'].find { |t| t.dig('source', 'elementId') == sm6['id'] }
check(!sm_target.nil? && sm_target['columnId'] == sm6['columns'].find { |c| c['name'] == 'Room Name' }['id'],
      'control targeting a master column the sub-master exposes gains a sub-master target', fails)
check(ctl_miss['filters'].none? { |t| t.dig('source', 'elementId') == sm6['id'] } &&
      w6.any? { |m| m.include?('Region Filter') && m.include?('does not expose') },
      'control on a column the outlier lacks stays master-only + named residue', fails)

# 24-char normalized-id collision → unique suffixed ids.
cplan = { 'datasources' => [
  { 'name' => 'f.a', 'caption' => 'Main', 'worksheets' => %w[W1 W2] },
  { 'name' => 'f.b', 'caption' => 'North America Sales Extract 2024', 'worksheets' => ['O1'] },
  { 'name' => 'f.c', 'caption' => 'North America Sales Extract 2025', 'worksheets' => ['O2'] }
] }
els7 = %w[O1 O2].map do |ws|
  { 'id' => "el-#{ws.downcase}", 'kind' => 'bar-chart', 'name' => ws, '_worksheet' => ws,
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [{ 'id' => "#{ws.downcase}-x", 'name' => 'X', 'formula' => '[Master/X]' }] }
end
de7 = []
route_multi_ds!(els7, de7, cplan, 'master', [])
check(de7.size == 2 && de7.map { |s| s['id'] }.uniq.size == 2,
      "long-caption siblings get UNIQUE sub-master ids (got #{de7.map { |s| s['id'] }.inspect})", fails)

puts
puts 'Part 6 — v5.4 derived calcs on the sub-master'
# A routed chart's [Master/<name>] ref can name a Tableau CALC, not a physical
# column of the outlier datasource. Contract:
#   row-level calc  → DERIVED column on the sub-master (translated formula),
#   aggregated calc → decomposed at viz level; sub-master exposes base columns;
#                     on a row-grain HELPER the passthrough is dropped and
#                     CONSUMER formulas rewritten,
#   untranslatable  → NO column + loud STAYS-MANUAL (never a broken passthrough).
%w[map_column translate_user_agg_formula translate_row_level_calc translate_dim_calc].each do |fn|
  m = SRC.match(/^def #{Regexp.escape(fn)}\b.*?\n^end$/m) or abort("could not extract #{fn}")
  eval(m[0]) # rubocop:disable Security/Eval
end
USER_AGG_FN = { 'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max', 'MEDIAN' => 'Median' }.freeze

CBG = {
  'Calc_1' => { 'caption' => 'Room Clean', 'formula' => 'REPLACE([RoomName], "Act 1 - ", "")' },
  'Calc_2' => { 'caption' => '% Lab',      'formula' => 'SUM([Count])/SUM([Sum_Count])' },
  'Calc_3' => { 'caption' => 'Opaque',     'formula' => "RAWSQL_STR('x')" }
}.freeze

els8 = [
  { 'id' => 'el-room2', 'kind' => 'pivot-table', 'name' => '% of total by room name',
    '_worksheet' => '% of total by room name',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [
      { 'id' => 'q-room', 'name' => 'Room Clean', 'formula' => '[Master/Room Clean]' },
      { 'id' => 'q-lab',  'name' => '% Lab',      'formula' => 'Sum([Master/% Lab])' },
      { 'id' => 'q-op',   'name' => 'Opaque',     'formula' => 'Sum([Master/Opaque])' }
    ] }
]
de8 = []
w8 = []
route_multi_ds!(els8, de8, JSON.parse(JSON.generate(PLAN)), 'master', w8, cbg: CBG, mmap: {})
sm8 = de8.first
check(!sm8.nil?, 'derived-calc case still creates the sub-master', fails)
rc = sm8 && sm8['columns'].find { |c| c['name'] == 'Room Clean' }
check(rc && rc['formula'] == 'Replace([Dir Bias by Level/RoomName], "Act 1 - ", "")',
      "row-level calc becomes a DERIVED sub-master column (got #{rc && rc['formula']})", fails)
lab = els8[0]['columns'].find { |c| c['id'] == 'q-lab' }
check(lab['formula'] == 'Sum([Master (Dir Bias by Level)/Count])/Sum([Master (Dir Bias by Level)/Sum_Count])',
      "aggregated calc decomposed at viz level (got #{lab['formula']})", fails)
check(sm8 && %w[Count Sum_Count].all? { |n| sm8['columns'].any? { |c| c['name'] == n } },
      'sub-master exposes the decomposition base columns', fails)
check(sm8 && sm8['columns'].none? { |c| c['name'] == '% Lab' },
      'no row-grain passthrough for the aggregated calc', fails)
check(sm8 && sm8['columns'].none? { |c| c['name'] == 'Opaque' },
      'untranslatable calc gets NO sub-master column', fails)
check(w8.any? { |m| m.include?('STAYS-MANUAL') && m.include?('Opaque') },
      'untranslatable calc is flagged STAYS-MANUAL by name', fails)

# Row-grain helper variant: the tagged helper carries the calc passthrough;
# its consumer chart wraps the helper column. The passthrough must be dropped,
# base columns exposed, and the consumer formula rewritten.
helper9 = { 'id' => 'el-x-topn-src', 'kind' => 'table', 'name' => 'TopN Source (x)',
            '_worksheet' => '% of total by room name', 'visibleAsSource' => false,
            'source' => { 'kind' => 'table', 'elementId' => 'master' },
            'columns' => [
              { 'id' => 'h-room', 'name' => 'Room Clean', 'formula' => '[Master/Room Clean]' },
              { 'id' => 'h-lab',  'name' => '% Lab',      'formula' => '[Master/% Lab]' }
            ] }
cons9 = { 'id' => 'el-x', 'kind' => 'pivot-table', 'name' => 'consumer',
          'source' => { 'kind' => 'table', 'elementId' => 'el-x-topn-src' },
          'columns' => [{ 'id' => 'c-lab', 'name' => '% Lab', 'formula' => 'Sum([TopN Source (x)/% Lab])' }] }
els9 = [cons9]
de9 = [helper9]
w9 = []
route_multi_ds!(els9, de9, JSON.parse(JSON.generate(PLAN)), 'master', w9, cbg: CBG, mmap: {})
check(helper9['columns'].none? { |c| c['name'] == '% Lab' },
      'helper: aggregated-calc passthrough dropped from the row-grain helper', fails)
check(%w[Count Sum_Count].all? { |n| helper9['columns'].any? { |c| c['name'] == n } },
      'helper: base columns exposed on the helper', fails)
check(cons9['columns'][0]['formula'] == 'Sum([TopN Source (x)/Count])/Sum([TopN Source (x)/Sum_Count])',
      "helper: consumer formula rewritten to the ratio-of-sums (got #{cons9['columns'][0]['formula']})", fails)
hrc = helper9['columns'].find { |c| c['name'] == 'Room Clean' }
check(hrc && hrc['formula'] == '[Master (Dir Bias by Level)/Room Clean]',
      'helper: row-level calc passthrough re-pointed at the sub-master derived column', fails)
sm9 = de9.find { |e| e['id'].to_s.start_with?('submaster-') }
check(sm9 && sm9['columns'].any? { |c| c['name'] == 'Room Clean' && c['formula'].include?('Replace(') },
      'helper: sub-master carries the derived Room Clean column', fails)

puts
puts 'Part 7 — same-datasource logical-table grain routing'
grain_plan = {
  'datasources' => [
    { 'caption' => 'Employees', 'default' => true, 'worksheets' => ['Employee Count'] },
    { 'caption' => 'Absence Records View', 'worksheets' => ['Absence Count'] }
  ]
}
grain_elements = [
  { 'id' => 'el-employees', 'kind' => 'bar-chart', 'name' => 'Employee Count',
    '_worksheet' => 'Employee Count',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [
      { 'id' => 'e-dept', 'name' => 'Department', 'formula' => '[Master/Department]' },
      { 'id' => 'e-count', 'name' => 'Employee Count', 'formula' => 'CountIf(IsNotNull([Master/Employee Id]))' }
    ] },
  { 'id' => 'el-absences', 'kind' => 'bar-chart', 'name' => 'Absence Count',
    '_worksheet' => 'Absence Count',
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [
      { 'id' => 'a-location', 'name' => 'Location', 'formula' => '[Master/Location]' },
      { 'id' => 'a-date', 'name' => 'Date', 'formula' => '[Master/Date]' },
      { 'id' => 'a-count', 'name' => 'Absence Count', 'formula' => 'CountIf(IsNotNull([Master/Employee Id]))' }
    ] }
]
grain_data = []
grain_warnings = []
date_control = {
  'id' => 'date-filter', 'kind' => 'control', 'name' => 'Date',
  'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-date' }]
}
grain_routed = route_multi_ds!(
  grain_elements, grain_data, grain_plan, 'master', grain_warnings,
  controls: [date_control], id2name: { 'm-date' => 'Date' }, mode: 'multi-grain'
)
employee_chart, absence_chart = grain_elements
grain_master = grain_data.find { |element| element['id'].to_s.start_with?('submaster-') }
check(grain_routed == { 'Absence Count' => 'Absence Records View' },
      "only the child-fact worksheet is grain-routed (got #{grain_routed.inspect})", fails)
check(employee_chart.dig('source', 'elementId') == 'master' &&
      employee_chart['columns'][1]['formula'].include?('[Master/Employee Id]'),
      'default employee-grain chart stays on the shared master', fails)
check(absence_chart.dig('source', 'elementId') == grain_master&.dig('id') &&
      absence_chart['columns'].all? { |column| !column['formula'].include?('[Master/') },
      'absence chart sources its own sub-master and every formula prefix moves in lock-step', fails)
check(grain_master && grain_master.dig('source', 'elementId') == '__DM_ELEMENT__:Absence Records View' &&
      %w[Location Date Employee\ Id].all? { |name| grain_master['columns'].any? { |column| column['name'] == name } },
      'grain sub-master exposes exactly the child-grain chart dependencies', fails)
check(date_control['filters'].any? { |target| target.dig('source', 'elementId') == grain_master&.dig('id') },
      'master-targeted date control fans out to the grain sub-master', fails)

puts
if fails.empty?
  puts 'OK — source routing holds (multi-DS + same-datasource grain sub-masters, lock-step rewrite, controls)'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
