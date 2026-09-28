#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for MechanicalSpecs.remap_from_manifest! (2026-07-08).
#
# Guards the multi-embedded-extract DM collapse: the converter sees only the
# generic in-.twbx table name ("Extract") for every embedded datasource, so N
# datasources land on an IDENTICAL source.path + element name (DEMO_DB.PUBLIC.EXTRACT
# / "Extract") with unresolvable [EXTRACT/...] formula prefixes. The manifest
# remap must separate them by COLUMN-CAPTION OVERLAP (never name) and repoint
# each onto its landed Snowflake table + thread a colmap for the phantom-filter.
#
# Deterministic + offline: hand-built DM + fixture manifest, no network.
#
#   Part A — two identically-named "Extract" elements repoint to DISTINCT landed
#            tables, matched by their disjoint column sets (36-col vs 19-col).
#   Part B — every base-column formula prefix is rewritten [EXTRACT/x] -> [T/x].
#   Part C — pick_fact selects the LARGER (36-col) element once disambiguated.
#   Part D — returned colmap merges the orig→landed renames; no-op without a
#            manifest.
#
# Usage:  ruby scripts/test-manifest-remap.rb

require 'json'
require 'tmpdir'
require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# 36-col fact (Metric Series) captions and 19-col dim (REV2005) captions — disjoint
# enough to force a unique assignment. We only need a representative handful.
FACT_CAPS = ['New Region', 'Revenue (current US$)', 'NFI net inflows', 'Container volume (UNITS)',
             'Country Name', 'Year', 'Country Code']
DIM_CAPS  = ['Country Code', 'Country Group', 'Entity Group', 'Region Label', 'REV2005 Value']

def element(name, caps)
  {
    'id' => "el-#{name}", 'kind' => 'table', 'name' => 'Extract',
    'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1',
                  'path' => %w[DEMO_DB PUBLIC EXTRACT] },
    'columns' => caps.each_with_index.map do |c, i|
      { 'id' => "c-#{name}-#{i}", 'name' => c, 'formula' => "[EXTRACT/#{c}]" }
    end,
    'metrics' => [{ 'id' => "m-#{name}", 'name' => 'Total', 'formula' => "Sum([EXTRACT/#{caps.first}])" }]
  }
end

model = { 'pages' => [{ 'elements' => [element('fact', FACT_CAPS), element('dim', DIM_CAPS)] }] }

manifest = [
  { 'slug' => 'wb', 'datasource' => 'federated.a', 'caption' => '1. Metric Series Extract',
    'hyper' => 'dataengine_a.hyper', 'hyper_table' => 'Extract',
    'sf_table' => 'DEMO_DB.PUBLIC.METRICSERIES_FACT', 'rows' => 14_991,
    'columns' => FACT_CAPS.each_with_object({}) { |c, h| h[c] = c.gsub(/[^0-9A-Za-z]+/, '_').gsub(/_+$/, '').upcase } },
  { 'slug' => 'wb', 'datasource' => 'federated.b', 'caption' => 'ZQXKPnullREV2005 Extract',
    'hyper' => 'dataengine_b.hyper', 'hyper_table' => 'Extract',
    'sf_table' => 'DEMO_DB.PUBLIC.METRICSERIES_REV2005', 'rows' => 11_706,
    'columns' => DIM_CAPS.each_with_object({}) { |c, h| h[c] = c.gsub(/[^0-9A-Za-z]+/, '_').gsub(/_+$/, '').upcase } }
]

rm = nil
Dir.mktmpdir do |dir|
  mpath = File.join(dir, 'landing-manifest.json')
  File.write(mpath, JSON.generate(manifest))
  rm = MechanicalSpecs.remap_from_manifest!(model, mpath)
end

els = model['pages'][0]['elements']
fact_el = els.find { |e| e['id'] == 'el-fact' }
dim_el  = els.find { |e| e['id'] == 'el-dim' }

puts 'Part A — disambiguation by column-set overlap (not name)'
check(rm[:elements] == 2, "both elements remapped (got #{rm[:elements]})", fails)
check(fact_el.dig('source', 'path') == %w[DEMO_DB PUBLIC METRICSERIES_FACT],
      "36-col element -> METRICSERIES_FACT (got #{fact_el.dig('source', 'path').inspect})", fails)
