#!/usr/bin/env ruby
# build-workbook-from-quicksight.rb
# Build a Sigma workbook that mirrors a QuickSight analysis, bound to the
# data model produced by the convert phase.
#
# Architecture (matches the Qlik/PowerBI builders):
#   - a master "table" element on a Data page, source = {dataModelId, elementId, kind:"data-model"},
#     surfacing the columns the dashboard needs via [Custom SQL/RAW] (or a translated calc-field expr);
#   - one dashboard page whose chart elements source the master via {elementId, kind:"table"}
#     and reference master columns as [<MasterName>/<Col>] with the QuickSight aggregation.
#
# Key behaviours (beads-sigma-nc6g / woaa / 23xu):
#   - the master sources the DM element whose columns COVER the charted columns (the
#     denormalized join element), NOT a hardcoded pages[0].elements[0];
#   - QuickSight window/table-calc functions (runningSum/percentOfTotal/rank/difference/…)
#     are NOT passed through as live Sigma formulas — they are neutralized to Null (the
#     original expr goes into the column description);
#   - a dataset FilterOperation surfaced by convert-model (dm-filters.json) is APPLIED as a
#     real element-level list filter on the master, so downstream aggregates honor it;
#   - GaugeChartVisual -> kpi-chart, FunnelChartVisual -> bar-chart, TreeMapVisual -> bar-chart
#     (Sigma has no native gauge/funnel/treemap kind; this mirrors the PBI builder's mapping).
#
# Usage:
#   ruby scripts/build-workbook-from-quicksight.rb \
#     --analysis DISCOVER_DIR/analysis.json --dm-readback /tmp/dm-readback.json \
#     [--dm-spec /tmp/dm-spec.json] [--filters /tmp/dm-filters.json] \
#     --folder-id ID --out /tmp/wb-spec.json
require 'json'
require 'optparse'
require 'securerandom'
require 'set'

opts = {}
OptionParser.new do |o|
  o.on('--analysis F') { |v| opts[:an] = v }
  o.on('--dm-readback F') { |v| opts[:rb] = v }
  o.on('--dm-spec F') { |v| opts[:dmspec] = v }
  o.on('--filters F') { |v| opts[:filters] = v }
  o.on('--folder-id ID') { |v| opts[:folder] = v }
  o.on('--master-name NAME') { |v| opts[:mname] = v }
  o.on('--out F') { |v| opts[:out] = v }
end.parse!
%i[an rb out].each { |k| abort "missing --#{k}" unless opts[k] }

an = JSON.parse(File.read(opts[:an]))
defn = an['Definition']
# QuickSight what-if PARAMETERS (Decimal/Integer/String/DateTime ParameterDeclaration).
# A calc field references a parameter as ${ParamName}. Sigma has no 1:1 parameter inside a
# data-model formula, so for parity we inline the parameter's DEFAULT value as a constant
# (the default-view value the QS dashboard shows on load). This is recorded as a warning so
# the (interactive) what-if control is understood to be a manual re-author in Sigma.
PARAM_DEFAULTS = {}
(defn['ParameterDeclarations'] || []).each do |pd|
  decl = pd.values.first
  next unless decl.is_a?(Hash) && decl['Name']
  dv = (decl.dig('DefaultValues', 'StaticValues') || [])[0]
  PARAM_DEFAULTS[decl['Name']] = dv unless dv.nil?
end
rb = JSON.parse(File.read(opts[:rb]))
dm_id = rb['dataModelId']

def disp(raw); raw.to_s.gsub(/[_.]/, ' ').split.map { |w| w[0..0].upcase + w[1..-1].to_s.downcase }.join(' '); end

# ---- derive the columns the dashboard actually references (raw col names) ----
def visual_cols(inner)
  out = []
  walk = lambda do |o|
    if o.is_a?(Hash)
      if (c = o['Column']) && c.is_a?(Hash) && c['ColumnName']
        out << c['ColumnName']
      end
      o.each_value { |v| walk.call(v) }
    elsif o.is_a?(Array)
      o.each { |v| walk.call(v) }
    end
  end
  walk.call(inner['ChartConfiguration'] || {})
  out
end

calc_names = {}
(defn['CalculatedFields'] || []).each { |c| calc_names[c['Name']] = c['Expression'] }

needed_raw = []
defn['Sheets'].each do |sh|
  (sh['Visuals'] || []).each do |v|
    _, inner = v.first
    needed_raw.concat(visual_cols(inner))
  end
end
needed_raw.uniq!
# calc fields resolve to raw columns inside their expressions; expand
needed_resolved = needed_raw.flat_map do |n|
  if calc_names.key?(n)
    calc_names[n].to_s.scan(/\{([^}]+)\}/).flatten.map(&:strip)
  else
    [n]
  end
end.uniq

# ---- pick the DM element whose columns COVER the charted columns ----
# Use the dm-spec (has column display names) to score coverage; fall back to the
# dm-readback element list when no dm-spec is provided. (beads-sigma-nc6g point 4)
dm_spec = opts[:dmspec] && File.exist?(opts[:dmspec]) ? JSON.parse(File.read(opts[:dmspec])) : nil
needed_disp = needed_resolved.map { |c| disp(c) }.to_set

best = nil
best_idx = nil
if dm_spec
  spec_els = (dm_spec['pages'] || []).flat_map { |pg| pg['elements'] || [] }
  scored = spec_els.each_with_index.map do |el, i|
    names = (el['columns'] || []).map { |c| c['name'] }.compact.to_set
    cover = needed_disp.count { |d| names.include?(d) }
    [cover, (el['columns'] || []).size, el['name'], i]
  end
  # most coverage; tie-break on more columns (the denormalized view wins)
  top = scored.max_by { |cover, ncols, _name, _i| [cover, ncols] }
  best = top && top[2]
  best_idx = top && top[3]
end

rb_els = (rb['pages'] || []).flat_map { |pg| pg['elements'] || [] }
dm_el_obj =
  if best
    # DM element names can COLLIDE (e.g. two "D20 Kitchen Sink" elements: a source +
    # the denormalized join). Selecting by name alone would grab the first match and
    # miss the join element that actually covers the charted columns. The dm-spec and
    # dm-readback element lists are in the same order, so prefer the readback element at
    # the winning spec index; fall back to name match, then first.
    (best_idx && rb_els[best_idx]) || rb_els.find { |e| e['name'] == best } || rb_els.first
  elsif rb_els.any? { |e| (e['columns'] || []).any? }
    # No dm-spec, but the readback carries column names: score coverage directly off the
    # readback so we pick the element that actually COVERS the charted columns (handles
    # name-collision + arbitrary element ordering — beads D20). Tie-break on more columns
    # (the denormalized join wins).
    scored_rb = rb_els.map do |el|
      names = (el['columns'] || []).map { |c| c['name'] }.compact.to_set
      cover = needed_disp.count { |d| names.include?(d) }
      [cover, (el['columns'] || []).size, el]
    end
    top = scored_rb.max_by { |cover, ncols, _| [cover, ncols] }
    (top && top[2]) || rb_els.first
  else
    # no dm-spec and no readback columns: prefer the last (synthesized join element is
    # appended last) else first.
    rb_els.last || rb_els.first
  end
abort 'no DM elements in readback' unless dm_el_obj
dm_el = dm_el_obj['id']
DMEL = dm_el_obj['name'] || 'Custom SQL'   # DM element name — master refs cols as [DMEL/Col]
M = opts[:mname] || 'Orders'               # master element name (used in [M/Col] refs from charts)

def nid(p = 'el'); "#{p}-" + SecureRandom.hex(5); end
NUM = ->(fs) { { 'kind' => 'number', 'formatString' => fs } }
AGG = { 'SUM' => 'Sum', 'AVERAGE' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
        'COUNT' => 'Count', 'DISTINCT_COUNT' => 'CountDistinct', 'MEDIAN' => 'Median' }

