#!/usr/bin/env ruby
# Offline test for the fix-workstream-G additions to scripts/validate-spec.rb:
#   1. GLOBAL element-ID uniqueness across ALL pages (controlIds share the
#      namespace — refs/troubleshooting.md `Duplicate id: 'ctl-xxx'` entry).
#      A live converter run emitted the same element id on two pages and
#      nothing flagged it before the POST rejection.
#   2. Function-name tiers: case-variants of known Sigma functions -> ERROR
#      (Sigma is case-sensitive); genuinely unknown names -> WARN, not error
#      (the whitelist can't be exhaustive).
#   3. FormulaNormalize wired REPORT-ONLY: NORMALIZE lines list what the
#      orchestrator's rewrite pass would change; the spec file is untouched.
#
# Usage:  ruby scripts/test-validate-spec-guards.rb

require 'json'
require 'tempfile'
require 'open3'
require_relative 'lib/workbook_code'

VALIDATE = File.join(__dir__, 'validate-spec.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def validate(spec, type: 'workbook', envelope: true)
  # Auto-envelope the minimal fixtures (schemaVersion/name/page ids) so each
  # part tests ITS guard in isolation; envelope: false exercises the envelope
  # checks themselves (Part F).
  if envelope
    spec = JSON.parse(JSON.generate(spec))
    spec['schemaVersion'] ||= 1
    spec['name'] ||= 'guards-test'
    spec['folderId'] ||= 'folder-test' # keeps warn-count assertions envelope-neutral
    (spec['pages'] || []).each_with_index { |p, i| p['id'] ||= "pg-#{i}" }
    if type == 'workbook'
      pages = Array(spec['pages'])
      page_records = pages.map do |page|
        [page.reject { |key, _| key == 'elements' }, Array(page['elements'])]
      end
      metadata = spec.reject do |key, _|
        %w[schemaVersion kind pages elements layout settings agents overlays panels].include?(key)
      end
      spec = metadata.merge(
        'document' => {
          'schemaVersion' => spec['schemaVersion'],
          'kind' => 'workbook',
          'pages' => page_records.map(&:first),
          # Preserve duplicates: Parts A1-A4 exercise duplicate diagnostics.
          'elements' => page_records.flat_map(&:last),
          'layout' => WorkbookCode.layout_for(page_records)
        }
      )
    end
  end
  tmp = Tempfile.new(['validate-guards-', '.json'])
  tmp.write(JSON.generate(spec))
  tmp.close
  out, err, st = Open3.capture3('ruby', VALIDATE, '--type', type, tmp.path)
  tmp.unlink
  [out + err, st.exitstatus]
end

def el(id, name, kind: 'table', formula: nil)
  e = { 'id' => id, 'kind' => kind, 'name' => name }
  e['columns'] = [{ 'id' => "#{id}-c1", 'name' => 'Val', 'formula' => formula }] if formula
  e
end

puts 'Part A — global element-ID uniqueness across pages'
dup_spec = { 'pages' => [
  { 'name' => 'Page One', 'elements' => [el('text-1', 'Title A', kind: 'text'), el('tbl-1', 'T1')] },
  { 'name' => 'Page Two', 'elements' => [el('text-1', 'Title B', kind: 'text'), el('tbl-2', 'T2')] }
] }
out, code = validate(dup_spec)
check(code == 1, "duplicate id across pages exits 1 (got #{code})", fails)
check(out.include?('duplicate id "text-1"'), 'error names the colliding id', fails)
check(out.include?('Page One') && out.include?('Page Two'), 'error lists BOTH pages of the collision', fails)
check(out.include?('globally unique'), 'error explains the global-uniqueness rule', fails)

triple = { 'pages' => [
  { 'name' => 'P1', 'elements' => [el('x', 'A'), el('x', 'B')] },
  { 'name' => 'P2', 'elements' => [el('x', 'C')] }
] }
out, code = validate(triple)
check(code == 1 && out.include?('used 3x'), 'triple collision counted (used 3x)', fails)

ctl_spec = { 'pages' => [{ 'name' => 'P1', 'elements' => [
  { 'id' => 'ctl-region', 'kind' => 'control', 'controlId' => 'ctl-region', 'name' => 'Region' }
] }] }
out, code = validate(ctl_spec)
check(code == 1 && out.include?('duplicate id "ctl-region"'),
      'control id == its own controlId caught (shared namespace)', fails)

cross_ns = { 'pages' => [
  { 'name' => 'P1', 'elements' => [el('el-9', 'T')] },
  { 'name' => 'P2', 'elements' => [
    { 'id' => 'el-ctl-x', 'kind' => 'control', 'controlId' => 'el-9', 'name' => 'X' }
  ] }
] }
out, code = validate(cross_ns)
check(code == 1 && out.include?('duplicate id "el-9"'),
      'controlId colliding with another element id caught across pages', fails)

clean = { 'pages' => [
  { 'name' => 'P1', 'elements' => [el('a', 'A'), { 'id' => 'el-ctl-r', 'kind' => 'control', 'controlId' => 'ctl-r', 'name' => 'R' }] },
  { 'name' => 'P2', 'elements' => [el('b', 'B')] }
] }
out, code = validate(clean)
check(code == 0, "unique ids exit 0 (got #{code}: #{out.lines.grep(/ERROR/).join.strip})", fails)

puts
puts 'Part B — case-variant function names are ERRORS (the live-leak class)'
spec = { 'pages' => [{ 'name' => 'P1', 'elements' => [el('t1', 'T', formula: 'round([Sales], 2)')] }] }
spec['pages'][0]['elements'][0]['columns'] << { 'id' => 'c-sib', 'name' => 'Sales', 'formula' => nil }
out, code = validate(spec)
check(code == 1, "lowercase round( exits 1 (got #{code})", fails)
check(out.include?('case-variant') && out.include?('"Round"'), 'error names the correct casing', fails)
check(out.include?('NORMALIZE:') && out =~ /"round" -> "Round"/, 'NORMALIZE report lists the would-be rewrite', fails)

puts
puts 'Part C — genuinely unknown functions are WARN, not error'
spec = { 'pages' => [{ 'name' => 'P1', 'elements' => [el('t1', 'T', formula: 'FluxCapacitor([Sales])')] }] }
spec['pages'][0]['elements'][0]['columns'] << { 'id' => 'c-sib', 'name' => 'Sales', 'formula' => nil }
out, code = validate(spec)
check(code == 0, "unknown function exits 0 (WARN only — list can't be exhaustive; got #{code}: #{out.lines.grep(/ERROR/).join.strip})", fails)
check(out.include?('not a known Sigma function — Sigma is case-sensitive; check refs'),
      'WARN carries the contract wording', fails)
check(out =~ /WARN: .*FluxCapacitor/, 'WARN names the function', fails)
check(out.include?('--- 1 warnings (non-fatal)'), 'warning count summarized', fails)

puts
puts 'Part D — refs-documented spellings beyond sigma_functions.rb'
# Ltrim/Rtrim (the converter's spellings) stay accepted via EXTRA_FUNCTIONS.
spec = { 'pages' => [{ 'name' => 'P1', 'elements' => [el('t1', 'T', formula: 'Ltrim(Rtrim([Order Date]))')] }] }
spec['pages'][0]['elements'][0]['columns'] << { 'id' => 'c-sib', 'name' => 'Order Date', 'formula' => nil }
out, code = validate(spec)
check(code == 0 && !out.include?('WARN:'), "Ltrim/Rtrim accepted, no warn (got #{code})", fails)
# Week/Datetime were dropped from EXTRA_FUNCTIONS (2026-07-25): neither exists
# in Sigma (live probe "Unknown function: Week"; both absent from the function
# index) — the stale blessing defeated this validator. They must now surface
# as unknown-function WARNs, no longer sail through clean.
spec = { 'pages' => [{ 'name' => 'P1', 'elements' => [el('t1', 'T', formula: 'Week([Order Date]) + Datetime([Order Date])')] }] }
spec['pages'][0]['elements'][0]['columns'] << { 'id' => 'c-sib', 'name' => 'Order Date', 'formula' => nil }
out, code = validate(spec)
check(code == 0 && out =~ /WARN: .*Week/ && out =~ /WARN: .*Datetime/,
      "Week/Datetime no longer blessed — flagged as unknown functions (got #{code})", fails)

puts
puts 'Part E — Tableau leaks stay hard ERRORS (unchanged behavior)'
spec = { 'pages' => [{ 'name' => 'P1', 'elements' => [el('t1', 'T', formula: 'IIF(IsIn([Sales]), 1, 0)')] }] }
spec['pages'][0]['elements'][0]['columns'] << { 'id' => 'c-sib', 'name' => 'Sales', 'formula' => nil }
out, code = validate(spec)
check(code == 1, 'IIF/IsIn still exit 1', fails)
check(out.include?('IIF(c, t, e)') && out.include?('IsIn()'), 'leak hints still emitted', fails)

puts
puts 'Part F — envelope checks (schemaVersion/name/page id/source.kind) fail locally, not at POST'
bare = { 'pages' => [{ 'name' => 'P1', 'elements' => [
  { 'id' => 'e1', 'kind' => 'table', 'name' => 'T',
    'source' => { 'kind' => 'table', 'dataModelId' => 'dm-123', 'elementId' => 'x' } }
] }] }
out, code = validate(bare, envelope: false)
check(code == 1, "bare spec exits 1 (got #{code})", fails)
check(out.include?('schemaVersion'), 'names the missing schemaVersion', fails)
check(out =~ /pages\[0\] has no "id"/, 'names the missing page id', fails)
check(out.include?('needs source.kind "data-model"'), 'catches table-kind-with-dataModelId misbinding', fails)

puts
puts 'Part G — --dm-context with null element names must NOT false-abort (reused-DM handoff bug)'
def validate_dm_ctx(wb, ctx)
  wb = WorkbookCode.canonicalize(wb)
  wf = Tempfile.new(['g-wb-', '.json']);  wf.write(JSON.generate(wb));   wf.close
  cf = Tempfile.new(['g-ctx-', '.json']); cf.write(JSON.generate(ctx)); cf.close
  out, err, st = Open3.capture3('ruby', VALIDATE, '--type', 'workbook', '--dm-context', cf.path, wf.path)
  wf.unlink; cf.unlink
  [out + err, st.exitstatus]
end
# A DM-sourced master whose refs use the SQL element's own [Custom SQL/COL] prefix.
wb = { 'schemaVersion' => 1, 'name' => 'g', 'folderId' => 'f',
       'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
         { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
           'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm-x', 'elementId' => 'J9ADKnuzjR' },
           'columns' => [{ 'id' => 'c1', 'name' => 'N', 'formula' => '[Custom SQL/N]' }] }] }] }
