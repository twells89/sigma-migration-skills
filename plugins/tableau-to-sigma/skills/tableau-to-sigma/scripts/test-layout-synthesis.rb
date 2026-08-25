#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-layout-synthesis.rb — E1/E2 layout synthesis regression tests.
#
# Covers the structure-aware synthesis in build-dashboard-layout.rb (workstream
# E of the v3 consistency plan — the 10/10 hand-rolled-layout rate fix):
#   - SigmaLayout band detection (pure): KPI rows (x-disjoint, similar height),
#     sidebar rails, header text zones
#   - E1 per-kind minimum row spans: expansion + push-down never overlaps
#   - KPI rows emit ONE Container, equal inner spans, inner gridRow
#     matching the container span (the KPI-sliver rule)
#   - sidebar rail: vertical repeat(1,1fr) container of stacked controls;
#     the content grid gets the remaining columns
#   - census: exact-compatible pages + new bands_detected/min_row_expansions
#   - determinism: two runs produce byte-identical outputs
#
# Fixtures are minimal derivations of real live-migration zone trees
# (supermart-sales' header + KPI band; superstore-performance's left
# filter/param rail). Offline, creds-free. Run: ruby scripts/test-layout-synthesis.rb

require 'json'
require 'rexml/document'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/layout'
require_relative 'lib/layout_lint'

BUILD = File.join(__dir__, 'build-dashboard-layout.rb')
RUBY  = RbConfig.ruby

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def build(dl, wb, dir, extra = [])
  File.write(File.join(dir, 'dl.json'), JSON.generate(dl))
  File.write(File.join(dir, 'wb.json'), JSON.generate(wb))
  out = File.join(dir, 'layout.xml')
  log = IO.popen([RUBY, BUILD, '--layout', File.join(dir, 'dl.json'), '--wb-ids', File.join(dir, 'wb.json'), '--out', out, *extra], err: %i[child out], &:read)
  xml = File.exist?(out) ? File.read(out) : nil
  census = File.exist?(File.join(dir, 'layout-census.json')) ? JSON.parse(File.read(File.join(dir, 'layout-census.json'))) : nil
  elements = File.exist?("#{out}.elements.json") ? File.read("#{out}.elements.json") : nil
  [xml, census, log, elements]
end

def doc_for(xml)
  REXML::Document.new("<Root>#{xml.sub(/\A<\?xml[^>]*\?>\s*/, '')}</Root>")
end

def rect(el)
  gcc = el.attributes['gridColumn'].to_s.split('/').map { |s| s.strip.to_i }
  grr = el.attributes['gridRow'].to_s.split('/').map { |s| s.strip.to_i }
  [gcc[0], gcc[1], grr[0], grr[1]]
end

# No two SIBLINGS (page-level, or within one container) may overlap.
def collisions(xml)
  bad = []
  check = lambda do |parent, label|
    sibs = parent.elements.to_a.select { |e| %w[Container Element].include?(e.name) }
    sibs.map { |e| [e.attributes['elementId'], rect(e)] }.combination(2).each do |(ia, ra), (ib, rb)|
      bad << "#{label}: #{ia} vs #{ib}" if ra[0] < rb[1] && rb[0] < ra[1] && ra[2] < rb[3] && rb[2] < ra[3]
    end
    sibs.each { |e| check.call(e, e.attributes['elementId']) if e.name == 'Container' }
  end
  doc_for(xml).elements.each('Root/Page') { |pg| check.call(pg, "page #{pg.attributes['id']}") }
  bad
end

# ---- 0. pure band-detection + min-row functions ------------------------------
puts '-- pure functions'
ok('min_rows_for: kpi-chart 4 / bar-chart 8 / pivot 10 / control 2',
   SigmaLayout.min_rows_for('kpi-chart') == 4 && SigmaLayout.min_rows_for('bar-chart') == 8 &&
   SigmaLayout.min_rows_for('pivot-table') == 10 && SigmaLayout.min_rows_for('control') == 2)

kpi_z = lambda do |id, x, y, h = 10, w = 20|
  { 'id' => id, 'kind' => 'chart', 'caption' => id, 'chart_kind' => 'kpi',
    'measures' => ['m'], 'x_pct' => x, 'y_pct' => y, 'w_pct' => w, 'h_pct' => h }
end
row = [kpi_z.call('a', 2, 14), kpi_z.call('b', 27, 14), kpi_z.call('c', 52, 14.5), kpi_z.call('d', 77, 14)]
rows = SigmaLayout.detect_kpi_rows(row)
ok('detect_kpi_rows: 4 adjacent similar-height KPIs -> one row of 4',
   rows.length == 1 && rows[0].map { |z| z['id'] } == %w[a b c d])
