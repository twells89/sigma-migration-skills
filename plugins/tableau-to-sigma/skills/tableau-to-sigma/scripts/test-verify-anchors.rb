#!/usr/bin/env ruby
# frozen_string_literal: true
# Tests for scripts/verify-anchors.rb — the measured value bar.
#
#   1. Pure core (AnchorVerify): label→element fuzzy match by token overlap,
#      sigma_element_hint priority, found-elsewhere-still-matches, missing
#      anchors carry a best_candidate, cell parsing ($/,/%/parens).
#   2. CLI offline mode (--workbook-spec + --exports-dir): verdict file shape
#      (checked/matched/missing/pass), exit codes (0 all matched / 1 miss /
#      2 usage), and the parity-final.json `anchors` stamp.
#
# Offline, no network. Usage: ruby scripts/test-verify-anchors.rb

require 'json'
require 'csv'
require 'open3'
require 'tmpdir'
require 'rbconfig'

ENV['VERIFY_ANCHORS_CLI'] = nil
require_relative 'verify-anchors' # loads AnchorVerify (CLI guarded out)

SCRIPT = File.join(__dir__, 'verify-anchors.rb')

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '-- pure core: element ranking --'
els = ['Top Accounts', 'Revenue Trend', 'YoY Growth by Region', 'KPI Row']
a_label = { 'id' => 'a1', 'panel' => 'TOP ACCOUNTS', 'label' => 'United Widgets revenue', 'raw' => '12,345B' }
ok(AnchorVerify.ranked_elements(a_label, els).first == 'Top Accounts',
   'panel/label token overlap ranks the right element first')
ok(AnchorVerify.ranked_elements(a_label, els).length == els.length,
   'zero-score elements are appended (search everywhere)')
a_hint = a_label.merge('sigma_element_hint' => 'YoY Growth by Region')
ok(AnchorVerify.ranked_elements(a_hint, els).first == 'YoY Growth by Region',
   'sigma_element_hint wins over panel/label overlap')
a_hint_fuzzy = a_label.merge('sigma_element_hint' => 'yoy region growth')
ok(AnchorVerify.ranked_elements(a_hint_fuzzy, els).first == 'YoY Growth by Region',
   'non-exact hint still matches by token overlap')

puts '-- pure core: cell parsing --'
ok(AnchorVerify.cell_numbers('$1,234.50') == [1234.5], 'currency + commas parse')
ok(AnchorVerify.cell_numbers('(42)') == [-42.0], 'paren negative parses')
ok(AnchorVerify.cell_numbers('12%') == [12.0, 0.12], 'percent cell keeps points + fraction')
ok(AnchorVerify.cell_numbers('United Widgets').empty?, 'non-numeric cell yields nothing')
ok(AnchorVerify.cell_numbers('').empty? && AnchorVerify.cell_numbers(nil).empty?, 'empty/nil cells yield nothing')

puts '-- pure core: verify() verdicts --'
exports = {
  'Top Accounts' => [['Account', 'Revenue'], ['United Widgets', '12345000000000'], ['Acme Holdings', '9876000000000']],
  'Revenue Trend'     => [['Year', 'Revenue'], ['2024', '1.15e12'], ['2025', '1.2e12']],
  'KPI Row'       => [['Total Revenue', 'YoY'], ['45600000000000', '-0.02']]
}
anchors = [
  { 'id' => 'a1', 'panel' => 'TOP ACCOUNTS', 'label' => 'United Widgets revenue', 'raw' => '12,345B' },
  { 'id' => 'a2', 'panel' => 'KPI', 'label' => 'YoY change', 'raw' => '-2%', 'sigma_element_hint' => 'KPI Row' },
  { 'id' => 'a3', 'panel' => 'KPI', 'label' => 'Total Revenue', 'raw' => '45.6T' }
]
v = AnchorVerify.verify(anchors, exports)
ok(v['pass'] == true && v['matched'] == 3 && v['checked'] == 3, 'all-matched verdict passes 3/3')
ok(v['missing'].empty?, 'no missing entries when all matched')

# The field failure: the workbook renders 1.2T where the source printed 12,345B.
bad_exports = exports.merge('Top Accounts' => [['Account', 'Revenue'], ['Umbrella Corp', '1.2e12']])
v2 = AnchorVerify.verify(anchors, bad_exports)
ok(v2['pass'] == false && v2['matched'] == 2, '10x-off value fails the anchor (2/3)')
miss = v2['missing'].first
ok(miss['id'] == 'a1' && miss['raw'] == '12,345B', 'missing entry carries id + raw')
ok(miss['best_candidate'].is_a?(Hash) && miss['best_candidate']['value'] == 1.2e12,
   'best_candidate reports the closest wrong value (the 1.2T impostor)')