# (G1) elements present but every name == null → WARN + continue (exit 0), the field fix.
out, code = validate_dm_ctx(wb, { 'dataModelId' => 'dm-x',
  'pages' => [{ 'id' => 'dp', 'elements' => [{ 'id' => 'J9ADKnuzjR', 'kind' => 'table', 'name' => nil }] }] })
check(code == 0, "null-name DM element does NOT false-abort (got #{code}: #{out.lines.grep(/ERROR|0 element names/).join.strip})", fails)
check(out.include?('all names were null'), 'emits the null-name WARN (does not silently pass)', fails)
# (G2) genuinely EMPTY context (zero elements) → still the loud abort.
out2, code2 = validate_dm_ctx(wb, { 'dataModelId' => 'dm-x', 'pages' => [{ 'id' => 'dp', 'elements' => [] }] })
check(code2 != 0 && out2.include?('loaded 0 element names'), 'empty dm-context (0 elements) still aborts loudly', fails)

puts 'Part H — Tableau date/text function leaks are HARD errors (non-dismissible), not WARNs'
# Field-caught (2 runs): CurrentDate()/STR() fell to the dismissible WARN tier;
# one run waved off the CurrentDate warning as a false "whitelist gap", shipping
# 52 type=error columns. They must be tableau_leaks (exit 1) naming the fix.
out, code = validate({ 'pages' => [{ 'elements' => [el('t1', 'T', formula: 'STR([Val])') ] }] })
check(code == 1, "STR( → hard error, exit 1 (got #{code})", fails)
check(out.include?('STR(x) → Sigma Text(x)'), 'STR error names the Sigma Text() fix', fails)
out, code = validate({ 'pages' => [{ 'elements' => [el('t1', 'T', formula: 'CurrentDate()') ] }] })
check(code == 1, "CurrentDate( → hard error, exit 1 (got #{code})", fails)
check(out.include?('Today()'), 'CurrentDate error names the Sigma Today() fix', fails)
# negative: Substring (contains "str") and a clean Today() must NOT be flagged
out, _ = validate({ 'pages' => [{ 'elements' => [el('t1', 'T', formula: 'Substring([Val], 1, 2)') ] }] })
check(!out.include?('→ Sigma Text'), 'Substring (contains "str") is NOT flagged as an STR leak', fails)

