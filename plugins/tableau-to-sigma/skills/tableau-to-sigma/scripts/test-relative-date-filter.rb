#!/usr/bin/env ruby
# Regression test for ROLLING relative-date filter emission.
#
# Tableau relative-date filters ("last 6 months", "this year", "next 2 quarters")
# used to be FROZEN to static mode:between bounds for any offset window — so the
# filter stopped rolling and, when the frozen range missed the data, the whole
# dashboard rendered empty (the customer "leading indicators" dashboard). The
# fallback path even emitted `mode:'relative'` + `count`, which is NOT a valid
# Sigma date-range mode (valid: between/last/next/current/on/before/after/custom)
# and silently dropped.
#
# The fix maps Tableau offsets → Sigma's native ROLLING modes:
#   this <period>  (0,0)      → mode:current unit
#   last N <period>(-N+1..0)  → mode:last  value:N unit includeToday
#   next N <period>           → mode:next  value:N unit includeToday
# and only falls back to frozen mode:between for shifted/spanning windows.
#
# Deterministic, offline, creds-free: extracts the pure helper methods straight
# from build-charts-from-signals.rb and evals them, so it locks the exact
# mapping without spinning up the whole builder.
#
# Usage:  ruby scripts/test-relative-date-filter.rb

require 'date'
require 'time'

SRC = File.join(__dir__, 'build-charts-from-signals.rb')
src = File.read(SRC)

# Slice the contiguous helper block: relative_period_bounds → sigma_date_unit →
# relative_date_filter_fields (ends at the sole `[nil, :unsupported]`).
m = src[/def relative_period_bounds.*?\[nil, :unsupported\]\nend/m]
abort "could not extract helper methods from #{SRC} — did they move/rename?" unless m
eval(m) # rubocop:disable Security/Eval — trusted first-party source, test-only

# Fix "now" so bounds are deterministic (frozen fallback assertions).
NOW = Time.new(2026, 7, 1, 12, 0, 0)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ── this <period> → mode:current ────────────────────────────────────────────
f, k = relative_date_filter_fields('year', 0, 0, NOW)
check(k == :current && f == { 'mode' => 'current', 'unit' => 'year' },
      "this year → mode:current unit:year (got #{k} #{f.inspect})", fails)

# ── last 6 months (Tableau first=-5,last=0) → rolling mode:last ─────────────
f, k = relative_date_filter_fields('month', -5, 0, NOW)
check(k == :last && f == { 'mode' => 'last', 'value' => 6, 'unit' => 'month', 'includeToday' => true },
      "last 6 months → mode:last value:6 unit:month includeToday:true (got #{k} #{f.inspect})", fails)

# ── last 3 COMPLETE months (first=-3,last=-1) → includeToday:false ──────────
f, k = relative_date_filter_fields('month', -3, -1, NOW)
check(k == :last && f['value'] == 3 && f['includeToday'] == false,
      "last 3 complete months → value:3 includeToday:false (got #{f.inspect})", fails)

# ── next 2 quarters incl current (first=0,last=1) → mode:next ──────────────
f, k = relative_date_filter_fields('quarter', 0, 1, NOW)
check(k == :next && f == { 'mode' => 'next', 'value' => 2, 'unit' => 'quarter', 'includeToday' => true },
      "next 2 quarters → mode:next value:2 includeToday:true (got #{k} #{f.inspect})", fails)

# ── week grain → Sigma 'week-starting-sunday' (no bare 'week') ──────────────
f, k = relative_date_filter_fields('week', -3, 0, NOW)
check(k == :last && f['unit'] == 'week-starting-sunday' && f['value'] == 4,
      "last 4 weeks → unit:week-starting-sunday value:4 (got #{f.inspect})", fails)

# ── day grain rolls even though relative_period_bounds can't bound days ─────
f, k = relative_date_filter_fields('day', -6, 0, NOW)
check(k == :last && f['unit'] == 'day' && f['value'] == 7,
      "last 7 days → mode:last value:7 unit:day (got #{f.inspect})", fails)

# ── shifted/spanning window (no rolling mode fits) → frozen mode:between ────
f, k = relative_date_filter_fields('month', -8, -3, NOW)
check(k == :frozen && f['mode'] == 'between' && f['startDate'] && f['endDate'],
      "shifted month window → frozen mode:between with bounds (got #{k} #{f.inspect})", fails)

# ── unsupported grain + unboundable window → [nil,:unsupported] (dropped) ───
f, k = relative_date_filter_fields('weekday', -8, -3, NOW)
check(k == :unsupported && f.nil?,
      "weekday shifted window → unsupported/nil (got #{k} #{f.inspect})", fails)

# ── the OLD bug must never resurface: no invalid mode:'relative' / 'count' ──
all = [
  relative_date_filter_fields('month', -5, 0, NOW),
  relative_date_filter_fields('year', 0, 0, NOW),
  relative_date_filter_fields('quarter', 0, 1, NOW),
].map(&:first).compact
check(all.none? { |x| x['mode'] == 'relative' || x.key?('count') },
      "never emits invalid mode:'relative' or 'count' key", fails)
check(all.all? { |x| %w[current last next between].include?(x['mode']) },
      "every emitted mode is a valid Sigma date-range mode", fails)

puts
if fails.empty?
  puts 'ALL PASS — relative-date filters emit rolling mode:current/last/next (frozen only for shifted windows)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
