#!/usr/bin/env ruby
# frozen_string_literal: true

# Local planning/completion manifest for screenshot/mockup-driven workbook
# builds. Stdlib only; customer artifacts and org identifiers stay outside the
# skill tree.

require 'json'

module DesignArtifact
  IMPLEMENTATIONS = %w[native-spec ui-only plugin unavailable].freeze
  VERDICTS = %w[pending pass fail accepted-gap].freeze
  SEVERITIES = %w[low medium high].freeze
  MISMATCH_STATUSES = %w[open fixed accepted].freeze

  TEMPLATE = {
    'schemaVersion' => 1,
    'artifacts' => [
      {
        'id' => 'target-1',
        'path' => '/absolute/path/to/target.png',
        'viewport' => { 'width' => 1440, 'height' => 900 }
      }
    ],
    'workbooks' => [
      {
        'name' => 'Workbook name',
        'artifactRefs' => ['target-1'],
        'boundaryDecision' => 'One separate workbook for this app surface.',
        'surfaces' => [
          {
            'id' => 'app-shell',
            'target' => 'Left rail, breadcrumb, title row, actions, and tabs',
            'sigmaKind' => 'container/text/button',
            'implementation' => 'native-spec',
            'acceptance' => 'Rendered geometry and active states match the artifact.'
          },
          {
            'id' => 'primary-data',
            'target' => 'Primary data visualization or editable grid',
            'sigmaKind' => 'bar-chart',
            'implementation' => 'native-spec',
            'acceptance' => 'Kind, channels, values, labels, and density match.'
          }
        ],
        'interactions' => [
          {
            'id' => 'primary-interaction',
            'expectedBehavior' => 'Describe the button/control/edit behavior.',
            'implementation' => 'native-spec',
            'verification' => 'pending',
            'evidence' => ''
          }
        ],
        'visual' => {
          'renders' => [
            { 'stage' => 'first', 'path' => '', 'reviewed' => false },
            { 'stage' => 'final', 'path' => '', 'reviewed' => false }
          ],
          'mismatches' => [
            {
              'id' => 'example-gap',
              'severity' => 'high',
              'status' => 'open',
              'description' => 'Replace with a real first-render mismatch.'
            }
          ],
          'acceptedTradeoffs' => []
        },
        'runtime' => {
          'specVerify' => 'pending',
          'compile' => 'pending',
          'dataParity' => 'pending',
          'controls' => 'pending',
          'writeback' => 'accepted-gap',
          'agent' => 'accepted-gap'
        }
      }
    ]
  }.freeze

  module_function

  def errors(manifest, strict: false)
    out = []
    unless manifest.is_a?(Hash)
      return ['root must be a JSON object']
    end

    out << 'schemaVersion must be 1' unless manifest['schemaVersion'] == 1
    artifacts = manifest['artifacts']
    out << 'artifacts must be a non-empty array' unless artifacts.is_a?(Array) && !artifacts.empty?
    artifact_ids = []
    if artifacts.is_a?(Array)
      artifacts.each_with_index do |artifact, index|
        at = "artifacts[#{index}]"
        unless artifact.is_a?(Hash)
          out << "#{at} must be an object"
          next
        end
        require_string(artifact, 'id', at, out)
        require_string(artifact, 'path', at, out)
        artifact_ids << artifact['id'] if artifact['id'].is_a?(String)
        viewport = artifact['viewport']
        unless viewport.is_a?(Hash) &&
               viewport['width'].is_a?(Numeric) && viewport['width'].positive? &&
               viewport['height'].is_a?(Numeric) && viewport['height'].positive?
          out << "#{at}.viewport must contain positive numeric width and height"
        end
      end
    end
    out << 'artifact ids must be unique' if artifact_ids.uniq.length != artifact_ids.length

    workbooks = manifest['workbooks']
    out << 'workbooks must be a non-empty array' unless workbooks.is_a?(Array) && !workbooks.empty?
    return out unless workbooks.is_a?(Array)

    workbooks.each_with_index do |workbook, index|
      wb = "workbooks[#{index}]"
      unless workbook.is_a?(Hash)
        out << "#{wb} must be an object"
        next
      end

      require_string(workbook, 'name', wb, out)
      require_string(workbook, 'boundaryDecision', wb, out)
      refs = workbook['artifactRefs']
      if !refs.is_a?(Array) || refs.empty? || refs.any? { |ref| !artifact_ids.include?(ref) }
        out << "#{wb}.artifactRefs must be a non-empty array of known artifact ids"
      end

      surfaces = workbook['surfaces']
      if !surfaces.is_a?(Array) || surfaces.empty?
        out << "#{wb}.surfaces must be a non-empty array"
      else
        surfaces.each_with_index do |surface, surface_index|
          sf = "#{wb}.surfaces[#{surface_index}]"
          unless surface.is_a?(Hash)
            out << "#{sf} must be an object"
            next
          end
          %w[id target sigmaKind acceptance].each { |key| require_string(surface, key, sf, out) }
          enum(surface, 'implementation', IMPLEMENTATIONS, sf, out)
        end
      end

      interactions = workbook['interactions']
      if !interactions.is_a?(Array)
        out << "#{wb}.interactions must be an array (use [] only when the artifact has no behavior)"
      else
        interactions.each_with_index do |interaction, interaction_index|
          ix = "#{wb}.interactions[#{interaction_index}]"
          unless interaction.is_a?(Hash)
            out << "#{ix} must be an object"
            next
          end
          %w[id expectedBehavior].each { |key| require_string(interaction, key, ix, out) }
          enum(interaction, 'implementation', IMPLEMENTATIONS, ix, out)
          enum(interaction, 'verification', VERDICTS, ix, out)
          if strict && interaction['verification'] == 'pending'
            out << "#{ix}.verification is still pending"
          end
          if strict && interaction['verification'] == 'pass' && interaction['evidence'].to_s.strip.empty?
            out << "#{ix}.evidence is required for a passing interaction"
          end
        end
      end

      validate_visual(workbook['visual'], wb, out, strict: strict)
      validate_runtime(workbook['runtime'], wb, out, strict: strict)
    end

    out
  end

  def validate_visual(visual, wb, out, strict:)
    unless visual.is_a?(Hash)
      out << "#{wb}.visual must be an object"
      return
    end

    renders = visual['renders']
    unless renders.is_a?(Array)
      out << "#{wb}.visual.renders must be an array"
      renders = []
    end
    renders.each_with_index do |render, index|
      at = "#{wb}.visual.renders[#{index}]"
      unless render.is_a?(Hash)
        out << "#{at} must be an object"
        next
      end
      require_string(render, 'stage', at, out)
      next unless strict

      require_string(render, 'path', at, out)
      out << "#{at}.reviewed must be true" unless render['reviewed'] == true
    end
    if strict
      stages = renders.map { |render| render['stage'] if render.is_a?(Hash) }.compact
      out << "#{wb}.visual.renders needs reviewed first and final renders" unless
        stages.include?('first') && stages.include?('final')
    end

    mismatches = visual['mismatches']
    unless mismatches.is_a?(Array)
      out << "#{wb}.visual.mismatches must be an array"
      mismatches = []
    end
    mismatches.each_with_index do |mismatch, index|
      at = "#{wb}.visual.mismatches[#{index}]"
      unless mismatch.is_a?(Hash)
        out << "#{at} must be an object"
        next
      end
      %w[id description].each { |key| require_string(mismatch, key, at, out) }
      enum(mismatch, 'severity', SEVERITIES, at, out)
      enum(mismatch, 'status', MISMATCH_STATUSES, at, out)
      if strict && mismatch['severity'] == 'high' && mismatch['status'] == 'open'
        out << "#{at} is an unresolved high-severity mismatch"
      end
    end

    tradeoffs = visual['acceptedTradeoffs']
    out << "#{wb}.visual.acceptedTradeoffs must be an array" unless tradeoffs.is_a?(Array)
  end

  def validate_runtime(runtime, wb, out, strict:)
    unless runtime.is_a?(Hash)
      out << "#{wb}.runtime must be an object"
      return
    end

    %w[specVerify compile dataParity controls writeback agent].each do |gate|
      enum(runtime, gate, VERDICTS, "#{wb}.runtime", out)
    end
    return unless strict

    %w[specVerify compile dataParity].each do |gate|
      out << "#{wb}.runtime.#{gate} must pass" unless runtime[gate] == 'pass'
    end
    %w[controls writeback agent].each do |gate|
      next if %w[pass accepted-gap].include?(runtime[gate])

      out << "#{wb}.runtime.#{gate} must pass or be an accepted gap"
    end
  end

  def require_string(hash, key, prefix, out)
    out << "#{prefix}.#{key} must be a non-empty string" unless
      hash[key].is_a?(String) && !hash[key].strip.empty?
  end

  def enum(hash, key, allowed, prefix, out)
    out << "#{prefix}.#{key} must be one of: #{allowed.join(', ')}" unless allowed.include?(hash[key])
  end

  def write_template(path)
    raise ArgumentError, "#{path} already exists" if File.exist?(path)

    File.write(path, JSON.pretty_generate(TEMPLATE) + "\n")
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  strict = ARGV.delete('--strict')
  path = ARGV.shift
  unless %w[init check].include?(command) && path && ARGV.empty?
    warn 'Usage: ruby scripts/design-artifact.rb init <manifest.json>'
    warn '   or: ruby scripts/design-artifact.rb check [--strict] <manifest.json>'
    exit 2
  end

  if command == 'init'
    DesignArtifact.write_template(path)
    puts "Wrote #{path}"
    exit 0
  end

  begin
    manifest = JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError => e
    warn "design-artifact: #{e.message}"
    exit 1
  end

  errors = DesignArtifact.errors(manifest, strict: !strict.nil?)
  if errors.empty?
    puts "OK: #{path}#{strict ? ' (strict)' : ''}"
    exit 0
  end

  errors.each { |error| warn "ERROR: #{error}" }
  exit 1
end
