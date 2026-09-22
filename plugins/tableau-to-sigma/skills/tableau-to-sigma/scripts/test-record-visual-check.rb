#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for record-visual-check.rb's vision precondition (§D5) and
# the PR-9 blind-grader precondition.
#
# Gate 8/8b used to prove only that a PNG exists and a verdict was recorded —
# an agent WITHOUT image input could still "record" pass (a blind attestation).
# Now --agent-vision true|false is required (env AGENT_VISION as fallback):
#   - vision=false + pass       → REFUSED, exit nonzero, parity-final untouched
#   - not-executable            → --notes mandatory; stamps visual_checked:false,
#                                 visual_verdict:"not-executable", agent_vision:false
#   - every verdict             → stamps agent_vision
#   - flag omitted entirely     → loud deprecation WARN + assume true (back-compat)
#
# PR-9 (blind visual grader): a pass additionally requires --blind-grade — a
# blind-grade.json from a CONTEXT-FREE subagent, validated (all six dimensions),
# sha256-BOUND to the actual image files (hashes recomputed), cross-checked
# against the mechanical kind census, and REFUSED when the blind verdict is
# fail. The only escape is --no-vision-waiver "<reason>" (budget-counted).
#
# Usage:  ruby scripts/test-record-visual-check.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'digest'
require_relative 'lib/blind_fixture'

SCRIPT = File.join(__dir__, 'record-visual-check.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

CL = 'element_titles_hidden=pass,palette_match=pass,composition_match=pass,' \
     'chart_shapes_match=pass,labels_legible=pass,numbers_formatted=pass'

# Fresh workdir with a minimal parity-final.json per case. blind: :valid
# installs a hash-bound passing blind-grade fixture and appends --blind-grade;
# a Proc receives the dir and returns extra args (custom fixtures/tampering).
def run_case(args, env: {}, blind: nil)
  Dir.mktmpdir('rvc-test') do |dir|
    pf = File.join(dir, 'parity-final.json')
    File.write(pf, JSON.pretty_generate('status' => 'PASS', 'charts_total' => 3, 'charts_pass' => 3))
    extra = []
    case blind
    when :valid
      BlindFixture.install(dir, stamp: false)
      extra = ['--blind-grade', File.join(dir, 'blind-grade.json')]
    when Proc
      extra = Array(blind.call(dir))
    end
    clean_env = { 'AGENT_VISION' => nil }.merge(env)
    out, err, st = Open3.capture3(clean_env, RbConfig.ruby, SCRIPT, '--workdir', dir, *args, *extra)
    [out, err, st, JSON.parse(File.read(pf))]
  end
end

# --- pass + vision true + valid blind grade → exit 0, stamps ------------------
out, _err, st, pf = run_case(%w[--verdict pass --agent-vision true --notes ok] + ['--checklist', CL], blind: :valid)
check(st.success?, 'pass + --agent-vision true + valid blind grade → exit 0', fails)
check(pf['visual_checked'] == true && pf['visual_verdict'] == 'pass', 'pass stamps visual_checked:true', fails)
check(pf['agent_vision'] == true, 'pass stamps agent_vision:true', fails)
check(out.include?('[OK]'), 'pass prints [OK]', fails)
check(pf['blind_grade'].is_a?(Hash) && pf['blind_grade']['verdict'] == 'pass',
      'pass stamps blind_grade metadata', fails)
check(pf['blind_grade']['source_sha256'].to_s =~ /\A[0-9a-f]{64}\z/ &&
        pf['blind_grade']['target_sha256'].to_s =~ /\A[0-9a-f]{64}\z/,
      'blind_grade stamp carries both 64-hex sha256s', fails)
check(BlindFixture::KEYS.all? { |k| pf['blind_grade']['dimensions'][k] == 'pass' },
      'blind_grade stamp carries all six dimension verdicts', fails)
check(out.include?('blind grade: PASS') && out.include?('sha-bound'),
      'pass output names the sha-bound blind grade', fails)

# --- pass + vision false → REFUSED, nothing written --------------------------
_out, err, st, pf = run_case(%w[--verdict pass --agent-vision false --notes blind])
check(!st.success?, 'pass + --agent-vision false → exits NONZERO', fails)
check(err.include?('REFUSED: a pass verdict requires an agent that actually read the render'),
      'refusal message names the vision requirement', fails)
check(err.include?('not-executable') && err.include?('vision-capable session'),
      'refusal points at not-executable + a vision-capable session', fails)
check(!pf.key?('visual_verdict') && !pf.key?('agent_vision'),
      'refusal writes NOTHING into parity-final.json', fails)

# --- env AGENT_VISION=false is honored as the fallback source ----------------
_out, err, st, pf = run_case(%w[--verdict pass --notes blind], env: { 'AGENT_VISION' => 'false' })
check(!st.success? && err.include?('REFUSED'), 'env AGENT_VISION=false + pass → refused', fails)
check(!pf.key?('agent_vision'), 'env-refused run writes nothing', fails)

# ...and the flag beats the env
_out, _err, st, pf = run_case((%w[--verdict pass --agent-vision true] + ['--checklist', CL]),
                              env: { 'AGENT_VISION' => 'false' }, blind: :valid)
check(st.success? && pf['agent_vision'] == true, '--agent-vision flag overrides AGENT_VISION env', fails)

# --- not-executable: notes mandatory, stamps the degradation -----------------
_out, err, st, pf = run_case(%w[--verdict not-executable --agent-vision false])
check(!st.success? && err.include?('--notes'), 'not-executable without --notes → fatal', fails)

_out, err, st, pf = run_case(['--verdict', 'not-executable', '--agent-vision', 'false',
                              '--notes', 'agent lacks image input'])
check(st.success?, 'not-executable + notes → exit 0 (recorded; gate blocks downstream)', fails)
check(pf['visual_checked'] == false, 'not-executable stamps visual_checked:false', fails)
check(pf['visual_verdict'] == 'not-executable', 'not-executable stamps visual_verdict', fails)
check(pf['agent_vision'] == false, 'not-executable stamps agent_vision:false', fails)
check(err.include?('visual gate not executable') || err.include?('vision-capable session'),
      'not-executable output names the gate-8b consequence', fails)

# not-executable forces agent_vision:false even if the caller claims true
_out, _err, st, pf = run_case(['--verdict', 'not-executable', '--agent-vision', 'true',
                               '--notes', 'render loop unavailable'])
check(st.success? && pf['agent_vision'] == false,
      'not-executable stamps agent_vision:false even with --agent-vision true', fails)

# --- divergent + vision false: recordable, stamped ----------------------------
_out, _err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'false',
                               '--notes', 'cannot confirm'])
