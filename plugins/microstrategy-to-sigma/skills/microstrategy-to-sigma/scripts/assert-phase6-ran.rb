#!/usr/bin/env ruby
# Hard gate that proves a tableau-to-sigma conversion is actually complete.
# The subagent MUST run this script before declaring GREEN. It checks seven
# independent things — failing ANY of them blocks the GREEN declaration:
#
#   1. Phase 6 ran (parity-final.json exists, status=PASS, pass-rate met)
#      → beads-sigma-4pm. Raw-mode: when the source tool is unreachable,
#      verify-warehouse.rb writes parity-final.json with
#      verified_against=warehouse — accepted as PASS but flagged with a loud
#      banner ("verified vs warehouse, NOT source"). intake.json input_mode=file
#      without a warehouse-verified parity triggers an advisory WARN.
#   2. No orphan workbooks left in the customer's My Documents
#      (posted-workbooks.jsonl has ≤1 entry OR cleanup-marker.json shows
#      cleanup ran with no failed deletes)  → beads-sigma-38a
#   3. The live workbook's /columns endpoint shows no column with
#      type=error (catches circular refs / runtime errors introduced
#      AFTER the initial POST's column-type guard ran)  → beads-sigma-38a
#   4. The workbook has a non-empty layout XML applied (catches the
#      "elements just listed in a single column" regression where the
#      agent forgot to PUT a layout)  → beads-sigma-bw3
#   5. Tile census — parity-final.json's `tile_census` field (emitted by the
#      converter's phase6 finalize when a dashboard zone tree is available)
#      shows no unexplained dashboard zones without a matching chart in the
#      parity plan. Catches the "empty view CSV silently dropped a tile and
#      the workbook shipped with N-1 charts" escape (bead gjhe). Skipped
#      (with a note) when the converter doesn't emit a census.
#   6. Layout lint (scripts/lib/layout_lint.rb, shared) — no raw-id element
#      display names, no input controls outside the GridContainer bands on a
#      banded page, no dead zones (>25% empty grid rows between a page's
#      first and last element), no generic header-band title ("Page 1" /
#      "Sheet 3" / "Dashboard 2" must never title a dashboard), and no
#      under-filled band (<60% of the 24 grid columns covered; deliberate
#      KPI bands of <=4 tiles exempt). Catches the "PHASEE PBI Employee
#      Dashboard" visual-mess regression (and its PHASEE2 sequel: "Page 1"
#      header + a lone small chart beside a 19-column hole) that every data
#      gate waved through.
#   7. Control lint (scripts/lib/control_lint.rb, shared) — no dead controls
#      (a control with no resolving `filters` target AND no [controlId]
#      formula reference is furniture: the "Orders Overview (from Looker)"
#      estate shipped three of them), no ghost filter targets, and no control
#      whose source-closure misses same-page queryable elements (the PHASEE
#      "Action(Region) -> Monthly Revenue Trend" escape). Honors the
#      control-scope sidecar (<workdir>/control-scope.json or
#      --control-scope) for source-signal coverage (zero controls built from
#      an interactive source = FAIL, the Qlik class) and per-control
#      scope:[...] allowlists (intentional single-chart switchers like grain
#      controls). See the lib header CONTRACT.
#   7b. Runtime control flip test (OPT-IN via --require-control-flip) — gate 7's
#      control-scope.json sidecar is derived by build_workbook.py from the same
#      `listen` data it used to wire the spec, so a builder-level mis-mapping
#      makes spec and sidecar AGREE and gate 7 passes. This gate proves the
#      wiring INDEPENDENTLY at runtime: scripts/probe-controls.rb flips each
#      auto-probeable control via the REST export API and requires its targets'
#      output to actually change (wired-but-inert = FAIL, exit 21). Offline runs
#      (no creds / no workbook) SKIP. See lib/flip_gate.rb.
#
# Usage:
#   ruby scripts/assert-phase6-ran.rb --tableau /tmp/<name> \
#     [--workbook-id <id>]     # override; default = read from wb-ids.json
#     [--min-pass-rate 1.0]    # default 1.0 (every chart must PASS)
#     [--allow-extract]        # treat extract-mode as acceptable
#     [--skip-column-check]    # skip the live /columns type=error scan
#     [--skip-orphan-check]    # skip the orphan-workbook scan (for callers
#                              # that genuinely want multiple workbooks)
#     [--skip-layout-check]    # skip the layout-applied scan
#     [--skip-layout-lint]     # skip gate 6 (layout-quality lint) — escape
#                              # hatch for legacy workbooks; name the reason
#                              # in your report
#     [--skip-control-lint]    # skip gate 7 (control-wiring lint) — escape
#                              # hatch for legacy workbooks; name the reason
#                              # in your report
#     [--control-scope PATH]   # control-scope.json sidecar for gate 7
#                              # (default: <workdir>/control-scope.json)
#     [--require-control-flip] # gate 7b (OPT-IN): prove control wiring at runtime
#                              # via probe-controls.rb (looker-to-sigma opts in)
#     [--skip-control-flip R]  # waive gate 7b — name the reason in your report
#     [--flip-check-leaks]     # gate 7b: also assert flips don't leak
#                              # (probe --check-out-of-closure; doubles exports)
#     [--min-layout-elements N] default 2 — single-page bare-element layouts
#                              # often have just the page wrapper; require this
#                              # many <LayoutElement> tags
#     [--allow-missing-tiles N] default 0 — tolerate up to N unmatched dashboard
#                              # zones in the tile census (for legitimately
#                              # unbuildable zones; name them in your report)
#
# Exit codes:
#   0  every gate passes — conversion is allowed to declare GREEN
#   1  parity-final.json missing (Phase 6 skipped — the regression case)
#   2  parity-final.json exists but status=FAIL / pass-rate below min /
#      extract-mode without --allow-extract / charts_total==0
#   3  parity-final.json malformed
#   4  orphan workbooks left uncleaned (beads-sigma-38a)
#   5  live workbook has column(s) with type=error (beads-sigma-38a)
#   6  live workbook has no layout applied — single-column fallback
#      (beads-sigma-bw3)
#   7  tile census shows unexplained unmatched dashboard zones beyond
#      --allow-missing-tiles (bead gjhe)
#   8  layout lint violations — raw-id display names / orphan controls /
#      dead zones (gate 6; scripts/lib/layout_lint.rb)
#   9  control lint violations — dead controls / ghost targets / partial
#      reach / source filter signals with zero controls
#      (gate 7; scripts/lib/control_lint.rb)
#  10  Phase 6f visual render missing — no valid Sigma render PNG was produced,
#      so the mandatory full-dashboard visual comparison could not have run
#      ("declared done on HTTP 200" regression; gate 8). Render with
#      scripts/sigma-export-png.py --page <pageId>, Read it against the source
#      dashboard PNG, then re-run. Escape hatch: --skip-visual-gate "<reason>".
#  11  Build-from-signals tile(s) not image-verified (gate 9). Escape hatch:
#      --skip-visual-tiles "<reason>".
#  12  Telemetry consent decision missing — the anonymous usage ping was never
#      sent or declined (no telemetry-sent.json marker; gate 10, delegated to
#      assert-telemetry-ran.rb). Ask the user, then run report-telemetry.py
#      (--declined if they decline). Escape hatch: --skip-telemetry-gate "<reason>".
#  13  Visual comparison not recorded OR not executable (gate 8b) — ENFORCED BY
#      DEFAULT. Two variants, same exit code:
#      (a) a valid render exists but parity-final.json carries no
#          visual_checked/screenshot_path verdict. A structurally-clean workbook
#          can still ship visually empty/wrong, so the source-vs-target
#          comparison is mandatory. Run record-visual-check.rb after reading the
#          rendered page against the source dashboard PNG, then re-run.
#      (b) parity-final.json carries agent_vision=false or
#          visual_verdict="not-executable" (stamped by record-visual-check.rb
#          §D5) — the driving agent could not READ the render, so any verdict is
#          a blind attestation. Re-run the visual loop from a vision-capable
#          session (Claude Code with image input).
#      Escape hatch for both (source image genuinely unobtainable / knowingly
#      accepting an unverified render): --skip-visual-comparison "<reason>".
#  14  Layout fill / grid coverage failed (gate 8c; #259 item 1) — a page in
#      layout-census.json dropped a tile (placed < zones) or ships under-filled
#      (grid_fill_pct < --min-grid-fill, default 0.45), OR a dashboard layout was
#      built but no census was emitted. build-dashboard-layout.rb produces the
#      census. Escape hatch: --skip-layout-fill "<reason>".
#  15  RCF fidelity ledger unresolved (gate 8d; OPT-IN via --require-fidelity-ledger)
#      — the Phase 5g render-compare-fix ledger (fidelity-ledger.json) is missing, or
#      still carries spec-fixable deltas that were never resolved. Run the RCF loop
#      (scripts/fidelity-loop.rb) to convergence, or waive named residuals with
#      --accept-residuals id,id. Only enforced for converters that pass the flag.
#  16  Post-publish interactivity guide missing (gate 11) — the source dashboards
#      carry filter/highlight/nav ACTIONS (dashboard-layout-meta.json worksheets'
#      is_action filters, or the *-gaps-report.json "Dashboard filter / highlight /
#      nav actions" feature) that workbooks-as-code cannot port, and
#      <workdir>/POSTPUBLISH_GUIDE.md does not exist. Run
#      scripts/build-postpublish-guide.rb to generate the user handoff guide.
#      Escape hatch: --skip-postpublish-guide "<reason>".
#  17  Deferred DM elements unresolved (gate 12) — <workdir>/deferred-elements.json
#      is non-empty: post-and-readback.rb --quarantine-on-failure removed broken
#      element(s) at DM POST time to save the rest, so the LIVE data model is
#      PARTIAL. Resolve the deferred elements and re-POST: fix each element spec
#      in the file, restore it into the DM spec, PUT it back (post-and-readback
#      --update-id <dmId>), then delete the file. Escape hatch:
#      --accept-deferred-elements "<reason>" (knowingly shipping a partial DM —
#      name it AND the dropped elements in your migration report).
#  18  Source-anchor value verification failed (gate 13) — the MEASURED value
#      bar. When the workdir carries a source dashboard PNG (the Phase 1d
#      artifact: png-read.json source_png / views/*.png / dashboards/*.png),
#      <workdir>/source-anchors.json MUST exist with >= 5 anchors (printed
#      values transcribed EXACTLY as printed while reading the source image)
#      AND <workdir>/anchors-verdict.json (written by scripts/verify-anchors.rb)
#      must show pass with every anchor checked. A printed source value that
#      appears NOWHERE in the live workbook's element exports means the NUMBERS
#      are wrong — the failure two field migrations shipped behind passing
#      visual verdicts ("$1.8T" rendered where the source printed "18,037B").
#      No source dashboard PNG at all → stated SKIP. Escape hatch:
#      --skip-anchors-gate "<reason>" (counted against the waiver budget).
#      ALSO raised when --skip-parity-gate is passed WITHOUT a passing
#      anchors-verdict.json: waiving parity is now CONDITIONAL — the anchors
#      oracle replaces parity, never nothing.
#  19  Waiver budget exceeded — more than 2 QUALITY waiver/escape flags were
#      passed (--skip-*, --allow-extract, --allow-missing-tiles>0,
#      --min-pass-rate<1, --accept-*). Each waiver is an attestation that a
#      verification could not run; stacking them is how an unverified workbook
#      ships GREEN. GREEN is unavailable on this run regardless of individual
#      escapes — the highest achievable result is YELLOW. Every run stamps
#      `waivers` + `waiver_count` (the full census) into parity-final.json so
#      the report (and any reviewer) sees the count. There is NO escape flag
#      for this cap. Two POLICY exclusions never consume the budget:
#        - --skip-telemetry-gate (consent policy, not workbook quality);
#        - --skip-visual-comparison ONLY under the sanctioned builder→verifier
#          split (its reason references the verifier, matched /verifier/i —
#          the verifier session records the verdict); any other reason counts.
#  20  Visual-similarity floor failed (gate 14) — scripts/visual-similarity.py
#      is present, a source dashboard PNG + Sigma render both exist, and the
#      measured comparison (python3 scripts/visual-similarity.py --source <src>
#      --render <render> --json-out <W>/visual-similarity.json) wrote
#      pass=false. Script absent → gate is invisible; inputs absent → stated
#      SKIP. Escape hatch: --skip-visual-similarity "<reason>" (counted against
#      the waiver budget).
#  21  Runtime control flip test failed (gate 7b; OPT-IN via --require-control-flip)
#      — a control passed the static wiring lint (gate 7) but does NOT actually
#      filter its targets at runtime (wired-but-inert / builder-level listen->
#      column mis-mapping), proven by scripts/probe-controls.rb; OR the probe
#      could not run at all on an opted-in gate (fail-closed). Fix the listen
#      mapping in build_workbook.py + re-PUT, or re-run once the export API is
#      reachable. Un-probeable control types (date-range / slider) are an
#      advisory WARN + control-flip-unverified.json marker, not this failure.
#      Escape hatch: --skip-control-flip "<reason>" (counts against the budget).
#
# DATA-CLASS RCF residuals (part of gate 8d, exit 15, but enforced whenever
# fidelity-ledger.json EXISTS — even without --require-fidelity-ledger): any
# UNRESOLVED ledger entry with class `data` hard-fails. Data-class residuals
# can never be waved through — the numbers are wrong; fix or reclassify with
# evidence. --accept-residuals does NOT apply to data-class ids and there is
# no escape flag.
#
# Prints a per-gate summary to stdout regardless of exit code.

