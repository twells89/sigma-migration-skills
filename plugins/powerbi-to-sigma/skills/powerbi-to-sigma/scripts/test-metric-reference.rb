#!/usr/bin/env ruby
# Regression test for DM-metric references in the workbook builder (bead 7bun.5).
#
# A measure prefers a governed [Metrics/<name>] reference over re-deriving the
# aggregation inline, when its emitted formula matches a metric on the measure's
# master (formula-equivalence match via the shared binder lib/metric_binding.rb;
# strip the master `id` prefix). migrate-powerbi.rb attaches each master's DM
# metrics (name + ORIGINAL bare formula) to master-map.json. SAFE: no metrics /
# no match → inline, byte-identical.
#
# Deterministic + offline: runs the ACTUAL build-workbook-from-pbir.rb on a
# synthetic signals + master-map (mirrors tests/test-grounding.rb) and asserts a
# CountDistinct measure flips from CountDistinct([master-emp/Headcount]) to
# [Metrics/Distinct Headcount] when a matching metric is present.
#
# Run: ruby scripts/test-metric-reference.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SKILL   = File.dirname(__dir__)
SCRIPTS = File.join(SKILL, 'scripts')
BUILDER = File.join(SCRIPTS, 'build-workbook-from-pbir.rb')
RUBY    = RbConfig.ruby

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def master(metrics)
  { 'id' => 'master-emp', 'element_id' => 'el-emp', 'data_model' => 'dm-x',
    'columns' => [
      { 'id' => 'mc-dept', 'name' => 'Department', 'formula' => '[EMP/Department]' },
      { 'id' => 'mc-hc',   'name' => 'Headcount',  'formula' => '[EMP/Headcount]' }
    ],
    'metrics' => metrics }
end

FIELDS = {
  'EMP.Department' => { 'master' => 'EMP', 'ref' => '[master-emp/Department]', 'agg' => nil },
  # a metric-derived measure: migrate emits the rewritten [mid/col] form verbatim
  'EMP.Headcount'  => { 'master' => 'EMP', 'ref' => 'CountDistinct([master-emp/Headcount])', 'agg' => nil }
}.freeze

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'pages' => [{ 'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720,
                'interactions' => [], 'visuals' => [
                  { 'visual_id' => 'v1', 'visual_type' => 'barChart', 'sigma_kind' => 'bar', 'title' => 'HC by Dept',
                    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
                    'bindings' => { 'Category' => ['EMP.Department'], 'Y' => ['EMP.Headcount'] },
                    'sort' => nil, 'formats' => {} }
                ] }]
}.freeze

def headcount_formula(metrics)
  formula = nil
  Dir.mktmpdir do |d|
    mmap = { 'masters' => { 'EMP' => master(metrics) }, 'fields' => FIELDS }
    File.write(File.join(d, 'mmap.json'), JSON.generate(mmap))
    File.write(File.join(d, 'sig.json'), JSON.generate(SIGNALS))
    wb = File.join(d, 'wb.json')
    _o, err, st = Open3.capture3(RUBY, BUILDER, '--signals', File.join(d, 'sig.json'),
                                 '--master-map', File.join(d, 'mmap.json'),
                                 '--data-model', 'dm-x', '--name', 'T',
                                 '--out', wb, '--layout-out', File.join(d, 'l.xml'),
                                 '--coverage-out', File.join(d, 'cov.json'))
    abort "builder failed:\n#{err}" unless st.success?
    spec = JSON.parse(File.read(wb))
    els = spec['pages'] ? spec['pages'].flat_map { |p| p['elements'] || [] } : (spec['elements'] || [])
    # the bar-chart element (NOT the Data-page master 'table', which also carries a
    # plain "Headcount" column)
    chart = els.find { |e| e['name'].to_s == 'HC by Dept' }
    hc = chart && (chart['columns'] || []).find { |c| c['name'].to_s == 'Headcount' }
    formula = hc && hc['formula'].to_s
  end
  formula
end

# 1) no metrics on the master → inline (byte-identical fallback)
f0 = headcount_formula([])
check(f0 == 'CountDistinct([master-emp/Headcount])',
      "no metrics: measure stays inline (got #{f0.inspect})", fails)

# 2) a matching DM metric (bare formula) → governed [Metrics/<name>] reference
f1 = headcount_formula([{ 'name' => 'Distinct Headcount', 'formula' => 'CountDistinct([Headcount])' }])
check(f1 == '[Metrics/Distinct Headcount]',
      "matching metric: measure binds to [Metrics/Distinct Headcount] (got #{f1.inspect})", fails)

# 3) non-matching metric → inline (no false positive)
f2 = headcount_formula([{ 'name' => 'Unrelated', 'formula' => 'Sum([Something Else])' }])
check(f2 == 'CountDistinct([master-emp/Headcount])',
      "non-matching metric: measure stays inline (got #{f2.inspect})", fails)

if fails.empty?
  puts 'ALL PASS — powerbi workbook measures bind to [Metrics/<name>] (byte-identical fallback)'
  exit 0
else
  puts "FAILURES:\n  - #{fails.join("\n  - ")}"
  exit 1
end
