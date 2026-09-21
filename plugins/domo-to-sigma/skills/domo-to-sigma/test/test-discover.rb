#!/usr/bin/env ruby
# Unit tests for domo-discover.rb pure helpers (no network). Validates the
# two-shape card-def normalizer, Beast Mode classification, and summary-number
# extraction against synthetic fixtures modeled on the confirmed Domo shapes
# (Shape A = official CardDefinition, Shape B = internal analyzer definition).
#
#   ruby test/test-discover.rb
#
# discovery/ is created on load (gitignored) — harmless.

ARGV.clear                       # ensure domo-discover.rb's main flow is a no-op
require_relative '../scripts/domo-discover'
require_relative '../scripts/lib/domo_sigma_util'
require 'base64'
require 'stringio'
include DomoSigma

FIXTURE_DIR = File.join(__dir__, 'fixtures', 'domo-live-raw')
def load_fixture(name)
  JSON.parse(File.read(File.join(FIXTURE_DIR, name)))
end

# Kernel#warn writes to $stderr — swap it for a StringIO so a "warn loudly,
# never silently" assertion is an actual check, not an eyeballed log line.
def capture_stderr
  old = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = old
end

# Minimal stub harness for the Domo REST wrapper: temporarily override a
# module_function singleton method (Domo.foo), run the block, then ALWAYS
# restore the original — even on assertion failure — so a stub from one test
# section can never leak into a later one. Used throughout below to exercise
# the Bug 1 (card enumeration) and Bug 4 (Beast Mode classification) fallback
# logic entirely offline, with no network/credentials.
def with_domo_stub(method_name, impl)
  orig = Domo.method(method_name)
  Domo.define_singleton_method(method_name, &impl)
  yield
ensure
  Domo.define_singleton_method(method_name, &orig)
end

$failures = 0
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end
def ok(cond, msg)
  eq(!!cond, true, msg)
end

puts "== sigma_kind_hint =="
eq(sigma_kind_hint('badge_vert_bar'),      'bar-chart',     'badge_vert_bar → bar-chart')
eq(sigma_kind_hint('badge_horiz_bar'),     'bar-chart',     'badge_horiz_bar → bar-chart')
eq(sigma_kind_hint('badge_xyscatterplot'), 'scatter-chart', 'badge_xyscatterplot → scatter-chart')
eq(sigma_kind_hint('badge_datagrid'),      'table',         'badge_datagrid → table')
eq(sigma_kind_hint('badge_singlevalue'),   'kpi-chart',     'badge_singlevalue → kpi-chart')
eq(sigma_kind_hint('badge_line'),          'line-chart',    'badge_line → line-chart')
eq(sigma_kind_hint('badge_pie'),           'donut-chart',   'badge_pie → donut-chart')
eq(sigma_kind_hint('badge_pivottable'),    'pivot-table',   'pivot → pivot-table')
eq(sigma_kind_hint('mystery_widget'),      nil,             'unknown → nil (read PNG)')

puts "== classify_beast_mode (heuristic, no template) =="
eq(classify_beast_mode('SUM(SUM(`Total Sales`) FIXED (BY `Region`))'), 'lod',        'FIXED → lod')
eq(classify_beast_mode('RANK() OVER(ORDER BY SUM(`Sales`) DESC)'),     'window',     'OVER → window')
eq(classify_beast_mode('sum(sum(`visits`)) over(partition by `x`)'),   'window',     'running-total OVER → window')
eq(classify_beast_mode('SUM(`IntegerColumn`)'),                         'aggregate',  'SUM(col) → aggregate')
eq(classify_beast_mode("CONCAT(`City`, ', ', `State`)"),               'projection', 'CONCAT → projection')
eq(classify_beast_mode("CASE WHEN `c` = 'x' THEN 'y' ELSE 'z' END"),   'projection', 'row-level CASE → projection')

puts "== classify_beast_mode (API flags win) =="
eq(classify_beast_mode('anything', { 'analytic' => true }),   'window',     'analytic flag → window')
eq(classify_beast_mode('anything', { 'aggregated' => true }), 'aggregate',  'aggregated flag → aggregate')
eq(classify_beast_mode('CONCAT(a,b)', { 'aggregated' => false, 'analytic' => false }), 'projection', 'no flags → projection')

puts "== normalize_card: Shape A =="
shape_a = {
  'title' => 'Revenue by Region', 'chartType' => 'badge_vert_bar', 'dataSetId' => 'ds-1',
  'chartBody' => {
    'columns' => [
      { 'column' => 'store_region', 'alias' => 'Store Region' },
      { 'column' => 'sales_amount', 'alias' => 'Sales', 'aggregation' => 'SUM',
        'format' => { 'type' => 'CURRENCY' } },
    ],
    'groupBy' => [{ 'column' => 'store_region' }],
    'orderBy' => [{ 'column' => 'sales_amount' }],
    'filters' => [{ 'column' => 'status', 'operand' => 'IN', 'values' => %w[Active Pending] }],
    'limit' => 25,
  },
  'summaryNumber' => { 'columns' => [{ 'column' => 'sales_amount', 'aggregation' => 'SUM',
                                       'alias' => 'Total Revenue', 'format' => { 'type' => 'CURRENCY' } }] },
  'calculatedFields' => [{ 'id' => 'calculation_abc', 'name' => 'Margin', 'formula' => 'SUM(`profit`)/SUM(`sales`)' }],
  'conditionalFormats' => [],
}
a = normalize_card(shape_a, 'card-A')
eq(a['_shape'], 'A', 'shape detected A')
eq(a['title'], 'Revenue by Region', 'title')
eq(a['sigmaKindHint'], 'bar-chart', 'kind hint bar-chart')
eq(a['columns'].map { |c| c['alias'] }, ['Store Region', 'Sales'], 'aliases carried (fixes raw-name bug)')
eq(a['columns'][1]['aggregation'], 'SUM', 'column aggregation')
eq(a['groupBy'], ['store_region'], 'groupBy flattened')
eq(a['orderBy'], ['sales_amount'], 'orderBy flattened')
eq(a['filters'], [{ 'column' => 'status', 'operator' => 'IN', 'values' => %w[Active Pending] }], 'filter normalized (operand→operator)')
eq(a['summaryNumber']['column'], 'sales_amount', 'summary number column')
eq(a['summaryNumber']['aggregation'], 'SUM', 'summary number aggregation')
eq(a['summaryNumber']['label'], 'Total Revenue', 'summary number label from alias')
eq(a['summaryNumber']['_defaultCountSuspect'], false, 'SUM is not a COUNT-of-id suspect')
eq(a['cardFormulas'].size, 1, 'card-local formula captured')
eq(a['limit'], 25, 'limit carried through Shape A normalization (bead 2ef7)')

puts "== normalize_card: Shape B =="
shape_b = {
  'chartType' => 'badge_datagrid', 'dataSetId' => 'ds-2',
  'definition' => {
    'dynamicTitle' => { 'text' => [{ 'type' => 'TEXT', 'text' => 'Project List' }] },
    'subscriptions' => { 'main' => {
      'columns' => [
        { 'column' => 'project_id' },
        { 'column' => 'calculation_xyz', 'formulaId' => 'calculation_xyz' },
      ],
      'filters' => [{ 'column' => 'region', 'filterType' => 'IN', 'values' => ['West'] }],
      'groupBy' => [{ 'column' => 'project_id' }],
      'orderBy' => [{ 'column' => 'project_id' }],
      'limit' => 25,
    } },
    'formulas' => [{ 'id' => 'calculation_xyz', 'name' => 'Days Open', 'formula' => 'DATEDIFF(`close`,`open`)' }],
    'conditionalFormats' => [{ 'condition' => { 'column' => 'x' }, 'format' => {} }],
  },
}
b = normalize_card(shape_b, 'card-B')
eq(b['_shape'], 'B', 'shape detected B')
eq(b['title'], 'Project List', 'title from dynamicTitle')
eq(b['sigmaKindHint'], 'table', 'kind hint table')
eq(b['columns'][1]['beastModeId'], 'calculation_xyz', 'beastModeId joined via calculation_ id')
eq(b['filters'], [{ 'column' => 'region', 'operator' => 'IN', 'values' => ['West'] }], 'filter normalized (filterType→operator)')
eq(b['groupBy'], ['project_id'], 'groupBy flattened (Shape B)')
eq(b['cardFormulas'].first['name'], 'Days Open', 'card formulas from definition.formulas')
eq(b['limit'], 25, 'limit carried through Shape B normalization (bead 2ef7)')

