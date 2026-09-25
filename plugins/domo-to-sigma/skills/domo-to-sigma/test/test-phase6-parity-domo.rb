#!/usr/bin/env ruby
# Contract tests for scripts/phase6-parity-domo.rb — the missing PARITY FINALIZER
# (bead beads-sigma-2tkm).
#
# Root cause this covers: domo was the ONLY converter of six with no
# phase6-parity-*.rb finalizer. migrate-domo.rb aimed verify-parity.rb's
# --score-out straight at parity-final.json, so the gate's contract file was
# overwritten with a tiles_*-shaped score document. assert-phase6-ran.rb gate 1
# reads charts_total/charts_pass/status, found none of them, computed
# charts_total = 0, and dropped into the anchors-oracle substitution branch —
# so a flawless 65/65 parity run exited 2. The two documents are distinct:
#
#   parity-score.json  <- verify-parity.rb --score-out   (tiles_*, per-tile scores)
#   parity-final.json  <- THIS finalizer                 (charts_*/status, gate contract)
#
# Every other converter already draws that line (tableau phase6-parity.rb:344-382
# is the reference implementation). This restores it for domo.
#
# The suite deliberately asserts BOTH directions against the REAL shared gate:
# a clean run must be ACCEPTED, and a planted divergence must be REJECTED. A
# finalizer that only ever emits status=PASS would satisfy the first half alone.
#
# Offline: no network, no creds.
#   ruby test/test-phase6-parity-domo.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'fileutils'

FINALIZER = File.expand_path('../scripts/phase6-parity-domo.rb', __dir__)
GATE      = File.expand_path('../scripts/assert-phase6-ran.rb', __dir__)

$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end
def truthy(v, m)
  if v then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n    got #{v.inspect}" end
end
# Nil-safe fetch: before the finalizer exists every group must still report its
# own failure rather than the first one aborting the suite.
def at(doc, *path) path.reduce(doc) { |d, k| d.is_a?(Hash) || d.is_a?(Array) ? d[k] : nil } end

# --- fixture helpers ---------------------------------------------------------

# One chartable element per tile name, plus the non-chartable furniture that
# build-parity-plan.rb's own `chartable?` predicate excludes. If this drifts out
# of sync with shared/scripts/build-parity-plan.rb the census denominator is
# wrong, so the drift is asserted directly (group E).
def wb_spec(tile_names, extras: true)
  els = tile_names.each_with_index.map do |n, i|
    { 'id' => "el-#{i}", 'kind' => 'kpi-chart', 'name' => n,
      'columns' => [{ 'id' => "c-#{i}", 'name' => 'v' }] }
  end
  if extras
    els += [
      { 'id' => 'ctl-1',  'kind' => 'control-list-values', 'name' => 'Region control',
        'columns' => [{ 'id' => 'cc', 'name' => 'v' }] },
      { 'id' => 'txt-1',  'kind' => 'text',      'name' => 'Header',  'columns' => [] },
      { 'id' => 'img-1',  'kind' => 'image',     'name' => 'Logo',    'columns' => [] },
      { 'id' => 'cont-1', 'kind' => 'container', 'name' => 'Wrapper', 'columns' => [] },
      # hidden data-page master: chartable kind + columns, but visibleAsSource=false
      { 'id' => 'master-1', 'kind' => 'table', 'name' => 'Master (SALESFORCE)',
        'visibleAsSource' => false, 'columns' => [{ 'id' => 'mc', 'name' => 'v' }] },
    ]
  end
  { 'name' => 'WB', 'schemaVersion' => 1, 'kind' => 'workbook', 'pages' => [{ 'elements' => els }] }
end

# A verify-parity plan whose tiles carry inline expected+actual, so the whole
# chain runs offline. `diverge` names tiles whose actual is wrong on purpose.
def plan_for(tile_names, diverge: [])
  charts = tile_names.map do |n|
    actual = diverge.include?(n) ? [['east', 999]] : [['east', 100]]
    { 'chart' => n, 'expected' => [['east', 100]], 'actual' => { 'rows' => actual } }
  end
  { 'charts' => charts }
end

