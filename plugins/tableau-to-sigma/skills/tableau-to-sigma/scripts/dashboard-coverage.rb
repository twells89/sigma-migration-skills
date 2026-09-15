#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'lib/dashboard_coverage'

opts = {}
OptionParser.new do |parser|
  parser.on('--workdir DIR') { |value| opts[:workdir] = File.expand_path(value) }
  parser.on('--source PATH') { |value| opts[:source] = File.expand_path(value) }
  parser.on('--spec PATH') { |value| opts[:spec] = File.expand_path(value) }
  parser.on('--scope PATH') { |value| opts[:scope] = File.expand_path(value) }
  parser.on('--check', 'compare with the existing artifact instead of writing') { opts[:check] = true }
end.parse!

workdir = opts[:workdir] || abort('usage: dashboard-coverage.rb --workdir DIR [--spec PATH] [--check]')
source = opts[:source] || File.join(workdir, 'workbook-content.twb')
spec = opts[:spec] ||
       [File.join(workdir, 'wb-readback.json'),
        File.join(workdir, 'wb-spec.resolved.json'), File.join(workdir, 'wb-spec.json')]
       .find { |path| File.file?(path) }
scope_path = opts[:scope] || File.join(workdir, 'dashboard-scope.json')
artifact_path = File.join(workdir, 'dashboard-coverage.json')

unless File.file?(source) && spec && File.file?(spec)
  warn "DASHBOARD COVERAGE FAIL: source/spec missing (source=#{source}, spec=#{spec || '(none)'})"
  exit 3
end

scope = begin
  File.file?(scope_path) ? JSON.parse(File.read(scope_path)) : { 'mode' => 'full' }
rescue JSON::ParserError => e
  warn "DASHBOARD COVERAGE FAIL: #{scope_path} is malformed: #{e.message}"
  exit 3
end
result = begin
  DashboardCoverage.evaluate(
    twb_path: source, spec_path: spec, scope: scope,
    story_plan_path: File.join(workdir, 'story-plan.json')
  )
rescue JSON::ParserError, ArgumentError, SystemCallError => e
  warn "DASHBOARD COVERAGE FAIL: #{e.message}"
  exit 3
end

if opts[:check]
  actual = begin
    JSON.parse(File.read(artifact_path))
  rescue JSON::ParserError, SystemCallError => e
    warn "DASHBOARD COVERAGE FAIL: #{artifact_path} is missing/unreadable: #{e.message}"
    exit 3
  end
  unless actual == result
    warn 'DASHBOARD COVERAGE FAIL: dashboard-coverage.json is stale or was edited; rerun pass 1'
    exit 3
  end
else
  File.write(artifact_path, "#{JSON.pretty_generate(result)}\n")
end

puts "dashboard coverage: #{result['status'].upcase} — " \
     "#{result['built_pages'].size}/#{result['expected_pages'].size} expected page(s), " \
     "#{result['missing_dashboards'].size + result['missing_story_points'].size} missing"
if result['status'] == 'fail'
  result['blockers'].each { |blocker| warn "  - #{blocker['dashboard'] || blocker['kind']}: #{blocker['reason']}" }
  exit 3
end
exit 0
