#!/usr/bin/env ruby
# frozen_string_literal: true
#
# record-visual-check.rb — record the outcome of the MANDATORY Phase 6f
# full-dashboard source-vs-target visual comparison into parity-final.json, so
# assert-phase6-ran.rb gate 8b (--require-visual-comparison) can confirm the
# comparison actually happened instead of trusting a prose "I looked at it".
#
# Run this AFTER you have rendered the Sigma page (sigma-export-png.py) AND read
# it side-by-side against the source dashboard PNG captured in discovery (Tableau MCP
# get-view-image, Power BI page export, QuickSight StartDashboardSnapshotJob,
# MicroStrategy export-dossier-pdf.py, … — whatever this plugin's Phase-1d step
# writes; a customer screenshot dropped at the same path is equally valid):
#
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision true \
#     --verdict pass            --notes "matches source; KPI row + 3 trend tiles aligned"
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision true \
#     --verdict divergent       --notes "Region bar truncated vs source — fixing"  [--screenshot <png>]
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> --agent-vision false \
#     --verdict not-executable  --notes "driving agent has no image input"
#
# It does NOT judge for you — it records the verdict YOU reached. `pass` stamps
# visual_checked:true; `divergent` records the gap (visual_checked stays false).
# A recorded divergent verdict passes gate 8b as RECORDED, but the divergence is
# BUDGET-COUNTED: the gate injects `visual-divergent` into the waiver census
# (exit-19 doctrine), so GREEN requires the budget to hold — fix the gaps and
# re-record `pass`, or accept YELLOW. (Verdict-capping divergent → PARTIAL is
# PLAN-v3 PR-14.)
#
# VISION PRECONDITION (SKILL_IMPROVEMENT_PLAN_V3 §D5): a pixel-fidelity verdict
# requires an agent that actually READ the render. --agent-vision true|false is
# required (env AGENT_VISION accepted as a fallback source):
#   --agent-vision false + --verdict pass  → REFUSED (exit 2, nothing written).
#     Record --verdict not-executable instead, or re-run the visual loop from a
#     vision-capable session (Claude Code with image input).
#   --verdict not-executable (--notes mandatory) → stamps visual_checked:false,
#     visual_verdict:"not-executable", agent_vision:false — gate 8b then fails
#     with the named degradation instead of accepting a blind attestation.
#   Every verdict stamps `agent_vision` into parity-final.json.
# Back-compat: omitting --agent-vision entirely warns LOUDLY and assumes true
# (existing callers keep working) — that default is deprecated; pass the flag.
#
# BLIND-GRADER PRECONDITION (PLAN-v3 PR-9): a `pass` verdict additionally
# REQUIRES `--blind-grade <path>` — a blind-grade.json written by a FRESH,
# CONTEXT-FREE subagent that received ONLY the source PNG + render PNG + the
# rubric (refs/blind-grader-brief.md). Field failure: the builder self-graded
# its own workbook 6/6 PASS on visuals the customer rejected — the builder's
# eye is not the verdict. The grade is validated here (parses, every checklist
# dimension present, sha256-BOUND to the actual image files on disk — hashes
# recomputed, never trusted) and its per-tile chart-family readings are
# cross-checked against the mechanical kind census (wb-readback.json /
# png-read.json) so a fabricated grade is refused as inconsistent. A builder
# `pass` over a FAILING blind grade is refused. The ONLY escape, for sessions
# that cannot spawn a vision-capable context-free grader: --no-vision-waiver
# "<reason>" — recorded into parity-final.json and COUNTED against the gate's
# waiver budget (never silent).
require 'json'
require_relative 'lib/cli_encoding'
require_relative 'lib/blind_grade'
require 'optparse'

VERDICTS = %w[pass divergent not-executable].freeze
# v5.3 STYLE CHECKLIST (round-5 owner-eye consensus dimensions). A gestalt
# "pass" repeatedly shipped exposed chrome, broken palettes, and decomposed
# layouts that an exacting owner rejected — the verdict must now attest each
# dimension separately, judged against the SOURCE image, not the intent.
CHECKLIST_KEYS = %w[element_titles_hidden palette_match composition_match
                    chart_shapes_match labels_legible numbers_formatted].freeze
CHECKLIST_VALS = %w[pass fail na].freeze

