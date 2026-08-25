#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/tableau_workbook_compiler'
require_relative 'lib/workbook_ir'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

ir = {
  'schemaVersion' => 1,
  'kind' => 'tableau-workbook-ir',
  'source' => { 'type' => 'tableau', 'twb' => 'workbook-content.twb', 'sha256' => 'abc' },
  'artifacts' => {},
  'workbook' => {
    'worksheets' => {},
    'parameters' => [
      { 'name' => 'Metric', 'datatype' => 'string', 'values' => %w[Revenue Profit] },
      { 'name' => 'As Of', 'datatype' => 'date' }
    ],
    'shared_filters' => [],
    'datasource_filters' => [],
    'column_aliases' => {},
    'column_formats' => {},
    'stories' => [],
    'pages' => [
      {
        'name' => 'Overview',
        'layout_index' => 0,
        'emit_page' => true,
        'zones' => [
          {
            'id' => 'z-bar',
            'kind' => 'chart',
            'caption' => 'Revenue by Region',
            'chart_kind' => 'bar',
            'measures' => [{ 'column' => 'Revenue' }],
            'filters' => [{
              'column_caption' => 'Region Friendly',
              'raw_param' => '[federated].[none:Region:nk]',
              'kind' => 'list',
              'members' => %w[East West]
            }],
            'calculations' => [
              { 'caption' => 'Running Revenue', 'formula' => 'RUNNING_SUM(SUM([Revenue]))' }
            ]
          },
          {
            'id' => 'z-combo',
            'kind' => 'chart',
            'caption' => 'Revenue and Margin',
            'chart_kind' => 'line',
            'measures' => [{ 'column' => 'Revenue' }, { 'column' => 'Margin' }],
            'dual_axis' => true,
            'synchronized_axis' => false
          },
          {
            'id' => 'z-pivot',
            'kind' => 'chart',
            'caption' => 'Monthly P&L',
            'chart_kind' => 'table',
            'mark_class' => 'Automatic',
            'rows_shelf' => {
              'fields' => [{ 'role' => 'dim', 'guid' => 'Line Item' }]
            },
            'cols_shelf' => {
              'fields' => [{ 'role' => 'dim', 'guid' => 'Month' }]
            },
            'measures' => [{ 'column' => 'Amount', 'derivation' => 'sum' }]
          },
          {
            'id' => 'z-filter',
            'kind' => 'filter',
            'filter_column_caption' => 'Region Friendly',
            'filter_column_datatype' => 'string'
          },
          {
            'id' => 'z-nav',
            'kind' => 'dashboard-object',
            'caption' => 'Details',
            'button_intent' => 'navigate',
            'button_nav_target' => 'Detail'
          }
        ]
      }
    ]
  },
  'bindings' => [],
  'unsupported' => [],
  'phases' => { 'parse' => true, 'charts' => false, 'assemble' => false, 'layout' => false }
}

plan = TableauWorkbookCompiler.compile(ir)
assert(plan.dig('summary', 'blocking') == 0, 'supported workbook has no blockers')
assert(plan['schemaVersion'] == 2, 'semantic compile plan schema v2')
assert(plan['visuals'].any? { |entry| entry['rule'] == 'viz.bar.v1' && entry['target_kind'] == 'bar-chart' }, 'bar lowering')
assert(plan['visuals'].any? { |entry| entry['rule'] == 'viz.dual-axis-combo.v1' }, 'dual-axis lowering')
bar = plan['visuals'].find { |entry| entry['zone_id'] == 'z-bar' }
assert(bar.dig('bindings', 'values', 0, 'formula') == 'Sum([Master/Revenue])', 'chart value formula bound')
assert(bar.dig('bindings', 'filters', 0, 'column') == 'Region Friendly', 'filter caption wins over raw token')
assert(bar.dig('bindings', 'filters', 0, 'values') == %w[East West], 'filter members retained')
assert(plan['visuals'].any? { |entry| entry['zone_id'] == 'z-pivot' && entry['target_kind'] == 'pivot-table' },
       'Automatic dim-by-dim grid lowers to pivot')
assert(plan['controls'].any? { |entry| entry['name'] == 'Metric' && entry['target_kind'] == 'list-control' }, 'parameter list control')
assert(plan['controls'].any? { |entry| entry['name'] == 'As Of' && entry['target_kind'] == 'date-control' }, 'date control')
assert(plan['controls'].any? { |entry| entry['name'] == 'Region Friendly' }, 'quick-filter uses resolved caption')
assert(plan['formulas'].any? { |entry| entry['recipes']&.include?('formula.running-sum.v1') }, 'table-calc recipe')
assert(plan['formulas'].any? { |entry| entry['sigma_formula']&.include?('CumulativeSum(') },
       'table-calc entry carries concrete Sigma formula')
assert(plan['actions'].any? { |entry| entry['rule'] == 'action.navigation.v1' }, 'navigation action')

blocked_ir = Marshal.load(Marshal.dump(ir))
blocked_ir.dig('workbook', 'pages', 0, 'zones') << {
  'id' => 'z-unknown',
  'kind' => 'chart',
  'caption' => 'Unsupported Viz',
  'chart_kind' => 'radial-tree',
  'measures' => [{ 'column' => 'Revenue' }]
}
blocked_ir.dig('workbook', 'pages', 0, 'zones') << {
  'id' => 'z-unbound',
  'kind' => 'chart',
  'caption' => 'Unbound Viz',
  'chart_kind' => 'bar'
}
blocked_ir.dig('workbook', 'pages', 0, 'zones', 0, 'calculations') << {
  'caption' => 'Selected Set',
  'formula' => '[Region] IN [Top Regions]'
}
blocked_plan = TableauWorkbookCompiler.compile(blocked_ir)
assert(blocked_plan.dig('summary', 'blocking') == 3, 'unknown viz, set membership, and missing bindings block')
assert(blocked_plan['blocking'].any? { |entry| entry['rule'] == 'viz.unknown.v1' }, 'unknown viz named')
assert(blocked_plan['blocking'].any? { |entry| entry['rule'] == 'formula.set-membership.v1' }, 'set membership named')
assert(blocked_plan['blocking'].any? { |entry| entry['rule'] == 'viz.binding-missing.v1' }, 'missing chart bindings named')

Dir.mktmpdir('workbook-compiler-cli') do |dir|
  File.write(File.join(dir, 'workbook-content.twb'), '<workbook/>')
  File.write(File.join(dir, 'dashboard-layout.json'), '[]')
  File.write(File.join(dir, 'dashboard-layout-meta.json'), JSON.generate('worksheets' => {}))
  ir_path = File.join(dir, 'workbook-ir.json')
  WorkbookIR.emit(dir, out: ir_path)

  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby,
    File.join(__dir__, 'compile-workbook-ir.rb'),
    '--ir', ir_path,
    '--strict'
  )
  assert(status.success?, "strict supported CLI failed: #{stdout}\n#{stderr}")
  compile_plan = JSON.parse(File.read(File.join(dir, 'workbook-compile-plan.json')))
  assert(compile_plan['kind'] == 'tableau-workbook-compile-plan', 'CLI writes compile plan')
  refreshed_ir = JSON.parse(File.read(ir_path))
  assert(refreshed_ir.dig('artifacts', 'compile_plan') == 'workbook-compile-plan.json', 'CLI refreshes IR')
end

puts 'PASS: deterministic Tableau workbook lowering compiler'
