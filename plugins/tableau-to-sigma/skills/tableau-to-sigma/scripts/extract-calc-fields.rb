#!/usr/bin/env ruby
# Phase 1c — Discover calculated fields for a Tableau workbook.
#
# Primary path:  Tableau Metadata API (GraphQL at /api/metadata/graphql).
#                Returns formula + dependency graph. Works regardless of VDS state.
# Fallback path: Parse the cached .twb XML. Returns formula only (no dep graph).
#
# Both paths emit the same JSON shape so downstream phases don't care which fired.
#
# Usage:
#   ruby extract-calc-fields.rb --workbook-luid <luid> \
#     [--out <wb-dir>/calc-fields.json] \
#     [--source auto|metadata|twb] \
#     [--twb <path>] \
#     [--dashboard "<name>"] [--used-by <layout-meta.json>] \
#     [--refresh] [--no-cache]
#
# WORKING-SET SCOPING (--dashboard / --used-by):
#   A big .twb can carry ~2000 calcs, but one dashboard uses only a few dozen.
#   When --dashboard "<name>" (repeatable) and/or --used-by <meta.json>
#   (repeatable) is given, the script resolves the FULL calc set first, then
#   keeps ONLY the calcs the target dashboard's worksheets actually reference —
#   transitively (a kept calc that depends on another calc pulls that one in
#   too). The used-field set comes from the parse-twb-layout `*-meta.json`
#   sidecar (per-worksheet column-instance / measure / filter / calc lists).
#     --dashboard resolves the meta sidecar next to --twb (workbook-content.twb
#       → workbook-content-meta.json or layout-meta.json) and reads the
#       worksheets whose dashboard is in scope; if the sidecar isn't already
#       dashboard-scoped, ALL worksheets in it are treated as the used set
#       (still narrows to that workbook's referenced calcs).
#     --used-by <meta.json> reads an explicit (already dashboard-scoped) meta
#       sidecar. Use this from migrate-tableau when a scoped meta already exists.
#   WITHOUT either flag, behavior is unchanged: every calc is emitted.
#   The filtered output adds a `used_by` index (dashboard names → kept calc
#   captions) plus `n_calcs_total` so downstream sees the reduction.
#
# TRANSLATION CACHE (~/.tableau-to-sigma/calc-cache.json):
#   Each calc carries a `formula_hash` (SHA1 of its formula text). Per-calc
#   derived translation signals (is_lod / requires_custom_sql / translation_notes)
#   are memoized in the customer HOME cache keyed by that hash, matching the
#   ~/.tableau-to-sigma/ convention used by learned-rules.rb. Re-runs over the
#   same formulas are instant (cache HITs are logged to stderr). --no-cache
#   bypasses read+write; --refresh still re-fetches the source but reuses cache.
#
# Exit codes:
#   0 — success (metadata-api OR twb-xml-fallback)
#   3 — both paths failed
#   4 — metadata-api responded but workbook luid not in returned data
#   2 — bad arguments
#
# The old (pre-2026-05-26) signature was
#   ruby extract-calc-fields.rb <ds-metadata.json> <out.json>
# That signature is gone. The new script fetches metadata itself by workbook LUID.

require 'json'
require 'time'
require 'optparse'
require 'fileutils'
require 'digest'
require 'set'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'tableau_rest'

# ---- argument parsing ---------------------------------------------------

opts = {
  source: 'auto',
  refresh: false,
  dashboards: [],
  used_by: [],
  cache: true
}
OptionParser.new do |p|
  p.on('--workbook-luid LUID')      { |v| opts[:workbook_luid] = v }
  p.on('--out PATH')                { |v| opts[:out] = v }
  p.on('--source {auto|metadata|twb}', %w[auto metadata twb]) { |v| opts[:source] = v }
  p.on('--twb PATH')                { |v| opts[:twb] = v }
  p.on('--dashboard NAME')          { |v| opts[:dashboards] << v }
  p.on('--used-by PATH')            { |v| opts[:used_by] << v }
  p.on('--refresh')                 { opts[:refresh] = true }
  p.on('--no-cache')                { opts[:cache] = false }
end.parse!

unless opts[:workbook_luid]
  warn 'usage: extract-calc-fields.rb --workbook-luid <luid> [--out PATH] ' \
       '[--source auto|metadata|twb] [--twb PATH] [--refresh]'
  exit 2
