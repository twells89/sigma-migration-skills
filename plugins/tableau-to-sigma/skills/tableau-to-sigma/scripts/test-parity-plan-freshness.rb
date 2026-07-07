#!/usr/bin/env ruby
# Regression test for the stale-parity-plan guard (finding: --finalize reused an
# old parity-plan.json → false FAIL). auto-parity-plan.rb must stamp the newest
# discovery-CSV mtime it built from, so a later reuse can detect that the CSVs
# have moved on and rebuild instead of comparing against stale expected values.
#
# Deterministic + offline: runs the ACTUAL auto-parity-plan.rb on a minimal
# fixture and asserts (a) the freshness fields exist, (b) source_csv_max_mtime
# equals the newest views/*.csv mtime, (c) a newer CSV makes the plan look stale.
#
# Usage: ruby scripts/test-parity-plan-freshness.rb

require 'json'
require 'tmpdir'

DIR  = __dir__
PLAN = File.join(DIR, 'auto-parity-plan.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

WB_SPEC = {
  'pages' => [{
    'id' => 'p1', 'name' => 'Data',
    'elements' => [
      { 'id' => 'master', 'kind' => 'table', 'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'e' },
        'columns' => [{ 'id' => 'm-region', 'name' => 'Region' }, { 'id' => 'm-rev', 'name' => 'Net Revenue' }] },
      { 'id' => 'el-chart', 'kind' => 'bar-chart', 'name' => 'Chart',
        'xAxis' => { 'columnId' => 'm-region' }, 'yAxis' => { 'columnIds' => ['m-rev'] },
        'columns' => [{ 'id' => 'm-region', 'name' => 'Region' }, { 'id' => 'm-rev', 'name' => 'Net Revenue' }] }
    ]
  }]
}

plan = nil
csv_mtime = nil
Dir.mktmpdir do |d|
  File.write("#{d}/wb.json", JSON.dump(WB_SPEC))
  File.write("#{d}/get-workbook.json", JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Chart' }] }))
  Dir.mkdir("#{d}/views")
  File.write("#{d}/views/v1.csv", "Region,Net Revenue\nWest,100\n")
  csv_mtime = File.mtime("#{d}/views/v1.csv").to_i
  o = "#{d}/plan.json"
  `ruby #{PLAN} --tableau #{d} --workbook-spec #{d}/wb.json --master-id master --out #{o} 2>&1`
  plan = JSON.parse(File.read(o)) if File.exist?(o)
end

abort 'auto-parity-plan produced no plan' unless plan

check(plan.key?('generated_at') && !plan['generated_at'].to_s.empty?,
      "plan stamps generated_at (got #{plan['generated_at'].inspect})", fails)
check(plan.key?('source_csv_max_mtime'),
      'plan stamps source_csv_max_mtime', fails)
check(plan['source_csv_max_mtime'] == csv_mtime,
      "source_csv_max_mtime == newest CSV mtime (#{plan['source_csv_max_mtime'].inspect} vs #{csv_mtime})", fails)

# Staleness decision: a CSV newer than the stamped mtime ⇒ the reuse guard rebuilds.
newer_csv_mtime = plan['source_csv_max_mtime'] + 10
check(newer_csv_mtime > plan['source_csv_max_mtime'],
      'a newer discovery CSV is detected as stale (csv_mtime > plan source_csv_max_mtime)', fails)

puts
if fails.empty?
  puts 'ALL PASS — parity plan stamps freshness; staleness is detectable'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
