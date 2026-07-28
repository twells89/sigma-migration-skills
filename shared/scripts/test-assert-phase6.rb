#!/usr/bin/env ruby
# Offline contract tests for the FILE-DRIVEN gates of assert-phase6-ran.rb — the
# shared (synced-from-canonical) Phase-6 GREEN gate — exercised END-TO-END
# through the actual script (not by calling libs directly; scripts/lib/{control_lint,
# layout_lint}.rb already have their own direct-lib contract tests in
# test-green-gates.rb).
#
# Scope, from reading the CURRENT script (2026-07, ~31 gates; header comments
# lag the code and are NOT trusted):
#   - Gates 3 (live /columns) and 4 (live /spec layout) hit the network and
#     FAIL CLOSED (exit 5 / exit 6) when SIGMA_BASE_URL/SIGMA_API_TOKEN are
#     unset and a workbook id resolves — they do not silently pass. This
#     fail-closed behavior itself is file+env driven and IS tested below;
#     their escape hatches are --skip-column-check / --skip-layout-check.
#   - Gates 6 (layout lint) and 7 (control lint) ALSO fetch the live spec, but
#     — unlike 3/4 — do NOT fail closed without creds: they print a [SKIP]
#     WARN and continue. Already covered (against the libs directly) by
#     test-green-gates.rb; this harness only relies on their offline no-op.
#   - Gate 10 (telemetry) delegates to scripts/assert-telemetry-ran.rb.
#     write_good_fixtures seeds a telemetry-sent.json marker (status
#     "declined") so this gate is satisfied at ZERO waiver-budget cost
#     regardless of whether the delegate script happens to be vendored
#     alongside this gate: an unconditional WARN no-op where it is absent
#     (e.g. domo-to-sigma's copy), a genuine marker-satisfied pass where it
#     IS vendored (e.g. this canonical's own location, and most other
#     plugins' copies) — either way every scenario below reaches its own
#     targeted gate, never gate 10's exit 12.
#   - Gate 14 (visual-similarity) needs scripts/visual-similarity.py plus a
#     real python3 + image pair; no scenario below ever supplies BOTH a
#     source dashboard PNG AND reaches this gate without exiting earlier
#     (the one scenario with a source PNG, gate 13, always exits first), so
#     gate 14 stays an inert [SKIP] N/A here whether or not the delegate
#     script is vendored — left untested (see bottom-of-file NOTE) rather
#     than faked.
#   - Gate 7b (runtime control flip) and gate 4b (layout-phase sentinel) are
#     opt-in / tool-gated respectively; both have genuine offline-triggerable
#     paths (a file-driven enforced-fallback for 7b, a tool-registry check for
#     4b) and are exercised below, with the tool-gating boundary documented at
#     the call site.
#   - lib/degradation_ledger.rb and lib/flip_gate.rb are not vendored in this
#     plugin (grep confirms), so DEG_LEDGER_LOADED is false and the final
#     verdict line is always the legacy "no PR-14 verdict derived" print —
#     exit code is unaffected either way.
#
# Isolation: SIGMA_BASE_URL / SIGMA_API_TOKEN are forced empty in the gate's
# subprocess env on every invocation (belt-and-braces against a dev shell that
# happens to have live Sigma creds exported — this suite must never reach the
# network even by accident).
#
#   ruby test/test-assert-phase6.rb
require 'json'
require 'tmpdir'
require 'fileutils'

GATE = File.expand_path('../scripts/assert-phase6-ran.rb', __dir__)
# Self-identifies the adopting converter from this file's own path (e.g. a
# synced copy living under plugins/<tool>/skills/<tool>/test/ resolves to
# <tool>); falls back to a neutral label when run from the shared canonical
# location (shared/scripts/), which is not itself a `*-to-sigma` plugin dir.
TOOL = (__dir__[%r{(\w+-to-sigma)}, 1] || 'assert-phase6')
$failures = 0
def eq(a, b, m)
  if a == b then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}" end
end

