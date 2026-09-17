#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../scripts/lib/domo_workbook_code'

class TestDomoWorkbookCode < Minitest::Test
  def test_normalizes_legacy_page_nested_fixture
    legacy = {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'pages' => [
        {
          'id' => 'page-1',
          'name' => 'Overview',
          'elements' => [{ 'id' => 'chart-1', 'kind' => 'bar-chart' }]
        }
      ],
      'layout' => '<Page id="page-1"><LayoutElement elementId="chart-1"/></Page>'
    }

    document = DomoSigma::WorkbookCode.normalized_document(legacy)

    assert_equal [{ 'id' => 'page-1', 'name' => 'Overview' }], document['pages']
    assert_equal ['chart-1'], document['elements'].map { |element| element['id'] }
    assert_equal '<Page id="page-1"><Element elementId="chart-1"/></Page>', document['layout']
    assert legacy['pages'].first.key?('elements'), 'normalization must not mutate its input'
  end

  def test_preserves_released_flat_document
    released_document = {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'pages' => [{ 'id' => 'page-1', 'name' => 'Overview' }],
      'elements' => [{ 'id' => 'chart-1', 'kind' => 'bar-chart' }],
      'layout' => '<Page id="page-1"><Element elementId="chart-1"/></Page>'
    }
    envelope = { 'name' => 'Domo migration', 'document' => released_document }

    assert_equal released_document, DomoSigma::WorkbookCode.normalized_document(envelope)
  end

  def test_preserves_local_hidden_helper_hint_during_analysis
    document = {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'pages' => [{
        'id' => 'data',
        'elements' => [{
          'id' => 'master', 'kind' => 'table', 'visibleAsSource' => false,
          'columns' => [{ 'id' => 'value', 'name' => 'Value' }],
        }],
      }],
      'layout' => '<Page id="data"><Element elementId="master"/></Page>',
    }

    normalized = DomoSigma::WorkbookCode.normalized_document(document)
    assert_equal false, normalized['elements'].first['visibleAsSource'],
                 'analysis normalization must retain the hidden-helper hint'
  end
end
