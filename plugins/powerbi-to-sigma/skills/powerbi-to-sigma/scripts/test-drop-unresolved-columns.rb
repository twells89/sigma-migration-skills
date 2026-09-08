#!/usr/bin/env ruby
# frozen_string_literal: true
# test-drop-unresolved-columns.rb — end-to-end offline test for bead miu7. Runs
# build-workbook-from-pbir.rb (NO API, NO creds — it only reads/writes files) on
# crafted signals + master-map containing unresolvable queryRefs in every role,
# and asserts the built spec ships NO type=error literal column and leaves NO
# dangling id reference, while coverage.json records each drop honestly.
require 'json'
require 'tmpdir'
require 'rbconfig'

BUILD = File.join(__dir__, 'build-workbook-from-pbir.rb')
RUBY  = RbConfig.ruby
$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

MMAP = {
  'masters' => {
    'EMPLOYEES' => { 'id' => 'master-emp', 'element_id' => 'el-emp', 'data_model' => 'dm-x',
      'columns' => [
        { 'id' => 'mc-dept', 'name' => 'Department', 'formula' => '[EMPLOYEES/Department]' },
        { 'id' => 'mc-hc',   'name' => 'Headcount',  'formula' => '[EMPLOYEES/Headcount]' },
      ] },
  },
  'fields' => {
    'EMPLOYEES.Department' => { 'master' => 'EMPLOYEES', 'ref' => '[master-emp/Department]', 'agg' => nil },
    'EMPLOYEES.Headcount'  => { 'master' => 'EMPLOYEES', 'ref' => 'CountDistinct([master-emp/Headcount])', 'agg' => nil },
  },
}.freeze

# Each visual binds at least one GHOST (absent from the master-map) queryRef in a
# different role, plus a real field so the tile still has something.
def vis(id, type, kind, bindings)
  { 'visual_id' => id, 'visual_type' => type, 'sigma_kind' => kind, 'title' => "#{kind} #{id}",
    'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0, 'parent_group' => nil,
    'bindings' => bindings, 'sort' => nil, 'formats' => {} }
end

SIGNALS = {
  'source' => 'powerbi', 'pbir_dir' => '/tmp/none',
  'pages' => [{ 'page_id' => 'p1', 'page_title' => 'P1', 'page_w' => 1280, 'page_h' => 720,
    'interactions' => [], 'visuals' => [
      vis('v_bar_x',  'barChart', 'bar',   { 'Category' => ['EMPLOYEES.GhostDim'], 'Y' => ['EMPLOYEES.Headcount'] }),
      vis('v_bar_y',  'barChart', 'bar',   { 'Category' => ['EMPLOYEES.Department'], 'Y' => ['EMPLOYEES.Headcount', 'EMPLOYEES.GhostY'] }),
      vis('v_kpi',    'card',     'kpi',   { 'Values' => ['EMPLOYEES.GhostKpi'] }),
      vis('v_table',  'tableEx',  'table', { 'Values' => ['EMPLOYEES.Department', 'EMPLOYEES.Headcount', 'EMPLOYEES.GhostCol'] }),
      vis('v_pivot',  'pivotTable', 'pivot-table', { 'Rows' => ['EMPLOYEES.Department'], 'Values' => ['EMPLOYEES.Headcount', 'EMPLOYEES.GhostVal'] }),
      vis('v_clean',  'tableEx',  'table', { 'Values' => ['EMPLOYEES.Department', 'EMPLOYEES.Headcount'] }),
    ] }],
}.freeze

# every column-id a Sigma element references must resolve to a real column on it.
def dangling_ids(el)
  own = (el['columns'] || []).map { |c| c['id'] }
  refs = []
  refs << el.dig('value', 'columnId')
  refs << el.dig('xAxis', 'columnId')
  refs << el.dig('xAxis', 'sort', 'by')
  %w[yAxis yAxis2].each { |a| Array(el.dig(a, 'columnIds')).each { |x| refs << (x.is_a?(Hash) ? (x['columnId'] || x['id']) : x) } }
  Array(el['groupings']).each { |g| refs.concat(Array(g['groupBy'])); refs.concat(Array(g['calculations'])) }
  %w[rowsBy columnsBy].each { |k| Array(el[k]).each { |x| refs << (x.is_a?(Hash) ? (x['columnId'] || x['id']) : x) } }
  Array(el['values']).each { |x| refs << (x.is_a?(Hash) ? (x['columnId'] || x['id']) : x) }
  refs.compact.uniq.reject { |id| own.include?(id) }
end

Dir.mktmpdir do |d|
  File.write(File.join(d, 'mmap.json'), JSON.generate(MMAP))
  File.write(File.join(d, 'sig.json'), JSON.generate(SIGNALS))
  wb  = File.join(d, 'wb.json')
  cov = File.join(d, 'cov.json')
  st = system(RUBY, BUILD, '--signals', File.join(d, 'sig.json'), '--master-map', File.join(d, 'mmap.json'),
              '--data-model', 'dm-x', '--name', 'T', '--out', wb,
              '--layout-out', File.join(d, 'l.xml'), '--coverage-out', cov,
              out: File::NULL, err: File::NULL)
  ok('builder exits 0', st)
  spec = JSON.parse(File.read(wb))
  raw = File.read(wb)

  ok('NO dot-bracket literal ref anywhere in the spec', raw !~ %r{\[[^\]/"]*\.[^\]"]*\]})

  content_els = spec.dig('document', 'elements').reject { |e| e['visibleAsSource'] == false }
  bad_dangle = content_els.flat_map { |e| dangling_ids(e).map { |id| "#{e['id']}:#{id}" } }
  ok('NO dangling column-id reference in any element', bad_dangle.empty? || (puts("    dangling: #{bad_dangle.inspect}") && false))

  # the clean visual is untouched: still has both its columns.
  clean = content_els.find { |e| e['name'].to_s.include?('v_clean') }
  ok('clean visual keeps both resolvable columns', clean && (clean['columns'] || []).length == 2)

  # the surviving real fields are still present (we dropped only the ghosts).
  all_formulas = content_els.flat_map { |e| (e['columns'] || []).map { |c| c['formula'] } }
  ok('resolvable refs survive (Headcount measure present)',
     all_formulas.any? { |f| f.to_s.include?('master-emp/Headcount') })

  cover = JSON.parse(File.read(cov))['unresolved'] || []
  # the 4 visuals that keep a real field record the explicit miu7 "could not be
  # resolved" drop; the kpi whose ONLY field is a ghost is dropped by the
  # master-selection path ("element skipped") — also honest. All 5 ghost-bearing
  # visuals must surface a 'dropped' entry; the clean visual must not.
  miu7_drops = cover.count { |u| u['severity'] == 'dropped' && u['detail'].to_s =~ /could not be resolved/ }
  all_drops  = cover.count { |u| u['severity'] == 'dropped' }
  ok('>=4 visuals record the explicit miu7 column drop', miu7_drops >= 4)
  ok('all 5 ghost-bearing visuals surface a dropped entry', all_drops >= 5)
  # the drop record carries the source ENTITY (part before the dot in [Entity.Leaf])
  # so CoverageGate.classify_causes can attribute it to an ungranted schema.
  ok('miu7 drop records the source entity for cause attribution',
     cover.any? { |u| u['detail'].to_s =~ /could not be resolved/ && !u['entity'].to_s.strip.empty? })
end

puts $fail.zero? ? "\nall drop-unresolved-columns tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
