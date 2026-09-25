#!/usr/bin/env ruby

require_relative '../scripts/qa-check'

$failures = 0
def ok(condition, message)
  if condition
    puts "  ok: #{message}"
  else
    $failures += 1
    puts "  FAIL: #{message}"
  end
end

spec = {
  'pages' => [{
    'name' => 'Dashboard',
    'elements' => [{
      'id' => 'el-123-summary',
      'kind' => 'kpi-chart',
      'name' => 'Count of contactId',
      'columns' => [{
        'id' => 'v-contact', 'name' => 'Count of contactId',
        'formula' => 'Count([Master/Contact Id])',
      }],
      'value' => { 'columnId' => 'v-contact' },
    }],
  }],
}

errors, = check(spec)
ok(errors.any? { |error| error.include?('row-key/id') },
   'unconfirmed COUNT(row-key) remains a hard QA failure')

errors, = check(spec, kpi_override_ids: ['123'])
ok(errors.empty?,
   'operator-confirmed kpi-overrides.json entry clears the false-positive suspicion')

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
