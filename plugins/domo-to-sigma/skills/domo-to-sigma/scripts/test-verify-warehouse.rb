#!/usr/bin/env ruby
# test-verify-warehouse.rb — unit test for raw-mode warehouse verification
# (verify-warehouse.rb). Offline: element CSVs come from the --fixture seam, never
# the export API. Canonical in shared/scripts (epic [bead]).
# Run: ruby scripts/test-verify-warehouse.rb
require 'json'
require 'tmpdir'
require 'rbconfig'

VW   = File.join(__dir__, 'verify-warehouse.rb')
RUBY = RbConfig.ruby

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

SPEC = {
  'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
  'elements' => [
    { 'id' => 'el-rev',   'columns' => [{ 'id' => 'c-m', 'name' => 'Month' }, { 'id' => 'c-r', 'name' => 'Net Revenue' }] },
    { 'id' => 'el-empty', 'columns' => [{ 'id' => 'c-x', 'name' => 'Region' }, { 'id' => 'c-y', 'name' => 'Sales' }] },
    { 'id' => 'el-piv',   'columns' => [{ 'id' => 'c-a', 'name' => 'A' }] },
    { 'id' => 'el-blank', 'columns' => [{ 'id' => 'c-b', 'name' => 'B' }] },
  ],
  'layout' => '<Page id="p1"><Element elementId="el-rev"/><Element elementId="el-empty"/>' \
              '<Element elementId="el-piv"/><Element elementId="el-blank"/></Page>'
}

def run(dir, charts, fixture)
  File.write(File.join(dir, 'wb-readback.json'), JSON.generate(SPEC))
  File.write(File.join(dir, 'parity-plan.json'), JSON.generate('charts' => charts))
  File.write(File.join(dir, 'fx.json'), JSON.generate(fixture))
  out = File.join(dir, 'parity-final.json')
  system(RUBY, VW, '--plan', File.join(dir, 'parity-plan.json'), '--workbook-id', 'WB',
         '--workbook-spec', File.join(dir, 'wb-readback.json'), '--out', out, '--fixture', File.join(dir, 'fx.json'),
         out: File::NULL, err: File::NULL)
  [$?.exitstatus, JSON.parse(File.read(out))]
end

# 1. all elements return data → PASS, verified_against=warehouse
Dir.mktmpdir do |d|
  st, s = run(d,
    [{ 'chart' => 'Rev', 'sigma_element_id' => 'el-rev', 'sigma_kind' => 'line-chart', 'sigma_columns' => %w[c-m c-r] }],
    { 'el-rev' => "Month,Net Revenue\n2025-01,42508.08\n2025-02,51200.10\n" })
  ok('all-data → exit 0', st == 0)
  ok('status PASS', s['status'] == 'PASS')
  ok('verified_against=warehouse', s['verified_against'] == 'warehouse')
end

# 2. element returns headers only (broken join / empty) → FAIL
Dir.mktmpdir do |d|
  st, s = run(d,
    [{ 'chart' => 'Empty', 'sigma_element_id' => 'el-empty', 'sigma_kind' => 'bar-chart', 'sigma_columns' => %w[c-x c-y] }],
    { 'el-empty' => "Region,Sales\n" })
  ok('headers-only → exit 2', st == 2)
  ok('listed in fail_names', s['fail_names'] == ['Empty'])
end

# 3. plotted column missing from export → FAIL
Dir.mktmpdir do |d|
  st, _ = run(d,
    [{ 'chart' => 'Rev', 'sigma_element_id' => 'el-rev', 'sigma_kind' => 'line-chart', 'sigma_columns' => %w[c-m c-r] }],
    { 'el-rev' => "Month,Other\n2025-01,5\n" })   # 'Net Revenue' absent
  ok('missing plotted column → FAIL', st == 2)
end

# 4. pivot-table wide grid (non-empty) → PASS without column enforcement
Dir.mktmpdir do |d|
  st, s = run(d,
    [{ 'chart' => 'Piv', 'sigma_element_id' => 'el-piv', 'sigma_kind' => 'pivot-table', 'sigma_columns' => %w[c-a] }],
    { 'el-piv' => "Region,Jan,Feb\nWest,1,2\nEast,3,4\n" })
  ok('pivot non-empty → PASS', st == 0 && s['status'] == 'PASS')
end

# 5. all cells blank → FAIL
Dir.mktmpdir do |d|
  st, _ = run(d,
    [{ 'chart' => 'Blank', 'sigma_element_id' => 'el-blank', 'sigma_kind' => 'kpi-chart', 'sigma_columns' => %w[c-b] }],
    { 'el-blank' => "B\n\n" })
  ok('all-blank → FAIL', st == 2)
end

# 6. query-error cell ("Invalid Query: …") → FAIL (handoff FIX 2: must not PASS a broken element)
Dir.mktmpdir do |d|
  st, s = run(d,
    [{ 'chart' => 'Broken', 'sigma_element_id' => 'el-rev', 'sigma_kind' => 'kpi-chart', 'sigma_columns' => %w[c-m c-r] }],
    { 'el-rev' => "Month,Net Revenue\n2025-01,Invalid Query: Unknown column DimDate.Month\n" })
  ok('query-error cell → exit 2', st == 2)
  ok('query-error cell listed as FAIL', s['fail_names'] == ['Broken'])
end

puts $fail.zero? ? "\nall verify-warehouse tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
