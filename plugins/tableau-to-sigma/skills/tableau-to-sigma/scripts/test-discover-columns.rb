#!/usr/bin/env ruby
# test-discover-columns.rb — discover-columns.rb must consume EVERY page of the
# columns list, not just the first.
#
# The bug this guards (field-reported, 2-workbook enterprise run): Sigma's list
# endpoints default to 50 entries per page. discover-columns.rb did ONE
# un-paginated GET /v2/connections/tables/<inodeId>/columns and read `entries`,
# so any table wider than 50 columns was silently truncated — the DM built from
# it was lopsided (calcs referencing the missing columns fail downstream, with
# no hint the discovery itself was short).
#
# Covered here:
#   1. a 3-page columns list is FULLY concatenated, server order preserved,
#      every request carries an explicit limit, and the opaque nextPage token
#      rides back URL-encoded;
#   2. multi-page fetches announce themselves on stderr (page count);
#   3. the single-page path is byte-shape-identical to before (no pagination
#      noise, same output JSON keys, nested type objects still flattened);
#   4. a server that repeats the same nextPage token forever cannot spin us or
#      return a partial catalog — the command fails closed and writes nothing.
#
# Loopback WEBrick over http:// (same harness as test-dm-reuse-ranking.rb) —
# offline, creds-free, invented fixture names only.
# Run: ruby scripts/test-discover-columns.rb
require 'webrick'
require 'json'
require 'open3'
require 'uri'

DIR    = __dir__
SCRIPT = File.join(DIR, 'discover-columns.rb')
INODE  = 'inode-widefact'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# 120 columns across 3 pages (50/50/20) — mirrors a wide warehouse fact table.
ALL_COLS = (1..120).map do |i|
  # every 3rd column uses the nested { type: { type: ... } } variant the API
  # sometimes returns, so flattening is exercised on every page
  t = (i % 3).zero? ? { 'type' => "VARCHAR#{i}" } : "NUMBER#{i}"
  { 'name' => "WIDE_COL_#{format('%03d', i)}", 'type' => t }
end.freeze
PAGE_TOKENS = [nil, 'tok 2/x', 'tok-3'].freeze # token with space+slash → URL-encoding must survive

requests = []       # every columns query string, in order
mode = :three_pages # :three_pages | :single | :repeat_token

server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
                                 Logger: WEBrick::Log.new(File::NULL),
                                 AccessLog: [])
server.mount_proc('/v2/connection/conn-1/lookup') do |_req, res|
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate('inodeId' => INODE, 'kind' => 'table')
end
server.mount_proc("/v2/connections/tables/#{INODE}/columns") do |req, res|
  res['Content-Type'] = 'application/json'
  requests << (req.query_string || '')
  tok = req.query['page']
  res.body =
    case mode
    when :single
      JSON.generate('entries' => ALL_COLS.first(4), 'nextPage' => nil)
    when :repeat_token
      # pathological server: always the same token — must not loop forever
      JSON.generate('entries' => [ALL_COLS.first(1)].flatten, 'nextPage' => 'same')
    else
      page_idx = PAGE_TOKENS.index(tok) || 0
      entries  = ALL_COLS.each_slice(50).to_a[page_idx] || []
      JSON.generate('entries' => entries, 'nextPage' => PAGE_TOKENS[page_idx + 1])
    end
end
Thread.new { server.start }
sleep 0.2
base = "http://127.0.0.1:#{server.config[:Port]}"
env  = { 'SIGMA_BASE_URL' => base, 'SIGMA_API_TOKEN' => 'offline-test' }
args = ['ruby', SCRIPT, '--connection-id', 'conn-1', '--table-path', 'BENCHDB.PUBLIC.WIDE_FACT']

begin
  # ---- 1+2. three pages: full concatenation, order, limit, token encoding ----
  out, err, st = Open3.capture3(env, *args)
  res = JSON.parse(out) rescue {}
  cols = res['columns'] || []
  check(st.exitstatus.zero?, 'multi-page run exits 0', fails)
  check(cols.size == 120, "all 3 pages concatenated (got #{cols.size}/120 columns)", fails)
  check(cols.map { |c| c['name'] } == ALL_COLS.map { |c| c['name'] },
        'server page order preserved end-to-end', fails)
  check(cols[2]['type'] == 'VARCHAR3' && cols[1]['type'] == 'NUMBER2',
        'nested { type: { type } } objects still flattened on every page', fails)
  check(requests.size == 3, "exactly one request per page (got #{requests.size})", fails)
  check(requests.all? { |q| q =~ /(^|&)limit=\d+/ },
        'every page request carries an explicit limit (never the 50-row server default)', fails)
  check(requests[1].include?('page=' + URI.encode_www_form_component('tok 2/x')),
        'opaque nextPage token echoed back URL-encoded', fails)
  check(err.include?('3 pages') && err.include?('120'),
        'stderr announces the page count + total on a multi-page fetch (operator-visible)', fails)
  check(res['connection_id'] == 'conn-1' && res['inode_id'] == INODE &&
          res['path'] == %w[BENCHDB PUBLIC WIDE_FACT],
        'output shape unchanged (connection_id / path / inode_id keys intact)', fails)

  # ---- 3. single-page path unchanged ----
  requests.clear
  mode = :single
  out, err, st = Open3.capture3(env, *args)
  res = JSON.parse(out) rescue {}
  check(st.exitstatus.zero? && (res['columns'] || []).size == 4,
        'single-page path returns all columns with exit 0', fails)
  check(requests.size == 1, 'single page ⇒ single request (nil nextPage ends the loop)', fails)
  check(!err.include?('pages'), 'no pagination noise on the single-page path', fails)

  # ---- 4. repeated-token server fails closed ----
  requests.clear
  mode = :repeat_token
  out, err, st = Open3.capture3(env, *args)
  check(!st.exitstatus.zero?, 'repeated-token run terminates nonzero (never returns partial columns)', fails)
  check(requests.size == 2, "repeated nextPage token fetched at most twice (got #{requests.size})", fails)
  check(out.empty?, 'repeated-token failure writes no partial JSON to stdout', fails)
  check(err.include?('repeated nextPage token') && err.include?('refusing a partial column list'),
        'the fatal stop names the repeated cursor and partial-list risk on stderr', fails)
ensure
  server.shutdown
end

if fails.empty?
  puts 'ALL PASS'
else
  warn "#{fails.size} FAILURE(S):"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
