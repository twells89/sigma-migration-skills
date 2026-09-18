#!/usr/bin/env ruby
# frozen_string_literal: true
# build-parity-oracle.rb — join the two collectors into the plan verify-parity.rb verifies.
#
#   ruby scripts/build-parity-oracle.rb --workdir <dir> \
#     [--plan <dir>/parity-plan.json] [--expected <dir>/parity-expected.json] \
#     [--actuals <dir>/parity-actuals.json] [--out <dir>/parity-plan-verified.json] \
#     [--exclusions <dir>/parity-plan-exclusions.json]
#
# Reads:
#   parity-plan.json      build-parity-plan.rb — {charts:[{chart, sigma_element_id,
#                         sigma_kind, sigma_columns}]}; the authoritative TILE LIST
#   parity-expected.json  collect-parity-expected.rb — Domo's own rendered rows, by card id
#   parity-actuals.json   collect-parity-actuals.rb — Sigma's element exports, by chart name
#
# Writes the verify-parity plan (its documented contract, verify-parity.rb:11-16):
#   {"charts":[{"chart","expected":[[..]],"actual":{"rows":[[..]]},"sigma_columns":[..]}]}
# and the exclusion ledger phase6-parity-domo.rb enforces:
#   {"exclusions":[{"chart","reason"}]}
#
# EVERY TILE IS ACCOUNTED FOR OR THE BUILD FAILS. phase6-parity-domo.rb (#631)
# already refuses to emit a gate contract unless plan + exclusions covers every
# chartable element; this asserts the same invariant at the point the plan is
# BUILT, so the failure names the missing tile instead of surfacing later as an
# opaque census mismatch. A tile quietly missing from the plan shrinks gate 1's
# denominator and reads identically to a clean pass — 45/45 looks exactly like
# 65/65. That is the single most dangerous failure mode on this path.
#
# TILE -> DOMO MAPPING IS MECHANICAL, not name-matching: a workbook element id is
# `el-<cardId>` for a card's own tile and `el-<cardId>-summary` for the companion
# KPI Domo calls the card's summary number. So the base tile takes the card's
# rows and the companion takes a single [[title, summary_value]] row.
#
# SAME-DAY GUARD. Domo evaluates a card's relative date window at FETCH time, so
# a rolling-7-day card collected either side of midnight UTC legitimately
# disagrees with itself. Both collectors stamp fetched_at; joining across a UTC
# date boundary is refused rather than silently scored as a divergence. The gold
# audit flagged this for 28 of the 36 cards.
require 'json'
require 'set'
require 'optparse'
require 'time'
require 'date'
require_relative 'lib/ruby_compat'

opts = {}
OptionParser.new do |p|
  p.banner = 'Usage: build-parity-oracle.rb --workdir DIR [...]'
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--plan PATH') { |v| opts[:plan] = v }
  p.on('--expected PATH') { |v| opts[:exp] = v }
  p.on('--actuals PATH') { |v| opts[:act] = v }
  p.on('--out PATH') { |v| opts[:out] = v }
  p.on('--exclusions PATH') { |v| opts[:excl] = v }
  p.on('--allow-cross-day', 'proceed even if the two sides straddle a UTC date boundary') { opts[:xday] = true }
  p.on('--allow-stale-warehouse REASON', 'proceed even though the landed warehouse copy holds ' \
       'OLDER data than Domo (see the freshness guard) — only safe when no plan tile has a date ' \
       'dimension or a relative window') { |v| opts[:allow_stale] = v }
end.parse!
abort('--workdir required') unless opts[:wd] && Dir.exist?(opts[:wd])
wd = opts[:wd]
plan_path = opts[:plan] || File.join(wd, 'parity-plan.json')
exp_path  = opts[:exp]  || File.join(wd, 'parity-expected.json')
act_path  = opts[:act]  || File.join(wd, 'parity-actuals.json')
out_path  = opts[:out]  || File.join(wd, 'parity-plan-verified.json')
excl_path = opts[:excl] || File.join(wd, 'parity-plan-exclusions.json')
[plan_path, exp_path, act_path].each { |f| abort("missing #{f}") unless File.exist?(f) }

plan_doc = JSON.parse(File.read(plan_path))
charts   = plan_doc.is_a?(Hash) ? (plan_doc['charts'] || []) : Array(plan_doc)
expected = JSON.parse(File.read(exp_path))
actuals  = JSON.parse(File.read(act_path))
abort('parity-plan.json has no charts') if charts.empty?

