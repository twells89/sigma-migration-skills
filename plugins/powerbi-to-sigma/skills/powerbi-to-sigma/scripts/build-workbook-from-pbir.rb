#!/usr/bin/env ruby
# build-workbook-from-pbir.rb — map normalized PBIR signals -> Sigma workbook spec.
#
# Power BI analog of tableau-to-sigma's build-charts-from-signals.rb. Input is
# extract-pbir.py's signals.json (per-visual kind + role bindings + position).
# Output is a complete Sigma workbook spec (Data page of hidden masters + a
# page of chart elements) ready for POST /v2/workbooks/spec via
# post-and-readback.rb, plus a 24-col grid layout string for put-layout.rb.
#
# It applies the measure-translation patterns documented in
# refs/measure-patterns.md:
#   - line charts default to a SINGLE series (no color split) unless a Series/
#     Legend role is bound (beads-sigma-c07);
#   - PBI measure refs ("EMPLOYEES.Total Salary") map to a measure formula via a
#     measure-map (Sum/Count/CountDistinct/…); dimensions map to bare/master refs;
#   - kpi/bar/line/pie/donut/table/pivot-table element shapes per spec-fixups.md.
#
# Usage:
#   ruby scripts/build-workbook-from-pbir.rb \
#     --signals /tmp/pbir/signals.json \
#     --master-map /tmp/pbir/master-map.json \
#     --data-model <dataModelId> \
#     --out /tmp/pbir/workbook-spec.json \
#     --layout-out /tmp/pbir/layout.xml \
#     [--name "Workforce KitchenSink (from Power BI)"] \
#     [--folder-id <uuid>]
#
# master-map.json shape — maps each PBI "Entity" to a Data-page master table and
# each "Entity.Field" queryRef to {ref, agg}. `ref` is the Sigma column path
# (e.g. "[EMP/Annual Salary]"); `agg` is the Sigma aggregator name for measures
# (Sum/Count/CountDistinct/Avg/Min/Max) or null for a dimension. Example:
#   {
#     "masters": {
#       "EMP": {"id":"master-emp","element_id":"<dmElementId>","data_model":"<dmId>",
#               "columns":[{"id":"me-salary","name":"Annual Salary","formula":"[EMPLOYEES/Annual Salary]"}, ...]}
#     },
#     "fields": {
#       "EMPLOYEES.DEPARTMENT":   {"master":"EMP","ref":"[EMP/Department]","agg":null},
#       "EMPLOYEES.Total Salary": {"master":"EMP","ref":"[EMP/Annual Salary]","agg":"Sum"},
#       "EMPLOYEES.Headcount":    {"master":"EMP","ref":"[EMP/Employee Id]","agg":"Count"},
#       "SAFETY_INCIDENTS.Incident Count": {"master":"INC","ref":"[INC/Incident Id]","agg":"CountDistinct"}
#     }
#   }
#
# The master-map is the one PBI-specific artifact the agent authors (it encodes
# the DM element ids + the DAX-measure→Sigma-aggregator decisions). Everything
# else is mechanical. Idempotent: deterministic ids from visual_id, re-runnable.

require 'json'
require 'optparse'
require_relative 'lib/layout'
include SigmaLayout

opts = {}
OptionParser.new do |p|
  p.on('--signals PATH')     { |v| opts[:sig] = v }
  p.on('--master-map PATH')  { |v| opts[:mmap] = v }
  p.on('--bim PATH', 'model.bim — geo dataCategory lookup so PBI map visuals emit real Sigma region/point maps') { |v| opts[:bim] = v }
  p.on('--image-map PATH', 'JSON {registeredResourceName: hostedUrl} — PBI image visuals become Sigma image elements (no map: skipped with a note)') { |v| opts[:imap] = v }
  p.on('--layout MODE', 'clean (default: opinionated Sigma-native grid — dark header, KPI row, uniform 2-up chart grid) | pbi (flat canvas-proportional, matches the PBI page 1:1) | banded (legacy row-band containers)') { |v| opts[:layout_mode] = v }
  p.on('--data-model ID')    { |v| opts[:dm] = v }
  p.on('--out PATH')         { |v| opts[:out] = v }
  p.on('--layout-out PATH')  { |v| opts[:layout_out] = v }
  p.on('--name NAME')        { |v| opts[:name] = v }
  # The SOURCE report/dashboard display name (e.g. "EMPLOYEE DASHBOARD") —
  # header-band title fallback when a page has no promotable title textbox and
  # its own name is a generic auto-name ("Page 1"). See resolve_header_title.
  p.on('--source-title NAME') { |v| opts[:source_title] = v }
  p.on('--folder-id ID')     { |v| opts[:folder] = v }
  # Control-targeting wave (workstream B): the TMSL model (model.bim / .tmsl)
  # supplies the relationships a PBI slicer's filter flows through, so each
  # control can be wired to EVERY master whose table the slicer reaches —
  # not just the master the sliced column lives on. Optional: without it,
  # slicers wire same-table masters only (a WARN says the scope was reduced).
  p.on('--model PATH')       { |v| opts[:model] = v }
  # Where the intended-scope contract lands (consumed by workstream A's lint).
  # Default: control-scope.json next to --out.
  p.on('--control-scope-out PATH') { |v| opts[:scope_out] = v }
