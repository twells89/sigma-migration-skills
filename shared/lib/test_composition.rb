# frozen_string_literal: true
# test_composition.rb — run directly: ruby shared/lib/test_composition.rb
require 'json'
require_relative 'composition'
$failures = 0
def check(desc); ok = yield; puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}"); $failures += 1 unless ok; end

golden = File.read(File.join(__dir__, 'testdata', 'composition_exec_golden.txt')).strip
els = [
  { id: 'kpi1', role: :kpi }, { id: 'kpi2', role: :kpi },
  { id: 'kpi3', role: :kpi }, { id: 'kpi4', role: :kpi },
  { id: 'hero', role: :hero }, { id: 'tbl', role: :table }
]
check('exec layout matches golden') { Composition.compose(els, pattern: :exec).strip == golden }
check('kpi band widths sum to 24 (4 KPIs -> 6 each)') do
  Composition.compose(els, pattern: :exec).include?('gridColumn="1 / 7"') &&
    Composition.compose(els, pattern: :exec).include?('gridColumn="19 / 25"')
end
check('raises when a band is not evenly divisible (5 KPIs into 24)') do
  bad = (1..5).map { |i| { id: "k#{i}", role: :kpi } }
  begin; Composition.compose(bad, pattern: :exec); false
  rescue ArgumentError; true; end
end
check('infer_role: kpi-chart -> :kpi, table -> :table, bar-chart -> :supporting') do
  Composition.infer_role('kpi-chart') == :kpi && Composition.infer_role('table') == :table &&
    Composition.infer_role('bar-chart') == :supporting
end
check('unknown pattern raises') do
  begin; Composition.compose(els, pattern: :nope); false; rescue ArgumentError; true; end
end
check('empty-string role resolves via inference (no drop)') do
  out = Composition.compose([{ id: 'k1', role: '', kind: 'kpi-chart' }], pattern: :exec)
  out.include?('elementId="k1"') && out.include?('gridColumn="1 / 25"')
end
check('unrecognized explicit role raises') do
  begin
    Composition.compose([{ id: 'bad1', role: :chart }], pattern: :exec)
    false
  rescue ArgumentError => e
    e.message == 'compose: unknown role chart for element bad1'
  end
end

md_golden = File.read(File.join(__dir__, 'testdata', 'composition_master_detail_golden.txt')).strip
md_els = [
  { id: 'ctl', role: :control },
  { id: 'master-chart', role: :master, kind: 'bar-chart' },
  { id: 'detail-tbl', role: :detail, kind: 'table' }
]
check('master_detail: master 1/13 and detail 13/25 share a gridRow, matches golden') do
  out = Composition.compose(md_els, pattern: :master_detail)
  out.strip == md_golden &&
    out.include?('elementId="master-chart" gridColumn="1 / 13" gridRow="3 / 17"') &&
    out.include?('elementId="detail-tbl" gridColumn="13 / 25" gridRow="3 / 17"')
end
check('master_detail: control row is optional (master/detail band starts at row 1 without it)') do
  out = Composition.compose([{ id: 'm', role: :master }, { id: 'd', role: :detail }], pattern: :master_detail)
  out.include?('elementId="m" gridColumn="1 / 13" gridRow="1 / 15"') &&
    out.include?('elementId="d" gridColumn="13 / 25" gridRow="1 / 15"')
end
check('regression: :exec output unchanged after adding :master_detail') do
  Composition.compose(els, pattern: :exec).strip == golden
end

# I3 (root fix): a role a pattern doesn't consume must RAISE, never silently
# vanish from the emitted layout.
check(':master passed to :exec raises') do
  begin
    Composition.compose([{ id: 'm1', role: :master }], pattern: :exec)
    false
  rescue ArgumentError => e
    e.message == 'compose: role master (element m1) is not used by pattern exec'
  end
end
check(':kpi passed to :master_detail raises') do
  begin
    Composition.compose([{ id: 'k1', role: :kpi }], pattern: :master_detail)
    false
  rescue ArgumentError => e
    e.message == 'compose: role kpi (element k1) is not used by pattern master_detail'
  end
end
check('regression: normal :exec call with control/kpi/hero/supporting/table still succeeds') do
  out = Composition.compose([
    { id: 'ctl', role: :control }, { id: 'k1', role: :kpi }, { id: 'hero1', role: :hero },
    { id: 'sup1', role: :supporting }, { id: 'tbl1', role: :table }
  ], pattern: :exec)
  %w[ctl k1 hero1 sup1 tbl1].all? { |id| out.include?("elementId=\"#{id}\"") }
end

