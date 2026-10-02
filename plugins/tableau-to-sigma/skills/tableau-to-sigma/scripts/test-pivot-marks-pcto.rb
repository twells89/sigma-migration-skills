#!/usr/bin/env ruby
# frozen_string_literal: true

# A percent-of-total quick calc can live on the Tableau Marks card while the
# shelves expose only the raw measure. Preserve its axis scope and formatting.

require 'json'
require 'rbconfig'
require 'tmpdir'

DIR = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
RUBY = RbConfig.ruby

fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

twb = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Fact' name='federated.primary'>
        <column caption='Partner Name' datatype='string' name='[Partner Name]' role='dimension' type='nominal' />
        <column caption='Department' datatype='string' name='[Department]' role='dimension' type='nominal' />
        <column caption='Created FYQQ' datatype='string' name='[Created FYQQ]' role='dimension' type='nominal' />
        <column caption='Seed' datatype='string' name='[Seed]' role='measure' type='quantitative' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Partner Share Matrix'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.primary'>
              <column caption='Partner Name' datatype='string' name='[Partner Name]' role='dimension' type='nominal' />
              <column caption='Department' datatype='string' name='[Department]' role='dimension' type='nominal' />
              <column caption='Created FYQQ' datatype='string' name='[Created FYQQ]' role='dimension' type='nominal' />
              <column caption='Seed' datatype='string' name='[Seed]' role='measure' type='quantitative' />
              <column-instance column='[Partner Name]' derivation='None' name='[none:Partner Name:nk]' pivot='key' type='nominal' />
              <column-instance column='[Department]' derivation='None' name='[none:Department:nk]' pivot='key' type='nominal' />
              <column-instance column='[Created FYQQ]' derivation='None' name='[none:Created FYQQ:nk]' pivot='key' type='nominal' />
              <column-instance column='[Seed]' derivation='CountD' name='[ctd:Seed:qk]' pivot='key' type='quantitative' />
              <column-instance column='[Seed]' derivation='CountD' name='[pcto:ctd:Seed:qk:2]' pivot='key' type='quantitative'>
                <table-calc ordering-field='[federated.primary].[none:Partner Name:nk]' type='PctTotal' />
              </column-instance>
            </datasource-dependencies>
          </view>
          <style>
            <style-rule element='cell'>
              <format attr='text-format' field='[federated.primary].[pcto:ctd:Seed:qk:2]' value='p0.0%' />
            </style-rule>
          </style>
          <rows>([federated.primary].[none:Partner Name:nk] / [federated.primary].[none:Department:nk])</rows>
          <cols>[federated.primary].[none:Created FYQQ:nk]</cols>
          <panes>
            <pane>
              <mark class='Square' />
              <encodings><text column='[federated.primary].[pcto:ctd:Seed:qk:2]' /></encodings>
            </pane>
          </panes>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Partner Share'>
        <zones><zone h='100000' id='1' name='Partner Share Matrix' w='100000' x='0' y='0' /></zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

master_map = {
  '(?i)^Partner Name$' => { 'id' => 'm-partner', 'name' => 'Partner Name' },
  '(?i)^Department$' => { 'id' => 'm-department', 'name' => 'Department' },
  '(?i)^Created FYQQ$' => { 'id' => 'm-fyqq', 'name' => 'Created FYQQ' },
  '(?i)^Seed$' => { 'id' => 'm-seed', 'name' => 'Seed' }
}

meta = nil
layout = nil
build_out = nil
build_log = ''

Dir.mktmpdir do |dir|
  twb_path = File.join(dir, 'workbook-content.twb')
  layout_path = File.join(dir, 'dashboard-layout.json')
  meta_path = layout_path.sub(/\.json\z/, '-meta.json')
  map_path = File.join(dir, 'master-columns.json')
  out_path = File.join(dir, 'chart-specs.json')

  File.write(twb_path, twb)
  File.write(map_path, JSON.generate(master_map))
  File.write(File.join(dir, 'get-workbook.json'), JSON.generate('views' => { 'view' => [] }))

  parsed = system(RUBY, PARSER, twb_path, layout_path, out: File::NULL, err: File::NULL)
  check(parsed, 'parser completed', fails)
  if parsed
    meta = JSON.parse(File.read(meta_path))
    layout = JSON.parse(File.read(layout_path))
    build_log = IO.popen(
      [RUBY, BUILD, '--tableau-dir', dir, '--layout', layout_path,
       '--meta', meta_path, '--master-map', map_path,
       '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
       '--title', 'Partner Share', '--out', out_path],
      err: %i[child out], &:read
    )
    build_out = JSON.parse(File.read(out_path)) if File.exist?(out_path)
  end
end

ws = meta && meta.dig('worksheets', 'Partner Share Matrix')
qc = ws && Array(ws['quick_calc_pcto']).first
check(qc == {
        'agg' => 'ctd', 'col' => 'Seed', 'addressing' => 'Partner Name',
        'token' => '[pcto:ctd:Seed:qk:2]'
      }, "parser captures the pcto pill, numeric suffix, and addressing (got #{qc.inspect})", fails)

zone = layout && layout.flat_map { |d| d['zones'] || [] }.find { |z| z['caption'] == 'Partner Share Matrix' }
check(zone && zone['chart_kind'] == 'pivot-table',
      "two-dimensional Square-mark crosstab stays a pivot-table (got #{zone && zone['chart_kind'].inspect})", fails)

elements = if build_out.is_a?(Array)
             build_out
           else
             Array(build_out && build_out['elements']) +
               Array(build_out && build_out['pages']).flat_map { |page| page['elements'] || [] }
           end
pivot = elements.find { |element| element['kind'] == 'pivot-table' }
check(!pivot.nil?, 'builder emits a pivot-table element', fails)
check(pivot && Array(pivot['rowsBy']).size == 2,
      "both Tableau row fields survive (got #{pivot && pivot['rowsBy'].inspect})", fails)
check(pivot && pivot.dig('display', 'rowLayout') == 'separate-columns',
      "multi-row pivot preserves separate source header columns (got #{pivot && pivot['display'].inspect})", fails)

value_col = if pivot
              Array(pivot['columns']).find { |column| Array(pivot['values']).include?(column['id']) }
            end
check(value_col && value_col['formula'] == 'PercentOfTotal(CountDistinct([Master/Seed]), "column")',
      "Marks-card pcto wraps the CountD value with rows-axis scope (got #{value_col && value_col['formula'].inspect})", fails)
check(value_col && value_col.dig('format', 'formatString') == ',.1%',
      "Marks-card pcto keeps the source's one-decimal percent format (got #{value_col && value_col['format'].inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS - pivot Marks-card percent-of-total survives parser and builder'
  exit 0
end

puts "FAILURES (#{fails.length}):"
fails.each { |failure| puts "  - #{failure}" }
puts "\n--- build log ---\n#{build_log}" unless build_log.empty?
exit 1