end.parse!
%i[sig mmap out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

signals = JSON.parse(File.read(opts[:sig]))
$image_map = (opts[:imap] && File.exist?(opts[:imap])) ? JSON.parse(File.read(opts[:imap])) : {}
if opts[:bim] && File.exist?(opts[:bim])
  $geo_categories ||= {}
  $sort_by_column ||= {}
  _bim = JSON.parse(File.read(opts[:bim]))
  _model = _bim['model'] || _bim
  (_model['tables'] || []).each do |t|
    (t['columns'] || []).each do |c|
      $geo_categories["#{t['name']}.#{c['name']}".downcase] = c['dataCategory'] if c['dataCategory']
      # PBI sort-by-column ("FiscalMonth" sorts by "Period") — without it Sigma
      # sorts month names ALPHABETICALLY (Apr, Aug, Feb…), a top complaint on
      # converted dashboards. Recorded as 'table.field' -> 'table.sortfield'.
      $sort_by_column["#{t['name']}.#{c['name']}".downcase] = "#{t['name']}.#{c['sortByColumn']}" if c['sortByColumn']
    end
  end
  warn "[build-workbook] geo metadata: #{$geo_categories.length} dataCategory, #{$sort_by_column.length} sortByColumn column(s) from #{opts[:bim]}"
end
mmap    = JSON.parse(File.read(opts[:mmap]))
fields  = mmap['fields'] || {}
masters = mmap['masters'] || {}

# ---------------------------------------------------------------------------
# Slicer relationship scope (control-targeting wave, workstream B).
# A PBI slicer filters its page ACROSS related tables: the filter flows from
# the sliced table along model relationships (one side -> many side; both ways
# when crossFilteringBehavior is bothDirections; inactive rels don't flow).
# ---------------------------------------------------------------------------
_tmsl = opts[:model] && File.exist?(opts[:model]) ? (JSON.parse(File.read(opts[:model])) rescue nil) : nil
_tmodel = _tmsl && (_tmsl['model'] || _tmsl)
MODEL_RELATIONSHIPS = _tmodel ? (_tmodel['relationships'] || []) : []
MODEL_TABLES_FULL = _tmodel ? (_tmodel['tables'] || []) : []
MODEL_TABLES = MODEL_TABLES_FULL.map { |t| t['name'].to_s }
warn '[build-workbook] NOTE: no --model TMSL given — slicer controls wire same-table masters only ' \
     '(relationship-scoped targets need the model).' if _tmodel.nil?

# Tables reachable by a filter applied on `entity` (always includes entity).
def reachable_entities(entity)
  adj = Hash.new { |h, k| h[k] = [] }
  MODEL_RELATIONSHIPS.each do |r|
    next if r['isActive'] == false                       # inactive: no filter flow
    from = r['fromTable'].to_s                           # many side
    to   = r['toTable'].to_s                             # one side
    adj[to] << from                                      # one filters many (PBI default)
    adj[from] << to if r['crossFilteringBehavior'].to_s =~ /both/i
  end
  seen = [entity]
  queue = [entity]
  until queue.empty?
    adj[queue.shift].each do |t|
      next if seen.include?(t)
      seen << t
      queue << t
    end
  end
  seen
end

# entity -> masters that can resolve at least one of its fields (primary + alts).
# Derived/restructured elements (Dense Rank …, time-intel, Custom SQL calc
# tables) surface as PSEUDO entities here — names that are not TMSL tables.
def entity_master_coverage(fields)
  cov = Hash.new { |h, k| h[k] = [] }
  fields.each do |k, v|
    ent = k.to_s.split('.').first
    ([v['master']] + Array(v['alts']).map { |a| a['master'] }).compact.each do |m|
      cov[ent] << m unless cov[ent].include?(m)
    end
  end
  cov
end

# Find the column on a master matching the sliced leaf. Exact (case/​separator-
# insensitive) name match wins; else a disambiguated "Leaf (ENTITY)" view column
# — preferring the sliced entity's own. Returns the column hash or nil. NEVER
# falls back to an arbitrary column (that was the silent wrong-column bug).
def match_master_column(mrec, leaf, prefer_entity = nil)
  norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
  cols = mrec['columns'] || []
  nl = norm.call(leaf)
  exact = cols.find { |c| norm.call(c['name']) == nl }
  return exact if exact
  cands = cols.select do |c|
    m = c['name'].to_s.match(/\A(.+?)\s+\(([^)]+)\)\s*\z/)
    m && norm.call(m[1]) == nl
  end
  preferred = prefer_entity && cands.find do |c|
    c['name'].to_s =~ /\(\s*#{Regexp.escape(prefer_entity)}\s*\)\s*\z/i
  end
  preferred || cands.first
end

# Intended-scope contract accumulators -> control-scope.json (the sidecar
# workstream A's control lint consumes — schema in lib/control_lint.rb header
# CONTRACT + refs/control-parity.md). `$control_scope` gets one entry per
# EMITTED control ({controlId, sourceName, scope:[element ids], excluded:[...]});
# `$control_unbound` records slicers that produced NO control element (an
# unresolvable column is dropped LOUDLY, never wired to a wrong column and
# never shipped dead) so the sidecar carries the full source-signal story.
$control_scope = []
$control_unbound = []
$used_control_ids = Hash.new(0)

# TMSL column type for ENTITY.LEAF — date-typed slicers must become date-range
# controls: a `list` control bound to a datetime column posts fine but Sigma
# SILENTLY STRIPS its filter targets (known estate-repair gotcha).
def tmsl_date_column?(ent, leaf)
  return false if MODEL_TABLES.empty?
  tmodel_tables = MODEL_TABLES_FULL
  t = tmodel_tables.find { |tb| tb['name'].to_s == ent.to_s }
  c = t && (t['columns'] || []).find { |col| col['name'].to_s.casecmp(leaf.to_s).zero? }
  !!(c && c['dataType'].to_s =~ /date/i)
end

SIGMA_KIND = {
  'kpi' => 'kpi-chart', 'bar' => 'bar-chart', 'line' => 'line-chart',
  'area' => 'area-chart', 'combo' => 'combo-chart', 'scatter' => 'scatter-chart',
  'pie' => 'pie-chart', 'donut' => 'donut-chart',
  'table' => 'table', 'pivot-table' => 'pivot-table', 'text' => 'text',
  'control' => 'control', 'map' => 'map', 'image' => 'image'
}.freeze

# PBI role -> (dim_role?, value_role?) per visual kind handled below.
# A field_map entry may carry `alts` — alternative {master, ref[, agg]} resolutions
# on OTHER masters (used for time-intel: a field can live on both the View and a
# grouped prior-year element). When the visual has chosen a master, prefer the
# alt that lives on it so all of the visual's columns resolve on one element.
def field_spec(queryref, fields, chosen_master = nil)
  fs = fields[queryref]
  # Case-insensitive fallback: PBIR queryRefs may carry the RAW warehouse column
  # name ("EMPLOYEES.DEPARTMENT") while the master-map keys on the Sigma display
  # name ("EMPLOYEES.Department"). Match ignoring case so the dimension resolves
  # instead of leaking a literal [EMPLOYEES.DEPARTMENT] ref that error-types.
  if fs.nil? && queryref
    # Normalize case AND underscore/space so a raw warehouse queryRef
    # ("ABSENCE_RECORDS.ABSENCE_TYPE") matches a display-name key
    # ("ABSENCE_RECORDS.Absence Type").
    norm = ->(s) { s.to_s.downcase.gsub(/[_\s]+/, ' ').strip }
    @ci_index ||= fields.each_with_object({}) { |(k, v), h| h[norm.call(k)] ||= v }
    fs = @ci_index[norm.call(queryref)]
  end
  fs ||= { 'master' => nil, 'ref' => "[#{queryref}]", 'agg' => nil }
  if chosen_master && fs['master'] != chosen_master && fs['alts'].is_a?(Array)
    alt = fs['alts'].find { |a| a['master'] == chosen_master }
    if alt
      merged = fs.merge(alt)
      # A verbatim `formula` on the PRIMARY resolution references the primary
      # master's columns — it is invalid on the alt's master (bead 525l). Drop it
      # unless the alt carries its own.
      merged.delete('formula') unless alt.key?('formula')
      return merged
    end
  end
  fs
end

# bead hjke(b): display-name leaf from a queryRef. Classic-report queryRefs can
# carry the AGGREGATED form "Sum(TABLE.COL)" — a naive split('.').last leaves a
# trailing paren ("COL)"). Unwrap any Func( ... ) wrapper(s) first, then take
# the dotted leaf.
def qr_leaf(qr, fallback = 'Value')
  s = qr.to_s.strip
  s = Regexp.last_match(1).strip while s =~ /\A[A-Za-z_][A-Za-z0-9_ ]*\(\s*(.*)\s*\)\z/
  leaf = s.split('.').last.to_s
  # bead c2kf: a '/' (or bracket) inside a generated column NAME breaks the
  # [Element/Col] cross-element ref path — "Avg $/Unit TY" parses as a
  # two-segment path and the referencing column compiles to type "error".
  # Sanitize at this single chokepoint so names and refs stay in sync.
  leaf = leaf.tr('[]', '').tr('/', '-')
  leaf.empty? ? fallback : leaf
end

# ---------------------------------------------------------------------------
# Derived element titles (phase-e layout-quality fix): classic report.json
# visuals routinely carry NO objects.title, and the old fallback surfaced the
# RAW visual id ("291ef87d16c50d7a3808") as the chart's display name. Derive a
# human title from the visual's projections instead — a raw id must NEVER
# surface as a display name (layout_lint.rb fails the build if one does).
# ---------------------------------------------------------------------------

# Humanized leaf for titles: strip agg wrappers + date-hierarchy "Variation"
# tails, underscores -> spaces, ALL-CAPS warehouse names -> Title Case (short
# acronyms like ZIP/ID stay upcased).
def title_leaf(qr, fallback = nil)
  s = qr.to_s.strip
  # "T.COL.Variation.Date Hierarchy.Month" -> the base column "T.COL"
  s = Regexp.last_match(1) if s =~ /\A(.+?)\.Variation\..+\z/i
  leaf = qr_leaf(s, nil)
  return fallback if leaf.nil? || leaf.empty?
  words = leaf.gsub(/_+/, ' ').strip.split(/\s+/)
  words.map { |w| w =~ /\A[A-Z0-9]+\z/ && w.length > 3 ? w.capitalize : w }.join(' ')
end

# True when a dimension queryRef is date-shaped (date hierarchy / date-named
# column) — those visuals read better as "<Measure> Over Time".
def dateish_qr?(qr)
  qr.to_s =~ /variation|hierarchy|\b(date|month|year|quarter|week|day)\b/i
end

# "Absence Count by Department" / "Hours by Location" / "Hires Over Time" —
# derived purely from the visual's role projections. Returns nil only when the
# visual has no usable bindings (caller falls back to the kind label).
def derived_title(rec, kind)
  b = rec['bindings'] || {}
  vals = b['Values'] || b['Y'] || []
  dims = b['Category'] || b['Axis'] || b['X'] || b['Group'] || b['Rows'] || b['Fields'] || []
  case kind
  when 'kpi-chart'
    title_leaf(vals.first || dims.first)
  when 'table'
    leaves = (b['Values'] || []).map { |q| title_leaf(q) }.compact.uniq
    return nil if leaves.empty?
    leaves.length > 3 ? "#{leaves.first(3).join(', ')} +#{leaves.length - 3}" : leaves.join(', ')
  when 'pivot-table'
    v = title_leaf(vals.first)
    r = title_leaf((b['Rows'] || b['Category'] || []).first)
    c = title_leaf((b['Columns'] || []).first)
    return nil unless v
    [v, r && "by #{r}", c && "and #{c}"].compact.join(' ')
  when 'scatter-chart'
    x = title_leaf((b['X'] || b['Values'] || []).first)
    y = title_leaf((b['Y'] || []).first)
    x && y ? "#{y} vs #{x}" : (y || x)
  else # bar/line/area/combo/pie/donut
    dim = dims.first || (b['Legend'] || []).first
    v = title_leaf(vals.first || (b['Y2'] || []).first)
    d = title_leaf(dim)
    return v || d if v.nil? || d.nil?
    dateish_qr?(dim) ? "#{v} Over Time" : "#{v} by #{d}"
  end
end

# Last-resort label per Sigma kind — still human-readable, never an id.
KIND_LABEL = {
  'kpi-chart' => 'KPI', 'bar-chart' => 'Bar Chart', 'line-chart' => 'Line Chart',
  'area-chart' => 'Area Chart', 'combo-chart' => 'Combo Chart',
  'scatter-chart' => 'Scatter Plot', 'pie-chart' => 'Pie Chart',
  'donut-chart' => 'Donut Chart', 'table' => 'Table', 'pivot-table' => 'Pivot Table'
}.freeze

# PBI numeric format string (from signals 'formats' or master-map field 'format')
# -> Sigma column format hash. Best-effort; only emits when a format is known.
# Sigma column format shape is { kind, formatString } (matches the converter's
# metric.format output). NOT { type, ... } — POST rejects a missing `kind`.
# Sigma format strings are d3-format syntax (e.g. ",.0f", "$,.0f", ".1%"),
# NOT Excel masks ("#,##0") — the latter is rejected as "Invalid number format
# string". Matches the converter's metric.format output (",.0f").
PBI_FMT = {
  'currency' => { 'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } },
  'percent'  => { 'format' => { 'kind' => 'number', 'formatString' => '.1%' } },
  'comma'    => { 'format' => { 'kind' => 'number', 'formatString' => ',.1f' } },
  'integer'  => { 'format' => { 'kind' => 'number', 'formatString' => ',.0f' } }
}.freeze
def sigma_format(hint)
  return nil if hint.nil? || hint.to_s.empty?
  h = hint.to_s
  return PBI_FMT['currency'] if h =~ /\$|currency|USD/i
  return PBI_FMT['percent']  if h =~ /%|percent/i
  return PBI_FMT['integer']  if h =~ /^#,?#?0$|integer|whole/i
  return PBI_FMT['comma']    if h =~ /#,##0|,/
  nil
end

# Apply a resolved format onto a column hash (mutates + returns it).
def apply_fmt(col, queryref, fields, vfmts)
  hint = (fields[queryref] || {})['format'] || (vfmts || {})[queryref]
  f = sigma_format(hint)
  col.merge!(f) if f
  col
end

# A field spec is a MEASURE unless it is a bare stored-column reference. The
# old `agg`/`formula`-emptiness test misclassified auto-derived master-map
# metrics (always agg:nil with the full expression in `ref`, e.g.
# "Median([m/Annual Salary])") as dimensions — tables then built UNGROUPED
# (1 row per source row) and scatters skipped their grouped source (ry0n).
def measure_ref?(fs)
  return true unless fs['agg'].to_s.empty? && fs['formula'].to_s.empty?
  !(fs['ref'].to_s =~ /\A\[[^\]]+\]\z/)
end

def measure_formula(fs)
  # bead qb2i: an explicit `formula` wins — lets the master-map emit a verbatim
  # Sigma expression (e.g. a window calc "Lag(Sum([X/v]), 1)" / "Rank(Sum([X/v]),
  # \"desc\")" / percent-of-total "Sum([X/v]) / GrandTotal(Sum([X/v]))") the
  # agg/`?` encodings can't express, instead of falling back to a wrong stub.
  return fs['formula'] if fs['formula'].is_a?(String) && !fs['formula'].empty?
  agg = fs['agg']
  return fs['ref'] if agg.nil? || (agg.respond_to?(:empty?) && agg.empty?)
  # Multi-arg aggregator support (bead 14w c): PercentileCont(col, 0.9), etc.
  # Two encodings are honored, both keeping the extra arg(s) verbatim:
  #   1. fs['agg'] contains a '?' placeholder -> substitute the column ref.
  #      e.g. agg="PercentileCont(?, 0.9)" -> "PercentileCont([EMP/Salary], 0.9)"
  #   2. fs['agg_args'] is an array of extra args appended after the column ref.
  #      e.g. agg="PercentileCont", agg_args=["0.9"] -> "PercentileCont([EMP/Salary], 0.9)"
  # We never fabricate an aggregator from a measure *label* — the agg comes only
  # from the master-map's explicit decision.
  if agg.to_s.include?('?')
    agg.to_s.gsub('?', fs['ref'])
  elsif fs['agg_args'].is_a?(Array) && !fs['agg_args'].empty?
    "#{agg}(#{([fs['ref']] + fs['agg_args']).join(', ')})"
  else
    "#{agg}(#{fs['ref']})"
  end
end

# bead (A) reference lines: PBI analytics-pane constant lines (rec['ref_lines'],
# captured by extract-pbir._reference_lines) -> Sigma `refMarks`. VERIFIED shape
# (ported from build-charts-from-signals.rb + qlik-to-sigma qlik_refmarks,
# 2026-06-15): `value` MUST be the wrapped object form ({type:formula,formula} —
# a bare number 400s; value.type:column is rejected too, so a column threshold
# goes through `formula`), and `label.visibility` MUST be 'shown' (the docs'
# bare-number/string forms are rejected by the live API). axis is carried from
# the PBI axis ('series' for y-axis lines, 'axis' for x). Only emitted for the
# cartesian kinds Sigma supports refMarks on.
def build_ref_marks(rec)
  Array(rec['ref_lines']).map do |rl|
    val = rl['value']
    # constant numbers go through verbatim; anything else is treated as a Sigma
    # formula (a measure-bound threshold the agent can refine).
    formula = val.to_s
    next nil if formula.strip.empty?
    rm = { 'type' => 'line', 'axis' => (rl['axis'] || 'series'),
           'value' => { 'type' => 'formula', 'formula' => formula } }
    line = {}
    line['color'] = rl['color'] if rl['color']
    rm['line'] = line.merge('width' => 2) unless line.empty?
    label = { 'visibility' => 'shown' }
    label['text'] = rl['label'] if rl['label'] && !rl['label'].to_s.empty?
    rm['label'] = label
    rm
  end.compact
end

# bead (A) trend line: PBI 'Trend line' analytics toggle -> Sigma trendlines[].
# The verified shape (build-charts-from-signals.rb) keys the trendline to a
# value column id with model + shown label/value. PBI offers only a linear trend.
def build_trendlines(rec, ycids)
  return [] unless rec['trend_line'] && ycids && !ycids.empty?
  model = (rec['trend_line']['model'] || 'linear').to_s
  ycids.map do |cid|
    real = cid.is_a?(Hash) ? cid['columnId'] : cid   # combo: {columnId,type} form
    { 'columnId' => real, 'model' => model,
      'label' => { 'visibility' => 'shown' }, 'value' => { 'visibility' => 'shown' } }
  end
end

# bead (B) by-measure color: PBI 'Color saturation' / FX fill-by-value
# (rec['measure_color'] = {queryRef, scheme[], reverse}) -> Sigma
# color:{by:scale, column:<dup measure>, scheme}. Ported from qlik-to-sigma's
# qlik_color: a Sigma column can't be on BOTH yAxis and color, so the driving
# measure is DUPLICATED into a new (hidden) column referenced by the scale.
# Mutates `cols` (appends the dup column) and returns the color hash, or nil.
def measure_color_channel(rec, fields, master, vfmts, eid, cols, ycids)
  mc = rec['measure_color']
  return nil unless mc && mc['queryRef'] && ycids && !ycids.empty?
  fs = field_spec(mc['queryRef'], fields, master)
  scheme = Array(mc['scheme']).dup
  scheme = ['#ffffcc', '#fd8d3c', '#bd0026'] if scheme.empty?
  scheme.reverse! if mc['reverse']
  base_cid = ycids.first.is_a?(Hash) ? ycids.first['columnId'] : ycids.first
  base = cols.find { |c| c['id'] == base_cid }
  cid = "#{eid}-clr"
  dup = { 'id' => cid, 'name' => "#{qr_leaf(mc['queryRef'], 'Value')} (color)",
          'formula' => (base ? base['formula'] : measure_formula(fs)), 'hidden' => true }
  apply_fmt(dup, mc['queryRef'], fields, vfmts)
  cols << dup
  { 'by' => 'scale', 'column' => cid, 'scheme' => scheme }
end

# Deterministic, collision-free short id from a PBIR visual id. PBIR visual ids
# often share a long common prefix (e.g. a1b2c3d4e5f60001 / ...0002), so a naive
# prefix-truncate collides. Take a stable suffix of the sanitized id plus a short
# hash of the full id to guarantee uniqueness across visuals.
require 'digest'
def short(id)
  clean = id.to_s.gsub(/[^a-zA-Z0-9]/, '')
  h = Digest::SHA1.hexdigest(id.to_s)[0, 6]
  "#{clean[-6, 6] || clean}#{h}"
end

# Resolve which master a visual sources from. A Sigma chart can only reference
# columns on ONE element, so pick the master that can satisfy the MOST of the
# visual's bound fields (counting `alts` — a field reachable on multiple masters).
# This makes a Year×NetRev×NetRevPY chart source from the grouped prior-year
# element (which carries all three) instead of the View (missing the PY column).
# Ties break toward the FIRST field's master (preserves prior behavior).
def visual_master(rec, fields)
  qrs = rec['bindings'].values.flatten.compact
  return nil if qrs.empty?
  # candidate masters a field can resolve on (primary + alts). Use field_spec so
  # the case-insensitive fallback applies here too.
  masters_for = lambda do |qr|
    fs = field_spec(qr, fields)
    ms = []
    ms << fs['master'] if fs['master']
    Array(fs['alts']).each { |a| ms << a['master'] if a['master'] }
    ms.uniq
  end
  counts = Hash.new(0)
  qrs.each { |qr| masters_for.call(qr).each { |m| counts[m] += 1 } }
  return nil if counts.empty?
  first_master = qrs.map { |qr| field_spec(qr, fields)['master'] }.compact.first
  best = counts.max_by { |m, c| [c, (m == first_master ? 1 : 0)] }
  best && best[0]
end

# bead f972: PBI sort carry. rec['sort'] = {queryRef, direction asc|desc} from the
# extractors (PBIR query.sortDefinition / classic prototypeQuery.OrderBy). Resolve
# the sorted queryRef to the element column built for it (qr_cids, recorded as each
# branch builds its columns) and emit the VERIFIED Sigma sort shapes:
#   bar/line/area/combo : xAxis.sort = { by: <colId>, direction }
#   pie/donut           : color.sort = { by: <colId>, direction }
#   table (grouped)     : groupings[0].sort = [{ columnId, direction }] — element-
#                         level sort is REJECTED ("Sort column not found") on a
#                         grouped table; the sort must nest INSIDE the grouping
#                         (qlik-to-sigma refs/sigma-build-gotchas.md, verified 2026-06-10)
#   table (ungrouped)   : sort = [{ columnId, direction }]
# direction must be the full word "ascending"/"descending" — the API rejects
# "asc"/"desc" (validate-spec.rb guards this too).
def apply_sort(el, kind, rec, qr_cids, name)
  srt = rec['sort']
  return unless srt.is_a?(Hash) && srt['queryRef']
  dir = srt['direction'].to_s.start_with?('desc') ? 'descending' : 'ascending'
  norm = ->(s) { s.to_s.downcase.gsub(/[_\s]+/, ' ').strip }
  pair = qr_cids.find { |qr, _| norm.call(qr) == norm.call(srt['queryRef']) }
  cid = qr_cids[srt['queryRef']] || (pair && pair[1])
  case kind
  when 'bar-chart', 'line-chart', 'area-chart', 'combo-chart'
    return warn_sort_miss(name, srt) unless cid
    # A visual-level sort BY THE DIM ITSELF must not clobber the model's
    # sortByColumn axis order (PBI sorts FiscalMonth via Period; re-sorting by
    # the month NAME would go alphabetical).
    return if cid == el.dig('xAxis', 'columnId') && el.dig('xAxis', 'sort', 'by').to_s.end_with?('-sortcol')
    (el['xAxis'] ||= {})['sort'] = { 'by' => cid, 'direction' => dir }
  when 'pie-chart', 'donut-chart'
    return warn_sort_miss(name, srt) unless cid
    (el['color'] ||= {})['sort'] = { 'by' => cid, 'direction' => dir }
  when 'table'
    return warn_sort_miss(name, srt) unless cid
    if el['groupings'].is_a?(Array) && !el['groupings'].empty?
      el['groupings'][0]['sort'] = [{ 'columnId' => cid, 'direction' => dir }]
    else
      el['sort'] = [{ 'columnId' => cid, 'direction' => dir }]
    end
  when 'pivot-table'
    warn "[build-workbook] WARN visual '#{name}': pivot-table sort is not spec-expressible in Sigma — set it in the UI."
  end
end

def warn_sort_miss(name, srt)
  warn "[build-workbook] WARN visual '#{name}': sort field '#{srt['queryRef']}' is not among " \
       'the built columns — sort skipped.'
end

# Build chart element from a normalized visual record. `extra_data` is an
# accumulator array: branches that need a HIDDEN helper element on the Data page
# (bead ry0n: the scatter grouped-source table) push it there; the page assembly
# appends extra_data to the Data page's elements.
# PBI dataCategory -> Sigma region-map regionType. Loaded from --bim into
# $geo_categories ('table.field' downcased -> dataCategory). PBI geocodes
# arbitrary place text via Bing at render time; Sigma matches region NAMES to
# built-in shapes — so only category-tagged columns can become real maps.
GEO_REGION_TYPE = {
  'postalcode' => 'us-zipcode', 'city' => 'us-postal-place', 'place' => 'us-postal-place',
  'stateorprovince' => 'us-state', 'county' => 'us-county',
  'country' => 'country', 'countryregion' => 'country'
}.freeze
$geo_categories ||= {}
$sort_by_column ||= {}

# Resolve a 'map' visual to region-map / point-map / bar-chart fallback.
# Mutates rec['bindings'] for the fallback (legend becomes the bar category,
# matching the old downgrade behavior).
def resolve_map_kind(rec, name)
  b = rec['bindings'] || {}
  lat = (b['Latitude'] || []).first
  lng = (b['Longitude'] || []).first
  return 'point-map' if lat && lng
  loc = (b['Category'] || b['Location'] || []).first
  cat = loc && $geo_categories[loc.to_s.downcase]
  rt  = cat && GEO_REGION_TYPE[cat.to_s.downcase]
  if rt
    rec['_region_type'] = rt
    warn "[build-workbook] visual '#{name}': PBI map -> Sigma region-map (#{rt}) on '#{loc}'"          "#{rt.start_with?('us-') ? ' — US region layer assumed (PBI dataCategory carries no country)' : ''}."
    return 'region-map'
  end
  why = loc.nil? ? 'no location binding' : ($geo_categories.empty? ? 'no --bim geo metadata supplied' : "'#{loc}' has no geocodable dataCategory")
  warn "[build-workbook] WARN visual '#{name}': PBI map downgraded to bar chart — #{why}. "        'Sigma maps need a region-typed column (country/state/county/zip/place) or lat+long; '        'PBI relied on Bing geocoding which Sigma does not do.'
  series = (b['Series'] || b['Legend'] || []).first
  b['Category'] = [series] if series  # old downgrade kept the legend as the bar category
  'bar-chart'
end

def build_element(rec, fields, masters, extra_data = [])
  kind = SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'
  if kind == 'map'
    t0 = rec['title'].to_s.strip
    kind = resolve_map_kind(rec, t0.empty? ? rec['visual_id'] : t0)
  end
  vid  = rec['visual_id']
  eid  = "el-#{short(vid)}"
  vfmts = rec['formats'] || {}
  # bead 14w(e): element name comes from the PBI visual title, not the raw id.
  # When the source visual has no explicit title (the classic-report norm),
  # derive one from its projections — NEVER surface the raw visual id as the
  # display name (phase-e layout-quality fix; layout_lint.rb gates this).
  title = rec['title'].to_s.strip
  name  = title.empty? ? (derived_title(rec, kind) || KIND_LABEL[kind] || 'Chart') : title

  if kind == 'text'
    # Size-aware: PBI textboxes are titles OR small decorative labels
    # (copyright lines, urls). Rendering every one as an H2 made tiny footer
    # text huge and overlapping (customer QS feedback). Boxes under ~60px tall
    # render as plain body text.
    txt = rec['text'].to_s
    body = (rec['h'].to_f >= 60 ? "## #{txt}" : txt)
    return { 'id' => eid, 'kind' => 'text', 'body' => body.empty? ? ' ' : body }
  end

  if kind == 'image'
    url = ($image_map || {})[rec['resource']]
    unless url
      warn "[build-workbook] visual '#{rec['visual_id']}': image asset '#{rec['resource']}' " \
           'skipped — supply --image-map {resource: hostedUrl} to embed it (Sigma images are URL-only).'
      return nil
    end
    return { 'id' => eid, 'kind' => 'image', 'url' => url }
  end

  master = visual_master(rec, fields)
  # bead 8vzj: a Sigma element sources exactly ONE master. visual_master picks the
  # one covering the MOST fields, but any bound field that cannot resolve on it
  # (not its master and not among its `alts`) is silently DROPPED. Warn loudly so
  # the agent supplies a single joined master (or per-field override) for those.
  if master
    unreachable = rec['bindings'].values.flatten.compact.reject do |qr|
      fs = field_spec(qr, fields)
      fs['master'] == master || Array(fs['alts']).any? { |a| a['master'] == master }
    end.map { |qr| qr.to_s }.uniq
    unless unreachable.empty?
      warn "[build-workbook] WARN visual '#{(rec['title'] || rec['visual_id'])}' has field(s) " \
           "#{unreachable.join(', ')} not reachable on the chosen master '#{master}'; a Sigma element " \
           "sources only one master, so they will be DROPPED — point them at a single joined master element."
    end
  end
  master_id = master && masters[master] ? masters[master]['id'] : nil
  el = { 'id' => eid, 'kind' => kind, 'name' => name }
  el['source'] = { 'elementId' => master_id, 'kind' => 'table' } if master_id
  cols = []
  qr_cids = {} # bead f972: queryRef -> built column id (for sort resolution)
  b = rec['bindings']

  case kind
  when 'control'
    # bead 14w(a)/6z5 + control-targeting wave (workstream B): a PBI slicer -> a
    # Sigma `list` control bound to the sliced column on its master element.
    # Valid shape (controls.md): controlType:list + controlId + mode +
    # selectionMode + values[] + source{kind:source,...} + filters[]. The control
    # defines NO columns of its own — it references master columns by id.
    #
    # TARGETING: a PBI slicer filters its whole page ACROSS related tables, so
    # the control's filters[] gets one entry per master the slicer's filter
    # reaches: the sliced table's own master(s) always, plus every master
    # covering a table reachable via model relationships (one->many flow;
    # bothDirections adds the reverse), plus derived/restructured elements
    # (pseudo entities) that carry the sliced column. A slicer column that
    # cannot be resolved to a real master column SKIPS the control with a LOUD
    # warning — never silently wires the wrong column (the old `|| mcols.first`).
    qr = (b['Values'] || b['Category'] || b['Fields'] || []).first
    leaf = qr_leaf(qr, 'Filter')
    ent  = qr.to_s.split('.').first
    fs = qr && field_spec(qr, fields)
    pmaster = fs && fs['master']
    pm = pmaster && masters[pmaster]
    pcol = pm && match_master_column(pm, leaf, ent)
    if pm.nil? || pcol.nil?
      warn "[build-workbook] ERROR slicer '#{name}' (#{vid}): column '#{qr}' does not resolve to a " \
           "column on any master (resolved master=#{pmaster.inspect}) — control SKIPPED. " \
           'Fix the master-map (or add the column to the master) and re-run; a control must ' \
           'never be silently wired to the wrong column.'
      $control_unbound << { 'sourceName' => "slicer #{name} (#{vid}) column #{qr}",
                            'status' => 'unbound',
                            'reason' => "column '#{qr}' resolves to no master column " \
                                        "(master=#{pmaster.inspect}); dropped loudly rather than " \
                                        'wired to a wrong column or shipped dead' }
      return nil
    end
    reach = MODEL_RELATIONSHIPS.any? || MODEL_TABLES.any? ? reachable_entities(ent) : [ent]
    cov = entity_master_coverage(fields)
    filters, wired, unwired = [], [], []
    masters.each do |mname, mrec|
      ents = cov.select { |_e, ms| ms.include?(mname) }.keys
      real = MODEL_TABLES.any? ? (ents & MODEL_TABLES) : ents
      pseudo = MODEL_TABLES.any? && real.empty?      # derived/restructured element
      in_scope = (real & reach).any? || mname == pmaster
      col = match_master_column(mrec, leaf, ent)
      # pseudo elements: only when they actually carry the sliced column —
      # column-name evidence is the best provenance we have for restructured
      # (Dense Rank / time-intel / calc-table SQL) elements.
      in_scope ||= pseudo && !col.nil?
      next unless in_scope
      if col.nil?
        unwired << mname
        next
      end
      filters << { 'source' => { 'kind' => 'table', 'elementId' => mrec['id'] }, 'columnId' => col['id'] }
      wired << mname
    end
    unless unwired.empty?
      warn "[build-workbook] WARN slicer '#{name}': master(s) #{unwired.join(', ')} are in the " \
           "slicer's relationship scope but carry no column matching '#{leaf}' — NOT wired. " \
           'Charts on those masters will not respond to this control; add the related column ' \
           'to the master (cross-element ref) to wire it.'
    end
    ctl_id = (title_leaf(qr) || leaf).gsub(/[^A-Za-z0-9]/, '') + 'Filter'
    n = ($used_control_ids[ctl_id] += 1)
    ctl_id = "#{ctl_id}#{n}" if n > 1     # two slicers on one column: unique ids
    el['kind'] = 'control'
    el['controlId'] = ctl_id
    el['name'] = name
    if tmsl_date_column?(ent, leaf)
      # date-typed slicer -> date-range control. A `list` control bound to a
      # datetime column gets its filter targets SILENTLY STRIPPED by Sigma
      # (estate-repair gotcha) — the control posts, then filters nothing.
      # date-range needs no `source` (columns come from `filters`) but DOES
      # require a flat `mode` — without it the POST 400s with the misleading
      # "Invalid kind: control" (live-verified 2026-06-12).
      el['controlType'] = 'date-range'
      el['mode'] = 'between'
      el['includeNulls'] = 'when-no-value-is-selected'
    else
      el['controlType'] = 'list'
      el['mode'] = 'include'
      el['selectionMode'] = 'multiple'
      el['values'] = []
      el['source'] = { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => pm['id'] }, 'columnId' => pcol['id'] }
    end
    el['filters'] = filters
    $control_scope << { 'controlId' => ctl_id,
                        'sourceName' => "slicer #{name} (#{vid}) column #{qr}",
                        'status' => 'wired',
                        'reachableTables' => reach,
                        'wiredMasters' => wired,
                        'unwiredMasters' => unwired,
                        # internal (stripped before write): resolved to the
                        # scope allowlist + excluded[] at page assembly.
                        '_visual_id' => vid,
                        '_leaf' => leaf,
                        '_wired_ids' => filters.map { |f| f.dig('source', 'elementId') },
                        'scope' => [], 'excluded' => [] }
  when 'kpi-chart'
    # A single-value PBI card -> kpi-chart. A multiRowCard (multiple Values) ->
    # ONE kpi-chart tile per measure (bead x81l: a kpi-chart renders only
    # value.id, so a flat table or single-value KPI would drop the rest).
    # Returns an ARRAY here; the page/layout assembly flattens + tiles them.
    vals = (b['Values'] || b['Y'] || [])
    if vals.length > 1
      return vals.each_with_index.map do |qr, i|
        fs = field_spec(qr, fields, master)
        kid = "#{eid}-k#{i}"
        col = { 'id' => "#{kid}-v", 'formula' => measure_formula(fs), 'name' => qr_leaf(qr) }
        apply_fmt(col, qr, fields, vfmts)
        e = { 'id' => kid, 'kind' => 'kpi-chart', 'name' => qr_leaf(qr),
              'columns' => [col], 'value' => { 'columnId' => "#{kid}-v" } }
        e['source'] = { 'elementId' => master_id, 'kind' => 'table' } if master_id
        e
      end
    end
    qr = vals.first
    fs = field_spec(qr, fields, master)
    cid = "#{eid}-v"
    col = { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr_leaf(qr, 'Value') }
    apply_fmt(col, qr, fields, vfmts)
    cols << col
    # KPI value binds by `columnId` (the API rejects `{id}` -> "value.columnId:
    # Invalid string"; live readback also normalizes to columnId). NB: pie/donut
    # `value` uses `{id}` — do not change that one.
    el['value'] = { 'columnId' => cid }
  when 'region-map'
    loc = (b['Category'] || b['Location'] || []).first
    meas = (b['Y'] || b['Values'] || []).first
    dfs = field_spec(loc, fields, master)
    dcid = "#{eid}-r"
    cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => qr_leaf(loc, 'Region') }
    qr_cids[loc] = dcid
    el['region'] = { 'id' => dcid, 'regionType' => rec['_region_type'] }
    if meas
      fs = field_spec(meas, fields, master)
      vcid = "#{eid}-v"
      col = { 'id' => vcid, 'formula' => measure_formula(fs), 'name' => qr_leaf(meas) }
      apply_fmt(col, meas, fields, vfmts)
      cols << col
      qr_cids[meas] = vcid
      el['color'] = { 'by' => 'scale', 'column' => vcid }
    end
    if (srs = (b['Series'] || b['Legend'] || []).first)
      warn "[build-workbook] WARN visual '#{name}': region-map colors by the measure scale — "            "PBI legend '#{srs}' dropped (no categorical legend on a Sigma region map)."
    end
  when 'point-map'
    latq = (b['Latitude'] || []).first
    lngq = (b['Longitude'] || []).first
    lfs = field_spec(latq, fields, master); gfs = field_spec(lngq, fields, master)
    lcid = "#{eid}-lat"; gcid = "#{eid}-lng"
    cols << { 'id' => lcid, 'formula' => lfs['ref'], 'name' => qr_leaf(latq, 'Latitude') }
    cols << { 'id' => gcid, 'formula' => gfs['ref'], 'name' => qr_leaf(lngq, 'Longitude') }
    el['latitude'] = { 'id' => lcid }
    el['longitude'] = { 'id' => gcid }
    if (szq = (b['Size'] || b['Y'] || b['Values'] || []).first)
      fs = field_spec(szq, fields, master)
      scid = "#{eid}-sz"
      col = { 'id' => scid, 'formula' => measure_formula(fs), 'name' => qr_leaf(szq, 'Size') }
      apply_fmt(col, szq, fields, vfmts)
      cols << col
      el['size'] = { 'id' => scid }
    end
  when 'bar-chart', 'line-chart', 'area-chart'
    # b['Group'] is the treemap/funnel category role (1zh9) — alias it to the dim
    # so a treemap-as-bar fallback keeps its category instead of emitting '[]'.
    dim_role = (b['Category'] || b['Axis'] || b['X'] || b['Group'] || [])
    dim = dim_role.first
    # bead hjke(c): a PBI date-hierarchy role carries one queryRef PER LEVEL
    # (Year/Quarter/Month/Day). The extractors keep only the ACTIVE drill level
    # when the report records one (activeProjections / active flag); if multiple
    # levels still arrive here we can only bind the first — warn that the drill
    # depth was reduced so the agent can re-point the dim at the intended level.
    if dim_role.length > 1 &&
       dim_role.all? { |q| q.to_s =~ /hierarchy/i || q.to_s =~ /\.(Year|Quarter|Month|Week|Day|Date)\s*\z/i }
      warn "[build-workbook] WARN visual '#{name}': date hierarchy with #{dim_role.length} levels " \
           "reduced to '#{dim}' — deeper drill levels (#{dim_role[1..].join(', ')}) dropped."
    end
    meas = (b['Y'] || b['Values'] || [])
    series = (b['Series'] || b['Legend'] || []).first
    dfs = field_spec(dim, fields, master)
    dcid = "#{eid}-x"
    cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => qr_leaf(dim, 'Dim') }
    qr_cids[dim] = dcid if dim
    ycids = []
    meas.each_with_index do |qr, i|
      fs = field_spec(qr, fields, master)
      cid = "#{eid}-y#{i}"
      col = { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr_leaf(qr) }
      apply_fmt(col, qr, fields, vfmts)
      cols << col
      ycids << cid
      qr_cids[qr] = cid
    end
    el['xAxis'] = { 'columnId' => dcid }
    el['yAxis'] = { 'columnIds' => ycids }
    # PBI sort-by-column: bind the hidden sort field and order the axis by it
    # (model FiscalMonth sorts by Period; alphabetical months otherwise).
    if dim && (sort_qr = ($sort_by_column || {})[dim.to_s.downcase])
      sfs = fields[sort_qr] || fields.find { |k, _| k.to_s.downcase == sort_qr.downcase }&.last
      if sfs && (sfs['master'] == master || Array(sfs['alts']).any? { |a| a['master'] == master })
        scol_id = "#{eid}-sortcol"
        cols << { 'id' => scol_id, 'formula' => (sfs['master'] == master ? sfs['ref'] : Array(sfs['alts']).find { |a| a['master'] == master }['ref']), 'name' => qr_leaf(sort_qr, 'Sort'), 'hidden' => true }
        el['xAxis']['sort'] = { 'by' => scol_id, 'direction' => 'ascending' }
      else
        warn "[build-workbook] WARN visual '#{name}': model sorts '#{dim}' by '#{sort_qr}' but that field is not in the master-map — axis will sort alphabetically; add it to fields to fix."
      end
    end
    # PBI *Bar* visuals are horizontal; *Column* visuals vertical. Sigma keeps the
    # same xAxis(category)/yAxis(value) binding and flips rendering via this flag.
    # Only "horizontal" is a valid value — vertical = omit (Sigma default).
    el['orientation'] = 'horizontal' if kind == 'bar-chart' && rec['orientation'] == 'horizontal'
    # Stacking fidelity: emit explicitly so a multi-series clustered PBI chart does
    # NOT inherit Sigma's stacked default. PBI clustered->"none", stacked->"stacked",
    # 100%-stacked->"100".
    # Stacking enum is none|stacked|normalized (OpenAPI BarChart.stacking;
    # "normalized" = scaled to 100%). extract-pbir already maps PBI 100%-stacked
    # -> "normalized", so pass it through verbatim (bead pi8v).
    el['stacking'] = rec['stacking'] if %w[bar-chart area-chart].include?(kind) && rec['stacking']
    # bead n9u9: honor the PBI per-visual data-label signal (objects.labels show)
    # when the extractor provided one: true -> shown, false -> omit (Sigma default
    # is off). Verified `dataLabel:{labels:"shown"}` persists + renders for bar AND
    # line. Back-compat when the signal is nil/absent: bar shown, line/area clean.
    dl = rec['data_labels']
    el['dataLabel'] = { 'labels' => 'shown' } if dl == true || (dl.nil? && kind == 'bar-chart')
    # c07: default to single series. Only split by color when PBI bound a
    # Series/Legend role. Never auto-color a line by a dimension that PBI did
    # not legend (see refs/measure-patterns.md §1 + §4).
    if series
      sfs = field_spec(series, fields, master)
      scid = "#{eid}-c"
      cols << { 'id' => scid, 'formula' => sfs['ref'], 'name' => qr_leaf(series, 'Series') }
      qr_cids[series] = scid
      el['color'] = { 'by' => 'category', 'column' => scid }
    else
      # bead (B) by-measure color: only when PBI did NOT bind a categorical
      # Series/Legend (that wins — a column can't be on color twice).
      cc = measure_color_channel(rec, fields, master, vfmts, eid, cols, ycids)
      el['color'] = cc if cc
    end
    # bead (A) reference lines / trend line -> Sigma refMarks / trendlines.
    rms = build_ref_marks(rec)
    el['refMarks'] = rms unless rms.empty?
    tls = build_trendlines(rec, ycids)
    el['trendlines'] = tls unless tls.empty?
  when 'combo-chart'
    # bead 6v5u: PBI lineClustered/StackedColumnComboChart -> Sigma combo. Roles:
    # Category (x), Y (columns -> primary/left axis), Y2 (lines -> secondary/right
    # axis). Dual-axis persists via the bare-string-vs-object form of
    # yAxis.columnIds (feedback_sigma_combo_dual_axis): bare string = primary,
    # {columnId, type:'line'} = secondary line.
    dim = (b['Category'] || b['Axis'] || b['X'] || []).first
    col_meas  = (b['Y'] || b['Values'] || [])
    line_meas = (b['Y2'] || [])
    dfs = field_spec(dim, fields, master)
    dcid = "#{eid}-x"
    cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => qr_leaf(dim, 'Dim') }
    qr_cids[dim] = dcid if dim
    ycids = []
    col_meas.each_with_index do |qr, i|
      fs = field_spec(qr, fields, master)
      cid = "#{eid}-y#{i}"
      col = { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr_leaf(qr) }
      apply_fmt(col, qr, fields, vfmts)
      cols << col
      ycids << cid                                   # bare string -> primary (left) bars
      qr_cids[qr] = cid
    end
    line_meas.each_with_index do |qr, i|
      fs = field_spec(qr, fields, master)
      cid = "#{eid}-l#{i}"
      col = { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr_leaf(qr) }
      apply_fmt(col, qr, fields, vfmts)
      cols << col
      ycids << { 'columnId' => cid, 'type' => 'line' } # object -> secondary (right) line
      qr_cids[qr] = cid
    end
    el['xAxis'] = { 'columnId' => dcid }
    el['yAxis'] = { 'columnIds' => ycids }
    # bead (B) by-measure color on the combo's primary bars.
    cc = measure_color_channel(rec, fields, master, vfmts, eid, cols, ycids)
    el['color'] = cc if cc
    # bead (A) reference lines / trend line.
    rms = build_ref_marks(rec)
    el['refMarks'] = rms unless rms.empty?
    tls = build_trendlines(rec, ycids)
    el['trendlines'] = tls unless tls.empty?
  when 'scatter-chart'
    # bead 14w(b): scatter -> xAxis (measure), yAxis (measure), point category for
    # color/detail. PBI scatter binds X + Y (both measures) and a Category/Details.
    xqr = (b['X'] || b['Values'] || []).first
    yqr = (b['Y'] || []).first
    detail = (b['Category'] || b['Details'] || b['Series'] || b['Legend'] || []).first
    sizeqr = (b['Size'] || []).first
    xfs = field_spec(xqr, fields, master); yfs = field_spec(yqr, fields, master)
    is_meas = ->(fs) { measure_ref?(fs) }
    if is_meas.call(xfs) && detail && master_id
      # bead ry0n: Sigma's scatter xAxis is a GROUPING axis — binding an AGGREGATE
      # to it makes the aggregate evaluate per-row (Count -> 1) and every point
      # collapses to x=1. Verified fix: pre-aggregate in a HIDDEN grouped source
      # table on the Data page (dim + x/y[/size] aggregates, grouped by the dim),
      # then point the scatter at it with ALL-RAW column refs. The detail dim MUST
      # stay on color:{by:category} — points sharing an x merge to a null y
      # without it.
      dfs   = field_spec(detail, fields, master)
      dname = qr_leaf(detail, 'Detail'); xname = qr_leaf(xqr, 'X'); yname = qr_leaf(yqr, 'Y')
      src_id   = "#{eid}-src"
      src_name = "Scatter Source #{short(vid)}"   # unique name: raw refs resolve [Name/Col]
      gd = "#{src_id}-d"; gx = "#{src_id}-x"; gy = "#{src_id}-y"
      gcols = [
        { 'id' => gd, 'formula' => dfs['ref'], 'name' => dname },
        apply_fmt({ 'id' => gx, 'formula' => measure_formula(xfs), 'name' => xname }, xqr, fields, vfmts),
        apply_fmt({ 'id' => gy, 'formula' => measure_formula(yfs), 'name' => yname }, yqr, fields, vfmts)
      ]
      calc_ids = [gx, gy]
      szname = nil
      if sizeqr
        szfs = field_spec(sizeqr, fields, master)
        if is_meas.call(szfs)
          szname = qr_leaf(sizeqr, 'Size')
          # avoid a display-name collision with x/y (e.g. Size bound to the same measure)
          szname = "#{szname} (Size)" if [dname, xname, yname].include?(szname)
          gsz = "#{src_id}-s"
          gcols << apply_fmt({ 'id' => gsz, 'formula' => measure_formula(szfs), 'name' => szname }, sizeqr, fields, vfmts)
          calc_ids << gsz
        else
          warn "[build-workbook] WARN scatter '#{name}': Size role '#{sizeqr}' is not a measure — size DROPPED."
        end
      end
      extra_data << { 'id' => src_id, 'kind' => 'table', 'name' => src_name,
                      'source' => { 'elementId' => master_id, 'kind' => 'table' },
                      'columns' => gcols,
                      'groupings' => [{ 'id' => "#{src_id}-g", 'groupBy' => [gd], 'calculations' => calc_ids }],
                      'visibleAsSource' => false }
      el['source'] = { 'elementId' => src_id, 'kind' => 'table' }
      dcid = "#{eid}-d"; xcid = "#{eid}-x"; ycid = "#{eid}-y"
      cols << { 'id' => dcid, 'formula' => "[#{src_name}/#{dname}]", 'name' => dname }
      cols << apply_fmt({ 'id' => xcid, 'formula' => "[#{src_name}/#{xname}]", 'name' => xname }, xqr, fields, vfmts)
      cols << apply_fmt({ 'id' => ycid, 'formula' => "[#{src_name}/#{yname}]", 'name' => yname }, yqr, fields, vfmts)
      el['xAxis'] = { 'columnId' => xcid }
      el['yAxis'] = { 'columnIds' => [ycid] }
      el['color'] = { 'by' => 'category', 'column' => dcid }   # REQUIRED (see above)
      if szname
        szcid = "#{eid}-s"
        cols << apply_fmt({ 'id' => szcid, 'formula' => "[#{src_name}/#{szname}]", 'name' => szname }, sizeqr, fields, vfmts)
        el['size'] = { 'id' => szcid }
      end
    else
      warn "[build-workbook] WARN scatter '#{name}': measure X with no Details/Category dim — " \
           'points will collapse to one x value.' if is_meas.call(xfs) && !detail
      xcid = "#{eid}-x"; ycid = "#{eid}-y"
      cx = { 'id' => xcid, 'formula' => measure_formula(xfs), 'name' => qr_leaf(xqr, 'X') }
      cy = { 'id' => ycid, 'formula' => measure_formula(yfs), 'name' => qr_leaf(yqr, 'Y') }
      apply_fmt(cx, xqr, fields, vfmts); apply_fmt(cy, yqr, fields, vfmts)
      cols << cx << cy
      el['xAxis'] = { 'columnId' => xcid }
      el['yAxis'] = { 'columnIds' => [ycid] }
      if detail
        dfs = field_spec(detail, fields, master)
        dcid = "#{eid}-d"
        cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => qr_leaf(detail, 'Detail') }
        el['color'] = { 'by' => 'category', 'column' => dcid }
      end
      warn "[build-workbook] WARN scatter '#{name}': Size role '#{(b['Size'] || []).first}' DROPPED " \
           '(ungrouped scatter path).' if (b['Size'] || []).first
    end
    # PBI legend.show=false -> hide the Sigma legend (the detail-on-color split
    # otherwise surfaces a legend PBI did not show).
    el['legend'] = { 'visibility' => 'hidden' } if rec['legend'] == false
    # bead (A) reference lines on a scatter (e.g. a margin-target line at x=0.45).
    rms = build_ref_marks(rec)
    el['refMarks'] = rms unless rms.empty?
  when 'pie-chart', 'donut-chart'
    dim = (b['Category'] || b['Legend'] || []).first
    val = (b['Values'] || b['Y'] || []).first
    dfs = field_spec(dim, fields, master); vfs = field_spec(val, fields, master)
    dcid = "#{eid}-c"; vcid = "#{eid}-v"
    cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => qr_leaf(dim, 'Dim') }
    cv = { 'id' => vcid, 'formula' => measure_formula(vfs), 'name' => qr_leaf(val, 'Value') }
    apply_fmt(cv, val, fields, vfmts)
    cols << cv
    qr_cids[dim] = dcid if dim
    qr_cids[val] = vcid if val
    el['color'] = { 'id' => dcid }
    el['value'] = { 'id' => vcid }
    # value labels on pie/donut slices — honor an explicit PBI labels-off signal
    # (bead n9u9); default (nil/absent) keeps the labels shown as before.
    el['dataLabel'] = { 'labels' => 'shown' } unless rec['data_labels'] == false
  when 'table'
    # A plain table with measure columns renders FLAT/ungrouped unless it has a
    # grouping whose `calculations` lists the measure col ids (bead 14w(f)).
    # The first non-aggregated (dimension) column becomes the groupBy; every
    # aggregated column id goes into that grouping's calculations[].
    # bead ne48: group by ALL leading dimension columns, not just the first —
    # otherwise a 2-dim matrix collapses to the wrong grain. A field with an
    # explicit `formula` (bead qb2i window calc) is a calculation, never a groupBy.
    group_ids = []; calc_ids = []
    (b['Values'] || []).each_with_index do |qr, i|
      fs = field_spec(qr, fields, master)
      cid = "#{eid}-c#{i}"
      is_dim = !measure_ref?(fs)
      col = { 'id' => cid, 'formula' => is_dim ? fs['ref'] : measure_formula(fs),
              'name' => qr_leaf(qr) }
      apply_fmt(col, qr, fields, vfmts) unless is_dim
      cols << col
      qr_cids[qr] = cid
      if is_dim
        group_ids << cid
      else
        calc_ids << cid
      end
    end
    if !group_ids.empty? && !calc_ids.empty?
      el['groupings'] = [{ 'id' => "#{eid}-g", 'groupBy' => group_ids, 'calculations' => calc_ids }]
    end
  when 'pivot-table'
    rows = (b['Rows'] || b['Category'] || [])
    colsby = (b['Columns'] || [])   # bead 14w(d): PBI Columns role -> pivot columnsBy
    vals = (b['Values'] || [])
    rowids = []
    rows.each_with_index do |qr, i|
      fs = field_spec(qr, fields, master); cid = "#{eid}-r#{i}"
      cols << { 'id' => cid, 'formula' => fs['ref'], 'name' => qr_leaf(qr) }
      rowids << cid
    end
    colids = []
    colsby.each_with_index do |qr, i|
      fs = field_spec(qr, fields, master); cid = "#{eid}-col#{i}"
      cols << { 'id' => cid, 'formula' => fs['ref'], 'name' => qr_leaf(qr) }
      colids << cid
    end
    valids = []
    vals.each_with_index do |qr, i|
      fs = field_spec(qr, fields, master); cid = "#{eid}-v#{i}"
      col = { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr_leaf(qr) }
      apply_fmt(col, qr, fields, vfmts)
      cols << col
      valids << cid
    end
    # rowsBy + values REQUIRED or the pivot collapses to one grand-total cell
    # (memory: feedback_sigma_pivot_rowsby_columnsby). columnsBy is the PBI
    # Columns role (bead 14w(d)) — without it a Rows×Columns matrix flattens.
    el['rowsBy'] = rowids.map { |id| { 'id' => id } }
    el['columnsBy'] = colids.map { |id| { 'id' => id } } unless colids.empty?
    el['values'] = valids
  end

  # bead f972: carry the PBI visual's sort onto the built element (runs AFTER the
  # case so a grouped table's sort can nest inside its grouping entry).
  apply_sort(el, kind, rec, qr_cids, name)

  # Controls reference a master column; they carry no columns array of their own.
  el['columns'] = cols unless el['kind'] == 'control'
  el