# ---- same-day guard --------------------------------------------------------
ed = (Time.parse(expected['fetched_at']).utc.to_date rescue nil)
ad = (Time.parse(actuals['fetched_at']).utc.to_date rescue nil)
if ed && ad && ed != ad && !opts[:xday]
  abort <<~MSG
    REFUSING to join: the two sides were collected on different UTC days
      expected  #{expected['fetched_at']}
      actual    #{actuals['fetched_at']}
    Domo evaluates a card's relative date window at FETCH time, so a rolling
    7/14/28/30-day card compared across a date boundary diverges for a reason
    that has nothing to do with migration fidelity — a false RED that costs a
    debugging cycle. Re-collect both sides in one run, or pass
    --allow-cross-day if you have specifically established no plan tile carries
    a relative window.
  MSG
end

# ---- lookups ---------------------------------------------------------------
exp_cards = expected['cards'] || {}
source_cards_path = File.join(wd, 'discovery', 'cards.json')
source_cards = (JSON.parse(File.read(source_cards_path)) rescue []).each_with_object({}) do |card, out|
  out[card['id'].to_s] = card if card.is_a?(Hash) && card['id']
end
# reasons the Domo side already recorded, keyed by card id
exp_unavail = (expected['unavailable'] || []).each_with_object({}) { |u, h| h[u['card_id'].to_s] = u['reason'] }
# Actuals are keyed by ELEMENT ID, never by display name. Domo reuses generic
# summary labels, so 11 of the real 65 tiles share a name with another tile
# ("New Visits in Period" names 4 distinct elements). Name-keying let one
# element's export be scored as another's — a reproduced unearned PASS. See the
# header of collect-parity-actuals.rb.
act_by_eid = actuals['charts'] || {}
act_unavail = (actuals['unavailable'] || []).each_with_object({}) { |u, h| h[u['element_id'].to_s] = u['reason'] }

def card_id_for(element_id)
  m = /\Ael-(\d+)(?:-(summary))?(?:-verify)?\z/.match(element_id.to_s)
  return [nil, false] unless m
  [m[1], m[2] == 'summary']
end

# Parse the handful of date shapes the two sides actually emit. Domo's card-data
# returns ISO days ("2026-07-13") and month buckets ("2026-Mar"); Sigma's CSV
# export returns ISO ("2026-07-11", "2026-02"). Anything unrecognised is nil, and
# a nil simply excludes that tile from the freshness check — never a false alarm.
# A CONSTANT, not a local: a leading-underscore local is invisible inside `def`.
MONTH_ABBR = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
             .each_with_index.to_h { |m, i| [m, i + 1] }.freeze
def parse_date(v)
  s = v.to_s.strip
  if (m = /\A(\d{4})-(\d{2})-(\d{2})/.match(s))
    return (Date.new(m[1].to_i, m[2].to_i, m[3].to_i) rescue nil)
  end
  if (m = /\A(\d{4})-(\d{2})\z/.match(s))
    return (Date.new(m[1].to_i, m[2].to_i, 1) rescue nil)
  end
  if (m = /\A(\d{4})-([A-Z][a-z]{2})\z/.match(s)) && MONTH_ABBR[m[2]]
    return (Date.new(m[1].to_i, MONTH_ABBR[m[2]], 1) rescue nil)
  end
  nil
end

