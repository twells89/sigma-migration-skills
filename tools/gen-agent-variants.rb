#!/usr/bin/env ruby
# frozen_string_literal: true
#
# gen-agent-variants.rb — generate the non-Claude-Code agent instruction files
# from a skill's canonical SKILL.md, so EVERY coding agent (Cursor, Codex, Cline,
# Continue, …) reads the SAME instructions instead of a hand-maintained copy that
# silently drifts. This is the in-repo home of the generator (previously only in
# the sibling sigma-skills repo, which is why the marketplace copies had no drift
# gate). Pair with tools/check-agent-variants.rb (the CI/hook drift gate).
#
# Usage:
#   ruby tools/gen-agent-variants.rb <skill-dir>   # regenerate one skill
#   ruby tools/gen-agent-variants.rb --all         # every skill with a generated/ dir
#
# For each skill it (re)writes:
#   <skill-dir>/generated/codex/AGENTS.md
#   <skill-dir>/generated/cursor/rules/<name>.mdc
#   <skill-dir>/generated/cline/<name>.md
#   <skill-dir>/generated/continue/<name>.md
# Cortex Code is intentionally NOT generated — it reads SKILL.md natively.
#
# SKILL.md markers (kept identical to the canonical generator's contract):
#   <!-- agents:claude-only -->  …stripped from non-Claude outputs…  <!-- /agents:claude-only -->
#   <!-- agents:non-claude \n …shown only in non-Claude outputs… \n agents:end -->

require 'yaml'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)

PROVENANCE = <<~PROV
  <!--
  Auto-generated from SKILL.md by tools/gen-agent-variants.rb.
  Do not edit by hand — edit SKILL.md and re-run: ruby tools/gen-agent-variants.rb --all
  -->
PROV

def strip_claude_only_blocks(s)
  s.gsub(/<!--\s*agents:claude-only\s*-->.*?<!--\s*\/agents:claude-only\s*-->/m, '')
end

def reveal_non_claude_blocks(s)
  s.gsub(/<!--\s*agents:non-claude\s*\n(.*?)\nagents:end\s*-->/m) { Regexp.last_match(1) }
end

CLAUDE_PHRASE_SUBS = [
  [/\bClaude or the local machine\b/, 'the AI agent or the local machine'],
  [/\bin Claude Code\b/i, 'in your AI coding agent'],
  [/\bvia the `?Skill`? tool\b/i, ''],
  [/\bUse the `?Skill`? tool\b/i, 'Follow the procedure below'],
  [/\bvia the `?Bash`? tool\b/i, 'in your shell'],
  [/\bUse the `?Bash`? tool\b/i, 'In your shell'],
  [/\bvia the `?(Read|Edit|Write)`? tool\b/i, ''],
  [/\bsubagent_type:\s*\S+/, ''],
  [/\bTaskCreate\b/, 'a TODO entry'],
  [/\bTaskUpdate\b/, 'a TODO update'],
  [/\bTaskList\b/, 'a TODO list']
].freeze

def apply_phrase_subs(s, subs)
  out = s.dup
  subs.each { |re, repl| out.gsub!(re, repl) }
  out.gsub!(/[ \t]+$/, '')
  out.gsub!(/\n{3,}/, "\n\n")
  out
end

def transform_for_non_claude(body)
  s = body
  s = strip_claude_only_blocks(s)
  s = reveal_non_claude_blocks(s)
  s = apply_phrase_subs(s, CLAUDE_PHRASE_SUBS)
  s.strip + "\n"
end

# Drop the generated H1 when the body already opens with one.
def header(name, desc, body_xform)
  return "> #{desc}\n\n" if body_xform.lstrip.start_with?('# ')

  "# #{name}\n\n> #{desc}\n\n"
end

# Compute the intended content of every agent variant for a skill WITHOUT
# writing anything. Returns { absolute_path => content }. Shared by the writer
# (below) and the drift gate (tools/check-agent-variants.rb) so both use the
# exact same render — the gate can never disagree with the generator.
module AgentVariants
  module_function

  def render(skill_dir)
    skill_dir = File.expand_path(skill_dir)
    skill_md  = File.join(skill_dir, 'SKILL.md')
    abort "no SKILL.md at #{skill_md}" unless File.exist?(skill_md)

    raw = File.read(skill_md)
    unless raw =~ /\A---\s*\n(.+?)\n---\s*\n(.*)\z/m
      abort "no YAML frontmatter at top of #{skill_md} — needed at minimum: name + description"
    end
    fm = YAML.safe_load(Regexp.last_match(1))
    body = Regexp.last_match(2)
    name = fm['name'] or abort "frontmatter missing `name` in #{skill_md}"
    desc = (fm['description'] || '').to_s.gsub(/\s+/, ' ').strip

    body_xform = transform_for_non_claude(body)
    hdr = header(name, desc, body_xform)

    {
      File.join(skill_dir, 'generated', 'codex', 'AGENTS.md') =>
        PROVENANCE + "\n" + hdr + body_xform,
      File.join(skill_dir, 'generated', 'cursor', 'rules', "#{name}.mdc") =>
        "---\ndescription: #{desc.inspect}\nalwaysApply: false\n---\n\n" + PROVENANCE + "\n" + hdr + body_xform,
      File.join(skill_dir, 'generated', 'cline', "#{name}.md") =>
        PROVENANCE + "\n" + hdr + body_xform,
      File.join(skill_dir, 'generated', 'continue', "#{name}.md") =>
        PROVENANCE + "\n" + hdr + body_xform
    }
  end

  # Every skill that already ships agent variants (has a generated/ dir).
  def skills_with_variants
    Dir.glob(File.join(ROOT, 'plugins', '*', 'skills', '*')).select do |d|
      File.directory?(File.join(d, 'generated')) && File.file?(File.join(d, 'SKILL.md'))
    end.sort
  end

  def write(skill_dir)
    render(skill_dir).each do |path, content|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end.keys
  end
end

# CLI (skipped when this file is required as a library by the drift gate).
if $PROGRAM_NAME == __FILE__
  if ARGV.delete('--all')
    dirs = AgentVariants.skills_with_variants
    abort 'no skills with a generated/ dir found' if dirs.empty?
    dirs.each { |d| puts "#{d.sub(ROOT + '/', '')}: regenerated #{AgentVariants.write(d).size} variant(s)" }
  elsif ARGV[0]
    written = AgentVariants.write(ARGV[0])
    puts "regenerated #{written.size} variant(s):"
    written.each { |p| puts "  #{p.sub(ROOT + '/', '')}" }
  else
    abort 'usage: gen-agent-variants.rb <skill-dir> | --all'
  end
end