# QuickSight window / table-calc function names (must match convert-model.rb). A
# calc field using any of these can't be a live Sigma formula — neutralize to Null.
QS_WINDOW_FUNCS = %w[
  runningSum runningAvg runningCount runningMax runningMin
  percentOfTotal percentDifference difference
  rank denseRank percentileRank
  lag lead firstValue lastValue
  windowSum windowAvg windowCount windowMax windowMin
  movingSum movingAverage
].freeze
def qs_window_func?(expr)
  e = expr.to_s
  QS_WINDOW_FUNCS.any? { |fn| e =~ /(?<![A-Za-z0-9_])#{Regexp.escape(fn)}\s*\(/ }
end

# minimal QuickSight-expr → Sigma-formula translator for calc fields referenced by visuals
def qs_expr_to_sigma(expr, dmel, params = {})
  s = expr.to_s.dup
  # ${Param} -> inlined default constant (what-if parameters have no DM-formula equivalent).
  s = s.gsub(/\$\{([^}]+)\}/) do
    nm = Regexp.last_match(1).strip
    v = params[nm]
    v.nil? ? '0' : (v.is_a?(String) ? "\"#{v}\"" : v.to_s)
  end
  s = s.gsub(/\{([^}]+)\}/) { "[#{dmel}/#{disp(Regexp.last_match(1).strip)}]" }
  s = s.gsub('<>', '!=')
  s = s.gsub(/\bifelse\s*\(/i, 'If(')
  s = s.gsub(/'([^']*)'/) { "\"#{Regexp.last_match(1)}\"" }
  s
end

calc = {}
(defn['CalculatedFields'] || []).each { |c| calc[c['Name']] = c['Expression'] }

def field_role(f)
  if (mf = f['NumericalMeasureField'])
    [:meas, mf['Column']['ColumnName'], (mf.dig('AggregationFunction', 'SimpleNumericalAggregation') || 'SUM')]
  elsif (mf = f['CategoricalMeasureField'])
    [:meas, mf['Column']['ColumnName'], 'COUNT']
  elsif (df = f['CategoricalDimensionField'])
    [:dim, df['Column']['ColumnName'], nil]
  elsif (df = f['DateDimensionField'])
    # 4th tuple slot carries the QS DateGranularity (YEAR/QUARTER/MONTH/WEEK/DAY/...)
    # so a date x-axis can be truncated to that grain (D20 line-chart monthly).
    [:dim, df['Column']['ColumnName'], nil, df['DateGranularity']]
  end
end

# Generic field-well flattener for the D18 fallback path. The unsupported QS visual
# types use non-standard well names (Categories / Source / Destination / Weight /
# GroupBy / Size / Color / ...), so the named-well lambda in the dispatch cannot find
# them. This walks EVERY well in the field-well object, in document order, and returns
# [dims, measures] (each an array of field_role tuples). Used only for fallbacks.
def all_field_roles(w)
  dims = []; meas = []
  (w || {}).each do |_well, fields|
    next unless fields.is_a?(Array)
    fields.each do |f|
      r = field_role(f); next unless r
      (r[0] == :dim ? dims : meas) << r
    end
  end
  [dims, meas]
end

# The QuickSight FieldId of a single field-well entry (e.g. "f_cnt"). Needed to map a
# ConditionalFormatting rule (keyed by FieldId) back to the Sigma column we built.
def field_id(f)
  return nil unless f.is_a?(Hash)
  (f['NumericalMeasureField'] || f['CategoricalMeasureField'] ||
   f['CategoricalDimensionField'] || f['DateDimensionField'] || {})['FieldId']
end

# ---- QS SortConfiguration -> Sigma sort (beads-sigma-xvjl) -------------------
# QuickSight sorts live under ChartConfiguration.SortConfiguration, e.g.
#   { "CategorySort": [ { "FieldSort":  { "FieldId": "...", "Direction": "DESC" } },
#                       { "ColumnSort": { "SortBy": { "Column": { "ColumnName": ... } },
#                                         "Direction": "ASC", "AggregationFunction": {...} } } ] }
# (bar/line/pie use CategorySort; TableVisual uses RowSort.) Resolve the sorted field
# to the Sigma column built for the visual and emit the verified Sigma shapes:
#   bar/line/area/combo/scatter : xAxis.sort  = { by: <colId>, direction: }
#   pie/donut                   : color.sort  = { by: <colId>, direction: }
#   table                       : sort        = [{ columnId:, direction: }]
# (pivot-table columnsBy/rowsBy sorts are NOT spec-supported — skipped with a warning.)

# Every FieldId -> raw ColumnName mapping in the visual's field wells.
def fid_to_colname(field_wells)
  map = {}
  walk = lambda do |o|
    if o.is_a?(Hash)
      if o['FieldId'] && (cn = o.dig('Column', 'ColumnName'))
        map[o['FieldId']] = cn
      end
      o.each_value { |v| walk.call(v) }
    elsif o.is_a?(Array)
      o.each { |v| walk.call(v) }
    end
  end
  walk.call(field_wells || {})
  map
end

# Apply a visual's SortConfiguration to the built Sigma element (mutates el).
def apply_qs_sorts(el, inner, kind, title, warnings)
  cc = inner['ChartConfiguration'] || {}
  sc = cc['SortConfiguration']
  return unless sc.is_a?(Hash) && !sc.empty?
  entries = sc.values.find { |v| v.is_a?(Array) && !v.empty? } # CategorySort / RowSort / ...
  return unless entries
  if kind == 'pivot-table'
    warnings << { 'visual' => title, 'type' => 'SortConfiguration',
                  'reason' => 'pivot-table sorts are not spec-expressible in Sigma (columnsBy/rowsBy sort rejected) — set in the UI' }
    return
  end
  fidmap = fid_to_colname(cc['FieldWells'])
  entries.each_with_index do |entry, i|
    fs = entry['FieldSort']; cs = entry['ColumnSort']
    raw = fs ? fidmap[fs['FieldId']] : cs&.dig('SortBy', 'Column', 'ColumnName')
    dir = ((fs || cs || {})['Direction'].to_s.upcase == 'DESC') ? 'descending' : 'ascending'
    next unless raw
    # column names on the element: calc fields keep the raw name, physical cols are disp()'d
    col = (el['columns'] || []).find { |c| c['name'] == disp(raw) || c['name'] == raw }
    unless col
      warnings << { 'visual' => title, 'type' => 'SortConfiguration',
                    'reason' => "sort field '#{raw}' is not among the visual's Sigma columns — sort skipped" }
      next
    end
    case kind
    when 'bar-chart', 'line-chart', 'area-chart', 'combo-chart', 'scatter-chart'
      (el['xAxis'] ||= {})['sort'] = { 'by' => col['id'], 'direction' => dir } if i.zero?
    when 'pie-chart', 'donut-chart'
      (el['color'] ||= {})['sort'] = { 'by' => col['id'], 'direction' => dir } if i.zero?
    when 'table'
      (el['sort'] ||= []) << { 'columnId' => col['id'], 'direction' => dir }
    end
  end
end

# ---- QS ReferenceLines -> Sigma refMarks (B-gap: reference lines) ------------
# QuickSight reference lines live at ChartConfiguration.ReferenceLines[] on the
# cartesian visuals (bar/line/area/combo/scatter). Each entry:
#   { "Status": "ENABLED",
#     "DataConfiguration": {
#       "AxisBinding": "PRIMARY_YAXIS",          # PRIMARY_YAXIS|SECONDARY_YAXIS = series; *_XAXIS = axis
#       "StaticConfiguration": { "Value": 0.45 } # a constant; OR
#       "DynamicConfiguration": { "Calculation": {"SimpleNumericalAggregation":"AVERAGE"},
#                                 "MeasureAggregationFunction": {...}, "Column": {...} } },
#     "LabelConfiguration": { "CustomLabelConfiguration": { "CustomLabel": "Target" },
#                             "FontColor": "#ef4444" },
#     "StyleConfiguration": { "Color": "#ef4444", "Pattern": "DASHED" } }
# Sigma refMarks (verified shape, qlik_refmarks() parity, 2026-06-15): the value
# MUST be the wrapped { type:"formula", formula:"<expr>" } form (a bare number 400s);
# label.visibility must be "shown". A static value -> the literal; a dynamic
# (aggregation over a column) -> the Sigma aggregate formula over the master, so the
# line tracks the data. X-axis bindings -> axis "axis"; Y/measure bindings -> "series".
def qs_reference_lines(inner, calc, master_cols, dmel, m, title, warnings)
  cc = inner['ChartConfiguration'] || {}
  lines = cc['ReferenceLines']
  return [] unless lines.is_a?(Array) && !lines.empty?
  out = []
  lines.each do |rl|
    next if rl['Status'].to_s.upcase == 'DISABLED'
    dc = rl['DataConfiguration'] || {}
    axis = dc['AxisBinding'].to_s.upcase.include?('XAXIS') ? 'axis' : 'series'
    formula = nil
    if (sc = dc['StaticConfiguration']) && !sc['Value'].nil?
      formula = sc['Value'].to_s
    elsif (dyn = dc['DynamicConfiguration'])
      # aggregation over a column -> Agg([Master/Col]); the line follows the data.
      col = dyn.dig('Column', 'ColumnName') || dyn.dig('MeasureAggregationFunction', 'Column', 'ColumnName')
      aggk = (dyn.dig('Calculation', 'SimpleNumericalAggregation') ||
              dyn.dig('MeasureAggregationFunction', 'SimpleNumericalAggregation') || 'AVERAGE').to_s.upcase
      if col
        ref = master_ref(col, calc, master_cols, dmel)
        formula = "#{AGG[aggk] || 'Avg'}([#{m}/#{ref['name']}])"
      end
    end
    if formula.nil? || formula.empty?
      warnings << { 'visual' => title, 'type' => 'ReferenceLine',
                    'reason' => 'reference line has neither a static value nor a resolvable dynamic column — skipped' }
      next
    end
    color = rl.dig('StyleConfiguration', 'Color') || rl.dig('LabelConfiguration', 'FontColor') || '#ef4444'
    rm = { 'type' => 'line', 'axis' => axis,
           'value' => { 'type' => 'formula', 'formula' => formula },
           'line' => { 'color' => color, 'width' => 2 } }
    lbl = rl.dig('LabelConfiguration', 'CustomLabelConfiguration', 'CustomLabel')
    rm['label'] = { 'visibility' => 'shown', 'text' => lbl } if lbl && !lbl.to_s.empty?
    out << rm
  end
  out
