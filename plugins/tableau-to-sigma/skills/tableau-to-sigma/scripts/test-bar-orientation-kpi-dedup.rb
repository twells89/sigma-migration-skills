#!/usr/bin/env ruby
# Regression test for two build-charts fidelity fixes (from a live CoCo run of
# the Orders Executive Overview dashboard):
#
#  (A) Bar orientation — a Tableau bar with the DIMENSION on the Rows shelf and
#      the MEASURE on the Cols shelf is a HORIZONTAL bar; build-charts must emit
#      `orientation: "horizontal"`. The default (dim on Cols) stays vertical
#      (field omitted). Bug: all bars came out vertical.
#  (B) Orphan KPI-label text zones — a Tableau KPI card is a short label text
#      zone directly ABOVE a scorecard in the same column band. Sigma's kpi-chart
#      renders its own title, so those labels are redundant; build-charts must
#      DROP them (positionally — the label text is the clean measure name and
#      doesn't match the scorecard's internal caption). A full-width section
#      title must be KEPT. Bug: the labels piled into a stray bottom band.
#
# Deterministic + offline: hand-builds the dashboard-layout.json the parser would
# emit, runs the ACTUAL build-charts-from-signals.rb, asserts the output spec.
#
# Usage: ruby scripts/test-bar-orientation-kpi-dedup.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# One dashboard: a KPI card (label text zone above a scorecard), a full-width
# section title, a horizontal bar (dim on Rows), and a vertical bar (dim on Cols).
LAYOUT = [{
  'dashboard' => 'Exec',
  'zones' => [
    { 'id' => 't-title', 'kind' => 'text', 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 4,
      'text_runs' => [{ 'text' => 'Orders — Executive Overview' }] },
    { 'id' => 't-lbl', 'kind' => 'text', 'x_pct' => 0, 'y_pct' => 4, 'w_pct' => 20, 'h_pct' => 5,
      'text_runs' => [{ 'text' => 'Net Revenue' }] },
    { 'id' => 'k1', 'kind' => 'chart', 'caption' => 'OV KPI Revenue', 'is_kpi' => true,
      'chart_kind' => 'kpi', 'x_pct' => 0, 'y_pct' => 9, 'w_pct' => 20, 'h_pct' => 15,
      'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
      'ref_marks' => [], 'aggregations' => { '[Net Revenue]' => 'Sum' },
      'rows_shelf' => { 'fields' => [] }, 'cols_shelf' => { 'fields' => [] },
      'measures' => [{ 'column' => '[Net Revenue]', 'derivation' => 'Sum' }], 'calculations' => [] },
    { 'id' => 'bH', 'kind' => 'chart', 'caption' => 'Rev by Region', 'chart_kind' => 'bar',
      'mark_class' => 'Bar', 'x_pct' => 0, 'y_pct' => 30, 'w_pct' => 50, 'h_pct' => 30,
      'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
      'ref_marks' => [], 'aggregations' => { '[Region]' => 'None', '[Net Revenue]' => 'Sum' },
      'rows_shelf' => { 'fields' => [{ 'caption' => 'Region', 'role' => 'dim' }] },
      'cols_shelf' => { 'fields' => [{ 'caption' => 'Net Revenue', 'role' => 'measure' }] },
      'measures' => [{ 'column' => '[Net Revenue]', 'derivation' => 'Sum' }], 'calculations' => [] },
    { 'id' => 'bV', 'kind' => 'chart', 'caption' => 'Rev by Ship', 'chart_kind' => 'bar',
      'mark_class' => 'Bar', 'x_pct' => 50, 'y_pct' => 30, 'w_pct' => 50, 'h_pct' => 30,
      'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
      'ref_marks' => [], 'aggregations' => { '[Ship]' => 'None', '[Net Revenue]' => 'Sum' },
      'rows_shelf' => { 'fields' => [{ 'caption' => 'Net Revenue', 'role' => 'measure' }] },
      'cols_shelf' => { 'fields' => [{ 'caption' => 'Ship', 'role' => 'dim' }] },
      'measures' => [{ 'column' => '[Net Revenue]', 'derivation' => 'Sum' }], 'calculations' => [] }
  ]
}]
META = { 'worksheets' => {}, 'shared_filters' => [], 'parameters' => [], 'column_aliases' => {},
         'columns_by_guid' => {} }
MMAP = {
  '(?i)^Region$'      => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Ship$'        => { 'id' => 'm-ship',   'name' => 'Ship' },
  '(?i)^Net Revenue$' => { 'id' => 'm-rev',    'name' => 'Net Revenue' }
}

out = nil
Dir.mktmpdir do |d|
  File.write("#{d}/layout.json", JSON.dump(LAYOUT))
  File.write("#{d}/meta.json",   JSON.dump(META))
  File.write("#{d}/mm.json",     JSON.dump(MMAP))
  File.write("#{d}/get-workbook.json",
             JSON.dump('views' => { 'view' => [{ 'id' => 'vH', 'name' => 'Rev by Region' },
                                                { 'id' => 'vV', 'name' => 'Rev by Ship' }] }))
  Dir.mkdir("#{d}/views")
  File.write("#{d}/views/vH.csv", "Region,Net Revenue\nWest,100\nEast,50\n")
  File.write("#{d}/views/vV.csv", "Ship,Net Revenue\nAir,100\nGround,50\n")
  o = "#{d}/specs.json"
  `ruby #{BUILD} --tableau-dir #{d} --layout #{d}/layout.json --meta #{d}/meta.json --master-map #{d}/mm.json --master-element-id master --skip-dashboard-read unit-test --out #{o} 2>&1`
  out = JSON.parse(File.read(o)) if File.exist?(o)
end

abort 'build produced no spec' unless out
els = out.is_a?(Array) ? out : (out['elements'] || (out['pages'] || []).flat_map { |p| p['elements'] || [] })
texts = els.select { |e| e['kind'] == 'text' }
bars  = els.select { |e| e['kind'] == 'bar-chart' }
bar_h = bars.find { |b| b['name'].to_s =~ /Region/ }
bar_v = bars.find { |b| b['name'].to_s =~ /Ship/ }

# (B) orphan KPI label dropped, section title kept
text_bodies = texts.map { |t| (t['body'] || '').to_s }
check(text_bodies.none? { |b| b =~ /Net Revenue/ && b !~ /Executive/ },
      'orphan KPI label "Net Revenue" (above the KPI card) was DROPPED', fails)
check(text_bodies.any? { |b| b =~ /Executive Overview/ },
      'full-width section title "Orders — Executive Overview" was KEPT', fails)

# (A) orientation
check(!bar_h.nil? && bar_h['orientation'] == 'horizontal',
      "dim-on-Rows bar → orientation:horizontal (got #{bar_h && bar_h['orientation'].inspect})", fails)
check(!bar_v.nil? && bar_v['orientation'].nil?,
      "dim-on-Cols bar → vertical (no orientation field) (got #{bar_v && bar_v['orientation'].inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — horizontal-bar orientation emitted + orphan KPI labels suppressed'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
