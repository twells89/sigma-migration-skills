#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the run-scoped completion sentinel (2026-07-09) and the
# PR-14 verdict model + report cross-check.
#
# "Done" must be a fact on disk, not a narration. verify-complete.rb reports
# DONE only when phase6-success.json is present AND no parity-pending.json
# remains — the two markers PASS 1 (exit 12) and assert-phase6-ran.rb (exit 0)
# maintain. This drives verify-complete.rb across the four states, then the
# PR-14 additions: the degradation ledger is re-derived offline, the verdict
# (GREEN/YELLOW/PARTIAL) is printed with the ledger inline, and a report whose
# claims contradict the derivation fails with exit 6 (the anti-"GREEN,
# 0 waivers" mechanism). Offline.
#
# Usage: ruby scripts/test-verify-complete.rb

require 'json'
require 'tmpdir'

DIR = __dir__
VC  = File.join(DIR, 'verify-complete.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

def run_vc(vc, wd, wb: nil)
  cmd = ['ruby', vc, '--workdir', wd]
  cmd += ['--workbook-id', wb] if wb
  out = IO.popen(cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
end

def write_source_accounting(wd, status: 'migrated', verdict: 'GREEN', result_status: nil)
  object = {
    'type' => 'dashboard', 'id' => 'dashboard:Sales', 'name' => 'Sales',
    'status' => status, 'evidence' => [{ 'artifact' => 'wb-readback.json', 'detail' => 'fixture' }]
  }
  counts = %w[migrated approximated needs-review skipped not-applicable]
           .to_h { |terminal| [terminal, terminal == status ? 1 : 0] }
  summary = { 'total' => 1, 'accounted' => 1, 'complete' => true, 'counts' => counts }
  File.write(File.join(wd, 'source-object-census.json'),
             JSON.generate('summary' => summary, 'objects' => [object]))
  result_object = object.reject { |key, _| key == 'evidence' }.merge('status' => result_status || status)
  File.write(File.join(wd, 'migration-result.json'),
             JSON.generate('verdict' => verdict, 'summary' => summary,
                           'source_objects' => [result_object]))
end

Dir.mktmpdir do |wd|
  # State 1 — PASS 1 only (pending present) => exit 3, NOT DONE
  File.write(File.join(wd, 'parity-pending.json'),
             JSON.generate('workbookId' => 'wb-1', 'stage' => 'pass1'))
  code, out = run_vc(VC, wd)
  check(code == 3, "PASS-1 pending => exit 3 (got #{code})", fails)
  check(out.include?('NOT DONE') && out.downcase.include?('pass 1'), 'pending message names PASS 1', fails)

  # State 2 — nothing (no markers) => exit 2, NOT DONE (gate never ran)
  File.delete(File.join(wd, 'parity-pending.json'))
  code, = run_vc(VC, wd)
  check(code == 2, "no markers => exit 2 (got #{code})", fails)

  # State 3 — success present, no pending => exit 0, DONE
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate('workbookId' => 'wb-1', 'gates' => 'all-pass',
                           'generatedAt' => '2026-07-09T00:00:00Z'))
  write_source_accounting(wd)
  code, out = run_vc(VC, wd)
  check(code == 0, "success + no pending => exit 0 (got #{code})", fails)
  check(out.include?('DONE') && out.include?('wb-1'), 'done message names the workbook', fails)

  # State 3b — --workbook-id match still passes
  code, = run_vc(VC, wd, wb: 'wb-1')
  check(code == 0, "success + matching --workbook-id => exit 0 (got #{code})", fails)

  # State 4 — success is for a DIFFERENT workbook than asked => exit 4
  code, = run_vc(VC, wd, wb: 'wb-OTHER')
  check(code == 4, "success but workbook mismatch => exit 4 (got #{code})", fails)

  # State 5 — a fresh PASS 1 after a success must FLIP back to NOT DONE
  # (exit-12 writes pending AND deletes the stale success marker; simulate both).
  File.write(File.join(wd, 'parity-pending.json'), JSON.generate('workbookId' => 'wb-1', 'stage' => 'pass1'))
  File.delete(File.join(wd, 'phase6-success.json'))
  code, = run_vc(VC, wd)
  check(code == 3, "re-run PASS 1 flips DONE back to NOT DONE (got #{code})", fails)
end

# ---------------------------------------------------------------------------
# PR-14 — verdict surfacing + report cross-check (exit 6).
# ---------------------------------------------------------------------------

def success_marker(wd, extra = {})
  File.write(File.join(wd, 'phase6-success.json'),
             JSON.generate({ 'workbookId' => 'wb-1', 'gates' => 'all-pass',
                             'generatedAt' => '2026-07-19T00:00:00Z' }.merge(extra)))
  write_source_accounting(wd)
end

# Tableau-local reconstruction gate must remain load-bearing even though the
# shared assert-phase6 marker was already stamped.
Dir.mktmpdir do |wd|
  success_marker(wd)
  File.write(File.join(wd, 'neutral-controls-coverage.json'), JSON.generate('detail' => []))
  code, out = run_vc(VC, wd)
  check(code == 11 && out.include?('reconstruction-integrity.json is missing'),
        "reconstruction surface + missing local gate => exit 11 (got #{code})", fails)

  File.write(File.join(wd, 'reconstruction-integrity.json'), JSON.generate(
    'status' => 'FAIL',
    'unresolved_controls' => [
      { 'kind' => 'parameter', 'name' => 'Date Grain', 'status' => 'needs-wiring' }
    ],
    'renamed_chart_family_mismatches' => []
  ))
  code, out = run_vc(VC, wd)
  check(code == 11 && out.include?('parameter:Date Grain'),
        "failed reconstruction artifact blocks DONE by name (got #{code})", fails)

  File.write(File.join(wd, 'reconstruction-integrity.json'), JSON.generate(
    'status' => 'PASS',
    'unresolved_controls' => [],
    'renamed_chart_family_mismatches' => []
  ))
  code, = run_vc(VC, wd)
  check(code == 0, "passing reconstruction artifact restores DONE (got #{code})", fails)
end

# Clean workdir → DONE with VERDICT: GREEN and an explicitly-empty ledger.
Dir.mktmpdir do |wd|
  success_marker(wd, 'verdict' => 'GREEN')
  code, out = run_vc(VC, wd)
  check(code == 0, "clean workdir + GREEN claim => exit 0 (got #{code})", fails)
  check(out.include?('VERDICT: GREEN'), 'DONE line prints the GREEN verdict', fails)
  check(out.include?('ledger   : empty'), 'empty ledger is stated explicitly', fails)
end

# Legacy marker (no verdict/waivers keys) over a clean workdir stays DONE and
# gets the derived verdict printed — absent claims are never contradictions.
Dir.mktmpdir do |wd|
  success_marker(wd)
  code, out = run_vc(VC, wd)
  check(code == 0, "legacy marker without verdict key => exit 0 (got #{code})", fails)
  check(out.include?('VERDICT: GREEN'), 'legacy marker still gets the derived verdict printed', fails)
end

# Scope cut (coverage.json dropped tile) + consistent PARTIAL claims → DONE,
# verdict PARTIAL, ledger entry printed inline.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'coverage.json'), JSON.generate(
    'unresolved' => [{ 'visual' => 'Region Map', 'severity' => 'dropped', 'detail' => 'no basemap' }]))
  File.write(File.join(wd, 'parity-final.json'), JSON.generate(
    'status' => 'PASS', 'waivers' => [], 'waiver_count' => 0, 'verdict' => 'PARTIAL'))
  success_marker(wd, 'verdict' => 'PARTIAL', 'waivers' => [])
  code, out = run_vc(VC, wd)
  check(code == 0, "dropped tile + honest PARTIAL claims => exit 0 (got #{code})", fails)
  check(out.include?('VERDICT: PARTIAL'), 'verdict PARTIAL surfaces on the DONE line', fails)
  check(out.include?('[scope-cut]') && out.include?('Region Map'), 'the ledger entry prints inline, one line', fails)
  check(out.include?('SUBSET of the source'), 'PARTIAL names the scope-cut meaning', fails)
