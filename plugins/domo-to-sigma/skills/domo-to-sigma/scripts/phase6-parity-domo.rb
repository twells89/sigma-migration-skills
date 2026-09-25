#!/usr/bin/env ruby
# frozen_string_literal: true
#
# phase6-parity-domo.rb — the Phase-6 parity FINALIZER for domo-to-sigma.
# Bead beads-sigma-2tkm.
#
# WHY THIS EXISTS
# ---------------
# domo was the only converter of six with no phase6-parity-*.rb finalizer
# (looker/powerbi/quicksight/tableau/thoughtspot all have one). Without it,
# migrate-domo.rb pointed verify-parity.rb's --score-out directly at
# parity-final.json — overwriting the GATE'S CONTRACT FILE with a score
# document. assert-phase6-ran.rb gate 1 reads charts_total/charts_pass/status;
# the score document carries tiles_total/tiles_pass/tiles_fail. So the gate read
# charts_total = 0, fell into the anchors-oracle substitution branch, found no
# anchors-verdict.json, and exited 2 — meaning a flawless 65/65 parity run was
# indistinguishable from never having run parity at all.
#
# Two documents, two jobs — the same split tableau's phase6-parity.rb:344-382 makes:
#
#   parity-score.json   verify-parity.rb --score-out    tiles_*, per-tile value scores
#   parity-final.json   THIS script                     charts_*/status — the gate contract
#
# THE CENSUS (anti-inflation)
# ---------------------------
# Gate 1 computes its pass rate purely from what the plan contains; nothing
# cross-checks the plan against the workbook's actual chartable elements. So a
# plan quietly narrowed to the easy tiles scores "100% (45/45)" and reads
# identically to a genuine full pass. This finalizer refuses to emit a contract
# unless every chartable element is either VERIFIED or EXCLUDED WITH A REASON in
# parity-plan-exclusions.json. Excluding a tile stays legitimate; excluding it
# silently does not.
#
# Usage:
#   ruby scripts/phase6-parity-domo.rb --workdir <wd> --plan <wd>/parity-plan.json \
#     --workbook-id <id> [--workbook-spec PATH] [--exclusions PATH] [--out PATH]
#     [--score-out PATH] [--skip-verify] [--allow-missing-census REASON]
#
# Exit codes: 0 = contract written; 1 = bad invocation / missing input;
#             5 = census unbalanced or unverifiable (unaccounted tiles, a
#                 reasonless exclusion, or no workbook spec and no named waiver);
#             6 = verify-parity.rb produced no score document (it crashed).
#
# On every non-zero exit any pre-existing parity-final.json is INVALIDATED
# (status=FAIL + finalize_error) rather than left behind, so a prior run's PASS
# can never be read as this run's evidence. See die! below.
require 'json'
require 'optparse'
require 'open3'
require 'time'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'domo_workbook_code'

opts = { workdir: nil, plan: nil, wb: nil, spec: nil, excl: nil, out: nil,
         score_out: nil, skip_verify: false, extract_mode: false }
OptionParser.new do |p|
  p.banner = 'Usage: phase6-parity-domo.rb --workdir DIR --plan PATH [options]'
  p.on('--workdir DIR', 'run directory (migrate-domo.rb --out)')       { |v| opts[:workdir] = v }
  p.on('--plan PATH', 'parity plan actually verified')                 { |v| opts[:plan] = v }
  p.on('--workbook-id ID')                                            { |v| opts[:wb] = v }
  p.on('--workbook-spec PATH', 'default <workdir>/workbook-spec.json') { |v| opts[:spec] = v }
  p.on('--exclusions PATH', 'default <workdir>/parity-plan-exclusions.json') { |v| opts[:excl] = v }
  p.on('--out PATH', 'default <workdir>/parity-final.json')            { |v| opts[:out] = v }
  p.on('--score-out PATH', 'default <workdir>/parity-score.json')      { |v| opts[:score_out] = v }
  p.on('--extract-mode', 'pass --extract-mode through to verify-parity.rb') { opts[:extract_mode] = true }
  p.on('--skip-verify', 'finalize from an existing parity-score.json (do not re-run verify-parity)') { opts[:skip_verify] = true }
  p.on('--allow-missing-census REASON',
       'proceed without a workbook spec (and therefore WITHOUT the anti-inflation census) — ' \
       'REQUIRED reason string, recorded in parity-final.json as census_waiver and MUST be ' \
       'named in the migration report') { |v| opts[:allow_missing_census] = v }
end.parse!

