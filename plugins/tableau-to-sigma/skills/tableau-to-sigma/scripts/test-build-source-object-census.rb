#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

SCRIPT = File.join(__dir__, 'build-source-object-census.rb')
REPORT = File.join(__dir__, 'build-migration-report.rb')
RUBY = RbConfig.ruby
TERMINAL = %w[migrated approximated needs-review skipped not-applicable].freeze

$failures = []
def check(condition, message)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  $failures << message unless condition
end

def write_json(dir, name, value)
  path = File.join(dir, name)
  File.write(path, JSON.pretty_generate(value))
  path
end

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8'?>
  <workbook>
    <datasources>
      <datasource caption='Orders' name='orders'>
        <column caption='Profit Ratio' datatype='real' name='[calc_profit]' role='measure'>
          <calculation class='tableau' formula='SUM([Profit]) / SUM([Sales])' />
        </column>
        <column caption='Approx Calc' datatype='real' name='[calc_approx]' role='measure'>
          <calculation class='tableau' formula='WINDOW_SUM(SUM([Sales]))' />
        </column>
        <column caption='Unsupported Calc' datatype='real' name='[calc_unsupported]' role='measure'>
          <calculation class='tableau' formula='SCRIPT_REAL(&quot;x&quot;, SUM([Sales]))' />
        </column>
        <group caption='Top Customers' name='[set_top]'>
          <groupfilter function='set' />
        </group>
      </datasource>
      <datasource name='Parameters'>
        <column caption='Region Parameter' datatype='string' name='[param_region]' param-domain-type='list' value='West' />
        <column caption='Broken Parameter' datatype='string' name='[param_broken]' param-domain-type='list' value='A' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Revenue' />
      <worksheet name='Gauge' />
      <worksheet name='Missing Sheet' />
      <worksheet name='Orphan Sheet' />
    </worksheets>
    <dashboards>
      <dashboard name='Sales Dashboard'>
        <zones>
          <zone id='1' name='Revenue' />
          <zone id='2' name='Gauge' />
          <zone id='3' name='Missing Sheet' />
          <zone id='4' type-v2='title' />
        </zones>
      </dashboard>
      <dashboard name='Archive Dashboard'>
        <zones><zone id='9' name='Orphan Sheet' /></zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