stacked = [kpi_z.call('a', 10, 10, 4), kpi_z.call('b', 10, 13, 4)] # same x -> vertical stack
ok('detect_kpi_rows: vertically stacked same-x tiles are NOT a row',
   SigmaLayout.detect_kpi_rows(stacked).empty?)
tallmix = [kpi_z.call('a', 2, 10, 6), kpi_z.call('b', 30, 10, 16)] # 2.6x height ratio
ok('detect_kpi_rows: dissimilar heights do not group',
   SigmaLayout.detect_kpi_rows(tallmix).empty?)
furniture = [{ 'id' => 'f', 'kind' => 'chart', 'caption' => 'f', 'chart_kind' => 'kpi',
               'measures' => [], 'rows_shelf' => {}, 'cols_shelf' => {},
               'x_pct' => 2, 'y_pct' => 14, 'w_pct' => 20, 'h_pct' => 10 }, kpi_z.call('b', 27, 14)]
ok('detect_kpi_rows: non-plotting furniture zones are not KPI candidates',
   SigmaLayout.detect_kpi_rows(furniture).empty?)

rail_zones = [
  { 'id' => 'p1', 'kind' => 'parameter', 'x_pct' => 5, 'y_pct' => 30, 'w_pct' => 6, 'h_pct' => 3 },
  { 'id' => 'f1', 'kind' => 'filter', 'x_pct' => 5, 'y_pct' => 35, 'w_pct' => 6, 'h_pct' => 3 },
  { 'id' => 'f2', 'kind' => 'filter', 'x_pct' => 5, 'y_pct' => 40, 'w_pct' => 6, 'h_pct' => 3 },
  { 'id' => 'ch', 'kind' => 'chart', 'caption' => 'T', 'measures' => ['m'],
    'x_pct' => 16, 'y_pct' => 10, 'w_pct' => 80, 'h_pct' => 80 }
]
sb = SigmaLayout.detect_sidebar(rail_zones)
ok('detect_sidebar: narrow left column of controls -> left rail',
   sb && sb[:side] == :left && sb[:zones].map { |z| z['id'] } == %w[p1 f1 f2])
wide = rail_zones.map { |z| z['kind'] == 'chart' ? z : z.merge('w_pct' => 25) }
ok('detect_sidebar: a 25%-wide control column is NOT a rail (<20% rule)',
   SigmaLayout.detect_sidebar(wide).nil?)

hdr = SigmaLayout.detect_header_zones(
  [{ 'id' => 't1', 'kind' => 'text', 'x_pct' => 5, 'y_pct' => 1, 'w_pct' => 60, 'h_pct' => 5 },
   { 'id' => 't2', 'kind' => 'text', 'x_pct' => 5, 'y_pct' => 50, 'w_pct' => 90, 'h_pct' => 5 }]
)
ok('detect_header_zones: topmost full-width text only', hdr.map { |z| z['id'] } == ['t1'])

r2, n2 = SigmaLayout.expand_min_rows([[1, 13, 1, 3], [1, 13, 3, 5]], [8, 8])
ok('expand_min_rows: expands both and pushes the lower tile down (no overlap)',
   n2 == 2 && r2 == [[1, 13, 1, 9], [1, 13, 9, 17]])
ok('expand_min_rows: no-op when everything meets its floor',
   SigmaLayout.expand_min_rows([[1, 13, 1, 9]], [8]) == [[[1, 13, 1, 9]], 0])

# ---- 1. supermart-like: header + KPI band ------------------------------------
puts '-- header + KPI band (supermart-sales shape)'
DL_KPI = [{
  'dashboard' => 'Overview',
  'zones' => [
    { 'id' => 't1', 'kind' => 'text', 'x_pct' => 5, 'y_pct' => 1, 'w_pct' => 60, 'h_pct' => 5 },
    kpi_z.call('k1', 2, 14), kpi_z.call('k2', 27, 14), kpi_z.call('k3', 52, 14), kpi_z.call('k4', 77, 14),
    { 'id' => 'c1', 'kind' => 'chart', 'caption' => 'Sales Trend', 'chart_kind' => 'bar',
      'measures' => ['m'], 'x_pct' => 1, 'y_pct' => 30, 'w_pct' => 48, 'h_pct' => 30 },
    { 'id' => 'c2', 'kind' => 'chart', 'caption' => 'Category Split', 'chart_kind' => 'line',
      'measures' => ['m'], 'x_pct' => 51, 'y_pct' => 30, 'w_pct' => 48, 'h_pct' => 30 }
  ],
  'zone_tree' => []
}]
WB_KPI = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'Overview', 'id' => 'page-ov', 'elements' => [
    { 'id' => 'title-ov', 'kind' => 'text', 'name' => nil },
    { 'id' => 'text-t1', 'kind' => 'text', 'name' => nil },
    { 'id' => 'el-k1', 'kind' => 'kpi-chart', 'name' => 'k1' },
    { 'id' => 'el-k2', 'kind' => 'kpi-chart', 'name' => 'k2' },
    { 'id' => 'el-k3', 'kind' => 'kpi-chart', 'name' => 'k3' },
    { 'id' => 'el-k4', 'kind' => 'kpi-chart', 'name' => 'k4' },
    { 'id' => 'el-c1', 'kind' => 'bar-chart', 'name' => 'Sales Trend' },
    { 'id' => 'el-c2', 'kind' => 'line-chart', 'name' => 'Category Split' }
  ] }
] }