abort('phase6-parity-domo: --workdir is required') unless opts[:workdir]
abort("phase6-parity-domo: --workdir #{opts[:workdir]} does not exist") unless Dir.exist?(opts[:workdir])
opts[:plan]      ||= File.join(opts[:workdir], 'parity-plan.json')
opts[:spec]      ||= File.join(opts[:workdir], 'workbook-spec.json')
opts[:excl]      ||= File.join(opts[:workdir], 'parity-plan-exclusions.json')
opts[:out]       ||= File.join(opts[:workdir], 'parity-final.json')
opts[:score_out] ||= File.join(opts[:workdir], 'parity-score.json')
abort("phase6-parity-domo: --plan #{opts[:plan]} does not exist") unless File.exist?(opts[:plan])

# ---------------------------------------------------------------------------
# Chartable predicate — kept byte-identical in behaviour to
# shared/scripts/build-parity-plan.rb:50-57. If that predicate ever changes,
# this census over-counts and FAILS CLOSED (unaccounted tiles) rather than
# silently shrinking the denominator; test/test-phase6-parity-domo.rb group E
# pins the behaviour.
# ---------------------------------------------------------------------------
SKIP_KIND = /control|^text$|^image$|^button|container|^iframe|^embed|^divider/i
def chartable?(el)
  k = el['kind'].to_s
  return false if k.empty? || k =~ SKIP_KIND
  return false if el['visibleAsSource'] == false
  (el['columns'] || []).any?
end

# build-parity-plan.rb's own naming rule, so census names and plan names match.
def element_name(el)
  n = el['name'].is_a?(Hash) ? el['name']['text'] : el['name']
  n = nil if n.to_s.empty?
  (n || el['title'] || el['id']).to_s
end

def load_json(path)
  JSON.parse(File.read(path))
rescue StandardError => e
  abort("phase6-parity-domo: cannot read #{path}: #{e.message}")
end

# Exit non-zero WITHOUT leaving a stale PASS contract behind.
#
# Every failure path here runs in a workdir that may already hold a
# parity-final.json from an earlier, successful finalize (migrate-domo.rb is
# idempotent and re-running into a populated workdir is the normal path). Simply
# exiting would leave that prior `status: "PASS"` on disk for assert-phase6-ran.rb
# to read as this run's evidence — the same presence-is-not-freshness trap as the
# score document, one level up, and a direct route to an unearned GREEN.
#
# The prior contract is therefore overwritten with an explicit FAIL carrying the
# reason. Visual-verdict keys are preserved (record-visual-check.rb owns them and
# cannot re-derive them), but nothing that could read as passing parity survives.
def die!(code, out_path, reason)
  if File.exist?(out_path)
    prior = (JSON.parse(File.read(out_path)) rescue nil)
    prior = {} unless prior.is_a?(Hash)
    invalid = {
      'ran_at'          => Time.now.utc.iso8601,
      'status'          => 'FAIL',
      'charts_total'    => 0,
      'charts_pass'     => 0,
      'charts_fail'     => 0,
      'finalize_error'  => reason,
      'note'            => 'phase6-parity-domo.rb could not finalize; any previous PASS in this ' \
                           'file has been invalidated so the gate cannot read it as fresh evidence.',
    }
    %w[visual_checked visual_verdict screenshot_path agent_vision visual_similarity].each do |k|
      invalid[k] = prior[k] if prior.key?(k)
    end
    File.write(out_path, JSON.pretty_generate(invalid))
    warn "       invalidated the prior #{File.basename(out_path)} (status=FAIL) — it would otherwise " \
         'have been read as this run\'s parity evidence.'
  end
  exit code
end

# ---------------------------------------------------------------------------
# 1. Census FIRST — fail before spending a parity run on a narrowed plan.
# ---------------------------------------------------------------------------
plan_raw    = load_json(opts[:plan])
plan_charts = plan_raw.is_a?(Hash) ? (plan_raw['charts'] || []) : Array(plan_raw)
plan_names  = plan_charts.map { |c| c['chart'].to_s }.reject(&:empty?)

