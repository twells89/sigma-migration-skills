#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'lib/workbook_pipeline_reuse'

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

donor = {
  'name' => 'Donor',
  'document' => {
    'schemaVersion' => 1,
    'kind' => 'workbook',
    'pages' => [
      { 'id' => 'p-data', 'name' => 'Data', 'visibility' => 'hidden' }
    ],
    'elements' => [
      {
        'id' => 'actuals', 'kind' => 'table', 'name' => 'Actuals',
        'visibleAsSource' => false,
        'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'actual-el' },
        'columns' => [{ 'id' => 'a1', 'name' => 'Amount', 'formula' => '[Custom SQL/Amount]' }],
        'order' => ['a1']
      },
      {
        'id' => 'combined', 'kind' => 'table', 'name' => 'Combined',
        'visibleAsSource' => false,
        'source' => {
          'kind' => 'union',
          'sources' => [{ 'kind' => 'table', 'elementId' => 'actuals' }],
          'matches' => [{ 'outputColumnName' => 'Amount', 'sourceColumns' => ['[Amount]'] }]
        },
        'columns' => [{ 'id' => 'c1', 'name' => 'Amount', 'formula' => '[Union of 1 Sources/Amount]' }],
        'order' => ['c1']
      }
    ],
    'layout' => "<?xml version=\"1.0\"?><Page id=\"p-data\"><Element elementId=\"actuals\"/><Element elementId=\"combined\"/></Page>"
  }
}

generated = {
  'name' => 'Generated',
  'schemaVersion' => 1,
  'pages' => [
    {
      'id' => 'data', 'name' => 'Data',
      'elements' => [{
        'id' => 'master-overview', 'kind' => 'table', 'name' => 'Master',
        'visibleAsSource' => false,
        'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm', 'elementId' => 'wrong' },
        'columns' => [
          { 'id' => 'm1', 'name' => 'Record Type', 'formula' => '[Custom SQL/Record Type]' },
          { 'id' => 'm2', 'name' => 'Amount', 'formula' => '[Custom SQL/Amount]' }
        ],
        'order' => %w[m1 m2]
      }]
    },
    {
      'id' => 'overview', 'name' => 'Overview',
      'elements' => [{
        'id' => 'kpi', 'kind' => 'kpi-chart', 'name' => { 'text' => 'Revenue' },
        'source' => { 'kind' => 'table', 'elementId' => 'master-overview' },
        'columns' => [{ 'id' => 'k1', 'name' => 'Amount', 'formula' => '[Metrics/Total Amount]' }]
      }]
    }
  ]
}

plan = {
  'template_workbook_id' => 'donor-id',
  'pipeline_pages' => [
    {
      'id' => 'data', 'name' => 'Pipeline Data', 'visibility' => 'hidden',
      'retain_existing' => false, 'element_ids' => %w[actuals]
    },
    {
      'id' => 'derived', 'name' => 'Derived Data', 'visibility' => 'hidden',
      'element_ids' => %w[combined]
    }
  ],
  'move_existing_elements' => [{
    'from_page' => 'data', 'to_page' => 'derived', 'kind' => 'table', 'name' => 'Master'
  }],
  'master_sources' => {
    'page-overview-master' => {
      'page' => 'Overview',
      'source' => { 'kind' => 'table', 'elementId' => 'combined' },
      'fields' => {
        'Record Type' => '"P&L"',
        'Amount' => '[Combined/Amount]'
      }
    }
  },
  'formula_rewrites' => {
    '[Metrics/Total Amount]' => 'Sum([Master/Amount])'
  }
}

result = WorkbookPipelineReuse.apply!(generated, donor_spec: donor, plan: plan)
spec = result['spec']
elements = spec['pages'].flat_map { |page| page['elements'] || [] }
by_id = elements.to_h { |element| [element['id'], element] }

assert(spec['pages'].first['id'] == 'data', 'pipeline page merged with existing data page')
assert(%w[actuals combined].all? { |id| by_id.key?(id) }, 'donor pipeline copied')
assert(by_id.key?('master-overview'), 'existing page master retained during pipeline merge')
assert(spec['pages'].find { |page| page['id'] == 'derived' }['elements'].any? { |element| element['id'] == 'master-overview' },
       'existing master moved to derived pipeline page')
assert(by_id['master-overview'].dig('source', 'elementId') == 'combined', 'master routed to pipeline root')
assert(by_id['master-overview']['columns'][0]['formula'] == '"P&L"', 'semantic constant mapping applied')
assert(by_id['master-overview']['columns'][1]['formula'] == '[Combined/Amount]', 'semantic source mapping applied')
assert(by_id['kpi']['columns'][0]['formula'] == 'Sum([Master/Amount])', 'metric formula rewritten')
assert(by_id['kpi']['name'] == 'Revenue', 'hash-shaped display name normalized')
assert(result.dig('report', 'pipeline_elements_copied') == 2, 'reuse evidence report')

puts 'PASS: workbook pipeline reuse'
