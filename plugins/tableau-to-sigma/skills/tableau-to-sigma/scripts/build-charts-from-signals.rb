#!/usr/bin/env ruby
# Build Sigma chart-element specs from parse-twb-layout.rb output + view CSVs +
# a master-column map.
#
# The agent's job is the data model + master table (deciding which DM columns
# the master needs, naming them, wiring Lookup/Coalesce as needed). This
# script's job is the chart layer: translating each Tableau chart zone into a
# Sigma element using the new parser signals (chart_kind, sort, aggregations,
# channels, filters) so chart kind / aggregator / sort match the source instead
# of relying on agent defaults.
#
# Usage:
#   ruby scripts/build-charts-from-signals.rb \
#     --tableau-dir /tmp/<name> \
#     --layout /tmp/<name>/dashboard-layout.json \
#     --master-map /tmp/<name>/master-columns.json \
#     --master-element-id master \
#     --out /tmp/<name>/chart-specs.json
#
# Inputs:
#   --tableau-dir       directory with get-workbook.json + views/<viewId>.csv
#   --layout            parse-twb-layout.rb output (per-dashboard zone list)
#   --master-map        JSON: regex-string → { id, name } mapping CSV header tokens
#                       to master-table column IDs. Example:
#                       { "(?i)region":      { "id": "m-region",  "name": "Region" },
#                         "(?i)gross revenue": { "id": "m-gross-rev", "name": "Gross Revenue" } }
#   --master-element-id ID of the master table in the workbook (default "master")
#   --out               output JSON: array of chart-element specs ready to embed
#                       in a workbook spec's pages[].elements[]
#
# Per chart zone, the script reads the matching view CSV's first two headers
# (dim + measure). It then:
#   - Maps each header to a master column using the regex map.
#   - Picks the Sigma element `kind` from chart_kind (with `automatic` → bar
#     fallback + a warning to verify against the PNG). A VERIFIED per-tile kind
#     in png-read.json OVERRIDES the shelf inference for every kind (PR-10;
#     tiles named in png-read kind_waivers keep the shelf kind — a recorded
#     deliberate substitution).
#   - Reads zone.sort: emits xAxis.sort iff Tableau had a <sort>. Otherwise
#     leaves xAxis unsorted (Sigma renders natural categorical / date order).
#   - Reads zone.aggregations: applies the right Sigma aggregator. Tableau
#     "Sum"→Sum, "Avg"→Avg, "Min"→Min, "Max"→Max, "Median"→Median,
#     "CountD"→CountDistinct, "None"→raw column (no agg), "User"→already-
#     aggregated calc field formula (use as-is via the master column).
#   - Reads zone.channels.color: if present, build one yAxis per category in
#     the master column's distinct values (best-effort — agent should fill in
#     the real category list when they know it; we emit a TODO marker).
#   - Skips action filters ("[Action (Foo)]") — those are cross-chart dashboard
#     actions, not value filters.
#
# Output: array of element specs. Drop into pages[].elements[] in the workbook
# spec and POST via post-and-readback.rb.

require 'json'
require 'csv'
require 'date'
require 'optparse'
require 'base64'
require 'open3'
require 'digest'
require_relative 'learned-rules'
require_relative 'lib/theme_derive'
require_relative 'lib/png_classify'
require_relative 'lib/zone_census'
require_relative 'lib/format_map'     # PR-12: the ONE Tableau→Sigma format translator
require_relative 'lib/series_colors'  # PR-12: ordered per-series color schemes
require_relative 'lib/threshold_halo'  # C2: threshold-halo (computed-boolean color) detection
require_relative 'lib/integer_dim'    # PR-18: integer-coded dimension decode-to-text routing
require_relative 'lib/trellis_emit'   # shared native-trellis emitter (supported-kind gate + fallbacks)
require_relative 'lib/metric_binding' # shared DM-metric binder ([Metrics/<name>] over inline re-derive)
require_relative 'lib/kpi_card'       # shared KPI-chart emitter (comparative-KPI-ready)
require_relative 'lib/kpi_comparison_detect' # Task 5: prior/target comparison-measure detector
require 'erb'

opts = { master_id: 'master' }
OptionParser.new do |p|
  p.on('--tableau-dir DIR')         { |v| opts[:tab] = v }
  p.on('--layout PATH')             { |v| opts[:layout] = v }
  p.on('--meta PATH', 'parse-twb-layout sister meta file (worksheets+shared_filters)') { |v| opts[:meta] = v }
  p.on('--master-map PATH')         { |v| opts[:mmap] = v }
  p.on('--master-element-id ID')    { |v| opts[:master_id] = v }
  p.on('--controls PATH', 'JSON file: array of control specs to emit alongside the chart elements') { |v| opts[:controls] = v }
  p.on('--title STR',     'Dashboard title text element to emit (e.g., "Orders Dashboard")')         { |v| opts[:title] = v }
  p.on('--page-per-worksheet', 'Emit one Sigma page per Tableau worksheet (ignore dashboard layout)') { opts[:pages_mode] = :worksheet }
  p.on('--page-per-dashboard', 'Emit ONE Sigma page per Tableau DASHBOARD (multi-dashboard workbooks - bead ptrt)') { opts[:pages_mode] = :dashboard }
  # Per-dashboard scoping (large-workbook one-tab-at-a-time builds). Normally the
  # --layout is ALREADY scoped by parse-twb-layout --dashboard, so a single
  # dashboard ⇒ exactly one page. These flags are a defensive belt-and-suspenders
  # filter: if handed a FULL layout, keep only the matching dashboard(s) so a
  # standalone invocation still builds just the requested tab. Repeatable.
  p.on('--dashboard NAME', 'Build only this dashboard (name: exact or unique substring, case-insensitive). Repeatable.') { |v| (opts[:dashboards] ||= []) << v }
  p.on('--page ID', 'Build only the dashboard whose zone-root id matches (rarely needed; --dashboard is the handle).') { |v| (opts[:pages] ||= []) << v }
  p.on('--auto-controls', 'DEPRECATED — control emission is now ON by default (every .twb parameter + quick-filter becomes a control). No-op kept for back-compat.') { opts[:auto_controls] = true }
  p.on('--no-auto-controls', 'Disable auto-emit of controls from .twb parameters/quick-filters (escape hatch; you will miss the interactive layer).') { opts[:no_auto_controls] = true }
  # Converter meta (conv-meta.json) carrying workbookPatterns — used to auto-wire
  # parameter measure-pickers (kind:param-switch) into a control-driven Switch
  # tile measure (n4pi.10). Optional; absent ⇒ pickers stay surfaced as notes.
  p.on('--workbook-patterns PATH', 'converter conv-meta.json (workbookPatterns) — auto-wire param measure-pickers') { |v| opts[:wb_patterns] = v }
  p.on('--out PATH')                { |v| opts[:out] = v }
  # Where the migration COVERAGE ledger lands (the aggregated drop/approx report
  # migrate-tableau.rb surfaces). Default: coverage.json next to --out. bead beads-sigma-59mk.
  p.on('--coverage-out PATH')       { |v| opts[:coverage_out] = v }
  # 🚧 GATE escape hatch — waive the Phase 1d dashboard-read requirement. Use ONLY
  # when the source dashboard PNG genuinely cannot be read; name the reason in your report.
  p.on('--skip-dashboard-read REASON', 'waive the Phase 1d dashboard-read gate (REQUIRED reason; name it in your report)') { |v| opts[:skip_dashboard_read] = v }
  # DM metrics referenceable on the master (name+formula, own + inherited via
  # source.elementId) — a measure whose inline aggregate matches one binds to a
  # governed [Metrics/<name>] ref instead of re-deriving inline. Absent → inline.
  p.on('--metrics PATH', 'JSON array of DM metrics {name,formula} referenceable on the master element') { |v| opts[:metrics_file] = v }
end.parse!
%i[tab layout mmap out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

# Load the referenceable DM metrics once; every measure-emission site prefers a
# governed [Metrics/<name>] ref over its inline aggregate when they match by formula
# equivalence (strip the literal 'Master' prefix). Empty/absent → inline, byte-identical.
opts[:metrics] = (opts[:metrics_file] && File.exist?(opts[:metrics_file]) ?
                  JSON.parse(File.read(opts[:metrics_file], encoding: 'UTF-8')) : [])

# 🚧 GATE (Phase 1d) — refuse to build charts until the SOURCE dashboard PNG has
# been read and enumerated. png-read.json is the artifact of that read; without it
# the build produces the right numbers but silently drops tiles/text/filters the
# source dashboard rendered (the most common Phase 5 escape). Escape hatch:
# --skip-dashboard-read "<reason>". See scripts/lib/dashboard_read.rb + SKILL.md Phase 1d.
require_relative 'lib/dashboard_read'
require_relative 'lib/recipe_multimetric' # rollup_flag validator + caption-variant helpers
# Evidence ledger (PLAN-v4 E3.1 / E5.11) — optional: png-read-vs-shelf kind
# divergences are census entries in <WORK>/evidence-ledger.jsonl when the lib
# is vendored; an older checkout keeps the stderr line only.
EVIDENCE_LEDGER_LOADED = begin
  require_relative 'lib/evidence_ledger'
  true
rescue LoadError
  false
end
if opts[:skip_dashboard_read]
  warn "[SKIP] dashboard-read gate WAIVED (#{opts[:skip_dashboard_read]}) — name this in your migration report."
  # PR-14: every honored --skip-* leaves a record on the off-ramp trail.
  begin
    $LOAD_PATH.unshift File.expand_path('lib', __dir__)
    require 'offramp'
    Offramp.log(opts[:tab], kind: 'skip-flag-waived', reason: opts[:skip_dashboard_read],
                detail: '--skip-dashboard-read')
  rescue LoadError
    warn '       WARN: lib/offramp.rb not vendored — the waiver could not be recorded to offramps.jsonl.'
  end
else
  dr_ok, dr_errs = DashboardRead.validate(opts[:tab])
  unless dr_ok
    warn "[FAIL] Phase 1d dashboard-read gate blocks chart build (#{DashboardRead.path(opts[:tab])}):"
    dr_errs.each { |e| warn "       - #{e}" }
    warn '       Read the dashboard PNG (get-view-image, solo) and write png-read.json enumerating'
    warn '       every tile with its Sigma `kind` + text_elements + filter_shelf (SKILL.md Phase 1d),'
    warn '       or waive with --skip-dashboard-read "<reason>" and name it in your report.'
    exit 1
  end
  # png-read schema extension (same gate): the OPTIONAL point_in_time.rollup_flag
  # block (flag-valued discriminator — rollup rows marked by VALUE, not NULL).
  # A malformed block would silently no-op the rollup exclusion downstream, so
  # it fails the read gate here instead.
  _pr_doc = (JSON.parse(File.read(DashboardRead.path(opts[:tab]))) rescue nil)
  _rf_errs = RecipeMultimetric.validate_rollup_flag((_pr_doc || {})['point_in_time'] || {})
  if _rf_errs.any?
    warn '[FAIL] Phase 1d dashboard-read gate: png-read.json point_in_time.rollup_flag is malformed:'
    _rf_errs.each { |e| warn "       - #{e}" }
    warn '       Schema: "rollup_flag": { "column": "<flag col>", "rollup_values": ["Y"], "entity_values": ["N"] }'
    warn '       (refs/phase-1-discover.md). Fix the block or remove it (IsNull discriminator fallback).'
    exit 1
  end
end

# Human-verified bar orientation from png-read.json (Phase 1d) OVERRIDES the
# shelf inference below: the operator confirmed it against the source image, so
# it is authoritative where present. Keyed by tile title (a chart zone caption).
PNG_ORIENTATION = begin
  pr = (JSON.parse(File.read(DashboardRead.path(opts[:tab]))) rescue nil)
  tiles = (pr && pr['tiles'].is_a?(Array)) ? pr['tiles'] : []
  tiles.each_with_object({}) do |t, h|
    o = t['orientation']
    h[t['title'].to_s.downcase.strip] = o if %w[horizontal vertical].include?(o)
  end
rescue StandardError
  {}
end

# PR-10 KIND PROPAGATION — the human-verified chart KIND from png-read.json
# (Phase 1d) OVERRIDES the shelf inference for EVERY kind, not just bar
# orientation (the override above was the bar-only special case; this
# generalizes it). Field failure this closes: an operator corrected the kinds
# in a verified png-read.json and the build ignored them — bars shipped where
# the source shows lines. Precedence: png-read verified kind > shelf inference.
#
# Vocabulary bridge: png-read tiles carry Sigma element kinds (bar-chart /
# line-chart / …) while the zone loop speaks parser chart_kind (bar / line /
# …). The bridge is the INVERSE of DashboardRead::DRAFT_KIND — the one
# existing png-read↔parser mapping (lib/dashboard_read.rb) — never a second
# divergent table; combo/donut ride SIGMA_KIND's vocabulary ('combo' ⇒
# combo-chart; a donut is the pie family, same as lib/blind_grade.rb).
# Non-chart kinds (text/control/image/container) have no entry, so they can
# never override a chart zone.
#
# Tiles named in png-read.json kind_waivers [{tile, reason}] are EXEMPT: the
# operator recorded a DELIBERATE substitution at read time (e.g. a Sigma
# capability gap), so the shelf-side kind stands and the final gate (gate 21)
# accepts the difference by name — ledger-style, like coverage_waivers.
PNG_KIND_TO_CHART = DashboardRead::DRAFT_KIND
                    .reject { |ck, _| %w[automatic other].include?(ck) }
                    .each_with_object({}) { |(ck, sk), h| h[sk] ||= ck }
                    .merge('combo-chart' => 'combo', 'donut-chart' => 'pie').freeze
PNG_KIND = begin
  pr = (JSON.parse(File.read(DashboardRead.path(opts[:tab]))) rescue nil)
  if pr.is_a?(Hash) && pr['verified'] != false && pr['tiles'].is_a?(Array)
    kw = Array(pr['kind_waivers']).map { |w| w.is_a?(Hash) ? w['tile'].to_s.downcase.strip : nil }
                                  .compact.reject(&:empty?)
    pr['tiles'].each_with_object({}) do |t, h|
      next unless t.is_a?(Hash)
      title = t['title'].to_s.downcase.strip
      next if title.empty? || kw.include?(title)
      ck = PNG_KIND_TO_CHART[(t['kind'] || t['chart_kind']).to_s.strip.downcase]
      h[title] = ck if ck
    end
  else
    {} # absent / draft / waived read ⇒ no overrides; shelf inference stands
  end
rescue StandardError
  {}
end

# ---- chart_kind → Sigma element kind ----
SIGMA_KIND = {
  'bar'           => 'bar-chart',
  'line'          => 'line-chart',
  'area'          => 'area-chart',
  'pie'           => 'pie-chart',
  'scatter'       => 'scatter-chart',
  'combo'         => 'combo-chart',
  'map-region'    => 'region-map',
  'map-point'     => 'point-map',
  'pivot-table'   => 'pivot-table',
  'table'         => 'table',
  'kpi'           => 'kpi-chart',
  'table-or-text' => 'table',         # legacy parser output — kept for back-compat
  'automatic'     => 'bar-chart',     # fallback; agent verifies against PNG
  'other'         => 'bar-chart'
}.freeze

# The human display name for a built tile: the source-displayed worksheet title
# (parse-twb-layout's `display_title`, from the worksheet <title> run — e.g.
# "Net Revenue") when present, else the worksheet nickname/caption ("OV KPI
# Revenue"). One source of truth so every tile builder names elements the way the
# source labels them, not by internal sheet name.
def tile_title(zone, fallback)
  t = zone && zone['display_title']
  t && !t.to_s.strip.empty? ? t.to_s.strip : fallback
end

# ---- Tableau derivation → Sigma aggregation function name ----
SIGMA_AGG = {
  'Sum'    => 'Sum',
  'Avg'    => 'Avg',
  'Min'    => 'Min',
  'Max'    => 'Max',
  'Median' => 'Median',
  'CountD' => 'CountDistinct',
  'Count'  => 'CountIf(IsNotNull(%s))',  # special — see render_agg below
  'None'   => nil,                       # no aggregation; raw column ref
  'User'   => nil                        # user-defined calc — already aggregated
}.freeze

# ---- Date truncation derivations ----
DATE_TRUNC = {
  'Year-Trunc'   => 'year',
  'Quarter-Trunc'=> 'quarter',
  'Month-Trunc'  => 'month',
  'Week-Trunc'   => 'week',
  'Day-Trunc'    => 'day',
  'Hour-Trunc'   => 'hour'
}.freeze

# Tableau date-derivation code (on a shelf column-instance) → the "<grain> of "
# prefix Tableau puts on the CSV/header label for that field. Used to
# reconstruct the view headers from shelf signals when the data export came
# back empty (see synthesize_view_from_signals).
DATE_DERIV_LABEL = {
  'tyr' => 'Year of ',  'yr' => 'Year of ',
  'tqr' => 'Quarter of ', 'qr' => 'Quarter of ',
  'tmn' => 'Month of ', 'mn' => 'Month of ',
  'twk' => 'Week of ',  'wk' => 'Week of ',
  'tdy' => 'Day of ',   'dy' => 'Day of ',
  'thr' => 'Hour of ',  'hr' => 'Hour of ',
  'tmi' => 'Minute of ', 'mi' => 'Minute of ',
  'tsc' => 'Second of ', 'sc' => 'Second of '
}.freeze

# Reconstruct the view's CSV header row from the parsed shelf signals when the
# Tableau data export came back EMPTY (a common case for sheets gated behind a
# dashboard ACTION filter — Tableau renders them fine but its headless data API
# returns zero rows). The 2-column / multi-channel build flow downstream is
# driven by the HEADERS plus the aggregations/trunc dicts, not by data rows, so
# a header-only reconstruction lets us build the chart instead of dropping the
# tile. Returns { headers: [...] } (dims first, then measures) or nil if the
# shelves don't carry at least one dim + one measure. Principle: never skip
# anything that's in the .twb — an empty parity export is not a missing viz.
def synthesize_view_from_signals(z, meta)
  cbg = meta['columns_by_guid'] || {}
  field_header = lambda do |f|
    return nil unless f && f['guid']
    cap = (cbg[f['guid']] || {})['caption']
    cap = f['guid'] if cap.nil? || cap.to_s.empty?
    pre = DATE_DERIV_LABEL[f['derivation'].to_s.downcase]
    pre ? "#{pre}#{cap}" : cap
  end
  fields = ((z.dig('cols_shelf', 'fields') || []) + (z.dig('rows_shelf', 'fields') || []))
  dims = fields.select { |f| f['role'] == 'dim' }
  # v5.4: skip axis-anchor PLACEHOLDER measures (AVG(0) / min(-1.0) — the
  # dummy-axis idiom; on pie marks it's the dual-axis donut-hole hack). They
  # carry no data, and picking one as the synthesized measure header binds the
  # constant instead of the real marks-card measure (recovered below).
  meas = fields.select do |f|
    next false unless f['role'] == 'measure'
    !placeholder_calc?((cbg[f['guid'].to_s] || {})['formula'])
  end
  # Include a color-channel dimension if the encoding names one not on a shelf.
  if (cc = z.dig('channels', 'color', 'column'))
    g = guid_from_text(cc.to_s)
    dims << { 'guid' => g, 'role' => 'dim', 'derivation' => 'none' } if g && dims.none? { |f| f['guid'] == g }
  end
  # TEXT-MARK TABLE recovery (Top-N country lists): a Tableau text/label table
  # carries its measure on the Label mark, NOT on a shelf — so cols_shelf.fields
  # is empty and the zone would drop with "no dim+measure" even though the value
  # is fully known. Recover the measure from the sort's `using` clause
  # (`[…].[sum:Revenue (current US$):qk]`), then from the aggregations map (first
  # numeric-agg field that isn't the dim). Without this the 3 Top-Countries
  # tables silently vanish from the dashboard.
  if meas.empty? && dims.any?
    dim_guids = dims.map { |d| d['guid'].to_s.downcase }
    recovered = nil
    if (mm = z.dig('sort', 'using').to_s.match(/\.\[[a-z]+:(.+?):[a-z]+\]\s*\z/i))
      recovered = mm[1]
    end
    recovered ||= (z['aggregations'] || {}).find { |k, agg|
      %w[sum avg average min max count countd median].include?(agg.to_s.downcase) &&
        !dim_guids.include?(k.to_s.gsub(/\A\[|\]\z/, '').downcase)
    }&.first&.gsub(/\A\[|\]\z/, '')
    meas << { 'guid' => recovered, 'role' => 'measure', 'derivation' => 'none' } if recovered && !recovered.empty?
  end
  headers = (dims.map(&field_header) + meas.map(&field_header)).compact
  # Fallback for pie/detail marks: the dimension sits on the color/detail
  # encoding (not rows/cols shelves, and `channels` may be empty), so the only
  # signal is the zone's `aggregations` map — a "None"-aggregated column is the
  # dim, anything with a real aggregator is the measure. Without this a pie/
  # donut whose dim isn't shelf-bound gets "no dim+measure" and is dropped.
  if headers.length < 2 && (aggs = z['aggregations']).is_a?(Hash) && !aggs.empty?
    dcaps = []
    mcaps = []
    aggs.each do |col, agg|
      g = guid_from_text(col.to_s)
      next unless g
      cap = (cbg[g] || {})['caption']
      cap = g if cap.nil? || cap.to_s.empty?
      (agg.to_s.casecmp('none').zero? ? dcaps : mcaps) << cap
    end
    fb = (dcaps + mcaps).compact
    headers = fb if fb.length >= 2
  end
  # v5.4 LAST-RESORT — NAME-KEYED workbooks (textscan/excel-direct/live
  # datasources key column instances by NAME, not hex GUID; every resolver
  # above returns nil on them, and the zone dropped). Applied ONLY when the
  # zone would otherwise drop, so hex-GUID workbooks' header synthesis is
  # byte-identical to before.
  #
  # QUALITY FLOOR (v5.4.9 review fix): every field this block emits must be a
  # REAL column — its key must carry a <column> definition in columns_by_guid
  # and must not be a Tableau pseudo-field (the shelf parser mangles a
  # multi-pill shelf expression into a pseudo-dim whose guid is Tableau's
  # placeholder caption 'Multiple Values' — no column definition exists for
  # it). And the recovered MEASURE must actually be measure-shaped: never
  # promote a role=dimension or non-numeric (boolean/string/date) calc to a
  # Sum() measure. Without the floor this block emitted [Master/...] refs that
  # can never resolve, converting the old loud zone-drop into a hard exit-4 at
  # the pre-POST ref gate. When the floor rejects, headers stay short and the
  # zone falls back to the pre-v5.4 behavior: dropped with a loud warning.
  if headers.length < 2
    real_col = lambda do |key|
      k = key.to_s
      info = cbg[k]
      info.is_a?(Hash) && !TABLEAU_PSEUDO_FIELDS.include?(k) ? info : nil
    end
    dims2 = dims.select { |f| real_col.call(f['guid']) }
    if (cc2 = z.dig('channels', 'color', 'column')) && (g2 = name_or_guid_from_text(cc2.to_s))
      dims2 << { 'guid' => g2, 'role' => 'dim', 'derivation' => 'none' } if real_col.call(g2) && dims2.none? { |f| f['guid'] == g2 }
    end
    meas2 = meas.select { |f| real_col.call(f['guid']) }
    if meas2.empty? && dims2.any?
      dim_keys = dims2.map { |d| d['guid'].to_s.downcase }
      rec = (z['aggregations'] || {}).find do |k, agg|
        %w[sum avg average min max count countd median].include?(agg.to_s.downcase) &&
          !dim_keys.include?(k.to_s.gsub(/\A\[|\]\z/, '').downcase)
      end&.first&.gsub(/\A\[|\]\z/, '')
      rec_info = rec && real_col.call(rec)
      if rec_info && rec_info['role'].to_s != 'dimension' &&
         (rec_info['datatype'].to_s.empty? || %w[integer real].include?(rec_info['datatype'].to_s)) &&
         !placeholder_calc?(rec_info['formula'])
        meas2 << { 'guid' => rec, 'role' => 'measure', 'derivation' => 'none' }
      end
    end
    d2 = dims2.map(&field_header).compact
    m2 = meas2.map(&field_header).compact
    # The block's own contract (and the caller's): dims first, then measures —
    # at least one of EACH. Two dims are not a chart; reject and drop loudly.
    headers = d2 + m2 if d2.any? && m2.any?
  end
  headers.length >= 2 ? { headers: headers } : nil
end

# Tableau reserved placeholder captions that the shelf parser can surface as
# field keys but that are NEVER columns. 'Multiple Values' is the caption
# Tableau renders for a multi-pill shelf expression (grammar-level constant,
# not workbook-specific).
TABLEAU_PSEUDO_FIELDS = ['Multiple Values'].freeze

# Tableau relative-date offset window (first-period..last-period, in periods
# relative to now — e.g. first=-2,last=0 = "last 3 months") → explicit
# [startDate, endDate] bounds. Returns [nil, nil] for periods we don't bound
# (caller falls back to a pass-through relative filter).
#
# NOTE (bead z135, 2026-06-10): this is only the FALLBACK for offset windows.
# "This <period>" (first=0,last=0) filters are emitted as Sigma
# `mode: "current"` + `unit: <period>` — E2E re-verified that mode:current DOES
# filter the chart-data SQL when the control's `filters` target wiring is
# present, so the old hardcode-the-bounds workaround (which froze the filter
# and broke at period rollover) is no longer used for current-period filters.
def relative_period_bounds(period, first = 0, last = 0, now = Time.now)
  first = first.to_i
  last  = last.to_i
  case period.to_s.downcase
  when 'year'
    ["#{now.year + first}-01-01T00:00:00Z", "#{now.year + last}-12-31T23:59:59Z"]
  when 'quarter'
    q0 = Date.new(now.year, ((now.month - 1) / 3) * 3 + 1, 1)
    s  = q0 >> (3 * first)
    e  = (q0 >> (3 * last + 3)) - 1
    [s.strftime('%Y-%m-%dT00:00:00Z'), e.strftime('%Y-%m-%dT23:59:59Z')]
  when 'month'
    m0 = Date.new(now.year, now.month, 1)
    s  = m0 >> first
    e  = (m0 >> (last + 1)) - 1
    [s.strftime('%Y-%m-%dT00:00:00Z'), e.strftime('%Y-%m-%dT23:59:59Z')]
  else
    [nil, nil]
  end
end

# Back-compat alias — current period only.
def current_period_bounds(period, now = Time.now)
  relative_period_bounds(period, 0, 0, now)
end

# #415: the Workbook Spec API ACCEPTS a bare-date `startDate`/`endDate` default
# on a date-range control (200 on POST/PUT) and SILENTLY DROPS it on readback —
# the live control shows the "Select date range" placeholder and every filtered
# element opens unfiltered. Full ISO-8601 UTC timestamps ("2026-01-01T00:00:00Z")
# are the only string form observed to round-trip (refs/workbook-layout.md).
# Normalize every emitted default to that persisting form. Tableau attribute
# forms handled: "#2026-01-01#", "2026-01-01", "2026-01-01 00:00:00". Anything
# unrecognized is returned AS-IS — the preflight lint (A2 WARN) and the
# post-POST control-field audit surface it rather than a silent mangle.
def iso_utc_datestamp(v, end_of_day: false)
  s = v.to_s.strip.sub(/\A#/, '').sub(/#\z/, '')
  return v if s.empty?
  return s if s =~ /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/
  m = s.match(/\A(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}:\d{2}))?\z/)
  return v unless m
  "#{m[1]}T#{m[2] || (end_of_day ? '23:59:59' : '00:00:00')}Z"
end

# Tableau period-type → Sigma date-range `unit` enum. Sigma has no bare "week"
# (it splits Sunday/Monday anchored) and no "weekday"/other Tableau grains.
# Returns nil for grains Sigma's rolling modes can't express (caller falls back).
def sigma_date_unit(period)
  case period.to_s.downcase
  when 'year'    then 'year'
  when 'quarter' then 'quarter'
  when 'month'   then 'month'
  when 'week'    then 'week-starting-sunday'
  when 'day'     then 'day'
  when 'hour'    then 'hour'
  when 'minute'  then 'minute'
  end
end

# Map a Tableau relative-date filter (period-type + first/last period offsets) to
# a ROLLING Sigma date-range filter fragment — the fields that sit flat alongside
# `mode` (verified shapes in sigma-workbooks reference/specification/controls.md).
#
# Tableau offsets are period counts relative to now (first=-2,last=0 = "last 3
# months"; first=0,last=0 = "this month"). We preserve the window LENGTH and
# whether it reaches the current period, and emit a filter that ROLLS instead of
# freezing to concrete dates (the old mode:between behaviour broke at every
# period rollover and rendered empty when the frozen window missed the data).
#
# Returns [fragment_hash, kind] where kind ∈ :current/:last/:next/:frozen and the
# fragment excludes columnId/id/includeNulls (the caller adds those). Returns
# [nil, :unsupported] only when no Sigma shape fits at all.
def relative_date_filter_fields(period, first, last, now = Time.now)
  first = first.to_i
  last  = last.to_i
  unit  = sigma_date_unit(period)

  # "This <period>" — rolls automatically (bead z135). Works for every grain.
  return [{ 'mode' => 'current', 'unit' => (unit || period.to_s.downcase) }, :current] if first.zero? && last.zero?

  if unit
    # Trailing window that ends at now (last=0) or at the last complete period
    # (last=-1): "last N <unit>". includeToday distinguishes the two.
    if last == 0 || last == -1
      value = last - first + 1
      return [{ 'mode' => 'last', 'value' => value, 'unit' => unit, 'includeToday' => (last == 0) }, :last] if value >= 1
    end
    # Leading (future) window that starts at now (first=0) or the next period
    # (first=1): "next N <unit>".
    if first == 0 || first == 1
      value = last - first + 1
      return [{ 'mode' => 'next', 'value' => value, 'unit' => unit, 'includeToday' => (first == 0) }, :next] if value >= 1
    end
  end

  # Shifted/spanning window (or a grain Sigma can't roll): fall back to explicit
  # frozen bounds so at least the range is right at build time.
  start_d, end_d = relative_period_bounds(period, first, last, now)
  return [{ 'mode' => 'between', 'startDate' => start_d, 'endDate' => end_d }, :frozen] if start_d
  [nil, :unsupported]
end

def render_agg(agg, master_col_ref)
  return master_col_ref if agg.nil?
  if agg.include?('%s')
    agg.sub('%s', master_col_ref)
  else
    "#{agg}(#{master_col_ref})"
  end
end

# Tableau "User"-aggregated calc fields (derivation=User) are already-aggregated
# expressions like `SUM([Returns]) / COUNT([Order Id])` — wrapping them in
# another Sum() against a master column that doesn't exist emits an
# unresolvable `Sum([Master/X])` (bead k3kk). Decompose the Tableau formula
# directly into a Sigma formula against the master table instead. Returns nil
# when the formula contains anything beyond simple aggregates + arithmetic
# (the caller falls back and warns loudly).
USER_AGG_FN = {
  'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
  'MEDIAN' => 'Median'
}.freeze

# extra_fns: additional Sigma function names the residue validator should
# accept (the window-calc path passes WINDOW_SIGMA_FNS so Cumulative*/Moving*/
# Rank/Lag/... formulas validate; plain ratio decomposition passes none).
def translate_user_agg_formula(formula, mmap, columns_by_guid = {}, extra_fns: [])
  s = formula.to_s.gsub(/\s+/, ' ').strip
  return nil if s.empty?
  # Resolve Tableau-internal GUID refs ([d3b60b0e-…]) to their captions first —
  # worksheet calc formulas reference columns by GUID, not caption.
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption']}]" : "[#{Regexp.last_match(1)}]"
  end
  # IIF(c, t, e) → If(c, t, e) so guarded ratios (divide-by-zero protection)
  # survive the decomposition.
  s = s.gsub(/\bIIF\s*\(/i, 'If(')
  out = s.gsub(/\b(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[([^\]]+)\]\s*\)/i) do
    agg = Regexp.last_match(1).upcase
    col = Regexp.last_match(2)
    m   = map_column(col, mmap)
    ref = "[Master/#{m ? m['name'] : col}]"
    case agg
    when 'COUNT'  then "CountIf(IsNotNull(#{ref}))"
    when 'COUNTD' then "CountDistinct(#{ref})"
    else "#{USER_AGG_FN[agg]}(#{ref})"
    end
  end
  # ZN(expr) → Coalesce(expr, 0). One nesting level of parens is enough for
  # ZN(Sum([x]))-style wrappers; loop to handle repeated occurrences.
  while out =~ /\bZN\s*\(((?:[^()]|\([^()]*(?:\([^()]*\)[^()]*)*\))*)\)/i
    out = out.sub(Regexp.last_match(0), "Coalesce(#{Regexp.last_match(1)}, 0)")
  end
  # Validate: after stripping translated calls + refs, only arithmetic glue may
  # remain — otherwise the formula has constructs we can't safely auto-emit.
  residue = out.dup
  residue.gsub!(/"(?:\\.|[^"\\])*"/, '1') # string literals ("desc", "grand_total")
  residue.gsub!(/\[Master\/[^\]]+\]/, '1')
  allowed = %w[Sum Avg Min Max Median CountDistinct CountIf IsNotNull Coalesce If Abs] + extra_fns
  residue.gsub!(/\b(#{allowed.map { |f| Regexp.escape(f) }.join('|')})\b/, '')
  return nil unless residue =~ %r{\A[\s()+\-*/.,\d!=<>]*\z}
  out
end

# Row-level (non-aggregated) Tableau worksheet calc → Sigma formula over master
# columns (bead 3w4d: KPIs like "Avg. Days Since Order" aggregate a row-level
# DATEDIFF calc). Resolves GUID refs to captions, renames the common Tableau
# date/logic functions, rewrites bare refs to [Master/...]. Returns nil when
# the result still contains constructs we can't vouch for.
def translate_row_level_calc(formula, mmap, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  return nil if s.empty?
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end
  return nil if s =~ /\[[0-9a-f\-]{36}\]/i # unresolved GUID ref
  s = s.gsub(/\bDATEDIFF\s*\(\s*'([^']+)'\s*,/i) { "DateDiff(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATEADD\s*\(\s*'([^']+)'\s*,/i)  { "DateAdd(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATETRUNC\s*\(\s*'([^']+)'\s*,/i) { "DateTrunc(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATEPART\s*\(\s*'([^']+)'\s*,/i) { "DatePart(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bTODAY\s*\(\s*\)/i, 'Today()')
  s = s.gsub(/\bNOW\s*\(\s*\)/i, 'Now()')
  s = s.gsub(/\bIIF\s*\(/i, 'If(')
  s = s.gsub(/\bIFNULL\s*\(/i, 'Coalesce(')
  s = s.gsub(/\bABS\s*\(/i, 'Abs(')
  # Date-part extracts — align with the TS TABLEAU_FUNC_MAP so a row-level date
  # calc auto-translates instead of failing the residue check and dropping to a
  # manual warning (bead tt3z.4). WEEK has NO Sigma Week() fn — it maps to
  # DatePart("week", …) exactly like formulas.ts (bead tt3z.2). Run before the
  # single→double-quote pass; "week" is already double-quoted here.
  s = s.gsub(/\bWEEK\s*\(/i, 'DatePart("week", ')
  s = s.gsub(/\bYEAR\s*\(/i, 'Year(').gsub(/\bMONTH\s*\(/i, 'Month(').gsub(/\bDAY\s*\(/i, 'Day(')
  s = s.gsub(/\bQUARTER\s*\(/i, 'Quarter(').gsub(/\bHOUR\s*\(/i, 'Hour(')
  s = s.gsub(/\bMINUTE\s*\(/i, 'Minute(').gsub(/\bSECOND\s*\(/i, 'Second(')
  # 1:1 STRING functions (identical name modulo case + identical signature in
  # both formula languages; every target spelling is in the canonical
  # sigma_functions.rb registry). v5.4: row-level string chains
  # (REPLACE(REPLACE([col], "a", ""), "b", "") derived dims) failed the
  # residue check and dropped to a manual warning without these.
  s = s.gsub(/\bREPLACE\s*\(/i, 'Replace(').gsub(/\bUPPER\s*\(/i, 'Upper(')
       .gsub(/\bLOWER\s*\(/i, 'Lower(').gsub(/\bLTRIM\s*\(/i, 'Ltrim(')
       .gsub(/\bRTRIM\s*\(/i, 'Rtrim(').gsub(/\bTRIM\s*\(/i, 'Trim(')
       .gsub(/\bLEFT\s*\(/i, 'Left(').gsub(/\bRIGHT\s*\(/i, 'Right(')
       .gsub(/\bLEN\s*\(/i, 'Len(').gsub(/\bCONTAINS\s*\(/i, 'Contains(')
       .gsub(/\bSTARTSWITH\s*\(/i, 'StartsWith(').gsub(/\bENDSWITH\s*\(/i, 'EndsWith(')
       .gsub(/\bMID\s*\(/i, 'Mid(')
  s = s.gsub(/'([^']*)'/) { %("#{Regexp.last_match(1)}") } # remaining single-quoted strings
  out = s.gsub(/\[([^\/\]]+)\]/) do
    cap = Regexp.last_match(1).strip
    m = map_column(cap, mmap)
    "[Master/#{m ? m['name'] : cap}]"
  end
  residue = out.dup
  residue.gsub!(/"(?:\\.|[^"\\])*"/, '1')
  residue.gsub!(/\[Master\/[^\]]+\]/, '1')
  residue.gsub!(/\b(DateDiff|DateAdd|DateTrunc|DatePart|Today|Now|If|Coalesce|Abs|Year|Month|Day|Quarter|Hour|Minute|Second|Replace|Upper|Lower|Ltrim|Rtrim|Trim|Left|Right|Len|Contains|StartsWith|EndsWith|Mid)\b/, '')
  return nil unless residue =~ %r{\A[\s()+\-*/.,\d!=<>]*\z}
  out
end

# Worksheet-local DIMENSION calc -> Sigma formula over master columns
# (bead z1d0: "Channel Group" CASE / "High Value Flag" IF-chain dims used to
# fall back to an unresolvable raw header). Handles:
#   CASE [col] WHEN "a" THEN "b" ... [ELSE e] END -> Switch([Master/col], ...)
#   IF c THEN r [ELSEIF c2 THEN r2]* [ELSE e] END -> nested If(...)
# Returns nil when the construct isn't recognized.
def translate_dim_calc(formula, mmap, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  return nil if s.empty?
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end
  return nil if s =~ /\[[0-9a-f\-]{36}\]/i
  master_ref = lambda do |str|
    str.gsub(/\[([^\/\]]+)\]/) do
      cap = Regexp.last_match(1).strip
      m = map_column(cap, mmap)
      "[Master/#{m ? m['name'] : cap}]"
    end
  end
  if (m = s.match(/\ACASE\s+(\[[^\]]+\])\s+(WHEN\b.*?)\s*\bEND\z/i))
    subject = master_ref.call(m[1])
    body = m[2]
    pairs = body.scan(/WHEN\s+(.+?)\s+THEN\s+(.+?)(?=\s+WHEN\b|\s+ELSE\b|\z)/i)
    else_m = body.match(/\bELSE\b\s+(.+)\z/i)
    return nil if pairs.empty?
    parts = [subject]
    pairs.each { |a, b| parts << a.strip << b.strip }
    parts << else_m[1].strip if else_m
    return "Switch(#{parts.join(', ')})"
  end
  if (m = s.match(/\AIF\s+(.+)\s+END\z/i))
    body = m[1]
    segs = body.split(/\s+ELSEIF\s+/i)
    else_expr = nil
    if (em = segs.last.match(/(.*)\s+ELSE\s+(.+)\z/i))
      segs[-1] = em[1]
      else_expr = em[2].strip
    end
    conds = []
    segs.each do |seg|
      cm = seg.match(/\A(.+?)\s+THEN\s+(.+)\z/i)
      return nil unless cm
      conds << [cm[1].strip, cm[2].strip]
    end
    expr = else_expr || 'Null'
    conds.reverse_each { |c, r| expr = "If(#{c}, #{r}, #{expr})" }
    return master_ref.call(expr.gsub(/\bAND\b/, 'and').gsub(/\bOR\b/, 'or').gsub(/\bNOT\b/, 'not'))
  end
  nil
end

# ---- FIXED-LOD / grain-aware two-stage aggregation --------------------------
# Tableau `{FIXED [dims] : AGG([m])}` (and Avg-of-a-dim-table-measure, which
# Tableau evaluates at the dim table's native grain under relationship
# semantics) CANNOT be expressed as a single workbook formula: Sigma evaluates
# chart formulas at the source's base row grain, and window functions silently
# error in master/DM calc columns (feedback_sigma_window_functions). The
# verified translation (LODPROBE2, 2026-06-11) is a HIDDEN TWO-LEVEL GROUPED
# helper element on the Data page (the PR #65 / ry0n machinery):
#   level 2 (inner)  = the FIXED dims, computing the LOD aggregate
#   level 1 (outer)  = the dims the chart plots (or a constant for KPIs),
#                      computing the SECOND-stage aggregate over the inner
#                      group values (Sigma grouping calcs aggregate over child
#                      GROUP values, not base rows — verified)
# The chart sources the helper and references the outer calc via Max(): a
# chart re-aggregates a grouped source at BASE grain (group calcs replicated
# per row, window-style — verified), and Max over replicated identical values
# is exact.
# ⚠ Carried chart dims join the OUTER grouping — exact iff they are
# functionally dependent on (coarser than) the FIXED dims (e.g. Customer
# Segment per Customer Id). The emitted warning documents this assumption.
#
# DISPATCH (single vs nested FIXED — the two paths are disjoint by design):
#   - SINGLE-level {FIXED [dims] : AGG([m])}  → THIS path (parse_fixed_lod /
#     build_two_stage_helper): the regex below is anchored (\A..\z) to exactly
#     one non-nested FIXED, so it returns nil for anything nested. Parity-
#     proven on the fat workbook (40/40 strict incl. the dim-native-grain
#     subtlety).
#   - NESTED {FIXED ... {FIXED ...}}          → decompose_nested_fixed below
#     (requires ≥2 `{FIXED` occurrences): emits a helper-element CHAIN plan
#     into the -lod-chains.json sidecar for the agent to build. Never reaches
#     this path, and single-level LODs never reach the chain path.
def parse_fixed_lod(formula, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  # The inner aggregate argument is captured greedily (.+) rather than as a bare
  # [col], so a CONDITIONAL / expression inner (e.g. the last-sold-date pattern
  # MAX(IF [Units] > 0 THEN [Date] END)) is ACCEPTED here instead of silently
  # dropping to a generic "translate manually" warning (bead: conditional-inner
  # FIXED LODs missed the auto-helper). The \z anchor forces the trailing ')}',
  # so the greedy body backtracks to the last ')'.
  m = s.match(/\A\{\s*FIXED\s+(\[[^\]]+\](?:\s*,\s*\[[^\]]+\])*)\s*:\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\((.+)\)\s*\}\z/i)
  return nil unless m
  inner = m[3].strip
  # NESTED {FIXED…{FIXED…}} stays DISJOINT from this path (see the dispatch note
  # above): it routes through decompose_nested_fixed (helper-element chain). The
  # loosened inner would otherwise match the outer of a nest — reject it here.
  return nil if inner =~ /\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b/i
  resolve = lambda do |ref|
    if ref =~ /\A[0-9a-f\-]{36}\z/i
      info = columns_by_guid[ref]
      info && info['caption'] && info['caption'].strip
    else
      ref.strip
    end
  end
  dims = m[1].scan(/\[([^\]]+)\]/).flatten.map { |d| resolve.call(d) }
  return nil if dims.empty? || dims.any?(&:nil?)
  out = { 'dims' => dims, 'agg' => m[2].upcase }
  if (bare = inner.match(/\A\[([^\]]+)\]\z/))
    # Bare-column inner — unchanged behaviour: expose 'measure' (+ display label).
    meas = resolve.call(bare[1])
    return nil if meas.nil?
    out['measure'] = meas
    out['label']   = meas
  else
    # Conditional / expression inner — the caller resolves it to a Sigma formula
    # via lod_inner_ref; 'label' is the raw inner for warning messages.
    out['inner_expr'] = inner
    out['label']      = inner
  end
  out
end

# Parse a RELATIVE LOD — {INCLUDE [dims]: AGG([m])} or {EXCLUDE [dims]: AGG([m])}
# — which (unlike FIXED) is evaluated relative to the chart's VIEW grain. Returns
# { 'type'=>'INCLUDE'|'EXCLUDE', 'dims'=>[...], 'agg'=>'SUM'|..., 'measure'=>name }.
# Supports multiple dims and the full agg set (the WOW case is a multi-dim
# EXCLUDE MAX). The caller composes grain from the chart's plotted dims.
def parse_relative_lod(formula, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  m = s.match(/\A\{\s*(INCLUDE|EXCLUDE)\s+(\[[^\]]+\](?:\s*,\s*\[[^\]]+\])*)\s*:\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[([^\]]+)\]\s*\)\s*\}\z/i)
  return nil unless m
  resolve = lambda do |ref|
    if ref =~ /\A[0-9a-f\-]{36}\z/i
      info = columns_by_guid[ref]
      info && info['caption'] && info['caption'].strip
    else
      ref.strip
    end
  end
  dims = m[2].scan(/\[([^\]]+)\]/).flatten.map { |d| resolve.call(d) }
  meas = resolve.call(m[4])
  return nil if dims.empty? || dims.any?(&:nil?) || meas.nil?
  { 'type' => m[1].upcase, 'dims' => dims, 'agg' => m[3].upcase, 'measure' => meas }
end

# Aggregations where agg-of-agg == agg, so a two-level grouped helper reproduces
# the relative-LOD value exactly (Max of per-group Maxes = global Max, etc.).
# AVG / MEDIAN / COUNTD are NOT composable this way — those stay flagged.
LOD_COMPOSABLE_AGGS = %w[SUM MAX MIN COUNT].freeze

# Strip the aggregation/date-part prefix off a Tableau CSV header so it can be
# matched against a worksheet calc name ("Avg. Customer LTV LOD" -> "Customer
# LTV LOD"). Mirrors auto-parity-plan's header_base.
def header_base(h)
  h.to_s.strip
   .sub(/^(?:sum|avg|average|min|max|median|distinct count|count) of /i, '')
   .sub(/^(?:avg|sum|min|max|med|cnt|ctd)\.\s*/i, '')
   .sub(/^(?:second|minute|hour|day|week|month|quarter|year) of /i, '')
   .strip
end

LOD_INNER_AGG = {
  'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
  'MEDIAN' => 'Median', 'COUNTD' => 'CountDistinct',
  'COUNT' => 'CountIf(IsNotNull(%s))'
}.freeze

# Resolve a FIXED LOD's inner aggregate into the Sigma expression the helper's
# inner grouping aggregates over. A bare-column inner ('measure') maps to a
# single [Master/<col>] ref (unchanged). A conditional/expression inner
# ('inner_expr', e.g. IF [Units] > 0 THEN [Date] END) is translated to a Sigma
# formula over master columns via the shared dim/row-level calc translators
# (IF/CASE…END → nested If()/Switch(); arithmetic/date fns via row-level). The
# caller then wraps the result in the LOD aggregate (render_agg). Returns nil
# when the inner uses constructs we can't safely auto-emit — the caller falls
# back to a loud, specific warning (author a DM Custom SQL element) rather than
# building a broken helper.
def lod_inner_ref(lod, mmap, columns_by_guid = {})
  if lod['measure']
    m = map_column(lod['measure'], mmap)
    "[Master/#{m ? m['name'] : lod['measure']}]"
  elsif lod['inner_expr']
    translate_dim_calc(lod['inner_expr'], mmap, columns_by_guid) ||
      translate_row_level_calc(lod['inner_expr'], mmap, columns_by_guid)
  end
end

# Build the hidden two-level grouped helper element for a FIXED LOD (see the
# block comment above). Returns [element_hash, src_name, stage2_col_name].
#   value_name:    display name of the LOD value ("Customer LTV LOD")
#   value_formula: the inner aggregate over master refs ("Sum([Master/Net Revenue])")
#   inner_keys:    [{'name','formula'}] — the FIXED dims (master refs)
#   outer_dims:    [{'name','formula'}] — chart dims carried downstream; empty
#                  for KPIs (a constant "All Rows" key keeps the outer level)
#   stage2_agg:    Sigma agg template for the second stage ('Avg' or '%s' form)
def build_two_stage_helper(el_id:, master_id:, value_name:, value_formula:,
                           inner_keys:, outer_dims:, stage2_agg:)
  src_id = "#{el_id}-lod-src"
  src_name = "#{value_name} Source (#{el_id.sub(/^el-(kpi-)?/, '')})"
  stage2_name = "#{value_name} 2nd Stage"
  outer = outer_dims.empty? ? [{ 'name' => 'All Rows', 'formula' => '1' }] : outer_dims
  outer_cols = outer.each_with_index.map do |d, i|
    { 'id' => "#{src_id}-d#{i}", 'name' => d['name'], 'formula' => d['formula'] }
  end
  inner_cols = inner_keys.each_with_index.map do |k, i|
    { 'id' => "#{src_id}-k#{i}", 'name' => k['name'], 'formula' => k['formula'] }
  end
  value_col  = { 'id' => "#{src_id}-v", 'name' => value_name, 'formula' => value_formula }
  stage2_col = { 'id' => "#{src_id}-s2", 'name' => stage2_name,
                 'formula' => render_agg(stage2_agg, "[#{value_name}]") }
  element = {
    'id' => src_id, 'kind' => 'table', 'name' => src_name,
    'source' => { 'kind' => 'table', 'elementId' => master_id },
    'columns' => outer_cols + inner_cols + [value_col, stage2_col],
    'groupings' => [
      { 'id' => "#{src_id}-g1", 'groupBy' => outer_cols.map { |c| c['id'] },
        'calculations' => [stage2_col['id']] },
      { 'id' => "#{src_id}-g2", 'groupBy' => inner_cols.map { |c| c['id'] },
        'calculations' => [value_col['id']] }
    ],
    'visibleAsSource' => false
  }
  [element, src_name, stage2_name]
end

# Build the hidden DIM-GRAIN passthrough helper for an aggregate of a dim-table
# measure (grain annotation on the master-map entry — see mechanical-specs
# derive_master). The helper sources the DIM ELEMENT of the data model itself
# (NOT the fact master): Tableau's relationship semantics aggregate a dim-table
# column over the dim table's OWN rows, including entities with no fact match —
# a fact-side group-by can never reproduce that (verified: AvgLTR 11418.65 over
# 25 CUSTOMER_DIM rows vs 10480.53 fact-side). The source elementId is a
# placeholder ("__DM_ELEMENT__:<name>") — migrate-tableau resolves it against
# the posted DM readback (build-charts runs before it knows live element ids).
# Returns [element_hash, src_name].
def build_dim_grain_helper(el_id:, grain:, columns:)
  src_id = "#{el_id}-grain-src"
  src_name = "#{grain['element']} Grain (#{el_id.sub(/^el-(kpi-)?/, '')})"
  cols = columns.each_with_index.map do |name, i|
    { 'id' => "#{src_id}-c#{i}", 'name' => name, 'formula' => "[#{grain['element']}/#{name}]" }
  end
  element = {
    'id' => src_id, 'kind' => 'table', 'name' => src_name,
    'source' => { 'kind' => 'data-model', 'elementId' => "__DM_ELEMENT__:#{grain['element']}" },
    'columns' => cols,
    'visibleAsSource' => false
  }
  [element, src_name]
end

# Translate the Tableau column reference inside aggregations dict to a clean key
# we can look up. Tableau uses internal IDs like "[33b6c718-9b55-3dc0-9698-…]"
# OR friendly names like "[NET_REVENUE]". We strip the brackets for matching.
def strip_brackets(s)
  s.to_s.sub(/^\[/, '').sub(/\]$/, '')
end

# Match a CSV header (e.g., "Gross Revenue", "Distinct count of Order Id") to
# a master-table column using regex map.
def map_column(header, mmap)
  # Strip leading/trailing whitespace from the header before matching. Tableau
  # column captions sometimes carry trailing whitespace (e.g., "Order Date ")
  # from the source .twb XML — `(?i)^order date$` won't match it without this.
  h = header.to_s.strip
  mmap.each do |pat, info|
    return info if Regexp.new(pat).match?(h)
  end
  nil
end

# Resolve a calc-bound quick-filter to an ALREADY-materialized master column by
# the calc's IDENTITY, not a naive caption match (bead: calc-bound-filter wiring
# / #259). A quick-filter on a calculated field maps to no raw column, so
# map_column(cap) is nil and the control was recorded `needs-materialization` —
# even when the calc is already a column on the master. The filter's caption can
# arrive as EITHER form, so we bridge both against `columns_by_guid` (keyed by
# internal name → friendly caption):
#   - cap is an INTERNAL name, often blend-suffixed ("Calculation_NNN 1"): strip
#     the " N" secondary-source suffix, resolve to the friendly caption, and try
#     that against the master (a calc materialized + renamed to its caption — the
#     an "N. <Level>" hierarchy-level calc case).
#   - cap is a CAPTION ("Team Bucket"): find the internal name(s) carrying it and
#     try those (a calc materialized under its raw internal name).
# Returns the mmap column entry when the calc is already materialized (→ wire it
# like any quick-filter), else nil (→ genuinely needs materialization). Pure.
def materialized_calc_column(cap, columns_by_guid, mmap, norm)
  return nil if cap.nil? || columns_by_guid.nil?
  base   = cap.to_s.sub(/\s+\d+\z/, '').strip   # strip a blend/secondary suffix
  target = norm.call(cap)
  base_n = norm.call(base)

  # Direction 1: cap IS an internal calc name → friendly caption → master.
  info = columns_by_guid[cap.to_s] || columns_by_guid[base]
  if info && info['caption']
    m = map_column(info['caption'], mmap)
    return m if m
  end

  # Direction 2: cap is a caption → internal name(s) carrying it → master.
  columns_by_guid.each do |internal, ci|
    next unless ci && [target, base_n].include?(norm.call(ci['caption']))
    m = map_column(internal, mmap)
    return m if m
  end
  nil
end

# Resolve which Sigma column a Tableau <sort column="..."> targets: the chart's
# dim or its measure. Tableau sort columns look like
# `[federated.X].[none:REGION:nk]` or `[sum:NET_REVENUE:qk]` — pull the middle
# token of the last bracket segment and fuzzy-match against the dim names.
# A sort on the dim itself = alphabetic/natural dim sort; anything else
# (field sort on the measure, unresolvable) sorts by the measure, which was
# the previous hardcoded behaviour.
def sort_target_column_id(sort_info, dim, dim_hdr, dim_col_id, meas_col_id)
  raw   = sort_info['column'].to_s
  inner = raw[/\[([^\[\]]+)\]\z/, 1].to_s
  token = (inner.split(':')[1] || inner).downcase.gsub(/\W+/, '')
  return meas_col_id if token.empty?
  dim_keys = [dim && dim['name'], dim_hdr].compact
                                          .map { |x| x.to_s.downcase.gsub(/\W+/, '') }
                                          .reject(&:empty?)
  return dim_col_id if dim_keys.any? { |k| token == k || token.include?(k) || k.include?(token) }
  meas_col_id
end

# Pick the best aggregation for a header. CSV headers often hint at the
# aggregation ("Sum of X" / "Distinct count of X" / etc.).
def infer_csv_agg(header)
  case header.to_s.strip
  # Tableau CSV headers use BOTH the long form ("Avg of X") and the dotted
  # short form ("Avg. Days To Ship") — the short form previously fell through
  # to the Sum default and mis-aggregated every "Avg. X" measure (bead z1d0).
  when /^sum(\.\s*| of )/i           then 'Sum'
  when /^(avg|average)(\.\s*| of )/i then 'Avg'
  when /^min(\.\s*| of )/i           then 'Min'
  when /^max(\.\s*| of )/i           then 'Max'
  when /^med(ian)?(\.\s*| of )/i     then 'Median'
  when /\bdistinct count\b/i         then 'CountD'
  when /^(ctd|cntd)(\.\s*| of )/i    then 'CountD'
  when /\bcount\b/i                  then 'Count'
  else nil
  end
end

# ---- By-MEASURE (continuous) color channel --------------------------------
# Tableau column-instance references carry an aggregation prefix + a type
# suffix: `[federated.X].[sum:NET_REVENUE:qk]` is a continuous MEASURE
# (prefix in MEASURE_PREFIXES, `:qk` quantitative-key), whereas
# `[none:REGION:nk]` is a discrete dimension. A measure on Tableau's Color
# shelf is a *continuous* color ramp — the Sigma equivalent is
# `color:{by:scale, column:<measure col>, scheme:[...]}` (mirrors qlik_color's
# byMeasure branch in qlik-to-sigma). A Sigma column can't be on both yAxis and
# color, so the caller adds a DUPLICATE measure column for the color scale.
MEASURE_REF_PREFIXES = %w[sum avg min max count countd cntd median stdev stdevp var varp attr usr].freeze

# Sequential low->high ramp — Qlik's QLIK_MSCHEME 'sg'/'sc' sequential palette,
# a sensible default for a continuous measure color (white-yellow -> orange ->
# deep red). The agent can re-pick a diverging scheme in the Sigma editor.
MEASURE_COLOR_SCHEME = %w[#ffffcc #fd8d3c #bd0026].freeze

# Is this channel encoding a continuous MEASURE (vs a discrete dimension)?
# Reads the column-instance ref's agg/type tokens. Conservative: only true when
# the ref clearly carries a measure aggregation prefix or a quantitative key.
def channel_is_measure?(channel)
  return false unless channel
  ref = (channel['column'] || channel['field']).to_s
  return false if ref.empty?
  spec = ref[/\[([^\[\]]*)\]\s*\z/, 1] || ref     # last bracket segment
  if (m = spec.match(/\A([a-z]+):.*?:([a-z]+)\z/i))
    pref = m[1].downcase
    return true  if MEASURE_REF_PREFIXES.include?(pref)
    return false if pref == 'none'
  end
  spec =~ /:qk\]?\z/i ? true : false             # quantitative-key suffix
end

# Resolve a measure-color channel to a master column + Sigma aggregator.
# Returns { 'name', 'formula', 'agg' } (formula = aggregated master ref), or nil
# when the channel isn't a measure / can't be resolved.
def color_measure_field(channel, meta, mmap)
  return nil unless channel_is_measure?(channel)
  ref = (channel['column'] || channel['field']).to_s
  guid = guid_from_text(ref)
  cap = (guid && (meta['columns_by_guid'] || {})[guid]&.dig('caption')) ||
        ref.sub(/^\[[^\]]+\]\./, '').gsub(/^\[|\]$/, '')
           .sub(/^[a-z]+:/i, '').sub(/:[a-z]+$/i, '')
  return nil if cap.to_s.strip.empty?
  spec = ref[/\[([^\[\]]*)\]\s*\z/, 1] || ref
  pref = (spec.match(/\A([a-z]+):/i) || [])[1].to_s.downcase
  agg = SHELF_AGG_FOR_PREFIX[pref] || SIGMA_AGG[infer_csv_agg(cap) || 'Sum'] || 'Sum'
  m = map_column(cap, mmap) || { 'name' => cap }
  { 'name' => m['name'], 'formula' => render_agg(agg, "[Master/#{m['name']}]"), 'agg' => agg }
end

# ---- Load inputs ----
layout = JSON.parse(File.read(opts[:layout]))
# Defensive per-dashboard scope: if --dashboard/--page was passed AND the layout
# still carries more than the requested tab(s), keep only the matching ones.
# (parse-twb-layout normally pre-scopes the layout, making this a no-op — but a
# standalone build with a full layout should still honor the flag.) Name match is
# case-insensitive exact OR unique substring, matching parse-twb-layout.
if (opts[:dashboards] && !opts[:dashboards].empty?) || (opts[:pages] && !opts[:pages].empty?)
  want = (opts[:dashboards] || []).map(&:downcase)
  before = layout.size
  layout = layout.select do |d|
    n = d['dashboard'].to_s.downcase
    want.any? { |w| n == w || (!w.empty? && n.include?(w)) }
  end
  warn "scoped layout to #{layout.size}/#{before} dashboard(s): #{layout.map { |d| d['dashboard'] }.join(', ')}"
  abort("--dashboard/--page matched no dashboard in #{opts[:layout]}") if layout.empty?
end
mmap   = JSON.parse(File.read(opts[:mmap]))
meta   = opts[:meta] ? JSON.parse(File.read(opts[:meta])) : { 'worksheets' => {}, 'shared_filters' => [] }
# Caption → Tableau formula for every calculated field the workbook defines
# (deduped across worksheets; first definition wins). Lets the shared-filter
# control builder tell a calc-field filter ("Team Bucket", "Tier") apart
# from a genuinely-missing column, and surface the calc's formula so it can be
# materialized on the master rather than silently dropped.
calc_formula_by_caption = {}
(meta['worksheets'] || {}).each_value do |w|
  (w['calculations'] || []).each do |c|
    cap = (c['caption'] || c['name']).to_s.gsub(/^\[|\]$/, '').strip
    next if cap.empty? || c['formula'].to_s.empty?
    calc_formula_by_caption[cap] ||= c['formula'].to_s
  end
end
# Customer-learned rules (~/.tableau-to-sigma/learned-rules.yaml). Empty list
# is normal for first-time customers — rules accumulate as the gap-scout
# subagent validates translations.
LEARNED_RULES = LearnedRules.load
warn "loaded #{LEARNED_RULES.length} customer-learned rule(s) from #{LearnedRules.rules_path}" if LEARNED_RULES.any?
gw     = JSON.parse(File.read(File.join(opts[:tab], 'get-workbook.json')))
views  = gw.dig('views', 'view') || []
views  = [views] unless views.is_a?(Array)
view_by_name = views.each_with_object({}) { |v, h| h[v['name']] = v }

# Translate a Tableau format-value string into a Sigma format hash. PR-12:
# delegates to the shared lib/format_map.rb (the parser's translate_format
# delegates there too — the old duplicated minimal translator had already
# drifted on date handling). Sigma date-time formats are d3-time strings
# ('%B %-d, %Y'); moment-style tokens ("MMM D, YYYY") print LITERALLY, so
# FormatMap returns nil for anything it can't fully tokenize — unmapped
# formats are RECORDED in formats-emitted.json, never guessed.
def tableau_format_to_sigma(s)
  FormatMap.translate(s)
end

# PR-12: per-column DEFAULT formats from the .twb (<column default-format=…>,
# parser meta 'column_formats': caption → raw Tableau format string). The
# display ground truth wherever a sheet doesn't override per-pill — the fix
# for the field failure where a one-shot KPI printed raw while the source
# shows $-formatted. Populated after meta load; caption match mirrors
# pick_tableau_format's normalized containment match.
COLUMN_DEFAULT_FORMATS = {}
(meta['column_formats'] || {}).each { |k, v| COLUMN_DEFAULT_FORMATS[k] = v }

# Worksheet per-pill format keys are keyed by the field's INTERNAL id
# (`[usr:Calculation_AvgBal:qk]`), but measure/KPI columns are named by CAPTION
# ("Avg Balance per User"). Without this bridge the friendly match compares the
# internal id to the caption, misses, and the column falls to a name-based
# heuristic — the field failure where a KPI printed raw (or, worse, got a `$` on
# a percentage) while the source .twb carried the real format. Map internal id →
# caption from columns_by_guid so a format key can also match on its caption.
FORMAT_KEY_CAPTIONS = {}
(meta['columns_by_guid'] || {}).each do |gid, ci|
  cap = ci.is_a?(Hash) ? ci['caption'].to_s : ''
  FORMAT_KEY_CAPTIONS[gid.to_s] = cap unless cap.empty?
end

# The human name(s) a worksheet format-key can match a column header on: its own
# friendly token AND — bridged through columns_by_guid — the caption its
# internal id resolves to. Returns NORMALIZED keys (downcased, \W stripped).
def format_key_match_keys(field)
  inner = field.to_s.scan(/\[([^\]]+)\]/).flatten.last.to_s
  parts = inner.split(':')
  token = parts.length >= 3 ? parts[1].to_s : ''
  return [] if token.empty?
  names = [token]
  cap = FORMAT_KEY_CAPTIONS[token]
  names << cap if cap && !cap.empty?
  names.map { |n| n.downcase.gsub(/\W+/, '') }.reject(&:empty?).uniq
end

def pick_column_default_format_raw(header)
  hkey = header.to_s.downcase.gsub(/\W+/, '')
  return nil if hkey.empty?
  COLUMN_DEFAULT_FORMATS.each do |capn, val|
    ckey = capn.to_s.downcase.gsub(/\W+/, '')
    next if ckey.empty?
    return val if ckey == hkey || hkey.include?(ckey) || ckey.include?(hkey)
  end
  nil
end

def pick_column_default_format(header)
  raw = pick_column_default_format_raw(header)
  raw && tableau_format_to_sigma(raw)
end

# Last-resort number format when NO source format resolves (no pill format, no
# .twb default, no master-map format): guess by header name. Percent detection
# — a literal '%' in the caption OR a percent/rate/ratio word — WINS over the
# currency guess, so a percentage NEVER gets a currency symbol (the
# '% Customers with Profit' matched /profit/ and got a bogus '$' field failure).
def heuristic_number_format(name)
  n = name.to_s
  if n.include?('%') || n.downcase =~ /(rate|margin|pct|percent|ratio)/
    { 'kind' => 'number', 'formatString' => ',.1%' }
  elsif n.downcase =~ /(revenue|profit|cost|sales|amount|spend)/
    { 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }
  else
    { 'kind' => 'number', 'formatString' => ',.0f' }
  end
end

# Tableau scale-comma + literal-suffix formats ('n#,##0,,,B;-#,##0,,,B'):
# each trailing comma after the digit mask divides by 1,000 (',,,' = /1e9),
# '.0…' = decimals, the trailing letter is a LITERAL suffix. Sigma's d3 enum
# can NEVER render these exactly (,.2s shows SI 'G' for 1e9, not 'B') — the
# exact path is a Text() formula column. Returns {scale, decimals, suffix} or
# nil when there are no scale-commas (the enum branches above keep those).
def parse_scaled_suffix_format(s)
  return nil if s.nil? || s.empty?
  pos = s.split(';')[0].to_s
  m = pos.match(/\A[nc]?[#,0]+?(,+)(?:\.(0+))?\s*([A-Za-z%€£$]{1,3})?\z/)
  return nil unless m
  { 'scale' => 1000**m[1].length, 'decimals' => m[2].to_s.length, 'suffix' => m[3].to_s }
end

# The exact-format column for a scaled-suffix format: a NUMERIC scaled
# formula + a d3 fixed-decimal formatString + the schema's literal `suffix`
# field (spec/verify-confirmed 2026-07-11). Strictly better than a Text()
# concat: trailing zeros survive (',.1f' renders 3.0 not 3), grouping
# survives, and the column stays numeric (sortable).
def scaled_suffix_column(inner_formula, spec)
  {
    'formula' => "(#{inner_formula}) / #{spec['scale']}",
    'format'  => { 'kind' => 'number', 'formatString' => ",.#{spec['decimals']}f" }
                 .merge(spec['suffix'].empty? ? {} : { 'suffix' => spec['suffix'] })
  }
end

# Sigma formulas reference controls by `controlId` in brackets, NOT by display
# name. This helper computes the controlId the auto-controls block will emit
# for a given parameter caption so the translated Switch/If formulas match.
def param_control_ref(caption)
  "[ctl-param-#{caption.downcase.gsub(/\W+/, '-').sub(/-$/, '')}]"
end

# ---- Parameter → column data-scoping tracer (TASK C / #259) ----------------
# A data-scoping parameter drives a boolean filter calc that compares a column
# to the parameter — e.g. `[Region] = [Parameters].[Region Param]` — which
# Tableau uses as a worksheet filter (keep only matching rows). To reproduce
# that in Sigma the parameter's control must actually FILTER the column, not
# merely be referenced by a translated calc (a materialized boolean column
# filters nothing on its own). This PURE tracer scans every calc formula for
# such comparisons against the given parameter and returns:
#
#   { 'clean' => [{ 'col' => <caption>, 'column_id' => <master col id>,
#                   'op' => '='|'>='|'<='|'>'|'<' }, ...],
#     'candidates' => [<caption>, ...] }
#
# `clean` = single, whole-formula comparisons "[Col] <op> [Param]" (either
#           operand order) whose [Col] resolves to a master column. The caller
#           auto-wires the EQUALITY ones to a filter target (directional ops are
#           surfaced, not auto-wired — an inclusion filter can't express ">").
# `candidates` = every non-parameter column any param-referencing calc mentions
#           that resolves to a master column — surfaced so the operator knows the
#           target(s) when the calc is a multi-param period engine we won't guess.
# Pure (no I/O, no globals) so it is unit-testable in isolation.
def param_filter_targets(param_cap, calc_formulas, mmap, columns_by_guid = {}, param_name: nil)
  out = { 'clean' => [], 'candidates' => [] }
  param_forms = [param_cap, param_name].map { |x| x.to_s.gsub(/^\[|\]$/, '').strip }
                                       .reject(&:empty?).uniq
  return out if param_forms.empty?
  is_param = ->(ref) { param_forms.any? { |pf| pf.casecmp?(ref.to_s.strip) } }
  op_re = /(>=|<=|<>|!=|=|>|<)/

  (calc_formulas || {}).each_value do |raw|
    next if raw.to_s.empty?
    # Normalize [Parameters].[X] → [X] and resolve [<guid>] → [caption] so refs
    # compare uniformly, then require the formula to touch this parameter.
    s = raw.to_s.gsub(/\s+/, ' ')
            .gsub(/\[Parameters\]\.\[([^\]]+)\]/i, '[\1]')
            .gsub(/\[([0-9a-f\-]{36})\]/i) do
              info = (columns_by_guid || {})[Regexp.last_match(1)]
              info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
            end
    next unless param_forms.any? { |pf| s =~ /\[#{Regexp.escape(pf)}\]/i }

    # Candidate columns: every bracketed ref that is not the parameter and
    # resolves to a master column.
    s.scan(/\[([^\/\]]+)\]/).flatten.each do |ref|
      r = ref.strip
      next if is_param.call(r)
      out['candidates'] << r if map_column(r, mmap)
    end

    # Clean single-comparison form: the WHOLE formula is "[A] <op> [B]" with the
    # parameter on exactly one side and a master column on the other.
    if (m = s.strip.match(/\A\[([^\/\]]+)\]\s*#{op_re}\s*\[([^\/\]]+)\]\z/))
      a, op, b = m[1].strip, m[2], m[3].strip
      col = if is_param.call(b) && !is_param.call(a) then a
            elsif is_param.call(a) && !is_param.call(b) then b
            end
      if col && (mc = map_column(col, mmap))
        # Normalize the operator to be column-relative regardless of operand order.
        op = { '>' => '<', '<' => '>', '>=' => '<=', '<=' => '>=' }.fetch(op, op) if is_param.call(a)
        out['clean'] << { 'col' => col, 'column_id' => mc['id'], 'op' => op }
      end
    end
  end
  out['clean'].uniq! { |c| [c['column_id'], c['op']] }
  out['candidates'].uniq!
  out
end

# ---- Tableau table-calc translators ---------------------------------------
# Translate Tableau table-calculation functions to their Sigma equivalents.
# Returns the translated formula, plus a placement hint. Sigma window
# functions are FIRST-CLASS as chart-element viz formulas on the yAxis
# (WINPROBE-validated 2026-06-12); they error only in DM-element calc columns
# and grouping-table master calcs — see refs/window-functions.md.
#
# Function mappings (Sigma names):
#   INDEX()                  → RowNumber()
#   LOOKUP(expr, n)          → Lag(expr, n)  (positive n) / Lead(expr, -n) (neg)
#   LOOKUP(expr, 0)          → expr  (zero offset is identity)
#   RANK(expr [, 'desc'])    → Rank(expr [, "desc"])
#   RANK_DENSE(expr)         → RankDense(expr)
#   RANK_UNIQUE(expr)        → RowNumber() within ranked partition
#   RANK_PERCENTILE(expr)    → RankPercentile(expr)
#   TOTAL(SUM(x))            → Sum(x)  (Sigma metric on master without dim group)
#   SIZE()                   → Count(*) OVER ()  — no direct Sigma fn; warn
#   FIRST()                  → RowNumber() - 1   (Tableau FIRST returns 0-indexed)
#   LAST()                   → no direct equiv; needs Count-RowNumber pattern
#   ZN(x)                    → Coalesce(x, 0)
#   COUNTD(x)                → CountDistinct(x)
#   IIF(c, t, e)             → If(c, t, e)
#   IFNULL(x, y)             → Coalesce(x, y)
def translate_tableau_tc(formula)
  return [nil, nil] if formula.nil? || formula.empty?
  s = formula.dup
  hints = []
  changed = false

  # Order matters — apply table-calc translations BEFORE simple renames so the
  # match patterns (LOOKUP / TOTAL(COUNTD()) etc.) see the original Tableau
  # syntax.

  # INDEX() → RowNumber()
  if s.gsub!(/\bINDEX\s*\(\s*\)/, 'RowNumber()')
    hints << 'INDEX()→RowNumber()'; changed = true
  end

  # LOOKUP(expr, 0) — drop the wrapper. Use a balanced-paren match.
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*0\s*\)/
    s = s.sub($~[0], $1)
    hints << 'LOOKUP(x, 0)→x'; changed = true
  end
  # LOOKUP(expr, -n) → Lag(expr, n). Tableau's negative offset looks BACKWARD
  # (LOOKUP(x, -1) = previous row), which is Sigma Lag — the earlier mapping
  # had Lag/Lead reversed (caught by the WINPROBE WoW-delta live validation:
  # Coalesce(Sum(x) - Lag(Sum(x), 1), 0) matches the warehouse, Lead diverges).
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*-(\d+)\s*\)/
    s = s.sub($~[0], "Lag(#{$1}, #{$2})")
    hints << 'LOOKUP(x, -n)→Lag(x, n)'; changed = true
  end
  # LOOKUP(expr, n) where n >= 1 → Lead(expr, n) (forward offset = next rows)
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*(\d+)\s*\)/
    s = s.sub($~[0], "Lead(#{$1}, #{$2})")
    hints << 'LOOKUP(x, n)→Lead(x, n)'; changed = true
  end

  # RUNNING_* → Cumulative* (WINPROBE-validated 930/930: cumulative functions
  # follow the chart's xAxis sort and auto-partition by the chart color/series).
  { 'SUM' => 'CumulativeSum', 'AVG' => 'CumulativeAvg', 'MAX' => 'CumulativeMax',
    'MIN' => 'CumulativeMin', 'COUNT' => 'CumulativeCount' }.each do |tfn, sfn|
    if s.gsub!(/\bRUNNING_#{tfn}\s*\(/, "#{sfn}(")
      hints << "RUNNING_#{tfn}→#{sfn} (follows xAxis sort; valid as a chart viz formula on the yAxis)"
      changed = true
    end
  end
  # WINDOW_*(agg, -n, 0) → Moving*(agg, n); (-n, m) → Moving*(agg, n, m).
  # Tableau bounds are (first, last) offsets; Sigma Moving* takes (back[, fwd])
  # as POSITIVE counts. Forward-only / shifted windows (first > 0 or last < 0)
  # and FIRST()/LAST() bounds have no validated mapping — leave untouched.
  # NOTE: 'STDEV'/'VAR' here are the SAMPLE variants — Tableau WINDOW_STDEV /
  # WINDOW_VAR map to Sigma MovingStdDev / MovingVariance. The population forms
  # WINDOW_STDEVP / WINDOW_VARP stay manual (no `\bWINDOW_VAR\s*\(` match on
  # "WINDOW_VARP(" — the P breaks the word boundary, so they fall through).
  { 'AVG' => 'MovingAvg', 'SUM' => 'MovingSum', 'MAX' => 'MovingMax',
    'MIN' => 'MovingMin', 'COUNT' => 'MovingCount',
    'STDEV' => 'MovingStdDev', 'VAR' => 'MovingVariance' }.each do |tfn, sfn|
    while (m = s.match(/\bWINDOW_#{tfn}\s*\(\s*((?:[^(),]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\)/))
      lo, hi = m[2].to_i, m[3].to_i
      break if lo > 0 || hi < 0 # shifted window — unvalidated, keep Tableau form
      s = s.sub(m[0], hi.zero? ? "#{sfn}(#{m[1]}, #{-lo})" : "#{sfn}(#{m[1]}, #{-lo}, #{hi})")
      hints << "WINDOW_#{tfn}(x, -n, m)→#{sfn}(x, n[, m]) (valid as a chart viz formula on the yAxis)"
      changed = true
    end
  end

  # TOTAL(SUM(x)) → Sum(x); TOTAL(COUNTD(x)) → CountDistinct(x); TOTAL(AVG(x))
  if s.gsub!(/\bTOTAL\s*\(\s*SUM\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'Sum(\1)')
    hints << 'TOTAL(SUM(x))→Sum(x) (non-grouping context)'; changed = true
  end
  if s.gsub!(/\bTOTAL\s*\(\s*COUNTD\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'CountDistinct(\1)')
    hints << 'TOTAL(COUNTD(x))→CountDistinct(x) (non-grouping context)'; changed = true
  end
  if s.gsub!(/\bTOTAL\s*\(\s*AVG\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'Avg(\1)')
    hints << 'TOTAL(AVG(x))→Avg(x) (non-grouping context)'; changed = true
  end

  # RANK_UNIQUE(expr[, 'asc'|'desc']) → RowNumber(). Tableau RANK_UNIQUE assigns
  # a UNIQUE 1..N rank (no ties); Sigma RowNumber() does the same but FOLLOWS the
  # element's sort, so it is exact only when the element is sorted by the ranked
  # expression in the matching direction (mirrors the RUNNING_*/INDEX viz-formula
  # contract). Must precede the bare RANK( rewrite — though `\bRANK\(` can't match
  # `RANK_UNIQUE(` (the underscore), handle it explicitly so it stops falling
  # through to "untranslatable" (the enterprise top-N idiom: RANK_UNIQUE(SUM(x)) <= 25).
  if s.gsub!(/\bRANK_UNIQUE\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*(?:,\s*'(?:asc|desc)'\s*)?\)/, 'RowNumber()')
    hints << 'RANK_UNIQUE(expr)→RowNumber() — unique rank; VERIFY the element is sorted by the ranked expr (RowNumber follows the viz sort). For a top-N filter (RANK_UNIQUE(...)<=N) prefer a Sigma Top-N filter.'
    changed = true
  end

  # RANK([col], 'desc') / RANK([col]) / RANK_DENSE / RANK_PERCENTILE.
  # Tableau's RANK family defaults to DESCENDING; Sigma's defaults ascending —
  # the no-direction form must emit an explicit "desc" (WINPROBE-validated:
  # Rank(Sum(x), "desc") matches Tableau RANK(SUM(x)) exactly).
  if s.gsub!(/\bRANK\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*,\s*'(asc|desc)'\s*\)/, 'Rank(\1, "\2")')
    hints << "RANK→Rank"; changed = true
  end
  if s.gsub!(/\bRANK\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'Rank(\1, "desc")')
    hints << "RANK→Rank (Tableau default direction = desc)"
    changed = true
  end
  if s.gsub!(/\bRANK_DENSE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*,\s*'(asc|desc)'\s*\)/, 'RankDense(\1, "\2")')
    hints << "RANK_DENSE→RankDense"; changed = true
  end
  if s.gsub!(/\bRANK_DENSE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'RankDense(\1, "desc")')
    hints << "RANK_DENSE→RankDense (Tableau default direction = desc)"; changed = true
  end
  if s.gsub!(/\bRANK_PERCENTILE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*,\s*'(asc|desc)'\s*\)/, 'RankPercentile(\1, "\2")')
    hints << "RANK_PERCENTILE→RankPercentile"; changed = true
  end
  if s.gsub!(/\bRANK_PERCENTILE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'RankPercentile(\1, "desc")')
    hints << "RANK_PERCENTILE→RankPercentile (Tableau default direction = desc)"; changed = true
  end

  # Simple renames done AFTER table-calc rewrites so the table-calc patterns
  # match the original Tableau spelling.
  if s.gsub!(/\bZN\s*\(/, 'Coalesce(')
    # ZN takes one arg; pair the matching close-paren and append `, 0`. Walk
    # the string and balance parens to find the right `)`.
    out = String.new
    i = 0
    while i < s.length
      if s[i, 9] == 'Coalesce(' && (i == 0 || s[i - 1] !~ /\w/)
        out << 'Coalesce('
        depth = 1
        j = i + 9
        while j < s.length && depth > 0
          depth += 1 if s[j] == '('
          depth -= 1 if s[j] == ')'
          break if depth == 0
          j += 1
        end
        out << s[i + 9...j] << ', 0)'
        i = j + 1
      else
        out << s[i]
        i += 1
      end
    end
    s = out
    changed = true
  end
  if s.gsub!(/\bIIF\s*\(/, 'If(')
    changed = true
  end
  if s.gsub!(/\bIFNULL\s*\(/, 'Coalesce(')
    changed = true
  end
  if s.gsub!(/\bABS\s*\(/, 'Abs(')
    changed = true
  end
  if s.gsub!(/\bCOUNTD\s*\(/, 'CountDistinct(')
    changed = true
  end

  # SIZE() — no direct Sigma equivalent for partition size at the formula level.
  # Leave as-is and warn so the agent rewrites manually (commonly Count(*)+OVER).
  if s.include?('SIZE()')
    hints << 'SIZE() has no direct Sigma equivalent — rewrite as Count(*) in a non-grouping context or Custom SQL'
  end

  # FIRST() / LAST() — special.
  if s.include?('FIRST()')
    hints << 'FIRST() → RowNumber() - 1 (Tableau FIRST is 0-indexed first row)'
  end
  if s.include?('LAST()')
    hints << 'LAST() → no direct Sigma equivalent — use a Count() - RowNumber() pattern or Custom SQL'
  end

  # DATEPART('iso-year', x) — Sigma DatePart has NO iso-year / iso-week
  # precision (its "weekday" is 1-7 Sunday-start). Verified equivalent
  # (live-checked vs Snowflake YEAROFWEEKISO, 2026-06-11): the ISO year of x is
  # the calendar Year() of the THURSDAY of x's ISO week:
  #   Year(DateAdd("day", 3 - Mod(DatePart("weekday", x) + 5, 7), x))
  # (DatePart("weekday")+5 mod 7 maps Mon→0..Sun→6; 3-that shifts to Thursday.)
  while (m = s.match(/\bDATEPART\s*\(\s*['"]iso-year['"]\s*,\s*((?:[^()]|\([^()]*\))+?)\s*\)/i))
    arg = m[1]
    s = s.sub(m[0], %(Year(DateAdd("day", 3 - Mod(DatePart("weekday", #{arg}) + 5, 7), #{arg}))))
    hints << %(DATEPART('iso-year')→Year(DateAdd("day", 3 - Mod(DatePart("weekday", x) + 5, 7), x)) — Thursday-of-ISO-week; Sigma DatePart has no iso-year precision)
    changed = true
  end
  if s =~ /\bDATEPART\s*\(\s*['"]iso-week(?:number)?['"]/i
    hints << "DATEPART('iso-week') has no verified Sigma formula equivalent — use a Custom SQL DM element (Snowflake WEEKISO(x)) or derive from the iso-year Thursday shift"
  end

  # FINDNTH(s, sub, n) → 1-based index of the nth occurrence of sub in s
  # (0 when there are fewer than n occurrences). Verified Sigma composition
  # (live-checked vs warehouse SQL, 2026-06-11) via the array functions:
  #   If(ArrayLength(SplitToArray(s, sub)) > n,
  #      Len(ArrayJoin(ArraySlice(SplitToArray(s, sub), 0, n), sub)) + 1, 0)
  # i.e. rejoin the first n split-segments and measure the prefix length.
  # NB: Sigma ArraySlice's start index is 0-BASED — ArraySlice(arr, 0, n) is
  # the first n elements; start=1 silently skips the first segment (every
  # result lands past the (n+1)th occurrence; caught live vs SPLIT_PART SQL).
  while (m = s.match(/\bFINDNTH\s*\(\s*([^,()]*(?:\([^()]*\))?[^,()]*)\s*,\s*([^,()]+?)\s*,\s*([^,()]+?)\s*\)/i))
    str_a, sub_a, n_a = m[1].strip, m[2].strip, m[3].strip
    s = s.sub(m[0],
              "If(ArrayLength(SplitToArray(#{str_a}, #{sub_a})) > #{n_a}, " \
              "Len(ArrayJoin(ArraySlice(SplitToArray(#{str_a}, #{sub_a}), 0, #{n_a}), #{sub_a})) + 1, 0)")
    hints << 'FINDNTH→SplitToArray/ArraySlice/ArrayJoin composition (result 1-based; ArraySlice start 0-based; 0 when fewer than n occurrences)'
    changed = true
  end

  # LOD calcs — Tableau's `{FIXED [dim] : AGG([m])}` family.
  # Translation strategy (Sigma):
  #   {FIXED [dims] : AGG([m])}   → AUTO-BUILT when plotted as a chart/KPI
  #                                 measure: hidden two-level grouped helper
  #                                 element (inner = FIXED dims computing the
  #                                 LOD aggregate, outer = chart dims computing
  #                                 the 2nd-stage aggregate) — see
  #                                 parse_fixed_lod/build_two_stage_helper.
  #   {FIXED : SUM([m])}          → unscoped `Sum([m])` (workbook-level scalar)
  #   nested {FIXED…{FIXED…}}     → handled UPSTREAM by decompose_nested_fixed
  #                                 (helper-element chain + -lod-chains.json
  #                                 sidecar); the calc loop `next`s before this
  #                                 translator runs, so no double hint.
  #   {INCLUDE [dim] : SUM([m])}  → add [dim] to chart grouping and just use Sum
  #   {EXCLUDE [dim] : SUM([m])}  → remove [dim] from chart grouping, use Sum
  # INCLUDE/EXCLUDE need the chart's grouping context — surfaced as manual
  # hints, not auto-emitted.
  if s =~ /\{\s*FIXED\s+\[([^\]]+)\]\s*:\s*(SUM|AVG|MIN|MAX|COUNT|COUNTD)\s*\(\[([^\]]+)\]\)\s*\}/i
    dim, agg, m = $1, $2.upcase, $3
    hints << "FIXED LOD → auto-built as a hidden grouped helper element when plotted (inner grain = [#{dim}], " \
             "#{agg}(#{m}); 2nd-stage agg at chart grain) ⚠ carried chart dims must be functionally dependent on the FIXED dims"
    changed = true
  end
  if s =~ /\{\s*FIXED\s*:\s*(SUM|AVG|MIN|MAX|COUNT|COUNTD)\s*\(\[([^\]]+)\]\)\s*\}/i
    agg, m = $1.upcase, $2
    sigma_agg = { 'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
                  'COUNT' => 'Count', 'COUNTD' => 'CountDistinct' }[agg]
    hints << "FIXED-no-dim LOD → workbook scalar metric #{sigma_agg}([Master/#{m}]) (no group by)"
    changed = true
  end
  if (mi = s.match(/\{\s*INCLUDE\s+((?:\[[^\]]+\]\s*,?\s*)+):\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\[([^\]]+)\]\)\s*\}/i))
    dims, agg = mi[1].scan(/\[([^\]]+)\]/).flatten.join(', '), mi[2].upcase
    hints << "INCLUDE LOD on [#{dims}] → AUTO-BUILT as a hidden grouped helper when plotted as a chart measure " \
             "(inner = INCLUDE dims below the view, 2nd-stage agg at view grain); elsewhere add [#{dims}] to the grouping"
    changed = true
  end
  if (me = s.match(/\{\s*EXCLUDE\s+((?:\[[^\]]+\]\s*,?\s*)+):\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\[([^\]]+)\]\)\s*\}/i))
    dims, agg = me[1].scan(/\[([^\]]+)\]/).flatten.join(', '), me[2].upcase
    composable = %w[SUM MAX MIN COUNT].include?(agg)
    hints << if composable
               "EXCLUDE LOD on [#{dims}] (#{agg}) → AUTO-BUILT as a hidden grouped helper when plotted (value at " \
               'view minus the excluded dims, broadcast); composable agg, exact'
             else
               "EXCLUDE LOD on [#{dims}] uses #{agg} (not composable as agg-of-agg) → STAYS MANUAL: re-author at the coarser grain"
             end
    changed = true
  end

  return [nil, nil] unless changed
  hints.uniq!
  # Family rule (corrected 2026-07-15, probe-window-contexts.rb): Sigma-native
  # window functions (Rank/RankDense/RankPercentile/Lag/Lead/RowNumber/
  # Cumulative*/Moving*/PercentOfTotal) resolve to real OVER() as chart-element
  # viz formulas on the yAxis AND in table calc columns (grouped + ungrouped)
  # AND in DM-element calc columns — no Custom SQL needed. Only the *Over family
  # (SumOver/MaxOver/...) is 'Unknown function' in every spec context.
  hints << 'NOTE: emit as a CHART-element viz formula on the yAxis (the default, WINPROBE-verified); table / DM-element calc columns are also valid. Never the *Over functions — see refs/window-functions.md' if hints.any? { |h| h =~ /Rank|Lag|Lead|RowNumber|Cumulative|Moving/ }
  [s, hints.join('; ')]
end

# ---- Tableau window table-calcs → Sigma-native chart formulas --------------
# WINPROBE-validated design (bead 427, 2026-06-12; 930/930 cells exact vs the
# warehouse on ONE DM base element, ZERO Custom SQL):
#
#   RUNNING_SUM/AVG/MAX/MIN/COUNT(agg)        → Cumulative*(agg)
#   WINDOW_AVG/SUM/MAX/MIN/COUNT(agg, -n, 0)  → Moving*(agg, n)
#   WINDOW_*(agg, -n, m)                      → Moving*(agg, n, m)
#   WINDOW_STDEV(agg, -n[, m])                → MovingStdDev(agg, n[, m])
#   agg / WINDOW_SUM(agg)   (unbounded share) → PercentOfTotal(agg, "grand_total")
#   RUNNING_SUM(agg) / TOTAL(agg)   (pareto)  → CumulativeSum(PercentOfTotal(agg, "grand_total"))
#   RANK / RANK_DENSE / RANK_PERCENTILE(agg)  → Rank/RankDense/RankPercentile(agg, "desc")
#   INDEX()                                   → RowNumber()
#   LOOKUP(agg, -n) / LOOKUP(agg, n)          → Lag(agg, n) / Lead(agg, n)
#   unbounded WINDOW_MAX/MIN/SUM, TOTAL(agg)  → TWO-LEVEL grouped helper element
#     (outer grouping = partition dims, inner = addressing dims; the chart
#     consumer re-aggregates Max/Min — NEVER Sum: group calcs broadcast to
#     base-grain rows, so a Sum would multiply by the row count)
#
# Family rule (corrected 2026-07-15): these Sigma-native window functions are
# first-class as chart-element viz formulas on the yAxis (the emitted default)
# AND resolve in table calc columns (grouped + ungrouped) and DM-element calc
# columns — location is not the gate. Cumulative*/rank functions follow the
# chart's xAxis sort and auto-partition by the chart's color/series dim. Only
# the *Over family (SumOver/MaxOver/...) is 'Unknown function' in every spec
# context — never emit those. Re-verify contexts with probe-window-contexts.rb.
#
# STAYS MANUAL (flagged, never guessed): WINDOW_MEDIAN / WINDOW_PERCENTILE /
# WINDOW_CORR / WINDOW_COVAR(P) / WINDOW_VARP (population) / WINDOW_STDEVP,
# PREVIOUS_VALUE, SIZE(), FIRST()/LAST(), RANK_MODIFIED, and any
# compute-using/addressing override beyond the default Table(Across) / simple
# partition ("restart every", pane-relative, compute-along-non-axis-dim).
# NOW MAPPED (2026-06-18): RANK_UNIQUE→RowNumber (sort-following, like INDEX),
# WINDOW_VAR (sample)→MovingVariance — Sigma shipped MovingVariance; the
# population variant WINDOW_VARP has no validated Sigma window fn, stays manual.
WINDOW_SIGMA_FNS = %w[
  CumulativeSum CumulativeAvg CumulativeMax CumulativeMin CumulativeCount
  MovingAvg MovingSum MovingMax MovingMin MovingCount MovingStdDev MovingVariance
  Rank RankDense RankPercentile RowNumber Lag Lead PercentOfTotal
].freeze

WINDOW_MANUAL_RE = /\b(?:WINDOW_(?:MEDIAN|PERCENTILE|CORR|COVARP?|VARP|STDEVP)|PREVIOUS_VALUE|RANK_MODIFIED)\s*\(|\b(?:SIZE|FIRST|LAST)\s*\(\s*\)/i

# Case-SENSITIVE on purpose: .twb formulas carry canonical UPPERCASE Tableau
# function names, and the post-rewrite leftover check must not match the
# translated Sigma names (Rank/Lookup-the-join-fn/...).
WINDOW_TC_RE = /\b(?:RUNNING_[A-Z]+|WINDOW_[A-Z]+|RANK(?:_[A-Z]+)?|INDEX|LOOKUP|TOTAL|PREVIOUS_VALUE)\s*\(|\bSIZE\s*\(\s*\)/

# Classify + translate a Tableau window table-calc into its Sigma-native form.
# Returns nil when the formula has no window construct (caller proceeds on the
# normal paths), otherwise a hash:
#   { 'mode' => 'inline',    'formula' => <Sigma formula over [Master/...]>,
#                            'follows_sort' => bool, 'note' => ... }
#   { 'mode' => 'two-stage', 'stage_agg' => 'Max|Min|Sum', 'retrieve_agg' =>
#                            'Max|Min', 'value_formula' => <inner agg>, 'note' => ... }
#   { 'mode' => 'manual',    'note' => why }
# v5.0-P2: structured record of every window-calc translation, for the VDS
# table-calc oracle (scripts/vds-oracle.rb — Tableau computes the ORIGINAL
# calc server-side and the values are compared in Phase 6). Recorded thin at
# the translation sites, then ENRICHED against the built elements
# (enrich_window_calcs!) — element ids, the value column, and the addressing
# dims come from the emitted chart itself, the only place they're authoritative
# (review-caught: guessing dims from zone['channels'] yielded [] always).
$window_calc_records = []
def record_window_calc(zone, calc, plan, mode: nil)
  return unless plan
  $window_calc_records << {
    'id'              => "wc-#{$window_calc_records.size + 1}",
    'worksheet'       => zone && zone['caption'],
    'element_id'      => nil, # enrich_window_calcs! fills from the built element
    'calc_name'       => calc && (calc['caption'] || calc['name']).to_s.gsub(/^\[|\]$/, ''),
    'tableau_formula' => calc && calc['formula'],
    'sigma_formula'   => plan['formula'],
    'mode'            => mode || plan['mode'],
    'dims'            => [],
    'filters_present' => !(zone && Array(zone['filters']).empty?),
    'translator_note' => plan['note']
  }
end

# Fill element_id/element_name/column_id/dims/datasource_caption from the
# BUILT elements (must run while elements still carry _worksheet, i.e. before
# the output modes strip the tags). dims = the chart's category axis / pivot
# grouping columns — in the mechanical path their Sigma names ARE the Tableau
# captions (master columns are caption-named), which is what VDS addresses by.
def enrich_window_calcs!(records, elements, ds_plan)
  by_ws = elements.group_by { |e| e['_worksheet'] }
  ws_to_ds_caption = {}
  if ds_plan && ds_plan['datasources'].is_a?(Array)
    dominant = ds_plan['datasources'].max_by { |d| (d['worksheets'] || []).size }
    ds_plan['datasources'].each do |d|
      (d['worksheets'] || []).each { |w| ws_to_ds_caption[w.to_s.strip.downcase] = d['caption'] }
    end
    ws_to_ds_caption.default = dominant && dominant['caption']
  end
  records.each do |r|
    # Match by the translated formula when the plan carried one; a mode
    # without a formula (manual / top-n-filter) still binds to the
    # worksheet's element by name — its VALUE column is then the yAxis /
    # values column, never a blank-formula include-all match (review-caught:
    # include?('') matched the x-axis column and starved dims).
    sf = r['sigma_formula'].to_s
    ws_els = by_ws[r['worksheet']] || []
    el = (sf.empty? ? nil : ws_els.find { |e| (e['columns'] || []).any? { |c| c['formula'].to_s.include?(sf) } }) ||
         ws_els.first
    next unless el
    r['element_id']   = el['id']
    r['element_name'] = el['name']
    vcol = (!sf.empty? && (el['columns'] || []).find { |c| c['formula'].to_s.include?(sf) }) || nil
    if vcol.nil?
      vids = []
      vids.concat(Array(el.dig('yAxis', 'columnIds')).map { |x| x.is_a?(Hash) ? x['columnId'] : x })
      vids.concat(Array(el['values']))
      vcol = (el['columns'] || []).find { |c| vids.include?(c['id']) }
    end
    r['column_id']   = vcol && vcol['id']
    r['column_name'] = vcol && vcol['name']
    cols_by_id = (el['columns'] || []).each_with_object({}) { |c, h| h[c['id']] = c }
    dim_ids = []
    dim_ids << el.dig('xAxis', 'columnId') if el.dig('xAxis', 'columnId')
    dim_ids.concat(Array(el['rowsBy']).map { |x| x.is_a?(Hash) ? x['id'] : x })
    dim_ids.concat(Array(el['columnsBy']).map { |x| x.is_a?(Hash) ? x['id'] : x })
    r['dims'] = dim_ids.compact.uniq.map { |cid| cols_by_id[cid] }.compact
                       .reject { |c| c['id'] == r['column_id'] }
                       .map { |c| { 'caption' => c['name'] } }
    dsc = ws_to_ds_caption[r['worksheet'].to_s.strip.downcase] || ws_to_ds_caption.default
    r['datasource_caption'] = dsc if dsc
  end
end

def translate_window_calc(formula, mmap, columns_by_guid = {}, depth: 0)
  s = formula.to_s.gsub(/\s+/, ' ').strip
  # v5.1: a LEADING unary minus on a window-share pill or a bare calc ref is a
  # Tableau DESC-sort trick (`-WINDOW_MAX(share)`, `-[CalcRef]`). Strip it and
  # carry the flag — the minus must NEVER reach a column name/formula (the
  # round-4 `Sum([Master/-WINDOW_MAX(…)])` class died here). SCOPED to those
  # two shapes only: a minus on any other window calc (-RUNNING_SUM(…)) is a
  # genuine negation and keeps its sign through the generic path
  # (review-caught: the blanket strip silently changed those values).
  negated = false
  if s.start_with?('-') && s[1..-1].to_s.strip =~ /\A(?:WINDOW_(?:MAX|MIN|AVG)\s*\(|\[[^\]]+\]\z)/i
    negated = true
    s = s[1..-1].to_s.strip
  end
  # v5.1: one-level calc-ref dereference — a bare `[CalcRef]` whose formula is
  # known resolves to that formula and re-enters. Allowed at depth 0 AND 1
  # (Rule T1 hands the RANK operand in at depth 1 — review-caught: gating on
  # depth.zero? made the T1 ref path dead); depth 2 stops the recursion.
  if depth < 2 && (ref = s[/\A\[([^\]]+)\]\z/, 1])
    info = columns_by_guid[ref] || columns_by_guid.values.find { |v| v.is_a?(Hash) && v['caption'].to_s == ref }
    if info.is_a?(Hash) && info['formula'].to_s =~ WINDOW_TC_RE
      plan = translate_window_calc(info['formula'], mmap, columns_by_guid, depth: depth + 1)
      return plan && plan.merge('negated_for_sort' => (negated || plan['negated_for_sort'] || false))
    end
  end
  # v5.4: EMBEDDED calc-ref inlining (one hop). Tableau authors routinely split
  # a share across two serialized <calculation>s — [Total X] = TOTAL(SUM([X]))
  # and [% X] = SUM([X]) / [Total X] — so the window construct never appears in
  # the referring formula's own text and every classifier below is blind to it
  # (the calc translated as an unresolvable plain ref, or worse, a co-shelf
  # positional calc was picked instead). Substitute each embedded ref whose
  # KNOWN formula carries a window construct: verbatim when that formula is a
  # single closed call (TOTAL(...) — keeps the share regexes matchable), else
  # parenthesized for precedence safety. Gated to formulas that do NOT already
  # match WINDOW_TC_RE, so it strictly ADDS translations (previous nil returns)
  # and never re-routes a formula the classifiers already handled.
  if depth < 2 && s !~ WINDOW_TC_RE
    single_call = lambda do |f|
      return false unless f =~ /\A[A-Za-z_][A-Za-z0-9_]*\s*\(/ && f.end_with?(')')
      d = 0
      f.each_char.with_index do |ch, i|
        d += 1 if ch == '('
        if ch == ')'
          d -= 1
          return false if d.negative?
          return false if d.zero? && i < f.length - 1
        end
      end
      d.zero?
    end
    inlined = false
    s2 = s.gsub(/\[([^\]]+)\]/) do
      ref = Regexp.last_match(1)
      whole = Regexp.last_match(0)
      info = columns_by_guid[ref] ||
             columns_by_guid.values.find { |v| v.is_a?(Hash) && v['caption'].to_s.strip == ref }
      f = info.is_a?(Hash) ? info['formula'].to_s.gsub(/\s+/, ' ').strip : ''
      if !f.empty? && f =~ WINDOW_TC_RE
        inlined = true
        single_call.call(f) ? f : "(#{f})"
      else
        whole
      end
    end
    s = s2 if inlined
  end
  return nil if s.empty? || s !~ WINDOW_TC_RE
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end

  if (mm = s.match(WINDOW_MANUAL_RE))
    return { 'mode' => 'manual',
             'note' => "uses #{mm[0].sub(/\s*\(\s*\)?\z/, '')}() — no validated Sigma chart-formula mapping (stays manual; port via Custom SQL or re-author in Sigma)" }
  end

  agg_src = '(?:SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[[^\]]+\]\s*\)'
  norm = ->(x) { x.to_s.gsub(/\s+/, '').downcase }
  tx_agg = ->(a) { translate_user_agg_formula(a, mmap, {}) }

  # v5.1 Rule W1 — window-wrapped share (the round-4 exit-4 class):
  # WINDOW_MAX|MIN|AVG( agg/TOTAL(agg) | agg/WINDOW_SUM(agg) | agg1/agg2 ).
  # The wrapper flattens to the partition max in Tableau but all three round-4
  # runs (and their anchors) treat it as the per-cell share for DISPLAY —
  # value-identical when the window is a single cell (nested addressing) or
  # shares are uniform. The emit layer picks the PercentOfTotal scope from the
  # pivot axes; the VDS oracle re-checks every emission (window-calcs.json).
  if (w1 = s.match(%r{\A\s*WINDOW_(MAX|MIN|AVG)\s*\(\s*(#{agg_src})\s*/\s*(?:(?:WINDOW_SUM|TOTAL)\s*\(\s*(#{agg_src})\s*\)|(#{agg_src}))\s*\)\s*\z}i))
    num = w1[2]
    if w1[3] && norm.call(num) == norm.call(w1[3]) # same-agg → percent of total
      inner = tx_agg.call(num)
      return { 'mode' => 'manual', 'note' => 'window-wrapped share whose inner aggregate did not translate' } unless inner
      return { 'mode' => 'inline-share', 'share_kind' => 'percent_of_total',
               'inner' => inner, 'wrapper' => "WINDOW_#{w1[1].upcase}",
               'negated_for_sort' => negated,
               'note' => "WINDOW_#{w1[1].upcase}(share) treated as the per-cell share for display; " \
                         'exact when the window is a single cell — VDS oracle verifies' }
    elsif w1[4] # different-agg ratio
      a = tx_agg.call(num)
      b = tx_agg.call(w1[4])
      return { 'mode' => 'manual', 'note' => 'window-wrapped ratio whose aggregates did not translate' } unless a && b
      return { 'mode' => 'inline-share', 'share_kind' => 'ratio',
               'inner' => "#{a} / #{b}", 'wrapper' => "WINDOW_#{w1[1].upcase}",
               'negated_for_sort' => negated,
               'note' => "WINDOW_#{w1[1].upcase}(ratio) treated as the per-cell ratio for display — VDS oracle verifies" }
    end
  end

  # Top-N idiom: RANK(<expr>)<=N or RANK_UNIQUE(<expr>)<=N (bead pnxp).
  # The generic rewrite below collapses RANK_UNIQUE(<expr>) → RowNumber() and
  # DROPS <expr> entirely, which is only correct when the element is sorted by
  # <expr> — and is value-WRONG when <expr> is an untranslatable LOD ({exclude…}
  # /{include…}/{fixed…}). Intercept the top-N filter shape here so the operand
  # is never silently discarded:
  #   (a) <expr> reduces cleanly to a Sigma aggregate → RowNumber()<=N AND record
  #       the ranked measure so the caller can sort the tile by it (RowNumber
  #       follows the viz sort).
  #   (b) <expr> does NOT reduce (LOD operand) → STAY MANUAL: never emit a
  #       sort-dependent RowNumber()<=N with the operand gone.
  if (tn = s.match(/\A\s*RANK(?:_UNIQUE)?\s*\(\s*(.+?)\s*(?:,\s*'(?:asc|desc)'\s*)?\)\s*(<=|>=|<|>)\s*(\d+)\s*\z/i))
    operand, op, n = tn[1], tn[2], tn[3]
    # RANK_UNIQUE assigns 1..N with NO ties (like ROW_NUMBER); RANK ties on equal
    # values. A Sigma top-n filter mirrors this via rankingFunction. Only the
    # `<=N` / `<N` shapes are a FIXED-COUNT top-N (keep the N highest-ranked);
    # `>=N` / `>N` keep "everything ranked N or worse" — NOT a fixed bottom-N
    # count, so they only get the inline/manual note (no top-n filter).
    ranking  = (tn[0] =~ /_UNIQUE/i) ? 'row-number' : 'rank'
    row_count = (op == '<=') ? n.to_i : (op == '<' ? n.to_i - 1 : nil)  # nil ⇒ not a top-n filter
    ranked = translate_user_agg_formula(operand, mmap, {})
    base = { 'top_op' => op, 'ranking' => ranking, 'operand_raw' => operand.to_s.gsub(/\s+/, ' ') }
    base['top_n'] = row_count if row_count
    if ranked
      # Clean aggregate operand: caller emits a real Sigma Top-N FILTER keyed on
      # this measure when top_n is set. Keep the legacy inline RowNumber() form +
      # ranked_measure for the measure-on-yAxis path, which now auto-sorts the
      # tile by the ranked measure (bead pnxp).
      filt = row_count ? "Sigma top-#{row_count} filter ranked by #{ranked[0..70]}" : "RowNumber() #{op} #{n} on a tile sorted by #{ranked[0..70]}"
      return base.merge('mode' => 'inline', 'formula' => "RowNumber() #{op} #{n}",
               'follows_sort' => true, 'ranked_measure' => ranked,
               'note' => "RANK#{tn[0] =~ /_UNIQUE/i ? '_UNIQUE' : ''}(expr) #{op} #{n} top-N → #{filt}")
    end
    # v5.1 Rule T1: a RANK operand that is (a ref to) a WINDOW-WRAPPED SHARE
    # classifies as topn-prefilter — the rank-limited pre-filtered source
    # table all three round-4 runs hand-built, now mechanical.
    if row_count && depth.zero?
      share_plan = translate_window_calc(operand, mmap, columns_by_guid, depth: 1)
      if share_plan && share_plan['mode'] == 'inline-share'
        return base.merge('mode' => 'topn-prefilter', 'top_n' => row_count,
                 'operand_share' => share_plan,
                 'note' => "RANK(<window share>) #{op} #{n}: keep the top #{row_count} entities by their " \
                           'max per-partition share — emit the rank-limited pre-filtered source table ' \
                           '(refs/fidelity-recipes.md §Ranked pivot)')
      end
    end
    # Untranslatable LOD operand: cannot key a filter on a measure we couldn't
    # build. STAY MANUAL, but carry the parsed top-N facts so the caller can
    # surface a precise, actionable instruction (build the LOD helper measure,
    # then a top-n filter ranked by it) — never a sort-dependent RowNumber().
    return base.merge('mode' => 'manual',
             'note' => "top-N over an untranslatable LOD operand (#{operand.to_s.gsub(/\s+/, ' ')[0..80]}) — build the LOD helper as a Sigma measure, then a Sigma #{row_count ? "top-#{row_count}" : 'top-N'} filter ranked by it; never a sort-dependent RowNumber() #{op} #{n} with the operand dropped")
  end

  # Unbounded share-of-total: AGG / WINDOW_SUM(AGG) or AGG / TOTAL(AGG) on the
  # SAME aggregate. Both denominators are the grand total of the partition; the
  # `TOTAL(SUM(x))` form is how Tableau authors most often write share-of-total.
  if (m = s.match(%r{\A\s*(#{agg_src})\s*/\s*(?:WINDOW_SUM|TOTAL)\s*\(\s*(#{agg_src})\s*\)\s*\z}i)) &&
     norm.call(m[1]) == norm.call(m[2])
    inner = tx_agg.call(m[1])
    return { 'mode' => 'manual', 'note' => 'share-of-total whose inner aggregate did not translate' } unless inner
    return { 'mode' => 'inline', 'follows_sort' => false,
             'formula' => %(PercentOfTotal(#{inner}, "grand_total")),
             'note' => 'agg/WINDOW_SUM(agg) or agg/TOTAL(agg) → PercentOfTotal(agg, "grand_total")' }
  end

  # Pareto: RUNNING_SUM(AGG) / TOTAL(AGG) on the SAME aggregate.
  if (m = s.match(%r{\A\s*RUNNING_SUM\s*\(\s*(#{agg_src})\s*\)\s*/\s*TOTAL\s*\(\s*(#{agg_src})\s*\)\s*\z}i)) &&
     norm.call(m[1]) == norm.call(m[2])
    inner = tx_agg.call(m[1])
    return { 'mode' => 'manual', 'note' => 'pareto whose inner aggregate did not translate' } unless inner
    return { 'mode' => 'inline', 'follows_sort' => true,
             'formula' => %(CumulativeSum(PercentOfTotal(#{inner}, "grand_total"))),
             'note' => 'RUNNING_SUM(agg)/TOTAL(agg) pareto → CumulativeSum(PercentOfTotal(agg, "grand_total")) — accumulation follows the xAxis sort' }
  end

  # Standalone unbounded WINDOW_MAX/MIN/SUM or TOTAL → two-level grouped helper.
  if (m = s.match(/\A\s*(?:WINDOW_(MAX|MIN|SUM)|(TOTAL))\s*\(\s*(#{agg_src})\s*\)\s*\z/i))
    inner = tx_agg.call(m[3])
    return { 'mode' => 'manual', 'note' => 'unbounded window aggregate whose inner aggregate did not translate' } unless inner
    stage = (m[1] || 'SUM').upcase
    return { 'mode' => 'two-stage',
             'stage_agg' => { 'MAX' => 'Max', 'MIN' => 'Min', 'SUM' => 'Sum' }[stage],
             'retrieve_agg' => stage == 'MIN' ? 'Min' : 'Max',
             'value_formula' => inner,
             'note' => "unbounded #{m[2] ? 'TOTAL' : "WINDOW_#{stage}"} → two-level grouped helper; consumer re-aggregates #{stage == 'MIN' ? 'Min' : 'Max'} (NEVER Sum — group calcs broadcast to base-grain rows)" }
  end

  # Generic inline path: rewrite the window tokens (translate_tableau_tc now
  # carries the full validated mapping), then translate the inner aggregates.
  rewritten, _hint = translate_tableau_tc(s)
  rewritten ||= s
  if (left = rewritten.match(WINDOW_TC_RE))
    return { 'mode' => 'manual',
             'note' => "window construct #{left[0].sub(/\s*\(\s*\)?\z/, '')}() has no validated mapping in this shape (stays manual)" }
  end
  final = translate_user_agg_formula(rewritten, mmap, {}, extra_fns: WINDOW_SIGMA_FNS)
  return { 'mode' => 'manual', 'note' => 'window formula did not reduce to translated aggregates + arithmetic glue' } unless final
  return nil unless WINDOW_SIGMA_FNS.any? { |f| final =~ /\b#{f}\s*\(/ }
  { 'mode' => 'inline', 'formula' => final,
    'follows_sort' => !!(final =~ /\b(?:Cumulative\w+|Moving\w+|RowNumber|Lag|Lead)\s*\(/),
    'note' => 'window table-calc → Sigma viz formula on the chart yAxis' }
end

# Hidden two-level grouped helper for UNBOUNDED partitioned window aggregates
# (WINDOW_MAX/MIN/SUM, TOTAL). Generalizes build_two_stage_helper to multiple
# stage calcs sharing one inner value column (a pivot with both WINDOW_MAX and
# WINDOW_MIN builds ONE helper):
#   outer grouping (g1) = the PARTITION dims (chart color / pivot rowsBy;
#                         a constant "All Rows" key when unpartitioned)
#   inner grouping (g2) = the ADDRESSING dims (chart x / pivot columnsBy),
#                         computing the inner aggregate (the window's operand)
#   stage cols          = stage_agg over the inner GROUP values, broadcast to
#                         base-grain rows when a chart re-aggregates the helper
# The consumer references stages via Max()/Min() — NEVER Sum (broadcast-down).
def build_window_helper(el_id:, master_id:, partition_dims:, addressing_dims:,
                        value_name:, value_formula:, stages:)
  src_id = "#{el_id}-win-src"
  src_name = "#{value_name.sub(/ Window Base\z/, '')} Window Source (#{el_id.sub(/^el-(kpi-)?/, '')})"
  outer = partition_dims.empty? ? [{ 'name' => 'All Rows', 'formula' => '1' }] : partition_dims
  outer_cols = outer.each_with_index.map do |d, i|
    { 'id' => "#{src_id}-p#{i}", 'name' => d['name'], 'formula' => d['formula'] }
  end
  inner_cols = addressing_dims.each_with_index.map do |d, i|
    { 'id' => "#{src_id}-a#{i}", 'name' => d['name'], 'formula' => d['formula'] }
  end
  value_col = { 'id' => "#{src_id}-v", 'name' => value_name, 'formula' => value_formula }
  stage_cols = stages.each_with_index.map do |st, i|
    { 'id' => "#{src_id}-s#{i}", 'name' => st['name'], 'formula' => "#{st['agg']}([#{value_name}])" }
  end
  element = {
    'id' => src_id, 'kind' => 'table', 'name' => src_name,
    'source' => { 'kind' => 'table', 'elementId' => master_id },
    'columns' => outer_cols + inner_cols + [value_col] + stage_cols,
    'groupings' => [
      { 'id' => "#{src_id}-g1", 'groupBy' => outer_cols.map { |c| c['id'] },
        'calculations' => stage_cols.map { |c| c['id'] } },
      { 'id' => "#{src_id}-g2", 'groupBy' => inner_cols.map { |c| c['id'] },
        'calculations' => [value_col['id']] }
    ],
    'visibleAsSource' => false
  }
  [element, src_name]
end

# Hidden helper CHAIN for an AGGREGATE-DERIVED DIMENSION (calc-on-calc; y9rd.13).
# A Tableau dimension defined by BUCKETING an aggregate metric, e.g.
#   High Margin Flag = IF [Margin Pct] > 0.3 THEN "High" ELSE "Low" END
#   Margin Pct       = SUM([Gross Profit]) / SUM([Gross Revenue])
# A metric can't be a grouping dimension, and the bucket can't be a row-level DM
# column (it references aggregates), so the converter reports it as an
# `aggregate-dimension` workbookPattern (y9rd.11). The build layer materialises
# it as a TWO-element chain (chart then sources the 2nd):
#   INNER (grouped by the chart's BASE dims — the view's OTHER dims; whole-table
#     when none): its GROUP CALCULATIONS are the referenced aggregate metric(s)
#     + the tile measure, so each aggregate becomes a row-level value per group.
#   PASSTHRU (sources INNER *WITH groupingId* so it reads the grouped grain — the
#     verified table→table pattern; a chart source SILENTLY DROPS groupingId and
#     would read base-grain rows with the aggregate REPEATED, fanning the measure
#     ×row-count): an UNGROUPED element exposing the measure + base dims + the
#     BUCKET column (row-level over the grouped rows). The chart sources PASSTHRU
#     (now one row per base group, no broadcast), groups by the bucket, and
#     re-aggregates the measure — value-correct (live-verified 116,557.3 exact vs
#     the de-fanned warehouse total; a chart-direct source fanned it to 82.2M).
# bucket_name/bucket_formula: the dimension caption + its Sigma If/Case body, the
# latter with metric/base refs still in bare [Name] form (rewritten here onto the
# inner element). base_dims/agg_metrics/measure carry [Master/…] formulas.
def build_aggregate_dim_helper(el_id:, master_id:, base_dims:, agg_metrics:, measure:,
                               bucket_name:, bucket_formula:)
  stem = el_id.sub(/^el-(kpi-)?/, '')
  inner_id = "#{el_id}-aggdim-in"
  inner_name = "#{stem} AggDim Inner"
  pass_id = "#{el_id}-aggdim"
  pass_name = "#{stem} AggDim"
  inner_grp = "#{inner_id}-g"
  base = base_dims.empty? ? [{ 'name' => 'All Rows', 'formula' => '1' }] : base_dims
  base_cols   = base.each_with_index.map { |d, i| { 'id' => "#{inner_id}-b#{i}", 'name' => d['name'], 'formula' => d['formula'] } }
  metric_cols = agg_metrics.each_with_index.map { |m, i| { 'id' => "#{inner_id}-m#{i}", 'name' => m['name'], 'formula' => m['formula'] } }
  meas_col    = { 'id' => "#{inner_id}-v", 'name' => measure['name'], 'formula' => measure['formula'] }
  inner = {
    'id' => inner_id, 'kind' => 'table', 'name' => inner_name,
    'source' => { 'kind' => 'table', 'elementId' => master_id },
    'columns' => base_cols + metric_cols + [meas_col],
    'groupings' => [{ 'id' => inner_grp, 'groupBy' => base_cols.map { |c| c['id'] },
                      'calculations' => (metric_cols + [meas_col]).map { |c| c['id'] } }],
    'visibleAsSource' => false
  }
  # Rewrite the bucket's [Metric]/[BaseDim] refs onto the inner element (cross-
  # element refs resolve at the grouped grain the passthru reads).
  bucket = bucket_formula.to_s.dup
  (agg_metrics.map { |m| m['name'] } + base_dims.map { |d| d['name'] }).each do |nm|
    bucket = bucket.gsub(/\[#{Regexp.escape(nm)}\]/i, "[#{inner_name}/#{nm}]")
  end
  pass_cols = base_dims.each_with_index.map { |d, i| { 'id' => "#{pass_id}-b#{i}", 'name' => d['name'], 'formula' => "[#{inner_name}/#{d['name']}]" } }
  pass_cols << { 'id' => "#{pass_id}-v", 'name' => measure['name'], 'formula' => "[#{inner_name}/#{measure['name']}]" }
  pass_cols << { 'id' => "#{pass_id}-bk", 'name' => bucket_name, 'formula' => bucket }
  passthru = {
    'id' => pass_id, 'kind' => 'table', 'name' => pass_name,
    'source' => { 'kind' => 'table', 'elementId' => inner_id, 'groupingId' => inner_grp },
    'columns' => pass_cols,
    'visibleAsSource' => false
  }
  [inner, passthru, pass_name]
end

# ---- Nested FIXED LOD decomposition (beads-sigma-t67b) ----------------------
# Tableau allows LODs inside LODs:
#   {FIXED [Region] : AVG({FIXED [Region], [Customer Id] : SUM([Sales])})}
# Sigma formulas can't nest aggregates, but the verified pattern is a CHAIN of
# helper elements: the INNERMOST LOD becomes helper element 1 (a DM/workbook
# element grouped by its dims, with the aggregate as its Value column); each
# OUTER level consumes the previous helper via a cross-element ref
# `[LOD Helper k/Value]` (relationship keyed on the shared dims), and the
# outermost expression lands on the chart/master.
# CRITICAL (live-verified 2026-06-11): when chaining workbook elements, the
# outer element's source MUST set `groupingId` to the inner element's grouping
# (`source: {kind: table, elementId: <helper-k>, groupingId: <its grouping>}`).
# Without it the child reads BASE-grain rows with the grouped aggregate
# REPEATED per row, so Avg/Median/Count at the outer level silently come out
# row-weighted (caught live: row-weighted 969.82 vs correct 687.81 per-customer
# Avg on DEMO_DB.DEMO.ORDER_FACT). Custom SQL `GROUP BY` subqueries per level are
# the equivalent alternative. decompose_nested_fixed
# returns nil for non-nested formulas — SINGLE-level FIXED takes the verified
# two-level helper AUTO path instead (parse_fixed_lod / build_two_stage_helper
# above; see the dispatch note on parse_fixed_lod) — and otherwise:
#   { 'chain' => [{helper, dims, tableau_body, sigma_aggregate}, ...]  # innermost first
#     'final' => "<outermost expr with [LOD Helper k/Value] refs>" }
LOD_AGG_FN = { 'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
               'COUNT' => 'Count', 'COUNTD' => 'CountDistinct', 'MEDIAN' => 'Median' }.freeze

def decompose_nested_fixed(formula)
  return nil unless formula.to_s.scan(/\{\s*FIXED/i).length >= 2
  s = formula.gsub(/\s+/, ' ').strip
  chain = []
  k = 0
  # Innermost-first: a {FIXED ...} whose body holds no further brace. After
  # each substitution the next-outer level becomes brace-free and matches.
  while (m = s.match(/\{\s*FIXED\s*([^:{}]*):\s*([^{}]+?)\s*\}/i))
    k += 1
    dims = m[1].scan(/\[([^\]]+)\]/).flatten
    body = m[2].strip
    agg_m = body.match(/\A(SUM|AVG|MIN|MAX|COUNT|COUNTD|MEDIAN)\s*\((.+)\)\z/i)
    sigma_body = agg_m ? "#{LOD_AGG_FN[agg_m[1].upcase]}(#{agg_m[2].strip})" : body
    helper = "LOD Helper #{k}"
    chain << { 'helper' => helper, 'dims' => dims,
               'tableau_body' => body, 'sigma_aggregate' => sigma_body }
    s = s.sub(m[0], "[#{helper}/Value]")
    break if k > 8 # guard against pathological inputs
  end
  return nil if chain.length < 2
  { 'chain' => chain, 'final' => s }
end

# ---- Parameter / CASE translator ------------------------------------------
# Tableau CASE-on-parameter:
#   CASE [Parameters].[Analysis Type]
#     WHEN "Customer Type" THEN [CUSTOMER_TYPE]
#     WHEN "Overall"       THEN "Overall"
#     WHEN "Region"        THEN [REGION_NAME]
#     ELSE "Country"
#   END
# Sigma:
#   Switch([Analysis Type], "Customer Type", [Customer Type], "Overall",
#          "Overall", "Region", [Region Name], "Country")
#
# We accept the slightly-loose form Tableau uses (`Case` token-case insensitive,
# bracket refs for parameter and for dim columns, mixed quoted strings).
# Remap the RESULT side of a param Switch/If branch (a column ref, sibling calc,
# or string literal) onto the canonical Sigma `[Master/<name>]` form the
# validator accepts. UUID refs resolve via columns_by_guid → caption → master
# map; bare [Name] refs map by caption. Control refs ([ctl-...]) and string
# literals pass through untouched. Mirrors translate_dim_calc's master_ref so
# parameter-driven calcs resolve the same way plain dim calcs already do
# (without this, branch refs stayed as raw Tableau UUIDs / sibling-calc names
# and validate-spec rejected them as "bare ref … not a sibling column").
# A param-driven Switch compares the CONTROL value to each case literal. Sigma
# list/segmented controls are text-typed, so a bare-number case literal (from a
# Tableau `WHEN 1`) makes Sigma reject the Switch: "Argument N invalid … Expected
# text; received number." Quote bare numeric case literals so they match the
# text control. Leave already-quoted strings and non-numeric tokens untouched.
# Canonicalise a Switch match value so a param CONTROL's option value and the
# translated Switch's WHEN key compare equal regardless of numeric form. Tableau
# stores list-parameter member values as FLOATS ("0.", "1.", "2.0") but writes
# CASE `WHEN 0` as an INTEGER — so the control emits value "0." while the Switch
# key is "0", and Sigma's Switch matches NOTHING (the picker renders blank).
# Verified live 2026-07-07 (metric-switch E2E). Fold both to a canonical numeric
# string ("0."→"0", "1.0"→"1", "2.5"→"2.5"); non-numerics pass through.
def canonical_switch_value(v)
  s = v.to_s.strip.gsub(/\A["']|["']\z/, '')
  if s =~ /\A-?\d+(?:\.\d*)?\z/ || s =~ /\A-?\.\d+\z/
    f = s.to_f
    return (f == f.to_i ? f.to_i.to_s : f.to_s)
  end
  s
end

def coerce_case_literal(v)
  s = v.to_s.strip
  return s if s.start_with?('"') || s.start_with?("'")
  return "\"#{canonical_switch_value(s)}\"" if s =~ /\A-?\d+(?:\.\d*)?\z/ || s =~ /\A-?\.\d+\z/
  s
end

def remap_param_branch(expr, mmap, columns_by_guid)
  return expr if mmap.nil?
  s = expr.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = (columns_by_guid || {})[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end
  s = s.gsub(/\[([^\/\]]+)\]/) do
    inner = Regexp.last_match(1).strip
    if inner.start_with?('ctl-') || inner.include?('/')
      Regexp.last_match(0)
    else
      m = map_column(inner, mmap)
      # Use the master-map's LOGICAL name (bare, e.g. "Region") — the same form
      # the chart's grouping passthrough columns use and that the master source
      # resolves. A relationship-suffixed label like "Region (STORE_DIM)" is NOT
      # a master-map key and Sigma rejects it ("Dependency not found"); the
      # parentheses also break formula parsing.
      "[Master/#{m ? m['name'] : inner}]"
    end
  end
  # A measure-branch Switch (e.g. THEN SUM([X])) carries Tableau aggregate
  # function names; Sigma's library has Sum/Avg/CountDistinct/…, not SUM/COUNTD,
  # so an untranslated branch fails: "references function(s) not in Sigma's
  # library: SUM". Translate the common aggregate/function names (COUNTD before
  # COUNT so it isn't partially matched).
  { 'COUNTD' => 'CountDistinct', 'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min',
    'MAX' => 'Max', 'MEDIAN' => 'Median', 'COUNT' => 'Count', 'STDEV' => 'StdDev',
    'IIF' => 'If' }.each { |t, sg| s = s.gsub(/\b#{t}\s*\(/i, "#{sg}(") }
  s
end

def translate_case_on_param(formula, param_captions, mmap = nil, columns_by_guid = {})
  return nil unless formula =~ /\bCASE\b/i
  # Strip newlines + collapse spaces
  s = formula.gsub(/\s+/, ' ').strip
  m = s.match(/\bCASE\b\s+(.*?)\s+(WHEN\b.*?)\s+\bEND\b/i)
  return nil unless m
  param_ref = m[1].strip   # the value being switched, e.g. [Parameters].[X] or [X]
  body = m[2]
  # Pull WHEN ... THEN ... pairs + optional ELSE
  pairs = body.scan(/WHEN\s+(.+?)\s+THEN\s+(.+?)(?=\s+WHEN\b|\s+ELSE\b|\z)/i).map { |a, b| [a.strip, b.strip] }
  else_match = body.match(/\bELSE\b\s+(.+)\z/i)
  else_expr = else_match && else_match[1].strip
  return nil if pairs.empty?
  # Normalise parameter reference: prefer the human caption when we know it,
  # otherwise strip [Parameters].[...] wrapping.
  param_caption = nil
  if (mm = param_ref.match(/\[Parameters?(?:\s*\([^)]*\))?\]\s*\.\s*\[([^\]]+)\]/i))
    param_caption = mm[1]
  elsif (mm = param_ref.match(/\[([^\]]+)\]/))
    param_caption = mm[1] if param_captions.include?(mm[1])
  end
  return nil unless param_caption
  parts = [param_control_ref(param_caption)]
  # when_val = match literal (1, "Region", …) → keep; then_val = result column
  # ref → remap onto [Master/…].
  pairs.each { |when_val, then_val| parts << coerce_case_literal(when_val); parts << remap_param_branch(then_val, mmap, columns_by_guid) }
  parts << remap_param_branch(else_expr, mmap, columns_by_guid) if else_expr
  "Switch(#{parts.join(', ')})"
end

# Translate IF/ELSEIF chains on a parameter ref:
#   IF [Param] = "A" THEN x ELSEIF [Param] = "B" THEN y ELSE z END
# → Switch([Param], "A", x, "B", y, z)
def translate_if_chain_on_param(formula, param_captions, mmap = nil, columns_by_guid = {})
  s = formula.gsub(/\s+/, ' ').strip
  return nil unless s =~ /\bIF\b.*\bEND\b/i
  return nil unless param_captions.any? { |cap| s.include?("[#{cap}]") }
  m = s.match(/\bIF\b\s+(.+?)\s+\bEND\b/i)
  return nil unless m
  body = m[1]
  # Pull `<cond> THEN <result>` segments delimited by ELSEIF
  segs = body.scan(/(.+?)\s+THEN\s+(.+?)(?=\s+ELSEIF\b|\s+ELSE\b|\z)/i).map { |c, r| [c.strip, r.strip] }
  else_match = body.match(/\bELSE\b\s+(.+)\z/i)
  else_expr = else_match && else_match[1].strip
  return nil if segs.empty?
  # All conditions must be `[Param] = "..."` for the same parameter
  param_caption = nil
  cases = []
  segs.each do |cond, result|
    cm = cond.match(/\[([^\]]+)\]\s*=\s*("[^"]*"|'[^']*'|\S+)/)
    return nil unless cm
    p_cap = cm[1]
    return nil unless param_captions.include?(p_cap)
    param_caption ||= p_cap
    return nil unless p_cap == param_caption
    val = cm[2]
    val = val.gsub("'", '"') if val.start_with?("'")
    cases << coerce_case_literal(val) << remap_param_branch(result, mmap, columns_by_guid)
  end
  parts = [param_control_ref(param_caption)] + cases
  parts << remap_param_branch(else_expr, mmap, columns_by_guid) if else_expr
  "Switch(#{parts.join(', ')})"
end

# Bind a parameter-driven Switch onto the chart column(s) that carry the calc,
# in place, so the workbook CONTROL actually drives the value. Two column shapes:
#   • DIMENSION grouping passthrough → bare `[Master/<calc>]`      → replace with the Switch
#   • MEASURE (the metric-switch case) → `Agg([Master/<calc>])`    → keep the shelf
#     aggregate around a bare-branch Switch → `Agg(Switch(...))`; but if the
#     Switch branches are ALREADY aggregated (e.g. IF [P] THEN SUM(x) ELSE SUM(y)),
#     the Switch replaces the whole formula (no double aggregation).
# Returns the number of columns rewired. (Before this, only the exact bare form
# was matched, so measure/metric switches silently missed and the control drove
# nothing — an orphan un-aggregated Switch was appended instead. bead: param-msw.)
def rewire_param_switch!(columns, calc_name, switch_sibling)
  master_ref = "[Master/#{calc_name}]"
  pre_aggregated = switch_sibling =~ /\b(?:Sum|Avg|Min|Max|Count|CountDistinct|Median|StdDev|StdDevPop|Variance|VariancePop)\s*\(/
  rewired = 0
  (columns || []).each do |col|
    f = col['formula'].to_s.strip
    if f == master_ref
      col['formula'] = switch_sibling
    elsif (mw = f.match(/\A([A-Za-z]\w*)\(\s*#{Regexp.escape(master_ref)}\s*\)\z/))
      col['formula'] = pre_aggregated ? switch_sibling : "#{mw[1]}(#{switch_sibling})"
    else
      next
    end
    col.delete('column')
    rewired += 1
  end
  rewired
end

# ---- Converter param measure-pickers (workbookPatterns kind:param-switch) ----
# The Tableau→Sigma converter detects a parameter measure-picker
# (`CASE [Parameters].[P] WHEN v THEN <measure> … END`) and emits a clean
# `param-switch` workbookPattern: { name (the calc CAPTION), controlId, paramName,
# cases:[{when,then}], elseExpr, formula }. The build layer materialises it as a
# control-driven Switch — a single-select control under the EXACT controlId the
# converter baked into the formula, and the tile's MEASURE set to the Switch
# (branch results remapped onto the master columns). This auto-wires the recipe
# that was verified by hand (KPI=24) instead of leaving it a manual note.
#
# $param_switch_by_key bridges Calculation_NNN→caption: the layout references a
# picker calc by its internal `Calculation_<id>`, but the converter keys the
# pattern by the human caption — so we index BOTH (every Calculation_<id> whose
# .twb caption equals the pattern name) and the caption itself.
$param_switches = []
$param_switch_by_key = {}
$param_switch_used = [] # controlIds actually wired onto a tile — emit only these

def load_param_switches(wb_patterns_path, meta)
  return unless wb_patterns_path && File.exist?(wb_patterns_path)
  raw = (JSON.parse(File.read(wb_patterns_path)) rescue {})
  wp = raw['workbookPatterns'] || raw['workbook_patterns'] || []
  cbg = meta['columns_by_guid'] || {}
  cap_to_ids = Hash.new { |h, k| h[k] = [] }
  cbg.each { |gid, info| c = (info || {})['caption']; cap_to_ids[c.to_s.downcase] << gid if c && !c.to_s.empty? }
  wp.select { |p| p['kind'] == 'param-switch' }.each do |p|
    name = p['name'].to_s
    keys = ([name.downcase] + cap_to_ids[name.downcase].map(&:downcase)).uniq
    sw = { 'name' => name, 'control_id' => p['controlId'], 'param_name' => p['paramName'],
           'cases' => p['cases'] || [], 'else' => p['elseExpr'], 'keys' => keys }
    $param_switches << sw
    keys.each { |k| $param_switch_by_key[k] = sw }
  end
end

# Look up a param-switch by a chart header / field caption OR its Calculation_NNN
# internal id (any of several candidate refs). Returns the switch hash or nil.
def param_switch_for(*candidates)
  candidates.flatten.compact.each do |c|
    key = c.to_s.gsub(/^\[|\]$/, '').strip.downcase
    sw = $param_switch_by_key[key]
    return sw if sw
  end
  nil
end

# Normalize a parameter caption/name for dedup matching: strip Tableau's
# "[Parameters].[X]" wrapping and bare brackets, then case-fold. (jwsf)
def norm_param_caption(s)
  s.to_s.gsub(/\A\[Parameters\]\.\[|\]\z|\A\[|\]\z/, '').strip.downcase
end

# Index the parameter captions that drive a WIRED measure-picker Switch, so the
# auto-control loop can skip the redundant `ctl-param-<caption>` control (jwsf).
# The converter usually puts the parameter CAPTION directly in `param_name`
# ("Metric Picker"), but older paths put a GUID/key resolvable via
# columns_by_guid; index EVERY form so the dedup fires regardless. Returns a
# Set-like hash {normalized_caption => true}. Only pickers actually used on a
# tile count (an un-wired picker doesn't suppress its parameter's control).
def picker_param_caps_index(param_switches, used, columns_by_guid)
  idx = {}
  (param_switches || []).each do |sw|
    next unless (used || []).include?(sw['control_id'])
    [sw['param_name'], (columns_by_guid || {}).dig(sw['param_name'], 'caption')]
      .compact.reject { |x| x.to_s.strip.empty? }
      .each { |pc| idx[norm_param_caption(pc)] = true }
  end
  idx
end

# ---- Converter aggregate-derived dimensions (workbookPatterns kind:aggregate-
# dimension; y9rd.13) ---------------------------------------------------------
# The converter emits { kind:'aggregate-dimension', name (the calc CAPTION),
# formula (the Sigma-translated bucket, e.g. If([Margin Pct] > 0.3,"High","Low")),
# source, requires, note } for a dimension built by bucketing an aggregate metric
# (a metric can't be a grouping dim; the bucket can't be a row-level DM column).
# We index by the caption AND every Calculation_<id> whose .twb caption matches
# (a layout shelf references the calc by its internal id), and parse the bucket's
# bracketed refs as the aggregate metric(s) the helper must compute per group.
$agg_dims = []
$agg_dim_by_key = {}

def load_aggregate_dims(wb_patterns_path, meta)
  return unless wb_patterns_path && File.exist?(wb_patterns_path)
  raw = (JSON.parse(File.read(wb_patterns_path)) rescue {})
  wp = raw['workbookPatterns'] || raw['workbook_patterns'] || []
  cbg = meta['columns_by_guid'] || {}
  cap_to_ids = Hash.new { |h, k| h[k] = [] }
  cbg.each { |gid, info| c = (info || {})['caption']; cap_to_ids[c.to_s.downcase] << gid if c && !c.to_s.empty? }
  wp.select { |p| p['kind'] == 'aggregate-dimension' }.each do |p|
    name = p['name'].to_s
    refs = p['formula'].to_s.scan(/\[([^\]]+)\]/).flatten.map(&:strip)
                       .reject { |r| r.include?('/') || r.start_with?('ctl-') }.uniq
    keys = ([name.downcase] + cap_to_ids[name.downcase].map(&:downcase)).uniq
    ad = { 'name' => name, 'formula' => p['formula'], 'agg_refs' => refs, 'keys' => keys }
    $agg_dims << ad
    keys.each { |k| $agg_dim_by_key[k] = ad }
  end
end

# Look up an aggregate-dimension pattern by a chart dim caption OR its
# Calculation_<id> internal id (any candidate). Returns the pattern hash or nil.
def agg_dim_for(*candidates)
  candidates.flatten.compact.each do |c|
    key = c.to_s.gsub(/^\[|\]$/, '').strip.downcase
    ad = $agg_dim_by_key[key]
    return ad if ad
  end
  nil
end

# Build the inline, SIBLING-form Switch measure formula for a param-switch + the
# list of master columns the Switch's branches reference (to materialise as hidden
# passthrough siblings — a `[Master/X]` nested inside Switch() does NOT resolve
# standalone). Returns nil when a branch carries a chart-context-only window
# function (window_sum / running_* / rank / lookup) that can't live in an inline
# Switch — those stay surfaced as a migration note, never emitted broken.
def param_switch_inline(sw, mmap, cbg)
  branches = sw['cases'].map { |c| c['then'].to_s } + [sw['else'].to_s]
  # A branch carrying a chart-context-only window/table calc can't live in an
  # inline Switch — surface the whole picker as a note instead of emitting broken.
  return nil if branches.any? { |b| b =~ /\b(?:window_\w+|running_\w+|rank|index|lookup|previous_value|total)\s*\(/i }
  # Split the master-map into real COLUMNS (passthrough-able) vs aggregate METRICS
  # (entries that carry a `formula` — derive_master registers these NOT as master
  # columns but as inline aggregate formulas, e.g. "Signs - Actuals" =
  # CountDistinct([Master/STORE_ACCOUNT_ID])). A metric ref can't be a passthrough
  # sibling (the master table has no such column); it must be INLINED as its
  # formula — exactly what the normal measure path does (meas['formula']).
  col_names = {}
  metric_formulas = {}
  mmap.each_value do |v|
    next unless v.is_a?(Hash) && v['name']
    if v['formula'] && !v['formula'].to_s.empty?
      metric_formulas[v['name'].downcase] = v['formula']
    else
      col_names[v['name'].downcase] = true
    end
  end
  unresolved = []
  # Remap a branch result onto [Master/…], inline any metric refs to their formula,
  # then require every remaining ref to be the control or a real master COLUMN. A
  # branch that still references something the master can't carry — an un-emitted
  # calc, or a caption with a '/' like "TAM / CW" that remap skips (a slash signals
  # an already-qualified ref) — is replaced with Null so the OTHER options + the
  # control keep working (graceful degradation, never a broken dependency), and the
  # dropped option is recorded so it's surfaced (never silent).
  resolve_branch = lambda do |label, expr|
    return 'Null' if expr.nil? || expr.empty?
    r = remap_param_branch(expr, mmap, cbg)
    4.times do
      changed = false
      r = r.gsub(%r{\[Master/([^\]]+)\]}) do
        mf = metric_formulas[Regexp.last_match(1).downcase]
        if mf then changed = true; "(#{mf})" else Regexp.last_match(0) end
      end
      break unless changed
    end
    bad = r.scan(/\[([^\]]+)\]/).flatten.reject do |ref|
      ref.start_with?('ctl-') ||
        (ref.start_with?('Master/') && col_names[ref.sub(%r{\AMaster/}, '').downcase])
    end
    if bad.any?
      unresolved << label
      'Null'
    else
      r
    end
  end
  parts = ["[#{sw['control_id']}]"]
  sw['cases'].each do |c|
    parts << coerce_case_literal(%("#{c['when']}"))
    parts << resolve_branch.call(c['when'].to_s, c['then'].to_s)
  end
  parts << resolve_branch.call('(else)', sw['else'].to_s) if sw['else'] && !sw['else'].to_s.empty?
  # All branches unresolvable ⇒ nothing to plot; let it fall through to a note.
  return nil if unresolved.size >= sw['cases'].size && (sw['else'].nil? || sw['else'].to_s.empty? || unresolved.include?('(else)'))
  master_form = "Switch(#{parts.join(', ')})"
  branch_refs = master_form.scan(%r{\[Master/([^\]]+)\]}).flatten.uniq
  { 'sibling_form' => master_form.gsub(%r{\[Master/([^\]]+)\]}) { "[#{Regexp.last_match(1)}]" },
    'branch_refs' => branch_refs, 'control_id' => sw['control_id'], 'name' => sw['name'],
    'unresolved' => unresolved.uniq }
end

# Add hidden passthrough sibling columns ([Master/X] resolves standalone) for each
# branch ref, so the nested-in-Switch [X] refs resolve. Idempotent on name.
def add_switch_siblings!(element, branch_refs)
  existing = (element['columns'] ||= []).map { |c| c['name'] }.compact
  branch_refs.each do |b|
    next if existing.include?(b)
    bid = "swcol-#{b.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')
    element['columns'] << { 'id' => bid, 'name' => b, 'formula' => "[Master/#{b}]" }
    existing << b
  end
end

# Pick the Tableau format for a given header against a worksheet's formats dict.
# Match by best-effort: field ref contains a column GUID OR a friendly name
# fragment that overlaps with the header.
def pick_tableau_format(formats, header)
  return nil if formats.nil? || formats.empty?
  hkey = header.to_s.downcase.gsub(/\W+/, '')
  return nil if hkey.empty?
  formats.each do |field, val|
    # Friendly-name match: format key looks like `[usr:Return Rate:qk]` OR is
    # keyed by an internal id (`[usr:Calculation_AvgBal:qk]`) the KPI/measure
    # column carries under its CAPTION — format_key_match_keys bridges both.
    format_key_match_keys(field).each do |fkey|
      next unless fkey == hkey || hkey.include?(fkey) || fkey.include?(hkey)
      sigma = tableau_format_to_sigma(val)
      return sigma if sigma
    end
  end
  nil
end

# The RAW Tableau format string for a header (same matching loop as
# pick_tableau_format) — for formats the enum translator returns nil on
# (scale-comma + suffix), where the exact path is a Text() formula column.
def pick_tableau_format_raw(formats, header)
  return nil if formats.nil? || formats.empty?
  hkey = header.to_s.downcase.gsub(/\W+/, '')
  return nil if hkey.empty?
  formats.each do |field, val|
    format_key_match_keys(field).each do |fkey|
      return val if fkey == hkey || hkey.include?(fkey) || fkey.include?(hkey)
    end
  end
  nil
end

# ---- "Measure Names on rows" → ordered values[] members -------------------
# First-class the DDMX crosstab pattern (N bespoke calc measures stacked as the
# rows of a crosstab). z['measures'] is the parser's document-order walk of the
# worksheet's quantitative column-instances — i.e. the ORDERED Measure-Names
# members as Tableau renders them. Return them as add_col-shaped field hashes,
# IN ORDER, so build_pivot_element emits one ordered values[] entry per member:
#
#   - DROP dim-shaped entries (None / date-trunc derivations land in
#     z['measures'] too; a Sum() over a date silently corrupts the grid).
#   - A member whose caption matches a worksheet CALCULATION is emitted with
#     derivation 'usr' so it registers in user_vals and the User-derivation
#     resolver downstream translates its window/ratio formula (instead of the
#     blind Sum([Master/<calc name>]) that the SHELF_AGG fallback would emit and
#     which would HARD-FAIL the POST — the exact one-off-per-measure breakage
#     this recipe replaces).
#   - A plain warehouse measure keeps its OWN Tableau aggregation (Sum/Avg/
#     CountD/…); add_col then resolves its per-measure format from z['formats'].
#
# Returns [] when there are no measure members (caller falls back / warns).
def measure_names_members(z, meta)
  cbg = meta['columns_by_guid'] || {}
  calc_names = (z['calculations'] || []).map { |c| c['name'].to_s.gsub(/^\[|\]$/, '').strip.downcase }.reject(&:empty?)
  (z['measures'] || []).each_with_object([]) do |m, out|
    deriv = (m['derivation'] || 'Sum').to_s
    next if deriv == 'None' || DATE_TRUNC.key?(deriv)
    col_ref = m['column'].to_s
    guid = guid_from_text(col_ref)
    # Resolve the member's display caption (calc fields surface as a GUID /
    # Calculation_ internal id; the human caption lives in columns_by_guid).
    cap = (guid && cbg.dig(guid, 'caption')) ||
          col_ref.sub(/^\[[^\]]+\]\./, '').gsub(/^\[|\]$/, '').sub(/^[a-z]+:/i, '').sub(/:[a-z]+$/i, '')
    is_calc = calc_names.include?(cap.to_s.strip.downcase)
    out << {
      'role'       => 'measure',
      # 'usr' routes calc members to the User-derivation resolver (window/ratio
      # translation); plain measures keep their own warehouse aggregation.
      'derivation' => is_calc ? 'usr' : deriv.downcase,
      'raw'        => col_ref,
      'guid'       => guid
    }
  end
end

# ---- Pivot-table emission --------------------------------------------------
# Tableau crosstab worksheets (mark=Text or mark=Square with dims on both
# Rows AND Cols shelves, OR the Measure Names crosstab pattern) translate to
# a Sigma `pivot-table` element with `rowsBy` / `columnsBy` / `values` arrays,
# NOT a plain `table`. Without this, parse-twb-layout's `pivot-table` chart_kind
# would fall through to the default table builder and lose the pivot shape.
#
# Resolves shelf fields via the parser's columns_by_guid lookup + the master-
# column regex map. Returns the element hash, or nil if shelf info is unusable
# (caller falls back to the standard table/chart flow with a warning).
SHELF_AGG_FOR_PREFIX = {
  'sum' => 'Sum', 'avg' => 'Avg', 'min' => 'Min', 'max' => 'Max',
  'median' => 'Median', 'count' => 'CountIf(IsNotNull(%s))',
  # quick-calc pills abbreviate CountD as 'ctd' and Count as 'cnt'
  # ([pcto:ctd:seed:qk], [cnt:3 digit:qk] — corpus-verified); 'med'/'mdn' =
  # Median instance abbreviations
  'countd' => 'CountDistinct', 'cntd' => 'CountDistinct', 'ctd' => 'CountDistinct',
  'cnt' => 'CountIf(IsNotNull(%s))', 'med' => 'Median', 'mdn' => 'Median'
}.freeze
SHELF_TRUNC_FOR_PREFIX = {
  'yr' => 'year', 'qr' => 'quarter', 'mn' => 'month',
  'wk' => 'week', 'dy' => 'day', 'hr' => 'hour',
  # Tableau column-instance TRUNC derivations carry a 't' prefix ([tqr:GUID:qk]
  # = Quarter-Trunc); the bare forms above are kept for back-compat. Without
  # these, a date-trunc pivot shelf silently fell through to the RAW date
  # column and the grid exploded to day grain (caught by WINPROBE MaxMin).
  'tyr' => 'year', 'tqr' => 'quarter', 'tmn' => 'month',
  'twk' => 'week', 'tdy' => 'day', 'thr' => 'hour'
}.freeze

def resolve_shelf_field(field, meta, mmap)
  cols_by_guid = meta['columns_by_guid'] || {}
  guid = field['guid']
  cap_for_field = nil
  if guid
    info = cols_by_guid[guid]
    cap_for_field = info && info['caption']
  end
  # Bracket-stripped internal-name fallback (bead: KPI value fidelity). Tableau
  # calc columns are named `[Calculation_NNN]` or `[<Field> (copy)_NNN]` — NOT a
  # 36-char GUID — so guid_from_text() returns nil and the guid lookup above
  # misses. But `columns_by_guid` IS keyed by that internal name and carries the
  # real caption (e.g. a "…(validated)" calc). Without this the field falls back
  # to the raw `(copy)_NNN` string, map_column + the calc-formula lookup both
  # miss, and the KPI naively re-derives `Sum(rawcol)`.
  if cap_for_field.nil?
    raw_key = field['raw'].to_s
                          .sub(/^\[[^\]]+\]\./, '')
                          .gsub(/^\[|\]$/, '')
                          .sub(/^[a-z]+:/i, '')
                          .sub(/:[a-z]+$/i, '')
    info2 = cols_by_guid[raw_key]
    cap_for_field = info2 && info2['caption']
  end
  cap_for_field ||= field['raw'].to_s
                                 .sub(/^\[[^\]]+\]\./, '')
                                 .gsub(/^\[|\]$/, '')
                                 .sub(/^[a-z]+:/i, '')
                                 .sub(/:[a-z]+$/i, '')
  # Tableau captions sometimes carry trailing/leading whitespace (e.g. the
  # skeleton's "Order Date "), and the master column is the trimmed name — so a
  # bare [Master/Order Date ] ref won't resolve. Trim before matching + as the
  # fallback name (map_column already trims internally for the lookup).
  cap_for_field = cap_for_field.to_s.strip
  m = map_column(cap_for_field, mmap)
  m ||= { 'id' => "m-#{cap_for_field.downcase.gsub(/\W+/, '-')}", 'name' => cap_for_field }
  [m, cap_for_field]
end

def build_pivot_element(z, meta, mmap, opts, warnings, data_elements = [])
  cap = z['caption']
  el_id = "el-#{cap.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')
  rows_shelf = z['rows_shelf'] || {}
  cols_shelf = z['cols_shelf'] || {}

  cols_array = []
  rows_by    = []
  cols_by    = []
  values_arr = []
  seen_ids   = {}
  user_vals  = [] # User-derivation measures (window / ratio calcs) — resolved below

  add_col = lambda do |field, target, shelf = nil|
    m, _cap = resolve_shelf_field(field, meta, mmap)
    base = "p-#{el_id}-#{target}-#{(m['name'] || 'x').downcase.gsub(/\W+/, '-')}"
    col_id = base
    n = 1
    while seen_ids[col_id]
      col_id = "#{base}-#{n}"
      n += 1
    end
    seen_ids[col_id] = true

    deriv = field['derivation'].to_s.downcase
    formula =
      if field['role'] == 'measure' && deriv == 'pcto'
        # v5.1 (D1): Tableau's percent-of-total QUICK CALC shelf token
        # [pcto:<agg>:<col>:qk] — previously unmapped, fell through to a wrong
        # bare Sum. Scope = the axis the token sits on (live-verified: pcto in
        # cols shelf sums each COLUMN to 100%). PIVOT-ONLY partition modes per
        # round-3 consensus; the shelf context is only set on pivot paths.
        raw = (field['column'] || field['raw']).to_s
        iagg, icol = raw[/pcto:([a-z]+):([^:\]]+)/i, 1], raw[/pcto:[a-z]+:([^:\]]+)/i, 1]
        agg_fn = SHELF_AGG_FOR_PREFIX[iagg.to_s.downcase] || 'CountDistinct'
        inner_ref = "[Master/#{(meta['columns_by_guid'] || {}).dig(icol.to_s, 'caption') || icol || m['name']}]"
        inner = agg_fn.include?('%s') ? agg_fn.sub('%s', inner_ref) : "#{agg_fn}(#{inner_ref})"
        scope = shelf == :cols ? 'column' : (shelf == :rows ? 'row' : 'grand_total')
        %(PercentOfTotal(#{inner}, "#{scope}"))
      elsif field['role'] == 'measure' && deriv == 'rtot'
        # v5.1.2: running-total quick calc pills carry the same 4-segment
        # shape as pcto ([rtot:<agg>:<col>:qk]) — m['name'] keeps the extra
        # 'agg:' segment and emitted an unresolvable ref (review-caught).
        raw = (field['column'] || field['raw']).to_s
        riagg, ricol = raw[/rtot:([a-z]+):([^:\]]+)/i, 1], raw[/rtot:[a-z]+:([^:\]]+)/i, 1]
        if ricol
          agg_fn = SHELF_AGG_FOR_PREFIX[riagg.to_s.downcase] || 'Sum'
          inner_ref = "[Master/#{(meta['columns_by_guid'] || {}).dig(ricol.to_s, 'caption') || ricol}]"
          inner = agg_fn.include?('%s') ? agg_fn.sub('%s', inner_ref) : "#{agg_fn}(#{inner_ref})"
          "CumulativeSum(#{inner})"
        else
          "CumulativeSum(Sum([Master/#{m['name']}]))"
        end
      elsif field['role'] == 'measure'
        agg = SHELF_AGG_FOR_PREFIX[deriv] || 'Sum'
        if agg.include?('%s')
          agg.sub('%s', "[Master/#{m['name']}]")
        else
          "#{agg}([Master/#{m['name']}])"
        end
      elsif field['role'] == 'dim' && SHELF_TRUNC_FOR_PREFIX[deriv] == 'week'
        # Tableau weeks are Sunday-anchored; Sigma DateTrunc("week") follows
        # the warehouse week start (Monday on Snowflake) — use the verified
        # Sunday-anchored arithmetic instead (Weekday() is 1=Sunday).
        %(DateAdd("day", 1 - Weekday([Master/#{m['name']}]), DateTrunc("day", [Master/#{m['name']}])))
      elsif field['role'] == 'dim' && SHELF_TRUNC_FOR_PREFIX[deriv]
        %(DateTrunc("#{SHELF_TRUNC_FOR_PREFIX[deriv]}", [Master/#{m['name']}]))
      else
        "[Master/#{m['name']}]"
      end

    # A calc field referenced on a shelf surfaces by its INTERNAL id
    # (`Calculation_1466…` / `Calculation_summary`), which would render as an
    # ugly column header. Resolve it to the calc's human caption (captured in
    # columns_by_guid) when available — purely a display-name fix; the value
    # array, Switch branch refs, and ws_calc match all key off ids / the raw
    # name, so this is safe.
    display_name = m['name']
    if display_name.to_s =~ /\ACalculation_/i
      cbg_cap = (meta['columns_by_guid'] || {}).dig(display_name.to_s, 'caption')
      display_name = cbg_cap if cbg_cap && !cbg_cap.to_s.strip.empty? && cbg_cap.to_s !~ /\ACalculation_/i
    end
    col_obj = { 'id' => col_id, 'name' => display_name, 'formula' => formula }
    if field['role'] == 'measure'
      # PR-12: fall back to the column's .twb default-format when the sheet
      # has no per-pill format (still ahead of the master-map/heuristic).
      tab_fmt = pick_tableau_format(z['formats'], m['name']) ||
                pick_column_default_format(m['name'])
      col_obj['format'] = tab_fmt if tab_fmt
      col_obj['format'] ||= m['format'] if m['format'].is_a?(Hash)
      col_obj['format'] ||= { 'kind' => 'number', 'formatString' => ',.0f' }
    elsif SHELF_TRUNC_FOR_PREFIX[deriv]
      col_obj['format'] = { 'kind' => 'datetime', 'formatString' => '%b %Y' }
    end
    cols_array << col_obj
    # Carry the field's raw ref (its Calculation_<id> internal id) so a converter
    # param measure-picker can be matched by id, not just the resolved caption
    # (the Calculation_NNN→caption bridge — n4pi.10).
    user_vals << { 'col' => col_obj, 'name' => m['name'].to_s.strip,
                   'raw' => (field['column'] || field['raw']).to_s,
                   'shelf' => shelf } if target == :value && %w[usr user].include?(deriv)
    case target
    when :row   then rows_by    << { 'id' => col_id }
    when :col   then cols_by    << { 'id' => col_id }
    when :value then values_arr << col_id
    end
  end

  # v5.1 (D4): `:ok` qualified pills are Tableau's HIDDEN SORT KEYS, never
  # displayed values — enrolling them as pivot values shipped ghost columns
  # ("Rank N (copy)_…:ok:9"). Skip them; the shelf-sort path carries ordering.
  hidden_sort_pill = ->(f) { (f['column'] || f['raw']).to_s.include?(':ok') }
  (rows_shelf['fields'] || []).each do |f|
    next if hidden_sort_pill.call(f)
    add_col.call(f, :row, :rows)   if f['role'] == 'dim'
    add_col.call(f, :value, :rows) if f['role'] == 'measure'
  end
  (cols_shelf['fields'] || []).each do |f|
    next if hidden_sort_pill.call(f)
    add_col.call(f, :col, :cols)   if f['role'] == 'dim'
    add_col.call(f, :value, :cols) if f['role'] == 'measure'
  end

  # ---- "Measure Names on rows" crosstab recipe (first-classed) -------------
  # The DDMX-class pattern: a worksheet stacks N bespoke calc measures as the
  # rows of a crosstab (Measure Names on rows × week/quarter on columns) with
  # Measure Values in the pane. The shelves carry only the [Measure Names]
  # placeholder pill — the actual ORDERED members live in z['measures'] (the
  # parser walks them in .twb document order, which IS the displayed stack
  # order). Rather than treating each measure as a one-off, map the ordered
  # members → an ordered Sigma pivot `values[]` array, one column per measure,
  # in the same order Tableau renders them. add_col appends to values_arr in
  # call order, so iterating the members in order yields an ordered values[].
  #
  # Per-member resolution mirrors the chart-side Measure-Names path: a member
  # backed by a worksheet CALC is left for the User-derivation resolver below
  # (emitted with derivation 'usr' so it registers in user_vals and gets its
  # window/ratio formula translated), while a plain warehouse measure carries
  # its own Tableau aggregation (Sum/Avg/CountD/…) instead of a blind Sum().
  # Per-measure formats are picked by add_col from z['formats'] / the master
  # map, so each stacked value keeps its own number/percent/currency format.
  if values_arr.empty?
    members = measure_names_members(z, meta)
    members.each { |m| add_col.call(m, :value) }
  end

  if values_arr.empty? || (rows_by.empty? && cols_by.empty?)
    warnings << "'#{cap}' is flagged as a Tableau crosstab but shelves did not yield rows+cols+values — falling back to flat table"
    return nil
  end

  # User-derivation values: a pivot value with derivation=User is a Tableau
  # calc — the SHELF_AGG fallback above emitted an unresolvable
  # `Sum([Master/<calc name>])`. Resolve each against the worksheet calcs:
  #   - plain aggregated ratio → decomposed Sigma formula (inline)
  #   - UNBOUNDED window aggregate (WINDOW_MAX/MIN/SUM, TOTAL) → the pivot is
  #     rewired onto ONE hidden two-level grouped helper (outer grouping =
  #     rowsBy dims = the partition; inner = columnsBy dims = the addressing;
  #     Tableau's default Table(Across) windows across the pivot columns).
  #     WINPROBE-validated: consumer re-aggregates Max/Min, NEVER Sum.
  #   - anything else windowed (Cumulative*/Moving* inside a pivot grid) is
  #     UNVALIDATED in pivot context — dropped from the grid with a loud warn.
  win_stage = [] # { 'col' =>, 'plan' => }
  user_vals.each do |uv|
    # Converter param measure-picker (n4pi.10): if this value IS a param-switch
    # calc (matched by its resolved caption OR its Calculation_<id> internal id),
    # use the converter's CLEAN Switch — its cases are already resolved to captions,
    # so it bridges the Calculation_NNN→caption gap that re-translating the raw
    # Tableau formula below hits (the raw branch refs are [Calculation_<id>] sibling
    # refs that don't resolve, and the ws_calc lookup keys off the internal id while
    # this value keys off the caption). Materialize the [Master/Y] branch refs as
    # hidden sibling cols and rewrite to [Y] (nested [Master/Y] doesn't resolve).
    psw = param_switch_for(uv['name'], uv['raw'], uv['col']['name'])
    if psw && (plan = param_switch_inline(psw, mmap, meta['columns_by_guid'] || {}))
      existing_names = cols_array.map { |c| c['name'] }.compact
      plan['branch_refs'].each do |bn|
        next if existing_names.include?(bn)
        bid = "pvsw-#{bn.downcase.gsub(/\W+/, '-')[0..36]}".sub(/-$/, '')
        cols_array << { 'id' => bid, 'name' => bn, 'formula' => "[Master/#{bn}]" }
        existing_names << bn
      end
      uv['col']['formula'] = plan['sibling_form']
      $param_switch_used << plan['control_id'] unless $param_switch_used.include?(plan['control_id'])
      drp = plan['unresolved'].any? ? " (option(s) #{plan['unresolved'].join(', ')} show blank — their measure isn't a master column)" : ''
      warnings << "'#{cap}' pivot value '#{uv['name']}' → converter param measure-picker Switch over " \
                  "[#{plan['control_id']}] (#{psw['cases'].size} option(s))#{drp}: #{plan['sibling_form'].gsub(/\s+/, ' ')[0..100]}"
      next
    end
    ws_calc = (z['calculations'] || []).find do |c|
      c['name'].to_s.gsub(/^\[|\]$/, '').strip.casecmp?(uv['name'])
    end
    next unless ws_calc
    plan = translate_window_calc(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
    record_window_calc(z, ws_calc, plan, mode: 'pivot-value') if plan
    if plan.nil?
      # Parameter-driven Switch value (the "Switch Metric" class): a pivot value
      # like IF [Parameters].[X] = … THEN SUM([A]) ELSE SUM([B]) END becomes a
      # Switch over the parameter's CONTROL. Translate it (else it falls through
      # to the drop path and the workbook ships without the param control, since
      # nothing references [ctl-param-…]). Materialize the [Master/Y] branch refs
      # as hidden sibling columns on the pivot and rewrite to [Y] — a [Master/Y]
      # nested inside Switch() doesn't resolve standalone (same rule as charts).
      pv_param_caps = (meta['parameters'] || []).map { |p| p['caption'] }.compact
      pv_cbg = meta['columns_by_guid'] || {}
      # The Switch translators match a parameter by CAPTION, but a formula often
      # references it by internal NAME ([Parameters].[Parameter 5]). Normalize
      # name→caption first (same fix as the parser's parameter_refs) so the
      # translator recognizes it and builds the right [ctl-param-<caption>] ref.
      pv_pmap = {}
      (meta['parameters'] || []).each do |p|
        cap = p['caption']; nm = p['name'].to_s.gsub(/^\[|\]$/, '')
        pv_pmap[nm] = cap if cap && !nm.empty?
      end
      pv_formula = ws_calc['formula'].to_s.gsub(/(\[Parameters?\]\s*\.\s*\[)([^\]]+)(\])/i) do
        "#{Regexp.last_match(1)}#{pv_pmap[Regexp.last_match(2)] || Regexp.last_match(2)}#{Regexp.last_match(3)}"
      end
      pv_switch = translate_case_on_param(pv_formula, pv_param_caps, mmap, pv_cbg) ||
                  translate_if_chain_on_param(pv_formula, pv_param_caps, mmap, pv_cbg)
      if pv_switch
        existing_names = cols_array.map { |c| c['name'] }.compact
        pv_switch.scan(/\[Master\/([^\]]+)\]/).flatten.uniq.each do |bn|
          next if existing_names.include?(bn)
          bid = "pvsw-#{bn.downcase.gsub(/\W+/, '-')[0..36]}".sub(/-$/, '')
          cols_array << { 'id' => bid, 'name' => bn, 'formula' => "[Master/#{bn}]" }
          existing_names << bn
        end
        uv['col']['formula'] = pv_switch.gsub(/\[Master\/([^\]]+)\]/) { "[#{Regexp.last_match(1)}]" }
        warnings << "'#{cap}' pivot value '#{uv['name']}' → parameter-driven Switch over the control: " \
                    "#{uv['col']['formula'].gsub(/\s+/, ' ')[0..100]}"
        next
      end
      f = translate_user_agg_formula(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
      if f
        uv['col']['formula'] = f
        # Attainment/share ratios (a measure ÷ a goal/target/budget/quota) are
        # percentages by convention — the default ',.0f' would round e.g. 0.93 to
        # "1". Detect by the value name OR a goal/target denominator in the source
        # formula and apply a percent format. (Names like "Revenue Attainment"
        # would otherwise false-match the currency heuristic on "revenue".)
        if uv['name'].to_s =~ /attain|\bshare\b|sell[-\s]?through|win[-\s]?rate|conversion/i ||
           ws_calc['formula'].to_s =~ /\b(goal|target|budget|quota|plan|forecast)\b/i
          uv['col']['format'] = { 'kind' => 'number', 'formatString' => ',.1%' }
        end
        warnings << "'#{cap}' pivot value '#{uv['name']}' is a Tableau User-aggregated calc — decomposed: #{f[0..120]}"
      else
        # Can't decompose → its emitted Sum([Master/<calc>]) references a
        # column that doesn't exist and would HARD-FAIL the workbook POST
        # ("Dependency not found"), blocking the whole migration. Drop it from
        # the grid (same as the unvalidated-window path) so the core pivot
        # POSTs clean and only this value is flagged for manual re-authoring.
        cols_array.delete(uv['col'])
        values_arr.delete(uv['col']['id'])
        warnings << "'#{cap}' pivot value '#{uv['name']}' could not be auto-decomposed — dropped from the grid; " \
                    "re-author manually. Formula: #{ws_calc['formula'].to_s.gsub(/\s+/, ' ')[0..120]}"
      end
    elsif plan['mode'] == 'two-stage'
      win_stage << { 'col' => uv['col'], 'plan' => plan }
    elsif plan['mode'] == 'inline-share'
      # v5.4 Rule W1 emission (pivot): scope from the table-calc ADDRESSING
      # first. The twb serializes "compute using <dim>" as <table-calc
      # ordering-field=...> and the parser stamps it on the calc as
      # ordering_field — the share's denominator is the partition total ACROSS
      # that dim. Addressing dim on the pivot COLUMNS → each row sums to 100%
      # → "row"; on ROWS → "column". Only when no addressing resolves to a
      # pivot axis fall back to the value pill's own shelf (the v5.1
      # heuristic, which guessed wrong on row-normalized shares whose pill sat
      # elsewhere) — and name the fallback so a wrong scope is auditable.
      nqs = ->(x) { x.to_s.downcase.gsub(/[^a-z0-9]/, '') }
      addr = ws_calc['ordering_field']
      axis_has_addr = lambda do |entries|
        entries.any? do |e|
          c = cols_array.find { |x| x['id'] == e['id'] }
          c && addr && nqs.call(c['name']) == nqs.call(addr)
        end
      end
      scope, scope_src =
        if addr && axis_has_addr.call(cols_by)
          ['row', "table-calc addressing '#{addr}' rides the columns axis"]
        elsif addr && axis_has_addr.call(rows_by)
          ['column', "table-calc addressing '#{addr}' rides the rows axis"]
        else
          [uv['shelf'] == :cols ? 'column' : 'row',
           addr ? "addressing '#{addr}' not on either pivot axis — pill-shelf fallback, VERIFY scope" \
                : 'no table-calc addressing — pill-shelf fallback, VERIFY scope']
        end
      uv['col']['formula'] =
        if plan['share_kind'] == 'percent_of_total'
          %(PercentOfTotal(#{plan['inner']}, "#{scope}"))
        else
          plan['inner']
        end
      uv['col']['format'] = { 'kind' => 'number', 'formatString' => ',.1%' } if plan['share_kind'] == 'percent_of_total'
      warnings << "'#{cap}' pivot value '#{uv['name']}' → #{plan['wrapper']}(share) emitted as " \
                  "#{uv['col']['formula'][0..90]} [scope=#{scope}: #{scope_src}] [#{plan['note']}]"
    elsif plan['mode'] == 'inline' && plan['formula']
      # VALIDATED live 2026-06-24 (wb cd9058fe): Sigma accepts window functions
      # (PercentOfTotal(…, "grand_total"), CumulativeSum(…)) as pivot-table value
      # columns — they compile clean and render real values. Emit the translated
      # window formula as the pivot value instead of dropping it (the old
      # conservative "UNVALIDATED in pivot context" behaviour lost real measures
      # like share-of-total and running-total from migrated crosstabs).
      uv['col']['formula'] = plan['formula']
      # Window formulas that yield a 0–1 fraction (share-of-total, rank-percentile)
      # must carry a percent format, else the default ',.0f' rounds every cell to
      # "0" and the crosstab reads as all-zeros even though it computes correctly
      # (grand total = 1.0). Mirrors the chart-path override (PercentOfTotal→',.2%').
      case plan['formula']
      when /\A\s*(?:CumulativeSum\(PercentOfTotal|PercentOfTotal)\(/ then uv['col']['format'] = { 'kind' => 'number', 'formatString' => ',.2%' }
      when /\A\s*RankPercentile\(/ then uv['col']['format'] = { 'kind' => 'number', 'formatString' => ',.1%' }
      end
      sort_note = plan['follows_sort'] ? ' (accumulates along the pivot sort — verify order vs Tableau)' : ''
      warnings << "'#{cap}' pivot value '#{uv['name']}' → window formula in grid: " \
                  "#{plan['formula'].gsub(/\s+/, ' ')[0..100]}#{sort_note}"
    else
      note = plan['note'] || 'window aggregate did not translate'
      cols_array.delete(uv['col'])
      values_arr.delete(uv['col']['id'])
      warnings << "'#{cap}' pivot value '#{uv['name']}' STAYS MANUAL (#{note}) — dropped from the grid; " \
                  "rebuild by hand if needed. Formula: #{ws_calc['formula'].to_s.gsub(/\s+/, ' ')[0..120]}"
    end
  end

  source = { 'kind' => 'table', 'elementId' => opts[:master_id] }
  if win_stage.any?
    inner_formulas = win_stage.map { |w| w['plan']['value_formula'] }.uniq
    non_window_vals = values_arr.reject { |vid| win_stage.any? { |w| w['col']['id'] == vid } }
    if inner_formulas.size == 1 && non_window_vals.empty?
      row_dims = cols_array.select { |c| rows_by.any? { |r| r['id'] == c['id'] } }
      col_dims = cols_array.select { |c| cols_by.any? { |r| r['id'] == c['id'] } }
      value_name = "#{inner_formulas.first[/\[Master\/([^\]]+)\]/, 1] || header_base(win_stage.first['col']['name'])} Window Base"
      helper, src_name = build_window_helper(
        el_id: el_id, master_id: opts[:master_id],
        partition_dims: row_dims.map { |c| { 'name' => c['name'], 'formula' => c['formula'] } },
        addressing_dims: col_dims.map { |c| { 'name' => c['name'], 'formula' => c['formula'] } },
        value_name: value_name, value_formula: inner_formulas.first,
        stages: win_stage.map { |w| { 'name' => w['col']['name'], 'agg' => w['plan']['stage_agg'] } })
      data_elements << helper
      source = { 'kind' => 'table', 'elementId' => helper['id'] }
      (row_dims + col_dims).each { |c| c['formula'] = "[#{src_name}/#{c['name']}]" }
      win_stage.each { |w| w['col']['formula'] = "#{w['plan']['retrieve_agg']}([#{src_name}/#{w['col']['name']}])" }
      warnings << "'#{cap}' unbounded window pivot value(s) #{win_stage.map { |w| w['col']['name'] }.join(', ')} → " \
                  "hidden helper '#{src_name}' (partition = #{row_dims.map { |c| c['name'] }.join(', ')}; " \
                  "addressing = #{col_dims.map { |c| c['name'] }.join(', ')}) ⚠ verify in Sigma"
      warnings << "'#{cap}' window partition spans #{row_dims.size} dims — multi-dim partitions beyond a single " \
                  'split are UNTESTED; verify against Tableau' if row_dims.size > 1
    else
      win_stage.each do |w|
        cols_array.delete(w['col'])
        values_arr.delete(w['col']['id'])
      end
      warnings << "'#{cap}' mixes unbounded window value(s) with other measures / differing inner aggregates — " \
                  'helper rewiring only supports a uniform window pivot; the windowed value(s) were dropped (manual)'
    end
  end

  # v5.1.2: percent-of-total QUICK CALC riding the MARKS CARD (parser
  # quick_calc_pcto) — z['measures'] only carries the bare inner aggregate
  # (column-instance derivation), so the value shipped as raw counts where the
  # source renders percentages (review round: THE room-share pivot). Wrap the
  # matching value in PercentOfTotal; scope from the PctTotal table-calc's
  # addressing dim: addressing on the ROWS shelf → each column sums to 100% →
  # "column"; cols shelf → "row"; no/unresolved addressing → "grand_total".
  Array(z['quick_calc_pcto']).each do |qc|
    nq = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
    inner_cap = (meta['columns_by_guid'] || {}).dig(qc['col'].to_s, 'caption') || qc['col']
    qc_agg = SHELF_AGG_FOR_PREFIX[qc['agg'].to_s]
    # UNKNOWN prefix → agg-agnostic matching (the 0d206e2 behavior). A 'Sum'
    # fallback made both the handled-bail and the vcol match key on the wrong
    # aggregation and SILENTLY skipped the wrap (review-caught regression:
    # [pcto:cnt:…] shipped raw counts).
    qc_agg_name = qc_agg && qc_agg[/\A[A-Za-z]+/].to_s # 'CountIf(IsNotNull(%s))' → 'CountIf'
    warnings << "'#{cap}' pcto quick calc has UNKNOWN agg prefix '#{qc['agg']}' — matching by inner column only; verify the wrapped aggregation" if qc_agg_name.nil?
    # If a value already carries PercentOfTotal over the SAME inner (the pill
    # also rode a rows/cols shelf and add_col wrapped it), this quick calc is
    # HANDLED — bail before the loose match wraps a sibling raw value
    # (review-caught: dual-pill pivots corrupted the raw count column).
    handled = cols_array.any? do |c|
      values_arr.include?(c['id']) &&
        c['formula'].to_s =~ /\APercentOfTotal\(\s*#{qc_agg_name ? Regexp.escape(qc_agg_name) : '[A-Za-z]+'}/ &&
        (ir = c['formula'].to_s[%r{\[Master/([^\]]+)\]}, 1]) && nq.call(ir) == nq.call(inner_cap)
    end
    next if handled
    vcol = cols_array.find do |c|
      next false unless values_arr.include?(c['id'])
      next false if c['formula'].to_s.include?('PercentOfTotal(')
      # the AGGREGATION must match the pill's too when the prefix is KNOWN — a
      # crosstab can carry the same base column under two aggs (review-caught)
      next false if qc_agg_name && !c['formula'].to_s.start_with?("#{qc_agg_name}(")
      ref = c['formula'].to_s[%r{\[Master/([^\]]+)\]}, 1]
      ref && (nq.call(ref) == nq.call(inner_cap) || nq.call(c['name']) == nq.call(inner_cap))
    end
    next unless vcol
    addr_cap = (meta['columns_by_guid'] || {}).dig(qc['addressing'].to_s, 'caption') || qc['addressing']
    axis_of = lambda do |entries|
      entries.any? do |e|
        c = cols_array.find { |x| x['id'] == e['id'] }
        c && addr_cap && nq.call(c['name']) == nq.call(addr_cap)
      end
    end
    scope = if axis_of.call(rows_by) then 'column'
            elsif axis_of.call(cols_by) then 'row'
            else 'grand_total'
            end
    vcol['formula'] = %(PercentOfTotal(#{vcol['formula']}, "#{scope}"))
    # exact decimals from the pill's own text-format (p0.0% → ,.1%); with no
    # pill format, FORCE a percent format — add_col already stamped the
    # measure default ',.0f', which renders every share as 0 (review-caught:
    # the trailing default block only repairs nil/,.0% formats, not ,.0f).
    fkey = (z['formats'] || {}).keys.find { |k| k.to_s.downcase.include?("pcto:#{qc['agg']}:#{qc['col']}".downcase) }
    fmt = fkey && tableau_format_to_sigma((z['formats'] || {})[fkey])
    fmt ||= { 'kind' => 'number', 'formatString' => ',.1%' } unless vcol.dig('format', 'formatString').to_s.include?('%')
    vcol['format'] = fmt if fmt
    warnings << "'#{cap}' pivot value '#{vcol['name']}' is a marks-card percent-of-total quick calc → " \
                "PercentOfTotal(…, \"#{scope}\") [PctTotal addressing: #{addr_cap.inspect}]"
  end

  # v5.1: source shelf sorts (<shelf-sort-v2> — three rounds of ranked pivots
  # shipped alphabetical because this surface was never parsed). Resolve the
  # sorted dimension to its rowsBy/columnsBy entry and the sort measure to a
  # value column. GUARD (the opus trap, live-probed): a PercentOfTotal whose
  # scope is the SORTED axis is constant (100%) → the sort silently no-ops to
  # alphabetical; sort by the inner aggregate instead when detectable.
  Array(z['shelf_sorts']).each do |ss|
    norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
    axis = ss['shelf'].to_s == 'columns' ? cols_by : rows_by
    entry = axis.find do |e|
      col = cols_array.find { |c| c['id'] == e['id'] }
      col && norm.call(col['name']) == norm.call(ss['dimension'])
    end
    next unless entry
    by_col = cols_array.find { |c| values_arr.include?(c['id']) && norm.call(c['name']).include?(norm.call(ss['measure'])) } ||
             cols_array.find { |c| values_arr.include?(c['id']) }
    next unless by_col
    scope_word = ss['shelf'].to_s == 'columns' ? 'column' : 'row'
    if by_col['formula'].to_s =~ /PercentOfTotal\s*\(.*"#{scope_word}"\s*\)/
      warnings << "'#{cap}' pivot sort key '#{by_col['name']}' is PercentOfTotal(…,\"#{scope_word}\") — CONSTANT " \
                  'across the sorted axis (sorts alphabetically at render). Sort by the inner aggregate instead ' \
                  '(refs/fidelity-recipes.md §Ranked pivot).'
    else
      entry['sort'] = { 'direction' => ss['direction'] || 'ascending', 'by' => by_col['id'] }
      agg = by_col['formula'].to_s[/\A(Sum|Avg|Min|Max|Median|Count|CountDistinct)\(/, 1]
      entry['sort']['aggregation'] = agg.downcase if agg
      warnings << "'#{cap}' pivot #{ss['shelf']} sorted by '#{by_col['name']}' #{ss['direction']} (source shelf-sort)"
    end
  end

  # v5.1.1: legacy <computed-sort> fallback — "sort field X by measure Y" in
  # older workbooks lands ONLY here, not in <shelf-sort-v2>, and those pivots
  # shipped alphabetical (review-caught). Same emission + constant-key guard
  # as above; skipped whenever a shelf sort exists.
  if Array(z['shelf_sorts']).empty? && z['sort'].is_a?(Hash) && z['sort']['using']
    norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
    refname = lambda do |raw|
      tok = raw.to_s[/\[(?:[a-z\-]+:)?([^:\]]+?)(?::[a-z0-9]+)*\]\z/i, 1]
      info = (meta['columns_by_guid'] || {})[guid_from_text(raw.to_s)] ||
             (meta['columns_by_guid'] || {})[tok]
      (info && info['caption']) || tok
    end
    dim_name  = refname.call(z['sort']['column'])
    meas_name = refname.call(z['sort']['using'])
    (rows_by + cols_by).each do |entry|
      next if entry['sort']
      col = cols_array.find { |c| c['id'] == entry['id'] }
      next unless col && dim_name && norm.call(col['name']) == norm.call(dim_name)
      by_match = cols_array.find { |c| values_arr.include?(c['id']) && meas_name && norm.call(c['name']).include?(norm.call(meas_name)) }
      by_col = by_match || cols_array.find { |c| values_arr.include?(c['id']) }
      break unless by_col
      # v5.1.2: honesty on the fallback — the emitted key may not be the
      # source's sort measure (review: silent substitution masked a divergent
      # order behind a fidelity-claiming warning).
      if by_match.nil?
        warnings << "'#{cap}' computed-sort measure #{meas_name.inspect} is not among the pivot values — " \
                    "sorted by '#{by_col['name']}' instead; VERIFY the axis order against the source"
      end
      scope_word = cols_by.include?(entry) ? 'column' : 'row'
      if by_col['formula'].to_s =~ /PercentOfTotal\s*\(.*"#{scope_word}"\s*\)/
        warnings << "'#{cap}' pivot computed-sort key '#{by_col['name']}' is PercentOfTotal(…,\"#{scope_word}\") — " \
                    'CONSTANT across the sorted axis (sorts alphabetically at render). Sort by the inner aggregate ' \
                    'instead (refs/fidelity-recipes.md §Ranked pivot).'
      else
        entry['sort'] = { 'direction' => z['sort']['direction'] || 'ascending', 'by' => by_col['id'] }
        agg = by_col['formula'].to_s[/\A(Sum|Avg|Min|Max|Median|Count|CountDistinct)\(/, 1]
        entry['sort']['aggregation'] = agg.downcase if agg
        warnings << "'#{cap}' pivot sorted by '#{by_col['name']}' #{z['sort']['direction']} (source computed-sort)"
      end
      break
    end
  end

  el = {
    'id'        => el_id,
    'kind'      => 'pivot-table',
    'name'      => tile_title(z, cap),
    'source'    => source,
    'columns'   => cols_array,
    'values'    => values_arr,
    'rowsBy'    => rows_by,
    'columnsBy' => cols_by,
    # v5.1 defect-2 fix: Tableau pivots in this pipeline never show grand
    # totals; Sigma defaults them SHOWN. showSubtotals enum is only
    # always|when-collapsed ('hidden' is rejected) — when-collapsed is the
    # no-visible-subtotals setting for expanded pivots (live-probed).
    'totals'    => { 'showGrandTotals' => 'hidden', 'showSubtotals' => 'when-collapsed' }
  }
  # v5.1 defect-4 fix: heat scale from the SOURCE ramp (parser heat_scheme),
  # 3-point downsample; never a default accent. Value-format cascade: a
  # PercentOfTotal value with no matched format renders 1-decimal like the
  # corpus sources (defect-5).
  if z['heat_scheme'].is_a?(Array) && z['heat_scheme'].size >= 2 && values_arr.any?
    stops = z['heat_scheme']
    el['conditionalFormats'] = [{
      'type' => 'backgroundScale', 'columnIds' => values_arr.dup,
      'scheme' => [stops.first, stops[stops.size / 2], stops.last].uniq
    }]
  end
  cols_array.each do |c|
    next unless values_arr.include?(c['id'])
    next unless c['formula'].to_s.include?('PercentOfTotal(')
    fs = c.dig('format', 'formatString')
    c['format'] = { 'kind' => 'number', 'formatString' => ',.1%' } if fs.nil? || fs =~ /\A,?\.0%\z/
  end
  el
end

# v5.1: rank-limited PRE-FILTERED source table — mechanizes the pattern all
# three round-4 runs hand-built for RANK()<=N pivots. The list filter lives on
# a hidden TABLE element the pivot re-sources; element-level filters on the
# pivot itself silently do NOT prune its dimension (round-4 bisect-proven).
def build_topn_prefilter_helper(el_id:, master_id:, entity_col:, carry_cols:, members:)
  src_id = "#{el_id}-topn-src"
  src_name = "TopN Source (#{el_id.sub(/^el-/, '')})"
  # One passthrough column per DISTINCT base ref across ALL carry formulas —
  # a ratio measure Sum([Master/A])/Sum([Master/B]) needs BOTH A and B at row
  # grain (review-caught: a first-ref slice dropped every ref after the first,
  # and naming columns by the pivot header broke the re-pointed ref lookup).
  # Aggregates re-compute on the pivot, so bare refs are all it must carry.
  refs = carry_cols.flat_map { |c| c['formula'].to_s.scan(%r{\[Master/([^\]/]+)\]}).flatten }.uniq
  ent_name = entity_col['formula'].to_s[%r{\[Master/([^\]/]+)\]}, 1] || entity_col['name']
  refs << ent_name unless refs.include?(ent_name)
  cols = refs.each_with_index.map do |rn, i|
    { 'id' => "#{src_id}-c#{i}", 'name' => rn, 'formula' => "[Master/#{rn}]" }
  end
  ent = cols.find { |c| c['name'] == ent_name }
  {
    'id' => src_id, 'kind' => 'table', 'name' => src_name, 'visibleAsSource' => false,
    'source' => { 'kind' => 'table', 'elementId' => master_id },
    'columns' => cols,
    # 'id' is REQUIRED — the API rejects filters without one (round-6 field:
    # a 400 with a 507-line union dump traced to exactly this missing key).
    'filters' => [{ 'id' => "flt-#{src_id}-0", 'columnId' => ent['id'], 'kind' => 'list',
                    'mode' => 'include', 'selectionMode' => 'multiple', 'values' => members }]
  }
end

# Member resolution for the prefilter, in trust order:
#   (1) <tab>/topn-members.json — {calc_caption => [members]} fed by one probe
#       run (or by hand); array order = desired display (rank) order.
#   (2) a rendered view CSV that is ATTRIBUTABLE to this zone: either the
#       zone's own view (own_view_id) or a CSV whose headers cover the entity
#       dim PLUS at least one more of the element's own columns — a bare
#       entity-header match is NOT enough (v5.1.2 review-caught: 'Bi assets'
#       silently inherited another worksheet's member set from a different
#       datasource; disjoint domain → empty pivot reported as success).
# When the matched CSV also carries the rank pill's column, members come back
# SORTED BY RANK (the CSV row order is data order, NOT render order —
# live-checked: first-occurrence gave rank 3,1,2,8,…). Returns nil when no
# trustworthy source exists (caller writes the probe sidecar).
def topn_members_for(calc_caption, entity_name, opts, zone, element_cols: [], own_view_id: nil)
  mpath = File.join(opts[:tab], 'topn-members.json')
  bare_hit = nil
  if File.exist?(mpath)
    map = JSON.parse(File.read(mpath)) rescue {}
    # ZONE-SCOPED key first ('<zone caption>::<calc caption>') — two zones
    # routinely share one rank-calc name ('Rank N' on both fixture pivots),
    # and a caption-only key fed one zone the OTHER zone's roster
    # (review-caught, live-reproduced: disjoint domain → empty tile).
    zcap = zone.is_a?(Hash) ? zone['caption'].to_s : ''
    scoped = "#{zcap}::#{calc_caption}"
    hit = map[scoped] || map.find { |k, _| k.to_s.strip.casecmp?(scoped.strip) }&.last
    return hit if hit.is_a?(Array) && hit.any?
    # The BARE calc-caption key is legacy/ambiguous: it now ranks BELOW the
    # zone's own CSV evidence, and at most ONE zone per build may consume it
    # (review-caught: a legacy bare-key file fed a disjoint roster to a
    # second zone AND truncated a zone that had perfectly good CSV members).
    bh = map[calc_caption.to_s] || map.find { |k, _| k.to_s.strip.casecmp?(calc_caption.to_s.strip) }&.last
    if bh.is_a?(Array) && bh.any?
      # ownership is claimed at USE time (below), not lookup time — a zone
      # that resolves from its own CSV must not block another zone's fallback
      bare_hit = lambda do
        $topn_bare_consumers ||= {}
        owner = ($topn_bare_consumers[calc_caption.to_s] ||= zcap)
        if owner == zcap
          bh
        else
          warn "topn-members: bare key #{calc_caption.inspect} already consumed by zone #{owner.inspect} — " \
               "#{zcap.inspect} needs its own ZONE-SCOPED key (\"#{zcap}::#{calc_caption}\")"
          nil
        end
      end
    end
  end
  bare_hit ||= lambda { nil }
  # No entity → the members could never be APPLIED (the helper's list filter
  # needs the entity column) — do NOT consult the bare key here, or its
  # single-consumer claim starves the zone that can actually use it
  # (review-caught).
  return nil unless entity_name
  nrm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
  other_cols = element_cols.map { |c| nrm.call(c['name']) } - [nrm.call(entity_name)]
  best = nil # [coverage, rows, hdr]
  Dir.glob(File.join(opts[:tab], 'views', '*.csv')).sort.each do |csvp|
    rows = CSV.read(csvp, headers: true) rescue next
    hdr = rows.headers&.find { |h| h.to_s.strip.casecmp?(entity_name.to_s.strip) }
    next unless hdr
    own = own_view_id && File.basename(csvp, '.csv') == own_view_id.to_s
    coverage = (rows.headers.map { |h| nrm.call(h) } & other_cols).length
    next unless own || coverage >= 1
    score = (own ? 1000 : 0) + coverage
    best = [score, rows, hdr] if best.nil? || score > best[0]
  end
  return bare_hit.call unless best
  _, rows, hdr = best
  # Rank-ordered members when the CSV carries THE rank pill's column: the
  # header must BE 'rank' or the rank calc's caption (a containment match
  # let an ordinary 'Rank Points' data measure hijack the order —
  # review-caught). Tableau RANK is COMPETITION ranking — ties legitimately
  # share a value (a strict-permutation check threw away the whole ordering
  # on any tie; review-caught) — so accept duplicates and break ties by CSV
  # first-occurrence, but reject value ranges a rank can't have (a 'Rank
  # Points' 1500/2000 measure fails the bound).
  rank_h = rows.headers.find do |h|
    hn = nrm.call(h)
    (hn == 'rank' || hn == nrm.call(calc_caption)) && rows.first && rows.first[h].to_s =~ /\A\d+\z/
  end
  if rank_h
    by_rank = {}
    order   = {}
    rows.each do |r|
      m = r[hdr]
      next if m.nil?
      order[m.to_s] ||= order.size
      by_rank[m.to_s] ||= r[rank_h].to_i
    end
    plausible = by_rank.any? && by_rank.values.min.to_i >= 1 &&
                by_rank.values.max.to_i <= by_rank.size * 2
    return by_rank.keys.sort_by { |m| [by_rank[m], order[m]] } if plausible
  end
  vals = rows.map { |r| r[hdr] }.compact.map(&:to_s)
  vals.any? ? vals.uniq : bare_hit.call
end

# v5.1.1: shared top-N idiom detection — the CSV flow's inline lambda made the
# interception unreachable for pivots (the fast path `next`s out of the zone
# loop long before it; review-caught). Given ONE zone filter, return the
# translated plan (merged with keeps_true/calc_caption) or nil.
def detect_topn_plan(f, z, mmap, meta)
  norm = ->(x) { x.to_s.gsub(/^\[|\]$/, '').strip.downcase }
  ref = [f['column_caption'], f['raw_param']].compact.map(&:to_s).join(' ')
  calc = (z['calculations'] || []).find do |c|
    cap_n  = norm.call(c['caption'])
    name_n = norm.call(c['name'])
    next false if c['formula'].to_s !~ /\bRANK(?:_UNIQUE)?\s*\(/i
    (!cap_n.empty? && norm.call(f['column_caption']) == cap_n) ||
      (!name_n.empty? && ref.downcase.include?(name_n))
  end
  return nil unless calc
  plan = translate_window_calc(calc['formula'], mmap, meta['columns_by_guid'] || {})
  record_window_calc(z, calc, plan, mode: 'top-n-filter') if plan && plan['operand_raw']
  return nil unless plan && plan['operand_raw'] # only the top-N branch sets this
  # The filter must KEEP the top rows (member 'true'); a keep-false inverts it.
  kept = (f['members'] || []).map { |v| v.to_s.downcase }
  plan.merge('keeps_true' => kept.empty? || kept.include?('true'),
             'calc_caption' => calc['caption'] || calc['name'],
             # "compute using" dim from the calc's table-calc addressing — the
             # RANKED ENTITY (parser ordering_field, v5.1.1); nil on older twbs.
             'entity_ref' => calc['ordering_field'])
end

# v5.1.1: re-source an element to the rank-limited PRE-FILTERED helper (or
# write the probe sidecar when no member source exists). Shared by the pivot
# fast path and the CSV flow's pivot/topn-prefilter branch.
def apply_topn_prefilter!(tp, element:, cap:, z:, opts:, warnings:, data_elements:, meta: {}, own_view_id: nil)
  label = tp['calc_caption']
  norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
  # v5.1.2 guard: the helper builder + re-pointing assume the element still
  # rides the MASTER with [Master/ refs. A pivot already rewired onto a
  # two-stage window helper would get an unresolvable helper (its refs scan
  # finds nothing) and dangling window refs — POST hard-fails. Stay manual.
  if element.dig('source', 'elementId') != opts[:master_id]
    warnings << "'#{cap}' top-#{tp['top_n']} '#{label}': element already rides a helper source " \
                "(#{element.dig('source', 'elementId')}) — top-N prefilter NOT auto-emitted; add the " \
                'member list filter to that helper by hand (refs/fidelity-recipes.md §Ranked pivot)'
    return false
  end
  # The ranked entity comes from the rank calc's OWN addressing when the twb
  # carries it (entity_ref, exact) — the axis heuristic below picked the wrong
  # dim on real column-ranked pivots (rooms ride columnsBy, not rowsBy.first).
  entity_col = nil
  if tp['entity_ref']
    hint = (meta['columns_by_guid'] || {}).dig(tp['entity_ref'], 'caption') || tp['entity_ref']
    entity_col = (element['columns'] || []).find { |c| norm.call(c['name']) == norm.call(hint) }
  end
  entity_col ||= (element['rowsBy'] || []).map { |r| (element['columns'] || []).find { |c| c['id'] == r['id'] } }.compact.first ||
                 (element['columnsBy'] || []).map { |r| (element['columns'] || []).find { |c| c['id'] == r['id'] } }.compact
                   .reject { |c| c['formula'].to_s =~ /\A\[Master\/Rank/i }.last
  members = topn_members_for(label, entity_col && entity_col['name'], opts, z,
                             element_cols: element['columns'] || [], own_view_id: own_view_id)
  if entity_col && members && members.any?
    src_id = "#{element['id']}-topn-src"
    helper = data_elements.find { |d| d['id'] == src_id }
    if helper.nil?
      helper = build_topn_prefilter_helper(
        el_id: element['id'], master_id: opts[:master_id],
        entity_col: entity_col, carry_cols: element['columns'], members: members)
      # SORT_ORD: the recipe's exact render-order device (refs/fidelity-recipes
      # §Ranked pivot) — members are already rank-ordered, so the position map
      # is a data-independent Switch. The pivot sorts its entity axis by
      # Min(SORT_ORD) below; sorting by a share value is the constant-key trap.
      ent_ref = "[Master/#{helper['columns'].find { |c| c['id'] == helper['filters'][0]['columnId'] }['name']}]"
      # UNQUOTED literals only with EXPLICIT numeric datatype evidence from
      # the twb — a digit-string TEXT column ('070' room codes) must stay
      # quoted, and members-look-numeric alone proved nothing (review-caught).
      # Evidence: entity_ref's datatype, else a caption match into
      # columns_by_guid (entity_ref is nil on older twbs; review-caught).
      ent_dt = tp['entity_ref'] && (meta['columns_by_guid'] || {}).dig(tp['entity_ref'], 'datatype')
      ent_dt ||= (meta['columns_by_guid'] || {}).values.find do |v|
        v.is_a?(Hash) && v['caption'].to_s.strip.casecmp?(entity_col['name'].to_s.strip)
      end&.dig('datatype')
      numeric_members = %w[integer real].include?(ent_dt.to_s) &&
                        members.all? { |m| m.to_s =~ /\A-?(?:0|[1-9]\d*)(?:\.\d+)?\z/ }
      if !numeric_members && ent_dt.to_s.empty? && members.all? { |m| m.to_s =~ /\A-?\d+(?:\.\d+)?\z/ }
        warnings << "'#{cap}' SORT_ORD members look numeric but the entity's twb datatype is unknown — " \
                    'emitted QUOTED literals; if the column is numeric in Sigma, fix the Switch by hand'
      end
      pairs = members.each_with_index.map do |m, i|
        lit = numeric_members ? m.to_s : JSON.generate(m.to_s)
        "#{lit}, #{i + 1}"
      end.join(', ')
      helper['columns'] << { 'id' => "#{src_id}-sortord", 'name' => 'SORT_ORD',
                             'formula' => "Switch(#{ent_ref}, #{pairs}, #{members.size + 1})" }
      # The element no longer rides the master, so multi-DS routing must route
      # the HELPER — tag it with the worksheet (routing includes tagged helpers).
      helper['_worksheet'] = cap
      data_elements << helper
    end
    # (helper reuse: the same rank-filtered worksheet placed on a second
    # dashboard re-enters here — a duplicate data_element id fails the POST.)
    hname = helper['name']
    element['source'] = { 'kind' => 'table', 'elementId' => helper['id'] }
    (element['columns'] || []).each do |c|
      c['formula'] = c['formula'].to_s.gsub('[Master/', "[#{hname}/")
    end
    # Entity axis order = RANK order (Tableau's hidden rank pill drives the
    # render; a vestigial <computed-sort> matched it at 1/15 — live-checked).
    # A source shelf-sort on the same dimension is a real user sort and wins.
    # Pivots sort the axis entry; CHART-shaped elements (the CSV flow's
    # topn-prefilter mode) sort the xAxis — element['values'] is nil there,
    # so every pivot-shaped access below is guarded (review-caught: the
    # denominator check never fired for charts and the success warning
    # over-claimed).
    is_pivot = element['kind'] == 'pivot-table'
    shelf_ss = Array(z['shelf_sorts']).find { |ss| norm.call(ss['dimension']) == norm.call(entity_col['name']) }
    so_id = "p-#{element['id']}-sortord"
    axis_entry = ((element['rowsBy'] || []) + (element['columnsBy'] || [])).find { |r| r['id'] == entity_col['id'] }
    ordered = nil
    add_sortord = lambda do
      unless (element['columns'] || []).any? { |c| c['id'] == so_id }
        element['columns'] << { 'id' => so_id, 'name' => 'SORT_ORD', 'formula' => "[#{hname}/SORT_ORD]" }
      end
    end
    if axis_entry && !shelf_ss
      add_sortord.call
      axis_entry['sort'] = { 'direction' => 'ascending', 'by' => so_id, 'aggregation' => 'min' }
      ordered = 'SORT_ORD'
    elsif !is_pivot && element['xAxis'].is_a?(Hash) && element['xAxis']['sort'].nil? && !z['sort']
      if shelf_ss
        # A shelf-sorted CHART must get its order HERE — build_pivot_element's
        # shelf-sort emission never sees charts, so deferring shipped the tile
        # with NO axis order at all (review-caught on the fixture's own top-N
        # bar). Sort by the yAxis measure the shelf sort names.
        yids = element.dig('yAxis', 'columnIds') || []
        ycols = yids.map { |vid| (element['columns'] || []).find { |c| c['id'] == vid } }.compact
        by = ycols.find { |c| norm.call(c['name']).include?(norm.call(shelf_ss['measure'])) } || ycols.first
        if by
          element['xAxis']['sort'] = { 'by' => by['id'], 'direction' => shelf_ss['direction'] || 'descending' }
          ordered = 'source shelf-sort'
        end
      else
        add_sortord.call
        element['xAxis']['sort'] = { 'by' => so_id, 'direction' => 'ascending', 'aggregation' => 'min' }
        ordered = 'SORT_ORD'
      end
    end
    # Share-denominator honesty: Tableau's RANK filter is a TABLE-CALC filter —
    # shares compute over the FULL domain, then marks hide. A share whose scope
    # spans the pruned axis (or the grand total) re-computes over only the kept
    # members here and INFLATES. Scope orthogonal to the entity axis is exact.
    ent_on_cols = (element['columnsBy'] || []).any? { |r| r['id'] == entity_col['id'] }
    bad_scope = ent_on_cols ? 'row' : 'column'
    value_ids = element['values'] || element.dig('yAxis', 'columnIds') ||
                # TABLE-kind elements carry values as plain columns (review-
                # caught: the honesty warning could never fire for them)
                (element['kind'] == 'table' ? (element['columns'] || []).map { |c| c['id'] } - [entity_col['id'], so_id] : [])
    inflated = value_ids.select do |vid|
      c = (element['columns'] || []).find { |x| x['id'] == vid }
      re = is_pivot ? /PercentOfTotal\s*\([^\v]*"(?:#{bad_scope}|grand_total)"\s*\)/ : /PercentOfTotal\s*\(/
      c && c['formula'].to_s =~ re
    end
    if inflated.any?
      warnings << "'#{cap}' WARNING: #{inflated.size} share value(s) re-compute over the PRE-FILTERED domain — " \
                  'Tableau ranks over the FULL domain, so these can read HIGH here. Verify against the source; ' \
                  'full-domain denominators need a hand-build (fidelity-recipes §Ranked pivot).'
    end
    warnings << "'#{cap}' top-#{tp['top_n']} '#{label}' → rank-limited PRE-FILTERED source " \
                "'#{hname}' (#{members.size} member(s)#{ordered ? ", ordered via #{ordered}" : ''}; " \
                'element filters don\'t prune pivots)'
  else
    probes_path = opts[:out].sub(/\.json$/, '-topn-probes.json')
    probe = { 'zone' => cap, 'calc' => label, 'top_n' => tp['top_n'],
              'entity_dim' => entity_col && entity_col['name'],
              'sql_template' => "SELECT entity, MAX(share) ms, RANK() OVER (ORDER BY MAX(share) DESC) rnk " \
                                "FROM (<share-per-entity query over the landed table>) GROUP BY entity " \
                                "QUALIFY rnk <= #{tp['top_n']} -- write members (rank order) to <tab>/topn-members.json " \
                                "under the ZONE-SCOPED key {\"#{cap}::#{label}\": [..]} and re-run" }
    existing = File.exist?(probes_path) ? (JSON.parse(File.read(probes_path)) rescue []) : []
    # dedup: re-entries (multi-dashboard zones, orchestrator re-runs within one
    # build) must not balloon the sidecar
    unless existing.any? { |p| p['zone'] == probe['zone'] && p['calc'] == probe['calc'] }
      File.write(probes_path, JSON.pretty_generate(existing + [probe]))
    end
    warnings << "'#{cap}' top-#{tp['top_n']} '#{label}': no ATTRIBUTABLE member source (a CSV must be the zone's own " \
                "view or cover the entity dim plus another of its columns) — probe written to #{File.basename(probes_path)}; " \
                'run it, save members to topn-members.json (rank order), re-run build'
  end
  true
end

# Minimal GUID-from-text helper for shelf measures whose `column` reads like
# `[federated.X].[sum:GUID:qk]` or just `[GUID]`. Mirrors the parser helper.
def guid_from_text(s)
  return nil if s.nil? || s.empty?
  m = s.match(/\[(?:[a-z\-]+:)?([0-9a-f\-]{36})(?::[a-z]+)?\]/i)
  m && m[1]
end

# v5.4 — NAME-KEYED serialization variant of guid_from_text, SCOPED to the
# signal-only view synthesis. Hex GUIDs are only one of Tableau's column
# identity schemes: textscan/excel-direct/federated-live datasources key
# <column-instance> tokens by NAME ([none:IS_PAID:nk], [usr:Calculation_N:qk:2]).
# Those workbooks resolved to nil in guid_from_text, so color-channel dims and
# aggregation fallbacks silently vanished (the dropped-pie class). Kept as a
# SEPARATE resolver because guid_from_text feeds many measure/color pickers
# whose semantics are tuned to hex-GUID workbooks — broadening it globally
# re-picked measures across unrelated tiles (corpus-regression-caught).
def name_or_guid_from_text(s)
  g = guid_from_text(s)
  return g if g
  return nil if s.nil? || s.empty?
  m = s.match(/\[[a-z]+:([^:\[\]]+):[a-z]+k(?::\d+)?\]/i)
  return m[1] if m
  m = s.match(/\]\.\[([^:\/\[\]]+)\]\z/) || s.match(/\A\[([^:\/\[\]]+)\]\z/)
  g = m && m[1]
  g && g.casecmp?('Parameters') ? nil : g
end

# ---- KPI emission ---------------------------------------------------------
# Tableau "scorecard" / "big number" tiles — mark=Text or mark=Square with a
# KPI measure formula translator (bead: KPI value fidelity — ratio KPIs). A
# validated calc like `[Amount Saved (copy)]/[Cost (copy)]` composes MATERIALIZED
# measure columns via BARE refs (no explicit SUM), so translate_user_agg_formula
# (which only rewrites explicit `SUM([x])`) returns nil and the KPI falls to a
# naive `Sum(rawcol)`. Here we (a) translate any explicit aggregates, then
# (b) wrap each remaining BARE column ref that maps to a known master column in
# Sum() — yielding `Sum([Master/A]) / Sum([Master/B])`, the exact form verified
# live against the source (ROI 4.66x, Avg Cost $378.8). Bails to nil (caller
# keeps its other resolution paths) when a ref is a parameter, doesn't map to a
# column, or non-arithmetic glue remains — never emits a half-resolved formula.
# NB: end-to-end correctness requires the master to CARRY the `(copy)` columns
# (mechanical-specs materialization) — this is the emit half.
def translate_kpi_measure_formula(formula, mmap, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  return nil if s.empty?
  return nil if s =~ /\[Parameters\]/i          # param-scalar KPI — resolved elsewhere
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do          # 36-char GUID refs → captions
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption']}]" : "[#{Regexp.last_match(1)}]"
  end
  s = s.gsub(/\bIIF\s*\(/i, 'If(')
  # (a) explicit aggregates SUM([x]) / COUNT([x]) / …
  s = s.gsub(/\b(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[([^\]]+)\]\s*\)/i) do
    agg = Regexp.last_match(1).upcase
    col = Regexp.last_match(2)
    m   = map_column(col, mmap)
    ref = "[Master/#{m ? m['name'] : col}]"
    case agg
    when 'COUNT'  then "CountIf(IsNotNull(#{ref}))"
    when 'COUNTD' then "CountDistinct(#{ref})"
    else "#{USER_AGG_FN[agg]}(#{ref})"
    end
  end
  # (b) wrap remaining BARE column refs (materialized measures) in Sum()
  ok = true
  s = s.gsub(/\[([^\]]+)\]/) do
    inner = Regexp.last_match(1)
    if inner.start_with?('Master/')
      Regexp.last_match(0)                        # already translated in (a)
    elsif (m = map_column(inner, mmap))
      "Sum([Master/#{m['name']}])"
    else
      ok = false
      Regexp.last_match(0)
    end
  end
  return nil unless ok
  # residue: only arithmetic glue + our own fns may remain
  residue = s.dup
  residue.gsub!(/"(?:\\.|[^"\\])*"/, '1')
  residue.gsub!(/\[Master\/[^\]]+\]/, '1')
  allowed = %w[Sum Avg Min Max Median CountDistinct CountIf IsNotNull Coalesce If Abs]
  residue.gsub!(/\b(#{allowed.map { |f| Regexp.escape(f) }.join('|')})\b/, '')
  return nil unless residue =~ %r{\A[\s()+\-*/.,\d!=<>]*\z}
  s
end

# An axis-anchor PLACEHOLDER: a measure whose formula is a ROW-INDEPENDENT
# constant — MIN/MAX/AVG/MEDIAN/ATTR of any numeric literal (min(-1.0), AVG(0))
# or a zero/negative literal. This is the standard Tableau dummy-axis idiom —
# dashboarders pin BAN/scorecard marks to a constant axis so the text sits
# where they want it. Such a pill carries NO data; binding it as a KPI value
# reproduces the constant, not the metric (round 6: every headline KPI on one
# shape bound min(-1.0)).
#
# NOT placeholders (v5.4.9 review fix): row-COUNT measures. Bare literal `1`
# is exactly the formula of Tableau's auto-generated [Number of Records]
# field (default Sum aggregation → row count), and SUM(<positive literal>) is
# the ad-hoc row-count idiom — both scale with the data and are real headline
# values ("Total Orders" BANs). Only row-independent constants are plumbing.
def placeholder_calc?(formula)
  s = formula.to_s.strip
  return false if s.empty?
  return s.to_f <= 0 if s =~ /\A-?\d+(?:\.\d+)?\z/
  m = s.match(/\A(MIN|MAX|AVG|SUM|MEDIAN|ATTR)\s*\(\s*(-?\d+(?:\.\d+)?)\s*\)\z/i)
  return false unless m
  m[1].casecmp('SUM').zero? ? m[2].to_f <= 0 : true
end

# Pick the KPI's VALUE measure from a marks-card measure list (bead: KPI value
# fidelity). A Tableau scorecard commonly carries several measures on its Marks
# card — a raw column (`[RAW_COL]` Sum), one or more internal calc ids, and the
# MATERIALIZED VALIDATED calc the author actually trusts (`[<Field> (copy)_NNN]`,
# whose caption ends "(validated)"). The old code took `measures.first`, which
# is usually the raw column → `Sum(rawcol)` reproduces the wrong number (the
# class where a KPI reads millions when the validated value is thousands). Prefer
# the validated/materialized calc, and never pick a `(Label)` text calc as the
# value. Pure + order-stable (earliest wins on a score tie) so it's testable.
#   measures: [{ 'column' => '[…]', 'derivation' => 'Sum'|'User'|… }, …]
#   columns_by_guid: internal-name → { 'caption' => … } (for caption-based scoring)
def pick_kpi_measure(measures, columns_by_guid = {})
  list = Array(measures)
  return nil if list.empty?

  cap_of = lambda do |m|
    key = m['column'].to_s.gsub(/^\[|\]$/, '').sub(/^[a-z]+:/i, '').sub(/:[a-z]+$/i, '')
    info = columns_by_guid[key]
    ((info && info['caption']) || m['column'].to_s).to_s
  end
  is_label = ->(m) { (cap_of.call(m) =~ /\(label\)/i) || (m['column'].to_s =~ /\(label\)/i) }
  is_placeholder = lambda do |m|
    key = m['column'].to_s.gsub(/^\[|\]$/, '').sub(/^[a-z]+:/i, '').sub(/:[a-z]+$/i, '')
    info = columns_by_guid[key]
    info.is_a?(Hash) && placeholder_calc?(info['formula'])
  end

  # A `(Label)` calc is the scorecard's caption text, and an axis-anchor
  # placeholder (min(-1.0) / AVG(0)) is mark plumbing — neither is ever the
  # value. Drop them unless they're ALL we have (then fall through so the tile
  # isn't lost).
  candidates = list.reject { |m| is_label.call(m) || is_placeholder.call(m) }
  candidates = list.reject { |m| is_label.call(m) } if candidates.empty?
  candidates = list if candidates.empty?

  # A pre-computed DELTA/CHANGE ratio (`SALES CHANGE POS/NEG`, `YoY Change`,
  # `% Change`, `vs …`, variance/diff) is the sign-split delta the tile colors
  # by — NEVER the headline value. The canonical Superstore YTD-vs-PYTD tile
  # carries `TOTAL YTD Sales` + `Sales Change Pos` + `Sales Change Neg`, and the
  # old first-wins tie let a CHANGE ratio (≈−0.06) become the displayed number
  # (cold-migration value-fidelity bug). Penalize delta names hard so a real
  # total/period measure always wins; still a SCORE (not a reject) so an
  # all-delta tile isn't lost.
  is_delta = lambda do |m|
    "#{cap_of.call(m)} #{m['column']}" =~
      /\bchange\b|\bpos\b|\bneg\b|\byoy\b|y\/y|%\s*change|\bdelta\b|\bvariance\b|\bdiff\b|vs\.?\s/i
  end
  score = lambda do |m|
    name = m['column'].to_s
    cap  = cap_of.call(m)
    s = 0
    s -= 8 if is_delta.call(m)                                     # a delta ratio is never the headline value
    s += 4 if cap =~ /\(validated\)/i || name =~ /\(validated\)/i  # author's trusted calc
    s += 3 if cap =~ /\btotal\b/i || name =~ /\btotal\b/i          # prefer a TOTAL over a bare/period measure
    s += 2 if name =~ /\(copy\)_/i                                 # a materialized duplicate calc
    s += 2 if cap =~ /\bytd\b/i || name =~ /\bytd\b/i              # a period total (YTD/CYTD)
    s += 1 if m['derivation'].to_s.downcase == 'user'             # a calc, not a raw aggregate
    s
  end

  # Highest score; earliest position breaks ties (stable, reproducible).
  candidates.each_with_index.max_by { |m, i| [score.call(m), -i] }.first
end

# Candidate measures for comparison-delta detection (Task 5 — KpiComparisonDetect).
# A KPI tile's Marks card can carry several measures beyond the one
# pick_kpi_measure selects as the headline value (a raw prior-year column, a
# "% Change" calc, ...). Only measures that resolve to a REAL, already-existing
# master column (via map_column, same caption resolution pick_kpi_measure's
# cap_of uses) are eligible: a comparisonColumn must point at a column that
# already lives on the KPI's source element, and a calc-only measure with no
# master mapping can't be safely wired without replicating the full
# formula-decompose cascade build_kpi_element runs for the headline value —
# out of scope for this conservative detector. Non-mappable measures are
# silently excluded (not included with a fabricated id).
def kpi_tile_measures(z, meta, mmap)
  cols_by_guid = meta['columns_by_guid'] || {}
  cap_of = lambda do |m|
    key = m['column'].to_s.gsub(/^\[|\]$/, '').sub(/^[a-z]+:/i, '').sub(/:[a-z]+$/i, '')
    info = cols_by_guid[key]
    ((info && info['caption']) || m['column'].to_s).to_s.strip
  end
  (z['measures'] || []).each_with_object([]) do |m, out|
    cap = cap_of.call(m)
    mapped = map_column(cap, mmap)
    # 'name' stays the Tableau caption (what COMPARISON_NAME_RE matches on);
    # 'master_name' is the resolved master-column name the builder needs to
    # construct a parallel aggregated comparison column (Sum([Master/<name>])).
    out << { 'id' => mapped['id'], 'name' => cap, 'master_name' => mapped['name'] } if mapped
  end
end

# ---- Generic period/param-scoped KPI recipe (v5.4) --------------------------
# Two serializations put a parameter's CURRENT value between a scorecard and
# its number, and both shipped unscoped (all-periods) values in the field:
#   (a) the measure itself:  AGG(IF <expr> = [Parameters].[P] THEN [col] END)
#   (b) a worksheet filter:  boolean calc "<expr> = [Parameters].[P]" kept true
# <expr> is a column ref (bracketed or BARE — the Tableau formula grammar
# allows both) or a calc reducing to a date-part of a datetime column
# (DATEPART('year', [d]) / YEAR([d])) — the "period lives only in a datetime
# column" case. Sigma elements cannot evaluate a Tableau parameter, so the
# general recipe is a hidden FILTERED helper element the KPI sources: one
# column per scope expression, one list filter (with id) per scope pinned to
# the parameter's current value. Conservative contract: if ANY scope
# expression or parameter value fails to resolve, NO helper is built and the
# tile is flagged STAYS-MANUAL — a partially scoped number is worse than a
# named gap.

# Parse form (a). Returns { 'agg','col','lhs','param' } or nil. Only the
# single-branch current-period shape qualifies — offsets ([P]-1, prior-period
# comparisons) are delta plumbing, not the headline value.
def parse_param_if_measure(formula)
  s = formula.to_s.gsub(/\s+/, ' ').strip
  m = s.match(/\A(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*IF\s+(.+?)\s+THEN\s+\[([^\]]+)\]\s*(?:ELSE\s+NULL\s+)?END\s*\)\z/i)
  return nil unless m
  cm = m[2].match(/\A(\[?[\w .\-]+\]?)\s*=\s*\[Parameters?\]\s*\.\s*\[([^\]]+)\]\z/i)
  return nil unless cm
  { 'agg' => m[1].upcase, 'col' => m[3], 'lhs' => cm[1], 'param' => cm[2] }
end

# map_column with a NORMALIZED fallback for the scope recipe: formulas
# reference raw twb serialization tokens (NUM_ENROLLED, PUBLISHED DATE)
# while the master-map regexes are built from display labels ("Num
# Subscribers"). Same drift class the global ref-label repair handles —
# match case/punct-insensitively when the normalized name is UNIQUE among
# master columns; ambiguity returns nil (never guessed).
def scope_map_column(name, mmap)
  hit = map_column(name, mmap)
  return hit if hit
  key = name.to_s.downcase.gsub(/[^a-z0-9]/, '')
  return nil if key.empty?
  cands = mmap.values.select do |v|
    v.is_a?(Hash) && v['name'].to_s.downcase.gsub(/[^a-z0-9]/, '') == key
  end
  cands.map { |v| v['name'] }.uniq.size == 1 ? cands.first : nil
end

# Resolve a scope expression's LEFT side to a master-relative Sigma formula.
# Column ref → passthrough; calc reducing to a date-part → DatePart(...);
# other translatable dim calcs → their translation. nil = unresolvable.
def param_scope_resolve_lhs(lhs, z, meta, mmap)
  name = lhs.to_s.strip.gsub(/^\[|\]$/, '').strip
  return nil if name.empty?
  if (mc = scope_map_column(name, mmap))
    return { 'name' => mc['name'], 'formula' => "[Master/#{mc['name']}]" }
  end
  nrm = ->(x) { x.to_s.gsub(/^\[|\]$/, '').strip.downcase }
  cinfo = (z['calculations'] || []).find do |c|
    nrm.call(c['name']) == name.downcase || nrm.call(c['caption']) == name.downcase
  end
  cinfo ||= (meta['columns_by_guid'] || {})[name]
  f = cinfo.is_a?(Hash) ? cinfo['formula'].to_s.gsub(/\s+/, ' ').strip : ''
  return nil if f.empty?
  disp = cinfo['caption'].to_s.strip
  disp = name if disp.empty?
  if (dm = f.match(/\ADATEPART\s*\(\s*'(year|quarter|month|week|day)'\s*,\s*\[([^\]]+)\]\s*\)\z/i))
    base = scope_map_column(dm[2], mmap)
    return base && { 'name' => disp, 'formula' => %(DatePart("#{dm[1].downcase}", [Master/#{base['name']}])) }
  end
  if (ym = f.match(/\A(YEAR|QUARTER|MONTH|WEEK|DAY)\s*\(\s*\[([^\]]+)\]\s*\)\z/i))
    base = scope_map_column(ym[2], mmap)
    return base && { 'name' => disp, 'formula' => %(DatePart("#{ym[1].downcase}", [Master/#{base['name']}])) }
  end
  tf = translate_dim_calc(f, mmap, meta['columns_by_guid'] || {}) ||
       translate_row_level_calc(f, mmap, meta['columns_by_guid'] || {})
  tf && { 'name' => disp, 'formula' => tf }
end

# The parameter's CURRENT value: parser meta first (default_value), then the
# param's own serialized <calculation formula='...'> literal. Typed by the
# param's datatype so numeric filters carry numbers, not strings.
def param_current_value(pcap, z, meta)
  key = pcap.to_s.strip
  p = (meta['parameters'] || []).find do |pp|
    pp['caption'].to_s.strip.casecmp?(key) || pp['name'].to_s.gsub(/^\[|\]$/, '').strip.casecmp?(key)
  end
  raw = p && p['default_value']
  dt  = p && p['datatype']
  if raw.nil? || raw.to_s.strip.empty?
    c = (z['calculations'] || []).find do |cc|
      [cc['caption'], cc['name']].compact.any? { |x| x.to_s.gsub(/^\[|\]$/, '').strip.casecmp?(key) }
    end
    raw = c && c['formula']
    dt  = (c && c['datatype']) || dt
  end
  return nil if raw.nil? || raw.to_s.strip.empty?
  v = raw.to_s.strip.sub(/\A"(.*)"\z/m, '\1')
  case dt.to_s
  when 'integer' then v =~ /\A-?\d+\z/ ? v.to_i : nil
  when 'real'    then v =~ /\A-?(?:\d+\.?\d*|\.\d+)\z/ ? v.to_f : nil
  when 'date', 'datetime'
    # v5.4.9 review fix: a date/datetime param default serializes as a Tableau
    # date literal ('#2026-06-30#'); pinning that string in a list filter
    # matches NO date value — the KPI renders blank while the warning claims
    # success. Sigma list-filter pin semantics for date values are not
    # live-verified, so fail CLOSED: nil routes the tile to the recipe's
    # STAYS-MANUAL contract (a named gap beats a silently blank number).
    nil
  else
    # Same date-literal shape with the datatype missing from the meta — still
    # a date param; fail closed rather than pin '#...#' verbatim.
    v =~ /\A#.*#\z/m ? nil : v
  end
end

# Form (b): collect the zone's param-equality boolean filters (kept 'true').
# Returns { 'scopes' => [{name,formula,value,param,via}], 'unresolved' => [] }.
# Boolean-true filters that are NOT param equalities are not scopes — skipped.
def param_scopes_for_kpi(z, meta, mmap)
  scopes = []
  unresolved = []
  seen = {}
  (Array(z['filters']) + Array(z['hidden_filters'])).each do |f|
    next unless f.is_a?(Hash) && f['kind'].to_s == 'list'
    next unless Array(f['members']).map(&:to_s) == ['true']
    capn = (f['column_caption'] || f['caption']).to_s.strip
    next if capn.empty? || seen[capn.downcase]
    calc = (z['calculations'] || []).find do |c|
      [c['caption'], c['name']].compact.any? { |x| x.to_s.gsub(/^\[|\]$/, '').strip.casecmp?(capn) }
    end
    next unless calc
    cm = calc['formula'].to_s.gsub(/\s+/, ' ').strip
             .match(/\A(\[?[\w .\-]+\]?)\s*=\s*\[Parameters?\]\s*\.\s*\[([^\]]+)\]\z/i)
    next unless cm
    seen[capn.downcase] = true
    lhs = param_scope_resolve_lhs(cm[1], z, meta, mmap)
    val = param_current_value(cm[2], z, meta)
    if lhs && !val.nil?
      scopes << lhs.merge('value' => val, 'param' => cm[2], 'via' => capn)
    else
      unresolved << "filter '#{capn}' (#{cm[1]} = [Parameters].[#{cm[2]}])"
    end
  end
  { 'scopes' => scopes, 'unresolved' => unresolved }
end

# The hidden filtered helper the scoped KPI sources. Every filter carries an
# 'id' (the API rejects filters without one).
def build_param_scope_helper(el_id:, master_id:, value_name:, value_formula:, scopes:)
  src_id = "#{el_id}-scoped-src"
  src_name = "#{value_name} Scoped (#{el_id.sub(/^el-(kpi-)?/, '')})"
  value_col = { 'id' => "#{src_id}-v", 'name' => value_name, 'formula' => value_formula }
  scope_cols = []
  filters = []
  scopes.each_with_index do |sc, i|
    col = { 'id' => "#{src_id}-f#{i}", 'name' => sc['name'], 'formula' => sc['formula'] }
    scope_cols << col
    filters << { 'id' => "flt-#{src_id}-#{i}", 'columnId' => col['id'], 'kind' => 'list',
                 'mode' => 'include', 'selectionMode' => 'multiple', 'values' => [sc['value']] }
  end
  element = {
    'id' => src_id, 'kind' => 'table', 'name' => src_name,
    'source' => { 'kind' => 'table', 'elementId' => master_id },
    'columns' => [value_col] + scope_cols,
    'filters' => filters,
    'visibleAsSource' => false
  }
  [element, src_name]
end

# ---- C2 threshold halo (gap ubr5.11) ---------------------------------------
# A "threshold halo" is a mark whose COLOR flips above/below a constant on the
# measure (the reference ">100K" yellow halo; the red-below/green-above BAN).
# Detection is shared (lib/threshold_halo.rb); these two builder helpers resolve
# the plan against THIS run's meta and turn a mappable one into the verified
# computed-boolean + 2-color `color.scheme` on a category chart. KPIs/BANs have
# no spec path for a conditional value color (kpi-chart `value.color` is a static
# hex; conditional formatting is UI-only) → the caller routes them to
# POSTPUBLISH_GUIDE + coverage instead of silently dropping the halo.
$threshold_halo_records = [] # sidecar rows (threshold-halo.json) + coverage feed

# Task 5: KPI tiles (keyed by the same (caption || zone id) spec_api_limit_entries
# uses) for which detect_comparison_measure resolved a real comparison column.
# Consumed by spec_api_limit_entries to demote the "comparison indicator is
# UI-only" coverage warning so it fires ONLY when detection did NOT wire one.
$kpi_comparison_wired = {}

# Neutral-color test for the saturation fallback (a near-grey base vs the halo).
# Mirrors parse-twb-layout's color_neutral? closely enough for a 2-band split.
def threshold_color_neutral?(hex)
  h = hex.to_s.downcase.sub(/\A#/, '')
  return false unless h =~ /\A[0-9a-f]{6}\z/
  r = h[0, 2].to_i(16); g = h[2, 2].to_i(16); b = h[4, 2].to_i(16)
  mx = [r, g, b].max; mn = [r, g, b].min
  (mx - mn) <= 24 # low chroma → grey/neutral base
end

# Tableau color-shelf aggregate wrapper → Sigma agg template (render_agg form).
THRESHOLD_AGG = {
  'SUM' => 'Sum', 'TOTAL' => 'Sum', 'AVG' => 'Avg', 'AVERAGE' => 'Avg',
  'MIN' => 'Min', 'MAX' => 'Max', 'MEDIAN' => 'Median', 'ATTR' => 'Min',
  'COUNT' => 'CountIf(IsNotNull(%s))', 'COUNTD' => 'CountDistinct'
}.freeze

# Resolve a zone's threshold-color plan (or nil / unmappable) for this run.
def threshold_halo_plan(z, meta)
  cbg = meta['columns_by_guid'] || {}
  # Resolve the color channel's field token → columns_by_guid key. Handles hex
  # GUIDs (guid_from_text) AND name/Calculation_NNN-keyed instance refs.
  guid_of = lambda do |ref|
    g = guid_from_text(ref)
    return g if g && cbg.key?(g)
    tok = ref.to_s[/\[(?:[a-z]+:)?([^:\]]+?)(?::[a-z0-9]+)?\]\s*\z/i, 1]
    tok && cbg.key?(tok) ? tok : (g || tok)
  end
  ThresholdHalo.plan_for_zone(z, cbg, guid_of, method(:threshold_color_neutral?))
end

# Build the Sigma computed-boolean color column for a mappable plan. Returns
# [column_hash, master_name] or [nil, reason]. The boolean is evaluated per the
# chart's grouping (per bar), so `Sum([Master/m]) > N` colors each mark.
def threshold_halo_color_column(plan, el_id, meta, mmap)
  cbg = meta['columns_by_guid'] || {}
  ref = plan['measure_ref'].to_s
  tok = strip_brackets(ref).strip
  cap = (info = cbg[tok] || cbg[guid_from_text(ref).to_s]) && info.is_a?(Hash) ? info['caption'] : nil
  cap ||= tok
  master = map_column(cap, mmap)
  return [nil, "threshold measure '#{cap}' has no master column"] unless master && master['name']
  agg_tmpl = THRESHOLD_AGG[plan['agg'].to_s] || 'Sum' # bare measure ref → aggregate by Sum
  mref = "[Master/#{master['name'].to_s.strip}]"
  lhs  = render_agg(agg_tmpl, mref)
  const = plan['constant']
  col = { 'id' => "clr-halo-#{el_id}", 'name' => (plan['field'].to_s.strip.empty? ? "#{cap} #{plan['op']} #{const}" : plan['field'].to_s.strip),
          'formula' => "#{lhs} #{plan['op']} #{const}" }
  [col, master['name'].to_s.strip]
end

# single measure and no dimensions — translate to a Sigma kpi-chart element.
# Without this, the chart_kind=kpi worksheet would fall through to the
# CSV-driven flat-table flow and quietly produce nothing usable.
# See beads-sigma-bw3.
def build_kpi_element(z, meta, mmap, opts, warnings, data_elements = [])
  cap = z['caption']
  el_id = "el-kpi-#{cap.downcase.gsub(/\W+/, '-')[0..38]}".sub(/-$/, '')

  rows_shelf = z['rows_shelf'] || {}
  cols_shelf = z['cols_shelf'] || {}

  # Find the KPI's measure: first from shelves (preferred — explicit derivation),
  # then fall back to the worksheet's `measures` array (when the measure is on
  # the Marks card via Text/Color/Size encoding rather than a shelf).
  # v5.4: a shelf field that resolves to an axis-anchor PLACEHOLDER calc
  # (min(-1.0) / AVG(0) — the dummy-axis idiom) is mark plumbing, not the
  # value; skip it so the marks-card fallback below binds the real measure.
  shelf_formula = lambda do |f|
    g = f['guid'].to_s
    info = (z['calculations'] || []).find { |c| c['name'].to_s.gsub(/^\[|\]$/, '') == g } ||
           (meta['columns_by_guid'] || {})[g]
    info.is_a?(Hash) ? info['formula'].to_s : ''
  end
  measure_field = nil
  skipped_placeholder = nil
  [rows_shelf, cols_shelf].each do |shelf|
    (shelf['fields'] || []).each do |f|
      next unless f['role'] == 'measure'
      if placeholder_calc?(shelf_formula.call(f))
        skipped_placeholder ||= f
        next
      end
      measure_field ||= f
    end
  end
  if measure_field.nil? && skipped_placeholder
    warnings << "'#{cap}' KPI shelf carries only an axis-anchor placeholder " \
                "(#{shelf_formula.call(skipped_placeholder).strip[0, 30].inspect}) — binding the real measure from the marks card instead"
  end
  if measure_field.nil? && (z['measures'] || []).any?
    # Prefer the materialized VALIDATED calc over a raw aggregate column
    # (bead: KPI value fidelity) instead of blindly taking measures.first.
    m = pick_kpi_measure(z['measures'], meta['columns_by_guid'] || {}) || z['measures'].first
    measure_field = {
      'role'       => 'measure',
      'derivation' => (m['derivation'] || 'Sum').to_s.downcase,
      'raw'        => m['column'],
      'guid'       => guid_from_text(m['column'].to_s)
    }
  end

  if measure_field.nil?
    warnings << "'#{cap}' is flagged as KPI but no measure resolved from shelves or worksheet — skipping"
    return nil
  end

  master, field_cap = resolve_shelf_field(measure_field, meta, mmap)
  deriv = measure_field['derivation'].to_s.downcase
  norm = ->(x) { x.to_s.gsub(/^\[|\]$/, '').strip.downcase }

  # Parameter measure-picker (n4pi.10): if this KPI's measure IS a converter
  # param-switch calc (matched by caption OR its Calculation_NNN internal id),
  # the value becomes a control-driven Switch over the materialised branch cols.
  psw = param_switch_for(field_cap, measure_field['raw'], measure_field['guid'])
  pswitch_plan = psw && param_switch_inline(psw, mmap, meta['columns_by_guid'] || {})

  source_eid = opts[:master_id]
  two_stage_formula = nil
  ws_calc_lod = (z['calculations'] || []).find { |c| norm.call(c['name']) == norm.call(field_cap) }
  lod = ws_calc_lod && parse_fixed_lod(ws_calc_lod['formula'], meta['columns_by_guid'] || {})
  lod_ref = lod && lod_inner_ref(lod, mmap, meta['columns_by_guid'] || {})
  if lod && lod_ref
    # FIXED-LOD KPI → two-level helper (constant outer key), Max() the outer calc.
    map_name = ->(capn) { (m = map_column(capn, mmap)) ? m['name'] : capn }
    inner_keys = lod['dims'].map { |d| n = map_name.call(d); { 'name' => n, 'formula' => "[Master/#{n}]" } }
    value_formula = render_agg(LOD_INNER_AGG[lod['agg']], lod_ref)
    stage2 = SHELF_AGG_FOR_PREFIX[deriv] || 'Avg'
    helper, src_name, s2_name = build_two_stage_helper(
      el_id: el_id, master_id: opts[:master_id], value_name: field_cap.to_s.strip,
      value_formula: value_formula, inner_keys: inner_keys, outer_dims: [], stage2_agg: stage2)
    data_elements << helper
    source_eid = helper['id']
    two_stage_formula = "Max([#{src_name}/#{s2_name}])"
    warnings << "'#{cap}' KPI measure '#{field_cap}' is a FIXED LOD ({FIXED #{lod['dims'].join(', ')} : #{lod['agg']}(#{lod['label']})}) — " \
                "auto-built hidden grouped helper '#{src_name}' (inner grain = FIXED dims, 2nd-stage #{stage2}) ⚠ verify in Sigma"
  elsif lod && lod_ref.nil?
    # Parsed as a FIXED LOD but the conditional/expression inner can't be safely
    # auto-translated — point at the data-model Custom SQL path (loud, specific).
    warnings << "'#{cap}' KPI measure '#{field_cap}' is a FIXED LOD with a conditional/expression inner " \
                "(#{lod['agg']}(#{lod['label']})) that can't be auto-translated to a workbook helper — implement it as a " \
                "data-model Custom SQL element: #{lod['agg']}(CASE …) OVER (PARTITION BY #{lod['dims'].join(', ')}). See refs/phase-3-datamodel.md."
  elsif %w[avg average].include?(deriv) && master['formula'].nil? && master['grain'] && ws_calc_lod.nil?
    # Grain-aware average (bead AvgLTR): Avg of a dim-table measure — Tableau
    # evaluates it at the DIM table's native grain (all dim rows, incl. entities
    # with no fact match). Source the DM dim element directly via a hidden
    # passthrough helper; a chart re-aggregates an UNGROUPED source at its base
    # grain, so a plain Avg over the helper is exact.
    helper, src_name = build_dim_grain_helper(el_id: el_id, grain: master['grain'],
                                              columns: [master['name'].to_s.strip])
    data_elements << helper
    source_eid = helper['id']
    two_stage_formula = "Avg([#{src_name}/#{master['name'].to_s.strip}])"
    warnings << "'#{cap}' KPI measure '#{field_cap}' averages a #{master['grain']['element']} column — Tableau evaluates this at the " \
                "dim table's native grain (relationship semantics), so the KPI sources the DM '#{master['grain']['element']}' element " \
                "via hidden helper '#{src_name}' instead of the row-grain master ⚠ verify in Sigma"
  end

  # Formula resolution priority (bead 3w4d — calc-measure KPIs used to drop):
  #   1. master-map entry with a verbatim aggregate `formula` (DM metrics like
  #      Return Rate / Gross Margin Pct / Revenue Per Order)
  #   2. User-aggregated worksheet calc → decompose (SUM(a)/COUNTD(b) etc.)
  #   3. row-level worksheet calc (DATEDIFF(...)) → translate, wrap in the
  #      shelf aggregation (Avg/Sum/...)
  #   4. plain master column wrapped in the shelf aggregation
  formula = (pswitch_plan && pswitch_plan['sibling_form']) || two_stage_formula || master['formula']
  # Match the worksheet calc by the resolved CAPTION *or* the measure's internal
  # name (bead: KPI value fidelity) — z['calculations'] are keyed by internal
  # name (`[<Field> (copy)_NNN]`), so a caption-only match misses the validated
  # ratio calc that lives right on the zone.
  raw_norm = norm.call(measure_field['raw'])
  ws_calc = (z['calculations'] || []).find do |c|
    n = norm.call(c['name'])
    n == norm.call(field_cap) || n == raw_norm
  end
  # v5.4 GENERIC PERIOD/PARAM-SCOPED KPI (see the recipe block above
  # build_kpi_element). Runs before the decompose cascade: a param-IF measure
  # decomposes to NOTHING there (translate_kpi_measure_formula bails on
  # [Parameters]) and previously fell to a naive unresolvable Sum().
  if formula.nil? && source_eid == opts[:master_id]
    pif = ws_calc && parse_param_if_measure(ws_calc['formula'])
    zone_sc = param_scopes_for_kpi(z, meta, mmap)
    scopes = zone_sc['scopes'].dup
    unresolved = zone_sc['unresolved'].dup
    sc_value_name = nil
    sc_value_formula = nil
    sc_agg = nil
    if pif
      lhs = param_scope_resolve_lhs(pif['lhs'], z, meta, mmap)
      val = param_current_value(pif['param'], z, meta)
      vm  = scope_map_column(pif['col'], mmap)
      if lhs && !val.nil? && vm
        scopes << lhs.merge('value' => val, 'param' => pif['param'], 'via' => field_cap.to_s)
        sc_value_name = vm['name']
        sc_value_formula = "[Master/#{vm['name']}]"
        sc_agg = pif['agg']
      else
        miss = []
        miss << "condition '#{pif['lhs']} = [Parameters].[#{pif['param']}]'" unless lhs && !val.nil?
        miss << "value column '#{pif['col']}'" unless vm
        unresolved << "measure '#{field_cap}': #{miss.join(' + ')}"
      end
    elsif scopes.any? && ws_calc.nil? && master['formula'].nil?
      # Plain-column measure + param scope filters: same helper, shelf agg.
      sc_value_name = master['name'].to_s.strip
      sc_value_formula = "[Master/#{sc_value_name}]"
      sc_agg = nil # shelf-derivation template below
    end
    if unresolved.any?
      warnings << "'#{cap}' KPI is parameter-scoped but its scope did not resolve (#{unresolved.join('; ')}) — " \
                  'STAYS-MANUAL: build the period-scoped helper by hand (a hidden filtered element the KPI ' \
                  'sources); an unscoped value silently diverges from the source'
    elsif scopes.any? && sc_value_formula
      helper, src_name = build_param_scope_helper(
        el_id: el_id, master_id: opts[:master_id], value_name: sc_value_name,
        value_formula: sc_value_formula, scopes: scopes)
      data_elements << helper
      source_eid = helper['id']
      sc_ref = "[#{src_name}/#{sc_value_name}]"
      formula =
        if sc_agg
          case sc_agg
          when 'COUNT'  then "CountIf(IsNotNull(#{sc_ref}))"
          when 'COUNTD' then "CountDistinct(#{sc_ref})"
          else "#{USER_AGG_FN[sc_agg] || 'Sum'}(#{sc_ref})"
          end
        else
          tmpl = SHELF_AGG_FOR_PREFIX[deriv] || 'Sum'
          tmpl.include?('%s') ? tmpl.sub('%s', sc_ref) : "#{tmpl}(#{sc_ref})"
        end
      pins = scopes.map { |sc| "#{sc['name']} = #{sc['value'].inspect} ([#{sc['param']}] current value)" }
      warnings << "'#{cap}' KPI is parameter-scoped — emitted hidden filtered helper '#{src_name}' pinning " \
                  "#{pins.join(', ')}; re-bind the helper's filter(s) to the parameter control(s) post-publish " \
                  'to keep the tile interactive'
    elsif scopes.any?
      warnings << "'#{cap}' KPI carries parameter-scope filter(s) " \
                  "(#{scopes.map { |s| s['via'] || s['name'] }.join(', ')}) that could not be auto-applied to " \
                  'its calc-based measure — VERIFY: the emitted value is UNSCOPED vs the source'
    end
  end
  # Ratio/arithmetic of MATERIALIZED measure columns (bead: KPI value fidelity):
  # `[Amount Saved (copy)]/[Cost (copy)]` → `Sum([Master/…])/Sum([Master/…])`.
  # Tried before the explicit-agg decompose because that path returns nil on
  # bare measure refs and would otherwise drop the KPI to a naive Sum(rawcol).
  if formula.nil? && ws_calc && %w[usr user].include?(deriv)
    formula = translate_kpi_measure_formula(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
    warnings << "'#{cap}' KPI measure '#{field_cap}' composes materialized measure columns — translated: #{formula[0..120]}" if formula
  end
  if formula.nil? && ws_calc && %w[usr user].include?(deriv)
    formula = translate_user_agg_formula(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
    warnings << "'#{cap}' KPI measure '#{field_cap}' is a Tableau User-aggregated calc — decomposed: #{formula[0..120]}" if formula
  end
  if formula.nil? && ws_calc
    body = translate_row_level_calc(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
    if body
      agg = SHELF_AGG_FOR_PREFIX[deriv] || 'Sum'
      formula = agg.include?('%s') ? agg.sub('%s', "(#{body})") : "#{agg}((#{body}))"
      warnings << "'#{cap}' KPI measure '#{field_cap}' is a row-level Tableau calc — translated + #{agg =~ /%s/ ? 'CountIf' : agg}-aggregated: #{formula[0..120]}"
    end
  end
  if formula.nil?
    agg_template = SHELF_AGG_FOR_PREFIX[deriv] || 'Sum'
    formula =
      if agg_template.include?('%s')
        agg_template.sub('%s', "[Master/#{master['name'].to_s.strip}]")
      else
        "#{agg_template}([Master/#{master['name'].to_s.strip}])"
      end
    if ws_calc
      warnings << "'#{cap}' KPI measure '#{field_cap}' is a Tableau calc that could not be auto-decomposed — emitted #{formula} which will only resolve if the master carries that column"
    end
  end

  measure_col_id = "k-#{el_id}"
  # Prefer a governed [Metrics/<name>] ref when this KPI aggregate matches a DM
  # metric by formula equivalence; safe no-op (inline) otherwise.
  formula = MetricBinding.metric_ref_or_inline(formula, 'Master', opts[:metrics])
  measure_col = {
    'id'      => measure_col_id,
    'name'    => master['name'].to_s.strip,
    'formula' => formula
  }

  # Format: prefer Tableau format string for this measure (worksheet pill
  # format, then the column's .twb default-format — PR-12, the fix for the
  # KPI-printed-raw-where-source-shows-$ field failure), then master-map
  # format, then heuristic by name.
  tab_fmt = pick_tableau_format(z['formats'], master['name']) ||
            pick_column_default_format(master['name'])
  measure_col['format'] = tab_fmt if tab_fmt
  measure_col['format'] ||= master['format'] if master['format'].is_a?(Hash)
  measure_col['format'] ||= heuristic_number_format(master['name'])

  # Scale-comma + literal-suffix source format ('#,##0,,,B' → "1B"): the d3
  # enum can't render it (,.2s shows 'G' for 1e9), so the enum translator
  # returned nil above. Mechanize the fidelity-recipes exact-format recipe:
  # a scaled NUMERIC column with a fixed-decimal format + literal `suffix`
  # carries the EXACT rendering (trailing zeros + grouping intact) and the
  # KPI value points at it (raw column kept for anything else).
  fmt_columns = []
  if tab_fmt.nil? &&
     (raw_fmt = pick_tableau_format_raw(z['formats'], master['name']) ||
                pick_column_default_format_raw(master['name'])) &&
     (sspec = parse_scaled_suffix_format(raw_fmt))
    fmt_col_id = "#{measure_col_id}-fmt"
    fmt_columns << { 'id' => fmt_col_id, 'name' => "#{master['name'].to_s.strip} (fmt)" }
                   .merge(scaled_suffix_column(formula, sspec))
    warnings << "NOTE '#{cap}' KPI: source format #{raw_fmt.inspect} is scale+suffix (not d3-expressible) — " \
                'emitted exact-format scaled column (numeric + format suffix) and pointed the KPI value at it'
  end

  # Task 5 (the migration payoff): detect an obvious prior-period/target
  # comparison measure among the tile's OTHER measures and wire it as a real
  # Sigma delta instead of always leaving the KPI single-value. Only attempted
  # when the KPI's source is still the plain master (source_eid ==
  # opts[:master_id]) — the LOD/dim-grain/param-scope branches above swap
  # source_eid to a hidden helper element that doesn't carry the tile's
  # sibling master columns, so an mmap-resolved comparison id would point at a
  # column that doesn't exist on that helper. detect returns nil (ambiguous or
  # no match) unless exactly one sibling measure's name reads as a comparison.
  # Candidate pool #2 (the Superstore YTD-vs-PYTD case): the prior VALUE is a
  # MASTER/DM column, NOT on the tile shelf, so also hand the detector the
  # master columns (dedup'd by id) + this value's name. When no shelf sibling
  # qualifies it pairs the value's base metric (Sales) with the prior-value
  # master column (PYTD Sales). value_name prefers the resolved master column
  # name, falling back to the Tableau caption.
  cmp_measure =
    if source_eid == opts[:master_id]
      KpiComparisonDetect.detect_measure(
        kpi_tile_measures(z, meta, mmap), master['id'],
        master_columns: mmap.values, value_name: (master['name'] || field_cap)
      )
    end

  # Build the comparison as a PARALLEL derived aggregate column — the SAME
  # construction as the value measure_col above (Sum([Master/<name>]), same
  # shelf-agg template, source-prefixed) — instead of binding the bare master
  # id. That makes the Sigma delta correct-BY-CONSTRUCTION: Sum(current) -
  # Sum(prior), both aggregated over the tile's grain. The old bare-id path
  # pointed comparisonColumn at a raw row-level column while value.columnId was
  # an aggregate, so the delta rendered blank (unbound) or wrong (row vs
  # aggregate). Only reachable when source_eid is still the plain master (the
  # LOD/dim-grain/param-scope helper swaps above disqualify detection), and the
  # detected measure always resolves to a real master column (kpi_tile_measures
  # only yields mappable measures), so Sum([Master/<prior>]) is exactly the
  # value's plain-master fallback (line ~4020) applied to the prior measure.
  comparison_col       = nil
  comparison_column_id = nil
  if cmp_measure
    cmp_name    = (cmp_measure['master_name'] || cmp_measure['name']).to_s.strip
    cmp_agg     = SHELF_AGG_FOR_PREFIX[deriv] || 'Sum'
    cmp_formula = cmp_agg.include?('%s') ? cmp_agg.sub('%s', "[Master/#{cmp_name}]") : "#{cmp_agg}([Master/#{cmp_name}])"
    cmp_formula = MetricBinding.metric_ref_or_inline(cmp_formula, 'Master', opts[:metrics])
    comparison_column_id = "kc-#{el_id}"
    comparison_col = { 'id' => comparison_column_id, 'name' => cmp_name, 'formula' => cmp_formula }
    cmp_fmt = pick_tableau_format(z['formats'], cmp_name) || pick_column_default_format(cmp_name)
    comparison_col['format'] = cmp_fmt if cmp_fmt
    comparison_col['format'] ||= heuristic_number_format(cmp_name)
    $kpi_comparison_wired[(z['caption'] || z['id']).to_s] = true
  end

  # value.columnId, NOT value.id — the live API 400s with "value.columnId:
  # Invalid string: undefined" (bead 3w4d; same fix as qlik-to-sigma
  # scout-validate + refs/sigma-build-gotchas.md) — KpiCard.build already
  # follows this contract.
  element = KpiCard.build(
    id: el_id,
    name: tile_title(z, cap),
    source_element_id: source_eid,
    columns: [measure_col] + fmt_columns + (comparison_col ? [comparison_col] : []),
    value_column_id: (fmt_columns.any? ? fmt_columns.first['id'] : measure_col_id),
    comparison_column_id: comparison_column_id, # Task 5: derived aggregated prior/target column, else nil (single-value)
    good_direction: :up
  )

  # B3 (gap ubr5.7): a Tableau "big number" BAN scorecard (Shape/Circle mark with
  # a <customized-label>, surfaced by the parser as kpi_value_font_size). Style
  # the composite faithfully: use the label run as the KPI title and keep the
  # SOURCE font size (fidelity mandate — prefer the .twb value over a hand-tuned
  # one). Non-BAN KPIs (Automatic-mark scorecards) carry no kpi_value_font_size
  # and keep their default styling.
  #
  # NOTE (transparency is a COMPOSITION decision, not an element one): a
  # transparent hero (backgroundColor #00000000) only reads well when a container
  # TINT sits behind it (the composed region-card look). Applied to a KPI that
  # is NOT inside a tinted container it strips the default card and the number
  # floats naked on the canvas — a regression vs the plain KPI card. The element
  # builder can't see its container, so it must NOT force transparency here; the
  # composition stage (B1/B2 region cards) sets it when it actually places a KPI
  # into a tint. So we set label + fontSize only and leave the default card.
  if z['kpi_value_font_size']
    # kpi_label (BAN scorecard label) only when the source has no displayed title
    # — the worksheet <title> (already applied above) is the more authoritative name.
    element['name'] = z['kpi_label'] if z['kpi_label'] && !z['kpi_label'].to_s.strip.empty? &&
                                        z['display_title'].to_s.strip.empty?
    element['value']['fontSize'] = z['kpi_value_font_size']
    # The BAN's side annotation (e.g. "40% of U.S. total") is driven by a dynamic
    # Tableau calc token that can't be reproduced as static text; emitting the
    # literal remainder ("of U.S. total") alone would mislead. Surface the gap.
    if Array(z['kpi_annotation_runs']).any? { |r| r['ref'] }
      warnings << "'#{cap}' KPI has a customized-label annotation with a dynamic value " \
                  "(e.g. a '% of total' calc) — the annotation is NOT reproduced (needs a computed column)"
    end
  end

  # Param measure-picker: materialise the hidden passthrough sibling cols the
  # Switch's branches reference, and register the control for emission (n4pi.10).
  if pswitch_plan
    add_switch_siblings!(element, pswitch_plan['branch_refs'])
    $param_switch_used << pswitch_plan['control_id'] unless $param_switch_used.include?(pswitch_plan['control_id'])
    warnings << "'#{cap}' KPI measure '#{field_cap}' is a parameter measure-picker → control-driven Switch over " \
                "[#{pswitch_plan['control_id']}] (#{psw['cases'].size} option(s)): #{pswitch_plan['sibling_form'][0..100]}"
  end

  # If the Tableau worksheet had Show Mark Labels on (typical for KPIs since
  # the number IS the chart), we don't need a separate dataLabel — kpi-chart
  # always renders the value. No-op.

  # C2 threshold halo on a BAN/KPI: the scorecard's value color flips on a
  # threshold. Sigma's kpi-chart `value.color` is a STATIC hex and its
  # conditional formatting is UI-only — there is NO create-spec path to a
  # value color that flips on the measure. Route it to POSTPUBLISH_GUIDE +
  # coverage (never silently drop); the user finishes it in the editor.
  thp = threshold_halo_plan(z, meta)
  if thp
    reason = thp['mappable'] ? 'kpi-chart conditional value color is UI-only in Sigma (value.color is a static hex)' : thp['reason']
    $threshold_halo_records << { 'element' => element['id'], 'worksheet' => cap, 'kind' => 'kpi-chart',
                                 'status' => 'postpublish', 'field' => thp['field'], 'formula' => thp['formula'],
                                 'op' => thp['op'], 'constant' => thp['constant'], 'reason' => reason }
    warnings << "'#{cap}' BAN/KPI has a THRESHOLD color (#{thp['formula'].to_s.gsub(/\s+/, ' ')}) — Sigma has no " \
                'create-spec path for a conditional KPI value color (value.color is static; conditional formatting is ' \
                'UI-only) — STAYS-MANUAL: set the KPI conditional color in the editor (routed to POSTPUBLISH_GUIDE + coverage)'
  end

  element
end

# A workbook may have multiple dashboards; iterate all and concatenate elements.
# Drop the chart_kind=automatic warnings to stderr so the caller can act on them.
# Converter param measure-pickers (kind:param-switch) — indexed by caption +
# Calculation_NNN id so a picker plotted as a tile measure becomes a control-
# driven Switch (n4pi.10). Optional; no --workbook-patterns ⇒ empty index. Loaded
# here (after the helper defs above, before the element loop) so the globals it
# populates are initialised first.
load_param_switches(opts[:wb_patterns], meta)
warn "loaded #{$param_switches.size} param measure-picker(s) from #{opts[:wb_patterns]}" if $param_switches.any?
load_aggregate_dims(opts[:wb_patterns], meta)
warn "loaded #{$agg_dims.size} aggregate-derived dimension(s) from #{opts[:wb_patterns]}" if $agg_dims.any?

elements = []
data_elements = [] # hidden helper elements (scatter grouped sources — bead z1d0)
warnings = []
# D2/P0.2: datasource-level + extract filters from the parse meta apply to
# EVERY element sourcing that datasource (Tableau row-scopes the whole source;
# no worksheet carries them). They ride the normal per-zone value-filter
# dispatch below, tagged so a loud post-loop summary can list what was applied.
ds_value_filters = (meta['datasource_filters'] || []).reject { |f| f['is_action'] }
ds_value_filters.each { |f| f['_ds_scope'] = true }
ds_filter_applications = Hash.new { |h, k| h[k] = [] } # object_id → [worksheet]
# topn-probes sidecar is rebuilt from scratch each run — append-only growth
# left resolved/stale probes lingering across builds (review-caught).
_stale_probes = opts[:out].sub(/\.json$/, '-topn-probes.json')
File.delete(_stale_probes) if File.exist?(_stale_probes)
lod_chains = [] # nested-FIXED helper-element chains (beads-sigma-t67b)
# Tiles built from .twb signals because their Tableau data export was EMPTY
# (action-filter-gated, etc). They can't be value-diffed (no actuals), so they
# route to IMAGE-based visual verification instead of silently passing parity.
signal_built_tiles = [] # [{ 'worksheet' => cap, 'view_id' => id }]

layout.each do |dash|
  dash['zones'].each do |z|
    next unless z['kind'] == 'chart'
    cap = z['caption']
    next if cap.nil? || cap.empty?

    # PR-10 kind propagation: the Phase 1d read VERIFIED this tile's kind
    # against the source image — it beats every shelf inference below, for ALL
    # kinds (see the PNG_KIND header above). Mismatches are logged one line
    # each; a verified kind also clears chart_kind_inferred (it is confirmed,
    # not a guess, so the image-confirmation routing below is redundant).
    png_ck = PNG_KIND[cap.to_s.downcase.strip]
    png_ck ||= PNG_KIND[z['display_title'].to_s.downcase.strip]
    if png_ck
      if png_ck != z['chart_kind'].to_s
        warn "[png-read] '#{cap}': verified kind '#{png_ck}' OVERRIDES shelf-inferred '#{z['chart_kind']}' (png-read.json is the source-image truth)"
        # E5.11 census entry: every png-read-vs-mechanical divergence is
        # recorded, so a bent Phase-1d transcription can never silently
        # convert source-vs-built divergence into a passing gate — gate 21
        # (the single kind-parity comparator) and the punch list read these.
        if EVIDENCE_LEDGER_LOADED
          EvidenceLedger.append(opts[:tab], gate: 'build-charts', verdict: 'kind-override',
                                evidence_kind: 'kind-divergence', evidence_path: 'png-read.json',
                                detail: { 'tile' => cap.to_s, 'png_kind' => png_ck,
                                          'shelf_kind' => z['chart_kind'].to_s })
        end
        z['chart_kind'] = png_ck
      end
      z['chart_kind_inferred'] = false
    end

    # Pivot-table fast path: Tableau crosstabs (chart_kind=pivot-table from
    # parse-twb-layout) emit a Sigma pivot-table element with rowsBy/columnsBy/
    # values derived from shelf info — independent of the view CSV shape.
    # Falls through to the CSV-driven flat-table path if shelves can't be
    # resolved cleanly (logged via warnings).
    if z['chart_kind'] == 'pivot-table'
      pivot_el = build_pivot_element(z, meta, mmap, opts, warnings, data_elements)
      if pivot_el
        pivot_el['_worksheet'] = cap
        pivot_el['_dashboard'] = dash['dashboard']
        # v5.1.1: intercept the top-N idiom HERE — the fast path `next`s out of
        # the zone loop, so the CSV flow's value-filter interception never sees
        # pivots (review-caught: the v5.1 pre-filtered-source branch was dead
        # for every real pivot). Element filters don't prune a pivot's
        # dimension, so the ONLY correct emission is the pre-filtered source.
        (z['filters'] || []).reject { |f| f['is_action'] }.each do |f|
          # D6/P0.5: a NATIVE Top-tab quick filter on a pivot — element filters
          # don't prune a pivot dimension, so the only faithful emission is the
          # rank-limited pre-filtered source. Surface it, never drop it.
          if (tn = f['topn'])
            warnings << "'#{cap}' native Tableau #{tn['end'] || 'top'}-N quick filter " \
                        "(N=#{tn['n'] || tn['count_param'] || '?'}, ranked by #{tn['order_expr'].to_s[0..80]}) " \
                        'targets a PIVOT — STAYS-MANUAL: build the rank-limited pre-filtered source ' \
                        '(refs/fidelity-recipes.md §Ranked pivot)'
            next
          end
          tp = detect_topn_plan(f, z, mmap, meta)
          next unless tp
          unless tp['top_n']
            # mirror the CSV flow's honesty: a detected rank filter that can't
            # auto-emit (>= / > op, LOD operand) must be SURFACED, not dropped
            # (v5.1.2 review-caught)
            warnings << "'#{cap}' top-N filter '#{tp['calc_caption']}': #{tp['note'] || 'rank operand did not translate'} — not auto-emitted; re-create by hand"
            next
          end
          unless tp['keeps_true']
            warnings << "'#{cap}' top-N filter '#{tp['calc_caption']}' keeps FALSE (anti-top-N) — not auto-emitted; re-create by hand"
            next
          end
          apply_topn_prefilter!(tp, element: pivot_el, cap: cap, z: z, meta: meta,
                                opts: opts, warnings: warnings, data_elements: data_elements,
                                own_view_id: view_by_name[cap] && view_by_name[cap]['id'])
          break
        end
        # D2/P0.2: pivots exit the zone loop before the CSV flow's ds-filter
        # merge, and element filters don't reliably prune a pivot anyway
        # (round-4 bisect) — surface the datasource/extract row scoping loudly
        # instead of silently over-reporting.
        if ds_value_filters.any?
          warnings << "'#{cap}' is a PIVOT — #{ds_value_filters.size} datasource/extract filter(s) NOT " \
                      'auto-applied (element filters do not prune pivots); scope its SOURCE by hand ' \
                      "(helper prefilter or DM filter): #{ds_value_filters.map { |f| f['column_caption'] || f['raw_param'] }.join(', ')[0..160]}"
        end
        elements << pivot_el
        warnings << "'#{cap}' auto-emitted as Sigma pivot-table from Tableau crosstab (rows/cols shelves) — verify dim placement"
        next
      end
      # else: fall through to flat-table flow
    end

    # KPI fast path: Tableau scorecards (chart_kind=kpi) emit a Sigma kpi-chart
    # with a single measure as value. Without this, the worksheet would fall
    # into the CSV-driven 2-column flow which requires headers.length >= 2 and
    # silently drops single-measure tiles. beads-sigma-bw3.
    if z['chart_kind'] == 'kpi'
      kpi_el = build_kpi_element(z, meta, mmap, opts, warnings, data_elements)
      if kpi_el
        kpi_el['_worksheet'] = cap
        kpi_el['_dashboard'] = dash['dashboard']
        elements << kpi_el
        warnings << "'#{cap}' auto-emitted as Sigma kpi-chart from Tableau scorecard (single aggregated measure, no dims) — verify value formula"
        next
      end
      # else: fall through with the warning already logged
    end

    # v5.4 ZONE-DROP HONESTY: a NAMED mark class with no Sigma equivalent
    # (GanttBar waterfalls/candlesticks/strips, VizExtension third-party
    # marks, …) previously fell through SIGMA_KIND['other'] → 'bar-chart' and
    # shipped a silently WRONG chart shape. Emit a LOUD named handoff instead:
    # the zone is not auto-built, the coverage ledger records it dropped with
    # the mark class as root cause, and the Phase-6 tile census reports it
    # unmatched. A BLANK mark ('other' with no mark_class) keeps the bar
    # fallback — loudly.
    if z['chart_kind'].to_s == 'other'
      mc = z['mark_class'].to_s
      if mc.empty?
        warnings << "'#{cap}' has a blank mark class — defaulted to bar-chart; VERIFY against the source image"
      else
        warnings << "ZONE DROPPED / STAYS-MANUAL: '#{cap}' uses Tableau mark class '#{mc}' with no Sigma " \
                    'chart equivalent — NOT auto-built (a bar-chart stand-in misrepresents the mark). ' \
                    'Re-author in Sigma by hand (waterfall/candlestick: bar + running-total helper; ' \
                    'gantt: no native equivalent; viz-extension: rebuild with a native chart). ' \
                    'The Phase-6 tile census will report this zone unmatched.'
        next
      end
    end

    # MULTI-DATASOURCE ROUTING SENTRY: every chart below is sourced from the ONE
    # master (opts[:master_id]) — correct only when its worksheet rides the SAME
    # datasource as the master's fact. Record each worksheet's federated
    # datasource id (from its shelf refs); after the loop, charts on a MINORITY
    # datasource get a loud, actionable warning (field-caught: two pivots riding
    # a different datasource were silently routed to the primary master and
    # emitted refs to columns that don't exist there — the pre-POST ref gate
    # stopped the run, but with no explanation of WHY or WHAT to do).
    _zshelves = [z['rows_shelf'], z['cols_shelf']].compact.map { |s| s['raw'].to_s }.join(' ') +
                (z['channels'] || {}).values.map { |c| c.is_a?(Hash) ? c['column'].to_s : '' }.join(' ')
    _zds = _zshelves.scan(/\[(federated\.[a-z0-9]+)\]/).flatten
                    .group_by(&:itself).max_by { |_k, v| v.length }&.first # (no .tally — Ruby 2.6 floor)
    ($zone_datasource ||= {})[cap] = _zds if _zds

    view = view_by_name[cap]
    if view.nil?
      # No standalone Tableau REST view for this worksheet — it's a sheet
      # embedded inside a dashboard (published without its own tab), so it has no
      # data export. NOT a reason to drop it (the "5 blend worksheets never
      # built" regression): give it a synthetic view id (no CSV on disk) so it
      # falls through to the empty-CSV path below, which reconstructs the tile
      # from .twb shelf signals. Drop only when the shelves genuinely can't be
      # reconstructed — and even then, surface it (never silent).
      if synthesize_view_from_signals(z, meta)
        warnings << "'#{cap}' has NO standalone Tableau REST view (worksheet embedded in a dashboard) — " \
                    "building it from .twb shelf signals instead of dropping it (data parity for this tile is manual/image)."
        view = { 'id' => "signal-only-#{cap.gsub(/\W+/, '-')}" }
      else
        warnings << "ZONE DROPPED: '#{cap}' — no Tableau REST view AND shelf signals carry no dim+measure to " \
                    "reconstruct it. Build the chart by hand; the Phase-6 tile census will report it unmatched."
        next
      end
    end
    # Chart kind was INFERRED from shelves (Tableau mark=Automatic) — route it to
    # IMAGE confirmation so a wrong line/bar/scatter guess can't pass silently.
    if z['chart_kind_inferred']
      signal_built_tiles << { 'worksheet' => cap, 'view_id' => view['id'], 'reason' => 'chart-kind-inferred' }
      warnings << "'#{cap}' chart kind was AUTOMATIC in Tableau — inferred '#{z['chart_kind']}' from the shelves; " \
                  'routed to image confirmation (verify-visual-tiles) — confirm against the Tableau view image.'
    end
    csv_path = File.join(opts[:tab], 'views', "#{view['id']}.csv")
    # A view CSV that is MISSING (dataless / signal-only run — e.g. synth-twb-e2e
    # stubs the views with no export) is treated the same as an EMPTY one: the
    # standard-chart flow below is header+signal driven, so reconstruct the view
    # from the .twb shelf signals rather than silently dropping the zone. (Pivot
    # and KPI zones already took their fast paths above; this is the standard
    # line/bar/scatter path — without this, every standard chart in a dataless
    # run was skipped while crosstabs/KPIs built. bead y9rd.)
    csv_missing = !File.exist?(csv_path)
    rows = csv_missing ? [] : CSV.read(csv_path)
    if rows.empty?
      # An empty/0-byte view CSV is usually NOT a missing viz — it's a sheet
      # gated behind a dashboard ACTION filter (Tableau renders it fine, but its
      # headless data export returns zero rows), or a permission/timeout empty.
      # A MISSING CSV is a dataless signal-only run. Either way, reconstruct the
      # view headers from the .twb shelf signals and build the chart from those
      # (header+signal driven, not row driven) — we never skip a viz that exists
      # in the workbook. Parity for THIS tile is downgraded to manual (no
      # exportable actuals to diff).
      synth = synthesize_view_from_signals(z, meta)
      if synth
        warnings << "'#{cap}' — Tableau view CSV is #{csv_missing ? "MISSING (dataless/signal-only run)" : "EMPTY (0 bytes), almost always an ACTION-FILTER-gated export (the sheet renders fine in Tableau)"}. " \
                    "BUILT FROM .twb SIGNALS instead of dropping it: " \
                    "headers=#{synth[:headers].inspect}. Sigma sources the same warehouse so the chart will populate; " \
                    "DATA PARITY for this one tile must be verified manually (no exportable actuals)."
        rows = [synth[:headers]]   # header row only — body stays empty
        z['_parity_manual'] = true
        signal_built_tiles << { 'worksheet' => cap, 'view_id' => (view && view['id']) }
      else
        warnings << "ZONE DROPPED: '#{cap}' — view CSV at #{csv_path} is EMPTY (0 bytes / 0 rows) AND the shelf " \
                    "signals carry no dim+measure to reconstruct it (rows_shelf=#{(z['rows_shelf']||{})['raw'].inspect}, " \
                    "cols_shelf=#{(z['cols_shelf']||{})['raw'].inspect}). Build the chart by hand — " \
                    "the Phase-6 tile census will report this zone as unmatched."
        next
      end
    end
    headers = rows.shift
    if headers.length < 2
      warnings << "ZONE DROPPED: '#{cap}' — view CSV has only #{headers.length} column(s); " \
                  "need dim + measure. NO Sigma chart was built for this zone — " \
                  "the Phase-6 tile census will report it as unmatched."
      next
    end

    # ---- Measure Names / Measure Values long format → multi-measure chart --
    # Tableau exports a Measure-Names worksheet as LONG rows
    # ("Measure Names","<dim>","Measure Values") — the 2-column flow below
    # would mis-read the measure-name strings as a color dim. Dissolve it into
    # ONE chart with a yAxis column per measure (WINPROBE-validated shape:
    # multi-measure line over the shared dim, window calcs included).
    mn_i = headers.index { |h| h.to_s.strip.casecmp?('Measure Names') }
    mv_i = headers.index { |h| h.to_s.strip.casecmp?('Measure Values') }
    if mn_i && mv_i && headers.length == 3 && !%w[pivot-table kpi].include?(z['chart_kind'].to_s)
      dim_i   = ([0, 1, 2] - [mn_i, mv_i]).first
      dim_hdr = headers[dim_i].to_s.strip
      labels  = rows.map { |r| r[mn_i] }.compact.map(&:strip).reject(&:empty?).uniq
      mm_trunc = (hm = dim_hdr.match(/^(second|minute|hour|day|week|month|quarter|year) of /i)) && hm[1].downcase
      # For a date-grain header the DateTrunc below must wrap the BASE date column
      # ([Master/Order Date]); resolve the grain-stripped name FIRST so we don't
      # bind the converter's broken passthrough "Month of Order Date" master column
      # (formula [Fact/Month of Order Date] — no such fact column). See Path B.
      mm_base_hdr = mm_trunc ? dim_hdr.sub(/^(?:second|minute|hour|day|week|month|quarter|year) of /i, '') : dim_hdr
      dimm = (mm_trunc && map_column(mm_base_hdr, mmap)) || map_column(dim_hdr, mmap) ||
             { 'id' => "m-#{dim_hdr.downcase.gsub(/\W+/, '-')}", 'name' => dim_hdr }
      el_id = "el-#{cap.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')
      mm_dim_formula =
        if mm_trunc == 'week'
          # Tableau weeks are Sunday-anchored (see the week note below).
          %(DateAdd("day", 1 - Weekday([Master/#{dimm['name']}]), DateTrunc("day", [Master/#{dimm['name']}])))
        elsif mm_trunc
          %(DateTrunc("#{mm_trunc}", [Master/#{dimm['name']}]))
        else
          "[Master/#{dimm['name']}]"
        end
      dim_col_obj = { 'id' => "x-#{el_id}", 'name' => dimm['name'], 'formula' => mm_dim_formula }
      dim_col_obj['format'] = { 'kind' => 'datetime', 'formatString' => mm_trunc == 'week' ? '%b %d, %Y' : '%b %Y' } if mm_trunc
      cap_deriv = {}
      (z['aggregations'] || {}).each do |col_ref, deriv|
        g = strip_brackets(col_ref)
        info = (meta['columns_by_guid'] || {})[g]
        cap_deriv[(info ? info['caption'] : g).to_s.strip.downcase] = deriv
      end
      mm_norm = ->(x) { x.to_s.gsub(/^\[|\]$/, '').strip.downcase }
      y_cols = []
      unresolved = []
      labels.each_with_index do |label, i|
        base = header_base(label)
        ws_calc = (z['calculations'] || []).find do |c|
          n = mm_norm.call(c['name'])
          n == mm_norm.call(base) || n == mm_norm.call(label)
        end
        formula = nil
        if ws_calc
          wp = translate_window_calc(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
          record_window_calc(z, ws_calc, wp) if wp
          if wp && wp['mode'] == 'inline'
            formula = wp['formula']
            warnings << "'#{cap}' measure '#{label}' is a window table-calc — emitted as a Sigma viz formula [#{wp['note']}]"
          elsif wp
            warnings << "'#{cap}' measure '#{label}' STAYS MANUAL in the multi-measure chart: #{wp['note']}"
          else
            formula = translate_user_agg_formula(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
          end
        else
          mcol = map_column(base, mmap) || map_column(label, mmap)
          if mcol
            deriv = infer_csv_agg(label) || cap_deriv[mcol['name'].to_s.strip.downcase] ||
                    cap_deriv[base.downcase] || 'Sum'
            formula = mcol['formula'] || render_agg(SIGMA_AGG[deriv] || 'Sum', "[Master/#{mcol['name']}]")
          end
        end
        if formula.nil?
          unresolved << label
          next
        end
        fmt = label.to_s =~ /(rate|margin|pct|percent|ratio)/i ?
                { 'kind' => 'number', 'formatString' => ',.1%' } :
                { 'kind' => 'number', 'formatString' => ',.0f' }
        # Column NAME = the Tableau measure-name label verbatim — the parity
        # plan pivots the long CSV and matches Sigma columns by display name.
        formula = MetricBinding.metric_ref_or_inline(formula, 'Master', opts[:metrics])
        y_cols << { 'id' => "y#{i}-#{el_id}", 'name' => label, 'formula' => formula, 'format' => fmt }
      end
      if y_cols.any?
        element = {
          'id' => el_id, 'kind' => SIGMA_KIND[z['chart_kind']] || 'line-chart', 'name' => tile_title(z, cap),
          'source' => { 'kind' => 'table', 'elementId' => opts[:master_id] },
          'columns' => [dim_col_obj] + y_cols,
          'xAxis' => { 'columnId' => dim_col_obj['id'] },
          'yAxis' => { 'columnIds' => y_cols.map { |c| c['id'] } },
          '_worksheet' => cap, '_dashboard' => dash['dashboard']
        }
        elements << element
        warnings << "'#{cap}' Measure Names/Values long-format view dissolved into a multi-measure " \
                    "#{element['kind']} (#{y_cols.size} measure(s): #{y_cols.map { |c| c['name'] }.join(', ')})" \
                    "#{unresolved.any? ? "; UNRESOLVED measure(s): #{unresolved.join(', ')}" : ''} — " \
                    'view filters (other than the Measure Names filter itself) are not auto-carried; verify'
        next
      end
      warnings << "'#{cap}' is a Measure Names/Values view but no measure resolved — falling through to the 2-column flow"
    end

    dim_hdr  = headers[0].to_s.strip
    meas_hdr = headers[1].to_s.strip

    # Multi-channel detection (bead z1d0): a 3-column CSV whose SECOND column
    # is another dimension (non-numeric data) is a stacked/colored chart
    # (color dim + x dim + measure) — NEVER aggregate the string dim. Tableau
    # exports the COLOR (inner) dim first, the axis dim second.
    color_hdr = nil
    dim_csv_idx = 0
    color_csv_idx = nil
    if headers.length >= 3 && %w[bar line area automatic other].include?(z['chart_kind'].to_s)
      second_vals = rows.first(20).map { |r| r[1] }.compact
      second_is_dim = second_vals.any? &&
                      second_vals.none? { |v| begin Float(v.to_s.gsub(',', '')); true; rescue StandardError; false; end }
      if second_is_dim
        h0 = headers[0].to_s.strip
        h1 = headers[1].to_s.strip
        # Which of the two dims is the color channel? Resolve the Tableau color
        # encoding column to a caption and match; fall back to "first = color".
        color_cap = nil
        if (cc = z.dig('channels', 'color', 'column'))
          g = guid_from_text(cc.to_s)
          info = g ? (meta['columns_by_guid'] || {})[g] : nil
          color_cap = (info && info['caption']) ||
                      cc.to_s.sub(/^\[[^\]]+\]\./, '').gsub(/^\[|\]$/, '').sub(/^[a-z]+:/i, '').sub(/:[a-z]+$/i, '')
        end
        if color_cap && h1.casecmp?(color_cap.to_s.strip)
          color_hdr = h1
          dim_hdr = h0
          color_csv_idx = 1
          dim_csv_idx = 0
        else
          color_hdr = h0
          dim_hdr = h1
          color_csv_idx = 0
          dim_csv_idx = 1
        end
        meas_hdr = headers[2].to_s.strip
        warnings << "'#{cap}' 3-channel chart: x=#{dim_hdr.inspect} color=#{color_hdr.inspect} measure=#{meas_hdr.inspect} (color channel #{color_cap ? "resolved from Tableau encoding '#{color_cap}'" : 'defaulted to first CSV dim'})"
      end
    end

    # A date-grain header ("Month of Order Date") won't match a master column
    # named "Order Date"; try the grain-stripped form so the DateTrunc wraps the
    # real master date column instead of leaking the prefixed name into the
    # formula (which would resolve to a non-existent column). dim_trunc below
    # still carries the grain. Strips only when the full header didn't match.
    dim_hdr_base = dim_hdr.sub(/^(?:second|minute|hour|day|week|month|quarter|year) of /i, '')
    # When a grain prefix is present, resolve the BASE date column FIRST so the
    # DateTrunc wraps [Master/Order Date]. Matching the full "Month of Order Date"
    # first binds the converter's passthrough master column whose formula is
    # [Fact/Month of Order Date] — a non-existent fact column — and DateTrunc then
    # double-wraps a broken ref. The base "Order Date" is on the master via the
    # reuse-union (#5); fall back to the full header only if the base isn't mapped.
    dim = if dim_hdr_base != dim_hdr
            map_column(dim_hdr_base, mmap) || map_column(dim_hdr, mmap)
          else
            map_column(dim_hdr, mmap)
          end
    meas = map_column(meas_hdr, mmap)
    meas_unresolved = meas.nil?
    find_ws_calc = lambda do |hdr|
      (z['calculations'] || []).find { |c| c['name'].to_s.gsub(/^\[|\]$/, '').strip.casecmp?(hdr.to_s.strip) }
    end
    if dim.nil?
      wc = find_ws_calc.call(dim_hdr)
      tf = wc && (translate_dim_calc(wc['formula'], mmap, meta['columns_by_guid'] || {}) ||
                  translate_row_level_calc(wc['formula'], mmap, meta['columns_by_guid'] || {}))
      if tf
        dim = { 'id' => "m-#{dim_hdr.downcase.gsub(/\W+/, '-')}", 'name' => dim_hdr, 'formula' => tf }
        warnings << "'#{cap}' dim '#{dim_hdr}' is a worksheet-local Tableau calc — translated inline: #{tf[0..140]}"
      else
        warnings << "no master column matched dim header '#{dim_hdr}' for '#{cap}' — falling back to raw header"
        dim = { 'id' => "m-#{dim_hdr.downcase.gsub(/\W+/, '-')}", 'name' => dim_hdr }
      end
    end
    if meas.nil?
      warnings << "no master column matched measure header '#{meas_hdr}' for '#{cap}'"
      meas = { 'id' => "m-#{meas_hdr.downcase.gsub(/\W+/,'-')}", 'name' => meas_hdr }
    end
    # Parameter measure-picker (n4pi.10): a measure that IS a converter param-
    # switch calc (matched by caption OR its Calculation_NNN id) becomes a
    # control-driven Switch tile measure over materialised branch cols.
    chart_pswitch = param_switch_for(meas_hdr, meas && meas['name'])
    chart_pswitch_plan = chart_pswitch && param_switch_inline(chart_pswitch, mmap, meta['columns_by_guid'] || {})
    color_dim = nil
    if color_hdr
      color_dim = map_column(color_hdr, mmap)
      if color_dim.nil?
        wcc = (z['calculations'] || []).find { |c| c['name'].to_s.gsub(/^\[|\]$/, '').strip.casecmp?(color_hdr.to_s.strip) }
        tfc = wcc && (translate_dim_calc(wcc['formula'], mmap, meta['columns_by_guid'] || {}) ||
                      translate_row_level_calc(wcc['formula'], mmap, meta['columns_by_guid'] || {}))
        if tfc
          color_dim = { 'id' => "m-#{color_hdr.downcase.gsub(/\W+/, '-')}", 'name' => color_hdr, 'formula' => tfc }
          warnings << "'#{cap}' color dim '#{color_hdr}' is a worksheet-local Tableau calc — translated inline: #{tfc[0..140]}"
        else
          warnings << "no master column matched color header '#{color_hdr}' for '#{cap}' — falling back to raw header"
          color_dim = { 'id' => "m-#{color_hdr.downcase.gsub(/\W+/,'-')}", 'name' => color_hdr }
        end
      end
    end

    # Decide the Sigma aggregator. Priority:
    #   1. parse-twb-layout.rb's aggregations dict (most authoritative — comes
    #      from Tableau's column-instance derivation)
    #   2. CSV header naming heuristic ("Sum of X" → Sum)
    #   3. Default Sum for numeric, no-agg for text
    agg_label = nil
    (z['aggregations'] || {}).each do |col_ref, deriv|
      stripped = strip_brackets(col_ref)
      if stripped.casecmp(meas['name']).zero? ||
         stripped.casecmp(meas_hdr).zero? ||
         meas_hdr.downcase.include?(stripped.downcase[0..15])
        agg_label = deriv
        break
      end
    end
    agg_label ||= infer_csv_agg(meas_hdr)
    agg_label ||= 'Sum'
    sigma_agg = SIGMA_AGG[agg_label] || 'Sum'

    # derivation=User → the measure IS a Tableau calc field that's already
    # aggregated (typically a ratio like SUM(a)/COUNT(b)). Wrapping it in
    # Sum([Master/X]) is unresolvable when no master column carries the ratio —
    # decompose the calc formula into a direct Sigma formula instead (bead k3kk).
    user_agg_formula = chart_pswitch_plan && chart_pswitch_plan['sibling_form']
    window_plan = nil
    window_calc_name = nil
    # Translate the measure's source calc when it's a Tableau User-aggregated calc
    # (agg=User) OR when the measure header didn't resolve to a master column at all
    # (meas_unresolved) — a window table-calc on a shelf carries a Sum/None pill,
    # not agg=User, so gating on User alone left running-sum / share-of-total LINE
    # and BAR measures emitting an unresolvable Sum([Master/<calc>]). bead y9rd.
    if user_agg_formula.nil? && (agg_label == 'User' || meas_unresolved) && meas['formula'].nil?
      norm = ->(x) { x.to_s.gsub(/^\[|\]$/, '').strip.downcase }
      user_calc = (z['calculations'] || []).find do |c|
        n = norm.call(c['name'])
        cap_n = norm.call(c['caption'])
        targets = [norm.call(meas['name']), norm.call(meas_hdr)]
        # Match on the calc's internal name (Calculation_NNN) OR its human caption
        # ("Running Revenue") — a chart measure header is the CAPTION, so name-only
        # matching missed window calcs in the standard-chart path. bead y9rd.
        (!n.empty? && (targets.include?(n) || norm.call(meas_hdr).include?(n))) ||
          (!cap_n.empty? && targets.include?(cap_n))
      end
      # Window table-calcs FIRST (RUNNING_* / WINDOW_* / RANK / LOOKUP / INDEX /
      # TOTAL): translate to Sigma-native window math on the chart yAxis (see
      # translate_window_calc above — WINPROBE-validated, zero Custom SQL).
      window_plan = user_calc &&
                    translate_window_calc(user_calc['formula'], mmap,
                                          meta['columns_by_guid'] || {})
      record_window_calc(z, user_calc, window_plan) if window_plan
      window_calc_name = user_calc && user_calc['name'].to_s.gsub(/^\[|\]$/, '')
      # v5.4: a POSITIONAL window calc (INDEX()/FIRST() → bare RowNumber()±k,
      # no comparison) as the VALUE axis is a rank HEADER mis-pick, not a
      # measure. In the twb grammar the ranked-bar idiom serializes INDEX() as
      # a DISCRETE instance alongside the category dim while the real
      # bar-length measure (typically a percent-of-total share) rides a shelf
      # as a CONTINUOUS (:qk) instance. Bar length = row position is never the
      # source semantics when such a measure exists — re-target the value to
      # the first continuous shelf calc that translates, and say so loudly.
      if window_plan && window_plan['mode'] == 'inline' &&
         window_plan['formula'].to_s =~ /\A\s*RowNumber\s*\(\s*\)\s*(?:[-+]\s*\d+)?\s*\z/i
        cur_guid = user_calc['name'].to_s.gsub(/^\[|\]$/, '')
        cand_guids = []
        %w[rows_shelf cols_shelf].each do |sh|
          (z.dig(sh, 'fields') || []).each do |ff|
            next unless ff['role'] == 'measure' && ff['raw'].to_s =~ /:qk(?::\d+)?\]/
            g = ff['guid'].to_s
            cand_guids << g unless g.empty? || g == cur_guid
          end
          # A shelf EXPRESSION ("(inst + inst)" — the dual-instance overlay
          # idiom) parses as one field with guid nil; recover the instance
          # guids from the raw shelf text ([<deriv>:<guid>:qk[:n]] tokens).
          z.dig(sh, 'raw').to_s.scan(/\[[a-z]+:([^:\[\]]+):qk(?::\d+)?\]/i) do |(g)|
            cand_guids << g unless g.to_s.empty? || g == cur_guid
          end
        end
        cand_guids.uniq.each do |g|
          # Prefer the worksheet-calc entry — it carries ordering_field (the
          # table-calc addressing) which the share-scope audit below needs.
          info = (z['calculations'] || []).find { |c| c['name'].to_s.gsub(/^\[|\]$/, '') == g } ||
                 (meta['columns_by_guid'] || {})[g]
          cform = info.is_a?(Hash) ? info['formula'].to_s : ''
          next if cform.strip.empty?
          plan2 = translate_window_calc(cform, mmap, meta['columns_by_guid'] || {})
          next unless plan2 && %w[inline inline-share].include?(plan2['mode']) &&
                      plan2['formula'].to_s !~ /\A\s*RowNumber\s*\(\s*\)\s*(?:[-+]\s*\d+)?\s*\z/i
          cap2 = (info['caption'] || info['name']).to_s.gsub(/^\[|\]$/, '').strip
          cap2 = g if cap2.empty?
          warnings << "'#{cap}' value axis: '#{meas_hdr}' (#{user_calc['formula'].to_s[0..40]}) is a positional " \
                      "rank header, never a bar value — re-targeted to the continuous shelf measure '#{cap2}'"
          user_calc = { 'name' => "[#{g}]", 'caption' => cap2, 'formula' => cform,
                        'ordering_field' => (info.is_a?(Hash) ? info['ordering_field'] : nil) }
          window_plan = plan2
          record_window_calc(z, user_calc, window_plan)
          window_calc_name = g
          meas_hdr = cap2
          meas = { 'id' => "m-#{cap2.downcase.gsub(/\W+/, '-')}", 'name' => cap2 }
          break
        end
      end
      case window_plan && window_plan['mode']
      when 'inline'
        user_agg_formula = window_plan['formula']
        warnings << "'#{cap}' measure '#{meas_hdr}' is a Tableau window table-calc — auto-emitted as a Sigma " \
                    "viz formula on the yAxis: #{user_agg_formula[0..140]}  [#{window_plan['note']}]"
      when 'inline-share'
        # v5.1 Rule W1 (chart): non-pivot shares stay grand_total (partition
        # modes are PIVOT-ONLY per round-3 consensus + live-probed product
        # fact: partition scopes collapse to grand-total on chart formulas).
        user_agg_formula =
          if window_plan['share_kind'] == 'percent_of_total'
            %(PercentOfTotal(#{window_plan['inner']}, "grand_total"))
          else
            window_plan['inner']
          end
        # v5.4 scope AUDIT: the table-calc addressing ("compute using <dim>",
        # parser ordering_field) names the dim the share normalizes ACROSS;
        # everything else in the view partitions it. grand_total is only
        # value-correct when the addressing spans the chart's whole dim set.
        # A partitioned share can't be expressed as a Sigma chart formula —
        # ship grand_total but say LOUDLY that the number diverges from the
        # source and the tile needs a grouped-helper rebuild (STAYS-MANUAL
        # class), instead of a silently wrong export.
        if window_plan['share_kind'] == 'percent_of_total'
          addr = user_calc['ordering_field'].to_s
          chart_dims = [dim_hdr, color_hdr].map { |x| x.to_s.strip }.reject(&:empty?)
          nrmw = ->(x) { x.to_s.downcase.gsub(/[^a-z0-9]/, '') }
          covers_all = chart_dims.size <= 1 &&
                       (chart_dims.empty? || nrmw.call(addr) == nrmw.call(chart_dims.first))
          if !addr.empty? && !covers_all
            part = chart_dims.reject { |dh| nrmw.call(dh) == nrmw.call(addr) }
            warnings << "'#{cap}' share scope MISMATCH: the source computes this share across " \
                        "'#{addr}' only (partitioned by #{part.empty? ? 'the remaining view dims' : part.map(&:inspect).join(', ')}); " \
                        'Sigma chart formulas support grand_total ONLY, so the emitted values will diverge ' \
                        'from the source — STAYS-MANUAL: rebuild via a grouped helper element that computes ' \
                        'the partitioned share (refs/fidelity-recipes.md §Ranked pivot)'
          end
        end
        # downstream reads window_plan['formula'] (top-N auto-sort, dedup) —
        # carry the emitted share so it is never nil (review-caught).
        window_plan = window_plan.merge('mode' => 'inline', 'formula' => user_agg_formula)
        warnings << "'#{cap}' measure '#{meas_hdr}' is a window-wrapped share — emitted " \
                    "#{user_agg_formula[0..120]} [#{window_plan['note']}]"
      when 'two-stage'
        # Helper built below once the dim/color column objects exist.
        warnings << "'#{cap}' measure '#{meas_hdr}' is an unbounded window aggregate — auto-built as a hidden " \
                    "two-level grouped helper [#{window_plan['note']}]"
      when 'manual'
        warnings << "'#{cap}' measure '#{meas_hdr}' STAYS MANUAL: #{window_plan['note']}. " \
                    "Formula: #{user_calc['formula'].to_s.gsub(/\s+/, ' ')[0..140]}"
        window_plan = nil
      end
      user_agg_formula ||= (window_plan.nil? || window_plan['mode'] != 'two-stage') && user_calc &&
                           translate_user_agg_formula(user_calc['formula'], mmap,
                                                      meta['columns_by_guid'] || {}) || nil
      # Parameter-driven metric/measure SWITCH (bead param-msw): the calc picks
      # which measure the chart shows via a control — SUM(CASE [Parameters].[P]
      # WHEN 0 THEN [A] WHEN 1 THEN [B] END) or IF [P]="x" THEN SUM([A]) ELSE
      # SUM([B]) END. translate_user_agg_formula can't decompose it, so without
      # this it fell through to an unbound Sum([Master/<calc>]) and the control
      # drove NOTHING (only dimension-swaps worked). Bind the control-driven
      # Switch as THIS measure's yAxis formula; the calc-loop below materialises
      # the branch sibling cols and registers the control under the same id.
      if user_agg_formula.nil? && user_calc && !(window_plan && window_plan['mode'] == 'two-stage')
        pcaps = (meta['parameters'] || []).map { |pp| pp['caption'] }.compact
        pnmap = {}
        (meta['parameters'] || []).each { |pp| pc = pp['caption']; pn = pp['name'].to_s.gsub(/^\[|\]$/, ''); pnmap[pn] = pc if pc && !pn.empty? }
        fpn = user_calc['formula'].to_s.gsub(/(\[Parameters?\]\s*\.\s*\[)([^\]]+)(\])/i) { "#{$1}#{pnmap[$2] || $2}#{$3}" }
        psw = translate_case_on_param(fpn, pcaps, mmap, meta['columns_by_guid'] || {}) ||
              translate_if_chain_on_param(fpn, pcaps, mmap, meta['columns_by_guid'] || {})
        if psw
          psw_sibling = psw.gsub(%r{\[Master/([^\]]+)\]}) { "[#{Regexp.last_match(1)}]" }
          # Branches already aggregated (IF [P] THEN SUM(x)…) → the Switch IS the
          # measure; bare branches (SUM(CASE…THEN [col])) → wrap in the shelf agg.
          pre_agg = psw_sibling =~ /\b(?:Sum|Avg|Min|Max|Count|CountDistinct|Median|StdDev|StdDevPop|Variance|VariancePop)\s*\(/
          shelf_agg = SIGMA_AGG[infer_csv_agg(meas_hdr) || 'Sum'] || 'Sum'
          user_agg_formula = pre_agg ? psw_sibling : "#{shelf_agg}(#{psw_sibling})"
          warnings << "'#{cap}' measure '#{meas_hdr}' is a parameter-driven metric switch — bound to the control-driven Switch on the yAxis: #{user_agg_formula[0..140]}"
        end
      end
      if user_agg_formula && !(window_plan && window_plan['mode'] == 'inline')
        warnings << "'#{cap}' measure '#{meas['name']}' is a Tableau User-aggregated calc — emitted its decomposed Sigma formula directly: #{user_agg_formula[0..140]}"
      elsif user_agg_formula.nil? && !(window_plan && window_plan['mode'] == 'two-stage')
        # Fall back to the CSV-header aggregation hint ("Avg. X" → Avg), not a
        # raw column ref (which Sigma's yAxis silently Sum()s — bead z1d0).
        sigma_agg = SIGMA_AGG[infer_csv_agg(meas_hdr) || 'Sum'] || 'Sum'
        warnings << "'#{cap}' measure '#{meas['name']}' has Tableau aggregation=User but its calc formula could not be auto-decomposed — falling back to #{sigma_agg}([Master/#{meas['name']}]), which is only correct if a master column (or --master-col placeholder) carries that value"
      end
    end

    # Decide if the dimension is a date that needs DateTrunc. The parser's
    # aggregations dict surfaces Month-Trunc / Year-Trunc / etc. on the date col.
    dim_trunc = nil
    (z['aggregations'] || {}).each do |col_ref, deriv|
      stripped = strip_brackets(col_ref)
      if DATE_TRUNC.key?(deriv) &&
         (stripped.casecmp(dim['name']).zero? || dim_hdr.downcase.include?('date'))
        dim_trunc = DATE_TRUNC[deriv]
        break
      end
    end
    # Header-derived fallback: Tableau CSV date headers carry the grain
    # ("Month of Order Date" / "Week of Order Date") even when the
    # column-instance derivation didn't resolve (bead ovud).
    if dim_trunc.nil? && (hm = dim_hdr.match(/^(second|minute|hour|day|week|month|quarter|year) of /i))
      dim_trunc = hm[1].downcase
    end

    el_id = "el-#{cap.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')

    # If the dim column is aliased in Tableau (raw → display mapping), wrap the
    # master ref in a Switch() so the chart displays the friendly labels.
    aliases_for_dim = (meta['column_aliases'] || {})[dim['name']] ||
                      (meta['column_aliases'] || {})[dim_hdr]
    dim_formula = if dim['formula']                     # explicit formula override
                    dim['formula']
                  elsif aliases_for_dim && !aliases_for_dim.empty?
                    parts = ["[Master/#{dim['name']}]"]
                    aliases_for_dim.each { |a| parts << a['key'].inspect; parts << a['value'].inspect }
                    parts << "[Master/#{dim['name']}]"  # default: pass through raw value
                    "Switch(#{parts.join(', ')})"
                  elsif dim_trunc == 'week'
                    # Tableau weeks start SUNDAY (default date-options); Sigma's
                    # DateTrunc("week") follows the warehouse week start (Monday
                    # on Snowflake). Sigma Weekday() returns 1=Sunday, so the
                    # Sunday-start bucket is convention-free arithmetic (s6fo:
                    # weekly-grain parity compares the underlying date value).
                    %(DateAdd("day", 1 - Weekday([Master/#{dim['name']}]), DateTrunc("day", [Master/#{dim['name']}])))
                  elsif dim_trunc
                    %(DateTrunc("#{dim_trunc}", [Master/#{dim['name']}]))
                  else
                    "[Master/#{dim['name']}]"
                  end
    # If the measure mapping carries a `formula` key, that's a workbook-level
    # calc like Return Rate = Sum(...)/Count(...). Use it verbatim. Otherwise
    # wrap the master-table column with the Sigma aggregator picked above.
    measure_formula = if meas['formula']
                        meas['formula']
                      elsif user_agg_formula
                        user_agg_formula
                      else
                        render_agg(sigma_agg, "[Master/#{meas['name']}]")
                      end
    # Prefer a governed [Metrics/<name>] ref when this inline aggregate matches a
    # DM metric by formula equivalence; safe no-op (inline) otherwise.
    measure_formula = MetricBinding.metric_ref_or_inline(measure_formula, 'Master', opts[:metrics])
    # v5.4: NUMERIC aggregates over a TEXT column compile to type=error on the
    # live workbook (Sum/Avg/Median are numeric-only). Tableau's CSV header
    # order can hand a string column to the measure slot (the scatter
    # y=Sum(text) class) — emit the raw column ref + a loud note instead of a
    # dead column. Datatype from the twb column registry; unknown types pass.
    if (tm = measure_formula.match(/\A(Sum|Avg|Median)\(\[Master\/([^\]]+)\]\)\z/))
      tinfo = (meta['columns_by_guid'] || {}).values.find do |v|
        v.is_a?(Hash) && v['caption'].to_s.strip.casecmp?(tm[2].strip)
      end
      tinfo ||= (meta['columns_by_guid'] || {})[tm[2]]
      if tinfo.is_a?(Hash) && tinfo['datatype'].to_s == 'string'
        warnings << "'#{cap}' measure #{tm[1]}([#{tm[2]}]) aggregates a TEXT column — emitted the raw column " \
                    'instead (numeric aggregates over text compile to type=error); the source likely encodes ' \
                    'this on label/shape/detail — VERIFY the tile or re-author'
        measure_formula = "[Master/#{tm[2]}]"
      end
    end

    dim_col_obj = { 'id' => "x-#{el_id}", 'name' => dim['name'], 'formula' => dim_formula }
    if dim_trunc
      dim_col_obj['format'] = { 'kind' => 'datetime',
                                'formatString' => dim_trunc == 'week' ? '%b %d, %Y' : '%b %Y' }
    end
    color_col_obj = nil
    if color_dim
      color_col_obj = { 'id' => "c-#{el_id}", 'name' => color_dim['name'],
                        'formula' => color_dim['formula'] || "[Master/#{color_dim['name']}]" }
    end

    # By-MEASURE (continuous) color: a measure on Tableau's Color shelf is a
    # color RAMP, not a categorical series. When the 3-channel dim path above
    # did NOT claim a color dim and channels.color resolves to a measure, emit
    # color:{by:scale} on a DUPLICATE measure column (a column can't sit on both
    # yAxis and color) — mirrors qlik_color's byMeasure branch. The duplicate
    # column object is built in the finalize block once the y-measure exists.
    color_scale = nil
    if color_dim.nil?
      cs = color_measure_field(z.dig('channels', 'color'), meta, mmap)
      color_scale = cs if cs
    end

    # ---- Two-stage aggregation (FIXED LOD / grain-aware average) ------------
    # See the parse_fixed_lod block comment. Both cases retarget the chart at a
    # hidden helper element; every downstream block that wraps the column
    # formulas (null-dim IsNotNull, sort, dataLabel) keeps working because the
    # column OBJECTS keep their ids/names — only formulas + source change.
    chart_source_eid = opts[:master_id]
    if window_plan && window_plan['mode'] == 'two-stage'
      # Unbounded partitioned window aggregate (WINDOW_MAX/MIN/SUM, TOTAL):
      # partition = the chart's color/series dim (Tableau's default
      # Table(Across) addressing restarts per pane row); addressing = the
      # plotted x dim. No color dim = a whole-table window (constant key).
      partition = color_col_obj ? [{ 'name' => color_col_obj['name'], 'formula' => color_col_obj['formula'] }] : []
      value_name = "#{window_plan['value_formula'][/\[Master\/([^\]]+)\]/, 1] || header_base(meas_hdr)} Window Base"
      helper, src_name = build_window_helper(
        el_id: el_id, master_id: opts[:master_id],
        partition_dims: partition,
        addressing_dims: [{ 'name' => dim['name'], 'formula' => dim_formula }],
        value_name: value_name, value_formula: window_plan['value_formula'],
        stages: [{ 'name' => header_base(meas_hdr), 'agg' => window_plan['stage_agg'] }])
      data_elements << helper
      chart_source_eid = helper['id']
      dim_col_obj['formula'] = "[#{src_name}/#{dim['name']}]"
      color_col_obj['formula'] = "[#{src_name}/#{color_col_obj['name']}]" if color_col_obj
      measure_formula = "#{window_plan['retrieve_agg']}([#{src_name}/#{header_base(meas_hdr)}])"
      warnings << "'#{cap}' unbounded window measure '#{meas_hdr}' → hidden helper '#{src_name}' " \
                  "(outer grouping = #{partition.any? ? partition.map { |d| d['name'] }.join(', ') : 'whole table'}, " \
                  "inner = #{dim['name']}; consumer #{window_plan['retrieve_agg']}s the broadcast stage value) ⚠ verify in Sigma"
      if partition.size > 1 || (color_col_obj && z.dig('channels', 'color').nil?)
        warnings << "'#{cap}' window partition has more than one split dim — multi-dim partitions beyond a single " \
                    'color split are UNTESTED; verify the windowed values against Tableau before shipping'
      end
    elsif meas['formula'].nil? && user_agg_formula.nil?
      lod_calc = (z['calculations'] || []).find do |c|
        c['name'].to_s.gsub(/^\[|\]$/, '').strip.casecmp?(header_base(meas_hdr))
      end
      # NB: parse_fixed_lod is nil for NESTED {FIXED} calcs — those route
      # through decompose_nested_fixed (helper-element chain, -lod-chains.json
      # sidecar) in the calc loop below; the agent wires the chain manually.
      lod_parse = lod_calc && parse_fixed_lod(lod_calc['formula'], meta['columns_by_guid'] || {})
      lod_ref = lod_parse && lod_inner_ref(lod_parse, mmap, meta['columns_by_guid'] || {})
      if lod_parse && lod_ref
        # FIXED LOD → two-level grouped helper: inner = FIXED dims computing
        # the LOD aggregate, outer = the chart's plotted dims computing the
        # second-stage aggregate; chart Max()es the replicated outer calc.
        map_name = ->(capn) { (mm = map_column(capn, mmap)) ? mm['name'] : capn }
        inner_keys = lod_parse['dims'].map { |d| n = map_name.call(d); { 'name' => n, 'formula' => "[Master/#{n}]" } }
        value_name = header_base(meas_hdr)
        outer_dims = [{ 'name' => dim['name'], 'formula' => dim_formula }]
        outer_dims << { 'name' => color_col_obj['name'], 'formula' => color_col_obj['formula'] } if color_col_obj
        stage2 = (SIGMA_AGG[agg_label] unless %w[None User].include?(agg_label.to_s)) || 'Avg'
        helper, src_name, s2_name = build_two_stage_helper(
          el_id: el_id, master_id: opts[:master_id], value_name: value_name,
          value_formula: render_agg(LOD_INNER_AGG[lod_parse['agg']], lod_ref),
          inner_keys: inner_keys, outer_dims: outer_dims, stage2_agg: stage2)
        data_elements << helper
        chart_source_eid = helper['id']
        dim_col_obj['formula'] = "[#{src_name}/#{dim['name']}]"
        color_col_obj['formula'] = "[#{src_name}/#{color_col_obj['name']}]" if color_col_obj
        measure_formula = "Max([#{src_name}/#{s2_name}])"
        warnings << "'#{cap}' measure '#{meas_hdr}' is a FIXED LOD ({FIXED #{lod_parse['dims'].join(', ')} : " \
                    "#{lod_parse['agg']}(#{lod_parse['label']})}) — auto-built hidden grouped helper '#{src_name}' " \
                    "(inner grain = FIXED dims, 2nd-stage #{stage2} at chart grain) ⚠ exact iff the chart dims are " \
                    'functionally dependent on the FIXED dims — verify in Sigma'
      elsif lod_parse && lod_ref.nil?
        # FIXED LOD whose conditional/expression inner isn't auto-translatable —
        # steer to the data-model Custom SQL path instead of silently degrading.
        warnings << "'#{cap}' measure '#{meas_hdr}' is a FIXED LOD with a conditional/expression inner " \
                    "(#{lod_parse['agg']}(#{lod_parse['label']})) that can't be auto-translated to a workbook helper — " \
                    "implement it as a data-model Custom SQL element: #{lod_parse['agg']}(CASE …) " \
                    "OVER (PARTITION BY #{lod_parse['dims'].join(', ')}). See refs/phase-3-datamodel.md."
      elsif (rel = lod_calc && parse_relative_lod(lod_calc['formula'], meta['columns_by_guid'] || {}))
        # INCLUDE / EXCLUDE LOD — relative to the chart's VIEW grain.
        map_name = ->(capn) { (mm = map_column(capn, mmap)) ? mm['name'] : capn }
        rel_meas  = map_name.call(rel['measure'])
        value_name = header_base(meas_hdr)
        view_dims = [{ 'name' => dim['name'], 'formula' => dim_formula }]
        view_dims << { 'name' => color_col_obj['name'], 'formula' => color_col_obj['formula'] } if color_col_obj
        value_formula = render_agg(LOD_INNER_AGG[rel['agg']], "[Master/#{rel_meas}]")
        if rel['type'] == 'INCLUDE'
          # INCLUDE adds dims BELOW the view: inner = INCLUDE dims (nested under
          # the view), outer = view dims, 2nd stage = the view's aggregation.
          inner_keys = rel['dims'].map { |d| n = map_name.call(d); { 'name' => n, 'formula' => "[Master/#{n}]" } }
          stage2 = (SIGMA_AGG[agg_label] unless %w[None User].include?(agg_label.to_s)) || 'Avg'
          helper, src_name, s2_name = build_two_stage_helper(
            el_id: el_id, master_id: opts[:master_id], value_name: value_name,
            value_formula: value_formula, inner_keys: inner_keys,
            outer_dims: view_dims, stage2_agg: stage2)
          data_elements << helper
          chart_source_eid = helper['id']
          dim_col_obj['formula'] = "[#{src_name}/#{dim['name']}]"
          color_col_obj['formula'] = "[#{src_name}/#{color_col_obj['name']}]" if color_col_obj
          measure_formula = "Max([#{src_name}/#{s2_name}])"
          warnings << "'#{cap}' measure '#{meas_hdr}' is an INCLUDE LOD ({INCLUDE #{rel['dims'].join(', ')} : " \
                      "#{rel['agg']}(#{rel['measure']})}) — auto-built hidden grouped helper '#{src_name}' " \
                      "(inner = INCLUDE dims below the view, 2nd-stage #{stage2} at view grain) ⚠ verify in Sigma"
        else
          # EXCLUDE removes dims from the view → value at (view − excluded),
          # broadcast across the excluded dims. Exact only for composable aggs
          # (SUM/MAX/MIN/COUNT, where agg-of-agg == agg).
          present = view_dims.select { |d| rel['dims'].map { |x| map_name.call(x) }.include?(d['name']) }
          if !LOD_COMPOSABLE_AGGS.include?(rel['agg'])
            warnings << "'#{cap}' EXCLUDE LOD uses #{rel['agg']} (not composable as agg-of-agg) — STAYS MANUAL: " \
                        're-author at the coarser grain in Sigma'
          elsif present.empty?
            # the excluded dims aren't plotted here → EXCLUDE reduces to a plain
            # aggregate at the view grain.
            measure_formula = value_formula
            warnings << "'#{cap}' EXCLUDE LOD on [#{rel['dims'].join(', ')}] — none of those dims are in this view, " \
                        "so it reduces to #{rel['agg']}(#{rel['measure']}) at view grain"
          else
            outer_dims = view_dims.reject { |d| present.any? { |p| p['name'] == d['name'] } }
            inner_keys = present.map { |d| { 'name' => d['name'], 'formula' => "[Master/#{d['name']}]" } }
            stage2 = { 'SUM' => 'Sum', 'MAX' => 'Max', 'MIN' => 'Min', 'COUNT' => 'Sum' }[rel['agg']]
            helper, src_name, s2_name = build_two_stage_helper(
              el_id: el_id, master_id: opts[:master_id], value_name: value_name,
              value_formula: value_formula, inner_keys: inner_keys,
              outer_dims: outer_dims, stage2_agg: stage2)
            data_elements << helper
            chart_source_eid = helper['id']
            dim_col_obj['formula'] = "[#{src_name}/#{dim['name']}]"
            color_col_obj['formula'] = "[#{src_name}/#{color_col_obj['name']}]" if color_col_obj
            measure_formula = "Max([#{src_name}/#{s2_name}])"
            warnings << "'#{cap}' measure '#{meas_hdr}' is an EXCLUDE LOD ({EXCLUDE #{rel['dims'].join(', ')} : " \
                        "#{rel['agg']}(#{rel['measure']})}) — auto-built hidden grouped helper '#{src_name}' " \
                        "(value at view minus [#{rel['dims'].join(', ')}], broadcast via #{stage2}) ⚠ verify in Sigma"
          end
        end
      elsif sigma_agg == 'Avg' && meas['grain'] &&
            dim['formula'].nil? && dim_trunc.nil? && (aliases_for_dim.nil? || aliases_for_dim.empty?) &&
            dim['grain'] && dim['grain']['element'] == meas['grain']['element'] &&
            (color_dim.nil? || (color_dim['grain'] && color_dim['grain']['element'] == meas['grain']['element']))
        # Grain-aware average over a dim-table measure, plotted by dims that
        # live on the SAME dim element → source the dim element at its native
        # grain (ungrouped passthrough); the chart's Avg is then per-entity.
        names = [dim['name'], meas['name']]
        names << color_dim['name'] if color_dim
        helper, src_name = build_dim_grain_helper(el_id: el_id, grain: meas['grain'], columns: names.uniq)
        data_elements << helper
        chart_source_eid = helper['id']
        dim_col_obj['formula'] = "[#{src_name}/#{dim['name']}]"
        color_col_obj['formula'] = "[#{src_name}/#{color_col_obj['name']}]" if color_col_obj
        measure_formula = "Avg([#{src_name}/#{meas['name']}])"
        warnings << "'#{cap}' averages a #{meas['grain']['element']} column — Tableau evaluates this at the dim table's " \
                    "native grain (relationship semantics); chart sources the DM '#{meas['grain']['element']}' element via " \
                    "hidden helper '#{src_name}' ⚠ verify in Sigma"
      elsif sigma_agg == 'Avg' && meas['grain']
        warnings << "'#{cap}' averages dim-table column '#{meas['name']}' (#{meas['grain']['element']}) but its chart dims " \
                    'are not plain columns of that dim element — left at row grain; values may diverge from Tableau ' \
                    '(relationship semantics average at the dim grain). Verify or restructure manually.'
      end
    end

    # ---- Aggregate-derived grouping dimension (calc-on-calc; y9rd.13) -------
    # The chart is grouped by a dimension that buckets an aggregate metric
    # (converter `aggregate-dimension` workbookPattern). It can't be a master
    # column or a metric, so build a hidden grouped helper at the chart's BASE
    # grain (the color dim, else whole table) whose group calculations are the
    # referenced aggregate metric(s) + this tile's measure; then group the chart
    # by the bucket expression over that element and re-aggregate the measure.
    # Skip when the measure path already retargeted the source (rare combo) —
    # surface it rather than emit two competing helpers.
    agg_dim = agg_dim_for(dim_hdr, dim && dim['name'])
    if agg_dim
      if chart_source_eid != opts[:master_id]
        warnings << "'#{cap}' is grouped by aggregate-derived dimension '#{dim['name']}' AND its measure needed a " \
                    'helper element — the combination is unsupported; the aggregate-dimension grouping was NOT wired ' \
                    '(verify manually).'
      else
        agg_metrics = agg_dim['agg_refs'].map do |r|
          mc = map_column(r, mmap)
          (mc && mc['formula'] && !mc['formula'].to_s.empty?) ? { 'name' => mc['name'], 'formula' => mc['formula'] } : nil
        end
        if agg_metrics.any? && agg_metrics.none?(&:nil?)
          base_dims = color_col_obj ? [{ 'name' => color_col_obj['name'], 'formula' => color_col_obj['formula'] }] : []
          inner, passthru, pass_name = build_aggregate_dim_helper(
            el_id: el_id, master_id: opts[:master_id], base_dims: base_dims,
            agg_metrics: agg_metrics, measure: { 'name' => meas['name'], 'formula' => measure_formula },
            bucket_name: dim['name'], bucket_formula: agg_dim['formula'])
          data_elements << inner
          data_elements << passthru
          chart_source_eid = passthru['id']
          # Chart sources the PASSTHRU (one row per base group): plot the bucket
          # column raw and Sum the measure across the bucket's groups.
          dim_col_obj['formula'] = "[#{pass_name}/#{dim['name']}]"
          dim_col_obj.delete('format') # the bucket is a text label, never a date
          color_col_obj['formula'] = "[#{pass_name}/#{color_col_obj['name']}]" if color_col_obj
          measure_formula = "#{sigma_agg}([#{pass_name}/#{meas['name']}])"
          warnings << "'#{cap}' grouped by aggregate-derived dimension '#{dim['name']}' (#{agg_dim['formula']}) → " \
                      "hidden helper chain (inner grouped at base grain = " \
                      "#{base_dims.any? ? base_dims.map { |d| d['name'] }.join(', ') : 'whole table'} computing " \
                      "[#{agg_metrics.map { |m| m['name'] }.join('], [')}] + measure; passthru '#{pass_name}' reads it " \
                      "via groupingId and buckets it); chart #{sigma_agg}'s the measure per bucket — exact for " \
                      'composable aggregates (Sum/Min/Max/Count) [y9rd.13] ⚠ verify in Sigma'
        else
          warnings << "'#{cap}' aggregate-derived dimension '#{dim['name']}' references aggregate metric(s) " \
                      "[#{agg_dim['agg_refs'].join('], [')}] not all resolvable in the master map — left unwired " \
                      '(the bar would be viz-pruned; verify manually).'
        end
      end
    end

    meas_col_obj = { 'id' => "y-#{el_id}", 'name' => meas['name'], 'formula' => measure_formula }
    # Format priority (source-fidelity order):
    #   1. the worksheet's OWN Tableau format for this measure (zone.formats) —
    #      the DISPLAY ground truth; the same measure can render at different
    #      precision per sheet, and the DM's auto-inferred master format often
    #      picks 2 decimals for a percent calc where the source shows 1 (65.04%
    #      vs 65.0%). The source viz wins.
    #   2. explicit `format` on the master-map entry (DM/curated)
    #   3. heuristic by header name
    tab_fmt = pick_tableau_format(z['formats'], meas_hdr) ||
              pick_tableau_format(z['formats'], meas['name']) ||
              # PR-12: the column's .twb default-format (still source truth;
              # outranks the DM-inferred master-map format + the name heuristic)
              pick_column_default_format(meas_hdr) ||
              pick_column_default_format(meas['name'])
    meas_col_obj['format'] = tab_fmt
    meas_col_obj['format'] ||= meas['format'] if meas['format'].is_a?(Hash)
    meas_col_obj['format'] ||= heuristic_number_format(meas['name'])
    # Allow `format` on map entries to be either a Sigma format object OR a
    # bare formatString string for convenience.
    if meas['format'].is_a?(String)
      meas_col_obj['format'] = { 'kind' => 'number', 'formatString' => meas['format'] }
    end
    # Attainment/share ratios (a measure ÷ a goal/target/budget/quota) are
    # percentages by convention — same rule the pivot path applies (y9rd.5). The
    # converter often guesses CURRENCY for such a metric (its numerator is
    # revenue/$), so this override fires LAST, after meas['format']. Gate on an
    # actual division so plain currency measures ("Revenue Goal") never flip.
    if measure_formula.to_s =~ %r{/} &&
       (meas['name'].to_s =~ /attain|\bshare\b|sell[-\s]?through|win[-\s]?rate|conversion/i ||
        measure_formula.to_s =~ /\b(goal|target|budget|quota|plan|forecast)\b/i)
      meas_col_obj['format'] = { 'kind' => 'number', 'formatString' => ',.1%' }
    end
    # Windowed-measure format overrides: a rank named "Revenue Rank" would
    # otherwise inherit the $-currency heuristic from the /revenue/ name match.
    if window_plan && window_plan['mode'] == 'inline'
      case window_plan['formula']
      when /\A\s*RankPercentile\(/ then meas_col_obj['format'] = { 'kind' => 'number', 'formatString' => ',.1%' }
      when /\A\s*(Rank|RankDense|RowNumber)\(/ then meas_col_obj['format'] = { 'kind' => 'number', 'formatString' => ',.0f' }
      when /\A\s*(CumulativeSum\(PercentOfTotal|PercentOfTotal)\(/ then meas_col_obj['format'] = { 'kind' => 'number', 'formatString' => ',.2%' }
      end
    end

    kind = SIGMA_KIND[z['chart_kind']] || 'bar-chart'
    if z['chart_kind'] == 'automatic'
      warnings << "'#{cap}' has chart_kind=automatic — defaulted to bar-chart; verify against PNG"
    end
    # v5.4 DONUT discriminator: Tableau has no donut mark — a donut is a Pie
    # mark whose rows/cols shelf carries ONLY constant-aggregate placeholder
    # instances, STACKED on a dual/blended axis (the dual-AVG(0) hack: two pies
    # share one constant axis, the smaller one making the hole). A plain pie
    # has no such shelf. Grammar-level test, no fixture knowledge: every shelf
    # measure resolves to a placeholder calc AND the shelf raw carries the
    # multi-instance '+' axis marker (`[..] + [..]`) — a SINGLE dummy-axis
    # instance is just a vertically-positioned pie, not the donut idiom
    # (v5.4.9 review fix).
    if kind == 'pie-chart'
      shelf_meas = ((z.dig('rows_shelf', 'fields') || []) + (z.dig('cols_shelf', 'fields') || []))
                   .select { |f| f['role'] == 'measure' }
      shelf_raw = "#{z.dig('rows_shelf', 'raw')} #{z.dig('cols_shelf', 'raw')}"
      if shelf_meas.any? && shelf_raw =~ /\]\s*\+\s*[(\[]/ && shelf_meas.all? { |f|
           placeholder_calc?(((meta['columns_by_guid'] || {})[f['guid'].to_s] || {})['formula'])
         }
        kind = 'donut-chart'
        warnings << "'#{cap}' pie mark rides stacked constant-aggregate dummy axes (the Tableau donut idiom) — " \
                    'emitted as donut-chart'
      end
    end

    # Scatter fast path (bead z1d0, ported from the PBI builder's verified
    # ry0n fix): Sigma's scatter xAxis is a GROUPING axis — binding an
    # AGGREGATE makes it evaluate per source row and the chart plots raw rows.
    # Pre-aggregate in a HIDDEN grouped source table on the Data page (dim +
    # x/y aggregates grouped by the dim), then point the scatter at it with
    # ALL-RAW column refs. The detail dim MUST stay on color:{by:category} —
    # points sharing an x merge to a null y without it.
    if kind == 'scatter-chart' && headers.length >= 3
      meas2_hdr = headers[2].to_s.strip
      meas2 = map_column(meas2_hdr, mmap) ||
              { 'id' => "m-#{meas2_hdr.downcase.gsub(/\W+/, '-')}", 'name' => meas2_hdr }
      # Tableau scatter: Cols shelf = X measure, Rows shelf = Y measure. The
      # CSV column order is not axis order — resolve via the shelves; fall
      # back to CSV order [dim, y, x] (matches Tableau's export convention).
      shelf_cap = lambda do |shelf|
        f = (shelf || {})['fields']&.find { |x| x['role'] == 'measure' }
        f && resolve_shelf_field(f, meta, mmap).last.to_s.strip
      end
      x_cap = shelf_cap.call(z['cols_shelf'])
      y_cap = shelf_cap.call(z['rows_shelf'])
      m_for = lambda do |hdr_cap|
        h = hdr_cap.to_s.sub(/^(?:sum|avg|average|min|max|median|distinct count|count) of /i, '')
                   .sub(/^(?:avg|sum|min|max|med|cnt|ctd)\.\s*/i, '').strip
        [[meas, meas_hdr], [meas2, meas2_hdr]].find do |(_, mh)|
          mh.to_s.sub(/^(?:sum|avg|average|min|max|median|distinct count|count) of /i, '')
            .sub(/^(?:avg|sum|min|max|med|cnt|ctd)\.\s*/i, '').strip.casecmp?(h)
        end
      end
      x_pair = (x_cap && m_for.call(x_cap)) || [meas2, meas2_hdr]
      y_pair = (y_cap && m_for.call(y_cap)) || ([[meas, meas_hdr], [meas2, meas2_hdr]] - [x_pair]).first
      agg_for = lambda do |mm, hdr|
        next mm['formula'] if mm['formula'] # verbatim aggregate from master-map
        a = SIGMA_AGG[infer_csv_agg(hdr) || 'Sum'] || 'Sum'
        render_agg(a, "[Master/#{mm['name']}]")
      end
      # SIZE channel: a measure on Tableau's Size shelf scales each bubble.
      # Sigma's scatter size is size:{id:<col>} — the column must be a grouped
      # CALCULATION on the same hidden source (one value per point dim), exactly
      # like x/y (mirrors qlik_color's scatter size branch). Resolve the size
      # measure from channels.size; skip when it's a dimension or unresolvable.
      size_field = color_measure_field(z.dig('channels', 'size'), meta, mmap)
      src_id   = "#{el_id}-src"
      src_name = "#{cap} Source"
      gd = "#{src_id}-d"
      gx = "#{src_id}-x"
      gy = "#{src_id}-y"
      gz = "#{src_id}-z"
      src_columns = [
        { 'id' => gd, 'name' => dim['name'], 'formula' => dim['formula'] || "[Master/#{dim['name']}]" },
        { 'id' => gx, 'name' => x_pair[0]['name'], 'formula' => agg_for.call(x_pair[0], x_pair[1]) },
        { 'id' => gy, 'name' => y_pair[0]['name'], 'formula' => agg_for.call(y_pair[0], y_pair[1]) }
      ]
      src_calcs = [gx, gy]
      if size_field
        src_columns << { 'id' => gz, 'name' => size_field['name'], 'formula' => size_field['formula'] }
        src_calcs << gz
      end
      data_elements << {
        'id' => src_id, 'kind' => 'table', 'name' => src_name,
        'source' => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columns' => src_columns,
        'groupings' => [{ 'id' => "#{src_id}-g", 'groupBy' => [gd], 'calculations' => src_calcs }],
        'visibleAsSource' => false
      }
      money_fmt = { 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }
      num_fmt = ->(n) { n.to_s.downcase =~ /(revenue|profit|cost|sales|amount|spend)/ ? money_fmt : { 'kind' => 'number', 'formatString' => ',.0f' } }
      element = {
        'id' => el_id, 'kind' => 'scatter-chart', 'name' => tile_title(z, cap),
        'source' => { 'kind' => 'table', 'elementId' => src_id },
        'columns' => [
          { 'id' => "c-#{el_id}", 'name' => dim['name'], 'formula' => "[#{src_name}/#{dim['name']}]" },
          { 'id' => "x-#{el_id}", 'name' => x_pair[0]['name'], 'formula' => "[#{src_name}/#{x_pair[0]['name']}]", 'format' => num_fmt.call(x_pair[0]['name']) },
          { 'id' => "y-#{el_id}", 'name' => y_pair[0]['name'], 'formula' => "[#{src_name}/#{y_pair[0]['name']}]", 'format' => num_fmt.call(y_pair[0]['name']) }
        ],
        'xAxis' => { 'columnId' => "x-#{el_id}" },
        'yAxis' => { 'columnIds' => ["y-#{el_id}"] },
        'color' => { 'by' => 'category', 'column' => "c-#{el_id}" }
      }
      # PR-12: explicit .twb member→color assignments on the detail/color dim →
      # ordered scheme (same contract as the bar/line category-color path).
      # D2 (PR-13) fallback: a sibling zone's explicit map for the same field
      # pins the shared category→color dict here too.
      if SeriesColors.field_matches?(z['series_color_field'], dim['name']) &&
         (pinned = SeriesColors.ordered_scheme(z['series_colors']))
        element['color']['scheme'] = pinned
      elsif (pinned = SeriesColors.scheme_for_field(dash['zones'], dim['name']))
        element['color']['scheme'] = pinned
        warnings << "'#{cap}' scatter category colors pinned from a SIBLING chart's explicit .twb map " \
                    "for '#{dim['name']}' (per-category consistency)"
      end
      if size_field
        element['columns'] << { 'id' => "sz-#{el_id}", 'name' => size_field['name'],
                                'formula' => "[#{src_name}/#{size_field['name']}]",
                                'format' => num_fmt.call(size_field['name']) }
        element['size'] = { 'id' => "sz-#{el_id}" }
        warnings << "'#{cap}' scatter size shelf carries measure '#{size_field['name']}' — emitted size:{id} " \
                    'over a grouped calculation on the hidden source (one value per point)'
      end
      unless rows.any? { |r| r[0].nil? || r[0].to_s.strip.empty? }
        element['columns'] << { 'id' => "nn-c-#{el_id}", 'name' => "#{dim['name']} Not Null",
                                'formula' => "IsNotNull([#{src_name}/#{dim['name']}])" }
        element['filters'] = [{ 'id' => "flt-#{el_id}-nn", 'columnId' => "nn-c-#{el_id}",
                                'kind' => 'list', 'mode' => 'include',
                                'selectionMode' => 'multiple', 'values' => [true] }]
      end
      element['_worksheet'] = cap
      element['_dashboard'] = dash['dashboard']
      elements << element
      warnings << "'#{cap}' scatter pre-aggregated via hidden grouped source '#{src_name}' (x=#{x_pair[0]['name']}, y=#{y_pair[0]['name']}, detail=#{dim['name']}#{size_field ? ", size=#{size_field['name']}" : ''}) — raw refs on axes, color=detail (PBI ry0n design)"
      next
    end

    # Dual-axis / combo detection: if Tableau marked this worksheet as
    # synchronized-axes OR there are 2+ measures in the pane AND the view CSV
    # has a second measure column, emit a combo-chart with two yAxis groups.
    extra_meas_col = nil
    if z['dual_axis'] && headers.length >= 3
      meas2_hdr = headers[2]
      meas2 = map_column(meas2_hdr, mmap) ||
              { 'id' => "m-#{meas2_hdr.downcase.gsub(/\W+/,'-')}", 'name' => meas2_hdr }
      meas2_formula = meas2['formula'] || render_agg(sigma_agg, "[Master/#{meas2['name']}]")
      meas2_formula = MetricBinding.metric_ref_or_inline(meas2_formula, 'Master', opts[:metrics])
      extra_meas_col = {
        'id'      => "y2-#{el_id}",
        'name'    => meas2['name'],
        'formula' => meas2_formula,
        # PR-12: source formats first (pill format, then column default-format)
        'format'  => pick_tableau_format(z['formats'], meas2_hdr) ||
                     pick_column_default_format(meas2['name']) ||
                     (meas2['format'].is_a?(Hash) ? meas2['format'] :
                      { 'kind' => 'number', 'formatString' => ',.0f' })
      }
      kind = 'combo-chart' unless %w[pie-chart donut-chart].include?(kind)
      # Sigma combo-chart dual-axis IS persisted in the spec — the secondary
      # axis is implied by yAxis.columnIds entries in object form
      # (`{columnId, type}`) vs bare-string form. Bare strings go to the
      # primary (left) axis; object-form entries go to the secondary (right)
      # axis with the specified mark type. Verified 2026-05-22 against
      # UI-built workbook readback (workbookUrlId 5xKqmuAXGooHxRgFrdk6VY).
      # The right axis is auto-scaled by default; custom right-axis scale
      # configuration (log/min/max/zero) is unverified — yAxis.format only
      # governs the left axis.
      warnings << "'#{cap}' detected as dual-axis (synchronized=true or 2+ measures) — emitted as combo-chart with secondary measure on right axis (yAxis.columnIds object form). Right axis is auto-scaled; if Tableau had a custom right-axis range, configure manually in the Sigma editor."
    end

    element = {
      'id'      => el_id,
      'kind'    => kind,
      'name'    => tile_title(z, cap),
      'source'  => { 'kind' => 'table', 'elementId' => chart_source_eid },
      'columns' => [dim_col_obj, meas_col_obj]
    }
    element['columns'] << extra_meas_col if extra_meas_col

    # C2 THRESHOLD HALO (gap ubr5.11): a color channel driven by a threshold on
    # the measure ([m] <op> N) is not a CSV/master dim, so color_col_obj is nil
    # and the halo used to be DROPPED behind the single-series fan-out NOTE.
    # Synthesize the verified computed-boolean color column + a 2-color scheme
    # ordered [below, above] on category charts. Purely ADDITIVE: no threshold
    # color ⇒ threshold_halo_plan returns nil ⇒ identical output.
    threshold_halo_scheme = nil
    if color_col_obj.nil? && %w[bar-chart line-chart area-chart combo-chart].include?(kind)
      thp = threshold_halo_plan(z, meta)
      if thp && thp['mappable']
        thcol, why = threshold_halo_color_column(thp, el_id, meta, mmap)
        if thcol
          color_col_obj = thcol
          threshold_halo_scheme = [thp['below'], thp['above']]
          $threshold_halo_records << { 'element' => el_id, 'worksheet' => cap,
                                       'dashboard' => dash['dashboard'], 'kind' => kind, 'status' => 'emitted',
                                       'field' => thp['field'], 'formula' => thp['formula'], 'op' => thp['op'],
                                       'constant' => thp['constant'], 'scheme' => threshold_halo_scheme, 'basis' => thp['basis'] }
          warnings << "'#{cap}' THRESHOLD HALO: color is driven by a threshold on the measure " \
                      "(#{thp['formula'].to_s.gsub(/\s+/, ' ')}) — emitted computed-boolean color column " \
                      "'#{color_col_obj['name']}' + scheme #{threshold_halo_scheme.inspect} (below→above); the halo is " \
                      'APPROXIMATED (Sigma has no second marks-layer overlay) — verify the render'
        else
          $threshold_halo_records << { 'element' => el_id, 'worksheet' => cap, 'dashboard' => dash['dashboard'],
                                       'kind' => kind, 'status' => 'unmapped', 'field' => thp['field'],
                                       'formula' => thp['formula'], 'reason' => why }
          warnings << "'#{cap}' threshold-halo color NOT auto-emitted (#{why}) — STAYS-MANUAL: map the measure on " \
                      'the master, then re-run, or set the conditional color in the Sigma editor (routed to coverage)'
        end
      elsif thp && !thp['mappable']
        $threshold_halo_records << { 'element' => el_id, 'worksheet' => cap, 'dashboard' => dash['dashboard'],
                                     'kind' => kind, 'status' => 'unmapped', 'field' => thp['field'],
                                     'formula' => thp['formula'], 'reason' => thp['reason'] }
        warnings << "'#{cap}' threshold-halo color NOT auto-emitted (#{thp['reason']}) — STAYS-MANUAL: set the " \
                    'conditional color in the Sigma editor (routed to coverage; deferred per C2 tight scope)'
      end
    end

    if color_col_obj && !%w[pie-chart donut-chart table pivot-table].include?(kind)
      element['columns'] << color_col_obj
      element['color'] = { 'by' => 'category', 'column' => color_col_obj['id'] }
      # C2: a computed threshold boolean (false<true) binds scheme positionally
      # [below, above] deterministically — override any member-name pin.
      element['color']['scheme'] = threshold_halo_scheme if threshold_halo_scheme
      # PR-12: pin the .twb's explicit member→color assignments as an ORDERED
      # scheme (ascending member order = Sigma's positional category-sort
      # application) so the member→color BINDING survives — the Top/Bottom-500
      # inversion class. No explicit map ⇒ no scheme ⇒ theme palette applies
      # (current derivation unchanged). Skipped when C2 already pinned the
      # threshold scheme deterministically above.
      if threshold_halo_scheme
        # (scheme already set from the threshold plan)
      elsif SeriesColors.field_matches?(z['series_color_field'], color_col_obj['name']) &&
         (pinned = SeriesColors.ordered_scheme(z['series_colors']))
        element['color']['scheme'] = pinned
        members = z['series_colors'].map { |p| p['member'] }.sort_by { |m| m.to_s.downcase }
        warnings << "'#{cap}' series colors PINNED from the .twb member→color map " \
                    "(ascending member order: #{members.join(' → ')}) — scheme[i] binds to the i-th " \
                    'category in Sigma sort order'
      elsif (pinned = SeriesColors.scheme_for_field(dash['zones'], color_col_obj['name']))
        # D2 (PR-13): no explicit map on THIS worksheet, but a sibling zone on
        # the dashboard colors by the same field with explicit assignments —
        # pin the shared dict so a category keeps ONE color on every chart
        # (Tableau only serializes the map where the author touched the legend;
        # unpinned siblings fell to the positional theme palette and the same
        # region changed color chart-to-chart).
        element['color']['scheme'] = pinned
        warnings << "'#{cap}' category colors pinned from a SIBLING chart's explicit .twb map for " \
                    "'#{color_col_obj['name']}' (per-category consistency: same category, same color " \
                    'on every chart of the dashboard)'
      end
    elsif color_scale && %w[bar-chart line-chart area-chart combo-chart].include?(kind)
      # By-measure color ramp: add a DUPLICATE measure column (Sigma forbids a
      # column on both yAxis and color) and point color:{by:scale} at it.
      clr_id = "clr-#{el_id}"
      clr_col = { 'id' => clr_id, 'name' => "#{color_scale['name']} (color)",
                  'formula' => color_scale['formula'] }
      clr_col['format'] = meas_col_obj['format'] if color_scale['name'] == meas['name'] && meas_col_obj['format']
      element['columns'] << clr_col
      element['color'] = { 'by' => 'scale', 'column' => clr_id, 'scheme' => MEASURE_COLOR_SCHEME.dup }
      warnings << "'#{cap}' color shelf carries the measure '#{color_scale['name']}' (continuous) — emitted " \
                  "color:{by:scale} on a duplicate measure column with a sequential scheme; re-pick a diverging " \
                  'palette in the Sigma editor if Tableau used one'
    end

    # Null-dim exclusion (Tableau↔Sigma join-semantics parity): Sigma DM
    # relationships are LEFT joins, so fact rows without a dim match surface a
    # NULL dim bucket that the Tableau view excluded. When the Tableau CSV has
    # NO null dim values, mirror the exclusion with a verified bool-filter
    # (IsNotNull calc column + include:[true] list filter — the spec shape from
    # reference_sigma_rls_cls_spec_shape). A no-null dataset makes this a
    # harmless no-op.
    null_excl_filters = []
    # Charts only: a table/pivot RENDERS every column, so the helper column
    # would show up as a visible "X Not Null" column (and crosstabs keep their
    # null buckets in Tableau anyway).
    null_excl_kinds = %w[bar-chart line-chart area-chart combo-chart pie-chart donut-chart scatter-chart]
    [[dim_csv_idx, dim_col_obj], [color_csv_idx, color_col_obj]].each do |(ci, cobj)|
      next unless null_excl_kinds.include?(kind)
      next if ci.nil? || cobj.nil?
      next if rows.any? { |r| r[ci].nil? || r[ci].to_s.strip.empty? } # Tableau kept nulls
      nn_id = "nn-#{cobj['id']}"
      element['columns'] << { 'id' => nn_id, 'name' => "#{cobj['name']} Not Null",
                              'formula' => "IsNotNull(#{cobj['formula'] || "[Master/#{cobj['name']}]"})" }
      null_excl_filters << { 'columnId' => nn_id, 'kind' => 'list', 'mode' => 'include',
                             'selectionMode' => 'multiple', 'values' => [true] }
    end
    unless null_excl_filters.empty?
      warnings << "'#{cap}' null-dim exclusion: #{null_excl_filters.size} IsNotNull filter(s) emitted (Tableau view shows no null dim bucket; Sigma LEFT joins would)"
    end

    # Reference lines / bands / trendlines from Tableau → Sigma `refMarks`.
    # Verified shape (from a UI-built workbook readback, 2026-05-21):
    #   refMarks:
    #     - type: line | band
    #       axis: series | series2 | axis
    #       value:
    #         { type: constant, value: <number> }     # constant threshold
    #         { type: formula,  formula: "<expr>" }   # any Sigma formula
    #       label:
    #         { visibility: shown|hidden, text?: "..." }
    #
    # Docs (charts.md) suggested bare numbers / strings for `value` but the
    # live API only accepts the wrapped object form. `value.type: column` is
    # also rejected — use `formula` with a column ref instead.
    ref_emit, trend_emit, ref_skip = [], [], []
    if z['ref_marks'] && !z['ref_marks'].empty? && %w[bar-chart line-chart area-chart combo-chart scatter-chart].include?(kind)
      meas_name = meas_col_obj['name']
      tab_to_sigma_agg = { 'average' => 'Avg', 'median' => 'Median', 'max' => 'Max', 'min' => 'Min', 'sum' => 'Sum', 'count' => 'Count' }
      # Trendline shape verified 2026-05-22 against a UI-built workbook
      # (workbookUrlId 5xKqmuAXGooHxRgFrdk6VY). Only `linear` is canonically
      # verified; other Tableau model-types are passed through under the same
      # name (Sigma docs list logarithmic/exponential/polynomial/quadratic/power)
      # and will surface a per-element WARN to verify visually.
      tab_to_sigma_model = {
        'linear'      => 'linear',
        'logarithmic' => 'logarithmic',
        'exponential' => 'exponential',
        'polynomial'  => 'polynomial',
        'power'       => 'power'
      }
      z['ref_marks'].each do |rm|
        case rm['kind']
        when 'line'
          # Skip band-styled lines (fill/percentage bands) — they need the band shape, not line.
          if rm['band_values'] || rm['fill_below'] == 'true' || rm['fill_above'] == 'true' || rm['percentage_bands'] == 'true'
            ref_skip << rm
            next
          end
          fagg = tab_to_sigma_agg[rm['formula']]
          if fagg
            label_text = rm['label_type'] == 'custom' ? rm['label'] : "#{fagg} #{meas_name}"
            # Mark-level vs row-level (bead: refmark-avg / finding #3). Tableau's
            # reference line aggregates over the plotted MARKS (the per-bin
            # aggregates), but Sigma evaluates a refMark formula over the raw
            # ROWS — so `Avg([meas])` yields the row mean (e.g. $163/order), not
            # the mean of the bars (e.g. mean of monthly sums ≈ $3,500). For an
            # AVERAGE line the mark-level mean = Sum(meas) / <count of x-axis
            # bins>; the bins are the chart's x grouping (dim_col_obj's formula:
            # `[Master/Region]` or `DateTrunc("month", [Master/Order Date])`).
            dim_grp = dim_col_obj && dim_col_obj['formula'].to_s
            value_formula =
              if fagg == 'Avg' && dim_grp && !dim_grp.strip.empty?
                "Sum([Master/#{meas_name}]) / CountDistinct(#{dim_grp})"
              else
                "#{fagg}([Master/#{meas_name}])"
              end
            if fagg == 'Avg' && !(dim_grp && !dim_grp.strip.empty?)
              warnings << "'#{cap}' average reference line fell back to ROW-LEVEL (couldn't resolve the x-axis grouping for a mark-level mean) — verify the line value vs Tableau at Phase 6f"
            elsif %w[Min Max Median].include?(fagg)
              warnings << "'#{cap}' #{fagg} reference line emitted ROW-LEVEL; Tableau computes it over the plotted marks — verify vs Tableau at Phase 6f (mark-level Min/Max/Median needs a windowed formula)"
            end
            ref_emit << {
              'type'  => 'line',
              'axis'  => 'series',
              'value' => { 'type' => 'formula', 'formula' => value_formula },
              'label' => { 'visibility' => 'shown', 'text' => label_text }.compact
            }
          else
            ref_skip << rm
          end
        when 'trendline'
          model = tab_to_sigma_model[rm['model'].to_s] || 'linear'
          trend_emit << {
            'columnId' => meas_col_obj['id'],
            'model'    => model,
            'label'    => { 'visibility' => 'shown' },
            'value'    => { 'visibility' => 'shown' }
          }
        when 'band', 'distribution'
          # Bands need the {type:band} variant which we haven't verified.
          ref_skip << rm
        end
      end
      element['refMarks']   = ref_emit   unless ref_emit.empty?
      element['trendlines'] = trend_emit unless trend_emit.empty?
      if !ref_skip.empty?
        skip_counts = ref_skip.each_with_object(Hash.new(0)) { |r, h| h[r['kind']] += 1 }
        skip_kinds = skip_counts.map { |k, n| "#{n}× #{k}" }.join(', ')
        warnings << "'#{cap}' has #{ref_skip.size} Tableau reference mark(s) not auto-emitted (#{skip_kinds}) — bands/distributions need manual review (beads-sigma-7ak)"
      end
      if !ref_emit.empty?
        warnings << "'#{cap}' auto-emitted #{ref_emit.size} Sigma refMarks from Tableau reference marks — verify visual fidelity"
      end
      if !trend_emit.empty?
        models_used = trend_emit.map { |t| t['model'] }.uniq
        non_linear = models_used - ['linear']
        msg = "'#{cap}' auto-emitted #{trend_emit.size} Sigma trendline(s) (model: #{models_used.join(', ')})"
        msg += " — only `linear` is canonically verified; visually verify #{non_linear.join('/')} fits" unless non_linear.empty?
        warnings << msg
      end
    end

    if kind == 'table'
      # Tableau text-table → Sigma grouped ("level") table. WITHOUT `groupings`,
      # a table with dim + Sum(...) columns renders one row per SOURCE row (no
      # roll-up). And on a grouped table the sort MUST nest inside the grouping
      # entry — element-level sort 400s with "Sort column not found" (verified
      # shape, see qlik-to-sigma refs/sigma-build-gotchas.md; bead f972).
      grouping = {
        'id'           => "g-#{el_id}",
        'groupBy'      => [dim_col_obj['id']],
        'calculations' => [meas_col_obj['id']]
      }
      if z['sort']
        dir = z.dig('sort', 'direction').to_s
        grouping['sort'] = [{
          'columnId'  => sort_target_column_id(z['sort'], dim, dim_hdr, dim_col_obj['id'], meas_col_obj['id']),
          'direction' => (dir =~ /desc/i) ? 'descending' : 'ascending'
        }]
        warnings << "'#{cap}' Tableau sort carried into groupings[0].sort (grouped-table sorts must nest inside the grouping — element-level sort 400s)"
      end
      element['groupings'] = [grouping]
    elsif kind == 'pie-chart' || kind == 'donut-chart'
      element['color'] = { 'id' => dim_col_obj['id'] }
      element['value'] = { 'id' => meas_col_obj['id'] }
      # PR-12: per-element color.scheme is SILENTLY DROPPED on pie/donut — the
      # only slice-color path is themeOverrides.categoricalScheme, applied
      # positionally in category-sort order. ThemeDerive orders the theme from
      # this zone's explicit member→color map (SeriesColors
      # .explicit_scheme_for_dashboard); surface the contract for the RCF pass.
      if z['series_colors'].is_a?(Array) && z['series_colors'].size >= 2
        warnings << "'#{cap}' pie/donut slice colors ride themeOverrides.categoricalScheme (per-element " \
                    'color.scheme is dropped on pie/donut) — theme scheme is ordered ascending by the ' \
                    ".twb member→color map; verify slice-color alignment in the render"
      end
      if z['sort']
        dir = z.dig('sort', 'direction').to_s
        element['color']['sort'] = {
          'by'        => sort_target_column_id(z['sort'], dim, dim_hdr, dim_col_obj['id'], meas_col_obj['id']),
          'direction' => (dir =~ /desc/i) ? 'descending' : 'ascending'
        }
        warnings << "'#{cap}' Tableau sort carried into pie color.sort"
      end
    else
      # Breaking-change-2026-05-21: xAxis takes singular `columnId` (string),
      # yAxis takes plural `columnIds` (array on the object — NOT array of
      # objects). The old `xAxis: {id: ...}` / `yAxis: [{id: ...}]` shape
      # is rejected by the live API on new POSTs.
      x_axis = { 'columnId' => dim_col_obj['id'] }
      # Sort: only set when Tableau explicitly sorted. parse-twb-layout emits
      # nil when there's no <sort> on the worksheet — leave Sigma's xAxis
      # unsorted in that case (natural order matches Tableau's default).
      if z['sort']
        dir = z.dig('sort', 'direction').to_s
        sigma_dir = (dir =~ /desc/i) ? 'descending' : 'ascending'
        sort_by = nil
        # <computed-sort using='[sum:GUID:qk]'> = "sort the dim BY measure Y".
        # Resolve Y; when it isn't the plotted measure, carry it as a HIDDEN
        # companion aggregate so xAxis.sort can target it. This is load-bearing
        # for window calcs: Sigma Cumulative*/Rank follow the xAxis sort, so a
        # pareto chart sorted by revenue desc must accumulate in that order
        # (sorting by the cumulative measure itself would be circular).
        if z['sort']['using']
          u = z['sort']['using'].to_s
          ug = guid_from_text(u)
          ucap = ug && (meta['columns_by_guid'] || {})[ug]&.dig('caption')
          ucap ||= u.sub(/^\[[^\]]+\]\./, '').gsub(/^\[|\]$/, '')
                    .sub(/^[a-z]+:/i, '').sub(/:[a-z]+$/i, '').strip
          um = ucap && ucap !~ /\A[0-9a-f\-]{36}\z/i ? map_column(ucap, mmap) : nil
          if um && um['name'].casecmp?(meas['name'])
            sort_by = meas_col_obj['id']
          elsif um && chart_source_eid == opts[:master_id]
            uagg = SHELF_AGG_FOR_PREFIX[(u[/\[([a-z]+):/i, 1] || 'sum').downcase] || 'Sum'
            comp_id = "srt-#{el_id}"
            element['columns'] << { 'id' => comp_id, 'name' => um['name'],
                                    'formula' => um['formula'] || render_agg(uagg, "[Master/#{um['name']}]") }
            sort_by = comp_id
            warnings << "'#{cap}' Tableau computed-sort (by #{um['name']} #{sigma_dir}) carried into xAxis.sort " \
                        'via a hidden companion aggregate — cumulative/rank window formulas follow this order'
          elsif window_plan
            warnings << "'#{cap}' computed-sort measure '#{ucap}' could not be carried (unmapped or helper-sourced " \
                        'chart) — VERIFY the accumulation order of the windowed measure against Tableau'
          end
        end
        sort_by ||= sort_target_column_id(z['sort'], dim, dim_hdr, dim_col_obj['id'], meas_col_obj['id'])
        x_axis['sort'] = { 'by' => sort_by, 'direction' => sigma_dir }
      end
      # Top-N measure-on-yAxis safety (bead pnxp): when the plotted measure is a
      # RANK_UNIQUE/RANK(<clean agg>)<=N idiom, translate_window_calc emits the
      # inline RowNumber()<=N form and RECORDS the ranked measure. RowNumber()
      # follows the viz sort, so without sorting by that measure the "top N"
      # cutoff is wrong. If Tableau carried no explicit sort, auto-wire xAxis.sort
      # by a hidden companion of the ranked measure (descending = top).
      if window_plan && window_plan['mode'] == 'inline' && window_plan['ranked_measure'] &&
         !z['sort'] && x_axis['sort'].nil? && chart_source_eid == opts[:master_id]
        rm_id = "topn-sort-#{el_id}"
        unless (element['columns'] || []).any? { |c| c['id'] == rm_id }
          element['columns'] << { 'id' => rm_id, 'name' => "#{header_base(meas_hdr)} (rank measure)",
                                  'formula' => window_plan['ranked_measure'] }
        end
        x_axis['sort'] = { 'by' => rm_id, 'direction' => 'descending' }
        warnings << "'#{cap}' top-N measure (RowNumber()<=N) auto-sorted by its ranked measure " \
                    "#{window_plan['ranked_measure'][0..70]} desc (RowNumber follows the viz sort — else the cutoff is wrong)"
      end
      element['xAxis'] = x_axis
      # Combo-chart: yAxis.columnIds is a mixed array — bare strings default to
      # bar; { columnId, type: 'line' } objects override the series type.
      # For non-combo: just bare strings.
      y_column_ids = [meas_col_obj['id']]
      if extra_meas_col
        y_column_ids << (kind == 'combo-chart' ?
          { 'columnId' => extra_meas_col['id'], 'type' => 'line' } :
          extra_meas_col['id'])
      end
      # v5.4 KPI-adjacent SPARKLINE overlays: a trend tile whose measure shelf
      # is a multi-instance EXPRESSION ("SUM(base) + SUM(conditional
      # highlight)") plots the FULL date series with a highlighted current
      # period. The single-field pick takes only ONE instance (the parser's
      # expression-field guid is the LAST token — typically the conditional
      # highlight), so the tile shipped the current period alone. Emit one y
      # column per ADDITIONAL instance that resolves; an instance that doesn't
      # translate is a NAMED note — the full trend must never silently reduce
      # to a point.
      if %w[line-chart area-chart].include?(kind) && chart_source_eid == opts[:master_id]
        m_raw = [z.dig('rows_shelf', 'raw'), z.dig('cols_shelf', 'raw')].compact
                .map(&:to_s).find { |r| r.include?('+') && r =~ /:qk/ }.to_s
        toks = m_raw.scan(/\[([a-z]+):([^:\[\]]+):qk(?::\d+)?\]/i)
        if toks.size > 1
          nrm_sp = ->(x) { x.to_s.downcase.gsub(/[^a-z0-9]/, '') }
          existing_f = (element['columns'] || []).map { |c| c['formula'].to_s.gsub(/\s+/, '') }
          toks.each_with_index do |(deriv2, g2), ti|
            info2 = (meta['columns_by_guid'] || {})[g2] || {}
            cap2 = info2['caption'].to_s.strip
            cap2 = g2 if cap2.empty?
            # skip the instance the standard pick already bound
            next if nrm_sp.call(cap2) == nrm_sp.call(meas['name']) || nrm_sp.call(cap2) == nrm_sp.call(meas_hdr)
            f2 =
              if (mc2 = map_column(cap2, mmap) || scope_map_column(cap2, mmap))
                render_agg(SHELF_AGG_FOR_PREFIX[deriv2.to_s.downcase] || 'Sum', "[Master/#{mc2['name']}]")
              elsif info2['formula'].to_s.strip != ''
                translate_user_agg_formula(info2['formula'], mmap, meta['columns_by_guid'] || {}) ||
                  (rl = translate_row_level_calc(info2['formula'], mmap, meta['columns_by_guid'] || {})) &&
                  "Sum((#{rl}))"
              end
            if f2.nil? || f2 == false
              warnings << "'#{cap}' trend overlay instance '#{cap2}' did not translate — the series ships " \
                          'without this overlay (typically a parameter-bound period highlight); re-author it ' \
                          'as a conditional measure if needed'
              next
            end
            next if existing_f.include?(f2.gsub(/\s+/, ''))
            oc = { 'id' => "y#{ti + 2}-#{el_id}", 'name' => cap2, 'formula' => f2 }
            oc['format'] = meas_col_obj['format'] if meas_col_obj['format']
            element['columns'] << oc
            existing_f << f2.gsub(/\s+/, '')
            y_column_ids << oc['id']
            warnings << "'#{cap}' multi-instance trend shelf: emitted overlay series '#{cap2}' (#{f2[0, 80]}) — " \
                        'the tile plots the full series, not just the highlighted period'
          end
        end
      end
      element['yAxis'] = { 'columnIds' => y_column_ids }

      # Bar orientation (bead: bar-orientation). Tableau puts the DIMENSION on
      # the Rows shelf and the MEASURE on Columns for a HORIZONTAL bar (bars grow
      # left→right, categories down the y-axis); the default vertical bar is the
      # opposite. parse-twb-layout already tags each shelf field's `role`, so read
      # it straight off the zone. Sigma spec: `orientation: "horizontal"` on a
      # bar-chart (omit for vertical — "vertical" is REJECTED). Round-trips live
      # (refs/workbook-layout.md, verified 2026-06-15).
      if kind == 'bar-chart'
        pr_orient = PNG_ORIENTATION[z['caption'].to_s.downcase.strip]
        if pr_orient
          # Operator-confirmed (Phase 1d) wins. Sigma REJECTS orientation:
          # "vertical" — vertical is expressed by omitting the field.
          element['orientation'] = 'horizontal' if pr_orient == 'horizontal'
        else
          # rows_shelf/cols_shelf are a Hash ({fields:[…]}) in the rich parse,
          # but sometimes just the raw shelf STRING — only the Hash carries roles.
          rows_sh = z['rows_shelf']
          cols_sh = z['cols_shelf']
          rows_f = rows_sh.is_a?(Hash) ? (rows_sh['fields'] || []) : []
          cols_f = cols_sh.is_a?(Hash) ? (cols_sh['fields'] || []) : []
          dim_on_rows  = rows_f.any? { |f| %w[dim dimension].include?(f['role']) }
          meas_on_cols = cols_f.any? { |f| f['role'] == 'measure' }
          if dim_on_rows && meas_on_cols
            element['orientation'] = 'horizontal'
          end
        end
      end

      # Axis format (log scale, fixed min/max). parse-twb-layout extracts these
      # from Tableau's <style-rule element='axis'><encoding attr='space' ...>
      # nodes per worksheet. Sigma side shape verified 2026-05-22:
      #   format: { scale: { type: log | linear, domain: {min, max}, zero } }
      # Tableau→Sigma scope mapping: rows→yAxis, cols→xAxis. class='0' is
      # primary, class='1' is secondary (dual-axis right side, currently
      # unverified from Sigma side — emit primary only for now).
      (z['axis_formats'] || []).each do |af|
        next unless af['class'].to_s == '0'  # primary only
        target = af['scope'] == 'rows' ? 'yAxis' : 'xAxis'
        scale = {}
        scale['type']   = 'log' if af['scale'] == 'log'
        if af['range_type'] == 'fixed' && af['min'] && af['max']
          scale['domain'] = { 'min' => af['min'], 'max' => af['max'] }
        end
        next if scale.empty?
        element[target] ||= {}
        element[target]['format'] ||= {}
        element[target]['format']['scale'] = scale
        warnings << "'#{cap}' auto-emitted #{target}.format.scale from Tableau axis override (scale=#{af['scale']}, range=#{af['range_type']}) — verify visual fidelity"
      end
    end

    # Surface action filters (they get skipped — these are cross-chart actions,
    # not value filters)
    action_filters = (z['filters'] || []).select { |f|
      f['column'].to_s.include?('[Action (') || f['column'].to_s.start_with?('[Action ')
    }
    if action_filters.any?
      warnings << "'#{cap}' has #{action_filters.size} Tableau action filter(s) — skipped (cross-chart actions, not value filters)"
    end

    # If channels.color is set, that's a multi-series signal. Emit a TODO note
    # so the agent can fan-out the yAxis with one If() per category. We don't
    # auto-fan because we don't have a reliable categorical-values list here.
    if z.dig('channels', 'color', 'column') && color_col_obj.nil? && color_scale.nil? && kind != 'pie-chart'
      warnings << "'#{cap}' has a color channel on #{z['channels']['color']['column']} — chart is single-series; agent should fan-out yAxis with one If() per category (see refs/workbook-layout.md \"Multi-series chart patterns\")"
    end

    # Data labels — verified canonical shape 2026-05-22 against UI-built workbook
    # (workbookUrlId 5xKqmuAXGooHxRgFrdk6VY): minimum required is just
    #   dataLabel: { labels: shown }
    # Two Tableau signals trigger this:
    #   1. Label or Text encoding channel on the worksheet (drag-to-shelf)
    #   2. Worksheet-level "Show Mark Labels" toggle, surfaced by parse-twb-layout
    #      from <pane><style><style-rule element='mark'>
    #             <format attr='mark-labels-show' value='true'/>
    #      (verified against "Orders Conversion Test" workbook, 2026-05-22)
    if %w[bar-chart line-chart area-chart combo-chart scatter-chart pie-chart donut-chart].include?(kind)
      has_label_channel = z.dig('channels', 'label', 'column') || z.dig('channels', 'text', 'column')
      has_mark_labels   = z['mark_labels_show'] == true
      if has_label_channel || has_mark_labels
        element['dataLabel'] = { 'labels' => 'shown' }
        src = has_label_channel ? 'Label/Text encoding' : 'worksheet "Show Mark Labels" toggle'
        warnings << "'#{cap}' auto-emitted dataLabel:{labels:shown} from Tableau #{src} — verify formatting (Sigma defaults are minimal)"
      end
    end

    # Per-chart value filters (skip action filters — already warned above).
    # Translate each non-action filter into a Sigma element-level filter spec
    # using the parser's normalized fields (column_caption, kind, members,
    # period_type, etc.). We map the caption → master column via the same
    # regex map used for dim/measure.
    value_filters = (z['filters'] || []).reject { |f| f['is_action'] }
    # D2/P0.2: append datasource-level + extract filters — Tableau applies them
    # to every sheet on that datasource. Scope by the zone's shelf refs when
    # the workbook is multi-datasource (`[federated.X]` tokens); a zone with no
    # federated refs (single-DS shapes) gets them all. Skip a ds filter the
    # worksheet already carries on the same column/kind (AND-composing an
    # identical copy adds noise, not data).
    ds_value_filters.each do |df|
      dsn = df['datasource_name'].to_s
      next unless dsn.empty? || _zds.nil? || _zshelves.include?("[#{dsn}]")
      next if value_filters.any? do |f|
        f['kind'] == df['kind'] && f['column_caption'] == df['column_caption']
      end
      value_filters << df
    end
    el_filters = null_excl_filters
    # Element filters must reference a column ON THE TARGET ELEMENT (bead 320u)
    # — the master-namespace ids ("m-region") don't exist on the chart and the
    # POST rejects them. Reuse the chart's own column when the filter targets
    # the plotted dim/measure; otherwise add a hidden passthrough column.
    el_filter_col_for = lambda do |m|
      hit = (element['columns'] || []).find { |c| c['name'].to_s.strip.casecmp?(m['name'].to_s.strip) }
      return hit['id'] if hit
      # A helper-sourced chart (FIXED LOD / dim-grain) cannot reach master
      # columns the helper does not carry — surface it instead of emitting a
      # ref that error-types at POST.
      if chart_source_eid != opts[:master_id]
        warnings << "value filter on '#{cap}' targets '#{m['name']}' but the chart sources a two-stage helper that " \
                    'does not carry that column — filter NOT emitted; add the column to the helper manually if needed'
        return nil
      end
      fid = "f-#{el_id}-#{m['name'].to_s.downcase.gsub(/\W+/, '-')}"
      unless (element['columns'] || []).any? { |c| c['id'] == fid }
        element['columns'] << { 'id' => fid, 'name' => m['name'],
                                'formula' => m['formula'] || "[Master/#{m['name']}]" }
      end
      fid
    end
    # Top-N filter idiom (bead pnxp): a Tableau filter whose target is a BOOLEAN
    # calc `RANK(<expr>)<=N` / `RANK_UNIQUE(<expr>)<=N` kept on `true`. Tableau
    # exports hide this (it just thins the rows) and map_column can't resolve the
    # calc to a warehouse column, so it used to be silently dropped. Resolve the
    # filter to its calc formula and, when the ranked operand translates cleanly,
    # emit a NATIVE Sigma `kind:top-n` element filter keyed on that measure
    # (rowCount=N, rankingFunction row-number/rank) + sort the tile by it. An
    # untranslatable LOD operand is surfaced (build the helper measure first),
    # never emitted as a sort-dependent RowNumber.
    # Dispatch body extracted to a lambda (`next` still short-circuits one
    # filter) so the driver loop below can attribute datasource-filter
    # applications (D2/P0.2) without duplicating any arm.
    emit_value_filter = lambda do |f|
      fcap = f['column_caption'] || f['raw_param']
      # --- Top-N idiom interception (before master-column resolution) ---------
      # (detection + prefilter emission shared with the pivot fast path via
      # detect_topn_plan / apply_topn_prefilter! — v5.1.1)
      if (tp = detect_topn_plan(f, z, mmap, meta))
        label = tp['calc_caption']
        unless tp['keeps_true']
          warnings << "'#{cap}' top-N filter '#{label}' keeps FALSE (anti-top-N) — not auto-emitted; re-create by hand"
          next
        end
        # v5.1: PIVOTS require the PRE-FILTERED SOURCE TABLE — element-level
        # filters silently do NOT prune a pivot's dimension (round-4
        # bisect-proven), and RANK(<window share>) operands (topn-prefilter
        # mode) can't key an element filter at all. Members come from
        # <tab>/topn-members.json (one probe run) or the zone's rendered CSV
        # (Tableau already applied the rank — distinct entity values ARE the
        # exact member set); else emit the probe SQL and stay manual.
        if tp['top_n'] && (kind == 'pivot-table' || tp['mode'] == 'topn-prefilter')
          apply_topn_prefilter!(tp, element: element, cap: cap, z: z, meta: meta,
                                opts: opts, warnings: warnings, data_elements: data_elements,
                                own_view_id: view_by_name[cap] && view_by_name[cap]['id'])
          next
        end
        unless tp['top_n'] && tp['ranked_measure']
          # LOD operand or non-fixed-count op (>=/>): surface the actionable note.
          warnings << "'#{cap}' top-N filter '#{label}': #{tp['note']}"
          next
        end
        # Find or add the ranked-measure column on the element.
        rm = tp['ranked_measure']
        norm_f = ->(x) { x.to_s.gsub(/\s+/, '').downcase }
        ranked_col = (element['columns'] || []).find { |c| norm_f.call(c['formula']) == norm_f.call(rm) }
        if ranked_col.nil?
          rc_id = "topn-#{el_id}"
          ranked_col = { 'id' => rc_id, 'name' => header_base(label.to_s).strip.empty? ? 'Top-N Rank Measure' : label.to_s.sub(/\s*<=?\s*\d+\s*$/, '').strip,
                         'formula' => rm }
          element['columns'] << ranked_col
        end
        el_filters << {
          'columnId' => ranked_col['id'], 'kind' => 'top-n',
          'rankingFunction' => tp['ranking'], 'mode' => 'top-n',
          'rowCount' => tp['top_n'], 'includeNulls' => 'never'
        }
        # Make the visible order match the ranking (cosmetic but expected). Only
        # set when the tile has no explicit Tableau sort already.
        unless z['sort']
          if element['xAxis'].is_a?(Hash) && element['xAxis']['sort'].nil?
            element['xAxis']['sort'] = { 'by' => ranked_col['id'], 'direction' => 'descending' }
          elsif kind == 'table' && element.dig('groupings', 0) && element['groupings'][0]['sort'].nil?
            element['groupings'][0]['sort'] = [{ 'columnId' => ranked_col['id'], 'direction' => 'descending' }]
          end
        end
        warnings << "'#{cap}' top-N filter '#{label}' → native Sigma top-#{tp['top_n']} filter " \
                    "(rankingFunction:#{tp['ranking']}) ranked by #{rm[0..80]}#{ranked_col['id'] == "topn-#{el_id}" ? ' (hidden companion measure added)' : ''}"
        next
      end
      # --- Native TOP-N quick filter (D6/P0.5): the Top tab's groupfilter
      # `end/count/direction/order` tree, parsed by normalize_filter into
      # f['topn']. Literal N → the SAME native emission as the RANK-calc path
      # (kind:top-n element filter keyed on a hidden ranked-measure column;
      # rowCount is a literal — Sigma rejects control-parametrized rowCount).
      # Parameter-driven N → the RANK-helper + number-control idiom (Rank()
      # companion + keep-if formula referencing the param's number control).
      if (tn = f['topn'])
        tn_label = fcap || 'top-N quick filter'
        n_desc = tn['n'] || tn['count_param'] || '?'
        if kind == 'pivot-table'
          warnings << "'#{cap}' native Tableau top-N quick filter on '#{tn_label}' targets a PIVOT — " \
                      'element filters do not prune a pivot dimension; STAYS-MANUAL: build the ' \
                      "rank-limited pre-filtered source (refs/fidelity-recipes.md §Ranked pivot). N=#{n_desc}, " \
                      "ranked by: #{tn['order_expr'].to_s[0..100]}"
          next
        end
        if tn['units'].to_s =~ /percent/i
          warnings << "'#{cap}' native top-N quick filter on '#{tn_label}' STAYS-MANUAL — PERCENT-based " \
                      "(#{tn['end']} #{n_desc}%); Sigma's top-n filter takes a row count, not a percentile"
          next
        end
        ranked = tn['order_expr'] ? translate_user_agg_formula(tn['order_expr'], mmap, meta['columns_by_guid'] || {}) : nil
        if ranked.nil?
          warnings << "'#{cap}' native top-N quick filter on '#{tn_label}' STAYS-MANUAL — order expression " \
                      "did not translate: #{tn['order_expr'] || '(no order expression in the .twb)'}"
          next
        end
        # end='top' takes the first N of the given ordering; end='bottom' the
        # last N. DESC+top / ASC+bottom keep the HIGHEST values.
        asc = tn['direction'].to_s.upcase == 'ASC'
        keep_high = tn['end'] == 'bottom' ? asc : !asc
        norm_f = ->(x) { x.to_s.gsub(/\s+/, '').downcase }
        if tn['n'] # ---- literal N → native Sigma top-n element filter --------
          # Sigma's top-n filter keeps the HIGHEST-ranked rows; a bottom-N
          # keeps the lowest — rank by the sign-inverted measure instead.
          rank_formula = keep_high ? ranked : "-(#{ranked})"
          ranked_col = (element['columns'] || []).find { |c| norm_f.call(c['formula']) == norm_f.call(rank_formula) }
          if ranked_col.nil?
            ranked_col = { 'id' => "topnq-#{el_id}", 'name' => 'Top-N Rank Measure', 'formula' => rank_formula }
            element['columns'] << ranked_col
          end
          el_filters << {
            'columnId' => ranked_col['id'], 'kind' => 'top-n',
            'rankingFunction' => 'rank', 'mode' => 'top-n',
            'rowCount' => tn['n'], 'includeNulls' => 'never'
          }
          unless z['sort']
            if element['xAxis'].is_a?(Hash) && element['xAxis']['sort'].nil?
              element['xAxis']['sort'] = { 'by' => ranked_col['id'], 'direction' => 'descending' }
            elsif kind == 'table' && element.dig('groupings', 0) && element['groupings'][0]['sort'].nil?
              element['groupings'][0]['sort'] = [{ 'columnId' => ranked_col['id'], 'direction' => 'descending' }]
            end
          end
          warnings << "'#{cap}' native Tableau #{keep_high ? 'top' : 'bottom'}-#{tn['n']} quick filter on " \
                      "'#{tn_label}' → Sigma top-n element filter (rowCount:#{tn['n']}, ranked by " \
                      "#{tn['order_expr'].to_s[0..80]}#{keep_high ? '' : ', sign-inverted for bottom-N'})"
          next
        end
        # ---- parameter-driven N → RANK helper + number control ---------------
        token = tn['count_param'].to_s[/\[Parameters?[^\]]*\]\s*\.\s*\[([^\]]+)\]/, 1] ||
                tn['count_param'].to_s.gsub(/^\[|\]$/, '')
        pdef = (meta['parameters'] || []).find do |p|
          p['caption'].to_s == token || p['name'].to_s.gsub(/^\[|\]$/, '') == token
        end
        pcap = pdef && pdef['caption'].to_s.strip
        if pcap.nil? || pcap.empty?
          warnings << "'#{cap}' native top-N quick filter on '#{tn_label}' STAYS-MANUAL — parameter-driven " \
                      "count (#{tn['count_param']}) but no matching workbook parameter was found"
          next
        end
        ctl = "ctl-param-#{pcap.downcase.gsub(/\W+/, '-').sub(/-$/, '')}"
        rank_id = "topnq-rank-#{el_id}"
        rank_name = "Top-N Rank (#{tn_label})"
        keep_id = "topnq-keep-#{el_id}"
        unless (element['columns'] || []).any? { |c| c['id'] == rank_id }
          element['columns'] << { 'id' => rank_id, 'name' => rank_name,
                                  'formula' => "Rank(#{ranked}, \"#{keep_high ? 'desc' : 'asc'}\")" }
          # Text (not boolean) keep flag: live probes reject non-string list
          # filter values (Text() casting rule, sigma ground truth §E.10).
          element['columns'] << { 'id' => keep_id, 'name' => "Top-N Keep (#{tn_label})",
                                  'formula' => "If([#{rank_name}] <= [#{ctl}], \"keep\", \"cut\")" }
        end
        el_filters << {
          'columnId' => keep_id, 'kind' => 'list', 'mode' => 'include',
          'selectionMode' => 'multiple', 'values' => ['keep'], 'includeNulls' => 'never'
        }
        warnings << "'#{cap}' parameter-driven #{keep_high ? 'top' : 'bottom'}-N quick filter on '#{tn_label}' " \
                    "→ Rank() helper + keep-filter wired to number control [#{ctl}] (param '#{pcap}', " \
                    "default N=#{pdef['default_value']}) ranked by #{tn['order_expr'].to_s[0..80]}"
        next
      end
      # --- WILDCARD quick filter (D5/P0.6): parsed pattern → a hidden string
      # match column + keep-filter (worksheet-scoped filters have no card to
      # bind, so the match is applied as an element filter). Unparseable
      # pattern → loud STAYS-MANUAL, never a silent "All".
      if f['kind'] == 'wildcard' && f['wildcard'].nil?
        warnings << "'#{cap}' WILDCARD quick filter on '#{fcap}' STAYS-MANUAL — pattern expression did not " \
                    "parse (#{f['wildcard_unparsed'].to_s[0..120]}); NOT treated as 'All', no filter emitted"
        next
      end
      m = fcap ? map_column(fcap, mmap) : nil
      if m.nil?
        warnings << "value filter on '#{cap}' targets '#{fcap}' — no master column matched, skipping"
        next
      end
      case f['kind']
      when 'list'
        # A Tableau categorical filter with NO members = "All" (the member list
        # is only materialized for explicit selections). An empty Sigma
        # include-list would filter out EVERY row — skip it (bead 320u).
        if (f['members'] || []).empty?
          warnings << if f['exclude']
                        "'#{cap}' EXCLUDE quick filter on '#{fcap}' carries no explicit members — nothing to exclude; no Sigma element filter emitted"
                      else
                        "'#{cap}' quick filter on '#{fcap}' has no explicit members (Tableau 'All') — no Sigma element filter emitted"
                      end
          next
        end
        fcol = el_filter_col_for.call(m)
        next if fcol.nil? # helper-sourced chart, column unreachable (warned in el_filter_col_for)
        # D1/P0.1: an EXCLUDE-mode Tableau filter enumerates the values it
        # HIDES — emit mode:'exclude' (Sigma list filters support it) instead
        # of inverting the filter into an include list of the excluded members.
        el_filters << {
          'columnId' => fcol,
          'kind' => 'list', 'mode' => (f['exclude'] ? 'exclude' : 'include'),
          'selectionMode' => 'multiple',
          'values' => f['members'], 'includeNulls' => 'never'
        }
        if f['exclude']
          warnings << "'#{cap}' EXCLUDE quick filter on '#{fcap}' → Sigma list filter mode:exclude " \
                      "(#{f['members'].size} hidden value(s): #{f['members'].join(', ')[0..80]})"
        end
      when 'relative-date'
        # Tableau relative-date filters → ROLLING Sigma date-range filters:
        #   "this <period>" (first=last=0)      → mode:current unit:<unit>
        #   "last N <period>" (e.g. first=-5,0) → mode:last  value:N unit includeToday
        #   "next N <period>"                   → mode:next  value:N unit includeToday
        # Only genuinely shifted/spanning windows (which no rolling mode fits)
        # fall back to frozen mode:between bounds. This replaces the old code
        # that froze EVERY offset window to static dates (broke at rollover and
        # rendered empty when the frozen range missed the data — Wendy's dash).
        period   = (f['period_type'] || 'year').downcase
        inc_null = (f['include_null'].to_s == 'true' ? 'always' : 'never')
        fcol = el_filter_col_for.call(m)
        next if fcol.nil? # helper-sourced chart, column unreachable (warned in el_filter_col_for)
        fields, kind = relative_date_filter_fields(period, f['first_period'], f['last_period'])
        if fields.nil?
          warnings << "'#{cap}' relative-date on '#{fcap}' (period=#{period}, window #{f['first_period']}..#{f['last_period']}) — no Sigma date-range mode fits; filter DROPPED, wire it by hand"
          next
        end
        el_filters << { 'columnId' => fcol, 'kind' => 'date-range', 'includeNulls' => inc_null }.merge(fields)
        case kind
        when :current
          warnings << "'#{cap}' relative-date 'this #{period}' → element filter mode:current unit:#{fields['unit']} (rolls automatically; bead z135)"
        when :last
          warnings << "'#{cap}' relative-date → element filter mode:last value:#{fields['value']} unit:#{fields['unit']} includeToday:#{fields['includeToday']} (ROLLS — no frozen dates)"
        when :next
          warnings << "'#{cap}' relative-date → element filter mode:next value:#{fields['value']} unit:#{fields['unit']} includeToday:#{fields['includeToday']} (rolls)"
        when :frozen
          warnings << "'#{cap}' relative-date window #{f['first_period']}..#{f['last_period']} #{period}s is shifted/spanning — no rolling mode fits → mode:between (#{fields['startDate'][0..9]}..#{fields['endDate'][0..9]}); FROZEN — re-run to refresh"
        end
      when 'number-range'
        # An UNRESTRICTED Tableau quantitative filter carries no min/max (the
        # <filter class='quantitative'> has no explicit bounds) → "all values".
        # Emitting {min:null, max:null} on a mode:between number-range 400s the
        # whole POST (issue #422 — recurred across workbooks). A range
        # that filters nothing is a NO-OP, so mirror the categorical "All"
        # handling above and emit NO element filter; where a bound IS present,
        # emit only the non-nil key(s) so the shape never carries a null bound.
        fmin = f['min']
        fmax = f['max']
        if fmin.nil? && fmax.nil?
          warnings << "'#{cap}' quantitative quick filter on '#{fcap}' is UNRESTRICTED (no min/max — Tableau 'All') — no Sigma element filter emitted (an unbounded number-range with null bounds 400s the POST; #422)"
          next
        end
        fcol = el_filter_col_for.call(m)
        next if fcol.nil? # helper-sourced chart, column unreachable (warned in el_filter_col_for)
        nr = { 'columnId' => fcol, 'kind' => 'number-range', 'mode' => 'between', 'includeNulls' => 'never' }
        nr['min'] = fmin unless fmin.nil?
        nr['max'] = fmax unless fmax.nil?
        el_filters << nr
      when 'wildcard'
        # D5/P0.6 (parsed pattern; the unparseable shape was intercepted above).
        # Worksheet-scoped wildcard → hidden Contains/StartsWith/EndsWith match
        # column + keep-filter. Text values only (numeric/boolean list values
        # 400 at runtime — Text() casting rule).
        fcol = el_filter_col_for.call(m)
        next if fcol.nil? # helper-sourced chart, column unreachable (warned in el_filter_col_for)
        wc = f['wildcard']
        match_fn = {
          'contains' => 'Contains', 'does-not-contain' => 'Contains',
          'starts-with' => 'StartsWith', 'does-not-start-with' => 'StartsWith',
          'ends-with' => 'EndsWith', 'does-not-end-with' => 'EndsWith'
        }[wc['mode'].to_s]
        if match_fn.nil?
          warnings << "'#{cap}' wildcard filter on '#{fcap}' mode #{wc['mode'].inspect} has no match-function mapping — STAYS-MANUAL"
          next
        end
        negated = wc['mode'].to_s.start_with?('does-not-')
        pat_lit = JSON.generate(wc['pattern'].to_s)
        wcid = "wc-#{el_id}-#{fcol}"
        unless (element['columns'] || []).any? { |c| c['id'] == wcid }
          element['columns'] << {
            'id' => wcid, 'name' => "Wildcard Match (#{m['name']})",
            'formula' => "If(#{match_fn}([#{m['name']}], #{pat_lit}), \"match\", \"no-match\")"
          }
        end
        el_filters << {
          'columnId' => wcid, 'kind' => 'list', 'mode' => 'include',
          'selectionMode' => 'multiple', 'values' => [negated ? 'no-match' : 'match'],
          'includeNulls' => 'never'
        }
        warnings << "'#{cap}' WILDCARD quick filter on '#{fcap}' → #{match_fn}() match column + " \
                    "keep-filter (#{wc['mode']} #{pat_lit}; Tableau-style match is case-sensitive here — verify)"
      when 'list+condition', 'unknown'
        # No silent skips (the old dispatch had no arm here — condition-only and
        # unknown filter classes vanished without a trace).
        warnings << "'#{cap}' quick filter on '#{fcap}' (kind=#{f['kind']}" \
                    "#{f['condition_expressions'] ? "; conditions: #{Array(f['condition_expressions']).join('; ')[0..120]}" : ''}) " \
                    'has no element-filter mapping — STAYS-MANUAL, no Sigma element filter emitted'
      end
    end
    value_filters.each do |f|
      applied_before = el_filters.length
      emit_value_filter.call(f)
      ds_filter_applications[f.object_id] << cap if f['_ds_scope'] && el_filters.length > applied_before
    end
    # Every element filter needs a unique `id` (the live /v2/workbooks/.../spec
    # readback shows `id: flt-<element>-<n>`); the API rejects filters without it.
    el_filters.each_with_index { |nf, i| nf['id'] = "flt-#{el_id}-#{i}" }
    element['filters'] = el_filters unless el_filters.empty?

    # Surface Tableau-side calculated fields the worksheet uses, and auto-
    # translate the ones we know how to handle (parameter-driven Switch).
    # Otherwise emit a translation hint so the agent can wire it up by hand.
    param_caps = (meta['parameters'] || []).map { |p| p['caption'] }.compact
    (z['calculations'] || []).each do |c|
      formula = c['formula'].to_s
      next if formula.empty?

      # Tableau bin column (calc class='bin') → Sigma NATIVE binning
      # (beads-sigma-t67b). Must run before the bare-column-ref skip below —
      # a bin calc's formula IS a bare ref to the base field. Sigma has
      # BinFixed(value, min, max, binCount) (equal-width bins over [min, max])
      # and BinRange(value, b1, b2, ...) (explicit cutoffs); do NOT hand-roll
      # Floor((x - peg) / width) bucket math. Tableau bins are width-based, so
      # preserve the width by deriving binCount from the data's min/max.
      if c['class'] == 'bin'
        width = c['bin_size'] || '<width>'
        peg   = c['bin_peg'] || '0'
        warnings << "'#{cap}' Tableau bin #{c['name']} (width #{width}, origin #{peg}) on #{formula} → " \
                    "Sigma native binning: BinFixed([Master/#{formula.gsub(/^\[|\]$/, '')}], <min>, <max>, " \
                    "Ceiling((<max> - <min>) / #{width})) with <min>/<max> from the data " \
                    '(align <min> to the peg); for hand-picked buckets use BinRange(col, b1, b2, ...). ' \
                    'Do NOT emit Floor() bucket math — Sigma has native bin functions.'
        next
      end

      # Nested FIXED LODs → helper-element chain (beads-sigma-t67b). One DM/
      # workbook helper element per LOD level, innermost first; the outer level
      # consumes the inner via [LOD Helper k/Value]. Machine-readable chain
      # lands in <out>-lod-chains.json for the agent to build the elements.
      if (lod = decompose_nested_fixed(formula))
        lod['calc']            = c['name']
        lod['caption']         = c['caption']
        lod['worksheet']       = cap
        lod['tableau_formula'] = formula
        lod_chains << lod
        chain_desc = lod['chain'].map do |l|
          "#{l['helper']} = #{l['sigma_aggregate']} grouped by [#{l['dims'].join(', ')}]"
        end.join(' → ')
        warnings << "'#{cap}' nested FIXED LOD #{c['name']} → #{lod['chain'].length}-level " \
                    "helper-element chain (innermost first): #{chain_desc}; " \
                    "final = #{lod['final']} — outer levels must source the inner element " \
                    'with groupingId (or a Custom SQL GROUP BY) or aggregates come ' \
                    'out row-weighted — see the -lod-chains.json sidecar'
        next
      end

      next if formula =~ /\A\s*(SUM|COUNT|AVG|MIN|MAX)\(\[[^\]]+\]\)\s*\z/
      next if formula =~ /\A\s*\[[^\]]+\]\s*\z/

      # The plotted measure's window calc was already auto-emitted on this
      # chart (inline yAxis viz formula or two-stage helper) — skip the
      # hint-only re-translation so the WARN stream stays single-sourced.
      next if window_plan && window_calc_name &&
              c['name'].to_s.gsub(/^\[|\]$/, '').casecmp?(window_calc_name)

      # Try parameter-driven translations first (CASE / IF chain on param).
      # Pass mmap + the GUID→caption map so the Switch branch result refs are
      # remapped onto [Master/…] (else they leak raw Tableau UUIDs / sibling
      # calc names that validate-spec rejects as non-sibling).
      cbg = meta['columns_by_guid'] || {}
      # Normalize param-by-name → caption so the Switch translators (which match
      # on caption) recognize formulas that reference a param by internal name.
      pnmap = {}
      (meta['parameters'] || []).each do |p|
        c = p['caption']; n = p['name'].to_s.gsub(/^\[|\]$/, '')
        pnmap[n] = c if c && !n.empty?
      end
      formula_pn = formula.gsub(/(\[Parameters?\]\s*\.\s*\[)([^\]]+)(\])/i) do
        "#{Regexp.last_match(1)}#{pnmap[Regexp.last_match(2)] || Regexp.last_match(2)}#{Regexp.last_match(3)}"
      end
      translated = translate_case_on_param(formula_pn, param_caps, mmap, cbg) ||
                   translate_if_chain_on_param(formula_pn, param_caps, mmap, cbg)
      if translated
        calc_name = c['name'].to_s.gsub(/^\[|\]$/, '')
        # Sigma resolves a STANDALONE `[Master/X]` passthrough column against the
        # source, but a `[Master/X]` nested inside a Switch() does NOT resolve
        # unless X is a materialized SIBLING column of this element. So: for each
        # distinct `[Master/X]` branch ref, add a hidden passthrough sibling
        # column named X (formula `[Master/X]`, which resolves standalone), then
        # rewrite the Switch to reference the sibling `[X]`. Without this the
        # Switch compiles to type "error" (branch refs unresolved).
        branch_refs = translated.scan(/\[Master\/([^\]]+)\]/).flatten.uniq
        existing_names = (element['columns'] || []).map { |c2| c2['name'] }.compact
        branch_refs.each do |bname|
          next if existing_names.include?(bname)
          bid = "swcol-#{bname.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')
          element['columns'] << { 'id' => bid, 'name' => bname,
                                  'formula' => "[Master/#{bname}]" }
          existing_names << bname
        end
        switch_sibling = translated.gsub(/\[Master\/([^\]]+)\]/) { "[#{Regexp.last_match(1)}]" }

        # The mechanical pass emits the worksheet dimension as a passthrough
        # column ([Master/<calc>]) and the chart GROUPS BY it. That passthrough
        # resolves to the DM's own (static, param-frozen) copy of the calc, so
        # the workbook control drives nothing. Rewrite the passthrough column(s)
        # in place to the control-driven Switch (over the materialized siblings)
        # so the grouping itself does the swap; only append a standalone calc
        # column if no passthrough exists.
        rewired = rewire_param_switch!(element['columns'], calc_name, switch_sibling)
        # The measure-role path (above) may have ALREADY bound this Switch as the
        # yAxis measure (e.g. Sum(Switch(...))). Don't also append a standalone
        # orphan — only append when nothing carries the Switch yet.
        already_bound = (element['columns'] || []).any? { |col| col['formula'].to_s.include?(switch_sibling) }
        if rewired.zero? && !already_bound
          calc_id = "calc-#{calc_name.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')
          element['columns'] << { 'id' => calc_id, 'name' => calc_name, 'formula' => switch_sibling }
        end
        warnings << "'#{cap}' parameter-driven calc #{c['name']} → control-driven Switch over " \
                    "#{branch_refs.size} materialized branch col(s) (#{rewired} grouping rewired): #{switch_sibling[0..90]}"
        next
      end

      # Try customer-learned rules FIRST — these are translations the scout
      # subagent has validated against this customer's Sigma site. Anything
      # here is known-to-work in their context, so it wins over built-in
      # heuristics. Source: ~/.tableau-to-sigma/learned-rules.yaml (user home,
      # never clobbered by skill updates).
      lr_translated, lr_hint = LearnedRules.apply(LEARNED_RULES, formula)
      if lr_translated
        warnings << "'#{cap}' learned-rule applied to #{c['name']} → Sigma:  #{lr_translated[0..160]}  [#{lr_hint}]"
        next
      end

      # Try table-calc / common-fn translations (INDEX/LOOKUP/TOTAL/RANK/ZN/etc.).
      tc_translated, tc_hint = translate_tableau_tc(formula)
      if tc_translated
        warnings << "'#{cap}' Tableau table-calc #{c['name']} → Sigma:  #{tc_translated[0..160]}  [#{tc_hint}]"
        next
      end

      hint = if formula =~ /\bIIF\(.*=.*0.*,\s*SUM.*\/\s*SUM/
               'ratio calc — translate as `Sum(num) / NullIf(Sum(den), 0)` on master OR via Custom SQL'
             elsif formula =~ /\bIF\b.*\bELSEIF\b.*\bEND\b/i
               'IF/ELSEIF chain — translate to nested Sigma If(...) or Switch(...) on master'
             elsif formula =~ /\bCASE\b/i
               'CASE statement — translate to Sigma Switch(value, when1, then1, ...) on master'
             elsif formula =~ /\bSUM\(.*\)\s*\/\s*COUNT\(/i
               'ratio calc — translate as `Sum(...) / Count(...)` (or CountIf for NotNull) on master'
             elsif formula =~ /\[Parameters?\]\.|\[Parameters?\s+\(/
               'parameter-driven calc — translate to Sigma control + Switch()/If() formula'
             else
               'calc — translate to Sigma formula and add as a master column or workbook calc'
             end
      warnings << "'#{cap}' uses Tableau calc #{c['name']}: #{hint}. Formula: #{formula[0..120]}"
    end

    # Param measure-picker (n4pi.10): the tile measure was set to the control-
    # driven Switch (sibling form) above — materialise the hidden passthrough
    # sibling cols its branches reference, and register the control for emission.
    if chart_pswitch_plan
      add_switch_siblings!(element, chart_pswitch_plan['branch_refs'])
      $param_switch_used << chart_pswitch_plan['control_id'] unless $param_switch_used.include?(chart_pswitch_plan['control_id'])
      warnings << "'#{cap}' measure '#{meas_hdr}' is a parameter measure-picker → control-driven Switch over " \
                  "[#{chart_pswitch_plan['control_id']}] (#{chart_pswitch['cases'].size} option(s))"
    end

    # Stamp with worksheet + dashboard so the page emitters can group.
    element['_worksheet'] = cap
    element['_dashboard'] = dash['dashboard']
    elements << element
  end
end

# ---- D2/P0.2 loud summary: datasource/extract filter application -----------
# Every parsed datasource-level (and extract) filter must be visibly accounted
# for: which elements now carry it, or a NOT-applied warning (unmapped column /
# unsupported kind) so the over-reporting risk is never silent.
ds_value_filters.each do |df|
  label = df['column_caption'] || df['raw_param']
  scope_word = df['filter_scope'] == 'extract' ? 'EXTRACT filter' : 'DATASOURCE filter'
  applied = ds_filter_applications[df.object_id].uniq
  if applied.any?
    warnings << "#{scope_word} on '#{label}' (#{df['kind']}#{df['exclude'] ? ' exclude' : ''}" \
                "#{(df['members'] || []).any? ? ": #{df['members'].join(', ')[0..80]}" : ''}) from " \
                "datasource '#{df['datasource']}' applied as an element filter on #{applied.size} " \
                "element(s): #{applied.join(', ')[0..200]}" \
                "#{df['filter_scope'] == 'extract' ? ' [provenance: Tableau EXTRACT filter — rows were pre-filtered at extract time]' : ''}"
  else
    warnings << "#{scope_word} on '#{label}' from datasource '#{df['datasource']}' was NOT applied to any " \
                'element (unmapped column, unsupported kind, or no element on that datasource) — every sheet ' \
                'on it may OVER-REPORT; wire the filter by hand (element filters or a DM-level filter)'
  end
end

# ---- B4: styled static text (gap ubr5.8) -----------------------------------
# Assemble a Sigma text.body from Tableau formatted-text runs (parse-twb-layout
# `text_runs`). Each run → an inline <span style> carrying its source color +
# font-size (px, verbatim — the source point size faithfully preserves relative
# weight, so no fragile markdown-heading guessing), with **bold** for bold runs;
# hard-break runs (the Æ+newline sentinel) split paragraphs (\n\n). A run's
# literal whitespace is emitted plain (keeps inter-run spacing). Dynamic Tableau
# tokens (<[Parameters]…>) can't be reproduced as static text and would corrupt
# the HTML body, so they're stripped (caller WARNs). `align` wraps center/right
# in a <p> (left is Sigma's default and 400s if forced — styling.md); `bg` wraps
# the content in a background-color span (a pill/chip). Returns nil when nothing
# visible remains. All colors are hex (var(--…) 400s). Pure/self-contained so
# test-styled-text-body.rb can extract and eval it.
# default_px (v5.4): a run WITHOUT an explicit fontsize inherits Tableau's
# zone-sized rendering — for single-line title/banner zones the text is sized
# to the zone box. Callers derive a px-true default from the zone's pixel
# height (see the B4 call site) and thread it here; explicit run sizes always
# win.
# force_color (header-contrast fix): when a title text zone lands on a DARK
# header band (build-dashboard-layout paints the container backgroundColor from
# the SAME source fill), the source's own dark run colours (e.g. #1b1b1b) render
# invisible and any white background-color span makes a white box on the black
# band. force_color overrides every run's colour to a light hex AND suppresses
# the bg pill wrapper, so the title reads as light-on-dark. Only the caller that
# detects a dark header band passes it; every other text element is untouched.
def text_body_from_runs(runs, align: nil, bg: nil, default_px: nil, force_color: nil)
  bg = nil if force_color # never a background-color span over a dark band
  return nil if runs.nil? || runs.empty?
  # Split into paragraphs on hard-break runs. A break run often CARRIES text
  # (the parser marks any run containing newlines as break:true — "G\nD\nP"
  # vertical letter stacks, "\nSource: …" credit lines): split that
  # text on its newlines into successive paragraphs. Discarding it (the old
  # behavior) silently erased every such zone — a letter-stack zone rendered
  # as an EMPTY body and the whole element was dropped.
  lines = [[]]
  runs.each do |r|
    unless r['break']
      lines.last << r
      next
    end
    segs = r['text'].to_s.split("\n", -1)
    if segs.all? { |s| s.strip.empty? }
      lines << [] # pure hard-break sentinel — paragraph split only
    else
      segs.each_with_index do |seg, i|
        lines << [] if i.positive?
        lines.last << r.merge('text' => seg, 'break' => false) unless seg.empty?
      end
    end
  end
  rendered = lines.map do |line|
    line.map do |r|
      raw = r['text'].to_s
      raw = raw.gsub(/<\[[^\]]*\][^>]*>/, '') if raw.include?('<[') # drop dynamic tokens
      next '' if raw.empty?
      next raw if raw.strip.empty? # whitespace spacer → literal (keeps run spacing)
      esc = raw.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      # Bold/italic markers must hug the text — markdown won't style "** Rank**"
      # (leading space inside the markers). Keep leading/trailing whitespace
      # OUTSIDE. Sigma has no font-style/font-weight span props (whitelist:
      # color/background-color/font-size/font-family) — bold+italic are
      # markdown (**/*, combined ***), underline the whitelisted <u> tag.
      marker = "#{'**' if r['bold']}#{'*' if r['italic']}"
      if !marker.empty? && (mm = esc.match(/\A(\s*)(.*?)(\s*)\z/m)) && !mm[2].empty?
        esc = "#{mm[1]}#{marker}#{mm[2]}#{marker.reverse}#{mm[3]}"
      end
      esc = "<u>#{esc}</u>" if r['underline'] && !esc.strip.empty?
      styles = []
      run_color = force_color || r['color']
      styles << "color: #{run_color}" if run_color
      if (fs = r['font_size'] || default_px)
        styles << "font-size: #{fs}px"
      end
      styles << "font-family: #{r['font']}" if r['font']
      styles.empty? ? esc : %(<span style="#{styles.join('; ')}">#{esc}</span>)
    end.join
  end
  body = rendered.reject { |l| l.strip.empty? }.join("\n\n")
  return nil if body.strip.empty?
  body = %(<span style="background-color: #{bg}">#{body}</span>) if bg
  %w[center right].include?(align.to_s) ? %(<p style="text-align: #{align}">#{body}</p>) : body
end

# ---- Title text element ----
# If --title given, emit a text element. If --title omitted AND the parser
# found a title/text zone, infer the dashboard name from the parser output.
#
# The source's OWN top title zone (a text/title zone near the top carrying
# run-level formatting) is emitted faithfully as a styled `text-<id>` element
# (B4 path) and placed at the top. Synthesizing a second "# <name>" title here
# then DOUBLES the title — the dashboard shows it at the top AND again in the
# stray text band (the "title top + bottom" duplicate). So skip the synthetic
# title WHENEVER the source has its own top title zone — regardless of whether
# --title was passed. (migrate-tableau always passes --title, which is exactly
# why the old `opts[:title].nil?`-only guard never fired and the title doubled.)
source_has_top_title = layout.any? do |dash|
  (dash['zones'] || []).any? do |z|
    %w[title text].include?(z['kind']) && (z['y_pct'] || 100) < 10 && z['text_runs']
  end
end
auto_title = nil
if opts[:title].nil? && !source_has_top_title
  layout.each do |dash|
    top = dash['zones'].select { |z| %w[title text].include?(z['kind']) && (z['y_pct'] || 100) < 10 }
    next if top.empty?
    auto_title = dash['dashboard']
    break
  end
end
# Source banner wins: when it exists, the styled text-<id> element IS the title
# (placed at its own top geometry by the layout stage), so emit no synthetic one.
title_text = source_has_top_title ? nil : (opts[:title] || auto_title)

extras = []
if title_text
  extras << {
    'id'   => 'title-text',
    'kind' => 'text',
    # Theme-default colour (dark on a light canvas). build-dashboard-layout now
    # emits a colored header band ONLY when the source actually has one; a bare
    # source title (no styled runs, so we synthesize here) sits on the page
    # canvas, where a forced-white title would render invisibly. Sources WITH a
    # styled title zone are handled by the B4 path below (skipped above), which
    # carries the source's own run colours.
    'body' => "# #{title_text}"
  }
end

# ---- B4: styled static-text elements ---------------------------------------
# Emit each dashboard text/title zone that carries run-level formatting as a
# Sigma `text` element (id "text-<zoneid>") that the layout stage places at the
# zone's own geometry (build-dashboard-layout resolve_leaf). These were dropped
# entirely before — subtitle, captions, credit line, section headers, and BAN
# annotations all vanished. Dashboard-level chrome, so skipped in
# --page-per-worksheet (which ignores the dashboard layout by design).
styled_text_by_dash = Hash.new { |h, k| h[k] = [] }
# Normalize a label for KPI-title dedup: lowercase, drop all non-alphanumerics,
# strip a trailing plural 's'. So "# Feature Types" (label) matches the KPI
# caption "# Feature Type" — Tableau KPI-card labels routinely differ from the
# scorecard sheet name by pluralization/punctuation.
norm_label = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '').sub(/s\z/, '') }
unless opts[:pages_mode] == :worksheet
  layout.each do |dash|
    # KPI captions on this dashboard. A Tableau "KPI card" is a label text zone
    # ABOVE a scorecard worksheet; Sigma's kpi-chart renders its own title, so a
    # standalone styled-text zone whose text just repeats a KPI's caption is a
    # redundant duplicate — emitting it (and dumping it in a stray band) is the
    # "orphan labels at the bottom" defect. Drop those; keep real prose/sections.
    kpi_zones = (dash['zones'] || []).select { |z| z['is_kpi'] }
    kpi_labels = kpi_zones.select { |z| z['caption'] }
                          .map { |z| norm_label.call(z['caption']) }.reject(&:empty?)
    # A Tableau KPI card is often a LABEL text zone sitting directly above the
    # scorecard sheet in the same column band — and its label is the clean measure
    # name ("Net Revenue"), which does NOT match the scorecard's internal caption
    # ("OV KPI Revenue"), so the name dedup above misses it and the labels pile
    # into a stray bottom band (the "orphan labels" defect). Catch them
    # POSITIONALLY: a short text zone whose x-band overlaps a KPI zone, is about
    # the same width (not a full-width section title), and sits just above it is
    # that card's label — Sigma's kpi-chart renders its own title, so drop it.
    labels_kpi_positionally = lambda do |t|
      tx, tw, ty, th = %w[x_pct w_pct y_pct h_pct].map { |k| t[k] }
      return false unless [tx, tw, ty].all? { |v| v.is_a?(Numeric) } && tw > 0

      kpi_zones.any? do |k|
        kx, kw, ky = %w[x_pct w_pct y_pct].map { |kk| k[kk] }
        next false unless [kx, kw, ky].all? { |v| v.is_a?(Numeric) } && kw > 0
        next false if tw > kw * 1.5                        # wider banner/section title, not a per-card label
        ovl = [tx + tw, kx + kw].min - [tx, kx].max        # horizontal overlap
        next false unless ovl / [tw, kw].min >= 0.6        # same column band
        ty < ky && (ky - ty) <= (th.to_f > 0 ? th * 3 : 14.0) # sits just above the card
      end
    end
    (dash['zones'] || []).each do |z|
      next unless %w[text title].include?(z['kind']) && z['text_runs']
      # v5.0-P2: a blank-text DIVIDER zone becomes a native divider in the
      # layout (plan_node) — emitting its whitespace body here too would leave
      # an unplaced text element that lands in a stray bottom band.
      next if ZoneCensus.divider_zone?(z, dash['canvas_px'])
      full_text = z['text_runs'].map { |r| r['text'] }.join
      plain = norm_label.call(full_text)
      is_short_label = full_text.split.length <= 5 && z['text_runs'].none? { |r| r['break'] }
      if !plain.empty? && (kpi_labels.include?(plain) || (is_short_label && labels_kpi_positionally.call(z)))
        warnings << "dashboard '#{dash['dashboard']}' text zone #{z['id']} (#{plain.inspect}) " \
                    'labels a KPI card — dropped (the Sigma kpi-chart renders its own title)'
        next
      end
      # v5.4 px-true titles, corrected v5.4.9: a text run with NO explicit
      # fontsize renders at Tableau's workbook default (~9pt ≈ 12px) REGARDLESS
      # of zone height — Tableau has no zone-fit text scaling, so the earlier
      # height-derived size (0.55 × zone px) 4x-oversized any default-size
      # label stretched by a fit-height layout container. Emit the flat default
      # so Sigma's larger text default doesn't inflate single-line titles.
      # Explicit run sizes always win; multi-line zones are left to Sigma
      # defaults.
      default_px = nil
      if z['text_runs'].none? { |r| r['font_size'] } && z['text_runs'].none? { |r| r['break'] }
        default_px = 12
        warnings << "dashboard '#{dash['dashboard']}' text zone #{z['id']}: no explicit run sizes — " \
                    "emitted Tableau's default 12px (~9pt; px-true title)"
      end
      # Header-contrast fix: a top-of-page title zone (y_pct < 10) that will
      # land on a DARK header band (build-dashboard-layout derives the band bg
      # from the SAME source fill via ZoneCensus.dark_header_fill) must render
      # LIGHT — otherwise the source's dark run colours (and any white pill bg)
      # produce dark-text/white-box on a black band (unreadable). Force the
      # title white and drop the pill bg in that one case; all other text
      # zones keep their source colours and pills.
      on_dark_header = (z['y_pct'] || 100) < 10 &&
                       !ZoneCensus.dark_header_fill(dash['zone_tree'] || dash['zones']).nil?
      body = text_body_from_runs(z['text_runs'], align: z['text_align'],
                                 bg: (z['is_pill'] ? z['fill_color'] : nil),
                                 default_px: default_px,
                                 force_color: (on_dark_header ? '#FFFFFF' : nil))
      next if body.nil?
      warnings << "dashboard '#{dash['dashboard']}' title zone #{z['id']}: sits on a DARK header band — " \
                  'forced light (white) title text and dropped any white background-color span for contrast' if on_dark_header
      if z['text_runs'].any? { |r| r['text'].to_s.include?('<[') }
        warnings << "dashboard '#{dash['dashboard']}' text zone #{z['id']}: dynamic Tableau token(s) " \
                    '(<[Parameters]…>) dropped from static text — not reproducible as literal text'
      end
      el = { 'id' => "text-#{z['id']}", 'kind' => 'text', 'body' => body }
      # Short single-line annotations/pills read better vertically centered.
      el['verticalAlign'] = 'middle' if z['is_pill'] || z['text_runs'].none? { |r| r['break'] }
      el['_dashboard'] = dash['dashboard']
      styled_text_by_dash[dash['dashboard']] << el
    end
  end
end
# ---- v5.0: image (bitmap) zones → Sigma image elements ---------------------
# Tableau image zones ship their bitmap INSIDE the .twbx (`image_path` is the
# exact zip path, e.g. 'Image/title art.png'). Extract each to <tab>/assets/
# and emit {kind:"image", source:{kind:"url", url:"data:image/…;base64,…"}}.
# The URL may be a data: URI or a hosted URL — BOTH validate. What the API
# rejects is the FLAT `url:` shape, for every image (live-probed 2026-08-06:
# flat -> 400 Invalid kind: "image"; nested source -> valid:true). The original
# register blamed data: URIs; the shape was the actual defect.
# Zones with a web-hosted `image_file_url` use the
# URL directly. Full-canvas backgrounds (is_background) are page-level design,
# not grid tiles: extracted + recorded in <tab>/image-assets.json for the
# background/composite step, never emitted as elements (the layout builder
# skips them too). Same per-dashboard bucket as styled text so page routing
# and the final merge treat them identically.
image_asset_records = []
unless opts[:pages_mode] == :worksheet
  twbx = Dir.glob(File.join(opts[:tab], '*.twbx')).first
  assets_dir = File.join(opts[:tab], 'assets')
  extract_asset = lambda do |zip_path|
    return nil unless twbx && zip_path
    dest = File.join(assets_dir, File.basename(zip_path))
    unless File.exist?(dest)
      require_relative 'lib/zip_extract' # stdlib Zlib reader — no shelled unzip binary (Windows-safe)
      data = ZipExtract.read(twbx, zip_path)
      return nil unless data && !data.empty?
      require 'fileutils'
      FileUtils.mkdir_p(assets_dir)
      File.binwrite(dest, data)
    end
    dest
  end
  mime_for = lambda do |path|
    case File.extname(path.to_s).downcase
    when '.jpg', '.jpeg' then 'image/jpeg'
    when '.gif'          then 'image/gif'
    when '.svg'          then 'image/svg+xml'
    else 'image/png'
    end
  end
  layout.each do |dash|
    (dash['zones'] || []).each do |z|
      next unless z['kind'] == 'image'
      asset = extract_asset.call(z['image_path'])
      record = { 'dashboard' => dash['dashboard'], 'zone_id' => z['id'],
                 'image_path' => z['image_path'], 'asset' => asset,
                 'is_background' => !!z['is_background'],
                 'is_scaled' => z['is_scaled'], 'is_centered' => z['is_centered'] }
      record['image_file_url'] = z['image_file_url'] if z['image_file_url']
      # v5.0 pixel classification (lib/png_classify): a bitmap whose pixels
      # read as a ROUNDED CARD (transparent corners + near-uniform interior)
      # is Tableau's faked-container idiom — the faithful Sigma target is a
      # styled container (style.backgroundColor + borderRadius), not a
      # stretched image. v1 records the verdict + extracted fill/radius and
      # NOTEs it for the RCF loop; fail-open (decode failure → 'art' → the
      # data-URI element path, never worse than today).
      if asset
        cls = PngClassify.classify(asset, zone_w_pct: z['w_pct'], zone_h_pct: z['h_pct'],
                                          canvas_w: dash.dig('canvas_px', 'w'),
                                          canvas_h: dash.dig('canvas_px', 'h'))
        if cls.is_a?(Hash)
          record['pixel_kind'] = cls['kind']
          if cls['kind'] == 'rounded_card'
            record['card_fill']      = cls['fill']
            record['card_radius_px'] = cls['radius_px']
            warnings << "NOTE dashboard '#{dash['dashboard']}' image zone #{z['id']} " \
                        "(#{File.basename(asset)}) is a ROUNDED-CARD bitmap (fill #{cls['fill']}, " \
                        "r=#{cls['radius_px']}px) — prefer a styled container " \
                        "(backgroundColor + borderRadius) over the image element (image-assets.json)"
          end
        end
      end
      image_asset_records << record
      if z['is_background']
        warnings << "dashboard '#{dash['dashboard']}' image zone #{z['id']} is a FULL-CANVAS " \
                    "background (#{z['image_path']}) — extracted to #{asset || 'UNEXTRACTED'}; " \
                    'apply as page background / composite, not a grid element (image-assets.json)'
        next
      end
      url = z['image_file_url']
      if url.nil? && asset
        url = "data:#{mime_for.call(asset)};base64,#{Base64.strict_encode64(File.binread(asset))}"
      end
      if url.nil?
        warnings << "dashboard '#{dash['dashboard']}' image zone #{z['id']} " \
                    "(#{z['image_path'].inspect}) — asset not extractable (no .twbx?); NAMED RESIDUE"
        next
      end
      styled_text_by_dash[dash['dashboard']] <<
        { 'id' => "img-#{z['id']}", 'kind' => 'image',
          'source' => { 'kind' => 'url', 'url' => url },
          '_dashboard' => dash['dashboard'] }
    end
  end
  if image_asset_records.any?
    File.write(File.join(opts[:tab], 'image-assets.json'), JSON.pretty_generate(image_asset_records))
    warn "image zones: #{image_asset_records.size} found, " \
         "#{image_asset_records.count { |r| r['is_background'] }} background(s) — image-assets.json written"
  end
end

# ---- v5.0-P2: dashboard-object BUTTONS -------------------------------------
# Corpus census: navigate (dashboard→dashboard, i.e. page→page in Sigma),
# export-image/pdf (redundant — Sigma has a built-in export menu), toggle
# (show/hide container — no spec equivalent). NAVIGATE buttons are emitted;
# the rest become named residue (spec_api_limit_entries).
#
# Emission shape: Sigma's native kind:button is spec-valid but WORKSPACE-GATED
# (live-probed 2026-07-11: verify 200, PUT 400 "`button` elements are not
# enabled for this workspace") — so the default is the proven text-pill
# fallback (markdown link + pill background), with real buttons behind
# SIGMA_BUTTON_ELEMENTS=on for workspaces that have the flag. Both carry the
# machine-recognizable placeholder URL https://nav.invalid/#page=<name>;
# put-layout.rb rewrites it to the live workbook page URL post-publish
# (the workbook URL doesn't exist until the POST returns).
nav_button_records = []
unless opts[:pages_mode] == :worksheet
  layout.each do |dash|
    (dash['zones'] || []).each do |z|
      next unless z['kind'] == 'dashboard-object' && z['button_intent'] == 'navigate'
      unless z['button_nav_target'] && z['button_nav_target_class'] == 'dashboard'
        warnings << "dashboard '#{dash['dashboard']}' button zone #{z['id']} navigates to a " \
                    "#{z['button_nav_target_class'] || 'unresolved'} target — no Sigma page equivalent (named residue)"
        next
      end
      label = z['button_caption'] ||
              z['button_tooltip'].to_s[/\Aclick to (?:navigate to|open) (?:the )?(.+)\z/i, 1] ||
              z['button_nav_target']
      url = "https://nav.invalid/#page=#{ERB::Util.url_encode(z['button_nav_target'])}"
      el =
        if ENV['SIGMA_BUTTON_ELEMENTS'] == 'on'
          e = { 'id' => "btn-#{z['id']}", 'kind' => 'button', 'text' => label,
                'appearance' => 'filled', 'align' => 'center', 'size' => 'small',
                'actions' => [{ 'trigger' => 'on-click', 'effects' => [{
                  'effect' => 'open-url', 'openTarget' => '_self', 'url' => url }] }] }
          e['fillColor'] = z['fill_color'][0, 7] if z['fill_color']
          e['fontColor'] = z['button_font_color'] if z['button_font_color']
          e
        else
          # Text-pill fallback (proven live): bold markdown link, pill bg.
          body = "[**#{label}**](#{url})"
          body = %(<span style="background-color: #{z['fill_color'][0, 7]}">#{body}</span>) if z['fill_color']
          { 'id' => "btn-#{z['id']}", 'kind' => 'text',
            'body' => %(<p style="text-align: center">#{body}</p>), 'verticalAlign' => 'middle' }
        end
      el['_dashboard'] = dash['dashboard']
      styled_text_by_dash[dash['dashboard']] << el
      nav_button_records << { 'element_id' => "btn-#{z['id']}", 'dashboard' => dash['dashboard'],
                              'target_page_name' => z['button_nav_target'], 'label' => label }
    end
  end
  if nav_button_records.any?
    side = opts[:out].sub(/\.json$/, '-nav-buttons.json')
    File.write(side, JSON.pretty_generate(nav_button_records))
    warn "wrote #{side} (#{nav_button_records.size} navigation button(s) — put-layout.rb rewrites the placeholder URLs post-publish)"
  end
end

styled_text_all = styled_text_by_dash.values.flatten(1)

# ---- Control targeting: intended-scope closure ------------------------------
# A control filter applied to an element propagates to every element that
# SOURCES it (verified Sigma propagation), so the old emission hardcoded ONE
# target — opts[:master_id]. That goes DEAD for any chart whose source chain
# never reaches the master: DM-direct elements and dim-grain helpers source
# the data model itself (audit-proven case: a master-targeted Region control
# never filtered 'Monthly Revenue Trend'). Targeting now walks every emitted
# chart's source chain to its ROOT and targets the set of roots the control's
# INTENDED charts actually use. Intended scope per source signal:
#   * shared-view quick filters apply PER-DASHBOARD: the dashboards whose zone
#     tree carries that filter zone; no zone info → shared-view default (all)
#   * worksheet-level `[Action (X)]` filters: the sheets the .twb scopes the
#     action to join the closure even without a quick-filter zone
# The contract is recorded in <tableau-dir>/control-scope.json per control
# ({controlId, source_signal, intended matchers, targets, unreachable}) so the
# downstream coverage lint can assert it and allowlist by-design gaps.
control_scope_records = []
helpers_by_id = data_elements.to_h { |d| [d['id'], d] }
norm_cap = ->(s) { s.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '') }
# PR-18: decode columns the ORCHESTRATOR must add to the master element (a
# master-rooted list control's Text() decode must live ON the master so the
# filter propagates to every chart sourcing from it). Rides the output JSON as
# `master_decode_columns` (only when non-empty — additive/byte-identical).
master_decode_columns = []

# PR-18 — route an integer-coded discrete-dimension LIST control through a
# Text() decode helper. A Sigma list/dropdown control sources STRING option
# values; a filter target on the raw INTEGER column is accepted then SILENTLY
# stripped (reads back filters:null — control-parity.md). The sanctioned fix
# (proven by hand in Twin C's runs): add `Text([<col>])` on the element the
# control targets and bind BOTH the filter target AND the value-source to the
# decoded column. Mutates `targets` in place (rewrites each columnId to its
# decode column) and returns:
#   { applied:, source: {elementId:, columnId:} | nil, helpers: [name,...],
#     manual: [ "<why the target couldn't be decoded>", ... ] }
# manual entries are NEVER silently dropped: the caller routes them to the
# POSTPUBLISH guide and the control-scope sidecar.
route_integer_dim_decode = lambda do |targets, mcol, cap, slug|
  result = { applied: false, source: nil, helpers: [], manual: [] }
  targets.each do |t|
    root = t.dig('source', 'elementId')
    raw_id = t['columnId']
    if root == opts[:master_id] && mcol
      # Master-rooted: the decode column lives on the master (sibling ref by the
      # master column's friendly name). Injected by the orchestrator.
      dec_id = IntegerDim.decode_col_id(slug, opts[:master_id])
      dec_name = IntegerDim.decode_name(mcol['name'])
      unless master_decode_columns.any? { |c| c['id'] == dec_id }
        master_decode_columns << { 'id' => dec_id, 'name' => dec_name,
                                   'formula' => IntegerDim.decode_formula_for("[#{mcol['name']}]") }
      end
      t['columnId'] = dec_id
      result[:helpers] << dec_name
      result[:applied] = true
      result[:source] ||= { elementId: opts[:master_id], columnId: dec_id }
    else
      el = elements.find { |e| e['id'] == root } || helpers_by_id[root]
      raw_col = el && (el['columns'] || []).find { |c| c['id'] == raw_id }
      if el.nil? || raw_col.nil?
        # Cross-scope / hidden-master case: can't safely author the decode here
        # (the col isn't a modifiable table column on a reachable element).
        result[:manual] << "target element #{root.inspect} carries no addressable column for '#{cap}' — " \
                           'add a Text() decode column there by hand and repoint the control'
        next
      end
      dec_id = IntegerDim.decode_col_id(slug, root)
      dec_name = IntegerDim.decode_name(raw_col['name'])
      el['columns'] ||= []
      unless el['columns'].any? { |c| c['id'] == dec_id }
        el['columns'] << { 'id' => dec_id, 'name' => dec_name,
                           'formula' => IntegerDim.decode_formula_for("[#{raw_col['name']}]") }
      end
      t['columnId'] = dec_id
      result[:helpers] << dec_name
      result[:applied] = true
      result[:source] ||= { elementId: root, columnId: dec_id }
    end
  end
  result
end
# Chart-id/page snapshot for the sidecar's scope decision (taken BEFORE the
# page-mode emitters strip the _dashboard tags).
ctl_chart_index = elements.select { |e| e['source'] }
                          .map { |e| { 'id' => e['id'], 'dash' => e['_dashboard'], 'ws' => e['_worksheet'] } }

# The element a filter must target so it propagates into `el`: chains through
# hidden helpers; the master and any data-model-sourced element are roots.
root_of = lambda do |el|
  cur = el
  seen = {}
  loop do
    src = cur['source'] || {}
    return cur['id'] if src['kind'] == 'data-model'
    nxt_id = src['elementId']
    return cur['id'] if nxt_id.nil?
    return opts[:master_id] if nxt_id == opts[:master_id]
    nxt = helpers_by_id[nxt_id]
    return nxt_id if nxt.nil? || seen[nxt_id] # unknown id — treat as its own root
    seen[nxt_id] = true
    cur = nxt
  end
end

# Filter-target spec for caption `cap` on a root, or nil when the root carries
# no matching column (caller records it as unreachable — NEVER guess a column).
target_on_root = lambda do |root_id, cap, mcol|
  if root_id == opts[:master_id]
    return mcol && { 'source' => { 'kind' => 'table', 'elementId' => opts[:master_id] },
                     'columnId' => mcol['id'] }
  end
  rel = helpers_by_id[root_id] || elements.find { |e| e['id'] == root_id }
  col = rel && (rel['columns'] || []).find { |c| norm_cap.call(c['name']) == norm_cap.call(cap) }
  col && { 'source' => { 'kind' => 'table', 'elementId' => root_id }, 'columnId' => col['id'] }
end

# Dashboards whose zone tree carries a quick-filter zone for this caption.
filter_zone_dashboards = lambda do |cap|
  (layout || []).select do |d|
    (d['zones'] || []).any? do |z|
      z['kind'] == 'filter' && norm_cap.call(z['filter_column_caption']) == norm_cap.call(cap)
    end
  end.map { |d| d['dashboard'] }
end

# E1 (gap ubr5.17): a parameter/filter control's Tableau display mode → Sigma
# control style. parse-twb-layout surfaces the zone `mode` attr as
# `control_display` ('compact' → dropdown/Sigma controlType:list; 'type_in' →
# text; absent → default button/radio → segmented). control_display_for looks it
# up by the control's caption across all dashboards' (flat, all-descendant) zones,
# returning nil when Tableau gave no explicit mode (→ caller keeps segmented).
# `norm` is the caption normalizer (passed so this stays a pure, testable def).
def control_display_for(layout, cap, norm)
  (layout || []).each do |d|
    (d['zones'] || []).each do |z|
      next unless z['kind'] == 'filter' || z['kind'] == 'parameter'
      next unless norm.call(z['filter_column_caption']) == norm.call(cap)
      cd = z['control_display']
      return cd if cd && !cd.to_s.empty?
    end
  end
  nil
end

# Map a Tableau control_display (zone `mode`) to a Sigma controlType for a
# discrete/list signal. Full Tableau zone-mode vocabulary (v5.0 matrix):
# compact/checkdropdown → list (dropdown), checklist → list (multi),
# radiolist → segmented, type_in/pattern → text, otherwise segmented.
def sigma_control_type(disp)
  case disp
  when 'compact', 'checkdropdown', 'checklist' then 'list'
  when 'type_in', 'pattern' then 'text'
  else 'segmented'
  end
end

# Worksheets whose own view filters carry `[Action (<cap>)]` — the .twb scopes
# those cross-sheet filter actions to specific sheets.
action_worksheets = lambda do |cap|
  (meta['worksheets'] || {}).select do |_ws, w|
    (w['filters'] || []).any? do |f|
      f['is_action'] && f['raw_param'].to_s.include?("[Action (#{cap.to_s.strip})]")
    end
  end.keys
end

# Closure for one source filter: [targets, intended, unreachable, zone_dashes,
# action_ws]. `mcol` is the master-map entry (nil → master can't be a target).
control_targets = lambda do |cap, mcol|
  zd = filter_zone_dashboards.call(cap)
  aw = action_worksheets.call(cap)
  in_scope = elements.select do |e|
    e['source'] && ((zd.empty? || zd.include?(e['_dashboard'])) || aw.include?(e['_worksheet']))
  end
  roots = {}
  in_scope.each { |e| (roots[root_of.call(e)] ||= []) << e }
  targets, unreachable = [], []
  roots.each do |rid, els|
    t = target_on_root.call(rid, cap, mcol)
    if t
      targets << t
    else
      unreachable << { 'root' => rid, 'elements' => els.map { |e| e['name'] } }
    end
  end
  intended = in_scope.map do |e|
    { 'element_id' => e['id'], 'name' => e['name'], 'root' => root_of.call(e),
      'dashboard' => e['_dashboard'], 'worksheet' => e['_worksheet'] }
  end
  [targets, intended, unreachable, zd, aw]
end

# ---- Auto-generated parameter controls (--auto-controls) ------------------
# Tableau parameters become Sigma controls. The control's name matches the
# parameter caption so any translated `Switch([Param Caption], ...)` formula
# resolves to this control.
param_controls = []
unless opts[:no_auto_controls]   # default-on: never miss a .twb parameter/filter
  # Determine which parameter captions are actually referenced by any worksheet
  # calc. Tableau workbooks often define orphan parameters (defined but not used
  # by any calc field) — emitting controls for those clutters the dashboard
  # with widgets that filter nothing. Skip them.
  referenced_caps = (meta['worksheets'] || {}).values
    .flat_map { |w| (w['calculations'] || []).flat_map { |c| c['parameter_refs'] || [] } }
    .uniq
  # A Tableau parameter that drives a WIRED measure-picker Switch already has its
  # control emitted under the converter's controlId (ctl-parameter-<n>); don't ALSO
  # emit the legacy auto-param control (ctl-param-<caption>) for the same parameter
  # — that second control binds nothing and trips the control lint (n4pi.10).
  # Skip the redundant ctl-param-<caption> auto-control for any parameter that
  # already drives a WIRED measure-picker Switch (jwsf: when paramName was already
  # the caption, the old columns_by_guid-only lookup returned nil → the control
  # leaked, got pruned as unreferenced, and its orphan control-scope record tripped
  # control_lint "missing control"). picker_param_caps_index matches every caption
  # form.
  picker_param_caps = picker_param_caps_index($param_switches, $param_switch_used, meta['columns_by_guid'])
  # A parameter is typically declared once in the workbook metadata AND again in
  # every worksheet's datasource-dependencies that references it, so
  # meta['parameters'] commonly carries many duplicates of the same caption
  # (enterprise: ~600 declarations for ~38 params). Emitting one control per
  # declaration produces colliding element/control ids → "Duplicate id" on POST.
  # Dedup by caption so each parameter yields exactly one control.
  seen_param_caps = {}
  (meta['parameters'] || []).each_with_index do |p, i|
    cap = p['caption'].to_s.strip
    next if cap.empty?
    next if seen_param_caps[cap.downcase]
    seen_param_caps[cap.downcase] = true
    if picker_param_caps[norm_param_caption(cap)] || picker_param_caps[norm_param_caption(p['name'])]
      warnings << "parameter '#{cap}' drives a measure-picker Switch — control emitted under the converter controlId; skipping the redundant auto-param control"
      next
    end
    unreferenced_param = !referenced_caps.include?(cap)
    if unreferenced_param
      # "Never miss a parameter": an unreferenced param is usually a filter /
      # period picker whose driving calc was materialized to a column (so no
      # calc references it any more) — NOT dead. Emit it anyway (type-mapped
      # below) and flag it needs-wiring so it's surfaced in controls-coverage,
      # never silently dropped. (Was: silent `next` — the #1 "controls didn't
      # come over" cause.)
      warnings << "parameter '#{cap}' is not referenced by any worksheet calc — emitting it anyway (likely a filter/period picker); complete its filter wiring per controls-coverage.json"
    end
    slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
    # Base spec. includeNulls is added PER BRANCH — the OpenAPI carries it on
    # only 7 controlTypes (text/number/number-range/date/date-range/slider/
    # range-slider); stray on list/segmented/switch it's out-of-schema.
    spec = {
      'id'        => "el-param-#{slug}",
      'kind'      => 'control',
      'controlId' => "ctl-param-#{slug}",
      'name'      => cap
    }
    if p['param_domain'] == 'list' &&
       sigma_control_type(control_display_for(layout, cap, norm_cap)) == 'text'
      # type_in zone mode: a free-text input has NO source/selectionMode in the
      # schema (mode is REQUIRED); attaching the manual-source block made the
      # whole element off-schema (live leak class).
      spec['controlType'] = 'text'
      spec['mode'] = 'equals'
      spec['value'] = p['default_value']
      spec['includeNulls'] = 'when-no-value-is-selected'
    elsif p['param_domain'] == 'list'
      # E1: dropdown vs segmented from the Tableau control display mode; default
      # segmented (button row) when Tableau declared no explicit mode.
      spec['controlType']   = sigma_control_type(control_display_for(layout, cap, norm_cap))
      # Canonicalise member values to the SAME numeric form the translated Switch
      # uses for its WHEN keys (Tableau stores members as floats "0."/"1." but
      # writes CASE `WHEN 0`), so the control's option value actually matches the
      # Switch key — else the measure-switch renders blank (live-verified 2026-07-07).
      values = (p['members'] || []).map { |m| canonical_switch_value(m) }
      # Tableau list parameters often store integer-coded members (1..13) whose
      # human meaning lives in the parameter's value ALIASES (1→"TCV", 3→"ACV").
      # parse-twb-layout captures these in column_aliases keyed by the param
      # caption. Map each member value to its alias label so the segmented
      # control shows "TCV"/"ACV" instead of raw "1"/"3" — the selection VALUE
      # stays the code (what the translated Switch([ctl-param-…], "1", …)
      # compares against), only the display label changes. Without this the
      # measure-switcher renders as a row of meaningless numbers (enterprise).
      alias_pairs = (meta['column_aliases'] || {})[cap] ||
                    (meta['column_aliases'] || {})[p['name'].to_s.gsub(/^\[|\]$/, '')]
      labels = []
      if alias_pairs && !alias_pairs.empty?
        amap = alias_pairs.each_with_object({}) { |a, h| h[canonical_switch_value(a['key'])] = a['value'] }
        labels = values.map { |v| amap[v.to_s] || v.to_s }
        labels = [] if labels == values.map(&:to_s) # all unmapped → omit (no value-add)
      end
      spec['source'] = {
        'kind' => 'manual', 'valueType' => 'text',
        'values' => values, 'labels' => labels
      }
      # A Tableau parameter is ALWAYS single-valued. Sigma defaults a `list`
      # control to selectionMode:"multiple", which (a) drops the scalar default
      # `value` on readback and (b) makes the translated Switch/If measure-picker
      # compile to type "error" — a scalar case-compare against a multi-select
      # ARRAY. Pin single so the scalar default applies and the Switch resolves.
      # (Verified live 2026-07-05: without this the picker ships dead. The
      # OpenAPI enum says multiple-only — live behavior wins; do not "fix".
      # segmented is inherently single: no selectionMode in its schema.)
      spec['selectionMode'] = 'single' if spec['controlType'] == 'list'
      # Canonicalise so the default matches a control option value (0.→0).
      spec['value'] = canonical_switch_value(p['default_value'])
    elsif p['param_domain'] == 'range' && %w[integer real].include?(p['datatype'])
      # Numeric range parameter → Sigma `number-range` control (discovered by
      # gap-scout 2026-05-20, beads-sigma-ebw). Two-handle slider; the single-
      # value Tableau parameter is rendered as a range with handles initially
      # collapsed to the default. Bounds are the schema's flat min/max (the old
      # mode:'between' + values:[…] pair was out-of-schema and never
      # round-tripped on readback).
      spec['controlType'] = 'number-range'
      min = p['min'] ? (p['datatype'] == 'real' ? p['min'].to_f : p['min'].to_i) : nil
      max = p['max'] ? (p['datatype'] == 'real' ? p['max'].to_f : p['max'].to_i) : nil
      spec['min'] = min if min
      spec['max'] = max if max
      spec['includeNulls'] = 'when-no-value-is-selected'
      warnings << "parameter '#{cap}' is a numeric range — emitted as number-range control (Sigma 2-handle slider; Tableau's single-handle UX needs manual post-publish tweak)"
    elsif p['param_domain'] == 'range' && %w[date datetime].include?(p['datatype'])
      spec['controlType'] = 'date-range'
      spec['mode'] = 'between'
      spec['includeNulls'] = 'when-no-value-is-selected'
    elsif p['datatype'] == 'boolean'
      # Boolean parameter → Sigma switch (on/off toggle). Default from the raw
      # value. mode is REQUIRED on switch (True/False vs True/All).
      spec['controlType'] = 'switch'
      spec['mode']  = 'True/False'
      spec['value'] = %w[true 1].include?(p['default_value'].to_s.downcase.strip)
    elsif %w[date datetime].include?(p['datatype'])
      # Single-value date parameter (not a range) → Sigma `date` control.
      # mode is REQUIRED on date (=|>=|<=).
      spec['controlType'] = 'date'
      spec['mode']  = '='
      spec['value'] = p['default_value']
      spec['includeNulls'] = 'when-no-value-is-selected'
    elsif %w[integer real].include?(p['datatype'])
      # Single-value numeric parameter (not a range) → Sigma `number` control.
      spec['controlType'] = 'number'
      spec['mode']  = '='
      spec['value'] = p['datatype'] == 'real' ? p['default_value'].to_f : p['default_value'].to_i
      spec['includeNulls'] = 'when-no-value-is-selected'
    else
      # Generic fallback — text input. mode is REQUIRED on text.
      spec['controlType'] = 'text'
      spec['mode']  = 'equals'
      spec['value'] = p['default_value']
      spec['includeNulls'] = 'when-no-value-is-selected'
    end
    # TASK C (#259): data-scoping wiring. If this parameter drives a boolean
    # filter calc "[Col] = [Param]" whose [Col] resolves to a master column,
    # give the control a real FILTER TARGET on that column so it actually scopes
    # data (turns needs-wiring / inert-formula → emitted+filters). Only EQUALITY
    # is auto-wired — an inclusion filter can't express a directional ">"/"<", so
    # those (and multi-param period engines) are SURFACED with their candidate
    # column(s) for the operator to finish, never silently mis-wired.
    pft = param_filter_targets(cap, calc_formula_by_caption, mmap,
                               meta['columns_by_guid'] || {}, param_name: p['name'])
    filter_targets = []
    pft['clean'].select { |c| c['op'] == '=' }.each do |c|
      ts, = control_targets.call(c['col'], { 'id' => c['column_id'] })
      filter_targets.concat(ts)
    end
    filter_targets.uniq! { |t| [t.dig('source', 'elementId'), t['columnId']] }
    wired_cols = pft['clean'].select { |c| c['op'] == '=' }.map { |c| c['col'] }.uniq

    if filter_targets.any?
      spec['filters'] = filter_targets
      warnings << "parameter '#{cap}' data-scopes #{wired_cols.join(', ')} via a boolean filter calc " \
                  "→ wired control [#{spec['controlId']}] to filter #{filter_targets.size} element target(s)"
    end

    if filter_targets.any?
      status = 'emitted'
      mechanism = unreferenced_param ? 'filters' : 'formula+filters'
      signal = "tableau parameter '#{cap}' data-scopes #{wired_cols.join(', ')} (boolean filter calc → filter target)"
    elsif unreferenced_param
      status = 'needs-wiring'
      mechanism = 'formula'
      # Enrich the surfaced record with the candidate column(s) the param's calcs
      # reference (always-correct, low-risk) instead of a generic "wire it".
      cands = pft['candidates']
      signal = if cands.any?
                 "tableau parameter '#{cap}' (NOT calc-referenced; its filter calc scopes " \
                 "#{cands.join(', ')} — wire the control to filter that column)"
               else
                 "tableau parameter '#{cap}' (NOT calc-referenced — emitted for coverage; wire its filter target)"
               end
    else
      status = 'emitted'
      mechanism = 'formula'
      signal = "tableau parameter '#{cap}' (referenced by worksheet calcs)"
    end

    param_controls << spec
    # Record the consumer set so the coverage lint knows the mechanism.
    rec = {
      'controlId' => spec['controlId'], 'name' => cap, 'mechanism' => mechanism,
      'status' => status,
      'source_signal' => signal,
      # Translated calcs reference the control by its CONTROL ID (line ~541's
      # "[ctl-param-<slug>]" form), not by caption — match what the lint's
      # formula-ref reach walk will actually see.
      'intended' => elements.select { |e|
        (e['columns'] || []).any? { |c| c['formula'].to_s.include?("[#{spec['controlId']}]") }
      }.map { |e| { 'element_id' => e['id'], 'name' => e['name'] } }
    }
    rec['targets'] = filter_targets if filter_targets.any?
    rec['candidate_columns'] = pft['candidates'] if !filter_targets.any? && pft['candidates'].any?
    control_scope_records << rec
  end
end

# ---- Param measure-picker controls (n4pi.10) ------------------------------
# Emit a single-select segmented control under the EXACT controlId the converter
# baked into each param-switch's Switch formula (e.g. ctl-parameter-17), for every
# picker actually wired onto a tile above. Values = the case match literals; the
# control's display name is the parameter's caption when known. Not gated on
# --auto-controls: the picker wiring already happened during chart building, and
# the Switch tile measure is inert without its control.
$param_switches.each do |sw|
  next unless $param_switch_used.include?(sw['control_id'])
  next if param_controls.any? { |c| c['controlId'] == sw['control_id'] }
  values = sw['cases'].map { |c| c['when'].to_s }
  next if values.empty?
  pcap = (meta['columns_by_guid'] || {}).dig(sw['param_name'], 'caption') || sw['param_name'] || sw['name']
  param_controls << {
    'id'          => "el-#{sw['control_id']}",
    'kind'        => 'control',
    'controlId'   => sw['control_id'],
    'name'        => pcap,
    # E1: a measure-picker often renders as a dropdown (Tableau 'compact'); honor
    # its display mode, else segmented (button row).
    'controlType' => sigma_control_type(control_display_for(layout, pcap, norm_cap)),
    'source'      => { 'kind' => 'manual', 'valueType' => 'text', 'values' => values, 'labels' => values },
    # Measure-pickers are single-valued (see the param-control path above): a
    # `list` control defaults to multiple, which drops the scalar `value` and
    # errors the Switch (scalar vs array). Pin single. Verified live 2026-07-05.
    # (No includeNulls — not in the list/segmented schema.)
    'selectionMode' => 'single',
    'value'       => values.first
  }
  control_scope_records << {
    'controlId' => sw['control_id'], 'name' => pcap, 'mechanism' => 'formula',
    'source_signal' => "tableau parameter measure-picker '#{sw['name']}' → control-driven Switch",
    'intended' => elements.select { |e|
      (e['columns'] || []).any? { |c| c['formula'].to_s.include?("[#{sw['control_id']}]") }
    }.map { |e| { 'element_id' => e['id'], 'name' => e['name'] } }
  }
  warnings << "param measure-picker '#{sw['name']}' → segmented control [#{sw['control_id']}] " \
              "with #{values.size} option(s): #{values.join(' / ')}"
end

# ---- Auto-generated controls from shared-view filters (--auto-controls) ----
# PR-18: a workbook whose quick filters live as dashboard filter ZONES (not a
# <shared-view>) never reaches this emitter — `shared_filters` is empty and the
# INTEGER-coded dimension control is SILENTLY DROPPED (Twin C hand-authored it +
# its Text() helper). Promote ONLY integer-dim zone filters (resolved from their
# worksheet filter) into the emitter list so they auto-emit AND auto-decode.
# Gated strictly on integer_dim → every non-integer-dim workbook is untouched
# (byte-identical); string/date zone filters keep their current behavior.
promoted_int_dim_filters = []
unless opts[:no_auto_controls]
  seen_caps = (meta['shared_filters'] || []).map { |f| norm_cap.call(f['column_caption']) }
  ws_filters = (meta['worksheets'] || {}).values.flat_map { |w| w['filters'] || [] }
  (layout || []).each do |d|
    (d['zones'] || []).each do |z|
      next unless z['kind'] == 'filter'
      zc = z['filter_column_caption']
      next if zc.nil? || seen_caps.include?(norm_cap.call(zc))
      wf = ws_filters.find { |f| norm_cap.call(f['column_caption']) == norm_cap.call(zc) && f['integer_dim'] }
      next unless wf
      seen_caps << norm_cap.call(zc)
      promoted_int_dim_filters << wf
      warnings << "integer-coded dimension quick filter '#{zc}' is a dashboard filter ZONE (no <shared-view>) — " \
                  'promoting it to an auto-control so it is not silently dropped, and auto-decoding it (PR-18)'
    end
  end
end
auto_controls = []
unless opts[:no_auto_controls]   # default-on: never miss a .twb parameter/filter
  ((meta['shared_filters'] || []) + promoted_int_dim_filters).each_with_index do |f, i|
    next if f['is_action']
    cap = f['column_caption']
    if cap.nil?
      warnings << "shared filter ##{i} has no resolvable column_caption (raw_param=#{f['raw_param']}) — skipping auto-control"
      next
    end
    # D6/P0.5: a SHARED native top-N quick filter has no member list to seed a
    # control from, and its data effect (rank + N + direction) cannot ride a
    # list control. Name every parsed fact loudly — the old path mislabeled it
    # via the generic condition warning with N and direction dropped.
    if (tn = f['topn'])
      slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
      n_desc = tn['n'] || tn['count_param'] || '?'
      warnings << "shared quick filter '#{cap}' is a native Tableau #{tn['end'] || 'top'}-N " \
                  "(N=#{n_desc}, direction=#{tn['direction'] || 'DESC'}#{tn['units'] ? ", units=#{tn['units']}" : ''}) " \
                  "ranked by: #{tn['order_expr'].to_s[0..100]} — auto-control NOT emitted; wire the per-tile " \
                  'top-N (kind:top-n element filter / rank helper + number control) by hand — needs-wiring'
      control_scope_records << {
        'controlId' => "ctl-#{slug}", 'name' => cap.strip, 'mechanism' => 'filters',
        'source_signal' => "tableau shared top-N quick filter '#{cap}' (#{tn['end'] || 'top'} #{n_desc} by #{tn['order_expr'].to_s[0..80]})",
        'status' => 'needs-wiring'
      }
      next
    end
    m = map_column(cap, mmap)
    if m.nil?
      # Calc-bound filter that's ALREADY materialized on the master under its
      # internal name (bead: calc-bound-filter wiring / #259) — match by the
      # calc's identity, not its caption, and wire it like any quick-filter
      # instead of falsely flagging needs-materialization. (The plan-hierarchy
      # miss: a hierarchy-level filter whose Calculation_NNN column exists.)
      m = materialized_calc_column(cap, meta['columns_by_guid'] || {}, mmap, norm_cap)
      warnings << "quick filter '#{cap}' binds to a calculated field that is ALREADY materialized on the master (matched by calc identity) — wiring it" if m
    end
    if m.nil?
      # No master-map regex matched. If the caption names a CALCULATED field,
      # that's expected — a calc dim ("Team Bucket", "Tier") has no raw column
      # and must be materialized on the master before a control can target it.
      # Don't drop it silently: record a needs-materialization entry and surface
      # the calc's translated Sigma formula so the agent adds the column + a
      # master-columns.json regex, then re-runs.
      if (tab_formula = calc_formula_by_caption[cap.to_s.strip])
        sigma_formula = (translate_dim_calc(tab_formula, mmap, meta['columns_by_guid'] || {}) rescue nil)
        slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
        control_scope_records << {
          'controlId' => "ctl-#{slug}", 'name' => cap.strip, 'mechanism' => 'filters',
          'source_signal' => "tableau shared-view quick filter '#{cap}' (bound to a calculated field)",
          'status' => 'needs-materialization',
          'tableau_formula' => tab_formula,
          'sigma_formula' => sigma_formula
        }
        warnings << "shared filter on '#{cap}' binds to a CALCULATED field, not a raw column — " \
                    'materialize it on the master, then add a master-columns.json regex so the control binds. ' \
                    "Tableau: #{tab_formula}" +
                    (sigma_formula ? " → Sigma: #{sigma_formula}" : ' (auto-translation unavailable — translate by hand)')
      elsif f['is_datasource_filter']
        # #483: an always-on DATA-SOURCE filter whose column is not a charted
        # dimension (e.g. an `active` flag) has no master-map entry — but it is
        # NOT optional. Record needs-master-default (a breadcrumb in
        # control-scope.json / the coverage ledger) instead of a bare warning, so
        # the operator applies it as a workbook-wide default filter on the master
        # and the datasource-filter gate (assert-phase6-ran) sees it was surfaced
        # rather than silently dropped (which silently over-reports every aggregate).
        slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
        control_scope_records << {
          'controlId' => "ctl-#{slug}", 'name' => cap.strip, 'mechanism' => 'filters',
          'source_signal' => "tableau DATASOURCE-level filter '#{cap}' (always-on; ui-domain=#{f['ui_domain'].inspect}; not a charted dimension)",
          'status' => 'needs-master-default', 'datasource_filter' => true,
          'is_active_flag' => (f['is_active_flag'] == true), 'members' => Array(f['members'])
        }
        warnings << "DATASOURCE-level filter '#{cap}' (always-on) has no master-map entry — NOT optional: " \
                    'apply it as a workbook-wide default filter on the master element (or add a ' \
                    'master-columns.json regex + a control with its default set). Recorded needs-master-default; ' \
                    'the datasource-filter gate blocks GREEN until it is applied.'
      else
        warnings << "shared filter on '#{cap}' has no master-map entry — add a regex to master-columns.json"
      end
      next
    end
    slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
    # Intended-scope closure (see the control-targeting section above): targets
    # = the sourcing ROOTS of every chart this filter is meant to reach, not a
    # hardcoded master. A filter with NO reachable target never ships dead.
    targets, intended, unreachable, zone_dashes, action_ws = control_targets.call(cap, m)
    unreachable.each do |u|
      warnings << "control '#{cap}' cannot reach #{u['elements'].join(', ')} — their sourcing root " \
                  "'#{u['root']}' has no '#{cap}' column; wire manually or add the column to the helper"
    end
    if targets.empty?
      warnings << "DROPPED auto-control '#{cap}' — no chart root carries a matching column " \
                  '(a control that filters nothing never ships); see control-scope.json'
      control_scope_records << {
        'controlId' => "ctl-#{slug}", 'name' => cap.strip, 'mechanism' => 'filters',
        'source_signal' => "tableau shared-view quick filter '#{cap}'",
        'status' => 'dropped', 'intended' => intended, 'unreachable' => unreachable
      }
      next
    end
    spec = {
      'id'           => "el-ctl-#{slug}",
      'kind'         => 'control',
      'controlId'    => "ctl-#{slug}",
      'name'         => cap.strip
    }
    # Quick-filter zones apply per-dashboard: place the control only on the
    # dashboard pages whose zone tree shows it (page-per-dashboard mode);
    # empty = no zone info → shared-view default (every page).
    spec['_scope_dashboards'] = zone_dashes
    control_scope_records << {
      'controlId' => spec['controlId'], 'name' => cap.strip, 'mechanism' => 'filters',
      'source_signal' => "tableau shared-view quick filter '#{cap}'" +
                         (zone_dashes.any? ? " (zones on: #{zone_dashes.join(', ')})" : ' (no zone parsed — shared-view default: all dashboards)') +
                         (action_ws.any? ? "; [Action (#{cap.to_s.strip})] scoped to: #{action_ws.join(', ')}" : ''),
      'intended' => intended, 'targets' => targets,
      'zone_dashboards' => zone_dashes, 'action_worksheets' => action_ws,
      'unreachable' => unreachable, 'status' => 'emitted'
    }
    case f['kind']
    when 'list', 'list+condition'
      # radiolist zones → segmented (single-select); everything else a
      # column-backed multi-select list. list+condition keeps the member list
      # control; the CONDITION itself is not a control — surface it.
      # D1/P0.1: an EXCLUDE-mode filter always emits a multi-select LIST in
      # mode:'exclude' seeded with the excluded members (segmented is a
      # single-pick include widget — wrong semantics), so the dashboard OPENS
      # with Tableau's hidden values hidden, not shown.
      disp = control_display_for(layout, cap, norm_cap)
      spec['controlType'] = disp == 'radiolist' && !f['exclude'] ? 'segmented' : 'list'
      if spec['controlType'] == 'list'
        spec['mode']          = f['exclude'] ? 'exclude' : 'include'
        spec['selectionMode'] = 'multiple'
        # include: default to all, user adjusts in UI. exclude: the selection
        # IS the excluded member set — shipping [] would show the hidden rows.
        spec['values']        = f['exclude'] ? (f['members'] || []) : []
      end
      spec['source'] = {
        'kind'     => 'source',
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }
      spec['filters'] = targets
      # #417 workaround: the Tableau filter EXCLUDES Null, but Sigma's
      # `showNullOption:false` is accepted by POST/PUT then SILENTLY DROPPED on
      # readback — it never suppresses the null option. The field-validated
      # alternative: filter nulls at the control's OPTION-SOURCE — a hidden
      # helper element sourcing the master with an IsNotNull(<col>) filter, and
      # the control's value list pointed at it. (Data-side exclusion still rides
      # the control's mode/values; only the OPTION LIST changes here.)
      if f['excludes_null'] && spec['controlType'] == 'list'
        opt_id = "opt-src-#{slug}"
        opt_val_col = "#{opt_id}-v"
        opt_nn_col  = "#{opt_id}-nn"
        data_elements << {
          'id' => opt_id, 'kind' => 'table', 'name' => "#{cap.strip} Options",
          'source' => { 'kind' => 'table', 'elementId' => opts[:master_id] },
          'columns' => [
            { 'id' => opt_val_col, 'name' => cap.strip, 'formula' => "[Master/#{m['name']}]" },
            { 'id' => opt_nn_col, 'name' => "#{cap.strip} Not Null",
              'formula' => "IsNotNull([Master/#{m['name']}])" }
          ],
          # every element filter needs an `id` — the spec API 400s
          # `filters[N].id: Invalid string: undefined` without one (field report)
          'filters' => [{ 'id' => "flt-#{opt_id}-0", 'columnId' => opt_nn_col,
                          'kind' => 'list', 'mode' => 'include',
                          'selectionMode' => 'multiple', 'values' => [true] }],
          'visibleAsSource' => false
        }
        spec['source'] = {
          'kind'     => 'source',
          'source'   => { 'kind' => 'table', 'elementId' => opt_id },
          'columnId' => opt_val_col
        }
        warnings << "quick filter '#{cap}' EXCLUDES Null — `showNullOption:false` is silently dropped by " \
                    "the spec API (#417), so the control's option list sources hidden helper " \
                    "'#{cap.strip} Options' with an IsNotNull filter at the option source (sanctioned workaround)"
      end
      if f['exclude']
        warnings << "quick filter '#{cap}' is EXCLUDE-mode → list control mode:exclude seeded with " \
                    "#{(f['members'] || []).size} excluded value(s): #{(f['members'] || []).join(', ')[0..80]}"
      end
      if f['kind'] == 'list+condition'
        warnings << "quick filter '#{cap}' carries a CONDITION beyond its member list " \
                    "(#{Array(f['condition_expressions']).join('; ')[0, 120]}) — the member control is emitted; " \
                    'apply the condition as an element filter or accept the wider domain'
      end
      # PR-18: integer-coded discrete-dimension DECODE routing. When this list/
      # segmented control filters an INTEGER column, a raw-column filter target is
      # accepted then SILENTLY stripped by Sigma (control-parity.md "list-control
      # targets on NUMERIC columns are silently stripped"). Route each target
      # through a Text() decode helper and bind the value-source to it — the exact
      # by-hand pattern Twin C's runs used (gen-wb-spec.rb). Never silently drop:
      # where the decode can't be auto-built, route a POSTPUBLISH note instead.
      if f['integer_dim'] && IntegerDim.decode_control_type?(spec['controlType'])
        dec = route_integer_dim_decode.call(targets, m, cap, slug)
        rec = control_scope_records.find { |r| r['controlId'] == spec['controlId'] }
        rec['integer_dim'] = true if rec
        if dec[:applied]
          # Bind the value-source (option list) to the decoded column too — unless
          # the null-option workaround already re-sourced it to a hidden helper.
          opt_sourced = f['excludes_null'] &&
                        spec.dig('source', 'source', 'elementId').to_s.start_with?('opt-src-')
          if dec[:source] && !opt_sourced
            spec['source'] = { 'kind' => 'source',
                               'source' => { 'kind' => 'table', 'elementId' => dec[:source][:elementId] },
                               'columnId' => dec[:source][:columnId] }
          elsif opt_sourced
            warnings << "quick filter '#{cap}' both EXCLUDES Null and targets an INTEGER dimension — the data " \
                        'filter is decoded via Text(), but confirm the null-option suppression in the Sigma UI'
          end
          rec['decode'] = { 'status' => (dec[:manual].any? ? 'partial-manual' : 'auto-decoded'),
                            'helpers' => dec[:helpers].uniq } if rec
          warnings << "quick filter '#{cap}' targets an INTEGER column used as a discrete dimension — " \
                      "auto-decoded via Text() helper column(s) #{dec[:helpers].uniq.join(', ')} so the list " \
                      'control filters STRING values (a raw numeric list-filter target is silently stripped by Sigma)'
        end
        if dec[:manual].any?
          (rec['decode'] ||= {})['status'] ||= 'manual-required' if rec
          (rec['decode'] ||= {})['manual'] = dec[:manual] if rec
          $integer_dim_manual ||= []
          $integer_dim_manual << { 'controlId' => spec['controlId'], 'name' => cap.strip,
                                   'column' => cap.strip, 'notes' => dec[:manual] }
          dec[:manual].each do |why|
            warnings << "quick filter '#{cap}' targets an INTEGER dimension but the decode could not be " \
                        "auto-built (#{why}) — routed to POSTPUBLISH_GUIDE; add the Text() decode by hand. " \
                        'NEVER ship the raw numeric filter (Sigma silently strips it).'
          end
        end
      end
    when 'relative-date'
      # Tableau relative-date → ROLLING Sigma date-range control (same rolling
      # mode vocabulary as an element filter; shapes verified in sigma-workbooks
      # reference/specification/controls.md, live 2026-06-15):
      #   "this <period>"  → mode:current unit
      #   "last N <period>"→ mode:last value:N unit includeToday
      #   "next N <period>"→ mode:next value:N unit includeToday
      # Only shifted/spanning windows fall back to frozen mode:between. This
      # replaces freezing every offset window to static dates (bead z135).
      spec['controlType'] = 'date-range'
      period = (f['period_type'] || 'year').downcase
      spec['filters'] = targets
      fields, kind = relative_date_filter_fields(period, f['first_period'], f['last_period'])
      if fields.nil?
        # Nothing Sigma can express — leave the picker open rather than emit an invalid mode.
        spec['mode'] = 'between'
        warnings << "shared filter '#{cap}' relative-date (period=#{period}, window #{f['first_period']}..#{f['last_period']}) — no Sigma mode fits; emitted an empty date-range picker, set it by hand"
      else
        spec.merge!(fields)
        case kind
        when :current
          warnings << "shared filter '#{cap}' relative-date 'this #{period}' → date-range control mode:current unit:#{fields['unit']} (rolls automatically; no frozen dates)"
        when :last
          warnings << "shared filter '#{cap}' relative-date → date-range control mode:last value:#{fields['value']} unit:#{fields['unit']} includeToday:#{fields['includeToday']} (ROLLS — no frozen dates)"
        when :next
          warnings << "shared filter '#{cap}' relative-date → date-range control mode:next value:#{fields['value']} unit:#{fields['unit']} includeToday:#{fields['includeToday']} (rolls)"
        when :frozen
          warnings << "shared filter '#{cap}' relative-date window #{f['first_period']}..#{f['last_period']} #{period}s is shifted/spanning → mode:between (#{fields['startDate'][0..9]}..#{fields['endDate'][0..9]}); FROZEN — re-run to refresh"
        end
      end
    when 'number-range'
      if %w[date datetime].include?(f['datatype'].to_s)
        # Quantitative filter on a DATE column: a range-slider is the wrong
        # widget (renders epoch numbers) — date-range with the parsed bounds.
        # Bounds go through iso_utc_datestamp: a bare-date default is accepted
        # then SILENTLY DROPPED by the spec API (#415); only full ISO-8601 UTC
        # timestamps round-trip.
        spec['controlType'] = 'date-range'
        spec['mode'] = 'between'
        spec['startDate'] = iso_utc_datestamp(f['min']) if f['min']
        spec['endDate']   = iso_utc_datestamp(f['max'], end_of_day: true) if f['max']
        if (f['min'] && spec['startDate'] != f['min']) || (f['max'] && spec['endDate'] != f['max'])
          warnings << "shared filter '#{cap}' date-range default normalized to ISO-8601 UTC " \
                      "(#{spec['startDate']}..#{spec['endDate']}) — bare dates are accepted then " \
                      'silently dropped by the spec API (#415); only Z-suffixed timestamps persist'
        end
      elsif f['min'] && f['max']
        spec['controlType'] = 'range-slider'
        # Bounds are load-bearing: a bare range-slider renders 0..0 and filters
        # everything out. low/high = the slider track, min/max = selected band.
        spec['low']  = f['min']
        spec['high'] = f['max']
        spec['min']  = f['min']
        spec['max']  = f['max']
      else
        # single-bound quantitative filter (at-least / at-most) → one-handle slider
        spec['controlType'] = 'slider'
        spec['mode']  = f['min'] ? '>=' : '<='
        spec['value'] = f['min'] || f['max']
      end
      spec['includeNulls'] = 'when-no-value-is-selected'
      spec['filters'] = targets
    when 'wildcard'
      # D5/P0.6: wildcard card → Sigma TEXT control (modes contains/starts-with/
      # ends-with + negations, per the live control spec) targeting the column.
      # Unparseable pattern → loud STAYS-MANUAL (never a silent select-all).
      if f['wildcard'].nil?
        rec = control_scope_records.reverse.find { |r| r['controlId'] == spec['controlId'] }
        rec['status'] = 'needs-wiring' if rec
        warnings << "shared WILDCARD filter '#{cap}' STAYS-MANUAL — pattern expression did not parse " \
                    "(#{f['wildcard_unparsed'].to_s[0..120]}); control NOT emitted, NOT treated as 'All'"
        next
      end
      spec['controlType'] = 'text'
      spec['mode']  = f['wildcard']['mode']
      spec['value'] = f['wildcard']['pattern']
      spec['includeNulls'] = 'when-no-value-is-selected'
      spec['filters'] = targets
      warnings << "shared WILDCARD filter '#{cap}' → Sigma text control mode:#{f['wildcard']['mode']} " \
                  "value:#{f['wildcard']['pattern'].inspect} targeting #{targets.size} root(s)"
    else
      # Unknown filter kind: NEVER append a controlType-less spec (controlType
      # is REQUIRED on every schema branch — the old fallthrough shipped an
      # invalid element that killed the whole POST). Downgrade the scope record
      # just pushed above and skip emission.
      rec = control_scope_records.reverse.find { |r| r['controlId'] == spec['controlId'] }
      rec['status'] = 'needs-wiring' if rec
      warnings << "shared filter '#{cap}' kind=#{f['kind'].inspect} has no controlType mapping — " \
                  'NOT emitted (needs-wiring in controls-coverage); wire via --controls'
      next
    end
    auto_controls << spec
  end
end

# ---- Filter controls ----
# Caller supplies the column targets explicitly via --controls. We don't try
# to infer the column from filter zone metadata because the Tableau filter
# shelf doesn't reliably tell us which dimension it filters in this XML.
if opts[:controls]
  controls = JSON.parse(File.read(opts[:controls]))
  controls.each_with_index do |c, i|
    # Explicit controls carry no per-dashboard scope signal — intended scope is
    # EVERY chart, so the target list is every sourcing root in the workbook
    # (master + DM-direct/grain-helper roots that carry a matching column),
    # not the master alone.
    col_name = c['column_name'] ||
               (mmap.values.find { |v| v['id'] == c['column'] } || {})['name'] ||
               c['name']
    mcol_entry = { 'id' => c['column'] }
    targets, intended, unreachable, _zone_dashes, ctl_action_ws = control_targets.call(col_name, mcol_entry)
    targets = [{ 'source' => { 'kind' => 'table', 'elementId' => opts[:master_id] },
                 'columnId' => c['column'] }] if targets.empty?
    unreachable.each do |u|
      warnings << "control '#{c['name']}' cannot reach #{u['elements'].join(', ')} — their sourcing " \
                  "root '#{u['root']}' has no '#{col_name}' column; wire manually"
    end
    spec = {
      'id'          => "el-ctl-#{c['name'] ? c['name'].downcase.gsub(/\W+/, '-') : "f#{i}"}",
      'kind'        => 'control',
      'controlId'   => "ctl-#{c['name'] ? c['name'].downcase.gsub(/\W+/, '-') : "f#{i}"}",
      'name'        => c['name'] || "Filter #{i + 1}",
      'controlType' => c['type'] || 'list',
      'includeNulls' => 'when-no-value-is-selected',
      'filters' => targets
    }
    control_scope_records << {
      'controlId' => spec['controlId'], 'name' => spec['name'], 'mechanism' => 'filters',
      'source_signal' => 'explicit --controls entry (no per-dashboard scope signal: all charts intended)',
      'intended' => intended, 'targets' => targets,
      'action_worksheets' => ctl_action_ws,
      'unreachable' => unreachable, 'status' => 'emitted'
    }
    case spec['controlType']
    when 'list'
      spec['mode'] = c['mode'] || 'include'
      spec['selectionMode'] = c['selectionMode'] || 'multiple'
      spec['values'] = c['values'] || []
      spec['source'] = {
        'kind'     => 'source',
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => c['column']
      }
    when 'date-range'
      spec['mode'] = c['mode'] || 'between'
      if c['default']
        d = c['default']
        # #415: bare-date defaults are accepted then silently dropped by the
        # spec API — normalize to the persisting ISO-8601 UTC timestamp form.
        # Relative {op,unit,value} hashes (custom mode) pass through untouched.
        spec['startDate'] = d['startDate'].is_a?(String) ? iso_utc_datestamp(d['startDate']) : d['startDate'] if d['startDate']
        spec['endDate']   = d['endDate'].is_a?(String) ? iso_utc_datestamp(d['endDate'], end_of_day: true) : d['endDate'] if d['endDate']
        spec['unit']      = d['unit']      if d['unit']
        spec['mode']      = d['mode']      if d['mode']
        if spec['startDate'] != d['startDate'] || spec['endDate'] != d['endDate']
          warnings << "control '#{spec['name']}' date-range default normalized to ISO-8601 UTC — bare dates " \
                      'are accepted then silently dropped by the spec API (#415); only Z-suffixed timestamps persist'
        end
      end
    when 'segmented'
      spec['source'] = c['source'] || {
        'kind' => 'manual', 'valueType' => 'text', 'values' => c['values'] || [], 'labels' => []
      }
      spec['value'] = c['value']
    # v5.0: every remaining schema type gets its REQUIRED fields — the old
    # passthrough shipped switch/checkbox/text/number/date/slider without
    # `mode` (required on each) and they 400'd the POST.
    when 'switch', 'checkbox'
      spec['mode']  = c['mode'] || 'True/False'
      spec['value'] = c['value'] unless c['value'].nil?
    when 'text'
      spec['mode']  = c['mode'] || 'equals'
      spec['value'] = c['value'] if c['value']
    when 'text-area'
      spec['value'] = c['value'] if c['value']
    when 'number'
      spec['mode']  = c['mode'] || '='
      spec['value'] = c['value'] if c['value']
    when 'date'
      spec['mode']  = c['mode'] || '='
      spec['value'] = c['value'] if c['value']
    when 'number-range'
      spec['min'] = c['min'] if c['min']
      spec['max'] = c['max'] if c['max']
    when 'slider'
      spec['mode']  = c['mode'] || '<='
      %w[low high step value].each { |k| spec[k] = c[k] if c[k] }
    when 'range-slider'
      %w[low high step min max].each { |k| spec[k] = c[k] if c[k] }
    when 'top-n'
      # no extra spec fields exist in the OpenAPI — wiring (filters) only
    when 'hierarchy'
      spec['mode']   = c['mode'] || 'include'
      spec['values'] = c['values'] || []
      spec['source'] = c['source'] if c['source']
    end
    # includeNulls exists on only 7 types — strip it where out-of-schema.
    unless %w[text number number-range date date-range slider range-slider].include?(spec['controlType'])
      spec.delete('includeNulls')
    end
    extras << spec
  end
end

all_extras = extras + param_controls + auto_controls

# ---- Control-coverage reconciliation — "never miss a .twb parameter/filter" ----
# Enumerate EVERY extracted parameter + quick-filter and confirm each is
# accounted for (emitted / needs-wiring / needs-materialization / dropped-with-
# reason). Anything with no control and no scope record is UNACCOUNTED — the
# silent-miss the mandate forbids. Writes <meta>-controls-coverage.json + a loud
# summary warning; a non-zero unaccounted count is a signal for the gate/agent.
begin
  seen_f = {}
  expected = []
  (meta['parameters'] || []).each { |p| c = p['caption'].to_s.strip; expected << ['parameter', c] unless c.empty? }
  (meta['shared_filters'] || []).each do |f|
    next if f['is_action']
    c = f['column_caption'].to_s.strip
    next if c.empty? || seen_f[c.downcase]
    seen_f[c.downcase] = true
    expected << ['filter', c]
  end
  accounted = {}
  control_scope_records.each { |r| accounted[r['name'].to_s.strip.downcase] = (r['status'] || 'emitted') }
  (param_controls + auto_controls).each { |c| accounted[c['name'].to_s.strip.downcase] ||= 'emitted' }
  rows = expected.map { |kind, name| { 'kind' => kind, 'name' => name, 'status' => (accounted[name.downcase] || 'UNACCOUNTED') } }
  missing = rows.select { |r| r['status'] == 'UNACCOUNTED' }
  cov = {
    'params_total'  => (meta['parameters'] || []).size,
    'filters_total' => seen_f.size,
    'emitted'       => rows.count { |r| r['status'] == 'emitted' },
    'needs_wiring'  => rows.count { |r| r['status'].to_s.include?('needs') },
    'dropped'       => rows.count { |r| r['status'] == 'dropped' },
    'unaccounted'   => missing.map { |r| "#{r['kind']}:#{r['name']}" },
    'detail'        => rows
  }
  if opts[:meta]
    cp = opts[:meta].to_s.sub(/(-meta)?\.json$/, '-controls-coverage.json')
    File.write(cp, JSON.pretty_generate(cov)) rescue nil
  end
  warnings << "CONTROL COVERAGE: #{cov['params_total']} param(s) + #{cov['filters_total']} filter(s) → " \
              "#{cov['emitted']} emitted, #{cov['needs_wiring']} needs-wiring, #{cov['dropped']} dropped" +
              (missing.any? ? "; #{missing.size} UNACCOUNTED (#{missing.map { |r| r['name'] }.join(', ')}) — must be 0" : '; 0 unaccounted ✓')
rescue => e
  warnings << "control-coverage reconciliation error: #{e.message}"
end

# ---- v5.1 leaked-ref guard (fail-closed) ------------------------------------
# A column ref whose inner name contains formula punctuation or a Tableau pill
# qualifier ([Master/-WINDOW_MAX(…)], [Master/Rank N (copy)_…:ok:9]) is ALWAYS
# leaked formula text / an internal sort pill — it can never resolve and
# hard-fails the POST ("Dependency not found"). Never ship one: drop the
# column loudly (round-4 D3/D4 class, the exit-4 trigger).
elements.each do |el|
  bad = (el['columns'] || []).select do |c|
    c['formula'].to_s.scan(/\[[^\]\/]+\/([^\]]+)\]/).flatten.any? do |inner|
      # FUNCTION-CALL shapes and pill qualifiers only. Legit captions carry
      # parens too ('Revenue (current US$)', 'Cost (copy)_123' — real resolvable
      # DM columns in the corpus; review-caught: a blanket paren test dropped
      # them), so match aggregate/window CALLS, not punctuation. The match is
      # CASE-SENSITIVE: leaked twb formulas are canonically UPPERCASE, while
      # captions like 'Total (USD)' / 'Count (copy)' / 'Max (F)' are mixed
      # case — /i dropped all of those (v5.1.2 review-caught).
      inner =~ /\b(?:WINDOW_[A-Z]+|RUNNING_[A-Z]+|TOTAL|RANK[A-Z_]*|SUM|AVG|MIN|MAX|MEDIAN|COUNTD?|ZN|LOOKUP|INDEX)\s*\(/ ||
        # a NESTED bracket inside the inner name is always a leaked formula
        # ref — Tableau captions cannot legally contain [ or ] — and catches
        # lowercase author-typed leaks the case-sensitive branch would miss
        inner =~ /[\[\]]/ ||
        inner =~ /:(?:ok|qk)\b/
    end
  end
  next if bad.empty?
  bad.each do |c|
    el['columns'].delete(c)
    Array(el.dig('yAxis', 'columnIds')).delete(c['id'])
    Array(el['values']).delete(c['id'])
    # Clean every other structure that references the dropped id — a dangling
    # sort.by / conditionalFormats columnId fails the PUT just as hard.
    %w[rowsBy columnsBy].each do |ax|
      Array(el[ax]).each { |e2| e2.delete('sort') if e2.is_a?(Hash) && e2.dig('sort', 'by') == c['id'] }
      el[ax] = Array(el[ax]).reject { |e2| (e2.is_a?(Hash) ? e2['id'] : e2) == c['id'] } if el[ax]
    end
    Array(el['conditionalFormats']).each { |cf| Array(cf['columnIds']).delete(c['id']) }
    el['conditionalFormats'] = Array(el['conditionalFormats']).reject { |cf| Array(cf['columnIds']).empty? } if el['conditionalFormats']
    # chart-axis and table-grouping sorts can also point at the dropped id
    # (the top-N path sets them — v5.1.2 review-caught)
    el['xAxis'].delete('sort') if el['xAxis'].is_a?(Hash) && el.dig('xAxis', 'sort', 'by') == c['id']
    Array(el['groupings']).each do |g|
      next unless g.is_a?(Hash) && g['sort'].is_a?(Array)
      g['sort'] = g['sort'].reject { |s| s.is_a?(Hash) && s['columnId'] == c['id'] }
      g.delete('sort') if g['sort'].empty?
    end
    warnings << "FAIL-CLOSED '#{el['name']}': column '#{c['name']}' referenced leaked formula text/pill " \
                "(#{c['formula'].to_s[0, 90]}) — DROPPED (would hard-fail the POST); translate or re-author it"
  end
end

# ---- Multi-DS routing (v5.0) ------------------------------------------------
# Three rounds' #1 recurring gap, mechanized. multi-ds-plan.json (gap-scan)
# maps each worksheet to its owning federated datasource; every chart used to
# be hardwired to the ONE master (built from the dominant datasource), so
# outlier-datasource charts showed the wrong numbers and a WARN wall told a
# human to re-source them. Now: for each outlier worksheet whose element is
# MECHANICAL (source == the master, formulas plain [Master/…]), lazily emit a
# hidden sub-master per outlier datasource ("Master (<caption>)", DM-element
# placeholder resolved by the orchestrator like the grain helpers) and repoint
# the element + rewrite its formulas in lock-step. Charts needing window/LOD/
# two-stage helpers keep the WARN (v1 scope cut: the translators emit literal
# [Master/…] internally — threading a source through them is the blast-radius
# trap).
# Recursively gsub a string pattern across every String in a JSON-shaped
# structure IN PLACE. Structural (never a JSON-text splice), so captions
# containing quotes/backslashes can't corrupt anything.
def deep_gsub!(node, from, to)
  case node
  when Hash  then node.each { |k, v| node[k] = deep_gsub!(v, from, to) }
  when Array then node.map! { |v| deep_gsub!(v, from, to) }
  when String then node = node.gsub(from, to)
  end
  node
end

def route_multi_ds!(elements, data_elements, plan, master_id, warnings, controls: [], id2name: {}, cbg: {}, mmap: {})
  routed = {}
  return routed unless plan && plan['datasources'].is_a?(Array) && plan['datasources'].size > 1
  norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
  dominant = plan['datasources'].max_by { |d| (d['worksheets'] || []).size }
  ws_to_ds = {}
  plan['datasources'].each do |d|
    next if d == dominant
    (d['worksheets'] || []).each { |w| ws_to_ds[norm.call(w)] = d }
  end
  submasters = {} # ds caption → sub-master element (lazy)
  # v5.1.1: hidden helpers tagged with _worksheet (top-N prefilter sources)
  # ride the master DIRECTLY while their chart sources the helper — the chart
  # fails the mechanical guard below, so the HELPER must be routed in its
  # place (review-caught: the helper kept [Master/ refs + the wrong master on
  # outlier-datasource pivots → Dependency-not-found at POST).
  (elements + data_elements.select { |d| d['_worksheet'] }).each do |el|
    ds = ws_to_ds[norm.call(el['_worksheet'])]
    next unless ds
    # mechanical-only guard: source must be exactly the shared master
    next unless el['source'] == { 'kind' => 'table', 'elementId' => master_id }
    caption = ds['caption'].to_s
    # The caption rides inside Sigma formula refs ([Master (X)/Col]) — strip
    # the characters that would break the ref grammar ([ ] /) or read as
    # escapes. The PLACEHOLDER keeps the raw caption (the orchestrator's
    # resolver matches normalized, so punctuation is irrelevant there).
    safe_cap = caption.gsub(%r{[\[\]/"\\]}, ' ').squeeze(' ').strip
    sm = submasters[caption]
    if sm.nil?
      base_id = "submaster-#{norm.call(caption)[0, 24]}"
      # 24-char truncation can collide across long sibling captions — suffix
      # a counter so ids stay globally unique.
      sid = base_id
      n = 1
      while submasters.values.any? { |s| s['id'] == sid }
        n += 1
        sid = "#{base_id}-#{n}"
      end
      sm = submasters[caption] = {
        'id' => sid, 'kind' => 'table',
        'name' => "Master (#{safe_cap})", 'visibleAsSource' => false,
        'source' => { 'kind' => 'data-model', 'elementId' => "__DM_ELEMENT__:#{caption}" },
        'columns' => []
      }
    end
    # v5.4 DERIVED CALCS on the sub-master: a routed chart's [Master/<name>]
    # ref can name a Tableau CALC (not a physical column of the outlier
    # datasource) — the old blind passthrough emitted [<caption>/<calc name>],
    # a ref to a DM column that does not exist, and the POST hard-failed.
    # Resolve each ref against the workbook calc registry (columns_by_guid —
    # an entry with a formula IS a calc). Row-level/dim calcs become derived
    # COLUMNS on the sub-master (translated, source-relative refs); aggregated
    # calcs (ratio-of-sums) cannot live at row grain — their decomposition is
    # spliced into the CHART formulas at viz level and the base aggregates'
    # refs fall through to passthroughs. Untranslatable calcs get NO column
    # and a loud STAYS-MANUAL (the pre-POST ref gate names the broken ref) —
    # never a silently broken passthrough.
    nrmv = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
    calc_of = lambda do |cn|
      k = nrmv.call(cn)
      next nil if k.empty?
      hits = cbg.values.select do |v|
        v.is_a?(Hash) && !v['formula'].to_s.strip.empty? && nrmv.call(v['caption']) == k
      end
      hits.map { |v| v['formula'] }.uniq.size == 1 ? hits.first : nil
    end
    manual_calcs = []
    splice_strings = lambda do |node, wrap_re, bare, repl|
      case node
      when Hash   then node.each { |k, v| node[k] = splice_strings.call(v, wrap_re, bare, repl) }
      when Array  then node.map! { |v| splice_strings.call(v, wrap_re, bare, repl) }
      when String then node.gsub(wrap_re, repl).gsub(bare, repl)
      else node
      end
    end
    JSON.generate(el).scan(%r{\[Master/([^\]/]+)\]}).flatten.uniq.each do |cn|
      calc = calc_of.call(cn)
      next unless calc
      next if sm['columns'].any? { |c| c['name'] == cn }
      f = calc['formula']
      agg_t = translate_user_agg_formula(f, mmap, cbg)
      row_t = agg_t ? nil : (translate_row_level_calc(f, mmap, cbg) || translate_dim_calc(f, mmap, cbg))
      if agg_t
        agg_wrap = /(?:Sum|Avg|Min|Max|Median|CountDistinct|Count)\(\[Master\/#{Regexp.escape(cn)}\]\)/
        if data_elements.include?(el)
          # el is a row-grain HELPER (top-N prefilter source etc.) — an
          # aggregate cannot live as one of its base-grain columns. Drop the
          # calc's passthrough column, expose the decomposition's BASE columns
          # instead, and splice the aggregate into every CONSUMER formula that
          # wraps or references the dropped column (consumers reference the
          # helper by NAME, evaluated per viz cell — the correct grain).
          el['columns'] = (el['columns'] || []).reject do |c|
            c['name'] == cn && c['formula'].to_s.include?("[Master/#{cn}]")
          end
          agg_t.scan(%r{\[Master/([^\]/]+)\]}).flatten.uniq.each do |b|
            next if (el['columns'] || []).any? { |c| c['name'] == b }
            el['columns'] << { 'id' => "#{el['id']}-agg#{el['columns'].size}", 'name' => b,
                               'formula' => "[Master/#{b}]" }
          end
          agg_c = agg_t.gsub('[Master/', "[#{el['name']}/")
          wrap_c = /(?:Sum|Avg|Min|Max|Median|CountDistinct|Count)\(\[#{Regexp.escape(el['name'])}\/#{Regexp.escape(cn)}\]\)/
          elements.each do |cons|
            next unless cons.dig('source', 'elementId') == el['id']
            splice_strings.call(cons, wrap_c, "[#{el['name']}/#{cn}]", agg_c)
          end
          warnings << "NOTE multi-DS: '#{el['_worksheet']}' calc '#{cn}' is an aggregated calc — decomposed " \
                      "into its consumer chart formulas as #{agg_c[0, 110]} (helper exposes the base columns)"
        else
          # el is a CHART: splice the decomposition at viz level; its
          # [Master/…] base refs are prefix-rewritten with everything below.
          splice_strings.call(el, agg_wrap, "[Master/#{cn}]", agg_t)
          warnings << "NOTE multi-DS: '#{el['_worksheet']}' calc '#{cn}' is an aggregated calc — decomposed at " \
                      "viz level over sub-master columns: #{agg_t.gsub('[Master/', "[#{safe_cap}/")[0, 110]}"
        end
      elsif row_t
        sm['columns'] << { 'id' => "#{sm['id']}-c#{sm['columns'].size}", 'name' => cn,
                           'formula' => row_t.gsub('[Master/', "[#{safe_cap}/") }
        warnings << "NOTE multi-DS: '#{el['_worksheet']}' calc '#{cn}' emitted as a DERIVED column on " \
                    "sub-master '#{sm['name']}': #{sm['columns'].last['formula'][0, 110]}"
      else
        manual_calcs << cn
        warnings << "multi-DS STAYS-MANUAL: '#{el['_worksheet']}' references calc '#{cn}' on datasource " \
                    "'#{caption}' whose formula could not be auto-translated " \
                    "(#{f.to_s.gsub(/\s+/, ' ')[0, 90]}) — no sub-master column emitted; the pre-POST ref " \
                    'gate will name the broken ref; author it on the sub-master by hand (--master-col)'
      end
    end
    # Repoint + rewrite formulas in lock-step (structural, in place); collect
    # the referenced column names so the sub-master exposes exactly what its
    # charts consume (formulas [<caption>/<col>] — the orchestrator's
    # placeholder resolver rewrites the prefix when the live name differs).
    cols = JSON.generate(el).scan(%r{\[Master/([^\]/]+)\]}).flatten.uniq
    cols.each do |cn|
      next if sm['columns'].any? { |c| c['name'] == cn }
      next if manual_calcs.include?(cn) # loud above — never a broken passthrough
      sm['columns'] << { 'id' => "#{sm['id']}-c#{sm['columns'].size}", 'name' => cn,
                         'formula' => "[#{safe_cap}/#{cn}]" }
    end
    deep_gsub!(el, '[Master/', "[Master (#{safe_cap})/")
    el['source'] = { 'kind' => 'table', 'elementId' => sm['id'] }
    routed[el['_worksheet']] = caption
    warnings << "NOTE multi-DS: '#{el['_worksheet']}' auto-routed to datasource '#{caption}' " \
                "(sub-master #{sm['id']}, #{cols.size} column(s))"
  end
  # A filter on the master does NOT propagate to sub-master-sourced charts
  # (propagation follows the source chain). Retarget: every control targeting
  # a master column ALSO targets each sub-master that exposes the same column
  # name; sub-masters lacking it are named residue (the outlier datasource may
  # genuinely not carry the column — never guess).
  submasters.each_value do |sm|
    sm_cols = sm['columns'].each_with_object({}) { |c, h| h[c['name']] = c['id'] }
    controls.each do |ctl|
      next unless ctl['filters'].is_a?(Array)
      ctl['filters'].select { |t| t.dig('source', 'elementId') == master_id }.each do |t|
        cname = id2name[t['columnId']]
        next unless cname
        next if ctl['filters'].any? { |x| x.dig('source', 'elementId') == sm['id'] }
        if sm_cols[cname]
          ctl['filters'] << { 'source' => { 'kind' => 'table', 'elementId' => sm['id'] },
                              'columnId' => sm_cols[cname] }
        else
          warnings << "multi-DS: control '#{ctl['name']}' targets master column '#{cname}' which " \
                      "'#{sm['name']}' does not expose — routed charts on that datasource are NOT " \
                      'filtered by it (named residue; verify the outlier datasource carries the column)'
        end
      end
    end
  end
  data_elements.concat(submasters.values)
  routed
end

$ds_routed = {}
begin
  plan_path = File.join(opts[:tab], 'multi-ds-plan.json')
  plan = File.exist?(plan_path) ? (JSON.parse(File.read(plan_path)) rescue nil) : nil
  if ENV['SIGMA_MULTI_DS_ROUTING'] == 'off'
    warn 'multi-DS routing DISABLED (SIGMA_MULTI_DS_ROUTING=off) — outlier charts stay on the master + WARN wall.'
  elsif plan
    id2name = mmap.values.each_with_object({}) { |v, h| h[v['id']] = v['name'] if v['id'] && v['name'] }
    $ds_routed = route_multi_ds!(elements, data_elements, plan, opts[:master_id], warnings,
                                 controls: param_controls + auto_controls + extras, id2name: id2name,
                                 cbg: meta['columns_by_guid'] || {}, mmap: mmap)
  end
rescue => e
  warnings << "multi-DS routing error (charts left on the master + WARN wall): #{e.message}"
end
# routing tags on hidden helpers are internal — never emit them in the spec
data_elements.each { |e| e.delete('_worksheet') }

# v5.1: HIDDEN-TITLES sidecar. The source hides worksheet titles via the zone
# attr show-title='false' (parser: zone show_title) — three rounds leaked
# "Sheet 9"/"Bi assets" chrome because nothing carried the signal. The live
# API rejects name:{text, visibility:'hidden'} ("cannot mix"), and bare
# {visibility:'hidden'} breaks every name-keyed matcher upstream — so titles
# are hidden as the FINAL spec mutation in put-layout.rb, driven by this
# sidecar. kpi-chart excluded (its name IS the rendered KPI label).
begin
  st_by_ws = {}
  layout.each do |dash|
    (dash['zones'] || []).each do |z|
      st_by_ws[z['caption']] = z['show_title'] if z['kind'] == 'chart' && !z['caption'].to_s.empty?
    end
  end
  $hidden_title_ids = elements.select do |e|
    e['kind'] != 'kpi-chart' && st_by_ws.key?(e['_worksheet']) && st_by_ws[e['_worksheet']] == false
  end.map { |e| e['id'] }
  # namespaced duplicates (worksheet on a 2nd+ dashboard) get their own ids
  # appended by the page-per-dashboard emitter; the sidecar is WRITTEN after
  # the emitters run (review-caught: pre-namespace ids never matched the
  # copies, leaking title chrome on later pages).
  $hidden_title_ns_ids = []
  # Ownership marker for stale-sidecar cleanup: the workbook's .twb sha —
  # caption-derived element ids ('el-sheet-1') collide across workbooks, so a
  # bare id-overlap test could delete ANOTHER workbook's sidecar in a shared
  # directory (review-caught). Legacy array-shaped sidecars fall back to the
  # id-overlap heuristic.
  twb_p = File.join(opts[:tab], 'workbook-content.twb')
  $hidden_title_wb_sha = File.exist?(twb_p) ? Digest::SHA256.file(twb_p).hexdigest[0, 16] : nil
  ht_path = opts[:out].sub(/\.json$/, '-hidden-titles.json')
  own_ids = elements.map { |e| e['id'].to_s }
  Dir.glob(File.join(File.dirname(opts[:out]), '*-hidden-titles.json')).each do |stale|
    body = JSON.parse(File.read(stale)) rescue []
    owned =
      if stale == ht_path
        true
      elsif body.is_a?(Hash)
        # sha match is exact ownership; the id-overlap fallback covers the
        # SAME workbook whose twb changed between builds (or a null sha from
        # a missing .twb) — without it those sidecars re-hid titles forever
        # (review-caught). A cross-workbook slug collision deleting a shared
        # sidecar is the lesser failure (it regenerates on that build).
        ($hidden_title_wb_sha && body['workbook'] == $hidden_title_wb_sha) ||
          (Array(body['ids']).map(&:to_s) & own_ids).any?
      elsif body.is_a?(Array)
        (body.map(&:to_s) & own_ids).any? # legacy shape
      else
        false
      end
    next unless owned
    File.delete(stale)
    warn "removed stale #{stale}" unless stale == ht_path
  end
rescue => e
  warnings << "hidden-titles sidecar error (titles stay visible): #{e.message}"
end

# v5.0-P2: window-calc sidecar for the VDS oracle — enriched from the BUILT
# elements and written HERE (before the output modes strip the _worksheet
# tags the enrichment joins on). Always written: empty entries tell the
# oracle "no window calcs" vs "builder predates the sidecar".
begin
  enrich_window_calcs!($window_calc_records, elements, (plan rescue nil))
  wc_path = File.join(File.dirname(File.expand_path(opts[:out])), 'window-calcs.json')
  File.write(wc_path, JSON.pretty_generate({ 'version' => 1, 'entries' => $window_calc_records }))
  warn "wrote #{wc_path} (#{$window_calc_records.size} window-calc translation(s) for the VDS oracle)" if $window_calc_records.any?
rescue => e
  warnings << "window-calcs sidecar error (VDS oracle will report nothing-to-verify): #{e.message}"
end

# v5.4: EVERY generated element filter carries an 'id' — the API rejects
# filters without one, and in the field the failure surfaces as an opaque 400
# with a multi-hundred-line union dump. Belt-and-suspenders over the per-site
# ids so no construction site (present or future) can regress the contract.
# Control filter-TARGETS ({source:, columnId:} on control elements) are a
# different shape and are skipped (keyed by 'source').
stamp_filter_ids = lambda do |els_list|
  Array(els_list).each do |e|
    next unless e.is_a?(Hash) && e['filters'].is_a?(Array)
    e['filters'].each_with_index do |f, i|
      next unless f.is_a?(Hash) && !f.key?('source')
      f['id'] = "flt-#{e['id']}-#{i}" if f['id'].to_s.empty?
    end
  end
end
stamp_filter_ids.call(elements)
stamp_filter_ids.call(data_elements)
stamp_filter_ids.call(all_extras) if defined?(all_extras)

# v5.5 CHART PROVENANCE (field-caught wrong-view parity): element id → the
# Tableau WORKSHEET name that built it (unique per workbook — Tableau enforces
# it) + dashboard. Sigma tile DISPLAY names are the worksheet display_titles,
# which are NOT unique across dashboards: auto-parity-plan's display-name
# back-match double-mapped 5 views and dropped 5 on a 29-chart field workbook,
# and silently parity-checked tiles against the WRONG same-titled view. This
# map is the collision-free join auto-parity-plan.rb consumes FIRST (display-
# name matching stays only as a warned fallback for hand-added charts).
# Captured HERE while elements still carry _worksheet; the page-per-dashboard
# emitter adds its namespaced duplicate ids below; written to
# <tableau-dir>/chart-provenance.json after the emitters run.
$chart_provenance = {}
elements.each do |e|
  ws = e['_worksheet'].to_s
  next if ws.empty? || e['id'].to_s.empty?
  $chart_provenance[e['id'].to_s] ||= {
    'worksheet' => ws,
    'dashboard' => e['_dashboard'],
    'name'      => (e['name'].is_a?(String) ? e['name'] : nil)
  }.compact
end

# PR-12: formats-emitted.json — the MECHANICAL counterpart for the blind
# grader's `numbers_formatted` + `palette_match` dimensions, computed HERE
# while elements still carry _worksheet (same seam as chart-provenance).
# Per tile: every applicable source format string → the emitted Sigma format,
# status mapped|unmapped (unmapped = the translator refused; the source string
# is RECORDED, never guessed) + per-tile series-color pinning records. Always
# written (empty entries = "no source formats", vs "builder predates the
# artifact"). Consumed by the RCF loop and future gates.
begin
  fe = {
    'version'           => 1,
    'entries'           => FormatMap.emitted_records(elements, meta['worksheets'] || {}, COLUMN_DEFAULT_FORMATS, meta['columns_by_guid'] || {}),
    'series_color_maps' => SeriesColors.records(elements, meta['worksheets'] || {})
  }
  fe_path = File.join(File.dirname(File.expand_path(opts[:out])), 'formats-emitted.json')
  File.write(fe_path, JSON.pretty_generate(fe))
  unmapped = fe['entries'].count { |r| r['status'] == 'unmapped' }
  warn "wrote #{fe_path} (#{fe['entries'].size} format assignment(s), #{unmapped} unmapped — recorded, " \
       "never guessed; #{fe['series_color_maps'].size} series-color map(s))"
rescue => e
  warnings << "formats-emitted sidecar error (formats coverage unrecorded): #{e.message}"
end

# ---- C2: threshold-halo.json — the MECHANICAL counterpart for the blind ------
# grader's palette/threshold dimension. Records every threshold-colored mark the
# build detected: what it was (measure op constant + source colors), and how it
# was handled — 'emitted' (category chart: computed-boolean color + [below,above]
# scheme, the halo approximation), 'postpublish' (BAN/KPI: no create-spec path),
# or 'unmapped' (deferred: not a 2-band constant threshold). Never a silent drop.
# Only written when the source actually has a threshold color, so a workbook
# WITHOUT one stays byte-identical to origin/main (no sidecar, no coverage rows).
if $threshold_halo_records.any?
  begin
    th = { 'version' => 1, 'source' => 'tableau', 'halos' => $threshold_halo_records }
    th_path = File.join(File.dirname(File.expand_path(opts[:out])), 'threshold-halo.json')
    File.write(th_path, JSON.pretty_generate(th))
    by_status = $threshold_halo_records.group_by { |r| r['status'] }.transform_values(&:size)
    warn "wrote #{th_path} (#{$threshold_halo_records.size} threshold-colored mark(s): " \
         "#{by_status.map { |s, n| "#{n} #{s}" }.join(', ')})"
  rescue => e
    warnings << "threshold-halo sidecar error (halo coverage unrecorded): #{e.message}"
  end
end

# ---- Native trellis collapse (fix/native-trellis, SUPERSEDES #451 B1) --------
# parse-twb-layout flags a dashboard that repeats one viz across a categorical
# field as small multiples (N sibling per-member worksheets). The flat build
# above already emitted each member as its OWN filtered chart element. The
# CORRECT Sigma shape for small-multiples is ONE viz element carrying a native
# `trellis` property (rowsBy / columnsBy) — NOT N cloned elements. So here we
# COLLAPSE each detected group: keep the BASE member's element, reuse the facet
# field it already carries as its single-member filter column, EMPTY that member
# filter (so every member renders — one panel each), attach trellis.rowsBy /
# columnsBy chosen from the source ARRANGEMENT (vertical stack → rowsBy,
# horizontal row → columnsBy), and DROP the sibling member elements. Gated on
# `dash['trellis']` → a non-trellis workbook is byte-identical to the flat build.
(layout || []).each do |dash|
  next unless dash['trellis'].is_a?(Array) && !dash['trellis'].empty?
  dash['trellis'].each do |grp|
    caps = Array(grp['captions'])
    next if caps.size < 2
    base_cap = caps.first
    base_el = elements.find do |e|
      e['_dashboard'] == dash['dashboard'] && e['_worksheet'] == base_cap && e['source']
    end
    unless base_el
      warnings << "native trellis on '#{dash['dashboard']}': base worksheet #{base_cap.inspect} has no chart " \
                  'element — trellis NOT collapsed (member charts stay flat)'
      next
    end
    # Native `trellis` survives readback ONLY on the readback-safe kinds (empirical
    # coverage matrix — docs/sigma-trellis-chart-support.md). On pie/kpi/pivot/
    # table the POST returns 200 but Sigma SILENTLY STRIPS the key and renders
    # flat, so we must NOT emit it there. The supported set + fallback rules are
    # the single source of truth in shared/lib/trellis_emit.rb (TrellisEmit):
    #   * pie-chart → convert the base to a DONUT (donut supports trellis) and
    #     collapse as usual (the faithful faceted-pie shape) — TrellisEmit.apply
    #     does the kind flip below;
    #   * kpi-chart → leave the N sibling KPI elements FLAT (fanning out to N
    #     per-member KPIs IS the correct Sigma shape — do not collapse);
    #   * pivot-table/table → leave flat (pivot's own rowsBy/columnsBy shelves
    #     and table→postpublish are the documented follow-up mechanisms).
    # NOTE: the POST→readback round-trip must still ASSERT the key survived on
    # supported kinds (silent stripping) — enforced in the live e2e + verify.
    unless TrellisEmit.trellises?(base_el['kind'])
      warnings << "native trellis on '#{dash['dashboard']}': base kind '#{base_el['kind']}' does NOT support a " \
                  "native trellis (Sigma strips the key on readback) — left the #{caps.size} member " \
                  "#{base_el['kind']} element(s) FLAT " \
                  "(#{base_el['kind'] == 'kpi-chart' ? 'N sibling KPIs is the correct faceted shape' : 'pivot→own shelves / table→postpublish is the follow-up'})"
      next
    end
    if base_el['kind'] == 'pie-chart'
      warnings << "native trellis on '#{dash['dashboard']}': base '#{base_cap}' is a PIE — converted to DONUT " \
                  '(pie silently strips the trellis key on readback; donut supports it) before faceting'
    end
    field = grp['field'].to_s
    base_el['columns'] ||= []
    # The facet field is already a column on the base element — the flat build
    # added it as the single-member filter column `f-<el>-<field>`. Reuse it;
    # if absent (defensive), add a passthrough master column so the trellis has
    # a real column to face by.
    cat_col = base_el['columns'].find { |c| c['name'].to_s.strip.casecmp?(field.strip) }
    unless cat_col
      cid = "f-#{base_el['id']}-#{field.downcase.gsub(/\W+/, '-')}".sub(/-$/, '')
      cid = "f-#{base_el['id']}-trellis" if cid == "f-#{base_el['id']}-" || cid.end_with?('-')
      cat_col = { 'id' => cid, 'name' => field, 'formula' => "[Master/#{field}]" }
      base_el['columns'] << cat_col
    end
    # Empty the per-member list filter so ALL members render (matches the owner's
    # native reference: the list filter stays with values:[]; Sigma renders every
    # member as its own trellis panel).
    Array(base_el['filters']).each do |f|
      f['values'] = [] if f.is_a?(Hash) && f['columnId'] == cat_col['id'] && f['kind'] == 'list'
    end
    # Source arrangement → Sigma trellis axis via the shared emitter. A single
    # facet field faces ONE axis (rowsBy XOR columnsBy — emitting BOTH on the same
    # column is degenerate); a 'grid' arrangement of one field maps to columnsBy,
    # which Sigma wraps into a tile grid on its own. TrellisEmit.apply also does
    # the pie→donut kind flip (a no-op here — already gated/flipped above).
    TrellisEmit.apply(base_el, facet_column_id: cat_col['id'], orientation: grp['orientation'])
    axis_key = base_el['trellis'].keys.first
    # Round-trip guard record: Sigma SILENTLY strips an unsupported trellis on
    # readback, so the post-publish verifier re-reads the spec and asserts each
    # of these survived (verify-trellis-survived.rb).
    ($native_trellis_records ||= []) << {
      'element_id' => base_el['id'], 'kind' => base_el['kind'], 'name' => base_el['name'],
      'axis' => axis_key, 'columnId' => cat_col['id'], 'dashboard' => dash['dashboard']
    }
    # Drop the sibling member chart elements — the ONE trellis element replaces
    # the whole small-multiples set.
    sib_caps = caps[1..].map(&:to_s)
    elements.reject! do |e|
      e['_dashboard'] == dash['dashboard'] && sib_caps.include?(e['_worksheet'].to_s) && e['source']
    end
    warnings << "native trellis on '#{dash['dashboard']}': #{caps.size} #{field.inspect} worksheets → ONE " \
                "#{base_el['kind']} element '#{base_el['id']}' with trellis.#{axis_key} " \
                "(orientation=#{grp['orientation']}, facet column #{cat_col['id']})"
  end
end
# Round-trip guard sidecar — only written when a native trellis was actually
# emitted (a non-trellis workbook stays byte-identical: no sidecar). The
# post-publish verifier asserts each element still carries its `trellis` key on
# readback (Sigma silently strips unsupported ones).
if ($native_trellis_records ||= []).any?
  begin
    nt_path = File.join(File.dirname(File.expand_path(opts[:out])), 'native-trellis-emitted.json')
    File.write(nt_path, JSON.pretty_generate('version' => 1, 'elements' => $native_trellis_records))
    warn "wrote #{nt_path} (#{$native_trellis_records.size} native trellis element(s) — verify survives readback)"
  rescue => e
    warnings << "native-trellis sidecar error (round-trip coverage unrecorded): #{e.message}"
  end
end

# ---- Output mode ----
#   Default       → flat array of elements (legacy behaviour). Extras first.
#   --page-per-worksheet → emit { pages: [{name, elements:[]}] }. One page per
#                          worksheet that has a chart, with the shared-filter
#                          auto-controls AND a title text duplicated onto each
#                          page so the customer sees the same filter set on
#                          every page (Tableau dashboard-level filter semantics).
if opts[:pages_mode] == :worksheet
  pages = []
  by_ws = elements.group_by { |e| e['_worksheet'] }
  by_ws.each do |ws_name, els|
    els.each { |e| e.delete('_worksheet'); e.delete('_dashboard') }
    page_extras = []
    if title_text
      page_extras << {
        'id'   => "title-text-#{ws_name.downcase.gsub(/\W+/,'-')[0..30]}".sub(/-$/, ''),
        'kind' => 'text',
        'body' => "## #{ws_name}"
      }
    end
    # Auto-controls duplicated per page. Both `id` and `controlId` need to be
    # workbook-globally unique (Sigma rejects duplicates). We track per-page
    # controlId rewrites so any param-driven Switch() formula on this page's
    # charts can be rewritten to reference the suffixed controlId.
    ws_slug = ws_name.downcase.gsub(/\W+/, '-')[0..20]
    ctl_rewrites = {}
    (param_controls + auto_controls).each do |c|
      dup = JSON.parse(c.to_json)
      dup.delete('_scope_dashboards') # page-per-worksheet has no dashboard scope
      original_cid = dup['controlId']
      dup['id']        = "#{dup['id']}-#{ws_slug}"
      dup['controlId'] = "#{dup['controlId']}-#{ws_slug}"
      ctl_rewrites[original_cid] = dup['controlId']
      base = control_scope_records.find { |r| r['controlId'] == original_cid }
      (base['page_instances'] ||= []) << { 'page' => ws_name, 'controlId' => dup['controlId'] } if base
      page_extras << dup
    end
    # Rewrite Switch / If formulas on this page's chart calc columns.
    els.each do |el|
      (el['columns'] || []).each do |col|
        f = col['formula'].to_s
        ctl_rewrites.each do |from, to|
          f = f.gsub("[#{from}]", "[#{to}]")
        end
        col['formula'] = f
      end
    end
    pages << {
      'name'     => ws_name,
      'elements' => page_extras + els
    }
  end
  theme = ThemeDerive.derive(layout)
  # data_elements must ride EVERY output shape — multi-DS sub-masters (and any
  # hidden helpers) live there, and a routed chart whose sub-master never
  # reaches the spec is a dangling source ref (review-caught regression).
  _out = { 'pages' => pages, 'data_elements' => data_elements, 'theme' => theme }
  # PR-18: decode columns the orchestrator injects into the master element (only
  # when a master-rooted integer-dim control was routed — additive/byte-identical).
  _out['master_decode_columns'] = master_decode_columns if master_decode_columns.any?
  File.write(opts[:out], JSON.pretty_generate(_out))
  warn "wrote #{opts[:out]} (page-per-worksheet: #{pages.size} pages, #{auto_controls.size} auto-controls per page" \
       "#{data_elements.any? ? ", #{data_elements.size} hidden data element(s)" : ''})"
elsif opts[:pages_mode] == :dashboard
  # One Sigma page per Tableau DASHBOARD (bead ptrt) — the fat-workbook fix:
  # 4 dashboards must become 4 laid-out pages, each with its own title text and
  # its own copy of the dashboard-global controls (ids suffixed for global
  # uniqueness, control refs in calc formulas rewritten per page).
  dash_order = layout.map { |d| d['dashboard'] }
  by_dash = elements.group_by { |e| e['_dashboard'] }
  pages = []
  seen_el_ids = {}   # element id → true; a worksheet reused on N dashboards
                     # yields N element copies sharing one id → "Duplicate id"
                     # on POST. Namespace the 2nd+ occurrence per page.
  dash_order.each do |dash_name|
    els = by_dash[dash_name]
    next if els.nil? || els.empty?
    els.each { |e| e.delete('_worksheet'); e.delete('_dashboard') }
    d_slug = dash_name.to_s.downcase.gsub(/\W+/, '-')[0..30].sub(/-$/, '')
    # Skip the synthetic "# <dashboard>" title when this dashboard has its OWN top
    # title zone (a styled text/title zone near the top) — that zone is already
    # emitted in styled_text_by_dash and placed at the top by the layout stage, so
    # a synthetic one DOUBLES the title (renders at the top AND again in the stray
    # text band — the reported "title top + bottom" duplicate). The source banner
    # (richer, e.g. "Orders — Executive Overview") wins.
    dash_has_top_title = (layout.find { |d| d['dashboard'] == dash_name } || {})['zones']
                         &.any? { |z| %w[title text].include?(z['kind']) && (z['y_pct'] || 100) < 10 && z['text_runs'] }
    page_extras = []
    unless dash_has_top_title
      page_extras << {
        'id'   => "title-#{d_slug}",
        'kind' => 'text',
        # Theme-default colour: the layout builder now emits a colored header band
        # only when the source has one (else the title sits on the canvas, where
        # forced-white would be invisible).
        'body' => "# #{dash_name}"
      }
    end
    # B4: this dashboard's styled static-text elements (subtitle/annotations/
    # credit/section headers) — incl. the source's own top title banner. Placed by
    # the layout stage at their zone geometry.
    styled_text_by_dash[dash_name].each { |e| page_extras << e.reject { |k, _| k == '_dashboard' } }
    ctl_rewrites = {}
    param_control_ids = param_controls.map { |c| c['controlId'] }
    (param_controls + auto_controls).each do |c|
      # Quick-filter zones apply per-dashboard: skip pages whose zone tree
      # doesn't carry the filter (empty scope = shared-view default, all pages).
      sd = c['_scope_dashboards']
      next if sd.is_a?(Array) && sd.any? && !sd.include?(dash_name)
      # Parameter controls drive charts through FORMULA refs (a Switch/If reads
      # the control id), not filter targets. Only emit one on a page where some
      # element formula actually references it — otherwise it's a "dead control"
      # (a user changes it and nothing reacts) that fails the control lint.
      if param_control_ids.include?(c['controlId'])
        used = els.any? { |el| (el['columns'] || []).any? { |col| col['formula'].to_s.include?("[#{c['controlId']}]") } }
        # A DATA-SCOPING parameter control filters via its `filters` targets (a
        # boolean filter-calc wired to a master column at ~L4649), NOT via a
        # Switch/If formula ref — so it is NOT dead even when no chart formula
        # names it. Keep it whenever it carries filter targets, else the Region
        # data-scoper is silently dropped (control-lint FAIL + the multi-metric
        # recipe can't find a control to build masterAll/highlight from).
        used ||= (c['filters'].is_a?(Array) && c['filters'].any?)
        next unless used
      end
      dup = JSON.parse(c.to_json)
      dup.delete('_scope_dashboards')
      original_cid = dup['controlId']
      dup['id']        = "#{dup['id']}-#{d_slug[0..20]}"
      dup['controlId'] = "#{dup['controlId']}-#{d_slug[0..20]}"
      ctl_rewrites[original_cid] = dup['controlId']
      base = control_scope_records.find { |r| r['controlId'] == original_cid }
      (base['page_instances'] ||= []) << { 'page' => dash_name, 'controlId' => dup['controlId'] } if base
      page_extras << dup
    end
    els.each do |el|
      (el['columns'] || []).each do |col|
        f = col['formula'].to_s
        ctl_rewrites.each { |from, to| f = f.gsub("[#{from}]", "[#{to}]") }
        col['formula'] = f
      end
    end
    # K3: page_extras (styled text, title text, images) carry Tableau ZONE ids,
    # which are unique per dashboard but NOT globally — "text-550" recurs on the
    # next dashboard. They were concatenated in after this pass, so they never
    # got namespaced and the POST hard-failed on "Duplicate id". Same op as the
    # els pass below, minus the top-N source-restore (page_extras have no
    # source.elementId).
    namespace_ids = lambda do |list|
      list.map do |el|
        stem = el['id']
        next el unless stem

        if seen_el_ids[stem]
          ns = "#{stem}-#{d_slug[0..20]}"
          ($hidden_title_ns_ids ||= []) << ns if ($hidden_title_ids || []).include?(stem)
          if (pv = $chart_provenance[stem])
            $chart_provenance[ns] = pv.merge('dashboard' => dash_name)
          end
          JSON.parse(el.to_json.gsub(stem, ns))
        else
          seen_el_ids[stem] = true
          el
        end
      end
    end

    # Namespace element ids that already appeared on a prior page (a worksheet
    # placed on multiple dashboards). The element id is the stem of its column
    # ids (x-<id>/y-<id>/g-<id>) and grouping refs, so gsub the stem across the
    # element's own JSON to rewrite id + column ids + grouping refs in lock-step
    # (formulas reference [Master/..]/[ctl-..], never the element id, so they're
    # untouched).
    els.map! do |el|
      stem = el['id']
      if stem && seen_el_ids[stem]
        ns = "#{stem}-#{d_slug[0..20]}"
        # a namespaced copy of a hidden-title element needs ITS id in the
        # sidecar too (written post-emitters) — exact-id matching in
        # put-layout would otherwise leak the copy's title chrome
        ($hidden_title_ns_ids ||= []) << ns if ($hidden_title_ids || []).include?(stem)
        # provenance for the namespaced copy: same WORKSHEET, this dashboard —
        # auto-parity-plan keys the join by element id, so every posted copy
        # must resolve to its worksheet (both copies verify against the same
        # view CSV by design).
        if (pv = $chart_provenance[stem])
          $chart_provenance[ns] = pv.merge('dashboard' => dash_name)
        end
        src_before = el.dig('source', 'elementId')
        el2 = JSON.parse(el.to_json.gsub(stem, ns))
        # v5.1.3: the stem gsub also rewrites a source.elementId that EMBEDS
        # the stem (top-N prefilter helpers are '<stem>-topn-src'). The helper
        # is a SHARED data element that keeps its original id — restore the
        # ref, or the second page's copy points at a helper that doesn't
        # exist and the POST hard-fails (review-caught, live-reproduced).
        src_after = el2.dig('source', 'elementId')
        if src_after != src_before && data_elements.any? { |d| d['id'] == src_before } &&
           data_elements.none? { |d| d['id'] == src_after }
          el2['source']['elementId'] = src_before
        end
        el2
      else
        seen_el_ids[stem] = true if stem
        el
      end
    end
    page = { 'name' => dash_name, 'elements' => namespace_ids.call(page_extras) + els }
    # v5.0: full-canvas designed background (the Figma/PPT card-art pattern) →
    # page-level backgroundImage (data URI live-verified rendering behind the
    # page's elements). image_asset_records carries the extracted asset.
    bg = image_asset_records.find { |r| r['dashboard'] == dash_name && r['is_background'] && r['asset'] }
    if bg
      url = bg['image_file_url'] ||
            "data:image/png;base64,#{Base64.strict_encode64(File.binread(bg['asset']))}"
      page['backgroundImage'] = { 'url' => url, 'style' => { 'fit' => bg['is_scaled'] ? 'stretch' : 'cover' } }
      warn "page '#{dash_name}': designed background #{File.basename(bg['asset'])} → page backgroundImage"
    end
    pages << page
  end
  theme = ThemeDerive.derive(layout)
  _out = { 'pages' => pages, 'data_elements' => data_elements, 'theme' => theme }
  # PR-18: decode columns the orchestrator injects into the master element (only
  # when a master-rooted integer-dim control was routed — additive/byte-identical).
  _out['master_decode_columns'] = master_decode_columns if master_decode_columns.any?
  File.write(opts[:out], JSON.pretty_generate(_out))
  warn "wrote #{opts[:out]} (page-per-dashboard: #{pages.size} page(s), #{data_elements.size} hidden data element(s), #{(param_controls + auto_controls).size} controls per page)"
else
  elements.each { |e| e.delete('_worksheet'); e.delete('_dashboard') }
  all_extras.each { |e| e.delete('_scope_dashboards') }
  styled_text_all.each { |e| e.delete('_dashboard') }
  all_elements = all_extras + styled_text_all + elements
  File.write(opts[:out], JSON.pretty_generate(all_elements))
  warn "wrote #{opts[:out]}  (#{all_elements.size} elements: #{all_extras.size} controls/text + " \
       "#{styled_text_all.size} styled-text + #{elements.size} charts)"
  if data_elements.any?
    side = opts[:out].sub(/\.json$/, '-data-elements.json')
    File.write(side, JSON.pretty_generate(data_elements))
    warn "wrote #{side} (#{data_elements.size} HIDDEN data-page element(s) — scatter grouped sources; add them to the workbook's Data page)"
  end
  # Flat-array mode can't carry a top-level theme key — sidecar (mirrors the
  # -data-elements.json pattern).
  theme = ThemeDerive.derive(layout)
  unless theme.empty?
    tside = opts[:out].sub(/\.json$/, '-theme.json')
    File.write(tside, JSON.pretty_generate(theme))
    warn "wrote #{tside} (derived theme — apply via ThemeDerive.apply! / build-workbook-spec)"
  end
end

# hidden-titles sidecar WRITE — after the emitters so namespaced duplicate ids
# (worksheet on 2+ dashboards) are included; shape {workbook:, ids:} so the
# stale-cleanup ownership check can tell workbooks apart (legacy arrays read
# fine in put-layout).
begin
  ht_ids = (($hidden_title_ids || []) + ($hidden_title_ns_ids || [])).uniq
  if ht_ids.any?
    ht_path = opts[:out].sub(/\.json$/, '-hidden-titles.json')
    File.write(ht_path, JSON.pretty_generate({ 'workbook' => $hidden_title_wb_sha, 'ids' => ht_ids }))
    warn "wrote #{ht_path} (#{ht_ids.size} element title(s) hidden at put-layout, incl. #{($hidden_title_ns_ids || []).size} namespaced cop(ies))"
  end
rescue => e
  warnings << "hidden-titles sidecar write error (titles stay visible): #{e.message}"
end

# chart-provenance sidecar WRITE — after the emitters so page-per-dashboard's
# namespaced duplicate ids are included. ALWAYS written (possibly empty) so
# auto-parity-plan can tell "no charts built" from "builder predates
# provenance" (an absent file ⇒ warned display-name fallback matching).
begin
  if opts[:tab]
    pv_path = File.join(opts[:tab], 'chart-provenance.json')
    File.write(pv_path, JSON.pretty_generate({ 'version' => 1, 'elements' => $chart_provenance }))
    warn "wrote #{pv_path} (#{$chart_provenance.size} element→worksheet provenance entr(y/ies) for auto-parity-plan)"
  end
rescue => e
  warn "  WARN  chart-provenance sidecar write error (parity plan falls back to display-name matching): #{e.message}"
end

# ---- Intended-scope contract (control-scope.json) ---------------------------
# Emitted in the lib/control_lint.rb CONTRACT shape (a Hash — a bare array is
# silently ignored by the lint):
#   * sourceFilterSignals = every source signal we saw (parameters, quick
#     filters, explicit --controls entries — dropped ones included: they ARE
#     signals; the loud build warning covers the drop)
#   * per emitted control: scope = "page" when the control's reachable intent
#     covers every chart on its page, else the allowlist of reachable intended
#     element ids (zone-scoped quick filters, formula-driven parameters, and
#     unreachable-root exclusions are all by-design narrow scopes — recorded,
#     never silent); mustReach = the [Action (X)]-scoped worksheets' charts —
#     the sheet-scoped-filter closure is a hard assertion, not a default
#   * page-mode runs emit one entry per page INSTANCE (the per-page rewritten
#     controlId is what the posted spec actually carries)
#   * dropped controls live under "dropped", NOT "controls" (a sidecar control
#     missing from the spec is a lint failure by design — the drop is already
#     loud above); rich detail keys ride along, the lint ignores unknown keys.
unless control_scope_records.empty?
  unreach_names = ->(r) { Array(r['unreachable']).flat_map { |u| u['elements'] || [] } }
  page_chart_ids = lambda do |page|
    page ? ctl_chart_index.select { |c| c['dash'] == page || c['ws'] == page }.map { |c| c['id'] }
         : ctl_chart_index.map { |c| c['id'] }
  end
  to_contract = lambda do |r, cid, page|
    ints = Array(r['intended'])
    # page is a dashboard name (page-per-dashboard) or a worksheet name
    # (page-per-worksheet); parameter records carry neither key — keep those.
    ints = ints.select { |i| (i['dashboard'] || i['worksheet']).nil? || i['dashboard'] == page || i['worksheet'] == page } if page
    bad = unreach_names.call(r)
    reached = ints.reject { |i| bad.include?(i['name']) }
    reached_ids = reached.map { |i| i['element_id'] }.uniq
    e = r.merge('controlId' => cid, 'sourceName' => r['source_signal'])
    e.delete('page_instances')
    e['scope'] = (page_chart_ids.call(page) - reached_ids).empty? ? 'page' : reached_ids
    aws = Array(r['action_worksheets'])
    must = reached.select { |i| aws.include?(i['worksheet']) }.map { |i| i['element_id'] }.uniq
    e['mustReach'] = must if must.any?
    e
  end
  emitted_rs, dropped_rs = control_scope_records.partition { |r| r['status'] != 'dropped' }
  contract_controls = emitted_rs.flat_map do |r|
    if (insts = Array(r['page_instances'])).any?
      insts.map { |pi| to_contract.call(r, pi['controlId'], pi['page']) }
    else
      [to_contract.call(r, r['controlId'], nil)]
    end
  end
  sidecar = {
    'version' => 1, 'source' => 'tableau',
    'sourceFilterSignals' => control_scope_records.size,
    'controls' => contract_controls,
    'dropped' => dropped_rs
  }
  scope_path = File.join(opts[:tab], 'control-scope.json')
  File.write(scope_path, JSON.pretty_generate(sidecar))
  warn "wrote #{scope_path} (#{contract_controls.size} control scope entr(y/ies), #{dropped_rs.size} dropped)"

  # PR-18: integer-dim decode sidecar — the candidates for the OPTIONAL
  # warehouse-cardinality confirmation (probe-int-dim-cardinality.rb) and the
  # source for the POSTPUBLISH manual-decode section. Only written when an
  # integer-coded dimension control was detected (additive/byte-identical).
  int_dim_ctls = control_scope_records.select { |r| r['integer_dim'] }
  if int_dim_ctls.any? || (defined?($integer_dim_manual) && $integer_dim_manual&.any?)
    id_path = File.join(opts[:tab], 'integer-dim-decode.json')
    File.write(id_path, JSON.pretty_generate(
                 'version' => 1, 'source' => 'tableau',
                 'candidates' => int_dim_ctls.map do |r|
                   { 'controlId' => r['controlId'], 'name' => r['name'],
                     'column' => r['name'], 'decode' => r['decode'] }
                 end,
                 'manual' => (defined?($integer_dim_manual) ? ($integer_dim_manual || []) : [])
               ))
    warn "wrote #{id_path} (#{int_dim_ctls.size} integer-dim control(s); " \
         "#{(defined?($integer_dim_manual) ? ($integer_dim_manual || []) : []).size} manual-decode note(s))"
  end
end
# Classify each build message so the WARN count reflects ACTUAL gaps, not volume
# (bead beads-sigma-59mk). The builder historically prefixed every note — including
# SUCCESS confirmations ("decomposed: …", "translated inline: …") and verify-nudges
# ("auto-emitted … verify", "sort carried", "inferred from shelves") — with WARN,
# so a clean conversion read like a pile of failures (the "drops a lot" perception).
# Only genuine drops/degradations are WARN now; the rest are NOTE. The SAME helper
# feeds coverage.json below, so WARN count == coverage gap count from warnings.
#   :dropped  — a source component was lost (no element / value)
#   :degraded — built best-effort but a piece stays manual / wasn't auto-emitted
#   :note     — success or a verify nudge (NOT a gap)
def warning_severity(w)
  s = w.to_s
  return :dropped  if s =~ /ZONE DROPPED|NOT auto-built|dropped from the grid|—\s*skipping|could not be carried|cannot reconstruct/i
  return :degraded if s =~ /STAYS[ -]MANUAL|could not be auto-decomposed|not composable as agg-of-agg|not auto-emitted|falling (through|back)/i
  :note
end
warnings.each do |w|
  warn(warning_severity(w) == :note ? "  NOTE  #{w}" : "  WARN  #{w}")
end

# ---- Visual-verify sidecar (build-from-signals tiles) -----------------------
# Tiles built from .twb signals (empty data export) can't be value-diffed, so
# the orchestrator routes them to IMAGE-based verification (verify-visual-
# tiles.rb): fetch the Tableau view image + render the Sigma element and compare
# them. Resolve each tile's Sigma element id by name so the renderer can target
# it. Always write the file (possibly empty) so the gate can distinguish
# "checked, none needed" from "never ran".
if opts[:tab]
  by_name = elements.each_with_object({}) { |e, h| h[e['name'].to_s] = e['id'] if e['name'] }
  seen = {}
  vv = signal_built_tiles.map do |t|
    { 'worksheet' => t['worksheet'], 'view_id' => t['view_id'],
      'element_id' => by_name[t['worksheet'].to_s], 'reason' => (t['reason'] || 'empty-data-export') }
  end.select { |t| t['element_id'] && !seen[t['worksheet']] && (seen[t['worksheet']] = true) }
  vv_path = File.join(opts[:tab], 'visual-verify-tiles.json')
  File.write(vv_path, JSON.pretty_generate(vv))
  unless vv.empty?
    by_reason = vv.group_by { |t| t['reason'] }.transform_values(&:size)
    warn "wrote #{vv_path} (#{vv.size} tile(s) need IMAGE verification: #{by_reason.map { |r, n| "#{n} #{r}" }.join(', ')})"
  end
end

# Multi-datasource routing sentry (see the collection point in the zone loop):
# charts whose worksheet rides a MINORITY datasource are still sourced from the
# single master — name each one and the fix, so the pre-POST ref-gate failure
# that follows (if the master lacks their columns) is diagnosable in one read.
if $zone_datasource && $zone_datasource.values.uniq.length > 1
  groups = $zone_datasource.group_by { |_ws, ds| ds }
  dominant_ds = groups.max_by { |_ds, pairs| pairs.length }.first
  outliers = $zone_datasource.reject { |_ws, ds| ds == dominant_ds }
  # v5.0: auto-routed worksheets are handled (sub-master + rewritten formulas)
  # — the WARN wall is only for what routing could NOT mechanize.
  routed = outliers.select { |ws, _| $ds_routed && $ds_routed.key?(ws) }
  outliers = outliers.reject { |ws, _| $ds_routed && $ds_routed.key?(ws) }
  unless routed.empty?
    warn "multi-DS: #{routed.size} outlier chart(s) AUTO-ROUTED to their own datasource's DM element " \
         "(#{routed.map { |ws, _| "'#{ws}'→'#{$ds_routed[ws]}'" }.join(', ')}) — verify in Phase 6 as usual."
  end
  unless outliers.empty?
    # Enrich with the gap-scan's routing plan (multi-ds-plan.json): it names
    # each federated datasource's CAPTION + owning worksheets, so the fix
    # instruction can name the exact DM element to re-source from instead of
    # leaving each agent to reverse-engineer the federated ids.
    ds_caption = {}
    if opts[:tab]
      plan = (JSON.parse(File.read(File.join(opts[:tab], 'multi-ds-plan.json'))) rescue nil)
      (plan && plan['datasources'] || []).each { |d| ds_caption[d['name']] = d['caption'] }
    end
    warn '=== MULTI-DATASOURCE ROUTING WARNING ============================================'
    warn "The dashboard's worksheets ride #{groups.length} DIFFERENT datasources, but every chart"
    warn "is sourced from the single master (#{opts[:master_id].inspect}) riding the DOMINANT one " \
         "(#{ds_caption[dominant_ds] || dominant_ds})."
    outliers.each do |ws, ds|
      cap = ds_caption[ds]
      warn "  • '#{ws}' rides #{cap ? "'#{cap}'" : ds} — re-source it from THAT datasource's DM element" \
           "#{cap ? " (element named after '#{cap}' in the posted DM)" : ''}; its refs resolve on the" \
           ' master ONLY if the master fact happens to carry the same columns'
    end
    warn 'Routing table: multi-ds-plan.json (per-datasource caption → worksheets). Fix = source'
    warn "each outlier chart from its own DM element ([<Element Name>/<Column>] refs, or a second"
    warn 'master per refs/multi-datasource.md). Do NOT point their formulas at the primary master'
    warn 'by renaming columns — wrong data, silently.'
    warn '================================================================================='
  end
end

# ---- Nested-LOD chains sidecar (beads-sigma-t67b) ---------------------------
# Machine-readable helper-element chains for every nested {FIXED} calc: the
# agent builds one grouped element per chain level (innermost first; Value =
# sigma_aggregate, grouped by dims), relates each level to the next on the
# shared dims, and lands `final` on the consuming chart/master. Outer levels
# MUST source the inner element at its grouping grain (`groupingId` on the
# source) or via a Custom SQL GROUP BY — see decompose_nested_fixed's header
# note on the row-weighted-aggregate trap.
unless lod_chains.empty?
  lod_path = opts[:out].sub(/\.json$/, '-lod-chains.json')
  File.write(lod_path, JSON.pretty_generate(lod_chains))
  warn "wrote #{lod_path} (#{lod_chains.size} nested-LOD chain(s))"
end

# ---- Tableau dashboard actions companion file -----------------------------
# Action filters were translated into element-level filters when possible; the
# leftover Tableau-internal action wiring (which source-tile filters which
# target-tile set) is non-translatable without Sigma's cross-element wiring
# API. Emit a companion actions.md so the agent (or customer) can replicate
# the cross-chart interactivity by hand post-publish.
actions = []
(layout || []).each do |dash|
  (dash['zones'] || []).each do |z|
    next unless z['kind'] == 'chart'
    (z['filters'] || []).select { |f| f['is_action'] }.each do |af|
      # Tableau's action filter column looks like
      #   [federated.<id>].[Action (Region)]
      # Pull "Region" out as the dim that the action filters on.
      raw = (af['raw_param'] || af['column'] || '').to_s
      dim = (raw[/\[Action \(([^)]+)\)\]/, 1] || raw)
      actions << {
        'target'  => z['caption'],
        'source'  => dim,
        'column'  => dim
      }
    end
  end
end
unless actions.empty? && nav_button_records.empty?
  actions_md_path = opts[:out].sub(/\.json$/, '-actions.md')
  md = String.new
  md << "# Tableau dashboard actions — post-publish setup\n\n"
  unless actions.empty?
    md << "Sigma cross-chart filtering replaces Tableau's filter actions. For each\n"
    md << "row below, in the published Sigma workbook: select the source element,\n"
    md << "open Actions → Add filter action, target the listed element on the named\n"
    md << "column.\n\n"
    md << "| Source dim | Target chart | Filter column |\n"
    md << "|---|---|---|\n"
    actions.uniq.each do |a|
      md << "| #{a['source']} | #{a['target']} | #{a['column']} |\n"
    end
  end
  unless nav_button_records.empty?
    md << "\n## Navigation buttons (wired automatically)\n\n"
    md << "Emitted with a placeholder URL; put-layout.rb rewrites each to the live\n"
    md << "workbook page URL after publish. Verify each link navigates correctly.\n\n"
    md << "| Source dashboard | Button | Target page |\n"
    md << "|---|---|---|\n"
    nav_button_records.each do |b|
      md << "| #{b['dashboard']} | #{b['label']} | #{b['target_page_name']} |\n"
    end
  end
  File.write(actions_md_path, md)
  warn "wrote #{actions_md_path} (#{actions.size} action + #{nav_button_records.size} nav-button entries)"
end

# ---- spec-API limits — unsupported source primitives/features (bead ubr5.20) --
# Some Tableau viz kinds + features have NO Sigma spec path. When the builder
# can't emit them it produces NOTHING and NO warning — so they vanish silently
# from coverage.json (the #1 "the report said clean but the dashboard is missing
# things" failure). Scan the SOURCE dashboard zones and name each unsupported
# primitive/feature explicitly. Detectors are CONSERVATIVE (fire only on a clear
# structural signal) to avoid false positives; one entry per zone.
def spec_api_limit_entries(layout, cmp_wired = {})
  entries = []
  add = lambda do |cap, severity, detail, action|
    entries << { 'visual' => cap.to_s, 'source_type' => 'worksheet',
                 'severity' => severity, 'recoverable' => false,
                 'detail' => detail, 'action' => action }
  end
  (layout || []).each do |dash|
    (dash['zones'] || []).each do |z|
      next unless z['kind'] == 'chart'
      cap  = (z['caption'] || z['id']).to_s
      mk   = z['mark_class'].to_s
      ck   = z['chart_kind'].to_s
      calc = (z['calculations'] || []).map { |c| "#{c['caption']} #{c['formula']}" }.join(' ')
      meas = (z['measures'] || []).map { |m| m['column'] }.join(' ')
      # Bump / rank-flow: a line chart whose plotted value is a RANK/INDEX table
      # calc (one line per entity connecting rank positions over time). ubr5.21.
      if (mk == 'Line' || ck == 'line') &&
         (meas =~ /\[?rank\b/i || calc =~ /\b(?:RANK(?:_UNIQUE|_DENSE|_MODIFIED|_PERCENTILE)?|INDEX)\s*\(/i)
        add.call(cap, 'dropped',
                 'bump / rank-flow chart (line-per-entity rank over a time axis) — no Sigma chart primitive',
                 'Rebuild as a line chart with a computed Rank() y-value on an inverted axis, or omit (see bead ubr5.21).')
        next
      end
      # Shape / image mark used as an icon or decorative graphic — Sigma has no
      # shape mark; these are silently dropped today.
      if mk == 'Shape'
        add.call(cap, 'dropped',
                 'shape / image-mark worksheet (icon or decorative graphic) — Sigma has no shape mark',
                 'Recreate with a hosted image element (kind:image + URL) or omit; not auto-migrated.')
        next
      end
      # Filled map / choropleth with a color gradient — limited Sigma geo support.
      if z['geo_role'] && (mk =~ /map|polygon/i || ck =~ /map|choropleth/i)
        add.call(cap, 'degraded',
                 'filled map / choropleth — Sigma polygon/value-gradient geography support is limited',
                 'Verify against a Sigma map element; a point/bubble-map fallback may be needed.')
        next
      end
      # KPI ▲/▼ delta: the big number migrates, but the vs-prior comparison
      # indicator (arrow + % change) is UI-only, not spec-authorable — UNLESS
      # Task 5's detector already resolved a real comparison measure and wired
      # it as the kpi-chart's comparisonColumn (build_kpi_element records the
      # tile in $kpi_comparison_wired, keyed the same way as `cap` here). Only
      # warn when detection did NOT wire one — don't cry "UI-only" about a
      # delta we actually built.
      if (z['is_kpi'] || ck == 'kpi') && !cmp_wired[cap] &&
         (calc =~ /(?:up|down)\s*arrow|%\s*change|change from prev|vs\.?\s*prev|prior (?:month|period|year)/i ||
          meas =~ /arrow|%\s*change/i)
        add.call(cap, 'degraded',
                 'KPI comparison indicator (▲/▼ + % vs prior period) is UI-only — the value migrates, the delta does not',
                 'Add the trend/comparison in the Sigma editor after publish (not spec-authorable; memory sigma-kpi-trend-comparison-ui-only).')
        next
      end
    end
    # v5.0-P2: dashboard-object BUTTON residue (the ubr5.20 anti-silent-vanish
    # rule). Navigate buttons are EMITTED (btn- elements); export buttons are
    # redundant (Sigma has a built-in export menu); toggles have no spec
    # equivalent. Dedupe toggles per (dashboard, tooltip/image) — the corpus
    # has one workbook with 88 accordion toggles, and 88 identical ledger rows
    # is noise, not coverage.
    btns = (dash['zones'] || []).select { |z| z['kind'] == 'dashboard-object' && z['button_intent'] }
    # Navigate buttons whose target ISN'T a dashboard (worksheet windows,
    # unresolved window-id GUIDs) are NOT emitted — they must appear here or
    # they vanish silently (review-caught: the build warning classifies as
    # NOTE, which the coverage loop skips).
    btns.select { |z| z['button_intent'] == 'navigate' &&
                      !(z['button_nav_target'] && z['button_nav_target_class'] == 'dashboard') }.each do |z|
      entries << { 'visual' => (z['button_caption'] || z['button_tooltip'] || "button #{z['id']}").to_s,
                   'source_type' => 'button', 'severity' => 'dropped', 'recoverable' => false,
                   'detail' => "navigation button targets #{z['button_nav_target_class'] || 'an unresolved window'} " \
                               '— no Sigma page equivalent',
                   'action' => 'link the nearest equivalent page by hand post-publish, or omit.' }
    end
    btns.select { |z| z['button_intent'].to_s.start_with?('export') }.each do |z|
      entries << { 'visual' => (z['button_caption'] || z['button_tooltip'] || "button #{z['id']}").to_s,
                   'source_type' => 'button', 'severity' => 'dropped', 'recoverable' => true,
                   'detail' => "Tableau #{z['button_intent']} download button — redundant in Sigma (built-in export menu)",
                   'action' => "none needed; point users at Sigma's export menu." }
    end
    toggles = btns.select { |z| z['button_intent'] == 'toggle' }
    toggles.group_by { |z| [z['button_tooltip'], z['button_image_path']] }.each do |_, grp|
      z = grp.first
      entries << { 'visual' => (z['button_caption'] || z['button_tooltip'] || "toggle button #{z['id']}").to_s +
                               (grp.size > 1 ? " (×#{grp.size})" : ''),
                   'source_type' => 'button', 'severity' => 'dropped', 'recoverable' => false,
                   'detail' => 'show/hide container toggle button — Sigma has no spec-authorable container-visibility toggle',
                   'action' => 'replicate as a separate (hidden) page, or leave the region expanded (post-publish).' }
    end
  end
  entries
end

# ---- coverage.json — ONE consolidated "what didn't carry over (and why)" ledger
# (bead beads-sigma-59mk; ports powerbi-to-sigma PR #177). The builder already
# emits the facts — 87 build WARN lines + the dropped-control / inferred-tile /
# nested-LOD sidecars — but scattered across the log + several files. This
# AGGREGATES them into the shared coverage.json schema that CoverageGate renders,
# so a complex dashboard's gaps surface in one place instead of being
# reconstructed by hand. Leads with what CARRIED OVER (only a 'dropped' component
# is truly absent; approximated/degraded still land with their data).
# Entry: {visual, source_type, severity(dropped|degraded|approximated), detail,
#         recoverable, action}.
coverage_unresolved = []

# (1) dropped controls — a source filter/parameter that resolved to no target.
control_scope_records.select { |r| r['status'] == 'dropped' }.each do |r|
  coverage_unresolved << {
    'visual' => (r['source_signal'] || r['sourceName'] || 'filter/control').to_s,
    'source_type' => 'filter', 'severity' => 'dropped', 'recoverable' => true,
    'detail' => "filter/control dropped: #{r['reason'] || r['drop_reason'] || 'did not resolve to a target column'}",
    'action' => 'Map the filtered column on the master (or fix master-columns.json) so the control wires, then re-run.'
  }
end

# (2) inferred chart-kind tiles — built with a best-guess Sigma kind (no value
# export to confirm), an APPROXIMATION the image-verify gate must confirm. Plain
# 'empty-data-export' tiles built faithfully and are NOT a coverage gap.
signal_built_tiles.select { |t| t['reason'] == 'chart-kind-inferred' }
                  .uniq { |t| t['worksheet'] }.each do |t|
  coverage_unresolved << {
    'visual' => t['worksheet'].to_s, 'source_type' => 'worksheet',
    'severity' => 'approximated', 'recoverable' => false,
    'detail' => 'chart kind inferred (no value export to confirm) — verify against the source image',
    'action' => 'Compare the rendered Sigma tile to the Tableau view image (visual-verify gate); fix the kind if the inference is wrong.'
  }
end

# (3) nested-LOD chains — built as a helper-element chain the agent must assemble.
lod_chains.each do |lc|
  nm = (lc['final'] || lc['name'] || lc['caption'] || 'nested-LOD calc').to_s
  coverage_unresolved << {
    'visual' => nm, 'source_type' => 'calc', 'severity' => 'degraded', 'recoverable' => true,
    'detail' => 'nested FIXED LOD needs a helper-element chain to resolve',
    'action' => 'Build the nested-LOD helper chain from the <out>-lod-chains.json sidecar (one grouped element per level).'
  }
end

# (4) build messages that name a LOST or degraded component — classified by the
# SAME warning_severity helper used for the WARN/NOTE split above, so the coverage
# gap list and the WARN log agree exactly. :note messages (successes / verify
# nudges) are NOT coverage gaps.
warnings.each do |w|
  sev = warning_severity(w)
  next if sev == :note
  ws = w.to_s.gsub(/\s+/, ' ').strip
  vis = (ws[/\A'([^']+)'/, 1] || 'field/calc')
  recoverable = !(ws =~ /unmapped|master|master-col|could not be auto-decomposed|STAYS MANUAL/i).nil?
  coverage_unresolved << {
    'visual' => vis, 'source_type' => 'field/calc',
    'severity' => sev.to_s, 'recoverable' => recoverable,
    'detail' => ws[0, 300],
    'action' => (recoverable ? 'Resolve the field on the master (map it / add the calc column), then re-run.' : nil)
  }
end

# (4.5) C2 threshold halos that WERE emitted — the halo is an APPROXIMATION
# (Sigma has no second marks-layer overlay), so it belongs in coverage as
# 'approximated' even though it carried. The 'postpublish'/'unmapped' records
# already flow through their STAYS-MANUAL warnings in (4); adding only 'emitted'
# here avoids double-listing.
$threshold_halo_records.select { |r| r['status'] == 'emitted' }.each do |r|
  coverage_unresolved << {
    'visual' => r['worksheet'].to_s, 'source_type' => 'threshold-color',
    'severity' => 'approximated', 'recoverable' => false,
    'detail' => "threshold halo emitted as computed-boolean color + scheme #{Array(r['scheme']).inspect} " \
                "(#{r['formula'].to_s.gsub(/\s+/, ' ')}) — Sigma has no second marks-layer overlay; the halo is approximated",
    'action' => 'Verify the rendered mark colors flip at the threshold against the Tableau source image.'
  }
end

# (5) spec-API limits — unsupported source primitives/features (bead ubr5.20).
# Skip any zone already surfaced by a warning above (avoid double-listing).
_already = coverage_unresolved.map { |u| u['visual'].to_s.downcase }
spec_api_limit_entries(layout, $kpi_comparison_wired).each do |e|
  next if _already.include?(e['visual'].to_s.downcase)
  coverage_unresolved << e
end

built_n = (defined?(elements) && elements.respond_to?(:size)) ? elements.size : 0
dropped_n = coverage_unresolved.select { |u| u['severity'] == 'dropped' }.map { |u| u['visual'] }.uniq.size
by_sev = coverage_unresolved.group_by { |u| u['severity'] }.transform_values(&:size)
coverage_path = opts[:coverage_out] ||
                File.join(File.dirname(File.expand_path(opts[:out])), 'coverage.json')
File.write(coverage_path, JSON.pretty_generate(
             { 'version' => 1, 'source' => 'tableau',
               'summary' => {
                 'sourceVisuals' => built_n + dropped_n,
                 'builtElements' => built_n,
                 'dropped' => by_sev['dropped'] || 0,
                 'degraded' => by_sev['degraded'] || 0,
                 'approximated' => by_sev['approximated'] || 0,
                 'recoverable' => coverage_unresolved.count { |u| u['recoverable'] }
               },
               'unresolved' => coverage_unresolved }
           ))
warn "wrote #{coverage_path} (#{built_n} element(s) built; " \
     "#{by_sev['dropped'] || 0} dropped, #{by_sev['degraded'] || 0} degraded, " \
     "#{by_sev['approximated'] || 0} approximated)"

# ---- manual-residues.json — the G6 build-it ledger ---------------------------
# Phase 1e (extract-calc-fields.rb WINPROBE split) routes the STAYS-MANUAL
# window/table-calc residues (requires_custom_sql) to the Custom SQL path
# CORRECTLY — but nothing bound the routed measure to the tile that plots it:
# the build silently shipped the tile with a magnitude proxy and the divergence
# surfaced only at Phase 6 (~2h later; the single gap that kept run 2 YELLOW).
# This ledger names every requires_custom_sql calc that a png-read tile (its
# `measure` — string or {"manual_residue": "<calc>"} — or its worksheet's
# measure shelf) declares as its measure:
#   { calc, formula, tile, suggested_sql (OVER() skeleton), status: "unbuilt" }
# The orchestrator BLOCKS pass-1 completion on 'unbuilt' entries (exit 16) and
# assert-phase6-ran refuses GREEN until each is 'built' (or waived via
# --accept-manual-residues). Statuses are MERGED across re-builds by
# (calc, tile) so a bound residue never resets to 'unbuilt'.
begin
  _mr_nk = ->(s) { s.to_s.upcase.gsub(/[^0-9A-Z]/, '') }
  _cf = (JSON.parse(File.read(File.join(opts[:tab], 'calc-fields.json'))) rescue nil)
  _residue_calcs = Array(_cf.is_a?(Hash) ? _cf['calcs'] : nil)
                   .select { |c| c.is_a?(Hash) && c['requires_custom_sql'] && !c['name'].to_s.strip.empty? }
  _prd = (JSON.parse(File.read(DashboardRead.path(opts[:tab]))) rescue nil)
  _mr_tiles = Array(_prd.is_a?(Hash) ? _prd['tiles'] : nil).select { |t| t.is_a?(Hash) }
  _ledger_path = File.join(opts[:tab], 'manual-residues.json')
  if _residue_calcs.any? && _mr_tiles.any?
    # ANSI OVER() hints for the STAYS-MANUAL family (refs/window-functions.md).
    _ansi = {
      'FIRST' => 'FIRST_VALUE(<expr>)', 'LAST' => 'LAST_VALUE(<expr>)',
      'SIZE' => 'COUNT(*)', 'PREVIOUS_VALUE' => 'LAG(<expr>, 1)',
      'RANK_UNIQUE' => 'ROW_NUMBER()', 'RANK_MODIFIED' => 'RANK()',
      'WINDOW_MEDIAN' => 'MEDIAN(<expr>)',
      'WINDOW_PERCENTILE' => 'PERCENTILE_CONT(<p>) WITHIN GROUP (ORDER BY <expr>)',
      'WINDOW_STDEVP' => 'STDDEV_POP(<expr>)', 'WINDOW_VARP' => 'VAR_POP(<expr>)',
      'WINDOW_VAR' => 'VAR_SAMP(<expr>)', 'WINDOW_CORR' => 'CORR(<x>, <y>)',
      'WINDOW_COVARP' => 'COVAR_POP(<x>, <y>)', 'WINDOW_COVAR' => 'COVAR_SAMP(<x>, <y>)',
      'LOOKUP' => 'LAG/LEAD(<expr>, <n>)' # rides along inside MANUAL chains (e.g. LOOKUP(..., FIRST()))
    }
    _suggest = lambda do |calc|
      # v5.6 (calc-flex item 4): extract-calc-fields emits READY grouped-helper
      # SQL for named auto-translatable subclasses (manual_subclass:
      # 'index-to-first', LOOKUP(agg, FIRST())). Prefer it over the generic
      # skeleton so the build-it checklist carries paste-ready SQL.
      ready = calc['suggested_sql'].to_s
      next ready unless ready.strip.empty?
      fns = _ansi.keys.select { |fn| calc['formula'].to_s =~ /\b#{Regexp.escape(fn)}\s*\(/i }
      lines = ["-- Custom SQL (OVER()) skeleton for \"#{calc['name']}\" — replace every <...>;",
               '-- route: refs/phase-3-datamodel.md "Custom SQL data-model element" + refs/window-functions.md']
      lines += fns.map { |fn| "--   #{fn} -> #{_ansi[fn]} OVER (PARTITION BY <pane dims> ORDER BY <axis dim>)" }
      lines << %(SELECT <tile dims>, <axis dim>, <window expr for the Tableau formula> AS "#{calc['name']}")
      lines << 'FROM ( SELECT <tile dims>, <axis dim>, <base aggregates> FROM <landed fact table>'
      lines << '       GROUP BY <tile dims>, <axis dim> ) t'
      lines.join("\n")
    end
    _entries = []
    _mr_tiles.each do |t|
      title = t['title'].to_s
      cands = []
      m = t['measure']
      if m.is_a?(Hash)
        cands << m['manual_residue'].to_s
      elsif m
        cands << m.to_s
      end
      cands.concat(Array(t['measures']).map(&:to_s)) if t['measures'].is_a?(Array)
      # The tile's WORKSHEET measure shelf: a residue plotted as [Calculation_N]
      # resolves to its caption via the worksheet's calculations list.
      wsm = meta['worksheets'] || {}
      wm = wsm[title] || (wsm.find { |k, _| _mr_nk.call(k) == _mr_nk.call(title) } || []).last
      if wm.is_a?(Hash)
        calc_caps = {}
        Array(wm['calculations']).each do |c|
          next unless c.is_a?(Hash)
          nm = c['name'].to_s.gsub(/\A\[|\]\z/, '')
          calc_caps[nm] = c['caption'].to_s.empty? ? nm : c['caption'].to_s
        end
        Array(wm['measures']).each do |mm|
          col = (mm.is_a?(Hash) ? mm['column'] : mm).to_s.gsub(/\A\[|\]\z/, '')
          cands << (calc_caps[col] || col)
        end
      end
      cand_keys = cands.map { |c| _mr_nk.call(c) }.reject(&:empty?)
      _residue_calcs.each do |c|
        next unless cand_keys.include?(_mr_nk.call(c['name']))
        _entries << { 'calc' => c['name'], 'formula' => c['formula'], 'tile' => title,
                      'suggested_sql' => _suggest.call(c), 'status' => 'unbuilt' }
      end
    end
    _entries.uniq! { |e| [e['calc'], e['tile']] }
    # Merge prior statuses (a residue marked 'built' stays built on re-build).
    _prev = (JSON.parse(File.read(_ledger_path)) rescue nil)
    _prev_entries = _prev.is_a?(Hash) ? Array(_prev['residues']) : Array(_prev)
    _prev_by_key = {}
    _prev_entries.each { |e| _prev_by_key[[e['calc'].to_s, e['tile'].to_s]] = e if e.is_a?(Hash) }
    _entries.each do |e|
      old = _prev_by_key[[e['calc'], e['tile']]]
      next unless old
      e['status'] = old['status'] unless old['status'].to_s.strip.empty?
      e['note'] = old['note'] if old['note']
    end
    if _entries.any? || File.exist?(_ledger_path)
      File.write(_ledger_path, JSON.pretty_generate('version' => 1, 'residues' => _entries))
      if _entries.any?
        _n_unbuilt = _entries.count { |e| e['status'] == 'unbuilt' }
        warn "manual-residues: #{_entries.size} window/table-calc residue(s) plotted by dashboard tiles " \
             "(#{_n_unbuilt} unbuilt — pass-1 BLOCKS until built/waived) -> #{_ledger_path}"
      end
    end
  end
rescue StandardError => e
  warn "WARN: manual-residues ledger skipped (#{e.class}: #{e.message})"
end
