#!/usr/bin/env ruby
# Unit tests for build-workbook.rb — the fixes for feedback #1,#2,#5,#7,#8.
#   ruby test/test-build-workbook.rb

require_relative '../scripts/build-workbook'
require 'tmpdir'

# Temporarily override a top-level constant for the duration of a block, then
# ALWAYS restore it — even on assertion failure — mirroring the with_domo_stub
# pattern in test-discover.rb. Ruby warns on constant reassignment; silence it
# locally rather than suppressing warnings globally.
def stub_const(name, value)
  target = Object
  existed = target.const_defined?(name)
  old = target.const_get(name) if existed
  silence_warnings { target.send(:remove_const, name) if target.const_defined?(name); target.const_set(name, value) }
  yield
ensure
  silence_warnings do
    target.send(:remove_const, name) if target.const_defined?(name)
    target.const_set(name, old) if existed
  end
end

def silence_warnings
  old_verbose = $VERBOSE
  $VERBOSE = nil
  yield
ensure
  $VERBOSE = old_verbose
end

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
eq(kpi['columns'][0]['format'], { 'kind' => 'number', 'formatString' => '$.4~s' },
   'currency KPI matches Domo visible abbreviated headline')

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
eq(bar.dig('xAxis', 'format', 'marks'), 'none', '#8 x-axis gridlines off')
eq(bar['yAxis']['format'], { 'marks' => 'none' }, '#8 y-axis gridlines off')
eq(bar['columns'][0]['formula'], '[Master/Store Region]', 'dimension references master')
eq(bar['columns'][1]['formula'], 'Sum([Master/Sales Amount])', 'measure aggregated + master-ref')
eq(bar['columns'][1]['name'], 'Sales', 'measure label uses Domo alias (fixes raw names #4)')

puts "== symbol line preserves source point markers =="
symbol_line = build_element({
  'id' => 'c3-line', 'title' => 'Sales by Month',
  'chartType' => 'badge_symbolline', 'sigmaKindHint' => 'line-chart',
  'dateGrain' => { 'column' => 'month', 'dateTimeElement' => 'MONTH' },
  'groupBy' => ['month'],
  'columns' => [
    { 'column' => 'month', 'mapping' => 'ITEM', 'calendar' => true },
    { 'column' => 'sales_amount', 'aggregation' => 'SUM', 'mapping' => 'SERIES' }
  ]
}, {})
eq(symbol_line.dig('lineAreaStyle', 'points'),
   { 'visibility' => 'shown', 'shape' => 'circle', 'size' => 9 },
   'badge_symbolline emits released lineAreaStyle point markers')
eq(symbol_line['columns'].first['format'],
   { 'kind' => 'datetime', 'formatString' => '%b %y' },
   'calendar axes use compact source-like month labels')

puts "== visual roles: aggregated XTIME is a measure, plain XTIME is a dimension =="
dims, measures = split_cols({
  'columns' => [
    { 'column' => 'period', 'mapping' => 'XTIME' },
    { 'column' => 'won', 'mapping' => 'XTIME', 'aggregation' => 'COUNT' },
  ],
})
eq(dims.map { |c| c['column'] }, ['period'], 'plain XTIME remains the grouping axis')
eq(measures.map { |c| c['column'] }, ['won'], 'aggregated XTIME keeps its measure role')

puts "== #5 table: text wrap on dimension columns; dataBars only when declared =="
tbl = build_element({ 'id' => 'c4', 'title' => 'Projects', 'chartType' => 'badge_table',
                      'sigmaKindHint' => 'table',
                      'columns' => [ { 'column' => 'project_name' },
                                     { 'column' => 'amount', 'aggregation' => 'SUM' } ],
                      'conditionalFormats' => [] }, {})
eq(tbl['kind'], 'table', 'badge_table (the REAL token — badge_datagrid does not exist) → table')
eq(tbl['columns'][0]['style'], { 'textWrap' => 'wrap' }, '#5 text column wraps')
ok(!tbl.key?('conditionalFormats'), 'no dataBars when the card declared none')

tbl2 = build_element({ 'id' => 'c5', 'title' => 'T', 'chartType' => 'badge_table', 'sigmaKindHint' => 'table',
                       'columns' => [ { 'column' => 'region' }, { 'column' => 'amt', 'aggregation' => 'SUM' } ],
                       'conditionalFormats' => [{ 'format' => { 'dataBar' => true } }] }, {})
eq(tbl2['conditionalFormats'].first['type'], 'dataBars', 'dataBars kept when the Domo table declared them')

puts "== Rule 0: single-value summary card → KPI even if chartType is table =="
$warnings = []
r0 = build_element({ 'id' => 'c6', 'title' => 'One Number', 'chartType' => 'badge_table',
                     'sigmaKindHint' => 'table', 'groupBy' => [], 'columns' => [{ 'column' => 'total', 'aggregation' => 'SUM' }],
                     'summaryNumber' => { 'column' => 'total', 'aggregation' => 'SUM' } }, {})
eq(r0['kind'], 'kpi-chart', 'summary-number table card → KPI, not a grid')

puts "== B4: build_controls no longer manufactures a page control from CARD-level filters =="
# This used to turn every distinct `card['filters'][].column` into a
# page-level `list` control with NO values — 3 spurious workbook-wide
# controls the source page never had, per the 2026-08-05 cold-run audit.
# Card-level filters now become ELEMENT filters instead (see the B4 tests
# below) — build_controls is reserved for a genuine Domo PAGE filter, which
# does not exist in any real discovered data yet.
ctrls = build_controls([
  { 'id' => 'a', 'filters' => [{ 'column' => 'region', 'operator' => 'IN', 'values' => %w[W E] }] },
  { 'id' => 'b', 'filters' => [{ 'column' => 'region' }, { 'column' => 'status' }] },
])
eq(ctrls, [], 'no spurious page control emitted for card-level filters (B4)')

puts "== Phase-5 geometry gate: warn when a page's cards carry no x/y =="
$warnings = []
warn_missing_geometry('Overview', [{ 'id' => 'c7', 'title' => 'No Geometry' }, { 'id' => 'c8' }])
ok($warnings.any? { |w| w['warning'].include?("no grid geometry for page 'Overview'") && w['warning'].include?('single-column stack') },
   "page with no card x/y warns loudly (Task 1's merge_geometry never ran / found nothing)")

$warnings = []
warn_missing_geometry('Overview', [{ 'id' => 'c9', 'x' => 0, 'y' => 0, 'w' => 3, 'h' => 2 }, { 'id' => 'c10' }])
ok($warnings.empty?, 'no warning once at least one card on the page carries geometry')

$warnings = []
warn_missing_geometry('Empty', [])
ok($warnings.empty?, 'no warning for an empty page (nothing to place)')

puts "== Problem 2: chartType is an EXACT-match strict enum, not a substring match =="
$warnings = []
# badge_line_bar is a COMBO chart but contains the substring 'badge_line' — the
# old doc's substring rule would have mis-routed this to line-chart.
combo = build_element({ 'id' => 'c11', 'title' => 'Revenue vs Target', 'chartType' => 'badge_line_bar',
                        'columns' => [ { 'column' => 'month' },
                                       { 'column' => 'revenue', 'aggregation' => 'SUM', 'alias' => 'Revenue' },
                                       { 'column' => 'target', 'aggregation' => 'SUM', 'alias' => 'Target' } ] }, {})
eq(combo['kind'], 'combo-chart', 'badge_line_bar → combo-chart, NOT line-chart (substring "badge_line" would mis-route it)')
eq(combo['yAxis']['columnIds'],
   [ { 'columnId' => combo['columns'][1]['id'], 'type' => 'line' },
     { 'columnId' => combo['columns'][2]['id'], 'type' => 'bar' } ],
   'badge_line_bar preserves Domo role order: first measure line, second bar')
eq(combo.dig('yAxis2', 'columnIds'), [combo['columns'][2]['id']],
   'bar series uses the secondary axis so line-rate and bar-volume scales both remain visible')

