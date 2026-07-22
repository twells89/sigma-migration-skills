#!/usr/bin/env ruby
# Regression test for DM-metric EMIT + reference (bead 7bun.10 — emit-first).
#
# QuickSight doesn't emit DM metrics from the source; convert-model.rb --fixup now
# EMITS a governed metric per field-well aggregation onto the element(s) that carry
# the column, and build-workbook-from-quicksight.rb REFERENCES it: a measure whose
# inline aggregate matches binds to [Metrics/<name>] (formula-equivalence via the
# shared binder lib/metric_binding.rb; strip the master prefix). SAFE: no metrics /
# no match → inline, byte-identical.
#
# Deterministic + offline: runs the ACTUAL convert-model.rb --fixup (EMIT) then feeds
# its dm-spec as the workbook builder's --dm-readback (REFERENCE) — a true
# emit→reference round-trip — and asserts the SUM measure flips to [Metrics/<name>].
#
# Usage: ruby scripts/test-metric-reference.rb
require 'json'
require 'tmpdir'
require 'rbconfig'

HERE = __dir__
CONVERT = File.join(HERE, 'convert-model.rb')
BUILDER = File.join(HERE, 'build-workbook-from-quicksight.rb')
RUBY = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# one field-well SUM(NET_REVENUE) by REGION — the aggregation the DM metric is emitted from
ANALYSIS = { 'Definition' => { 'Sheets' => [{ 'SheetId' => 's1', 'Name' => 'S1', 'Visuals' => [
  { 'BarChartVisual' => { 'VisualId' => 'v1', 'Title' => { 'FormatText' => { 'PlainText' => 'Rev by Region' } },
    'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
      'Category' => [{ 'CategoricalDimensionField' => { 'FieldId' => 'd1', 'Column' => { 'ColumnName' => 'REGION' } } }],
      'Values' => [{ 'NumericalMeasureField' => { 'FieldId' => 'f1', 'Column' => { 'ColumnName' => 'NET_REVENUE' },
        'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }] } } } } }
] }] } }.freeze

# a converter-out model with one passthrough element carrying the columns
MODEL = { 'name' => 'QS', 'schemaVersion' => 1, 'pages' => [{ 'id' => 'pg', 'elements' => [
  { 'id' => 'el-1', 'name' => 'Orders', 'kind' => 'table',
    'source' => { 'connectionId' => 'conn', 'kind' => 'sql', 'statement' => 'select 1' },
    'columns' => [{ 'id' => 'c1', 'name' => 'Net Revenue', 'formula' => '[Custom SQL/NET_REVENUE]' },
                  { 'id' => 'c2', 'name' => 'Region', 'formula' => '[Custom SQL/REGION]' }] } ] }] }.freeze

# ---- EMIT: convert-model.rb --fixup reads analysis.json → metrics on the element ----
def emit_dm
  Dir.mktmpdir do |d|
    Dir.mkdir(File.join(d, 'datasets'))
    File.write(File.join(d, 'analysis.json'), JSON.generate(ANALYSIS))
    inp = File.join(d, 'model.json'); File.write(inp, JSON.generate(MODEL))
    out = File.join(d, 'dm-spec.json')
    system(RUBY, CONVERT, '--fixup', '--in', inp, '--discover-dir', d, '--folder-id', 'fld-x', '--out', out,
           out: File::NULL, err: File::NULL) or abort 'convert-model --fixup failed'
    return JSON.parse(File.read(out))
  end
end

# ---- REFERENCE: build the workbook against a readback, return the measure formula ----
def measure_formula(readback)
  Dir.mktmpdir do |d|
    an = File.join(d, 'an.json'); rb = File.join(d, 'rb.json'); out = File.join(d, 'wb.json')
    File.write(an, JSON.generate(ANALYSIS)); File.write(rb, JSON.generate(readback))
    system(RUBY, BUILDER, '--analysis', an, '--dm-readback', rb, '--out', out,
           out: File::NULL, err: File::NULL) or abort 'build-workbook failed'
    spec = JSON.parse(File.read(out))
    el = spec['pages'].flat_map { |p| p['elements'] }.find { |e| e['name'] == 'Rev by Region' }
    (el['columns'] || []).map { |c| c['formula'] }.find { |f| f.to_s =~ /Net Revenue|Metrics/ }
  end
end

# 1) EMIT: the field-well SUM(NET_REVENUE) becomes a metric on the "Orders" element
dm = emit_dm
orders = dm['pages'].flat_map { |p| p['elements'] }.find { |e| e['name'] == 'Orders' }
mets = (orders && orders['metrics']) || []
check(mets.any? { |m| m['formula'] == 'Sum([Net Revenue])' },
      "EMIT: convert-model emitted Sum([Net Revenue]) metric on the element (got #{mets.inspect})", fails)
metric_name = (mets.find { |m| m['formula'] == 'Sum([Net Revenue])' } || {})['name']

# 2) REFERENCE (round-trip): feed the emitted dm-spec back as the readback → measure binds
f_bound = measure_formula(dm)
check(f_bound == "[Metrics/#{metric_name}]",
      "REFERENCE: SUM measure binds to [Metrics/#{metric_name}] (got #{f_bound.inspect})", fails)

# 3) fallback: a readback with NO metrics → inline (byte-identical)
no_metrics = JSON.parse(JSON.generate(dm))
no_metrics['pages'].flat_map { |p| p['elements'] }.each { |e| e.delete('metrics') }
f_inline = measure_formula(no_metrics)
check(f_inline == 'Sum([Orders/Net Revenue])',
      "fallback: no metrics → inline Sum([Orders/Net Revenue]) (got #{f_inline.inspect})", fails)

# 4) non-match: a metric with a different formula must NOT be referenced
other = JSON.parse(JSON.generate(dm))
other['pages'].flat_map { |p| p['elements'] }.each { |e| e['metrics'] = [{ 'name' => 'Unrelated', 'formula' => 'Sum([Something Else])' }] if e['name'] == 'Orders' }
f_other = measure_formula(other)
check(f_other == 'Sum([Orders/Net Revenue])',
      "non-match: unrelated metric → inline (got #{f_other.inspect})", fails)

if fails.empty?
  puts 'ALL PASS — quicksight EMITs DM metrics from field-wells + binds workbook measures to [Metrics/<name>]'
  exit 0
else
  puts "FAILURES:\n  - #{fails.join("\n  - ")}"
  exit 1
end
