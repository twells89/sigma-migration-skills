#!/usr/bin/env ruby
# Regression test for lib/style_normalize.rb — the STYLE-NORMALIZE pass
# (v51-spec-chrome.md §5, minus SN-1 title-hide which ships via put-layout).
#
# Locks four rules plus the pass-wide guarantees:
#   SN-2  pivot-table with no `totals` key → showGrandTotals hidden (Sigma
#         default is SHOWN; Tableau crosstab default is none). An existing
#         `totals` key — any value, even {} — is NEVER touched.
#   SN-3  Excel/Tableau digit-mask formatStrings → d3 (',.1%' etc.); valid d3
#         untouched; unknown grammars warned + untouched.
#   SN-4  PercentOfTotal( columns with missing/integer-percent format → ',.1%';
#         an explicit 2-decimal choice stays.
#   SN-5  Sigma-default royal (#1a70f1/#1f73f1) dataBars/backgroundScale
#         schemes → [mix(dominant, white, 88%), dominant] derived from
#         settings.theme.overrides.categoricalScheme; no theme → untouched.
#   Plus: idempotence (second run = zero changes, byte-identical spec) and the
#   change-record shape {element_id, field, from, to, rule}.
#
# Usage:  ruby scripts/test-style-normalize.rb   (system Ruby 2.6 clean)
require 'json'
require_relative 'lib/style_normalize'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def deep_dup(o)
  Marshal.load(Marshal.dump(o))
end

# ---- SN-2: pivot totals default -------------------------------------------
puts '-- SN-2 pivot totals default'
spec = { 'pages' => [{ 'name' => 'P1', 'elements' => [
  { 'id' => 'pv-1', 'kind' => 'pivot-table', 'name' => 'Rooms' },
  { 'id' => 'pv-2', 'kind' => 'pivot-table', 'name' => 'Bi',
    'totals' => { 'showGrandTotals' => 'shown' } },
  { 'id' => 'pv-3', 'kind' => 'pivot-table', 'name' => 'Edge', 'totals' => {} },
  { 'id' => 'tb-1', 'kind' => 'table', 'name' => 'Grid' }
] }] }
ch = StyleNormalize.normalize!(spec)
els = spec['pages'][0]['elements']
check(els[0]['totals'] == { 'showGrandTotals' => 'hidden' },
      'no-totals pivot gains showGrandTotals:hidden', fails)
check(ch.length == 1 && ch[0]['rule'] == StyleNormalize::RULE_TOTALS &&
      ch[0]['element_id'] == 'pv-1' && ch[0]['field'] == 'totals' &&
      ch[0]['from'].nil? && ch[0]['to'] == { 'showGrandTotals' => 'hidden' },
      "exactly one SN-2 change, correctly shaped (got #{ch.inspect})", fails)
check(els[1]['totals'] == { 'showGrandTotals' => 'shown' },
      'explicit totals:{showGrandTotals:shown} NEVER touched', fails)
check(els[2]['totals'] == {},
      'existing totals key with empty value NEVER touched (key presence is the signal)', fails)
check(!els[3].key?('totals'), 'non-pivot element gains no totals key', fails)

# layout honor: a (future) has_grand_totals zone signal flips the default
layout = [{ 'zones' => [
  { 'kind' => 'chart', 'caption' => 'Rooms', 'has_grand_totals' => true },
  { 'kind' => 'chart', 'caption' => 'Paths' }
] }]
spec_l = { 'pages' => [{ 'elements' => [
  { 'id' => 'pv-a', 'kind' => 'pivot-table', 'name' => { 'text' => 'Rooms' } },
  { 'id' => 'pv-b', 'kind' => 'pivot-table', 'name' => 'Paths' }
] }] }
StyleNormalize.normalize!(spec_l, layout: layout)
els_l = spec_l['pages'][0]['elements']
check(els_l[0]['totals'] == { 'showGrandTotals' => 'shown' },
      'layout zone has_grand_totals:true → shown (hash-form name matched via el_name)', fails)
check(els_l[1]['totals'] == { 'showGrandTotals' => 'hidden' },
      'layout zone without the signal → hidden default stands', fails)

# ---- SN-3: d3 format grammar repair ----------------------------------------
puts '-- SN-3 format grammar repair'
def numcol(id, fs, formula = 'Sum([Master/X])', kind = 'number')
  { 'id' => id, 'name' => id, 'formula' => formula,
    'format' => { 'kind' => kind, 'formatString' => fs } }
