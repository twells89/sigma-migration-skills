#!/usr/bin/env ruby
# Cross-path consistency + fail-closed guard for the Ruby formula translator
# (bead beads-sigma-tt3z.4). The TS path (formulas.ts::tableauFormulaToSigma) and
# this Ruby path (build-charts-from-signals.rb) had drifted:
#   - TS: fail-OPEN until B1 — unmapped fns passed through verbatim (silent break).
#         Fixed by the B1 catch-all (warns).
#   - Ruby: fail-CLOSED — a residue validator returns nil on any unmapped
#         construct and the caller warns loudly. So the dangerous silent
#         passthrough never existed here. This test LOCKS that contract.
# It also locks the WEEK → DatePart("week", …) fix (Sigma has no Week(), bead
# tt3z.2) now mirrored on the Ruby path, plus the sibling date-part extracts.
#
# Usage:  ruby scripts/test-row-level-date-translation.rb
DIR = __dir__
src = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
o = Object.new
# map_column needs the full mmap infra; nil is fine here — refs fall back to the
# raw caption inside [Master/…], which is all the residue validator inspects.
o.define_singleton_method(:map_column) { |_cap, _mmap| nil }
comments = src.match(/^def strip_tableau_comments\b.*?\n^end$/m)
abort 'test bug: could not extract strip_tableau_comments' unless comments
o.instance_eval(comments[0])
defsrc = src.match(/^def translate_row_level_calc\b.*?\n^end$/m)
abort 'test bug: could not extract translate_row_level_calc' unless defsrc
o.instance_eval(defsrc[0])

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'WEEK / date-part extracts (consistency with formulas.ts)'
week = o.translate_row_level_calc('WEEK([Order Date])', {}, {})
check(week&.include?('DatePart("week"'), "WEEK([Order Date]) → DatePart(\"week\", …)  (got #{week.inspect})", fails)
check(week && !week.match?(/\bWEEK\s*\(/i), '  no residual WEEK( passthrough', fails)

{ 'YEAR' => 'Year', 'MONTH' => 'Month', 'QUARTER' => 'Quarter' }.each do |tab, sig|
  out = o.translate_row_level_calc("#{tab}([Order Date])", {}, {})
  check(out&.include?("#{sig}("), "#{tab}([Order Date]) → #{sig}(…)  (got #{out.inspect})", fails)
end

puts 'fail-closed guarantee (never emit an unmapped Tableau fn verbatim)'
%w[FINDNTH([Path]) CHAR([Code]) MAKEDATETIME([D])].each do |f|
  out = o.translate_row_level_calc(f, {}, {})
  check(out.nil?, "#{f} → nil (rejected, caller warns) — got #{out.inspect}", fails)
end

# a fully-mapped row-level calc still translates (no over-rejection)
ok = o.translate_row_level_calc('DATEDIFF(\'day\', [Start], [End])', {}, {})
check(ok&.include?('DateDiff("day"'), "DATEDIFF still translates (got #{ok.inspect})", fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILED")
exit(fails.empty? ? 0 : 1)
