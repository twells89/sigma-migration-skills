#!/usr/bin/env ruby
# migrate-powerbi.rb — ONE-SHOT, single-process orchestrator for the
# powerbi-to-sigma pipeline. Runs the whole phased workflow in one Ruby process
# to cut agent turns / token cost, WITHOUT turning the migration into a black
# box: every phase prints a visible header + concise result, and the genuine
# human decision points are surfaced as a structured OPEN QUESTIONS block
# (exit 10) rather than silently auto-resolved.
#
# Modeled on quicksight-to-sigma/scripts/migrate-quicksight.rb. It does NOT
# re-implement any phase — it chains the EXISTING scripts + the local
# convert_powerbi_to_sigma converter build:
#   explode the PBIR bundle + extract-pbir.py        (Phase 1 Discover/Extract)
#   convertPowerBIToSigma() via a node shim           (Phase 2 Convert)
#   convert-model.rb --converter-out (fixups)         (Phase 3 Build DM)
#     + validate-spec.rb + post-and-readback.rb
#   auto master-map + build-workbook-from-pbir.rb     (Phase 4 Build workbook)
#     + post-and-readback.rb
#   put-layout.rb                                     (Phase 5 Layout)
#   /columns error-type guard + per-element probe     (Phase 6 Parity)
#
# The convert_powerbi_to_sigma MCP tool is an ESM module; we import its exported
# convertPowerBIToSigma() directly via a tiny node shim (same trick as the QS
# orchestrator). Override the build dir with PBI_MCP_DIR.
#
# The one PBI-specific artifact a human normally authors — master-map.json (maps
# each PBI Entity.Field queryRef -> {master, ref, agg}) — is DERIVED here
# deterministically from the converter output (element name + column display
# names + translated metric formulas) cross-referenced with the PBIR queryRefs.
# DAX measures the converter could not translate (the (c)-tail) surface as OPEN
# QUESTIONS, not silent Null columns.
#
# Usage:
#   eval "$(scripts/get-token.sh)"   # Sigma token in env first (or rely on ~/.sigma-migration/env)
#   ruby scripts/migrate-powerbi.rb \
#     --tmsl /tmp/assessment-pbi-live/raw-tmsl/Test__Superstore_Overview.tmsl \
#     --pbir /tmp/assessment-pbi-live/raw-pbir/Test__Superstore_Overview.json \
#     --connection <SIGMA_CONN_UUID> --database TJ --schema PUBLIC \
#     --ref-dm <referenceDataModelId> \
#     [--name "Superstore Overview (from Power BI)"] [--folder <id>] \
#     [--out DIR] [--answers '<json>'] [--yes] \
#     [--mcp-dir <sigma-data-model-mcp clone> | --converter-out <mcp-tool result.json>] \
#     [--python <interpreter>]
#
# Converter route (bead 7o01): with a local sigma-data-model-mcp build (--mcp-dir /
# PBI_MCP_DIR / ~/Desktop or ~/ clone) the conversion runs in-process via a node
# shim. WITHOUT one, Phase 2 stops with a gate: run the convert_powerbi_to_sigma
# MCP tool yourself and resume with --converter-out <its result JSON> — the
# default route on machines without a local build.
#
# Phase E (OPT-IN) — Enhance: pass --enhance to run the shared enhancement
# engine AFTER parity passes: enhance-scan.rb emits candidates; nothing applies
# without --enhance-accept <ids|all-low-risk> (without it the run stops at exit
# 14 with the proposals); enhance-apply.rb then clones the parity workbook
# ("<name> — Enhanced") and applies accepted items one at a time under a
# parity-unchanged gate. Default = OFF everywhere.
#
# Exit codes: 0 = done (parity pass); 10 = decisions needed (OPEN QUESTIONS); 3 = parity fail;
# 14 = parity PASS + Phase E proposals pending acceptance (re-run with --enhance-accept); other = error.
require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require 'digest'
require 'set'

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'scout_gate'    # run-each-time gap-scout gate (bead beads-sigma-5l5e)
require 'dax_gate'      # DAX warning → decision-question classifier (regression-tested)
require 'coverage_gate' # workbook-build coverage.json → consolidated report + assistance prompt

opts = { db: '', schema: '' }
OptionParser.new do |o|
  o.on('--tmsl PATH')       { |v| opts[:tmsl]   = File.expand_path(v) }
  o.on('--pbir PATH')       { |v| opts[:pbir]   = File.expand_path(v) }
  o.on('--connection ID')   { |v| opts[:conn]   = v }
  o.on('--database DB')     { |v| opts[:db]     = v }
  o.on('--schema S')        { |v| opts[:schema] = v }
  o.on('--ref-dm ID')       { |v| opts[:ref_dm] = v }
  o.on('--folder ID')       { |v| opts[:folder] = v }
  o.on('--name NAME')       { |v| opts[:name]   = v }
  # SOURCE report display name (Fabric/Power BI "EMPLOYEE DASHBOARD") — used as
  # the header-band title fallback when a page has no promotable title textbox
  # and its own name is a generic "Page N". Defaults to the humanized slug.
  o.on('--source-title NAME') { |v| opts[:source_title] = v }
  o.on('--out DIR')         { |v| opts[:out]    = File.expand_path(v) }
  o.on('--answers JSON')    { |v| opts[:answers]= v }
  o.on('--yes')             {     opts[:yes]    = true }
  # bead 7o01 portability: no hardcoded developer paths. --mcp-dir / PBI_MCP_DIR
  # selects a local sigma-data-model-mcp build; --converter-out feeds a converter
  # result produced by the convert_powerbi_to_sigma MCP TOOL (the default route
  # when no local build exists); --python / PBI_PY picks the Python interpreter.
  o.on('--mcp-dir DIR')        { |v| opts[:mcp_dir] = File.expand_path(v) }
  o.on('--converter-out PATH') { |v| opts[:cvt_out] = File.expand_path(v) }
  o.on('--python PATH')        { |v| opts[:python]  = File.expand_path(v) }
  # bead fmte — SOURCE-FRESHNESS PREFLIGHT. --workspace/--dataset identify the
  # LIVE semantic model (workspace id or "me" for My workspace) so Phase 1.5 can
  # pull its refresh history + a cheap executeQueries snapshot. Optional: without
  # them the preflight is skipped (offline TMSL+PBIR-only runs still work).
  o.on('--workspace ID')       { |v| opts[:ws] = v }
  o.on('--dataset ID')         { |v| opts[:dataset] = v }
  o.on('--skip-freshness')     {     opts[:skip_fresh] = true }
  # Phase E (opt-in) — Enhance. NEVER runs without --enhance; with --enhance
  # but no --enhance-accept the run stops at exit 14 with the scan proposals
  # (present them per-item to the human, e.g. AskUserQuestion), then re-run
  # with --enhance-accept <id,id,...> or 'all-low-risk'.
  o.on('--enhance')            {     opts[:enhance] = true }
  o.on('--enhance-accept L')   { |v| opts[:enhance_accept] = v }
  # DM-REUSE (reuse-first). The scan runs by DEFAULT (Phase 2.9) and auto-reuses
  # an existing Sigma data model that already covers this model's warehouse
  # table(s) + columns, instead of building a 4th near-identical DM. --reuse-dm
  # forces a specific existing dataModelId (skips the scan); --no-reuse always
  # builds a new DM.
  o.on('--reuse-dm ID')        { |v| opts[:reuse_dm] = v }
  o.on('--no-reuse')           {     opts[:no_reuse] = true }
end.parse!

abort 'missing --tmsl' unless opts[:tmsl]
abort "--tmsl not found: #{opts[:tmsl]}" unless opts[:tmsl] && File.exist?(opts[:tmsl])
abort 'missing --pbir' unless opts[:pbir]
abort "--pbir not found: #{opts[:pbir]}" unless File.exist?(opts[:pbir])
# bead hjke(a): abort early on a truncated/partial connection id — it survives
# all the way to the DM POST and fails there opaquely ("Source not found").
if opts[:conn] && opts[:conn] !~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  abort "FATAL: --connection must be a FULL Sigma connection UUID (8-4-4-4-12 hex); " \
        "got #{opts[:conn].inspect}. List connections with GET /v2/connections."
end

# Local converter build (the convert_powerbi_to_sigma MCP tool, imported directly).
# bead 7o01: no hardcoded developer paths — resolve from --mcp-dir / PBI_MCP_DIR,
# else probe common clone locations under $HOME. When NONE is found, Phase 2 does
# NOT abort: it stops with a gate instructing the agent to run the
# convert_powerbi_to_sigma MCP tool and resume with --converter-out (the default
# converter route on machines without a local build).
MCP_DIR = [opts[:mcp_dir], ENV['PBI_MCP_DIR'],
           File.expand_path('~/Desktop/sigma-data-model-mcp'),
           File.expand_path('~/sigma-data-model-mcp')]
          .compact.find { |d| File.exist?(File.join(d, 'build', 'powerbi.js')) }

name_slug = File.basename(opts[:tmsl], '.*').gsub(/[^A-Za-z0-9_-]/, '-')
WORK = opts[:out] || File.expand_path("~/powerbi-migration/#{name_slug}")
FileUtils.mkdir_p(WORK)
WB_NAME = opts[:name] || "#{name_slug.gsub(/[_]+/, ' ').strip} (from Power BI)"

# ---- phase timings (always written to <WORK>/timings.json) ------------------
# Fast-discovery evidence trail: every terminal exit (success, decisions gate,
# parity fail, workbook fallback) prints a PHASE TIMINGS line and persists the
# per-phase wall clock, so old-vs-new discovery comparisons are always possible.
$phase_times = []
$phase_open = nil
def phase_mark(name)
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  $phase_times << [$phase_open[0], (now - $phase_open[1]).round(1)] if $phase_open
  $phase_open = name ? [name, now] : nil
end
at_exit do
  phase_mark(nil)
  unless $phase_times.empty?
    total = $phase_times.sum { |_, s| s }.round(1)
    begin
      File.write(File.join(WORK, 'timings.json'), JSON.pretty_generate(
        { 'phases' => $phase_times.map { |n, s| { 'phase' => n, 'seconds' => s } },
          'totalSeconds' => total }))
    rescue StandardError
      nil # timings are evidence, never a failure
    end
    puts
    puts 'PHASE TIMINGS  ' + $phase_times.map { |n, s| "#{n}=#{s}s" }.join('  ') + "  total=#{total}s"
  end
end

