#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'lib/derive_pipeline_map'

options = {}
parser = OptionParser.new do |opts|
  opts.banner = 'usage: derive-pipeline-map.rb --ir PATH --generated-spec PATH (--template-workbook ID | --donor-spec PATH) --out PATH'
  opts.on('--ir PATH') { |value| options[:ir] = value }
  opts.on('--generated-spec PATH') { |value| options[:generated_spec] = value }
  opts.on('--template-workbook ID') { |value| options[:template_workbook] = value }
  opts.on('--donor-spec PATH') { |value| options[:donor_spec] = value }
  opts.on('--out PATH') { |value| options[:out] = value }
end
parser.parse!
abort parser.to_s unless options[:ir] && options[:generated_spec] && options[:out]
abort 'pass exactly one of --template-workbook or --donor-spec' if !!options[:template_workbook] == !!options[:donor_spec]

donor =
  if options[:donor_spec]
    JSON.parse(File.read(options[:donor_spec], encoding: 'UTF-8'))
  else
    require_relative 'lib/sigma_rest'
    Sigma.request(:get, "/v2/workbooks/#{options[:template_workbook]}/spec", accept: 'application/json')
  end
plan = DerivePipelineMap.derive(
  ir: JSON.parse(File.read(options[:ir], encoding: 'UTF-8')),
  generated_spec: JSON.parse(File.read(options[:generated_spec], encoding: 'UTF-8')),
  donor_spec: donor,
  template_workbook_id: options[:template_workbook]
)
File.write(options[:out], JSON.pretty_generate(plan) + "\n")
puts "pipeline map draft: #{plan['pipeline_pages'].length} pipeline page(s), " \
     "#{plan['master_sources'].length} master route(s), " \
     "#{plan['review_required'].length} review item(s) -> #{options[:out]}"
exit(plan['review_required'].empty? ? 0 : 3)
