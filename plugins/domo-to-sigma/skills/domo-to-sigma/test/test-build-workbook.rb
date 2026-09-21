#!/usr/bin/env ruby
# Unit tests for build-workbook.rb — the fixes for feedback #1,#2,#5,#7,#8.
#   ruby test/test-build-workbook.rb

require_relative '../scripts/build-workbook'
require_relative '../scripts/qa-check'
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

puts "== sparse KPI presentation overrides are optional, never fatal =="
Dir.mktmpdir do |dir|
  File.write(
    File.join(dir, 'kpi-format-overrides.json'),
    JSON.generate((1..4).each_with_object({}) { |index, out|
      out["sparse-#{index}"] = { 'fontSize' => 48 }
    })
  )
  cards = (1..5).map do |index|
    {
      'id' => "sparse-#{index}",
      'title' => "KPI #{index}",
      'chartType' => 'badge_singlevalue',
      'sigmaKindHint' => 'kpi-chart',
      'groupBy' => [],
      'columns' => [{ 'column' => 'value', 'aggregation' => 'SUM' }],
      'summaryNumber' => {
        'column' => 'value', 'aggregation' => 'SUM', 'label' => "KPI #{index}",
        '_defaultCountSuspect' => false,
      },
      'filters' => [],
    }
  end
  $warnings = []
  built = nil
  stub_const(:OUT, dir) { built = cards.map { |card| build_element(card, {}) } }
  eq(built.compact.size, 5,
     'five KPI elements build when kpi-format-overrides.json has only four card rules')
  eq(built.first(4).map { |element| element.dig('value', 'fontSize') }, [48, 48, 48, 48],
     'the four present rules are applied')
  ok(!built.last['value'].key?('fontSize'),
     'the unmatched KPI keeps its default presentation instead of dereferencing nil')
  ok($warnings.none? { |warning| warning['warning'].include?('sparse') },
     'a missing sparse-map key is normal and does not emit a false warning')
end

puts "== malformed optional presentation rules warn and fall back =="
Dir.mktmpdir do |dir|
  card = {
    'id' => 'malformed-rule', 'title' => 'Malformed Rule',
    'summaryNumber' => {
      'column' => 'value', 'aggregation' => 'SUM', 'label' => 'Value',
      '_defaultCountSuspect' => false,
    },
  }
  kpi = build_kpi(card, {})
  File.write(File.join(dir, 'kpi-format-overrides.json'), JSON.generate('malformed-rule' => 'not-an-object'))
  $warnings = []
  result = nil
  stub_const(:OUT, dir) { result = apply_kpi_display_override!(card, kpi) }
  eq(result, kpi, 'a non-object card rule leaves the KPI unchanged')
  ok($warnings.any? { |warning| warning['warning'].include?('expected Hash') },
     'a malformed card rule is named in warnings')

  File.write(File.join(dir, 'kpi-format-overrides.json'), '{')
  $warnings = []
  stub_const(:OUT, dir) { result = apply_kpi_display_override!(card, kpi) }
  eq(result, kpi, 'invalid sidecar JSON leaves the KPI unchanged')
  ok($warnings.any? { |warning| warning['warning'].include?('JSON::ParserError') },
     'invalid sidecar JSON is warned rather than crashing the build')
end

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
eq(bar['yAxis']['format'], { 'marks' => 'none', 'labels' => { 'fontSize' => 8 } },
   '#8 y-axis gridlines stay off while labels remain legible')
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

puts "== table Quick Filter becomes a card-scoped Sigma control =="
$warnings = []
$card_controls = []
$control_scope_entries = []
quick_table = build_element({
  'id' => 'table-quick', 'title' => 'Daily Category Detail',
  'chartType' => 'badge_table', 'sigmaKindHint' => 'table',
  'datasetId' => 'ds-quick',
  'columns' => [
    { 'column' => 'CATEGORY_NAME', 'mapping' => 'ITEM' },
    { 'column' => 'CONV_PCT', 'aggregation' => 'AVG', 'mapping' => 'VALUE' },
  ],
  'quickFilters' => [{
    'type' => 'string', 'displayType' => 'multiple_select',
    'name' => 'Category', 'column' => 'CATEGORY_NAME', 'operator' => 'IN', 'values' => [],
  }],
}, {})
quick_control = $card_controls.last
eq(quick_table['kind'], 'table', 'the source table remains a table')
eq(quick_control && quick_control['controlType'], 'list',
   'the Domo string slicer becomes a Sigma list control')
quick_table_helper = $chart_helpers.find { |helper| helper['id'] == 'src-el-table-quick-filters' }
eq(quick_control && quick_control.dig('source', 'source', 'elementId'), quick_table_helper && quick_table_helper['id'],
   'the picker reads values from the table card hidden source')
eq(quick_control && quick_control.dig('filters', 0, 'source', 'elementId'), quick_table_helper && quick_table_helper['id'],
   'the control filters only its source table chain, not every card on the page')
eq(quick_control && quick_control.dig('filters', 0, 'columnId'), 'f-category_name',
   'the control targets the helper column resolved from the Domo slicer')
eq($control_scope_entries.last && $control_scope_entries.last['scope'], [quick_table['id']],
   'the control-scope ledger records the intentionally card-local reach')

puts "== card control IDs remain unique and within Sigma's 64-character limit =="
$card_controls = []
$control_scope_entries = []
$chart_helpers = []
long_column = 'THIS_IS_A_VERY_LONG_SOURCE_COLUMN_NAME_THAT_WOULD_PREVIOUSLY_OVERFLOW_SIGMA_IDS'
collision_table = build_element({
  'id' => 'control-collisions', 'title' => 'Filterable Detail',
  'chartType' => 'badge_table', 'sigmaKindHint' => 'table', '_pageId' => 'page-a',
  'columns' => [{ 'column' => long_column }, { 'column' => 'Amount', 'aggregation' => 'SUM' }],
  'quickFilters' => [
    { 'name' => 'First', 'column' => long_column, 'operator' => 'IN', 'values' => [] },
    { 'name' => 'Second', 'column' => long_column, 'operator' => 'IN', 'values' => [] },
  ],
  'dateRangeFilter' => {
    'column' => { 'column' => long_column },
    'dateTimeRange' => {
      'dateTimeRangeType' => 'ROLLING_PERIOD', 'interval' => 'DAY', 'offset' => 0, 'count' => 7,
    },
  },
}, {})
collision_controls = $card_controls.select do |control|
  Array(control['filters']).any? do |filter|
    filter.dig('source', 'elementId') == collision_table.dig('source', 'elementId')
  end
