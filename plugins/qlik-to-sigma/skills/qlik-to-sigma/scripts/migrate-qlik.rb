#!/usr/bin/env ruby
# migrate-qlik.rb — ONE-COMMAND, single-process orchestrator for the
# qlik-to-sigma pipeline: discover → convert → data model → workbook → layout
# → parity, for ANY app/sheet, with zero hand-edits. Every phase prints a
# visible header + concise result, and the genuine human decision points are
# surfaced as a structured OPEN QUESTIONS block (exit 10) rather than silently
# auto-resolved.
#
# This script does NOT re-implement any phase — it chains the per-phase scripts
# (each independently usable + artifact-driven):
#   qlik-discover.py            (Phase 1 — model, charts, sheet CELL GRIDS, app
#                                freshness meta + Qlik-engine KPI snapshot.
#                                Runs as a BACKGROUND lane with --defer-snapshot
#                                while the pure-Sigma-side prep — token mint,
#                                folder resolve, DM list+spec prefetch — runs
#                                concurrently in the foreground; the engine
#                                snapshot then runs as its OWN background lane
#                                under Phases 2-4 and is consumed only at the
#                                Phase-6 freshness banner. In-memory app totals
#                                cannot change without a reload, so the deferral
#                                is exact. Measured: 54.8s serial discovery →
#                                ~12s lane + ~4s snapshot hidden under the build.)
#   convertQlikToSigma()        (Phase 2 — the sigma-data-model-mcp converter, via node shim)
#   reconcile-columns.py + gen-denorm-sql.py + build-sigma-dm.py
#                               (Phase 3 — star repointed via reconcile + denorm
#                                SQL element + metrics, POST /v2/dataModels/spec)
#   build-sigma-workbook.py     (Phase 4 — one Sigma page per Qlik sheet from
#                                charts.json, POST /v2/workbooks/spec)
#   put-layout.rb               (Phase 5 — the Qlik cell grid mapped onto Sigma's
#                                24-col grid, straight from discovery)
#   Phase 6 — parity: column resolution + SOURCE-FRESHNESS banner (Qlik snapshot
#   vs live warehouse, led by the app's lastReloadTime) + per-KPI value compare
#   + per-chart BUCKET-COUNT compare vs the Qlik engine (so suppressed-null-
#   bucket mismatches surface even when cell values match).
#
# The genuine Qlik decision points (and ONLY these) are surfaced at the
# checkpoint: master-measure expressions with no clean Sigma equivalent,
# Section Access, DirectQuery vs in-memory, and charts with no native Sigma
# kind. Mechanical steps (reconcile, denorm SQL, POST, layout, parity) are
# NEVER asked about.
#
# Usage:
#   ruby scripts/migrate-qlik.rb \
#     --app <qlikAppId> --connection <SIGMA_CONNECTION_ID> \
#     [--database <DB>] [--schema <SCHEMA>] [--context sigma-migration] \
#     [--folder <SIGMA_FOLDER_ID>] [--name '<prefix for DM/workbook names>'] \
#     [--out DIR] [--answers '<json>'] [--yes] \
#     [--from-discovery DIR]   # reuse an existing discovery dir (e.g. fixtures/) — skips Phase 1
#     [--unbuild DIR]          # normalize a corectl unbuild folder, then run the same pipeline
#     [--dry-run]              # offline: no Sigma POSTs, no qlik-cli needed with --from-discovery;
#                              # emits dm-spec.json / wb-spec.json / layout.xml and stops
#
# Exit codes: 0 = done (PARITY GREEN); 10 = decisions needed (OPEN QUESTIONS printed,
# no Sigma objects created); 3 = built but PARITY RED; other = error.
require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require 'time'
require_relative 'lib/scout_gate'
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)
begin; require_relative 'lib/modeling_advisory'; rescue LoadError; end # shared, vendor-neutral CDW join-cost advisory (optional; synced from shared/)

$stdout.sync = true # lane/foreground progress lines interleave correctly

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('vendor/lib', HERE)
require 'code_rep'

# Phase-timing summary — printed at every terminal exit so the discovery
# interleave speedup stays visible in every run (regressions show up in the
# first slow report instead of an investigation).
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

# Background lanes (discovery / engine snapshot). Artifacts are written
# atomically by qlik-discover.py, so polling for them is safe.
def spawn_lane(cmd, log)
  File.write(log, '')
  { started: Time.now, log: log, status: nil,
    pid: Process.spawn(*cmd, %i[out err] => [log, 'a']) }
end

def lane_done?(lane)
  return true if lane.nil? || lane[:status]
  if (st = Process.wait2(lane[:pid], Process::WNOHANG))
    lane[:status] = st[1]
    lane[:ended] = Time.now
    true
  else
    false
  end
end

def join_lane(lane, label, timeout: 600)
  t0 = Time.now
  until lane_done?(lane)
    abort "FATAL: #{label} lane timed out (#{timeout}s)" if Time.now - t0 > timeout
    sleep 0.1
  end
  lane
end

def print_lane_log(lane)
  return unless lane && File.exist?(lane[:log])
  File.read(lane[:log]).each_line { |l| puts "   │ #{l.rstrip}" }
end

opts = { context: 'sigma-migration', database: 'DEMO_DB', schema: 'DEMO' }
OptionParser.new do |o|
  o.on('--app ID')            { |v| opts[:app]      = v }
  o.on('--connection ID')     { |v| opts[:conn]     = v }
  o.on('--database DB')       { |v| opts[:database] = v }
  o.on('--schema S')          { |v| opts[:schema]   = v }
  o.on('--context CTX')       { |v| opts[:context]  = v }
  o.on('--folder ID')         { |v| opts[:folder]   = v }
  o.on('--name PREFIX')       { |v| opts[:name]     = v }
  o.on('--out DIR')           { |v| opts[:out]      = File.expand_path(v) }
  o.on('--answers JSON')      { |v| opts[:answers]  = v }
  o.on('--yes')               {     opts[:yes]      = true }
  o.on('--from-discovery DIR'){ |v| opts[:from]     = File.expand_path(v) }
  o.on('--unbuild DIR')       { |v| opts[:unbuild]  = File.expand_path(v) }
  o.on('--prj DIR')           { |v| opts[:prj]      = File.expand_path(v) }
  o.on('--reuse-dm ID')       { |v| opts[:reuse_dm] = v }
  o.on('--no-reuse')          {     opts[:no_reuse] = true }
  o.on('--dry-run')           {     opts[:dry_run]  = true }
  o.on('--skip-layout-lint')  {     opts[:skip_layout_lint] = true }
  o.on('--skip-control-flip [REASON]') { |v| opts[:skip_control_flip] = v || true } # waive gate 7b (runtime control-flip proof); name the reason in your report
  o.on('--skip-visual-comparison REASON') { |v| opts[:skip_visual_comparison] = v }
  o.on('--skip-visual-similarity REASON') { |v| opts[:skip_visual_similarity] = v }
  o.on('--skip-anchors-gate REASON') { |v| opts[:skip_anchors_gate] = v }
  # Resolve + print which converter would run (vendored vs explicit dev build), then
  # exit 0 — no creds/args needed. Used by the converter-default regression test.
  o.on('--print-converter')   {     opts[:print_converter] = true }
end.parse!

abort 'FATAL: choose only one of --unbuild, --prj, or --from-discovery' \
  if [opts[:unbuild], opts[:prj], opts[:from]].compact.size > 1

# A corectl unbuild is already a complete offline Qlik extraction, but sheets
# are full property trees whose visuals live recursively under qChildren. Flatten
# it into the same artifact contract as live discovery before the standard path.
if opts[:unbuild]
  abort "FATAL: --unbuild dir not found: #{opts[:unbuild]}" unless File.directory?(opts[:unbuild])
  unbuild_slug = File.basename(opts[:unbuild]).sub(/-unbuild\z/i, '').gsub(/[^A-Za-z0-9_-]/, '-')
  disc_dir = opts[:out] || File.expand_path("~/qlik-migration/#{unbuild_slug}-unbuild")
  FileUtils.mkdir_p(disc_dir)
  warn "corectl unbuild → discovery artifacts in #{disc_dir}"
  ok = system(*PyResolve.argv, File.join(HERE, 'qlik-unbuild-discover.py'),
              '--unbuild', opts[:unbuild], '--out', disc_dir)
  abort 'FATAL: qlik-unbuild-discover.py failed' unless ok
  opts[:from] = disc_dir
  opts[:app] = nil
end

# QlikView (.qvw) has no Cloud/REST API. A "-prj" project folder is the migration
# surface: qlik-prj-discover.py parses it into the SAME discovery artifacts the Qlik
# Sense pipeline consumes (script.qvs, converter-input.json, charts.json, measures.json,
# layout.json), so the rest of this script (convert -> data model -> workbook) runs
# UNCHANGED via the --from-discovery path. There is no live engine, so the Qlik-side
# value snapshot / parity leg simply stays empty (warehouse-only parity downstream).
if opts[:prj]
  abort "FATAL: --prj dir not found: #{opts[:prj]}" unless File.directory?(opts[:prj])
  prj_slug = File.basename(opts[:prj]).sub(/-prj\z/i, '').gsub(/[^A-Za-z0-9_-]/, '-')
  disc_dir = opts[:out] || File.expand_path("~/qlik-migration/#{prj_slug}-prj")
  FileUtils.mkdir_p(disc_dir)
  warn "QlikView -prj → discovery artifacts in #{disc_dir}"
  ok = system(*PyResolve.argv, File.join(HERE, 'qlik-prj-discover.py'),
              '--prj', opts[:prj], '--out', disc_dir)
  abort 'FATAL: qlik-prj-discover.py failed' unless ok
  opts[:from] = disc_dir           # hand off to the standard --from-discovery pipeline
  opts[:app]  = nil
