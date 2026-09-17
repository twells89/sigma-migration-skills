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
  parser.on('--stage STAGE', %w[data-model workbook]) { |value| opts[:stage] = value }
  parser.on('--out PATH') { |value| opts[:out] = value }
end.parse!(ARGV)
opts[:stage] ||= 'workbook'

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
cards = Array(read_json.call('cards.json', []))
usage_doc = read_json.call('beast-mode-workbook-usage.json', {})
workbook_usage = Array(usage_doc['usages'])

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

source_formulas = source.uniq { |formula| formula['id'] }
references = cards.flat_map do |card|
  refs = Array(card['columns']).map do |column|
    { 'id' => column['beastModeId'], 'name' => column['column'], 'cardId' => card['id'],
      'kind' => 'column', 'isCalc' => column['_isCalc'] }
  end
  summary = card['summaryNumber']
  if summary.is_a?(Hash)
    refs << { 'id' => summary['beastModeId'], 'name' => summary['column'], 'cardId' => card['id'],
              'kind' => 'summary', 'isCalc' => summary['_isCalc'] }
  end
  refs.concat(Array(card['filters']).map do |filter|
    { 'id' => filter['beastModeId'], 'name' => filter['column'], 'cardId' => card['id'],
      'kind' => 'filter', 'isCalc' => filter['_isCalc'] }
  end)
  refs
end.select { |reference| reference['id'] || reference['isCalc'] }
referenced_ids = references.map { |reference| reference['id'] }.compact.map(&:to_s)
usage_by_id = workbook_usage.group_by { |usage| usage['id'].to_s }

entries = source_formulas.map do |formula|
  converted_formula = converted_by_id[formula['id']]
  outcome = outcome_by_id[formula['id']]
  entry = {
    'id' => formula['id'],
    'name' => formula['name'],
    'class' => formula['class'],
    'dataSourceId' => formula['dataSourceId'],
  }.compact

  if formula['extractionError']
    entry.merge('status' => 'blocked', 'reason' => "source extraction failed: #{formula['extractionError']}")
  elsif formula['definitionConflict']
    entry.merge('status' => 'blocked', 'reason' => 'dataset/card definitions contain divergent SQL')
  elsif converted_formula.nil?
    entry.merge('status' => 'blocked', 'reason' => 'missing from formulas.json after translation')
  elsif formula['scope'] == 'card'
    used = usage_by_id[formula['id'].to_s]
    if used && !used.empty?
      entry.merge(
        'status' => 'emitted',
        'target' => 'workbook-formula',
        'workbookUsages' => used,
      )
    elsif !referenced_ids.include?(formula['id'].to_s)
      entry.merge(
        'status' => 'not-used',
        'reason' => 'card-local formula is not referenced by a selected card column, filter, or summary',
      )
    elsif opts[:stage] == 'data-model'
      entry.merge('status' => 'pending-workbook', 'reason' => 'referenced card-local formula awaits workbook build')
    else
      entry.merge(
        'status' => 'blocked',
        'reason' => 'referenced card-local formula was not emitted into the workbook',
      )
    end
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

source_ids = source_formulas.map { |formula| formula['id'].to_s }
missing_references = references.select do |reference|
  reference['id'] && !source_ids.include?(reference['id'].to_s)
end
missing_references.each do |reference|
  entries << {
    'id' => reference['id'],
    'name' => reference['name'],
    'scope' => 'card',
    'cardId' => reference['cardId'],
    'status' => 'blocked',
    'reason' => "referenced #{reference['kind']} formula is missing from beast-modes.json",
  }
end

duplicate_names = source_formulas.group_by { |formula| formula['name'].to_s }
                                 .select { |name, formulas| !name.empty? && formulas.size > 1 }
ambiguous_name_refs = references.select do |reference|
  reference['id'].to_s.empty? && duplicate_names.key?(reference['name'].to_s)
end
ambiguous_name_refs.each do |reference|
  entries << {
    'name' => reference['name'],
    'scope' => 'card',
    'cardId' => reference['cardId'],
    'status' => 'blocked',
    'reason' => "name-only #{reference['kind']} reference matches multiple Beast Mode ids: " \
                "#{duplicate_names[reference['name'].to_s].map { |formula| formula['id'] }.join(', ')}",
  }
end

blocked = entries.select { |entry| entry['status'] == 'blocked' }
deferred = entries.select { |entry| entry['status'] == 'deferred' }
emitted = entries.select { |entry| entry['status'] == 'emitted' }
not_used = entries.select { |entry| entry['status'] == 'not-used' }
pending = entries.select { |entry| entry['status'] == 'pending-workbook' }
report = {
  'schema' => 'domo-beast-mode-accounting/v1',
  'stage' => opts[:stage],
  'sourceBeastModes' => source_formulas.size,
  'sourceDatasetBeastModes' => source_formulas.count { |formula| formula['scope'] == 'dataset' },
  'sourceCardBeastModes' => source_formulas.count { |formula| formula['scope'] == 'card' },
  'emitted' => emitted.size,
  'deferred' => deferred.size,
  'notUsed' => not_used.size,
  'pendingWorkbook' => pending.size,
  'blocked' => blocked.size,
  'dataModelId' => opts[:data_model_id],
  'entries' => entries,
}
out = opts[:out] || File.join(dir, 'beast-mode-accounting.json')
File.write(out, JSON.pretty_generate(report) + "\n")

warn "Beast Mode accounting (#{opts[:stage]}): #{source_formulas.size} source; #{emitted.size} emitted; " \
     "#{deferred.size} deferred; #{not_used.size} not used; #{pending.size} pending; #{blocked.size} blocked"
deferred.each { |entry| warn "  DEFERRED #{entry['name'] || entry['id']}: #{entry['reason']}" }
blocked.each { |entry| warn "  BLOCKED #{entry['name'] || entry['id']}: #{entry['reason']}" }
exit(blocked.empty? ? 0 : 1)