check(st.success? && pf['visual_checked'] == false && pf['agent_vision'] == false,
      'divergent + vision false → recorded with agent_vision:false (gate 8b blocks)', fails)

# --- divergent message states the REAL gate consequence (D3 doc/behavior fix) --
# The old message claimed "gate 8b will still BLOCK" — false: a recorded
# divergent verdict passes 8b as RECORDED and is budget-counted instead.
_out, err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true',
                              '--notes', 'Region bar truncated vs source'])
check(st.success? && pf['visual_verdict'] == 'divergent' && pf['visual_checked'] == false,
      'divergent recorded: stamps verdict, visual_checked stays false', fails)
check(err.include?('passes as RECORDED'),
      'divergent message states gate 8b passes as RECORDED (never claims it blocks)', fails)
check(!err.include?('will still BLOCK'),
      'divergent message no longer makes the false will-still-BLOCK claim', fails)
check(err.include?('visual-divergent') && err.include?('BUDGET-COUNTED'),
      'divergent message names the visual-divergent census injection + budget cost', fails)
check(err.include?('YELLOW') && err.include?('budget to hold'),
      'divergent message states the choice: fix the gaps or accept YELLOW', fails)
check(err.include?('PR-14'),
      'divergent message carries the PR-14 verdict-capping forward pointer', fails)

# --- back-compat: omitted flag → loud WARN + assume true ----------------------
_out, err, st, pf = run_case(%w[--verdict pass --notes legacy-caller] + ['--checklist', CL], blind: :valid)
check(st.success?, 'omitted --agent-vision → still exit 0 (back-compat)', fails)
check(pf['agent_vision'] == true && pf['visual_checked'] == true, 'omitted flag assumes agent_vision:true', fails)
check(err.include?('DEPRECATED') && err.include?('--agent-vision'),
      'omitted flag prints the loud deprecation warning', fails)

# --- bad values rejected -------------------------------------------------------
_out, _err, st, _pf = run_case(%w[--verdict pass --agent-vision maybe])
check(!st.success?, '--agent-vision maybe → rejected by the option parser', fails)


# --- v5.3 style checklist contract ---------------------------------------------
_out, err, st, pf = run_case(%w[--verdict pass --agent-vision true --notes x], blind: :valid)
check(!st.success? && err.include?('--checklist'), 'pass WITHOUT checklist → refused naming --checklist', fails)
check(!pf.key?('visual_verdict'), 'checklist refusal writes nothing', fails)
_out, err, st, pf = run_case(['--verdict', 'pass', '--agent-vision', 'true',
                              '--checklist', CL.sub('palette_match=pass', 'palette_match=fail')], blind: :valid)
