#!/usr/bin/env ruby
# Scout's terminal step: given a candidate Sigma formula + the gap context,
# validate against the customer's Sigma site and persist the rule on success
# or escalate on failure.
#
# This is what the gap-scout subagent invokes via Bash. The subagent does the
# Claude-reasoning side (proposing the candidate); this script does the
# deterministic side (POST, validate, write yaml).
#
# Usage:
#   ruby scripts/scout-validate-and-persist.rb \
#     --feature 'WINDOW_AVG' \
#     --pattern '\bWINDOW_AVG\s*\(\s*SUM\s*\(\[([^\]]+)\]\)\s*\)' \
#     --template 'MovingAvg(Sum([Master/\1]), -10, 10)' \
#     --test-formula 'MovingAvg(Sum([Master/Sales]), -10, 10)' \
#     --data-model-id <dm-id> \
#     --master-element-id master \
#     [--folder-id <folder-id>] \
#     [--description "..."] \
#     [--hint "Sigma window functions silently error in grouping-table charts"] \
#     [--example-from "workbook.twb line 123"] \
#     [--max-attempts 3]
#
# Output (JSON to stdout):
#   {
#     "status": "validated" | "escalated",
#     "rule_path": "~/.quicksight-to-sigma/learned-rules.yaml",  // on success
#     "workbook_id": "...",                                       // on success
#     "escalation_path": "~/.quicksight-to-sigma/escalations/...",// on failure
#     "escalation": { "dry_run_cmd": "...", "file_cmd": "..." },  // on failure
#     "attempts": [...]
#   }
#
# Escalation is OPT-IN. On failure this script records the gap locally and
# returns a ready-to-run `escalate-gap.py` command. It does NOT file anything.
# The main agent shows the user the dry-run draft and only files (--yes) if the
# user accepts. See scripts/gap-scout.md.

require 'json'
require 'optparse'
require 'open3'
require 'shellwords'
require 'time'
require_relative 'learned-rules'

opts = { max_attempts: 1 }
OptionParser.new do |p|
  p.on('--feature S')              { |v| opts[:feature] = v }
  p.on('--pattern S')              { |v| opts[:pattern] = v }
  p.on('--template S')             { |v| opts[:template] = v }
  p.on('--test-formula S')         { |v| opts[:test_formula] = v }
  p.on('--data-model-id S')        { |v| opts[:dm_id] = v }
  p.on('--master-element-id S')    { |v| opts[:el_id] = v }
  p.on('--folder-id S')            { |v| opts[:folder_id] = v }
  p.on('--description S')          { |v| opts[:description] = v }
  p.on('--hint S')                 { |v| opts[:hint] = v }
  p.on('--example-from S')         { |v| opts[:example_from] = v }
  p.on('--max-attempts N', Integer){ |v| opts[:max_attempts] = v }
  p.on('--chart-kind S')           { |v| opts[:chart_kind] = v }
end.parse!

%i[feature pattern template test_formula dm_id el_id].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

VALIDATE = File.join(__dir__, 'validate-sigma-formula.rb')

attempt = {
  'sigma_formula' => opts[:test_formula],
  'tested_at'     => Time.now.utc.iso8601
}

# Run validate-sigma-formula.rb
cmd = ['ruby', VALIDATE,
       '--formula',           opts[:test_formula],
       '--data-model-id',     opts[:dm_id],
       '--master-element-id', opts[:el_id],
       '--label',             "scout:#{opts[:feature]}"]
cmd << '--folder-id'  << opts[:folder_id]  if opts[:folder_id]
cmd << '--chart-kind' << opts[:chart_kind] if opts[:chart_kind]

stdout, stderr, status = Open3.capture3(*cmd)
result = (JSON.parse(stdout) rescue { 'status' => 'error', 'raw' => stdout, 'stderr' => stderr })
attempt['result'] = result

if result['status'] == 'ok'
  rule = {
    'feature'            => opts[:feature],
    'description'        => opts[:description],
    'tableau_pattern'    => opts[:pattern],
    'sigma_template'     => opts[:template],
    'hint'               => opts[:hint],
    'validated_at'       => Time.now.utc.iso8601,
    'validated_workbook' => result['workbook_id'],
    'example_from'       => opts[:example_from],
    'confidence'         => 'validated'
  }
  path = LearnedRules.append(rule)
  puts JSON.pretty_generate({
    'status'      => 'validated',
    'rule_path'   => path,
    'workbook_id' => result['workbook_id'],
    'attempts'    => [attempt],
    'rule'        => rule
  })
  exit 0
else
  payload = {
    'feature'         => opts[:feature],
    'description'     => opts[:description],
    'tableau_pattern' => opts[:pattern],
    'tableau_template_attempted' => opts[:template],
    'test_formula'    => opts[:test_formula],
    'example_from'    => opts[:example_from],
    'attempts'        => [attempt],
    'escalated_at'    => Time.now.utc.iso8601
  }
  esc_path = LearnedRules.escalate(payload)

  # Opt-in escalation (NOT automatic). We record the gap locally and hand the
  # main agent a ready-to-run command for the shared filer. The agent shows the
  # user the draft (dry run) and only files if they say yes (--yes). QuickSight
  # calc-field gaps are converter gaps → mirror to the converter repos.
  escalate = File.join(__dir__, 'escalate-gap.py')
  # Trim the validator output to the error verdict — never forward spec_used /
  # all_columns into the issue body (it bloats the command + issue to KBs).
  res = attempt['result'] || {}
  resp_summary = {
    'status'        => res['status'],
    'phase'         => res['phase'],
    'error_columns' => res['error_columns']
  }.compact
  esc_cmd = [
    'python3', escalate,
    '--skill',              'quicksight-to-sigma',
    '--category',           'converter',
    '--feature',            opts[:feature],
    '--description',        (opts[:description] || ''),
    '--source-pattern',     (opts[:pattern] || ''),
    '--template-attempted', (opts[:template] || ''),
    '--test-formula',       (opts[:test_formula] || ''),
    '--sigma-response',     JSON.generate(resp_summary),
    '--example-from',       (opts[:example_from] || ''),
    '--escalation-yaml',    esc_path
  ]
  suggested = esc_cmd.map { |a| Shellwords.escape(a) }.join(' ')

  puts JSON.pretty_generate({
    'status'          => 'escalated',
    'escalation_path' => esc_path,
    'attempts'        => [attempt],
    'escalation' => {
      'note'         => 'Gap recorded locally. To offer the user a tracking issue, ' \
                        'run the dry-run command (shows the draft + dedupe), then re-run with --yes if they accept.',
      'dry_run_cmd'  => suggested,
      'file_cmd'     => "#{suggested} --yes"
    }
  })
  exit 2
end