end

# THE LIE (field case): a report claiming GREEN + 0 waivers over a workdir
# whose off-ramp trail recorded a --skip-ref-check → exit 6, contradiction.
Dir.mktmpdir do |wd|
  File.open(File.join(wd, 'offramps.jsonl'), 'a') do |f|
    f.puts(JSON.generate('kind' => 'skip-flag-waived', 'reason' => 'refs pre-validated by hand',
                         'detail' => '--skip-ref-check'))
  end
  File.write(File.join(wd, 'parity-final.json'), JSON.generate(
    'status' => 'PASS', 'waivers' => [], 'waiver_count' => 0, 'verdict' => 'GREEN'))
  success_marker(wd, 'verdict' => 'GREEN', 'waivers' => [])
  code, out = run_vc(VC, wd)
  check(code == 6, "\"GREEN, 0 waivers\" over a recorded --skip-ref-check => exit 6 (got #{code})", fails)
  check(out.include?('REPORT CONTRADICTS LEDGER'), 'contradiction failure names itself', fails)
  check(out.include?('claims verdict GREEN') && out.include?('YELLOW'),
        'failure names the claimed vs derived verdict', fails)
  check(out.include?('0 waivers but the artifacts record'),
        'the zero-waiver claim is called out against the recorded escape', fails)
  check(out.include?('--skip-ref-check'), 'the ledger inline shows the hidden skip flag', fails)
