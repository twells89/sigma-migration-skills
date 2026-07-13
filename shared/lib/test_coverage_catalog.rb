#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit test for coverage_catalog.rb. Run: ruby shared/lib/test_coverage_catalog.rb

require 'json'
require 'tmpdir'
require_relative 'coverage_catalog'

$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "  [ok] #{desc}" : "  [FAIL] #{desc}")
  $failures += 1 unless ok
end

Dir.mktmpdir('cc-rb-test-') do |dir|
  File.write(File.join(dir, 'number-format.json'), JSON.dump(
    'dimension' => 'number-format', 'source_tool' => 'quicksight',
    'authoritative_doc' => 'https://example/authority', 'on_unmapped_default' => 'warn+skip',
    'rows' => [
      { 'source' => 'usd_0', 'sigma' => '$,.0f', 'doc_ref' => 'https://example/usd_0',
        'sigma_verified' => { 'status' => 'y', 'date' => '2026-07-13' } },
      { 'source' => 'Percent_1', 'sigma' => ',.1%', 'doc_ref' => 'https://example/pct',
        'sigma_verified' => { 'status' => 'n' } }
    ]
  ))
  cat = Coverage.load(dir, 'number-format')

  check('resolve hit + case/space normalization') do
    cat.target('usd_0') == '$,.0f' && cat.target('  USD_0 ') == '$,.0f' && cat.target('percent_1') == ',.1%'
  end
  check('resolve miss -> nil') { cat.resolve('gbp_9').nil? && cat.target('gbp_9').nil? && cat.resolve(nil).nil? }

  w = []
  miss = cat.resolve_or_warn('gbp_9', w, context: "visual 'X'")
  check('resolve_or_warn loud on miss') do
    miss.nil? && w.length == 1 && w[0].include?('number-format') && w[0].include?('gbp_9') &&
      w[0].include?('quicksight') && w[0].include?("visual 'X'") && w[0].include?('number-format.json')
  end
  cat.resolve_or_warn('usd_0', w)
  check('resolve_or_warn silent on hit') { w.length == 1 }

  check('metadata + sources') do
    cat.dimension == 'number-format' && cat.source_tool == 'quicksight' &&
      cat.sources.sort == %w[percent_1 usd_0]
  end
  check('unverified') { cat.unverified.map { |r| r['source'] } == ['Percent_1'] }

  raised = false
  begin; Coverage.load(dir, 'nope'); rescue RuntimeError; raised = true; end
  check('missing catalog fails loudly') { raised }

  File.write(File.join(dir, 'viz-kind.json'), JSON.dump(
    'dimension' => 'viz-kind', 'source_tool' => 'quicksight',
    'rows' => [{ 'source' => 'BAR', 'sigma' => 'bar-chart' }]))
  cats = Coverage.load_all(dir)
  check('load_all') { cats.keys.sort == %w[number-format viz-kind] && cats['viz-kind'].target('bar') == 'bar-chart' }

  check('default_catalog_dir') do
    Coverage.default_catalog_dir('/a/b/skills/x/scripts/build.rb').end_with?(File.join('skills', 'x', 'refs', 'catalogs'))
  end
end

if $failures.zero?
  puts 'ALL PASS'
else
  puts "#{$failures} FAILURE(S)"; exit 1
end