# found-elsewhere: value lives in a differently-named element → matched + noted
elsewhere = { 'Some Renamed Tile' => [['Revenue'], ['12345000000000']] }
v3 = AnchorVerify.verify([anchors[0]], elsewhere)
ok(v3['pass'] == true, 'value found in a non-best-match element still matches')
ok(v3['detail'].first['matched_in'] == 'Some Renamed Tile', 'detail names where it was found')

# hint discipline: a HINTED numeric anchor whose value appears ONLY in a
# hint-UNRELATED element is a MISS — NOT a false match. Field-caught in the
# PowerBI port pilot: a KPI's wrong value (10x-unit / wrong-aggregate) that
# coincidentally lived in a big detail table silently passed the old
# search-everywhere fallback. (Hint-LESS anchors keep that fallback — see v3.)
hinted_exports = {
  'Total Stores' => [['Total Stores'], ['104']],
  'Sales Detail' => [['SLS'], ['1040'], ['1600000']]
}
v4 = AnchorVerify.verify(
  [{ 'id' => 'h1', 'label' => 'Total Stores', 'raw' => '1,040', 'sigma_element_hint' => 'Total Stores' }],
  hinted_exports
)
ok(v4['pass'] == false && v4['missing'].first && v4['missing'].first['id'] == 'h1',
   'hinted numeric found only OUTSIDE the hinted element is a MISS (not a false match)')
ok(v4['missing'].first['best_candidate'] && v4['missing'].first['best_candidate']['value'] == 104.0,
   'the miss surfaces the real value (104 in the hinted element) as closest candidate')
v5 = AnchorVerify.verify(
  [{ 'id' => 'h2', 'label' => 'Total Stores', 'raw' => '104', 'sigma_element_hint' => 'Total Stores' }],
  hinted_exports
)
ok(v5['pass'] == true, 'hinted numeric present IN the hinted element still matches')

puts '-- pure core: anchor provenance + valued credit (PR-6 rider) --'
prov_exports = { 'KPI Row' => [['Total'], ['104']], 'Roster' => [['Name'], ['Region A']] }
prov_anchors = [
  { 'id' => 'p1', 'label' => 'Total', 'raw' => '104', 'kind' => 'number', 'provenance' => 'view-csv' },
  { 'id' => 'p2', 'label' => 'Total', 'raw' => '104', 'kind' => 'number', 'provenance' => 'png-eyeball' },
  { 'id' => 'p3', 'label' => 'Total', 'raw' => '104', 'kind' => 'number' }, # legacy: no provenance
  { 'id' => 'p4', 'label' => 'roster', 'raw' => 'Region A', 'kind' => 'text', 'provenance' => 'view-csv' }
]
vp = AnchorVerify.verify(prov_anchors, prov_exports)
ok(vp['pass'] == true && vp['matched'] == 4, 'provenance never changes MATCHING — all 4 still match')
by_id = vp['detail'].each_with_object({}) { |d, h| h[d['id']] = d }
ok(by_id['p1']['valued'] == true && by_id['p1']['provenance'] == 'view-csv',
   'view-csv numeric anchor is VALUED; detail carries provenance')
ok(by_id['p2']['valued'] == false, 'png-eyeball anchor is NOT valued (weak reading)')
ok(by_id['p3']['valued'] == false, 'legacy anchor without provenance is NOT valued (no laundering)')
ok(by_id['p4']['valued'] == false && by_id['p4']['kind'] == 'text',
   'name-only text anchor is NOT valued; detail carries kind')
ok(vp['valued_matched'] == 1, 'verdict counts valued_matched')
ok(vp['provenance_census'] == { 'view-csv' => 2, 'png-eyeball' => 1, 'unspecified' => 1 },
   "provenance census recorded (got #{vp['provenance_census'].inspect})")
ok(AnchorVerify.coverage_eligible?(prov_anchors[0]) && AnchorVerify.coverage_eligible?(prov_anchors[2]),
   'coverage credit: view-csv + legacy-unspecified numeric anchors stay eligible (back-compat)')
ok(!AnchorVerify.coverage_eligible?(prov_anchors[1]) && !AnchorVerify.coverage_eligible?(prov_anchors[3]),
   'coverage credit: png-eyeball + name-only anchors are NOT eligible')
