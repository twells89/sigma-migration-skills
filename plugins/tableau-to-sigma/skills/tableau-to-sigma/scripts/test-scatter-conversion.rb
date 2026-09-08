#!/usr/bin/env ruby
# Focused offline regression for Tableau scatter detection and Sigma emission.
# Usage: ruby scripts/test-scatter-conversion.rb

require 'json'
require 'tmpdir'

dir = __dir__
parser = File.join(dir, 'parse-twb-layout.rb')
builder = File.join(dir, 'build-charts-from-signals.rb')
fails = []

def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

customer = '[11111111-1111-1111-1111-111111111111]'
sales = '[22222222-2222-2222-2222-222222222222]'
profit = '[33333333-3333-3333-3333-333333333333]'
orders = '[44444444-4444-4444-4444-444444444444]'

twb = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Orders' name='federated.orders'>
        <column caption='Customer' name='#{customer}' datatype='string' role='dimension' type='nominal' />
        <column caption='Sales' name='#{sales}' datatype='real' role='measure' type='quantitative' />
        <column caption='Profit' name='#{profit}' datatype='real' role='measure' type='quantitative' />
        <column caption='Order Count' name='#{orders}' datatype='integer' role='measure' type='quantitative' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Customer Profitability'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.orders'>
              <column caption='Customer' name='#{customer}' datatype='string' role='dimension' type='nominal' />
              <column caption='Sales' name='#{sales}' datatype='real' role='measure' type='quantitative' />
              <column caption='Profit' name='#{profit}' datatype='real' role='measure' type='quantitative' />
              <column caption='Order Count' name='#{orders}' datatype='integer' role='measure' type='quantitative' />
              <column-instance column='#{customer}' derivation='None' name='[none:#{customer[1..-2]}:nk]' pivot='key' type='nominal' />
              <column-instance column='#{sales}' derivation='Sum' name='[sum:#{sales[1..-2]}:qk]' pivot='key' type='quantitative' />
              <column-instance column='#{profit}' derivation='Avg' name='[avg:#{profit[1..-2]}:qk]' pivot='key' type='quantitative' />
              <column-instance column='#{orders}' derivation='Sum' name='[sum:#{orders[1..-2]}:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <style>
            <style-rule element='mark'>
              <encoding attr='color' field='[federated.orders].[none:#{customer[1..-2]}:nk]' type='palette'>
                <map to='#445566'><bucket>&quot;Globex&quot;</bucket></map>
                <map to='#112233'><bucket>&quot;Acme&quot;</bucket></map>
              </encoding>
            </style-rule>
          </style>
          <rows>[federated.orders].[avg:#{profit[1..-2]}:qk]</rows>
          <cols>[federated.orders].[sum:#{sales[1..-2]}:qk]</cols>
          <pane>
            <mark class='Circle' />
            <encodings>
              <detail column='[federated.orders].[none:#{customer[1..-2]}:nk]' />
              <size column='[federated.orders].[sum:#{orders[1..-2]}:qk]' />
            </encodings>
          </pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Customer Analysis'><zones>
        <zone id='1' name='Customer Profitability' x='0' y='0' w='100000' h='100000' />
      </zones></dashboard>
    </dashboards>
  </workbook>
XML

header_pattern = lambda do |name|
  '(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of ' \
    '|(?:avg|sum|min|max|med|cnt|ctd)\.\s*)?' + Regexp.escape(name) + '$'
end
master_map = {
  header_pattern.call('Customer') => { 'id' => 'm-customer', 'name' => 'Customer' },
  header_pattern.call('Sales') => { 'id' => 'm-sales', 'name' => 'Sales' },
  header_pattern.call('Profit') => { 'id' => 'm-profit', 'name' => 'Profit' },
  header_pattern.call('Order Count') => { 'id' => 'm-orders', 'name' => 'Order Count' }
}

Dir.mktmpdir do |work|
  twb_path = File.join(work, 'scatter.twb')
  layout_path = File.join(work, 'layout.json')
  map_path = File.join(work, 'master-map.json')
  out_path = File.join(work, 'elements.json')
  File.write(twb_path, twb)
  File.write(map_path, JSON.pretty_generate(master_map))
  File.write(File.join(work, 'get-workbook.json'), JSON.pretty_generate(
    'views' => { 'view' => [{ 'id' => 'scatter-view', 'name' => 'Customer Profitability' }] }
  ))
  Dir.mkdir(File.join(work, 'views'))
  File.write(File.join(work, 'views', 'scatter-view.csv'), <<~CSV)
    Customer,Avg. Profit,Sum of Sales
    Acme,20,100
    Globex,35,240
  CSV

  parse_ok = system('ruby', parser, twb_path, layout_path, out: File::NULL, err: File::NULL)
  check(parse_ok, 'parser accepts representative Tableau scatter workbook', fails)
  next unless parse_ok

  layout = JSON.parse(File.read(layout_path))
  zone = layout.dig(0, 'zones', 0) || {}
  check(zone['chart_kind'] == 'scatter', "Circle worksheet detected as scatter (got #{zone['chart_kind'].inspect})", fails)
  check(zone.dig('channels', 'detail'), 'detail encoding is preserved by parser', fails)
  check(zone.dig('channels', 'size'), 'size encoding is preserved by parser', fails)
  check(zone['series_colors'] == [
          { 'member' => 'Globex', 'color' => '#445566' },
          { 'member' => 'Acme', 'color' => '#112233' }
        ], 'explicit Tableau member colors are preserved by parser', fails)

  args = [
    'ruby', builder,
    '--tableau-dir', work,
    '--layout', layout_path,
    '--meta', layout_path.sub(/\.json$/, '-meta.json'),
    '--master-map', map_path,
    '--master-element-id', 'master',
    '--out', out_path,
    '--skip-dashboard-read', 'offline scatter regression'
  ]
  build_ok = system(*args, out: File::NULL, err: File::NULL)
  check(build_ok, 'actual chart builder emits the scatter conversion', fails)
  next unless build_ok

  elements = JSON.parse(File.read(out_path))
  scatter = elements.find { |element| element['kind'] == 'scatter-chart' }
  data_path = out_path.sub(/\.json$/, '-data-elements.json')
  data_elements = File.exist?(data_path) ? JSON.parse(File.read(data_path)) : []
  source = data_elements.find { |element| element['id'] == scatter&.dig('source', 'elementId') }

  check(!scatter.nil?, 'output contains a native Sigma scatter-chart', fails)
  check(!source.nil? && source['visibleAsSource'] == false,
        'scatter points are pre-aggregated in a hidden grouped source', fails)
  check(source&.dig('groupings', 0, 'groupBy') == ['el-customer-profitability-src-d'],
        'hidden source groups one point per Customer detail value', fails)
  x_formula = source&.dig('columns', 1, 'formula')
  y_formula = source&.dig('columns', 2, 'formula')
  check(x_formula == 'Sum([Master/Sales])',
        "Tableau Columns shelf maps Sales to the grouped X calculation (got #{x_formula.inspect})", fails)
  check(y_formula == 'Avg([Master/Profit])',
        "Tableau Rows shelf maps Profit to the grouped Y calculation with Avg (got #{y_formula.inspect})", fails)
  check(scatter&.dig('xAxis', 'columnId') == 'x-el-customer-profitability',
        'scatter xAxis points to the emitted Sales column', fails)
  check(scatter&.dig('yAxis', 'columnIds') == ['y-el-customer-profitability'],
        'scatter yAxis points to the emitted Profit column', fails)
  check(scatter&.dig('color') == {
          'by' => 'category', 'column' => 'c-el-customer-profitability',
          'scheme' => ['#112233', '#445566']
        }, 'Customer detail stays bound as category color with the explicit Tableau scheme', fails)
  check(scatter&.dig('size', 'columnId') == 'sz-el-customer-profitability',
        'Tableau Size measure maps to Sigma bubble size', fails)
  check(scatter&.dig('columns', 4, 'formula') == 'Text(IsNotNull([Customer Profitability Source/Customer]))' &&
        scatter&.dig('filters', 0, 'values') == ['true'],
        'non-null point filter uses the boolean-safe Text()/string-value shape', fails)
end

puts
if fails.empty?
  puts 'ALL PASS - Tableau scatter conversion emits grouped X/Y/detail/size semantics'
  exit 0
end

puts "FAILURES (#{fails.length}):"
fails.each { |failure| puts "  - #{failure}" }
exit 1
