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
#     "warehouse_tables":   ["ANALYTICS.ORDER_FACT"],          # FQN list
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
require 'digest'
require 'time'
require 'set'

# --limit is the SPEC-FETCH BUDGET, not a cap on how many DMs are considered.
#
# Perf testing (2026-05-22) set limit=25 because the top score "saturated by ~25
# DMs in this org" and wall time elbows hard after 50 (0.065s/DM → 0.25s/DM —
# Sigma drops off a cached-spec hot path). That held only while the budget was
# spent on the RIGHT 25: the window used to be the 25 most-recently-UPDATED DMs,
# and recency is uncorrelated with whether a DM covers the workbook's tables. On
# an org that has since grown to 500 DMs that meant scoring 5% of them chosen by
# when they were last touched — a DM covering exactly the target table was never
# scored, the picker reported "no reusable DM found", and every migration posted
# yet another near-duplicate model. Reuse-first was effectively inert.
#
# Fix: rank the fetch queue by RELEVANCE (name affinity to the signature's own
# table names) and only use updatedAt as a tiebreak, so the same budget buys the
# plausible reuse targets. Any DM with non-zero affinity is fetched even past
# --limit, up to --max-fetch. Truncation is always reported, never silent.
RANKING_VERSION = 2 # bump to invalidate dm-match caches written by older ranking
opts = { limit: 25, min_score: 0.6, max_fetch: 120 }
OptionParser.new do |p|
  p.on('--workbook-signature P') { |v| opts[:sig]      = v }
  p.on('--out P')                { |v| opts[:out]      = v }
  p.on('--limit N', Integer)     { |v| opts[:limit]    = v }
  p.on('--max-fetch N', Integer, 'Hard ceiling on spec fetches when relevance-ranked candidates exceed --limit (default 120). Name-affine DMs are fetched past --limit up to this cap.') { |v| opts[:max_fetch] = v }
  p.on('--min-score F', Float)   { |v| opts[:min_score]= v }
  p.on('--force-new')            { |_| opts[:force_new]= true }
  p.on('--auto-pick',
       'Auto-recommend without UX prompt when top score >= --auto-pick-threshold AND no other candidate within --auto-pick-tie-window of it. Sets `auto_picked: true` on the result so the caller can WARN about inherited columns.') { |_| opts[:auto_pick] = true }
  p.on('--auto-pick-threshold F', Float, 'Min score for auto-pick (default 0.55).')                  { |v| opts[:auto_pick_threshold] = v }
  p.on('--auto-pick-tie-window F', Float, 'Gap from top score within which other candidates count as a tie that disables auto-pick (default 0.05).') { |v| opts[:auto_pick_tie_window] = v }
  p.on('--refresh', 'Force a rescan even when --out already answers this exact signature (see the re-entry cache below).') { |_| opts[:refresh] = true }
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
    # Derive TLS from the URI scheme (same as put-layout.rb) instead of hardcoding
    # use_ssl: true. Production SIGMA_BASE_URL is https so behaviour is unchanged;
    # this is what lets the candidate-ranking tests drive the picker against a
    # loopback WEBrick stub offline (hardcoded TLS made the scan untestable, which
    # is how the recency-window bug shipped with a green suite).
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
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

# ── Re-entry cache (refs/performance.md) ─────────────────────────────────────
# The orchestrator re-invokes this scan on EVERY loop re-entry (exit 10/11/13),
# and on a large org that re-pays a full DM list + N parallel spec fetches each
# time for an answer that cannot have changed: the recommendation is a pure
# function of the workbook SIGNATURE and the org's DM set. So the --out file is
# stamped with a canonical hash of the signature it was computed from —
# same signature ⇒ reuse the recommendation without touching the API.
# The org's DM set IS live external state, so reuse carries a 24h staleness
# bound; --refresh forces a rescan (e.g. after posting/deleting DMs mid-run).
def signature_sha(sig)
  canon = {
    'tables'   => (sig['warehouse_tables'] || []).map(&:to_s).sort,
    'columns'  => (sig['referenced_columns'] || []).map(&:to_s).sort,
    'measures' => (sig['measures'] || []).map { |m| "#{m['col']}/#{m['derivation']}" }.sort
  }
  Digest::SHA256.hexdigest(JSON.generate(canon))
