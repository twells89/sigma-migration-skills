#!/usr/bin/env ruby
# frozen_string_literal: true
#
# check-agent-variants.rb — drift gate for the per-agent instruction variants.
#
# Every coding agent must read the SAME instructions. The non-Claude variants
# (Cursor / Codex / Cline / Continue) are GENERATED from each skill's canonical
# SKILL.md by tools/gen-agent-variants.rb. This gate re-renders them in memory
# and fails if a committed variant differs — catching the exact bug we hit
# before it existed: SKILL.md edited, variants left stale, so Cursor/Codex users
# silently ran outdated steps. Mirrors tools/check-shared.rb for shared libs.
#
#   ruby tools/check-agent-variants.rb    # exit 1 on any drift or missing variant
#
# Fix drift with:  ruby tools/gen-agent-variants.rb --all
#
# Creds-free, stdlib-only — safe for the corpus-check CI workflow + git hooks.

require_relative 'gen-agent-variants' # defines ROOT + AgentVariants

drift = []    # [rel, reason]
checked = 0

AgentVariants.skills_with_variants.each do |skill_dir|
  AgentVariants.render(skill_dir).each do |path, expected|
    rel = path.sub(ROOT + '/', '')
    checked += 1
    if !File.exist?(path)
      drift << [rel, 'missing — generator would create it']
    elsif File.read(path) != expected
      drift << [rel, 'out of sync with SKILL.md']
    end
  end
end

if drift.empty?
  puts "OK: #{checked} agent variant(s) match their canonical SKILL.md (Cursor/Codex/Cline/Continue in sync)."
  exit 0
end

puts 'AGENT-VARIANT DRIFT DETECTED'
puts 'A non-Claude agent variant is out of sync with its SKILL.md — different agents would'
puts 'read different instructions. Regenerate: ruby tools/gen-agent-variants.rb --all'
puts
drift.each { |rel, why| puts "  DRIFT  #{rel}  (#{why})" }
puts
puts "drift: #{drift.size} / #{checked}"
exit 1
