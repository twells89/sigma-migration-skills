#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit guards for the parity oracle's pure helpers.
#
# Both scripts are top-level CLIs that parse ARGV and hit the network, so they
# cannot be require_relative'd. Extract the pure functions from source and eval
# them in isolation — the same idiom test-migrate-domo.rb already uses for
# render_target_page.
#
#   ruby test/test-parity-oracle.rb
require 'json'
require 'date'

SKILL   = File.expand_path('..', __dir__)
SCRIPTS = File.join(SKILL, 'scripts')
$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(a, e, m)
  if a == e then puts "  ok: #{m}"
  else $failures += 1; puts "  FAIL: #{m}\n        expected #{e.inspect}\n        got      #{a.inspect}" end
end

expected_src = File.read(File.join(SCRIPTS, 'collect-parity-expected.rb'))
sv_src = expected_src[/^def summary_value\(doc\)\n.*?\nend\n/m]
ok(sv_src, 'extracted summary_value(doc) from collect-parity-expected.rb')
eval(sv_src, TOPLEVEL_BINDING) if sv_src # rubocop:disable Security/Eval — trusted same-repo source, test-only

# ---------------------------------------------------------------------------
# THE BUG THIS FILE EXISTS FOR.
#
# Domo's card-data summary carries BOTH a display string and a raw number:
#   {"label": "Sales in Period", "value": "$9.7M", "number": 9690690.9317}
# The first cut of summary_value returned `value`. verify-parity.rb normalises
# numerically and in Ruby "$9.7M".to_f is 0.0, so the tile compared 0.0 against
# 9690690.93 and DIVERGED. Percent cards failed differently and just as quietly:
# "35.61%".to_f is 35.61 while `number` is 0.3561 — a 100x mismatch.
#
# All 29 companion KPI tiles on the live 36-card page would have failed this way:
# a ~45% false-failure rate on gate 1, indistinguishable from a catastrophic
# conversion bug. Shapes below are VERBATIM from the live payloads.
if sv_src
  eq(summary_value({ 'summary' => { 'label' => 'Sales in Period', 'value' => '$9.7M',
                                    'number' => 9_690_690.9317 } }),
     9_690_690.9317,
     'currency: takes the raw `number`, never the "$9.7M" display string')

  eq(summary_value({ 'summary' => { 'label' => 'Change over 7 Days', 'value' => '19.80%',
                                    'number' => 0.1979903 } }),
     0.1979903,
     'percent: takes the FRACTION, not the 19.80 that "19.80%".to_f would yield')

  eq(summary_value({ 'summary' => { 'value' => '950.9K', 'number' => 950_874 } }),
     950_874,
     'abbreviated: takes 950874, not the 950.9 that "950.9K".to_f would yield')

  # Zero is a legitimate value and must not be mistaken for absent.
  eq(summary_value({ 'summary' => { 'value' => '0.0%', 'number' => 0 } }), 0,
     'zero: a real 0 is returned, not treated as missing')

  # Domo declining to compute is NOT a zero.
  ok(summary_value({ 'summary' => { 'status' => 'not_ran', 'value' => '', 'number' => 0 },
                     'summaryNumber' => '' }).nil?,
     'status "not_ran" yields nil — Domo declining to compute a KPI is not a zero')

  # Fallbacks, in order, only when no numeric form exists.
  eq(summary_value({ 'summary' => { 'value' => '42' } }), '42',
     'falls back to `value` when there is no numeric `number`')
  eq(summary_value({ 'summaryNumber' => '77' }), '77',
     'falls back to the top-level summaryNumber when there is no summary object')
  ok(summary_value({}).nil?, 'no summary at all yields nil')

  # A non-numeric `number` must not be trusted just because the key exists.
  eq(summary_value({ 'summary' => { 'number' => 'N/A', 'value' => '12.5%' } }), '12.5%',
     'a non-Numeric `number` is rejected and `value` is used instead')
end

# ---------------------------------------------------------------------------
# dedupe_channels — Domo sometimes plots ONE measure on TWO channels, so its row
# carries the value twice while Sigma's export carries it once. Whole-tuple
# comparison then fails the tile on arity before any value is looked at.
#
# Every shape below is verbatim from the 2026-08-07 live run.
dc_src = expected_src[/^def dedupe_channels\(rows, columns, mappings\)\n.*?\nend\n/m]
ok(dc_src, 'extracted dedupe_channels from collect-parity-expected.rb')
eval(dc_src, TOPLEVEL_BINDING) if dc_src # rubocop:disable Security/Eval

