#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

RUNNER = File.join(__dir__, 'tableau-compiler-benchmark.rb')

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

Dir.mktmpdir('tableau-compiler-benchmark') do |dir|
  panel = {
    'schema_version' => 1,
    'promotion' => {
      'minimum_equal_or_better_rate' => 1.0,
      'minimum_green_rate' => 1.0,
      'maximum_numeric_regressions' => 0
    },
    'cases' => [{ 'id' => 'case-1', 'role' => 'live-anchor' }]
  }
  panel_path = File.join(dir, 'panel.json')
  out_path = File.join(dir, 'results.json')
  File.write(panel_path, JSON.generate(panel))
  %w[baseline candidate].each do |side|
    path = File.join(dir, 'results', 'case-1', side)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'migration-result.json'), JSON.generate('verdict' => 'GREEN'))
    File.write(File.join(path, 'parity-final.json'), JSON.generate('value_parity_score' => 1.0))
  end
  candidate = File.join(dir, 'results', 'case-1', 'candidate')
  File.write(File.join(candidate, 'compile-plan-reconcile.json'), JSON.generate('status' => 'PASS'))

  _stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, RUNNER,
    '--panel', panel_path,
    '--results-root', File.join(dir, 'results'),
    '--out', out_path
  )
  assert(status.success?, "passing panel failed: #{stderr}")
  assert(JSON.parse(File.read(out_path)).dig('summary', 'promotion_pass') == true,
         'passing panel promotes')

  File.delete(File.join(candidate, 'parity-final.json'))
  File.delete(File.join(candidate, 'migration-result.json'))
  _stdout, _stderr, status = Open3.capture3(
    RbConfig.ruby, RUNNER,
    '--panel', panel_path,
    '--results-root', File.join(dir, 'results'),
    '--out', out_path
  )
  assert(status.exitstatus == 2, 'missing A/B side fails closed')
end

puts 'PASS: Tableau compiler benchmark evaluator'
