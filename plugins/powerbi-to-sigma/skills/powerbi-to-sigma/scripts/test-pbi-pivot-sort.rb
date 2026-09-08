#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-pivot-sort.rb — regression test for lib/pbi_pivot_sort.rb.
# Offline: no API, no creds. Run: ruby scripts/test-pbi-pivot-sort.rb
#
# Pins the "Region table not sorted like the PBI report" fix (2026-07-15):
#   - a pivot-table row sort IS spec-expressible (rowsBy[0].sort) — the builder used
#     to DROP it with "not spec-expressible in Sigma, set it in the UI";
#   - Power BI sorts a blank/null dim member FIRST while Sigma sorts nulls LAST, so
#     an ascending sort BY THE DIM coalesces nulls -> "(Blank)" for blank-first parity.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'pbi_pivot_sort'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

DIM = 'el-c0'  # row dimension column id
MEA = 'el-c1'  # a measure column id
def cols_fixture
  [{ 'id' => DIM, 'formula' => '[V/Region]', 'name' => 'Region' },
   { 'id' => MEA, 'formula' => 'Sum([V/Net Revenue])', 'name' => 'Net Revenue $' }]
end

# 1. Default first-column-ascending (by the dim): sort applied + blank-first coalesce.
rb = [{ 'columnId' => DIM }]; cols = cols_fixture
res = PbiPivotSort.apply!(rows_by: rb, cols: cols, cid: DIM, dir: 'ascending')
ok('returns true when applied',            res == true)
ok('rowsBy[0].sort is set by+direction',   rb[0]['sort'] == { 'by' => DIM, 'direction' => 'ascending' })
ok('dim col coalesced -> (Blank) first',   cols[0]['formula'] == 'Coalesce([V/Region], "(Blank)")')
ok('measure col NOT coalesced',            cols[1]['formula'] == 'Sum([V/Net Revenue])')

# 2. Sort by a MEASURE ascending: sort applied, but the dim must NOT be coalesced
#    (a measure sort orders the blank by its value, not first).
rb = [{ 'columnId' => DIM }]; cols = cols_fixture
PbiPivotSort.apply!(rows_by: rb, cols: cols, cid: MEA, dir: 'ascending')
ok('measure sort sets rowsBy sort',        rb[0]['sort'] == { 'by' => MEA, 'direction' => 'ascending' })
ok('measure sort does NOT coalesce dim',   cols[0]['formula'] == '[V/Region]')

# 3. DESCENDING sort by the dim: no coalesce (blank-first is an ascending concern).
rb = [{ 'columnId' => DIM }]; cols = cols_fixture
PbiPivotSort.apply!(rows_by: rb, cols: cols, cid: DIM, dir: 'descending')
ok('descending dim sort does NOT coalesce', cols[0]['formula'] == '[V/Region]')

# 4. Idempotent: an already-coalesced dim is not double-wrapped.
rb = [{ 'columnId' => DIM }]
cols = [{ 'id' => DIM, 'formula' => 'Coalesce([V/Region], "(Blank)")' }]
PbiPivotSort.apply!(rows_by: rb, cols: cols, cid: DIM, dir: 'ascending')
ok('no double-coalesce',                   cols[0]['formula'] == 'Coalesce([V/Region], "(Blank)")')

# 5. Guards: empty rowsBy / nil cid -> false, no mutation, no crash.
ok('empty rowsBy -> false',                PbiPivotSort.apply!(rows_by: [], cols: cols_fixture, cid: DIM, dir: 'ascending') == false)
ok('nil cid -> false',                     PbiPivotSort.apply!(rows_by: [{ 'columnId' => DIM }], cols: cols_fixture, cid: nil, dir: 'ascending') == false)

puts($fail.zero? ? "\nall pbi-pivot-sort tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
