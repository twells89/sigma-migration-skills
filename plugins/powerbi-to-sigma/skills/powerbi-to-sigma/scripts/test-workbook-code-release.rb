#!/usr/bin/env ruby
# frozen_string_literal: true

# Focused offline regression for the Aug-2026 workbook-as-code release.
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/layout_lint'
require_relative 'lib/layout'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')
ASSEMBLE = File.join(__dir__, 'build-workbook-spec.rb')
VALIDATE = File.join(__dir__, 'validate-spec.rb')
RUBY = RbConfig.ruby
$fail = 0

def ok(label, value)
  puts "#{value ? '  ok  ' : 'FAIL  '}#{label}"
  $fail += 1 unless value
end

master = {
  'masters' => {
    'S' => {
      'id' => 'master-s', 'element_id' => 'dm-s', 'data_model' => 'dm-1',
      'columns' => [
        { 'id' => 'm-region', 'name' => 'Region', 'formula' => '[S/Region]' },
        { 'id' => 'm-state', 'name' => 'State', 'formula' => '[S/State]' },
        { 'id' => 'm-amount', 'name' => 'Amount', 'formula' => '[S/Amount]' }
      ]
    }
  },
  'fields' => {
    'S.Region' => { 'master' => 'S', 'ref' => '[master-s/Region]', 'agg' => nil },
    'S.State' => { 'master' => 'S', 'ref' => '[master-s/State]', 'agg' => nil },
    'S.Amount' => { 'master' => 'S', 'ref' => '[master-s/Amount]', 'agg' => 'Sum' }
  }
}

visual = lambda do |id, type, token, role, bindings, title, y, extra = {}|
  {
    'visual_id' => id, 'visual_type' => type, 'sigma_kind' => token,
    'role_class' => role, 'approximate' => false, 'title' => title,
    'x' => 0, 'y' => y, 'w' => 500, 'h' => 140, 'z' => 0,
    'bindings' => bindings, 'formats' => {}, 'style' => { 'backgroundColor' => '#F8FAFC' }
  }.merge(extra)
end

signals = {
  'source' => 'powerbi',
  'pages' => [{
    'page_id' => 'p1', 'page_title' => 'Overview', 'page_w' => 1280, 'page_h' => 720,
    'style' => { 'backgroundColor' => '#EEF2F7' }, 'interactions' => [],
    'visuals' => [
      visual.call('wf', 'waterfallChart', 'waterfall', 'chart',
                  { 'Category' => ['S.State'], 'Y' => ['S.Amount'], 'Legend' => ['S.Region'] },
                  'Amount Change', 0,
                  { 'legend' => false,
                    'drill' => { 'role' => 'Category', 'levels' => ['S.Region', 'S.State'],
                                 'active' => 'S.State' } }),
      visual.call('bar', 'clusteredColumnChart', 'bar', 'chart',
                  { 'Category' => ['S.State'], 'Y' => ['S.Amount'], 'Legend' => ['S.Region'] },
                  'Regional Trend', 150, { 'legend' => true }),
      visual.call('g', 'gauge', 'progress', 'chart', { 'Values' => ['S.Amount'] }, 'Goal', 300),
      visual.call('nav', 'pageNavigator', 'navigation', 'text', {}, 'Pages', 450),
      visual.call('ctl', 'slicer', 'control', 'control', { 'Values' => ['S.Region'] }, 'Region', 600),
      visual.call('tbl', 'tableEx', 'table', 'table',
                  { 'Values' => ['S.Region', 'S.Amount'] }, 'Details', 750),
      visual.call('donut', 'donutChart', 'donut', 'chart',
                  { 'Category' => ['S.Region'], 'Y' => ['S.Amount'] }, 'Regional Share', 900)
    ]
  }]
}

