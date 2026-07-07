#!/usr/bin/env ruby
# Build a parity plan automatically by matching Tableau view CSVs to Sigma
# workbook chart elements.
#
# Inputs:
#   --tableau /tmp/<name>           directory with get-workbook.json + views/<viewId>.csv
#   --workbook-spec wb-spec.json    Sigma workbook spec (after Phase 5c readback OR a manual write)
#                                   — used to pull element IDs, kinds, and column IDs
#   --out parity-plan.json          output plan (wrapped: { extract: bool, charts: [...] })
#
# Optional:
#   --rename CHART_FROM=CHART_TO    when the Sigma chart was renamed from the original Tableau title
#                                   (e.g., "Order Channel vs Ship Method=Orders by Category")
#                                   — repeatable
#
# Matching heuristic: Sigma element name == Tableau view name (exact), then loose match
# (strip punctuation, lowercase). Sigma kinds and Tableau chart_kinds are recorded for context.
#
# After running this, the agent fetches Sigma actuals via MCP or REST and edits the plan to
# add an "actual" key per chart, then runs verify-parity.rb.
#
# Or, if the SIGMA_API_TOKEN env path works, this script can pre-fetch Sigma actuals via the
# workbook query API and populate "actual" inline (best-effort; skip silently on failure).

require 'json'
require 'csv'
require 'optparse'
require 'net/http'
require 'uri'
require 'set'

opts = { renames: {} }
OptionParser.new do |p|
  p.on('--tableau DIR')          { |v| opts[:tab] = v }
  p.on('--workbook-spec PATH')   { |v| opts[:wb]  = v }
  p.on('--out PATH')             { |v| opts[:out] = v }
  p.on('--workbook-id ID')       { |v| opts[:wb_id] = v }
  p.on('--master-id ID',
       'Override the master-element ID prefix. Repeatable. ' \
       'Default: auto-detect every element where source.kind=="table" and ' \
       'elementId starts with "master" (handles multi-master specs like ' \
       'master-absences / master-employees / master-time).') { |v| (opts[:master_ids] ||= []) << v }
  p.on('--rename PAIR')          { |v| from, to = v.split('=', 2); opts[:renames][from] = to }
  p.on('--no-fetch')             {     opts[:no_fetch] = true }
  # Per-dashboard parity scoping (large-workbook one-tab-at-a-time gating). When
  # set, only chart elements on the matching workbook PAGE(s) are planned/gated —
  # so parity passes/fails per-tab instead of all-or-nothing across the whole
  # workbook. Page name match is case-insensitive exact OR unique substring (the
  # Sigma page name == the Tableau dashboard name in per-dashboard builds).
  # Repeatable. --page is an alias accepting a page id or name.
  p.on('--dashboard NAME', 'Scope parity to chart tiles on this workbook page only (name: exact or unique substring). Repeatable.') { |v| (opts[:dashboards] ||= []) << v }
  p.on('--page NAME_OR_ID', 'Alias for --dashboard; matches a page by name or id. Repeatable.') { |v| (opts[:dashboards] ||= []) << v }
end.parse!
abort('usage: --tableau DIR --workbook-spec FILE --out FILE [--workbook-id ID] [--rename A=B]') unless opts[:tab] && opts[:wb] && opts[:out]

# Load Tableau side: workbook metadata (for extract flag + view name → view id map) + CSVs
gw = JSON.parse(File.read(File.join(opts[:tab], 'get-workbook.json')))
views = gw.dig('views', 'view') || []
views = [views] unless views.is_a?(Array)

# hasExtracts on the workbook OR on the underlying datasource
extract = false
if gw['hasExtracts'] == true || gw['hasExtracts'] == 'true'
  extract = true
end
# Tableau Cloud often surfaces extracts on the workbook search result, not the get-workbook
# response — caller can re-flag via the --extract-mode CLI flag on verify-parity.rb.

view_by_name = views.each_with_object({}) { |v, h| h[v['name']] = v }

# Load Sigma side
spec = JSON.parse(File.read(opts[:wb]))

# Per-dashboard scope: narrow the pages we plan parity over to the matching
# page(s). The master-detection + chart-matching loops below iterate `pages`
# instead of `spec['pages']`, so a scoped run gates ONLY the target tab's tiles
# (per-tab parity, not all-or-nothing). No flag ⇒ every page (current behavior).
pages = spec['pages']
if opts[:dashboards] && !opts[:dashboards].empty?
  want = opts[:dashboards].map(&:downcase)
  pages = spec['pages'].select do |pg|
    nm = pg['name'].to_s.downcase
    pid = pg['id'].to_s.downcase
    want.any? { |w| !w.empty? && (nm == w || nm.include?(w) || pid == w) }
  end
  abort("--dashboard/--page matched no workbook page in #{opts[:wb]}") if pages.empty?
  warn "scoped parity to page(s): #{pages.map { |p| p['name'] }.join(', ')}"
