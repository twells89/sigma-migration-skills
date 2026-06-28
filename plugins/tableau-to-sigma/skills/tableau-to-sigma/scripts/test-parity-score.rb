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
  out = `#{RUBY} #{GATE} --workdir #{d} --min-parity-score 0.60 2>&1`
  ok('gate 1 OK line when score above threshold', out.include?('value-parity score=70.0% (>= 60.0% required)'))
  # off by default: no score gating, no score line
  out_off = `#{RUBY} #{GATE} --workdir #{d} 2>&1`
  ok('score gate OFF by default (no false gating)', !out_off.include?('value-parity score='))
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
