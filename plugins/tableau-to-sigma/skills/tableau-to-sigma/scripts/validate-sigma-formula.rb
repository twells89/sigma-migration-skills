#!/usr/bin/env ruby
# Validate that a candidate Sigma formula resolves cleanly against a given
# Sigma data-model context. The primitive used by the gap-scout subagent to
# decide whether a proposed translation actually works.
#
# Usage:
#   ruby scripts/validate-sigma-formula.rb \
#     --formula 'MovingAvg(Sum([Master/Sales]), -10, 10)' \
#     --data-model-id <dm-id> \
#     --master-element-id <element-id>  \
#     [--folder-id <folder-id>] \
#     [--chart-kind bar-chart|line-chart|table]
#
# What it does:
#   1. Builds a tiny Sigma workbook spec with:
#      - Data page: a master table pulling from the supplied DM element
#      - Test page: a single chart that uses the candidate formula as a column
#   2. POSTs to /v2/workbooks/spec
#   3. Reads /v2/workbooks/{id}/elements/{el}/columns and checks for
#      type.type == "error"
#   4. Emits a JSON result to stdout (machine-parseable):
#        { "status": "ok" | "error",
#          "workbook_id": "...",
#          "error_columns": [{ "label": "...", "err": {...} }],
#          "spec_used": {...} }
#
# Env: requires SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET
# (the same as post-and-readback.rb)

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'base64'
require 'optparse'

opts = {
  chart_kind: 'table',
  folder_id: nil
}
OptionParser.new do |p|
  p.on('--formula F')             { |v| opts[:formula] = v }
  p.on('--data-model-id ID')      { |v| opts[:dm_id] = v }
  p.on('--master-element-id ID')  { |v| opts[:el_id] = v }
  p.on('--folder-id ID')          { |v| opts[:folder_id] = v }
  p.on('--chart-kind K')          { |v| opts[:chart_kind] = v }
  p.on('--label L')               { |v| opts[:label] = v }
  p.on('--keep-workbook')         { opts[:keep] = true }
end.parse!
%i[formula dm_id el_id].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL')
CID  = ENV.fetch('SIGMA_CLIENT_ID')
CSEC = ENV.fetch('SIGMA_CLIENT_SECRET')

# --- Auth -----------------------------------------------------------------
def get_token
  uri = URI("#{BASE}/v2/auth/token")
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Basic #{Base64.strict_encode64("#{CID}:#{CSEC}")}"
  req['Content-Type']  = 'application/x-www-form-urlencoded'
  req.body = 'grant_type=client_credentials'
  resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  JSON.parse(resp.body).fetch('access_token')
end
BASE; TOK = get_token

def http(method, path, body: nil, accept_json: true)
  uri = URI("#{BASE}#{path}")
  req = case method
        when :post   then r = Net::HTTP::Post.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
        when :get    then Net::HTTP::Get.new(uri)
        when :delete then Net::HTTP::Delete.new(uri)
        end
  req['Authorization'] = "Bearer #{TOK}"
  req['Accept']        = 'application/json' if accept_json
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
end

# --- Build the test spec ---------------------------------------------------
formula = opts[:formula]
label   = opts[:label] || 'scout-test-col'

# Master needs at least one column to be valid — use a passthrough on whatever
# the DM element exposes. We don't know its specific columns up front; the
# scout caller should already know that [Master/X] refs in the formula resolve
# against the DM's columns. To validate, we POST and read back the chart's
# column types.

# Auto-discover the DM element's columns so test formulas that reference real
# data columns (e.g., `[Master/Gross Revenue]`) resolve cleanly. Without this,
# the test master only exposes a synthetic PassThrough column and any candidate
# touching real data fails with a misleading "dependency not found" error.
dm_spec_resp = http(:get, "/v2/dataModels/#{opts[:dm_id]}/spec")
dm_spec      = JSON.parse(dm_spec_resp.body) rescue {}
dm_element   = (dm_spec['pages'] || []).flat_map { |p| p['elements'] || [] }
                                       .find { |e| e['id'] == opts[:el_id] }