puts "== POP comparison metadata falls back from private Shape B to public Shape A =="
private_pop = normalize_card({
  'chartType' => 'badge_pop_bar_line',
  'definition' => {
    'title' => '1-30 $ YoY',
    'subscriptions' => {
      'main' => {
        'columns' => [
          { 'column' => 'Date', 'mapping' => 'ITEM' },
          { 'column' => '1-30', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
        ],
        'dateRangeFilter' => {
          'column' => { 'column' => 'Date' },
          'dateTimeRange' => {
            'dateTimeRangeType' => 'INTERVAL_OFFSET',
            'interval' => 'YEAR', 'offset' => 0, 'count' => 0,
          },
        },
      },
    },
  },
}, 'pop-private')
public_pop = {
  'title' => '1-30 $ YoY',
  'chartType' => 'badge_pop_bar_line',
  'chartBody' => {
    'columns' => [
      { 'column' => 'Date', 'mapping' => 'ITEM' },
      { 'column' => '1-30', 'aggregation' => 'SUM', 'mapping' => 'VALUE' },
    ],
    'dateGrain' => { 'column' => 'Date', 'dateTimeElement' => 'MONTH' },
    'dateRangeFilter' => {
      'column' => 'Date',
      'dateTimeRange' => {
        'dateTimeRangeType' => 'INTERVAL_OFFSET',
        'interval' => 'YEAR', 'offset' => 0, 'count' => 0,
      },
      'periods' => {
        'type' => 'COMBINED',
        'combined' => [{ 'interval' => 'YEAR', 'type' => 'OFFSET', 'count' => 1 }],
        'count' => 0,
      },
    },
  },
}
enriched_pop = merge_public_pop_comparison(private_pop, public_pop, 'pop-private')
ok(pop_comparison_periods?(enriched_pop['dateRangeFilter']),
   'public CardDefinition restores the prior-year offset missing from private analyzer data')
eq(enriched_pop.dig('dateRangeFilter', 'column'), { 'column' => 'Date' },
   'private date binding remains authoritative while public periods are merged')
eq(enriched_pop['dateGrain'], { 'column' => 'Date', 'dateTimeElement' => 'MONTH' },
   'public date grain fills the private omission needed for POP alignment')
eq(enriched_pop['_popComparisonSource'], 'public-card-definition',
   'backfill is explicitly attributable in cards.json')
eq(enriched_pop['columns'], private_pop['columns'],
   'public fallback does not replace private formula/column bindings')

already_complete = private_pop.merge(
  'dateRangeFilter' => public_pop.dig('chartBody', 'dateRangeFilter')
)
different_public = Marshal.load(Marshal.dump(public_pop))
different_public.dig('chartBody', 'dateRangeFilter', 'periods', 'combined', 0)['count'] = 2
unchanged_pop = merge_public_pop_comparison(already_complete, different_public, 'pop-complete')
eq(unchanged_pop.dig('dateRangeFilter', 'periods', 'combined', 0, 'count'), 1,
   'existing private comparison metadata wins without a redundant public override')

public_without_periods = Marshal.load(Marshal.dump(public_pop))
public_without_periods.dig('chartBody', 'dateRangeFilter').delete('periods')
probed_no_periods = merge_public_pop_comparison(
  private_pop, public_without_periods, 'pop-no-periods'
)
eq(probed_no_periods['_popComparisonProbe'], 'public-no-periods',
   'successful public probe distinguishes a genuine no-periods card from failed extraction')

consecutive_pop = Marshal.load(Marshal.dump(private_pop))
consecutive_pop['dateRangeFilter']['periods'] = {
  'type' => 'COMBINED',
  'combined' => [{ 'type' => 'CONSECUTIVE', 'count' => 1 }],
  'count' => 0,
}
ok(pop_comparison_periods?(consecutive_pop['dateRangeFilter']),
   'CONSECUTIVE compare metadata is a real prior period, not missing metadata')
consecutive_unchanged = merge_public_pop_comparison(
  consecutive_pop, public_without_periods, 'pop-consecutive'
)
ok(!consecutive_unchanged.key?('_popComparisonProbe'),
   'a private CONSECUTIVE period never receives the false public-no-periods marker')

puts "== normalize_card: Shape B prefers operand over conflicting filterType =="
shape_b_operand_wins = {
  'chartType' => 'badge_bar', 'dataSetId' => 'ds-2b',
  'definition' => {
    'title' => 'Exclude Midwest',
    'subscriptions' => { 'main' => {
      'columns' => [{ 'column' => 'region' }],
      # Live Shape-B often carries BOTH: real operator in `operand`, opaque
      # collapsed token in `filterType`. operand must win or NOT_IN becomes
      # LEGACY→include (exact inverse).
      'filters' => [{ 'column' => 'region', 'operand' => 'NOT_IN',
                     'filterType' => 'LEGACY', 'values' => ['Midwest'] }],
    } },
  },
}
b_op = normalize_card(shape_b_operand_wins, 'card-B-operand')
eq(b_op['filters'],
   [{ 'column' => 'region', 'operator' => 'NOT_IN', 'values' => ['Midwest'] }],
   'Shape B: operand wins over conflicting filterType (NOT_IN not collapsed to LEGACY)')

puts "== normalize_card: no limit declared -> key absent, not zero =="
no_limit = normalize_card({ 'chartType' => 'badge_table', 'chartBody' => { 'columns' => [{ 'column' => 'x' }] } }, 'card-C')
ok(!no_limit.key?('limit'), 'no limit key when the source declared none (compact drops nil, never defaults to 0)')

puts "== norm_summary_number: COUNT-of-id trap =="
sn = norm_summary_number({ 'columns' => [{ 'column' => 'project_id', 'aggregation' => 'COUNT' }] })
eq(sn['_defaultCountSuspect'], true, 'COUNT flagged as default-count suspect (#1 KPI bug guard)')

puts "== dig_beast_modes: dataset map + card formulas =="
ds_map = { 'calculation_ds1' => { 'id' => 'calculation_ds1', 'name' => 'DS Calc',
                                  'formula' => 'SUM(`x`)', 'templateId' => 'calculation_ds1' } }
card = { 'id' => 'c1', 'datasetId' => 'ds-2',
         'cardFormulas' => [{ 'id' => 'calculation_c1', 'name' => 'Card Calc', 'formula' => "CONCAT(`a`,`b`)" }] }
bms = dig_beast_modes(card, ds_map, {})
eq(bms.map { |x| x['scope'] }.sort, %w[card dataset], 'both dataset + card beast modes collected')
eq(bms.find { |x| x['scope'] == 'dataset' }['class'], 'aggregate', 'dataset SUM classified aggregate')
eq(bms.find { |x| x['scope'] == 'card' }['class'], 'projection', 'card CONCAT classified projection')

puts "== dataset formula payload normalization preserves empty vs missing =="
eq(dataset_formula_entries({ 'a' => { 'id' => 'a' } }), [{ 'id' => 'a' }],
   'map payload normalizes through its values')
eq(dataset_formula_entries([{ 'id' => 'a' }]), [{ 'id' => 'a' }],
   'array payload normalizes directly')
eq(dataset_formula_entries({}), [], 'empty map is a genuine empty formula collection')
eq(dataset_formula_entries(nil), nil, 'missing formula block remains distinguishable from empty')
eq(dataset_formula_map({ 'properties' => { 'formulas' => { 'formulas' => {} } } }), {},
   'present empty API block becomes an empty map, not an extraction error')
eq(dataset_formula_map({}), nil, 'missing API block is an extraction error signal')
reconciled = reconcile_dataset_formula_inventory(
  { 'ds-1' => { 'status' => 'ok', 'count' => 2 } },
  { 'ds-1' => {
    'calculation_a' => { 'id' => 'calculation_a' },
    'calculation_b' => { 'id' => 'calculation_b' },
  } },
  [{ 'id' => 'calculation_a', 'scope' => 'dataset', 'dataSourceId' => 'ds-1' }]
)
eq(reconciled['ds-1']['status'], 'error', 'API/discovery count mismatch becomes an error')
eq(reconciled['ds-1']['missingIds'], ['calculation_b'],
   'reconciliation names every dataset formula omitted from beast-modes.json')

puts "== normalize_card resolves dataset-only calculation references =="
dataset_only = {
  'calculation_dataset_only' => {
    'id' => 'calculation_dataset_only',
    'name' => 'Technical Error Type',
    'formula' => 'IFNULL(`error_type`, -3)',
    'persistedOnDataSource' => true,
    'dataType' => 'LONG',
  },
}
dataset_ref_card = normalize_card({
  'chartType' => 'badge_table',
  'definition' => {
    'title' => 'Abandon Rate',
    'subscriptions' => {
      'main' => {
        'columns' => [{ 'column' => 'calculation_dataset_only' }],
        'filters' => [{
          'column' => 'calculation_dataset_only',
          'operand' => 'NOT_IN',
          'values' => ['-3'],
        }],
      },
    },
    'formulas' => [],
  },
}, 'card-dataset-ref', dataset_formulas: dataset_only)
eq(dataset_ref_card['columns'].first['column'], 'Technical Error Type',
   'dataset-only calculated chart column resolves to its authored name')
eq(dataset_ref_card['filters'].first['column'], 'Technical Error Type',
   'dataset-only calculated filter resolves to its authored name')

puts "== normalize_card preserves Analyzer Quick Filters / slicers =="
quick_filter = {
  'type' => 'string', 'displayType' => 'multiple_select',
  'name' => 'Category', 'column' => 'CATEGORY_NAME', 'operator' => 'IN',
  'values' => [], 'collapsed' => false, 'controlType' => 'SLICER',
}
shape_b_quick = normalize_card({
  'definition' => {
    'title' => 'Daily Category Detail',
    'charts' => { 'main' => { 'chartType' => 'badge_table' } },
    'subscriptions' => { 'main' => { 'columns' => [{ 'column' => 'CATEGORY_NAME' }] } },
    'slicers' => [quick_filter],
  },
}, 'quick-b')
eq(shape_b_quick['quickFilters'], [quick_filter],
   'Shape B definition.slicers survives discovery as quickFilters')

shape_a_quick = normalize_card({
  'title' => 'Daily Category Detail', 'chartType' => 'badge_table',
  'chartBody' => { 'columns' => [{ 'column' => 'CATEGORY_NAME' }] },
  'quickFilters' => [quick_filter],
}, 'quick-a')
eq(shape_a_quick['quickFilters'], [quick_filter],
   'Shape A quickFilters survives discovery under the same normalized key')

shape_b_stack_quick = normalize_card({
  'definition' => {
    'title' => 'Daily Category Detail',
    'charts' => { 'main' => { 'chartType' => 'badge_table' } },
    'subscriptions' => { 'main' => { 'columns' => [{ 'column' => 'CATEGORY_NAME' }] } },
    'slicers' => [],
  },
}, 'quick-stack', card_meta: { 'slicers' => [quick_filter] })
eq(shape_b_stack_quick['quickFilters'], [quick_filter],
   'stacks-response slicers are retained when the analyzer definition omits them')

puts "== dig_beast_modes backfills missing SQL from the template endpoint =="
template_dev_token = ENV['DOMO_DEV_TOKEN']
ENV['DOMO_DEV_TOKEN'] = 'fake-token-for-offline-test'
with_domo_stub(:beast_mode_template, ->(*_a) {
  { 'expression' => 'SUM(`Amount`)', 'aggregated' => true }
}) do
  modes = dig_beast_modes(
    { 'id' => 'c-template', 'datasetId' => 'ds-template', 'cardFormulas' => [] },
    { 'calculation_template' => {
      'id' => 'calculation_template', 'name' => 'Template Only', 'templateId' => 'template-1',
    } },
    {}
  )
  eq(modes.first['sql'], 'SUM(`Amount`)', 'template expression supplies missing inline SQL')
  eq(modes.first['dataSourceId'], 'ds-template', 'backfilled dataset formula keeps dataset identity')
end
with_domo_stub(:beast_mode_template, ->(*_a) { nil }) do
  missing_body = dig_beast_modes(
    { 'id' => 'c-missing-template', 'datasetId' => 'ds-template', 'cardFormulas' => [] },
    { 'calculation_missing' => {
      'id' => 'calculation_missing', 'name' => 'Missing Body', 'templateId' => 'template-missing',
    } },
    {}
  )
  eq(missing_body.size, 1, 'missing formula body remains in inventory instead of disappearing')
  ok(missing_body.first['extractionError'].include?('template lookup'),
     'missing inline and template SQL receives an explicit extraction error')
end
template_dev_token ? ENV['DOMO_DEV_TOKEN'] = template_dev_token : ENV.delete('DOMO_DEV_TOKEN')

puts "== divergent dataset/card copies are surfaced =="
divergent_warning = capture_stderr do
  divergent = dedupe_beast_modes([
    { 'id' => 'calculation_conflict', 'name' => 'Rate', 'scope' => 'dataset', 'sql' => 'SUM(`A`)' },
    { 'id' => 'calculation_conflict', 'name' => 'Rate', 'scope' => 'card', 'sql' => 'SUM(`B`)' },
  ])
  eq(divergent.size, 1, 'duplicate id still emits exactly one canonical formula')
  eq(divergent.first['definitionConflict'], true, 'kept formula is marked for parity review')
end
ok(divergent_warning.include?('divergent') && divergent_warning.include?('calculation_conflict'),
   'divergence warning names the conflicting Beast Mode')

puts "== merge_dataset_permissions: C9 wiring (dataset_formulas permission -> datasets.json) =="
# Synthetic response shaped like Domo.dataset_formulas(dsid) — the SAME call
# already made per-card for Beast Modes (parts=core,permission,formulas). Only
# the top-level `permission` key is asserted; its inner shape is whatever a
# live instance actually returns.
synthetic_dataset_formulas_response = {
  'id' => 'ds-1',
  'properties' => { 'formulas' => { 'formulas' => {} } },
  'permission' => { 'policies' => [
    { 'id' => 'p1', 'name' => 'West only', 'predicates' => ['region = "West"'] },
  ] },
}
permission_cache = { 'ds-1' => synthetic_dataset_formulas_response['permission'] }
datasets = [
  { 'id' => 'ds-1', 'name' => 'Orders' },       # has a captured permission block
  { 'id' => 'ds-2', 'name' => 'No PDP here' },  # no entry in permission_cache
]

merged_count, out = merge_dataset_permissions(datasets, permission_cache)
eq(merged_count, 1, 'exactly one dataset record merged')
eq(out.size, 2, 'record count unchanged')
ds1 = out.find { |d| d['id'] == 'ds-1' }
ds2 = out.find { |d| d['id'] == 'ds-2' }
eq(ds1['permission'], synthetic_dataset_formulas_response['permission'], 'permission attached as-is (no reshaping)')
eq(ds2.key?('permission'), false, 'dataset with no captured permission is left untouched')

# Through the REAL normalize/merge path: detect_pdp (build-dm.rb's C9 reader)
# must find the policy on the merged record — proving the wiring actually
# reaches the existing tolerant reader, end to end.
pols = detect_pdp(ds1)
eq(pols.length, 1, 'detect_pdp finds the merged policy')
eq(pols.first['id'], 'p1', 'detect_pdp reads the policy id off the merged record')
eq(detect_pdp(ds2), [], 'detect_pdp still empty (not nil) for the untouched dataset')

puts "== merge_dataset_permissions: no captured permissions -> no-op =="
no_op_count, no_op_out = merge_dataset_permissions(datasets, {})
eq(no_op_count, 0, 'nothing merged when permission_cache is empty')
eq(no_op_out.none? { |d| d.key?('permission') }, true, 'no dataset gains a permission key')

# ===========================================================================
# Live-validation fixes (refs/live-validation-2026-07-30.md) — Bugs 1-4.
# Fixtures under test/fixtures/domo-live-raw/ are ANONYMIZED derivations of
# the real corpus (structure only — no real titles/columns/connector names).
# ===========================================================================
stacks_fixture = load_fixture('stacks-page.json')
admin_fixture  = load_fixture('cards-adminsummary.json')
public_fixture = load_fixture('cards-public.json')
v3_fixture     = load_fixture('card-definition-v3.json')
v3_beastmode_kpi_fixture = load_fixture('card-definition-v3-beastmode-kpi.json')
orig_dev_token_env = ENV['DOMO_DEV_TOKEN']

puts "== Bug 1: enumerate_page_cards — route 1 (stacks) used when it returns cards =="
with_domo_stub(:cards_for_page, ->(*_a, **_kw) { stacks_fixture }) do
  ids, meta_by_id, stacks = enumerate_page_cards('90210001')
  eq(ids.map(&:to_s).sort, stacks_fixture['cards'].map { |c| c['id'].to_s }.sort,
     'route 1 (stacks) supplies every card id — old code read the (empty) page[\'cardIds\'] instead')
  eq(stacks, stacks_fixture, 'the full stacks payload is returned for the Bug 5 geometry merge')
  eq(meta_by_id['700000001']['metadata']['chartType'], 'badge_map',
     'route 1 per-card record carries metadata.chartType (feeds Bug 3 chartType resolution)')
end

puts "== Bug 1: enumerate_page_cards — route 2 (adminsummary) used when route 1 is empty =="
ENV['DOMO_DEV_TOKEN'] = 'fake-token-for-offline-test'
with_domo_stub(:cards_for_page, ->(*_a, **_kw) { { 'cards' => [] } }) do
  with_domo_stub(:cards_adminsummary, ->(*_a, **_kw) { admin_fixture }) do
    ids, meta_by_id, stacks = enumerate_page_cards('90210001')
    eq(ids.sort, [700000005, 700000006], 'route 2 (adminsummary) card ids used as fallback')
    eq(stacks, nil, 'route 2 supplies no stacks/geometry payload (graceful degradation)')
    eq(meta_by_id['700000005']['title'], 'Metric Epsilon', 'route 2 record carries a title')
  end
end
ENV['DOMO_DEV_TOKEN'] = orig_dev_token_env

puts "== Bug 1: enumerate_page_cards — route 3 (PUBLIC) is reachable on Tier B =="
ENV.delete('DOMO_DEV_TOKEN')  # Tier B: routes 1/2 are private-gated and must not even be attempted
with_domo_stub(:list_cards, ->(*_a, **_kw) { public_fixture }) do
  ids, meta_by_id, stacks = enumerate_page_cards('90210001')
  eq(ids.sort, %w[700000007 700000008],
     'Tier B now yields a real card inventory via the public route, filtered to this page id')
  eq(stacks, nil, 'route 3 supplies no stacks/geometry payload')
  eq(meta_by_id.key?('700000009'), false, 'a card on a DIFFERENT page is excluded')
end
ENV['DOMO_DEV_TOKEN'] = orig_dev_token_env

puts "== Bug 1: Domo.list_cards caps limit at 100 (a higher limit silently returns empty on live Domo) =="
captured_query = nil
with_domo_stub(:public_get, ->(_path, query: nil, **_kw) { captured_query = query; { 'cards' => [] } }) do
  Domo.list_cards(limit: 500, offset: 0)
end
eq(captured_query[:limit], 100, 'Domo.list_cards caps the requested limit at 100 regardless of caller input')

puts "== Bug 1: Domo.cards_adminsummary — filter in BODY, pagination in QUERY params =="
captured_body, captured_query2 = nil, nil
with_domo_stub(:private_post, ->(_path, body:, query: nil) { captured_body = body; captured_query2 = query; { 'cardAdminSummaries' => [] } }) do
  Domo.cards_adminsummary('90210001', skip: 100, limit: 100)
end
eq(captured_body[:pageIds], ['90210001'], 'adminsummary filter (pageIds/orderBy/ascending) travels in the BODY')
eq([captured_query2[:skip], captured_query2[:limit]], [100, 100],
   'adminsummary pagination (skip/limit) travels in QUERY params, not the body')

puts "== Bug 3: Domo.card_definition_v3 — minimal body, no dynamicText/variables clutter =="
captured_v3_body = nil
with_domo_stub(:private_put, ->(_path, body:, query: nil) { captured_v3_body = body; {} }) do
  Domo.card_definition_v3('700000001')
end
eq(captured_v3_body, { urn: '700000001' }, 'card_definition_v3 body is just {urn: id} — confirmed sufficient live')

puts "== Bug 2: normalize_card — subscriptions.big_number is the summary number =="
stacks_meta_alpha = stacks_fixture['cards'].find { |c| c['id'] == 700000001 }
card_v3 = normalize_card(v3_fixture, '700000001', card_meta: stacks_meta_alpha)
eq(card_v3['summaryNumber'] && card_v3['summaryNumber']['column'], 'metric_alpha',
   'big_number column extracted (nil under old defn/main-summaryNumber-only code — Rule 0 never fired)')
eq(card_v3['summaryNumber'] && card_v3['summaryNumber']['aggregation'], 'SUM', 'big_number aggregation extracted')
eq(card_v3['summaryNumber'] && card_v3['summaryNumber']['label'], 'Metric Alpha in Period', 'big_number label extracted')
eq(card_v3['summaryNumber'] && card_v3['summaryNumber']['_defaultCountSuspect'], false,
   'SUM is not a COUNT-of-id default-count suspect')

puts "== Bug 2: normalize_card — main.columns[].mapping (visual-role binding) surfaced, not dropped =="
mapping_by_column = (card_v3['columns'] || []).each_with_object({}) { |c, h| h[c['column']] = c['mapping'] }
eq(mapping_by_column['category_col'], 'ITEM', 'ITEM mapping surfaced')
eq(mapping_by_column['metric_alpha'], 'VALUE', 'VALUE mapping surfaced')
eq(mapping_by_column['series_col'], 'SERIES', 'SERIES mapping surfaced')

puts "== Bug 3: normalize_card — chartType resolution precedence =="
eq(card_v3['chartType'], 'badge_map',
   'metadata.chartType (from the route-1 enumeration record) wins over definition.charts.main.chartType')
card_v3_no_meta = normalize_card(v3_fixture, '700000001')
eq(card_v3_no_meta['chartType'], 'badge_treemap',
   'with NO enumeration metadata at all, Shape B falls back to its OWN definition.charts.main.chartType ' \
   '(old code produced nil here — this chartType location did not exist in the old resolution chain)')

puts "== Bug 3: parse_card_metadata — JSON-string metadata fields double-parsed, malformed guarded =="
meta_alpha = stacks_fixture['cards'].find { |c| c['id'] == 700000001 }
parsed_alpha = parse_card_metadata(meta_alpha)
eq(parsed_alpha['columnAliases'], { 'state_col' => 'State', 'name_col' => 'Name' },
   'columnAliases JSON string double-parsed into a real Hash')
eq(parsed_alpha['summaryNumberFormat'], { 'type' => 'number', 'format' => '0.0A' },
   'SummaryNumberFormat JSON string double-parsed into a real Hash')

meta_gamma = stacks_fixture['cards'].find { |c| c['id'] == 700000003 }
parsed_gamma = parse_card_metadata(meta_gamma)
eq(parsed_gamma.key?('columnAliases'), false,
   'malformed columnAliases JSON degrades to absent — never raises and aborts discovery for one bad card')
eq(parsed_gamma['chartType'], 'badge_donut', 'chartType still read even when a sibling metadata field is malformed')

eq(card_v3['_metadata'] && card_v3['_metadata']['chartType'], 'badge_map',
   'normalize_card surfaces the parsed metadata on the card record as _metadata')
eq(card_v3['_metadata'] && card_v3['_metadata']['summaryNumberFormat'], { 'type' => 'number', 'format' => '0.0A' },
   '_metadata carries the double-parsed SummaryNumberFormat too')

puts "== Bug 4: dig_beast_modes — inline isAnalytic/isAggregatable preferred over a template fetch =="
template_calls = 0
with_domo_stub(:beast_mode_template, ->(*_a) { template_calls += 1; {} }) do
  card_inline = { 'id' => '700000001', 'datasetId' => nil, 'cardFormulas' => v3_fixture['definition']['formulas'] }
  bms = dig_beast_modes(card_inline, {}, {})
  eq(bms.find { |b| b['name'] == 'Open Rate' }['class'], 'aggregate',
     'isAggregatable:true classified aggregate straight from the inline formula (old code called fetch_template ' \
     'and would classify by the empty-hash stub instead — "projection")')
  eq(bms.find { |b| b['name'] == 'Running Total' }['class'], 'window',
     'isAnalytic:true classified window straight from the inline formula')
  eq(template_calls, 0, 'the standalone template endpoint was NOT called — inline flags were sufficient (Bug 4)')
end

puts "== Bug 4: dig_beast_modes — still falls back to the template fetch when inline flags are absent =="
template_calls2 = 0
with_domo_stub(:beast_mode_template, ->(*_a) { template_calls2 += 1; { 'analytic' => true } }) do
  ENV['DOMO_DEV_TOKEN'] = 'fake-token-for-offline-test'
  card_no_flags = { 'id' => 'c-no-flags',
                    'cardFormulas' => [{ 'id' => 'calculation_nf', 'name' => 'No Flags', 'formula' => 'anything' }] }
  bms2 = dig_beast_modes(card_no_flags, {}, {})
  eq(bms2.first['class'], 'window', 'template-fetch fallback still classifies correctly when inline flags are missing')
  eq(template_calls2, 1, 'the standalone template endpoint IS called when inline flags are absent (fallback preserved)')
  ENV['DOMO_DEV_TOKEN'] = orig_dev_token_env
end

# ===========================================================================
# Bug A (refs/live-validation-2026-07-30.md): a KPI whose measure is a Beast
# Mode extracted with NO value. Live Domo binds the summary number's measure
# by `formulaId` (with NO `column`/`aggregation` on that columns[] entry) when
# the measure is a Beast Mode — resolve it against the card's own
# definition.formulas[] and surface the Beast Mode's name, never inventing an
# aggregation the SQL already applies.
# ===========================================================================
puts "== Bug A: norm_summary_number — Beast Mode summary number resolved via formulaId =="
beastmode_card = normalize_card(v3_beastmode_kpi_fixture, '700000010')
sn_bm = beastmode_card['summaryNumber']
eq(sn_bm && sn_bm['column'], 'Metric Ratio Pct',
   "formulaId resolved against this card's OWN definition.formulas[] -> the Beast Mode's name becomes the measure " \
   '(nil under old code, which only ever read column/dataColumn/field)')
eq(sn_bm && sn_bm.key?('aggregation'), false,
   'NO aggregation is invented for a Beast Mode measure — the SQL already aggregates; wrapping it in another ' \
   'Agg(...) downstream would silently double-aggregate')
eq(sn_bm && sn_bm['_isCalc'], true, '_isCalc marks this as a calc/formula reference, not a raw warehouse column')
eq(sn_bm && sn_bm['beastModeId'], 'calculation_44444444-aaaa-bbbb-cccc-444444444444',
   'beastModeId carries the formulaId so the build step can join it against dig_beast_modes\' output')
eq(sn_bm && sn_bm['label'], 'Metric Ratio Pct', 'label still comes from the columns[] entry\'s own alias')
eq(sn_bm && sn_bm['_defaultCountSuspect'], false,
   '_defaultCountSuspect still correctly false for a Beast Mode measure (no aggregation to misread as COUNT)')

puts "== Bug A: norm_summary_number — plain-column COUNT case is UNCHANGED (no regression) =="
sn_count = norm_summary_number({ 'columns' => [{ 'column' => 'project_id', 'aggregation' => 'COUNT' }] })
eq(sn_count['_defaultCountSuspect'], true, '_defaultCountSuspect keeps working for the plain-column COUNT case')
eq(sn_count.key?('_isCalc'), false, 'a plain column is never marked _isCalc')

puts "== Bug A: norm_summary_number — an UNRESOLVED formulaId warns loudly and never leaves a nil measure =="
sn_unresolved = nil
unresolved_warning = capture_stderr do
  sn_unresolved = norm_summary_number(
    { 'columns' => [{ 'formulaId' => 'calculation_does_not_exist', 'alias' => 'Mystery KPI' }] },
    formulas: [{ 'id' => 'calculation_other', 'name' => 'Other Calc', 'formula' => 'SUM(`x`)' }],
    card_id: 'card-mystery'
  )
end
eq(sn_unresolved['column'], 'calculation_does_not_exist',
   'an unresolved formulaId falls back to the raw formulaId — never a silent nil measure')
eq(sn_unresolved.key?('_isCalc'), false, 'an unresolved formulaId is NOT marked _isCalc — we could not confirm it IS one')
ok(unresolved_warning.include?('card-mystery') && unresolved_warning.include?('calculation_does_not_exist'),
   'the warning names BOTH the card and the unresolved formulaId')

# ===========================================================================
# Bug C (refs/live-validation-2026-07-30.md): Beast Mode classification trusts
# unreliable Domo flags. Live evidence: 4/4 Beast Modes on a run reported
# isAggregatable:false, isAnalytic:false despite plainly-aggregate SQL, and
# the OLD classify_beast_mode short-circuited on `template.is_a?(Hash)` and
# never looked at the SQL at all once a flag pair was present. Fix: always
# scan the SQL; let a positive scan override a `false` flag.
# ===========================================================================
puts "== Bug C: classify_beast_mode — SQL cross-check overrides an unreliable FALSE/FALSE flag pair =="
false_flag_ratio_sql = '(CASE WHEN (SUM(`metric_denominator`) = 0) THEN 0 ELSE ' \
                        '(SUM(`metric_numerator`) / SUM(`metric_denominator`)) END )'
eq(classify_beast_mode(false_flag_ratio_sql, { 'isAnalytic' => false, 'isAggregatable' => false }), 'aggregate',
   'a CASE-wrapped ratio-of-SUMs is classified aggregate even though BOTH flags say false — the exact live ' \
   'misclassification (old code returned "projection" here)')

count_distinct_sql = '(SUM(`metric_numerator`) / COUNT(DISTINCT `metric_denominator`))'
eq(classify_beast_mode(count_distinct_sql, { 'isAnalytic' => false, 'isAggregatable' => false }), 'aggregate',
   'SUM(...) / COUNT(DISTINCT ...) with false/false flags is still classified aggregate')

window_false_flag_sql = 'ROW_NUMBER() OVER (ORDER BY `date_col`)'
eq(classify_beast_mode(window_false_flag_sql, { 'isAnalytic' => false, 'isAggregatable' => false }), 'window',
   'a ROW_NUMBER()/OVER construct is classified window even though isAnalytic says false')

mixed_flags_sql = 'RANK() OVER (ORDER BY `metric_numerator`)'
eq(classify_beast_mode(mixed_flags_sql, { 'isAnalytic' => false, 'isAggregatable' => true }), 'window',
   'a window construct wins over an aggregate hint/flag — most-specific-class-wins ordering (window > aggregate)')

puts "== Bug C: false-positive guard — a bare column that merely CONTAINS an aggregate name must not misfire =="
eq(sql_has_aggregate_call?('`SUMMARY_COLUMN` + 1'), false,
   'SUMMARY_COLUMN does not match SUM — only a function-CALL shape (name immediately followed by "(") counts')
eq(sql_has_aggregate_call?('SUM(`x`)'), true, 'a genuine SUM( call still matches')
eq(classify_beast_mode('`SUMMARY_COLUMN` + 1'), 'projection',
   'end-to-end: a column named SUMMARY_COLUMN is classified projection, never aggregate')

puts "== Bug C: dig_beast_modes end-to-end — a card-local Beast Mode with false/false flags is classified " \
     'aggregate, not projection =='
card_falseflag = {
  'id' => 'c-falseflag',
  'cardFormulas' => [
    { 'id' => 'calculation_margin', 'name' => 'Margin Pct', 'formula' => false_flag_ratio_sql,
      'isAnalytic' => false, 'isAggregatable' => false },
  ],
}
bms_falseflag = dig_beast_modes(card_falseflag, {}, {})
eq(bms_falseflag.first['class'], 'aggregate',
   'end-to-end through dig_beast_modes: isAnalytic:false/isAggregatable:false but aggregate SQL is classified ' \
   'aggregate, not projection — the exact live misclassification this bug describes')

puts "== bonus: Domo.decode_render — image.data as a nested Hash (confirmed live shape) =="
# refs/live-validation-2026-07-30.md: the render endpoint returns a JSON
# envelope {"image": {"data": "<b64>", ...}, ...} — json['image'] is a HASH,
# which is truthy in Ruby, so the old `json['image'] || ... || json.dig(
# 'image','data')` short-circuited on the Hash and never reached the real
# base64 string.
FakeRenderResponse = Struct.new(:body) do
  def [](key)
    key == 'content-type' ? 'application/json' : nil
  end
end
envelope = { 'image' => { 'data' => Base64.strict_encode64('PNGDATA'), 'notAllDataShown' => false },
             'limited' => false, 'notAllDataShown' => false }
render_res = FakeRenderResponse.new(JSON.generate(envelope))
eq(Domo.decode_render(render_res), 'PNGDATA',
   'image.data extracted correctly even though json["image"] is a Hash, not a bare base64 string')

# ===========================================================================
# B1 (AUDIT-SYNTHESIS.md): datasets.json has no schema for 9 of 10 used
# datasets on a real live instance -> build-dm.rb raises. resolve_dataset_schema
# falls back from Domo.dataset(id)['schema'] to a query_dataset LIMIT-1 probe;
# ensure_dataset_records guarantees a used-but-unlisted id still gets a record.
# ===========================================================================
puts "== B1: resolve_dataset_schema — Domo.dataset()['schema'] used when present =="
with_domo_stub(:dataset, ->(_id) { { 'id' => 'ds-has-schema', 'schema' => { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'STRING' }] } } }) do
  with_domo_stub(:query_dataset, ->(*_a) { raise 'query_dataset should NOT be called when dataset() already has a schema' }) do
    sch = resolve_dataset_schema('ds-has-schema')
    eq(sch, { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'STRING' }] }, 'schema taken straight from Domo.dataset() when present and non-empty')
  end