# Missing anchors carry kind/provenance/hint so downstream consumers
# (verify-ground-truth conflict matrix) can attribute the miss to a tile.
vm = AnchorVerify.verify(
  [{ 'id' => 'pm1', 'label' => 'Total', 'raw' => '9,999', 'kind' => 'number',
     'provenance' => 'view-csv', 'sigma_element_hint' => 'KPI Row' }], prov_exports
)
m0 = vm['missing'].first
ok(m0['kind'] == 'number' && m0['provenance'] == 'view-csv' && m0['sigma_element_hint'] == 'KPI Row',
   'missing entry carries kind + provenance + sigma_element_hint')

puts '-- pure core: hinted TEXT anchors are element-scoped too (PR-6 closes the #414 remainder) --'
roster_exports = { 'Top 15 Accounts' => [['Name'], ['Acme Holdings']],
                   'Raw Feeder' => [['Name'], ['United Widgets'], ['Acme Holdings']] }
vtx = AnchorVerify.verify(
  [{ 'id' => 't1', 'label' => 'top member', 'raw' => 'United Widgets', 'kind' => 'text',
     'sigma_element_hint' => 'Top 15 Accounts' }], roster_exports
)
ok(vtx['pass'] == false && vtx['missing'].first && vtx['missing'].first['id'] == 't1',
   'hinted roster label found only OUTSIDE the hinted element is a MISS')
vtx2 = AnchorVerify.verify(
  [{ 'id' => 't2', 'label' => 'top member', 'raw' => 'United Widgets', 'kind' => 'text' }], roster_exports
)
ok(vtx2['pass'] == true, 'hint-less roster label keeps the search-everywhere fallback')

puts '-- pure core: truncated-export inconclusiveness (issue #416) --'
# A bounded (row-capped) export that came back FULL may be missing rows: an
# anchor that fails to match over it canNOT be declared MISSING — the value may
# live below the cap. It reports 'inconclusive-truncated' instead (never a hard
# MISS), and inconclusive anchors still fail `pass` (unverified != vouched-for).
trunc_exports = {
  'Big Detail'   => [['V'], ['1'], ['2'], ['3']],
  'Total Stores' => [['Stores'], ['104']]
}
vt1 = AnchorVerify.verify(
  [{ 'id' => 'tr1', 'label' => 'Detail total', 'raw' => '999', 'sigma_element_hint' => 'Big Detail' }],
  trunc_exports, truncated: ['Big Detail']
)
ok(vt1['missing'].empty? && vt1['inconclusive'].length == 1,
   'miss over a truncated in-scope export → inconclusive, NOT missing')
ok(vt1['inconclusive'].first['status'] == 'inconclusive-truncated' &&
   vt1['inconclusive'].first['truncated_elements'] == ['Big Detail'],
   'inconclusive entry carries the status + the truncated element(s)')
ok(vt1['pass'] == false && vt1['matched'] == 0,
   'inconclusive anchors still fail pass and do not count as matched')
vt2 = AnchorVerify.verify(
  [{ 'id' => 'tr2', 'label' => 'Total Stores', 'raw' => '999', 'sigma_element_hint' => 'Total Stores' }],
  trunc_exports, truncated: ['Big Detail']
)
ok(vt2['missing'].length == 1 && vt2['inconclusive'].empty?,
   'truncation OUTSIDE a hinted anchor\'s scope does not soften a genuine MISS')
vt3 = AnchorVerify.verify(
  [{ 'id' => 'tr3', 'label' => 'Nowhere Number', 'raw' => '999' }],
  trunc_exports, truncated: ['Big Detail']
)
ok(vt3['missing'].empty? && vt3['inconclusive'].length == 1,
   'hint-less miss (search-everywhere) with ANY truncated export → inconclusive')
vt4 = AnchorVerify.verify(
  [{ 'id' => 'tr4', 'label' => 'Total Stores', 'raw' => '104' }],
  trunc_exports, truncated: ['Big Detail']
)
ok(vt4['pass'] == true && vt4['matched'] == 1 && vt4['inconclusive'].empty?,
   'a matched anchor is unaffected by truncation elsewhere')
vt5 = AnchorVerify.verify(
  [{ 'id' => 'tr5', 'label' => 'roster', 'raw' => 'Region Z', 'kind' => 'text' }],
  trunc_exports, truncated: ['Big Detail']
)
ok(vt5['missing'].empty? && vt5['inconclusive'].length == 1,
   'text-anchor miss over a truncated export → inconclusive too')
# No kwarg = legacy behavior: same misses stay hard MISSes.
vt6 = AnchorVerify.verify([{ 'id' => 'tr6', 'label' => 'Nowhere Number', 'raw' => '999' }], trunc_exports)
ok(vt6['missing'].length == 1 && vt6['inconclusive'].empty?,
   'without a truncated set the legacy hard-MISS behavior is unchanged')