end
SIG_SHA = signature_sha(sig)
CACHE_MAX_AGE = 24 * 3600
if !opts[:refresh] && !opts[:force_new] && File.exist?(opts[:out])
  prev = (JSON.parse(File.read(opts[:out])) rescue nil)
  prev_at = prev && (Time.parse(prev['scanned_at'].to_s) rescue nil)
  # ranking_version participates in cache validity: a result computed by the old
  # recency-window ranking must NOT be replayed, or the reuse fix stays invisible
  # for 24h on exactly the orgs that need it.
  prev_rv = prev.is_a?(Hash) ? prev['ranking_version'].to_i : 0
  if prev.is_a?(Hash) && prev['signature_sha256'] == SIG_SHA && prev_at && (Time.now - prev_at) < CACHE_MAX_AGE &&
     prev_rv == RANKING_VERSION
    warn "dm-match REUSED (signature unchanged; scanned #{prev['scanned_at']}) — pass --refresh to rescan"
    warn "best score: #{prev['score']}  →  #{prev['rationale']}"
    exit(prev['recommended_dm_id'].nil? ? 1 : 0)
  end
end

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
all_dms = []
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

# Deterministic ranking: name-affinity desc, then updatedAt desc, then name asc.
# NOTE: require 'time' MUST come before the sort — without it Time.parse raises,
# every timestamp rescues to 0, and the sort silently degrades to name-ascending
# (recently-updated DMs past the --limit window are never scanned).
require 'time'

# Cheap RELEVANCE signal computable from the list response alone (no spec fetch):
# how much a DM's NAME overlaps the distinctive tokens of the tables this
# workbook actually reads. Given a signature over <DB>.<SCHEMA>.PIPELINE_FACT, a DM
# named "Pipeline Fact (migrated)" scores; an unrelated "Bench Fixture 12" scores 0.
# This only ORDERS the fetch queue — the real scoring below is still done on the
# fetched spec's tables/columns, so a name coincidence can never by itself produce
# a reuse recommendation.
STOP_TOKENS = %w[DM DATA MODEL FROM THE AND FOR TEST TMP TEMP COPY OF V1 V2 NEW OLD
                 FACT DIM TABLE VIEW PROD DEV RAW STG PUBLIC].to_set
def name_tokens(s)
  s.to_s.upcase.split(/[^A-Z0-9]+/).reject { |t| t.empty? || t.length < 3 || STOP_TOKENS.include?(t) }.to_set
end

# Signature tokens: the LEAF table name carries the signal (db/schema are shared
# by everything on the connection and would match every DM equally).
sig_tokens = (sig['warehouse_tables'] || []).each_with_object(Set.new) do |fqn, acc|
  leaf = fqn.to_s.split('.').reject(&:empty?).last
  acc.merge(name_tokens(leaf))
end
# The source document's own name is a weaker but real signal (a prior migration of
# the same dashboard usually named its DM after it).
sig_tokens.merge(name_tokens(sig['tableau_workbook'])) if sig['tableau_workbook']

def affinity(dm_name, sig_tokens)
  return 0.0 if sig_tokens.empty?
  toks = name_tokens(dm_name)
  return 0.0 if toks.empty?
  (toks & sig_tokens).size.to_f / sig_tokens.size
end

all_dms = all_dms.sort_by do |dm|
  [-affinity(dm['name'], sig_tokens),
   -(Time.parse(dm['updatedAt'].to_s).to_i rescue 0),
   dm['name'].to_s]
end

