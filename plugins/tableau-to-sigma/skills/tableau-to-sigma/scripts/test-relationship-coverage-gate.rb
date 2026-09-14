#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/relationship_coverage'

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

metadata = lambda do |entries|
  {
    'relationshipCoverage' => {
      'serialized' => entries.length,
      'wired' => entries.count { |entry| entry['derivedVia'] != 'unwired' },
      'entries' => entries
    }
  }
end

puts 'test-relationship-coverage-gate'

result = RelationshipCoverage.evaluate({}, source_text: '<workbook/>')
check.call(result['status'] == 'not-applicable',
           'non-object-graph source without a ledger is not applicable')

result = RelationshipCoverage.evaluate({}, source_text: '<object-graph/>')
check.call(result['status'] == 'fail' &&
           result.dig('blockers', 0, 'kind') == 'coverage-missing',
           'object-graph source without converter coverage fails')

result = RelationshipCoverage.evaluate(metadata.call([
  { 'left' => 'FACT', 'right' => 'DIM', 'derivedVia' => 'serialized', 'keyCount' => 1 }
]))
check.call(result['status'] == 'pass' && result['blockers'].empty?,
           'fully wired relationship coverage passes')

result = RelationshipCoverage.evaluate(metadata.call([
  { 'left' => 'FACT', 'right' => 'DIM_A', 'derivedVia' => 'unwired', 'reason' => 'no key' },
  { 'left' => 'FACT', 'right' => 'DIM_B', 'derivedVia' => 'serialized',
    'partial' => true, 'droppedConditions' => 1 }
]))
check.call(result['status'] == 'fail' &&
           result['blockers'].map { |row| row['kind'] } == %w[unwired partial],
           'unwired and partial relationships both block')

if fails.empty?
  puts 'ALL PASS'
  exit 0
end

warn "#{fails.length} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