end
spec = { 'pages' => [{ 'elements' => [{ 'id' => 'tb-f', 'kind' => 'table', 'columns' => [
  numcol('c1', '0.0%'),
  numcol('c2', '#,##0'),
  numcol('c3', '#,##0.0'),
  numcol('c4', '0%'),
  numcol('c5', ',.2%'),
  numcol('c6', '$,.2f'),
  numcol('c7', '.1%'),
  numcol('c8', '#,##0,,,B'),
  numcol('c9', '%b %Y', 'Sum([Master/X])', 'datetime'),
  numcol('c10', '$#,##0.00'),
  numcol('c11', '0.0%;(0.0%)')
] }] }] }
ch = StyleNormalize.normalize!(spec)
warns = StyleNormalize.warnings.dup
fs_of = lambda do |cid|
  spec['pages'][0]['elements'][0]['columns'].find { |c| c['id'] == cid }['format']['formatString']
end
check(fs_of.call('c1') == ',.1%',  "'0.0%' → ',.1%'", fails)
check(fs_of.call('c2') == ',.0f',  "'#,##0' → ',.0f'", fails)
check(fs_of.call('c3') == ',.1f',  "'#,##0.0' → ',.1f'", fails)
check(fs_of.call('c4') == ',.0%',  "'0%' → ',.0%'", fails)
check(fs_of.call('c5') == ',.2%',  "valid d3 ',.2%' untouched", fails)
check(fs_of.call('c6') == '$,.2f', "valid d3 '$,.2f' untouched", fails)
check(fs_of.call('c7') == '.1%',   "valid d3 '.1%' untouched", fails)
check(fs_of.call('c8') == '#,##0,,,B',
      "unknown grammar (scale+suffix '#,##0,,,B') untouched", fails)
check(warns.any? { |w| w.include?('#,##0,,,B') },
      'unknown grammar is logged to StyleNormalize.warnings', fails)
check(fs_of.call('c9') == '%b %Y', 'kind:datetime formatString untouched', fails)
check(fs_of.call('c10') == '$,.2f', "currency mask '$#,##0.00' → '$,.2f'", fails)
check(fs_of.call('c11') == '(,.1%',
      "sectioned '0.0%;(0.0%)' → paren-negative '(,.1%'", fails)
sn3 = ch.select { |c| c['rule'] == StyleNormalize::RULE_GRAMMAR }
check(sn3.length == 6, "exactly 6 SN-3 rewrites (got #{sn3.length})", fails)
check(ch.all? { |c| %w[element_id field from to rule].all? { |k| c.key?(k) } },
      'every change record carries element_id/field/from/to/rule', fails)

# ---- SN-4: PercentOfTotal precision ----------------------------------------
puts '-- SN-4 percent precision'
spec = { 'pages' => [{ 'elements' => [{ 'id' => 'pv-p', 'kind' => 'pivot-table',
  'totals' => { 'showGrandTotals' => 'hidden' }, 'columns' => [
  { 'id' => 'p1', 'formula' => 'PercentOfTotal(CountDistinct([Master/Seed]))' },
  numcol('p2', ',.0%', 'PercentOfTotal(Sum([Master/X]))'),
  numcol('p3', '.0%',  'PercentOfTotal(Sum([Master/X]))'),
  numcol('p4', ',.2%', 'PercentOfTotal(Sum([Master/X]))'),
  numcol('p5', ',.1%', 'PercentOfTotal(Sum([Master/X]))'),
  { 'id' => 'p6', 'formula' => 'Sum([Master/X])' },
  numcol('p7', '0%', 'PercentOfTotal(Sum([Master/X]))'),
  { 'id' => 'p8', 'formula' => 'PercentOfTotal(Sum([Master/X]))',
    'format' => { 'kind' => 'number' } }
] }] }] }
ch = StyleNormalize.normalize!(spec)
cols = spec['pages'][0]['elements'][0]['columns']
col = lambda { |cid| cols.find { |c| c['id'] == cid } }
check(col.call('p1')['format'] == { 'kind' => 'number', 'formatString' => ',.1%' },
      'PercentOfTotal + NO format → {kind:number, formatString:,.1%}', fails)
