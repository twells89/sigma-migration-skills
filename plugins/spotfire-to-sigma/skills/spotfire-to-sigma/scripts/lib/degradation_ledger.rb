# frozen_string_literal: true
#
# DegradationLedger — cumulative-degradation accounting → the PARTIAL verdict
# (PLAN-v3 PR-14, the honesty capstone).
#
# WHY: a migration can pass every hard gate and still ship LESS than the source
# — a dropped tile behind --allow-missing-tiles, a dropped control behind a
# controls-waivers.json entry, a column the coverage census recorded as lost,
# a --skip-* flag that quietly turned a verification off. Each degradation is
# individually recorded somewhere, but nothing ever ADDED THEM UP — so a field
# run once reported "GREEN, 0 waivers" after a --skip-ref-check and dropped
# columns. This module derives ONE ledger from the workdir's artifacts and one
# verdict from the ledger:
#
#   GREEN   — the ledger is EMPTY. No scope cuts, no quality waivers, no
#             recorded escapes, no fidelity residuals, no waived resolutions.
#   YELLOW  — quality degradations but no scope cut (any non-scope-cut entry;
#             a budget-exceeded run — assert-phase6-ran exit 19, existing
#             doctrine unchanged — is always at least YELLOW).
#   PARTIAL — ANY scope-cut entry (a dropped tile / column / control /
#             DM element), regardless of the waiver budget. A scope cut caps
#             the verdict: the delivered workbook is a subset of the source.
#   PARTIAL+YELLOW — both (scope cuts AND quality degradations); PARTIAL is
#             the dominant verdict, YELLOW is noted.
#
# DERIVATION IS MECHANICAL — every entry comes from an artifact on disk that
# some script recorded at decision time; nothing here accepts self-reported
# claims. verify-complete.rb re-derives the ledger offline and FAILS when the
# final report's claims (verdict / waiver census) contradict it — the
# anti-"0 waivers" mechanism.
#
# Entry shape (stable):
#   { "class" => scope-cut | quality-waiver | recorded-escape |
#                fidelity-residual | resolution-waived,
#     "item"            => <what was degraded — tile/column/control/flag name>,
#     "reason"          => <the recorded reason, or a stated default>,
#     "source_artifact" => <file the entry was derived from> }
#
# Artifact classes read (all optional; absent file → no entries):
#   scope-cut         — coverage.json (dropped/degraded visuals+columns),
#                       parity-final.json tile_census unmatched zones (minus
#                       visual-verify oracle matches — gate 5's own logic),
#                       *-controls-coverage.json non-emitted signals with their
#                       control-scope.json / controls-waivers.json explanations
#                       (or those two files directly when no census exists),
#                       deferred-elements.json (quarantined DM elements).
#   quality-waiver    — parity-final.json `waivers` census (stamped by
#                       assert-phase6-ran on every run), minus the POLICY
#                       exclusion (--skip-visual-comparison under the
#                       sanctioned /verifier/i split) and minus flags
#                       reclassified below; plus column-scan.json
#                       skipped-* statuses (gate 3/7's runtime auto-skips —
#                       ruzs: an unaudited workbook must never keep GREEN).
#   recorded-escape   — offramps.jsonl escape kinds (cred/doctor/tableau gate
#                       waivers, stale-skill, degraded fast path, and the
#                       PR-14 `skip-flag-waived` records every closed --skip-*
#                       straggler now writes), plus the census' run off-ramp
#                       flags (--force-new-workbook / --force-route-switch /
#                       --allow-manual-spec).
#   fidelity-residual — parity-final.json visual_verdict=divergent, unresolved
#                       fidelity-ledger.json deltas (accepted residuals ride
#                       to DONE unresolved), layout-arrangement.json
#                       violations (advisory WARNs), png-read.json
#                       kind_waivers (recorded chart-family substitutions).
#   resolution-waived — lod-audit.json / join-plan.json resolutions with
#                       how=waived, agg-semantics.json how=faithful-to-source
#                       (a documented source hazard shipping as-is),
#                       manual-residues.json entries still unbuilt,
#                       source-anchors.json + ground-truth-plan.json
#                       coverage_waivers (tiles no numeric oracle watched).
#
# Canonical: shared/lib/degradation_ledger.rb — edit there and run
# tools/sync-shared.rb. Ruby 2.6-compatible, stdlib-only, fully offline.

