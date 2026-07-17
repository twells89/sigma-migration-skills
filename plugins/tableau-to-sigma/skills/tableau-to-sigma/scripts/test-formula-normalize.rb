#!/usr/bin/env ruby
# Offline unit test for scripts/lib/formula_normalize.rb (fix-workstream G).
#
# Guards the contract migrate-tableau.rb wires against:
#   FormulaNormalize.normalize_spec!(spec_hash) -> [spec_hash, rewrites]
#   rewrites: [{from:, to:, path:}, ...]
# and the safety rules: pure CASE normalization of KNOWN Sigma function tokens
# only — never text inside [brackets] or quoted strings, never semantic
# rewrites, never a rewrite entry for an already-correct spelling.
#
# Usage:  ruby scripts/test-formula-normalize.rb

require 'json'
require_relative 'lib/formula_normalize'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

norm = ->(f) { FormulaNormalize.normalize_formula(f) }

puts 'Part A — mixed-case rewrites (the live-failure set)'
check(norm.call('round([Master/Sales], 2)') == 'Round([Master/Sales], 2)', 'round( -> Round(', fails)
check(norm.call('DATETRUNC("month", [Master/Order Date])') == 'DateTrunc("month", [Master/Order Date])',
      'DATETRUNC( -> DateTrunc(', fails)
check(norm.call('left([Master/Region], 3)') == 'Left([Master/Region], 3)', 'left( -> Left(', fails)
check(norm.call('RIGHT([Master/Region], 3)') == 'Right([Master/Region], 3)', 'RIGHT( -> Right(', fails)
check(norm.call('dateTrunc("day", [d])') == 'DateTrunc("day", [d])', 'dateTrunc( -> DateTrunc( (camel variant)', fails)
check(norm.call('sum(round([x], 0))') == 'Sum(Round([x], 0))', 'nested calls both normalized', fails)
check(norm.call('IF([a] > 1, 1, 0)') == 'If([a] > 1, 1, 0)', 'IF( -> If( (uppercase Tableau-case)', fails)

puts
puts 'Part B — immunity: brackets, strings, non-calls, unknown names'
check(norm.call('[Master/round trip]') == '[Master/round trip]', 'bracket ref text untouched', fails)
check(norm.call('[left field/right(col)]') == '[left field/right(col)]', 'function-looking text inside brackets untouched', fails)
check(norm.call('Concat("round(", [x])') == 'Concat("round(", [x])', 'double-quoted string untouched', fails)
check(norm.call("Concat('left(', [x])") == "Concat('left(', [x])", 'single-quoted string untouched', fails)
check(norm.call('round') == 'round', 'identifier not followed by ( untouched', fails)
check(norm.call('MyHelper([x])') == 'MyHelper([x])', 'unknown function name untouched (no semantic guessing)', fails)
check(norm.call('DATENAME("month", [d])') == 'DATENAME("month", [d])',
      'DATENAME untouched — semantic rewrite (MonthName/WeekdayName) is converter territory', fails)
check(norm.call('Round([x], 2)') == 'Round([x], 2)', 'already-correct spelling untouched', fails)
check(norm.call(nil).nil?, 'nil formula passes through', fails)

puts
puts 'Part C — known-list coverage (contract list + refs additions)'
contract = %w[If Switch Sum Avg Min Max Median Count CountIf CountDistinct Coalesce IsNull IsNotNull
              Lookup DateTrunc DateAdd DateDiff DatePart Year Month Day Hour Minute Second Week Quarter
              MonthName WeekdayName Weekday MakeDate Date Datetime DateParse Today Now Text Left Right
              Mid Len Find Contains StartsWith EndsWith Replace Trim Ltrim Rtrim Upper Lower SplitPart
              Concat Abs Round Ceiling Floor Power Sqrt Int Number Ln Log Exp Mod Sign Pi StdDev
              Variance VariancePop PercentileCont Rank RankDense RankPercentile RowNumber Lag Lead
              CumulativeSum CumulativeAvg CumulativeMax CumulativeMin CumulativeCount MovingAvg
              MovingSum MovingMin MovingMax MovingStdDev MovingCount PercentOfTotal GrandTotal Greatest
              Least RegexpExtract RegexpReplace RegexpMatch Corr BinFixed BinRange SplitToArray
              ArraySlice ArrayJoin CurrentUserEmail CurrentUserInTeam CurrentUserAttributeText
              First Last Zn]
