#!/usr/bin/env ruby
# Phase 1.5 — Reuse existing Sigma data models when one already covers the
# Tableau workbook's needs. Goals:
#   1. Avoid DM sprawl: don't add a 4th "Orders" DM when the customer already
#      has three that all point at the same warehouse table.
#   2. Performance: skip Phase 2 (warehouse column discovery) and Phase 3
#      (DM build + POST + validate) when reusing — often 2-3 min savings.
#
# This script DOES NOT mutate any DM. It only scores existing DMs against the
# Tableau workbook signature and recommends a candidate (with a warning about
# inherited columns / RLS / metrics). The downstream phase decides whether to
# reuse or create new.
#
# Usage:
#   ruby scripts/find-or-pick-dm.rb \
#     --workbook-signature /tmp/<name>/workbook-signature.json \
#     --out /tmp/<name>/dm-match.json \
#     [--limit 200]                    # max DMs to scan
#     [--min-score 0.6]                # below: no recommendation, build new
#     [--force-new]                    # always recommend new (skip scan)
#
# Input signature shape (produced by Phase 1 + 2.5 — adjust paths as needed):
#   {
#     "tableau_workbook":   "Monthly Revenue",
#     "warehouse_tables":   ["CSA.ORDER_FACT"],          # FQN list
#     "referenced_columns": ["ORDER_DATE","GROSS_REVENUE","REGION","STATE"],
#     "measures":           [{"col":"GROSS_REVENUE","derivation":"Sum"}, ...]
#   }
#
# Output: dm-match.json with shape documented in SKILL.md Phase 1.5.
# Exit: 0 if any candidate ≥ --min-score, 1 if none (caller can choose to
# build new). Never aborts on missing inputs — always emits a result file so
# the agent can decide.

require 'json'
require 'yaml'
require 'net/http'
require 'uri'
require 'optparse'

# Default limit 25: perf testing (2026-05-22) showed the picker's top-score
# saturates by ~25 DMs in this org; the wall-time curve elbows hard after 50
# (0.065s/DM → 0.25s/DM — Sigma drops off a cached-spec hot path). limit=25
# finishes in ~2s. Earlier default was 50; dropping to 25 saves ~12s per
# picker run with no score regression. beads-sigma-3kw.
opts = { limit: 25, min_score: 0.6 }
OptionParser.new do |p|
  p.on('--workbook-signature P') { |v| opts[:sig]      = v }
  p.on('--out P')                { |v| opts[:out]      = v }
  p.on('--limit N', Integer)     { |v| opts[:limit]    = v }
  p.on('--min-score F', Float)   { |v| opts[:min_score]= v }
  p.on('--force-new')            { |_| opts[:force_new]= true }
  p.on('--auto-pick',
       'Auto-recommend without UX prompt when top score >= --auto-pick-threshold AND no other candidate within --auto-pick-tie-window of it. Sets `auto_picked: true` on the result so the caller can WARN about inherited columns.') { |_| opts[:auto_pick] = true }
  p.on('--auto-pick-threshold F', Float, 'Min score for auto-pick (default 0.55).')                  { |v| opts[:auto_pick_threshold] = v }
  p.on('--auto-pick-tie-window F', Float, 'Gap from top score within which other candidates count as a tie that disables auto-pick (default 0.05).') { |v| opts[:auto_pick_tie_window] = v }
  p.on('--specs-cache P',
       'JSON cache {"dms":[…list entries…],"specs":{dmId:spec}} prefetched by an orchestrator ' \
       '(e.g. migrate-qlik.rb prefetches it CONCURRENTLY with source discovery). When supplied, ' \
       'the DM list + spec fetches are served from the cache (missing specs still fetched live).') { |v| opts[:specs_cache] = v }
