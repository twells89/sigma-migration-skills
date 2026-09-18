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
# Matching (v5.5): PROVENANCE FIRST — when <tableau-dir>/chart-provenance.json
# exists (written by build-charts-from-signals.rb), each Sigma element id maps
# to its Tableau WORKSHEET name (unique per workbook), an exact collision-free
# join. Only elements ABSENT from the map (hand-added charts) fall back to the
# display-name heuristic: Sigma element name == Tableau view name (exact), then
# loose match (strip punctuation, lowercase) — WITH a warning, because display
# titles are NOT unique across dashboards (the same-title collision class:
# double-mapped + dropped views, and tiles parity-checked against the wrong
# same-named view). Sigma kinds and Tableau chart_kinds are recorded for context.
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
require_relative 'lib/workbook_code'

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
workbook_pages = WorkbookCode.pages(spec)
workbook_elements = WorkbookCode.elements(spec)

# Per-dashboard scope: narrow the pages we plan parity over to the matching
# page(s). Workbook pages are metadata-only; layout owns page membership, so
# scoped element selection must use WorkbookCode.elements_for_page rather than
# reading a nonexistent pages[].elements array.
pages = workbook_pages
if opts[:dashboards] && !opts[:dashboards].empty?
  want = opts[:dashboards].map(&:downcase)
  pages = workbook_pages.select do |pg|
    nm = pg['name'].to_s.downcase
    pid = pg['id'].to_s.downcase
    want.any? { |w| !w.empty? && (nm == w || nm.include?(w) || pid == w) }
  end
  abort("--dashboard/--page matched no workbook page in #{opts[:wb]}") if pages.empty?
  warn "scoped parity to page(s): #{pages.map { |p| p['name'] }.join(', ')}"
end
scoped_elements =
  if opts[:dashboards] && !opts[:dashboards].empty?
    pages.flat_map { |page| WorkbookCode.elements_for_page(spec, page) }.uniq { |element| element['id'] }
  else
    workbook_elements
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
    detected = workbook_elements.each_with_object([]) do |element, out|
      if element['kind'] == 'table' &&
         element['visibleAsSource'] == false &&
         element.dig('source', 'kind') == 'data-model'
        out << element['id']
      end
    end
    # Legacy fallback for specs that pre-date the master/visibleAsSource shape:
    # any element whose ID literally starts with `master`.
    if detected.empty?
      workbook_elements.each { |element| detected << element['id'] if element['id'].to_s.start_with?('master') }
    end
    detected.uniq
  end
if master_ids.empty?
  # A hand-authored spec may have NO intermediate master tables at all — every
  # chart sources the data model directly. That's a valid documented shape,
  # not an error (the chart loop below matches DM-sourced charts on its own).
  has_dm_charts = scoped_elements.any? do |element|
    element.dig('source', 'kind') == 'data-model' && element['kind'] != 'table'
  end
  abort('auto-parity-plan.rb: no master element(s) detected; pass --master-id explicitly') unless has_dm_charts
  warn 'no master tables detected — matching data-model-sourced charts directly'
else
  warn "matching charts that source from master element(s): #{master_ids.join(', ')}"
end

master_id_set = master_ids.to_set
# Transitive: hidden helper tables that THEMSELVES source a master (e.g. the
# scatter grouped-source tables, bead z1d0) count as masters for chart
# matching — the scatter chart sources the helper, not the master.
workbook_elements.each do |element|
  next unless element['kind'] == 'table' && element['visibleAsSource'] == false
  next unless element['source'] && master_id_set.include?(element['source']['elementId'])
  master_id_set << element['id']
end
sigma_charts = scoped_elements.each_with_object([]) do |element, out|
  next if master_id_set.include?(element['id'])
  # A chart counts when it sources a detected master — OR sources the data
  # model DIRECTLY (source.kind=='data-model' on the chart itself, the
  # documented hand-authored shape). The master-only check silently produced
  # a "0 CSV tiles" census on every exit-4 workbook, forcing an
  # --allow-missing-tiles waiver for tiles that were fully verifiable
  # (field-caught round 2, two independent runs).
  from_master = element['source'] && master_id_set.include?(element['source']['elementId'])
  from_dm = element.dig('source', 'kind') == 'data-model' &&
            !%w[table control text image container].include?(element['kind'].to_s)
  out << element if from_master || from_dm
