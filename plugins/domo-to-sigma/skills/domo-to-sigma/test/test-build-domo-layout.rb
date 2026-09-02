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
require_relative '../scripts/lib/zone_census' # ZoneCensus — same grid-vs-stack rule migrate-domo.rb uses

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

# ===========================================================================
# I1 (final review, Important): a companion KPI element (bead 08sf) on a page
# that uses RUNG 1 (genuine x/y/w/h pixel geometry, build_dashboard) — the
# exact shape test/fixtures/domo-estate/ (the migrate-domo.rb e2e fixture)
# uses. rung 1's own geometry filter would otherwise silently drop the
# companion pseudo-card (it never carries x/y/w/h) even though every real
# card on the page has pixel geometry — append_geometryless_remainder is
# what rescues it. Distinct from the rung-2a coverage above (the
# domo-nogeom fixture, where NO card has pixel geometry at all).
# ===========================================================================
Dir.mktmpdir('domo-build-layout-rung1-companion') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }
  w.call('cards.json', [
    { 'id' => 'bar1', 'title' => 'Sales by Region', 'chartType' => 'badge_vert_bar',
      'x' => 0, 'y' => 0, 'w' => 100, 'h' => 30 },
  ])
  w.call('pages.json', [{ 'id' => 'p1', 'title' => 'Overview', 'cardIds' => %w[bar1] }])
  w.call('chart-specs.json', { 'pages' => [{ 'name' => 'Overview', 'elements' => [
    { 'id' => 'el-bar1', 'kind' => 'bar-chart', 'name' => 'Sales by Region' },
    { 'id' => 'el-bar1-summary', 'kind' => 'kpi-chart', 'name' => 'Total Sales' },
  ] }] })

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-domo-layout.rb exits 0 on a rung-1 (pixel geometry) page carrying a companion KPI\n#{out unless $?.success?}")

  dash = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json'))).first
  z_bar = dash['zones'].find { |z| z['id'].to_s == 'bar1' }
  z_comp = dash['zones'].find { |z| z['id'].to_s == 'el-bar1-summary' }
  ok(z_bar, "the real, pixel-geometry-bearing card's own zone is still placed (rung 1 unaffected)")
  ok(z_comp, "the companion KPI (no geometry of its own) STILL gets a zone on a rung-1 page, " \
             'not silently dropped by build_dashboard\'s own x/y/w/h filter (I1)')
  if z_comp && z_bar
    ok(z_comp['y_pct'].to_f >= z_bar['y_pct'].to_f + z_bar['h_pct'].to_f - 0.01,
       "the companion's zone is appended BELOW the real content, not overlapping it")
    eq(z_comp['caption'], 'Total Sales', "the companion zone's caption is its own name")
  end
end