def setup_wd(dir, tile_names, plan_tiles: nil, diverge: [], exclusions: nil, extras: true)
  plan_tiles ||= tile_names
  File.write(File.join(dir, 'workbook-spec.json'), JSON.pretty_generate(wb_spec(tile_names, extras: extras)))
  File.write(File.join(dir, 'parity-plan.json'),   JSON.pretty_generate(plan_for(plan_tiles, diverge: diverge)))
  File.write(File.join(dir, 'parity-plan-exclusions.json'), JSON.pretty_generate(exclusions)) if exclusions
  dir
end

def run_finalizer(dir, *extra)
  out, err, st = Open3.capture3('ruby', FINALIZER, '--workdir', dir,
                                '--plan', File.join(dir, 'parity-plan.json'),
                                '--workbook-id', 'wb-test', *extra)
  final_path = File.join(dir, 'parity-final.json')
  score_path = File.join(dir, 'parity-score.json')
  { stdout: out, stderr: err, exit: st.exitstatus,
    final: (File.exist?(final_path) ? JSON.parse(File.read(final_path)) : nil),
    score: (File.exist?(score_path) ? JSON.parse(File.read(score_path)) : nil) }
end

# Gate 1 verdict only. Gate 1 exits 2 on failure before any later gate runs; on
# success it prints "[OK] gate 1/7" and falls through to gates that this bare
# fixture workdir cannot satisfy — so the OK line, not the exit code, is the
# signal for the accept case.
def gate1(dir)
  out, err, st = Open3.capture3('ruby', GATE, '--workdir', dir, '--workbook-id', 'wb-test')
  combined = out + err
  { accepted: combined.include?('[OK] gate 1/7'),
    rejected: st.exitstatus == 2 && combined.include?('[FAIL] parity status='),
    exit: st.exitstatus, out: combined }
end

TILES5 = ['Deals Won', 'Pipeline', 'Win Rate', 'Avg Deal Size', 'Survey Completion Rate'].freeze

# --- A. the gate contract ----------------------------------------------------

puts '== A. a clean parity run writes the gate-shaped contract (charts_*, not tiles_*) =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  r = run_finalizer(dir)
  eq(r[:exit], 0, 'finalizer exits 0 on a clean run')
  truthy(r[:final], 'parity-final.json is written')
  eq(at(r[:final],'charts_total'), 5, 'charts_total is the tile count (the key the gate actually reads)')
  eq(at(r[:final],'charts_pass'),  5, 'charts_pass is populated')
  eq(at(r[:final],'charts_fail'),  0, 'charts_fail is populated')
  eq(at(r[:final],'status'), 'PASS', 'status=PASS on a clean run')
  truthy(r[:score], 'the tiles_* score document is preserved SEPARATELY as parity-score.json')
  eq(at(r[:score],'tiles_total'), 5, 'parity-score.json keeps the tiles_* schema')
  truthy(!(r[:final] || {}).key?('tiles_total'), 'parity-final.json is not just the score doc renamed')
end

puts '== A2. the REAL shared gate accepts that contract (this is what 2tkm broke) =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  run_finalizer(dir)
  g = gate1(dir)
  truthy(g[:accepted], "assert-phase6-ran.rb gate 1 ACCEPTS a clean 5/5 run (got exit #{g[:exit]})")
end

puts '== A3. characterisation: the raw score doc alone is NOT gate-readable =='
# CHARACTERISATION, not a regression guard for this fix. It documents the shared
# gate's behaviour on the pre-fix artifact (a tiles_*-shaped parity-final.json)
# and never invokes the finalizer, so reverting the production change would NOT
# flip it. The actual revert-detecting coverage is groups A/A2/B, which shell out
# to phase6-parity-domo.rb and fail outright when it is absent.
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  VP = File.expand_path('../scripts/verify-parity.rb', __dir__)
  Open3.capture3('ruby', VP, '--plan', File.join(dir, 'parity-plan.json'),
                 '--score-out', File.join(dir, 'parity-final.json'))
  g = gate1(dir)
  truthy(!g[:accepted], 'a tiles_*-shaped parity-final.json is NOT accepted by gate 1 (the 2tkm bug)')
end

# --- B. fail-first: a planted divergence must be REJECTED -------------------