# Run the gate as a subprocess against `dir`, with SIGMA creds forced empty
# (offline, and immune to whatever the invoking shell happens to export).
def run_gate(dir, *extra_args)
  cmd = ['ruby', GATE, '--workdir', dir] + extra_args
  env = { 'SIGMA_BASE_URL' => '', 'SIGMA_API_TOKEN' => '' }
  system(env, *cmd, out: File::NULL, err: File::NULL)
  $?.exitstatus
end

def write_json(dir, name, obj)
  File.write(File.join(dir, name), JSON.generate(obj))
end

# A workdir with valid, minimal fixtures for every FILE-DRIVEN gate this
# script checks, plus a resolvable workbook id (wb-ids.json) for the two
# live-endpoint gates' fail-closed check. Every gate NOT mentioned here is
# left absent-on-disk on purpose — each one's own code treats "file absent" as
# a stated SKIP/OK (back-compat / N-A), which is itself part of what the happy
# path proves.
def write_good_fixtures(dir)
  # Gate 1 (parity) + gate 5 (tile census, folded into the same file).
  write_json(dir, 'parity-final.json',
              'charts_total' => 3, 'charts_pass' => 3, 'status' => 'PASS', 'mode' => 'live',
              'tile_census' => { 'zones_total' => 3, 'charts_built' => 3,
                                  'zones_unmatched' => 0, 'unmatched_zone_names' => [] })
  # Gate 2 (orphan workbooks) — exactly one workbook POSTed, nothing to clean.
  File.write(File.join(dir, 'posted-workbooks.jsonl'), JSON.generate('id' => 'wb-happy-1') + "\n")
  # Resolvable workbook id for gates 3/4/6/7/7b's wb-ids.json fallback.
  write_json(dir, 'wb-ids.json', 'workbookId' => 'wb-happy-1')
  # Gate 8c (layout fill) — every zone placed, grid comfortably filled.
  write_json(dir, 'layout-census.json',
              'pages' => [{ 'page' => 'Overview', 'zones' => 3, 'placed' => 3,
                            'grid_fill_pct' => 0.9, 'unplaced_elements' => [] }])
  # Gate 8 (visual render) — real PNG magic bytes, comfortably over the 5,000
  # byte floor (valid_png only checks magic + size, never decodes the image).
  File.open(File.join(dir, 'sigma-render.png'), 'wb') do |f|
    f.write("\x89PNG\r\n\x1a\n".b)
    f.write("\x00".b * 6_000)
  end
  # Gate 10 (telemetry consent decision) — satisfied via the marker file
  # itself, at ZERO waiver-budget cost, rather than via --skip-telemetry-gate.
  # assert-telemetry-ran.rb requires BOTH the marker's existence AND a
  # status of sent/declined/skipped; harmless where the delegate script is
  # not vendored alongside this gate (an unconditional WARN no-op there, as
  # in domo-to-sigma's copy) and correctly satisfies it where it IS vendored
  # (e.g. the shared canonical's own location, and most other plugins' copies).
  write_json(dir, 'telemetry-sent.json', 'status' => 'declined')
end

# Every offline scenario needs gates 3 (--skip-column-check) and 4
# (--skip-layout-check) waived — no live Sigma creds exist in this harness —
# and gate 8b (visual comparison) waived under the sanctioned
# builder->verifier split, whose reason matches /verifier/i and is therefore a
# POLICY exclusion from the 2-waiver budget (exit 19), leaving the two
# genuinely-live-endpoint skips as the only budget-counted waivers (exactly at
# the cap of 2, never over it).
HAPPY_FLAGS = [
  '--skip-column-check', 'offline harness: no live Sigma creds (gate 3 needs GET /v2/workbooks/{id}/columns)',
  '--skip-layout-check', 'offline harness: no live Sigma creds (gate 4 needs GET /v2/workbooks/{id}/spec)',
  '--skip-visual-comparison', 'verifier: render pre-verified by a prior session (policy-excluded from the waiver budget)'
].freeze

# Build a fresh good workdir, let the block corrupt/add exactly one thing,
# run the gate with `flags`, and assert the EXACT exit code.
def scenario(name, expect_exit, flags = HAPPY_FLAGS)
  Dir.mktmpdir('domo-p6') do |dir|
    write_good_fixtures(dir)
    yield dir if block_given?
    got = run_gate(dir, *flags)
    eq(got, expect_exit, name)
  end
