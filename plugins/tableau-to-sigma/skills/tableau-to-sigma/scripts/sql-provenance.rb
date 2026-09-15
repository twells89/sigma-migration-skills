#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'lib/sql_provenance'

opts = {}
OptionParser.new do |parser|
  parser.on('--workdir DIR') { |value| opts[:workdir] = File.expand_path(value) }
  parser.on('--dm-spec PATH') { |value| opts[:dm_spec] = File.expand_path(value) }
  parser.on('--check') { opts[:check] = true }
end.parse!

workdir = opts[:workdir] || abort('usage: sql-provenance.rb --workdir DIR [--dm-spec PATH] [--check]')
dm_spec = opts[:dm_spec] ||
          [File.join(workdir, 'dm-spec.json'), File.join(workdir, 'dm-raw.json')]
          .find { |path| File.file?(path) }
artifact = File.join(workdir, 'sql-provenance.json')
unless dm_spec && File.file?(dm_spec)
  warn 'SQL PROVENANCE FAIL: no data-model spec is available'
  exit 3
end

result = begin
  SqlProvenance.evaluate(
    dm_spec_path: dm_spec,
    metadata_path: File.join(workdir, 'conv-meta.json'),
    twb_path: File.join(workdir, 'workbook-content.twb'),
    custom_sql_path: File.join(workdir, 'custom-sql.json'),
    overrides_path: File.join(workdir, 'sql-provenance-overrides.json')
  )
rescue JSON::ParserError, SystemCallError => e
  warn "SQL PROVENANCE FAIL: #{e.message}"
  exit 3
end

if opts[:check]
  actual = begin
    JSON.parse(File.read(artifact))
  rescue JSON::ParserError, SystemCallError => e
    warn "SQL PROVENANCE FAIL: #{artifact} is missing/unreadable: #{e.message}"
    exit 3
  end
  unless actual == result
    warn 'SQL PROVENANCE FAIL: sql-provenance.json is stale or was edited; rerun pass 1'
    exit 3
  end
else
  File.write(artifact, "#{JSON.pretty_generate(result)}\n")
end

puts "SQL provenance: #{result['status'].upcase} — #{result['sql_elements'].size} SQL element(s), " \
     "#{result['blockers'].size} unattributed"
if result['status'] == 'fail'
  result['blockers'].each do |entry|
    warn "  - #{entry['element_name'] || entry['element_id']}: #{entry['evidence']}"
  end
  warn "Add a reasoned entry with a `proof` JSON path (`match:true`) to " \
       "#{File.join(workdir, 'sql-provenance-overrides.json')} only after proving its source semantics."
  exit 3
end
exit 0
