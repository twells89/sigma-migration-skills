#!/usr/bin/env ruby
# Offline: ColumnPreflight's pure diff/suggestion logic (bead m655, Track "DM
# column pre-flight"). No network, no filesystem — see
# docs/superpowers/specs/2026-07-31-domo-dm-column-preflight-design.md.
#   ruby test/test-column-preflight.rb
require_relative '../scripts/lib/column_preflight'
include ColumnPreflight

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts '== normalize_name: uppercases and strips non-alphanumerics =='
eq(normalize_name('Order Date'), 'ORDERDATE', 'spaces stripped, uppercased')
eq(normalize_name('ORDER_DATE_KEY'), 'ORDERDATEKEY', 'underscores stripped')
eq(normalize_name(''), '', 'empty string stays empty')

puts '== diff_columns: a column present in the warehouse is never "missing" =='
schema = [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }, { 'name' => 'ORDER_DATE', 'type' => 'DATE' }]
warehouse = [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }, { 'name' => 'ORDER_DATE', 'type' => 'DATE' }]
diff = diff_columns(schema, warehouse, [], {})
eq(diff['missing'], [], 'both columns resolve — nothing missing')

puts '== diff_columns: a column absent from the warehouse is "missing" unless excluded/overridden =='
warehouse2 = [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }]
diff2 = diff_columns(schema, warehouse2, [], {})
eq(diff2['missing'], ['ORDER_DATE'], 'ORDER_DATE absent from warehouse -> missing')
eq(diff2['resolved_by_exclude'], [], 'nothing excluded')
eq(diff2['resolved_by_override'], [], 'nothing overridden')

puts '== diff_columns: excludeColumns removes a gap from "missing" -> "resolved_by_exclude" =='
diff3 = diff_columns(schema, warehouse2, ['ORDER_DATE'], {})
eq(diff3['missing'], [], 'excluded column is not "missing"')
eq(diff3['resolved_by_exclude'], ['ORDER_DATE'], 'excluded column is reported as resolved_by_exclude')

puts '== diff_columns: columnOverrides removes a gap from "missing" -> "resolved_by_override" =='
diff4 = diff_columns(schema, warehouse2, [], { 'ORDER_DATE' => { 'formula' => 'MakeDate(...)' } })
eq(diff4['missing'], [], 'overridden column is not "missing"')
eq(diff4['resolved_by_override'], ['ORDER_DATE'], 'overridden column is reported as resolved_by_override')

puts '== diff_columns: case-insensitive matching against warehouse column names =='
warehouse_lower = [{ 'name' => 'order_id', 'type' => 'LONG' }, { 'name' => 'order_date', 'type' => 'DATE' }]
diff5 = diff_columns(schema, warehouse_lower, [], {})
eq(diff5['missing'], [], 'lowercase warehouse names still match Domo\'s uppercase-ish names')

puts '== diff_columns: differently-styled Domo names for the same column both resolve against the warehouse (display_name-matched, not raw-matched) =='
schema_spaced = [{ 'name' => 'Order Date', 'type' => 'DATE' }]
warehouse_raw = [{ 'name' => 'ORDER_DATE', 'type' => 'DATE' }]
diff_spaced = diff_columns(schema_spaced, warehouse_raw, [], {})
eq(diff_spaced['missing'], [], '"Order Date" (spaced) matches warehouse "ORDER_DATE" via the same display_name transform build_element emits')
schema_snake = [{ 'name' => 'order_date', 'type' => 'DATE' }]
diff_snake = diff_columns(schema_snake, warehouse_raw, [], {})
eq(diff_snake['missing'], [], '"order_date" (snake_case) matches the same warehouse column too — both Domo naming styles resolve identically')

puts '== suggest_derivation: exactly one numeric candidate whose name starts with the missing column\'s normalized name -> suggestion =='
warehouse3 = [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }, { 'name' => 'ORDER_DATE_KEY', 'type' => 'INTEGER' }, { 'name' => 'CUSTOMER_ID', 'type' => 'LONG' }]
s = suggest_derivation('ORDER_DATE', 'DATE', warehouse3)
ok(s, 'a suggestion is returned')
eq(s['pattern'], 'yyyymmdd_integer_key', 'suggested pattern name')
eq(s['candidate_source_column'], 'ORDER_DATE_KEY', 'candidate is the one matching numeric column (RAW warehouse name)')
ok(s['suggested_formula'].include?('MakeDate') && s['suggested_formula'].include?('Order Date Key'),
   "suggested_formula references MakeDate and the candidate column's Sigma DISPLAY name, got #{s['suggested_formula'].inspect}")

