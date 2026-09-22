#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-ground-truth.rb — PR-6 part B: compare the executed ground-truth
# actuals (run-ground-truth.rb → ground-truth-actuals.json) against the tile's
# LIVE Sigma element export (the parity-actuals shapes collect-parity-actuals.rb
# writes), and stamp a per-tile `numeric_parity` verdict into parity-final.json.
#
#   numeric_parity.tiles["<chart>"] = {
#     "oracle":  "warehouse-sql" | "vds" | "anchors",
#     "verdict": "match" | "diverge" | "unverified",
#     "max_rel_diff": <float|null>, "rows_compared": <int>,
#     "reason": <string|null>,               # why unverified / what diverged
#     "conflict": { ... }                    # ONLY when the two oracles disagree
#   }
#
# ORACLES PER CLASSIFICATION (ground-truth-plan.json is the ledger):
#   warehouse-sql  ground-truth rows joined against the Sigma export on the
#                  tile's dims (canonicalized via lib/dim_canon.rb — the SAME
#                  canonicalizer verify-parity.rb uses, incl. the e2e-defect
#                  date forms "1/4/2026 12:00:00 AM" and "Feb 4, 24");
#                  relative diff per measure against --tol (strict, live).
#   vds            read from vds-oracle.json (scripts/vds-oracle.rb) — match/
#                  near = verified, diverge = diverge, skipped/absent =
#                  unverified.
#   anchor-only /  VALUED-anchor credit from anchors-verdict.json: a numeric
#   unverifiable   anchor with provenance view-csv|vds (NOT png-eyeball, NOT a
#                  name-only text/roster anchor) that MATCHED IN this tile.
#
# ANCHORS COEXISTENCE CONTRACT (refs/source-anchors.md,
# refs/ground-truth-oracle.md): anchors are RENDERED-SOURCE truth; this oracle
# is WAREHOUSE truth. When they disagree the script never auto-resolves:
#   oracle DIVERGES + anchors MATCHED in the tile  → FATAL-investigate: the
#     warehouse disagrees with what the source rendered (data bug — wrong/
#     drifted warehouse data, or a wrong ground-truth derivation);
#   anchors MISSING for the tile + oracle MATCHES  → FATAL-investigate: Sigma
#     agrees with the warehouse but not with the rendered source (translation
#     or source-reading bug — wrong tile semantics faithfully computed).
# Both sides' evidence is printed; a conflicted tile is NOT verified.
#
# EXTRACT TOLERANCE: --extract-tol F is honored ONLY when the workdir is
# extract-marked (a *landing-manifest*.json, or get-workbook.json
# hasExtracts=true — the same artifact rule verify-anchors.rb enforces). A live
# source never borrows the tolerance.
#
# Usage:
#   ruby scripts/verify-ground-truth.rb --workdir <W> \
#     [--plan P]            # default <W>/ground-truth-plan.json
#     [--actuals P]         # default <W>/ground-truth-actuals.json
#     [--sigma-actuals P]   # default <W>/parity-actuals.json
#     [--anchors-verdict P] # default <W>/anchors-verdict.json (optional input)
#     [--vds-oracle P]      # default <W>/vds-oracle.json (optional input)
#     [--out P]             # default <W>/numeric-parity.json
#     [--tol F]             # strict relative tolerance (default 1e-4)
#     [--extract-tol F]     # extract-marked workdirs ONLY
#
# Exit codes: 0 = no divergence, no conflict (unverified tiles are listed —
#             coverage is gate 18's job, not this script's);
#             1 = usage / missing inputs / STALE actuals (plan_generated_at
#                 does not bind to the current plan);
#             2 = ≥1 tile DIVERGES or the oracles CONFLICT (FATAL — per-tile
#                 report names tile + measure + both values).

require 'json'
require 'set'
require 'optparse'
require_relative 'lib/dim_canon'

STRICT_TOL = 1e-4

