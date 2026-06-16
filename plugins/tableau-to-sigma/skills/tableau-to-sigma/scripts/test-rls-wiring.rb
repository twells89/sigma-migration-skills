#!/usr/bin/env ruby
# Regression test for the RLS surfacing pipeline (2026-06-16). Deterministic +
# offline — no Tableau/Sigma/converter calls. Guards against the "RLS silently
# dropped" regression found on the EDNA-mirror fixture:
#
#   - mechanical-specs.rb run_converter must CARRY out.security into conv-meta
#     (it previously captured only model/warnings/stats → RLS vanished).
#   - migrate-tableau.rb must SURFACE detected RLS: write security.json + a loud
#     gate + an RLS line in the RESULT banner (never silently proceed).
#   - apply_sigma_rls.py --print-plan parses a security.json offline and reports
#     the rules + attributes/teams to provision (the security.json -> apply
#     handoff + the CI-portable behavioral check).
#
# Usage:  ruby scripts/test-rls-wiring.rb

require 'json'
require 'tempfile'

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- Part A: orchestrator wiring contract (source-level guards) -------------
puts 'Part A — orchestrator carries + surfaces RLS'
mech = File.read(File.join(DIR, 'mechanical-specs.rb'))
check(mech.include?('security: out.security'),
      'run_converter shim captures out.security into conv-meta', fails)

mig = File.read(File.join(DIR, 'migrate-tableau.rb'))
check(mig.match?(/conv\[['"]security['"]\]/),
      'migrate-tableau reads conv[\'security\']', fails)
check(mig.include?("File.join(WORK, 'security.json')"),
      'migrate-tableau writes security.json', fails)
check(mig.match?(/ROW-LEVEL SECURITY DETECTED/i),
      'migrate-tableau emits a loud RLS gate', fails)
check(mig.match?(/RLS\s+:.*DETECTED, NOT APPLIED/),
      'RESULT banner flags RLS detected-but-not-applied', fails)

# ---- Part B: apply_sigma_rls.py --print-plan parses security.json offline ----
puts 'Part B — apply_sigma_rls.py --print-plan (offline)'
security = [
  { 'kind' => 'rls', 'source' => 'Tableau calc "RLS Channel Access"', 'elementName' => 'Order Fact',
    'rls' => { 'name' => 'RLS Channel Access',
               'formula' => 'CurrentUserAttributeText("order_channel") = [Order Channel]',
               'userAttributes' => ['order_channel'] } },
  { 'kind' => 'rls', 'source' => 'Tableau calc "RLS User Allowlist"', 'elementName' => 'Order Fact',
    'rls' => { 'name' => 'RLS User Allowlist',
               'formula' => 'Contains([Order Status], CurrentUserEmail())',
               'usesCurrentUserEmail' => true } }
]
tmp = Tempfile.new(['security-', '.json'])
tmp.write(JSON.generate(security)); tmp.close
out = `python3 #{File.join(DIR, 'apply_sigma_rls.py').inspect} --from-security #{tmp.path.inspect} --print-plan 2>&1`
ok = $?.success?
tmp.unlink
check(ok, 'print-plan exits 0 with no token / --dm-id (offline)', fails)
check(out.include?('2 rule(s)'), 'reports both RLS rules', fails)
check(out.match?(/order_channel/), 'identifies the order_channel user attribute to provision', fails)
check(out.match?(/1 rule\(s\) use CurrentUserEmail/), 'identifies the CurrentUserEmail rule (no provisioning)', fails)

puts
if fails.empty?
  puts 'OK — RLS wiring + apply-plan parsing all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
