#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for preflight_lint's rules — the pre-existing enterprise-class
# checks (T1/C1/C2/C3) plus the v3 rules codified from the 10-workbook live run
# (SKILL_IMPROVEMENT_PLAN_V3 §D4):
#
#   K1  kpi-chart value column with a bare sibling-column ref (renders null)
#   S1  style.backgroundColor on kpi-chart / bar-chart (blanks PNG export)
#   C5  selectionMode:"single" control carrying values:[] instead of scalar value
#   N1  whitespace-only element / column names (break parity header matching)
#   P1  conditionalFormats includeValues:false (silent no-op)         [WARN]
#   I1  If() over a bare column ref, no comparison operator (v5.4: If-only)  [WARN]
#   A1  DROPPED_BY_API control fields (accepted-then-silently-ignored, #417) [WARN]
#   A2  date-range bare-date startDate/endDate default (silently dropped, #415) [WARN]
#
# Each rule: a clean spec passes, each violation is caught with the right rule
# id + message. WARN rules must never appear in lint() (the FAIL set).
#
# Usage:  ruby scripts/test-preflight-lint.rb
require 'json'
require_relative 'lib/preflight_lint'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Deep-copyable VALID spec: exercises every linted shape cleanly — an inlined-
# aggregate KPI, a styled-but-legal bar chart, a grouped table, a single-select
# control with a scalar value, a conditional format with includeValues:true,
# and an If() with an explicit comparison.
def valid_spec
  elements = [
    { 'id' => 'el-master', 'kind' => 'table', 'name' => 'Master',
      'columns' => [
        { 'id' => 'col-region', 'name' => 'Region', 'formula' => '[Src/Region]' },
        { 'id' => 'col-rev', 'name' => 'Revenue', 'formula' => '[Src/Revenue]' },
        { 'id' => 'col-flagged', 'name' => 'Flagged Revenue',
          'formula' => 'If([Src/Flag] = 1, [Src/Revenue], 0)' }
      ] },
    { 'id' => 'el-kpi', 'kind' => 'kpi-chart', 'name' => 'Total Revenue',
      'source' => { 'kind' => 'table', 'elementId' => 'el-master' },
      'columns' => [{ 'id' => 'col-kpi-val', 'name' => 'Total Revenue',
                      'formula' => 'Sum([Revenue])' }],
      'value' => { 'columnId' => 'col-kpi-val' } },
    { 'id' => 'el-bar', 'kind' => 'bar-chart', 'name' => 'Revenue by Region',
      'source' => { 'kind' => 'table', 'elementId' => 'el-master' },
      'style' => { 'legend' => { 'position' => 'bottom' } },
      'columns' => [
        { 'id' => 'col-bar-dim', 'name' => 'Region', 'formula' => '[Region]' },
        { 'id' => 'col-bar-val', 'name' => 'Revenue', 'formula' => 'Sum([Revenue])' }
      ] },
    { 'id' => 'el-pivot', 'kind' => 'pivot-table', 'name' => 'Waffle',
      'columns' => [{ 'id' => 'col-cell', 'name' => 'Filled', 'formula' => 'Max([Revenue])' }],
      'conditionalFormats' => [{ 'columnId' => 'col-cell', 'includeValues' => true,
                                 'backgroundScale' => { 'kind' => 'sequential' } }] },
    { 'id' => 'el-ctl', 'kind' => 'control', 'controlId' => 'ctl-region',
      'controlType' => 'list', 'name' => 'Region Filter',
      'selectionMode' => 'single', 'value' => 'East',
      'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'el-bar' },
                      'columnId' => 'col-bar-dim' }] }
  ]
  JSON.parse(JSON.generate(
    'document' => {
      'schemaVersion' => 4,
      'kind' => 'workbook',
      'pages' => [{ 'id' => 'p1', 'name' => 'Dash' }],
      'elements' => elements,
      'layout' => "<Page id=\"p1\">#{elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
    }
  ))
end

def fixture_elements(spec)
  spec.fetch('document').fetch('elements')
end

