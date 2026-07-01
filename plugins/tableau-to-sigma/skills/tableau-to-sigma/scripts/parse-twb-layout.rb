#!/usr/bin/env ruby
# Parse the dashboard layout out of a .twb XML file.
#
# The dashboard image PNG only shows pixels; the .twb XML carries the actual
# zone tree with chart positions, captions, underlying view refs, AND the chart
# kind (bar / line / pie / map / etc.) via the worksheet's <mark> element.
# Reading this BEFORE building the workbook spec prevents the common Phase 5
# miss: dropping the dashboard title, filter shelf, or any pie/donut/map tile
# whose chart-kind isn't visible in the view CSV.
#
# Usage:
#   ruby scripts/parse-twb-layout.rb /tmp/<name>/workbook-content.twb \
#                                    /tmp/<name>/dashboard-layout.json
#
# Output (one JSON object per dashboard):
#   {
#     "dashboard": "Orders Overview",
#     "zones": [
#       { "id":"3", "kind":"chart", "caption":"Revenue by Region",
#         "x_pct":0, "y_pct":29.7, "w_pct":35.5, "h_pct":31.5,
#         "view_ref":"[federated.xxx].[…]",
#         "chart_kind":"bar", "mark_class":"Bar",
#         "geo_role":null },
#       { "id":"26", "kind":"chart", "caption":"Order Channel vs Ship Method",
#         "chart_kind":"pie", "mark_class":"Pie", ... },
#       { "id":"57", "kind":"text", "caption":null, ... },
#       { "id":"71", "kind":"filter", "caption":"Revenue by Region", ... }
#     ]
#   }
#
# `chart_kind` is the Sigma-relevant chart type derived from the worksheet's
# <mark class="..."> element plus a check for geographic encoding roles. Map to
# Sigma kinds with the table in refs/workbook-layout.md.

require 'json'
# Nokogiri-backed REXML drop-in — REXML is O(n^2) on large .twb files; twb_xml.rb
# parses a 5 MB / 95-worksheet workbook in well under a second. See lib/twb_xml.rb.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'

# ---- Per-dashboard scoping ------------------------------------------------
# `--dashboard "<name>"` (repeatable) and `--page <id>` let a LARGE workbook
# (14+ dashboards) be migrated ONE tab at a time: only the matching
# dashboard(s) are emitted in the layout JSON, and the *-meta.json worksheets /
# shared_filters are scoped to those used by the selected dashboard(s). No
# filter ⇒ current behavior (all dashboards, full meta). The dashboard name
# match is case-insensitive and accepts either an exact match or a unique
# substring (so `--dashboard "Regional"` resolves a long Tableau caption).
# `--page <id>` filters on the dashboard's zone-root id (rarely needed; name is
# the ergonomic handle) and is treated as an additional accepted token.
DASHBOARD_FILTERS = []
PAGE_FILTERS = []
positional = []
i = 0
while i < ARGV.length
  a = ARGV[i]
  case a
  when '--dashboard'
    DASHBOARD_FILTERS << ARGV[i + 1].to_s
    i += 2
  when '--page'
    PAGE_FILTERS << ARGV[i + 1].to_s
    i += 2
  else
    positional << a
    i += 1
  end
end

INP = positional[0] || abort('usage: parse-twb-layout.rb <workbook-content.twb> <out.json> [--dashboard "<name>"] [--page <id>]')
OUT = positional[1] || abort('usage: parse-twb-layout.rb <workbook-content.twb> <out.json> [--dashboard "<name>"] [--page <id>]')

# True when no scoping requested → keep every dashboard (current behavior).
def dashboard_scoping?
  !DASHBOARD_FILTERS.empty? || !PAGE_FILTERS.empty?
end

# Decide whether a dashboard (by name + zone-root id) is in scope. Name match is
# case-insensitive exact OR unique substring; page match is exact on the id.
def dashboard_in_scope?(name, page_id)
  return true unless dashboard_scoping?
  n = name.to_s.downcase
  name_hit = DASHBOARD_FILTERS.any? do |f|
    fl = f.downcase
    n == fl || (!fl.empty? && n.include?(fl))
  end
  page_hit = PAGE_FILTERS.any? { |p| !p.empty? && p == page_id.to_s }
  name_hit || page_hit
end

xml = TwbXml.parse(File.read(INP))

def pct(v)
  return nil if v.nil?
  (v.to_f / 1_000.0).round(1)   # Tableau: 100000 == 100%
end

# ---- Column GUID → caption resolver ---------------------------------------
# Tableau filters reference columns by GUID (e.g.,
# `[federated.X].[none:c2ec6b07-...:qk]`). To translate a filter into a Sigma
# control we need the human-readable caption ("Region") plus the data type
# (categorical / date / numeric). Both live on <column> elements throughout the
# .twb (datasource-dependencies blocks AND the top-level metadata-records).
#
# We build a single lookup: { "c2ec6b07-..." => { caption:, datatype: } }.
COL_BY_GUID = {}
xml.elements.each('//column') do |c|
  raw = c.attributes['name'].to_s
  cap = c.attributes['caption']
  dt  = c.attributes['datatype']
  next if raw.empty?
  # Names look like `[guid]`, `[guid (foo)]`, `[Friendly Name]`,
  # `[Calculation_123]`, or a Tableau group/copy `[Partner Level (group)]`.
  # Strip surrounding brackets.
  body = raw.sub(/^\[/, '').sub(/\]$/, '')
  # GUID-shaped heads (hex UUID, possibly `(suffix)`-tagged) and Calculation_
  # ids resolve via their leading token — keep the historical head-split so
  # instance refs that quote only the GUID still match. These are only useful
  # when a caption exists (the GUID itself is not human-readable).
  if body =~ /\A([0-9a-f]{8}-[0-9a-f\-]{20,}|Calculation_\d+)/i
    head = body.split(/\s/, 2).first
    COL_BY_GUID[head] ||= { caption: cap, datatype: dt } if cap && !cap.empty?
  else
    # Friendly / group / copy names are referenced VERBATIM by their full body
    # (e.g. instance ref `[none:Customer Geo:nk]` → "Customer Geo", filter
    # `[Partner Level (group)]` → "Partner Level (group)"). Register under the
    # FULL body — NOT the first word — or multi-word names ("Customer Geo")
    # collapse to "Customer" and never resolve. Plain warehouse columns carry NO
    # caption attribute (their name IS the display name), so fall the caption
    # back to the body; that is the fix for the ~40 EDNA quick-filters that were
    # silently dropped ("shared filter has no resolvable column_caption").
    COL_BY_GUID[body] ||= { caption: (cap && !cap.empty? ? cap : body), datatype: dt }
  end
end

# Filter columns use a column-instance level reference like
#   `[federated.X].[none:c2ec6b07-...:qk]`
# where `none` is the derivation and `qk`/`nk` is pivot/key qualifier. Strip
# both and extract the column id.
#
# Two id shapes occur:
#   - raw warehouse columns → a 36-char hex GUID (`c2ec6b07-...`)
#   - CALCULATED fields      → the calc's internal id (`Calculation_<digits>`)
# Both are registered in COL_BY_GUID (the latter keyed by its `Calculation_…`
# head), so resolving either form lets a filter bound to a calc field surface a
# real caption instead of being silently dropped by the auto-control builder
# ("shared filter has no resolvable column_caption"). The raw-GUID behaviour is
# unchanged — we only add the calc-id alternative.
#   - raw warehouse columns by FRIENDLY NAME (`none:Region:nk`) — simple
#     columns whose instance ref uses the column name rather than a GUID; the
#     friendly head (`Region`) is registered in COL_BY_GUID too.
def guid_from_param(param)
  return nil if param.nil? || param.empty?
  # Friendly/group/copy names carry parens, slashes ("Mkt Sourced/Influenced"),
  # hyphens, ampersands, and trailing `(copy)_<digits>` / `(group)` suffixes —
  # the friendly char class keeps them all so refs like `[Partner Level
  # (group)]`, `[none:Region (copy)_4720…:nk]`, and `[none:Mkt
  # Sourced/Influenced:nk]` resolve instead of returning nil (which dropped
  # those quick-filters entirely). `:` stays excluded — it's the structural
  # `<deriv>:<name>:<qual>` delimiter.
  m = param.match(%r{\.\[(?:[a-z\-]+:)?([0-9a-f\-]{36}|Calculation_\d+|[A-Za-z_][\w. ()/&-]*)(?::[a-z]+)?\]$}i)
  m && m[1]
end