Dir.mktmpdir('pbi-workbook-code') do |dir|
  sig = File.join(dir, 'signals.json')
  mmap = File.join(dir, 'master-map.json')
  out = File.join(dir, 'workbook.json')
  File.write(sig, JSON.generate(signals))
  File.write(mmap, JSON.generate(master))
  _stdout, stderr, status = Open3.capture3(
    RUBY, BUILD, '--signals', sig, '--master-map', mmap, '--data-model', 'dm-1',
    '--out', out, '--layout-out', File.join(dir, 'layout.xml'), '--name', 'Release'
  )
  ok('builder succeeds', status.success? || (warn(stderr) && false))
  next unless status.success?

  envelope = JSON.parse(File.read(out))
  doc = envelope['document'] || {}
  ok('outer envelope contains metadata only', envelope['name'] == 'Release' && !envelope.key?('pages'))
  ok('document declares schemaVersion and kind', doc['schemaVersion'] == 1 && doc['kind'] == 'workbook')
  ok('pages are metadata-only', Array(doc['pages']).all? { |p| !p.key?('elements') })
  ok('elements are flat', doc['elements'].is_a?(Array) && doc['elements'].length >= 6)
  ok('layout is required and present', doc['layout'].to_s.include?('<Page'))
  ok('layout emits only live canonical Element/Container tags',
     doc['layout'].to_s.include?('<Element ') &&
       doc['layout'].to_s.include?('<Container ') &&
       !doc['layout'].to_s.match?(%r{<(?:LayoutElement|GridContainer)\b}))

  ids = doc['elements'].map { |e| e['id'] }
  placed = doc['layout'].scan(/\belementId="([^"]+)"/).flatten
  ok('every element is placed exactly once', ids.sort == placed.sort && placed.uniq.length == placed.length)

  waterfall = doc['elements'].find { |e| e['kind'] == 'waterfall-chart' }
  ok('waterfall uses native kind and splitBy', waterfall && waterfall.dig('splitBy', 'id') &&
     waterfall.dig('waterfallShape', 'connectorLine') == 'shown')
  ok('legend visibility applies to native waterfall',
     waterfall && waterfall['legend'] == { 'visibility' => 'hidden' })
  drill = doc['elements'].find { |e| e['controlType'] == 'drill' }
  ok('complete Power BI hierarchy emits native drill control',
     drill && Array(drill['categories']).length == 2 &&
       drill.dig('targets', 0, 'source', 'elementId') == waterfall['id'] &&
       drill.dig('targets', 0, 'columnIds').length == 2)
  bar = doc['elements'].find { |e| e['name'] == 'Regional Trend' }
  legend = doc['elements'].find { |e| e['controlType'] == 'legend' }
  ok('bound visible Power BI legend emits native legend control',
     bar && legend &&
       legend.dig('source', 'columnId') == 'm-region' &&
       legend.dig('targets', 0, 'source', 'elementId') == bar['id'] &&
       legend.dig('targets', 0, 'columnId') == bar.dig('color', 'column') &&
       bar['legend'] == { 'visibility' => 'hidden' })
  legend_pair = bar && legend &&
                doc['layout'].match?(
                  %r{<Container elementId="band-page-p1-legend-#{Regexp.escape(bar['id'])}"[^>]*gridTemplateRows="repeat\(8, 1fr\)"[^>]*>.*?<Element elementId="#{Regexp.escape(bar['id'])}" gridColumn="1 / 25"[^>]*/>.*?<Element elementId="#{Regexp.escape(legend['id'])}" gridColumn="19 / 25"[^>]*/>}m
                )
  ok('visible legend control stays beside and fills its source chart panel', legend_pair)
  donut = doc['elements'].find { |e| e['kind'] == 'donut-chart' }
  ok('donut category sort pins the positional Power BI palette',
     donut && donut.dig('color', 'sort') == {
       'by' => donut.dig('color', 'id'), 'direction' => 'ascending'
     })
  donut_dim = donut && donut['columns'].find { |c| c['id'] == donut.dig('color', 'id') }
  blank_safe = doc['elements'].find { |e| e['id'] == 'master-s' }
                              &.fetch('columns', [])
                              &.find { |c| c['id'] == 'm-region-blank' }
  donut_legend = doc['elements'].find do |e|
    e['controlType'] == 'legend' &&
      e.dig('targets', 0, 'source', 'elementId') == donut&.fetch('id', nil)
  end
  ok('donut blank bucket is materialized on the master to avoid gray Others',
     blank_safe &&
       blank_safe['formula'] == 'Coalesce([S/Region], "(Blank)")' &&
       donut_dim&.fetch('formula', nil) == '[master-s/Region (Blank-safe)]')
  ok('donut keeps its legend chart-local so the ring fills the panel',
     donut_legend.nil? && donut['legend'] == { 'visibility' => 'shown' })
  progress = doc['elements'].find { |e| e['kind'] == 'progress' }
  ok('gauge uses native ring progress', progress && progress['shape'] == 'ring' &&
     progress['mode'] == 'value' && progress['value'].to_s.include?('master-s'))
  nav = doc['elements'].find { |e| e['kind'] == 'navigation' }
  ok('page navigator uses native auto navigation', nav && nav['mode'] == 'auto')
  ok('feature-gated workbook navigation setting is omitted',
     !doc.fetch('settings', {}).key?('navigation'))
  ok('background and spacing survive', waterfall.dig('style', 'backgroundColor') == '#F8FAFC' &&
     Array(doc.dig('settings', 'theme', 'overrides', 'colorOverrides')).any? { |e| e.is_a?(Hash) && e['name'] == 'backgroundCanvas' && e['color'] == '#EEF2F7' } &&
     doc.dig('settings', 'theme', 'overrides', 'space', 'unit') == 'small')
  multiline_header = SigmaLayout.header_text_el('header', "Title\nSubtitle")
  ok('multiline source header preserves a muted subtitle',
     multiline_header['body'].include?('# <span style="color: #FFFFFF">Title</span>') &&
       multiline_header['body'].include?('<span style="color: #94A3B8">Subtitle</span>'))

  control = doc['elements'].find { |e| e['controlType'] == 'list' }
  target_ids = Array(control && control['filters']).filter_map { |f| f.dig('source', 'elementId') }
  ok('control references resolve to flat elements', target_ids.any? && (target_ids - ids).empty?)

  table = doc['elements'].find { |e| e['name'] == 'Details' }
  valid_columns = Array(table && table['columns']).map { |c| c['id'] }
  grouping_refs = Array(table && table['groupings']).flat_map do |g|
    Array(g['groupBy']) + Array(g['calculations'])
  end
  ok('table grouping references survive flattening and resolve', grouping_refs.any? &&
     (grouping_refs - valid_columns).empty?)

  _vo, ve, vst = Open3.capture3(RUBY, VALIDATE, '--type', 'workbook', out)
  ok('flat workbook passes validate-spec', vst.success? || (warn(ve) && false))
  layout_violations = LayoutLint.lint(envelope)
  legend_ids = doc['elements'].select { |e| e['controlType'] == 'legend' }.flat_map do |e|
    [e['id'], e.dig('targets', 0, 'source', 'elementId')]
  end.compact
  legend_violations = layout_violations.select { |v| legend_ids.any? { |id| v.include?(id) } }
  ok('chart-adjacent legend container passes layout lint',
     legend_violations.empty? || (warn(legend_violations.join("\n")) && false))
