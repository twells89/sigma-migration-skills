# frozen_string_literal: true
# test_composition.rb — run directly: ruby scripts/lib/test_composition.rb (from sigma-workbooks/)
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

# Root fix: a role a pattern doesn't consume must RAISE, never silently
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
  out.strip == '<Element elementId="tr" gridColumn="1 / 25" gridRow="1 / 13"/>'
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

# Operational app compositions are deliberately asymmetric: the editable or
# review surface dominates its supporting context/rail.
workbench_els = [
  { id: 'title', role: :app_header },
  { id: 'controls', role: :action_bar },
  { id: 'context', role: :context },
  { id: 'grid', role: :work_surface },
  { id: 's1', role: :summary }, { id: 's2', role: :summary },
  { id: 'submit', role: :footer }
]
workbench_golden = File.read(
  File.join(__dir__, 'testdata', 'composition_workbench_golden.txt')
).strip
check('workbench: context 8/24 and work surface 16/24 match golden') do
  out = Composition.compose(workbench_els, pattern: :workbench)
  out.strip == workbench_golden &&
    out.include?('elementId="context" gridColumn="1 / 9"') &&
    out.include?('elementId="grid" gridColumn="9 / 25"')
end
check('workbench: work surface expands full-width without context') do
  out = Composition.compose([{ id: 'grid', role: :work_surface }], pattern: :workbench)
  out.strip == '<Element elementId="grid" gridColumn="1 / 25" gridRow="1 / 19"/>'
end

queue_rail_els = [
  { id: 'title', role: :app_header },
  { id: 'filters', role: :action_bar },
  { id: 'queue', role: :queue },
  { id: 'rail', role: :rail },
  { id: 'actions', role: :footer }
]
queue_rail_golden = File.read(
  File.join(__dir__, 'testdata', 'composition_queue_rail_golden.txt')
).strip
check('queue_rail: queue 17/24 and rail 7/24 match golden') do
  out = Composition.compose(queue_rail_els, pattern: :queue_rail)
  out.strip == queue_rail_golden &&
    out.include?('elementId="queue" gridColumn="1 / 18"') &&
    out.include?('elementId="rail" gridColumn="18 / 25"')
end
check('queue_rail: queue expands full-width without rail') do
  out = Composition.compose([{ id: 'queue', role: :queue }], pattern: :queue_rail)
  out.strip == '<Element elementId="queue" gridColumn="1 / 25" gridRow="1 / 23"/>'
end

builder_preview_els = [
  { id: 'title', role: :app_header },
  { id: 'actions', role: :action_bar },
  { id: 'builder', role: :builder },
  { id: 'preview', role: :preview },
  { id: 'impact', role: :summary },
  { id: 'save', role: :footer }
]
builder_preview_golden = File.read(
  File.join(__dir__, 'testdata', 'composition_builder_preview_golden.txt')
).strip
check('builder_preview: builder 7/24 and preview 17/24 match golden') do
  out = Composition.compose(builder_preview_els, pattern: :builder_preview)
  out.strip == builder_preview_golden &&
    out.include?('elementId="builder" gridColumn="1 / 8"') &&
    out.include?('elementId="preview" gridColumn="8 / 25"')
end
check('operational pattern rejects dashboard roles rather than dropping them') do
  begin
    Composition.compose([{ id: 'k1', role: :kpi }], pattern: :workbench)
    false
  rescue ArgumentError => e
    e.message == 'compose: role kpi (element k1) is not used by pattern workbench'
  end
end
check('weighted pair rejects two elements on one side') do
  begin
    Composition.compose(
      [{ id: 'c1', role: :context }, { id: 'c2', role: :context },
       { id: 'grid', role: :work_surface }],
      pattern: :workbench
    )
    false
  rescue ArgumentError => e
    e.message.include?('at most one element per side')
  end
end

