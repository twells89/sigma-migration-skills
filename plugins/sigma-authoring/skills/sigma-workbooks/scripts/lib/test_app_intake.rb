#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'app_intake'

failures = []

def check(name, failures)
  yield
  puts "PASS: #{name}"
rescue StandardError => e
  failures << "#{name}: #{e.message}"
  warn "FAIL: #{name}: #{e.message}"
end

AppIntake::APP_TYPES.each do |app_type|
  check("#{app_type} template passes validation", failures) do
    errors = AppIntake.errors(AppIntake.template_for(app_type))
    raise errors.join('; ') unless errors.empty?
  end

  check("#{app_type} template includes required grain keys", failures) do
    keys = AppIntake.template_for(app_type).fetch('grain').fetch('keys')
    required = AppIntake::GRAIN_KEYS.fetch(app_type)
    missing = required - keys
    raise "missing keys #{missing.inspect}" unless missing.empty?
  end

  check("#{app_type} template does not pass strict completion", failures) do
    errors = AppIntake.errors(AppIntake.template_for(app_type), strict: true)
    raise 'strict check unexpectedly passed' if errors.empty?
    raise 'missing write connection error' unless errors.any? { |error| error.include?('writeConnectionId') }
    raise 'missing expectedRows error' unless errors.any? { |error| error.include?('expectedRows') }
  end

  check("#{app_type} template includes recommended editable fields", failures) do
    fields = AppIntake.template_for(app_type).fetch('editableFields')
    expected = AppIntake.editable_fields_for(app_type)
    raise "expected #{expected.inspect}, got #{fields.inspect}" unless fields == expected
  end

  check("#{app_type} template pre-fills agent and approvals", failures) do
    manifest = AppIntake.template_for(app_type)
    agent = manifest.fetch('agent')
    raise 'agent.include must default false' unless agent['include'] == false
    raise 'agent.purpose missing' if agent['purpose'].to_s.strip.empty?
    raise 'agent purpose mismatch' unless agent['purpose'] == AppIntake.agent_purpose_for(app_type)
    raise 'agent capabilities mismatch' unless
      agent['capabilities'] == AppIntake.agent_capabilities_for(app_type)
    approvals = manifest.fetch('approvals')
    raise 'approvals.include must default true' unless approvals['include'] == true
    raise 'approvals.purpose missing' if approvals['purpose'].to_s.strip.empty?
    raise 'approvals purpose mismatch' unless approvals['purpose'] == AppIntake.approval_purpose_for(app_type)
    raise 'audience missing' if manifest['audience'].to_s.strip.empty?
  end
end

check('agent capability profiles cover Analyze Configure Navigate Act', failures) do
  AppIntake::APP_TYPES.each do |app_type|
    capabilities = AppIntake.agent_capabilities_for(app_type)
    %w[profile analyze configure navigate act].each do |key|
      raise "#{app_type} missing #{key}" unless capabilities.key?(key)
    end
    raise "#{app_type} missing Analyze data sources" if
      capabilities.dig('analyze', 'dataSources').to_a.empty?
    raise "#{app_type} configure.controls must be an array" unless
      capabilities.dig('configure', 'controls').is_a?(Array)
    raise "#{app_type} navigate.pages must be an array" unless
      capabilities.dig('navigate', 'pages').is_a?(Array)
    raise "#{app_type} Act tools missing" if capabilities.dig('act', 'tools').to_a.empty?
    raise "#{app_type} write tools must require approval" unless
      capabilities.dig('act', 'requiresApproval') == true
  end
end

check('agent capability helper returns a deep copy', failures) do
  changed = AppIntake.agent_capabilities_for('planning')
  changed['analyze']['dataSources'] << 'mutated'
  fresh = AppIntake.agent_capabilities_for('planning')
  raise 'capability profile was mutated' if fresh['analyze']['dataSources'].include?('mutated')
end

check('agent write capability without approval is rejected', failures) do
  manifest = AppIntake.template_for('exception')
  manifest['agent']['capabilities']['act']['requiresApproval'] = false
  errors = AppIntake.errors(manifest)
  raise 'unapproved write proposal was accepted' unless
    errors.any? { |error| error.include?('act.requiresApproval') }
end

check('unknown appType is rejected', failures) do
  manifest = AppIntake.template_for('planning')
  manifest['appType'] = 'crm'
  errors = AppIntake.errors(manifest)
  raise 'unknown appType was accepted' unless errors.any? { |error| error.include?('appType must be one of') }
end

check('mismatched recipe is rejected', failures) do
  manifest = AppIntake.template_for('planning')
  manifest['recipe'] = 'reference/workflows/approval-apps.md'
  errors = AppIntake.errors(manifest)
  raise 'mismatched recipe was accepted' unless errors.any? { |error| error.include?('recipe must be') }
end

