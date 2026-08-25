#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/derive_pipeline_map'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

donor = {
  'document' => {
    'schemaVersion' => 1, 'kind' => 'workbook',
    'pages' => [{ 'id' => 'model', 'name' => 'Model (sources)' }],
    'elements' => [
      {
        'id' => 'actuals', 'kind' => 'table', 'name' => 'Actuals', 'visibleAsSource' => false,
        'columns' => [
          { 'id' => 'a1', 'name' => 'Amount' },
          { 'id' => 'a2', 'name' => 'Period' },
          { 'id' => 'a3', 'name' => 'Vendor Memo' }
        ]
      },
      {
        'id' => 'combined', 'kind' => 'table', 'name' => 'Combined', 'visibleAsSource' => false,
        'source' => { 'kind' => 'union', 'sources' => [{ 'kind' => 'table', 'elementId' => 'actuals' }] },
        'columns' => [{ 'id' => 'c1', 'name' => 'Amount' }, { 'id' => 'c2', 'name' => 'Period' }]
      }
    ],
    'layout' => "<?xml version=\"1.0\"?><Page id=\"model\"><Element elementId=\"actuals\"/><Element elementId=\"combined\"/></Page>"
  }
}
generated = {
  'schemaVersion' => 1, 'name' => 'Generated',
  'pages' => [
    {
      'id' => 'data', 'name' => 'Data',
      'elements' => [{
        'id' => 'master-overview', 'kind' => 'table', 'name' => 'Master',
        'columns' => [
          { 'id' => 'm1', 'name' => 'Amount' },
          { 'id' => 'm2', 'name' => 'Period Type' },
          { 'id' => 'm3', 'name' => 'Memo' }
        ]
      }]
    },
    {
      'id' => 'overview', 'name' => 'Overview',
      'elements' => [{
        'id' => 'chart', 'kind' => 'bar-chart', 'name' => 'Revenue',
        'source' => { 'kind' => 'table', 'elementId' => 'master-overview' },
        'columns' => []
      }]
    }
  ]
}
ir = {
  'workbook' => {
    'pages' => [{
      'name' => 'Overview',
      'zones' => [{
        'rows_shelf' => { 'fields' => [{ 'role' => 'dim', 'guid' => 'Period Type' }] },
        'measures' => [{ 'column' => 'Amount' }],
        'filters' => [{ 'column_caption' => 'Memo' }]
      }]
    }]
  }
}

plan = DerivePipelineMap.derive(
  ir: ir,
  generated_spec: generated,
  donor_spec: donor,
  template_workbook_id: 'donor-id'
)
master = plan['master_sources']['master-overview']

assert(plan['pipeline_pages'].length == 1, 'donor pipeline page discovered')
assert(master.dig('source', 'elementId') == 'actuals', 'best field-coverage pipeline root selected')
assert(master.dig('fields', 'Amount') == '[Actuals/Amount]', 'exact field mapping executable')
assert(master.dig('fields', 'Period Type', 'formula') == '[Actuals/Period]', 'alias field mapping drafted')
assert(master.dig('fields', 'Memo', 'formula') == '[Actuals/Vendor Memo]', 'token alias mapping drafted')
assert(plan['review_required'].length == 2, 'non-exact aliases require review')
assert(plan['status'] == 'draft-review-required', 'draft cannot auto-apply without review')

puts 'PASS: pipeline map derivation'
