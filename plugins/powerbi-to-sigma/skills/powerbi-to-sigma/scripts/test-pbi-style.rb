#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-style.rb — regression test for lib/pbi_style.rb (style fidelity §5-7:
# number abbreviation, KPI anchor, presentation table). Offline: no API, no creds.
# Run: ruby scripts/test-pbi-style.rb
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'pbi_style'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end
def fmt(el, cid); (el['columns'].find { |c| c['id'] == cid } || {}).dig('format', 'formatString'); end

S = PbiStyle

# --- abbreviates? : nil/auto/thousands abbreviate; explicit 'none' does not ----
ok('abbreviates? nil (PBI default Auto)', S.abbreviates?(nil) == true)
ok('abbreviates? auto',                   S.abbreviates?('auto') == true)
ok('abbreviates? thousands',              S.abbreviates?('thousands') == true)
ok('abbreviates? none = full precision',  S.abbreviates?('none') == false)

# --- kpi_anchor : center by default; explicit PBI alignment wins ---------------
ok('kpi_anchor nil -> middle',   S.kpi_anchor(nil) == 'middle')
ok('kpi_anchor left -> start',   S.kpi_anchor('left') == 'start')
ok('kpi_anchor right -> end',    S.kpi_anchor('right') == 'end')
ok('kpi_anchor center -> middle', S.kpi_anchor('center') == 'middle')

# --- compact_format : preserve $, skip %, classify unformatted by sibling ------
ok('compact $ currency -> $,.3s', S.compact_format({ 'formatString' => '$,.0f' }, 3, false) == { 'kind' => 'number', 'formatString' => '$,.3s' })
ok('compact plain number -> ,.2s', S.compact_format({ 'formatString' => ',.0f' }, 2, false) == { 'kind' => 'number', 'formatString' => ',.2s' })
ok('compact percent -> nil (never abbreviate a ratio)', S.compact_format({ 'formatString' => '.1%' }, 3, false).nil?)
ok('compact unformatted + currency sibling -> $,.2s', S.compact_format(nil, 2, true) == { 'kind' => 'number', 'formatString' => '$,.2s' })
ok('compact unformatted + no currency clue -> nil', S.compact_format(nil, 2, false).nil?)

# --- measure_col_ids : value.columnId (kpi) / value.id (donut) / yAxis ---------
kpi  = { 'kind' => 'kpi-chart', 'value' => { 'columnId' => 'v' } }
bar  = { 'kind' => 'bar-chart', 'yAxis' => { 'columnIds' => ['y0', { 'columnId' => 'y1', 'type' => 'line' }] } }
donut = { 'kind' => 'donut-chart', 'value' => { 'id' => 'dv' } }
ok('measure_col_ids kpi',   S.measure_col_ids(kpi) == ['v'])
ok('measure_col_ids bar (string + hash)', S.measure_col_ids(bar) == %w[y0 y1])
ok('measure_col_ids donut', S.measure_col_ids(donut) == ['dv'])

# --- abbreviate_measures! : the KPI + chart transforms end-to-end --------------
kpi_el = {
  'kind' => 'kpi-chart', 'value' => { 'columnId' => 'v' },
  'columns' => [{ 'id' => 'v', 'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } }]
}
S.abbreviate_measures!(kpi_el, nil, 'kpi-chart')
ok('KPI currency value -> $,.3s (precision 3)', fmt(kpi_el, 'v') == '$,.3s')

pct_kpi = {
  'kind' => 'kpi-chart', 'value' => { 'columnId' => 'v' },
  'columns' => [{ 'id' => 'v', 'format' => { 'kind' => 'number', 'formatString' => '.1%' } }]
}
S.abbreviate_measures!(pct_kpi, nil, 'kpi-chart')
ok('KPI percent value untouched', fmt(pct_kpi, 'v') == '.1%')

# bar with a formatted currency measure + an UNFORMATTED prior-year sibling:
# the sibling inherits the element's currency and both go to $,.2s (chart precision).
bar_el = {
  'kind' => 'bar-chart', 'yAxis' => { 'columnIds' => %w[y0 y1] },
  'columns' => [
    { 'id' => 'x' },                                                    # dim, must stay untouched
    { 'id' => 'y0', 'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } },
    { 'id' => 'y1' }                                                    # unformatted PY column
  ]
}
S.abbreviate_measures!(bar_el, nil, 'bar-chart')
ok('bar currency measure -> $,.2s',        fmt(bar_el, 'y0') == '$,.2s')
ok('bar unformatted sibling -> $,.2s',     fmt(bar_el, 'y1') == '$,.2s')
ok('bar dimension column untouched',       (bar_el['columns'].find { |c| c['id'] == 'x' }).key?('format') == false)

# display_units 'none' -> no abbreviation (full precision honored)
full_el = {
  'kind' => 'kpi-chart', 'value' => { 'columnId' => 'v' },
  'columns' => [{ 'id' => 'v', 'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } }]
}
S.abbreviate_measures!(full_el, 'none', 'kpi-chart')
ok('display_units none keeps full $,.0f', fmt(full_el, 'v') == '$,.0f')

# tables never abbreviate (PBI tables show full numbers too)
tbl_el = {
  'kind' => 'pivot-table', 'values' => ['c1'],
  'columns' => [{ 'id' => 'c1', 'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } }]
}
S.abbreviate_measures!(tbl_el, nil, 'pivot-table')
ok('pivot-table values NOT abbreviated', fmt(tbl_el, 'c1') == '$,.0f')

# --- presentation_table! -------------------------------------------------------
t = { 'kind' => 'table' }; S.presentation_table!(t, 'table')
ok('table gets presentation tableStyle', t.dig('tableStyle', 'preset') == 'presentation')
k = { 'kind' => 'kpi-chart' }; S.presentation_table!(k, 'kpi-chart')
ok('kpi-chart gets NO tableStyle', !k.key?('tableStyle'))
pre = { 'kind' => 'pivot-table', 'tableStyle' => { 'preset' => 'spreadsheet' } }
S.presentation_table!(pre, 'pivot-table')
ok('existing tableStyle not clobbered', pre.dig('tableStyle', 'preset') == 'spreadsheet')

puts $fail.zero? ? "\nall pbi-style tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