end
eq(collision_controls.map { |control| control['id'] }.uniq.length, 3,
   'two same-column Quick Filters and a date selector get distinct element IDs')
eq(collision_controls.map { |control| control['controlId'] }.uniq.length, 3,
   'two same-column Quick Filters and a date selector get distinct control IDs')
ok(collision_controls.flat_map { |control| [control['id'], control['controlId']] }
                     .all? { |id| id.length <= 64 },
   'every generated control ID is capped at 64 characters')
eq(quick_filter_unsupported_reason(
     'displayType' => 'range_slider', 'operator' => 'IN'
   ),
   'displayType "range_slider" needs source min/max bounds',
   'range Quick Filters are deferred with the missing-bound reason')
eq(quick_filter_unsupported_reason(
     'displayType' => 'multiple_select', 'operator' => 'BETWEEN'
   ),
   'operator "BETWEEN" has no faithful Sigma control translation',
   'unsupported operators are not mislabeled as missing range bounds')

puts "== calculated Quick Filter and calculated Summary Number share valid helper columns =="
$card_controls = []
$control_scope_entries = []
$chart_helpers = []
$companion_elements = []
$translated_bms = {
  'calculation_segment' => {
    'id' => 'calculation_segment', 'name' => 'Customer Segment',
    'class' => 'projection', 'scope' => 'card', 'dataType' => 'STRING',
    'sigmaFormula' => 'If([Amount] >= 100, "High", "Standard")',
  },
  'calculation_margin' => {
    'id' => 'calculation_margin', 'name' => 'Margin Rate',
    'class' => 'aggregate', 'scope' => 'card', 'dataType' => 'DECIMAL',
    'sigmaFormula' => 'Sum([Margin]) / Sum([Revenue])',
  },
}
calc_table = build_element({
  'id' => 'calculated-controls', 'title' => 'Calculated Detail',
  'chartType' => 'badge_table', 'sigmaKindHint' => 'table',
  'columns' => [{ 'column' => 'Account' }, { 'column' => 'Revenue', 'aggregation' => 'SUM' }],
  'summaryNumber' => {
    'column' => 'Margin Rate', 'beastModeId' => 'calculation_margin',
    '_isCalc' => true, 'label' => 'Margin Rate',
  },
  'filters' => [{
    'column' => 'Customer Segment', 'beastModeId' => 'calculation_segment',
    '_isCalc' => true, 'operator' => 'IN', 'values' => ['High'],
  }],
  'quickFilters' => [{
    'name' => 'Segment', 'column' => 'Customer Segment',
    'formulaId' => 'calculation_segment', 'operator' => 'IN', 'values' => [],
  }],
}, {})
calc_helper = $chart_helpers.find { |helper| helper['id'] == 'src-el-calculated-controls-filters' }
calc_control = $card_controls.find { |control| control['name'] == 'Segment' }
ok(calc_helper && Array(calc_helper['columns']).none? do |column|
     column['formula'].to_s.include?('[Master/Customer Segment]')
   end,
   'helper never fabricates a passthrough for a calculated field absent from the data model')
ok(calc_helper && Array(calc_helper['columns']).any? do |column|
     column['formula'].to_s.include?('If([Master/Amount]')
   end,
   'calculated filter is inlined on the helper source')
ok(calc_control && Array(calc_helper['columns']).any? do |column|
     column['id'] == calc_control.dig('filters', 0, 'columnId')
   end,
   'calculated Quick Filter targets a real helper column')
calc_summary = $companion_elements.find { |element| element['id'] == 'el-calculated-controls-summary' }
ok(calc_summary && calc_summary.dig('source', 'elementId') == calc_helper['id'],
   'calculated Summary Number is rebound to the same filtered helper')
ok(calc_summary && Array(calc_summary['columns']).any? do |column|
     column['formula'].to_s.include?("[#{calc_helper['name']}/Margin]")
   end,
   'calculated Summary Number keeps its aggregate formula after helper rebinding')
$translated_bms = nil

puts "== pivot filters are applied on a hidden pre-filter source =="
$warnings = []
$card_controls = []
$control_scope_entries = []
$chart_helpers = []
pivot = build_element({
  'id' => 'pivot-filtered', 'title' => 'Category Performance Pivot',
  'chartType' => 'badge_pivot_table', 'sigmaKindHint' => 'pivot-table',
  'datasetId' => 'ds-pivot',
  'columns' => [
    { 'column' => 'CATEGORY_NAME', 'mapping' => 'ITEM' },
    { 'column' => 'IMG_TYPE', 'mapping' => 'ITEM' },
    { 'column' => 'CONV_PCT', 'aggregation' => 'AVG', 'mapping' => 'VALUE' },
  ],
  'filters' => [{ 'column' => 'CATEGORY_NAME', 'operator' => 'IN', 'values' => ['Premium'] }],
  'dateRangeFilter' => {
    'column' => { 'column' => 'EVENT_DATE' },
    'dateTimeRange' => {
      'dateTimeRangeType' => 'INTERVAL_OFFSET', 'interval' => 'DAY', 'offset' => 1, 'count' => 0,
    },
  },
  'quickFilters' => [{
    'type' => 'string', 'displayType' => 'multiple_select',
    'name' => 'Category', 'column' => 'CATEGORY_NAME', 'operator' => 'IN', 'values' => [],
  }],
}, {})
pivot_helper = $chart_helpers.find { |helper| helper['id'] == 'src-el-pivot-filtered-filters' }
pivot_control = $card_controls.find { |control| control['name'] == 'Category' }
eq(pivot['kind'], 'pivot-table', 'the source pivot remains a pivot-table')
eq(pivot.dig('source', 'elementId'), pivot_helper && pivot_helper['id'],
   'the pivot reads through its hidden pre-filter source')
eq(pivot_helper && pivot_helper['name'], 'Domo Filter Source pivot-filtered',
   'the hidden source gets a card-id-derived unique namespace')
ok(!pivot.key?('filters'), 'no ignored filters are attached directly to the pivot')
ok(pivot_helper && Array(pivot_helper['filters']).any? { |filter| filter['id'].to_s.start_with?('cf-') },
   'the permanent Category predicate is applied to the hidden source')
