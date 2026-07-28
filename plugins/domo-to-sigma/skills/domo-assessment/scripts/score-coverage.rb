#!/usr/bin/env ruby
# Phase 3 scoring for domo-assessment: the differentiator.
#
#   ruby scripts/score-coverage.rb --in <dir> --out <dir>
#
# Reads --in for probe.json (tier), inventory.json (cards) and, when present
# (audit scope granted), usage.json (per-card views/distinct_viewers). Scores
# every card into a value/cost/tag "artifact" and writes:
#
#   complexity.json     = { tier, artifacts:[...], rollup:{by_tag,totals,pct_auto} }
#   shortlist.json       = { tier, artifacts:[...] }   -- same artifacts, re-sorted
#   migration-plan.json = { tier, clusters, pages, duplicate_dashboards }
#
# --in and --out may be the same directory (that's how the pipeline runs it).
#
# FORMULAS — spec §5, verbatim (see refs/complexity-scoring.md). Do not "improve"
# these; the numbers are the point of this stage.
#
#   cost  = 10*n_unhandled + 3*n_manual + 1*n_hint
#   value = audit ? views * sqrt(max(distinct_viewers, 1))
#                  : 10 * (1 + n_beast_modes_on_this_card / 4.0)
#   score = value / (1.0 + cost)
#
# `audit` = usage.json is present (regardless of tier — Tier B fixtures can still
# carry an Activity Log; Tier A/B only changes whether Beast Mode buckets exist).
#
# Tags, evaluated IN ORDER (first match wins):
#   AUDIT && views == 0                            -> retire
#   n_unhandled >= 1                              -> needs-gap-scout
#   score >= 20 && (n_manual + n_unhandled) == 0  -> migrate-first
#   score >= 10                                    -> easy-win
#   else                                            -> moderate
#
# Structural signals fold into the counts on every tier:
#   card['pdp']              -> n_manual += 1
#   card['dataflow_sourced'] -> n_unhandled += 1
#
# Beast Mode buckets (Tier A only — Tier B never sees `beast_modes` populated,
# see discover-domo.rb) are classified per
# ../../domo-to-sigma/refs/beast-mode-to-sigma.md into auto/manual/unhandled
# (no `hint` tier for Beast Mode — see refs/complexity-scoring.md §1).
#
# This assessment never posts to Sigma / calls Domo; pure JSON in, JSON out.
# The one subprocess call (dup-dashboards.py) is best-effort: any failure there
# is swallowed so the run always finishes with a migration-plan.json.

require 'json'
require 'optparse'
require 'fileutils'
require 'tempfile'

options = {}
OptionParser.new do |o|
  o.on('--in DIR', 'Directory with probe.json/inventory.json(/usage.json) (required)') { |v| options[:in] = v }
  o.on('--out DIR', 'Write complexity.json/shortlist.json/migration-plan.json here (required)') { |v| options[:out] = v }
end.parse!

abort('--in DIR is required') unless options[:in]
abort('--out DIR is required') unless options[:out]
abort("--in dir not found: #{options[:in]}") unless File.directory?(options[:in])
FileUtils.mkdir_p(options[:out])

def read_json(path, default = nil)
  File.exist?(path) ? JSON.parse(File.read(path)) : default
end

probe     = read_json(File.join(options[:in], 'probe.json'), {})
inventory = read_json(File.join(options[:in], 'inventory.json'))
abort("inventory.json not found in #{options[:in]} -- run discover-domo.rb first") unless inventory
usage = read_json(File.join(options[:in], 'usage.json')) # nil unless audit scope was available

TIER  = probe['tier'] || 'B'
AUDIT = !usage.nil?
USAGE_BY_CARD = (usage && usage['by_card']) || {}

