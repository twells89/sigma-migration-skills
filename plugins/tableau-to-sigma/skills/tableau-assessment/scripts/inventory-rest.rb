#!/usr/bin/env ruby
# REST-only site inventory — the Tableau Server fallback for Phase 1/2.
#
# Tableau Cloud exposes the Admin Insights project (usage, licenses, refresh
# history) that the MCP-driven Phase 2 queries. A self-hosted Tableau Server has
# NO Admin Insights — the equivalent lives in the Server repository (a separate
# Postgres "workgroup" DB an admin must enable). This script produces the
# inventory the downstream pipeline needs (build-shortlist.rb, migration-plan.rb)
# from the STANDARD REST endpoints alone: workbooks, views, datasources. It does
# NOT emit usage/refresh stats — those need Admin Insights (Cloud) or the
# repository DB. Per-workbook complexity still comes from fetch-all-twbs.rb +
# scan-workbook-gaps.rb (already REST/PAT and Server-compatible).
#
# Usage:
#   eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/inventory-rest.rb --out /tmp/assessment-<site>
#
# Output:
#   <out>/inventory.json  — { mode, counts, workbook_inventory, datasource_inventory,
#                             workbook_usage: [] }  (shape build-shortlist.rb reads)

require 'json'
require 'fileutils'
require 'optparse'
require 'time'
$LOAD_PATH.unshift File.expand_path('../../tableau-to-sigma/scripts/lib', __dir__)
require 'tableau_rest'

opts = { exclude_projects: ['Personal Space'] }
OptionParser.new do |p|
  p.on('--out DIR') { |v| opts[:out] = v }
  # Comma-separated. Use --exclude-projects '' to include Personal Space.
  p.on('--exclude-projects LIST') { |v| opts[:exclude_projects] = v.split(',').map(&:strip).reject(&:empty?) }
end.parse!
abort('--out required') unless opts[:out]
FileUtils.mkdir_p(opts[:out])

# Walk a paginated Tableau REST collection, returning the flattened array.
# `root`/`item` name the JSON envelope keys, e.g. ('workbooks','workbook').
def list_all(path, root, item)
  out = []
  page = 1
  loop do
    sep = path.include?('?') ? '&' : '?'
    resp = Tableau.request(:get, "#{Tableau.base_path}#{path}#{sep}pageSize=100&pageNumber=#{page}")
    batch = resp.dig(root, item) || []
    batch = [batch] unless batch.is_a?(Array)
    out.concat(batch)
    total = (resp['pagination'] || {})['totalAvailable'].to_i
    break if batch.empty? || out.size >= total
    page += 1
  end
  out
end

caps = (Tableau.capabilities rescue {})
warn "inventory-rest: product=#{caps['product_version'] || '?'} REST API=#{caps['rest_api_version'] || Tableau.api_version}"

workbooks   = list_all('/workbooks',   'workbooks',   'workbook')
datasources = list_all('/datasources', 'datasources', 'datasource')
views       = list_all('/views',       'views',       'view')
warn "listed #{workbooks.size} workbooks, #{datasources.size} datasources, #{views.size} views"

excluded = opts[:exclude_projects]
in_excluded = ->(row) { excluded.include?(row.dig('project', 'name')) }

# Per-workbook sheet count from the views list (each view carries its workbook
# ref) — avoids a get_workbook call per workbook.
sheets_by_wb = Hash.new(0)
views.each { |v| wb = v.dig('workbook', 'id'); sheets_by_wb[wb] += 1 if wb }

workbook_inventory = workbooks.reject(&in_excluded).map do |w|
  {
    'luid'        => w['id'],
    'name'        => w['name'],
    'project'     => w.dig('project', 'name'),
    'owner'       => w.dig('owner', 'name') || w.dig('owner', 'id'),
    'content_url' => w['contentUrl'],
    'created_at'  => w['createdAt'],
    'updated_at'  => w['updatedAt'],
    'size_mb'     => w['size'] && (w['size'].to_f / 1_048_576).round(2),
    'sheet_count' => sheets_by_wb[w['id']],
    # No accesses/actors on Server without Admin Insights / repository DB.
    'accesses'    => 0,
    'actors'      => 0,
  }
end

datasource_inventory = datasources.reject(&in_excluded).map do |d|
  {
    'luid'         => d['id'],
    'name'         => d['name'],
    'project'      => d.dig('project', 'name'),
    'type'         => d['type'],
    'has_extracts' => d['hasExtracts'],
    'updated_at'   => d['updatedAt'],
  }
end

inventory = {
  'mode'         => 'rest-server',
  'generated_at' => Time.now.utc.iso8601,
  'server'       => (Tableau.server_url rescue nil),
  'site_id'      => (Tableau.site_id rescue nil),
  'capabilities' => caps,
  'counts'       => {
    'workbooks'        => workbook_inventory.size,
    'datasources'      => datasource_inventory.size,
    'views'            => views.size,
    'workbooks_raw'    => workbooks.size,
  },
  'excluded_projects'    => excluded,
  'workbook_inventory'   => workbook_inventory,
  'datasource_inventory' => datasource_inventory,
  # Usage requires Admin Insights (Cloud) or the Server repository DB — absent here.
  # build-shortlist.rb tolerates this and ranks by complexity/cost alone.
  'workbook_usage'       => [],
  'usage_available'      => false,
}

out_path = File.join(opts[:out], 'inventory.json')
File.write(out_path, JSON.pretty_generate(inventory))
puts "wrote #{out_path}"
puts "  #{workbook_inventory.size} workbooks, #{datasource_inventory.size} datasources, #{views.size} views"
puts "  mode=rest-server — usage/refresh stats NOT available (needs Admin Insights on Cloud, or the"
puts "  Tableau Server repository DB). Shortlist will rank by complexity/cost only. Run"
puts "  fetch-all-twbs.rb + scan-workbook-gaps.rb next for per-workbook complexity."