Dir.mktmpdir do |d|
  xml, census, log, _els = build(DL_KPI, WB_KPI, d)
  ok('builder produced layout XML', !xml.nil?)
  ok('took the synthesized path', log.include?('synthesized layout'))
  next if xml.nil?
  doc = doc_for(xml)
  gcs = doc.elements.to_a('//Container')
  kpi_gc = gcs.find do |g|
    ids = g.elements.to_a('Element').map { |l| l.attributes['elementId'] }
    ids.sort == %w[el-k1 el-k2 el-k3 el-k4]
  end
  ok('the 4 KPI tiles live in ONE Container', !kpi_gc.nil?)
  if kpi_gc
    cr = rect(kpi_gc)
    span = cr[3] - cr[2]
    kids = kpi_gc.elements.to_a('Element').map { |l| rect(l) }
    ok('KPI container spans the full content width', cr[0] == 1 && cr[1] == 25)
    ok('inner KPI spans are equal (24/4 = 6 cols each)',
       kids.map { |r| r[1] - r[0] }.uniq == [6])
    ok("inner gridRow matches the container span (KPI-sliver rule, span=#{span})",
       kids.all? { |r| r[2] == 1 && r[3] == 1 + span })
    ok('KPI container is at least the kpi-chart floor tall', span >= 4)
  end
  hdr_gc = gcs.find { |g| g.attributes['elementId'].to_s.end_with?('-hdr') }
  hdr_ids = hdr_gc ? hdr_gc.elements.to_a('Element').map { |l| l.attributes['elementId'] } : []
  ok('header band holds the title AND the detected source header text',
     hdr_ids.include?('title-ov') && hdr_ids.include?('text-t1'))
  ok('synthetic title referenced exactly once (no duplicate beside the source header)',
     xml.scan(/elementId="title-ov"/).length == 1)
  ok('census does NOT mark synthetic_header when the source has its own header zone',
     census && !census['pages'].first.key?('synthetic_header'))
  ok('census unplaced_elements is present and empty (placement invariant)',
     census && census['pages'].first['unplaced_elements'] == [])
  ok('no collisions anywhere', collisions(xml).empty?)
  ok('census pages stay exact-compatible (zones/placed/dropped/grid_fill_pct)',
     census && census['pages'].first &&
     %w[page zones placed dropped grid_fill_pct].all? { |k| census['pages'].first.key?(k) })
  ok('census bands_detected: header + 1 KPI row, no sidebar',
     census && census['bands_detected'] == { 'header' => true, 'kpi_rows' => 1, 'sidebar' => false })
  ok('census carries min_row_expansions', census && census.key?('min_row_expansions'))
  ok('all 6 content tiles placed',
     census['pages'].first['placed'] == 6 && census['pages'].first['dropped'] == 0)
  spec = { 'pages' => WB_KPI['pages'], 'layout' => xml }
  ok('output passes layout lint (incl. the new min-row rule)', LayoutLint.lint(spec).empty?)
end

