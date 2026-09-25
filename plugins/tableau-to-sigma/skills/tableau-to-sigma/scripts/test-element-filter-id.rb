#!/usr/bin/env ruby
# frozen_string_literal: true
# test-element-filter-id.rb — REGRESSION PIN for beads-sigma-zjkw's M4 claim
# ("element-filter id omitted at 4 emission sites: null-dim exclusion, 2x
# native top-n, keep-list"). Re-verification on 2026-07-31 found the claim is
# FALSE on current code: commit 147e09b4 (2026-06-08, 7 weeks before the bead
# was filed) already added a centralized backfill in
# build-charts-from-signals.rb —
#   el_filters.each_with_index { |nf, i| nf['id'] = "flt-#{el_id}-#{i}" }
# — run over the SAME array object every element-filter emission site
# (including the null-dim-exclusion and native-top-n paths) pushes into. Live
# round-trip evidence: the /v2/workbooks/.../spec API rejects a filters[]
# entry with no id, so this guarantee matters — this test exists to keep it
# true, not to fix a live bug.
#
# Behaviorally exercises the ACTUAL build-charts-from-signals.rb (not the
# backfill line in isolation) across four independent emission paths on one
# dashboard, mirroring the fixture-building pattern of
# test-topn-filter-emission.rb / test-native-topn-quickfilter.rb /
# test-exclude-filter-emission.rb (synthetic .twb, empty view CSVs → built
# from .twb signals, neutral fixture names):
#
#   1. null-dim exclusion   — a plain bar chart, NO Tableau quick filter at
#                              all (build-charts-from-signals.rb ~5465)
#   2. native top-n         — literal-N `groupfilter end='top' count='10'`
#                              (~5916)
#   3. parameter-driven top-n keep-list — count driven by a workbook
#                              parameter, Rank()+keep-column idiom (~6017)
#   4. plain categorical list quick-filter — a `groupfilter function='union'`
#                              inclusive member filter (the `when 'list'` arm)
#
# Deterministic + offline + creds-free.
# Usage:  ruby scripts/test-element-filter-id.rb

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

def ws(name, filter_xml = '')
  <<~XML
    <worksheet name='#{name}'>
      <table>
        <view>
          <datasource-dependencies datasource='federated.x' />
          #{filter_xml}
        </view>
        <rows>[federated.x].[sum:TOTALREV:qk]</rows>
        <cols>[federated.x].[none:REGION:nk]</cols>
        <pane><mark class='Bar' /></pane>
      </table>
    </worksheet>
  XML
end

LIST_FILTER = <<~XML
  <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
    <groupfilter function='union' user:ui-enumeration='inclusive'>
      <groupfilter function='member' level='[none:REGION:nk]' member='&quot;Region A&quot;' />
    </groupfilter>
  </filter>
XML

TOPN_FILTER = <<~XML
  <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
    <groupfilter function='end' end='top' count='10' units='records'>
      <groupfilter function='order' direction='DESC' expression='SUM([TOTALREV])'>
        <groupfilter function='level-members' level='[none:REGION:nk]' />
      </groupfilter>
    </groupfilter>
  </filter>
XML

PARAM_TOPN_FILTER = <<~XML
  <filter class='categorical' column='[federated.x].[none:REGION:nk]'>
    <groupfilter function='end' end='top' count='[Parameters].[Parameter 7]' units='records'>
      <groupfilter function='order' direction='DESC' expression='SUM([TOTALREV])'>
        <groupfilter function='level-members' level='[none:REGION:nk]' />
      </groupfilter>
    </groupfilter>
  </filter>
XML

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook xmlns:user='http://www.tableausoftware.com/xml/user'>
    <datasources>
      <datasource caption='Params' name='Parameters'>
        <column param-domain-type='any' caption='Top Region Count' name='[Parameter 7]' datatype='integer' value='5' />
      </datasource>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      #{ws('Null Excl Chart')}
      #{ws('List Filter Chart', LIST_FILTER)}
      #{ws('Native TopN Chart', TOPN_FILTER)}
      #{ws('Param TopN Chart', PARAM_TOPN_FILTER)}
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Null Excl Chart' x='0' y='0' w='25000' h='100000' />
          <zone id='2' name='List Filter Chart' x='25000' y='0' w='25000' h='100000' />
          <zone id='3' name='Native TopN Chart' x='50000' y='0' w='25000' h='100000' />
          <zone id='4' name='Param TopN Chart' x='75000' y='0' w='25000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Region$'                    => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^TOTALREV$|^Total Revenue$'  => { 'id' => 'm-rev',    'name' => 'Total Revenue' }
}

