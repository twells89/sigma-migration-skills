#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'lib/tableau_workbook_compiler'
require_relative 'lib/workbook_ir'

options = { strict: false }
parser = OptionParser.new do |opts|
  opts.banner = 'usage: compile-workbook-ir.rb --ir workbook-ir.json [--out PATH] [--strict]'
  opts.on('--ir PATH') { |v| options[:ir] = v }
  opts.on('--out PATH') { |v| options[:out] = v }
  opts.on('--strict', 'Exit 2 when any unsupported construct remains') { options[:strict] = true }
end
parser.parse!
abort parser.to_s unless options[:ir]

ir = WorkbookIR.load(options[:ir])
plan = TableauWorkbookCompiler.compile(ir)
destination = options[:out] || File.join(File.dirname(File.expand_path(options[:ir])), 'workbook-compile-plan.json')
WorkbookIR.atomic_json(destination, plan)
if ir.dig('artifacts', 'layout')
  WorkbookIR.emit(
    File.dirname(File.expand_path(options[:ir])),
    out: options[:ir],
    overrides: { 'compile_plan' => destination }
  )
else
  # Standalone IR fixtures have no parser artifacts to rebuild from. Preserve
  # their semantic pages/zones; the requested --out is already authoritative.
end

puts "WORKBOOK COMPILE PLAN: #{destination}"
puts "  pages:     #{plan.dig('summary', 'pages')}"
puts "  visuals:   #{plan.dig('summary', 'visuals_lowered')}/#{plan.dig('summary', 'source_zones')}"
puts "  controls:  #{plan.dig('summary', 'controls_lowered')}"
puts "  formulas:  #{plan.dig('summary', 'formulas_lowered')}"
puts "  actions:   #{plan.dig('summary', 'actions_lowered')}"
puts "  blocking:  #{plan.dig('summary', 'blocking')}"

if options[:strict] && TableauWorkbookCompiler.blocking?(plan)
  warn 'COMPILER STOP: unsupported constructs remain; no Sigma writes are authorized.'
  plan['blocking'].first(20).each do |entry|
    warn "  - #{entry['rule']}: #{entry['reason'] || entry.dig('source', 'detail') || entry.dig('source', 'visual')}"
  end
  exit 2
end
