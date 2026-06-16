#!/usr/bin/env ruby
# Regression test for per-page element-id namespacing (2026-06-16). Deterministic
# + offline. Guards the scale/layout fix: a Tableau worksheet placed on multiple
# dashboards yields multiple Sigma element copies sharing one id ("el-<ws>") →
# "Duplicate id" on POST. The page-per-dashboard emitter namespaces the 2nd+
# occurrence per page, rewriting the id stem across the element's own JSON (id +
# column ids x-/y-/g-<id> + grouping refs) in lock-step.
#
# Part A: source-contract guard (the dedup block is present + keyed correctly).
# Part B: behavioral — replicate the shipped namespacing op and assert the id
#         stem is rewritten consistently across id, column ids, and grouping refs.
#
# Usage:  ruby scripts/test-element-id-namespacing.rb

require 'json'
DIR = __dir__
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

puts 'Part A — namespacing block present in build-charts-from-signals.rb'
src = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
check(src.include?('seen_el_ids'), 'tracks seen_el_ids across pages', fails)
check(src.match?(/seen_el_ids\[stem\]/), 'namespaces an element id already seen on a prior page', fails)
check(src.match?(/el\.to_json\.gsub\(stem, ns\)/), 'rewrites the id stem across the element JSON (id + column ids + grouping refs)', fails)

puts 'Part B — namespacing rewrites id stem in lock-step'
# Mirror the shipped op exactly.
seen = {}
def namespace(el, seen, slug)
  stem = el['id']
  if stem && seen[stem]
    JSON.parse(el.to_json.gsub(stem, "#{stem}-#{slug}"))
  else
    seen[stem] = true if stem
    el
  end
end
make = lambda do
  { 'id' => 'el-revenue-by-region', 'kind' => 'bar',
    'columns' => [
      { 'id' => 'x-el-revenue-by-region', 'name' => 'Region', 'formula' => '[Master/Region]' },
      { 'id' => 'y-el-revenue-by-region', 'name' => 'Net Revenue', 'formula' => 'Sum([Master/Net Revenue])' }
    ],
    'groupings' => [{ 'id' => 'g-el-revenue-by-region', 'groupBy' => ['x-el-revenue-by-region'], 'calculations' => ['y-el-revenue-by-region'] }] }
end
p1 = namespace(make.call, seen, 'orders-overview')          # first occurrence — untouched
p2 = namespace(make.call, seen, 'executive-rollup')         # reuse — namespaced

check(p1['id'] == 'el-revenue-by-region', 'first occurrence keeps its id', fails)
check(p2['id'] == 'el-revenue-by-region-executive-rollup', 'reused element id is namespaced per page', fails)
check(p2['columns'][0]['id'] == 'x-el-revenue-by-region-executive-rollup', 'column id rewritten in lock-step', fails)
check(p2['groupings'][0]['groupBy'] == ['x-el-revenue-by-region-executive-rollup'], 'grouping ref rewritten in lock-step', fails)
check(p2['columns'][1]['formula'] == 'Sum([Master/Net Revenue])', 'formula (Master ref) left untouched', fails)
check(p1['id'] != p2['id'], 'the two page copies now have distinct ids (no Duplicate id)', fails)

puts
if fails.empty?
  puts 'OK — element-id namespacing all pass'; exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"; fails.each { |f| warn "  - #{f}" }; exit 1
end
