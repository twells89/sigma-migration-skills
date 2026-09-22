#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/dashboard_element_assignment'

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

data_page = {
  'id' => 'page-data',
  'name' => 'Data',
  'elements' => [
    { 'id' => 'master', 'kind' => 'table', 'visibleAsSource' => false }
  ]
}
summary_page = {
  'id' => 'page-summary',
  'name' => 'Summary',
  'elements' => [
    {
      'id' => 'el-volume',
      'kind' => 'bar-chart',
      'name' => 'Volume',
      'source' => { 'kind' => 'table', 'elementId' => 'master' }
    }
  ]
}
operations_page = {
  'id' => 'page-operations',
  'name' => 'Operations',
  'elements' => [
    {
      'id' => 'el-reconstructed-latency',
      'kind' => 'line-chart',
      'name' => 'REBUILT Latency Trend',
      'source' => { 'kind' => 'table', 'elementId' => 'master' }
    }
  ]
}
pages = [data_page, summary_page, operations_page]
all_elements = pages.flat_map { |page| page['elements'] }
dashboards = [
  {
    'dashboard' => 'Operations',
    'zones' => [
      { 'kind' => 'chart', 'caption' => 'Source Volume' },
      { 'kind' => 'chart', 'caption' => 'Source Latency' }
    ]
  }
]
page_map = { 'Operations' => operations_page }
provenance = {
  'el-volume' => {
    'worksheet' => 'Source Volume',
    'dashboard' => 'Operations',
    'name' => 'Volume'
  }
}
renames = { 'Source Latency' => 'REBUILT Latency Trend' }

result = DashboardElementAssignment.reconcile!(
  legacy_pages: pages,
  dashboards: dashboards,
  page_for_dashboard: page_map,
  all_elements: all_elements,
  provenance: provenance,
  renames: renames
)

check.call(result['ambiguous'].empty? && result['conflicts'].empty?,
           'global assignment is unambiguous')
check.call(result['unmatched'].empty?, 'provenance and rename mappings resolve every chart zone')
check.call(result['moved'].map { |record| record['element_id'] } == ['el-volume'],
           'provenance rehomes a chart from the stale page')
check.call(result['retained'].map { |record| record['element_id'] } == ['el-reconstructed-latency'],
           'rename mapping retains a reconstructed chart already on the target page')
check.call(summary_page['elements'].empty?, 'stale source page no longer owns the moved chart')
check.call(operations_page['elements'].map { |element| element['id'] }.sort ==
             %w[el-reconstructed-latency el-volume],
           'target dashboard page owns both source-matched charts')
check.call(data_page['elements'].map { |element| element['id'] } == ['master'],
           'hidden data-page master is never reassigned')

# Two source dashboards cannot share one document-global element. The builder
# must report the conflict rather than duplicate the id across page layouts.
page_a = { 'id' => 'page-a', 'name' => 'A', 'elements' => [] }
page_b = { 'id' => 'page-b', 'name' => 'B', 'elements' => [] }
shared = { 'id' => 'el-shared', 'kind' => 'bar-chart', 'name' => 'Shared Tile' }
conflict = DashboardElementAssignment.reconcile!(
  legacy_pages: [page_a, page_b],
  dashboards: [
    { 'dashboard' => 'A', 'zones' => [{ 'kind' => 'chart', 'caption' => 'Shared Tile' }] },
    { 'dashboard' => 'B', 'zones' => [{ 'kind' => 'chart', 'caption' => 'Shared Tile' }] }
  ],
  page_for_dashboard: { 'A' => page_a, 'B' => page_b },
  all_elements: [shared]
)
check.call(conflict['conflicts'].length == 1,
           'one global element requested by two pages is reported as a conflict')
check.call(page_a['elements'].map { |element| element['id'] } == ['el-shared'] &&
             page_b['elements'].empty?,
           'conflicted element is placed once, never duplicated')

# Reused display titles across dashboards are common. Existing page ownership
# is the deterministic tie-breaker when no provenance record disambiguates.
page_left = {
  'id' => 'page-left',
  'name' => 'Left',
  'elements' => [{ 'id' => 'el-left-trend', 'kind' => 'line-chart', 'name' => 'Trend' }]
}
page_right = {
  'id' => 'page-right',
  'name' => 'Right',
  'elements' => [{ 'id' => 'el-right-trend', 'kind' => 'line-chart', 'name' => 'Trend' }]
}
same_name = DashboardElementAssignment.reconcile!(
  legacy_pages: [page_left, page_right],
  dashboards: [
    { 'dashboard' => 'Left', 'zones' => [{ 'kind' => 'chart', 'caption' => 'Trend' }] },
    { 'dashboard' => 'Right', 'zones' => [{ 'kind' => 'chart', 'caption' => 'Trend' }] }
  ],
  page_for_dashboard: { 'Left' => page_left, 'Right' => page_right },
  all_elements: page_left['elements'] + page_right['elements']
)
check.call(same_name['ambiguous'].empty? && same_name['conflicts'].empty?,
           'same display title on two dashboards is disambiguated by current page ownership')
check.call(page_left['elements'].first['id'] == 'el-left-trend' &&
             page_right['elements'].first['id'] == 'el-right-trend',
           'same-name charts retain their distinct page-local elements')

puts
if fails.empty?
  puts 'ALL PASS — global charts are reassigned by provenance/renames without duplicate placement'
  exit 0
end

puts "FAILURES (#{fails.length}):"
fails.each { |failure| puts "  - #{failure}" }
exit 1