# ---- 2. superstore-like: left filter/param rail ------------------------------
puts '-- sidebar rail (superstore-performance shape)'
DL_RAIL = [{
  'dashboard' => 'Order Detail',
  'zones' => [
    { 'id' => 'p1', 'kind' => 'parameter', 'caption' => nil, 'filter_column_caption' => 'Metric',
      'x_pct' => 5, 'y_pct' => 30, 'w_pct' => 6, 'h_pct' => 3 },
    { 'id' => 'f1', 'kind' => 'filter', 'caption' => 'tbl', 'filter_column_caption' => 'Region',
      'x_pct' => 5, 'y_pct' => 35, 'w_pct' => 6, 'h_pct' => 3 },
    { 'id' => 'f2', 'kind' => 'filter', 'caption' => 'tbl', 'filter_column_caption' => 'Segment',
      'x_pct' => 5, 'y_pct' => 40, 'w_pct' => 6, 'h_pct' => 3 },
    { 'id' => 'f3', 'kind' => 'filter', 'caption' => 'tbl', 'filter_column_caption' => 'Category',
      'x_pct' => 5, 'y_pct' => 45, 'w_pct' => 6, 'h_pct' => 3 },
    { 'id' => 'z1', 'kind' => 'chart', 'caption' => 'Order Detail Table', 'chart_kind' => 'other',
      'measures' => ['m'], 'x_pct' => 16, 'y_pct' => 10, 'w_pct' => 80, 'h_pct' => 80 },
    { 'id' => 'z2', 'kind' => 'chart', 'caption' => 'Detail Title', 'chart_kind' => 'kpi',
      'measures' => ['m'], 'x_pct' => 16, 'y_pct' => 5, 'w_pct' => 30, 'h_pct' => 4 }
  ],
  'zone_tree' => []
}]
WB_RAIL = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'Order Detail', 'id' => 'page-od', 'elements' => [
    { 'id' => 'title-od', 'kind' => 'text', 'name' => nil },
    { 'id' => 'ctl-metric', 'kind' => 'control', 'name' => 'Metric' },
    { 'id' => 'ctl-region', 'kind' => 'control', 'name' => 'Region' },
    { 'id' => 'ctl-segment', 'kind' => 'control', 'name' => 'Segment' },
    { 'id' => 'ctl-category', 'kind' => 'control', 'name' => 'Category' },
    { 'id' => 'el-table', 'kind' => 'table', 'name' => 'Order Detail Table' },
    { 'id' => 'el-title2', 'kind' => 'kpi-chart', 'name' => 'Detail Title' }
  ] }
] }

first_run = nil
Dir.mktmpdir do |d|
  xml, census, log, els = build(DL_RAIL, WB_RAIL, d)
  first_run = [xml, JSON.generate(census), els]
  ok('builder produced layout XML', !xml.nil?)
  ok('took the synthesized path (rail)', log.include?('synthesized layout') && log.include?('left sidebar rail'))
  next if xml.nil?
  doc = doc_for(xml)
  gcs = doc.elements.to_a('//Container')
  rail_gc = gcs.find { |g| g.attributes['elementId'].to_s.end_with?('-rail') }
  ok('a rail Container is emitted', !rail_gc.nil?)
  if rail_gc
    ok('rail declares a single internal column (repeat(1, 1fr))',
       rail_gc.attributes['gridTemplateColumns'] == 'repeat(1, 1fr)')
    ids = rail_gc.elements.to_a('Element').map { |l| l.attributes['elementId'] }
    ok('all 4 controls stack INSIDE the rail (source y-order)',
       ids == %w[ctl-metric ctl-region ctl-segment ctl-category])
    ok('the table is NOT in the rail', !ids.include?('el-table'))
    kid_rects = rail_gc.elements.to_a('Element').map { |l| rect(l) }
    ok('rail controls meet the control floor (>= 2 rows each)',
       kid_rects.all? { |r| r[3] - r[2] >= 2 })
    rr = rect(rail_gc)
    ok('rail hugs the left edge', rr[0] == 1)
    content_gcs = gcs - [rail_gc] - gcs.select { |g| g.attributes['elementId'].to_s.end_with?('-hdr') }
    ok('content containers start where the rail ends (remaining columns)',
       content_gcs.any? && content_gcs.all? { |g| rect(g)[0] == rr[1] })
  end
  table_le = doc.elements.to_a('//Element').find { |l| l.attributes['elementId'] == 'el-table' }
  ok('table tile meets its 10-row floor', table_le && rect(table_le)[3] - rect(table_le)[2] >= 10)
  ok('no collisions anywhere', collisions(xml).empty?)
  ok('census bands_detected reports the sidebar',
     census && census['bands_detected']['sidebar'] == true)
  ok('nothing dropped', census['pages'].all? { |p| p['dropped'] == 0 })
  spec = { 'pages' => WB_RAIL['pages'], 'layout' => xml }
  ok('output passes layout lint', LayoutLint.lint(spec).empty?)
  ok('documented XML shape: Page attrs + no empty elementId',
     xml.include?('<Page type="grid" gridTemplateColumns="repeat(24, 1fr)"') &&
     !xml.include?('elementId=""'))
end

# determinism: a second run must be byte-identical (same input, same XML)
Dir.mktmpdir do |d|
  xml, census, _log, els = build(DL_RAIL, WB_RAIL, d)
  ok('deterministic: layout XML byte-identical across runs', xml == first_run[0])
  ok('deterministic: census byte-identical across runs', JSON.generate(census) == first_run[1])
  ok('deterministic: elements sidecar byte-identical across runs', els == first_run[2])