duplicate_combo = build_element({
  'id' => 'c11b', 'title' => 'Page View Growth', 'chartType' => 'badge_line_bar',
  'columns' => [
    { 'column' => 'Date', 'mapping' => 'ITEM' },
    { 'column' => 'Unique Page Views', 'aggregation' => 'AVG', 'mapping' => 'SERIES' },
    { 'column' => 'Page Views', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => 'Unique Page Views', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
  ],
}, {})
combo_ids = duplicate_combo.dig('yAxis', 'columnIds').map { |s| s['columnId'] }
eq(combo_ids.uniq.length, 3,
   'duplicate raw columns keep distinct channel ids for Avg and Sum series')
eq(combo_ids, duplicate_combo['columns'].drop(1).map { |c| c['id'] },
   'combo channels retarget the suffixed duplicate id, never repeat the first formula')

post_reach = build_element({
  'id' => 'c11c', 'title' => 'Post Reach', 'chartType' => 'badge_line_bar',
  'columns' => [
    { 'column' => 'Date', 'mapping' => 'ITEM' },
    { 'column' => 'Paid Post Impression', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => 'Organic Post Impression', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => 'Number of Posts', 'alias' => 'Posts', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
  ],
}, {})
eq(post_reach.dig('yAxis', 'columnIds').map { |s| s['type'] },
   %w[line line bar],
   'post-impression measures stay lines while the exact Posts count is the bar')

# badge_symbol_bar contains the substring '_bar' — must be combo-chart, not bar-chart.
$warnings = []
symbar = build_element({ 'id' => 'c12', 'title' => 'Actual vs Marker', 'chartType' => 'badge_symbol_bar',
                         'columns' => [ { 'column' => 'region' },
                                        { 'column' => 'actual', 'aggregation' => 'SUM' },
                                        { 'column' => 'marker', 'aggregation' => 'SUM' } ] }, {})
eq(symbar['kind'], 'combo-chart', 'badge_symbol_bar → combo-chart, NOT bar-chart (substring "_bar" would mis-route it)')
eq(symbar['yAxis']['columnIds'][1]['type'], 'scatter', 'the symbol overlay renders as a scatter series')
eq(symbar.dig('yAxis2', 'columnIds'), [symbar['columns'][1]['id']],
   'bar layer uses the secondary axis beside scatter markers')

puts "== Problem 1: fabricated chartType tokens are flagged, never silently mapped =="
$warnings = []
fab = build_element({ 'id' => 'c13', 'title' => 'Old Table Card', 'chartType' => 'badge_datagrid',
                      'columns' => [ { 'column' => 'name' }, { 'column' => 'amt', 'aggregation' => 'SUM' } ] }, {})
ok($warnings.any? { |w| w['warning'].include?('not a valid Domo ChartType') && w['warning'].include?('badge_table') },
   'badge_datagrid (confirmed-invalid enum value) is flagged, naming the real replacement token')
ok(!fab.nil?, 'a fabricated-token card still emits SOME element — never a silent drop')

puts "== Problem 3: newly-mapped chart types resolve to the VERIFIED Sigma kind =="
$warnings = []
stacked = build_element({ 'id' => 'c14', 'title' => 'Sales by Region (stacked)', 'chartType' => 'badge_vert_stackedbar',
                          'columns' => [ { 'column' => 'region' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(stacked['kind'], 'bar-chart', 'badge_vert_stackedbar → bar-chart')
eq(stacked['stacking'], 'stacked', 'badge_vert_stackedbar carries stacking:stacked')

pct = build_element({ 'id' => 'c15', 'title' => 'Share of Total', 'chartType' => 'badge_horiz_100pct',
                      'columns' => [ { 'column' => 'segment' }, { 'column' => 'share', 'aggregation' => 'SUM' } ] }, {})
eq(pct['orientation'], 'horizontal', 'badge_horiz_100pct is horizontal')
eq(pct['stacking'], 'normalized', 'badge_horiz_100pct is the percent-stacked variant')

donut = build_element({ 'id' => 'c16', 'title' => 'Mix', 'chartType' => 'badge_donut',
                        'columns' => [ { 'column' => 'family' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(donut['kind'], 'donut-chart', 'badge_donut → donut-chart')
eq(donut['value'], { 'id' => donut['columns'].last['id'] }, 'donut value uses value.id (opposite of KPI columnId)')
ok(!donut.key?('xAxis') && !donut.key?('yAxis'), 'donut/pie carry value/color, NOT xAxis/yAxis (fixes the old broken shape)')
eq(donut['legend'], { 'position' => 'left', 'fontSize' => 9 },
   'donut legend preserves Domo left-side placement')

pie = build_element({ 'id' => 'c17', 'title' => 'Share', 'chartType' => 'badge_pie',
                      'columns' => [ { 'column' => 'family' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(pie['kind'], 'pie-chart', 'badge_pie → pie-chart (Sigma has a distinct pie-chart kind, not just donut)')

puts "== Problem 3: no-native-equivalent chart types warn loudly + degrade honestly (never a silent bar-chart) =="
$warnings = []
wc = build_element({ 'id' => 'c18', 'title' => 'Top Terms', 'chartType' => 'badge_word_cloud',
                     'columns' => [ { 'column' => 'term' }, { 'column' => 'freq', 'aggregation' => 'SUM' } ] }, {})
eq(wc['kind'], 'table', 'badge_word_cloud degrades to a table (no word-cloud kind exists in Sigma)')
ok($warnings.any? { |w| w['warning'].include?('no native Sigma equivalent') && w['warning'].include?('word cloud') && w['warning'].include?('plugin') },
   'the word-cloud gap is flagged loudly, naming the gap and the custom-plugin follow-up')

$warnings = []
gauge = build_element({ 'id' => 'c19', 'title' => 'Quota Attainment', 'chartType' => 'badge_filledgauge',
                        'summaryNumber' => { 'column' => 'attainment', 'aggregation' => 'SUM', 'label' => 'Attainment' },
                        'columns' => [ { 'column' => 'attainment', 'aggregation' => 'SUM' },
                                       { 'column' => 'target', 'aggregation' => 'SUM' } ] }, {})
eq(gauge['kind'], 'kpi-chart', 'filled gauge without explicit CURRENT/TARGET roles degrades to kpi-chart')
ok($warnings.any? { |w| w['warning'].include?('requires explicit CURRENT and TARGET') },
   'the ungrounded progress range is flagged loudly')

$warnings = []
native_progress = build_element({
  'id' => 'c19-native', 'title' => 'Quota Attainment', 'chartType' => 'badge_filledgauge',
  'columns' => [
    { 'column' => 'attainment', 'aggregation' => 'SUM', 'mapping' => 'CURRENT' },
    { 'column' => 'target', 'aggregation' => 'SUM', 'mapping' => 'TARGET' },
  ],
}, {})
eq(native_progress['kind'], 'progress', 'filled gauge with grounded CURRENT/TARGET roles maps to released progress')
eq(native_progress['shape'], 'ring', 'Domo filled gauge maps to ring progress')
eq(native_progress['min'], '0', 'progress uses the grounded zero baseline')
eq(native_progress['value'], 'Sum([Master/Attainment])', 'CURRENT role maps to the progress value formula')
eq(native_progress['max'], 'Sum([Master/Target])', 'TARGET role maps to the progress maximum formula')
ok($warnings.empty?, 'fully grounded progress emits no fallback warning')

$warnings = []
drill_gap = build_element({
  'id' => 'c19-drill', 'title' => 'Revenue hierarchy', 'chartType' => 'badge_vert_bar',
  'allowTableDrill' => true, 'drillPath' => { 'fields' => %w[region city] },
  'columns' => [
    { 'column' => 'region', 'mapping' => 'ITEM' },
    { 'column' => 'revenue', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
  ],
}, {})
eq(drill_gap['kind'], 'bar-chart', 'a drill-bearing card retains its grounded base chart')
ok($warnings.any? { |w| w['warning'].include?('complete ordered hierarchy') &&
                         w['warning'].include?('not fabricated') },
   'incomplete Domo drill metadata is a loud gap, never dead drill UI')

$warnings = []
nogauge = build_element({ 'id' => 'c19b', 'title' => 'Orphan Gauge', 'chartType' => 'badge_filledgauge',
                          'columns' => [] }, {})
eq(nogauge['kind'], 'table', 'a gauge card with no summaryNumber still emits an element (table) — never silently dropped')
ok($warnings.any? { |w| w['warning'].include?('requires explicit CURRENT and TARGET') },
   'the missing-summaryNumber gauge case carries the grounded progress-fallback warning')

puts "== badge_map: region-map when the geography column is classifiable, honest table fallback otherwise =="
$warnings = []
geomap = build_element({ 'id' => 'c20', 'title' => 'Sales by State', 'chartType' => 'badge_map',
                         'columns' => [ { 'column' => 'store_state' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(geomap['kind'], 'region-map', 'badge_map with a recognizable state column → region-map')
eq(geomap['region']['regionType'], 'us-state', 'regionType inferred from the column name')

$warnings = []
ga_region = build_element({
  'id' => 'c20b', 'title' => 'New Visits by State', 'chartType' => 'badge_map',
  'columns' => [{ 'column' => 'Region', 'mapping' => 'ITEM' },
                { 'column' => 'New Visits', 'aggregation' => 'SUM', 'mapping' => 'VALUE' }],
  'filters' => [{ 'column' => 'Country', 'operator' => 'IN', 'values' => ['United States'] }],
}, {})
eq(ga_region['kind'], 'region-map',
   'Google Analytics Region + United States filter resolves as a US-state map')
eq(ga_region.dig('region', 'regionType'), 'us-state',
   'the card-local country context grounds the otherwise ambiguous Region field')

$warnings = []
badgeo = build_element({ 'id' => 'c21', 'title' => 'Custom Territory Map', 'chartType' => 'badge_map',
                         'columns' => [ { 'column' => 'sales_territory_code' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(badgeo['kind'], 'table', 'badge_map with an unclassifiable geography → honest table fallback, not a broken map spec')
ok($warnings.any? { |w| w['warning'].include?('no native Sigma equivalent') }, 'the unclassifiable geography is flagged, not silently dropped')

puts "== split_cols honors Domo's own column->visual-role `mapping` vocabulary when present =="
dims, meas = split_cols({ 'columns' => [ { 'column' => 'region', 'mapping' => 'ITEM' },
                                         { 'column' => 'revenue', 'mapping' => 'VALUE' } ] })
eq(dims.map { |c| c['column'] }, ['region'], 'ITEM-mapped column is a dimension even with no aggregation/groupBy present')
eq(meas.map { |c| c['column'] }, ['revenue'], 'VALUE-mapped column is a measure even with no aggregation present (fails under the old aggregation-only heuristic)')

puts "== bead 2ef7: card['limit'] -> Sigma top-n element filter (table) =="
$warnings = []
topn = build_element({ 'id' => 'c22', 'title' => 'Order Detail (Top 25)', 'chartType' => 'badge_table',
                       'sigmaKindHint' => 'table', 'limit' => 25,
                       'columns' => [ { 'column' => 'order_id' },
                                      { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'alias' => 'Net Revenue' } ] }, {})
eq(topn['kind'], 'table', 'still a table element')
ok(topn.key?('filters'), 'limit produced an element filter')
eq(topn['filters'].first['kind'], 'top-n', 'filter kind is top-n')
eq(topn['filters'].first['rankingFunction'], 'rank', 'rankingFunction is rank')
eq(topn['filters'].first['mode'], 'top-n', 'mode is top-n')
eq(topn['filters'].first['rowCount'], 25, 'rowCount carries the Domo limit as a NUMBER LITERAL')
eq(topn['filters'].first['columnId'], topn['columns'].last['id'], 'ranks by the measure column (Net Revenue), not the dimension')

puts "== bead 2ef7: no limit declared -> no filters key at all =="
no_topn = build_element({ 'id' => 'c23', 'title' => 'All Orders', 'chartType' => 'badge_table',
                          'sigmaKindHint' => 'table',
                          'columns' => [ { 'column' => 'order_id' },
                                         { 'column' => 'net_revenue', 'aggregation' => 'SUM' } ] }, {})
ok(!no_topn.key?('filters'), 'no limit -> no filters key (never emit an empty/default top-n)')

puts "== bead 2ef7: limit with no measure column -> no filter (nothing to rank by)" \
     ' — never crash, never emit a columnId:nil filter =='
no_measure = build_element({ 'id' => 'c24', 'title' => 'Dim Only', 'chartType' => 'badge_table',
                             'sigmaKindHint' => 'table', 'limit' => 10,
                             'columns' => [ { 'column' => 'order_id' } ] }, {})
ok(!no_measure.key?('filters'), 'no measure column -> no top-n filter emitted')

puts "== bead ziht: dataset_element_map resolves datasetId -> live DM element =="
Dir.mktmpdir do |dir|
  dm_spec_path = File.join(dir, 'dm-spec.json')
  dm_ids_path  = File.join(dir, 'dm-ids.json')
  File.write(dm_spec_path, JSON.generate('pages' => [{ 'elements' => [
    { 'id' => 'el-fact-1', 'name' => 'Order Fact', '_datasetId' => 'ds-fact' },
    { 'id' => 'el-dim-1',  'name' => 'Customer Dim', '_datasetId' => 'ds-dim' },
  ] }]))
  File.write(dm_ids_path, JSON.generate('dataModelId' => 'dm-live-1', 'pages' => [{ 'elements' => [
    { 'id' => 'el-fact-1', 'name' => 'Order Fact', 'columnLabels' => ['Order Id', 'Region'] },
    { 'id' => 'el-dim-1',  'name' => 'Customer Dim', 'columnLabels' => ['Customer Id', 'Segment'] },
  ] }]))
  stub_const('DM_SPEC_PATH', dm_spec_path) do
    stub_const('DM_IDS_PATH', dm_ids_path) do
      $ds_element_map = nil # force recompute against this dir's fixtures
      map = dataset_element_map
      eq(map.keys.sort, %w[ds-dim ds-fact], 'both datasets resolved')
      eq(map['ds-dim']['id'], 'el-dim-1', 'ds-dim resolves to its own live element, not the fact')

      $sub_masters = {}
      sm = sub_master_for('ds-dim')
      ok(!sm.nil?, 'sub-master built for a resolvable dataset')
      eq(sm['kind'], 'table', 'sub-master is a table element')
      eq(sm['visibleAsSource'], false, 'sub-master is hidden, like the primary master')
      eq(sm['source'], { 'kind' => 'data-model', 'dataModelId' => 'dm-live-1', 'elementId' => 'el-dim-1' },
         'sub-master sources the LIVE DM element for ds-dim, dataModelId included')
      eq(sm['columns'].map { |c| c['name'] }, ['Customer Id', 'Segment'], 'auto-passthrough of the DM element\'s own columns')
      eq(sm['columns'].first['formula'], '[Customer Dim/Customer Id]', 'column formula qualifies by the DM element\'s own name')

      ok(sub_master_for('ds-dim').equal?(sm), 'memoized — a second call returns the SAME object, not a rebuild')
      eq($ds_element_map.dig('ds-nope'), nil, 'unknown dataset -> nil, not an exception')
      ok(sub_master_for('ds-nope').nil?, 'sub_master_for on an unresolvable dataset -> nil (caller falls back to today\'s skip)')
    end
  end
end

puts "== live-found 2026-07-31: a NAMELESS DM element (build-dm.rb's rule 3 — no element-level " \
     'name) still resolves a real sub-master formula, not "[/Col]" (an invalid, empty-table-name formula) =='
Dir.mktmpdir do |dir|
  dm_spec_path = File.join(dir, 'dm-spec.json')
  dm_ids_path  = File.join(dir, 'dm-ids.json')
  # Mirrors build-dm.rb's REAL output shape: no element-level `name`, plus the
  # warehouse-table `source.path` build-workbook-spec.rb's own name-fallback
  # already reads for the primary master.
  File.write(dm_spec_path, JSON.generate('pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', '_datasetId' => 'ds-dim',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ CUSTOMER_DIM] } },
  ] }]))
  File.write(dm_ids_path, JSON.generate('dataModelId' => 'dm-live-1', 'pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => nil, 'columnLabels' => ['Customer Id', 'Region'] },
  ] }]))
  stub_const('DM_SPEC_PATH', dm_spec_path) do
    stub_const('DM_IDS_PATH', dm_ids_path) do
      $ds_element_map = nil
      $sub_masters = {}
      sm = sub_master_for('ds-dim')
      ok(!sm.nil?, 'sub-master still built for a nameless DM element')
      eq(sm['name'], 'Master (CUSTOMER_DIM)', "falls back to the warehouse table's own name (last path segment), " \
                                              'the SAME resolution build-workbook-spec.rb uses for the primary master')
      eq(sm['columns'].first['formula'], '[CUSTOMER_DIM/Customer Id]',
         'formula is correctly table-qualified — never "[/Customer Id]" (an invalid, empty-table-name formula ' \
         'that would 400 the whole workbook POST)')
    end
  end
end

puts "== bead ziht: dataset_element_map degrades to {} when the inputs are absent (offline / unit-test default) =="
stub_const('DM_SPEC_PATH', '/nonexistent/dm-spec.json') do
  stub_const('DM_IDS_PATH', nil) do
    $ds_element_map = nil
    eq(dataset_element_map, {}, 'no dm-spec/dm-ids -> empty map, never an exception')
  end
end

puts "== stub_const restores a constant whose ORIGINAL value was falsy (nil), not just truthy ones =="
# DM_IDS_PATH's real original value in THIS offline test run is nil (nothing sets
# DOMO_DM_IDS_PATH in the environment) — exactly the real-world case that used to
# defeat restore-on-`ensure`'s old `if old` guard (nil is falsy, so the constant was
# left REMOVED rather than restored to nil).
ok(Object.const_defined?(:DM_IDS_PATH), 'DM_IDS_PATH is defined before the stub (as nil, since DOMO_DM_IDS_PATH is unset)')
eq(DM_IDS_PATH, nil, 'sanity: DM_IDS_PATH really is nil in this offline test env')
stub_const('DM_IDS_PATH', '/tmp/whatever-dm-ids.json') do
  eq(DM_IDS_PATH, '/tmp/whatever-dm-ids.json', 'stubbed value visible inside the block')
end
ok(Object.const_defined?(:DM_IDS_PATH), 'DM_IDS_PATH still defined after stub block exits (regression: used to vanish when the original value was nil/falsy)')
eq(DM_IDS_PATH, nil, 'restored to its original nil value, not left undefined')

puts "== bead 08sf: build_summary_companion mirrors build_kpi but with a distinct id =="
kpi_card = { 'id' => 'c29', 'title' => 'Revenue by Channel',
             'summaryNumber' => { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'label' => 'Total Revenue' } }
companion = build_summary_companion(kpi_card, {})
ok(!companion.nil?, 'companion built when the summary number has a resolvable column')
eq(companion['kind'], 'kpi-chart', 'companion is a kpi-chart element')
eq(companion['name'], 'Total Revenue', 'companion carries the summary number\'s own label')
eq(companion['id'], "#{eid(kpi_card)}-summary",
   'companion id is the primary element\'s id + a -summary suffix (never collides with it)')

no_col_card = { 'id' => 'c30', 'title' => 'Orders', 'summaryNumber' => { 'column' => '', 'aggregation' => 'COUNT' } }
ok(build_summary_companion(no_col_card, {}).nil?,
   'nil when the summary number has no resolvable column (mirrors build_kpi\'s own "return nil unless col")')

puts "== M1 (final review, minor): retarget_to_submaster! must NOT fabricate a 'source' key on " \
     'an element that never had one (build_image) =='
img_el = { 'id' => 'el-img1', 'kind' => 'image', 'url' => 'data:image/png;base64,AAAA' }
sm_fixture = { 'id' => 'master-ds-dim', 'name' => 'Master (Customer Dim)' }
retarget_to_submaster!(img_el, sm_fixture)
ok(!img_el.key?('source'), "an image element (no 'source' key to begin with) still has none after retargeting " \
                            '— no bogus source fabricated (M1)')
eq(img_el['url'], 'data:image/png;base64,AAAA', "the image element's other fields are untouched")

chart_el = { 'id' => 'el-c1', 'kind' => 'bar-chart', 'source' => { 'kind' => 'table', 'elementId' => 'master' } }
retarget_to_submaster!(chart_el, sm_fixture)
eq(chart_el['source'], { 'kind' => 'table', 'elementId' => 'master-ds-dim' },
   'an element that DOES carry a source key still gets retargeted normally (unchanged behavior)')

puts "== live-found 2026-07-31: retarget_to_submaster! must not raise FrozenError on a " \
     'shared frozen constant (AXIS_OFF) nested inside an axis-chart element =='
axis_el = { 'id' => 'el-axis1', 'kind' => 'bar-chart',
            'source' => { 'kind' => 'table', 'elementId' => 'master' },
            'columns' => [{ 'id' => 'd-region', 'formula' => '[Master/Region]' }],
            'xAxis' => { 'columnId' => 'd-region', 'format' => AXIS_OFF },
            'yAxis' => { 'columnIds' => ['m-count'], 'format' => AXIS_OFF } }
retarget_to_submaster!(axis_el, sm_fixture)
ok(true, 'retargeting an element referencing the frozen AXIS_OFF constant does not raise FrozenError')
eq(axis_el['columns'].first['formula'], '[Master (Customer Dim)/Region]', 'the real formula ref is still rewritten')
eq(axis_el['xAxis']['format'], AXIS_OFF, "the frozen shared format hash is left as-is (never a rewrite target)")
ok(AXIS_OFF.frozen?, 'sanity: AXIS_OFF itself is still frozen (unmutated) after being walked')

puts "== bead ziht: a card on a non-dominant DataSet routes to its own sub-master " \
     '(not skipped) once a live DM element is resolvable =='
Dir.mktmpdir do |dir|
  dm_spec_path = File.join(dir, 'dm-spec.json')
  dm_ids_path  = File.join(dir, 'dm-ids.json')
  File.write(dm_spec_path, JSON.generate('pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => 'Customer Dim', '_datasetId' => 'ds-dim' },
  ] }]))
  File.write(dm_ids_path, JSON.generate('dataModelId' => 'dm-live-1', 'pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => 'Customer Dim', 'columnLabels' => ['Region', 'Segment'] },
  ] }]))
  stub_const('DM_SPEC_PATH', dm_spec_path) do
    stub_const('DM_IDS_PATH', dm_ids_path) do
      $ds_element_map = nil
      $sub_masters = {}
      $warnings = []
      routed = build_element({ 'id' => 'c25', 'title' => 'Customers by Region', 'chartType' => 'badge_table',
                               'sigmaKindHint' => 'table', 'datasetId' => 'ds-dim',
                               'columns' => [ { 'column' => 'region' } ] }, {}, 'ds-fact')
      ok(!routed.nil?, 'card is NOT skipped — a live sub-master was resolvable')
      eq(routed['source'], { 'kind' => 'table', 'elementId' => 'master-ds-dim' }, 'routed to its own sub-master, not the shared master')
      eq(routed['columns'].first['formula'], '[Master (Customer Dim)/Region]', 'formula re-qualified to the sub-master\'s namespace')
      ok($warnings.any? { |w| w['warning'].include?('routed to sub-master') }, 'routing is reported, not silent')
      ok($sub_masters.key?('ds-dim'), 'the sub-master was registered for the main block to emit under data_elements')
    end
  end
end

puts "== bead ziht: unresolvable DataSet still falls back to today's warn+SKIP =="
$ds_element_map = {}
$sub_masters = {}
$warnings = []
skipped = build_element({ 'id' => 'c26', 'title' => 'Orphan Dataset Card', 'chartType' => 'badge_table',
                          'sigmaKindHint' => 'table', 'datasetId' => 'ds-unknown',
                          'columns' => [ { 'column' => 'x' } ] }, {}, 'ds-fact')
ok(skipped.nil?, 'still nil when no live DM element is resolvable for the DataSet (unchanged fallback)')
ok($warnings.any? { |w| w['warning'].include?('SKIPPED') }, 'still warns loudly on fallback')

puts "== B4: build_controls stays a no-op regardless of dataset mix or master_ds =="
# (Superseded case: this used to test that a filter bound to a non-dominant
# DataSet's column was SKIPPED as a control, to avoid 400ing the whole POST
# by binding it to the wrong master. Card-level filters no longer become
# controls at all — see apply_card_filters! / build_element for how a
# sub-master-routed card's OWN filters are now handled, entirely independent
# of the shared master.)
$warnings = []
ctrls2 = build_controls([
  { 'id' => 'c27', 'datasetId' => 'ds-fact', 'filters' => [{ 'column' => 'region' }] },
  { 'id' => 'c28', 'datasetId' => 'ds-dim',  'filters' => [{ 'column' => 'segment' }] },
], 'ds-fact')
eq(ctrls2, [], 'still no controls, dominant dataset or not')
ok($warnings.empty?, 'no warnings either — there is nothing to skip')

puts "== bead 08sf: a chart/table card with a summaryNumber gets a companion KPI via " \
     'build_element, not just a warning =='
$warnings = []
$companion_elements = []
chart_with_summary = build_element({ 'id' => 'c31', 'title' => 'Revenue by Channel', 'chartType' => 'badge_vert_bar',
                                     'sigmaKindHint' => 'bar-chart',
                                     'groupBy' => ['channel'],
                                     'columns' => [ { 'column' => 'channel' },
                                                    { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'alias' => 'Net Revenue' } ],
                                     'summaryNumber' => { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'label' => 'Total Revenue' } }, {})
eq(chart_with_summary['kind'], 'bar-chart', 'the primary element is still the bar chart, unchanged')
eq($companion_elements.size, 1, 'exactly one companion KPI was produced')
companion = $companion_elements.first
eq(companion['kind'], 'kpi-chart', 'companion is a kpi-chart element')
eq(companion['name'], 'Total Revenue', 'companion carries the summary number\'s own label')
ok(companion['id'] != chart_with_summary['id'], 'companion has a DISTINCT id from the primary element (no duplicate-id 400)')
ok($warnings.any? { |w| w['warning'].include?('companion KPI element') }, 'the companion is reported, not silent')

puts "== bead 08sf: a card whose summaryNumber has no resolvable column still just warns " \
     '(no crash, no half-built companion) =='
$warnings = []
$companion_elements = []
# NOTE (task-5 self-review fix): a genuinely blank ('') summaryNumber column, with
# only 1 total column and no groupBy, trips Rule 0's is_kpi check (unchanged, and
# correctly so — see the Rule-0 test right below) BEFORE this code ever runs, and
# even bypassing Rule 0, build_element_body's own outer guard
# (`!sn['column'].to_s.empty?`) requires a raw non-blank column before it will even
# attempt build_summary_companion. So a literal '' can never reach the "companion
# could not be built" branch this test targets. A second (non-KPI-triggering)
# column keeps this off the Rule-0 path, and a whitespace-only column (' ') passes
# the outer guard's raw `.empty?` check while still failing
# build_summary_companion's stricter `.strip.empty?` check — genuinely exercising
# "column present but not resolvable", exactly the case this test names.
no_companion = build_element({ 'id' => 'c32', 'title' => 'Orders', 'chartType' => 'badge_table',
                               'sigmaKindHint' => 'table',
                               'columns' => [ { 'column' => 'order_id' },
                                              { 'column' => 'amount', 'aggregation' => 'SUM' } ],
                               'summaryNumber' => { 'column' => ' ', 'aggregation' => 'COUNT' } }, {})
ok(!no_companion.nil?, 'primary element still built')
eq($companion_elements.size, 0, 'no companion when the summary number has no resolvable column')
ok($warnings.any? { |w| w['warning'].include?('NOT represented') }, 'still warns loudly on the unresolvable case (unchanged existing behavior)')

puts "== bead 08sf: Rule 0 (summary IS the whole card) still short-circuits to a single " \
     'KPI, no companion (unchanged) =='
$warnings = []
$companion_elements = []
rule0 = build_element({ 'id' => 'c33', 'title' => 'One Number', 'chartType' => 'badge_table',
                        'sigmaKindHint' => 'table', 'groupBy' => [], 'columns' => [{ 'column' => 'total', 'aggregation' => 'SUM' }],
                        'summaryNumber' => { 'column' => 'total', 'aggregation' => 'SUM' } }, {})
eq(rule0['kind'], 'kpi-chart', 'Rule 0 still routes straight to a single KPI')
eq($companion_elements.size, 0, 'no companion is produced for a Rule-0 card (it IS the KPI, not a chart+companion)')

puts "== C1 (final review, Critical): a ROUTED card whose PRIMARY element fails to build " \
     'must NOT leak its companion KPI un-retargeted into $companion_elements =='
Dir.mktmpdir do |dir|
  dm_spec_path = File.join(dir, 'dm-spec.json')
  dm_ids_path  = File.join(dir, 'dm-ids.json')
  File.write(dm_spec_path, JSON.generate('pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => 'Customer Dim', '_datasetId' => 'ds-dim' },
  ] }]))
  File.write(dm_ids_path, JSON.generate('dataModelId' => 'dm-live-1', 'pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => 'Customer Dim', 'columnLabels' => ['Region', 'Segment'] },
  ] }]))
  stub_const('DM_SPEC_PATH', dm_spec_path) do
    stub_const('DM_IDS_PATH', dm_ids_path) do
      $ds_element_map = nil
      $sub_masters = {}
      $warnings = []
      $companion_elements = []
      before_companions = $companion_elements.length

      # Routed to ds-dim's sub-master (resolvable, per the fixture above), so
      # this DOES take the routing path (not the warn+SKIP "unresolvable
      # DataSet" fallback). Two non-aggregated dimension columns (no
      # 'aggregation', no groupBy/mapping signal) means split_cols resolves
      # ZERO measures, so build_axis_chart's own "could not resolve both a
      # dimension and a measure" guard fires and returns nil for the PRIMARY
      # element — while the card ALSO carries a resolvable summaryNumber, so
      # build_element_body has a companion ready to go before it discovers
      # the primary failed.
      failed = build_element({ 'id' => 'c34', 'title' => 'Customers (no measure)', 'chartType' => 'badge_vert_bar',
                               'datasetId' => 'ds-dim',
                               'columns' => [ { 'column' => 'region' }, { 'column' => 'segment' } ],
                               'summaryNumber' => { 'column' => 'net_revenue', 'aggregation' => 'SUM',
                                                    'label' => 'Total Revenue' } },
                             {}, 'ds-fact')

      ok(failed.nil?, 'build_element still returns nil when the routed primary element failed to build')
      eq($companion_elements.length, before_companions,
         '$companion_elements did NOT grow — the companion built during the failed attempt was ' \
         'dropped, never leaked un-retargeted against the shared master (C1)')

      # M3: the warning sequence must not claim a companion "represents" a
      # card whose primary element was actually dropped.
      ok(!$warnings.any? { |w| w['warning'].include?('ALSO represented') },
         'the misleading "ALSO represented" warning does NOT fire when the primary failed to build (M3)')
      ok($warnings.any? { |w| w['warning'].include?('was NOT emitted') && w['warning'].include?('failed to build') },
         'a warning explains the companion was dropped BECAUSE the primary failed (M3)')
    end
  end
end

puts "== bead 08sf follow-up (live-found 2026-07-31): build_kpi inlines an aggregate " \
     'Beast Mode summary number instead of referencing a non-existent DM column =='
$translated_bms = {
  'calculation_margin' => { 'id' => 'calculation_margin', 'name' => 'Margin Pct',
                            'class' => 'aggregate',
                            'sigmaFormula' => 'If(Sum([Net Revenue]) = 0, 0, Sum([Gross Profit]) / Sum([Net Revenue]))' },
}
calc_kpi = build_kpi({ 'id' => 'c34', 'title' => 'Margin % by Channel',
                       'summaryNumber' => { 'column' => 'Margin Pct', 'beastModeId' => 'calculation_margin',
                                            '_isCalc' => true, 'label' => 'Margin Pct' } }, {})
ok(!calc_kpi.nil?, 'KPI still built for an aggregate-calc summary number')
eq(calc_kpi['columns'][0]['formula'],
   'Coalesce(If(Sum([Master/Net Revenue]) = 0, 0, Sum([Master/Gross Profit]) / Sum([Master/Net Revenue])), 0)',
   'formula is the INLINED, masterized Beast Mode expression — NOT Sum([Master/Margin Pct]), ' \
   'a column that does not exist and would 400 the whole workbook POST')
eq(calc_kpi['value'], { 'columnId' => calc_kpi['columns'][0]['id'] }, "value.columnId matches the inlined column's own id")
$translated_bms = nil

puts "== bead 08sf follow-up: a kpi-overrides.json entry still bypasses Beast Mode inlining =="
override_kpi = build_kpi({ 'id' => 'c34', 'title' => 'Margin % by Channel',
                           'summaryNumber' => { 'column' => 'Margin Pct', 'beastModeId' => 'calculation_margin',
                                                '_isCalc' => true } },
                         { 'c34' => { 'column' => 'net_revenue', 'aggregation' => 'SUM' } })
eq(override_kpi['columns'][0]['formula'], 'Sum([Master/Net Revenue])', 'override still wins over the calc inlining')

puts "== B4 (real-data shape): a card-level filter on a column the card does NOT already " \
     'plot becomes an ELEMENT filter with its real values, on a new HIDDEN column =='
# Mirrors the real "Projected Sales" card (1eb93e0f dataset, chartType
# badge_trendline) from the 2026-08-05 cold run: columns CalendarQuarter/
# Amount, filters: [{"column":"IsWon","operator":"LEGACY","values":["true"]}].
$warnings = []
$companion_elements = []
projected_sales = build_element({
  'id' => '1998254736', 'title' => 'Projected Sales', 'chartType' => 'badge_trendline',
  'sigmaKindHint' => 'line-chart',
  'columns' => [ { 'column' => 'CalendarQuarter', 'mapping' => 'ITEM' },
                 { 'column' => 'Amount', 'aggregation' => 'SUM', 'mapping' => 'VALUE' } ],
  'filters' => [ { 'column' => 'IsWon', 'operator' => 'LEGACY', 'values' => ['true'] } ],
}, {})
eq(projected_sales['kind'], 'area-chart', 'Domo trendline keeps its filled area shape')
ok(projected_sales.key?('filters'), 'the card filter produced an element filter (it used to produce NOTHING)')
flt = projected_sales['filters'].find { |f| f['values'] == ['true'] }
ok(!flt.nil?, 'the filter carries the REAL value ["true"] — not dropped, not empty (B4 core fix)')
eq(flt['kind'], 'list', "LEGACY (Domo's classic 'value is one of' filter) maps to a list filter")
eq(flt['mode'], 'include', 'LEGACY maps to include, not exclude')
hidden_col = projected_sales['columns'].find { |c| c['id'] == flt['columnId'] }
ok(!hidden_col.nil?, 'the filter targets a real column present in the element\'s own columns array')
eq(hidden_col['formula'], '[Master/Is Won]', 'the new column references the master, display-named IsWon -> Is Won')
eq(hidden_col['hidden'], true, "the filter-only column is marked hidden — IsWon wasn't a plotted dim/measure")
ok(projected_sales['columns'].size == 3, 'exactly one new column was added (2 plotted + 1 hidden filter column)')

puts "== B4: a filter on a column the card ALREADY plots reuses that column — no duplicate =="
# Mirrors the real "Top Salespeople" card: columns IsWon/Amount/Owner.Name/
# Amount, filters: [{"column":"IsWon",...,"values":["true"]}].
$warnings = []
$companion_elements = []
$chart_helpers = []
top_salespeople = build_element({
  'id' => '2071758146', 'title' => 'Top Salespeople', 'chartType' => 'badge_bubble',
  'sigmaKindHint' => 'scatter-chart',
  'columns' => [ { 'column' => 'IsWon', 'mapping' => 'ITEM' },
                 { 'column' => 'Amount', 'aggregation' => 'SUM', 'mapping' => 'VALUE' } ],
  'filters' => [ { 'column' => 'IsWon', 'operator' => 'LEGACY', 'values' => ['true'] } ],
}, {})
top_salespeople_helper = $chart_helpers.last
before_size = top_salespeople_helper['columns'].size
flt2 = top_salespeople_helper['filters'].find { |f| f['values'] == ['true'] }
dim_col_for_iswon = top_salespeople_helper['columns'].find { |c| c['id'] == 'd-iswon' }
ok(!dim_col_for_iswon.nil?, 'IsWon is plotted as the dimension column, id d-iswon')
eq(flt2['columnId'], 'd-iswon',
   'the grouped source filter reuses its EXISTING dimension column, not a duplicate')
eq(before_size, 2, 'no extra helper column was appended — reuse, not duplication')

puts "== B4: a raw-value filter never targets an aggregated measure of the same column =="
$chart_helpers = []
build_element({
  'id' => 'c39b', 'title' => 'Won Deals', 'chartType' => 'badge_bubble',
  'columns' => [
    { 'column' => 'IsWon', 'aggregation' => 'COUNT', 'mapping' => 'XTIME' },
    { 'column' => 'Amount', 'aggregation' => 'AVG', 'mapping' => 'VALUE' },
    { 'column' => 'Owner', 'mapping' => 'SERIES' },
  ],
  'filters' => [{ 'column' => 'IsWon', 'operator' => 'IN', 'values' => ['true'] }],
}, {})
agg_helper = $chart_helpers.last
raw_filter = agg_helper['filters'].find { |f| f['values'] == ['true'] }
eq(raw_filter['columnId'], 'f-iswon',
   'list filter uses a hidden raw IsWon column, not Count(IsWon)')
eq(agg_helper['columns'].find { |c| c['id'] == 'f-iswon' }['formula'], '[Master/Is Won]',
   'hidden filter target preserves row-level boolean semantics')

puts "== B4: an operator with no faithful Sigma translation is dropped LOUDLY, never silently =="
$warnings = []
$companion_elements = []
weird_op = build_element({
  'id' => 'c40', 'title' => 'Big Deals', 'chartType' => 'badge_vert_bar', 'sigmaKindHint' => 'bar-chart',
  'columns' => [ { 'column' => 'region' }, { 'column' => 'amount', 'aggregation' => 'SUM' } ],
  'filters' => [ { 'column' => 'amount', 'operator' => 'BETWEEN', 'values' => [100, 500] } ],
}, {})
ok(!weird_op.key?('filters'), 'BETWEEN has no list-filter translation here — nothing was emitted')
ok($warnings.any? { |w| w['warning'].include?("card filter on 'amount' dropped") && w['warning'].include?('BETWEEN') },
   'the drop is reported by name — never a silent loss (per refs/card-to-element.md\'s "diff the filter inventory")')

puts "== B4: a filter on a translated (even mis-classified) Beast Mode inlines its formula, " \
     'like inline_beast_mode_measure does for a measure =='
# Mirrors the real card 1267439679's second filter clause: column
# "calculation_ea1150fd-..." ("State"), values [""].
$warnings = []
$companion_elements = []
$translated_bms = {
  'calculation_ea1150fd' => { 'id' => 'calculation_ea1150fd', 'name' => 'State', 'class' => 'aggregate',
                              'sigmaFormula' => 'If(Equals([Account.BillingState], "CA"), "California", "Other")' },
}
calc_filter_card = build_element({
  'id' => '1267439679', 'title' => 'PDP Example', 'chartType' => 'badge_map', 'sigmaKindHint' => nil,
  'columns' => [ { 'column' => 'State' }, { 'column' => 'Name' } ],
  'filters' => [ { 'column' => 'calculation_ea1150fd', 'operator' => 'LEGACY', 'values' => [''] } ],
}, {})
ok(!calc_filter_card.nil?, 'card still builds (State classifies as a us-state region-map geography)')
flt3 = calc_filter_card['filters'].find { |f| f['values'] == [''] }
ok(!flt3.nil?, 'the calc-id filter clause produced a real filter, values carried as-is')
calc_col = calc_filter_card['columns'].find { |c| c['id'] == flt3['columnId'] }
eq(calc_col['name'], 'State', 'the new column takes the Beast Mode\'s real name, not the raw calc id')
eq(calc_col['formula'], 'If(Equals([Master/Account Billing State], "CA"), "California", "Other")',
   'the Beast Mode formula is INLINED, masterized, and display_name-normalized (the master column is "Account Billing State", not the raw dotted Domo name)')
$translated_bms = nil

puts "== B4: a filter on an UNTRANSLATED Beast Mode is dropped LOUDLY, mirroring " \
     'prune_unresolvable_columns! for ordinary data columns =='
$warnings = []
$companion_elements = []
$translated_bms = {}
untranslated = build_element({
  'id' => 'c41', 'title' => 'US Leads', 'chartType' => 'badge_map', 'sigmaKindHint' => nil,
  'columns' => [ { 'column' => 'Account.BillingState' }, { 'column' => 'Name' } ],
  'filters' => [ { 'column' => 'calculation_deadbeef', 'operator' => 'LEGACY', 'values' => ['x'] } ],
}, {})
ok(!untranslated.nil?, 'card still builds')
ok(!untranslated.key?('filters') || untranslated['filters'].none? { |f| f['values'] == ['x'] },
   'the untranslated calc filter was never emitted')
ok($warnings.any? { |w| w['warning'].include?("card filter on 'calculation_deadbeef' dropped") &&
                        w['warning'].include?('Beast Mode did not translate') },
   'dropped loudly, naming the reason (never a silent loss)')
$translated_bms = nil

puts "== B4: pivot-table element filters are a documented Sigma silent-drop trap — " \
     'warn and do NOT emit rather than ship a filter Sigma will ignore =='
$warnings = []
$companion_elements = []
pivot_card = build_element({
  'id' => 'c42', 'title' => 'Sales Pivot', 'chartType' => 'badge_pivottable', 'sigmaKindHint' => 'pivot-table',
  'columns' => [ { 'column' => 'region' }, { 'column' => 'quarter' }, { 'column' => 'amount', 'aggregation' => 'SUM' } ],
  'filters' => [ { 'column' => 'region', 'operator' => 'LEGACY', 'values' => ['West'] } ],
}, {})
eq(pivot_card['kind'], 'pivot-table', 'still a pivot-table element')
ok(!pivot_card.key?('filters'), 'the filter was NOT attached to the pivot-table element (Sigma silently drops it there)')
ok($warnings.any? { |w| w['warning'].include?('NOT applied') && w['warning'].include?('pivot-table') },
   'the pivot-table trap is flagged loudly instead of shipping an ignored filter')

puts "== B4: the companion KPI (bead 08sf) carries the SAME card filters as its primary " \
     'element — Domo\'s Summary Number is scoped to the same card-level filters =='
$warnings = []
$companion_elements = []
with_companion = build_element({
  'id' => 'c43', 'title' => 'Revenue by Channel (Won only)', 'chartType' => 'badge_vert_bar',
  'sigmaKindHint' => 'bar-chart',
  'columns' => [ { 'column' => 'channel' }, { 'column' => 'net_revenue', 'aggregation' => 'SUM' } ],
  'summaryNumber' => { 'column' => 'net_revenue', 'aggregation' => 'SUM', 'label' => 'Total Revenue' },
  'filters' => [ { 'column' => 'IsWon', 'operator' => 'LEGACY', 'values' => ['true'] } ],
}, {})
ok(!with_companion.nil?, 'primary element built')
eq($companion_elements.size, 1, 'companion KPI built')
comp = $companion_elements.first
ok(comp.key?('filters'), 'the companion KPI ALSO carries an element filter')
comp_flt = comp['filters'].find { |f| f['values'] == ['true'] }
ok(!comp_flt.nil?, 'same filter, same real value, on the companion too — no unfiltered total beside a filtered chart')

puts "== F3: page name resolution falls back to the page's REAL title, not the literal " \
     "'Overview', when cardIds/cards is empty and there is exactly ONE page in scope =="
# Mirrors the real 2026-08-05 cold run: page 'Sample DataSets + Cards' (id
# 59931332) reports cardIds: [] while genuinely owning all 36 cards.
real_page = [{ 'id' => 59931332, 'title' => 'Sample DataSets + Cards', 'cardIds' => [] }]
real_cards = [{ 'id' => 'card-1' }, { 'id' => 'card-2' }]
grouped = group_cards_by_page(real_cards, real_page)
eq(grouped.keys, ['Sample DataSets + Cards'], 'the single real page\'s own title is used, not "Overview"')
eq(grouped['Sample DataSets + Cards'].size, 2, 'both cards attributed to it')

puts "== F3: multiple pages with no reliable cardIds attribution keep the honest " \
     "'Overview' placeholder — guessing which page owns which card would be worse =="
ambiguous_pages = [{ 'id' => 1, 'title' => 'Page One', 'cardIds' => [] },
                   { 'id' => 2, 'title' => 'Page Two', 'cardIds' => [] }]
grouped2 = group_cards_by_page(real_cards, ambiguous_pages)
eq(grouped2.keys, ['Overview'], 'falls back to the placeholder rather than mis-attributing to one of two pages')

puts "== F3: cardIds/cards, when actually populated, still take priority over any fallback =="
reliable_pages = [{ 'id' => 1, 'title' => 'Page One', 'cardIds' => ['card-1'] },
                  { 'id' => 2, 'title' => 'Page Two', 'cards' => ['card-2'] }]
grouped3 = group_cards_by_page(real_cards, reliable_pages)
eq(grouped3.keys.sort, ['Page One', 'Page Two'], 'real per-page attribution is honored when present')
eq(grouped3['Page One'].map { |c| c['id'] }, ['card-1'], 'card-1 -> Page One via cardIds')
eq(grouped3['Page Two'].map { |c| c['id'] }, ['card-2'], 'card-2 -> Page Two via cards')

puts "== F4: an ungrounded badge_filledgauge warning fires even when Rule 0 " \
     'short-circuits straight to build_kpi =='
$warnings = []
$companion_elements = []
real_gauge = build_element({
  'id' => '983053598', 'title' => 'Quota Attainment', 'chartType' => 'badge_filledgauge',
  'sigmaKindHint' => 'kpi-chart',   # verified real shape: sigma_kind_hint substring-matches 'gauge'
  'summaryNumber' => { 'column' => 'attainment', 'aggregation' => 'SUM', 'label' => 'Attainment' },
  'columns' => [ { 'column' => 'attainment', 'aggregation' => 'SUM' } ],
}, {})
eq(real_gauge['kind'], 'kpi-chart', 'Rule 0 still degrades it to a KPI (that part was always correct)')
ok($warnings.any? { |w| w['warning'].include?('requires explicit CURRENT and TARGET') },
   'the honest progress-range warning ALSO fires on this path')

puts "== F4: the warning fires exactly once per card, not duplicated on the non-Rule-0 path =="
$warnings = []
$companion_elements = []
gauge_via_case = build_element({
  'id' => 'c44', 'title' => 'Other Gauge', 'chartType' => 'badge_filledgauge', 'sigmaKindHint' => nil,
  'summaryNumber' => { 'column' => 'attainment', 'aggregation' => 'SUM' },
  'columns' => [ { 'column' => 'attainment', 'aggregation' => 'SUM' }, { 'column' => 'target', 'aggregation' => 'SUM' } ],
}, {})
eq(gauge_via_case['kind'], 'kpi-chart', 'still resolves to kpi-chart via the case-statement path (not Rule 0)')
gauge_warnings = $warnings.select { |w| w['warning'].include?('requires explicit CURRENT and TARGET') }
eq(gauge_warnings.size, 1, 'exactly one progress-range warning — never double-fired')

puts "== B4 + bead ziht: a card-level filter on a SUB-MASTER-routed card is retargeted " \
     'to that sub-master\'s namespace, just like every other column — never left ' \
     'pointing at the shared "[Master/...]" it does not source from =='
Dir.mktmpdir do |dir|
  dm_spec_path = File.join(dir, 'dm-spec.json')
  dm_ids_path  = File.join(dir, 'dm-ids.json')
  File.write(dm_spec_path, JSON.generate('pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => 'Customer Dim', '_datasetId' => 'ds-dim' },
  ] }]))
  File.write(dm_ids_path, JSON.generate('dataModelId' => 'dm-live-1', 'pages' => [{ 'elements' => [
    { 'id' => 'el-dim-1', 'name' => 'Customer Dim', 'columnLabels' => ['Region', 'Segment'] },
  ] }]))
  stub_const('DM_SPEC_PATH', dm_spec_path) do
    stub_const('DM_IDS_PATH', dm_ids_path) do
      $ds_element_map = nil
      $sub_masters = {}
      $warnings = []
      $companion_elements = []
      routed_filtered = build_element({
        'id' => 'c45', 'title' => 'Customers by Region', 'chartType' => 'badge_table',
        'sigmaKindHint' => 'table', 'datasetId' => 'ds-dim',
        'columns' => [ { 'column' => 'region' } ],
        'filters' => [ { 'column' => 'segment', 'operator' => 'LEGACY', 'values' => ['Enterprise'] } ],
      }, {}, 'ds-fact')
      ok(!routed_filtered.nil?, 'card is not skipped — the sub-master is resolvable')
      eq(routed_filtered['source'], { 'kind' => 'table', 'elementId' => 'master-ds-dim' }, 'sourced from its own sub-master')
      flt = routed_filtered['filters'].find { |f| f['values'] == ['Enterprise'] }
      ok(!flt.nil?, 'the card filter still produced an element filter even though it never touches the shared master')
      seg_col = routed_filtered['columns'].find { |c| c['id'] == flt['columnId'] }
      eq(seg_col['formula'], '[Master (Customer Dim)/Segment]',
         'the new filter column was retargeted to the SUB-MASTER\'s own namespace, not left as ' \
         '"[Master/Segment]" (which does not exist for this card\'s element)')
    end
  end
