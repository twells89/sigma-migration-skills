#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-anchors.rb — the MEASURED value bar for a converted workbook.
#
# WHY. Two field migrations recorded passing visual verdicts over dashboards
# whose NUMBERS were wrong: a ranked list showed different members with 10x-off
# values ("$1.2T" rendered where the source printed "12,345B"), and a
# multi-bucket panel collapsed to a single bar. Every judgment gate is an
# attestation, and lenient models attest generously — so this script replaces
# the judgment with a MEASUREMENT: each printed value the agent transcribed
# from the SOURCE dashboard image (Phase 1d, <workdir>/source-anchors.json)
# must literally appear in the LIVE Sigma workbook's element CSV exports, at
# the printed precision (scripts/lib/anchor_values.rb). An anchor value that
# appears NOWHERE in the workbook exports is the loudest possible signal the
# data is wrong.
#
# INPUT  <workdir>/source-anchors.json — authored by the AGENT at Phase 1d
#        while reading the source dashboard PNG (schema: SKILL.md Phase 1d,
#        refs/source-anchors.md):
#          { "source_image": "views/<id>.png", "transcribed_at": "...",
#            "anchors": [ { "id": "a1", "panel": "TOP ACCOUNTS",
#                           "label": "United Widgets revenue", "raw": "12,345B",
#                           "kind": "currency",
#                           "sigma_element_hint": "Top Accounts" } ] }
# OUTPUT <workdir>/anchors-verdict.json:
#          { "checked": N, "matched": M,
#            "missing": [ { "id", "label", "raw", "best_candidate" } ],
#            "pass": true|false }
#        Also stamps an `anchors` summary into parity-final.json when present.
#
# HOW. Fetches the live workbook spec for element names, then pools element
# CSV exports (the same POST /v2/workbooks/{wb}/export → poll
# GET /v2/query/{q}/download flow collect-parity-actuals.rb uses). Each anchor
# is searched in the element whose name best matches its label/panel (token
# overlap; `sigma_element_hint` wins when present); when the matched element
# doesn't carry the value, every other export is searched before declaring the
# anchor MISSING — found-elsewhere still counts as matched (the value exists;
# only the label→element mapping was fuzzy) and is noted in the verdict.
#
# BOUNDED EXPORTS (issue #416). Element exports are row-capped (the export
# POST sends Sigma's `rowLimit`; default anchors×10k, min 50k, --row-limit
# overrides, 0 = uncapped) and --timeout is the TOTAL wall-clock budget for
# the whole run — one deadline computed at start, checked by every poll loop
# and download (lib/export_pool.rb). Previously a multi-million-row
# unaggregated detail grid hung the pool indefinitely at 100% CPU (unbounded
# export → unbounded download → unbounded CSV.parse → per-cell scan). A
# TRUNCATED export can hide an anchor value below the cap, so an anchor that
# misses while any in-scope export was truncated reports
# 'inconclusive-truncated' — NEVER a hard MISS (a false MISS would demand a
# workbook "fix" for correct data). The pool prints one progress line per
# element start/finish; it is never silent for minutes.
#
# Usage (live):
#   ruby scripts/verify-anchors.rb --workdir <W> --workbook-id <id> \
#     [--anchors PATH] [--out PATH] [--pool 4] [--timeout 600] [--row-limit N]
# Usage (offline — tests / pre-collected exports):
#   ruby scripts/verify-anchors.rb --workdir <W> --workbook-spec spec.json \
#     --exports-dir <dir-with-<elementId>.csv>
#
# Exit codes: 0 = every anchor matched; 1 = one or more anchors missing (the
# per-miss report names each, with its closest candidate); 2 = usage / missing
# inputs; 3 = no hard miss but >=1 anchor inconclusive (truncated bounded
# export — add an element filter, verify via the warehouse SQL oracle, or
# raise --row-limit); 4 = --timeout total deadline expired (partial results
# recorded; the report names each element that timed out).

require 'json'
require 'csv'
require 'set'
require 'optparse'
require_relative 'lib/anchor_values'
begin
  require_relative 'lib/code_rep'
rescue LoadError
  require_relative '../lib/code_rep'
end

# Evidence ledger (PLAN-v4 E3.1) — optional: verdicts are appended to
# <workdir>/evidence-ledger.jsonl when the lib is vendored; an older checkout
# just skips the ledger line (stated, never fatal).
EVIDENCE_LEDGER_LOADED = begin
  require_relative 'lib/evidence_ledger'
  true
rescue LoadError
  begin
    require_relative '../lib/evidence_ledger'
    true
  rescue LoadError
    false
  end
end

