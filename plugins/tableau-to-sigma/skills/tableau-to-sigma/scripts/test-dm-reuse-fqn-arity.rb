#!/usr/bin/env ruby
# test-dm-reuse-fqn-arity.rb — find-or-pick-dm.rb must match warehouse tables
# ARITY-AWARE, so a signature that could not resolve the DATABASE still matches a
# DM that stores the fully-qualified path.
#
# The bug this guards (live-caught, and the true root cause of "every migration
# posts another data model"): QuickSight's dataset JSON carries only Schema + Name
# — the database lives in the separate DataSource object — so its signature emits
# "SCHEMA.TABLE" while every Sigma DM spec stores ["DB","SCHEMA","TABLE"].
# Comparing the joined strings failed on the arity difference alone. Measured
# against three data models built FROM that very table:
#
#   column_match 1.0, missing_columns []             <- every column present
#   table_match  0.0, missing_tables [SCHEMA.TABLE]  <- "doesn't cover the table"
#
# and because table_match 0.0 => covers_tables false => is_superset false, the
# wide-tie guard fired and reuse was refused FOREVER, with the score capped near
# 0.7 so it could never clear the auto-pick bar. Relevance ranking had already put
# the right candidates in front of the scorer; this is what let the scorer
# recognise them. After the fix the same signature scores 0.9 and auto-picks with
# 1/1 tables and 10/10 columns.
#
# Loopback WEBrick over http:// — offline, creds-free.
# Run: ruby scripts/test-dm-reuse-fqn-arity.rb
require 'webrick'
require 'json'
require 'tmpdir'
require 'open3'
require 'time'

$fail = 0
def ok(desc); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"; $fail += 1 unless r; end

PICKER = File.expand_path('find-or-pick-dm.rb', __dir__)
COLS = %w[SALE_DATE REGION SEGMENT REVENUE].freeze

# Three data models, all carrying the FULL db.schema.table path:
#   exact      — the db-qualified twin of the signature's schema.table
#   other_db   — same schema.table under a DIFFERENT database (the db is unknowable
#                from the source, so this must still count as covering)
#   other_schm — same table name under a different SCHEMA (must NOT match)
DMS = {
  'dm-exact'      => { name: 'Pipeline Fact Model',     path: %w[ACME SALES PIPELINE_FACT],   cols: COLS },
  'dm-other-db'   => { name: 'Pipeline Fact Warehouse', path: %w[OTHER SALES PIPELINE_FACT],  cols: COLS },
  'dm-other-schm' => { name: 'Pipeline Fact Staging',   path: %w[ACME STAGING PIPELINE_FACT], cols: COLS }
}.freeze

def dm_list
  DMS.map.with_index { |(id, d), i| { 'dataModelId' => id, 'name' => d[:name],
                                      'updatedAt' => (Time.now.utc - i * 60).iso8601 } }
end

def spec_for(id)
  d = DMS[id] or return { 'pages' => [] }
  { 'pages' => [{ 'elements' => [
    { 'source' => { 'kind' => 'warehouse-table', 'path' => d[:path] },
      'columns' => d[:cols].map { |c| { 'name' => c } } }
  ] }] }
end

server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
                                 Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
server.mount_proc('/v2/dataModels') do |req, res|
  res['Content-Type'] = 'application/json'
  res.body = if (m = req.path.match(%r{/v2/dataModels/([^/]+)/spec}))
               JSON.generate(spec_for(m[1]))
             else
               JSON.generate({ 'entries' => dm_list, 'nextPage' => nil })
             end
end
Thread.new { server.start }
sleep 0.2
ENVV = { 'SIGMA_BASE_URL' => "http://127.0.0.1:#{server.config[:Port]}",
         'SIGMA_ALLOW_INSECURE_BASE_URL' => '1',
         'SIGMA_CLIENT_ID' => nil, 'SIGMA_API_TOKEN' => 'offline-test' }.freeze

def run_picker(dir, sig, tag)
  sp = File.join(dir, "#{tag}-sig.json")
  op = File.join(dir, "#{tag}-out.json")
  File.write(sp, JSON.pretty_generate(sig))
  _o, err, st = Open3.capture3(ENVV, 'ruby', PICKER, '--workbook-signature', sp,
                               '--out', op, '--auto-pick', '--refresh')
  [JSON.parse(File.read(op)), err, st]
end

begin
  Dir.mktmpdir do |dir|
    # The live shape: the signature knows SCHEMA.TABLE only.
    res, _err, st = run_picker(dir, { 'tableau_workbook' => 'Pipeline Fact',
                                      'warehouse_tables' => ['SALES.PIPELINE_FACT'],
                                      'referenced_columns' => COLS }, 'short')
    cands = (res['candidates'] || []).each_with_object({}) { |c, h| h[c['dm_id']] = c }

    ok('a schema-qualified signature MATCHES a db-qualified DM (table_match 1.0)') do
      cands['dm-exact'] && cands['dm-exact']['table_match'].to_f >= 1.0
    end
    ok('missing_tables is empty for that DM (not "MISSING" after a suffix match)') do
      cands['dm-exact'] && (cands['dm-exact']['missing_tables'] || []).empty?
    end
    ok('it is a full column-superset, so the score clears the auto-pick bar') do
      cands['dm-exact'] && cands['dm-exact']['column_match'].to_f >= 1.0 && res['score'].to_f >= 0.8
    end
    ok('reuse is AUTO-PICKED instead of refused (exit 0)') do
      res['auto_picked'] == true && !res['recommended_dm_id'].nil? && st.exitstatus.zero?
    end
    ok('a same-table DM under a DIFFERENT SCHEMA does NOT count as covering') do
      c = cands['dm-other-schm']
      c.nil? || (c['table_match'].to_f < 1.0 && !(c['missing_tables'] || []).empty?)
    end
    ok('a same-schema.table DM under a different DATABASE still covers (db unknowable)') do
      c = cands['dm-other-db']
      c && c['table_match'].to_f >= 1.0
    end

    # A fully-qualified signature must keep matching exactly as before (no regression).
    res2, _e2, st2 = run_picker(dir, { 'tableau_workbook' => 'Pipeline Fact',
                                       'warehouse_tables' => ['ACME.SALES.PIPELINE_FACT'],
                                       'referenced_columns' => COLS }, 'full')
    ok('a fully-qualified signature still matches (no regression for 3-part names)') do
      c = (res2['candidates'] || []).find { |x| x['dm_id'] == 'dm-exact' }
      c && c['table_match'].to_f >= 1.0 && st2.exitstatus.zero?
    end
    ok('and the OTHER-DB DM is correctly excluded once the signature names the db') do
      c = (res2['candidates'] || []).find { |x| x['dm_id'] == 'dm-other-db' }
      c.nil? || c['table_match'].to_f < 1.0
    end
  end
ensure
  server.shutdown
end

puts($fail.zero? ? "\nALL PASS — warehouse-table matching is arity-aware, so an unresolved database no longer blocks reuse" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