# tabbed_container — labels-only element; <Tab> children map to tabs[] by
# position; bare <Element> children only inside a <Tab> (a nested
# Container scrambles tab render order).
require 'json'
tabbed_golden = JSON.parse(File.read(File.join(__dir__, 'testdata', 'composition_tabbed_golden.json')))
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
    out[:element]['tabBar'] == { 'alignment' => 'left' }
end
check('tabbed_container: non-default tab_bar_alignment is honored (not hardcoded to start)') do
  out = Composition.tabbed_container(
    id: 'tc', tabs: tabbed_tabs, grid_column: '1 / 25', grid_row: '7 / 60', tab_bar_alignment: 'center'
  )
  out[:element]['tabBar'] == { 'alignment' => 'center' }
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
check('all composition emitters use canonical leaves and no legacy layout tags') do
  outputs = [
    Composition.compose(els, pattern: :exec),
    Composition.compose(md_els, pattern: :master_detail),
    Composition.compose(overview_els, pattern: :overview),
    Composition.compose(workbench_els, pattern: :workbench),
    Composition.compose(queue_rail_els, pattern: :queue_rail),
    Composition.compose(builder_preview_els, pattern: :builder_preview),
    Composition.tabbed_container(
      id: 'tc', tabs: tabbed_tabs, grid_column: '1 / 25', grid_row: '7 / 60'
    )[:layout]
  ].join("\n")
  outputs.include?('<Element ') &&
    !outputs.match?(/<(?:LayoutElement|GridContainer)\b/)
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

# --- Named splits, mosaic, ledger, table_height -------------------------

check('SPLIT_PRESETS cover full/pairs/halves/trio and each sums to 24') do
  expected = {
    full: [24], pair_16_8: [16, 8], pair_14_10: [14, 10], pair_17_7: [17, 7],
    pair_8_16: [8, 16], pair_7_17: [7, 17], halves: [12, 12], trio: [8, 8, 8]
  }
  Composition::SPLIT_PRESETS == expected &&
    expected.all? { |_k, widths| widths.sum == 24 }
end

check('resolve_split: nil even-splits; named presets; explicit arrays') do
  Composition.resolve_split(nil, 24, 4) == [6, 6, 6, 6] &&
    Composition.resolve_split(:pair_16_8, 24, 2) == [16, 8] &&
    Composition.resolve_split([10, 14], 24, 2) == [10, 14]
end

check('resolve_split: unknown name / bad sum / count mismatch / non-24 named raise') do
  errors = []
  begin; Composition.resolve_split(:pair_9_9, 24, 2); rescue ArgumentError => e; errors << e.message; end
  begin; Composition.resolve_split([10, 10], 24, 2); rescue ArgumentError => e; errors << e.message; end
  begin; Composition.resolve_split(:pair_16_8, 24, 3); rescue ArgumentError => e; errors << e.message; end
  begin; Composition.resolve_split(:halves, 12, 2); rescue ArgumentError => e; errors << e.message; end
  errors.size == 4 &&
    errors[0].include?('unknown split') &&
    errors[1].include?('sum') &&
    errors[2].include?('width') &&
    errors[3].include?('page_cols=24')
end

check('band: default even split unchanged; named split applies widths') do
  even = Composition.band([{ id: 'a' }, { id: 'b' }], 1, 5, 24)
  named = Composition.band([{ id: 'a' }, { id: 'b' }], 1, 5, 24, split: :pair_16_8)
  even == [
    '  <Element elementId="a" gridColumn="1 / 13" gridRow="1 / 5"/>',
    '  <Element elementId="b" gridColumn="13 / 25" gridRow="1 / 5"/>'
  ] && named == [
    '  <Element elementId="a" gridColumn="1 / 17" gridRow="1 / 5"/>',
    '  <Element elementId="b" gridColumn="17 / 25" gridRow="1 / 5"/>'
  ]
end