require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require 'rbconfig'

opts = { min_pass_rate: 1.0, allow_extract: false, min_layout_elements: 2,
         allow_missing_tiles: 0, min_parity_score: 0.0, min_grid_fill: 0.45 }
OptionParser.new do |p|
  p.on('--tableau DIR')              { |v| opts[:tab] = v }
  p.on('--workdir DIR', 'alias of --tableau for non-Tableau converters') { |v| opts[:tab] = v }
  p.on('--workbook-id ID')           { |v| opts[:wb] = v }
  p.on('--min-pass-rate F', Float)   { |v| opts[:min_pass_rate] = v }
  p.on('--min-parity-score F', Float, 'gate 1: fail if value_parity_score (mean per-tile, parity-score.json) < F (0..1, default 0 = off)') { |v| opts[:min_parity_score] = v }
  p.on('--allow-extract')            { opts[:allow_extract] = true }
  # These five accept an OPTIONAL reason (kept backward-compatible: a bare flag
  # still works). A skip with no reason is recorded as "NO REASON GIVEN" and
  # logged loudly so a silent bypass can't hide — see record_waiver below.
  p.on('--skip-column-check [REASON]')  { |v| opts[:skip_column] = v || true }
  p.on('--skip-orphan-check [REASON]')  { |v| opts[:skip_orphan] = v || true }
  p.on('--skip-layout-check [REASON]')  { |v| opts[:skip_layout] = v || true }
  p.on('--skip-layout-lint [REASON]')   { |v| opts[:skip_lint] = v || true }
  p.on('--skip-control-lint [REASON]')  { |v| opts[:skip_control_lint] = v || true }
  p.on('--control-scope PATH')       { |v| opts[:control_scope] = v }
  p.on('--require-control-flip', 'gate 7b (OPT-IN, off by default): after control lint, PROVE each auto-probeable control actually filters its targets at runtime via scripts/probe-controls.rb (live REST export flip test). Closes the self-referential-sidecar hole in gate 7. Adopters (looker-to-sigma) pass this; other converters are unaffected until they do.') { opts[:require_control_flip] = true }
  p.on('--skip-control-flip [REASON]', 'waive gate 7b (runtime control flip test) — the reason MUST be named in your migration report.') { |v| opts[:skip_control_flip] = v || true }
  p.on('--flip-check-leaks', 'gate 7b: also run probe --check-out-of-closure (asserts a flip does NOT leak to out-of-closure elements; doubles exports). Off by default.') { opts[:flip_check_leaks] = true }
  p.on('--min-layout-elements N', Integer) { |v| opts[:min_layout_elements] = v }
  p.on('--allow-missing-tiles N', Integer, 'tolerate N unmatched dashboard zones in the tile census') { |v| opts[:allow_missing_tiles] = v }
  p.on('--skip-parity-gate REASON', 'waive gate 1 (Phase 6 source-parity) — REQUIRED reason string. Use ONLY when source parity is genuinely unavailable (e.g. no source workspace/dataset/warehouse access). The reason MUST be named in your migration report.') { |v| opts[:skip_parity] = v }
  p.on('--sigma-render PATH', 'gate 8: path to the rendered Sigma dashboard PNG (default: <workdir>/sigma-render.png; also accepts <workdir>/screenshots/_manifest.json)') { |v| opts[:sigma_render] = v }
  p.on('--skip-visual-gate REASON', 'waive gate 8 (Phase 6f visual render) — REQUIRED reason string. Use ONLY when the workbook genuinely cannot be rendered (e.g. export API unavailable). The reason MUST be named in your migration report.') { |v| opts[:skip_visual] = v }
  p.on('--require-visual-comparison', 'DEPRECATED — gate 8b is now enforced by default; this flag is a no-op kept for back-compat.') { opts[:require_visual_cmp] = true }
  p.on('--skip-visual-comparison REASON', 'waive gate 8b (source-vs-target visual verdict) — REQUIRED reason string. Use ONLY when the source dashboard image is genuinely unobtainable (no source render/export access). The reason MUST be named in your migration report.') { |v| opts[:skip_visual_cmp] = v }
  p.on('--skip-visual-tiles REASON', 'waive gate 9 (build-from-signals tile image-verification) — REQUIRED reason string. The reason MUST be named in your migration report.') { |v| opts[:skip_visual_tiles] = v }
  p.on('--min-grid-fill F', Float, 'gate 8c: minimum per-page grid_fill_pct (0..1, default 0.45) — pages below fail as mostly-empty') { |v| opts[:min_grid_fill] = v }
  p.on('--skip-layout-fill REASON', 'waive gate 8c (layout fill / grid coverage) — REQUIRED reason string. Use ONLY when a sparse/partial page is intentional. The reason MUST be named in your migration report.') { |v| opts[:skip_layout_fill] = v }
  p.on('--skip-telemetry-gate REASON', 'waive gate 10 (telemetry consent decision) — REQUIRED reason string. Use ONLY when the run genuinely cannot prompt (e.g. unattended CI). The reason MUST be named in your migration report.') { |v| opts[:skip_telemetry] = v }
  p.on('--skip-postpublish-guide REASON', 'waive gate 11 (post-publish interactivity guide) — REQUIRED reason string. Use ONLY when the source dashboard actions are genuinely not worth a handoff guide. The reason MUST be named in your migration report.') { |v| opts[:skip_postpublish] = v }
  p.on('--accept-deferred-elements REASON', 'waive gate 12 (deferred/quarantined DM elements) — REQUIRED reason string. Use ONLY when knowingly shipping a PARTIAL data model; the reason AND the dropped elements MUST be named in your migration report.') { |v| opts[:accept_deferred] = v }
  p.on('--require-fidelity-ledger', 'gate 8d (OPT-IN, off by default): require an RCF fidelity-ledger.json (Phase 5g) with zero UNRESOLVED spec-fixable deltas. Adopters (tableau-to-sigma) pass this; other converters are unaffected until they do.') { opts[:require_fidelity] = true }
  p.on('--fidelity-ledger PATH', 'gate 8d: path to the RCF ledger (default: <workdir>/fidelity-ledger.json)') { |v| opts[:fidelity_ledger] = v }
  p.on('--accept-residuals LIST', 'gate 8d: comma-separated ledger entry ids/indices to WAIVE as accepted residuals (name them in the report). Does NOT apply to data-class entries — those must be fixed or reclassified with evidence.') { |v| opts[:accept_residuals] = v.split(',').map(&:strip) }
  p.on('--skip-anchors-gate REASON', 'waive gate 13 (source-anchor value verification) — REQUIRED reason string. Use ONLY when the source image values are genuinely untranscribable. Counted against the waiver budget; name it in your migration report.') { |v| opts[:skip_anchors] = v }
  p.on('--skip-visual-similarity REASON', 'waive gate 14 (measured visual-similarity floor) — REQUIRED reason string. Counted against the waiver budget; name it in your migration report.') { |v| opts[:skip_vsim] = v }
end.parse!
abort('--workdir (or --tableau) required') unless opts[:tab]

# A waived gate must never pass SILENTLY. record_waiver prints a loud banner and
# appends to <workdir>/waivers.json so the migration report (and any future
# check) can see every gate that was bypassed and why. A bare skip (no reason)
# is recorded as "NO REASON GIVEN" — visible, not invisible. (CoCo run wrapped
# up GREEN after silently skipping checks — this makes that impossible.)
waivers = []
record_waiver = lambda do |flag, gate, reason|
  r = (reason.is_a?(String) && !reason.strip.empty?) ? reason.strip : nil
  waivers << { 'flag' => flag, 'gate' => gate, 'reason' => r }
  puts "[SKIP] #{gate} WAIVED via #{flag}#{r ? " (#{r})" : ' — NO REASON GIVEN'}"
  puts "       MUST be named in the migration report#{r ? '' : ' WITH a reason'}; this gate did NOT verify the workbook."
  File.write(File.join(opts[:tab], 'waivers.json'), JSON.pretty_generate(waivers)) rescue nil
end

summary_path = File.join(opts[:tab], 'parity-final.json')

# ── Run-scoped completion sentinel (current run id) ─────────────────────────
# The orchestrator mints a run_id at each PASS-1 start (migrate-state.json /
# run-state.json). phase6-success.json is only valid FOR that run: on exit 0 we
# stamp it with the current id; on ANY failure we delete a success marker left
# by a PREVIOUS run id, so verify-complete.rb can never report DONE off a stale
# marker. Converters without a run_id concept fall back to nil (the marker is
# then deleted on every failure — fail-closed).
current_run_id = begin
  JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))['run_id']
rescue StandardError
  nil
end
current_run_id ||= begin
  JSON.parse(File.read(File.join(opts[:tab], 'run-state.json')))['run_id']
rescue StandardError
  nil
end
at_exit do
  st = $!
  next unless st.is_a?(SystemExit) && !st.success?
  succ = File.join(opts[:tab], 'phase6-success.json')
  next unless File.exist?(succ)
  old_id = (JSON.parse(File.read(succ))['run_id'] rescue nil)
  # Keep a same-run success (a re-run of an already-green run with a failing
  # extra flag must not unmint it); delete anything else — it is stale.
  unless current_run_id && old_id && old_id == current_run_id
    File.delete(succ) rescue nil
    warn "[SENTINEL] stale phase6-success.json (run #{old_id || '?'}) deleted — this run (#{current_run_id || '?'}) FAILED the gate."
  end
end

# ---------------------------------------------------------------------------
# Waiver budget (exit 19). EVERY waiver/escape flag is counted — --skip-*,
# --allow-extract, --allow-missing-tiles>0, --min-pass-rate<1, --accept-* —
# and the census is stamped into parity-final.json (`waivers` + `waiver_count`)
# on EVERY run, pass or fail. More than 2 waivers caps the run below GREEN
# (checked at the end, so individual gate failures still surface first). Waiver
# stacking is how a field run shipped an unverified workbook: each escape was
# individually arguable, and together they waived away the whole value bar.
# ---------------------------------------------------------------------------
WAIVER_BUDGET = 2
WAIVER_HIDES = {
  '--skip-parity-gate'         => 'gate 1: values were never diffed against the source',
  '--min-pass-rate'            => 'gate 1: charts that DIVERGE from the source were accepted',
  '--allow-extract'            => 'gate 1: value drift tolerated (extract mode)',
  '--skip-orphan-check'        => 'gate 2: orphan workbooks may remain in My Documents',
  '--skip-column-check'        => 'gate 3: live type=error columns not scanned',
  '--skip-layout-check'        => 'gate 4: layout-applied never verified on the live workbook',
  '--allow-missing-tiles'      => 'gate 5: source tiles absent from the build were accepted',
  '--skip-layout-lint'         => 'gate 6: layout quality never linted',
  '--skip-control-lint'        => 'gate 7: control wiring never linted',
  '--skip-control-flip'        => 'gate 7b: control wiring never proven at runtime',
  '--skip-visual-gate'         => 'gate 8: no rendered PNG was required',
  '--skip-visual-comparison'   => 'gate 8b: no source-vs-target visual verdict was required',
  '--skip-layout-fill'         => 'gate 8c: dropped/under-filled pages were accepted',
  '--accept-residuals'         => 'gate 8d: named RCF deltas shipped unresolved',
  '--skip-visual-tiles'        => 'gate 9: build-from-signals tiles never image-verified',
  '--skip-telemetry-gate'      => 'gate 10: telemetry consent never decided',
  '--skip-postpublish-guide'   => 'gate 11: interactivity handoff guide not required',
  '--accept-deferred-elements' => 'gate 12: a PARTIAL data model was accepted',
  '--skip-anchors-gate'        => 'gate 13: source-anchor values never verified (the measured value bar)',
  '--skip-visual-similarity'   => 'gate 14: visual-similarity floor never measured',
  # Runtime off-ramps (recorded to <workdir>/offramps.jsonl by the scripts that
  # honored them; counted here so an escape taken MID-RUN spends budget exactly
  # like a gate flag):
  '--force-new-workbook'       => 'run: a prior workbook for this workdir was deliberately orphaned (new POST)',
  '--force-route-switch'       => 'run: the workdir was re-driven via the OTHER route (orchestrated vs manual)',
  '--allow-manual-spec'        => 'run: hand-authored specs / standalone POST with no orchestrator STOP on record'
}.freeze
waiver_flags = []
waiver_flags << '--skip-parity-gate'         if opts[:skip_parity]
waiver_flags << '--min-pass-rate'            if opts[:min_pass_rate] < 1.0
waiver_flags << '--allow-extract'            if opts[:allow_extract]
waiver_flags << '--skip-orphan-check'        if opts[:skip_orphan]
waiver_flags << '--skip-column-check'        if opts[:skip_column]
waiver_flags << '--skip-layout-check'        if opts[:skip_layout]
waiver_flags << '--allow-missing-tiles'      if opts[:allow_missing_tiles].to_i.positive?
waiver_flags << '--skip-layout-lint'         if opts[:skip_lint]
waiver_flags << '--skip-control-lint'        if opts[:skip_control_lint]
waiver_flags << '--skip-control-flip'        if opts[:skip_control_flip] && opts[:require_control_flip]
waiver_flags << '--skip-visual-gate'         if opts[:skip_visual]
waiver_flags << '--skip-visual-comparison'   if opts[:skip_visual_cmp]
waiver_flags << '--skip-layout-fill'         if opts[:skip_layout_fill]
waiver_flags << '--accept-residuals'         if opts[:accept_residuals] && !opts[:accept_residuals].empty?
waiver_flags << '--skip-visual-tiles'        if opts[:skip_visual_tiles]
waiver_flags << '--skip-telemetry-gate'      if opts[:skip_telemetry]
waiver_flags << '--skip-postpublish-guide'   if opts[:skip_postpublish]
waiver_flags << '--accept-deferred-elements' if opts[:accept_deferred]
waiver_flags << '--skip-anchors-gate'        if opts[:skip_anchors]
waiver_flags << '--skip-visual-similarity'   if opts[:skip_vsim]

