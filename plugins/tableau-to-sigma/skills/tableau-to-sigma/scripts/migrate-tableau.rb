#!/usr/bin/env ruby
# frozen_string_literal: true
# migrate-tableau.rb — ONE-SHOT, single-process orchestrator for the
# tableau-to-sigma pipeline. Runs the whole phased workflow in one Ruby process
# to cut agent turns / token cost, WITHOUT turning the migration into a black
# box: every phase prints a visible header + concise result, and the genuine
# human decision points (window/table-calc degradations, untranslatable calcs,
# custom-SQL / file-based datasources, unsupported viz) are surfaced as a
# structured OPEN QUESTIONS block (exit 10) rather than silently auto-resolved.
#
# This script does NOT re-implement any mechanical phase — it chains the
# existing skill scripts:
#   tableau-discover.rb     (Phase 1 — workbook + views + .twb + ds-metadata + PNG)
#   parse-twb-layout.rb     (Phase 1 — dashboard zone tree + chart kinds)
#   extract-calc-fields.rb  (Phase 1 — calc formulas + requires_custom_sql flag)
#   extract-custom-sql.rb   (Phase 1 — custom-SQL blocks behind the datasource)
#   scan-workbook-gaps.rb   (Phase 1 — feature-gap inventory)
#   discover-columns.rb     (Phase 2 — real warehouse column names/types)
#   validate-spec.rb + post-and-readback.rb (Phase 3 DM, Phase 4 workbook)
#   build-dashboard-layout.rb + put-layout.rb (Phase 5 layout)
#   phase6-parity.rb        (Phase 6 parity, best-effort; falls back to the
#                            post-and-readback column-type guard as the hard signal)
#
# Spec GENERATION (the DM spec + workbook spec) is the one genuinely
# agent-owned step in this skill — there is no mechanical converter the way
# QuickSight has. The orchestrator delegates it to a pluggable generator:
#   * If a `Specs` module is reachable (the validated reference generator at
#     ~/orders-migration/specs.rb, or a per-workbook generator the agent drops
#     next to the working dir), it is used verbatim — deterministic, validated.
#   * Otherwise the orchestrator builds a data-driven DM from the warehouse
#     tables discovered in Phase 2 (one warehouse-table element per table,
#     *_KEY-inferred relationships, calc fields translated by the built-in
#     Tableau->Sigma translator) and the workbook via the skill's own
#     build-charts-from-signals.rb + build-workbook-spec.rb.
#
# Usage (PASS 1 — discover → gates → DM → workbook → layout → parity plan):
#   ruby scripts/migrate-tableau.rb \
#     --workbook "<name>" | --workbook-id <luid> \
#     --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
#     [--db CSA --schema TJ] [--specs <path/to/specs.rb>] \
#     [--name '<prefix for DM/workbook names>'] [--row-scale 1.5] \
#     [--force]               # proceed past ❌-unhandled gap-scan features
#     [--reuse-dm [ID]]       # opt IN to DM reuse (default: build new; bare
#                             # flag = use find-or-pick-dm's recommendation)
#     [--skip-reuse-scan]     # don't scan existing DMs at all
#     [--out DIR] [--answers '<json>'] [--yes]
#
# Phase 6 parity is TWO-PASS (Sigma has no synchronous chart-data REST endpoint;
# actuals come from mcp-v2 queries). Pass 1 ends by emitting the per-chart MCP
# query list + exit 12. Collect the actuals, then resume (PASS 2 — finalize +
# cleanup-orphans + the census-aware assert-phase6-ran hard gate):
#   ruby scripts/migrate-tableau.rb --workbook "<name>" [--out DIR] \
#     --finalize --actuals <WORKDIR>/parity-actuals.json \
#     [--allow-missing-tiles N]   # explain legitimately unbuildable zones
#
# Phase E (OPT-IN) — Enhance: pass --enhance (pass 1 or --finalize) to run the
# shared enhancement engine AFTER all gates are green: enhance-scan.rb emits
# candidates; nothing applies without --enhance-accept <ids|all-low-risk>
# (without it the run stops at exit 14 with the proposals); enhance-apply.rb
# then clones the parity workbook ("<name> — Enhanced") and applies accepted
# items one at a time under a parity-unchanged gate. Default = OFF everywhere.
#
# Exit codes: 0 = done (ALL gates green — only possible via --finalize);
# 10 = decisions needed (OPEN QUESTIONS printed, NO Sigma objects created);
# 11 = gap scan found ❌-unhandled features (re-run with --force to accept);
# 12 = pass 1 complete, parity PENDING (run the printed MCP queries, then
#      re-run with --finalize --actuals);
# 14 = migration GREEN + Phase E proposals pending acceptance (re-run
#      --finalize with --enhance --enhance-accept ...);
# 3 = parity/guard fail; 4 = workbook layer needs the agent path; other = error.
require 'json'
require 'csv'
require 'yaml'
require 'optparse'
require 'fileutils'
require 'open3'
require 'date'
require 'time'
require_relative 'lib/scout_gate'

$stdout.sync = true # progress lines interleave correctly when piped/captured

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'coverage_gate' # build-charts coverage.json → consolidated report (bead beads-sigma-59mk)

opts = {}
OptionParser.new do |o|
  o.on('--workbook NAME')    { |v| opts[:wb_name] = v }
  o.on('--workbook-id LUID') { |v| opts[:wb_id]   = v }
  o.on('--connection ID')    { |v| opts[:conn]    = v }
  o.on('--folder ID')        { |v| opts[:folder]  = v }
  o.on('--db NAME')          { |v| opts[:db]      = v }
  o.on('--schema NAME')      { |v| opts[:schema]  = v }
  o.on('--specs PATH')       { |v| opts[:specs]   = File.expand_path(v) }
  o.on('--out DIR')          { |v| opts[:out]     = File.expand_path(v) }
  o.on('--answers JSON')     { |v| opts[:answers] = v }
  o.on('--yes')              {     opts[:yes]     = true }
  o.on('--name PREFIX')      { |v| opts[:name]    = v }
  o.on('--force')            {     opts[:force]   = true }
  o.on('--reuse-dm [ID]')    { |v| opts[:reuse_dm] = v || :recommended }
  o.on('--skip-reuse-scan')  {     opts[:skip_reuse] = true }
  o.on('--row-scale F', Float) { |v| opts[:row_scale] = v }
  o.on('--master-col PAIR', "'Name=<Sigma formula>' — extra master column (repeatable). The resume path " \
                            'for the exit-4 handoff when a chart dim is a master-level calc the mechanical ' \
                            'map cannot derive (e.g. a binned/categorized dimension).') do |v|
    nm, fx = v.split('=', 2)
    abort "--master-col expects 'Name=<Sigma formula>', got #{v.inspect}" if nm.to_s.empty? || fx.to_s.empty?
    (opts[:master_cols] ||= []) << [nm, fx]
  end
  o.on('--finalize')         {     opts[:finalize] = true }
  o.on('--actuals PATH')     { |v| opts[:actuals] = File.expand_path(v) }
  o.on('--allow-missing-tiles N', Integer) { |v| opts[:allow_missing_tiles] = v }
  o.on('--min-pass-rate F', Float, 'accept a parity pass-rate below 1.0 at the gate — ONLY for honest, ' \
                                   'NAMED divergences (LOD placeholders / cross-grain semantics)') { |v| opts[:min_pass_rate] = v }
  # Phase E (opt-in) — Enhance. NEVER runs without --enhance; with --enhance
  # but no --enhance-accept the run stops at exit 14 with the scan proposals
  # (present them per-item to the human, e.g. AskUserQuestion), then re-run
  # --finalize with --enhance-accept <id,id,...> or 'all-low-risk'.
  o.on('--enhance')          {     opts[:enhance] = true }
  o.on('--enhance-accept L') { |v| opts[:enhance_accept] = v }
  o.on('--converter MODE', %w[local hosted], "converter backend: 'local' (default; no data egress — " \
       "needs TABLEAU_MCP_BUILD) or 'hosted' (sends the .twb to sigma-data-model-mcp.onrender.com — " \
       'explicit consent to upload customer schema/SQL).') { |v| opts[:converter] = v }
end.parse!

abort 'missing --workbook or --workbook-id' unless opts[:wb_name] || opts[:wb_id]
abort 'missing --connection' unless opts[:conn] || opts[:finalize]

slug = (opts[:wb_name] || opts[:wb_id]).gsub(/[^A-Za-z0-9_-]/, '-').squeeze('-')
WORK = opts[:out] || File.expand_path("~/tableau-migration/#{slug}")
FileUtils.mkdir_p(File.join(WORK, 'views'))

TOTAL = 6
def hdr(n, title) puts; puts "── Phase #{n}/#{TOTAL} · #{title} ──"; end
def line(m) puts "   #{m}"; end

# Phase-timing summary — printed at every terminal exit so the discovery
# interleave speedup stays visible in every run (and regressions show up in
# the first slow report instead of an investigation).
START_T = Time.now
PHASE_T = {}
$t_mark = Time.now
def mark(key)
  now = Time.now
  PHASE_T[key] = (PHASE_T[key] || 0.0) + (now - $t_mark)
  $t_mark = now
end
def phase_summary
  return if PHASE_T.empty?
  puts
  puts "PHASE TIMINGS  #{PHASE_T.map { |k, v| "#{k}=#{v.round(1)}s" }.join('  ')}  " \
       "total=#{(Time.now - START_T).round(1)}s"
end