# Spend the budget on relevance, but never let a plausible reuse target fall off
# the end just because the budget is small: every name-affine DM is fetched, up
# to --max-fetch.
affine_count = all_dms.count { |dm| affinity(dm['name'], sig_tokens) > 0 }
fetch_n = [[opts[:limit], affine_count].max, opts[:max_fetch], all_dms.size].min
POOL_TOTAL = all_dms.size
POOL_FETCHED = fetch_n
POOL_TRUNCATED = fetch_n < POOL_TOTAL
warn "found #{POOL_TOTAL} total DMs; scoring #{POOL_FETCHED} ranked by name-affinity to the signature's tables " \
     "(#{affine_count} name-affine, budget --limit=#{opts[:limit]}, cap --max-fetch=#{opts[:max_fetch]})"
if POOL_TRUNCATED
  warn "  NOTE: #{POOL_TOTAL - POOL_FETCHED} DM(s) were NOT scored — a 'no reusable DM' result below means " \
       "none was found AMONG THE #{POOL_FETCHED} SCORED, not that none exists. Raise --limit/--max-fetch to widen."
end

# 2. Fetch each DM's spec and extract its signature (tables + columns + metrics).
def normalize_fqn(s)
  return nil if s.nil? || s.empty?
  parts = s.to_s.split('.').reject(&:empty?).map(&:upcase)
  parts.join('.')
end

def normalize_col(s)
  s.to_s.upcase.gsub(/[^A-Z0-9]/, '')
end

# Does DM fqn `dm` cover workbook fqn `wb`, allowing for a source signature that
# could not resolve every qualifier? True when the two are equal, or when the
# SHORTER one's parts are a suffix of the longer's — warehouse names qualify
# right-to-left (table, schema, database), so a signature over SCHEMA.TABLE is
# satisfied by a DM on DB.SCHEMA.TABLE, while SCHEMA_A.T vs SCHEMA_B.T stay
# distinct. A single bare part (just a table name) is deliberately allowed to
# match too: it is a weaker signal, but the column match (weighted 0.7 vs the
# table's 0.2) is what actually discriminates, and refusing it would recreate the
# false-negative this exists to fix. CUSTOM_SQL is a sentinel, never a real path.
def fqn_covers?(dm, wb)
  return false if dm.nil? || wb.nil?
  return dm == wb if dm == 'CUSTOM_SQL' || wb == 'CUSTOM_SQL'
  d = dm.to_s.split('.')
  w = wb.to_s.split('.')
  return false if d.empty? || w.empty?
  n = [d.size, w.size].min
  d.last(n) == w.last(n)
end

