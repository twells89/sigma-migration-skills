#!/usr/bin/env ruby
# migrate-quicksight.rb — ONE-SHOT, single-process orchestrator for the
# quicksight-to-sigma pipeline. Runs the whole phased workflow in one Ruby
# process to cut agent turns / token cost, WITHOUT turning the migration into a
# black box: every phase prints a visible header + concise result, and the
# genuine human decision points are surfaced as a structured OPEN QUESTIONS
# block (exit 10) rather than silently auto-resolved.
#
# This script does NOT re-implement any phase — it chains the existing scripts:
#   quicksight-discover.py [--from-fixtures]                       (Phase 1)
#   convert-model.rb --emit-mcp → MCP gate → --converted resume,
#     or a local sigma-data-model-mcp build via a node shim        (Phase 2)
#   qs-dm-signature.py + find-or-pick-dm.rb (DM-reuse check)       (Phase 2.5)
#   convert-model.rb --fixup --folder-id + validate-spec.rb
#     + post-and-readback.rb                                       (Phase 3/DM)
#   build-workbook-from-quicksight.rb + post-and-readback.rb       (Phase 4/workbook)
#   build-quicksight-layout.rb (fixed 36-col inference) + put-layout.rb (Phase 5)
#   phase6-parity-quicksight.rb two-pass (emit query list → MCP gate →
#     --actuals/--expected resume) + assert-phase6-ran.rb --workdir (Phase 6/parity)
#
# Usage (live):
#   ruby scripts/migrate-quicksight.rb \
#     --analysis-id <ID> --account-id <ACCT> --region <REGION> --profile <PROFILE> \
#     --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID-or-name> \
#     [--database DB --schema SCH] [--name "My Dashboard"] \
#     [--out DIR] [--answers '<json>'] [--yes]
#   --folder accepts a folder id OR an exact folder NAME (looked up via
#   /v2/files; ambiguous names abort with the candidate ids).
#
# IDEMPOTENT RESUME: re-running with the same --out after a mid-run crash
# NEVER duplicates the DM or workbook — ids already posted by this workdir
# (dm-readback.json / wb-id.txt) are verified live and reused. Use a fresh
# --out (or delete the workdir) to force a fresh build.
#
# Usage (offline fixtures — no AWS needed):
#   ruby scripts/migrate-quicksight.rb --from-fixtures fixtures/ \
#     --connection <ID> --folder <ID> --database DB --schema SCH --yes
#
# RESUME PATTERNS (each gate prints its own exact resume command):
#   converter MCP gate → re-run with --converted <mcp-tool-result.json>
#   parity MCP gate    → write <out>/parity-expected.json + parity-actuals.json
#                        (or pass --expected/--actuals) and re-run; phases 1-5
#                        are skipped automatically when their artifacts exist.
#
# Exit codes: 0 = done (parity + hard gate pass); 10 = gate/decisions (printed);
#             3 = parity fail; other = error.
require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require_relative 'lib/scout_gate'
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)

