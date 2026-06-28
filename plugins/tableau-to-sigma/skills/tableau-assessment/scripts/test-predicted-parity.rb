#!/usr/bin/env ruby
# Regression test for the pre-migration parity PREDICTION (y9rd.6): the
# occurrence-weighted coverage % + A-D band that aggregate-complexity.rb derives
# from the gap-scanner's per-feature status tiers. Exercises the pure
# `predicted_parity` helper directly (no .twb, no network).
#
# Usage:  ruby scripts/test-predicted-parity.rb
DIR = __dir__
SRC = File.read(File.join(DIR, 'aggregate-complexity.rb'))
# Pull the constant + the pure helper out of the script (which otherwise needs --out).
cw = SRC.match(/^COVERAGE_WEIGHTS = .*$/) or abort('could not extract COVERAGE_WEIGHTS')
eval(cw[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
m = SRC.match(/^def predicted_parity\b.*?\n^end$/m) or abort('could not extract predicted_parity')
eval(m[0]) # rubocop:disable Security/Eval

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# No complex features detected → a plain workbook predicts 100% / band A.
check(predicted_parity([]) == [100.0, 'A'], 'empty feature set → 100% band A', fails)

# All auto → 100% A.
pct, band = predicted_parity([{ 'status' => 'auto', 'count' => 5 }])
check(pct == 100.0 && band == 'A', "all auto → 100% A (got #{pct} #{band})", fails)

# All unhandled → 0% D.
pct, band = predicted_parity([{ 'status' => 'unhandled', 'count' => 3 }])
check(pct == 0.0 && band == 'D', "all unhandled → 0% D (got #{pct} #{band})", fails)

# Occurrence-weighting: 50 auto + 1 unhandled predicts FAR higher than 1 auto + 1
# unhandled (the whole point — feature COUNT matters, not just presence).
many, = predicted_parity([{ 'status' => 'auto', 'count' => 50 }, { 'status' => 'unhandled', 'count' => 1 }])
few,  = predicted_parity([{ 'status' => 'auto', 'count' => 1 },  { 'status' => 'unhandled', 'count' => 1 }])
check(many > few, "occurrence-weighted: 50auto+1unh (#{many}%) > 1auto+1unh (#{few}%)", fails)
check(many >= 90 && (90..100).cover?(many), "50auto+1unh lands band A (#{many}%)", fails)
check(few == 50.0, "1auto+1unh = exactly 50% (1.0+0.0)/2 (got #{few})", fails)

# Tier weights compose: auto=1, hint=.85, manual=.5, unhandled=0 — one each.
pct, = predicted_parity([{ 'status' => 'auto', 'count' => 1 }, { 'status' => 'hint', 'count' => 1 },
                         { 'status' => 'manual', 'count' => 1 }, { 'status' => 'unhandled', 'count' => 1 }])
check(pct == ((1.0 + 0.85 + 0.5 + 0.0) / 4 * 100).round(1), "mixed tiers weight correctly (got #{pct})", fails)

# Band boundaries: 75% = B (not C); 50% = C (not D).
check(predicted_parity([{ 'status' => 'manual', 'count' => 1 }, { 'status' => 'auto', 'count' => 1 }])[1] == 'B',
      'manual+auto = 75% → band B (>=75)', fails)
# nil count defaults to 1 occurrence.
pct, = predicted_parity([{ 'status' => 'auto' }, { 'status' => 'unhandled' }])
check(pct == 50.0, "nil count defaults to 1 occurrence (got #{pct})", fails)

puts
if fails.empty?
  puts 'ALL PASS — predicted-parity: occurrence-weighted tiers, band boundaries, empty/edge cases'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
