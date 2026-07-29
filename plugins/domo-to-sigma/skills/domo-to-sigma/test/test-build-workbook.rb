#!/usr/bin/env ruby
# Unit tests for build-workbook.rb — the fixes for feedback #1,#2,#5,#7,#8.
#   ruby test/test-build-workbook.rb

require_relative '../scripts/build-workbook'

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) eq(!!c, true, m) end

puts "== #1 KPI: measure aggregate w/ source prefix + value.columnId =="
$warnings = []
kpi = build_kpi({ 'id' => 'c1', 'title' => 'Revenue',
                  'summaryNumber' => { 'column' => 'sales_amount', 'aggregation' => 'SUM',
                                       'label' => 'Total Revenue', 'format' => { 'type' => 'CURRENCY' },
                                       '_defaultCountSuspect' => false } }, {})
eq(kpi['kind'], 'kpi-chart', 'kind kpi-chart')
eq(kpi['columns'][0]['formula'], 'Sum([Master/Sales Amount])', 'value = Sum of measure, source-prefixed (NOT Count of id)')
eq(kpi['value'], { 'columnId' => kpi['columns'][0]['id'] }, 'value uses columnId (not id)')
eq(kpi['columns'][0]['format'], { 'kind' => 'number', 'decimalPlaces' => 0 }, 'currency format carried (proven decimalPlaces shape, not a d3 formatString)')

puts "== #1 KPI: COUNT-of-id (Domo table default) is flagged, not silent =="
$warnings = []
kpi2 = build_kpi({ 'id' => 'c2', 'title' => 'Projects',
                   'summaryNumber' => { 'column' => 'project_id', 'aggregation' => 'COUNT',
                                        '_defaultCountSuspect' => true } }, {})
ok($warnings.any? { |w| w['warning'].include?('row-key') && w['warning'].include?('kpi-overrides') }, 'COUNT-of-id KPI warned + override hint')
eq(kpi2['columns'][0]['formula'], 'Count([Master/Project Id])', 'still emits faithfully (surfaced, not dropped)')

puts "== #1 KPI: kpi-overrides.json corrects the measure deterministically =="
$warnings = []
kpi3 = build_kpi({ 'id' => 'c2', 'title' => 'Projects',
                   'summaryNumber' => { 'column' => 'project_id', 'aggregation' => 'COUNT', '_defaultCountSuspect' => true } },
                 { 'c2' => { 'column' => 'budget', 'aggregation' => 'SUM' } })
eq(kpi3['columns'][0]['formula'], 'Sum([Master/Budget])', 'override swaps to the intended measure')
ok($warnings.empty?, 'no warning once overridden')

puts "== #7 + #8 bar chart: real bar-chart, gridlines off =="
$warnings = []
bar = build_element({ 'id' => 'c3', 'title' => 'Sales by Region', 'chartType' => 'badge_vert_bar',
                      'sigmaKindHint' => 'bar-chart',
                      'groupBy' => ['store_region'],
                      'columns' => [ { 'column' => 'store_region' },
                                     { 'column' => 'sales_amount', 'aggregation' => 'SUM', 'alias' => 'Sales' } ] }, {})
eq(bar['kind'], 'bar-chart', '#7 bar card → bar-chart element (NOT table+dataBars)')
ok(bar['columns'].none? { |c| c['id'].to_s.start_with?('cf') }, 'no conditionalFormats/dataBars on a bar chart')
eq(bar['xAxis']['format'], { 'marks' => 'none' }, '#8 x-axis gridlines off')
eq(bar['yAxis']['format'], { 'marks' => 'none' }, '#8 y-axis gridlines off')
eq(bar['columns'][0]['formula'], '[Master/Store Region]', 'dimension references master')
eq(bar['columns'][1]['formula'], 'Sum([Master/Sales Amount])', 'measure aggregated + master-ref')
eq(bar['columns'][1]['name'], 'Sales', 'measure label uses Domo alias (fixes raw names #4)')

puts "== #5 table: text wrap on dimension columns; dataBars only when declared =="
tbl = build_element({ 'id' => 'c4', 'title' => 'Projects', 'chartType' => 'badge_datagrid',
                      'sigmaKindHint' => 'table',
                      'columns' => [ { 'column' => 'project_name' },
                                     { 'column' => 'amount', 'aggregation' => 'SUM' } ],
                      'conditionalFormats' => [] }, {})
eq(tbl['kind'], 'table', 'datagrid → table')
eq(tbl['columns'][0]['style'], { 'textWrap' => 'wrap' }, '#5 text column wraps')
ok(!tbl.key?('conditionalFormats'), 'no dataBars when the card declared none')

tbl2 = build_element({ 'id' => 'c5', 'title' => 'T', 'chartType' => 'badge_datagrid', 'sigmaKindHint' => 'table',
                       'columns' => [ { 'column' => 'region' }, { 'column' => 'amt', 'aggregation' => 'SUM' } ],
                       'conditionalFormats' => [{ 'format' => { 'dataBar' => true } }] }, {})
eq(tbl2['conditionalFormats'].first['type'], 'dataBars', 'dataBars kept when the Domo table declared them')

puts "== Rule 0: single-value summary card → KPI even if chartType is table =="
$warnings = []
r0 = build_element({ 'id' => 'c6', 'title' => 'One Number', 'chartType' => 'badge_datagrid',
                     'sigmaKindHint' => 'table', 'groupBy' => [], 'columns' => [{ 'column' => 'total', 'aggregation' => 'SUM' }],
                     'summaryNumber' => { 'column' => 'total', 'aggregation' => 'SUM' } }, {})
eq(r0['kind'], 'kpi-chart', 'summary-number table card → KPI, not a grid')

puts "== #2 controls: one per distinct filter column, bound to shared master =="
ctrls = build_controls([
  { 'id' => 'a', 'filters' => [{ 'column' => 'region', 'operator' => 'IN', 'values' => %w[W E] }] },
  { 'id' => 'b', 'filters' => [{ 'column' => 'region' }, { 'column' => 'status' }] },
])
eq(ctrls.size, 2, 'deduped to distinct filter columns (region, status)')
eq(ctrls[0]['filters'], [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => 'm-region' }],
   'control binds to master column → fans out to every element (fixes fall-off)')

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