end

# ---- assemble pages -------------------------------------------------------
data_elements = masters.map do |_name, m|
  {
    'id' => m['id'], 'kind' => 'table', 'name' => m['id'].sub(/^master-/, '').upcase[0, 6],
    'source' => { 'dataModelId' => (m['data_model'] || opts[:dm]),
                  'elementId' => m['element_id'], 'kind' => 'data-model' },
    'columns' => (m['columns'] || []),
    'visibleAsSource' => false
  }
end

# bead ry0n: hidden helper elements (scatter grouped sources) accumulate here
# and are appended to the Data page below.
extra_data_elements = []
content_pages = signals['pages'].map do |pg|
  # build_element may return one element or an array (multiRowCard -> N KPIs),
  # or nil (unresolvable slicer -> control skipped loudly, never wired wrong).
  vis_elements = {}   # visual_id -> [built element ids] (feeds intended-scope)
  els = pg['visuals'].flat_map do |v|
    r = build_element(v, fields, masters, extra_data_elements)
    list = r.is_a?(Array) ? r : [r] # NB: not Array(r) — that explodes a Hash into pairs
    list = list.compact
    vis_elements[v['visual_id']] = list.map { |e| e['id'] }
    list
  end
  # Intended-scope contract (workstream B): for each control on this page,
  # `scope` (the lint's allowlist — EVERY listed element is hard-asserted to
  # be in the control's reach) = every chart element built from a same-page
  # visual whose bound tables the slicer's filter reaches in the SOURCE (PBI:
  # slicer scope is its page, flowing across relationships) AND whose Sigma
  # element chains to a master this control actually wired. The remainder —
  # source-reachable but UN-wireable (cross-grain: the master carries no
  # column matching the sliced leaf and no relationship-resolvable column
  # exists) — lands in `excluded` with a reason, NOT in scope, so gate 7
  # neither asserts the impossible nor lets it pass silently.
  # Visual-interaction "edit interactions" overrides (page.json
  # visualInteractions, type none/nofilter) also exclude that target visual —
  # best-effort: master-level wiring cannot exempt one visual that SHARES a
  # master with an intended one, so warn when that happens.
  offs = (pg['interactions'] || []).select { |ia| ia['type'].to_s =~ /no.?filter|none/i }
  # element id -> the master element id it (transitively) sources, walking
  # restructured intermediates (e.g. a scatter's grouped source element).
  src_of = (els + extra_data_elements).each_with_object({}) do |e, h|
    h[e['id']] = e.dig('source', 'elementId') || e.dig('source', 'source', 'elementId')
  end
  eff_master = lambda do |eid|
    cur = src_of[eid]
    cur = src_of[cur] while cur && src_of.key?(cur)
    cur
  end
  $control_scope.select { |sc| vis_elements.key?(sc['_visual_id']) }.each do |sc|
    reach = sc['reachableTables'] || []
    wired_ids = sc['_wired_ids'] || []
    pg['visuals'].each do |v|
      next if v['visual_id'] == sc['_visual_id']
      next if %w[control text].include?(SIGMA_KIND[v['sigma_kind']] || v['sigma_kind'])
      ents = (v['bindings'] || {}).values.flatten.compact.map { |q| q.to_s.split('.').first }.uniq
      next unless ents.any? { |e| reach.include?(e) } || reach.empty?
      if offs.any? { |ia| ia['source'] == sc['_visual_id'] && ia['target'] == v['visual_id'] }
        warn "[build-workbook] NOTE control '#{sc['controlId']}': source report turns OFF its " \
             "interaction with visual '#{v['title'] || v['visual_id']}' — excluded from intended " \
             'scope. Master-level wiring cannot exempt it if it shares a master with an ' \
             'intended chart; verify in Sigma.'
        (vis_elements[v['visual_id']] || []).each do |eid|
          sc['excluded'] << { 'element' => eid,
                              'reason' => 'source report visual-interaction set to none for this ' \
                                          'target — intentionally not filtered in PBI' }
        end
        next
      end
      (vis_elements[v['visual_id']] || []).each do |eid|
        if wired_ids.include?(eff_master.call(eid))
          sc['scope'] << eid
        else
          sc['excluded'] << { 'element' => eid,
                              'reason' => "cross-grain: its master carries no column matching " \
                                          "'#{sc['_leaf']}' and no relationship path resolves one " \
                                          '— unreachable without a model change ' \
                                          "(masters not wired: #{(sc['unwiredMasters'] || []).join(', ')})" }
        end
      end
    end
    sc['scope'].uniq!
  end
  { 'id' => "page-#{pg['page_id']}", 'name' => pg['page_title'], 'elements' => els }
