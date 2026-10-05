#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test_shared_script_closure.rb — structural guards on the shared fan-out
# (issue #539). Two live-caught failure modes, both invisible to every existing
# gate because each individual file was perfectly valid:
#
#  1. A GATE'S REMEDY SCRIPT WAS MISSING. assert-phase6-ran.rb was shared to
#     several plugins and its gate 8b tells the operator to run
#     `ruby scripts/record-visual-check.rb …` — but that script shipped in only a
#     subset. A live QuickSight migration could not satisfy its own mandatory
#     gate; the run had to borrow another plugin's copy, and the two existing
#     copies had DIFFERENT flag sets (looker's rejected --no-vision-waiver), so
#     the remedy's behaviour depended on which copy you happened to find.
#
#  2. A SHARED SCRIPT'S DEPENDENCY WASN'T FANNED OUT. Promoting that recorder to
#     shared/ fanned out the script but not the two libs it require_relative's
#     (lib/cli_encoding, lib/blind_grade — which existed only under tableau), so
#     every newly-created copy died on LoadError at startup. check-shared only
#     compares files that ARE registered; it cannot see a dependency that was
#     never registered at all. Static require-parsing is unreliable here
#     (requires can be conditional, and paths can be ../lib/…), so this asserts
#     the thing that actually matters: each copy LOADS.
#
# Offline, creds-free, no network (--help only; nothing is executed for real).
# Run: ruby shared/lib/test_shared_script_closure.rb
require 'json'
require 'open3'
require 'set'

ROOT = File.expand_path('../..', __dir__)
Dir.chdir(ROOT)

$fail = 0
def ok(desc); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"; $fail += 1 unless r; end

MANIFEST = JSON.parse(File.read('shared/manifest.json'))
ENTRIES = MANIFEST['shared'].each_with_object({}) do |e, h|
  h[e['canonical']] = e['targets'].map { |t| t.is_a?(Hash) ? t['path'] : t }
end

# ── 1. Every registered fan-out target actually exists on disk. A registered
#       entry whose target file is absent means the fan-out never ran (or a
#       target path is a typo) — check-shared compares CONTENT and would report
#       a mismatch, but this states the simpler precondition outright.
missing_targets = ENTRIES.flat_map { |c, ts| ts.reject { |t| File.exist?(t) }.map { |t| "#{c} -> #{t}" } }
ok('every shared-manifest target file exists') do
  missing_targets.each { |m| warn "    MISSING #{m}" }
  missing_targets.empty?
end

# The browser-first Sigma auth runtime is one atomic closure. A get-token.sh
# without get_token.py silently falls back to a different protocol on Python-free
# hosts; a browser-login.sh without its sourced platform helper dies at startup.
# Keep every existing outlier (the authoring helper and legacy assessment copy)
# and Qlik's documented vendor/ location in exact lockstep.
sigma_auth_entries = %w[
  shared/scripts/get-token.sh
  shared/scripts/get_token.py
  shared/scripts/browser-login.sh
  shared/scripts/refresh-token.sh
  shared/scripts/lib/browser-login-platform.sh
]
sigma_auth_roots = sigma_auth_entries.each_with_object({}) do |canonical, roots|
  roots[canonical] = ENTRIES.fetch(canonical, []).map do |target|
    target.end_with?('/lib/browser-login-platform.sh') ? File.dirname(File.dirname(target)) : File.dirname(target)
  end.to_set
end
auth_reference = sigma_auth_roots.fetch('shared/scripts/get-token.sh')
auth_runtime_drift = sigma_auth_roots.reject { |_canonical, roots| roots == auth_reference }
ok('Sigma dual-mode auth provider/browser/refresh/helper fan out as one closure') do
  auth_runtime_drift.each do |canonical, roots|
    warn "    #{canonical}: missing=#{(auth_reference - roots).to_a.sort.join(',')} extra=#{(roots - auth_reference).to_a.sort.join(',')}"
  end
  auth_runtime_drift.empty?
end

