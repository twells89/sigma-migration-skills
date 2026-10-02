#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression tests for assert-phase6-ran.rb's v4 determinism gates:
#
#   gate 13 source anchors (exit 18): a workdir carrying a source dashboard PNG
#     (the Phase 1d artifact) must carry source-anchors.json (>= 5 anchors) AND
#     a passing anchors-verdict.json. Missing/failing/stale → fail. No source
#     PNG → stated SKIP. --skip-anchors-gate waives (counted as a waiver).
#
#   conditional --skip-parity-gate (exit 18): waiving parity is rejected unless
#     anchors-verdict.json exists and passes — the anchors oracle replaces
#     parity, never nothing.
#
#   data-class RCF residuals (exit 15): an unresolved cls=data ledger entry
#     blocks GREEN whenever fidelity-ledger.json exists (even without
#     --require-fidelity-ledger) and --accept-residuals does not apply.
#
#   waiver budget (exit 19): >2 QUALITY waiver/escape flags → GREEN unavailable
#     (YELLOW cap); waivers + waiver_count stamped into parity-final.json on
#     every run. The policy exclusion never consumes the budget:
#     --skip-visual-comparison only under the sanctioned builder→verifier
#     handoff (reason matches /verifier/i).
#
#   gate 14 visual-similarity floor (exit 20): behind File.exist? on
#     scripts/visual-similarity.py (VISUAL_SIMILARITY_SCRIPT env override for
#     tests); verdict read from the JSON `pass` field; --skip-visual-similarity
#     waives (counted).
#
#   E3.1 waivers_history (two-invocation replay): a gate waived on invocation 1
#     appends a gate-waived line to offramps.jsonl; a clean invocation 2 merges
#     it into parity-final.json waivers_history as superseded-by-pass and
#     announces it — the headline count never silently drops to zero. Same-run
#     scoped: another run_id's records never bleed in.
#
# Runs the real script per scenario in a scratch workdir with no SIGMA_* env,
# so the live gates (3/4/6/7) SKIP and the file-based gates are exercised.
#
# Usage:  ruby scripts/test-anchors-waiver-gates.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'digest'
require_relative 'lib/blind_fixture'

