#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only Tableau/Sigma inventory matcher. It never downloads row data and
# never calls a POST/PUT/PATCH/DELETE endpoint.

require 'json'
require 'optparse'
require 'pathname'
require 'time'
require_relative 'lib/migration_pair'

options = {
  out: nil,
  min_confidence: 0.55,
  ambiguity_window: 0.05,
  tableau_limit: nil,
  sigma_limit: nil
}

parser = OptionParser.new do |opts|
  opts.banner = 'usage: discover-migration-pairs.rb --out PATH [offline inputs | live credentials]'
  opts.on('--out PATH', 'Output directory or pair-discovery.json path') { |v| options[:out] = v }
  opts.on('--tableau-json PATH', 'Offline Tableau workbook-list response') { |v| options[:tableau_json] = v }
  opts.on('--sigma-json PATH', 'Offline Sigma workbook-list response') { |v| options[:sigma_json] = v }
  opts.on('--min-confidence N', Float, 'Minimum pair score (default 0.55)') { |v| options[:min_confidence] = v }
  opts.on('--ambiguity-window N', Float, 'Top-score tie window (default 0.05)') { |v| options[:ambiguity_window] = v }
  opts.on('--limit-tableau N', Integer, 'Limit Tableau inventory after deterministic sort') { |v| options[:tableau_limit] = v }
  opts.on('--limit-sigma N', Integer, 'Limit Sigma inventory after deterministic sort') { |v| options[:sigma_limit] = v }
end
parser.parse!

abort parser.to_s unless options[:out]
if [options[:tableau_json], options[:sigma_json]].compact.length == 1
  abort 'offline mode requires both --tableau-json and --sigma-json'
end

def list_tableau_workbooks
  require_relative 'lib/tableau_rest'
  output = []
  page = 1
  page_size = 100
  loop do
    response = Tableau.request(
      :get,
      "#{Tableau.base_path}/workbooks?pageSize=#{page_size}&pageNumber=#{page}"
    )
    items = MigrationPair.parse_tableau_list(response)
    output.concat(items)
    total = response.dig('pagination', 'totalAvailable').to_i
    break if items.empty? || page * page_size >= total

    page += 1
  end
  output
end

def list_sigma_workbooks
  require_relative 'lib/sigma_rest'
  Sigma.list_entries('/v2/workbooks')
end

offline = options[:tableau_json] && options[:sigma_json]
tableau_workbooks = if offline
                      MigrationPair.parse_tableau_list(JSON.parse(File.read(options[:tableau_json])))
                    else
                      list_tableau_workbooks
                    end
sigma_workbooks = if offline
                    MigrationPair.parse_sigma_list(JSON.parse(File.read(options[:sigma_json])))
                  else
                    list_sigma_workbooks
                  end

tableau_workbooks = tableau_workbooks.sort_by { |entry| [entry['name'].to_s, entry['id'].to_s] }
sigma_workbooks = sigma_workbooks.sort_by { |entry| [entry['name'].to_s, (entry['id'] || entry['inodeId']).to_s] }
tableau_workbooks = tableau_workbooks.first(options[:tableau_limit]) if options[:tableau_limit]
sigma_workbooks = sigma_workbooks.first(options[:sigma_limit]) if options[:sigma_limit]

matches = MigrationPair.discover(
  tableau_workbooks,
  sigma_workbooks,
  min_confidence: options[:min_confidence],
  ambiguity_window: options[:ambiguity_window]
)

destination = Pathname(options[:out]).expand_path
destination = destination.join('pair-discovery.json') unless destination.extname == '.json'
document = {
  'schema_version' => MigrationPair::SCHEMA_VERSION,
  'mode' => 'read-only',
  'source' => offline ? 'offline-fixtures' : 'live-metadata',
  'generated_at' => Time.now.utc.iso8601,
  'tableau' => { 'workbook_count' => tableau_workbooks.length },
  'sigma' => { 'workbook_count' => sigma_workbooks.length }
}.merge(matches)
MigrationPair.atomic_json(destination, document)

puts "PAIR DISCOVERY: #{matches['pairs'].length} candidate(s)"
puts "  Tableau: #{tableau_workbooks.length} workbook(s)"
puts "  Sigma:   #{sigma_workbooks.length} workbook(s)"
puts "  output:  #{destination}"
exit(matches['pairs'].empty? ? 1 : 0)
