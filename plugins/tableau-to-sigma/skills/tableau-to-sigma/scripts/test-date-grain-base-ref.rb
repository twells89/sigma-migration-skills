#!/usr/bin/env ruby
# Regression test: a date-grain dim header ("Month of Order Date") must resolve to
# the BASE date column so DateTrunc wraps [Master/Order Date] — NOT the converter's
# passthrough "Month of Order Date" master column (formula [Fact/Month of Order
# Date], a non-existent fact column → renders empty / needs a --master-col override).
# The base "Order Date" is on the master via the reuse-union (#5); build-charts must
# prefer it for grain headers. Covers the "master/month of order date" defect.
#
# Usage: ruby scripts/test-date-grain-base-ref.rb

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
    'id' => 'l1', 'kind' => 'chart', 'caption' => 'Revenue Trend', 'chart_kind' => 'line',
    'mark_class' => 'Line', 'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100,
    'filters' => [], 'hidden_filters' => [], 'channels' => {}, 'formats' => {}, 'dual_axis' => false,
    'ref_marks' => [], 'aggregations' => { '[Net Revenue]' => 'Sum' },
    'rows_shelf' => { 'fields' => [] }, 'cols_shelf' => { 'fields' => [] },
    'measures' => [{ 'column' => '[Net Revenue]', 'derivation' => 'Sum' }], 'calculations' => []
  }]
}]
META = { 'worksheets' => {}, 'shared_filters' => [], 'parameters' => [], 'column_aliases' => {}, 'columns_by_guid' => {} }
# Master-map AS IT LOOKS POST-#5: the base "Order Date" is present, AND the
# converter's passthrough "Month of Order Date" is also present (the trap).
MMAP = {
  '(?i)^(?:(?:month|year|quarter|week|day) of )?Order Date$'          => { 'id' => 'm-order-date', 'name' => 'Order Date' },
  '(?i)^(?:(?:month|year|quarter|week|day) of )?Month of Order Date$' => { 'id' => 'm-month-of-order-date', 'name' => 'Month of Order Date' },
  '(?i)^Net Revenue$'                                                 => { 'id' => 'm-rev', 'name' => 'Net Revenue' }
}

out = nil
Dir.mktmpdir do |d|
  File.write("#{d}/layout.json", JSON.dump(LAYOUT))
  File.write("#{d}/meta.json",   JSON.dump(META))
  File.write("#{d}/mm.json",     JSON.dump(MMAP))
  File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Revenue Trend' }] }))
  Dir.mkdir("#{d}/views")
  File.write("#{d}/views/v1.csv", "Month of Order Date,Net Revenue\n2024-01,100\n2024-02,50\n")
  o = "#{d}/specs.json"
  `ruby #{BUILD} --tableau-dir #{d} --layout #{d}/layout.json --meta #{d}/meta.json --master-map #{d}/mm.json --master-element-id master --skip-dashboard-read unit-test --out #{o} 2>&1`
  out = JSON.parse(File.read(o)) if File.exist?(o)
end

abort 'build produced no spec' unless out
els = out.is_a?(Array) ? out : (out['elements'] || (out['pages'] || []).flat_map { |p| p['elements'] || [] })
line = els.find { |e| e['kind'] == 'line-chart' }
xid  = line && line.dig('xAxis', 'columnId')
xcol = line && (line['columns'] || []).find { |c| c['id'] == xid }
f    = xcol && xcol['formula'].to_s

check(!line.nil?, 'line chart built', fails)
check(f == 'DateTrunc("month", [Master/Order Date])',
      "x-axis wraps the BASE date column (got #{f.inspect})", fails)
check(f !~ /Month of Order Date/,
      'x-axis does NOT reference the broken passthrough [Master/Month of Order Date]', fails)

puts
if fails.empty?
  puts 'ALL PASS — date-grain dim resolves to the base date column'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