SCRIPT = File.join(__dir__, 'assert-phase6-ran.rb')

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A workdir that satisfies every default gate (mirrors test-assert-phase6-gates.rb).
def base_workdir(dir, parity_extra: {})
  parity = { 'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
             'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
             'pass_names' => ['KPI', 'Trend'], 'fail_names' => [],
             'visual_checked' => true, 'visual_verdict' => 'pass', 'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass', 'composition_match' => 'pass', 'chart_shapes_match' => 'pass', 'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
             'agent_vision' => true }.merge(parity_extra)
  File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate(parity))
  File.binwrite(File.join(dir, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  BlindFixture.install(dir) # PR-9: gate 8b refuses a self-attested visual pass
end

def add_source_png(dir)
  Dir.mkdir(File.join(dir, 'views')) unless Dir.exist?(File.join(dir, 'views'))
  File.binwrite(File.join(dir, 'views', 'dash-view.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 100))
end

ANCHORS = {
  'source_image' => 'views/dash-view.png', 'transcribed_at' => '2026-07-08T00:00:00Z',
  'anchors' => (1..5).map { |i| { 'id' => "a#{i}", 'panel' => 'KPI', 'label' => "metric #{i}", 'raw' => "#{i},00#{i}", 'kind' => 'number' } }
}.freeze

def add_anchors(dir, verdict: nil, n: 5)
  a = JSON.parse(JSON.generate(ANCHORS))
  a['anchors'] = a['anchors'].first(n)
  File.write(File.join(dir, 'source-anchors.json'), JSON.pretty_generate(a))
  return unless verdict
  File.write(File.join(dir, 'anchors-verdict.json'), JSON.pretty_generate(verdict))
end

PASS_VERDICT = { 'checked' => 5, 'matched' => 5, 'missing' => [], 'pass' => true }.freeze
FAIL_VERDICT = { 'checked' => 5, 'matched' => 3, 'pass' => false,
                 'missing' => [{ 'id' => 'a1', 'label' => 'metric 1', 'raw' => '1,001',
                                 'best_candidate' => { 'value' => 999_999.0, 'element' => 'KPI Row' } },
                               { 'id' => 'a2', 'label' => 'metric 2', 'raw' => '2,002', 'best_candidate' => nil }] }.freeze

def run_gate(dir, *args, env_extra: {})
  env = { 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }.merge(env_extra)
  Open3.capture3(env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args)
end

def write_fidelity_ledger(dir, ledger)
  bound = JSON.parse(JSON.generate(ledger))
  target = File.join(dir, 'sigma-render.png')
  target_sha = Digest::SHA256.file(target).hexdigest
  bound['renders'] = [{ 'pass' => bound['pass'], 'path' => target }]
  File.write(File.join(dir, 'fidelity-ledger.json'), JSON.pretty_generate(bound))

  parity_path = File.join(dir, 'parity-final.json')
  parity = JSON.parse(File.read(parity_path))
  parity['screenshot_path'] = target
  parity['blind_grade']['fidelity_render'] = {
    'pass' => bound['pass'], 'path' => target, 'sha256' => target_sha
  }
  File.write(parity_path, JSON.pretty_generate(parity))
end

# ---- baseline: no source PNG → anchors gate stated SKIP, exit 0 ---------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, err, st = run_gate(dir)
  check(st.success?, "baseline (no source PNG) → exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})")
  check(out.include?('gate 13') && out.include?('N/A'), 'anchors gate states its SKIP (never silent)')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waiver_count'] == 0 && pf['waivers'] == [], 'zero-waiver run stamps waivers=[] + waiver_count=0')
end

# ---- gate 13: source PNG + no source-anchors.json → exit 18 -------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "source PNG + no anchors file → exit 18 (got #{st.exitstatus})")
  check(err.include?('EXACTLY as'), 'failure restates the transcribe-exactly-as-printed rule')
  check(err.include?('verify-anchors.rb'), 'failure points at the verifier script')
  check(err.include?('--skip-anchors-gate'), 'failure names the escape hatch')
end

# ---- gate 13: < 5 anchors → exit 18 -------------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, n: 3)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "only 3 anchors → exit 18 (got #{st.exitstatus})")
  check(err.include?('3 anchor(s)') && err.include?('>= 5'), 'failure counts the shortfall')
end

# ---- gate 13: anchors present, verdict missing → exit 18 ----------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "no anchors-verdict.json → exit 18 (got #{st.exitstatus})")
  check(err.include?('never verified'), 'failure says the anchors were never verified')
end

# ---- gate 13: verdict FAILS → exit 18 with per-miss report --------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: FAIL_VERDICT)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "failing verdict → exit 18 (got #{st.exitstatus})")
  check(err.include?('"1,001"') && err.include?('999999'), 'per-miss report carries raw + best candidate')
  check(err.include?('loudest'), 'failure explains what a total miss means')
end

# ---- gate 13: STALE verdict (checked < anchors) → exit 18 ---------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT.merge('checked' => 3, 'matched' => 3))
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 18, "stale verdict → exit 18 (got #{st.exitstatus})")
  check(err.include?('STALE'), 'stale verdict is named')
end

# ---- gate 13: passing verdict → exit 0 ----------------------------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  out, _err, st = run_gate(dir)
  check(st.success?, "passing anchors verdict → exit 0 (got #{st.exitstatus})")
  check(out.include?('gate 13') && out.include?('5/5'), 'gate 13 OK line reports matched/checked')
end

# ---- gate 13: --skip-anchors-gate waives AND is counted -----------------------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  out, _err, st = run_gate(dir, '--skip-anchors-gate', 'source image is a low-res scan; values unreadable')
  check(st.success?, "--skip-anchors-gate → exit 0 (got #{st.exitstatus})")
  check(out.include?('WAIVED'), 'anchors waiver is stated loudly')
  waivers = JSON.parse(File.read(File.join(dir, 'waivers.json'))) rescue []
  check(waivers.any? { |w| w['flag'] == '--skip-anchors-gate' }, 'anchors waiver lands in waivers.json')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waivers'] == ['--skip-anchors-gate'] && pf['waiver_count'] == 1,
        'anchors waiver counted + stamped into parity-final.json')
end

# ---- conditional --skip-parity-gate: rejected without a passing verdict -------
Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  _out, err, st = run_gate(dir, '--skip-parity-gate', 'no source workspace access')
  check(st.exitstatus == 18, "--skip-parity-gate without anchors verdict → exit 18 (got #{st.exitstatus})")
  check(err.include?('REJECTED') && err.include?('never nothing'),
        'rejection says the anchors oracle replaces parity, never nothing')
end

Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  out, _err, st = run_gate(dir, '--skip-parity-gate', 'no source workspace access')
  check(st.success?, "--skip-parity-gate WITH passing anchors verdict → exit 0 (got #{st.exitstatus})")
  check(out.include?('anchors oracle stands in'), 'accepted waiver names the stand-in oracle')
end

Dir.mktmpdir do |dir|
  # a FAILING verdict does not unlock --skip-parity-gate
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  add_source_png(dir)
  add_anchors(dir, verdict: FAIL_VERDICT)
  _out, _err, st = run_gate(dir, '--skip-parity-gate', 'no source workspace access')
  check(st.exitstatus == 18, "--skip-parity-gate with FAILING verdict → exit 18 (got #{st.exitstatus})")
end

Dir.mktmpdir do |dir|
  # stacking --skip-anchors-gate on top does NOT unlock --skip-parity-gate
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  add_source_png(dir)
  _out, _err, st = run_gate(dir, '--skip-parity-gate', 'x', '--skip-anchors-gate', 'y')
  check(st.exitstatus == 18, "--skip-parity-gate + --skip-anchors-gate (no verdict) → still exit 18 (got #{st.exitstatus})")
end

# ---- data-class RCF residuals: block even WITHOUT --require-fidelity-ledger ---
DATA_LEDGER = { 'workbook_id' => 'wb', 'page_id' => 'pg', 'max_passes' => 5, 'pass' => 2, 'renders' => [],
                'entries' => [
                  { 'id' => 'e0', 'pass' => 1, 'dimension' => 'KPI/table-values', 'cls' => 'data',
                    'delta' => 'top-list magnitudes 10x off vs source', 'resolved' => false },
                  { 'id' => 'e1', 'pass' => 1, 'dimension' => 'palette', 'cls' => 'ui-only',
                    'delta' => 'accent color drift', 'resolved' => false }
                ] }.freeze

Dir.mktmpdir do |dir|
  base_workdir(dir)
  write_fidelity_ledger(dir, DATA_LEDGER)
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 15, "unresolved data-class delta (no opt-in flag) → exit 15 (got #{st.exitstatus})")
  check(err.include?('can never be waved through') && err.include?('the numbers are wrong'),
        'data-class failure carries the canonical message')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  write_fidelity_ledger(dir, DATA_LEDGER)
  _out, err, st = run_gate(dir, '--accept-residuals', 'e0')
  check(st.exitstatus == 15, "--accept-residuals e0 does NOT accept a data-class id → exit 15 (got #{st.exitstatus})")
  check(err.include?('REJECTED for data-class'), 'the rejected accept is named')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  resolved = JSON.parse(JSON.generate(DATA_LEDGER))
  resolved['entries'][0]['resolved'] = true
  write_fidelity_ledger(dir, resolved)
  _out, _err, st = run_gate(dir)
  check(st.success?, "RESOLVED data-class delta → exit 0 (got #{st.exitstatus})")
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  write_fidelity_ledger(dir, DATA_LEDGER)
  _out, err, st = run_gate(dir, '--require-fidelity-ledger')
  check(st.exitstatus == 15, 'data-class also blocks under --require-fidelity-ledger')
  check(err.include?('data-class'), 'opt-in path names data-class too')
end

# ---- waiver budget: 3 waivers → exit 19 (YELLOW cap); 2 → within budget -------
Dir.mktmpdir do |dir|
  base_workdir(dir)
  _out, err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2', '--skip-control-lint', 'r3')
  check(st.exitstatus == 19, "3 waivers → exit 19 (got #{st.exitstatus})")
  check(err.include?('GREEN unavailable') && err.include?('YELLOW'), 'cap message names the YELLOW ceiling')
  check(err.include?('--skip-orphan-check') && err.include?('--skip-layout-lint') && err.include?('--skip-control-lint'),
        'cap message lists every waiver')
  check(err.include?('orphan workbooks may remain') && err.include?('layout quality never linted'),
        'cap message says what each waiver hid')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waiver_count'] == 3 && pf['waivers'].sort == ['--skip-control-lint', '--skip-layout-lint', '--skip-orphan-check'],
        'capped run still stamps waivers + waiver_count into parity-final.json')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  out, _err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2')
  check(st.success?, "2 waivers → exit 0, within budget (got #{st.exitstatus})")
  check(out.include?('within budget'), 'GREEN clearance names the in-budget waivers')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waiver_count'] == 2, 'in-budget run stamps waiver_count=2')
