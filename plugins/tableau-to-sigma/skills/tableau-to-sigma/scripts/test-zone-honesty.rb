#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the v5.4 zone-honesty wave. Grammar patterns locked:
#
#   1. DONUT discovery: Tableau has no donut mark — a donut serializes as a
#      Pie mark whose rows/cols shelf carries ONLY constant-aggregate
#      placeholder instances (dual AVG(0) dummy axes) with the slice dim on
#      the Color channel and the angle measure on the marks card. Must emit a
#      donut-chart element, never drop the zone. A plain pie stays pie-chart.
#   2. NAME-KEYED workbooks: textscan/excel-direct datasources key column
#      instances by NAME ([none:IS_PAID:nk]), not hex GUID — the last-resort
#      synthesis must recover the color dim + aggregation measure for zones
#      that would otherwise drop, WITHOUT touching zones that already build.
#   3. Unsupported-mark honesty: a NAMED mark class with no Sigma equivalent
#      (GanttBar, VizExtension, …) is a LOUD named handoff — never silently
#      mis-built as a bar chart. A BLANK mark keeps the bar fallback, loudly.
#   4. Data-page topo order: build_wb_spec emits SOURCE-BEFORE-CONSUMER (a
#      helper sourcing a sub-master must follow it in document order).
#
# Usage: ruby scripts/test-zone-honesty.rb
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
base_zone = {
  'kind' => 'chart', 'view_ref' => nil, 'x_pct' => 0.0, 'y_pct' => 0.0,
  'w_pct' => 25.0, 'h_pct' => 25.0, 'chart_kind_inferred' => false,
  'sort' => nil, 'shelf_sorts' => [], 'quick_calc_pcto' => [], 'filters' => [],
  'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'calculations' => [],
  'dual_axis' => false, 'measures' => [], 'ref_marks' => [], 'axis_formats' => [],
  'mark_labels_show' => false, 'is_crosstab' => false, 'is_kpi' => false,
  'rows_shelf' => { 'raw' => nil, 'fields' => [], 'dim_count' => 0, 'measure_count' => 0,
                    'cont_measure_count' => 0, 'has_measure_names' => false, 'has_measure_values' => false },
  'cols_shelf' => { 'raw' => nil, 'fields' => [], 'dim_count' => 0, 'measure_count' => 0,
                    'cont_measure_count' => 0, 'has_measure_names' => false, 'has_measure_values' => false }
}

donut = JSON.parse(JSON.generate(base_zone)).merge(
  'id' => '1', 'caption' => 'Paid Split', 'chart_kind' => 'pie', 'mark_class' => 'Pie',
  'aggregations' => { '[IS_PAID]' => 'None', '[NUM_ENROLLED]' => 'Sum', '[CalcA]' => 'User' },
  'channels' => { 'color' => { 'column' => "#{FED}.[none:IS_PAID:nk]", 'field' => nil } },
  'calculations' => [
    { 'name' => '[CalcA]', 'caption' => 'AVG(0)', 'datatype' => 'real', 'role' => 'measure',
      'class' => 'tableau', 'formula' => 'AVG(0)' }
  ])
donut['rows_shelf'] = {
  'raw' => "(#{FED}.[usr:CalcA:qk] + #{FED}.[usr:CalcA:qk:1])",
  'fields' => [{ 'raw' => "#{FED}.[usr:CalcA:qk] + #{FED}.[usr:CalcA:qk:1]",
                 'role' => 'measure', 'derivation' => 'usr', 'discrete' => false, 'guid' => 'CalcA' }],
  'dim_count' => 0, 'measure_count' => 1, 'cont_measure_count' => 1,
  'has_measure_names' => false, 'has_measure_values' => false
}

plain_pie = JSON.parse(JSON.generate(base_zone)).merge(
  'id' => '2', 'caption' => 'Plain Pie', 'chart_kind' => 'pie', 'mark_class' => 'Pie', 'x_pct' => 30.0,
  'aggregations' => { '[Segment]' => 'None', '[Sales]' => 'Sum' })
plain_pie['rows_shelf'] = {
  'raw' => "#{FED}.[sum:Sales:qk]",
  'fields' => [{ 'raw' => "#{FED}.[sum:Sales:qk]", 'role' => 'measure', 'derivation' => 'sum',
                 'discrete' => false, 'guid' => 'Sales' }],
  'dim_count' => 0, 'measure_count' => 1, 'cont_measure_count' => 1,
  'has_measure_names' => false, 'has_measure_values' => false
}
plain_pie['cols_shelf'] = {
  'raw' => "#{FED}.[none:Segment:nk]",
  'fields' => [{ 'raw' => "#{FED}.[none:Segment:nk]", 'role' => 'dim', 'derivation' => 'none',
                 'guid' => 'Segment' }],
  'dim_count' => 1, 'measure_count' => 0, 'cont_measure_count' => 0,
  'has_measure_names' => false, 'has_measure_values' => false
}