end.parse!
%i[sig out].each { |k| abort "missing --#{k}" unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL')
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'

# DM-shortlisting scans many candidates and is called per-follower in cluster
# orchestration — auto-refresh on 401 to survive long batch runs.
def http_get(path)
  attempts = 0
  loop do
    attempts += 1
    uri = URI("#{BASE}#{path}")
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{Sigma.auth_token}"
    req['Accept'] = 'application/json'
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    if res.code.to_i == 401 && attempts == 1 && ENV['SIGMA_CLIENT_ID']
      Sigma.refresh_token!
      next
    end
    return res
  end
end

sig = JSON.parse(File.read(opts[:sig]))
warn "workbook: #{sig['tableau_workbook'] || '(unnamed)'}"
warn "  warehouse_tables:   #{sig['warehouse_tables']&.size || 0}"
warn "  referenced_columns: #{sig['referenced_columns']&.size || 0}"

# Force-new short-circuit: emit a no-match result and exit 1.
if opts[:force_new]
  File.write(opts[:out], JSON.pretty_generate({
    'recommended_dm_id' => nil,
    'score' => 0.0,
    'rationale' => '--force-new: bypassed DM-reuse scan',
    'candidates' => []
  }))
  warn "force-new mode — wrote empty match"
  exit 1
end

# 1. List ALL data models, then sort deterministically before applying --limit.
# Sigma's /v2/dataModels list endpoint returns server page-order, not
# relevance order. Without a stable client-side sort, the same workbook
# picks different candidates on different runs (observed: 3 conversions of
# the same Tableau workbook reached 3 different recommendations). Fix:
# fetch all DMs (cheap — one list call per 100), sort by updatedAt desc
# (recent DMs are usually more relevant), then take the first --limit for
# parallel spec-fetch + scoring. Stable tiebreaker by name. beads-sigma-3kw.
cache = nil
if opts[:specs_cache] && File.exist?(opts[:specs_cache])
  cache = (JSON.parse(File.read(opts[:specs_cache])) rescue nil)
  warn "specs-cache: #{opts[:specs_cache]} (#{(cache['dms'] || []).size} DMs, #{(cache['specs'] || {}).size} specs)" if cache
end

all_dms = []
if cache
  all_dms = cache['dms'] || []
else
  page = nil
  hard_cap = 500
  loop do
    qs = "limit=100"
    qs += "&page=#{page}" if page
    r = http_get("/v2/dataModels?#{qs}")
    break unless r.code.to_i == 200
    data = JSON.parse(r.body)
    rows = data['entries'] || data['dataModels'] || []
    break if rows.empty?
    all_dms.concat(rows)
    break if all_dms.size >= hard_cap
    page = data['nextPage']
    break if page.nil? || page.empty?
  end
end

# Deterministic ranking: updatedAt desc, then name asc.
# NOTE: require 'time' MUST come before the sort — without it Time.parse raises,
# every timestamp rescues to 0, and the sort silently degrades to name-ascending
# (recently-updated DMs past the --limit window are never scanned).
require 'time'
all_dms = all_dms.sort_by do |dm|
  [-(Time.parse(dm['updatedAt'].to_s).to_i rescue 0), dm['name'].to_s]
end

warn "found #{all_dms.size} total DMs; scoring top #{[all_dms.size, opts[:limit]].min} by updatedAt"

# 2. Fetch each DM's spec and extract its signature (tables + columns + metrics).
def normalize_fqn(s)
  return nil if s.nil? || s.empty?
  parts = s.to_s.split('.').reject(&:empty?).map(&:upcase)
  parts.join('.')
end

def normalize_col(s)
  s.to_s.upcase.gsub(/[^A-Z0-9]/, '')
end

# Fetch all DM specs in parallel (10 threads). Some DMs return non-200
# (archived, permission-restricted, broken refs) — log and continue. Single
# transient 5xx errors are retried once.
dm_specs = {}
dm_failures = []
require 'thread'
mu = Mutex.new
queue = Queue.new
# Serve specs from the orchestrator's prefetch cache when present; only DMs
# missing from the cache go to the network. Cached entries may be raw strings
# (the spec endpoint can answer YAML) — parse JSON-else-YAML, same as below.
if cache
  (cache['specs'] || {}).each do |dm_id, spec|
    if spec.is_a?(String)
      spec = begin
        JSON.parse(spec)
      rescue JSON::ParserError
        (YAML.safe_load(spec, permitted_classes: [Date, Time]) rescue nil)
      end
    end
    dm_specs[dm_id] = spec if spec
  end
end
all_dms.take(opts[:limit]).reject { |dm| dm_specs.key?(dm['dataModelId'] || dm['id']) }
       .each { |dm| queue << dm }
threads = 5.times.map do
  Thread.new do
    until queue.empty?
      dm = queue.pop(true) rescue nil
      break unless dm
      dm_id = dm['dataModelId'] || dm['id']
      next unless dm_id
      r = nil
      # Retry on 429 (Cloudflare burst limit) with exponential backoff. The
      # /v2/dataModels endpoint commonly 429s at >5 concurrent across
      # tj-wells-1989 — see beads-sigma-cn5.
      4.times do |attempt|
        r = http_get("/v2/dataModels/#{dm_id}/spec")
        code = r.code.to_i
        break if code == 200 || (code != 429 && code < 500)
        sleep (0.5 * (2 ** attempt))  # 0.5s, 1s, 2s, 4s
      end
      if r.code.to_i != 200
        mu.synchronize { dm_failures << { name: dm['name'], id: dm_id, code: r.code, body_head: r.body[0..80] } }
        next
      end
      spec = begin
        JSON.parse(r.body)
      rescue JSON::ParserError
        YAML.safe_load(r.body, permitted_classes: [Date, Time])
      end
      mu.synchronize { dm_specs[dm_id] = spec }
    end
  end
end
threads.each(&:join)
warn "fetched #{dm_specs.size} DM specs (#{dm_failures.size} failed)"
dm_failures.first(5).each { |f| warn "  failure: #{f[:code]} #{f[:name]} — #{f[:body_head]}" }

dm_signatures = []
all_dms.take(opts[:limit]).each do |dm|
  dm_id = dm['dataModelId'] || dm['id']
  spec = dm_specs[dm_id]
  next unless spec

  tables = []
  columns = []
  metrics = []
  column_captions = {}  # normalized → original, so output can be human-readable

  # Walk every element. Sigma DM specs nest elements under pages[*].elements
  # (NOT top-level `elements` — that's a workbook-only convention). Fall back
  # to top-level for robustness in case schema changes.
  all_elements = spec['elements'] || (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
  all_elements.each do |el|
    src = el['source'] || {}
    case src['kind']
    when 'warehouse-table', 'table'
      # source like { kind: warehouse-table, connectionId, path: "DB.SCHEMA.TABLE" }.
      # Live API specs return path as an ARRAY (["DB","SCHEMA","TABLE"]) — join it,
      # else normalize_fqn sees the array's to_s and table-match never fires.
      raw = src['path']
      fqn = raw.is_a?(Array) ? raw.join('.') : (raw || [src['database'], src['schema'], src['name']].compact.join('.'))
      tables << normalize_fqn(fqn) if fqn && !fqn.empty?
    when 'sql'
      # Custom SQL — surface a sentinel so the agent knows; not directly comparable
      tables << 'CUSTOM_SQL'
    end
    (el['columns'] || []).each do |c|
      colname = c['name'] || (c['formula'].to_s.match(/\[.*?([^\/\]]+)\]/) || [])[1]
      if colname && !colname.empty?
        norm = normalize_col(colname)
        columns << norm
        column_captions[norm] ||= colname
      end
    end
    (el['metrics'] || []).each do |m|
      metrics << "#{m['name']}/#{m['aggregation'] || m['derivation']}"
    end
  end

  dm_signatures << {
    dm_id: dm_id,
    dm_name: dm['name'],
    tables: tables.uniq.compact,
    columns: columns.uniq.compact,
    column_captions: column_captions,
    metrics: metrics.uniq.compact,
    raw_element_count: all_elements.size
  }
end

# 3. Score each DM.
tableau_tables  = (sig['warehouse_tables']   || []).map { |t| normalize_fqn(t) }.compact
# Keep both forms: normalized for matching, original for human-readable output.
tableau_columns_orig = (sig['referenced_columns'] || [])
tableau_columns      = tableau_columns_orig.map { |c| normalize_col(c) }
tableau_col_caption  = tableau_columns.zip(tableau_columns_orig).to_h
tableau_measure_keys = (sig['measures'] || []).map { |m| "#{normalize_col(m['col'])}/#{m['derivation']}" }

candidates = dm_signatures.map do |dm|
  # Table match: 1.0 if Tableau tables ⊆ DM tables. 0.5 if partial. 0 if disjoint.
  shared_tables = (tableau_tables & dm[:tables])
  table_match =
    if tableau_tables.empty?
      0.0
    elsif shared_tables.size == tableau_tables.size
      1.0
    elsif shared_tables.any?
      0.5 + 0.5 * (shared_tables.size.to_f / tableau_tables.size)
    else
      0.0
    end

  # Column match: % of Tableau-referenced columns present in DM.
  shared_cols = (tableau_columns & dm[:columns])
  col_match =
    tableau_columns.empty? ? 0.0 : shared_cols.size.to_f / tableau_columns.size

  # Metric overlap (small weight).
  shared_metrics = (tableau_measure_keys & dm[:metrics])
  metric_match =
    tableau_measure_keys.empty? ? 0.0 : shared_metrics.size.to_f / tableau_measure_keys.size

  # Weighting rationale: column overlap is the most reliable signal —
  # a DM's source table FQN can vary (raw warehouse table vs view vs joined
  # element) but the column set must be a superset of what the workbook
  # references for reuse to be safe. Table-match is a soft tiebreaker.
  score = 0.2 * table_match + 0.7 * col_match + 0.1 * metric_match

  # Extras the workbook would inherit. Surface original captions (not the
  # normalized form) so the user-facing report is readable.
  extra_cols_norm = dm[:columns] - tableau_columns
  caption_of = ->(norm) { dm[:column_captions][norm] || norm }
  {
    'dm_id'             => dm[:dm_id],
    'dm_name'           => dm[:dm_name],
    'score'             => score.round(3),
    'table_match'       => table_match.round(2),
    'column_match'      => col_match.round(2),
    'metric_match'      => metric_match.round(2),
    'shared_tables'     => shared_tables,
    'missing_tables'    => tableau_tables - dm[:tables],
    'shared_columns'    => shared_cols.map(&caption_of),
    'missing_columns'   => (tableau_columns - dm[:columns]).map { |c| tableau_col_caption[c] || c },
    'extra_columns'     => extra_cols_norm.size,
    'extra_columns_sample' => extra_cols_norm.first(5).map(&caption_of),
    'raw_element_count' => dm[:raw_element_count]
  }
end

# Tie-break: identical scores are common (duplicate / derived DMs sourcing the
# same tables and column set). Prefer a DM whose name matches the source
# workbook, then the one with the fewest extra columns — otherwise ordering is
# arbitrary and the recommendation can land on a sprawling lookalike instead
# of the purpose-built twin.
sig_name_norm = normalize_col(sig['tableau_workbook'] || sig['workbook'] || '')
candidates = candidates.sort_by do |c|
  name_mismatch = (!sig_name_norm.empty? && normalize_col(c['dm_name']) == sig_name_norm) ? 0 : 1
  [-c['score'], name_mismatch, c['extra_columns'] || 0]
end

best = candidates.first
second = candidates[1]

# Auto-pick gate (reuse-first). Fires when --auto-pick is set and the top
# candidate (a) clears the auto-pick threshold AND (b) COVERS ALL of the
# workbook's source tables (table_match 1.0). Table coverage is the safety
# invariant: a DM that sources every table the workbook needs can satisfy every
# column ref through its element set, so reusing it is safe; a DM missing a table
# is never auto-picked (its denorm view can't resolve the missing columns).
#
# We deliberately DO NOT block on a score tie here. A tie among table-covering
# candidates is duplicate-DM SPRAWL (the same star modeled two or three times) —
# exactly what reuse-first exists to collapse — so we take the top (the
# deterministic tie-break already prefers a name match, then the fewest extra
# columns, over the most-recently-updated set). A column-SUPERSET (every
# referenced column present, column_match 1.0) is the safest case and always
# qualifies. Callers should reuse `recommended_dm_id` only when `auto_picked`.
auto_pick_threshold  = opts[:auto_pick_threshold]  || 0.55
auto_pick_tie_window = opts[:auto_pick_tie_window] || 0.05
tie_with_second      = best && second && (best['score'] - second['score']) < auto_pick_tie_window
best_name_matches    = best && !sig_name_norm.empty? && normalize_col(best['dm_name']) == sig_name_norm
best_covers_tables   = best && best['table_match'].to_f >= 1.0
best_is_superset     = best_covers_tables && best['column_match'].to_f >= 1.0
auto_picked          = !!(opts[:auto_pick] && best && best['score'] >= auto_pick_threshold && best_covers_tables)

# Standard recommend path keeps the old semantics (printed for human opt-in).
recommended_via_std  = best && best['score'] >= opts[:min_score]
recommended_dm_id    = (auto_picked || recommended_via_std) ? best['dm_id'] : nil

rationale =
  if best.nil?
    'no DMs in org'
  elsif auto_picked
    kind = best_is_superset ? 'column-superset' : 'covers all source tables'
    tie  = tie_with_second ? " (collapsing a #{best['score']}-score tie — duplicate-DM sprawl)" : ''
    "AUTO-PICKED at score #{best['score']} — #{kind}#{tie}. #{best['shared_columns'].size}/#{tableau_columns.size} cols, #{best['shared_tables'].size}/#{tableau_tables.size} tables matched. Caller must WARN about #{best['extra_columns']} inherited columns."
  elsif opts[:auto_pick] && best['score'] >= auto_pick_threshold && !best_covers_tables
    "score #{best['score']} clears the bar but the candidate is MISSING source table(s) #{best['missing_tables'].join(', ')} — not a safe reuse — build a new DM"
  elsif best['score'] >= opts[:min_score]
    'ambiguous match — ASK USER before reusing'
  else
    'no candidate above min-score; build a new DM'
  end

result = {
  'workbook_signature_path' => opts[:sig],
  'scanned_dm_count'        => candidates.size,
  'recommended_dm_id'       => recommended_dm_id,
  'auto_picked'             => auto_picked,
  'score'                   => best ? best['score'] : 0.0,
  'rationale'               => rationale,
  'warning'                 => (best && best['extra_columns'] > 0) ? "Reusing inherits #{best['extra_columns']} extra columns (sample: #{best['extra_columns_sample'].join(', ')})" : nil,
  'candidates'              => candidates.first(5)
}.compact

File.write(opts[:out], JSON.pretty_generate(result))
warn ""
warn "wrote #{opts[:out]}"
warn "best score: #{result['score']}  →  #{result['rationale']}"
exit result['recommended_dm_id'].nil? ? 1 : 0
