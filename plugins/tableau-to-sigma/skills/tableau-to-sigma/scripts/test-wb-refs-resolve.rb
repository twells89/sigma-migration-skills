#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for assert-wb-refs-resolve.rb (Tier 1 #2). Drives the gate as a
# subprocess against fixture wb-spec + dm-ids files. The a real multi-datasource workbook
# (2026-07-08): a multi-datasource collapse left workbook [Master/...] refs
# pointing at columns absent from the live DM; this gate must catch them BEFORE
# the POST that would otherwise return an opaque "Dependency not found".
require 'json'
require 'tmpdir'

GATE = File.join(__dir__, 'assert-wb-refs-resolve.rb')
FAILS = []
def check(cond, msg)
  puts((cond ? '  ok  ' : '  FAIL ') + msg)
  FAILS << msg unless cond
end

def run_gate(spec, dmids, *extra)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'wb.json'), JSON.generate(spec))
    File.write(File.join(d, 'dm.json'), JSON.generate(dmids))
    out = IO.popen(['ruby', GATE, '--wb-spec', "#{d}/wb.json", '--dm-ids', "#{d}/dm.json", *extra],
                   err: %i[child out], &:read)
    [$?.exitstatus, out]
  end
end

DM = { 'dataModelId' => 'dm1', 'pages' => [{ 'elements' => [
  { 'id' => 'e1', 'name' => 'Master',
    'columnLabels' => ['Net Revenue', 'Region', 'Customer Id (CUSTOMER_DIM)'],
    'metrics' => [{ 'id' => 'metric-gross-margin', 'name' => 'Gross Margin Pct' }] }
] }] }

# all refs resolve (incl. suffix-normalized "Customer Id")
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => 'Sum([Master/Net Revenue])' },
  { 'formula' => '[Master/Customer Id]' }
] }] }] }, DM)
check(rc == 0, 'all-resolving spec passes (exit 0), suffix-normalized match works')

# [Metrics/name] is a literal namespace. It resolves ONLY against the DM
# metrics census from the full spec/readback, never against columnLabels.
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => '[Metrics/Gross Margin Pct]' }
] }] }] }, DM)
check(rc == 0, 'metric-only DM name resolves through the metrics census')

rc, out = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => '[Metrics/Net Revenue]' }
] }] }] }, DM)
check(rc == 1, '[Metrics/name] does not resolve through a same-named DM column')
check(out.include?('not in the DM metrics census'), 'column-only metric miss names the metrics census')

rc, out = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => '[Metrics/Ghost Rate]' }
] }] }] }, DM)
check(rc == 1 && out.include?('Ghost Rate'), 'genuinely absent metric fails closed')

dm_without_metrics = Marshal.load(Marshal.dump(DM))
dm_without_metrics['pages'][0]['elements'][0].delete('metrics')
rc, out = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => '[Metrics/Gross Margin Pct]' }
] }] }] }, dm_without_metrics)
check(rc == 1, 'missing metric census fails closed')
check(out.include?('no DM metrics census'), 'missing census failure is explicit')

# dropped columns (multi-DS collapse) → fail with exit 1
rc, out = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => 'Sum([Master/Net Revenue])' },
  { 'formula' => '[Master/Partner Name]' },
  { 'formula' => '[SKU Master/Product Code]' }
] }] }] }, DM)
check(rc == 1, 'dropped-column refs fail (exit 1)')
check(out.include?('Partner Name') && out.include?('Product Code'), 'names the unresolved columns')
check(out.downcase.include?('multi-datasource'), 'points at the multi-datasource cause')

# 3-part relationship ref [Element/RelName/Field] resolves on the FINAL segment
# (surfaced FIXED-LOD column). The relationship name in the middle is NOT a column.
DM_WORLD = { 'dataModelId' => 'dm1', 'pages' => [{ 'elements' => [
  { 'id' => 'e1', 'name' => 'Master', 'columnLabels' => ['Net Revenue', 'Revenue World'] }
] }] }
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => '[Metric Series/FIXED Year/Revenue World]' }
] }] }] }, DM_WORLD)
check(rc == 0, '3-part FIXED-relationship ref resolves on its final column segment (exit 0)')
# but a 3-part ref whose FINAL segment is missing still fails
rc, out = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => '[Metric Series/FIXED Year/Nonexistent World]' }
] }] }] }, DM_WORLD)
check(rc == 1 && out.include?('Nonexistent World'), '3-part ref with a missing final column still fails (exit 1)')

# empty DM → fail
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [{ 'formula' => '[Master/X]' }] }] }] },
               { 'pages' => [{ 'elements' => [{ 'name' => 'Master', 'columnLabels' => [] }] }] })
