#!/usr/bin/env ruby
# Regression test for the AGGREGATE-DERIVED DIMENSION wiring (y9rd.13): a Tableau
# dimension that BUCKETS an aggregate metric (e.g. High Margin Flag =
# IF [Margin Pct] > 0.3 THEN "High" ELSE "Low" END, where Margin Pct =
# SUM([Gross Profit]) / SUM([Gross Revenue])). A metric can't be a grouping dim
# and the bucket can't be a row-level DM column, so the converter reports it as an
# `aggregate-dimension` workbookPattern (y9rd.11) and the build layer materialises
# a hidden helper CHAIN. Exercises the build-layer helpers directly (no live POST):
#   - load_aggregate_dims: indexes the pattern by caption AND its Calculation_<id>,
#     parsing the bucket's bracketed refs as the aggregate metric(s)
#   - agg_dim_for:         looks the pattern up by either key
#   - build_aggregate_dim_helper: builds the INNER grouped element + the PASSTHRU
#     element that sources it WITH groupingId (the verified table→table pattern —
#     a chart source SILENTLY DROPS groupingId and would fan the measure ×rows),
#     rewriting the bucket's refs onto the inner element
#
# Live-verified value (CSA.TJ testbed, 2026-06-28): the chain renders the bucket
# at the de-fanned warehouse total (116,557.3); a chart-direct grouped source
# fanned it to 82,172,896.5 (×705 base rows). See beads-sigma-y9rd.13.
#
# Usage:  ruby scripts/test-aggregate-dimension.rb
require 'json'
require 'set'
require 'tmpdir'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'))

%w[map_column load_aggregate_dims agg_dim_for build_aggregate_dim_helper].each do |fn|
  m = SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn} from build-charts-from-signals.rb")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# master-map carries the aggregate METRIC "Margin Pct" with a [Master/…] formula
# (rewrite_metric_formula form) + the plotted measure column.
MMAP = {
  '(?i)^Net Revenue$'  => { 'id' => 'm-nr', 'name' => 'Net Revenue' },
  '(?i)^Margin Pct$'   => { 'id' => 'm-mp', 'name' => 'Margin Pct',
                            'formula' => 'Sum([Master/Gross Profit]) / Sum([Master/Gross Revenue])' }
}
CBG = { 'Calculation_HighMarginFlag' => { 'caption' => 'High Margin Flag', 'datatype' => 'string' } }

# ---- 1. load + lookup -------------------------------------------------------
$agg_dims = []; $agg_dim_by_key = {}
meta = { 'columns_by_guid' => CBG }
patterns = { 'workbookPatterns' => [
  { 'kind' => 'aggregate-dimension', 'name' => 'High Margin Flag',
    'source' => 'If([Margin Pct] > 0.3, "High", "Low")',
    'formula' => 'If([Margin Pct] > 0.3, "High", "Low")' },
  # a param-switch in the same file must be ignored by the aggregate-dim loader
  { 'kind' => 'param-switch', 'name' => 'Ignore Me', 'controlId' => 'ctl-x', 'cases' => [] }
] }
Dir.mktmpdir do |d|
  File.write(File.join(d, 'wp.json'), JSON.dump(patterns))
  load_aggregate_dims(File.join(d, 'wp.json'), meta)
end

check($agg_dims.size == 1, 'loaded exactly 1 aggregate-dimension (param-switch ignored)', fails)
check(($agg_dims.first || {})['agg_refs'] == ['Margin Pct'], "parsed the aggregate ref(s) from the bucket (got #{($agg_dims.first || {})['agg_refs'].inspect})", fails)
check(!agg_dim_for('High Margin Flag').nil?, 'agg_dim_for resolves by caption', fails)
check(!agg_dim_for('Calculation_HighMarginFlag').nil?, 'agg_dim_for resolves by Calculation_<id> (caption bridge)', fails)
check(agg_dim_for('Net Revenue').nil?, 'agg_dim_for returns nil for a plain dim', fails)

