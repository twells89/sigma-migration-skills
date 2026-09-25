#!/usr/bin/env ruby
# frozen_string_literal: true

source = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
definition = source.match(/^def typed_filter_members.*?\n^end$/m)
abort 'could not extract typed_filter_members' unless definition
eval(definition[0]) # rubocop:disable Security/Eval -- first-party test extraction

failures = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  failures << message unless condition
end

check.call(
  typed_filter_members(
    'datatype' => 'boolean', 'members' => %w[false true]
  ) == [false, true],
  'boolean Tableau members become JSON booleans, never null readback values'
)
check.call(
  typed_filter_members(
    'datatype' => 'boolean', 'members' => %w[1 0]
  ) == [true, false],
  'numeric boolean spellings become JSON booleans'
)
check.call(
  typed_filter_members(
    'datatype' => 'integer', 'members' => %w[7 11]
  ) == [7, 11],
  'integer members retain numeric type'
)
check.call(
  typed_filter_members(
    'datatype' => 'string', 'members' => %w[false true]
  ) == %w[false true],
  'string columns retain literal true/false text'
)

if failures.empty?
  puts 'ALL PASS — worksheet filter members preserve source datatypes'
else
  warn "#{failures.length} failure(s): #{failures.join('; ')}"
  exit 1
end
