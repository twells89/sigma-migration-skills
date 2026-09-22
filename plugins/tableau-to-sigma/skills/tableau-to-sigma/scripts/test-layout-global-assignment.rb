#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration regression: the live workbook spec may keep an element in the
# document-global `elements` array while stale layout XML assigns it to the
# wrong page. build-dashboard-layout must recover page ownership from chart
# provenance before its page-local matching and zero-drop census run.

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

SCRIPT = File.join(__dir__, 'build-dashboard-layout.rb')

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

zone = lambda do |id, caption|
  {
    'id' => id,
    'kind' => 'chart',
    'caption' => caption,
    'x_pct' => 0,
    'y_pct' => 0,
    'w_pct' => 100,
    'h_pct' => 100,
    'measures' => ['Value'],
    'rows_shelf' => { 'dim_count' => 1 },
    'cols_shelf' => { 'measure_count' => 1 }
  }
end

Dir.mktmpdir do |dir|
  dashboards = [
    {
      'dashboard' => 'Summary',
      'zones' => [zone.call('zone-summary', 'Summary Sales')],
      'zone_tree' => [zone.call('zone-summary', 'Summary Sales')]
    },
    {
      'dashboard' => 'Operations',
      'zones' => [zone.call('zone-volume', 'Source Volume')],
      'zone_tree' => [zone.call('zone-volume', 'Source Volume')]
    }
  ]
  workbook = {
    'workbookId' => 'wb-neutral',
    'latestDocumentVersion' => '7',
    'document' => {
      'schemaVersion' => 4,
      'kind' => 'workbook',
      'pages' => [
        { 'id' => 'page-data', 'name' => 'Data' },
        { 'id' => 'page-summary', 'name' => 'Summary' },
        { 'id' => 'page-operations', 'name' => 'Operations' }
      ],
      'elements' => [
        {
          'id' => 'master',
          'kind' => 'table',
          'name' => 'Data',
          'visibleAsSource' => false,
          'source' => { 'kind' => 'data-model' }
        },
        {
          'id' => 'el-summary-sales',
          'kind' => 'bar-chart',
          'name' => 'Summary Sales',
          'source' => { 'kind' => 'table', 'elementId' => 'master' }
        },
        {
          'id' => 'el-volume',
          'kind' => 'line-chart',
          'name' => 'Volume',
          'source' => { 'kind' => 'table', 'elementId' => 'master' }
        }
      ],
      # Stale ownership: el-volume is on Summary instead of Operations.
      'layout' => '<Page id="page-data"><Element elementId="master"/></Page>' \
                  '<Page id="page-summary"><Element elementId="el-summary-sales"/>' \
                  '<Element elementId="el-volume"/></Page>' \
                  '<Page id="page-operations"></Page>'
    }
  }

  layout_path = File.join(dir, 'dashboard-layout.json')
  workbook_path = File.join(dir, 'wb-readback.json')
  output_path = File.join(dir, 'layout.xml')
  File.write(layout_path, JSON.pretty_generate(dashboards))
  File.write(workbook_path, JSON.pretty_generate(workbook))
  File.write(File.join(dir, 'chart-provenance.json'), JSON.pretty_generate(
    'version' => 1,
    'elements' => {
      'el-summary-sales' => { 'worksheet' => 'Summary Sales', 'dashboard' => 'Summary' },
      'el-volume' => { 'worksheet' => 'Source Volume', 'dashboard' => 'Operations' }
    }
  ))

  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, SCRIPT,
    '--layout', layout_path,
    '--wb-ids', workbook_path,
    '--out', output_path,
    '--no-synthetic-title'
  )
  check.call(status.success?, "layout rebuild succeeds (exit #{status.exitstatus}: #{stderr.lines.last})")
  if File.exist?(output_path)
    xml = File.read(output_path)
    summary_body = xml[/<Page\b[^>]*id="page-summary"[^>]*>(.*?)<\/Page>/m, 1].to_s
    operations_body = xml[/<Page\b[^>]*id="page-operations"[^>]*>(.*?)<\/Page>/m, 1].to_s
    check.call(!summary_body.include?('el-volume'),
               'stale page no longer places the globally-owned chart')
    check.call(operations_body.scan(/elementId="el-volume"/).length == 1,
               'source dashboard places the recovered chart exactly once')
  else
    check.call(false, 'layout XML was produced')
  end

  census_path = File.join(dir, 'layout-census.json')
  census = File.exist?(census_path) ? JSON.parse(File.read(census_path)) : {}
  moved = census.dig('element_assignment', 'moved') || []
  check.call(moved.any? { |record| record['element_id'] == 'el-volume' &&
                                  record['to_page_id'] == 'page-operations' },
             'layout census records the cross-page reassignment')
  check.call(Array(census['pages']).all? { |page| page['dropped'].to_i.zero? },
             'zero-dropped-zones invariant holds after reassignment')
  check.call(stdout.include?('2 dashboard page(s)'),
             'both source dashboards are rebuilt')
end

# A real source data tile with no global element match must block publication
# before a partial layout can be PUT.
Dir.mktmpdir do |dir|
  dashboards = [{
    'dashboard' => 'Operations',
    'zones' => [zone.call('zone-missing', 'Missing Source Tile')],
    'zone_tree' => [zone.call('zone-missing', 'Missing Source Tile')]
  }]
  workbook = {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [
      { 'id' => 'page-data', 'name' => 'Data' },
      { 'id' => 'page-operations', 'name' => 'Operations' }
    ],
    'elements' => [
      { 'id' => 'master', 'kind' => 'table', 'name' => 'Data', 'visibleAsSource' => false }
    ],
    'layout' => '<Page id="page-data"><Element elementId="master"/></Page>' \
                '<Page id="page-operations"></Page>'
  }
  layout_path = File.join(dir, 'dashboard-layout.json')
  workbook_path = File.join(dir, 'wb-readback.json')
  output_path = File.join(dir, 'layout.xml')
  File.write(layout_path, JSON.pretty_generate(dashboards))
  File.write(workbook_path, JSON.pretty_generate(workbook))
  _stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, SCRIPT,
    '--layout', layout_path,
    '--wb-ids', workbook_path,
    '--out', output_path,
    '--no-synthetic-title'
  )
  check.call(!status.success? && stderr.include?('generated layout dropped source data tile'),
             'unmatched source data tile fails the layout build')
  check.call(!File.exist?(output_path),
             'failed zero-drop gate does not publish partial layout XML')
  census = JSON.parse(File.read(File.join(dir, 'layout-census.json')))
  check.call(census['pages'].first['dropped'] == 1,
             'failure census names the dropped source tile count')
end

puts
if fails.empty?
  puts 'ALL PASS — document-global chart ownership is recovered before page layout'
  exit 0
end

puts "FAILURES (#{fails.length}):"
fails.each { |failure| puts "  - #{failure}" }
exit 1