# :overview — optional stack of bands: header -> control -> kpi -> kpi2 ->
# trend -> pivot -> base, each skipped if empty, even-split within a band.
overview_golden = File.read(File.join(__dir__, 'testdata', 'composition_overview_golden.txt')).strip
overview_els = [
  { id: 'hdr', role: :header },
  { id: 'ctl', role: :control },
  { id: 'kpi1', role: :kpi }, { id: 'kpi2', role: :kpi },
  { id: 'rate1', role: :kpi2 }, { id: 'rate2', role: :kpi2 },
  { id: 'trend1', role: :trend },
  { id: 'pivot1', role: :pivot },
  { id: 'base1', role: :base }, { id: 'base2', role: :base }, { id: 'base3', role: :base }
]
check('overview: bands() returns expected [{role,ids,r0,r1}] stack for a partial set') do
  stack = Composition.bands(
    [{ id: 'h', role: :header }, { id: 'k', role: :kpi }, { id: 'tr', role: :trend }, { id: 'pv', role: :pivot }],
    :overview
  )
  stack == [
    { role: :header, ids: ['h'], r0: 1, r1: 4 },
    { role: :kpi, ids: ['k'], r0: 4, r1: 12 },
    { role: :trend, ids: ['tr'], r0: 12, r1: 24 },
    { role: :pivot, ids: ['pv'], r0: 24, r1: 38 }
  ]
end
check('overview: full-stack compose(pattern: :overview) matches golden') do
  Composition.compose(overview_els, pattern: :overview).strip == overview_golden
end
check('overview: unused bands are skipped, not emitted empty') do
  out = Composition.compose([{ id: 'tr', role: :trend }], pattern: :overview)
  out.strip == '<LayoutElement elementId="tr" gridColumn="1 / 25" gridRow="1 / 13"/>'
end
check(':master passed to :overview raises (role not consumed by pattern)') do
  begin
    Composition.compose([{ id: 'm1', role: :master }], pattern: :overview)
    false
  rescue ArgumentError => e
    e.message == 'compose: role master (element m1) is not used by pattern overview'
  end
end
check(':header passed to :exec raises (overview role not consumed by exec)') do
  begin
    Composition.compose([{ id: 'h1', role: :header }], pattern: :exec)
    false
  rescue ArgumentError => e
    e.message == 'compose: role header (element h1) is not used by pattern exec'
  end
end
check('regression: :exec golden still matches after adding :overview') do
  Composition.compose(els, pattern: :exec).strip == golden
end
check('regression: :master_detail golden still matches after adding :overview') do
  Composition.compose(md_els, pattern: :master_detail).strip == md_golden
end

# tabbed_container — labels-only element; <Tab> children map to tabs[] by
# position; bare <LayoutElement> children only inside a <Tab> (a nested
# GridContainer scrambles tab render order).
tabbed_golden = JSON.parse(File.read(File.join(__dir__, 'testdata', 'composition_tabbed_golden.txt')))
tabbed_tabs = [
  { name: 'Overview', inner: Composition.le('a1', 1, 25, 1, 7) },
  { name: 'Details', inner: Composition.le('b1', 1, 25, 1, 7) }
]
check('tabbed_container: element + layout match golden') do
  out = Composition.tabbed_container(id: 'tc', tabs: tabbed_tabs, grid_column: '1 / 25', grid_row: '7 / 60')
  out[:element] == tabbed_golden['element'] && out[:layout] == tabbed_golden['layout']
end
check('tabbed_container: element tabs are labels-only, in order, with tabBar.alignment') do
  out = Composition.tabbed_container(id: 'tc', tabs: tabbed_tabs, grid_column: '1 / 25', grid_row: '7 / 60')
  out[:element]['tabs'] == [{ 'name' => 'Overview' }, { 'name' => 'Details' }] &&
    out[:element]['tabBar'] == { 'alignment' => 'start' }
end
check('tabbed_container: layout has exactly 2 ordered <Tab> blocks, each wrapping its inner') do
  out = Composition.tabbed_container(id: 'tc', tabs: tabbed_tabs, grid_column: '1 / 25', grid_row: '7 / 60')
  out[:layout].scan('<Tab ').size == 2 &&
    out[:layout].index('elementId="a1"') < out[:layout].index('elementId="b1"') &&
    out[:layout].start_with?(
      '<TabbedContainer elementId="tc" type="tabbed-container" gridColumn="1 / 25" gridRow="7 / 60">'
    ) &&
    out[:layout].end_with?('</TabbedContainer>')
end
check('tabbed_container: empty id raises ArgumentError') do
  begin
    Composition.tabbed_container(id: '', tabs: tabbed_tabs, grid_column: '1 / 25', grid_row: '7 / 60')
    false
  rescue ArgumentError
    true
  end
end
check('tabbed_container: empty tabs raises ArgumentError') do
  begin
    Composition.tabbed_container(id: 'tc', tabs: [], grid_column: '1 / 25', grid_row: '7 / 60')
    false
  rescue ArgumentError
    true
  end
end
check('tabbed_container: a tab missing a name raises ArgumentError') do
  begin
    Composition.tabbed_container(id: 'tc', tabs: [{ name: '', inner: 'x' }], grid_column: '1 / 25', grid_row: '7 / 60')
    false
  rescue ArgumentError
    true
  end
end
check('tabbed_container: a tab with a missing (nil) name raises ArgumentError') do
  begin
    Composition.tabbed_container(id: 'tc', tabs: [{ inner: 'x' }], grid_column: '1 / 25', grid_row: '7 / 60')
    false
  rescue ArgumentError
    true
  end
end

exit($failures.zero? ? 0 : 1)
