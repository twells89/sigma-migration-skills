#!/usr/bin/env ruby
# frozen_string_literal: true
# test-grounding.rb — grounding regression for build-workbook-from-pbir.rb
# (beads-sigma-kvza). Mirrors the looker-to-sigma pilot's tests/test_grounding.py.
#
# Proves the Power BI dashboard classifier is documentation-grounded and
# loud-on-unmapped:
#   1. CATALOGS      — all four refs/catalogs/*.json load, are cited (real https
#                      doc_refs), tool=powerbi, unique sources.
#   2. NO INLINE MAP — the viz/format maps are DERIVED from the catalogs and the
#                      control kinds resolved from the catalog; no residual inline
#                      literal bypasses them, and the named silent default
#                      `SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'` is GONE.
#   3. VERBATIM LOCK — the catalog-derived SIGMA_KIND / PBI_FMT carry the exact
#                      same source->target pairs the old inline literals did
#                      (behavior on already-mapped inputs is unchanged) — the
#                      offline-fixture-free stand-in for a byte-golden.
#   4. LOUD FALLBACKS — running the builder on a synthetic dashboard, an unmapped
#                      sigma_kind token AND an empty PBI visualType each WARN and
#                      record an honest 'approximated' coverage entry (never a
#                      silent bar-chart).
#   5. COVERAGE FRESH — refs/powerbi-coverage.md is regenerated from the catalogs.
#
# No LIVE API/network (Power BI has no offline dashboard fixture; the builder only
# reads/writes files). Run: ruby tests/test-grounding.rb   (exit 0 = pass)
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SKILL   = File.dirname(__dir__)
SCRIPTS = File.join(SKILL, 'scripts')
LIB     = File.join(SCRIPTS, 'lib')
CATDIR  = File.join(SKILL, 'refs', 'catalogs')
BUILDER = File.join(SCRIPTS, 'build-workbook-from-pbir.rb')
GEN     = File.join(SCRIPTS, 'gen-coverage-matrix.py')
COV_MD  = File.join(SKILL, 'refs', 'powerbi-coverage.md')
RUBY    = RbConfig.ruby
$LOAD_PATH.unshift(LIB)
require 'coverage_catalog'

$fail = 0
def ok(name, cond)
  puts((cond ? "  ok  " : "FAIL  ") + name)
  $fail += 1 unless cond
end

# ---- 1. catalogs load, cited, unique --------------------------------------
CATS = Coverage.load_all(CATDIR)
ok('four catalogs load', CATS.keys.sort == %w[aggregation control number-format viz-kind])
CATS.each do |name, cat|
  ok("#{name}: has rows", !cat.rows.empty?)
  ok("#{name}: source_tool == powerbi", cat.source_tool == 'powerbi')
  ok("#{name}: authoritative_doc is a real URL", cat.authoritative_doc.start_with?('http'))
  seen = {}
  dupes = cat.rows.map { |r| r['source'].to_s.downcase }.select { |s| (seen[s] = (seen[s] || 0) + 1) > 1 }
  ok("#{name}: unique sources", dupes.empty?)
  cited = cat.rows.all? { |r| r['doc_ref'].to_s.start_with?('http') }
  ok("#{name}: every row cites a real doc_ref URL", cited)
  mapped = cat.rows.all? { |r| !r['sigma'].to_s.empty? }
  ok("#{name}: every row has a Sigma target", mapped)
  valid_sv = cat.rows.all? do |r|
    sv = r['sigma_verified'] || {}
    %w[y n].include?(sv['status']) && (sv['status'] != 'y' || !sv['date'].to_s.empty?)
  end
  ok("#{name}: sigma_verified status is y/n and any 'y' carries a date", valid_sv)
end

# ---- 2. no residual inline map / the named silent default is gone ----------
SRC = File.read(BUILDER)
ok('builder requires the coverage_catalog loader', SRC.include?("require_relative 'lib/coverage_catalog'"))
ok('builder loads catalogs via Coverage.load', SRC.include?('Coverage.load(_CAT_DIR'))
ok('SIGMA_KIND is DERIVED from the viz-kind catalog',
   SRC.include?('VIZ_CAT.rows.each_with_object'))
ok('PBI_FMT is DERIVED from the number-format catalog',
   SRC.include?('FMT_CAT.rows.each_with_object'))
ok('control kinds are RESOLVED from the control catalog',
   SRC.include?("CTL_CAT.target('slicer')") && SRC.include?("CTL_CAT.target('slicer:date')"))
# the specific silent catch-all must be gone
ok("named silent default \"SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'\" removed",
   !SRC.include?("SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'"))
# the extracted literals must no longer live inline in the builder
ok('inline SIGMA_KIND literal removed', !SRC.include?("'kpi' => 'kpi-chart'"))
ok('inline PBI_FMT literal removed', !SRC.include?("'formatString' => '$,.0f'"))

