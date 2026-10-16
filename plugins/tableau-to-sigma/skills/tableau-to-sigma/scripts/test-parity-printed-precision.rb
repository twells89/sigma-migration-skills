#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression: Tableau view CSVs are DISPLAY-formatted ("$#,##0" whole dollars,
# accounting negatives, percents printed to 1dp) while Sigma returns
# warehouse-precision values (field find: FP&A Executive Overview). Covers
#   * auto-parity-plan.rb  — parse_cell reads "($41,000)" / unicode minus as
#     negative and records the printed decimals per column as
#     entry['expected_decimals'] (percent => +2 fraction decimals)
#   * verify-parity.rb     — when expected_decimals is present, BOTH sides are
#     rounded from the RAW rows at those decimals (no round_row double-round of
#     a 3dp percent) and rows whose measure cells are all null on either side
#     (Tableau crosstab padding) are dropped.
#
# Usage:  ruby scripts/test-parity-printed-precision.rb
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

PLAN_SCRIPT = File.join(__dir__, 'auto-parity-plan.rb')
VERIFY_SCRIPT = File.join(__dir__, 'verify-parity.rb')

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# --- Part A: auto-parity-plan ------------------------------------------------
def build_plan(csv)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'get-workbook.json'),
               JSON.generate('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Variance' }] }))
    Dir.mkdir(File.join(dir, 'views'))
    File.write(File.join(dir, 'views', 'v1.csv'), csv)
    File.write(File.join(dir, 'wb.json'), JSON.generate(
      'schemaVersion' => 4, 'kind' => 'workbook',
      'pages' => [{ 'id' => 'pg', 'name' => 'Overview' }],
      'elements' => [{
        'id' => 'el-var', 'kind' => 'bar-chart', 'name' => 'Variance',
        'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm1', 'elementId' => 'dm-el' },
        'columns' => [{ 'id' => 'c-acct', 'name' => 'Account' },
                      { 'id' => 'c-var', 'name' => 'Variance' },
                      { 'id' => 'c-pct', 'name' => 'Margin' }],
        'xAxis' => { 'columnId' => 'c-acct' },
        'yAxis' => { 'columnIds' => %w[c-var c-pct] }
      }],
      'layout' => '<Page id="pg"><Element elementId="el-var"/></Page>'
    ))
    out = File.join(dir, 'plan.json')
    log, status = Open3.capture2e(RbConfig.ruby, PLAN_SCRIPT, '--tableau', dir, '--workbook-spec',
                                  File.join(dir, 'wb.json'), '--out', out, '--workbook-id', 'wb-t')
    plan = File.exist?(out) ? JSON.parse(File.read(out)) : nil
    [plan, log, status]
  end
end

puts 'test-parity-printed-precision:'
puts 'Part A — auto-parity-plan parse_cell + expected_decimals'
csv = "Account,Variance,Margin\n" \
      "Rev,\"($41,000)\",\"78.5%\"\n" \
      "COGS,\"−$1,250\",\"12.34%\"\n" \
      "Opex,\"$7,000\",\"-3.0%\"\n" \
      "Other,,\n"
plan, log, status = build_plan(csv)
check(status.success? && plan, "plan builds (exit #{status.exitstatus}: #{log.lines.last(2).join.strip})")
chart = plan && plan['charts'].first
rows = chart && chart['expected']
check(rows && rows[0][1] == -41_000.0, 'accounting negative "($41,000)" parses as -41000.0')
check(rows && rows[1][1] == -1250.0, 'unicode minus "−$1,250" parses as -1250.0')
check(rows && rows[2][1] == 7000.0, 'positive "$7,000" still parses positive')
check(rows && (rows[0][2] - 0.785).abs < 1e-12 && (rows[2][2] + 0.03).abs < 1e-12,
      'percents parse to fractions (78.5% -> 0.785, -3.0% -> -0.03)')
check(rows && rows[3][1].nil? && rows[3][2].nil?, 'blank padding cells stay nil')
decs = chart && chart['expected_decimals']
check(decs.is_a?(Array) && decs[1] == 0, "whole-dollar column records 0 printed decimals (got #{decs.inspect})")
check(decs.is_a?(Array) && decs[2] == 4, "percent column: max 2 printed decimals (12.34%) + 2 = 4 (got #{decs.inspect})")
check(decs.is_a?(Array) && decs[0].nil?, 'dimension column carries no printed precision')
check(chart && chart['measure_indices'] == [1, 2], 'plan records plotted measure columns separately from dimensions')

plan2, = build_plan("Account,Variance,Margin\nRev,-100.5,0.25\nCOGS,7,-0.5\n")
check(plan2 && !plan2['charts'].first.key?('expected_decimals'),
      'unformatted numeric CSV, including negatives, records no expected_decimals')

