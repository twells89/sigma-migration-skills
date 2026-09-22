#!/usr/bin/env ruby
# test-parity-score.rb — unit test for the value-parity SCORE (bead y9rd.2):
# verify-parity.rb emits a per-tile + overall value_parity_score and a
# --score-out JSON; assert-phase6-ran.rb gates on --min-parity-score. Offline:
# crafts plan fixtures, never the API. Run: ruby scripts/test-parity-score.rb
require 'json'
require 'tmpdir'
require 'rbconfig'

VP   = File.join(__dir__, 'verify-parity.rb')
GATE = File.join(__dir__, 'assert-phase6-ran.rb')
RUBY = RbConfig.ruby
$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# ── verify-parity --score-out: per-tile + overall score ─────────────────────
PLAN = { 'extract' => false, 'charts' => [
  { 'chart' => 'Exact',     'expected' => [%w[East]+[100], %w[West]+[200]],
    'actual' => { 'rows' => [%w[East]+[100], %w[West]+[200]] } },
  { 'chart' => 'HalfMatch', 'expected' => [%w[East]+[100], %w[West]+[200], %w[North]+[300], %w[South]+[400]],
    'actual' => { 'rows' => [%w[East]+[100], %w[West]+[200]] } },
  { 'chart' => 'Drift', 'extract' => true, 'expected' => [%w[East]+[100], %w[West]+[200]],
    'actual' => { 'rows' => [%w[East]+[110], %w[West]+[200]] } },
] }

Dir.mktmpdir do |d|
  plan = File.join(d, 'plan.json')
  score = File.join(d, 'parity-score.json')
  File.write(plan, JSON.generate(PLAN))
  # verify-parity exits 1 when any tile DIVERGEs (HalfMatch) — that's expected.
  system(RUBY, VP, '--plan', plan, '--score-out', score, out: File::NULL, err: File::NULL)
  ok('score-out written', File.exist?(score))
  doc = JSON.parse(File.read(score))
  tiles = doc['tiles'].each_with_object({}) { |t, h| h[t['chart']] = t }
  ok('exact tile scores 1.0',            tiles['Exact']['score'] == 1.0)
  ok('half-match tile scores 0.5 (2/4 Jaccard)', tiles['HalfMatch']['score'] == 0.5)
  ok('half-match flagged DIVERGE',       tiles['HalfMatch']['status'] == 'DIVERGE')
  ok('drift tile scores ~0.95 (9% drift, under tol → PASS)',
     (tiles['Drift']['score'] - 0.9545).abs < 0.01 && tiles['Drift']['status'] == 'PASS')
  ok('overall = mean per-tile (~0.818)', (doc['value_parity_score'] - 0.8182).abs < 0.001)
  ok('tiles_total/pass counts', doc['tiles_total'] == 3 && doc['tiles_pass'] == 2)

  # per-column (per-formula) scores — bead y9rd.14
  ok('per-column scores present (2 cols)', tiles['Exact']['columns'].is_a?(Array) && tiles['Exact']['columns'].size == 2)
  ok('exact: both columns score 1.0', tiles['Exact']['columns'].all? { |c| c['score'] == 1.0 })
  hm = tiles['HalfMatch']['columns']
  ok('half-match dim col (idx0, kind=dim) scores 0.5', hm[0]['score'] == 0.5 && hm[0]['kind'] == 'dim')
  ok('half-match measure col (idx1, kind=measure) scores 0.5 (key 0.5 × value 1.0)',
     hm[1]['score'] == 0.5 && hm[1]['kind'] == 'measure')
  dr = tiles['Drift']['columns']
  ok('drift measure col reflects the 9% drift (~0.95)', (dr[1]['score'] - 0.9545).abs < 0.01)
end

