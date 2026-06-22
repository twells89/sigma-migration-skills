#!/usr/bin/env ruby
# test-dax-gate.rb — regression test for the gap-scout gate over-firing fixed after
# PR #153 (the PowerBI "Employee Dashboard" demo stalled on measures the converter had
# already handled). Pure, no network. Run: ruby scripts/test-dax-gate.rb
require_relative 'lib/dax_gate'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# A DM model that REALIZES the time-intel measures as grouped elements (as the real
# converter does for TOTALYTD / SAMEPERIODLASTYEAR on this report).
DM = {
  'pages' => [{ 'elements' => [
    { 'name' => 'YTD Absence Hours' },
    { 'name' => 'PY Absence Hours' },
    { 'name' => 'EMPLOYEES', 'metrics' => [{ 'name' => 'Headcount' }] }
  ] }]
}

# The exact Employee Dashboard converter warnings (verbatim prefixes).
WARNINGS = [
  'ℹ "Full Name" → calculated column. Review: ...',
  'ℹ "Tenure Days" → calculated column. Review: ...',
  '⚠ "Total Absence Hours (CC)": uses DAX iterator (SUMX). Use groupings ...',
  '⚠ "Salary Pct of Dept": CALCULATE filter ALLEXCEPT(EMPLOYEES, EMPLOYEES[DEPARTMENT]) ...',
  '✅ "Dept Salary Rank" (DENSE_RANK) → SQL window helper "Dense Rank DEPARTMENT" ...',
  '✅ "Hires In Period": CALCULATE over INACTIVE relationship ... alternate join path ...',
  '⚠ "YTD Absence Hours": uses DAX time intelligence (TOTALYTD). Use Period over ...',
  '⚠ "PY Absence Hours": uses DAX time intelligence (SAMEPERIODLASTYEAR). Use Period ...',
  '⚠ "Absence Hours Per Head": references "[Headcount]" ... cross-table measure ... dropped',
  'ℹ "Severity Score" → calculated column. Review: ...',
  '⚠ "PY Incident Count": uses DAX time intelligence (SAMEPERIODLASTYEAR). Use Period ...',
  '✅ "Dept Incident Rank" (DENSE_RANK) → SQL window helper ...',
  'ℹ Calculated table "DimDate": DAX CALENDAR/ADDCOLUMNS → SQL date-spine.',
  'ℹ Inactive relationship SAFETY_INCIDENTS[DATE] → DimDate[Date] skipped.'
]

qs    = DaxGate.dax_questions(WARNINGS, DM)
ids   = qs.map { |q| q['id'] }
mnames = qs.map { |q| DaxGate.measure_of(q['detail']) }

# Regression: the demo used to flag 9 (all non-ℹ incl. ✅ + handled time-intel).
# After the fix exactly 4 genuinely-dropped measures remain.
ok 'exactly 4 decisions (was 9 pre-fix)',           qs.size == 4
ok '✅ successes excluded (DENSE_RANK/USERELATIONSHIP)',
   mnames.none? { |m| ['Dept Salary Rank', 'Hires In Period', 'Dept Incident Rank'].include?(m) }
ok 'ℹ informational excluded (calc cols, DimDate)',  mnames.none? { |m| ['Full Name', 'Tenure Days', 'Severity Score'].include?(m) }
ok '⚠ realized-in-DM excluded (YTD/PY Absence Hours)',
   mnames.none? { |m| ['YTD Absence Hours', 'PY Absence Hours'].include?(m) }
ok 'genuinely-dropped ⚠ kept (SUMX CC)',             mnames.include?('Total Absence Hours (CC)')
ok 'genuinely-dropped ⚠ kept (ALLEXCEPT)',           mnames.include?('Salary Pct of Dept')
ok 'genuinely-dropped ⚠ kept (cross-table)',         mnames.include?('Absence Hours Per Head')
ok 'unrealized time-intel kept (PY Incident Count)', mnames.include?('PY Incident Count')
ok 'all kept are dax_needs_restructure',             ids.all? { |i| i == 'dax_needs_restructure' }

# ⛔ (true no-equivalent) is always a decision, even with no DM.
ho = DaxGate.dax_questions(['⛔ "Hierarchy Path": PATHITEM has no Sigma equivalent'], {})
ok '⛔ no-equivalent surfaces as dax_no_equivalent',  ho.size == 1 && ho[0]['id'] == 'dax_no_equivalent'

# A handled measure must not be flagged just because an unrelated DM is empty.
ok 'empty DM → realized set empty (⚠ all kept)',
   DaxGate.dax_questions(['⚠ "X": something'], {}).size == 1

puts(($fail.zero? ? "\nPASS" : "\n#{$fail} FAILED"))
exit($fail.zero? ? 0 : 1)
