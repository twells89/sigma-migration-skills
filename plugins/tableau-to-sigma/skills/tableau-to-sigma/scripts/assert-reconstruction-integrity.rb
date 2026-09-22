#!/usr/bin/env ruby
# frozen_string_literal: true

# Tableau-local completion gate for manual/reconstructed dashboard work:
#   1. `needs-wiring` / `needs-materialization` controls are unfinished work,
#      not terminal coverage decisions. They block unless controls-waivers.json
#      explicitly accepts the scope cut with a reason.
#   2. layout-renames.json cannot hide a chart-family substitution from the
#      verified png-read.json → live wb-readback comparison. A deliberate
#      substitution needs a reasoned png-read kind_waivers entry.
#
# Kept local rather than folded into the vendored shared assert-phase6-ran.rb:
# reconstruction rename sidecars and Tableau controls-coverage statuses are
# plugin-specific.

require 'json'
require 'optparse'
require 'time'
require_relative 'lib/code_rep'

opts = {}
OptionParser.new do |parser|
  parser.on('--workdir DIR') { |value| opts[:workdir] = File.expand_path(value) }
end.parse!
abort('usage: assert-reconstruction-integrity.rb --workdir DIR') unless opts[:workdir]

workdir = opts[:workdir]
norm = ->(value) { value.to_s.strip.downcase.gsub(/[^a-z0-9]/, '') }
read_json = lambda do |path|
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  abort("FATAL: #{path} is not valid JSON: #{e.message}")
end

control_blockers = []
control_census_path = Dir[File.join(workdir, '*-controls-coverage.json')].min
if control_census_path
  census = read_json.call(control_census_path)
  rows = census.is_a?(Hash) ? census['detail'] : nil
  abort("FATAL: #{control_census_path} is malformed (expected detail array)") unless rows.is_a?(Array)

  waivers_path = File.join(workdir, 'controls-waivers.json')
  waivers = File.exist?(waivers_path) ? read_json.call(waivers_path) : []
  waivers = waivers['waivers'] if waivers.is_a?(Hash)
  valid_waivers = Array(waivers).select do |waiver|
    waiver.is_a?(Hash) &&
      !(waiver['control'] || waiver['name']).to_s.strip.empty? &&
      !waiver['reason'].to_s.strip.empty?
  end

  rows.each do |row|
    next unless row.is_a?(Hash) && %w[needs-wiring needs-materialization].include?(row['status'].to_s)
    kind = row['kind'].to_s
    name = row['name'].to_s
    waived = valid_waivers.any? do |waiver|
      key = norm.call(waiver['control'] || waiver['name'])
      key == norm.call(name) || key == norm.call("#{kind}:#{name}")
    end
    control_blockers << {
      'kind' => kind,
      'name' => name,
      'status' => row['status']
    } unless waived
  end
end

family_map = {
  'bar' => 'bar', 'bar-chart' => 'bar', 'column' => 'bar', 'column-chart' => 'bar',
  'line' => 'line', 'line-chart' => 'line', 'sparkline' => 'line',
  'area' => 'area', 'area-chart' => 'area',
  'combo' => 'combo', 'combo-chart' => 'combo', 'dual-axis' => 'combo',
  'scatter' => 'scatter', 'scatter-chart' => 'scatter', 'bubble' => 'scatter',
  'pie' => 'pie', 'pie-chart' => 'pie', 'donut' => 'pie', 'donut-chart' => 'pie',
  'kpi' => 'kpi', 'kpi-chart' => 'kpi', 'single-value' => 'kpi', 'big-number' => 'kpi',
  'map' => 'map', 'region-map' => 'map', 'point-map' => 'map',
  'table' => 'table', 'pivot-table' => 'table', 'pivot' => 'table',
  'crosstab' => 'table', 'text-table' => 'table', 'grid' => 'table'
}.freeze
family = ->(kind) { family_map[kind.to_s.strip.downcase] }