unknown_to_map = contract.reject { |n| FormulaNormalize::CANONICAL_BY_DOWNCASE.key?(n.downcase) }
check(unknown_to_map.empty?, "every contract-named function is known case-insensitively (missing: #{unknown_to_map.inspect})", fails)
check(norm.call('WEEK([d])') == 'Week([d])', 'WEEK( -> Week( (refs addition beyond sigma_functions.rb)', fails)
check(norm.call('datetime([d])') == 'Datetime([d])', 'datetime( -> Datetime( (refs addition)', fails)
check(norm.call('LTRIM([s])') == 'Ltrim([s])', 'LTRIM( -> Ltrim( (converter spelling wins the collision)', fails)
check(norm.call('LTrim([s])') == 'LTrim([s])', 'LTrim( (whitelist spelling) treated as known — never rewritten', fails)
check(norm.call('Ltrim([s])') == 'Ltrim([s])', 'Ltrim( (converter spelling) treated as known — never rewritten', fails)

puts
puts 'Part D — normalize_spec!: in-place mutation + rewrites list'
spec = {
  'pages' => [
    { 'name' => 'Data', 'elements' => [
      { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
        'columns' => [
          { 'id' => 'c1', 'name' => 'Sales R', 'formula' => 'round([Fact/Sales], 2)' },
          { 'id' => 'c2', 'name' => 'Month',   'formula' => 'DATETRUNC("month", [Fact/Order Date])' },
          { 'id' => 'c3', 'name' => 'Clean',   'formula' => 'Sum([Fact/Sales])' }
        ] }
    ] },
    { 'name' => 'Overview', 'elements' => [
      { 'id' => 'kpi', 'kind' => 'kpi-chart',
        'columns' => [{ 'id' => 'k1', 'name' => 'Init', 'formula' => 'left([Master/Region], 1)' }],
        'metrics' => [{ 'id' => 'm1', 'name' => 'Tot', 'formula' => 'sum([Master/Sales R])' }] }
    ] }
  ]
}
returned, rewrites = FormulaNormalize.normalize_spec!(spec)
check(returned.equal?(spec), 'returns the same (mutated-in-place) spec hash', fails)
check(spec['pages'][0]['elements'][0]['columns'][0]['formula'] == 'Round([Fact/Sales], 2)',
      'spec formula rewritten in place', fails)
check(spec['pages'][1]['elements'][0]['metrics'][0]['formula'] == 'Sum([Master/Sales R])',
      'metrics formulas rewritten too', fails)
check(rewrites.size == 4, "exactly 4 rewrites recorded (got #{rewrites.size}: #{rewrites.inspect})", fails)
check(rewrites.all? { |r| r.keys.sort == %i[from path to] }, 'rewrite entries carry exactly from/to/path keys', fails)
r1 = rewrites.find { |r| r[:from] == 'round' }
check(r1 && r1[:to] == 'Round' && r1[:path] == 'pages[0].elements[0].columns[0].formula',
      "rewrite path pinpoints the formula (got #{r1.inspect})", fails)
check(rewrites.map { |r| r[:from] }.sort == %w[DATETRUNC left round sum].sort,
      'clean formulas produce NO rewrite entries', fails)
check(spec['pages'][0]['elements'][0]['columns'][2]['formula'] == 'Sum([Fact/Sales])',
      'already-clean formula byte-identical after normalize', fails)

# Tableau name-only leaks (STR/CurrentDate) auto-rewrite to the Sigma spelling.
tl = { 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'id' => 'c1', 'formula' => 'STR([Id]) & CurrentDate()' },
  { 'id' => 'c2', 'formula' => 'CURRENT_DATE()' },
  { 'id' => 'c3', 'formula' => 'Substring([Name], 1, 2)' } # contains "str" — must NOT change
] }] }] }
_, tlr = FormulaNormalize.normalize_spec!(tl)
tf = ->(i) { tl['pages'][0]['elements'][0]['columns'][i]['formula'] }
check(tf.call(0) == 'Text([Id]) & Today()', "STR→Text and CurrentDate→Today rewritten (got #{tf.call(0)})", fails)
check(tf.call(1) == 'Today()', 'CURRENT_DATE→Today rewritten', fails)
check(tf.call(2) == 'Substring([Name], 1, 2)', 'Substring (contains "str") left byte-identical', fails)
check(tlr.any? { |r| r[:from] == 'STR' && r[:to] == 'Text' }, 'STR→Text recorded as a rewrite', fails)

# idempotence: a second pass is a no-op
_, second = FormulaNormalize.normalize_spec!(Marshal.load(Marshal.dump(spec)))
check(second.empty?, 'normalize is idempotent (second pass rewrites nothing)', fails)

puts
if fails.empty?
  puts 'OK — formula_normalize contract + immunity rules all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
