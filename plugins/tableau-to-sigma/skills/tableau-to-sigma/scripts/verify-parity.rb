#!/usr/bin/env ruby
# Parity verification: compare expected (from Tableau CSVs) vs actual
# (from Sigma queries) for each chart in a plan.
#
# Plan format (JSON array):
#   [{ "chart": "...",
#      "expected": [[dim, val], ...],
#      "actual":   { "rows": [[dim, val], ...] },
#      "extract":  true|false   # optional per-chart override
#   }]
#
# Export-marker fallbacks: collect-parity-actuals.rb may mark a chart's actual
# as a status marker instead of rows —
#   "actual": { "status": "render-verify-required", "reason": "..." }
#     (known Sigma platform bug — pivot CSV export 500/empty)
#   "actual": { "status": "too-large-for-export", "reason": "..." }
#     (bounded export truncated at rowLimit — parity over partial data is
#      meaningless; issue #416)
#   "actual": { "status": "timeout", "reason": "..." }
#     (the collector's total --timeout deadline expired)
# Such a chart reports PENDING (pending-manual, never DIVERGE) and keeps the
# run failing until the agent EITHER replaces the marker with real rows
# (direct SQL / mcp-v2 — for too-large tiles, an AGGREGATE query or the
# warehouse oracle) OR confirms the values via render-read and sets
#   "render_verified": true            # + optional "render_verified_notes"
# on the chart in the plan — which then PASSes with a named verified note.
#
# A top-level wrapper is also accepted:
#   { "extract": true, "charts": [ ... ] }
# in which case `extract` propagates to every chart.
#
# --strict      value-exact comparison (default)
# --extract-mode  structural comparison only — when Tableau view CSVs come from
#                 a workbook with hasExtracts=true, the absolute values can drift
#                 from Sigma (live warehouse) while the chart shape is correct.
#                 Extract-mode checks:
#                   - same number of buckets (rows)
#                   - same set of dimension values
#                   - same sort order on the dimension column
#                   - measure values within `--extract-tol` relative tolerance
#                     (default 0.30 = 30%) IF both are non-null, otherwise skipped
#
# Usage:
#   ruby verify-parity.rb --plan plan.json
#   ruby verify-parity.rb --plan plan.json --extract-mode
#   ruby verify-parity.rb --plan plan.json --extract-mode --extract-tol 0.50

require 'json'
require 'set'
require 'optparse'
require_relative 'lib/dim_canon'

opts = { mode: :strict, tol: 0.30 }
OptionParser.new do |p|
  p.on('--plan P')              { |v| opts[:plan] = v }
  p.on('--extract-mode')        {     opts[:mode] = :extract }
  p.on('--extract-tol TOL', Float) { |v| opts[:tol] = v }
  p.on('--score-out P')         { |v| opts[:score_out] = v }
end.parse!
require 'time'
abort('--plan required') unless opts[:plan]

# Dimension canonicalization + row rounding live in lib/dim_canon.rb — ONE
# shared implementation for this comparator AND verify-ground-truth.rb (PR-6),
# so "the same bucket" cannot mean two different things across oracles. It also
# carries the e2e-defect-list date formats ("1/4/2026 12:00:00 AM", "Feb 4, 24").
def canonicalize_dim(v)
  DimCanon.canonicalize_dim(v)
end

def month_grain(v)
  DimCanon.month_grain(v)
end

def round_row(row)
  DimCanon.round_row(row)
end

# Per-tile value-parity score in [0,1] (bead y9rd.2): tuple-set Jaccard —
# matched cells / distinct cells across both sides. 1.0 = exact. Lets us turn
# "75% parity" into a real, repeatable, gateable number instead of pass/fail only.
def jaccard(exp_set, act_set)
  union = (exp_set | act_set).size
  union.zero? ? 1.0 : ((exp_set & act_set).size.to_f / union).round(4)
end

