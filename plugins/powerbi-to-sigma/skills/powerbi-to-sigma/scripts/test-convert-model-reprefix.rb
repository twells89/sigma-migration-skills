#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

fails = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  fails << message unless condition
end

raw = {
  'pages' => [{
    'id' => 'p1',
    'elements' => [
      {
        'id' => 'cost', 'kind' => 'table', 'name' => 'COST_CENTER',
        'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB SCHEMA COST_CENTER] },
        'columns' => [
          { 'id' => 'id', 'formula' => '[Cost Center/ID]' },
          { 'id' => 'dim', 'formula' => '[DIM/Label]' }
        ]
      },
      {
        'id' => 'dim', 'kind' => 'table', 'name' => 'DIM',
        'source' => { 'kind' => 'warehouse-table', 'connectionId' => 'c', 'path' => %w[DB SCHEMA DIM] },
        'columns' => [{ 'id' => 'label', 'formula' => '[DIM/LABEL]' }]
      }
    ]
  }]
}

source = File.read(File.expand_path('convert-model.rb', __dir__))
check.call(source.include?("require_relative 'lib/sigma_rest'") &&
           source.include?('Sigma.request(:get, "/v2/dataModels/#{opts[:ref_dm]}/spec")'),
           'reference-DM harvest delegates browser/client auth and one-401 retry to sigma_rest')
check.call(!source.include?("ENV.fetch('SIGMA_API_TOKEN')") &&
           !source.include?("req['Authorization']"),
           'reference-DM harvest does not read or attach a static bearer')

Dir.mktmpdir('reprefix-test') do |dir|
  input = File.join(dir, 'raw.json')
  output = File.join(dir, 'spec.json')
  File.write(input, JSON.generate(raw))
  cmd = [
    'ruby', File.expand_path('convert-model.rb', __dir__),
    '--converter-out', input, '--out', output,
    '--folder-id', 'folder', '--owner-id', 'owner'
  ]
  text, status = Open3.capture2e(*cmd)
  check.call(status.success?, "convert-model succeeds#{": #{text}" unless status.success?}")
  if status.success?
    spec = JSON.parse(File.read(output))
    cost = spec['pages'][0]['elements'][0]
    check.call(cost['columns'][0]['formula'] == '[COST_CENTER/ID]',
               'space/underscore lookalike is rewritten to the literal element name')
    check.call(cost['columns'][1]['formula'] == '[DIM/Label]',
               'an exact reference to another known element is preserved')
    check.call(spec['pages'][0]['elements'][1]['columns'][0]['formula'] == '[DIM/LABEL]',
               'an exact self-reference remains unchanged')
  end
end

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |failure| puts "  - #{failure}" }
exit(fails.empty? ? 0 : 1)