end


puts "== step 6 / dateRangeFilter: a ROLLING_PERIOD card window becomes an element filter =="
# MEASURED on the 36-card cold run: 29 of 36 cards carry a date window
# (24 ROLLING_PERIOD + 5 INTERVAL_OFFSET), and the generated Sigma spec carried
# ZERO date filters — so 55 of the 65 chartable tiles aggregated over ALL history
# while their Domo counterparts aggregated over a rolling window. Against
# min_pass_rate 1.0 that alone makes gate 1 unpassable, no matter how good the
# parity oracle is.
#
# Sigma has NO element-level date-range filter kind (live-verified 2026-07-17:
# only list / top-n / number-range round-trip), and a date-range CONTROL is not
# usable here: a control targets a TABLE, so it would propagate to every element
# sourcing the shared master — yet the corpus has 20 DISTINCT windows across 9
# datasets, up to 4 different windows on a single dataset. So the window has to be
# element-local: a HIDDEN boolean window column + a `list` filter including "in".
# That shape uses only the verified-supported `list` kind, is element-local (no
# propagation), and no tile in this corpus is a pivot-table (the one kind whose
# own filters Sigma silently drops).
$warnings = []
win = build_element({ 'id' => 'c40', 'title' => 'Page Views (last 14 days)', 'chartType' => 'badge_line',
                      'dateRangeFilter' => {
                        'column' => { 'column' => 'Date', 'exprType' => 'COLUMN' },
                        'dateTimeRange' => { 'dateTimeRangeType' => 'ROLLING_PERIOD',
                                             'interval' => 'DAY', 'offset' => 0, 'count' => 14 } },
                      'columns' => [{ 'column' => 'Date' },
                                    { 'column' => 'views', 'aggregation' => 'SUM' }] }, {})
