#!/usr/bin/env ruby
# Regression test for Phase-1 B3 KPI-scorecard detection in parse-twb-layout.rb.
# Tableau "big number" scorecards frequently use a Shape/Circle mark with the
# value rendered as a <customized-label> BAN (a large-font run), e.g. the "Job
# Loss from Mass Deportations" region cards:
#   <pane><mark class='Shape'/>
#     <customized-label><formatted-text>
#       <run fontcolor='#333' fontsize='10'>Total Job Losses</run>   ← label
#       <run fontcolor='#f5f5f5' fontsize='2'>2</run>                ← invisible filler
#       <run fontsize='26'><[…measure…]></run>                       ← BAN value
#       <run fontcolor='#666' fontsize='8'>of U.S. total</run>       ← annotation
#     </formatted-text></customized-label></pane>
# Before B3 the parser mapped Shape → scatter, so is_kpi was FALSE and the KPI
# path never fired for these tiles. Detection is NARROW: only a Shape/Circle mark
# that carries a big-font customized-label BAN qualifies — an ordinary symbol
# scatter (no BAN) must stay a scatter.
#
# Asserts, end-to-end through the ACTUAL parse-twb-layout.rb:
#   1. Shape mark + BAN customized-label + zero dims → chart_kind == 'kpi'.
#   2. kpi_label = the leading label run ("Total Job Losses"); the invisible
#      tiny filler run is dropped from the label.
#   3. kpi_value_font_size = the BAN run's size (26).
#   4. kpi_annotation_runs carries the trailing annotation ("of U.S. total"),
#      with the dynamic <[…]> value run flagged ref=true and the Æ sentinel gone.
#   5. A Shape mark WITHOUT a big customized-label (a real scatter) stays
#      chart_kind == 'scatter' and is_kpi is false (narrow — no false positives).
#
# Usage:  ruby scripts/test-kpi-scorecard-detection.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')

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
        <column caption='Job Losses' name='[JL]' datatype='real' role='measure' type='quantitative' />
        <column caption='Rate' name='[RT]' datatype='real' role='measure' type='quantitative' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Region BAN'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='Job Losses' name='[JL]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[JL]' derivation='Sum' name='[sum:JL:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <pane>
            <mark class='Shape' />
            <customized-label>
              <formatted-text>
                <run bold='false' fontcolor='#333333' fontsize='10'>Total Job Losses</run>
                <run bold='false' fontcolor='#f5f5f5' fontsize='2'>2</run>
                <run fontsize='26'><![CDATA[<[federated.x].[sum:JL:qk]>]]></run>
                <run>Æ&#10;</run>
                <run fontcolor='#666666' fontsize='12'><![CDATA[<[federated.x].[usr:pct:qk]>]]></run>
                <run bold='false' fontcolor='#666666' fontsize='8'>Æ of U.S. total</run>
              </formatted-text>
            </customized-label>
          </pane>
        </table>
      </worksheet>
      <worksheet name='Scatter Plot'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='Job Losses' name='[JL]' datatype='real' role='measure' type='quantitative' />
            <column caption='Rate' name='[RT]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[JL]' derivation='Sum' name='[sum:JL:qk]' pivot='key' type='quantitative' />
            <column-instance column='[RT]' derivation='Sum' name='[sum:RT:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <rows>[federated.x].[sum:JL:qk]</rows>
          <cols>[federated.x].[sum:RT:qk]</cols>
          <pane><mark class='Shape' /></pane>
        </table>
      </worksheet>
      <worksheet name='Automatic KPI'>
        <table>
          <view><datasource-dependencies datasource='federated.x'>
            <column caption='Job Losses' name='[JL]' datatype='real' role='measure' type='quantitative' />
            <column-instance column='[JL]' derivation='Sum' name='[sum:JL:qk]' pivot='key' type='quantitative' />
          </datasource-dependencies></view>
          <pane>
            <mark class='Automatic' />
            <style><style-rule element='mark'>
              <format attr='font-size' value='32' />
            </style-rule></style>
          </pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='D'>
        <zones><zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
          <zone id='2' name='Region BAN'  x='0'     y='0' w='50000' h='100000' />
          <zone id='3' name='Scatter Plot' x='50000' y='0' w='50000' h='100000' />
          <zone id='4' name='Automatic KPI' x='0' y='0' w='25000' h='25000' />
        </zone></zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

layout = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  layout = JSON.parse(File.read(lay))
end
zones = (layout || []).find { |x| x['dashboard'] == 'D' }&.dig('zones') || []

ban = zones.find { |z| z['caption'] == 'Region BAN' }
scat = zones.find { |z| z['caption'] == 'Scatter Plot' }
automatic = zones.find { |z| z['caption'] == 'Automatic KPI' }

# ---- 1. Shape + BAN → kpi --------------------------------------------------
check(ban && ban['chart_kind'] == 'kpi',
      "Shape mark + BAN customized-label → chart_kind 'kpi' (got #{ban && ban['chart_kind'].inspect})", fails)
# ---- 2. label extracted, filler dropped ------------------------------------
check(ban && ban['kpi_label'] == 'Total Job Losses',
      "kpi_label = leading label, tiny filler run dropped (got #{ban && ban['kpi_label'].inspect})", fails)
# ---- 3. BAN font size -------------------------------------------------------
check(ban && ban['kpi_value_font_size'] == 26,
      "kpi_value_font_size = BAN run size 26 (got #{ban && ban['kpi_value_font_size'].inspect})", fails)
# ---- 4. annotation runs: trailing text + ref flag + no Æ -------------------
ann = ban && ban['kpi_annotation_runs']
check(ann.is_a?(Array) && ann.any? { |r| r['text'].to_s.include?('of U.S. total') },
      "kpi_annotation_runs carries the trailing annotation text (got #{ann.inspect})", fails)
check(ann && ann.any? { |r| r['ref'] == true },
      'the dynamic <[…]> percent run is flagged ref=true (emit strips it)', fails)
check(ann && ann.none? { |r| r['text'].to_s.include?('Æ') },
      'the Æ line-break sentinel is stripped from annotation runs', fails)
# ---- 5. NARROW: real Shape scatter stays scatter ---------------------------
check(scat && scat['chart_kind'] == 'scatter',
      "Shape mark WITHOUT a BAN stays 'scatter' (got #{scat && scat['chart_kind'].inspect})", fails)
check(scat && !scat['is_kpi'],
      "the scatter is NOT a false-positive KPI (is_kpi=#{scat && scat['is_kpi'].inspect})", fails)
check(scat && scat['kpi_label'].nil?,
      'the scatter carries no kpi_label', fails)
check(automatic && automatic['is_kpi'] && automatic['kpi_value_font_size'] == 32,
      "Automatic-mark KPI carries the source mark font size (got #{automatic && automatic['kpi_value_font_size'].inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — B3 KPI-scorecard detection (Shape/Circle + BAN → kpi; narrow, no scatter false-positives)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