end

# Build the set of master-element-IDs we should treat as "the master" for
# chart matching. Either explicit via --master-id (repeatable) OR auto-detect
# from the spec: any element with kind=="table" + visibleAsSource==false +
# source.kind=="data-model" is a master. This handles multi-master workbooks
# (e.g. workforce uses master-absences / master-employees / master-time, one
# per Tableau worksheet sourcing different facts) — the previous hardcoded
# `elementId == 'master'` check returned zero matches and an incomprehensible
# "fire 0 queries" message.
master_ids =
  if opts[:master_ids] && !opts[:master_ids].empty?
    opts[:master_ids]
  else
    detected = []
    spec['pages'].each do |pg|
      pg['elements'].each do |e|
        if e['kind'] == 'table' &&
           e['visibleAsSource'] == false &&
           e.dig('source', 'kind') == 'data-model'
          detected << e['id']
        end
      end
    end
    # Legacy fallback for specs that pre-date the master/visibleAsSource shape:
    # any element whose ID literally starts with `master`.
    if detected.empty?
      spec['pages'].each do |pg|
        pg['elements'].each do |e|
          detected << e['id'] if e['id'].to_s.start_with?('master')
        end
      end
    end
    detected.uniq
  end
abort("auto-parity-plan.rb: no master element(s) detected; pass --master-id explicitly") if master_ids.empty?
warn "matching charts that source from master element(s): #{master_ids.join(', ')}"

master_id_set = master_ids.to_set
# Transitive: hidden helper tables that THEMSELVES source a master (e.g. the
# scatter grouped-source tables, bead z1d0) count as masters for chart
# matching — the scatter chart sources the helper, not the master.
spec['pages'].each do |pg|
  pg['elements'].each do |e|
    next unless e['kind'] == 'table' && e['visibleAsSource'] == false
    next unless e['source'] && master_id_set.include?(e['source']['elementId'])
    master_id_set << e['id']
  end
end
sigma_charts = []
pages.each do |pg|
  pg['elements'].each do |e|
    next if master_id_set.include?(e['id'])
    next unless e['source'] && master_id_set.include?(e['source']['elementId'])
    sigma_charts << e
  end
end

# Match Sigma chart → Tableau view
def normalize(s)
  s.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

# Build reverse-rename map: tableau-name → sigma-name was the input;
# we want sigma-name → tableau-name for lookup.
rev_renames = opts[:renames].each_with_object({}) { |(k, v), h| h[v] = k }

