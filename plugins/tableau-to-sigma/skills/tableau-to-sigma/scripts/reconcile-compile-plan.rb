#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'lib/compile_plan_reconcile'

options = {}
OptionParser.new do |opts|
  opts.on('--plan PATH') { |value| options[:plan] = value }
  opts.on('--chart-specs PATH') { |value| options[:charts] = value }
  opts.on('--provenance PATH') { |value| options[:provenance] = value }
  opts.on('--coverage PATH') { |value| options[:coverage] = value }
  opts.on('--out PATH') { |value| options[:out] = value }
end.parse!
abort 'usage: reconcile-compile-plan.rb --plan PATH --chart-specs PATH --provenance PATH --out PATH [--coverage PATH]' unless
  options[:plan] && options[:charts] && options[:provenance] && options[:out]

read = ->(path) { path && File.exist?(path) ? JSON.parse(File.read(path, encoding: 'UTF-8')) : nil }
result = CompilePlanReconcile.reconcile(
  plan: read.call(options[:plan]),
  chart_specs: read.call(options[:charts]),
  provenance: read.call(options[:provenance]),
  coverage: read.call(options[:coverage])
)
File.write(options[:out], JSON.pretty_generate(result) + "\n")
puts "compile-plan reconcile: #{result['status']} " \
     "(#{result['matched_chart_keys'].length}/#{result['planned_chart_keys'].length} charts, " \
     "#{result['built_control_names'].length}/#{result['planned_control_names'].length} controls)"
exit(result['status'] == 'PASS' ? 0 : 3)
