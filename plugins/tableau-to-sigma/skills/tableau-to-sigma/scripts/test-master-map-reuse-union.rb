#!/usr/bin/env ruby
# Regression test for finding #5: on the DM-REUSE path, derive_master built the
# master-map only from the .twb-derived CONVERTER fact columns, so a column that
# exists on the reused DM's fact but not in the converter output (e.g. a raw
# "Order Date" the source only used via a "Month of Order Date" calc) was silently
# absent — forcing a manual --master-col override. derive_master must UNION the
# real readback columns so the master-map spans ALL fact columns.
#
# Usage: ruby scripts/test-master-map-reuse-union.rb

require_relative 'mechanical-specs'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Converter fact element MISSING "Order Date" (only the derived month calc used it).
conv_fact = { 'name' => 'Order Fact', 'columns' => [
  { 'id' => 'c1', 'name' => 'Net Revenue' },
  { 'id' => 'c2', 'name' => 'Region' }
] }
# The REUSED DM's fact actually carries these columns (readback columnLabels).
real_labels = ['Net Revenue', 'Region', 'Order Date', 'Order Date Key']

d = MechanicalSpecs.derive_master(conv_fact, 'Order Fact', nil, real_labels, nil)
names = d['master_columns'].map { |c| c['name'] }

check(names.include?('Order Date'),
      "master-map now includes the reused-DM-only column 'Order Date' (got #{names.inspect})", fails)
check(names.include?('Net Revenue') && names.include?('Region'),
      'converter columns still present', fails)
check(names.count('Order Date') == 1 && names.uniq.length == names.length,
      'no duplicate master columns', fails)

od = d['master_columns'].find { |c| c['name'] == 'Order Date' }
check(od && od['formula'] == '[Order Fact/Order Date]',
      "Order Date formula refs the fact element (got #{od && od['formula'].inspect})", fails)

# The mmap must carry a regex that matches an "Order Date" CSV header (so a chart
# dim/param resolves without a manual --master-col).
matched = d['mmap'].keys.any? { |rx| 'Order Date' =~ Regexp.new(rx) }
check(matched, "mmap has a regex matching the 'Order Date' header", fails)

# Suffix-dedup: a converter 'Region' must NOT be re-added as 'Region (Store Dim)'.
d2 = MechanicalSpecs.derive_master(conv_fact, 'Order Fact', nil,
                                   ['Net Revenue', 'Region (Store Dim)', 'Order Date'], nil)
n2 = d2['master_columns'].map { |c| c['name'] }
check(!n2.include?('Region (Store Dim)'),
      "a suffixed dup of an existing converter column is NOT re-added (got #{n2.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — reused-DM fact columns are unioned into the master-map'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