puts
puts 'Part I — workbook-local join/union operator prefixes are valid'
relational = {
  'pages' => [{
    'name' => 'Data',
    'elements' => [
      { 'id' => 'left', 'kind' => 'table', 'name' => 'Left', 'columns' => [] },
      { 'id' => 'right', 'kind' => 'table', 'name' => 'Right', 'columns' => [] },
      {
        'id' => 'joined', 'kind' => 'table', 'name' => 'Joined',
        'source' => {
          'kind' => 'join', 'name' => 'ForecastJoin',
          'primarySource' => { 'kind' => 'table', 'elementId' => 'left' },
          'joins' => [{
            'name' => 'Rates', 'joinType' => 'left-outer',
            'left' => { 'kind' => 'table', 'elementId' => 'left' },
            'right' => { 'kind' => 'table', 'elementId' => 'right' },
            'columns' => [{ 'left' => '[Val]', 'right' => '[Val]' }]
          }]
        },
        'columns' => [
          { 'id' => 'j1', 'name' => 'Primary Val', 'formula' => '[ForecastJoin/Val]' },
          { 'id' => 'j2', 'name' => 'Rate', 'formula' => '[Rates/Val]' }
        ]
      },
      {
        'id' => 'unioned', 'kind' => 'table', 'name' => 'Unioned',
        'source' => {
          'kind' => 'union',
          'sources' => [
            { 'kind' => 'table', 'elementId' => 'left' },
            { 'kind' => 'table', 'elementId' => 'right' }
          ],
          'matches' => [{ 'outputColumnName' => 'Val', 'sourceColumns' => ['[Val]', '[Val]'] }]
        },
        'columns' => [
          { 'id' => 'u1', 'name' => 'Val', 'formula' => '[Union of 2 Sources/Val]' }
        ]
      }
    ]
  }]
}
out, code = validate(relational)
check(code == 0, "join aliases + union namespace validate (got #{code}: #{out.lines.grep(/ERROR/).join.strip})", fails)

if fails.empty?
  puts 'OK — validate-spec ID-uniqueness + function-tier + tableau-leak + envelope + null-name guards all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