def rule(errs, id)
  errs.select { |e| e.start_with?("#{id} ") }
end

# ---- baseline: the valid spec is clean (errors AND warnings) -----------------
v = lint(valid_spec)
check(v.empty?, "valid spec → zero violations (got #{v.inspect})", fails)
w = lint_warnings(valid_spec)
check(w.empty?, "valid spec → zero warnings (got #{w.inspect})", fails)

# ---- K1: kpi-chart value column with a bare sibling ref ----------------------
s = valid_spec
kpi = fixture_elements(s)[1]
kpi['columns'][0]['formula'] = '[Total Calls]'
errs = lint(s)
k1 = rule(errs, 'K1')
check(k1.size == 1, "K1: bare sibling ref in kpi value column → 1 violation (got #{errs.inspect})", fails)
check(k1.first.to_s.include?('render null') && k1.first.to_s.include?('Total Revenue'),
      'K1 message names the element and says bare refs render null', fails)

# K1 only fires on the VALUE column — a bare-ref helper sibling is fine.
s = valid_spec
fixture_elements(s)[1]['columns'] << { 'id' => 'col-helper', 'name' => 'Helper', 'formula' => '[Revenue]' }
check(rule(lint(s), 'K1').empty?, 'K1: bare ref on a NON-value kpi column → no violation', fails)

# ---- S1: backgroundColor on kpi-chart / bar-chart ----------------------------
%w[kpi-chart bar-chart].each_with_index do |kind, i|
  s = valid_spec
  fixture_elements(s)[1 + i]['style'] = { 'backgroundColor' => '#00000000' }
  s1 = rule(lint(s), 'S1')
  check(s1.size == 1, "S1: backgroundColor on #{kind} → 1 violation", fails)
  check(s1.first.to_s.include?('blanks the tile in PNG export') && s1.first.to_s.include?('container styling'),
        "S1 message (#{kind}) names the export blanking + the container-styling fix", fails)
end
# other kinds keep backgroundColor legally (e.g. text elements / tables)
s = valid_spec
fixture_elements(s)[0]['style'] = { 'backgroundColor' => '#FFFFFF' }
check(rule(lint(s), 'S1').empty?, 'S1: backgroundColor on a table → no violation', fails)

# ---- C5: single-select control carrying values:[] ----------------------------
s = valid_spec
ctl = fixture_elements(s)[4]
ctl.delete('value')
ctl['values'] = ['East']
c5 = rule(lint(s), 'C5')
check(c5.size == 1, 'C5: selectionMode single + values array → 1 violation', fails)
check(c5.first.to_s.include?('value: "East"'), 'C5 message spells out the scalar-value fix', fails)

# multi-select values arrays are legal
s = valid_spec
ctl = fixture_elements(s)[4]
ctl.delete('value')
ctl['selectionMode'] = 'multi'
ctl['values'] = %w[East West]
check(rule(lint(s), 'C5').empty?, 'C5: selectionMode multi + values array → no violation', fails)

# ---- N1: whitespace-only names ------------------------------------------------
s = valid_spec
fixture_elements(s)[2]['name'] = '  '
n1 = rule(lint(s), 'N1')
check(n1.size == 1, 'N1: whitespace-only element name → 1 violation', fails)
check(n1.first.to_s.include?('parity header matching') && n1.first.to_s.include?('title hiding belongs on the element'),
      'N1 message names the breakage + the real fix', fails)

s = valid_spec
fixture_elements(s)[0]['columns'][1]['name'] = ''
n1c = rule(lint(s), 'N1')
check(n1c.size == 1 && n1c.first.to_s.include?("column 'col-rev'"),
      'N1: empty column name → 1 violation naming the column', fails)

# an element with NO name key at all is not an N1 (Sigma derives a name)
s = valid_spec
fixture_elements(s)[0].delete('name')
check(rule(lint(s), 'N1').empty?, 'N1: absent name key → no violation', fails)

