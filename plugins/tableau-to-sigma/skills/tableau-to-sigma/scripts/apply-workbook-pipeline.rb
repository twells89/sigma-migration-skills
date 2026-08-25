#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'lib/workbook_pipeline_reuse'

options = {}
parser = OptionParser.new do |opts|
  opts.banner = 'usage: apply-workbook-pipeline.rb --wb-spec PATH (--template-workbook ID | --donor-spec PATH) --plan PATH --out PATH'
  opts.on('--wb-spec PATH') { |value| options[:wb_spec] = value }
  opts.on('--template-workbook ID') { |value| options[:template_workbook] = value }
  opts.on('--donor-spec PATH', 'offline/readback donor workbook spec') { |value| options[:donor_spec] = value }
  opts.on('--plan PATH') { |value| options[:plan] = value }
  opts.on('--out PATH') { |value| options[:out] = value }
end
parser.parse!
abort parser.to_s unless options[:wb_spec] && options[:plan] && options[:out]
abort 'pass exactly one of --template-workbook or --donor-spec' if !!options[:template_workbook] == !!options[:donor_spec]

donor =
  if options[:donor_spec]
    JSON.parse(File.read(options[:donor_spec], encoding: 'UTF-8'))
  else
    require_relative 'lib/sigma_rest'
    Sigma.request(:get, "/v2/workbooks/#{options[:template_workbook]}/spec", accept: 'application/json')
  end
plan = JSON.parse(File.read(options[:plan], encoding: 'UTF-8'))
plan['template_workbook_id'] ||= options[:template_workbook]
result = WorkbookPipelineReuse.apply!(
  JSON.parse(File.read(options[:wb_spec], encoding: 'UTF-8')),
  donor_spec: donor,
  plan: plan
)
File.write(options[:out], JSON.pretty_generate(WorkbookCode.canonicalize(result['spec'])) + "\n")
report_path = options[:out].sub(/\.json\z/, '') + '-pipeline-reuse.json'
File.write(report_path, JSON.pretty_generate(result['report']) + "\n")
puts "pipeline reuse: #{result['report']['pipeline_elements_copied']} element(s), " \
     "#{result['report']['masters_patched'].length} master(s) -> #{options[:out]}"
