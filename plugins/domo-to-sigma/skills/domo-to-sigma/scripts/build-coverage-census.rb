#!/usr/bin/env ruby
# frozen_string_literal: true
# build-coverage-census.rb — emit coverage.json: which source cards produced no
# Sigma element.
#
#   ruby scripts/build-coverage-census.rb --workdir <dir> [--out <dir>/coverage.json]
#
# WHY THIS EXISTS — a real hole on the GREEN path, measured 2026-08-07.
#
# assert-phase6-ran.rb's verdict is GREEN only when the degradation ledger is
# EMPTY (shared/lib/degradation_ledger.rb:146-153); ANY scope-cut caps the run at
# PARTIAL. DegradationLedger.scope_cuts derives those from exactly two places:
#
#   coverage.json      'unresolved' entries with severity dropped|degraded
#   parity-final.json  tile_census.unmatched_zone_names   (TABLEAU zone census)
#
# domo can never fill the second: `tile_census` is a RESERVED key holding
# tableau's zone shape, and publishing anything else there turns gate 5's honest
# [SKIP] into a vacuous "[OK] 0 zones, 0 unmatched" — a real regression caught in
# review on PR #631, which is why domo's census correctly publishes under
# `parity_tile_census` instead (see memory gate5-tile-census-key-reserved).
#
# And until now domo emitted NO coverage.json: grep shows the only mentions in
# the skill are the two READERS (assert-phase6-ran.rb, lib/degradation_ledger.rb).
# powerbi and tableau emit one; domo does not. Bead beads-sigma-59mk has tracked
# porting it since 2026-06-25.
#
# NET EFFECT BEFORE THIS SCRIPT: a Domo card that produced no Sigma element was
# invisible to the ledger, so a run that silently dropped cards could still be
# declared GREEN. phase6-parity-domo.rb's census does NOT close this — it counts
# elements in workbook-spec.json against the parity plan, so a card that never
# became an element at all is missing from its denominator too. That is precisely
# the class the whole gate suite exists to prevent.
#
# WHAT IS ASSERTED, AND WHAT DELIBERATELY IS NOT.
#
# `dropped` is COMPUTED, never guessed: a source card whose id has no
# `el-<cardId>` element in the built spec. Element ids embed the card id, so the
# diff is exact, not a name match.
#
# `degraded` (built, but lost a column or field) is NOT emitted. The tempting
# source is warnings.json, which is already card-attributed — but classifying
# free-text warning prose into severities is guesswork, and a fabricated
# `degraded` would cap a run at PARTIAL for a reason nobody can verify. That is
# the same over-claiming this script exists to stop, pointed the other way. Every
# warning is instead carried at severity 'warning', which DegradationLedger
# ignores (it reacts only to dropped|degraded) — recorded for the human report,
# inert to the verdict. Real degraded-detection needs a per-card column census
# and belongs with bead beads-sigma-59mk's full port.
require 'json'
require 'set'
require 'optparse'
require 'time'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'code_rep'

opts = {}
OptionParser.new do |p|
  p.banner = 'Usage: build-coverage-census.rb --workdir DIR [--out PATH]'
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--out PATH', 'default <workdir>/coverage.json') { |v| opts[:out] = v }
  p.on('--spec PATH', 'default <workdir>/workbook-spec.json') { |v| opts[:spec] = v }
  p.on('--cards PATH', 'default <workdir>/discovery/cards.json') { |v| opts[:cards] = v }
  p.on('--warnings PATH', 'default <workdir>/discovery/warnings.json') { |v| opts[:warn] = v }
end.parse!
abort('--workdir required') unless opts[:wd] && Dir.exist?(opts[:wd])
wd = opts[:wd]
spec_path  = opts[:spec]  || File.join(wd, 'workbook-spec.json')
cards_path = opts[:cards] || File.join(wd, 'discovery', 'cards.json')
warn_path  = opts[:warn]  || File.join(wd, 'discovery', 'warnings.json')
out_path   = opts[:out]   || File.join(wd, 'coverage.json')
abort("missing #{spec_path}") unless File.exist?(spec_path)
abort("missing #{cards_path}") unless File.exist?(cards_path)

raw_cards = JSON.parse(File.read(cards_path))
cards = raw_cards.is_a?(Array) ? raw_cards : Array(raw_cards['cards'])
spec = JSON.parse(File.read(spec_path))
elements = Sigma::CodeRep.workbook_elements(spec)

# Every card id that reached the built spec. Element ids are `el-<cardId>` for a
# card's own tile and `el-<cardId>-summary` for its companion KPI, so either
# proves the card was migrated.
built = elements.map { |e| e['id'].to_s[/\Ael-(\d+)/, 1] }.compact.to_set

unresolved = []
cards.each do |c|
  cid = c['id'].to_s
  next if built.include?(cid)
  unresolved << {
    'visual'      => (c['title'] || c['name'] || cid).to_s,
    'card_id'     => cid,
    'severity'    => 'dropped',
    'detail'      => 'source card produced no Sigma element (no el-%s in workbook-spec.json)' % cid,
    'recoverable' => true,
    'action'      => 'inspect discovery/warnings.json and build-workbook.rb for why this card ' \
                     'was skipped; a dropped card is a missing tile, not a cosmetic gap',
  }
end

# Warnings ride along at an inert severity — see the header. They are NOT
# scope-cuts and must not become them without a per-card column census.
if File.exist?(warn_path)
  Array(JSON.parse(File.read(warn_path))).each do |w|
    next unless w.is_a?(Hash)
    unresolved << {
      'visual'      => w['card'].to_s,
      'severity'    => 'warning',
      'detail'      => w['warning'].to_s,
      'recoverable' => false,
    }
  end
end

dropped = unresolved.count { |u| u['severity'] == 'dropped' }
census = {
  'generated_at'   => Time.now.utc.iso8601,
  'source'         => 'domo-to-sigma build-coverage-census.rb',
  'cards_total'    => cards.size,
  'cards_built'    => cards.count { |c| built.include?(c['id'].to_s) },
  'cards_dropped'  => dropped,
  'note'           => 'severity dropped is computed from a card-id diff (element ids embed the ' \
                      'card id). severity degraded is deliberately NOT emitted — see the script ' \
                      'header; warnings are carried at an inert severity the degradation ledger ' \
                      'ignores.',
  'unresolved'     => unresolved,
}
File.write(out_path, JSON.pretty_generate(census))

warn "coverage census → #{out_path}"
warn "  #{census['cards_built']}/#{cards.size} source cards produced a Sigma element"
if dropped.positive?
  warn "  #{dropped} card(s) DROPPED — each becomes a degradation-ledger scope-cut, which caps " \
       'the run at PARTIAL (correctly: a dropped tile is missing migration, not a nit):'
  unresolved.select { |u| u['severity'] == 'dropped' }
            .each { |u| warn "      #{u['card_id']}  #{u['visual']}" }
else
  warn '  no dropped cards'
end
exit 0
