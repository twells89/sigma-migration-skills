#!/usr/bin/env ruby
# Regression test for finding #8: the orchestrator can't read images, so it now
# SEEDS a draft png-read.json from the .twb zone tree (removing the write-from-
# scratch friction) — but the draft is verified:false, so the gate STILL requires
# the agent to Read the dashboard PNG and set verified:true (the .twb can't tell
# bar-vs-pie, text annotations, or the filter shelf). This preserves the vision
# gate while addressing the friction.
#
# Usage: ruby scripts/test-png-read-draft-seed.rb

require 'json'
require 'tmpdir'
require_relative 'lib/dashboard_read'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

LAYOUT = [{
  'dashboard' => 'Exec',
  'zones' => [
    { 'id' => 'k1', 'kind' => 'chart', 'caption' => 'KPI Revenue', 'is_kpi' => true, 'chart_kind' => 'kpi' },
    { 'id' => 'b1', 'kind' => 'chart', 'caption' => 'Rev by Region', 'chart_kind' => 'bar' },
    { 'id' => 'a1', 'kind' => 'chart', 'caption' => 'Auto Tile', 'chart_kind' => 'automatic' },
    { 'id' => 't1', 'kind' => 'text', 'text_runs' => [{ 'text' => 'Executive Overview' }] }
  ]
}]
META = { 'shared_filters' => [{ 'caption' => 'Order Date' }] }

Dir.mktmpdir do |d|
  File.write("#{d}/dashboard-layout.json", JSON.dump(LAYOUT))
  File.write("#{d}/dashboard-layout-meta.json", JSON.dump(META))

  p = DashboardRead.seed_from_layout(d)
  check(!p.nil? && File.exist?(p), 'seed_from_layout wrote a draft png-read.json', fails)
  doc = JSON.parse(File.read(p))

  check(doc['verified'] == false, 'draft is verified:false', fails)
  check(doc['tiles'].size == 3, "3 chart tiles seeded (got #{doc['tiles'].size})", fails)
  check(doc['tiles'].any? { |t| t['title'] == 'KPI Revenue' && t['kind'] == 'kpi-chart' }, 'KPI → kpi-chart', fails)
  check(doc['tiles'].any? { |t| t['title'] == 'Rev by Region' && t['kind'] == 'bar-chart' }, 'bar → bar-chart', fails)
  check(doc['tiles'].any? { |t| t['title'] == 'Auto Tile' && t['kind'] == 'bar-chart' }, "automatic → bar-chart (verify vs PNG)", fails)
  check(doc['text_elements'].include?('Executive Overview'), 'text zone → text_elements', fails)
  check(doc['filter_shelf'].any? { |f| f['label'] == 'Order Date' }, 'shared_filter → filter_shelf', fails)

  ok, errs = DashboardRead.validate(d)
  check(!ok && errs.first.to_s =~ /DRAFT|verified/, 'gate REJECTS the unverified draft', fails)

  doc['verified'] = true
  File.write(p, JSON.pretty_generate(doc))
  ok2, = DashboardRead.validate(d)
  check(ok2, 'gate PASSES once verified:true', fails)
end

# A hand-written png-read.json WITHOUT a `verified` field stays valid (back-compat)
# once the load-bearing fields (bar orientation) are supplied.
Dir.mktmpdir do |d|
  File.write(DashboardRead.path(d), JSON.dump(
    'tiles' => [{ 'title' => 'X', 'kind' => 'bar-chart', 'orientation' => 'horizontal' }],
    'text_elements' => [], 'filter_shelf' => []
  ))
  ok, = DashboardRead.validate(d)
  check(ok, 'hand-written file without a verified field is still accepted (back-compat)', fails)
end

# Bar/combo tile with NO orientation is REJECTED (defaults wrong in the build).
Dir.mktmpdir do |d|
  File.write(DashboardRead.path(d), JSON.dump(
    'tiles' => [{ 'title' => 'X', 'kind' => 'bar-chart' }], 'text_elements' => [], 'filter_shelf' => []
  ))
  ok, errs = DashboardRead.validate(d)
  check(!ok && errs.any? { |e| e =~ /orientation/ }, 'bar-chart without orientation is rejected', fails)
end

# A control that declares no reach (no target_tiles / highlight_tiles) is REJECTED
# — an unscoped page filter silently collapses every tile.
Dir.mktmpdir do |d|
  File.write(DashboardRead.path(d), JSON.dump(
    'tiles' => [{ 'title' => 'X', 'kind' => 'kpi-chart' }], 'text_elements' => [],
    'filter_shelf' => [{ 'label' => 'Region' }]
  ))
  ok, errs = DashboardRead.validate(d)
  check(!ok && errs.any? { |e| e =~ /target_tiles/ }, 'filter_shelf entry without target_tiles is rejected', fails)
end