end

luid = opts[:workbook_luid]
out_path = opts[:out] || File.join('/tmp', "calc-fields-#{luid}.json")
twb_path = opts[:twb] || "/tmp/assessment-dataflow/twbs/#{luid}.twb"

FileUtils.mkdir_p(File.dirname(out_path))

# True when the caller asked for a per-dashboard working set.
def scoping?(opts)
  !opts[:dashboards].empty? || !opts[:used_by].empty?
end

# ---- cache reuse --------------------------------------------------------

# Cache freshness rule: "same Tableau auth session". We don't have a session
# timestamp, so use the cached file's mtime within the current process's
# clock vs the auth env (TABLEAU_AUTH_TOKEN). A token lasts ~2h. We treat a
# cached calc-fields.json as fresh if it exists and is < 1h old, unless
# --refresh is set.
def cache_fresh?(path)
  return false unless File.file?(path)
  age = Time.now - File.mtime(path)
  age < 3600
end

if !opts[:refresh] && cache_fresh?(out_path)
  warn "calc-fields.json fresh at #{out_path} (#{(Time.now - File.mtime(out_path)).to_i}s old); use --refresh to bypass"
  puts File.read(out_path)
  exit 0
end

# ---- per-calc translation cache (~/.tableau-to-sigma/calc-cache.json) ----
#
# Keyed by SHA1 of the formula text — formula identity, not field name — so the
# SAME formula seen in a re-run (or in another workbook for the same customer)
# reuses the already-computed translation signals instead of re-deriving them.
# Lives under the customer HOME exactly like learned-rules.yaml, so `git pull`
# of the skill never clobbers it. The cached payload is small (the derived
# signals, not the formula), so the file stays tiny even for 2000-calc books.
module CalcCache
  HOME_OVERRIDE = ENV['TABLEAU_TO_SIGMA_HOME']
  DEFAULT_HOME  = File.expand_path('~/.tableau-to-sigma')
  CACHE_VERSION = 2 # bump when gotchas()/requires_custom_sql? logic changes

  def self.home
    HOME_OVERRIDE || DEFAULT_HOME
  end

  def self.path
    File.join(home, 'calc-cache.json')
  end

  def self.key(formula)
    Digest::SHA1.hexdigest("v#{CACHE_VERSION}\n#{formula}")
  end

  # Load the on-disk cache once. Missing file is the normal first-run case.
  def self.load
    return {} unless File.file?(path)
    data = JSON.parse(File.read(path))
    (data['entries'].is_a?(Hash) ? data['entries'] : {})
  rescue StandardError => e
    warn "WARN  calc-cache.json at #{path} unreadable: #{e.message}; starting fresh"
    {}
  end

  def self.save(entries)
    FileUtils.mkdir_p(home)
    tmp = "#{path}.tmp#{Process.pid}"
    File.write(tmp, JSON.pretty_generate('version' => CACHE_VERSION,
                                         'updated_at' => Time.now.utc.iso8601,
                                         'entries' => entries))
    File.rename(tmp, path)
  rescue StandardError => e
    warn "WARN  could not persist calc-cache.json: #{e.message}"
  end
end

# ---- formula translation hints (carried over from the v1 script) --------

# Window/table-calc split (WINPROBE-validated, bead 427, 2026-06-12):
# AUTO functions translate to Sigma-NATIVE window math emitted as chart-element
# viz formulas on the yAxis by build-charts-from-signals.rb — single DM base
# element, ZERO Custom SQL (930/930 cells exact vs warehouse). MANUAL functions
# have no validated mapping and still require human translation (Custom SQL or
# re-authoring). See refs/window-functions.md for the full mapping table.
TABLEAU_WINDOW_FNS_AUTO = %w[
  WINDOW_SUM WINDOW_AVG WINDOW_MIN WINDOW_MAX WINDOW_COUNT WINDOW_STDEV
  RUNNING_SUM RUNNING_AVG RUNNING_COUNT RUNNING_MIN RUNNING_MAX
  RANK RANK_DENSE RANK_PERCENTILE
  INDEX TOTAL LOOKUP
].freeze
TABLEAU_WINDOW_FNS_MANUAL = %w[
  WINDOW_MEDIAN WINDOW_PERCENTILE WINDOW_CORR WINDOW_COVAR WINDOW_COVARP
  WINDOW_VAR WINDOW_VARP WINDOW_STDEVP
  RANK_MODIFIED RANK_UNIQUE
  FIRST LAST SIZE PREVIOUS_VALUE
].freeze
TABLEAU_WINDOW_FNS = (TABLEAU_WINDOW_FNS_AUTO + TABLEAU_WINDOW_FNS_MANUAL).freeze