# ---------------------------------------------------------------------------
# Pure core — unit-tested offline in test-verify-anchors.rb.
# ---------------------------------------------------------------------------
module AnchorVerify
  STOPWORDS = %w[the a an of by per and or in on for to vs].freeze

  # --- anchor PROVENANCE (PR-6 rider) ----------------------------------------
  # Where did the transcribed value COME from?
  #   view-csv     read off a Tableau view CSV export (strong: machine-rendered)
  #   vds          read off a VizQL Data Service query (strong: source-computed)
  #   png-eyeball  eyeball-transcribed from the dashboard PNG (weak: the field
  #                sessions mis-read rendered "##"/abbreviated values this way)
  # A VALUED anchor — one that can numerically vouch for a tile — must be a
  # NUMERIC anchor (not a name-only text/roster/member label) with provenance
  # view-csv|vds. png-eyeball and name-only anchors still verify (a printed
  # value/label must appear), but they earn NO tile-coverage credit: not toward
  # the G10 coverage floor, not toward gate 18's valued-anchors credit.
  # Anchors WITHOUT a provenance field (pre-PR-6 transcriptions) keep their G10
  # credit for back-compat but are never `valued`.
  VALUED_PROVENANCE = %w[view-csv vds].freeze
  NAME_ONLY_KINDS = %w[text roster member].freeze

  module_function

  def tokens(s)
    s.to_s.downcase.scan(/[a-z0-9]+/) - STOPWORDS
  end

  def name_only?(anchor)
    NAME_ONLY_KINDS.include?(anchor['kind'].to_s)
  end

  def valued?(anchor)
    !name_only?(anchor) && VALUED_PROVENANCE.include?(anchor['provenance'].to_s)
  end

  # G10 coverage-credit eligibility: numeric, and not EXPLICITLY eyeballed.
  def coverage_eligible?(anchor)
    !name_only?(anchor) && anchor['provenance'].to_s != 'png-eyeball'
  end

  # Overlap score between an anchor and an element name. sigma_element_hint,
  # when present, is the only signal; otherwise panel+label tokens are used.
  def element_score(anchor, el_name)
    hint = anchor['sigma_element_hint'].to_s
    name_toks = tokens(el_name)
    return 0 if name_toks.empty?
    if !hint.strip.empty?
      return 1_000 if hint.strip.casecmp?(el_name.to_s.strip)
      return (tokens(hint) & name_toks).length
    end
    ((tokens(anchor['panel']) | tokens(anchor['label'])) & name_toks).length
  end

  # Element names ordered best-match-first for this anchor; zero-score names
  # are appended (search everywhere before declaring a value missing).
  def ranked_elements(anchor, el_names)
    scored = el_names.map { |n| [n, element_score(anchor, n)] }
    hits = scored.select { |_, s| s.positive? }.sort_by { |n, s| [-s, n.to_s] }.map(&:first)
    hits + (el_names - hits)
  end

  # Numeric face values of a CSV cell (both percent interpretations kept so
  # AnchorValues candidate matching sees whichever the export carried).
  def cell_numbers(cell)
    s = cell.to_s
    # Export bytes arrive as ASCII-8BIT off the HTTP body; a UTF-8 regexp match
    # on that raises Encoding::CompatibilityError (live-caught). Normalize first.
    s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
    s = s.scrub('') unless s.valid_encoding?
    s = s.strip
    return [] if s.empty?
    neg = s.start_with?('(') && s.end_with?(')')
    s = s[1..-2] if neg
    body = s.gsub(/[,$€£¥\s]/, '')
    pct = body.end_with?('%')
    body = body.chomp('%')
    f = begin
      Float(body)
    rescue ArgumentError, TypeError
      return []
    end
    f = -f if neg
    pct ? [f, f / 100.0] : [f]
  end

  def rows_numbers(rows)
    rows.flat_map { |r| Array(r).flat_map { |c| cell_numbers(c) } }
  end

  # Normalized text cells of an export (for kind:"text" roster anchors).
  def rows_texts(rows)
    # (map+compact, not filter_map — the skill's floor is the system Ruby 2.6)
    rows.flat_map { |r| Array(r) }.map do |c|
      s = c.to_s
      s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
      s = s.scrub('') unless s.valid_encoding?
      s = s.strip.downcase
      s.empty? ? nil : s
    end.compact.to_set
  end

  # Verify anchors against { element_name => [[cell, ...], ...] } exports.
  # Returns the verdict Hash (contract shape + per-anchor detail).
  #
  # Two anchor kinds:
  #   numeric (default) — `raw` is a printed VALUE; matches any export cell at
  #     printed precision.
  #   kind: "text" (aka "roster") — `raw` is a LABEL that must appear as a cell
  #     (case-insensitive, trimmed). Use these on ranked/top-N tiles so a
  #     WRONGLY-SELECTED or dropped member fails loudly (a materialized top-15
  #     built from the wrong rank, a renamed category, a missing path label).
  #     Scope note: exports carry the element's full underlying data, so a
  #     roster anchor canNOT catch an UNFILTERED tile that merely WINDOWS the
  #     wrong first-N on screen — that class is caught by gate 9b (shape
  #     identity: the reviewer sees the wrong columns) and by the render-bisect
  #     playbook (unbounded pivots kill the renderer). Use both.
  #
  # extract_tol (Float, relative, e.g. 0.02 = ±2%) — EXTRACT DRIFT tolerance.
  #   An extract-based source renders a frozen snapshot in the PNG the anchors
  #   were transcribed from, while the landed warehouse can be fresher; the
  #   printed-precision bar then reports a legitimate mismatch, and the field
  #   temptation is to "fix" source-anchors.json (oracle rewriting — the exact
  #   tamper W1.3 locks against). Instead the CALLER (CLI) activates a relative
  #   tolerance ONLY for extract-marked workdirs: a numeric anchor that fails
  #   the exact printed-precision match is retried with
  #   relative_distance <= extract_tol, and a tolerance-admitted match RECORDS
  #   'tolerance_used' (+ measured 'drift') in its detail row so the verdict
  #   never silently launders drift into an exact pass. Text/roster anchors
  #   never use tolerance (labels don't drift). Hinted-anchor scoping applies
  #   identically to the tolerance retry.
  # truncated (Array/Set of element NAMES, optional) — elements whose bounded
  #   CSV export came back FULL (>= the row cap), i.e. the export may be
  #   missing rows. An anchor that fails to match while ANY element in its
  #   search scope is truncated canNOT be declared MISSING — the value may
  #   live below the cap — so it is reported 'inconclusive-truncated' in the
  #   verdict's `inconclusive` list instead of `missing` (issue #416: a
  #   truncated export must never produce a false hard MISS). Inconclusive
  #   anchors still fail `pass` — they are unverified, not vouched-for.
  def verify(anchors, exports, extract_tol: nil, truncated: nil)
    tol = extract_tol.is_a?(Numeric) && extract_tol.positive? ? extract_tol.to_f : nil
    trunc = Array(truncated)
    el_names = exports.keys
    numbers = exports.transform_values { |rows| rows_numbers(rows) }
    texts = exports.transform_values { |rows| rows_texts(rows) }
    detail = []
    missing = []
    inconclusive = []
    # A miss is only a hard MISS when every export the anchor searched was
    # complete; otherwise it lands in `inconclusive` with the truncated
    # element(s) named.
    classify_miss = lambda do |a, raw, scope_names, entry|
      t_hits = scope_names.select { |n| trunc.include?(n) }
      if t_hits.any?
        inconclusive << entry.merge('status' => 'inconclusive-truncated',
                                    'truncated_elements' => t_hits)
      else
        missing << entry
      end
    end
    # A HINTED anchor asserts WHERE its value/label must live. A match found
    # only in a hint-UNRELATED element (e.g. a raw detail table that merely
    # happens to contain the number) is NOT acceptance — that loophole silently
    # passed 10x-unit and wrong-aggregate defects in field testing (a KPI whose
    # value coincidentally appears in a big detail element). PR-414 scoped
    # hinted NUMERIC anchors; PR-6 extends the same rule to hinted text/roster
    # anchors (a hinted roster anchor asserts the member appears in THAT ranked
    # tile — found in an unrelated feeder table is not acceptance). Hint-less
    # anchors keep the search-everywhere fallback (no asserted location).
    scope_for = lambda do |a, order|
      next order if a['sigma_element_hint'].to_s.strip.empty?
      scoped = order.select { |n| element_score(a, n).positive? }
      scoped.empty? ? order : scoped # defensive: hint matched no element name
    end
    # Every detail/missing row carries the anchor's kind + provenance so
    # downstream consumers (G10 coverage, verify-ground-truth.rb, gate 18) can
    # apply the valued-anchor credit rules without re-reading source-anchors.
    stamp = lambda do |a, h|
      h['kind'] = a['kind'] if a['kind']
      h['provenance'] = a['provenance'] if a['provenance']
      h
    end
    anchors.each do |a|
      raw = a['raw'].to_s
      order = ranked_elements(a, el_names)
      search_order = scope_for.call(a, order)
      if name_only?(a)
        want = raw.strip.downcase
        found_in = search_order.find { |n| texts[n].include?(want) }
        if found_in
          detail << stamp.call(a, { 'id' => a['id'], 'raw' => raw, 'matched_in' => found_in,
                                    'valued' => false })
        else
          miss = { 'id' => a['id'], 'label' => a['label'], 'raw' => raw,
                   'best_candidate' => { 'note' => 'text anchor: label not present in any in-scope element export' } }
          miss['sigma_element_hint'] = a['sigma_element_hint'] unless a['sigma_element_hint'].to_s.strip.empty?
          classify_miss.call(a, raw, search_order, stamp.call(a, miss))
        end
        next
      end
      found_in = search_order.find { |n| numbers[n].any? { |v| AnchorValues.match?(raw, v) } }
      tol_used = nil
      if found_in.nil? && tol
        found_in = search_order.find do |n|
          numbers[n].any? { |v| AnchorValues.relative_distance(raw, v) <= tol }
        end
        tol_used = tol if found_in
      end
      if found_in
        primary = order.first
        d = { 'id' => a['id'], 'raw' => raw, 'matched_in' => found_in,
              'note' => (found_in == primary ? nil : "found outside best-match element #{primary.inspect}") }.compact
        d['valued'] = valued?(a)
        if tol_used
          drift = numbers[found_in].map { |v| AnchorValues.relative_distance(raw, v) }.min
          d['tolerance_used'] = tol_used
          d['drift'] = drift.round(6) if drift&.finite?
        end
        detail << stamp.call(a, d)
      else
        # Closest candidate WITHIN the best-matching element that carries any
        # numbers (walking down the ranking until one does) — the wrong value
        # almost always lives in the anchor's own panel, so this surfaces the
        # impostor ("$1.2T where the source printed 12,345B") rather than a
        # coincidentally-near number from an unrelated tile.
        best = nil
        order.each do |n|
          numbers[n].each do |v|
            d = AnchorValues.relative_distance(raw, v)
            best = { 'value' => v, 'element' => n, 'distance' => d.round(6) } if best.nil? || d < best['distance']
          end
          break if best
        end
        miss = { 'id' => a['id'], 'label' => a['label'], 'raw' => raw,
                 'best_candidate' => best }
        miss['sigma_element_hint'] = a['sigma_element_hint'] unless a['sigma_element_hint'].to_s.strip.empty?
        classify_miss.call(a, raw, search_order, stamp.call(a, miss))
      end
    end
    census = Hash.new(0)
    anchors.each { |a| census[a.is_a?(Hash) && a['provenance'] ? a['provenance'].to_s : 'unspecified'] += 1 }
    { 'checked' => anchors.length,
      'matched' => anchors.length - missing.length - inconclusive.length,
      'missing' => missing,
      'inconclusive' => inconclusive,
      'pass' => missing.empty? && inconclusive.empty?,
      'matched_via_tolerance' => detail.count { |d| d['tolerance_used'] },
      # PR-6 valued-anchor credit: numeric + provenance view-csv|vds matches
      # (the only anchors that numerically vouch for a tile downstream).
      'valued_matched' => detail.count { |d| d['valued'] },
      'provenance_census' => census,
      'detail' => detail }
  end