check(dim_el.dig('source', 'path') == %w[DEMO_DB PUBLIC METRICSERIES_REV2005],
      "19-col element -> METRICSERIES_REV2005 (got #{dim_el.dig('source', 'path').inspect})", fails)
check(els.map { |e| e['name'] }.uniq.size == 2, 'element names no longer collide', fails)

puts 'Part B — base-column + metric formula prefixes rewritten'
fcols = fact_el['columns'].map { |c| c['formula'] }
check(fcols.all? { |f| f.start_with?('[METRICSERIES_FACT/') },
      'every fact base-column formula prefix repointed off [EXTRACT/…]', fails)
check(fcols.none? { |f| f.include?('[EXTRACT/') }, 'no [EXTRACT/…] prefix survives', fails)
check(fact_el['metrics'][0]['formula'].include?('[METRICSERIES_FACT/'),
      'metric formula prefix repointed too', fails)
check(fact_el['columns'][0]['name'] == 'New Region', 'display captions preserved (fold via phantom-filter)', fails)

puts 'Part C — pick_fact selects the larger element once disambiguated'
picked = MechanicalSpecs.pick_fact(model)
check(picked && picked['id'] == 'el-fact', "pick_fact -> 36-col Metric Series element (got #{picked && picked['id']})", fails)

puts 'Part D — returned colmap + no-manifest no-op'
check(rm[:colmap]['Revenue (current US$)'] == 'REVENUE_CURRENT_US',
      "colmap folds 'Revenue (current US$)' -> REVENUE_CURRENT_US (got #{rm[:colmap]['Revenue (current US$)'].inspect})", fails)
check(rm[:colmap].size == (FACT_CAPS | DIM_CAPS).size, 'colmap merges both entries (dedup shared captions)', fails)
noop = MechanicalSpecs.remap_from_manifest!({ 'pages' => [] }, '/nonexistent/landing-manifest.json')
check(noop[:elements].zero?, 'missing manifest is a safe no-op', fails)

puts 'Part E — v5.4: kind:sql FROM + column identifiers remapped'
# Single embedded Excel datasource: the FIXED-LOD helper's statement embeds the
# original sheet identifier ('COURSE LIST$') and the ORIGINAL column names —
# both must land on the warehouse names. A multi-table statement stays as-is.
sql_model = { 'pages' => [{ 'elements' => [
  element('fact2', ['Subject', 'Published Date', 'Num Enrolled']),
  { 'id' => 'el-lod', 'kind' => 'table', 'name' => "'COURSE LIST$' FIXED PRICE",
    'source' => { 'connectionId' => 'conn-1', 'kind' => 'sql',
                  'statement' => %(SELECT "Subject", SUM("Num Enrolled") AS S FROM "EXTRACT".'COURSE LIST$' GROUP BY "Subject") },
    'columns' => [{ 'id' => 'c-l1', 'name' => 'Subject' }, { 'id' => 'c-l2', 'name' => 'S' }] },
  { 'id' => 'el-window', 'kind' => 'table', 'name' => 'Window Subject',
    'source' => { 'connectionId' => 'conn-1', 'kind' => 'sql',
                  'statement' => %(WITH base AS (SELECT "Subject" AS SUBJECT FROM 'COURSE LIST$' GROUP BY 1) SELECT SUBJECT FROM base) },
    'columns' => [{ 'id' => 'c-w1', 'name' => 'Subject' }] },
  { 'id' => 'el-join', 'kind' => 'table', 'name' => 'joined helper',
    'source' => { 'connectionId' => 'conn-1', 'kind' => 'sql',
                  'statement' => %(SELECT a."Subject" FROM t1 a JOIN t2 b ON a.x = b.x) },
    'columns' => [{ 'id' => 'c-j1', 'name' => 'Subject' }] }
] }] }
sql_manifest = [
  { 'slug' => 'wb', 'datasource' => 'federated.u', 'caption' => 'Course List',
    'hyper' => 'u.hyper', 'hyper_table' => 'Extract',
    'sf_table' => 'DEMO_DB.LANDED.COURSE_LIST_DATASET', 'rows' => 3673,
    'columns' => { 'Subject' => 'SUBJECT', 'Published Date' => 'PUBLISHED_DATE',
                   'Num Enrolled' => 'NUM_ENROLLED' } }
]
rm2 = nil
Dir.mktmpdir do |dir|
  mpath = File.join(dir, 'landing-manifest.json')
  File.write(mpath, JSON.generate(sql_manifest))
  rm2 = MechanicalSpecs.remap_from_manifest!(sql_model, mpath)