end

puts "== B1: resolve_dataset_schema — falls back to a query_dataset LIMIT-1 probe when dataset() has NO schema =="
with_domo_stub(:dataset, ->(_id) { { 'id' => 'ds-no-schema', 'name' => 'publicsampledata Orders' } }) do
  with_domo_stub(:query_dataset, ->(_id, sql) {
    eq(sql, 'SELECT * FROM table LIMIT 1', 'the exact confirmed-live probe query is issued')
    { 'columns' => %w[ORDER_ID SHIP_DATE AMOUNT],
      'metadata' => [{ 'type' => 'STRING' }, { 'type' => 'DATETIME' }, { 'type' => 'DECIMAL' }],
      'rows' => [['1001', '2026-01-01T00:00:00Z', '19.99']] }
  }) do
    sch = resolve_dataset_schema('ds-no-schema')
    eq(sch, { 'columns' => [
      { 'name' => 'ORDER_ID',  'type' => 'STRING' },
      { 'name' => 'SHIP_DATE', 'type' => 'DATETIME' },
      { 'name' => 'AMOUNT',    'type' => 'DECIMAL' },
    ] }, 'columns/metadata zipped into the same {name,type} shape build-dm.rb expects from Domo.dataset()[\'schema\']')
  end
end

puts "== B1: resolve_dataset_schema — empty schema.columns[] on dataset() is treated as absent, still falls back =="
with_domo_stub(:dataset, ->(_id) { { 'schema' => { 'columns' => [] } } }) do
  with_domo_stub(:query_dataset, ->(*_a) { { 'columns' => ['x'], 'metadata' => [{ 'type' => 'LONG' }], 'rows' => [] } }) do
    sch = resolve_dataset_schema('ds-empty-schema')
    eq(sch, { 'columns' => [{ 'name' => 'x', 'type' => 'LONG' }] }, 'an empty columns[] array does not count as a usable schema — falls through to the probe')
  end