opts = {}
# optparse special-cases any long flag starting with "--no-" as the boolean
# negation of the bare flag (value false, argument dropped) — extract the
# no-vision waiver + its REQUIRED reason from ARGV before parsing. The p.on
# entry below stays for --help; its callback is a no-op after this scan.
if (_nv_i = ARGV.index('--no-vision-waiver'))
  _nv_reason = ARGV[_nv_i + 1]
  if _nv_reason.nil? || _nv_reason.start_with?('--')
    abort 'FATAL: --no-vision-waiver requires a reason argument (WHY could no vision-capable grader be spawned?).'
  end
  opts[:no_vision_waiver] = _nv_reason
  ARGV.slice!(_nv_i, 2)
elsif (_nv_kv = ARGV.find { |a| a.start_with?('--no-vision-waiver=') })
  opts[:no_vision_waiver] = _nv_kv.split('=', 2)[1]
  ARGV.delete(_nv_kv)
end
OptionParser.new do |p|
  p.on('--workdir DIR')   { |v| opts[:dir] = v }
  p.on('--verdict V', VERDICTS, 'pass = render matches the source; divergent = a gap remains (gate stays blocked); not-executable = the visual loop could not run (vision-less agent) — --notes required, gate 8b fails with a named degradation') { |v| opts[:verdict] = v }
  p.on('--notes S')       { |v| opts[:notes] = v }
  p.on('--screenshot P')  { |v| opts[:shot] = v }
  p.on('--blind-grade P', 'REQUIRED with --verdict pass: path to blind-grade.json written by a FRESH context-free ' \
                          'grader subagent (refs/blind-grader-brief.md) that received ONLY the two image paths + ' \
                          'the rubric. Validated + sha256-bound here; a failing blind grade refuses a builder pass.') { |v| opts[:blind_grade] = v }
  p.on('--no-vision-waiver R', 'escape ONLY for sessions that cannot spawn a vision-capable context-free grader ' \
                               '(Agent tool unavailable / subagents lack image input): records a blind_grade_waiver ' \
                               'into parity-final.json that COUNTS against the gate waiver budget — never silent. ' \
                               'The driving agent must still have read the render itself (--agent-vision true).') { |v| opts[:no_vision_waiver] = v if v.is_a?(String) }
  p.on('--agent-vision B', %w[true false], 'REQUIRED: can the driving agent actually read images? (env AGENT_VISION accepted as fallback)') { |v| opts[:vision] = (v == 'true') }
  p.on('--checklist S', "REQUIRED with --verdict pass: 'k=pass|fail|na,...' covering #{CHECKLIST_KEYS.join(', ')} — " \
                        'each judged against the SOURCE image (element_titles_hidden = no exposed/truncated element-title ' \
                        'chrome the source hides; palette_match = series/background/accent colors match the source swatches; ' \
                        'composition_match = same canvas grid/proportions, section headers adjacent to their charts, no dead ' \
                        'zones; chart_shapes_match = every tile same chart family + encoding; labels_legible = no truncated/' \
                        'clipped labels or leaked control stubs; numbers_formatted = value formats as printed in the source)') do |v|
    pairs = v.split(',').map(&:strip).reject(&:empty?)
    bad = pairs.reject { |kv| kv.include?('=') }
    abort "FATAL: --checklist entries need key=value (bad: #{bad.join(', ')})" if bad.any?
    opts[:checklist] = pairs.map { |kv| kv.split('=', 2).map(&:strip) }.to_h
  end
end.parse!

# checklist keys/values are validated for EVERY verdict that carries one — a
# divergent record feeds the fix loop and must not stamp junk (v5.3.1).
if opts[:checklist]
  missing_v = opts[:checklist].reject { |_k, v| CHECKLIST_VALS.include?(v) }
  abort "FATAL: --checklist value(s) must be pass|fail|na: #{missing_v.keys.join(', ')}" if missing_v.any?
  unknown_k = opts[:checklist].keys - CHECKLIST_KEYS
  abort "FATAL: --checklist unknown key(s): #{unknown_k.join(', ')} (want: #{CHECKLIST_KEYS.join(', ')})" if unknown_k.any?
end

abort 'FATAL: --workdir required' unless opts[:dir]
abort "FATAL: --verdict #{VERDICTS.join('|')} required" unless opts[:verdict]

# --agent-vision: flag > env AGENT_VISION > (deprecated) assume-true.
if opts[:vision].nil? && !ENV['AGENT_VISION'].to_s.strip.empty?
  ev = ENV['AGENT_VISION'].to_s.strip.downcase
  abort "FATAL: AGENT_VISION must be true|false (got #{ENV['AGENT_VISION'].inspect})" unless %w[true false].include?(ev)
  opts[:vision] = (ev == 'true')
