#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/workbook_ir'

options = {}
parser = OptionParser.new do |opts|
  opts.banner = 'usage: emit-workbook-ir.rb --workdir DIR [--out PATH] [artifact overrides]'
  opts.on('--workdir DIR') { |v| options[:workdir] = v }
  opts.on('--out PATH') { |v| options[:out] = v }
  opts.on('--layout PATH') { |v| (options[:overrides] ||= {})['layout'] = v }
  opts.on('--meta PATH') { |v| (options[:overrides] ||= {})['meta'] = v }
  opts.on('--master-map PATH') { |v| (options[:overrides] ||= {})['master_map'] = v }
  opts.on('--chart-specs PATH') { |v| (options[:overrides] ||= {})['chart_specs'] = v }
  opts.on('--workbook-spec PATH') { |v| (options[:overrides] ||= {})['workbook_spec'] = v }
  opts.on('--workbook-ids PATH') { |v| (options[:overrides] ||= {})['workbook_ids'] = v }
  opts.on('--layout-xml PATH') { |v| (options[:overrides] ||= {})['layout_xml'] = v }
end
parser.parse!
abort parser.to_s unless options[:workdir]

document = WorkbookIR.emit(
  options[:workdir],
  out: options[:out],
  overrides: options[:overrides] || {}
)
destination = options[:out] || File.join(options[:workdir], 'workbook-ir.json')
puts "WORKBOOK IR: #{destination}"
puts "  pages:       #{document.dig('workbook', 'pages').length}"
puts "  worksheets:  #{document.dig('workbook', 'worksheets').length}"
puts "  bindings:    #{document['bindings'].length}"
puts "  unsupported: #{document['unsupported'].length}"