date_control = $card_controls.find { |control| control['controlType'] == 'date-range' }
eq(date_control && date_control.dig('filters', 0, 'source', 'elementId'),
   pivot_helper && pivot_helper['id'],
   'the Yesterday date selector remains interactive over the hidden source')
eq(date_control && date_control['mode'], 'last',
   'the INTERVAL_OFFSET date selector keeps a relative default')
eq(date_control && date_control['includeToday'], false,
   'Yesterday excludes the current day')
eq(pivot_control && pivot_control.dig('filters', 0, 'source', 'elementId'),
   pivot_helper && pivot_helper['id'],
   'the interactive Category Quick Filter targets the same hidden source')
eq(pivot_control && pivot_control.dig('source', 'source', 'elementId'),
   pivot_helper && pivot_helper['id'],
   'the pivot Quick Filter picker is populated from a table, never from the pivot')

puts "== duplicate card instances fail closed before duplicate element IDs are emitted =="
begin
  assert_unique_card_instances!([
    { 'id' => 'pinned-card', '_pageId' => 'page-1' },
    { 'id' => 'pinned-card', '_pageId' => 'page-2' },
  ])
  duplicate_card_refused = false
rescue ArgumentError => e
  duplicate_card_refused = e.message.include?('migrate the affected pages separately') &&
                           e.message.include?('page-1') && e.message.include?('page-2')
end
ok(duplicate_card_refused,
   'a card pinned to multiple pages is refused explicitly instead of creating duplicate element IDs')
begin
  assert_unique_card_instances!([{ 'id' => 'one' }, { 'id' => 'two' }])
  unique_cards_allowed = true
rescue ArgumentError
  unique_cards_allowed = false
end
ok(unique_cards_allowed, 'distinct card IDs remain valid')

puts "== day/week calendar labels preserve bucket identity =="
day_line = build_element({
  'id' => 'day-line', 'title' => 'Daily Conversion',
  'chartType' => 'badge_symbolline', 'sigmaKindHint' => 'line-chart',
  'dateGrain' => { 'column' => 'EVENT_DATE', 'dateTimeElement' => 'DAY' },
  'columns' => [
    { 'column' => 'CalendarDay', 'mapping' => 'ITEM', 'calendar' => true },
    { 'column' => 'CONV_PCT', 'aggregation' => 'AVG', 'mapping' => 'VALUE' },
  ],
}, {})
eq(day_line['columns'].first['format'],
   { 'kind' => 'datetime', 'formatString' => '%b %-d, %Y' },
   'day-grain labels do not collapse every date to a month/year string')

puts "== Phase-5 geometry gate: warn when a page's cards carry no x/y =="
$warnings = []
warn_missing_geometry('Overview', [{ 'id' => 'c7', 'title' => 'No Geometry' }, { 'id' => 'c8' }])
ok($warnings.any? { |w| w['warning'].include?("no grid geometry for page 'Overview'") &&
                          w['warning'].include?('kind-aware default composition') },
   'page with no card x/y names the honest default-composition fallback')

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

marimekko = build_element({
  'id' => 'c15-marimekko', 'title' => 'Age Bucket as % of Total',
  'chartType' => 'badge_vert_marimekko',
  'columns' => [
    { 'column' => 'Month', 'mapping' => 'ITEM' },
    { 'column' => '1-30', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => '31-60', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => '61-90', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => '90+', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
  ],
}, {})
eq(marimekko['kind'], 'bar-chart', 'badge_vert_marimekko uses the closest native bar chart')
eq(marimekko['stacking'], 'normalized',
   'Marimekko part-to-whole bands become normalized stacked bars')
eq(marimekko.dig('yAxis', 'columnIds').size, 4,
   'all four authored age-bucket series remain visible')

donut = build_element({ 'id' => 'c16', 'title' => 'Mix', 'chartType' => 'badge_donut',
                        'columns' => [ { 'column' => 'family' }, { 'column' => 'sales', 'aggregation' => 'SUM' } ] }, {})
eq(donut['kind'], 'donut-chart', 'badge_donut → donut-chart')
eq(donut['value'], { 'columnId' => donut['columns'].last['id'] }, 'donut value uses value.columnId')
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

puts "== explicit visual mappings exclude Shape-B support columns =="
$translated_bms = {
  'calc-ar-pct' => {
    'id' => 'calc-ar-pct', 'name' => 'AR %', 'class' => 'aggregate',
    'sigmaFormula' => 'Sum([AR Amount]) / Sum([Total])',
  },
}
dims, meas = split_cols({
  'chartType' => 'badge_two_trendline',
  'columns' => [
    { 'column' => 'CalendarMonth', 'mapping' => 'ITEM', 'calendar' => true },
    { 'column' => 'AR %', 'mapping' => 'VALUE', '_isCalc' => true, 'beastModeId' => 'calc-ar-pct' },
    { 'column' => 'Site', 'mapping' => 'SERIES' },
    { 'column' => '60+', 'aggregation' => 'SUM' },
    { 'column' => '31-60', 'aggregation' => 'SUM' },
    { 'column' => '1-30', 'aggregation' => 'COUNT' },
  ],
})
eq(dims.map { |column| column['column'] }, %w[CalendarMonth Site],
   'mapped ITEM/SERIES columns remain the only dimensions')
eq(meas.map { |column| column['column'] }, ['AR %'],
   'blank-mapped support aggregates do not leak onto the value axis')
$translated_bms = nil

puts "== combo chart display scaling resolves structured y-axis entries =="
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'chart-axis-overrides.json'), JSON.generate(
    'scaled-combo' => {
      'scale' => 1000, 'prefix' => '$', 'suffix' => 'K', 'decimals' => 0,
    },
  ))
  combo = {
    'id' => 'el-scaled-combo', 'kind' => 'combo-chart', 'name' => 'Amount YoY',
    'columns' => [
      { 'id' => 'm-current', 'name' => 'This Year', 'formula' => 'Sum([Master/Amount])' },
      { 'id' => 'm-prior', 'name' => '1 Year Ago', 'formula' => 'Sum([Master/Prior Amount])' },
    ],
    'yAxis' => {
      'columnIds' => [
        { 'columnId' => 'm-current', 'type' => 'bar' },
        { 'columnId' => 'm-prior', 'type' => 'line' },
      ],
    },
  }
  $chart_verification_elements = []
  stub_const(:OUT, dir) do
    apply_chart_axis_override!({ 'id' => 'scaled-combo', 'title' => 'Amount YoY' }, combo)
  end
  ok(combo['columns'].all? { |column| column['formula'].include?('/ 1000.0') },
     'both structured combo measures receive compact display scaling')
  eq($chart_verification_elements.size, 1,
     'raw unscaled combo twin remains available for parity')