# ---- 2. whole-table helper chain (no base dims) -----------------------------
ad = agg_dim_for('High Margin Flag')
agg_metrics = ad['agg_refs'].map { |r| mc = map_column(r, MMAP); { 'name' => mc['name'], 'formula' => mc['formula'] } }
inner, passthru, pass_name = build_aggregate_dim_helper(
  el_id: 'el-margin-flag-bar', master_id: 'master', base_dims: [],
  agg_metrics: agg_metrics, measure: { 'name' => 'Net Revenue', 'formula' => 'Sum([Master/Net Revenue])' },
  bucket_name: 'High Margin Flag', bucket_formula: ad['formula'])

# inner: grouped, sources master, computes Margin Pct + measure as group calcs.
check(inner['source'] == { 'kind' => 'table', 'elementId' => 'master' }, 'inner sources the master', fails)
check(inner['visibleAsSource'] == false, 'inner is hidden (visibleAsSource:false)', fails)
g = (inner['groupings'] || []).first || {}
ids = ->(n) { (inner['columns'].find { |c| c['name'] == n } || {})['id'] }
check(g['groupBy'] == [ids.call('All Rows')], 'inner groups by the All-Rows constant (whole table)', fails)
check((inner['columns'].find { |c| c['name'] == 'All Rows' } || {})['formula'] == '1', 'All-Rows key formula is 1', fails)
check((g['calculations'] || []).sort == [ids.call('Margin Pct'), ids.call('Net Revenue')].sort, 'inner group calcs = the metric(s) + measure', fails)
check((inner['columns'].find { |c| c['name'] == 'Margin Pct' } || {})['formula'] == 'Sum([Master/Gross Profit]) / Sum([Master/Gross Revenue])', 'inner Margin Pct keeps its [Master/…] aggregate formula', fails)
check((inner['columns'].find { |c| c['name'] == 'Net Revenue' } || {})['formula'] == 'Sum([Master/Net Revenue])', 'inner measure aggregates the master column', fails)

# passthru: sources inner WITH groupingId; bucket rewritten onto the inner.
check(passthru['source'] == { 'kind' => 'table', 'elementId' => inner['id'], 'groupingId' => g['id'] },
      "passthru sources inner WITH groupingId (got #{passthru['source'].inspect})", fails)
check(passthru['visibleAsSource'] == false, 'passthru is hidden', fails)
bk = passthru['columns'].find { |c| c['name'] == 'High Margin Flag' } || {}
check(bk['formula'] == %(If([#{inner['name']}/Margin Pct] > 0.3, "High", "Low")),
      "bucket refs rewritten onto the inner element (got #{bk['formula'].inspect})", fails)
mv = passthru['columns'].find { |c| c['name'] == 'Net Revenue' } || {}
check(mv['formula'] == "[#{inner['name']}/Net Revenue]", 'passthru carries the measure as a passthrough (no re-aggregation here)', fails)
check(passthru['groupings'].nil?, 'passthru is UNGROUPED (the chart does the bucket grouping)', fails)
check(pass_name == passthru['name'], 'returned pass_name matches the passthru element name', fails)

# ---- 3. base-dim (color) grain: inner groups by the base dim ----------------
inner2, passthru2, = build_aggregate_dim_helper(
  el_id: 'el-x', master_id: 'master',
  base_dims: [{ 'name' => 'Region', 'formula' => '[Master/Region]' }],
  agg_metrics: agg_metrics, measure: { 'name' => 'Net Revenue', 'formula' => 'Sum([Master/Net Revenue])' },
  bucket_name: 'High Margin Flag', bucket_formula: ad['formula'])
gg = (inner2['groupings'] || []).first || {}
region_id = (inner2['columns'].find { |c| c['name'] == 'Region' } || {})['id']
check(gg['groupBy'] == [region_id], 'with a base dim, inner groups by that dim (not All-Rows)', fails)
check((passthru2['columns'].find { |c| c['name'] == 'Region' } || {})['formula'] == "[#{inner2['name']}/Region]",
      'passthru carries the base dim as a passthrough (for chart color)', fails)

puts
if fails.empty?
  puts 'ALL PASS — aggregate-derived dimension: helper chain (inner grouped + passthru groupingId), bucket rewrite, base-dim grain'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