# Canonicalise Domo's month-bucket rendering to the ISO form Sigma exports.
# Domo renders a CalendarMonth dimension as "2026-Apr"; Sigma's CSV export gives
# "2026-04". Same month, different rendering — comparing the strings fails the
# tile with every measure identical. Measured on 2 tiles (Unsubscribes, Bounces
# Trend) on the 2026-08-07 run.
#
# This is normalisation, not masking: it only rewrites a value that parses as
# EXACTLY `YYYY-Mon`, and only into the same month's ISO form. A value that means
# something different is left alone, so a genuine dimension difference still
# fails. Anything not matching that one pattern is untouched.
#
# THREE grains are handled, each VERIFIED against the live corpus rather than
# assumed, because a wrong rule here would silently fail a tile forever:
#
#   month    "2026-Apr"      -> "2026-04"     (Unsubscribes, Bounces Trend)
#   quarter  "2025-Q3"       -> "2025-07"     first month of the quarter
#                                             (Projected Sales; 3/3 samples)
#   week     "Week-28 2026"  -> "2026-07-05"  SUNDAY-anchored week start, where
#                                             week 1 begins on the Sunday on or
#                                             before Jan 1 (Click-Through Rate,
#                                             Traffic Trend; 4/4 samples)
#
# THE WEEK RULE IS NOT ISO. ISO calls 2026-07-05 week 27; Domo calls it week 28.
# Using isocalendar() would have been off by one on every week-grained tile and
# looked like a data difference. Checked, not guessed.
def canonicalise_dim(rows)
  return [rows, 0] unless rows.is_a?(Array)
  n = 0
  week_rows = []
  out = rows.map.with_index do |r, idx|
    a = Array(r).dup
    s = a.first.to_s
    if (m = /\A(\d{4})-([A-Z][a-z]{2})\z/.match(s)) && MONTH_ABBR[m[2]]
      a[0] = format('%s-%02d', m[1], MONTH_ABBR[m[2]])
      n += 1
    elsif (m = /\A([A-Z][a-z]{2})\s+(\d{2})\z/.match(s)) && MONTH_ABBR[m[1]]
      a[0] = format('20%s-%02d', m[2], MONTH_ABBR[m[1]])
      n += 1
    elsif (m = /\A([A-Z][a-z]{2})\s+(\d{1,2}),\s*(\d{4})\z/.match(s)) && MONTH_ABBR[m[1]]
      a[0] = format('%s-%02d-%02d', m[3], MONTH_ABBR[m[1]], m[2].to_i)
      n += 1
    elsif (m = /\A(\d{4})-Q([1-4])\z/.match(s))
      a[0] = format('%s-%02d', m[1], ((m[2].to_i - 1) * 3) + 1)
      n += 1
    elsif (m = /\AWeek-(\d{1,2})\s+(\d{4})\z/.match(s))
      wk = m[1].to_i
      yr = m[2].to_i
      jan1 = Date.new(yr, 1, 1)
      # Sunday on or before Jan 1 == start of Domo's week 1.
      wk1 = jan1 - ((jan1.wday) % 7)
      a[0] = (wk1 + ((wk - 1) * 7)).to_s
      week_rows << idx
      n += 1
    end
    a
  end

  # Domo names a week by the calendar year attached to the label. Around New
  # Year, `Week-53 2024` and `Week-1 2025` can describe the SAME Sunday-based
  # physical week. Sigma emits one grouped row; after canonicalisation Domo has
  # two rows with the same date. Coalesce only those week-derived collisions,
  # and only when every trailing value is numeric/nil, so a legitimate second
  # string dimension can never be collapsed.
  by_date = Hash.new { |h, k| h[k] = [] }
  week_rows.each { |idx| by_date[out[idx][0]] << idx }
  removed = {}
  by_date.each_value do |indices|
    next unless indices.length > 1
    candidates = indices.map { |idx| out[idx] }
    width = candidates.map(&:length).max
    next unless candidates.all? do |row|
      (1...width).all? { |i| row[i].nil? || row[i].is_a?(Numeric) }
    end
    merged = [candidates.first[0]]
    (1...width).each do |i|
      values = candidates.map { |row| row[i] }.compact
      merged << (values.empty? ? nil : values.sum)
    end
    out[indices.first] = merged
    indices.drop(1).each { |idx| removed[idx] = true }
  end
  out = out.each_with_index.reject { |_row, idx| removed[idx] }.map(&:first)
  [out, n]
end