opts = { tol: STRICT_TOL }
OptionParser.new do |p|
  p.on('--workdir DIR')         { |v| opts[:dir] = v }
  p.on('--plan PATH')           { |v| opts[:plan] = v }
  p.on('--actuals PATH')        { |v| opts[:actuals] = v }
  p.on('--sigma-actuals PATH')  { |v| opts[:sigma] = v }
  p.on('--anchors-verdict PATH') { |v| opts[:anchors] = v }
  p.on('--vds-oracle PATH')     { |v| opts[:vds] = v }
  p.on('--out PATH')            { |v| opts[:out] = v }
  p.on('--tol F', Float, "strict relative tolerance per measure (default #{STRICT_TOL})") { |v| opts[:tol] = v }
  p.on('--extract-tol F', Float, 'relative tolerance for EXTRACT-marked workdirs only (same artifact rule as verify-anchors.rb) — the ground truth queries the live warehouse while an extract-frozen source lags it') { |v| opts[:extract_tol] = v }
end.parse!
unless opts[:dir]
  warn 'usage: verify-ground-truth.rb --workdir <W> [--plan P] [--actuals P] [--sigma-actuals P] [--tol F] [--extract-tol F]'
  exit 1
end

dir          = opts[:dir]
plan_path    = opts[:plan]    || File.join(dir, 'ground-truth-plan.json')
actuals_path = opts[:actuals] || File.join(dir, 'ground-truth-actuals.json')
sigma_path   = opts[:sigma]   || File.join(dir, 'parity-actuals.json')
av_path      = opts[:anchors] || File.join(dir, 'anchors-verdict.json')
vds_path     = opts[:vds]     || File.join(dir, 'vds-oracle.json')
out_path     = opts[:out]     || File.join(dir, 'numeric-parity.json')

read_json = lambda do |path, required, hint|
  unless File.exist?(path)
    if required
      warn "FATAL: #{path} not found — #{hint}"
      exit 1
    end
    return nil
  end
  begin
    JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    warn "FATAL: #{path} is malformed JSON: #{e.message.lines.first.to_s.strip[0, 120]}"
    exit 1
  end
end

plan    = read_json.call(plan_path, true, 'run scripts/derive-ground-truth.rb first')
actuals = read_json.call(actuals_path, true, 'run scripts/run-ground-truth.rb first')
sigma   = read_json.call(sigma_path, false, nil) || {}
av      = read_json.call(av_path, false, nil)
vds     = read_json.call(vds_path, false, nil)

# Freshness bind: the actuals must have been executed against THIS plan.
if actuals['plan_generated_at'].to_s != plan['generated_at'].to_s
  warn "FATAL: #{actuals_path} is STALE — it ran against plan #{actuals['plan_generated_at'].inspect} " \
       "but #{plan_path} is #{plan['generated_at'].inspect}. Re-run scripts/run-ground-truth.rb."
  exit 1
end