check(rc == 1, 'empty DM fails (exit 1)')

# waiver → skip (exit 0)
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [{ 'formula' => '[Master/Partner Name]' }] }] }] },
               DM, '--skip-ref-check', 'known, building manually')
check(rc == 0, '--skip-ref-check waives (exit 0)')

# PR-14: a waiver with --workdir writes a skip-flag-waived off-ramp record —
# the "GREEN, 0 waivers after --skip-ref-check" escape is closed: the skip is
# visible to the degradation ledger and verify-complete's cross-check.
Dir.mktmpdir do |wd|
  rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [{ 'formula' => '[Master/Partner Name]' }] }] }] },
                 DM, '--workdir', wd, '--skip-ref-check', 'known, building manually')
  check(rc == 0, '--skip-ref-check + --workdir still waives (exit 0)')
  recs = File.readlines(File.join(wd, 'offramps.jsonl')).map { |l| JSON.parse(l) }
  rec = recs.find { |r| r['kind'] == 'skip-flag-waived' && r['detail'] == '--skip-ref-check' }
  check(!rec.nil? && rec['reason'].include?('known'),
        'waived run records skip-flag-waived (--skip-ref-check) with its reason in offramps.jsonl')
end
# without --workdir the waiver still works but WARNS it went unrecorded
rc, out = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [{ 'formula' => '[Master/Partner Name]' }] }] }] },
                   DM, '--skip-ref-check', 'reason')
check(rc == 0 && out.include?('NOT recorded'), 'waiver without --workdir warns the skip went unrecorded')

# ---- merged capabilities (from the deleted assert-refs-resolve.rb) ----------

# INTERNAL master ref: a master-level calc column absent from the DM by design
# resolves against the workbook element's OWN columns (no false positive).
def master_el(*extra_cols)
  { 'id' => 'el-master', 'name' => 'Master', 'kind' => 'table',
    'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm1', 'elementId' => 'e1' },
    'columns' => [{ 'name' => 'Net Revenue', 'formula' => '[Master DM/Net Revenue]' }] + extra_cols }
end
rc, = run_gate({ 'pages' => [{ 'elements' => [
  master_el({ 'name' => 'Margin Pct', 'formula' => '[Master/Net Revenue] / 100' }),
  { 'id' => 'el-kpi', 'kind' => 'kpi-chart',
    'source' => { 'kind' => 'table', 'elementId' => 'el-master' },
    'columns' => [{ 'name' => 'KPI', 'formula' => 'Sum([Master/Margin Pct])' }] }
] }] }, DM)
check(rc == 0, 'internal master-calc ref (column not in the DM) resolves against the spec element')

# Workbook-local relational operators are namespaces owned by the element's
# source, not data-model elements. Live readback uses these exact prefixes.
relational_spec = { 'pages' => [{ 'elements' => [
  { 'id' => 'left', 'name' => 'Left', 'kind' => 'table', 'columns' => [] },
  { 'id' => 'right', 'name' => 'Right', 'kind' => 'table', 'columns' => [] },
  { 'id' => 'joined', 'name' => 'Forecast', 'kind' => 'table',
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
      { 'name' => 'Val', 'formula' => '[ForecastJoin/Val]' },
      { 'name' => 'Rate', 'formula' => '[Rates/Rate]' }
    ] },
  { 'id' => 'unioned', 'name' => 'Combined', 'kind' => 'table',
    'source' => {
      'kind' => 'union',
      'sources' => [
        { 'kind' => 'table', 'elementId' => 'left' },
        { 'kind' => 'table', 'elementId' => 'right' }
      ],
      'matches' => [{ 'outputColumnName' => 'Val', 'sourceColumns' => ['[Val]', '[Val]'] }]
    },
    'columns' => [{ 'name' => 'Val', 'formula' => '[Union of 2 Sources/Val]' }] }
] }] }
rc, = run_gate(relational_spec, DM)
check(rc == 0, 'workbook-local join aliases and union namespaces pass the ref gate')

# internal prefix without the column falls back to the GLOBAL DM check
# (renamed-element tolerance — upstream semantics keep the final say).
rc, = run_gate({ 'pages' => [{ 'elements' => [
  master_el,
  { 'id' => 'el-kpi', 'kind' => 'kpi-chart', 'columns' => [{ 'formula' => 'Sum([Master/Region])' }] }
] }] }, DM)
check(rc == 0, 'internal prefix missing the column still resolves via the global DM check')

