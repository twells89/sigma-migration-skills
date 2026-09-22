#!/usr/bin/env ruby
# Regression test for PR-12 emission in build-charts-from-signals.rb:
#   1. ORDERED series color scheme — a 3-channel bar (x=Month, color=Value
#      Tier, y=Net Bookings) whose .twb carries the explicit member→color map
#      {Top 500→#f2c037, Bottom 500→#c9d1d3} must emit color:{by:category,
#      scheme:[...]} with the scheme ORDERED ASCENDING BY MEMBER — scheme[0]
#      is "Bottom 500"'s grey. This is the mechanical kill for the field
#      failure where Top/Bottom-500 colors came out INVERTED (positional
#      scheme + unordered palette = a coin flip).
#   2. NUMBER FORMATS from the .twb column default-format — the measure column
#      carries $,.2f + currencySymbol (source '$#,##0.00'), NOT the name
#      heuristic (which can't know decimals and misses non-$-named measures).
#   3. formats-emitted.json — the mechanical formats-coverage artifact:
#      mapped entry for the default-format, UNMAPPED (recorded, never guessed)
#      entry for a non-translatable pill format, and a pinned series-color
#      record for the tier chart.
#   4. literal-format hazard sweep: NO emitted datetime formatString carries
#      bare letter residue (moment-style tokens print literally in Sigma).
#
# Deterministic + offline: synthesizes a .twb + view CSVs, runs the ACTUAL
# parse-twb-layout.rb + build-charts-from-signals.rb.
#
# Usage:  ruby scripts/test-series-scheme-emission.rb
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
        <column caption='Net Bookings' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' default-format='$#,##0.00' />
        <column caption='Order Date' name='[c2ec6b07-897e-39ab-9422-aa895d35a627]' datatype='date' role='dimension' type='ordinal' />
        <column caption='Value Tier' name='[a1b2c3d4-1111-2222-3333-444455556666]' datatype='string' role='dimension' type='nominal' />
        <column caption='Customer Tier' name='[c3d4e5f6-3333-4444-5555-666677778888]' datatype='string' role='dimension' type='nominal' />
        <column caption='Region' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
        <column caption='Weird Metric' name='[Weird Metric]' datatype='real' role='measure' type='quantitative' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Bookings by Tier'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Net Bookings' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Order Date' name='[c2ec6b07-897e-39ab-9422-aa895d35a627]' datatype='date' role='dimension' type='ordinal' />
              <column caption='Value Tier' name='[a1b2c3d4-1111-2222-3333-444455556666]' datatype='string' role='dimension' type='nominal' />
              <column-instance column='[c2ec6b07-897e-39ab-9422-aa895d35a627]' derivation='Month-Trunc' name='[tmn:c2ec6b07-897e-39ab-9422-aa895d35a627:qk]' pivot='key' type='quantitative' />
              <column-instance column='[a1b2c3d4-1111-2222-3333-444455556666]' derivation='None' name='[none:a1b2c3d4-1111-2222-3333-444455556666:nk]' pivot='key' type='nominal' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <style>
            <style-rule element='mark'>
              <encoding attr='color' field='[federated.fact].[none:a1b2c3d4-1111-2222-3333-444455556666:nk]' type='palette'>
                <map to='#f2c037'><bucket>&quot;Top 500&quot;</bucket></map>
                <map to='#c9d1d3'><bucket>&quot;Bottom 500&quot;</bucket></map>
              </encoding>
            </style-rule>
          </style>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[tmn:c2ec6b07-897e-39ab-9422-aa895d35a627:qk]</cols>
          <pane>
            <mark class='Bar' />
            <encodings>
              <encoding attr='color' column='[federated.fact].[none:a1b2c3d4-1111-2222-3333-444455556666:nk]' />
            </encodings>
          </pane>
        </table>
      </worksheet>
      <worksheet name='Tier Bars'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Net Bookings' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Customer Tier' name='[c3d4e5f6-3333-4444-5555-666677778888]' datatype='string' role='dimension' type='nominal' />
              <column-instance column='[c3d4e5f6-3333-4444-5555-666677778888]' derivation='None' name='[none:c3d4e5f6-3333-4444-5555-666677778888:nk]' pivot='key' type='nominal' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[none:c3d4e5f6-3333-4444-5555-666677778888:nk]</cols>
          <pane>
            <mark class='Bar' />
            <encodings>
              <color column='[federated.fact].[none:Customer Tier:nk]' />
            </encodings>
          </pane>
        </table>
      </worksheet>
      <worksheet name='Weird Metric by Region'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Region' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
              <column caption='Weird Metric' name='[Weird Metric]' datatype='real' role='measure' type='quantitative' />
              <column-instance column='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' derivation='None' name='[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]' pivot='key' type='nominal' />
              <column-instance column='[Weird Metric]' derivation='Sum' name='[sum:Weird Metric:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <style>
            <style-rule element='cell'>
              <format attr='text-format' field='[federated.fact].[sum:Weird Metric:qk]' value='0.0△' />
            </style-rule>
          </style>
          <rows>[federated.fact].[sum:Weird Metric:qk]</rows>
          <cols>[federated.fact].[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Tiers'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' name='Bookings by Tier' x='0' y='0' w='50000' h='100000' />
            <zone id='3' name='Weird Metric by Region' x='50000' y='0' w='50000' h='100000' />
            <zone id='4' name='Tier Bars' x='0' y='0' w='50000' h='50000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Net Bookings$' => { 'id' => 'm-nb',   'name' => 'Net Bookings' },
  '(?i)^Order Date$'   => { 'id' => 'm-od',   'name' => 'Order Date' },
  '(?i)^Value Tier$'   => { 'id' => 'm-vt',   'name' => 'Value Tier' },
  '(?i)^Customer Tier$'=> { 'id' => 'm-ct',   'name' => 'Customer Tier' },
  '(?i)^Region$'       => { 'id' => 'm-reg',  'name' => 'Region' },
  '(?i)^Weird Metric$' => { 'id' => 'm-wm',   'name' => 'Weird Metric' }
}