# Converter resolution (issue #227). The pinned VENDORED bundle is the DEFAULT so a
# developer machine and a customer machine produce identical output for the same
# input. A local sigma-data-model-mcp build is used ONLY when EXPLICITLY opted in
# via --mcp-dir / QS_MCP_DIR — there is NO silent auto-discovery of ~/… checkouts
# (that was the "works in my demo, differs for the customer" footgun). Returns
# [conv_module, mcp_build_dir_or_nil, loud_provenance_line].
def resolve_converter(mcp_dir, vendored, build_basename)
  build_dir = (mcp_dir && File.exist?(File.join(mcp_dir, 'build', build_basename))) ? mcp_dir : nil
  conv = build_dir ? File.join(build_dir, 'build', build_basename) :
         (File.exist?(vendored) ? vendored : nil)
  desc =
    if conv && conv == vendored
      prov = File.join(File.dirname(vendored), 'PROVENANCE.json')
      commit = (JSON.parse(File.read(prov))['source_commit'] rescue nil)
      "VENDORED #{File.basename(vendored)}#{commit ? " (pinned #{commit})" : ''} — no data egress"
    elsif conv
      "DEV BUILD #{conv} (explicit opt-in via --mcp-dir/QS_MCP_DIR)"
    else
      'NONE — vendored bundle missing; convert_quicksight_to_sigma MCP / --converted fallback applies'
    end
  [conv, build_dir, desc]
end

opts = { region: 'us-east-1' }
OptionParser.new do |o|
  o.on('--analysis-id ID')  { |v| opts[:analysis] = v }
  o.on('--account-id ID')   { |v| opts[:account]  = v }
  o.on('--region R')        { |v| opts[:region]   = v }
  o.on('--profile P')       { |v| opts[:profile]  = v }
  o.on('--from-fixtures D') { |v| opts[:fixtures] = File.expand_path(v) }
  o.on('--connection ID')   { |v| opts[:conn]     = v }
  o.on('--database DB')     { |v| opts[:db]       = v }
  o.on('--schema SCH')      { |v| opts[:schema]   = v }
  o.on('--folder ID')       { |v| opts[:folder]   = v }
  o.on('--name NAME')       { |v| opts[:name]     = v }
  o.on('--out DIR')         { |v| opts[:out]      = File.expand_path(v) }
  o.on('--answers JSON')    { |v| opts[:answers]  = v }
  o.on('--yes')             {     opts[:yes]      = true }
  # converter MCP-gate resume: the convert_quicksight_to_sigma MCP tool result.
  o.on('--converted PATH')  { |v| opts[:converted] = File.expand_path(v) }
  o.on('--mcp-dir DIR')     { |v| opts[:mcp_dir]   = File.expand_path(v) }
  # DM-reuse (Phase 2.5). Default = build new; --reuse-dm attaches to an
  # existing DM (skips Phase 3); --skip-reuse-check skips the scan entirely.
  o.on('--reuse-dm ID')     { |v| opts[:reuse_dm] = v }
  o.on('--skip-reuse-check'){     opts[:skip_reuse] = true }
  # parity MCP-gate resume inputs (defaults: <out>/parity-expected.json + parity-actuals.json).
  o.on('--expected PATH')   { |v| opts[:expected] = File.expand_path(v) }
  o.on('--actuals PATH')    { |v| opts[:actuals]  = File.expand_path(v) }
  o.on('--extract-mode')    {     opts[:extract]  = true }
  o.on('--extract-tol F', Float) { |v| opts[:tol] = v }
  # Resolve + print which converter would run (vendored vs explicit dev build), then
  # exit 0 — no creds/args needed. Used by the converter-default regression test.
  o.on('--print-converter') {     opts[:print_converter] = true }
end.parse!

VENDORED_QS = File.expand_path('../converter/quicksight.mjs', __dir__)
if opts[:print_converter]
  conv, _bd, desc = resolve_converter(opts[:mcp_dir] || ENV['QS_MCP_DIR'], VENDORED_QS, 'quicksight.js')
  puts(conv || 'none')
  puts desc
  exit 0
end

abort 'missing --analysis-id (or --from-fixtures)' unless opts[:analysis] || opts[:fixtures]
abort 'missing --account-id (live discovery)' if opts[:analysis] && !opts[:fixtures] && !opts[:account]
# intake.rb (front-door) caches the resolved connection in <out>/connection.json; honor it
# when --connection is omitted so the agent need not re-pass the id it just resolved.
opts[:conn] ||= (JSON.parse(File.read(File.join(opts[:out], 'connection.json')))['connection_id'] rescue nil) if opts[:out]
abort 'missing --connection (pass --connection <id>, or run intake.rb first and point --out at its --workdir)' unless opts[:conn]
if opts[:conn] !~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  abort "FATAL: --connection must be a FULL Sigma connection UUID (8-4-4-4-12 hex); got #{opts[:conn].inspect}"
end

# Converter resolution (issue #227): the pinned VENDORED bundle is the DEFAULT so a
# dev machine and a customer machine convert identically. A local sigma-data-model-mcp
# build is used ONLY via explicit --mcp-dir / QS_MCP_DIR — no silent auto-discovery of
# ~/… checkouts (that was the "works in my demo, differs for the customer" footgun).
# CONV_MODULE is what the Phase-2 shim imports; nil only if the bundle is also absent
# (then --converted / the convert_quicksight_to_sigma MCP tool gate applies).
CONV_MODULE, MCP_DIR, CONVERTER_DESC =
  resolve_converter(opts[:mcp_dir] || ENV['QS_MCP_DIR'], VENDORED_QS, 'quicksight.js')
warn "converter: #{CONVERTER_DESC}"

name_slug = (opts[:analysis] || File.basename(opts[:fixtures].to_s)).gsub(/[^A-Za-z0-9_-]/, '-')
WORK = opts[:out] || File.expand_path("~/quicksight-migration/#{name_slug}")
FileUtils.mkdir_p(WORK)

def hdr(n, total, title)
  puts
  puts "── Phase #{n}/#{total} · #{title} ──"
end

def run!(cmd, env: {})
  out, st = Open3.capture2e(env, *cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success?
  out
end

TOTAL = 6

# ---- parity-resume detection (phases 1-5 already ran; finalize only) -------
exp_path   = opts[:expected] || File.join(WORK, 'parity-expected.json')
act_path   = opts[:actuals]  || File.join(WORK, 'parity-actuals.json')
wb_id_path = File.join(WORK, 'wb-id.txt')
resume_parity = File.exist?(wb_id_path) && File.exist?(exp_path) && File.exist?(act_path)

dm_id = nil
wb_id = nil

if resume_parity
  wb_id = File.read(wb_id_path).strip
  dm_id = (JSON.parse(File.read(File.join(WORK, 'dm-readback.json')))['dataModelId'] rescue '?')
  puts "── resuming at Phase 6 (parity finalize) — workbook #{wb_id}, dm #{dm_id} ──"
else

# ---------------------------------------------------------------------------
# Phase 1 — Discover (live AWS, --from-fixtures, or reuse of a prior run)
# ---------------------------------------------------------------------------
hdr(1, TOTAL, 'Discover')
# idempotent resume: a prior run's discovery artifacts in WORK are reused
# (the --converted gate-resume relies on this — don't re-hit AWS).
if File.exist?(File.join(WORK, 'analysis.json')) && File.exist?(File.join(WORK, 'signals.json')) &&
   Dir[File.join(WORK, 'datasets', '*.json')].any?
  puts "   reusing discovery artifacts already in #{WORK}"
elsif opts[:fixtures]
  run!([*PyResolve.argv, File.join(HERE, 'quicksight-discover.py'),
        '--from-fixtures', opts[:fixtures], '--out-dir', WORK])
else
  disc_cmd = [*PyResolve.argv, File.join(HERE, 'quicksight-discover.py'),
              '--account-id', opts[:account], '--region', opts[:region],
              '--analysis-id', opts[:analysis], '--out-dir', WORK]
  disc_cmd += ['--profile', opts[:profile]] if opts[:profile]
  run!(disc_cmd)
end

signals = JSON.parse(File.read(File.join(WORK, 'signals.json')))
an_name = signals.dig('source', 'name') || opts[:analysis]
all_visuals = signals['sheets'].flat_map { |s| s['visuals'] }
vkinds = all_visuals.map { |v| v['type'].to_s.sub(/Visual$/, '').sub(/Chart$/, '') }
vcount = vkinds.each_with_object(Hash.new(0)) { |k, h| h[k] += 1 }
vsumm = vcount.map { |k, c| c > 1 ? "#{k}×#{c}" : k }.join(', ')
puts "   analysis '#{an_name}': #{signals['datasets'].size} dataset(s), " \
     "#{all_visuals.size} visual(s) (#{vsumm}), #{signals['parameters'].size} param(s), " \
     "#{signals['calculatedFields'].size} calc field(s)"

# ---------------------------------------------------------------------------
# Phase 2 — Convert. Three routes (in priority order):
#   a) --converted <file>: the convert_quicksight_to_sigma MCP TOOL already ran
#      (gate-resume — the default route on machines without a local build)
#   b) a local sigma-data-model-mcp build: run it in-process via a node shim
#   c) neither: print the exact MCP request (convert-model.rb --emit-mcp) and
#      GATE — re-run with --converted <the tool's result JSON>.
# ---------------------------------------------------------------------------
hdr(2, TOTAL, 'Convert')
ds_files = Dir[File.join(WORK, 'datasets', '*.json')].sort
conv_files = [File.join(WORK, 'analysis.json')] + ds_files

if opts[:converted]
  abort "FATAL: --converted not found: #{opts[:converted]}" unless File.exist?(opts[:converted])
  FileUtils.cp(opts[:converted], File.join(WORK, 'converter-out.json')) unless
    File.expand_path(opts[:converted]) == File.join(WORK, 'converter-out.json')
  puts "   converter output ingested from #{opts[:converted]} (MCP-tool route)"
elsif CONV_MODULE
  puts "   converter: #{CONV_MODULE == VENDORED_QS ? 'vendored bundle (converter/quicksight.mjs)' : CONV_MODULE} (no data leaves this machine)"
  shim = File.join(WORK, '_convert.mjs')
  File.write(shim, <<~JS)
    import { readFileSync, writeFileSync } from 'node:fs';
    import { convertQuickSightToSigma } from #{CONV_MODULE.to_json};
    const files = #{conv_files.to_json}.map(p => ({ name: p.split('/').pop(), content: readFileSync(p, 'utf8') }));
    const out = convertQuickSightToSigma(files, {
      connectionId: #{opts[:conn].to_json},
      database: #{(opts[:db] || ENV['QS_DB'] || '').to_json},
      schema: #{(opts[:schema] || ENV['QS_SCHEMA'] || '').to_json},
    });
    writeFileSync(#{File.join(WORK, 'converter-out.json').to_json}, JSON.stringify(out, null, 2));
    // emit a one-line machine summary on stderr for the orchestrator
    const w = out.warnings || [];
    process.stderr.write('CONVSTATS ' + JSON.stringify({ warnings: w, stats: out.stats || {} }) + '\\n');
  JS
  c_out, c_err, c_st = Open3.capture3('node', shim)
  abort "FATAL: converter failed:\n#{c_err}#{c_out}" unless c_st.success?
else
  puts '   no local sigma-data-model-mcp build found (set --mcp-dir / QS_MCP_DIR for the in-process route).'
  puts
  emit = ['ruby', File.join(HERE, 'convert-model.rb'), '--emit-mcp',
          '--discover-dir', WORK, '--connection-id', opts[:conn]]
  emit += ['--database', opts[:db]] if opts[:db]
  emit += ['--schema', opts[:schema]] if opts[:schema]
  run!(emit)
  puts
  puts '   >>> GATE: run the convert_quicksight_to_sigma MCP tool exactly as printed'
  puts '       above, save the tool result JSON to a file, then re-run this command'
  puts "       with --converted <that file>. No Sigma objects were created."
  exit 10
end
conv = JSON.parse(File.read(File.join(WORK, 'converter-out.json')))
conv_warnings = conv['warnings'] || []
# The converter output is {model|sigmaDataModel, warnings, stats}. convert-model.rb
# --fixup unwraps sigmaDataModel/model itself, so we feed it the raw converter-out.json.
model = conv['sigmaDataModel'] || conv['model'] || conv
el_ct = (model['pages'] || []).flat_map { |p| p['elements'] || [] }.size
puts "   #{el_ct} DM element(s) emitted; #{conv_warnings.size} converter warning(s)"

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine human questions
# ---------------------------------------------------------------------------
questions = []

# (a) calc fields / measures degraded to Null (window / table-calc — no Sigma translation)
window_warns = conv_warnings.select do |w|
  w.to_s =~ /window|table-calc|runningSum|percentOfTotal|periodOverPeriod|sumOver|rank|percentile|Null|degrad/i
end
window_warns.each do |w|
  questions << { 'id' => 'calc_degraded', 'severity' => 'review',
                 'detail' => w.to_s.gsub(/\s+/, ' ').strip,
                 'options' => ['proceed (column degrades to Null, original expr kept in description)', 'abort and re-author manually'],
                 'default' => 'proceed' }
end

# (b) visuals with no NATIVE Sigma kind ((c)-tail). Keep this list in lock-step with
# build-workbook-from-quicksight.rb's QS_UNSUPPORTED / QS_FALLBACK maps.
APPROX = {
  'TreeMapVisual'       => 'approximate-to-bar',
  'FunnelChartVisual'   => 'approximate-to-bar',
  'WaterfallVisual'     => 'approximate-to-bar',
  'HistogramVisual'     => 'approximate-to-bar',
  'GaugeChartVisual'    => 'approximate-to-kpi',
  'HeatMapVisual'       => 'data-migrate-as-table',
  'BoxPlotVisual'       => 'data-migrate-as-table',
  'SankeyDiagramVisual' => 'data-migrate-as-table',
  'WordCloudVisual'     => 'data-migrate-as-table',
  'RadarChartVisual'    => 'data-migrate-as-table'
}.freeze
DROP = %w[InsightVisual CustomContentVisual PluginVisual LayerMapVisual EmptyVisual].freeze
all_visuals.each do |v|
  t = v['type']
  if APPROX.key?(t)
    questions << { 'id' => 'visual_no_native_kind', 'severity' => 'review',
                   'visual' => v['title'] || v['visualId'], 'qs_type' => t,
                   'detail' => "#{t} has no native Sigma element kind",
                   'options' => [APPROX[t], 'skip this visual'], 'default' => APPROX[t] }
  elsif DROP.include?(t)
    questions << { 'id' => 'visual_unmigratable', 'severity' => 'review',
                   'visual' => v['title'] || v['visualId'], 'qs_type' => t,
                   'detail' => "#{t} has no Sigma equivalent and no field-well to data-migrate",
                   'options' => ['skip (record in warning manifest)'], 'default' => 'skip (record in warning manifest)' }
  end
end

# (c) scatter bubble-size channel dropped
all_visuals.select { |v| v['type'] == 'ScatterPlotVisual' }.each do |v|
  inner = nil
  # cheap detection: a scatter with >2 referenced measures usually carries a Size field
  if (v['columns'] || []).size > 2
    questions << { 'id' => 'scatter_bubble_size', 'severity' => 'review',
                   'visual' => v['title'] || v['visualId'],
                   'detail' => 'QuickSight scatter bubble-size channel has no Sigma scatter size channel; bubbles render uniform-size (measure still projected as a column)',
                   'options' => ['proceed (uniform bubbles)', 'skip this visual'], 'default' => 'proceed (uniform bubbles)' }
  end
end

# (d) connection / folder not supplied
unless opts[:conn]
  questions << { 'id' => 'connection', 'severity' => 'required',
                 'detail' => 'No Sigma --connection supplied; required to point the DM at the warehouse',
                 'options' => ['supply --connection <id>'], 'default' => nil }
end
unless opts[:folder]
  questions << { 'id' => 'folder', 'severity' => 'required',
                 'detail' => 'No Sigma --folder supplied; DM + workbook will land in My Documents',
                 'options' => ['supply --folder <id>', 'proceed into My Documents'], 'default' => 'proceed into My Documents' }
end

# RUN-EACH-TIME GAP-SCOUT GATE (bead beads-sigma-5l5e). Degraded calcs are
# scout-eligible — the gap-scout must ATTEMPT a Sigma translation for each
# before we accept the Null degradation. --yes does NOT skip this; it only
# accepts calcs the scout already tried (validated locally, or escalated). The
# scout records each to <WORK>/scout-ledger.jsonl via scout-validate-and-persist.
calc_gaps = questions.select { |q| q['id'] == 'calc_degraded' }
unless calc_gaps.empty?
  gid = ->(q) { "calc:" + q['detail'].to_s.gsub(/\s+/, ' ').strip[0, 80] }
  gap_ids = calc_gaps.map { |q| gid.call(q) }.uniq
  buckets = ScoutGate.classify(WORK, gap_ids)
  if buckets[:unscouted].any?
    unattended = opts[:yes] || opts[:answers]
    if unattended
      # Regression fix (gap-scout PR #153 made this a hard `exit 11` that overrode
      # --yes, stalling the unattended/demo path). Under --yes/--answers the gate is
      # ADVISORY: these calcs take their "proceed" default (already in the decisions
      # list) and the run flows through. Record as accepted so re-runs don't re-surface
      # them; recommend the gap-scout for anyone who wants a faithful translation.
      warn "   gap-scout: #{buckets[:unscouted].size} degraded calc(s) not scouted — proceeding (unattended); recording as accepted degradations."
      warn '   (optional: run scripts/gap-scout.md on these to persist a faithful Sigma translation)'
      buckets[:unscouted].each { |id| ScoutGate.record(WORK, gap_id: id, feature: 'calc', status: 'accepted') }
    else
      # Interactive: the same calcs already appear as review questions and exit via
      # the OPEN QUESTIONS block below (exit 10). Just nudge toward the scout.
      puts
      puts '-------------------- GAP-SCOUT RECOMMENDED --------------------'
      puts "#{buckets[:unscouted].size} of #{gap_ids.size} degraded calc(s) have no faithful translation yet:"
      buckets[:unscouted].each { |id| puts "  --gap-id '#{id}'" }
      puts ''
      puts 'Optional: spawn a gap-scout per calc (scripts/gap-scout.md) with the --gap-id above'
      puts "plus --workdir #{WORK} to persist a translation; or re-run with --yes to accept the"
      puts 'degradation defaults. These also appear in OPEN QUESTIONS below.'
      puts '---------------------------------------------------------------'
    end
  else
    puts "   gap-scout: all #{gap_ids.size} degraded calc(s) accounted for (validated or escalated)"
  end
end

answers = nil
if opts[:answers]
  answers = JSON.parse(opts[:answers]) rescue abort("FATAL: --answers is not valid JSON")
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'analysis' => an_name,
    'phases_completed' => ['1 Discover', '2 Convert'],
    'note' => 'Deterministic mechanical steps (fixup, POST, layout, parity) are NOT asked about. ' \
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
  puts "   no open questions — running straight through"
end

# ---------------------------------------------------------------------------
# Phase 2.5 — DM reuse check (qs-dm-signature.py + find-or-pick-dm.rb).
# DEFAULT = BUILD NEW. The scan is informational: it surfaces a reusable
# candidate (avoids a 4th near-identical "Orders" DM) and the exact flag to
# attach to it (--reuse-dm <id>), but never silently reuses.
# ---------------------------------------------------------------------------
require 'sigma_rest' # also loads ~/.sigma-migration/env for the child scripts

# --folder accepts a NAME or an id (bead eqom): anything that isn't a UUID is
# looked up by exact (case-insensitive) folder name via /v2/files.
if opts[:folder] && opts[:folder] !~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  want = opts[:folder].strip.downcase
  entries = (Sigma.request(:get, '/v2/files?typeFilters=folder&limit=500')['entries'] rescue []) || []
  hits = entries.select { |e| (e['name'] || '').strip.downcase == want }
  abort "FATAL: --folder #{opts[:folder].inspect} matched no folder by name — list them via GET /v2/files?typeFilters=folder, or pass an id" if hits.empty?
  abort "FATAL: --folder #{opts[:folder].inspect} is ambiguous (#{hits.size} folders named that): #{hits.map { |h| h['id'] }.join(', ')} — pass an id" if hits.size > 1
  puts "   --folder resolved by name: '#{hits[0]['name']}' → #{hits[0]['id']}"
  opts[:folder] = hits[0]['id']
end

hdr('2.5', TOTAL, 'DM reuse check')
if opts[:reuse_dm]
  puts "   --reuse-dm #{opts[:reuse_dm]} — attaching to the existing DM (Phase 3 skipped)"
elsif opts[:skip_reuse]
  puts '   skipped (--skip-reuse-check) — building a new DM'
else
  begin
    sig_path = File.join(WORK, 'dm-signature.json')
    run!([*PyResolve.argv, File.join(HERE, 'qs-dm-signature.py'),
          '--discover-dir', WORK, '--out', sig_path])
    match_path = File.join(WORK, 'dm-match.json')
    fop_out, = Open3.capture2e('ruby', File.join(HERE, 'find-or-pick-dm.rb'),
                               '--workbook-signature', sig_path, '--out', match_path,
                               '--auto-pick', '--auto-pick-threshold', '0.5')
    match = File.exist?(match_path) ? (JSON.parse(File.read(match_path)) rescue {}) : {}
    # Reuse-first (matches thoughtspot-to-sigma): the picker sets auto_picked only
    # when the top candidate covers ALL of this analysis's source tables — a safe
    # reuse that collapses duplicate-DM ties. When it fires, route into the
    # `elsif opts[:reuse_dm]` branch below (skips the DM POST).
    if !opts[:reuse_dm] && match['auto_picked'] && match['recommended_dm_id']
      opts[:reuse_dm] = match['recommended_dm_id']
      puts "   DM-REUSE (auto): #{match['rationale']}"
      puts "   WARNING: #{match['warning']}" if match['warning']
    end
    best = (match['candidates'] || []).first
    if opts[:reuse_dm]
      # auto-reuse fired — candidate hints would be misleading; stay quiet
    elsif best && best['score'].to_f >= 0.6
      puts "   candidate: '#{best['dm_name']}' (#{best['dm_id']}) score=#{best['score']} — " \
           "#{(best['shared_columns'] || []).size} shared column(s), #{best['extra_columns']} inherited extra(s)"
      puts "   default = BUILD NEW. To reuse it instead, re-run with --reuse-dm #{best['dm_id']}"
    else
      puts '   no reusable DM found (score < threshold) — building new'
    end
  rescue StandardError => e
    puts "   reuse scan failed (#{e.message[0, 80]}) — building new (the scan is advisory only)"
  end
end

# ---------------------------------------------------------------------------
# Phase 3 — Fixup + POST data model (skipped when --reuse-dm attaches to one)
# ---------------------------------------------------------------------------
hdr(3, TOTAL, 'Build data model')
dm_spec = File.join(WORK, 'dm-spec.json')
dm_readback = File.join(WORK, 'dm-readback.json')
# Idempotent resume BEFORE the parity state (bead eqom): a mid-run crash after
# the DM POST must not create a duplicate DM on re-run. dm-readback.json is
# written only by a successful post — when this workdir already has one,
# verify the DM still exists and REUSE it.
prior_dm = File.exist?(dm_readback) ? (JSON.parse(File.read(dm_readback))['dataModelId'] rescue nil) : nil
if prior_dm && !opts[:reuse_dm]
  if (Sigma.request(:get, "/v2/dataModels/#{prior_dm}") rescue nil)
    dm_id = prior_dm
    puts "   idempotent resume: dataModelId #{dm_id} was already posted by a prior run of"
    puts "   this workdir — REUSING it (no duplicate DM). Use a fresh --out for a fresh build."
  else
    puts "   prior dataModelId #{prior_dm} in #{dm_readback} no longer exists — rebuilding"
    prior_dm = nil
  end
end
if dm_id
  # reused above — nothing to post
elsif opts[:reuse_dm]
  # Read the existing DM's spec back and synthesize the dm-readback artifact the
  # workbook builder consumes (element names/ids). The spec endpoint answers in
  # YAML even when asked for JSON — parse both.
  raw = Sigma.request(:get, "/v2/dataModels/#{opts[:reuse_dm]}/spec", binary: true)
  spec = begin
    JSON.parse(raw)
  rescue JSON::ParserError
    require 'yaml'
    require 'date'
    YAML.safe_load(raw, permitted_classes: [Date, Time]) || {}
  end
  dm_rb = { 'dataModelId' => opts[:reuse_dm] }.merge(spec)
  File.write(dm_readback, JSON.pretty_generate(dm_rb))
  dm_id = opts[:reuse_dm]
  puts "   reusing dataModelId = #{dm_id} ('#{spec['name']}') — shape preflight: " \
       "#{(spec['pages'] || []).flat_map { |p| p['elements'] || [] }.size} element(s) read back"
else
  fixup = ['ruby', File.join(HERE, 'convert-model.rb'), '--fixup',
           '--in', File.join(WORK, 'converter-out.json'),
           '--discover-dir', WORK, '--out', dm_spec]
  fixup += ['--folder-id', opts[:folder]] if opts[:folder]
  run!(fixup)
  if opts[:name]
    j = JSON.parse(File.read(dm_spec))
    j['name'] = "#{opts[:name]} DM"
    File.write(dm_spec, JSON.pretty_generate(j))
  end
  run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec])
  run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
        '--spec', dm_spec, '--out', dm_readback, '--workdir', WORK])
  dm_id = JSON.parse(File.read(dm_readback))['dataModelId']
  puts "   dataModelId = #{dm_id}"