census = nil
if File.exist?(opts[:spec])
  # Workbook elements are document-global in the released representation;
  # pages are metadata-only and layout owns page membership. CodeRep accepts
  # both the released envelope and legacy page-nested fixtures.
  raw_spec = load_json(opts[:spec])
  normalized_spec = DomoSigma::WorkbookCode.normalized_document(raw_spec)
  chartable_names = Sigma::CodeRep.workbook_elements(normalized_spec)
                    .select { |el| chartable?(el) }
                    .map { |el| element_name(el) }

  excluded = []
  if File.exist?(opts[:excl])
    doc = load_json(opts[:excl])
    excluded = (doc.is_a?(Hash) ? (doc['exclusions'] || []) : Array(doc))
    reasonless = excluded.select { |e| !e.is_a?(Hash) || e['reason'].to_s.strip.empty? }
    unless reasonless.empty?
      warn '[FAIL] phase6-parity-domo: exclusion(s) with no reason in ' \
           "#{opts[:excl]} — an excluded tile must say WHY:"
      reasonless.each do |e|
        warn "         - #{(e.is_a?(Hash) ? e['chart'] : e).to_s.empty? ? '(unnamed)' : e['chart']}"
      end
      warn '       A reason is REQUIRED so the exclusion lands in the migration report'
      warn '       instead of quietly shrinking the parity denominator.'
      die!(5, opts[:out], "exclusion(s) with no reason in #{File.basename(opts[:excl])}")
    end
  end
  excluded_names = excluded.map { |e| e['chart'].to_s }

  # MULTISET comparison, deliberately not `chartable_names - plan_names`.
  # Ruby's Array#- is SET difference: it removes EVERY occurrence of a matching
  # value. Two chartable elements sharing a name (the same KPI title repeated on
  # two pages is routine) and a plan verifying only ONE of them therefore came out
  # as fully accounted — exactly the silent inflation this census exists to catch.
  # Counting per name closes that: a name verified 1x but chartable 2x leaves a
  # deficit of 1. Hand-rolled because Array#tally is Ruby 2.7+ and the system
  # ruby here is 2.6.
  def tally(arr)
    arr.each_with_object(Hash.new(0)) { |x, h| h[x] += 1 }
  end
  chartable_tally = tally(chartable_names)
  accounted_tally = tally(plan_names + excluded_names)
  unaccounted = []
  chartable_tally.each do |name, want|
    deficit = want - accounted_tally.fetch(name, 0)
    deficit.times { unaccounted << name } if deficit.positive?
  end
  # A plan/exclusion naming something the workbook has no chartable element for is
  # not fatal (a renamed or removed tile), but it means the denominator and the
  # plan disagree, so say so rather than absorbing it silently.
  stray = accounted_tally.keys - chartable_tally.keys
  warn "[WARN] phase6-parity-domo: #{stray.length} plan/exclusion entr(ies) match no chartable " \
       "element: #{stray.join(', ')}" unless stray.empty?

  census = {
    'chartable_total' => chartable_names.length,
    'plan_total'      => plan_names.length,
    'excluded_total'  => excluded_names.length,
    'unaccounted'     => unaccounted,
    'stray_entries'   => stray,
    'source'          => File.basename(opts[:spec]),
  }

  unless unaccounted.empty?
    warn "[FAIL] phase6-parity-domo: #{unaccounted.length} chartable element(s) are neither " \
         'verified nor excluded:'
    unaccounted.each { |n| warn "         - #{n}" }
    warn "       chartable=#{chartable_names.length}  in plan=#{plan_names.length}  " \
         "excluded=#{excluded_names.length}"
    warn '       A plan narrowed to the easy tiles reports "100% (n/n)" and reads exactly like a'
    warn '       full pass. Either verify these, or record each in'
    warn "       #{opts[:excl]} as {\"chart\":\"<name>\",\"reason\":\"<why>\"}."
    die!(5, opts[:out], "#{unaccounted.length} chartable element(s) neither verified nor excluded: #{unaccounted.join(', ')}")
  end
  warn "census: #{census['chartable_total']} chartable, #{census['plan_total']} verified, " \
       "#{census['excluded_total']} excluded — balanced"
elsif opts[:allow_missing_census]
  warn "[WAIVED] phase6-parity-domo: no #{opts[:spec]} — anti-inflation census SKIPPED by explicit " \
       "request: #{opts[:allow_missing_census]}"
  warn '          This waiver MUST be named in the migration report: the parity denominator was NOT verified.'
else
  # Fail closed. A bare [WARN] here silently voided the whole anti-inflation
  # guarantee for any invocation that did not happen to have workbook-spec.json
  # beside it — and this script documents standalone use, so that is reachable.
  # An unverifiable denominator is now a NAMED decision, never a default.
  warn "[FAIL] phase6-parity-domo: no #{opts[:spec]} — cannot verify the parity denominator."
  warn '       Without it, a plan narrowed to the easy tiles reports "100% (n/n)" and reads exactly'
  warn '       like a full pass, which is the failure mode this census exists to prevent.'
  warn '       Pass --workbook-spec PATH, or, if the spec is genuinely unavailable, waive it'
  warn '       explicitly with --allow-missing-census "<reason>" (recorded in parity-final.json).'
  die!(5, opts[:out], "no #{File.basename(opts[:spec])} — parity denominator unverifiable")
end

