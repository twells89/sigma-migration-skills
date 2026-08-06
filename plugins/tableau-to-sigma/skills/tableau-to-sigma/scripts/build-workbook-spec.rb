#!/usr/bin/env ruby
# Assemble a complete Sigma workbook spec from build-charts-from-signals
# output + DM IDs + a master-columns config. Replaces the per-conversion
# hand-written assemble-*.py one-offs that crept in during dashboard-mode
# conversions.
#
# Usage:
#   ruby scripts/build-workbook-spec.rb \
#     --chart-specs /tmp/<name>/chart-specs.json    # build-charts-from-signals output
#     --dm-ids      /tmp/<name>/dm-ids.json         # post-and-readback output for the DM
#     --master-cols /tmp/<name>/master-columns.yaml # see schema below
#     --workbook-name "<name>"
#     --description "<one-liner>"
#     --folder-id   <uuid>
#     [--mode dashboard|page-per-worksheet]         # default: page-per-worksheet
#     [--dm-element-name "Order Fact"]              # which DM element the master sources from (default: first non-Date)
#     [--layout /tmp/<name>/dashboard-layout.json]  # parse-twb-layout output — derives themeName + themeOverrides
#                                                    #   (backgroundCanvas from the page fill; categoricalScheme
#                                                    #   from the tinted region-card palette). Omit → no theme.
#     --out /tmp/<name>/wb-spec.json
#
# --master-cols schema (YAML):
#   columns:
#     - { id: m-order-id,      name: "Order Id",       formula: "[Order Fact/Order Id]" }
#     - { id: m-order-date,    name: "Order Date",     formula: "[Order Fact/Order Date]" }
#     - { id: m-gross-revenue, name: "Gross Revenue",  formula: "[Order Fact/Gross Revenue]" }
#     ...
#
# Or omit --master-cols entirely: the script will auto-build a master that
# passes through every column of the named DM element by name. Suitable for
# small workbooks; for complex masters with renames or Lookup columns, supply
# the YAML explicitly.

require 'json'
require 'yaml'
require 'optparse'
require 'net/http'
require 'uri'
require_relative 'lib/theme_derive'
require 'base64'

opts = { mode: 'page-per-worksheet' }
OptionParser.new do |p|
  p.on('--chart-specs PATH')    { |v| opts[:specs] = v }
  p.on('--dm-ids PATH')         { |v| opts[:dm_ids] = v }
  p.on('--master-cols PATH')    { |v| opts[:master_cols] = v }
  p.on('--workbook-name S')     { |v| opts[:name] = v }
  p.on('--description S')       { |v| opts[:description] = v }
  p.on('--folder-id S')         { |v| opts[:folder_id] = v }
  p.on('--mode S')              { |v| opts[:mode] = v }
  p.on('--dm-element-name S')   { |v| opts[:dm_el_name] = v }
  p.on('--layout PATH', 'parse-twb-layout output — used to derive workbook theme (canvas + region palette)') { |v| opts[:layout] = v }
  # PLAN-v3 PR-17 (flag-staged, default OFF). Give each content page that draws
  # on the master its own master instance so page controls filter only that
  # page's tiles (a shared cross-page master composes every page's filters on
  # one master — V5.6-CONTROLS-AUDIT D11). No-op unless >=2 pages use the master.
  p.on('--per-page-masters', 'PR-17: per-page master instances (no-op for single-page workbooks)') { opts[:ppm] = true }
  p.on('--out PATH')            { |v| opts[:out] = v }
end.parse!
%i[specs dm_ids name folder_id out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }
abort("--mode must be dashboard or page-per-worksheet") unless %w[dashboard page-per-worksheet].include?(opts[:mode])

specs   = JSON.parse(File.read(opts[:specs]))
dm_ids  = JSON.parse(File.read(opts[:dm_ids]))

dm_id = dm_ids['dataModelId'] || abort('dm-ids.json missing dataModelId')