end

# ---------------------------------------------------------------------------
# CLI (IO / REST) — thin wrapper around the pure core above.
# ---------------------------------------------------------------------------
return if $PROGRAM_NAME != __FILE__ && !ENV['VERIFY_ANCHORS_CLI'] # allow `require` in tests

# Element display name for export keys. put-layout replaces `name` with a
# visibility hash on hidden-title elements — every such element would
# stringify to the SAME key and overwrite each other's exports (false RED on
# any anchor living in the clobbered tile). Fall back to text, then the id
# slug (unique by construction; token matching still ranks it).
def el_display_name(el)
  n = el['name']
  return n.to_s unless n.is_a?(Hash)
  t = n['text'].to_s
  t.empty? ? el['id'].to_s.sub(/\Ael-/, '').tr('-', ' ') : t
end

# --- extract-drift tolerance gating -----------------------------------------
# --extract-tol is honored ONLY when the workdir's own intake/landing artifacts
# mark the source as extract-based:
#   - a landing manifest (*landing-manifest*.json) — extracts were LANDED, or
#   - get-workbook.json hasExtracts=true (workbook or datasource level — the
#     same signals migrate-tableau/auto-parity-plan read).
# Returns a human-readable marker string, or nil (not extract-marked). Keeping
# the decision on ARTIFACTS (not a caller-asserted flag) means a live-source
# run can never borrow the tolerance to paper over a genuinely wrong value.
def extract_marker(dir)
  mani = Dir[File.join(dir, '*landing-manifest*.json')].first
  return "extract-landed (#{File.basename(mani)})" if mani
  gw_path = File.join(dir, 'get-workbook.json')
  if File.exist?(gw_path)
    gw = (JSON.parse(File.read(gw_path)) rescue nil)
    if gw.is_a?(Hash)
      has = gw['hasExtracts']
      return 'hasExtracts=true (get-workbook.json)' if has == true || has.to_s == 'true'
      ds = gw['datasources']
      return 'hasExtracts=true (get-workbook.json datasources)' if ds.to_s =~ /"hasExtracts"\s*(=>|:)\s*"?true/
    end
  end
  nil
end

# --- W1.1/W1.2: dashboard-tile emptiness + anchor scoping --------------------
# A 2026-07 field-workbook run went GREEN over a workbook whose every chart
# rendered "No data": the anchors oracle matched all 15 values inside the raw,
# UNFILTERED master feeder table (found-elsewhere counts as matched), so it
# vouched only that the WAREHOUSE landed — never that any displayed tile shows a
# value. These helpers separate DISPLAYED tiles (must return >=1 data row) from
# FEEDER tables (the master/masterAll twins other tiles derive from), so the gate
# can (a) hard-fail on any empty displayed tile and (b) know whether an anchor
# matched inside something the dashboard actually displays.

# Non-queryable / non-visualization element kinds (no data export to check).
VIZ_NONQUERY_KINDS = %w[control text image container divider button
                        visualization-legend page-control modal].freeze

# Every `elementId` string referenced ANYWHERE inside a node (a chart's
# source.elementId, a control's filter target, etc.). Walked recursively so the
# feeder set is spec-shape-agnostic. An element's OWN id lives under `id`, not
# `elementId`, so self-references are not collected.
def collect_source_elids(node, acc)
  case node
  when Hash
    node.each do |k, v|
      acc << v.to_s if k.to_s == 'elementId' && v && !v.to_s.empty?
      collect_source_elids(v, acc)
    end
  when Array
    node.each { |v| collect_source_elids(v, acc) }
  end
  acc
end

# Authoritative displayed-tile element ids the BUILD declared (parity plan +
# visual-verify manifests). Empty when no build artifacts are in the workdir
# (offline/standalone) — callers fall back to the source-graph leaf heuristic.
def declared_tile_ids(workdir)
  ids = []
  begin
    pp = File.join(workdir, 'parity-plan.json')
    (JSON.parse(File.read(pp))['charts'] || []).each { |c| ids << c['sigma_element_id'].to_s } if File.exist?(pp)
  rescue StandardError; end
  [File.join(workdir, 'visual-verify', 'manifest.json'),
   File.join(workdir, 'visual-verify-tiles.json')].each do |mf|
    next unless File.exist?(mf)
    begin
      arr = JSON.parse(File.read(mf))
      Array(arr).each { |t| ids << t['element_id'].to_s if t.is_a?(Hash) && t['element_id'] }
    rescue StandardError; end
  end
  ids.reject { |s| s.to_s.empty? }.uniq
end

# Per-element emptiness census. `exports` is {display_name => CSV rows incl.
# header}; a missing key = export never succeeded (failed/HTML/timeout — distinct
# from an empty result). Returns one record per queryable element.
def tile_emptiness_census(elements, exports, workdir)
  # FEEDER detection: an element is a feeder only when another element derives its
  # DATA from it, i.e. appears in that element's `source` subtree (master/masterAll
  # twins). Collect ONLY from the `source` of QUERYABLE elements — NOT the whole
  # element node, and NOT from controls. A control filters the tiles it targets via
  # `filters:[{source:{elementId:<tile>}}]`; walking that (the original bug, review-
  # caught) marked every control-filtered DISPLAYED chart as a feeder, so its
  # emptiness was never gated and the field-workbook false-GREEN stayed reachable.
  referenced = Set.new
  elements.each do |el|
    next if VIZ_NONQUERY_KINDS.include?(el['kind'].to_s) # controls/text/etc create no feeders
    collect_source_elids(el['source'], referenced)
  end
  declared = declared_tile_ids(workdir)
  elements.map do |el|
    kind = el['kind'].to_s
    next nil if VIZ_NONQUERY_KINDS.include?(kind)
    id   = el['id'].to_s
    rows = exports[el_display_name(el)]
    # CSV export carries a header row; data_rows = rows-1. nil = export failed.
    data_rows = rows.is_a?(Array) ? [rows.length - 1, 0].max : nil
    # A feeder is a raw base DATA TABLE another element derives from (master/
    # masterAll). Require kind=='table' so a referenced CHART/KPI/pivot (a dual-role
    # tile that is displayed AND sourced by another tile) is NOT misclassified as a
    # feeder and un-gated (review-caught false-negative). Genuine base tables stay
    # feeders, avoiding a false-positive on a legitimately-empty undisplayed base.
    is_feeder = referenced.include?(id) && kind == 'table'
    # Displayed tile: named by the build (authoritative) or, lacking artifacts, a
    # LEAF nothing else sources from (feeders are referenced by their consumers).
    # (A dual-role displayed TABLE in an artifact-less run remains a residual hole;
    # any real migration carries a parity-plan/visual-verify manifest → declared.)
    displayed = declared.empty? ? !is_feeder : declared.include?(id)
    { 'id' => id, 'name' => el_display_name(el), 'kind' => kind,
      'data_rows' => data_rows, 'displayed' => displayed, 'is_feeder' => is_feeder }
  end.compact