end

# ---------------------------------------------------------------------------
# Phase 4 — Build workbook
# ---------------------------------------------------------------------------
hdr(4, TOTAL, 'Build workbook')
wb_spec = File.join(WORK, 'wb-spec.json')
wb_readback = File.join(WORK, 'wb-readback.json')
# Idempotent resume (bead eqom): a workbook already posted by this workdir is
# reused — never duplicated. wb-id.txt is the primary record; wb-readback.json
# still holds workbookId when the crash hit before wb-id.txt was written.
prior_wb = File.exist?(wb_id_path) ? File.read(wb_id_path).strip : nil
prior_wb = (JSON.parse(File.read(wb_readback))['workbookId'] rescue nil) if (prior_wb.nil? || prior_wb.empty?) && File.exist?(wb_readback)
if prior_wb && !prior_wb.empty?
  if (Sigma.request(:get, "/v2/workbooks/#{prior_wb}") rescue nil)
    wb_id = prior_wb
    File.write(wb_id_path, wb_id)
    puts "   idempotent resume: workbook #{wb_id} was already posted by a prior run of"
    puts "   this workdir — REUSING it (no duplicate workbook). Use a fresh --out for a fresh build."
  else
    puts "   prior workbookId #{prior_wb} no longer exists — rebuilding"
  end