end

Dir.mktmpdir do |dir|
  # --min-pass-rate <1 and --allow-missing-tiles >0 count as waivers too
  base_workdir(dir)
  _out, err, st = run_gate(dir, '--min-pass-rate', '0.9', '--allow-missing-tiles', '2', '--skip-layout-fill', 'r')
  check(st.exitstatus == 19, "min-pass-rate<1 + allow-missing-tiles>0 + skip → exit 19 (got #{st.exitstatus})")
  check(err.include?('--min-pass-rate') && err.include?('--allow-missing-tiles'),
        'threshold-style escapes are named in the cap message')
end

# ---- POLICY exclusions never consume the budget --------------------------------
Dir.mktmpdir do |dir|
  # --skip-visual-comparison under the sanctioned builder→verifier split
  # (reason references the verifier) does not count...
  base_workdir(dir)
  out, _err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2',
                           '--skip-visual-comparison', 'verifier records the verdict (builder/verifier split)')
  check(st.success?, "2 quality + verifier-handoff --skip-visual-comparison → exit 0 (got #{st.exitstatus})")
  check(out.include?('policy exclusions'), 'verifier-handoff exclusion stated on the WAIVERS line')
end

Dir.mktmpdir do |dir|
  # ...but any OTHER --skip-visual-comparison reason counts as quality.
  base_workdir(dir)
  _out, err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2',
                           '--skip-visual-comparison', 'source image unobtainable')
  check(st.exitstatus == 19, "non-verifier --skip-visual-comparison counts → exit 19 (got #{st.exitstatus})")
  check(err.include?('--skip-visual-comparison'), 'counted visual-comparison waiver named in the cap')