# Strip Tableau's quoted-string member encoding (`&quot;CA&quot;` → `CA`).
def unquote_member(s)
  return nil if s.nil?
  s = s.to_s.gsub('&quot;', '"').strip
  return nil if s == '%null%'
  s.sub(/^"/, '').sub(/"$/, '')
end

# Read a <filter> element and emit a normalized spec:
#   { kind: "list" | "date-range" | "relative-date" | "number-range" | "action" | "unknown",
#     column_guid: "...", column_caption: "...", datatype: "string|date|real|integer|...",
#     members: ["CA","NY",...]  (for list)
#     min/max: numbers           (for number-range)
#     first_period/last_period/period_type/include_future/include_null  (relative-date)
#     raw_param: ...,
#     is_action: true|false }
def normalize_filter(f)
  cls   = f.attributes['class'].to_s
  param = f.attributes['column'].to_s
  is_action = param.include?('[Action ') || param.include?('[Action(')
  guid  = guid_from_param(param)
  info  = guid ? COL_BY_GUID[guid] : nil

  # Caption fallback: when the ref resolved to a friendly name (not a hex GUID /
  # Calculation_ id) but no <column> def registered it, the extracted token IS
  # the display name — use it rather than dropping the filter as "unresolvable".
  # Strip Tableau's `(copy)_<digits>` / `(group)` decorations for a clean label.
  friendly = guid && guid !~ /\A([0-9a-f]{8}-[0-9a-f\-]{20,}|Calculation_\d+)\z/i
  fallback_caption =
    if friendly
      guid.sub(/\s*\(copy\)_\d+\z/i, '').sub(/\s*\(group\)\z/i, ' (group)').strip
    end

  out = {
    'raw_class'      => cls,
    'raw_param'      => param,
    'column_guid'    => guid,
    'column_caption' => (info && info[:caption]) || fallback_caption,
    'datatype'       => info && info[:datatype],
    'is_action'      => is_action
  }

  if is_action
    out['kind'] = 'action'
    return out
  end

  case cls
  when 'categorical'
    members = []
    f.each_element('.//groupfilter') do |gf|
      next unless gf.attributes['function'] == 'member'
      m = unquote_member(gf.attributes['member'])
      members << m if m
    end
    out['kind']    = 'list'
    out['members'] = members
  when 'relative-date'
    out['kind']           = 'relative-date'
    out['first_period']   = f.attributes['first-period']
    out['last_period']    = f.attributes['last-period']
    out['period_type']    = f.attributes['period-type-v2'] || f.attributes['period-type']
    out['include_future'] = f.attributes['include-future']
    out['include_null']   = f.attributes['include-null']
  when 'quantitative'
    out['kind'] = 'number-range'
    out['min'] = f.attributes['min']
    out['max'] = f.attributes['max']
  else
    out['kind'] = 'unknown'
  end
  out
end

# ---- Rows/Cols shelf parsing (pivot-table detection) ----------------------
# Tableau worksheets carry their shelf state inside <table>:
#   <rows>[federated.X].[REGION] / [federated.X].[CATEGORY]</rows>
#   <cols>[federated.X].[yr:ORDER_DATE:ok] / [federated.X].[sum:SALES:qk]</cols>
# Each field is separated by ` / `. The bracketed spec carries a prefix that
# tells us role:
#   `[FIELDNAME]` (no prefix)                 → dim
#   `[none:GUID:nk]` / `[none:GUID:qk]`       → dim (Tableau's "no aggregation")
#   `[yr|qr|mn|wk|dy|hr|mi|sc:GUID:ok]`       → date-trunc dim
#   `[mdy|md|qd|ymd|y|q|m|d|w|h|s:...]`       → date-part dim
#   `[sum|avg|min|max|count|countd|cntd|median|stdev|stdevp|var|varp|attr|usr:...]`
#                                              → measure
#   `[Measure Names]` literal                  → placeholder, skip
#
# Detection rule for pivot-table:
#   - mark in {Text, Square} (necessary)
#   - rows AND cols each carry ≥1 real dim                       → pivot-table
#   - OR one shelf has a real dim + the other has Measure Names
#     plus the worksheet has ≥2 measures                          → pivot-table
#   - Otherwise (one shelf empty, or both empty)                  → table
MEASURE_PREFIXES = %w[sum avg min max count countd cntd median stdev stdevp var varp attr usr].freeze
DATE_TRUNC_PREFIXES = %w[yr qr mn wk dy hr mi sc mdy md qd ymd y q m d w h s].freeze

# Classify a single shelf-field bracketed spec like "none:GUID:qk" or "sum:GUID:qk"
# or "REGION" (no prefix). Returns [:dim | :measure | :measure_names, derivation_or_nil].
def classify_shelf_field(field_str)
  return [:skip, nil] if field_str.nil? || field_str.strip.empty?
  fs = field_str.strip
  # Bare "[Measure Names]" or ".[Measure Names]" → placeholder
  return [:measure_names, nil] if fs =~ /\bMeasure\s*Names\b/i
  # Extract the inner spec — the last `[...]` segment
  spec = fs[/\[([^\[\]]*)\]\s*$/, 1] || fs
  # Aggregation/trunc prefix form: "prefix:GUID:type"
  if (m = spec.match(/^([a-z]+):.*?:[a-z]+$/i))
    pref = m[1].downcase
    return [:measure, pref] if MEASURE_PREFIXES.include?(pref)
    return [:dim, pref]     if DATE_TRUNC_PREFIXES.include?(pref)
    return [:dim, pref]     if pref == 'none'
    return [:dim, pref]     # unknown prefix → conservative dim
  end
  # No prefix → dim (e.g. "[REGION]")
  [:dim, nil]
end

# Parse a `<rows>` or `<cols>` shelf string into a structured summary.
def parse_shelf(shelf_str)
  out = { 'raw' => shelf_str, 'fields' => [], 'dim_count' => 0,
          'measure_count' => 0, 'has_measure_names' => false,
          'has_measure_values' => false }
  return out if shelf_str.nil? || shelf_str.strip.empty?
  # The Measure-VALUES pill (`[Multiple Values]` / `[Measure Values]`) signals
  # measures placed on this shelf as a VISUAL encoding (bar lengths / line
  # values). Detect it from the RAW string as a flag — NOT as a per-field role —
  # because a shelf can hold it ALONGSIDE a real measure pill
  # (`([Multiple Values] + [usr:Calc:qk])`), and classifying the whole field as
  # measure-values would drop that real measure and break line/bar inference.
  out['has_measure_values'] = true if shelf_str =~ /\[(?:Multiple|Measure)\s+Values\]/i
  shelf_str.split('/').each do |f|
    # Nested shelves wrap the field list in parens —
    #   `([ds].[none:A:nk] / [ds].[none:B:nk])`
    # — so split('/') leaves a leading '(' on the first field and a trailing
    # ')' on the last. Strip surrounding parens/whitespace; otherwise
    # guid_from_param / classify_shelf_field (both anchored on a trailing ']')
    # miss, and the nested dim keeps its raw federated GUID and POSTs as a
    # broken `[Master/<guid>:nk])` dependency. (Field refs never contain
    # parens, so this is safe for flat and ≥2-level nested shelves alike.)
    raw_field = f.strip.gsub(/\A[(\s]+/, '').gsub(/[)\s]+\z/, '')
    next if raw_field.empty?
    role, deriv = classify_shelf_field(raw_field)
    case role
    when :dim
      out['dim_count'] += 1
      out['fields'] << { 'raw' => raw_field, 'role' => 'dim', 'derivation' => deriv,
                         'guid' => guid_from_param(raw_field) }
    when :measure
      out['measure_count'] += 1
      out['fields'] << { 'raw' => raw_field, 'role' => 'measure', 'derivation' => deriv,
                         'guid' => guid_from_param(raw_field) }
    when :measure_names
      out['has_measure_names'] = true
      out['fields'] << { 'raw' => raw_field, 'role' => 'measure-names' }
    end
  end
  out
end

