#!/usr/bin/env ruby
# frozen_string_literal: true

# Creds-free lint of the operational-app fixtures. Run from anywhere:
#   ruby sigma-workbooks/scripts/test-app-fixtures.rb

require 'yaml'
require_relative 'lib/app_intake'

failures = []

def check(name, failures)
  yield
  puts "PASS: #{name}"
rescue StandardError => e
  failures << "#{name}: #{e.message}"
  warn "FAIL: #{name}: #{e.message}"
end

SKILL_ROOT = AppIntake::SKILL_ROOT
UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i
PLACEHOLDERS = %w[<FOLDER_ID> <WRITE_CONNECTION_ID> <SOURCE_CONNECTION_ID>].freeze

REQUIRED_KINDS = {
  'planning' => {
    warehouse: true,
    empty_input: 2,
    linked_input: 1,
    join: true,
    insert_rows: true,
    update_rows: true,
    which_rows: true,
    hidden_page: true
  },
  'allocation' => {
    warehouse: true,
    empty_input: 1,
    linked_input: 1,
    join: false,
    insert_rows: true,
    hidden_page: true
  },
  'approval' => {
    warehouse: true,
    empty_input: 1,
    linked_input: 1,
    join: false,
    insert_rows: true,
    update_rows: true,
    which_rows: true,
    hidden_page: true
  },
  'exception' => {
    warehouse: true,
    empty_input: 1,
    linked_input: 1,
    join: false,
    insert_rows: true,
    hidden_page: true,
    recommendation: true
  }
}.freeze

def elements(doc)
  doc.fetch('document').fetch('elements')
end

def input_tables(doc)
  elements(doc).select { |el| el['kind'] == 'input-table' }
end

def buttons(doc)
  elements(doc).select { |el| el['kind'] == 'button' }
end

def effects(doc)
  buttons(doc).flat_map do |button|
    Array(button['actions']).flat_map { |action| Array(action['effects']) }
  end
end

def layout(doc)
  doc.fetch('document').fetch('layout').to_s
end