end

# ---- the waiver-STACKING field failure: skip-parity + allow-missing-tiles -----
Dir.mktmpdir do |dir|
  base_workdir(dir, parity_extra: { 'status' => 'FAIL', 'charts_pass' => 0 })
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  # 2 waivers + passing anchors → allowed (but stamped)...
  out, _err, st = run_gate(dir, '--skip-parity-gate', 'x', '--allow-missing-tiles', '6')
  check(st.success?, 'skip-parity (anchors-backed) + allow-missing-tiles = 2 waivers → still exit 0')
  check(out.include?('WAIVERS') || out.include?('waiver'), 'waivers surfaced on stdout')
  # ...a third waiver tips it to YELLOW.
  _out2, err2, st2 = run_gate(dir, '--skip-parity-gate', 'x', '--allow-missing-tiles', '6', '--skip-layout-fill', 'z')
  check(st2.exitstatus == 19, "adding a third waiver → exit 19 (got #{st2.exitstatus})")
  check(err2.include?('values were never diffed against the source'), 'cap explains what skip-parity hid')
end

# ---- E3.1 waivers_history: two-invocation replay (waive, then pass) ----------
# The PLAN-v4 E3.1 acceptance: a waiver forced on invocation 1 (flaky render,
# later retried clean) must never vanish once invocation 2 passes — the
# gate-waived record is APPENDED to offramps.jsonl and merged into
# parity-final.json `waivers_history` as superseded-by-pass, and the headline
# announces it (never a silent zero).
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate('run_id' => 'r-e31'))
  # Invocation 1: gate 2 waived → gate-waived line appended to offramps.jsonl.
  _out1, _err1, st1 = run_gate(dir, '--skip-orphan-check', 'flaky render mid-run')
  check(st1.success?, "invocation 1 (waived) exits 0 (got #{st1.exitstatus})")
  gw = File.readlines(File.join(dir, 'offramps.jsonl')).map { |l| JSON.parse(l) }
           .select { |r| r['kind'] == 'gate-waived' }
  check(gw.length == 1 && gw.first['flag'] == '--skip-orphan-check' &&
        gw.first['gate'] == '2' && gw.first['run_id'] == 'r-e31',
        'gate-waived offramp line appended with flag + gate + run_id')
  check(JSON.parse(File.read(File.join(dir, 'parity-final.json')))['waiver_count'] == 1,
        'invocation 1 stamps waiver_count=1')
  # Invocation 2: same run, no flag → gate passes; the prior waiver must ride
  # into waivers_history as superseded-by-pass, never silently vanish.
  out2, _err2, st2 = run_gate(dir)
  check(st2.success?, "invocation 2 (clean) exits 0 (got #{st2.exitstatus})")
  pf2 = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf2['waivers'] == [] && pf2['waiver_count'] == 0,
        'current census honestly reports zero ACTIVE waivers on invocation 2')
  h = pf2['waivers_history']
  check(h.is_a?(Array) && h.length == 1 && h.first['flag'] == '--skip-orphan-check' &&
        h.first['status'] == 'superseded-by-pass' && pf2['waivers_history_count'] == 1,
        "prior waiver retained in waivers_history as superseded-by-pass (got #{h.inspect[0, 140]})")
  check(out2.include?('waivers_history') && out2.include?('superseded'),
        'headline announces the superseded history — the count never silently drops')
  check(File.readlines(File.join(dir, 'offramps.jsonl')).map { |l| JSON.parse(l) }
            .any? { |r| r['kind'] == 'gate-waived' },
        'the gate-waived offramp record itself is never deleted')
  # Invocation 3 re-waives → the history entry reads active again (no false
  # supersede while the flag is genuinely on).
  _o3, _e3, st3 = run_gate(dir, '--skip-orphan-check', 'still flaky')
  h3 = (JSON.parse(File.read(File.join(dir, 'parity-final.json')))['waivers_history'] || [])
       .find { |x| x['flag'] == '--skip-orphan-check' }
  check(st3.success? && h3 && h3['status'] == 'active',
        "a re-waived flag reads active in the history (got #{h3 && h3['status']})")
