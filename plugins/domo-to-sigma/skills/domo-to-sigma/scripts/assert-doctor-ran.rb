#!/usr/bin/env ruby
# frozen_string_literal: true
# ── VENDORED (do not edit here) ──────────────────────────────────────────────
# Source: twells89/sigma-migration-skills @ de9a840
#   plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/assert-doctor-ran.rb
# Fix upstream and re-vendor; do not diverge this copy. Vendored for the
# standalone domo-sigma-migration repo (clone-safety) per the domo-build-pipeline plan.
# ─────────────────────────────────────────────────────────────────────────────
# 🚧 GATE — refuse to proceed on an unverified / broken environment.
#
# The mandatory Step-0 environment check (doctor.sh / doctor.ps1) writes a
# machine-readable doctor.json fingerprint. This turns "run the doctor first"
# from prose into a real gate: if the doctor never ran, or ran and FAILED, the
# pipeline stops here with the exact remediation — instead of the agent
# improvising around a missing runtime, which is the #1 source of cross-user
# inconsistency at multi-user events.
#
# doctor.json is looked up in this order:
#   1. <workdir>/doctor.json         (when --workdir is given)
#   2. ~/.sigma-migration/doctor.json (the stable location doctor always writes)
#
# Usage:
#   ruby scripts/assert-doctor-ran.rb [--workdir DIR]
#     [--skip-doctor-gate REASON]   # waive — REQUIRED reason; name it in your report
#
# Exit codes:
#   0  doctor.json present and pass:true (or waived)
#   1  doctor.json missing, unreadable, or pass:false
#   2  usage error
require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:dir] = v }
  p.on('--tableau DIR', 'alias of --workdir') { |v| opts[:dir] = v }
  p.on('--skip-doctor-gate REASON',
       'waive the environment gate — REQUIRED reason string; name it in your report') do |v|
    opts[:skip] = v
  end
end.parse!

if opts[:skip]
  puts "[SKIP] environment gate WAIVED (#{opts[:skip]}) — name this in your report."
  exit 0
end

home_doctor = File.expand_path('~/.sigma-migration/doctor.json')
candidates = []
candidates << File.join(opts[:dir], 'doctor.json') if opts[:dir]
candidates << home_doctor
path = candidates.find { |p| File.exist?(p) }

def remediate
  warn '       Run the environment doctor FIRST, then re-run:'
  warn '         macOS/Linux/Git-Bash:  bash scripts/doctor.sh'
  warn '         Windows PowerShell:    powershell -ExecutionPolicy Bypass -File scripts\\doctor.ps1'
  warn '       Escape hatch (name it in your report): --skip-doctor-gate "<reason>".'
end

unless path
  warn '[FAIL] environment gate — no doctor.json found (the Step-0 environment check never ran).'
  remediate
  exit 1
end

begin
  # 'bom|utf-8' strips a UTF-8 BOM if present — Windows PowerShell writes one and
  # JSON.parse otherwise fails with "unexpected token".
  d = JSON.parse(File.read(path, encoding: 'bom|utf-8'))
rescue JSON::ParserError => e
  warn "[FAIL] environment gate — doctor.json at #{path} is unreadable: #{e.message}"
  remediate
  exit 1
end

rt = d['runtimes'] || {}
env_desc = "os=#{d['os']} shell=#{d['shell']} sandbox=#{d['sandbox_hint']} " \
           "runtimes=[#{rt.select { |_, v| v }.keys.join(',')}]"

# Version-drift hard gate (v3 §2.1). A plugin many commits behind origin/main is
# missing the fidelity layer — the #1 measured cause of "looks better on another
# machine". WARN lives in the doctor; the orchestrator preflight BLOCKS above a
# threshold. Override with SIGMA_MAX_BEHIND; waive with --skip-doctor-gate.
threshold = (ENV['SIGMA_MAX_BEHIND'] || '50').to_i
behind = d['behind_count']
if behind.is_a?(Integer) && behind > threshold
  warn "[FAIL] environment gate — skill is #{behind} commit(s) behind origin/main " \
       "(> #{threshold}); the installed build (#{d['skill_sha']}) is missing fidelity-layer fixes."
  warn '       Update the skill checkout: git pull (or reinstall the plugin), re-run the'
  warn '       doctor, then retry. Tune the bar with SIGMA_MAX_BEHIND=<n>.'
  warn '       Escape hatch (name it in your report): --skip-doctor-gate "<reason>".'
  exit 1
end

if d['pass']
  puts "[PASS] environment gate — doctor.json OK (#{env_desc}). Source: #{path}"
  exit 0
end

warn "[FAIL] environment gate — the environment doctor reported blocking failures (#{env_desc}):"
Array(d['failures']).each { |f| warn "         ✗ #{f}" }
remediate
exit 1