check('missing grain keys are rejected', failures) do
  manifest = AppIntake.template_for('planning')
  manifest['grain']['keys'] = %w[period]
  errors = AppIntake.errors(manifest)
  raise 'incomplete grain was accepted' unless errors.any? { |error| error.include?('grain.keys must include') }
end

check('completed manifest passes strict validation', failures) do
  manifest = AppIntake.template_for('planning')
  manifest['sources'] = {
    'connectionId' => 'source-conn',
    'tablePath' => %w[DB SCHEMA Source],
    'writeConnectionId' => 'write-conn'
  }
  manifest['grain']['expectedRows'] = 12
  errors = AppIntake.errors(manifest, strict: true)
  raise errors.join('; ') unless errors.empty?
end

check('agent.include true with blank purpose is rejected', failures) do
  manifest = AppIntake.template_for('exception')
  manifest['agent'] = { 'include' => true, 'purpose' => '  ' }
  errors = AppIntake.errors(manifest)
  raise 'blank agent purpose was accepted' unless errors.any? { |error| error.include?('agent.purpose') }
end

check('approvals.include true with blank purpose is rejected', failures) do
  manifest = AppIntake.template_for('planning')
  manifest['approvals'] = { 'include' => true, 'purpose' => '' }
  errors = AppIntake.errors(manifest)
  raise 'blank approvals purpose was accepted' unless errors.any? { |error| error.include?('approvals.purpose') }
end

check('empty editableFields is rejected', failures) do
  manifest = AppIntake.template_for('allocation')
  manifest['editableFields'] = []
  errors = AppIntake.errors(manifest)
  raise 'empty editableFields was accepted' unless errors.any? { |error| error.include?('editableFields') }
end

check('helpers return a purpose and data sources for every type', failures) do
  AppIntake::APP_TYPES.each do |app_type|
    raise "#{app_type} agent purpose blank" if AppIntake.agent_purpose_for(app_type).strip.empty?
    raise "#{app_type} approval purpose blank" if AppIntake.approval_purpose_for(app_type).strip.empty?
    raise "#{app_type} missing data sources" if AppIntake.agent_data_sources_for(app_type).empty?
    raise "#{app_type} missing editable fields" if AppIntake.editable_fields_for(app_type).empty?
  end
end

check('composition recommendations stay separate from app type', failures) do
  expected = {
    ['planning', 'pg-home'] => :workbench,
    ['planning', 'pg-build'] => :builder_preview,
    ['planning', 'pg-review'] => :queue_rail,
    ['allocation', 'page-app'] => :builder_preview,
    ['approval', 'page-app'] => :queue_rail,
    ['exception', 'page-app'] => :queue_rail
  }
  expected.each do |(app_type, page_id), pattern|
    actual = AppIntake.composition_pattern_for(app_type, page_id)
    raise "#{app_type}/#{page_id}: expected #{pattern}, got #{actual}" unless actual == pattern
  end
end

check('composition recommendation rejects unknown app/page instead of guessing', failures) do
  begin
    AppIntake.composition_pattern_for('planning', 'missing-page')
    raise 'unknown page was accepted'
  rescue KeyError
    # expected
  end
  begin
    AppIntake.composition_pattern_for('crm')
    raise 'unknown app type was accepted'
  rescue KeyError
    # expected
  end
end

check('init refuses to overwrite an existing manifest', failures) do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'app-intake.json')
    AppIntake.write_template(path, 'approval')
    begin
      AppIntake.write_template(path, 'approval')
    rescue ArgumentError
      next
    end
    raise 'existing manifest was overwritten'
  end
end

check('init writes the requested appType', failures) do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'app-intake.json')
    AppIntake.write_template(path, 'exception')
    manifest = JSON.parse(File.read(path))
    raise "expected exception, got #{manifest['appType']}" unless manifest['appType'] == 'exception'
    raise 'wrong fixture' unless manifest['fixture'] == AppIntake.fixture_for('exception')
  end
end

{
  'Edit forecasts and compare scenarios' => 'planning',
  'Redistribute marketing budget across channels' => 'allocation',
  'Approve or reject pending deals' => 'approval',
  'Triage inventory exceptions and log resolution' => 'exception'
}.each do |phrase, app_type|
  check("classify #{phrase.inspect} → #{app_type}", failures) do
    result = AppIntake.classify(phrase)
    raise "expected #{app_type}, got #{result.inspect}" unless result && result['appType'] == app_type
    raise 'fixture mismatch' unless result['fixture'] == AppIntake.fixture_for(app_type)
  end
end

{
  'Sales KPI dashboard' => 'dashboard',
  'PDF invoice' => 'report'
}.each do |phrase, redirect|
  check("classify #{phrase.inspect} redirects to #{redirect}", failures) do
    result = AppIntake.classify(phrase)
    raise "expected redirect #{redirect}, got #{result.inspect}" unless result && result['redirect'] == redirect
  end
end

abort "#{failures.length} failure(s)" unless failures.empty?
puts 'All app-intake tests passed.'
