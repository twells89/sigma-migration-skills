#!/usr/bin/env ruby
# Regression test for the Top-N FILTER idiom (bead pnxp). The real EDNA "Top 25
# Partners" tile carries a BOOLEAN calc `RANK_UNIQUE(<expr>)<=25` on the Filters
# shelf, kept on `true`. Tableau's data export hides it (it just thins rows), and
# the calc never maps to a warehouse column — so the converter used to silently
# DROP it (no top-N at all) or, worse, emit a sort-dependent RowNumber()<=N with
# the operand gone. This test locks the fix:
#
#   - CLEAN aggregate operand  → a NATIVE Sigma `kind:top-n` element filter
#     (rowCount=N, rankingFunction row-number/rank) keyed on the ranked measure,
#     plus a descending sort so the visible order matches the ranking.
#   - UNTRANSLATABLE LOD operand → NOT emitted; surfaced with an actionable note
#     (build the LOD helper measure first). Never a sort-dependent RowNumber.
#
# Deterministic + offline: synthesizes two minimal bar-chart worksheets (clean +
# LOD), runs the ACTUAL parse-twb-layout.rb + build-charts-from-signals.rb, and
# asserts the emitted element filters.
#
# Usage:  ruby scripts/test-topn-filter-emission.rb

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

# Two bar charts: Partner Name (dim) × SUM(Net Revenue) (measure). Each has a
# boolean rank calc on the Filters shelf kept on `true`:
#   Top 25 Partners      → RANK_UNIQUE(SUM([Net Revenue]))<=25         (clean)
#   Top 25 Partners LOD  → RANK_UNIQUE(SUM({exclude [Seg]:SUM([Net Revenue])}))<=10  (LOD)
# The filter column refs use the real `[usr:<name>:nk:3]` shape (guid_from_param
# returns nil for it — so the fix must match the calc by NAME substring, exactly
# like the real workbook).
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='ORDER_FACT' name='federated.fact'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='snow'><connection class='snowflake' dbname='CSA' schema='TJ' /></named-connection>
          </named-connections>
          <relation connection='snow' name='ORDER_FACT' table='[TJ].[ORDER_FACT]' type='table' />
        </connection>
        <column caption='Net Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
        <column caption='Partner Name' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Top 25 Partners'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Net Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Partner Name' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
              <column-instance column='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' derivation='None' name='[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]' pivot='key' type='nominal' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
              <column caption='Top25Flag' datatype='boolean' name='[topn_clean]' role='measure' type='nominal'>
                <calculation class='tableau' formula='RANK_UNIQUE(SUM([Net Revenue]))&lt;=25'>
                  <table-calc ordering-type='Rows' />
                </calculation>
              </column>
              <column-instance column='[topn_clean]' derivation='User' name='[usr:topn_clean:nk:3]' pivot='key' type='nominal' />
            </datasource-dependencies>
          </view>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]</cols>
          <pane><mark class='Bar' /></pane>
          <filter class='categorical' column='[federated.fact].[usr:topn_clean:nk:3]'>
            <groupfilter function='member' level='[usr:topn_clean:nk:3]' member='true' />
          </filter>
        </table>
      </worksheet>
      <worksheet name='Top 10 Partners LOD'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Net Revenue' name='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' datatype='real' role='measure' type='quantitative' />
              <column caption='Partner Name' name='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' datatype='string' role='dimension' type='nominal' />
              <column-instance column='[d73055c0-9ed1-347d-8f8e-05a48ce2c8a8]' derivation='None' name='[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]' pivot='key' type='nominal' />
              <column-instance column='[33b6c718-9b55-3dc0-9698-d1d57fac0f90]' derivation='Sum' name='[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]' pivot='key' type='quantitative' />
              <column caption='Top10FlagLOD' datatype='boolean' name='[topn_lod]' role='measure' type='nominal'>
                <calculation class='tableau' formula='RANK_UNIQUE(sum({exclude [Seg]: sum([Net Revenue])}))&lt;=10'>
                  <table-calc ordering-type='Rows' />
                </calculation>
              </column>
              <column-instance column='[topn_lod]' derivation='User' name='[usr:topn_lod:nk:3]' pivot='key' type='nominal' />
            </datasource-dependencies>
          </view>
          <rows>[federated.fact].[sum:33b6c718-9b55-3dc0-9698-d1d57fac0f90:qk]</rows>
          <cols>[federated.fact].[none:d73055c0-9ed1-347d-8f8e-05a48ce2c8a8:nk]</cols>
          <pane><mark class='Bar' /></pane>
          <filter class='categorical' column='[federated.fact].[usr:topn_lod:nk:3]'>
            <groupfilter function='member' level='[usr:topn_lod:nk:3]' member='true' />
          </filter>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Top 25 Partners' x='0' y='0' w='50000' h='100000' />
          <zone id='2' name='Top 10 Partners LOD' x='50000' y='0' w='50000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Net Revenue$'  => { 'id' => 'm-nr', 'name' => 'Net Revenue' },
  '(?i)^Partner Name$' => { 'id' => 'm-pn', 'name' => 'Partner Name' }
}

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
               { 'id' => 'v1', 'name' => 'Top 25 Partners' },
               { 'id' => 'v2', 'name' => 'Top 10 Partners LOD' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')   # empty → build from .twb signals
  File.write(File.join(d, 'views', 'v2.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  out = File.join(d, 'specs.json')
  build_log = `ruby #{BUILD} --tableau-dir #{d} --layout #{lay} --meta #{lay.sub(/\.json$/, '-meta.json')} --master-map #{mm} --master-element-id master --title Dash --out #{out} 2>&1`
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []

# ---- CLEAN aggregate operand → native Sigma top-n filter --------------------
clean = els.find { |e| e['name'].to_s.casecmp?('Top 25 Partners') }
check(!clean.nil?, 'clean top-N tile built', fails)
cfilters = clean ? (clean['filters'] || []) : []
tn = cfilters.find { |f| f['kind'] == 'top-n' }
check(!tn.nil?, "clean tile got a kind:top-n element filter (got #{cfilters.inspect})", fails)
check(tn && tn['rowCount'] == 25, "  rowCount == 25 (got #{tn && tn['rowCount'].inspect})", fails)
check(tn && tn['rankingFunction'] == 'row-number',
      "  rankingFunction == row-number (RANK_UNIQUE → unique ranks) (got #{tn && tn['rankingFunction'].inspect})", fails)
check(tn && tn['mode'] == 'top-n', "  mode == top-n (got #{tn && tn['mode'].inspect})", fails)
# Filter keys on the ranked measure column (the plotted SUM(Net Revenue)).
ranked_col = clean && (clean['columns'] || []).find { |c| c['id'] == (tn && tn['columnId']) }
check(ranked_col && ranked_col['formula'].to_s =~ /Sum\(\[Master\/Net Revenue\]\)/i,
      "  filter keyed on Sum([Master/Net Revenue]) (got #{ranked_col && ranked_col['formula'].inspect})", fails)
# Visible order follows the ranking (descending sort by the ranked measure).
srt = clean && clean.dig('xAxis', 'sort')
check(srt && srt['by'] == (tn && tn['columnId']) && srt['direction'] == 'descending',
      "  xAxis sorted by the ranked measure descending (got #{srt.inspect})", fails)

# ---- UNTRANSLATABLE LOD operand → surfaced, NOT a wrong filter --------------
lod = els.find { |e| e['name'].to_s.casecmp?('Top 10 Partners LOD') }
check(!lod.nil?, 'LOD top-N tile built', fails)
lfilters = lod ? (lod['filters'] || []) : []
check(lfilters.none? { |f| f['kind'] == 'top-n' },
      "LOD tile did NOT emit a top-n filter (operand untranslatable) (got #{lfilters.inspect})", fails)
# And no plotted column should be a sort-dependent RowNumber()<=N.
lcols = lod ? (lod['columns'] || []) : []
check(lcols.none? { |c| c['formula'].to_s =~ /RowNumber\(\)\s*<=/ },
      'LOD tile has no sort-dependent RowNumber()<=N column', fails)
check(build_log =~ /Top 10 Partners LOD.*top-N filter.*LOD/m ||
      build_log =~ /top-N filter 'Top10FlagLOD'/,
      'builder SURFACED the LOD top-N (actionable warning, not silently dropped)', fails)

puts
if fails.empty?
  puts 'ALL PASS — top-N filter idiom: clean operand → native Sigma top-n filter; LOD operand surfaced'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(30).join
  exit 1
end