end
lod = sql_model['pages'][0]['elements'].find { |e| e['id'] == 'el-lod' }
window = sql_model['pages'][0]['elements'].find { |e| e['id'] == 'el-window' }
join = sql_model['pages'][0]['elements'].find { |e| e['id'] == 'el-join' }
check(rm2[:sql_elements] == 2, "both physical-single-table sql elements remapped (got #{rm2[:sql_elements]})", fails)
check(lod.dig('source', 'statement').include?('FROM DEMO_DB.LANDED.COURSE_LIST_DATASET'),
      "FROM identifier landed (got #{lod.dig('source', 'statement')[0, 90]})", fails)
check(!lod.dig('source', 'statement').include?("COURSE LIST$"),
      'original sheet identifier gone from the statement', fails)
check(lod.dig('source', 'statement').include?('SUM(NUM_ENROLLED)') &&
      lod.dig('source', 'statement').include?('GROUP BY SUBJECT'),
      'original column identifiers folded to warehouse names', fails)
check(window.dig('source', 'statement').include?('FROM DEMO_DB.LANDED.COURSE_LIST_DATASET') &&
      window.dig('source', 'statement').end_with?('SELECT SUBJECT FROM base'),
      'window-helper CTE remaps its physical table while preserving the outer CTE reference', fails)
check(join.dig('source', 'statement').include?('FROM t1 a JOIN t2 b'),
      'multi-table statement left as-is (named residue)', fails)

puts 'Part F — v5.4: derived-element refs repaired when uniquely attributable'
d_model = { 'pages' => [{ 'elements' => [
  element('fact3', ['Subject', 'Price']),
  { 'id' => 'el-view', 'kind' => 'table', 'name' => "'course List$' View",
    'source' => { 'kind' => 'table', 'elementId' => 'el-fact3' },
    'columns' => [{ 'id' => 'c-v1', 'name' => 'Subject', 'formula' => '[EXTRACT/Subject]' }] }
] }] }
Dir.mktmpdir do |dir|
  mpath = File.join(dir, 'landing-manifest.json')
  File.write(mpath, JSON.generate(sql_manifest))
  MechanicalSpecs.remap_from_manifest!(d_model, mpath)
end
view = d_model['pages'][0]['elements'].find { |e| e['id'] == 'el-view' }
check(view['columns'][0]['formula'] == '[COURSE_LIST_DATASET/Subject]',
      "derived element's stale ref repointed (got #{view['columns'][0]['formula']})", fails)
# ambiguity guard: the Part A/B model had TWO elements sharing 'EXTRACT' — its
# dim element must NOT have been rewritten to the fact's table.
dim_ref = dim_el['columns'][0]['formula']
check(dim_ref.start_with?('[METRICSERIES_REV2005/'),
      "shared-identifier claim keeps each element on its OWN table (got #{dim_ref})", fails)

puts 'Part G — v5.4: prune_broken_orphans! (union-collapse leftover class)'
p_model = { 'pages' => [{ 'elements' => [
  element('factp', ['Subject', 'Price']),
  # broken AND unreferenced -> pruned
  { 'id' => 'el-orphan', 'kind' => 'table', 'name' => 'Ghost View',
    'source' => { 'kind' => 'table', 'elementId' => 'el-gone' },
    'columns' => [{ 'id' => 'c-o1', 'name' => 'X', 'formula' => "['COURSE LIST$'/X]" }] },
  # broken cross-ref but REFERENCED by the metric below -> kept
  { 'id' => 'el-used', 'kind' => 'table', 'name' => 'Used View',
    'source' => { 'kind' => 'table', 'elementId' => 'el-factp' },
    'columns' => [{ 'id' => 'c-u1', 'name' => 'Y', 'formula' => '[NoSuchElement/Y]' }] },
  { 'id' => 'el-consumer', 'kind' => 'table', 'name' => 'Consumer',
    'source' => { 'kind' => 'table', 'elementId' => 'el-used' },
    'columns' => [{ 'id' => 'c-c1', 'name' => 'Z', 'formula' => 'Sum([Used View/Y])' }] },
  # source-relative refs only (valid) -> kept
  { 'id' => 'el-sql2', 'kind' => 'table', 'name' => 'FIXED thing',
    'source' => { 'connectionId' => 'c', 'kind' => 'sql', 'statement' => 'SELECT 1' },
    'columns' => [{ 'id' => 'c-s1', 'name' => 'V', 'formula' => '[Custom SQL/V]' }] }
] }] }
pruned = MechanicalSpecs.prune_broken_orphans!(p_model)
names_left = p_model['pages'][0]['elements'].map { |e| e['id'] }
check(pruned == ['Ghost View'], "exactly the broken+unreferenced element pruned (got #{pruned.inspect})", fails)
check(!names_left.include?('el-orphan'), 'orphan removed from the page', fails)
check(names_left.include?('el-used') && names_left.include?('el-sql2'),
      'referenced-but-broken and source-relative elements KEPT', fails)