end

# ---- QS chart color encoding -> Sigma `color` channel (B-gap: by-measure / by-dimension)
# QuickSight encodes series color two ways inside the aggregated field wells:
#   * by DIMENSION — a `Colors` well holding a CategoricalDimensionField (the chart is
#     split into one colored series per dimension value). -> Sigma color:{by:category}
#     on that dimension's Sigma column (added to the element if not already present).
#   * by MEASURE — a `ColorScale` (ColorFillType + Colors[] gradient stops) under the
#     visual's ColorScale/ScalarColors config, coloring marks along a measure's value.
#     A Sigma column can't sit on both yAxis and color, so (qlik_color() parity) we add
#     a DUPLICATE of the first measure column and put color:{by:scale, scheme} on it.
# Returns the color hash (and MUTATES el['columns'] for the by-scale dup / by-category
# dim) or nil. `wells` is the inner aggregated-field-wells hash; dim_ids/m_ids are the
# Sigma column ids already built for this element.
def qs_color(inner, wells, el, dim_ids, m_ids, calc, master_cols, dmel, m)
  cc = inner['ChartConfiguration'] || {}
  # by-dimension: a Colors well with a categorical dimension
  color_roles = (wells['Colors'] || []).map { |f| field_role(f) }.compact
  cdim = color_roles.find { |r| r[0] == :dim }
  if cdim
    # reuse the dim column if it's already on the element, else add it
    existing = (el['columns'] || []).find { |c| c['name'] == disp(cdim[1]) || c['name'] == cdim[1] }
    if existing
      return { 'by' => 'category', 'column' => existing['id'] }
    end
    dc, did = dim_col(cdim, calc, master_cols, dmel, m)
    (el['columns'] ||= []) << dc
    return { 'by' => 'category', 'column' => did }
  end
  # by-measure: a ColorScale gradient (ColorFillType + Colors[] stops). QS nests it
  # under the aggregated field-wells (Color/ColorScale) OR ChartConfiguration.ColorScale.
  cs = wells['ColorScale'] || cc['ColorScale']
  if cs.is_a?(Hash) && !m_ids.empty?
    stops = (cs['Colors'] || []).map { |st| st.is_a?(Hash) ? st['Color'] : st }.compact
    scheme = stops.size >= 2 ? stops : ['#ffffcc', '#fd8d3c', '#bd0026']
    base = (el['columns'] || []).find { |c| c['id'] == m_ids[0] }
    return nil unless base
    cid = "clr-#{SecureRandom.hex(4)}"
    dup = { 'id' => cid, 'formula' => base['formula'], 'name' => "#{base['name']} (color)" }
    dup['format'] = base['format'] if base['format']
    (el['columns'] ||= []) << dup
    return { 'by' => 'scale', 'column' => cid, 'scheme' => scheme }
  end
  nil
end

# Translate a QuickSight TableVisual ConditionalFormatting block into Sigma
# `conditionalFormats` (D19). Supported QS -> Sigma mappings (verified spec-expressible
# + round-tripping via /v2/workbooks/spec, 2026-06-06):
#   - TextFormat.BackgroundColor.Gradient  -> type:"backgroundScale" (gradient on cell bg)
#   - TextFormat.TextColor.Gradient        -> type:"fontScale"
#   - DataBars                             -> type:"dataBars"
# The gradient Color.Stops (offset/color) become the Sigma `scheme` color-stop array.
# fieldmap maps QS FieldId -> Sigma column id (only measure cells are colored).
def qs_conditional_formats(cf_block, fieldmap)
  out = []
  (cf_block['ConditionalFormattingOptions'] || []).each do |opt|
    cell = opt['Cell'] || opt['Row'] || {}
    fid  = cell['FieldId']
    colid = fieldmap[fid]
    next unless colid
    tf = cell['TextFormat'] || {}
    if (grad = tf.dig('BackgroundColor', 'Gradient'))
      scheme = (grad.dig('Color', 'Stops') || []).map { |st| st['Color'] }.compact
      scheme = ['#FFFFFF', '#D13212'] if scheme.size < 2
      out << { 'type' => 'backgroundScale', 'columnIds' => [colid], 'scheme' => scheme }
    elsif (grad = tf.dig('TextColor', 'Gradient'))
      scheme = (grad.dig('Color', 'Stops') || []).map { |st| st['Color'] }.compact
      scheme = ['#FFFFFF', '#D13212'] if scheme.size < 2
      out << { 'type' => 'fontScale', 'columnIds' => [colid], 'scheme' => scheme }
    elsif cell['DataBars']
      db = cell['DataBars']
      pos = db['PositiveColor'] || '#1f77b4'
      out << { 'type' => 'dataBars', 'columnIds' => [colid], 'scheme' => [pos] }
    end
  end
  out
end

# QuickSight visual type -> Sigma element kind.
#
# Sigma's REAL workbook chart kinds (confirmed against the public OpenAPI element
# union — /v2/workbooks/spec): kpi-chart, bar-chart, line-chart, area-chart,
# pie-chart, donut-chart, scatter-chart, combo-chart, table, pivot-table, AND the
# three geographic kinds point-map / region-map / geography-map. There is NO native
# histogram, heat-map, treemap, waterfall, box-plot, radar, sankey, or word-cloud
# kind (verified: those names do not appear anywhere in the element union).
#
# Approximations (no native kind, mirror the PBI builder, beads-sigma-1zh9):
#   gauge -> kpi-chart (single value); funnel/treemap -> bar-chart (category+measure).
# Geographic (NEW — region-map shape verified to round-trip via live POST+readback
# + MCP query parity on the D17 DM, 2026-06-06): QuickSight FilledMapVisual and
# GeospatialMapVisual both map to Sigma region-map when their geo field is a region
# NAME (state/country/city/zip); GeospatialMapVisual maps to point-map only when it
# carries real latitude+longitude fields (handled in the dispatch). LayerMapVisual
# (multi-layer) has no clean single-element equivalent -> dropped with a warning.
KIND = { 'KPIVisual' => 'kpi-chart', 'BarChartVisual' => 'bar-chart',
         'LineChartVisual' => 'line-chart', 'PieChartVisual' => 'pie-chart',
         'ComboChartVisual' => 'combo-chart', 'ScatterPlotVisual' => 'scatter-chart',
         'TableVisual' => 'table', 'PivotTableVisual' => 'pivot-table',
         'GaugeChartVisual' => 'kpi-chart', 'FunnelChartVisual' => 'bar-chart',
         'TreeMapVisual' => 'bar-chart',
         'FilledMapVisual' => 'region-map', 'GeospatialMapVisual' => 'region-map' }