# --- extract tolerance: artifact-gated, never caller-asserted ----------------
# (same rule as verify-anchors.rb — a live-source run can never borrow it)
extract_marker =
  if (mani = Dir[File.join(dir, '*landing-manifest*.json')].first)
    "extract-landed (#{File.basename(mani)})"
  else
    gw = read_json.call(File.join(dir, 'get-workbook.json'), false, nil)
    if gw.is_a?(Hash) && (gw['hasExtracts'] == true || gw['hasExtracts'].to_s == 'true' ||
                          gw['datasources'].to_s =~ /"hasExtracts"\s*(=>|:)\s*"?true/)
      'hasExtracts=true (get-workbook.json)'
    end
  end
tol = opts[:tol]
tol_note = "strict --tol #{tol}"
if opts[:extract_tol]
  if extract_marker
    tol = opts[:extract_tol]
    tol_note = "--extract-tol #{tol} (#{extract_marker})"
    warn "[extract-tol] ±#{(tol * 100).round(2)}% relative tolerance ACTIVE — #{extract_marker}."
  else
    warn "[extract-tol] REFUSED: --extract-tol #{opts[:extract_tol]} IGNORED — the workdir carries no extract marker"
    warn '              (no *landing-manifest*.json, no get-workbook.json hasExtracts=true). On a live source'
    warn '              a ground-truth mismatch means the numbers are wrong. Fix the workbook.'
  end
end

# --- anchors evidence per tile -----------------------------------------------
# matched: detail rows (matched_in = element display name). VALUED credit needs
# kind numeric + provenance view-csv|vds (the post-PR-6 verify-anchors writes
# kind/provenance/valued into every detail row; older verdicts earn no credit —
# fail-closed). MISSING valued anchors aimed at a tile (sigma_element_hint
# token-match) are the anchors-side divergence evidence.
def norm_name(s)
  s.to_s.strip.downcase
end

anchors_matched = Hash.new { |h, k| h[k] = [] }   # tile name → matched detail rows (any numeric anchor)
anchors_valued  = Hash.new { |h, k| h[k] = [] }   # tile name → matched VALUED detail rows
anchors_missing = Hash.new { |h, k| h[k] = [] }   # tile name → missing anchors aimed at it
if av.is_a?(Hash)
  Array(av['detail']).each do |d|
    next unless d.is_a?(Hash) && d['matched_in']
    key = norm_name(d['matched_in'])
    kind = d['kind'].to_s
    next if %w[text roster member].include?(kind) # name-only anchors carry no value
    anchors_matched[key] << d
    anchors_valued[key] << d if d['valued'] == true
  end
  Array(av['missing']).each do |m|
    next unless m.is_a?(Hash)
    next if %w[text roster member].include?(m['kind'].to_s)
    hint = m['sigma_element_hint'].to_s
    next if hint.strip.empty? # no asserted location — cannot attribute the miss to a tile
    anchors_missing[norm_name(hint)] << m
  end
end

# --- vds oracle evidence per element ----------------------------------------
vds_checks = Hash.new { |h, k| h[k] = [] } # element_id AND element_name → checks
if vds.is_a?(Hash)
  Array(vds['checks']).each do |c|
    next unless c.is_a?(Hash)
    vds_checks[c['element_id'].to_s] << c if c['element_id']
    vds_checks[norm_name(c['element_name'])] << c if c['element_name']
  end
end

# --- warehouse-sql comparison -------------------------------------------------
gt_results = Array(actuals['results']).each_with_object({}) { |r, h| h[r['chart']] = r }

# Sigma rows for a chart: parity-actuals.json { "<chart>": rows | marker }.
def sigma_rows_for(sigma, chart)
  v = sigma[chart]
  return [nil, nil] if v.nil?
  return [nil, "Sigma export unavailable: #{v['status']}#{v['reason'] ? " (#{v['reason']})" : ''}"] if v.is_a?(Hash)
  [v, nil]
end

def exported_decimal_precision(value)
  return nil unless value.is_a?(Numeric) && value.to_f.finite?
  scale = [value.to_f.abs, 1.0].max
  (0..9).find { |places| (value.to_f - value.to_f.round(places)).abs <= scale * 1e-9 } || 9
end

# Compare one warehouse-sql tile. Returns the stamp fields + printable detail.
def compare_tile(entry, gt_res, sigma_rows, tol)
  cols = Array(entry['columns'])
  n_dims = cols.count { |c| c['role'] == 'dim' }
  n_meas = cols.count { |c| c['role'] == 'measure' }
  gt = Array(gt_res['rows']).map { |r| DimCanon.round_row(Array(r)) }
  sg = Array(sigma_rows).map { |r| DimCanon.round_row(Array(r)) }
  return { 'verdict' => 'unverified', 'reason' => 'ground truth returned no rows', 'rows_compared' => 0 } if gt.empty?
  return { 'verdict' => 'unverified', 'reason' => 'Sigma export returned no rows', 'rows_compared' => 0 } if sg.empty?
  if sg.any? { |r| r.length < n_dims + 1 }
    return { 'verdict' => 'unverified', 'rows_compared' => 0,
             'reason' => "Sigma rows narrower (#{sg.map(&:length).min} cell(s)) than the tile's #{n_dims} dim(s) + a measure" }
  end

  gt_key = ->(r) { r.first(n_dims) }
  # Duplicate keys on either side (flattened multi-series the plan didn't carry
  # as a dim): fall back to exact tuple-set identity — never guess a join.
  gt_keys = gt.map(&gt_key)
  sg_keys = sg.map(&gt_key)
  if gt_keys.uniq.length < gt_keys.length || sg_keys.uniq.length < sg_keys.length
    width = [n_dims + n_meas, sg.map(&:length).min].min
    gt_set = Set.new(gt.map { |r| r.first(width) })
    sg_set = Set.new(sg.map { |r| r.first(width) })
    if gt_set == sg_set
      return { 'verdict' => 'match', 'max_rel_diff' => 0.0, 'rows_compared' => gt_set.size,
               'reason' => 'duplicate dim keys — verified by exact tuple-set identity' }
    end
    return { 'verdict' => 'diverge', 'max_rel_diff' => nil, 'rows_compared' => (gt_set & sg_set).size,
             'reason' => 'duplicate dim keys and the tuple sets differ',
             'only_in_ground_truth' => (gt_set - sg_set).to_a.first(3),
             'only_in_sigma' => (sg_set - gt_set).to_a.first(3) }
  end

  gt_h = gt.each_with_object({}) { |r, h| h[gt_key.call(r)] = r[n_dims, n_meas] || [] }
  sg_h = sg.each_with_object({}) { |r, h| h[gt_key.call(r)] = r[n_dims..-1] || [] }
  only_gt = (gt_h.keys - sg_h.keys)
  only_sg = (sg_h.keys - gt_h.keys)
  shared = gt_h.keys & sg_h.keys
  max_rel = 0.0
  worst = nil
  display_precision_used = false
  meas_aliases = cols.select { |c| c['role'] == 'measure' }.map { |c| c['alias'] }
  shared.each do |k|
    gvec = gt_h[k]
    svec = sg_h[k]
    [gvec.length, svec.length].min.times do |j|
      g = gvec[j]
      s = svec[j]
      next unless g.is_a?(Numeric) && s.is_a?(Numeric)
      places = exported_decimal_precision(s)
      ground_value = places ? g.to_f.round(places) : g
      sigma_value = places ? s.to_f.round(places) : s
      display_precision_used ||= ground_value != g
      rel = (ground_value.to_f - sigma_value.to_f).abs /
            [ground_value.to_f.abs, sigma_value.to_f.abs, 1.0].max
      if rel > max_rel
        max_rel = rel
        worst = { 'key' => k, 'measure' => meas_aliases[j] || "measure ##{j + 1}",
                  'ground_truth' => g, 'sigma' => s, 'rel_diff' => rel.round(6) }
      end
    end
  end
  if only_gt.any? || only_sg.any?
    return { 'verdict' => 'diverge', 'max_rel_diff' => max_rel.round(6), 'rows_compared' => shared.size,
             'reason' => "dim buckets differ: #{only_gt.size} only in ground truth, #{only_sg.size} only in Sigma",
             'only_in_ground_truth' => only_gt.first(3), 'only_in_sigma' => only_sg.first(3),
             'worst' => worst }
  end
  if max_rel > tol
    return { 'verdict' => 'diverge', 'max_rel_diff' => max_rel.round(6), 'rows_compared' => shared.size,
             'reason' => "measure #{worst['measure'].inspect} differs beyond tol #{tol}", 'worst' => worst }
  end
  { 'verdict' => 'match', 'max_rel_diff' => max_rel.round(6), 'rows_compared' => shared.size,
    'display_precision' => display_precision_used }
end

tiles = {}
counts = Hash.new(0)
conflicts = []
diverges = []

Array(plan['entries']).each do |entry|
  chart = entry['chart'].to_s
  cls = entry['classification'].to_s
  key = norm_name(chart)
  stamp =
    case cls
    when 'warehouse-sql'
      res = gt_results[entry['chart']]
      s_rows, s_reason = sigma_rows_for(sigma, entry['chart'])
      if res.nil? || res['status'] != 'ok'
        { 'oracle' => 'warehouse-sql', 'verdict' => 'unverified', 'rows_compared' => 0,
          'reason' => res.nil? ? 'no ground-truth execution result for this tile' :
                      "ground-truth execution #{res['status']}#{res['error'] ? ": #{res['error'].to_s[0, 120]}" : ''}" }
      elsif s_rows.nil?
        { 'oracle' => 'warehouse-sql', 'verdict' => 'unverified', 'rows_compared' => 0,
          'reason' => s_reason || 'no Sigma actuals collected for this tile (collect-parity-actuals.rb)' }
      else
        { 'oracle' => 'warehouse-sql' }.merge(compare_tile(entry, res, s_rows, tol))
      end
    when 'vds'
      checks = vds_checks[entry['sigma_element_id'].to_s]
      checks = vds_checks[key] if checks.empty?
      divs = checks.select { |c| c['status'] == 'diverge' }
      hits = checks.select { |c| %w[match near].include?(c['status'].to_s) }
      if divs.any?
        w = divs.first
        { 'oracle' => 'vds', 'verdict' => 'diverge', 'rows_compared' => w['n_joined'].to_i,
          'max_rel_diff' => w['max_rel_diff'],
          'reason' => "vds-oracle diverge on #{w['calc'].inspect}",
          'worst' => { 'measure' => w['calc'], 'ground_truth' => w['tableau_value'], 'sigma' => w['sigma_value'] } }
      elsif hits.any?
        { 'oracle' => 'vds', 'verdict' => 'match', 'rows_compared' => hits.map { |c| c['n_joined'].to_i }.max,
          'max_rel_diff' => hits.map { |c| c['max_rel_diff'].to_f }.max }
      else
        { 'oracle' => 'vds', 'verdict' => 'unverified', 'rows_compared' => 0,
          'reason' => vds.nil? ? 'vds-oracle.json absent — run scripts/vds-oracle.rb' :
                      "vds oracle did not verify this tile (#{checks.map { |c| c['status'] }.uniq.join(', ')})" }
      end
    else # anchor-only / unverifiable → VALUED-anchor credit only
      valued = anchors_valued[key]
      if valued.any?
        { 'oracle' => 'anchors', 'verdict' => 'match', 'rows_compared' => valued.length,
          'max_rel_diff' => nil,
          'reason' => "#{valued.length} valued anchor(s) (provenance view-csv/vds) matched in this tile" }
      else
        eyeball = anchors_matched[key].length
        { 'oracle' => 'anchors', 'verdict' => 'unverified', 'rows_compared' => 0,
          'reason' => "#{cls}: #{entry['reason'].to_s[0, 100]}" \
                      "#{eyeball.positive? ? " — #{eyeball} anchor(s) matched but none are VALUED (need numeric + provenance view-csv|vds, not png-eyeball)" : ' — no valued anchors matched in this tile'}" }
      end
    end

  # --- conflict matrix (never auto-resolved) ---------------------------------
  if stamp['verdict'] == 'diverge' && anchors_matched[key].any?
    stamp['conflict'] = {
      'type' => 'oracle-diverges-anchors-match',
      'investigate' => 'DATA BUG: the warehouse disagrees with what the rendered source shows — ' \
                       'drifted/wrong warehouse data, or a wrong ground-truth derivation',
      'anchors' => anchors_matched[key].map { |d| { 'id' => d['id'], 'raw' => d['raw'] } }.first(5)
    }
  elsif stamp['verdict'] == 'match' && anchors_missing[key].any?
    stamp['conflict'] = {
      'type' => 'anchors-diverge-oracle-matches',
      'investigate' => 'TRANSLATION/SOURCE-READING BUG: Sigma agrees with the warehouse but not with ' \
                       'the rendered source — the tile may faithfully compute the WRONG semantics',
      'anchors' => anchors_missing[key].map { |m| { 'id' => m['id'], 'raw' => m['raw'], 'best_candidate' => m['best_candidate'] } }.first(5)
    }
  end

  conflicts << [chart, stamp] if stamp['conflict']
  diverges << [chart, stamp] if stamp['verdict'] == 'diverge'
  counts[stamp['verdict']] += 1
  tiles[chart] = stamp
end

doc = {
  'version' => 1,
  'verified_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
  'plan_generated_at' => plan['generated_at'],
  'tolerance' => tol,
  'tolerance_note' => tol_note,
  'tiles' => tiles,
  'summary' => { 'tiles' => tiles.size, 'match' => counts['match'],
                 'diverge' => counts['diverge'], 'unverified' => counts['unverified'],
                 'conflicts' => conflicts.size }
}
File.write(out_path, JSON.pretty_generate(doc))

# Stamp into parity-final.json — EXTEND its existing shape (the same pattern
# verify-anchors.rb / vds-oracle.rb use); never replace other keys.
pf_path = File.join(dir, 'parity-final.json')
if File.exist?(pf_path)
  begin
    pf = JSON.parse(File.read(pf_path))
    pf['numeric_parity'] = doc.reject { |k, _| k == 'version' }
    File.write(pf_path, JSON.pretty_generate(pf))
  rescue JSON::ParserError
    warn "[WARN] #{pf_path} is malformed — numeric_parity not stamped."
  end
else
  warn "[WARN] #{pf_path} does not exist yet — numeric_parity written to #{out_path} only " \
       '(assert-phase6-ran.rb gate 18 reads either).'
end

# --- report -------------------------------------------------------------------
tiles.each do |chart, s|
  tag = format('%-10s', s['verdict'].upcase)
  extra = s['verdict'] == 'match' ? "rows=#{s['rows_compared']}#{s['max_rel_diff'] ? " max_rel_diff=#{s['max_rel_diff']}" : ''}" : s['reason'].to_s[0, 140]
  puts "  #{tag} [#{s['oracle']}] #{chart.inspect} — #{extra}"
end
puts "verify-ground-truth: #{counts['match']}/#{tiles.size} tile(s) match, #{counts['diverge']} diverge, " \
     "#{counts['unverified']} unverified (#{tol_note}) → #{out_path}"

diverges.each do |chart, s|
  warn "[FAIL] #{chart.inspect} DIVERGES from the #{s['oracle']} ground truth — #{s['reason']}"
  if (w = s['worst'])
    warn "       #{w['measure'].inspect}#{w['key'] ? " at #{w['key'].inspect}" : ''}: " \
         "ground truth #{w['ground_truth'].inspect} vs Sigma #{w['sigma'].inspect}" \
         "#{w['rel_diff'] ? " (rel diff #{w['rel_diff']})" : ''}"
  end
  warn "       only in ground truth: #{s['only_in_ground_truth'].inspect[0, 160]}" if s['only_in_ground_truth']
  warn "       only in Sigma:        #{s['only_in_sigma'].inspect[0, 160]}" if s['only_in_sigma']
end
conflicts.each do |chart, s|
  c = s['conflict']
  warn "[FATAL-INVESTIGATE] #{chart.inspect}: #{c['type']} — the two oracles DISAGREE and this script"
  warn '       never auto-resolves a conflict. Both sides of the evidence:'
  warn "         oracle (#{s['oracle']}, warehouse truth): verdict=#{s['verdict']}" \
       "#{s['worst'] ? " worst=#{s['worst'].inspect[0, 160]}" : " max_rel_diff=#{s['max_rel_diff'].inspect}"}"
  Array(c['anchors']).each do |a|
    warn "         anchor (rendered-source truth): #{a['id']} raw=#{a['raw'].inspect}" \
         "#{a['best_candidate'] ? " closest-in-workbook=#{a['best_candidate'].inspect[0, 120]}" : ' (matched in this tile)'}"
  end
  warn "       #{c['investigate']}"
end

if diverges.any? || conflicts.any?
  warn "[FAIL] #{diverges.size} diverging + #{conflicts.size} conflicted tile(s) — the numbers are not proven. " \
       'Investigate each named tile; never edit the ground truth or the anchors to agree with the workbook.'
  exit 2
end
exit 0