end

# ---- 3. E1 min-row expansion on the geometry-banded path ---------------------
puts '-- min-row expansion (banded path)'
DL_MIN = [{
  'dashboard' => 'Dash',
  'zones' => [
    { 'id' => 'a', 'kind' => 'chart', 'caption' => 'A', 'chart_kind' => 'bar', 'measures' => ['m'],
      'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 50, 'h_pct' => 13 },
    { 'id' => 'b', 'kind' => 'chart', 'caption' => 'B', 'chart_kind' => 'bar', 'measures' => ['m'],
      'x_pct' => 50, 'y_pct' => 0, 'w_pct' => 50, 'h_pct' => 13 },
    { 'id' => 'c', 'kind' => 'chart', 'caption' => 'C', 'chart_kind' => 'table', 'measures' => ['m'],
      'x_pct' => 0, 'y_pct' => 13, 'w_pct' => 100, 'h_pct' => 87 }
  ],
  'zone_tree' => []
}]
WB_MIN = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'Dash', 'id' => 'page-d', 'elements' => [
    { 'id' => 'title-d', 'kind' => 'text', 'name' => nil },
    { 'id' => 'el-a', 'kind' => 'bar-chart', 'name' => 'A' },
    { 'id' => 'el-b', 'kind' => 'bar-chart', 'name' => 'B' },
    { 'id' => 'el-c', 'kind' => 'table', 'name' => 'C' }
  ] }
] }

Dir.mktmpdir do |d|
  xml, census, log, _els = build(DL_MIN, WB_MIN, d)
  ok('builder produced layout XML', !xml.nil?)
  ok('banded path taken (no structures, no controls)',
     !log.include?('synthesized layout') && !log.include?('container-tree layout'))
  next if xml.nil?
  doc = doc_for(xml)
  spans = {}
  doc.elements.each('//Element') { |l| spans[l.attributes['elementId']] = rect(l) }
  ok('short bar charts expanded to the 8-row floor',
     spans['el-a'] && spans['el-a'][3] - spans['el-a'][2] >= 8 &&
     spans['el-b'] && spans['el-b'][3] - spans['el-b'][2] >= 8)
  ok('table meets the 10-row floor', spans['el-c'] && spans['el-c'][3] - spans['el-c'][2] >= 10)
  ok('expansion pushed the lower band down — no collisions', collisions(xml).empty?)
  ok('census counts the expansions', census && census['min_row_expansions'] >= 2)
  spec = { 'pages' => WB_MIN['pages'], 'layout' => xml }
  ok('output passes layout lint (no sub-minimum tiles shipped)', LayoutLint.lint(spec).empty?)
end

# ---- 4. synthetic dashboard title + orphan-element invariant -----------------
# Live-caught defect (v5.5 e2e, every workbook): the synthetic "# <Dashboard>"
# title element (id "title-<slug>", emitted by build-charts when the .twb has
# no top title zone) is NOT a .twb zone — any element the layout bands don't
# reference is auto-flowed by Sigma as a stray white card, bottom-left. The
# invariant: NO element in the built page may be absent from the layout; the
# census records violators in `unplaced_elements` (gate 8c fails on non-empty)
# and counts a synthesized title header (`synthetic_header: true`).
puts '-- synthetic title header + orphan invariant'
DL_TITLE = [{
  'dashboard' => 'Profitability Watch',
  'zones' => [
    { 'id' => 'z1', 'kind' => 'chart', 'caption' => 'Margin Trend', 'chart_kind' => 'bar',
      'measures' => ['m'], 'x_pct' => 0, 'y_pct' => 5, 'w_pct' => 50, 'h_pct' => 45 },
    { 'id' => 'z2', 'kind' => 'chart', 'caption' => 'Cost Split', 'chart_kind' => 'line',
      'measures' => ['m'], 'x_pct' => 50, 'y_pct' => 5, 'w_pct' => 50, 'h_pct' => 45 }
  ],
  'zone_tree' => []
}]
WB_TITLE = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'Profitability Watch', 'id' => 'page-pw', 'elements' => [
    { 'id' => 'title-profitability-watch', 'kind' => 'text', 'name' => nil },
    { 'id' => 'el-1', 'kind' => 'bar-chart', 'name' => 'Margin Trend' },
    { 'id' => 'el-2', 'kind' => 'line-chart', 'name' => 'Cost Split' }
  ] }
] }