# ---- P1 (WARN): conditionalFormats includeValues:false ------------------------
s = valid_spec
fixture_elements(s)[3]['conditionalFormats'][0]['includeValues'] = false
warns = lint_warnings(s)
p1 = warns.select { |x| x.start_with?('P1 ') }
check(p1.size == 1, 'P1: includeValues:false → 1 WARNING', fails)
check(p1.first.to_s.include?('silently disables the format'), 'P1 message says the format is silently disabled', fails)
check(rule(lint(s), 'P1').empty?, 'P1 is WARN-only — never in the FAIL set', fails)

# ---- I1 (WARN): If()/Switch() over a bare column ref ---------------------------
s = valid_spec
fixture_elements(s)[0]['columns'][2]['formula'] = 'If([Src/Flag], [Src/Revenue], 0)'
warns = lint_warnings(s)
i1 = warns.select { |x| x.start_with?('I1 ') }
check(i1.size == 1, 'I1: If() over bare column ref → 1 WARNING', fails)
check(i1.first.to_s.include?('= 1'), 'I1 message suggests the explicit = 1 comparison', fails)
check(rule(lint(s), 'I1').empty?, 'I1 is WARN-only — never in the FAIL set', fails)

# v5.4: Switch is MATCH-form in Sigma — a bare [col] first argument is the
# matched SUBJECT (the builder's own SORT_ORD ordering columns are exactly
# this shape) and must NOT warn. I1 is If-only now.
s = valid_spec
fixture_elements(s)[0]['columns'][2]['formula'] = 'Sum(Switch([Status], "done", 1, 0))'
check(lint_warnings(s).none? { |x| x.start_with?('I1 ') }, 'I1: match-form Switch over bare subject → NO warning (v5.4)', fails)

# explicit comparison must NOT warn
s = valid_spec
fixture_elements(s)[0]['columns'][2]['formula'] = 'If([Src/Flag] = 1, [Src/Revenue], 0)'
check(lint_warnings(s).none? { |x| x.start_with?('I1 ') }, 'I1: If() with explicit comparison → no warning', fails)

# ---- A1 (WARN): DROPPED_BY_API fields — accepted then silently ignored (#417) --
# One warning PER field, naming the field, the silent-drop behavior, and the
# workaround — and phrased as "silently ignored", never as a will-400.
# `conditional` members (filters, #456) persist in the normal case and are NOT
# A1-warned on mere presence — they are asserted separately just below.
DROPPED_BY_API.reject { |_f, info| info['conditional'] }.each_key do |field|
  s = valid_spec
  fixture_elements(s)[4][field] = false
  warns = lint_warnings(s)
  a1 = warns.select { |x| x.start_with?('A1 ') }
  check(a1.size == 1, "A1: `#{field}` on a control → exactly 1 WARNING (got #{a1.inspect})", fails)
  check(a1.first.to_s.include?("`#{field}`") && a1.first.to_s.include?('SILENTLY DROPPED'),
        "A1 message names `#{field}` + the silent drop", fails)
  check(a1.first.to_s.include?('NOT a 400') && a1.first.to_s.include?('Workaround:'),
        "A1 message (#{field}) distinguishes silently-ignored from will-400 and names a workaround", fails)
  check(rule(lint(s), 'A1').empty?, "A1 (#{field}) is WARN-only — never in the FAIL set", fails)
end
# #456: `filters` is a CONDITIONAL DROPPED_BY_API member — documented in the
# contract but NOT A1-warned on mere presence (every valid control has filters).
check(DROPPED_BY_API.key?('filters') && DROPPED_BY_API['filters']['conditional'],
      'DROPPED_BY_API covers the filter TARGET binding as a conditional member (#456)', fails)
check(DROPPED_BY_API['filters']['workaround'].to_s.include?('Text(') &&
      DROPPED_BY_API['filters']['workaround'].to_s.include?('never ship a control that filters nothing'),
      'filters workaround names the Text() decode + the never-ship-a-dead-control floor', fails)
# valid_spec's control ALREADY carries a filters binding — it must NOT A1-warn.
check(lint_warnings(valid_spec).none? { |x| x.start_with?('A1 ') && x.include?('`filters`') },
      'A1: a control carrying a normal filters binding → no A1 warning (conditional member)', fails)