kind_blockers = []
png_path = File.join(workdir, 'png-read.json')
readback_path = File.join(workdir, 'wb-readback.json')
renames_path = File.join(workdir, 'layout-renames.json')
if File.exist?(png_path) && File.exist?(readback_path) && File.exist?(renames_path)
  png = read_json.call(png_path)
  readback = read_json.call(readback_path)
  renames = read_json.call(renames_path)
  if png.is_a?(Hash) && png['verified'] != false && png['tiles'].is_a?(Array) && renames.is_a?(Hash)
    elements_by_name = Hash.new { |hash, key| hash[key] = [] }
    Sigma::CodeRep.workbook_elements(readback).each do |element|
      next unless element.is_a?(Hash) && element['visibleAsSource'] != false
      built_family = family.call(element['kind'])
      next unless built_family
      name = element['name'].is_a?(Hash) ? element.dig('name', 'text') : element['name']
      name = element['title'] || element['id'] if name.to_s.strip.empty?
      key = norm.call(name)
      elements_by_name[key] << {
        'id' => element['id'],
        'kind' => element['kind'],
        'family' => built_family
      } unless key.empty?
    end

    rename_by_source = renames.each_with_object({}) do |(source_name, built_name), index|
      index[norm.call(source_name)] = built_name
    end
    kind_waivers = Array(png['kind_waivers']).select do |waiver|
      waiver.is_a?(Hash) && !waiver['tile'].to_s.strip.empty? && !waiver['reason'].to_s.strip.empty?
    end

    png['tiles'].each do |tile|
      next unless tile.is_a?(Hash)
      expected = family.call(tile['kind'] || tile['chart_kind'])
      source_name = tile['title'].to_s
      built_name = rename_by_source[norm.call(source_name)]
      next unless expected && built_name
      actuals = elements_by_name[norm.call(built_name)]
      next if actuals.empty? || actuals.any? { |element| element['family'] == expected }
      waived = kind_waivers.any? { |waiver| norm.call(waiver['tile']) == norm.call(source_name) }
      next if waived
      kind_blockers << {
        'source_tile' => source_name,
        'renamed_element' => built_name,
        'expected_family' => expected,
        'built_families' => actuals.map { |element| element['family'] }.uniq,
        'built_kinds' => actuals.map { |element| element['kind'] }.uniq
      }
    end
  end
end

result = {
  'version' => 1,
  'generated_at' => Time.now.utc.iso8601,
  'status' => control_blockers.empty? && kind_blockers.empty? ? 'PASS' : 'FAIL',
  'controls_census' => control_census_path && File.basename(control_census_path),
  'unresolved_controls' => control_blockers,
  'renamed_chart_family_mismatches' => kind_blockers
}
out_path = File.join(workdir, 'reconstruction-integrity.json')
File.write(out_path, JSON.pretty_generate(result) + "\n")

if control_blockers.any?
  warn "[FAIL] reconstruction integrity: #{control_blockers.length} control(s) remain unfinished:"
  control_blockers.each do |blocker|
    warn "       - #{blocker['kind']}:#{blocker['name']} (#{blocker['status']})"
  end
  warn '       Complete the wiring/materialization, or add a reasoned controls-waivers.json entry.'
end
if kind_blockers.any?
  warn "[FAIL] reconstruction integrity: #{kind_blockers.length} renamed chart(s) changed family without residue:"
  kind_blockers.each do |blocker|
    warn "       - #{blocker['source_tile'].inspect} -> #{blocker['renamed_element'].inspect}: " \
         "expected #{blocker['expected_family']}, built #{blocker['built_families'].join('/')}"
  end
  warn '       Restore the source family, or add a reasoned png-read.json kind_waivers entry.'
end

if result['status'] == 'PASS'
  puts "[OK] reconstruction integrity: controls terminal, renamed chart families faithful or explicitly waived"
  puts "wrote #{out_path}"
  exit 0
end
warn "wrote #{out_path}"
exit 1
