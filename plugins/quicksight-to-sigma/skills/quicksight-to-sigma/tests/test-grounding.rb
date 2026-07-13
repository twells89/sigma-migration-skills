#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Grounding regression for build-workbook-from-quicksight.rb (beads-sigma-kvza).
#
# Proves the QuickSight dashboard classifier is DOCUMENTATION-GROUNDED and LOUD-on-miss,
# mirroring the merged Looker/Qlik pilot (tests/test_grounding.py):
#   1. CATALOGS      — all four refs/catalogs/*.json load, are cited (real doc URLs),
#      have unique sources, and are tagged source_tool == "quicksight".
#   2. NO INLINE MAP — the viz/aggregation/control maps are DERIVED from the catalogs;
#      no residual inline literal bypasses the single source of truth, and the two named
#      silent defaults (AGG || 'Sum', AGG || 'Avg') + the fmt_for name-substring currency/
#      percent guess and its silent ',.0f' default are GONE.
#   3. LOUD FALLBACKS — running the builder on a synthetic analysis, an unmapped QS
#      aggregation (STDEV), an every-measure missing number format, and an unknown visual
#      type each WARN (never a silent wrong-default / silent skip). The unmapped
#      aggregation is neutralized to Null, NOT quietly summed.
#   4. MATRIX FRESH  — refs/quicksight-coverage.md is regenerated from the catalogs.
#
# No byte-golden: the builder is non-deterministic (SecureRandom element ids) and ships no
# offline dashboard fixture, so verbatim extraction + these unit checks are the contract.
#
# Run: ruby tests/test-grounding.rb   (exit 0 = pass)

require 'json'
require 'tmpdir'
require 'rbconfig'

HERE    = File.dirname(File.expand_path(__FILE__))
SKILL   = File.dirname(HERE)
SCRIPTS = File.join(SKILL, 'scripts')
CATDIR  = File.join(SKILL, 'refs', 'catalogs')
BUILDER = File.join(SCRIPTS, 'build-workbook-from-quicksight.rb')
GENMTX  = File.join(SCRIPTS, 'gen-coverage-matrix.py')
COVMD   = File.join(SKILL, 'refs', 'quicksight-coverage.md')
RUBY    = RbConfig.ruby

require File.join(SCRIPTS, 'lib', 'coverage_catalog')

def assert(cond, msg)
  raise "ASSERT FAILED: #{msg}" unless cond
end

# ---- 1. catalogs load, cited, unique sources -------------------------------
def test_catalogs_valid
  cats = Coverage.load_all(CATDIR)
  assert(cats.keys.sort == %w[aggregation control number-format viz-kind],
         "expected 4 catalogs, got #{cats.keys.sort.inspect}")
  cats.each do |name, cat|
    assert(!cat.rows.empty?, "#{name}: no rows")
    assert(cat.source_tool == 'quicksight', "#{name}: source_tool=#{cat.source_tool.inspect}")
    assert(cat.authoritative_doc.start_with?('http'), "#{name}: authoritative_doc not a URL")
    seen = {}
    cat.rows.each do |r|
      key = r['source'].to_s.downcase
      assert(!seen[key], "#{name}: duplicate source #{key.inspect}")
      seen[key] = true
      assert(r['doc_ref'].to_s.start_with?('http'), "#{name}: #{r['source']} doc_ref not a URL")
      sv = r['sigma_verified'] || {}
      assert(%w[y n].include?(sv['status']),
             "#{name}: #{r['source']} sigma_verified.status must be 'y' or 'n' (got #{sv['status'].inspect})")
      assert(sv['status'] != 'y' || !sv['date'].to_s.empty?,
             "#{name}: #{r['source']} live-verified rows (status 'y') must carry a date")
      # a mapped Sigma target must be present — EXCEPT a viz-kind DROP row (no Sigma
      # equivalent), which legitimately carries sigma:null + an unsupported_reason.
      has_target = !r['sigma'].nil?
      drop_row = name == 'viz-kind' && r['sigma'].nil? && r['unsupported_reason']
      assert(has_target || drop_row, "#{name}: #{r['source']} has no Sigma target and is not a drop row")
    end
  end
  puts '[ok] catalogs: 4 dimensions load, cited (quicksight), unique sources, all sigma_verified=n'