end

puts "== B1: resolve_dataset_schema — neither path resolves -> nil, never raises (tolerant degrade) =="
with_domo_stub(:dataset, ->(_id) { raise 'network down' }) do
  with_domo_stub(:query_dataset, ->(*_a) { raise 'network down' }) do
    sch = nil
    threw = false
    begin
      sch = resolve_dataset_schema('ds-unreachable')
    rescue
      threw = true
    end
    eq(threw, false, 'resolve_dataset_schema never raises even when BOTH underlying calls raise')
    eq(sch, nil, 'nil signals "unresolved" to the caller, which is responsible for warning loudly')
  end
end

puts "== B1: resolve_dataset_schema — malformed query_dataset response (no columns) -> nil, not a crash =="
with_domo_stub(:dataset, ->(_id) { {} }) do
  with_domo_stub(:query_dataset, ->(*_a) { { 'rows' => [] } }) do
    eq(resolve_dataset_schema('ds-malformed'), nil, 'a query_dataset response missing \'columns\' degrades to nil, not a raise')
  end
end

# ===========================================================================
# Blocker 4 (2026-08-05 batch-verify): the query_dataset LIMIT-1 fallback used
# to zip `columns` against `metadata` positionally with no length check —
# a `metadata` absent, or shorter than `columns`, silently produced
# `type: nil` for every name past metadata's own length (types[i] is nil when
# i is out of range). build-dm.rb's type_format(nil) then emits NO format at
# all — exactly the "a DATE column silently losing its format killed the
# whole DM POST" class build-dm.rb:175-177 already documents, just reached
# via a different silent path. Fixed: refuse to emit ANY columns from this
# probe when metadata doesn't cover every column name — warn loudly, by
# dataset id, and return nil (same "unresolved" signal as every other nil
# path above, which the caller already turns into a loud by-id warning of
# its own, and which build-dm.rb hard-fails on rather than posting a
# typeless DM).
# ===========================================================================
puts "== Blocker 4: resolve_dataset_schema — metadata SHORTER than columns -> nil + a loud by-id warning, never a guessed type =="
with_domo_stub(:dataset, ->(_id) { {} }) do
  with_domo_stub(:query_dataset, ->(*_a) {
    { 'columns' => %w[ORDER_ID SHIP_DATE AMOUNT],
      'metadata' => [{ 'type' => 'STRING' }], # only 1 of 3 — SHIP_DATE/AMOUNT would have zipped to type:nil
      'rows' => [] }
  }) do
    short_meta_result = nil
    out = capture_stderr { short_meta_result = resolve_dataset_schema('ds-short-metadata') }
    eq(short_meta_result, nil, 'a metadata array shorter than columns is refused entirely, not partially zipped with nil types')
    ok(out.include?('ds-short-metadata'), 'the warning names the specific dataset id, not a generic message')
    ok(out.include?('3') && out.include?('1'), 'the warning states both counts (3 column names, 1 metadata entry)')
  end
