#!/usr/bin/env ruby
# frozen_string_literal: true
# test-verify-ground-truth.rb — offline tests for scripts/verify-ground-truth.rb
# (PR-6 part B: ground-truth vs Sigma-export comparison, numeric_parity stamps,
# the anchors-coexistence conflict matrix) and the shared dim canonicalizer
# (scripts/lib/dim_canon.rb — incl. the e2e-defect date formats).
#
# Run: ruby scripts/test-verify-ground-truth.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'verify-ground-truth.rb')
require_relative 'lib/dim_canon'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

T0 = '2026-07-18T00:00:00Z'

def entry(chart, cls, dims: 1, measures: 1, reason: nil)
  cols = (1..dims).map { |i| { 'alias' => "Dim#{i}", 'role' => 'dim' } } +
         (1..measures).map { |i| { 'alias' => "Meas#{i}", 'role' => 'measure' } }
  { 'chart' => chart, 'sigma_element_id' => "el-#{chart.downcase.tr(' ', '-')}",
    'classification' => cls, 'reason' => reason,
    'sql' => cls == 'warehouse-sql' ? 'SELECT 1' : nil,
    'columns' => cls == 'warehouse-sql' ? cols : nil }
end

def stage(dir, entries, gt_rows_by_chart, sigma_by_chart, plan_extra: {}, actuals_stamp: T0)
  File.write(File.join(dir, 'ground-truth-plan.json'), JSON.pretty_generate(
    { 'version' => 1, 'generated_at' => T0, 'entries' => entries }.merge(plan_extra)))
  results = entries.each_with_index.map do |e, i|
    base = { 'index' => i, 'chart' => e['chart'], 'classification' => e['classification'] }
    if e['classification'] == 'warehouse-sql' && gt_rows_by_chart.key?(e['chart'])
      base.merge('status' => 'ok', 'columns' => Array(e['columns']).map { |c| c['alias'] },
                 'rows' => gt_rows_by_chart[e['chart']])
    elsif e['classification'] == 'warehouse-sql'
      base.merge('status' => 'error', 'error' => 'no canned rows')
    else
      base.merge('status' => "skipped-#{e['classification']}")
    end
  end
  File.write(File.join(dir, 'ground-truth-actuals.json'), JSON.pretty_generate(
    'version' => 1, 'plan_generated_at' => actuals_stamp, 'results' => results))
  File.write(File.join(dir, 'parity-actuals.json'), JSON.pretty_generate(sigma_by_chart))
end

def run(dir, *args)
  Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
end

puts '-- dim_canon: e2e-defect date formats canonicalize (ONE shared place) --'
ok(DimCanon.canonicalize_dim('1/4/2026 12:00:00 AM') == '2026-01-04',
   'M/D/YYYY 12:00:00 AM (e2e defect list) → day bucket')
ok(DimCanon.canonicalize_dim('11/23/2026') == '2026-11-23', 'bare M/D/YYYY → day bucket')
ok(DimCanon.canonicalize_dim('Feb 4, 24') == '2024-02-04', '%b %d, %y (e2e defect list) → day bucket')
ok(DimCanon.canonicalize_dim('February 4, 2024') == '2024-02-04', '%B %d, %Y still works')
ok(DimCanon.canonicalize_dim('2026-01-04T00:00:00.000') == '2026-01-04', 'ISO midnight → day bucket')
ok(DimCanon.canonicalize_dim('1/4/2026 3:15:00 PM') == '1/4/2026 3:15:00 PM',
   'a NON-midnight time is left alone (distinct hourly buckets must not merge)')
ok(DimCanon.canonicalize_dim('Jan 2026') == '2026-01', 'month label → month bucket')

puts '-- verify-parity uses the SAME canonicalizer (no drift between oracles) --'
vp = File.read(File.join(__dir__, 'verify-parity.rb'))
ok(vp.include?("require_relative 'lib/dim_canon'"), 'verify-parity.rb requires lib/dim_canon')
ok(!vp.include?('MONTH_NUM = {'), 'verify-parity.rb no longer carries a private month table')

