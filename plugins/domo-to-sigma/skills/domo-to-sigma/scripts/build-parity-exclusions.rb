#!/usr/bin/env ruby
# frozen_string_literal: true
#
# build-parity-exclusions.rb — generate `parity-plan-exclusions.json` for the
# Phase-6 census. Companion to phase6-parity-domo.rb (bead beads-sigma-2tkm).
#
# WHY THIS EXISTS
# ---------------
# phase6-parity-domo.rb REFUSES to emit a gate-1 contract unless every chartable
# element is either verified by the parity plan or recorded here WITH A REASON.
# That check shipped in PR #631; nothing wrote the file it reads. This writes it.
#
# THE CONSTRAINT THAT SHAPES THE WHOLE DESIGN
# -------------------------------------------
# An exclusions generator is itself a potential silent-inflation loophole — the
# exact failure mode the census exists to prevent. Excluding a tile removes it
# from the parity denominator, so a generous generator turns "45 of 65 verified"
# into a clean-looking "100% (45/45)". Three rules keep it honest:
#
#   1. Exclusions derive ONLY from MACHINE FACTS the converter already recorded in
#      warnings.json. No heuristics, no chart-kind guesses, no "probably fine".
#   2. The originating warning text rides along as `evidence`, so every exclusion
#      is auditable back to the line of converter output that justified it.
#   3. A RUNAWAY GUARD: if the derived exclusions would exceed
#      MAX_EXCLUSION_RATE of a non-trivial pool, this ABORTS and tells the
#      operator to fix the converter rather than widen the exclusions. Overriding
#      it requires an explicitly named --accept-exclusion-rate REASON, which is
#      recorded in the artifact.
#
# WHAT ACTUALLY DISQUALIFIES A TILE
# ---------------------------------
# Only warnings that mean "the Domo side and the Sigma side cannot agree by
# construction". Today that is exactly one class: a REFUSED DATE WINDOW. When
# build-workbook.rb declines to translate a card's date window (INTERVAL_OFFSET,
# non-zero offset, unmapped interval — see apply_card_date_window!), Domo
# aggregates over a window and the Sigma tile aggregates over all history. No
# oracle can reconcile that, so scoring the tile would produce a guaranteed
# failure that says nothing about conversion quality.
#
# A layout, geometry, series-assignment or sub-master routing warning is NOT
# grounds for exclusion — those are fidelity concerns whose VALUES should still
# agree, and dropping them would hide real divergence.
#
# Usage:
#   ruby scripts/build-parity-exclusions.rb --workdir <wd> \
#     [--workbook-spec PATH] [--warnings PATH] [--out PATH] \
#     [--max-rate F] [--accept-exclusion-rate REASON]
#
# Exit codes: 0 = written; 1 = bad invocation / missing input;
#             7 = runaway guard tripped (too many exclusions, no named override).
require 'json'
require 'optparse'
require 'time'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'code_rep'

opts = { workdir: nil, spec: nil, warns: nil, out: nil, max_rate: 0.4, accept: nil }
OptionParser.new do |p|
  p.banner = 'Usage: build-parity-exclusions.rb --workdir DIR [options]'
  p.on('--workdir DIR', 'run directory')                                { |v| opts[:workdir] = v }
  p.on('--workbook-spec PATH', 'default <workdir>/workbook-spec.json')  { |v| opts[:spec] = v }
  p.on('--warnings PATH', 'default <workdir>/warnings.json (or discovery/warnings.json)') { |v| opts[:warns] = v }
  p.on('--out PATH', 'default <workdir>/parity-plan-exclusions.json')   { |v| opts[:out] = v }
  p.on('--max-rate F', Float, 'runaway guard: max excluded fraction of the pool (default 0.4)') { |v| opts[:max_rate] = v }
  p.on('--accept-exclusion-rate REASON',
       'override the runaway guard — REQUIRED reason, recorded as rate_waiver and MUST be named ' \
       'in the migration report') { |v| opts[:accept] = v }
end.parse!

abort('build-parity-exclusions: --workdir is required') unless opts[:workdir]
abort("build-parity-exclusions: --workdir #{opts[:workdir]} does not exist") unless Dir.exist?(opts[:workdir])
opts[:spec] ||= File.join(opts[:workdir], 'workbook-spec.json')
opts[:out]  ||= File.join(opts[:workdir], 'parity-plan-exclusions.json')
if opts[:warns].nil?
  cand = [File.join(opts[:workdir], 'warnings.json'),
          File.join(opts[:workdir], 'discovery', 'warnings.json')]
  opts[:warns] = cand.find { |c| File.exist?(c) } || cand.first
end
abort("build-parity-exclusions: no workbook spec at #{opts[:spec]}") unless File.exist?(opts[:spec])

# A rate guard on a tiny pool is meaningless (2 of 3 is not a runaway), so it only
# engages once the pool is big enough for a fraction to mean anything.
MIN_POOL_FOR_RATE_GUARD = 5

