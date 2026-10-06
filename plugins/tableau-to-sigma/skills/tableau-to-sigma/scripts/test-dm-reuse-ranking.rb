#!/usr/bin/env ruby
# test-dm-reuse-ranking.rb — find-or-pick-dm.rb must rank spec-fetch candidates by
# RELEVANCE (name affinity to the signature's tables), not by updatedAt recency.
#
# The bug this guards (live-caught on a large org: 500 data models): --limit was spent on the N
# most-recently-UPDATED DMs. Recency is uncorrelated with whether a DM covers the
# workbook's tables, so on a large org the picker scored ~5% of the DMs chosen by
# when they were last touched, never scored the DM sitting on the very same table,
# reported "no reusable DM found", and every migration posted another duplicate —
# reuse-first was silently inert.
#
# The fixture is built so RECENCY RANKING FAILS AND RELEVANCE RANKING PASSES: the
# one reusable DM is the OLDEST entry, parked behind 29 recently-touched decoys
# and outside a --limit=5 window.
#
# Loopback WEBrick over http:// (same harness as test-put-layout-prune.rb) —
# offline, creds-free. Run: ruby scripts/test-dm-reuse-ranking.rb
require 'webrick'
require 'json'
require 'tmpdir'
require 'open3'
require 'time'

$fail = 0
def ok(desc); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"; $fail += 1 unless r; end

PICKER = File.expand_path('find-or-pick-dm.rb', __dir__)
TARGET_TABLE = 'ACME.SALES.PIPELINE_FACT'
TARGET_COLS  = %w[SALE_DATE SALESPERSON LEAD_NAME SEGMENT REGION FORECASTED_MONTHLY_REVENUE
                  OPPORTUNITY_STAGE WEIGHTED_REVENUE].freeze
REUSABLE_ID  = 'dm-pipeline-fact'

# 22 decoys, all touched TODAY; then 7 name-affine LOOK-ALIKES that share the
# signature's name tokens but NOT its table; and last, the one genuinely reusable
# DM, touched a year ago so it sorts LAST under updatedAt-desc and cannot survive a
# recency window. affine_count (8) > --limit (5), so this also proves the fetch AND
# scoring budgets widen together for affine candidates.
def dm_list
  decoys = (1..22).map do |i|
    { 'dataModelId' => "dm-decoy-#{i}", 'name' => "Bench Complex Fixture #{i}",
      'updatedAt' => (Time.now.utc - i * 60).iso8601 }
  end
  lookalikes = (1..7).map do |i|
    { 'dataModelId' => "dm-lookalike-#{i}", 'name' => "Pipeline Fact Lookalike #{i}",
      'updatedAt' => (Time.now.utc - (100 + i) * 60).iso8601 }
  end
  decoys + lookalikes + [{ 'dataModelId' => REUSABLE_ID, 'name' => 'Pipeline Fact Model',
                           'updatedAt' => (Time.now.utc - 365 * 24 * 3600).iso8601 }]
end

def spec_for(id)
  if id == REUSABLE_ID
    { 'pages' => [{ 'elements' => [
      { 'source' => { 'kind' => 'warehouse-table', 'path' => %w[ACME SALES PIPELINE_FACT] },
        'columns' => TARGET_COLS.map { |c| { 'name' => c } } }
    ] }] }
  else
    { 'pages' => [{ 'elements' => [
      { 'source' => { 'kind' => 'warehouse-table', 'path' => %w[BENCH PUBLIC UNRELATED_FACT] },
        'columns' => [{ 'name' => 'SOME_ID' }, { 'name' => 'SOME_VALUE' }] }
    ] }] }
  end
end

server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0,
                                 Logger: WEBrick::Log.new(File::NULL),
                                 AccessLog: [])
