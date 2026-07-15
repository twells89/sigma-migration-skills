#!/usr/bin/env ruby
# frozen_string_literal: true
#
# probe-window-contexts.rb — live evidence for WHERE Sigma-native window
# functions resolve. OPTIONAL diagnostic (like probe-control-formula.rb): run it
# to re-prove the family rule in refs/window-functions.md on the current org
# rather than trust the doc.
#
# It settles the load-bearing question: is a Sigma-native window function
# (Cumulative*/Moving*/Rank*/RowNumber/Lag/Lead/PercentOfTotal) restricted to
# chart-element yAxis formulas, or does it also resolve in calc columns of
# workbook tables and data-model elements?
#
# It builds throwaway artifacts sourced from a data-model base element and
# checks resolve-vs-error via CSV export across THREE calc-column contexts:
#   1. GROUPED workbook table       (groupBy a dim)
#   2. UNGROUPED workbook "master"  (base grain, visibleAsSource-style)
#   3. DM-ELEMENT calc column       (a clone of the DM with the calcs inline)
# plus the *Over family (SumOver/CountOver) as a negative control.
#
# Result (verified 2026-07-15, WINPROBE Base): the native family resolves in ALL
# THREE contexts; only the *Over family is "Unknown function". This is why the
# old "chart yAxis ONLY" placement rule was corrected.
#
# Usage:  bash -c 'eval "$(scripts/get-token.sh)" && ruby scripts/probe-window-contexts.rb'
# Env:    SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (see sigma-api).
#         DM_ID / EL_ID / EL_NAME override the source element (default: WINPROBE Base).
#         KEEP=1 keeps the throwaway workbook + data model instead of deleting.
# Exit:   0 if every native fn resolved in every context; 1 otherwise.

require 'json'
require 'csv'
require 'net/http'
require 'uri'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'

DM_ID   = ENV['DM_ID']   || '01d5deb8-de64-485d-a428-e368afc6963b' # WINPROBE Base
EL_ID   = ENV['EL_ID']   || 'p13miPuGpa'                           # "Orders Base"
EL_NAME = ENV['EL_NAME'] || 'Orders Base'
MEASURE = ENV['MEASURE'] || 'Net Revenue'
DATEDIM = ENV['DATEDIM'] || 'Order Date'
COUNTCOL = ENV['COUNTCOL'] || 'Order Id'

REV = "Sum([#{EL_NAME}/#{MEASURE}])"
# label => formula. *_CTL are the *Over negative control (expected: Unknown function).
NATIVE = {
  'CumulativeSum'  => "CumulativeSum(#{REV})",
  'MovingSum'      => "MovingSum(#{REV}, 7)",
  'MovingAvg'      => "MovingAvg(#{REV}, 7)",
  'Rank'           => "Rank(#{REV}, \"desc\")",
  'RankDense'      => "RankDense(#{REV}, \"desc\")",
  'RowNumber'      => 'RowNumber()',
  'Lag'            => "Lag(#{REV}, 1)",
  'Lead'           => "Lead(#{REV}, 1)",
  'PercentOfTotal' => "PercentOfTotal(#{REV}, \"grand_total\")",
}
CONTROL = {
  'SumOver_CTL'    => "SumOver(#{REV})",
  'CountOver_CTL'  => "CountOver([#{EL_NAME}/#{COUNTCOL}])",
}
ALL = NATIVE.merge(CONTROL)

def jget(p); Sigma.request(:get, p); end

def export_row(wb, eid, timeout = 120)
  res = Sigma.request(:post, "/v2/workbooks/#{wb}/export",
                      body: JSON.generate({ 'elementId' => eid, 'format' => { 'type' => 'csv' } }))
  qid = res.is_a?(Hash) && res['queryId']
  raise "export request failed: #{res.inspect}" unless qid
  deadline = Time.now + timeout
  loop do
    uri = URI("#{Sigma.base_url}/v2/query/#{qid}/download")
    req = Net::HTTP::Get.new(uri); req['Authorization'] = "Bearer #{Sigma.auth_token}"
    r = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { |h| h.request(req) }
    return CSV.parse(r.body, headers: true).first if r.code.to_i == 200
    raise "download HTTP #{r.code}: #{r.body.to_s[0, 300]}" if r.code.to_i >= 400 && r.code.to_i != 404
    raise "export timeout (#{qid})" if Time.now > deadline
    sleep 2
  end
end

# classify a first-row cell. A native fn that returns a real number (or a
# legitimately-null Lag/Lead first row) resolved; an "error/unknown/..." token
# means it failed. Only *_CTL is expected to fail.
def classify(v)
  s = v.to_s
  return %i[blank BLANK/nil] if v.nil? || s.strip.empty?
  return [:error, "ERROR(#{s[0, 60]})"] if s =~ /error|unknown|expected|argument|invalid|#REF/i
  [:ok, "OK(#{s[0, 24]})"]