# ===========================================================================
# F3 / blocker 3 (2026-08-05 batch-verify): pages.json's cardIds is unreliable
# (GET /v1/pages/{id} reports cardIds: [] even for a page that genuinely owns
# every card — domo-discover.rb's "Bug 1 (P0)"). When that happens and there
# is exactly ONE page in scope, this file must fall back to that page's REAL
# title — the SAME fallback build-workbook.rb's group_cards_by_page already
# uses (see test-build-workbook.rb's own F3 tests) — not the literal
# 'Overview'. Before this fix, build-domo-layout.rb still hard-coded
# 'Overview' while build-workbook.rb had already been fixed to use the real
# title, so load_chart_specs_companions'/load_chart_specs_controls' page-NAME
# keyed lookup missed every companion/control: measured on the real cold run,
# 50 zones w/ 5 companion KPIs (name-matched) vs 45 zones w/ 0 companion KPIs
# (as-landed, before this fix). Reproduced at fixture scale below: a companion
# KPI keyed under the page's real title in chart-specs.json must still reach
# a zone even though pages.json's cardIds is empty.
# ===========================================================================
Dir.mktmpdir('domo-build-layout-f3-page-name') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }
  w.call('cards.json', [
    { 'id' => 'c1', 'title' => 'Revenue', 'chartType' => 'badge_vert_bar',
      'x' => 0, 'y' => 0, 'w' => 100, 'h' => 30 },
  ])
  # Deliberately cardIds: [] (the real Domo shape) on a title that is NOT
  # 'Overview' — the exact real-data mismatch (page 'Sample DataSets +
  # Cards', pages.json's cardIds: []).
  w.call('pages.json', [{ 'id' => 59931332, 'title' => 'Sample DataSets + Cards', 'cardIds' => [] }])
  w.call('chart-specs.json', { 'pages' => [{ 'name' => 'Sample DataSets + Cards', 'elements' => [
    { 'id' => 'el-c1', 'kind' => 'bar-chart', 'name' => 'Revenue' },
    { 'id' => 'el-c1-summary', 'kind' => 'kpi-chart', 'name' => 'Total Revenue' },
  ] }] })

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-domo-layout.rb exits 0 with an empty cardIds and a companion KPI keyed by the " \
                   "page's real title\n#{out unless $?.success?}")

  dashboards = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json')))
  ok(dashboards.none? { |d| d['dashboard'] == 'Overview' },
     "the placeholder 'Overview' name is NOT used when there is exactly one real page in scope (F3)")
  dash = dashboards.find { |d| d['dashboard'] == 'Sample DataSets + Cards' }
  ok(dash, "the dashboard is named after the page's REAL title, not 'Overview' " \
           "(dashboards seen: #{dashboards.map { |d| d['dashboard'] }.inspect})")
  if dash
    z_comp = dash['zones'].find { |z| z['id'].to_s == 'el-c1-summary' }
    ok(z_comp, 'the companion KPI (chart-specs.json, keyed by the REAL page title) reaches a zone — ' \
               "before this fix it was silently dropped (page-NAME mismatch: 'Overview' vs the real title)")
    eq(z_comp['caption'], 'Total Revenue', 'the recovered companion zone is captioned with its own name') if z_comp
  end
end

# ===========================================================================
# F3 / blocker 3 cross-file consistency: build-workbook.rb's
# group_cards_by_page and build-domo-layout.rb's group_cards_by_page_for_layout
# MUST resolve the same default page name for the same pages.json input — a
# mismatch here is exactly what silently drops layout zones (see above). Both
# real functions are exercised directly (not re-implemented here) so a future
# edit to either one's fallback logic that de-syncs them fails this test.
# ===========================================================================
# Both scripts independently assign OUT = ENV['DOMO_DISCOVERY_DIR'] || ... at
# their own top level (same value, never read below) — requiring both in one
# process trips Ruby's unconditional "already initialized constant" notice.
# Silence just that, not real warnings from the assertions below.
old_verbose = $VERBOSE
$VERBOSE = nil
require_relative '../scripts/build-workbook'
require_relative '../scripts/build-domo-layout' # group_cards_by_page_for_layout lives here
$VERBOSE = old_verbose

[
  ['single page, empty cardIds -> falls back to the page\'s real title',
   [{ 'id' => 'card-1' }, { 'id' => 'card-2' }],
   [{ 'id' => 59931332, 'title' => 'Sample DataSets + Cards', 'cardIds' => [] }]],
  ['multiple pages, no reliable attribution -> both fall back to the honest Overview placeholder',
   [{ 'id' => 'card-1' }, { 'id' => 'card-2' }],
   [{ 'id' => 1, 'title' => 'Page One', 'cardIds' => [] }, { 'id' => 2, 'title' => 'Page Two', 'cardIds' => [] }]],
  ['reliable cardIds present -> both honor the real per-page attribution identically',
   [{ 'id' => 'card-1' }, { 'id' => 'card-2' }],
   [{ 'id' => 1, 'title' => 'Page One', 'cardIds' => ['card-1'] }, { 'id' => 2, 'title' => 'Page Two', 'cards' => ['card-2'] }]],
].each do |desc, cards, pages|
  from_workbook = group_cards_by_page(cards, pages)
  from_layout   = group_cards_by_page_for_layout(cards, pages)
  eq(from_workbook.keys.sort, from_layout.keys.sort, "#{desc} — page names agree")
  from_workbook.each do |pname, pcards|
    eq(pcards.map { |c| c['id'] }.sort, Array(from_layout[pname]).map { |c| c['id'] }.sort,
       "#{desc} — page '#{pname}' gets the SAME cards from both functions")
  end
