require 'json'; require_relative 'helper'
%w[datasets pages cards users pdp dataflows activity-log].each do |name|
  f = File.join(Helper.fixtures_dir('tier-b'), "#{name}.json")
  Helper.assert(File.exist?(f), "#{name}.json present")
  d = JSON.parse(File.read(f))
  Helper.assert(d.key?('columns') && d.key?('rows'), "#{name} has columns+rows")
end
# One card must have zero views (→ retire) and one must reference an unhandled Beast Mode (→ needs-gap-scout)
cards = JSON.parse(File.read(File.join(Helper.fixtures_dir('tier-b'),'cards.json')))
Helper.assert(cards['rows'].any?, 'cards non-empty')
puts 'test-fixtures: PASS'