def hdr(n, total, title)
  phase_mark("#{n}-#{title.downcase.gsub(/[^a-z0-9]+/, '-')}")
  puts
  puts "── Phase #{n}/#{total} · #{title} ──"
end

def run!(cmd, env: {})
  out, st = Open3.capture2e(env, *cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success?
  out
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
# abort()ing the process. Captures the child output so the caller can mine it for
# the offending field name(s) ("Dependency not found", "Unknown column", etc.).
def run_wb!(cmd, env: {})
  out, st = Open3.capture2e(env, *cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  raise WorkbookBuildError.new("command failed (#{st.exitstatus}): #{cmd.join(' ')}", out) unless st.success?
  out
end

# Pull likely-offending field/column names out of a failed workbook build/POST log
# so the fallback message can name them. Looks for the common rejection shapes:
#   "Dependency not found: <X>", "Unknown column \"[<X>]\"", "source: {} ... <X>",
#   "Invalid value: undefined", unresolved [El/Col] refs.
def cull_failed_fields(*logs)
  text = logs.join("\n")
  names = []
  text.scan(/Dependency not found:?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Unknown column\s*"?\[?([^"\]\n]+)\]?"?/i) { |m| names << m[0].strip }
  text.scan(/unmapped (?:derived[- ]dim|measure|field)\s*[:=]?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Circular column reference[^\n]*\[([^\]]+)\]/i) { |m| names << m[0].strip }
  names.map { |n| n.gsub(/[\[\]"]/, '').strip }.reject(&:empty?).uniq
end

TOTAL = 6

# ---------------------------------------------------------------------------
# Phase 1 — Discover / Extract (explode the PBIR bundle, parse TMSL + signals)
# ---------------------------------------------------------------------------
hdr(1, TOTAL, 'Discover / Extract')

# The raw-pbir/*.json files are a FLAT bundle: { "<part-path>": "<json text>", ... }.
# extract-pbir.py wants an exploded definition/ folder — so explode it first.
pbir_dir = File.join(WORK, 'pbir')
FileUtils.mkdir_p(pbir_dir)
bundle = JSON.parse(File.read(opts[:pbir]))
exploded = 0
bundle.each do |part, payload|
  next unless part.start_with?('definition/') # the exploded-PBIR parts only
  fp = File.join(pbir_dir, part)
  FileUtils.mkdir_p(File.dirname(fp))
  File.write(fp, payload.is_a?(String) ? payload : JSON.pretty_generate(payload))
  exploded += 1
end
# bead anlb (orchestrator parity with run.sh): a fetched definition may be the
# CLASSIC single report.json (top-level sections[]) instead of exploded PBIR
# parts. Branch to extract-report-classic.py — same signals.json schema out.
classic_rj = nil
if exploded.zero? && bundle.key?('report.json')
  classic_rj = File.join(pbir_dir, 'report.json')
  payload = bundle['report.json']
  File.write(classic_rj, payload.is_a?(String) ? payload : JSON.pretty_generate(payload))
end
abort "FATAL: PBIR bundle has no definition/ parts and no classic report.json — keys=#{bundle.keys.first(3)}" if exploded.zero? && classic_rj.nil?

signals_path = File.join(WORK, 'signals.json')
# bead 7o01: Python resolution — --python / PBI_PY, else a bootstrapped venv
# (run.sh creates <work-dir>/.venv), else the legacy /tmp/pbiauth venv, else
# system python3 (sufficient here: the offline PBIR parse is stdlib-only).
PY = opts[:python] || ENV['PBI_PY'] ||
     [File.join(WORK, '.venv', 'bin', 'python'), '/tmp/pbiauth/bin/python']
       .find { |p| File.exist?(p) } || 'python3'
if classic_rj
  puts '   classic single report.json detected — branching to extract-report-classic.py'
  run!([PY, File.join(HERE, 'extract-report-classic.py'), '--report-json', classic_rj, '--out', signals_path])
else
  run!([PY, File.join(HERE, 'extract-pbir.py'), '--pbir-dir', pbir_dir, '--out', signals_path])
end
signals = JSON.parse(File.read(signals_path))

# TMSL model summary + import/DirectQuery mode.
tmsl = JSON.parse(File.read(opts[:tmsl]))
model = tmsl['model'] || tmsl
tables = (model['tables'] || []).reject { |t| t['name'].to_s.start_with?('LocalDateTable_', 'DateTableTemplate_') }
all_measures = tables.flat_map { |t| (t['measures'] || []).map { |m| [t['name'], m['name'], Array(m['expression']).join] } }
modes = tables.flat_map { |t| (t['partitions'] || []).map { |p| p['mode'] } }.compact.uniq
mode_summ = modes.empty? ? 'unknown' : modes.join('/')

all_visuals = signals['pages'].flat_map { |p| p['visuals'] }
vkinds = all_visuals.each_with_object(Hash.new(0)) { |v, h| h[v['visual_type']] += 1 }
vsumm = vkinds.map { |k, c| c > 1 ? "#{k}×#{c}" : k }.join(', ')
puts "   model '#{name_slug}': #{tables.size} table(s), #{tables.sum { |t| (t['columns'] || []).size }} column(s), " \
     "#{all_measures.size} measure(s), mode=#{mode_summ}"
puts "   report: #{signals['pages'].size} page(s), #{all_visuals.size} visual(s) (#{vsumm})"

# --- Phase 1.5 — SOURCE-FRESHNESS PREFLIGHT (bead fmte) — NON-BLOCKING ------
# An import-mode PBI model is a frozen snapshot; Sigma reads the LIVE warehouse.
# The preflight (refresh history + per-table executeQueries snapshot) is only
# CONSUMED at Phase 6 parity, so it runs as a BACKGROUND LANE concurrent with
# Phase 2 Convert / Phase 3-5 build instead of blocking the pipeline for its
# 3-8s of Power BI round-trips. Joined (with the log replayed) at Phase 6.
# Best-effort: a preflight failure warns and continues. If the run stops at a
# gate (decisions exit 10 / converter gate), the detached probe still finishes
# and writes freshness.json for the resume run, which reuses it.
fresh_path = File.join(WORK, 'freshness.json')
fresh_log  = File.join(WORK, 'freshness.log')
fresh_waiter = nil
if File.exist?(fresh_path) && !opts[:skip_fresh]
  puts "   freshness.json already present — reusing (delete #{fresh_path} to re-probe)"
elsif opts[:ws] && opts[:dataset] && !opts[:skip_fresh] && modes.include?('import')
  fresh_pid = Process.spawn(PY, File.join(HERE, 'pbi-freshness.py'),
                            '--workspace', opts[:ws], '--dataset', opts[:dataset],
                            '--tmsl', opts[:tmsl], '--out', fresh_path,
                            out: fresh_log, err: fresh_log)
  fresh_waiter = Process.detach(fresh_pid)
  puts "   freshness preflight launched NON-BLOCKING (pid #{fresh_pid}) — runs alongside Convert/Build, consumed at Phase 6"
elsif opts[:ws] && opts[:dataset] && !opts[:skip_fresh]
  puts "   (freshness preflight skipped — model is #{mode_summ}, not import-mode: Sigma and PBI both read live)"
end

# ---------------------------------------------------------------------------
# Phase 2 — Convert (run convertPowerBIToSigma via a node shim)
# ---------------------------------------------------------------------------
hdr(2, TOTAL, 'Convert')
if opts[:cvt_out]
  # bead 7o01: converter output supplied (the convert_powerbi_to_sigma MCP tool
  # ran out-of-process — the default route when no local build exists). Unwrap
  # the {model,...} / {sigmaDataModel} wrapper the same way the shim does.
  raw = JSON.parse(File.read(opts[:cvt_out]))
  bare = raw['model'] || raw['sigmaDataModel'] || raw
  File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(bare))
  File.write(File.join(WORK, 'conv-meta.json'),
             JSON.pretty_generate({ 'model' => bare, 'warnings' => raw['warnings'] || [],
                                    'stats' => raw['stats'] || {} }))
  puts "   converter output ingested from #{opts[:cvt_out]}"
elsif MCP_DIR.nil?
  puts '   no local sigma-data-model-mcp build found (set --mcp-dir / PBI_MCP_DIR for the in-process route).'
  puts
  puts '   >>> GATE: run the convert_powerbi_to_sigma MCP tool on the TMSL model'
  puts "       (#{opts[:tmsl]}) with connectionId=#{opts[:conn]} database=#{opts[:db]} schema=#{opts[:schema]},"
  puts '       save the tool result JSON to a file, then re-run this command with'
  puts '       --converter-out <that file>. No Sigma objects were created.'
  exit 10
end
unless opts[:cvt_out]
shim = File.join(WORK, '_convert.mjs')
File.write(shim, <<~JS)
  import { readFileSync, writeFileSync } from 'node:fs';
  import { convertPowerBIToSigma } from #{File.join(MCP_DIR, 'build', 'powerbi.js').to_json};
  const model = JSON.parse(readFileSync(#{opts[:tmsl].to_json}, 'utf8'));
  const out = convertPowerBIToSigma(model, {
    connectionId: #{(opts[:conn] || '').to_json},
    database: #{opts[:db].to_json},
    schema: #{opts[:schema].to_json},
  });
  // Write the UNWRAPPED model to dm-raw.json. convert-model.rb MODE B unwraps
  // only {sigmaDataModel} or a bare spec, NOT this converter's {model,...}
  // wrapper, so it must receive the bare model (else "pages: Invalid array").
  const bare = out.model || out.sigmaDataModel || out;
  writeFileSync(#{File.join(WORK, 'dm-raw.json').to_json}, JSON.stringify(bare, null, 2));
  writeFileSync(#{File.join(WORK, 'conv-meta.json').to_json}, JSON.stringify({ model: bare, warnings: out.warnings || [], stats: out.stats || {} }, null, 2));
  process.stderr.write('CONVSTATS ' + JSON.stringify({ warnings: out.warnings || [], stats: out.stats || {} }) + '\\n');
JS
_c_out, c_err, c_st = Open3.capture3('node', shim)
abort "FATAL: converter failed:\n#{c_err}#{_c_out}" unless c_st.success?
puts "   converter ran (build: #{MCP_DIR})"
end
conv = JSON.parse(File.read(File.join(WORK, 'conv-meta.json')))
dm_model = conv['model']
conv_warnings = conv['warnings'] || []
conv_stats = conv['stats'] || {}
puts "   #{conv_stats['elements'] || (dm_model['pages'] || []).flat_map { |p| p['elements'] || [] }.size} element(s), " \
     "#{conv_stats['columns']} column(s), #{conv_stats['metrics']} metric(s); #{conv_warnings.size} converter warning(s)"

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine human questions
# ---------------------------------------------------------------------------
questions = []

# (a) + (b) DAX measures with no Sigma equivalent ((c)-tail) / DAX needing restructure.
# Classification lives in lib/dax_gate.rb (pure + unit-tested in test-dax-gate.rb).
# The converter marks each warning: ⛔ = no/failed translation (drops to Null);
# ⚠ = restructure-needed; ✅ = SUCCESS (auto-translated — RANKX→SQL window helper,
# USERELATIONSHIP→alternate join path); ℹ = informational. Only ⛔ and genuinely
# DROPPED ⚠ become decisions — ✅/ℹ and any ⚠ the converter actually REALIZED in the
# DM (e.g. time-intel → grouped element) are handled, NOT degradations. Regression fix:
# the gate used to bucket ✅ and built restructures as "needs scout", stalling --yes.
questions.concat(DaxGate.dax_questions(conv_warnings, dm_model))

# (b) visuals with no NATIVE Sigma kind. extract-pbir maps unknown visualTypes to
# "bar" as a fallback; flag any visualType that is NOT a recognized native PBI kind
# so a human confirms the approximation (treemap/funnel/gauge/map/etc.).
NATIVE = %w[card multiRowCard kpi textbox actionButton lineChart areaChart
            stackedAreaChart barChart clusteredBarChart stackedBarChart columnChart
            clusteredColumnChart stackedColumnChart hundredPercentStackedColumnChart
            hundredPercentStackedBarChart lineClusteredColumnComboChart
            lineStackedColumnComboChart pieChart donutChart scatterChart tableEx
            pivotTable matrix slicer].freeze
GAUGE = %w[gauge].freeze
all_visuals.each do |v|
  vt = v['visual_type']
  next if NATIVE.include?(vt)
  approx = GAUGE.include?(vt) ? 'approximate-to-kpi' : "approximate-to-#{v['sigma_kind']}"
  questions << { 'id' => 'visual_no_native_kind', 'severity' => 'review',
                 'visual' => v['title'] || v['visual_id'], 'pbi_type' => vt,
                 'detail' => "#{vt} has no native Sigma element kind (mapped to #{v['sigma_kind']})",
                 'options' => [approx, 'skip this visual'], 'default' => approx }
end

# (c) import vs DirectQuery / warehouse landing. Sigma is always live-on-warehouse;
# an IMPORT-mode PBI model has cached data, so values may drift vs the warehouse.
if modes.include?('import')
  questions << { 'id' => 'import_vs_directquery', 'severity' => 'review',
                 'detail' => "PBI model partition mode = #{mode_summ}. Sigma queries the warehouse LIVE; " \
                             "an import model's cached values may differ from the live #{opts[:db]}.#{opts[:schema]} table. " \
                             "Confirm the Sigma connection points at the same warehouse the import was sourced from.",
                 'options' => ["land live on connection #{opts[:conn]} (#{opts[:db]}.#{opts[:schema]})",
                               'abort and reconcile the warehouse source first'],
                 'default' => "land live on connection #{opts[:conn]} (#{opts[:db]}.#{opts[:schema]})" }
end

# (required) connection.
unless opts[:conn]
  questions << { 'id' => 'connection', 'severity' => 'required',
                 'detail' => 'No Sigma --connection supplied; required to point the DM at the warehouse',
                 'options' => ['supply --connection <id>'], 'default' => nil }
end

# RUN-EACH-TIME GAP-SCOUT GATE (bead beads-sigma-5l5e). Flagged DAX measures
# (⛔ no-equivalent → degrade to Null; ⚠ restructure-needed) are scout-eligible —
# the gap-scout must ATTEMPT a Sigma translation for each before we accept the
# degradation. --yes does NOT skip this; it only accepts gaps the scout already
# tried (validated locally, or escalated). The scout records each to
# <WORK>/scout-ledger.jsonl via scout-validate.py + lib/scout_gate.py.
dax_gaps = questions.select { |q| %w[dax_no_equivalent dax_needs_restructure].include?(q['id']) }
unless dax_gaps.empty?
  gid = ->(q) { 'dax:' + q['detail'].to_s.gsub(/\s+/, ' ').strip[0, 80] }
  gap_ids = dax_gaps.map { |q| gid.call(q) }.uniq
  buckets = ScoutGate.classify(WORK, gap_ids)
  if buckets[:unscouted].any?
    unattended = opts[:yes] || opts[:answers]
    if unattended
      # Regression fix (gap-scout PR #153 made this a hard `exit 11` that overrode
      # --yes, stalling the unattended/demo path even for measures the converter
      # already handled). Under --yes/--answers the gate is ADVISORY: these gaps
      # take their "proceed" default (already shown in the decisions list) and the
      # run flows through. Record them as accepted so re-runs don't re-surface them,
      # and recommend the gap-scout for anyone who wants a faithful translation.
      warn "   gap-scout: #{buckets[:unscouted].size} flagged DAX measure(s) not scouted — proceeding (unattended); recording as accepted degradations."
      warn '   (optional: run scripts/gap-scout.md on these to persist a faithful Sigma translation)'
      buckets[:unscouted].each { |id| ScoutGate.record(WORK, gap_id: id, feature: 'dax', status: 'accepted') }
    else
      # Interactive: the same measures already appear as dax_* review questions and
      # exit via the OPEN QUESTIONS block below (exit 10). Just nudge toward the scout.
      puts
      puts '-------------------- GAP-SCOUT RECOMMENDED --------------------'
      puts "#{buckets[:unscouted].size} of #{gap_ids.size} flagged DAX measure(s) have no faithful translation yet:"
      buckets[:unscouted].each { |id| puts "  --gap-id '#{id}'" }
      puts ''
      puts 'Optional: spawn a gap-scout per measure (scripts/gap-scout.md) with the --gap-id above'
      puts "plus --workdir #{WORK} to persist a translation; or re-run with --yes to accept the"
      puts 'degradation defaults. These also appear in OPEN QUESTIONS below.'
      puts '---------------------------------------------------------------'
    end
  else
    puts "   gap-scout: all #{gap_ids.size} flagged DAX measure(s) accounted for (validated or escalated)"
  end
end

answers = nil
if opts[:answers]
  answers = (JSON.parse(opts[:answers]) rescue abort('FATAL: --answers is not valid JSON'))
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'model' => name_slug,
    'phases_completed' => ['1 Discover/Extract', '2 Convert'],
    'note' => 'Deterministic mechanical steps (fixup, master-map, POST, layout, parity) are NOT asked about. ' \
              'Re-run with --yes to accept all defaults, or --answers \'{"<id>":"<choice>"}\' to override.',
    'open_questions' => questions
  }
  puts
  puts '==================== OPEN QUESTIONS ===================='
  puts JSON.pretty_generate(block)
  puts '======================================================='
  puts
  puts "#{questions.size} decision(s) need a human. No Sigma objects were created."
  exit 10
end

if questions.any?
  puts
  puts "   decisions auto-resolved (#{opts[:yes] ? '--yes: defaults' : '--answers supplied'}):"
  questions.each do |q|
    chosen = (answers && answers[q['id']]) || q['default']
    puts "     - #{q['id']}#{q['visual'] ? " [#{q['visual']}]" : ''}: #{chosen}"
  end
else
  puts '   no open questions — running straight through'
end

# Abort if any answer chose an abort/stop option.
chosen_all = questions.map { |q| (answers && answers[q['id']]) || q['default'] }
if chosen_all.any? { |c| c.to_s =~ /\babort\b/i }
  abort "STOP: a decision selected an abort option — not creating any Sigma objects."
end

# ---------------------------------------------------------------------------
# Phase 2.9 — DM-REUSE scan (reuse-first). Runs by DEFAULT before the DM build:
# score the existing Sigma DMs against this model's signature and AUTO-REUSE a
# guaranteed-safe match (same warehouse table(s) + all referenced columns) so we
# don't create a 4th near-identical DM and we skip the build + POST + validate.
# Opt out with --no-reuse; force a specific id with --reuse-dm <id>. Best-effort:
# any failure in the scan falls back to building a new DM — reuse never aborts.
# ---------------------------------------------------------------------------
reuse_dm_id = opts[:reuse_dm]
if reuse_dm_id
  puts
  puts "── Phase 2.9 · DM-reuse (explicit --reuse-dm #{reuse_dm_id}) ──"
elsif !opts[:no_reuse]
  puts
  puts '── Phase 2.9 · DM-reuse scan ──'
  begin
    sig_path   = File.join(WORK, 'dm-signature.json')
    match_path = File.join(WORK, 'dm-match.json')
    # Signature is parsed from the TMSL/model.bim (warehouse FQNs from the M
    # partition expressions). Best-effort — tolerate a non-zero exit.
    _so, _ss = Open3.capture2e(PY, File.join(HERE, 'pbi-dm-signature.py'),
                               '--bim', opts[:tmsl], '--out', sig_path)
    _so.each_line { |l| puts "   #{l.rstrip}" } unless _so.strip.empty?
    if File.exist?(sig_path)
      # find-or-pick-dm.rb exits non-zero when no candidate qualifies; that is
      # NORMAL (build-new), so don't treat the exit code as fatal.
      Open3.capture2e(ENV.to_h, 'ruby', File.join(HERE, 'find-or-pick-dm.rb'),
                      '--workbook-signature', sig_path, '--out', match_path,
                      '--auto-pick', '--auto-pick-threshold', '0.5')
    end
    match = (File.exist?(match_path) ? JSON.parse(File.read(match_path)) : {}) || {}
    if match['auto_picked'] && match['recommended_dm_id']
      reuse_dm_id = match['recommended_dm_id']
      puts "   DM-REUSE (auto): #{match['rationale']}"
      puts "   ⚠ #{match['warning']}" if match['warning']
    else
      top = (match['candidates'] || []).first(3)
      if top.any?
        puts "   no auto-safe match (#{match['rationale'] || 'below threshold'}) — building a new DM. Top candidate(s):"
        top.each { |c| puts "     - #{c['dm_name']} [#{c['dm_id']}] score=#{c['score']}" }
      else
        puts "   no reuse candidate (#{match['rationale'] || 'none scored'}) — building a new DM"
      end
    end
  rescue StandardError => e
    puts "   [warn] DM-reuse scan skipped (#{e.message[0, 120]}) — building a new DM"
    reuse_dm_id = nil
  end
end

# ---------------------------------------------------------------------------
# Phase 3 — Build data model (fixups + validate + POST + readback) — OR reuse an
# existing DM (skip the build entirely; read its spec back instead).
# ---------------------------------------------------------------------------
hdr(3, TOTAL, 'Build data model')

if reuse_dm_id
  # REUSE PATH — skip convert-model.rb / validate / POST. GET the existing DM's
  # spec once and derive the SAME downstream variables the build path produces:
  #   dm_id    — the reused dataModelId
  #   dm_spec  — full spec file (Phase 4 reads columns[].name + folderId from it)
  #   dm_model — the spec itself (conv_elements is read from dm_model['pages'])
  #   dm_rb    — readback-shaped {dataModelId, pages[].elements[]{id,name}}
  # If anything here fails, fall back to building a new DM (reuse never aborts).
  begin
    require 'sigma_rest'
    spec = Sigma.request(:get, "/v2/dataModels/#{reuse_dm_id}/spec")
    spec = JSON.parse(spec) if spec.is_a?(String)
    raise 'no pages in reused DM spec' unless spec.is_a?(Hash) && spec['pages']
    dm_id   = reuse_dm_id
    dm_spec = File.join(WORK, 'dm-spec.json')
    File.write(dm_spec, JSON.pretty_generate(spec))
    dm_model = spec                                   # conv_elements reads dm_model['pages']
    dm_rb = {
      'dataModelId' => dm_id,
      'pages' => (spec['pages'] || []).map do |p|
        { 'id' => p['id'], 'name' => p['name'], 'visibility' => p['visibility'],
          'elements' => (p['elements'] || []).map { |e| { 'id' => e['id'], 'name' => e['name'] } } }
      end
    }
    File.write(File.join(WORK, 'dm-readback.json'), JSON.pretty_generate(dm_rb))
    n_el = dm_rb['pages'].flat_map { |p| p['elements'] || [] }.size
    puts "   REUSING dataModelId = #{dm_id} (#{n_el} element(s)) — convert + POST skipped"
  rescue StandardError => e
    puts "   [warn] could not read reused DM #{reuse_dm_id} (#{e.message[0, 120]}) — building a new DM instead"
    reuse_dm_id = nil
  end
end

unless reuse_dm_id
# Pre-fixup: the converter emits base warehouse-table columns with NO `name`
# (Sigma derives the display name from the source column at POST time). But
# validate-spec.rb resolves sibling refs by `name`, and a metric like
# `Sum([Sales])` then fails ("[Sales] not a sibling column"). So stamp each
# base column's display name from its own formula ([Tbl/Sales] -> "Sales")
# before convert-model.rb runs. Idempotent: only fills a missing/empty name.
raw_dm = JSON.parse(File.read(File.join(WORK, 'dm-raw.json')))
named_cols = 0
(raw_dm['pages'] || []).each do |pg|
  (pg['elements'] || []).each do |el|
    # Bug E: SQL elements synthesized from a DAX CALENDAR/VALUES calc-table
    # (DimDate, DimMonth, SalaryBands) ALSO need their columns named — their
    # follow-on calc columns reference siblings by bare [ColAlias], which
    # error-type if the referenced column has no display name. Previously only
    # warehouse-table (source.path) elements were stamped.
    is_warehouse = !el.dig('source', 'path').nil?
    is_sql       = el.dig('source', 'kind') == 'sql'
    next unless is_warehouse || is_sql
    (el['columns'] || []).each do |c|
      next if c['name'] && !c['name'].to_s.empty?
      f  = c['formula'].to_s
      dn = f.gsub(/^\[|\]$/, '').split('/')[-1]
      next if dn.to_s.empty?
      # Bug E (SQL elements): a SQL-OUTPUT column has a bare self-referencing
      # formula `[Date]` that maps to the SQL `AS "Date"` alias. Stamping
      # name="Date" on it makes `[Date]` a CIRCULAR reference -> error-type. Only
      # stamp a name when the formula is NOT a bare self-reference (i.e. a
      # follow-on calc column like `Year([Date])`), so its siblings can ref it,
      # while leaving SQL-output columns nameless to bind to their alias.
      if is_sql
        bare_self = (f =~ /\A\[[^\]\/]+\]\z/) && (f.gsub(/^\[|\]$/, '') == dn)
        next if bare_self
      end
      c['name'] = dn
      named_cols += 1
    end
  end
end
File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(raw_dm))
puts "   pre-fixup: named #{named_cols} base column(s) from their formula" if named_cols.positive?

dm_spec = File.join(WORK, 'dm-spec.json')
fixup = ['ruby', File.join(HERE, 'convert-model.rb'),
         '--converter-out', File.join(WORK, 'dm-raw.json'),
         '--out', dm_spec, '--name', WB_NAME.sub(/\(from Power BI\)\s*$/, 'DM (from Power BI)')]
if opts[:folder]
  # caller gave an explicit folder; still need an owner — harvest from ref-dm if present.
  fixup += ['--folder-id', opts[:folder]]
  fixup += ['--ref-dm', opts[:ref_dm]] if opts[:ref_dm]
elsif opts[:ref_dm]
  fixup += ['--ref-dm', opts[:ref_dm]]
else
  abort 'FATAL: need --ref-dm (to harvest folderId/ownerId) or --folder plus a --ref-dm for ownerId'
end
run!(fixup, env: ENV.to_h)
run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec])
dm_readback = File.join(WORK, 'dm-readback.json')
run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
      '--spec', dm_spec, '--out', dm_readback, '--workdir', WORK], env: ENV.to_h)