end

# ===========================================================================
# Live-validation fix (refs/live-validation-2026-07-30.md): a real classic
# Domo page's private read carries NO x/y/w/h at all — only a per-card
# T-shirt size token (stacks['sizes']) and titled collections[] grouping
# cards by index. This ran the OLD build-domo-layout.rb straight into its
# "no geometry" abort (or, before that, a silent single-column stack — the
# exact fidelity bug a partner migration hit). Exercised here through the
# REAL subprocess entrypoint (not just the build_dashboard_from_collections
# function — test-layout-tag.rb already covers that directly), so a
# regression in how the CLI wires cards.json -> the fallback chain fails
# this test even if the individual functions still work in isolation.
#
# Field shapes below ('_size', '_collection', '_pageOrder') mirror
# DomoSigma.merge_geometry's actual Bug 5 output (lib/domo_sigma_util.rb) —
# see build-domo-layout.rb's header comment for the full field-name contract.
#   ruby test/test-build-domo-layout.rb
# ===========================================================================
Dir.mktmpdir('domo-build-layout-classic') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }

  # Page "Classic Overview": NO card carries x/y/w/h anywhere — only
  # '_collection'/'_size'/'_pageOrder' (merge_geometry's Bug 5 fields). k1+k2
  # are two 'medium' cards in collection "Team Alpha" -> must land side by
  # side in ONE row. k3 is alone in "Team Beta" with an UNKNOWN size token ->
  # must warn and default to 'medium'. k4 has NO collection and NO size token
  # at all (the true "Domo gave us nothing" shape, refs/
  # layout-visual-qa.md's "2a" kind-aware default composition) -> must still
  # be placed (trailing ungrouped section), never silently dropped, and — as
  # a table-kind card with no width signal of its own — gets the FULL-WIDTH
  # table treatment (compose_kind_aware_rows' table_rows_for), not the flat
  # 'medium' 50% every other kind used to get here too.
  w.call('cards.json', [
    { 'id' => 'k1', 'title' => 'Alpha One', 'chartType' => 'badge_vert_bar', '_size' => 'medium',
      '_collection' => { 'id' => 100, 'title' => 'Team Alpha', 'index' => 0 }, '_pageOrder' => 0 },
    { 'id' => 'k2', 'title' => 'Alpha Two', 'chartType' => 'badge_vert_bar', '_size' => 'medium',
      '_collection' => { 'id' => 100, 'title' => 'Team Alpha', 'index' => 1 }, '_pageOrder' => 1 },
    { 'id' => 'k3', 'title' => 'Beta One', 'chartType' => 'badge', '_size' => 'huge-token',
      '_collection' => { 'id' => 101, 'title' => 'Team Beta', 'index' => 2 }, '_pageOrder' => 2 },
    { 'id' => 'k4', 'title' => 'Loose Card', 'chartType' => 'table', '_pageOrder' => 3 },
    # Page "Totally Blank"'s cards: NO x/y/w/h, no '_size'/'_collection'/
    # '_pageOrder', no preferredFullWidth/Height — the true last-resort case.
    # Must NOT abort; must fall to the loud-warning single-column stack (rung 3).
    { 'id' => 'm1', 'title' => 'Blank One', 'chartType' => 'badge_vert_bar' },
    { 'id' => 'm2', 'title' => 'Blank Two', 'chartType' => 'table' },
  ])
  w.call('pages.json', [
    { 'id' => 'p2', 'title' => 'Classic Overview', 'cardIds' => %w[k1 k2 k3 k4] },
    { 'id' => 'p3', 'title' => 'Totally Blank', 'cardIds' => %w[m1 m2] },
  ])

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "build-domo-layout.rb exits 0 on a page with NO x/y/w/h (collections+size only) " \
             "and a page with NO geometry signal at all\n#{out unless status}")
  ok(out.include?('huge-token') && out.include?('medium'),
     "the unrecognized size token 'huge-token' WARNS on stderr (captured via the combined subprocess output)")
  ok(out.include?('WARNING') && out.include?('Totally Blank'),
     "the geometry-less 'Totally Blank' page prints the loud last-resort stack WARNING, named, on stderr")

  dashboards = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json')))
  classic = dashboards.find { |d| d['dashboard'] == 'Classic Overview' }
  blank   = dashboards.find { |d| d['dashboard'] == 'Totally Blank' }
  ok(classic && blank, 'both pages produced a dashboard (neither aborted despite having no x/y/w/h)')

  # ---- "Classic Overview": collections -> heading zones + a real 2D grid --
  czones = classic['zones']
  hdr_a = czones.find { |z| z['kind'] == 'text' && z['caption'] == 'Team Alpha' }
  hdr_b = czones.find { |z| z['kind'] == 'text' && z['caption'] == 'Team Beta' }
  ok(hdr_a && hdr_b, "each collection's title became its own heading zone (Sigma section heading)")
  ok(hdr_a['y_pct'] < hdr_b['y_pct'], "headings ordered top-to-bottom by their cards' _pageOrder")

  zk1 = czones.find { |z| z['id'] == 'k1' }
  zk2 = czones.find { |z| z['id'] == 'k2' }
  zk3 = czones.find { |z| z['id'] == 'k3' }
  zk4 = czones.find { |z| z['id'] == 'k4' }
  eq(zk1['y_pct'], zk2['y_pct'], "k1/k2 (both 'medium', same collection) share a row")
  ok(zk1['x_pct'] != zk2['x_pct'], 'k1/k2 sit at DISTINCT x_pct on that shared row — a real 2D grid')
  eq(zk1['w_pct'], 50.0, "a 'medium' card is 3 of Domo's 6 native grid cols -> 50% width")
  eq(zk3['w_pct'], 50.0, "k3's UNRECOGNIZED size token defaulted to 'medium' -> still 50% width, not dropped/zero")
  # k4 alone has NO width signal at all (no '_size' key, no preferred*): the
  # kind-aware default composition applies, and its kind (chartType 'table',
  # no sigmaKindHint/chart-specs override here) puts it on its OWN full-width
  # row — the fix this task exists for (a table used to get the same flat
  # 'medium' 50% as everything else; see git history of this assertion).
  eq(zk4['w_pct'], 100.0, "k4 (table kind, no width signal at all) gets the FULL-WIDTH table " \
                          'treatment, not the old flat 50% default')
  eq(zk4['chart_kind'], 'table', "k4's zone is tagged chart_kind 'table' (resolved via kind_hint(chartType), " \
                                 'no sigmaKindHint/chart-specs override present in this fixture)')
  ok(zk4['y_pct'] > zk3['y_pct'] && zk3['y_pct'] > zk1['y_pct'],
     'section order preserved end to end: Team Alpha row, then Team Beta row, then the trailing ungrouped card')

  content = ZoneCensus.content_zones(czones)
  by_row = content.group_by { |z| z['y_pct'].to_f.round(1) }
  grid = by_row.values.any? { |zs| zs.map { |z| z['x_pct'].to_f.round(1) }.uniq.size >= 2 }
  ok(grid, "'Classic Overview' classifies as a GRID under migrate-domo.rb's own layout-2d.flag rule " \
           "(>= 2 distinct x_pct sharing a row) — NOT 'stack'; this is the P0 fidelity fix")

  # ---- "Totally Blank": last-resort single-column stack, but never silent --
  bzones = blank['zones']
  eq(bzones.map { |z| z['x_pct'] }.uniq, [0.0], "'Totally Blank' zones are single-column (x_pct 0)")
  eq(bzones.map { |z| z['w_pct'] }.uniq, [100.0], "'Totally Blank' zones are full width (100%)")
  bcontent = ZoneCensus.content_zones(bzones)
  bby_row = bcontent.group_by { |z| z['y_pct'].to_f.round(1) }
  bgrid = bby_row.values.any? { |zs| zs.map { |z| z['x_pct'].to_f.round(1) }.uniq.size >= 2 }
  ok(!bgrid, "'Totally Blank' correctly classifies as 'stack' (no geometry signal at all was ever provided)")