end

opts = { pool: 8, timeout: 600 } # pool 8: A/B report measured phase6-pass1 +70.5s dominated by anchor export collection
OptionParser.new do |p|
  p.on('--workdir DIR')        { |v| opts[:dir] = v }
  p.on('--tableau DIR', 'alias of --workdir') { |v| opts[:dir] = v }
  p.on('--workbook-id ID')     { |v| opts[:wb] = v }
  p.on('--anchors PATH', 'default: <workdir>/source-anchors.json') { |v| opts[:anchors] = v }
  p.on('--out PATH', 'default: <workdir>/anchors-verdict.json')    { |v| opts[:out] = v }
  p.on('--pool N', Integer)    { |v| opts[:pool] = v }
  p.on('--timeout S', Integer, 'TOTAL wall-clock budget for the whole run (default 600). One deadline is computed at start; every export poll and download checks it. On expiry: per-element "timeout" status, partial results recorded, exit 4.') { |v| opts[:timeout] = v }
  p.on('--row-limit N', Integer, 'row cap per element CSV export (Sigma export rowLimit). Default: anchors×10,000, min 50,000, capped at Sigma\'s 1M export ceiling. 0 = uncapped (NOT recommended — a multi-million-row detail grid is the issue-#416 hang). A miss over a truncated export reports inconclusive-truncated, never a hard MISS.') { |v| opts[:row_limit] = v }
  p.on('--extract-tol F', Float, 'relative tolerance (e.g. 0.02 = ±2%) for EXTRACT-based sources: the source PNG renders a frozen extract snapshot while the warehouse is fresher, so printed-precision misses can be legitimate drift. ONLY honored when the workdir is extract-marked (get-workbook.json hasExtracts / a landing manifest); tolerance-admitted matches are RECORDED per anchor (tolerance_used + drift), never silent. This — not editing source-anchors.json — is the sanctioned answer to extract drift.') { |v| opts[:extract_tol] = v }
  p.on('--workbook-spec PATH', 'offline: read element names from this spec instead of the live workbook') { |v| opts[:spec] = v }
  p.on('--exports-dir DIR', 'offline: read <elementId>.csv files instead of exporting live') { |v| opts[:exports] = v }
  p.on('--retranscribed REASON', 'authorize a CHANGE to source-anchors.json since its first verification — ONLY when you RE-READ the source dashboard PNG and corrected a genuine transcription error. REQUIRED reason string; the old->new diff is logged into the verdict and MUST be named in your report. NEVER use this to reconcile anchors against the live actuals (that defeats the whole measurement).') { |v| opts[:retranscribed] = v }
end.parse!
abort('--workdir required') unless opts[:dir]

anchors_path = opts[:anchors] || File.join(opts[:dir], 'source-anchors.json')
out_path     = opts[:out]     || File.join(opts[:dir], 'anchors-verdict.json')

unless File.exist?(anchors_path)
  warn "FATAL: #{anchors_path} not found — transcribe the source dashboard's printed values"
  warn '       at Phase 1d (every KPI, top-3 of every ranked list/table, one bucket value per'
  warn '       chart; EXACTLY as printed). Schema: SKILL.md Phase 1d / refs/source-anchors.md.'
  exit 2
end
doc = begin
  JSON.parse(File.read(anchors_path))
rescue JSON::ParserError => e
  warn "FATAL: #{anchors_path} is malformed JSON: #{e.message}"
  exit 2
end
anchors = Array(doc['anchors'])
if anchors.empty?
  warn "FATAL: #{anchors_path} has no anchors[] — nothing to verify."
  exit 2
end
# kind:"text"/"roster"/"member" anchors carry a LABEL in `raw` (displayed-set
# membership for ranked tiles) — only NUMERIC anchors must parse as values.
bad = anchors.reject do |a|
  next false unless a.is_a?(Hash)
  %w[text roster member].include?(a['kind'].to_s) ? !a['raw'].to_s.strip.empty? : AnchorValues.parse(a['raw'])
end
unless bad.empty?
  warn "FATAL: #{bad.length} anchor(s) have an unparseable `raw` printed value:"
  bad.first(10).each { |a| warn "         #{a.is_a?(Hash) ? a['id'] : '(bad entry)'}: raw=#{(a['raw'] rescue nil).inspect}" }
  warn '       `raw` must be the value EXACTLY as printed on the source image ("12,345B", "-2%",'
  warn '       "$733,215.26") — or, for kind:"text" roster anchors, a non-empty displayed label.'
  exit 2
end

# --- W1.3: source-anchor immutability ---------------------------------------
# The anchors are the MEASUREMENT; editing a printed VALUE after seeing the live
# actuals defeats the entire bar. The 2026-07 run changed a1 "12,345B" ->
# "12,338B" (the Sigma value) to flip a 14/15 FAIL into a 15/15 PASS. Lock the
# per-anchor id->raw map on first verification and refuse a later change to an
# EXISTING anchor's printed value unless --retranscribed authorizes a genuine
# re-transcription (re-read the SOURCE PNG, not the actuals). The decision is on
# the VALUE map, not the file bytes — reordering keys, re-indenting, editing a
# label, or ADDING/removing anchors is NOT tampering and must not false-refuse
# (review-caught: a byte hash tripped on a pretty-print of identical anchors).
require 'digest'
lock_path = File.join(opts[:dir], 'source-anchors.lock.json')
cur_map = anchors.each_with_object({}) { |a, h| h[a['id'].to_s] = a['raw'].to_s if a.is_a?(Hash) && a['id'] }
anchor_retranscribe = nil
if File.exist?(lock_path)
  lock = (JSON.parse(File.read(lock_path)) rescue {})
  prev_map = lock['anchors'].is_a?(Hash) ? lock['anchors'] : {}
  # Tamper signal: an id present in BOTH whose printed value changed.
  changed = cur_map.select { |id, raw| prev_map.key?(id) && prev_map[id].to_s != raw }
                   .map { |id, raw| { 'id' => id, 'from' => prev_map[id], 'to' => raw } }
  if changed.any?
    if opts[:retranscribed].to_s.strip.empty?
      warn "FATAL: #{changed.length} source-anchor VALUE(s) changed since first verification:"
      changed.each { |c| warn "         #{c['id']}: #{c['from'].inspect} -> #{c['to'].inspect}" }
      warn "       (locked #{lock['stamped_at']}) Editing a transcribed printed value after seeing the"
      warn '       live actuals defeats the measurement (the 2026-07 run flipped a FAIL to a PASS this'
      warn '       way). If — and ONLY if — you RE-READ the source dashboard PNG and corrected a genuine'
      warn '       transcription error, re-run with --retranscribed "<why, referencing the source image>".'
      warn '       Otherwise revert source-anchors.json and FIX THE WORKBOOK so the printed value appears.'
      exit 2
    end
    anchor_retranscribe = { 'reason' => opts[:retranscribed], 'changed' => changed }
    warn "[RETRANSCRIBED] #{changed.length} source-anchor value change(s) AUTHORIZED — #{opts[:retranscribed]}"
    changed.each { |c| warn "                #{c['id']}: #{c['from'].inspect} -> #{c['to'].inspect}" }
    warn '                This MUST be named in your migration report.'
  end