ok(win.key?('filters'), 'a ROLLING_PERIOD window produced an element filter')
dfs = Array(win['filters']).select { |f| f['id'].to_s.start_with?('dw-') }
eq(dfs.size, 1, 'exactly one date-window filter')
eq(dfs.first['kind'], 'list', "filter kind is list (Sigma has NO element date-range kind)")
eq(dfs.first['mode'], 'include', 'mode is include')
eq(dfs.first['values'], ['in'], 'includes only the in-window sentinel')
wc = Array(win['columns']).find { |c| c['id'] == dfs.first['columnId'] }
ok(!wc.nil?, 'the filter targets a column the element actually has')
eq(wc['hidden'], true, 'the window column is HIDDEN — the source card never rendered it')
ok(wc['formula'].include?('DateTrunc("day", DateAdd("day", -13, Today()))'),
   "lower bound includes 14 calendar-day buckets — got #{wc && wc['formula']}")
ok(wc['formula'].include?('< DateAdd("day", 1, DateTrunc("day", Today()))'),
   "upper bound excludes future buckets — got #{wc && wc['formula']}")
ok(wc['formula'].include?(' and '), 'both calendar-bucket bounds are required')
ok(wc['formula'].include?('Today()'), 'predicate is anchored on Today()')

puts "== step 6: unit mapping covers every interval the corpus actually uses =="
# MEASURED intervals in the corpus: DAY, MONTH, QUARTER, WEEK, YEAR.
{ 'DAY' => 'day', 'MONTH' => 'month', 'QUARTER' => 'quarter',
  'WEEK' => 'week', 'YEAR' => 'year' }.each do |domo, sigma|
  $warnings = []
  e = build_element({ 'id' => "c41-#{domo}", 'title' => "T #{domo}", 'chartType' => 'badge_line',
                      'dateRangeFilter' => {
                        'column' => { 'column' => 'Date' },
                        'dateTimeRange' => { 'dateTimeRangeType' => 'ROLLING_PERIOD',
                                             'interval' => domo, 'offset' => 0, 'count' => 3 } },
                      'columns' => [{ 'column' => 'Date' },
                                    { 'column' => 'v', 'aggregation' => 'SUM' }] }, {})
  c = Array(e['columns']).find { |x| x['id'].to_s.start_with?('f-datewin') }
  # NB: a %(...) literal would balance the nested paren and silently append ")"
  # to the needle — use an explicit escaped string.
  needle = "DateTrunc(\"#{sigma}\", DateAdd(\"#{sigma}\", -2, Today()))"
  ok(c && c['formula'].include?(needle),
     "#{domo} -> \"#{sigma}\" (got #{c && c['formula']})")
  upper = "< DateAdd(\"#{sigma}\", 1, DateTrunc(\"#{sigma}\", Today()))"
  ok(c && c['formula'].include?(upper),
     "#{domo} carries an exclusive next-bucket upper bound")
