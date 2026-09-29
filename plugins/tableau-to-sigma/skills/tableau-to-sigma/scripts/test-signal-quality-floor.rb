#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the v5.4.9 review fixes (grammar-level, zero fixture
# knowledge):
#
#   1. LAST-RESORT QUALITY FLOOR — the name-keyed header recovery must never
#      emit a field without a column definition in columns_by_guid, never a
#      Tableau pseudo-field ('Multiple Values', the multi-pill placeholder
#      caption), and never promote a role=dimension / non-numeric calc to a
#      Sum() measure. A rejected zone falls back to the OLD behavior: dropped
#      with a loud ZONE DROPPED warning — a warned drop, never a hard exit-4
#      ref-gate stop.
#   2. ROW COUNTS ARE DATA — SUM([Number of Records]) (formula literal '1')
#      on a KPI shelf is the headline row count, not an axis-anchor
#      placeholder; the KPI must bind it, not a secondary marks-card measure.
#   3. DONUT NEEDS THE STACKED DUAL AXIS — a pie on a SINGLE constant-
#      aggregate dummy axis is a positioned pie (stays pie-chart); only the
#      multi-instance '+' shelf (two stacked constant pies) is the donut idiom.
#   4. DATE PARAM SCOPE FAILS CLOSED — a KPI scoped by <col> = [Parameters].[P]
#      where P is a DATE param must go STAYS-MANUAL (a pinned '#…#' literal
#      matches no date value; a named gap beats a silently blank number).
#
# Usage: ruby scripts/test-signal-quality-floor.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

FED = '[federated.fact]'

# Z1: dataless multi-pill zone — the shelf parser mangles the multi-pill rows
# expression into a pseudo-dim guid 'Multiple Values' (no column def exists).
z_pill = {
  'id' => '1', 'kind' => 'chart', 'caption' => 'Pill Zone', 'chart_kind' => 'bar',
  'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 30.0, 'h_pct' => 20.0,
  'rows_shelf' => { 'raw' => "(#{FED}.[usr:CalcA:qk] / #{FED}.[usr:CalcB:qk])",
                    'fields' => [{ 'guid' => nil, 'role' => 'measure', 'derivation' => 'usr' },
                                 { 'guid' => 'Multiple Values', 'role' => 'dim', 'derivation' => nil }],
                    'dim_count' => 1, 'measure_count' => 1 },
  'cols_shelf' => {},
  'channels' => { 'color' => { 'column' => "#{FED}.[none:CATEGORY_SEL:nk]" } },
  'aggregations' => { '[CATEGORY_SEL]' => 'Sum' }
}
# Z2: KPI — SUM([Number of Records]) on the shelf + a secondary marks measure.
z_kpi = {
  'id' => '2', 'kind' => 'chart', 'caption' => 'Total Orders', 'chart_kind' => 'kpi',
  'x_pct' => 40.0, 'y_pct' => 0.0, 'w_pct' => 20.0, 'h_pct' => 10.0,
  'rows_shelf' => { 'raw' => "#{FED}.[sum:Number of Records:qk]",
                    'fields' => [{ 'guid' => 'Number of Records', 'role' => 'measure', 'derivation' => 'sum' }] },
  'cols_shelf' => {},
  'measures' => [{ 'column' => '[sum:Number of Records:qk]', 'derivation' => 'Sum' },
                 { 'column' => '[usr:CalcShare:qk]', 'derivation' => 'User' }],
  'calculations' => [{ 'name' => '[CalcShare]', 'caption' => 'Profit Share', 'datatype' => 'real',
                       'role' => 'measure', 'class' => 'tableau', 'formula' => 'SUM([PROFIT])/SUM([SALES])' }],
  'aggregations' => { '[Number of Records]' => 'Sum' }
}
# Z3: pie on ONE constant anchor — positioned pie, not a donut.
z_pie = {
  'id' => '3', 'kind' => 'chart', 'caption' => 'Category Pie', 'chart_kind' => 'pie',
  'x_pct' => 0.0, 'y_pct' => 30.0, 'w_pct' => 30.0, 'h_pct' => 30.0,
  'rows_shelf' => { 'raw' => "#{FED}.[avg:CalcAnchor:qk]",
                    'fields' => [{ 'guid' => 'CalcAnchor', 'role' => 'measure', 'derivation' => 'avg' }],
                    'measure_count' => 1 },
  'cols_shelf' => { 'fields' => [{ 'guid' => 'CATEGORY', 'role' => 'dim', 'derivation' => 'none' }],
                    'dim_count' => 1 },
  'channels' => { 'color' => { 'column' => "#{FED}.[none:CATEGORY:nk]" } },
  'aggregations' => { '[CATEGORY]' => 'None', '[SALES]' => 'Sum' }
}
# Z4: the genuine donut idiom — two stacked constant pies on a '+' dual axis.
z_donut = JSON.parse(JSON.generate(z_pie)).merge(
  'id' => '4', 'caption' => 'Share Donut', 'x_pct' => 40.0,
  'rows_shelf' => { 'raw' => "(#{FED}.[avg:CalcAnchor:qk] + #{FED}.[avg:CalcAnchor2:qk])",
                    'fields' => [{ 'guid' => 'CalcAnchor', 'role' => 'measure', 'derivation' => 'avg' },
                                 { 'guid' => 'CalcAnchor2', 'role' => 'measure', 'derivation' => 'avg' }],
                    'measure_count' => 2 })
