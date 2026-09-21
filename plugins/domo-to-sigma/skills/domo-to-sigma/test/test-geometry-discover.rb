#!/usr/bin/env ruby
# Offline: card grid geometry merge (Task 1 of the domo-to-sigma fidelity pass).
# domo-discover.rb's --pages path used to stash the raw page layout on
# page['_layout'] and nothing ever read it — DomoSigma.merge_geometry copies
# each card's x/y/w/h off the page layout onto the matching cards.json record
# by id, so the (already 2D-capable) layout builder gets real coordinates.
#
#   ruby test/test-geometry-discover.rb
require 'json'
require_relative '../scripts/lib/domo_sigma_util'
include DomoSigma

$failures = 0
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end
def ok(cond, msg) eq(!!cond, true, msg) end

puts '== merge_geometry: copies x/y/w/h by card id =='
layout = { 'cards' => [
  { 'id' => 'c1', 'x' => 0, 'y' => 0, 'w' => 3, 'h' => 2 },
  { 'id' => 'c2', 'x' => 3, 'y' => 0, 'w' => 3, 'h' => 2 },
] }
cards  = [{ 'id' => 'c1', 'title' => 'A' }, { 'id' => 'c2', 'title' => 'B' }]
merged = merge_geometry(cards, layout)
ok(merged[0]['x'] == 0 && merged[1]['x'] == 3 && merged[0]['w'] == 3, 'x/w copied by matching id')
eq(merged[0]['y'], 0, 'y copied')
eq(merged[0]['h'], 2, 'h copied')
eq(merged[1]['y'], 0, 'y copied for second card')
eq(merged[1]['w'], 3, 'w copied for second card')
eq(merged[0]['title'], 'A', 'original card fields preserved')
ok(merged[0]['x'].is_a?(Integer), 'x coerced to Integer')

puts '== merge_geometry: alternate raw field names (width/colSpan/sizeX, height/rowSpan/sizeY, col/gridX, row/gridY) =='
layout2 = { 'cards' => [
  { 'id' => 'c1', 'col' => 1, 'row' => 2, 'width' => 4, 'height' => 5 },
  { 'id' => 'c2', 'gridX' => 6, 'gridY' => 7, 'colSpan' => 8, 'rowSpan' => 9 },
  { 'id' => 'c3', 'x' => 10, 'y' => 11, 'sizeX' => 12, 'sizeY' => 13 },
] }
cards2 = [
  { 'id' => 'c1', 'title' => 'A' },
  { 'id' => 'c2', 'title' => 'B' },
  { 'id' => 'c3', 'title' => 'C' },
]
merged2 = merge_geometry(cards2, layout2)
eq([merged2[0]['x'], merged2[0]['y'], merged2[0]['w'], merged2[0]['h']], [1, 2, 4, 5], 'col/row/width/height fallback')
eq([merged2[1]['x'], merged2[1]['y'], merged2[1]['w'], merged2[1]['h']], [6, 7, 8, 9], 'gridX/gridY/colSpan/rowSpan fallback')
eq([merged2[2]['x'], merged2[2]['y'], merged2[2]['w'], merged2[2]['h']], [10, 11, 12, 13], 'x/y/sizeX/sizeY fallback')

puts '== merge_geometry: geometry nested under c["layout"] =='
layout3 = { 'cards' => [{ 'id' => 'c1', 'layout' => { 'x' => 5, 'y' => 6, 'w' => 7, 'h' => 8 } }] }
merged3 = merge_geometry([{ 'id' => 'c1' }], layout3)
eq([merged3[0]['x'], merged3[0]['y'], merged3[0]['w'], merged3[0]['h']], [5, 6, 7, 8], 'nested layout geometry read')

puts '== merge_geometry: no matching layout entry -> keys OMITTED, not zeroed =='
merged4 = merge_geometry([{ 'id' => 'no-such-card', 'title' => 'Orphan' }], layout)
card4 = merged4.first
eq(card4['title'], 'Orphan', 'card preserved')
ok(!card4.key?('x') && !card4.key?('y') && !card4.key?('w') && !card4.key?('h'), 'no geometry keys added when id has no layout match')