dm_rb = JSON.parse(File.read(dm_readback))
dm_id = dm_rb['dataModelId']
puts "   dataModelId = #{dm_id}"
end # unless reuse_dm_id (build-new path)

# ---------------------------------------------------------------------------
# Phase 4 — Build workbook (auto master-map from converter + signals, then build+POST)
# ---------------------------------------------------------------------------
hdr(4, TOTAL, 'Build workbook')

# --- derive the master-map deterministically ---
# Converter element: name (= warehouse table) + columns (formula [Tbl/Display]) + metrics.
# The DM readback element name is authoritative (PUT may rename); match by name.
conv_elements = (dm_model['pages'] || []).flat_map { |p| p['elements'] || [] }
dm_elements = dm_rb['pages'].flat_map { |p| p['elements'] || [] }

# Display-name helper: a column formula "[Tbl/Order Id]" -> "Order Id".
disp = lambda { |formula| formula.to_s.gsub(/^\[|\]$/, '').split('/')[-1] }

# Bug A: For a JOIN/View element, columns carry the FULL cross-element ref path
# in their formula — e.g. "[ORDER_FACT/Customer Key]" (own column) AND
# "[ORDER_FACT/CUSTOMER_DIM/Customer Key]" (related column). Both leaf-resolve to
# "Customer Key", so keying the master-column id/name on the leaf produces a
# COLLISION (duplicate ids + duplicate names) and the workbook POST fails.
# These helpers reproduce Sigma's own disambiguation:
#   - the Sigma DISPLAY NAME of a related col is "Customer Key (CUSTOMER_DIM)"
#     (leaf + " (relName)") — matches the converter's viewColDisplay().
#   - the master-column ID keys on the FULL path so it is unique per column.
sigma_view_disp = lambda do |formula|
  parts = formula.to_s.gsub(/^\[|\]$/, '').split('/')
  parts.length <= 2 ? parts[-1] : "#{parts[-1]} (#{parts[-2]})"