puts '== B. a planted divergence produces status=FAIL and is REJECTED by the gate =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5, diverge: ['Win Rate'])
  r = run_finalizer(dir)
  eq(at(r[:final],'status'), 'FAIL', 'status=FAIL when one tile diverges')
  eq(at(r[:final],'charts_pass'), 4, 'charts_pass counts only the passing tiles')
  eq(at(r[:final],'charts_fail'), 1, 'charts_fail counts the divergence')
  truthy(Array(at(r[:final],'fail_names')).include?('Win Rate'),
         'fail_names names the diverging tile so the gate can report it')
  g = gate1(dir)
  truthy(g[:rejected], "gate 1 REJECTS the diverging run with exit 2 (got exit #{g[:exit]})")
end

# --- C. the anti-inflation census -------------------------------------------

puts '== C. omitting chartable tiles from the plan is caught, not silently inflated =='
# The audit failure mode: a plan carrying only the 45 easy tiles scores
# "100% (45/45)" and reads identically to a genuine 65/65 pass.
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5, plan_tiles: TILES5.first(3))
  r = run_finalizer(dir)
  truthy(r[:exit] != 0, "finalizer FAILS when 2 of 5 chartable tiles are absent from the plan (got exit #{r[:exit]})")
  truthy((r[:stdout] + r[:stderr]).include?('Avg Deal Size'),
         'the unaccounted tiles are named, not just counted')
  truthy(!(r[:final] && at(r[:final],'status') == 'PASS'),
         'no PASS contract is emitted for a silently-narrowed plan')
end

puts '== C2. a RECORDED exclusion balances the census and is carried into the contract =='
Dir.mktmpdir do |dir|
  excl = { 'exclusions' => [
    { 'chart' => 'Avg Deal Size', 'reason' => 'top-N with no documented secondary sort — tie-break unstable' },
    { 'chart' => 'Survey Completion Rate', 'reason' => 'date window baked into the plotted value; true answer changes daily' },
  ] }
  setup_wd(dir, TILES5, plan_tiles: TILES5.first(3), exclusions: excl)
  r = run_finalizer(dir)
  eq(r[:exit], 0, 'finalizer exits 0 when every omission is recorded with a reason')
  eq(at(r[:final],'status'), 'PASS', 'status=PASS on the recorded-exclusion run')
  eq(at(r[:final],'charts_total'), 3, 'charts_total is the VERIFIED pool')
  census = at(r[:final],'parity_tile_census') || {}
  eq(census['chartable_total'], 5, 'census records the true denominator')
  eq(census['excluded_total'],  2, 'census records how many were excluded')
  eq(Array(census['unaccounted']).size, 0, 'census balances: plan + exclusions == chartable')
  truthy(Array(at(r[:final],'excluded_with_reason')).size == 2,
         'the exclusions ride along in the contract so the report cannot omit them')
end

puts '== C3. an exclusion without a reason cannot launder a dropped tile =='
Dir.mktmpdir do |dir|
  excl = { 'exclusions' => [{ 'chart' => 'Avg Deal Size' },
                            { 'chart' => 'Survey Completion Rate', 'reason' => '' }] }
  setup_wd(dir, TILES5, plan_tiles: TILES5.first(3), exclusions: excl)
  r = run_finalizer(dir)
  truthy(r[:exit] != 0, "a reasonless exclusion is rejected (got exit #{r[:exit]})")
  truthy((r[:stdout] + r[:stderr]).downcase.include?('reason'),
         'the failure explains that a reason is required')
end

# --- D. score fold-through so --min-parity-score works ----------------------

puts '== D. the per-tile value score is folded into the contract =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  r = run_finalizer(dir)
  truthy(!at(r[:final],'value_parity_score').nil?,
         'value_parity_score is present (gate 1 --min-parity-score fails closed without it)')
  truthy(Array(at(r[:final],'per_tile_scores')).size == 5,
         'per_tile_scores carries every tile so the gate can name the low scorers')
  eq(at(r[:final],'verified_against'), 'source',
     'verified_against=source — Domo values, not the warehouse honesty banner')
end

# --- E. census predicate must match build-parity-plan.rb --------------------

puts '== E. controls / text / images / containers / hidden masters are not chartable =='
Dir.mktmpdir do |dir|
  # 5 real tiles + 5 pieces of furniture; a census that counted furniture would
  # report chartable_total = 10 and fail a plan that is genuinely complete.
  setup_wd(dir, TILES5)
  r = run_finalizer(dir)
  eq(r[:exit], 0, 'a complete plan passes despite 5 non-chartable elements in the spec')
  eq(at(r[:final],'parity_tile_census','chartable_total'), 5,
     'census excludes controls, text, image, container and hidden masters')