# Run a child command, indenting its output. token_env: prepend a fresh
# Sigma/Tableau token via the skill's get-token scripts so long runs survive
# the ~1h token TTL.
def run!(cmd, allow_fail: false)
  out, st = Open3.capture2e(*cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success? || allow_fail
  [out, st]
end

# Wrap a command so a Sigma token is live for it (eval get-token.sh first).
def sigma_run!(cmd, allow_fail: false)
  joined = cmd.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')
  run!(['bash', '-c', "eval \"$(#{File.join(HERE, 'get-token.sh')})\" && #{joined}"], allow_fail: allow_fail)
end

# Raised when the MECHANICAL WORKBOOK layer (build / validate / POST) fails after
# the data model is already posted + valid. The orchestrator catches this and
# degrades to a FRIENDLY agent-path handoff instead of a bare crash — the DM is
# ready, so the agent path can rebuild just the workbook against it.
class WorkbookBuildError < StandardError
  attr_reader :captured_output
  def initialize(msg, captured_output = '')
    super(msg)
    @captured_output = captured_output.to_s
  end
end

# Like run!, but on failure raises WorkbookBuildError (catchable) instead of
# abort()ing the process. Captures the child output for field-name mining.
def run_wb!(cmd)
  out, st = Open3.capture2e(*cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  raise WorkbookBuildError.new("command failed (#{st.exitstatus}): #{cmd.join(' ')}", out) unless st.success?
  out
end

# sigma_run! variant that raises WorkbookBuildError instead of aborting.
def sigma_run_wb!(cmd)
  joined = cmd.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')
  run_wb!(['bash', '-c', "eval \"$(#{File.join(HERE, 'get-token.sh')})\" && #{joined}"])
end

# Pull likely-offending field/column names out of a failed workbook build/POST log.
def cull_failed_fields(*logs)
  text = logs.join("\n")
  names = []
  text.scan(/Dependency not found:?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Unknown column\s*"?\[?([^"\]\n]+)\]?"?/i) { |m| names << m[0].strip }
  text.scan(/unmapped (?:derived[- ]dim|measure|field)\s*[:=]?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Circular column reference[^\n]*\[([^\]]+)\]/i) { |m| names << m[0].strip }
  names.map { |n| n.gsub(/[\[\]"]/, '').strip }.reject(&:empty?).uniq
end

def yp(s) YAML.safe_load(s, permitted_classes: [Date, Time]) rescue {} end

# ---------------------------------------------------------------------------
# PASS 2 (--finalize) — phase6 finalize + cleanup-orphans + the census-aware
# assert-phase6-ran hard gate. Resumes from <WORK>/migrate-state.json; phases
# 1–5 are NOT re-run. Exit 0 here is the ONLY green exit of the orchestrator.
# ---------------------------------------------------------------------------
if opts[:finalize]
  abort '--actuals required with --finalize (the parity-actuals.json you built from the MCP queries)' unless opts[:actuals]
  state_path = File.join(WORK, 'migrate-state.json')
  abort "FATAL: no #{state_path} — run pass 1 first (same --workbook/--out)" unless File.exist?(state_path)
  state = JSON.parse(File.read(state_path))
  wb_id = state['workbook_id'] or abort 'FATAL: state has no workbook_id (pass 1 never completed Phase 4)'

  hdr(6, 'Parity (pass 2 — finalize)')
  $t_mark = Time.now
  p6 = ['ruby', File.join(HERE, 'phase6-parity.rb'), '--tableau', WORK,
        '--finalize', '--actuals', opts[:actuals]]
  p6 += ['--extract-mode', '--extract-tol', '0.30'] if state['extract_mode']
  _, p6st = sigma_run!(p6, allow_fail: true)
  line "phase6-parity finalize: #{p6st.success? ? 'PASS' : "FAIL (exit #{p6st.exitstatus})"}"
  mark('phase6-finalize')

  # Cleanup: delete orphan workbooks from spec-iteration retries (keep the live one).
  _, clst = sigma_run!(['ruby', File.join(HERE, 'cleanup-orphan-workbooks.rb'),
                        '--workdir', WORK, '--keep', wb_id], allow_fail: true)
  line 'WARN: orphan cleanup reported failures — assert-phase6-ran will gate on it' unless clst.success?
  mark('cleanup-orphans')

  # The census-aware hard gate. NEVER bypassed — this command fails when it fails.
  gate = ['ruby', File.join(HERE, 'assert-phase6-ran.rb'), '--tableau', WORK, '--workbook-id', wb_id]
  gate += ['--allow-extract'] if state['extract_mode']
  gate += ['--allow-missing-tiles', opts[:allow_missing_tiles].to_s] if opts[:allow_missing_tiles]
  gate += ['--min-pass-rate', opts[:min_pass_rate].to_s] if opts[:min_pass_rate]
  _, gst = sigma_run!(gate, allow_fail: true)
  mark('assert-phase6-ran')

  if gst.exitstatus == 7
    census = (JSON.parse(File.read(File.join(WORK, 'parity-final.json')))['tile_census'] rescue {}) || {}
    unmatched = census['unmatched_zone_names'] || []
    puts
    puts '==================== CENSUS STOP (agent action required) ===================='
    puts "The Tableau dashboard has #{census['zones_total']} chart zone(s) but only"
    puts "#{census['charts_built']} made it into the parity plan. Unmatched zone(s):"
    unmatched.each { |z| puts "  - #{z}" }
    puts ''
    puts 'This usually means the Tableau view CSV came back EMPTY (filtered viz /'
    puts 'export quirk) so the chart was silently dropped, or a chart was renamed.'
    puts 'Handle each zone, then re-run this exact --finalize command:'
    puts "  1. Re-export the view CSV (scripts/fetch-view-data.rb / MCP get-view-data"
    puts '     with filters relaxed) into the workdir and rebuild the missing chart'
    puts "     against DM #{state['data_model_id']} / workbook #{wb_id} (see SKILL.md),"
    puts '     then re-run phase6-parity pass 1 + the MCP queries + --finalize; OR'
    puts "  2. If it was a RENAME, re-run pass 1 with --rename plumbed via phase6-parity; OR"
    puts "  3. If the zone is legitimately unbuildable, re-run --finalize with"
    puts "     --allow-missing-tiles #{unmatched.size} and NAME the zone(s) in your report."
    puts '============================================================================='
  end

  if gst.exitstatus == 10
    puts
    puts '==================== VISUAL STOP (agent action required) ===================='
    puts 'Phase 6f visual verification has not run: no Sigma render PNG exists in the'
    puts 'workdir. CSV parity passing does NOT mean the workbook renders correctly'
    puts '(overlaps, dead zones, dropped log scale, missing labels, wrong chart kind).'
    puts 'Do this, then re-run this exact --finalize command:'
    puts "  1. Render the full page(s) of workbook #{wb_id}:"
    puts "       python3 scripts/sigma-export-png.py --workbook #{wb_id} \\"
    puts "         --page <pageId> --out #{File.join(WORK, 'sigma-render.png')}"
    puts "  2. READ #{File.join(WORK, 'sigma-render.png')} with the Read tool and compare it"
    puts "     side-by-side against the source dashboard PNG in #{WORK} (Phase 1d)."
    puts '     Fix any visual divergence (re-PUT the spec) and re-render until they match.'
    puts '  3. Record screenshot_path (and visual_checked:true) in parity-final.json so the'
    puts '     gate confirms the comparison ran, then re-run --finalize.'
    puts '  If the workbook genuinely cannot be rendered (export API unavailable), the gate'
    puts '  can be waived ONLY via assert-phase6-ran.rb --skip-visual-gate "<reason>" —'
    puts '  name the reason in your migration report.'
    puts '============================================================================='
  end

  # With an explicit --min-pass-rate (honest NAMED divergences), the census-
  # aware gate is the parity authority — phase6's own exit stays strict-100%.
  parity_ok = p6st.success? || (opts[:min_pass_rate] && gst.success?)
  all_green = parity_ok && clst.success? && gst.success?

  # ---------------------------------------------------------------------------
  # Phase E (OPT-IN) — Enhance. Runs ONLY when --enhance was passed (here or on
  # pass 1) AND every gate above is green: enhancements clone a PARITY-VERIFIED
  # workbook, never an unproven one. Clone-first / scan-then-propose /
  # accept-only / parity-unchanged-gated — see enhance-scan.rb + enhance-apply.rb.
  # ---------------------------------------------------------------------------
  enhance_requested = opts[:enhance] || state['enhance_requested']
  enhance_line = nil
  $t_mark = Time.now # Phase E timing starts here (mark('phaseE') at each terminal)
  if enhance_requested && !all_green
    enhance_line = 'SKIPPED — gates not green (Phase E only clones a parity-verified workbook)'
  elsif enhance_requested
    puts
    puts '── Phase E (opt-in) · Enhance ──'
    enh_path = File.join(WORK, 'enhancements.json')
    _, est = sigma_run!(['ruby', File.join(HERE, 'enhance-scan.rb'),
                         '--workbook-id', wb_id, '--workdir', WORK,
                         '--source', 'tableau', '--out', enh_path], allow_fail: true)
    if !est.success?
      enhance_line = 'scan FAILED (migration itself is green; see output above)'
    elsif opts[:enhance_accept].nil?
      cands = (JSON.parse(File.read(enh_path))['candidates'] rescue [])
      puts
      puts '==================== PHASE E PROPOSALS (acceptance required) ===================='
      puts "#{cands.size} enhancement candidate(s) in #{enh_path}. NOTHING has been applied —"
      puts 'present each candidate to the human (interactive: one AskUserQuestion checklist),'
      puts 'then re-run this exact --finalize command adding:'
      puts "  --enhance --enhance-accept <id,id,...>   # or: --enhance-accept all-low-risk"
      puts '================================================================================='
      mark('phaseE')
      phase_summary
      exit 14
    else
      _, ast = sigma_run!(['ruby', File.join(HERE, 'enhance-apply.rb'),
                           '--workbook-id', wb_id, '--enhancements', enh_path,
                           '--accept', opts[:enhance_accept],
                           '--out', File.join(WORK, 'enhance-report.json')], allow_fail: true)
      rep = (JSON.parse(File.read(File.join(WORK, 'enhance-report.json'))) rescue {})
      enhance_line = if ast.success?
                       "clone #{rep['clone_id']} '#{rep['clone_name']}': " \
                       "#{(rep['applied'] || []).size} applied, #{(rep['skipped'] || []).size} skipped, " \
                       "#{(rep['reverted'] || []).size} reverted; parity-unchanged gate GREEN"
                     else
                       "apply NOT GREEN (exit #{ast.exitstatus}) — see enhance-report.json"
                     end
    end
  end

  mark('phaseE') if enhance_requested
  pf = (JSON.parse(File.read(File.join(WORK, 'parity-final.json'))) rescue {})
  puts
  puts '================ RESULT ================'
  puts "dataModelId : #{state['data_model_id']}"
  puts "workbookId  : #{wb_id}"
  puts "PARITY      : #{pf['status'] || '?'} (#{pf['charts_pass']}/#{pf['charts_total']} charts#{state['extract_mode'] ? ', extract-mode' : ''})"
  puts "GATES       : phase6=#{p6st.success? ? 'PASS' : 'FAIL'} cleanup=#{clst.success? ? 'PASS' : 'FAIL'} assert-phase6-ran=#{gst.success? ? 'PASS' : "FAIL(#{gst.exitstatus})"}"
  puts "ENHANCE     : #{enhance_line}" if enhance_line
  puts "STATUS      : #{all_green ? 'GREEN' : 'NOT GREEN'}"
  puts '======================================='
  phase_summary
  exit(all_green ? 0 : 3)
end

# ---------------------------------------------------------------------------
# Phase 1 — Discover (Tableau side), INTERLEAVED. tableau-discover.rb (its own
# unified 5-fetch pool) + scan-workbook-gaps run as a BACKGROUND lane; the
# pure-Sigma-side phases (1.6 DM-reuse scan + 2 warehouse columns — read-only,
# no Sigma objects created) run concurrently in the foreground. The lanes JOIN
# before anything that consumes discovery output (calc fields, gap gate, view
# CSVs, decisions checkpoint) — every designed stop/gate fires exactly as in
# the serial flow, just sooner.
# ---------------------------------------------------------------------------
hdr(1, 'Discover')
$t_mark = Time.now
twb = File.join(WORK, 'workbook-content.twb')

# ---------------------------------------------------------------------------
# Discovery REUSE (bead mg92). A 4-stop run must pay the ~112s Tableau fetch
# ONCE: stamp the out-dir per source revision (workbook luid + updatedAt). On
# re-entry, ONE cheap REST probe (~1s) decides:
#   * stamp matches + artifacts complete → SKIP the discovery lane entirely
#   * stamp differs / artifacts missing  → CLEAR the stale artifacts first so
#     lane_wait_for can never pick up a prior run's workbook-content.twb,
#     then re-fetch and re-stamp.
# ---------------------------------------------------------------------------
FAKE_OK = Struct.new(:exitstatus) do
  def success?
    exitstatus.zero?
  end
end
stamp_path = File.join(WORK, 'discovery-stamp.json')
disc_artifacts = [File.join(WORK, 'get-workbook.json'), twb, File.join(WORK, 'timings.json')]
probe = nil
probe_rb = +"$LOAD_PATH.unshift #{File.join(HERE, 'lib').inspect}; require 'tableau_rest'; require 'json'; "
probe_rb << if opts[:wb_id]
              "wb = Tableau.get_workbook(#{opts[:wb_id].inspect}); "
            else
              "h = Tableau.find_workbook_by_name(#{opts[:wb_name].inspect}) or abort 'no workbook'; wb = Tableau.get_workbook(h['id']); "
            end
probe_rb << "puts JSON.generate({ 'id' => wb['id'], 'updatedAt' => wb['updatedAt'] })"
probe_quoted = "'" + probe_rb.gsub("'") { "'\\''" } + "'"
probe_out, probe_st = Open3.capture2e('bash', '-c',
                                      "eval \"$(#{File.join(HERE, 'get-tableau-token.sh')})\" && ruby -e #{probe_quoted}")
probe = (JSON.parse(probe_out.lines.last.to_s) rescue nil) if probe_st.success?
stamp = (JSON.parse(File.read(stamp_path)) rescue nil)
reuse_discovery = probe && stamp &&
                  stamp['workbook_id'] == probe['id'] && stamp['updatedAt'] == probe['updatedAt'] &&
                  disc_artifacts.all? { |p| File.exist?(p) } &&
                  Dir[File.join(WORK, 'views', '*.csv')].any?

disc_log = File.join(WORK, 'phase1-discover.log')
if reuse_discovery
  lane = { started: Time.now, ended: Time.now, status: FAKE_OK.new(0), reused: true }
  line "discovery REUSED (stamp match: workbook #{probe['id']} updatedAt=#{probe['updatedAt']}; " \
       "#{Dir[File.join(WORK, 'views', '*.csv')].size} view CSVs already on disk) — Tableau fetch skipped"
else
  unless probe
    line "WARN: workbook-revision probe failed (#{probe_out.lines.last.to_s.strip[0, 120]}); discovery will re-fetch"
  end
  # Clear stale artifacts from any prior run — lane_wait_for polls File.exist?,
  # so a leftover file would short-circuit the wait with stale content.
  stale = (disc_artifacts + [stamp_path, File.join(WORK, 'ds-metadata.json'),
                             File.join(WORK, 'graphql-fields.json'), File.join(WORK, 'calc-fields.json'),
                             File.join(WORK, 'workbook-content.twbx')] +
           Dir[File.join(WORK, 'views', '*')] + Dir[File.join(WORK, '*gaps*report*')])
          .select { |p| File.exist?(p) }
  if stale.any?
    line "cleared #{stale.size} stale discovery artifact(s) from a prior run (source revision unknown or changed)"
    stale.each { |p| FileUtils.rm_f(p) }
  end
  disc = ['ruby', File.join(HERE, 'tableau-discover.rb'), '--out', WORK]
  disc += opts[:wb_id] ? ['--workbook-id', opts[:wb_id]] : ['--workbook-name', opts[:wb_name]]
  disc_sh = disc.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')
  scan_sh = ['ruby', File.join(HERE, 'scan-workbook-gaps.rb'), twb]
            .map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')
  File.write(disc_log, '')
  # Gap scan runs in the lane as soon as its input (the .twb) is ready — i.e.
  # right after discovery lands it. Scan failure is tolerated (same as before);
  # discovery failure is the lane's exit code.
  lane_cmd = "eval \"$(#{File.join(HERE, 'get-tableau-token.sh')})\" && #{disc_sh}; rc=$?; " \
             "if [ $rc -eq 0 ] && [ -f '#{twb}' ]; then #{scan_sh} || true; fi; exit $rc"
  lane = { started: Time.now, status: nil }
  lane[:pid] = Process.spawn('bash', '-c', lane_cmd, %i[out err] => [disc_log, 'a'])
  line "Tableau discovery + gap scan: BACKGROUND lane (pid #{lane[:pid]}, log #{File.basename(disc_log)})"
  line 'Sigma-side phases 1.6 + 2 run concurrently; lanes join before discovery output is consumed.'
end

lane_done = lambda do
  next true if lane[:status]
  if (st = Process.wait2(lane[:pid], Process::WNOHANG))
    lane[:status] = st[1]
    lane[:ended] = Time.now
    # Stamp the completed discovery for resume reuse (bead mg92) — but ONLY a
    # COMPLETE one: a run with failed fetch tasks (Tableau Cloud's transient
    # 400s) must not be blessed, or the resume reuses a discovery with missing
    # view CSVs and tiles silently drop. No stamp = the next run re-fetches.
    if st[1].success? && probe
      tj = (JSON.parse(File.read(File.join(WORK, 'timings.json'))) rescue nil)
      # Only ESSENTIAL tasks block the stamp (view CSVs / .twb / workbook meta).
      # A persistently-failing dashboard PNG must not force re-paying discovery
      # on every resume.
      failed = tj ? (tj['tasks'] || []).select { |t| t['ok'] == false && t['task'].to_s =~ /\A(csv:|twb|get-workbook)/ } : []
      if failed.empty?
        File.write(stamp_path, JSON.pretty_generate(
                                 'workbook_id' => probe['id'], 'updatedAt' => probe['updatedAt'],
                                 'stamped_at' => Time.now.utc.iso8601))
      else
        line "discovery NOT stamped for reuse — #{failed.size} fetch task(s) failed " \
             "(#{failed.map { |t| t['task'] }.join(', ')[0, 120]}); a resume will re-fetch"
      end
    end
    true
  else
    false
  end
end
print_lane_log = lambda do
  next if lane[:reused] # prior run's log — already shown on the run that fetched
  File.read(disc_log).each_line { |l| puts "   │ #{l.rstrip}" } if File.exist?(disc_log)
end
# Wait for a lane artifact (tableau-discover writes them atomically). Returns
# false when the lane exits without producing it.
lane_wait_for = lambda do |path, what, timeout = 600|
  t0 = Time.now
  until File.exist?(path)
    if lane_done.call
      return File.exist?(path)
    end
    abort "FATAL: timed out (#{timeout}s) waiting for #{what} from the discovery lane" if Time.now - t0 > timeout
    sleep 0.1
  end
  true
end

unless lane_wait_for.call(File.join(WORK, 'get-workbook.json'), 'get-workbook.json')
  print_lane_log.call
  abort "FATAL: discovery lane exited (#{lane[:status]&.exitstatus}) before producing get-workbook.json"
end

gw = JSON.parse(File.read(File.join(WORK, 'get-workbook.json')))
wb = gw['workbook'] || gw
wb_luid = wb['id'] || opts[:wb_id]
wb_name = wb['name'] || opts[:wb_name] || slug
has_extracts = [wb['hasExtracts'], wb.dig('datasources')].to_s.include?('true') ||
               wb['hasExtracts'] == true
views = (wb.dig('views', 'view') || [])
views = [views] unless views.is_a?(Array)
line "workbook '#{wb_name}' (#{wb_luid}): #{views.size} view(s)#{has_extracts ? ', hasExtracts=true' : ''}"

layout_json = File.join(WORK, 'dashboard-layout.json')
have_twb = lane_wait_for.call(twb, 'workbook-content.twb')
if have_twb
  run!(['ruby', File.join(HERE, 'parse-twb-layout.rb'), twb, layout_json])
  dash = JSON.parse(File.read(layout_json))
  zones = dash.is_a?(Array) ? dash.flat_map { |d| d['zones'] || [] } : (dash['zones'] || [])
  chart_zones = zones.select { |z| z['kind'] == 'chart' }
  kinds = chart_zones.map { |z| z['chart_kind'] }.compact
                     .each_with_object(Hash.new(0)) { |k, h| h[k] += 1 }
                     .map { |k, c| c > 1 ? "#{k}×#{c}" : k }.join(', ')
  line "parsed .twb: #{chart_zones.size} chart zone(s) (#{kinds})"
else
  chart_zones = []
  line 'no .twb content (MCP-only datasource?) — chart-kind/calc discovery degraded'
end

# calc fields / custom-SQL / gap gate / empty-CSV preflight all consume
# discovery-lane output — they run AFTER the lane join below. The spec
# generation here only needs the .twb (already landed).

# ---------------------------------------------------------------------------
# Spec generation. The DEFAULT path is MECHANICAL (no agent hand-authoring):
#   convert_tableau_to_sigma → DM spec; parse-twb-layout + build-charts-from-
#   signals + an auto-derived master-map → workbook spec. An explicit --specs
#   <path> (or a per-workbook <workdir>/specs.rb the human dropped in) overrides
#   the mechanical path with a hand-authored `Specs` module, used verbatim.
# ---------------------------------------------------------------------------
require File.join(HERE, 'mechanical-specs')
specs_path = opts[:specs] || [File.join(WORK, 'specs.rb')].find { |p| File.exist?(p) }
have_specs = false
if specs_path && File.exist?(specs_path)
  begin
    require specs_path.sub(/\.rb$/, '')
    have_specs = defined?(Specs) && Specs.respond_to?(:dm_spec) && Specs.respond_to?(:wb_spec)
    line "spec generator: hand-authored Specs module (#{specs_path})" if have_specs
  rescue StandardError => e
    line "(spec generator at #{specs_path} failed to load: #{e.message})"
  end
end

# Mechanical converter run (the default). Requires the .twb (parse-twb-layout
# already gated on have_twb above) and a converter backend — local build by
# default, hosted MCP only on explicit consent (see backend resolution below).
mechanical = !have_specs
conv = nil
if mechanical
  unless have_twb
    sleep 0.1 until lane_done.call # reap the background lane before aborting
    print_lane_log.call
    abort <<~MSG
      FATAL: mechanical conversion needs the workbook .twb (for the data model +
      chart signals), but none was downloaded (MCP-only datasource?). Either
      supply a hand-authored Specs module via --specs, or use a .twb-backed
      workbook.
    MSG
  end
  # Converter backend — LOCAL-FIRST, never silently upload customer data. The
  # .twb holds customer schema / SQL / calc formulas; the hosted converter MCP
  # would send it to a third-party server, which many customers cannot allow.
  #   1. LOCAL (default, no egress): TABLEAU_MCP_BUILD → a local build/tableau.js
  #      (or a locally-run sigma-data-model MCP). Data never leaves the machine.
  #   2. HOSTED (sigma-data-model-mcp.onrender.com) ONLY on explicit consent
  #      (--converter hosted or SIGMA_CONVERTER_ALLOW_HOSTED=1) — the .twb is
  #      uploaded off-box.
  #   3. Otherwise STOP with both options — NEVER fall back to hosted silently.
  mcp_build = ENV['TABLEAU_MCP_BUILD']
  if mcp_build && !File.exist?(mcp_build)
    line "WARN: TABLEAU_MCP_BUILD=#{mcp_build} does not exist — ignoring"
    mcp_build = nil
  end
  allow_hosted = opts[:converter] == 'hosted' || ENV['SIGMA_CONVERTER_ALLOW_HOSTED'] == '1'
  if mcp_build
    line "converter: LOCAL build #{mcp_build} (no data leaves this machine)"
  elsif allow_hosted
    line 'converter: HOSTED MCP (sigma-data-model-mcp.onrender.com) — NOTE: the .twb is uploaded'
    line '           to this third-party server (opted in via --converter hosted / SIGMA_CONVERTER_ALLOW_HOSTED).'
  else
    sleep 0.1 until lane_done.call # reap the background lane before aborting
    print_lane_log.call
    abort <<~MSG
      FATAL: no local Tableau→Sigma converter, and hosted conversion was not consented to.
      The .twb holds customer schema/SQL/formulas, so this skill will NOT upload it to the
      hosted converter without explicit consent. Choose one:
        • LOCAL (no data egress): set TABLEAU_MCP_BUILD to a local build/tableau.js (or run the
          sigma-data-model MCP locally), then re-run. See QUICKSTART "Converter backend".
        • HOSTED (uploads the .twb to sigma-data-model-mcp.onrender.com): re-run with
          --converter hosted (or SIGMA_CONVERTER_ALLOW_HOSTED=1) to consent.
    MSG
  end
  conv = MechanicalSpecs.run_converter(
    twb_path: twb, conn: opts[:conn], db: (opts[:db] || 'CSA'),
    schema: (opts[:schema] || 'TJ'), mcp_build: mcp_build, workdir: WORK)
  st = conv['stats'] || {}
  line "mechanical converter: #{st['elements']} element(s), #{st['columns']} column(s), " \
       "#{st['metrics']} metric(s), #{st['relationships']} relationship(s); #{(conv['warnings'] || []).size} warning(s)"

  # ---- RLS gate (never silently drop) -------------------------------------
  # The converter detects row-level security (USERNAME/USERATTRIBUTE/ISMEMBEROF
  # calcs) and reports it in conv['security'] (architecture B: reported, not
  # injected). Persist it to security.json and surface a LOUD, un-missable
  # checkpoint — RLS is provisioned + applied by scripts/apply_sigma_rls.py, NOT
  # by this converter. Also surface the cross-element warnings (an RLS calc over
  # a joined-dim column that needs manual placement on the owning element), so
  # those can't hide inside the warnings count either.
  rls_rules = conv['security'] || []
  rls_xelem = (conv['warnings'] || []).grep(/row-level security but references a related-table/)
  $rls_pending = rls_rules.any? || rls_xelem.any?
  if $rls_pending
    sec_path = File.join(WORK, 'security.json')
    File.write(sec_path, JSON.pretty_generate(rls_rules))
    line ''
    line '🔐 ROW-LEVEL SECURITY DETECTED — NOT yet applied to the Sigma model'
    rls_rules.each do |r|
      nm = r.dig('rls', 'name') || r['source']
      attrs = (r.dig('rls', 'userAttributes') || []).join(', ')
      line "   • #{nm}#{attrs.empty? ? '' : "  (user attribute(s): #{attrs})"}"
    end
    rls_xelem.each { |w| line "   • #{w[0, 150]}" }
    line "   wrote #{sec_path} (#{rls_rules.size} emit-ready rule(s); #{rls_xelem.size} cross-element rule(s) need manual placement)"
    line '   PROVISION + APPLY before this model is safe to share:'
    line "     python3 scripts/apply_sigma_rls.py --from-security #{sec_path} --dm-id <dataModelId>            # plan"
    line "     python3 scripts/apply_sigma_rls.py --from-security #{sec_path} --dm-id <dataModelId> --provision --apply"
    line ''
  end

  # Mechanical DM fixup NOW (so dropped calcs feed the checkpoint): resolve
  # raw-table-name prefixes + GUID sibling refs, and DROP calc columns that
  # still cannot resolve (unknown functions / unresolved refs).
  fx = MechanicalSpecs.fixup_dm_spec(conv['model'])
  line "DM fixup: rewrote #{fx[:fixed]} formula(s); dropped #{fx[:dropped].size} unresolvable calc col(s)" if fx[:fixed].positive? || fx[:dropped].any?
  dropped_calcs = fx[:dropped]

  # Pre-derive the master-map now (deterministic; uses the converter element
  # name — Phase 4 re-derives against the authoritative readback name). This lets
  # us surface any chart-PLOTTED metric that did not fully translate (GUID refs
  # the converter could not resolve) as an OPEN QUESTION rather than a silent
  # blank chart. Metrics that aren't plotted by any view are ignored.
  conv_fact = MechanicalSpecs.pick_fact(conv['model'])
  conv_base = conv_fact ? MechanicalSpecs.base_of(conv['model'], conv_fact) : nil
  pre = conv_fact ? MechanicalSpecs.derive_master(conv_fact, (conv_fact['name'] || 'Order Fact'), conv_base, nil, conv['model']) : { 'untranslated_metrics' => [] }
  pre_untranslated = pre['untranslated_metrics'] || []
  # plotted_untranslated (the CSV-header match) is computed after the lane join
  # — it needs the view CSVs.
end
mark('phase1-foreground')

# ---------------------------------------------------------------------------
# Phase 1.6 — DM-reuse scan (find-or-pick-dm). Default = BUILD NEW; candidates
# are printed so a human can opt in with --reuse-dm. Non-destructive.
# Pure Sigma-side — runs CONCURRENTLY with the background discovery lane.
# ---------------------------------------------------------------------------
hdr('1.6', 'DM-reuse scan (concurrent with discovery)')
reuse_dm_id = nil
dm_match = {}
src_model = mechanical ? conv['model'] : (have_specs ? Specs.dm_spec : nil)
if opts[:skip_reuse]
  line 'skipped (--skip-reuse-scan)'
elsif src_model.nil?
  line 'no spec source to derive a signature from — building new'
else
  sig_els = (src_model['pages'] || []).flat_map { |p| p['elements'] || [] }
  sig_tables = sig_els.map do |e|
    s = e['source'] || {}
    next 'CUSTOM_SQL' if s['kind'] == 'sql'
    pth = s['path']
    pth.is_a?(Array) ? pth.join('.').upcase : nil
  end.compact.uniq
  sig_cols = sig_els.flat_map { |e| (e['columns'] || []).map { |c| c['name'] } }.compact.uniq
  sig_meas = sig_els.flat_map do |e|
    (e['metrics'] || []).map { |m| { 'col' => m['name'], 'derivation' => m['aggregation'] || m['derivation'] } }
  end
  sig_path = File.join(WORK, 'workbook-signature.json')
  File.write(sig_path, JSON.pretty_generate(
    'tableau_workbook' => wb_name, 'warehouse_tables' => sig_tables,
    'referenced_columns' => sig_cols, 'measures' => sig_meas))
  match_path = File.join(WORK, 'dm-match.json')
  sigma_run!(['ruby', File.join(HERE, 'find-or-pick-dm.rb'),
              '--workbook-signature', sig_path, '--out', match_path,
              '--auto-pick', '--auto-pick-threshold', '0.5'],
             allow_fail: true) # exit 1 = no candidate ≥ min-score (normal: build new)
  dm_match = (JSON.parse(File.read(match_path)) rescue {})
  # Reuse-first: if the picker auto-picked a safe candidate (covers ALL source
  # tables), reuse it automatically unless the user passed an explicit --reuse-dm.
  if !opts[:reuse_dm] && dm_match['auto_picked'] && dm_match['recommended_dm_id']
    opts[:reuse_dm] = :recommended
    line "DM-REUSE (auto): #{dm_match['rationale']}"
  end
  cands = (dm_match['candidates'] || []).first(3)
  if cands.any?
    line 'top candidate(s):' if opts[:reuse_dm]
    line 'top candidate(s) — default is BUILD NEW; pass --reuse-dm to opt in:' unless opts[:reuse_dm]
    cands.each { |c| line "  score #{format('%.2f', c['score'] || 0)}  #{c['dm_id']}  '#{c['dm_name']}'" }
  else
    line 'no existing DM covers this workbook — building new'
  end
end
if opts[:reuse_dm]
  reuse_dm_id = opts[:reuse_dm] == :recommended ? dm_match['recommended_dm_id'] : opts[:reuse_dm]
  abort 'FATAL: --reuse-dm: the picker found no candidate ≥ min-score; pass an explicit ' \
        '--reuse-dm <dataModelId> or drop the flag to build new' unless reuse_dm_id
  line "REUSING data model #{reuse_dm_id} — Phase 3 build+POST will be skipped."
  line "  #{dm_match['warning']}" if dm_match['warning']
  line '  NOTE: master-column formulas are derived against the reused DM\'s readback labels;'
  line '  if its shape differs (separate dim elements), the workbook gate will stop with the'
  line '  agent-path handoff (exit 4) — run SKILL.md Phase 1.5b (inspect-dm-shape.rb) then.'
end
mark('phase1.6-dm-scan')

# ---------------------------------------------------------------------------
# Phase 2 — Discover warehouse column names (per table) for the DM build.
# Pure Sigma-side — runs CONCURRENTLY with the background discovery lane.
# ---------------------------------------------------------------------------
hdr(2, 'Discover warehouse columns (concurrent with discovery)')
db = opts[:db] || 'CSA'
schema = opts[:schema] || 'TJ'
# Table set: from the generator's DM spec when available, else inferred from the
# datasource's logical tables.
wh_tables =
  if mechanical
    (conv['model']['pages'] || []).flat_map { |p| p['elements'] || [] }
      .select { |e| e.dig('source', 'kind') == 'warehouse-table' }
      .map { |e| e.dig('source', 'path')&.last }.compact.uniq
  elsif have_specs
    Specs.dm_spec['pages'].flat_map { |p| p['elements'] }
         .map { |e| e.dig('source', 'path')&.last }.compact.uniq
  else
    md = (JSON.parse(File.read(File.join(WORK, 'ds-metadata.json'))) rescue {})
    fields = md['data'] || []
    fields.flat_map { |f| (f['name'] || '').scan(/\b([A-Z][A-Z0-9_]*(?:_DIM|_FACT))\b/) }
          .flatten.uniq
  end
wh_tables = [] if wh_tables.nil?
if wh_tables.empty?
  line 'no warehouse tables resolved from metadata; relying on spec generator'
else
  wh_tables.each do |t|
    _, st = sigma_run!(['ruby', File.join(HERE, 'discover-columns.rb'),
                        '--connection-id', opts[:conn],
                        '--table-path', "#{db}.#{schema}.#{t}",
                        '--out', File.join(WORK, "cols-#{t}.json")], allow_fail: true)
    cj = (JSON.parse(File.read(File.join(WORK, "cols-#{t}.json"))) rescue nil)
    n = cj && cj['columns'] ? cj['columns'].size : '?'
    line "#{db}.#{schema}.#{t}: #{n} columns#{st.success? ? '' : ' (not in catalog — Custom SQL fallback may be needed)'}"
  end
end
mark('phase2-columns')

# ---------------------------------------------------------------------------
# Phase 1 (join) — wait for the background Tableau lane, then run everything
# that consumes its output: calc fields, custom-SQL scan, the gap-scan HARD
# GATE, the empty-view-CSV preflight, and the plotted-untranslated check.
# Every designed stop below is byte-identical to the serial flow.
# ---------------------------------------------------------------------------
puts
puts '── Phase 1 (join) · Tableau discovery lane ──'
sleep 0.1 until lane_done.call
mark('join-wait')
print_lane_log.call
unless lane[:status].success?
  abort "FATAL: Tableau discovery failed (exit #{lane[:status].exitstatus}) — see lane log above"
end
PHASE_T['phase1-lane(bg)'] = (lane[:ended] - lane[:started])
tjs = (JSON.parse(File.read(File.join(WORK, 'timings.json'))) rescue nil)
line "discovery lane: #{(lane[:ended] - lane[:started]).round(1)}s wall" \
     "#{tjs ? " (tableau-discover #{tjs['total_seconds']}s, pool=#{tjs['pool']}; per-task breakdown in timings.json)" : ''}"

calc_path = File.join(WORK, 'calc-fields.json')
calcs = []
if wb_luid
  cf = ['ruby', File.join(HERE, 'extract-calc-fields.rb'),
        '--workbook-luid', wb_luid, '--out', calc_path]
  cf += ['--twb', twb] if have_twb
  _, st = run!(['bash', '-c',
                "eval \"$(#{File.join(HERE, 'get-tableau-token.sh')})\" && " +
                cf.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')], allow_fail: true)
  if File.exist?(calc_path)
    cfj = JSON.parse(File.read(calc_path)) rescue {}
    calcs = cfj['calcs'] || []
    n_csql = calcs.count { |c| c['requires_custom_sql'] }
    line "#{calcs.size} calc field(s); #{n_csql} require Custom SQL (window/LOD)"
  end
end

custom_sql = []
csql_path = File.join(WORK, 'custom-sql.json')
if wb_luid && have_twb
  csql_cmd = ['ruby', File.join(HERE, 'extract-custom-sql.rb'),
              '--workbook-luid', wb_luid, '--twb', twb, '--out', csql_path]
  run!(['bash', '-c',
        "eval \"$(#{File.join(HERE, 'get-tableau-token.sh')})\" && " +
        csql_cmd.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')], allow_fail: true)
  custom_sql = (JSON.parse(File.read(csql_path)) rescue []) if File.exist?(csql_path)
  custom_sql = [] unless custom_sql.is_a?(Array)
end

# Gap scan already ran in the discovery lane (right after the .twb landed);
# parse its report here. Lane scan failure degrades the same way the serial
# allow_fail run did: gaps stays empty.
gaps = []
gap_report_md = nil
if have_twb
  gj = Dir[File.join(WORK, '*gaps*report*.json')].first || Dir[File.join(WORK, '*gaps*.json')].first
  if gj && File.exist?(gj)
    gap_report_md = gj.sub(/\.json$/, '.md')
    gaps = (JSON.parse(File.read(gj))['detected_features'] || []) rescue []
    bys = gaps.group_by { |g| g['status'] }.transform_values(&:size)
    line "gap scan: #{bys.map { |k, v| "#{v} #{k}" }.join(', ')}"
  end
end

# GAP-SCAN HARD GATE: ❌-unhandled features mean part of the workbook cannot be
# migrated by this skill yet. Abort WITH the report unless the human accepts the
# degradation explicitly via --force. (auto/hint/manual statuses flow into the
# decisions checkpoint below instead.)
unhandled_gaps = gaps.select { |g| g['status'].to_s == 'unhandled' }
if unhandled_gaps.any?
  # RUN-EACH-TIME GATE (bead 5l5e): the gap-scout must have run for EVERY
  # ❌-unhandled feature before the conversion proceeds. scout-validate-and-
  # persist.rb records each scouted gap to <WORK>/scout-ledger.jsonl as
  # {gap_id, status: validated|escalated}. --force is NOT a blanket skip: it
  # only accepts gaps the scout actually tried and escalated — never a gap the
  # scout never ran for.
  # Gap-id = the gap-report row name; the scout records under --gap-id '<name>'.
  by_name = unhandled_gaps.each_with_object({}) { |g, h| h[g['name'].to_s] = g }
  buckets = ScoutGate.classify(WORK, unhandled_gaps.map { |g| g['name'].to_s })
  unscouted = buckets[:unscouted].map { |id| by_name[id] }
  escalated = buckets[:escalated].map { |id| by_name[id] }

  # Regression fix (gap-scout PR #153): the unscouted branch hard-`exit 11`'d even
  # under --yes/--force, stalling the unattended/demo path. Under unattended mode
  # (--yes/--answers/--force) the gate is ADVISORY — record the gaps as accepted and
  # proceed (the features are MISSING/flagged in Sigma, as before the gate existed).
  # Interactive runs still hard-stop so a human sees the gap and can scout it.
  unattended = opts[:yes] || opts[:answers] || opts[:force]
  if unscouted.any? && !unattended
    puts
    puts '==================== GAP-SCAN STOP (scout required) ===================='
    puts "#{unscouted.size} of #{unhandled_gaps.size} ❌-unhandled feature(s) have NOT been scouted:"
    unscouted.each { |g| puts "  - #{g['name']} (×#{g['count']}): #{g['blurb']}" }
    puts ''
    puts "Full report: #{gap_report_md || '(see workdir *gaps-report.md)'}"
    puts 'Spawn ONE gap-scout subagent per row (scripts/gap-scout.md), passing'
    puts "  --gap-id '<the row name above>' --workdir #{WORK}"
    puts 'so each scout records its result to the ledger. Then re-run this command,'
    puts 'or re-run with --yes/--force to accept the degradation (features MISSING/flagged).'
    puts '======================================================='
    puts 'No Sigma objects were created.'
    mark('phase1-join')
    phase_summary
    exit 11
  elsif escalated.any? && !unattended
    puts
    puts '==================== GAP-SCAN STOP (escalated gaps) ===================='
    puts "All #{unhandled_gaps.size} unhandled feature(s) were scouted; #{escalated.size} could NOT be"
    puts 'auto-translated and were escalated (recorded locally; file an issue via escalate-gap.py):'
    escalated.each { |g| puts "  - #{g['name']} (×#{g['count']})" }
    puts ''
    puts 'Re-run with --force/--yes to accept these as manual — they will be MISSING/flagged'
    puts 'in the Sigma workbook. (The validated ones still migrate.)'
    puts '======================================================='
    puts 'No Sigma objects were created.'
    mark('phase1-join')
    phase_summary
    exit 11
  else
    if unscouted.any?
      line "gap-scout: #{unscouted.size} ❌-unhandled feature(s) NOT scouted — proceeding (unattended); they will be MISSING/flagged in Sigma. (optional: scripts/gap-scout.md to translate)"
      unscouted.each { |g| ScoutGate.record(WORK, gap_id: g['name'].to_s, feature: 'feature', status: 'accepted') }
    end
    line "--force/--yes: proceeding past #{escalated.size} scouted-but-escalated feature(s) — they will NOT migrate" if escalated.any?
    line "gap-scout: all #{unhandled_gaps.size} ❌-unhandled feature(s) resolved via validated rules" if unscouted.empty? && escalated.empty?
  end
end

# EMPTY-VIEW-CSV preflight (honesty stop): a view whose CSV exported 0 data rows
# produces NO chart — the tile silently drops and the census gate stops the
# --finalize pass. Surface it NOW as a decision instead of a surprise later.
empty_csvs = Dir[File.join(WORK, 'views', '*.csv')].select do |c|
  (File.readlines(c).reject { |l| l.strip.empty? }.size rescue 0) <= 1
end.map { |c| File.basename(c, '.csv') }
line "WARN: #{empty_csvs.size} view CSV(s) came back EMPTY: #{empty_csvs.join(', ')}" if empty_csvs.any?

# PLOTTED metrics whose formula did not fully translate — deferred from spec
# generation (needs the lane's view CSVs to know what is actually charted).
if mechanical
  csv_headers = Dir[File.join(WORK, 'views', '*.csv')].flat_map do |c|
    (CSV.read(c).first rescue nil) || []
  end.compact.map { |h| h.to_s.strip }.uniq
  plotted_untranslated = pre_untranslated.select do |nm|
    csv_headers.any? { |h| h.casecmp?(nm) || h.sub(/^(sum|avg|min|max|median|distinct count|count) of /i, '').casecmp?(nm) }
  end
end
mark('phase1-join')

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine human questions ONLY. Mechanical
# fixup / POST / layout / parity are never asked about.
# ---------------------------------------------------------------------------
questions = []

# (a0) MECHANICAL CONVERTER WARNINGS — the authoritative un-mappable signal.
# convert_tableau_to_sigma marks each calc/LOD/window translation outcome:
#   ⛔ = no/failed translation (calc dropped → charts using it degrade)
#   ⚠  = best-effort / unsupported mode (verify in Sigma)
#   ℹ / ✅ = clean auto-handle (NOT a decision)
(mechanical ? (conv['warnings'] || []) : []).each do |w|
  ws = w.to_s.gsub(/\s+/, ' ').strip
  next if ws.start_with?('ℹ', '✅')
  next if ws.include?('Connection ID not set') # mechanical: --connection always supplied
  if ws.start_with?('⛔')
    questions << { 'id' => 'calc_no_translation', 'severity' => 'review', 'detail' => ws,
                   'options' => ['proceed (calc dropped; dependent charts degrade)',
                                 'abort and re-author the calc manually'],
                   'default' => 'proceed (calc dropped; dependent charts degrade)' }
  else # ⚠ and any unmarked warning
    questions << { 'id' => 'calc_best_effort', 'severity' => 'review', 'detail' => ws,
                   'options' => ['proceed (converter best-effort; verify in Sigma)',
                                 'restructure manually'],
                   'default' => 'proceed (converter best-effort; verify in Sigma)' }
  end
end

# (a1) PLOTTED metrics whose formula did not fully translate (unresolved Tableau
# internal field refs). These are charted by a Tableau view but cannot resolve
# mechanically against the master — a genuine human decision.
(mechanical ? (defined?(plotted_untranslated) && plotted_untranslated || []) : []).each do |nm|
  questions << { 'id' => 'metric_untranslated', 'severity' => 'review', 'calc' => nm,
                 'detail' => "Metric '#{nm}' is plotted in a Tableau view but the converter left unresolved " \
                             'internal field references in its formula — it cannot be rebuilt mechanically.',
                 'options' => ['proceed (chart measure left blank; re-author the calc in Sigma)',
                               'skip this metric'],
                 'default' => 'proceed (chart measure left blank; re-author the calc in Sigma)' }
end

# (a2) calc COLUMNS the mechanical fixup had to DROP (unknown function like
# DATEPARSE, or refs that never resolved). Genuinely un-mappable → human.
(mechanical ? (defined?(dropped_calcs) && dropped_calcs || []) : []).each do |nm|
  questions << { 'id' => 'calc_dropped', 'severity' => 'review', 'calc' => nm,
                 'detail' => "Calc column '#{nm}' could not be translated mechanically (unsupported function " \
                             'or unresolved reference) and was dropped from the data model.',
                 'options' => ['proceed (column dropped; re-author as a Custom SQL element or Sigma calc)',
                               'skip this calc'],
                 'default' => 'proceed (column dropped; re-author as a Custom SQL element or Sigma calc)' }
end

# (a) calc fields that have NO Sigma translation AT ALL — the manual window
#     residues (WINDOW_MEDIAN/PERCENTILE/CORR/..., PREVIOUS_VALUE, SIZE,
#     FIRST/LAST) and INCLUDE/EXCLUDE LODs. The mainstream window/table-calc
#     family (RUNNING_*/bounded WINDOW_*/RANK*/INDEX/LOOKUP/TOTAL) no longer
#     lands here: build-charts auto-emits it as Sigma-native chart formulas
#     (refs/window-functions.md) with no decision needed.
calcs.select { |c| c['requires_custom_sql'] }.each do |c|
  questions << {
    'id' => 'calc_requires_custom_sql', 'severity' => 'review',
    'calc' => c['name'],
    'detail' => "Tableau calc '#{c['name']}' (#{c['is_lod'] ? 'LOD' : 'manual window residue'}) has no validated Sigma " \
                "translation: #{c['formula'].to_s.gsub(/\s+/, ' ').strip[0, 120]}",
    'options' => ['implement as a Custom SQL data-model element (kind: sql)',
                  'degrade (drop the calc; charts using it go blank)',
                  'skip this calc'],
    'default' => 'implement as a Custom SQL data-model element (kind: sql)'
  }
end

# (b) custom-SQL datasource blocks — DM must source via kind:sql, not warehouse-table.
custom_sql.each do |b|
  q = (b['query'] || b['sql'] || '').to_s.gsub(/\s+/, ' ').strip[0, 120]
  questions << {
    'id' => 'custom_sql_datasource', 'severity' => 'review',
    'detail' => "Datasource is backed by Custom SQL; the DM element must use source.kind=sql: #{q}",
    'options' => ['source the DM element via Custom SQL (kind: sql)',
                  'abort and refactor the source in the warehouse first'],
    'default' => 'source the DM element via Custom SQL (kind: sql)'
  }
end

# (c) file-based / "land in warehouse" datasources (Excel/CSV/Hyper extract not
#     backed by a live warehouse table).
ds_type = (wb.dig('datasources') || []).to_s
file_based = ds_type =~ /excel|csv|textscan|hyper|\.tde|google-sheets/i
if file_based || (has_extracts && custom_sql.empty? && !have_twb)
  questions << {
    'id' => 'file_based_datasource', 'severity' => 'required',
    'detail' => 'Datasource appears to be file-based (Excel/CSV/Hyper) — Sigma reads a warehouse, ' \
                'so the data must first land in a warehouse table on the chosen connection',
    'options' => ['land the file in the warehouse, then point the DM at that table',
                  'abort until the data is in the warehouse'],
    'default' => nil
  }
end

# (d) extract-backed workbook — Tableau CSVs are a frozen snapshot; parity will
#     drift vs live warehouse. This is an expectations decision, not a failure.
if has_extracts
  questions << {
    'id' => 'extract_drift', 'severity' => 'review',
    'detail' => 'Workbook/datasource hasExtracts=true: Tableau view CSVs are a frozen snapshot. ' \
                'Sigma reads the warehouse live, so absolute values will drift; parity runs in ' \
                'structural (extract) mode.',
    'options' => ['proceed (structural parity, value drift expected)', 'abort and refresh the extract first'],
    'default' => 'proceed (structural parity, value drift expected)'
  }
end

# (e) unsupported / approximate viz kinds. Keep in lock-step with build-charts'
#     SIGMA_KIND map + the SKILL's "Sigma spec supports" list.
NATIVE = %w[bar line area combo scatter pie kpi map-region map-point pivot-table
            table automatic other table-or-text].freeze
APPROX = {
  'gantt' => 'approximate-to-bar', 'bullet' => 'approximate-to-bar',
  'heatmap' => 'data-migrate-as-table', 'treemap' => 'data-migrate-as-table',
  'packed-bubble' => 'data-migrate-as-table', 'density' => 'data-migrate-as-table'
}.freeze
chart_zones.each do |z|
  k = z['chart_kind'].to_s
  next if NATIVE.include?(k)
  cap = z['caption'] || z['view_ref'] || k
  if APPROX.key?(k)
    questions << { 'id' => 'viz_no_native_kind', 'severity' => 'review',
                   'viz' => cap, 'tableau_kind' => k,
                   'detail' => "Tableau '#{k}' has no native Sigma element kind",
                   'options' => [APPROX[k], 'skip this viz'], 'default' => APPROX[k] }
  else
    questions << { 'id' => 'viz_unknown_kind', 'severity' => 'review',
                   'viz' => cap, 'tableau_kind' => k,
                   'detail' => "Tableau mark '#{k}' did not map to a known Sigma kind — confirm from the dashboard PNG",
                   'options' => ['build as a bar-chart (default fallback)', 'skip this viz'],
                   'default' => 'build as a bar-chart (default fallback)' }
  end
end

# (e2) empty view CSVs — the chart for that view CANNOT be built mechanically
#      (no headers/rows to derive columns from). Genuine human decision: recover
#      the data or accept a missing tile (which the census gate will then stop on).
empty_csvs.each do |v|
  questions << {
    'id' => 'empty_view_csv', 'severity' => 'review', 'viz' => v,
    'detail' => "View '#{v}' exported an EMPTY CSV — its chart cannot be built mechanically and " \
                'the tile census will stop the --finalize gate. Recover the CSV (re-export with ' \
                'filters relaxed / MCP get-view-data) before re-running, or proceed and rebuild ' \
                'the chart manually against the posted DM, then explain via --allow-missing-tiles.',
    'options' => ['proceed (tile missing; rebuild manually + --allow-missing-tiles at --finalize)',
                  'abort and recover the view CSV first'],
    'default' => 'proceed (tile missing; rebuild manually + --allow-missing-tiles at --finalize)'
  }
end

# (f) missing folder (DM + workbook land in My Documents).
unless opts[:folder]
  questions << { 'id' => 'folder', 'severity' => 'required',
                 'detail' => 'No Sigma --folder supplied; DM + workbook will land in My Documents',
                 'options' => ['supply --folder <id>', 'proceed into My Documents'],
                 'default' => 'proceed into My Documents' }
end

answers = nil
if opts[:answers]
  answers = JSON.parse(opts[:answers]) rescue abort('FATAL: --answers is not valid JSON')
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'workbook' => wb_name,
    'phases_completed' => ['1 Discover', '1.6 DM-reuse scan (read-only)', '2 Warehouse columns (read-only)'],
    'note' => 'Deterministic mechanical steps (DM/workbook POST, layout, parity) are NOT asked about. ' \
              'Re-run with --yes to accept all defaults, or --answers \'{"<id>":"<choice>"}\' to override.',
    'open_questions' => questions
  }
  puts
  puts '==================== OPEN QUESTIONS ===================='
  puts JSON.pretty_generate(block)
  puts '======================================================='
  puts
  puts "#{questions.size} decision(s) need a human. No Sigma objects were created."
  phase_summary
  exit 10
end

if questions.any?
  puts
  line "decisions auto-resolved (#{opts[:yes] ? '--yes: defaults' : '--answers supplied'}):"
  questions.each do |q|
    chosen = (answers && answers[q['id']]) || q['default']
    tag = q['calc'] || q['viz']
    line "  - #{q['id']}#{tag ? " [#{tag}]" : ''}: #{chosen || '(no default — required)'}"
    if chosen.nil? && q['severity'] == 'required'
      abort "FATAL: required decision '#{q['id']}' has no default; re-run with --answers or fix inputs"
    end
  end
else
  line 'no open questions — running straight through'
end
mark('decisions')

# ---------------------------------------------------------------------------
# folderId default (bead epvr). POST /v2/dataModels/spec REQUIRES folderId
# ("Expecting UUID at 0.folderId"). When the human chose "proceed into My
# Documents" (--yes / answered default), RESOLVE the caller's My Documents
# folder id and inject it — never emit a folderId-less spec. (Same contract
# the quicksight converter enforces with its mandatory --folder-id.)
# ---------------------------------------------------------------------------
if opts[:folder].to_s.empty?
  require 'sigma_rest'
  begin
    uid = Sigma.request(:get, '/v2/whoami')['userId']
    entry = ((Sigma.request(:get, "/v2/members/#{uid}/files") || {})['entries'] || [])
            .find { |e| e['path'] == 'My Documents' }
    folder_id = entry && entry['parentId']
    unless folder_id
      entry2 = ((Sigma.request(:get, '/v2/files?typeFilters=folder&limit=500') || {})['entries'] || [])
               .find { |e| e['path'] == 'My Documents' && e['ownerId'] == uid }
      folder_id = entry2 && entry2['parentId']
    end
    abort "FATAL: could not resolve the caller's My Documents folder id (the DM POST requires folderId) — pass --folder <id>" unless folder_id
    opts[:folder] = folder_id
    line "folderId default: resolved caller's My Documents = #{folder_id} (no --folder supplied)"
  rescue Sigma::Error => e
    abort "FATAL: My Documents folder resolution failed (#{e.message.lines.first&.strip}) — pass --folder <id>"
  end
end
mark('folder-resolve')

# ---------------------------------------------------------------------------
# Phase 3 — Build + POST the data model.
# ---------------------------------------------------------------------------
hdr(3, 'Build data model')
dm_spec_path = File.join(WORK, 'dm-spec.json')
dm_ids_path = File.join(WORK, 'dm-ids.json')
if reuse_dm_id
  # REUSE: no build, no POST. Read the existing DM back into the same id-map
  # shape post-and-readback.rb emits (incl. per-element columnLabels — Phase 4's
  # master derivation resolves against them).
  $LOAD_PATH.unshift File.expand_path('lib', HERE)
  require 'sigma_rest'
  dm_spec_rb = Sigma.request(:get, "/v2/dataModels/#{reuse_dm_id}/spec")
  abort "FATAL: could not read back reused DM #{reuse_dm_id} spec" unless dm_spec_rb.is_a?(Hash) && dm_spec_rb['pages']
  cols_rb = (Sigma.request(:get, "/v2/dataModels/#{reuse_dm_id}/columns") rescue { 'entries' => [] })
  labels_by_el = Hash.new { |h, k| h[k] = [] }
  (cols_rb['entries'] || []).each { |c| labels_by_el[c['elementId']] << c['label'] if c['elementId'] && c['label'] }
  dm_ids = {
    'dataModelId' => reuse_dm_id,
    'pages' => (dm_spec_rb['pages'] || []).map do |p|
      { 'id' => p['id'], 'name' => p['name'],
        'elements' => (p['elements'] || []).map do |e|
          el = { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'] }
          el['columnLabels'] = labels_by_el[e['id']] if labels_by_el.key?(e['id'])
          el
        end }
    end
  }
  File.write(dm_ids_path, JSON.pretty_generate(dm_ids))
  dm_id = reuse_dm_id
  dm_els = dm_ids['pages'].flat_map { |p| p['elements'] }
  # The fact is the WIDEST non-dim element. Exclude both "<X> Dim" and "Dim <X>"
  # (so a date/time dim like "Dim Time" can't be picked) and tie-break by column
  # count, not list order.
  dim_re = /(^Dim\b| Dim$)/i
  fact = dm_els.reject { |e| e['name'] =~ dim_re }.max_by { |e| (e['columnLabels'] || []).size } ||
         dm_els.find { |e| e['name'] !~ dim_re } || dm_els.first
  fact_eid = fact['id']
  line "REUSED dataModelId = #{dm_id}  (fact element '#{fact['name']}' = #{fact_eid}, name-heuristic pick)"
elsif mechanical
  # The converter output IS the DM spec (schemaVersion:1 already set). Apply the
  # mechanical fixup (resolve raw-table-name prefixes + GUID sibling refs the
  # converter left unresolved) then stamp the human-supplied folderId. No agent
  # authoring.
  dm = conv['model'] # already fixed up in Phase 1 (prefixes/GUIDs resolved, bad calcs dropped)
  dm['name'] = wb_name if dm['name'].to_s.empty?
  dm['name'] = "#{opts[:name]} #{dm['name']}" if opts[:name]
  # Phantom-column filter (needs Phase 2's live warehouse columns): Tableau
  # virtual-connection datasources flatten dim columns into the fact and emit
  # base-column refs that don't exist in the real table. Drop them so the POST
  # resolves. Load the cols-<TABLE>.json files discovered in Phase 2.
  real_cols = {}
  dim_catalogs = {}
  Dir[File.join(WORK, 'cols-*.json')].each do |cf|
    cj = (JSON.parse(File.read(cf)) rescue nil)
    next unless cj && cj['columns']
    tname = File.basename(cf, '.json').sub(/^cols-/, '')
    real_cols[tname] = cj['columns'].map { |c| c['name'] }
    dim_catalogs[tname.upcase] = cj['columns']
  end
  unless real_cols.empty?
    pf = MechanicalSpecs.fixup_dm_spec(dm, real_cols)
    line "phantom-column filter: dropped #{pf[:phantom]} non-existent base column(s) using #{real_cols.size} live table catalog(s)" if pf[:phantom].to_i.positive?
  end
  # Computed-key join recovery (bead ovud): joins the converter skipped
  # ("DATE([Order Date]) = [Date Key]") are recovered mechanically — via a calc
  # key column, or via the physical "<X>_KEY" FK when the wrapped column is
  # VDS-only — so date axes resolve instead of NULL-bucketing.
  if have_twb
    MechanicalSpecs.recover_computed_key_joins!(dm, File.read(twb), real_cols, dim_catalogs)
                   .each { |m| line m }
  end
  # Relationship reachability guard (bead ovud): duplicate relationship names /
  # refs through nonexistent relationships make charts NULL-bucket SILENTLY.
  # Fail loudly BEFORE the POST.
  viols = MechanicalSpecs.relationship_reachability_violations(dm)
  if viols.any?
    puts
    puts '==================== RELATIONSHIP GUARD STOP ===================='
    viols.each { |v| puts "  - #{v}" }
    puts 'Every cross-element ref must resolve through a uniquely-named,'
    puts 'existing relationship ([Base/REL_NAME/Field]) or charts grouped'
    puts 'through it silently NULL-bucket. Fix the converter output / report'
    puts 'this as a converter bug — do NOT proceed to the POST.'
    puts '================================================================='
    abort 'FATAL: relationship reachability guard failed'
  end
else
  dm = Specs.dm_spec
  dm['name'] = "#{opts[:name]} #{dm['name'] || wb_name}".strip if opts[:name]
end
unless reuse_dm_id
  dm['folderId'] = opts[:folder] if opts[:folder]
  File.write(dm_spec_path, JSON.pretty_generate(dm))
  # In mechanical mode validate-spec.rb is advisory only: it flags cross-element
  # sibling refs that Sigma actually resolves via relationships (documented
  # false-negative class — see project CLAUDE.md). The authoritative gate is the
  # live POST + readback column-type guard below (post-and-readback exits 2 on any
  # error-typed column). For hand-authored Specs, keep validation hard.
  _, dvst = run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec_path],
                 allow_fail: mechanical)
  line 'DM validate-spec flagged issues (advisory in mechanical mode — live POST is the gate)' if mechanical && !dvst.success?
  sigma_run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
              '--spec', dm_spec_path, '--out', dm_ids_path, '--workdir', WORK])
  dm_ids = JSON.parse(File.read(dm_ids_path))
  dm_id = dm_ids['dataModelId']
  dm_els = dm_ids['pages'].flat_map { |p| p['elements'] }
  if mechanical
    # The master must source the SAME chart-ready element pick_fact chose (the
    # derived "<Fact> View" when present). Match it into the readback by name.
    cf = MechanicalSpecs.pick_fact(conv['model'])
    cf_name = cf && (cf['name'] || MechanicalSpecs.elem_name(cf))
    # Fallback (when the exact name match misses): the fact is the WIDEST non-dim
    # element — never a narrow date/time dim. Match pick_fact's dim test (both
    # "<X> Dim" and "Dim <X>") and tie-break by column count, not list order, so
    # "Dim Time" can't win just by appearing first.
    dim_re = /(^Dim\b| Dim$)/i
    fact = dm_els.find { |e| e['name'] == cf_name } ||
           dm_els.reject { |e| e['name'] =~ dim_re }.max_by { |e| (e['columnLabels'] || []).size } ||
           dm_els.max_by { |e| (e['columnLabels'] || []).size } || dm_els.first
  else
    dim_re = /(^Dim\b| Dim$)/i
    fact = dm_els.reject { |e| e['name'] =~ dim_re }.max_by { |e| (e['columnLabels'] || []).size } ||
           dm_els.find { |e| e['name'] !~ dim_re } || dm_els.first
  end
  fact_eid = fact['id']
  line "dataModelId = #{dm_id}  (fact element '#{fact['name']}' = #{fact_eid})"
end
mark('phase3-dm')

# ---------------------------------------------------------------------------
# Phase 4 — Build + POST the workbook.
# ---------------------------------------------------------------------------
hdr(4, 'Build workbook')
wb_spec_path = File.join(WORK, 'wb-spec.json')
display_wb_name = opts[:name] ? "#{opts[:name]} #{wb_name}" : wb_name
layout_xml = nil
if mechanical
  # 1) Derive the master-map DETERMINISTICALLY from the converter fact element,
  #    using the AUTHORITATIVE readback element name for the [fact/Col] formulas,
  #    AND the readback element's REAL column labels (the suffixed display names
  #    Sigma assigns to joined-dim columns, e.g. "Customer Id (CUSTOMER_DIM)") so
  #    the [fact/Col] formulas resolve for virtual-connection (denormalized) DMs.
  conv_fact = MechanicalSpecs.pick_fact(conv['model'])
  abort 'FATAL: mechanical path could not identify a fact element in the converter output' unless conv_fact
  conv_base = MechanicalSpecs.base_of(conv['model'], conv_fact)
  real_labels = fact['columnLabels'] # from post-and-readback /columns (may be nil)
  derived = MechanicalSpecs.derive_master(conv_fact, fact['name'], conv_base, real_labels, conv['model'])
  master_columns = derived['master_columns']
  mmap = derived['mmap']
  # Human-supplied master-calc overrides (--master-col): appended verbatim so a
  # chart ref like [master/Ship Speed Category] resolves on the next run.
  (opts[:master_cols] || []).each do |(nm, fx)|
    id = "m-#{nm.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')}"
    master_columns.reject! { |c| c['name'].casecmp?(nm) }
    master_columns << { 'id' => id, 'name' => nm, 'formula' => fx }
    # Register the override in the header->column regex map too (same pattern
    # shape as derive_master's entries) so chart dim headers AND shared-filter
    # captions resolve to it — without this, an --master-col like 'Order Date'
    # still left the shared Order-Date filter unmapped (no auto-control, charts
    # silently unfiltered vs the source view).
    mmap["(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of )?#{Regexp.escape(nm)}$"] =
      { 'id' => id, 'name' => nm }
    line "master-col override: '#{nm}' = #{fx[0, 80]}"
  end
  mmap_path = File.join(WORK, 'master-map.json')
  File.write(mmap_path, JSON.pretty_generate(mmap))
  line "master-map: #{master_columns.size} master column(s) (fact element '#{fact['name']}', #{real_labels ? real_labels.size : 0} readback labels)"

  # 2) Build the chart-element specs from the parsed zones + view CSVs + map.
  #    ONE SIGMA PAGE PER TABLEAU DASHBOARD (bead ptrt) — a fat workbook's 4
  #    dashboards become 4 laid-out pages, each with its own banded layout.
  charts_path = File.join(WORK, 'chart-specs.json')
  build_cmd = ['ruby', File.join(HERE, 'build-charts-from-signals.rb'),
               '--tableau-dir', WORK, '--layout', layout_json,
               '--master-map', mmap_path, '--master-element-id', 'master',
               '--page-per-dashboard',
               '--out', charts_path,
               '--coverage-out', File.join(WORK, 'coverage.json')]
  build_cmd += ['--meta', layout_json.sub(/\.json$/, '-meta.json')] if File.exist?(layout_json.sub(/\.json$/, '-meta.json'))
  build_cmd += ['--auto-controls'] if File.exist?(layout_json.sub(/\.json$/, '-meta.json'))
  run!(build_cmd, allow_fail: true)
  raw_charts = (JSON.parse(File.read(charts_path)) rescue [])
  chart_pages = raw_charts.is_a?(Hash) ? (raw_charts['pages'] || []) : nil
  data_elements = raw_charts.is_a?(Hash) ? (raw_charts['data_elements'] || []) : []
  chart_elements = chart_pages ? chart_pages.flat_map { |p| p['elements'] || [] } : raw_charts
  # Dim-grain helper placeholder resolution: build-charts runs before it knows
  # the live DM element ids, so grain helpers carry source.elementId =
  # "__DM_ELEMENT__:<name>". Resolve against the readback (dm_els) NOW — an
  # unresolvable grain element means the two-stage chart would silently misbind,
  # so fail loudly (same contract as the relationship guard).
  data_elements.each do |de|
    ph = de.dig('source', 'elementId').to_s
    next unless ph.start_with?('__DM_ELEMENT__:')
    want = ph.split(':', 2).last
    hit = dm_els.find { |e| e['name'].to_s.strip.casecmp?(want) }
    abort "FATAL: grain helper '#{de['name']}' needs DM element '#{want}' but the posted data model has no element " \
          "by that name (have: #{dm_els.map { |e| e['name'] }.join(', ')})" unless hit
    de['source'] = { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => hit['id'] }
    line "grain helper '#{de['name']}' → DM element '#{want}' (#{hit['id']})"
  end
  if chart_elements.empty?
    line 'WARN: build-charts produced 0 elements (no usable view CSVs / zones); emitting an empty dashboard page'
  else
    line "build-charts: #{chart_elements.size} chart/control element(s) across #{chart_pages ? chart_pages.size : 1} page(s)" \
         "#{data_elements.any? ? " + #{data_elements.size} hidden data element(s)" : ''}"
  end

  # MIGRATION COVERAGE — one consolidated "what carried over (and what didn't)"
  # readout (bead beads-sigma-59mk; ports powerbi-to-sigma PR #177). Leads with
  # what converted; nothing is silently dropped. Non-blocking — the build's
  # control_lint + visual-verify gates already hard-gate the recoverable classes.
  coverage = CoverageGate.load(File.join(WORK, 'coverage.json'))
  if coverage
    puts
    puts '==================== MIGRATION COVERAGE ===================='
    puts "   #{CoverageGate.headline(coverage)}"
    rlines = CoverageGate.report_lines(coverage)
    (puts; puts rlines.join("\n")) unless rlines.empty?
    cov_qs = CoverageGate.questions(coverage)
    unless cov_qs.empty?
      puts
      if opts[:yes] || opts[:answers]
        puts "   #{cov_qs.size} recoverable gap(s) — proceeding (unattended); recorded as accepted degradations."
      else
        puts '-------------------- ASSISTANCE AVAILABLE --------------------'
        puts "   #{cov_qs.size} gap(s) are RECOVERABLE — ask the user whether to recover or accept each."
        puts JSON.pretty_generate('recoverable_gaps' => cov_qs)
      end
    end
    puts '==========================================================='
  end

  # 3) Assemble the workbook spec (page-data master [+ hidden helpers] + one
  #    page per dashboard).
  spec = MechanicalSpecs.build_wb_spec(
    name: display_wb_name, dm_id: dm_id, fact_eid: fact_eid,
    master_columns: master_columns,
    chart_elements: (chart_pages && chart_pages.any? ? chart_pages : chart_elements),
    data_elements: data_elements,
    folder_id: opts[:folder])
else
  spec = Specs.wb_spec(dm_id, fact_eid)
  spec['name'] = display_wb_name if opts[:name]
  spec['folderId'] = opts[:folder] if opts[:folder]
  layout_xml = (Specs.respond_to?(:layout_xml) ? Specs.layout_xml : nil)
end
File.write(wb_spec_path, JSON.pretty_generate(spec))
wb_ids_path = File.join(WORK, 'wb-ids.json')

# GRACEFUL AGENT-PATH FALLBACK. The DM is already posted + valid (dm_id above), so
# if the MECHANICAL workbook layer (validate-spec / build / POST) hits a field it
# cannot translate (Sigma rejects the spec / unresolved "Dependency not found" /
# unmapped derived-dim or measure), we must NOT bare-crash. Catch it and exit with
# a clear, FRIENDLY non-zero handoff: the agent path rebuilds the workbook against
# this DM (see SKILL.md). Never worse than the proven agent path.
begin
  v_log = run_wb!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'workbook',
                   '--dm-context', dm_ids_path, wb_spec_path])
  p_log = sigma_run_wb!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
                         '--spec', wb_spec_path, '--out', wb_ids_path, '--workdir', WORK])
rescue WorkbookBuildError => e
  failed = cull_failed_fields(e.captured_output,
                              (defined?(v_log) ? v_log : ''), (defined?(p_log) ? p_log : ''))
  # Fall back to the mechanically-known untranslatable fields when the log itself
  # doesn't name one (plotted-but-unresolved metrics + dropped calc columns).
  if failed.empty? && mechanical
    failed = ((defined?(plotted_untranslated) && plotted_untranslated || []) +
              (defined?(dropped_calcs) && dropped_calcs || [])).compact.uniq
  end
  names = failed.empty? ? 'one or more fields' : failed.join(', ')
  n = failed.empty? ? 'some' : failed.size.to_s
  puts
  puts "── Mechanical path: data model built OK (dataModelId=#{dm_id}). The WORKBOOK " \
       "layer hit #{n} field(s) the mechanical path can't translate (#{names}). " \
       'Two ways forward:'
  puts "   1. If the field is a MASTER-LEVEL CALC (a binned/categorized dim like 'Ship"
  puts "      Speed Category'), translate its Tableau formula (see calc-fields.json) to"
  puts '      a Sigma formula over master columns and re-run this exact command with:'
  puts "        --master-col '<Name>=<Sigma formula>'   (repeatable)"
  puts '   2. Otherwise fall back to the agent path: rebuild the workbook via the'
  puts "      skill's agent-authored flow (see SKILL.md) against this DM."
  puts '   The data model is posted and ready to attach either way.'
  mark('phase4-workbook')
  phase_summary
  exit 4
end
wb_ids = JSON.parse(File.read(wb_ids_path))
wb_id = wb_ids['workbookId']
line "workbookId = #{wb_id}"
mark('phase4-workbook')

# ---------------------------------------------------------------------------
# Phase 5 — Layout. Prefer the generator's layout_xml; else auto-build from the
# parsed Tableau zone tree via build-dashboard-layout.rb.
# ---------------------------------------------------------------------------
hdr(5, 'Layout')
layout_path = File.join(WORK, 'layout.xml')
if layout_xml
  File.write(layout_path, layout_xml)
  line 'layout from spec generator'
elsif File.exist?(layout_json)
  _, lst = run!(['ruby', File.join(HERE, 'build-dashboard-layout.rb'),
                 '--layout', layout_json, '--wb-ids', wb_ids_path, '--out', layout_path,
                 '--row-scale', (opts[:row_scale] || 1.5).to_s],
                allow_fail: true)
  line 'WARN: layout build failed — workbook will render in default stacked order' unless lst.success?
else
  line 'no layout source — skipping (workbook renders single-column stack)'
end
# Layout is cosmetic: a bad grid PUT must NOT fail an otherwise-good migration
# (the workbook still renders + queries). Apply best-effort.
if File.exist?(layout_path)
  _, pst = sigma_run!(['ruby', File.join(HERE, 'put-layout.rb'),
                       '--workbook', wb_id, '--layout', layout_path], allow_fail: true)
  line(pst.success? ? "layout applied to workbook #{wb_id}" :
       'WARN: layout PUT rejected (Invalid element position) — keeping default stacked layout; charts unaffected')
end
mark('phase5-layout')

# ---------------------------------------------------------------------------
# Phase 5b — Visual QA: render each content page to a full-page PNG so the
# layout can be reviewed against refs/layout-visual-qa.md AND compared to the
# source Tableau dashboard — the cross-converter visual-QA gate. Page ids come
# from the LOCAL wb-spec.json (deterministic; the live /spec readback is flaky
# and returns YAML); token via get-token.sh inside sigma_run!. Non-fatal — a
# transient export failure must not sink a green migration; the REVIEW is the gate.
# ---------------------------------------------------------------------------
hdr('5b', 'Visual QA')
vqa = File.join(WORK, 'visual-qa'); FileUtils.mkdir_p(vqa)
wbspec_local = (JSON.parse(File.read(wb_spec_path)) rescue {})
content_pages = (wbspec_local['pages'] || []).reject { |p| p['id'].to_s.downcase.include?('data') }
rendered = 0
content_pages.each do |pg|
  out = File.join(vqa, "#{pg['id']}.png")
  _o, st = sigma_run!(['python3', File.join(HERE, 'sigma-export-png.py'),
                       '--workbook', wb_id, '--page', pg['id'], '--out', out, '--w', '1800', '--h', '1000'],
                      allow_fail: true)
  st.success? ? (rendered += 1) : line("WARN: visual-QA render failed for page #{pg['id']}")
end
line "rendered #{rendered}/#{content_pages.size} full-page PNG(s) → #{vqa}"
line 'VISUAL QA (review, do not skip): open each PNG; check vs refs/layout-visual-qa.md AND the source Tableau dashboard — titles, right chart kinds, colors, no overlaps/dead zones.' if rendered.positive?
mark('phase5b-visual-qa')

# ---------------------------------------------------------------------------
# Phase 6 — Parity, PASS 1 of 2. Structural hard signals first (live /columns
# type=error re-check after the layout PUT + per-chart compile check), then
# phase6-parity.rb pass 1 builds the parity plan and emits the per-chart MCP
# query list. VALUE parity needs the mcp-v2 actuals — this process cannot fetch
# them (no synchronous chart-data REST endpoint), so it stops HONESTLY at exit
# 12 with resume instructions instead of declaring a fake PASS.
# ---------------------------------------------------------------------------
hdr(6, 'Parity (pass 1 of 2)')
require 'sigma_rest'

# Structural hard signal: no live column resolves to type "error".
cols = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/columns") rescue { 'entries' => [] })
err_cols = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
total_cols = (cols['entries'] || []).size
# Compile-check chart elements (Unknown column / Circular ref markers).
chart_els = wb_ids['pages'].reject { |p| p['id'].to_s =~ /data/ }
                           .flat_map { |p| p['elements'] || [] }
                           .select { |e| e['kind'].to_s.end_with?('-chart') }
bad = []
chart_els.each do |e|
  b = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/elements/#{e['id']}/query", accept: 'text/plain') rescue '')
  bad << (e['name'] || e['id']) if b.to_s =~ /Unknown column "\[|Circular column reference/
end
structural_ok = err_cols.empty? && bad.empty?
if structural_ok
  line "structural: PASS — #{total_cols} workbook column(s) resolve (0 error-typed); " \
       "#{chart_els.size} chart element(s) compile clean"
else
  line "structural: FAIL — #{err_cols.size}/#{total_cols} error-typed column(s)#{bad.any? ? ", #{bad.size} chart(s) with unresolved refs (#{bad.join(', ')})" : ''}"
  err_cols.first(8).each { |c| line "  [#{c['elementId']}] #{c['label']}: #{c['formula']}" }
end

# Persist resume state for --finalize (pass 2) BEFORE stopping.
state = { 'workbook_id' => wb_id, 'data_model_id' => dm_id,
          'extract_mode' => !!has_extracts, 'workbook_name' => display_wb_name,
          'reused_dm' => !!reuse_dm_id, 'pass1_at' => Time.now.utc.iso8601,
          'enhance_requested' => !!opts[:enhance] }
File.write(File.join(WORK, 'migrate-state.json'), JSON.pretty_generate(state))

unless structural_ok
  puts
  puts '================ RESULT ================'
  puts "dataModelId : #{dm_id}"
  puts "workbookId  : #{wb_id}"
  puts "PARITY      : FAIL (structural — #{err_cols.size} error column(s); fix before the value pass)"
  puts '======================================='
  mark('phase6-pass1')
  phase_summary
  exit 3
end

# phase6-parity PASS 1: builds parity-plan.json + prints one mcp-v2 query per chart.
p6 = ['ruby', File.join(HERE, 'phase6-parity.rb'),
      '--tableau', WORK, '--workbook-id', wb_id]
p6 += ['--extract-mode', '--extract-tol', '0.30'] if has_extracts
sigma_run!(p6)

# Phase 6f-visual — tiles whose Tableau data export came back EMPTY (action-
# filter-gated etc.) were BUILT from .twb signals and have no actuals to value-
# diff. Stage an IMAGE comparison (Tableau view image vs Sigma element render)
# so they're verified visually instead of silently passing parity.
vv_sidecar = File.join(WORK, 'visual-verify-tiles.json')
vv_tiles = File.exist?(vv_sidecar) ? (JSON.parse(File.read(vv_sidecar)) rescue []) : []
if vv_tiles.any?
  line "Phase 6f-visual: #{vv_tiles.size} tile(s) had EMPTY data exports / inferred chart kinds — staging per-tile image comparison"
  sigma_run!(['ruby', File.join(HERE, 'verify-visual-tiles.rb'),
              '--workbook', wb_id, '--tableau-dir', WORK], allow_fail: true)
end

# Phase 6f — FULL-DASHBOARD ground truth: stage the source Tableau dashboard
# image next to the Sigma page render per dashboard, so the mandatory whole-page
# visual comparison (and the repair loop: diff → fix → re-render) has both sides
# ready. Writes visual-qa/compare-manifest.json (agent sets visual_match).
line 'Phase 6f-visual: staging full-dashboard source-vs-Sigma image pairs for the repair loop'
sigma_run!(['ruby', File.join(HERE, 'verify-dashboard-visual.rb'),
            '--workbook', wb_id, '--tableau-dir', WORK], allow_fail: true)

puts
puts '================ RESULT (pass 1 — parity PENDING) ================'
puts "dataModelId : #{dm_id}#{reuse_dm_id ? '  (REUSED existing DM)' : ''}"
puts "workbookId  : #{wb_id}"
puts "structural  : PASS (#{total_cols} cols resolve, #{chart_els.size} charts compile)"
if $rls_pending
  puts "RLS         : DETECTED, NOT APPLIED — see #{File.join(WORK, 'security.json')}; provision + apply"
  puts '              via scripts/apply_sigma_rls.py before sharing (the model returns ALL rows until then)'
end
puts 'PARITY      : PENDING — the pooled collector filled parity-actuals.json for every'
puts '              exportable chart; run the REMAINING mcp-v2 queries printed above'
puts "              (if any), merge into #{File.join(WORK, 'parity-actuals.json')}, then:"
puts 'VISUAL      : FULL-DASHBOARD comparison staged — READ each source vs Sigma pair under'
puts "              #{File.join(WORK, 'visual-qa')}/ (<dash>.source.png vs <dash>.sigma.png). Diff layout,"
puts '              chart kinds, sizing; fix the spec + re-render for any divergence; set "visual_match":true'
puts '              per dashboard in compare-manifest.json (the repair loop).'
if vv_tiles.any?
  puts "              ALSO #{vv_tiles.size} per-tile pair(s) under #{File.join(WORK, 'visual-verify')}/ — tiles with"
  puts '              EMPTY data exports or INFERRED chart kinds (no value-diff possible). Confirm each and set'
  puts '              "visual_verified": true in visual-verify/manifest.json (gate 9 blocks GREEN until done).'
end
finalize_cmd = "  ruby scripts/migrate-tableau.rb #{opts[:wb_id] ? "--workbook-id #{opts[:wb_id]}" : "--workbook \"#{opts[:wb_name]}\""}" \
               "#{opts[:out] ? " --out #{WORK}" : ''} \\\n    --finalize --actuals #{File.join(WORK, 'parity-actuals.json')}"
puts finalize_cmd
puts '(--finalize runs phase6 finalize + orphan cleanup + the census-aware'
puts ' assert-phase6-ran hard gate; exit 0 there is the ONLY green exit.)'
puts 'PHASE E     : requested (--enhance) — runs at --finalize AFTER all gates are green' if opts[:enhance]
puts '=================================================================='
mark('phase6-pass1')
phase_summary
exit 12