end

puts "== Blocker 4: resolve_dataset_schema — metadata KEY ABSENT entirely (not just short) -> nil + warning =="
with_domo_stub(:dataset, ->(_id) { {} }) do
  with_domo_stub(:query_dataset, ->(*_a) { { 'columns' => %w[ORDER_ID SHIP_DATE], 'rows' => [] } }) do
    absent_meta_result = :unset
    out = capture_stderr { absent_meta_result = resolve_dataset_schema('ds-no-metadata-key') }
    eq(absent_meta_result, nil, 'no metadata key at all is refused the same way as a too-short one')
    ok(out.include?('ds-no-metadata-key'), 'the warning names the dataset id')
  end
end

puts "== Blocker 4: resolve_dataset_schema — metadata covers every column (equal length) still resolves normally =="
with_domo_stub(:dataset, ->(_id) { {} }) do
  with_domo_stub(:query_dataset, ->(*_a) {
    { 'columns' => %w[ORDER_ID SHIP_DATE],
      'metadata' => [{ 'type' => 'STRING' }, { 'type' => 'DATE' }],
      'rows' => [] }
  }) do
    sch = resolve_dataset_schema('ds-full-metadata')
    eq(sch, { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'STRING' }, { 'name' => 'SHIP_DATE', 'type' => 'DATE' }] },
       'metadata that covers every column name still resolves exactly as before (no false-positive refusal)')
  end
