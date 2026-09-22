#!/usr/bin/env ruby
# Regression test for D2 (PR-13) in build-charts-from-signals.rb +
# lib/series_colors.rb — dashboard-wide per-category color consistency:
#
#   1. A chart that colors by a categorical field but carries NO explicit
#      member→color map of its own must inherit the ORDERED scheme merged from
#      SIBLING zones on the same dashboard that color by a MATCHING field with
#      explicit .twb assignments (Tableau only serializes the map on
#      worksheets where the author touched the legend). Before D2 the unpinned
#      sibling fell to the positional theme palette, so the same region
#      changed color chart-to-chart.
#   2. The sibling pin uses the same ascending-member ordering contract as
#      the own-zone pin (Sigma applies `scheme` positionally in category-sort
#      order), so member→color binding survives.
#   3. A chart colored by an UNRELATED field inherits nothing — gluing
#      different fields onto one dict would be worse than the theme palette.
#   4. The own-zone explicit map still wins where present (PR-12 unchanged).
#
# Deterministic + offline: synthesizes a .twb + view CSVs, runs the ACTUAL
# parse-twb-layout.rb + build-charts-from-signals.rb.
#
# Usage:  ruby scripts/test-series-color-consistency.rb
require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

REGION_GUID = '[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]'
DATE_GUID   = '[c2ec6b07-897e-39ab-9422-aa895d35a627]'
SALES_GUID  = '[33b6c718-9b55-3dc0-9698-d1d57fac0f90]'
PROFIT_GUID = '[44c7d829-0c66-4ed1-a7a9-e2e68fbd1a01]'
TIER_GUID   = '[a1b2c3d4-1111-2222-3333-444455556666]'

