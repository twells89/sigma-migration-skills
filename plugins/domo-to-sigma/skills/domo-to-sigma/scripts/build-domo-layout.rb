#!/usr/bin/env ruby
# Phase 5d (pre) — Domo page geometry → the zone-schema dashboard-layout.json that
# the reused build-dashboard-layout.rb consumes.
#
# Geometry source: discovery/cards.json — specifically the x/y/w/h fields
# DomoSigma.merge_geometry (Task 1, lib/domo_sigma_util.rb) copies onto each
# card from the page's private-API layout during domo-discover.rb's --pages
# run. This is the ONE geometry source for the layout builder; there is no
# separate extractor. (Earlier revisions read a duplicate
# discovery/layout/<pageId>.json produced by domo-capture-visuals.rb's own
# normalize_layout — that path never received Task 1's merge_geometry output,
# so a migration's real card coordinates never reached the layout builder.
# domo-capture-visuals.rb now only stages PNG/PDF references; it emits no
# geometry file.)
#
# Geometry is normalized RELATIVE to each page's own max extent (x/(maxX), etc.),
# so it works whether Domo reports card geometry in grid cells or pixels — no need
# to resolve the grid-unit question. Each captured card becomes a zone with
# kind:"chart" (or "filter") + caption + chart_kind so ZoneCensus counts it.
#
#   ruby scripts/build-domo-layout.rb            # → discovery/dashboard-layout.json
#
# Then reuse: build-dashboard-layout.rb --layout discovery/dashboard-layout.json --wb-ids wb-ids.json --out layout.xml
#
# NOTE: the dashboard/page NAME here must match the workbook page names
# build-workbook.rb produced (build-dashboard-layout matches dashboards↔pages by
# name and requires a page literally named "Data").

require 'json'
require 'fileutils'
require_relative 'lib/domo_sigma_util'
include DomoSigma

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# Coarse chart_kind token for census/placement (the real Sigma kind is chosen by
# build-workbook.rb; this is only for layout weighting). Substring map, kept
# independent of domo-discover.rb. NOTE: this is the zone's LOGICAL kind that
# lib/layout.rb's kpi_like_zone? (vendored verbatim from tableau-to-sigma)
# matches against — it expects the bare 'kpi', not the Sigma ELEMENT kind
# 'kpi-chart' that domo-discover.rb's sigma_kind_hint separately emits for
# build-workbook.rb's build_kpi. Emitting 'kpi-chart' here silently missed
# KPI-row detection for any Domo KPI tile that failed the plain size heuristic.
def kind_hint(chart_type)
  t = chart_type.to_s.downcase
  return 'filter'       if t.include?('filter')
  return 'kpi'          if t.include?('singlevalue') || t.include?('summary') || t == 'badge'
  return 'table'        if t.include?('datagrid') || t.include?('table')
  return 'bar-chart'    if t.include?('bar')
  return 'line-chart'   if t.include?('line')
  return 'donut-chart'  if t.include?('pie') || t.include?('donut')
  return 'scatter-chart' if t.include?('scatter') || t.include?('bubble')
  'bar-chart'
end

# Build one dashboard's zone tree from its own geometry-bearing cards (already
# scoped to one page by the caller). `cards` — this page's cards.json records
# that carry x/y/w/h (Task 1's merge_geometry). `name` — the page title, used
# as the dashboard name build-dashboard-layout.rb matches against the workbook
# page name.
def build_dashboard(name, cards)
  cards = Array(cards).select { |c| c['x'] && c['y'] && c['w'] && c['h'] }
  return nil if cards.empty?
  max_x = cards.map { |c| c['x'].to_f + c['w'].to_f }.max
  max_y = cards.map { |c| c['y'].to_f + c['h'].to_f }.max
  max_x = 1.0 if max_x.zero?
  max_y = 1.0 if max_y.zero?
  zones = cards.map do |c|
    kh = kind_hint(c['chartType'])
    is_filter = kh == 'filter'
    {
      'id'        => c['id'],
      'x_pct'     => (c['x'].to_f * 100.0 / max_x).round(2),
      'y_pct'     => (c['y'].to_f * 100.0 / max_y).round(2),
      'w_pct'     => (c['w'].to_f * 100.0 / max_x).round(2),
      'h_pct'     => (c['h'].to_f * 100.0 / max_y).round(2),
      'kind'      => is_filter ? 'filter' : 'chart',
      'caption'   => c['title'],
      'chart_kind'=> is_filter ? nil : kh,
      # non-empty so ZoneCensus.plots? counts a data card as a real tile
      'measures'  => is_filter ? [] : ['value'],
      'children'  => [],
    }.compact
  end
  { 'dashboard' => name, 'zone_tree' => zones, 'zones' => zones }
end

if $PROGRAM_NAME == __FILE__
  cards = JSON.parse(File.read(File.join(OUT, 'cards.json'))) rescue []
  pages = JSON.parse(File.read(File.join(OUT, 'pages.json'))) rescue []

  cards = cards.reject { |c| c['_error'] || c['_tierB'] }

  # Group cards by page — same membership resolution build-workbook.rb uses,
  # so a page's layout dashboard and its workbook page carry the SAME cards.
  card_page = {}
  pages.each do |p|
    pname = p['title'] || p['name'] || p['id']
    Array(p['cardIds'] || p['cards']).each { |cid| card_page[cid.to_s] = pname }
  end
  by_page = Hash.new { |h, k| h[k] = [] }
  cards.each { |c| by_page[card_page[c['id'].to_s] || 'Overview'] << c }

  dashboards = by_page.map { |pname, pcards| build_dashboard(pname, pcards) }.compact
  abort("  no cards with x/y/w/h geometry in #{File.join(OUT, 'cards.json')} — " \
        'run domo-discover.rb --pages <ids> first (its merge_geometry copies the ' \
        'private-API page layout onto each card); an image/PNG capture is not required.') if dashboards.empty?

  FileUtils.mkdir_p(OUT)
  out = File.join(OUT, 'dashboard-layout.json')
  File.write(out, JSON.pretty_generate(dashboards))
  warn "  wrote #{out} (#{dashboards.size} dashboard(s), #{dashboards.sum { |d| d['zones'].size }} zones)"
  warn "  ⚠ dashboard names must match the workbook page names; ensure a 'Data' page exists in wb-ids."
end