Dir.mktmpdir('tableau-source-census') do |dir|
  twb = File.join(dir, 'workbook-content.twb')
  File.write(twb, TWB)
  write_json(dir, 'dashboard-scope.json',
             'schema_version' => 1, 'mode' => 'selected',
             'provenance' => 'stated', 'dashboards' => ['Sales Dashboard'])
  layout = write_json(dir, 'dashboard-layout.json', [
    {
      'dashboard' => 'Sales Dashboard',
      'zones' => [
        { 'id' => '1', 'kind' => 'chart', 'caption' => 'Revenue' },
        { 'id' => '2', 'kind' => 'chart', 'caption' => 'Gauge' },
        { 'id' => '3', 'kind' => 'chart', 'caption' => 'Missing Sheet' },
        { 'id' => '4', 'kind' => 'title', 'caption' => 'Executive summary' }
      ]
    }
  ])
  meta = write_json(dir, 'dashboard-layout-meta.json',
                    'worksheets' => { 'Revenue' => {}, 'Gauge' => {}, 'Missing Sheet' => {} },
                    'parameters' => [{ 'name' => 'Region Parameter' }])
  calcs = write_json(dir, 'calc-fields.json',
                     'calcs' => [
                       { 'name' => 'Profit Ratio', 'internal_name' => '[calc_profit]',
                         'datasource' => 'Orders', 'formula' => 'SUM([Profit]) / SUM([Sales])' },
                       { 'name' => 'Approx Calc', 'internal_name' => '[calc_approx]',
                         'datasource' => 'Orders', 'formula' => 'WINDOW_SUM(SUM([Sales]))' },
                       { 'name' => 'Unsupported Calc', 'internal_name' => '[calc_unsupported]',
                         'datasource' => 'Orders', 'formula' => 'SCRIPT_REAL("x", SUM([Sales]))',
                         'requires_custom_sql' => true }
                     ])
  gaps = write_json(dir, 'workbook-content-gaps-report.json',
                    'detected_features' => [
                      { 'name' => 'Sets (computed / manual)', 'status' => 'unhandled',
                        'detail' => 'No direct Sigma set primitive' }
                    ],
                    'formula_audit' => {
                      'formulas' => [
                        { 'name' => 'Unsupported Calc', 'status' => 'unmapped',
                          'detail' => 'embedded scanner audit' }
                      ]
                    })
  formula_audit = write_json(dir, 'formula-audit.json',
                             'calculations' => [
                               { 'name' => 'Profit Ratio', 'status' => 'pass',
                                 'detail' => 'formula compiled' },
                               { 'name' => 'Unsupported Calc', 'status' => 'unmapped',
                                 'detail' => 'SCRIPT_REAL has no warehouse translation' }
                             ])
  blend = write_json(dir, 'blend-plan.json',
                     'blends' => [
                       { 'worksheet' => 'Revenue', 'primary' => 'orders', 'secondary' => 'targets',
                         'route' => 'same-warehouse' },
                       { 'worksheet' => 'Future Blend', 'primary' => 'orders', 'secondary' => 'upload',
                         'route' => 'materialize-via-vds' }
                     ])
  coverage = write_json(dir, 'coverage.json',
                        'unresolved' => [
                          { 'visual' => 'Gauge', 'source_type' => 'worksheet',
                            'severity' => 'approximated', 'detail' => 'gauge rendered as KPI' },
                          { 'visual' => 'Missing Sheet', 'source_type' => 'worksheet',
                            'severity' => 'dropped', 'detail' => 'unsupported extension object' },
                          { 'visual' => 'Approx Calc', 'source_type' => 'calc',
                            'severity' => 'approximated', 'detail' => 'window helper approximation' },
                          { 'visual' => 'Broken Parameter', 'source_type' => 'parameter',
                            'severity' => 'dropped', 'detail' => 'target column missing' }
                        ])
  controls = write_json(dir, 'tableau-controls-coverage.json',
                        'detail' => [
                          { 'control' => 'Region Parameter', 'status' => 'emitted',
                            'detail' => 'control present and bound' },
                          { 'control' => 'Broken Parameter', 'status' => 'dropped',
                            'detail' => 'no target binding' }
                        ])
  parity = write_json(dir, 'parity-final.json',
                      'status' => 'PASS', 'charts_total' => 2, 'charts_pass' => 2,
                      'pass_names' => %w[Revenue Gauge], 'fail_names' => [])
  readback = write_json(dir, 'wb-readback.json',
                        'pages' => [{ 'id' => 'page-sales', 'name' => 'Sales Dashboard' }],
                        'elements' => [
                          { 'id' => 'revenue', 'kind' => 'bar-chart', 'name' => 'Revenue',
                            'columns' => [{ 'id' => 'profit-ratio', 'name' => 'Profit Ratio' }] },
                          { 'id' => 'gauge', 'kind' => 'kpi-chart', 'name' => 'Gauge',
                            'columns' => [{ 'id' => 'approx', 'name' => 'Approx Calc' }] },
                          { 'id' => 'region', 'kind' => 'control', 'name' => 'Region Parameter',
                            'controlId' => 'region-parameter', 'controlType' => 'list' }
                        ])
  spec = write_json(dir, 'wb-spec.json', JSON.parse(File.read(readback)))

  args = [
    RUBY, SCRIPT, '--workdir', dir,
    '--twb', twb, '--dashboard-layout', layout, '--dashboard-meta', meta,
    '--calc-fields', calcs, '--gap-audit', gaps, '--formula-audit', formula_audit,
    '--blend-plan', blend, '--coverage', coverage, '--controls-census', controls,
    '--parity-final', parity, '--wb-spec', spec, '--wb-readback', readback
  ]
  stdout, stderr, status = Open3.capture3(*args)
  check(status.success?, "explicit artifact invocation succeeds (#{stderr})")
  check(stdout.include?('source object census:'), 'prints a compact accounting summary')

  output = File.join(dir, 'source-object-census.json')
  first_bytes = File.binread(output)
  census = JSON.parse(first_bytes)
  types = census['objects'].map { |object| object['type'] }.uniq.sort
  check(types == %w[blend calculation dashboard dashboard-zone parameter set worksheet],
        'census covers dashboards, worksheets/zones, calculations, sets, parameters, and blends')
  check(census.dig('summary', 'complete') == true &&
        census.dig('summary', 'accounted') == census.dig('summary', 'total'),
        'all source objects are completely accounted')
  check(census['objects'].all? do |object|
          TERMINAL.include?(object['status']) &&
            object.keys.count { |key| key == 'status' } == 1 &&
            object['evidence'].is_a?(Array) && !object['evidence'].empty?
        end,
        'every object has exactly one terminal status and evidence')

  statuses = census['objects'].map { |object| object['status'] }.uniq.sort
  check((%w[migrated approximated needs-review skipped not-applicable] - statuses).empty?,
        'realistic fixture produces every terminal status')

  by_name = census['objects'].to_h { |object| [[object['type'], object['name']], object] }
  check(by_name[['dashboard', 'Sales Dashboard']]['status'] == 'migrated',
        'built parity-verified dashboard is migrated')
  check(by_name[['dashboard', 'Archive Dashboard']]['status'] == 'not-applicable',
        'out-of-scope dashboard is not-applicable')
  check(by_name[['worksheet', 'Orphan Sheet']]['status'] == 'not-applicable',
        'orphan/out-of-scope worksheet is not-applicable')
  check(by_name[['worksheet', 'Gauge']]['status'] == 'approximated',
        'coverage approximation overrides built/parity evidence')
  check(by_name[['worksheet', 'Missing Sheet']]['status'] == 'skipped',
        'explicit dropped coverage is skipped, never guessed migrated')
  check(by_name[['calculation', 'Unsupported Calc']]['status'] == 'needs-review',
        'unsupported formula audit remains needs-review')
  check(by_name[['set', 'Top Customers']]['status'] == 'needs-review',
        'unhandled set remains needs-review')
  check(by_name[['parameter', 'Region Parameter']]['status'] == 'migrated',
        'built control with clean census and parity is migrated')
  check(by_name[['parameter', 'Broken Parameter']]['status'] == 'skipped',
        'dropped control is skipped')
  check(by_name[['blend', 'Future Blend: orders + upload']]['status'] == 'needs-review',
        'unmaterialized blend route remains needs-review')

  _stdout2, stderr2, status2 = Open3.capture3(RUBY, SCRIPT, '--workdir', dir)
  check(status2.success?, "auto-discovery invocation succeeds (#{stderr2})")
  check(File.binread(output) == first_bytes, 'output is byte-deterministic across explicit and auto-discovered runs')

  write_json(dir, 'render-health.json', 'status' => 'PASS', 'blank_count' => 0)
  report_stdout, report_stderr, report_status = Open3.capture3(RUBY, REPORT, '--workdir', dir)
  check(report_status.success?,
        "vendored migration report consumes the census without contradiction (#{report_stderr})")
  result = JSON.parse(File.read(File.join(dir, 'migration-result.json')))
  check(result['verdict'] == 'YELLOW' && result.dig('summary', 'complete') == true,
        'mixed terminal statuses produce a complete non-RED migration report')
  check(report_stdout.include?('migration report: YELLOW'),
        'migration report surfaces the accounting verdict')
end

puts
if $failures.empty?
  puts 'ALL PASS'
else
  puts "#{$failures.length} FAILURE(S)"
  $failures.each { |failure| puts "  - #{failure}" }
  exit 1
end
