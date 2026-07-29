#!/usr/bin/env ruby
# Phase 5 — Workbook chart layer (the Domo analog of Tableau's
# build-charts-from-signals.rb). Turns normalized Domo cards into Sigma workbook
# ELEMENTS that source a hidden "master" table, then the reused
# build-workbook-spec.rb assembles master + pages into the POST-ready spec.
#
# Every element references DM columns as [Master/<Display Name>] so it composes
# with the auto-master build-workbook-spec.rb emits. This script bakes in the
# fixes from the field migration feedback:
#   #1 KPI value = summary number's aggregation of its MEASURE (source-prefixed);
#      a COUNT of a row-key/id (Domo table default) is flagged, not shipped silently.
#   #2 page filters → controls that fan out to EVERY element via the shared master.
#   #5 long-text table columns get style.textWrap:"wrap".
#   #7 a Domo bar chart → a real bar-chart element, never a table+dataBars.
#   #8 chart axes default to gridlines-off (format.marks:"none").
#
#   ruby scripts/build-workbook.rb            # → discovery/chart-specs.json (+ warnings.json)
#   # then reuse: build-workbook-spec.rb --chart-specs chart-specs.json --dm-ids dm-ids.json ...
#
# Optional sidecar discovery/kpi-overrides.json  { "<cardId>": {"column":"...","aggregation":"SUM"} }
# lets the migrator correct a wrong KPI measure deterministically and re-run.

require 'json'
require 'fileutils'
require 'base64'
require_relative 'lib/domo_sigma_util'
include DomoSigma

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

AGG = { 'SUM' => 'Sum', 'AVG' => 'Avg', 'AVERAGE' => 'Avg', 'COUNT' => 'Count',
        'COUNT DISTINCT' => 'CountDistinct', 'DISTINCT_COUNT' => 'CountDistinct',
        'COUNT_DISTINCT' => 'CountDistinct', 'MIN' => 'Min', 'MAX' => 'Max' }.freeze
def sigma_agg(a) AGG[a.to_s.upcase] || 'Sum' end

def mref(display) "[Master/#{display}]" end

$warnings = []
def warn_card(card, msg) $warnings << { 'card' => card['title'] || card['id'], 'warning' => msg } end

# A page whose cards carry no grid geometry (Task 1's merge_geometry 'x'/'y'
# fields, sourced from domo-discover's --pages capture) has nothing for
# build-domo-layout.rb/build-dashboard-layout.rb to place — it silently falls
# back to a single-column stack. Warn loudly instead of shipping that quietly.
def warn_missing_geometry(pname, pcards)
  return if pcards.empty?
  return if pcards.any? { |c| c['x'] || c['y'] }
  warn_card(pcards.first, "no grid geometry for page '#{pname}' — layout will fall back to a " \
                          'single-column stack; ensure domo-discover captured x/y/w/h')
end

# Split a card's columns into dimensions (grouped / non-aggregated) and measures.
def split_cols(card)
  cols = card['columns'] || []
  gb = Array(card['groupBy'])
  dims = cols.select { |c| gb.include?(c['column']) || c['aggregation'].to_s.empty? }
  meas = cols.select { |c| !c['aggregation'].to_s.empty? }
  dims = cols.reject { |c| meas.include?(c) } if dims.empty? && !meas.empty?
  [dims, meas]
end

def col_label(c) (c['alias'] && !c['alias'].to_s.strip.empty?) ? c['alias'] : display_name(c['column']) end

# A measure element column: <Agg>([Master/<disp>]) with a clean label + format.
def measure_col(c)
  disp = display_name(c['column'])
  { 'id' => "m-#{c['column'].to_s.downcase.gsub(/\W+/, '-')}",
    'name' => col_label(c),
    'formula' => "#{sigma_agg(c['aggregation'])}(#{mref(disp)})",
    'format' => sigma_format(c['format'], col_label(c)) }.compact
end

# A dimension element column: [Master/<disp>].
def dim_col(c)
  { 'id' => "d-#{c['column'].to_s.downcase.gsub(/\W+/, '-')}",
    'name' => col_label(c), 'formula' => mref(display_name(c['column'])) }.compact
end

AXIS_OFF = { 'marks' => 'none' }.freeze # gridlines off (bug #8); labels left to source

def eid(card, suffix = '') "el-#{(card['id'] || rand_id).to_s.gsub(/\W+/, '-')}#{suffix}" end

# ---- per-kind builders -----------------------------------------------------