# Qlik hard-gate adoption is deliberately all-or-nothing. In particular,
# degradation_ledger is loaded behind a compatibility rescue, so the behavioural
# --help check below cannot detect its absence: the script would load but derive
# a weaker legacy verdict. Pin every direct require_relative dependency, plus
# the mandatory visual-remedy script and its dependency closure, in the manifest.
qlik_scripts = 'plugins/qlik-to-sigma/skills/qlik-to-sigma/scripts'
qlik_hard_gate_closure = {
  'shared/scripts/assert-phase6-ran.rb'      => "#{qlik_scripts}/assert-phase6-ran.rb",
  'shared/scripts/lint-render-integrity.rb' => "#{qlik_scripts}/lint-render-integrity.rb",
  'shared/lib/degradation_ledger.rb'        => "#{qlik_scripts}/lib/degradation_ledger.rb",
  'shared/lib/evidence_ledger.rb'           => "#{qlik_scripts}/lib/evidence_ledger.rb",
  'shared/lib/code_rep.rb'                  => "#{qlik_scripts}/lib/code_rep.rb",
  'shared/lib/layout_lint.rb'               => "#{qlik_scripts}/lib/layout_lint.rb",
  'shared/lib/control_lint.rb'              => "#{qlik_scripts}/lib/control_lint.rb",
  'shared/lib/flip_gate.rb'                 => "#{qlik_scripts}/lib/flip_gate.rb",
  'shared/scripts/record-visual-check.rb'   => "#{qlik_scripts}/record-visual-check.rb",
  'shared/lib/cli_encoding.rb'              => "#{qlik_scripts}/lib/cli_encoding.rb",
  'shared/lib/blind_grade.rb'               => "#{qlik_scripts}/lib/blind_grade.rb",
  'shared/scripts/cleanup-orphan-workbooks.rb' => "#{qlik_scripts}/cleanup-orphan-workbooks.rb"
}.freeze
missing_qlik_closure = qlik_hard_gate_closure.reject { |canonical, target| ENTRIES.fetch(canonical, []).include?(target) }
ok('Qlik assert-phase6 hard gate is manifest-registered with its full shared closure') do
  missing_qlik_closure.each { |canonical, target| warn "    MISSING REGISTRATION #{canonical} -> #{target}" }
  missing_qlik_closure.empty?
end

# Sisense hard-gate adoption has the same atomic closure requirement. Some
# dependencies were already vendored for Sisense's existing render/control
# checks; pin the complete set so later manifest edits cannot silently weaken
# the gate or remove one of its operator-facing remedies.
sisense_scripts = 'plugins/sisense-to-sigma/skills/sisense-to-sigma/scripts'
sisense_hard_gate_closure = {
  'shared/scripts/assert-phase6-ran.rb'      => "#{sisense_scripts}/assert-phase6-ran.rb",
  'shared/scripts/lint-render-integrity.rb' => "#{sisense_scripts}/lint-render-integrity.rb",
  'shared/lib/degradation_ledger.rb'        => "#{sisense_scripts}/lib/degradation_ledger.rb",
  'shared/lib/evidence_ledger.rb'           => "#{sisense_scripts}/lib/evidence_ledger.rb",
  'shared/lib/code_rep.rb'                  => "#{sisense_scripts}/lib/code_rep.rb",
  'shared/lib/layout_lint.rb'               => "#{sisense_scripts}/lib/layout_lint.rb",
  'shared/lib/control_lint.rb'              => "#{sisense_scripts}/lib/control_lint.rb",
  'shared/lib/flip_gate.rb'                 => "#{sisense_scripts}/lib/flip_gate.rb",
  'shared/scripts/record-visual-check.rb'   => "#{sisense_scripts}/record-visual-check.rb",
  'shared/lib/cli_encoding.rb'              => "#{sisense_scripts}/lib/cli_encoding.rb",
  'shared/lib/blind_grade.rb'               => "#{sisense_scripts}/lib/blind_grade.rb",
  'shared/scripts/cleanup-orphan-workbooks.rb' => "#{sisense_scripts}/cleanup-orphan-workbooks.rb",
  'shared/scripts/probe-controls.rb'         => "#{sisense_scripts}/probe-controls.rb",
  'shared/scripts/verify-warehouse.rb'       => "#{sisense_scripts}/verify-warehouse.rb",
  'shared/lib/sigma_rest.rb'                => "#{sisense_scripts}/lib/sigma_rest.rb",
  'shared/lib/export_pool.rb'               => "#{sisense_scripts}/lib/export_pool.rb"
}.freeze
missing_sisense_closure = sisense_hard_gate_closure.reject { |canonical, target| ENTRIES.fetch(canonical, []).include?(target) }
ok('Sisense assert-phase6 hard gate is manifest-registered with its full shared closure') do
  missing_sisense_closure.each { |canonical, target| warn "    MISSING REGISTRATION #{canonical} -> #{target}" }
  missing_sisense_closure.empty?