end

puts "== step 6: no dateRangeFilter -> no window column and no window filter =="
$warnings = []
nowin = build_element({ 'id' => 'c42', 'title' => 'All History', 'chartType' => 'badge_line',
                        'columns' => [{ 'column' => 'Date' },
                                      { 'column' => 'v', 'aggregation' => 'SUM' }] }, {})
ok(Array(nowin['filters']).none? { |f| f['id'].to_s.start_with?('dw-') },
   'never emit a default/empty date window')
ok(Array(nowin['columns']).none? { |c| c['id'].to_s.start_with?('f-datewin') },
   'and no orphan window column')

puts "== step 6: INTERVAL_OFFSET maps to one completed calendar bucket =="
$warnings = []
io = build_element({ 'id' => 'c43', 'title' => 'Survey Completion Rate', 'chartType' => 'badge_line',
                     'dateRangeFilter' => {
                       'column' => { 'column' => 'created_on' },
                       'dateTimeRange' => { 'dateTimeRangeType' => 'INTERVAL_OFFSET',
                                            'interval' => 'WEEK', 'offset' => 1, 'count' => 0 } },
                     'columns' => [{ 'column' => 'created_on' },
                                   { 'column' => 'v', 'aggregation' => 'SUM' }] }, {})
io_filter = Array(io['filters']).find { |f| f['id'].to_s.start_with?('dw-') }
ok(io_filter, 'INTERVAL_OFFSET emits an element-local window filter')
io_col = io['columns'].find { |c| c['id'] == io_filter['columnId'] }
ok(io_col['formula'].include?('DateTrunc("week", DateAdd("week", -1, Today()))'),
   'Sigma week offset uses its Domo-compatible Sunday boundary')
