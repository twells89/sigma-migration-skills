#!/usr/bin/env ruby
# Unit test for build-workbook.rb's build_image — inline data-URI image element
# for Domo image/logo/drawing cards (mirrors tableau build-charts-from-signals.rb:6655).
#   ruby test/test-build-image.rb

require 'base64'; require_relative '../scripts/build-workbook' rescue nil
png = File.join(__dir__, 'fixtures', 'domo-estate', 'logo.png')
el = build_image({ 'id' => 'c9', 'title' => 'Logo', '_pngPath' => png })
raise 'not image kind' unless el['kind'] == 'image'
raise 'not data-uri png' unless el['url'].start_with?('data:image/png;base64,')
raise 'bytes mismatch' unless el['url'].sub('data:image/png;base64,', '') == Base64.strict_encode64(File.binread(png))

# Regression: capture-visuals renders a PNG for EVERY card on a page (filter
# widgets and text/title cards included), so "has a staged PNG + no data
# columns" is NOT a safe signal for "this is an image card" — only an explicit
# chartType match is. A filter widget must stay on the control path and a
# text/title card must stay a text element; neither should silently become a
# flat raster image (fidelity-discipline: no taking liberties, no silent drop).
$warnings = []
filter_card = { 'id' => 'cf1', 'title' => 'Region Filter', 'chartType' => 'filter', 'columns' => [], '_pngPath' => png }
el_filter = build_element(filter_card, {})
raise 'filter card misrouted to an image element' if el_filter && el_filter['kind'] == 'image'

text_card = { 'id' => 'ct1', 'title' => 'Header', 'chartType' => 'text', 'columns' => [], '_pngPath' => png }
el_text = build_element(text_card, {})
raise 'text card misrouted to an image element' if el_text && el_text['kind'] == 'image'

puts 'test-build-image: PASS'