def strict_compare(exp, act)
  # Compare the FULL tuple width the plan carries (bead s6fo): 3-channel charts
  # (stacked color / pivot row+col+value / scatter dim+x+y) must compare every
  # channel — the old first(2) slice compared two dims and ignored the measure.
  width = [(exp.map(&:size) + act.map(&:size)).max || 2, 2].max
  exp_set = Set.new(exp.map { |r| r.first(width) })
  act_set = Set.new(act.map { |r| r.first(width) })
  counts = { n_expected: exp_set.size, n_actual: act_set.size, n_matched: (exp_set & act_set).size }
  return { status: 'PASS', score: 1.0, only_in_tableau: [], only_in_sigma: [], **counts } if exp_set == act_set

  # Month-grain fallback — REPRESENTATION mismatches only: a monthly chart's
  # Tableau label ("January 2026" → "2026-01") vs Sigma's DateTrunc value
  # ("2026-01-01"). Applies ONLY when one side carries month-form keys and the
  # other day-form keys — two day-form sides (e.g. weekly buckets shifted a
  # day) must keep diverging.
  month_form = ->(set) { set.any? { |r| r[0].is_a?(String) && r[0].match?(/\A\d{4}-\d{2}\z/) } }
  day_form   = ->(set) { set.any? { |r| r[0].is_a?(String) && r[0].match?(/\A\d{4}-\d{2}-\d{2}\z/) } }
  if (month_form.call(exp_set) && day_form.call(act_set)) ||
     (day_form.call(exp_set) && month_form.call(act_set))
    to_month = ->(set) { Set.new(set.map { |r| [month_grain(r[0]), *r[1..]] }) }
    if to_month.call(exp_set) == to_month.call(act_set)
      return { status: 'PASS', score: 1.0, only_in_tableau: [], only_in_sigma: [],
               notes: ['matched at month grain (label vs first-of-month representation)'], **counts }
    end
  end

  { status: 'DIVERGE',
    score: jaccard(exp_set, act_set),
    only_in_tableau: (exp_set - act_set).to_a,
    only_in_sigma:   (act_set - exp_set).to_a,
    **counts }
end

# Extract-mode: same row count + same dim set + same dim sort. Measure values
# only flagged if they're WILDLY off (beyond extract_tol) — small drift is
# expected because Sigma reads live warehouse while extracts are frozen snapshots.
def extract_compare(exp, act, tol:)
  exp_dims = exp.map { |r| r[0] }
  act_dims = act.map { |r| r[0] }
  exp_set  = Set.new(exp_dims)
  act_set  = Set.new(act_dims)

  notes = []
  status = 'PASS'

  if exp.size != act.size
    status = 'DIVERGE'
    notes << "bucket count differs: tableau=#{exp.size} sigma=#{act.size}"
  end

  unless exp_set == act_set
    status = 'DIVERGE'
    notes << "dim set differs: tableau-only=#{(exp_set - act_set).to_a[0..3].inspect}, sigma-only=#{(act_set - exp_set).to_a[0..3].inspect}"
  end

  # If dim sets match, check sort order on the dimension
  if exp_set == act_set && exp_dims != act_dims
    notes << "dim sort order differs (extract-mode flags only — not a failure)"
  end

  # Value fidelity over matched dims (bead y9rd.2 score): mean of max(0, 1-drift)
  # across comparable numeric cells, capped at 1. Computed regardless of bucket
  # alignment so the score reflects real value accuracy even when extract-mode
  # leniently PASSes. big_drifts (> tol) still surfaced as review notes.
  exp_h = exp.each_with_object({}) { |r, h| h[r[0]] = r[1] }
  act_h = act.each_with_object({}) { |r, h| h[r[0]] = r[1] }
  big_drifts = []
  fidelities = []
  exp_h.each do |k, v|
    a = act_h[k]
    next if v.nil? || a.nil?
    next unless v.is_a?(Numeric) && a.is_a?(Numeric)
    denom = [v.abs.to_f, a.abs.to_f, 1.0].max
    drift = (v - a).abs.to_f / denom
    fidelities << [0.0, 1.0 - drift].max
    big_drifts << [k, v, a, drift] if drift > tol
  end
  if big_drifts.any? && exp.size == act.size && exp_set == act_set
    notes << "#{big_drifts.size} measure value(s) drift > #{(tol * 100).to_i}% — review:"
    big_drifts.first(3).each do |k, v, a, d|
      notes << "    #{k.inspect} tableau=#{v} sigma=#{a} drift=#{(d * 100).round}%"
    end
  end

  # Score = dim-set Jaccard × mean value fidelity (when comparable numerics exist).
  dim_jac = jaccard(exp_set, act_set)
  value_acc = fidelities.empty? ? 1.0 : (fidelities.sum / fidelities.size)
  score = (dim_jac * value_acc).round(4)

  { status: status, notes: notes, score: score,
    only_in_tableau: (exp_set - act_set).to_a,
    only_in_sigma:   (act_set - exp_set).to_a,
    n_expected: exp_set.size, n_actual: act_set.size, n_matched: (exp_set & act_set).size }
