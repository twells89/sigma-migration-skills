#!/usr/bin/env ruby
# Regression test: scan-workbook-gaps.rb calc classifications must match what
# build-charts-from-signals.rb actually translates.
#
# The gap scan feeds the assessment complexity/cost tiering (build-shortlist.rb:
# cost = 10*unhandled + 3*manual + 1*hint). Miscategorizing an AUTO-translated
# calc as `:manual` over-costs the workbook, mis-ranks the migration shortlist,
# and tells a customer they have hand-work they don't. Two drifts fixed here:
#   RANK_UNIQUE      → auto (build-charts: RANK_UNIQUE→RowNumber())
#   sample WINDOW_VAR→ auto (build-charts: WINDOW_VAR→MovingVariance)
# while the population forms (WINDOW_VARP/STDEVP) and RANK_MODIFIED stay manual.
#
# Deterministic/offline/creds-free: extracts INVENTORY + categorize from the
# real scanner and runs them, so it locks the actual classification table.
#
# Usage:  ruby scripts/test-calc-gap-classification.rb

SRC = File.join(__dir__, 'scan-workbook-gaps.rb')
src = File.read(SRC)
block = src[/INVENTORY = \[.*?\]\.freeze\s*\ndef categorize.*?\nend/m]
abort "could not extract INVENTORY/categorize from #{SRC}" unless block
eval(block) # rubocop:disable Security/Eval — trusted first-party source, test-only

fails = []
# The single status the scanner assigns to a formula snippet (expects exactly one
# INVENTORY row to match; asserts there's no ambiguous multi-status match).
def status_of(formula, fails)
  hits = categorize(formula).map { |r| r[:status] }.uniq
  if hits.length != 1
    fails << "#{formula.inspect} matched statuses #{hits.inspect} (expected exactly one)"
    return nil
  end
  hits.first
end

def check(formula, expected, fails)
  got = status_of(formula, fails)
  ok = got == expected
  fails << "#{formula.inspect} → #{got.inspect}, expected #{expected.inspect}" unless ok || got.nil?
  puts "  #{ok ? 'PASS' : 'FAIL'}  #{formula}  → #{got.inspect}"
end

# ── AUTO (translated by build-charts) ───────────────────────────────────────
check('RANK_UNIQUE(SUM([Sales]))',        :auto, fails)   # → RowNumber()
check('RANK_DENSE(SUM([Sales]))',         :auto, fails)
check('RANK_PERCENTILE(SUM([Sales]))',    :auto, fails)
check('WINDOW_VAR(SUM([Sales]), -2, 0)',  :auto, fails)   # sample → MovingVariance
check('WINDOW_STDEV(SUM([Sales]), -2, 0)',:auto, fails)   # sample → MovingStdDev
check('RUNNING_SUM(SUM([Sales]))',        :auto, fails)
check('LOOKUP(SUM([Sales]), -1)',         :auto, fails)

# ── MANUAL (no validated Sigma chart-formula mapping) ───────────────────────
check('RANK_MODIFIED(SUM([Sales]))',      :manual, fails)
check('WINDOW_VARP(SUM([Sales]), -2, 0)', :manual, fails) # population variant
check('WINDOW_STDEVP(SUM([Sales]), -2, 0)',:manual, fails)
check('WINDOW_MEDIAN(SUM([Sales]))',      :manual, fails)
check('WINDOW_PERCENTILE(SUM([Sales]), 0.9)', :manual, fails)
check('PREVIOUS_VALUE(0)',                :manual, fails)
check('SIZE()',                           :manual, fails)

puts
if fails.empty?
  puts 'ALL PASS — gap-scan calc classifications match builder coverage (no over-costing auto calcs as manual)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