# forward-document-order: the prefix BINDS to the spec element, so a ref to an
# element defined LATER fails even though the DM carries a same-named column.
rc, out = run_gate({ 'pages' => [
  { 'elements' => [{ 'id' => 'el-kpi', 'kind' => 'kpi-chart',
                     'columns' => [{ 'formula' => 'Sum([Master/Net Revenue])' }] }] },
  { 'elements' => [master_el] }
] }, DM)
check(rc == 1, 'ref to a workbook element defined LATER fails (exit 1)')
check(out.include?('forward-in-document-order'), 'order violation names the forward-only rule')

# dangling source elementId → structural failure
rc, out = run_gate({ 'pages' => [{ 'elements' => [
  { 'id' => 'el-kpi', 'kind' => 'kpi-chart',
    'source' => { 'kind' => 'table', 'elementId' => 'no-such-element' },
    'columns' => [{ 'formula' => 'Sum([Master/Net Revenue])' }] }
] }] }, DM)
check(rc == 1, 'dangling source elementId fails (exit 1)')
check(out.include?('no-such-element'), 'dangling source id named in the report')

# stale data-model source: source elementId absent from the dm-ids readback
rc, out = run_gate({ 'pages' => [{ 'elements' => [
  { 'id' => 'el-master', 'name' => 'Master', 'kind' => 'table',
    'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm1', 'elementId' => 'e-stale' },
    'columns' => [{ 'name' => 'Net Revenue', 'formula' => '[Master DM/Net Revenue]' }] }
] }] }, DM)
check(rc == 1, 'data-model source elementId absent from dm-ids fails (stale readback)')
check(out.include?('e-stale'), 'stale DM source elementId named in the report')

# flat {elements:[...]} dm-ids shape accepted
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => 'Sum([Master/Net Revenue])' }
] }] }] }, { 'dataModelId' => 'dm1', 'elements' => DM['pages'][0]['elements'] })
check(rc == 0, 'flat {elements:[...]} dm-ids shape accepted')

# bare / control refs carry no slash — validator territory, never flagged here
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => 'Switch([ctl-param-metric], "1", [Total Sales], Sum([Master/Net Revenue]))' }
] }] }] }, DM)
check(rc == 0, 'bare [ctl-*] and sibling refs are ignored (validate-spec.rb owns those)')

# ---- slash-in-column-name (wave-2 §6.2: two-segment escape) -----------------
# A COLUMN whose display name itself contains '/' ("Margin Pct H/L",
# "Date (Month /Year)") used to be unconditionally split — the ref resolved as
# its final fragment ("L" / "Year)"): a false FAIL, or a false PASS when a real
# same-named column existed. The escape ported from mechanical-specs.rb's
# derived-rel checker resolves the WHOLE slashed tail first.
DM_SLASH = { 'dataModelId' => 'dm1', 'pages' => [{ 'elements' => [
  { 'id' => 'e1', 'name' => 'Master',
    'columnLabels' => ['Net Revenue', 'Margin Pct H/L', 'Date (Month /Year)'] }
] }] }
# false-FAIL direction: the slash-named DM column resolves as-is now
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => 'Sum([Master/Margin Pct H/L])' },
  { 'formula' => '[Master/Date (Month /Year)]' }
] }] }] }, DM_SLASH)
check(rc == 0, 'slash-named DM columns resolve whole ("Margin Pct H/L", "Date (Month /Year)") — no false FAIL')
# a slash-named column that is genuinely MISSING (and whose fragment resolves
# nowhere either) still fails — the escape never widens what passes
rc, out = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => '[Master/Margin Pct A/B]' }
] }] }] }, DM_SLASH)
check(rc == 1, 'missing slash-named column still fails (exit 1)')
# internal binding: a workbook element's OWN slash-named calc column (absent
# from the DM by design) resolves via the element's own column set
rc, = run_gate({ 'pages' => [{ 'elements' => [
  master_el({ 'name' => 'Margin H/L', 'formula' => '[Master/Net Revenue] / 100' }),
  { 'id' => 'el-kpi', 'kind' => 'kpi-chart',
    'source' => { 'kind' => 'table', 'elementId' => 'el-master' },
    'columns' => [{ 'name' => 'KPI', 'formula' => 'Sum([Master/Margin H/L])' }] }
] }] }, DM)
check(rc == 0, 'internal slash-named calc column resolves against the spec element (two-segment escape)')
# regression: the escape must NOT break 3-part relationship-path resolution
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => '[Metric Series/FIXED Year/Revenue World]' }
] }] }] }, DM_WORLD)
check(rc == 0, '3-part relationship refs still resolve on the final segment after the escape')

puts(FAILS.empty? ? "\nall wb-refs-resolve tests passed" : "\n#{FAILS.length} FAILED")
exit(FAILS.empty? ? 0 : 1)
