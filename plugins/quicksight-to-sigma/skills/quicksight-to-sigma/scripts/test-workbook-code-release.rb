#!/usr/bin/env ruby
# frozen_string_literal: true

# Focused offline regression for the Aug-2026 workbook-as-code release.
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

BUILD = File.join(__dir__, 'build-workbook-from-quicksight.rb')
VALIDATE = File.join(__dir__, 'validate-spec.rb')
RUBY = RbConfig.ruby
$fail = 0

def ok(label, value)
  puts "#{value ? '  ok  ' : 'FAIL  '}#{label}"
  $fail += 1 unless value
end

def dim(id, name)
  { 'CategoricalDimensionField' => {
    'FieldId' => id, 'Column' => { 'DataSetIdentifier' => 'orders', 'ColumnName' => name }
  } }
end

def measure(id, name)
  { 'NumericalMeasureField' => {
    'FieldId' => id, 'Column' => { 'DataSetIdentifier' => 'orders', 'ColumnName' => name },
    'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' }
  } }
end

waterfall = {
  'WaterfallVisual' => {
    'VisualId' => 'waterfall',
    'Title' => { 'FormatText' => { 'PlainText' => 'Amount Change' } },
    'ColumnHierarchies' => [{
      'ExplicitHierarchy' => {
        'HierarchyId' => 'geo', 'Columns' => [
          { 'DataSetIdentifier' => 'orders', 'ColumnName' => 'REGION' },
          { 'DataSetIdentifier' => 'orders', 'ColumnName' => 'STATE' }
        ]
      }
    }],
    'ChartConfiguration' => {
      'FieldWells' => {
        'WaterfallChartAggregatedFieldWells' => {
          'Categories' => [dim('state', 'STATE')],
          'Values' => [measure('amount', 'AMOUNT')],
          'Breakdowns' => [dim('region', 'REGION')]
        }
      },
      'Legend' => { 'Visibility' => 'HIDDEN', 'Position' => 'RIGHT' }
    }
  }
}

gauge = {
  'GaugeChartVisual' => {
    'VisualId' => 'gauge',
    'Title' => { 'FormatText' => { 'PlainText' => 'Goal' } },
    'ChartConfiguration' => {
      'FieldWells' => {
        'GaugeChartAggregatedFieldWells' => { 'Values' => [measure('goal', 'AMOUNT')] }
      },
      'GaugeChartOptions' => { 'ArcAxis' => { 'Range' => { 'Min' => 10, 'Max' => 500 } } }
    }
  }
}

box = {
  'BoxPlotVisual' => {
    'VisualId' => 'box',
    'Title' => { 'FormatText' => { 'PlainText' => 'Distribution' } },
    'ChartConfiguration' => {
      'FieldWells' => {
        'BoxPlotAggregatedFieldWells' => {
          'GroupBy' => [dim('box-region', 'REGION')],
          'Values' => [measure('box-amount', 'AMOUNT')]
        }
      }
    }
  }
}

detail = {
  'TableVisual' => {
    'VisualId' => 'detail',
    'Title' => { 'FormatText' => { 'PlainText' => 'Regional Detail' } },
    'ChartConfiguration' => {
      'FieldWells' => {
        'TableAggregatedFieldWells' => {
          'GroupBy' => [dim('detail-region', 'REGION')],
          'Values' => [measure('detail-amount', 'AMOUNT')]
        }
      }
    }
  }
}

analysis = {
  'Name' => 'QuickSight Release',
  'Definition' => {
    'CalculatedFields' => [],
    'ParameterDeclarations' => [],
    'Sheets' => [
      {
        'SheetId' => 'overview', 'Name' => 'Overview',
        'Visuals' => [waterfall, gauge, box],
        'Layouts' => [{
          'Configuration' => {
            'GridLayout' => {
              'Elements' => [
                { 'ElementId' => 'waterfall', 'ColumnIndex' => 0, 'ColumnSpan' => 12, 'RowIndex' => 0, 'RowSpan' => 8 },
                { 'ElementId' => 'gauge', 'ColumnIndex' => 12, 'ColumnSpan' => 6, 'RowIndex' => 0, 'RowSpan' => 8 },
                { 'ElementId' => 'box', 'ColumnIndex' => 18, 'ColumnSpan' => 6, 'RowIndex' => 0, 'RowSpan' => 8 }
              ]
            }
          }
        }]
      },
      {
        'SheetId' => 'detail-sheet', 'Name' => 'Detail',
        'ContentType' => 'PAGINATED',
        'Visuals' => [detail],
        'Layouts' => [{
          'Configuration' => {
            'SectionBasedLayout' => {
              'BodySections' => [{
                'SectionId' => 'regional-cards',
                'Content' => {
                  'Layout' => {
                    'FreeFormLayout' => {
                      'Elements' => [{ 'ElementId' => 'detail', 'XAxisLocation' => '0px',
                                       'YAxisLocation' => '0px', 'Width' => '800px', 'Height' => '300px' }]
                    }
                  }
                },
                'RepeatConfiguration' => {
                  'DimensionConfigurations' => [{
                    'DynamicCategoryDimensionConfiguration' => {
                      'Column' => { 'DataSetIdentifier' => 'orders', 'ColumnName' => 'REGION' },
                      'Limit' => 20
                    }
                  }],
                  'PageBreakConfiguration' => { 'After' => { 'Status' => 'ENABLED' } }
                },
                'PageBreakConfiguration' => { 'After' => { 'Status' => 'ENABLED' } }
              }]
            }
          }
        }]
      }
    ]
  }
}