# --- Part B: verify-parity ---------------------------------------------------
def verify(chart)
  Dir.mktmpdir do |dir|
    plan = File.join(dir, 'plan.json')
    File.write(plan, JSON.generate('charts' => [chart]))
    out, _err, st = Open3.capture3(RbConfig.ruby, VERIFY_SCRIPT, '--plan', plan,
                                   '--score-out', File.join(dir, 'score.json'))
    [st.exitstatus, out]
  end
end

puts 'Part B — verify-parity printed-precision compare'
# Sigma returns cents; Tableau printed whole dollars — equal at the printed grain.
rc, out = verify('chart' => 'Whole dollars', 'extract' => false,
                 'expected' => [['Rev', 41_000.0], ['COGS', -1250.0]],
                 'expected_decimals' => [nil, 0],
                 'actual' => { 'rows' => [['Rev', 41_000.38], ['COGS', -1249.64]] })
check(rc.zero? && out.include?('PASS'), "cent-precision Sigma == whole-dollar Tableau at expected_decimals=0 (exit #{rc})")

rc, out = verify('chart' => 'Whole dollars (no decimals recorded)', 'extract' => false,
                 'expected' => [['Rev', 41_000.0]],
                 'actual' => { 'rows' => [['Rev', 41_000.38]] })
check(rc == 1 && out.include?('DIVERGE'), "without expected_decimals the same pair still DIVERGEs (exit #{rc})")

rc, out = verify('chart' => 'Wrong beyond printed grain', 'extract' => false,
                 'expected' => [['Rev', 41_000.0]],
                 'expected_decimals' => [nil, 0],
                 'actual' => { 'rows' => [['Rev', 41_002.0]] })
check(rc == 1 && out.include?('DIVERGE'), "a real difference beyond the printed grain still DIVERGEs (exit #{rc})")

# 78.5% printed to 1dp => fraction 0.785 at 3 decimals. Sigma 0.78497 must round
# to 0.785 from RAW, not through round_row's 2dp (0.785 -> 0.79 vs 0.78497 -> 0.78).
rc, out = verify('chart' => 'Percent 3dp', 'extract' => false,
                 'expected' => [['Rev', 0.785]],
                 'expected_decimals' => [nil, 3],
                 'actual' => { 'rows' => [['Rev', 0.78497]] })
check(rc.zero? && out.include?('PASS'), "3dp percent compares from RAW rows, no 2dp double-round (exit #{rc})")

# Tableau crosstab padding: all-measure-null rows on either side are dropped.
rc, out = verify('chart' => 'Crosstab padding', 'extract' => false,
                 'expected' => [['Rev', 5.0], ['Pad Dim', nil]],
                 'expected_decimals' => [nil, 0],
                 'actual' => { 'rows' => [['Rev', 5.2]] })
check(rc.zero? && out.include?('PASS'), "all-null measure padding row on the Tableau side is dropped (exit #{rc})")

rc, out = verify('chart' => 'Sigma null row', 'extract' => false,
                 'expected' => [['Rev', 5.0]],
                 'expected_decimals' => [nil, 0],
                 'actual' => { 'rows' => [['Rev', 5.2], ['Ghost', nil]] })
check(rc.zero? && out.include?('PASS'), "all-null measure row on the Sigma side is dropped (exit #{rc})")

# A row with a real value is never dropped — a missing Sigma row still fails.
rc, out = verify('chart' => 'Missing row', 'extract' => false,
                 'expected' => [['Rev', 5.0], ['COGS', 9.0]],
                 'expected_decimals' => [nil, 0],
                 'actual' => { 'rows' => [['Rev', 5.2]] })
check(rc == 1 && out.include?('DIVERGE'), "a row with a real measure missing from Sigma still DIVERGEs (exit #{rc})")

# A populated unformatted companion measure makes the row real even when the
# formatted measure is null.
rc, out = verify('chart' => 'Mixed-format missing row', 'extract' => false,
                 'expected' => [['East', 10.0, 2.0], ['West', nil, 5.0]],
                 'expected_decimals' => [nil, 0, nil],
                 'measure_indices' => [1, 2],
                 'actual' => { 'rows' => [['East', 10.2, 2.0]] })
check(rc == 1 && out.include?('DIVERGE'),
      "a row populated only in an unformatted measure still DIVERGEs when missing from Sigma (exit #{rc})")

# Numeric dimensions must not keep otherwise all-null crosstab padding.
rc, out = verify('chart' => 'Numeric dimension padding', 'extract' => false,
                 'expected' => [['East', 2025.0, 5.0], ['West', 2025.0, nil]],
                 'expected_decimals' => [nil, nil, 0],
                 'measure_indices' => [2],
                 'actual' => { 'rows' => [['East', 2025.0, 5.2]] })
check(rc.zero? && out.include?('PASS'), "numeric dimensions are not treated as measures (exit #{rc})")

puts
if FAILS.empty?
  puts 'OK — printed-precision parity tests passed'
  exit 0
else
  warn "FAIL — #{FAILS.size} check(s) failed:"
  FAILS.each { |f| warn "  - #{f}" }
  exit 1
end