end
# The path INSIDE the element (drop the element-name prefix), used as the master
# column's resolving formula, e.g. "[mid/CUSTOMER_DIM/Customer Key]".
inner_path = lambda do |formula|
  parts = formula.to_s.gsub(/^\[|\]$/, '').split('/')
  parts.length <= 1 ? parts[0].to_s : parts[1..].join('/')
end

# Build one master per converter element. master id is "master-<elementId-tail>".
# The POSTED dm-spec is the column display-name AUTHORITY: convert-model.rb's
# pre-fixup names bare columns from their formula (e.g. [Custom SQL/ANNUAL_SALARY]
# -> "Annual Salary"), and workbook refs resolve by that DISPLAY name. Deriving
# the name from the converter formula leaf alone left raw ALIASES on SQL-element
# masters ([Dense Rank DEPARTMENT/ANNUAL_SALARY] -> "Dependency not found").
spec_elements = begin
  (JSON.parse(File.read(dm_spec))['pages'] || []).flat_map { |p| p['elements'] || [] }
rescue StandardError
  []
end
masters = {}
field_map = {}
conv_elements.each_with_index do |cel, cel_idx|
  cname = cel['name']
  # match the posted DM element: by NAME first (PUT keeps names; ids may change),
  # then by ID, then POSITIONALLY (POST /spec preserves element order). A Custom
  # SQL element is NAMELESS in the spec (rule 3) and the readback can ALSO carry
  # name:null — the old `|| dm_elements.first` fallback then bound it to the
  # FIRST element (usually the fact table), OVERWRITING that master with the SQL
  # element's columns (live failure: EMPLOYEES master got SalaryBands' "Band
  # Floor" -> "Dependency not found: 'employees/band floor'"). Positional match
  # keeps the nameless element its OWN master (Bug E: nameless SQL element).
  dmel = (cname && dm_elements.find { |e| e['name'] == cname }) ||
         dm_elements.find { |e| e['id'] == cel['id'] } ||
         dm_elements[cel_idx] || dm_elements.first
  cname ||= (dmel && dmel['name']) || 'Custom SQL'
  # POSTED-spec column display names for this element (matched the same way the
  # dm element was), keyed by formula — overrides the formula-leaf derivation.
  spec_el = (cel['name'] && spec_elements.find { |e| e['name'] == cel['name'] }) ||
            spec_elements[cel_idx]
  spec_name_for = (spec_el && spec_el['columns'] || [])
                  .each_with_object({}) { |c, h| h[c['formula'].to_s] = c['name'] if c['name'] }
  mkey = cname
  mid  = "master-#{Digest::SHA1.hexdigest(cname)[0, 8]}"
  # Bug A: key the master-column id on the FULL cross-element path (not the leaf)
  # and use Sigma's disambiguated display name. For a JOIN/View element, base and
  # related columns can share a leaf ("Customer Key"), so leaf-keying collides on
  # both id AND name -> duplicate columns -> workbook POST fails. The master table
  # element sources from the DM element (named `cname`); the DM element exposes a
  # related column under its disambiguated display name "Leaf (RelName)", so the
  # master column's formula references THAT display name on `cname`. Dedupe by the
  # full path so each underlying column yields exactly one master column.
  seen_paths = {}
  cols = (cel['columns'] || []).map do |c|
    # If the converter already stamped a display `name` (calc/derived/time-intel
    # columns), trust it — the column's formula is an expression, NOT a bare
    # [El/Col] ref, so formula-parsing would mangle the name (Bug C side effect).
    # Bug A formula-path keying applies ONLY to bare [El/.../Col] reference cols.
    bare_ref = c['formula'].to_s =~ /\A\[[^\]]+\]\z/
    if c['name'] && !c['name'].to_s.empty? && !bare_ref
      dn  = c['name'].to_s
      key = "#{cname}/calc/#{dn}"
      next nil if seen_paths[key]
      seen_paths[key] = true
      next({ 'id' => "mc-#{Digest::SHA1.hexdigest(key)[0, 10]}", 'name' => dn,
             'formula' => "[#{cname}/#{dn}]", '_leaf' => dn })
    end
    full = c['formula'].to_s.gsub(/^\[|\]$/, '')         # e.g. ORDER_FACT/CUSTOMER_DIM/Customer Key
    next nil if full.empty? || seen_paths[full]
    seen_paths[full] = true
    # the POSTED spec's display name wins (it's what workbook refs resolve by);
    # fall back to Sigma's own derivation from the formula path.
    dn   = spec_name_for[c['formula'].to_s] ||
           sigma_view_disp.call(c['formula'])            # "Customer Key (CUSTOMER_DIM)"
    { 'id' => "mc-#{Digest::SHA1.hexdigest("#{cname}/#{full}")[0, 10]}", 'name' => dn,
      'formula' => "[#{cname}/#{dn}]", '_leaf' => disp.call(c['formula']) }
  end.compact
  # column field refs: queryRef "Entity.Col" -> {master, ref:[mid/Name], agg:null}.
  # Map both the disambiguated name AND the bare leaf (PBIR queryRefs use the leaf
  # when the dim column is unambiguous in the original model) so bindings resolve.
  cols.each do |c|
    ref = { 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil }
    field_map["#{cname}.#{c['name']}"] = ref
    field_map["#{cname}.#{c['_leaf']}"] ||= ref
  end
  cols.each { |c| c.delete('_leaf') } # internal-only; keep master columns clean
  masters[mkey] = { 'id' => mid, 'element_id' => dmel['id'], 'data_model' => dm_id,
                    'columns' => cols }
  # measure field refs: a translated metric "Sum([Sales])" -> rewrite bare col refs
  # to the master, set agg=null and pass the FULL formula as `ref` (build script
  # uses ref verbatim when agg is nil — handles ratios like DIVIDE too).
  #
  # Bug D: a metric formula may reference ANOTHER metric by name, e.g.
  #   Sales per Order = [Total Sales] / [Orders]
  # where Total Sales = Sum([Sales]) and Orders = CountDistinct([Order Id]).
  # Naively rewriting [Total Sales] -> [mid/Total Sales] points at a NON-EXISTENT
  # master column (metrics are formulas, not stored columns), and Sigma rejects
  # the dependency. Fix: substitute the referenced metric's FULL formula INLINE.
  # Stored master-column names ARE valid [mid/Name] refs; only metric-name refs
  # are inlined. Resolve recursively (with a guard) so chained metrics collapse.
  master_col_names = cols.map { |c| c['name'] }.to_set
  metric_by_name   = {}
  (cel['metrics'] || []).each { |mm| metric_by_name[mm['name'].to_s] = mm['formula'].to_s }
  resolve_metric = lambda do |formula, depth|
    formula.to_s.gsub(/\[([^\/\]]+)\]/) do
      ref = Regexp.last_match(1)
      if master_col_names.include?(ref)
        "[#{mid}/#{ref}]"                                   # real stored column
      elsif metric_by_name.key?(ref) && depth < 16
        "(#{resolve_metric.call(metric_by_name[ref], depth + 1)})" # inline the metric
      else
        "[#{mid}/#{ref}]"                                   # bare column ref (e.g. Sum([Sales]))
      end
    end
  end
  (cel['metrics'] || []).each do |m|
    rewritten = resolve_metric.call(m['formula'].to_s, 0)
    # Converter gap (live 2026-06-12): DAX SEARCH/FIND translate with their
    # start argument, but Sigma's Find() takes only (text, search) — a third
    # arg compiles the column to type "error" (verified: dropping it fixes).
    # Strip a trailing integer start arg until the converter is fixed.
    rewritten = rewritten.gsub(/\bFind\((\[[^\]]+\]|"[^"]*")\s*,\s*(\[[^\]]+\]|"[^"]*")\s*,\s*\d+\s*\)/, 'Find(\1, \2)')
    field_map["#{cname}.#{m['name']}"] = { 'master' => mkey, 'ref' => rewritten, 'agg' => nil,
                                           'format' => (m.dig('format', 'formatString')) }
  end
