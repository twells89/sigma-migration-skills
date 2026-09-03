#!/usr/bin/env ruby
# frozen_string_literal: true
# verify-warehouse.rb — RAW-MODE parity: verify the built workbook against the
# LIVE SIGMA WAREHOUSE when the source tool is unreachable.
#
# Normal Phase 6 diffs each Sigma element against the SOURCE tool's values
# (Tableau view CSV, Looker API, …). When a customer hands over only a raw export
# (.twb/.pbix/.qvf) with no live source, there is nothing to diff against — but
# the warehouse IS reachable. This script proves the next-best, honest thing:
# every built element EVALUATES against the live warehouse connection and returns
# real, column-resolvable, non-empty data (no broken joins, error columns, or
# empty results — the failure modes that make a raw-file conversion "look done"
# but be wrong). It does NOT claim the numbers match the source's rendered output
# — assert-phase6-ran.rb prints a loud banner saying exactly that.
#
# It reuses the verified element-CSV export flow (POST /v2/workbooks/{wb}/export →
# poll GET /v2/query/{q}/download) that collect-parity-actuals.rb uses, through
# lib/sigma_rest (auto-refresh on 401).
#
# Usage:
#   ruby scripts/verify-warehouse.rb --plan <dir>/parity-plan.json \
#     --workbook-id <wb> --workbook-spec <dir>/wb-readback.json \
#     --out <dir>/parity-final.json [--pool 5] [--timeout 120]
#     [--fixture <file>]   # TEST ONLY: {"<element_id>": "<csv text>", ...} instead of the API
#
# Exit codes: 0 = all elements returned warehouse data (status PASS written);
#             2 = one or more elements empty / errored (status FAIL written);
#             1 = bad invocation.

require 'json'
require 'csv'
require 'optparse'
require 'time'

begin
  require_relative 'lib/code_rep'
rescue LoadError
  require_relative '../lib/code_rep'
end