puts '-- exact match → verdict match, stamps extend parity-final --'
Dir.mktmpdir do |d|
  stage(d, [entry('Sales by Region', 'warehouse-sql')],
        { 'Sales by Region' => [['East', 100.5], ['West', 200.25]] },
        { 'Sales by Region' => [['West', 200.25], ['East', 100.5]] })
  File.write(File.join(d, 'parity-final.json'), JSON.pretty_generate(
    'status' => 'PASS', 'charts_total' => 1, 'charts_pass' => 1, 'anchors' => { 'pass' => true }))
  out, _err, st = run(d)
  ok(st.exitstatus.zero?, "exact match → exit 0 (got #{st.exitstatus})")
  np = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))
  t = np['tiles']['Sales by Region']
  ok(t['oracle'] == 'warehouse-sql' && t['verdict'] == 'match' && t['rows_compared'] == 2 &&
     t['max_rel_diff'] == 0.0, "stamp carries oracle/verdict/rows/max_rel_diff (got #{t.inspect})")
  ok(np['plan_generated_at'] == T0, 'stamps bind to the plan generated_at')
  pf = JSON.parse(File.read(File.join(d, 'parity-final.json')))
  ok(pf['numeric_parity'].is_a?(Hash) && pf['numeric_parity']['tiles'].key?('Sales by Region'),
     'numeric_parity stamped into parity-final.json')
  ok(pf['status'] == 'PASS' && pf['charts_total'] == 1 && pf['anchors'] == { 'pass' => true },
     'parity-final existing shape EXTENDED, not replaced')
  ok(out.include?('1/1 tile(s) match'), 'summary line reports the match count')
end

puts '-- tiny relative diff within strict tol → match --'
Dir.mktmpdir do |d|
  stage(d, [entry('KPI', 'warehouse-sql', dims: 0)],
        { 'KPI' => [[1_234_567.8]] }, { 'KPI' => [[1_234_567.9]] })
  _out, _err, st = run(d)
  ok(st.exitstatus.zero?, "rel diff ~8e-8 within default tol → exit 0 (got #{st.exitstatus})")
end

puts '-- Sigma display-formatted export precision → match only when rounded values agree --'
Dir.mktmpdir do |d|
  stage(d, [entry('Rounded KPI', 'warehouse-sql', dims: 0)],
        { 'Rounded KPI' => [[2168.76]] }, { 'Rounded KPI' => [[2169.0]] })
  _out, _err, st = run(d)
  stamp = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))['tiles']['Rounded KPI']
  ok(st.exitstatus.zero? && stamp['verdict'] == 'match' && stamp['display_precision'] == true,
     'ground truth rounds to the precision exposed by the Sigma element export')
end
Dir.mktmpdir do |d|
  stage(d, [entry('Rounded Divergence', 'warehouse-sql', dims: 0)],
        { 'Rounded Divergence' => [[2168.2]] }, { 'Rounded Divergence' => [[2169.0]] })
  _out, _err, st = run(d)
  ok(st.exitstatus == 2, 'difference that survives export rounding still diverges')
end

puts '-- divergence → FATAL naming tile + measure + both values --'
Dir.mktmpdir do |d|
  stage(d, [entry('Revenue Trend', 'warehouse-sql')],
        { 'Revenue Trend' => [['2026-01', 100.0], ['2026-02', 500.0]] },
        { 'Revenue Trend' => [['2026-01', 100.0], ['2026-02', 5000.0]] })
  _out, err, st = run(d)
  ok(st.exitstatus == 2, "diverge → exit 2 (got #{st.exitstatus})")
  ok(err.include?('"Revenue Trend" DIVERGES'), 'FATAL names the tile')
  ok(err.include?('Meas1') && err.include?('500.0') && err.include?('5000.0'),
     'FATAL names the measure and BOTH values')
  np = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))
  t = np['tiles']['Revenue Trend']
  ok(t['verdict'] == 'diverge' && t['worst']['ground_truth'] == 500.0 && t['worst']['sigma'] == 5000.0,
     'diverge stamp carries the worst row evidence')
end

puts '-- bucket mismatch → diverge naming the missing dims --'
Dir.mktmpdir do |d|
  stage(d, [entry('Buckets', 'warehouse-sql')],
        { 'Buckets' => [['East', 1], ['West', 2], ['South', 3]] },
        { 'Buckets' => [['East', 1], ['West', 2]] })
  _out, err, st = run(d)
  ok(st.exitstatus == 2, "missing bucket → exit 2 (got #{st.exitstatus})")
  ok(err.include?('South'), 'divergence lists the bucket only in ground truth')
end

puts '-- dim canonicalization joins mixed date representations --'
Dir.mktmpdir do |d|
  stage(d, [entry('Weekly', 'warehouse-sql')],
        { 'Weekly' => [['2026-01-04 00:00:00.000', 10.0], ['2024-02-04T00:00:00', 20.0]] },
        { 'Weekly' => [['1/4/2026 12:00:00 AM', 10.0], ['Feb 4, 24', 20.0]] })
  _out, _err, st = run(d)
  ok(st.exitstatus.zero?, "M/D/YYYY 12:00:00 AM + %b %d, %y join ISO buckets → exit 0 (got #{st.exitstatus})")
end