# QuickSight visual types Sigma has NO native equivalent for. Rather than dropping
# them (which left whole dashboards empty - beads D18), we DATA-MIGRATE each one as a
# Sigma fallback element built from the visual\'s underlying dims + measures, so the
# query/data still migrates with parity. A clear per-visual warning is still recorded
# (the chart KIND is the (c)-tail, not the data).
#
#   QS_FALLBACK maps the type -> the Sigma kind to approximate it with:
#     - \'bar-chart\'  where a single category+measure shape reads sensibly as bars
#       (waterfall: a running category total; histogram: a binned distribution that
#       we approximate as a per-value bar - true auto-binning is still (c)-tail).
#     - \'table\'      for everything multi-dimensional or non-cartesian (sankey: a
#       source->dest->weight table; box-plot/word-cloud/radar/heat-map: the underlying
#       grouped measure table). A table is always data-complete + query-parity.
# Reason text is surfaced to STDERR + a sidecar warnings file either way.
QS_UNSUPPORTED = {
  'HeatMapVisual'       => 'Sigma has no heat-map element kind; migrated as a grouped table of the underlying measure',
  'HistogramVisual'     => 'Sigma has no histogram element kind (auto-binning); approximated as a bar-chart of the measure (true binning is manual in Sigma)',
  'BoxPlotVisual'       => 'Sigma has no box-plot element kind; migrated as a grouped table of the underlying values',
  'WaterfallVisual'     => 'Sigma has no waterfall element kind; approximated as a bar-chart of the category totals',
  'SankeyDiagramVisual' => 'Sigma has no sankey element kind; migrated as a source/destination/weight table',
  'WordCloudVisual'     => 'Sigma has no word-cloud element kind; migrated as a grouped table of the term counts',
  'RadarChartVisual'    => 'Sigma has no radar/spider element kind; migrated as a grouped table of the measure',
  'LayerMapVisual'      => 'Sigma has no multi-layer map element kind (single-layer point/region-map only)',
  'InsightVisual'       => 'QuickSight ML insight (forecast/anomaly/narrative) - no Sigma equivalent',
  'CustomContentVisual' => 'QuickSight custom content (iframe/HTML/image embed) - re-author as a Sigma image/embed element',
  'PluginVisual'        => 'QuickSight third-party plugin visual (e.g. Highcharts) - no Sigma equivalent',
  'EmptyVisual'         => 'QuickSight placeholder (no chart configured) - nothing to build'
}.freeze

# Fallback Sigma kind for each unsupported QS type (D18 data-migration). Types absent
# here (Insight / CustomContent / Plugin / Empty / LayerMap) have no underlying
# dim+measure field-well to migrate, so they remain genuine drops with a warning.
QS_FALLBACK = {
  'WaterfallVisual'     => 'bar-chart',
  'HistogramVisual'     => 'bar-chart',
  'HeatMapVisual'       => 'table',
  'BoxPlotVisual'       => 'table',
  'SankeyDiagramVisual' => 'table',
  'WordCloudVisual'     => 'table',
  'RadarChartVisual'    => 'table'
}.freeze
build_warnings = []
# Hidden GROUPED source tables emitted for scatter-charts (one row per point dim),
# appended to the Data page next to the master. See the scatter branch below
# (ported from the live-verified qlik-to-sigma builder, bead ry0n): Sigma's scatter
# axis is a GROUPING axis, so an aggregate (Sum(...)) over the UNGROUPED master
# collapses every point to one x. The scatter must instead bind to a hidden grouped
# source whose groupBy is the point dimension.
scatter_sources = []

master_cols = {}   # colname(raw or calc) -> {id, formula, name}
def fmt_for(name)
  case name
  when /margin|pct|percent|ratio|rate/i then '.1%'
  when /revenue|profit|cost|sales|amount|price|discount/i then '$,.0f'
  else ',.0f'
  end
end

# Infer a Sigma region-map regionType from the geo dimension's (raw) column name.
# Sigma regionType enum (OpenAPI): country, us-state, us-county, us-zipcode,
# us-cbsa, us-postal-place, ca-province. Default to us-postal-place for free
# city/place names (the most permissive name-based bucket).
def region_type_for(rawname)
  n = rawname.to_s.downcase
  return 'country'         if n =~ /country|nation/
  return 'us-state'        if n =~ /\bstate\b|province_state|^st$/
  return 'us-county'       if n =~ /county/
  return 'us-zipcode'      if n =~ /zip|postal_?code|postcode/
  return 'us-cbsa'         if n =~ /cbsa|metro/
  return 'ca-province'     if n =~ /province/
  'us-postal-place'  # city / place name
end

# Does a Geospatial field-well carry an explicit latitude / longitude pair? If so
# the QuickSight geo visual should become a Sigma point-map; otherwise (a region
# NAME like state/city) it becomes a region-map.
def latlong_pair(geo_roles)
  lat = geo_roles.find { |r| r[1].to_s =~ /lat(itude)?/i }
  lon = geo_roles.find { |r| r[1].to_s =~ /lon(g|gitude)?/i }
  (lat && lon) ? [lat, lon] : nil
end

def master_ref(colname, calc, master_cols, dmel)
  return master_cols[colname] if master_cols[colname]
  if calc.key?(colname)
    if qs_window_func?(calc[colname])
      # neutralize: a window/table-calc field can't be a live Sigma calc column.
      formula = 'Null'; nm = colname
      master_cols[colname] = { 'id' => "m-#{SecureRandom.hex(4)}", 'formula' => formula, 'name' => nm,
                               'description' => "QuickSight table-calc (neutralized — re-author in Sigma): #{calc[colname]}",
                               '_window' => true }
      return master_cols[colname]
    end
    formula = qs_expr_to_sigma(calc[colname], dmel, defined?(PARAM_DEFAULTS) ? PARAM_DEFAULTS : {}); nm = colname
  else
    formula = "[#{dmel}/#{disp(colname)}]"; nm = disp(colname)
  end
  master_cols[colname] = { 'id' => "m-#{SecureRandom.hex(4)}", 'formula' => formula, 'name' => nm }
end

def dim_col(role, calc, mc, dmel, m)
  ref = master_ref(role[1], calc, mc, dmel); id = nid('d')
  [{ 'id' => id, 'formula' => "[#{m}/#{ref['name']}]", 'name' => ref['name'] }, id]
end

# QuickSight DateGranularity -> Sigma DateTrunc() part. (D20: a LineChartVisual with a
# DateDimensionField DateGranularity=MONTH must aggregate the x-axis by month, not plot
# raw datetime. Sigma truncates via DateTrunc("month", <date>).)
QS_GRAIN = { 'YEAR' => 'year', 'QUARTER' => 'quarter', 'MONTH' => 'month',
             'WEEK' => 'week', 'DAY' => 'day', 'HOUR' => 'hour',
             'MINUTE' => 'minute', 'SECOND' => 'second' }.freeze

# Date dimension column truncated to a QS DateGranularity. Returns the same
# [col, id] shape as dim_col. The truncated column gets a date format string so the
# axis renders as e.g. "Jun 2026" for month grain.
def date_dim_col(role, calc, mc, dmel, m)
  grain = QS_GRAIN[role[3].to_s.upcase]
  return dim_col(role, calc, mc, dmel, m) unless grain
  ref = master_ref(role[1], calc, mc, dmel); id = nid('d')
  # Sigma datetime formatStrings are strftime conventions (NOT moment.js MMM/YYYY).
  fmt = case grain
        when 'year' then '%Y'
        when 'quarter' then '%b %Y'
        when 'month' then '%b %Y'
        when 'week', 'day' then '%Y-%m-%d'
        else '%Y-%m-%d %H:%M'
        end
  [{ 'id' => id, 'name' => ref['name'],
     'formula' => "DateTrunc(\"#{grain}\", [#{m}/#{ref['name']}])",
     'format' => { 'kind' => 'datetime', 'formatString' => fmt } }, id]
end

def meas_col(role, calc, mc, dmel, m)
  _, col, agg = role; ref = master_ref(col, calc, mc, dmel); id = nid('m')
  # a neutralized window calc field can't be aggregated as a live formula either
  if ref['_window']
    return [{ 'id' => id, 'formula' => 'Null', 'name' => ref['name'],
              'description' => ref['description'] }, id]
  end
  [{ 'id' => id, 'formula' => "#{AGG[agg] || 'Sum'}([#{m}/#{ref['name']}])", 'name' => ref['name'],
     'format' => NUM.(fmt_for(ref['name'])) }, id]
end

# D12: a measure that resolves to a QuickSight window / table-calc field (runningSum,
# percentOfTotal, rank, difference, ...) is neutralized to Null in the master (it can't
# be a live Sigma formula). Surfacing those as columns in a chart/table renders BLANK
# columns that look broken. We DROP such measures from the workbook ELEMENT (they stay
# in the data model's master with their original expr in the description, so the intent
# is preserved and re-authorable) and record a per-visual warning.
def window_meas?(role, calc)
  return false unless role && role[0] == :meas
  name = role[1]
  calc.key?(name) && qs_window_func?(calc[name])
end

