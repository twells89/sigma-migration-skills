#!/usr/bin/env ruby
# frozen_string_literal: true

# Local intake manifest for question-driven operational-app builds.
# Stdlib only; customer table paths and org identifiers stay outside the
# skill tree.

require 'json'

module AppIntake
  SKILL_ROOT = File.expand_path('../..', __dir__)

  APP_TYPES = %w[planning allocation approval exception].freeze
  REDIRECTS = %w[dashboard report].freeze

  GRAIN_KEYS = {
    'planning' => %w[scenario period planningLine],
    'allocation' => %w[period allocationDimension],
    'approval' => %w[entity],
    'exception' => %w[operationalEntity]
  }.freeze

  RECIPES = {
    'planning' => 'reference/workflows/planning-apps.md',
    'allocation' => 'reference/workflows/allocation-apps.md',
    'approval' => 'reference/workflows/approval-apps.md',
    'exception' => 'reference/workflows/exception-apps.md'
  }.freeze

  FIXTURES = {
    'planning' => 'reference/workflows/fixtures/planning-app.yaml',
    'allocation' => 'reference/workflows/fixtures/allocation-app.yaml',
    'approval' => 'reference/workflows/fixtures/approval-app.yaml',
    'exception' => 'reference/workflows/fixtures/exception-app.yaml'
  }.freeze

  # Visual work mode is deliberately separate from semantic app type. Planning
  # has different page jobs; the other fixture shells currently have one
  # visible app page. Callers may override this recommendation after writing
  # the local app-design manifest.
  COMPOSITION_BY_PAGE = {
    'planning' => {
      'pg-home' => :workbench,
      'pg-build' => :builder_preview,
      'pg-review' => :queue_rail
    },
    'allocation' => { 'page-app' => :builder_preview },
    'approval' => { 'page-app' => :queue_rail },
    'exception' => { 'page-app' => :queue_rail }
  }.freeze

  REDIRECT_LOAD = {
    'dashboard' => 'reference/workflows/composition.md',
    'report' => 'sigma-reports'
  }.freeze

  REDIRECT_RULES = [
    { type: 'report', patterns: [/\binvoice\b/i, /\bstatement\b/i, /\bpdf\b/i, /\bprintable\b/i, /\bfixed[- ]layout\b/i] },
    { type: 'dashboard', patterns: [/\bdashboard\b/i, /\bkpi overview\b/i, /\bread[- ]only\b/i, /\bexec(utive)? overview\b/i] }
  ].freeze

  APP_RULES = [
    { type: 'allocation', patterns: [/\ballocat/i, /\bheadcount\b/i, /\bquota\b/i, /\bcapacit/i, /\bredistribut/i, /\bterritor/i] },
    { type: 'approval', patterns: [/\bapprov/i, /\breject\b/i, /\bcounter[- ]value\b/i, /\bdecision queue\b/i, /\bpending (deals|requests)\b/i] },
    { type: 'exception', patterns: [/\bexception\b/i, /\btriage\b/i, /\breplenish/i, /\bsla breach/i, /\banomal/i] },
    { type: 'planning', patterns: [/\bforecast/i, /\bscenario/i, /\bassumption/i, /\bbudget/i, /\bworking plan\b/i, /\bfp&a\b/i] }
  ].freeze

  ANSWER_KEYS = {
    'planning' => %w[mode filterPropagation],
    'allocation' => %w[allocationDimension],
    'approval' => %w[allowedDecisions],
    'exception' => %w[override]
  }.freeze

  # Recommended `{ id, type }` columns on the linked grid. Keys and
  # formulas stay non-editable. See generate-apps.md Step B.
  EDITABLE_FIELDS = {
    'planning' => ['Method', 'Pct Change', 'Dollar Change', 'New Amount', 'Rationale'],
    'allocation' => ['Added Hires', 'Cost Uplift %', 'Rationale'],
    'approval' => ['Decision', 'Approved Discount', 'Reviewer', 'Decision Note'],
    'exception' => ['Override Order Qty', 'Decision', 'Owner', 'Resolution Note']
  }.freeze

  # Recommended approval/submit/log layer per type. Fixtures include this
  # layer; generate-apps Step B asks whether to keep it.
  APPROVAL_PURPOSES = {
    'planning' => 'submit, approve, or request changes: append an immutable decision-log row and update only that scenario status via whichRows',
    'allocation' => 'log a hiring or reallocation request to the request log (approvals stay off the editable plan grid)',
    'approval' => 'record Approve / Reject / Counter: append an audit-log row and update only the selected entity via whichRows on the stable key',
    'exception' => 'log a resolution: append an immutable resolution-log row for the selected operational entity'
  }.freeze

  AUDIENCES = {
    'planning' => 'FP&A planner',
    'allocation' => 'ops or finance owner',
    'approval' => 'reviewer',
    'exception' => 'ops owner'
  }.freeze

  # Fixture element ids the type's agent may query (dataSources).
  AGENT_DATA_SOURCES = {
    'planning' => %w[plan-grid plan-ledger scenarios decision-log],
    'allocation' => %w[alloc-grid request-log],
    'approval' => %w[deal-directory review-queue decision-log],
    'exception' => %w[exception-directory action-queue resolution-log]
  }.freeze

  # Recommended workbook-agent purpose per type. Analyze = dataSources;
  # Act = tools[] (omit for read-only). Write tools always require
  # requiresApproval: true — see reference/specification/agents.md.
  AGENT_PURPOSES = {
    'planning' => {
      'analyze' => 'plan grid, plan ledger (actuals vs plan), scenario directory, and decision log — distinguish actual vs baseline vs selected plan; compare only scenario-keyed rows',
      'act' => 'read-only unless they asked the agent to submit or log; any write tool sets requiresApproval: true and must not claim a write without that confirmation'
    },
    'allocation' => {
      'analyze' => 'allocation grid, working allocation, variance, and request log — which dimension is over/under, whether variance is baseline underfunding vs added units, concentration and tradeoffs',
      'act' => 'read-only unless they asked the agent to log a request; any write tool sets requiresApproval: true'
    },
    'approval' => {
      'analyze' => 'entity directory, review queue, and decision log — prioritize by policy breach, value at risk, and age; name the highest-risk pending entity',
      'act' => 'do not record a decision unless they asked for that tool; any write tool sets requiresApproval: true and must not claim a decision was written without confirmation'
    },
    'exception' => {
      'analyze' => 'exception directory and action queue — rank unresolved items by urgency and impact, skip already-logged resolutions, distinguish source risk from the user-entered override',
      'act' => 'log-resolution (or equivalent) action tool with requiresApproval: true'
    }
  }.freeze

  # Prefilled Analyze / Configure / Navigate / Act interview. Element/control
  # ids match the architecture fixtures; the builder must remove capabilities
  # whose targets were dropped or renamed after discovery. `act.tools` are
  # intent labels, not already-shaped tool specs.
  AGENT_CAPABILITY_PROFILES = {
    'planning' => {
      'profile' => 'operator',
      'analyze' => { 'dataSources' => %w[plan-grid plan-ledger scenarios decision-log] },
      'configure' => { 'controls' => %w[scenario] },
      'navigate' => { 'pages' => %w[pg-home pg-scenarios pg-build pg-review], 'tabs' => [] },
      'act' => {
        'tools' => %w[submit-plan record-review-decision],
        'requiresApproval' => true
      }
    },
    'allocation' => {
      'profile' => 'operator',
      'analyze' => { 'dataSources' => %w[alloc-grid request-log] },
      'configure' => { 'controls' => %w[periodControl dimControl] },
      'navigate' => { 'pages' => [], 'tabs' => [] },
      'act' => { 'tools' => %w[log-allocation-request], 'requiresApproval' => true }
    },
    'approval' => {
      'profile' => 'operator',
      'analyze' => { 'dataSources' => %w[deal-directory review-queue decision-log] },
      'configure' => { 'controls' => %w[dealControl decisionControl noteControl] },
      'navigate' => { 'pages' => [], 'tabs' => [] },
      'act' => { 'tools' => %w[record-decision], 'requiresApproval' => true }
    },
    'exception' => {
      'profile' => 'operator',
      'analyze' => { 'dataSources' => %w[exception-directory action-queue resolution-log] },
      'configure' => { 'controls' => %w[skuControl decisionControl noteControl] },
      'navigate' => { 'pages' => [], 'tabs' => [] },
      'act' => { 'tools' => %w[log-resolution], 'requiresApproval' => true }
    }
  }.freeze

  module_function

  def recipe_for(app_type)
    RECIPES[app_type]
  end

  def fixture_for(app_type)
    FIXTURES[app_type]
  end

  def composition_pattern_for(app_type, page_id = nil)
    pages = COMPOSITION_BY_PAGE.fetch(app_type)
    return pages.fetch(page_id) if page_id

    pages.values.first
  end

  def agent_purpose_for(app_type)
    purpose = AGENT_PURPOSES.fetch(app_type)
    "Analyze: #{purpose['analyze']}. Act: #{purpose['act']}."
  end

  def editable_fields_for(app_type)
    EDITABLE_FIELDS.fetch(app_type).dup
  end

  def approval_purpose_for(app_type)
    APPROVAL_PURPOSES.fetch(app_type)
  end

  def audience_for(app_type)
    AUDIENCES.fetch(app_type)
  end

  def agent_data_sources_for(app_type)
    AGENT_DATA_SOURCES.fetch(app_type).dup
  end

  def agent_capabilities_for(app_type)
    Marshal.load(Marshal.dump(AGENT_CAPABILITY_PROFILES.fetch(app_type)))
  end

  def route_for(app_type)
    return nil unless APP_TYPES.include?(app_type)

    {
      'appType' => app_type,
      'recipe' => recipe_for(app_type),
      'fixture' => fixture_for(app_type)
    }
  end

  def classify(text)
    blob = text.to_s
    REDIRECT_RULES.each do |rule|
      next unless rule[:patterns].any? { |pattern| blob.match?(pattern) }

      return {
        'redirect' => rule[:type],
        'load' => REDIRECT_LOAD.fetch(rule[:type])
      }
    end
    APP_RULES.each do |rule|
      next unless rule[:patterns].any? { |pattern| blob.match?(pattern) }

      return route_for(rule[:type])
    end
    nil
  end

  def template_for(app_type = 'planning')
    raise ArgumentError, "unknown appType #{app_type.inspect}; allowed: #{APP_TYPES.join(', ')}" unless
      APP_TYPES.include?(app_type)

    answers = { 'rowGrain' => nil, 'governedSource' => true, 'sparseOverrides' => true, 'loadMethod' => 'interactive' }
    case app_type
    when 'planning'
      answers['mode'] = 'scenario-planning'
      answers['filterPropagation'] = 'option-a'
      answers['rowGrain'] = 'Scenario × Period × Planning Line'
    when 'allocation'
      answers['allocationDimension'] = 'Department'
      answers['rowGrain'] = 'Period × Allocation Dimension'
    when 'approval'
      answers['allowedDecisions'] = %w[Approved Rejected Counter]
      answers['counterValue'] = true
      answers['rowGrain'] = 'one row per entity key'
    when 'exception'
      answers['override'] = true
      answers['compositeKey'] = false
      answers['rowGrain'] = 'one row per operational entity'
    end

    {
      'schemaVersion' => 1,
      'appType' => app_type,
      'recipe' => recipe_for(app_type),
      'fixture' => fixture_for(app_type),
      'answers' => answers,
      'audience' => audience_for(app_type),
      'editableFields' => editable_fields_for(app_type),
      'sources' => {
        'connectionId' => nil,
        'tablePath' => nil,
        'writeConnectionId' => nil
      },
      'approvals' => {
        'include' => true,
        'purpose' => approval_purpose_for(app_type)
      },
      'agent' => {
        'include' => false,
        'purpose' => agent_purpose_for(app_type),
        'capabilities' => agent_capabilities_for(app_type)
      },
      'grain' => {
        'keys' => GRAIN_KEYS.fetch(app_type).dup,
        'expectedRows' => nil
      }
    }
  end

  TEMPLATE = template_for('planning').freeze

  def errors(manifest, strict: false)
    out = []
    unless manifest.is_a?(Hash)
      return ['root must be a JSON object']
    end

    out << 'schemaVersion must be 1' unless manifest['schemaVersion'] == 1
    app_type = manifest['appType']
    unless APP_TYPES.include?(app_type)
      out << "appType must be one of: #{APP_TYPES.join(', ')}"
      return out
    end

    expected_recipe = recipe_for(app_type)
    expected_fixture = fixture_for(app_type)
    out << "recipe must be #{expected_recipe}" unless manifest['recipe'] == expected_recipe
    out << "fixture must be #{expected_fixture}" unless manifest['fixture'] == expected_fixture

    recipe_path = File.join(SKILL_ROOT, expected_recipe)
    fixture_path = File.join(SKILL_ROOT, expected_fixture)
    out << "recipe file missing: #{expected_recipe}" unless File.file?(recipe_path)
    out << "fixture file missing: #{expected_fixture}" unless File.file?(fixture_path)

    answers = manifest['answers']
    if answers.is_a?(Hash)
      ANSWER_KEYS.fetch(app_type).each do |key|
        value = answers[key]
        out << "answers.#{key} must be present for #{app_type}" if value.nil? || (value.is_a?(String) && value.strip.empty?)
      end
    else
      out << 'answers must be an object'
    end

    sources = manifest['sources']
    if sources.is_a?(Hash)
      %w[connectionId tablePath writeConnectionId].each do |key|
        next if sources.key?(key)

        out << "sources.#{key} must be present (use null until discovery)"
      end
      if strict
        %w[connectionId writeConnectionId].each do |key|
          out << "sources.#{key} must be a non-empty string" unless
            sources[key].is_a?(String) && !sources[key].strip.empty?
        end
        path = sources['tablePath']
        out << 'sources.tablePath must be a non-empty array of path segments' unless
          path.is_a?(Array) && !path.empty? && path.all? { |segment| segment.is_a?(String) && !segment.strip.empty? }
      end
    else
      out << 'sources must be an object'
    end

    audience = manifest['audience']
    out << 'audience must be a non-empty string' unless
      audience.is_a?(String) && !audience.strip.empty?

    fields = manifest['editableFields']
    out << 'editableFields must be a non-empty array of field names' unless
      fields.is_a?(Array) && !fields.empty? && fields.all? { |name| name.is_a?(String) && !name.strip.empty? }

    approvals = manifest['approvals']
    if approvals.is_a?(Hash)
      unless [true, false].include?(approvals['include'])
        out << 'approvals.include must be true or false'
      end
      if approvals['include'] == true
        purpose = approvals['purpose']
        out << 'approvals.purpose must be a non-empty string when include is true' if
          purpose.nil? || (purpose.is_a?(String) && purpose.strip.empty?)
      end
    else
      out << 'approvals must be an object'
    end

    agent = manifest['agent']
    if agent.is_a?(Hash)
      unless [true, false].include?(agent['include'])
        out << 'agent.include must be true or false'
      end
      if agent['include'] == true
        purpose = agent['purpose']
        out << 'agent.purpose must be a non-empty string when include is true' if
          purpose.nil? || (purpose.is_a?(String) && purpose.strip.empty?)
      end
      capabilities = agent['capabilities']
      if capabilities.is_a?(Hash)
        %w[profile analyze configure navigate act].each do |key|
          out << "agent.capabilities.#{key} must be present" unless capabilities.key?(key)
        end
        data_sources = capabilities.dig('analyze', 'dataSources')
        out << 'agent.capabilities.analyze.dataSources must be an array' unless data_sources.is_a?(Array)
        controls = capabilities.dig('configure', 'controls')
        out << 'agent.capabilities.configure.controls must be an array' unless controls.is_a?(Array)
        pages = capabilities.dig('navigate', 'pages')
        tabs = capabilities.dig('navigate', 'tabs')
        out << 'agent.capabilities.navigate.pages must be an array' unless pages.is_a?(Array)
        out << 'agent.capabilities.navigate.tabs must be an array' unless tabs.is_a?(Array)
        tools = capabilities.dig('act', 'tools')
        out << 'agent.capabilities.act.tools must be an array' unless tools.is_a?(Array)
        if tools.is_a?(Array) && !tools.empty? && capabilities.dig('act', 'requiresApproval') != true
          out << 'agent.capabilities.act.requiresApproval must be true when write tools are proposed'
        end
      else
        out << 'agent.capabilities must be an object'
      end
    else
      out << 'agent must be an object'
    end

    grain = manifest['grain']
    if grain.is_a?(Hash)
      keys = grain['keys']
      required = GRAIN_KEYS.fetch(app_type)
      if keys.is_a?(Array) && keys.all? { |key| key.is_a?(String) }
        missing = required - keys
        out << "grain.keys must include #{required.join(', ')} for #{app_type}" unless missing.empty?
      else
        out << 'grain.keys must be an array of strings'
      end
      if strict
        out << 'grain.expectedRows must be a positive number' unless
          grain['expectedRows'].is_a?(Numeric) && grain['expectedRows'].positive?
      end
    else
      out << 'grain must be an object'
    end

    out
  end

  def write_template(path, app_type = 'planning')
    raise ArgumentError, "#{path} already exists" if File.exist?(path)

    File.write(path, JSON.pretty_generate(template_for(app_type)) + "\n")
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  strict = ARGV.delete('--strict')
  path = ARGV.shift
  app_type = ARGV.shift || 'planning'

  valid_init = command == 'init' && path && (ARGV.empty? || APP_TYPES.include?(app_type) && ARGV.empty?)
  valid_validate = command == 'validate' && path && ARGV.empty?
  unless valid_init || valid_validate
    warn 'Usage: ruby scripts/lib/app_intake.rb init <manifest.json> [appType]'
    warn '   or: ruby scripts/lib/app_intake.rb validate [--strict] <manifest.json>'
    exit 2
  end

  if command == 'init'
    unless AppIntake::APP_TYPES.include?(app_type)
      warn "unknown appType #{app_type.inspect}; allowed: #{AppIntake::APP_TYPES.join(', ')}"
      exit 2
    end
    begin
      AppIntake.write_template(path, app_type)
    rescue ArgumentError => e
      warn "app-intake: #{e.message}"
      exit 1
    end
    puts "Wrote #{path}"
    exit 0
  end

  begin
    manifest = JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError => e
    warn "app-intake: #{e.message}"
    exit 1
  end

  errors = AppIntake.errors(manifest, strict: !strict.nil?)
  if errors.empty?
    puts "OK: #{path}#{strict ? ' (strict)' : ''}"
    exit 0
  end

  errors.each { |error| warn "ERROR: #{error}" }
  exit 1
end
