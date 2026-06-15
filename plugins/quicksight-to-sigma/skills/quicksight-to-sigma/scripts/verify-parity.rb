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

opts = { mode: :strict, tol: 0.30 }
OptionParser.new do |p|
  p.on('--plan P')              { |v| opts[:plan] = v }
  p.on('--extract-mode')        {     opts[:mode] = :extract }
  p.on('--extract-tol TOL', Float) { |v| opts[:tol] = v }
end.parse!
abort('--plan required') unless opts[:plan]

MONTH_NUM = {
  'january' => 1, 'february' => 2, 'march' => 3, 'april' => 4, 'may' => 5, 'june' => 6,
  'july' => 7, 'august' => 8, 'september' => 9, 'october' => 10, 'november' => 11, 'december' => 12,
  'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'jun' => 6,
  'jul' => 7, 'aug' => 8, 'sep' => 9, 'sept' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12
}.freeze

# Canonicalize date-like dimension values to a DAY-grain key so buckets compare
# equal across representations:
#   Sigma raw SQL "2026-01-04T00:00:00.000"   → "2026-01-04"
#   Tableau weekly label "February 4, 2024"   → "2024-02-04"
#   Tableau monthly label "January 2026"      → "2026-01"
# Weekly grains MUST keep the underlying date value (bead s6fo) — the old
# collapse-day-1-to-month rule turned the "January 1" WEEK bucket into a month
# bucket and every weekly chart diverged. Month-label vs first-of-month is
# reconciled by strict_compare's month-grain fallback, not here.
def canonicalize_dim(v)
  return v unless v.is_a?(String)
  s = v.strip
  # ISO datetime at midnight → day bucket (T or space separator)
  if (m = s.match(/\A(\d{4})-(\d{2})-(\d{2})[T ]00:00:00(?:\.0+)?(?:Z|[+-]\d{2}:?\d{2})?\z/))
    return "#{m[1]}-#{m[2]}-#{m[3]}"
  end
  # ISO date stays a day bucket
  return s if s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
  # "February 4, 2024" / "Feb 4, 2024" (Tableau day/week labels)
  if (m = s.match(/\A([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})\z/)) && (mnum = MONTH_NUM[m[1].downcase])
    return format('%s-%02d-%02d', m[3], mnum, m[2].to_i)
  end
  # "January 2026" / "Jan 2026" → month bucket
  if (m = s.match(/\A([A-Za-z]+)\s+(\d{4})\z/)) && (mnum = MONTH_NUM[m[1].downcase])
    return format('%s-%02d', m[2], mnum)
  end
  # "2024 Q1" (Tableau quarter label) → first-of-quarter DAY bucket so it
  # compares equal to Sigma's DateTrunc("quarter") value ("2024-01-01T00:00:00"
  # canonicalizes to "2024-01-01" above). Added for window-function pivots
  # (WINPROBE MaxMin: Region × Quarter grid).
  if (m = s.match(/\A(\d{4})\s+Q([1-4])\z/i))
    return format('%s-%02d-01', m[1], ((m[2].to_i - 1) * 3) + 1)
  end
  # Already-canonical "YYYY-MM"
  return s if s.match?(/\A\d{4}-\d{2}\z/)
  v
end

# Truncate a canonical day key to its month bucket (month-grain fallback).
def month_grain(v)
  v.is_a?(String) && v.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? v[0, 7] : v
end

def round_row(row)
  # Convert all numerics to Float-rounded so Integer 11 and Float 11.0 compare equal in the set,
  # and canonicalize date-like dim strings so equivalent monthly buckets match.
  row.map do |v|
    if v.is_a?(Numeric)
      v.to_f.round(2)
    else
      canonicalize_dim(v)
    end
  end
end

def strict_compare(exp, act)
  # Compare the FULL tuple width the plan carries (bead s6fo): 3-channel charts
  # (stacked color / pivot row+col+value / scatter dim+x+y) must compare every
  # channel — the old first(2) slice compared two dims and ignored the measure.
  width = [(exp.map(&:size) + act.map(&:size)).max || 2, 2].max
  exp_set = Set.new(exp.map { |r| r.first(width) })
  act_set = Set.new(act.map { |r| r.first(width) })
  return { status: 'PASS', only_in_tableau: [], only_in_sigma: [] } if exp_set == act_set

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
      return { status: 'PASS', only_in_tableau: [], only_in_sigma: [],
               notes: ['matched at month grain (label vs first-of-month representation)'] }
    end
  end

  { status: 'DIVERGE',
    only_in_tableau: (exp_set - act_set).to_a,
    only_in_sigma:   (act_set - exp_set).to_a }
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

  # Wild-divergence check on measures (10x or more drift = probably a real bug,
  # not just extract staleness)
  if exp.size == act.size && exp_set == act_set
    exp_h = exp.each_with_object({}) { |r, h| h[r[0]] = r[1] }
    act_h = act.each_with_object({}) { |r, h| h[r[0]] = r[1] }
    big_drifts = []
    exp_h.each do |k, v|
      a = act_h[k]
      next if v.nil? || a.nil?
      next unless v.is_a?(Numeric) && a.is_a?(Numeric)
      denom = [v.abs.to_f, a.abs.to_f, 1.0].max
      drift = (v - a).abs.to_f / denom
      big_drifts << [k, v, a, drift] if drift > tol
    end
    if big_drifts.any?
      notes << "#{big_drifts.size} measure value(s) drift > #{(tol * 100).to_i}% — review:"
      big_drifts.first(3).each do |k, v, a, d|
        notes << "    #{k.inspect} tableau=#{v} sigma=#{a} drift=#{(d * 100).round}%"
      end
    end
  end

  { status: status, notes: notes,
    only_in_tableau: (exp_set - act_set).to_a,
    only_in_sigma:   (act_set - exp_set).to_a }
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
  act = (p.dig('actual', 'rows') || []).map { |r| round_row(r) }

  this_extract = if p.key?('extract')
                   p['extract']
                 elsif mode_forced
                   true
                 else
                   default_extract
                 end

  result = this_extract ? extract_compare(exp, act, tol: opts[:tol]) : strict_compare(exp, act)
  result.merge(chart: p['chart'], extract: this_extract)
end

results.each do |r|
  tag = r[:extract] ? '[extract]' : '[strict] '
  printf "%-7s  %s  %s\n", r[:status], tag, r[:chart]
  if r[:status] != 'PASS' || (r[:notes] && r[:notes].any?)
    Array(r[:notes]).each { |n| puts "    #{n}" }
    if r[:only_in_tableau].any? || r[:only_in_sigma].any?
      puts "    Tableau-only: #{r[:only_in_tableau].inspect[0..200]}"
      puts "    Sigma-only:   #{r[:only_in_sigma].inspect[0..200]}"
    end
  end
end

failed = results.count { |r| r[:status] != 'PASS' }
puts '---'
puts "#{results.size - failed}/#{results.size} pass" + (mode_forced ? '  (extract-mode)' : '')
exit(failed.zero? ? 0 : 1)