Dir.mktmpdir do |d|
  xml, census, _log, _els = build(DL_TITLE, WB_TITLE, d)
  ok('builder produced layout XML (synthetic title, no source header zone)', !xml.nil?)
  next if xml.nil?
  doc = doc_for(xml)
  hdr_gc = doc.elements.to_a('//Container').find { |g| g.attributes['elementId'].to_s.end_with?('-hdr') }
  hdr_ids = hdr_gc ? hdr_gc.elements.to_a('Element').map { |l| l.attributes['elementId'] } : []
  ok('a full-width header band exists and references the synthetic title',
     hdr_gc && hdr_ids == ['title-profitability-watch'] && rect(hdr_gc)[0] == 1 && rect(hdr_gc)[1] == 25)
  ok('header band sits at the top of the grid', hdr_gc && rect(hdr_gc)[2] == 1)
  ok('synthetic title referenced exactly once',
     xml.scan(/elementId="title-profitability-watch"/).length == 1)
  pg = census && census['pages'].first
  ok('census counts the synthesized title (zones/placed include it, synthetic_header noted)',
     pg && pg['synthetic_header'] == true && pg['zones'] == 3 && pg['placed'] == 3 && pg['dropped'] == 0)
  ok('census unplaced_elements empty — nothing orphaned', pg && pg['unplaced_elements'] == [])
  ok('no collisions', collisions(xml).empty?)
end

# 4b. banded path safety net: an element with NO Tableau zone (here an image)
# must land in a bottom band, never be left for Sigma to auto-flow.
Dir.mktmpdir do |d|
  wb = JSON.parse(JSON.generate(WB_TITLE))
  wb['pages'][1]['elements'] << { 'id' => 'img-logo', 'kind' => 'image', 'name' => nil }
  xml, census, _log, _els = build(DL_TITLE, wb, d)
  ok('builder produced layout XML (zone-less image element)', !xml.nil?)
  next if xml.nil?
  ok('zone-less image is placed by the banded-path safety net (referenced in a band)',
     xml.scan(/elementId="img-logo"/).length == 1 && xml.include?('-extra"'))
  pg = census && census['pages'].first
  ok('census unplaced_elements empty — the safety net upheld the invariant',
     pg && pg['unplaced_elements'] == [])
  ok('no collisions (safety band below content)', collisions(xml).empty?)
end

# 4c. provenance-aware zone matching: a tile RENAMED to its display title (so
# neither the zone caption nor display_title matches the element name) resolves
# through chart-provenance.json (element id → worksheet) instead of falling
# into the safety-net band — the stale-container-on-re-PUT source defect.
Dir.mktmpdir do |d|
  dl = JSON.parse(JSON.generate(DL_TITLE))
  wb = JSON.parse(JSON.generate(WB_TITLE))
  wb['pages'][1]['elements'][1]['name'] = 'Gross Margin Trend (renamed)'
  # REAL builder shape ({version, elements} envelope — build-charts-from-signals):
  # the old fixture wrote a FLAT map, a false green that hid the #422 root cause
  # (the loader read the envelope file flat and provenance never fired live).
  File.write(File.join(d, 'chart-provenance.json'), JSON.generate(
    'version' => 1, 'elements' => {
      'el-1' => { 'worksheet' => 'Margin Trend', 'dashboard' => 'Profitability Watch' }
    }))
  xml, census, log, _els = build(dl, wb, d)
  ok('builder produced layout XML (renamed tile + provenance)', !xml.nil?)
  next if xml.nil?
  ok('renamed tile resolves via provenance — placed as a zone tile, not the safety band',
     xml.scan(/elementId="el-1"/).length == 1 && !xml.include?('-extra"'))
  ok('no "no Sigma element matched" WARN for the renamed tile', !log.include?('no Sigma element matched'))
  pg = census && census['pages'].first
  ok('census counts the renamed tile as placed (no drop)', pg && pg['dropped'] == 0)
  ok('census unplaced_elements empty', pg && pg['unplaced_elements'] == [])
end

# ---- 5. #422 re-entry repeat-tax regressions ---------------------------------
puts '-- #422: provenance on re-entry, rename persistence, banner opt-out'

