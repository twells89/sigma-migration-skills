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
  JSON.parse(JSON.generate(
    'pages' => [{
      'name' => 'Dash',
      'elements' => [
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
    }]
  ))
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
kpi = s['pages'][0]['elements'][1]
kpi['columns'][0]['formula'] = '[Total Calls]'
errs = lint(s)
k1 = rule(errs, 'K1')
check(k1.size == 1, "K1: bare sibling ref in kpi value column → 1 violation (got #{errs.inspect})", fails)
check(k1.first.to_s.include?('render null') && k1.first.to_s.include?('Total Revenue'),
      'K1 message names the element and says bare refs render null', fails)

# K1 only fires on the VALUE column — a bare-ref helper sibling is fine.
s = valid_spec
s['pages'][0]['elements'][1]['columns'] << { 'id' => 'col-helper', 'name' => 'Helper', 'formula' => '[Revenue]' }
check(rule(lint(s), 'K1').empty?, 'K1: bare ref on a NON-value kpi column → no violation', fails)

# ---- S1: backgroundColor on kpi-chart / bar-chart ----------------------------
%w[kpi-chart bar-chart].each_with_index do |kind, i|
  s = valid_spec
  s['pages'][0]['elements'][1 + i]['style'] = { 'backgroundColor' => '#00000000' }
  s1 = rule(lint(s), 'S1')
  check(s1.size == 1, "S1: backgroundColor on #{kind} → 1 violation", fails)
  check(s1.first.to_s.include?('blanks the tile in PNG export') && s1.first.to_s.include?('container styling'),
        "S1 message (#{kind}) names the export blanking + the container-styling fix", fails)
end
# other kinds keep backgroundColor legally (e.g. text elements / tables)
s = valid_spec
s['pages'][0]['elements'][0]['style'] = { 'backgroundColor' => '#FFFFFF' }
check(rule(lint(s), 'S1').empty?, 'S1: backgroundColor on a table → no violation', fails)

# ---- C5: single-select control carrying values:[] ----------------------------
s = valid_spec
ctl = s['pages'][0]['elements'][4]
ctl.delete('value')
ctl['values'] = ['East']
c5 = rule(lint(s), 'C5')
check(c5.size == 1, 'C5: selectionMode single + values array → 1 violation', fails)
check(c5.first.to_s.include?('value: "East"'), 'C5 message spells out the scalar-value fix', fails)

# multi-select values arrays are legal
s = valid_spec
ctl = s['pages'][0]['elements'][4]
ctl.delete('value')
ctl['selectionMode'] = 'multi'
ctl['values'] = %w[East West]
check(rule(lint(s), 'C5').empty?, 'C5: selectionMode multi + values array → no violation', fails)

# ---- N1: whitespace-only names ------------------------------------------------
s = valid_spec
s['pages'][0]['elements'][2]['name'] = '  '
n1 = rule(lint(s), 'N1')
check(n1.size == 1, 'N1: whitespace-only element name → 1 violation', fails)
check(n1.first.to_s.include?('parity header matching') && n1.first.to_s.include?('title hiding belongs on the element'),
      'N1 message names the breakage + the real fix', fails)

s = valid_spec
s['pages'][0]['elements'][0]['columns'][1]['name'] = ''
n1c = rule(lint(s), 'N1')
check(n1c.size == 1 && n1c.first.to_s.include?("column 'col-rev'"),
      'N1: empty column name → 1 violation naming the column', fails)

# an element with NO name key at all is not an N1 (Sigma derives a name)
s = valid_spec
s['pages'][0]['elements'][0].delete('name')
check(rule(lint(s), 'N1').empty?, 'N1: absent name key → no violation', fails)

# ---- P1 (WARN): conditionalFormats includeValues:false ------------------------
s = valid_spec
s['pages'][0]['elements'][3]['conditionalFormats'][0]['includeValues'] = false
warns = lint_warnings(s)
p1 = warns.select { |x| x.start_with?('P1 ') }
check(p1.size == 1, 'P1: includeValues:false → 1 WARNING', fails)
check(p1.first.to_s.include?('silently disables the format'), 'P1 message says the format is silently disabled', fails)
check(rule(lint(s), 'P1').empty?, 'P1 is WARN-only — never in the FAIL set', fails)

# ---- I1 (WARN): If()/Switch() over a bare column ref ---------------------------
s = valid_spec
s['pages'][0]['elements'][0]['columns'][2]['formula'] = 'If([Src/Flag], [Src/Revenue], 0)'
warns = lint_warnings(s)
i1 = warns.select { |x| x.start_with?('I1 ') }
check(i1.size == 1, 'I1: If() over bare column ref → 1 WARNING', fails)
check(i1.first.to_s.include?('= 1'), 'I1 message suggests the explicit = 1 comparison', fails)
check(rule(lint(s), 'I1').empty?, 'I1 is WARN-only — never in the FAIL set', fails)

# v5.4: Switch is MATCH-form in Sigma — a bare [col] first argument is the
# matched SUBJECT (the builder's own SORT_ORD ordering columns are exactly
# this shape) and must NOT warn. I1 is If-only now.
s = valid_spec
s['pages'][0]['elements'][0]['columns'][2]['formula'] = 'Sum(Switch([Status], "done", 1, 0))'
check(lint_warnings(s).none? { |x| x.start_with?('I1 ') }, 'I1: match-form Switch over bare subject → NO warning (v5.4)', fails)

# explicit comparison must NOT warn
s = valid_spec
s['pages'][0]['elements'][0]['columns'][2]['formula'] = 'If([Src/Flag] = 1, [Src/Revenue], 0)'
check(lint_warnings(s).none? { |x| x.start_with?('I1 ') }, 'I1: If() with explicit comparison → no warning', fails)

# ---- regression: pre-existing rules untouched ---------------------------------
# T1: aggregate + dimension table without groupings still fails
s = valid_spec
s['pages'][0]['elements'][0]['columns'][1]['formula'] = 'Sum([Src/Revenue])'
check(rule(lint(s), 'T1').size == 1, 'T1 regression: agg+dim table without groupings still fails', fails)

# C2: control value fields nested under an OBJECT still fail; scalar value stays legal
s = valid_spec
s['pages'][0]['elements'][4]['value'] = { 'low' => 1, 'high' => 5 }
check(rule(lint(s), 'C2').size == 1, 'C2 regression: value OBJECT on a control still fails', fails)
check(rule(lint(valid_spec), 'C2').empty?, 'C2 regression: scalar value on a control stays legal', fails)

# C3: unwired list control still fails
s = valid_spec
s['pages'][0]['elements'][4].delete('filters')
check(rule(lint(s), 'C3').size == 1, 'C3 regression: list control wired to nothing still fails', fails)

# ---- C6: controlType enum + docs-only top-n ---------------------------------
s = valid_spec
s['pages'][0]['elements'][4]['controlType'] = 'dropdown'
c6 = rule(lint(s), 'C6')
check(c6.size == 1 && c6.first.include?('unknown controlType "dropdown"'), 'C6: unknown controlType flagged', fails)
s = valid_spec
s['pages'][0]['elements'][4]['controlType'] = 'top-n'
s['pages'][0]['elements'][4].delete('selectionMode')   # avoid unrelated C5 noise
c6b = rule(lint(s), 'C6')
check(c6b.size == 1 && c6b.first.include?('docs-only'), 'C6: docs-only top-n flagged with the element rank-filter fix', fails)

# ---- C7: required per-type fields -------------------------------------------
s = valid_spec
ct = s['pages'][0]['elements'][4]
ct['controlType'] = 'number'; ct.delete('selectionMode'); ct['value'] = 5
check(rule(lint(s), 'C7').size == 1, 'C7: number control missing `mode` → 1 violation', fails)
ct['mode'] = '>='
check(rule(lint(s), 'C7').empty?, 'C7: number control WITH `mode` → clean', fails)
s = valid_spec
rs = s['pages'][0]['elements'][4]
rs['controlType'] = 'range-slider'; rs.delete('selectionMode'); rs.delete('value')
check(rule(lint(s), 'C7').any? { |e| e.include?('low`/`high') }, 'C7: range-slider without low/high → violation', fails)
rs['low'] = 0; rs['high'] = 100
check(rule(lint(s), 'C7').empty?, 'C7: range-slider with low/high → clean', fails)
s = valid_spec
nr = s['pages'][0]['elements'][4]
nr['controlType'] = 'number-range'; nr.delete('selectionMode'); nr.delete('value')
check(rule(lint(s), 'C7').any? { |e| e.include?('number-range') },
      'C7: number-range with neither min nor max → violation', fails)
nr['min'] = 0; nr['max'] = 100
check(rule(lint(s), 'C7').empty?, 'C7: number-range with min/max → clean', fails)

# ---- C8: includeNulls placement --------------------------------------------
s = valid_spec
s['pages'][0]['elements'][4]['includeNulls'] = true    # on a `list` control (off-schema)
check(rule(lint(s), 'C8').size == 1, 'C8: includeNulls on a list control → 1 violation', fails)
s = valid_spec
n = s['pages'][0]['elements'][4]
n['controlType'] = 'number'; n['mode'] = '='; n.delete('selectionMode'); n['value'] = 1; n['includeNulls'] = true
check(rule(lint(s), 'C8').empty?, 'C8: includeNulls on a number control → allowed (no violation)', fails)

puts
if fails.empty?
  puts 'ALL PASS — preflight_lint K1/S1/C5/N1 fail rules + P1/I1 warnings + T1/C2/C3 regressions'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