# Build a lookup of worksheet name → metadata extracted from <worksheet> elements.
# - mark_class: the <mark class="..."> value (Bar / Line / Pie / Filled / Circle / etc.)
# - geo_role:   the first geographic semantic-role we find on any column (e.g. "geo:state")
# - has_lat / has_long: heuristic for point-map detection (column names contain
#   "latitude" / "longitude")
# - rows_shelf / cols_shelf: structured summary of dims/measures on each shelf
# - is_crosstab: convenience flag — true when the worksheet is a Tableau crosstab
#   (Text/Square mark + dims on both shelves, or Measure Names crosstab)
# Top-level datasource calc definitions — the SOURCE OF TRUTH for a calc's
# formula. Worksheet <datasource-dependencies> blocks carry CACHED copies that
# go stale when the calc is later edited in the datasource (caught live on
# WINPROBE: the funnel's [Return Rate] dependency block said SUM/COUNTD while
# the top-level datasource — and Tableau's actual evaluation + CSV export —
# said SUM/COUNT). Keyed by internal column name; used to OVERRIDE the
# per-worksheet formula on name match.
ds_calc_formulas = {}
xml.elements.each('/workbook/datasources/datasource') do |ds|
  ds_label = (ds.attributes['caption'] || ds.attributes['name']).to_s
  next if ds_label.start_with?('Parameter')
  ds.elements.each('column') do |col|
    calc = col.elements['calculation']
    next unless calc && calc.attributes['class'] == 'tableau'
    f = calc.attributes['formula']
    next if f.nil? || f.empty?
    ds_calc_formulas[col.attributes['name'].to_s] = f
  end
end