end
# (Re)stamp the lock every run: first sight, an authorized re-transcription, or a
# benign additions/reorder/label change all update the baseline id->raw map.
begin
  File.write(lock_path, JSON.pretty_generate(
    'content_sha256' => Digest::SHA256.hexdigest(File.read(anchors_path)), # record only, not the decision
    'stamped_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'anchor_count' => anchors.length,
    'anchors' => cur_map))
rescue StandardError => e
  warn "  [WARN] could not write source-anchors lock (#{e.class}: #{e.message.to_s[0, 60]})"
end

# --- element names + rows: offline (spec+exports dir) or live (REST) ---------
exports = {} # element name => rows (arrays of cells)
export_status = {}   # live: element name => 'ok' | 'ok-truncated' | 'timeout' | 'failed'
truncated_names = [] # live: elements whose bounded export came back FULL (may be missing rows)
deadline = nil       # live: whole-run wall-clock budget (ExportPool::Deadline)
row_limit = nil
export_cache = nil       # live: version-keyed RAW export cache (#7a; ExportPool::Cache)
export_doc_version = nil # live: workbook latestDocumentVersion the payloads bind to

if opts[:exports]
  spec_path = opts[:spec] || File.join(opts[:dir], 'wb-readback.json')
  unless File.exist?(spec_path)
    warn "FATAL: offline mode needs --workbook-spec (or <workdir>/wb-readback.json); #{spec_path} not found."
    exit 2
  end
  spec = Sigma::CodeRep.document(JSON.parse(File.read(spec_path)))
  elements = Sigma::CodeRep.workbook_elements(spec)
  elements.each do |el|
    csv = File.join(opts[:exports], "#{el['id']}.csv")
    next unless File.exist?(csv)
    exports[el_display_name(el)] = CSV.read(csv)
  end