end

# Bug E (queryRef routing): a DAX calc-table (DimDate / SalaryBands / DimMonth)
# becomes a NAMELESS Custom SQL element (master keyed "Custom SQL"), but the PBIR
# chart still binds it under its ORIGINAL table name ("DimDate.Month"). Alias the
# original calc-table name + each column onto the Custom SQL master so those
# bindings resolve. The calc table is identified from the TMSL (partition source
# type 'calculated'); its column display names match the Custom SQL master cols.
calc_tables = tables.select do |t|
  Array(t['partitions']).any? { |p| p.dig('source', 'type') == 'calculated' }
end
# A Custom SQL master is recognizable by its column formulas using the
# `[Custom SQL/...]` prefix (the converter emits that for SQL-element columns).
sql_masters = masters.select do |_n, m|
  (m['columns'] || []).any? { |c| c['formula'].to_s.start_with?('[Custom SQL/') }
end
calc_tables.each do |t|
  orig = t['name'].to_s
  # pick the SQL master whose columns best cover this calc table's columns.
  tcols = (t['columns'] || []).reject { |c| c['type'] == 'rowNumber' || c['isGenerated'] }
                              .map { |c| (c['sourceColumn'] || c['name']).to_s.gsub(/^\[|\]$/, '') }
  best = sql_masters.max_by do |_n, m|
    names = (m['columns'] || []).map { |c| c['name'].to_s }
    tcols.count { |tc| names.any? { |n| n.casecmp?(tc) || n.gsub(/\s+/, '').casecmp?(tc.gsub(/\s+/, '')) } }
  end
  next unless best
  bmkey, bm = best
  (bm['columns'] || []).each do |c|
    ref = { 'master' => bmkey, 'ref' => "[#{bm['id']}/#{c['name']}]", 'agg' => nil }
    field_map["#{orig}.#{c['name']}"] ||= ref
  end
end