end

puts '== E2. the census reads a document-wrapped readback too =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  flat = JSON.parse(File.read(File.join(dir, 'workbook-spec.json')))
  File.write(File.join(dir, 'workbook-spec.json'),
             JSON.pretty_generate({ 'document' => { 'pages' => flat['pages'] } }))
  r = run_finalizer(dir)
  eq(r[:exit], 0, 'a {document:{pages:[...]}} spec is understood (wrapper migration in flight)')
  eq(at(r[:final],'parity_tile_census','chartable_total'), 5, 'wrapped spec yields the same denominator')
end

# --- F. do not clobber a recorded visual verdict ----------------------------

puts '== F. a pre-existing visual verdict survives the finalizer =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(
    { 'visual_checked' => true, 'visual_verdict' => 'divergent',
      'screenshot_path' => 'sigma-render.png' }))
  r = run_finalizer(dir)
  eq(at(r[:final],'visual_verdict'), 'divergent', 'visual_verdict is preserved')
  eq(at(r[:final],'screenshot_path'), 'sigma-render.png', 'screenshot_path is preserved')
  eq(at(r[:final],'charts_total'), 5, 'and the gate contract is still written')
end

# --- G. duplicate tile names must not launder an unverified tile ------------
# Review finding 1 (critical). Ruby's Array#- is SET difference: it removes
# EVERY occurrence of a matching value, not one per match. With two chartable
# elements sharing a name, a plan verifying only ONE of them produced
# `unaccounted == []` and a PASS contract — precisely the silent inflation the
# census exists to stop. The census must compare MULTISETS.

puts '== G. two same-named tiles, only one verified -> caught (Array#- set-difference trap) =='
Dir.mktmpdir do |dir|
  setup_wd(dir, ['Region Total', 'Region Total', 'Pipeline'], plan_tiles: ['Region Total', 'Pipeline'])
  r = run_finalizer(dir)
  truthy(r[:exit] != 0,
         "one of two same-named chartable tiles is unverified -> must FAIL (got exit #{r[:exit]})")
  truthy((r[:stdout] + r[:stderr]).include?('Region Total'),
         'the under-verified duplicate name is reported')
  truthy(!(r[:final] && at(r[:final], 'status') == 'PASS'),
         'no PASS contract for a plan that covers only one of two same-named tiles')
end

puts '== G2. both same-named tiles verified -> census balances =='
Dir.mktmpdir do |dir|
  setup_wd(dir, ['Region Total', 'Region Total', 'Pipeline'],
           plan_tiles: ['Region Total', 'Region Total', 'Pipeline'])
  r = run_finalizer(dir)
  eq(r[:exit], 0, 'verifying both duplicates passes the census')
  eq(at(r[:final], 'status'), 'PASS', 'and yields a PASS contract')
  eq(at(r[:final], 'parity_tile_census', 'chartable_total'), 3, 'denominator counts both duplicates')
end

puts '== G3. one reasoned exclusion does not silence BOTH same-named tiles =='
Dir.mktmpdir do |dir|
  excl = { 'exclusions' => [{ 'chart' => 'Region Total', 'reason' => 'top-N tie-break unstable' }] }
  setup_wd(dir, ['Region Total', 'Region Total', 'Pipeline'],
           plan_tiles: ['Pipeline'], exclusions: excl)
  r = run_finalizer(dir)
  truthy(r[:exit] != 0,
         "1 plan + 1 exclusion cannot account for 2 same-named tiles (got exit #{r[:exit]})")
end

# --- H. a stale score document must not be read as this run's result --------
# Review finding 2 (critical). verify-parity.rb exits non-zero on a genuine
# divergence, so the finalizer deliberately ignores its exit code and treats a
# missing score file as the only crash signal. But presence-of-file is not
# freshness-of-file: on a reused workdir (the NORMAL path — migrate-domo.rb is
# idempotent and skips phases whose artifacts exist) a crashing verify-parity
# left the PREVIOUS run's score document on disk, which was then finalized into a
# fresh-timestamped PASS.

