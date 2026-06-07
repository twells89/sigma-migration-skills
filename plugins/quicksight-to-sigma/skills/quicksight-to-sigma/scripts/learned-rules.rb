#!/usr/bin/env ruby
# Load + apply customer-accumulated translation rules. The rules live in the
# customer's HOME directory (~/.quicksight-to-sigma/learned-rules.yaml), NOT in
# the skill repo — that means `git pull` of the skill never clobbers what a
# customer has discovered locally, and one customer's wins persist across
# every workbook they migrate.
#
# File location is canonical: ~/.quicksight-to-sigma/learned-rules.yaml
# Override for testing via QUICKSIGHT_TO_SIGMA_HOME env var.
#
# Schema (YAML):
#   rules:
#     - feature: "WINDOW_AVG"
#       description: "Tableau WINDOW_AVG(SUM(x)) → Sigma MovingAvg"
#       tableau_pattern: '\bWINDOW_AVG\s*\(\s*SUM\s*\(\[([^\]]+)\]\)\s*\)'
#       sigma_template: 'MovingAvg(Sum([Master/\1]), -10, 10)'
#       hint: "Sigma window functions silently error in grouping-table charts"
#       validated_at: "2026-05-19T16:42:00Z"
#       validated_workbook: "wb-id-here"
#       example_from: "workbook.twb line 1234"
#       confidence: "validated" | "proposed" | "experimental"
#
# Usage from the build script:
#   require_relative 'learned-rules'
#   rules = LearnedRules.load
#   translated, hint = LearnedRules.apply(rules, formula)

require 'yaml'
require 'date'
require 'time'

module LearnedRules
  HOME_OVERRIDE = ENV['QUICKSIGHT_TO_SIGMA_HOME']
  DEFAULT_HOME  = File.expand_path('~/.quicksight-to-sigma')

  def self.home
    HOME_OVERRIDE || DEFAULT_HOME
  end

  def self.rules_path
    File.join(home, 'learned-rules.yaml')
  end

  def self.escalations_dir
    File.join(home, 'escalations')
  end

  def self.ensure_home
    Dir.mkdir(home) unless Dir.exist?(home)
    Dir.mkdir(escalations_dir) unless Dir.exist?(escalations_dir)
  end

  # Load the customer's accumulated rules. Returns [] if the file is missing —
  # that's the normal first-time case, NOT an error.
  def self.load
    return [] unless File.exist?(rules_path)
    data = YAML.safe_load(File.read(rules_path), permitted_classes: [Time, Date]) || {}
    (data['rules'] || []).select do |r|
      # Only apply confidence=validated rules by default. proposed/experimental
      # rules are loaded but flagged so the agent can dry-run before trusting.
      conf = r['confidence'] || 'validated'
      conf == 'validated'
    end
  rescue StandardError => e
    warn "WARN  learned-rules.yaml at #{rules_path} unreadable: #{e.message}; skipping"
    []
  end

  # Apply rules to a formula. Returns [translated_formula, hint] when a rule
  # matched, [nil, nil] when none did. First matching rule wins so customers
  # can override built-in rules by adding a more-specific pattern earlier.
  def self.apply(rules, formula)
    return [nil, nil] if formula.nil? || formula.empty?
    rules.each do |r|
      pat = r['tableau_pattern']
      tmpl = r['sigma_template']
      next if pat.nil? || tmpl.nil?
      begin
        re = Regexp.new(pat)
      rescue RegexpError
        next
      end
      next unless formula =~ re
      translated = formula.gsub(re, tmpl)
      next if translated == formula
      hint_parts = []
      hint_parts << "learned-rule:#{r['feature']}"
      hint_parts << r['hint'] if r['hint']
      hint_parts << "(confidence=#{r['confidence']})" if r['confidence'] && r['confidence'] != 'validated'
      return [translated, hint_parts.join(' — ')]
    end
    [nil, nil]
  end

  # Append a freshly-validated rule to the customer's file. Called by the
  # gap-scout subagent after a successful Sigma POST + column-type guard.
  def self.append(rule)
    ensure_home
    existing = if File.exist?(rules_path)
                 YAML.safe_load(File.read(rules_path), permitted_classes: [Time, Date]) || {}
               else
                 {}
               end
    existing['rules'] ||= []
    # Deduplicate by feature+pattern
    existing['rules'].reject! { |r| r['feature'] == rule['feature'] && r['tableau_pattern'] == rule['tableau_pattern'] }
    existing['rules'] << rule
    File.write(rules_path, existing.to_yaml)
    rules_path
  end

  # Save a structured escalation for a gap the scout couldn't solve. Filed
  # locally — Phase 4 will mirror to GitHub/beads via `gh issue create` or
  # `bd create`.
  def self.escalate(payload)
    ensure_home
    slug = (payload['feature'] || 'unknown').downcase.gsub(/\W+/, '-')[0..40].sub(/-$/, '')
    path = File.join(escalations_dir, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{slug}.yaml")
    File.write(path, payload.to_yaml)
    path
  end
end

# CLI: when invoked directly, dump the loaded rules for debugging
if $PROGRAM_NAME == __FILE__
  rules = LearnedRules.load
  puts "Learned-rules file: #{LearnedRules.rules_path}"
  puts "  rules loaded:      #{rules.length}"
  rules.each_with_index do |r, i|
    puts "  [#{i}] #{r['feature']} (#{r['confidence'] || 'validated'})"
    puts "      pattern: #{r['tableau_pattern']}"
    puts "      → #{r['sigma_template']}"
  end
end
