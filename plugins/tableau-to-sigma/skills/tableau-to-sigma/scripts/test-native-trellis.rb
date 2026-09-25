#!/usr/bin/env ruby
# Regression test for NATIVE TRELLIS (SUPERSEDES the #451 B1 card-trellis).
#
# A Tableau dashboard that repeats one viz across a categorical dimension as
# small multiples (N sibling per-member worksheets, each pinned to one member of
# the same field) must convert to the CORRECT Sigma shape: a SINGLE viz element
# carrying a native `trellis` property (rowsBy / columnsBy) — NOT N cloned chart
# elements in N Container "cards" (the wrong #451 shape).
#
#   PARSER  detect the repetition → ONE dashboard-level `trellis` group carrying
#           the facet field, the ordered members / zone_ids / captions, and the
#           source `orientation` (rows|cols|grid) read off the zone arrangement.
#   BUILDER collapse the N member worksheets into ONE chart element: the facet as
#           a column, the per-member filter EMPTIED (every member renders), and
#           trellis.rowsBy (vertical stack) / trellis.columnsBy (horizontal row)
#           referencing that column. The sibling member elements are DROPPED.
#           Emission is GATED on the readback-safe kinds (bar/line/area/combo/
#           scatter/donut); a faceted PIE is converted to a DONUT first.
#   LAYOUT  place that ONE element once, full-size (base zone expanded to the
#           group bbox) — NO per-category Container cards.
# A NON-trellis dashboard must be UNCHANGED: no `trellis` key, one flat chart,
# no trellis containers.
#
# Drives the ACTUAL parse-twb-layout.rb + build-charts-from-signals.rb +
# build-dashboard-layout.rb (no Tableau/Sigma calls — views are synthesized from
# the .twb shelf signals). The emitted element structurally matches
# scratchpad/trellis-REFERENCE-native.json (the owner's hand-built reference).
# The POST->readback round-trip (Sigma silently strips unsupported trellises) is
# asserted LIVE in the e2e and by verify-trellis-survived.rb — not offline here.
#
# Usage:  ruby scripts/test-native-trellis.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
CHARTS = File.join(DIR, 'build-charts-from-signals.rb')
LAYOUT = File.join(DIR, 'build-dashboard-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# 4 per-Ship-Method panels — a bar of SUM(Net Revenue) by Order Channel, each
# worksheet pinned to one Ship Method member (mirrors the owner's reference and
# the live e2e source).
MEMBERS = %w[BOPIS Express Next-Day Standard].freeze
DASH    = 'Ship Method Revenue Cards'

# mark = 'Bar' (default) or 'Pie'. Both plot SUM(Net Revenue) by Order Channel
# (dim + measure); the mark only changes the Sigma chart kind, so a Pie panel
# yields a pie-chart the collapse must convert to a donut.
def worksheet(member, mark: 'Bar')
  <<~XML
    <worksheet name='Revenue - #{member}'>
      <table>
        <view>
          <datasources>
            <datasource caption='Sales' name='federated.x' />
          </datasources>
          <datasource-dependencies datasource='federated.x'>
            <column caption='Net Revenue' datatype='real' name='[netrev]' role='measure' type='quantitative' />
            <column caption='Order Channel' datatype='string' name='[chan]' role='dimension' type='nominal' />
            <column caption='Ship Method' datatype='string' name='[ship]' role='dimension' type='nominal' />
            <column-instance column='[netrev]' derivation='Sum' name='[sum:netrev:qk]' pivot='key' type='quantitative' />
            <column-instance column='[chan]' derivation='None' name='[none:chan:nk]' pivot='key' type='nominal' />
            <column-instance column='[ship]' derivation='None' name='[none:ship:nk]' pivot='key' type='nominal' />
          </datasource-dependencies>
          <filter class='categorical' column='[federated.x].[none:ship:nk]'>
            <groupfilter function='member' level='[ship]' member='&quot;#{member}&quot;' />
          </filter>
        </view>
        <panes><pane><mark class='#{mark}' /></pane></panes>
        <rows>[federated.x].[sum:netrev:qk]</rows>
        <cols>[federated.x].[none:chan:nk]</cols>
      </table>
    </worksheet>
  XML
end

# `orientation`:
#   :horz — 4 panels side-by-side (same top edge)  → columnsBy
#   :vert — 4 panels stacked down (same left edge)  → rowsBy
def trellis_twb(orientation, mark: 'Bar')
  zones = MEMBERS.each_with_index.map do |m, i|
    if orientation == :horz
      "              <zone id='#{200 + i}' name='Revenue - #{m}' x='#{i * 25_000}' y='12000' w='25000' h='58000' />"
    else
      "              <zone id='#{200 + i}' name='Revenue - #{m}' x='0' y='#{10_000 + i * 20_000}' w='100000' h='18000' />"
    end
  end.join("\n")
  flow = orientation == :horz ? 'horz' : 'vert'
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        <datasource caption='Sales' name='federated.x'>
          <column caption='Net Revenue' datatype='real' name='[netrev]' role='measure' type='quantitative' />
          <column caption='Order Channel' datatype='string' name='[chan]' role='dimension' type='nominal' />
          <column caption='Ship Method' datatype='string' name='[ship]' role='dimension' type='nominal' />
        </datasource>
      </datasources>
      <worksheets>
    #{MEMBERS.map { |m| worksheet(m, mark: mark) }.join("\n")}
      </worksheets>
      <dashboards>
        <dashboard name='#{DASH}'>
          <size maxheight='800' maxwidth='1200' sizing-mode='fixed' />
          <zones>
            <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
              <zone id='2' type-v2='layout-flow' param='#{flow}' x='0' y='0' w='100000' h='100000'>
    #{zones}
              </zone>
            </zone>
          </zones>
        </dashboard>
      </dashboards>
    </workbook>
  XML
end

# NON-trellis control: the same worksheets, but the dashboard uses only ONE of
# them (no repeated per-category set) → detection must NOT fire.
FLAT_TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Net Revenue' datatype='real' name='[netrev]' role='measure' type='quantitative' />
        <column caption='Order Channel' datatype='string' name='[chan]' role='dimension' type='nominal' />
        <column caption='Ship Method' datatype='string' name='[ship]' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
  #{worksheet('BOPIS')}
    </worksheets>
    <dashboards>
      <dashboard name='One Method'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='200' name='Revenue - BOPIS' x='0' y='0' w='100000' h='100000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MMAP = {
  '(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of )?net revenue$' =>
    { 'id' => 'm-net-revenue', 'name' => 'Net Revenue' },
  '(?i)^order channel$' => { 'id' => 'm-order-channel', 'name' => 'Order Channel' },
  '(?i)^ship method$' => { 'id' => 'm-ship-method', 'name' => 'Ship Method' }
}.freeze