# Sigma element CSV exports use display formatting. Canonicalize only strings
# that unambiguously carry numeric decoration so strict parity compares Domo's
# raw numbers to their displayed equivalents without weakening plain strings.
def canonicalise_numeric_display(rows, expected_rows = nil)
  numeric_positions = nil
  expected = Array(expected_rows).map { |row| Array(row) }
  if expected_rows
    width = expected.map(&:length).max.to_i
    numeric_positions = (0...width).select do |index|
      expected.any? { |row| row[index].is_a?(Numeric) }
    end
  end
  actual_rows = Array(rows).map { |row| Array(row) }
  parsed_rows = actual_rows.map do |actual|
    actual.each_with_index.map do |value, index|
      next value if numeric_positions && !numeric_positions.include?(index)
      next value unless value.is_a?(String)
      s = value.strip
      next value if s.empty?
      negative = s.start_with?('(') && s.end_with?(')')
      s = s[1..-2].to_s.strip if negative
      percent = s.end_with?('%')
      suffix = percent ? nil : s[/([kKmMbBtT])\z/, 1]
      decorated = percent || suffix || s.match?(/\A[$€£¥]/) || s.include?(',')
      next value unless decorated
      body = s.gsub(/[,$€£¥\s]/, '').sub(/%\z/, '').sub(/[kKmMbBtT]\z/, '')
      begin
        number = Float(body)
      rescue ArgumentError, TypeError
        next value
      end
      multiplier = suffix ? { 'k' => 1e3, 'm' => 1e6, 'b' => 1e9, 't' => 1e12 }[suffix.downcase] : 1.0
      decimals = body.include?('.') ? body.split('.', 2).last.length : 0
      number *= multiplier
      tolerance = (10.0**-decimals) * multiplier / 2.0
      if percent
        number /= 100.0
        tolerance /= 100.0
      end
      number = -number if negative
      { 'value' => number, 'tolerance' => tolerance }
    end
  end

  unless numeric_positions
    return parsed_rows.map do |row|
      row.map { |value| value.is_a?(Hash) ? value['value'] : value }
    end
  end

  # Match rounded display values to source rows one-to-one within each complete
  # dimension key. A repeated key is valid (for example, a pivot with multiple
  # measures); independently taking the first candidate can assign one expected
  # row twice and make the result depend on row order.
  dim_positions = (0...[actual_rows.map(&:length).max, expected.map(&:length).max].max).to_a -
                  numeric_positions
  expected_by_key = Hash.new { |hash, key| hash[key] = [] }
  expected.each_with_index do |row, index|
    expected_by_key[dim_positions.map { |position| row[position] }] << index
  end
  actual_by_key = Hash.new { |hash, key| hash[key] = [] }
  actual_rows.each_with_index do |row, index|
    actual_by_key[dim_positions.map { |position| row[position] }] << index
  end

  actual_to_expected = {}
  actual_by_key.each do |key, actual_indices|
    expected_indices = expected_by_key[key]
    next if expected_indices.empty?
    edges = actual_indices.each_with_object({}) do |actual_index, out|
      parsed = parsed_rows[actual_index]
      decorated = numeric_positions.select { |position| parsed[position].is_a?(Hash) }
      next if decorated.empty?
      out[actual_index] = expected_indices.filter_map do |expected_index|
        candidate = expected[expected_index]
        next unless decorated.all? do |position|
          value = parsed[position]
          candidate[position].is_a?(Numeric) &&
            (candidate[position].to_f - value['value']).abs <=
              value['tolerance'] + (1e-9 * [candidate[position].to_f.abs, 1.0].max)
        end
        distance = decorated.sum do |position|
          (candidate[position].to_f - parsed[position]['value']).abs
        end
        [expected_index, distance]
      end.sort_by { |expected_index, distance| [distance, expected_index] }
    end

    expected_to_actual = {}
    assign = lambda do |actual_index, seen|
      Array(edges[actual_index]).each do |expected_index, _distance|
        next if seen[expected_index]
        seen[expected_index] = true
        prior = expected_to_actual[expected_index]
        if prior.nil? || assign.call(prior, seen)
          expected_to_actual[expected_index] = actual_index
          actual_to_expected[actual_index] = expected_index
          return true
        end
      end
      false
    end
    actual_indices.sort_by { |index| [Array(edges[index]).length, index] }
                  .each { |index| assign.call(index, {}) }
  end

  parsed_rows.each_with_index.map do |parsed, row_index|
    exact_index = actual_to_expected[row_index]
    exact = expected[exact_index] if exact_index
    parsed.each_with_index.map do |value, index|
      next value unless value.is_a?(Hash)
      if exact && exact[index].is_a?(Numeric)
        exact[index]
      else
        value['value']
      end
    end
  end
end

# The newest date appearing in a row set's FIRST column, or nil if that column is
# not uniformly a date.
def max_date(rows)
  return nil unless rows.is_a?(Array) && !rows.empty?
  ds = rows.map { |r| parse_date(Array(r).first) }
  return nil if ds.any?(&:nil?)
  ds.max
end

def same_parity_value?(left, right)
  return true if left == right
  return left.to_f == right.to_f if left.to_s.match?(/\A-?\d+(?:\.\d+)?\z/) &&
                                    right.to_s.match?(/\A-?\d+(?:\.\d+)?\z/)
  false
end

def dedupe_identical_columns(rows, columns)
  rows = Array(rows).map { |row| Array(row) }
  columns = Array(columns)
  return [rows, columns, []] if rows.empty?
  keep = []
  dropped = []
  (0...rows.map(&:length).max).each do |idx|
    prior = keep.find { |candidate|
      rows.all? { |row| same_parity_value?(row[candidate], row[idx]) }
    }
    prior ? dropped << idx : keep << idx
  end
  return [rows, columns, []] if dropped.empty?
  [rows.map { |row| keep.map { |idx| row[idx] } },
   keep.map { |idx| columns[idx] },
   dropped.map { |idx| columns[idx] || idx }]
end

def normalize_parity_header(value)
  value.to_s.gsub(/\([^)]*\)\z/, '').gsub(/[^a-z0-9]/i, '').downcase
end

def realign_actual_columns(rows, actual_columns, expected_columns)
  actual_columns = Array(actual_columns)
  expected_columns = Array(expected_columns)
  return [rows, actual_columns] unless actual_columns.length == expected_columns.length
  unused = (0...actual_columns.length).to_a
  order = []
  expected_columns.each do |wanted|
    idx = unused.find {
      |candidate| normalize_parity_header(actual_columns[candidate]) ==
                   normalize_parity_header(wanted)
    }
    return [rows, actual_columns] unless idx
    unused.delete(idx)
    order << idx
  end
  [Array(rows).map { |row| order.map { |idx| Array(row)[idx] } },
   order.map { |idx| actual_columns[idx] }]
end

