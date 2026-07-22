#!/usr/bin/env ruby
# Regression test for DM-metric references in the workbook builder (bead 7bun.4).
#
# A chart/KPI measure prefers a governed [Metrics/<name>] reference over
# re-deriving the aggregation inline, when its inline aggregate matches a metric
# referenceable on the master (formula-equivalence match via the shared binder,
# lib/metric_binding.rb; strip the literal 'Master' prefix). migrate-tableau.rb
# resolves those metrics off the fact element (own + inherited via source.elementId)
# and passes them with --metrics. SAFE: no --metrics / no match → inline,
# byte-identical to before.
#
# Deterministic + offline: synthesizes a minimal .twb (a line chart of
# Month(Order Date) x SUM(Gross Revenue)), runs the ACTUAL parse-twb-layout.rb +
# build-charts-from-signals.rb with and without --metrics, and asserts the y-axis
# measure formula flips from Sum([Master/Gross Revenue]) to [Metrics/Gross Revenue].
#
# Usage:  ruby scripts/test-metric-reference.rb

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
        <column caption='Gross Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
        <column caption='Order Date ' name='[c2ec6b07-897e-39ab-9422-aa895d35a627]' datatype='date' role='dimension' type='ordinal' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Monthly Revenue Trend'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Gross Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Order Date ' name='[c2ec6b07-897e-39ab-9422-aa895d35a627]' datatype='date' role='dimension' type='ordinal' />
              <column-instance column='[c2ec6b07-897e-39ab-9422-aa895d35a627]' derivation='Month-Trunc' name='[tmn:c2ec6b07-897e-39ab-9422-aa895d35a627:qk]' pivot='key' type='quantitative' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[tmn:c2ec6b07-897e-39ab-9422-aa895d35a627:qk]</cols>
          <pane><mark class='Line' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones><zone id='1' name='Monthly Revenue Trend' x='0' y='0' w='100000' h='100000' /></zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Gross Revenue$' => { 'id' => 'm-gr', 'name' => 'Gross Revenue' },
  '(?i)^Order Date $'   => { 'id' => 'm-od', 'name' => 'Order Date ' },
  '(?i)^Order Date$'    => { 'id' => 'm-od', 'name' => 'Order Date ' }
}

# emit the same view CSV both runs; only --metrics differs
def build_ycol(metrics)
  ycol = nil
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb'); lay = File.join(d, 'layout.json'); mm = File.join(d, 'master-map.json')
    File.write(twb, TWB)
    File.write(mm, JSON.dump(MASTER_MAP))
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Monthly Revenue Trend' }] }))
    Dir.mkdir(File.join(d, 'views'))
    File.write(File.join(d, 'views', 'v1.csv'), "Month of Order Date,Gross Revenue\n2024-01,100\n")
    File.write(File.join(d, 'png-read.json'),
               JSON.dump('source_png' => 'views/v1.png',
                         'tiles' => [{ 'title' => 'Monthly Revenue Trend', 'kind' => 'line-chart' }],
                         'text_elements' => [], 'filter_shelf' => []))
    system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL) or abort 'parse-twb-layout failed'
    out = File.join(d, 'specs.json')
    cmd = ['ruby', BUILD, '--tableau-dir', d, '--layout', lay, '--master-map', mm,
           '--master-element-id', 'master', '--title', 'Dash', '--out', out]
    if metrics
      mp = File.join(d, 'metrics.json'); File.write(mp, JSON.dump(metrics)); cmd += ['--metrics', mp]
    end
    system(*cmd, out: File::NULL, err: File::NULL) or abort 'build-charts failed'
    spec = JSON.parse(File.read(out))
    els = spec.is_a?(Array) ? spec : (spec['elements'] || (spec['pages'] || []).flat_map { |p| p['elements'] || [] })
    trend = els.find { |e| e['name'].to_s.casecmp?('Monthly Revenue Trend') }
    cols = trend ? (trend['columns'] || []) : []
    ycol = trend && cols.find { |c| trend.dig('yAxis', 'columnIds')&.include?(c['id']) }
  end
  ycol && ycol['formula'].to_s
end

# 1) no --metrics → inline Sum (byte-identical fallback)
f0 = build_ycol(nil)
check(f0 =~ /\ASum\(/i && !f0.include?('[Metrics/'),
      "no --metrics: y-axis stays inline Sum(...) (got #{f0.inspect})", fails)

# 2) with a matching DM metric → governed [Metrics/<name>] reference
f1 = build_ycol([{ 'name' => 'Gross Revenue', 'formula' => 'Sum([Gross Revenue])' }])
check(f1 == '[Metrics/Gross Revenue]',
      "matching metric: y-axis binds to [Metrics/Gross Revenue] (got #{f1.inspect})", fails)

# 3) non-matching metric → inline (no false positive)
f2 = build_ycol([{ 'name' => 'Unrelated', 'formula' => 'Sum([Something Else])' }])
check(f2 =~ /\ASum\(/i && !f2.include?('[Metrics/'),
      "non-matching metric: y-axis stays inline (got #{f2.inspect})", fails)

if fails.empty?
  puts 'ALL PASS — tableau workbook measures bind to [Metrics/<name>] (byte-identical fallback)'
  exit 0
else
  puts "FAILURES:\n  - #{fails.join("\n  - ")}"
  exit 1
end
