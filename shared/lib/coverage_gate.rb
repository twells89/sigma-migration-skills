# frozen_string_literal: true
#
# CoverageGate — turns a converter's build-step coverage.json into (a) a
# human-readable migration-coverage REPORT and (b) the decision questions for the
# RECOVERABLE drops, so the migrate-* orchestrator can surface ONE consolidated
# readout + an assistance prompt instead of leaving the facts in scattered STDERR
# warnings (customer feedback, 2026-06-25: "silently drops components it cannot
# resolve, rather than prompting the user for assistance").
#
# Converter-agnostic + pure + unit-tested (test-coverage-gate.rb), like DaxGate.
# The builder already warns loudly at each drop site; this module only aggregates
# + classifies. Canonical lives in shared/lib (bead beads-sigma-59mk); edit there,
# run tools/sync-shared.rb.
#
# coverage.json schema (written by each converter's build script):
#   { version, source, summary:{sourceVisuals, builtElements, dropped, degraded,
#     approximated, recoverable},
#     unresolved:[{visual, source_type, sigma_kind, severity, detail,
#                  recoverable, action}] }
#   (source_type is the per-tool source kind; some converters still emit the
#    legacy `pbi_type` — both are accepted.)
#   severity: 'dropped' | 'degraded' | 'approximated'
require 'json'

module CoverageGate
  module_function

  # Read coverage.json defensively; returns nil when absent/garbage so callers
  # can no-op (an offline / agent-path build may not have written one).
  def load(path)
    return nil unless path && File.exist?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  # The headline coverage line. Leads with what CARRIED OVER, not the gaps — an
  # APPROXIMATED visual (treemap→bar) and a DEGRADED one (lost a field) both still
  # land in Sigma with their data; only a DROPPED visual is truly absent. Counting
  # approximations as "not converted" is what fuels the "drops a lot" perception.
  # e.g. "12/12 source visuals carried over (5 approximated, 1 degraded); 0 dropped."
  def headline(coverage)
    s = (coverage && coverage['summary']) || {}
    sv = s['sourceVisuals'].to_i
    dropped_v = distinct_dropped_visuals(coverage)
    carried = [sv - dropped_v, 0].max
    extras = []
    extras << "#{s['approximated'].to_i} approximated" if s['approximated'].to_i.positive?
    extras << "#{s['degraded'].to_i} degraded" if s['degraded'].to_i.positive?
    qual = extras.empty? ? '' : " (#{extras.join(', ')})"
    "#{carried}/#{sv} source visual(s) carried over#{qual}; #{dropped_v} dropped."
  end

  # DISTINCT source visuals that produced NO Sigma element (a 'dropped' entry).
  # Approximated/degraded visuals DID build, so they are NOT counted as dropped.
  def distinct_dropped_visuals(coverage)
    ((coverage && coverage['unresolved']) || [])
      .select { |u| u['severity'] == 'dropped' }.map { |u| u['visual'] }.uniq.size
  end

  # Count of DISTINCT source visuals with at least one gap entry of ANY severity.
  def distinct_visuals_with_gaps(coverage)
    ((coverage && coverage['unresolved']) || []).map { |u| u['visual'] }.uniq.size
  end

  # Full report lines (printed under the headline). Stable ordering: dropped
  # first (most severe), then degraded, then approximated.
  ORDER = { 'dropped' => 0, 'degraded' => 1, 'approximated' => 2 }.freeze
  def report_lines(coverage)
    items = (coverage && coverage['unresolved']) || []
    items.sort_by { |u| [ORDER[u['severity']] || 9, u['visual'].to_s] }.map do |u|
      tag = u['severity'].to_s.upcase
      rec = u['recoverable'] ? ' [recoverable]' : ''
      "  • [#{tag}]#{rec} #{u['visual']}: #{u['detail']}" +
        (u['action'] ? "\n      ↳ #{u['action']}" : '')
    end
  end

  # Decision questions for the RECOVERABLE items only — same shape the migrate-*
  # orchestrators push onto `questions` (id/severity/detail/options/default).
  # Non-recoverable items (genuine Sigma limitations) are reported but never asked.
  def questions(coverage)
    ((coverage && coverage['unresolved']) || []).select { |u| u['recoverable'] }.map do |u|
      { 'id' => "coverage_#{u['severity']}", 'severity' => 'review',
        'visual' => u['visual'], 'source_type' => (u['source_type'] || u['pbi_type']),
        'detail' => u['detail'],
        'options' => [u['action'] || 'recover per the action note (re-run after fixing the source map)',
                      'accept the gap (ship without this component)'],
        'default' => 'accept the gap (ship without this component)' }
    end
  end
end