# Fetch all DM specs in parallel (10 threads). Some DMs return non-200
# (archived, permission-restricted, broken refs) — log and continue. Single
# transient 5xx errors are retried once.
dm_specs = {}
dm_failures = []
require 'thread'
mu = Mutex.new
queue = Queue.new
all_dms.take(POOL_FETCHED).each { |dm| queue << dm }
threads = 5.times.map do
  Thread.new do
    until queue.empty?
      dm = queue.pop(true) rescue nil
      break unless dm
      dm_id = dm['dataModelId'] || dm['id']
      next unless dm_id
      r = nil
      # Retry on 429 (Cloudflare burst limit) with exponential backoff. The
      # /v2/dataModels endpoint commonly 429s at >5 concurrent on a live
      # org — see beads-sigma-cn5.
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
# POOL_FETCHED, not opts[:limit] — the fetch queue above is sized by POOL_FETCHED
# (which can exceed --limit when name-affine candidates do). Scoring only
# opts[:limit] here would fetch specs and then silently drop them unscored.
all_dms.take(POOL_FETCHED).each do |dm|
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
  # Table match: 1.0 if the workbook's tables ⊆ DM tables. 0.5 if partial. 0 if disjoint.
  #
  # Matched by ARITY-AWARE SUFFIX, not string equality. A source signature often
  # cannot resolve the DATABASE: QuickSight's dataset JSON carries only Schema +
  # Name (the database lives in the separate DataSource object), so its signature
  # emits "SCHEMA.TABLE" while every Sigma DM spec stores the full
  # ["DB","SCHEMA","TABLE"] path. Comparing the joined strings then fails on an
  # arity mismatch alone — measured live: three data models built FROM
  # <db>.<schema>.<table> scored table_match 0.0 against a signature over
  # <schema>.<table>, with column_match 1.0 and zero missing columns.
  #
  # That is not cosmetic. table_match 0.0 => covers_tables false => is_superset
  # false => the wide-tie guard fires and reuse is REFUSED forever, and the score
  # is capped around 0.7 so it can never clear the auto-pick bar. It is the reason
  # QuickSight reuse never fired even once the relevance ranking put the right
  # candidates in front of the scorer, and therefore the reason every migration
  # posted another duplicate model.
  #
  # A shorter FQN matches a longer one when its parts are a SUFFIX of the longer's
  # (table, then schema, then db — the qualification order), so SCHEMA.TABLE
  # matches DB.SCHEMA.TABLE while SCHEMA_A.T and SCHEMA_B.T stay distinct.
  shared_tables = tableau_tables.select { |wt| dm[:tables].any? { |dt| fqn_covers?(dt, wt) } }
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
    # Same arity-aware rule as shared_tables above — a plain set difference would
    # report a table as MISSING that the suffix match just resolved, and that
    # string is what the "MISSING source table(s)" rationale prints to the operator.
    'missing_tables'    => tableau_tables - shared_tables,
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
# candidate (a) clears the auto-pick threshold AND (b) is a COLUMN-SUPERSET of
# the workbook's references — table_match 1.0 AND column_match 1.0 (every
# referenced column present in the DM).
#
# Column coverage, not just table coverage, is the safety invariant. The old gate
# required only table_match 1.0 on the theory that "every table present ⇒ every
# column resolvable through the element set" — but that is FALSE when a DM merely
# scores well on table names: a DM can source all the workbook's tables yet still
# be missing referenced columns (col_match < 1.0, e.g. 0.8) and auto-pick anyway
# (0.2·1.0 + 0.7·0.8 ≈ 0.76 ≥ threshold), then fail the pre-POST ref gate. Require
# the full column-superset so a DM missing ANY referenced column is NOT silently
# reused — it can still be RECOMMENDED for human opt-in below.
#
# KNOWN RESIDUAL (role-playing dimensions): column-NAME coverage cannot express
# "the master needs table T joined under TWO aliases" (e.g. DATE_DIM as both Order
# Date and Return Date). A DM with T once can be a full column-superset yet lack
# the second alias; the pre-POST ref gate still catches it (exit-4 handoff). A
# self-heal (auto-rebuild fresh on ref-gate failure of an auto-picked DM) is the
# proper fix for that case — tracked separately.
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
# A WIDE tie among table-covering look-alikes (>=3 within the tie window) is
# duplicate-DM sprawl we CANNOT safely disambiguate by score — silently collapsing
# it can reuse a bloated look-alike that lacks the workbook's joined structure
# (verified 2026-07-02: a 5-way 0.876 tie of demo DMs auto-collapsed, dropping 8/9
# visuals + falling back to the agent path). Unless the top is a confident pick
# (exact source-name match OR a full column-superset), refuse to auto-pick so the
# caller builds a fresh, correctly-structured DM (and, interactively, surfaces the
# tie). Narrow ties (<=2) still collapse as before — reuse-first for the common case.
tie_window_count     = best ? candidates.count { |c| (best['score'] - c['score'].to_f) < auto_pick_tie_window } : 0
# The tie guard only means something when the tied scores are actually REUSE
# CANDIDATES. Without the min_score floor, a pile of IRRELEVANT DMs (all scoring
# ~0.0 because they share no tables or columns) trips it and gets reported as
# "N near-identical DMs tie — duplicate-DM sprawl", which is both wrong and
# actively misleading: nothing is duplicated, the picker simply found nothing.
# Now widened relevance ranking surfaces more zero-score DMs, so this matters.
ambiguous_wide_tie   = tie_window_count >= 3 && best && best['score'].to_f >= opts[:min_score] &&
                       !best_name_matches && !best_is_superset
