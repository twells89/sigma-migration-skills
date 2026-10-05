#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'yaml'

WB_REP = File.join(__dir__, 'wb-rep.rb')
VALIDATOR = File.join(__dir__, 'validate-spec.sh')
failures = []

def check(failures, description)
  if yield
    puts "PASS — #{description}"
  else
    failures << description
    warn "FAIL — #{description}"
  end
end

def base_spec
  {
    'name' => 'workbook semantic lint fixture',
    'folderId' => '00000000-0000-0000-0000-000000000000',
    'document' => {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'pages' => [{ 'id' => 'p1', 'name' => 'Page 1' }],
      'elements' => [
        {
          'id' => 'source',
          'kind' => 'table',
          'name' => 'Source',
          'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'dm-el' },
          'columns' => [
            { 'id' => 'source-region', 'name' => 'Region', 'formula' => '[Model/Region]' },
            { 'id' => 'source-amount', 'name' => 'Amount', 'formula' => '[Model/Amount]' }
          ]
        },
        {
          'id' => 'chart',
          'kind' => 'bar-chart',
          'name' => 'Sales by region',
          'source' => { 'kind' => 'table', 'elementId' => 'source' },
          'columns' => [
            { 'id' => 'chart-region', 'name' => 'Region', 'formula' => '[Source/Region]' },
            { 'id' => 'chart-amount', 'name' => 'Amount', 'formula' => 'Sum([Source/Amount])' }
          ],
          'xAxis' => { 'columnId' => 'chart-region' },
          'yAxis' => { 'columnIds' => ['chart-amount'] }
        }
      ],
      'layout' => <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">
          <Element elementId="source" gridColumn="1 / 13" gridRow="1 / 13"/>
          <Element elementId="chart" gridColumn="13 / 25" gridRow="1 / 13"/>
        </Page>
      XML
    }
  }
end

def element(spec, id)
  spec['document']['elements'].find { |candidate| candidate['id'] == id }
end

def run_with_spec(command, spec)
  Dir.mktmpdir('workbook-lint') do |tmp|
    path = File.join(tmp, 'spec.yaml')
    File.write(path, YAML.dump(spec))
    Open3.capture2e(*command.call(path, tmp))
  end
end

def lint(spec)
  run_with_spec(->(path, _tmp) { ['ruby', WB_REP, 'lint', path] }, spec)
end

def validate(spec)
  run_with_spec(->(path, _tmp) { [VALIDATOR, path] }, spec)
end

out, status = lint(base_spec)
check(failures, 'clean chart pointers pass workbook lint') { status.success? }
warn out unless status.success?

spec = base_spec
element(spec, 'chart')['xAxis'] = { 'columnID' => 'chart-region' }
out, status = lint(spec)
check(failures, 'columnID casing is rejected') do
  !status.success? && out.include?('columnID') && out.include?('columnId')
end

spec = base_spec
element(spec, 'chart')['xAxis'] = { 'id' => 'chart-region' }
out, status = lint(spec)
check(failures, 'legacy id chart pointer is rejected') do
  !status.success? && out.include?('xAxis uses id')
end

spec = base_spec
element(spec, 'chart')['yAxis']['columnIds'] = ['missing-column']
out, status = lint(spec)
check(failures, 'unknown chart axis column is rejected') do
  !status.success? && out.include?('missing-column')
end

spec = base_spec
pivot = element(spec, 'chart')
pivot['kind'] = 'pivot-table'
pivot.delete('xAxis')
pivot.delete('yAxis')
pivot['rowsBy'] = [{ 'id' => 'chart-region' }]
pivot['values'] = ['chart-amount']
out, status = lint(spec)
check(failures, 'legacy pivot shelf id is rejected') do
  !status.success? && out.include?('rowsBy[0] uses id')
end

spec = base_spec
source = element(spec, 'source')
source['columns'] << { 'id' => 'source-total', 'name' => 'Total', 'formula' => 'Sum([Amount])' }
out, status = lint(spec)
check(failures, 'aggregate table without groupings is rejected') do
  !status.success? && out.include?('aggregate columns but no groupings')
end

spec = base_spec
source = element(spec, 'source')
source['groupings'] = [
  { 'id' => 'by-region', 'groupBy' => ['source-region'], 'calculations' => ['source-amount'] }
]
out, status = lint(spec)
check(failures, 'non-aggregate grouping calculation is rejected') do
  !status.success? && out.include?('non-aggregate column')
end

spec = base_spec
source = element(spec, 'source')
source['columns'] << {
  'id' => 'source-total',
  'name' => 'Total',
  'formula' => 'Sum([Amount])'
}
source['columns'][1]['hidden'] = true
source['groupings'] = [
  {
    'id' => 'by-region',
    'groupBy' => ['source-region'],
    'calculations' => ['source-total'],
    'sort' => [{ 'columnId' => 'source-total', 'direction' => 'descending' }]
  }
]
out, status = lint(spec)
check(failures, 'valid grouped table passes lint') { status.success? }
warn out unless status.success?
out, status = validate(spec)
check(failures, 'shell validator accepts valid grouping sort') { status.success? }
warn out unless status.success?

spec = base_spec
source = element(spec, 'source')
source['columns'] << {
  'id' => 'source-total',
  'name' => 'Total',
  'formula' => 'Sum([Amount])'
}
source['groupings'] = [
  { 'id' => 'by-region', 'groupBy' => ['source-region'], 'calculations' => ['source-total'] }
]
out, status = lint(spec)
check(failures, 'visible grouped-table detail columns produce a warning') do
  status.success? && out.include?('grouping warning') && out.include?('source-amount')
end

spec = base_spec
element(spec, 'chart')['xAxis'] = { 'columnID' => 'chart-region' }
out, status = validate(spec)
check(failures, 'shell validator rejects columnID casing') do
  !status.success? && out.include?('columnID') && out.include?('columnId')
end

spec = base_spec
source = element(spec, 'source')
source['columns'] << { 'id' => 'source-total', 'name' => 'Total', 'formula' => 'Sum([Amount])' }
out, status = validate(spec)
check(failures, 'shell validator rejects missing table groupings') do
  !status.success? && out.include?('aggregate columns but no groupings')
end

spec = base_spec
element(spec, 'chart')['xAxis'] = { 'columnID' => 'chart-region' }
out, status = run_with_spec(
  lambda do |path, tmp|
    rep = File.join(tmp, 'rep')
    ['bash', '-c', 'ruby "$1" import "$2" "$3" >/dev/null && ruby "$1" push "$3"', 'test', WB_REP, path, rep]
  end,
  spec
)
check(failures, 'push runs semantic lint before requiring API credentials') do
  !status.success? && out.include?('column pointer validation') && !out.include?('SIGMA_BASE_URL not set')
end

if failures.empty?
  puts "\nAll workbook semantic lint checks passed."
else
  warn "\n#{failures.length} failure(s):"
  failures.each { |failure| warn "  - #{failure}" }
  exit 1
end