check('band: explicit widths on custom page_cols; named preset rejected off-24') do
  custom = Composition.band([{ id: 'a' }, { id: 'b' }, { id: 'c' }], 2, 8, 12, split: [5, 3, 4])
  ok_custom = custom == [
    '  <Element elementId="a" gridColumn="1 / 6" gridRow="2 / 8"/>',
    '  <Element elementId="b" gridColumn="6 / 9" gridRow="2 / 8"/>',
    '  <Element elementId="c" gridColumn="9 / 13" gridRow="2 / 8"/>'
  ]
  raised = begin
    Composition.band([{ id: 'a' }, { id: 'b' }], 1, 5, 12, split: :halves)
    false
  rescue ArgumentError => e
    e.message.include?('page_cols=24')
  end
  ok_custom && raised
end

check('compose band_splits: overrides one band, leaves others even') do
  out = Composition.compose(
    [{ id: 'k1', role: :kpi }, { id: 'k2', role: :kpi }, { id: 'hero', role: :hero }],
    pattern: :exec,
    band_splits: { kpi: :pair_16_8 }
  )
  out.include?('elementId="k1" gridColumn="1 / 17"') &&
    out.include?('elementId="k2" gridColumn="17 / 25"') &&
    out.include?('elementId="hero" gridColumn="1 / 25"')
end

check('compose band_splits: master_detail can use pair_14_10') do
  out = Composition.compose(
    [{ id: 'm', role: :master }, { id: 'd', role: :detail }],
    pattern: :master_detail,
    band_splits: { master_detail: :pair_14_10 }
  )
  out.include?('elementId="m" gridColumn="1 / 15" gridRow="1 / 15"') &&
    out.include?('elementId="d" gridColumn="15 / 25" gridRow="1 / 15"')
end

mosaic_golden = File.read(File.join(__dir__, 'testdata', 'composition_mosaic_golden.txt')).strip
check('mosaic: primary 14x16 beside two stacked 10x8 panes matches golden') do
  out = Composition.mosaic(primary: 'deep', top_right: 'a', bottom_right: 'b')
  out.strip == mosaic_golden &&
    out.include?('elementId="deep" gridColumn="1 / 15" gridRow="1 / 17"') &&
    out.include?('elementId="a" gridColumn="15 / 25" gridRow="1 / 9"') &&
    out.include?('elementId="b" gridColumn="15 / 25" gridRow="9 / 17"')
end
check('mosaic: accepts hashes, custom r0; rejects non-24 page_cols / invalid r0 / missing ids') do
  out = Composition.mosaic(
    primary: { id: 'p' }, top_right: { id: 't' }, bottom_right: { id: 'b' }, r0: 5
  )
  placed = out.include?('gridRow="5 / 21"') && out.include?('gridRow="5 / 13"') &&
           out.include?('gridRow="13 / 21"')
  bad_cols = begin
    Composition.mosaic(primary: 'p', top_right: 't', bottom_right: 'b', page_cols: 12)
    false
  rescue ArgumentError => e
    e.message.include?('page_cols=24')
  end
  bad_id = begin
    Composition.mosaic(primary: '', top_right: 't', bottom_right: 'b')
    false
  rescue ArgumentError
    true
  end
  bad_row = begin
    Composition.mosaic(primary: 'p', top_right: 't', bottom_right: 'b', r0: 0)
    false
  rescue ArgumentError
    true
  end
  placed && bad_cols && bad_id && bad_row
end

ledger_golden = File.read(File.join(__dir__, 'testdata', 'composition_ledger_golden.txt')).strip
ledger_els = [
  { id: 'title', role: :ledger_header },
  { id: 'count', role: :ledger_count },
  { id: 'search', role: :ledger_toolbar },
  { id: 'results', role: :ledger_results },
  { id: 'detail', role: :ledger_detail },
  { id: 'k1', role: :ledger_kpi }, { id: 'k2', role: :ledger_kpi }
]
check('ledger: full record-lookup layout matches golden (16/8 title, 14/10 body)') do
  out = Composition.compose(ledger_els, pattern: :ledger)
  out.strip == ledger_golden &&
    out.include?('elementId="title" gridColumn="1 / 17" gridRow="1 / 4"') &&
    out.include?('elementId="count" gridColumn="17 / 25" gridRow="1 / 4"') &&
    out.include?('elementId="search" gridColumn="1 / 25" gridRow="4 / 7"') &&
    out.include?('elementId="results" gridColumn="1 / 15" gridRow="7 / 23"') &&
    out.include?('elementId="detail" gridColumn="15 / 25" gridRow="7 / 23"') &&
    out.include?('elementId="k1" gridColumn="1 / 13" gridRow="23 / 29"')
