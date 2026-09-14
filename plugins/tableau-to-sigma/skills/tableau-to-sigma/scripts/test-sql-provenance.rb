#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative 'lib/sql_provenance'

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

element = lambda do |id, name, sql|
  {
    'id' => id, 'name' => name, 'kind' => 'table',
    'source' => { 'kind' => 'sql', 'connectionId' => 'conn', 'statement' => sql }
  }
end

Dir.mktmpdir('sql-provenance') do |dir|
  twb = File.join(dir, 'source.twb')
  dm = File.join(dir, 'dm.json')
  meta = File.join(dir, 'conv-meta.json')
  File.write(twb, <<~XML)
    <workbook><datasources><datasource><connection>
      <relation type="text"><![CDATA[SELECT order_id, amount FROM orders]]></relation>
    </connection></datasource></datasources></workbook>
  XML
  File.write(dm, JSON.generate(
    'pages' => [{
      'elements' => [
        element.call('source-sql', 'Source SQL', 'SELECT order_id, amount FROM orders'),
        element.call('lod', 'Revenue LOD Helper', 'SELECT region, SUM(amount) FROM orders GROUP BY region'),
        element.call('mystery', 'Mystery',
                     'SELECT secret, COUNT(*) FROM nowhere GROUP BY secret')
      ]
    }]
  ))
  File.write(meta, JSON.generate(
    'sqlProvenance' => [{
      'elementId' => 'lod', 'originType' => 'generated-lod',
      'statement' => 'SELECT region, SUM(amount) FROM orders GROUP BY region'
    }]
  ))
  result = SqlProvenance.evaluate(dm_spec_path: dm, metadata_path: meta, twb_path: twb)
  by_id = result['sql_elements'].to_h { |row| [row['element_id'], row] }
  check.call(by_id['source-sql']['origin_type'] == 'source-custom-sql',
             'source Custom SQL is attributed to the Tableau relation')
  check.call(by_id['lod']['origin_type'] == 'generated-lod',
             'generated grouped helper is labeled by the converter ledger')
  check.call(result['status'] == 'fail' && by_id['mystery']['status'] == 'fail',
             'unrecognized SQL is blocked instead of appearing as an invented table')

  overrides = File.join(dir, 'sql-provenance-overrides.json')
  proof = File.join(dir, 'semantic-proof.json')
  File.write(proof, JSON.generate('match' => true, 'checks' => [{ 'name' => 'row-count', 'match' => true }]))
  File.write(overrides, JSON.generate(
    'entries' => [{
      'element_id' => 'mystery', 'origin_type' => 'generated-manual',
      'reason' => 'operator-proven semantic rewrite', 'proof' => proof
    }]
  ))
  result = SqlProvenance.evaluate(dm_spec_path: dm, metadata_path: meta,
                                  twb_path: twb, overrides_path: overrides)
  check.call(result['status'] == 'pass', 'a reasoned explicit override makes every SQL element accountable')
end

if fails.empty?
  puts 'ALL PASS'
  exit 0
end
warn "#{fails.length} FAILURE(S):"
fails.each { |failure| warn "  - #{failure}" }
exit 1