TIER_CSV = <<~CSV
  Month of Order Date,Value Tier,Net Bookings
  2024-01-01,Top 500,1200.50
  2024-01-01,Bottom 500,300.25
  2024-02-01,Top 500,1400.00
  2024-02-01,Bottom 500,410.10
CSV

WEIRD_CSV = <<~CSV
  Region,Weird Metric
  East,12.5
  West,9.1
CSV

TIER_BARS_CSV = <<~CSV
  Customer Tier,Net Bookings
  Platinum,1200.50
  Silver,800.25
  Gold,500.00
  Bronze,200.10
CSV

build_out = nil
build_log = ''
formats_emitted = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [
               { 'id' => 'v1', 'name' => 'Bookings by Tier' },
               { 'id' => 'v2', 'name' => 'Weird Metric by Region' },
               { 'id' => 'v3', 'name' => 'Tier Bars' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), TIER_CSV)
  File.write(File.join(d, 'views', 'v2.csv'), WEIRD_CSV)
  File.write(File.join(d, 'views', 'v3.csv'), TIER_BARS_CSV)
  File.write(File.join(d, 'png-read.json'),
             JSON.dump('source_png' => 'views/v1.png',
                       'tiles' => [{ 'title' => 'Bookings by Tier', 'kind' => 'bar-chart', 'orientation' => 'vertical' },
                                   { 'title' => 'Weird Metric by Region', 'kind' => 'bar-chart', 'orientation' => 'vertical' },
                                   { 'title' => 'Tier Bars', 'kind' => 'bar-chart', 'orientation' => 'vertical' }],
                       'text_elements' => [], 'filter_shelf' => []))
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  parsed_layout = JSON.parse(File.read(lay))
  parsed_layout.first['brand_palette'] = %w[#4e79a7 #f28e2b #e15759 #76b7b2 #59a14f]
  File.write(lay, JSON.dump(parsed_layout))
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm, '--master-element-id', 'master', '--out', out], err: %i[child out], &:read)
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
  fe_path = File.join(d, 'formats-emitted.json')
  formats_emitted = JSON.parse(File.read(fe_path)) if File.exist?(fe_path)