end

Dir.mktmpdir('pbi-legacy-assembler') do |dir|
  charts = File.join(dir, 'charts.json')
  dm_ids = File.join(dir, 'dm-ids.json')
  columns = File.join(dir, 'columns.yml')
  out = File.join(dir, 'workbook.json')
  File.write(charts, JSON.generate([
    { 'id' => 'chart-1', 'kind' => 'text', 'body' => 'Legacy assembler' }
  ]))
  # Data-model id maps intentionally remain nested.
  File.write(dm_ids, JSON.generate(
    'dataModelId' => 'dm-1',
    'pages' => [{ 'elements' => [{ 'id' => 'dm-source', 'name' => 'Fact' }] }]
  ))
  File.write(columns, "columns:\n  - { id: m-region, name: Region, formula: \"[Fact/Region]\" }\n")
  _ao, ae, ast = Open3.capture3(
    RUBY, ASSEMBLE, '--chart-specs', charts, '--dm-ids', dm_ids,
    '--master-cols', columns, '--workbook-name', 'Assembler', '--folder-id', 'folder',
    '--mode', 'dashboard', '--out', out
  )
  ok('secondary workbook assembler succeeds', ast.success? || (warn(ae) && false))
  if ast.success?
    assembled = JSON.parse(File.read(out))
    adoc = assembled['document'] || {}
    ok('secondary assembler emits flat document elements',
       Array(adoc['pages']).all? { |p| !p.key?('elements') } &&
       Array(adoc['elements']).map { |e| e['id'] }.sort == %w[chart-1 master])
    aplaced = adoc['layout'].to_s.scan(/\belementId="([^"]+)"/).flatten
    ok('secondary assembler places every element once',
       aplaced.sort == %w[chart-1 master] && aplaced.uniq.length == aplaced.length)
    ok('secondary assembler emits canonical Element tags',
       adoc['layout'].to_s.include?('<Element ') &&
         !adoc['layout'].to_s.match?(%r{<(?:LayoutElement|GridContainer)\b}))
  end
end

puts($fail.zero? ? "\nall workbook-code release tests passed" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
