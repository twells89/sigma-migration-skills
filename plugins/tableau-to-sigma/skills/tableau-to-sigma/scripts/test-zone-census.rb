#!/usr/bin/env ruby
# test-zone-census.rb — unit test for ZoneCensus (lib/zone_census.rb): the
# furniture predicate + layout-fill math shared by phase6-parity's tile census
# and build-dashboard-layout's layout-census.json (#259 item 1, gate 8c).
# Pure, offline, creds-free. Run: ruby scripts/test-zone-census.rb
require_relative 'lib/zone_census'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# ---- plots? : a real data tile vs furniture ---------------------------------
chart_with_measure = { 'kind' => 'chart', 'caption' => 'Sales', 'measures' => ['Sales'] }
chart_with_shelf   = { 'kind' => 'chart', 'caption' => 'Trend',
                       'rows_shelf' => { 'measure_count' => 1 }, 'cols_shelf' => { 'dim_count' => 1 } }
label_worksheet    = { 'kind' => 'chart', 'caption' => 'Note Box', 'measures' => [],
                       'rows_shelf' => {}, 'cols_shelf' => {} }
title_zone         = { 'kind' => 'title', 'caption' => 'My Dashboard' }
text_zone          = { 'kind' => 'text', 'caption' => 'Disclaimer' }
filter_zone        = { 'kind' => 'filter', 'caption' => 'Region' }
uncaptioned_chart  = { 'kind' => 'chart', 'caption' => '  ', 'measures' => ['X'] }

ok('chart with a measure plots', ZoneCensus.plots?(chart_with_measure))
ok('chart with a non-empty shelf plots', ZoneCensus.plots?(chart_with_shelf))
ok('chart with no measure + empty shelf is furniture (label worksheet)', !ZoneCensus.plots?(label_worksheet))
ok('title zone is furniture', !ZoneCensus.plots?(title_zone))
ok('text zone is furniture', !ZoneCensus.plots?(text_zone))
ok('filter zone is furniture', !ZoneCensus.plots?(filter_zone))
ok('uncaptioned chart is not a tile', !ZoneCensus.plots?(uncaptioned_chart))
ok('nil is not a tile', !ZoneCensus.plots?(nil))

# ---- content_zones : furniture excluded from the count ----------------------
mixed = [chart_with_measure, chart_with_shelf, label_worksheet, title_zone, text_zone, filter_zone]
ok('content_zones keeps only the 2 real tiles', ZoneCensus.content_zones(mixed).size == 2)
ok('content_zones(nil) is empty', ZoneCensus.content_zones(nil) == [])

# ---- grid_fill_pct : sum of placed areas / page area, capped ----------------
# One tile spanning cols 1..13 (12 wide) x rows 1..17 (16 tall) = 192 cells on a
# 24x32 = 768-cell page -> 0.25.
ok('single 12x16 tile on 24x32 grid -> 0.25',
   (ZoneCensus.grid_fill_pct([[1, 13, 1, 17]], 24, 32) - 0.25).abs < 1e-9)
# Two tiles filling the top and bottom halves fully -> 1.0.
ok('two half-page tiles -> 1.0',
   (ZoneCensus.grid_fill_pct([[1, 25, 1, 17], [1, 25, 17, 33]], 24, 32) - 1.0).abs < 1e-9)
# Over-full (overlapping/summed beyond the page) is capped at 1.0.
ok('area beyond the page is capped at 1.0',
   ZoneCensus.grid_fill_pct([[1, 25, 1, 33], [1, 25, 1, 33]], 24, 32) == 1.0)
ok('no tiles -> 0.0', ZoneCensus.grid_fill_pct([], 24, 32) == 0.0)
ok('zero page area -> 0.0 (no divide-by-zero)', ZoneCensus.grid_fill_pct([[1, 5, 1, 5]], 0, 32) == 0.0)
# Degenerate/negative spans contribute nothing.
ok('degenerate rect contributes 0', ZoneCensus.grid_fill_pct([[5, 5, 1, 10]], 24, 32) == 0.0)

# ---- page_record : shape, rounding, dropped floor ---------------------------
rec = ZoneCensus.page_record('Overview', 9, 9, 0.7133)
ok('page_record page name', rec['page'] == 'Overview')
ok('page_record zones/placed', rec['zones'] == 9 && rec['placed'] == 9)
ok('page_record dropped = 0 when full', rec['dropped'] == 0)
ok('page_record rounds fill to 3 decimals', rec['grid_fill_pct'] == 0.713)

dropped = ZoneCensus.page_record('Sparse', 9, 6, 0.2)
ok('page_record dropped = zones - placed', dropped['dropped'] == 3)
# placed can never exceed zones in practice, but dropped must never go negative.
neg = ZoneCensus.page_record('Odd', 2, 5, 1.0)
ok('page_record dropped floored at 0', neg['dropped'] == 0)

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