end

# Match Sigma chart → Tableau view
# Element display name: put-layout replaces `name` with a visibility hash on
# hidden-title elements — recover text, else the id slug, so Tableau-view
# matching keeps working (and keys stay unique).
def el_display_name(el)
  n = el['name']
  return n.to_s unless n.is_a?(Hash)
  t = n['text'].to_s
  t.empty? ? el['id'].to_s.sub(/\Ael-/, '').tr('-', ' ') : t
end

def normalize(s)
  s.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

# Auto-bridge the display-title rename. Sigma tiles are named by their worksheet
# display_title ("Net Revenue"), but Tableau views are keyed by the worksheet
# caption/nickname ("OV KPI Revenue"). Seed the caption→display_title map from the
# dashboard-layout zones so parity matches WITHOUT a manual --rename (explicit
# --rename still wins). Keeps parity matching in lockstep with the element namer.
_dl_path = File.join(opts[:tab], 'dashboard-layout.json')
if File.exist?(_dl_path)
  begin
    _dl = JSON.parse(File.read(_dl_path))
    (_dl.is_a?(Array) ? _dl : (_dl['dashboards'] || [_dl])).each do |d|
      (d['zones'] || []).each do |z|
        cap = z['caption'].to_s; dt = z['display_title'].to_s.strip
        opts[:renames][cap] ||= dt unless cap.empty? || dt.empty? || cap == dt
      end
    end
  rescue StandardError
    nil # best-effort; fall back to name==name matching
  end
end

# Build reverse-rename map: tableau-name → sigma-name was the input;
# we want sigma-name → tableau-name for lookup.
# ⚠️ COLLISION-PRONE BY CONSTRUCTION: two worksheets sharing one display_title
# collapse to a single rev_renames entry, so both Sigma charts back-match the
# SAME view and the other view drops (field-verified: 29 charts → 24 views,
# 5 double-mapped + 5 dropped, and 5 tiles value-checked against the WRONG
# same-titled view). This map is therefore only the FALLBACK — the provenance
# join below (element id → worksheet, unique) is consumed first.
rev_renames = opts[:renames].each_with_object({}) { |(k, v), h| h[v] = k }

# ---- Chart provenance (v5.5 — the collision-free join) ----------------------
# build-charts-from-signals.rb writes <tableau-dir>/chart-provenance.json:
#   { "version": 1, "elements": { "<sigma element id>":
#       { "worksheet": "<Tableau worksheet name>", "dashboard": "...", ... } } }
# Tableau worksheet names are unique within a workbook (Tableau enforces it)
# and ARE the view names get-workbook.json/views key CSVs by — so an id-keyed
# lookup matches each chart to its own view exactly, immune to display-title
# collisions. Element ids are deterministic (el-<worksheet-slug>), so the map
# survives re-POSTs/readbacks. Charts absent from the map (hand-added) fall
# back to the display-name heuristic WITH A WARNING.
prov_path = File.join(opts[:tab], 'chart-provenance.json')
provenance = {}
if File.exist?(prov_path)
  begin
    pj = JSON.parse(File.read(prov_path))
    provenance = pj.is_a?(Hash) && pj['elements'].is_a?(Hash) ? pj['elements'] : {}
  rescue JSON::ParserError => e
    warn "chart-provenance.json unreadable (#{e.message}) — falling back to display-name matching"
  end
end
if provenance.empty?
  warn "no chart provenance at #{prov_path} — matching by DISPLAY NAME, which is " \
       'COLLISION-PRONE when worksheets share display titles; rebuild charts with ' \
       'build-charts-from-signals.rb to emit it (hand-authored specs: verify every ' \
       'tableau_view below and use --rename per renamed tile)'
end