# ---- C-gap: QuickSight CONTROLS -> Sigma list controls ----------------------
# QuickSight interactivity lives at the SHEET level as FilterControls + ParameterControls
# (NOT inside a visual). Until now this builder emitted ZERO control elements — every QS
# dashboard migrated as a static workbook (filters inlined as constants / element-level).
# We now reconstruct them as real Sigma `kind:control` list controls so the dropdowns
# populate and drive the page (the silently-dropped class the control-scope gate exists
# to kill). Shape mirrors the live-verified qlik-to-sigma builder:
#   { kind:"control", controlId, name, controlType:"list", mode:"include",
#     selectionMode:"multiple", values:[],
#     source:{ kind:"source", source:{kind:"table", elementId:"master"}, columnId },
#     filters:[{ source:{kind:"table", elementId:"master"}, columnId }] }
# The double-nested `source` is what POPULATES the dropdown's value list from the master
# column; `filters` is what makes the control DRIVE the master (and so, via source-closure,
# every chart that sources the master). Date-typed columns become date-range controls
# (a list control on a datetime target is silently stripped by the spec API).
#
# QS -> Sigma mapping:
#   * FilterControls (Dropdown/List/...) -> resolve SourceFilterId through FilterGroups to
#     the filtered Column.ColumnName, target the master column for that name.
#   * ParameterControls (Dropdown/List/...) bound to a Column-typed parameter -> same.
#     A ParameterControl bound to a WHAT-IF numeric parameter (no column) has no list-
#     control equivalent (it feeds a calc-field constant) -> recorded UNBOUND/manual, not
#     emitted (the value is already inlined by PARAM_DEFAULTS).
QS_CONTROL_WRAPS = %w[Dropdown List Slider TextField TextArea DateTimePicker RelativeDateTime].freeze

# Every FilterId -> filtered raw ColumnName, indexed across the analysis FilterGroups.
QS_FILTER_COL = {}
(defn['FilterGroups'] || []).each do |fg|
  (fg['Filters'] || []).each do |flt|
    body = flt.is_a?(Hash) ? flt.values.first : nil
    next unless body.is_a?(Hash)
    fid = body['FilterId']
    col = body.dig('Column', 'ColumnName') || body.dig('ColumnName')
    QS_FILTER_COL[fid] = col if fid && col
  end
end

# Column-typed parameter? (ParameterDeclaration whose default came from a column.) We map
# a ParameterControl to a column only when the analysis associates it with one; otherwise
# it's a what-if scalar (inlined as a constant) and gets no list control.
def qs_control_target_col(wrap, kind, filter_col_map)
  body = wrap[kind] || {}
  if (sfid = body['SourceFilterId'])
    return [filter_col_map[sfid], body, :filter]
  end
  # ParameterControl: a Dropdown/List bound to a column surfaces SelectableValues or a
  # LinkToDataSetColumn { Column: { ColumnName } }. A plain what-if param has neither.
  col = body.dig('SelectableValues', 'LinkToDataSetColumn', 'ColumnName') ||
        body.dig('CascadingControlConfiguration', 'SourceControls', 0, 'ColumnToMatch', 'ColumnName')
  [col, body, :parameter]
end

