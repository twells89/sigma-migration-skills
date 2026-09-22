#!/usr/bin/env ruby
# frozen_string_literal: true
# test-ground-truth-derive.rb — offline tests for the PR-5 part A ground-truth
# DERIVATION (scripts/lib/ground_truth_sql.rb + scripts/derive-ground-truth.rb).
#
# Uses the synthetic test-fixtures/ground-truth.twb, runs the REAL
# parse-twb-layout.rb over it (so the zone/meta shapes stay in lockstep with
# the parser), then derives the ledger and asserts:
#   - simple agg tile → correct SQL (dims, agg, worksheet + datasource filters,
#     the .twb LEFT JOIN, GROUP BY)
#   - user-agg calc tile → SQL with NULLIF-guarded ratio + calc-dependency
#     provenance (name + formula_hash, calc-fields source priority)
#   - parameter-referencing calc → default value substituted AND recorded
#   - window-calc tile → classified vds (routes to the existing vds-oracle)
#   - blend tile → anchor-only with a reason
#   - tile with no source zone → unverifiable(reason)
#   - COVERAGE COMPLETENESS: every parity-plan tile gets exactly one ledger
#     entry with a valid classification — nothing silently drops out
#   - smoke: the corpus orders-overview .twb derives a complete ledger too
#
# Run: ruby scripts/test-ground-truth-derive.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'lib/ground_truth_sql'