puts '-- stale actuals → refused --'
Dir.mktmpdir do |d|
  stage(d, [entry('Sales', 'warehouse-sql')], { 'Sales' => [['E', 1]] }, { 'Sales' => [['E', 1]] },
        actuals_stamp: '2020-01-01T00:00:00Z')
  _out, err, st = run(d)
  ok(st.exitstatus == 1 && err.include?('STALE'), "actuals not bound to the plan → exit 1 (got #{st.exitstatus})")
end

puts '-- Sigma export marker / missing actuals → unverified, never diverge --'
Dir.mktmpdir do |d|
  stage(d, [entry('Pivot', 'warehouse-sql'), entry('Ghosted', 'warehouse-sql')],
        { 'Pivot' => [['E', 1]], 'Ghosted' => [['E', 1]] },
        { 'Pivot' => { 'status' => 'render-verify-required', 'reason' => 'pivot CSV 500' } })
  _out, _err, st = run(d)
  ok(st.exitstatus.zero?, "markers/missing exports → exit 0 (unverified, gate 18 owns coverage; got #{st.exitstatus})")
  np = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))
  ok(np['tiles']['Pivot']['verdict'] == 'unverified' && np['tiles']['Pivot']['reason'].include?('render-verify-required'),
     'marker actual → unverified naming the marker')
  ok(np['tiles']['Ghosted']['verdict'] == 'unverified', 'missing Sigma actual → unverified')
end

puts '-- vds tiles read the vds-oracle verdicts --'
Dir.mktmpdir do |d|
  stage(d, [entry('Running', 'vds', reason: 'window calc'), entry('Rank', 'vds', reason: 'window calc')],
        {}, {})
  File.write(File.join(d, 'vds-oracle.json'), JSON.pretty_generate(
    'checks' => [
      { 'element_id' => 'el-running', 'element_name' => 'Running', 'calc' => 'Running Sales',
        'status' => 'match', 'n_joined' => 12, 'max_rel_diff' => 0.0 },
      { 'element_id' => 'el-rank', 'element_name' => 'Rank', 'calc' => 'Sales Rank',
        'status' => 'diverge', 'n_joined' => 8, 'max_rel_diff' => 0.4,
        'tableau_value' => 3, 'sigma_value' => 7 }
    ]))
  _out, err, st = run(d)
  ok(st.exitstatus == 2, "vds diverge → exit 2 (got #{st.exitstatus})")
  np = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))
  ok(np['tiles']['Running']['oracle'] == 'vds' && np['tiles']['Running']['verdict'] == 'match',
     'vds match credited from vds-oracle.json')
  ok(np['tiles']['Rank']['verdict'] == 'diverge' && err.include?('Sales Rank'),
     'vds diverge surfaces the calc name')
end

puts '-- anchors credit: VALUED anchors only (provenance rules) --'
Dir.mktmpdir do |d|
  stage(d, [entry('Blend Tile', 'anchor-only', reason: 'data blend'),
            entry('Eyeballed Tile', 'anchor-only', reason: 'LOD calc')], {}, {})
  File.write(File.join(d, 'anchors-verdict.json'), JSON.pretty_generate(
    'checked' => 2, 'matched' => 2, 'missing' => [], 'pass' => true,
    'detail' => [
      { 'id' => 'a1', 'raw' => '1,234', 'matched_in' => 'Blend Tile',
        'kind' => 'number', 'provenance' => 'view-csv', 'valued' => true },
      { 'id' => 'a2', 'raw' => '9,876', 'matched_in' => 'Eyeballed Tile',
        'kind' => 'number', 'provenance' => 'png-eyeball', 'valued' => false }
    ]))
  _out, _err, st = run(d)
  ok(st.exitstatus.zero?, "anchors credit run → exit 0 (got #{st.exitstatus})")
  np = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))
  ok(np['tiles']['Blend Tile']['oracle'] == 'anchors' && np['tiles']['Blend Tile']['verdict'] == 'match',
     'valued (view-csv) anchor match verifies an anchor-only tile')
  e = np['tiles']['Eyeballed Tile']
  ok(e['verdict'] == 'unverified' && e['reason'].include?('none are VALUED'),
     'png-eyeball anchors earn NO credit — tile stays unverified naming why')
end

