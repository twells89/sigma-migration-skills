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
# Deterministic + offline + CREDS-FREE: drives the ACTUAL build-charts-from-
# signals.rb against committed parser-output fixtures (test-fixtures/topn-*.json,
# generated once from a 2-bar-chart .twb — clean + LOD — via parse-twb-layout).
# We feed build-charts directly (NOT the nokogiri-backed parser) so this runs in
# the creds-free CI ruby. To regenerate the fixtures, see the heredoc TWB in the
# git history of this file / run parse-twb-layout on it.
#
# Usage:  ruby scripts/test-topn-filter-emission.rb

require 'json'
require 'tmpdir'

DIR     = __dir__
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
FIXTURE = File.join(DIR, 'test-fixtures')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# The two fixtures model bar charts of Partner Name (dim) × SUM(Net Revenue) with
# a boolean rank calc on the Filters shelf kept on `true`:
#   Top 25 Partners      → RANK_UNIQUE(SUM([Net Revenue]))<=25                      (clean)
#   Top 10 Partners LOD  → RANK_UNIQUE(sum({exclude [Seg]:sum([Net Revenue])}))<=10 (LOD)
MASTER_MAP = {
  '(?i)^Net Revenue$'  => { 'id' => 'm-nr', 'name' => 'Net Revenue' },
  '(?i)^Partner Name$' => { 'id' => 'm-pn', 'name' => 'Partner Name' }
}

build_out = nil
build_log = ''
Dir.mktmpdir do |d|
  lay  = File.join(d, 'layout.json')
  meta = File.join(d, 'layout-meta.json')
  mm   = File.join(d, 'master-map.json')
  File.write(lay,  File.read(File.join(FIXTURE, 'topn-layout.json')))
  File.write(meta, File.read(File.join(FIXTURE, 'topn-layout-meta.json')))
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [
               { 'id' => 'v1', 'name' => 'Top 25 Partners' },
               { 'id' => 'v2', 'name' => 'Top 10 Partners LOD' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')   # empty → build from .twb signals
  File.write(File.join(d, 'views', 'v2.csv'), '')
  out = File.join(d, 'specs.json')
  build_log = `ruby #{BUILD} --tableau-dir #{d} --layout #{lay} --meta #{meta} --master-map #{mm} --master-element-id master --title Dash --out #{out} 2>&1`
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
check(build_log =~ /top-N filter.*(?:LOD|untranslatable)/m,
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