worksheets = {}
xml.elements.each('//worksheet') do |ws|
  name = ws.attributes['name']
  next unless name
  mark = ws.elements['.//mark']
  mark_class = mark ? (mark.attributes['class'].to_s) : nil

  geo_role = nil
  has_lat  = false
  has_long = false
  has_geometry = !ws.elements['.//geometry'].nil?
  ws.elements.each('.//column') do |col|
    # Tableau's `semantic-role` attribute on a column carries the geographic
    # assignment when one is set. Patterns we've seen in the wild:
    #   [Country].[ISO3166_2]      [State].[Country].[State]
    #   [State/Province].[Name]    [City].[Country].[Name]
    #   [County].[Country].[Name]  [Zip Code].[Country].[Zip]
    # If the attribute is present at all, the column carries a geo assignment.
    role = col.attributes['semantic-role'] || col.attributes['semanticRole']
    if role && !role.to_s.empty?
      geo_role ||= role
    end
    nm = col.attributes['caption'] || col.attributes['name'] || ''
    has_lat  = true if nm =~ /latitude/i
    has_long = true if nm =~ /longitude/i
  end

  # Per-worksheet sort. <sort> element under the worksheet carries direction
  # ("ascending"|"descending") and a `column` attribute referencing the sorted
  # dimension. We emit the first sort we find (Tableau allows multiple but
  # downstream tooling almost always wants the primary one).
  sort_info = nil
  if (s = ws.elements['.//sort'])
    sort_info = {
      direction: s.attributes['direction'],
      column:    s.attributes['column']
    }
  end
  # "Sort field X by measure Y" lands as <computed-sort column='<dim ref>'
  # direction='ASC|DESC' using='<measure column-instance ref>'/> — a DIFFERENT
  # element from <sort>. Window-function worksheets (pareto / rank) rely on it:
  # Sigma Cumulative* / Rank follow the chart's xAxis sort, so dropping the
  # computed-sort silently re-accumulates in natural order and every cumulative
  # value diverges. `using` is carried so build-charts can sort by the measure.
  if sort_info.nil? && (cs = ws.elements['.//computed-sort'])
    sort_info = {
      direction: (cs.attributes['direction'].to_s =~ /desc/i ? 'descending' : 'ascending'),
      column:    cs.attributes['column'],
      using:     cs.attributes['using']
    }
  end

  # Per-worksheet view-level filters. Each filter is normalized via
  # normalize_filter (resolves GUID → caption + datatype, extracts member values
  # for categorical, period spec for relative-date, min/max for quantitative,
  # and flags action filters separately).
  filters_info = []
  ws.elements.each('.//filter') do |f|
    filters_info << normalize_filter(f)
  end

  # Per-column aggregation override. <column-instance derivation="Sum|Avg|Min|
  # Max|Median|CountD|None|User|Month-Trunc|Year-Trunc|..."> tells us what
  # aggregation Tableau is using for that column in the pane. We expose all of
  # them; the agent decides which are interesting (non-default).
  aggregations = {}
  ws.elements.each('.//column-instance') do |ci|
    col = ci.attributes['column']
    deriv = ci.attributes['derivation']
    next if col.nil? || deriv.nil?
    aggregations[col.to_s] = deriv.to_s
  end

  # Per-column format strings. Tableau emits these via
  #   <style-rule element='cell'>
  #     <format attr='text-format' field='[federated.X].[col-ref]' value='p0.0%' />
  # We capture the value verbatim keyed by the field reference. translate_format
  # below converts to Sigma's d3-format string.
  formats = {}
  ws.elements.each('.//format') do |fmt|
    next unless fmt.attributes['attr'] == 'text-format'
    field = fmt.attributes['field']
    val   = fmt.attributes['value']
    next if field.nil? || val.nil?
    formats[field.to_s] = val.to_s
  end

  # Per-worksheet dual-axis / synchronized-axis detection. Tableau combo charts
  # ship two measures on the same dim shelf and a `synchronized='true'`
  # attribute on the axis encoding inside <style-rule element='axis'>. We surface:
  #   dual_axis: bool       — true if any axis has synchronized='true' or there
  #                            are 2+ distinct quantitative measures
  #   measures:  [{column, derivation}]
  axis_synced = false
  # Axis range/scale/log overrides. Tableau emits these inside
  #   <style-rule element='axis'><encoding attr='space' .../></style-rule>
  # Attributes we extract:
  #   scope='rows'|'cols'           → which Sigma axis: rows→yAxis, cols→xAxis
  #   class='0'|'1'                 → axis index: 0=primary, 1=secondary (dual-axis)
  #   scale='log'                   → log scale (otherwise linear)
  #   range-type='fixed'|'automatic'→ when 'fixed', honor min/max
  #   min='...' max='...'           → numeric bounds (only meaningful when fixed)
  # Verified against "Orders Conversion Test" workbook (2026-05-22).
  axis_formats = []
  ws.elements.each('.//style-rule[@element="axis"]/encoding') do |e|
    a = e.attributes
    if a['synchronized'].to_s == 'true'
      axis_synced = true
    end
    next unless a['attr'].to_s == 'space'
    next unless %w[rows cols].include?(a['scope'].to_s)
    af = {
      'scope'      => a['scope'].to_s,
      'class'      => a['class'].to_s,
      'scale'      => a['scale']&.to_s,
      'range_type' => a['range-type']&.to_s,
      'field'      => a['field']&.to_s
    }
    af['min'] = a['min'].to_f if a['min']
    af['max'] = a['max'].to_f if a['max']
    axis_formats << af.compact
  end
  measures = []
  ws.elements.each('.//column-instance') do |ci|
    col = ci.attributes['column']
    deriv = ci.attributes['derivation']
    next if col.nil? || deriv.nil?
    next unless ci.attributes['type'] == 'quantitative'
    # 'None' = raw (non-aggregated) usage — not a measure. 'User' IS a measure:
    # a user-aggregated calc field (ratio KPIs like Gross Margin Pct). Excluding
    # it made every calc-measure KPI read as 0-measure and fall through to the
    # flat-table flow (bead 3w4d — "CSV has only 1 column" KPI drops).
    next if deriv == 'None'
    measures << { 'column' => col.to_s, 'derivation' => deriv.to_s }
  end
  # Conservative: only flag dual_axis when Tableau explicitly synchronized two
  # axes. Multi-measure worksheets without sync are usually pivot tables or
  # measure-name shelves, not combo charts.
  dual_axis = axis_synced

  # Per-worksheet reference lines / bands / distributions / trendlines.
  # Surface enough metadata for build-charts-from-signals.rb to emit Sigma
  # refMarks / trendlines blocks per the new chart spec (2026-05-21):
  #
  #   - formula:      "average" | "median" | "max" | "min" | "sum" | "count" | "constant" | "attr" | ...
  #   - axis_column:  Tableau axis-column ref (column the line is anchored to)
  #   - value_column: column the formula evaluates against (often same as axis-column)
  #   - label:        custom label text (with <Value> template) or nil
  #   - label_type:   "custom" | "none" | "computation" | ...
  #   - scope:        "per-table" | "per-pane" | "per-cell"
  #   - band_values:  array of percentage thresholds for percentage-bands
  #   - fill_above / fill_below / percentage_bands / symmetric: band styling flags
  def extract_ref_line_attrs(node, kind)
    a = node.attributes
    info = {
      'kind'         => kind,
      'formula'      => a['formula'],
      'axis_column'  => a['axis-column'],
      'value_column' => a['value-column'],
      'label'        => a['label'],
      'label_type'   => a['label-type'],
      'scope'        => a['scope']
    }
    info['fill_above']        = a['fill-above']        if a['fill-above']
    info['fill_below']        = a['fill-below']        if a['fill-below']
    info['percentage_bands']  = a['percentage-bands']  if a['percentage-bands']
    info['symmetric']         = a['symmetric']         if a['symmetric']
    info['probability']       = a['probability']       if a['probability']
    band_vals = node.elements.to_a('.//reference-line-value').map { |v| v.attributes['percentage'] }.compact
    info['band_values'] = band_vals unless band_vals.empty?
    info.compact
  end

  ref_marks = []
  ws.elements.each('.//reference-line')        { |n| ref_marks << extract_ref_line_attrs(n, 'line') }
  ws.elements.each('.//reference-band')        { |n| ref_marks << extract_ref_line_attrs(n, 'band') }
  ws.elements.each('.//reference-distribution'){ |n| ref_marks << extract_ref_line_attrs(n, 'distribution') }
  ws.elements.each('.//trendline-model') do |n|
    a = n.attributes
    ref_marks << {
      'kind'    => 'trendline',
      'model'   => a['model-type'] || a['model'] || 'linear',
      'field_x' => a['field-x'],
      'field_y' => a['field-y']
    }.compact
  end

  # Encoding channels (color / size / detail / shape / label / tooltip).
  # Color is the key one for multi-series approximations (Sales by Segment etc).
  channels = {}
  ws.elements.each('.//encodings/encoding') do |e|
    attr = e.attributes['attr']
    next unless %w[color size shape detail label tooltip text].include?(attr.to_s)
    channels[attr.to_s] = {
      column: e.attributes['column'],
      field:  e.attributes['field']
    }
  end

  # Per-worksheet calculated fields. Tableau emits these as
  #   <column datatype='X' name='[Calc Name]' role='dimension|measure' type='...'>
  #     <calculation class='tableau' formula='...' />
  #   </column>
  # We surface them so the build script can flag (or translate) calcs that are
  # used by this worksheet's chart.
  calcs = []
  ws.elements.each('.//column') do |col|
    calc = col.elements['calculation']
    next unless calc
    cls  = calc.attributes['class']
    formula = calc.attributes['formula']
    next if formula.nil? || formula.empty?
    entry = {
      'name'    => col.attributes['name'],
      'caption' => col.attributes['caption'],
      'datatype'=> col.attributes['datatype'],
      'role'    => col.attributes['role'],
      'class'   => cls,
      'formula' => formula
    }
    # Tableau numeric bins are calc columns with class='bin': `formula` is the
    # base field ref, `size` (or a `size-parameter` ref) is the bin width and
    # `peg` the bin origin. Surfaced so build-charts-from-signals.rb can emit
    # the Sigma-native BinFixed/BinRange translation (beads-sigma-t67b).
    if cls == 'bin'
      entry['bin_size'] = calc.attributes['size'] || calc.attributes['size-parameter']
      entry['bin_peg']  = calc.attributes['peg']
    end
    # Stale-dependency override: the top-level datasource definition wins over
    # the worksheet's cached copy (see ds_calc_formulas above).
    ds_f = ds_calc_formulas[col.attributes['name'].to_s]
    if cls == 'tableau' && ds_f && ds_f != formula
      entry['stale_dependency_formula'] = formula
      entry['formula'] = ds_f
    end
    calcs << entry
  end

  # Worksheet-level "Show Mark Labels" toggle. Tableau emits this on the
  # worksheet's pane style:
  #   <pane><style><style-rule element='mark'>
  #     <format attr='mark-labels-show' value='true' />
  # Verified against "Orders Conversion Test" workbook (2026-05-22).
  mark_labels_show = false
  ws.elements.each(".//pane//style-rule[@element='mark']/format") do |f|
    if f.attributes['attr'].to_s == 'mark-labels-show' && f.attributes['value'].to_s == 'true'
      mark_labels_show = true
      break
    end
  end

  # Rows/Cols shelf parsing for pivot-table detection. Tableau emits these as
  # sibling elements under <table> in the worksheet. We pick the first match
  # (worksheets rarely have multiples).
  rows_node  = ws.elements['.//table/rows'] || ws.elements['.//rows']
  cols_node  = ws.elements['.//table/cols'] || ws.elements['.//cols']
  rows_shelf = parse_shelf(rows_node&.text)
  cols_shelf = parse_shelf(cols_node&.text)

  # Crosstab signal:
  #   (a) explicit Text/Square mark with ≥1 real dim on BOTH shelves, OR a
  #       Measure-Names shelf (≥2 measures + ≥1 dim) — the mark is unambiguous, OR
  #   (b) Automatic/blank mark with Measure Names AND dims on BOTH shelves.
  # Measure Names on a shelf lays measures out as a text grid, and Tableau's
  # DEFAULT "Automatic" mark renders that grid as text — so a crosstab authored
  # without flipping the mark to "Text" reports mark_class="Automatic" (or blank).
  # Gating only on text/square missed every such table (EDNA's "Metric Partner
  # Closed Won" / "1T.PartnerClosed size&Status" → flat table/kpi, losing the
  # grouped quarter headers + Grand Total).
  #
  # BUT the AUTOMATIC relaxation excludes sheets carrying the Measure-VALUES pill
  # (`[Multiple Values]` / `[Measure Values]`) on a shelf: that places the
  # measures as a VISUAL encoding (bar lengths / line values), so an
  # Automatic-mark sheet with Measure Names on one shelf and Measure Values on the
  # other is a MULTI-MEASURE BAR, not a text crosstab (real-world catch: a public
  # "Barchart of accident factors" sheet — Measure Names on cols, `[Multiple
  # Values]` on rows — must stay a bar). A genuine text crosstab carries the
  # measure values on the Text marks card, never as a row/col pill. Explicit
  # Text/Square marks keep the lenient rule — the author's intent is unambiguous.
  is_text_mark = %w[text square].include?(mark_class.to_s.downcase)
  automatic_mark = mark_class.to_s.downcase == 'automatic' || mark_class.to_s.strip.empty?
  both_have_dims = rows_shelf['dim_count'] >= 1 && cols_shelf['dim_count'] >= 1
  shelf_has_measure_values = rows_shelf['has_measure_values'] || cols_shelf['has_measure_values']
  measure_names_crosstab =
    (rows_shelf['has_measure_names'] || cols_shelf['has_measure_names']) &&
    (rows_shelf['dim_count'] + cols_shelf['dim_count']) >= 1 &&
    (rows_shelf['measure_count'] + cols_shelf['measure_count'] + measures.size) >= 2
  is_crosstab = (is_text_mark && (both_have_dims || measure_names_crosstab)) ||
                (automatic_mark && measure_names_crosstab && !shelf_has_measure_values)

  # KPI signal: Text/Square/AUTOMATIC mark with ZERO dims on both shelves AND
  # ≥1 measure (on shelves or on the worksheet's Marks card). Tableau
  # "scorecard" / "big number" tiles match this shape — they're not detail
  # lists, not crosstabs, just a single aggregated value rendered as text.
  # Maps to Sigma kpi-chart. beads-sigma-bw3.
  # Automatic mark included (bead 3w4d): Tableau's default mark for a
  # zero-dim single-measure sheet renders as a big-number text table — the
  # FATSCALE rehearsal lost 14/40 tiles because these fell through to the
  # CSV-driven flow (1-column CSV → zone dropped).
  kpi_capable_mark = is_text_mark || mark_class.to_s.downcase == 'automatic' ||
                     mark_class.to_s.empty?
  total_dim_count = rows_shelf['dim_count'] + cols_shelf['dim_count']
  total_measure_count = rows_shelf['measure_count'] + cols_shelf['measure_count'] + measures.size
  is_kpi = kpi_capable_mark && !is_crosstab &&
           total_dim_count == 0 && total_measure_count >= 1

  # Hidden calc filters: worksheet-level filters whose target column is a
  # calculated field. These are invisible in Tableau CSV exports — they silently
  # reduce row counts and cause parity divergences with no warning. A filter is
  # "calc-targeted" when:
  #   - the column ref contains `Calculation_`
  #   - the column ref starts with `[Parameters.`
  #   - OR the resolved COL_BY_GUID entry matches a calc we know about
  # We walk the already-built filters_info (worksheet-level only, NOT
  # shared-view filters — those are dashboard-level).
  # Build a set of known calc column names from this worksheet's calcs plus
  # top-level datasource calcs for quick membership test.
  ws_calc_names = calcs.map { |c| c['name'].to_s }.to_set
  ws_calc_captions = calcs.map { |c| c['caption'].to_s }.reject(&:empty?).to_set
  hidden_filters = filters_info.select do |fi|
    raw = fi['raw_param'].to_s
    guid = fi['column_guid'].to_s
    # Check 1: raw param contains Calculation_ or Parameters.
    next true if raw =~ /Calculation_\d+/i
    next true if raw =~ /\[Parameters\./i
    # Check 2: resolved guid is a Calculation_ id
    next true if guid =~ /\ACalculation_\d+\z/i
    # Check 3: caption matches a known calc in this worksheet
    cap = fi['column_caption'].to_s
    next true if !cap.empty? && (ws_calc_captions.include?(cap) || ws_calc_names.include?("[#{cap}]"))
    false
  end.map do |fi|
    hf = {
      'calc_ref'    => fi['raw_param'],
      'caption'     => fi['column_caption'],
      'filter_type' => fi['raw_class'],
      'kind'        => fi['kind']
    }
    hf['members'] = fi['members'] if fi['kind'] == 'list' && fi['members']
    hf['min']     = fi['min']     if fi['min']
    hf['max']     = fi['max']     if fi['max']
    hf.compact
  end

  worksheets[name] = {
    mark_class:       mark_class,
    geo_role:         geo_role,
    has_lat:          has_lat,
    has_long:         has_long,
    has_geometry:     has_geometry,
    sort:             sort_info,
    filters:          filters_info,
    hidden_filters:   hidden_filters,
    aggregations:     aggregations,
    channels:         channels,
    formats:          formats,
    calculations:     calcs,
    dual_axis:        dual_axis,
    measures:         measures.uniq { |m| m['column'] },
    ref_marks:        ref_marks,
    axis_formats:     axis_formats,
    mark_labels_show: mark_labels_show,
    rows_shelf:       rows_shelf,
    cols_shelf:       cols_shelf,
    is_crosstab:      is_crosstab,
    is_kpi:           is_kpi
  }
end

# ---- Tableau format → Sigma format translator -----------------------------
# Tableau format codes (subset we see in the wild):
#   p0%      → ,.0%
#   p0.0%    → ,.1%
#   p0.00%   → ,.2%
#   0        → ,.0f
#   0.0      → ,.1f
#   #,##0    → ,.0f
#   $#,##0   → $,.0f (currency)
#   $#,##0.00→ $,.2f
#   yyyy-MM-dd → %Y-%m-%d
#   MMM yyyy   → %b %Y
#   yyyy       → %Y
def translate_format(tableau_fmt)
  s = tableau_fmt.to_s
  return nil if s.empty?
  # Tableau format strings can have multiple segments split by ';':
  #   positive;negative;zero;text
  # The negative segment encodes parens / explicit minus / [Red]. d3-format
  # supports a `(` sign modifier that wraps negatives in parens. We detect that
  # case and prepend `(` to the format string.
  segments = s.split(';')
  pos = segments[0] || s
  neg = segments[1]
  paren_negative = neg && neg.include?('(') && neg.include?(')')
  prefix = paren_negative ? '(' : ''

  # Percent — p<digits>[.<digits>]%
  if (m = pos.match(/^p\d*(?:\.(\d+))?%$/i))
    decimals = (m[1] || '').length
    return { 'kind' => 'number', 'formatString' => "#{prefix},.#{decimals}%" }
  end
  # Tableau locale-currency code — C<locale>[.<digits>]% (e.g., C1033% = $#,##0)
  if (m = pos.match(/^C\d+(?:\.(\d+))?%?$/))
    decimals = (m[1] || '').length
    return { 'kind' => 'number', 'formatString' => "#{prefix}$,.#{decimals}f", 'currencySymbol' => '$' }
  end
  # Currency — leading $ or c"$" / c\"$\"
  if pos =~ /^c?["\\]*\$/ || pos.start_with?('$')
    # Look for #...0.00 to extract decimals
    decimals = (pos.match(/\.(0+)/) || [])[1].to_s.length
    return { 'kind' => 'number', 'formatString' => "#{prefix}$,.#{decimals}f", 'currencySymbol' => '$' }
  end
  # Plain number — count decimals after the decimal point
  if pos =~ /^[#,0]+(?:\.(0+))?$/
    decimals = ($1 || '').length
    return { 'kind' => 'number', 'formatString' => "#{prefix},.#{decimals}f" }
  end
  # Date formats — translate Tableau tokens to strftime
  if s =~ /yyyy|MMM|MM|dd|HH/
    f = s
      .gsub('yyyy', '%Y').gsub('yy', '%y')
      .gsub('MMMM','%B').gsub('MMM','%b').gsub('MM','%m')
      .gsub('dd','%d').gsub('HH','%H').gsub('mm','%M').gsub('ss','%S')
    return { 'kind' => 'datetime', 'formatString' => f }
  end
  nil
end

# Translate Tableau mark class + geo signals into a Sigma-relevant chart-kind label.
# Returns one of:
#   bar | line | area | pie | scatter | map-region | map-point |
#   pivot-table | table | automatic | other
#
# Pivot vs table detection (mark in {Text, Square}):
#   - Dims on BOTH rows AND cols shelves → "pivot-table" (Tableau crosstab)
#   - Measure-Names crosstab pattern     → "pivot-table"
#   - Otherwise                           → "table" (flat detail list)
# The `is_crosstab` flag set during worksheet parsing carries this decision.
#
# Notes:
#   - "Automatic" is Tableau's default-pick-for-the-encodings. It usually renders
#     as a bar in our experience but is not deterministic; we emit "automatic" so
#     the agent KNOWS to look at the PNG before committing to a Sigma kind.
#   - Geographic encoding presence beats mark class for map detection.
# Tableau "Show Me" picks a mark for an Automatic worksheet deterministically
# from the shelf structure. Replicate the high-value rules so an Automatic sheet
# isn't blindly defaulted to a bar (the #1 first-pass fidelity miss — a time
# series silently became bars). Conservative: only fires for mark=Automatic;
# anything it can't classify still falls back to bar (and gets image-confirmed
# downstream, since the kind was inferred not declared).
DATE_GRAIN_DERIV = %w[tyr tqr tmn twk tdy thr tmi tsc yr qr mn wk dy hr mi sc].freeze
def infer_automatic_kind(meta)
  rs = meta[:rows_shelf] || {}
  cs = meta[:cols_shelf] || {}
  fields = (rs['fields'] || []) + (cs['fields'] || [])
  dims = fields.select { |f| f['role'] == 'dim' }
  meas = fields.select { |f| f['role'] == 'measure' }
  has_date_dim = dims.any? { |f| DATE_GRAIN_DERIV.include?(f['derivation'].to_s.downcase) }
  # 1) continuous date dimension + a measure → time-series LINE
  return 'line' if has_date_dim && !meas.empty?
  # 2) a measure on BOTH axes (rows AND cols), ≤1 dim → SCATTER
  return 'scatter' if rs['measure_count'].to_i >= 1 && cs['measure_count'].to_i >= 1 && dims.size <= 1
  # 3) categorical dim(s) + measure → BAR (Tableau's default for cat × measure)
  return 'bar' if !dims.empty? && !meas.empty?
  'bar'
end

def chart_kind_for(meta)
  return nil unless meta
  mc       = (meta[:mark_class] || '').downcase
  has_xy   = meta[:has_lat] && meta[:has_long]
  geo_mark = %w[multipolygon polygon filled map].include?(mc)

  # Map detection — STRONG signals only. Semantic-role on a column alone is not
  # enough: a column with a geographic semantic-role on the datasource flows into
  # every worksheet that uses it, including KPIs, bar charts, etc. that aren't
  # maps. Only trust:
  #   1. Mark class is one of the explicit map marks (Multipolygon / Polygon /
  #      Filled / Map). Tableau sets these when the worksheet renders as a map.
  #   2. <geometry> element present in the worksheet — auto-generated for filled
  #      maps from named regions (state / country / etc.).
  #   3. Both Latitude and Longitude column references — a lat/long symbol map.
  return 'map-region' if geo_mark || meta[:has_geometry]
  return 'map-point'  if has_xy

  case mc
  when 'bar'        then 'bar'
  when 'line'       then 'line'
  when 'area'       then 'area'
  when 'pie'        then 'pie'
  when 'circle'     then 'scatter'                # symbol marks (non-geo) = scatter
  when 'square'     then (meta[:is_crosstab] ? 'pivot-table' : (meta[:is_kpi] ? 'kpi' : 'table'))
  when 'text'       then (meta[:is_crosstab] ? 'pivot-table' : (meta[:is_kpi] ? 'kpi' : 'table'))
  when 'shape'      then 'scatter'
  # Automatic is Tableau's default-pick — but a zero-dim single-measure sheet
  # under Automatic renders as a big-number text table, i.e. a KPI (bead 3w4d).
  when 'automatic'
    # An Automatic-mark sheet with the crosstab shape (Measure Names + dims) is
    # a text grid pivot — honor is_crosstab BEFORE the bar/KPI inference, else
    # the grouped headers + Grand Total are lost to a flat table (EDNA partner
    # tables). A measure on BOTH axes is unambiguously a scatter (not a
    # big-number KPI), so it overrides the zero-dim KPI heuristic; otherwise
    # zero-dim → KPI.
    if meta[:is_crosstab]
      'pivot-table'
    else
      inferred = infer_automatic_kind(meta)
      inferred == 'scatter' ? 'scatter' : (meta[:is_kpi] ? 'kpi' : inferred)
    end
  when ''           then (meta[:is_crosstab] ? 'pivot-table' : 'other')
  else 'other'
  end
end

# Map a Tableau zone `type-v2` (+ presence of a worksheet name) to our
# zone-level kind label. Shared by the flat-zone loop and the nested
# zone-tree builder so the two never diverge.
def zone_kind(type_v2, caption)
  case type_v2
  when 'layout-basic', 'layout-flow' then 'container'
  when 'text'                        then 'text'
  when 'title'                       then 'title'
  when 'filter'                      then 'filter'
  when 'paramctrl'                   then 'parameter'
  when 'color'                       then 'legend'
  when 'empty'                       then 'spacer'
  when 'dashboard-object'            then 'dashboard-object'
  when nil
    # No type-v2 + a worksheet name → this is the chart tile
    caption ? 'chart' : 'container'
  else type_v2
  end
end

# Build a NESTED zone tree for a dashboard, preserving Tableau's container
# hierarchy (layout-basic / layout-flow, nested arbitrarily). Each node carries
# enough to drive a faithful Sigma container layout — kind, caption, bounds,
# flow direction (vert/horz for layout-flow), the resolved filter/param target
# column, and `children` (direct-child zones only). This is ADDITIVE: the flat
# `zones` list (below) is preserved for every downstream consumer that wants the
# geometry-banded path; the layout builder prefers the tree when present.
# ── Phase-1 style extraction (composition/style layer, gaps B2/D1/E1) ────────
# Tableau stores a dashboard zone's fill/border on the zone's DIRECT <zone-style>
# child (NOT a <style-rule element='dash-zone'> — that scope does not exist):
#   <zone …><zone-style>
#     <format attr='background-color' value='#RRGGBBAA'/>   ← region-card tint / canvas
#     <format attr='border-color' value='#hex'/> …
#   </zone-style></zone>
# Values may be 8-digit alpha hex (#rrggbbaa) — Sigma style.backgroundColor accepts
# them verbatim. Returns {} when the zone has no explicit styling (→ plain container,
# never worse than today's output). Verified against the "Job Loss from Mass
# Deportations" benchmark (region tints #07b4a2/#e8519a/#827bb8/#f28e2b at alpha).
def zone_style_fields(z)
  out = {}
  z.elements.each('zone-style/format') do |f|
    a = f.attributes['attr']; v = f.attributes['value']
    next if v.nil? || v.empty?
    case a
    when 'background-color'
      out['fill_color'] = v unless v.downcase == '#00000000' # skip fully-transparent
    when 'border-color'  then out['border_color'] = v
    when 'border-style'  then out['border_style'] = v
    end
  end
  out
end

# Tableau quick-filter / parameter display mode (zone `mode` attr) → E1 control-style
# hint. mode='compact' → dropdown (Sigma controlType:list); 'type_in' → text input;
# absent → default button/radio (Sigma segmented). Returns nil when unset.
def zone_control_display(z)
  m = z.attributes['mode']
  m && !m.empty? ? m : nil
end

def build_zone_tree(z)
  type_v2 = z.attributes['type-v2']
  caption = z.attributes['name']
  param   = z.attributes['param']
  kind    = zone_kind(type_v2, caption)
  node = {
    'id'      => z.attributes['id'],
    'kind'    => kind,
    'caption' => caption,
    'x_pct'   => pct(z.attributes['x']),
    'y_pct'   => pct(z.attributes['y']),
    'w_pct'   => pct(z.attributes['w']),
    'h_pct'   => pct(z.attributes['h'])
  }
  # layout-flow's `param` is the stack direction; a vertical flow stacks its
  # children top-to-bottom (the classic left filter-rail), horizontal L→R.
  node['direction'] = (param == 'vert' ? 'vert' : 'horz') if type_v2 == 'layout-flow'
  # Phase-1 style: per-zone fill/border (region-card tints, canvas) + control mode.
  node.merge!(zone_style_fields(z))
  cd = zone_control_display(z)
  node['control_display'] = cd if cd
  # filter/param zones resolve their target column from `param` (a column GUID).
  if kind == 'filter' || kind == 'parameter'
    g = guid_from_param(param)
    info = g ? COL_BY_GUID[g] : nil
    node['filter_column_caption']  = info && info[:caption]
    node['filter_column_datatype'] = info && info[:datatype]
  end
  kids = []
  z.elements.each('zone') { |cz| next if cz.attributes['id'].nil?; kids << build_zone_tree(cz) }
  node['children'] = kids unless kids.empty?
  node
end

dashboards = []
xml.elements.each('//dashboard') do |d|
  dash_name = d.attributes['name']
  # Zone-root id is the handle `--page` filters on.
  zone_root_id = (r = d.elements['zones']) ? r.attributes['id'] : nil
  next unless dashboard_in_scope?(dash_name, zone_root_id)
  zones = []
  seen_ids = {}
  d.elements.each('.//zone') do |z|
    next if z.attributes['id'].nil?
    next if seen_ids[z.attributes['id']]
    seen_ids[z.attributes['id']] = true

    type_v2  = z.attributes['type-v2']
    caption  = z.attributes['name']
    view_ref = z.attributes['param']

    # Translate Tableau zone type-v2 → our zone-level kind label
    kind = zone_kind(type_v2, caption)

    ws_meta    = caption ? worksheets[caption] : nil
    chart_kind = kind == 'chart' ? chart_kind_for(ws_meta) : nil
    # The chart kind was INFERRED from shelves (Tableau mark=Automatic), not
    # declared — flag it so the builder routes it to image confirmation.
    chart_kind_inferred = kind == 'chart' &&
                          ws_meta&.dig(:mark_class).to_s.downcase == 'automatic' &&
                          chart_kind != 'kpi'

    # Resolve filter-zone param GUID → column caption when this is a filter
    # zone, so downstream tools don't need to re-walk the .twb.
    if kind == 'filter' || kind == 'parameter'
      g = guid_from_param(view_ref)
      info = g ? COL_BY_GUID[g] : nil
      filter_col_caption  = info && info[:caption]
      filter_col_datatype = info && info[:datatype]
    end

    # Phase-1 style: per-zone fill/border (tints, canvas) + control display mode.
    zstyle = zone_style_fields(z)
    zdisp  = zone_control_display(z)

    zones << {
      'id'           => z.attributes['id'],
      'kind'         => kind,
      'caption'      => caption,
      'view_ref'     => view_ref,
      'x_pct'        => pct(z.attributes['x']),
      'y_pct'        => pct(z.attributes['y']),
      'w_pct'        => pct(z.attributes['w']),
      'h_pct'        => pct(z.attributes['h']),
      'chart_kind'   => chart_kind,
      'chart_kind_inferred' => chart_kind_inferred,
      'mark_class'   => ws_meta&.dig(:mark_class),
      'geo_role'     => ws_meta&.dig(:geo_role),
      # New per-worksheet signal fields (nil for non-chart zones)
      'sort'           => (kind == 'chart' ? ws_meta&.dig(:sort)           : nil),
      'filters'        => (kind == 'chart' ? ws_meta&.dig(:filters)       : nil),
      'hidden_filters' => (kind == 'chart' ? (ws_meta&.dig(:hidden_filters) || []) : nil),
      'aggregations'   => (kind == 'chart' ? ws_meta&.dig(:aggregations)  : nil),
      'channels'     => (kind == 'chart' ? ws_meta&.dig(:channels)      : nil),
      'formats'      => (kind == 'chart' ? ws_meta&.dig(:formats)       : nil),
      'calculations' => (kind == 'chart' ? ws_meta&.dig(:calculations)  : nil),
      'dual_axis'    => (kind == 'chart' ? ws_meta&.dig(:dual_axis)     : nil),
      'measures'     => (kind == 'chart' ? ws_meta&.dig(:measures)      : nil),
      'ref_marks'    => (kind == 'chart' ? ws_meta&.dig(:ref_marks)     : nil),
      'axis_formats' => (kind == 'chart' ? ws_meta&.dig(:axis_formats)  : nil),
      'mark_labels_show' => (kind == 'chart' ? ws_meta&.dig(:mark_labels_show) : nil),
      'rows_shelf'   => (kind == 'chart' ? ws_meta&.dig(:rows_shelf)    : nil),
      'cols_shelf'   => (kind == 'chart' ? ws_meta&.dig(:cols_shelf)    : nil),
      'is_crosstab'  => (kind == 'chart' ? ws_meta&.dig(:is_crosstab)   : nil),
      'is_kpi'       => (kind == 'chart' ? ws_meta&.dig(:is_kpi)        : nil),
      # Resolved filter target (filter/parameter zones only)
      'filter_column_caption'  => (kind == 'filter' || kind == 'parameter' ? filter_col_caption  : nil),
      'filter_column_datatype' => (kind == 'filter' || kind == 'parameter' ? filter_col_datatype : nil),
      # Phase-1 composition/style signals (gaps B2/E1; nil when the zone is unstyled)
      'fill_color'      => zstyle['fill_color'],
      'border_color'    => zstyle['border_color'],
      'control_display' => zdisp
    }
  end
  # A "storyboard" dashboard is Tableau's story container (sequential story
  # points in a flipboard zone) — flag it so downstream layout builders don't
  # treat the flipboard chrome as a regular chart page. The story itself is
  # parsed into story-plan.json below (beads-sigma-y6b).
  is_story = d.attributes['type-v2'] == 'storyboard' || !d.elements['.//story-points'].nil?
  # Nested container tree (additive — see build_zone_tree). Walk the direct
  # children of the dashboard's <zones> root so nesting is preserved.
  zone_tree = []
  if (root = d.elements['zones'])
    root.elements.each('zone') { |z| next if z.attributes['id'].nil?; zone_tree << build_zone_tree(z) }
  end

  dashboards << {
    'dashboard' => d.attributes['name'],
    'is_story'  => is_story,
    'zones'     => zones,
    'zone_tree' => zone_tree
  }
end

# Sheet-only workbooks (no <dashboard> blocks — just standalone worksheets)
# still need a zone list so downstream build-charts-from-signals can match
# Sigma chart-elements to Tableau views. Emit a synthetic dashboard per
# worksheet so the parser output looks normal to the build script.
if dashboards.empty? && !worksheets.empty?
  worksheets.each_key do |ws_name|
    # In a sheet-only workbook the worksheet IS the page, so `--dashboard`
    # filters on the worksheet name (zone-root id n/a → nil).
    next unless dashboard_in_scope?(ws_name, nil)
    ws_meta    = worksheets[ws_name]
    chart_kind = chart_kind_for(ws_meta)
    dashboards << {
      'dashboard' => "[synthetic] #{ws_name}",
      'zones'     => [{
        'id'           => '1',
        'kind'         => 'chart',
        'caption'      => ws_name,
        'view_ref'     => nil,
        'x_pct'        => 0.0,
        'y_pct'        => 0.0,
        'w_pct'        => 100.0,
        'h_pct'        => 100.0,
        'chart_kind'     => chart_kind,
        'mark_class'     => ws_meta[:mark_class],
        'geo_role'       => ws_meta[:geo_role],
        'sort'           => ws_meta[:sort],
        'filters'        => ws_meta[:filters],
        'hidden_filters' => ws_meta[:hidden_filters] || [],
        'aggregations'   => ws_meta[:aggregations],
        'channels'     => ws_meta[:channels],
        'formats'      => ws_meta[:formats],
        'calculations' => ws_meta[:calculations],
        'dual_axis'    => ws_meta[:dual_axis],
        'measures'     => ws_meta[:measures],
        'ref_marks'    => ws_meta[:ref_marks],
        'axis_formats' => ws_meta[:axis_formats],
        'mark_labels_show' => ws_meta[:mark_labels_show],
        'rows_shelf'   => ws_meta[:rows_shelf],
        'cols_shelf'   => ws_meta[:cols_shelf],
        'is_crosstab'  => ws_meta[:is_crosstab],
        'is_kpi'       => ws_meta[:is_kpi],
        'filter_column_caption'  => nil,
        'filter_column_datatype' => nil
      }]
    }
  end
end

def unquote_value(s)
  s = s.to_s.gsub('&quot;', '"')
  s.sub(/^"/, '').sub(/"$/, '')
end

## ---- Tableau column aliases -----------------------------------------------
# Columns can carry per-value aliases that override the raw warehouse value
# with a friendly display label. Pattern:
#   <column caption='Region' name='[Region]' ...>
#     <aliases>
#       <alias key='"N"' value='North' />
#       <alias key='"S"' value='South' />
#     </aliases>
#   </column>
# We skip the Tableau-internal `[:Measure Names]` pseudo-column and any aliases
# whose key references an internal federated id (those map field-ids to display
# strings, not data values — agent needs to wire those by hand).
column_aliases = {}
xml.elements.each('//column') do |col|
  raw_name = col.attributes['name'].to_s
  next if raw_name == '[:Measure Names]' || raw_name.empty?
  # Caption is the human-facing column name; fall back to the bracketed `name`
  # (with brackets stripped) when caption isn't set — Tableau leaves caption
  # empty for columns whose name IS already display-friendly (e.g., `[Metric]`).
  cap = col.attributes['caption']
  cap = raw_name.gsub(/^\[|\]$/, '') if cap.nil? || cap.empty?
  next if cap.empty?
  pairs = []
  col.each_element('aliases/alias') do |a|
    k = unquote_value(a.attributes['key'])
    v = a.attributes['value']
    next if k.nil? || v.nil? || v.empty?
    # Drop internal-id keys (federated.* / [usr:foo] / [sum:foo] / [ctd:foo]).
    next if k =~ /^\[(?:federated|usr|sum|ctd|min|max|avg|none):/i
    next if k =~ /^\[[\w-]+\]\.\[/  # e.g., [Sample.csv].[usr:Calc...:qk]
    pairs << { 'key' => k, 'value' => v }
  end
  next if pairs.empty?
  # Keep the richest alias set per caption (a column may appear in multiple
  # datasource blocks — keep the one with the most pairs).
  existing = column_aliases[cap]
  column_aliases[cap] = pairs if existing.nil? || pairs.size > existing.size
end

## ---- Tableau parameters ---------------------------------------------------
# Parameters live as <column param-domain-type='list|range'> inside any
# datasource (Tableau's "Parameters" datasource for global ones, or inside a
# real datasource for legacy local params). Each has:
#   - caption        (display name)
#   - datatype       (integer | real | string | date | datetime | boolean)
#   - param_domain   ('list' | 'range' | 'any')
#   - default_value  (value attribute, raw — may be quoted)
#   - members        [{ value }] when param_domain='list'
#   - min/max/step   when param_domain='range'
# Sigma maps these to: segmented/list control (list), number/range-slider
# control (range numeric), date-range control (range date).
parameters = []
xml.elements.each("//column[@param-domain-type]") do |col|
  raw_name = col.attributes['name'].to_s
  caption  = col.attributes['caption'] || raw_name.gsub(/^\[|\]$/, '')
  members  = []
  col.each_element('.//members/member') do |m|
    members << unquote_value(m.attributes['value'])
  end
  rng = col.elements['range']
  parameters << {
    'name'          => raw_name,
    'caption'       => caption,
    'datatype'      => col.attributes['datatype'],
    'param_domain'  => col.attributes['param-domain-type'],
    'default_value' => unquote_value(col.attributes['value']),
    'members'       => members,
    'min'           => rng && rng.attributes['min'],
    'max'           => rng && rng.attributes['max'],
    'step'          => rng && rng.attributes['granularity']
  }
end

# A global parameter is redeclared in EVERY worksheet's embedded
# datasource-dependencies — so the raw scan finds the same `[Parameter N]`
# hundreds of times (EDNA: 604 declarations for ~50 params), and the COPIES
# carry empty <members> while the canonical Parameters-datasource declaration
# carries the real domain. Dedup by internal NAME, keeping the richest entry
# (most members; tie-break on a non-empty default). Without this the meta is
# bloated AND a downstream consumer that takes the first-seen declaration can
# land on an empty-members copy and emit a domainless control.
parameters = parameters
  .group_by { |p| p['name'] }
  .map do |_name, dups|
    dups.max_by { |p| [(p['members'] || []).size, p['default_value'].to_s.empty? ? 0 : 1] }
  end

# Detect which worksheet calcs reference a parameter so the build script knows
# which calcs to translate via Switch(). A calc references a parameter when its
# formula contains `[Parameters].[X]` OR a bare `[X]` matching a known param.
#
# X may be the parameter's CAPTION ("Switch Metric") or its internal NAME
# ("[Parameter 5]") depending on the .twb version. The auto-control builder keys
# its orphan check on the caption, so a calc that references a param by name was
# previously misflagged "orphan parameter" and its control silently skipped.
# Resolve every ref — by name or caption — to the canonical caption so the
# builder sees the param as referenced.
param_caption_to_caption = {}
parameters.each do |p|
  cap = p['caption']
  next if cap.nil? || cap.to_s.empty?
  param_caption_to_caption[cap] = cap
  nm = p['name'].to_s.gsub(/^\[|\]$/, '')
  param_caption_to_caption[nm] = cap unless nm.empty?
end
worksheets.each do |_ws_name, w|
  next unless w[:calculations]
  w[:calculations].each do |c|
    f = c['formula'].to_s
    refs = []
    # Explicit `[Parameters].[X]` references — X may be name or caption.
    f.scan(/\[Parameters?(?:\s*\([^)]*\))?\]\s*\.\s*\[([^\]]+)\]/i).flatten.each do |x|
      refs << (param_caption_to_caption[x] || x)
    end
    # Bare bracket-refs that resolve to a known parameter (by name or caption).
    f.scan(/\[([^\]\/]+)\]/).flatten.each do |x|
      refs << param_caption_to_caption[x] if param_caption_to_caption.key?(x)
    end
    c['parameter_refs'] = refs.uniq unless refs.empty?
  end
end

## ---- Shared-view (workbook-level) filters ---------------------------------
# Tableau emits dashboard / cross-sheet filters in <shared-view> blocks at the
# workbook level. These apply to every worksheet that uses the same datasource.
# Parsing here means a page-per-worksheet builder can auto-emit Sigma controls
# for them without the agent supplying any config.
shared_filters = []
xml.elements.each('//shared-view') do |sv|
  sv_name = sv.attributes['name']
  sv.elements.each('filter') do |f|
    spec = normalize_filter(f)
    spec['shared_view'] = sv_name
    shared_filters << spec
  end
end

## ---- Tableau stories (story points) ----------------------------------------
# A Tableau story is a sequential slide deck: each <story-point> captures a
# dashboard or worksheet plus a navigator caption. XML shapes in the wild:
#   <story name='X'> ... <flipboard><story-points><story-point .../>   (older)
#   <dashboard name='X' type-v2='storyboard'> ... same flipboard tree  (newer)
# We match on //story-points so both shapes parse, and resolve each point's
# captured-sheet against the dashboard/worksheet name sets so the downstream
# builder (scripts/build-story-pages.rb) knows whether the point's Sigma page
# clones a whole dashboard page or a single worksheet element. Output:
# story-plan.json in the same directory as OUT (only when stories exist).
# beads-sigma-y6b.
stories = []
dashboard_names = dashboards.map { |d| d['dashboard'] }
xml.elements.each('//story-points') do |spn|
  # Enclosing story container = nearest ancestor carrying a name attribute
  # (<story name=...> or <dashboard name=... type-v2='storyboard'>).
  story_name = nil
  anc = spn.parent
  while anc
    nm = anc.respond_to?(:attributes) && anc.attributes ? anc.attributes['name'] : nil
    unless nm.to_s.empty?
      story_name = nm
      break
    end
    anc = anc.respond_to?(:parent) ? anc.parent : nil
  end
  points = []
  spn.elements.each('story-point') do |sp|
    a = sp.attributes
    cap = a['caption']
    cap = sp.elements['caption'].text if (cap.nil? || cap.to_s.empty?) && sp.elements['caption']
    captured = a['captured-sheet']
    kind = if captured.nil?                          then 'unknown'
           elsif dashboard_names.include?(captured)  then 'dashboard'
           elsif worksheets.key?(captured)           then 'worksheet'
           else 'unknown'
           end
    points << {
      'id'             => a['id'],
      'caption'        => cap,
      'captured_sheet' => captured,
      'sheet_kind'     => kind
    }
  end
  next if points.empty?
  stories << { 'story' => story_name, 'points' => points }
end
unless stories.empty?
  story_plan_path = File.join(File.dirname(File.expand_path(OUT)), 'story-plan.json')
  File.write(story_plan_path, JSON.pretty_generate(stories))
  puts "wrote #{story_plan_path} (#{stories.size} story(ies), " \
       "#{stories.sum { |st| st['points'].size }} story point(s)) — " \
       'run scripts/build-story-pages.rb to emit one Sigma page per story point'
end

# When per-dashboard scoping is active, narrow the meta worksheets/shared_filters
# to only what the in-scope dashboard(s) actually use, so a single-tab build
# doesn't drag the whole workbook's worksheet metadata along. Worksheets are
# referenced by a chart zone's `caption`; shared_filters are kept when their
# resolved column_caption is filtered by an in-scope worksheet (conservative —
# keep any whose column is referenced, plus all when we can't tell).
scoped_worksheets = worksheets
scoped_shared_filters = shared_filters
if dashboard_scoping?
  used_captions = {}
  dashboards.each do |d|
    d['zones'].each do |z|
      cap = z['caption']
      used_captions[cap] = true if cap && worksheets.key?(cap)
    end
  end
  scoped_worksheets = worksheets.select { |name, _| used_captions[name] }
  # Shared filters apply workbook-wide; keep those whose target column is filtered
  # by an in-scope worksheet (matched on column_caption), so the auto-control
  # builder still surfaces the relevant dashboard filters without the full set.
  used_filter_captions = {}
  scoped_worksheets.each_value do |w|
    (w[:filters] || []).each do |f|
      c = f['column_caption']
      used_filter_captions[c] = true if c
    end
  end
  scoped_shared_filters = shared_filters.select do |f|
    c = f['column_caption']
    c.nil? || used_filter_captions[c]
  end
end

meta = {
  'worksheets'     => scoped_worksheets.transform_values { |v| v.transform_keys(&:to_s) },
  'stories'        => stories,
  'shared_filters' => scoped_shared_filters,
  'parameters'     => parameters,
  'column_aliases' => column_aliases,
  'columns_by_guid'=> COL_BY_GUID.transform_values { |v| { 'caption' => v[:caption], 'datatype' => v[:datatype] } }
}
META_OUT = OUT.sub(/\.json$/, '-meta.json')
File.write(META_OUT, JSON.pretty_generate(meta))
scope_note = dashboard_scoping? ? " [scoped: #{(DASHBOARD_FILTERS + PAGE_FILTERS).join(', ')}]" : ''
puts "wrote #{META_OUT} (#{meta['worksheets'].size} worksheets, #{meta['shared_filters'].size} shared filters)#{scope_note}"

File.write(OUT, JSON.pretty_generate(dashboards))
puts "wrote #{OUT} (#{dashboards.size} dashboards, #{dashboards.sum { |d| d['zones'].size }} zones total)"
dashboards.each do |d|
  puts "  [#{d['dashboard']}]"
  d['zones'].each do |z|
    next if z['kind'] == 'container' && z['caption'].nil?
    cap = z['caption'] || '(no caption)'
    extras = []
    extras << "chart_kind=#{z['chart_kind']}" if z['chart_kind']
    extras << "mark=#{z['mark_class']}"        if z['mark_class']
    extras << "geo=#{z['geo_role']}"           if z['geo_role']
    pos = "x=#{z['x_pct']}% y=#{z['y_pct']}% w=#{z['w_pct']}% h=#{z['h_pct']}%"
    puts "    #{z['kind'].ljust(8)} #{cap.to_s[0..38].ljust(40)} #{pos.ljust(45)} #{extras.join(' ')}"
  end
end