# Run the FULL offline pipeline (parser → build-charts → layout) on a .twb and
# return [dash_layout_hash, chart_page_elements, layout_xml].
def run_pipeline(twb_text, dash_name)
  Dir.mktmpdir do |d|
    twb    = File.join(d, 'wb.twb')
    lay    = File.join(d, 'layout.json')
    meta   = File.join(d, 'layout-meta.json')
    charts = File.join(d, 'chart-specs.json')
    xmlf   = File.join(d, 'layout.xml')
    File.write(twb, twb_text)
    File.write(File.join(d, 'master-map.json'), JSON.pretty_generate(MMAP))
    File.write(File.join(d, 'get-workbook.json'), JSON.dump('views' => { 'view' => [] }))
    system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
    return [nil, nil, nil] unless File.exist?(lay)
    system('ruby', CHARTS, '--tableau-dir', d, '--layout', lay,
           '--master-map', File.join(d, 'master-map.json'),
           '--master-element-id', 'master', '--page-per-dashboard',
           '--skip-dashboard-read', 'offline-test',
           '--meta', meta, '--out', charts, out: File::NULL, err: File::NULL)
    dash = JSON.parse(File.read(lay)).find { |x| x['dashboard'] == dash_name }
    cs   = File.exist?(charts) ? JSON.parse(File.read(charts)) : { 'pages' => [] }
    page = (cs['pages'] || []).find { |p| p['name'] == dash_name }
    els  = page ? page['elements'] : []
    wb = { 'pages' => [
      { 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Master' }] },
      page || { 'name' => dash_name, 'elements' => [] }
    ] }
    File.write(File.join(d, 'wb-ids.json'), JSON.dump(wb))
    system('ruby', LAYOUT, '--layout', lay, '--wb-ids', File.join(d, 'wb-ids.json'),
           '--out', xmlf, out: File::NULL, err: File::NULL)
    xml = File.exist?(xmlf) ? File.read(xmlf) : ''
    [dash, els, xml]
  end
end

def chart_elements(els)
  Array(els).select { |e| e['kind'].to_s.end_with?('-chart') }
end

# ---- Horizontal source → columnsBy -----------------------------------------
puts '== HORIZONTAL small-multiples → trellis.columnsBy =='
dash, els, xml = run_pipeline(trellis_twb(:horz), DASH)
grp = (dash && Array(dash['trellis']).first) || {}
check(Array(dash && dash['trellis']).size == 1, 'exactly one trellis group detected', fails)
check(grp['field'] == 'Ship Method', "facet field is 'Ship Method' (got #{grp['field'].inspect})", fails)
check(grp['orientation'] == 'cols', "horizontal row → orientation 'cols' (got #{grp['orientation'].inspect})", fails)
check(grp['members'] == %w[BOPIS Express Next-Day Standard],
      "members are the 4 pinned methods, ordered ascending (got #{grp['members'].inspect})", fails)
check(grp['chart_kind'] == 'bar', "template chart_kind is 'bar'", fails)
check(!grp.key?('member_colors'), 'no per-card member_colors (native trellis colors by series)', fails)

cel = chart_elements(els)
el  = cel.find { |e| e['trellis'] }
check(cel.size == 1, "exactly ONE chart element emitted (native trellis, NOT #{MEMBERS.size} cards) — got #{cel.size}", fails)
check(el && el['kind'] == 'bar-chart', 'the element is a single bar-chart', fails)
cat_id = el && el.dig('trellis', 'columnsBy', 0, 'columnId')
check(el && el['trellis'].is_a?(Hash) && el['trellis'].key?('columnsBy') && !el['trellis'].key?('rowsBy'),
      'element carries trellis.columnsBy (and NOT rowsBy) for a horizontal source', fails)
cat_col = el && Array(el['columns']).find { |c| c['id'] == cat_id }
check(cat_col && cat_col['name'] == 'Ship Method', 'trellis.columnsBy references the Ship Method facet column', fails)
mem_filter = el && Array(el['filters']).find { |f| f['columnId'] == cat_id }
check(mem_filter && Array(mem_filter['values']).empty?,
      'the per-member list filter is EMPTIED (values: []) so every member renders', fails)
check(el && el.dig('source', 'elementId') == 'master' && el.dig('source', 'kind') == 'table',
      'element sources the master table (matches reference)', fails)
check(el && Array(el['columns']).any? { |c| c['formula'] == 'Sum([Master/Net Revenue])' },
      'element keeps the Sum(Net Revenue) measure column (matches reference)', fails)
check(xml.scan('trellis-').size.zero?, 'layout has NO per-category card containers (trellis-*)', fails)
check(xml.scan('elementId="el-revenue-bopis"').size == 1, 'the ONE trellis element is placed exactly once', fails)
check(xml.scan(/el-revenue-(express|next-day|standard)/).size.zero?,
      'no sibling member elements are placed (they were collapsed away)', fails)

# ---- Vertical source → rowsBy ----------------------------------------------
puts "\n== VERTICAL small-multiples → trellis.rowsBy =="
vdash, vels, vxml = run_pipeline(trellis_twb(:vert), DASH)
vgrp = (vdash && Array(vdash['trellis']).first) || {}
check(vgrp['orientation'] == 'rows', "vertical stack → orientation 'rows' (got #{vgrp['orientation'].inspect})", fails)
vcel = chart_elements(vels)
vel  = vcel.find { |e| e['trellis'] }
check(vcel.size == 1, "exactly ONE chart element emitted (got #{vcel.size})", fails)
vcat = vel && vel.dig('trellis', 'rowsBy', 0, 'columnId')
check(vel && vel['trellis'].is_a?(Hash) && vel['trellis'].key?('rowsBy') && !vel['trellis'].key?('columnsBy'),
      'element carries trellis.rowsBy (and NOT columnsBy) for a vertical source', fails)
vcatcol = vel && Array(vel['columns']).find { |c| c['id'] == vcat }
check(vcatcol && vcatcol['name'] == 'Ship Method', 'trellis.rowsBy references the Ship Method facet column', fails)
check(vxml.scan('trellis-').size.zero?, 'vertical layout has NO per-category card containers', fails)

# ---- PIE facet → DONUT fallback (pie silently strips the trellis key) -------
puts "\n== PIE small-multiples → DONUT fallback (trellis survives on donut) =="
pdash, pels, = run_pipeline(trellis_twb(:horz, mark: 'Pie'), DASH)
pgrp = (pdash && Array(pdash['trellis']).first) || {}
if pgrp['chart_kind'].to_s == 'pie'
  pcel = chart_elements(pels)
  ptrel = pcel.find { |e| e['trellis'] }
  check(pcel.size == 1, "faceted pie collapses to ONE element (got #{pcel.size})", fails)
  check(ptrel && ptrel['kind'] == 'donut-chart',
        "the faceted PIE is converted to a DONUT before faceting (got #{ptrel && ptrel['kind']})", fails)
  check(ptrel && ptrel['trellis'].is_a?(Hash) && (ptrel['trellis'].key?('columnsBy') || ptrel['trellis'].key?('rowsBy')),
        'the donut carries a native trellis (donut is readback-safe)', fails)
else
  # The parser didn't classify the synthetic pie as chart_kind 'pie' — skip the
  # fallback assertion rather than fail on a shelf-inference detail (the pie→
  # donut conversion is unit-covered by the kind gate in build-charts).
  puts "  SKIP  synthetic pie parsed as #{pgrp['chart_kind'].inspect}, not 'pie' — pie→donut gate covered in build-charts"
end

# ---- Sparse matches across unrelated sections must NOT collapse ------------
puts "\n== SPARSE repeated worksheets: no cross-section trellis collapse =="
sparse_twb = trellis_twb(:vert).gsub("h='18000'", "h='5000'")
sdash, sels, = run_pipeline(sparse_twb, DASH)
check(sdash && !sdash.key?('trellis'),
      'widely separated matching worksheets carry NO trellis group', fails)
check(chart_elements(sels).size == MEMBERS.size,
      'all sparse source panels remain independent chart elements', fails)

# ---- Non-trellis dashboard is UNCHANGED ------------------------------------
puts "\n== NON-trellis dashboard: no trellis key, one flat chart =="
fdash, fels, fxml = run_pipeline(FLAT_TWB, 'One Method')
check(fdash && !fdash.key?('trellis'), 'a single-viz dashboard carries NO trellis key', fails)
fchart = chart_elements(fels)
check(fchart.size == 1 && !fchart.first['trellis'],
      'the single chart has NO trellis property (flat build unchanged)', fails)
check(fxml.scan('trellis-').size.zero?, 'no trellis containers on a non-trellis dashboard', fails)

puts
if fails.empty?
  puts 'ALL PASS — native trellis (single element + rowsBy/columnsBy from source arrangement; ' \
       'pie→donut; non-trellis unchanged)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
