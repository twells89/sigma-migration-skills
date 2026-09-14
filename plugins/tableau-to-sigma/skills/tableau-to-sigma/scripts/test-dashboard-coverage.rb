#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'lib/dashboard_coverage'

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

twb = <<~XML
  <workbook>
    <dashboards>
      <dashboard name="Overview"><zones><zone id="1"/></zones></dashboard>
      <dashboard name="Operations"><zones><zone id="2"/></zones></dashboard>
      <dashboard name="Parameter Host"><zones><zone id="3"/></zones></dashboard>
      <dashboard name="Actually Empty"><zones/></dashboard>
    </dashboards>
    <windows>
      <window class="dashboard" name="Overview"/>
      <window class="dashboard" name="Operations"/>
      <window class="worksheet" hidden="true" name="Parameter Host"/>
    </windows>
  </workbook>
XML

spec_for = lambda do |names|
  {
    'name' => 'Fixture',
    'document' => {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'pages' => names.map.with_index { |name, i| { 'id' => "p#{i}", 'name' => name } },
      'elements' => [],
      'layout' => ''
    }
  }
end

Dir.mktmpdir('dashboard-coverage') do |dir|
  twb_path = File.join(dir, 'source.twb')
  spec_path = File.join(dir, 'spec.json')
  File.write(twb_path, twb)

  File.write(spec_path, JSON.generate(spec_for.call(['Overview'])))
  result = DashboardCoverage.evaluate(
    twb_path: twb_path, spec_path: spec_path,
    scope: { 'mode' => 'full', 'provenance' => 'full-workbook' }
  )
  check.call(result['status'] == 'fail' && result['missing_dashboards'] == ['Operations'],
             'full-workbook mode fails when one visible Tableau dashboard is missing')
  check.call(result['visible_source_dashboards'] == %w[Overview Operations],
             'hidden parameter hosts and truly empty dashboards are excluded')

  File.write(spec_path, JSON.generate(spec_for.call(%w[Overview Operations])))
  result = DashboardCoverage.evaluate(
    twb_path: twb_path, spec_path: spec_path,
    scope: { 'mode' => 'full', 'provenance' => 'full-workbook' }
  )
  check.call(result['status'] == 'pass', 'full-workbook mode passes when every visible dashboard is built')

  File.write(spec_path, JSON.generate(spec_for.call(['Overview'])))
  result = DashboardCoverage.evaluate(
    twb_path: twb_path, spec_path: spec_path,
    scope: { 'mode' => 'selected', 'provenance' => 'stated', 'dashboards' => ['Overview'] }
  )
  check.call(result['status'] == 'pass' && result['scope_excluded_dashboards'] == ['Operations'],
             'stated selected scope may deliberately exclude another visible dashboard')

  result = DashboardCoverage.evaluate(
    twb_path: twb_path, spec_path: spec_path,
    scope: { 'mode' => 'selected', 'provenance' => 'inferred', 'dashboards' => ['Overview'] }
  )
  check.call(result['status'] == 'fail' &&
             result['blockers'].any? { |row| row['kind'] == 'unstated-scope' },
             'inferred selected scope cannot excuse a missing dashboard')

  story_plan = File.join(dir, 'story-plan.json')
  File.write(story_plan, JSON.generate([
    { 'story' => 'Executive Story',
      'points' => [{ 'id' => '1', 'caption' => 'Where we landed',
                     'captured_sheet' => 'Overview', 'sheet_kind' => 'dashboard' }] }
  ]))
  File.write(spec_path, JSON.generate(spec_for.call(%w[Overview Operations])))
  result = DashboardCoverage.evaluate(
    twb_path: twb_path, spec_path: spec_path,
    scope: { 'mode' => 'full', 'provenance' => 'full-workbook' },
    story_plan_path: story_plan
  )
  check.call(result['missing_story_points'] == ['Where we landed'],
             'full scope blocks when a Tableau story point has no Sigma page')
  File.write(spec_path, JSON.generate(spec_for.call(['Overview', 'Operations', 'Where we landed'])))
  result = DashboardCoverage.evaluate(
    twb_path: twb_path, spec_path: spec_path,
    scope: { 'mode' => 'full', 'provenance' => 'full-workbook' },
    story_plan_path: story_plan
  )
  check.call(result['status'] == 'pass', 'story point coverage passes after its page is built')
end

if fails.empty?
  puts 'ALL PASS'
  exit 0
end
warn "#{fails.length} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