puts '== merge_geometry: nil page_layout -> cards passed through unchanged =='
eq(merge_geometry(cards, nil), cards, 'nil layout is a no-op')

puts '== merge_geometry: pageLayoutV4 (v4-inline pages, Track C) — content[]+standard.template[] joined on contentKey =='
stacks_v4 = {
  'pageLayoutV4' => {
    'content' => [
      { 'contentKey' => 0, 'cardId' => 700000010, 'type' => 'CARD' },
      { 'contentKey' => 1, 'cardId' => 700000011, 'type' => 'CARD' },
      { 'contentKey' => 2, 'type' => 'HEADER', 'text' => 'Sample Section' },
    ],
    'standard' => { 'width' => 60, 'template' => [
      { 'contentKey' => 2, 'x' => 0,  'y' => 0,  'width' => 60, 'height' => 3,  'type' => 'HEADER' },
      { 'contentKey' => 0, 'x' => 0,  'y' => 5,  'width' => 11, 'height' => 14, 'type' => 'CARD' },
      { 'contentKey' => 1, 'x' => 11, 'y' => 5,  'width' => 8,  'height' => 14, 'type' => 'CARD' },
      { 'contentKey' => 3, 'x' => 0,  'y' => 19, 'width' => 60, 'height' => 1,  'type' => 'PAGE_BREAK' },
    ] },
  },
}
merged_v4 = merge_geometry([{ 'id' => 700000010 }, { 'id' => 700000011 }], nil, stacks: stacks_v4)
eq([merged_v4[0]['x'], merged_v4[0]['y'], merged_v4[0]['w'], merged_v4[0]['h']], [0.0, 2.0, 4.4, 5.6],
   'card 700000010 geometry: Domo 60-wide grid scaled x0.4 to Sigma-comparable units')
eq([merged_v4[1]['x'], merged_v4[1]['y'], merged_v4[1]['w'], merged_v4[1]['h']], [4.4, 2.0, 3.2, 5.6],
   'card 700000011 gets its own distinct template entry, joined by its own contentKey')

puts '== merge_geometry: pageLayoutV4 HEADER/PAGE_BREAK entries never produce a phantom card match =='
no_match = merge_geometry([{ 'id' => 'no-such-card' }], nil, stacks: stacks_v4)
ok(!no_match.first.key?('x'), 'a card id with no v4 content[] entry gets no geometry — HEADER/PAGE_BREAK carry no cardId to match against')

puts '== merge_geometry: stacks without a pageLayoutV4 key -> v4 pass is a no-op (legacy pages unaffected) =='
# NOTE: _pageOrder still gets attached by the separate, pre-existing
# merge_stacks_geometry pass (unconditional whenever `stacks` is any Hash —
# see the 'API-created page' test above) — that's out of scope for this v4
# join and is exercised on its own elsewhere. What THIS assertion checks is
# that no x/y/w/h geometry keys leak in when there's no pageLayoutV4 key.
v4_noop = merge_geometry([{ 'id' => 700000010 }], nil, stacks: { 'sizes' => [] })
eq(v4_noop, [{ 'id' => 700000010, '_pageOrder' => 0 }],
   'no pageLayoutV4 key -> no x/y/w/h added (unrelated _pageOrder pass still applies)')
ok(!v4_noop.first.key?('x'), 'specifically: no x/y/w/h geometry keys added by the v4 pass')

puts '== merge_geometry: real captured pageLayoutV4 fixture (test/fixtures/domo-live-raw/stacks-page-v4.json) =='
stacks_v4_fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'domo-live-raw', 'stacks-page-v4.json')))
fixture_v4_cards = stacks_v4_fixture['cards'].map { |c| { 'id' => c['id'], 'title' => c['title'] } }
merged_v4_fixture = merge_geometry(fixture_v4_cards, nil, stacks: stacks_v4_fixture)
by_id_v4 = merged_v4_fixture.each_with_object({}) { |c, h| h[c['id']] = c }
eq([by_id_v4[700000012]['x'], by_id_v4[700000012]['y'], by_id_v4[700000012]['w'], by_id_v4[700000012]['h']],
   [0.0, 7.6, 12.0, 8.0], 'fixture card 700000012 gets exact scaled geometry from standard.template')