end

# A DIFFERENT run's gate-waived records never bleed into this run's history
# (run_id-scoped merge — a fresh run starts a fresh accounting).
Dir.mktmpdir do |dir|
  base_workdir(dir)
  File.write(File.join(dir, 'migrate-state.json'), JSON.generate('run_id' => 'r-new'))
  File.open(File.join(dir, 'offramps.jsonl'), 'a') do |f|
    f.puts(JSON.generate('kind' => 'gate-waived', 'gate' => '2', 'flag' => '--skip-orphan-check',
                         'reason' => 'old run', 'run_id' => 'r-old', 'at' => '2026-07-01T00:00:00Z'))
  end
  _out, _err, st = run_gate(dir)
  check(st.success?, "clean run with only an OLD run's waiver record exits 0 (got #{st.exitstatus})")
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waivers_history'] == [] && pf['waivers_history_count'] == 0,
        "other-run gate-waived records excluded from waivers_history (got #{pf['waivers_history'].inspect[0, 100]})")
end

# ---- gate 14: visual-similarity floor (via VISUAL_SIMILARITY_SCRIPT stub) -----
def write_vsim_stub(dir, pass_value)
  stub = File.join(dir, 'vsim-stub.py')
  File.write(stub, <<~PY)
    import argparse, json
    p = argparse.ArgumentParser()
    p.add_argument('--source'); p.add_argument('--render'); p.add_argument('--json-out')
    a = p.parse_args()
    with open(a.json_out, 'w') as f:
        json.dump({'pass': #{pass_value ? 'True' : 'False'}, 'score': 0.42,
                   'source': a.source, 'render': a.render}, f)
  PY
  stub
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  stub = write_vsim_stub(dir, false)
  _out, err, st = run_gate(dir, env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => stub })
  check(st.exitstatus == 20, "similarity pass=false → exit 20 (got #{st.exitstatus})")
  check(err.include?('score=0.42'), 'failure surfaces the measured score')
  check(err.include?('--skip-visual-similarity'), 'failure names the escape hatch')
  vs = JSON.parse(File.read(File.join(dir, 'visual-similarity.json')))
  check(vs['render'].to_s.end_with?('sigma-render.png'), 'gate passed the resolved render to the scorer')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  stub = write_vsim_stub(dir, true)
  out, _err, st = run_gate(dir, env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => stub })
  check(st.success?, "similarity pass=true → exit 0 (got #{st.exitstatus})")
  check(out.include?('gate 14') && out.include?('score=0.42'), 'gate 14 OK line carries the score')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  stub = write_vsim_stub(dir, false)
  out, _err, st = run_gate(dir, '--skip-visual-similarity', 'no python3 pillow in env',
                           env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => stub })
  check(st.success?, "--skip-visual-similarity → exit 0 (got #{st.exitstatus})")
  check(out.include?('WAIVED'), 'similarity waiver stated loudly')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waivers'].include?('--skip-visual-similarity'), 'similarity waiver counted in the stamp')