end

# ── 2. Gate remedies ship with their gate. Parses `scripts/<name>.rb` out of a
#       shared assert-* gate's own operator-facing text and requires that any
#       such script which is ITSELF shared exists in every plugin the gate ships
#       to. (A plugin-private remedy is that plugin's own business.)
SHARED_BASENAMES = ENTRIES.keys.map { |c| File.basename(c) }.to_set
missing_remedies = []
ENTRIES.each do |gate, gate_targets|
  next unless File.basename(gate).start_with?('assert-') && gate.end_with?('.rb')
  next unless File.exist?(gate)
  remedies = File.read(gate).scan(%r{scripts/([a-z0-9_-]+\.rb)}).flatten.uniq
                            .select { |r| SHARED_BASENAMES.include?(r) }
  gate_targets.each do |t|
    remedies.each do |r|
      path = File.join(File.dirname(t), r)
      missing_remedies << "#{File.basename(gate)} in #{t.split('/')[1]} names scripts/#{r} — ABSENT there" unless File.exist?(path)
    end
  end
end
ok('every shared script a shared gate names as its remedy ships with that gate') do
  missing_remedies.each { |m| warn "    #{m}" }
  missing_remedies.empty?
end

# ── 3. Dependency closure, verified BEHAVIOURALLY: every fanned-out copy of a
#       shared entry-point script must load (no LoadError) in its own plugin.
#       This is the guard that catches a promoted script whose require_relative'd
#       libs were not registered alongside it.
CHECKABLE = ENTRIES.keys.select do |c|
  c.start_with?('shared/scripts/') && c.end_with?('.rb') &&
    File.read(c).include?('OptionParser')   # entry points that parse flags support --help