# Runtime waivers taken MID-RUN (off-ramp trail, offramps.jsonl): a forced new
# workbook, a forced route switch, or an unauthorized manual-spec run each spend
# the same budget as a gate flag — otherwise an escape honored by a SCRIPT would
# be invisible to the cap that exists to stop waiver stacking. Read directly
# (plain JSONL; no lib dependency — this file is shared across plugins). Counted
# once per kind.
begin
  _or_path = File.join(opts[:tab], 'offramps.jsonl')
  if File.exist?(_or_path)
    _or_kinds = File.readlines(_or_path).map { |l| JSON.parse(l) rescue nil }.compact
    waiver_flags << '--force-new-workbook' if _or_kinds.any? { |r| r['kind'] == 'force-new-workbook' } &&
                                              !waiver_flags.include?('--force-new-workbook')
    waiver_flags << '--force-route-switch' if _or_kinds.any? { |r| r['kind'] == 'route-switch-forced' } &&
                                              !waiver_flags.include?('--force-route-switch')
    waiver_flags << '--allow-manual-spec'  if _or_kinds.any? { |r| r['kind'] == 'manual-spec' && r['reason'].to_s.start_with?('waiver:') } &&
                                              !waiver_flags.include?('--allow-manual-spec')
  end
rescue StandardError
  nil # observability only — never sink the gate on trail parsing
end

# QUALITY waivers consume the budget; POLICY waivers never do:
#   - --skip-telemetry-gate is a consent-policy decision, not workbook quality;
#   - --skip-visual-comparison under the sanctioned builder→verifier split
#     (reason references the verifier, /verifier/i) hands the verdict to the
#     verifier session instead of waiving it — any OTHER reason counts.
budget_flags = waiver_flags.reject do |f|
  (f == '--skip-telemetry-gate') ||
    (f == '--skip-visual-comparison' && opts[:skip_visual_cmp].to_s =~ /verifier/i)
end

# Stamp the census into parity-final.json on every run (best-effort — a
# missing/malformed file is gate 1's problem, not the stamp's).
if File.exist?(summary_path)
  begin
    _pf = JSON.parse(File.read(summary_path))
    _pf['waivers'] = waiver_flags
    _pf['waiver_count'] = waiver_flags.length
    # Off-ramp telemetry fields (P2): where did this run defect? route comes from
    # the orchestrator's migrate-state.json ('orchestrated' | 'manual-authorized';
    # null for converters without the concept); manual_path_authorized records an
    # orchestrator STOP token; success_sentinel is stamped false here and flipped
    # true ONLY at the green exit below.
    _pf['route'] = (JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))['route'] rescue nil)
    _pf['manual_path_authorized'] = File.exist?(File.join(opts[:tab], 'manual-path-authorized.json'))
    _pf['success_sentinel'] = false
    File.write(summary_path, JSON.pretty_generate(_pf))
  rescue JSON::ParserError
    nil
  end
end
if waiver_flags.any?
  excluded = waiver_flags - budget_flags
  puts "[WAIVERS] #{waiver_flags.length} waiver/escape flag(s) on this run: #{waiver_flags.join(', ')} — " \
       "#{budget_flags.length} count against the budget of #{WAIVER_BUDGET}" \
       "#{excluded.any? ? " (policy exclusions: #{excluded.join(', ')})" : ''}" \
       ' (exceeding the budget caps the run below GREEN, exit 19)'
end

if opts[:skip_parity]
  # CONDITIONAL waiver: --skip-parity-gate is rejected unless the anchors
  # oracle stands in. Parity can be genuinely unavailable (no source workspace
  # access, dashboard-embedded worksheets with no standalone views) — but "no
  # parity AND no anchors" means the numbers were never measured against the
  # source at all, which is exactly how a wrong-numbers workbook shipped GREEN.
  # The anchors oracle replaces parity, never nothing.
  _av_path = File.join(opts[:tab], 'anchors-verdict.json')
  _av = File.exist?(_av_path) ? (JSON.parse(File.read(_av_path)) rescue nil) : nil
  unless _av.is_a?(Hash) && _av['pass'] == true
    warn '[FAIL] --skip-parity-gate REJECTED — the anchors oracle replaces parity, never nothing.'
    warn "       #{_av.nil? ? "#{_av_path} does not exist" : 'anchors-verdict.json does not show pass'} —"
    warn '       waiving source parity requires the MEASURED value bar to stand in:'
    warn '       1. Transcribe the source dashboard\'s printed values into <workdir>/source-anchors.json'
    warn '          at Phase 1d (EXACTLY as printed; schema: SKILL.md Phase 1d / refs/source-anchors.md).'
    warn "       2. Run: ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id <id>"
    warn '       3. Re-run this gate once anchors-verdict.json shows pass.'
    warn '       (If parity IS obtainable, drop --skip-parity-gate and run Phase 6 instead.)'
    exit 18
  end
  puts "[SKIP] gate 1/7: Phase 6 source-parity WAIVED via --skip-parity-gate (#{opts[:skip_parity]})."
  puts "       Accepted because the anchors oracle stands in: anchors-verdict.json pass " \
       "(#{_av['matched']}/#{_av['checked']} anchors matched)."
  puts '       This waiver MUST be named in the migration report — the workbook was NOT chart-by-chart verified vs the source.'
else
  unless File.exist?(summary_path)
    warn "[FAIL] Phase 6 skipped — #{summary_path} does not exist."
    warn "       Run: ruby scripts/phase6-parity.rb --tableau #{opts[:tab]} --workbook-id <id>"
    warn "       then collect actuals via mcp__sigma-mcp-v2__query and re-run with --finalize."
    warn "       See SKILL.md Phase 6. This is the hard gate (beads-sigma-4pm)."
    warn "       If source parity is genuinely unavailable (no workspace/dataset/warehouse access), waive"
    warn "       with --skip-parity-gate \"<reason>\" and name it in the report — but note the waiver is"
    warn "       CONDITIONAL: it is rejected (exit 18) unless anchors-verdict.json exists and passes"
    warn "       (ruby scripts/verify-anchors.rb). The anchors oracle replaces parity, never nothing."
    exit 1
  end

  begin
    summary = JSON.parse(File.read(summary_path))
  rescue JSON::ParserError => e
    warn "[FAIL] #{summary_path} is malformed JSON: #{e.message}"
    exit 3
  end

  total = summary['charts_total'].to_i
  passed = summary['charts_pass'].to_i
  status = summary['status'].to_s
  mode = summary['mode'].to_s

  if total <= 0
    # ORACLE SUBSTITUTION (not a waiver): a workbook whose every worksheet is
    # dashboard-embedded exports NO standalone view CSVs, so the value-parity
    # pool is legitimately empty. The numbers are still machine-verified when
    # BOTH hold: (a) anchors-verdict.json passes with EVERY source anchor
    # matched against live element exports, and (b) every empty-export tile is
    # image-verified (visual-verify manifest all true). Then the anchors
    # oracle IS the parity evidence — same doctrine as the conditional
    # --skip-parity-gate acceptance, but deterministic, and it burns no waiver
    # budget because nothing is skipped.
    _av = (JSON.parse(File.read(File.join(opts[:tab], 'anchors-verdict.json'))) rescue nil)
    _vv = (JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))) rescue nil)
    _vv_ok = _vv.is_a?(Array) && _vv.any? && _vv.all? { |t| t['visual_verified'] == true }
    if _av && _av['pass'] && _av['checked'].to_i >= 5 && _av['matched'] == _av['checked'] && _vv_ok
      puts "[PASS] gate 2 (value parity): 0 exportable view CSVs (all worksheets dashboard-embedded) — " \
           "the ANCHORS ORACLE stands in: anchors-verdict.json pass " \
           "(#{_av['matched']}/#{_av['checked']} anchors matched) + all #{_vv.size} tile(s) image-verified."
    else
      warn "[FAIL] parity-final.json reports charts_total=#{total} — no charts were verified."
      warn "       This usually means auto-parity-plan.rb matched zero Tableau views."
      warn "       Phase 6 must verify at least one chart to declare GREEN."
      warn '       If every worksheet is dashboard-embedded (no exportable view CSVs), the'
      warn '       anchors oracle can stand in — BOTH must hold:'
      warn "         a) verify-anchors.rb pass with EVERY anchor matched (#{_av ? "currently #{_av['matched']}/#{_av['checked']}" : 'anchors-verdict.json missing'})"
      warn "         b) every visual-verify tile confirmed (#{_vv_ok ? 'ok' : 'incomplete'})"
      exit 2
    end
  end

  if total.positive? && mode == 'extract' && !opts[:allow_extract]
    warn "[FAIL] parity ran in extract-mode but --allow-extract was not passed."
    warn "       Extract-mode permits up to ±#{((summary['extract_tol'] || 0.30) * 100).to_i}% drift —"
    warn "       only acceptable when the source Tableau workbook has hasExtracts=true."
    exit 2
  end

  # (total==0 only reaches here through the anchors-oracle substitution above —
  # there is no rate/status to gate on an empty pool.)
  pass_rate = total.positive? ? passed.to_f / total : 1.0
  # status=PASS requires 100% — when the caller explicitly accepts a lower
  # pass-rate (--min-pass-rate, for honest NAMED divergences like LOD
  # placeholders / cross-grain semantics), the rate is the gate, not the status.
  rate_gate_only = opts[:min_pass_rate] < 1.0
  if total.positive? &&
     (rate_gate_only ? pass_rate < opts[:min_pass_rate] : (status != 'PASS' || pass_rate < opts[:min_pass_rate]))
    warn "[FAIL] parity status=#{status} pass-rate=#{(pass_rate * 100).round(1)}% (#{passed}/#{total})"
    warn "       Required: #{rate_gate_only ? '' : 'status=PASS and '}pass-rate >= #{(opts[:min_pass_rate] * 100).to_i}%"
    if (fail_names = summary['fail_names']) && !fail_names.empty?
      warn "       Failing charts: #{fail_names.join(', ')}"
    end
    if (pending = summary['pending_names']) && !pending.empty?
      warn "       Pending render-verify (pivot CSV export 500/empty fallback): #{pending.join(', ')} —"
      warn '       verify each via render-read or direct SQL, set "render_verified": true on the chart'
      warn '       in parity-plan.json, then re-run phase6-parity.rb --finalize.'
    end
    exit 2
  end

  # Value-parity SCORE gate (bead y9rd.2): the mean per-tile value-fidelity score
  # is a finer signal than pass/fail — a tile can PASS the bucket check yet score
  # low on value drift. When --min-parity-score is set, gate on the real number.
  if opts[:min_parity_score] > 0.0
    vps = summary['value_parity_score']
    if vps.nil?
      warn "[FAIL] --min-parity-score #{opts[:min_parity_score]} requested but parity-final.json has no value_parity_score."
      warn "       Re-run phase6-parity.rb --finalize (it now writes the score via verify-parity --score-out)."
      exit 2
    end
    if vps.to_f < opts[:min_parity_score]
      warn "[FAIL] value-parity score=#{(vps.to_f * 100).round(1)}% < required #{(opts[:min_parity_score] * 100).round(1)}%"
      low = (summary['per_tile_scores'] || []).select { |t| t['score'].to_f < opts[:min_parity_score] }
                                              .sort_by { |t| t['score'].to_f }.first(5)
      low.each { |t| warn format('       %-40s %.0f%% (%s)', t['chart'], t['score'].to_f * 100, t['status']) }
      exit 2
    end
    puts "[OK] gate 1/7: value-parity score=#{(vps.to_f * 100).round(1)}% (>= #{(opts[:min_parity_score] * 100).round(1)}% required)"
  end

  if rate_gate_only && status != 'PASS'
    puts "[OK] gate 1/7: Phase 6 ran — #{passed}/#{total} charts PASS (>= #{(opts[:min_pass_rate] * 100).to_i}% accepted); " \
         "DIVERGING (accepted, must be NAMED in the report): #{(summary['fail_names'] || []).join(', ')}"
  else
    puts "[OK] gate 1/7: Phase 6 ran cleanly — #{passed}/#{total} charts PASS (mode=#{mode}, status=#{status})"
  end

  # Raw-mode honesty banner. When the source tool was unreachable, parity is run
  # against the live Sigma WAREHOUSE (verify-warehouse.rb) instead of the source —
  # every element evaluates against real warehouse data, but the values were NOT
  # diffed against the source tool's rendered output. Surface that loudly so a
  # warehouse-verified run is never mistaken for source parity.
  verified_against = summary['verified_against'].to_s
  if verified_against == 'warehouse'
    puts '     ┌─────────────────────────────────────────────────────────────────────────┐'
    puts '     │ VERIFIED AGAINST THE LIVE SIGMA WAREHOUSE — NOT against the source tool.   │'
    puts '     │ Each element evaluates against real warehouse data; values were NOT diffed │'
    puts '     │ vs the source (it was unreachable). State this in the migration report.    │'
    puts '     └─────────────────────────────────────────────────────────────────────────┘'
  else
    # Advisory only: if intake recorded file-mode (no live source) but parity was
    # not warehouse-verified, the run may be over-claiming source parity.
    intake = (JSON.parse(File.read(File.join(opts[:tab], 'intake.json'))) rescue nil)
    if intake.is_a?(Hash) && intake['input_mode'].to_s == 'file'
      warn '[WARN] gate 1: intake.json records input_mode=file (no live source) but parity-final.json is'
      warn '       not marked verified_against=warehouse. In raw-mode, verify against the warehouse'
      warn '       (ruby scripts/verify-warehouse.rb) so the result is not mistaken for source parity.'
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 2 — orphan workbooks (beads-sigma-38a)
# ---------------------------------------------------------------------------
unless opts[:skip_orphan]
  log = File.join(opts[:tab], 'posted-workbooks.jsonl')
  if File.exist?(log)
    posted = File.readlines(log).map { |l| JSON.parse(l) rescue nil }.compact
    unique_ids = posted.map { |e| e['id'] }.uniq
    if unique_ids.length > 1
      marker_path = File.join(opts[:tab], 'cleanup-marker.json')
      unless File.exist?(marker_path)
        warn "[FAIL] gate 2/7: #{unique_ids.length} workbooks created during this conversion (orphans not cleaned)."
        warn "       posted-workbooks.jsonl entries:"
        unique_ids.each { |id| warn "         - #{id}" }
        warn "       Run: ruby scripts/cleanup-orphan-workbooks.rb --workdir #{opts[:tab]}"
        warn "       See beads-sigma-38a."
        exit 4
      end
      marker = JSON.parse(File.read(marker_path)) rescue {}
      if marker['failed'] && !marker['failed'].empty?
        warn "[FAIL] gate 2/7: cleanup-marker.json reports #{marker['failed'].length} failed delete(s)."
        warn "       Orphan workbooks are still in the customer's My Documents:"
        marker['failed'].each { |f| warn "         - #{f['id']} (HTTP #{f['status']})" }
        exit 4
      end
      if marker['dry_run']
        warn "[FAIL] gate 2/7: cleanup-marker.json is from a --dry-run; orphans were not actually deleted."
        warn "       Re-run cleanup-orphan-workbooks.rb without --dry-run."
        exit 4
      end
      kept = marker['kept'] || '(unknown)'
      deleted = (marker['deleted'] || []).length
      puts "[OK] gate 2/7: orphan cleanup ran — kept #{kept}, deleted #{deleted}"
    else
      puts "[OK] gate 2/7: only one workbook POSTed (#{unique_ids.first}) — no orphan check needed"
    end
  else
    puts "[OK] gate 2/7: posted-workbooks.jsonl missing — assuming no orphans (legacy or external POST flow)"
  end