# 5a. provenance matching on RE-ENTRY (the live 1/6 case): after a re-entry
# readback, 5 of 6 tiles carry operator-renamed display names that match
# neither the zone caption nor display_title. With the REAL nested
# chart-provenance.json ({version, elements}) every tile must resolve via its
# worksheet alias — main@208626b matched only the un-renamed tile because the
# loader read the envelope file flat and the aliases never materialized.
DL_SIX = [{
  'dashboard' => 'Exec Overview',
  'zones' => (1..6).map do |i|
    { 'id' => "z#{i}", 'kind' => 'chart', 'caption' => "WS #{i}", 'chart_kind' => 'bar',
      'measures' => ['m'], 'x_pct' => ((i - 1) % 3) * 33.4, 'y_pct' => 5 + ((i - 1) / 3) * 45,
      'w_pct' => 33, 'h_pct' => 40 }
  end,
  'zone_tree' => []
}]
WB_SIX = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'M' }] },
  { 'name' => 'Exec Overview', 'id' => 'page-ex', 'elements' =>
    (1..6).map do |i|
      { 'id' => "el-#{i}", 'kind' => 'bar-chart',
        'name' => i == 1 ? 'WS 1' : "Operator Renamed #{i}" }
    end }
] }

Dir.mktmpdir do |d|
  File.write(File.join(d, 'chart-provenance.json'), JSON.generate(
    'version' => 1,
    'elements' => (1..6).each_with_object({}) do |i, h|
      h["el-#{i}"] = { 'worksheet' => "WS #{i}", 'dashboard' => 'Exec Overview' }
    end))
  xml, census, log, _els = build(DL_SIX, WB_SIX, d)
  ok('re-entry build produced layout XML (5/6 tiles renamed)', !xml.nil?)
  unless xml.nil?
    pg = census && census['pages'].first
    ok('ALL 6 renamed tiles match via nested provenance (was 1/6 live)',
       pg && pg['placed'] == 6 && pg['dropped'] == 0)
    ok('no safety-net band needed for the renamed tiles', !xml.include?('-extra"'))
    ok('no "no Sigma element matched" WARN', !log.include?('no Sigma element matched'))
    ok('no collisions', collisions(xml).empty?)
  end
end

# 5b. rename persistence round-trip: --rename on pass 1 lands in
# layout-renames.json; a re-entry rebuild WITHOUT the flag auto-applies it
# (the operator no longer re-types --rename x4 per re-entry).
Dir.mktmpdir do |d|
  dl = JSON.parse(JSON.generate(DL_TITLE))
  wb = JSON.parse(JSON.generate(WB_TITLE))
  wb['pages'][1]['elements'][1]['name'] = 'Net Margin Trend'
  xml, _c, _log, = build(dl, wb, d, ['--rename', 'Margin Trend=Net Margin Trend'])
  ok('pass 1 (--rename) placed the renamed tile',
     !xml.nil? && xml.scan(/elementId="el-1"/).length == 1 && !xml.include?('-extra"'))
  rn = File.join(d, 'layout-renames.json')
  ok('renames persisted to layout-renames.json',
     File.exist?(rn) && JSON.parse(File.read(rn)) == { 'Margin Trend' => 'Net Margin Trend' })
  xml2, census2, log2, = build(dl, wb, d) # re-entry: NO --rename flags
  pg2 = census2 && census2['pages'].first
  ok('re-entry (no --rename) still matches via the persisted map',
     !xml2.nil? && xml2.scan(/elementId="el-1"/).length == 1 && !xml2.include?('-extra"') &&
     pg2 && pg2['dropped'] == 0)
  ok('re-entry log notes the persisted renames were loaded', log2.include?('persisted rename mapping'))
end

# 5c. banner opt-out. Baseline (no title element, no source header zone) emits
# the fabricated page-name banner; --no-synthetic-title suppresses it.
WB_NOTITLE = JSON.parse(JSON.generate(WB_TITLE))
WB_NOTITLE['pages'][1]['elements'] = WB_NOTITLE['pages'][1]['elements'].reject { |e| e['id'].to_s.start_with?('title') }

Dir.mktmpdir do |d|
  xml, _c, _log, = build(DL_TITLE, WB_NOTITLE, d)
  ok('baseline: fabricated page-name banner emitted (-hdrtext)', !xml.nil? && xml.include?('-hdrtext"'))
end
Dir.mktmpdir do |d|
  xml, census, _log, = build(DL_TITLE, WB_NOTITLE, d, ['--no-synthetic-title'])
  ok('--no-synthetic-title: no fabricated banner, no header band',
     !xml.nil? && !xml.include?('-hdrtext"') && !xml.include?('-hdr"'))
  pg = census && census['pages'].first
  ok('suppressed banner: charts still placed, nothing orphaned, no collisions',
     pg && pg['placed'] == 2 && pg['unplaced_elements'] == [] && collisions(xml).empty?)
