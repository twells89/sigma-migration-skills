# frozen_string_literal: true
# test_composition_lint.rb — run directly: ruby scripts/lib/test_composition_lint.rb (from sigma-workbooks/)
require_relative 'composition'
require_relative 'composition_lint'
require_relative 'styling'
$f = 0; def check(d); ok = yield; puts(ok ? "[ok] #{d}" : "[FAIL] #{d}"); $f += 1 unless ok; end
good = Composition.compose([{ id: 'a', role: :kpi }, { id: 'b', role: :kpi }, { id: 'h', role: :hero }], pattern: :exec)
check('clean exec layout has no lint errors') { CompositionLint.check(good).empty? }
check('composition emits canonical Element leaves, never legacy aliases') do
  good.include?('<Element ') &&
    !good.include?('<LayoutElement') &&
    !good.include?('<GridContainer')
end
operational = {
  workbench: [
    { id: 'context', role: :context },
    { id: 'grid', role: :work_surface }
  ],
  queue_rail: [
    { id: 'queue', role: :queue },
    { id: 'rail', role: :rail }
  ],
  builder_preview: [
    { id: 'builder', role: :builder },
    { id: 'preview', role: :preview }
  ]
}
check('all asymmetric operational app layouts lint clean') do
  operational.all? do |pattern, elements|
    CompositionLint.check(Composition.compose(elements, pattern: pattern)).empty?
  end
end
overlap = %Q(  <Element elementId="x" gridColumn="1 / 13" gridRow="1 / 7"/>\n  <Element elementId="y" gridColumn="10 / 25" gridRow="1 / 7"/>)
check('detects column overlap in a band') { CompositionLint.check(overlap).any? { |e| e =~ /overlap/i } }
gap = %Q(  <Element elementId="x" gridColumn="1 / 7" gridRow="1 / 7"/>)
check('detects a band that does not fill page_cols (dead columns)') { CompositionLint.check(gap).any? { |e| e =~ /fill|dead|sum/i } }
legacy = %Q(<GridContainer elementId="old" gridColumn="1 / 25" gridRow="1 / 7">
  <LayoutElement elementId="old-child" gridColumn="1 / 25" gridRow="1 / 7"/>
</GridContainer>)
check('linter still parses legacy aliases in historical snapshots') do
  CompositionLint.check(legacy).empty?
end

# --- <Container> card wrappers (styled layouts) ---

# (a) a real styled layout: header Container (rows 1/3, full width) +
# a carded kpi band + a bare hero band + a bare supporting band, all stacked
# contiguously below the header. Built from the real Styling/Composition
# helpers (not hand-typed XML) so this reflects what those helpers actually
# emit.
theme = Styling::DEFAULT_THEME
hdr = Styling.header(id: 'hdr', title: 'Dashboard', theme: theme)
els = [{ id: 'k1', role: :kpi }, { id: 'k2', role: :kpi }, { id: 'hero1', role: :hero }, { id: 'sup1', role: :supporting }]
bands = Composition.bands(els, :exec).map { |b| b.merge(r0: b[:r0] + 2, r1: b[:r1] + 2) } # shift below the rows-1/3 header
kpi_band, hero_band, supporting_band = bands
kpi_card = Styling.section_card(id: 'card-kpi', band: kpi_band, theme: theme)
hero_render = Composition.band(hero_band[:ids].map { |i| { id: i } }, hero_band[:r0], hero_band[:r1], 24).join("\n")
supporting_render = Composition.band(supporting_band[:ids].map { |i| { id: i } }, supporting_band[:r0], supporting_band[:r1], 24).join("\n")
styled_layout = [hdr[:layout], kpi_card[:wrap], hero_render, supporting_render].join("\n")
check('styled layout (header Container + carded kpi band + hero + supporting) lints clean') do
  errs = CompositionLint.check(styled_layout)
  errs.empty? || (puts errs.inspect; false)
end
check('styling helpers emit Container/Element and never legacy aliases') do
  styled_layout.include?('<Container ') &&
    styled_layout.include?('<Element ') &&
    !styled_layout.match?(/<(?:GridContainer|LayoutElement)\b/)
end

# (b) a container whose CHILDREN overflow/gap within its own rect must flag,
# even though the container's own page-level rect tiles cleanly.
container_child_gap = %Q(<Container elementId="c1" type="grid" gridColumn="1 / 25" gridRow="1 / 7" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <Element elementId="a" gridColumn="1 / 7" gridRow="1 / 7"/>
  <Element elementId="b" gridColumn="10 / 25" gridRow="1 / 7"/>
</Container>)
check('container whose children gap/overflow within its own rect flags') do
  CompositionLint.check(container_child_gap).any? { |e| e =~ /overlap|gap/i }
end

# (c) a top-level Container overlapping a sibling band (different, but
# vertically overlapping, gridRow ranges) still flags — the container's own
# gridColumn/gridRow now participates in page-level band tiling exactly like
# an <Element> would.
container_sibling_overlap = %Q(<Container elementId="c1" type="grid" gridColumn="1 / 25" gridRow="1 / 7" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <Element elementId="a" gridColumn="1 / 25" gridRow="1 / 7"/>
</Container>
<Element elementId="b" gridColumn="1 / 25" gridRow="4 / 10"/>)
check('a top-level Container overlapping a sibling band flags') do
  CompositionLint.check(container_sibling_overlap).any? { |e| e =~ /overlap/i }
end

ledger_els = [
  { id: 'title', role: :ledger_header },
  { id: 'count', role: :ledger_count },
  { id: 'search', role: :ledger_toolbar },
  { id: 'results', role: :ledger_results },
  { id: 'detail', role: :ledger_detail },
  { id: 'k1', role: :ledger_kpi }, { id: 'k2', role: :ledger_kpi }
]
check('ledger layout lints clean') do
  CompositionLint.check(Composition.compose(ledger_els, pattern: :ledger)).empty?
end
check('mosaic layout lints clean across staggered row boundaries') do
  CompositionLint.check(
    Composition.mosaic(primary: 'deep', top_right: 'a', bottom_right: 'b')
  ).empty?
end
check('exec layout with height-13 supporting band still lints clean') do
  CompositionLint.check(
    Composition.compose(
      [{ id: 'k1', role: :kpi }, { id: 'hero', role: :hero }, { id: 'tbl', role: :table }],
      pattern: :exec
    )
  ).empty?
end
check('band_splits asymmetric exec kpi row lints clean') do
  CompositionLint.check(
    Composition.compose(
      [{ id: 'k1', role: :kpi }, { id: 'k2', role: :kpi }, { id: 'hero', role: :hero }],
      pattern: :exec,
      band_splits: { kpi: :pair_16_8 }
    )
  ).empty?
end

exit($f.zero? ? 0 : 1)