else
  # Live: resolve workbook id, GET the spec, pool the element CSV exports —
  # the same export → poll → download flow collect-parity-actuals.rb uses.
  wb = opts[:wb]
  if wb.nil?
    ids = File.join(opts[:dir], 'wb-ids.json')
    wb = (JSON.parse(File.read(ids))['workbookId'] rescue nil) if File.exist?(ids)
  end
  abort('--workbook-id required (or a <workdir>/wb-ids.json with workbookId)') if wb.to_s.empty?

  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
  require 'export_pool'
  require 'code_rep'

  # ONE deadline for the entire run (issue #416: --timeout used to bound only
  # the per-element poll wait, so total runtime was unbounded). Computed here,
  # before any export starts; every poll loop and download checks it.
  deadline = ExportPool::Deadline.new(opts[:timeout])
  # Bounded exports: anchors need only enough rows to find printed values —
  # anchors×10k, floored at the SHARED default (ExportPool::
  # DEFAULT_EXPORT_ROW_LIMIT = collect-parity-actuals.rb's default; A3, wave-1
  # review: rowLimit is part of the raw-export cache key, so a divergent
  # default defeated every cross-script cache hit). Still keeps a 5M-row
  # detail grid from hanging the pool. --row-limit overrides; 0 = uncapped.
  row_limit =
    if opts.key?(:row_limit)
      opts[:row_limit].to_i.positive? ? [opts[:row_limit].to_i, ExportPool::SIGMA_EXPORT_HARD_CAP].min : nil
    else
      [[anchors.length * 10_000, ExportPool::DEFAULT_EXPORT_ROW_LIMIT].max,
       ExportPool::SIGMA_EXPORT_HARD_CAP].min
    end

  body = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'text/yaml')
  raw_spec = begin
    JSON.parse(body)
  rescue JSON::ParserError, TypeError
    require 'yaml'
    require 'date'
    body.is_a?(Hash) ? body : (YAML.safe_load(body.to_s, permitted_classes: [Date, Time]) || {})
  end
  # Workbook code-rep nests pages/layout/schemaVersion/kind under a top-level
  # `document` key (live since 2026-08-03/04). Flatten metadata (workbookId,
  # latestDocumentVersion, ...) and document content onto one hash: this file
  # reads BOTH off `spec` below (flat document elements, the doc version
  # from spec['latestDocumentVersion'] via ExportPool.resolve_doc_version, the
  # workbook id from spec['workbookId']) and mutates elements in place for the
  # pivot-totals strip/restore bracket, so one flat hash keeps every existing
  # read/mutation site below working unchanged. put_spec re-nests at the wire.
  spec = Sigma::CodeRep.metadata(raw_spec).merge(Sigma::CodeRep.document(raw_spec))
  elements = Sigma::CodeRep.workbook_elements(spec)
  queryable = elements.reject { |el| %w[control text image container].include?(el['kind'].to_s) }

  # v5.4 PIVOT-TOTALS CEILING: a pivot carrying a `totals` key 500s its CSV
  # export (probe-isolated: the key's PRESENCE is the sole trigger — value type
  # irrelevant), so a totals-bearing pivot's anchor values would read as MISSING
  # here through no fault of the data. Bracket the exports: capture + STRIP each
  # pivot's totals (one PUT), export against totals-free pivots, then RESTORE the
  # captured totals (ensure). Renders keep their hidden grand totals before and
  # after — only the brief export window is totals-free. The shipped hide state
  # is re-guaranteed by `put-layout.rb --apply-pivot-totals` at the finalize ship
  # step. Read-only spec fields are stripped before each PUT (Sigma rejects them).
  READONLY_SPEC_KEYS = %w[workbookId url ownerId createdBy updatedBy createdAt updatedAt latestDocumentVersion].freeze
  put_spec = lambda do |s|
    meta = Sigma::CodeRep.metadata(s).reject { |k, _| READONLY_SPEC_KEYS.include?(k) }
    body = Sigma::CodeRep.wrap(Sigma::CodeRep.document(s), extra: meta)
    Sigma.request(:put, "/v2/workbooks/#{wb}/spec", body: JSON.generate(body))
  end
  captured_totals = {}
  queryable.each do |el|
    next unless el['kind'] == 'pivot-table' && el.is_a?(Hash) && el.key?('totals')
    captured_totals[el['id'].to_s] = el.delete('totals')
  end
  # v5.4.9 review fix: persist the captured totals to a *-pivot-totals.json
  # sidecar BEFORE the strip PUT. If this process dies (or the restore PUT
  # fails) between strip and restore, the finalize ship step (put-layout.rb
  # --apply-pivot-totals, which globs the workdir) re-applies the FULL captured
  # totals — including showSubtotals — instead of stamping the lossy
  # showGrandTotals-only default. Deleted again after a successful restore.
  totals_sidecar = File.join(opts[:dir], 'anchors-restore-pivot-totals.json')
  if captured_totals.any?
    begin
      File.write(totals_sidecar, JSON.pretty_generate({ 'workbook' => wb, 'totals' => captured_totals }))
    rescue StandardError => e
      warn "  [WARN] could not write totals restore sidecar (#{e.class}: #{e.message.to_s[0, 80]})"
    end
  end

  # RAW export cache (#7a/#7d): one export per (workbook, latestDocumentVersion,
  # element) shared with collect-parity-actuals.rb and across gate re-runs.
  # RAW bodies only — every anchor/emptiness/truncation verdict below is still
  # recomputed from the bytes on every run (the reconciled #7 red line). The
  # cache is DISABLED when the totals strip/restore bracket is active: the
  # strip PUT bumps the document version mid-run, so payloads exported inside
  # the bracket cannot be strictly attributed to any stable version.
  export_doc_version = captured_totals.any? ? nil : ExportPool.resolve_doc_version(spec)
  export_cache = ExportPool::Cache.new(opts[:dir], workbook_id: wb.to_s,
                                       doc_version: export_doc_version)
  if export_cache.enabled?
    warn "  [cache] raw export cache active (wb #{wb} @ doc v#{export_doc_version}; " \
         'strict version keys, verdicts always recomputed)'
  elsif captured_totals.any?
    warn '  [cache] raw export cache OFF — pivot-totals strip/restore bumps the document version mid-run'
  else
    warn '  [cache] raw export cache OFF — spec carries no latestDocumentVersion (cannot version-key payloads)'
  end

  # Export one element, bounded by row_limit and the shared deadline.
  # Returns [:ok | :ok_truncated, rows] | [:timeout, nil] | [:failed, nil].
  export_one = lambda do |el|
    name = el_display_name(el)
    t_el = Time.now
    # Version-keyed raw-cache hit: skip the wire flow, reparse the recorded
    # bytes, recompute truncation — never a recorded verdict (#7 red line).
    if (cached = export_cache.fetch(el['id'], 'csv', row_limit))
      rows = CSV.parse(cached)
      trunc = ExportPool.truncated?(rows, row_limit)
      ExportPool.progress(deadline, format('CACHED  %s — %d recorded row(s) @ doc v%s (verdicts recomputed)%s',
                                           name.inspect, [rows.length - 1, 0].max, export_doc_version,
                                           trunc ? " [TRUNCATED at --row-limit #{row_limit}]" : ''))
      return [trunc ? :ok_truncated : :ok, rows]
    end
    qid = ExportPool.start_csv_export(wb, el['id'], row_limit)
    unless qid
      warn "  [WARN] export POST returned no queryId for element #{name.inspect}"
      return [:failed, nil]
    end
    status, body = ExportPool.poll_csv_download(qid, deadline)
    case status
    when :timeout
      ExportPool.progress(deadline, "TIMEOUT #{name.inspect} after #{(Time.now - t_el).round(1)}s — " \
                                    "--timeout #{opts[:timeout]}s total deadline reached")
      [:timeout, nil]
    when :html # HTML behind a 200 = renderer error
      warn "  [WARN] export for element #{name.inspect} returned HTML behind a 200 (renderer error)"
      [:failed, nil]
    else
      rows = CSV.parse(body)
      export_cache.store(el['id'], 'csv', row_limit, body)
      trunc = ExportPool.truncated?(rows, row_limit)
      ExportPool.progress(deadline, format('DONE    %s — %d row(s) in %.1fs%s', name.inspect,
                                           [rows.length - 1, 0].max, Time.now - t_el,
                                           trunc ? " [TRUNCATED at --row-limit #{row_limit}]" : ''))
      [trunc ? :ok_truncated : :ok, rows]
    end
  rescue Sigma::Error, CSV::MalformedCSVError => e
    msg = e.message.lines.first.to_s.strip[0, 120]
    ceiling = (el['kind'] == 'pivot-table' && e.is_a?(Sigma::Error) && msg =~ /\b500\b/) ?
      ' [PIVOT-TOTALS CEILING: a `totals` key 500s a pivot CSV export — this pivot still carries one; ' \
      'the strip/restore bracket should have removed it. See refs/layout-visual-qa.md]' : ''
    warn "  [WARN] export failed for element #{el_display_name(el).inspect}: #{msg}#{ceiling}"
    [:failed, nil]
  end

  require 'thread'
  begin
    # The strip PUT runs INSIDE this begin/ensure (v5.4.9 review fix): a
    # network-level exception on the PUT (Net::ReadTimeout, Errno::ECONNRESET,
    # SocketError — raised raw by Sigma.request, which only wraps HTTP-status
    # failures in Sigma::Error) can fire AFTER the server applied the strip;
    # previously it propagated before the restore bracket existed and left the
    # live workbook totals-stripped (grand totals visible). Restoring when the
    # strip never landed is an idempotent no-op PUT, so the ensure always
    # attempts it.
    if captured_totals.any?
      begin
        put_spec.call(spec)
        warn "  [totals-ceiling] stripped grand-total key from #{captured_totals.size} pivot(s) for CSV export (restored after)"
      rescue StandardError => e
        warn "  [WARN] could not strip pivot totals (#{e.class}: #{e.message.lines.first.to_s.strip[0, 100]}) — " \
             'totals-bearing pivot exports may 500; those anchors can only be checked via a totals-free export'
      end
    end
    warn format('  [pool] exporting %d element(s), pool=%d, row limit %s, total budget %ds',
                queryable.size, [opts[:pool], queryable.size].min.clamp(1, 8),
                row_limit ? row_limit.to_s : 'UNCAPPED', opts[:timeout])
    queue = Queue.new
    queryable.each { |el| queue << el }
    mutex = Mutex.new
    Array.new([opts[:pool], queryable.size].min.clamp(1, 8)) do
      Thread.new do
        loop do
          el = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          name = el_display_name(el)
          if deadline.expired?
            # Deadline already blown: don't even start the export — record a
            # clean per-element timeout so the report can name it.
            ExportPool.progress(deadline, "TIMEOUT #{name.inspect} — not started " \
                                          "(--timeout #{opts[:timeout]}s total deadline reached)")
            mutex.synchronize { export_status[name] = 'timeout' }
            next
          end
          ExportPool.progress(deadline, "START   #{name.inspect} (#{el['id']})")
          status, rows = export_one.call(el)
          mutex.synchronize do
            case status
            when :ok
              exports[name] = rows
              export_status[name] = 'ok'
            when :ok_truncated
              exports[name] = rows
              truncated_names << name
              export_status[name] = 'ok-truncated'
            when :timeout
              export_status[name] = 'timeout'
            else
              export_status[name] = 'failed'
            end
          end
        end
      end
    end.each(&:join)
  ensure
    # Restore the grand-total keys stripped for the export window so renders
    # (and the shipped workbook) keep hidden grand totals — even if the strip
    # PUT or an export above raised (network-level errors included). On
    # restore failure the sidecar written above survives, and the finalize
    # ship step re-applies the FULL captured totals (incl. showSubtotals).
    if captured_totals.any?
      begin
        elements.each { |el| (t = captured_totals[el['id'].to_s]) && el['totals'] = t }
        put_spec.call(spec)
        warn "  [totals-ceiling] restored grand-total key on #{captured_totals.size} pivot(s)"
        begin
          File.delete(totals_sidecar) if File.exist?(totals_sidecar)
        rescue StandardError
          nil # stale sidecar is harmless: it re-applies the same captured totals
        end
      rescue StandardError => e
        warn "  [WARN] pivot totals RESTORE failed (#{e.class}: #{e.message.lines.first.to_s.strip[0, 100]}) — " \
             "captured totals kept in #{File.basename(totals_sidecar)}; the finalize ship step " \
             '(put-layout.rb --apply-pivot-totals) re-applies them, incl. showSubtotals'
      end
    end
  end
end