plan_entries = []
sigma_charts.each do |el|
  sigma_name = el['name']
  tableau_name = rev_renames[sigma_name] || sigma_name

  view = view_by_name[tableau_name]
  view ||= view_by_name.find { |n, _| normalize(n) == normalize(tableau_name) }&.last
  if view.nil?
    warn "no Tableau view matched Sigma chart #{sigma_name.inspect} (try --rename '<Tableau title>=#{sigma_name}')"
    next
  end

  csv_path = File.join(opts[:tab], 'views', "#{view['id']}.csv")
  unless File.exist?(csv_path)
    warn "missing CSV at #{csv_path} for #{sigma_name.inspect}"
    next
  end

  rows = CSV.read(csv_path)
  next if rows.empty?
  header = rows.shift

  # Measure Names / Measure Values long-format CSV → pivot WIDE so it compares
  # against the dissolved multi-measure Sigma chart (build-charts emits one
  # yAxis column per measure, NAMED with the verbatim Tableau measure label —
  # the pivoted header below therefore matches by display name).
  mn_i = header.index { |h| h.to_s.strip.casecmp?('Measure Names') }
  mv_i = header.index { |h| h.to_s.strip.casecmp?('Measure Values') }
  if mn_i && mv_i && header.length == 3
    dim_i  = ([0, 1, 2] - [mn_i, mv_i]).first
    labels = rows.map { |r| r[mn_i] }.compact.map(&:strip).reject(&:empty?).uniq
    wide   = {}
    order  = []
    rows.each do |r|
      k = r[dim_i]
      unless wide.key?(k)
        wide[k] = {}
        order << k
      end
      wide[k][r[mn_i].to_s.strip] = r[mv_i]
    end
    header = [header[dim_i]] + labels
    rows   = order.map { |k| [k] + labels.map { |l| wide[k][l] } }
    warn "#{sigma_name.inspect}: Measure Names/Values long CSV pivoted to wide (#{labels.size} measure(s)) for the multi-measure chart"
  end

  n_fields = header.length

  # Parse a Tableau CSV cell to a comparable value. Measures arrive as
  # formatted strings ("110,788.35" / "$1,234" / "12.3%") — KPI expecteds MUST
  # become floats or the strict compare fails on representation (bead s6fo).
  parse_cell = lambda do |v|
    return nil if v.nil? || v.to_s.strip.empty?
    s = v.to_s.strip
    pct = s.end_with?('%')
    f = (Float(s.gsub(/[,$%]/, '')) rescue nil)
    return v if f.nil?
    pct ? f / 100.0 : f
  end
  expected_rows = rows.map do |r|
    r.map.with_index do |v, i|
      if n_fields == 1 || i.positive?
        parse_cell.call(v)
      else
        v.nil? || v.to_s.strip.empty? ? nil : v
      end
    end
  end

  # Column selection (bead s6fo): align the Sigma SELECT to the Tableau CSV's
  # column order by NAME so 3-channel charts (stacked color / pivot / scatter)
  # compare every channel — not an arbitrary first-2-columns slice.
  all_cols = (el['columns'] || [])
  header_base = lambda do |h|
    h.to_s.strip
     .sub(/^(?:sum|avg|average|min|max|median|distinct count|count) of /i, '')
     .sub(/^(?:avg|sum|min|max|med|cnt|ctd)\.\s*/i, '')
     .sub(/^(?:second|minute|hour|day|week|month|quarter|year) of /i, '')
     .strip
  end
  pick = lambda do |h|
    base = header_base.call(h)
    cands = all_cols.select do |c|
      nm = c['name'].to_s.strip
      nm.casecmp?(h.to_s.strip) || nm.casecmp?(base)
    end
    # Prefer plotted channel columns over hidden filter passthroughs.
    pref = %w[x- c- y- y2- k- p- calc-]
    cands.min_by { |c| pref.index { |px| c['id'].to_s.start_with?(px) } || 99 }
  end
  matched = header.map { |h| pick.call(h) }
  cols =
    if matched.all? && matched.map { |c| c['id'] }.uniq.length == header.length
      matched.map { |c| c['id'] }
    elsif el['kind'] == 'kpi-chart' && all_cols.length >= 1
      [all_cols.first['id']]
    else
      # Axis-channel fallback: x, color, y in CSV order (color-first when the
      # CSV has 3 fields — Tableau exports the inner/color dim first).
      x_id = el.dig('xAxis', 'columnId')
      y_id = (el.dig('yAxis', 'columnIds') || []).map { |y| y.is_a?(Hash) ? y['columnId'] : y }.first
      c_id = el.dig('color', 'column')
      guess = n_fields >= 3 && c_id ? [c_id, x_id, y_id] : [x_id, y_id]
      guess = all_cols.map { |c| c['id'] }.first(2) unless guess.all?
      warn "#{sigma_name.inspect}: CSV headers #{header.inspect} did not all match Sigma column names — falling back to #{guess.inspect}"
      guess.compact
    end

  entry = {
    'chart'       => sigma_name,
    'tableau_view' => tableau_name,
    'sigma_element_id' => el['id'],
    'sigma_kind'  => el['kind'],
    'sigma_columns' => cols,
    'expected'    => expected_rows
  }
  if opts[:wb_id] && cols.size >= 1
    sel = cols.each_with_index.map { |c, i| %("#{c}" AS f#{i}) }.join(', ')
    entry['sql_template'] = %(SELECT #{sel} FROM "workbook"."#{el['id']}" ORDER BY 1)
    entry['workbookId'] = opts[:wb_id]
  end
  plan_entries << entry
end

# NOTE: an earlier version of this script tried to pre-fetch actuals via
# POST /v2/workbooks/{wb}/query (REST). That endpoint does NOT exist on
# Sigma's public REST API — it returns `errorcause: UnmatchedHandler` with
# an empty body, which was silently swallowed by the rescue clause. The
# canonical path to fetch chart actuals is the MCP tool
# `mcp__sigma-mcp-v2__query` (Sigma's official MCP server, which goes
# through the internal query layer). Fire it from the agent's conversation
# layer — see phase6-parity.rb for the call shape per chart, and the
# Phase 6c documentation in SKILL.md for parallel-batch guidance.
#
# This script intentionally leaves entry['actual'] unset; the agent fills
# it after running the MCP queries in parallel (single tool-use message
# with N parallel tool calls). beads-sigma-s04.
puts "  NOTE: actuals must be fetched via mcp__sigma-mcp-v2__query (MCP), not REST."
puts "        Fire all #{plan_entries.size} per-chart queries in ONE parallel tool-use batch,"
puts "        then merge the rows into the parity plan's actual.rows arrays."

# ---- Hidden calc-filter gate -----------------------------------------------
# Worksheet-level filters on calc fields (Calculation_* refs) are invisible in
# CSV exports — they silently reduce row counts and break parity. Parse them
# from the dashboard layout if available; each requires either:
#   status: "translated"  — the filter has been applied to the Sigma source
#   status: "waived"      — explicitly waived with a reason
# Any unresolved filter blocks plan status to "needs_review" (never "green").
#
# The dashboard-layout path is looked up next to the --tableau dir as
# `dashboard-layout.json` (the default parse-twb-layout output location).
hidden_filters_gate = []
dash_layout_path = File.join(opts[:tab], 'dashboard-layout.json')
if File.exist?(dash_layout_path)
  begin
    dash_layout = JSON.parse(File.read(dash_layout_path))
    if dash_layout.is_a?(Array)
      # Collect all tiles in scope (scoped to matched pages/dashboards when
      # --dashboard was given; otherwise everything in the layout).
      scoped_dash_names = opts[:dashboards]&.map(&:downcase)
      dash_layout.each do |d|
        next if scoped_dash_names &&
                !scoped_dash_names.any? { |dn| d['dashboard'].to_s.downcase.include?(dn) }
        (d['zones'] || []).each do |z|
          next unless z['kind'] == 'chart'
          hf_list = z['hidden_filters']
          next if hf_list.nil? || hf_list.empty?
          hf_list.each do |hf|
            hidden_filters_gate << {
              'tile'        => z['caption'],
              'calc_ref'    => hf['calc_ref'],
              'caption'     => hf['caption'],
              'filter_type' => hf['filter_type'],
              'members'     => hf['members'],
              # Default status: unresolved. Caller must set "translated" or "waived".
              'status'      => 'unresolved'
            }.compact
          end
        end
      end
      if hidden_filters_gate.any?
        warn "hidden_filters gate: #{hidden_filters_gate.size} unresolved calc-filter(s) found — " \
             "plan will be 'needs_review' until each is translated or waived"
        hidden_filters_gate.each do |hf|
          warn "  [#{hf['tile']}] #{hf['calc_ref']} (#{hf['caption']}) filter_type=#{hf['filter_type']}"
        end
      else
        warn "hidden_filters gate: no hidden calc-filters found in dashboard layout"
      end
    end
  rescue JSON::ParserError => e
    warn "hidden_filters gate: could not parse #{dash_layout_path}: #{e.message}"
  end
else
  warn "hidden_filters gate: no dashboard-layout.json at #{dash_layout_path} (run parse-twb-layout first)"
end

# Derive plan-level status
unresolved_hf = hidden_filters_gate.reject { |hf| %w[translated waived].include?(hf['status']) }
plan_status = unresolved_hf.any? ? 'needs_review' : 'green'
warn "plan status: #{plan_status}" \
     "#{unresolved_hf.any? ? " (#{unresolved_hf.size} unresolved hidden calc-filter(s))" : ''}"

# Wrap output. Stamp freshness (bead: stale-parity-plan): record the newest
# discovery-CSV mtime this plan's expected values were derived from, so a later
# reuse (phase6-parity.rb) can detect a plan built against OLDER data than the
# current CSVs and rebuild instead of shipping a false FAIL.
require 'time'
csv_mtime = Dir.glob(File.join(opts[:tab], 'views', '*.csv'))
               .map { |f| File.mtime(f).to_i }.max || 0
output = {
  'extract'              => extract,
  'charts'               => plan_entries,
  'hidden_filters'       => hidden_filters_gate,
  'plan_status'          => plan_status,
  'generated_at'         => Time.now.utc.iso8601,
  'source_csv_max_mtime' => csv_mtime
}
File.write(opts[:out], JSON.pretty_generate(output))

puts "wrote #{opts[:out]}"
puts "  charts matched: #{plan_entries.size}"
puts "  extract flag:   #{extract}"
puts "  next: fire mcp__sigma-mcp-v2__query for each chart in parallel (one tool-use batch),"
puts "        then merge the result rows into the parity plan and run verify-parity.rb."