end

# ---- gate 14 --tiles wiring (W1.7): dashboard-layout.json → per-tile detector --
# A stub that RECORDS whether --tiles was passed, so the wiring (not the
# detector itself — that's test_visual_similarity_tiles.py) is what's locked.
def write_vsim_tiles_stub(dir)
  stub = File.join(dir, 'vsim-tiles-stub.py')
  File.write(stub, <<~PY)
    import argparse, json
    p = argparse.ArgumentParser()
    p.add_argument('--source'); p.add_argument('--render'); p.add_argument('--json-out')
    p.add_argument('--tiles', default=None)
    a = p.parse_args()
    out = {'pass': True, 'score': 0.9, 'tiles_arg': a.tiles}
    if a.tiles:
        out['tiles_measured'] = 3
        out['tiles_blank'] = []
    with open(a.json_out, 'w') as f:
        json.dump(out, f)
  PY
  stub
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  # A built dashboard layout arms the --tiles pass-through (and gate 8c wants
  # its fill census — provide a passing one so only gate 14 is under test).
  File.write(File.join(dir, 'dashboard-layout.json'), JSON.generate('zones' => []))
  File.write(File.join(dir, 'layout-census.json'),
             JSON.generate('pages' => [{ 'page' => 'Dash', 'zones' => 2, 'placed' => 2, 'grid_fill_pct' => 0.95 }]))
  stub = write_vsim_tiles_stub(dir)
  out, _err, st = run_gate(dir, env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => stub })
  check(st.success?, "tiles wiring run → exit 0 (got #{st.exitstatus})")
  vs = JSON.parse(File.read(File.join(dir, 'visual-similarity.json')))
  check(vs['tiles_arg'].to_s.end_with?('dashboard-layout.json'),
        'gate 14 passes --tiles <workdir>/dashboard-layout.json when it exists')
  check(out.include?('tile(s) measured'), 'gate 14 OK line surfaces the per-tile census')
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_source_png(dir)
  add_anchors(dir, verdict: PASS_VERDICT)
  stub = write_vsim_tiles_stub(dir)
  _out, _err, st = run_gate(dir, env_extra: { 'VISUAL_SIMILARITY_SCRIPT' => stub })
  check(st.success?, "no dashboard-layout.json run → exit 0 (got #{st.exitstatus})")
  vs = JSON.parse(File.read(File.join(dir, 'visual-similarity.json')))
  check(vs['tiles_arg'].nil?, 'no dashboard-layout.json → NO --tiles (no-tiles invocation unchanged)')