# all eight #417 fields are in the contract table
%w[showNullOption showClearButton showSearchBox showHistogram allowMultipleSelection
   excludeValues showExpandedList required].each do |f417|
  check(DROPPED_BY_API.key?(f417), "DROPPED_BY_API covers #{f417} (#417)", fails)
end
# multiple dropped fields on one control → one warning each
s = valid_spec
fixture_elements(s)[4]['showNullOption'] = false
fixture_elements(s)[4]['showSearchBox'] = true
check(lint_warnings(s).count { |x| x.start_with?('A1 ') } == 2,
      'A1: two dropped fields on one control → two warnings', fails)
# the showNullOption workaround is the option-source IsNotNull filter
s = valid_spec
fixture_elements(s)[4]['showNullOption'] = false
a1 = lint_warnings(s).find { |x| x.start_with?('A1 ') }
check(a1.to_s.include?('IsNotNull'), 'A1 showNullOption workaround names the option-source IsNotNull filter', fails)

# ---- A2 (WARN): date-range bare-date default (#415) ---------------------------
def date_range_ctl(s, start_d, end_d = nil)
  ctl = fixture_elements(s)[4]
  ctl['controlType'] = 'date-range'
  ctl.delete('selectionMode')
  ctl.delete('value')
  ctl['mode'] = 'between'
  ctl['startDate'] = start_d if start_d
  ctl['endDate'] = end_d if end_d
  ctl
end
s = valid_spec
date_range_ctl(s, '2026-01-01')
warns = lint_warnings(s)
a2 = warns.select { |x| x.start_with?('A2 ') }
check(a2.size == 1, "A2: bare-date startDate → 1 WARNING (got #{a2.inspect})", fails)
check(a2.first.to_s.include?('SILENTLY DROPPED') && a2.first.to_s.include?('2026-01-01T00:00:00Z'),
      'A2 message says the default silently drops and shows the persisting ISO-UTC form', fails)
check(a2.first.to_s.include?('POSTPUBLISH_GUIDE'),
      'A2 message names the UI-default honest floor (postpublish guide)', fails)
check(rule(lint(s), 'A2').empty?, 'A2 is WARN-only — never in the FAIL set', fails)
# both bounds bare → one warning per field
s = valid_spec
date_range_ctl(s, '2026-01-01', '2026-03-31')
check(lint_warnings(s).count { |x| x.start_with?('A2 ') } == 2,
      'A2: bare startDate AND endDate → two warnings', fails)
# the persisting Z-suffixed form is clean
s = valid_spec
date_range_ctl(s, '2026-01-01T00:00:00Z', '2026-03-31T23:59:59Z')
check(lint_warnings(s).none? { |x| x.start_with?('A2 ') },
      'A2: full ISO-8601 UTC timestamps → no warning (documented round-trip form)', fails)
# relative {op,unit,value} hashes (custom mode) are not strings — no warning
s = valid_spec
ctl = date_range_ctl(s, nil)
ctl['mode'] = 'custom'
ctl['startDate'] = { 'op' => 'now-minus', 'unit' => 'day', 'value' => 30 }
check(lint_warnings(s).none? { |x| x.start_with?('A2 ') },
      'A2: relative startDate hash (custom mode) → no warning', fails)
# A2 is date-range-only: a bare-date scalar on a `date` control is a `value`, not startDate
s = valid_spec
ctl = fixture_elements(s)[4]
ctl['controlType'] = 'date'; ctl['mode'] = '='; ctl.delete('selectionMode'); ctl['value'] = '2026-01-01'
check(lint_warnings(s).none? { |x| x.start_with?('A2 ') },
      'A2: date control with scalar value → no warning', fails)

# ---- regression: pre-existing rules untouched ---------------------------------
# T1: aggregate + dimension table without groupings still fails
s = valid_spec
fixture_elements(s)[0]['columns'][1]['formula'] = 'Sum([Src/Revenue])'
check(rule(lint(s), 'T1').size == 1, 'T1 regression: agg+dim table without groupings still fails', fails)

