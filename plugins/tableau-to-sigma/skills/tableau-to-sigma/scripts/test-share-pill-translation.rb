#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the v5.4 share-pill translation wave. Grammar patterns
# locked (all serialization-level, none fixture-specific):
#
#   1. TWO-HOP SHARE: Tableau authors split shares across two <calculation>s —
#      [Total X] = TOTAL(SUM([X])), [% X] = SUM([X]) / [Total X]. The window
#      construct never appears in the referring formula, so the classifier
#      returned nil. translate_window_calc now inlines embedded refs whose
#      known formula carries a window construct (one hop) and classifies the
#      result — a share pill must NEVER fall through to positional RowNumber().
#
#   2. POSITIONAL RETARGET: the ranked-bar idiom serializes INDEX() as a
#      discrete (:ok) instance next to the category dim while the real
#      bar-length measure rides a shelf as a continuous (:qk) instance —
#      including inside shelf EXPRESSIONS ("(inst + inst)", guid-less fields).
#      A bare RowNumber() y-axis is a rank header mis-pick; the builder must
#      re-target the value to the continuous shelf measure.
#
#   3. W1 SCOPE AUDIT (chart): PercentOfTotal on chart formulas is grand_total
#      only (live-probed). When the table-calc addressing (ordering_field)
#      does not span the chart's dims, the source share is partitioned and the
#      emitted number diverges — the builder must say so LOUDLY (STAYS-MANUAL
#      class), never ship a silently wrong share.
#
# Usage: ruby scripts/test-share-pill-translation.rb
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