if exports.empty?
  warn 'FATAL: no element exports could be collected — cannot verify anchors.'
  warn '       (live: check SIGMA_* credentials and the workbook id; offline: check --exports-dir)'
  exit 2
end

# --- extract-drift tolerance activation --------------------------------------
# The tolerance NEVER edits anchors; it widens the numeric match ONLY, only for
# extract-marked workdirs, and every tolerance-admitted match is recorded.
extract_tol_active = nil
extract_tol_info = nil
if opts[:extract_tol]
  tol = opts[:extract_tol].to_f
  if tol <= 0 || tol > 0.5
    warn "FATAL: --extract-tol #{opts[:extract_tol]} out of range (0 < F <= 0.5). A relative tolerance"
    warn '       above 50% is not a measurement — fix the workbook instead of widening the ruler.'
    exit 2
  end
  marker = extract_marker(opts[:dir])
  if marker
    extract_tol_active = tol
    warn format('[extract-tol] ±%.2f%% relative tolerance ACTIVE — %s. Tolerance-admitted matches are recorded per anchor.', tol * 100, marker)
  else
    warn "[extract-tol] REFUSED: --extract-tol #{tol} IGNORED — the workdir carries no extract marker"
    warn '              (no *landing-manifest*.json, no get-workbook.json hasExtracts=true).'
    warn '              The tolerance exists for extract-stale sources ONLY; on a live source a'
    warn '              printed-precision miss means the data is wrong. Fix the workbook.'
  end
  extract_tol_info = { 'requested' => tol, 'active' => !extract_tol_active.nil?,
                       'reason' => marker || 'workdir not extract-marked (hasExtracts/landing manifest absent)' }
end

verdict = AnchorVerify.verify(anchors, exports, extract_tol: extract_tol_active,
                                                truncated: truncated_names)