# C2: control value fields nested under an OBJECT still fail; scalar value stays legal
s = valid_spec
fixture_elements(s)[4]['value'] = { 'low' => 1, 'high' => 5 }
check(rule(lint(s), 'C2').size == 1, 'C2 regression: value OBJECT on a control still fails', fails)
check(rule(lint(valid_spec), 'C2').empty?, 'C2 regression: scalar value on a control stays legal', fails)

# C3: unwired list control still fails
s = valid_spec
fixture_elements(s)[4].delete('filters')
check(rule(lint(s), 'C3').size == 1, 'C3 regression: list control wired to nothing still fails', fails)

# ---- C6: controlType enum + docs-only top-n ---------------------------------
s = valid_spec
fixture_elements(s)[4]['controlType'] = 'dropdown'
c6 = rule(lint(s), 'C6')
check(c6.size == 1 && c6.first.include?('unknown controlType "dropdown"'), 'C6: unknown controlType flagged', fails)
s = valid_spec
fixture_elements(s)[4]['controlType'] = 'top-n'
fixture_elements(s)[4].delete('selectionMode')   # avoid unrelated C5 noise
c6b = rule(lint(s), 'C6')
check(c6b.size == 1 && c6b.first.include?('docs-only'), 'C6: docs-only top-n flagged with the element rank-filter fix', fails)

# ---- C7: required per-type fields -------------------------------------------
s = valid_spec
ct = fixture_elements(s)[4]
ct['controlType'] = 'number'; ct.delete('selectionMode'); ct['value'] = 5
check(rule(lint(s), 'C7').size == 1, 'C7: number control missing `mode` → 1 violation', fails)
ct['mode'] = '>='
check(rule(lint(s), 'C7').empty?, 'C7: number control WITH `mode` → clean', fails)
s = valid_spec
rs = fixture_elements(s)[4]
rs['controlType'] = 'range-slider'; rs.delete('selectionMode'); rs.delete('value')
check(rule(lint(s), 'C7').any? { |e| e.include?('low`/`high') }, 'C7: range-slider without low/high → violation', fails)
rs['low'] = 0; rs['high'] = 100
check(rule(lint(s), 'C7').empty?, 'C7: range-slider with low/high → clean', fails)

# ---- C7: unbounded number-range {min:null,max:null} → HARD error (#422) ------
# The recurring #422 defect: an UNRESTRICTED Tableau quantitative
# quick-filter produced a number-range with min AND max present-and-null, which
# 400s the whole POST. C7 must HARD-error it (in lint(), the FAIL set), name the
# fix, and NEVER flag the valid keys-omitted unbounded form.
def number_range_ctl(s)
  ctl = fixture_elements(s)[4]
  ctl['controlType'] = 'number-range'
  ctl.delete('selectionMode')
  ctl.delete('value')
  ctl.delete('mode')
  ctl
end
# min:null AND max:null control → hard C7 violation naming the fix.
s = valid_spec
ctl = number_range_ctl(s)
ctl['min'] = nil
ctl['max'] = nil
c7nr = rule(lint(s), 'C7')
check(c7nr.size == 1, "C7: number-range control with min:null and max:null → 1 HARD violation (got #{lint(s).inspect})", fails)
check(c7nr.first.to_s.include?('min:null and max:null') && c7nr.first.to_s.include?('#422'),
      'C7 number-range message names the {min:null,max:null} 400 shape and the issue', fails)
check(c7nr.first.to_s.include?('valid unbounded number-range') && c7nr.first.to_s.include?('never null bounds'),
      'C7 number-range message names the remedy (omit the keys / concrete bounds, never null)', fails)
# non-empty errs → the CLI would exit non-zero: assert it is a FAIL, not a warn.
check(lint_warnings(s).none? { |x| x.start_with?('C7 ') }, 'C7 number-range null-bounds is a hard error, never a warning', fails)