if dc_src
  # Top 20 Organic Tweets: ['Text','Favorite Count','Favorite Count'] -> 2817 twice
  rows, cols, maps, dropped = dedupe_channels(
    [['a', 2817, 2817], ['b', 2320, 2320]],
    ['Text', 'Favorite Count', 'Favorite Count'], %w[ITEM SERIES SERIES])
  eq(cols, ['Text', 'Favorite Count'], 'a repeated channel with identical values is collapsed')
  eq(rows, [['a', 2817], ['b', 2320]], 'and the rows lose exactly that column')
  eq(maps, %w[ITEM SERIES], 'mappings stay parallel to columns')
  eq(dropped, ['Favorite Count'], 'and the drop is RECORDED, never invisible')

  # Page Engagement Rate: 3288.0 at one index, 3288 at another — numerically equal.
  _, cols2, _, dropped2 = dedupe_channels(
    [['2026-07-25', 3288.0, 202283, 3288]],
    ['Date', 'Engaged Users', 'Unique Impressions', 'Engaged Users'],
    %w[ITEM SERIES SERIES SERIES])
  eq(cols2, ['Date', 'Engaged Users', 'Unique Impressions'],
     'int/float variance of the same value still counts as a duplicate')
  eq(dropped2, ['Engaged Users'], 'and is recorded')

  # THE DANGEROUS CASE. Domo's table default counts the row-key column, so the
  # column appears as BOTH the dimension and the counted measure under ONE name
  # with DIFFERENT data. Deduping on name alone would delete the measure.
  _, cols3, _, dropped3 = dedupe_channels(
    [['Gembucket campaign', 2], ['Zoolab campaign', 5]],
    %w[campaign_title campaign_title], %w[ITEM VALUE])
  eq(cols3, %w[campaign_title campaign_title],
     'same NAME but different DATA (Domo table-default COUNT) is NOT collapsed')
  eq(dropped3, [], 'and nothing is reported dropped')

  _, cols4, _, dropped4 = dedupe_channels(
    [['d', 1, 2, 3]], %w[Date A B C], %w[ITEM SERIES SERIES SERIES])
  eq(cols4, %w[Date A B C], 'genuinely distinct series are untouched')
  eq(dropped4, [], 'with nothing dropped')

  _, cols5, = dedupe_channels([], %w[Date A], %w[ITEM SERIES])
  eq(cols5, %w[Date A], 'an empty row set is returned unchanged (no false collapse)')
end

# ---------------------------------------------------------------------------
# A headers-only Sigma export is a DEFECT, not an empty comparison. Four elements
# did this on the live run; recording them as successful exports made the join
# compare N Domo rows against 0 Sigma rows, scoring as an ordinary DIVERGE and
# burying the real finding ("this tile renders nothing") among value mismatches.
actuals_src = File.read(File.join(SCRIPTS, 'collect-parity-actuals.rb'))
ok(actuals_src.include?('ZERO data rows'),
   'collect-parity-actuals routes a headers-only export to `unavailable` with a measured reason')
ok(actuals_src.match?(/if rows\.empty\?/),
   'and it checks for it explicitly after shifting the header row')

# ---------------------------------------------------------------------------
oracle_src = File.read(File.join(SCRIPTS, 'build-parity-oracle.rb'))
ok(oracle_src.include?("'kind' => 'domo-card-data-cap'") &&
   oracle_src.include?("card['num_rows'].to_i == 500"),
   'oracle records exact-500 Domo collector truncation instead of scoring extra Sigma rows')
compat_index = oracle_src.index("require_relative 'lib/ruby_compat'")
filter_map_index = oracle_src.index('filter_map')
ok(compat_index && filter_map_index && compat_index < filter_map_index,
   'Ruby 2.6 compatibility shim loads before the oracle uses filter_map')
cid_src = oracle_src[/^def card_id_for\(element_id\)\n.*?\nend\n/m]
ok(cid_src, 'extracted card_id_for(element_id) from build-parity-oracle.rb')
eval(cid_src, TOPLEVEL_BINDING) if cid_src # rubocop:disable Security/Eval

if cid_src
  eq(card_id_for('el-922919965'), %w[922919965].push(false).freeze.to_a,
     'a base tile id yields the card id and is_summary=false')
  eq(card_id_for('el-922919965-summary'), ['922919965', true],
     'a companion tile id yields the same card id and is_summary=true')
  eq(card_id_for('el-922919965-verify'), ['922919965', false],
     'a static visual live-verification tile joins to the card as a base value tile')
  eq(card_id_for('el-922919965-summary-verify'), ['922919965', true],
     'a formatted companion KPI parity twin retains summary semantics')
  eq(card_id_for('master-1252fb63'), [nil, false],
     'a master element traces to no card (it is excluded, not silently skipped)')
  eq(card_id_for('header-block-1'), [nil, false],
     'a put-layout header element traces to no card')
  eq(card_id_for('el-922919965-summary-extra'), [nil, false],
     'the pattern is anchored — a longer suffix is not mistaken for a summary tile')
