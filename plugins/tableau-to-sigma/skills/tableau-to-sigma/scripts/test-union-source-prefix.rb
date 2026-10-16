#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression: a workbook element sourced by `kind: union` resolves its refs under
# the prefix "Union of N Sources" (N = sources.size). Live
# /v2/workbooks/spec/verify REJECTS the union's own `name` as a prefix (field
# find: FP&A Executive Overview — GL actuals + forecast unioned on a hidden Data
# page). Covers both offline gates that read the prefix:
#   * validate-spec.rb         — own_prefixes accepts "Union of N Sources"
#   * assert-wb-refs-resolve.rb — union-aware ref resolution against
#     matches[].outputColumnName; leg elementIds must precede the element.
#
# Usage:  ruby scripts/test-union-source-prefix.rb
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/workbook_code'

VALIDATE = File.join(__dir__, 'validate-spec.rb')
REFS_GATE = File.join(__dir__, 'assert-wb-refs-resolve.rb')

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def leg(id)
  { 'id' => id, 'kind' => 'table', 'name' => id,
    'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm1', 'elementId' => "dm-#{id}" },
    'columns' => [{ 'id' => "#{id}-c", 'name' => 'Amount', 'formula' => '[Amount]' }] }
end

def union_source(leg_ids, name: 'All GL')
  { 'kind' => 'union', 'name' => name,
    'sources' => leg_ids.map { |i| { 'kind' => 'table', 'elementId' => i } },
    'matches' => [
      { 'outputColumnName' => 'Amount', 'sourceColumns' => leg_ids.map { '[Amount]' } },
      { 'outputColumnName' => 'Account', 'sourceColumns' => leg_ids.map { '[Account]' } }
    ] }
end

def union_el(formula, leg_ids: %w[gl fc], name: 'All GL')
  { 'id' => 'u', 'kind' => 'table', 'name' => 'Combined',
    'source' => union_source(leg_ids, name: name),
    'columns' => [{ 'id' => 'u-c1', 'name' => 'Amt', 'formula' => formula }] }
end

def validate(elements)
  spec = { 'schemaVersion' => 1, 'name' => 'union-test', 'folderId' => 'f',
           'document' => {
             'schemaVersion' => 1, 'kind' => 'workbook',
             'pages' => [{ 'id' => 'pg-0', 'name' => 'Data' }],
             'elements' => elements,
             'layout' => WorkbookCode.layout_for([[{ 'id' => 'pg-0', 'name' => 'Data' }, elements]])
           } }
  Dir.mktmpdir do |d|
    path = File.join(d, 'spec.json')
    File.write(path, JSON.generate(spec))
    out, err, st = Open3.capture3(RbConfig.ruby, VALIDATE, '--type', 'workbook', path)
    [out + err, st.exitstatus]
  end
end

DM = { 'dataModelId' => 'dm1', 'pages' => [{ 'elements' => [
  { 'id' => 'dm-gl', 'name' => 'GL Actuals', 'columnLabels' => %w[Amount Account] },
  { 'id' => 'dm-fc', 'name' => 'Forecast', 'columnLabels' => %w[Amount Account] }
] }] }

def refs_gate(elements)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'wb.json'), JSON.generate('pages' => [{ 'elements' => elements }]))
    File.write(File.join(d, 'dm.json'), JSON.generate(DM))
    out, st = Open3.capture2e(RbConfig.ruby, REFS_GATE, '--wb-spec', "#{d}/wb.json", '--dm-ids', "#{d}/dm.json")
    [st.exitstatus, out]
  end
end

puts 'test-union-source-prefix:'

puts 'Part A — validate-spec.rb'
out, code = validate([leg('gl'), leg('fc'), union_el('[Union of 2 Sources/Amount]')])
check(code.zero?, "union output ref under 'Union of N Sources' is accepted (exit #{code}: #{out.lines.grep(/prefix|ERROR/).first(2).join.strip})")

out, code = validate([leg('gl'), leg('fc'), union_el('[All GL/Amount]')])
check(code == 1 && out.include?('All GL'), "the union's own name is NOT a valid prefix (live verify rejects it) (exit #{code})")

out, code = validate([leg('gl'), leg('fc'), union_el('[Union of 3 Sources/Amount]')])
check(code == 1, "N must equal sources.size — 'Union of 3 Sources' on a 2-leg union fails (exit #{code})")

l3 = leg('x3')
out, code = validate([leg('gl'), leg('fc'), l3, union_el('[Union of 3 Sources/Amount]', leg_ids: %w[gl fc x3])])
check(code.zero?, "3-leg union resolves under 'Union of 3 Sources' (exit #{code})")

puts 'Part B — assert-wb-refs-resolve.rb'
rc, out = refs_gate([leg('gl'), leg('fc'), union_el('[Union of 2 Sources/Amount]')])
check(rc.zero?, "ref to a matched output column resolves (exit #{rc}: #{out.lines.last(2).join.strip})")

rc, out = refs_gate([leg('gl'), leg('fc'), union_el('Sum([Union of 2 Sources/Account])')])
check(rc.zero?, "second output column + aggregate wrapper resolves (exit #{rc})")

rc, out = refs_gate([leg('gl'), leg('fc'), union_el('[Union of 2 Sources/Nope]')])
check(rc == 1 && out.include?('Nope') && out.include?('not a union output column'),
      "ref to a column that is not a matches[].outputColumnName fails (exit #{rc})")

rc, out = refs_gate([union_el('[Union of 2 Sources/Amount]'), leg('gl'), leg('fc')])
check(rc == 1 && out.include?('defined LATER'),
      "union legs defined AFTER the element fail (document order) (exit #{rc})")

rc, out = refs_gate([leg('gl'), union_el('[Union of 2 Sources/Amount]')])
check(rc == 1 && out.include?('not found in the spec'),
      "a union leg elementId absent from the spec fails (exit #{rc})")

# Union refs never fall through to DM-census resolution: a prefix that merely
# looks like a DM element but is not the union prefix still goes down the DM path.
rc, out = refs_gate([leg('gl'), leg('fc'), union_el('[GL Actuals/Amount]')])
check(rc.zero?, "a genuine DM-element ref on a union element still resolves via the DM (exit #{rc})")

puts
if FAILS.empty?
  puts 'OK — union source prefix tests passed'
  exit 0
else
  warn "FAIL — #{FAILS.size} check(s) failed:"
  FAILS.each { |f| warn "  - #{f}" }
  exit 1
end