end
if opts[:vision].nil?
  warn '=' * 74
  warn 'WARN: --agent-vision not given (and AGENT_VISION unset) — ASSUMING true so'
  warn '      existing callers keep working. This default is DEPRECATED: a visual'
  warn '      verdict from an agent that cannot read images is a blind attestation.'
  warn '      Pass --agent-vision true|false explicitly (SKILL_IMPROVEMENT_PLAN_V3 §D5).'
  warn '=' * 74
  opts[:vision] = true
end

if opts[:verdict] == 'pass' && !opts[:vision]
  warn 'REFUSED: a pass verdict requires an agent that actually read the render. ' \
       'Record --verdict not-executable instead, or re-run the visual loop from a ' \
       'vision-capable session (Claude Code with image input).'
  exit 2
end
if opts[:verdict] == 'not-executable' && opts[:notes].to_s.strip.empty?
  abort 'FATAL: --verdict not-executable requires --notes (say WHY the visual loop could not run).'
end
# v5.3: a PASS must attest every style dimension; any 'fail' means the render
# does NOT match the source — record divergent and fix instead.
if opts[:verdict] == 'pass'
  cl = opts[:checklist]
  if cl.nil?
    warn 'REFUSED: --verdict pass now requires --checklist (round-5: gestalt passes shipped exposed'
    warn "         chrome/broken palettes an exacting owner rejected). Provide all of:"
    warn "         --checklist \"#{CHECKLIST_KEYS.map { |k| "#{k}=pass" }.join(',')}\""
    warn '         judging each against the SOURCE image; use fail/na honestly (fail ⇒ record divergent).'
    exit 2
  end
  missing = CHECKLIST_KEYS - cl.keys
  bad_vals = cl.reject { |_k, v| CHECKLIST_VALS.include?(v) }
  abort "FATAL: --checklist missing key(s): #{missing.join(', ')}" if missing.any?
  abort "FATAL: --checklist value(s) must be pass|fail|na: #{bad_vals.keys.join(', ')}" if bad_vals.any?
  fails = cl.select { |k, v| CHECKLIST_KEYS.include?(k) && v == 'fail' }.keys
  if fails.any?
    warn "REFUSED: checklist marks #{fails.join(', ')} = fail — that is a DIVERGENT render, not a pass."
    warn '         Record --verdict divergent with the same checklist, fix, re-render, re-judge.'
    exit 2
  end
  # W1.4 contradiction guard: a PASS must not contradict the machine signal. If
  # verify-anchors measured empty DISPLAYED tiles (charts return no rows), a
  # "pass" is a false attestation over a "No data" render — the exact 2026-07
  # move (record-visual-check PASS + 6x-pass checklist over a dataless render).
  av_path = File.join(opts[:dir], 'anchors-verdict.json')
  if File.exist?(av_path)
    av = (JSON.parse(File.read(av_path)) rescue nil)
    if av.is_a?(Hash) && av.key?('tiles_all_nonempty') && av['tiles_all_nonempty'] != true
      empty = Array(av['dashboard_tiles_empty'])
      warn "REFUSED: cannot record a visual PASS — verify-anchors measured #{empty.length} displayed tile(s)"
      warn '         that export ZERO data rows (the charts render "No data"):'
      empty.first(8).each { |t| warn "           #{t['id']} #{t['name'].inspect} [#{t['kind']}]" }
      warn '         A visual "pass" over a dataless render is a false attestation. Fix the data path'
      warn '         (filter literal / calc types), re-run verify-anchors.rb, then re-judge. A genuinely'
      warn '         empty SOURCE chart is waived at the gate (--allow-empty-tiles), never by a pass here.'
      exit 2
    end
  end
end

# ── PR-9: blind-grader precondition for a PASS ───────────────────────────────
# The builder's own eye (the checklist above) is necessary but NOT sufficient:
# a pass verdict must be countersigned by a context-free blind grade.
blind_stamp = nil
waiver_stamp = nil
if opts[:no_vision_waiver] && opts[:verdict] != 'pass'
  abort 'FATAL: --no-vision-waiver only applies to --verdict pass (other verdicts need no blind grade).'
end
if opts[:blind_grade] && opts[:no_vision_waiver]
  abort 'FATAL: --blind-grade and --no-vision-waiver are mutually exclusive — a grade exists, so no waiver applies.'
end
if opts[:no_vision_waiver] && opts[:no_vision_waiver].to_s.strip.empty?
  abort 'FATAL: --no-vision-waiver requires a non-empty reason (WHY could no vision-capable grader be spawned?).'
