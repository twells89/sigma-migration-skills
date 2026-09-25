#!/usr/bin/env ruby
# frozen_string_literal: true

# A Tableau detail list can place many discrete fields on one shelf. Every CSV
# header must become a visible Sigma table column; the chart-oriented two-column
# path is not sufficient for this element kind.
require 'csv'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

DIR = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

dimensions = ['Record ID', 'Owner', 'Category', 'Region', 'Status', 'Updated At']
headers = dimensions + ['Amount', 'SLA Rate']
zone = {
  'id' => 'detail-zone', 'kind' => 'chart', 'caption' => 'Record Detail',
  'chart_kind' => 'table', 'x_pct' => 0.0, 'y_pct' => 0.0,
  'w_pct' => 100.0, 'h_pct' => 100.0,
  'aggregations' => dimensions.to_h { |header| ["[#{header}]", 'None'] }
                              .merge('[AMOUNT_INTERNAL]' => 'Sum', '[SLA_INTERNAL]' => 'User'),
  'rows_shelf' => {
    'raw' => headers.map { |header| "[none:#{header}:nk]" }.join(' / '),
    'fields' => dimensions.map { |header| { 'guid' => header, 'role' => 'dim', 'derivation' => 'none' } } +
                [{ 'guid' => 'AMOUNT_INTERNAL', 'role' => 'measure', 'derivation' => 'sum' },
                 { 'guid' => 'SLA_INTERNAL', 'role' => 'measure', 'derivation' => 'usr' }]
  },
  'cols_shelf' => { 'raw' => '', 'fields' => [] },
  'channels' => {},
  'calculations' => [{
    'name' => '[SLA_INTERNAL]', 'caption' => 'SLA Rate',
    'formula' => 'SUM([Amount])/COUNT([Record ID])'
  }],
  'filters' => []
}
layout = [{ 'dashboard' => 'Operations', 'is_story' => false, 'zones' => [zone] }]
meta = {
  'worksheets' => {}, 'stories' => [], 'shared_filters' => [],
  'column_aliases' => {}, 'parameters' => [],
  'columns_by_guid' => dimensions.to_h do |header|
    [header, { 'caption' => header,
               'datatype' => (header == 'Updated At' ? 'datetime' : 'string'),
               'role' => 'dimension' }]
  end.merge(
    'AMOUNT_INTERNAL' => { 'caption' => 'Amount', 'datatype' => 'real', 'role' => 'measure' },
    'SLA_INTERNAL' => { 'caption' => 'SLA Rate', 'datatype' => 'real', 'role' => 'measure' }
  )
}
mmap = (headers - ['SLA Rate']).to_h do |header|
  ["(?i)^#{Regexp.escape(header)}$",
   { 'id' => "m-#{header.downcase.gsub(/\W+/, '-')}", 'name' => header }]
end

result = {}
log = ''
Dir.mktmpdir do |dir|
  views = File.join(dir, 'views')
  Dir.mkdir(views)
  File.write(File.join(dir, 'layout.json'), JSON.pretty_generate(layout))
  File.write(File.join(dir, 'layout-meta.json'), JSON.pretty_generate(meta))
  File.write(File.join(dir, 'master-map.json'), JSON.pretty_generate(mmap))
  File.write(File.join(dir, 'get-workbook.json'), JSON.pretty_generate(
               'workbook' => { 'views' => { 'view' => [{ 'id' => 'view-wide', 'name' => 'Record Detail' }] } }
             ))
  CSV.open(File.join(views, 'view-wide.csv'), 'w') do |csv|
    csv << headers
    csv << ['R-001', 'A. User', 'Standard', 'West', 'Open', '2026-08-19 09:00:00', '125.50', '1.0']
  end

  out = File.join(dir, 'chart-specs.json')
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, BUILD,
    '--tableau-dir', dir,
    '--layout', File.join(dir, 'layout.json'),
    '--meta', File.join(dir, 'layout-meta.json'),
    '--master-map', File.join(dir, 'master-map.json'),
    '--skip-dashboard-read', 'unit-test',
    '--page-per-dashboard',
    '--out', out
  )
  log = stdout + stderr
  check(status.success?, "builder exits 0 (got #{status.exitstatus})", fails)
  result = JSON.parse(File.read(out)) if status.success? && File.exist?(out)
end

table = Array(result['pages']).flat_map { |page| Array(page['elements']) }
              .find { |element| element['kind'] == 'table' && element['name'] == 'Record Detail' }
columns = Array(table && table['columns'])
grouping = Array(table && table['groupings']).first || {}

check(!table.nil?, 'detail table is emitted', fails)
check(columns.map { |column| column['name'] } == headers,
      'all CSV headers are emitted in source order', fails)
check(grouping['groupBy'] == columns.first(dimensions.length).map { |column| column['id'] },
      'all non-aggregated detail columns participate in grouping', fails)
check(grouping['calculations'] == columns.last(2).map { |column| column && column['id'] },
      'aggregate and calculated measures are grouping calculations', fails)
check(columns[-2] && columns[-2]['formula'] == 'Sum([Master/Amount])',
      'aggregate formula survives beyond the first two CSV headers', fails)
check(columns.last && columns.last['formula'] ==
      'Sum([Master/Amount])/CountIf(IsNotNull([Master/Record ID]))',
      'worksheet calculation referenced by an extra table header is translated', fails)
check(!log.include?('ZONE DROPPED'), 'wide detail table is not dropped', fails)

if fails.empty?
  puts 'test-wide-flat-table: ALL PASS'
else
  puts "test-wide-flat-table: #{fails.size} FAILURE(S)"
  fails.each { |failure| puts "  - #{failure}" }
  exit 1
end