end

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []
tier  = els.find { |e| e['name'].to_s.casecmp?('Bookings by Tier') }
weird = els.find { |e| e['name'].to_s.casecmp?('Weird Metric by Region') }
same_axis_color = els.find { |e| e['name'].to_s.casecmp?('Tier Bars') }

# ---- 1. ORDERED series scheme ----------------------------------------------
color = tier && tier['color']
check(color.is_a?(Hash) && color['by'] == 'category',
      "tier chart colors by category (got #{color.inspect})", fails)
check(color && color['scheme'] == %w[#c9d1d3 #f2c037],
      "scheme ORDERED ascending by member — Bottom 500's grey first, Top 500's gold second " \
      "(the inversion kill; got #{color && color['scheme'].inspect})", fails)
check(build_log.include?('series colors PINNED'),
      'builder logged the pinned member→color ordering', fails)
check(same_axis_color && same_axis_color.dig('color', 'by') == 'category',
      "axis+Color-shelf chart emits a category color channel (got #{same_axis_color && same_axis_color['color'].inspect})", fails)
check(same_axis_color && same_axis_color.dig('color', 'column') != same_axis_color.dig('xAxis', 'columnId'),
      'axis+Color-shelf chart uses a duplicate column to satisfy channel exclusivity', fails)
check(same_axis_color && same_axis_color.dig('color', 'scheme') ==
        %w[#76b7b2 #e15759 #4e79a7 #f28e2b],
      "source member order is rebound to Sigma's alphabetical color slots " \
      "(got #{same_axis_color && same_axis_color.dig('color', 'scheme').inspect})", fails)
check(same_axis_color && same_axis_color['legend'] == { 'visibility' => 'hidden' },
      'color channel hides Sigma default legend when Tableau has no legend zone', fails)

# ---- 2. number format from the column default-format ------------------------
ycol = tier && (tier['columns'] || []).find { |c| tier.dig('yAxis', 'columnIds')&.include?(c['id']) }
check(ycol && ycol['format'] == { 'kind' => 'number', 'formatString' => '$,.2f', 'currencySymbol' => '$' },
      "measure format from .twb default-format '$#,##0.00' → $,.2f + $ (got #{ycol && ycol['format'].inspect})", fails)

# ---- 3. formats-emitted.json (mechanical coverage artifact) -----------------
check(formats_emitted.is_a?(Hash) && formats_emitted['version'] == 1,
      'formats-emitted.json written next to --out', fails)
entries = (formats_emitted || {})['entries'] || []
nb = entries.find { |r| r['field'] == 'Net Bookings' }
check(nb && nb['status'] == 'mapped' && nb['source_format'] == '$#,##0.00' &&
      nb.dig('emitted_format', 'formatString') == '$,.2f',
      "Net Bookings entry: source string + emitted format + status=mapped (got #{nb.inspect})", fails)
wm = entries.find { |r| r['field'].to_s =~ /weird metric/i }
check(wm && wm['status'] == 'unmapped' && wm['source_format'] == '0.0△',
      "non-translatable pill format RECORDED as unmapped, never guessed (got #{wm.inspect})", fails)
scm = ((formats_emitted || {})['series_color_maps'] || []).find { |r| r['worksheet'] == 'Bookings by Tier' }
check(scm && scm['status'] == 'pinned' && scm['emitted_scheme'] == %w[#c9d1d3 #f2c037],
      "series-color map record: status=pinned + the ordered scheme (got #{scm.inspect})", fails)

# ---- 4. literal-format hazard sweep -----------------------------------------
bad = els.flat_map { |e| e['columns'] || [] }
         .map { |c| c['format'] }
         .select { |f| f.is_a?(Hash) && f['kind'] == 'datetime' }
         .reject { |f| f['formatString'].to_s.gsub(/%-?[A-Za-z]/, '') !~ /[A-Za-z]/ }
check(bad.empty?,
      "no emitted datetime formatString carries bare letter residue (moment tokens print literally; got #{bad.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — PR-12 emission: ordered series scheme + source number formats + formats-emitted artifact'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(25).join
  exit 1
end