end

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
$beast_mode_usage = []
$translated_bms = {
  'calculation_ea1150fd' => { 'id' => 'calculation_ea1150fd', 'name' => 'State', 'class' => 'aggregate',
                              'sigmaFormula' => 'If(Equals([Account.BillingState], "CA"), "California", "Other")' },
}
calc_filter_card = build_element({
  'id' => '1267439679', 'title' => 'PDP Example', 'chartType' => 'badge_map', 'sigmaKindHint' => nil,
  'columns' => [ { 'column' => 'State' }, { 'column' => 'Name' } ],
  'filters' => [ { 'column' => 'State', 'beastModeId' => 'calculation_ea1150fd',
                   '_isCalc' => true, 'operator' => 'LEGACY', 'values' => [''] } ],
}, {})
ok(!calc_filter_card.nil?, 'card still builds (State classifies as a us-state region-map geography)')
flt3 = calc_filter_card['filters'].find { |f| f['values'] == [''] }
ok(!flt3.nil?, 'the calc-id filter clause produced a real filter, values carried as-is')
calc_col = calc_filter_card['columns'].find { |c| c['id'] == flt3['columnId'] }
eq(calc_col['name'], 'State', 'the new column takes the Beast Mode\'s real name, not the raw calc id')
eq(calc_col['formula'], 'If(Equals([Master/Account Billing State], "CA"), "California", "Other")',
   'the Beast Mode formula is INLINED, masterized, and display_name-normalized (the master column is "Account Billing State", not the raw dotted Domo name)')
eq($beast_mode_usage.first['id'], 'calculation_ea1150fd',
   'filter usage is recorded by stable id even after discovery resolves its display name')
$translated_bms = nil

puts "== B4: a filter on an UNTRANSLATED Beast Mode is dropped LOUDLY, mirroring " \
     'prune_unresolvable_columns! for ordinary data columns =='
$warnings = []
$companion_elements = []
$translated_bms = {}
untranslated = build_element({
  'id' => 'c41', 'title' => 'US Leads', 'chartType' => 'badge_map', 'sigmaKindHint' => nil,
  'columns' => [ { 'column' => 'Account.BillingState' }, { 'column' => 'Name' } ],
  'filters' => [ { 'column' => 'Missing Calc', 'beastModeId' => 'calculation_deadbeef',
                   '_isCalc' => true, 'operator' => 'LEGACY', 'values' => ['x'] } ],
}, {})
ok(!untranslated.nil?, 'card still builds')
ok(!untranslated.key?('filters') || untranslated['filters'].none? { |f| f['values'] == ['x'] },
   'the untranslated calc filter was never emitted')
ok($warnings.any? { |w| w['warning'].include?("card filter on 'Missing Calc' dropped") &&
                        w['warning'].include?('Beast Mode did not translate') },
   'dropped loudly, naming the reason (never a silent loss)')
$translated_bms = nil

puts "== B4: pivot-table filters move to a hidden source because Sigma drops them on the pivot =="
$warnings = []
$companion_elements = []
$chart_helpers = []
pivot_card = build_element({
  'id' => 'c42', 'title' => 'Sales Pivot', 'chartType' => 'badge_pivottable', 'sigmaKindHint' => 'pivot-table',
  'columns' => [ { 'column' => 'region' }, { 'column' => 'quarter' }, { 'column' => 'amount', 'aggregation' => 'SUM' } ],
  'filters' => [ { 'column' => 'region', 'operator' => 'LEGACY', 'values' => ['West'] } ],
}, {})
eq(pivot_card['kind'], 'pivot-table', 'still a pivot-table element')
ok(!pivot_card.key?('filters'), 'the filter was NOT attached to the pivot-table element (Sigma silently drops it there)')
pivot_source = $chart_helpers.find { |helper| helper['id'] == 'src-el-c42-filters' }
ok(pivot_source && Array(pivot_source['filters']).any? { |filter| filter['values'] == ['West'] },
   'the pivot predicate is applied to its hidden table source instead')

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

puts "== projection Beast Modes resolve by scope and emitted DM name =="
$beast_mode_usage = []
$translated_bms = {
  'calc-card-projection' => {
    'id' => 'calc-card-projection', 'name' => 'Technical Label',
    'class' => 'projection', 'scope' => 'card',
    'sigmaFormula' => '[Technical Error Type] & " / " & [Video Queue]',
  },
  'calc-dataset-projection' => {
    'id' => 'calc-dataset-projection', 'name' => 'Project Id',
    'sigmaName' => 'Project Id (Beast Mode)',
    'class' => 'projection', 'scope' => 'dataset',
    'sigmaFormula' => '[Project Id] & " label"',
  },
}
card_projection = dim_col({
  'column' => 'Technical Label', 'beastModeId' => 'calc-card-projection', '_isCalc' => true,
})
eq(card_projection['formula'], '[Master/Technical Error Type] & " / " & [Master/Video Queue]',
   'card-local projection is inlined at workbook row scope')
dataset_projection = dim_col({
  'column' => 'Project Id', 'beastModeId' => 'calc-dataset-projection', '_isCalc' => true,
})
eq(dataset_projection['formula'], '[Master/Project Id (Beast Mode)]',
   'dataset projection binds the collision-safe name emitted by build-dm')
eq($beast_mode_usage.map { |usage| usage['id'] }.sort,
   %w[calc-card-projection calc-dataset-projection],
   'workbook usage is recorded by stable formula id for accounting')
$translated_bms = nil

puts "== duplicate Beast Mode names require stable-id lookup =="
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'formulas.json'), JSON.generate([
    { 'id' => 'duplicate-a', 'name' => 'Duplicate', 'scope' => 'card',
      'class' => 'projection', 'sigmaFormula' => '[A]' },
    { 'id' => 'duplicate-b', 'name' => 'Duplicate', 'scope' => 'card',
      'class' => 'projection', 'sigmaFormula' => '[B]' },
  ]))
  stub_const(:OUT, dir) do
    $translated_bms = nil
    index = translated_beast_modes
    ok(index.key?('duplicate-a') && index.key?('duplicate-b'),
       'both duplicate-name formulas remain addressable by id')
    ok(!index.key?('Duplicate'), 'ambiguous display name is not indexed to an arbitrary formula')
    eq($ambiguous_beast_mode_names, ['Duplicate'], 'ambiguous name is recorded for accounting')
  end