def build_kpi(card, overrides)
  sn = card['summaryNumber'] || {}
  ov = overrides[card['id']]
  col = ov && ov['column'] || sn['column']
  agg = ov && ov['aggregation'] || sn['aggregation'] || 'SUM'
  # #1 guard: Domo table cards default the summary number to COUNT of the bound
  # (usually id/row-key) column. Ship it, but flag loudly so wrong numbers surface.
  if !ov && sn['_defaultCountSuspect'] && id_like?(col)
    warn_card(card, "KPI counts the row-key '#{col}' (Domo table default) — likely NOT the intended metric. " \
                    "Set discovery/kpi-overrides.json {\"#{card['id']}\":{\"column\":\"<measure>\",\"aggregation\":\"SUM\"}} and re-run.")
  end
  return nil unless col
  disp = display_name(col)
  label = (sn['label'] && !sn['label'].to_s.strip.empty?) ? sn['label'] : disp
  vid = mcol_id(disp).sub(/\Am-/, 'v-')
  {
    'id' => eid(card), 'kind' => 'kpi-chart', 'name' => label,
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [{ 'id' => vid, 'name' => label,
                    'formula' => "#{sigma_agg(agg)}(#{mref(disp)})",
                    'format' => sigma_format(sn['format'], label) }.compact],
    'value' => { 'columnId' => vid },   # ⚠ columnId, NOT id (feedback_sigma_kpi_value_columnid)
  }
end

def build_axis_chart(card, kind)
  dims, meas = split_cols(card)
  if dims.empty? || meas.empty?
    warn_card(card, "#{kind}: could not resolve both a dimension and a measure — verify against the card PNG.")
  end
  xcol = dims.first
  dcols = dims.map { |d| dim_col(d) }
  mcols = meas.map { |m| measure_col(m) }
  el = {
    'id' => eid(card), 'kind' => kind, 'name' => card['title'],
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => dcols + mcols,
  }
  if xcol
    xa = { 'columnId' => dcols.first['id'], 'format' => AXIS_OFF }
    # sort by the first measure if the card ordered by a measure
    xa['sort'] = { 'by' => mcols.first['id'], 'direction' => 'descending' } if mcols.first && Array(card['orderBy']).any?
    el['xAxis'] = xa
  end
  el['yAxis'] = { 'columnIds' => mcols.map { |m| m['id'] }, 'format' => AXIS_OFF } unless mcols.empty?
  el['orientation'] = 'horizontal' if card['chartType'].to_s.downcase.include?('horiz')
  el
end

def build_table(card)
  dims, meas = split_cols(card)
  cols = dims.map { |d| dim_col(d).merge('style' => { 'textWrap' => 'wrap' }) } +   # #5 wrap text cols
         meas.map { |m| measure_col(m) }
  cols = (card['columns'] || []).map { |c| dim_col(c).merge('style' => { 'textWrap' => 'wrap' }) } if cols.empty?
  el = {
    'id' => eid(card), 'kind' => 'table', 'name' => card['title'],
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => cols, 'order' => cols.map { |c| c['id'] },
  }
  # #7: in-cell data bars belong ONLY to a real Domo table card that declared them.
  bars = Array(card['conditionalFormats']).select { |cf| cf.to_s.downcase.include?('databar') || cf.dig('format', 'dataBar') }
  unless bars.empty?
    el['conditionalFormats'] = [{ 'type' => 'dataBars', 'columnIds' => meas.map { |m| measure_col(m)['id'] } }]
  end
  el
end

def build_pivot(card)
  dims, meas = split_cols(card)
  warn_card(card, 'pivot-table: rowsBy/columnsBy split inferred — verify against the card PNG.') if dims.size < 2
  {
    'id' => eid(card), 'kind' => 'pivot-table', 'name' => card['title'],
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => (dims + meas).map { |c| meas.include?(c) ? measure_col(c) : dim_col(c) },
    'rowsBy' => dims.first(1).map { |d| dim_col(d)['id'] },
    'columnsBy' => dims.drop(1).map { |d| dim_col(d)['id'] },   # pivot REQUIRES both (feedback_sigma_pivot_rowsby_columnsby)
    'values' => meas.map { |m| measure_col(m)['id'] },
  }
end

# ---- image / logo / drawing cards (tableau build-charts-from-signals.rb:6655 pattern) ----
# Inline data-URI — no hosting required. PNG/JPEG data-URIs POST + render cleanly
# (only base64-SVG is WAF-blocked; Domo logos are raster PNG).
# NOTE: 'richtext' is deliberately excluded — it overlaps the text/title row
# (refs/card-to-element.md); richtext stays a text element, not an image.
IMAGE_CHART_TYPE_RE = /image|logo|drawing|picture/i

# The staged capture path capture_card (domo-capture-visuals.rb) writes to, or
# the card's own override if the caller already resolved one.
def png_path(card)
  card['_pngPath'] || File.join(OUT, 'png', 'cards', "#{card['id']}.png")
end

# True ONLY for a card whose chartType explicitly names it as a static
# image/logo/drawing asset. Do NOT also key off "no data columns + a staged
# PNG exists" — domo-capture-visuals.rb's capture_card renders a PNG for
# EVERY card on a page (filter widgets, text/title cards included), so that
# combination is not a useful discriminator and silently misroutes cards that
# belong on the control path (chartType 'filter') or the text path (chartType
# 'text'/'title') into a flat raster image with no warning. An image-ish card
# that doesn't match this chartType check falls through to the existing
# placeholder path + warn_card below — the honest fidelity-discipline default.
def image_card?(card)
  card['chartType'].to_s =~ IMAGE_CHART_TYPE_RE ? true : false