end

puts '== happy path: every file-driven gate satisfied, both live-endpoint gates waived =='
scenario('all fixtures valid, live gates skipped -> exit 0', 0)

puts '== gate 1 (Phase 6 parity) =='
scenario('no parity-final.json at all -> exit 1 (Phase 6 never ran)', 1) { |dir| File.delete(File.join(dir, 'parity-final.json')) }
scenario('parity-final.json is malformed JSON -> exit 3', 3) { |dir| File.write(File.join(dir, 'parity-final.json'), '{not valid json') }
scenario('parity-final.json status=FAIL -> exit 2', 2) do |dir|
  write_json(dir, 'parity-final.json', 'charts_total' => 3, 'charts_pass' => 2, 'status' => 'FAIL', 'mode' => 'live')
end

puts '== gate 2 (orphan workbooks, beads-sigma-38a) =='
scenario('2 workbooks POSTed, no cleanup-marker.json -> exit 4', 4) do |dir|
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             [{ 'id' => 'wb-1' }, { 'id' => 'wb-2' }].map { |h| JSON.generate(h) }.join("\n") + "\n")
end

puts '== gate 3 (live /columns, fail-closed without creds) =='
# No --skip-column-check passed: wb-ids.json resolves a workbook id and
# SIGMA_BASE_URL/TOKEN are forced empty by run_gate, so the gate must FAIL
# CLOSED rather than silently pass — proves a credential-less run cannot ship.
scenario('workbook id resolvable, no creds, no waiver -> exit 5', 5, [])

puts '== gate 4 (live /spec layout, fail-closed without creds) =='
scenario('gate 3 waived, gate 4 not waived, no creds -> exit 6', 6,
         ['--skip-column-check', 'reach gate 4'])