def pop_grain_key(date, grain)
  case grain.to_s.downcase
  when 'day'
    date.to_s
  when 'week'
    (date - date.wday).to_s
  when 'month'
    date.strftime('%Y-%m')
  when 'year'
    date.year.to_s
  end
end

# Domo's POP card-data is a query transport, not the rendered chart table. It
# carries ITEM/VALUE/POP_PERIOD/POP_INDEX and may densify the selected interval
# to one row per day even when the chart grain is month (null VALUE on the
# filler days). Sigma exports the visible chart after alignment and pivoting:
# one row per display grain and one measure column per period. Reconstruct that
# visual table before strict parity so equivalent bars/lines do not fail solely
# on the two APIs' different transport shapes.
def normalize_pop_expected(card_data, source_card)
  return nil unless card_data.is_a?(Hash) && source_card.is_a?(Hash)
  return nil unless source_card['chartType'].to_s.downcase == 'badge_pop_bar_line'

  mappings = Array(card_data['mappings']).map { |mapping| mapping.to_s.upcase }
  item_idx = mappings.index('ITEM')
  value_idx = mappings.index('VALUE')
  period_idx = mappings.index('POP_PERIOD')
  alignment_idx = mappings.index('POP_INDEX')
  return nil unless item_idx && value_idx && period_idx && alignment_idx
  return nil unless mappings.count('VALUE') == 1

  grain = source_card.dig('dateGrain', 'dateTimeElement').to_s.downcase
  return nil unless %w[day week month year].include?(grain)

  rows = Array(card_data['rows']).map { |row| Array(row) }
  periods = rows.map { |row| row[period_idx] }.compact.map(&:to_i).uniq.sort
  return nil unless periods.include?(0) && periods.length >= 2

  primary_dates = {}
  rows.each do |row|
    next unless row[period_idx].to_i.zero?
    date = Date.parse(row[item_idx].to_s) rescue nil
    primary_dates[row[alignment_idx].to_i] = date if date
  end
  return nil if primary_dates.empty?

  aggregation = Array(source_card['columns']).find {
    |column| column['mapping'].to_s.upcase == 'VALUE'
  }.to_h['aggregation'].to_s.upcase
  aggregation = 'SUM' if aggregation.empty?
  values_by_bucket = Hash.new { |hash, key| hash[key] = Hash.new { |h, period| h[period] = [] } }
  bucket_dates = {}
  rows.each do |row|
    next if row[period_idx].nil?
    period = row[period_idx].to_i
    aligned_date = primary_dates[row[alignment_idx].to_i]
    next unless aligned_date
    bucket = pop_grain_key(aligned_date, grain)
    next unless bucket
    bucket_dates[bucket] ||= aligned_date
    value = row[value_idx]
    values_by_bucket[bucket][period] << value if value.is_a?(Numeric)
  end
  if %w[AVG AVERAGE COUNT_DISTINCT DISTINCT_COUNT COUNT\ DISTINCT].include?(aggregation) &&
     values_by_bucket.any? { |_bucket, by_period| by_period.any? { |_period, values| values.length > 1 } }
    return nil
  end

  output_rows = bucket_dates.keys.sort_by { |bucket| bucket_dates[bucket] }.map do |bucket|
    [bucket] + periods.map do |period|
      values = values_by_bucket[bucket][period]
      next nil if values.empty?
      case aggregation
      when 'AVG', 'AVERAGE' then values.sum.to_f / values.length
      when 'MIN' then values.min
      when 'MAX' then values.max
      else values.sum
      end
    end
  end
  {
    'rows' => output_rows,
    'columns' => ['Date'] + periods.map { |period| period.zero? ? 'Current period' : "Period #{period}" },
    'transform' => 'domo-pop-aligned-grain',
  }
end

stale_evidence = []
canonicalised = 0
pop_normalized = 0

# PRIOR exclusions, loaded BEFORE the loop and honoured over verification.
#
# build-parity-exclusions.rb (#649) excludes tiles that cannot agree BY
# CONSTRUCTION — today, a refused date window: Domo aggregates over a window the
# Sigma tile does not have. Such a tile is still present in parity-plan.json (the
# plan lists every chartable element), and both its sides are perfectly
# collectable — so without this check the oracle would happily "verify" it and
# score a guaranteed DIVERGE that says nothing about conversion quality. The
# construction-level reason is the more fundamental one, so it wins.
# KEYED BY ELEMENT ID WHERE AVAILABLE. build-parity-exclusions.rb records
# `evidence.element_id` on every entry, so the match can be exact. Keying by
# display name instead swept every same-named tile into one tile's exclusion:
# with "New Visits in Period" naming 4 elements and only one card carrying a
# refused date window, all four were exempted from scoring — three of them fully
# collectable and never disqualified. That is silent inflation (a smaller
# denominator reads as a cleaner pass), which is what this chain exists to refuse.
#
# A name-only entry (no element_id) is still honoured, but consumed ONCE rather
# than matching every same-named tile — an ambiguous exclusion should under-apply,
# not over-apply.
prior_by_eid = {}
prior_by_name = {}
if File.exist?(excl_path)
  doc = (JSON.parse(File.read(excl_path)) rescue nil)
  list = doc.is_a?(Hash) ? Array(doc['exclusions']) : Array(doc)
  list.each do |e|
    next unless e.is_a?(Hash)
    eid = (e['element_id'] || e.dig('evidence', 'element_id')).to_s
    if eid.empty?
      (prior_by_name[e['chart'].to_s] ||= []) << e
    else
      prior_by_eid[eid] = e
    end
  end