plan_entries = []
sigma_charts.each do |el|
  sigma_name = el_display_name(el)
  prov = provenance[el['id'].to_s]
  if prov && !prov['worksheet'].to_s.strip.empty?
    tableau_name = prov['worksheet'].to_s
    matched_via  = 'provenance'
  else
    tableau_name = rev_renames[sigma_name] || sigma_name
    matched_via  = 'name-fallback'
    unless provenance.empty?
      warn "provenance MISS for element #{el['id']} (#{sigma_name.inspect}) — falling back to " \
           'display-name matching (hand-added chart?); verify its tableau_view'
    end
  end

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
    'tableau_view' => view['name'] || tableau_name,
    'sigma_element_id' => el['id'],
    'sigma_kind'  => el['kind'],
    'sigma_columns' => cols,
    'matched_via' => matched_via,
    'expected'    => expected_rows
  }
  if opts[:wb_id] && cols.size >= 1
    sel = cols.each_with_index.map { |c, i| %("#{c}" AS f#{i}) }.join(', ')
    entry['sql_template'] = %(SELECT #{sel} FROM "workbook"."#{el['id']}" ORDER BY 1)
    entry['workbookId'] = opts[:wb_id]
  end
  plan_entries << entry
end

# ---- Integrity guard: same-view double-map (LOUD, not silent) ---------------
# Two plan charts on the SAME tableau_view is legitimate only when one
# worksheet is genuinely placed on multiple dashboards (provenance-matched
# copies verify against the same CSV by design). When any of the duplicates
# arrived via the display-name FALLBACK and the workbook has ANOTHER view
# sharing that display title, one chart is being validated against the WRONG
# view — the silent wrong-numbers class (a repeated-name tile with a
# page-specific filter would "pass" against the wrong source). Warn naming
# both sides. The DROPPED view itself is the tile census's job (gate 5) — this
# guard only flags the double-map, so it cannot mask or double-count that.
begin
  # display_title → the worksheet captions that render under it: the rename
  # bridge's cap→display_title pairs, plus any view literally NAMED the title
  # (a worksheet whose display title equals its own name never enters renames).
  title_to_caps = Hash.new { |h, k| h[k] = [] }
  opts[:renames].each { |cap, dt| title_to_caps[normalize(dt)] << cap }
  view_by_name.each_key do |vn|
    key = normalize(vn)
    title_to_caps[key] << vn if title_to_caps.key?(key) && !title_to_caps[key].include?(vn)
  end
  plan_entries.group_by { |e| e['tableau_view'] }.each do |vn, entries|
    next if entries.size < 2
    fb = entries.select { |e| e['matched_via'] == 'name-fallback' }
    next if fb.empty?
    others = fb.flat_map { |e| title_to_caps[normalize(e['chart'])] }
               .uniq.reject { |cap| cap == vn }
    next if others.empty?
    warn "COLLISION: #{entries.size} chart(s) (#{entries.map { |e| e['sigma_element_id'] }.join(', ')}) " \
         "all matched Tableau view #{vn.inspect} by DISPLAY NAME, but the workbook has other view(s) " \
         "with the same display title: #{others.map(&:inspect).join(', ')} — at least one chart is " \
         'validating against the WRONG view. Rebuild charts with build-charts-from-signals.rb so ' \
         'chart-provenance.json disambiguates (or hand-fix tableau_view per chart), then regenerate this plan.'
  end
rescue StandardError => e
  warn "collision guard error (non-fatal): #{e.message}"
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
# v5.2 (speed): carry RESOLUTIONS forward across plan regenerations. The
# orchestrator re-runs this script on every re-entry, and a hardcoded
# 'unresolved' default silently WIPED the operator's translated/waived
# statuses — round-4 runs burned three identical Phase-6 FATALs re-doing the
# same waive (timeline-proven). Keyed by tile + calc_ref.
prior_hf = {}
if File.exist?(opts[:out])
  begin
    parsed = JSON.parse(File.read(opts[:out]))
    if parsed.is_a?(Hash)
      (parsed['hidden_filters'] || []).each do |hf|
        next unless hf.is_a?(Hash) && %w[translated waived].include?(hf['status'])
        prior_hf[[hf['tile'], hf['calc_ref']]] = hf
      end
    end
  rescue JSON::ParserError, TypeError
    nil
  end
end
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
            entry = {
              'tile'        => z['caption'],
              'calc_ref'    => hf['calc_ref'],
              'caption'     => hf['caption'],
              'filter_type' => hf['filter_type'],
              'members'     => hf['members'],
              # quantitative bounds ride along so the carry-forward fingerprint
              # (and a human reviewing the plan) can SEE a range change —
              # members-only compared trivially-equal nils (review-caught)
              'min'         => hf['min'],
              'max'         => hf['max'],
              # Default status: unresolved. Caller must set "translated" or "waived".
              'status'      => 'unresolved'
            }.compact
            if (prev = prior_hf[[entry['tile'], entry['calc_ref']]])
              # A resolution only carries when the filter DEFINITION is
              # unchanged — a waive granted for members ["2025"] must not
              # bless the same calc_ref now filtering ["2025","2026"] (the
              # 248→52-row silent wrong-numbers class this gate exists to
              # block; review-caught).
              same_def = prev['filter_type'].to_s == entry['filter_type'].to_s &&
                         Array(prev['members']).map(&:to_s).sort == Array(entry['members']).map(&:to_s).sort &&
                         prev['min'].to_s == entry['min'].to_s && prev['max'].to_s == entry['max'].to_s
              if same_def
                entry['status'] = prev['status']
                %w[waive_reason translation translated_to note].each { |k| entry[k] = prev[k] if prev[k] }
                warn "hidden_filters gate: carried '#{prev['status']}' forward for [#{entry['tile']}] #{entry['calc_ref']} (definition unchanged)"
              else
                warn "hidden_filters gate: DROPPED prior '#{prev['status']}' for [#{entry['tile']}] #{entry['calc_ref']} — " \
                     'the filter definition CHANGED (members/type differ); re-review and re-resolve it'
              end
            end
            hidden_filters_gate << entry
          end
        end
      end
      if hidden_filters_gate.any?
        open_hf = hidden_filters_gate.count { |hf| !%w[translated waived].include?(hf['status']) }
        warn "hidden_filters gate: #{open_hf} unresolved calc-filter(s) " \
             "(#{hidden_filters_gate.size - open_hf} carried resolved)" \
             "#{open_hf.positive? ? " — plan is 'needs_review' until each is translated or waived" : ''}"
        hidden_filters_gate.each do |hf|
          warn "  [#{hf['tile']}] #{hf['calc_ref']} (#{hf['caption']}) filter_type=#{hf['filter_type']} status=#{hf['status']}"
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
# Composite-dashboard fallback (bead: composite-parity-plan): a SINGLE composite
# dashboard view has no per-worksheet views/CSVs, so every Sigma chart `next`s
# above and plan_entries is empty — which then dead-ends the gate on
# charts_total==0. Emit a STUB entry per Sigma chart (expected:null, needs_source
# marker) so the census is non-empty and the operator fills `actual` from a live
# Sigma MCP query while the visual gate (8/8b) carries fidelity. Only triggers
# when there is genuinely no CSV oracle — never masks a real rename mismatch
# (which leaves CSVs present).
composite_stub = false
if plan_entries.empty? && csv_mtime.zero?
  composite_stub = true
  plan_entries = sigma_charts.map do |el|
    { 'id' => el['id'], 'chart' => el_display_name(el), 'name' => el_display_name(el), 'expected' => nil,
      'needs_source' => 'composite-dashboard: no per-worksheet CSV oracle — fill `actual` via a live ' \
                        'Sigma MCP query if a value oracle exists; fidelity is otherwise carried by the ' \
                        'visual gate (assert-phase6-ran.rb 8/8b).' }
  end
  plan_status = 'composite-stub'
  warn "COMPOSITE fallback: no per-worksheet CSVs found — emitted #{plan_entries.size} stub chart(s) " \
       '(expected:null). Value parity is manual (fill actual via Sigma MCP); visual gate carries fidelity.'
end

output = {
  'extract'              => extract,
  'charts'               => plan_entries,
  'hidden_filters'       => hidden_filters_gate,
  'plan_status'          => plan_status,
  'composite_stub'       => composite_stub,
  'generated_at'         => Time.now.utc.iso8601,
  'source_csv_max_mtime' => csv_mtime
}
File.write(opts[:out], JSON.pretty_generate(output))

puts "wrote #{opts[:out]}"
puts "  charts matched: #{plan_entries.size}"
puts "  extract flag:   #{extract}"
puts "  next: fire mcp__sigma-mcp-v2__query for each chart in parallel (one tool-use batch),"
puts "        then merge the result rows into the parity plan and run verify-parity.rb."