# Bug A (star schema): a cross-table visual binds a DIMENSION from a dim table
# (e.g. PRODUCT_DIM.Category) AND a MEASURE from the fact (ORDER_FACT.Net Rev).
# Those route to DIFFERENT per-table masters, but a Sigma chart element can only
# reference columns from its OWN source master — a cross-master ref error-types.
# The converter already builds a denormalized "<Fact> View" element that carries
# the fact columns + every related dim column (disambiguated "Leaf (DIM)"). So
# RE-ROUTE every field that the View also exposes onto the View master, leaving
# the visual with a single coherent source. Match a per-table field's leaf name
# to the View column whose Sigma display name is "Leaf" or "Leaf (anything)".
conv_elements.each do |vcel|
  vname = vcel['name'].to_s
  next unless vname =~ /\sView$/                     # the denormalized join element
  next unless masters[vname]
  vmid  = masters[vname]['id']
  vcols = masters[vname]['columns'] || []
  # leaf -> View column name (prefer the bare-leaf col when present, else the
  # first disambiguated "Leaf (DIM)" col).
  leaf_to_view = {}
  vcols.each do |c|
    leaf = c['name'].to_s.sub(/\s+\([^)]*\)\s*$/, '') # strip " (DIM)" suffix
    leaf_to_view[leaf] ||= c['name']
    leaf_to_view[c['name']] ||= c['name']            # exact disambiguated form too
  end
  # the fact this View denormalizes (drop the trailing " View").
  fact = vname.sub(/\s+View$/, '')
  # masters whose columns the View subsumes: the fact + every dim reachable via
  # a "(DIM)" suffix in the View's columns.
  subsumed = [fact] + vcols.map { |c| c['name'][/\(([^)]*)\)\s*$/, 1] }.compact.uniq
  # Register the View resolution as an ALT, not the primary (grain fix, found
  # live during the control-targeting wave): making the View the PRIMARY routed
  # EVERY field of the subsumed tables onto the join element, so a SINGLE-table
  # visual (e.g. Median Salary over EMPLOYEES) silently evaluated at the JOIN
  # grain — one row per fact/absence record, not per employee — and diverged
  # (live: Sigma median 73,500 vs PBI 73,000). As an alt, visual_master still
  # majority-picks the View for CROSS-table visuals (the View is the only
  # master covering all their fields) while same-table visuals tie-break to the
  # field's own master and keep their source grain.
  field_map.each do |qr, fs|
    next unless subsumed.include?(fs['master'])
    next if fs['master'] == vname
    old_mid = masters[fs['master']] ? masters[fs['master']]['id'] : nil
    ref_str = fs['ref'].to_s
    is_plain_col = ref_str =~ /\A\[[^\]]+\]\z/ # exactly one bracketed ref, no agg
    add_alt = lambda do |ref|
      alts = (fs['alts'] ||= [])
      alts << { 'master' => vname, 'ref' => ref, 'agg' => fs['agg'] } unless
        alts.any? { |a| a['master'] == vname }
    end
    if is_plain_col
      # plain dimension/column ref: match its leaf to a View column.
      leaf = qr.split('.', 2).last.to_s.sub(/\s+\([^)]*\)\s*$/, '')
      vcol = leaf_to_view[leaf] || leaf_to_view[qr.split('.', 2).last.to_s]
      next unless vcol
      add_alt.call("[#{vmid}/#{vcol}]")
    elsif old_mid
      # measure/aggregation formula: every referenced fact column must exist on the
      # View (it does — the View carries all fact columns). Swap the old master id
      # for the View master id and remap each inner column leaf to its View name.
      remapped = ref_str.gsub(/\[#{Regexp.escape(old_mid)}\/([^\]]+)\]/) do
        inner = Regexp.last_match(1)
        mapped = leaf_to_view[inner] || leaf_to_view[inner.sub(/\s+\([^)]*\)\s*$/, '')] || inner
        "[#{vmid}/#{mapped}]"
      end
      # only register if we actually rewrote a ref onto the View master.
      add_alt.call(remapped) if remapped.include?(vmid)
    end
  end
end

# Bug C: time-intel forwarding. The converter turns DAX SAMEPERIODLASTYEAR /
# TOTALYTD measures into NEW DM elements (source.kind=='table' sourcing another
# element, carrying DateLookback / CumulativeSum columns). Those elements get a
# master built above, but the ORIGINAL PBI queryRef ("ORDER_FACT.Net Revenue PY"
# / "ORDER_FACT.YoY %") still points at the fact table, where the measure no
# longer exists -> the workbook chart resolves no master -> emits source:{} and
# the POST fails with "Invalid value: undefined". Add synthetic field_map entries
# routing "<OrigTable>.<MeasureName>" -> the new element's computed column.
#   measure name -> original TMSL table (from Phase 1's all_measures).
ti_orig_table = {}
all_measures.each { |tbl, mname, _expr| ti_orig_table[mname] = tbl }
# collect the emitted time-intel elements (element-sourced, DateLookback/CumulativeSum).
ti_elements = []
conv_elements.each do |cel|
  src = cel['source'] || {}
  next unless src['kind'] == 'table' && src['elementId'] # element sourced from another element
  cols = cel['columns'] || []
  is_time_intel = cols.any? { |c| c['formula'].to_s =~ /\b(DateLookback|CumulativeSum)\s*\(/ }
  next unless is_time_intel
  mname = cel['name'].to_s            # converter names the element after the measure
  mkey  = mname
  next unless masters[mkey]           # its master was built in the loop above
  mid   = masters[mkey]['id']
  # pick the headline computed column: prior-year / YTD / YoY %, falling back to
  # the last column (the converter appends the derived measure last).
  pick = cols.find { |c| c['formula'].to_s =~ /\bDateLookback\s*\(/ } ||
         cols.find { |c| c['formula'].to_s =~ /\bCumulativeSum\s*\(/ } ||
         cols.find { |c| c['name'].to_s =~ /YoY/i } || cols.last
  next unless pick
  # bead 525l: a SINGLE-VALUE KPI bound to this measure must NOT receive a bare
  # row-level ref (agg:nil) into the GROUPED element — Sigma evaluates an
  # unaggregated ref over a multi-row (one-per-period) element nondeterministically
  # (null / arbitrary row). Emit an explicit deterministic "latest period" headline
  # formula via the builder's verbatim-formula hook (measure_formula):
  #   Sum(If([mid/<dateCol>] = Max([mid/<dateCol>]), [mid/<col>], Null))
  # In a chart grouped BY that date column the same formula still evaluates to the
  # per-period value (within each group Max(date)=date), so it is safe for both
  # the KPI and the date-grouped chart paths. The date col = the element's groupBy.
  group_ids = (cel['groupings'] || []).flat_map { |g| g['groupBy'] || [] }
  date_col  = cols.find { |c| group_ids.include?(c['id']) } ||
              cols.find { |c| c['formula'].to_s =~ /\bDateTrunc\s*\(/ } ||
              cols.find { |c| c['name'].to_s =~ /\A(Year|Quarter|Month|Week|Date|Day)\z/i }
  headline = lambda do |colname|
    next nil unless date_col
    "Sum(If([#{mid}/#{date_col['name']}] = Max([#{mid}/#{date_col['name']}]), [#{mid}/#{colname}], Null))"
  end
  ti_elements << { 'name' => mname, 'mid' => mid, 'cols' => cols,
                   'date' => (date_col && date_col['name']) }
  ref = { 'master' => mkey, 'ref' => "[#{mid}/#{pick['name']}]", 'agg' => nil }
  hf = headline.call(pick['name'])
  ref['formula'] = hf if hf
  orig = ti_orig_table[mname]
  # route both the original-table queryRef and a self-named queryRef so whichever
  # form the PBIR binding used resolves to this element.
  field_map["#{orig}.#{mname}"] = ref if orig
  field_map["#{mname}.#{mname}"] ||= ref
  # also map any YoY % / Prior Year / YTD sibling column by its own name on the orig table.
  cols.each do |c|
    next unless c['name'].to_s =~ /YoY|Prior Year|YTD/i
    sub = { 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil }
    shf = headline.call(c['name'])
    sub['formula'] = shf if shf
    field_map["#{orig}.#{c['name']}"] ||= sub if orig
  end
  # A chart that puts a PY/YoY column next to the BASE value and the period
  # dimension (e.g. Year × Net Revenue × Net Revenue PY) must source from THIS
  # grouped element — the View lacks the PY column. Register ALTS so those
  # sibling fields can ALSO resolve here: the grouped value is already aggregated,
  # so it is referenced as a PLAIN column (no extra Sum). visual_master then
  # majority-picks this element and field_spec swaps in the alt ref.
  base_val  = cols.find { |c| c['formula'].to_s =~ /\b(Sum|Avg|Count|CountDistinct|Min|Max)\s*\(/ }
  period_cols = cols.select { |c| c['name'].to_s =~ /\b(Year|Month|Quarter|Day|Date|Week)\b/i }
  reg_alt = lambda do |qr, colname|
    next unless field_map[qr] && colname
    (field_map[qr]['alts'] ||= []) << { 'master' => mkey, 'ref' => "[#{mid}/#{colname}]", 'agg' => nil }
  end
  if base_val
    # the base value measure under the orig table (any measure whose formula is an
    # aggregation of the same value column the PY/YTD element sums). Compare with
    # whitespace stripped from BOTH sides so "Net Revenue" matches "[Net Revenue]".
    valleaf  = base_val['name']
    valnorm  = valleaf.gsub(/\s+/, '').downcase
    all_measures.each do |t2, m2, e2|
      next unless t2 == orig
      enorm = e2.to_s.gsub(/\s+/, '').downcase
      agg_of_val = enorm =~ /(sum|average|avg|min|max|count|distinctcount)\([^)]*#{Regexp.escape(valnorm)}/
      reg_alt.call("#{orig}.#{m2}", valleaf) if agg_of_val || m2 == valleaf
    end
  end
  # The grouped element carries period dimension column(s) (Year and/or Month).
  # A chart that plots the time-intel measure BY one of those periods must source
  # from this element, so register each period column as an alt under the common
  # date-dim queryRef forms (the calc-table date dim is the usual binding source).
  period_cols.each do |pc|
    %w[DATE_DIM DimDate DimMonth Date].each { |dt| reg_alt.call("#{dt}.#{pc['name']}", pc['name']) }
    reg_alt.call("#{orig}.#{pc['name']}", pc['name'])
  end
end

# Bug C (continued): OTHER time-intel measures (e.g. a standalone "YoY %" using a
# hand-rolled MAX/ALL prior-year pattern) may NOT get their own element — the
# converter folds the YoY computation into the prior-year element's "... YoY %"
# column. Any such measure still has a live PBI queryRef ("ORDER_FACT.YoY %")
# the chart binds, but no field_map entry -> source:{} -> POST fails. Route every
# remaining time-intel-shaped measure to the best-matching time-intel column.
if ti_elements.any?
  ti_re = /\b(SAMEPERIODLASTYEAR|TOTALYTD|TOTALQTD|TOTALMTD|DATESYTD|DATEADD|PARALLELPERIOD|PREVIOUSYEAR|PREVIOUSMONTH|PREVIOUSQUARTER)\b/i
  all_measures.each do |tbl, mname, expr|
    next if field_map.key?("#{tbl}.#{mname}")
    e = expr.to_s
    # time-intel-shaped: a DAX time-intel function, OR a YoY/growth name, OR a
    # hand-rolled MAX(...)/ALL(...) prior-year ratio.
    shape =
      if e =~ ti_re then :generic
      elsif mname =~ /YoY|Y\/Y|growth/i || e =~ /ALL\s*\([^)]*\[Year\]/i then :yoy
      elsif mname =~ /\bYTD\b/i then :ytd
      elsif mname =~ /\b(PY|Prior Year|Last Year|LY)\b/i then :prior
      end
    next unless shape
    # choose a target column across the emitted time-intel elements.
    target = nil; tmid = nil; tname = nil; tdate = nil
    ti_elements.each do |te|
      cand =
        case shape
        when :yoy   then te['cols'].find { |c| c['name'].to_s =~ /YoY/i }
        when :ytd   then te['cols'].find { |c| c['formula'].to_s =~ /\bCumulativeSum\s*\(/ }
        when :prior then te['cols'].find { |c| c['formula'].to_s =~ /\bDateLookback\s*\(/ }
        else te['cols'].find { |c| c['formula'].to_s =~ /\b(DateLookback|CumulativeSum)\s*\(/ }
        end
      if cand then target = cand; tmid = te['mid']; tname = te['name']; tdate = te['date']; break end
    end
    next unless target
    entry = { 'master' => tname, 'ref' => "[#{tmid}/#{target['name']}]", 'agg' => nil }
    # bead 525l: same headline-KPI determinism as above — a bare row-level ref on
    # the grouped element is nondeterministic when consumed by a single-value KPI.
    if tdate
      entry['formula'] = "Sum(If([#{tmid}/#{tdate}] = Max([#{tmid}/#{tdate}]), " \
                         "[#{tmid}/#{target['name']}], Null))"
    end
    field_map["#{tbl}.#{mname}"] = entry
  end
end

# bead anlb (continued) — CLASSIC-report queryRef normalization. The legacy
# report.json binds measures as "Sum(Entity.Col)" / "Count(Entity.Col)" and
# date hierarchies as "Entity.Col.Variation.Date Hierarchy.<Level>". Neither
# key shape exists in the Entity.Field map derived above (which uses the
# converter's Title-Case display names), so those bindings fell through to a
# literal bracketed ref -> silent error-typed column. Resolve both shapes via
# a case/underscore-insensitive lookup against the existing map.
norm_key = ->(k) { k.to_s.downcase.gsub(/[^a-z0-9.]/, '') }
fm_norm = {}
field_map.each { |k, v| fm_norm[norm_key.call(k)] ||= v }
agg_names = { 'sum' => 'Sum', 'avg' => 'Avg', 'average' => 'Avg', 'min' => 'Min', 'max' => 'Max',
              'count' => 'Count', 'countnonnull' => 'Count', 'distinctcount' => 'CountDistinct' }
all_visuals.flat_map { |v| (v['bindings'] || {}).values.flatten }.uniq.each do |r|
  next if r.nil? || field_map.key?(r)
  if (m = r.match(/\A([A-Za-z ]+)\((.+)\)\z/)) && agg_names[m[1].downcase.delete(' ')]
    base = fm_norm[norm_key.call(m[2])]
    next unless base && base['ref'].to_s =~ /\A\[[^\]]+\]\z/
    field_map[r] = base.merge('ref' => "#{agg_names[m[1].downcase.delete(' ')]}(#{base['ref']})", 'agg' => nil)
  elsif (m = r.match(/\A(.+?)\.Variation\..*\.(Year|Quarter|Month|Week|Day)\z/i))
    base = fm_norm[norm_key.call(m[1])]
    next unless base && base['ref'].to_s =~ /\A\[[^\]]+\]\z/
    field_map[r] = base.merge('ref' => "DateTrunc(\"#{m[2].downcase}\", #{base['ref']})", 'agg' => nil)
  end
end

master_map = { 'masters' => masters, 'fields' => field_map }
mmap_path = File.join(WORK, 'master-map.json')
File.write(mmap_path, JSON.pretty_generate(master_map))
puts "   master-map: #{masters.size} master(s), #{field_map.size} field/measure ref(s) -> #{mmap_path}"

wb_spec = File.join(WORK, 'workbook-spec.json')
layout = File.join(WORK, 'layout.xml')
build = ['ruby', File.join(HERE, 'build-workbook-from-pbir.rb'),
         '--signals', signals_path, '--master-map', mmap_path,
         '--data-model', dm_id, '--name', WB_NAME,
         '--source-title', (opts[:source_title] || name_slug.gsub(/[-_]+/, ' ').strip),
         # control-targeting wave (workstream B): the TMSL relationships drive
         # slicer-control target scope; control-scope.json (intended-scope
         # contract for the control lint) lands in WORK.
         '--model', opts[:tmsl],
         '--control-scope-out', File.join(WORK, 'control-scope.json'),
         '--coverage-out', File.join(WORK, 'coverage.json'),
         '--out', wb_spec, '--layout-out', layout]
# The workbook POST requires a folderId. Use --folder if given, else inherit the
# DM's folderId (harvested from the ref-dm at Phase 3) so both land together.
wb_folder = opts[:folder] || (JSON.parse(File.read(dm_spec))['folderId'] rescue nil)
build += ['--folder-id', wb_folder] if wb_folder

# GRACEFUL AGENT-PATH FALLBACK. The DM is already posted + valid (dm_id above), so
# if the MECHANICAL workbook layer (build / validate-spec / POST) hits a field it
# cannot translate (Sigma rejects the spec / unresolved "Dependency not found" /
# unmapped derived-dim or measure / source:{}), we must NOT bare-crash. Catch it
# and exit with a clear, FRIENDLY non-zero handoff: the agent path rebuilds the
# workbook against this DM (see SKILL.md). Never worse than the proven agent path.
begin
  build_log = run_wb!(build)
  # Validate the WORKBOOK spec before POST — previously only the DM spec was
  # validated, so workbook-shape defects (source-less "[]" elements, dangling
  # grouping refs, missing kind) went straight to the API. The DM readback gives
  # the cross-ref context (master/DM element names + ids).
  dm_ctx = File.join(WORK, 'dm-context.json')
  File.write(dm_ctx, JSON.generate(dm_rb))
  run_wb!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'workbook',
           '--dm-context', dm_ctx, wb_spec])
  wb_readback = File.join(WORK, 'wb-readback.json')
  rb_log = run_wb!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
                    '--spec', wb_spec, '--out', wb_readback, '--workdir', WORK], env: ENV.to_h)
rescue WorkbookBuildError => e
  failed = cull_failed_fields(e.captured_output, (defined?(build_log) ? build_log : ''))
  # Also surface the converter (c)-tail measures as the likely culprits when the
  # log itself doesn't name a field.
  if failed.empty?
    failed = conv_warnings.map { |w| w.to_s.gsub(/\s+/, ' ').strip }
                          .select { |w| w.start_with?('⛔') }
                          .map { |w| w[/[“"]([^”"]+)[”"]/, 1] || w.sub(/^⛔\s*/, '')[0, 60] }
                          .compact.uniq
  end
  names = failed.empty? ? 'one or more fields' : failed.join(', ')
  n = failed.empty? ? 'some' : failed.size.to_s
  puts
  puts "── Mechanical path: data model built OK (dataModelId=#{dm_id}). The WORKBOOK " \
       "layer hit #{n} field(s) the mechanical path can't translate (#{names}). " \
       "Falling back to the agent path: rebuild the workbook via the skill's " \
       "agent-authored flow (see SKILL.md) against this DM. The data model is " \
       "posted and ready to attach."
  exit 4
end
wb_rb = JSON.parse(File.read(wb_readback))
wb_id = wb_rb['workbookId']
puts "   workbookId = #{wb_id}"

# ---------------------------------------------------------------------------
# MIGRATION COVERAGE REPORT — what carried over, and what didn't (bead beads-sigma-cov).
# The build warns loudly at each drop site, but on a complex report those warnings
# scatter through the log; this aggregates coverage.json into ONE readout and, for
# RECOVERABLE gaps, an explicit assistance prompt so nothing is "silently dropped".
# It leads with what DID convert — the perception that a lot is lost is usually
# "the few gaps weren't surfaced in one place". Non-blocking (the workbook is
# posted + usable); the recoverable items are HARD-gated later by
# assert-visual-compare.rb (must be ACCEPTED or fixed before Phase 6 sign-off).
# ---------------------------------------------------------------------------
coverage = CoverageGate.load(File.join(WORK, 'coverage.json'))
if coverage
  puts
  puts '==================== MIGRATION COVERAGE ===================='
  puts "   #{CoverageGate.headline(coverage)}"
  rlines = CoverageGate.report_lines(coverage)
  unless rlines.empty?
    puts
    puts rlines.join("\n")
  end
  cov_qs = CoverageGate.questions(coverage)
  unless cov_qs.empty?
    puts
    if opts[:yes] || opts[:answers]
      puts "   #{cov_qs.size} recoverable gap(s) — proceeding (unattended); recorded as accepted degradations."
      puts '   (re-run after the action note on each to recover; they are also gated by assert-visual-compare.rb)'
    else
      puts '-------------------- ASSISTANCE AVAILABLE --------------------'
      puts "   #{cov_qs.size} gap(s) below are RECOVERABLE — ask the user whether to recover or accept each."
      puts '   These are NOT silent: each has a concrete action. assert-visual-compare.rb (Phase 5e)'
      puts '   will not go GREEN until every recoverable gap is recovered or explicitly ACCEPTED.'
      puts JSON.pretty_generate('recoverable_gaps' => cov_qs)
    end
  end
  puts '==========================================================='
end

# ---------------------------------------------------------------------------
# Phase 5 — Layout (authoritative final spec write — bead 16i)
# ---------------------------------------------------------------------------
hdr(5, TOTAL, 'Layout')
run!(['ruby', File.join(HERE, 'put-layout.rb'), '--workbook', wb_id, '--layout', layout], env: ENV.to_h)
puts "   layout applied to workbook #{wb_id}"
require 'sigma_rest'

# ---------------------------------------------------------------------------
# Phase 5b — Visual QA: auto-render each content page to a FULL-PAGE PNG so the
# layout can be reviewed against refs/layout-visual-qa.md AND compared to the
# source PBI page captures (SKILL.md Phase 5e/5f gate). Matches qlik/tableau
# Phase 5b. NON-FATAL — a transient export failure must not sink a green
# migration; the REVIEW (reading each PNG) is the actual gate. Page ids come
# from the LOCAL spec the builder wrote (deterministic; POST preserves them) —
# the live GET /spec readback has proven flaky mid-pipeline.
# ---------------------------------------------------------------------------
begin
  vqa = File.join(WORK, 'visual-qa')
  FileUtils.mkdir_p(vqa)
  local_spec = (JSON.parse(File.read(wb_spec)) rescue {})
  content_pages_qa = (local_spec['pages'] || []).reject { |p| p['id'].to_s.downcase.include?('data') }
  tok = (Sigma.auth_token rescue ENV['SIGMA_API_TOKEN'])
  pngs = []
  content_pages_qa.each do |pg|
    out = File.join(vqa, "#{pg['id']}.png")
    _o, st = Open3.capture2e({ 'SIGMA_API_TOKEN' => tok.to_s }, PY,
                             File.join(HERE, 'sigma-export-png.py'),
                             '--workbook', wb_id, '--page', pg['id'], '--out', out,
                             '--w', '1800', '--h', '1000')
    st.success? ? (pngs << out) : (puts "   [warn] visual-QA render failed for page #{pg['id']}")
  end
  puts "   rendered #{pngs.size}/#{content_pages_qa.size} full-page PNG(s) for visual QA -> #{vqa}"
  if pngs.any?
    puts '   VISUAL QA (mandatory review — do not skip): open each PNG and check vs'
    puts '   refs/layout-visual-qa.md AND the source PBI page captures (export-pbi-pages.py) —'
    puts '   no overlaps/stacking, no clipped titles, controls in their own band, right chart'
    puts '   kinds/colors, even heights. See assert-visual-compare.rb for the source-vs-target gate.'
  end
rescue StandardError => e
  puts "   [warn] visual-QA render skipped: #{e.message[0, 120]}"
end

# ---------------------------------------------------------------------------
# Phase 6 — Parity (freshness banner FIRST, then formula guard + warehouse compare)
# ---------------------------------------------------------------------------
hdr(6, TOTAL, 'Parity')
require 'date'

# ---- join the NON-BLOCKING Phase-1.5 freshness lane (launched pre-Convert) --
if fresh_waiter
  fresh_waiter.join(180) # the probe ran concurrently; normally already done
  if File.exist?(fresh_log)
    File.read(fresh_log).each_line { |l| puts "   #{l.rstrip}" }
  end
  puts '   ⚠ freshness preflight produced no freshness.json (continuing without it)' unless File.exist?(fresh_path)
end
freshness = File.exist?(fresh_path) ? (JSON.parse(File.read(fresh_path)) rescue {}) : {}
stale_days = freshness['staleDays']

# bead fmte — the SOURCE-FRESHNESS banner LEADS the parity output (read this
# before any side-by-side): a stale import snapshot / failed refresh explains
# "Sigma shows more data" deltas up front instead of after they look wrong.
fresh_ok   = freshness['lastSuccessfulRefresh']
fresh_fail = (freshness['failures'] || []).first
if fresh_ok || fresh_fail
  puts '   ── SOURCE FRESHNESS (read this before any side-by-side) ──'
  if fresh_ok
    puts "   PBI dataset last refreshed #{fresh_ok['endTime']} (#{stale_days} days ago)"
  end
  if fresh_fail
    tag = freshness['credsSuspect'] ? ' — dataset credentials look EXPIRED' : ''
    puts "   ⚠ most recent refresh FAILURE #{fresh_fail['endTime']} (#{fresh_fail['errorCode']})#{tag}"
  end
  if stale_days && stale_days >= 1
    puts "   ⚠ source is ~#{stale_days.ceil} day(s) stale — Sigma reads the LIVE warehouse and is"
    puts '     EXPECTED to show more data. Deltas below are classified accordingly.'
  end
end

# (1) formula-resolution guard: no column resolved to type "error".
cols = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/columns") rescue { 'entries' => [] })
err_cols = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
total_cols = (cols['entries'] || []).size
chart_pages = wb_rb['pages'].reject { |p| p['id'] == 'page-data' }
chart_els = chart_pages.flat_map { |p| (p['elements'] || []) }

# (2) warehouse-vs-snapshot compare (bead fmte). For every table the preflight
# snapshotted, export the matching Data-page master element (Sigma = LIVE
# warehouse rows) via the REST export API and classify the delta:
#   MATCH            same row count (and max dates, when known)
#   STALE-EXPLAINED  Sigma has MORE/newer rows — the stale/failed-refresh
#                    snapshot explains it; NOT a conversion error
#   DIVERGENT        Sigma has FEWER/older rows — a real problem; blocks
norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
export_rows = lambda do |element_id|
  res = Sigma.request(:post, "/v2/workbooks/#{wb_id}/export",
                      body: { 'elementId' => element_id, 'format' => { 'type' => 'json' } }.to_json)
  qid = res.is_a?(Hash) ? res['queryId'] : nil
  raise 'export returned no queryId' unless qid
  deadline = Time.now + 90
  while Time.now < deadline
    body = (Sigma.request(:get, "/v2/query/#{qid}/download", binary: true) rescue nil)
    if body && !body.strip.empty?
      parsed = (JSON.parse(body) rescue nil)
      return parsed if parsed.is_a?(Array)
      return parsed['rows'] if parsed.is_a?(Hash) && parsed['rows'].is_a?(Array)
      lines = body.each_line.map { |l| (JSON.parse(l) rescue nil) }.compact
      return lines if lines.size > 1
    end
    sleep 2
  end
  raise 'export download timed out'
end

fresh_classes = []
data_page = wb_rb['pages'].find { |p| p['id'] == 'page-data' } ||
            wb_rb['pages'].find { |p| p['name'].to_s =~ /data/i }
data_els = data_page ? (data_page['elements'] || []) : []
(freshness['snapshot'] || {}).each do |table, snap|
  pbi_rows = snap['rows']
  next if pbi_rows.nil?
  # match via the master-map (master key == converter element name == warehouse
  # table for base tables; the page-data element keeps the master's id), falling
  # back to a name match. Skip the derived "<Fact> View" join masters.
  _mk, master = masters.find { |k, _| norm.call(k) == norm.call(table) }
  el = (master && data_els.find { |e| e['id'] == master['id'] }) ||
       data_els.find { |e| norm.call(e['name']) == norm.call(table) }
  unless el
    fresh_classes << ['SKIPPED', table, 'no matching Data-page master element']
    next
  end
  if pbi_rows > 100_000
    fresh_classes << ['SKIPPED', table, "#{pbi_rows} rows — too large for an export row-count probe"]
    next
  end
  begin
    rows = export_rows.call(el['id'])
  rescue StandardError => e
    fresh_classes << ['SKIPPED', table, "export failed: #{e.message[0, 80]}"]
    next
  end
  wh_rows = rows.size
  # max-date compare: match each snapshot date col to an export key by name.
  date_note = nil
  newer_dates = false
  (snap['maxDates'] || {}).each do |dcol, pbi_max|
    next if pbi_max.nil?
    key = (rows.first || {}).keys.find { |k| norm.call(k) == norm.call(dcol) }
    next unless key
    wh_max = rows.map { |r| r[key] }.compact.max
    pd = (Date.parse(pbi_max.to_s) rescue nil)
    wd = (Date.parse(wh_max.to_s) rescue nil)
    next unless pd && wd
    if wd > pd
      newer_dates = true
      date_note = "max(#{dcol}) warehouse=#{wd} vs PBI=#{pd}"
    end
  end
  stale_or_failed = (stale_days && stale_days >= 1) || freshness['credsSuspect'] ||
                    (freshness['failures'] || []).any?
  if wh_rows == pbi_rows && !newer_dates
    fresh_classes << ['MATCH', table, "rows=#{wh_rows} (warehouse == PBI snapshot)"]
  elsif wh_rows >= pbi_rows
    why = stale_or_failed ? 'stale/failed-refresh snapshot explains it' : 'warehouse moved since the refresh'
    delta = wh_rows - pbi_rows
    msg = "Sigma will show more data: warehouse rows=#{wh_rows} vs PBI snapshot=#{pbi_rows}" \
          "#{delta.positive? ? " (+#{delta})" : ''}#{date_note ? "; #{date_note}" : ''} — #{why}"
    fresh_classes << ['STALE-EXPLAINED', table, msg]
  else
    fresh_classes << ['DIVERGENT', table,
                      "warehouse rows=#{wh_rows} < PBI snapshot=#{pbi_rows} — Sigma shows LESS data " \
                      'than the source snapshot; check the table/path mapping']
  end
end
if fresh_classes.any?
  puts '   freshness deltas (table-level, Sigma live vs PBI snapshot):'
  fresh_classes.each { |cls, table, msg| puts format('   %-15s %s: %s', cls, table, msg) }
end
divergent = fresh_classes.count { |c| c[0] == 'DIVERGENT' }

parity_ok = err_cols.empty? && divergent.zero?
if err_cols.empty?
  puts "   PARITY: #{parity_ok ? 'PASS' : 'FAIL'} — #{total_cols} workbook column(s) resolve (0 error-typed); " \
       "#{chart_els.size} chart element(s) built across #{chart_pages.size} page(s)"
  puts "   PARITY: FAIL — #{divergent} DIVERGENT freshness delta(s) above" unless divergent.zero?
else
  puts "   PARITY: FAIL — #{err_cols.size}/#{total_cols} column(s) resolved to type 'error':"
  err_cols.first(8).each { |c| puts "     [#{c['elementId']}] #{c['label']}: #{c['formula']}" }
end

# ---------------------------------------------------------------------------
# Phase E (OPT-IN) — Enhance. Runs ONLY with --enhance AND a parity PASS:
# enhancements clone a PARITY-VERIFIED workbook, never an unproven one.
# Clone-first / scan-then-propose / accept-only / parity-unchanged-gated —
# see enhance-scan.rb + enhance-apply.rb (the shared Phase-E engine).
# ---------------------------------------------------------------------------
enhance_line = nil
if opts[:enhance] && !parity_ok
  enhance_line = 'SKIPPED — parity not green (Phase E only clones a parity-verified workbook)'
elsif opts[:enhance]
  puts
  puts '── Phase E (opt-in) · Enhance ──'
  enh_path = File.join(WORK, 'enhancements.json')
  e_out, e_st = Open3.capture2e(ENV.to_h, 'ruby', File.join(HERE, 'enhance-scan.rb'),
                                '--workbook-id', wb_id, '--workdir', WORK,
                                '--source', 'powerbi', '--out', enh_path)
  e_out.each_line { |l| puts "   #{l.rstrip}" }
  if !e_st.success?
    enhance_line = 'scan FAILED (migration itself passed parity; see output above)'
  elsif opts[:enhance_accept].nil?
    cands = (JSON.parse(File.read(enh_path))['candidates'] rescue [])
    puts
    puts '==================== PHASE E PROPOSALS (acceptance required) ===================='
    puts "#{cands.size} enhancement candidate(s) in #{enh_path}. NOTHING has been applied —"
    puts 'present each candidate to the human (interactive: one AskUserQuestion checklist),'
    puts 'then re-run this exact command adding:'
    puts "  --enhance --enhance-accept <id,id,...>   # or: --enhance-accept all-low-risk"
    puts '================================================================================='
    exit 14
  else
    a_out, a_st = Open3.capture2e(ENV.to_h, 'ruby', File.join(HERE, 'enhance-apply.rb'),
                                  '--workbook-id', wb_id, '--enhancements', enh_path,
                                  '--accept', opts[:enhance_accept],
                                  '--out', File.join(WORK, 'enhance-report.json'))
    a_out.each_line { |l| puts "   #{l.rstrip}" }
    rep = (JSON.parse(File.read(File.join(WORK, 'enhance-report.json'))) rescue {})
    enhance_line = if a_st.success?
                     "clone #{rep['clone_id']} '#{rep['clone_name']}': " \
                     "#{(rep['applied'] || []).size} applied, #{(rep['skipped'] || []).size} skipped, " \
                     "#{(rep['reverted'] || []).size} reverted; parity-unchanged gate GREEN"
                   else
                     "apply NOT GREEN (exit #{a_st.exitstatus}) — see enhance-report.json"
                   end
  end
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts
puts '================ RESULT ================'
puts "dataModelId : #{dm_id}"
puts "workbookId  : #{wb_id}"
puts "PARITY      : #{parity_ok ? 'PASS' : 'FAIL'} (#{total_cols} cols resolve, #{err_cols.size} error" \
     "#{fresh_classes.any? ? format(', freshness: %d match / %d stale-explained / %d divergent', fresh_classes.count { |c| c[0] == 'MATCH' }, fresh_classes.count { |c| c[0] == 'STALE-EXPLAINED' }, divergent) : ''})"
if fresh_ok
  puts "freshness   : PBI last refresh #{fresh_ok['endTime']} (#{stale_days} days ago)" \
       "#{freshness['credsSuspect'] ? ' — REFRESH FAILING (creds)' : ''}"
end
puts "ENHANCE     : #{enhance_line}" if enhance_line
puts '======================================='
exit(parity_ok ? 0 : 3)