puts '== H. a crashing verify-parity cannot be masked by a previous run\'s score doc =='
Dir.mktmpdir do |dir|
  # 1. a clean run leaves a passing parity-score.json behind
  setup_wd(dir, ['Tile A'])
  first = run_finalizer(dir)
  eq(at(first[:final], 'status'), 'PASS', 'setup: the first clean run PASSes')
  truthy(File.exist?(File.join(dir, 'parity-score.json')), 'setup: a score document is on disk')

  # 2. re-verify the SAME workdir with a plan that makes verify-parity.rb abort
  #    (its documented missing-requested-column guard), writing nothing new
  crash_plan = { 'charts' => [
    { 'chart' => 'Tile A',
      'expected' => { 'columns' => %w[lines orders], 'rows' => [[1, 2]],
                      'requested_columns' => %w[lines totally_absent_measure] },
      'actual' => { 'rows' => [[1, 2]] } },
  ] }
  File.write(File.join(dir, 'parity-plan.json'), JSON.pretty_generate(crash_plan))
  r = run_finalizer(dir)
  truthy(r[:exit] != 0,
         "a crashed verify-parity must FAIL the finalizer, not inherit a stale score (got exit #{r[:exit]})")
  truthy(!(r[:final] && at(r[:final], 'status') == 'PASS'),
         'no PASS contract may be derived from a previous run\'s score document')
end

# --- I. the census is not optional ------------------------------------------
# Review finding 3. The census was skipped with a bare [WARN] when
# workbook-spec.json was absent, so the whole anti-inflation guarantee silently
# evaporated for any standalone invocation — and the script's own usage banner
# documents standalone use. An absent denominator must be a NAMED decision.

puts '== I. a missing workbook-spec is a hard failure, not a silent [WARN] =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  File.delete(File.join(dir, 'workbook-spec.json'))
  r = run_finalizer(dir)
  truthy(r[:exit] != 0,
         "no workbook-spec -> no denominator -> must FAIL rather than warn (got exit #{r[:exit]})")
  truthy(!(r[:final] && at(r[:final], 'status') == 'PASS'),
         'no PASS contract without a verified denominator')
end

puts '== I2. ...unless the operator names the reason, which is recorded in the contract =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  File.delete(File.join(dir, 'workbook-spec.json'))
  r = run_finalizer(dir, '--allow-missing-census', 'spec pruned by an external archive step')
  eq(r[:exit], 0, 'an explicitly named opt-out is accepted')
  eq(at(r[:final], 'census_waiver'), 'spec pruned by an external archive step',
     'the reason is recorded in the contract so the report cannot omit it')
end

# --- J. gate 5 must keep its honest SKIP -----------------------------------
# Review finding 4 (self-inflicted). The shared gate's gate 5 reads
# summary['tile_census'] and, when present, pulls tableau's ZONE-census keys
# (zones_total / charts_built / zones_unmatched / unmatched_zone_names). Emitting
# a differently-shaped doc under that exact key turned gate 5's honest
# "[SKIP] no tile_census" into a always-true "[OK] ... 0 zones, 0 unmatched".
# domo has no dashboard zone tree, so the honest answer is SKIP.

puts '== J. the parity census does not hijack gate 5\'s zone-census key =='
Dir.mktmpdir do |dir|
  setup_wd(dir, TILES5)
  r = run_finalizer(dir)
  truthy(!(r[:final] || {}).key?('tile_census'),
         'parity-final.json must NOT carry a tile_census key (gate 5 would misread it as zones)')
  truthy((r[:final] || {}).key?('parity_tile_census'),
         'the census is still recorded, under its own key')
  # Gate 5 itself cannot be exercised offline — it sits behind gate 3, which
  # live-GETs the workbook. So assert the CONTRACT statically instead: the gate
  # keys its zone census on 'tile_census', and our document must not answer to
  # that name. This is checked against the real gate source, not a copy of it.
  gate_src = File.read(GATE)
  truthy(gate_src.include?("summary['tile_census']"),
         "sanity: the shared gate really does key gate 5 on 'tile_census'")
  truthy(gate_src.include?("census['zones_total']"),
         'sanity: and reads tableau ZONE keys out of it, which domo has no equivalent for')
end

puts
if $failures.zero? then puts 'ALL PASS'; exit 0
else puts "#{$failures} FAILURE(S)"; exit 1 end