end

pop_src = oracle_src[/^def pop_grain_key\(date, grain\)\n.*?(?=^stale_evidence =)/m]
ok(pop_src, 'extracted Domo POP transport normalizer from build-parity-oracle.rb')
eval(pop_src, TOPLEVEL_BINDING) if pop_src # rubocop:disable Security/Eval

if pop_src
  pop_card_data = {
    'mappings' => %w[ITEM VALUE POP_PERIOD POP_INDEX],
    'rows' => [
      ['2026-01-01', 93_000, 0, 0],
      ['2026-01-02', nil, 0, 1],
      ['2026-02-01', 96_000, 0, 31],
      ['2025-01-01', 82_000, 1, 0],
      ['2025-02-01', 84_000, 1, 31],
    ],
  }
  source_pop = {
    'chartType' => 'badge_pop_bar_line',
    'dateGrain' => { 'dateTimeElement' => 'MONTH' },
    'columns' => [{ 'mapping' => 'VALUE', 'aggregation' => 'SUM' }],
  }
  normalized = normalize_pop_expected(pop_card_data, source_pop)
  eq(normalized['rows'],
     [['2026-01', 93_000, 82_000], ['2026-02', 96_000, 84_000]],
     'POP_PERIOD/POP_INDEX rows pivot to one current/prior measure pair per visible month')
  eq(normalized['columns'], ['Date', 'Current period', 'Period 1'],
     'normalized POP transport has the same three-column arity as the Sigma combo export')
  eq(normalized['transform'], 'domo-pop-aligned-grain',
     'oracle records the source-shape transformation instead of applying it silently')
  ok(normalize_pop_expected(pop_card_data, source_pop.merge('chartType' => 'badge_line_bar')).nil?,
     'ordinary combo charts never take the POP-specific transport transform')
end

month_abbr_src = oracle_src[/^MONTH_ABBR = .*?\.freeze\n/m]
eval(month_abbr_src, TOPLEVEL_BINDING) if month_abbr_src && !defined?(MONTH_ABBR) # rubocop:disable Security/Eval
parse_date_src = oracle_src[/^def parse_date\(v\)\n.*?\nend\n/m]
ok(parse_date_src, 'extracted parse_date(v) from build-parity-oracle.rb')
eval(parse_date_src, TOPLEVEL_BINDING) if parse_date_src # rubocop:disable Security/Eval
max_date_src = oracle_src[/^def max_date\(rows\)\n.*?\nend\n/m]
ok(max_date_src, 'extracted max_date(rows) from build-parity-oracle.rb')
eval(max_date_src, TOPLEVEL_BINDING) if max_date_src # rubocop:disable Security/Eval
if max_date_src
  eq(max_date([
       ['2026-09-01', 117_000],
       ['2026-10-01', nil],
       ['2026-11-01', nil],
       ['2026-12-01', nil],
     ]), Date.new(2026, 9, 1),
     'future POP density rows with no values do not make the warehouse look stale')
end
ok(oracle_src.include?("unless expected_transform == 'domo-pop-aligned-grain'"),
   'aligned POP display dates are excluded from warehouse-freshness inference')

canon_src = oracle_src[/^def canonicalise_dim\(rows\)\n.*?(?=^def max_date\(rows\))/m]
ok(canon_src, 'extracted canonicalise_dim(rows) from build-parity-oracle.rb')
eval(canon_src, TOPLEVEL_BINDING) if canon_src # rubocop:disable Security/Eval

if canon_src
  rows, n = canonicalise_dim([
    ['Week-53 2024', 206_226.0, 85_758.0, 60_993.0],
    ['Week-1 2025', 204_276.0, 85_341.0, 62_985.0],
    ['Week-2 2025', 10.0, 20.0, 30.0],
  ])
  eq(n, 3, 'all Domo week labels are canonicalised')
  eq(rows,
     [['2024-12-29', 410_502.0, 171_099.0, 123_978.0],
      ['2025-01-05', 10.0, 20.0, 30.0]],
     'year-boundary labels for one physical week coalesce by summing measures')

  categorical, = canonicalise_dim([
    ['Week-53 2024', 'A', 1.0],
    ['Week-1 2025', 'B', 2.0],
  ])
  eq(categorical.length, 2,
     'a second string dimension prevents coalescing legitimate category rows')

  compact_months, compact_count = canonicalise_dim([['Jan 24', 10], ['Dec 26', 20]])
  eq(compact_months, [['2024-01', 10], ['2026-12', 20]],
     'compact Sigma month labels canonicalise to Domo ISO month buckets')
  eq(compact_count, 2, 'each compact month rewrite is counted')

  readable_days, readable_count = canonicalise_dim([['Jul 23, 2026', 0.4]])
  eq(readable_days, [['2026-07-23', 0.4]],
     'readable day labels retain full day precision for parity')
  eq(readable_count, 1, 'the readable day rewrite is counted')