puts '-- conflict matrix: oracle diverges + anchors matched → FATAL-investigate (data bug) --'
Dir.mktmpdir do |d|
  stage(d, [entry('KPI Total', 'warehouse-sql', dims: 0)],
        { 'KPI Total' => [[100.0]] }, { 'KPI Total' => [[999.0]] })
  File.write(File.join(d, 'anchors-verdict.json'), JSON.pretty_generate(
    'checked' => 1, 'matched' => 1, 'missing' => [], 'pass' => true,
    'detail' => [{ 'id' => 'a1', 'raw' => '999', 'matched_in' => 'KPI Total',
                   'kind' => 'number', 'provenance' => 'view-csv', 'valued' => true }]))
  _out, err, st = run(d)
  ok(st.exitstatus == 2, "conflict run → exit 2 (got #{st.exitstatus})")
  np = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))
  c = np['tiles']['KPI Total']['conflict']
  ok(c.is_a?(Hash) && c['type'] == 'oracle-diverges-anchors-match', 'conflict type recorded')
  ok(err.include?('FATAL-INVESTIGATE') && err.include?('DATA BUG'), 'conflict names the investigate class')
  ok(err.include?('100.0') && err.include?('999'), 'BOTH sides of the evidence are printed')
  ok(err.include?('never edit the ground truth or the anchors'), 'no auto-resolution doctrine stated')
end

puts '-- conflict matrix: anchors diverge + oracle matches → FATAL-investigate (translation bug) --'
Dir.mktmpdir do |d|
  stage(d, [entry('KPI Total', 'warehouse-sql', dims: 0)],
        { 'KPI Total' => [[999.0]] }, { 'KPI Total' => [[999.0]] })
  File.write(File.join(d, 'anchors-verdict.json'), JSON.pretty_generate(
    'checked' => 1, 'matched' => 0, 'pass' => false,
    'missing' => [{ 'id' => 'a1', 'label' => 'KPI', 'raw' => '1,234', 'kind' => 'number',
                    'provenance' => 'view-csv', 'sigma_element_hint' => 'KPI Total',
                    'best_candidate' => { 'value' => 999.0, 'element' => 'KPI Total' } }],
    'detail' => []))
  _out, err, st = run(d)
  ok(st.exitstatus == 2, "inverse conflict → exit 2 (got #{st.exitstatus})")
  np = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))
  c = np['tiles']['KPI Total']['conflict']
  ok(c.is_a?(Hash) && c['type'] == 'anchors-diverge-oracle-matches', 'inverse conflict type recorded')
  ok(np['tiles']['KPI Total']['verdict'] == 'match', 'the oracle verdict itself is preserved (not auto-resolved)')
  ok(err.include?('TRANSLATION/SOURCE-READING BUG') && err.include?('1,234'),
     'inverse conflict names the class + the missing anchor evidence')
end

puts '-- both oracles agree → verified, no conflict --'
Dir.mktmpdir do |d|
  stage(d, [entry('KPI Total', 'warehouse-sql', dims: 0)],
        { 'KPI Total' => [[999.0]] }, { 'KPI Total' => [[999.0]] })
  File.write(File.join(d, 'anchors-verdict.json'), JSON.pretty_generate(
    'checked' => 1, 'matched' => 1, 'missing' => [], 'pass' => true,
    'detail' => [{ 'id' => 'a1', 'raw' => '999', 'matched_in' => 'KPI Total',
                   'kind' => 'number', 'provenance' => 'view-csv', 'valued' => true }]))
  _out, _err, st = run(d)
  np = JSON.parse(File.read(File.join(d, 'numeric-parity.json')))
  ok(st.exitstatus.zero? && np['tiles']['KPI Total']['verdict'] == 'match' &&
     !np['tiles']['KPI Total'].key?('conflict'),
     'warehouse match + anchors match → verified, no conflict')
end

puts '-- extract tolerance: artifact-gated (same rule as verify-anchors) --'
Dir.mktmpdir do |d|
  stage(d, [entry('Drift', 'warehouse-sql', dims: 0)],
        { 'Drift' => [[104.0]] }, { 'Drift' => [[106.0]] })
  _out, err, st = run(d, '--extract-tol', '0.05')
  ok(st.exitstatus == 2 && err.include?('REFUSED'),
     "unmarked workdir: --extract-tol refused, drift diverges → exit 2 (got #{st.exitstatus})")
end
Dir.mktmpdir do |d|
  stage(d, [entry('Drift', 'warehouse-sql', dims: 0)],
        { 'Drift' => [[104.0]] }, { 'Drift' => [[106.0]] })
  File.write(File.join(d, 'get-workbook.json'), JSON.pretty_generate('hasExtracts' => true))
  _out, err, st = run(d, '--extract-tol', '0.05')
  ok(st.exitstatus.zero? && err.include?('ACTIVE'),
     "extract-marked workdir: tolerance active, ~1.9% drift matches → exit 0 (got #{st.exitstatus})")
end

puts '-- usage guards --'
Dir.mktmpdir do |d|
  _out, err, st = run(d)
  ok(st.exitstatus == 1 && err.include?('derive-ground-truth'),
     'missing plan → exit 1 pointing at derive-ground-truth.rb')
end

puts
if $fails.empty?
  puts 'ALL PASS — verify-ground-truth comparison + conflict matrix + shared dim canonicalizer'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