auto_picked          = !!(opts[:auto_pick] && best && best['score'] >= auto_pick_threshold && best_is_superset && !ambiguous_wide_tie)

# Standard recommend path keeps the old semantics (printed for human opt-in).
recommended_via_std  = best && best['score'] >= opts[:min_score] && !ambiguous_wide_tie
recommended_dm_id    = (auto_picked || recommended_via_std) ? best['dm_id'] : nil

rationale =
  if best.nil?
    'no DMs in org'
  elsif auto_picked
    kind = best_is_superset ? 'column-superset' : 'covers all source tables'
    tie  = tie_with_second ? " (collapsing a #{best['score']}-score tie — duplicate-DM sprawl)" : ''
    "AUTO-PICKED at score #{best['score']} — #{kind}#{tie}. #{best['shared_columns'].size}/#{tableau_columns.size} cols, #{best['shared_tables'].size}/#{tableau_tables.size} tables matched. Caller must WARN about #{best['extra_columns']} inherited columns."
  elsif ambiguous_wide_tie
    "AMBIGUOUS: #{tie_window_count} near-identical DMs tie at ~#{best['score']} (duplicate-DM sprawl) and none is an exact source-name match or full column-superset — NOT auto-reusing a look-alike (it may lack the workbook's joined structure). Build a fresh DM, or force one with --reuse-dm <id>. Tied: #{candidates.first([tie_window_count, 4].min).map { |c| c['dm_name'] }.join('; ')}"
  elsif opts[:auto_pick] && best['score'] >= auto_pick_threshold && !best_covers_tables
    "score #{best['score']} clears the bar but the candidate is MISSING source table(s) #{best['missing_tables'].join(', ')} — not a safe reuse — build a new DM"
  elsif best['score'] >= opts[:min_score]
    'ambiguous match — ASK USER before reusing'
  else
    "no candidate above min-score across the #{POOL_FETCHED} DM(s) scored; build a new DM"
  end

# NO SILENT CAPS: whenever we decline to recommend reuse AND the budget stopped us
# short of the whole org, say so in the rationale itself — the agent/operator reads
# this string, and "build a new DM" must never imply "the org has nothing reusable"
# when only part of it was scored. (Appended to whichever branch fired above.)
if recommended_dm_id.nil? && POOL_TRUNCATED
  rationale += " [scanned #{POOL_FETCHED} of #{POOL_TOTAL} DM(s) scored, ranked by name-affinity — " \
               "#{POOL_TOTAL - POOL_FETCHED} NOT scored; raise --limit/--max-fetch to scan wider]"
end

result = {
  'workbook_signature_path' => opts[:sig],
  # Re-entry cache stamp (see the header block): same signature within 24h ⇒
  # the next invocation reuses this file instead of re-scanning the org.
  'signature_sha256'        => SIG_SHA,
  # Ranking generation this result was computed under; the cache refuses to replay
  # a result from an older ranking (see RANKING_VERSION).
  'ranking_version'         => RANKING_VERSION,
  'scanned_at'              => Time.now.utc.iso8601,
  'scanned_dm_count'        => candidates.size,
  # NO SILENT CAPS: a "no reusable DM" verdict is only as broad as the pool that
  # was actually scored. Callers (and the agent reading this file) must be able to
  # tell "none exists" apart from "none among the N we could afford to score".
  'candidate_pool'          => {
    'total_in_org' => POOL_TOTAL,
    'scored'       => POOL_FETCHED,
    'truncated'    => POOL_TRUNCATED,
    'ranked_by'    => 'name-affinity to signature tables, then updatedAt desc, then name asc'
  },
  'recommended_dm_id'       => recommended_dm_id,
  'auto_picked'             => auto_picked,
  'ambiguous_wide_tie'      => ambiguous_wide_tie,
  'tie_count'               => tie_window_count,
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