gantt = JSON.parse(JSON.generate(base_zone)).merge(
  'id' => '3', 'caption' => 'Level Strip', 'chart_kind' => 'other', 'mark_class' => 'GanttBar', 'y_pct' => 30.0)
gantt['rows_shelf'] = {
  'raw' => "#{FED}.[sum:VAL:qk]",
  'fields' => [{ 'raw' => "#{FED}.[sum:VAL:qk]", 'role' => 'measure',
                 'derivation' => 'sum', 'discrete' => false, 'guid' => 'VAL' }],
  'dim_count' => 0, 'measure_count' => 1, 'cont_measure_count' => 1,
  'has_measure_names' => false, 'has_measure_values' => false
}

# KPI-adjacent sparkline: dual-instance measure shelf — full trend + a
# conditional current-period highlight. Must plot the FULL series.
spark = JSON.parse(JSON.generate(base_zone)).merge(
  'id' => '4', 'caption' => 'Trend Mini', 'chart_kind' => 'area', 'mark_class' => 'Area', 'y_pct' => 60.0,
  'aggregations' => { '[VAL]' => 'Sum', '[CalcHL]' => 'Sum', '[PUBDATE]' => 'Month-Trunc' },
  'measures' => [{ 'column' => '[CalcHL]', 'derivation' => 'Sum' }, { 'column' => '[VAL]', 'derivation' => 'Sum' }],
  'calculations' => [
    { 'name' => '[CalcHL]', 'caption' => 'CY Val 4 Area', 'datatype' => 'integer', 'role' => 'measure',
      'class' => 'tableau', 'formula' => 'IF [SomeBool] = TRUE Then [VAL] END' }
  ])
spark['rows_shelf'] = {
  'raw' => "(#{FED}.[sum:VAL:qk] + #{FED}.[sum:CalcHL:qk])",
  'fields' => [{ 'raw' => "#{FED}.[sum:VAL:qk] + #{FED}.[sum:CalcHL:qk]",
                 'role' => 'measure', 'derivation' => 'sum', 'discrete' => false, 'guid' => 'CalcHL' }],
  'dim_count' => 0, 'measure_count' => 1, 'cont_measure_count' => 1,
  'has_measure_names' => false, 'has_measure_values' => false
}
spark['cols_shelf'] = {
  'raw' => "#{FED}.[tmn:PUBDATE:qk]",
  'fields' => [{ 'raw' => "#{FED}.[tmn:PUBDATE:qk]", 'role' => 'dim', 'derivation' => 'tmn', 'guid' => 'PUBDATE' }],
  'dim_count' => 1, 'measure_count' => 0, 'cont_measure_count' => 0,
  'has_measure_names' => false, 'has_measure_values' => false
}

layout = [{ 'dashboard' => 'Dash', 'is_story' => false, 'zones' => [donut, plain_pie, gantt, spark] }]
meta = {
  'worksheets' => {}, 'stories' => [], 'shared_filters' => [], 'parameters' => [], 'column_aliases' => {},
  'columns_by_guid' => {
    'CalcA'   => { 'caption' => 'AVG(0)', 'formula' => 'AVG(0)' },
    'IS_PAID' => { 'caption' => 'Is Paid' },
    'NUM_ENROLLED' => { 'caption' => 'Num Enrolled' },
    'Segment' => { 'caption' => 'Segment' }, 'Sales' => { 'caption' => 'Sales' },
    'CalcHL'  => { 'caption' => 'CY Val 4 Area', 'formula' => 'IF [SomeBool] = TRUE Then [VAL] END' },
    'VAL'     => { 'caption' => 'Val' }, 'PUBDATE' => { 'caption' => 'Pub Date' }
  }
}
mmap = {
  '(?i)^Is Paid$' => { 'id' => 'm-paid', 'name' => 'Is Paid' },
  '(?i)^Num Enrolled$' => { 'id' => 'm-subs', 'name' => 'Num Enrolled' },
  '(?i)^Segment$' => { 'id' => 'm-seg', 'name' => 'Segment' },
  '(?i)^Sales$' => { 'id' => 'm-sales', 'name' => 'Sales' },
  '(?i)^Val$' => { 'id' => 'm-val', 'name' => 'Val' },
  '(?i)^(?:Month of )?Pub Date$' => { 'id' => 'm-pd', 'name' => 'Pub Date' }
}