puts '== suggest_derivation: suggested_formula brackets the candidate\'s Sigma-auto-assigned DISPLAY name, ' \
     'NEVER the raw all-caps warehouse identifier (bead beads-sigma-nxft) =='
# Sigma's server Title-Cases every underscore-separated word of a raw warehouse
# column UNCONDITIONALLY when auto-naming it (confirmed live, 2026-08-03:
# ORDER_DATE_KEY -> "Order Date Key") -- a formula referencing [ORDER_DATE_KEY]
# would not resolve against the real column, which is labeled [Order Date Key].
s_bug = suggest_derivation('ORDER_DATE', 'DATE', warehouse3)
ok(s_bug['suggested_formula'].include?('[Order Date Key]'),
   "suggested_formula must bracket-reference the Title-Cased display name, got #{s_bug['suggested_formula'].inspect}")
ok(!s_bug['suggested_formula'].include?('[ORDER_DATE_KEY]'),
   "suggested_formula must NOT bracket-reference the raw all-caps warehouse name, got #{s_bug['suggested_formula'].inspect}")

puts '== suggest_derivation: an already-mixed/Title-Case candidate name is left as-is by Title-Casing (idempotent-ish shape) =='
# fetch_warehouse_columns reports names exactly as the warehouse catalog returns
# them (preflight-columns.rb) -- for an unquoted Snowflake identifier that's
# always all-caps, but guard the mixed-case shape too in case a differently
# cased connector (or a quoted identifier) is ever the candidate.
warehouse_mixed = [
  { 'name' => 'Order_Date_Key', 'type' => 'INTEGER' },
  { 'name' => 'ORDER_ID', 'type' => 'LONG' },
]
s_mixed = suggest_derivation('ORDER_DATE', 'DATE', warehouse_mixed)
ok(s_mixed, 'a suggestion is returned for the mixed-case candidate')
eq(s_mixed['suggested_formula'].include?('[Order Date Key]'), true,
   "mixed-case warehouse name still normalizes to the Title-Cased display form, got #{s_mixed['suggested_formula'].inspect}")

puts '== suggest_derivation: non-date Domo type -> no suggestion, even with a perfect candidate =='
eq(suggest_derivation('ORDER_DATE', 'LONG', warehouse3), nil, 'only DATE/DATETIME Domo columns trigger this pattern')

puts '== suggest_derivation: zero candidates -> no suggestion =='
warehouse_none = [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }, { 'name' => 'CUSTOMER_ID', 'type' => 'LONG' }]
eq(suggest_derivation('ORDER_DATE', 'DATE', warehouse_none), nil, 'no numeric column with a matching name prefix -> nil, never guess')

puts '== suggest_derivation: two ambiguous candidates -> no suggestion (never guess) =='
warehouse_ambiguous = [
  { 'name' => 'ORDER_DATE_KEY', 'type' => 'INTEGER' },
  { 'name' => 'ORDER_DATE_ID', 'type' => 'LONG' },
]
eq(suggest_derivation('ORDER_DATE', 'DATE', warehouse_ambiguous), nil,
   'two plausible numeric candidates is ambiguous -> nil, never pick one arbitrarily')

puts '== suggest_derivation: a matching-name candidate that is NOT numeric-typed is not a candidate =='
warehouse_nonnumeric = [{ 'name' => 'ORDER_DATE_KEY', 'type' => 'VARCHAR' }]
eq(suggest_derivation('ORDER_DATE', 'DATE', warehouse_nonnumeric), nil,
   'a text-typed column with a matching name is not treated as a YYYYMMDD integer key')

puts '== build_report_entry: combines diff + suggestion into the full report shape =='
entry = build_report_entry('ORDER_FACT', schema, warehouse3, [], {})
eq(entry['table'], 'ORDER_FACT', 'table name carried through')
eq(entry['missing'], ['ORDER_DATE'], 'ORDER_DATE is missing (not in warehouse3)')
eq(entry['resolved_by_exclude'], [], 'nothing excluded')
eq(entry['resolved_by_override'], [], 'nothing overridden')
ok(entry['suggested_overrides']['ORDER_DATE'], 'a suggestion is present for the missing ORDER_DATE column')
eq(entry['suggested_overrides']['ORDER_DATE']['candidate_source_column'], 'ORDER_DATE_KEY',
   'the suggestion names the correct candidate column')

puts '== build_report_entry: a missing column with no derivable pattern gets no suggested_overrides entry =='
entry2 = build_report_entry('ORDER_FACT', schema, warehouse_none, [], {})
eq(entry2['missing'], ['ORDER_DATE'], 'still missing')
eq(entry2['suggested_overrides'], {}, 'no suggestion when there is no derivable candidate')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