# ---- Beast Mode -> auto/manual/unhandled (spec §1 / beast-mode-to-sigma.md) --
# No `hint` tier here: bucket-a Beast Modes are already mechanical, same as
# Power BI DAX bucket-a (see refs/complexity-scoring.md).
UNHANDLED_RE = /\b(SQRT|CONVERT_TZ|MICROSECOND)\s*\(/i
MANUAL_RE = /\b(CEILING|FLOOR|PERIOD_ADD|PERIOD_DIFF|YEARWEEK|WEEK|OVER|FIXED)\s*\(|\bIN\s*\(|\bHLL_/i

def classify_beast_mode(sql)
  s = sql.to_s
  return 'unhandled' if s =~ UNHANDLED_RE
  return 'manual' if s =~ MANUAL_RE
  'auto'
end

# Per-card Beast Mode bucket counts. Tier B never has `beast_modes` populated
# (discover-domo.rb only fills it from the Tier-A-only "Beast Mode Refs"
# column), but guard on TIER anyway so a stray Tier-B fixture with a leaked
# beast_modes array can't silently score as Tier A.
def beast_bucket_counts(card)
  counts = { 'auto' => 0, 'manual' => 0, 'unhandled' => 0 }
  return counts unless TIER == 'A'
  Array(card['beast_modes']).each { |bm| counts[classify_beast_mode(bm['sql'])] += 1 }
  counts
end

# ---- score every card --------------------------------------------------------
cards = inventory['cards'] || []

artifacts = cards.map do |card|
  id = card['id']
  bm = beast_bucket_counts(card)
  n_auto      = bm['auto']
  n_hint      = 0
  n_manual    = bm['manual']
  n_unhandled = bm['unhandled']

  n_manual    += 1 if card['pdp']
  n_unhandled += 1 if card['dataflow_sourced']

  u = USAGE_BY_CARD[id] || {}
  views            = (u['views'] || card['views'] || 0).to_i
  distinct_viewers = (u['distinct_viewers'] || 0).to_i

  cost = (10 * n_unhandled) + (3 * n_manual) + (1 * n_hint)

  value =
    if AUDIT
      views * Math.sqrt([distinct_viewers, 1].max)
    else
      10 * (1 + (Array(card['beast_modes']).size / 4.0))
    end
  score = value / (1.0 + cost)

  tag =
    if AUDIT && views.zero?
      'retire'
    elsif n_unhandled >= 1
      'needs-gap-scout'
    elsif score >= 20 && (n_manual + n_unhandled).zero?
      'migrate-first'
    elsif score >= 10
      'easy-win'
    else
      'moderate'
    end

  {
    'id'               => id,
    'title'            => card['title'],
    'page_id'          => card['page_id'],
    'dataset_id'       => card['dataset_id'],
    'n_auto'           => n_auto,
    'n_hint'           => n_hint,
    'n_manual'         => n_manual,
    'n_unhandled'      => n_unhandled,
    'views'            => views,
    'distinct_viewers' => distinct_viewers,
    'value'            => value.round(3),
    'cost'             => cost,
    'score'            => score.round(3),
    'tag'              => tag
  }
end

# ---- rollup -------------------------------------------------------------------
by_tag = Hash.new(0)
artifacts.each { |a| by_tag[a['tag']] += 1 }

totals = {
  'n_artifacts' => artifacts.size,
  'n_auto'      => artifacts.sum { |a| a['n_auto'] },
  'n_hint'      => artifacts.sum { |a| a['n_hint'] },
  'n_manual'    => artifacts.sum { |a| a['n_manual'] },
  'n_unhandled' => artifacts.sum { |a| a['n_unhandled'] },
  'total_views' => artifacts.sum { |a| a['views'] }
}
n_features = totals['n_auto'] + totals['n_hint'] + totals['n_manual'] + totals['n_unhandled']
# auto-migratable = auto + hint (hint is a one-time review decision, not rework)
pct_auto = n_features.positive? ? (((totals['n_auto'] + totals['n_hint']).to_f / n_features) * 100).round(1) : 0.0

rollup = { 'by_tag' => by_tag, 'totals' => totals, 'pct_auto' => pct_auto }

complexity = { 'tier' => TIER, 'artifacts' => artifacts, 'rollup' => rollup }
File.write(File.join(options[:out], 'complexity.json'), JSON.pretty_generate(complexity))

# ---- shortlist: score desc, migrate-first/easy-win pulled to the front -------
TAG_PRIORITY = { 'migrate-first' => 0, 'easy-win' => 1, 'moderate' => 2, 'needs-gap-scout' => 3, 'retire' => 4 }
shortlist_artifacts = artifacts.sort_by { |a| [TAG_PRIORITY.fetch(a['tag'], 9), -a['score']] }
shortlist = { 'tier' => TIER, 'artifacts' => shortlist_artifacts }
File.write(File.join(options[:out], 'shortlist.json'), JSON.pretty_generate(shortlist))

# ---- migration-plan: clusters by shared dataset_id + per-page recommendation -
clusters = {}
artifacts.each do |a|
  dsid = (a['dataset_id'] || 'unknown').to_s
  c = (clusters[dsid] ||= { 'dataset_id' => dsid, 'card_ids' => [], 'card_count' => 0, 'by_tag' => Hash.new(0) })
  c['card_ids'] << a['id']
  c['card_count'] += 1
  c['by_tag'][a['tag']] += 1
end

pages = {}
artifacts.each do |a|
  pgid = (a['page_id'] || 'unknown').to_s
  p = (pages[pgid] ||= { 'page_id' => pgid, 'card_ids' => [], '_tags' => [] })
  p['card_ids'] << a['id']
  p['_tags'] << a['tag']
end
pages.each_value do |p|
  tags = p.delete('_tags')
  p['recommended_path'] =
    if tags.all? { |t| t == 'retire' }
      'retire'
    elsif tags.any? { |t| t == 'needs-gap-scout' }
      'gap-scout'
    else
      'convert'
    end
end

# ---- dup-dashboards.py: best-effort, never fails the run ---------------------
def run_dup_dashboards(cards, root_dir)
  dash_input = cards.map do |c|
    {
      'id'     => c['id'],
      'name'   => c['title'],
      'sources' => [c['dataset_id']].compact,
      'viz'    => [c['type']].compact,
      'usage'  => c['views']
    }
  end

  in_f  = Tempfile.new(['dup-dashboards-in', '.json'])
  out_f = Tempfile.new(['dup-dashboards-out', '.json'])
  begin
    in_f.write(JSON.generate(dash_input))
    in_f.flush
    script = File.join(root_dir, 'scripts', 'dup-dashboards.py')
    ok = system('python3', script, '--in', in_f.path, '--out', out_f.path)
    raise "dup-dashboards.py failed (exit #{$? && $?.exitstatus})" unless ok
    JSON.parse(File.read(out_f.path))
  rescue StandardError => e
    warn "score-coverage: dup-dashboards.py swallowed error -- #{e.class}: #{e.message}"
    { 'groups' => [], 'summary' => {} }
  ensure
    in_f.close!
    out_f.close!
  end
end

root_dir = File.expand_path('..', __dir__)
duplicate_dashboards = run_dup_dashboards(cards, root_dir)

migration_plan = {
  'tier'                 => TIER,
  'clusters'             => clusters,
  'pages'                => pages,
  'duplicate_dashboards' => duplicate_dashboards
}
File.write(File.join(options[:out], 'migration-plan.json'), JSON.pretty_generate(migration_plan))

warn "wrote complexity.json / shortlist.json / migration-plan.json " \
     "(#{artifacts.size} artifacts, tier=#{TIER}, audit=#{AUDIT}, pct_auto=#{pct_auto})"