# v5.3: valid integer-percent formats are SOURCE-faithful and preserved
# (round-5: forcing ,.1% over a source printing "25%" cost a full waiver)
check(col.call('p2')['format']['formatString'] == ',.0%', "valid ',.0%' PRESERVED (v5.3)", fails)
check(col.call('p3')['format']['formatString'] == '.0%', "valid '.0%' PRESERVED (v5.3)", fails)
check(col.call('p4')['format']['formatString'] == ',.2%',
      "explicit 2-decimal ',.2%' stays (never override a deliberate choice)", fails)
check(col.call('p5')['format']['formatString'] == ',.1%' &&
      ch.none? { |c| c['field'].include?('[p5]') },
      "already-',.1%' records no change", fails)
check(!col.call('p6').key?('format'), 'non-PercentOfTotal column gains no format', fails)
check(col.call('p7')['format']['formatString'] == ',.0%' &&
      ch.select { |c| c['field'].include?('[p7]') }.map { |c| c['rule'] } ==
        [StyleNormalize::RULE_GRAMMAR],
      "Excel '0%' repairs to ',.0%' (SN-3) and STAYS integer-percent (v5.3: no SN-4 coercion)", fails)
check(col.call('p8')['format'] == { 'kind' => 'number', 'formatString' => ',.1%' },
      'format hash without formatString counts as missing → ,.1%', fails)

# ---- SN-5: royal default scheme guard --------------------------------------
puts '-- SN-5 default scheme guard'
themed = lambda do |cfs|
  { 'settings' => { 'theme' => { 'overrides' => { 'categoricalScheme' => ['#52baee', '#c5e8f9'] } } },
    'pages' => [{ 'elements' => [{ 'id' => 'pv-s', 'kind' => 'pivot-table',
      'totals' => {}, 'conditionalFormats' => cfs }] }] }
end
spec = themed.call([
  { 'type' => 'dataBars', 'columnIds' => %w[v1], 'scheme' => ['#eaf2ff', '#1a70f1'],
    'includeValues' => true },
  { 'type' => 'backgroundScale', 'columnIds' => %w[v2],
    'scheme' => ['#EAF2FF', '#1F73F1', '#ffffff'] },
  { 'type' => 'dataBars', 'columnIds' => %w[v3], 'scheme' => ['#a4dfc0', '#4caf7d'] },
  { 'type' => 'single', 'columnIds' => %w[v4], 'scheme' => ['#1a70f1'] }
])
ch = StyleNormalize.normalize!(spec)
cfs = spec['pages'][0]['elements'][0]['conditionalFormats']
derived = ['#eaf7fd', '#52baee'] # mix(#52baee, white, 88%) = #eaf7fd
check(cfs[0]['scheme'] == derived,
      "royal dataBars scheme → [88% tint, dominant] = #{derived.inspect}", fails)
check(cfs[1]['scheme'] == derived,
      'royal backgroundScale scheme (uppercase #1F73F1) → same derivation', fails)
check(cfs[2]['scheme'] == ['#a4dfc0', '#4caf7d'],
      'non-royal scheme is a deliberate choice — untouched', fails)
check(cfs[3]['scheme'] == ['#1a70f1'],
      "type 'single' never carries a scheme rewrite (dataBars/backgroundScale only)", fails)
check(cfs[0]['includeValues'] == true && cfs[0]['columnIds'] == %w[v1],
      'sibling conditionalFormat keys survive the scheme swap', fails)
check(ch.count { |c| c['rule'] == StyleNormalize::RULE_SCHEME } == 2,
      'exactly 2 SN-5 changes recorded', fails)

# no theme → untouched (nothing faithful to derive)
spec_nt = { 'pages' => [{ 'elements' => [{ 'id' => 'pv-nt', 'kind' => 'table',
  'conditionalFormats' => [{ 'type' => 'dataBars', 'columnIds' => %w[v1],
                             'scheme' => ['#eaf2ff', '#1a70f1'] }] }] }] }
ch = StyleNormalize.normalize!(spec_nt)
check(spec_nt['pages'][0]['elements'][0]['conditionalFormats'][0]['scheme'] ==
        ['#eaf2ff', '#1a70f1'] && ch.empty?,
      'no settings.theme.overrides.categoricalScheme → royal dataBars untouched, zero changes', fails)

# uppercase theme hue still derives (downcased) correctly
spec_uc = themed.call([{ 'type' => 'dataBars', 'columnIds' => %w[v1],
                         'scheme' => ['#1a70f1'] }])
