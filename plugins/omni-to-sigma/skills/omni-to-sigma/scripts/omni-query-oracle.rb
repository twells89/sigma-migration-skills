#!/usr/bin/env ruby
# frozen_string_literal: true
# Parity oracle plan from an Omni dashboard export.
# Offline: writes the POST /api/v1/query/run bodies (exit 0).
# Live: if OMNI_BASE_URL and OMNI_API_TOKEN are set, runs each query and
# writes oracle-results.json next to --out. A transport failure exits 3.
#
#   ruby scripts/omni-query-oracle.rb --export dashboard.json --out oracle-plan.json

require 'json'
require 'net/http'
require 'optparse'
require 'uri'
require_relative 'lib/omni_export'

def run_query(base, token, query)
  uri = URI.join(base.end_with?('/') ? base : "#{base}/", 'api/v1/query/run')
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate('query' => query)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    res = http.request(req)
    body = JSON.parse(res.body) rescue { 'raw' => res.body }
    { 'status' => res.code.to_i, 'body' => body }
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--export PATH') { |v| opts[:export] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
  end.parse!(ARGV)
  abort 'missing --export' if opts[:export].to_s.empty?
  abort 'missing --out' if opts[:out].to_s.empty?
  board = OmniExport.load(opts[:export])
  queries = board['tiles'].map do |tile|
    {
      'tile' => tile['id'],
      'name' => tile['name'],
      'endpoint' => 'POST /api/v1/query/run',
      'body' => { 'query' => tile['query'] }
    }
  end
  plan = {
    'mode' => 'offline',
    'document' => board['identifier'],
    'queries' => queries
  }
  base = ENV['OMNI_BASE_URL'].to_s
  token = ENV['OMNI_API_TOKEN'].to_s
  if !base.empty? && !token.empty?
    results = []
    queries.each do |q|
      begin
        results << q.merge('response' => run_query(base, token, q.dig('body', 'query') || {}))
      rescue StandardError => e
        File.write(opts[:out], JSON.pretty_generate(plan) + "\n")
        warn "query/run failed for tile #{q['tile']}: #{e.message}"
        exit 3
      end
    end
    plan['mode'] = 'live'
    File.write(File.join(File.dirname(opts[:out]), 'oracle-results.json'), JSON.pretty_generate(results) + "\n")
  end
  File.write(opts[:out], JSON.pretty_generate(plan) + "\n")
  warn "wrote #{opts[:out]} (#{queries.length} queries, mode=#{plan['mode']})"
end
