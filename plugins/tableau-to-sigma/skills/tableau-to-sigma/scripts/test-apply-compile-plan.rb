#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/compile_plan_apply'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

plan = {
  'visuals' => [{
    'key' => 'plan-pivot',
    'dashboard' => 'Overview',
    'zone_id' => 'z1',
    'source_name' => 'Monthly P&L',
    'status' => 'lowered',
    'target_kind' => 'pivot-table',
    'rule' => 'viz.pivot.v1',
    'bindings' => {
      'filters' => [{
        'column' => 'Record Type',
        'kind' => 'list',
        'mode' => 'include',
        'values' => ['P&L']
      }]
    }
  }]
}
index = CompilePlanApply.index(plan)
zone = {
  'id' => 'z1',
  'caption' => 'Monthly P&L',
  'chart_kind' => 'table',
  'filters' => []
}
entry = CompilePlanApply.apply_zone!(zone, 'Overview', index)

assert(entry['key'] == 'plan-pivot', 'zone resolves to compile-plan entry')
assert(zone['chart_kind'] == 'pivot-table', 'plan target forces shared pivot emitter')
assert(zone['is_crosstab'] == true, 'pivot plan marks crosstab semantics')
assert(zone['_compile_plan_key'] == 'plan-pivot', 'zone carries plan provenance')
assert(zone.dig('filters', 0, 'column_caption') == 'Record Type', 'planned filter applied')
assert(zone.dig('filters', 0, 'members') == ['P&L'], 'planned filter values applied')

puts 'PASS: compile plan drives shared emitter inputs'