puts '-- CLI offline mode --'
def write_fixture(dir, exports_rows, anchors)
  elements = exports_rows.each_with_index.map do |(name, _), i|
    { 'id' => "el#{i}", 'name' => name, 'kind' => 'table' }
  end
  layout = "<Page id=\"pg1\">#{elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
  spec = { 'pages' => [{ 'id' => 'pg1', 'name' => 'P1' }],
           'elements' => elements, 'layout' => layout }
  File.write(File.join(dir, 'wb-spec.json'), JSON.pretty_generate(spec))
  exp = File.join(dir, 'exports')
  Dir.mkdir(exp)
  exports_rows.each_with_index do |(_, rows), i|
    CSV.open(File.join(exp, "el#{i}.csv"), 'w') { |c| rows.each { |r| c << r } }
  end
  File.write(File.join(dir, 'source-anchors.json'),
             JSON.pretty_generate('source_image' => 'views/dash.png',
                                  'transcribed_at' => '2026-07-08T00:00:00Z',
                                  'anchors' => anchors))
  [File.join(dir, 'wb-spec.json'), exp]
end

def run_cli(dir, spec, exp)
  Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--workbook-spec', spec, '--exports-dir', exp)
end

Dir.mktmpdir do |dir|
  spec, exp = write_fixture(dir, exports, anchors)
  File.write(File.join(dir, 'parity-final.json'),
             JSON.pretty_generate('status' => 'PASS', 'charts_total' => 3, 'charts_pass' => 3))
  out, _err, st = run_cli(dir, spec, exp)
  ok(st.exitstatus.zero?, "all matched → exit 0 (got #{st.exitstatus})")
  ok(out.include?('3/3'), 'summary reports 3/3 matched')
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  ok(vd['pass'] == true && vd['checked'] == 3 && vd['matched'] == 3 && vd['missing'] == [],
     'anchors-verdict.json carries the contract shape (checked/matched/missing/pass)')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  ok(pf['anchors'].is_a?(Hash) && pf['anchors']['pass'] == true && pf['anchors']['checked'] == 3,
     'anchors summary stamped into parity-final.json')
end

Dir.mktmpdir do |dir|
  spec, exp = write_fixture(dir, bad_exports, anchors)
  _out, err, st = run_cli(dir, spec, exp)
  ok(st.exitstatus == 1, "missing anchor → exit 1 (got #{st.exitstatus})")
  ok(err.include?('MISSING') && err.include?('12,345B'), 'per-miss report names the anchor raw value')
  ok(err.include?('closest candidate'), 'per-miss report shows the best candidate')
  ok(err.include?('loudest possible signal'), 'failure explains what a total miss means')
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  ok(vd['pass'] == false && vd['missing'].length == 1 && vd['missing'][0]['id'] == 'a1',
     'failing verdict written with the missing anchor')
end

Dir.mktmpdir do |dir|
  # no source-anchors.json at all → usage error, points at Phase 1d
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir,
                                 '--workbook-spec', '/nonexistent', '--exports-dir', dir)
  ok(st.exitstatus == 2, "missing source-anchors.json → exit 2 (got #{st.exitstatus})")
  ok(err.include?('Phase 1d'), 'missing-anchors error points at the Phase 1d transcription step')
end

Dir.mktmpdir do |dir|
  # unparseable raw → usage error (transcription contract violated)
  spec, exp = write_fixture(dir, exports, [{ 'id' => 'a1', 'label' => 'x', 'raw' => 'about twenty' }])
  _out, err, st = run_cli(dir, spec, exp)
  ok(st.exitstatus == 2, "unparseable raw → exit 2 (got #{st.exitstatus})")
  ok(err.include?('EXACTLY as printed'), 'unparseable-raw error restates the transcription rule')
end