end
load_errors = []
CHECKABLE.each do |c|
  ENTRIES[c].each do |t|
    dir = File.dirname(t)
    _o, err, = Open3.capture3('ruby', File.basename(t), '--help', chdir: dir)
    next unless err.include?('LoadError')
    dep = err[/cannot load such file -- (\S+)/, 1].to_s
    load_errors << "#{t}: LoadError#{dep.empty? ? '' : " (#{File.basename(dep)})"}"
  end
end
ok('every fanned-out shared entry-point script LOADS in its plugin (deps travelled with it)') do
  load_errors.each { |m| warn "    #{m}" }
  load_errors.empty?
end

# ── 4. RATCHET on unregistered duplicate script names.
#
# A script name living in several plugins without a shared-manifest entry is
# exactly how the record-visual-check divergence happened: nothing forces the
# copies to agree, so they drift silently until one plugin's copy is missing a
# flag or a fix another already has. check-shared can't help — it only compares
# what IS registered.
#
# The 24 names below are a REAL PRE-EXISTING BACKLOG, not an endorsement. Most
# have already diverged, and several diverged HARD (tableau's put-layout.rb is
# 301 lines against 77-85 elsewhere; build-charts-from-signals.rb is 9009 against
# 1533). Reconciling those is a per-script judgement about which behaviour is
# genuinely per-tool and which is a fix the others are missing — it cannot be
# done safely in bulk, because adopting the larger copy wholesale drags in libs
# the smaller plugins don't have (precisely the LoadError this file's guard 3
# exists to catch).
#
# So this is a RATCHET, not a pass: every name here is an acknowledged debt, and
# any NEW duplicate name fails CI. To clear an entry, either register it in
# shared/manifest.json (canonical = whichever copy carries the fixes, and make
# sure its deps are registered too) or, if the implementations really are
# per-tool, delete the line and add the name to PER_TOOL_BY_DESIGN with a reason.
PER_TOOL_BY_DESIGN = {
  'convert-model.rb'  => 'each converter parses a different source format end-to-end',
  'build-dm.rb' => 'each converter builds the Sigma DM from a structurally different source: ' \
    'domo-to-sigma\'s (478 lines) maps flat, materialized Domo DataSets through a customer-specific ' \
    'discovery/dataset-map.json onto warehouse tables, plus PROJECTION Beast Mode calc columns. ' \
    'mode-to-sigma\'s (167 lines) wraps each Mode Query verbatim as a single `sql`-kind element — ' \
    'Mode\'s SQL already runs against the target warehouse dialect, so there is no schema-mapping or ' \
    'formula-translation step at all. Sharing would mean one plugin carrying machinery the other has ' \
    'no source shape to exercise.',
  'phase6-parity.rb'  => "per-tool parity CLI (--tableau vs --workdir) and per-tool oracles",
  'learned-rules.rb'  => 'gap-scout rule store is keyed to one tool\'s expression language',
  'probe_registry.rb' => 'local artifact registry binds to one tool\'s <TOOL>_TO_SIGMA_HOME dotdir (same convention as learned-rules.rb)',
  'collect-parity-actuals.rb' => 'per-tool Sigma-actuals collector, same reasoning as phase6-parity.rb. ' \
    'tableau\'s is 441 lines whose bulk is machinery for problems MEASURED ON TABLEAU workbooks — a ' \
    'wide pivot-grid CSV export needing a totals-JSON fallback, multi-million-row detail tables that ' \
    'hung the pool, per-chart row-limit accounting. None of that has been observed on a Domo workbook, ' \
    'and domo already owns the identical export+poll fetch (lib/element_export.rb, live-proven since ' \
    '2026-07-30). Sharing would mean domo carrying and maintaining behaviour justified by another ' \
    'converter\'s evidence. They also key their results differently ON PURPOSE: domo keys by ' \
    'sigma_element_id because Domo reuses generic summary labels (11 of one real 65-tile page share a ' \
    'display name), which name-keying silently cross-wired into an unearned PASS.'
}.freeze

DUP_BACKLOG = %w[
  assert-doctor-ran.rb build-charts-from-signals.rb build-dashboard-layout.rb
  build-shortlist.rb build-workbook-spec.rb column_census.rb dm_quarantine.rb
  layout.rb migration-plan.rb post-and-readback.rb put-layout.rb
  render-readout-html.rb render-readout.rb run_state.rb
  scout-validate-and-persist.rb sigma_functions.rb validate-sigma-formula.rb
  validate-spec.rb verify-complete.rb verify-parity.rb zone_census.rb
].to_set

by_name = {}
Dir.glob('plugins/*/skills/*/scripts/**/*.rb').each do |p|
  b = File.basename(p)
  next if b.start_with?('test-', 'test_')
  (by_name[b] ||= []) << p
end
dupes = by_name.select { |n, ps| ps.size >= 2 && !SHARED_BASENAMES.include?(n) }
new_dupes  = dupes.keys.reject { |n| DUP_BACKLOG.include?(n) || PER_TOOL_BY_DESIGN.key?(n) }
gone       = (DUP_BACKLOG.to_a - dupes.keys).sort   # cleared or no longer duplicated

ok('no NEW unregistered duplicate script name (ratchet over a known backlog)') do
  new_dupes.sort.each do |n|
    ps = dupes[n]
    ident = ps.map { |p| File.read(p) }.uniq.size == 1
    warn "    NEW duplicate #{n}: #{ps.size} copies (#{ident ? 'identical' : 'already diverged'}) in " \
         "#{ps.map { |p| p.split('/')[1] }.join(', ')}"
    warn '      -> register it in shared/manifest.json, or add it to PER_TOOL_BY_DESIGN with a reason'
  end
  new_dupes.empty?
end

ok('the duplicate backlog list is accurate (no stale entries to tighten)') do
  gone.each { |n| warn "    #{n} is no longer an unregistered duplicate — remove it from DUP_BACKLOG (ratchet tightens)" }
  gone.empty?
end

warn "\nnote: #{DUP_BACKLOG.size} acknowledged duplicate-script debts remain (see DUP_BACKLOG above)." if $fail.zero?

puts($fail.zero? ? "\nALL PASS — fan-out targets exist, gates ship their remedies, every shared script loads with its deps, and no new duplicates crept in" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