spec_uc['settings']['theme']['overrides']['categoricalScheme'] = ['#52BAEE']
StyleNormalize.normalize!(spec_uc)
check(spec_uc['pages'][0]['elements'][0]['conditionalFormats'][0]['scheme'] == derived,
      'uppercase theme hue normalizes to the same derived scheme', fails)

# ---- el_name helper ---------------------------------------------------------
puts '-- el_name (§5.4 name-shape tolerance)'
check(StyleNormalize.el_name('name' => 'Plain') == 'Plain', 'string name → text', fails)
check(StyleNormalize.el_name('name' => { 'text' => 'Hidden', 'visibility' => 'hidden' }) == 'Hidden',
      'hash-form name → text field', fails)
check(StyleNormalize.el_name({}) == '' && StyleNormalize.el_name(nil) == '',
      'missing name / nil element → empty string', fails)

# ---- integration: full mini-spec + idempotence ------------------------------
puts '-- integration mini-spec + idempotence'
mini = {
  'name' => 'Hero Art Mini',
  'settings' => { 'theme' => { 'overrides' => { 'categoricalScheme' => ['#52baee', '#c5e8f9', '#f1f1f1'] } } },
  'pages' => [{ 'name' => 'Dashboard', 'elements' => [
    { 'id' => 'el-room', 'kind' => 'pivot-table', 'name' => 'Room Presets',
      'columns' => [
        { 'id' => 'c-room', 'formula' => '[Master/Room]', 'name' => 'Room' },
        numcol('c-share', '0.0%', 'PercentOfTotal(CountDistinct([Master/Seed]))')
      ],
      'values' => %w[c-share], 'rowsBy' => [{ 'columnId' => 'c-room' }],
      'conditionalFormats' => [{ 'type' => 'backgroundScale',
                                 'columnIds' => %w[c-share],
                                 'scheme' => ['#eaf2ff', '#1a70f1'],
                                 'includeValues' => true }] },
    { 'id' => 'el-bars', 'kind' => 'bar',
      'columns' => [numcol('c-count', '#,##0', 'CountDistinct([Master/Seed])')] },
    { 'id' => 'el-kpi', 'kind' => 'kpi-chart',
      'columns' => [{ 'id' => 'c-pot', 'formula' => 'PercentOfTotal(Sum([Master/X]))' }] }
  ] }]
}
first = StyleNormalize.normalize!(mini)
el_room = mini['pages'][0]['elements'][0]
check(el_room['totals'] == { 'showGrandTotals' => 'hidden' },
      'integration: pivot gains hidden grand totals', fails)
check(el_room['columns'][1]['format']['formatString'] == ',.1%',
      "integration: '0.0%' PercentOfTotal value ends at ',.1%'", fails)
check(el_room['conditionalFormats'][0]['scheme'] == derived,
      'integration: royal heat scheme re-derived from theme', fails)
check(mini['pages'][0]['elements'][1]['columns'][0]['format']['formatString'] == ',.0f',
      "integration: bar '#,##0' → ',.0f'", fails)
check(mini['pages'][0]['elements'][2]['columns'][0]['format'] ==
        { 'kind' => 'number', 'formatString' => ',.1%' },
      'integration: bare PercentOfTotal KPI gains ,.1% format', fails)
expected_rules = [StyleNormalize::RULE_TOTALS, StyleNormalize::RULE_GRAMMAR,
                  StyleNormalize::RULE_PERCENT, StyleNormalize::RULE_SCHEME].sort
check(first.map { |c| c['rule'] }.uniq.sort == expected_rules,
      'integration: all four rules fired exactly once each by rule id', fails)

frozen = deep_dup(mini)
second = StyleNormalize.normalize!(mini)
check(second.empty?, "idempotence: second run records ZERO changes (got #{second.inspect})", fails)
check(mini == frozen, 'idempotence: second run leaves the spec byte-identical', fails)
check(StyleNormalize.warnings.empty?, 'idempotence: second run logs no warnings', fails)

# degenerate inputs never raise
check(StyleNormalize.normalize!(nil) == [], 'nil spec → [] (no raise)', fails)
check(StyleNormalize.normalize!({}) == [], 'empty spec → [] (no raise)', fails)
check(StyleNormalize.normalize!({ 'pages' => [{ 'elements' => [{ 'kind' => 'pivot-table' }] }] }).length == 1,
      'id-less pivot still normalizes (element_id falls back)', fails)

puts
if fails.empty?
  puts 'ALL PASS — style_normalize covers SN-2..SN-5, never-override guards, idempotence'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