# ---- 3. verbatim lock: derived maps == the old inline pairs ----------------
EXPECT_SIGMA_KIND = {
  'kpi' => 'kpi-chart', 'bar' => 'bar-chart', 'line' => 'line-chart',
  'area' => 'area-chart', 'combo' => 'combo-chart', 'scatter' => 'scatter-chart',
  'pie' => 'pie-chart', 'donut' => 'donut-chart', 'table' => 'table',
  'pivot-table' => 'pivot-table', 'text' => 'text', 'control' => 'control',
  'map' => 'map', 'image' => 'image'
}.freeze
derived_kind = CATS['viz-kind'].rows.each_with_object({}) { |r, h| h[r['source']] = r['sigma'] }
ok('derived SIGMA_KIND == the original 14 verbatim pairs', derived_kind == EXPECT_SIGMA_KIND)

EXPECT_FMT = { 'currency' => '$,.0f', 'percent' => '.1%', 'comma' => ',.1f', 'integer' => ',.0f' }.freeze
derived_fmt = CATS['number-format'].rows.each_with_object({}) { |r, h| h[r['source']] = r['sigma'] }
ok('derived PBI_FMT strings == the original verbatim pairs', derived_fmt == EXPECT_FMT)

ok('control catalog resolves slicer->list', CATS['control'].target('slicer') == 'list')
ok('control catalog resolves slicer:date->date-range', CATS['control'].target('slicer:date') == 'date-range')

# ---- 4. loud fallbacks: run the builder on a synthetic dashboard -----------
MMAP = {
  'masters' => {
    'EMP' => { 'id' => 'master-emp', 'element_id' => 'el-emp', 'data_model' => 'dm-x',
               'columns' => [
                 { 'id' => 'mc-dept', 'name' => 'Department', 'formula' => '[EMP/Department]' },
                 { 'id' => 'mc-hc',   'name' => 'Headcount',  'formula' => '[EMP/Headcount]' }
               ] }
  },
  'fields' => {
    'EMP.Department' => { 'master' => 'EMP', 'ref' => '[master-emp/Department]', 'agg' => nil },
    'EMP.Headcount'  => { 'master' => 'EMP', 'ref' => 'CountDistinct([master-emp/Headcount])', 'agg' => nil }
  }
}.freeze

def vis(id, vtype, kind, title)
  { 'visual_id' => id, 'visual_type' => vtype, 'sigma_kind' => kind, 'title' => title,
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => { 'Category' => ['EMP.Department'], 'Y' => ['EMP.Headcount'] },
    'sort' => nil, 'formats' => {} }
end

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'pages' => [{ 'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720,
                'interactions' => [], 'visuals' => [
                  # empty visualType (upstream coerces to the 'bar' token) — used to ship a SILENT bar-chart
                  vis('v_empty', '', 'bar', 'Empty Type Viz'),
                  # unmapped sigma_kind token — used to hit the `|| 'bar-chart'` catch-all silently
                  vis('v_bogus', 'treemap', 'zzz_bogus_token', 'Treemap Viz'),
                  # a clean native bar — MUST NOT be flagged as an approximation
                  vis('v_clean', 'barChart', 'bar', 'Clean Bar')
                ] }]
}.freeze

Dir.mktmpdir do |d|
  File.write(File.join(d, 'mmap.json'), JSON.generate(MMAP))
  File.write(File.join(d, 'sig.json'), JSON.generate(SIGNALS))
  wb  = File.join(d, 'wb.json')
  cov = File.join(d, 'cov.json')
  _out, err, st = Open3.capture3(RUBY, BUILDER,
                                 '--signals', File.join(d, 'sig.json'),
                                 '--master-map', File.join(d, 'mmap.json'),
                                 '--data-model', 'dm-x', '--name', 'T',
                                 '--out', wb, '--layout-out', File.join(d, 'l.xml'),
                                 '--coverage-out', cov)
  ok('builder exits 0 on the synthetic dashboard', st.success?)

  # the unmapped sigma_kind token WARNS (loud) instead of silently defaulting
  ok('WARNS on unmapped sigma_kind token', err.include?('zzz_bogus_token') && err.include?('viz-kind mapping'))
  # the empty visualType WARNS (loud) — previously silently skipped
  ok('WARNS on empty visualType (unknown/blank)',
     err.include?('unknown/blank') && err.include?('no native'))

  unresolved = JSON.parse(File.read(cov))['unresolved'] || []
  approx = unresolved.select { |u| u['severity'] == 'approximated' }
  ok('records an approximated entry for the treemap (unmapped)',
     approx.any? { |u| u['pbi_type'] == 'treemap' })
  ok('records an approximated entry for the empty/unknown visualType',
     approx.any? { |u| u['pbi_type'] == 'unknown/blank' })
  # the clean native bar must NOT be recorded as an approximation
  ok('clean native barChart is NOT flagged as an approximation',
     approx.none? { |u| u['visual'].to_s.include?('Clean Bar') })
end

# ---- 5. coverage matrix is fresh (regenerated from the catalogs) -----------
_o, e, st = Open3.capture3('python3', GEN, '--catalogs', CATDIR, '--skill', 'powerbi',
                           '--out', COV_MD, '--check')
ok('refs/powerbi-coverage.md matches the catalogs (no drift)', st.success? || (puts("    #{e}") && false))

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