# Z5: KPI scoped by a DATE param equality — must fail closed (STAYS-MANUAL).
z_date = {
  'id' => '5', 'kind' => 'chart', 'caption' => 'Revenue KPI', 'chart_kind' => 'kpi',
  'x_pct' => 70.0, 'y_pct' => 0.0, 'w_pct' => 20.0, 'h_pct' => 10.0,
  'rows_shelf' => { 'raw' => "#{FED}.[sum:REVENUE:qk]",
                    'fields' => [{ 'guid' => 'REVENUE', 'role' => 'measure', 'derivation' => 'sum' }] },
  'cols_shelf' => {},
  'measures' => [{ 'column' => '[sum:REVENUE:qk]', 'derivation' => 'Sum' }],
  'calculations' => [{ 'name' => '[CalcAsOf]', 'caption' => 'As Of Filter', 'datatype' => 'boolean',
                       'role' => 'dimension', 'class' => 'tableau',
                       'formula' => '[AS_OF_DATE] = [Parameters].[As of Date]' }],
  'filters' => [{ 'kind' => 'list', 'members' => ['true'], 'column_caption' => 'As Of Filter' }],
  'aggregations' => { '[REVENUE]' => 'Sum' }
}
# Z6: signal-only line with a Color shelf not present in the synthetic
# dim+measure headers. The .twb channel must still become a Sigma series.
z_series = {
  'id' => '6', 'kind' => 'chart', 'caption' => 'Sales by Category', 'chart_kind' => 'line',
  'x_pct' => 0.0, 'y_pct' => 65.0, 'w_pct' => 45.0, 'h_pct' => 25.0,
  'rows_shelf' => { 'raw' => "#{FED}.[sum:SALES:qk]",
                    'fields' => [{ 'guid' => 'SALES', 'role' => 'measure', 'derivation' => 'sum' }],
                    'measure_count' => 1 },
  'cols_shelf' => { 'raw' => "#{FED}.[none:AS_OF_DATE:nk]",
                    'fields' => [{ 'guid' => 'AS_OF_DATE', 'role' => 'dim', 'derivation' => 'none' }],
                    'dim_count' => 1 },
  'channels' => { 'color' => { 'column' => "#{FED}.[none:CATEGORY:nk]" } },
  'measures' => [{ 'column' => '[SALES]', 'derivation' => 'Sum' }],
  'aggregations' => { '[SALES]' => 'Sum', '[AS_OF_DATE]' => 'None', '[CATEGORY]' => 'None' },
  'filters' => []
}
z_ramp = JSON.parse(JSON.generate(z_series)).merge(
  'id' => '7', 'caption' => 'Sales Heat', 'x_pct' => 50.0,
  'channels' => { 'color' => { 'column' => "#{FED}.[sum:PROFIT:qk]" } }
)

