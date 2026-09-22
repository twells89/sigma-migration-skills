#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

BACKENDS = {
  'ruby' => [RbConfig.ruby, File.join(__dir__, 'assert-reconstruction-integrity.rb')],
  'python' => ['python3', File.join(__dir__, 'assert-reconstruction-integrity.py')]
}.freeze

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

run_gate = lambda do |dir, command|
  Open3.capture3(*command, '--workdir', dir)
end

write_controls = lambda do |dir, status|
  File.write(File.join(dir, 'neutral-controls-coverage.json'), JSON.pretty_generate(
    'detail' => [{ 'kind' => 'parameter', 'name' => 'Date Grain', 'status' => status }]
  ))
end

write_kind_fixture = lambda do |dir|
  File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(
    'verified' => true,
    'tiles' => [{ 'title' => 'Volume Trend', 'kind' => 'line-chart' }]
  ))
  File.write(File.join(dir, 'layout-renames.json'), JSON.pretty_generate(
    'Volume Trend' => 'REBUILT Volume Trend'
  ))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(
    'workbookId' => 'wb-neutral',
    'latestDocumentVersion' => '9',
    'document' => {
      'schemaVersion' => 4,
      'kind' => 'workbook',
      'pages' => [{ 'id' => 'page-dashboard', 'name' => 'Dashboard' }],
      'elements' => [
        { 'id' => 'el-volume', 'kind' => 'bar-chart', 'name' => 'REBUILT Volume Trend' }
      ],
      'layout' => '<Page id="page-dashboard"><Element elementId="el-volume"/></Page>'
    }
  ))
end

BACKENDS.each do |backend, command|
  Dir.mktmpdir do |dir|
    out, err, status = run_gate.call(dir, command)
    check.call(status.success?, "#{backend}: no reconstruction residues passes (#{err})")
    check.call(out.include?('[OK] reconstruction integrity'), "#{backend}: clean gate states its result")
  end

  Dir.mktmpdir do |dir|
    write_controls.call(dir, 'needs-wiring')
    _out, err, status = run_gate.call(dir, command)
    check.call(!status.success? && err.include?('parameter:Date Grain') && err.include?('needs-wiring'),
               "#{backend}: declared needs-wiring remains blocking by name")
    result = JSON.parse(File.read(File.join(dir, 'reconstruction-integrity.json')))
    check.call(result['status'] == 'FAIL' && result['unresolved_controls'].length == 1,
               "#{backend}: control blocker is persisted in the integrity artifact")
  end

  Dir.mktmpdir do |dir|
    write_controls.call(dir, 'needs-materialization')
    File.write(File.join(dir, 'controls-waivers.json'), JSON.pretty_generate(
      [{ 'control' => 'parameter:Date Grain', 'reason' => 'source parameter is outside retained scope' }]
    ))
    _out, _err, status = run_gate.call(dir, command)
    check.call(status.success?, "#{backend}: reasoned control waiver terminally accepts the scope cut")
  end

  Dir.mktmpdir do |dir|
    write_kind_fixture.call(dir)
    _out, err, status = run_gate.call(dir, command)
    check.call(!status.success? && err.include?('expected line, built bar'),
               "#{backend}: renamed reconstructed bar cannot hide a verified source line")
    result = JSON.parse(File.read(File.join(dir, 'reconstruction-integrity.json')))
    mismatch = result['renamed_chart_family_mismatches'].first
    check.call(mismatch && mismatch['source_tile'] == 'Volume Trend',
               "#{backend}: chart-family mismatch artifact retains source and renamed identities")
  end

  Dir.mktmpdir do |dir|
    write_kind_fixture.call(dir)
    png_path = File.join(dir, 'png-read.json')
    png = JSON.parse(File.read(png_path))
    png['kind_waivers'] = [{
      'tile' => 'Volume Trend',
      'reason' => 'documented capability substitution'
    }]
    File.write(png_path, JSON.pretty_generate(png))
    _out, _err, status = run_gate.call(dir, command)
    check.call(status.success?, "#{backend}: reasoned kind waiver records a deliberate substitution")
  end
end

puts
if fails.empty?
  puts 'ALL PASS — Tableau reconstruction residues block unless completed or explicitly waived'
  exit 0
end

puts "FAILURES (#{fails.length}):"
fails.each { |failure| puts "  - #{failure}" }
exit 1
