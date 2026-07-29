# frozen_string_literal: true
#
# run_state.rb — the per-run phase LEDGER for migrate-domo.rb.
#
# Structure borrowed (not copied — trimmed to this skill's phase set) from
# tableau-to-sigma's scripts/lib/run_state.rb: as migrate-domo.rb walks its
# phase chain it stamps run-state.json, so a re-run or an edited orchestration
# that silently dropped a phase can be told apart from a deliberate, reasoned
# skip (e.g. --offline skipping the live/private-API phases). A phase stamped
# "skip" always carries a `note` explaining WHY — never a silent omission.
#
# run-state.json shape:
#   { "tool": "domo-to-sigma",
#     "phases": {
#       "discover":            { "status": "skip", "note": "offline: seeded from fixture ...", "ts": "..." },
#       "build-workbook":      { "status": "done", "ts": "..." },
#       "build-workbook-spec": { "status": "done", "note": "offline-local assembly (no live DM readback)", "ts": "..." },
#       ... } }

require 'json'
require 'time'

module DomoRunState
  def self.path(workdir)
    File.join(workdir, 'run-state.json')
  end

  def self.load(workdir)
    p = path(workdir)
    return { 'tool' => 'domo-to-sigma', 'phases' => {} } unless File.exist?(p)
    doc = JSON.parse(File.read(p))
    doc['phases'] ||= {}
    doc
  rescue JSON::ParserError
    { 'tool' => 'domo-to-sigma', 'phases' => {} }
  end

  # Record a phase. status: 'done' | 'skip' | 'fail'. Best-effort — a ledger
  # write must never crash the migration; failures are swallowed.
  def self.stamp(workdir, phase, status: 'done', note: nil)
    return unless workdir && File.directory?(workdir)
    doc = load(workdir)
    doc['phases'][phase.to_s] = { 'status' => status, 'note' => note,
                                  'ts' => Time.now.utc.iso8601 }.compact
    File.write(path(workdir), JSON.pretty_generate(doc) + "\n")
  rescue StandardError
    nil
  end

  def self.skip(workdir, phase, reason)
    stamp(workdir, phase, status: 'skip', note: reason)
  end

  def self.fail(workdir, phase, reason)
    stamp(workdir, phase, status: 'fail', note: reason)
  end

  # Record TOP-LEVEL run facts (not phases) — e.g. run mode / tier.
  def self.record(workdir, fields)
    return unless workdir && File.directory?(workdir)
    doc = load(workdir)
    fields.each { |k, v| doc[k.to_s] = v }
    File.write(path(workdir), JSON.pretty_generate(doc) + "\n")
  rescue StandardError
    nil
  end

  # Which of the required phase keys have NO entry at all (neither done, skip,
  # nor fail). Returns [] when everything required is accounted for.
  def self.missing(workdir, required)
    phases = load(workdir)['phases']
    required.reject { |k| phases.key?(k.to_s) }
  end

  def self.tracked?(workdir)
    File.exist?(path(workdir))
  end
end
