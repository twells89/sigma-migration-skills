#!/usr/bin/env ruby
# Offline: build-domo-layout.rb's CLI entrypoint (Task 5a) must read its
# geometry from discovery/cards.json (Task 1's DomoSigma.merge_geometry
# output) + discovery/pages.json (for the page/dashboard name) and produce a
# TRUE 2D discovery/dashboard-layout.json — not the old single-column
# auto-stack a missing/duplicate discovery/layout/<pageId>.json path used to
# force. Exercises the actual `if $PROGRAM_NAME == __FILE__` main block (via
# subprocess, like test-e2e.rb), not just the build_dashboard function
# test-layout-tag.rb already covers.
#
#   ruby test/test-build-domo-layout.rb

require 'json'
require 'fileutils'
require 'tmpdir'

SKILL   = File.expand_path('..', __dir__)
SCRIPTS = File.join(SKILL, 'scripts')
$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

Dir.mktmpdir('domo-build-layout') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }

  # Two cards share a y-band (y=0) at DISTINCT x — a real 2D layout (side by
  # side), which a single-column auto-stack would never produce. A third card
  # sits in a second row. A geometry-less card and an error-tagged card are
  # included to prove both get filtered out rather than crashing/auto-placed.
  w.call('cards.json', [
    { 'id' => 'c1', 'title' => 'Revenue', 'chartType' => 'badge_vert_bar',
      'x' => 0,  'y' => 0,  'w' => 40, 'h' => 50 },
    { 'id' => 'c2', 'title' => 'Costs',   'chartType' => 'badge_vert_bar',
      'x' => 40, 'y' => 0,  'w' => 40, 'h' => 50 },
    { 'id' => 'c3', 'title' => 'Detail',  'chartType' => 'table',
      'x' => 0,  'y' => 50, 'w' => 80, 'h' => 30 },
    { 'id' => 'c4', 'title' => 'NoGeom',  'chartType' => 'table' },
    { 'id' => 'c5', 'title' => 'Broken',  '_error' => 'card definition unavailable' },
  ])
  w.call('pages.json', [{ 'id' => 'p1', 'title' => 'Overview', 'cardIds' => %w[c1 c2 c3 c4 c5] }])

  # The point of Task 5a: this must work with NO discovery/layout/ dir at all
  # (the old duplicate-geometry path from domo-capture-visuals.rb). Assert the
  # tmp discovery dir genuinely has none before running.
  ok(!Dir.exist?(File.join(dir, 'layout')), "sanity: no discovery/layout/ present before running the script")

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "build-domo-layout.rb exits 0 reading cards.json + pages.json only (no discovery/layout/)\n#{out unless status}")

  out_path = File.join(dir, 'dashboard-layout.json')
  ok(File.exist?(out_path), 'wrote discovery/dashboard-layout.json')
  dashboards = JSON.parse(File.read(out_path))

  eq(dashboards.size, 1, 'one dashboard (one page)')
  dash = dashboards.first
  eq(dash['dashboard'], 'Overview', "dashboard name comes from pages.json's title, keyed by page id")

  zones = dash['zones']
  eq(zones.size, 3, 'only the 3 geometry-bearing cards became zones (NoGeom + _error card excluded)')
  ok(zones.map { |z| z['id'] }.sort == %w[c1 c2 c3], 'zone ids are exactly the geometry-bearing cards')

  z1 = zones.find { |z| z['id'] == 'c1' }
  z2 = zones.find { |z| z['id'] == 'c2' }
  z3 = zones.find { |z| z['id'] == 'c3' }

  # The 2D assertion: c1 and c2 share a y-band (same row) but sit at DISTINCT
  # x_pct — a true zone-tree layout, not a single-column auto-stack (which
  # would give every zone the same x_pct and only vary y_pct).
  eq(z1['y_pct'], z2['y_pct'], 'c1 and c2 are on the same y-band (row)')
  ok(z1['x_pct'] != z2['x_pct'], 'c1 and c2 sit at DISTINCT x_pct on that shared row — a real 2D layout')
  ok(zones.map { |z| z['x_pct'] }.uniq.size >= 2, 'multiple distinct x_pct values across the dashboard (multi-column)')
  ok(z3['y_pct'] > z1['y_pct'], 'c3 (second row) has a greater y_pct than the first row')
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
