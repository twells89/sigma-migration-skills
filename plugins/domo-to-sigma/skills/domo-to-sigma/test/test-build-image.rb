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
puts 'test-build-image: PASS'
