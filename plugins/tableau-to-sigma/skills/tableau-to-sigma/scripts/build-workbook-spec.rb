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
           # First non-dim-suffixed element, fallback to first
           dm_elements.find { |e| !(e['name'] || '').end_with?(' Dim') } || dm_elements.first
         end
dm_el_id   = target['id']
dm_el_name = target['name']

# Master columns: either explicit from --master-cols or auto-passthrough from the DM element
master_columns =
  if opts[:master_cols]
    cfg = YAML.safe_load(File.read(opts[:master_cols]))
    cfg['columns'] || abort('master-cols YAML missing `columns:` key')
  else
    # Auto: pull the DM element's column DDL via REST (limited fields — name only)
    # Sigma.request handles initial token fetch + 401-retry-with-refresh.
    $LOAD_PATH.unshift File.expand_path('lib', __dir__)
    require 'sigma_rest'
    spec = Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec")
    el = spec['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == dm_el_id }
    abort("DM element #{dm_el_id} not found in spec") unless el
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
    slug = p['name'].to_s.downcase
    %w[ / ( ) %].each { |ch| slug = slug.tr(ch, '-') }
    slug = slug.tr(' ', '-').gsub(/-+/, '-').sub(/^-/, '').sub(/-$/, '')[0..40]
    visible_pages << {
      'id'       => "page-#{slug}",
      'name'     => p['name'],
      'elements' => p['elements']
    }
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

wb = {
  'name'          => opts[:name],
  'schemaVersion' => 1,
  'folderId'      => opts[:folder_id],
  'pages'         => [data_page] + visible_pages
}
wb['description'] = opts[:description] if opts[:description]

File.write(opts[:out], JSON.pretty_generate(wb))
warn "wrote #{opts[:out]}"
warn "  mode: #{opts[:mode]}"
warn "  Data page: master sourced from '#{dm_el_name}' (#{dm_el_id})  #{master_columns.size} columns"
warn "  visible pages: #{visible_pages.size}"
visible_pages.each { |p| warn "    - #{p['name']}: #{p['elements'].size} elements" }