end

# Per-COLUMN (per-formula) value scoring (y9rd.14): project the row tuples to each
# column position and score it independently, so a 3-channel / multi-measure tile
# reports WHICH column diverged (the per-formula "coverage answer"), not just one
# blended tile score. Column 0 is the key/dim → distinct-value-set Jaccard. A
# numeric column i>0 is a measure → key-set Jaccard × mean value fidelity keyed on
# the row's dim (col 0), matching extract_compare. A non-numeric column i>0 falls
# back to set Jaccard. `cols` = the plan's sigma_columns (ids in row order).
def per_column_scores(exp, act, cols)
  width = [(exp.map(&:size) + act.map(&:size)).max || 0, 0].max
  return [] if width.zero?
  (0...width).map do |i|
    exp_vals = exp.map { |r| r[i] }
    act_vals = act.map { |r| r[i] }
    present  = (exp_vals + act_vals).compact
    numeric  = i.positive? && present.any? && present.all? { |v| v.is_a?(Numeric) }
    if numeric
      exp_h = exp.each_with_object({}) { |r, h| h[r[0]] = r[i] }
      act_h = act.each_with_object({}) { |r, h| h[r[0]] = r[i] }
      fids = []
      exp_h.each do |k, v|
        a = act_h[k]
        next if v.nil? || a.nil?
        denom = [v.abs.to_f, a.abs.to_f, 1.0].max
        fids << [0.0, 1.0 - (v - a).abs.to_f / denom].max
      end
      key_jac = jaccard(Set.new(exp_h.keys), Set.new(act_h.keys))
      val_acc = fids.empty? ? (key_jac.zero? ? 0.0 : 1.0) : (fids.sum / fids.size)
      score = (key_jac * val_acc).round(4)
    else
      score = jaccard(Set.new(exp_vals), Set.new(act_vals))
    end
    { 'index' => i, 'column_id' => (cols && cols[i]), 'kind' => (numeric ? 'measure' : 'dim'),
      'score' => score, 'n_expected' => exp_vals.compact.uniq.size, 'n_actual' => act_vals.compact.uniq.size }
  end
end

# ── Trailing-partial-period guard ────────────────────────────────────────────
# Field bug: a landed dataset's FINAL period was incomplete (a few days of a
# month), the time-series' last point crashed to ~0, and the chart shipped —
# extract-mode parity PASSes it (bucket sets match; value drift is notes-only)
# and even a strict DIVERGE doesn't NAME the cause. This guard is deterministic
# detection + human decision: WARN only, never a status change.
#
# Fires when, for a date-keyed series (unique date-shaped dim keys, ≥4 points):
#   * the FINAL point of a numeric column drops >90% vs the median of the
#     prior 3 points, AND
#   * the source expectation (when present) shows NO such drop — i.e. Tableau
#     rendered a healthy run-rate where Sigma renders a cliff.
# Both sides cliffing = real data (a genuine collapse), not a partial period.
TRAILING_DROP = 0.90

def date_key?(v)
  v.is_a?(String) && v.match?(/\A\d{4}-\d{2}(-\d{2})?\z/)
end

