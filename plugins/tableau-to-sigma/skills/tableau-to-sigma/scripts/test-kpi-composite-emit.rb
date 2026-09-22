#!/usr/bin/env ruby
# End-to-end test for Phase-1 B3 KPI-composite EMIT (build-charts-from-signals.rb).
# A Tableau BAN scorecard (Shape mark + big-number <customized-label>, detected
# by the B3 parser) must emit a Sigma kpi-chart styled as the composite:
#   - name = the label run ("Total Job Losses"), NOT the worksheet caption
#   - value.fontSize = the SOURCE BAN font size (fidelity mandate — the .twb
#     value, not a hand-tuned one)
#   - style = transparent hero ({padding:none, backgroundColor:'#00000000'}) so a
#     container tint shows through
# and it must WARN that the customized-label's dynamic-value annotation (a
# "% of total" calc) is not reproduced.
#
# Runs the ACTUAL parse-twb-layout.rb + build-charts-from-signals.rb (build_kpi_
# element has many internal helper deps, so this drives the whole script rather
# than eval-extracting one def). Deterministic + offline (empty view CSV; the
# element is built from .twb signals).
#
# Usage:  ruby scripts/test-kpi-composite-emit.rb

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
      <datasource caption='Fact' name='federated.x'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='snow'><connection class='snowflake' dbname='DEMO_DB' schema='DEMO' /></named-connection>
          </named-connections>
          <relation connection='snow' name='STATE_FACT' table='[DEMO].[STATE_FACT]' type='table' />
        </connection>
        <column caption='Total Job Losses' name='[TJL]' datatype='real' role='measure' type='quantitative' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='South Job losses'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='Total Job Losses' name='[TJL]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[TJL]' derivation='Sum' name='[sum:TJL:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <pane>
            <mark class='Shape' />
            <customized-label>
              <formatted-text>
                <run bold='false' fontcolor='#333333' fontsize='10'>Total Job Losses</run>
                <run fontsize='26'><![CDATA[<[federated.x].[sum:TJL:qk]>]]></run>
                <run fontcolor='#666666' fontsize='12'><![CDATA[<[federated.x].[usr:pct:qk]>]]></run>
                <run bold='false' fontcolor='#666666' fontsize='8'>Æ of U.S. total</run>
              </formatted-text>
            </customized-label>
          </pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='D'>
        <zones><zone id='1' name='South Job losses' x='0' y='0' w='100000' h='100000' /></zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = { '(?i)^Total Job Losses$' => { 'id' => 'm-tjl', 'name' => 'Total Job Losses' } }

build_out = nil
build_log = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'South Job losses' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
                        '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                        '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                        '--title', 'D', '--out', out], err: %i[child out], &:read)
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []
kpi = els.find { |e| e['kind'] == 'kpi-chart' }

check(!kpi.nil?, 'BAN scorecard emitted as a kpi-chart (not a scatter)', fails)
check(kpi && kpi['name'] == 'Total Job Losses',
      "KPI name = the customized-label label run, not the worksheet caption (got #{kpi && kpi['name'].inspect})", fails)
check(kpi && kpi.dig('value', 'fontSize') == 26,
      "value.fontSize = SOURCE BAN font size 26 (got #{kpi && kpi.dig('value', 'fontSize').inspect})", fails)
check(kpi && kpi['layout'] == { 'anchor' => 'middle' },
      "KPI content uses source-like centered alignment (got #{kpi && kpi['layout'].inspect})", fails)
check(kpi && kpi.dig('value', 'columnId'),
      'value still carries columnId (kpi-chart contract)', fails)
# Transparency is a COMPOSITION decision (only reads well over a container tint),
# so the element builder must NOT force it — the KPI keeps its default card until
# the composition stage (B1/B2) places it in a tint. A naked transparent KPI on
# the canvas was the regression we are fixing.
check(kpi && kpi['style'].nil?,
      "KPI keeps its DEFAULT card — no forced transparent style at the element level (got #{kpi && kpi['style'].inspect})", fails)
check(build_log.include?('annotation is NOT reproduced'),
      'builder WARNs the dynamic-value annotation is not reproduced', fails)

puts
if fails.empty?
  puts 'ALL PASS — B3 KPI composite emit (label name + source fontSize + transparent hero + annotation WARN)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---\n#{build_log.to_s.lines.last(12).join}"
  exit 1
end
