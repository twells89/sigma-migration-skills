#!/usr/bin/env ruby
# Assert that every dataset-scoped Domo Beast Mode has an explicit Sigma
# outcome. Projection formulas must be data-model columns, aggregate formulas
# must be metrics, and unsupported classes must carry a named deferral.

require 'json'
require 'optparse'
require_relative 'lib/sigma_rest'

opts = {}
OptionParser.new do |parser|
  parser.on('--discovery DIR') { |value| opts[:discovery] = value }
  parser.on('--data-model-id ID') { |value| opts[:data_model_id] = value }
  parser.on('--out PATH') { |value| opts[:out] = value }
end.parse!(ARGV)

dir = File.expand_path(opts[:discovery] || ENV['DOMO_DISCOVERY_DIR'].to_s)
abort '--discovery DIR (or DOMO_DISCOVERY_DIR) is required' if dir.empty? || !Dir.exist?(dir)

read_json = lambda do |name, fallback|
  path = File.join(dir, name)
  File.exist?(path) ? JSON.parse(File.read(path)) : fallback
end

source = Array(read_json.call('beast-modes.json', []))
converted = Array(read_json.call('formulas.json', []))
dm_outcomes_doc = read_json.call('beast-mode-dm-outcomes.json', {})
dm_outcomes = Array(dm_outcomes_doc['outcomes'])
dm_spec = read_json.call('dm-spec.json', {})

converted_by_id = converted.each_with_object({}) { |formula, out| out[formula['id']] = formula }
outcome_by_id = dm_outcomes.each_with_object({}) { |outcome, out| out[outcome['id']] = outcome }
local_elements = Array(dm_spec['pages']).flat_map { |page| Array(page['elements']) }
local_columns = local_elements.flat_map { |element| Array(element['columns']) }
local_metrics = local_elements.flat_map { |element| Array(element['metrics']) }

live_columns = []
live_metrics = []
if opts[:data_model_id]
  live = Sigma.request(:get, "/v2/dataModels/#{opts[:data_model_id]}/spec")
  live_elements = Array(live['pages']).flat_map { |page| Array(page['elements']) }
  live_columns = live_elements.flat_map { |element| Array(element['columns']) }
  live_metrics = live_elements.flat_map { |element| Array(element['metrics']) }
end

dataset_source = source.select { |formula| formula['scope'] == 'dataset' }
                       .uniq { |formula| formula['id'] }
entries = dataset_source.map do |formula|
  converted_formula = converted_by_id[formula['id']]
  outcome = outcome_by_id[formula['id']]
  entry = {
    'id' => formula['id'],
    'name' => formula['name'],
    'class' => formula['class'],
    'dataSourceId' => formula['dataSourceId'],
  }.compact

  if converted_formula.nil?
    entry.merge('status' => 'blocked', 'reason' => 'missing from formulas.json after translation')
  elsif outcome.nil?
    entry.merge('status' => 'blocked', 'reason' => 'translated but has no data-model disposition')
  elsif outcome['status'] == 'emitted'
    collection = outcome['target'] == 'data-model-metric' ? local_metrics : local_columns
    local_match = collection.any? do |item|
      item['id'] == outcome['targetId'] || item['name'] == outcome['sigmaName']
    end
    if !local_match
      entry.merge(outcome).merge('status' => 'blocked',
                                 'reason' => "#{outcome['target']} missing from local dm-spec.json")
    elsif opts[:data_model_id]
      live_collection = outcome['target'] == 'data-model-metric' ? live_metrics : live_columns
      live_match = live_collection.any? { |item| item['name'] == outcome['sigmaName'] }
      live_match ? entry.merge(outcome).merge('readbackVerified' => true) :
        entry.merge(outcome).merge(
          'status' => 'blocked',
          'reason' => "#{outcome['target']} #{outcome['sigmaName'].inspect} missing from live readback",
        )
    else
      entry.merge(outcome)
    end
  else
    entry.merge(outcome)
  end
end

blocked = entries.select { |entry| entry['status'] == 'blocked' }
deferred = entries.select { |entry| entry['status'] == 'deferred' }
emitted = entries.select { |entry| entry['status'] == 'emitted' }
report = {
  'schema' => 'domo-beast-mode-accounting/v1',
  'sourceDatasetBeastModes' => dataset_source.size,
  'emitted' => emitted.size,
  'deferred' => deferred.size,
  'blocked' => blocked.size,
  'dataModelId' => opts[:data_model_id],
  'entries' => entries,
}
out = opts[:out] || File.join(dir, 'beast-mode-accounting.json')
File.write(out, JSON.pretty_generate(report) + "\n")

warn "Beast Mode accounting: #{dataset_source.size} source; #{emitted.size} emitted; " \
     "#{deferred.size} deferred; #{blocked.size} blocked"
deferred.each { |entry| warn "  DEFERRED #{entry['name'] || entry['id']}: #{entry['reason']}" }
blocked.each { |entry| warn "  BLOCKED #{entry['name'] || entry['id']}: #{entry['reason']}" }
exit(blocked.empty? ? 0 : 1)