verdict['source_anchors'] = anchors_path
verdict['verified_at'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
verdict['extract_tolerance'] = extract_tol_info if extract_tol_info
# Bounded-export provenance (live mode): per-element export status, the row cap
# used, and whether the total --timeout deadline expired mid-run (issue #416).
timed_out_elements = export_status.select { |_, s| s == 'timeout' }.keys
unless export_status.empty?
  verdict['export_status'] = export_status
  verdict['export_row_limit'] = row_limit
  verdict['export_timeout_s'] = opts[:timeout]
  verdict['export_timed_out'] = timed_out_elements
  verdict['partial'] = timed_out_elements.any?
end
# RAW-cache provenance (#7a): how many exports were served from the version-
# keyed cache vs the wire. Payload reuse only — this verdict was recomputed
# from the raw bytes either way.
if export_cache && export_cache.enabled?
  verdict['export_cache'] = export_cache.stats.merge('doc_version' => export_doc_version)
end

# W1.1/W1.2: dashboard-tile emptiness + anchor display scoping. `elements` is in
# scope from whichever branch (offline spec / live REST) populated `exports`.
tiles = tile_emptiness_census(elements, exports, opts[:dir])
displayed_names = tiles.select { |t| t['displayed'] }.map { |t| t['name'] }.to_set
empty_displayed = tiles.select { |t| t['displayed'] && t['data_rows'] == 0 }
verdict['tiles'] = tiles
verdict['dashboard_tiles_empty'] = empty_displayed.map { |t| { 'id' => t['id'], 'name' => t['name'], 'kind' => t['kind'] } }
verdict['tiles_all_nonempty'] = empty_displayed.empty?
# Which matches landed in something the dashboard DISPLAYS vs only a raw feeder.
# The oracle's teeth are tiles_all_nonempty; this explains a landed-not-displayed
# pass (all anchors matched, every displayed tile empty).
verdict['detail'].each { |d| d['in_displayed_tile'] = displayed_names.include?(d['matched_in']) }
verdict['anchors_matched_in_displayed'] = verdict['detail'].count { |d| d['in_displayed_tile'] }
verdict['anchors_only_in_feeders'] = verdict['detail'].reject { |d| d['in_displayed_tile'] }.map { |d| d['id'] }
verdict['anchors_retranscribed'] = anchor_retranscribe if anchor_retranscribe

# --- G10: per-displayed-tile ANCHOR COVERAGE ---------------------------------
# Run-2 field failure: all 11 anchors sat in 3 of 9 displayed tiles, so the
# anchors oracle "passed" while 6 tiles had ZERO anchors watching them. A tile
# is COVERED when an anchor matched IN it (matched_in == the tile's display
# name) or is AIMED at it (sigma_element_hint token-matches the tile name —
# the hint asserts where the value must live even when the anchor missed).
# PR-6 rider: only COVERAGE-ELIGIBLE anchors earn credit — numeric anchors not
# explicitly provenance:"png-eyeball" (an eyeballed value is the weak reading
# the field sessions got wrong; a name-only text/roster anchor carries no
# value). Legacy anchors without a provenance field keep their credit.
# Advisory here (WARN, exit unchanged); assert-phase6-ran's charts_total==0
# anchors-ORACLE substitution requires covered == displayed unless each
# uncovered tile is named in source-anchors.json coverage_waivers
# [{tile, reason}] (authored at Phase 1d).
matched_in_names = verdict['detail'].select { |d| AnchorVerify.coverage_eligible?(d) }
                                    .map { |d| d['matched_in'].to_s }.to_set
hinted = anchors.select do |a|
  a.is_a?(Hash) && !a['sigma_element_hint'].to_s.strip.empty? && AnchorVerify.coverage_eligible?(a)
end
disp_tiles = tiles.select { |t| t['displayed'] }
covered_names = disp_tiles.map { |t| t['name'] }.select do |name|
  matched_in_names.include?(name) ||
    hinted.any? { |a| AnchorVerify.element_score(a, name).positive? }
end.to_set
uncovered = disp_tiles.map { |t| t['name'] }.reject { |n| covered_names.include?(n) }
verdict['anchor_coverage'] = { 'covered' => covered_names.size,
                               'displayed' => disp_tiles.size,
                               'uncovered' => uncovered }
if uncovered.any?
  cov_waived = Array(doc['coverage_waivers'])
               .map { |w| w.is_a?(Hash) ? w['tile'].to_s.downcase.strip : nil }.compact.reject(&:empty?)
  unwaived = uncovered.reject { |n| cov_waived.include?(n.to_s.downcase.strip) }
  warn "[WARN] anchor coverage: #{uncovered.length}/#{disp_tiles.size} displayed tile(s) have ZERO anchor coverage:"
  uncovered.each do |n|
    warn "         UNCOVERED  #{n.inspect}#{cov_waived.include?(n.to_s.downcase.strip) ? '  [coverage_waivers: waived at Phase 1d]' : ''}"
  end
  if unwaived.any?
    warn '       An anchor only vouches for the tile it lands in. Transcribe anchors for each uncovered'
    warn '       tile (re-read the source PNG), or name it in source-anchors.json coverage_waivers'
    warn '       [{"tile": "<name>", "reason": "<why no anchorable value>"}]. The all-embedded'
    warn '       (charts_total==0) anchors-ORACLE gate refuses substitution while unwaived tiles remain.'
  end
end

File.write(out_path, JSON.pretty_generate(verdict))

# Evidence ledger (E3.1): record this oracle run — verdict + where the raw
# evidence lives, under the strict version key. The GATE (assert-phase6-ran
# gate 13) still recomputes its own decision from anchors-verdict.json.
if EVIDENCE_LEDGER_LOADED
  el_wb = wb # nil on the offline (--exports-dir) branch
  el_wb = spec['workbookId'] if el_wb.to_s.empty? && spec.is_a?(Hash) && spec['workbookId']
  EvidenceLedger.append(
    opts[:dir], gate: 'verify-anchors',
    verdict: verdict['pass'] ? 'pass' : (Array(verdict['missing']).any? ? 'fail' : 'inconclusive'),
    evidence_kind: 'anchors-verdict',
    evidence_path: File.basename(out_path),
    evidence_key: EvidenceLedger.key(workbook_id: el_wb.to_s.empty? ? '?' : el_wb,
                                     doc_version: export_doc_version),
    evidence_sha256: EvidenceLedger.sha256_file(out_path),
    detail: { 'checked' => verdict['checked'], 'matched' => verdict['matched'],
              'missing' => Array(verdict['missing']).map { |m| m['id'] },
              'export_cache' => (export_cache && export_cache.enabled? ? export_cache.stats : nil) }.compact
  )
end

# Stamp the summary into parity-final.json when Phase 6 already finalized —
# the anchors result travels with the parity verdict the final gate reads.
pf = File.join(opts[:dir], 'parity-final.json')
if File.exist?(pf)
  begin
    s = JSON.parse(File.read(pf))
    s['anchors'] = { 'checked' => verdict['checked'], 'matched' => verdict['matched'],
                     'pass' => verdict['pass'], 'missing' => verdict['missing'].map { |m| m['id'] } }
    inc_ids = Array(verdict['inconclusive']).map { |m| m['id'] }
    s['anchors']['inconclusive'] = inc_ids if inc_ids.any?
    s['anchors']['matched_via_tolerance'] = verdict['matched_via_tolerance'] if verdict['matched_via_tolerance'].to_i.positive?
    s['anchors']['extract_tolerance'] = verdict['extract_tolerance'] if verdict['extract_tolerance']
    s['dashboard_tiles_empty'] = verdict['dashboard_tiles_empty']
    s['tiles_all_nonempty'] = verdict['tiles_all_nonempty']
    File.write(pf, JSON.pretty_generate(s))
  rescue JSON::ParserError
    warn "[WARN] #{pf} is malformed — anchors summary not stamped."
  end
end

puts "verify-anchors: #{verdict['matched']}/#{verdict['checked']} anchor(s) matched " \
     "across #{exports.length} element export(s) → #{out_path}"
verdict['detail'].each do |d|
  scope = d['in_displayed_tile'] ? '' : ' [FEEDER-ONLY: value is in a raw source table, not a displayed tile]'
  tolnote = d['tolerance_used'] ? format(' [EXTRACT-TOL: drift %.2f%% within ±%.2f%%]', (d['drift'] || 0) * 100, d['tolerance_used'] * 100) : ''
  puts "  MATCHED  #{d['id']} #{d['raw'].inspect} in #{d['matched_in'].inspect}#{d['note'] ? " (#{d['note']})" : ''}#{scope}#{tolnote}"
end
if verdict['matched_via_tolerance'].to_i.positive?
  puts "  [extract-tol] #{verdict['matched_via_tolerance']} anchor(s) matched only within the extract drift " \
       "tolerance (±#{format('%.2f', (extract_tol_active || 0) * 100)}%) — recorded in the verdict; " \
       'name this in your migration report. Anchors were NOT edited.'
end

# Total-deadline expiry (issue #416): the run is PARTIAL — some elements never
# exported — so no verdict below is final. Name every timed-out element, keep
# the partial results on disk, and exit with the distinct timeout code.
if timed_out_elements.any?
  warn ''
  warn "[TIMEOUT] --timeout #{opts[:timeout]}s TOTAL deadline reached — #{timed_out_elements.length} element export(s) timed out:"
  timed_out_elements.each { |n| warn "         TIMEOUT  #{n.inspect}" }
  warn "       Partial results recorded in #{out_path} (#{verdict['matched']}/#{verdict['checked']} anchors matched over"
  warn "       the #{exports.length} export(s) that completed; per-element status under \"export_status\")."
  warn '       Raise --timeout, lower --row-limit (smaller exports render faster), or add element filters to'
  warn '       shrink the slow tiles, then re-run. No anchor verdict is final on a partial run.'
  exit 4
end

# W1.1: non-empty dashboard tiles — the hard data-path check. A displayed tile
# that exports 0 data rows is the exact false-GREEN the field-workbook run hid
# behind a warehouse-only anchors pass. This is loud and fails the script even
# when every anchor "matched" (they can match in the unfiltered feeder table).
unless verdict['tiles_all_nonempty']
  warn ''
  warn "[FAIL] #{verdict['dashboard_tiles_empty'].length} displayed dashboard tile(s) export ZERO data rows —"
  warn '       the charts render "No data". Anchor matches in a raw feeder table do NOT count as'
  warn '       displayed data. Common causes: a control/filter literal that matches no rows (e.g.'
  warn '       "Region A & B" vs a calc emitting "Region A and B"), or a calc'
  warn '       comparing a NUMBER column to a string literal (renders NULL). Fix, then re-run.'
  verdict['dashboard_tiles_empty'].each { |t| warn "         EMPTY  #{t['id']} #{t['name'].inspect} [#{t['kind']}]" }
  if verdict['anchors_matched_in_displayed'].to_i.zero? && verdict['matched'].to_i.positive?
    warn "       NOTE: all #{verdict['matched']} anchor match(es) landed ONLY in feeder tables — " \
         'the warehouse landed but nothing is displayed.'
  end
  exit 1
end

if verdict['pass']
  puts '[OK] every source anchor value is present in the live workbook exports; ' \
       "all displayed tiles return data (#{verdict['anchors_matched_in_displayed']}/#{verdict['matched']} anchors in displayed tiles)."
  exit 0
end

# Truncation-inconclusive anchors (issue #416): the anchor missed, but at least
# one export it searched was TRUNCATED at the row cap — the value may simply
# live below the cap, so this is NOT a hard MISS and must not demand a workbook
# "fix" for possibly-correct data.
inconclusive = Array(verdict['inconclusive'])
if inconclusive.any?
  warn "[INCONCLUSIVE] #{inconclusive.length} anchor(s) could not be verified — a bounded export in their search"
  warn "               scope was TRUNCATED at the #{row_limit || 'requested'}-row cap (the value may live below it):"
  inconclusive.each do |m|
    warn "  INCONCLUSIVE  #{m['id']} #{m['label'].inspect} raw=#{m['raw'].inspect} — " \
         "truncated export(s): #{Array(m['truncated_elements']).map(&:inspect).join(', ')}"
  end
  warn '               Options: add an element filter so the tile exports fewer rows; verify the value via the'
  warn '               warehouse SQL oracle (verify-warehouse.rb / vds-oracle.rb) instead; or raise --row-limit.'
end

if verdict['missing'].any?
  warn "[FAIL] #{verdict['missing'].length} anchor(s) MISSING from the live workbook exports:"
  verdict['missing'].each do |m|
    bc = m['best_candidate']
    warn "  MISSING  #{m['id']} #{m['label'].inspect} raw=#{m['raw'].inspect}" \
         "#{bc ? " — closest candidate #{bc['value']} in #{bc['element'].inspect}" : ' — no numeric candidates at all'}"
  end
  warn '       A printed source value that appears NOWHERE in the workbook exports is the'
  warn '       loudest possible signal the data is wrong (wrong aggregate, wrong unit/10x,'
  warn '       missing filter, collapsed buckets). Fix the workbook — or, if the SOURCE'
  warn '       transcription was wrong, correct source-anchors.json — then re-run.'
  exit 1
end
exit 3 # inconclusive-only: unverified, not vouched-for — resolve before shipping