# Strict same-warehouse parity compares at the precision the Sigma element CSV
# actually exports. Hidden decimals from Tableau must not false-fail a chart
# formatted to whole dollars / one decimal, while a change that survives
# display rounding remains a real divergence.
Dir.mktmpdir do |d|
  plan = File.join(d, 'display-precision-plan.json')
  score = File.join(d, 'display-precision-score.json')
  File.write(plan, JSON.generate(
    'extract' => false,
    'charts' => [
      { 'chart' => 'Whole Dollars', 'expected' => [[170_641.9]],
        'actual' => { 'rows' => [[170_642.0]] } },
      { 'chart' => 'One Decimal', 'expected' => [[3.451699]],
        'actual' => { 'rows' => [[3.5]] } },
      { 'chart' => 'Material Difference', 'expected' => [[170_641.4]],
        'actual' => { 'rows' => [[170_642.0]] } }
    ]
  ))
  output = IO.popen([RUBY, VP, '--plan', plan, '--score-out', score],
                    err: %i[child out], &:read)
  doc = JSON.parse(File.read(score))
  tiles = doc['tiles'].each_with_object({}) { |tile, index| index[tile['chart']] = tile }
  ok('whole-dollar export compares at displayed precision',
     tiles['Whole Dollars']['status'] == 'PASS' && tiles['Whole Dollars']['score'] == 1.0)
  ok('one-decimal export compares at displayed precision',
     tiles['One Decimal']['status'] == 'PASS' && tiles['One Decimal']['score'] == 1.0)
  ok('display precision normalization is stated in verifier output',
     output.include?('compared at Sigma export display precision'))
  ok('material difference still diverges after display rounding',
     tiles['Material Difference']['status'] == 'DIVERGE')
end

# An embedded-only dashboard has no source-CSV chart scores. That is
# unavailable evidence, never a vacuous 100%.
Dir.mktmpdir do |d|
  plan = File.join(d, 'empty-plan.json')
  score = File.join(d, 'empty-score.json')
  File.write(plan, JSON.generate('extract' => false, 'charts' => [],
                                 'oracle_mode' => 'anchors-warehouse'))
  output = IO.popen([RUBY, VP, '--plan', plan, '--score-out', score],
                    err: %i[child out], &:read)
  empty_exit = $?.exitstatus
  doc = JSON.parse(File.read(score))
  ok('empty chart plan fails closed with exit 2', empty_exit == 2)
  ok('zero source-CSV tiles have a null parity score', doc['value_parity_score'].nil?)
  ok('zero-tile output routes to the oracle instead of printing 0/0 or 100%',
     output.include?('anchors + warehouse') &&
       !output.include?('0/0') && !output.include?('100.0%'))
end

# ── assert-phase6-ran.rb --min-parity-score gate ────────────────────────────
FINAL = { 'mode' => 'strict', 'status' => 'PASS', 'charts_total' => 2, 'charts_pass' => 2,
          'charts_fail' => 0, 'value_parity_score' => 0.70,
          'per_tile_scores' => [{ 'chart' => 'Weak', 'status' => 'PASS', 'score' => 0.4 }] }

Dir.mktmpdir do |d|
  File.write(File.join(d, 'parity-final.json'), JSON.generate(FINAL))
  below = system(RUBY, GATE, '--workdir', d, '--min-parity-score', '0.80', out: File::NULL, err: File::NULL)
  ok('gate FAILS when score below threshold', below == false)
  # gate 1 passes at 0.60; later gates may fail on missing files, so assert the
  # gate-1 score line is printed rather than the overall exit.
  out = IO.popen([RUBY, GATE, '--workdir', d, '--min-parity-score', '0.60'], err: %i[child out], &:read)
  ok('gate 1 OK line when score above threshold', out.include?('value-parity score=70.0% (>= 60.0% required)'))
  # off by default: no score gating, no score line
  out_off = IO.popen([RUBY, GATE, '--workdir', d], err: %i[child out], &:read)
  ok('score gate OFF by default (no false gating)', !out_off.include?('value-parity score='))
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