end

# Converter resolution (issue #227). The pinned VENDORED bundle is the DEFAULT so a
# developer machine and a customer machine produce identical output for the same
# input. A local sigma-data-model-mcp build is used ONLY when EXPLICITLY opted in
# via QLIK_MCP_DIR — there is NO silent auto-discovery of ~/… checkouts (that was
# the "works in my demo, differs for the customer" footgun). Returns
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
      "DEV BUILD #{conv} (explicit opt-in via QLIK_MCP_DIR)"
    else
      'NONE — vendored bundle missing; convert_qlik_to_sigma MCP / --converter-out (converter-out.json) resume applies'
    end
  [conv, build_dir, desc]
end

VENDORED_QLIK = File.expand_path('../converter/qlik.mjs', __dir__)
if opts[:print_converter]
  conv, _bd, desc = resolve_converter(ENV['QLIK_MCP_DIR'], VENDORED_QLIK, 'qlik.js')
  puts(conv || 'none')
  puts desc
  exit 0
end

abort 'missing --app (or --from-discovery/--unbuild/--prj)' unless opts[:app] || opts[:from]
# intake.rb (front-door) caches the resolved connection in <out>/connection.json; honor it
# when --connection is omitted so the agent need not re-pass the id it just resolved.
opts[:conn] ||= (JSON.parse(File.read(File.join(opts[:out], 'connection.json')))['connection_id'] rescue nil) if opts[:out]
abort 'missing --connection (pass --connection <id>, or run intake.rb first and point --out at its --workdir)' unless opts[:conn]

# Converter resolution (issue #227): the pinned VENDORED bundle is the DEFAULT so a
# dev machine and a customer machine convert identically. A local build is used ONLY
# via explicit QLIK_MCP_DIR — no silent auto-discovery of ~/… checkouts. CONV_MODULE
# is what the Phase-2 shim imports; nil only if the bundle is also absent (then
# --converter-out / the convert_qlik_to_sigma MCP gate applies).
CONV_MODULE, MCP_DIR, CONVERTER_DESC =
  resolve_converter(ENV['QLIK_MCP_DIR'], VENDORED_QLIK, 'qlik.js')
warn "converter: #{CONVERTER_DESC}"

name_slug = (opts[:app] || File.basename(opts[:from].to_s)).gsub(/[^A-Za-z0-9_-]/, '-')
WORK = opts[:out] || File.expand_path("~/qlik-migration/#{name_slug}")
FileUtils.mkdir_p(WORK)

def hdr(n, total, title)
  puts
  puts "── Phase #{n}/#{total} · #{title} ──"
end

def run!(cmd, env: {})
  out, st = Open3.capture2e(env, *cmd)
  # Windows consoles hand back cp1252 bytes (e.g. em-dash -> 0x97) that are invalid
  # UTF-8; scrub so the strip/each_line below never raise Encoding::CompatibilityError.
  out = out.force_encoding('UTF-8').scrub
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success?
  out
end

def qlik_eval(app, ctx, expr)
  # qlik-cli echoes the expression before the value: a multi-line expression
  # would push the value off line 2. Whitespace is insignificant in Qlik exprs.
  out, st = Open3.capture2('qlik', 'app', 'eval', expr.to_s.gsub(/\s*[\r\n]+\s*/, ' '), '-a', app, '--context', ctx)
  return nil unless st.success?
  lines = out.split("\n").reject { |l| l.strip.empty? }
  lines[1]&.strip
end

def numish(s)
  return nil if s.nil?
  t = s.to_s.gsub(/[$,%\s]/, '')
  t =~ /\A-?\d+(\.\d+)?\z/ ? t.to_f : nil
end

# A Qlik display value ("$529.2M", "$837.0") equals a warehouse number when the
# number rounds to it at the precision and unit scale Qlik printed.
QLIK_SCALE = { 'K' => 1e3, 'M' => 1e6, 'B' => 1e9, 'G' => 1e9, 'T' => 1e12 }.freeze
def display_match?(shown, number)
  return false if shown.nil? || number.nil?
  m = shown.to_s.gsub(/[$,\s]/, '').match(/\A(-?\d+(?:\.(\d+))?)([KMBGT])?\z/i)
  return false unless m
  scale = m[3] ? QLIK_SCALE[m[3].upcase] : 1.0
  tol = 0.5 * (10.0**-(m[2] ? m[2].length : 0)) * scale
  (m[1].to_f * scale - number).abs <= tol + 1e-9
end

TOTAL = 6

# ---------------------------------------------------------------------------
# Phase 1 — Discover (qlik-cli), INTERLEAVED. qlik-discover.py (its own pooled
# fetcher, --defer-snapshot) runs as a BACKGROUND lane while the pure-Sigma-
# side prep (token mint, folder resolve, DM list+spec prefetch for the
# Phase-2.5 reuse scan — all READ-ONLY, no Sigma objects created) runs
# concurrently in the foreground. The lanes JOIN before anything consumes
# discovery output. The Qlik-engine snapshot then runs as its OWN lane under
# Phases 2-4 (in-memory totals can't change without a reload) and is consumed
# at the Phase-6 freshness banner.
# ---------------------------------------------------------------------------
hdr(1, TOTAL, 'Discover')
$t_mark = Time.now
snap_lane = nil
prep = {}
if opts[:from]
  %w[script.qvs measures.json charts.json converter-input.json].each do |f|
    abort "FATAL: --from-discovery dir missing #{f}" unless File.exist?(File.join(opts[:from], f))
  end
  if opts[:from] != WORK
    Dir[File.join(opts[:from], '*')].each { |f| FileUtils.cp(f, WORK) }
  end
  puts "   reusing discovery artifacts from #{opts[:from]}"
