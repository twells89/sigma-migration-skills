# frozen_string_literal: true
#
# FlipGate — pure decision logic for gate 7b (the runtime control flip test).
#
# Gate 7 (control_lint.rb) asserts control wiring against the LIVE spec plus the
# control-scope.json sidecar — but that sidecar is derived by build_workbook.py
# from the SAME `listen` data it used to wire the spec, so a builder-level
# mis-mapping produces a spec and a sidecar that AGREE and gate 7 passes. The
# only independent proof is runtime: flip a control via the REST export API and
# confirm its targets' output actually changes (scripts/probe-controls.rb).
#
# This module turns probe-controls.rb's exit code + parsed probe-results.json
# into a gate verdict. It is pure (no I/O) so the branch logic is unit-testable
# without a live workbook — see the plugin tests/ for coverage.
#
# SHARED lib, vendored byte-identical into every plugin that runs
# assert-phase6-ran.rb (SHA-1 discipline — tools/check-shared.rb).
module FlipGate
  # probe-controls.rb exit codes (see its header):
  #   0 = every auto-probeable control flipped correctly (SKIPs allowed)
  #   1 = at least one FAIL (a control is wired but inert, or a flip leaked)
  #   2 = nothing could be auto-probed (all controls are date-range / slider /
  #       unlabeled types that need an explicit --value)
  #
  # results: the parsed probe-results.json array (or nil if it could not be read
  # — e.g. probe crashed before writing it).
  #
  # Returns [decision, info]:
  #   decision ∈ :ok | :fail | :advisory | :error
  #     :ok       — ≥1 control proven to filter its targets live → gate passes
  #     :fail     — ≥1 control FAILed the flip → gate blocks GREEN (exit 21)
  #     :advisory — no control was auto-probeable → loud WARN + marker, no fail
  #                 (we genuinely cannot flip these types; do not block a
  #                  legitimately date-only dashboard)
  #     :error    — probe could not run / produced no verdict → fail-closed
  #                 (exit 21): an opted-in gate that could not verify must not
  #                 silently pass; re-run or waive with --skip-control-flip
  #   info: { passes:[cid,...], fails:[[cid,note],...], skips:[[cid,note],...] }
  def self.decide(probe_rc, results)
    rows   = results.is_a?(Array) ? results : []
    pick   = ->(name) { rows.select { |r| val(r, 'result').to_s == name } }
    passes = pick.call('PASS')
    fails  = pick.call('FAIL')
    skips  = pick.call('SKIP')
    info = {
      passes: passes.map { |r| val(r, 'control') },
      fails:  fails.map  { |r| [val(r, 'control'), val(r, 'note')] },
      skips:  skips.map  { |r| [val(r, 'control'), val(r, 'note')] }
    }

    decision =
      case probe_rc
      when 1
        # rc==1 with FAIL rows is a real inert/leaky control; rc==1 with none
        # is an abort (bad args, columns fetch failed, …) — could not verify.
        fails.any? ? :fail : :error
      when 0
        passes.any? ? :ok : :advisory
      when 2
        :advisory
      else
        :error
      end
    [decision, info]
  end

  # Read a field from a probe result row whether it was parsed from JSON (string
  # keys) or built in-process (symbol keys).
  def self.val(row, key)
    return nil unless row.is_a?(Hash)
    row[key] || row[key.to_sym]
  end

  # Re-derive probe-controls.rb's exit code from its result ROWS (A6, wave-1
  # review — the gate-7b recorded-evidence acceptance previously consumed the
  # ledger-recorded `probe_rc`, the one datum in that path NOT covered by the
  # probe-results.json sha). The mapping mirrors the script's own exit logic
  # exactly: any FAIL row → 1 (every `failures += 1` there appends a FAIL
  # row); no PASS row either → 2 (nothing reached the flip — probed controls
  # always append PASS or FAIL); else 0. An aborted probe (rc 1 with no FAIL
  # rows) is NOT reproducible from rows alone — it derives to 2/:advisory,
  # which the acceptance path treats as ambiguous and re-probes live: the
  # conservative direction.
  def self.derive_rc(results)
    rows = results.is_a?(Array) ? results : []
    verdicts = rows.map { |r| val(r, 'result').to_s }
    return 1 if verdicts.include?('FAIL')
    return 2 unless verdicts.include?('PASS')
    0
  end
end
