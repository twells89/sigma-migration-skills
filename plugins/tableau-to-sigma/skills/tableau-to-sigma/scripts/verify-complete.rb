#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the SINGLE offline "are we actually done?" check.
#
# The migration is a two-pass design: PASS 1 (migrate-tableau.rb) ends at exit 12
# with parity + the hard-gate suite still PENDING; only PASS 2 (--finalize) runs
# assert-phase6-ran.rb, whose exit 0 is the one legitimate GREEN. A low-context
# agent can mistake a clean PASS-1 (DM + workbook POSTed, HTTP 200s) for "done"
# and stop before the gates ever fire. This script makes "done" a fact on disk,
# not a narration:
#
#   * PASS 1 writes   <workdir>/parity-pending.json  and clears the success marker
#   * assert-phase6-ran.rb (at --finalize, exit 0) writes <workdir>/phase6-success.json
#     and clears the pending marker
#
# So the ONLY state that reports DONE here is: success marker present, no pending
# marker. The SKILL's definition of done is "verify-complete.rb exits 0" —
# nothing else counts. It is fully offline; run it before claiming completion
# or handing off.
#
# VERDICT + LEDGER CROSS-CHECK (PLAN-v3 PR-14): DONE is not the same as GREEN.
# This script RE-DERIVES the degradation ledger from the workdir's artifacts
# (lib/degradation_ledger.rb — scope cuts, quality waivers, recorded escapes,
# fidelity residuals, waived resolutions; deterministic, never self-reported),
# prints the verdict (GREEN / YELLOW / PARTIAL / PARTIAL+YELLOW) with every
# ledger entry inline, and FAILS (exit 6) when the run's own reports contradict
# the derivation — a phase6-success.json / parity-final.json claiming a verdict
# or waiver census the artifacts don't support, or a degradation-ledger.json
# that no longer matches a fresh derivation. This is the anti-"GREEN, 0
# waivers" mechanism: a report can no longer claim clean over a workdir whose
# artifacts recorded scope cuts or escapes.
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — phase6-success.json present (and matches --workbook-id if given);
#      the derived verdict + ledger are printed (GREEN only on an empty ledger)
#   2  NOT DONE — the hard gate never stamped success (finalize not run / failed)
#   3  NOT DONE — still at PASS 1 (parity-pending.json present); run --finalize
#   4  DONE-BUT-MISMATCH — success marker is for a different workbook than asked
#   5  NOT DONE — loop-log.jsonl shows a tripped loop breaker since the last
#      green reset: the SAME failure signature 2+ times (stop-at-2 tripped/was
#      breached) or a record the breaker stamped as a hard stop (same-mode
#      no-progress / attempt-cap rules stop WITHOUT a signature repeat); an
#      operator must resolve it
#   6  REPORT CONTRADICTS LEDGER — a completion claim (phase6-success.json /
#      parity-final.json / degradation-ledger.json) is inconsistent with the
#      ledger derived fresh from the artifacts; the report is lying about the
#      run's degradations. Fix the report (or the tampered artifact), never
#      the ledger.
#   7  SOURCE ACCOUNTING INVALID — migration-result.json is absent/malformed,
#      RED/incomplete, or disagrees with source-object-census.json. Rebuild the
#      census and migration report from the run artifacts.
#   8  RELATIONSHIP COVERAGE INVALID — an object-graph relationship is
#      unwired/partial, or the coverage artifact is missing/stale.
#   9  DASHBOARD COVERAGE INVALID — a visible in-scope Tableau dashboard has
#      no Sigma page, or the coverage artifact is missing/stale.
#  10  SQL PROVENANCE INVALID — a data-model SQL element is unattributed, or
#      the provenance artifact is stale.

require 'json'
require 'optparse'
require_relative 'lib/offramp'
require_relative 'lib/degradation_ledger'
require_relative 'lib/relationship_coverage'
require_relative 'lib/dashboard_coverage'
require_relative 'lib/sql_provenance'

TERMINAL_SOURCE_STATUSES = %w[
  migrated approximated needs-review skipped not-applicable
].freeze

