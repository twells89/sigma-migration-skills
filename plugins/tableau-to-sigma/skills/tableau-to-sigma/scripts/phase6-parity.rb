#!/usr/bin/env ruby
# Phase 6 (MANDATORY) — verify Sigma chart values match Tableau view CSVs.
#
# Two-pass workflow because Sigma's REST API doesn't expose a synchronous
# chart-data endpoint (filed as a separate Sigma API gap ticket). The skill
# uses the MCP V2 query tool to fetch actuals, then the script verifies.
#
# PASS 1 — emit the parity plan + per-chart MCP query instructions:
#
#   ruby scripts/phase6-parity.rb --tableau /tmp/<name> --workbook-id <wb>
#     [--rename "Tableau name=Sigma name" ...]
#     [--extract-mode] [--extract-tol 0.30]
#
#   Writes /tmp/<name>/parity-plan.json (with sigma_sql per chart)
#   Prints exact mcp__sigma-mcp-v2__query calls the agent should run, one
#   per chart, then re-invoke this script with --finalize.
#
# PASS 2 — finalize with the actuals the agent collected:
#
#   ruby scripts/phase6-parity.rb --tableau /tmp/<name> --finalize \
#     --actuals /tmp/<name>/parity-actuals.json
#     [--extract-mode] [--extract-tol 0.30]
#
#   actuals.json shape:
#     { "<Sigma chart name>": [[dim, val], [dim, val], ...], ... }
#
#   Runs verify-parity.rb, prints pass/fail summary, writes parity-final.json.

require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require 'base64'
require 'open3'
require 'time'
require_relative 'lib/zone_census'

opts = { extract_mode: false, extract_tol: 0.30, renames: [], finalize: false }
OptionParser.new do |p|
  p.on('--tableau DIR')          { |v| opts[:tab] = v }
  p.on('--workdir DIR', 'alias of --tableau') { |v| opts[:tab] = v }
  p.on('--workbook-id ID')       { |v| opts[:wb] = v }
  p.on('--out PATH')             { |v| opts[:out] = v }
  p.on('--extract-mode')         { opts[:extract_mode] = true }
  p.on('--extract-tol F', Float) { |v| opts[:extract_tol] = v }
  p.on('--rename PAIR', 'Tableau-name=Sigma-name (repeat)') { |v| opts[:renames] << v }
  p.on('--dashboard-layout PATH', 'parse-twb-layout output for the tile census (default <tableau-dir>/dashboard-layout.json)') { |v| opts[:dash_layout] = v }
  p.on('--coverage PATH', 'build-charts coverage.json for the tier-coverage report (default <tableau-dir>/coverage.json)') { |v| opts[:coverage] = v }
  # Per-dashboard parity scoping: scope parity checks to only tiles on the
  # named dashboard (case-insensitive exact or unique substring). Repeatable.
  # Threaded through to auto-parity-plan.rb's --dashboard flag so both the
  # plan and the gate operate on the same scoped tile set.
  p.on('--dashboard NAME', 'Scope parity checks to tiles on this dashboard only (exact or substring). Repeatable.') { |v| (opts[:dashboards] ||= []) << v }
  p.on('--finalize')             { opts[:finalize] = true }
  p.on('--regen-plan', 'PASS 1: force-rebuild parity-plan.json even if one exists (default: REUSE an existing plan so operator waives/edits survive a re-run)') { opts[:regen_plan] = true }
  p.on('--actuals PATH', 'JSON: { "<chart name>": [[dim, val], ...] } — for --finalize') { |v| opts[:actuals] = v }
end.parse!
abort('missing --tableau') unless opts[:tab]
opts[:out] ||= File.join(opts[:tab], 'parity-final.txt')

if opts[:finalize]
  abort('--actuals required with --finalize') unless opts[:actuals]
else
  abort('--workbook-id required for pass 1') unless opts[:wb]
end

BASE = ENV.fetch('SIGMA_BASE_URL')
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'code_rep'

# Sigma.request handles initial token fetch + 401-retry-with-refresh
# transparently. Phase 6 is the longest pass in the pipeline; tokens
# routinely expire mid-run on big workbooks.
def http_json(path)
  Sigma.request(:get, path)