end
data_elements += extra_data_elements

# control-scope.json — the intended-scope contract sidecar (schema: the
# CONTRACT block in scripts/lib/control_lint.rb + refs/control-parity.md).
# `sourceFilterSignals` counts the source report's slicer visuals — >0 with
# zero spec controls FAILS gate 7 (the "interactive source, static migration"
# class). Each emitted control carries `scope` (allowlist of element ids the
# lint hard-asserts reachable) + `excluded` (cross-grain / interaction-off,
# with reasons); slicers that produced no control land in `unbound`.
scope_path = opts[:scope_out] || File.join(File.dirname(File.expand_path(opts[:out])), 'control-scope.json')
source_signals = signals['pages'].sum do |pg|
  (pg['visuals'] || []).count { |v| (SIGMA_KIND[v['sigma_kind']] || v['sigma_kind']) == 'control' }
end
scope_controls = $control_scope.map { |sc| sc.reject { |k, _| k.start_with?('_') } }
File.write(scope_path, JSON.pretty_generate(
             { 'version' => 1, 'source' => 'powerbi',
               'sourceFilterSignals' => source_signals,
               'controls' => scope_controls,
               'unbound' => $control_unbound }
           ))
warn "[build-workbook] wrote control scope -> #{scope_path} (#{scope_controls.size} control(s), " \
     "#{source_signals} source signal(s), #{$control_unbound.size} unbound)"