require 'json'

module DegradationLedger
  VERSION = 1
  CLASSES = %w[scope-cut quality-waiver recorded-escape fidelity-residual
               resolution-waived].freeze

  # Census policy exclusion (assert-phase6-ran budget doctrine): the
  # visual-comparison hand-off to a verifier session is excluded from the
  # quality-waiver census only when its recorded reason matches /verifier/i
  # (handled inline in quality_waivers).
  # Census flags that are run OFF-RAMPS, not gate-quality waivers — classed
  # recorded-escape (they were honored by a script mid-run, mirrored into the
  # census by the budget code).
  CENSUS_ESCAPE_FLAGS = ['--force-new-workbook', '--force-route-switch',
                         '--allow-manual-spec'].freeze
  # Census flags whose degradation is derived (better) from an artifact —
  # skipped in the census pass so one degradation never counts twice:
  # visual-divergent is derived from parity-final's visual_verdict.
  CENSUS_DERIVED_FLAGS = ['visual-divergent'].freeze

  # offramps.jsonl kinds that are ESCAPES (a verification/protection turned
  # off) as opposed to observability records (pass1-stop, workbook-handoff,
  # loop-stop, …). force-new-workbook / route-switch-forced / manual-spec are
  # deliberately absent: the census already mirrors them (see above).
  ESCAPE_OFFRAMP_KINDS = %w[cred-gate-waived doctor-gate-waived
                            tableau-gate-waived stale-skill-waived
                            degraded-fastpath skip-flag-waived].freeze

  module_function

  def ledger_path(workdir)
    File.join(workdir, 'degradation-ledger.json')
  end

  # Derive the full ledger (Array of entry Hashes) from the workdir's
  # artifacts. Deterministic: same files → same entries, same order.
  # Dedupe is by the FULL entry (class, item, reason, source) — the reason must
  # participate: coverage.json legitimately records several distinct degraded
  # rows under one generic `visual` label (field-observed: three "field/calc"
  # header-fallback rows for three different tiles, distinguishable only by
  # their detail), and an item-only key silently swallowed all but the first.
  def derive(workdir)
    entries = []
    entries.concat(scope_cuts(workdir))
    entries.concat(quality_waivers(workdir))
    entries.concat(column_scan_skips(workdir))
    entries.concat(recorded_escapes(workdir))
    entries.concat(fidelity_residuals(workdir))
    entries.concat(resolution_waived(workdir))
    entries.uniq { |e| [e['class'], e['item'], e['reason'], e['source_artifact']] }
  end

  # Write <workdir>/degradation-ledger.json (entries + per-class counts).
  # Never raises — bookkeeping must not sink a gate run.
  def write(workdir, entries)
    counts = Hash.new(0)
    entries.each { |e| counts[e['class']] += 1 }
    File.write(ledger_path(workdir),
               JSON.pretty_generate('version' => VERSION,
                                    'derivedAt' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                                    'counts' => counts,
                                    'entries' => entries))
    true
  rescue StandardError
    false
  end

  # The verdict string. Any scope cut → PARTIAL (dominant); any other entry —
  # or a budget-exceeded run — → YELLOW; both → "PARTIAL+YELLOW"; empty ledger
  # and budget intact → GREEN. GREEN requires an EMPTY ledger, full stop.
  def verdict(entries, budget_exceeded: false)
    partial = entries.any? { |e| e['class'] == 'scope-cut' }
    yellow  = budget_exceeded || entries.any? { |e| e['class'] != 'scope-cut' }
    return 'PARTIAL+YELLOW' if partial && yellow
    return 'PARTIAL' if partial
    return 'YELLOW' if yellow
    'GREEN'
  end

  # One line per entry, for inline printing under the verdict.
  def report_lines(entries)
    entries.map do |e|
      "  - [#{e['class']}] #{e['item']} — #{e['reason']} (#{e['source_artifact']})"
    end
  end

  # ── class derivations ──────────────────────────────────────────────────────

  def scope_cuts(wd)
    out = []
    # coverage.json — the build-step drop census: severity 'dropped' is a tile
    # that produced NO Sigma element; 'degraded' built but LOST a column/field.
    cov = read_json(wd, 'coverage.json')
    Array(cov.is_a?(Hash) ? cov['unresolved'] : nil).each do |u|
      next unless u.is_a?(Hash) && %w[dropped degraded].include?(u['severity'].to_s)
      what = u['severity'].to_s == 'dropped' ? 'dropped visual' : 'degraded visual (lost column/field)'
      out << entry('scope-cut', "#{what}: #{u['visual']}",
                   u['detail'].to_s.empty? ? u['severity'].to_s : u['detail'].to_s,
                   'coverage.json')
    end
    # tile census — unmatched dashboard zones (gate 5), minus zones the
    # visual-verify oracle confirmed (same subtraction gate 5 applies).
    pf = read_json(wd, 'parity-final.json')
    census = pf.is_a?(Hash) ? pf['tile_census'] : nil
    if census.is_a?(Hash)
      names = Array(census['unmatched_zone_names']).map(&:to_s)
      vv = read_json(wd, File.join('visual-verify', 'manifest.json'))
      vv_ok = Array(vv).select { |t| t.is_a?(Hash) && t['visual_verified'] == true }
                       .map { |t| t['worksheet'].to_s }
      (names - vv_ok).each do |n|
        out << entry('scope-cut', "dropped tile: #{n}",
                     'source dashboard zone with no matching chart (tile census)',
                     'parity-final.json tile_census')
      end
    end
    # controls — the source-vs-built census names every signal; a non-emitted
    # row is a control the user had that the migration did not build. Its
    # explanation (control-scope drop record / controls-waivers reason) rides
    # into the entry; without a census the declaration files stand alone.
    dropped_notes = control_scope_drops(wd)
    ctl_waivers = controls_waivers(wd)
    ctl_census_path = Dir[File.join(wd, '*-controls-coverage.json')].min
    seen_controls = []
    if ctl_census_path
      doc = read_json_path(ctl_census_path)
      Array(doc.is_a?(Hash) ? doc['detail'] : nil).each do |r|
        next unless r.is_a?(Hash) && r['status'].to_s != 'emitted'
        name = r['name'].to_s
        key = norm(name)
        reason = dropped_notes[key] ||
                 (ctl_waivers[key] || ctl_waivers[norm("#{r['kind']}:#{name}")]) ||
                 "census status: #{r['status']}"
        seen_controls << key << norm("#{r['kind']}:#{name}")
        out << entry('scope-cut', "dropped control: #{r['kind']}:#{name}", reason,
                     File.basename(ctl_census_path))
      end
    end
    dropped_notes.each do |key, reason|
      next if seen_controls.include?(key)
      out << entry('scope-cut', "dropped control: #{key}", reason, 'control-scope.json')
    end
    ctl_waivers.each do |key, reason|
      next if seen_controls.include?(key) || dropped_notes.key?(key)
      out << entry('scope-cut', "dropped control: #{key}", reason, 'controls-waivers.json')
    end
    # deferred-elements.json — DM elements quarantined at POST time; a
    # non-empty file at DONE means the PARTIAL data model was accepted.
    dd = read_json(wd, 'deferred-elements.json')
    deferred = dd.is_a?(Hash) ? Array(dd['deferred']) : (dd.is_a?(Array) ? dd : [])
    deferred.each do |el|
      name = el.is_a?(Hash) ? (el['name'] || el['id'] || 'unnamed element') : el.to_s
      out << entry('scope-cut', "dropped DM element: #{name}",
                   'quarantined at DM POST (deferred-elements.json still non-empty)',
                   'deferred-elements.json')
    end
    out
  end

  def quality_waivers(wd)
    pf = read_json(wd, 'parity-final.json')
    return [] unless pf.is_a?(Hash) && pf['waivers'].is_a?(Array)
    reasons = pf['waiver_reasons'].is_a?(Hash) ? pf['waiver_reasons'] : {}
    # waivers.json carries {flag, gate, reason} for gates waived via
    # record_waiver — a second reason source for older parity-final stamps.
    wj = read_json(wd, 'waivers.json')
    wj = wj['waivers'] if wj.is_a?(Hash)
    Array(wj).each do |w|
      next unless w.is_a?(Hash) && w['flag']
      reasons[w['flag'].to_s] ||= w['reason'].to_s unless w['reason'].to_s.empty?
    end
    out = []
    pf['waivers'].map(&:to_s).uniq.each do |flag|
      next if CENSUS_DERIVED_FLAGS.include?(flag)
      next if CENSUS_ESCAPE_FLAGS.include?(flag) # classed recorded-escape below
      next if flag == '--skip-visual-comparison' && reasons[flag].to_s =~ /verifier/i
      reason = reasons[flag].to_s
      reason = 'budget-counted quality waiver (no reason recorded)' if reason.empty?
      out << entry('quality-waiver', flag, reason, 'parity-final.json waivers')
    end
    out
  end

  # Gate 3/7's runtime auto-skips (ruzs): column-scan.json is stamped by
  # assert-phase6-ran at audit time — complete-clean is positive evidence and
  # derives nothing; a skipped-* status means the live column audit NEVER
  # verified the workbook, which is the same degradation class as an operator
  # --skip-column-check (quality-waiver → verdict at most YELLOW). Kept
  # separate from the census: these skips are runtime conditions, not flags,
  # so they must not depend on the waiver census having been stamped.
  def column_scan_skips(wd)
    scan = read_json(wd, 'column-scan.json')
    return [] unless scan.is_a?(Hash) && scan['status'].to_s.start_with?('skipped-')
    reason = scan['reason'].to_s
    reason = scan['status'].to_s if reason.empty?
    detail = scan['columns_read'] ? " (#{scan['columns_read']} column(s) read before the stop)" : ''
    [entry('quality-waiver', 'gate-3-column-scan',
           "live column type=error audit #{scan['status']}: #{reason}#{detail}",
           'column-scan.json')]
  end

  def recorded_escapes(wd)
    out = []
    # Census-mirrored run off-ramps (they also spend waiver budget there).
    pf = read_json(wd, 'parity-final.json')
    census = pf.is_a?(Hash) ? Array(pf['waivers']).map(&:to_s) : []
    (census & CENSUS_ESCAPE_FLAGS).each do |flag|
      out << entry('recorded-escape', flag, 'run off-ramp honored mid-run (see offramps.jsonl)',
                   'parity-final.json waivers')
    end
    # offramps.jsonl escape kinds — including the PR-14 skip-flag-waived
    # records that make every --skip-* visible (the --skip-ref-check fix).
    trail(wd).each do |r|
      next unless ESCAPE_OFFRAMP_KINDS.include?(r['kind'].to_s)
      item = r['kind'].to_s == 'skip-flag-waived' && !r['detail'].to_s.empty? ? r['detail'].to_s : r['kind'].to_s
      reason = r['reason'].to_s.empty? ? 'NO REASON GIVEN' : r['reason'].to_s
      out << entry('recorded-escape', item, reason, 'offramps.jsonl')
    end
    out.uniq { |e| [e['item'], e['reason']] }
  end

  def fidelity_residuals(wd)
    out = []
    pf = read_json(wd, 'parity-final.json')
    if pf.is_a?(Hash) && pf['visual_verdict'].to_s == 'divergent'
      out << entry('fidelity-residual', 'visual verdict: divergent',
                   'recorded source-vs-target visual gaps ship in the render',
                   'parity-final.json')
    end
    fl = read_json(wd, 'fidelity-ledger.json')
    Array(fl.is_a?(Hash) ? fl['entries'] : nil).each do |e|
      next unless e.is_a?(Hash) && !e['resolved']
      out << entry('fidelity-residual',
                   "RCF residual #{e['id']} [#{e['dimension'] || e['cls']}]",
                   e['delta'].to_s.empty? ? "unresolved #{e['cls']} delta" : e['delta'].to_s,
                   'fidelity-ledger.json')
    end
    arr = read_json(wd, 'layout-arrangement.json')
    Array(arr.is_a?(Hash) ? arr['pages'] : nil).each do |p|
      next unless p.is_a?(Hash)
      Array(p['violations']).each do |v|
        out << entry('fidelity-residual', "arrangement: #{p['page']}", v.to_s,
                     'layout-arrangement.json')
      end
    end
    pr = read_json(wd, 'png-read.json')
    Array(pr.is_a?(Hash) ? pr['kind_waivers'] : nil).each do |w|
      next unless w.is_a?(Hash)
      out << entry('fidelity-residual', "chart-kind substitution: #{w['tile']}",
                   w['reason'].to_s.empty? ? 'recorded at read time' : w['reason'].to_s,
                   'png-read.json kind_waivers')
    end
    out
  end

  def resolution_waived(wd)
    out = []
    { 'lod-audit.json' => %w[waived], 'join-plan.json' => %w[waived],
      'agg-semantics.json' => %w[faithful-to-source] }.each do |file, hows|
      doc = read_json(wd, file)
      list = doc.is_a?(Hash) ? doc['entries'] : doc
      Array(list).each do |e|
        next unless e.is_a?(Hash) && e['resolution'].is_a?(Hash)
        how = e['resolution']['how'].to_s
        next unless hows.include?(how)
        item = e['calc'] || e['name'] ||
               (e['left'] && e['right'] ? "#{e['left']}→#{e['right']}" : nil) ||
               e['column'] || 'entry'
        out << entry('resolution-waived', "#{item} (#{how})",
                     e['resolution']['reason'].to_s.empty? ? 'no reason recorded' : e['resolution']['reason'].to_s,
                     file)
      end
    end
    mr = read_json(wd, 'manual-residues.json')
    mr_list = mr.is_a?(Hash) ? mr['residues'] : mr
    Array(mr_list).each do |e|
      next unless e.is_a?(Hash) && e['status'].to_s == 'unbuilt'
      out << entry('resolution-waived', "unbuilt custom-SQL residue: #{e['calc']}",
                   'accepted unbuilt — its tile renders a magnitude proxy',
                   'manual-residues.json')
    end
    { 'source-anchors.json' => 'no anchor watched this tile',
      'ground-truth-plan.json' => 'no numeric oracle verified this tile' }.each do |file, why|
      doc = read_json(wd, file)
      Array(doc.is_a?(Hash) ? doc['coverage_waivers'] : nil).each do |w|
        next unless w.is_a?(Hash)
        out << entry('resolution-waived', "coverage waiver: #{w['tile']}",
                     "#{why}#{w['reason'].to_s.empty? ? '' : " — #{w['reason']}"}",
                     "#{file} coverage_waivers")
      end
    end
    out
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  def entry(cls, item, reason, source)
    { 'class' => cls, 'item' => item.to_s, 'reason' => reason.to_s,
      'source_artifact' => source.to_s }
  end

  def norm(s)
    s.to_s.strip.downcase
  end

  def control_scope_drops(wd)
    doc = read_json(wd, 'control-scope.json')
    out = {}
    Array(doc.is_a?(Hash) ? doc['dropped'] : nil).each do |d|
      name = d.is_a?(Hash) ? d['name'] : d
      next if name.to_s.strip.empty?
      reason = d.is_a?(Hash) && !d['reason'].to_s.empty? ? d['reason'].to_s : 'dropped — recorded in control-scope.json'
      out[norm(name)] = reason
    end
    out
  end

  def controls_waivers(wd)
    doc = read_json(wd, 'controls-waivers.json')
    doc = doc['waivers'] if doc.is_a?(Hash)
    out = {}
    Array(doc).each do |w|
      next unless w.is_a?(Hash)
      name = w['control'] || w['name']
      next if name.to_s.strip.empty? || w['reason'].to_s.strip.empty?
      out[norm(name)] = "waived: #{w['reason'].to_s.strip}"
    end
    out
  end

  def trail(wd)
    path = File.join(wd, 'offramps.jsonl')
    return [] unless File.exist?(path)
    File.readlines(path).map { |l| JSON.parse(l) rescue nil }.compact
  rescue StandardError
    []
  end

  def read_json(wd, rel)
    read_json_path(File.join(wd, rel))
  end

  def read_json_path(path)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue StandardError
    nil
  end
end