server.mount_proc('/v2/dataModels') do |req, res|
  res['Content-Type'] = 'application/json'
  if (m = req.path.match(%r{/v2/dataModels/([^/]+)/spec}))
    res.body = JSON.generate(spec_for(m[1]))
  else
    res.body = JSON.generate({ 'entries' => dm_list, 'nextPage' => nil })
  end
end
Thread.new { server.start }
sleep 0.2
base = "http://127.0.0.1:#{server.config[:Port]}"
env = {
  'SIGMA_BASE_URL' => base,
  'SIGMA_ALLOW_INSECURE_BASE_URL' => '1',
  'SIGMA_CLIENT_ID' => nil,
  'SIGMA_API_TOKEN' => 'offline-test'
}

begin
  Dir.mktmpdir do |work|
    sig = { 'tableau_workbook' => 'Pipeline Fact',
            'warehouse_tables' => [TARGET_TABLE],
            'referenced_columns' => TARGET_COLS }
    sig_path = File.join(work, 'sig.json')
    out_path = File.join(work, 'dm-match.json')
    File.write(sig_path, JSON.pretty_generate(sig))

    # --limit 5: far too small to reach the reusable DM by recency (it is 30th of 30).
    _, err, st = Open3.capture3(env, 'ruby', PICKER, '--workbook-signature', sig_path,
                                '--out', out_path, '--limit', '5', '--auto-pick')
    res = JSON.parse(File.read(out_path))

    ok('the reusable DM is SCORED despite being the oldest and outside --limit') do
      (res['candidates'] || []).any? { |c| c['dm_id'] == REUSABLE_ID }
    end
    ok('it is RECOMMENDED (relevance ranking reached it; recency never would)') do
      res['recommended_dm_id'] == REUSABLE_ID
    end
    ok('its score reflects the real table+column match, not the name') do
      res['score'].to_f >= 0.6
    end
    ok('name-affine candidates are fetched AND scored past --limit (8 affine > limit 5)') do
      res.dig('candidate_pool', 'scored').to_i == 8
    end
    ok('candidate_pool records the org total and the ranking dimension') do
      res.dig('candidate_pool', 'total_in_org') == 30 &&
        res.dig('candidate_pool', 'ranked_by').to_s.include?('name-affinity')
    end
    ok('ranking_version is stamped so stale-ranking caches cannot be replayed') do
      res['ranking_version'].to_i >= 2
    end
    ok('stderr names the ranking dimension (operator-visible, not silent)') do
      err.include?('name-affinity')
    end
    ok('exit 0 on a recommendation') { st.exitstatus.zero? }

    # A signature with NO affine DM must still not claim the org has nothing:
    # the build-new verdict has to disclose that the pool was truncated.
    sig2 = { 'tableau_workbook' => 'Zzz Unrelated',
             'warehouse_tables' => ['OTHER.ELSEWHERE.ZZZ_NOTHING'],
             'referenced_columns' => %w[ALPHA BETA GAMMA] }
    sig2_path = File.join(work, 'sig2.json')
    out2_path = File.join(work, 'dm-match2.json')
    File.write(sig2_path, JSON.pretty_generate(sig2))
    _, err2, st2 = Open3.capture3(env, 'ruby', PICKER, '--workbook-signature', sig2_path,
                                  '--out', out2_path, '--limit', '5', '--auto-pick')
    res2 = JSON.parse(File.read(out2_path))

    ok('no match → exit 1 (caller builds new)') { st2.exitstatus == 1 }
    ok('NO SILENT CAPS: the build-new rationale discloses the scored/total pool') do
      res2['rationale'].to_s.match?(/scanned 5 of 30 DM\(s\) scored/)
    end
    ok('truncation is flagged in candidate_pool and on stderr') do
      res2.dig('candidate_pool', 'truncated') == true && err2.include?('were NOT scored')
    end
  end
ensure
  server.shutdown
end

puts($fail.zero? ? "\nALL PASS — DM-reuse candidates are relevance-ranked, widened past --limit, and truncation is disclosed" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