end

verified = []
exclusions = []
seen_eids = Set.new

charts.each do |c|
  name = c['chart'].to_s
  eid  = c['sigma_element_id'].to_s
  cid, is_summary = card_id_for(eid)

  # The SAME element id listed twice in the plan. collect-parity-actuals.rb
  # records this in `unavailable` and refuses to overwrite the first export —
  # but that reason was unreachable here, because act_by_eid[eid] resolves for
  # every occurrence, so the second entry looked perfectly healthy and was
  # scored a second time against the first one's data. Two plan rows, one
  # measurement, both reported.
  #
  # Reachable from real data: a Domo card pinned to two dashboard pages is
  # ordinary, domo-discover.rb applies no cross-page dedup, and build-workbook's
  # element id derives purely from the card id — so cards.json can legitimately
  # carry the same card twice and the plan inherits the duplicate.
  if seen_eids.include?(eid)
    exclusions << { 'chart' => name, 'element_id' => eid, 'reason' =>
      'element id appears more than once in the parity plan — only the first ' \
      'occurrence is scored; a duplicate would be measured twice against one ' \
      'export. Investigate why the plan double-lists this element (a card ' \
      'pinned to two pages is the usual cause).' }
    next
  end
  seen_eids << eid

  # Already excluded upstream for a construction-level reason — carry it through
  # verbatim rather than re-deriving or overriding it. Element id first; a
  # name-only entry is consumed once (shift) so it cannot sweep its same-named
  # siblings.
  pe = prior_by_eid[eid] || (prior_by_name[name] && prior_by_name[name].shift)
  if pe
    exclusions << pe
    next
  end

  # --- the Domo (expected) side ---
  if cid.nil?
    exclusions << { 'chart' => name, 'element_id' => eid, 'reason' =>
      "element id #{eid.inspect} is not of the form el-<cardId>[-summary], so it cannot be " \
      'traced back to a Domo card — no source value exists to compare against' }
    next
  end
  card = exp_cards[cid]
  if card.nil?
    reason = exp_unavail[cid] || 'Domo card-data returned nothing for this card'
    exclusions << { 'chart' => name, 'element_id' => eid,
                    'reason' => "no Domo source value: #{reason}" }
    next
  end
  # A KPI tile plots ONE value however it was built. That is true of a `-summary`
  # companion AND of a Rule-0 KPI — a card whose own element is `kpi-chart`, with
  # no separate companion. Keying only on `-summary` left every Rule-0 KPI taking
  # the card's full `rows` payload, which for a multi-column card (a
  # CATEGORY|CURRENT|TARGET gauge, say) can never match Sigma's single-cell KPI
  # export: a shape mismatch that reads as a value divergence, exactly the bug
  # already fixed once for the companions below.
  is_kpi = is_summary || c['sigma_kind'].to_s == 'kpi-chart'
  exp_columns = card['columns']
  expected_transform = nil

  if is_kpi
    sv = card['summary_value']
    if sv.nil?
      exclusions << { 'chart' => name, 'element_id' => eid, 'reason' =>
        'KPI tile, but the Domo card reports no summary number ' \
        '(summary.status was not a completed run) — Domo declining to compute a ' \
        'KPI is not a zero, so there is no value to compare' }
      next
    end
    # A KPI tile plots ONE value, and Sigma's element export for it is a
    # single-column CSV — one header, one cell. So the expected side must be a
    # single-cell row too. An earlier cut emitted [[title, value]] and every
    # companion tile DIVERGED with "expected [["Page Views", 22.0]] vs actual
    # [[22.0]]" — a shape mismatch masquerading as a value mismatch, which would
    # have read as 29 genuine parity failures. Caught by running the emitted plan
    # through verify-parity.rb rather than assuming the contract.
    exp_rows = [[sv]]
  else
    exp_rows = card['rows']
    if !exp_rows.is_a?(Array) || exp_rows.empty?
      exclusions << { 'chart' => name, 'element_id' => eid,
                      'reason' => 'Domo card returned no rows' }
      next
    end
    normalized_pop = normalize_pop_expected(card, source_cards[cid])
    if normalized_pop
      exp_rows = normalized_pop['rows']
      exp_columns = normalized_pop['columns']
      expected_transform = normalized_pop['transform']
      pop_normalized += 1
    end
  end

  # --- the Sigma (actual) side ---
  # BY ELEMENT ID. Looking this up by display name scored one element's export as
  # another's whenever two tiles shared a title (11 of the real 65 do).
  act = act_by_eid[eid]
  if act.nil?
    reason = act_unavail[eid] || 'no Sigma export recorded for this element'
    exclusions << { 'chart' => name, 'element_id' => eid,
                    'reason' => "no Sigma actual: #{reason}" }
    next
  end
  if !is_kpi && card['num_rows'].to_i == 500 && Array(act['rows']).length > 500
    exclusions << {
      'chart' => name, 'element_id' => eid,
      'reason' => "Domo card-data returned exactly 500 rows (the endpoint cap) while Sigma " \
                  "returned #{Array(act['rows']).length}; the source collector is truncated, " \
                  'so scoring the extra live rows as a migration divergence would be false.',
      'evidence' => { 'card_id' => cid, 'domo_rows' => 500,
                      'sigma_rows' => Array(act['rows']).length,
                      'kind' => 'domo-card-data-cap' }
    }
    next
  end
  act_rows, act_columns = realign_actual_columns(act['rows'], act['columns'], exp_columns)
  act_rows, act_columns, _dropped_actual_columns =
    dedupe_identical_columns(act_rows, act_columns)

  # Canonicalise the dimension BEFORE the row is recorded — doing it afterwards
  # mutates a local the emitted hash no longer references, which is exactly the
  # bug this comment exists to stop recurring.
  exp_rows, expected_canon_n = canonicalise_dim(exp_rows)
  act_rows, actual_canon_n = canonicalise_dim(act_rows)
  act_rows = canonicalise_numeric_display(act_rows, exp_rows)
  canonicalised += expected_canon_n + actual_canon_n

  verified_entry = {
    'chart'          => name,
    'sigma_element_id' => eid,
    'sigma_kind'     => c['sigma_kind'],
    'sigma_columns'  => c['sigma_columns'],
    'domo_card_id'   => cid,
    'expected'       => exp_rows,
    # NOTE the deliberate absence of `requested_columns`. verify-parity.rb's
    # extract_rows only realigns when a side carries BOTH `columns` and
    # `requested_columns` (:167-177), and realign resolves each requested name
    # against the returned headers, raising if one is missing. The plan's
    # `sigma_columns` are Sigma column IDs (`d-date`, `m-views`) while the CSV
    # headers are DISPLAY names (`Date`, `Views`), so feeding them in as
    # requested columns makes every tile raise — measured here, not guessed.
    # Without it the export's own column order is used, which is already the
    # element's plotted order. `columns` is still carried for diagnostics.
    'actual'         => { 'rows' => act_rows, 'columns' => act_columns },
  }
  verified_entry['expected_transform'] = expected_transform if expected_transform
  verified << verified_entry

  # ---- warehouse-freshness evidence, collected as we go -------------------
  # See the guard below. Recorded per tile whose first column parses as a date
  # on BOTH sides, which is the only shape where "whose data is newer" is a
  # meaningful question.
  ed = max_date(exp_rows)
  ad = max_date(act_rows)
  stale_evidence << { 'chart' => name, 'element_id' => eid,
                      'domo_max' => ed.to_s, 'sigma_max' => ad.to_s,
                      'days' => (ed - ad).to_i } if ed && ad && ed > ad