end

plan_path = File.join(opts[:tab], 'parity-plan.json')

# Finalize does NOT rebuild the plan (that would divorce it from the actuals just
# collected), but a plan built against OLDER CSVs carries stale `expected` values
# → a false FAIL. Warn loudly so it isn't mistaken for a real divergence.
if opts[:finalize] && File.exist?(plan_path)
  built = (JSON.parse(File.read(plan_path))['source_csv_max_mtime'] rescue nil) || File.mtime(plan_path).to_i
  newest = Dir.glob(File.join(opts[:tab], 'views', '*.csv')).map { |f| File.mtime(f).to_i }.max || 0
  if newest > built
    warn '⚠️  Phase 6 finalize: parity-plan.json is STALE (view CSVs are newer than the plan it was built from). ' \
         'Expected values may be from OLD data — a FAIL here can be a false alarm. Re-run PASS 1 with --regen-plan, then re-collect actuals.'
  end
end

if !opts[:finalize]
  # PASS 1 — build plan + emit per-chart MCP instructions
  warn "Phase 6 PASS 1: reading workbook spec #{opts[:wb]}"
  raw_spec = http_json("/v2/workbooks/#{opts[:wb]}/spec")
  # Live GET now nests non-metadata fields under `document` (verified 2026-08-03/04);
  # unwrap so wb-readback.json keeps the flat {pages:[...]} shape downstream
  # scripts (auto-parity-plan.rb, verify-anchors.rb, ...) already expect on disk.
  spec = Sigma::CodeRep.document(raw_spec)
  File.write(File.join(opts[:tab], 'wb-readback.json'), JSON.pretty_generate(spec))

  # Idempotence guard: if a parity plan already exists, REUSE it (unless
  # --regen-plan). auto-parity-plan.rb rewrites the plan from scratch, which
  # DESTROYS operator edits — hidden_filter `status: waived` + `waive_reason`,
  # hand-corrected `expected` rows, `extract` waivers — every time PASS 1 is
  # re-run (and the top-level orchestrator re-runs PASS 1 on every invocation).
  # That turned finalize into an unwinnable fight (edits wiped before the
  # actuals step). Reusing preserves those edits; --regen-plan forces a rebuild
  # (use after a workbook re-POST changes element ids).
  # Staleness guard (bead: stale-parity-plan): reuse preserves operator edits,
  # but a plan built against OLDER discovery CSVs carries stale `expected` values
  # → a false FAIL at finalize (the current data matches Sigma, not the plan).
  # If the view CSVs are newer than the data this plan was built from, rebuild.
  plan_stale = false
  if File.exist?(plan_path) && !opts[:regen_plan]
    built_mtime = (JSON.parse(File.read(plan_path))['source_csv_max_mtime'] rescue nil) ||
                  File.mtime(plan_path).to_i
    csv_mtime = Dir.glob(File.join(opts[:tab], 'views', '*.csv'))
                   .map { |f| File.mtime(f).to_i }.max || 0
    plan_stale = csv_mtime > built_mtime
  end
  if File.exist?(plan_path) && !opts[:regen_plan] && !plan_stale
    warn "Phase 6 PASS 1: REUSING existing #{plan_path} (operator waives/edits preserved; pass --regen-plan to rebuild from scratch)"
  else
    warn 'Phase 6 PASS 1: existing plan is STALE — view CSVs are newer than the data it was built from; REBUILDING so expected values match current data (prior operator edits on this plan are discarded — the source data changed underneath them).' if plan_stale
    warn "Phase 6 PASS 1: building parity plan"
    plan_args = ['ruby', File.join(__dir__, 'auto-parity-plan.rb'),
                 '--tableau', opts[:tab],
                 '--workbook-spec', File.join(opts[:tab], 'wb-readback.json'),
                 '--out', plan_path]
    opts[:renames].each { |r| plan_args.concat(['--rename', r]) }
    # Thread --dashboard scoping through to the parity plan so both the chart
    # matching and the hidden_filters gate operate on the same tile set.
    (opts[:dashboards] || []).each { |d| plan_args.concat(['--dashboard', d]) }
    out, err, status = Open3.capture3(*plan_args)
    warn out unless out.empty?
    warn err unless err.empty?
    abort('auto-parity-plan failed') unless status.success?
  end

  plan = JSON.parse(File.read(plan_path))
  # Persist the census/plan dashboard scope so PASS-2/finalize (which may run
  # without --dashboard flags) scopes the tile census identically (gate-5 fix).
  if (opts[:dashboards] || []).any? && plan["dashboards_scope"] != opts[:dashboards]
    plan["dashboards_scope"] = opts[:dashboards]
    File.write(plan_path, JSON.pretty_generate(plan))
  end

  # ---- Hidden calc-filter gate (Phase 6 enforcement) -----------------------
  # If the parity plan contains unresolved hidden calc-filters, Phase 6 must
  # refuse to proceed. Worksheet-level calc-field filters are invisible in CSV
  # exports; an unresolved filter means the Sigma source was NOT filtered to
  # match, so any parity comparison would be against a row-superset and could
  # silently PASS with wrong numbers. A real case dropped 248→52 rows.
  unresolved_hf = (plan['hidden_filters'] || []).reject do |hf|
    %w[translated waived].include?(hf['status'])
  end
  if unresolved_hf.any?
    warn ""
    warn "=" * 70
    warn "PHASE 6 BLOCKED — unresolved hidden worksheet calc-filter(s)"
    warn "=" * 70
    warn ""
    warn "The following worksheet-level filters target calculated fields and are"
    warn "invisible in Tableau CSV exports. They must be either:"
    warn "  translated — applied to the Sigma source so row counts match, OR"
    warn "  waived     — explicitly waived (set status: 'waived' + reason in"
    warn "               #{plan_path})"
    warn ""
    unresolved_hf.each_with_index do |hf, i|
      warn "  [#{i + 1}] tile=#{hf['tile'].inspect} calc_ref=#{hf['calc_ref'].inspect}" \
           " caption=#{hf['caption'].inspect} filter_type=#{hf['filter_type']}"
      if hf['members'] && !hf['members'].empty?
        warn "       members: #{hf['members'].inspect}"
      end
    end
    warn ""
    warn "To waive: open #{plan_path}, find each entry in hidden_filters, and"
    warn "set \"status\": \"waived\" + add \"waive_reason\": \"<your reason>\"."
    warn "Then re-run this script."
    warn ""
    abort("Phase 6 blocked: #{unresolved_hf.size} unresolved hidden calc-filter(s)")
  end

  # Pooled Sigma-side actuals collection (collect-parity-actuals.rb): the
  # element CSV export serves every chart kind except pivot-tables, N-wide,
  # under sigma_rest's auto-refresh. Only the genuinely agent-mediated charts
  # (pivot grids) are printed as MCP instructions below.
  actuals_path = File.join(opts[:tab], 'parity-actuals.json')
  t_collect = Time.now
  coll_out, coll_err, coll_st = Open3.capture3(
    'ruby', File.join(__dir__, 'collect-parity-actuals.rb'),
    '--plan', plan_path, '--workbook-id', opts[:wb],
    '--workbook-spec', File.join(opts[:tab], 'wb-readback.json'),
    '--out', actuals_path)
  puts coll_out unless coll_out.empty?
  warn coll_err unless coll_err.empty?
  if coll_st.exitstatus == 3
    warn 'collect-parity-actuals hit its --timeout total deadline — partial actuals recorded; ' \
         'uncollected charts fall back to agent-mediated MCP queries'
  elsif !coll_st.success?
    warn 'collect-parity-actuals failed — ALL charts fall back to agent-mediated MCP queries'
  end
  collected = (JSON.parse(File.read(actuals_path)) rescue {}) if File.exist?(actuals_path)
  collected ||= {}
  # A chart counts as collected only when it has real rows OR a render-verify
  # marker (the known pivot platform bug — resolved via render-read, not
  # re-query). too-large-for-export / timeout markers (issue #416) stay on the
  # agent-mediated list: the agent must supply those rows via mcp-v2 aggregate
  # queries or the warehouse oracle.
  remaining = plan['charts'].reject do |c|
    v = collected[c['chart']]
    usable = v.is_a?(Array) || (v.is_a?(Hash) && v['status'] == 'render-verify-required')
    usable && (c['sigma_columns'] || []).length >= 1
  end.select { |c| (c['sigma_columns'] || []).length >= 1 }
  warn format('parity collection: %d/%d chart(s) pooled in %.1fs; %d agent-mediated',
              collected.size, plan['charts'].size, Time.now - t_collect, remaining.size)

  # Emit per-chart MCP instructions for the REMAINDER only.
  puts ""
  puts "=" * 70
  puts "PHASE 6 PASS 1 OUTPUT — Sigma chart data fetch instructions"
  puts "=" * 70
  puts ""
  if remaining.empty?
    # remaining == [] means either everything collectible was collected, OR there
    # was nothing collectible (all plan charts are dashboard-embedded / signal-only,
    # 0 sigma_columns — the all-embedded case). NB: "collectible charts exist but 0
    # were collected" does NOT land here (those charts stay in `remaining`, routed to
    # the agent-query path below); that broken-data-path state is caught downstream
    # by verify-parity and the verify-anchors non-empty-chart gate.
    if collected.empty?
      # No exportable-view actuals at all: parity is legitimately deferred to the
      # anchors oracle — but chart emptiness is still gated downstream (verify-anchors).
      # Do NOT phrase this as "complete. No MCP queries needed." (the 2026-07 vacuous
      # success that helped a dataless workbook read as done).
      puts "No exportable-view actuals to collect (all charts dashboard-embedded / signal-only)."
      puts "#{actuals_path} is intentionally empty; value parity is carried by the anchors oracle +"
      puts "the non-empty-chart gate (verify-anchors), NOT by this pass."
    else
      puts "ALL #{collected.size} chart actuals were collected by the pooled exporter —"
      puts "#{actuals_path} is complete. No MCP queries needed."
    end
  else
    puts "The pooled exporter filled #{actuals_path} for #{collected.size} chart(s)."
    puts "Agent: run ONE mcp__sigma-mcp-v2__query call per REMAINING chart below and"
    puts "MERGE the results into that same file (shape:"
    puts '  { "<Sigma chart name>": [[dim, val], [dim, val], ...], ... } ).'
  end
  puts ""
  puts "Then re-run:"
  puts "  ruby scripts/phase6-parity.rb --tableau #{opts[:tab]} \\"
  puts "    --finalize --actuals #{actuals_path}#{opts[:extract_mode] ? ' \\\n    --extract-mode --extract-tol ' + opts[:extract_tol].to_s : ''}"
  puts ""
  remaining.each_with_index do |c, i|
    cols = c['sigma_columns'] || []
    # KPIs are single-column (value only) — they MUST be queried too (bead
    # s6fo: the >=2 guard silently dropped every KPI from the actuals fetch).
    sel = cols.each_with_index.map { |col, j| %("#{col}" AS f#{j}) }.join(', ')
    sql = %(SELECT #{sel} FROM "workbook"."#{c['sigma_element_id']}" ORDER BY f0 NULLS FIRST)
    puts "  [#{i + 1}/#{remaining.length}] #{c['chart']}"
    puts "    mcp__sigma-mcp-v2__query  type=workbook  workbookId=#{opts[:wb]}"
    puts "    sql=#{sql.inspect}"
    puts ""
  end
  puts "=" * 70
  exit 0
end

# PASS 2 — finalize: inject actuals + run verifier
abort("plan not found at #{plan_path}; run pass 1 first") unless File.exist?(plan_path)
plan = JSON.parse(File.read(plan_path))
actuals = JSON.parse(File.read(opts[:actuals]))

warn "Phase 6 PASS 2: injecting actuals (#{actuals.size} charts) → #{plan_path}"
plan['charts'].each do |c|
  # Actuals are keyed by the chart's `chart` field, but a HAND-AUTHORED parity
  # plan (the single-composite-dashboard case, no auto-plan) keys entries by
  # `name` — without this fallback `actuals[nil]` is nil, `actual` stays empty,
  # and every chart scores a FALSE 0% DIVERGE against nothing despite exact
  # value matches. Normalize + look up under both keys.
  c['chart'] ||= c['name']
  a = actuals[c['chart']] || actuals[c['name']]
  next unless a
  # A render-verify marker ({"status":"render-verify-required","reason":...} —
  # collect-parity-actuals' pivot-export 500/empty fallback) passes through
  # as-is: verify-parity reports it PENDING (or PASS once the plan chart
  # carries render_verified:true) instead of a bogus DIVERGE-against-empty.
  c['actual'] = (a.is_a?(Hash) && a['status']) ? a : { 'rows' => a }
end
File.write(plan_path, JSON.pretty_generate(plan))

warn "Phase 6 PASS 2: running verifier (#{opts[:extract_mode] ? 'extract-mode' : 'strict'})"
score_out_path = File.join(opts[:tab], 'parity-score.json')
verifier_args = ['ruby', File.join(__dir__, 'verify-parity.rb'),
                 '--plan', plan_path, '--score-out', score_out_path]
if opts[:extract_mode]
  verifier_args.concat(['--extract-mode', '--extract-tol', opts[:extract_tol].to_s])
end
out, err, status = Open3.capture3(*verifier_args)
puts out
warn err unless err.empty?
File.write(opts[:out], out)

# Hard-gate sentinel — parity-final.json. assert-phase6-ran.rb checks this file
# to confirm Phase 6 actually ran. Without this sentinel, a subagent can skip
# Phase 6 entirely and still self-report GREEN (the historic loophole that
# masked the cluster follower regression on 2026-05-22, see beads-sigma-4pm).
summary_path = File.join(opts[:tab], 'parity-final.json')
total = plan['charts'].size
# NB: verify-parity appends a "  (score NN%)" suffix (bead y9rd.2) — strip it so
# chart names stay clean for the tile-census name match. PENDING lines (the
# pivot-export render-verify fallback) carry a "(render-verify-required)" suffix.
passed_chart_names  = out.scan(/^PASS\s+\[[^\]]+\]\s+(.+?)(?:\s+\(score [\d.]+%\))?$/).flatten
failed_chart_names  = out.scan(/^DIVERGE\s+\[[^\]]+\]\s+(.+?)(?:\s+\(score [\d.]+%\))?$/).flatten
pending_chart_names = out.scan(/^PENDING\s+\[[^\]]+\]\s+(.+?)(?:\s+\((?:render-verify-required|too-large-for-export|timeout)\))?$/).flatten