# A control WITH highlight_tiles now also requires: each highlighted tile carries
# a `measure`, AND a point_in_time block (the multi-metric recipe contract).
def hl_doc(extra = {})
  { 'tiles' => [{ 'title' => 'Trend', 'kind' => 'line-chart' },
                { 'title' => 'Bars', 'kind' => 'bar-chart', 'orientation' => 'horizontal', 'measure' => 'Revenue (current US$)' }],
    'text_elements' => [],
    'filter_shelf' => [{ 'label' => 'Region', 'target_tiles' => ['Trend'], 'highlight_tiles' => ['Bars'] }],
    'point_in_time' => { 'year_column' => 'Year', 'entity_discriminator' => 'Entity Group', 'latest_year' => 2015 } }.merge(extra)
end
Dir.mktmpdir do |d|
  File.write(DashboardRead.path(d), JSON.dump(hl_doc))
  ok, = DashboardRead.validate(d)
  check(ok, 'highlight control WITH measure + point_in_time is accepted', fails)
end
# highlighted tile missing its `measure` → rejected
Dir.mktmpdir do |d|
  bad = hl_doc
  bad['tiles'][1].delete('measure')
  File.write(DashboardRead.path(d), JSON.dump(bad))
  ok, errs = DashboardRead.validate(d)
  check(!ok && errs.any? { |e| e =~ /measure/ }, 'highlight tile without `measure` is rejected', fails)
end
# highlight pattern but no point_in_time → rejected
Dir.mktmpdir do |d|
  bad = hl_doc
  bad.delete('point_in_time')
  File.write(DashboardRead.path(d), JSON.dump(bad))
  ok, errs = DashboardRead.validate(d)
  check(!ok && errs.any? { |e| e =~ /point_in_time/ }, 'highlight pattern without point_in_time is rejected', fails)
end
# A non-temporal source can explicitly prove the snapshot rewrite is not
# applicable while retaining highlight-only control behavior.
Dir.mktmpdir do |d|
  non_temporal = hl_doc(
    'point_in_time' => {
      'not_applicable' => true,
      'reason' => 'single current-state extract with no date field'
    }
  )
  File.write(DashboardRead.path(d), JSON.dump(non_temporal))
  ok, = DashboardRead.validate(d)
  check(ok, 'reasoned non-temporal point_in_time disposition is accepted', fails)
end

# A PARAMETER-driven highlight (not a shared_filter) is surfaced into filter_shelf
# so the multi-metric forcing function can't be skipped. Only tiles that REFERENCE
# the parameter in a calc formula (not the boilerplate redeclaration) are seeded
# as highlight_tiles; point_in_time is seeded too.
Dir.mktmpdir do |d|
  layout = [{ 'dashboard' => 'M', 'zones' => [
    { 'id' => 'bA', 'kind' => 'chart', 'caption' => 'BarA', 'chart_kind' => 'bar' },
    { 'id' => 'bB', 'kind' => 'chart', 'caption' => 'BarB', 'chart_kind' => 'bar' },
    { 'id' => 'tA', 'kind' => 'chart', 'caption' => 'TrendA', 'chart_kind' => 'line' }
  ] }]
  meta = {
    'shared_filters' => [],
    'parameters' => [{ 'name' => '[Parameter 5]', 'caption' => 'Region', 'param_domain' => 'list' }],
    'worksheets' => {
      # BarA/BarB reference the param in a highlight calc; TrendA only carries the
      # boilerplate redeclaration (a bare column named like the param, no ref).
      'BarA'   => { 'calculations' => [{ 'name' => 'hl',  'formula' => 'If([New Region]=[Parameter 5],1,0)' }] },
      'BarB'   => { 'calculations' => [{ 'name' => 'hl2', 'formula' => 'If([New Region]=[Parameter 5],"S","O")' }] },
      'TrendA' => { 'calculations' => [{ 'name' => '[Parameter 5]', 'formula' => '' }] }
    }
  }
  File.write("#{d}/dashboard-layout.json", JSON.dump(layout))
  File.write("#{d}/dashboard-layout-meta.json", JSON.dump(meta))
  doc = JSON.parse(File.read(DashboardRead.seed_from_layout(d)))
  reg = doc['filter_shelf'].find { |f| f['label'] == 'Region' }
  check(reg, 'parameter "Region" surfaced into filter_shelf (not just shared_filters)', fails)
  check(reg && reg['highlight_tiles'].sort == %w[BarA BarB], "highlight = tiles referencing the param (got #{reg && reg['highlight_tiles'].inspect})", fails)
  check(reg && reg['target_tiles'] == ['TrendA'], 'target = the non-referencing tile (TrendA, boilerplate redeclaration only)', fails)
  check(doc['point_in_time'].is_a?(Hash), 'point_in_time seeded once a highlight parameter is present', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — .twb draft seeded; gate still requires visual verification'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