end

# ---- WAREHOUSE FRESHNESS GUARD ---------------------------------------------
# THERE ARE THREE CLOCKS HERE AND THE SAME-DAY GUARD ABOVE ONLY WATCHES TWO.
#
# That guard refuses when the two COLLECTORS ran on different UTC days. But the
# Sigma side does not read Domo — it reads a warehouse COPY that
# domo-import-to-snowflake landed at some earlier moment. If that snapshot is
# older than Domo's live data, both collectors can run in the same second and
# still be comparing different data.
#
# MEASURED 2026-08-07, the run this guard exists because of. The landed table
# carried Domo's own _BATCH_LAST_RUN_ = 2026-08-05T14:41:55Z with a newest fact
# date of 2026-08-04, while Domo rendered through 2026-08-06. Two days stale, and
# gate 1 reported 24.6% (14/57) — which read exactly like 43 broken tiles:
#   * 3 trend tiles offset by 2 days, with measures aligning 1:1 by POSITION
#   * every %-change KPI SIGN-INVERTED (+0.198 -> -0.312), because a 7-day
#     window over data ending 2 days earlier reshuffles which rows fall in the
#     current vs prior period, and a ratio near 1 flips
#   * windowed counts off by ~3%
#   * and the 14 that passed were exactly the non-windowed / static-dataset
#     tiles, passing byte-exactly (3180018 == 3180018)
# Nothing about that failure points at the warehouse being behind. Someone would
# reasonably spend a day auditing the converter, whose formulas were correct.
#
# DETECTION USES DATA THE JOIN ALREADY HOLDS — no extra API call, no reliance on
# _BATCH_LAST_RUN_ existing. For every tile whose first column is uniformly a
# date on both sides, compare the newest date. Domo newer than Sigma means the
# warehouse cannot possibly match, whatever the conversion does.
#
# TWO tiles must agree before refusing. One tile could legitimately differ (a
# top-N or a filter truncating Sigma's range); a second independent tile showing
# the same direction is no longer explainable that way. Reporting every tile
# either way, so the operator sees the spread rather than one number.
unless stale_evidence.empty?
  worst = stale_evidence.max_by { |e| e['days'] }
  if stale_evidence.size >= 2 && !opts[:allow_stale]
    warn ''
    warn 'REFUSING to emit a parity plan: the WAREHOUSE COPY IS STALE relative to Domo.'
    warn ''
    stale_evidence.sort_by { |e| -e['days'] }.first(8).each do |e|
      warn format('    %-26s domo through %s, sigma through %s  (%+d days)',
                  e['element_id'], e['domo_max'], e['sigma_max'], -e['days'])
    end
    warn "    ... and #{stale_evidence.size - 8} more" if stale_evidence.size > 8
    warn ''
    warn "#{stale_evidence.size} date-dimensioned tile(s) show Domo holding data newer than the"
    warn "warehouse, by up to #{worst['days']} day(s). Scoring this would produce a large, entirely"
    warn 'misleading FAIL: windowed KPIs shift, %-change ratios can invert sign, and only the'
    warn 'non-windowed tiles would pass. The conversion is not what is wrong.'
    warn ''
    warn 'FIX: re-land the datasets, then re-run the parity phase, so both sides see one snapshot:'
    warn '    ruby ../domo-import-to-snowflake/scripts/domo_import_to_snowflake.rb --workdir <wd> ...'
    warn 'Override with --allow-stale-warehouse REASON only if you have established that every'
    warn 'plan tile is insensitive to the gap (no relative windows, no date dimensions).'
    exit 9
  end
  warn "WARNING: #{stale_evidence.size} tile(s) show Domo newer than the warehouse " \
       "(worst #{worst['days']} day(s)) — proceeding because " \
       "#{opts[:allow_stale] ? "--allow-stale-warehouse: #{opts[:allow_stale]}" : 'only one tile is affected'}."