end

# ===========================================================================
# Phase 5e visual-QA fix, CLI/subprocess level (unit coverage of the same
# fix lives in test-layout-tag.rb, function-level). Fixture SHAPE derived
# from a real 15-card/3-page no-geometry live discovery run (anonymized) —
# see test/fixtures/domo-nogeom/: EVERY card carries the live API-created-
# card shape ('_size' => "", no '_collection'), so the WHOLE run exercises
# rung 2a (compose_kind_aware_rows), not the per-card token-default path.
# Also exercises the CLI's chart-specs.json wiring end to end: card 2004's
# cards.json sigmaKindHint says 'bar-chart', but chart-specs.json (as
# build-workbook.rb would write it after resolving the real element) says
# 'combo-chart' for that same card — the resolved zone must reflect the
# LATTER, proving load_chart_specs_kind_map is actually wired into the real
# entrypoint, not just reachable in isolation. And: chart-specs.json's
# "Detail" page also carries "ctl-region-filter" (kind 'control') — a control
# with NO backing card in cards.json at all, mirroring the REAL live Tier-2
# "ctl-order_status" element (refs/live-validation-2026-07-30.md) — proving
# load_chart_specs_controls's orphan-control synthesis is wired into the real
# entrypoint too.
# ===========================================================================
Dir.mktmpdir('domo-build-layout-nogeom') do |dir|
  fixture = File.join(__dir__, 'fixtures', 'domo-nogeom')
  %w[cards.json pages.json chart-specs.json].each do |f|
    FileUtils.cp(File.join(fixture, f), File.join(dir, f))
  end

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "build-domo-layout.rb exits 0 on the anonymized no-geometry fixture\n#{out unless status}")

  dashboards = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json')))
  overview = dashboards.find { |d| d['dashboard'] == 'Overview' }
  detail   = dashboards.find { |d| d['dashboard'] == 'Detail' }
  ok(overview && detail, 'both pages produced a dashboard through the real CLI entrypoint')

  # ---- "Overview": 4 interleaved KPIs -> one compact row; 2 charts -> paired --
  ozones = overview['zones']
  kpi_ids = %w[1001 1003 1004 1006]
  kpi_zones = kpi_ids.map { |id| ozones.find { |z| z['id'].to_s == id } }
  chart_zones = %w[1002 1005].map { |id| ozones.find { |z| z['id'].to_s == id } }
  ok(kpi_zones.all? && chart_zones.all?, 'every card from the fixture was placed')

  eq(kpi_zones.map { |z| z['y_pct'] }.uniq.length, 1,
     'all 4 KPIs (interleaved with 2 charts in the source _pageOrder, exactly like the real ' \
     'live discovery run) share ONE row through the real CLI entrypoint')
  eq(kpi_zones.map { |z| z['w_pct'] }, [25.0, 25.0, 25.0, 25.0], '4 KPIs sharing a row -> 25% each end to end')
  eq(chart_zones.map { |z| z['y_pct'] }.uniq.length, 1, 'the 2 charts pair onto their OWN single row')
  eq(chart_zones.map { |z| z['w_pct'] }, [50.0, 50.0], 'the 2 paired charts are 50% each end to end')
  ok(chart_zones.first['y_pct'] > kpi_zones.first['y_pct'], 'the chart row sits below the KPI row')

  # ---- "Detail": chart-specs.json's resolved kind wins over sigmaKindHint --
  dzones = detail['zones']
  z_combo = dzones.find { |z| z['id'].to_s == '2004' }
  ok(z_combo, 'card 2004 was placed')
  eq(z_combo['chart_kind'], 'combo-chart',
     "card 2004's zone reflects chart-specs.json's resolved 'combo-chart' — NOT cards.json's own " \
     "sigmaKindHint ('bar-chart') — proving the CLI entrypoint actually loads and prefers " \
     'discovery/chart-specs.json (load_chart_specs_kind_map), not just in an isolated unit call')
  eq(z_combo['w_pct'], 100.0,
     "card 2004 is the ODD one out among 3 charts on 'Detail' (donut+bar pair, then this lone " \
     'trailing chart) -> full width, exactly as test-layout-tag.rb\'s function-level Page B case')

  ztable = dzones.find { |z| z['id'].to_s == '2003' }
  eq(ztable['w_pct'], 100.0, "'Detail Table' gets full width")
  ok(ztable['h_pct'] > z_combo['h_pct'], "the table's row is taller than a chart row end to end")

  # ---- "Detail": chart-specs-only orphan control ("ctl-region-filter") ----
  z_ctl = dzones.find { |z| z['id'].to_s == 'ctl-region-filter' }
  ok(z_ctl, "the orphan control (NO backing card in cards.json — synthesized purely from " \
            "chart-specs.json's 'control'-kind element, mirroring the real ctl-order_status case) " \
            'still produced a zone through the real CLI entrypoint')
  eq(z_ctl['kind'], 'filter', "the orphan control's zone is kind 'filter'")
  eq(z_ctl['caption'], 'Region Filter', "the zone's caption is the control's OWN name (the join key " \
                                        'downstream zone_el_name/assign_controls matching needs), not its raw id')
  eq(z_ctl['w_pct'], 100.0, 'the sole control on this page spans the full control band width')
  ok(z_ctl['y_pct'] < z_combo['y_pct'] && z_ctl['y_pct'] < ztable['y_pct'],
     'the control band sits ABOVE every other band on the page (house-style order: control -> ... -> table)')

  # ---- "Detail": chart-specs-only companion KPI ("el-2003-summary", bead ----
  # 08sf) — final review Important I1: a companion KPI has no card of its own
  # either (build-workbook.rb synthesizes it from card 2003, the "Detail
  # Table" card), so without load_chart_specs_companions it would never reach
  # composition_class and would silently have no layout zone at all, even
  # though it IS present in the workbook spec. Proves the fix is wired into
  # the real CLI entrypoint, not just reachable in isolation.
  z_comp = dzones.find { |z| z['id'].to_s == 'el-2003-summary' }
  ok(z_comp, "the orphan companion KPI (NO backing card in cards.json — synthesized purely from " \
             "chart-specs.json's 'kpi-chart' + '-summary'-suffixed element) still produced a zone " \
             'through the real CLI entrypoint (I1)')
  if z_comp
    eq(z_comp['kind'], 'chart', "the companion's zone kind is 'chart' (not 'filter' — it's a KPI, not a control)")
    eq(z_comp['chart_kind'], 'kpi', "the companion's zone chart_kind is the LOGICAL 'kpi' token " \
                                     "(zone_chart_kind_for normalizes the Sigma element kind 'kpi-chart')")
    eq(z_comp['caption'], 'Detail Table Total', "the zone's caption is the companion's OWN name — " \
                                                 'downstream zone_el_name/els_by_name matching keys on ' \
                                                 'name, not id, so this must be exact')
    ok(z_comp['w_pct'].to_f.positive? && z_comp['h_pct'].to_f.positive?, 'the companion zone has a real, non-zero footprint')
  end
