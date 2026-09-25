#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'

source = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
definition = source.match(/^def worksheet_element_id.*?\n^end$/m)
abort 'could not extract worksheet_element_id' unless definition
eval(definition[0]) # rubocop:disable Security/Eval -- first-party test extraction

$worksheet_element_id_owners = {}
$worksheet_element_id_collisions = []
first_caption = '2. WEEKLY/MONTHLY UPLOADED PAGES BY VERIFICATION FLOW TYPE - REPORTING'
second_caption = '2. WEEKLY/MONTHLY % UPLOADED PAGES BY VERIFICATION FLOW TYPE - REPORTING'
first = worksheet_element_id(first_caption)
second = worksheet_element_id(second_caption)
repeat = worksheet_element_id(first_caption)

failures = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  failures << message unless condition
end
check.call(first != second, 'long captions with the same truncated slug get distinct element ids')
check.call(second.match?(/-[0-9a-f]{8}\z/), 'colliding id receives a stable digest suffix')
check.call(repeat == first, 'the same worksheet reused on another dashboard keeps its stable base id')
check.call($worksheet_element_id_collisions.length == 1,
           'one collision is recorded for diagnostic reporting')

if failures.empty?
  puts 'ALL PASS — caption truncation cannot overwrite a different worksheet'
else
  warn "#{failures.length} failure(s): #{failures.join('; ')}"
  exit 1
end
