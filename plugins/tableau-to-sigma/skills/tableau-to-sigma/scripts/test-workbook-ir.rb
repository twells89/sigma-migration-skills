#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'lib/workbook_ir'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

Dir.mktmpdir('workbook-ir-test') do |dir|
  File.write(File.join(dir, 'workbook-content.twb'), '<workbook/>')
  File.write(
    File.join(dir, 'dashboard-layout.json'),
    JSON.generate([
      {
        'dashboard' => 'Overview',
        'canvas_px' => { 'w' => 1200, 'h' => 800 },
        'zones' => [
          {
            'id' => 'zone-1',
            'kind' => 'chart',
            'caption' => 'Revenue by Region',
            'chart_kind' => 'bar',
            'mark_class' => 'Bar',
            'x_pct' => 1.0,
            'y_pct' => 20.0,
            'w_pct' => 48.0,
            'h_pct' => 35.0,
            'filters' => [{ 'column' => 'Region' }]
          }
        ],
        'zone_tree' => [{ 'id' => 'zone-1' }]
      }
    ])
  )
  File.write(
    File.join(dir, 'dashboard-layout-meta.json'),
    JSON.generate(
      'worksheets' => {
        'Revenue by Region' => {
          'mark_class' => 'Bar',
          'rows_shelf' => '[Sales]',
          'cols_shelf' => '[Region]'
        }
      },
      'parameters' => [{ 'name' => 'Date Range' }],
      'shared_filters' => [{ 'column' => 'Region' }]
    )
  )
  File.write(
    File.join(dir, 'chart-provenance.json'),
    JSON.generate(
      'version' => 1,
      'elements' => {
        'chart-revenue' => {
          'worksheet' => 'Revenue by Region',
          'dashboard' => 'Overview'
        }
      }
    )
  )
  File.write(
    File.join(dir, 'coverage.json'),
    JSON.generate(
      'version' => 1,
      'unresolved' => [{ 'visual' => 'Map', 'severity' => 'degraded' }]
    )
  )

  ir_path = File.join(dir, 'workbook-ir.json')
  first = WorkbookIR.emit(dir, out: ir_path)
  first_bytes = File.binread(ir_path)
  second = WorkbookIR.emit(dir, out: ir_path)
  second_bytes = File.binread(ir_path)

  assert(first_bytes == second_bytes, 'IR emission is byte deterministic')
  assert(first == second, 'IR document is deterministic')
  assert(first['kind'] == 'tableau-workbook-ir', 'IR kind')
  assert(first.dig('source', 'sha256').to_s.length == 64, 'TWB hash recorded')
  assert(first.dig('workbook', 'pages', 0, 'zones', 0, 'chart_kind') == 'bar', 'chart kind retained')
  assert(first.dig('workbook', 'worksheets', 'Revenue by Region', 'rows_shelf') == '[Sales]', 'worksheet shelves retained')
  assert(first.dig('workbook', 'parameters', 0, 'name') == 'Date Range', 'parameters retained')
  assert(first.dig('bindings', 0, 'zone_id') == 'zone-1', 'zone-to-element binding derived')
  assert(first.dig('bindings', 0, 'element_id') == 'chart-revenue', 'element binding retained')
  assert(first['unsupported'].length == 1, 'unsupported-feature ledger retained')
  assert(WorkbookIR.validate(first, root: dir).empty?, 'IR validates')
  assert(
    WorkbookIR.artifact_path(ir_path, 'layout', required: true) == File.join(dir, 'dashboard-layout.json'),
    'artifact paths resolve from IR'
  )
end

puts 'PASS: canonical workbook IR'