ok(by_id_v4.values.all? { |c| c['x'] && c['y'] && c['w'] && c['h'] }, 'every real card in the fixture got geometry (the HEADER entry never became a phantom card)')

puts '== merge_geometry: pageLayoutV4 template entry missing x/y/width/height -> geometry keys OMITTED, never defaulted to 0 =='
# Regression test for the nil.to_f-silently-becomes-0.0 bug: a template entry
# that is genuinely missing geometry (e.g. an isDynamic:true layout) must NOT
# produce x/y/w/h of 0/0.0 — that would be indistinguishable from a real
# top-left coordinate and could make build_dashboard's rung-1 filter accept a
# card (or even the whole page) that has no real geometry at all.
# Before the `next if [...].any?(&:nil?)` guard, this would have produced
# {'x'=>0.0,'y'=>0.0,'w'=>4.4,'h'=>5.6} instead of omitting the keys.
stacks_v4_missing_geom = {
  'pageLayoutV4' => {
    'content' => [{ 'contentKey' => 0, 'cardId' => 700000099, 'type' => 'CARD' }],
    'standard' => { 'width' => 60, 'template' => [
      { 'contentKey' => 0, 'width' => 11, 'height' => 14, 'type' => 'CARD' }, # x, y missing
    ] },
  },
}
merged_missing = merge_geometry([{ 'id' => 700000099, 'title' => 'Dynamic' }], nil, stacks: stacks_v4_missing_geom)
card_missing = merged_missing.first
eq(card_missing['title'], 'Dynamic', 'card preserved even without geometry')
ok(!card_missing.key?('x') && !card_missing.key?('y') && !card_missing.key?('w') && !card_missing.key?('h'),
   'template entry missing x/y -> no x/y/w/h keys added at all (not defaulted to 0/0.0)')

puts '== merge_geometry: v4 pass takes precedence over PARTIAL legacy xywh geometry for the same card id (no mixed-precision merge) =='
# Regression test for the precedence-inversion bug: merge_xywh_geometry must
# run BEFORE merge_pagelayoutv4_geometry so a page with a partial legacy
# page_layout entry (e.g. only width/height, no x/y) for a card that ALSO has
# real v4 geometry doesn't end up with a mixed-precision card — v4's scaled
# x/y combined with the legacy pass's unscaled w/h.
page_layout_partial = { 'cards' => [{ 'id' => 700000010, 'width' => 40, 'height' => 30 }] }
merged_precedence = merge_geometry([{ 'id' => 700000010 }], page_layout_partial, stacks: stacks_v4)
card_precedence = merged_precedence.first
eq([card_precedence['x'], card_precedence['y'], card_precedence['w'], card_precedence['h']], [0.0, 2.0, 4.4, 5.6],
   'v4 geometry (all 4 keys, atomically) wins outright over partial legacy w/h — no mixed-precision result')

# ===========================================================================
# Bug 5 (P0, refs/live-validation-2026-07-30.md): classic Domo pages carry NO
# x/y/w/h at all. The `stacks` (GET /api/content/v3/stacks/{id}/cards)
# response instead carries sizes[] (a T-shirt token per card) and
# collections[] (titled sections grouping cards BY INDEX into the response's
# own cards[] array). merge_geometry's new `stacks:` keyword param merges
# both onto each card as '_size' / '_collection' / '_pageOrder'.
# ===========================================================================
puts '== merge_geometry: stacks sizes[] merged as _size, by card id =='
stacks_a = {
  'sizes' => [
    { 'id' => 'c1', 'size' => 'medium' },
    { 'id' => 'c2', 'size' => 'large' },
  ],
  'collections' => [],
}
cards_a = [{ 'id' => 'c1', 'title' => 'A' }, { 'id' => 'c2', 'title' => 'B' }]
merged_a = merge_geometry(cards_a, nil, stacks: stacks_a)
eq(merged_a[0]['_size'], 'medium', 'T-shirt size token merged for card 1')
eq(merged_a[1]['_size'], 'large', 'T-shirt size token merged for card 2')
eq(merged_a[0]['title'], 'A', 'original card fields preserved alongside _size')

