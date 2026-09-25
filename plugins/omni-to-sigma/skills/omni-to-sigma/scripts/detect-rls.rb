#!/usr/bin/env ruby
# frozen_string_literal: true
# Scan an Omni model directory for row- and column-level security.
# Read-only. Exit 0 always (detection never blocks). --strict exits 2 when
# any finding is present so a gate can require an explicit ack.
#
#   ruby scripts/detect-rls.rb --model-dir <dir> [--out rls.json] [--strict]

require 'json'
require 'optparse'
require 'yaml'

def findings_for(path, text)
  out = []
  if text =~ /access_filters:/
    out << { 'kind' => 'access_filter', 'file' => path, 'sigma' => 'RLS user attribute + element filter' }
  end
  if text =~ /default_topic_access_filters:/
    out << { 'kind' => 'default_topic_access_filter', 'file' => path, 'sigma' => 'RLS on every topic' }
  end
  if text =~ /access_grants:/
    out << { 'kind' => 'access_grant', 'file' => path, 'sigma' => 'CLS / visibility (partial; | and & grants need a rule)' }
  end
  if text =~ /required_access_grants:/
    out << { 'kind' => 'required_access_grant', 'file' => path, 'sigma' => 'CLS on topic or field' }
  end
  if text.include?('{{') && text =~ /omni_attributes/
    out << { 'kind' => 'mustache_attribute', 'file' => path, 'sigma' => 'fail-loud — not translated into a formula' }
  end
  out
end

def structured(dir)
  filters = []
  grants = []
  Dir.glob(File.join(dir, '**', '*')).sort.each do |path|
    next unless File.file?(path)
    next unless path =~ /\.(yaml|view|topic)\z/ || File.basename(path) =~ /\A(model|relationships)\z/
    doc = YAML.safe_load(File.read(path))
    next unless doc.is_a?(Hash)
    Array(doc['access_filters']).each do |row|
      next unless row.is_a?(Hash)
      filters << row.merge('file' => path.sub(%r{\A#{Regexp.escape(dir)}/?}, ''))
    end
    grants_node = doc['access_grants']
    next unless grants_node.is_a?(Hash)
    grants_node.each do |name, spec|
      spec = {} unless spec.is_a?(Hash)
      grants << { 'name' => name, 'user_attribute' => spec['user_attribute'], 'allowed_values' => spec['allowed_values'],
                  'file' => path.sub(%r{\A#{Regexp.escape(dir)}/?}, '') }
    end
  end
  { 'access_filters' => filters, 'access_grants' => grants }
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--model-dir DIR') { |v| opts[:dir] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--strict') { opts[:strict] = true }
  end.parse!(ARGV)
  abort 'missing --model-dir' if opts[:dir].to_s.empty?
  hits = []
  Dir.glob(File.join(opts[:dir], '**', '*')).sort.each do |path|
    next unless File.file?(path)
    rel = path.sub(%r{\A#{Regexp.escape(File.expand_path(opts[:dir]))}/?}, '')
    hits.concat(findings_for(rel, File.read(path)))
  end
  report = structured(File.expand_path(opts[:dir])).merge(
    'findings' => hits,
    'summary' => {
      'findings' => hits.length,
      'access_filters' => hits.count { |h| h['kind'] == 'access_filter' },
      'access_grants' => hits.count { |h| h['kind'] == 'access_grant' }
    }
  )
  json = JSON.pretty_generate(report)
  if opts[:out]
    File.write(opts[:out], json + "\n")
  else
    puts json
  end
  warn "detect-rls: #{hits.length} finding(s)"
  exit 2 if opts[:strict] && !hits.empty?
end