# Derived titles can collide (two untitled visuals over the same projections) —
# suffix duplicates so every element keeps a distinct human-readable name.
seen_names = Hash.new(0)
content_pages.flat_map { |p| p['elements'] }.each do |el|
  next unless el['name'].is_a?(String) && !el['name'].empty?
  n = (seen_names[el['name']] += 1)
  el['name'] = "#{el['name']} (#{n})" if n > 1
end

# ---- 24-col grid layout (research/powerbi-visual-layout.md §4) -------------
# Built BEFORE the spec is assembled so the layout XML can be EMBEDDED into the
# workbook spec's top-level `layout` (bead 16i): a bare POST/PUT /workbooks/spec
# WITHOUT an embedded layout makes Sigma auto-generate a single-column stack
# that wipes any grid. Embedding it on every write means the layout survives the
# initial POST; put-layout.rb is still the authoritative FINAL write.
# bead p4h: end grid lines must be floor((start+size)/unit)+1 on BOTH axes.
# The old form (cols: floor((x+w-1)/unit)+2; rows: ceil((y+h)/unit)+1) overshot
# the end line by one cell, so adjacent PBI visuals shared a grid line ->
# "Element collisions found during layout edit". gridColumn/gridRow lines are
# end-EXCLUSIVE, so floor/floor tiles adjacent visuals without overlap.
col_for = ->(x, w, pw) {
  unit = pw / 24.0
  cs = (x / unit).floor + 1
  ce = ((x + w) / unit).floor + 1
  ce = cs + 1 if ce <= cs
  [[cs, 1].max, [ce, 25].min]
}
ROW_UNIT = 20.0
# Container-banded pages (layout-playbook.md): the PBI canvas regions cluster
# into horizontal row bands, each band a full-width <GridContainer> whose
# children keep the canvas-derived geometry (container-relative rows). Every
# page gets a dark header band carrying the page title; the matching
# `kind: container` / header-text spec elements are appended to the page below.
pages_xml = signals['pages'].map do |pg|
  pw = pg['page_w'] || 1280
  items = pg['visuals'].flat_map do |v|
    cs, ce = col_for.call(v['x'], v['w'], pw)
    rs = (v['y'] / ROW_UNIT).floor + 1
    re = ((v['y'] + v['h']) / ROW_UNIT).floor + 1
    re = rs + 1 if re <= rs
    base = "el-#{short(v['visual_id'])}"
    vvals = (v['bindings'] || {})['Values'] || []
    if v['visual_type'] == 'multiRowCard' && vvals.length > 1
      # tile the card's column span across N KPI sub-elements (must match the
      # `#{eid}-k#{i}` ids emitted by build_element's kpi multi-value branch).
      # Tile the N KPIs in a grid (ncol = ceil(sqrt n)) inside the card's box so
      # wide values (e.g. $180,504) aren't truncated by a 1-column-wide tile.
      n = vvals.length
      ncol = Math.sqrt(n).ceil
      nrow = (n.to_f / ncol).ceil
      cspan = ce - cs
      # A KPI tile needs ~3 grid rows (90px) to render value+title; a short PBI
      # card box would clip the lower tiles. Grow the box down to nrow*3 rows
      # (the row band above the first chart is empty, so this won't collide).
      re_eff = [re, rs + nrow * 3].max
      rspan = re_eff - rs
      (0...n).map do |i|
        r = i / ncol
        c = i % ncol
        scs = cs + (c * cspan.to_f / ncol).round
        sce = cs + ((c + 1) * cspan.to_f / ncol).round
        srs = rs + (r * rspan.to_f / nrow).round
        sre = rs + ((r + 1) * rspan.to_f / nrow).round
        sce = scs + 1 if sce <= scs
        sre = srs + 1 if sre <= srs
        ["#{base}-k#{i}", scs, sce, srs, sre]
      end
    else
      [[base, cs, ce, rs, re]]
    end
  end
  page_id = "page-#{pg['page_id']}"
  page_spec = content_pages.find { |p| p['id'] == page_id }
  # A skipped visual (e.g. an unresolvable slicer) has no spec element — a
  # layout entry for a non-existent element id breaks the layout write.
  if page_spec
    built_ids = page_spec['elements'].map { |e| e['id'] }
    items = items.select { |i| built_ids.include?(i[0]) }
  end
  next nil if items.empty?

  # ---- CLEAN opinionated layout (default) ----------------------------------
  # Customer-tuned (2026-06-12): keep every element in the SAME SPOT as the
  # PBI canvas (same row band, same left-to-right position, same vertical
  # stacking), but make overriding decisions about sizing: bands become
  # uniform full-width rows, column widths are normalized to fill the 24-col
  # grid edge-to-edge, items stacked in a sub-column split the band height
  # evenly, and per-kind minimum heights apply. Tiny decorative textboxes
  # (copyright lines, urls) are DROPPED; the page title moves into the dark
  # header band.
  if (opts[:layout_mode] || 'clean') == 'clean'
    kind_of = {}
    (page_spec ? page_spec['elements'] : []).each { |e| kind_of[e['id']] = e['kind'] }
    src_rec = ->(id) { pg['visuals'].find { |v| "el-#{short(v['visual_id'])}" == id } }

    # 1) header promotion + decorative-text drop
    hdr_text_id = nil
    drop = []
    items.each do |it|
      next unless kind_of[it[0]] == 'text'
      r = src_rec.call(it[0])
      txt = r && r['text'].to_s.strip
      if hdr_text_id.nil? && txt && txt != '' && r['h'].to_f >= 40 && r['y'].to_f < 120
        hdr_text_id = it[0]
        drop << it[0]
      elsif r.nil? || r['h'].to_f < 60 || txt == ''
        warn "[build-workbook] clean layout: decorative textbox '#{it[0]}' dropped (#{txt.to_s[0, 30].inspect})."
        page_spec['elements'] = page_spec['elements'].reject { |e| e['id'] == it[0] } if page_spec
        drop << it[0]
      end
    end
    items = items.reject { |i| drop.include?(i[0]) }

    children = []
    extra = []
    hdr_id = "band-#{page_id}-hdr"
    extra << SigmaLayout.container_el(hdr_id, SigmaLayout::HEADER_STYLE.dup)
    if hdr_text_id
      hdr_el = page_spec && page_spec['elements'].find { |e| e['id'] == hdr_text_id }
      ttl = src_rec.call(hdr_text_id)['text'].to_s.strip
      hdr_el['body'] = %(# <span style="color: #FFFFFF">#{ttl}</span>) if hdr_el
      children << SigmaLayout.header_band_xml(hdr_id, hdr_text_id)
    else
      ttl = SigmaLayout.resolve_header_title(pg['page_title'], opts[:source_title], opts[:name]) || 'Dashboard'
      txt_id = "band-#{page_id}-hdrtext"
      extra << SigmaLayout.header_text_el(txt_id, ttl)
      children << SigmaLayout.header_band_xml(hdr_id, txt_id)
    end

    # 2) bands from the SOURCE rows, columns from the SOURCE x-positions
    min_rows = { 'kpi-chart' => 4, 'control' => 2, 'text' => 2, 'image' => 20,
                 'scatter-chart' => 9, 'region-map' => 9, 'point-map' => 9 }
    bands = SigmaLayout.cluster_bands(items)
    cursor = 1 + SigmaLayout::HEADER_ROWS
    les = []
    bands.each do |band|
      # columns: cluster band items by x-overlap, preserving left-to-right order
      cols = []
      band.sort_by { |i| i[1] }.each do |it|
        hit = cols.find { |c| it[1] < c[:c1] && c[:c0] < it[2] }
        if hit
          hit[:items] << it
          hit[:c0] = [hit[:c0], it[1]].min
          hit[:c1] = [hit[:c1], it[2]].max
        else
          cols << { c0: it[1], c1: it[2], items: [it] }
        end
      end
      # normalized widths proportional to source widths, filling 1..25 exactly
      total = cols.sum { |c| c[:c1] - c[:c0] }.to_f
      alloc = cols.map { |c| [(24 * (c[:c1] - c[:c0]) / total).round, 3].max }
      diff = 24 - alloc.sum
      alloc[alloc.index(alloc.max)] += diff
      # band height: tallest member's source height, clamped by kind minimums
      band_h = band.map do |it|
        h = it[4] - it[3]
        [h, min_rows[kind_of[it[0]]] || 6].max
      end.max
      edge = 1
      cols.each_with_index do |c, ci|
        c0 = edge
        c1 = edge + alloc[ci]
        edge = c1
        stack = c[:items].sort_by { |i| i[3] }
        each_h = [band_h / stack.length, 2].max
        stack.each_with_index do |it, si|
          r0 = cursor + si * each_h
          r1 = (si == stack.length - 1) ? cursor + band_h : r0 + each_h
          les << [it[0], c0, c1, r0, r1]
        end
      end
      cursor += band_h
    end
    page_spec['elements'] = page_spec['elements'] + extra if page_spec
    inner = les.map { |i| SigmaLayout.le(i[0], i[1], i[2], i[3], i[4]) }.join("\n")
    next SigmaLayout.page_xml(page_id, children.join("\n"), inner)
  end

  # ---- PBI-fidelity FLAT layout (--layout pbi) ------------------------------
  # The page mirrors the PBI canvas 1:1: flat LayoutElements at the canvas-
  # proportional grid coords (exactly the shape Sigma's own UI writes), no
  # header band, no row containers. Band containers with auto rows COLLAPSE
  # around short content (KPIs lost their titles; map/scatter bands rendered
  # blank in page exports) — verified against the PBI page renders.
  if opts[:layout_mode] == 'pbi'
    kind_of = {}
    (page_spec ? page_spec['elements'] : []).each { |e| kind_of[e['id']] = e['kind'] }
    # Sigma needs more vertical room than PBI's compact widgets: clamp minimum
    # row spans per kind (KPI value+title needs ~5 rows; charts breathe at 6+).
    min_rows = { 'kpi-chart' => 4, 'scatter-chart' => 8, 'region-map' => 8, 'point-map' => 8,
                 'pie-chart' => 6, 'bar-chart' => 6, 'line-chart' => 6, 'area-chart' => 6,
                 'combo-chart' => 6 }
    items = items.map do |id, c0, c1, r0, r1|
      need = min_rows[kind_of[id]]
      r1 = r0 + need if need && (r1 - r0) < need
      c1 = c0 + 2 if c1 - c0 < 2
      [id, c0, c1, r0, r1]
    end
    # Sigma rejects overlapping LayoutElements ("Element collisions") while a
    # PBI canvas freely z-stacks (decorative text over chart corners). Resolve
    # deterministically: later/lower items push DOWN past whatever they hit.
    items = items.sort_by { |i| [i[3], i[1]] }
    10.times do
      moved = false
      items.each_with_index do |a, ai|
        items.each_with_index do |b, bi|
          next if bi <= ai
          cols = a[1] < b[2] && b[1] < a[2]
          rows = a[3] < b[4] && b[3] < a[4]
          next unless cols && rows
          delta = a[4] - b[3]
          b[3] += delta; b[4] += delta
          moved = true
        end
      end
      items = items.sort_by { |i| [i[3], i[1]] }
      break unless moved
    end
    # FILL THE CANVAS (customer feedback: "no white space, things big enough
    # to show the data"): PBI's compact widgets leave the converted page
    # sparse. Snap every element to its neighbors / page edges — stretch right
    # and down until the next element or the grid border (gaps <= 3 cols/rows
    # are dead gutters, not intentional spacing).
    overlap = ->(a0, a1, b0, b1) { a0 < b1 && b0 < a1 }
    items.each do |it|
      it[1] = 1 if it[1] <= 3 &&
                   items.none? { |o| !o.equal?(it) && o[2] <= it[1] + 1 && overlap.call(it[3], it[4], o[3], o[4]) }
      it[3] = 1 if it[3] <= 3 &&
                   items.none? { |o| !o.equal?(it) && o[4] <= it[3] + 1 && overlap.call(it[1], it[2], o[1], o[2]) }
    end
    items.each do |it|
      right = items.reject { |o| o.equal?(it) }
                   .select { |o| o[1] >= it[2] && overlap.call(it[3], it[4], o[3], o[4]) }
                   .map { |o| o[1] }.min || 25
      it[2] = right if right > it[2] && right - it[2] <= 3
      below = items.reject { |o| o.equal?(it) }
                   .select { |o| o[3] >= it[4] && overlap.call(it[1], it[2], o[1], o[2]) }
                   .map { |o| o[3] }.min
      it[4] = below if below && below > it[4] && below - it[4] <= 3
    end
    # bottom band: level everything to the page's max row
    maxr = items.map { |i| i[4] }.max
    items.each do |it|
      nothing_below = items.none? { |o| !o.equal?(it) && o[3] >= it[4] && overlap.call(it[1], it[2], o[1], o[2]) }
      it[4] = maxr if nothing_below && maxr - it[4] <= 4
    end
    inner = items.map { |i| SigmaLayout.le(i[0], i[1], i[2], i[3], i[4]) }.join("\n")
    next SigmaLayout.page_xml(page_id, inner)
  end
  # ---- legacy banded layout (--layout banded) ------------------------------
  # phase-e layout-quality fix: a short title TEXTBOX at the top of the source
  # canvas becomes the header band's text (white-on-dark), MOVED out of band 1
  # (never left behind as a dead zone). The candidate may start up to one grid
  # row below the page's topmost element (classic-report title boxes are
  # routinely nudged a few px down from y=0 — exact-row equality was the
  # PHASEE2 fragility). Same promotion the Phase E re-banding applies to
  # pre-container clones.
  top_row = items.map { |i| i[3] }.min
  hdr_vis = pg['visuals'].find do |v|
    next false unless v['sigma_kind'] == 'text' && v['text'].to_s.strip != ''
    it = items.find { |i| i[0] == "el-#{short(v['visual_id'])}" }
    it && it[3] <= top_row + 1 && (it[4] - it[3]) <= 5
  end
  if hdr_vis && page_spec
    hdr_eid = "el-#{short(hdr_vis['visual_id'])}"
    items = items.reject { |i| i[0] == hdr_eid }
    next nil if items.empty?
    hdr_el = page_spec['elements'].find { |e| e['id'] == hdr_eid }
    hdr_el['body'] = %(# <span style="color: #FFFFFF">#{hdr_vis['text']}</span>) if hdr_el
    xml, extra = banded_page(page_id, items, header_el: hdr_eid)
  else
    # No promotable source title — header text falls back, in priority order,
    # to: source page name (if not a generic auto-name) -> source report
    # display name (--source-title) -> workbook name. NEVER "Page 1".
    hdr_title = SigmaLayout.resolve_header_title(
      pg['page_title'], opts[:source_title], opts[:name]
    ) || 'Dashboard'
    xml, extra = banded_page(page_id, items, title: hdr_title)
  end
  page_spec['elements'] = page_spec['elements'] + extra if page_spec
  xml
end.compact.join("\n")
layout_xml = %(<?xml version="1.0" encoding="utf-8"?>\n#{pages_xml}\n)

spec = {
  'name' => opts[:name] || opts[:source_title] ||
            signals.dig('pages', 0, 'page_title') || 'Power BI Import',
  'schemaVersion' => 1,
  'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'elements' => data_elements }] + content_pages,
  # bead 16i: embed the layout so the very first POST does not trigger Sigma's
  # single-column auto-layout (which would wipe put-layout.rb's grid).
  'layout' => layout_xml
}
spec['folderId'] = opts[:folder] if opts[:folder]

File.write(opts[:out], JSON.pretty_generate(spec))
warn "[build-workbook] wrote #{opts[:out]} (#{data_elements.size} master(s), " \
     "#{content_pages.sum { |p| p['elements'].size }} chart element(s); layout embedded)"

if opts[:layout_out]
  File.write(opts[:layout_out], layout_xml)
  warn "[build-workbook] wrote layout -> #{opts[:layout_out]}"
end
