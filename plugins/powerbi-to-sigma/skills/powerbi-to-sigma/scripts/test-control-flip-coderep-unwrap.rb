#!/usr/bin/env ruby
# frozen_string_literal: true
# Guards the Phase 6b runtime control-flip control-count GET against the
# workbook code-rep `document` wrapper (live since 2026-08).
#
# migrate-powerbi.rb GETs the live posted-workbook spec to count controls
# (ControlLint.controls_report) before deciding whether the runtime
# control-flip proof (probe-controls.rb) is even needed. That GET now nests
# `pages`/`schemaVersion` under a top-level `document` key — a bare
# `_spec['pages']`-shaped read (via ControlLint.controls_report) would always
# see 0 controls, so Phase 6b's runtime-flip gate silently never runs even on
# a workbook full of controls.
#
# migrate-powerbi.rb is the monolithic ~2500-line orchestrator (this block
# depends on prior CLI/discovery/build state — wb_id, opts, WORK, HERE — so
# it can't be isolated into a runnable unit offline) — source-level
# assertions, mirroring tableau-to-sigma's
# test-workbook-target-coderep-unwrap.rb approach to the same "can't isolate
# a god-script" problem, rather than a live/subprocess run.
#
# Usage: ruby scripts/test-control-flip-coderep-unwrap.rb

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

mig = File.read(File.join(__dir__, 'migrate-powerbi.rb'))

check(mig.include?("require_relative 'lib/code_rep'"),
      'migrate-powerbi.rb requires lib/code_rep', fails)
check(mig.match?(/has_creds = begin\s+!ENV\['SIGMA_BASE_URL'\].*Sigma\.auth_token/m) &&
      !mig.match?(/has_creds\s*=.*ENV\['SIGMA_API_TOKEN'\]/),
      'Phase 6b accepts browser/client auth resolved by sigma_rest, not only a static bearer',
      fails)

# Isolate the Phase 6b control-count block: from the `n_controls = nil` init
# through the ControlLint.controls_report call, a few lines later.
block_m = mig.match(/n_controls = nil\n.*?n_controls = ControlLint\.controls_report\(_spec\)\.length\n/m)
check(!block_m.nil?, 'the Phase 6b control-count block is present', fails)

if block_m
  block = block_m[0]
  get_idx    = block.index(/Sigma\.request\(:get,\s*"\/v2\/workbooks\/#\{wb_id\}\/spec"\)/)
  unwrap_idx = block.index(/Sigma::CodeRep\.metadata\(_spec\)\.merge\(Sigma::CodeRep\.document\(_spec\)\)/)
  report_idx = block.index(/ControlLint\.controls_report\(_spec\)\.length/)

  check(!get_idx.nil?, 'the live workbook spec GET is present', fails)
  check(!unwrap_idx.nil?, 'the `document` unwrap (metadata+document merge) is present', fails)
  check(!report_idx.nil?, 'the ControlLint.controls_report(_spec) call is present', fails)
  if get_idx && unwrap_idx && report_idx
    check(get_idx < unwrap_idx && unwrap_idx < report_idx,
          'unwrap runs AFTER the GET/parse and BEFORE ControlLint.controls_report (so it sees the flattened shape, not the raw nested GET)',
          fails)
  end
  check(block.match?(/_spec\s*=\s*Sigma::CodeRep\.metadata\(_spec\)\.merge/),
        'the unwrap reassigns `_spec` in place (so the downstream .length call sees the flattened value)',
        fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