end

def find_home
  me = jget('/v2/whoami'); uid = me['userId']
  mem = uid ? (jget("/v2/members/#{uid}") rescue nil) : nil
  [me, mem].compact.map { |h| h['homeFolderId'] || h['homeFolder'] }.compact.first
end

def find_schema_version
  (jget('/v2/workbooks?limit=30')['entries'] || []).each do |w|
    wid = w['workbookId'] || w['id']; next unless wid
    s = (Sigma.request(:get, "/v2/workbooks/#{wid}/spec", accept: 'application/json') rescue next)
    return s['schemaVersion'] if s.is_a?(Hash) && s['schemaVersion']
  end
  1
end

HOME = find_home or abort 'no home folder resolvable'
SV   = find_schema_version
puts "source: dm=#{DM_ID} element=#{EL_NAME} (#{EL_ID})  home=#{HOME}  schemaVersion=#{SV}"

created = [] # [type, id] for cleanup
results = {} # context => { label => [status, display] }

# ---- contexts 1 & 2: workbook table calc columns (grouped + ungrouped) ------
date_col = { 'id' => 'g_date', 'name' => DATEDIM, 'formula' => "[#{EL_NAME}/#{DATEDIM}]" }
wf_cols  = ALL.map { |lbl, f| { 'id' => "wf_#{lbl}", 'name' => lbl, 'formula' => f } }
grouped = {
  'kind' => 'table', 'id' => 'tbl-grouped', 'name' => 'GROUPED',
  'source' => { 'kind' => 'data-model', 'dataModelId' => DM_ID, 'elementId' => EL_ID },
  'columns' => [date_col] + wf_cols,
  'groupings' => [{ 'id' => 'grp', 'groupBy' => ['g_date'], 'calculations' => wf_cols.map { |c| c['id'] },
                    'sort' => [{ 'columnId' => 'g_date', 'direction' => 'ascending' }] }],
  'order' => ['g_date'] + wf_cols.map { |c| c['id'] },
}
ungrouped = {
  'kind' => 'table', 'id' => 'tbl-master', 'name' => 'UNGROUPED',
  'source' => { 'kind' => 'data-model', 'dataModelId' => DM_ID, 'elementId' => EL_ID },
  'columns' => [date_col.merge('id' => 'u_date')] + wf_cols.map { |c| c.merge('id' => "u_#{c['id']}") },
  'order' => ['u_date'] + wf_cols.map { |c| "u_#{c['id']}" },
}
wb_spec = { 'name' => 'ZZ probe-window-contexts (throwaway)', 'folderId' => HOME, 'schemaVersion' => SV,
            'description' => 'window-function calc-column context probe',
            'pages' => [{ 'id' => 'pg', 'name' => 'Probe', 'elements' => [grouped, ungrouped] }] }
wresp = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(wb_spec),
                      content_type: 'application/json', accept: 'application/json')
wb = wresp['workbookId'] || wresp['id']
abort "workbook CREATE failed: #{wresp.inspect}" unless wb
created << ['file', wb]
puts "created workbook #{wb} (POST clean)"

{ 'grouped table' => 'tbl-grouped', 'ungrouped master' => 'tbl-master' }.each do |label, eid|
  results[label] = {}
  begin
    row = export_row(wb, eid)
    ALL.each_key { |lbl| results[label][lbl] = classify(row && (row[lbl] rescue nil)) }
  rescue StandardError => e
    ALL.each_key { |lbl| results[label][lbl] = [:error, "EXPORT ERR: #{e.message[0, 40]}"] }
  end
end

