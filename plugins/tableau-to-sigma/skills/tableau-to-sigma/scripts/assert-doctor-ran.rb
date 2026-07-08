#!/usr/bin/env ruby
# frozen_string_literal: true
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
  d = JSON.parse(File.read(path))
rescue JSON::ParserError => e
  warn "[FAIL] environment gate — doctor.json at #{path} is unreadable: #{e.message}"
  remediate
  exit 1
end

rt = d['runtimes'] || {}
env_desc = "os=#{d['os']} shell=#{d['shell']} sandbox=#{d['sandbox_hint']} " \
           "runtimes=[#{rt.select { |_, v| v }.keys.join(',')}]"

if d['pass']
  puts "[PASS] environment gate — doctor.json OK (#{env_desc}). Source: #{path}"
  exit 0
end

warn "[FAIL] environment gate — the environment doctor reported blocking failures (#{env_desc}):"
Array(d['failures']).each { |f| warn "         ✗ #{f}" }
remediate
exit 1