end
unless wb_id
build = ['ruby', File.join(HERE, 'build-workbook-from-quicksight.rb'),
         '--analysis', File.join(WORK, 'analysis.json'),
         '--dm-readback', dm_readback, '--out', wb_spec]
build += ['--dm-spec', dm_spec] if File.exist?(dm_spec)
build += ['--discover-dir', WORK]   # datasets/*.json -> boolean-flag predicate rewrite (RCA #3)
build += ['--folder-id', opts[:folder]] if opts[:folder]
filters = File.join(WORK, 'dm-filters.json')
build += ['--filters', filters] if File.exist?(filters)
run!(build)
if opts[:name]
  j = JSON.parse(File.read(wb_spec))
  j['name'] = opts[:name]
  File.write(wb_spec, JSON.pretty_generate(j))
end
run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
      '--spec', wb_spec, '--out', wb_readback, '--workdir', WORK])
wb_id = JSON.parse(File.read(wb_readback))['workbookId']
# Phase 6 PASS 1 overwrites wb-readback.json with the live spec (no workbookId
# key), so persist the id separately — the parity-finalize resume needs it.
File.write(wb_id_path, wb_id)
puts "   workbookId = #{wb_id}"
end # unless wb_id (idempotent resume)

# ---------------------------------------------------------------------------
# Phase 5 — Layout (build-quicksight-layout.rb infers the QS grid width — the
# explicit-index 12/18/24/36-col cases — and emits the Sigma layout XML)
# ---------------------------------------------------------------------------
hdr(5, TOTAL, 'Layout')
layout = File.join(WORK, 'layout.xml')
run!(['ruby', File.join(HERE, 'build-quicksight-layout.rb'),
      '--analysis', File.join(WORK, 'analysis.json'),
      '--map', wb_spec.sub(/\.json$/, '') + '.map.json', '--out', layout])
