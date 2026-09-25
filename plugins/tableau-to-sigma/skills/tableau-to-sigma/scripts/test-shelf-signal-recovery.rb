#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression coverage for customer workbooks whose shelf field names contain
# slashes, nested quick-calc prefixes, Measure Values, or a text-only KPI.

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'

DIR = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(condition, message, failures)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  failures << message unless condition
end

twb = <<~XML
  <?xml version='1.0' encoding='utf-8'?>
  <workbook>
    <datasources>
      <datasource caption='Master' name='federated.fact'>
        <column caption='Weekly/Monthly Period' name='[Weekly/Monthly Period]' datatype='date' role='dimension' type='ordinal'/>
        <column caption='Measure Value' name='[MEASURE_VALUE]' datatype='real' role='measure' type='quantitative'/>
        <column caption='Metric A' name='[Metric A]' datatype='real' role='measure' type='quantitative'/>
        <column caption='Metric B' name='[Metric B]' datatype='real' role='measure' type='quantitative'/>
        <column caption='Verification Date' name='[VERIFICATION_DATE]' datatype='date' role='dimension' type='ordinal'/>
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Slash Axis'>
        <table><view><datasource-dependencies datasource='federated.fact'>
          <column-instance column='[Weekly/Monthly Period]' derivation='None' name='[none:Weekly/Monthly Period:ok]' pivot='key' type='ordinal'/>
          <column-instance column='[MEASURE_VALUE]' derivation='Sum' name='[sum:MEASURE_VALUE:qk]' pivot='key' type='quantitative'/>
        </datasource-dependencies></view>
        <rows>[federated.fact].[sum:MEASURE_VALUE:qk]</rows>
        <cols>[federated.fact].[none:Weekly/Monthly Period:ok]</cols>
        <pane><mark class='Automatic'/></pane></table>
      </worksheet>
      <worksheet name='Quick Share'>
        <table><view><datasource-dependencies datasource='federated.fact'>
          <column-instance column='[Weekly/Monthly Period]' derivation='None' name='[none:Weekly/Monthly Period:ok]' pivot='key' type='ordinal'/>
          <column-instance column='[MEASURE_VALUE]' derivation='Sum' name='[pcto:sum:MEASURE_VALUE:qk:2]' pivot='key' type='quantitative'/>
        </datasource-dependencies></view>
        <rows>[federated.fact].[pcto:sum:MEASURE_VALUE:qk:2]</rows>
        <cols>[federated.fact].[none:Weekly/Monthly Period:ok]</cols>
        <pane><mark class='Area'/></pane></table>
      </worksheet>
      <worksheet name='Measure Values'>
        <table><view><datasource-dependencies datasource='federated.fact'>
          <column-instance column='[Weekly/Monthly Period]' derivation='None' name='[none:Weekly/Monthly Period:ok]' pivot='key' type='ordinal'/>
          <column-instance column='[Metric A]' derivation='Sum' name='[sum:Metric A:qk]' pivot='key' type='quantitative'/>
          <column-instance column='[Metric B]' derivation='Sum' name='[sum:Metric B:qk]' pivot='key' type='quantitative'/>
        </datasource-dependencies></view>
        <rows>[federated.fact].[Multiple Values]</rows>
        <cols>[federated.fact].[none:Weekly/Monthly Period:ok]</cols>
        <pane><mark class='Automatic'/></pane></table>
      </worksheet>
      <worksheet name='Data Until'>
        <table><view><datasource-dependencies datasource='federated.fact'>
          <column-instance column='[VERIFICATION_DATE]' derivation='Max' name='[max:VERIFICATION_DATE:ok]' pivot='key' type='ordinal'/>
        </datasource-dependencies></view>
        <rows></rows><cols></cols>
        <pane><mark class='Automatic'/><encodings><text column='[federated.fact].[max:VERIFICATION_DATE:ok]'/></encodings></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards><dashboard name='Dash'><zones>
      <zone id='1' name='Slash Axis' x='0' y='0' w='50000' h='25000'/>
      <zone id='2' name='Quick Share' x='50000' y='0' w='50000' h='25000'/>
      <zone id='3' name='Measure Values' x='0' y='25000' w='100000' h='50000'/>
      <zone id='4' name='Data Until' x='0' y='75000' w='100000' h='25000'/>
    </zones></dashboard></dashboards>
  </workbook>
