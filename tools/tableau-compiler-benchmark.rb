#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'

options = {}
OptionParser.new do |opts|
  opts.on('--panel PATH') { |value| options[:panel] = value }
  opts.on('--results-root DIR') { |value| options[:root] = value }
  opts.on('--out PATH') { |value| options[:out] = value }
  opts.on('--allow-missing') { options[:allow_missing] = true }
end.parse!
abort 'usage: tableau-compiler-benchmark.rb --panel PATH --results-root DIR --out PATH [--allow-missing]' unless
  options[:panel] && options[:root] && options[:out]

panel = JSON.parse(File.read(options[:panel], encoding: 'UTF-8'))
read = lambda do |dir, name|
  path = File.join(dir, name)
  File.exist?(path) ? JSON.parse(File.read(path, encoding: 'UTF-8')) : nil
end
rank = { 'RED' => 0, 'PARTIAL' => 1, 'YELLOW' => 2, 'GREEN' => 3 }
cases = panel['cases'].map do |definition|
  if definition['corpus_case']
    next { 'id' => definition['id'], 'status' => 'offline',
           'corpus_case' => definition['corpus_case'] }
  end
  case_root = File.join(options[:root], definition['id'])
  baseline_dir = File.join(case_root, 'baseline')
  candidate_dir = File.join(case_root, 'candidate')
  baseline_result = read.call(baseline_dir, 'migration-result.json')
  candidate_result = read.call(candidate_dir, 'migration-result.json')
  baseline_parity = read.call(baseline_dir, 'parity-final.json')
  candidate_parity = read.call(candidate_dir, 'parity-final.json')
  reconcile = read.call(candidate_dir, 'compile-plan-reconcile.json')
  baseline_present = baseline_result || baseline_parity
  candidate_present = candidate_result || candidate_parity
  unless baseline_present && candidate_present
    next {
      'id' => definition['id'], 'status' => 'missing',
      'missing_sides' => [
        ('baseline' unless baseline_present),
        ('candidate' unless candidate_present)
      ].compact
    }
  end
  baseline_verdict = baseline_result&.dig('verdict') || 'RED'
  candidate_verdict = candidate_result&.dig('verdict') || 'RED'
  baseline_score = baseline_parity&.dig('value_parity_score')
  candidate_score = candidate_parity&.dig('value_parity_score')
  equal_or_better = rank.fetch(candidate_verdict, 0) >= rank.fetch(baseline_verdict, 0) &&
    (baseline_score.nil? || (!candidate_score.nil? && candidate_score + 0.01 >= baseline_score))
  {
    'id' => definition['id'],
    'status' => 'evaluated',
    'baseline_verdict' => baseline_verdict,
    'candidate_verdict' => candidate_verdict,
    'candidate_green' => candidate_verdict == 'GREEN',
    'baseline_parity_score' => baseline_score,
    'candidate_parity_score' => candidate_score,
    'reconcile_pass' => reconcile && reconcile['status'] == 'PASS',
    'equal_or_better' => equal_or_better,
    'numeric_regression' => baseline_score && candidate_score &&
      candidate_score < baseline_score - 0.01
  }
end

evaluated = cases.select { |entry| entry['status'] == 'evaluated' }
denominator = [evaluated.length, 1].max
equal_rate = evaluated.count { |entry| entry['equal_or_better'] }.to_f / denominator
green_rate = evaluated.count { |entry| entry['candidate_green'] }.to_f / denominator
regressions = evaluated.count { |entry| entry['numeric_regression'] }
promotion = panel['promotion']
promotion_pass = evaluated.any? &&
  equal_rate >= promotion['minimum_equal_or_better_rate'].to_f &&
  green_rate >= promotion['minimum_green_rate'].to_f &&
  regressions <= promotion['maximum_numeric_regressions'].to_i &&
  evaluated.all? { |entry| entry['reconcile_pass'] }
result = {
  'schema_version' => 1,
  'summary' => {
    'total' => panel['cases'].length,
    'evaluated' => evaluated.length,
    'equal_or_better_rate' => equal_rate.round(4),
    'green_rate' => green_rate.round(4),
    'numeric_regressions' => regressions,
    'promotion_pass' => promotion_pass
  },
  'cases' => cases
}
File.write(options[:out], JSON.pretty_generate(result) + "\n")
puts "tableau compiler benchmark: #{promotion_pass ? 'PROMOTION PASS' : 'WIP'} " \
     "(#{evaluated.length} live, equal/better #{(equal_rate * 100).round(1)}%, " \
     "green #{(green_rate * 100).round(1)}%, regressions #{regressions})"
missing = cases.count { |entry| entry['status'] == 'missing' }
exit 2 if missing.positive? && !options[:allow_missing]
exit(promotion_pass ? 0 : 3)