end

# ===========================================================================
# discovery/layout-observed.json wired through the REAL CLI entrypoint
# (function-level coverage of build_dashboard_with_observed itself lives in
# test-layout-tag.rb). A typo'd sidecar key (matching no card at all) must
# WARN, never silently do nothing — same discipline as an unrecognized size
# token.
# ===========================================================================
Dir.mktmpdir('domo-build-layout-observed') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }
  w.call('cards.json', [
    { 'id' => 'ov1', 'title' => 'Observed Chart', 'chartType' => 'badge_vert_bar', '_size' => '', '_pageOrder' => 0 },
    { 'id' => 'ov2', 'title' => 'Composed Chart', 'chartType' => 'badge_vert_bar', '_size' => '', '_pageOrder' => 1 },
    { 'id' => 'ov3', 'title' => 'Observed KPI', 'chartType' => 'badge_singlevalue', '_size' => '', '_pageOrder' => 2 },
  ])
  w.call('pages.json', [{ 'id' => 'p1', 'title' => 'Observed Page', 'cardIds' => %w[ov1 ov2 ov3] }])
  w.call('chart-specs.json', {
    'pages' => [{
      'name' => 'Observed Page',
      'elements' => [
        { 'id' => 'el-ov1', 'kind' => 'bar-chart', 'name' => 'Observed Chart' },
        { 'id' => 'el-ov1-summary', 'kind' => 'kpi-chart', 'name' => 'Observed Total' },
        { 'id' => 'el-ov3', 'kind' => 'kpi-chart', 'name' => ' ' },
        { 'id' => 'header-kpi-ov3', 'kind' => 'text', 'name' => nil },
      ],
    }],
  })
  w.call('layout-observed.json', {
    'ov1' => { 'x' => 0.0, 'y' => 0.0, 'w' => 0.4, 'h' => 0.15 },
    'ov3' => { 'x' => 0.5, 'y' => 0.0, 'w' => 0.4, 'h' => 0.15 },
    'nonexistent-card-id' => { 'x' => 0.0, 'y' => 0.0, 'w' => 1.0, 'h' => 1.0 }, # typo -> must WARN
  })

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "build-domo-layout.rb exits 0 with a layout-observed.json sidecar present\n#{out unless status}")
  ok(out.include?('nonexistent-card-id'),
     "an observed-layout key matching NO card WARNS by name on stderr (captured via the combined subprocess output)")

  dash = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json'))).find { |d| d['dashboard'] == 'Observed Page' }
  zov1 = dash['zones'].find { |z| z['id'] == 'ov1' }
  zov2 = dash['zones'].find { |z| z['id'] == 'ov2' }
  zsum = dash['zones'].find { |z| z['id'] == 'el-ov1-summary' }
  eq([zov1['x_pct'], zov1['y_pct'], zov1['w_pct'], zov1['h_pct']], [0.0, 3.6, 40.0, 11.4],
     "ov1's observed card rectangle reserves its top 24% for the source Summary Number")
  eq([zsum['x_pct'], zsum['y_pct'], zsum['w_pct'], zsum['h_pct']], [0.0, 0.0, 40.0, 3.6],
     'the companion KPI occupies that source-card header area instead of a bottom KPI band')
  eq(zsum['_source'], 'observed-from-screenshot-summary',
     'the companion placement is explicitly tagged as screenshot-derived')
  eq(zov1['_source'], 'observed-from-screenshot', "ov1's zone is tagged _source, end to end")
  card_container = dash['zone_tree'].find { |z| z['id'] == 'dc-ov1' }
  ok(card_container && card_container['kind'] == 'container',
     'observed chart + companion KPI stay grouped in one source-card container')
  eq(card_container['children'].map { |child| child['id'] }, %w[el-ov1-summary el-ov1],
     'source-card container places the summary above its primary chart')
  kpi_container = dash['zone_tree'].find { |z| z['id'] == 'dc-ov3' }
  eq(kpi_container['children'].map { |child| child['id'] }, %w[header-kpi-ov3 el-ov3],
     'screenshot-backed KPI header stays inside its observed source card')
  ok(zov2['_source'].nil?, 'ov2 (not in the sidecar) falls back to the kind-aware default composition, untagged')
  ok(zov2['y_pct'] > zov1['y_pct'], 'the composed remainder (ov2) is placed below the observed region, end to end')