end

source_grain_src = oracle_src[/^def canonicalise_source_grain\(rows, source_card\)\n.*?\nend\n/m]
ok(source_grain_src, 'extracted canonicalise_source_grain(rows, source_card)')
eval(source_grain_src, TOPLEVEL_BINDING) if source_grain_src # rubocop:disable Security/Eval
if source_grain_src
  monthly, count = canonicalise_source_grain(
    [['2025-01-01', 40_000, 'Alpha'], ['2025-02-01', 42_000, 'Alpha']],
    { 'dateGrain' => { 'dateTimeElement' => 'MONTH' } }
  )
  eq(monthly, [['2025-01', 40_000, 'Alpha'], ['2025-02', 42_000, 'Alpha']],
     'month-grained source rows compare to Sigma month labels at the same grain')
  eq(count, 2, 'source-grain rewrites are auditable')
end

display_src = oracle_src[/^def canonicalise_numeric_display\(rows, expected_rows = nil\)\n.*?\nend\n/m]
ok(display_src, 'extracted canonicalise_numeric_display(rows) from build-parity-oracle.rb')
eval(display_src, TOPLEVEL_BINDING) if display_src # rubocop:disable Security/Eval
if display_src
  eq(canonicalise_numeric_display([['2026-07-23', '41%', '$9.7M']]),
     [['2026-07-23', 0.41, 9_700_000.0]],
     'formatted Sigma percentages/currency compare to Domo raw numeric values')
  eq(canonicalise_numeric_display([['1,234', '41%']], [['1,234', 0.41]]),
     [['1,234', 0.41]],
     'text dimensions that look numeric are never coerced when source truth is text')
  eq(canonicalise_numeric_display([['2026-09-17', '38%']], [['2026-09-17', 0.375]]),
     [['2026-09-17', 0.375]],
     'a displayed percent adopts the exact source value only when it rounds to the printed precision')
  eq(canonicalise_numeric_display([['2026-09-17', '40%']], [['2026-09-17', 0.375]]),
     [['2026-09-17', 0.4]],
     'a materially different displayed percent is not laundered into a match')
  eq(canonicalise_numeric_display([['38%']], [[0.375]]),
     [[0.375]],
     'a one-cell KPI percent also recovers its exact source value at printed precision')
  duplicate_keys = canonicalise_numeric_display(
    [['Same', '38%'], ['Same', '37%']],
    [['Same', 0.365], ['Same', 0.375]]
  )
  eq(duplicate_keys, [['Same', 0.375], ['Same', 0.365]],
     'duplicate dimension keys match rounded values one-to-one instead of reusing the first source row')
  eq(canonicalise_numeric_display(
       [['Same', '37%'], ['Same', '38%']],
       [['Same', 0.365], ['Same', 0.375]]
     ),
     [['Same', 0.365], ['Same', 0.375]],
     'duplicate-key normalization remains correct when Sigma row order changes')
end

dedupe_src = oracle_src[/^def same_parity_value\?\(left, right\)\n.*?(?=^stale_evidence =)/m]
ok(dedupe_src, 'extracted identical-column normalization helpers')
eval(dedupe_src, TOPLEVEL_BINDING) if dedupe_src # rubocop:disable Security/Eval
if dedupe_src
  aligned, headers = realign_actual_columns(
    [['Bree Spence', 8, 40_593.75, 324_750]],
    ['Owner Name', 'Is Won', 'Amount (Value)', 'Amount (Bubblesize)'],
    ['IsWon', 'Amount', 'Owner.Name', 'Amount']
  )
  eq(aligned, [[8, 40_593.75, 'Bree Spence', 324_750]],
     'scatter export is realigned to Domo XTIME/VALUE/SERIES/BUBBLESIZE order')
  eq(headers, ['Is Won', 'Amount (Value)', 'Owner Name', 'Amount (Bubblesize)'],
     'realigned headers stay parallel')

  rows, cols, dropped = dedupe_identical_columns(
    [['2026-07-12', '129.0', 208, '129'],
     ['2026-07-13', '66.0', 95, '66']],
    ['Date', 'Unique Page Views', 'Page Views', 'Visitors']
  )
  eq(rows, [['2026-07-12', '129.0', 208], ['2026-07-13', '66.0', 95]],
     'numeric-equivalent duplicate visual channel is removed from Sigma rows')
  eq(cols, ['Date', 'Unique Page Views', 'Page Views'],
     'column headers stay aligned after removal')
  eq(dropped, ['Visitors'], 'dropped channel is auditable')
end

puts $failures.zero? ? "\nALL PASS" : "\n#{$failures} FAILURE(S)"
exit($failures.zero? ? 0 : 1)
