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

# Also load translate_window_calc (the classifier that returns the result hash)
# and its dependencies so the higher-level top-N / %-change idioms can be
# asserted end-to-end (beads t18q + pnxp).
w = Object.new
%w[SIGMA_AGG USER_AGG_FN WINDOW_SIGMA_FNS WINDOW_MANUAL_RE WINDOW_TC_RE].each do |c|
  m = src.match(/^#{c}\s*=\s*%w\[.*?\]\.freeze/m) ||
      src.match(/^#{c}\s*=\s*\{.*?\}\.freeze/m) ||
      src.match(/^#{c}\s*=.*$/)
  w.instance_eval(m[0]) if m
end
%w[translate_window_calc translate_tableau_tc translate_user_agg_formula
   map_column header_base].each do |fn|
  m = src.match(/^def #{fn}\b.*?\n^end$/m)
  w.instance_eval(m[0]) if m
end

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

# --- translate_window_calc: %-change reduction (bead t18q) ------------------
# The ZN()/ABS()-wrapped period-over-period %change must auto-reduce to an
# inline Sigma viz formula (Lag-based, with Coalesce + Abs glue), NOT stay
# manual ("did not reduce to translated aggregates + arithmetic glue").
puts
puts 'translate_window_calc — %-change (t18q)'
pct = w.translate_window_calc('(ZN(SUM([x])) - LOOKUP(SUM([x]),-1)) / ABS(LOOKUP(SUM([x]),-1))', {})
check(pct && pct['mode'] == 'inline', "%change reduces to mode=inline (got #{pct.inspect})", fails)
check(pct && pct['formula'].to_s.include?('Lag('),      '  formula contains Lag(', fails)
check(pct && pct['formula'].to_s.include?('Coalesce('), '  formula contains Coalesce( (ZN→Coalesce(_,0))', fails)
check(pct && pct['formula'].to_s.include?('Abs('),      '  formula contains Abs( (ABS→Abs)', fails)

# --- translate_window_calc: top-N must not silently drop the operand (pnxp) -
# RANK_UNIQUE(<expr>)<=N / RANK(<expr>)<=N: when <expr> is an untranslatable
# LOD it must STAY MANUAL (never an inline RowNumber()<=N with the operand
# gone); when <expr> is a clean aggregate it may become a sorted top-N that
# RECORDS the ranked measure.
puts
puts 'translate_window_calc — top-N operand safety (pnxp)'
lod = w.translate_window_calc('RANK_UNIQUE(sum({exclude [T]: sum([Net Revenue])}))<=25', {})
check(lod && lod['mode'] == 'manual',
      "top-N over LOD operand stays manual (got #{lod.inspect})", fails)
check(!(lod && lod['formula'].to_s.include?('RowNumber()')),
      '  does NOT emit a sort-dependent RowNumber()<=N with the operand dropped', fails)

clean = w.translate_window_calc('RANK_UNIQUE(SUM([Net Revenue]))<=25', {})
check(clean && clean['mode'] == 'inline',
      "top-N over a clean aggregate becomes a proper sorted top-N (got #{clean.inspect})", fails)
check(clean && clean['formula'].to_s =~ /RowNumber\(\)\s*<=\s*25/,
      '  formula is RowNumber() <= 25', fails)
check(clean && clean['ranked_measure'].to_s.include?('Sum([Master/Net Revenue])'),
      '  records the ranked measure (so the tile can be sorted by it)', fails)

if fails.empty?
  puts 'OK — table-calc translations all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |x| warn "  - #{x}" }
  exit 1
end