XML

master_map = {
  '(?i)^Weekly/Monthly Period$' => { 'id' => 'm-period', 'name' => 'Weekly/Monthly Period' },
  '(?i)^Measure Value$' => { 'id' => 'm-value', 'name' => 'Measure Value' },
  '(?i)^Metric A$' => { 'id' => 'm-a', 'name' => 'Metric A' },
  '(?i)^Metric B$' => { 'id' => 'm-b', 'name' => 'Metric B' },
  '(?i)^Verification Date$' => { 'id' => 'm-date', 'name' => 'Verification Date' }
}

elements = []
coverage = {}
log = ''
Dir.mktmpdir do |dir|
  twb_path = File.join(dir, 'source.twb')
  layout_path = File.join(dir, 'layout.json')
  map_path = File.join(dir, 'master-map.json')
  File.write(twb_path, twb)
  File.write(map_path, JSON.generate(master_map))
  parser_ok = system(RbConfig.ruby, PARSER, twb_path, layout_path, out: File::NULL, err: File::NULL)
  check(parser_ok, 'parser accepts slash/nested-prefix shelf tokens', fails)
  parsed = parser_ok ? JSON.parse(File.read(layout_path)) : []
  zones = parsed.flat_map { |dashboard| dashboard['zones'] || [] }.select { |zone| zone['kind'] == 'chart' }
  slash = zones.find { |zone| zone['caption'] == 'Slash Axis' }
  quick = zones.find { |zone| zone['caption'] == 'Quick Share' }
  until_zone = zones.find { |zone| zone['caption'] == 'Data Until' }
  check(slash&.dig('cols_shelf', 'fields', 0, 'guid') == 'Weekly/Monthly Period',
        'slash inside field name does not split the shelf pill', fails)
  check(quick&.dig('rows_shelf', 'fields', 0, 'guid') == 'MEASURE_VALUE',
        'nested pcto:sum prefix resolves the underlying field', fails)
  check(until_zone && until_zone['is_kpi'] && until_zone['chart_kind'] == 'kpi',
        'text-only MAX(date) worksheet is classified as a KPI', fails)

  File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))
  FileUtils.mkdir_p(File.join(dir, 'views'))
  File.write(File.join(dir, 'png-read.json'), JSON.generate(
    'source_png' => 'source.png',
    'tiles' => zones.map { |zone| { 'title' => zone['caption'], 'kind' => "#{zone['chart_kind']}-chart" } },
    'text_elements' => [], 'filter_shelf' => []
  ))
  out_path = File.join(dir, 'chart-specs.json')
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, BUILD,
    '--tableau-dir', dir, '--layout', layout_path,
    '--meta', layout_path.sub(/\.json$/, '-meta.json'),
    '--master-map', map_path, '--master-element-id', 'master',
    '--page-per-dashboard', '--out', out_path
  )
  log = stdout + stderr
  check(status.success?, "builder exits cleanly (#{stderr.lines.first})", fails)
  built = JSON.parse(File.read(out_path)) rescue {}
  elements = (built['pages'] || []).flat_map { |page| page['elements'] || [] }
  coverage = JSON.parse(File.read(File.join(dir, 'coverage.json'))) rescue {}
end

%w[Slash\ Axis Quick\ Share Measure\ Values Data\ Until].each do |name|
  check(elements.any? { |element| element['name'].to_s.casecmp?(name) },
        "#{name.inspect} is built instead of dropped", fails)
end
measure_values = elements.find { |element| element['name'].to_s.casecmp?('Measure Values') }
check(Array(measure_values&.dig('yAxis', 'columnIds')).length == 2,
      'Measure Values worksheet emits both ordered measures', fails)
check(!log.include?('ZONE DROPPED'), 'no source worksheet is silently dropped', fails)
check(coverage.dig('summary', 'sourceVisuals') == 4 &&
      coverage.dig('summary', 'builtChartElements') == 4,
      "coverage counts source chart zones, not incidental elements (got #{coverage['summary'].inspect})", fails)

if fails.empty?
  puts 'ALL PASS — slash, quick-calc, Measure Values, and text-KPI signals recover'
else
  warn "#{fails.length} failure(s): #{fails.join('; ')}"
  exit 1
end