# ---------------------------------------------------------------------------
# 2. Run verify-parity.rb for the per-tile score document.
# ---------------------------------------------------------------------------
unless opts[:skip_verify]
  vp = File.expand_path('verify-parity.rb', __dir__)
  abort("phase6-parity-domo: #{vp} not found") unless File.exist?(vp)
  # Remove any prior score document FIRST, so "the file exists afterwards" can
  # only mean "this invocation wrote it".
  #
  # verify-parity.rb exits non-zero on a genuine divergence, so its exit code
  # cannot distinguish a finding from a crash, and the crash check below is
  # presence-of-file. But migrate-domo.rb is idempotent and re-runs into an
  # ALREADY-POPULATED workdir as the normal path — so a verify-parity that
  # aborted (e.g. its own missing-requested-column guard) left the PREVIOUS
  # run's score on disk, which was then finalized into a fresh-timestamped PASS.
  # Presence is not freshness.
  File.delete(opts[:score_out]) if File.exist?(opts[:score_out])
  argv = ['ruby', vp, '--plan', opts[:plan], '--score-out', opts[:score_out]]
  argv << '--extract-mode' if opts[:extract_mode]
  out, err, _st = Open3.capture3(*argv)
  # A non-zero exit here is EXPECTED when tiles diverge — the divergence is the
  # finding, not an error. Only a missing score document is fatal.
  warn out unless out.to_s.strip.empty?
  warn err unless err.to_s.strip.empty?
end

unless File.exist?(opts[:score_out])
  warn "[FAIL] phase6-parity-domo: verify-parity.rb wrote no #{opts[:score_out]} — it crashed " \
       'rather than reporting a divergence. Fix that before finalizing; do NOT hand-author the score.'
  die!(6, opts[:out], 'verify-parity.rb wrote no score document (it crashed)')
end
score = load_json(opts[:score_out])
tiles = Array(score['tiles'])

# ---------------------------------------------------------------------------
# 3. Derive the gate contract.
# ---------------------------------------------------------------------------
# PENDING tiles (render-verify fallback) are unresolved, not divergent — they
# block PASS but are reported separately, as tableau's finalizer does.
pending_names = tiles.select { |t| t['status'].to_s == 'PENDING' }.map { |t| t['chart'].to_s }
pass_names    = tiles.select { |t| t['status'].to_s == 'PASS' }.map { |t| t['chart'].to_s }
fail_names    = tiles.reject { |t| %w[PASS PENDING].include?(t['status'].to_s) }
                     .map { |t| t['chart'].to_s }
total = tiles.length

summary = {
  'workbook_id'      => opts[:wb],
  'ran_at'           => Time.now.utc.iso8601,
  'mode'             => score['mode'] || 'strict',
  # Domo values come from Domo.query_dataset aggregations diffed against live
  # Sigma element exports — a genuine source comparison, so the gate's
  # warehouse-only honesty banner does not apply.
  'verified_against' => 'source',
  'charts_total'     => total,
  'charts_pass'      => pass_names.length,
  'charts_fail'      => fail_names.length,
  'pass_names'       => pass_names,
  'fail_names'       => fail_names,
  'status'           => (total.positive? && fail_names.empty? && pending_names.empty?) ? 'PASS' : 'FAIL',
}
unless pending_names.empty?
  summary['charts_pending_manual'] = pending_names.length
  summary['pending_names']         = pending_names
end
# Fold the value score through so gate 1 --min-parity-score has something to
# read (it fails closed when value_parity_score is absent).
summary['value_parity_score'] = score['value_parity_score']
summary['per_tile_scores']    = tiles
# Deliberately NOT the key `tile_census`. The shared gate's gate 5 reads
# summary['tile_census'] and, whenever it is present, pulls tableau's ZONE-census
# keys out of it (zones_total / charts_built / zones_unmatched /
# unmatched_zone_names — assert-phase6-ran.rb:1637-1640). Publishing a
# differently-shaped document under that name turned gate 5's honest
# "[SKIP] no tile_census" into an always-true "[OK] ... 0 zones, 0 unmatched":
# a gate that had been abstaining started reporting success it had not measured.
# domo builds no dashboard zone tree, so SKIP is the truthful answer, and this
# census lives under its own key.
summary['parity_tile_census'] = census if census
summary['census_waiver']      = opts[:allow_missing_census] if opts[:allow_missing_census]
if census && census['excluded_total'].to_i.positive?
  doc = load_json(opts[:excl])
  summary['excluded_with_reason'] = (doc.is_a?(Hash) ? (doc['exclusions'] || []) : Array(doc))
end

# record-visual-check.rb merges its verdict INTO parity-final.json; never clobber
# a verdict that is already recorded (same doctrine as tableau preserving
# tile_census across a finalize-only invocation).
if File.exist?(opts[:out])
  prior = (JSON.parse(File.read(opts[:out])) rescue nil)
  if prior.is_a?(Hash)
    %w[visual_checked visual_verdict screenshot_path agent_vision visual_similarity].each do |k|
      summary[k] = prior[k] if prior.key?(k)
    end
  end
end

File.write(opts[:out], JSON.pretty_generate(summary))
warn "wrote #{opts[:out]} (status=#{summary['status']} #{summary['charts_pass']}/#{summary['charts_total']}" \
     "#{pending_names.empty? ? '' : ", #{pending_names.length} pending"})"
exit 0