end

# Census arithmetic: waiver_count must equal the census it counts.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'parity-final.json'), JSON.generate(
    'status' => 'PASS', 'waivers' => ['--skip-anchors-gate'], 'waiver_count' => 0))
  success_marker(wd)
  code, out = run_vc(VC, wd)
  check(code == 6, "waiver_count=0 over a 1-entry census => exit 6 (got #{code})", fails)
  check(out.include?('its own census lists 1'), 'census arithmetic contradiction is named', fails)
end

# Marker census drift: phase6-success waivers != parity-final waivers → exit 6.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'parity-final.json'), JSON.generate(
    'status' => 'PASS', 'waivers' => ['--skip-anchors-gate'], 'waiver_count' => 1))
  success_marker(wd, 'waivers' => [])
  code, out = run_vc(VC, wd)
  check(code == 6, "marker census drifted from parity-final census => exit 6 (got #{code})", fails)
end

# Tampered ledger: degradation-ledger.json edited to empty while the artifacts
# still derive an entry → exit 6.
Dir.mktmpdir do |wd|
  File.write(File.join(wd, 'coverage.json'), JSON.generate(
    'unresolved' => [{ 'visual' => 'Trend', 'severity' => 'dropped', 'detail' => 'x' }]))
  File.write(File.join(wd, 'degradation-ledger.json'), JSON.generate(
    'version' => 1, 'counts' => {}, 'entries' => []))
  success_marker(wd)
  code, out = run_vc(VC, wd)
  check(code == 6, "hand-emptied degradation-ledger.json => exit 6 (got #{code})", fails)
  check(out.include?('does not match a fresh derivation'), 'tampered ledger is named', fails)
end

# Source accounting is a separate completion contract (exit 7): a gate marker
# cannot vouch for an absent, RED, incomplete, or census-drifted migration report.
Dir.mktmpdir do |wd|
  success_marker(wd)
  File.delete(File.join(wd, 'migration-result.json'))
  code, out = run_vc(VC, wd)
  check(code == 7, "missing migration-result.json => distinct exit 7 (got #{code})", fails)
  check(out.include?('SOURCE ACCOUNTING INVALID') && out.include?('migration-result.json is missing'),
        'missing report failure names the source accounting contract', fails)
end

Dir.mktmpdir do |wd|
  success_marker(wd)
  write_source_accounting(wd, verdict: 'RED')
  code, out = run_vc(VC, wd)
  check(code == 7, "RED migration report => exit 7 (got #{code})", fails)
  check(out.include?('verdict is RED'), 'RED report verdict is named', fails)
end

Dir.mktmpdir do |wd|
  success_marker(wd)
  result = JSON.parse(File.read(File.join(wd, 'migration-result.json')))
  result['summary']['complete'] = false
  result['summary']['accounted'] = 0
  File.write(File.join(wd, 'migration-result.json'), JSON.generate(result))
  code, out = run_vc(VC, wd)
  check(code == 7, "incomplete source accounting => exit 7 (got #{code})", fails)
  check(out.include?('summary.complete is not true') && out.include?('accounted'),
        'incomplete report identifies completeness and arithmetic', fails)
end

Dir.mktmpdir do |wd|
  success_marker(wd)
  result = JSON.parse(File.read(File.join(wd, 'migration-result.json')))
  result['source_objects'][0]['status'] = 'approximated'
  result['summary']['counts']['migrated'] = 0
  result['summary']['counts']['approximated'] = 1
  File.write(File.join(wd, 'migration-result.json'), JSON.generate(result))
  code, out = run_vc(VC, wd)
  check(code == 7, "migration-result/census status drift => exit 7 (got #{code})", fails)
  check(out.include?('1 status drift'), 'status disagreement is counted', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