puts '== merge_geometry: collections[] group cards BY INDEX (not by id) into _collection =='
stacks_b = {
  'sizes' => [],
  'collections' => [
    { 'id' => 900, 'title' => 'Section One', 'cardIndices' => [0, 1] },
    { 'id' => 901, 'title' => 'Section Two', 'cardIndices' => [2] },
  ],
}
# NOTE: card ids are deliberately NOT in index order (idOne is at index 0, the
# collection groups by ARRAY POSITION, never by id) — this is exactly the
# distinction Bug 5 calls out.
cards_b = [{ 'id' => 'idOne' }, { 'id' => 'idTwo' }, { 'id' => 'idThree' }]
merged_b = merge_geometry(cards_b, nil, stacks: stacks_b)
eq(merged_b[0]['_collection'], { 'id' => 900, 'title' => 'Section One', 'index' => 0 },
   'card at array position 0 tagged with Section One + its index')
eq(merged_b[1]['_collection'], { 'id' => 900, 'title' => 'Section One', 'index' => 1 },
   'card at array position 1 (idTwo) also grouped into Section One — by position, not id order')
eq(merged_b[2]['_collection'], { 'id' => 901, 'title' => 'Section Two', 'index' => 2 },
   'card at array position 2 tagged with Section Two')
eq([merged_b[0]['_pageOrder'], merged_b[1]['_pageOrder'], merged_b[2]['_pageOrder']], [0, 1, 2],
   '_pageOrder always attached (0-based array position) whenever stacks is given')

puts '== merge_geometry: collection indices follow stacks sizes order, not definition-fetch order =='
stacks_reordered = {
  'sizes' => [
    { 'id' => 'visual-first', 'size' => 'small' },
    { 'id' => 'visual-second', 'size' => 'small' },
    { 'id' => 'visual-third', 'size' => 'small' },
  ],
  'collections' => [
    { 'id' => 910, 'title' => 'First Section', 'cardIndices' => [0, 1] },
    { 'id' => 911, 'title' => 'Second Section', 'cardIndices' => [2] },
  ],
}
definition_order = [
  { 'id' => 'visual-third' },
  { 'id' => 'visual-first' },
  { 'id' => 'visual-second' },
]
merged_reordered = merge_geometry(definition_order, nil, stacks: stacks_reordered)
reordered_by_id = merged_reordered.each_with_object({}) { |card, out| out[card['id']] = card }
eq(reordered_by_id['visual-first']['_collection']['title'], 'First Section',
   'first visual card uses collection index 0 even when fetched second')
eq(reordered_by_id['visual-second']['_collection']['title'], 'First Section',
   'second visual card uses collection index 1 even when fetched third')
eq(reordered_by_id['visual-third']['_collection']['title'], 'Second Section',
   'third visual card uses collection index 2 even when fetched first')
eq(%w[visual-first visual-second visual-third].map {
     |id| reordered_by_id[id]['_pageOrder']
   }, [0, 1, 2],
   '_pageOrder follows the visual sizes sequence')

puts '== merge_geometry: API-created page (collections: []) — _pageOrder + _size, no _collection =='
stacks_c = { 'sizes' => [{ 'id' => 'c1', 'size' => 'small' }], 'collections' => [] }
merged_c = merge_geometry([{ 'id' => 'c1' }], nil, stacks: stacks_c)
eq(merged_c[0]['_size'], 'small', '_size still merged with zero collections')
eq(merged_c[0].key?('_collection'), false, 'no _collection key added when collections is empty')
eq(merged_c[0]['_pageOrder'], 0, '_pageOrder still attached with zero collections')

puts '== merge_geometry: a card whose index falls OUTSIDE every cardIndices range gets _pageOrder but no _collection =='
stacks_d = { 'sizes' => [], 'collections' => [{ 'id' => 1, 'title' => 'Only Section', 'cardIndices' => [0] }] }
merged_d = merge_geometry([{ 'id' => 'c1' }, { 'id' => 'c2' }], nil, stacks: stacks_d)
eq(merged_d[0].key?('_collection'), true, 'card at index 0 (covered) gets _collection')
eq(merged_d[1].key?('_collection'), false, 'card at index 1 (uncovered) gets NO _collection')
eq(merged_d[1]['_pageOrder'], 1, 'but still gets _pageOrder (an explicit ordering signal even with no section)')