end
$translated_bms = nil

puts "== field regression: aggregate Beast Mode SERIES is a measure, never 2,013 color categories =="
$translated_bms = {
  'calc-ap-rate' => {
    'id' => 'calc-ap-rate', 'name' => 'AP %', 'class' => 'aggregate',
    'sigmaFormula' => 'Sum([On Auto Pay]) / Sum([Total Ledgers])',
  },
}
auto_pay = build_element({
  'id' => 'auto-pay-month', 'title' => 'Auto-Pay by Month', 'chartType' => 'badge_two_trendline',
  'dateGrain' => { 'column' => 'Date', 'dateTimeElement' => 'MONTH' },
  'columns' => [
    { 'column' => 'CalendarMonth', 'mapping' => 'ITEM', 'calendar' => true },
    { 'column' => 'Off Auto Pay', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => 'On Auto Pay', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => 'AP %', 'beastModeId' => 'calc-ap-rate', '_isCalc' => true, 'mapping' => 'SERIES' },
  ],
}, {})
ok(!auto_pay.key?('color'),
   'aggregate AP % is not emitted as color.by:category (the browser-locking 2,013-series bug)')
ap_measure = auto_pay['columns'].find { |column| column['name'] == 'AP %' }
ok(ap_measure && ap_measure['id'].start_with?('m-'), 'aggregate Beast Mode is classified as a measure')
ok(Array(auto_pay.dig('yAxis', 'columnIds')).include?(ap_measure['id']),
   'AP % stays visible on the value axis after the unsafe color channel is removed')
$translated_bms = nil

puts "== source-cardinality guard: observed high-cardinality SERIES color is omitted =="
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'chart-color-overrides.json'), JSON.generate(
    'high-color' => {
      'mode' => 'omit', 'distinctValuesObserved' => 2013, 'threshold' => 100,
      'source' => 'domo-card-data',
    }
  ))
  stub_const(:OUT, dir) do
    $warnings = []
    guarded = build_element({
      'id' => 'high-color', 'title' => 'Sites by Month', 'chartType' => 'badge_two_trendline',
      'columns' => [
        { 'column' => 'Date', 'mapping' => 'ITEM' },
        { 'column' => 'Site', 'mapping' => 'SERIES' },
        { 'column' => 'Revenue', 'mapping' => 'VALUE', 'aggregation' => 'SUM' },
      ],
    }, {})
    ok(!guarded.key?('color'), 'source-observed 2,013-member color channel is omitted')
    ok($warnings.any? { |warning| warning['warning'].include?('2,013') ||
                                   warning['warning'].include?('2013') },
       'the omitted source color records its measured cardinality')
  end
end

puts "== QA hard gate: aggregate formulas can never escape on a category color channel =="
bad_color_spec = {
  'pages' => [{
    'name' => 'Auto Pay',
    'elements' => [{
      'id' => 'bad-color', 'kind' => 'line-chart', 'name' => 'Auto-Pay by Month',
      'columns' => [
        { 'id' => 'd-date', 'name' => 'Date', 'formula' => '[Master/Date]' },
        { 'id' => 'd-ap', 'name' => 'AP %',
          'formula' => 'Sum([Master/On Auto Pay]) / Sum([Master/Total Ledgers])' },
      ],
      'xAxis' => { 'columnId' => 'd-date', 'format' => { 'marks' => 'none' } },
      'yAxis' => { 'columnIds' => ['d-ap'], 'format' => { 'marks' => 'none' } },
      'color' => { 'by' => 'category', 'column' => 'd-ap' },
    }],
  }],
}
qa_errors, = check(bad_color_spec)
ok(qa_errors.any? { |error| error.include?('uses aggregate') && error.include?('category color') },
   'qa-check rejects an aggregate color category even if another builder emitted it')
audit_errors, audit_warnings = check_filter_type_audit(
  'filters' => [{
    'cardId' => 'bad-filter', 'column' => 'Technical Error Type',
    'sourceType' => 'LONG', 'outputTypes' => ['String'], 'status' => 'typed',
  }]
)
ok(audit_errors.any? { |error| error.include?('numeric LONG') && error.include?('string values') },
   'qa-check rejects string literals on a known numeric list filter')
eq(audit_warnings, [], 'known numeric mismatch is an error, not an advisory warning')