end

# ===========================================================================
# bead wmkf: a KPI-kind card's ZONE caption must match the name build_kpi
# (build-workbook.rb) will actually give the built Sigma element — it prefers
# the card's Summary Number label over the card's own title (Domo lets an
# author label a tile differently from the card's own title; the label is
# what actually renders ON the KPI). Regression for a real live bug: a card
# titled "Units Ordered" but labeled "Units" on the tile itself produced a
# zone captioned "Units Ordered", which build-dashboard-layout.rb's NAME-based
# zone matcher (els_by_name, keyed on the real built element's name "Units")
# could never match — silently dropping the KPI out of the shared top KPI row
# and into the generic "no zone matched" bottom-band fallback instead.
#
# No card here carries x/y/w/h, '_collection', or a real '_size' token, so
# every card routes through rung 2a (compose_kind_aware_rows / kpi_rows_for)
# — the same call site (build-domo-layout.rb's row-tuple `chart_kind`
# destructure) the real live bug (card id 390868622) was reproduced through.
# ===========================================================================
Dir.mktmpdir('domo-build-layout-kpi-caption') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }
  w.call('cards.json', [
    { 'id' => 'kpi-label-diff', 'title' => 'Units Ordered', 'chartType' => 'badge_singlevalue',
      'summaryNumber' => { 'column' => 'QUANTITY_ORDERED', 'aggregation' => 'SUM', 'label' => 'Units' },
      '_size' => '', '_pageOrder' => 0 },
    { 'id' => 'kpi-label-same', 'title' => 'Orders', 'chartType' => 'badge_singlevalue',
      'summaryNumber' => { 'column' => 'ORDER_ID', 'aggregation' => 'COUNT', 'label' => 'Orders' },
      '_size' => '', '_pageOrder' => 1 },
    { 'id' => 'kpi-label-blank', 'title' => 'Net Revenue', 'chartType' => 'badge_singlevalue',
      'summaryNumber' => { 'column' => 'NET_REVENUE', 'aggregation' => 'SUM', 'label' => '' },
      '_size' => '', '_pageOrder' => 2 },
    { 'id' => 'kpi-no-summary', 'title' => 'Gross Profit', 'chartType' => 'badge_singlevalue',
      '_size' => '', '_pageOrder' => 3 },
  ])
  w.call('pages.json', [{ 'id' => 'p1', 'title' => 'KPI Caption Page',
                          'cardIds' => %w[kpi-label-diff kpi-label-same kpi-label-blank kpi-no-summary] }])

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "build-domo-layout.rb exits 0 on a page of KPI cards whose title/summaryNumber.label vary\n#{out unless status}")

  dash = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json'))).find { |d| d['dashboard'] == 'KPI Caption Page' }
  zones = dash['zones']

  z_diff  = zones.find { |z| z['id'] == 'kpi-label-diff' }
  z_same  = zones.find { |z| z['id'] == 'kpi-label-same' }
  z_blank = zones.find { |z| z['id'] == 'kpi-label-blank' }
  z_none  = zones.find { |z| z['id'] == 'kpi-no-summary' }
  ok(z_diff && z_same && z_blank && z_none, 'every KPI card in the fixture was placed')

  eq(z_diff['caption'], 'Units',
     "bead wmkf: a KPI whose summaryNumber.label ('Units') differs from its card title ('Units Ordered') " \
     'gets a zone captioned with the LABEL — the same name build_kpi actually gives the built Sigma element')
  eq(z_same['caption'], 'Orders', 'a KPI whose label already matches its title is unaffected (unchanged behavior)')
  eq(z_blank['caption'], 'Net Revenue',
     'a KPI with a BLANK summaryNumber.label falls back to the card title, unchanged (regression guard)')
  eq(z_none['caption'], 'Gross Profit',
     'a KPI card with no summaryNumber at all falls back to the card title, unchanged (regression guard)')
