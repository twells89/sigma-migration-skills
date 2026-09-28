#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'

DIR = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

calculations = [
  { 'name' => '[Parameter 1]', 'caption' => 'Type', 'formula' => '0.' },
  { 'name' => '[Parameter 3]', 'caption' => 'RANK', 'formula' => '0.' },
  {
    'name' => '[measure_calc]', 'caption' => 'Measure',
    'formula' => "SUM(CASE [Parameters].[Parameter 1]\n" \
                 "WHEN 0 THEN [Total]\nWHEN 1 THEN [Domestic]\n" \
                 "WHEN 2 THEN [International]\nEND)"
  },
  {
    'name' => '[top_desc]', 'caption' => 'Top 5',
    'formula' => "RANK([measure_calc],'desc') <= 5"
  },
  {
    'name' => '[top_asc]', 'caption' => 'Bottom 5',
    'formula' => "RANK([measure_calc],'asc') <= 5"
  },
  {
    'name' => '[rank_switch]', 'caption' => 'Most/Least Impacted',
    'formula' => "CASE [Parameters].[Parameter 3]\n" \
                 "WHEN 0 THEN [top_asc]\nWHEN 1 THEN [top_desc]\nEND",
    'parameter_refs' => ['RANK']
  },
  { 'name' => '[index_calc]', 'caption' => 'Index', 'formula' => 'INDEX()' },
  {
    'name' => '[window_calc]', 'caption' => 'Window Max or Min',
    'formula' => "WINDOW_MAX(CASE [Parameters].[Parameter 3] " \
                 "WHEN 0 THEN (IF [top_desc] THEN [measure_calc] END) " \
                 "WHEN 1 THEN (IF [top_asc] THEN [measure_calc] END) END)",
    'parameter_refs' => ['RANK']
  }
]

zone = lambda do |id, caption, region, x|
  {
    'id' => id, 'kind' => 'chart', 'caption' => caption,
    'display_title' => 'The <[Parameters].[Parameter 3]> Products',
    'x_pct' => x, 'y_pct' => 0.0, 'w_pct' => 50.0, 'h_pct' => 100.0,
    'chart_kind' => 'bar', 'chart_kind_inferred' => false,
    'mark_class' => 'Bar', 'dual_axis' => true,
    'filters' => [
      {
        'raw_class' => 'categorical', 'column_caption' => 'Region',
        'kind' => 'list', 'members' => [region], 'is_action' => false
      },
      {
        'raw_class' => 'categorical', 'column_caption' => 'Most/Least Impacted',
        'raw_param' => '[rank_switch]', 'kind' => 'list',
        'members' => ['true'], 'is_action' => false
      }
    ],
    'hidden_filters' => [],
    'aggregations' => {
      '[State]' => 'None', '[measure_calc]' => 'User',
      '[index_calc]' => 'User', '[window_calc]' => 'User'
    },
    'channels' => { 'color' => { 'column' => '[Region]' } },
    'formats' => {},
    'calculations' => calculations,
    'measures' => [
      { 'column' => '[measure_calc]', 'derivation' => 'User' },
      { 'column' => '[window_calc]', 'derivation' => 'User' }
    ],
    'rows_shelf' => {
      'raw' => '([index_calc] / [State])',
      'fields' => [
        { 'raw' => '[index_calc]', 'role' => 'measure', 'derivation' => 'usr', 'guid' => 'index_calc' },
        { 'raw' => '[State]', 'role' => 'dim', 'derivation' => 'none', 'guid' => 'State' }
      ],
      'dim_count' => 1, 'measure_count' => 1,
      'has_measure_names' => false, 'has_measure_values' => false
    },
    'cols_shelf' => {
      'raw' => '([measure_calc] + [window_calc])',
      'fields' => [
        { 'raw' => '[window_calc]', 'role' => 'measure', 'derivation' => 'usr', 'guid' => 'window_calc' }
      ],
      'dim_count' => 0, 'measure_count' => 1,
      'has_measure_names' => false, 'has_measure_values' => false
    },
    'is_crosstab' => false, 'is_kpi' => false,
    'mark_labels_show' => true
  }
end

layout = [{
  'dashboard' => 'Regional',
  'zones' => [
    zone.call('1', 'Top States - South', 'South', 0.0),
    zone.call('2', 'Top States - West', 'West', 50.0)
  ],
  'zone_tree' => [],
  'trellis' => [{
    'field' => 'Region', 'chart_kind' => 'bar', 'orientation' => 'cols',
    'members' => %w[South West], 'zone_ids' => %w[1 2],
    'captions' => ['Top States - South', 'Top States - West']
  }]
}]