end
check('ledger: optional detail/kpi/count collapse; results required') do
  minimal = Composition.compose(
    [{ id: 'hdr', role: :ledger_header }, { id: 'res', role: :ledger_results }],
    pattern: :ledger
  )
  collapsed = minimal.include?('elementId="hdr" gridColumn="1 / 25" gridRow="1 / 4"') &&
              minimal.include?('elementId="res" gridColumn="1 / 25" gridRow="4 / 20"') &&
              !minimal.include?('ledger_detail') && !minimal.include?('gridRow="20 /')
  missing = begin
    Composition.compose([{ id: 'hdr', role: :ledger_header }], pattern: :ledger)
    false
  rescue ArgumentError => e
    e.message.include?('ledger_results')
  end
  bad_role = begin
    Composition.compose(
      [{ id: 'res', role: :ledger_results }, { id: 'k', role: :kpi }],
      pattern: :ledger
    )
    false
  rescue ArgumentError => e
    e.message.include?('not used by pattern ledger')
  end
  collapsed && missing && bad_role
end
check('ledger: band_splits can override body to pair_17_7') do
  out = Composition.compose(
    [{ id: 'res', role: :ledger_results }, { id: 'det', role: :ledger_detail }],
    pattern: :ledger,
    band_splits: { ledger_body: :pair_17_7 }
  )
  out.include?('elementId="res" gridColumn="1 / 18"') &&
    out.include?('elementId="det" gridColumn="18 / 25"')
end

check('table_height: ceil(3 + rows*4/3); 7→13; rejects negatives') do
  Composition.table_height(0) == 3 &&
    Composition.table_height(1) == 5 &&
    Composition.table_height(7) == 13 &&
    Composition.table_height(10) == 17 &&
    (begin; Composition.table_height(-1); false; rescue ArgumentError; true; end) &&
    (begin; Composition.table_height(1.5); false; rescue ArgumentError; true; end)
end

check('exec supporting/detail band is now height 13 (table ends at row 32)') do
  out = Composition.compose(els, pattern: :exec)
  out.include?('elementId="tbl" gridColumn="1 / 25" gridRow="19 / 32"') &&
    Composition.bands([{ id: 't', role: :table }], :exec) == [
      { role: :supporting, ids: ['t'], r0: 1, r1: 14 }
    ]
end

check('operational patterns still byte-identical after split-resolver refactor') do
  Composition.compose(workbench_els, pattern: :workbench).strip == workbench_golden &&
    Composition.compose(queue_rail_els, pattern: :queue_rail).strip == queue_rail_golden &&
    Composition.compose(builder_preview_els, pattern: :builder_preview).strip == builder_preview_golden
end
check('operational custom page_cols preserve historical absolute left spans') do
  out = Composition.compose(
    [{ id: 'ctx', role: :context }, { id: 'grid', role: :work_surface }],
    pattern: :workbench,
    page_cols: 30
  )
  out.include?('elementId="ctx" gridColumn="1 / 9"') &&
    out.include?('elementId="grid" gridColumn="9 / 31"')
end
check('operational custom page_cols accept an explicit pair override') do
  out = Composition.compose(
    [{ id: 'ctx', role: :context }, { id: 'grid', role: :work_surface }],
    pattern: :workbench,
    page_cols: 30,
    band_splits: { workbench: [10, 20] }
  )
  out.include?('elementId="ctx" gridColumn="1 / 11"') &&
    out.include?('elementId="grid" gridColumn="11 / 31"')
end

exit($failures.zero? ? 0 : 1)