end

puts "== Blocker 4: resolve_dataset_schema — metadata LONGER than columns (extra trailing entries) still resolves =="
with_domo_stub(:dataset, ->(_id) { {} }) do
  with_domo_stub(:query_dataset, ->(*_a) {
    { 'columns' => %w[ORDER_ID],
      'metadata' => [{ 'type' => 'STRING' }, { 'type' => 'DATE' }],
      'rows' => [] }
  }) do
    sch = resolve_dataset_schema('ds-extra-metadata')
    eq(sch, { 'columns' => [{ 'name' => 'ORDER_ID', 'type' => 'STRING' }] },
       'metadata longer than columns is not a rejection case — every column name still has a real type')
  end
end

puts "== B1: ensure_dataset_records — synthesizes a minimal record for a used id absent from the list entirely =="
existing_5 = [
  { 'id' => '021e123b', 'name' => 'Orders Fact' },
  { 'id' => '1252fb63', 'name' => 'PDP Example DataSet' },
]
used_10 = %w[021e123b 1252fb63 f64df8eb a30c23f7 1eb93e0f]
added, out = ensure_dataset_records(existing_5, used_10)
eq(added.sort, %w[a30c23f7 f64df8eb 1eb93e0f].sort, 'only the used ids NOT already present are reported as added')
eq(out.size, 5, 'existing 2 + 3 synthesized = 5 total records')
eq(out.map { |d| d['id'] }.sort, (existing_5.map { |d| d['id'] } + added).sort, 'every used id now has SOME record')
eq(out.find { |d| d['id'] == '021e123b' }, { 'id' => '021e123b', 'name' => 'Orders Fact' }, 'a pre-existing record is left untouched, not flattened to {id}')
eq(out.find { |d| d['id'] == 'f64df8eb' }, { 'id' => 'f64df8eb' }, 'a synthesized record is minimal ({id} only) so the schema merge still has somewhere to land it')