ok(io_col['formula'].include?('< DateAdd("week", 1, DateTrunc("week"'),
   'window ends exclusively at the next boundary')

calc_kpi = build_element({
  'id' => 'c43b', 'title' => 'Completion', 'chartType' => 'badge_filledgauge',
  'summaryNumber' => { 'column' => 'Completion Rate 30-Day', '_isCalc' => true },
  'dateRangeFilter' => {
    'column' => { 'column' => 'created_on' },
    'dateTimeRange' => { 'dateTimeRangeType' => 'INTERVAL_OFFSET',
                         'interval' => 'WEEK', 'offset' => 1, 'count' => 0 },
  },
  'columns' => [{ 'column' => 'status', 'aggregation' => 'COUNT', 'mapping' => 'CURRENT' }],
}, {})
ok(Array(calc_kpi['filters']).any? { |f| f['id'].to_s.start_with?('dw-') },
   'calculated KPI is scoped to the source card interval')
ok(calc_kpi['columns'].first['formula'].start_with?('Coalesce('),
   'empty calculated KPI windows render source-equivalent zero instead of null')

puts "== step 6: an unresolvable date column is dropped LOUDLY, never a broken filter =="
$warnings = []
# The card needs a real dimension, or build_element legitimately declines to emit a
# line element at all and this would assert nothing.
bad = build_element({ 'id' => 'c44', 'title' => 'Bad Col', 'chartType' => 'badge_line',
                      'dateRangeFilter' => {
                        'column' => { 'column' => '' },
                        'dateTimeRange' => { 'dateTimeRangeType' => 'ROLLING_PERIOD',
                                             'interval' => 'DAY', 'offset' => 0, 'count' => 7 } },
                      'columns' => [{ 'column' => 'region' },
                                    { 'column' => 'v', 'aggregation' => 'SUM' }] }, {})