end

# ---- the invariant ---------------------------------------------------------
covered = verified.size + exclusions.size
if covered != charts.size
  abort "INTERNAL: #{covered} tiles accounted for but the plan lists #{charts.size} — " \
        'every tile must be verified or excluded; refusing to emit a partial plan.'
end

# A prior exclusion naming a tile that is NOT in the plan would otherwise be
# dropped on write, since the loop above only ever visits plan tiles. That should
# not happen (both derive from the same chartable set) but if it does, the census
# in phase6-parity-domo.rb — which measures against workbook-spec.json, not the
# plan — would fail on a tile that WAS legitimately accounted for. Carry them
# through and say so, rather than trusting the two derivations to agree forever.
emitted = exclusions.map { |e| e.object_id }.to_set
orphaned = prior_by_eid.values.reject { |e| emitted.include?(e.object_id) } +
           prior_by_name.values.flatten           # anything left unconsumed
unless orphaned.empty?
  warn "carrying through #{orphaned.size} prior exclusion(s) for tile(s) absent from the plan:"
  orphaned.each { |e| warn "    #{e['chart']} — #{e['reason']}" }
  exclusions.concat(orphaned)
end

File.write(out_path, JSON.pretty_generate('charts' => verified))
File.write(excl_path, JSON.pretty_generate('exclusions' => exclusions))

warn "wrote #{out_path}      #{verified.size} tile(s) to verify"
warn "normalized #{pop_normalized} Domo POP transport(s) to aligned visual-grain tables" if pop_normalized.positive?
warn "wrote #{excl_path}  #{exclusions.size} tile(s) excluded WITH a reason"
warn "coverage: #{verified.size} + #{exclusions.size} = #{charts.size} plan tiles (complete)"
unless exclusions.empty?
  warn "\nEXCLUDED — each of these is a tile gate 1 will NOT score. Read them; an" \
       "\nexclusion is a hole in the evidence, not a pass:"
  exclusions.each { |e| warn "  #{e['chart']}\n      #{e['reason']}" }
end
exit 0