puts '== merge_geometry: nil stacks -> no _size/_collection/_pageOrder added (existing x/y/w/h behavior untouched) =='
merged_e = merge_geometry(cards, layout, stacks: nil)
eq(merged_e[0].key?('_size'), false, 'no _size added when stacks is nil')
eq(merged_e[0].key?('_pageOrder'), false, 'no _pageOrder added when stacks is nil')
eq(merged_e[0]['x'], 0, 'the ORIGINAL x/y/w/h merge still works unchanged with stacks: nil')

puts '== merge_geometry: x/y/w/h (mason) AND stacks sizes/collections can BOTH be present on the same call =='
merged_f = merge_geometry(cards, layout, stacks: stacks_a)
eq(merged_f[0]['x'], 0, 'x/y/w/h from page_layout still present')
eq(merged_f[0]['_size'], 'medium', '_size from stacks also present on the very same card')

# ===========================================================================
# Bug B (refs/live-validation-2026-07-30.md): "size token join is broken two
# ways" on a live instance —
#   1. a TYPE MISMATCH: the live GET /api/content/v3/stacks/{pageId}/cards
#      response has cards[].id as an INTEGER but sizes[].id as a STRING (a
#      live probe: "card id types: ['int','int','int'] / size id types:
#      ['str','str','str']") — 0/15 cards on that run got a merged _size.
#   2. the size TOKEN ITSELF can be the EMPTY STRING for API-created cards
#      (live: {"id":"189217601","size":""}), which is the NORMAL "unspecified"
#      value, not an anomaly.
# ===========================================================================
puts "== merge_geometry: card ids INTEGER, stacks['sizes'] ids STRING — the exact live type mismatch joins correctly =="
stacks_type_mismatch = {
  'sizes' => [
    { 'id' => '501', 'size' => 'medium' },
    { 'id' => '502', 'size' => '' }, # API-created card: "" is normal, not an anomaly
  ],
  'collections' => [],
}
cards_type_mismatch = [{ 'id' => 501, 'title' => 'Int Card A' }, { 'id' => 502, 'title' => 'Int Card B' }]
merged_g = merge_geometry(cards_type_mismatch, nil, stacks: stacks_type_mismatch)
ok(cards_type_mismatch.all? { |c| c['id'].is_a?(Integer) }, 'sanity: card ids really are Integer, matching the live shape')
ok(stacks_type_mismatch['sizes'].all? { |s| s['id'].is_a?(String) }, "sanity: stacks['sizes'] ids really are String, matching the live shape")
eq(merged_g[0]['_size'], 'medium', 'Integer card id 501 joins String size id "501"')
eq(merged_g[1].key?('_size'), true, 'Integer card id 502 STILL gets a _size key even though its token is ""')
eq(merged_g[1]['_size'], '', 'the merged _size is the empty string itself, not silently dropped as "no size"')

puts '== merge_geometry: stacks fixture (test/fixtures/domo-live-raw/stacks-page.json) — real captured shape, end to end =='
stacks_fixture = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'domo-live-raw', 'stacks-page.json')))
fixture_cards = stacks_fixture['cards'].map { |c| { 'id' => c['id'], 'title' => c['title'] } }
ok(fixture_cards.all? { |c| c['id'].is_a?(Integer) }, 'fixture card ids are Integer (as captured live)')
ok(stacks_fixture['sizes'].all? { |s| s['id'].is_a?(String) }, 'fixture size ids are String (as captured live)')
merged_fixture = merge_geometry(fixture_cards, nil, stacks: stacks_fixture)
by_id = merged_fixture.each_with_object({}) { |c, h| h[c['id']] = c }
eq(by_id[700000001]['_size'], 'medium', 'fixture card 700000001 (Integer id) joins its String-id size entry')
eq(by_id[700000003]['_size'], 'large', 'fixture card 700000003 joins its "large" size token')
eq(by_id[700000005].key?('_size'), true,
   'fixture card 700000005 (API-created, unsized) STILL gets a _size key for its "" token')
eq(by_id[700000005]['_size'], '', 'that _size is the empty string, not omitted')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