def detect_window_fns(formula)
  TABLEAU_WINDOW_FNS.select { |fn| formula =~ /\b#{Regexp.escape(fn)}\s*\(/i }
end

def detect_manual_window_fns(formula)
  TABLEAU_WINDOW_FNS_MANUAL.select { |fn| formula =~ /\b#{Regexp.escape(fn)}\s*\(/i }
end

def lod?(formula)
  formula =~ /\{\s*(FIXED|INCLUDE|EXCLUDE)\b/i
end

def gotchas(formula)
  notes = []
  notes << 'IIF(c, t, e) → If(c, t, e) in Sigma' if formula =~ /\bIIF\s*\(/i
  notes << 'COUNTD → CountDistinct in Sigma' if formula =~ /\bCOUNTD\b/i
  # Split, non-backtracking checks. The old single regex `\bIF\b[\s\S]+(>=|...)`
  # catastrophically backtracked on real calcs (a 1 KB formula took >3 s; some
  # never finished), which — on top of REXML — was a primary cause of the
  # multi-minute calc-extraction stall. Detecting "has IF" AND "has comparison"
  # is the same hint signal at O(n).
  notes << 'Tableau IF/IFNULL falls through to ELSE on NULL; Sigma If returns Null — wrap nullable source with Coalesce' \
    if formula =~ /\bIF\b/i && formula =~ /(>=|<=|<|>|=)/

  manual_hits = detect_manual_window_fns(formula)
  auto_hits   = detect_window_fns(formula) - manual_hits
  if auto_hits.any?
    notes << "AUTO-TRANSLATED when plotted (WINPROBE-validated mapping, refs/window-functions.md): #{auto_hits.join(', ')} → " \
             'Sigma-NATIVE window math emitted as a CHART-element viz formula on the yAxis by build-charts-from-signals.rb. ' \
             'RUNNING_*→Cumulative*; WINDOW_AVG/SUM/MAX/MIN(x,-n,0)→Moving*(x,n); agg/WINDOW_SUM(agg)→PercentOfTotal(agg,"grand_total"); ' \
             'RANK/RANK_DENSE/RANK_PERCENTILE→Rank/RankDense/RankPercentile(agg,"desc"); INDEX()→RowNumber(); LOOKUP(x,±n)→Lag/Lead(x,n); ' \
             'RUNNING_SUM/TOTAL pareto→CumulativeSum(PercentOfTotal(agg,"grand_total")); unbounded WINDOW_MAX/MIN/SUM→hidden two-level ' \
             'grouped helper (consumer re-aggregates Max/Min, NEVER Sum). Single DM base element, NO Custom SQL. ' \
             'Placement: emitted on the chart yAxis (verified, the default), but the native family ALSO resolves in ' \
             'table calc columns (grouped + ungrouped) and DM-element calc columns — only the *Over family ' \
             '(SumOver/RankOver/...) is "Unknown function" (every context). Re-verify with scripts/probe-window-contexts.rb.'
  end
  if manual_hits.any?
    notes << "MANUAL. #{manual_hits.join(', ')} has no validated Sigma chart-formula mapping — port via a Custom SQL " \
             'data-model element (kind: "sql", ANSI OVER(...)) or re-author in Sigma. Also MANUAL: any compute-using/' \
             'addressing override beyond the default Table(Across) / a simple partition ("restart every", pane-relative, ' \
             'compute-along-non-axis-dim) — build-charts emits these as flags, never guesses.'
  end

  if formula.scan(/\{\s*FIXED/i).length >= 2
    notes << 'AUTO-DECOMPOSED (nested LOD): {FIXED…{FIXED…}} becomes a helper-element CHAIN — ' \
             'build-charts-from-signals.rb writes the per-level plan to the -lod-chains.json sidecar ' \
             '(innermost first); build one grouped element per level, each outer level sourcing the inner ' \
             'element WITH groupingId (or a Custom SQL GROUP BY) or outer Avg/Median/Count come out row-weighted.'
  elsif formula =~ /\{\s*FIXED\b/i
    notes << 'AUTO-TRANSLATED when plotted: {FIXED <dims>:<agg>} becomes a hidden two-level grouped helper element ' \
             '(visibleAsSource:false; inner grouping = the FIXED dims computing the LOD aggregate, outer grouping = ' \
             'the chart dims computing the 2nd-stage aggregate; the chart Max()es the outer calc). ' \
             '⚠ carried chart dims must be functionally dependent on the FIXED dims — verify in Sigma. ' \
             'NEVER translate as SumOver/CountOver in master or DM-element calc columns (silent error).'
  end
  if formula =~ /\{\s*INCLUDE\b/i
    notes << 'MANUAL. {INCLUDE <dim>:<agg>} needs the chart grouping context: add <dim> to the chart grouping and use ' \
             'the plain aggregate, OR a fine-grain subquery (Custom SQL element) joined back to the view grain.'
  end
  if formula =~ /\{\s*EXCLUDE\b/i
    notes << 'MANUAL. {EXCLUDE <dim>:<agg>} needs the chart grouping context: remove <dim> from the chart grouping and ' \
             'use the plain aggregate, OR <agg>(<expr>) OVER (PARTITION BY <view-dims-minus-excluded>) via Custom SQL.'
  end
  notes
end

# FIXED LODs and the AUTO window/table-calc family are auto-translated (hidden
# grouped helper / Sigma-native chart viz formulas — see gotchas above), so
# they no longer force the Custom-SQL decision path or the exit-4 workbook
# handoff. Only the MANUAL window residues (WINDOW_MEDIAN/PERCENTILE/CORR/...,
# PREVIOUS_VALUE, SIZE, FIRST/LAST) and INCLUDE/EXCLUDE LODs still do.
def requires_custom_sql?(formula)
  detect_manual_window_fns(formula).any? || !!(formula =~ /\{\s*(INCLUDE|EXCLUDE)\b/i)
end

# Derive the translation signals for one formula. Pure function of the formula
# text → safe to memoize by formula hash. Returns the subset of the calc record
# that depends ONLY on the formula (not on name/role/datasource metadata).
def compute_signals(formula)
  {
    is_lod: !!lod?(formula),
    requires_custom_sql: requires_custom_sql?(formula),
    translation_notes: gotchas(formula)
  }
end

# Memoizing wrapper. $calc_cache is the loaded hash; $calc_cache_stats tracks
# hits/misses for the run summary. Set $calc_cache to nil to bypass (--no-cache).
$calc_cache = nil
$calc_cache_stats = { hits: 0, misses: 0 }
def cached_signals(formula)
  return compute_signals(formula).merge(formula_hash: nil) if formula.to_s.empty?
  h = CalcCache.key(formula)
  if $calc_cache && (hit = $calc_cache[h])
    $calc_cache_stats[:hits] += 1
    return {
      is_lod: hit['is_lod'],
      requires_custom_sql: hit['requires_custom_sql'],
      translation_notes: hit['translation_notes'] || [],
      formula_hash: h
    }
  end
  $calc_cache_stats[:misses] += 1
  sig = compute_signals(formula)
  if $calc_cache
    $calc_cache[h] = {
      'is_lod' => sig[:is_lod],
      'requires_custom_sql' => sig[:requires_custom_sql],
      'translation_notes' => sig[:translation_notes]
    }
  end
  sig.merge(formula_hash: h)
end

# ---- Metadata API path --------------------------------------------------

GRAPHQL_QUERY = <<~GRAPHQL
  query($luid: String!) {
    workbooks(filter: {luid: $luid}) {
      name luid
      embeddedDatasources {
        name
        fields {
          __typename name
          ... on CalculatedField {
            formula isHidden role dataType aggregation
            fields { name __typename }
            upstreamFields { name }
          }
        }
      }
    }
  }
GRAPHQL

def fetch_via_metadata_api(luid)
  body = JSON.generate(query: GRAPHQL_QUERY, variables: { luid: luid })
  begin
    resp = Tableau.request(
      :post,
      '/api/metadata/graphql',
      body: body,
      content_type: 'application/json',
      accept: 'application/json'
    )
  rescue Tableau::Error => e
    # Tableau::Error includes "POST /path -> <code> <msg>\n<body>" — surface for the
    # caller to fall back rather than crash.
    return { ok: false, error: e.message }
  end

  if resp.is_a?(Hash) && resp['errors']
    return { ok: false, error: "GraphQL errors: #{resp['errors'].inspect}" }
  end

  wbs = resp.dig('data', 'workbooks') || []
  return { ok: false, error: 'no_workbook_in_response', wb_count: 0 } if wbs.empty?

  wb = wbs.first
  calcs = []
  (wb['embeddedDatasources'] || []).each do |ds|
    ds_name = ds['name']
    (ds['fields'] || []).each do |f|
      next unless f['__typename'] == 'CalculatedField'
      formula = f['formula'].to_s
      depends_on = (f['fields'] || []).map { |d| d['name'] }.compact.uniq
      sig = cached_signals(formula)
      calcs << {
        name: f['name'],
        internal_name: f['name'],
        datasource: ds_name,
        formula: formula,
        role: f['role'],
        data_type: f['dataType'],
        aggregation: f['aggregation'],
        is_hidden: f['isHidden'] == true,
        is_lod: sig[:is_lod],
        depends_on: depends_on,
        formula_hash: sig[:formula_hash],
        requires_custom_sql: sig[:requires_custom_sql],
        translation_notes: sig[:translation_notes]
      }
    end
  end

  { ok: true, workbook_name: wb['name'], calcs: calcs }
end

# ---- .twb XML fallback --------------------------------------------------

# Nokogiri-backed REXML drop-in — REXML is O(n^2) on large .twb files (a 5 MB
# workbook never finishes calc extraction inside an agent turn); twb_xml.rb
# does the same parse in ~35 ms. See lib/twb_xml.rb.
require 'twb_xml'

def fetch_via_twb_xml(twb_path)
  return { ok: false, error: "twb not found: #{twb_path}" } unless File.file?(twb_path)
  doc = TwbXml.parse(File.read(twb_path, encoding: 'UTF-8'))

  # Pass 1 — build the field graph: internal name (e.g. "[Calculation_123]")
  # => display caption, across EVERY <column> in EVERY datasource (source cols,
  # calcs, and Parameters). Formulas reference other fields by that bracketed
  # internal name, so this map is what lets us resolve dependencies straight
  # from the .twb — no Metadata API needed. Parameters are included because
  # calcs routinely reference them; omitting them would make param-driven calcs
  # look like leaves.
  name_to_caption = {}
  doc.elements.each('//datasource') do |ds|
    ds.elements.each('column') do |col|
      internal = col.attributes['name']
      next unless internal
      next if internal.include?('__tableau_internal_object_id__')
      name_to_caption[internal] ||= col.attributes['caption'] || internal
    end
  end
  all_internal_names = name_to_caption.keys

  # Find every OTHER field whose bracketed internal name appears verbatim in a
  # formula. Keyed by internal name (unambiguous): a data BLEND can reuse a
  # display caption across datasources, so a caption-keyed graph would collapse
  # distinct fields into self-loops/cycles — internal-name keying stays a clean
  # DAG, which dependency-ordered validation/repair needs. The closing "]" in
  # each token stops "[AGE]" matching inside "[AGE_BRACKET]".
  resolve_deps = lambda do |formula, self_internal|
    return [] if formula.nil? || formula.empty?
    all_internal_names.each_with_object([]) do |cand, acc|
      next if cand == self_internal
      acc << cand if formula.include?(cand)
    end.uniq
  end

  calcs = []
  # In a .twb, each <datasource> has a <column> children with optional
  # <calculation class='tableau' formula='...'/>. caption is the user-facing
  # name; name (e.g. "[Calculation_123]") is the internal id. role is
  # "dimension" / "measure"; datatype is "real" / "string" / etc.
  doc.elements.each('//datasource') do |ds|
    ds_name = ds.attributes['caption'] || ds.attributes['name']
    next if ds_name && ds_name.start_with?('Parameter')
    ds.elements.each('column') do |col|
      calc_el = col.elements['calculation']
      next unless calc_el
      next unless calc_el.attributes['class'] == 'tableau'
      formula = calc_el.attributes['formula'].to_s
      next if formula.empty?
      caption = col.attributes['caption']
      internal_name = col.attributes['name']
      data_type = col.attributes['datatype']
      role = col.attributes['role'] # dimension|measure
      role_norm = role == 'measure' ? 'MEASURE' : (role == 'dimension' ? 'DIMENSION' : role)
      hidden = col.attributes['hidden'] == 'true'
      default_agg = col.attributes['default-aggregation']
      sig = cached_signals(formula)
      dep_internal = resolve_deps.call(formula, internal_name)
      calcs << {
        name: caption || internal_name,
        # internal_name is the .twb id (e.g. "[Calculation_123]" or
        # "[Field (copy)_456]") that worksheet column-instances reference, used
        # by the --dashboard/--used-by working-set resolver to match calcs.
        internal_name: internal_name,
        datasource: ds_name,
        formula: formula,
        role: role_norm,
        data_type: data_type ? data_type.upcase : nil,
        aggregation: default_agg,
        is_hidden: hidden,
        is_lod: sig[:is_lod],
        # depends_on: human-readable display names (matches the Metadata-API
        # path). depends_on_internal: the DAG-safe graph keyed by internal name
        # — use THIS for dependency-ordered validation/repair. resolve_used_calcs
        # walks depends_on (normalizing captions to tokens) before falling back
        # to formula parsing, so populating it here strengthens working-set
        # scoping too.
        depends_on: dep_internal.map { |n| name_to_caption[n] }.uniq,
        depends_on_internal: dep_internal,
        formula_hash: sig[:formula_hash],
        requires_custom_sql: sig[:requires_custom_sql],
        translation_notes: sig[:translation_notes]
      }
    end
  end

  { ok: true, calcs: calcs }
end

# ---- working-set resolution (--dashboard / --used-by) -------------------

# Resolve the parse-twb-layout meta sidecar path for a given .twb. The parser
# writes "<base>-meta.json" next to its layout JSON; migrate-tableau names the
# layout "layout.json" (→ layout-meta.json) and the cold path may use
# "<twb-base>-meta.json". We probe the common spellings next to the .twb.
def resolve_meta_path(twb_path)
  return nil unless twb_path
  dir  = File.dirname(twb_path)
  base = File.basename(twb_path, '.twb')
  candidates = [
    File.join(dir, "#{base}-meta.json"),
    File.join(dir, 'layout-meta.json'),
    File.join(dir, 'layout-content-meta.json')
  ]
  candidates.find { |p| File.file?(p) }
end

# Normalize a field reference to a bare token usable for matching. Worksheet
# column-instances and formulas reference fields as "[Calculation_123]",
# "[Region]", "[federated.abc].[none:Region:nk]" etc. We strip brackets and any
# "[ds].[col]" qualifier, returning the inner-most segment. Both the calc index
# and the used-token set run through this so a worksheet ref and a calc id line
# up regardless of bracketing.
def norm_token(ref)
  s = ref.to_s.strip
  # Take the last bracketed segment of a qualified ref ([ds].[col] → col).
  if s =~ /\]\.\[([^\]]+)\]\s*$/
    s = Regexp.last_match(1)
  end
  s = s.sub(/\A\[/, '').sub(/\]\z/, '')
  # Tableau instance refs sometimes carry a "none:Name:nk" derivation prefix.
  if s =~ /\A(?:none|sum|avg|min|max|ctd|cnt|usr|qk|tmn|tdy|tyr|tqr|tmo|twk):(.+?):(?:nk|qk|ok|ck)\z/i
    s = Regexp.last_match(1)
  end
  s.strip
end

# Harvest every field token a scoped meta sidecar's worksheets reference. Returns
# a Hash: dashboard-or-meta label → Set-ish array of normalized tokens. We can't
# always know the dashboard name from the meta alone (the sidecar is keyed by
# worksheet), so when a label can't be derived we bucket under the meta file's
# basename. The token harvest is deliberately broad — every place a worksheet
# can name a field — because a missed reference silently drops a needed calc.
def used_tokens_from_meta(meta)
  tokens = []
  (meta['worksheets'] || {}).each_value do |w|
    # column-instance derivations (keyed by the column ref)
    (w['aggregations'] || {}).each_key { |k| tokens << norm_token(k) }
    (w['measures'] || []).each { |m| tokens << norm_token(m['column']) }
    (w['channels'] || {}).each_value do |c|
      tokens << norm_token(c['column']) if c['column']
      tokens << norm_token(c['field'])  if c['field']
    end
    if (s = w['sort'])
      tokens << norm_token(s['column']) if s['column']
      tokens << norm_token(s['using'])  if s['using']
    end
    %w[rows_shelf cols_shelf].each do |shelf|
      (w.dig(shelf, 'fields') || []).each { |f| tokens << norm_token(f['raw']) }
    end
    (w['filters'] || []).each do |f|
      tokens << norm_token(f['column_guid']) if f['column_guid']
      tokens << f['column_caption'] if f['column_caption']
    end
    (w['ref_marks'] || []).each do |r|
      tokens << norm_token(r['axis_column'])  if r['axis_column']
      tokens << norm_token(r['value_column']) if r['value_column']
      tokens << norm_token(r['field_x'])      if r['field_x']
      tokens << norm_token(r['field_y'])      if r['field_y']
    end
    # The worksheet's own calc list: match by BOTH internal id and caption.
    (w['calculations'] || []).each do |c|
      tokens << norm_token(c['name']) if c['name']
      tokens << c['caption'] if c['caption']
    end
  end
  tokens.compact.map(&:to_s).reject(&:empty?).uniq
end

# Pull the bracketed field references out of a formula so we can walk the
# dependency graph even on the .twb path (no resolved graph there). Captures
# "[Calculation_123]", "[Region]", "[Some Field (copy)_45]". Function names like
# IF/SUM aren't bracketed, so this only yields field refs.
def formula_refs(formula)
  formula.to_s.scan(/\[[^\[\]]+\]/).map { |t| norm_token(t) }.uniq
end

# Given the full calc list + a set of directly-used tokens, return the
# transitive closure of calcs needed: a calc is in-scope if its internal id or
# caption is used, and every calc THAT calc's formula references is pulled in
# too (walking depends_on when present, else parsed formula refs).
def resolve_used_calcs(calcs, used_tokens)
  used = used_tokens.map(&:to_s).to_set
  by_token = {}
  calcs.each do |c|
    # Index each calc under its normalized internal id, its normalized caption,
    # and its raw caption — a dependency ref may match any of these spellings.
    by_token[norm_token(c[:internal_name])] = c if c[:internal_name]
    if c[:name]
      by_token[norm_token(c[:name])] = c
      by_token[c[:name].to_s] = c
    end
  end
  # Seed: any calc whose id/caption is directly referenced by a worksheet.
  frontier = calcs.select do |c|
    used.include?(norm_token(c[:internal_name])) ||
      used.include?(c[:name].to_s) ||
      used.include?(norm_token(c[:name]))
  end
  kept = {}
  frontier.each { |c| kept[c.object_id] = c }
  queue = frontier.dup
  until queue.empty?
    c = queue.shift
    deps = (c[:depends_on] || []).map { |d| norm_token(d) }
    deps += formula_refs(c[:formula])
    deps.uniq.each do |d|
      dep = by_token[d]
      next unless dep
      next if kept.key?(dep.object_id)
      kept[dep.object_id] = dep
      queue << dep
    end
  end
  kept.values
end

# ---- orchestration ------------------------------------------------------

# Prime the per-formula translation cache (unless --no-cache). cached_signals
# reads/writes $calc_cache during both fetch paths below.
$calc_cache = opts[:cache] ? CalcCache.load : nil
warn "calc-cache: #{$calc_cache.size} entries loaded from #{CalcCache.path}" if $calc_cache

source_chosen = nil
final_calcs = nil
wb_name = nil
metadata_err = nil

case opts[:source]
when 'metadata'
  r = fetch_via_metadata_api(luid)
  if r[:ok]
    source_chosen = 'metadata-api'
    final_calcs = r[:calcs]
    wb_name = r[:workbook_name]
  else
    warn "metadata-api failed: #{r[:error]}"
    if r[:error] == 'no_workbook_in_response'
      exit 4
    end
    exit 3
  end
when 'twb'
  r = fetch_via_twb_xml(twb_path)
  if r[:ok]
    source_chosen = 'twb-xml-fallback'
    final_calcs = r[:calcs]
  else
    warn "twb-xml fallback failed: #{r[:error]}"
    exit 3
  end
when 'auto'
  r = fetch_via_metadata_api(luid)
  if r[:ok]
    source_chosen = 'metadata-api'
    final_calcs = r[:calcs]
    wb_name = r[:workbook_name]
  else
    metadata_err = r[:error]
    warn "metadata-api unavailable (#{metadata_err}); falling back to .twb XML at #{twb_path}"
    r2 = fetch_via_twb_xml(twb_path)
    if r2[:ok]
      source_chosen = 'twb-xml-fallback'
      final_calcs = r2[:calcs]
    else
      warn "both paths failed — metadata: #{metadata_err}; twb: #{r2[:error]}"
      exit 3
    end
  end
end

# Persist the per-formula cache (signals computed during this run). Cheap and
# idempotent; safe even on an all-calcs run.
if $calc_cache
  CalcCache.save($calc_cache)
  warn "calc-cache: #{$calc_cache_stats[:hits]} hit / #{$calc_cache_stats[:misses]} miss (saved #{$calc_cache.size} entries → #{CalcCache.path})"
end

n_calcs_total = final_calcs.size

# ---- working-set filter -------------------------------------------------
used_by = nil
if scoping?(opts)
  meta_inputs = []
  # Explicit --used-by sidecars first.
  opts[:used_by].each do |p|
    if File.file?(p)
      meta_inputs << [p, JSON.parse(File.read(p))]
    else
      warn "WARN  --used-by sidecar not found: #{p}; skipping"
    end
  end
  # --dashboard resolves the sidecar next to the .twb. The base-branch parser
  # writes a dashboard-SCOPED meta when run with --dashboard; if migrate-tableau
  # already produced that scoped meta, --used-by is the precise handle. Here we
  # fall back to whatever full/scoped meta sits next to the .twb.
  if !opts[:dashboards].empty?
    mp = resolve_meta_path(twb_path)
    if mp
      meta_inputs << [mp, JSON.parse(File.read(mp))]
      warn "scoping: --dashboard #{opts[:dashboards].inspect} resolving against meta sidecar #{mp}"
    else
      warn "WARN  --dashboard given but no meta sidecar found next to #{twb_path}; " \
           'run parse-twb-layout.rb (with --dashboard) first or pass --used-by. ' \
           'Emitting UNFILTERED calc set.'
    end
  end

  if meta_inputs.empty?
    warn 'WARN  scoping requested but no usable meta sidecars; emitting all calcs.'
  else
    all_tokens = []
    used_by = {}
    meta_inputs.each do |path, meta|
      toks = used_tokens_from_meta(meta)
      label = (opts[:dashboards].empty? ? File.basename(path) : opts[:dashboards].join(' + '))
      used_by[label] ||= []
      all_tokens.concat(toks)
    end
    scoped = resolve_used_calcs(final_calcs, all_tokens.uniq)
    # Build the per-label index of kept calc CAPTIONS (what downstream sees).
    kept_captions = scoped.map { |c| c[:name] }.compact.uniq.sort
    used_by.each_key { |k| used_by[k] = kept_captions }
    warn "scoping: #{final_calcs.size} total calcs → #{scoped.size} used by " \
         "#{used_by.keys.join(', ')} (transitive closure over #{all_tokens.uniq.size} tokens)"
    final_calcs = scoped
  end
end

n_calcs = final_calcs.size
n_lods  = final_calcs.count { |c| c[:is_lod] }
n_sql   = final_calcs.count { |c| c[:requires_custom_sql] }

result = {
  workbook_luid: luid,
  workbook_name: wb_name,
  source: source_chosen,
  generated_at: Time.now.utc.iso8601,
  scoped: scoping?(opts) && !used_by.nil?,
  scope_dashboards: (opts[:dashboards].empty? ? nil : opts[:dashboards]),
  scope_used_by: (opts[:used_by].empty? ? nil : opts[:used_by]),
  n_calcs_total: n_calcs_total,
  n_calcs: n_calcs,
  n_lods: n_lods,
  n_requires_custom_sql: n_sql,
  used_by: used_by,
  metadata_api_error: metadata_err,
  calcs: final_calcs
}

File.write(out_path, JSON.pretty_generate(result))
scope_note = result[:scoped] ? " scoped #{n_calcs}/#{n_calcs_total}" : ''
warn "wrote #{out_path}  (source=#{source_chosen}, n_calcs=#{n_calcs}, n_lods=#{n_lods}, n_sql=#{n_sql})#{scope_note}"
puts JSON.pretty_generate(result)
exit 0