puts '== gate 5 (tile census, bead gjhe) =='
scenario('2 dashboard zones unmatched, no visual-verify oracle -> exit 7', 7,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r']) do |dir|
  write_json(dir, 'parity-final.json',
             'charts_total' => 3, 'charts_pass' => 3, 'status' => 'PASS', 'mode' => 'live',
             'tile_census' => { 'zones_total' => 5, 'charts_built' => 3, 'zones_unmatched' => 2,
                                 'unmatched_zone_names' => %w[TileX TileY] })
end

puts '== gate 7c (source-vs-built controls census, PLAN-v3 PR-13) =='
scenario('census signal never built/declared/waived -> exit 31', 31,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r']) do |dir|
  write_json(dir, 'domo-controls-coverage.json',
             'detail' => [{ 'kind' => 'filter', 'name' => 'Region', 'status' => 'declared_not_built' }])
end

puts '== gate 7b (runtime control flip; DEFAULT-ON via migrate-state control_flip_required) =='
# opt-in path: migrate-state.json auto-enables enforcement (the same mechanism
# tableau-to-sigma pass 1 stamps); no live creds and no recorded evidence
# (no probe-results.json / control-flip-unverified.json / empty controls
# census) means the ENFORCED gate must fail closed, entirely file/env-driven.
# BOUNDARY: an adopting converter's workdir never carries migrate-state.json
# in real usage (that's tableau-to-sigma's stamp) — this proves the SHARED
# script's fallback mechanics, not a tool-specific code path.
scenario('flip enforced, no creds, no recorded evidence -> exit 21', 21,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r']) do |dir|
  write_json(dir, 'migrate-state.json', 'control_flip_required' => true)
end

puts '== gate 8 (Phase 6f visual render present) =='
scenario('no sigma-render.png and no fallback render found -> exit 10', 10,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r']) do |dir|
  File.delete(File.join(dir, 'sigma-render.png'))
end

puts '== gate 8b (source-vs-target visual comparison recorded) =='
scenario('valid render present but no visual verdict recorded, not waived -> exit 13', 13,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r'])

puts '== gate 8c (layout fill / grid coverage, #259 item 1) =='
scenario('a page dropped a tile (placed < zones) -> exit 14', 14,
         ['--skip-column-check', 'r', '--skip-layout-check', 'r', '--skip-visual-comparison', 'verifier: r']) do |dir|
  write_json(dir, 'layout-census.json',
             'pages' => [{ 'page' => 'Overview', 'zones' => 3, 'placed' => 1,
                           'grid_fill_pct' => 0.9, 'unplaced_elements' => [] }])
end

puts '== gate 8d (RCF fidelity ledger — data-class residuals always block) =='
scenario('unresolved data-class RCF delta -> exit 15', 15) do |dir|
  write_json(dir, 'fidelity-ledger.json',
             'pass' => 1, 'entries' => [{ 'id' => 'd1', 'cls' => 'data', 'dimension' => 'value',
                                           'delta' => 'KPI off by 10%', 'resolved' => false }])
end

puts '== gate 8e (layout-arrangement parity, opt-in via --require-arrangement) =='
scenario('--require-arrangement set, report carries a violation -> exit 29', 29,
         HAPPY_FLAGS + ['--require-arrangement']) do |dir|
  write_json(dir, 'layout-arrangement.json',
             'pages' => [{ 'page' => 'Overview', 'violations' => ['stacking order inverted vs source'] }])
end

puts '== gate 4b (layout-phase SENTINEL, PLAN-v3 PR-11) =='
# BOUNDARY: LAYOUT_PHASE_BY_TOOL only registers 'tableau-to-sigma' — an
# adopting converter's own genuine run-state.json (tool=<its own value>)
# always hits the "no registered layout-phase key" SKIP, never this FAIL.
# Spoofing `tool` here contract-tests the SHARED script's sentinel mechanism
# directly (same script, same code path any adopting converter would hit),
# not tool-specific behavior.
scenario('run-state.json tracked, layout phase key never stamped -> exit 30', 30) do |dir|
  write_json(dir, 'run-state.json', 'tool' => 'tableau-to-sigma', 'phases' => {})
end

puts '== gate 9 (build-from-signals tile image-verification) =='
scenario('sidecar present, no visual-verify manifest -> exit 11', 11) do |dir|
  write_json(dir, 'visual-verify-tiles.json', ['Tile A'])
end

puts '== gate 11 (post-publish interactivity guide) =='
scenario('source has a dashboard action, no POSTPUBLISH_GUIDE.md -> exit 16', 16) do |dir|
  write_json(dir, 'dashboard-layout-meta.json',
             'worksheets' => { 'Sheet1' => { 'filters' => [{ 'is_action' => true }] } })
end

puts '== gate 12 (deferred/quarantined DM elements) =='
scenario('deferred-elements.json non-empty -> exit 17', 17) do |dir|
  write_json(dir, 'deferred-elements.json', 'deferred' => [{ 'element' => { 'name' => 'Broken Calc' } }])
end

puts '== gate 13 (source-anchor value verification, the measured value bar) =='
scenario('source PNG present, source-anchors.json under the 5-anchor floor -> exit 18', 18) do |dir|
  FileUtils.mkdir_p(File.join(dir, 'views'))
  File.write(File.join(dir, 'views', 'source.png'), 'not a real png, just needs to exist')
  write_json(dir, 'source-anchors.json', 'anchors' => [{ 'id' => 'a1', 'label' => 'Total Sales', 'raw' => '$1,234' }])
end

puts '== gate 15 (manual custom-SQL residues, G6) =='
scenario('an unbuilt residue, not accepted -> exit 22', 22) do |dir|
  write_json(dir, 'manual-residues.json',
             'residues' => [{ 'calc' => 'RunningSum', 'tile' => 'Trend', 'status' => 'unbuilt' }])
end

puts '== gate 16 (join-cardinality ledger, PR-4) =='
scenario('a non-unique Lookup target, no resolution -> exit 23', 23) do |dir|
  write_json(dir, 'join-plan.json',
             'entries' => [{ 'kind' => 'lookup', 'left' => 'Orders', 'right' => 'Customers',
                             'keys' => ['customer_id'], 'status' => 'non-unique' }])
end

puts '== gate 17 (LOD translation ledger, #423) =='
scenario('a suspect-alias LOD calc, no resolution -> exit 24', 24) do |dir|
  write_json(dir, 'lod-audit.json',
             'entries' => [{ 'calc' => '[FIXED Region: SUM(Sales)]', 'class' => 'suspect-alias',
                             'lod_kind' => 'FIXED', 'evidence' => { 'formula' => '[Sales_Raw]' },
                             'suspect_refs' => ['Sales_Raw'] }])
end

puts '== gate 18 (ground-truth numeric coverage, PR-6) =='
scenario('plan exists, numeric comparison never ran -> exit 25', 25) do |dir|
  write_json(dir, 'ground-truth-plan.json',
             'generated_at' => '2026-01-01T00:00:00Z', 'entries' => [{ 'chart' => 'Revenue KPI' }])
end

puts '== gate 19 (aggregation-semantics ledger, PR-7) =='
scenario('an additive-over-preagg hit, no resolution -> exit 26', 26) do |dir|
  write_json(dir, 'agg-semantics.json',
             'entries' => [{ 'consumer' => 'Total Entities KPI', 'context' => 'Sum over FIXED pre-agg',
                             'class' => 'additive-over-preagg', 'preagg' => '[FIXED day: COUNTD(Entity)]' }])
end

puts '== gate 20 (semantic-edit equivalence ledger, PR-8) =='
scenario('a declared edit with no proof block -> exit 27', 27) do |dir|
  write_json(dir, 'semantic-edits.json',
             'entries' => [{ 'edit_description' => 'Dropped LEFT JOIN to Promotions',
                             'claim' => 'no-op, promotions unused', 'grain' => ['order_id'] }])
end

puts '== gate 21 (chart-kind parity, PR-10) =='
scenario('verified source kind (line) disagrees with the live readback (bar) -> exit 28', 28) do |dir|
  write_json(dir, 'png-read.json', 'verified' => true, 'tiles' => [{ 'title' => 'Sales by Region', 'kind' => 'line' }])
  write_json(dir, 'wb-readback.json',
             'pages' => [{ 'elements' => [{ 'name' => 'Sales by Region', 'kind' => 'bar-chart',
                                             'visibleAsSource' => true }] }])
end

puts '== waiver budget (exit 19; checked LAST, after every other gate passes) =='
scenario('3 budget-counted waivers (column+layout+orphan), 1 policy-excluded (visual-comparison) -> exit 19', 19,
         HAPPY_FLAGS + ['--skip-orphan-check', 'budget test: deliberately exceed the cap of 2'])

puts
if $failures.zero? then puts 'ALL PASS'; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end

# NOTE on coverage boundaries NOT tested above (documented, not faked):
#   - Gates 6/7 (layout lint / control lint): fetch the live spec; already
#     contract-tested against the libs directly in test-green-gates.rb. This
#     harness only relies on their credential-less no-op (implicit in every
#     scenario above, since SIGMA_BASE_URL/TOKEN are always forced empty and
#     none of the scenarios ever fail at gate 6 or 7).
#   - Gate 10 (telemetry): satisfied above via the telemetry-sent.json
#     fixture in write_good_fixtures (zero waiver-budget cost), not by
#     asserting a specific WARN-vs-pass behavior — that behavior legitimately
#     differs by copy (WARN no-op where scripts/assert-telemetry-ran.rb is
#     absent, e.g. domo-to-sigma; a real marker-satisfied pass where it is
#     vendored, e.g. this canonical and most other plugins' copies). Both
#     paths are exercised implicitly (every scenario below reaches its own
#     targeted gate either way); nothing further to assert.
#   - Gate 14 (visual-similarity floor): stays an inert [SKIP] N/A in every
#     scenario above regardless of whether scripts/visual-similarity.py is
#     vendored in this copy, because no scenario supplies both a source
#     dashboard PNG and reaches this gate without exiting earlier (gate 13's
#     scenario is the only one with a source PNG, and it always exits before
#     gate 14 runs). Actually exercising a measured pass/fail would require
#     vendoring a stub script, a real python3 subprocess, and entangles with
#     gate 13's source-PNG discovery. Left untested rather than faked.
#   - Gate 9's sub-checks (attested-empty-tile cross-check, gate 9b
#     shape_match) share gate 9's exit code (11); only the base
#     "no manifest at all" path is exercised above.