# Build ONE Sigma control element for a QS FilterControl/ParameterControl wrap, or nil.
# Pushes a control-scope CONTRACT row (scope/sourceName/status) or an `unbound` row so the
# signal is NEVER silently dropped. Dedupes by target column (the same column filtered by
# two controls is one Sigma control — controlIds are unique).
def build_qs_control(wrap, master_cols, calc, dmel, scope, unbound, seen_cols, warnings)
  ctype, body = nil, nil
  raw_col = nil; src_kind = :filter
  QS_CONTROL_WRAPS.each do |k|
    next unless wrap[k].is_a?(Hash)
    raw_col, body, src_kind = qs_control_target_col(wrap, k, QS_FILTER_COL)
    ctype = k
    break
  end
  return nil unless body
  cid_src = body['FilterControlId'] || body['ParameterControlId'] || nid('ctl')
  label = body.dig('Title') || body['Title'] || raw_col || cid_src
  sig = "#{src_kind} control #{cid_src.inspect}#{raw_col ? " on #{raw_col}" : ''}"
  if raw_col.nil? || raw_col.to_s.empty?
    # what-if scalar parameter control — already inlined as a constant; no list control.
    warnings << { 'visual' => '(control)', 'type' => 'ParameterControl',
                  'reason' => "#{sig}: not bound to a dataset column (what-if scalar) — its default is inlined; add a Sigma what-if control by hand if interactivity is needed" }
    unbound << { 'sourceName' => sig, 'status' => 'manual',
                 'reason' => 'what-if scalar parameter control has no Sigma list-control equivalent (value inlined as a constant)' }
    return nil
  end
  if seen_cols.key?(raw_col)
    unbound << { 'sourceName' => sig, 'status' => 'duplicate',
                 'reason' => "same column as control '#{seen_cols[raw_col]}' — one Sigma control already covers it" }
    return nil
  end
  # surface the target column on the master (master_ref adds it if absent) and target it.
  ref = master_ref(raw_col, calc, master_cols, dmel)
  col_id = ref['id']
  ctl_id = 'qs-' + raw_col.to_s.gsub(/[^A-Za-z0-9]/, '') + '-filter'
  seen_cols[raw_col] = ctl_id
  el = { 'id' => nid('ctlel'), 'kind' => 'control', 'controlId' => ctl_id,
         'name' => label.to_s }
  is_date = ctype == 'DateTimePicker' || ctype == 'RelativeDateTime' ||
            raw_col.to_s =~ /(^|_)(date|dt|timestamp)(_|$)/i
  if is_date
    # date target: a `list` control on a datetime column is silently stripped by the
    # spec API, so a date-range control is the faithful shape (needs a flat `mode`).
    el.merge!('controlType' => 'date-range', 'mode' => 'between',
              'includeNulls' => 'when-no-value-is-selected',
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => col_id }])
  else
    el.merge!('controlType' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple',
              'values' => [],
              'source' => { 'kind' => 'source',
                            'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => col_id },
              'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'master' }, 'columnId' => col_id }])
  end
  scope << { 'controlId' => ctl_id, 'sourceName' => sig, 'status' => 'wired',
             'controlType' => el['controlType'], 'scope' => 'page', 'mustReach' => [],
             'wired' => [{ 'elementId' => 'master', 'columnId' => col_id }] }
  el
end

# control-scope + signal accounting (filled in the sheet loop, written as control-scope.json)
control_scope = []      # CONTRACT rows for control_lint.rb gate (c)
control_unbound = []     # manual/duplicate/unbound signals (loud, never silent)
control_seen_cols = {}   # raw col -> ctl_id (dedupe; QS associative = global, like qlik)
n_control_signals = 0    # QS filter/parameter control objects encountered (sourceFilterSignals)

# MULTI-SHEET -> MULTI-PAGE (the big fidelity fix): every QuickSight SHEET becomes its
# own Sigma PAGE (page name = sheet name), each page holding only that sheet's visuals.
# Previously ALL sheets flattened onto a single "page-dash", so the layout step (which
# only read Sheets[0]) silently lost every visual on sheet 2..N. We now collect elements
# PER SHEET and record the sheet<->page<->visual mapping for the layout step.
sheet_pages = []   # [{ "pageId"=>, "name"=>, "sheetIndex"=>, "elements"=>[...] }]
vis_map = {}       # QS VisualId -> Sigma element id (globally unique within an analysis)
defn['Sheets'].each_with_index do |sh, sheet_idx|
  elements = []
  (sh['Visuals'] || []).each do |v|
    vtype, inner = v.first
    title = (inner.dig('Title', 'FormatText', 'PlainText') || (inner.is_a?(Hash) ? inner['VisualId'] : nil) || vtype)
    kind = KIND[vtype]
    is_fallback = false
    unless kind
      # D18: a QS type with no native Sigma kind. If it has a dim+measure fallback
      # mapping, DATA-MIGRATE it (build a Sigma table/bar from the underlying fields)
      # and still warn; otherwise it is a genuine drop (Insight/CustomContent/Plugin/
      # Empty/LayerMap) and we skip it.
      fk = QS_FALLBACK[vtype]
      reason = QS_UNSUPPORTED[vtype] || "unrecognized QuickSight visual type '#{vtype}'"
      build_warnings << { 'visual' => title, 'type' => vtype, 'reason' => reason }
      unless fk
        STDERR.puts "  ! skipped #{vtype} (#{title}): #{reason}"
        next
      end
      kind = fk; is_fallback = true
      STDERR.puts "  ~ #{vtype} (#{title}): no native Sigma kind -> migrated as #{fk} (#{reason})"
    end
    eid = nid
    vis_map[inner['VisualId']] = eid
    # PieChartVisual → pie-chart by default. Map to donut-chart ONLY when QuickSight
    # is rendering a REAL donut: DonutOptions.ArcOptions.ArcThickness is present AND
    # not 'WHOLE'. QuickSight's ArcThickness enum is WHOLE|SMALL|MEDIUM|LARGE — WHOLE
    # means a solid pie (no hole), SMALL/MEDIUM/LARGE are donuts. (The QS console also
    # emits a DonutOptions block for a plain pie, so presence of the key alone is not a
    # donut signal — orders-overview "Net Revenue by Region"=MEDIUM stays a donut;
    # D3 "Revenue Mix by Channel"=WHOLE becomes a pie.)
    if vtype == 'PieChartVisual'
      arc = inner.dig('ChartConfiguration', 'DonutOptions', 'ArcOptions', 'ArcThickness')
      kind = 'donut-chart' if arc && arc.to_s.upcase != 'WHOLE'
    end
    fw = (inner['ChartConfiguration'] || {})['FieldWells'] || {}
    w = fw.values.find { |x| x.is_a?(Hash) } || fw
    rol = ->(key) { (w[key] || []).map { |f| field_role(f) }.compact }
    base = { 'id' => eid, 'kind' => kind, 'name' => title, 'source' => { 'elementId' => 'master', 'kind' => 'table' } }
    # value labels on bar/pie/donut (Sigma defaults them OFF); lines stay clean
    base['dataLabel'] = { 'labels' => 'shown' } if %w[bar-chart pie-chart donut-chart].include?(kind)
    el = nil

    case kind
    when 'kpi-chart'
      # KPI + Gauge both surface a single value
      vals = rol.('Values'); (next if vals.empty?)
      c, cid = meas_col(vals[0], calc, master_cols, DMEL, M)
      el = base.merge('columns' => [c.merge('name' => title)], 'value' => { 'columnId' => cid })
    when 'bar-chart', 'line-chart', 'area-chart'
      # funnel/treemap land here too: their dim is in Category/Groups, measure in Values/Sizes
      if is_fallback
        # D18 waterfall/histogram -> bar. Use the generic flattener (non-standard wells).
        fdims, fmeas = all_field_roles(w)
        dims = fdims; vals = fmeas
      else
        dims = rol.('Category'); dims = rol.('Groups') if dims.empty?
        vals = rol.('Values'); vals = rol.('Sizes') if vals.empty?
      end
      # Histogram fallback has only a numeric measure and NO category. Use that column
      # as the (un-aggregated) x dimension and Count the rows as y, so the per-value
      # distribution still migrates as bars.
      if is_fallback && dims.empty? && !vals.empty?
        dims = [[:dim, vals[0][1], nil]]
        vals = [[:meas, vals[0][1], 'COUNT']]
      end
      # D12: drop null window/table-calc measures (they render as blank series); keep them
      # in the DM master. If none survive, the chart has nothing to plot -> skip it.
      dropped_w = vals.select { |mv| window_meas?(mv, calc) }
      dropped_w.each { |mv| build_warnings << { 'visual' => title, 'type' => 'WindowCalcColumn', 'reason' => "measure '#{mv[1]}' is a QuickSight window/table-calc - dropped from the chart (kept in the data model); re-author in Sigma" } }
      vals -= dropped_w
      if vals.empty?
        STDERR.puts "  ! skipped #{kind} (#{title}): only measure(s) were QuickSight window/table-calc (null in Sigma)"
        next
      end
      (next if dims.empty? || vals.empty?)
      # D20: a date dimension carrying a QS DateGranularity (e.g. MONTH on a line chart)
      # is truncated to that grain so the x-axis aggregates by month/quarter/year instead
      # of plotting raw datetime (otherwise the line is spiky/per-row).
      dc, did = if dims[0][3]
                  date_dim_col(dims[0], calc, master_cols, DMEL, M)
                else
                  dim_col(dims[0], calc, master_cols, DMEL, M)
                end
      cols = [dc]; ycids = []
      vals.each { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; ycids << id }
      el = base.merge('columns' => cols, 'xAxis' => { 'columnId' => did }, 'yAxis' => { 'columnIds' => ycids })
      # D20: honor QuickSight BarChartVisual Orientation. HORIZONTAL -> Sigma
      # orientation:"horizontal"; VERTICAL (default) is expressed by OMITTING the field
      # (Sigma rejects orientation:"vertical"). Only meaningful for bar charts.
      if kind == 'bar-chart'
        qs_orient = (inner['ChartConfiguration'] || {})['Orientation']
        el['orientation'] = 'horizontal' if qs_orient.to_s.upcase == 'HORIZONTAL'
      end
      # B-gap COLOR: by-measure (ColorScale dup column) / by-dimension (Colors well).
      cclr = qs_color(inner, w, el, [did], ycids, calc, master_cols, DMEL, M)
      el['color'] = cclr if cclr
      # A-gap REFERENCE LINES -> refMarks (wrapped value:{type:formula}).
      rms = qs_reference_lines(inner, calc, master_cols, DMEL, M, title, build_warnings)
      el['refMarks'] = rms unless rms.empty?
    when 'pie-chart', 'donut-chart'
      dims = rol.('Category'); vals = rol.('Values'); (next if dims.empty? || vals.empty?)
      dc, did = dim_col(dims[0], calc, master_cols, DMEL, M); mc2, mid = meas_col(vals[0], calc, master_cols, DMEL, M)
      el = base.merge('columns' => [dc, mc2], 'color' => { 'id' => did }, 'value' => { 'id' => mid })
    when 'combo-chart'
      dims = rol.('Category'); bars = rol.('BarValues'); lines = rol.('LineValues')
      [bars, lines].each do |arr|
        arr.select { |mv| window_meas?(mv, calc) }.each do |mv|
          build_warnings << { 'visual' => title, 'type' => 'WindowCalcColumn', 'reason' => "measure '#{mv[1]}' is a QuickSight window/table-calc - dropped from the combo chart (kept in the data model)" }
        end
      end
      bars  = bars.reject  { |mv| window_meas?(mv, calc) }
      lines = lines.reject { |mv| window_meas?(mv, calc) }
      if bars.empty? && lines.empty?
        STDERR.puts "  ! skipped combo-chart (#{title}): only measure(s) were QuickSight window/table-calc"
        next
      end
      (next if dims.empty? || (bars.empty? && lines.empty?))
      dc, did = dim_col(dims[0], calc, master_cols, DMEL, M); cols = [dc]; ycids = []
      bars.each  { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; ycids << id }
      lines.each { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; ycids << { 'columnId' => id, 'type' => 'line' } }
      el = base.merge('columns' => cols, 'xAxis' => { 'columnId' => did }, 'yAxis' => { 'columnIds' => ycids })
      cclr = qs_color(inner, w, el, [did], [], calc, master_cols, DMEL, M)  # combo: by-dimension only
      el['color'] = cclr if cclr && cclr['by'] == 'category'
      rms = qs_reference_lines(inner, calc, master_cols, DMEL, M, title, build_warnings)
      el['refMarks'] = rms unless rms.empty?
    when 'scatter-chart'
      xs = rol.('XAxis'); ys = rol.('YAxis'); cat = rol.('Category'); sz = rol.('Size')
      (next if xs.empty? || ys.empty?)
      xc, xid = meas_col(xs[0], calc, master_cols, DMEL, M); yc, yid = meas_col(ys[0], calc, master_cols, DMEL, M)
      if cat.any?
        # A QuickSight scatter is measure-vs-measure with the Category field as the POINT
        # identity. Sigma's scatter axis is a GROUPING axis: an aggregate (Sum(...)) over
        # the UNGROUPED master evaluates per-row and every point collapses to one x — the
        # spec POSTs but renders wrong (bead ry0n; ported from the live-verified
        # qlik-to-sigma builder, 2026-06-15). Correct shape: bind the scatter to a HIDDEN
        # GROUPED source table (one row per point dim) and reference its grouped columns
        # with raw refs; the dim stays on color:{by:category} so points don't merge.
        dc, did = dim_col(cat[0], calc, master_cols, DMEL, M)
        gcols = [dc, xc, yc]          # group dim + x + y (+ size); columns live on the source
        gcids = [xid, yid]            # aggregated calculations (size appended below)
        szc = nil
        if sz.any?
          szc, szid = meas_col(sz[0], calc, master_cols, DMEL, M)
          gcols << szc; gcids << szid
        end
        src_id = "#{eid}-src"; src_name = "Scatter Source #{eid[-6..-1]}"
        grp_id = "#{src_id}-g"
        scatter_sources << { 'id' => src_id, 'kind' => 'table', 'name' => src_name,
                             'visibleAsSource' => false,
                             'source' => { 'elementId' => 'master', 'kind' => 'table' },
                             'columns' => gcols,
                             'groupings' => [{ 'id' => grp_id, 'groupBy' => [did], 'calculations' => gcids }] }
        # RAW (non-aggregating) refs into the grouped source, one per channel.
        raw = lambda do |col|
          { 'id' => "#{eid}-#{col['id']}", 'formula' => "[#{src_name}/#{col['name']}]", 'name' => col['name'] }
        end
        s_dim = raw.(dc); s_x = raw.(xc); s_y = raw.(yc)
        scols = [s_dim, s_x, s_y]
        el = base.merge('source' => { 'elementId' => src_id, 'kind' => 'table', 'groupingId' => grp_id },
                        'xAxis' => { 'columnId' => s_x['id'] }, 'yAxis' => { 'columnIds' => [s_y['id']] },
                        'color' => { 'by' => 'category', 'column' => s_dim['id'] })
        # D8 (now a real channel): QuickSight scatter Size becomes a Sigma scatter
        # size:{id} channel over the grouped source's size aggregate.
        if szc
          s_sz = raw.(szc); scols << s_sz; el['size'] = { 'id' => s_sz['id'] }
        end
        el['columns'] = scols
      else
        # No point dimension: keep the prior measure-vs-measure-on-master behavior
        # (a single ungrouped scatter point is still the faithful migration here).
        el = base.merge('columns' => [xc, yc], 'xAxis' => { 'columnId' => xid }, 'yAxis' => { 'columnIds' => [yid] })
        # D8: QuickSight scatter Size (bubble radius) with no grouping. Sigma scatter has no
        # verified ungrouped size channel, so we PROJECT the size measure as a column (data
        # migrates) and record a warning that bubble-sizing renders uniform.
        if sz.any?
          szc, _szid = meas_col(sz[0], calc, master_cols, DMEL, M); el['columns'] << szc
          build_warnings << { 'visual' => title, 'type' => 'ScatterBubbleSize', 'reason' => "QuickSight scatter bubble-size ('#{sz[0][1]}') has no Sigma scatter size channel (no point dimension to group on); the measure is projected as a column but bubbles render uniform-size (Sigma limitation)" }
        end
      end
      # A-gap REFERENCE LINES on scatter (e.g. an x=Margin-Target line).
      rms = qs_reference_lines(inner, calc, master_cols, DMEL, M, title, build_warnings)
      el['refMarks'] = rms unless rms.empty?
    when 'table'
      cf_fieldmap = {}   # QS FieldId -> Sigma column id (for D19 conditional formatting)
      if is_fallback
        # D18 sankey/box-plot/word-cloud/radar/heat-map -> table. Flatten every well
        # (Source/Destination/Weight, GroupBy/Size, Category/Color/Values, ...) into a
        # grouped table: all dims become group-bys, all measures become aggregates.
        dims, vals = all_field_roles(w)
        raw_dims = []; raw_vals = []  # fallback has no CF
      else
        dims = rol.('GroupBy'); vals = rol.('Values')
        raw_dims = (w['GroupBy'] || []); raw_vals = (w['Values'] || [])
      end
      # D12: drop null window/table-calc measures from the TABLE (blank columns look broken);
      # they remain in the DM master with their original expr in the description.
      unless is_fallback
        keep_idx = vals.each_index.reject { |i| window_meas?(vals[i], calc) }
        dropped_idx = vals.each_index.to_a - keep_idx
        dropped_idx.each { |i| build_warnings << { 'visual' => title, 'type' => 'WindowCalcColumn', 'reason' => "column '#{vals[i][1]}' is a QuickSight window/table-calc - dropped from the table (kept in the data model); re-author in Sigma" } }
        vals = keep_idx.map { |i| vals[i] }
        raw_vals = keep_idx.map { |i| raw_vals[i] }
      end
      cols = []; gids = []; cids = []
      dims.each_with_index { |d, i| c, id = dim_col(d, calc, master_cols, DMEL, M); cols << c; gids << id; (fi = field_id(raw_dims[i])) && (cf_fieldmap[fi] = id) }
      vals.each_with_index { |mv, i| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; cids << id; (fi = field_id(raw_vals[i])) && (cf_fieldmap[fi] = id) }
      (next if cols.empty?)
      el = base.merge('columns' => cols)
      el['groupings'] = [{ 'id' => nid('g'), 'groupBy' => gids, 'calculations' => cids }] unless gids.empty?
      # D19: migrate QS TableVisual ConditionalFormatting (gradient cell color / data bars)
      # into Sigma `conditionalFormats` on the table element.
      if (cfb = inner['ConditionalFormatting'])
        cfmts = qs_conditional_formats(cfb, cf_fieldmap)
        unless cfmts.empty?
          el['conditionalFormats'] = cfmts
          STDERR.puts "  + #{cfmts.size} conditional format rule(s) migrated on table \"#{title}\""
        end
      end
    when 'pivot-table'
      rows = rol.('Rows'); pcols = rol.('Columns'); vals = rol.('Values'); cols = []; rids = []; coids = []; vids = []
      rows.each  { |d| c, id = dim_col(d, calc, master_cols, DMEL, M); cols << c; rids << id }
      pcols.each { |d| c, id = dim_col(d, calc, master_cols, DMEL, M); cols << c; coids << id }
      vals.each  { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; vids << id }
      (next if rids.empty? || vids.empty?)
      el = base.merge('columns' => cols, 'rowsBy' => rids.map { |i| { 'id' => i } }, 'values' => vids)
      el['columnsBy'] = coids.map { |i| { 'id' => i } } unless coids.empty?
    when 'region-map', 'point-map'
      # QuickSight FilledMap/GeospatialMap: Geospatial holds the geo field(s),
      # Values holds the measure that fills/sizes the map. (Colors is optional and
      # rendered automatically by Sigma from the measure, so it is not a separate well.)
      geo  = rol.('Geospatial')
      vals = rol.('Values')
      (next if geo.empty?)
      pair = latlong_pair(geo)
      cols = []
      if pair
        # real lat/long -> point-map
        latc, latid = meas_col([:meas, pair[0][1], 'AVERAGE'], calc, master_cols, DMEL, M)
        lonc, lonid = meas_col([:meas, pair[1][1], 'AVERAGE'], calc, master_cols, DMEL, M)
        # carry lat/long as dimension-style refs (no aggregation) for the point geometry
        latc = { 'id' => latid, 'formula' => latc['formula'].sub(/^Avg\(/, '').sub(/\)$/, ''), 'name' => latc['name'] }
        lonc = { 'id' => lonid, 'formula' => lonc['formula'].sub(/^Avg\(/, '').sub(/\)$/, ''), 'name' => lonc['name'] }
        cols << latc << lonc
        vals.each { |mv| c, _ = meas_col(mv, calc, master_cols, DMEL, M); cols << c }
        el = base.merge('kind' => 'point-map', 'columns' => cols,
                        'latitude' => { 'id' => latid }, 'longitude' => { 'id' => lonid })
      else
        # geo NAME (state/city/country/zip) -> region-map
        dc, did = dim_col(geo[0], calc, master_cols, DMEL, M); cols << dc
        vals.each { |mv| c, _ = meas_col(mv, calc, master_cols, DMEL, M); cols << c }
        el = base.merge('kind' => 'region-map', 'columns' => cols,
                        'region' => { 'id' => did, 'regionType' => region_type_for(geo[0][1]) })
      end
    end
    # carry the visual's QS SortConfiguration (CategorySort/RowSort) when present
    apply_qs_sorts(el, inner, kind, title, build_warnings) if el
    elements << el if el
  end
  # C-gap: QuickSight sheet-level FilterControls + ParameterControls -> Sigma list
  # controls. QS selections are GLOBAL on the sheet (and FilterGroups can scope AllSheets),
  # so a control wired to the master propagates to every chart that sources it.
  ((sh['FilterControls'] || []) + (sh['ParameterControls'] || [])).each do |wrap|
    next unless wrap.is_a?(Hash)
    n_control_signals += 1
    ctl = build_qs_control(wrap, master_cols, calc, DMEL,
                           control_scope, control_unbound, control_seen_cols, build_warnings)
    if ctl
      elements.unshift(ctl)   # controls render at the top of the page band
      vis_map[ctl['controlId']] = ctl['id']   # layout step can place it if QS gives coords
    end
  end
  # one Sigma page per QS sheet (skip a sheet that produced zero elements)
  pid = sheet_idx.zero? ? 'page-dash' : "page-sheet-#{sheet_idx}"
  sheet_pages << { 'pageId' => pid, 'name' => (sh['Name'] || "Sheet #{sheet_idx + 1}"),
                   'sheetIndex' => sheet_idx, 'elements' => elements }
end

# Record a (c)-tail warning for any what-if PARAMETER inlined as a constant (the
# interactive control itself is a manual Sigma re-author; the default value is what
# the migrated workbook shows).
PARAM_DEFAULTS.each do |nm, dv|
  used = (defn['CalculatedFields'] || []).any? { |c| c['Expression'].to_s.include?("${#{nm}}") }
  next unless used
  build_warnings << { 'visual' => '(parameter)', 'type' => 'WhatIfParameter',
                      'reason' => "QuickSight what-if parameter '#{nm}' inlined as its default (#{dv}); add a Sigma control to make it interactive" }
end

# strip the private _window marker before emit

master_cols.each_value { |c| c.delete('_window'); c.delete('description') if c['formula'] != 'Null' }

master = { 'id' => 'master', 'name' => M, 'kind' => 'table', 'visibleAsSource' => false,
           'source' => { 'dataModelId' => dm_id, 'elementId' => dm_el, 'kind' => 'data-model' },
           'columns' => master_cols.values }

# ---- apply surfaced dataset filter(s) (beads-sigma-23xu FilterOperation) ----
# convert-model writes the QS predicate(s) to dm-filters.json. We translate a simple
# {COL}='VALUE' equality predicate into a Sigma element-level list filter on the
# master, so every downstream aggregate honors it. The filtered column is added to
# the master if it isn't already projected.
filters_path = opts[:filters] || File.join(File.dirname(File.expand_path(opts[:an])), 'dm-filters.json')
applied_filters = []
if File.exist?(filters_path)
  fdata = JSON.parse(File.read(filters_path)) rescue {}
  (fdata['filters'] || []).each do |pred|
    m = pred.to_s.match(/\{([^}]+)\}\s*=\s*'([^']*)'/) || pred.to_s.match(/\{([^}]+)\}\s*=\s*"([^"]*)"/)
    next unless m
    raw_col = m[1].strip; val = m[2]
    ref = master_ref(raw_col, calc, master_cols, DMEL)
    # master_cols may have been re-read; ensure the col is on the master
    unless master.fetch('columns').any? { |c| c['id'] == ref['id'] }
      master['columns'] << master_cols[raw_col]
    end
    applied_filters << { 'id' => "flt-#{SecureRandom.hex(4)}", 'kind' => 'list',
                         'columnId' => ref['id'], 'values' => [val] }
  end
  master['filters'] = applied_filters unless applied_filters.empty?