puts "== B1: ensure_dataset_records — datasets.json entirely absent (nil) -> synthesizes ALL used ids =="
added2, out2 = ensure_dataset_records(nil, %w[ds-a ds-b])
eq(added2.sort, %w[ds-a ds-b], 'both used ids reported as added when there was nothing to start from')
eq(out2, [{ 'id' => 'ds-a' }, { 'id' => 'ds-b' }], 'synthesized records are the entire result')

puts "== B1: ensure_dataset_records — nothing used, nothing added (no-op) =="
added3, out3 = ensure_dataset_records(existing_5, [])
eq(added3, [], 'no used ids means nothing gets synthesized')
eq(out3, existing_5, 'existing records pass through unchanged')

puts "== B1 end-to-end: a used id missing from the public LIST still ends up in datasets.json WITH a usable schema =="
# Mirrors the real cold-run shape: datasets.json (from --datasets) has only
# 5 records; cards reference 10 ids; 9 of them (including this one) are
# absent from that list AND have no schema on Domo.dataset().
ensure_added, ensured = ensure_dataset_records(existing_5, ['f64df8eb'])
sch = { 'columns' => [{ 'name' => 'Region', 'type' => 'STRING' }] }
merged_count, merged = merge_dataset_schemas(ensured, { 'f64df8eb' => sch })
eq(ensure_added, ['f64df8eb'], 'the missing id was flagged as synthesized')
eq(merged_count, 1, 'exactly one record received the schema merge')
final_record = merged.find { |d| d['id'] == 'f64df8eb' }
ok(final_record['schema']['columns'].is_a?(Array) && !final_record['schema']['columns'].empty?,
   'the dataset that was absent from the public LIST entirely now has usable schema.columns in datasets.json — ' \
   'the exact gap that used to make build-dm.rb raise ArgumentError')