else
  disc_lane = spawn_lane([*PyResolve.argv, File.join(HERE, 'qlik-discover.py'),
                          '--app', opts[:app], '--context', opts[:context],
                          '--out', WORK, '--defer-snapshot'],
                         File.join(WORK, 'phase1-discover.log'))
  puts "   Qlik discovery: BACKGROUND lane (pid #{disc_lane[:pid]}, log phase1-discover.log;"
  puts "   engine snapshot deferred to its own lane). Sigma-side prep runs concurrently."

  if opts[:dry_run]
    puts '   Sigma-side prep skipped (--dry-run)'
  else
    begin
      require 'sigma_rest'
      Sigma.auth_token # mint once — exported via ENV to every child script
      puts '   ✓ Sigma token ready'
      # Folder resolve (read-only; same preference order as build-sigma-dm.py's
      # pick_folder: editable TEST/MIGRATION folder, else first editable).
      folders = (Sigma.request(:get, '/v2/files?typeFilters=folder&limit=200')['entries'] rescue []) || []
      editable = folders.select do |f|
        f['type'] == 'folder' && (%w[edit contribute].include?(f['permission']) || f['permission'].nil?)
      end
      pick = editable.find { |f| f['name'].to_s.upcase =~ /TEST|MIGRATION/ } || editable.first
      if pick
        prep[:folder_id], prep[:folder_name] = pick['id'], pick['name']
        puts "   ✓ folder resolved: '#{pick['name']}' (#{pick['id']})" \
             "#{opts[:folder] ? ' — overridden by --folder' : ''}"
      end
      # DM list + spec prefetch — warms the Phase-2.5 reuse scan so it costs ~0
      # at scan time (mirrors find-or-pick-dm.rb's own list/sort/limit logic).
      all_dms, page = [], nil
      loop do
        qs = 'limit=100' + (page ? "&page=#{page}" : '')
        data = (Sigma.request(:get, "/v2/dataModels?#{qs}") rescue {})
        rows = data['entries'] || data['dataModels'] || []
        break if rows.empty?
        all_dms.concat(rows)
        break if all_dms.size >= 500
        page = data['nextPage']
        break if page.nil? || page.to_s.empty?
      end
      top = all_dms.sort_by { |dm| [-(Time.parse(dm['updatedAt'].to_s).to_i rescue 0), dm['name'].to_s] }
                   .first(25)
      specs, smu, sq = {}, Mutex.new, Queue.new
      top.each { |dm| sq << dm }
      Array.new(5) do
        Thread.new do
          loop do
            dm = (sq.pop(true) rescue nil) or break
            dm_id = dm['dataModelId'] || dm['id']
            next unless dm_id
            # spec endpoint may answer YAML — store the RAW body; the scan
            # (find-or-pick-dm.rb --specs-cache) parses JSON-else-YAML itself.
            raw = (Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec", accept: '*/*') rescue nil)
            smu.synchronize { specs[dm_id] = raw } if raw && !raw.to_s.empty?
          end
        end
      end.each(&:join)
      File.write(File.join(WORK, 'dm-specs-cache.json'),
                 JSON.generate('fetched_at' => Time.now.utc.iso8601,
                               'dms' => all_dms, 'specs' => specs))
      puts "   ✓ prefetched #{specs.size}/#{all_dms.size} DM spec(s) → dm-specs-cache.json (feeds Phase 2.5)"
    rescue StandardError => e
      puts "   Sigma-side prep degraded (#{e.class}: #{e.message[0, 120]}) — later phases fall back to inline resolution"
    end
  end
  mark('phase1-prep(fg)')

  join_lane(disc_lane, 'discovery')
  print_lane_log(disc_lane)
  abort "FATAL: qlik discovery failed (exit #{disc_lane[:status].exitstatus}) — see lane log above" \
    unless disc_lane[:status].success?
  PHASE_T['phase1-discovery(bg)'] = (disc_lane[:ended] - disc_lane[:started])

  # Engine-snapshot lane: runs under Phases 2-4, joined at Phase 6. Read-only.
  snap_lane = spawn_lane([*PyResolve.argv, File.join(HERE, 'qlik-discover.py'),
                          '--app', opts[:app], '--context', opts[:context],
                          '--out', WORK, '--snapshot-only'],
                         File.join(WORK, 'phase1-snapshot.log'))
  puts "   engine-snapshot lane started (pid #{snap_lane[:pid]}) — runs under Phases 2-4," \
       ' consumed at the Phase-6 freshness banner'
end
mark('phase1')

conv_input = JSON.parse(File.read(File.join(WORK, 'converter-input.json')))
charts     = JSON.parse(File.read(File.join(WORK, 'charts.json')))
measures   = JSON.parse(File.read(File.join(WORK, 'measures.json')))
app_meta   = File.exist?(File.join(WORK, 'app-meta.json')) ? JSON.parse(File.read(File.join(WORK, 'app-meta.json'))) : {}
snapshot   = File.exist?(File.join(WORK, 'snapshot.json')) ? JSON.parse(File.read(File.join(WORK, 'snapshot.json'))) : {}
sheets     = File.exist?(File.join(WORK, 'layout.json'))   ? JSON.parse(File.read(File.join(WORK, 'layout.json')))   : []
app_name   = app_meta['name'] || conv_input['appName'] || opts[:app]
base_name  = opts[:name] ? "#{opts[:name]} #{app_name}" : app_name

real_charts = charts.select { |c| (c['measures'] || []).any? && (c['dimensions'] || []).any? }
vsumm = charts.group_by { |c| c['vizType'] }.map { |k, v| v.size > 1 ? "#{k}×#{v.size}" : k }.join(', ')
puts "   app '#{app_name}': #{conv_input['tables'].size} table(s), #{measures.size} master measure(s), " \
     "#{charts.size} object(s) (#{vsumm}); #{real_charts.size} rebuildable chart(s); " \
     "#{sheets.size} sheet(s) with cell grids"
puts "   sectionAccess=#{app_meta.fetch('hasSectionAccess', '?')}  directQuery=#{app_meta.fetch('isDirectQueryMode', '?')}"

# --- Phase 1.5 — SOURCE-FRESHNESS PREFLIGHT (qtfu) -------------------------
# Compare the app's lastReloadTime + in-memory snapshot against the live
# warehouse BEFORE any side-by-side, so a stale Qlik snapshot is called out up
# front instead of surfacing as a mysterious parity delta.
stale_days = nil
if (lr = app_meta['lastReloadTime'])
  stale_days = ((Time.now - Time.parse(lr)) / 86_400).round(1)
  puts
  puts "   ⏱  SOURCE FRESHNESS: Qlik app last reloaded #{lr} (#{stale_days} days ago)"
  if (snapshot['kpis'] || []).any?
    puts "      Qlik in-memory snapshot: " +
         snapshot['kpis'].map { |k| "#{k['title']}=#{k['value']}" }.join(' · ')
  elsif snap_lane
    puts '      Qlik in-memory KPI snapshot: evaluating in a background lane — consumed at Phase 6.'
  end
  if stale_days >= 1
    puts "      → The Qlik snapshot is ~#{stale_days.ceil} day(s) old. Sigma queries the LIVE warehouse"
    puts "        and will show newer data; the full Qlik-vs-warehouse comparison runs at Phase 6."
    puts "        (Option: reload/repoint the Qlik app first if you need matching snapshots.)"
  end
end

# ---------------------------------------------------------------------------
# Phase 2 — Convert (run convertQlikToSigma via a node shim)
# ---------------------------------------------------------------------------
hdr(2, TOTAL, 'Convert')
conv_out_path = File.join(WORK, 'converter-out.json')
conv_raw_path = File.join(WORK, 'converter-out.raw.json')
if CONV_MODULE.nil? && (File.exist?(conv_raw_path) || File.exist?(conv_out_path))
  resume_path = File.exist?(conv_raw_path) ? conv_raw_path : conv_out_path
  puts "   converter build/bundle not found — reusing existing #{resume_path}"
  FileUtils.cp(resume_path, conv_raw_path) unless resume_path == conv_raw_path
elsif CONV_MODULE.nil?
  abort 'FATAL: no Qlik converter available (vendored converter/qlik.mjs missing and no QLIK_MCP_DIR) and no converter-out.json present'
else
  puts "   converter: #{CONV_MODULE == VENDORED_QLIK ? 'vendored bundle (converter/qlik.mjs)' : CONV_MODULE} (no data leaves this machine)"
  shim = File.join(WORK, '_convert.mjs')
  # Node ESM on Windows rejects a bare drive-letter specifier
  # (`import ... from "C:/path/qlik.mjs"` → ERR_UNSUPPORTED_ESM_URL_SCHEME,
  # protocol 'c:'). Absolute paths must be file:// URLs there. POSIX absolute
  # paths import fine as-is, so we only rewrite on Windows and leave the
  # (working) macOS/Linux path byte-identical.
  import_specifier =
    if Gem.win_platform? && CONV_MODULE.to_s.match?(/\A[A-Za-z]:/)
      'file:///' + CONV_MODULE.gsub('\\', '/')
    else
      CONV_MODULE
    end
  File.write(shim, <<~JS)
    import { readFileSync, writeFileSync } from 'node:fs';
    import { convertQlikToSigma } from #{import_specifier.to_json};
    const model = JSON.parse(readFileSync(#{File.join(WORK, 'converter-input.json').to_json}, 'utf8'));
    const out = convertQlikToSigma(model, {
      connectionId: #{opts[:conn].to_json},
      database: #{opts[:database].to_json},
      schema: #{opts[:schema].to_json},
    });
    writeFileSync(#{conv_raw_path.to_json}, JSON.stringify(out, null, 2));
  JS
  c_out, c_err, c_st = Open3.capture3('node', shim)
  abort "FATAL: converter failed:\n#{c_err}#{c_out}" unless c_st.success?
end
# Formula normalization is a required post-converter contract. It writes the
# formula-mapping.json consumed by full source accounting; silently proceeding
# without it would make variables/master items impossible to reconcile.
normalizer = File.join(HERE, 'normalize-qlik-expressions.py')
abort "FATAL: required post-converter normalizer missing: #{normalizer}" unless File.file?(normalizer)
run!([*PyResolve.argv, normalizer,
      '--input', File.join(WORK, 'converter-input.json'),
      '--converter-out', conv_raw_path,
      '--out', conv_out_path,
      '--formula-mapping', File.join(WORK, 'formula-mapping.json')])
abort 'FATAL: normalize-qlik-expressions.py did not write formula-mapping.json' \
  unless File.file?(File.join(WORK, 'formula-mapping.json'))
conv = JSON.parse(File.read(conv_out_path))
conv_warnings = conv['warnings'] || []
cstats = conv['stats'] || {}
puts "   #{cstats['elements']} element(s), #{cstats['columns']} column(s), " \
     "#{cstats['metrics']} metric(s), #{cstats['relationships']} relationship(s); " \
     "#{conv_warnings.size} converter warning(s)"
# Vendor-neutral CDW join-cost advisory (informational only; never gates). See refs/modeling-strategy.md.
ModelingAdvisory.print_if_relevant(cstats['relationships']) if defined?(ModelingAdvisory)
mark('phase2-convert')

# ---------------------------------------------------------------------------
# Phase 2.5 — DM-reuse scan (non-destructive; candidates PRINTED, default =
# BUILD NEW). Consumes the dm-specs-cache.json prefetched concurrently with
# discovery, so the scan itself costs ~0 network. Reuse stays an explicit
# human decision — see SKILL.md Phase 2.5.
# ---------------------------------------------------------------------------
hdr('2.5', TOTAL, 'DM-reuse scan')
if opts[:dry_run]
  puts '   skipped (--dry-run: no Sigma access)'
elsif opts[:reuse_dm]
  puts "   explicit --reuse-dm #{opts[:reuse_dm]} — scan skipped, will reuse that DM"
elsif opts[:no_reuse]
  puts '   --no-reuse — scan skipped, building new'
else
  begin
    sig_path = File.join(WORK, 'dm-signature.json')
    run!([*PyResolve.argv, File.join(HERE, 'qlik-dm-signature.py'),
          '--model', File.join(WORK, 'converter-input.json'),
          '--database', opts[:database], '--schema', opts[:schema], '--out', sig_path])
    match_path = File.join(WORK, 'dm-match.json')
    fp_cmd = ['ruby', File.join(HERE, 'vendor', 'find-or-pick-dm.rb'),
              '--workbook-signature', sig_path, '--out', match_path,
              '--auto-pick', '--auto-pick-threshold', '0.5']
    cache_path = File.join(WORK, 'dm-specs-cache.json')
    fp_cmd += ['--specs-cache', cache_path] if File.exist?(cache_path)
    _, _fp_st = Open3.capture2e(*fp_cmd) # exit 1 = no candidate ≥ min-score (normal)
    match = (JSON.parse(File.read(match_path)) rescue {}) || {}
    cands = (match['candidates'] || []).first(3)
    # reuse-first: the picker sets auto_picked ONLY when the top candidate covers
    # ALL of this app's source tables (a safe superset) and collapses dup-DM ties.
    if match['auto_picked'] && match['recommended_dm_id']
      opts[:reuse_dm] = match['recommended_dm_id']
      puts "   DM-REUSE (auto): #{match['rationale']}"
      puts "   WARNING: #{match['warning']}" if match['warning']
    elsif cands.any?
      puts '   top candidate(s) — default is BUILD NEW; to reuse, follow SKILL.md Phase 2.5:'
      cands.each { |c| puts "     score #{format('%.2f', c['score'] || 0)}  #{c['dm_id']}  '#{c['dm_name']}'" }
    else
      puts '   no existing DM covers this app — building new'
    end
  rescue StandardError => e
    puts "   DM-reuse scan unavailable (#{e.message[0, 100]}) — building new"
  end
end
mark('phase2.5-dm-scan')

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine Qlik human questions ONLY
# ---------------------------------------------------------------------------
questions = []

# (a) master-measure expressions the converter could not cleanly translate.
DEGRADE_RX = /Set Analysis|Aggr\(\)|Dual\(\)|selection-state|alternate.?state|no Sigma equivalent|no direct Sigma|stripped|column dropped/i
conv_warnings.select { |w| w.to_s =~ DEGRADE_RX }.each do |w|
  detail = w.to_s.gsub(/\s+/, ' ').strip
  mname = (detail =~ /"([^"]+)"/ ? $1 : nil)
  questions << { 'id' => 'measure_no_sigma_equiv', 'severity' => 'review',
                 'measure' => mname, 'detail' => detail,
                 'options' => ['proceed (measure best-effort/dropped; original Qlik expr kept in DM description)',
                               'abort and re-author this measure manually'],
                 'default' => 'proceed (measure best-effort/dropped; original Qlik expr kept in DM description)' }
end

# (b) Section Access — handled by the skill's RLS flow AFTER the model is posted.
if app_meta['hasSectionAccess'] == true
  questions << { 'id' => 'section_access', 'severity' => 'required',
                 'detail' => 'Qlik app uses Section Access (row-level security). After the model is posted, ' \
                             'run the skill\'s RLS flow (scripts/apply_sigma_rls.py — see SKILL.md "Security"); ' \
                             'it is NOT migrated automatically by this pipeline.',
                 'options' => ['proceed (migrate now; port security via apply_sigma_rls.py after)',
                               'abort until security is designed'],
                 'default' => 'proceed (migrate now; port security via apply_sigma_rls.py after)' }
end

# (c) DirectQuery vs in-memory — affects whether the Sigma connection is live/warehouse.
if app_meta['isDirectQueryMode'] == true
  questions << { 'id' => 'directquery_mode', 'severity' => 'review',
                 'detail' => 'Qlik app is in DirectQuery mode (queries the warehouse live rather than an ' \
                             'in-memory load). Confirm the Sigma --connection points at the SAME live warehouse ' \
                             'so parity holds; aggregations/row-counts differ from an in-memory snapshot otherwise.',
                 'options' => ["proceed (Sigma --connection #{opts[:conn]} IS the same warehouse)",
                               'abort and repoint the connection'],
                 'default' => "proceed (Sigma --connection #{opts[:conn]} IS the same warehouse)" }
end

# (d) charts with no native Sigma element kind (auto-chart is resolved by shape).
# filterpane/listbox are NOT skipped (control-targeting wave, workstream B):
# build-sigma-workbook.py turns them into Sigma list controls wired to the
# master (global scope, matching Qlik's associative model); alternate-state
# panes are flagged manual in its warnings + control-scope.json.
NATIVE = %w[barchart auto-chart kpi linechart table piechart combochart scatterplot pivot-table
            filterpane listbox].freeze
SKIP_KINDS = %w[sheet singlepublic appprops LoadModel measure dimension masterobject sheetlist].freeze
real_charts.each do |c|
  vt = c['vizType']
  next if NATIVE.include?(vt) || SKIP_KINDS.include?(vt)
  questions << { 'id' => 'chart_no_native_kind', 'severity' => 'review',
                 'visual' => c['title'] || c['id'], 'qlik_type' => vt,
                 'detail' => "Qlik '#{vt}' has no native Sigma element kind",
                 'options' => ['approximate-to-bar (data migrates, render approximates)', 'skip this chart'],
                 'default' => 'approximate-to-bar (data migrates, render approximates)' }
end

# (e) folder not supplied
unless opts[:folder] || opts[:dry_run]
  resolved = prep[:folder_id] ? "'#{prep[:folder_name]}' (#{prep[:folder_id]}) — pre-resolved during discovery" \
                              : 'the first editable folder (prefers a TEST/MIGRATION folder)'
  questions << { 'id' => 'folder', 'severity' => 'required',
                 'detail' => "No Sigma --folder supplied; DM + workbook will land in #{resolved}.",
                 'options' => ['supply --folder <id>', 'proceed into auto-resolved folder'],
                 'default' => 'proceed into auto-resolved folder' }
end

answers = nil
if opts[:answers]
  answers = (JSON.parse(opts[:answers]) rescue abort('FATAL: --answers is not valid JSON'))
end

# RUN-EACH-TIME GAP-SCOUT GATE (bead beads-sigma-5l5e). Untranslated measures
# are scout-eligible — the gap-scout must ATTEMPT a Sigma translation for each
# before the degradation is accepted. --yes does NOT skip this; it only accepts
# measures already scouted (validated or escalated). Recorded to the ledger by
# scout-validate.py via lib/scout_gate.py. A 'validated' row is honored only when
# it carries signed live-probe evidence (ScoutGate integrity, issue #458): a hand-
# written or forged 'validated' line is treated as unvalidated (→ escalated
# bucket), so the gate still blocks.
scout_gaps = questions.select { |q| q['id'] == 'measure_no_sigma_equiv' }
unless scout_gaps.empty?
  gid = ->(q) { 'measure:' + (q['measure'] || q['detail'].to_s.gsub(/\s+/, ' ').strip[0, 80]).to_s }
  gap_ids = scout_gaps.map { |q| gid.call(q) }.uniq
  buckets = ScoutGate.classify(WORK, gap_ids)
  if buckets[:unscouted].any?
    unattended = opts[:yes] || opts[:answers]
    if unattended
      # Regression fix (gap-scout PR #153 made this a hard `exit 11` that overrode
      # --yes, stalling the unattended/demo path). Under --yes/--answers the gate is
      # ADVISORY: these measures take their "proceed" default (already in the decisions
      # list) and the run flows through. Record as accepted so re-runs don't re-surface
      # them; recommend the gap-scout for anyone who wants a faithful translation.
      warn "   gap-scout: #{buckets[:unscouted].size} untranslated measure(s) not scouted — proceeding (unattended); recording as accepted degradations."
      warn '   (optional: run scripts/gap-scout.md on these to persist a faithful Sigma translation)'
      buckets[:unscouted].each { |id| ScoutGate.record(WORK, gap_id: id, feature: 'measure', status: 'accepted') }
    else
      # Interactive: the same measures already appear as review questions and exit via
      # the OPEN QUESTIONS block below (exit 10). Just nudge toward the scout.
      puts
      puts '-------------------- GAP-SCOUT RECOMMENDED --------------------'
      puts "#{buckets[:unscouted].size} of #{gap_ids.size} untranslated measure(s) have no faithful translation yet:"
      buckets[:unscouted].each { |id| puts "  --gap-id '#{id}'" }
      puts ''
      puts 'Optional: spawn a gap-scout per measure (scripts/gap-scout.md) with the --gap-id above'
      puts "plus --workdir #{WORK} to persist a translation; or re-run with --yes to accept the"
      puts 'degradation defaults. These also appear in OPEN QUESTIONS below.'
      puts '---------------------------------------------------------------'
    end
  else
    puts "   gap-scout: all #{gap_ids.size} untranslated measure(s) accounted for (validated or escalated)"
  end
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'app' => app_name,
    'phases_completed' => ['1 Discover', '2 Convert'],
    'note' => 'Deterministic mechanical steps (reconcile, denorm SQL, POST, layout, parity) are NOT asked about. ' \
              "Re-run with --yes to accept all defaults, or --answers '{\"<id>\":\"<choice>\"}' to override.",
    'open_questions' => questions
  }
  puts
  puts '==================== OPEN QUESTIONS ===================='
  puts JSON.pretty_generate(block)
  puts '======================================================='
  puts
  puts "#{questions.size} decision(s) need a human. No Sigma objects were created."
  if snap_lane && !lane_done?(snap_lane)
    puts '   (waiting for the background engine-snapshot lane so the discovery dir is complete'
    puts "    — re-run with --from-discovery #{WORK} to skip re-discovery)"
    join_lane(snap_lane, 'snapshot', timeout: 300)
  end
  phase_summary
  exit 10
end

if questions.any?
  puts
  puts "   decisions auto-resolved (#{opts[:yes] ? '--yes: defaults' : '--answers supplied'}):"
  questions.each do |q|
    chosen = (answers && answers[q['id']]) || q['default']
    label = q['measure'] || q['visual']
    puts "     - #{q['id']}#{label ? " [#{label}]" : ''}: #{chosen}"
  end
  questions.each do |q|
    chosen = (answers && answers[q['id']]) || q['default']
    if chosen.to_s.start_with?('abort')
      puts "   '#{q['id']}' answered abort — stopping before any Sigma object is created."
      join_lane(snap_lane, 'snapshot', timeout: 300) if snap_lane
      phase_summary
      exit 10
    end
  end
else
  puts '   no open questions — running straight through'
end

# ---------------------------------------------------------------------------
# Phase 3 — Build data model (reconcile → denorm SQL → build-sigma-dm.py)
# ---------------------------------------------------------------------------
hdr(3, TOTAL, 'Build data model')
reconcile = File.join(WORK, 'reconcile.json')
run!([*PyResolve.argv, File.join(HERE, 'reconcile-columns.py'),
      '--script', File.join(WORK, 'script.qvs'), '--out', reconcile])

# No Snowflake/warehouse credentials and no MCP are needed. In live mode the
# supplied Sigma connection is the catalog authority: browse its paths, resolve
# every source table, enumerate every column (paginated), and canonicalize the
# reconcile map before generating SQL or posting anything.
unless opts[:dry_run]
  require 'sigma_rest'
  Sigma.auth_token # child Python builders inherit the minted token through ENV
  resolved_reconcile = File.join(WORK, 'reconcile-resolved.json')
  run!(['ruby', File.join(HERE, 'preflight-warehouse.rb'),
        '--reconcile', reconcile, '--connection', opts[:conn],
        '--database', opts[:database], '--schema', opts[:schema],
        '--out', resolved_reconcile, '--report', File.join(WORK, 'warehouse-preflight.json')])
  reconcile = resolved_reconcile
else
  puts '   warehouse catalog preflight skipped (--dry-run: no Sigma API); live runs enforce it before POST'
end
denorm_out = File.join(WORK, 'denorm.json')
run!([*PyResolve.argv, File.join(HERE, 'gen-denorm-sql.py'),
      '--reconcile', reconcile, '--database', opts[:database], '--schema', opts[:schema],
      '--connection', opts[:conn], '--out', denorm_out])

# Resolve the reuse denorm element UP FRONT so an unsuitable reuse DM falls back
# to building fresh instead of binding the workbook to the wrong element. The
# Qlik workbook is built against ONE denormalized all-columns element — the
# custom-SQL element (build-sigma-dm.py names it so Sigma auto-labels it
# "Custom SQL"). A reused DM that lacks it (a star-shaped or non-Qlik-origin DM,
# even if it covers the same tables) has no safe single element to bind to, so we
# DON'T reuse it — `els.first` there would silently pick a dimension element.
reuse_denorm_eid = nil
reuse_star_count = 0
if opts[:reuse_dm] && !opts[:dry_run]
  require 'sigma_rest'
  els = (Sigma.request(:get, "/v2/dataModels/#{opts[:reuse_dm]}/elements")['entries'] rescue []) || []
  cs = els.find { |e| e['name'] == 'Custom SQL' }
  eid = cs && (cs['elementId'] || cs['id'])
  if eid
    reuse_denorm_eid = eid
    reuse_star_count = [els.size - 1, 0].max
  else
    puts "   WARNING: reuse DM #{opts[:reuse_dm]} has no 'Custom SQL' denorm element " \
         "(elements: #{els.map { |e| e['name'] }.compact.join(', ')}) — not a Qlik-shaped " \
         "DM; building a fresh DM instead"
    opts[:reuse_dm] = nil
  end
end

# Dry-compile the DM first. The resulting ids/spec are sufficient to compile and
# lint the workbook, so workbook buildability is proven BEFORE the first POST.
if reuse_denorm_eid
  candidate_dm_res = { 'dataModelId' => opts[:reuse_dm], 'denormElementId' => reuse_denorm_eid,
                       'folderId' => (opts[:folder] || prep[:folder_id]),
                       'starElements' => reuse_star_count, 'metricsKept' => nil,
                       'metricsDropped' => [], 'reused' => true }
else
  dm_base_cmd = [*PyResolve.argv, File.join(HERE, 'build-sigma-dm.py'),
                 '--converter-out', conv_out_path, '--reconcile', reconcile,
                 '--denorm', denorm_out, '--measures', File.join(WORK, 'measures.json'),
                 '--name', "#{base_name} (Qlik→Sigma)", '--spec-out', File.join(WORK, 'dm-spec.json')]
  if (fid = opts[:folder] || prep[:folder_id])
    dm_base_cmd += ['--folder', fid]
  end
  run!(dm_base_cmd + ['--out', File.join(WORK, 'dm-preflight-result.json'), '--dry-run'])
  candidate_dm_res = JSON.parse(File.read(File.join(WORK, 'dm-preflight-result.json')))
end

pre_wb_cmd = [*PyResolve.argv, File.join(HERE, 'build-sigma-workbook.py'),
              '--charts', File.join(WORK, 'charts.json'), '--layout', File.join(WORK, 'layout.json'),
              '--denorm', denorm_out,
              '--dm-id', candidate_dm_res['dataModelId'] || 'PREWRITE-DM',
              '--denorm-element-id', candidate_dm_res['denormElementId'].to_s,
              '--name', "#{base_name} → Sigma",
              '--out', File.join(WORK, 'wb-preflight-result.json'),
              '--spec-out', File.join(WORK, 'wb-preflight-spec.json'),
              '--layout-out', File.join(WORK, 'layout-preflight.xml'),
              '--element-map', File.join(WORK, 'element-map-preflight.json'),
              '--control-scope-out', File.join(WORK, 'control-scope-preflight.json'),
              '--coverage-out', File.join(WORK, 'workbook-coverage.json'), '--dry-run']
pre_wb_cmd += ['--dm-spec', File.join(WORK, 'dm-spec.json')] unless reuse_denorm_eid
pre_wb_cmd += ['--folder', (opts[:folder] || candidate_dm_res['folderId'] || prep[:folder_id])] \
  if opts[:folder] || candidate_dm_res['folderId'] || prep[:folder_id]
run!(pre_wb_cmd)
run!(['ruby', File.join(HERE, 'lib', 'preflight_lint.rb'), File.join(WORK, 'wb-preflight-spec.json')])
run!(['ruby', File.join(HERE, 'lint-render-integrity.rb'),
      '--spec', File.join(WORK, 'wb-preflight-spec.json'),
      '--out', File.join(WORK, 'blank-risk-preflight.json')])
coverage = JSON.parse(File.read(File.join(WORK, 'workbook-coverage.json')))
puts "   ✓ pre-write source coverage: #{coverage['queryableElements']}/#{coverage['sourceVisuals']} " \
     'queryable visual(s); workbook lint clean — safe to write'

if reuse_denorm_eid
  dm_res = candidate_dm_res
  DM_ID = opts[:reuse_dm]
  puts "   REUSING DM #{DM_ID}  ·  denorm element 'Custom SQL' (#{reuse_denorm_eid})  — convert + POST skipped"
elsif opts[:dry_run]
  dm_res = candidate_dm_res
  FileUtils.cp(File.join(WORK, 'dm-preflight-result.json'), File.join(WORK, 'dm-result.json'))
  DM_ID = nil
else
  run!(dm_base_cmd + ['--out', File.join(WORK, 'dm-result.json')])
  dm_res = JSON.parse(File.read(File.join(WORK, 'dm-result.json')))
  DM_ID = dm_res['dataModelId']
end
puts "   dataModelId = #{DM_ID || '(dry-run)'}  denorm element #{dm_res['denormElementId']}  " \
     "#{dm_res['starElements']} star element(s), #{dm_res['metricsKept']} metric(s)" \
     "#{dm_res['metricsDropped'].to_a.any? ? "; dropped: #{dm_res['metricsDropped'].join(', ')}" : ''}"
mark('phase3-dm')

# ---------------------------------------------------------------------------
# Phase 4 — Build workbook (one Sigma page per Qlik sheet, from charts.json)
# ---------------------------------------------------------------------------
hdr(4, TOTAL, 'Build workbook')
wb_cmd = [*PyResolve.argv, File.join(HERE, 'build-sigma-workbook.py'),
          '--charts', File.join(WORK, 'charts.json'), '--layout', File.join(WORK, 'layout.json'),
          '--denorm', denorm_out,
          '--dm-id', DM_ID || 'DRY-RUN', '--denorm-element-id', dm_res['denormElementId'].to_s,
          '--name', "#{base_name} → Sigma",
          '--out', File.join(WORK, 'wb-result.json'), '--spec-out', File.join(WORK, 'wb-spec.json'),
          '--layout-out', File.join(WORK, 'layout.xml'),
          '--element-map', File.join(WORK, 'element-map.json')]
# Freshly-built DM only: hand the workbook builder the DM spec so measures whose
# inline aggregate matches a metric on the denorm element bind to [Metrics/<name>]
# (governed) instead of re-deriving inline. The reuse path writes no dm-spec.json,
# so measures stay inline there (unchanged) until a live metric-fetch exists.
wb_cmd += ['--dm-spec', File.join(WORK, 'dm-spec.json')] unless reuse_denorm_eid
wb_cmd += ['--folder', (opts[:folder] || dm_res['folderId'] || prep[:folder_id])] if opts[:folder] || dm_res['folderId'] || prep[:folder_id]
if opts[:dry_run]
  run!(wb_cmd + ['--dry-run'])
else
  # Compile the exact final wb-spec with real DM ids, then run the blank-risk
  # lint BEFORE the builder is allowed to POST it. The second invocation is
  # deterministic and posts the already-proven shape.
  run!(wb_cmd + ['--dry-run'])
end
run!(['ruby', File.join(HERE, 'lint-render-integrity.rb'),
      '--spec', File.join(WORK, 'wb-spec.json'),
      '--out', File.join(WORK, 'blank-risk-elements.json')])
run!(wb_cmd) unless opts[:dry_run]
wb_res = JSON.parse(File.read(File.join(WORK, 'wb-result.json')))
WB_ID = wb_res['workbookId']
emap  = JSON.parse(File.read(File.join(WORK, 'element-map.json')))
unless opts[:dry_run]
  File.open(File.join(WORK, 'posted-workbooks.jsonl'), 'a') do |file|
    file.puts(JSON.generate('id' => WB_ID, 'name' => "#{base_name} → Sigma"))
  end
  File.write(File.join(WORK, 'wb-ids.json'), JSON.pretty_generate('workbookId' => WB_ID))
end
puts "   workbookId = #{WB_ID || '(dry-run)'}  (#{wb_res['pages']} page(s), #{wb_res['elements']} element(s), " \
     "#{wb_res['queryableElements']} queryable, #{wb_res['kpis']} KPI(s), #{wb_res['controls'] || 0} control(s))"
puts "   control scope contract -> #{wb_res['controlScope']}" if (wb_res['controls'] || 0) > 0
mark('phase4-wb')

# ---------------------------------------------------------------------------
# Phase 5 — Layout (the Qlik sheet cell grids, mapped onto Sigma's 24-col grid)
# ---------------------------------------------------------------------------
hdr(5, TOTAL, 'Layout')
if opts[:dry_run]
  puts "   DRY RUN: layout XML -> #{File.join(WORK, 'layout.xml')} (from #{sheets.size} Qlik sheet grid(s))"
else
  run!(['ruby', File.join(HERE, 'vendor', 'put-layout.rb'),
        '--workbook', WB_ID, '--layout', File.join(WORK, 'layout.xml')])
  puts "   layout applied (#{sheets.size} Qlik sheet grid(s) → 24-col Sigma grid, row-scale ≥2)"
end
mark('phase5-layout')

# ---------------------------------------------------------------------------
# Phase 5b — Visual QA: render each content page to a FULL-PAGE PNG so the
# layout can be reviewed against refs/layout-visual-qa.md AND compared to the
# source Qlik sheet capture (scripts/qlik-screenshot.py) — matching the other
# migration skills' visual-QA gate. Render is non-fatal (a transient export
# failure must not sink a green migration); the REVIEW is the gate.
# ---------------------------------------------------------------------------
render_png = nil
unless opts[:dry_run]
  vqa = File.join(WORK, 'visual-qa'); FileUtils.mkdir_p(vqa)
  # Page ids come from the LOCAL spec the builder wrote — deterministic. (The
  # live GET /spec readback proved flaky inside the pipeline, silently yielding
  # zero pages; POST preserves these ids so the local copy is authoritative.)
  wbspec = (JSON.parse(File.read(File.join(WORK, 'wb-spec.json'))) rescue {})
  wbdoc = Sigma::CodeRep.document(wbspec)
  content_pages = (wbdoc['pages'] || []).reject { |p| p['id'].to_s.downcase.include?('data') }
  tok = (Sigma.auth_token rescue ENV['SIGMA_API_TOKEN'])
  pngs = []
  content_pages.each do |pg|
    out = File.join(vqa, "#{pg['id']}.png")
    _o, st = Open3.capture2e({ 'SIGMA_API_TOKEN' => tok.to_s }, *PyResolve.argv,
                             File.join(HERE, 'sigma-export-png.py'),
                             '--workbook', WB_ID, '--page', pg['id'], '--out', out, '--w', '1800', '--h', '1000')
    if st.success?
      pngs << out
      render_png ||= out
    else
      puts "   [warn] visual-QA render failed for page #{pg['id']}"
    end
  end
  puts "   ✓ rendered #{pngs.size}/#{content_pages.size} full-page PNG(s) for visual QA → #{vqa}"
  if pngs.any?
    puts '   VISUAL QA (mandatory review — do not skip): open each PNG and check vs'
    if opts[:prj]
      # QlikView has no capture API — the source reference is a USER-PROVIDED screenshot
      # per sheet (landed by the qlik-prj-discover assist). Armed if present, else WAIVED.
      dash = File.join(WORK, 'dashboards')
      shots = Dir[File.join(dash, '*.{png,jpg,jpeg,PNG,JPG,JPEG}')]
      if shots.any?
        puts "   refs/layout-visual-qa.md AND the #{shots.size} user-provided QlikView screenshot(s) in"
        puts "   #{dash} (QlikView has no capture API) — right chart kinds, titles, populated data,"
        puts '   sensible colors/heights, no overlaps/dead zones. Transcribe source-anchor values from'
        puts '   those screenshots (Phase 1d) so verify-anchors + visual-similarity arm.'
      else
        puts '   refs/layout-visual-qa.md ONLY. No source screenshots were provided for this QlikView'
        puts "   app (drop one PNG per sheet in #{dash} to arm the source-side gates) — the source-anchor"
        puts '   / visual-compare / visual-similarity gates are WAIVED; STATE that waiver + reason in the'
        puts '   Phase-6 report (never a silent skip).'
      end
    else
      puts '   refs/layout-visual-qa.md AND the source Qlik sheet capture — populated controls,'
      puts '   titles present, right chart kinds, sensible colors/heights, no overlaps/dead zones.'
    end
  end
end
mark('phase5b-visual-qa')

# ---------------------------------------------------------------------------
# Phase 6 — Parity (freshness banner FIRST, then columns + values + buckets)
# ---------------------------------------------------------------------------
hdr(6, TOTAL, 'Parity')
# Join the engine-snapshot lane (started at Phase 1, ran under Phases 2-5).
# The freshness banner + bucket parity below consume it; in-memory totals
# can't have changed (no reload happens anywhere in this pipeline).
if snap_lane
  join_lane(snap_lane, 'snapshot', timeout: 300)
  PHASE_T['snapshot-lane(bg)'] = (snap_lane[:ended] - snap_lane[:started])
  if snap_lane[:status].success?
    snapshot = (JSON.parse(File.read(File.join(WORK, 'snapshot.json'))) rescue {})
    puts "   engine-snapshot lane joined (#{(snap_lane[:ended] - snap_lane[:started]).round(1)}s, " \
         "ran under Phases 2-5): #{(snapshot['kpis'] || []).size} KPI(s), " \
         "#{(snapshot['buckets'] || []).size} bucket count(s)"
  else
    print_lane_log(snap_lane)
    puts '   snapshot lane FAILED — falling back to live engine evals below'
  end
end
if opts[:dry_run]
  puts '   DRY RUN: skipping live parity. Artifacts:'
  %w[dm-spec.json wb-spec.json layout.xml element-map.json].each { |f| puts "     #{File.join(WORK, f)}" }
  puts
  puts '================ RESULT (dry run) ================'
  puts "specs       : #{WORK}"
  puts '=================================================='
  phase_summary
  exit 0
end

require 'sigma_rest'

# 6a — column resolution guard
cols = Sigma.request(:get, "/v2/workbooks/#{WB_ID}/columns") rescue { 'entries' => [] }
entries = cols['entries'] || []
err_cols = entries.select { |c| c.dig('type', 'type') == 'error' }
puts "   columns: #{entries.size - err_cols.size}/#{entries.size} resolve" \
     "#{err_cols.any? ? " — #{err_cols.size} ERROR-typed:" : ''}"
err_cols.first(8).each { |c| puts "     [#{c['elementId']}] #{c['label']}: #{c['formula']}" }

# 6b — kick off CSV exports for every mapped element (parallel POST, then poll)
exports = emap.map do |e|
  res = (Sigma.request(:post, "/v2/workbooks/#{WB_ID}/export",
                       body: { elementId: e['elementId'], format: { type: 'csv' } }.to_json) rescue {})
  e.merge('queryId' => res['queryId'])
end
csv_for = {}
deadline = Time.now + 240
exports.each do |e|
  next unless e['queryId']
  loop do
    body = (Sigma.request(:get, "/v2/query/#{e['queryId']}/download", accept: 'text/csv') rescue nil)
    if body && !body.to_s.empty?
      csv_for[e['elementId']] = body
      break
    end
    break if Time.now > deadline
    sleep 2
  end
end

def csv_rows(body)
  body.to_s.split("\n").drop(1).reject(&:empty?)
end

# 6c — SOURCE-FRESHNESS BANNER (leads the parity handoff — before any side-by-side)
kpi_lines = []
kpi_results = []
kpi_parity_rows = []
snapshot_kpis = (snapshot['kpis'] || []).to_h { |k| [k['expr'], k['value']] }
emap.select { |e| e['kind'] == 'kpi-chart' }.each do |e|
  expr = e['qlik']['measures'].first
  qval = snapshot_kpis[expr]
  qval = qlik_eval(opts[:app], opts[:context], expr) if qval.nil? && opts[:app]
  srow = csv_rows(csv_for[e['elementId']]).first
  sval = srow && srow.split(',').first
  qn, sn = numish(qval), numish(sval)
  # the CSV export prints a format-rounded value (e.g. percent KPIs at 5
  # decimals): a Qlik value that rounds to EXACTLY the printed Sigma value is a
  # MATCH, not a divergence -- compare at the precision the export carries
  printed_dp = sval.to_s.gsub(/[$,%\s]/, '')[/\A-?\d+\.(\d+)\z/, 1]&.length
  rounded_match = (qn && sn && printed_dp && (qn.round(printed_dp) - sn).abs <= 1e-9) ||
                  display_match?(qval, sn)
  qn ||= sn if display_match?(qval, sn)
  status = if qn && sn && ((qn - sn).abs <= [qn.abs, sn.abs].max * 1e-6 + 1e-9 || rounded_match)
             'MATCH'
           elsif qn && sn && stale_days && stale_days >= 1
             'STALE-EXPLAINED'
           else
             'DIVERGENT'
           end
  kpi_results << status
  kpi_parity_rows << {
    'chart' => e['name'].to_s,
    'source_object_id' => e.dig('qlik', 'objectId'),
    'kind' => e['kind'],
    'qlik_value' => qval,
    'sigma_value' => sval,
    'status' => status,
    'pass' => status == 'MATCH'
  }
  kpi_lines << format('     %-28s Qlik %-18s warehouse %-18s %s',
                      e['name'].to_s[0, 27], qval.to_s[0, 17], sval.to_s[0, 17], status)
end

puts
puts '   ── SOURCE FRESHNESS (read this before any side-by-side) ──'
if stale_days && stale_days >= 1 && kpi_results.include?('STALE-EXPLAINED')
  puts "   ⚠ Qlik is ~#{stale_days.ceil} day(s) stale (last reload #{app_meta['lastReloadTime']})."
  puts '     Sigma queries the live warehouse and WILL show more data than the Qlik app:'
elsif stale_days
  puts "   Qlik last reloaded #{app_meta['lastReloadTime']} (#{stale_days} days ago)."
end
kpi_lines.each { |l| puts l }
# max-date evidence: the app's in-memory Max(date field) captured at discovery
(snapshot['maxDates'] || []).each do |md|
  puts "     Qlik in-memory Max(#{md['field']}) = #{md['value']}"
end
if kpi_results.include?('STALE-EXPLAINED')
  puts '     → These deltas are EXPLAINED by the stale Qlik snapshot, not a conversion error.'
  puts '       Option: reload the Qlik app and re-run parity for an exact side-by-side.'
end

# 6d — per-chart BUCKET-COUNT parity vs the Qlik engine (gl37): a suppressed/extra
# null bucket shows up as a row-count delta even when every shared cell matches.
puts
puts '   ── BUCKET COUNTS (per chart, Sigma rows vs Qlik engine) ──'
bucket_warns = 0
bucket_parity_rows = []
# Bucket counts were precomputed by the snapshot lane (same expr strings —
# see qlik-discover.py bucket_expr); live eval is only the fallback.
snapshot_buckets = (snapshot['buckets'] || []).to_h { |b| [b['expr'], b['value']] }
emap.reject { |e| e['kind'] == 'kpi-chart' }.each do |e|
  dims = e['qlik']['dims']
  next if dims.empty?
  expr = dims.size == 1 ? "Count(distinct [#{dims[0]}])" :
           "Count(distinct #{dims.map { |d| "[#{d}]" }.join("&'|'&")})"
  qraw = snapshot_buckets[expr]
  qraw = qlik_eval(opts[:app], opts[:context], expr) if qraw.nil? && opts[:app]
  qcount = numish(qraw)&.to_i
  scount = csv_for[e['elementId']] ? csv_rows(csv_for[e['elementId']]).size : nil
  status = if qcount && scount && qcount == scount
             'MATCH'
           elsif qcount.nil? || scount.nil?
             'NO-DATA'
           else
             bucket_warns += 1
             'MISMATCH (check: null-bucket suppression / dim values without facts / staleness)'
           end
  bucket_parity_rows << {
    'chart' => e['name'].to_s,
    'source_object_id' => e.dig('qlik', 'objectId'),
    'kind' => e['kind'],
    'qlik_buckets' => qcount,
    'sigma_buckets' => scount,
    'status' => status,
    'pass' => status == 'MATCH'
  }
  puts format('     %-34s Qlik %-6s Sigma %-6s %s', e['name'].to_s[0, 33], qcount.inspect, scount.inspect, status)
end

divergent = kpi_results.count('DIVERGENT')
chart_parity_rows = kpi_parity_rows + bucket_parity_rows
parity_fail_rows = chart_parity_rows.reject { |row| row['pass'] }
# Strict completion means source and Sigma match now. Stale-explained and
# NO-DATA remain useful diagnostics, but they are not passing parity.
parity_ok = err_cols.empty? && entries.size.positive? && chart_parity_rows.any? &&
            parity_fail_rows.empty?

# Materialize the shared gate's parity contract from the measurements above.
# Names are required: a RED result must identify every chart that failed rather
# than collapse into a workbook-level boolean.
source_visual_ids = Array(coverage['sourceVisualIds']).map(&:to_s)
built_visual_ids = Array(coverage['builtSourceVisualIds']).map(&:to_s)
chart_name_by_id = charts.each_with_object({}) do |chart, out|
  out[chart['id'].to_s] = (chart['title'] || chart['id']).to_s if chart.is_a?(Hash)
end
unmatched_ids = source_visual_ids - built_visual_ids
parity_final = {
  'schema_version' => 1,
  'source' => 'qlik',
  'status' => parity_ok ? 'PASS' : 'FAIL',
  'strict' => true,
  'mode' => 'live-engine',
  'verified_against' => 'qlik-engine',
  'charts_total' => chart_parity_rows.length,
  'charts_pass' => chart_parity_rows.count { |row| row['pass'] },
  'charts_fail' => parity_fail_rows.length,
  'charts_stale_explained' => chart_parity_rows.count { |row| row['status'] == 'STALE-EXPLAINED' },
  'fail_names' => parity_fail_rows.map { |row| row['chart'] }.uniq.sort,
  'pending_names' => [],
  'divergent' => parity_fail_rows.any?,
  'per_chart' => chart_parity_rows,
  'column_errors' => err_cols.map do |column|
    { 'element_id' => column['elementId'], 'label' => column['label'], 'formula' => column['formula'] }
  end,
  'tile_census' => {
    'zones_total' => source_visual_ids.length,
    'charts_built' => built_visual_ids.length,
    'zones_unmatched' => unmatched_ids.length,
    'unmatched_zone_names' => unmatched_ids.map { |id| chart_name_by_id[id] || id }.sort
  },
  'generated_at' => Time.now.utc.iso8601
}
File.write(File.join(WORK, 'parity-final.json'), JSON.pretty_generate(parity_final))

# 6e — control-wiring lint, gate 7 (scripts/lib/control_lint.rb, shared —
# vendored byte-identical across the migration plugins). Lints the LIVE spec
# readback against the control-scope.json sidecar the workbook builder
# emitted: dead controls, ghost targets, partial same-page reach, mustReach
# (Qlik global-scope assertions over every chart on every page), and the
# source-signal coverage check (filterpanes/listboxes in the app but zero
# controls in the spec = the silently-dropped class this gate exists to
# kill). RED here blocks GREEN exactly like a parity failure.
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'layout_lint'
require 'control_lint'
live = Sigma.request(:get, "/v2/workbooks/#{WB_ID}/spec") rescue {}
# Workbook code-rep GETs nest the complete document under `document`.
# Preserve that document intact; both lints use CodeRep's flat-element/layout
# helpers directly and no longer infer ownership from pages[].elements.
live_spec = live.is_a?(Hash) ? Sigma::CodeRep.metadata(live).merge(Sigma::CodeRep.document(live)) : {}

# 6d — layout-quality lint, gate 6 (scripts/lib/layout_lint.rb, shared —
# vendored byte-identical across the migration plugins). Flags raw-id element
# display names, controls orphaned outside containers on a banded page, and
# generic Sigma auto-page titles in the header band. RED here blocks GREEN like
# a parity or control failure. --skip-layout-lint bypasses. Verified clean
# against shipped Qlik migrations (Retail Orders, Exec Overview, Shipping Perf).
puts
puts '   ── LAYOUT LINT (gate 6: titles / orphan controls / header band) ──'
if opts[:skip_layout_lint]
  puts '     [SKIP] --skip-layout-lint'
  layout_ok = true
else
  layout_violations = LayoutLint.lint(live_spec)
  if layout_violations.empty?
    puts '     [OK] layout lint clean'
  else
    puts "     [FAIL] #{layout_violations.size} layout-lint violation(s):"
    layout_violations.each { |v| puts "       - #{v}" }
  end
  layout_ok = layout_violations.empty?
end

puts
puts '   ── CONTROL LINT (gate 7: every filterpane/listbox a WORKING control) ──'
ctl_scope = (JSON.parse(File.read(File.join(WORK, 'control-scope.json'))) rescue nil)
ctl_violations = ControlLint.lint(live_spec, scope: ctl_scope)
ctl_rows = ControlLint.controls_report(live_spec)
if ctl_violations.empty?
  puts "     [OK] control lint clean — #{ctl_rows.size} control(s), " \
       "#{(ctl_scope || {})['sourceFilterSignals'].to_i} source filter signal(s), " \
       "#{((ctl_scope || {})['unbound'] || []).size} unbound (reasons in control-scope.json)"
else
  puts "     [FAIL] #{ctl_violations.size} control-lint violation(s):"
  ctl_violations.each { |v| puts "       - #{v}" }
end
control_ok = ctl_violations.empty?

# 7b — runtime control-flip proof (gate 7b). Gate 7 proves control WIRING, but a
# builder listen->column mis-map can lint clean yet do NOTHING at runtime. Flip
# each control live via probe-controls.rb and FAIL (RED) if a control is INERT —
# the only independent proof the wiring works. DEFAULT-ON; --skip-control-flip
# "<reason>" waives; offline/dry-run/0-controls SKIP (never hard-fail a run that
# never reached the live API). Mirrors the powerbi Phase 6b + the shared gate 7b.
puts
puts '   ── CONTROL FLIP (gate 7b: each control actually FILTERS at runtime) ──'
require 'flip_gate'
flip_ok = true
_flip_tok = (Sigma.auth_token rescue ENV['SIGMA_API_TOKEN'])
if opts[:skip_control_flip]
  puts "     [WAIVED] #{opts[:skip_control_flip] == true ? '(no reason given)' : opts[:skip_control_flip]} (name it in your report)"
elsif ctl_rows.empty?
  puts '     [OK] no controls — nothing to flip-test'
elsif ENV['SIGMA_BASE_URL'].to_s.empty? || _flip_tok.to_s.empty?
  puts '     [SKIP] offline (no SIGMA creds) — runtime flip UNVERIFIED'
else
  _probe_out = File.join(WORK, 'probe-controls')
  system('ruby', File.join(HERE, 'probe-controls.rb'), '--workbook-id', WB_ID, '--out', _probe_out)
  _probe_rc = $?.exitstatus
  _results = (JSON.parse(File.read(File.join(_probe_out, 'probe-results.json'))) rescue nil)
  _decision, _info = FlipGate.decide(_probe_rc, _results)
  case _decision
  when :ok
    puts "     [OK] #{_info[:passes].length} control(s) proven live" \
         "#{_info[:skips].any? ? "; #{_info[:skips].length} un-probeable skipped" : ''}"
  when :fail
    puts "     [FAIL] #{_info[:fails].length} control(s) wired but INERT on workbook #{WB_ID}:"
    _info[:fails].each { |cid, note| puts "       - #{cid}: #{note}" }
    puts '       Static lint clean (gate 7) but does not filter — a builder listen->column'
    puts '       mis-map. Fix the build, or waive with --skip-control-flip "<reason>".'
    flip_ok = false
  when :advisory
    puts "     [WARN] no control auto-probeable (#{_info[:skips].length} date/slider/unlabeled) — runtime wiring UNVERIFIED"
  when :error
    puts '     [FAIL] probe-controls.rb could not verify the wiring — an enforced gate must not pass silently.'
    puts '       Re-run once the export API is reachable, or waive with --skip-control-flip "<reason>".'
    flip_ok = false
  end
end
mark('phase6-parity')

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts
puts '================ RESULT ================'
puts "dataModelId : #{DM_ID}"
puts "workbookId  : #{WB_ID}"
puts "PARITY      : #{parity_ok ? 'GREEN' : 'RED'} — #{entries.size} cols resolve (#{err_cols.size} error), " \
     "KPIs: #{kpi_results.count('MATCH')} match / #{kpi_results.count('STALE-EXPLAINED')} stale-explained / #{divergent} divergent, " \
     "#{bucket_warns} bucket warning(s)"
puts "LAYOUT      : #{layout_ok ? 'GREEN' : 'RED'} — gate 6 layout lint" \
     "#{(defined?(layout_violations) && layout_violations && layout_violations.any?) ? ", #{layout_violations.size} violation(s)" : (opts[:skip_layout_lint] ? ' (skipped)' : '')}"
puts "CONTROLS    : #{control_ok ? 'GREEN' : 'RED'} — gate 7 control lint, #{ctl_rows.size} control(s) checked" \
     "#{ctl_violations.any? ? ", #{ctl_violations.size} violation(s)" : ''}"
puts "CONTROL-FLIP: #{flip_ok ? 'GREEN' : 'RED'} — gate 7b runtime flip proof#{opts[:skip_control_flip] ? ' (waived)' : ''}"
puts "freshness   : Qlik last reload #{app_meta['lastReloadTime'] || '?'} (#{stale_days} days ago)" if stale_days
puts "warnings    : #{conv_warnings.size} converter, #{(wb_res['warnings'] || []).size} workbook-build" if conv_warnings.any? || (wb_res['warnings'] || []).any?
# Empty-workbook guard. Completion is minted only by the shared hard gate below;
# the orchestrator must never hand-write phase6-success.json.
n_elements = wb_res['elements'].to_i
n_queryable = wb_res['queryableElements'].to_i
mechanical_ok = parity_ok && layout_ok && control_ok && flip_ok &&
                n_queryable.positive? && wb_res['unbuiltSourceVisuals'].to_a.empty?
puts 'ELEMENTS    : 0 queryable workbook elements built — Data-only workbook, NOT done.' if n_queryable.zero?

run_terminal = lambda do |label, command|
  puts
  puts "── #{label} ──"
  output, status = Open3.capture2e(*command)
  output.each_line { |line| puts "   #{line.rstrip}" } unless output.strip.empty?
  puts "   exit=#{status.exitstatus}"
  status.success?
end

# Cleanup is a real gate input, not best-effort bookkeeping. It runs on both
# GREEN and RED parity paths so a failed migration does not leave retry
# workbooks behind.
cleanup_ok = run_terminal.call(
  'Orphan workbook cleanup',
  ['ruby', File.join(HERE, 'cleanup-orphan-workbooks.rb'),
   '--workdir', WORK, '--keep', WB_ID]
)

finalizer_cmd = [*PyResolve.argv, File.join(HERE, 'finalize-qlik-report.py'),
                 '--workdir', WORK]
if opts[:skip_visual_comparison]
  # Qlik reporting exports objects, not whole sheets. This waiver covers the
  # unavailable full-page source capture only; every object capture that does
  # exist is still health-checked by the finalizer.
  finalizer_cmd += ['--skip-source-pages', opts[:skip_visual_comparison]]
end
finalizer_cmd += ['--skip-visual-similarity', opts[:skip_visual_similarity]] \
  if opts[:skip_visual_similarity]

# The first pass materializes accounting/coverage/layout/PNG/similarity inputs
# consumed by the shared assert. It intentionally runs even when parity is RED.
pre_finalizer_ok = run_terminal.call('Qlik accounting and report finalization (pre-gate)',
                                     finalizer_cmd)

assert_cmd = ['ruby', File.join(HERE, 'assert-phase6-ran.rb'),
              '--workdir', WORK, '--workbook-id', WB_ID,
              '--control-scope', File.join(WORK, 'control-scope.json'),
              '--require-control-flip']
assert_cmd += ['--sigma-render', render_png] if render_png
assert_cmd += ['--skip-control-flip',
               opts[:skip_control_flip] == true ? 'explicit migrate-qlik --skip-control-flip' :
                                                  opts[:skip_control_flip].to_s] \
  if opts[:skip_control_flip]
assert_cmd += ['--skip-layout-lint', 'explicit migrate-qlik --skip-layout-lint'] \
  if opts[:skip_layout_lint]
assert_cmd += ['--skip-visual-comparison', opts[:skip_visual_comparison]] \
  if opts[:skip_visual_comparison]
assert_cmd += ['--skip-visual-similarity', opts[:skip_visual_similarity]] \
  if opts[:skip_visual_similarity]
assert_cmd += ['--skip-anchors-gate', opts[:skip_anchors_gate]] \
  if opts[:skip_anchors_gate]

# This is the only command allowed to stamp phase6-success.json. Its exit code
# participates directly in built_ok.
assert_ok = run_terminal.call('Shared Phase 6 hard gate', assert_cmd)

# assert-phase6-ran stamps the final waiver census, verdict, and degradation
# ledger. Re-run the accounting/report finalizer after it on BOTH terminal paths
# so migration-result.json and the report exactly reflect the terminal state.
post_finalizer_ok = run_terminal.call('Qlik accounting and report finalization (terminal)',
                                      finalizer_cmd)

built_ok = mechanical_ok && cleanup_ok && pre_finalizer_ok && assert_ok &&
           post_finalizer_ok
puts "TERMINAL    : #{built_ok ? 'GREEN' : 'RED'} — accounting/report " \
     "#{post_finalizer_ok ? 'current' : 'failed'}, shared assert " \
     "#{assert_ok ? 'passed' : 'failed'}"
puts '======================================='
phase_summary
exit(built_ok ? 0 : 3)