end

Dir.mktmpdir('domo-build-layout-v4-content') do |dir|
  w = ->(name, obj) { File.write(File.join(dir, name), JSON.generate(obj)) }
  w.call('cards.json', [
    { 'id' => 'c1', 'title' => 'Revenue', 'chartType' => 'badge_vert_bar',
      'x' => 0, 'y' => 2, 'w' => 24, 'h' => 8 },
  ])
  w.call('pages.json', [{
    'id' => 'p1', 'title' => 'Printable', 'cardIds' => ['c1'],
    '_layoutContent' => [
      { 'id' => 'domo-layout-p1-header-1', 'type' => 'header', 'text' => 'Revenue section',
        'x' => 0, 'y' => 0, 'w' => 24, 'h' => 2 },
      { 'id' => 'domo-layout-p1-page-break-2', 'type' => 'page-break',
        'x' => 0, 'y' => 10, 'w' => 24, 'h' => 1 },
    ],
  }])

  env = { 'DOMO_DISCOVERY_DIR' => dir }
  out = IO.popen(env, ['ruby', File.join(SCRIPTS, 'build-domo-layout.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-domo-layout.rb exits 0 with authored v4 header/page-break content\n#{out unless $?.success?}")
  dash = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json'))).first
  header = dash['zones'].find { |zone| zone['id'] == 'domo-layout-p1-header-1' }
  page_break = dash['zones'].find { |zone| zone['id'] == 'domo-layout-p1-page-break-2' }
  eq(header && header['chart_kind'], 'text', 'v4 HEADER reaches layout as a text zone')
  eq(header && header['caption'], 'Revenue section', 'v4 HEADER keeps its authored caption')
  eq(page_break && page_break['chart_kind'], 'page-break', 'v4 PAGE_BREAK reaches layout as a page-break zone')
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