run!(['ruby', File.join(HERE, 'put-layout.rb'), '--workbook', wb_id, '--layout', layout])
puts "   layout applied to workbook #{wb_id}"

# ---------------------------------------------------------------------------
# Phase 5b — Visual QA: render each CONTENT page to a FULL-PAGE PNG so the
# layout can be reviewed against refs/layout-visual-qa.md AND compared to the
# source QuickSight sheet — matching the other migration skills' visual-QA gate
# (tableau/qlik Phase 5b). Render is NON-FATAL (a transient export failure must
# not sink a green migration); the REVIEW is the gate, not the render.
# ---------------------------------------------------------------------------
require 'sigma_rest' # exposes Sigma.auth_token (override → SIGMA_API_TOKEN → refresh)
vqa = File.join(WORK, 'visual-qa')
FileUtils.mkdir_p(vqa)
# Page ids come from the LOCAL spec the builder wrote (<WORK>/wb-spec.json) —
# deterministic. The live GET /spec readback proved flaky in the pipeline
# (returns YAML / silently zero pages); POST preserves these ids, so the local
# copy is authoritative. Exclude any id containing "data" (hidden data pages).
wbspec = (JSON.parse(File.read(wb_spec)) rescue {})
content_pages = (wbspec['pages'] || []).reject { |p| p['id'].to_s.downcase.include?('data') }
tok = (Sigma.auth_token rescue ENV['SIGMA_API_TOKEN'])
pngs = []
content_pages.each do |pg|
  out = File.join(vqa, "#{pg['id']}.png")
  _o, st = Open3.capture2e({ 'SIGMA_API_TOKEN' => tok.to_s }, *PyResolve.argv,
                           File.join(HERE, 'sigma-export-png.py'),
                           '--workbook', wb_id, '--page', pg['id'], '--out', out,
                           '--w', '1800', '--h', '1000')
  st.success? ? (pngs << out) : (puts "   [warn] visual-QA render failed for page #{pg['id']}")