meta = nil
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
               { 'id' => 'v1', 'name' => 'Null Excl Chart' },
               { 'id' => 'v2', 'name' => 'List Filter Chart' },
               { 'id' => 'v3', 'name' => 'Native TopN Chart' },
               { 'id' => 'v4', 'name' => 'Param TopN Chart' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  %w[v1 v2 v3 v4].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') } # empty → build from .twb signals
  # Null exclusion is evidence-driven: provide one non-null exported row for
  # this path. Signal-only worksheets intentionally no longer guess null
  # behavior and therefore emit no IsNotNull filter.
  File.write(File.join(d, 'views', 'v1.csv'), "Region,Total Revenue\nRegion A,100\n")
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  meta = JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
                        '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                        '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                        '--auto-controls', '--title', 'Dash', '--out', out],
                       err: %i[child out], &:read)
  build_log = build_log.to_s.force_encoding('UTF-8')
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

els = build_out ? (build_out.is_a?(Array) ? build_out : (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []

def find_el(els, name)
  els.find { |e| e['name'].to_s.casecmp?(name) }
end

def filter_ids_valid_and_unique?(el, fails, label)
  filters = el ? (el['filters'] || []) : []
  ok = filters.all? { |f| f['id'].is_a?(String) && !f['id'].strip.empty? }
  check(ok, "#{label}: every filters[] entry has a non-empty id (got #{filters.map { |f| f['id'] }.inspect})", fails)
  ids = filters.map { |f| f['id'] }
  check(ids.uniq.size == ids.size, "#{label}: filter ids are unique within the element (got #{ids.inspect})", fails)
  filters
end

# ---- Path 1: null-dim exclusion (no Tableau quick filter at all) -----------
null_excl_el = find_el(els, 'Null Excl Chart')
check(!null_excl_el.nil?, 'null-dim-exclusion tile built', fails)
nef = filter_ids_valid_and_unique?(null_excl_el, fails, 'null-dim-exclusion tile')
check(nef.any? { |f| f['columnId'].to_s.start_with?('nn-') },
      "null-dim-exclusion path actually fired (expected an nn-* IsNotNull filter, got #{nef.inspect})", fails)
# S11/K20: must be Text(IsNotNull(...)) + values:["true"], not boolean [true].
nn_col = (null_excl_el && (null_excl_el['columns'] || []).find { |c| c['id'].to_s.start_with?('nn-') })
nn_f = nef.find { |f| f['columnId'].to_s.start_with?('nn-') }
check(nn_col && nn_col['formula'].to_s.start_with?('Text(IsNotNull('),
      "null-dim helper is Text(IsNotNull(...)) (got #{nn_col && nn_col['formula'].inspect})", fails)
check(nn_f && nn_f['values'] == ['true'],
      "null-dim filter values are string ['true'] (got #{nn_f && nn_f['values'].inspect})", fails)

# ---- Path 2: plain categorical list quick-filter ---------------------------
list_el = find_el(els, 'List Filter Chart')
check(!list_el.nil?, 'plain list-filter tile built', fails)
lf = filter_ids_valid_and_unique?(list_el, fails, 'list-filter tile')
check(lf.any? { |f| f['kind'] == 'list' && f['mode'] == 'include' && f['values'] == ['Region A'] },
      "plain categorical list filter actually fired (got #{lf.inspect})", fails)

# ---- Path 3: native top-n (literal N) ---------------------------------------
topn_el = find_el(els, 'Native TopN Chart')
check(!topn_el.nil?, 'native top-n tile built', fails)
tf = filter_ids_valid_and_unique?(topn_el, fails, 'native top-n tile')
check(tf.any? { |f| f['kind'] == 'top-n' && f['rowCount'] == 10 },
      "native top-n path actually fired (got #{tf.inspect})", fails)

# ---- Path 4: parameter-driven top-n keep-list -------------------------------
param_el = find_el(els, 'Param TopN Chart')
check(!param_el.nil?, 'parameter-driven top-n tile built', fails)
pf = filter_ids_valid_and_unique?(param_el, fails, 'parameter-driven top-n tile')
check(pf.any? { |f| f['kind'] == 'list' && f['mode'] == 'include' && f['values'] == ['keep'] },
      "parameter-driven top-n keep-list filter actually fired (got #{pf.inspect})", fails)

# ---- Global sweep: EVERY element's filters[] (any kind, any path) carries a
# non-empty id unique within that element — the pin this test exists for.
all_ok = els.all? do |e|
  filters = e['filters'] || []
  ids = filters.map { |f| f['id'] }
  ids.all? { |i| i.is_a?(String) && !i.strip.empty? } && ids.uniq.size == ids.size
end
check(all_ok, "every built element's filters[] entries all carry a non-empty, element-unique id (build log tail on failure below)", fails)

puts
if fails.empty?
  puts 'test-element-filter-id: ALL PASS — null-dim-exclusion, native top-n, parameter-driven top-n keep-list, ' \
       'and plain categorical list filters all emit a non-empty, element-unique id on every filters[] entry'
  exit 0
else
  puts "test-element-filter-id: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build log (tail) ---"
  puts build_log.to_s.lines.last(30).join
  exit 1
end