def sheet(name, meas_caption, meas_guid, color_guid, style_maps)
  <<~XML
    <worksheet name='#{name}'>
      <table>
        <view>
          <datasource-dependencies datasource='federated.fact'>
            <column caption='#{meas_caption}' name='#{meas_guid}' datatype='real' role='measure' type='quantitative' />
            <column caption='Order Date' name='#{DATE_GUID}' datatype='date' role='dimension' type='ordinal' />
            <column-instance column='#{DATE_GUID}' derivation='Month-Trunc' name='[tmn:#{DATE_GUID[1..-2]}:qk]' pivot='key' type='quantitative' />
            <column-instance column='#{color_guid}' derivation='None' name='[none:#{color_guid[1..-2]}:nk]' pivot='key' type='nominal' />
            <column-instance column='#{meas_guid}' derivation='Sum' name='[sum:#{meas_guid[1..-2]}:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies>
        </view>
        #{style_maps}
        <rows>[federated.fact].[sum:#{meas_guid[1..-2]}:qk]</rows>
        <cols>[federated.fact].[tmn:#{DATE_GUID[1..-2]}:qk]</cols>
        <pane>
          <mark class='Bar' />
          <encodings>
            <encoding attr='color' column='[federated.fact].[none:#{color_guid[1..-2]}:nk]' />
          </encodings>
        </pane>
      </table>
    </worksheet>
  XML
end

REGION_MAP_STYLE = <<~XML
  <style>
    <style-rule element='mark'>
      <encoding attr='color' field='[federated.fact].[none:#{REGION_GUID[1..-2]}:nk]' type='palette'>
        <map to='#e8519a'><bucket>&quot;West&quot;</bucket></map>
        <map to='#07b4a2'><bucket>&quot;East&quot;</bucket></map>
      </encoding>
    </style-rule>
  </style>
XML

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='ORDER_FACT' name='federated.fact'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='snow'><connection class='snowflake' dbname='DEMO_DB' schema='DEMO' /></named-connection>
          </named-connections>
          <relation connection='snow' name='ORDER_FACT' table='[DEMO].[ORDER_FACT]' type='table' />
        </connection>
        <column caption='Sales' name='#{SALES_GUID}' datatype='real' role='measure' type='quantitative' />
        <column caption='Profit' name='#{PROFIT_GUID}' datatype='real' role='measure' type='quantitative' />
        <column caption='Order Date' name='#{DATE_GUID}' datatype='date' role='dimension' type='ordinal' />
        <column caption='Region' name='#{REGION_GUID}' datatype='string' role='dimension' type='nominal' />
        <column caption='Value Tier' name='#{TIER_GUID}' datatype='string' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
      #{sheet('Sales by Month', 'Sales', SALES_GUID, REGION_GUID, REGION_MAP_STYLE)}
      #{sheet('Profit by Month', 'Profit', PROFIT_GUID, REGION_GUID, '')}
      #{sheet('Sales by Tier', 'Sales', SALES_GUID, TIER_GUID, '')}
    </worksheets>
    <dashboards>
      <dashboard name='Regions'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' name='Sales by Month' x='0' y='0' w='33000' h='100000' />
            <zone id='3' name='Profit by Month' x='33000' y='0' w='33000' h='100000' />
            <zone id='4' name='Sales by Tier' x='66000' y='0' w='34000' h='100000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Sales$'      => { 'id' => 'm-sal', 'name' => 'Sales' },
  '(?i)^Profit$'     => { 'id' => 'm-pro', 'name' => 'Profit' },
  '(?i)^Order Date$' => { 'id' => 'm-od',  'name' => 'Order Date' },
  '(?i)^Region$'     => { 'id' => 'm-reg', 'name' => 'Region' },
  '(?i)^Value Tier$' => { 'id' => 'm-vt',  'name' => 'Value Tier' }
}

SALES_CSV = <<~CSV
  Month of Order Date,Region,Sales
  2024-01-01,West,1200.50
  2024-01-01,East,300.25
  2024-02-01,West,1400.00
  2024-02-01,East,410.10
CSV

PROFIT_CSV = <<~CSV
  Month of Order Date,Region,Profit
  2024-01-01,West,120.00
  2024-01-01,East,30.00
  2024-02-01,West,140.00
  2024-02-01,East,41.00
CSV

TIER_CSV = <<~CSV
  Month of Order Date,Value Tier,Sales
  2024-01-01,Top 500,900.00
  2024-01-01,Bottom 500,600.75
  2024-02-01,Top 500,980.00
  2024-02-01,Bottom 500,830.10
CSV

build_out = nil
build_log = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [
               { 'id' => 'v1', 'name' => 'Sales by Month' },
               { 'id' => 'v2', 'name' => 'Profit by Month' },
               { 'id' => 'v3', 'name' => 'Sales by Tier' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), SALES_CSV)
  File.write(File.join(d, 'views', 'v2.csv'), PROFIT_CSV)
  File.write(File.join(d, 'views', 'v3.csv'), TIER_CSV)
  File.write(File.join(d, 'png-read.json'),
             JSON.dump('source_png' => 'views/v1.png',
                       'tiles' => [{ 'title' => 'Sales by Month', 'kind' => 'bar-chart', 'orientation' => 'vertical' },
                                   { 'title' => 'Profit by Month', 'kind' => 'bar-chart', 'orientation' => 'vertical' },
                                   { 'title' => 'Sales by Tier', 'kind' => 'bar-chart', 'orientation' => 'vertical' }],
                       'text_elements' => [], 'filter_shelf' => []))
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm, '--master-element-id', 'master', '--out', out], err: %i[child out], &:read)
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []
sales  = els.find { |e| e['name'].to_s.casecmp?('Sales by Month') }
profit = els.find { |e| e['name'].to_s.casecmp?('Profit by Month') }
tier   = els.find { |e| e['name'].to_s.casecmp?('Sales by Tier') }

PINNED = %w[#07b4a2 #e8519a] # ascending member order: East → West

# ---- 1. own-zone explicit map still wins (PR-12 path unchanged) --------------
sc = sales && sales['color']
check(sc.is_a?(Hash) && sc['by'] == 'category', "explicit-map chart colors by category (got #{sc.inspect})", fails)
check(sc && sc['scheme'] == PINNED,
      "explicit-map chart: scheme ordered ascending by member — East's teal first (got #{sc && sc['scheme'].inspect})", fails)
check(build_log.include?('series colors PINNED'), 'own-zone pin logged (PR-12 path)', fails)

# ---- 2. sibling chart WITHOUT an own map inherits the shared dict (D2) -------
pc = profit && profit['color']
check(pc.is_a?(Hash) && pc['by'] == 'category', "unpinned sibling colors by category (got #{pc.inspect})", fails)
check(pc && pc['scheme'] == PINNED,
      "sibling chart inherits the SAME ordered scheme — same region, same color everywhere (got #{pc && pc['scheme'].inspect})", fails)
check(build_log.include?("pinned from a SIBLING chart's explicit .twb map"),
      'sibling pin is logged (stated, never silent)', fails)

# ---- 3. unrelated field never inherits the sibling's explicit member map -----
tc = tier && tier['color']
check(tc.is_a?(Hash) && tc['scheme'].is_a?(Array) &&
      tc['scheme'] != %w[#07b4a2 #e8519a],
      "different-field chart uses its own source-order palette, not the sibling's member map " \
      "(got #{tc.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — D2 per-category color consistency: sibling charts share one ordered category→color dict'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(25).join
  exit 1
end
