#!/usr/bin/env ruby
# Offline: build-domo-layout.rb's zone chart_kind must be the LOGICAL 'kpi'
# tag that lib/layout.rb's kpi_like_zone? (vendored VERBATIM from
# tableau-to-sigma — do not diverge that copy) expects, not the Sigma
# ELEMENT kind 'kpi-chart' that domo-discover.rb's separate sigma_kind_hint
# emits for build-workbook.rb's build_kpi. build-domo-layout.rb's kind_hint
# (scripts/build-domo-layout.rb:33) used to stamp 'kpi-chart' onto the zone,
# so a Domo KPI tile that failed the plain size heuristic silently missed
# KPI-row detection instead of grouping into one GridContainer.
#   ruby test/test-layout-tag.rb
require_relative '../scripts/lib/layout'
require_relative '../scripts/build-domo-layout'

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

puts "== kind_hint: Domo singlevalue/summary/badge cards -> logical 'kpi' (not 'kpi-chart') =="
eq(kind_hint('badge'), 'kpi', "chartType 'badge' -> 'kpi'")
eq(kind_hint('singlevalue'), 'kpi', "chartType containing 'singlevalue' -> 'kpi'")
eq(kind_hint('summary_number'), 'kpi', "chartType containing 'summary' -> 'kpi'")
eq(kind_hint('filter'), 'filter', "chartType 'filter' unaffected")

puts "== build_dashboard: a KPI card's zone carries chart_kind=='kpi' =="
# Two cards so max_x/max_y come from their combined extent — the KPI card's
# own w_pct/h_pct end up WAY over the plain size heuristic thresholds
# (KPI_MAX_W_PCT 40 / KPI_MAX_H_PCT 12), isolating detection via the
# chart_kind tag rather than a heuristic size coincidence. Cards use cards.json's
# own 'id' field (domo-discover.rb's normalize_card), not the old capture-visuals
# 'cardId' shape — build-domo-layout.rb now sources geometry from cards.json.
cards = [
  { 'id' => 'kpi1', 'title' => 'Total Revenue', 'chartType' => 'badge',
    'x' => 0, 'y' => 0, 'w' => 80, 'h' => 50 },
  { 'id' => 't1', 'title' => 'Detail', 'chartType' => 'table',
    'x' => 80, 'y' => 0, 'w' => 20, 'h' => 10 },
]
dashboard = build_dashboard('Overview', cards)
kpi_zone = dashboard['zones'].find { |z| z['id'] == 'kpi1' }
ok(kpi_zone, 'KPI card produced a zone')
eq(kpi_zone['chart_kind'], 'kpi', "zone chart_kind is the logical 'kpi', not the element kind 'kpi-chart'")
ok(kpi_zone['w_pct'] > SigmaLayout::KPI_MAX_W_PCT || kpi_zone['h_pct'] > SigmaLayout::KPI_MAX_H_PCT,
   'sanity: this zone geometry exceeds the size heuristic, so detection below can only come from the tag')

puts "== lib/layout.rb's UNCHANGED kpi_like_zone? detects the corrected tag =="
ok(SigmaLayout.kpi_like_zone?(kpi_zone), "build-domo-layout's 'kpi'-tagged zone is detected as KPI-like")

puts "== no regression: a plain chart zone (non-KPI) is not swept in =="
tbl_zone = dashboard['zones'].find { |z| z['id'] == 't1' }
eq(tbl_zone['chart_kind'], 'table', "non-KPI card keeps its own chart_kind")

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
