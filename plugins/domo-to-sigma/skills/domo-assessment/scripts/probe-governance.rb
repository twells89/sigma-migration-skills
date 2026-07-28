#!/usr/bin/env ruby
# Phase 0 access probe for domo-assessment.
#
#   ruby scripts/probe-governance.rb --out /tmp/domo-assessment-<instance>        (live)
#   ruby scripts/probe-governance.rb --from-fixtures fixtures/tier-b --out <dir>  (offline)
#
# Detects which assessment mode is available and writes `probe.json`:
#   - public API reachable?
#   - which DomoStats/Governance system datasets are installed?
#   - is `audit` scope granted (Activity Log present)?
#   - Tier A (private card API OR a public Beast Modes dataset) vs Tier B
#     (public only — complexity will be a proxy)?
#
# Live prereqs (see ../domo-to-sigma/refs/connection.md):
#   export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=... DOMO_INSTANCE=<instance>
#   export DOMO_DEV_TOKEN=...        # omit for Tier B
#   eval "$(../domo-to-sigma/scripts/get-domo-token.sh)"
#
# Offline: point --from-fixtures at a directory of `{columns,rows}` governance
# tables (see ../fixtures/tier-a, ../fixtures/tier-b) — no auth, no network.
# Tier is decided by fixture presence: `beast-modes.json` (a public-API-visible
# Beast Modes governance dataset) OR `card-defs.json` (stands in for a reachable
# private card-definition API) ⇒ Tier A; otherwise Tier B.
#
# This assessment never posts to Sigma — no Sigma credentials, no sigma_rest.rb.
#
# NOTE: governance dataset NAME matching is best-effort (live) / filename-keyed
# (offline). CONFIRM exact names + column schemas on first live contact — see
# refs/governance-datasets.md.

require 'json'
require 'optparse'
require 'fileutils'

# Governance/DomoStats datasets we look for. Key = logical id used both as the
# `governance_datasets` key in probe.json AND (offline) the fixture filename
# stem `<key>.json`. Value = live dataset-name regex.
WANTED = {
  'datasets'     => /data\s*sets?/i,
  'dataflows'    => /data\s*flows?/i,
  'pages'        => /pages/i,
  'cards'        => /cards/i,
  'users'        => /users/i,
  'groups'       => /groups/i,
  'pdp'          => /pdp|personalized/i,
  'activity-log' => /activity\s*log/i,
  'beast-modes'  => /beast\s*mode/i
}
CORE_KEYS = %w[cards pages datasets].freeze

options = {}
OptionParser.new do |o|
  o.on('--from-fixtures DIR', 'Offline: read governance tables from DIR instead of a live Domo instance') { |v| options[:fixtures] = v }
  o.on('--out DIR', 'Write probe.json here (required)') { |v| options[:out] = v }
end.parse!

abort('--out DIR is required') unless options[:out]
FileUtils.mkdir_p(options[:out])

def write_probe(out_dir, probe)
  path = File.join(out_dir, 'probe.json')
  File.write(path, JSON.pretty_generate(probe))
  warn "\nwrote #{path}"
  warn "  tier=#{probe['tier']} public_reachable=#{probe['public_reachable']} audit_scope=#{probe['audit_scope']}"
  ds = probe['governance_datasets']
  warn(ds.empty? ? '  governance_datasets: (none matched)' : "  governance_datasets: #{ds.keys.sort.join(', ')}")
  probe['reasons'].each { |r| warn "  - #{r}" }
end

