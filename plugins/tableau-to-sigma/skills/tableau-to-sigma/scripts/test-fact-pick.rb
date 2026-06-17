#!/usr/bin/env ruby
# Regression test for fact-element picking (2026-06-17). Deterministic + offline.
# Guards the date-crosstab regression: a narrow time dimension named "Dim Time"
# (or "Date Dim", "Dim Date") must NEVER be chosen as the fact/master element —
# its name doesn't end in " Dim" so a trailing-only / Dim$/ test let it slip
# through and win max_by, making the workbook master source the wrong element
# ("Dependency not found: 'dim time/...'" on POST).
#
# Part A: MechanicalSpecs.pick_fact excludes "Dim Time" and picks the widest
#         non-dim element (the real fact view).
# Part B: source-guard — both migrate-tableau fact-resolution paths (fresh +
#         reuse) use the leading+trailing dim test and tie-break by column count.
#
# Usage:  ruby scripts/test-fact-pick.rb

require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

puts 'Part A — pick_fact never returns a dim, prefers the widest view'
# A converter-shaped model: dims (incl. the tricky "Dim Time"), a base fact, and
# the wide flattened "Order Fact View" derived element.
cols = ->(n) { Array.new(n) { |i| { 'id' => "c#{i}", 'name' => "c#{i}" } } }
model = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-dimtime', 'name' => 'Dim Time',        'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ DIM_TIME] },   'columns' => cols.call(8) },
  { 'id' => 'e-custdim', 'name' => 'Customer Dim',    'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ CUSTOMER_DIM] }, 'columns' => cols.call(18) },
  { 'id' => 'e-ordfact', 'name' => 'Order Fact',      'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ ORDER_FACT] },   'columns' => cols.call(36) },
  { 'id' => 'e-ofview',  'name' => 'Order Fact View', 'source' => { 'kind' => 'table', 'elementId' => 'e-ordfact' },                  'columns' => cols.call(94) }
] }] }
fact = MechanicalSpecs.pick_fact(model)
check(fact && fact['name'] == 'Order Fact View', "picks 'Order Fact View' (got #{fact && fact['name'].inspect})", fails)
check(fact && fact['name'] != 'Dim Time', "does NOT pick 'Dim Time'", fails)

# Even with NO derived view, a base fact must beat the narrow time dim.
model2 = { 'pages' => [{ 'elements' => [
  { 'id' => 'e-dimtime', 'name' => 'Dim Time',   'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ DIM_TIME] }, 'columns' => cols.call(8) },
  { 'id' => 'e-ordfact', 'name' => 'Order Fact', 'source' => { 'kind' => 'warehouse-table', 'path' => %w[CSA TJ ORDER_FACT] }, 'columns' => cols.call(36) }
] }] }
f2 = MechanicalSpecs.pick_fact(model2)
check(f2 && f2['name'] == 'Order Fact', "base-only: picks 'Order Fact' over 'Dim Time' (got #{f2 && f2['name'].inspect})", fails)

puts 'Part B — migrate-tableau fact-resolution guards (both paths)'
mig = File.read(File.join(__dir__, 'migrate-tableau.rb'))
check(mig.scan(/\(\^Dim\\b\| Dim\$\)/i).size >= 2, 'both fresh + reuse paths use the leading+trailing dim test', fails)
check(mig.match?(/max_by \{ \|e\| \(e\['columnLabels'\] \|\| \[\]\)\.size \}/),
      'fact fallback tie-breaks by column count, not list order', fails)

puts
if fails.empty?
  puts 'OK — fact-pick guards all pass'; exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"; fails.each { |f| warn "  - #{f}" }; exit 1
end