end
if opts[:verdict] == 'pass' && opts[:blind_grade].nil? && opts[:no_vision_waiver].nil?
  warn 'REFUSED: --verdict pass now requires --blind-grade <path> (PLAN-v3 PR-9). The visual verdict'
  warn '         must come from a CONTEXT-FREE grader, not the builder: a field run self-graded its own'
  warn '         workbook 6/6 PASS on visuals the customer rejected. The blind flow:'
  warn '           1. Spawn a FRESH subagent with refs/blind-grader-brief.md as its prompt, giving it'
  warn '              ONLY the source dashboard PNG path, the Sigma render PNG path, the rubric path'
  warn '              (refs/fidelity-rubric.md), and an output path — NO wb-spec, NO run history, NO'
  warn '              builder context.'
  warn '           2. It Reads both images and writes blind-grade.json (sha256-bound, per-dimension'
  warn '              verdicts, per-tile chart families, top gaps).'
  warn '           3. Re-run this exact command with --blind-grade <workdir>/blind-grade.json.'
  warn '         If the blind grade FAILS, the render diverges — record --verdict divergent and fix.'
  warn '         Escape ONLY when no vision-capable context-free grader can be spawned in this session:'
  warn '         --no-vision-waiver "<reason>" (recorded + counted against the waiver budget, never silent).'
  exit 2