els = []
log = ''
Dir.mktmpdir do |d|
  File.write(File.join(d, 'layout.json'), JSON.pretty_generate(layout))
  File.write(File.join(d, 'layout-meta.json'), JSON.pretty_generate(meta))
  File.write(File.join(d, 'master-map.json'), JSON.pretty_generate(mmap))
  File.write(File.join(d, 'get-workbook.json'), JSON.pretty_generate('workbook' => { 'views' => { 'view' => [] } }))
  out = File.join(d, 'chart-specs.json')
  o, e, st = Open3.capture3(RbConfig.ruby, BUILD, '--tableau-dir', d,
                            '--layout', File.join(d, 'layout.json'),
                            '--meta', File.join(d, 'layout-meta.json'),
                            '--master-map', File.join(d, 'master-map.json'),
                            '--skip-dashboard-read', 'unit-test',
                            '--page-per-dashboard', '--out', out)
  log = o + e
  check(st.success?, "build-charts exits 0 (got #{st.exitstatus}: #{e.lines.first})", fails)
  raw = JSON.parse(File.read(out)) rescue {}
  els = (raw['pages'] || []).flat_map { |p| p['elements'] || [] }
end

puts 'donut discovery (constant dummy axes + color-channel dim, name-keyed)'
de = els.find { |e| e['name'].to_s == 'Paid Split' }
check(!de.nil?, 'donut zone emitted (was the dropped-pie class)', fails)
check(de && de['kind'] == 'donut-chart', "dual-constant-axis pie → donut-chart (got #{de && de['kind']})", fails)
xcol = de && (de['columns'] || []).find { |c| c['id'].to_s.start_with?('x-') }
check(xcol && xcol['formula'].to_s =~ /IS_PAID|Is Paid/,
      "slice dim recovered from the name-keyed color channel (got #{xcol && xcol['formula']})", fails)
ycol = de && (de['columns'] || []).find { |c| c['id'].to_s.start_with?('y-') }
check(ycol && ycol['formula'].to_s !~ /AVG\(0\)|CalcA/,
      "angle measure is never the placeholder (got #{ycol && ycol['formula']})", fails)
check(log.include?('donut idiom') || log.include?('donut-chart'),
      'donut translation is disclosed', fails)

puts 'plain pie stays pie'
pe = els.find { |e| e['name'].to_s == 'Plain Pie' }
check(pe && pe['kind'] == 'pie-chart', "plain pie stays pie-chart (got #{pe && pe['kind']})", fails)

puts 'unsupported named mark → loud handoff'
ge = els.find { |e| e['name'].to_s == 'Level Strip' }
check(ge.nil?, 'GanttBar zone NOT auto-built as a stand-in bar', fails)
check(log.include?("ZONE DROPPED / STAYS-MANUAL: 'Level Strip'") && log.include?("'GanttBar'"),
      'handoff names the zone AND the mark class', fails)

puts 'sparkline dual-instance trend (full series, not the highlighted period)'
sp = els.find { |e| e['name'].to_s == 'Trend Mini' }
check(!sp.nil?, 'sparkline tile emitted', fails)
sp_y = sp ? Array(sp.dig('yAxis', 'columnIds')) : []
sp_formulas = sp ? (sp['columns'] || []).select { |c| sp_y.include?(c['id']) }.map { |c| c['formula'].to_s } : []
check(sp_formulas.any? { |f| f == 'Sum([Master/Val])' },
      "full-trend series emitted alongside the highlight (got #{sp_formulas.inspect})", fails)
check(sp_y.size >= 2, "tile plots BOTH series (got #{sp_y.size})", fails)
check(log.include?('multi-instance trend shelf'), 'overlay expansion is disclosed', fails)

# ---- topo order (build_wb_spec) ---------------------------------------------
puts 'data-page topo order (source before consumer)'
require_relative 'mechanical-specs'
require_relative 'lib/workbook_code'
spec = MechanicalSpecs.build_wb_spec(
  name: 'T', dm_id: 'dm', fact_eid: 'fe',
  master_columns: [{ 'id' => 'm-a', 'name' => 'A' }],
  chart_elements: [],
  data_elements: [
    # consumer FIRST (the round-6 400): sources the sub-master below
    { 'id' => 'helper-1', 'kind' => 'table', 'name' => 'TopN Source (x)',
      'source' => { 'kind' => 'table', 'elementId' => 'submaster-b' }, 'columns' => [] },
    { 'id' => 'submaster-b', 'kind' => 'table', 'name' => 'Master (B)',
      'source' => { 'kind' => 'data-model', 'elementId' => '__DM_ELEMENT__:B' }, 'columns' => [] },
    { 'id' => 'helper-2', 'kind' => 'table', 'name' => 'On Master',
      'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columns' => [] }
  ])
data_page = WorkbookCode.pages(spec).find { |p| p['id'] == 'page-data' }
order = WorkbookCode.elements_for_page(spec, data_page).map { |e| e['id'] }
check(order.first == 'master', "master leads the data page (got #{order.inspect})", fails)
check(order.index('submaster-b') < order.index('helper-1'),
      "sub-master precedes the helper that sources it (got #{order.inspect})", fails)
check(order.include?('helper-2'), 'independent helper still emitted', fails)

if fails.empty?
  puts 'test-zone-honesty: ALL PASS'
else
  puts "test-zone-honesty: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
