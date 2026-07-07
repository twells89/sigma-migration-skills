#!/usr/bin/env ruby
# Regression test for finding #3: a Tableau AVERAGE reference line averages the
# plotted MARKS (per-bin aggregates), but Sigma evaluates a refMark formula over
# raw ROWS — so Avg([meas]) gave the row mean, not the mean of the bars. For an
# average line the mark-level mean = Sum(meas) / CountDistinct(<x-axis bins>).
#
# Deterministic + offline: runs the ACTUAL build-charts-from-signals.rb on a bar
# zone with an average reference mark and asserts the emitted refMark formula.
#
# Usage: ruby scripts/test-refmark-mark-level.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

LAYOUT = [{
  'dashboard' => 'D',
  'zones' => [{
    'id' => 'b1', 'kind' => 'chart', 'caption' => 'Rev by Region', 'chart_kind' => 'bar',
    'mark_class' => 'Bar', 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100,
    'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
    'aggregations' => { '[Region]' => 'None', '[Net Revenue]' => 'Sum' },
    'rows_shelf' => { 'fields' => [{ 'caption' => 'Net Revenue', 'role' => 'measure' }] },
    'cols_shelf' => { 'fields' => [{ 'caption' => 'Region', 'role' => 'dim' }] },
    'measures' => [{ 'column' => '[Net Revenue]', 'derivation' => 'Sum' }], 'calculations' => [],
    'ref_marks' => [{ 'kind' => 'line', 'formula' => 'average', 'label_type' => 'auto' }]
  }]
}]
META = { 'worksheets' => {}, 'shared_filters' => [], 'parameters' => [], 'column_aliases' => {}, 'columns_by_guid' => {} }
MMAP = {
  '(?i)^Region$'      => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Net Revenue$' => { 'id' => 'm-rev',    'name' => 'Net Revenue' }
}

out = nil
Dir.mktmpdir do |d|
  File.write("#{d}/layout.json", JSON.dump(LAYOUT))
  File.write("#{d}/meta.json",   JSON.dump(META))
  File.write("#{d}/mm.json",     JSON.dump(MMAP))
  File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Rev by Region' }] }))
  Dir.mkdir("#{d}/views")
  File.write("#{d}/views/v1.csv", "Region,Net Revenue\nWest,100\nEast,50\n")
  o = "#{d}/specs.json"
  `ruby #{BUILD} --tableau-dir #{d} --layout #{d}/layout.json --meta #{d}/meta.json --master-map #{d}/mm.json --master-element-id master --skip-dashboard-read unit-test --out #{o} 2>&1`
  out = JSON.parse(File.read(o)) if File.exist?(o)
end

abort 'build produced no spec' unless out
els = out.is_a?(Array) ? out : (out['elements'] || (out['pages'] || []).flat_map { |p| p['elements'] || [] })
bar = els.find { |e| e['kind'] == 'bar-chart' }
rm  = bar && (bar['refMarks'] || []).first
f   = rm && rm.dig('value', 'formula').to_s

check(!rm.nil?, 'an average reference mark was emitted as a refMark', fails)
check(f =~ /\ASum\(\[Master\/Net Revenue\]\)\s*\/\s*CountDistinct\(/,
      "average line is MARK-LEVEL: Sum(meas)/CountDistinct(bins) (got #{f.inspect})", fails)
check(f.include?('CountDistinct([Master/Region])'),
      "denominator counts the x-axis bins (Region) (got #{f.inspect})", fails)
check(f !~ /\AAvg\(/,
      'NOT the old row-level Avg([meas])', fails)

puts
if fails.empty?
  puts 'ALL PASS — average reference line translated to a mark-level mean'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