puts "== live POP contract: synthetic periods become explicit Sigma measures =="
$chart_helpers = []
pop_month = build_element({
  'id' => '922919965', 'title' => 'Page Views', 'chartType' => 'badge_pop_bar_line',
  'columns' => [
    { 'column' => 'Date', 'mapping' => 'ITEM', 'calendar' => true },
    { 'column' => 'Page Views', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
  ],
  'dateGrain' => { 'column' => 'Period', 'dateTimeElement' => 'DAY' },
  'dateRangeFilter' => {
    'column' => { 'column' => 'Period', 'exprType' => 'COLUMN' },
    'dateTimeRange' => {
      'dateTimeRangeType' => 'INTERVAL_OFFSET', 'interval' => 'MONTH', 'offset' => 1, 'count' => 0,
    },
    'periods' => {
      'type' => 'COMBINED',
      'combined' => [
        { 'interval' => 'MONTH', 'type' => 'OFFSET', 'count' => 1 },
        { 'interval' => 'MONTH', 'type' => 'OFFSET', 'count' => 2 },
      ],
      'count' => 0,
    },
  },
}, {})
eq(pop_month['kind'], 'combo-chart', 'Domo POP bar+line becomes a Sigma combo chart')
eq(pop_month.dig('source', 'kind'), 'union',
   'period helpers are unioned so overlap rows can participate in more than one comparison')
ok(!pop_month['source'].key?('name'),
   'workbook union source omits unsupported name (the server derives its namespace)')
ok(pop_month['columns'].first['formula'].start_with?('[Union of 3 Sources/'),
   'visible columns use the live server-derived union namespace')
eq(pop_month.dig('yAxis', 'columnIds').map { |series| series['type'] }, %w[bar line line],
   'selected period is bars and both comparison periods are lines')
eq(pop_month['columns'].drop(1).map { |column| column['name'] },
   ['1 Month Ago', '2 Months Ago', '3 Months Ago'],
   'all source-declared month periods become explicit measure columns')
eq($chart_helpers.size, 3, 'one hidden helper is emitted for each Domo POP period')
ok($chart_helpers.last['columns'].first['formula'].include?(
     'DateDiff("day", DateAdd("month", -2, DateTrunc("month", DateAdd("month", -1, Today())))'
   ),
   'comparison dates align by source POP_INDEX semantics, not by a guessed calendar color split')
ok(!pop_month.key?('color'), 'POP uses bounded explicit measures, never a high-cardinality color category')

puts "== customer YoY contract: current year bars plus prior-year line =="
$chart_helpers = []
pop_yoy = build_element({
  'id' => 'yoy-current-prior', 'title' => 'YoY', 'chartType' => 'badge_pop_bar_line',
  'columns' => [
    { 'column' => 'CalendarMonth', 'mapping' => 'ITEM', 'calendar' => true },
    { 'column' => 'Revenue', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
  ],
  'dateGrain' => { 'column' => 'Date', 'dateTimeElement' => 'MONTH' },
  'dateRangeFilter' => {
    'column' => { 'column' => 'Date', 'exprType' => 'COLUMN' },
    'dateTimeRange' => {
      'dateTimeRangeType' => 'INTERVAL_OFFSET', 'interval' => 'YEAR', 'offset' => 0, 'count' => 0,
    },
    'periods' => {
      'type' => 'COMBINED',
      'combined' => [{ 'interval' => 'YEAR', 'type' => 'OFFSET', 'count' => 1 }],
      'count' => 0,
    },
  },
}, {})
eq(pop_yoy['columns'].drop(1).map { |column| column['name'] }, ['This Year', '1 Year Ago'],
   'YoY legend exposes the same two periods as the customer screenshot')
eq(pop_yoy.dig('yAxis', 'columnIds').map { |series| series['type'] }, %w[bar line],
   'YoY current period renders as bars and prior year as a line')
ok($chart_helpers.first['columns'].first['formula'].include?('DateDiff("month"'),
   'YoY points align by month before the explicit measures aggregate')

puts "== customer CONSECUTIVE POP supports aggregate Beast Mode values =="
$translated_bms = {
  'calc-90-pct' => {
    'id' => 'calc-90-pct', 'name' => '90+ %', 'class' => 'aggregate',
    'sigmaFormula' => 'Sum([90+]) / Sum([Total])',
  },
}
$chart_helpers = []
consecutive_calc_pop = build_element({
  'id' => 'aged-pop-calc', 'title' => '90+ % YoY', 'chartType' => 'badge_pop_bar_line',
  'columns' => [
    { 'column' => 'CalendarMonth', 'mapping' => 'ITEM', 'calendar' => true },
    { 'column' => '90+ %', 'mapping' => 'VALUE', '_isCalc' => true,
      'beastModeId' => 'calc-90-pct', 'format' => { 'type' => 'percent', 'precision' => 1 } },
    { 'column' => '61-90', 'aggregation' => 'SUM' },
    { 'column' => '31-60', 'aggregation' => 'SUM' },
    { 'column' => '1-30', 'aggregation' => 'COUNT' },
  ],
  'dateGrain' => { 'column' => 'Date', 'dateTimeElement' => 'MONTH' },
  'dateRangeFilter' => {
    'column' => { 'column' => 'Date', 'exprType' => 'COLUMN' },
    'dateTimeRange' => {
      'dateTimeRangeType' => 'INTERVAL_OFFSET', 'interval' => 'YEAR',
      'offset' => 0, 'count' => 0,
    },
    'periods' => {
      'type' => 'COMBINED',
      'combined' => [{ 'type' => 'CONSECUTIVE', 'count' => 1 }],
      'count' => 0,
    },
  },
}, {})
eq(consecutive_calc_pop['kind'], 'combo-chart',
   'CONSECUTIVE prior-year metadata reconstructs a combo instead of generic fallback')
eq(consecutive_calc_pop.dig('yAxis', 'columnIds').map { |series| series['type'] }, %w[bar line],
   'aggregate Beast Mode POP still emits current bars plus one prior-year line')
eq(consecutive_calc_pop['columns'].map { |column| column['name'] },
   ['Date', 'This Year', '1 Year Ago'],
   'blank-mapped support measures never leak into the reconstructed POP legend')
eq($chart_helpers.size, 2, 'CONSECUTIVE count=1 emits current and prior helper tables')
helper_value = $chart_helpers.first['columns'].find { |column| column['id'] == 'd-pop-value' }
eq(helper_value['formula'], 'Sum([Master/90+]) / Sum([Master/Total])',
   'each period helper evaluates the aggregate Beast Mode against its filtered source window')
eq($chart_helpers.first.dig('groupings', 0, 'groupBy'), %w[d-aligned-date d-period-index],
   'period helper groups before union so non-additive ratios emit once per aligned month')
$translated_bms = nil

puts "== POP compare offsets fall back to Domo card-data channels =="
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'parity-expected.json'), JSON.generate(
    'cards' => {
      'pop-card-data' => {
        'columns' => ['Date', 'Revenue', '__domo_period', '__domo_period_index'],
        'mappings' => %w[ITEM VALUE POP_PERIOD POP_INDEX],
        'rows' => [
          ['2026-08-01', 100, 0, 0],
          ['2026-08-02', 110, 0, 1],
          ['2026-07-01', 90, 1, 0],
          ['2026-07-02', 95, 1, 1],
          ['2025-08-01', 80, 2, 0],
          ['2025-08-02', 85, 2, 1],
        ],
      },
    },
  ))
  stub_const(:OUT, dir) do
    $warnings = []
    $chart_helpers = []
    inferred_pop = build_element({
      'id' => 'pop-card-data', 'title' => '1-30 $ YoY', 'chartType' => 'badge_pop_bar_line',
      'columns' => [
        { 'column' => 'Date', 'mapping' => 'ITEM', 'calendar' => true },
        { 'column' => 'Revenue', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
      ],
      'dateGrain' => { 'column' => 'Date', 'dateTimeElement' => 'DAY' },
      'dateRangeFilter' => {
        'column' => { 'column' => 'Date' },
        'dateTimeRange' => {
          'dateTimeRangeType' => 'INTERVAL_OFFSET', 'interval' => 'MONTH',
          'offset' => 1, 'count' => 0,
        },
      },
    }, {})
    ok(!inferred_pop.nil?, 'missing dateRangeFilter.periods no longer skips a card with POP card-data')
    eq(inferred_pop['columns'].drop(1).map { |column| column['name'] },
       ['1 Month Ago', '2 Months Ago', '1 Year Ago'],
       'POP_PERIOD starts infer month and year comparisons in source order')
    eq(inferred_pop.dig('yAxis', 'columnIds').map { |series| series['type'] },
       %w[bar line line], 'inferred current period is bars and comparisons are lines')
    ok($warnings.any? { |warning| warning['warning'].include?('POP_PERIOD/POP_INDEX') },
       'card-data reconstruction is auditable, not silent')
  end
end

puts "== explicit POP charts may carry more than two period measures =="
$warnings = []
four_measure_pop = build_element({
  'id' => 'pop-four-measures', 'title' => '61-90 $ YoY', 'chartType' => 'badge_pop_bar_line',
  'columns' => [
    { 'column' => 'Month', 'mapping' => 'ITEM' },
    { 'column' => 'Current', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
    { 'column' => 'Prior 1', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => 'Prior 2', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
    { 'column' => 'Prior 3', 'aggregation' => 'SUM', 'mapping' => 'SERIES' },
  ],
  'dateGrain' => { 'column' => 'Period', 'dateTimeElement' => 'MONTH' },
  'dateRangeFilter' => {
    'column' => { 'column' => 'Period' },
    'dateTimeRange' => {
      'dateTimeRangeType' => 'INTERVAL_OFFSET', 'interval' => 'YEAR',
      'offset' => 0, 'count' => 0,
    },
  },
}, {})
eq(four_measure_pop.dig('yAxis', 'columnIds').map { |series| series['type'] },
   %w[bar line line line], 'one current plus three prior measures is a valid POP combo')
ok(!$warnings.any? { |warning| warning['warning'].include?('expected a bar measure') },
   'valid four-period POP chart no longer emits a false expected-two warning')
ok(four_measure_pop['filters'].any? { |filter| filter['columnId'] == 'f-datewin-period-year-offset-0' },
   'authored multi-measure POP shape with no synthetic periods keeps its selected-year filter')
ok(!$warnings.any? { |warning| warning['warning'].include?('date window NOT applied') },
   'ordinary authored series do not trigger the synthetic-period date-window refusal')

puts "== live no-comparison POP shape remains an honest selected-period chart =="
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'parity-expected.json'), JSON.generate(
    'cards' => {
      'pop-missing-periods' => {
        'columns' => %w[Date Revenue], 'mappings' => %w[ITEM VALUE],
        'rows' => [['2026-01-01', 100]],
      },
    },
  ))
  $warnings = []
  unresolved_pop = nil
  stub_const(:OUT, dir) do
    unresolved_pop = build_element({
      'id' => 'pop-missing-periods', 'title' => 'Broken YoY', 'chartType' => 'badge_pop_bar_line',
      '_popComparisonProbe' => 'public-no-periods',
      'columns' => [
        { 'column' => 'Date', 'mapping' => 'ITEM' },
        { 'column' => 'Revenue', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
      ],
      'dateGrain' => { 'column' => 'Period', 'dateTimeElement' => 'MONTH' },
      'dateRangeFilter' => {
        'column' => { 'column' => 'Period' },
        'dateTimeRange' => {
          'dateTimeRangeType' => 'INTERVAL_OFFSET', 'interval' => 'YEAR',
          'offset' => 0, 'count' => 0,
        },
      },
    }, {})
  end
  eq(unresolved_pop['kind'], 'bar-chart',
     'POP token with card-data proof of no comparison preserves its one authored series as a bar')
  eq(unresolved_pop.dig('yAxis', 'columnIds').size, 1,
     'fallback exposes exactly one series and cannot masquerade as a comparison')
  ok(unresolved_pop['filters'].any? { |filter| filter['columnId'] == 'f-datewin-period-year-offset-0' },
     'fallback applies the selected Domo year instead of aggregating all history')
  ok($warnings.any? { |warning| warning['warning'].include?('does not claim a period-over-period comparison') },
     'warning distinguishes absent source comparison semantics from a conversion failure')
  ok(!$warnings.any? { |warning| warning['warning'].include?('SKIPPED') },
     'a source-valid no-comparison card is not dropped from the workbook')
end

puts "== unresolved one-measure POP never erases a comparison visible in Analyzer =="
$warnings = []
unknown_pop = build_element({
  'id' => 'pop-unknown-comparison', 'title' => '1-30 $ YoY', 'chartType' => 'badge_pop_bar_line',
  'columns' => [
    { 'column' => 'Date', 'mapping' => 'ITEM' },
    { 'column' => '1-30', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
  ],
}, {})
ok(unknown_pop.nil?,
   'one authored measure without a successful public/card-data probe remains unresolved')
ok($warnings.any? { |warning| warning['warning'].include?('Analyzer/render may still derive bars plus a line') },
   'warning captures the customer-observed hidden-comparison shape')

puts "== explicit current/prior Beast Modes remain a deterministic POP fallback =="
$translated_bms = {
  'calc-current' => {
    'id' => 'calc-current', 'name' => 'Current', 'class' => 'aggregate',
    'sigmaFormula' => 'Sum(If([Is Current] = "Yes", [Revenue], 0))',
  },
  'calc-prior' => {
    'id' => 'calc-prior', 'name' => 'Prior', 'class' => 'aggregate',
    'sigmaFormula' => 'Sum(If([Is Prior] = "Yes", [Revenue], 0))',
  },
}
explicit_pop = build_element({
  'id' => 'pop-explicit', 'title' => 'Explicit YoY', 'chartType' => 'badge_pop_bar_line',
  'columns' => [
    { 'column' => 'Month', 'mapping' => 'ITEM' },
    { 'column' => 'Current', 'beastModeId' => 'calc-current', '_isCalc' => true, 'mapping' => 'SERIES' },
    { 'column' => 'Prior', 'beastModeId' => 'calc-prior', '_isCalc' => true, 'mapping' => 'SERIES' },
  ],
}, {})
eq(explicit_pop.dig('yAxis', 'columnIds').size, 2,
   'two explicit aggregate Beast Modes become two comparison measures')
ok(!explicit_pop.key?('color'), 'explicit period measures never become categorical colors')
$translated_bms = nil

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
eq(scatter.dig('size', 'columnId'), 's-clicks', 'BUBBLESIZE binds size without a duplicate export column')
eq(scatter['color'], { 'by' => 'category', 'column' => 's-subject' }, 'SERIES identifies each point')
helper = $chart_helpers.last
eq(scatter['source'], { 'kind' => 'table', 'elementId' => helper['id'],
                        'groupingId' => helper['groupings'].first['id'] },
   'scatter binds to an explicit hidden grouping')
eq(helper['groupings'].first['groupBy'], ['d-subject'], 'helper groups to one point per Subject')
eq(helper['groupings'].first['calculations'], %w[m-delivered m-opens m-clicks],
   'helper pre-aggregates every scatter measure')
eq(helper['filters'].first['rowCount'], 10, 'source top-N is enforced on the grouped helper')

puts "== numeric Domo EXCLUDES values are typed from dataset schema =="
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    {
      'id' => 'ds-errors',
      'schema' => { 'columns' => [
        { 'name' => 'Video Queue', 'type' => 'STRING' },
        { 'name' => 'Abandon Rate', 'type' => 'DOUBLE' },
        { 'name' => 'Technical Error Type', 'type' => 'LONG' },
      ] },
    },
  ]))
  stub_const(:OUT, dir) do
    $dataset_schema_by_id = nil
    $filter_type_audit = []
    numeric_exclude = build_element({
      'id' => 'c-numeric-exclude', 'title' => 'Average Abandon Rate',
      'chartType' => 'badge_table', 'datasetId' => 'ds-errors',
      'columns' => [
        { 'column' => 'Video Queue', 'mapping' => 'ITEM' },
        { 'column' => 'Abandon Rate', 'aggregation' => 'AVG', 'mapping' => 'VALUE' },
      ],
      'filters' => [{
        'column' => 'Technical Error Type',
        'operator' => 'NOT_IN',
        'values' => ['-3'],
      }],
    }, {})
    filter = Array(numeric_exclude['filters']).find { |item| item['mode'] == 'exclude' }
    eq(filter['values'], [-3], 'LONG exclude literal is emitted as JSON number -3, not string "-3"')
    eq($filter_type_audit.first['sourceType'], 'LONG', 'typing audit records source schema evidence')
    eq($filter_type_audit.first['outputTypes'], ['Integer'], 'typing audit records numeric output')

    string_card = {
      'id' => 'c-string-code', 'datasetId' => 'ds-errors',
      'filters' => [{ 'column' => 'Video Queue', 'values' => ['-3'] }],
    }
    values, error, = coerce_filter_values(string_card, 'Video Queue', ['-3'])
    eq(error, nil, 'string code coercion succeeds')
    eq(values, ['-3'], 'numeric-looking STRING values stay strings')
  end
