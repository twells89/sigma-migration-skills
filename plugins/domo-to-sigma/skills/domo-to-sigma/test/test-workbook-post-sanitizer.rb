#!/usr/bin/env ruby

require 'json'
require 'tmpdir'
require_relative '../scripts/lib/workbook_post_sanitizer'

Dir.mktmpdir('domo-workbook-post') do |dir|
  source = File.join(dir, 'workbook-spec.json')
  output = File.join(dir, 'workbook-post-spec.json')
  original = {
    'name' => 'Domo Migration',
    'folderId' => 'folder-1',
    'document' => {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'pages' => [{ 'id' => 'data', 'visibility' => 'hidden' }],
      'elements' => [
        { 'id' => 'master', 'kind' => 'table', 'visibleAsSource' => false },
        { 'id' => 'helper', 'kind' => 'table', 'visibleAsSource' => false },
        { 'id' => 'chart', 'kind' => 'bar-chart' },
      ],
      'layout' => '<Page id="data"/>',
    },
  }
  File.write(source, JSON.pretty_generate(original))

  result = DomoSigma::WorkbookPostSanitizer.build(source, output)
  raise "wrong removal count: #{result.inspect}" unless result[:removed] == 2
  posted = JSON.parse(File.read(output))
  raise 'transport payload retained visibleAsSource' if JSON.generate(posted).include?('"visibleAsSource"')
  raise 'source spec was mutated' unless JSON.parse(File.read(source)) == original
  raise 'workbook metadata changed' unless posted['name'] == original['name'] &&
                                           posted['folderId'] == original['folderId']
  raise 'element count changed' unless posted.dig('document', 'elements').size == 3
end

puts 'workbook POST sanitizer: PASS'
