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

puts '== merge_geometry: pageLayoutV4 nesting =="'
layoutv4 = { 'pageLayoutV4' => { 'cards' => [{ 'id' => 'c1', 'x' => 9, 'y' => 9, 'w' => 9, 'h' => 9 }] } }
merged5 = merge_geometry([{ 'id' => 'c1' }], layoutv4)
eq([merged5[0]['x'], merged5[0]['w']], [9, 9], 'pageLayoutV4.cards nesting supported')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