check(!st.success? && err.include?('palette_match'), 'checklist fail dimension → pass refused, names it', fails)
_out, _err, st, pf = run_case(['--verdict', 'pass', '--agent-vision', 'true', '--checklist',
                               CL.sub('numbers_formatted=pass', 'numbers_formatted=na')], blind: :valid)
check(st.success? && pf['style_checklist']['numbers_formatted'] == 'na',
      'na dimension accepted + checklist stamped', fails)
_out, err, st, _pf = run_case(['--verdict', 'pass', '--agent-vision', 'true',
                               '--checklist', 'palette_match=pass'], blind: :valid)
check(!st.success? && err.include?('missing key'), 'incomplete checklist → fatal naming missing keys', fails)
_out, _err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true', '--notes', 'gaps',
                               '--checklist', CL.sub('palette_match=pass', 'palette_match=fail')])
check(st.success? && pf['style_checklist']['palette_match'] == 'fail',
      'divergent records a failing checklist for the fix loop', fails)

# =============================================================================
# PR-9 — blind-grader precondition
# =============================================================================
PASS_ARGS = %w[--verdict pass --agent-vision true --notes ok] + ['--checklist', CL]

# pass WITHOUT --blind-grade and WITHOUT the waiver → refused, flow explained
_out, err, st, pf = run_case(PASS_ARGS)
check(!st.success?, 'pass without --blind-grade → REFUSED (exit nonzero)', fails)
check(err.include?('--blind-grade') && err.include?('blind-grader-brief'),
      'refusal explains the blind flow (brief + --blind-grade)', fails)
check(err.include?('CONTEXT-FREE') || err.include?('context-free'),
      'refusal names the context-free grader requirement', fails)
check(err.include?('--no-vision-waiver') && err.include?('waiver budget'),
      'refusal names the only escape + its budget cost', fails)
check(!pf.key?('visual_verdict') && !pf.key?('blind_grade'), 'blind refusal writes nothing', fails)

# hash mismatch: image tampered AFTER grading → refused
tamper = lambda do |dir|
  BlindFixture.install(dir, stamp: false)
  File.binwrite(File.join(dir, 'sigma-render.png'), BlindFixture.png_bytes('X'))
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
end
_out, err, st, pf = run_case(PASS_ARGS, blind: tamper)
check(!st.success? && err.include?('target_sha256 does NOT match'),
      'render changed after grading (sha mismatch) → refused naming the binding', fails)
check(!pf.key?('blind_grade'), 'hash-mismatch refusal writes nothing', fails)

# fabricated shas (never computed from the files) → refused
fake_sha = lambda do |dir|
  g = BlindFixture.install(dir, stamp: false)
  g['source_sha256'] = 'a' * 64
  File.write(File.join(dir, 'blind-grade.json'), JSON.pretty_generate(g))
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
end
_out, err, st, _pf = run_case(PASS_ARGS, blind: fake_sha)
check(!st.success? && err.include?('source_sha256 does NOT match'),
      'fabricated source sha → refused (hash recomputed, never trusted)', fails)

# missing dimension → refused naming it
drop_dim = lambda do |dir|
  g = BlindFixture.install(dir, stamp: false)
  g['dimensions'].delete('chart_shapes_match')
  File.write(File.join(dir, 'blind-grade.json'), JSON.pretty_generate(g))
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
end
_out, err, st, _pf = run_case(PASS_ARGS, blind: drop_dim)
check(!st.success? && err.include?('chart_shapes_match'),
      'blind grade missing a checklist dimension → refused naming it', fails)

# blind verdict FAIL + builder pass → refused with the top gaps
_out, err, st, pf = run_case(PASS_ARGS, blind: lambda { |dir|
  BlindFixture.install(dir, stamp: false, verdict: 'fail')
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
})
check(!st.success?, 'builder pass over a FAILING blind grade → refused', fails)
check(err.include?("blind grader's verdict is FAIL") && err.include?('chart_shapes_match'),
      'refusal names the blind fail + failing dimension', fails)
check(err.include?('divergent'), 'refusal routes to --verdict divergent + fix loop', fails)
check(!pf.key?('visual_verdict'), 'blind-fail refusal writes nothing', fails)

# ...but the same failing grade is recordable WITH --verdict divergent
_out, _err, st, pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true', '--notes', 'gaps'],
                              blind: lambda { |dir|
                                BlindFixture.install(dir, stamp: false, verdict: 'fail')
                                ['--blind-grade', File.join(dir, 'blind-grade.json')]
                              })
check(st.success? && pf['blind_grade'].is_a?(Hash) && pf['blind_grade']['verdict'] == 'fail',
      'divergent + failing blind grade → recorded (feeds the fix loop)', fails)

