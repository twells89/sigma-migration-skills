#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/compile_plan_reconcile'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

plan = {
  'visuals' => [{
    'key' => 'p1', 'status' => 'lowered', 'target_kind' => 'bar-chart'
  }],
  'controls' => [{
    'key' => 'c1', 'status' => 'lowered', 'name' => 'Region'
  }]
}
charts = {
  'pages' => [{
    'elements' => [
      { 'id' => 'bar-1', 'kind' => 'bar-chart', 'name' => 'Revenue' },
      { 'id' => 'control-1', 'kind' => 'control', 'name' => 'Region' }
    ]
  }]
}
provenance = {
  'elements' => {
    'bar-1' => { 'compile_plan_key' => 'p1' }
  }
}
coverage = { 'summary' => { 'dropped' => 0 } }

result = CompilePlanReconcile.reconcile(
  plan: plan, chart_specs: charts, provenance: provenance, coverage: coverage
)
assert(result['status'] == 'PASS', 'matching plan/build passes')

missing = CompilePlanReconcile.reconcile(
  plan: plan,
  chart_specs: { 'pages' => [{ 'elements' => [{ 'id' => 'bar-1', 'kind' => 'bar-chart' }] }] },
  provenance: { 'elements' => {} },
  coverage: { 'summary' => { 'dropped' => 1 } }
)
assert(missing['status'] == 'FAIL', 'missing provenance/control and dropped coverage fail')
assert(missing['unmatched_plan_keys'] == ['p1'], 'missing planned chart named')
assert(missing['unexplained_builds'] == ['bar-1'], 'unexplained build named')
assert(missing['missing_controls'] == ['Region'], 'missing control named')

puts 'PASS: compile plan reconciliation'