# a number-range with the min/max keys OMITTED is a VALID unbounded control — no C7.
s = valid_spec
number_range_ctl(s) # controlType only, no min/max keys
check(rule(lint(s), 'C7').empty?, 'C7: number-range with min/max keys OMITTED → valid unbounded, no violation', fails)

# a BOUNDED number-range still passes clean.
s = valid_spec
ctl = number_range_ctl(s)
ctl['min'] = 0
ctl['max'] = 100000
check(rule(lint(s), 'C7').empty?, 'C7: bounded number-range (min:0,max:100000) → clean', fails)

# only ONE bound present-and-null (partial) is still the unbounded trap → hard error.
s = valid_spec
ctl = number_range_ctl(s)
ctl['min'] = nil # max key absent
check(rule(lint(s), 'C7').size == 1, 'C7: number-range with min:null (max absent) → hard violation', fails)

# ---- C7: unbounded number-range ELEMENT FILTER {min:null,max:null} (#422) ----
# The exact shape the builder used to emit for a worksheet-scoped unrestricted
# quantitative quick-filter — an ELEMENT filter, not a control. C7 must catch it
# too (element filters were previously unlinted).
s = valid_spec
fixture_elements(s)[1]['filters'] = [
  { 'columnId' => 'col-kpi-val', 'kind' => 'number-range', 'mode' => 'between',
    'min' => nil, 'max' => nil, 'includeNulls' => 'never' }
]
c7ef = rule(lint(s), 'C7')
check(c7ef.size == 1 && c7ef.first.include?('filter[0]') && c7ef.first.include?('#422'),
      "C7: number-range ELEMENT filter with min:null/max:null → 1 HARD violation naming filter[0] (got #{lint(s).inspect})", fails)
check(c7ef.first.to_s.include?('drop the filter'),
      'C7 element-filter message names the fix (drop the no-op filter)', fails)
# a bounded number-range element filter passes; keys-omitted passes.
s = valid_spec
fixture_elements(s)[1]['filters'] = [
  { 'columnId' => 'col-kpi-val', 'kind' => 'number-range', 'mode' => 'between', 'min' => 1, 'max' => 9, 'includeNulls' => 'never' }
]
check(rule(lint(s), 'C7').empty?, 'C7: bounded number-range element filter → clean', fails)
s = valid_spec
fixture_elements(s)[1]['filters'] = [
  { 'columnId' => 'col-kpi-val', 'kind' => 'list', 'mode' => 'include', 'values' => %w[a b] }
]
check(rule(lint(s), 'C7').empty?, 'C7: non-number-range element filter → clean', fails)

# ---- C8: includeNulls placement --------------------------------------------
s = valid_spec
fixture_elements(s)[4]['includeNulls'] = true    # on a `list` control (off-schema)
check(rule(lint(s), 'C8').size == 1, 'C8: includeNulls on a list control → 1 violation', fails)
s = valid_spec
n = fixture_elements(s)[4]
n['controlType'] = 'number'; n['mode'] = '='; n.delete('selectionMode'); n['value'] = 1; n['includeNulls'] = true
check(rule(lint(s), 'C8').empty?, 'C8: includeNulls on a number control → allowed (no violation)', fails)