end

# build_image(card) -> {id, kind:'image', url:"data:image/png;base64,<b64>"} or
# nil when no PNG was captured (Tier B / not captured) — the caller falls back
# and warns; NEVER emit an image element with an empty/broken url.
def build_image(card)
  path = png_path(card)
  return nil unless path && File.exist?(path.to_s)
  { 'id' => eid(card), 'kind' => 'image',
    'url' => "data:image/png;base64,#{Base64.strict_encode64(File.binread(path))}" }
end

def build_element(card, overrides)
  # Rule 0: a summary-number card with no real grouping → KPI, never a table.
  kind = card['sigmaKindHint']
  is_kpi = kind == 'kpi-chart' ||
           (card['summaryNumber'] && Array(card['groupBy']).empty? && (card['columns'] || []).size <= 1)
  return build_kpi(card, overrides) if is_kpi

  if image_card?(card)
    img = build_image(card)
    return img if img
    # PNG absent (Tier B / not captured) — honest fallback: fall through to the
    # existing placeholder path below (unchanged) + flag it so it gets fixed by
    # hand rather than shipping a broken/empty image element.
    warn_card(card, "image card #{card['id']}: no captured PNG — export from Domo UI and embed manually.")
  end

  case kind
  when 'bar-chart', 'line-chart', 'area-chart', 'combo-chart', 'scatter-chart'
    build_axis_chart(card, kind == 'combo-chart' ? 'bar-chart' : kind).tap do
      warn_card(card, 'combo/dual-axis: emitted as bar-chart — set yAxis2 in the editor.') if kind == 'combo-chart'
    end
  when 'donut-chart'
    warn_card(card, 'donut/pie: verify value binding (donut uses value.id, not columnId).')
    build_axis_chart(card, 'bar-chart').merge('kind' => 'donut-chart')
  when 'pivot-table'  then build_pivot(card)
  when 'table'        then build_table(card)
  else
    warn_card(card, "unknown chartType '#{card['chartType']}' → emitted bar-chart; verify against the PNG.")
    build_axis_chart(card, 'bar-chart')
  end
end

# ---- controls (bug #2: fan out to EVERY element via the shared master) ------
def build_controls(cards)
  seen = {}
  controls = []
  cards.each do |card|
    Array(card['filters']).each do |f|
      col = f['column']; next if col.nil? || seen[col]
      seen[col] = true
      disp = display_name(col)
      controls << {
        'id' => "ctl-#{col.to_s.downcase.gsub(/\W+/, '-')}",
        'kind' => 'control',
        'controlId' => disp.gsub(/\s+/, ''),
        'controlType' => 'list',
        'name' => disp,
        # Bind to the shared master column ONCE — every element sourcing master
        # inherits it, so the filter no longer falls off after the first element.
        'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' },
                        'columnId' => mcol_id(disp) }],
      }
    end
  end
  controls
end

if $PROGRAM_NAME == __FILE__
  cards = JSON.parse(File.read(File.join(OUT, 'cards.json'))) rescue []
  pages = JSON.parse(File.read(File.join(OUT, 'pages.json'))) rescue []
  overrides = (JSON.parse(File.read(File.join(OUT, 'kpi-overrides.json'))) rescue {}) || {}

  cards = cards.reject { |c| c['_error'] || c['_tierB'] }
  # Group cards by page (fall back to a single page when page membership is absent).
  by_page = Hash.new { |h, k| h[k] = [] }
  card_page = {}
  pages.each do |p|
    Array(p['cardIds'] || p['cards']).each { |cid| card_page[cid.to_s] = p['title'] || p['name'] || p['id'] }
  end
  cards.each { |c| by_page[card_page[c['id'].to_s] || 'Overview'] << c }
  by_page.each { |pname, pcards| warn_missing_geometry(pname, pcards) }

  out_pages = by_page.map do |pname, pcards|
    els = pcards.map { |c| build_element(c, overrides) }.compact
    els += build_controls(pcards)
    { 'name' => pname, 'elements' => els }
  end

  FileUtils.mkdir_p(OUT)
  File.write(File.join(OUT, 'chart-specs.json'), JSON.pretty_generate('pages' => out_pages))
  File.write(File.join(OUT, 'warnings.json'), JSON.pretty_generate($warnings))
  warn "  wrote #{File.join(OUT, 'chart-specs.json')} (#{out_pages.sum { |p| p['elements'].size }} elements across #{out_pages.size} page(s))"
  warn "  wrote #{File.join(OUT, 'warnings.json')} (#{$warnings.size} warning(s))"
  $warnings.first(20).each { |w| warn "    ⚠ #{w['card']}: #{w['warning']}" }
  warn "\n  Next: build-workbook-spec.rb --chart-specs discovery/chart-specs.json --dm-ids discovery/dm-ids.json ..."
end