# Find the DM element to source the master from. Default heuristic: pick the
# first element whose name doesn't start with a dimension-table prefix
# (Date Dim / Customer Dim / etc.). User can override via --dm-element-name.
dm_elements = (dm_ids['pages'] || []).flat_map { |p| p['elements'] || [] }
abort('no elements in dm-ids') if dm_elements.empty?
target = if opts[:dm_el_name]
           dm_elements.find { |e| e['name'] == opts[:dm_el_name] } ||
             abort("no DM element named #{opts[:dm_el_name].inspect}")
         else
           # First non-dim-suffixed element, but only among elements that actually
           # carry columns. The readback exposes columns via 'columnLabels'; an
           # extract-landed (or multi-datasource) DM has NAMELESS master-shell
           # elements with ZERO columns that must NOT be chosen — picking one
           # aborts at 'no master columns to emit'. Skipping empty shells keeps
           # the original "first non-dim" order for normal single-fact DMs.
           width = ->(e) { (e['columnLabels'] || e['columns'] || []).size }
           bearing = dm_elements.select { |e| width.call(e).positive? }
           bearing = dm_elements if bearing.empty?
           bearing.find { |e| !(e['name'] || '').end_with?(' Dim') } || bearing.first
         end
dm_el_id   = target['id']
dm_el_name = target['name']
# A DM element is often NAMELESS in the spec (rule 3: omit the element-level
# name). Sigma then assigns a name on the server BY KIND, and the master column
# formula must use that server name or it references a phantom element and the
# workbook POSTs but renders EMPTY. Fetch the spec up front so we can both name
# the element correctly and (in auto mode) read its columns.
#   • warehouse-table  → the table's last path segment (e.g. an extract-landed
#                        or direct-table element: MY_SCHEMA.MY_TABLE → "MY_TABLE")
#   • everything else  → "Custom SQL" (SQL / published-DS elements)
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
spec = Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec")
el = spec['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == dm_el_id }
abort("DM element #{dm_el_id} not found in spec") unless el
if dm_el_name.to_s.strip.empty?
  src = el['source'] || {}
  dm_el_name = if src['kind'] == 'warehouse-table' && !Array(src['path']).empty?
                 Array(src['path']).last
               else
                 'Custom SQL'
               end
end

# Master columns: either explicit from --master-cols or auto-passthrough from the DM element
master_columns =
  if opts[:master_cols]
    cfg = YAML.safe_load(File.read(opts[:master_cols]))
    cfg['columns'] || abort('master-cols YAML missing `columns:` key')
  else
    (el['columns'] || []).map do |c|
      nm = c['name'] || (c['formula'].to_s.match(/^\[[^\/]+\/([^\]]+)\]$/) || [nil, c['id']])[1]
      slug = nm.to_s.downcase.gsub(/\W+/, '-').sub(/-$/, '')
      { 'id' => "m-#{slug}", 'name' => nm, 'formula' => "[#{dm_el_name}/#{nm}]" }
    end
  end
abort('no master columns to emit') if master_columns.empty?

# Dedupe master column ids: two DM columns whose distinct display names slug to the
# same id (e.g. a calc "Market Maker" alongside the physical "MARKET_MAKER") would
# emit a duplicate id and 400 the workbook POST ("Duplicate id"). Names/formulas stay
# distinct (charts reference by name), so we only need to make the ids unique — keep
# the first, suffix later collisions (-2, -3, …).
seen_master_ids = {}
master_columns.each do |c|
  base = c['id']
  next unless seen_master_ids[base]
  n = 2
  n += 1 while seen_master_ids["#{base}-#{n}"]
  c['id'] = "#{base}-#{n}"
ensure
  seen_master_ids[c['id']] = true
end

# Build the data page. Beyond the master, build-charts may emit hidden helper
# elements (scatter grouped sources, FIXED/INCLUDE/EXCLUDE LOD two-level
# helpers, window helpers, aggregate-derived dimension helpers — y9rd.13) under
# the top-level `data_elements` key; they source the master (or each other) and
# the visible charts source THEM, so they must live on the Data page or the
# workbook POST 400s "Dependency not found". They carry visibleAsSource:false.
helper_elements = (specs.is_a?(Hash) && specs['data_elements']) || []
data_page = {
  'id'   => 'page-data',
  'name' => 'Data',
  'elements' => [{
    'id'   => 'master',
    'kind' => 'table',
    'name' => 'Master',
    'visibleAsSource' => false,
    'source' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => dm_el_id },
    'columns' => master_columns,
    'order'   => master_columns.map { |c| c['id'] }
  }] + helper_elements
}
warn "  Data page: + #{helper_elements.size} hidden helper element(s) [#{helper_elements.map { |h| h['id'] }.join(', ')}]" if helper_elements.any?