# ---- A3 (PR-18): integer-coded dimension control without a Text() decode -----
# A master carrying a raw integer STORE_KEY column, optionally with a decode
# sibling, and a list control targeting one or the other.
def a3_spec(target_col_id, with_decode: false)
  master_cols = [{ 'id' => 'm-store', 'name' => 'Store Key', 'formula' => '[Src/STORE_KEY]' }]
  master_cols << { 'id' => 'skt-store', 'name' => 'Store Key (Text)', 'formula' => 'Text([Store Key])' } if with_decode
  elements = [
    { 'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'columns' => master_cols },
    { 'id' => 'el-ctl-store', 'kind' => 'control', 'controlId' => 'ctl-store',
      'controlType' => 'list', 'name' => 'Store Key', 'selectionMode' => 'multiple',
      'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => target_col_id }] }
  ]
  JSON.parse(JSON.generate(
    'document' => {
      'schemaVersion' => 4,
      'kind' => 'workbook',
      'pages' => [{ 'id' => 'p1', 'name' => 'Dash' }],
      'elements' => elements,
      'layout' => "<Page id=\"p1\">#{elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
    }
  ))
end
scope_int = ->(status = nil) { { 'controls' => [{ 'controlId' => 'ctl-store', 'integer_dim' => true }.tap { |h| h['decode'] = { 'status' => status } if status }] } }

# A3-1: scope says integer_dim, spec targets the RAW column, no decode → WARN.
w = lint_warnings(a3_spec('m-store'), scope: scope_int.call)
a3 = rule(w, 'A3')
check(a3.size == 1 && a3.first.include?('SILENTLY strips'),
      "A3: integer_dim control w/o decode → 1 WARNING (got #{a3.inspect})", fails)
check(rule(lint(a3_spec('m-store')), 'A3').empty?, 'A3 is WARN-only — never in the FAIL set', fails)

# A3-2: decode present, control bound to it → NO A3.
ok = lint_warnings(a3_spec('skt-store', with_decode: true), scope: scope_int.call('auto-decoded'))
check(rule(ok, 'A3').empty?, 'A3: control bound to the Text() decode → no warning', fails)

# A3-3: spec-only mis-wire (decode column EXISTS but control targets the raw
# column), NO scope → still caught precisely.
w3 = lint_warnings(a3_spec('m-store', with_decode: true))
a33 = rule(w3, 'A3')
check(a33.size == 1 && a33.first.include?('exists on the target element') && a33.first.include?('skt-store'),
      "A3: spec-only mis-wire (raw target, decode sibling present) → WARNING naming the decode col (got #{a33.inspect})", fails)

# A3-4: manual-required decode → softer WARN pointing at the POSTPUBLISH guide.
w4 = lint_warnings(a3_spec('m-store'), scope: scope_int.call('manual-required'))
a34 = rule(w4, 'A3')
check(a34.size == 1 && a34.first.include?('POSTPUBLISH_GUIDE'),
      "A3: manual-required decode → WARN routes to POSTPUBLISH_GUIDE (got #{a34.inspect})", fails)

# A3-5: a plain STRING list control (no integer_dim, no decode sibling) → NO A3.
check(rule(lint_warnings(valid_spec), 'A3').empty?, 'A3: ordinary string list control → no warning', fails)

# ---- N2 (wave-2 §6.2): slash in a column display name — WARN, not FAIL ------
# '/' inside a display name is ambiguous against the [Element/Column] path
# syntax: cross-element refs to it mis-resolve and derived elements drop it.
s = valid_spec
fixture_elements(s)[0]['columns'] << { 'id' => 'col-slash', 'name' => 'Date (Month /Year)',
                                       'formula' => '[Src/Date Month Year]' }
n2 = rule(lint_warnings(s), 'N2')
check(n2.size == 1 && n2.first.include?('Date (Month /Year)') && n2.first.include?('Rename'),
      "N2: slash-named column → 1 WARNING naming the column + rename fix (got #{n2.inspect})", fails)
check(rule(lint(s), 'N2').empty?, 'N2 is WARN-only — never in the FAIL set', fails)
# metrics are covered too
s = valid_spec
(fixture_elements(s)[0]['metrics'] ||= []) << { 'id' => 'met-slash', 'name' => 'Rev H/L',
                                                'formula' => 'Sum([Revenue])' }
check(rule(lint_warnings(s), 'N2').size == 1, 'N2: slash-named METRIC → warning', fails)
# slash in a FORMULA (an [Element/Column] ref) must never trip N2
check(rule(lint_warnings(valid_spec), 'N2').empty?,
      'N2: slashes in formulas ([Src/Region] refs) never trip — names only', fails)

puts
if fails.empty?
  puts 'ALL PASS — preflight_lint K1/S1/C5/N1 fail rules + P1/I1/A1/A2/A3/N2 warnings + T1/C2/C3 regressions'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