# ---- 1. unit: two-hop share classification --------------------------------
src = File.read(BUILD)
w = Object.new
%w[SIGMA_AGG USER_AGG_FN WINDOW_SIGMA_FNS WINDOW_MANUAL_RE WINDOW_TC_RE].each do |c|
  m = src.match(/^#{c}\s*=\s*%w\[.*?\]\.freeze/m) ||
      src.match(/^#{c}\s*=\s*\{.*?\}\.freeze/m) ||
      src.match(/^#{c}\s*=.*$/)
  w.instance_eval(m[0]) if m
end
%w[
  translate_window_calc translate_tableau_tc translate_user_agg_formula
  strip_tableau_comments translate_sla_ratio split_top_level_args
  parse_tableau_function_call translated_calc_reference map_column header_base
].each do |fn|
  m = src.match(/^def #{fn}\b.*?\n^end$/m)
  w.instance_eval(m[0]) if m
end

puts 'two-hop share (embedded calc-ref inlining)'
cbg = {
  'CalcTotal' => { 'caption' => 'Total Value', 'formula' => 'TOTAL(SUM([Value]))' },
  'CalcShare' => { 'caption' => '% Share', 'formula' => 'SUM([Value])/ [CalcTotal]' }
}
plan = w.translate_window_calc('SUM([Value])/ [CalcTotal]', {}, cbg)
check(plan.is_a?(Hash) && plan['mode'] == 'inline',
      "two-hop share classifies inline (got #{plan.inspect[0, 80]})", fails)
check(plan && plan['formula'].to_s.start_with?('PercentOfTotal('),
      "two-hop share emits PercentOfTotal (got #{plan && plan['formula']})", fails)
# by CAPTION too (formulas reference calcs by caption after guid substitution)
plan2 = w.translate_window_calc('SUM([Value])/ [Total Value]', {}, cbg)
check(plan2 && plan2['formula'].to_s.start_with?('PercentOfTotal('),
      'two-hop share resolves the ref by caption too', fails)
# a ref to a NON-window calc must stay untouched (no inlining, still nil)
plan3 = w.translate_window_calc('SUM([Value])/ [PlainCalc]',
                                {}, { 'PlainCalc' => { 'caption' => 'Plain', 'formula' => 'SUM([Other])' } })
check(plan3.nil?, 'ref to a non-window calc is not inlined (stays nil)', fails)
# a non-single-call window formula splices parenthesized (precedence safety)
plan4 = w.translate_window_calc('SUM([Value])/ [RatioCalc]',
                                {}, { 'RatioCalc' => { 'caption' => 'R', 'formula' => 'TOTAL(SUM([A]))/TOTAL(SUM([B]))' } })
check(plan4.nil? || plan4['mode'] == 'manual' || plan4['formula'].to_s !~ /\APercentOfTotal/,
      'multi-call denominator never fakes a percent-of-total', fails)

# ---- 2+3. integration: ranked share pills + scope audit --------------------
FED = '[federated.fact]'
ranked_zone = {
  'id' => '1', 'kind' => 'chart', 'caption' => 'Share Pills', 'view_ref' => nil,
  'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 50.0, 'h_pct' => 40.0,
  'chart_kind' => 'bar', 'chart_kind_inferred' => false, 'mark_class' => 'Bar',
  'sort' => nil, 'shelf_sorts' => [], 'quick_calc_pcto' => [], 'filters' => [], 'hidden_filters' => [],
  'aggregations' => { '[CalcIdx]' => 'User', '[CalcShare]' => 'User', '[Subject]' => 'None' },
  'channels' => {}, 'formats' => {},
  'calculations' => [
    { 'name' => '[CalcIdx]',   'caption' => 'INDEX()',     'datatype' => 'integer', 'role' => 'measure', 'class' => 'tableau', 'formula' => 'INDEX()' },
    { 'name' => '[CalcTotal]', 'caption' => 'Total Value', 'datatype' => 'real',    'role' => 'measure', 'class' => 'tableau', 'formula' => 'TOTAL(SUM([Value]))' },
    { 'name' => '[CalcShare]', 'caption' => '% Share',     'datatype' => 'real',    'role' => 'measure', 'class' => 'tableau', 'formula' => 'SUM([Value])/ [CalcTotal]' }
  ],
  'dual_axis' => false,
  'measures' => [{ 'column' => '[CalcIdx]', 'derivation' => 'User' }, { 'column' => '[CalcShare]', 'derivation' => 'User' }],
  'ref_marks' => [], 'axis_formats' => [], 'mark_labels_show' => true,
  'rows_shelf' => {
    'raw' => "(#{FED}.[usr:CalcIdx:ok] / #{FED}.[none:Subject:nk])",
    'fields' => [
      { 'raw' => "#{FED}.[usr:CalcIdx:ok]", 'role' => 'measure', 'derivation' => 'usr', 'discrete' => false, 'guid' => 'CalcIdx' },
      { 'raw' => "#{FED}.[none:Subject:nk]", 'role' => 'dim', 'derivation' => 'none', 'guid' => 'Subject' }
    ],
    'dim_count' => 1, 'measure_count' => 1, 'cont_measure_count' => 1,
    'has_measure_names' => false, 'has_measure_values' => false
  },
  'cols_shelf' => {
    'raw' => "(#{FED}.[usr:CalcShare:qk:2] + #{FED}.[usr:CalcShare:qk:3])",
    'fields' => [
      { 'raw' => "#{FED}.[usr:CalcShare:qk:2] + #{FED}.[usr:CalcShare:qk:3]", 'role' => 'measure', 'derivation' => 'usr', 'discrete' => false, 'guid' => nil }
    ],
    'dim_count' => 0, 'measure_count' => 1, 'cont_measure_count' => 1,
    'has_measure_names' => false, 'has_measure_values' => false
  },
  'is_crosstab' => false, 'is_kpi' => false
}

part_zone = JSON.parse(JSON.generate(ranked_zone))
part_zone.merge!('id' => '2', 'caption' => 'Partitioned Share', 'y_pct' => 50.0)
part_zone['aggregations'] = { '[CalcW]' => 'User', '[Path]' => 'None' }
part_zone['calculations'] = [
  { 'name' => '[CalcW]', 'caption' => 'Share W', 'datatype' => 'real', 'role' => 'measure',
    'class' => 'tableau', 'formula' => 'WINDOW_MAX(COUNTD([Seed]) / TOTAL(COUNTD([Seed])))',
    'ordering_field' => 'Direction' }
]
part_zone['measures'] = [{ 'column' => '[CalcW]', 'derivation' => 'User' }]
part_zone['rows_shelf'] = {
  'raw' => "#{FED}.[none:Path:nk]",
  'fields' => [{ 'raw' => "#{FED}.[none:Path:nk]", 'role' => 'dim', 'derivation' => 'none', 'guid' => 'Path' }],
  'dim_count' => 1, 'measure_count' => 0, 'cont_measure_count' => 0,
  'has_measure_names' => false, 'has_measure_values' => false
}
part_zone['cols_shelf'] = {
  'raw' => "#{FED}.[usr:CalcW:qk]",
  'fields' => [{ 'raw' => "#{FED}.[usr:CalcW:qk]", 'role' => 'measure', 'derivation' => 'usr', 'discrete' => false, 'guid' => 'CalcW' }],
  'dim_count' => 0, 'measure_count' => 1, 'cont_measure_count' => 1,
  'has_measure_names' => false, 'has_measure_values' => false
}

layout = [{ 'dashboard' => 'Dash', 'is_story' => false, 'zones' => [ranked_zone, part_zone] }]
meta = {
  'worksheets' => {}, 'stories' => [], 'shared_filters' => [], 'parameters' => [],
  'column_aliases' => {},
  'columns_by_guid' => {
    'CalcIdx'   => { 'caption' => 'INDEX()', 'formula' => 'INDEX()' },
    'CalcTotal' => { 'caption' => 'Total Value', 'formula' => 'TOTAL(SUM([Value]))' },
    'CalcShare' => { 'caption' => '% Share', 'formula' => 'SUM([Value])/ [CalcTotal]' },
    'CalcW'     => { 'caption' => 'Share W', 'formula' => 'WINDOW_MAX(COUNTD([Seed]) / TOTAL(COUNTD([Seed])))' },
    'Subject'   => { 'caption' => 'Subject' }, 'Path' => { 'caption' => 'Path' },
    'Value'     => { 'caption' => 'Value' },  'Seed' => { 'caption' => 'Seed' }
  }
}
mmap = {
  '(?i)^Subject$' => { 'id' => 'm-subj', 'name' => 'Subject' },
  '(?i)^Path$'    => { 'id' => 'm-path', 'name' => 'Path' },
  '(?i)^Value$'   => { 'id' => 'm-val',  'name' => 'Value' },
  '(?i)^Seed$'    => { 'id' => 'm-seed', 'name' => 'Seed' }
}

out_els = nil
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
                            '--out', out)
  log = o + e
  check(st.success?, "build-charts exits 0 (got #{st.exitstatus}: #{e.lines.first})", fails)
  raw = JSON.parse(File.read(out)) rescue nil
  out_els = raw.is_a?(Hash) ? (raw['pages'] || []).flat_map { |p| p['elements'] || [] } : Array(raw)
end

puts 'ranked %-share pill bar (positional retarget)'
pills = out_els.find { |el| el['name'].to_s.strip == 'Share Pills' }
check(!pills.nil?, 'Share Pills bar element emitted', fails)
ycol = pills && (pills['columns'] || []).find { |c| c['id'].to_s.start_with?('y-') }
check(ycol && ycol['formula'].to_s.start_with?('PercentOfTotal('),
      "y-axis is the share, PercentOfTotal(...) (got #{ycol && ycol['formula']})", fails)
all_formulas = out_els.flat_map { |el| (el['columns'] || []).map { |c| c['formula'].to_s } }
check(all_formulas.none? { |f| f =~ /\A\s*RowNumber\s*\(\s*\)\s*\z/ },
      'no bare RowNumber() value column anywhere', fails)
check(log.include?('re-targeted to the continuous shelf measure'),
      'retarget is disclosed in the build log', fails)

puts 'chart share-scope audit (partitioned share)'
check(log.include?("'Partitioned Share' share scope MISMATCH"),
      'partitioned share (addressing != chart dims) warns LOUDLY', fails)
check(log.include?('STAYS-MANUAL'), 'mismatch names the manual handoff', fails)
check(!log.include?("'Share Pills' share scope MISMATCH"),
      'whole-table share (no addressing) does NOT false-alarm', fails)

if fails.empty?
  puts 'test-share-pill-translation: ALL PASS'
else
  puts "test-share-pill-translation: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