if options[:fixtures]
  # ---- OFFLINE: decide by fixture presence, no auth/network -----------------
  dir = options[:fixtures]
  abort("--from-fixtures dir not found: #{dir}") unless File.directory?(dir)

  governance_datasets = {}
  WANTED.each_key do |key|
    f = File.join(dir, "#{key}.json")
    governance_datasets[key] = File.expand_path(f) if File.exist?(f)
  end

  reasons = []
  beast_modes_present = governance_datasets.key?('beast-modes')
  card_defs_present = File.exist?(File.join(dir, 'card-defs.json'))

  tier =
    if beast_modes_present
      reasons << 'beast-modes.json present — Beast Modes governance dataset reachable on the public API (Tier A)'
      'A'
    elsif card_defs_present
      reasons << 'card-defs.json present — private card-definition API reachable (Tier A)'
      'A'
    else
      reasons << 'no beast-modes.json and no card-defs.json — Tier B (complexity will be a proxy)'
      'B'
    end

  audit_scope = governance_datasets.key?('activity-log')
  reasons << (audit_scope ? 'activity-log.json present — audit scope available (usage/value ranking)' :
                            'no activity-log.json — no audit scope; shortlist uses the complexity-only value proxy')

  unless governance_datasets.keys.any? { |k| CORE_KEYS.include?(k) }
    reasons << 'WARNING: core governance datasets (cards/pages/datasets) missing from fixtures'
  end

  reasons << "offline mode (--from-fixtures #{dir}) — public_reachable assumed true"

  probe = {
    'tier' => tier,
    'public_reachable' => true,
    'audit_scope' => audit_scope,
    'governance_datasets' => governance_datasets,
    'reasons' => reasons
  }
  write_probe(options[:out], probe)
  exit 0
end

# ---- LIVE: dev-token / Beast-Modes-dataset probe against a real Domo instance
require_relative '../../domo-to-sigma/scripts/lib/domo_rest'

reasons = []

datasets = begin
  Domo.list_datasets(limit: 200)
rescue => e
  reasons << "public API FAIL — #{e.message}"
  reasons << 'fix DOMO_CLIENT_ID/DOMO_CLIENT_SECRET and re-run scripts/get-domo-token.sh'
  probe = {
    'tier' => 'B',
    'public_reachable' => false,
    'audit_scope' => false,
    'governance_datasets' => {},
    'reasons' => reasons
  }
  write_probe(options[:out], probe)
  exit 1
end
reasons << "public API OK — #{datasets.size} DataSets visible (first page)"

governance_datasets = {}
WANTED.each do |key, rx|
  hit = datasets.find { |d| d['name'].to_s =~ rx }
  next unless hit
  governance_datasets[key] = hit['id']
  reasons << "matched #{key} => #{hit['name']} (#{hit['id']})"
end
unless governance_datasets.keys.any? { |k| CORE_KEYS.include?(k) }
  reasons << "WARNING: core Governance datasets missing — ask admin to install the 'Domo Governance " \
             "Datasets' + 'DomoStats' connectors; falling back to thin public endpoints"
end

audit_scope = governance_datasets.key?('activity-log')
reasons << (audit_scope ? 'Activity Log present — usage/value ranking available' :
                          'no Activity Log — shortlist will use the complexity-only value proxy')

tier =
  if Domo.dev_token.nil? && !governance_datasets.key?('beast-modes')
    reasons << 'no DOMO_DEV_TOKEN and no Beast Modes governance dataset — Tier B (complexity will be a proxy)'
    'B'
  elsif governance_datasets.key?('beast-modes')
    reasons << 'Beast Modes governance dataset exists — Tier A (public); no private API needed for formulas'
    'A'
  else
    # TODO(on-access): replace 'PROBE' with a real card id and confirm the shape.
    ok = begin
      Domo.private_get('/api/content/v1/cards', query: { urns: 'PROBE', parts: 'metadata' })
      true
    rescue => e
      reasons << "private API check failed: #{e.message}"
      false
    end
    reasons << (ok ? 'private card API reachable — Tier A (full complexity available)' :
                     'dev token set but private card API unreachable — Tier B')
    ok ? 'A' : 'B'
  end

probe = {
  'tier' => tier,
  'public_reachable' => true,
  'audit_scope' => audit_scope,
  'governance_datasets' => governance_datasets,
  'reasons' => reasons
}
write_probe(options[:out], probe)
exit 0