meta = {
  'worksheets' => {
    'Top States - South' => layout[0]['zones'][0],
    'Top States - West' => layout[0]['zones'][1]
  },
  'parameters' => [
    { 'name' => '[Parameter 1]', 'caption' => 'Type', 'datatype' => 'real',
      'param_domain' => 'list', 'default_value' => '0.', 'members' => %w[0. 1. 2.] },
    { 'name' => '[Parameter 3]', 'caption' => 'RANK', 'datatype' => 'real',
      'param_domain' => 'list', 'default_value' => '0.', 'members' => %w[0. 1.] }
  ],
  'shared_filters' => [],
  'columns_by_guid' => {
    'State' => { 'caption' => 'State', 'datatype' => 'string' },
    'Region' => { 'caption' => 'Region', 'datatype' => 'string' },
    'measure_calc' => { 'caption' => 'Measure', 'datatype' => 'integer' },
    'index_calc' => { 'caption' => 'Index', 'datatype' => 'integer' },
    'window_calc' => { 'caption' => 'Window Max or Min', 'datatype' => 'integer' }
  }
}

master_map = {
  '(?i)^State$' => { 'id' => 'm-state', 'name' => 'State' },
  '(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Total$' => { 'id' => 'm-total', 'name' => 'Total' },
  '(?i)^Domestic$' => { 'id' => 'm-domestic', 'name' => 'Domestic' },
  '(?i)^International$' => { 'id' => 'm-international', 'name' => 'International' }
}

output = nil
log = ''
Dir.mktmpdir do |dir|
  layout_path = File.join(dir, 'layout.json')
  meta_path = File.join(dir, 'layout-meta.json')
  map_path = File.join(dir, 'master-map.json')
  out_path = File.join(dir, 'out.json')
  File.write(layout_path, JSON.generate(layout))
  File.write(meta_path, JSON.generate(meta))
  File.write(map_path, JSON.generate(master_map))
  File.write(File.join(dir, 'get-workbook.json'), JSON.generate(
    'views' => { 'view' => [
      { 'id' => 'south', 'name' => 'Top States - South' },
      { 'id' => 'west', 'name' => 'Top States - West' }
    ] }
  ))
  Dir.mkdir(File.join(dir, 'views'))
  File.write(File.join(dir, 'views', 'south.csv'), '')
  File.write(File.join(dir, 'views', 'west.csv'), '')
  File.write(File.join(dir, 'png-read.json'), JSON.generate(
    'verified' => true,
    'tiles' => [
      { 'title' => 'Top States - South', 'kind' => 'bar-chart', 'orientation' => 'horizontal' },
      { 'title' => 'Top States - West', 'kind' => 'bar-chart', 'orientation' => 'horizontal' }
    ],
    'text_elements' => [], 'filter_shelf' => []
  ))

  log = IO.popen(
    ['ruby', BUILD, '--tableau-dir', dir, '--layout', layout_path,
     '--meta', meta_path, '--master-map', map_path,
     '--master-element-id', 'master', '--title', 'Regional',
     '--out', out_path],
    err: %i[child out], &:read
  ).to_s
  output = JSON.parse(File.read(out_path)) if File.exist?(out_path)
end

elements =
  if output.is_a?(Array)
    output
  elsif output
    output['elements'] || Array(output['pages']).flat_map { |page| page['elements'] || [] }
  else
    []
  end
panels = elements.select { |element| element['id'].to_s.start_with?('el-top-states-') }
check.call(panels.size == 2, "both source region panels survive (got #{panels.map { |e| e['id'] }.inspect})")
panels.each do |element|
  check.call(element['kind'] == 'bar-chart', "#{element['id']} remains a bar chart")
  check.call(element['orientation'] == 'horizontal', "#{element['id']} preserves horizontal orientation")
  check.call(element['name'] == 'Top / Bottom 5 Products',
             "#{element['id']} uses a stable label instead of rendering the raw parameter value")
  check.call(element['trellis'].nil?, "#{element['id']} is not globally trellised")
  topn = Array(element['filters']).find { |filter| filter['kind'] == 'top-n' }
  check.call(topn && topn['rowCount'] == 5, "#{element['id']} carries a per-panel top-5 filter")
  y_ids = Array(element.dig('yAxis', 'columnIds'))
  check.call(y_ids.size == 1, "#{element['id']} suppresses the hidden INDEX/WINDOW helper axis")
  formulas = Array(element['columns']).map { |column| column['formula'].to_s }
  check.call(formulas.any? { |formula| formula.include?('[ctl-param-rank]') },
             "#{element['id']} rank score is driven by the RANK control")
  rank_formula = Array(element['columns']).find do |column|
    column['name'] == 'Dynamic Top / Bottom Rank Score'
  end&.dig('formula').to_s
  check.call(
    rank_formula.include?('Switch([ctl-param-rank], "1",') &&
      rank_formula.include?('"0", -('),
    "#{element['id']} derives descending/ascending polarity from the source CASE mapping"
  )
  check.call(formulas.none? { |formula| formula.match?(/\b(?:IF|THEN|END)\b/) },
             "#{element['id']} leaks no Tableau IF/THEN/END syntax")
end
check.call(log.include?('left FLAT because Sigma evaluates top-N across the trellis domain'),
           'builder records why partition-sensitive panels are not collapsed')

puts
if fails.empty?
  puts 'ALL PASS — dynamic top/bottom panels remain separate horizontal bars with per-panel top-N'
  exit 0
end
warn "#{fails.size} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
warn log.lines.last(40).join
exit 1