# Chartable predicate — behaviourally identical to
# shared/scripts/build-parity-plan.rb:50-57 and phase6-parity-domo.rb, so this
# generator and the census it feeds always agree on the denominator.
SKIP_KIND = /control|^text$|^image$|^button|container|^iframe|^embed|^divider/i
def chartable?(el)
  k = el['kind'].to_s
  return false if k.empty? || k =~ SKIP_KIND
  return false if el['visibleAsSource'] == false
  (el['columns'] || []).any?
end

def element_name(el)
  n = el['name'].is_a?(Hash) ? el['name']['text'] : el['name']
  n = nil if n.to_s.empty?
  (n || el['title'] || el['id']).to_s
end

def load_json(path, default)
  return default unless File.exist?(path)
  JSON.parse(File.read(path))
rescue StandardError => e
  abort("build-parity-exclusions: cannot read #{path}: #{e.message}")
end

# Tile ids follow `el-<cardId>[-summary]` (build-workbook.rb), which is what makes
# a tile joinable to the card-level warning that disqualifies it.
def card_id_of(el_id)
  m = /\Ael-(\d+)/.match(el_id.to_s)
  m && m[1]
end

# The ONLY disqualifying signature today. Keyed on the exact prefix
# apply_card_date_window! emits, so a reworded unrelated warning cannot start
# silently excluding tiles.
DISQUALIFYING = [
  { key: 'date-window-not-applied',
    match: ->(w) { w.include?('date window NOT applied') },
    why: 'Domo applies a date window this converter refused to translate, so the Sigma tile ' \
         'aggregates over all history while the Domo card aggregates over a window — the two ' \
         'cannot agree by construction and scoring it would produce a guaranteed, uninformative ' \
         'failure. Restore the window (see apply_card_date_window!) to score this tile.' },
].freeze

spec  = load_json(opts[:spec], {})
tiles = Sigma::CodeRep.workbook_elements(spec).select { |el| chartable?(el) }

raw = load_json(opts[:warns], [])
warns = raw.is_a?(Array) ? raw : Array(raw['warnings'])

# Group disqualifying warnings by card id, and surface any that cannot be joined.
by_card = {}
unjoinable = []
warns.each do |w|
  text = w['warning'].to_s
  sig = DISQUALIFYING.find { |d| d[:match].call(text) }
  next unless sig
  cid = w['card_id'].to_s
  if cid.empty?
    unjoinable << w
    next
  end
  (by_card[cid] ||= []) << { sig: sig, warning: text, card: w['card'] }
end

unless unjoinable.empty?
  warn "[WARN] build-parity-exclusions: #{unjoinable.length} disqualifying warning(s) carry no " \
       'card_id and could not be joined to a tile — they are NOT excluded, so those tiles will be ' \
       'scored and may fail. Re-run build-workbook.rb (warn_card now records card_id):'
  unjoinable.first(10).each { |w| warn "         - #{w['card']}: #{w['warning'][0, 90]}" }
end

exclusions = []
tiles.each do |el|
  cid = card_id_of(el['id'])
  next unless cid
  hits = by_card[cid]
  next unless hits && !hits.empty?
  hit = hits.first
  exclusions << {
    'chart'    => element_name(el),
    'reason'   => "#{hit[:sig][:key]}: #{hit[:warning]} — #{hit[:sig][:why]}",
    'evidence' => { 'card_id' => cid, 'element_id' => el['id'],
                    'card' => hit[:card], 'warning' => hit[:warning] },
  }
end

total = tiles.length
rate  = total.zero? ? 0.0 : (exclusions.length.to_f / total)
warn format('build-parity-exclusions: %d chartable tile(s), %d excluded (%.1f%%)',
            total, exclusions.length, rate * 100)

if total >= MIN_POOL_FOR_RATE_GUARD && rate > opts[:max_rate] && opts[:accept].nil?
  warn "[FAIL] build-parity-exclusions: would exclude #{exclusions.length} of #{total} tiles " \
       "(#{(rate * 100).round(1)}% > #{(opts[:max_rate] * 100).round(0)}% limit) — too many."
  warn '       Excluding this much of the pool does not measure a conversion, it hides one: the'
  warn '       remaining tiles would score "100%" while most of the dashboard went unverified.'
  warn '       FIX THE CONVERTER instead of widening the exclusions — every entry below names the'
  warn '       warning that caused it:'
  exclusions.first(10).each { |e| warn "         - #{e['chart']}: #{e['evidence']['warning'][0, 90]}" }
  warn '       If the converter fix is genuinely deferred, re-run with'
  warn '       --accept-exclusion-rate "<reason>" and name it in the migration report.'
  exit 7
end

doc = {
  'generated_at'     => Time.now.utc.iso8601,
  'source'           => File.basename(opts[:spec]),
  'chartable_total'  => total,
  'excluded_total'   => exclusions.length,
  'exclusion_rate'   => rate.round(4),
  'note'             => 'Derived ONLY from machine facts recorded in warnings.json; every entry ' \
                        'carries the originating warning as evidence. Never hand-widen this file — ' \
                        'fix the converter so the tile can be scored.',
  'exclusions'       => exclusions,
}
doc['rate_waiver'] = opts[:accept] if opts[:accept]

File.write(opts[:out], JSON.pretty_generate(doc))
warn "wrote #{opts[:out]} (#{exclusions.length} exclusion(s) of #{total} chartable tile(s))"
exit 0
