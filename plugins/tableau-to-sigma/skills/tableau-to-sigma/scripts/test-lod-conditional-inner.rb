#!/usr/bin/env ruby
# Regression test for CONDITIONAL / EXPRESSION-inner FIXED LODs in the workbook
# auto-helper path (bead: conditional-inner FIXED LODs silently missed the
# auto-translate). The canonical case is the "last-sold date" recency LOD:
#
#   { FIXED [Retailer Store ID], [Product Name] : MAX(IF [Sales Units] > 0 THEN [Date] END) }
#
# Before the fix parse_fixed_lod's inner was anchored to a bare [col], so MAX(IF
# … END) returned nil and the measure dropped to a generic "translate manually"
# warning. Now the inner is captured generically, translated via the shared
# dim/row-level calc translators, and wrapped in the LOD aggregate.
#
# Deterministic + offline. Exercises the shipped function bodies verbatim
# (extracted + instance_eval'd over a map_column stub), like
# test-param-swap-translation.rb.
#
# Usage:  ruby scripts/test-lod-conditional-inner.rb

DIR   = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

src = File.read(BUILD)
defs = %w[render_agg parse_fixed_lod lod_inner_ref translate_dim_calc
          translate_row_level_calc].map do |fn|
  m = src.match(/^def #{Regexp.escape(fn)}\b.*?\nend\n/m)
  abort "test bug: could not extract def #{fn} from build-charts-from-signals.rb" unless m
  m[0]
end.join("\n")

# LOD_INNER_AGG is a top-level constant the callers use to wrap the inner ref.
LOD_INNER_AGG = {
  'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
  'MEDIAN' => 'Median', 'COUNTD' => 'CountDistinct',
  'COUNT' => 'CountIf(IsNotNull(%s))'
}.freeze

mod = Object.new
# map_column stub: known captions map to a same-named column; unknown -> nil
# (translators then keep the caption verbatim).
mod.instance_eval(<<~STUB + defs)
  KNOWN = %w[Sales\\ Units Date Net\\ Revenue Retailer\\ Store\\ ID Product\\ Name Order\\ Id]
  def map_column(cap, _mmap)
    c = cap.to_s.strip
    KNOWN.include?(c) ? { 'id' => "m-\#{c}", 'name' => c } : nil
  end
STUB

mmap = {} # unused by the stub, but the signatures expect it

# ---- 1. The prospect's conditional MAX-of-date LOD --------------------------
puts 'Part 1 — conditional MAX-of-date FIXED LOD (last-sold date)'
f1 = '{ FIXED [Retailer Store ID], [Product Name] : MAX(IF [Sales Units] > 0 THEN [Date] END) }'
lod = mod.parse_fixed_lod(f1, {})
check(!lod.nil?, 'parses (no longer nil for a conditional inner)', fails)
check(lod && lod['dims'] == ['Retailer Store ID', 'Product Name'], 'dims are the FIXED keys', fails)
check(lod && lod['agg'] == 'MAX', 'outer aggregate is MAX', fails)
check(lod && lod['measure'].nil? && lod['inner_expr'], 'exposes inner_expr, not measure', fails)
ref = lod && mod.lod_inner_ref(lod, mmap, {})
check(ref == 'If([Master/Sales Units] > 0, [Master/Date], Null)',
      "inner translates to Sigma If() over master cols (got: #{ref.inspect})", fails)
vf = ref && mod.render_agg(LOD_INNER_AGG[lod['agg']], ref)
check(vf == 'Max(If([Master/Sales Units] > 0, [Master/Date], Null))',
      "value formula wraps the inner in Max() (got: #{vf.inspect})", fails)

# ---- 2. Bare-column FIXED LOD — unchanged behaviour -------------------------
puts 'Part 2 — bare-column FIXED LOD (regression: existing path unchanged)'
lod2 = mod.parse_fixed_lod('{ FIXED [Retailer Store ID] : SUM([Net Revenue]) }', {})
check(lod2 && lod2['measure'] == 'Net Revenue', "still exposes 'measure' for a bare column", fails)
ref2 = lod2 && mod.lod_inner_ref(lod2, mmap, {})
check(ref2 == '[Master/Net Revenue]', "bare inner -> single [Master/col] ref (got: #{ref2.inspect})", fails)
vf2 = ref2 && mod.render_agg(LOD_INNER_AGG[lod2['agg']], ref2)
check(vf2 == 'Sum([Master/Net Revenue])', 'bare value formula is Sum([Master/Net Revenue])', fails)

# ---- 3. Nested FIXED stays disjoint (routes to decompose_nested_fixed) ------
puts 'Part 3 — nested FIXED must NOT be claimed here'
nested = '{ FIXED [Retailer Store ID] : SUM({ FIXED [Product Name] : SUM([Net Revenue]) }) }'
check(mod.parse_fixed_lod(nested, {}).nil?, 'nested {FIXED{FIXED}} returns nil', fails)

# ---- 4. GUID refs in dims and inner resolve via columns_by_guid -------------
puts 'Part 4 — GUID refs resolve to captions'
cbg = {
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' => { 'caption' => 'Retailer Store ID' },
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' => { 'caption' => 'Sales Units' },
  'cccccccc-cccc-cccc-cccc-cccccccccccc' => { 'caption' => 'Date' }
}
fg = '{ FIXED [aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa] : ' \
     'MAX(IF [bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb] > 0 THEN [cccccccc-cccc-cccc-cccc-cccccccccccc] END) }'
lodg = mod.parse_fixed_lod(fg, cbg)
check(lodg && lodg['dims'] == ['Retailer Store ID'], 'dim GUID resolves to caption', fails)
refg = lodg && mod.lod_inner_ref(lodg, mmap, cbg)
check(refg == 'If([Master/Sales Units] > 0, [Master/Date], Null)',
      "inner GUIDs resolve to master refs (got: #{refg.inspect})", fails)

# ---- 5. Untranslatable inner -> nil ref (caller warns loudly) ---------------
puts 'Part 5 — untranslatable inner returns nil (routes to DM Custom SQL warning)'
lodx = mod.parse_fixed_lod('{ FIXED [Retailer Store ID] : MAX(REGEXP_EXTRACT([Order Id], "x")) }', {})
check(!lodx.nil?, 'still parses the LOD shell', fails)
check(lodx && mod.lod_inner_ref(lodx, mmap, {}).nil?,
      'inner with an unsupported function yields nil ref', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "FAILURES (#{fails.size}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