AppIntake::APP_TYPES.each do |app_type|
  rel = AppIntake.fixture_for(app_type)
  path = File.join(SKILL_ROOT, rel)
  raw = File.read(path)
  doc = YAML.safe_load(raw)
  req = REQUIRED_KINDS.fetch(app_type)

  check("#{app_type} fixture parses as a workbook spec", failures) do
    raise 'missing document.kind workbook' unless doc.dig('document', 'kind') == 'workbook'
    raise 'elements must be a non-empty array' unless elements(doc).is_a?(Array) && !elements(doc).empty?
    raise 'pages must be a non-empty array' unless doc.dig('document', 'pages').is_a?(Array) && !doc['document']['pages'].empty?
    raise 'layout must be present' if layout(doc).strip.empty?
  end

  check("#{app_type} fixture keeps placeholders and no live ids", failures) do
    PLACEHOLDERS.each do |token|
      raise "missing placeholder #{token}" unless raw.include?(token)
    end
    raise 'contains a UUID (live id?)' if raw.match?(UUID)
    raise 'contains a live app URL' if raw.match?(%r{https://app\.}i)
  end

  check("#{app_type} input tables use inputMode view", failures) do
    tables = input_tables(doc)
    raise 'expected at least one input-table' if tables.empty?

    tables.each do |table|
      raise "#{table['id']} missing inputMode" unless table['inputMode'] == 'view'
    end
  end

  check("#{app_type} fixture encodes required layers", failures) do
    warehouse = elements(doc).any? { |el| el.dig('source', 'kind') == 'warehouse-table' }
    raise 'missing warehouse-table source' if req[:warehouse] && !warehouse

    empty = input_tables(doc).count { |table| table.dig('source', 'kind') == 'empty' }
    raise "expected #{req[:empty_input]} empty input-table(s), got #{empty}" unless empty == req[:empty_input]

    linked = input_tables(doc).count { |table| table.dig('source', 'kind') == 'linked' }
    raise "expected #{req[:linked_input]} linked input-table(s), got #{linked}" unless linked == req[:linked_input]

    join = elements(doc).any? { |el| el.dig('source', 'kind') == 'join' }
    raise 'missing join matrix' if req[:join] && !join
    raise 'unexpected join' if req[:join] == false && join

    fx = effects(doc)
    raise 'missing insert-rows' if req[:insert_rows] && fx.none? { |effect| effect['effect'] == 'insert-rows' }
    raise 'missing update-rows' if req[:update_rows] && fx.none? { |effect| effect['effect'] == 'update-rows' }
    raise 'missing whichRows on the stable entity key' if req[:which_rows] && fx.none? { |effect| effect.key?('whichRows') }
    fx.each do |effect|
      next unless %w[insert-rows update-rows delete-rows].include?(effect['effect'])

      raise "#{effect['effect']} still uses stale table: — OpenAPI requires tableElementId" if effect.key?('table')
      raise "#{effect['effect']} missing tableElementId" unless effect.key?('tableElementId')
    end
    fx.select { |effect| effect['effect'] == 'clear-control' }.each do |effect|
      scope = effect['scope'] || {}
      raise 'clear-control still uses stale scope.page — OpenAPI requires pageId' if scope.key?('page')
      raise 'clear-control page scope missing pageId' if scope['type'] == 'page' && !scope.key?('pageId')
    end

    hidden = Array(doc.dig('document', 'pages')).any? { |page| page['visibility'] == 'hidden' }
    raise 'missing hidden source page' if req[:hidden_page] && !hidden
  end

  check("#{app_type} entry text controls carry the four required fields", failures) do
    elements(doc).select { |el| el['kind'] == 'control' }.each do |control|
      type = control['controlType'].to_s
      next unless %w[text text-area].include?(type)

      %w[mode case includeNulls showOperators].each do |field|
        raise "#{control['id']} (#{type}) missing #{field} — POST is Invalid kind: \"control\"" if
          control[field].nil? || (control[field].is_a?(String) && control[field].strip.empty?)
      end
    end
  end

  check("#{app_type} fixture is architecture, not a stamped dashboard look", failures) do
    raise 'stamped hero container — fixtures must not ship the exec-dashboard chrome' if
      elements(doc).any? { |el| el['id'] == 'hero' && el['kind'] == 'container' }
    raise 'stamped settings.theme — compose theme in generate-apps Step D.4' if
      doc.dig('document', 'settings', 'theme')
  end

  check("#{app_type} fixture stays agent-free", failures) do
    raise 'fixtures must not ship document.agents — compose in generate-apps Step D.5' if
      doc.dig('document', 'agents')
    raise 'fixtures must not ship a chat element' if
      elements(doc).any? { |el| el['kind'] == 'chat' }
  end

  check("#{app_type} recommended agent data sources exist on the fixture", failures) do
    ids = elements(doc).map { |el| el['id'] }
    AppIntake.agent_data_sources_for(app_type).each do |element_id|
      raise "agent data source #{element_id} missing from fixture" unless ids.include?(element_id)
    end
  end

  check("#{app_type} recommended editable fields are type columns on the linked grid", failures) do
    linked = input_tables(doc).find { |table| table.dig('source', 'kind') == 'linked' }
    raise 'missing linked input-table' unless linked

    names = Array(linked['columns']).select { |col| col['type'] }.map { |col| col['name'] }
    AppIntake.editable_fields_for(app_type).each do |name|
      raise "#{name.inspect} is not a type column on #{linked['id']}" unless names.include?(name)
    end
  end

  check("#{app_type} layout places every element", failures) do
    xml = layout(doc)
    elements(doc).each do |el|
      id = el.fetch('id')
      raise "layout missing elementId=#{id}" unless xml.include?(%(elementId="#{id}"))
    end
    Array(doc.dig('document', 'pages')).each do |page|
      id = page.fetch('id')
      raise "layout missing Page id=#{id}" unless xml.include?(%(id="#{id}"))
    end
  end
end

check('exception fixture uses a policy recommendation, not an AI label', failures) do
  path = File.join(SKILL_ROOT, AppIntake.fixture_for('exception'))
  doc = YAML.safe_load(File.read(path))
  queue = input_tables(doc).find { |table| table.dig('source', 'kind') == 'linked' }
  raise 'missing linked action queue' unless queue

  names = Array(queue['columns']).map { |col| col['name'].to_s }
  raise 'recommendation labeled AI' if names.any? { |name| name.match?(/\bAI\b/i) }
  raise 'missing Suggested Order' unless names.include?('Suggested Order')
  raise 'missing Final Order' unless names.include?('Final Order')

  final = Array(queue['columns']).find { |col| col['name'] == 'Final Order' }
  raise 'Final Order must Coalesce override over suggestion' unless
    final['formula'].to_s.include?('Coalesce') && final['formula'].to_s.include?('Override')
end

check('approval whichRows uses the entity key', failures) do
  path = File.join(SKILL_ROOT, AppIntake.fixture_for('approval'))
  doc = YAML.safe_load(File.read(path))
  update = effects(doc).find { |effect| effect['effect'] == 'update-rows' }
  raise 'missing update-rows' unless update

  formula = update.dig('whichRows', 'formula').to_s
  raise "whichRows must key on Deal ID, got #{formula.inspect}" unless formula.include?('[Deal ID]')
end

check('planning grid keys stable context only', failures) do
  path = File.join(SKILL_ROOT, AppIntake.fixture_for('planning'))
  doc = YAML.safe_load(File.read(path))
  grid = elements(doc).find { |el| el['id'] == 'plan-grid' }
  raise 'missing plan-grid' unless grid

  key_names = Array(grid['columns']).select { |col| col['key'] }.map { |col| col['name'] }
  %w[Scenario Period Line\ Item Section Baseline].each do |name|
    raise "plan-grid missing key #{name}" unless key_names.include?(name)
  end
  bad = key_names & ['Status', 'Owner']
  raise "volatile key columns #{bad.inspect}" unless bad.empty?
end

check('planning fixture is a studio shell, not a one-page grid', failures) do
  path = File.join(SKILL_ROOT, AppIntake.fixture_for('planning'))
  raw = File.read(path)
  doc = YAML.safe_load(raw)
  page_ids = Array(doc.dig('document', 'pages')).map { |page| page['id'] }
  %w[pg-home pg-scenarios pg-build pg-review pg-data].each do |page_id|
    raise "missing page #{page_id}" unless page_ids.include?(page_id)
  end
  raise 'planning fixture must not ship a Guide page' if page_ids.include?('pg-guide')
  overlays = Array(doc.dig('document', 'overlays'))
  raise 'missing New Scenario overlay' unless overlays.any? { |overlay| overlay['id'] == 'ov-new' }
  raise 'layout missing overlay page ov-new' unless layout(doc).include?(%(id="ov-new"))
  ids = elements(doc).map { |el| el['id'] }
  raise 'missing plan-ledger' unless ids.include?('plan-ledger')
  raise 'missing agent-rail placeholder' unless ids.include?('txt-agent-rail')
  raise 'fixture must not ship a chat element' if elements(doc).any? { |el| el['kind'] == 'chat' }
  fx = effects(doc)
  raise 'missing open-overlay' if fx.none? { |effect| effect['effect'] == 'open-overlay' }
  create = fx.find { |effect| effect['effect'] == 'insert-rows' && effect['tableElementId'] == 'scenarios' }
  raise 'missing create-scenario insert into the scenarios table' unless create
  status = fx.select { |effect| effect['effect'] == 'update-rows' }
  raise 'planning review buttons must update-rows scenario status' if status.empty?
  status.each do |effect|
    formula = effect.dig('whichRows', 'formula').to_s
    raise "status whichRows must key on Scenario Name, got #{formula.inspect}" unless
      formula.include?('[Scenario Name]')
  end
  raise 'stamped indigo fillColor' if raw.include?('#4f46e5') || raw.include?('#0f172a')
  raise 'stamped FY26 copy' if raw.include?('FY26') || raw.include?('FY2026')
end

{
  'Edit forecasts and compare scenarios' => 'planning',
  'Redistribute headcount across departments' => 'allocation',
  'Approve or reject pending deals' => 'approval',
  'Triage inventory exceptions and log resolution' => 'exception'
}.each do |phrase, app_type|
  check("classifier maps #{phrase.inspect} to #{app_type} fixture", failures) do
    result = AppIntake.classify(phrase)
    expected = AppIntake.fixture_for(app_type)
    raise "expected #{expected}, got #{result.inspect}" unless result && result['fixture'] == expected
    path = File.join(SKILL_ROOT, expected)
    raise "fixture missing on disk: #{expected}" unless File.file?(path)
  end
end

check('generate-apps PNG fail list encodes input and Dark constraints', failures) do
  path = File.join(SKILL_ROOT, 'reference/workflows/generate-apps.md')
  text = File.read(path)
  %w[
    white-on-white Dark-on-dark 3-KPI strip data-entry app plan measures
    empty work surface Unknown column truncated primary headers
    empty audit/log table visually dominant work surface
  ].each do |needle|
    raise "missing constraint #{needle.inspect}" unless text.include?(needle)
  end
end

check('generate-apps interviews for fields, approvals, and agent', failures) do
  path = File.join(SKILL_ROOT, 'reference/workflows/generate-apps.md')
  text = File.read(path)
  %w[
    Interview before building
    Editable fields (all types)
    Does this workflow need approvals?
    Add a workbook agent?
    Analyze
    Configure
    Navigate
    Act
    agent_capabilities_for
    agent_action_tool
    authoritative audit/read path
    zero-row delta
    exactly-one-row delta
    supporting rail
  ].each do |needle|
    raise "missing interview #{needle.inspect}" unless text.include?(needle)
  end
end

check('generate-apps selects an operational composition and writes a design manifest', failures) do
  path = File.join(SKILL_ROOT, 'reference/workflows/generate-apps.md')
  text = File.read(path)
  [
    'app-compositions.md',
    'workbench',
    'queue-rail',
    'builder-preview',
    '/tmp/app-design-manifest.yaml',
    'Inspect at least two renders'
  ].each do |needle|
    raise "missing operational composition requirement #{needle.inspect}" unless text.include?(needle)
  end
end

check('app-compositions separates visual work mode from semantic architecture', failures) do
  path = File.join(SKILL_ROOT, 'reference/workflows/app-compositions.md')
  text = File.read(path)
  [
    'semantic architecture',
    'visual composition',
    'workSurface',
    'primaryAction',
    'aboveFold',
    'workbench',
    'queue_rail',
    'builder_preview',
    'Three-pass build',
    'Styling.app_shell',
    'oversized report title',
    'truncated headers',
    'empty audit/log table'
  ].each do |needle|
    raise "missing app-composition contract #{needle.inspect}" unless text.include?(needle)
  end
end

abort "#{failures.length} failure(s)" unless failures.empty?
puts 'All app-fixture tests passed.'