end
# synthesized path takes the same flag
Dir.mktmpdir do |d|
  dl = JSON.parse(JSON.generate(DL_KPI))
  dl[0]['zones'] = dl[0]['zones'].reject { |z| z['id'] == 't1' }
  wb = JSON.parse(JSON.generate(WB_KPI))
  wb['pages'][1]['elements'] = wb['pages'][1]['elements'].reject { |e| %w[title-ov text-t1].include?(e['id']) }
  xml, census, log, = build(dl, wb, d, ['--no-synthetic-title'])
  ok('synthesized path honors --no-synthetic-title (no header band at all)',
     !xml.nil? && log.include?('synthesized layout') && !xml.include?('-hdrtext"') && !xml.include?('-hdr"'))
  pg = census && census['pages'].first
  ok('synthesized suppression: nothing orphaned, no collisions',
     pg && pg['unplaced_elements'] == [] && collisions(xml).empty?)
end

# 5d. prior-state auto-suppression: a prior layout.xml at --out with NO header
# band (the operator removed the banner and re-PUT) must suppress re-injection
# on the next rebuild — respect the operator's last state.
Dir.mktmpdir do |d|
  File.write(File.join(d, 'layout.xml'),
             '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)"><Element elementId="el-1" gridColumn="1 / 25" gridRow="1 / 9"/></Page>')
  xml, _c, log, = build(DL_TITLE, WB_NOTITLE, d)
  ok('prior-state: rebuild auto-suppresses the banner', log.include?('auto-suppressed'))
  ok('prior-state: no fabricated banner in the rebuilt layout',
     !xml.nil? && !xml.include?('-hdrtext"'))
end
# …but a prior layout WITH the banner keeps it (no false suppression).
Dir.mktmpdir do |d|
  xml1, _c1, _l1, = build(DL_TITLE, WB_NOTITLE, d)
  ok('control: first build emits the banner', !xml1.nil? && xml1.include?('-hdrtext"'))
  xml2, _c2, log2, = build(DL_TITLE, WB_NOTITLE, d)
  ok('control: rebuild over a banner-bearing prior layout keeps the banner',
     !xml2.nil? && xml2.include?('-hdrtext"') && !log2.include?('auto-suppressed'))
end

# 6. A reused workbook-local data pipeline lives on hidden pages that have no
# Tableau dashboard zones. Preserve those pages/elements while rebuilding the
# visible dashboard layout.
puts '-- synthetic worksheet page matching'
Dir.mktmpdir do |d|
  synthetic = JSON.parse(JSON.generate(DL_TITLE))
  synthetic[0]['dashboard'] = '[synthetic] Profitability Watch'
  xml, _census, _log, = build(synthetic, WB_TITLE, d)
  ok('synthetic parser page matches worksheet-named Sigma page',
     !xml.nil? && xml.include?('id="page-pw"'))
end

puts '-- hidden pipeline page preservation'
dl_pipeline = [{
  'dashboard' => 'Overview',
  'zones' => [{
    'id' => 'z-chart', 'kind' => 'chart', 'caption' => 'Revenue',
    'chart_kind' => 'bar', 'measures' => ['Amount'],
    'x_pct' => 0, 'y_pct' => 0, 'w_pct' => 100, 'h_pct' => 100
  }],
  'zone_tree' => []
}]
wb_pipeline = {
  'pages' => [
    {
      'id' => 'page-data', 'name' => 'Data', 'visibility' => 'hidden',
      'elements' => [{
        'id' => 'pipeline-source', 'kind' => 'table', 'name' => 'Source',
        'visibleAsSource' => false, 'columns' => []
      }]
    },
    {
      'id' => 'page-derived', 'name' => 'Derived Data', 'visibility' => 'hidden',
      'elements' => [{
        'id' => 'pipeline-union', 'kind' => 'table', 'name' => 'Combined',
        'visibleAsSource' => false, 'source' => { 'kind' => 'table', 'elementId' => 'pipeline-source' },
        'columns' => []
      }]
    },
    {
      'id' => 'page-overview', 'name' => 'Overview',
      'elements' => [{
        'id' => 'chart-revenue', 'kind' => 'bar-chart', 'name' => 'Revenue',
        'source' => { 'kind' => 'table', 'elementId' => 'pipeline-union' },
        'columns' => []
      }]
    }
  ]
}
Dir.mktmpdir do |d|
  xml, _census, log, = build(dl_pipeline, wb_pipeline, d)
  ok('hidden pipeline page remains in rebuilt layout',
     !xml.nil? && xml.include?('id="page-derived"') && xml.include?('elementId="pipeline-union"'))
  ok('visible dashboard remains laid out once',
     !xml.nil? && xml.scan(/elementId="chart-revenue"/).length == 1)
  ok('builder reports preserved pipeline page', log.include?('non-dashboard pipeline page'))
end

puts($fail.zero? ? "\nALL PASS — layout synthesis (bands, rail, KPI containers, min rows, determinism)" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
