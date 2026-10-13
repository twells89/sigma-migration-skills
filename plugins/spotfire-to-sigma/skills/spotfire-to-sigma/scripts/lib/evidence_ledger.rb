# frozen_string_literal: true
#
# EvidenceLedger — the append-only per-run evidence ledger (PLAN-v4 E3.1).
#
# WHY. Gate verdicts used to live only in stdout and in per-gate artifacts that
# later invocations rewrite, so a re-run could silently repeat expensive live
# verification (exports, probes, renders) — or worse, a fresh context could
# re-trust nothing and re-pay everything. The ledger is ONE JSONL trail,
# <WORK>/evidence-ledger.jsonl, that every gate verdict appends to:
#
#   { "gate":          "<gate name — e.g. '7b', '13', '21', 'phase6-gates'>",
#     "verdict":       "pass" | "fail" | "waived" | "skip" | <verdict string>,
#     "evidence_kind": "<what backs it — 'anchors-verdict', 'probe-results',
#                        'kind-parity', 'export-cache', 'gate-exit', ...>",
#     "evidence_path": "<workdir-relative path of the RAW evidence artifact>",
#     "evidence_key":  "<version-keyed identity — see .key below>",
#     "evidence_sha256": "<sha of the raw artifact at record time, when bound>",
#     "detail":        { ... optional per-entry facts ... },
#     "at":            "<ISO8601 UTC>" }
#
# It is the substrate factory-mode's punch-list consumes (what failed, what was
# waived, where the raw proof lives) and the acceptance record for #7's
# recorded-evidence reuse.
#
# THE #7 RED LINE (reconciled program, binding): recorded evidence reuse is
# version-keyed RAW evidence only — a verifier NEVER consumes a recorded
# builder VERDICT. This lib enforces its half mechanically: `fresh?` vouches
# only that a RAW artifact is still identity-bound (same strict
# (workbookId, latestDocumentVersion[, elementId]) key, young enough, byte-
# identical to the recorded sha). It deliberately has NO API that answers
# "did this gate pass?" — callers that accept fresh recorded evidence MUST
# recompute their verdict from the raw artifact bytes.
#
# Local-state contract: the ledger lives in the RUN WORKDIR (a /tmp workdir,
# outside any repo), is machine-local, and is never committed anywhere.
#
# Append-only discipline: stdlib File.open(..., 'a') one-line writes (atomic
# on POSIX for short lines), never rewritten, never re-sorted. Malformed lines
# are skipped on read (counted, not fatal) — a torn write must not brick the
# substrate.
#
# assert-phase6-ran.rb carries an inline fallback appender for checkouts where
# this lib is not vendored — keep the line schema in lockstep with it.

require 'json'
require 'digest'
require 'time'

module EvidenceLedger
  FILE = 'evidence-ledger.jsonl'

  # Default freshness window for recorded-evidence reuse (#7d): the repo-speed
  # audit's acceptance rule — recorded raw evidence older than this is
  # re-collected, never trusted (B4: "age <30 min, same workbook version").
  DEFAULT_MAX_AGE_S = 30 * 60

  module_function

  def path(workdir)
    File.join(workdir, FILE)
  end

  # The strict version-keyed identity (#7 red line): every reusable piece of
  # raw evidence is bound to (workbookId, latestDocumentVersion) — and to the
  # elementId when it is element-scoped. Any new POST/PUT bumps the document
  # version, so a stale key can never match live state. An unknown version
  # renders as "v?" — which `fresh?` refuses to match (fail-closed).
  def key(workbook_id:, doc_version:, element_id: nil)
    k = "wb:#{workbook_id}@v#{doc_version.nil? || doc_version.to_s.empty? ? '?' : doc_version}"
    element_id ? "#{k}/el:#{element_id}" : k
  end

  # Append one verdict line. Returns the entry Hash (nil on write failure —
  # ledger bookkeeping must never fail a gate).
  def append(workdir, gate:, verdict:, evidence_kind: nil, evidence_path: nil,
             evidence_key: nil, evidence_sha256: nil, detail: nil, at: Time.now)
    entry = { 'gate' => gate.to_s, 'verdict' => verdict.to_s }
    entry['evidence_kind']   = evidence_kind.to_s unless evidence_kind.nil?
    entry['evidence_path']   = evidence_path.to_s unless evidence_path.nil?
    entry['evidence_key']    = evidence_key.to_s unless evidence_key.nil?
    entry['evidence_sha256'] = evidence_sha256.to_s unless evidence_sha256.nil?
    entry['detail']          = detail if detail.is_a?(Hash) && !detail.empty?
    entry['at'] = at.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    File.open(path(workdir), 'a') { |f| f.puts(JSON.generate(entry)) }
    entry
  rescue StandardError
    nil
  end

  # Read every well-formed entry, oldest first. Malformed lines are skipped
  # (their count is available via read_with_skips).
  def read(workdir)
    read_with_skips(workdir).first
  end

  def read_with_skips(workdir)
    p = path(workdir)
    return [[], 0] unless File.exist?(p)
    skipped = 0
    entries = File.readlines(p).map do |ln|
      next nil if ln.strip.empty?
      e = (JSON.parse(ln) rescue nil)
      skipped += 1 if e.nil?
      e.is_a?(Hash) ? e : nil
    end.compact
    [entries, skipped]
  rescue StandardError
    [[], 0]
  end

  # Most recent entry for a gate (optionally narrowed by evidence_kind and by
  # a caller predicate over the entry). The predicate exists for #7d's
  # anti-chaining rule: an acceptance run re-records its recomputed verdict
  # with detail.recorded_reuse=true and at:=now, so a caller measuring the
  # freshness window MUST anchor on the ORIGINAL collection entry (skip reuse
  # re-appends) — otherwise back-to-back re-runs each reset the age bound and
  # one probe's evidence extends forever.
  def latest(workdir, gate:, evidence_kind: nil)
    read(workdir).reverse_each.find do |e|
      e['gate'] == gate.to_s &&
        (evidence_kind.nil? || e['evidence_kind'] == evidence_kind.to_s) &&
        (!block_given? || yield(e))
    end
  end

  def sha256_file(path)
    File.exist?(path) ? Digest::SHA256.hexdigest(File.binread(path)) : nil
  end

  # RAW-evidence freshness check (#7d) — the ONLY reuse question this lib
  # answers. TRUE iff the recorded entry still identifies live raw evidence:
  #   * strict identity  — entry's evidence_key == the caller's CURRENT
  #     version-keyed identity (a "v?" on either side never matches);
  #   * young enough     — recorded `at` within max_age_s of now;
  #   * byte-bound       — when the entry recorded an evidence_sha256, the
  #     artifact on disk still hashes to it (a swapped/tampered file fails).
  # It says NOTHING about pass/fail: recompute the verdict from the raw bytes.
  def fresh?(entry, evidence_key:, workdir: nil, max_age_s: DEFAULT_MAX_AGE_S, now: Time.now)
    return false unless entry.is_a?(Hash)
    k = entry['evidence_key'].to_s
    return false if k.empty? || k.include?('@v?') || evidence_key.to_s.include?('@v?')
    return false unless k == evidence_key.to_s
    at = (Time.parse(entry['at'].to_s) rescue nil)
    return false if at.nil? || (now - at) > max_age_s || (now - at) < 0
    if entry['evidence_sha256'] && workdir
      ep = entry['evidence_path'].to_s
      abs = ep.start_with?('/') ? ep : File.join(workdir, ep)
      return false unless sha256_file(abs) == entry['evidence_sha256']
    end
    true
  end
end