# [final_key, drop_fraction] when column `ci`'s last point (by date order)
# drops below (1 - TRAILING_DROP) × the median of the prior 3 points; else nil.
def trailing_drop(rows, ci)
  pts = rows.select { |r| date_key?(r[0]) && r[ci].is_a?(Numeric) }
  return nil if pts.size < 4
  return nil if pts.size < rows.size * 0.8            # mostly non-date keys — not a time series
  keys = pts.map { |r| r[0] }
  return nil unless keys.uniq.size == keys.size       # duplicate dates = flattened multi-series; final point ambiguous
  pts = pts.sort_by { |r| r[0] }                      # canonical date keys sort lexicographically
  final = pts[-1][ci].to_f
  prior = pts[-4, 3].map { |r| r[ci].to_f }
  median = prior.sort[1]
  return nil unless median.positive?
  drop = 1.0 - (final / median)
  drop > TRAILING_DROP ? [pts[-1][0], drop] : nil
end

# WARN notes for a chart (possibly several — one per crashing measure column).
def trailing_partial_notes(exp, act)
  notes = []
  width = act.map(&:size).max || 0
  (1...width).each do |ci|
    crash = trailing_drop(act, ci)
    next unless crash
    next if exp.any? && trailing_drop(exp, ci)        # the source shows the same cliff — real data
    src = exp.any? ? 'the Tableau expectation shows no such drop' : 'no source expectation to compare'
    notes << format('TRAILING-PARTIAL-PERIOD WARN: trailing partial period? final point %s is -%d%% vs the ' \
                    'prior-3-point median (column #%d); %s — likely an INCOMPLETE final period in the ' \
                    'landed data. Filter the partial period out (or explain why the cliff is real) before shipping.',
                    crash[0], (crash[1] * 100).round, ci, src)
  end
  notes
end

raw = JSON.parse(File.read(opts[:plan]))
default_extract = false
if raw.is_a?(Hash) && raw['charts']
  default_extract = !!raw['extract']
  plan = raw['charts']
else
  plan = raw
end

# Top-level --extract-mode overrides default
mode_forced = opts[:mode] == :extract

