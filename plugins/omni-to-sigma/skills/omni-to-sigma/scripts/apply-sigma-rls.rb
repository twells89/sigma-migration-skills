#!/usr/bin/env ruby
# frozen_string_literal: true
# Turn detect-rls.rb JSON into a Sigma RLS/CLS plan.
# Default is plan-only (no API writes). --apply requires SIGMA_API_TOKEN and
# still refuses to create attributes unless --confirm is also set.
#
#   ruby scripts/apply-sigma-rls.rb --detect rls.json --out rls-plan.json
#   ruby scripts/apply-sigma-rls.rb --detect rls.json --out rls-plan.json --apply --confirm

require 'json'
require 'optparse'

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--detect PATH') { |v| opts[:detect] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--apply') { opts[:apply] = true }
    o.on('--confirm') { opts[:confirm] = true }
  end.parse!(ARGV)
  abort 'missing --detect' if opts[:detect].to_s.empty?
  abort 'missing --out' if opts[:out].to_s.empty?
  report = JSON.parse(File.read(opts[:detect]))
  attrs = {}
  Array(report['access_filters']).each do |row|
    name = row['user_attribute'].to_s
    next if name.empty?
    attrs[name] ||= { 'name' => name, 'source' => 'access_filter', 'values_for_unfiltered' => row['values_for_unfiltered'] }
  end
  Array(report['access_grants']).each do |row|
    name = row['user_attribute'].to_s
    next if name.empty?
    attrs[name] ||= { 'name' => name, 'source' => 'access_grant' }
  end
  filters = Array(report['access_filters']).map do |row|
    {
      'field' => row['field'],
      'user_attribute' => row['user_attribute'],
      'sigma' => "element filter: [#{row['field']}] equals user attribute #{row['user_attribute']}",
      'values_for_unfiltered' => row['values_for_unfiltered']
    }
  end
  plan = {
    'mode' => 'plan',
    'user_attributes' => attrs.values,
    'row_filters' => filters,
    'column_security' => Array(report['access_grants']).map { |g|
      { 'grant' => g['name'], 'user_attribute' => g['user_attribute'],
        'allowed_values' => g['allowed_values'],
        'sigma' => 'CLS partial — map allowed_values to column visibility; |/& expressions are not auto-applied' }
    }
  }
  if opts[:apply]
    token = ENV['SIGMA_API_TOKEN'].to_s
    if token.empty? || !opts[:confirm]
      plan['mode'] = 'apply-refused'
      plan['reason'] = 'live apply needs SIGMA_API_TOKEN and --confirm (user-attribute values are not invented)'
      File.write(opts[:out], JSON.pretty_generate(plan) + "\n")
      warn plan['reason']
      exit 2
    end
    plan['mode'] = 'apply-ready'
    plan['note'] = 'confirm recorded; POST /v2/user-attributes is still manual — this skill does not invent attribute values'
  end
  File.write(opts[:out], JSON.pretty_generate(plan) + "\n")
  warn "wrote #{opts[:out]} (#{plan['user_attributes'].length} attributes, #{plan['row_filters'].length} row filters)"
end