end

# ---- 2. no residual inline map bypasses the catalog ------------------------
def test_no_inline_maps
  src = File.read(BUILDER)
  # the maps must be catalog-LOADED, not inline literals
  assert(src.include?("require_relative 'lib/coverage_catalog'"), 'builder does not require the loader')
  assert(src.include?('Coverage.load_all('), 'builder does not load catalogs')
  assert(src.include?('VIZ_CAT.rows.each'), 'KIND/QS_FALLBACK/QS_UNSUPPORTED not derived from viz-kind catalog')
  assert(src.include?('AGG_CAT.rows.each_with_object'), 'AGG not derived from aggregation catalog')
  assert(src.include?('CTRL_CAT.target('), 'control kind not resolved via the control catalog')
  # the old inline literals must be gone
  assert(!src.include?("'KPIVisual' => 'kpi-chart'"), 'old inline KIND literal still present')
  assert(src !~ /'HeatMapVisual'\s*=>\s*'Sigma has no/, 'old inline QS_UNSUPPORTED literal still present')
  # the two named silent aggregation defaults must be gone
  assert(!src.include?("AGG[agg] || 'Sum'"), "silent AGG || 'Sum' still present")
  assert(!src.include?("AGG[aggk] || 'Avg'"), "silent AGG || 'Avg' still present")
  # the fmt_for name-substring currency/percent guessing + silent ',.0f' default must be gone
  assert(src !~ /when \/revenue\|profit/, 'fmt_for name-substring currency guess still present')
  assert(src !~ /when \/margin\|pct/, 'fmt_for name-substring percent guess still present')
  assert(!src.include?("else ',.0f'"), "fmt_for silent ',.0f' default still present")
  puts '[ok] no-inline-map: viz/agg/control maps catalog-derived; silent Sum/Avg + name-substring format guess removed'
end

# ---- helpers: run the builder on a synthetic analysis ----------------------
def build(analysis, readback)
  Dir.mktmpdir do |d|
    an = File.join(d, 'an.json'); rb = File.join(d, 'rb.json'); out = File.join(d, 'wb.json')
    File.write(an, JSON.generate(analysis))
    File.write(rb, JSON.generate(readback))
    stderr_r, stderr_w = IO.pipe
    pid = spawn(RUBY, BUILDER, '--analysis', an, '--dm-readback', rb, '--out', out,
                out: File::NULL, err: stderr_w)
    Process.wait(pid); status = $?.exitstatus
    stderr_w.close; err = stderr_r.read; stderr_r.close
    assert(status.zero?, "build-workbook-from-quicksight.rb failed (#{status}):\n#{err}")
    spec = JSON.parse(File.read(out))
    warns = JSON.parse(File.read(out.sub(/\.json$/, '') + '.warnings.json'))['warnings']
    [spec, warns, err]
  end
end

def synthetic_analysis
  { 'Definition' => { 'Sheets' => [ { 'SheetId' => 's1', 'Name' => 'S1', 'Visuals' => [
    # (a) an UNMAPPED QuickSight aggregation (STDEV has no simple Sigma equivalent)
    { 'KPIVisual' => { 'VisualId' => 'v1', 'Title' => { 'FormatText' => { 'PlainText' => 'Stdev KPI' } },
      'ChartConfiguration' => { 'FieldWells' => { 'Values' => [
        { 'NumericalMeasureField' => { 'FieldId' => 'f1', 'Column' => { 'ColumnName' => 'NET_REVENUE' },
          'AggregationFunction' => { 'SimpleNumericalAggregation' => 'STDEV' } } } ] } } } },
    # (b) a MAPPED aggregation (SUM) so we prove already-mapped behavior is unchanged
    { 'BarChartVisual' => { 'VisualId' => 'v2', 'Title' => { 'FormatText' => { 'PlainText' => 'Rev by Region' } },
      'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
        'Category' => [ { 'CategoricalDimensionField' => { 'FieldId' => 'd1', 'Column' => { 'ColumnName' => 'REGION' } } } ],
        'Values' => [ { 'NumericalMeasureField' => { 'FieldId' => 'f2', 'Column' => { 'ColumnName' => 'NET_REVENUE' },
          'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } } ] } } } } },
    # (c) an UNKNOWN visual type (no native kind, no fallback) -> loud drop
    { 'BogusFunkyVisual' => { 'VisualId' => 'v3', 'Title' => { 'FormatText' => { 'PlainText' => 'Funky' } },
      'ChartConfiguration' => { 'FieldWells' => {} } } }
  ] } ] } }
end

def synthetic_readback
  { 'dataModelId' => 'dm-1', 'pages' => [ { 'elements' => [
    { 'id' => 'el-1', 'name' => 'Orders', 'columns' => [ { 'name' => 'Net Revenue' }, { 'name' => 'Region' } ] } ] } ] }
end

# ---- 3. each killed silent fallback now WARNS ------------------------------
def test_loud_fallbacks
  spec, warns, err = build(synthetic_analysis, synthetic_readback)
  blob = JSON.generate(warns) + "\n" + err

  # (a) unmapped aggregation STDEV -> LOUD Aggregation warn + neutralize to Null (no silent Sum)
  assert(warns.any? { |w| w['type'] == 'Aggregation' && w['reason'].include?('STDEV') &&
                          w['reason'].include?('no documented Sigma mapping') },
         "unmapped aggregation did not warn loudly:\n#{blob}")
  assert(JSON.generate(spec).include?("unmapped QuickSight aggregation 'STDEV'"),
         'expected the STDEV measure neutralized to Null with a cited description')
  # the STDEV KPI must NOT have been quietly summed
  kpi = spec['pages'].flat_map { |p| p['elements'] }.find { |e| e['name'] == 'Stdev KPI' }
  assert(kpi, 'Stdev KPI element missing')
  stdev_formula = (kpi['columns'] || []).map { |c| c['formula'] }.first
  assert(stdev_formula == 'Null', "STDEV measure was not neutralized (formula=#{stdev_formula.inspect}) — silent default returned?")

  # already-mapped SUM is unchanged: the bar chart's measure is Sum([Orders/Net Revenue])
  assert(JSON.generate(spec).include?('Sum([Orders/Net Revenue])'),
         'mapped SUM aggregation changed behavior (expected Sum([Orders/Net Revenue]))')

  # (b) number format: no source format found -> LOUD note, and NO format guessed onto the measure
  assert(warns.any? { |w| w['type'] == 'NumberFormat' && w['reason'].include?('no QuickSight source format found') },
         "missing number format did not warn loudly:\n#{blob}")
  bar = spec['pages'].flat_map { |p| p['elements'] }.find { |e| e['name'] == 'Rev by Region' }
  measure_cols = (bar['columns'] || []).select { |c| c['formula'].to_s.start_with?('Sum(') }
  assert(measure_cols.any? && measure_cols.none? { |c| c.key?('format') },
         'a measure carried a guessed number format — name-substring guessing must be gone')

  # (c) unknown visual type -> loud drop, not silently emitted
  assert(warns.any? { |w| w['type'] == 'BogusFunkyVisual' && w['reason'].include?('unrecognized') },
         "unknown visual type did not warn loudly:\n#{blob}")
  names = spec['pages'].flat_map { |p| p['elements'] }.map { |e| e['name'] }
  assert(!names.include?('Funky'), 'unmapped visual type was silently emitted as an element')

  puts '[ok] loud fallbacks: unmapped STDEV neutralized+warns, unformatted measure warns, unknown viz drops+warns'
end

# ---- 4. coverage matrix fresh ----------------------------------------------
def test_coverage_matrix_fresh
  ok = system('python3', GENMTX, '--catalogs', CATDIR, '--skill', 'quicksight',
              '--out', COVMD, '--check')
  assert(ok, 'refs/quicksight-coverage.md is stale — regenerate with gen-coverage-matrix.py')
  puts '[ok] coverage matrix: refs/quicksight-coverage.md matches the catalogs'
end

if __FILE__ == $PROGRAM_NAME
  test_catalogs_valid
  test_no_inline_maps
  test_coverage_matrix_fresh
  test_loud_fallbacks
  puts 'ALL PASS'
end
