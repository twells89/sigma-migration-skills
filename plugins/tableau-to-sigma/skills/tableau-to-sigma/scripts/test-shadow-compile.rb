#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

HERE = File.expand_path(__dir__)
REPO = File.expand_path('../../../../..', HERE)
CASE_DIR = File.join(REPO, 'corpus', 'tableau', 'partner-crosstab-controls')
MIGRATE = File.join(HERE, 'migrate-tableau.rb')

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

Dir.mktmpdir('tableau-shadow-test') do |dir|
  work = File.join(dir, 'work')
  candidate = File.join(dir, 'candidate.json')
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby,
    MIGRATE,
    '--shadow-compile',
    '--from-corpus', CASE_DIR,
    '--out', work,
    '--write-candidate', candidate
  )
  assert(status.success?, "shadow compile failed: #{stdout}\n#{stderr}")
  assert(File.exist?(candidate), 'shadow candidate written')
  report_path = File.join(work, 'shadow-compile.json')
  assert(File.exist?(report_path), 'shadow report written')
  report = JSON.parse(File.read(report_path))
  assert(report['identical'] == true, 'candidate matches committed baseline')
  assert(report['sigma_writes'] == 0, 'Sigma writes remain zero')
  assert(report['tableau_writes'] == 0, 'Tableau writes remain zero')
  assert(report['post_complete'] == false, 'shadow never claims live POST completion')

  _stdout, conflict_stderr, conflict_status = Open3.capture3(
    RbConfig.ruby,
    MIGRATE,
    '--shadow-compile',
    '--from-corpus', CASE_DIR,
    '--connection', 'must-not-be-used'
  )
  assert(!conflict_status.success?, 'shadow rejects live connection flag')
  assert(conflict_stderr.include?('--connection'), 'shadow conflict names live flag')

  drift = File.join(dir, 'drift.json')
  baseline = JSON.parse(File.read(File.join(CASE_DIR, 'golden', 'workbook.json')))
  baseline['name'] = 'Intentional Drift'
  File.write(drift, "#{JSON.pretty_generate(baseline)}\n")
  _stdout, _stderr, drift_status = Open3.capture3(
    RbConfig.ruby,
    MIGRATE,
    '--shadow-compile',
    '--from-corpus', CASE_DIR,
    '--out', File.join(dir, 'drift-work'),
    '--baseline', drift
  )
  assert(drift_status.exitstatus == 2, 'shadow drift exits 2')

  _stdout, guard_stderr, guard_status = Open3.capture3(
    { 'SIGMA_SHADOW_COMPILE' => '1' },
    RbConfig.ruby,
    File.join(HERE, 'post-and-readback.rb')
  )
  assert(!guard_status.success?, 'post-and-readback is fail-closed in shadow mode')
  assert(guard_stderr.include?('forbids POST/PUT'), 'write guard explains refusal')
end

puts 'PASS: shadow compiler is deterministic and write-free'
