#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative 'lib/layout_apply'

options = {}
parser = OptionParser.new do |opts|
  opts.banner = 'usage: apply-layout-local.rb --workbook-spec PATH --layout PATH --out PATH'
  opts.on('--workbook-spec PATH') { |v| options[:spec] = v }
  opts.on('--layout PATH') { |v| options[:layout] = v }
  opts.on('--elements PATH', 'default: <layout>.elements.json') { |v| options[:elements] = v }
  opts.on('--prunes PATH', 'default: <layout>.prune-elements.json') { |v| options[:prunes] = v }
  opts.on('--out PATH') { |v| options[:out] = v }
end
parser.parse!
abort parser.to_s unless options[:spec] && options[:layout] && options[:out]

options[:elements] ||= "#{options[:layout]}.elements.json"
options[:prunes] ||= "#{options[:layout]}.prune-elements.json"
spec = JSON.parse(File.read(options[:spec], encoding: 'UTF-8'))
output = LayoutApply.apply(
  spec,
  layout_xml: File.read(options[:layout], encoding: 'UTF-8'),
  elements_sidecar: options[:elements],
  prune_sidecar: options[:prunes]
)
File.write(options[:out], "#{JSON.pretty_generate(output)}\n")
puts "LOCAL LAYOUT: #{options[:out]} (no network, no writes)"
