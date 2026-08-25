#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

GATE = File.join(__dir__, 'assert-compiler-runtime.rb')

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

def write(dir, name, value)
  File.write(File.join(dir, name), JSON.generate(value))
end

Dir.mktmpdir('compiler-runtime-gate') do |dir|
  write(dir, 'workbook-compile-plan.json', 'summary' => { 'planned_chart_visuals' => 2 })
  write(dir, 'compile-plan-reconcile.json', 'status' => 'PASS')
  write(dir, 'parity-final.json', 'status' => 'PASS', 'charts_total' => 2, 'charts_fail' => 0)
  write(dir, 'anchors-verdict.json', 'tiles_all_nonempty' => true, 'dashboard_tiles_empty' => [])
  _out, err, status = Open3.capture3(RbConfig.ruby, GATE, '--workdir', dir)
  assert(status.success?, "green compiler runtime gate failed: #{err}")

  write(dir, 'anchors-verdict.json',
        'tiles_all_nonempty' => false,
        'dashboard_tiles_empty' => ['Revenue'])
  _out, err, status = Open3.capture3(RbConfig.ruby, GATE, '--workdir', dir)
  assert(status.exitstatus == 3, 'empty displayed tile blocks compiler runtime gate')
  assert(err.include?('no data'), 'empty-tile failure names no-data condition')
end

puts 'PASS: compiler runtime gate'