layout = [{ 'dashboard' => 'Dash', 'is_story' => false, 'canvas_px' => { 'w' => 1200, 'h' => 800 },
            'zones' => [z_pill, z_kpi, z_pie, z_donut, z_date, z_series, z_ramp] }]
meta = {
  'worksheets' => {}, 'stories' => [], 'shared_filters' => [], 'column_aliases' => {},
  'parameters' => [{ 'name' => '[As of Date]', 'caption' => 'As of Date', 'datatype' => 'date',
                     'param_domain' => 'list', 'default_value' => '#2026-06-30#', 'members' => [] }],
  'columns_by_guid' => {
    'Number of Records' => { 'caption' => 'Number of Records', 'datatype' => 'integer', 'formula' => '1' },
    'PROFIT' => { 'caption' => 'Profit', 'datatype' => 'real' },
    'SALES' => { 'caption' => 'Sales', 'datatype' => 'real' },
    'REVENUE' => { 'caption' => 'Revenue', 'datatype' => 'real' },
    'AS_OF_DATE' => { 'caption' => 'As Of Date', 'datatype' => 'date' },
    'CATEGORY' => { 'caption' => 'Category', 'datatype' => 'string', 'role' => 'dimension' },
    'CalcAnchor' => { 'caption' => 'Pie Anchor', 'datatype' => 'real', 'formula' => 'AVG(0)' },
    'CalcAnchor2' => { 'caption' => 'Pie Anchor 2', 'datatype' => 'real', 'formula' => 'AVG(0)' },
    'CalcShare' => { 'caption' => 'Profit Share', 'datatype' => 'real', 'formula' => 'SUM([PROFIT])/SUM([SALES])' },
    # role=dimension boolean calc — the promotion floor must refuse Sum() over it
    'CATEGORY_SEL' => { 'caption' => 'Category Selector', 'datatype' => 'boolean', 'role' => 'dimension',
                       'formula' => '[CATEGORY] = [Parameters].[Category Parameter]' }
  }
}
pre = '(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of |(?:avg|sum|min|max|med|cnt|ctd)\\.\\s*|(?:second|minute|hour|day|week|month|quarter|year) of )?'
mmap = {}
{ 'Number\\ of\\ Records' => %w[m-numrec], 'Profit' => %w[m-profit], 'Sales' => %w[m-sales],
  'Revenue' => %w[m-revenue], 'As\\ Of\\ Date' => %w[m-asof], 'Category' => %w[m-category] }.each do |k, (id)|
  mmap[pre + k + '$'] = { 'id' => id, 'name' => k.gsub('\\ ', ' ') }
end

els = []
data_els = []
log = ''
raw = {}
Dir.mktmpdir do |d|
  File.write(File.join(d, 'layout.json'), JSON.pretty_generate(layout))
  File.write(File.join(d, 'layout-meta.json'), JSON.pretty_generate(meta))
  File.write(File.join(d, 'master-map.json'), JSON.pretty_generate(mmap))
  File.write(File.join(d, 'get-workbook.json'), JSON.pretty_generate('workbook' => { 'views' => { 'view' => [] } }))
  out = File.join(d, 'chart-specs.json')
  o2, e2, st = Open3.capture3(RbConfig.ruby, BUILD, '--tableau-dir', d,
                              '--layout', File.join(d, 'layout.json'),
                              '--meta', File.join(d, 'layout-meta.json'),
                              '--master-map', File.join(d, 'master-map.json'),
                              '--skip-dashboard-read', 'unit-test',
                              '--page-per-dashboard',
                              '--out', out)
  log = o2 + e2
  check(st.success?, "build-charts exits 0 (got #{st.exitstatus}: #{e2.lines.first})", fails)
  raw = JSON.parse(File.read(out)) rescue {}
  els = (raw['pages'] || []).flat_map { |p| p['elements'] || [] }
  data_els = raw['data_elements'] || []