end

# ---- runtime off-ramp waivers (offramps.jsonl) consume the budget too ---------
# v4.2: escapes honored MID-RUN by the scripts (--force-new-workbook,
# --force-route-switch, an unauthorized --allow-manual-spec) are recorded to
# <workdir>/offramps.jsonl and counted here exactly like gate flags — otherwise
# a run could stack script-level escapes invisibly under the cap.
def add_offramps(dir, records)
  File.open(File.join(dir, 'offramps.jsonl'), 'a') do |f|
    records.each { |r| f.puts(JSON.generate(r)) }
  end
end

Dir.mktmpdir do |dir|
  base_workdir(dir)
  add_offramps(dir, [
    { 'kind' => 'force-new-workbook', 'reason' => 'demo', 'at' => '2026-07-10T00:00:00Z' },
    { 'kind' => 'route-switch-forced', 'reason' => 'demo', 'at' => '2026-07-10T00:00:01Z' },
    { 'kind' => 'manual-spec', 'reason' => 'waiver: cold hand-author', 'at' => '2026-07-10T00:00:02Z' }
  ])
  _out, err, st = run_gate(dir)
  check(st.exitstatus == 19, "3 runtime off-ramp waivers → exit 19 (got #{st.exitstatus})")
  check(err.include?('--force-new-workbook') && err.include?('--force-route-switch') && err.include?('--allow-manual-spec'),
        'cap message names the runtime pseudo-flags')
  check(err.include?('deliberately orphaned'), 'cap message says what force-new-workbook hid')
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waivers'].sort == ['--allow-manual-spec', '--force-new-workbook', '--force-route-switch'],
        'runtime waivers stamped into the parity-final census')
end

Dir.mktmpdir do |dir|
  # 1 runtime waiver + 2 flag waivers => over budget; 1 runtime + 1 flag => within.
  base_workdir(dir)
  add_offramps(dir, [{ 'kind' => 'force-new-workbook', 'reason' => 'demo', 'at' => '2026-07-10T00:00:00Z' }])
  _out, _err, st = run_gate(dir, '--skip-orphan-check', 'r1', '--skip-layout-lint', 'r2')
  check(st.exitstatus == 19, "1 runtime + 2 flag waivers → exit 19 (got #{st.exitstatus})")
  out2, _err2, st2 = run_gate(dir, '--skip-orphan-check', 'r1')
  check(st2.success?, "1 runtime + 1 flag waiver → exit 0, within budget (got #{st2.exitstatus})")
  check(out2.include?('--force-new-workbook'), 'in-budget runtime waiver still surfaced on the WAIVERS line')
end

Dir.mktmpdir do |dir|
  # NON-waiver off-ramp kinds (pass1-stop, an AUTHORIZED manual-spec, duplicate
  # records of the same kind) never consume the budget.
  base_workdir(dir)
  add_offramps(dir, [
    { 'kind' => 'pass1-stop', 'detail' => 'workbook wb-test', 'at' => '2026-07-10T00:00:00Z' },
    { 'kind' => 'manual-spec', 'reason' => 'authorized-by-stop', 'at' => '2026-07-10T00:00:01Z' },
    { 'kind' => 'force-new-workbook', 'reason' => 'r', 'at' => '2026-07-10T00:00:02Z' },
    { 'kind' => 'force-new-workbook', 'reason' => 'r again', 'at' => '2026-07-10T00:00:03Z' }
  ])
  out, _err, st = run_gate(dir)
  check(st.success?, "informational off-ramps + deduped repeats → exit 0 (got #{st.exitstatus})")
  pf = JSON.parse(File.read(File.join(dir, 'parity-final.json')))
  check(pf['waivers'] == ['--force-new-workbook'],
        'only the real runtime waiver counted, once (authorized manual-spec + pass1-stop excluded)')
end

puts
if $fails.empty?
  puts 'ALL PASS — anchors gate + conditional skip-parity + data-class block + waiver budget + similarity floor + E3.1 waivers_history replay'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |x| puts "  - #{x}" }
  exit 1
end
