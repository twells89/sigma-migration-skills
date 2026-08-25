#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'

options = {}
OptionParser.new do |opts|
  opts.on('--workdir DIR') { |value| options[:workdir] = value }
end.parse!
abort 'usage: assert-compiler-runtime.rb --workdir DIR' unless options[:workdir]

read = lambda do |name|
  path = File.join(options[:workdir], name)
  File.exist?(path) ? JSON.parse(File.read(path, encoding: 'UTF-8')) : nil
end
plan = read.call('workbook-compile-plan.json')
reconcile = read.call('compile-plan-reconcile.json')
parity = read.call('parity-final.json')
anchors = read.call('anchors-verdict.json')
blank = read.call('blank-risk-elements.json')
errors = []

if plan
  errors << 'compile-plan-reconcile.json is missing' unless reconcile
  errors << 'compile-plan reconciliation failed' if reconcile && reconcile['status'] != 'PASS'
  planned_charts = plan.dig('summary', 'planned_chart_visuals').to_i
  if planned_charts.positive?
    errors << 'parity-final.json is missing' unless parity
    if parity
      errors << "parity status is #{parity['status'].inspect}, expected PASS" unless parity['status'] == 'PASS'
      errors << 'parity verified zero charts for a chart-bearing compile plan' if parity['charts_total'].to_i.zero?
      errors << "#{parity['charts_fail']} chart(s) failed parity" if parity['charts_fail'].to_i.positive?
    end
  end
end
if anchors
  errors << 'one or more displayed tiles returned no data' unless anchors['tiles_all_nonempty'] == true
  errors << "#{Array(anchors['dashboard_tiles_empty']).length} displayed tile(s) are empty" if
    Array(anchors['dashboard_tiles_empty']).any?
end
if blank && blank['status'] && blank['status'] != 'PASS'
  errors << "blank-risk gate status is #{blank['status']}"
end

report = {
  'schema_version' => 1,
  'status' => errors.empty? ? 'PASS' : 'FAIL',
  'errors' => errors,
  'planned_charts' => plan&.dig('summary', 'planned_chart_visuals'),
  'parity_charts' => parity && parity['charts_total'],
  'tiles_all_nonempty' => anchors && anchors['tiles_all_nonempty']
}
File.write(
  File.join(options[:workdir], 'compiler-runtime-gate.json'),
  JSON.pretty_generate(report) + "\n"
)
if errors.empty?
  puts 'compiler runtime gate: PASS'
  exit 0
end
warn 'compiler runtime gate: FAIL'
errors.each { |error| warn "  - #{error}" }
exit 3