ok(!bad.nil?, 'the card still produces an element (the window is dropped, not the card)')
ok(Array(bad && bad['filters']).none? { |f| f['id'].to_s.start_with?('dw-') },
   'no filter with a nil/blank columnId is ever emitted')
ok(Array(bad && bad['columns']).none? { |c| c['id'].to_s.start_with?('f-datewin') },
   'and no orphan window column is left behind')
ok($warnings.any? { |w| w['warning'].to_s.include?('names no date column') },
   'the blank date column is warned, not silent')

puts "== live parity: raw SERIES overlays become Max measures on combo charts =="
overlay = build_element({
  'id' => 'c45', 'title' => 'Open Rate', 'chartType' => 'badge_line_stackedbar',
  'columns' => [
    { 'column' => 'CalendarMonth', 'mapping' => 'ITEM' },
    { 'column' => 'industry_stats_open_rate', 'alias' => 'Industry Open Rate', 'mapping' => 'SERIES' },
    { 'column' => 'opens_unique_opens', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
  ],
}, {})
benchmark = overlay['columns'].find { |c| c['name'] == 'Industry Open Rate' }
eq(benchmark['formula'], 'Max([Master/Industry Stats Open Rate])',
   'raw benchmark SERIES survives as a grouped Max measure')
ok(Array(overlay.dig('yAxis', 'columnIds')).any? {
     |x| (x.is_a?(Hash) ? x['columnId'] : x) == benchmark['id']
   },
   'benchmark is bound to a visible series channel')

puts "== live parity: split SERIES binds to color while ITEM remains x-axis =="
revenue = build_element({
  'id' => 'c46', 'title' => 'Revenue', 'chartType' => 'badge_vert_stackedbar',
  'columns' => [
    { 'column' => 'Account', 'mapping' => 'SERIES' },
    { 'column' => 'Date', 'mapping' => 'ITEM' },
    { 'column' => 'Revenue', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
  ],
}, {})
eq(revenue.dig('xAxis', 'columnId'), 'd-date', 'ITEM date is the x-axis, not SERIES account')
eq(revenue['color'], { 'by' => 'category', 'column' => 'd-account' },
   'SERIES account remains a bound split dimension')

puts "== live parity: scatter channels follow XTIME/VALUE/SERIES/BUBBLESIZE roles =="
$chart_helpers = []
scatter = build_element({
  'id' => 'c47', 'title' => 'Top Subjects', 'chartType' => 'badge_bubble',
  'orderBy' => ['Clicks'], 'limit' => 10,
  'columns' => [
    { 'column' => 'Subject', 'mapping' => 'SERIES' },
    { 'column' => 'Delivered', 'aggregation' => 'SUM', 'mapping' => 'XTIME' },
    { 'column' => 'Opens', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
    { 'column' => 'Clicks', 'aggregation' => 'SUM', 'mapping' => 'BUBBLESIZE' },
  ],
}, {})
eq(scatter['columns'].map { |c| c['id'] },
   %w[s-subject s-delivered s-opens s-clicks],
   'each source role appears once, in source order')
eq(scatter.dig('xAxis', 'columnId'), 's-delivered', 'XTIME measure binds x')
eq(scatter.dig('yAxis', 'columnIds'), ['s-opens'], 'VALUE measure binds y')
eq(scatter.dig('size', 'id'), 's-clicks', 'BUBBLESIZE binds size without a duplicate export column')
eq(scatter['color'], { 'by' => 'category', 'column' => 's-subject' }, 'SERIES identifies each point')
helper = $chart_helpers.last
eq(scatter['source'], { 'kind' => 'table', 'elementId' => helper['id'],
                        'groupingId' => helper['groupings'].first['id'] },
   'scatter binds to an explicit hidden grouping')
eq(helper['groupings'].first['groupBy'], ['d-subject'], 'helper groups to one point per Subject')
eq(helper['groupings'].first['calculations'], %w[m-delivered m-opens m-clicks],
   'helper pre-aggregates every scatter measure')
eq(helper['filters'].first['rowCount'], 10, 'source top-N is enforced on the grouped helper')

puts "== live parity: numeric comparison filters compile to hidden boolean predicates =="
compared = build_element({
  'id' => 'c48', 'title' => 'Delivered', 'chartType' => 'badge_vert_bar',
  'columns' => [
    { 'column' => 'Subject', 'mapping' => 'ITEM' },
    { 'column' => 'Delivered', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
  ],
  'filters' => [{ 'column' => 'Delivered', 'operator' => 'GREATER_THAN', 'values' => ['0'] }],
}, {})
cmp_filter = Array(compared['filters']).find { |f| f['columnId'].to_s.start_with?('f-cmp-') }
ok(cmp_filter, 'GREATER_THAN emits an element-local list filter')
cmp_col = compared['columns'].find { |c| c['id'] == cmp_filter['columnId'] }
eq(cmp_col['formula'], 'If([Master/Delivered] > 0.0, "in", "out")',
   'comparison helper preserves strict greater-than semantics')

puts "== live parity: treemap degradation preserves Domo's 500 visible leaves =="
treemap = build_element({
  'id' => 'c49', 'title' => 'Devices', 'chartType' => 'badge_treemap',
  'columns' => [
    { 'column' => 'Device', 'mapping' => 'ITEM' },
    { 'column' => 'Visits', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
  ],
}, {})
top500 = Array(treemap['filters']).find { |f| f['kind'] == 'top-n' }
eq(top500 && top500['rowCount'], 500, 'treemap fallback caps the same top 500 categories')

puts "== live parity: grouped DESC limit-1 Summary Number filters to current bucket =="
$companion_elements = []
build_element({
  'id' => 'c50', 'title' => 'Projected Sales', 'chartType' => 'badge_trendline',
  'columns' => [
    { 'column' => 'CalendarQuarter', 'mapping' => 'ITEM', 'calendar' => true },
    { 'column' => 'Amount', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
  ],
  'summaryNumber' => {
    'column' => 'Amount', 'aggregation' => 'SUM', 'label' => 'Sales this Period',
    '_raw' => {
      'groupBy' => [{ 'column' => 'CalendarQuarter', 'calendar' => true }],
      'orderBy' => [{ 'column' => 'CalendarQuarter', 'calendar' => true, 'order' => 'DESCENDING' }],
      'limit' => 1,
    },
  },
  'dateGrain' => { 'column' => 'CloseDate', 'dateTimeElement' => 'QUARTER' },
  'dateRangeFilter' => {
    'column' => { 'column' => 'CloseDate' },
    'dateTimeRange' => { 'dateTimeRangeType' => 'ROLLING_PERIOD',
                         'interval' => 'QUARTER', 'offset' => 0, 'count' => 5 },
  },
}, {})
latest = $companion_elements.find { |e| e['id'] == 'el-c50-summary' }
latest_filter = Array(latest && latest['filters']).find { |f| f['id'].to_s.start_with?('summary-latest-') }
ok(latest_filter, 'companion KPI has a machine-derived latest-bucket filter')
latest_col = latest['columns'].find { |c| c['id'] == latest_filter['columnId'] }
ok(latest_col['formula'].include?('DateTrunc("quarter"'),
   'latest-bucket predicate uses the source calendar grain')

puts "== screenshot-observed sections become real workbook text elements =="
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'layout-observed.json'), JSON.generate({
    'a' => { 'x' => 0, 'y' => 0.4, 'w' => 0.2, 'h' => 0.1, 'section' => 'Second' },
    'b' => { 'x' => 0, 'y' => 0.1, 'w' => 0.2, 'h' => 0.1, 'section' => 'First' },
    'c' => { 'x' => 0.2, 'y' => 0.4, 'w' => 0.2, 'h' => 0.1, 'section' => 'Second' },
  }))
  stub_const(:OUT, dir) do
    section_els = observed_section_elements([{ 'id' => 'a' }, { 'id' => 'b' }, { 'id' => 'c' }])
    text_els = section_els.select { |e| e['kind'] == 'text' }
    divider_els = section_els.select { |e| e['kind'] == 'divider' }
    eq(text_els.map { |e| e['id'] },
       %w[text-observed-section-0 text-observed-section-1],
       'section ids match build-domo-layout observed-section ids')
    eq(text_els.map { |e| e['name'] }, %w[First Second],
       'section text follows screenshot y-order, not discovery card order')
    eq(text_els.map { |e| e['body'] }, ['### First', '### Second'],
       'each observed section is visible authored text')
    eq(divider_els, [],
       'observed sections do not emit unplaced divider furniture')
  end
end

puts "== no-native chart family uses a hosted plugin with live data source =="
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'plugin-config.json'),
             JSON.generate('visual_plugin_id' => 'plugin-test-id',
                           'calendar_plugin_id' => 'calendar-test-id',
                           'gauge_plugin_id' => 'gauge-test-id'))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-plugin' => { 'connectionId' => 'conn-1', 'database' => 'DB',
                     'schema' => 'PUBLIC', 'table' => 'DEVICES' }
  ))
  stub_const(:OUT, dir) do
    $plugin_config = nil
    $plugin_dataset_map = nil
    $plugin_source_elements = []
    visual = build_element({
      'id' => 'c51', 'title' => 'Device Treemap', 'chartType' => 'badge_treemap',
      'datasetId' => 'ds-plugin',
      'columns' => [
        { 'column' => 'Device', 'mapping' => 'ITEM' },
        { 'column' => 'Visits', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
      ],
    }, {})
    eq(visual['kind'], 'plugin', 'visible element is a real Sigma plugin, not a captured image')
    eq(visual['id'], 'el-c51-plugin-v1',
       'plugin gets a fresh id instead of changing an existing chart kind in place')
    eq(visual['pluginId'], 'plugin-test-id', 'plugin registration id comes from operator sidecar')
    eq(visual.dig('config', 'mode'), 'treemap', 'Domo chart family selects plugin render mode')
    parity_source = $plugin_source_elements.find { |e| e['id'] == 'el-c51-verify' }
    direct_source = $plugin_source_elements.find { |e| e['id'] == 'src-plugin-el-c51' }
    eq(parity_source['kind'], 'bar-chart',
       'converted live chart remains as strict parity evidence')
    eq(direct_source['kind'], 'table', 'plugin picker gets a direct SQL table like the proven gauge')
    eq(direct_source.dig('source', 'kind'), 'sql', 'plugin source avoids a derived-element picker gap')
    ok(direct_source.dig('source', 'statement').include?('"DB"."PUBLIC"."DEVICES"'),
       'direct source SQL targets the mapped warehouse table')
    eq(visual.dig('config', 'source', 'elementId'), direct_source['id'],
       'plugin subscribes to the direct selectable table')
    eq(visual.dig('config', 'label'),
       { 'kind' => 'column', 'columnId' => 'd-label', 'source' => 'source' },
       'plugin label uses the proven structured column binding')
    eq(visual.dig('config', 'value'),
       { 'kind' => 'column', 'columnId' => 'm-value', 'source' => 'source' },
       'plugin value uses the proven structured column binding')

    calendar = build_element({
      'id' => 'c52', 'title' => 'Activity Calendar', 'chartType' => 'badge_calendar',
      'datasetId' => 'ds-plugin',
      'dateGrain' => { 'column' => 'Activity Date', 'dateTimeElement' => 'DAY' },
      'columns' => [
        { 'column' => 'Activity Date', 'mapping' => 'DATE' },
        { 'column' => 'Description', 'mapping' => 'EVENT' },
      ],
    }, {})
    eq(calendar['pluginId'], 'calendar-test-id',
       'calendar card reuses the proven live calendar registration')
    eq(calendar.dig('config', 'dateColumn'),
       { 'kind' => 'column', 'columnId' => 'd-label', 'source' => 'source' },
       'calendar date uses the working plugin column config shape')
    eq(calendar.dig('config', 'valueColumn'),
       { 'kind' => 'column', 'columnId' => 'm-value', 'source' => 'source' },
       'calendar value uses the working plugin column config shape')

    $companion_elements = []
    gauge = build_element({
      'id' => 'c53', 'title' => 'Completion', 'chartType' => 'badge_filledgauge',
      'datasetId' => 'ds-plugin',
      'summaryNumber' => {
        'column' => 'Completion Rate', 'beastModeId' => 'calc-rate', '_isCalc' => true,
        'format' => { 'type' => 'percent', 'format' => '0.0 %' },
      },
      'cardFormulas' => [{
        'id' => 'calc-rate',
        'formula' => "COUNT(CASE WHEN `status` = 'Closed' THEN `id` END) / COUNT(`id`)",
      }],
      'columns' => [
        { 'column' => 'status', 'aggregation' => 'COUNT', 'mapping' => 'CURRENT' },
        { 'column' => 'id', 'aggregation' => 'COUNT', 'mapping' => 'TARGET' },
      ],
    }, {})
    eq(gauge['pluginId'], 'gauge-test-id', 'filled gauge uses hosted gauge plugin')
    eq(gauge.dig('config', 'format'), '.1%', 'percent gauge preserves display format')
    eq(gauge.dig('config', 'value'),
       { 'kind' => 'column', 'columnId' => 'actual', 'source' => 'source' },
       'gauge value uses structured working-plugin binding')
    gauge_source = $plugin_source_elements.find { |e| e['id'] == 'src-plugin-el-c53' }
    ok(gauge_source.dig('source', 'statement').include?('AS ACTUAL, 1 AS TARGET'),
       'percent gauge binds a live formula fraction against target 1')
    ok($companion_elements.any? { |e| e['id'] == 'el-c53-summary' },
       'source Summary Number remains adjacent as a companion KPI')
  end
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