# ---- Tile census (bead gjhe) ------------------------------------------------
# Compare the Tableau dashboard's chart-zone count against the charts that made
# it into the parity plan. A zone that rendered in the source dashboard but has
# no matching Sigma chart (empty view CSV silently dropped the tile, or an
# unexplained rename) used to slip through every gate — the workbook shipped
# with N-1 charts and parity still reported PASS. assert-phase6-ran.rb gate 5
# fails on unmatched zones unless --allow-missing-tiles explains them.
tile_census = nil
dash_layout_path = opts[:dash_layout] || File.join(opts[:tab], 'dashboard-layout.json')
if File.exist?(dash_layout_path)
  dash_layout = JSON.parse(File.read(dash_layout_path)) rescue nil
  if dash_layout.is_a?(Array)
    # Furniture exclusion + DASHBOARD SCOPING both live in ZoneCensus.tile_census
    # (pure, unit-tested). Scoping (field-caught false RED): the census must
    # judge exactly the dashboards the plan covers — when --dashboard scoped the
    # plan to one page of a multi-dashboard workbook, pooling ALL dashboards'
    # zones made every out-of-scope tile read "unmatched". The plan persists its
    # own scope so a finalize-only invocation scopes identically.
    census_scope = opts[:dashboards] || plan['dashboards_scope'] || []
    tile_census = ZoneCensus.tile_census(dash_layout, plan['charts'], census_scope)
    warn "tile census: #{tile_census['zones_total']} dashboard zone(s)" \
         "#{census_scope.any? ? " (scoped: #{Array(tile_census['dashboards_scoped']).join(', ')})" : ''}, " \
         "#{plan['charts'].size} chart(s) in parity plan, #{tile_census['zones_unmatched']} unmatched" \
         "#{tile_census['zones_unmatched'].positive? ? " — UNMATCHED: #{tile_census['unmatched_zone_names'].join(', ')}" : ''}"
  else
    warn "tile census skipped: #{dash_layout_path} is not a parse-twb-layout array"
  end
else
  warn "tile census skipped: no dashboard layout at #{dash_layout_path} (pass --dashboard-layout to enable)"
end
summary = {
  'workbook_id'  => plan.dig('charts', 0, 'workbook_id') ||
                    (File.exist?(File.join(opts[:tab], 'wb-readback.json')) ?
                       JSON.parse(File.read(File.join(opts[:tab], 'wb-readback.json')))['workbookId'] : nil),
  'ran_at'       => Time.now.utc.iso8601,
  'mode'         => opts[:extract_mode] ? 'extract' : 'strict',
  'extract_tol'  => opts[:extract_mode] ? opts[:extract_tol] : nil,
  'charts_total' => total,
  'charts_pass'  => passed_chart_names.size,
  'charts_fail'  => failed_chart_names.size,
  'pass_names'   => passed_chart_names,
  'fail_names'   => failed_chart_names,
  'status'       => (status.success? && total > 0 && passed_chart_names.size == total) ? 'PASS' : 'FAIL'
}
# Render-verify pendings (pivot-export 500/empty fallback) are surfaced by NAME
# so the gate's failure message can say exactly what to resolve — they block
# GREEN (status stays FAIL) but are pending-manual, not divergences.
if pending_chart_names.any?
  summary['charts_pending_manual'] = pending_chart_names.size
  summary['pending_names']         = pending_chart_names
  warn "pending render-verify (pivot CSV export 500/empty fallback): #{pending_chart_names.join(', ')} — " \
       'verify via render-read or direct SQL, set "render_verified": true on each chart in ' \
       "#{plan_path}, then re-run --finalize"
end
summary['tile_census'] = tile_census if tile_census

# ---- Value-parity score + tier coverage report (bead y9rd.2) ----------------
# Fold the verifier's per-tile value score (parity-score.json) and the
# build-layer coverage tiers (coverage.json: built/approximated/degraded/dropped)
# into one report so "N% parity" is a real number with a tier breakdown behind
# it — repeatable and CI-gateable via assert-phase6-ran.rb --min-parity-score.
if File.exist?(score_out_path)
  score_doc = JSON.parse(File.read(score_out_path)) rescue nil
  if score_doc
    summary['value_parity_score'] = score_doc['value_parity_score']
    summary['per_tile_scores'] = score_doc['tiles']
    warn "value-parity score: #{(score_doc['value_parity_score'].to_f * 100).round(1)}% (#{score_doc['tiles_pass']}/#{score_doc['tiles_total']} tiles exact)"
  end
end
coverage_path = opts[:coverage] || File.join(opts[:tab], 'coverage.json')
cov_unresolved = []
if File.exist?(coverage_path)
  cov = JSON.parse(File.read(coverage_path)) rescue nil
  if cov.is_a?(Hash)
    summary['tier_coverage'] = cov['summary'] if cov['summary']
    cov_unresolved = cov['unresolved'] || []
    # Tier report enrichment (bead y9rd.14): the summary counts alone don't say
    # WHICH tier or WHY. Add a distribution (by severity + source kind) and the
    # full dropped-with-root-cause list so a reviewer sees exactly what was lost.
    if cov_unresolved.any?
      summary['tier_distribution'] = {
        'by_severity'    => cov_unresolved.group_by { |u| u['severity'] }.transform_values(&:size),
        'by_source_type' => cov_unresolved.group_by { |u| u['source_type'] }.transform_values(&:size)
      }
      summary['excluded_with_root_cause'] = cov_unresolved
        .select { |u| u['severity'] == 'dropped' }
        .map { |u| u.select { |k, _| %w[visual source_type sigma_kind detail action recoverable].include?(k) } }
    end
  end
end

# Cross-ref DEPTH (bead y9rd.14): how deep the nested-LOD calc chains run — a
# proxy for calc-on-calc complexity. The build emits a <chart-specs>-lod-chains.json
# sidecar (decompose_nested_fixed, innermost-first); each chain's length is its
# depth. Best-effort: glob the tableau dir, omit the block when no chains exist.
lod_files = Dir.glob(File.join(opts[:tab], '*-lod-chains.json'))
chains = lod_files.flat_map { |f| (JSON.parse(File.read(f)) rescue []) }.select { |c| c.is_a?(Hash) }
if chains.any?
  depths = chains.map { |c| (c['chain'] || []).size }.reject(&:zero?)
  if depths.any?
    by_depth = depths.group_by(&:itself).transform_keys(&:to_s).transform_values(&:size)
    summary['cross_ref_depth'] = { 'max_depth' => depths.max, 'chains' => depths.size, 'by_depth' => by_depth }
  end
end

# Per-FORMULA "coverage answer" artifact (bead y9rd.14, ThoughtSpot idea): one
# record per scored column (did this formula migrate + at what fidelity) PLUS the
# dropped items (migrated:false + root cause). Flattens per-tile per-column scores
# (from parity-score.json, now carrying `columns`) and joins the coverage drops.
formula_coverage = []
if defined?(score_doc) && score_doc
  (score_doc['tiles'] || []).each do |t|
    (t['columns'] || []).each do |c|
      formula_coverage << {
        'chart' => t['chart'], 'column_id' => c['column_id'], 'kind' => c['kind'],
        'migrated' => true, 'fidelity' => c['score'],
        'coverage_status' => ((c['score'] || 0) >= 0.999 ? 'exact' : 'diverged')
      }
    end
  end
end
cov_unresolved.select { |u| u['severity'] == 'dropped' }.each do |u|
  formula_coverage << {
    'chart' => u['visual'], 'column_id' => nil, 'kind' => u['source_type'],
    'migrated' => false, 'fidelity' => nil, 'coverage_status' => 'dropped', 'detail' => u['detail']
  }
end
unless formula_coverage.empty?
  fc_path = File.join(opts[:tab], 'parity-formula-coverage.json')
  File.write(fc_path, JSON.pretty_generate(formula_coverage))
  n_drop = formula_coverage.count { |f| !f['migrated'] }
  n_div  = formula_coverage.count { |f| f['coverage_status'] == 'diverged' }
  warn "wrote #{fc_path} (#{formula_coverage.size} formula record(s): #{n_div} diverged, #{n_drop} dropped)"
end

# Idempotent finalize: this rebuilds `summary` from parity fields ONLY, so a
# re-run of --finalize would otherwise WIPE the visual verdict that
# record-visual-check.rb stamps onto this same parity-final.json (gate 8b), and
# a gate that had passed starts failing again. Carry the visual fields forward
# from the prior file so re-running finalize never un-does a recorded verdict.
# The list must cover EVERY key record-visual-check.rb stamps: gate 8b requires
# a complete style_checklist alongside a pass verdict, so dropping any stamped
# key here flips a passing gate to exit 13 on the next finalize.
if File.exist?(summary_path)
  prev = (JSON.parse(File.read(summary_path)) rescue {})
  %w[visual_verdict visual_notes visual_checked screenshot_path style_checklist
     agent_vision blind_grade blind_grade_waiver].each do |k|
    summary[k] = prev[k] if prev.key?(k)
  end
end
File.write(summary_path, JSON.pretty_generate(summary))
warn "wrote #{summary_path} (status=#{summary['status']} #{summary['charts_pass']}/#{summary['charts_total']}" \
     "#{summary['value_parity_score'] ? format(' parity=%.1f%%', summary['value_parity_score'].to_f * 100) : ''})"
exit(status.success? ? 0 : 2)
