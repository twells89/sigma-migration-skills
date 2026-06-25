#!/usr/bin/env ruby
# test-coverage-gate.rb — unit test for CoverageGate (the migration-coverage
# surfacing added for customer feedback 2026-06-25). Converter-agnostic, pure,
# no network. Canonical in shared/scripts (bead beads-sigma-59mk).
# Run: ruby scripts/test-coverage-gate.rb
require 'json'
require_relative 'lib/coverage_gate'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# A realistic coverage.json: 12 source visuals, 5 approximations (exotic chart
# types — informational), 1 degraded field-drop (recoverable). Nothing dropped.
COVERAGE = {
  'version' => 1, 'source' => 'test',
  'summary' => { 'sourceVisuals' => 12, 'builtElements' => 19,
                 'dropped' => 0, 'degraded' => 1, 'approximated' => 5, 'recoverable' => 1 },
  'unresolved' => [
    { 'visual' => 'Profit Margin (gauge)', 'source_type' => 'gauge', 'sigma_kind' => 'kpi-chart',
      'severity' => 'approximated', 'recoverable' => false,
      'detail' => 'gauge has no native Sigma element kind — approximated as kpi-chart',
      'action' => 'Sigma has no native gauge; accept or pick a different chart.' },
    { 'visual' => 'Sub-Cat table', 'source_type' => 'table', 'sigma_kind' => 'table',
      'severity' => 'degraded', 'recoverable' => true,
      'detail' => "field(s) Sales Rank not reachable on master 'SUPERSTORE' — dropped",
      'action' => 'Add a single joined master element covering Sales Rank in the source map.' }
  ]
}

# headline leads with what CARRIED OVER: nothing dropped here (5 approx + 1 degraded
# all still build), so all 12 carried over.
hl = CoverageGate.headline(COVERAGE)
ok('headline reports 12/12 carried (approx/degraded still build)', hl.include?('12/12'))
ok('headline counts approximated', hl.include?('5 approximated'))
ok('headline reports 0 dropped', hl.include?('0 dropped'))

# only DROPPED visuals reduce the carried count; approximated does NOT.
multi = { 'summary' => { 'sourceVisuals' => 3, 'approximated' => 1, 'degraded' => 1, 'dropped' => 1 },
          'unresolved' => [
            { 'visual' => 'A', 'severity' => 'degraded', 'recoverable' => true },
            { 'visual' => 'A', 'severity' => 'approximated', 'recoverable' => false },
            { 'visual' => 'B', 'severity' => 'dropped', 'recoverable' => true }
          ] }
ok('distinct_visuals_with_gaps de-dupes (A counted once)',
   CoverageGate.distinct_visuals_with_gaps(multi) == 2)
ok('distinct_dropped_visuals counts only dropped (B)',
   CoverageGate.distinct_dropped_visuals(multi) == 1)
ok('headline subtracts only DROPPED visuals (2/3 carried)',
   CoverageGate.headline(multi).include?('2/3'))

# questions: ONLY recoverable items become decisions.
qs = CoverageGate.questions(COVERAGE)
ok('exactly 1 recoverable question', qs.size == 1)
ok('question is the degraded field-drop', qs.first['visual'] == 'Sub-Cat table')
ok('question id namespaced by severity', qs.first['id'] == 'coverage_degraded')
ok('recover option carries the action note',
   qs.first['options'].first.include?('joined master'))
ok('non-recoverable approximation is NOT asked',
   qs.none? { |q| q['visual'].include?('gauge') })

# source_type passthrough accepts either the neutral key or legacy pbi_type.
legacy = { 'unresolved' => [{ 'visual' => 'V', 'pbi_type' => 'map', 'severity' => 'dropped', 'recoverable' => true }] }
ok('questions() reads legacy pbi_type into source_type',
   CoverageGate.questions(legacy).first['source_type'] == 'map')

# report ordering: dropped < degraded < approximated; every recoverable item tagged.
lines = CoverageGate.report_lines(COVERAGE)
ok('report has a line per unresolved entry', lines.size == 2)
ok('degraded line marked [recoverable]', lines.any? { |l| l.include?('[recoverable]') && l.include?('Sub-Cat') })
ok('approximation line NOT marked recoverable', lines.none? { |l| l.include?('[recoverable]') && l.include?('gauge') })
deg_i = lines.index { |l| l.include?('DEGRADED') }
app_i = lines.index { |l| l.include?('APPROXIMATED') }
ok('DEGRADED sorts before APPROXIMATED', deg_i && app_i && deg_i < app_i)

# defensive load: missing file / garbage -> nil (caller no-ops, never crashes).
ok('load(nil) -> nil', CoverageGate.load(nil).nil?)
ok('load(missing) -> nil', CoverageGate.load('/no/such/coverage.json').nil?)
ok('questions(nil) -> []', CoverageGate.questions(nil) == [])

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
