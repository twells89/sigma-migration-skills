#!/usr/bin/env ruby
# Regression test for the RLS surfacing pipeline (2026-06-16). Deterministic +
# offline — no Tableau/Sigma/converter calls. Guards against the "RLS silently
# dropped" regression found on the enterprise-mirror fixture:
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
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)

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
out = IO.popen([*PyResolve.argv, File.join(DIR, 'apply_sigma_rls.py'), '--from-security', tmp.path, '--print-plan'], err: %i[child out], &:read)
ok = $?.success?
tmp.unlink
check(ok, 'print-plan exits 0 with no token / --dm-id (offline)', fails)
check(out.include?('2 rule(s)'), 'reports both RLS rules', fails)
check(out.match?(/order_channel/), 'identifies the order_channel user attribute to provision', fails)
check(out.match?(/1 rule\(s\) use CurrentUserEmail/), 'identifies the CurrentUserEmail rule (no provisioning)', fails)

# ---- Part C: entitlement-table rules route through the plan, never auto-apply
# (wave-2 object-model batch: the converter's STRUCTURAL detector emits
# kind:'rls-entitlement-table'; the apply engine must surface the decision —
# strategies A/B/C — and refuse to inject anything for it).
puts 'Part C — entitlement-table rule (kind rls-entitlement-table) plan routing'
ent_security = security + [
  { 'kind' => 'rls-entitlement-table',
    'source' => 'object-model related table "ENTITLEMENTS" — a user-function datasource filter references it',
    'elementName' => 'ENTITLEMENTS',
    'entitlement' => {
      'identityColumn' => 'User Email',
      'factElementName' => 'FACT_VISITS',
      'keys' => [{ 'entitlementColumn' => 'Site Key', 'relatedColumn' => 'Site Key' }],
      'strategies' => [
        'A (materialized gate): fail-closed filter on the entitlement element + INNER-JOIN gate',
        'B (row-preserving gate): Lookup boolean on the fact + include-True filter',
        'C (de-entitle): user attributes (single-valued) or teams (group-shaped)'
      ]
    },
    'note' => 'NEVER auto-applied; unconstrained live join until decided.' }
]
tmp2 = Tempfile.new(['security-ent-', '.json'])
tmp2.write(JSON.generate(ent_security)); tmp2.close
out2 = IO.popen([*PyResolve.argv, File.join(DIR, 'apply_sigma_rls.py'), '--from-security', tmp2.path, '--print-plan'], err: %i[child out], &:read)
ok2 = $?.success?
tmp2.unlink
check(ok2, 'print-plan still exits 0 with an entitlement rule present', fails)
check(out2.match?(/ENTITLEMENT TABLE 'ENTITLEMENTS'/), 'entitlement rule surfaced by name', fails)
check(out2.match?(/NEVER auto-applied/), 'plan states the rule is never auto-applied', fails)
check(out2.scan(/- [ABC] \(/).size >= 3, 'all three port strategies listed', fails)
check(out2.match?(/UNCONSTRAINED|unconstrained/), 'plan warns the undecided join is unconstrained (fan-out)', fails)
check(out2.match?(/1 entitlement-table rule\(s\) require a strategy decision/), 'decision count summarized', fails)

# Source-level pin: the batch apply path must have an explicit refuse branch —
# an unknown-kind fallthrough would silently ignore the rule (the pre-wave-2
# failure mode) or, worse, a future edit could inject it.
apply_src = File.read(File.join(DIR, 'apply_sigma_rls.py'))
check(apply_src.include?('rule.get("kind") == "rls-entitlement-table"') &&
      apply_src.match?(/NOT auto-applied \(by design\)/),
      'apply_from_security has an explicit never-auto-apply branch for entitlement rules', fails)
check(apply_src.include?('import sigma_rest') &&
      apply_src.include?('sigma_rest.request(') &&
      !apply_src.include?('TOK = os.environ.get("SIGMA_API_TOKEN")') &&
      !apply_src.include?('"Authorization": "Bearer " + TOK'),
      'live RLS path delegates browser/client auth + one-401 retry to sigma_rest (no static bearer)', fails)
mig_src = File.read(File.join(DIR, 'migrate-tableau.rb'))
check(mig_src.match?(/rls-entitlement-table/) && mig_src.match?(/UNCONSTRAINED live join/),
      'migrate-tableau RLS gate surfaces entitlement rules with the unconstrained-join risk', fails)

puts
if fails.empty?
  puts 'OK — RLS wiring + apply-plan parsing all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