puts '-- pure core: extract-drift tolerance --'
# The source PNG printed "104" off a frozen extract; the fresher warehouse has 106
# (~1.9% drift). Printed-precision: MISS. With extract_tol 0.03: tolerance-admitted
# match, RECORDED (tolerance_used + drift) — never a silent exact-looking pass.
drift_exports = { 'Total Stores' => [['Stores'], ['106']] }
drift_anchor  = [{ 'id' => 'd1', 'label' => 'Total Stores', 'raw' => '104' }]
vd0 = AnchorVerify.verify(drift_anchor, drift_exports)
ok(vd0['pass'] == false, 'drifted value misses at printed precision (no tolerance)')
vd1 = AnchorVerify.verify(drift_anchor, drift_exports, extract_tol: 0.03)
ok(vd1['pass'] == true, 'drifted value matches within extract_tol 0.03')
ok(vd1['detail'].first['tolerance_used'] == 0.03, 'tolerance-admitted match records tolerance_used')
d_drift = vd1['detail'].first['drift']
ok(d_drift.is_a?(Numeric) && d_drift > 0.015 && d_drift < 0.025, 'measured drift recorded (~1.9%)')
ok(vd1['matched_via_tolerance'] == 1, 'verdict counts matched_via_tolerance')
vd2 = AnchorVerify.verify(drift_anchor, drift_exports, extract_tol: 0.01)
ok(vd2['pass'] == false, 'drift beyond the tolerance still misses (0.01 < 1.9% drift)')
# Exact matches never carry tolerance_used, even when a tolerance is active.
vd3 = AnchorVerify.verify(anchors, exports, extract_tol: 0.05)
ok(vd3['pass'] == true && vd3['matched_via_tolerance'] == 0 &&
   vd3['detail'].none? { |d| d.key?('tolerance_used') },
   'exact printed-precision matches record NO tolerance_used under an active tolerance')
# Hinted-anchor scoping is enforced identically on the tolerance retry: the
# drifted value living ONLY outside the hinted element is still a MISS.
hint_scope_exports = { 'Big Detail Table' => [['V'], ['106']],
                       'Total Stores' => [['Stores'], ['999']] }
hint_anchor = [{ 'id' => 'h1', 'label' => 'Total Stores', 'raw' => '104',
                 'sigma_element_hint' => 'Total Stores' }]
vh = AnchorVerify.verify(hint_anchor, hint_scope_exports, extract_tol: 0.03)
ok(vh['pass'] == false, 'hinted anchor: tolerance retry stays scoped to hint-matched elements')
# Text anchors never use tolerance (labels do not drift numerically).
vt = AnchorVerify.verify([{ 'id' => 't1', 'label' => 'roster', 'raw' => 'Region A', 'kind' => 'text' }],
                         { 'Roster' => [['Name'], ['Region B']] }, extract_tol: 0.5)
ok(vt['pass'] == false, 'text anchor unaffected by extract_tol')

puts '-- CLI: extract-tol activation gating --'
Dir.mktmpdir do |dir|
  # NOT extract-marked → tolerance REFUSED, drifted anchor still misses.
  spec, exp = write_fixture(dir, drift_exports, drift_anchor)
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--workbook-spec', spec,
                                 '--exports-dir', exp, '--extract-tol', '0.03')
  ok(st.exitstatus == 1, "unmarked workdir: --extract-tol refused, miss → exit 1 (got #{st.exitstatus})")
  ok(err.include?('REFUSED'), 'refusal is stated loudly')
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  ok(vd['extract_tolerance'].is_a?(Hash) && vd['extract_tolerance']['active'] == false,
     'verdict records the refused tolerance request')
end
Dir.mktmpdir do |dir|
  # Extract-marked workdir (get-workbook.json hasExtracts=true) → tolerance active.
  spec, exp = write_fixture(dir, drift_exports, drift_anchor)
  File.write(File.join(dir, 'get-workbook.json'), JSON.pretty_generate('hasExtracts' => true))
  out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--workbook-spec', spec,
                                 '--exports-dir', exp, '--extract-tol', '0.03')
  ok(st.exitstatus.zero?, "extract-marked workdir: tolerance active → exit 0 (got #{st.exitstatus})")
  ok(err.include?('ACTIVE'), 'activation names the extract marker')
  ok(out.include?('EXTRACT-TOL'), 'per-anchor MATCHED line shows the tolerance admission')
  vd = JSON.parse(File.read(File.join(dir, 'anchors-verdict.json')))
  ok(vd['pass'] == true && vd['matched_via_tolerance'] == 1 &&
     vd['extract_tolerance']['active'] == true,
     'verdict carries matched_via_tolerance + active extract_tolerance')
end
Dir.mktmpdir do |dir|
  # Out-of-range tolerance is a usage error (a huge tolerance is not a measurement).
  spec, exp = write_fixture(dir, drift_exports, drift_anchor)
  File.write(File.join(dir, 'get-workbook.json'), JSON.pretty_generate('hasExtracts' => true))
  _out, _err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--workbook-spec', spec,
                                  '--exports-dir', exp, '--extract-tol', '0.9')
  ok(st.exitstatus == 2, "--extract-tol 0.9 (out of range) → exit 2 (got #{st.exitstatus})")
end

puts
if $fails.empty?
  puts 'ALL PASS — verify-anchors core + offline CLI'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