# Build the visible pages from chart-specs.json
# Two shapes:
#  - dashboard mode: chart-specs.json is a flat array → one page with all elements
#  - page-per-worksheet: chart-specs.json is { pages: [{name, elements}, ...] }
visible_pages = []
if specs.is_a?(Hash) && specs['pages']
  specs['pages'].each do |p|
    # K2: allow-list, not deny-list. The old hand-listed set (/ ( ) %) plus space
    # left ? ! # & and every other punctuation mark in the id — a Tableau page
    # "How many weeks?" became `page-how-many-weeks?`, which Sigma rejects.
    slug = p['name'].to_s.downcase.gsub(/[^a-z0-9]+/, '-')
                    .sub(/\A-/, '').sub(/-\z/, '')[0..40].to_s
    page = {
      'id'       => "page-#{slug}",
      'name'     => p['name'],
      'elements' => p['elements']
    }
    # v5.0: designed-background passthrough (build-charts attaches
    # backgroundImage to its page hashes; a 3-key copy silently strips it).
    page['backgroundImage'] = p['backgroundImage'] if p['backgroundImage']
    visible_pages << page
  end
elsif specs.is_a?(Array)
  # Dashboard mode → single visible page
  visible_pages << {
    'id'       => 'page-overview',
    'name'     => opts[:name] && opts[:mode] == 'dashboard' ? opts[:name].sub(/\(.*\)$/, '').strip : 'Overview',
    'elements' => specs
  }
else
  abort('chart-specs.json must be either { pages: [...] } or [ ... ]')
end

# Derive the workbook theme from the parsed layout — shared implementation in
# lib/theme_derive.rb (v5.0: fonts + pageWidth + canvas + categoricalScheme) so
# this standalone path and the orchestrated mechanical path cannot diverge.
def derive_theme(layout)
  ThemeDerive.derive(layout)
end

wb = {
  'name'          => opts[:name],
  'schemaVersion' => 1,
  'folderId'      => opts[:folder_id],
  'pages'         => [data_page] + visible_pages
}
wb['description'] = opts[:description] if opts[:description]

# Phase-1 theme (D1 palette + Pass-7 canvas; v5.0 adds fonts + pageWidth),
# when a --layout was provided. Shared emission (ThemeDerive.apply!).
if opts[:layout]
  theme = derive_theme(JSON.parse(File.read(opts[:layout])))
  ThemeDerive.apply!(wb, theme)
  unless theme.empty?
    warn "  theme: canvas=#{theme['backgroundCanvas'] || '(default)'}, " \
         "fonts=#{(theme['fonts'] || {}).values.uniq.join('/')}, " \
         "pageWidth=#{theme['maxPageWidth'] || '(default)'}, " \
         "categoricalScheme=#{(theme['categoricalScheme'] || []).size} color(s)"
  end
end

# PR-17: per-page master instances (flag-staged, default OFF). Final structural
# pass — self-gating, so it only changes multi-page workbooks that actually
# share a master; single-page output is byte-identical.
if opts[:ppm]
  require_relative 'lib/per_page_masters'
  ppm = PerPageMasters.split!(wb)
  warn "  per-page-masters (PR-17): #{ppm[:applied] ? "#{ppm[:masters]} master instance(s) across #{ppm[:pages]} page(s), #{ppm[:clones]} Data-page element(s)" : 'no split needed (<=1 page draws on the master)'}"
end

File.write(opts[:out], JSON.pretty_generate(wb))
warn "wrote #{opts[:out]}"
warn "  mode: #{opts[:mode]}"
warn "  Data page: master sourced from '#{dm_el_name}' (#{dm_el_id})  #{master_columns.size} columns"
warn "  visible pages: #{visible_pages.size}"
visible_pages.each { |p| warn "    - #{p['name']}: #{p['elements'].size} elements" }
