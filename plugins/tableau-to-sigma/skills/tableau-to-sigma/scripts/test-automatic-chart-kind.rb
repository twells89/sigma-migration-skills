#!/usr/bin/env ruby
# Regression test for "Show Me"-style chart-kind inference on Tableau AUTOMATIC
# worksheets. Before this, any sheet with mark=Automatic was blindly defaulted
# to a bar chart (the #1 first-pass fidelity miss — a time series shipped as
# bars). The parser now infers the kind from the shelf structure:
#   - continuous date dim + measure        → line
#   - measure on BOTH axes (≤1 dim)         → scatter
#   - categorical dim + measure             → bar
# and flags chart_kind_inferred:true so the builder routes it to image
# confirmation (it's a guess, not a declared mark).
#
# Deterministic + offline: synthesizes a .twb with three Automatic worksheets
# and runs the ACTUAL parse-twb-layout.rb.
#
# Usage:  ruby scripts/test-automatic-chart-kind.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def ws(name, rows, cols)
  <<~XML
    <worksheet name='#{name}'>
      <table><view><datasource-dependencies datasource='federated.x' /></view>
        <rows>#{rows}</rows>
        <cols>#{cols}</cols>
        <pane><mark class='Automatic' /></pane>
      </table>
    </worksheet>
  XML
end

GR = '[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' # Gross Revenue (measure)
NP = '[a1111111-0000-0000-0000-000000000001]' # Net Profit (measure)
OD = '[c2ec6b07-897e-39ab-9422-aa895d35a627]' # Order Date (date dim)
RG = '[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' # Region (categorical dim)
CT = '[b2222222-0000-0000-0000-000000000002]' # Category (categorical dim)

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Gross Revenue' name='#{GR}' datatype='real' role='measure' />
        <column caption='Net Profit' name='#{NP}' datatype='real' role='measure' />
        <column caption='Order Date ' name='#{OD}' datatype='date' role='dimension' />
        <column caption='Region' name='#{RG}' datatype='string' role='dimension' />
        <column caption='Category' name='#{CT}' datatype='string' role='dimension' />
      </datasource>
    </datasources>
    <worksheets>
      #{ws('Trend',   "[federated.x].[sum:#{GR[1..-2]}:qk]", "[federated.x].[tmn:#{OD[1..-2]}:qk]")}
      #{ws('ByRegion', "[federated.x].[sum:#{GR[1..-2]}:qk]", "[federated.x].[none:#{RG[1..-2]}:nk]")}
      #{ws('Scatter', "[federated.x].[sum:#{NP[1..-2]}:qk]", "[federated.x].[sum:#{GR[1..-2]}:qk]")}
      #{ws('DetailList', "[federated.x].[none:#{RG[1..-2]}:nk] / [federated.x].[none:#{CT[1..-2]}:nk]", "")}
      #{ws('MultiMeasBar', "[federated.x].[none:#{RG[1..-2]}:nk]", "[Multiple Values]")}
      #{ws('DiscreteMeasTable', "[federated.x].[none:#{RG[1..-2]}:nk] / [federated.x].[sum:#{GR[1..-2]}:nk]", "")}
      #{ws('DiscreteBAN', "[federated.x].[usr:#{GR[1..-2]}:nk:1]", "")}
    </worksheets>
    <dashboards>
      <dashboard name='Dash'><zones>
        <zone id='1' name='Trend' x='0' y='0' w='33000' h='100000' />
        <zone id='2' name='ByRegion' x='33000' y='0' w='33000' h='100000' />
        <zone id='3' name='Scatter' x='66000' y='0' w='34000' h='100000' />
        <zone id='4' name='DetailList' x='0' y='100000' w='50000' h='100000' />
        <zone id='5' name='MultiMeasBar' x='50000' y='100000' w='50000' h='100000' />
        <zone id='6' name='DiscreteMeasTable' x='0' y='200000' w='50000' h='100000' />
        <zone id='7' name='DiscreteBAN' x='50000' y='200000' w='50000' h='100000' />
      </zones></dashboard>
    </dashboards>
  </workbook>
XML

zones = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  zones = JSON.parse(File.read(lay)).flat_map { |dash| dash['zones'] || [] }
end

by_name = (zones || []).each_with_object({}) { |z, h| h[z['caption']] = z if z['caption'] }
def kind(by, name); (by[name] || {})['chart_kind']; end

check(kind(by_name, 'Trend') == 'line',
      "Automatic + date dim + measure → line (got #{kind(by_name, 'Trend').inspect})", fails)
check(kind(by_name, 'ByRegion') == 'bar',
      "Automatic + categorical dim + measure → bar (got #{kind(by_name, 'ByRegion').inspect})", fails)
check(kind(by_name, 'Scatter') == 'scatter',
      "Automatic + measure on both axes → scatter (got #{kind(by_name, 'Scatter').inspect})", fails)
check((by_name['Trend'] || {})['chart_kind_inferred'] == true,
      'inferred-automatic kinds carry chart_kind_inferred:true (→ image confirmation)', fails)
check(kind(by_name, 'DetailList') == 'table',
      "Automatic + dims only, no measure axis → table (got #{kind(by_name, 'DetailList').inspect})", fails)
check(kind(by_name, 'MultiMeasBar') == 'bar',
      "Automatic + dim + [Multiple Values] pill → stays bar, not table (got #{kind(by_name, 'MultiMeasBar').inspect})", fails)
check(kind(by_name, 'DiscreteMeasTable') == 'table',
      "Automatic + dim + DISCRETE measure (nk) on shelf → table, not bar (got #{kind(by_name, 'DiscreteMeasTable').inspect})", fails)
check(kind(by_name, 'DiscreteBAN') == 'kpi',
      "Automatic + zero-dim discrete measure w/ :N instance index → kpi (got #{kind(by_name, 'DiscreteBAN').inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — Automatic worksheets infer line/bar/scatter from shelves (no blind bar default)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