results = plan.map do |p|
  exp = (p['expected'] || []).map { |r| round_row(r) }

  this_extract = if p.key?('extract')
                   p['extract']
                 elsif mode_forced
                   true
                 else
                   default_extract
                 end

  # Export-marker fallback (see header): a status marker instead of rows means
  # the CSV export could not serve this chart (pivot 500/empty platform bug,
  # bounded export truncated on a too-large detail grid, or collector total
  # timeout) — the chart is PENDING manual verification, never DIVERGE-
  # against-empty. Once the plan chart carries render_verified:true it PASSes
  # with a named note.
  marker_guidance = {
    'render-verify-required' => 'verify via render-read or direct SQL',
    'too-large-for-export'   => 'element exceeds the bounded CSV export — supply rows via an ' \
                                'agent-mediated (mcp-v2) AGGREGATE query or the warehouse SQL oracle',
    'timeout'                => 're-run collect-parity-actuals.rb with a higher --timeout, or ' \
                                'supply rows via mcp-v2/warehouse SQL'
  }
  marker = p.dig('actual', 'status')
  if marker_guidance.key?(marker)
    reason = p.dig('actual', 'reason') || 'CSV export unavailable'
    result =
      if p['render_verified']
        { status: 'PASS', score: 1.0, only_in_tableau: [], only_in_sigma: [],
          n_expected: exp.size, n_actual: nil, n_matched: nil,
          notes: ["render-verified: #{reason}; values confirmed via render-read/SQL" \
                  "#{p['render_verified_notes'] ? " — #{p['render_verified_notes']}" : ''}"] }
      else
        { status: 'PENDING', score: nil, only_in_tableau: [], only_in_sigma: [], marker: marker,
          n_expected: exp.size, n_actual: nil, n_matched: nil,
          notes: ["#{marker}: #{reason} — #{marker_guidance[marker]}, " \
                  'then set "render_verified": true on this chart in the plan ' \
                  '(or replace the marker with actual rows) and re-run'] }
      end
    next result.merge(chart: p['chart'], extract: this_extract, columns: [])
  end

  act = (p.dig('actual', 'rows') || []).map { |r| round_row(r) }

  result = this_extract ? extract_compare(exp, act, tol: opts[:tol]) : strict_compare(exp, act)
  # Trailing-partial-period guard: WARN only (deterministic detection, human
  # decision) — appended to the per-chart notes, never a status change.
  tp = trailing_partial_notes(exp, act)
  if tp.any?
    result[:notes] = (result[:notes] || []) + tp
    result[:trailing_partial_warn] = true
  end
  result.merge(chart: p['chart'], extract: this_extract,
               columns: per_column_scores(exp, act, p['sigma_columns']))
end

results.each do |r|
  tag = r[:extract] ? '[extract]' : '[strict] '
  if r[:status] == 'PENDING'
    printf "%-7s  %s  %s  (%s)\n", r[:status], tag, r[:chart], r[:marker] || 'render-verify-required'
  else
    printf "%-7s  %s  %s  (score %.0f%%)\n", r[:status], tag, r[:chart], (r[:score] || 0) * 100
  end
  if r[:status] != 'PASS' || (r[:notes] && r[:notes].any?)
    Array(r[:notes]).each { |n| puts "    #{n}" }
    if r[:only_in_tableau].any? || r[:only_in_sigma].any?
      puts "    Tableau-only: #{r[:only_in_tableau].inspect[0..200]}"
      puts "    Sigma-only:   #{r[:only_in_sigma].inspect[0..200]}"
    end
    # Point at the weakest column (per-formula coverage answer, y9rd.14).
    weak = (r[:columns] || []).reject { |c| (c['score'] || 1.0) >= 0.999 }.min_by { |c| c['score'] }
    if weak
      puts "    weakest column: ##{weak['index']} #{weak['column_id'] || '(unnamed)'} (#{weak['kind']}) score #{(weak['score'] * 100).round}%"
    end
  end
end

failed = results.count { |r| r[:status] != 'PASS' }
pending = results.count { |r| r[:status] == 'PENDING' }
# Overall value-parity score (bead y9rd.2): mean per-tile score — the real,
# repeatable number behind "N% parity". Separate from pass/fail (a chart can
# DIVERGE yet score 0.9 if only one bucket is off) so trends are visible.
# PENDING (render-verify) tiles carry no score and are excluded from the mean.
scored = results.map { |r| r[:score] }.compact
overall = scored.empty? ? 1.0 : (scored.sum / scored.size).round(4)
puts '---'
puts "#{results.size - failed}/#{results.size} pass" + (mode_forced ? '  (extract-mode)' : '') +
     (pending.positive? ? "  (#{pending} pending render-verify)" : '')
puts "value-parity score: #{(overall * 100).round(1)}%  (mean per-tile, #{scored.size} scored tile(s))"

if opts[:score_out]
  score_doc = {
    'ran_at'              => Time.now.utc.iso8601,
    'mode'                => mode_forced ? 'extract' : 'strict',
    'tiles_total'         => results.size,
    'tiles_pass'          => results.size - failed,
    'tiles_fail'          => failed,
    'value_parity_score'  => overall,
    'tiles'               => results.map { |r|
      { 'chart' => r[:chart], 'status' => r[:status], 'extract' => r[:extract],
        # PENDING (render-verify) tiles carry score:null — unscored, not zero.
        'score' => (r[:status] == 'PENDING' ? nil : (r[:score] || 0.0)),
        'n_expected' => r[:n_expected], 'n_actual' => r[:n_actual], 'n_matched' => r[:n_matched],
        # named WARNs (trailing-partial-period guard) — advisory, never a status
        'warnings' => Array(r[:notes]).grep(/\ATRAILING-PARTIAL-PERIOD/),
        # per-column (per-formula) scores (y9rd.14) — which column carried the divergence
        'columns' => (r[:columns] || []) }
    }
  }
  File.write(opts[:score_out], JSON.pretty_generate(score_doc))
  warn "value-parity score written → #{opts[:score_out]}"
end
exit(failed.zero? ? 0 : 1)
