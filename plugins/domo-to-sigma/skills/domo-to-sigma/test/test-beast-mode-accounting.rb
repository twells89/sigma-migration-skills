#!/usr/bin/env ruby

require 'json'
require 'tmpdir'
require 'open3'

SCRIPT = File.expand_path('../scripts/assert-beast-modes-accounted.rb', __dir__)

$failures = 0
def ok(condition, message)
  if condition
    puts "  ok: #{message}"
  else
    $failures += 1
    puts "  FAIL: #{message}"
  end
end

def write_json(dir, name, value)
  File.write(File.join(dir, name), JSON.pretty_generate(value))
end

puts '== complete dataset Beast Mode inventory passes with named deferrals =='
Dir.mktmpdir('bm-accounting') do |dir|
  source = [
    { 'id' => 'p1', 'name' => 'Row Label', 'scope' => 'dataset', 'class' => 'projection',
      'dataSourceId' => 'ds-1' },
    { 'id' => 'm1', 'name' => 'Total Revenue', 'scope' => 'dataset', 'class' => 'aggregate',
      'dataSourceId' => 'ds-1' },
    { 'id' => 'w1', 'name' => 'Running Revenue', 'scope' => 'dataset', 'class' => 'window',
      'dataSourceId' => 'ds-1' },
    { 'id' => 'c1', 'name' => 'Card Label', 'scope' => 'card', 'class' => 'projection',
      'cardId' => 'card-1' },
    { 'id' => 'c2', 'name' => 'Unused Helper', 'scope' => 'card', 'class' => 'projection',
      'cardId' => 'card-1' },
  ]
  write_json(dir, 'beast-modes.json', source)
  write_json(dir, 'formulas.json', source.map { |item| item.merge('sigmaFormula' => '[x]') })
  write_json(dir, 'cards.json', [{
    'id' => 'card-1',
    'columns' => [{
      'column' => 'Card Label', 'beastModeId' => 'c1', '_isCalc' => true,
    }],
  }])
  write_json(dir, 'beast-mode-workbook-usage.json', {
    'usages' => [{
      'id' => 'c1', 'name' => 'Card Label', 'scope' => 'card',
      'cardId' => 'card-1', 'target' => 'workbook-dimension-formula',
    }],
  })
  write_json(dir, 'dm-spec.json', {
    'pages' => [{ 'elements' => [{
      'columns' => [{ 'id' => 'bm-col-p1', 'name' => 'Row Label' }],
      'metrics' => [{ 'id' => 'bm-metric-m1', 'name' => 'Total Revenue' }],
    }] }],
  })
  write_json(dir, 'beast-mode-dm-outcomes.json', {
    'outcomes' => [
      { 'id' => 'p1', 'status' => 'emitted', 'target' => 'data-model-column',
        'targetId' => 'bm-col-p1', 'sigmaName' => 'Row Label' },
      { 'id' => 'm1', 'status' => 'emitted', 'target' => 'data-model-metric',
        'targetId' => 'bm-metric-m1', 'sigmaName' => 'Total Revenue' },
      { 'id' => 'w1', 'status' => 'deferred',
        'reason' => 'window Beast Modes require an explicit Sigma placement/override' },
    ],
  })
  out, status = Open3.capture2e('ruby', SCRIPT, '--discovery', dir)
  ok(status.success?, "accounted inventory exits 0\n#{out unless status.success?}")
  report = JSON.parse(File.read(File.join(dir, 'beast-mode-accounting.json')))
  ok(report['sourceBeastModes'] == 5 && report['sourceDatasetBeastModes'] == 3 &&
     report['sourceCardBeastModes'] == 2, 'dataset and card-local formulas are all counted')
  ok(report['emitted'] == 3 && report['deferred'] == 1 &&
     report['notUsed'] == 1 && report['blocked'] == 0,
     'columns, metrics, workbook use, named deferrals, and unused locals are distinguished')
end

puts '== translated but unplaced dataset Beast Mode is blocked =='
Dir.mktmpdir('bm-accounting') do |dir|
  formula = {
    'id' => 'lost', 'name' => 'Lost Formula', 'scope' => 'dataset',
    'class' => 'projection', 'dataSourceId' => 'ds-1',
  }
  write_json(dir, 'beast-modes.json', [formula])
  write_json(dir, 'formulas.json', [formula.merge('sigmaFormula' => '[x]')])
  write_json(dir, 'dm-spec.json', { 'pages' => [{ 'elements' => [] }] })
  write_json(dir, 'beast-mode-dm-outcomes.json', { 'outcomes' => [] })
  out, status = Open3.capture2e('ruby', SCRIPT, '--discovery', dir)
  ok(!status.success?, 'unplaced translated formula fails the accounting gate')
  ok(out.include?('Lost Formula') && out.include?('no data-model disposition'),
     'failure names the formula and exact missing disposition')
end

puts '== missing and ambiguous card references are blocked =='
Dir.mktmpdir('bm-accounting') do |dir|
  source = [
    { 'id' => 'dup-a', 'name' => 'Duplicate', 'scope' => 'card', 'class' => 'projection',
      'cardId' => 'card-1' },
    { 'id' => 'dup-b', 'name' => 'Duplicate', 'scope' => 'card', 'class' => 'projection',
      'cardId' => 'card-1' },
  ]
  write_json(dir, 'beast-modes.json', source)
  write_json(dir, 'formulas.json', source.map { |item| item.merge('sigmaFormula' => '[x]') })
  write_json(dir, 'cards.json', [{
    'id' => 'card-1',
    'columns' => [
      { 'column' => 'Duplicate', '_isCalc' => true },
      { 'column' => 'Missing', 'beastModeId' => 'missing-id', '_isCalc' => true },
    ],
  }])
  write_json(dir, 'dm-spec.json', { 'pages' => [{ 'elements' => [] }] })
  write_json(dir, 'beast-mode-dm-outcomes.json', { 'outcomes' => [] })
  out, status = Open3.capture2e('ruby', SCRIPT, '--discovery', dir)
  ok(!status.success?, 'ambiguous name-only and missing-id references fail the gate')
  ok(out.include?('matches multiple Beast Mode ids'), 'ambiguous name-only reference is explained')
  ok(out.include?('missing from beast-modes.json'), 'missing stable id is explained')
end

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
