#!/usr/bin/env ruby
# Unit tests for build-dm.rb helpers (display_name, build_element). No network.
#   ruby test/test-build-dm.rb

require_relative '../scripts/build-dm'
require 'tmpdir'

SKILL_ROOT = File.expand_path('..', __dir__)

$failures = 0
def eq(a, b, m) if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end end
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end

puts "== display_name (fixes raw snake_case labels) =="
eq(display_name('order_date'), 'Order Date', 'snake_case → Title Case')
eq(display_name('OrderDate'),  'Order Date', 'camelCase → Title Case')
eq(display_name('project_id'), 'Project Id', 'project_id → Project Id')
eq(display_name('FY2024'),     'FY 2024',    'letter/digit boundary')
eq(display_name('HTMLParser'), 'HTML Parser','acronym boundary')
eq(display_name(display_name('order_date')), 'Order Date', 'idempotent (case-safe sibling refs)')
# bead xo56 — a DOT is not a split boundary, so a dotted column stays one token.
# String#capitalize would lowercase its remainder ('Account.Billing' ->
# 'Account.billing'), emitting a formula reference Sigma cannot resolve and
# 400ing the whole data-model POST. Live-found on the 36-card cold run.
eq(display_name('Account.BillingState'), 'Account Billing State', 'dot is a word separator — no dot survives (xo56)')
eq(display_name('Account.BillingCountry'), 'Account Billing Country', 'second dotted camelCase column')
eq(display_name('Account.Name'), 'Account Name', 'dotted single-word column loses its dot too')
eq(display_name('IsWon'), 'Is Won', 'plain camelCase still splits (Sigma does too)')
eq(normalize_formula_column_refs(
     'DateDiff("minute", [Call DateTime], [ResolutionDateTime]) + [RAW_TABLE/Exact Name] & "[Call DateTime]"'
   ),
   'DateDiff("minute", [Call Date Time], [Resolution Date Time]) + [RAW_TABLE/Exact Name] & "[Call DateTime]"',
   'formula refs use DM humanization; qualified refs and bracket text inside strings stay exact')

puts "== build_element =="
ds = { 'id' => 'ds-1', 'name' => 'Orders',
       'schema' => { 'columns' => [
         { 'name' => 'project_id', 'type' => 'STRING' },
         { 'name' => 'sales_amount', 'type' => 'DECIMAL' },
         { 'name' => 'order_date', 'type' => 'DATE' },
         { 'name' => 'City', 'type' => 'STRING' },
         { 'name' => 'State', 'type' => 'STRING' } ] } }
map = { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDERS' }
proj = [{ 'name' => 'full_region', 'sigmaFormula' => 'Concat([City], ", ", [State])', 'class' => 'projection' }]
el = build_element(ds, map, proj)

eq(el['kind'], 'table', 'element kind table')
eq(el['source'], { 'connectionId' => 'conn-1', 'kind' => 'warehouse-table', 'path' => %w[DB SCH ORDERS] }, 'warehouse-table source path')
eq(el['columns'][0]['formula'], '[ORDERS/Project Id]', 'base column formula uses table-prefixed display name')
# A Sigma column `format` keys on **kind**, never `type`, and there is no `date`
# kind — `datetime` + formatString covers it. This assertion previously encoded
# the bug ({'type' => 'date'}), which Sigma rejects outright:
#   POST /v2/dataModels/spec ->
#   "pages[0].elements[0].columns[8].format: Missing \"kind\" field"
# so ANY source DATE column failed the whole data-model POST (live-validated
# 2026-07-30; see refs/live-validation-2026-07-30.md).
eq(el['columns'][2]['format'], { 'kind' => 'datetime', 'formatString' => '%Y-%m-%d' },
   'date column format uses kind:datetime (never type:date — Sigma rejects that)')
calc = el['columns'].find { |c| c['name'] == 'Full Region' }
eq(!calc.nil?, true, 'projection Beast Mode added as DM calc column')
eq(calc['formula'], 'Concat([City], ", ", [State])', 'calc column carries translated sigmaFormula')
eq(el['order'].size, el['columns'].size, 'order lists every column')

puts "== dataset Beast Mode promotion matrix =="
outcomes = []
bm_element = build_element(ds, map, [
  {
    'id' => 'calculation_projection', 'name' => 'Project Label', 'class' => 'projection',
    'scope' => 'dataset', 'dataSourceId' => 'ds-1', 'sigmaFormula' => '[Project Id] & " label"',
    'converted' => true, 'lintErrors' => [],
  },
  {
    'id' => 'calculation_revenue', 'name' => 'Total Revenue', 'class' => 'aggregate',
    'scope' => 'dataset', 'dataSourceId' => 'ds-1', 'sigmaFormula' => 'Sum([Sales Amount])',
    'converted' => true, 'lintErrors' => [],
  },
  {
    'id' => 'calculation_window', 'name' => 'Running Revenue', 'class' => 'window',
    'scope' => 'dataset', 'dataSourceId' => 'ds-1', 'sigmaFormula' => 'CumulativeSum([Sales Amount])',
    'converted' => true, 'lintErrors' => [],
  },
  {
    'id' => 'calculation_bad', 'name' => 'Broken Metric', 'class' => 'aggregate',
    'scope' => 'dataset', 'dataSourceId' => 'ds-1', 'sigmaFormula' => 'Raw SQL',
    'converted' => false, 'lintErrors' => [],
  },
], outcomes: outcomes)
project_label = bm_element['columns'].find { |column| column['name'] == 'Project Label' }
ok(project_label, 'dataset projection becomes a data-model calculated column')
eq(project_label['id'], 'bm-col-calculation-projection', 'projection id is deterministic')
metric = bm_element['metrics'].find { |item| item['name'] == 'Total Revenue' }
ok(metric, 'dataset aggregate becomes a first-class Sigma metric')
eq(metric['formula'], 'Sum([Sales Amount])', 'metric keeps the translated aggregate formula')
eq(metric['id'], 'bm-metric-calculation-revenue', 'metric id is deterministic')
eq(outcomes.find { |item| item['id'] == 'calculation_window' }['status'], 'deferred',
   'window formula receives an explicit deferred outcome')
eq(outcomes.find { |item| item['id'] == 'calculation_bad' }['status'], 'blocked',
   'converted:false formula is blocked rather than emitted')

puts "== Beast Mode refs match camel-humanized physical/override column names =="
humanized = build_element(
  {
    'id' => 'ds-calls',
    'name' => 'Calls',
    'schema' => {
      'columns' => [
        { 'name' => 'Call DateTime', 'type' => 'DATETIME' },
        { 'name' => 'ResolutionDateTime', 'type' => 'DATETIME' },
      ],
    },
  },
  map.merge(
    'columnOverrides' => {
      'Call DateTime' => { 'formula' => '[ORDERS/Call DateTime Raw]' },
    },
  ),
  [
    {
      'id' => 'calculation_call_age',
      'name' => 'Call Age',
      'class' => 'projection',
      'scope' => 'dataset',
      'sigmaFormula' => 'DateDiff("minute", [Call DateTime], [ResolutionDateTime])',
      'converted' => true,
      'lintErrors' => [],
    },
    {
      'id' => 'calculation_latest_call',
      'name' => 'Latest Call',
      'class' => 'aggregate',
      'scope' => 'dataset',
      'sigmaFormula' => 'Max([Call DateTime])',
      'converted' => true,
      'lintErrors' => [],
    },
  ],
)
eq(humanized['columns'].find { |column| column['name'] == 'Call Date Time' }['formula'],
   '[ORDERS/Call DateTime Raw]',
   'derived column keeps its explicit source formula and receives the humanized display name')
eq(humanized['columns'].find { |column| column['name'] == 'Call Age' }['formula'],
   'DateDiff("minute", [Call Date Time], [Resolution Date Time])',
   'projection references resolve to the humanized DM column names')
eq(humanized['metrics'].find { |metric_item| metric_item['name'] == 'Latest Call' }['formula'],
   'Max([Call Date Time])',
   'aggregate metric references resolve to the same humanized DM column name')
eq(formula_column_references(
     'If([Call Date Time] > 0, "[Ignored Ref]", [SOURCE/Qualified])'
   ),
   ['Call Date Time'],
   'symbol-table scanner ignores string content and qualified source paths')

begin
  validate_element_formula_references!(
    {
      'columns' => [
        { 'id' => 'physical', 'formula' => '[CALLS/Call Date Time]' },
        { 'id' => 'broken', 'name' => 'Broken Calc', 'formula' => '[Call DateTime] + 1' },
      ],
      'metrics' => [],
    },
    dataset_id: 'ds-calls',
  )
  ok(false, 'preflight rejects a raw mixed camel/spaced reference before POST')
rescue ArgumentError => e
  ok(e.message.include?('[Call DateTime]') && e.message.include?('Call Date Time'),
     'preflight names the unresolved reference and emitted namespace')
end

puts "== Beast Mode name collisions are deterministic and visible =="
collision_outcomes = []
collision_element = build_element(ds, map, [{
  'id' => 'calculation_project_id', 'name' => 'Project Id', 'class' => 'aggregate',
  'scope' => 'dataset', 'sigmaFormula' => 'CountDistinct([Project Id])',
  'converted' => true, 'lintErrors' => [],
}], outcomes: collision_outcomes)
eq(collision_element['metrics'].first['name'], 'Project Id (Beast Mode)',
   'metric colliding with a physical column gets a deterministic suffix')
eq(collision_outcomes.first['sigmaName'], 'Project Id (Beast Mode)',
   'accounting records the emitted collision-safe name')

puts "== connection-id placeholder when unmapped =="
el2 = build_element(ds, {}, [])
eq(el2['source']['connectionId'], '<CONNECTION_ID>', 'unmapped → placeholder connectionId (flagged, not guessed)')

# ---------------------------------------------------------------------------
# Task 1 (2026-07-30 live validation): auto-fill dataset-map.json from Domo's
# connector stream configuration. All offline — no credentials, no network;
# fetch_stream_config itself is never called here, only the pure helpers and
# autofill_dataset_map with a stubbed `fetcher:`.

puts "== stream_config_hash (flatten Domo's configuration[] shape) =="
raw_conf = [
  { 'streamId' => 13, 'category' => 'STREAM', 'name' => 'databaseName', 'type' => 'string', 'value' => 'SALESDB' },
  { 'streamId' => 13, 'category' => 'STREAM', 'name' => 'schemaName',   'type' => 'string', 'value' => 'PUBLIC' },
  { 'streamId' => 13, 'category' => 'STREAM', 'name' => 'tableName',    'type' => 'string', 'value' => 'ORDERS' },
]
eq(stream_config_hash(raw_conf),
   { 'databaseName' => 'SALESDB', 'schemaName' => 'PUBLIC', 'tableName' => 'ORDERS' },
   'configuration[] flattened to a name=>value Hash')
eq(stream_config_hash(nil), {}, 'nil configuration -> {} (never raises)')

puts "== derive_map_entry: connector-backed DataSet (real table) =="
ds_conn = { 'id' => 'ds-conn', 'name' => 'Orders Feed' }
conf_table = { 'databaseName' => 'SALESDB', 'schemaName' => 'PUBLIC', 'tableName' => 'ORDERS' }
entry_conn = derive_map_entry(ds_conn, conf_table)
eq(entry_conn['_source'], 'domo-stream-config', 'connector-backed -> domo-stream-config')
eq(entry_conn['database'], 'SALESDB', 'database derived from stream config')
eq(entry_conn['schema'],   'PUBLIC',  'schema derived from stream config')
eq(entry_conn['table'],    'ORDERS',  'table derived from stream config')
eq(entry_conn['connectionId'], '', 'connectionId NEVER derived — stays blank even for a connector-backed DataSet')

puts "== derive_map_entry: query-only (custom-SQL report) stream — no table guessed =="
conf_query = { 'databaseName' => 'SALESDB', 'schemaName' => 'PUBLIC', 'query' => 'SELECT * FROM v_orders_report' }
entry_query = derive_map_entry(ds_conn, conf_query)
eq(entry_query['_source'], 'domo-stream-config-query-only', 'query-only stream flagged, not treated as a table')
eq(entry_query['table'], nil, 'no table guessed for a query-only stream')
eq(entry_query['_query'], 'SELECT * FROM v_orders_report', 'SQL recorded for human review')
eq(entry_query.key?('_note'), true, 'a human-facing note is attached')

puts "== derive_map_entry: non-connector DataSet (landed data, no warehouse source) =="
ds_landed = { 'id' => 'ds-landed', 'name' => 'Webform Upload' }
entry_landed = derive_map_entry(ds_landed, {})
eq(entry_landed['_source'], 'domo-landed-data', 'no stream config -> flagged as landed data')
eq(entry_landed['table'], nil, 'no table guessed for landed data (honest, not a bogus mapping)')
eq(entry_landed['database'], nil, 'no database guessed for landed data')

puts "== autofill_dataset_map: fills a brand-new entry via the stubbed fetcher (offline seam) =="
ds_by_id = { 'ds-conn' => ds_conn, 'ds-landed' => ds_landed }
fake_configs = { 'ds-conn' => conf_table, 'ds-landed' => {} }
stub_fetcher = ->(id) { fake_configs[id] }
merged, filled = autofill_dataset_map({}, ds_by_id, %w[ds-conn ds-landed], fetcher: stub_fetcher)
eq(filled, 2, 'both brand-new entries counted as filled')
eq(merged['ds-conn']['table'], 'ORDERS', 'ds-conn auto-filled via the stub fetcher, not real network')
eq(merged['ds-landed']['_source'], 'domo-landed-data', 'ds-landed correctly flagged, not fabricated')

puts "== autofill_dataset_map: never clobbers a complete hand-authored entry =="
hand_authored = { 'ds-conn' => { 'connectionId' => 'conn-99', 'database' => 'HANDDB',
                                 'schema' => 'HANDSCHEMA', 'table' => 'HAND_TABLE', 'name' => 'Hand Named' } }
never_called = ->(_id) { raise 'fetcher must NOT be called for a complete hand-authored entry' }
merged2, filled2 = autofill_dataset_map(hand_authored, ds_by_id, %w[ds-conn], fetcher: never_called)
eq(filled2, 0, 'complete hand-authored entry is not touched')
eq(merged2['ds-conn']['table'], 'HAND_TABLE', 'hand-authored table survives untouched')
eq(merged2['ds-conn']['database'], 'HANDDB', 'hand-authored database survives untouched')

puts "== autofill_dataset_map: fills a PARTIAL entry but preserves its connectionId =="
partial = { 'ds-conn' => { 'connectionId' => 'conn-99', 'database' => '', 'schema' => '', 'table' => '' } }
merged3, filled3 = autofill_dataset_map(partial, ds_by_id, %w[ds-conn], fetcher: stub_fetcher)
eq(filled3, 1, 'partial entry (blank table) IS re-derived')
eq(merged3['ds-conn']['table'], 'ORDERS', 'blank table auto-filled from stream config')
eq(merged3['ds-conn']['connectionId'], 'conn-99', 'human-supplied connectionId preserved — never invented, never clobbered')

puts "== placeholder_table: build_element never fabricates a table for flagged entries =="
el_query  = build_element(ds, entry_query,  [])
el_landed = build_element(ds, entry_landed, [])
eq(el_query['source']['path'].last,  '<TABLE:QUERY_ONLY_NEEDS_HUMAN>',        'query-only entry -> unmistakable sentinel, not a guessed table')
eq(el_landed['source']['path'].last, '<TABLE:LANDED_DATA_NO_WAREHOUSE_SOURCE>', 'landed-data entry -> unmistakable sentinel, not the DataSet display name')

puts '== column-preflight gate: build-dm.rb aborts when discovery/column-preflight.json is missing =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1',
          'SIGMA_SKIP_DOCTOR_GATE' => 'unit test: environment not under test' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok(!$?.success?, 'build-dm.rb fails when column-preflight.json is absent')
  ok(out.include?('preflight-columns.rb'), "the failure names the script to run first, got:\n#{out}")
end

puts '== column-preflight gate: a corrupted (unparsable) column-preflight.json is a LOUD failure, never a silent pass =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  File.write(File.join(dir, 'column-preflight.json'), '{not valid json')
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1',
          'SIGMA_SKIP_DOCTOR_GATE' => 'unit test: environment not under test' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok(!$?.success?, 'build-dm.rb fails when column-preflight.json fails to parse (never a silent pass)')
  ok(out.include?('column-preflight.json'), "the failure names column-preflight.json, got:\n#{out}")
  ok(out.include?('preflight-columns.rb'), "the failure names the script to re-run, got:\n#{out}")
end

puts '== column-preflight gate: build-dm.rb aborts when the report shows unresolved columns =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  File.write(File.join(dir, 'column-preflight.json'), JSON.generate(
    'ds-1' => { 'table' => 'ORDER_FACT', 'missing' => ['ORDER_ID'], 'resolved_by_exclude' => [],
                'resolved_by_override' => [], 'suggested_overrides' => {} }
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1',
          'SIGMA_SKIP_DOCTOR_GATE' => 'unit test: environment not under test' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok(!$?.success?, 'build-dm.rb fails when column-preflight.json reports a missing column')
  ok(out.include?('ORDER_ID'), "the failure names the specific unresolved column, got:\n#{out}")
end

puts '== column-preflight gate: a clean report lets build-dm.rb proceed =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  File.write(File.join(dir, 'column-preflight.json'), JSON.generate(
    'ds-1' => { 'table' => 'ORDER_FACT', 'missing' => [], 'resolved_by_exclude' => [],
                'resolved_by_override' => [], 'suggested_overrides' => {} }
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1',
          'SIGMA_SKIP_DOCTOR_GATE' => 'unit test: environment not under test' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-dm.rb succeeds when column-preflight.json is clean, got:\n#{out unless $?.success?}")
  ok(File.exist?(File.join(dir, 'dm-spec.json')), 'dm-spec.json was written')
end

puts '== column-preflight gate: SIGMA_SKIP_COLUMN_PREFLIGHT waives it, same as the doctor-gate convention =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  # deliberately no column-preflight.json at all
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1',
          'SIGMA_SKIP_COLUMN_PREFLIGHT' => 'unit test waiver',
          'SIGMA_SKIP_DOCTOR_GATE' => 'unit test: environment not under test' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-dm.rb succeeds when the gate is waived, got:\n#{out unless $?.success?}")
  ok(out.include?('WAIVED'), "the waiver is loudly logged, not silent, got:\n#{out}")
end

puts '== column-preflight gate: the C3 reuse-shortcut path is NEVER gated (nothing new is being built) =='
Dir.mktmpdir('build-dm-gate') do |dir|
  # No datasets.json/cards.json/dataset-map.json/column-preflight.json at all —
  # a confirmed auto-pick must short-circuit before any of that is read.
  File.write(File.join(dir, 'dm-match.json'), JSON.generate(
    'recommended_dm_id' => 'dm-existing-123', 'auto_picked' => true
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_SKIP_DOCTOR_GATE' => 'unit test: environment not under test' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok($?.success?, "build-dm.rb succeeds via the reuse shortcut with NO column-preflight.json present, got:\n#{out unless $?.success?}")
  ok(File.exist?(File.join(dir, 'dm-reuse.json')), 'dm-reuse.json was written (the reuse path actually ran)')
  ok(!out.include?('column-preflight'), "the reuse shortcut never even mentions the pre-flight gate, got:\n#{out}")
end

puts '== column-preflight gate: a report older than dataset-map.json is stale — aborts, never silently trusted =='
Dir.mktmpdir('build-dm-gate') do |dir|
  File.write(File.join(dir, 'datasets.json'), JSON.generate([
    { 'id' => 'ds-1', 'name' => 'Orders', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'LONG' }] } },
  ]))
  File.write(File.join(dir, 'cards.json'), JSON.generate([{ 'datasetId' => 'ds-1' }]))
  preflight_path = File.join(dir, 'column-preflight.json')
  File.write(preflight_path, JSON.generate(
    'ds-1' => { 'table' => 'ORDER_FACT', 'missing' => [], 'resolved_by_exclude' => [],
                'resolved_by_override' => [], 'suggested_overrides' => {} }
  ))
  old = Time.now - 3600
  File.utime(old, old, preflight_path) # explicitly backdate the "clean" report
  File.write(File.join(dir, 'dataset-map.json'), JSON.generate(
    'ds-1' => { 'connectionId' => 'conn-1', 'database' => 'DB', 'schema' => 'SCH', 'table' => 'ORDER_FACT' }
  ))
  env = { 'DOMO_DISCOVERY_DIR' => dir, 'SIGMA_FOLDER_ID' => 'folder-1', 'SIGMA_SKIP_DOCTOR_GATE' => 'unit test' }
  out = IO.popen(env, ['ruby', File.join(SKILL_ROOT, 'scripts', 'build-dm.rb')], err: [:child, :out], &:read)
  ok(!$?.success?, "build-dm.rb fails when column-preflight.json predates dataset-map.json, got:\n#{out unless $?.success?}")
  ok(out.include?('predates') && out.include?('preflight-columns.rb'),
     "the failure explains the report is stale and names the fix, got:\n#{out}")
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