end
blob = JSON.generate(raw)

puts 'last-resort quality floor'
check(!blob.include?('Master/Multiple Values'),
      "no [Master/Multiple Values] ref anywhere (pseudo-field rejected)", fails)
check(!blob.include?('Master/Category Selector'),
      'role=dimension boolean calc never promoted to a measure ref', fails)
check(els.none? { |e| e['name'].to_s == 'Pill Zone' },
      'floor-rejected zone is DROPPED (old behavior), not emitted broken', fails)
check(log =~ /ZONE DROPPED: 'Pill Zone'/, 'drop is LOUD (ZONE DROPPED warning names the zone)', fails)

puts 'row counts are data'
# kpi-chart elements carry `name` as the house-standard object form
# {'text'=>...} (KpiCard.build); every other kind still carries a plain
# String. Accept both so this name-based lookup doesn't break on the shape.
name_of = ->(e) { n = e && e['name']; n.is_a?(Hash) ? n['text'] : n }
kpi = els.find { |e| e['kind'] == 'kpi-chart' && name_of.call(e) == 'Total Orders' }
kcol = kpi && (kpi['columns'] || []).first
check(kcol && kcol['formula'] == 'Sum([Master/Number of Records])',
      "row-count KPI binds Sum([Master/Number of Records]) (got #{kcol && kcol['formula']})", fails)

puts 'signal-only categorical color shelf'
series = els.find { |e| e['name'].to_s == 'Sales by Category' }
color_id = series && series.dig('color', 'column')
color_col = series && Array(series['columns']).find { |column| column['id'] == color_id }
check(color_col && color_col['name'] == 'Category',
      "Color shelf becomes a categorical Sigma series column (got #{color_col.inspect})", fails)
check(log.include?("recovered Color shelf 'Category' from .twb signals"),
      'signal-only color recovery is stated in the build log', fails)
ramp = els.find { |e| e['name'].to_s == 'Sales Heat' }
check(ramp && ramp.dig('color', 'by') == 'scale',
      "continuous measure Color shelf remains a scale, not a series (got #{ramp && ramp['color']})", fails)
check(ramp && Array(ramp['columns']).any? { |column| column['id'].to_s.start_with?('clr-') },
      'continuous Color shelf uses a duplicate measure column', fails)

puts 'donut discriminator needs the stacked dual axis'
pie = els.find { |e| e['name'].to_s == 'Category Pie' }
check(pie && pie['kind'] == 'pie-chart',
      "single-anchor positioned pie stays pie-chart (got #{pie && pie['kind']})", fails)
donut = els.find { |e| e['name'].to_s == 'Share Donut' }
check(donut && donut['kind'] == 'donut-chart',
      "stacked dual-anchor pie is the donut idiom (got #{donut && donut['kind']})", fails)

puts 'date param scope fails closed'
check(log =~ /'Revenue KPI' KPI is parameter-scoped but its scope did not resolve/,
      'date-param scope goes STAYS-MANUAL', fails)
check(!blob.include?('#2026-06-30#'),
      "no '#…#' date literal is ever pinned into a filter", fails)
check(data_els.none? { |e| e['id'].to_s.include?('kpi-revenue-kpi-scoped') },
      'no helper built for the unresolvable date scope', fails)

if fails.empty?
  puts 'test-signal-quality-floor: ALL PASS'
else
  puts "test-signal-quality-floor: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