end
# refresh master columns (master_ref may have added the filter column)
master['columns'] = master_cols.values

# Build one Sigma page per QS sheet. A sheet that produced zero elements is still
# emitted (named after the sheet) so the page exists — but a single dash page is the
# common case. The shared Data page (master) is always page 0.
dash_pages = sheet_pages.map do |sp|
  { 'id' => sp['pageId'], 'name' => sp['name'], 'elements' => sp['elements'] }
end
# defensive: if an analysis somehow had no sheets, keep an empty dash page so the
# workbook is still valid.
if dash_pages.empty?
  dash_pages = [{ 'id' => 'page-dash', 'name' => (an['Name'] || 'Dashboard'), 'elements' => [] }]
  sheet_pages = [{ 'pageId' => 'page-dash', 'name' => (an['Name'] || 'Dashboard'), 'sheetIndex' => 0, 'elements' => [] }]
end

# Scatter charts emit a hidden GROUPED source table (one row per point dim). Park
# them on the Data page next to the master (visibleAsSource:false, so they need no
# layout slot) — they're sourced by the scatter element via {elementId, groupingId}.
data_elements = [master] + scatter_sources

spec = { 'name' => (an['Name'] || 'QuickSight Migration') + ' (from QuickSight)',
         'schemaVersion' => 1,
         'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'elements' => data_elements }] + dash_pages }
spec['folderId'] = opts[:folder] if opts[:folder]

File.write(opts[:out], JSON.pretty_generate(spec))
map_out = opts[:out].sub(/\.json$/, '') + '.map.json'
# Map carries: the legacy single dashPageId (= first sheet's page, for back-compat),
# the per-sheet page list (sheetIndex -> pageId/name) so the layout step lays out EACH
# page from its OWN sheet's QS layout, and the global visual->element map.
# controlElementIds: the Sigma element ids of the kind:control elements (per page).
# QS controls live in SheetControlLayouts, not the visual GridLayout, so the layout step
# can't place them by QS coords — it LIFTS them into a clean full-width top band instead
# (Sigma's grid has no z-order; floating a control over a chart renders stacked).
control_eids_by_page = {}
dash_pages.each do |pg|
  ids = (pg['elements'] || []).select { |e| e['kind'] == 'control' }.map { |e| e['id'] }
  control_eids_by_page[pg['id']] = ids unless ids.empty?
end
File.write(map_out, JSON.pretty_generate(
  'dashPageId' => (sheet_pages.first && sheet_pages.first['pageId']) || 'page-dash',
  'masterElementId' => 'master',
  'sheetPages' => sheet_pages.map { |sp| { 'pageId' => sp['pageId'], 'name' => sp['name'], 'sheetIndex' => sp['sheetIndex'] } },
  'controlElementIds' => control_eids_by_page,
  'visualToElement' => vis_map))

# Persist a machine-readable per-visual warning manifest for any QuickSight visual
# Sigma can't recreate (sankey/radar/box-plot/waterfall/word-cloud/histogram/heat-map/
# layer-map/insight-ML/custom-content/plugin). This is the (c)-tail record — a clear
# "dropped, here's why" rather than a silent omission.
warn_out = opts[:out].sub(/\.json$/, '') + '.warnings.json'
File.write(warn_out, JSON.pretty_generate('warnings' => build_warnings))

# control-scope.json — the intended-scope contract sidecar (schema: the CONTRACT block
# in scripts/lib/control_lint.rb). QuickSight sheet/AllSheets filters are GLOBAL, so every
# wired control's mustReach = every queryable element on every CONTENT page (Qlik parity).
# post-and-readback.rb (--type workbook) and assert-phase6-ran.rb gate 7 pick it up from
# <workdir>/control-scope.json automatically; we write it next to the spec (= the workdir).
# sourceFilterSignals > 0 with zero spec controls FAILS gate 7 — the silently-dropped class
# this change exists to kill.
CTL_QUERYABLE = %w[table pivot-table bar-chart line-chart pie-chart donut-chart
                   area-chart scatter-chart combo-chart kpi-chart region-map point-map].to_set
must_reach = dash_pages.flat_map { |pg| pg['elements'] }
                       .select { |e| CTL_QUERYABLE.include?(e['kind']) }
                       .map { |e| e['id'] }
control_scope.each { |sc| sc['mustReach'] = must_reach if sc['status'] == 'wired' }
scope_out = File.join(File.dirname(File.expand_path(opts[:out])), 'control-scope.json')
File.write(scope_out, JSON.pretty_generate(
  'version' => 1, 'source' => 'quicksight', 'sourceFilterSignals' => n_control_signals,
  'controls' => control_scope, 'unbound' => control_unbound))
STDERR.puts "control-scope: #{n_control_signals} QS control signal(s) -> #{control_scope.size} wired Sigma control(s)" \
            "#{control_unbound.empty? ? '' : ", #{control_unbound.size} unbound/manual/duplicate"} → #{scope_out}"

all_elements = sheet_pages.flat_map { |sp| sp['elements'] }
STDERR.puts "workbook spec: master sources DM element \"#{DMEL}\" (#{dm_el}); #{sheet_pages.size} page(s)/#{all_elements.size} chart elements, #{master_cols.size} master cols#{applied_filters.empty? ? '' : "; #{applied_filters.size} filter(s) applied"} → #{opts[:out]} (+ #{map_out})"
sheet_pages.each do |sp|
  STDERR.puts "  page \"#{sp['name']}\" (#{sp['pageId']}): #{sp['elements'].size} element(s)"
  sp['elements'].each { |e| STDERR.puts "    - #{e['kind']}: #{e['name']}" }
end
unless build_warnings.empty?
  fb, dropped = build_warnings.partition { |w| QS_FALLBACK.key?(w['type']) }
  STDERR.puts "#{build_warnings.size} visual(s) with no native Sigma kind → #{warn_out}" \
              " (#{fb.size} data-migrated as table/bar fallback, #{dropped.size} genuinely dropped)"
  fb.each      { |w| STDERR.puts "  ~ #{w['type']}: #{w['reason']}" }
  dropped.each { |w| STDERR.puts "  ! #{w['type']}: #{w['reason']}" }
end