end
if opts[:blind_grade]
  res = BlindGrade.load_and_validate(opts[:blind_grade], workdir: opts[:dir])
  if res['errors'].any?
    warn "REFUSED: blind grade #{opts[:blind_grade]} is invalid — a pass cannot rest on it:"
    res['errors'].each { |e| warn "         - #{e}" }
    warn '         Re-run the context-free grader (refs/blind-grader-brief.md) against the CURRENT images'
    warn '         and re-record. Nothing was written.'
    exit 2
  end
  grade = res['doc']
  dim_fails = grade['dimensions'].select { |_k, v| v['verdict'].to_s == 'fail' }.keys
  if opts[:verdict] == 'pass' && (grade['verdict'] != 'pass' || dim_fails.any?)
    warn "REFUSED: the blind grader's verdict is FAIL#{dim_fails.any? ? " (failing: #{dim_fails.join(', ')})" : ''} —"
    warn '         a builder pass over a failing blind grade is exactly the self-grading escape this'
    warn '         flow closes. Top gaps from the blind grade:'
    Array(grade['top_gaps']).first(3).each { |g| warn "           - #{g}" }
    warn '         Record --verdict divergent, fix the gaps, re-render, re-run the blind grader, then'
    warn '         re-record pass with the new grade. Nothing was written.'
    exit 2
  end
  # Anti-gaming cross-check: the grader's per-tile family readings must agree
  # with the mechanical kind census. >MAX_FAMILY_MISMATCHES contradictions on
  # either side = the families were not read off the images → fabricated grade.
  cross = {}
  { 'target' => BlindGrade.census_from_readback(File.join(opts[:dir], 'wb-readback.json')),
    'source' => BlindGrade.census_from_png_read(File.join(opts[:dir], 'png-read.json')) }.each do |side, census|
    if census.nil? || census.empty?
      cross[side] = 'skipped (no mechanical census artifact)'
      next
    end
    cc = BlindGrade.cross_check(grade['per_tile'], census, side)
    if cc['mismatches'] > BlindGrade::MAX_FAMILY_MISMATCHES
      warn "REFUSED: blind grade INCONSISTENT with the mechanical kind census — its #{side}_family readings"
      warn "         contradict #{side == 'target' ? 'wb-readback.json' : 'png-read.json'} on #{cc['mismatches']} tile(s) " \
           "(tolerance: #{BlindGrade::MAX_FAMILY_MISMATCHES})."
      warn "         blind:  #{cc['blind'].sort.map { |f, n| "#{n}x#{f}" }.join(', ')}"
      warn "         census: #{cc['census'].sort.map { |f, n| "#{n}x#{f}" }.join(', ')}"
      warn '         A grade whose chart families do not match what is mechanically on the page was not'
      warn '         read off these images (fabricated or stale). Re-run the context-free grader against'
      warn '         the CURRENT render. Nothing was written.'
      exit 2
    end
    cross[side] = "ok (#{cc['mismatches']} of #{census.length} tile(s) tolerated-mismatch)"
  end
  bg_path = opts[:blind_grade]
  bg_rel  = bg_path.start_with?(File.join(opts[:dir], '')) ? bg_path[(File.join(opts[:dir], '').length)..-1] : bg_path
  blind_stamp = {
    'path'           => bg_rel,
    'source_sha256'  => grade['source_sha256'].to_s.downcase,
    'target_sha256'  => grade['target_sha256'].to_s.downcase,
    'verdict'        => grade['verdict'],
    'dimensions'     => grade['dimensions'].map { |k, v| [k, v['verdict']] }.to_h,
    'per_tile_count' => Array(grade['per_tile']).length,
    'top_gaps'       => Array(grade['top_gaps']).first(3),
    'cross_check'    => cross,
    'recorded_at'    => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  }
elsif opts[:no_vision_waiver]
  waiver_stamp = { 'kind' => 'no-vision-grader', 'reason' => opts[:no_vision_waiver].strip,
                   'recorded_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
end

path = File.join(opts[:dir], 'parity-final.json')
unless File.exist?(path)
  warn "FATAL: #{path} not found — the visual verdict records ONTO the parity result, so finalize must run first:"
  # Each converter names its own parity script (phase6-parity.rb,
  # phase6-parity-quicksight.rb, …) and its own source flag, so point at the
  # plugin's finalize step generically rather than hard-coding one tool's CLI.
  warn "  ruby scripts/phase6-parity*.rb --workdir #{opts[:dir]} --finalize   (this plugin's Phase-6/7 finalize step)"
  warn '  then re-run this exact record-visual-check command. (Field-caught ordering friction, run 2 ~2 min.)'
  exit 1
end

s = JSON.parse(File.read(path))
s['visual_verdict']  = opts[:verdict]
s['visual_notes']    = opts[:notes] if opts[:notes]
s['visual_checked']  = (opts[:verdict] == 'pass')
s['screenshot_path'] = opts[:shot] if opts[:shot]
s['style_checklist'] = opts[:checklist] if opts[:checklist]
s['blind_grade'] = blind_stamp if blind_stamp
s['blind_grade_waiver'] = waiver_stamp if waiver_stamp
# not-executable means the driving agent could not read the render — stamp
# agent_vision:false regardless of the flag so gate 8b sees the degradation.
s['agent_vision']    = opts[:verdict] == 'not-executable' ? false : opts[:vision]
File.write(path, JSON.pretty_generate(s))

case opts[:verdict]
when 'pass'
  puts "[OK] recorded visual comparison: PASS#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
  if blind_stamp
    puts "     blind grade: PASS (#{blind_stamp['path']}; sha-bound src=#{blind_stamp['source_sha256'][0, 12]}… " \
         "tgt=#{blind_stamp['target_sha256'][0, 12]}…; cross-check target=#{blind_stamp['cross_check']['target']}, " \
         "source=#{blind_stamp['cross_check']['source']})"
  else
    warn '=' * 74
    warn 'WARN: pass recorded under a NO-VISION-GRADER WAIVER — no context-free blind'
    warn "      grade backs this verdict (reason: #{waiver_stamp['reason']})."
    warn '      This waiver COUNTS against the gate waiver budget and MUST be named in'
    warn '      the migration report. Prefer re-running from a session that can spawn a'
    warn '      vision-capable grader (refs/blind-grader-brief.md).'
    warn '=' * 74
  end
  puts "     parity-final.json now satisfies assert-phase6-ran.rb gate 8b."
when 'divergent'
  puts "[RECORDED] visual comparison: DIVERGENT#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
  warn '     recorded divergent: gate 8b passes as RECORDED, but the divergence is BUDGET-COUNTED —'
  warn '     assert-phase6-ran.rb injects it into the waiver census as `visual-divergent` (exit-19'
  warn '     doctrine): GREEN requires the budget to hold. Fix the gaps, re-render, re-read, then'
  warn '     re-record --verdict pass — or accept YELLOW with the divergence named in the report.'
  warn '     (Full verdict-capping — divergent caps the run at PARTIAL — is PLAN-v3 PR-14.)'
else # not-executable
  puts "[RECORDED] visual comparison: NOT-EXECUTABLE — #{opts[:notes]}"
  warn '     visual_checked stays FALSE, agent_vision=false — gate 8b will fail with'
  warn '     "visual gate not executable" until the RCF/visual loop is re-run from a'
  warn '     vision-capable session (Claude Code with image input) and a pass verdict'
  warn '     is recorded, or the gate is explicitly waived (--skip-visual-comparison "<reason>").'
end
