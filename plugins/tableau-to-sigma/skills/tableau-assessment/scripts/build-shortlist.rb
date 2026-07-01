#!/usr/bin/env ruby
# Cross-tabulate workbook usage (from Admin Insights TS Events) with per-workbook
# complexity (from complexity.json) and emit a ranked migration shortlist.
#
# Scoring:
#   value = accesses × √(distinct_viewers)
#   cost  = 10·unhandled + 3·manual + 1·hint
#   score = value / (1 + cost)
#
# Tags (when usage IS known — Cloud / Admin Insights):
#   accesses == 0                                 → "retire"
#   unhandled >= 1                                → "needs-gap-scout"
#   score >= 20 and (manual + unhandled) == 0     → "migrate-first"
#   score >= 10                                   → "easy-win"
#   else                                          → "moderate"
#
# When usage is NOT known (inventory 'usage_available' == false, e.g. a Tableau
# Server REST-only inventory with no Admin Insights / repository DB), we must NOT
# tag zero-access workbooks "retire" — a missing access count is not proof of
# disuse. In that mode we rank by inverse complexity (easiest first) and tag on
# complexity alone.
#
# Usage:
#   ruby scripts/build-shortlist.rb --out /tmp/assessment-<site>
#
# Reads:  <out>/inventory.json (workbook_usage + workbook_inventory),
#         <out>/complexity.json
# Writes: <out>/shortlist.json

require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--out DIR') { |v| opts[:out] = v }
end.parse!
abort('--out required') unless opts[:out]

inventory  = JSON.parse(File.read(File.join(opts[:out], 'inventory.json')))
complexity = JSON.parse(File.read(File.join(opts[:out], 'complexity.json')))

usage_by_name = (inventory['workbook_usage'] || []).each_with_object({}) do |w, h|
  h[w['name']] = w
end
inv_by_name = (inventory['workbook_inventory'] || []).each_with_object({}) do |w, h|
  h[w['name']] = w
end
# Fallback: if workbook_usage is empty/missing, accept accesses+actors fields
# directly on workbook_inventory rows (older inventory.json shape).
if usage_by_name.empty?
  inv_by_name.each do |name, w|
    next unless w['accesses'] || w['actors']
    usage_by_name[name] = { 'accesses' => w['accesses'].to_i, 'actors' => w['actors'].to_i }
  end
end

# usage_available is set explicitly by inventory-rest.rb (Server); for older
# Cloud inventory.json shapes that predate the flag, infer it from whether any
# usage rows survived.
usage_known = inventory.key?('usage_available') ? inventory['usage_available'] : !usage_by_name.empty?

rows = []
complexity.each do |luid, r|
  name = r['name']
  usage = usage_by_name[name]
  inv   = inv_by_name[name]
  accesses = (usage && usage['accesses']) || 0
  actors   = (usage && usage['actors'])   || 0

  cost  = r['n_unhandled'] * 10 + r['n_manual'] * 3 + r['n_hint'] * 1

  if usage_known
    value = accesses * Math.sqrt([actors, 1].max).to_f
    score = value / (1 + cost).to_f
    tag =
      if accesses.zero?
        'retire'
      elsif r['n_unhandled'] >= 1
        'needs-gap-scout'
      elsif score >= 20 && (r['n_manual'] + r['n_unhandled']).zero?
        'migrate-first'
      elsif score >= 10
        'easy-win'
      else
        'moderate'
      end
  else
    # No usage signal: rank by inverse complexity (easiest first), tag on
    # complexity alone. Never "retire" — absence of a count is not disuse.
    value = nil
    score = 100.0 / (1 + cost)
    tag =
      if r['n_unhandled'] >= 1
        'needs-gap-scout'
      elsif (r['n_manual'] + r['n_unhandled']).zero?
        'easy-win'
      else
        'moderate'
      end
  end

  rows << {
    'name'                 => name,
    'luid'                 => luid,
    'url'                  => inv && inv['url'],
    'accesses'             => accesses,
    'actors'              => actors,
    'auto'                 => r['n_auto'],
    'hint'                 => r['n_hint'],
    'manual'               => r['n_manual'],
    'unhandled'            => r['n_unhandled'],
    # Pre-migration parity PREDICTION (y9rd.6) carried through from complexity.json.
    'predicted_parity_pct' => r['predicted_parity_pct'],
    'parity_band'          => r['parity_band'],
    'value'                => value&.round(1),
    'cost'                 => cost,
    'score'                => score.round(2),
    'tag'                  => tag
  }
end

rows.sort_by! { |r| -r['score'] }

File.write(File.join(opts[:out], 'shortlist.json'), JSON.pretty_generate(rows))
puts "wrote shortlist.json (#{rows.size} workbooks)"
unless usage_known
  puts "NOTE: no usage data (Tableau Server REST-only inventory) — ranked by complexity"
  puts "      (easiest first); 'acc' column is 0 for all rows and NOT a retire signal."
end
puts
printf "%-46s %5s %5s %5s %5s %6s %7s %s\n", 'Workbook', 'acc', 'view', 'manl', 'unhd', 'parity', 'score', 'tag'
rows.each do |r|
  printf "%-46s %5d %5d %5d %5d %4.0f%%%s %7.2f %s\n",
    (r['name'] || '')[0, 45], r['accesses'], r['actors'], r['manual'], r['unhandled'],
    r['predicted_parity_pct'].to_f, r['parity_band'].to_s, r['score'], r['tag']
end