puts "Part H — #685-C secondary: derived-view refs repaired via elementId even when the STRING " \
     "identifier is ambiguous (Tableau's own duplicate-datasource shape: two DIFFERENT datasources " \
     "reuse the identical internal relation name 'Orders' — the Executive Dashboard cold-run's " \
     '"Orders View" prefix-mismatch)'
dup_el = lambda do |id, caps|
  { 'id' => id, 'kind' => 'table', 'name' => nil,
    'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'conn-1', 'path' => %w[WHDB WHSCHEMA ORDERS] },
    'columns' => caps.each_with_index.map { |c, i| { 'id' => "#{id}-#{i}", 'name' => c, 'formula' => "[ORDERS/#{c}]" } } }
end
orders_a = dup_el.call('el-orders-a', ['Row ID', 'Order Date', 'Ship Date', 'Sales'])
orders_b = dup_el.call('el-orders-b', %w[Order\ ID Customer\ Name Sales Discount])
view_a = {
  'id' => 'el-view-a', 'kind' => 'table', 'name' => 'Orders View',
  'source' => { 'kind' => 'table', 'elementId' => 'el-orders-a' },
  'columns' => [{ 'id' => 'c-va1', 'name' => nil, 'formula' => '[ORDERS/Row ID]' }]
}
dup_model = { 'pages' => [{ 'elements' => [orders_a, orders_b, view_a] }] }
dup_manifest = [
  { 'slug' => 'wb', 'datasource' => 'federated.orders_a', 'caption' => 'Sample - Superstore',
    'hyper' => 'a.hyper', 'hyper_table' => 'Orders', 'sf_table' => 'WHDB.WHSCHEMA.FIXTURE_ORDERS', 'rows' => 100,
    'columns' => { 'Row ID' => 'ROW_ID', 'Order Date' => 'ORDER_DATE', 'Ship Date' => 'SHIP_DATE', 'Sales' => 'SALES' } },
  { 'slug' => 'wb', 'datasource' => 'federated.orders_b', 'caption' => 'Sample - Superstore (2)',
    'hyper' => 'b.hyper', 'hyper_table' => 'Orders', 'sf_table' => 'WHDB.WHSCHEMA.FIXTURE_ORDERS_DUP',
    'rows' => 100,
    'columns' => { 'Order ID' => 'ORDER_ID', 'Customer Name' => 'CUSTOMER_NAME', 'Sales' => 'SALES',
                   'Discount' => 'DISCOUNT' } }
]
Dir.mktmpdir do |dir|
  mpath = File.join(dir, 'landing-manifest.json')
  File.write(mpath, JSON.generate(dup_manifest))
  MechanicalSpecs.remap_from_manifest!(dup_model, mpath)
end
els_h = dup_model['pages'][0]['elements']
view_ref = els_h.find { |e| e['id'] == 'el-view-a' }['columns'][0]['formula']
check(view_ref == '[FIXTURE_ORDERS/Row ID]',
      "derived view's ref repointed to ITS OWN base's landed table via elementId (not the ambiguous " \
      "shared string 'ORDERS') (got #{view_ref})", fails)
check(els_h.find { |e| e['id'] == 'el-orders-a' }.dig('source', 'path') == %w[WHDB WHSCHEMA FIXTURE_ORDERS],
      'the first duplicate claims its own manifest entry', fails)
check(els_h.find { |e| e['id'] == 'el-orders-b' }.dig('source', 'path') == %w[WHDB WHSCHEMA FIXTURE_ORDERS_DUP],
      'the second (duplicate-named) datasource claims its OWN, different manifest entry', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