end

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

puts "== classic-page collections become real workbook section text =="
Dir.mktmpdir do |dir|
  cards = [
    { 'id' => 'c', '_pageOrder' => 2, '_collection' => { 'id' => 2, 'title' => 'Second' } },
    { 'id' => 'a', '_pageOrder' => 0, '_collection' => { 'id' => 1, 'title' => 'First' } },
    { 'id' => 'b', '_pageOrder' => 1, '_collection' => { 'id' => 1, 'title' => 'First' } },
  ]
  stub_const(:OUT, dir) do
    section_els = collection_section_elements(cards)
    eq(section_els.map { |element| element['id'] }, %w[text-collection-1 text-collection-2],
       'collection text ids use the shared layout builder text-<zone-id> contract')
    eq(section_els.map { |element| element['name'] }, %w[First Second],
       'collection headings follow source page order')
    eq(section_els.map { |element| element['body'] }, ['### First', '### Second'],
       'every classic-page collection is visible in the workbook')

    File.write(File.join(dir, 'layout-observed.json'), '{}')
    eq(collection_section_elements(cards), [],
       'screenshot-observed sections replace collection headings rather than duplicating them')
  end
end

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
    title = observed_page_title_element('Observed Dashboard')
    eq(title['id'], 'title-observed-dashboard',
       'screenshot-backed page title gets a stable layout-resolvable id')
    eq(title['body'], '## Observed Dashboard',
       'screenshot-backed page title reproduces the Domo page title')
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
      'dateRangeFilter' => {
        'column' => { 'column' => 'Activity Date' },
        'dateTimeRange' => {
          'dateTimeRangeType' => 'ROLLING_PERIOD', 'interval' => 'DAY', 'offset' => 0, 'count' => 14,
        },
      },
      'columns' => [
        { 'column' => 'Activity Date', 'mapping' => 'DATE' },
        { 'column' => 'Description', 'mapping' => 'EVENT' },
      ],
      'quickFilters' => [{
        'name' => 'Description', 'column' => 'Description',
        'displayType' => 'multiple_select', 'operator' => 'IN', 'values' => [],
      }],
    }, {})
    eq(calendar['pluginId'], 'calendar-test-id',
       'calendar card reuses the proven live calendar registration')
    eq(calendar.dig('config', 'dateColumn'),
       { 'kind' => 'column', 'columnId' => 'd-label', 'source' => 'source' },
       'calendar date uses the working plugin column config shape')
    eq(calendar.dig('config', 'valueColumn'),
       { 'kind' => 'column', 'columnId' => 'm-value', 'source' => 'source' },
       'calendar value uses the working plugin column config shape')
    ok(!calendar.key?('_filterHelper') &&
       $chart_helpers.none? { |helper| helper['id'].to_s.include?('c52') },
       'pluginized calendar never leaks a table filter helper')
    ok($card_controls.none? { |control| control['name'] == 'Description' },
       'pluginized calendar Quick Filter is deferred rather than wired to the wrong source')
    calendar_coverage = control_coverage_for([{
      'id' => 'c52', 'title' => 'Activity Calendar', 'chartType' => 'badge_calendar',
      'sigmaKindHint' => 'table',
      'dateRangeFilter' => {
        'column' => { 'column' => 'Activity Date' }, 'dateTimeRange' => {},
      },
      'quickFilters' => [{ 'name' => 'Description', 'column' => 'Description' }],
    }])
    eq(calendar_coverage.map { |row| row['status'] }, %w[deferred deferred],
       'pluginized calendar Quick Filter and date selector are recorded as deferred, not dropped')
    calendar_scope = control_scope_document(calendar_coverage)
    eq(calendar_scope['controls'].select { |row| row['status'] == 'needs-wiring' }
                                 .map { |row| row['name'] },
       %w[Description Date],
       'deferred plugin controls are declared to the shared control gate with evidence')
    eq(calendar_scope['dropped'].map { |row| row['name'] }, %w[Description Date],
       'deferred plugin controls are visible to degradation reporting')

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
