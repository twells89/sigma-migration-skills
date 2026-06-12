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
  p.on('--data-model ID')    { |v| opts[:dm] = v }
  p.on('--out PATH')         { |v| opts[:out] = v }
  p.on('--layout-out PATH')  { |v| opts[:layout_out] = v }
  p.on('--name NAME')        { |v| opts[:name] = v }
  # The SOURCE report/dashboard display name (e.g. "EMPLOYEE DASHBOARD") —
  # header-band title fallback when a page has no promotable title textbox and
  # its own name is a generic auto-name ("Page 1"). See resolve_header_title.
  p.on('--source-title NAME') { |v| opts[:source_title] = v }
  p.on('--folder-id ID')     { |v| opts[:folder] = v }
end.parse!
%i[sig mmap out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

signals = JSON.parse(File.read(opts[:sig]))
mmap    = JSON.parse(File.read(opts[:mmap]))
fields  = mmap['fields'] || {}
masters = mmap['masters'] || {}

SIGMA_KIND = {
  'kpi' => 'kpi-chart', 'bar' => 'bar-chart', 'line' => 'line-chart',
  'area' => 'area-chart', 'combo' => 'combo-chart', 'scatter' => 'scatter-chart',
  'pie' => 'pie-chart', 'donut' => 'donut-chart',
  'table' => 'table', 'pivot-table' => 'pivot-table', 'text' => 'text',
  'control' => 'control'
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
def build_element(rec, fields, masters, extra_data = [])
  kind = SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'
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
    body = rec['text'] ? "## #{rec['text']}" : '## '
    return { 'id' => eid, 'kind' => 'text', 'body' => body }
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
    # bead 14w(a)/6z5: a PBI slicer -> a Sigma `list` control bound to the sliced
    # column on its master element. Valid shape (controls.md): controlType:list +
    # controlId + mode + selectionMode + values[] + source{kind:source,...} +
    # filters[]. The control defines NO columns of its own — it references the
    # master's existing column id, so it both populates from and filters that col.
    qr = (b['Values'] || b['Category'] || b['Fields'] || []).first
    colname = qr_leaf(qr, 'Filter')
    mcols = (master && masters[master] ? (masters[master]['columns'] || []) : [])
    mcol = mcols.find { |c| c['name'] == colname } || mcols.first
    tgt = mcol ? mcol['id'] : nil
    el['kind'] = 'control'
    el['controlId'] = colname.gsub(/[^A-Za-z0-9]/, '') + 'Filter'
    el['name'] = colname
    el['controlType'] = 'list'
    el['mode'] = 'include'
    el['selectionMode'] = 'multiple'
    el['values'] = []
    el.delete('source')
    if master_id && tgt
      el['source']  = { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => master_id }, 'columnId' => tgt }
      el['filters'] = [{ 'source' => { 'kind' => 'table', 'elementId' => master_id }, 'columnId' => tgt }]
    end
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
    el['stacking'] = rec['stacking'] if kind == 'bar-chart' && rec['stacking']
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
    end
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
  when 'scatter-chart'
    # bead 14w(b): scatter -> xAxis (measure), yAxis (measure), point category for
    # color/detail. PBI scatter binds X + Y (both measures) and a Category/Details.
    xqr = (b['X'] || b['Values'] || []).first
    yqr = (b['Y'] || []).first
    detail = (b['Category'] || b['Details'] || b['Series'] || b['Legend'] || []).first
    sizeqr = (b['Size'] || []).first
    xfs = field_spec(xqr, fields, master); yfs = field_spec(yqr, fields, master)
    is_meas = ->(fs) { !(fs['agg'].to_s.empty? && fs['formula'].to_s.empty?) }
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
      is_dim = fs['agg'].to_s.empty? && fs['formula'].to_s.empty?
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
  # build_element may return one element or an array (multiRowCard -> N KPIs).
  els = pg['visuals'].flat_map do |v|
    r = build_element(v, fields, masters, extra_data_elements)
    r.is_a?(Array) ? r : [r]   # NB: not Array(r) — that explodes a Hash into pairs
  end
  { 'id' => "page-#{pg['page_id']}", 'name' => pg['page_title'], 'elements' => els }
end
data_elements += extra_data_elements

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
ROW_UNIT = 30.0
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
  next nil if items.empty?
  page_spec = content_pages.find { |p| p['id'] == page_id }
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