end
puts "   rendered #{pngs.size}/#{content_pages.size} full-page PNG(s) for visual QA → #{vqa}"
if pngs.any?
  puts '   VISUAL QA (mandatory review — do not skip): open each PNG and check vs'
  puts '   refs/layout-visual-qa.md AND the source QuickSight sheet — populated controls,'
  puts '   titles present, right chart kinds, sensible colors/heights, no overlaps/dead zones.'
end

end # resume_parity skip of phases 1-5

# ---------------------------------------------------------------------------
# Phase 6 — Parity (two-pass, hard-gated):
#   guard  — no workbook column resolved to type "error"
#   PASS 1 — phase6-parity-quicksight.rb emits parity-plan.json + the per-chart
#            sigma-mcp-v2 query list, then GATES (exit 10): the agent collects
#            Sigma ACTUAL rows + warehouse EXPECTED rows and re-runs (resume).
#   PASS 2 — --finalize + assert-phase6-ran.rb --workdir (the hard gate).
# ---------------------------------------------------------------------------
hdr(6, TOTAL, 'Parity (two-pass, hard-gated)')
require 'sigma_rest'
cols = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/columns") rescue { 'entries' => [] })
err_cols = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
total_cols = (cols['entries'] || []).size
unless err_cols.empty?
  puts "   GUARD FAIL — #{err_cols.size}/#{total_cols} column(s) resolved to type 'error':"
  err_cols.first(8).each { |c| puts "     [#{c['elementId']}] #{c['label']}: #{c['formula']}" }
  exit 3