dm_element_name = dm_element && dm_element['name']
dm_cols = (dm_element && dm_element['columns']) || []

# Build passthrough master columns from the DM element. Prefer the element-
# level `name` (which respects any renames the DM author did) over parsing
# the underlying-table name out of `[SOURCE/Col]` formulas — those two can
# differ when the DM renames a column.
master_columns = []
dm_cols.each do |c|
  display_name = c['name']
  if (display_name.nil? || display_name.empty?) && (m = c['formula'].to_s.match(/^\[[^\/]+\/([^\]]+)\]$/))
    display_name = m[1]
  end
  next if display_name.nil? || display_name.empty?
  next unless dm_element_name
  slug = display_name.downcase.gsub(/\W+/, '-').sub(/-$/, '')
  master_columns << {
    'id'      => "m-#{slug}",
    'name'    => display_name,
    'formula' => "[#{dm_element_name}/#{display_name}]"
  }
end
master_columns << { 'id' => 'm-passthrough', 'name' => 'PassThrough', 'formula' => 'RowNumber()' } if master_columns.empty?

master_el = {
  'id'              => 'master',
  'kind'            => 'table',
  'name'            => 'Master',
  'source'          => { 'kind' => 'data-model', 'dataModelId' => opts[:dm_id], 'elementId' => opts[:el_id] },
  'columns'         => master_columns,
  'visibleAsSource' => false
}

test_el = {
  'id'   => 'el-scout-test',
  'kind' => opts[:chart_kind],
  'name' => 'Scout test',
  'source' => { 'kind' => 'table', 'elementId' => 'master' },
  'columns' => [
    { 'id' => 'col-scout-test', 'name' => label, 'formula' => formula }
  ]
}

spec = {
  'name'           => "[scout-test] #{label}-#{Time.now.to_i}",
  'schemaVersion'  => 1,
  'pages' => [
    { 'id' => 'page-data', 'name' => 'Data', 'elements' => [master_el] },
    { 'id' => 'page-test', 'name' => 'Test', 'elements' => [test_el] }
  ]
}
spec['folderId'] = opts[:folder_id] if opts[:folder_id]

# --- POST + readback -------------------------------------------------------
resp = http(:post, '/v2/workbooks/spec', body: JSON.generate(spec))
parsed = (YAML.safe_load(resp.body, permitted_classes: [Date, Time]) rescue nil)
parsed ||= (JSON.parse(resp.body) rescue { 'raw' => resp.body })

wb_id = parsed.is_a?(Hash) && parsed['workbookId']
unless wb_id
  puts JSON.pretty_generate({
    'status' => 'error',
    'phase'  => 'post',
    'workbook_id' => nil,
    'error'  => parsed,
    'spec_used' => spec
  })
  exit 1
end

# Walk both elements; we mostly care about the test element
cols_resp = http(:get, "/v2/workbooks/#{wb_id}/elements/el-scout-test/columns")
cols_data = JSON.parse(cols_resp.body)
entries = cols_data['entries'] || []
error_cols = entries.select do |c|
  t = c['type']
  tt = t.is_a?(Hash) ? t['type'] : t
  tt == 'error'
end

status = error_cols.empty? ? 'ok' : 'error'

# Clean up the throwaway test workbook (unless --keep-workbook). The scout only
# needs the column-type verdict; leaving the workbook behind orphans one file per
# attempt in the customer's folder.
cleaned = false
unless opts[:keep]
  del = http(:delete, "/v2/files/#{wb_id}")
  cleaned = del.code.to_i.between?(200, 299)
end

puts JSON.pretty_generate({
  'status'        => status,
  'phase'         => 'columns',
  'workbook_id'   => wb_id,
  'workbook_cleaned' => cleaned,
  'error_columns' => error_cols.map { |c| { 'label' => c['label'], 'formula' => c['formula'], 'err' => c['type'] } },
  'all_columns'   => entries.map { |c| { 'label' => c['label'], 'type' => (c['type'].is_a?(Hash) ? c['type']['type'] : c['type']) } },
  'spec_used'     => spec
})

exit(status == 'ok' ? 0 : 2)
