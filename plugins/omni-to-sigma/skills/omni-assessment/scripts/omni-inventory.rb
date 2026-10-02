#!/usr/bin/env ruby
# frozen_string_literal: true
# Read-only Omni inventory. Offline against a model directory (and optional
# documents JSON). Live when OMNI_BASE_URL + OMNI_API_TOKEN are set: lists
# folders, documents, and stops. Never writes to Omni or Sigma.
#
#   ruby scripts/omni-inventory.rb --model-dir <dir> --out inventory.json
#   ruby scripts/omni-inventory.rb --documents documents.json --out inventory.json

require 'json'
require 'net/http'
require 'optparse'
require 'uri'

# Sibling skill inside this plugin (marketplace install keeps both skills).
require_relative '../../omni-to-sigma/scripts/lib/omni_model'

def live_get(base, token, path)
  uri = URI.join(base.end_with?('/') ? base : "#{base}/", path.sub(%r{\A/}, ''))
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{token}"
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    res = http.request(req)
    raise "GET #{path} → HTTP #{res.code}" unless res.code.to_i.between?(200, 299)
    JSON.parse(res.body)
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--model-dir DIR') { |v| opts[:model_dir] = v }
    o.on('--documents PATH') { |v| opts[:documents] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
  end.parse!(ARGV)
  abort 'missing --out' if opts[:out].to_s.empty?

  views = 0
  topics = []
  query_views = []
  relationships = 0
  if opts[:model_dir]
    model = OmniModel.load(opts[:model_dir])
    views = model['views'].length
    query_views = model['query_views']
    relationships = model['relationships'].length
    model['topics'].each do |key, topic|
      base = model['views'][topic['base_view'].to_s] || {}
      measures = (base['measures'] || {}).length
      topics << {
        'key' => key,
        'label' => topic['label'] || key,
        'base_view' => topic['base_view'],
        'joins' => OmniModel.joined_views(topic).length,
        'measures' => measures,
        'score' => measures + OmniModel.joined_views(topic).length
      }
    end
  end

  documents = []
  if opts[:documents] && File.file?(opts[:documents])
    raw = JSON.parse(File.read(opts[:documents]))
    documents = raw.is_a?(Array) ? raw : Array(raw['documents'])
  end

  live = { 'attempted' => false }
  base = ENV['OMNI_BASE_URL'].to_s
  token = ENV['OMNI_API_TOKEN'].to_s
  if !base.empty? && !token.empty? && documents.empty?
    live['attempted'] = true
    begin
      folders = live_get(base, token, 'api/v1/folders')
      live['folders'] = Array(folders['records'] || folders['folders']).length
      docs = live_get(base, token, 'api/v1/documents')
      rows = docs['records'] || docs['documents'] || []
      documents = rows
      live['documents'] = rows.length
    rescue StandardError => e
      live['error'] = e.message
    end
  end

  shortlist = topics.sort_by { |t| -t['score'] }
  complexity = views + (topics.length * 2) + (query_views.length * 3) + documents.length
  report = {
    'mode' => 'read-only',
    'counts' => {
      'views' => views,
      'topics' => topics.length,
      'relationships' => relationships,
      'query_views' => query_views.length,
      'documents' => documents.length
    },
    'complexity' => complexity,
    'shortlist' => shortlist,
    'hazards' => {
      'query_views' => query_views,
      'note' => 'Query views, custom Vega, and spreadsheet uploads stay manual in v0.'
    },
    'live' => live
  }
  File.write(opts[:out], JSON.pretty_generate(report) + "\n")
  warn "inventory: #{views} views, #{topics.length} topics, complexity #{complexity}"
end
