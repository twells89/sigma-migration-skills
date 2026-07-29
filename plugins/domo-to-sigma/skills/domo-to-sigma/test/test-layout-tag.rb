#!/usr/bin/env ruby
# Offline: kpi_like_zone? must accept both 'kpi' AND 'kpi-chart' chart_kind
# tags. build-domo-layout.rb's kind_hint (scripts/build-domo-layout.rb:33)
# emits 'kpi-chart' for Domo summary-number/badge cards, but layout.rb:388
# only matched the literal string 'kpi' — so a Domo KPI row silently fell
# through to the plain size heuristic (and, for a wide/tall KPI tile, missed
# KPI-row detection entirely instead of grouping into one GridContainer).
#   ruby test/test-layout-tag.rb
require_relative '../scripts/lib/layout'

$failures = 0
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end
def ok(cond, msg) eq(!!cond, true, msg) end

puts "== kpi_like_zone?: 'kpi-chart' tag (Domo) detected, not just 'kpi' =="
# w_pct/h_pct deliberately exceed the size-heuristic thresholds (KPI_MAX_H_PCT
# 12 / KPI_MAX_W_PCT 40) so this only passes via the chart_kind tag match —
# it would NOT pass via the size fallback, isolating the tag-mismatch fix.
z = { 'kind' => 'chart', 'caption' => 'Total Revenue', 'chart_kind' => 'kpi-chart',
      'measures' => ['value'], 'w_pct' => 50.0, 'h_pct' => 50.0 }
ok(SigmaLayout.kpi_like_zone?(z), "chart_kind:'kpi-chart' zone detected as KPI-like")

puts "== kpi_like_zone?: existing 'kpi' tag still detected (no regression) =="
z2 = { 'kind' => 'chart', 'caption' => 'Total Revenue', 'chart_kind' => 'kpi',
       'measures' => ['value'], 'w_pct' => 50.0, 'h_pct' => 50.0 }
ok(SigmaLayout.kpi_like_zone?(z2), "chart_kind:'kpi' zone still detected as KPI-like")

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