# ===========================================================================
# B3 (AUDIT-SYNTHESIS.md): a filter on a Beast Mode keeps the raw
# "calculation_<uuid>" id instead of resolving to the Beast Mode's real name
# -> a control binds to a column that doesn't exist. Real example in the
# data: calculation_ea1150fd-... resolves to "State".
# ===========================================================================
puts "== B3: resolve_calc_ref — resolves a calc id to the Beast Mode's real name =="
calc_by_id = { 'calculation_ea1150fd' => { 'id' => 'calculation_ea1150fd', 'name' => 'State' } }
eq(resolve_calc_ref('calculation_ea1150fd', calc_by_id), 'State', 'the real live example: calculation_ea1150fd-... -> "State"')
eq(resolve_calc_ref('Country', calc_by_id), 'Country', 'a plain (non-calc) column is passed through unchanged')
eq(resolve_calc_ref('calculation_does_not_exist', calc_by_id), 'calculation_does_not_exist',
   'an unresolvable calc id is returned UNCHANGED, never invents a name it can\'t back up')
eq(resolve_calc_ref(nil, calc_by_id), nil, 'a nil column value is passed through unchanged (no crash on nil.to_s)')

puts "== B3: normalize_card Shape B — a filter on a Beast Mode resolves to its real name, not the raw calc id =="
shape_b_filter = {
  'chartType' => 'badge_map', 'dataSetId' => 'ds-3',
  'definition' => {
    'title' => 'US Map',
    'subscriptions' => { 'main' => {
      'columns' => [{ 'column' => 'metric' }],
      'filters' => [{ 'column' => 'calculation_ea1150fd', 'filterType' => 'LEGACY', 'values' => [''] }],
    } },
    'formulas' => [{ 'id' => 'calculation_ea1150fd', 'name' => 'State', 'formula' => "CONCAT(`a`,`b`)" }],
  },
}
card_b_filter = normalize_card(shape_b_filter, 'card-B-filter')
eq(card_b_filter['filters'].first['column'], 'State',
   'Shape B filter column resolved to the Beast Mode\'s real name "State" (was the raw calc id before B3)')
eq(card_b_filter['filters'].first['operator'], 'LEGACY', 'Shape B filter operator is preserved')
eq(card_b_filter['filters'].first['values'], [''], 'Shape B filter values are preserved')
eq(card_b_filter['filters'].first['beastModeId'], 'calculation_ea1150fd',
   'Shape B filter preserves the stable Beast Mode id after resolving its display name')
eq(card_b_filter['filters'].first['_isCalc'], true,
   'Shape B filter remains marked as a calculated reference')

puts "== B3: normalize_card Shape A — a filter on a Beast Mode resolves to its real name, not the raw calc id =="
shape_a_filter = {
  'title' => 'Regional Map', 'chartType' => 'badge_map', 'dataSetId' => 'ds-4',
  'chartBody' => {
    'columns' => [{ 'column' => 'metric' }],
    'filters' => [{ 'column' => 'calculation_443eb18b', 'operand' => 'LEGACY', 'values' => ['Midwest'] }],
  },
  'calculatedFields' => [{ 'id' => 'calculation_443eb18b', 'name' => 'US Regions', 'formula' => "CASE WHEN 1 THEN 'x' END" }],
}
card_a_filter = normalize_card(shape_a_filter, 'card-A-filter')
eq(card_a_filter['filters'].first['column'], 'US Regions',
   'Shape A filter column resolved to the Beast Mode\'s real name "US Regions" (was the raw calc id before B3)')
eq(card_a_filter['filters'].first['beastModeId'], 'calculation_443eb18b',
   'Shape A filter preserves the stable Beast Mode id')

puts "== B3: normalize_card — a filter on a Beast Mode with NO matching formula degrades to the raw id, never crashes =="
shape_b_unresolved_filter = {
  'chartType' => 'badge_table',
  'definition' => {
    'title' => 'Mystery',
    'subscriptions' => { 'main' => {
      'columns' => [{ 'column' => 'x' }],
      'filters' => [{ 'column' => 'calculation_ghost', 'filterType' => 'IN', 'values' => %w[a] }],
    } },
    'formulas' => [],
  },
}
card_b_unresolved = normalize_card(shape_b_unresolved_filter, 'card-B-unresolved')
eq(card_b_unresolved['filters'].first['column'], 'calculation_ghost',
   'no matching formula -> raw calc id passed through unchanged, not a crash or a nil column')
eq(card_b_unresolved['filters'].first['beastModeId'], 'calculation_ghost',
   'unresolved filter still preserves the id so accounting can block it')

puts "== B3: norm_columns — a column whose value IS the calc id directly (not via empty+formulaId) also resolves =="
resolved_cols = norm_columns(
  { 'columns' => [{ 'column' => 'calculation_ea1150fd' }] },
  formulas: [{ 'id' => 'calculation_ea1150fd', 'name' => 'State' }]
)
eq(resolved_cols.first['column'], 'State', 'the same calc-id-as-column-value shape used by filters now resolves for chart-body columns too')

# ===========================================================================
# F6 (AUDIT-SYNTHESIS.md): beast-modes.json double-counts — a calc present at
# BOTH dataset and card scope for the same card survives twice under the old
# [id, scope] dedupe key (148 rows / 81 unique ids on a real 36-card page).
# ===========================================================================
puts "== F6: dedupe_beast_modes — a calc present at both dataset AND card scope collapses to ONE row =="
dupe_calc = 'calculation_443eb18b'
beast_modes_with_dupe = [
  { 'id' => dupe_calc, 'name' => 'US Regions', 'sql' => 'x', 'scope' => 'dataset', 'class' => 'projection', 'dataSourceId' => 'ds-1', 'cardId' => 'c-1' },
  { 'id' => dupe_calc, 'name' => 'US Regions', 'sql' => 'x', 'scope' => 'card',    'class' => 'projection', 'cardId' => 'c-1' },
  { 'id' => 'calculation_other', 'name' => 'Other', 'sql' => 'y', 'scope' => 'dataset', 'class' => 'aggregate', 'cardId' => 'c-2' },
]
deduped = dedupe_beast_modes(beast_modes_with_dupe)
eq(deduped.size, 2, 'the [id, scope]-dupe collapses to one row; the distinct id is untouched (3 rows -> 2)')
eq(deduped.map { |b| b['id'] }.sort, %w[calculation_443eb18b calculation_other], 'both surviving rows are one-per-unique-id')
kept = deduped.find { |b| b['id'] == dupe_calc }
eq(kept['scope'], 'dataset', 'the FIRST occurrence (dataset scope, the richer record with dataSourceId) is the one kept')
eq(kept['dataSourceId'], 'ds-1', 'the kept row still carries dataSourceId — nothing was lost by keeping the first, not an arbitrary, occurrence')

puts "== F6: dedupe_beast_modes — measured regression check: 148 rows collapse to 81 unique ids (real cold-run shape) =="
# Reproduce the MEASURED real-instance shape: 67 ids duplicated across dataset
# + card scope (67*2=134 rows) plus 14 ids appearing only once = 148 rows / 81
# unique ids total (67 + 14 = 81) — the exact numbers from AUDIT-SYNTHESIS.md.
synthetic_148 = []
67.times { |i| 2.times { |j| synthetic_148 << { 'id' => "calculation_dupe_#{i}", 'scope' => j.zero? ? 'dataset' : 'card' } } }
14.times { |i| synthetic_148 << { 'id' => "calculation_single_#{i}", 'scope' => 'dataset' } }
eq(synthetic_148.size, 148, 'synthetic fixture reproduces the measured 148-row shape')
eq(dedupe_beast_modes(synthetic_148).size, 81, 'dedupe_beast_modes collapses it to the measured 81 unique ids')

puts "== F6: dedupe_beast_modes — no dupes at all is a no-op =="
no_dupes = [{ 'id' => 'a' }, { 'id' => 'b' }, { 'id' => 'c' }]
eq(dedupe_beast_modes(no_dupes), no_dupes, 'nothing to collapse -> array passes through unchanged')

puts
if $failures.zero?
  puts "ALL PASS"
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
