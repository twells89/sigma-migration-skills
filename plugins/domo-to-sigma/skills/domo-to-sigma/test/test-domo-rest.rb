#!/usr/bin/env ruby
# Offline: Domo.cards_for_page must ask for v4 page-layout data (Track C,
# refs/page-layout-v4.md defect 1) — without includeV4PageLayouts=true the
# stacks response never carries pageLayoutV4 at all, so every v4-inline page
# falls through to the screenshot/default-composition fallback unnecessarily.
#   ruby test/test-domo-rest.rb
require_relative '../scripts/lib/domo_rest'

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

puts '== Domo.cards_for_page requests v4 page layouts =='
captured = nil
Domo.define_singleton_method(:private_get) { |path, query: nil| captured = [path, query]; {} }
Domo.cards_for_page('90210001')
eq(captured[0], '/api/content/v3/stacks/90210001/cards', 'hits the stacks endpoint for the given page id')
ok(captured[1].is_a?(Hash) && captured[1][:includeV4PageLayouts] == true,
   "query includes includeV4PageLayouts: true (got #{captured[1].inspect})")
eq(captured[1][:parts], 'metadata,datasources,dateInfo,subscriptions,slicers',
   'default parts include the filter/date bindings needed for faithful tables')

puts '== Domo.cards_for_page still honors an explicit parts: override =='
Domo.cards_for_page('90210001', parts: 'metadata')
eq(captured[1][:parts], 'metadata', 'parts: override still passed through')

puts '== Domo.card_definition public fallback requests quickFilters-capable shape =='
captured = nil
Domo.define_singleton_method(:private_get) { |_path, query: nil| nil }
Domo.define_singleton_method(:public_get) { |path, query: nil, **_kw| captured = [path, query]; {} }
Domo.card_definition('700000010')
eq(captured[0], '/v1/cards/chart/700000010',
   'public fallback uses the documented chart-definition endpoint')

puts '== Domo.card_definition falls back when the private parts read errors =='
captured = nil
Domo.define_singleton_method(:private_get) { |_path, query: nil| raise Domo::Error, 'private unavailable' }
Domo.card_definition('700000011')
eq(captured[0], '/v1/cards/chart/700000011',
   'a private endpoint error does not suppress the public definition fallback')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
