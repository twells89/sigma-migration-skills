#!/usr/bin/env ruby
# Regression test for Tableau table-calc → Sigma window-function translation
# (translate_tableau_tc in build-charts-from-signals.rb). Deterministic +
# offline. Locks the EDNA-relevant table calcs:
#
#   LOOKUP(expr,-n) → Lag(expr,n)   LOOKUP(expr,n) → Lead(expr,n)   LOOKUP(x,0)→x
#   INDEX()         → RowNumber()
#   RANK(expr)      → Rank(expr,"desc")   (Tableau default direction = desc)
#   RANK_UNIQUE(expr) → RowNumber()       (was claimed in the header but NOT
#                       implemented — the EDNA top-N idiom fell through to
#                       "untranslatable"; this guards the fix)
#   SIZE() / LAST() → left untranslated + a hint (no validated Sigma equivalent)
#
# Usage:  ruby scripts/test-table-calc-translation.rb

DIR = __dir__
src = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
defsrc = src.match(/^def translate_tableau_tc\b.*?\n^end\n/m)
abort 'test bug: could not extract translate_tableau_tc' unless defsrc
o = Object.new
o.instance_eval(defsrc[0])

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# [formula, expected_output_or_nil, substring_expected_in_hint]
cases = [
  ['LOOKUP(SUM([x]), -1)',  'Lag(SUM([x]), 1)',        'Lag'],
  ['LOOKUP(SUM([x]), 2)',   'Lead(SUM([x]), 2)',       'Lead'],
  ['LOOKUP(SUM([x]), 0)',   'SUM([x])',                nil],
  ['INDEX()',               'RowNumber()',             'RowNumber'],
  ['RANK(SUM([x]))',        'Rank(SUM([x]), "desc")',  'Rank'],
  ['RANK_UNIQUE(SUM([x]))', 'RowNumber()',             'RANK_UNIQUE'],
  ['RANK_UNIQUE(SUM([x]), \'asc\')', 'RowNumber()',    'RANK_UNIQUE'],
]
puts 'translate_tableau_tc'
cases.each do |formula, want, hint_sub|
  out, hint = o.translate_tableau_tc(formula)
  check(out == want, "#{formula}  →  #{want}  (got #{out.inspect})", fails)
  check(hint_sub.nil? || hint.to_s.include?(hint_sub), "  hint mentions #{hint_sub.inspect}", fails) if hint_sub
end

# SIZE() / LAST() have no validated Sigma equivalent — must NOT silently emit a
# wrong translation; they stay untranslated (caller flags them).
['SIZE()', 'LAST() == 0'].each do |f|
  out, _ = o.translate_tableau_tc(f)
  check(out.nil? || out == f, "#{f} left untranslated (flagged, not faked)  (got #{out.inspect})", fails)
end

puts
if fails.empty?
  puts 'OK — table-calc translations all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |x| warn "  - #{x}" }
  exit 1
end
