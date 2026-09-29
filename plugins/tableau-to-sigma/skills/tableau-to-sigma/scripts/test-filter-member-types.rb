#!/usr/bin/env ruby
# frozen_string_literal: true

source = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
%w[typed_filter_members full_boolean_domain_filter?].each do |name|
  definition = source.match(/^def #{Regexp.escape(name)}.*?\n^end$/m)
  abort "could not extract #{name}" unless definition
  eval(definition[0]) # rubocop:disable Security/Eval -- first-party test extraction
end

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
check.call(
  full_boolean_domain_filter?(
    'datatype' => 'boolean', 'members' => %w[false true]
  ),
  'both boolean members are recognized as the unrestricted full domain'
)
check.call(
  !full_boolean_domain_filter?(
    'datatype' => 'boolean', 'members' => ['true']
  ),
  'a single boolean member remains a real filter'
)
check.call(
  !full_boolean_domain_filter?(
    'datatype' => 'string', 'members' => %w[false true]
  ),
  'string literals named true/false are not mistaken for a boolean domain'
)

if failures.empty?
  puts 'ALL PASS — worksheet filter members preserve source datatypes'
else
  warn "#{failures.length} failure(s): #{failures.join('; ')}"
  exit 1
end