SCRIPTS = __dir__
FIXTURE = File.join(SCRIPTS, 'test-fixtures', 'ground-truth.twb')
DERIVE  = File.join(SCRIPTS, 'derive-ground-truth.rb')
PARSE   = File.join(SCRIPTS, 'parse-twb-layout.rb')
CORPUS_TWB = File.expand_path('../../../../../corpus/tableau/orders-overview/workbook-content.twb', SCRIPTS)

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |dir|
  # 1. Real layout parse over the synthetic .twb.
  layout_path = File.join(dir, 'dashboard-layout.json')
  _out, err, st = Open3.capture3(RbConfig.ruby, PARSE, FIXTURE, layout_path)
  ok(st.exitstatus.zero?, "parse-twb-layout runs over the fixture (got #{st.exitstatus}: #{err.lines.first})")

  # 2. Parity plan: the five worksheets + one tile with no source zone.
  charts = [
    { 'chart' => 'Sales by Region',         'tableau_view' => 'Sales by Region',         'sigma_element_id' => 'el-sales-by-region' },
    { 'chart' => 'Profit Ratio by Segment', 'tableau_view' => 'Profit Ratio by Segment', 'sigma_element_id' => 'el-profit-ratio' },
    { 'chart' => 'Scaled Sales',            'tableau_view' => 'Scaled Sales',            'sigma_element_id' => 'el-scaled' },
    { 'chart' => 'Running Sales Trend',     'tableau_view' => 'Running Sales Trend',     'sigma_element_id' => 'el-running' },
    { 'chart' => 'Quota Attainment Blend',  'tableau_view' => 'Quota Attainment Blend',  'sigma_element_id' => 'el-blend' },
    { 'chart' => 'Ghost Tile',              'tableau_view' => 'Ghost Tile',              'sigma_element_id' => 'el-ghost' }
  ]
  File.write(File.join(dir, 'parity-plan.json'),
             JSON.pretty_generate('extract' => false, 'charts' => charts))

  # 3. calc-fields.json — the extracted-calc artifact (translation input the
  #    DM build consumed). Profit Ratio present here AND in the .twb meta so
  #    the calc-fields source wins the dependency provenance.
  File.write(File.join(dir, 'calc-fields.json'), JSON.pretty_generate(
    'calcs' => [
      { 'name' => 'Profit Ratio', 'internal_name' => 'Calculation_200',
        'formula' => 'SUM([PROFIT]) / SUM([SALES])' },
      { 'name' => 'Running Sales', 'internal_name' => 'Calculation_201',
        'formula' => 'RUNNING_SUM(SUM([SALES]))' },
      { 'name' => 'Scaled Sales', 'internal_name' => 'Calculation_202',
        'formula' => 'SUM([SALES]) * [Parameters].[Factor]' }
    ]
  ))

  out_path = File.join(dir, 'ground-truth-plan.json')
  out, err, st = Open3.capture3(RbConfig.ruby, DERIVE, '--workdir', dir, '--twb', FIXTURE, '--out', out_path)
  ok(st.exitstatus.zero?, "derive-ground-truth exits 0 (got #{st.exitstatus}: #{err.lines.first})")
  doc = JSON.parse(File.read(out_path))
  by_chart = doc['entries'].each_with_object({}) { |e, h| h[e['chart']] = e }

  puts '-- coverage ledger completeness --'
  ok(doc['entries'].size == charts.size, "every parity-plan tile has exactly one ledger entry (#{doc['entries'].size}/#{charts.size})")
  ok(doc['summary']['coverage_complete'] == true, 'summary.coverage_complete is true')
  ok(doc['entries'].all? { |e| %w[warehouse-sql vds anchor-only unverifiable].include?(e['classification']) },
     'every entry carries a valid classification (nothing silently drops out)')
  ok(charts.map { |c| c['chart'] }.sort == doc['entries'].map { |e| e['chart'] }.sort,
     'ledger charts == plan charts (1:1)')
  ok(doc['generated_at'].to_s =~ /\A\d{4}-/ && doc['consumer'].to_s.include?('PR-6'),
     'plan stamped with generated_at + PR-6 consumer pointer')

  puts '-- simple agg tile → correct SQL --'
  e = by_chart['Sales by Region']
  ok(e['classification'] == 'warehouse-sql', "Sales by Region classified warehouse-sql (got #{e['classification']}: #{e['reason']})")
  sql = e['sql'].to_s
  ok(sql.include?('SUM(T1.SALES)'), "agg emitted (SUM over the fact column) — got:\n#{sql}")
  ok(sql.include?('T2.REGION_NAME AS "REGION_NAME"'), 'dim emitted with a stable alias')
  ok(sql.include?('FROM ANALYTICS.PUBLIC.SALES_FACT T1'), 'FROM = the .twb fact table FQN')
  ok(sql.include?('LEFT JOIN ANALYTICS.PUBLIC.REGION_DIM T2 ON T1.REGION_ID = T2.REGION_ID'),
     'JOIN per the .twb join spec (type + key pair)')
  ok(sql.include?("T2.REGION_NAME IN ('East', 'West')"), 'worksheet member filter in WHERE')
  ok(sql.include?("T1.SEGMENT IN ('Consumer', 'Corporate')"), 'DATASOURCE-level filter in WHERE (post-#414 parse)')
  ok(sql.include?('GROUP BY 1'), 'GROUP BY the dims')
  prov = e['provenance']
  ok(prov['filters'].any? { |f| f['source'] == 'datasource' } && prov['filters'].any? { |f| f['source'] == 'worksheet' },
     'provenance records which filters (worksheet + datasource) fed the SQL')
  ok(prov['worksheet'] == 'Sales by Region' && prov['dashboard'].to_s == 'Ground Truth Dash',
     'provenance names the source zone/worksheet')

  puts '-- calc measure → SQL + dependency provenance --'
  e = by_chart['Profit Ratio by Segment']
  ok(e['classification'] == 'warehouse-sql', "Profit Ratio classified warehouse-sql (got #{e['classification']}: #{e['reason']})")
  ok(e['sql'].to_s.include?('SUM(T1.PROFIT) / NULLIF(SUM(T1.SALES), 0)'),
     "user-agg ratio translated with a NULLIF divide-by-zero guard — got:\n#{e['sql']}")
  deps = e['provenance']['calc_dependencies']
  ok(deps.any? { |d| d['name'] == 'Profit Ratio' && d['formula_hash'].to_s.length == 40 },
     'calc dependency recorded with name + formula_hash (traceable common-mode residue)')
  ok(deps.all? { |d| d['source'] == 'calc-fields' },
     'dependency provenance names the calc-fields artifact as the formula source')

  puts '-- parameter default substitution --'
  e = by_chart['Scaled Sales']
  ok(e['classification'] == 'warehouse-sql', "Scaled Sales classified warehouse-sql (got #{e['classification']}: #{e['reason']})")
  ok(e['sql'].to_s.include?('SUM(T1.SALES) * 3'), "parameter default (Factor=3) substituted — got:\n#{e['sql']}")
  ok(e['provenance']['parameters'] == { 'Factor' => '3' },
     'parameter value recorded in provenance')

  puts '-- window calc → vds --'
  e = by_chart['Running Sales Trend']
  ok(e['classification'] == 'vds', "RUNNING_SUM tile classified vds (got #{e['classification']})")
  ok(e['reason'].to_s =~ /window|vds/i, 'vds reason routes to the vds-oracle path')
  ok(e['sql'].nil?, 'no SQL emitted for a vds tile (Tableau computes it)')

  puts '-- vds demoted on a fan-out-fed tile (join-plan ledger not proven unique) --'
  # Twin-B e2e 2026-07-19: VDS queries through Tableau's logical layer, which
  # CULLS relationship joins per-viz — VDS returns un-fanned data and would
  # false-green a Sigma build that dropped the join. A vds tile whose
  # datasource carries a ledger join not proven "unique" must fall back to
  # anchors (anchor-only) with the hazard named.
  File.write(File.join(dir, 'join-plan.json'), JSON.pretty_generate(
    'entries' => [{ 'kind' => 'federated-join', 'join_type' => 'left',
                    'left' => 'SALES_FACT', 'right' => 'REGION_DIM',
                    'keys' => ['REGION_ID'], 'grain_assumption' => 'right unique on keys',
                    'status' => 'unprobed', 'right_table' => 'ANALYTICS.PUBLIC.REGION_DIM',
                    'probe_keys' => ['REGION_ID'] }]
  ))
  _out, err, st = Open3.capture3(RbConfig.ruby, DERIVE, '--workdir', dir, '--twb', FIXTURE, '--out', out_path)
  ok(st.exitstatus.zero?, "derive re-runs with a join ledger present (got #{st.exitstatus}: #{err.lines.first})")
  doc2 = JSON.parse(File.read(out_path))
  e2 = doc2['entries'].find { |x| x['chart'] == 'Running Sales Trend' }
  ok(e2['classification'] == 'anchor-only',
     "vds demoted to anchor-only while the join is unproven (got #{e2['classification']})")
  ok(e2['reason'].to_s =~ /vds-oracle unsafe/ && e2['reason'].to_s =~ /SALES_FACT -> REGION_DIM/,
     'demotion reason names the hazard AND the unproven join')
  ok(doc2['entries'].find { |x| x['chart'] == 'Sales by Region' }['classification'] == 'warehouse-sql',
     'warehouse-sql tiles are untouched by the demotion (SQL replicates the join; VDS does not)')
  # A join PROVEN unique cannot fan out — vds stays trustworthy.
  File.write(File.join(dir, 'join-plan.json'), JSON.pretty_generate(
    'entries' => [{ 'kind' => 'federated-join', 'join_type' => 'left',
                    'left' => 'SALES_FACT', 'right' => 'REGION_DIM',
                    'keys' => ['REGION_ID'], 'grain_assumption' => 'right unique on keys',
                    'status' => 'unique', 'right_table' => 'ANALYTICS.PUBLIC.REGION_DIM',
                    'probe_keys' => ['REGION_ID'] }]
  ))
  _out, _err, st = Open3.capture3(RbConfig.ruby, DERIVE, '--workdir', dir, '--twb', FIXTURE, '--out', out_path)
  ok(st.exitstatus.zero?, 'derive re-runs with a proven-unique ledger')
  doc3 = JSON.parse(File.read(out_path))
  ok(doc3['entries'].find { |x| x['chart'] == 'Running Sales Trend' }['classification'] == 'vds',
     'a join PROVEN unique keeps the vds classification (no fan-out possible)')
  File.delete(File.join(dir, 'join-plan.json'))

  puts '-- blend → anchor-only --'
  e = by_chart['Quota Attainment Blend']
  ok(e['classification'] == 'anchor-only', "blend tile classified anchor-only (got #{e['classification']})")
  ok(e['reason'].to_s =~ /blend/i && e['reason'].to_s.include?('federated.gt02'),
     "anchor-only reason names the blend (got #{e['reason'].inspect})")

  puts '-- no source zone → unverifiable --'
  e = by_chart['Ghost Tile']
  ok(e['classification'] == 'unverifiable', "zoneless tile classified unverifiable (got #{e['classification']})")
  ok(!e['reason'].to_s.empty?, 'unverifiable carries a reason')

  ok(out.include?('derive-ground-truth:') && out.include?('warehouse-sql 3'),
     'summary line reports the classification counts')

  puts '-- independence: no builder imports --'
  %w[lib/ground_truth_sql.rb derive-ground-truth.rb run-ground-truth.rb].each do |f|
    src = File.read(File.join(SCRIPTS, f), encoding: 'UTF-8')
    ok(src !~ /require(_relative)?\s*\(?\s*['"].*build[-_]charts/,
       "#{f} requires nothing from the builder (independence contract)")
  end
end

puts '-- object-graph duplicate-caption relationship keys stay physical --'
relationship_ds = {
  'objects' => [
    { 'id' => 'fact-id', 'caption' => 'FACT', 'fqn' => 'DB.SC.FACT' },
    { 'id' => 'product-id', 'caption' => 'PRODUCT_DIM', 'fqn' => 'DB.SC.PRODUCT_DIM' }
  ],
  'relationships' => [
    { 'first' => 'fact-id', 'second' => 'product-id', 'second_unique' => true,
      'lexpr' => '[fact-guid]', 'rexpr' => '[product-guid]' }
  ]
}
relationship_meta = {
  'columns_by_guid' => {
    'fact-guid' => { 'caption' => 'Product Key' },
    'product-guid' => { 'caption' => 'Product Key (PRODUCT_DIM)' }
  }
}
relationship_from = GroundTruthSql.build_from_relationships(relationship_ds, relationship_meta)
ok(relationship_from['sql'].include?('T1.PRODUCT_KEY = T2.PRODUCT_KEY'),
   'display-only logical-table suffix is stripped from the target warehouse key')
ok(!relationship_from['sql'].include?('PRODUCT_KEY_('),
   'duplicate-caption disambiguation never leaks into the SQL identifier')

puts '-- object-graph shelf fields retain GUID ownership --'
resolver_ds = {
  'objects' => [
    { 'id' => 'fact-id', 'caption' => 'FACT', 'columns' => [] },
    { 'id' => 'customer-id', 'caption' => 'CUSTOMER_DIM', 'columns' => [] },
    { 'id' => 'store-id', 'caption' => 'STORE_DIM', 'columns' => [] }
  ],
  'relationships' => [
    { 'first' => 'fact-id', 'second' => 'customer-id' },
    { 'first' => 'fact-id', 'second' => 'store-id' }
  ],
  'field_owners' => {
    'customer-region-guid' => 'CUSTOMER_DIM',
    'store-region-guid' => 'STORE_DIM',
    'parsed-date-guid' => 'CUSTOMER_DIM'
  },
  'transformed_fields' => ['parsed-date-guid']
}
resolver_meta = {
  'columns_by_guid' => {
    'customer-region-guid' => { 'caption' => 'Region' },
    'store-region-guid' => { 'caption' => 'Region' },
    'parsed-date-guid' => { 'caption' => 'Order Date' }
  }
}
resolver = GroundTruthSql.column_resolver(
  resolver_ds,
  { 'CUSTOMER_DIM' => 'T1', 'STORE_DIM' => 'T2' },
  resolver_meta
)
ok(resolver.call('Region', 'customer-region-guid') == 'T1.REGION',
   'ambiguous display caption resolves through the source field GUID owner')
ok(resolver.call('Region', 'store-region-guid') == 'T2.REGION',
   'same-named field on another logical table resolves to its own alias')
ok(resolver.call('Order Date', 'parsed-date-guid').nil?,
   'date-parse aliases without a physical warehouse identity route to anchor-only')
ok(GroundTruthSql.related_object_grain(
     resolver_ds,
     [{ 'role' => 'dim', 'guid' => 'customer-region-guid' }]
   ) == 'CUSTOMER_DIM',
   'single-related-object tile is identified as dimension-grain/anchor-only')
ok(GroundTruthSql.related_object_grain(
     resolver_ds,
     [{ 'role' => 'dim', 'guid' => 'customer-region-guid' },
      { 'role' => 'dim', 'guid' => 'store-region-guid' }]
   ).nil?,
   'mixed-object tile remains eligible for explicit warehouse SQL derivation')

puts '-- corpus smoke: orders-overview derives a complete ledger --'
if File.exist?(CORPUS_TWB)
  Dir.mktmpdir do |dir|
    layout_path = File.join(dir, 'dashboard-layout.json')
    _out, err, st = Open3.capture3(RbConfig.ruby, PARSE, CORPUS_TWB, layout_path)
    ok(st.exitstatus.zero?, "parse-twb-layout runs over the corpus .twb (got #{st.exitstatus}: #{err.lines.first})")
    layout = JSON.parse(File.read(layout_path))
    charts = layout.flat_map { |d| d['zones'] }
                   .select { |z| z['kind'] == 'chart' && z['caption'] }
                   .map { |z| { 'chart' => z['caption'], 'tableau_view' => z['caption'],
                                'sigma_element_id' => "el-#{z['id']}" } }
    ok(charts.size >= 3, "corpus dashboard yields chart tiles (got #{charts.size})")
    File.write(File.join(dir, 'parity-plan.json'), JSON.pretty_generate('charts' => charts))
    out_path = File.join(dir, 'ground-truth-plan.json')
    _out, err, st = Open3.capture3(RbConfig.ruby, DERIVE, '--workdir', dir, '--twb', CORPUS_TWB,
                                   '--db', 'DEMO_DB', '--schema', 'DEMO', '--out', out_path)
    ok(st.exitstatus.zero?, "derive exits 0 on the corpus .twb (got #{st.exitstatus}: #{err.lines.first})")
    doc = JSON.parse(File.read(out_path))
    ok(doc['summary']['coverage_complete'] == true && doc['entries'].size == charts.size,
       "corpus ledger complete: every tile classified (#{doc['entries'].size}/#{charts.size})")
    ok(doc['entries'].all? { |e| %w[warehouse-sql vds anchor-only unverifiable].include?(e['classification']) },
       'corpus classifications all valid')
    ok(doc['entries'].none? { |e| e['classification'] == 'unverifiable' },
       'corpus tiles all classify better than unverifiable (anchor-only reasons are named, not dead ends)')
    ok(doc['entries'].all? { |e| e['classification'] == 'warehouse-sql' || !e['reason'].to_s.empty? },
       'every non-SQL corpus entry names its reason')
    counts = doc['entries'].group_by { |e| e['classification'] }.map { |k, v| "#{k}=#{v.size}" }.join(', ')
    puts "  INFO  orders-overview classification mix: #{counts}"
  end
else
  puts '  SKIP  corpus .twb not present in this checkout'
end

puts
if $fails.empty?
  puts 'ALL PASS — ground-truth derivation (ledger + SQL + classifications)'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
