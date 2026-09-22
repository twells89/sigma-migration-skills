#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression: Tableau may expose only a dashboard-level CSV while every chart
# worksheet is embedded. That CSV is not a per-chart value oracle and must not
# suppress the anchors+warehouse route merely because views/*.csv is non-empty.

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/zone_census'

SCRIPT = File.join(__dir__, 'auto-parity-plan.rb')

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

def stage_fixture(dir, extra_worksheet_csv: false)
  views = [{ 'id' => 'dashboard-view', 'name' => 'Operations Dashboard' }]
  if extra_worksheet_csv
    views << { 'id' => 'unmatched-sheet', 'name' => 'Other Worksheet' }
  end
  File.write(File.join(dir, 'get-workbook.json'),
             JSON.generate('views' => { 'view' => views }))
  views_dir = File.join(dir, 'views')
  Dir.mkdir(views_dir)
  File.write(File.join(views_dir, 'dashboard-view.csv'), "Composite\nnot-a-chart-oracle\n")
  if extra_worksheet_csv
    File.write(File.join(views_dir, 'unmatched-sheet.csv'), "Region,Value\nEast,10\n")
  end
  File.write(File.join(dir, 'chart-provenance.json'), JSON.generate(
    'version' => 1,
    'elements' => {
      'el-volume' => {
        'worksheet' => 'Embedded Volume',
        'dashboard' => 'Operations Dashboard',
        'name' => 'Volume'
      }
    }
  ))
  File.write(File.join(dir, 'layout-renames.json'), JSON.generate(
    'Embedded Latency' => 'REBUILT Latency'
  ))
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate([
    {
      'dashboard' => 'Operations Dashboard',
      'zones' => [
        {
          'kind' => 'chart',
          'caption' => 'Embedded Volume',
          'measures' => ['Volume'],
          'rows_shelf' => { 'dim_count' => 1 },
          'cols_shelf' => { 'measure_count' => 1 }
        },
        {
          'kind' => 'chart',
          'caption' => 'Embedded Latency',
          'measures' => ['Latency'],
          'rows_shelf' => { 'dim_count' => 1 },
          'cols_shelf' => { 'measure_count' => 1 }
        }
      ]
    }
  ]))
  File.write(File.join(dir, 'wb.json'), JSON.generate(
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'page-data', 'name' => 'Data' },
                { 'id' => 'page-dashboard', 'name' => 'Operations Dashboard' }],
    'elements' => [
      {
        'id' => 'master',
        'kind' => 'table',
        'visibleAsSource' => false,
        'source' => { 'kind' => 'data-model' }
      },
      {
        'id' => 'el-volume',
        'kind' => 'bar-chart',
        'name' => 'Volume',
        'source' => { 'kind' => 'table', 'elementId' => 'master' },
        'columns' => [
          { 'id' => 'x-period', 'name' => 'Period' },
          { 'id' => 'y-volume', 'name' => 'Volume' }
        ],
        'xAxis' => { 'columnId' => 'x-period' },
        'yAxis' => { 'columnIds' => ['y-volume'] }
      },
      {
        'id' => 'helper-latency',
        'kind' => 'table',
        'name' => 'Latency Grain',
        # Deliberately omit visibleAsSource:false: live readback may strip it.
        'source' => { 'kind' => 'data-model' },
        'columns' => [{ 'id' => 'helper-latency-value', 'name' => 'Latency' }]
      },
      {
        'id' => 'el-rebuilt-latency',
        'kind' => 'line-chart',
        'name' => 'REBUILT Latency',
        'source' => { 'kind' => 'table', 'elementId' => 'helper-latency' },
        'columns' => [
          { 'id' => 'x-period-2', 'name' => 'Period' },
          { 'id' => 'y-latency', 'name' => 'Latency' }
        ],
        'xAxis' => { 'columnId' => 'x-period-2' },
        'yAxis' => { 'columnIds' => ['y-latency'] }
      }
    ],
    'layout' => '<Page id="page-data"><Element elementId="master"/>' \
                '<Element elementId="helper-latency"/></Page>' \
                '<Page id="page-dashboard"><Element elementId="el-volume"/>' \
                '<Element elementId="el-rebuilt-latency"/></Page>'
  ))
end

def run_plan(dir)
  out = File.join(dir, 'parity-plan.json')
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, SCRIPT,
    '--tableau', dir,
    '--workbook-spec', File.join(dir, 'wb.json'),
    '--out', out,
    '--workbook-id', 'wb-test',
    '--dashboard', 'Operations Dashboard'
  )
  [File.exist?(out) ? JSON.parse(File.read(out)) : nil, stdout + stderr, status]
end

Dir.mktmpdir do |dir|
  stage_fixture(dir)
  plan, log, status = run_plan(dir)
  check.call(status.success?, "dashboard-only CSV selects the oracle route (exit #{status.exitstatus})")
  check.call(plan && plan['charts'] == [], 'no expected:null chart stubs are emitted')
  check.call(plan && plan['chart_inventory'].map { |chart| chart['sigma_element_id'] }.sort ==
               %w[el-rebuilt-latency el-volume],
             'composite route retains a structural inventory for every built tile')
  rebuilt = plan && plan['chart_inventory'].find { |chart| chart['sigma_element_id'] == 'el-rebuilt-latency' }
  check.call(rebuilt && rebuilt['tableau_view'] == 'Embedded Latency' && rebuilt['matched_via'] == 'rename',
             'persisted layout rename maps a reconstructed tile back to its source zone')
  check.call(log.include?('helper-latency'),
             'chart-referenced data-model helper is detected even when readback drops visibleAsSource:false')
  layout = JSON.parse(File.read(File.join(dir, 'dashboard-layout.json')))
  census = plan && ZoneCensus.tile_census(layout, plan['chart_inventory'], ['Operations Dashboard'])
  check.call(census && census['zones_total'] == 2 && census['zones_unmatched'].zero?,
             'tile census consumes the structural inventory instead of reporting false 0/N')
  check.call(plan && plan['workbook_id'] == 'wb-test',
             'top-level workbook id survives a zero-chart plan')
  check.call(plan && plan['oracle_mode'] == 'anchors-warehouse',
             'plan explicitly records the anchors+warehouse oracle')
  check.call(plan && plan['dashboard_csv_views'] == ['Operations Dashboard'],
             'dashboard-level CSV is classified separately from worksheet CSVs')
  check.call(plan && plan['worksheet_csv_views'] == [],
             'zero usable worksheet CSVs are recorded')
  check.call(log.include?('MCP is optional') && log.include?('anchors + warehouse'),
             'operator guidance names the no-MCP route')
  check.call(!log.include?('100.0%') && !log.include?('0/0'),
             'planner does not report vacuous parity')
end

Dir.mktmpdir do |dir|
  stage_fixture(dir, extra_worksheet_csv: true)
  plan, log, status = run_plan(dir)
  check.call(!status.success?, 'an unmatched worksheet CSV fails closed instead of hiding as composite')
  check.call(plan.nil?, 'failed rename/provenance matching does not write a partial plan')
  check.call(log.include?('worksheet CSV'), 'failure identifies the unmatched worksheet-CSV class')
end

puts
if fails.empty?
  puts 'ALL PASS — composite dashboards route to anchors+warehouse without MCP or vacuous stubs'
  exit 0
end

puts "FAILURES (#{fails.length}):"
fails.each { |failure| puts "  - #{failure}" }
exit 1