else
  record_waiver.call('--skip-orphan-check', 'gate 2 (orphan-workbook cleanup)', opts[:skip_orphan])
end

# ---------------------------------------------------------------------------
# Gate 3 — live /columns type=error scan (beads-sigma-38a)
# Catches circular references and runtime errors that the initial post-and-
# readback column-type guard missed because they were introduced by later
# PUTs (layout updates, spec edits during error recovery).
# ---------------------------------------------------------------------------
unless opts[:skip_column]
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end

  if wb_id.nil? || wb_id.empty?
    puts "[SKIP] gate 3/7: no workbook ID resolvable (pass --workbook-id or ensure wb-ids.json exists)"
  else
    base = ENV['SIGMA_BASE_URL']
    tok  = ENV['SIGMA_API_TOKEN']
    if base.nil? || base.empty? || tok.nil? || tok.empty?
      # FAIL CLOSED (field-caught): a hard gate that SKIPS without credentials
      # "passes" on any machine where the env wasn't sourced — the exact way a
      # run ships with unverified live columns. The gate needs the live check.
      warn '[FAIL] gate 3/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — the live column-type check CANNOT run.'
      warn '       Source your env (e.g. `source ~/.sigma-migration/env && eval "$(scripts/get-token.sh)"`)'
      warn '       and re-run this gate. A credential-less run is NOT a passing run.'
      exit 5
    else
      uri = URI("#{base}/v2/workbooks/#{wb_id}/columns")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        cols = (JSON.parse(res.body)['entries'] rescue []) || []
        error_cols = cols.select { |c| c.dig('type', 'type') == 'error' }
        if error_cols.any?
          warn "[FAIL] gate 3/7: live workbook #{wb_id} has #{error_cols.length} column(s) with type=error."
          warn "       These render as visible errors in the Sigma UI (circular ref, unknown column,"
          warn "       unsupported function, etc.). Fix the offending formulas and re-PUT before declaring GREEN."
          error_cols.first(10).each do |c|
            warn "         element=#{c['elementId']} col=#{c['columnId']} label=#{c['label'].inspect}"
            warn "           formula: #{c['formula']}"
          end
          warn "       See beads-sigma-38a."
          exit 5
        end
        puts "[OK] gate 3/7: #{cols.length} live columns clean (no type=error)"
      else
        warn "[SKIP] gate 3/7: GET /v2/workbooks/#{wb_id}/columns returned HTTP #{res.code} — cannot verify"
      end
    end
  end
else
  record_waiver.call('--skip-column-check', 'gate 3 (live column type=error scan)', opts[:skip_column])
end

# ---------------------------------------------------------------------------
# Gate 4 — layout applied (beads-sigma-bw3)
# Fetches the live workbook spec and confirms a non-empty top-level `layout`
# XML is set, with at least --min-layout-elements <LayoutElement> tags.
# Catches the "agent forgot to PUT a layout" regression where elements
# render as a single-column stack instead of the dashboard grid.
# ---------------------------------------------------------------------------
# Live positioned-element count from gate 4's spec fetch — reused by gate 8c to
# reconcile a stale zone-derived census against a hand-authored layout. nil when
# gate 4 was skipped / no token.
live_layout_positioned = nil
unless opts[:skip_layout]
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end

  if wb_id.nil? || wb_id.empty?
    puts "[SKIP] gate 4/7: no workbook ID resolvable for layout check"
  else
    base = ENV['SIGMA_BASE_URL']
    tok  = ENV['SIGMA_API_TOKEN']
    if base.nil? || base.empty? || tok.nil? || tok.empty?
      # FAIL CLOSED — same doctrine as gate 3/7: no credentials, no live layout
      # verification, no pass.
      warn '[FAIL] gate 4/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — the live layout check CANNOT run.'
      warn '       Source your env and re-run this gate. A credential-less run is NOT a passing run.'
      exit 6
    else
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        body = res.body.to_s
        spec =
          begin
            JSON.parse(body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(body, permitted_classes: [Date, Time]) || {}
          end
        layout_xml = spec['layout'].to_s
        elem_count = layout_xml.scan(/<LayoutElement\b/).length
        live_layout_positioned = elem_count

        # Detect the Sigma "auto-generated single-column stack" layout that
        # the server produces when a workbook is POSTed without a layout.
        # Signature: every non-Data page has all its elements at the same
        # gridColumn value (typically "1 / 13" — left half, vertically stacked).
        # Note: per-page detection — a workbook with one element per content
        # page is structurally fine (degenerate case, not a stack).
        # Container-banded pages (<GridContainer> bands per layout-playbook.md)
        # are exempt: full-width band containers (and single-chart rows inside
        # them) legitimately share gridColumn="1 / 25" — that is deliberate
        # banding, not the auto-stack regression.
        non_data_stack_pages = []
        # Walk one page at a time using the <Page id="..."> blocks
        layout_xml.scan(/<Page\b[^>]*id="([^"]*)"[^>]*>(.*?)<\/Page>/m).each do |page_id, page_body|
          next if page_id.to_s.downcase.include?('data')
          next if page_body.include?('<GridContainer')
          cols_on_page = page_body.scan(/gridColumn="([^"]+)"/).map(&:first).uniq
          elems_on_page = page_body.scan(/<LayoutElement\b/).length
          if elems_on_page >= 2 && cols_on_page.length == 1
            non_data_stack_pages << [page_id, cols_on_page.first, elems_on_page]
          end
        end

        if layout_xml.empty?
          warn "[FAIL] gate 4/7: live workbook #{wb_id} has NO top-level layout XML."
          warn "       Elements render as a single-column stack instead of the"
          warn "       dashboard grid. Rebuild the layout with this skill's layout"
          warn "       builder (see SKILL.md — layout phase) into #{opts[:tab]}/layout.xml,"
          warn "       then PUT it:"
          warn "         ruby scripts/put-layout.rb --workbook #{wb_id} \\"
          warn "           --layout #{opts[:tab]}/layout.xml"
          warn "       See beads-sigma-bw3."
          exit 6
        elsif elem_count < opts[:min_layout_elements]
          warn "[FAIL] gate 4/7: layout XML has only #{elem_count} <LayoutElement> tag(s);"
          warn "       at least #{opts[:min_layout_elements]} required (one master + ≥1 chart)."
          warn "       The layout likely covers only the Data page — chart page is unstyled."
          exit 6
        elsif non_data_stack_pages.any?
          warn "[FAIL] gate 4/7: live workbook #{wb_id} has Sigma's auto-generated"
          warn "       single-column stack layout (multiple elements at the same gridColumn"
          warn "       on a non-Data page). This is what Sigma defaults to when you POST"
          warn "       a workbook without a layout — exactly the CoCo regression."
          non_data_stack_pages.each do |pid, col, n|
            warn "         page=#{pid.inspect}: #{n} elements all at gridColumn=#{col.inspect}"
          end
          warn "       Rebuild the layout with this skill's layout builder (see SKILL.md —"
          warn "       layout phase) into #{opts[:tab]}/layout.xml, then PUT it:"
          warn "         ruby scripts/put-layout.rb --workbook #{wb_id} --layout #{opts[:tab]}/layout.xml"
          warn "       See beads-sigma-bw3."
          exit 6
        else
          puts "[OK] gate 4/7: layout XML applied with #{elem_count} positioned element(s)"
        end
      else
        warn "[SKIP] gate 4/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot verify"
      end
    end
  end
else
  record_waiver.call('--skip-layout-check', 'gate 4 (top-level layout applied)', opts[:skip_layout])
end

# ---------------------------------------------------------------------------
# Gate 5 — tile census (bead gjhe)
# parity-final.json's `tile_census` field compares the source dashboard's
# chart-zone count against the charts that made it into the parity plan.
# Catches the empty-view-CSV escape where the builder silently emits N-1
# charts and parity still reports PASS (every chart it knows about passes —
# it just doesn't know about the dropped one).
# ---------------------------------------------------------------------------
census = summary && summary['tile_census']  # summary is nil when gate 1 was waived
if census.nil?
  puts "[SKIP] gate 5/7: no tile_census in parity-final.json (converter did not emit one — re-run phase6 finalize with the dashboard zone tree available to enable)"
else
  zones     = census['zones_total'].to_i
  built     = census['charts_built'].to_i
  unmatched = census['zones_unmatched'].to_i
  names     = Array(census['unmatched_zone_names'])
  # The census keys on the PARITY PLAN's matched charts — empty for a workbook
  # whose worksheets are all dashboard-embedded (no standalone views), which
  # flags every zone "unmatched" even though each chart was BUILT and
  # image-verified. Count a zone as matched when its tile carries a confirmed
  # visual-verify entry (the per-tile side-by-side oracle) — deterministic,
  # per-name, and loud below.
  _vv_ok = begin
    Array(JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))))
      .select { |t| t['visual_verified'] == true }.map { |t| t['worksheet'].to_s }
  rescue StandardError
    []
  end
  oracle_matched = names & _vv_ok
  if oracle_matched.any?
    names -= oracle_matched
    unmatched = names.size
    puts "[OK] gate 5/7: #{oracle_matched.size} zone(s) matched via the image-verification oracle " \
         "(no standalone view in the parity plan; visual-verify confirmed): #{oracle_matched.join(', ')}"
  end
  if unmatched > opts[:allow_missing_tiles]
    warn "[FAIL] gate 5/7: tile census — #{zones} dashboard zone(s), #{built} chart(s) built, #{unmatched} unmatched:"
    names.each { |n| warn "         - #{n}" }
    warn "       A zone that rendered in the source dashboard has NO matching chart in the"
    warn "       parity plan. Common causes: empty/0-byte view CSV silently dropped the tile"
    warn "       (re-fetch the view data and rebuild), or the tile was renamed without"
    warn "       passing --rename to phase6-parity.rb / build-dashboard-layout.rb."
    warn "       If #{unmatched} zone(s) are legitimately unbuildable, re-run with"
    warn "       --allow-missing-tiles #{unmatched} and name them in your report. Bead gjhe."
    exit 7
  elsif unmatched > 0
    puts "[OK] gate 5/7: tile census — #{zones} zones, #{built} charts built, #{unmatched} unmatched (within --allow-missing-tiles #{opts[:allow_missing_tiles]}): #{names.join(', ')}"
  else
    puts "[OK] gate 5/7: tile census — #{zones} zones, #{built} charts built, 0 unmatched"
  end