readback = {
  'dataModelId' => 'dm-1',
  'pages' => [{
    'id' => 'dm-page',
    'elements' => [{
      'id' => 'dm-orders', 'name' => 'Orders',
      'columns' => [{ 'name' => 'Region' }, { 'name' => 'State' }, { 'name' => 'Amount' }]
    }]
  }]
}

Dir.mktmpdir('qs-workbook-release') do |dir|
  analysis_path = File.join(dir, 'analysis.json')
  readback_path = File.join(dir, 'readback.json')
  output_path = File.join(dir, 'workbook.json')
  File.write(analysis_path, JSON.pretty_generate(analysis))
  File.write(readback_path, JSON.pretty_generate(readback))
  File.write(File.join(dir, 'signals.json'), JSON.pretty_generate(
    'theme' => { 'dataColors' => ['#2563EB', '#F97316'], 'primaryColor' => '#2563EB', 'isDark' => false }
  ))

  _stdout, stderr, status = Open3.capture3(
    RUBY, BUILD, '--analysis', analysis_path, '--dm-readback', readback_path, '--out', output_path
  )
  ok('release builder succeeds', status.success? || (warn(stderr) && false))
  next unless status.success?

  envelope = JSON.parse(File.read(output_path))
  doc = envelope['document'] || {}
  elements = Array(doc['elements'])
  ok('outer create envelope contains metadata only',
     envelope['name'] == 'QuickSight Release (from QuickSight)' && !envelope.key?('pages'))
  ok('document declares released shape',
     doc['schemaVersion'] == 1 && doc['kind'] == 'workbook' &&
       Array(doc['pages']).all? { |page| !page.key?('elements') })
  layout_tags = doc['layout'].to_s.scan(%r{</?([A-Za-z][A-Za-z0-9]*)\b}).flatten.uniq.sort
  ok('layout uses only live canonical Page/Element/Container tags',
     layout_tags == %w[Container Element Page] &&
       !doc['layout'].to_s.match?(%r{<(?:LayoutElement|GridContainer)\b}))

  ids = elements.map { |element| element['id'] }
  placed = doc['layout'].to_s.scan(/\belementId="([^"]+)"/).flatten
  ok('authoritative layout places every flat element once',
     ids.sort == placed.sort && placed.uniq.length == placed.length)

  native_waterfall = elements.find { |element| element['kind'] == 'waterfall-chart' }
  ok('waterfall uses native released channels',
     native_waterfall && native_waterfall.dig('xAxis', 'columnId') &&
       native_waterfall.dig('yAxis', 'columnIds')&.one? &&
       native_waterfall.dig('splitBy', 'columnId') &&
       native_waterfall.dig('waterfallShape', 'connectorLine') == 'shown')
  ok('QuickSight legend visibility and position survive',
     native_waterfall && native_waterfall['legend'] == {
       'visibility' => 'hidden', 'position' => 'right'
     })

  drill = elements.find { |element| element['controlType'] == 'drill' }
  ok('complete QuickSight hierarchy emits native drill control',
     drill && Array(drill['categories']).length == 2 &&
       drill.dig('targets', 0, 'source', 'elementId') == native_waterfall['id'])

  progress = elements.find { |element| element['kind'] == 'progress' }
  ok('gauge uses native ring progress with grounded range',
     progress && progress['shape'] == 'ring' && progress['mode'] == 'value' &&
       progress['min'] == '10' && progress['max'] == '500')

  navigation = elements.select { |element| element['kind'] == 'navigation' }
  ok('multi-sheet analysis emits auto page navigation',
     navigation.length == 2 && navigation.all? { |element| element['mode'] == 'auto' } &&
       doc.dig('settings', 'navigation', 'pageTabsInViewMode') == 'shown')

  repeater = elements.find { |element| element['kind'] == 'repeated-container' }
  breaks = elements.select { |element| element['kind'] == 'page-break' }
  ok('section repeat emits native repeated-container and grouped source',
     repeater && repeater.dig('source', 'groupingId') &&
       elements.any? { |element| element['id'] == repeater.dig('source', 'elementId') })
  ok('section and repeated-instance breaks emit one-row page-breaks',
     breaks.length == 2 && breaks.all? do |element|
       match = doc['layout'].match(/elementId="#{Regexp.escape(element['id'])}"[^>]*gridRow="(\d+) \/ (\d+)"/)
       match && match[2].to_i - match[1].to_i == 1
     end)

  ok('panels are not fabricated and style is grounded in discovered theme',
     doc['panels'] == [] &&
       doc.dig('settings', 'theme', 'overrides', 'categoricalScheme') == ['#2563EB', '#F97316'])
  ok('box plot remains release-gated fallback',
     elements.none? { |element| element['kind'] == 'box-chart' } &&
       elements.any? { |element| element['name'] == 'Distribution' && element['kind'] == 'table' })

  vo, ve, validate_status = Open3.capture3(
    RUBY, VALIDATE, '--type', 'workbook', '--dm-context', readback_path, output_path
  )
  ok('release workbook passes validator', validate_status.success? || (warn(vo + ve) && false))
end

puts($fail.zero? ? "\nall QuickSight workbook-code release tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
