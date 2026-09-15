#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'lib/relationship_coverage'

opts = {}
OptionParser.new do |parser|
  parser.on('--workdir DIR') { |value| opts[:workdir] = File.expand_path(value) }
  parser.on('--metadata PATH') { |value| opts[:metadata] = File.expand_path(value) }
  parser.on('--source PATH') { |value| opts[:source] = File.expand_path(value) }
end.parse!

workdir = opts[:workdir] || abort('usage: assert-relationship-coverage.rb --workdir DIR')
metadata_path = opts[:metadata] || File.join(workdir, 'conv-meta.json')
source_path = opts[:source] || File.join(workdir, 'workbook-content.twb')
artifact_path = File.join(workdir, 'relationship-coverage.json')
model_path = [
  File.join(workdir, 'dm-readback.json'),
  File.join(workdir, 'dm-spec.json'),
  File.join(workdir, 'dm-raw.json')
].find { |path| File.file?(path) }

unless File.file?(artifact_path)
  source_has_graph = File.file?(source_path) &&
                     File.read(source_path, encoding: 'bom|utf-8')
                         .match?(/<(?:[^<>\s]*\.true\.\.\.)?object-graph[\s>\/]/)
  unless source_has_graph
    puts 'relationship coverage: N/A — source has no object-graph'
    exit 0
  end
  warn "RELATIONSHIP COVERAGE FAIL: #{artifact_path} is missing for an object-graph source"
  exit 3
end
unless File.file?(metadata_path)
  source_has_graph = File.file?(source_path) &&
                     File.read(source_path, encoding: 'bom|utf-8')
                         .match?(/<(?:[^<>\s]*\.true\.\.\.)?object-graph[\s>\/]/)
  if source_has_graph
    warn "RELATIONSHIP COVERAGE FAIL: source has an object-graph but #{metadata_path} is missing"
    exit 3
  end
  puts 'relationship coverage: N/A — no converter metadata and no source object-graph'
  exit 0
end

expected = begin
  RelationshipCoverage.from_files(metadata_path, source_path, model_path)
rescue JSON::ParserError, SystemCallError => e
  warn "RELATIONSHIP COVERAGE FAIL: #{e.message}"
  exit 3
end
actual = begin
  JSON.parse(File.read(artifact_path))
rescue JSON::ParserError, SystemCallError => e
  warn "RELATIONSHIP COVERAGE FAIL: #{artifact_path} is unreadable: #{e.message}"
  exit 3
end

unless actual == expected
  warn 'RELATIONSHIP COVERAGE FAIL: relationship-coverage.json is stale or was edited; ' \
       're-run emit-relationship-coverage.rb against conv-meta.json'
  exit 3
end
if expected['status'] == 'fail'
  warn "RELATIONSHIP COVERAGE FAIL: #{expected['blockers'].size} incomplete source relationship(s)"
  expected['blockers'].each do |blocker|
    pair = [blocker['left'], blocker['right']].compact.join(' ↔ ')
    warn "  - #{pair.empty? ? blocker['kind'] : pair}: #{blocker['reason']}"
  end
  exit 3
end

puts "relationship coverage: #{expected['status'].upcase} — " \
     "#{expected['wired']}/#{expected['serialized']} source relationship(s) wired completely"
exit 0