end

# ---------------------------------------------------------------------------
# Gate 6 — layout-quality lint (scripts/lib/layout_lint.rb, shared)
# A workbook can pass every data gate above and still ship as a visual mess:
# raw element ids as chart titles, controls dumped loose at the page foot,
# dead zones between elements (the "PHASEE PBI Employee Dashboard" escape).
# This gate mechanizes those checks on the LIVE spec.
# ---------------------------------------------------------------------------
if opts[:skip_lint]
  record_waiver.call('--skip-layout-lint', 'gate 6 (layout-quality lint)', opts[:skip_lint])
else
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end
  base = ENV['SIGMA_BASE_URL']
  tok  = ENV['SIGMA_API_TOKEN']
  if wb_id.nil? || wb_id.to_s.empty?
    puts "[SKIP] gate 6/7: no workbook ID resolvable for layout lint"
  elsif base.nil? || base.empty? || tok.nil? || tok.empty?
    warn "[SKIP] gate 6/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch spec"
  else
    begin
      require_relative 'lib/layout_lint'
    rescue LoadError
      warn "[SKIP] gate 6/7: scripts/lib/layout_lint.rb not vendored in this plugin — re-vendor (md5 discipline)"
    end
    if defined?(LayoutLint)
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
      if res.is_a?(Net::HTTPSuccess)
        spec =
          begin
            JSON.parse(res.body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
          end
        violations = LayoutLint.lint(spec)
        if violations.any?
          warn "[FAIL] gate 6/7: layout lint — #{violations.length} violation(s) on live workbook #{wb_id}:"
          violations.each { |v| warn "         - #{v}" }
          warn "       Fix the spec/layout and re-PUT (raw-id names -> derive human titles;"
          warn "       loose controls -> place into a band/container; dead zones -> re-band the page),"
          warn "       then re-run this gate. Escape hatch (legacy workbooks only): --skip-layout-lint."
          exit 8
        end
        puts '[OK] gate 6/7: layout lint clean (no raw-id names, no orphan controls, no dead zones, ' \
             'no generic header title, no under-filled bands)'
      else
        warn "[SKIP] gate 6/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot lint"
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 7 — control-wiring lint (scripts/lib/control_lint.rb, shared)
# A workbook can pass every gate above and still ship controls that do
# NOTHING (dead controls: no resolving filter target, no [controlId] formula
# reference — the "Orders Overview (from Looker)" estate escape) or controls
# that silently skip same-page charts (the PHASEE "Action(Region) ->
# Monthly Revenue Trend" escape). This gate mechanizes those checks on the
# LIVE spec, plus source-signal coverage when a control-scope sidecar exists
# (zero controls built from an interactive source = FAIL, the Qlik class).
# ---------------------------------------------------------------------------
if opts[:skip_control_lint]
  record_waiver.call('--skip-control-lint', 'gate 7 (control-wiring lint)', opts[:skip_control_lint])
else
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end
  base = ENV['SIGMA_BASE_URL']
  tok  = ENV['SIGMA_API_TOKEN']
  if wb_id.nil? || wb_id.to_s.empty?
    puts "[SKIP] gate 7/7: no workbook ID resolvable for control lint"
  elsif base.nil? || base.empty? || tok.nil? || tok.empty?
    warn "[SKIP] gate 7/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch spec"
  else
    begin
      require_relative 'lib/control_lint'
    rescue LoadError
      warn "[SKIP] gate 7/7: scripts/lib/control_lint.rb not vendored in this plugin — re-vendor (md5 discipline)"
    end
    if defined?(ControlLint)
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
      if res.is_a?(Net::HTTPSuccess)
        spec =
          begin
            JSON.parse(res.body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
          end
        scope_path = opts[:control_scope] || File.join(opts[:tab], 'control-scope.json')
        scope = nil
        if File.exist?(scope_path)
          scope = JSON.parse(File.read(scope_path)) rescue nil
          warn "[WARN] gate 7/7: #{scope_path} is not valid JSON — linting without source scope" if scope.nil?
        end
        violations = ControlLint.lint(spec, scope: scope)
        if violations.any?
          warn "[FAIL] gate 7/7: control lint — #{violations.length} violation(s) on live workbook #{wb_id}:"
          violations.each { |v| warn "         - #{v}" }
          warn "       Fix the control wiring and re-PUT (dead controls -> add filters targets"
          warn "       ({source:{elementId}, columnId}) or remove the control; partial reach ->"
          warn "       wire the uncovered elements or annotate controlScope in control-scope.json;"
          warn "       see scripts/lib/control_lint.rb CONTRACT), then re-run this gate."
          warn "       Flip-test the wiring live with: ruby scripts/probe-controls.rb --workbook-id #{wb_id}"
          warn "       Escape hatch (legacy workbooks only): --skip-control-lint."
          exit 9
        end
        n_controls = ControlLint.controls_report(spec).length
        puts "[OK] gate 7/7: control lint clean (#{n_controls} control(s); no dead controls, no ghost " \
             "targets, full same-page reach#{scope ? ', source scope honored' : ''})"
      else
        warn "[SKIP] gate 7/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot lint"
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 7b — runtime control flip test (exit 21; OPT-IN via --require-control-flip)
# Gate 7 proves control wiring against the LIVE spec + control-scope.json — but
# that sidecar is derived by build_workbook.py from the SAME `listen` data it
# used to wire the spec, so a BUILDER-level mis-mapping yields a spec and a
# sidecar that AGREE and gate 7 passes. The only independent proof is runtime:
# flip a control via the REST export API and confirm its targets' output
# actually changes. This gate shells out to scripts/probe-controls.rb (which
# already does exactly that) and turns its verdict into a hard gate. Opt-in so
# converters adopt it deliberately (looker-to-sigma passes --require-control-flip);
# offline runs (no creds / no workbook) SKIP, never false-fail. See lib/flip_gate.rb.
# ---------------------------------------------------------------------------
if !opts[:require_control_flip]
  puts '[SKIP] gate 7b: runtime control flip test not opted in (pass --require-control-flip to enable)'
elsif opts[:skip_control_flip]
  record_waiver.call('--skip-control-flip', 'gate 7b (runtime control flip test)', opts[:skip_control_flip])
else
  flip_wb = opts[:wb]
  if flip_wb.nil?
    _p = File.join(opts[:tab], 'wb-ids.json')
    flip_wb = (JSON.parse(File.read(_p))['workbookId'] rescue nil) if File.exist?(_p)
  end
  flip_base = ENV['SIGMA_BASE_URL']
  flip_tok  = ENV['SIGMA_API_TOKEN']
  probe = File.join(__dir__, 'probe-controls.rb')
  if flip_wb.nil? || flip_wb.to_s.empty?
    puts '[SKIP] gate 7b: no workbook ID resolvable for the flip test'
  elsif flip_base.nil? || flip_base.empty? || flip_tok.nil? || flip_tok.empty?
    warn '[SKIP] gate 7b: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot exercise controls'
  elsif !File.exist?(probe)
    warn '[SKIP] gate 7b: scripts/probe-controls.rb not vendored alongside this script — re-vendor (SHA-1 discipline)'
  else
    # Only meaningful when the workbook actually has controls. Reuse gate 7's
    # spec fetch + ControlLint to count them; 0 controls -> nothing to prove.
    begin
      require_relative 'lib/control_lint'
      require_relative 'lib/flip_gate'
    rescue LoadError => e
      warn "[SKIP] gate 7b: #{e.message} — re-vendor scripts/lib (SHA-1 discipline)"
    end
    n_controls = nil
    if defined?(ControlLint) && defined?(FlipGate)
      uri = URI("#{flip_base}/v2/workbooks/#{flip_wb}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{flip_tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
      if res.is_a?(Net::HTTPSuccess)
        spec =
          begin
            JSON.parse(res.body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
          end
        n_controls = ControlLint.controls_report(spec).length
      else
        warn "[SKIP] gate 7b: GET /v2/workbooks/#{flip_wb}/spec returned HTTP #{res.code} — cannot count controls"
      end
    end
    if n_controls == 0
      puts '[OK] gate 7b: workbook has no controls — nothing to flip-test'
    elsif !n_controls.nil?
      out = File.join(opts[:tab], 'probe-controls')
      cmd = [RbConfig.ruby, probe, '--workbook-id', flip_wb, '--out', out]
      cmd << '--check-out-of-closure' if opts[:flip_check_leaks]
      system(*cmd) # inherits stdout — the operator sees the per-control PASS/FAIL/SKIP table
      probe_rc = $?.exitstatus
      results = (JSON.parse(File.read(File.join(out, 'probe-results.json'))) rescue nil)
      decision, info = FlipGate.decide(probe_rc, results)
      case decision
      when :ok
        puts "[OK] gate 7b: #{info[:passes].length} control(s) proven live (in-closure export changes when flipped)" \
             "#{info[:skips].any? ? "; #{info[:skips].length} un-probeable type(s) skipped" : ''}"
      when :fail
        warn "[FAIL] gate 7b: #{info[:fails].length} control(s) wired but INERT on live workbook #{flip_wb}:"
        info[:fails].each { |cid, note| warn "         - #{cid}: #{note}" }
        warn '       The control passed the static lint (gate 7) but does not actually filter its'
        warn '       targets — a builder-level listen->column mis-mapping. Re-check the tile `listen`'
        warn '       mapping in build_workbook.py, re-PUT the spec, then re-run.'
        warn "       Reproduce: ruby scripts/probe-controls.rb --workbook-id #{flip_wb}"
        warn '       Escape hatch: --skip-control-flip "<reason>" (counts against the waiver budget).'
        exit 21
      when :advisory
        warn "[WARN] gate 7b: no control could be auto-flipped (#{info[:skips].length} date-range / slider / " \
             'unlabeled control(s) need an explicit flip value) — runtime wiring is UNVERIFIED.'
        info[:skips].each { |cid, note| warn "         - #{cid}: #{note}" }
        marker = File.join(opts[:tab], 'control-flip-unverified.json')
        File.write(marker, JSON.pretty_generate('workbookId' => flip_wb,
                                                'unprobed' => info[:skips].map { |c, n| { 'control' => c, 'note' => n } })) rescue nil
        warn "       Recorded to #{marker}. Prove them with: ruby scripts/probe-controls.rb --workbook-id " \
             "#{flip_wb} --value <controlId>=<value>  (or waive with --skip-control-flip \"<reason>\")."
      when :error
        warn "[FAIL] gate 7b: probe-controls.rb could not verify the wiring (exit #{probe_rc}) on workbook #{flip_wb}."
        warn '       An opted-in gate that could not run must not pass silently. Re-run once the export'
        warn "       API is reachable: ruby scripts/probe-controls.rb --workbook-id #{flip_wb}"
        warn '       Escape hatch: --skip-control-flip "<reason>" (counts against the waiver budget).'
        exit 21
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 8 — Phase 6f visual render (the "declared done on HTTP 200" regression)
# CSV value parity (gate 1) confirms the DATA matches; it cannot catch a
# visually-broken workbook (dropped log scale, missing labels, overlaps, dead
# zones, wrong chart kind, palette drift). Phase 6f is documented MANDATORY but
# had no machine enforcement, so a conversion could pass every gate above and
# ship without anyone ever rendering — let alone reading — the Sigma PNG.
# This gate requires a VALID render artifact to exist as proof the visual
# comparison could run. It does not (and cannot) verify the human/agent read it
# — but you cannot compare a PNG you never produced.
# ---------------------------------------------------------------------------
# Validated render PNG from gate 8 — reused by gate 14 (visual-similarity
# floor). nil when gate 8 was waived or no render resolved.
render_png = nil
if opts[:skip_visual]
  # BISECT-EVIDENCE demand (field-caught, twice): both rounds of a live test
  # produced a "render outage / persistent 500" waiver that an evaluator's
  # 6-probe bisect refuted in minutes — the poison was the run's OWN content
  # (an unbounded pivot column dimension) and the waiver silently absorbed
  # FOUR visual gates. A 500/timeout reason is only acceptable WITH bisect
  # evidence: the reason must name the playbook's step-1/step-2 probes.
  if opts[:skip_visual] =~ /500|timeout|timed?\s*out|hang|render.*(fail|outage|error)/i &&
     opts[:skip_visual] !~ /bisect|probe/i
    warn '[FAIL] gate 8: --skip-visual-gate cites a render failure but names NO bisect evidence.'
    warn '       A render 500/timeout is usually YOUR workbook content, not the service (an'
    warn '       unbounded pivot dimension has caused this in two independent field runs).'
    warn '       Run the bisect playbook (refs/layout-visual-qa.md "Render 500 / export-timeout'
    warn '       bisect") and re-waive ONLY if step 1 (another workbook fails too) or step 2'
    warn "       (a minimal probe on your DM fails) holds — include e.g. 'bisect: other-workbook"
    warn "       probe also 500s' or 'bisect: isolated to element <id>, verified product limit'"
    warn '       in the reason string.'
    exit 10
  end
  puts "[SKIP] gate 8: Phase 6f visual render WAIVED via --skip-visual-gate (#{opts[:skip_visual]})."
  puts "       This waiver MUST be named in the migration report — the workbook was NOT visually verified."
else
  default_render = File.join(opts[:tab], 'sigma-render.png')
  manifest_path  = File.join(opts[:tab], 'screenshots', '_manifest.json')
  render_path    = opts[:sigma_render] || (File.exist?(default_render) ? default_render : nil)

  # Validate a candidate PNG: real PNG magic bytes + non-trivial size (a blank /
  # error / truncated export is often a few hundred bytes).
  MIN_PNG_BYTES = 5_000
  valid_png = lambda do |path|
    next false unless path && File.file?(path)
    next false unless File.size(path) >= MIN_PNG_BYTES
    File.binread(path, 8) == "\x89PNG\r\n\x1a\n".b
  end

  ok_png = nil
  if valid_png.call(render_path)
    ok_png = render_path
  elsif opts[:sigma_render].nil?
    # The v4 pipeline's own full-page renders: phase 5b visual QA
    # (<workdir>/visual-qa/<dash>.sigma.png) and the phase 5g RCF loop
    # (<workdir>/rcf-pass-N.png). Both ARE live sigma-export-png renders —
    # this gate predates those paths and used to fail runs that had rendered
    # (and compared) the page several times over. Newest first.
    ok_png = (Dir[File.join(opts[:tab], 'visual-qa', '*.sigma.png')] +
              Dir[File.join(opts[:tab], 'rcf-pass-*.png')])
             .select { |p| valid_png.call(p) }.max_by { |p| File.mtime(p) }
  end
  if ok_png.nil? && opts[:sigma_render].nil? && File.exist?(manifest_path)
    # Fall back to the per-element screenshot manifest (export-chart-png.rb):
    # accept if it lists at least one rendered PNG that validates.
    entries = (JSON.parse(File.read(manifest_path)) rescue nil)
    entries = entries.values if entries.is_a?(Hash)
    if entries.is_a?(Array)
      cand = entries.map { |e| e.is_a?(Hash) ? (e['path'] || e['file']) : e }.compact
      ok_png = cand.find { |p| valid_png.call(p) || valid_png.call(File.join(opts[:tab], 'screenshots', File.basename(p.to_s))) }
    end
  end

  if ok_png.nil?
    warn '[FAIL] gate 8: Phase 6f visual render missing — no valid Sigma render PNG found.'
    warn "       Looked for: #{opts[:sigma_render] || default_render}" \
         "#{opts[:sigma_render] ? '' : " (and #{manifest_path})"}"
    warn '       CSV parity passing does NOT mean the workbook renders correctly. Render the full'
    warn '       page and READ it against the source dashboard PNG before declaring done:'
    warn "         python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out #{default_render}"
    warn '       then re-run this gate. See SKILL.md Phase 6f.'
    warn '       Export returning HTTP 500 / timing out? That is usually YOUR workbook content'
    warn '       (e.g. an unbounded pivot dimension from a dropped source rank filter), not the'
    warn '       service — run the bisect playbook in refs/layout-visual-qa.md ("Render 500 /'
    warn '       export-timeout bisect") BEFORE reaching for the escape hatch. Escape hatch'
    warn '       (only with other-workbook probe evidence): --skip-visual-gate "<reason>".'
    exit 10
  end
  size_kb = (File.size(ok_png) / 1024.0).round
  render_png = ok_png
  puts "[OK] gate 8: Phase 6f visual render present (#{ok_png}, #{size_kb} KB) — " \
       'valid PNG produced for source-vs-target comparison'
  # gate 8b — the comparison itself can't be fully mechanized, but we CAN require
  # that a VERDICT was recorded (record-visual-check.rb stamps visual_checked into
  # parity-final.json after the agent reads the rendered page against the source).
  # ENFORCED BY DEFAULT (was opt-in via --require-visual-comparison): a structurally
  # clean workbook can still ship visually empty/wrong (0 error columns, but stacked
  # slivers / missing tiles). "Can't verify" must not equal "passes", so a missing
  # verdict hard-fails unless explicitly waived with a named reason.
  #
  # VISION PRECONDITION (§D5): record-visual-check.rb stamps agent_vision; when the
  # driving agent could not READ the render (agent_vision=false, or the explicit
  # visual_verdict="not-executable"), any recorded verdict — even one carrying a
  # screenshot_path — is a blind attestation, and the gate fails with a NAMED
  # degradation instead of passing on it.
  s = File.exist?(summary_path) ? (JSON.parse(File.read(summary_path)) rescue {}) : {}
  recorded = s['visual_checked'] || s['screenshot_path']
  vision_blocked = (s.key?('agent_vision') && s['agent_vision'] == false) ||
                   s['visual_verdict'].to_s == 'not-executable'
  if vision_blocked
    if opts[:skip_visual_cmp]
      puts "[SKIP] gate 8b: visual gate NOT EXECUTABLE (agent_vision=#{s['agent_vision'].inspect}, " \
           "verdict=#{s['visual_verdict'].inspect}) — WAIVED via --skip-visual-comparison (#{opts[:skip_visual_cmp]})."
      puts '       This waiver MUST be named in the migration report — the render was NEVER read by a vision-capable agent.'
    else
      warn '[FAIL] gate 8b: visual gate not executable — vision-capable agent required.'
      warn "       parity-final.json records agent_vision=#{s['agent_vision'].inspect}" \
           "#{s['visual_verdict'] ? " / visual_verdict=#{s['visual_verdict'].inspect}" : ''}: the driving"
      warn '       agent lacks image input, so it cannot READ the render — any verdict it records is a'
      warn '       blind attestation, never a pass. Re-run the RCF/visual loop from a vision-capable'
      warn '       session (Claude Code with image input), then record the verdict:'
      warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass --notes "..."'
      warn '       Escape hatch (knowingly shipping an unverified render): --skip-visual-comparison "<reason>"'
      warn '       (name it in your migration report).'
      exit 13
    end
  elsif recorded
    # v5.3.1: a PASS verdict must carry the per-dimension STYLE CHECKLIST
    # (round-5: gestalt self-passes shipped renders an exacting owner
    # rejected on all six runs). record-visual-check.rb refuses new passes
    # without one; this catches hand-edited parity-final.json + stale verdicts.
    cl_keys = %w[element_titles_hidden palette_match composition_match
                 chart_shapes_match labels_legible numbers_formatted]
    if s['visual_verdict'].to_s == 'pass' && !opts[:skip_visual_cmp]
      cl = s['style_checklist']
      cl_missing = cl.is_a?(Hash) ? (cl_keys - cl.keys) : cl_keys
      cl_fails = cl.is_a?(Hash) ? cl.select { |k, v2| cl_keys.include?(k) && v2 == 'fail' }.keys : []
      unless cl_missing.empty? && cl_fails.empty?
        warn '[FAIL] gate 8b: visual PASS recorded WITHOUT a complete clean style checklist —'
        warn "       missing: #{cl_missing.join(', ')}" if cl_missing.any?
        warn "       failing: #{cl_fails.join(', ')}" if cl_fails.any?
        warn '       Re-judge the render against the SOURCE image per dimension (layout-visual-qa.md section 1b), then:'
        warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass \\'
        warn "           --checklist \"#{cl_keys.map { |k| "#{k}=pass" }.join(',')}\""
        warn '       (fail on any dimension means the verdict is divergent — fix it first).'
        exit 13
      end
    end
    v = s['visual_verdict'] ? " (#{s['visual_verdict']})" : ''
    av = s.key?('agent_vision') ? ", agent_vision=#{s['agent_vision']}" : ''
    cls = if s['style_checklist'].is_a?(Hash)
            counts = s['style_checklist'].values.each_with_object(Hash.new(0)) { |v2, h| h[v2] += 1 }
            ", style_checklist=#{counts.map { |k, n| "#{n}x#{k}" }.join('/')}"
          else
            ''
          end
    puts "[OK] gate 8b: source-vs-target visual comparison recorded#{v}#{av}#{cls}."
  elsif opts[:skip_visual_cmp]
    puts "[SKIP] gate 8b: source-vs-target visual comparison WAIVED via --skip-visual-comparison (#{opts[:skip_visual_cmp]})."
  else
    warn '[FAIL] gate 8b: parity-final.json records no visual_checked/screenshot_path verdict —'
    warn '       a valid render exists, but nobody confirmed it matches the source dashboard.'
    warn '       Enforced by default: a structurally-clean workbook can still be visually empty/wrong.'
    warn '       Read each rendered page against the source PNG, then run:'
    warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass|divergent --notes "..." \\'
    warn '           --checklist "<six style dimensions - layout-visual-qa.md section 1b>"'
    warn '       then re-run. If the source image is genuinely unobtainable, waive with'
    warn '       --skip-visual-comparison "<reason>" and name it in your migration report.'
    exit 13
  end
end

# ---------------------------------------------------------------------------
# Gate 8c — layout fill / grid coverage (#259 item 1). A workbook can pass
# every structural + visual gate above and still ship a page that is mostly
# empty: tiles silently dropped, or a sparse default stack. build-dashboard-
# layout.rb emits <workdir>/layout-census.json (one record per page: zones /
# placed / dropped / grid_fill_pct). This gate hard-fails when any page dropped
# a tile (placed < zones) OR its grid is under-filled (grid_fill_pct <
# --min-grid-fill, default 0.45).
#
# Absent census: CONDITIONAL fail. If a dashboard layout was built
# (dashboard-layout.json present, or a tile_census landed in parity-final.json)
# but no fill census exists, the gate couldn't run on a page it should have ⇒
# FAIL. When no dashboard layout was built at all — a non-dashboard migration
# or a converter that doesn't emit a census — the gate is N/A ⇒ SKIP (stated,
# never a silent pass).
# ---------------------------------------------------------------------------
census_fill_path = File.join(opts[:tab], 'layout-census.json')
if opts[:skip_layout_fill]
  record_waiver.call('--skip-layout-fill', 'gate 8c (layout fill / grid coverage)', opts[:skip_layout_fill])
elsif File.exist?(census_fill_path)
  doc = JSON.parse(File.read(census_fill_path)) rescue nil
  pages = doc.is_a?(Hash) ? Array(doc['pages']) : (doc.is_a?(Array) ? doc : nil)
  if pages.nil?
    warn "[FAIL] gate 8c: #{census_fill_path} is malformed (expected {\"pages\":[{page,zones,placed,grid_fill_pct}...]})."
    exit 14
  end
  min_fill = opts[:min_grid_fill]
  bad = pages.select { |p| p['placed'].to_i < p['zones'].to_i || p['grid_fill_pct'].to_f < min_fill }
  # Reconcile against the LIVE layout (gate 4 fetched its positioned-element
  # count). A HAND-AUTHORED workbook layout uses element ids the zone-derived
  # census can't match, so build-dashboard-layout.rb reports placed=0/N even
  # though the shipped layout positions every tile. If the live layout has at
  # least as many positioned <LayoutElement> tags as there are source zones,
  # trust it — the census is stale, not the layout. Conservative: only relaxes
  # when the live layout demonstrably covers every zone; never masks a genuine
  # drop when the live layout is actually short.
  total_zones = pages.sum { |p| p['zones'].to_i }
  if bad.any? && live_layout_positioned && total_zones.positive? && live_layout_positioned >= total_zones
    total_placed = pages.sum { |p| p['placed'].to_i }
    puts "[OK] gate 8c: layout-census.json is stale (placed #{total_placed}/#{total_zones}), but the LIVE " \
         "workbook layout positions #{live_layout_positioned} element(s) >= #{total_zones} source zone(s) — " \
         'hand-authored layout reconciled (the zone-derived census could not match its element ids).'
    bad = []
  end
  if bad.any?
    warn "[FAIL] gate 8c: layout fill/coverage — #{bad.length} page(s) dropped tiles or ship under-filled:"
    bad.each do |p|
      reasons = []
      if p['placed'].to_i < p['zones'].to_i
        reasons << "#{p['zones'].to_i - p['placed'].to_i} dropped tile(s) (placed #{p['placed']}/#{p['zones']})"
      end
      reasons << "grid fill #{(p['grid_fill_pct'].to_f * 100).round}% < #{(min_fill * 100).round}%" if p['grid_fill_pct'].to_f < min_fill
      warn "         - #{p['page'].inspect}: #{reasons.join('; ')}"
    end
    warn '       A dropped tile means a source zone never made it into the Sigma layout (empty'
    warn '       view CSV, unhandled rename); an under-filled grid means the page ships mostly'
    warn '       empty. Check build-dashboard-layout.rb WARN lines for dropped/unmatched zones,'
    warn '       rebuild the layout, re-PUT, and re-render. Tune with --min-grid-fill F.'
    warn '       Escape hatch (intentionally sparse page): --skip-layout-fill "<reason>" (name it in your report).'
    exit 14
  end
  puts "[OK] gate 8c: layout fill — #{pages.length} page(s), all tiles placed (no drops), grid fill >= #{(min_fill * 100).round}%"
else
  dash_built = File.exist?(File.join(opts[:tab], 'dashboard-layout.json')) ||
               (defined?(summary) && summary.is_a?(Hash) && summary['tile_census'])
  if dash_built
    warn "[FAIL] gate 8c: a dashboard layout was built but #{census_fill_path} is missing —"
    warn '       the layout fill/coverage gate could not run on a page it should have.'
    warn '       Re-run build-dashboard-layout.rb (it emits layout-census.json beside layout.xml),'
    warn '       then re-run this gate. Escape hatch: --skip-layout-fill "<reason>".'
    exit 14
  else
    puts "[SKIP] gate 8c: no layout-census.json and no dashboard layout built — fill gate N/A"
  end
end

# ---------------------------------------------------------------------------
# Gate 8d — RCF fidelity ledger (OPT-IN via --require-fidelity-ledger; #Phase 5g).
# Structural + value + visual-render + recorded-verdict all passing still leaves
# the composition gap the render-compare-fix loop closes: a workbook can be
# faithful in data yet visibly off-brand (generic palette, wrong chart kind, KPI
# format drift). The loop records each delta into fidelity-ledger.json classified
# spec-fixable | ui-only | sigma-capability | data; only UNRESOLVED spec-fixable
# entries block. Adopters pass --require-fidelity-ledger; other converters skip
# this gate entirely (soft) until they do. Logic mirrors FidelityLoop
# .unresolved_specfixable — inlined here so the shared gate has no cross-plugin dep.
# ---------------------------------------------------------------------------
fl_path = opts[:fidelity_ledger] || File.join(opts[:tab], 'fidelity-ledger.json')
accepted = Array(opts[:accept_residuals]).map(&:to_s)
if opts[:require_fidelity] && !File.exist?(fl_path)
  warn "[FAIL] gate 8d: --require-fidelity-ledger set but #{fl_path} is missing."
  warn '       Run the Phase 5g render-compare-fix loop (scripts/fidelity-loop.rb init/render/record/'
  warn '       apply-patch) to convergence, then re-run. See SKILL.md Phase 5g + refs/fidelity-rubric.md.'
  exit 15
end
ledger = nil
if File.exist?(fl_path)
  ledger = (JSON.parse(File.read(fl_path)) rescue nil)
  if ledger.nil?
    warn "[FAIL] gate 8d: #{fl_path} is malformed JSON."
    exit 15
  end
end
if ledger
  entries = ledger['entries'] || []
  # DATA-CLASS residuals block GREEN whenever a ledger EXISTS — with or
  # without --require-fidelity-ledger, and --accept-residuals does NOT apply.
  # A `data` delta means the rendered VALUES diverge from the source; every
  # other gate can pass while the numbers are wrong (the field failure).
  data_block = entries.each_with_index.select { |e, _i| e['cls'] == 'data' && !e['resolved'] }
  if data_block.any?
    accepted_data = data_block.select { |e, i| accepted.include?(i.to_s) || accepted.include?(e['id'].to_s) }
    warn "[FAIL] gate 8d: #{data_block.length} unresolved data-class RCF delta(s) in #{fl_path}:"
    data_block.each { |e, _i| warn "         #{e['id']} [#{e['dimension']}] #{e['delta']}" }
    if accepted_data.any?
      warn "       --accept-residuals named #{accepted_data.map { |e, _i| e['id'] }.join(', ')} — REJECTED for data-class ids."
    end
    warn '       data-class residuals can never be waved through — the numbers are wrong; fix or'
    warn '       reclassify with evidence. Either fix the spec/data and mark the entry resolved'
    warn '       (fidelity-loop.rb resolve), or — only after PROVING the values actually match the'
    warn '       source — re-record it under its true class with the evidence in the entry. There is'
    warn '       no escape flag for data-class.'
    exit 15
  end
  if opts[:require_fidelity]
    blocking = entries.each_with_index.select do |e, i|
      e['cls'] == 'spec-fixable' && !e['resolved'] &&
        !accepted.include?(i.to_s) && !accepted.include?(e['id'].to_s)
    end
    if blocking.any?
      warn "[FAIL] gate 8d: #{blocking.length} unresolved spec-fixable RCF delta(s) in #{fl_path}:"
      blocking.each do |e, _i|
        warn "         #{e['id']} [#{e['dimension']}] #{e['delta']} (fix: #{e['fix'] || 'see refs/fidelity-recipes.md'})"
      end
      warn '       Apply the recipe fix (fidelity-loop.rb apply-patch) and re-render, or waive named'
      warn '       residuals with --accept-residuals id,id (name them in your migration report;'
      warn '       data-class ids are never accepted).'
      exit 15
    end
    resid = entries.reject { |e| e['cls'] == 'spec-fixable' && !e['resolved'] }
                   .select { |e| %w[ui-only sigma-capability data].include?(e['cls']) }
    puts "[OK] gate 8d: RCF fidelity ledger clean — #{entries.length} delta(s) over #{ledger['pass']} pass(es), " \
         "0 unresolved spec-fixable, 0 unresolved data-class" \
         "#{resid.any? ? " (#{resid.length} recorded residual(s) → report)" : ''}"
  end
end

# ---------------------------------------------------------------------------
# Gate 13 — source-anchor value verification (exit 18). The MEASURED value bar.
# A run can pass CSV parity plumbing, render a PNG, and record a visual "pass"
# while the NUMBERS are wrong (different ranked members, 10x-off magnitudes,
# collapsed buckets — the two-field-failure class). Judgment gates are
# attestations; this one is arithmetic: every printed value the agent
# transcribed from the SOURCE dashboard image at Phase 1d (source-anchors.json,
# >= 5 anchors, EXACTLY as printed) must appear in the LIVE workbook's element
# exports at the printed precision (scripts/verify-anchors.rb →
# anchors-verdict.json). Fires whenever the workdir carries a source dashboard
# PNG (the 1d artifact); no source PNG at all → stated SKIP.
# ---------------------------------------------------------------------------
MIN_ANCHORS = 5
find_source_png = lambda do
  cands = []
  pr = File.join(opts[:tab], 'png-read.json')
  if File.exist?(pr)
    sp = (JSON.parse(File.read(pr))['source_png'] rescue nil).to_s
    unless sp.empty?
      cands << sp << File.join(opts[:tab], sp) << File.join(opts[:tab], 'views', File.basename(sp))
    end
  end
  if File.exist?(fl_path)
    si = ((ledger || {})['source_image'] rescue nil).to_s
    cands << si << File.join(opts[:tab], si) unless si.empty?
  end
  cands += Dir.glob(File.join(opts[:tab], 'views', '*.png')).sort
  cands += Dir.glob(File.join(opts[:tab], 'dashboards', '*.png')).sort
  cands.find { |p| p.downcase.end_with?('.png') && File.file?(p) }
end
source_png = find_source_png.call

if opts[:skip_anchors]
  record_waiver.call('--skip-anchors-gate', 'gate 13 (source-anchor value verification)', opts[:skip_anchors])
elsif source_png.nil?
  puts '[SKIP] gate 13: no source dashboard PNG in the workdir (no Phase 1d image artifact) — anchors gate N/A'
else
  sa_path = File.join(opts[:tab], 'source-anchors.json')
  av_path = File.join(opts[:tab], 'anchors-verdict.json')
  sa = File.exist?(sa_path) ? (JSON.parse(File.read(sa_path)) rescue nil) : nil
  n_anchors = sa.is_a?(Hash) ? Array(sa['anchors']).length : 0
  if n_anchors < MIN_ANCHORS
    warn "[FAIL] gate 13: source dashboard PNG present (#{source_png}) but " \
         "#{sa.nil? ? "#{sa_path} is missing/malformed" : "source-anchors.json has only #{n_anchors} anchor(s) (>= #{MIN_ANCHORS} required)"}."
    warn '       While READING the source image at Phase 1d, transcribe its printed values EXACTLY as'
    warn '       printed (raw string kept: "18,037B", not 18037) — every KPI value, the top 3 values of'
    warn '       every ranked list/table, and one representative bucket value per chart. Schema:'
    warn '       SKILL.md Phase 1d / refs/source-anchors.md. Then verify them against the live workbook:'
    warn "         ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id #{opts[:wb] || '<id>'}"
    warn '       Escape hatch (values genuinely untranscribable): --skip-anchors-gate "<reason>".'
    exit 18
  end
  av = File.exist?(av_path) ? (JSON.parse(File.read(av_path)) rescue nil) : nil
  if av.nil?
    warn "[FAIL] gate 13: #{n_anchors} anchor(s) transcribed but #{av_path} is missing/malformed —"
    warn '       the anchors were never verified against the live workbook. Run:'
    warn "         ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id #{opts[:wb] || '<id>'}"
    exit 18
  elsif av['checked'].to_i < n_anchors
    warn "[FAIL] gate 13: anchors-verdict.json is STALE — it checked #{av['checked'].to_i} anchor(s) but " \
         "source-anchors.json now has #{n_anchors}. Re-run verify-anchors.rb."
    exit 18
  elsif av['pass'] != true
    misses = Array(av['missing'])
    warn "[FAIL] gate 13: #{misses.length}/#{av['checked']} source anchor value(s) MISSING from the live workbook exports:"
    misses.first(10).each do |m|
      bc = m['best_candidate']
      warn "         #{m['id']} #{m['label'].inspect} raw=#{m['raw'].inspect}" \
           "#{bc.is_a?(Hash) ? " — closest candidate #{bc['value']} in #{bc['element'].inspect}" : ''}"
    end
    warn '       A printed source value that appears NOWHERE in the workbook exports is the loudest'
    warn '       possible signal the data is wrong (wrong aggregate, wrong unit/10x, missing filter,'
    warn '       collapsed buckets). Fix the workbook — or correct a mistranscribed anchor — then'
    warn '       re-run verify-anchors.rb and this gate. There is no per-anchor waiver.'
    exit 18
  else
    puts "[OK] gate 13: source anchors verified — #{av['matched']}/#{av['checked']} printed source values " \
         'found in the live workbook exports at printed precision'
  end
end

# ---------------------------------------------------------------------------
# Gate 14 — visual-similarity floor (exit 20). A MEASURED companion to the
# recorded visual verdict (gate 8b): scripts/visual-similarity.py (ships
# separately; gate is invisible until the script exists) scores the source
# dashboard PNG against the Sigma render and writes visual-similarity.json;
# its `pass` field is the verdict. CLI contract (fixed):
#   python3 scripts/visual-similarity.py --source <src> --render <render> \
#     --json-out <workdir>/visual-similarity.json
# VISUAL_SIMILARITY_SCRIPT env overrides the script path (tests).
# ---------------------------------------------------------------------------
vsim_script = ENV['VISUAL_SIMILARITY_SCRIPT'] || File.join(__dir__, 'visual-similarity.py')
if opts[:skip_vsim]
  record_waiver.call('--skip-visual-similarity', 'gate 14 (visual-similarity floor)', opts[:skip_vsim])
elsif File.exist?(vsim_script)
  if source_png.nil? || render_png.nil?
    puts "[SKIP] gate 14: visual-similarity floor N/A — #{source_png.nil? ? 'no source dashboard PNG' : 'no validated Sigma render'} to compare"
  else
    vs_out = File.join(opts[:tab], 'visual-similarity.json')
    system('python3', vsim_script, '--source', source_png, '--render', render_png, '--json-out', vs_out)
    vsim_status = $? ? $?.exitstatus : 'not-run'
    vs = File.exist?(vs_out) ? (JSON.parse(File.read(vs_out)) rescue nil) : nil
    if vs.nil?
      warn "[WARN] gate 14: visual-similarity.py exited #{vsim_status} with no readable #{vs_out} — floor NOT" \
           ' measured (deps missing / unreadable input; NOT a pass — stated, never silent).'
    elsif vs['pass'] == true
      puts "[OK] gate 14: visual-similarity floor passed#{vs['score'] ? " (score=#{vs['score']})" : ''}"
    else
      warn "[FAIL] gate 14: measured visual similarity below the floor#{vs['score'] ? " (score=#{vs['score']})" : ''} —"
      warn "       the render does not look like the source (#{source_png} vs #{render_png})."
      warn '       Re-enter the Phase 5g RCF loop (fidelity-loop.rb) and fix layout/kind/palette deltas,'
      warn '       then re-render and re-run. Escape hatch: --skip-visual-similarity "<reason>"'
      warn '       (counted against the waiver budget; name it in your migration report).'
      exit 20
    end
  end
end

# Gate 9 — Visual-verify tiles (build-from-signals). Tiles whose Tableau data
# export came back EMPTY (action-filter-gated etc.) are built from .twb signals
# and cannot be value-diffed, so they must be confirmed by IMAGE comparison
# (verify-visual-tiles.rb). Without this gate they'd pass parity silently. No-op
# (and invisible to other converters) when the sidecar is absent.
vv_sidecar = File.join(opts[:tab], 'visual-verify-tiles.json')
if File.exist?(vv_sidecar)
  vtiles = (JSON.parse(File.read(vv_sidecar)) rescue [])
  if opts[:skip_visual_tiles]
    puts "[SKIP] gate 9: #{vtiles.size} build-from-signals tile(s) visual-verify WAIVED (#{opts[:skip_visual_tiles]})."
  elsif vtiles.any?
    man_path = File.join(opts[:tab], 'visual-verify', 'manifest.json')
    man = File.exist?(man_path) ? (JSON.parse(File.read(man_path)) rescue nil) : nil
    if man.nil?
      warn "[FAIL] gate 9: #{vtiles.size} tile(s) had EMPTY data exports (built from .twb signals) but no"
      warn "       visual-verify/manifest.json exists — run: ruby scripts/verify-visual-tiles.rb"
      warn "       --workbook #{opts[:wb] || '<id>'} --tableau-dir #{opts[:tab]}, then READ each"
      warn '       <tile>.tableau.png vs <tile>.sigma.png pair and mark "visual_verified": true.'
      exit 11
    end
    unverified = man.reject { |m| m['visual_verified'] }
    if unverified.any?
      warn "[FAIL] gate 9: #{unverified.size}/#{man.size} build-from-signals tile(s) NOT visually verified: " \
           "#{unverified.map { |m| m['worksheet'] }.join(', ')}."
      warn '       These tiles have no value actuals (empty Tableau export). READ each'
      warn "       <tile>.tableau.png vs <tile>.sigma.png under #{File.join(opts[:tab], 'visual-verify')}/,"
      warn '       confirm trend/axis/magnitudes match, and set "visual_verified": true per tile in'
      warn '       visual-verify/manifest.json. Escape hatch: --skip-visual-tiles "<reason>" (name it in your report).'
      exit 11
    end
    # Gate 9b — SHAPE IDENTITY (field-caught: a run marked reshaped tiles
    # "verified" because their DATA matched — a ranked bar-table shipped as a
    # wall of grouped bars, annotated strip panels shipped as generic bars, and
    # the owner immediately judged the result "furthest from desired" while
    # every gate was green). visual_verified attests values/trends;
    # shape_match attests the tile is RECOGNIZABLY THE SAME VISUALIZATION.
    # Manifests written by current verify-visual-tiles.rb always carry the
    # field; legacy manifests (no shape_match key anywhere) are grandfathered.
    if man.any? { |m| m.key?('shape_match') }
      reshaped = man.select { |m| m['shape_match'] != true }
      if reshaped.any?
        warn "[FAIL] gate 9b: #{reshaped.size}/#{man.size} tile(s) verified for DATA but not for SHAPE: " \
             "#{reshaped.map { |m| "#{m['worksheet']}#{m['expected_kind'] ? " (source: #{m['expected_kind']})" : ''}" }.join(', ')}."
        warn '       Right data rendered as a DIFFERENT visualization is not fidelity — rebuild each'
        warn '       tile to the source shape (refs/fidelity-recipes.md; e.g. ranked bar-table →'
        warn '       pivot + dataBars, strip panel → per-panel chart + refMarks), re-render, then set'
        warn '       "shape_match": true in visual-verify/manifest.json. Escape hatch (only for a'
        warn '       VERIFIED product limitation, evidence in your report): --skip-visual-tiles "<reason>".'
        exit 11
      end
    end
    puts "[OK] gate 9: #{man.size} build-from-signals tile(s) image-verified (values + shape identity)"
  end
end

# ---------------------------------------------------------------------------
# Gate 10 — Telemetry consent decision. The anonymous usage ping (and the
# consent prompt that precedes it) lived as prose in each SKILL.md, so an agent
# could wrap up without ever asking — telemetry silently never fired. This gate
# delegates to the standalone assert-telemetry-ran.rb (single source of truth)
# which checks for the telemetry-sent.json marker written by report-telemetry.py
# on send OR decline. Never touches the network. The 3 converters that don't run
# THIS script (qlik/cognos/gooddata) call assert-telemetry-ran.rb directly.
# ---------------------------------------------------------------------------
tele_gate = File.join(__dir__, 'assert-telemetry-ran.rb')
if File.exist?(tele_gate)
  cmd = [RbConfig.ruby, tele_gate, '--workdir', opts[:tab]]
  cmd += ['--skip-telemetry-gate', opts[:skip_telemetry]] if opts[:skip_telemetry]
  unless system(*cmd)
    # assert-telemetry-ran.rb already printed the actionable failure message.
    exit 12
  end
else
  warn '[WARN] gate 10: assert-telemetry-ran.rb not found alongside this script — telemetry not enforced.'
end

# ---------------------------------------------------------------------------
# Gate 11 — post-publish interactivity guide (exit 16). Dashboard ACTIONS
# (filter / highlight / navigate / set-action / parameter-action / URL) are the
# one interactivity class workbooks-as-code cannot port — the customer wires
# cross-element filtering in the Sigma UI after publish. Every workbook in the
# 10-conversion live run that carried actions needed a hand-written handoff
# note; this gate makes the guide (POSTPUBLISH_GUIDE.md, generated by
# scripts/build-postpublish-guide.rb) mandatory whenever the source recorded
# actions. Action census sources, broadest wins:
#   - <workdir>/dashboard-layout-meta.json — parse-twb-layout.rb marks each
#     action-driven worksheet filter with is_action:true / kind:"action"
#   - <workdir>/*-gaps-report.json — scan-workbook-gaps.rb's "Dashboard filter /
#     highlight / nav actions" feature (command='tsc:tsl-*' matches; also covers
#     highlight/nav actions that never materialize as worksheet filters)
# Neither file present → census unavailable → stated SKIP (never a silent pass).
# ---------------------------------------------------------------------------
if opts[:skip_postpublish]
  record_waiver.call('--skip-postpublish-guide', 'gate 11 (post-publish interactivity guide)', opts[:skip_postpublish])
else
  meta_actions = 0
  gaps_actions = 0
  census_sources = []
  meta_path = File.join(opts[:tab], 'dashboard-layout-meta.json')
  if File.exist?(meta_path)
    meta = JSON.parse(File.read(meta_path)) rescue nil
    if meta.is_a?(Hash) && meta['worksheets'].is_a?(Hash)
      meta_actions = meta['worksheets'].values.sum do |ws|
        next 0 unless ws.is_a?(Hash)
        Array(ws['filters']).count { |f| f.is_a?(Hash) && (f['is_action'] == true || f['kind'] == 'action') }
      end
      census_sources << meta_path
    end
  end
  Dir.glob(File.join(opts[:tab], '*-gaps-report.json')).sort.each do |gp|
    gj = JSON.parse(File.read(gp)) rescue nil
    next unless gj.is_a?(Hash)
    feat = Array(gj['detected_features']).find do |f|
      f.is_a?(Hash) && (f['pat'].to_s.include?('tsc:tsl-') || f['name'].to_s =~ %r{filter\s*/\s*highlight\s*/\s*nav actions}i)
    end
    next unless feat
    gaps_actions = [gaps_actions, feat['count'].to_i].max
    census_sources << gp
  end
  n_actions = [meta_actions, gaps_actions].max
  guide_path = File.join(opts[:tab], 'POSTPUBLISH_GUIDE.md')
  if census_sources.empty?
    puts '[SKIP] gate 11: no dashboard-layout-meta.json / *-gaps-report.json in the workdir — dashboard-action census unavailable'
  elsif n_actions.zero?
    puts '[OK] gate 11: source recorded no dashboard filter/highlight/nav actions — post-publish guide not required'
  elsif File.exist?(guide_path)
    puts "[OK] gate 11: #{n_actions} source dashboard action(s) detected; POSTPUBLISH_GUIDE.md present (#{guide_path})"
  else
    warn "[FAIL] gate 11: source dashboards carry #{n_actions} interactive actions that workbooks-as-code"
    warn '       cannot port — run scripts/build-postpublish-guide.rb to generate the user handoff guide.'
    warn "       (census: #{census_sources.join(', ')})"
    warn "       The guide must land at #{guide_path} — it tells the customer which"
    warn '       cross-element filter/highlight/nav wirings to add in the Sigma UI after publish.'
    warn '       Escape hatch: --skip-postpublish-guide "<reason>" (name it in your migration report).'
    exit 16
  end
end

# ---------------------------------------------------------------------------
# Gate 12 — deferred DM elements (exit 17). post-and-readback.rb
# --quarantine-on-failure saves a DM POST killed by one broken element by
# moving the offender(s) to <workdir>/deferred-elements.json and re-POSTing the
# rest (hackathon Rec5). That DM is PARTIAL by construction — declaring GREEN
# on it would silently ship a data model missing elements. Non-empty file →
# hard FAIL until the elements are fixed + re-POSTed (then delete the file).
# No file / empty deferred list → OK. Escape: --accept-deferred-elements
# "<reason>" (recorded as a waiver; name it + the dropped elements in the report).
# ---------------------------------------------------------------------------
deferred_path = File.join(opts[:tab], 'deferred-elements.json')
if opts[:accept_deferred]
  record_waiver.call('--accept-deferred-elements', 'gate 12 (deferred/quarantined DM elements)', opts[:accept_deferred])
elsif File.exist?(deferred_path)
  ddoc = JSON.parse(File.read(deferred_path)) rescue nil
  deferred = ddoc.is_a?(Hash) ? Array(ddoc['deferred']) : (ddoc.is_a?(Array) ? ddoc : nil)
  if deferred.nil?
    warn "[FAIL] gate 12: #{deferred_path} is malformed (expected {\"deferred\":[...]} or a bare array)."
    warn '       Fix or delete the file (delete ONLY if every quarantined element was restored + re-POSTed).'
    exit 17
  elsif deferred.any?
    names = deferred.map { |d| d.is_a?(Hash) ? (d.dig('element', 'name') || d.dig('element', 'id') || '(unnamed)') : d.to_s }
    warn "[FAIL] gate 12: #{deferred.size} DM element(s) still deferred (quarantined at POST time) — the live"
    warn '       data model is PARTIAL. Resolve the deferred elements and re-POST:'
    names.each { |n| warn "         - #{n}" }
    warn "       Fix each element spec in #{deferred_path}, restore it into the DM spec,"
    warn '       PUT it back (ruby scripts/post-and-readback.rb --type datamodel --update-id <dmId> ...),'
    warn '       then delete the file and re-run this gate.'
    warn '       Escape hatch (knowingly shipping a partial DM): --accept-deferred-elements "<reason>"'
    warn '       (name it AND the dropped elements in your migration report).'
    exit 17
  else
    puts "[OK] gate 12: deferred-elements.json present but empty — all quarantined elements resolved"
  end
else
  puts '[OK] gate 12: no deferred-elements.json — no DM elements were quarantined'
end

# ---------------------------------------------------------------------------
# Waiver budget cap (exit 19) — checked LAST so genuine gate failures surface
# first. Individually-arguable escapes stack into an unverified workbook (a
# field run passed one workbook purely by combining --skip-parity-gate with
# --allow-missing-tiles); more than WAIVER_BUDGET waivers means GREEN is
# unavailable regardless of what each escape was for. No escape flag exists
# for this cap — reduce the waiver count by fixing the underlying issues, or
# report the migration as YELLOW.
# ---------------------------------------------------------------------------
if budget_flags.length > WAIVER_BUDGET
  warn "[FAIL] waiver budget exceeded — #{budget_flags.length} quality waiver/escape flag(s) on this run (budget #{WAIVER_BUDGET})."
  warn '       GREEN unavailable — too many waivers; the highest achievable result is YELLOW.'
  warn '       Each waiver hid a verification:'
  budget_flags.each { |f| warn "         - #{f}: #{WAIVER_HIDES[f] || 'a verification gate did not run'}" }
  warn '       Waivers are for impossibilities, not obstacles. Fix the underlying issues until'
  warn "       <= #{WAIVER_BUDGET} remain, or report this migration as YELLOW (never GREEN) and name"
  warn '       every waiver in the report. There is no escape flag for this cap.'
  exit 19
end

# Completion sentinel — stamp a run-scoped success marker keyed to the workbook
# and clear any PASS-1 pending marker. verify-complete.rb (the offline done-check
# the SKILL points agents at) reports GREEN only when this file exists for the
# workbook and no parity-pending.json remains. This makes "done" a token only the
# gate can mint, closing the "agent narrates success without the gate" hole.
# run_id scopes the marker to THIS run (see the at_exit stale-deletion above);
# the waiver census rides along so a report can quote the marker verbatim.
begin
  _wd = opts[:tab]
  # chartCount from parity-final.json (gate 1 already required charts_total > 0 to
  # reach here) so verify-complete.rb has a uniform element count across plugins.
  _pf = (JSON.parse(File.read(File.join(_wd, 'parity-final.json'))) rescue {})
  _cc = (_pf['charts_total'] || _pf['charts_pass'] || 0).to_i
  File.write(File.join(_wd, 'phase6-success.json'),
             JSON.pretty_generate('workbookId' => (opts[:wb] || ''),
                                  'chartCount' => _cc,
                                  'gates' => 'all-pass',
                                  'run_id' => current_run_id,
                                  'waivers' => waiver_flags,
                                  'generatedAt' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')))
  _pend = File.join(_wd, 'parity-pending.json')
  File.delete(_pend) if File.exist?(_pend)
  # Flip the off-ramp telemetry field now that success is minted (P2).
  if File.exist?(File.join(_wd, 'parity-final.json'))
    begin
      _pf['success_sentinel'] = true
      File.write(File.join(_wd, 'parity-final.json'), JSON.pretty_generate(_pf))
    rescue StandardError
      nil
    end
  end
rescue StandardError
  # never fail the gate on sentinel bookkeeping
end

puts "[OK] all gates pass — conversion may declare GREEN" \
     "#{waiver_flags.any? ? " (#{budget_flags.length}/#{waiver_flags.length} waiver(s) within budget — name them in the report: #{waiver_flags.join(', ')})" : ''}"
exit 0
