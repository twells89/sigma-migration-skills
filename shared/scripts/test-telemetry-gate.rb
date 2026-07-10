#!/usr/bin/env ruby
# test-telemetry-gate.rb — unit test for the telemetry consent gate
# (assert-telemetry-ran.rb) and the marker written by report-telemetry.py.
# Offline: the telemetry endpoint is never required — report-telemetry.py
# degrades gracefully and still writes the marker, which is all the gate checks.
# Canonical in shared/scripts (epic beads-sigma-p5y2). Run: ruby scripts/test-telemetry-gate.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)

GATE   = File.join(__dir__, 'assert-telemetry-ran.rb')
REPORT = File.join(__dir__, 'report-telemetry.py')
RUBY   = RbConfig.ruby

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

def gate(dir, *extra)
  system(RUBY, GATE, '--workdir', dir, *extra, out: File::NULL, err: File::NULL)
end

def report(dir, *extra)
  env = { 'SIGMA_CLIENT_ID' => 'testclient', 'SIGMA_BASE_URL' => 'https://api.au.aws.sigmacomputing.com' }
  system(env, *PyResolve.argv, REPORT, '--tool', 'tableau-to-sigma', '--workdir', dir, *extra,
         out: File::NULL, err: File::NULL)
end

Dir.mktmpdir do |d|
  # 1. fresh run, no marker → gate FAILS (exit 12)
  ok('missing marker fails the gate', gate(d) == false)

  # 2. user declines → marker written, no network, status=declined
  ok('--declined writes a marker', report(d, '--declined'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('declined marker status', rec['status'] == 'declined')

  # 3. gate now PASSES on the declined marker
  ok('declined marker satisfies the gate', gate(d) == true)
end

Dir.mktmpdir do |d|
  # 4. send path: status is "sent" when the POST lands, "skipped" when the endpoint
  #    is unreachable (offline CI). Both are honest (handoff FIX 3) and both satisfy
  #    the gate — telemetry must never block. NEVER "sent" on a failed delivery.
  ok('send writes a marker', report(d, '--duration', '120', '--mode', 'file'))
  rec = JSON.parse(File.read(File.join(d, 'telemetry-sent.json')))
  ok('send marker status sent|skipped', %w[sent skipped].include?(rec['status']))
  ok('send marker mode',    rec['mode'] == 'file')
  ok('send marker satisfies the gate', gate(d) == true)
end

Dir.mktmpdir do |d|
  # 5. escape hatch waives a missing marker
  ok('--skip-telemetry-gate waives', gate(d, '--skip-telemetry-gate', 'unattended CI') == true)

  # 6. corrupt/invalid status → gate FAILS
  File.write(File.join(d, 'telemetry-sent.json'), '{"status":"bogus"}')
  ok('invalid marker status fails', gate(d) == false)
end

puts $fail.zero? ? "\nall telemetry-gate tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