# ---- context 3: DM-element calc column --------------------------------------
# Clone the DM spec, add the calcs inline to the element, create a throwaway DM,
# then source it from a passthrough workbook table and export.
begin
  raw = Sigma.request(:get, "/v2/dataModels/#{DM_ID}/spec")
  pages = raw['pages']
  el = nil
  find_el = lambda { |n| case n
    when Hash then el = n if n['id'] == EL_ID; n.each_value(&find_el)
    when Array then n.each(&find_el) end }
  find_el.call(pages)
  raise 'element not found in DM spec' unless el
  # Ref-form gotcha: INSIDE a DM element, calc columns reference sibling columns
  # by BARE name ([Net Revenue]); the qualified [Element/Col] form (correct for
  # workbook columns) 400s here with "dependency not found". So rebuild the
  # native family against a bare measure ref. NATIVE only: a DM-spec POST also
  # hard-rejects *Over formulas (400) — those live in the workbook contexts.
  dm_rev = "Sum([#{MEASURE}])"
  dm_native = {
    'CumulativeSum' => "CumulativeSum(#{dm_rev})", 'MovingSum' => "MovingSum(#{dm_rev}, 7)",
    'MovingAvg' => "MovingAvg(#{dm_rev}, 7)", 'Rank' => "Rank(#{dm_rev}, \"desc\")",
    'RankDense' => "RankDense(#{dm_rev}, \"desc\")", 'RowNumber' => 'RowNumber()',
    'Lag' => "Lag(#{dm_rev}, 1)", 'Lead' => "Lead(#{dm_rev}, 1)",
    'PercentOfTotal' => "PercentOfTotal(#{dm_rev}, \"grand_total\")",
  }
  dm_native.each { |lbl, f| el['columns'] << { 'id' => "wf_#{lbl}", 'name' => "WF_#{lbl}", 'formula' => f } }

  dm_spec = { 'name' => 'ZZ probe-window-contexts DM (throwaway)', 'folderId' => HOME,
              'schemaVersion' => raw['schemaVersion'], 'pages' => pages }
  dresp = Sigma.request(:post, '/v2/dataModels/spec', body: JSON.generate(dm_spec),
                        content_type: 'application/json', accept: 'application/json')
  dm2 = dresp['dataModelId'] || dresp['id']
  raise "DM CREATE failed: #{dresp.inspect}" unless dm2
  created << ['file', dm2]

  back = Sigma.request(:get, "/v2/dataModels/#{dm2}/spec")
  new_el = nil
  find_by_name = lambda { |n| case n
    when Hash then new_el = n if n['name'] == EL_NAME && n['columns']; n.each_value(&find_by_name)
    when Array then n.each(&find_by_name) end }
  find_by_name.call(back['pages'])
  raise 'cloned element not found on readback' unless new_el

  cols = NATIVE.keys.map { |lbl| { 'id' => "p_#{lbl}", 'name' => lbl, 'formula' => "[#{EL_NAME}/WF_#{lbl}]" } }
  wb2_spec = { 'name' => 'ZZ probe-window-contexts DM-WB (throwaway)', 'folderId' => HOME, 'schemaVersion' => SV,
               'pages' => [{ 'id' => 'pg', 'name' => 'P', 'elements' => [
                 { 'kind' => 'table', 'id' => 't', 'name' => 'DM passthrough',
                   'source' => { 'kind' => 'data-model', 'dataModelId' => dm2, 'elementId' => new_el['id'] },
                   'columns' => cols, 'order' => cols.map { |c| c['id'] } }] }] }
  w2resp = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(wb2_spec),
                         content_type: 'application/json', accept: 'application/json')
  wb2 = w2resp['workbookId'] || w2resp['id']
  raise "DM-WB CREATE failed: #{w2resp.inspect}" unless wb2
  created << ['file', wb2]

  results['DM-element'] = {}
  row = export_row(wb2, 't')
  NATIVE.each_key { |lbl| results['DM-element'][lbl] = classify(row && (row[lbl] rescue nil)) }
  CONTROL.each_key { |lbl| results['DM-element'][lbl] = [:na, 'n/a (400 on POST)'] }
rescue StandardError => e
  results['DM-element'] ||= {}
  ALL.each_key { |lbl| results['DM-element'][lbl] = [:error, "SETUP ERR: #{e.message[0, 40]}"] }
end

# ---- report -----------------------------------------------------------------
contexts = results.keys
puts "\n%-16s %s" % ['FUNCTION', contexts.map { |c| c.ljust(22) }.join]
ALL.each_key do |lbl|
  cells = contexts.map { |c| (results[c][lbl] || [:blank, '-'])[1].to_s.ljust(22) }
  puts format('%-16s %s', lbl, cells.join)
end

# a native fn "passed" if it is :ok in every context (:blank allowed for Lag/Lead
# first-row null in a grouped context). *_CTL is expected to error → not a failure.
native_fail = NATIVE.keys.reject do |lbl|
  contexts.all? { |c| %i[ok blank].include?((results[c][lbl] || [:error])[0]) }
end
control_ok = CONTROL.keys.all? { |lbl| contexts.any? { |c| (results[c][lbl] || [])[0] == :error } }

# cleanup
if ENV['KEEP'] == '1'
  puts "\nKEPT: #{created.map { |_, id| id }.join(', ')}"
else
  created.reverse_each { |_, id| Sigma.request(:delete, "/v2/files/#{id}", accept: 'application/json') rescue nil }
  puts "\ndeleted #{created.size} throwaway artifact(s)"
end

if native_fail.empty? && control_ok
  puts "\nPASS — native window family resolves in ALL calc-column contexts; *Over family errors as expected."
  exit 0
else
  puts "\nFAIL — native fns that did NOT resolve everywhere: #{native_fail.inspect}" unless native_fail.empty?
  puts "FAIL — *Over control did not error (expected Unknown function)" unless control_ok
  exit 1
end
