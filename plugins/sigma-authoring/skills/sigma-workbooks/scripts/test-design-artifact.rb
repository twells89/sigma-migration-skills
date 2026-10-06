#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'design-artifact'

failures = []

def check(name, failures)
  yield
  puts "PASS: #{name}"
rescue StandardError => e
  failures << "#{name}: #{e.message}"
  warn "FAIL: #{name}: #{e.message}"
end

check('template passes planning validation', failures) do
  errors = DesignArtifact.errors(JSON.parse(JSON.generate(DesignArtifact::TEMPLATE)))
  raise errors.join('; ') unless errors.empty?
end

check('template does not pass strict completion', failures) do
  errors = DesignArtifact.errors(JSON.parse(JSON.generate(DesignArtifact::TEMPLATE)), strict: true)
  raise 'strict check unexpectedly passed' if errors.empty?
  raise 'missing render error' unless errors.any? { |error| error.include?('reviewed') }
  raise 'missing mismatch error' unless errors.any? { |error| error.include?('high-severity') }
  raise 'missing runtime error' unless errors.any? { |error| error.include?('specVerify must pass') }
end

check('completed manifest passes strict validation', failures) do
  manifest = JSON.parse(JSON.generate(DesignArtifact::TEMPLATE))
  workbook = manifest.fetch('workbooks').first
  workbook.fetch('interactions').first.merge!(
    'verification' => 'pass',
    'evidence' => '/tmp/export-control-state.csv'
  )
  workbook.fetch('visual').fetch('renders').each do |render|
    render['path'] = "/tmp/#{render.fetch('stage')}.png"
    render['reviewed'] = true
  end
  workbook.fetch('visual').fetch('mismatches').first['status'] = 'fixed'
  workbook['runtime'] = {
    'specVerify' => 'pass',
    'compile' => 'pass',
    'dataParity' => 'pass',
    'controls' => 'pass',
    'writeback' => 'accepted-gap',
    'agent' => 'accepted-gap'
  }
  errors = DesignArtifact.errors(manifest, strict: true)
  raise errors.join('; ') unless errors.empty?
end

check('unknown artifact refs are rejected', failures) do
  manifest = JSON.parse(JSON.generate(DesignArtifact::TEMPLATE))
  manifest.fetch('workbooks').first['artifactRefs'] = ['missing']
  errors = DesignArtifact.errors(manifest)
  raise 'unknown ref was accepted' unless errors.any? { |error| error.include?('known artifact ids') }
end

check('passing interactions require evidence in strict mode', failures) do
  manifest = JSON.parse(JSON.generate(DesignArtifact::TEMPLATE))
  workbook = manifest.fetch('workbooks').first
  interaction = workbook.fetch('interactions').first
  interaction['verification'] = 'pass'
  interaction['evidence'] = ''
  errors = DesignArtifact.errors(manifest, strict: true)
  raise 'missing evidence was accepted' unless errors.any? { |error| error.include?('evidence is required') }
end

check('init refuses to overwrite an existing manifest', failures) do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'design.json')
    DesignArtifact.write_template(path)
    begin
      DesignArtifact.write_template(path)
    rescue ArgumentError
      next
    end
    raise 'existing manifest was overwritten'
  end
end

abort "#{failures.length} failure(s)" unless failures.empty?
puts 'All design-artifact tests passed.'