end
puts "   guard: #{total_cols} workbook column(s) resolve (0 error-typed)"

have_parity_inputs = File.exist?(exp_path) && File.exist?(act_path)
unless File.exist?(File.join(WORK, 'parity-plan.json')) && have_parity_inputs
  run!(['ruby', File.join(HERE, 'phase6-parity-quicksight.rb'),
        '--workdir', WORK, '--workbook-id', wb_id])
end

unless have_parity_inputs
  puts
  puts '   >>> GATE: collect the Sigma ACTUAL rows (sigma-mcp-v2 queries above) and the'
  puts '       warehouse EXPECTED rows (same dim+aggregation, type=connection query), write'
  puts "         #{exp_path}"
  puts "         #{act_path}"
  puts '       then RE-RUN THIS SAME COMMAND — phases 1-5 are skipped automatically'
  puts '       (or pass --expected/--actuals explicitly).'
  exit 10
end

fin = ['ruby', File.join(HERE, 'phase6-parity-quicksight.rb'),
       '--workdir', WORK, '--finalize', '--expected', exp_path, '--actuals', act_path]
fin += ['--extract-mode', '--extract-tol', (opts[:tol] || 0.30).to_s] if opts[:extract]
fin_out, fin_st = Open3.capture2e(*fin)
fin_out.each_line { |l| puts "   #{l.rstrip}" }
parity_ok = fin_st.success?

# the shared HARD GATE: parity sentinel + orphan + error-column + layout checks.
gate_out, gate_st = Open3.capture2e('ruby', File.join(HERE, 'assert-phase6-ran.rb'),
                                    '--workdir', WORK, '--workbook-id', wb_id)
gate_out.each_line { |l| puts "   #{l.rstrip}" }
gate_ok = gate_st.success?

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts
puts '================ RESULT ================'
puts "dataModelId : #{dm_id}"
puts "workbookId  : #{wb_id}"
puts "PARITY      : #{parity_ok ? 'PASS' : 'FAIL'} (#{total_cols} cols resolve, 0 error)"
puts "HARD GATE   : #{gate_ok ? 'PASS' : 'FAIL'} (assert-phase6-ran)"
wf = File.join(WORK, 'wb-spec.warnings.json')
if File.exist?(wf)
  wl = (JSON.parse(File.read(wf))['warnings'] rescue []) || []
  puts "warnings    : #{wl.size} (see #{wf})" unless wl.empty?
end
puts '======================================='
exit(parity_ok && gate_ok ? 0 : 3)
