#!/usr/bin/env ruby
# frozen_string_literal: true

# A selected calculated filter must not bind to a same-named physical/DM
# passthrough. That passthrough may be NULL or carry different semantics.

# Ruby 2.6 floor: this test READS a sibling script and eval()s a method out
# of it, so that script's own require_relative lines never run -- the test
# must supply the polyfill itself. See shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'
DIR = __dir__
SOURCE = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
%w[
  map_column strip_tableau_comments translate_row_level_calc
  translate_dim_calc master_calc_filter_override
].each do |name|
  match = SOURCE.match(/^def #{name}\b.*?\n^end$/m) or abort("could not extract #{name}")
  eval(match[0]) # rubocop:disable Security/Eval -- test-only first-party helper extraction
end

fails = []
def check(condition, message, fails)
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

map = %w[Acceptance Heritage Unique\ Deal\ Id Accepted\ Status Status].to_h do |name|
  plain = name.tr('\\', '')
  ["(?i)^#{Regexp.escape(plain)}$", { 'id' => "m-#{plain.downcase.gsub(/\W+/, '-')}", 'name' => plain }]
end

formula = <<~TABLEAU.strip
  IF [Heritage] = "Mitel"
  OR ([Heritage] = "Unify"
  AND (LEFT([Unique Deal Id],1) = "M" OR LEFT([Unique Deal Id],1) = "R"))
  THEN [Accepted Status]
  ELSEIF ([Status] = "Active" OR [Status] = "Preferred Supplier")
  THEN "Qualified"
  ELSE [Status] END
TABLEAU

override = master_calc_filter_override('Acceptance', formula, map)
check(override && override['id'] == 'm-acceptance',
      "same-named passthrough is replaced in place (got #{override.inspect})", fails)
check(override && override['formula'].match?(/Left\(\[Unique Deal Id\],1\)/i),
      'Tableau string logic survives translation', fails)
check(override && override['formula'].include?('"Qualified"'),
      'Tableau selected-domain branch survives translation', fails)
check(override && !override['formula'].include?('[Master/'),
      'override uses sibling refs because it runs on the master itself', fails)

unmapped = map.reject { |_pattern, entry| entry['name'] == 'Accepted Status' }
check(master_calc_filter_override('Acceptance', formula, unmapped).nil?,
      'an unresolved dependency refuses the override instead of guessing', fails)
check(master_calc_filter_override('Acceptance', 'IF [Acceptance] = "x" THEN "y" END', map).nil?,
      'a self-referential replacement is refused', fails)

puts
if fails.empty?
  puts 'ALL PASS - selected calculated filters override unsafe same-name passthroughs'
  exit 0
end

puts "FAILURES (#{fails.length}):"
fails.each { |failure| puts "  - #{failure}" }
exit 1