# Print the off-ramp trail + any gate waivers for this workdir — the "where did
# this run leave the golden path" readout. Advisory; shown under every verdict.
def print_offramps(wd)
  trail = Offramp.trail(wd)
  waivers = begin
    JSON.parse(File.read(File.join(wd, 'waivers.json')))
  rescue StandardError
    nil
  end
  wv = waivers.is_a?(Array) ? waivers : (waivers.is_a?(Hash) ? (waivers['waivers'] || []) : [])
  return if trail.empty? && wv.empty?
  warn ''
  warn "   off-ramps taken this run (#{trail.size} logged, #{wv.size} gate waiver(s)) — where it left the golden path:"
  trail.each { |r| warn "     • #{r['kind']}#{r['reason'] ? " — #{r['reason']}" : ''}#{r['detail'] ? " (#{r['detail']})" : ''}" }
  warn "     • #{wv.size} assert-phase6-ran gate waiver(s) — see waivers.json" unless wv.empty?
end

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--workbook-id ID') { |v| opts[:wb] = v }
end.parse!(ARGV)
abort 'FATAL: --workdir required' unless opts[:wd]

wd       = opts[:wd]
pending  = File.join(wd, 'parity-pending.json')
success  = File.join(wd, 'phase6-success.json')

def load(path)
  JSON.parse(File.read(path))
rescue StandardError
  {}
end

if File.exist?(pending)
  pj = load(pending)
  warn '⛔ NOT DONE — still at PASS 1 (parity + hard gates have not run).'
  warn "   workbook: #{pj['workbookId'] || '?'}   stage: #{pj['stage'] || '?'}"
  warn '   Collect parity actuals, then run the --finalize command PASS 1 printed,'
  warn '   which runs assert-phase6-ran.rb (the only path to GREEN).'
  print_offramps(wd)
  exit 3
end

# Loop-log enforcement (stop-at-2, PLAN E5.1: refusal threshold 2+ in the same
# PR as the breaker): a signature recorded 2+ times since the last green reset
# means the run ground the same failure in a loop — completion can never be
# claimed over it, success marker or not. ALSO refuse over any record the
# breaker itself stamped as a hard stop: the mode-no-progress and attempt-cap
# rules stop a run while every signature is still at a 1-count, so the count
# threshold alone would let a hard-STOPPED run falsely report DONE. Both
# windows are post-reset (loop_counts / loop_stops only see entries after the
# last {'reset'} record), so a GREEN finalize re-arms this refusal
# automatically; otherwise the operator resolves the failure, then clears the log.
looped = Offramp.loop_counts(wd).select { |_, n| n >= 2 }
stops  = Offramp.loop_stops(wd)
unless looped.empty? && stops.empty?
  warn '⛔ NOT DONE — loop-log.jsonl records a tripped loop breaker (repeat / no-progress / attempt-cap):'
  looped.each { |sig, n| warn "   • #{sig}  × #{n}" }
  stops.reject { |r| looped.key?(r['signature']) }
       .each { |r| warn "   • hard STOP (#{r['stop_rule'] || 'stop'}) at #{r['at']}: #{r['signature']}" }
  warn '   The run was grinding, not converging — an operator must resolve it.'
  warn "   (After resolving, clear #{File.join(wd, 'loop-log.jsonl')} and re-run the gates;"
  warn '    a GREEN finalize also re-arms the breaker automatically.)'
  print_offramps(wd)
  exit 5
end

unless File.exist?(success)
  warn '⛔ NOT DONE — no phase6-success.json in the workdir.'
  warn '   The hard-gate suite (assert-phase6-ran.rb) has not passed for this run.'
  warn "   Run PASS 1, then --finalize. Workdir checked: #{wd}"
  print_offramps(wd)
  exit 2
end

sj = load(success)
if opts[:wb] && !sj['workbookId'].to_s.empty? && sj['workbookId'] != opts[:wb]
  warn "⛔ DONE marker is for a DIFFERENT workbook (#{sj['workbookId']}) than --workbook-id #{opts[:wb]}."
  warn '   You are likely looking at a stale workdir or the wrong run.'
  exit 4
end

source_path = File.join(wd, 'workbook-content.twb')
metadata_path = File.join(wd, 'conv-meta.json')
coverage_path = File.join(wd, 'relationship-coverage.json')
source_has_graph = File.file?(source_path) &&
                   File.read(source_path, encoding: 'bom|utf-8')
                       .match?(/<(?:[^<>\s]*\.true\.\.\.)?object-graph[\s>\/]/)
if source_has_graph || File.file?(coverage_path)
  begin
    relationship_model_path = [
      File.join(wd, 'dm-readback.json'),
      File.join(wd, 'dm-spec.json'),
      File.join(wd, 'dm-raw.json')
    ].find { |path| File.file?(path) }
    expected_coverage = RelationshipCoverage.from_files(
      metadata_path, source_path, relationship_model_path
    )
    actual_coverage = JSON.parse(File.read(coverage_path))
    unless actual_coverage == expected_coverage && expected_coverage['status'] != 'fail'
      warn '⛔ RELATIONSHIP COVERAGE INVALID — object-graph coverage is stale, unwired, or partial.'
      warn "   Re-run emit-relationship-coverage.rb and resolve every blocker in #{coverage_path}."
      exit 8
    end
  rescue JSON::ParserError, SystemCallError => e
    warn "⛔ RELATIONSHIP COVERAGE INVALID — #{e.message}"
    exit 8
  end
end

if File.file?(source_path) || File.file?(File.join(wd, 'dashboard-coverage.json'))
  dashboard_artifact_path = File.join(wd, 'dashboard-coverage.json')
  dashboard_scope_path = File.join(wd, 'dashboard-scope.json')
  dashboard_spec_path = [
    File.join(wd, 'wb-readback.json'),
    File.join(wd, 'wb-spec.resolved.json'),
    File.join(wd, 'wb-spec.json')
  ].find { |path| File.file?(path) }
  begin
    expected_dashboards = DashboardCoverage.evaluate(
      twb_path: source_path,
      spec_path: dashboard_spec_path,
      scope: JSON.parse(File.read(dashboard_scope_path)),
      story_plan_path: File.join(wd, 'story-plan.json')
    )
    actual_dashboards = JSON.parse(File.read(dashboard_artifact_path))
    unless actual_dashboards == expected_dashboards && expected_dashboards['status'] == 'pass'
      warn '⛔ DASHBOARD COVERAGE INVALID — a visible in-scope Tableau dashboard is missing, ' \
           'or dashboard-coverage.json is stale.'
      exit 9
    end
  rescue JSON::ParserError, ArgumentError, SystemCallError, TypeError => e
    warn "⛔ DASHBOARD COVERAGE INVALID — #{e.message}"
    exit 9
  end
end

sql_provenance_path = File.join(wd, 'sql-provenance.json')
if File.file?(sql_provenance_path)
  sql_spec_path = [
    File.join(wd, 'dm-spec-reused.json'),
    File.join(wd, 'dm-spec.json'),
    File.join(wd, 'dm-raw.json')
  ].find { |path| File.file?(path) }
  begin
    expected_sql = SqlProvenance.evaluate(
      dm_spec_path: sql_spec_path,
      metadata_path: metadata_path,
      twb_path: source_path,
      custom_sql_path: File.join(wd, 'custom-sql.json'),
      overrides_path: File.join(wd, 'sql-provenance-overrides.json')
    )
    actual_sql = JSON.parse(File.read(sql_provenance_path))
    unless actual_sql == expected_sql && expected_sql['status'] == 'pass'
      warn '⛔ SQL PROVENANCE INVALID — a data-model SQL element is unattributed, ' \
           'or sql-provenance.json is stale.'
      exit 10
    end
  rescue JSON::ParserError, SystemCallError, TypeError => e
    warn "⛔ SQL PROVENANCE INVALID — #{e.message}"
    exit 10
  end
end

# Completion now requires the deterministic migration report and exact
# agreement with its Tableau source census. phase6-success.json proves the gate
# battery ran; it does not prove every source object was represented in the
# completion report.
result_path = File.join(wd, 'migration-result.json')
census_path = File.join(wd, 'source-object-census.json')
accounting_errors = []
result = nil
census_doc = nil
begin
  result = JSON.parse(File.read(result_path))
rescue Errno::ENOENT
  accounting_errors << 'migration-result.json is missing'
rescue JSON::ParserError => e
  accounting_errors << "migration-result.json is malformed: #{e.message}"
rescue SystemCallError => e
  accounting_errors << "migration-result.json is unreadable: #{e.message}"
end
begin
  census_doc = JSON.parse(File.read(census_path))
rescue Errno::ENOENT
  accounting_errors << 'source-object-census.json is missing'
rescue JSON::ParserError => e
  accounting_errors << "source-object-census.json is malformed: #{e.message}"
rescue SystemCallError => e
  accounting_errors << "source-object-census.json is unreadable: #{e.message}"
end

if result.is_a?(Hash)
  verdict = result['verdict'].to_s.upcase
  accounting_errors << "migration-result.json verdict is #{verdict.empty? ? 'missing' : verdict} (must be non-RED)" \
    unless %w[GREEN YELLOW].include?(verdict)
  summary = result['summary']
  result_objects = result['source_objects']
  unless summary.is_a?(Hash) && result_objects.is_a?(Array)
    accounting_errors << 'migration-result.json lacks summary/source_objects accounting'
  else
    total = summary['total']
    accounted = summary['accounted']
    accounting_errors << "migration-result.json total #{total.inspect} != #{result_objects.length}" \
      unless total.to_i == result_objects.length
    accounting_errors << "migration-result.json accounted #{accounted.inspect} != total #{total.inspect}" \
      unless accounted.to_i == total.to_i
    accounting_errors << 'migration-result.json summary.complete is not true' unless summary['complete'] == true
    bad = result_objects.reject do |object|
      object.is_a?(Hash) && TERMINAL_SOURCE_STATUSES.include?(object['status'].to_s)
    end
    accounting_errors << "#{bad.length} migration-result source object(s) lack exactly one terminal status" unless bad.empty?
  end
elsif !result.nil?
  accounting_errors << 'migration-result.json must contain a JSON object'
end

if census_doc.is_a?(Hash)
  census_objects = census_doc['objects'] || census_doc['source_objects']
  summary = census_doc['summary']
  unless census_objects.is_a?(Array) && summary.is_a?(Hash)
    accounting_errors << 'source-object-census.json lacks summary/objects accounting'
  else
    census_total = summary['total']
    accounting_errors << "source-object-census.json total #{census_total.inspect} != #{census_objects.length}" \
      unless census_total.to_i == census_objects.length
    accounting_errors << 'source-object-census.json summary.complete is not true' unless summary['complete'] == true
    bad = census_objects.reject do |object|
      object.is_a?(Hash) &&
        TERMINAL_SOURCE_STATUSES.include?(object['status'].to_s) &&
        object['evidence'].is_a?(Array) && !object['evidence'].empty?
    end
    accounting_errors << "#{bad.length} census object(s) lack one terminal status and evidence" unless bad.empty?

    if result.is_a?(Hash) && result['source_objects'].is_a?(Array)
      identity = lambda do |object|
        [object['type'].to_s, object['id'].to_s, object['name'].to_s]
      end
      census_rows = census_objects.each_with_object({}) do |object, rows|
        key = identity.call(object)
        accounting_errors << "duplicate census identity #{key.join(':')}" if rows.key?(key)
        rows[key] = object['status'].to_s
      end
      result_rows = result['source_objects'].each_with_object({}) do |object, rows|
        key = identity.call(object)
        accounting_errors << "duplicate migration-result identity #{key.join(':')}" if rows.key?(key)
        rows[key] = object['status'].to_s
      end
      unless census_rows == result_rows
        missing = census_rows.keys - result_rows.keys
        extra = result_rows.keys - census_rows.keys
        drift = (census_rows.keys & result_rows.keys).select { |key| census_rows[key] != result_rows[key] }
        accounting_errors << "migration-result/census disagree: #{missing.length} missing, " \
                             "#{extra.length} extra, #{drift.length} status drift"
      end

      expected_counts = TERMINAL_SOURCE_STATUSES.to_h do |status|
        [status, census_objects.count { |object| object['status'].to_s == status }]
      end
      [census_doc, result].each do |doc|
        label = doc.equal?(census_doc) ? 'source-object-census.json' : 'migration-result.json'
        counts = doc.dig('summary', 'counts')
        next unless counts.is_a?(Hash)
        expected_counts.each do |status, count|
          accounting_errors << "#{label} count #{status}=#{counts[status].inspect} != #{count}" \
            unless counts[status].to_i == count
        end
      end
    end
  end
elsif !census_doc.nil?
  accounting_errors << 'source-object-census.json must contain a JSON object'
end

unless accounting_errors.empty?
  warn '⛔ SOURCE ACCOUNTING INVALID — completion requires a non-RED migration report'
  warn '   with complete, census-consistent source-object accounting:'
  accounting_errors.uniq.each { |error| warn "   • #{error}" }
  warn '   Re-run build-source-object-census.rb, then build-migration-report.rb.'
  print_offramps(wd)
  exit 7
end

# ---------------------------------------------------------------------------
# PR-14 — re-derive the degradation ledger and cross-check every completion
# claim against it. Derivation is mechanical (artifacts only), so any claim it
# contradicts is a report lying about the run. Absent claims (legacy markers
# with no verdict key) are not failures — the derived verdict is printed for
# them; an EXPLICIT contradicting claim is exit 6.
# ---------------------------------------------------------------------------
deg_entries = DegradationLedger.derive(wd)
derived_verdict = DegradationLedger.verdict(deg_entries)
pf = load(File.join(wd, 'parity-final.json'))
contradictions = []

# W2.3 — the labeled factory verdict. On a Tier-S factory run (migrate-state
# tier 'S', lane A) that ends GREEN with verdict_by 'builder-self-attested',
# the ONLY honest verdict string is the labeled one — the gate never mints a
# bare 'GREEN' there, so a bare claim means the label was stripped after the
# fact. Conversely the label without that basis is a claim the artifacts do
# not support. Vocabulary: Offramp::FACTORY_VERDICT_SUFFIX / VERDICT_BY.
run_tier = begin
  JSON.parse(File.read(File.join(wd, 'migrate-state.json')))['tier'].to_s
rescue StandardError
  nil
end
# The countersignature is RE-DERIVED from the evidence on disk, never trusted
# from the markers — the gate's own two evidence forms (orchestration.md O3):
# a verifier-recorded final pass in parity-final.json (visual_verdict 'pass' +
# 'VERIFIER:'-prefixed visual_notes), or a parseable verification-result.json
# carrying the verifier's final verdict (GREEN/YELLOW/RED — the
# verifier-brief.md deliverable). A marker claiming verdict_by 'verifier' with
# neither on disk is attestation laundering: a two-field edit (verdict +
# verdict_by) would otherwise slip past the label check, which only catches
# the one-field strip.
countersign_evidence = pf['visual_verdict'].to_s == 'pass' &&
                       pf['visual_notes'].to_s.start_with?('VERIFIER:')
unless countersign_evidence
  _vr = begin
    JSON.parse(File.read(File.join(wd, 'verification-result.json')))
  rescue StandardError
    nil
  end
  countersign_evidence = _vr.is_a?(Hash) && %w[GREEN YELLOW RED].include?(_vr['verdict'].to_s)
end
factory_green = derived_verdict == 'GREEN' && run_tier == 'S' &&
                pf['verdict_by'].to_s == Offramp::VERDICT_BY_BUILDER
expected_verdict = factory_green ? "GREEN#{Offramp::FACTORY_VERDICT_SUFFIX}" : derived_verdict

# Internal census arithmetic: waiver_count must equal the census it counts.
if pf.key?('waiver_count') && pf['waivers'].is_a?(Array) &&
   pf['waiver_count'].to_i != pf['waivers'].length
  contradictions << "parity-final.json claims waiver_count=#{pf['waiver_count']} but its own census lists #{pf['waivers'].length} waiver(s)"
end
# The success marker's census must match parity-final's (both are stamped by
# the gate on the same run; drift means one was edited after the fact).
if sj['waivers'].is_a?(Array) && pf['waivers'].is_a?(Array) && sj['waivers'] != pf['waivers']
  contradictions << "phase6-success.json waiver census (#{sj['waivers'].length}) differs from parity-final.json (#{pf['waivers'].length})"
end
# Claimed verdicts must match the derivation — INCLUDING the factory label:
# a Tier-S self-attested GREEN claim must carry the suffix (the bare string
# is the exact laundering W2.3 forbids), and the suffix without the factory
# basis is equally a lie.
{ 'phase6-success.json' => sj['verdict'], 'parity-final.json' => pf['verdict'] }.each do |src, claim|
  next if claim.to_s.empty?
  next if claim.to_s == expected_verdict
  contradictions << if factory_green && claim.to_s == derived_verdict
                      "#{src} claims the BARE string #{claim} but this is a Tier-S factory self-attested run — " \
                      "the labeled verdict #{expected_verdict.inspect} is mandatory (never launder the label off)"
                    elsif !factory_green && claim.to_s == "#{derived_verdict}#{Offramp::FACTORY_VERDICT_SUFFIX}"
                      "#{src} claims the factory label #{claim.inspect} without a Tier-S self-attested basis " \
                      "(tier=#{run_tier.inspect}, verdict_by=#{pf['verdict_by'].inspect})"
                    else
                      "#{src} claims verdict #{claim} but the artifacts derive #{expected_verdict}"
                    end
end
# A 'verifier' attestation claim is only as good as the countersignature
# evidence behind it (re-derived above) — without evidence the claim is the
# exact laundering the label check alone cannot see.
{ 'phase6-success.json' => sj['verdict_by'], 'parity-final.json' => pf['verdict_by'] }.each do |src, claim|
  next unless claim.to_s == Offramp::VERDICT_BY_VERIFIER
  next if countersign_evidence
  contradictions << "#{src} claims verdict_by #{Offramp::VERDICT_BY_VERIFIER.inspect} but the workdir holds no " \
                    'countersignature evidence (no VERIFIER:-prefixed visual pass in parity-final.json, no valid ' \
                    'verification-result.json) — attestation laundering'
end
# A zero-waiver claim over a ledger that records waivers/escapes is the exact
# field lie this closes ("GREEN, 0 waivers" after --skip-ref-check).
if pf.key?('waiver_count') && pf['waiver_count'].to_i.zero? &&
   deg_entries.any? { |e| %w[quality-waiver recorded-escape].include?(e['class']) }
  contradictions << 'parity-final.json claims 0 waivers but the artifacts record waiver/escape degradations'
end
# A stored ledger that drifted from a fresh derivation was edited by hand.
stored = begin
  JSON.parse(File.read(DegradationLedger.ledger_path(wd)))
rescue StandardError
  nil
end
if stored.is_a?(Hash) && stored['entries'].is_a?(Array) && stored['entries'] != deg_entries
  contradictions << "degradation-ledger.json on disk (#{stored['entries'].length} entr#{stored['entries'].length == 1 ? 'y' : 'ies'}) does not match a fresh derivation (#{deg_entries.length}) — the ledger was edited, not re-derived"
end

if contradictions.any?
  warn '⛔ REPORT CONTRADICTS LEDGER — completion claims are inconsistent with the degradations'
  warn '   derived from this workdir\'s artifacts (the ledger is mechanical; the claims are not):'
  contradictions.each { |c| warn "   • #{c}" }
  warn "   Derived verdict: #{derived_verdict} — ledger (#{deg_entries.length} entr#{deg_entries.length == 1 ? 'y' : 'ies'}):"
  DegradationLedger.report_lines(deg_entries).each { |l| warn "   #{l}" }
  warn '   Re-run assert-phase6-ran.rb to re-stamp honest claims. Never edit the ledger or the'
  warn '   markers by hand — fix the underlying artifacts (or the report) instead.'
  exit 6
end

puts "✅ DONE — assert-phase6-ran.rb passed all gates for this run. VERDICT: #{expected_verdict}"
if factory_green
  puts '   attested : builder-self-attested (Tier-S factory — the label above is part of the verdict'
  puts '              string; quote it verbatim. A verifier countersignature + gate re-run yields bare GREEN.)'
elsif !pf['verdict_by'].to_s.empty?
  puts "   attested : #{pf['verdict_by']}"
end
puts "   workbook : #{sj['workbookId']}"
puts "   gates    : #{sj['gates']}"
puts "   run id   : #{sj['run_id']}" if sj['run_id']
puts "   waivers  : #{sj['waivers'].join(', ')}" if sj['waivers'].is_a?(Array) && sj['waivers'].any?
puts "   stamped  : #{sj['generatedAt']}"
if deg_entries.empty?
  puts '   ledger   : empty — no scope cuts, no waivers, no residuals (GREEN)'
else
  puts "   ledger   : #{deg_entries.length} degradation(s) — GREEN requires an empty ledger:"
  DegradationLedger.report_lines(deg_entries).each { |l| puts "   #{l}" }
  if derived_verdict.start_with?('PARTIAL')
    puts '   PARTIAL: a scope cut shipped — the delivered workbook is a SUBSET of the source.'
  end
end
puts '   Quote this marker (workbook + run id + verdict) and the ledger in your completion report.'
print_offramps(wd) # even a DONE run can carry waivers/degradations — surface them
exit 0
