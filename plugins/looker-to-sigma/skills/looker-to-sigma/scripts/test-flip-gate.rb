#!/usr/bin/env ruby
# frozen_string_literal: true
# Tests for lib/flip_gate.rb — the pure decision logic behind gate 7b (the
# runtime control flip test in assert-phase6-ran.rb). Turns probe-controls.rb's
# exit code + parsed probe-results.json into :ok / :fail / :advisory / :error
# WITHOUT touching a live workbook, so the branch table is unit-verifiable.
#
# Offline, no network. Usage: ruby scripts/test-flip-gate.rb

require_relative 'lib/flip_gate'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A probe-results.json as parsed from disk (string keys).
PASS_ROW = { 'control' => 'ctl-region', 'result' => 'PASS', 'note' => '3 -> 1 rows' }
FAIL_ROW = { 'control' => 'ctl-tier', 'result' => 'FAIL', 'note' => 'export IDENTICAL — wired but inert' }
SKIP_ROW = { 'control' => 'ctl-date', 'result' => 'SKIP', 'note' => 'date range — pass --value' }

puts '-- rc=0 (probe reports every probeable control flipped) --'
dec, info = FlipGate.decide(0, [PASS_ROW])
ok(dec == :ok, "rc=0 + a PASS row → :ok (got #{dec})")
ok(info[:passes] == ['ctl-region'], 'ok: passes list carries the control id')

dec, info = FlipGate.decide(0, [PASS_ROW, SKIP_ROW])
ok(dec == :ok, 'rc=0 with a PASS and a SKIP → :ok (skips allowed)')
ok(info[:skips].first == ['ctl-date', 'date range — pass --value'], 'ok: skips carry [id, note]')

dec, = FlipGate.decide(0, [SKIP_ROW])
ok(dec == :advisory, 'rc=0 but ONLY skips (no PASS) → :advisory, never a silent green')

puts '-- rc=1 (probe reports a failure) --'
dec, info = FlipGate.decide(1, [PASS_ROW, FAIL_ROW])
ok(dec == :fail, "rc=1 + a FAIL row → :fail (got #{dec})")
ok(info[:fails].first == ['ctl-tier', 'export IDENTICAL — wired but inert'],
   'fail: fails carry [id, note] for the operator message')

dec, = FlipGate.decide(1, nil)
ok(dec == :error, 'rc=1 with NO results file (probe aborted / bad args) → :error, not a false :fail')
dec, = FlipGate.decide(1, [])
ok(dec == :error, 'rc=1 with an empty results array → :error (nothing actually failed to report)')

puts '-- rc=2 (nothing was auto-probeable) --'
dec, info = FlipGate.decide(2, [SKIP_ROW])
ok(dec == :advisory, 'rc=2 → :advisory (date/slider controls need --value; do not block)')
ok(info[:skips].length == 1, 'advisory: the un-probeable controls are reported for the marker')

puts '-- unexpected probe exit → fail-closed --'
dec, = FlipGate.decide(3, nil)
ok(dec == :error, 'rc=3 (probe crashed unexpectedly) → :error (fail-closed, never silent pass)')

puts '-- symbol-keyed rows (results built in-process, not parsed from JSON) --'
dec, info = FlipGate.decide(0, [{ control: 'c1', result: 'PASS', note: 'ok' }])
ok(dec == :ok, 'symbol keys resolve identically to string keys → :ok')
ok(info[:passes] == ['c1'], 'symbol-keyed control id extracted')

puts '-- defensive: garbage results shape --'
dec, = FlipGate.decide(0, 'not-an-array')
ok(dec == :advisory, 'non-array results at rc=0 → :advisory (no PASS rows found)')

puts
if $fails.empty?
  puts 'ALL PASS — flip_gate decision table'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