opts = { pool: 5, timeout: 120 }
OptionParser.new do |p|
  p.on('--plan PATH')          { |v| opts[:plan] = v }
  p.on('--workbook-id ID')     { |v| opts[:wb] = v }
  p.on('--workbook-spec PATH') { |v| opts[:spec] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--pool N', Integer)    { |v| opts[:pool] = v }
  p.on('--timeout S', Integer) { |v| opts[:timeout] = v }
  p.on('--fixture PATH', 'TEST ONLY: element_id → CSV text map, bypasses the export API') { |v| opts[:fixture] = v }
end.parse!
%i[plan wb spec out].each { |k| abort "missing --#{k.to_s.tr('_', '-')}" unless opts[k] }

unless opts[:fixture]
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
end

plan = JSON.parse(File.read(opts[:plan]))
charts = plan.is_a?(Hash) ? (plan['charts'] || []) : plan
spec = JSON.parse(File.read(opts[:spec]))
spec = Sigma::CodeRep.document(spec)
elements = Sigma::CodeRep.workbook_elements(spec)
el_by_id = elements.each_with_object({}) { |e, h| h[e['id']] = e }

# Pull one element's CSV — from the fixture (tests) or the live export API.
def element_csv(c, wb, timeout, fixture)
  if fixture
    txt = fixture[c['sigma_element_id']]
    return [:fail, 'no fixture row for element'] if txt.nil?
    return [:ok, txt]
  end
  attempts = 0
  begin
    attempts += 1
    r = Sigma.request(:post, "/v2/workbooks/#{wb}/export",
                      body: JSON.generate({ elementId: c['sigma_element_id'], format: { type: 'csv' } }))
    qid = r && r['queryId']
    return [:fail, "export POST returned no queryId: #{r.inspect[0, 120]}"] unless qid
    t0 = Time.now
    loop do
      return [:fail, "export poll timed out (#{timeout}s)"] if Time.now - t0 > timeout
      sleep 1.0
      begin
        b = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
        return [:ok, b] if b && !b.to_s.empty?   # 204-empty = still rendering
      rescue Sigma::Error => e
        raise unless e.message.lines.first.to_s =~ /\b404\b/
      end
    end
  rescue Sigma::Error, Timeout::Error, Errno::ETIMEDOUT => e
    msg = e.message.lines.first.to_s
    if attempts < 4 && msg =~ /\b(429|408|50[234])\b|Too Many Requests|timed? ?out/i
      sleep((1.5 * (2**(attempts - 1))) + rand * 0.5)
      retry
    end
    [:fail, msg[0, 160]]
  end
end

# Verify one element returns real warehouse data: non-empty rows, all plan
# columns present in the export headers, and at least one non-blank cell.
# A cell that is itself a Sigma query-error string is NOT real data — the element
# rendered "Invalid Query: Unknown…" / "#ERROR". The old has_value check treated
# these as non-blank and PASSed a visibly-broken workbook (handoff FIX 2).
ERROR_CELL = /\A\s*(Invalid Query|Error\b|#REF|#ERROR|#VALUE|#NAME)/i

def verify_chart(c, el_by_id, error_element_ids, wb, timeout, fixture)
  # An element that owns a type=error column (the signal Gate 3 uses) can never
  # be warehouse-verified — fail it before we even look at the CSV.
  if error_element_ids.include?(c['sigma_element_id'])
    return [:fail, 'element owns a type=error column (broken formula — see /columns)']
  end
  status, payload = element_csv(c, wb, timeout, fixture)
  return [:fail, payload] if status == :fail
  rows = (CSV.parse(payload) rescue [])
  return [:fail, 'export CSV empty / unparseable'] if rows.empty?
  headers = rows.shift.map { |h| h.to_s.strip }
  data = rows
  return [:fail, 'no data rows (element returned headers only — empty result / broken join)'] if data.empty?

  # Reject query-error sentinels appearing as cell values.
  bad = data.flatten.find { |cell| cell.to_s =~ ERROR_CELL }
  return [:fail, "element returned query-error cells: #{bad.to_s.strip[0, 60]}"] if bad

  # pivot-table exports the wide grid (not the plan's long tuples); a non-empty
  # grid is the strongest honest assertion we can make for it.
  unless c['sigma_kind'] == 'pivot-table'
    el = el_by_id[c['sigma_element_id']]
    if el
      name_for = (el['columns'] || []).each_with_object({}) { |col, h| h[col['id']] = col['name'].to_s.strip }
      want = (c['sigma_columns'] || []).map { |id| name_for[id] }.compact
      missing = want.reject { |n| headers.any? { |h| h.casecmp?(n) } }
      return [:fail, "plotted column(s) absent from export: #{missing.join(', ')}"] unless missing.empty?
    end
  end

  has_value = data.any? { |r| r.any? { |cell| !cell.to_s.strip.empty? } }
  return [:fail, 'all cells blank (element evaluated to nothing)'] unless has_value
  [:ok, "#{data.size} row(s)"]
end

# Belt-and-suspenders: the warehouse-verified stamp must never land on a workbook
# with type=error columns. Fetch /columns exhaustively (one paginated scan, not one
# request) and collect the owning element ids (the same signal assert-phase6 Gate 3
# uses). Skipped in fixture/test mode.
error_element_ids = []
unless opts[:fixture]
  begin
    # PAGINATED: this read had NO limit param, so it truncated at the server default
    # of 50 and the verifier audited 50 of N columns — reporting clean on a wide
    # workbook. list_entries returns the flat Array, so there is no ['entries'] unwrap.
    cols = (Sigma.list_entries("/v2/workbooks/#{opts[:wb]}/columns") rescue []) || []
    error_element_ids = cols.select { |c| c.dig('type', 'type') == 'error' }.map { |c| c['elementId'] }.compact.uniq
    warn "verify-warehouse: #{error_element_ids.size} element(s) own type=error columns — will fail" unless error_element_ids.empty?
  rescue => e
    warn "verify-warehouse: /columns scan unavailable (#{e.message.lines.first.to_s.strip[0, 80]}) — relying on per-cell error detection"
  end
end

require 'thread'
fixture_data = opts[:fixture] && JSON.parse(File.read(opts[:fixture]))
queue = Queue.new
charts.each { |c| queue << c }
results = {}
mutex = Mutex.new
Array.new([opts[:pool], [charts.size, 1].max].min.clamp(1, 16)) do
  Thread.new do
    loop do
      c = (queue.pop(true) rescue break)
      st, why = verify_chart(c, el_by_id, error_element_ids, opts[:wb], opts[:timeout], fixture_data)
      mutex.synchronize { results[c['chart']] = [st, why] }
    end
  end
end.each(&:join)

passed = results.select { |_, (s, _)| s == :ok }.keys
failed = results.select { |_, (s, _)| s == :fail }
total = results.size
status = (total > 0 && failed.empty?) ? 'PASS' : 'FAIL'

summary = {
  'workbook_id'      => opts[:wb],
  'ran_at'           => Time.now.utc.iso8601,
  'mode'             => 'warehouse',
  'verified_against' => 'warehouse',
  'charts_total'     => total,
  'charts_pass'      => passed.size,
  'charts_fail'      => failed.size,
  'pass_names'       => passed,
  'fail_names'       => failed.keys,
  'status'           => status,
  'note'             => 'Raw-mode: each element verified to evaluate against the live Sigma ' \
                        'warehouse and return data. NOT diffed against the source tool (unreachable).',
}
# preserve tile_census if a prior parity-final.json had one (dashboard zone gate)
if File.exist?(opts[:out])
  prior = (JSON.parse(File.read(opts[:out])) rescue {})
  summary['tile_census'] = prior['tile_census'] if prior.is_a?(Hash) && prior['tile_census']
end
File.write(opts[:out], JSON.pretty_generate(summary))

puts "verify-warehouse: #{passed.size}/#{total} element(s) returned live warehouse data → status=#{status}"
failed.each { |name, (_, why)| puts "  FAIL  #{name}: #{why}" }
puts "  → #{opts[:out]} (verified_against=warehouse). assert-phase6-ran.rb will flag this as warehouse-verified."
exit(status == 'PASS' ? 0 : 2)