# unparseable / missing grade file → refused
_out, err, st, _pf = run_case(PASS_ARGS, blind: lambda { |dir|
  File.write(File.join(dir, 'blind-grade.json'), '{nope')
  ['--blind-grade', File.join(dir, 'blind-grade.json')]
})
check(!st.success? && err.include?('not valid JSON'), 'malformed blind-grade.json → refused', fails)
_out, err, st, _pf = run_case(PASS_ARGS, blind: ->(dir) { ['--blind-grade', File.join(dir, 'nope.json')] })
check(!st.success? && err.include?('not found'), 'missing blind-grade.json → refused', fails)

# --- anti-gaming: family readings vs the mechanical kind census ---------------
# wb-readback census: 1 kpi + 2 bar. Blind grade reads 1 kpi + 1 bar + 1 line
# → 1 mismatch (tolerated). Reading 1 kpi + 2 line → 2 mismatches (refused).
CENSUS_ELEMENTS = [
  { 'id' => 'e1', 'kind' => 'kpi-chart' },
  { 'id' => 'e2', 'kind' => 'bar-chart' },
  { 'id' => 'e3', 'kind' => 'bar-chart' },
  { 'id' => 'e4', 'kind' => 'control' },          # non-chart: never in the census
  { 'id' => 'e5', 'kind' => 'bar-chart', 'visibleAsSource' => false } # hidden master
].freeze
CENSUS_RB = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'p1', 'name' => 'Dashboard' }],
    'elements' => CENSUS_ELEMENTS,
    'layout' => "<Page id=\"p1\">#{CENSUS_ELEMENTS.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
  }
}.freeze

census_case = lambda do |families|
  lambda do |dir|
    File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(CENSUS_RB))
    tiles = families.each_with_index.map do |f, i|
      { 'position' => "r#{i + 1}c1", 'source_family' => f, 'target_family' => f }
    end
    BlindFixture.install(dir, stamp: false, per_tile: tiles)
    ['--blind-grade', File.join(dir, 'blind-grade.json')]
  end
end

_out, _err, st, pf = run_case(PASS_ARGS, blind: census_case.call(%w[kpi bar line]))
check(st.success?, 'census disagreement on exactly 1 tile → tolerated (accepted)', fails)
check(pf['blind_grade']['cross_check']['target'].to_s.start_with?('ok'),
      'tolerated cross-check recorded in the stamp', fails)

_out, err, st, pf = run_case(PASS_ARGS, blind: census_case.call(%w[kpi line line]))
check(!st.success?, 'census disagreement on 2 tiles → REFUSED as inconsistent', fails)
check(err.include?('INCONSISTENT') && err.include?('wb-readback.json'),
      'anti-gaming refusal names the census contradiction', fails)
check(err.include?('fabricated') || err.include?('stale'),
      'anti-gaming refusal states the fabrication rationale', fails)
check(!pf.key?('blind_grade'), 'anti-gaming refusal writes nothing', fails)

# --- no-vision waiver: recorded + loud, never silent --------------------------
_out, err, st, pf = run_case(PASS_ARGS + ['--no-vision-waiver', 'Agent tool unavailable in this CI session'])
check(st.success?, 'pass + --no-vision-waiver "<reason>" → exit 0 (recorded escape)', fails)
check(pf['blind_grade_waiver'].is_a?(Hash) &&
        pf['blind_grade_waiver']['reason'] == 'Agent tool unavailable in this CI session' &&
        pf['blind_grade_waiver']['kind'] == 'no-vision-grader',
      'waiver stamps blind_grade_waiver {kind, reason}', fails)
check(err.include?('waiver budget') && err.include?('NO-VISION-GRADER'),
      'waiver output is LOUD and names the budget cost', fails)
check(!pf.key?('blind_grade'), 'waived pass carries no blind_grade stamp (honest degradation)', fails)

# waiver misuse rejected
_out, err, st, _pf = run_case(PASS_ARGS + ['--no-vision-waiver', '   '])
check(!st.success? && err.include?('non-empty reason'), 'blank waiver reason → fatal', fails)
_out, err, st, _pf = run_case(['--verdict', 'divergent', '--agent-vision', 'true', '--notes', 'x',
                               '--no-vision-waiver', 'why'])
check(!st.success? && err.include?('only applies to --verdict pass'),
      '--no-vision-waiver with a non-pass verdict → fatal', fails)
_out, err, st, _pf = run_case(PASS_ARGS + ['--no-vision-waiver', 'why'], blind: :valid)
check(!st.success? && err.include?('mutually exclusive'),
      '--blind-grade + --no-vision-waiver together → fatal', fails)

puts
if fails.empty?
  puts 'ALL PASS — record-visual-check vision precondition (§D5) + PR-9 blind-grader precondition'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
