#!/usr/bin/env ruby
# frozen_string_literal: true
#
# enhance-scan.rb — Phase E (opt-in) shared engine, part 1 of 2: SCAN.
#
# Reads source-migration signals (workdir artifacts) + the PARITY-VERIFIED
# built workbook (live spec + element data exports) and emits
# enhancements.json: a list of candidate enhancements, each with
#   {id, category, evidence, proposed, risk, verdict_hint, patch}
# NOTHING here writes to Sigma — scan is strictly read-only. Application is
# enhance-apply.rb's job, and ONLY for explicitly accepted candidates.
#
# This file is the SHARED Phase-E engine, vendored byte-identical into every
# covered plugin (md5 discipline — same as escalate-gap.py). Keep it
# tool-agnostic: per-source behavior keys off --source + which workdir
# artifacts exist, never off the plugin it happens to live in.
#
# The detector catalog is TRIAL-VALIDATED (2026-06-10 prototype trials on
# tableau/qlik/powerbi migrations) — nothing speculative:
#   1. comparison-enrichment  date-grouped master -> prior-period KPI pair
#      (the verified Sum(If(D = Max(D), v, Null)) inline shape; KPI value
#      columns must INLINE the full expression — cross-column aggregate refs
#      silently misevaluate).
#   2. interactivity-recovery
#      (a) selection controls — list controls on reasonable-cardinality dims
#          wired to the shared master (qlik-trial pattern; empty default =>
#          untouched render identical).
#      (b) grain switcher — segmented control + DateTrunc switch on a
#          date-grouped chart (PBI-trial pattern; default == parity grain).
#      (c) drill switcher — segmented control + If() dimension switch where a
#          finer dimension exists on the master (tableau-trial pattern).
#      (d) map restoration (PBI) — azureMap-approximated-as-bar -> point-map
#          with Switch() centroid synthesis when geo-ish columns exist
#          (PBI-trial verified shape; centroids must be supplied at apply).
#   3. fidelity-polish — null-bucket labeling (Coalesce -> "No <Dim>"),
#      month/date axis canonicalization (MakeDate), stale-source freshness
#      note (time-boxed wording), title corrections from source captions.
#   DESCOPED (trial-proven spec-unsupported; emitted as propose-in-UI NOTES,
#   never spec changes): chart-as-filter (useAsFilter silently dropped on
#   readback), pie percent labels (valueFormat:'percent' silently dropped).
#
# Usage:
#   ruby scripts/enhance-scan.rb --workbook-id <parityWorkbookId> \
#     --workdir <migration workdir> [--source tableau|powerbi|qlik|...] \
#     [--out enhancements.json] [--max-exports N]
#
# Env: SIGMA_BASE_URL + SIGMA_CLIENT_ID/SECRET (lib/sigma_rest.rb bootstraps
# from ~/.sigma-migration/env when unset).

require 'json'
require 'csv'
require 'time'
require 'digest'
require 'optparse'

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'sigma_rest'
require 'enhance_options'
require 'code_rep'

opts = { max_exports: 12 }
OptionParser.new do |o|
  o.on('--workbook-id ID')  { |v| opts[:wb] = v }
  o.on('--workdir DIR')     { |v| opts[:workdir] = File.expand_path(v) }
  o.on('--source NAME')     { |v| opts[:source] = v }
  o.on('--out PATH')        { |v| opts[:out] = File.expand_path(v) }
  o.on('--max-exports N', Integer) { |v| opts[:max_exports] = v }
end.parse!
abort 'missing --workbook-id' unless opts[:wb]
WB = opts[:wb]
WORKDIR = opts[:workdir]
OUT = opts[:out] || (WORKDIR ? File.join(WORKDIR, 'enhancements.json') : 'enhancements.json')

def jread(path)
  return nil unless path && File.exist?(path)
  JSON.parse(File.read(path))
rescue StandardError
  nil
end

# Infer the source tool from workdir artifacts when --source is not given.
source = opts[:source]
if source.nil? && WORKDIR
  source = if File.exist?(File.join(WORKDIR, 'signals.json')) then 'powerbi'
           elsif File.exist?(File.join(WORKDIR, 'dashboard-layout.json')) ||
                 File.exist?(File.join(WORKDIR, 'calc-fields.json')) then 'tableau'
           end
end
source ||= 'unknown'

# ---------------------------------------------------------------------------
# Load the live spec + export element data (read-only).
# ---------------------------------------------------------------------------
# Workbook code-rep nests pages/elements/layout/schemaVersion/kind under a top-level
# `document` key (live since 2026-08-03/04); flatten metadata (name, etc.)
# and document content back onto one hash so every existing spec['...'] read
# below (mixing both) keeps working unchanged. Read-only file — no PUT here,
# so there is no wrap-back to worry about.
raw_spec = Sigma.request(:get, "/v2/workbooks/#{WB}/spec")
spec = Sigma::CodeRep.metadata(raw_spec).merge(Sigma::CodeRep.document(raw_spec))
abort "FATAL: could not read spec for workbook #{WB}" unless raw_spec.is_a?(Hash) &&
                                                           spec['pages'].is_a?(Array) &&
                                                           spec['elements'].is_a?(Array) &&
                                                           !spec['layout'].to_s.empty?
wb_name = spec['name'].to_s

VIZ_KINDS = %w[bar-chart line-chart area-chart pie-chart combo-chart scatter-chart].freeze
pages = spec['pages'] || []
data_page = pages.find { |p| p['id'] == 'page-data' } || pages.find { |p| p['name'].to_s =~ /\bdata\b/i }
dash_pages = pages - [data_page].compact
elements_with_pages = Sigma::CodeRep.workbook_elements_with_pages(spec)
page_by_element = Sigma::CodeRep.workbook_page_by_element(spec)
dash_page_ids = dash_pages.map { |p| p['id'] }
viz = elements_with_pages.select do |e, page|
  page && dash_page_ids.include?(page['id']) && VIZ_KINDS.include?(e['kind'])
end.map { |e, page| [page, e] }
controls = elements_with_pages.select do |e, page|
  page && dash_page_ids.include?(page['id']) && e['kind'] == 'control'
end.map(&:first)
masters = data_page ? elements_with_pages.select { |_e, page| page && page['id'] == data_page['id'] }.map(&:first) : []
master_by_id = masters.to_h { |e| [e['id'], e] }

# Export an element's data rows via the REST export API (JSON). Best-effort.
def export_rows(wb, element_id, timeout: 75)
  res = Sigma.request(:post, "/v2/workbooks/#{wb}/export",
                      body: { 'elementId' => element_id, 'format' => { 'type' => 'json' } }.to_json)
  qid = res.is_a?(Hash) ? res['queryId'] : nil
  return nil unless qid
  deadline = Time.now + timeout
  while Time.now < deadline
    body = (Sigma.request(:get, "/v2/query/#{qid}/download", binary: true) rescue nil)
    if body && !body.strip.empty?
      parsed = (JSON.parse(body) rescue nil)
      return parsed if parsed.is_a?(Array)
      return parsed['rows'] if parsed.is_a?(Hash) && parsed['rows'].is_a?(Array)
      lines = body.each_line.map { |l| (JSON.parse(l) rescue nil) }.compact
      return lines unless lines.empty?
    end
    sleep 2
  end
  nil
rescue StandardError
  nil
end

# Per-element data cache (each viz exported at most once; capped).
rows_by_el = {}
exported = 0
viz.each do |(_pg, el)|
  break if exported >= opts[:max_exports]
  rows_by_el[el['id']] = export_rows(WB, el['id'])
  exported += 1
end

# ---------------------------------------------------------------------------
# Spec-navigation helpers.
# ---------------------------------------------------------------------------
def col_by_id(el, cid)
  (el['columns'] || []).find { |c| c['id'] == cid }
end

# The categorical/x column of a viz element.
def x_col(el)
  cid = el.dig('xAxis', 'columnId') || el.dig('color', 'columnId') ||
        el.dig('color', 'column') || el.dig('category', 'columnId') ||
        el.dig('color', 'id') || el.dig('category', 'id')
  cid && col_by_id(el, cid)
end

# The first value/measure column.
def y_col(el)
  cid = Array(el.dig('yAxis', 'columnIds')).first || el.dig('value', 'id') || el.dig('value', 'columnId')
  cid = cid['columnId'] if cid.is_a?(Hash)
  cid && col_by_id(el, cid)
end

# A bare single-ref formula like "[Master/Region]" -> ['Master', 'Region'].
def bare_ref(formula)
  m = formula.to_s.strip.match(/\A\[([^\]]+)\]\z/)
  return nil unless m
  parts = m[1].split('/')
  return nil if parts.size < 2
  [parts[0..-2].join('/'), parts[-1]]
end

def norm(s)
  s.to_s.downcase.gsub(/[^a-z0-9]/, '')
end

# Pull the value for a viz row matching a column display name (export keys are
# display names, sometimes suffixed).
def row_val(row, colname)
  return row[colname] if row.key?(colname)
  k = row.keys.find { |kk| norm(kk) == norm(colname) }
  k && row[k]
end

DATEISH = /\b(date|month|year|week|quarter|day)\b/i
MEASUREISH = /revenue|sales|amount|profit|margin|net|gross|total|spend|cost|price|hours|count|orders|quantity|qty|units|headcount/i

candidates = []
descoped = []

# ---------------------------------------------------------------------------
# 1. comparison-enrichment — prior-period KPI pair on the best date-grouped
#    chart. Verified shape: KPI value column INLINES the full conditional
#    aggregate (Sum(If(D = Max(D), v, Null))) — never references sibling
#    aggregate columns (they silently misevaluate in kpi-chart).
# ---------------------------------------------------------------------------
comparison_target = nil
viz.sort_by { |(_p, e)| e['kind'] == 'line-chart' ? 0 : 1 }.each do |(_pg, el)|
  xc = x_col(el)
  yc = y_col(el)
  next unless xc && yc
  next unless yc['formula'].to_s =~ /\ASum\((.+)\)\z/m
  inner_v = Regexp.last_match(1)
  next unless (yc['name'].to_s =~ MEASUREISH) || (yc['formula'].to_s =~ MEASUREISH)
  xf = xc['formula'].to_s
  d_expr = nil
  unit = nil
  if (m = xf.match(/\ADateTrunc\(\s*"(\w+)"\s*,\s*(.+)\)\z/m))
    unit = m[1]
    d_expr = xf
  elsif xc['name'].to_s =~ DATEISH || xf =~ DATEISH
    # Derive a usable month-grain date expression over the same source:
    # a real date column on the ref prefix, else MakeDate(Year, Month, 1).
    ref = bare_ref(xf)
    src_el = master_by_id[el.dig('source', 'elementId')]
    prefix = ref ? ref[0] : (src_el && src_el['name'])
    src_cols = src_el ? (src_el['columns'] || []).map { |c| c['name'].to_s } : []
    date_col = src_cols.find { |n| n =~ /\bdate\b/i && n !~ /\bkey\b/i }
    year_col = src_cols.find { |n| n =~ /\byear\b/i }
    month_col = src_cols.find { |n| n =~ /\bmonth\b/i && n !~ /name/i }
    if prefix && date_col
      d_expr = "DateTrunc(\"month\", [#{prefix}/#{date_col}])"
      unit = 'month'
    elsif prefix && year_col && month_col
      d_expr = "DateTrunc(\"month\", MakeDate([#{prefix}/#{year_col}], [#{prefix}/#{month_col}], 1))"
      unit = 'month'
    end
  end
  next unless d_expr && unit
  comparison_target = { el: el, inner_v: inner_v, d: d_expr, unit: unit,
                        measure: yc['name'].to_s, fmt: yc['format'] }
  break
end

if comparison_target
  t = comparison_target
  el = t[:el]
  cur = "Sum(If(#{t[:d]} = Max(#{t[:d]}), #{t[:inner_v]}, Null))"
  prev = "Sum(If(#{t[:d]} = DateAdd(\"#{t[:unit]}\", -1, Max(#{t[:d]})), #{t[:inner_v]}, Null))"
  page_id = page_by_element[el['id']]&.dig('id') || dash_pages.first&.dig('id')
  kpi_cur = {
    'id' => 'el-phasee-kpi-current', 'kind' => 'kpi-chart',
    'name' => "Latest #{t[:unit].capitalize} #{t[:measure]}",
    'source' => el['source'],
    'columns' => [{ 'id' => 'phasee-kpi-cur-val', 'name' => "Latest #{t[:unit].capitalize} #{t[:measure]}",
                    'formula' => cur }.merge(t[:fmt] ? { 'format' => t[:fmt] } : {})],
    'value' => { 'columnId' => 'phasee-kpi-cur-val' }
  }
  kpi_delta = {
    'id' => 'el-phasee-kpi-delta', 'kind' => 'kpi-chart',
    'name' => "#{t[:measure]} vs prior #{t[:unit]}",
    'source' => el['source'],
    'columns' => [{ 'id' => 'phasee-kpi-delta-val', 'name' => "#{t[:measure]} Δ vs prior #{t[:unit]}",
                    'formula' => "((#{cur}) - (#{prev})) / (#{prev})",
                    'format' => { 'kind' => 'number', 'formatString' => '+,.1%' } }],
    'value' => { 'columnId' => 'phasee-kpi-delta-val' }
  }
  candidates << {
    'id' => 'comparison-kpi-pair',
    'category' => 'comparison-enrichment',
    'evidence' => "'#{el['name']}' (#{el['kind']}) groups #{t[:measure]} by a date expression " \
                  "(#{t[:d][0, 90]}); the dashboard has no period-over-period context. " \
                  'Trial-verified pattern: latest-period KPI + delta-% KPI, full expression inlined ' \
                  '(KPI cross-column aggregate refs silently misevaluate).',
    'proposed' => "Add 2 KPI tiles sourcing the same element: 'Latest #{t[:unit].capitalize} " \
                  "#{t[:measure]}' and '#{t[:measure]} vs prior #{t[:unit]}' (delta %). Purely additive — " \
                  'no existing element changes.',
    'risk' => 'low',
    'verdict_hint' => 'apply',
    'patch' => { 'op' => 'add_elements', 'page_id' => page_id,
                 'elements' => [kpi_cur, kpi_delta],
                 'layout' => [{ 'element_id' => 'el-phasee-kpi-current', 'grid_column' => '1 / 13', 'height' => 6 },
                              { 'element_id' => 'el-phasee-kpi-delta', 'grid_column' => '13 / 25', 'height' => 6,
                                'same_row_as' => 'el-phasee-kpi-current' }] }
  }
end

# ---------------------------------------------------------------------------
# 2a. selection controls — list controls on reasonable-cardinality dims wired
#     to the shared master (qlik-trial verified shape). Empty default values
#     => untouched render is identical, so this is low risk.
# ---------------------------------------------------------------------------
existing_ctrl_cols = controls.flat_map { |c| Array(c['filters']).map { |f| f['columnId'] } }
                             .compact
sel_seen = {}
viz.each do |(_pg, el)|
  break if candidates.count { |c| c['id'].start_with?('interactivity-selection-') } >= 3
  xc = x_col(el)
  next unless xc
  ref = bare_ref(xc['formula'])
  next unless ref
  next if xc['name'].to_s =~ DATEISH
  src_eid = el.dig('source', 'elementId')
  master = master_by_id[src_eid]
  next unless master
  # shared master: at least 2 viz source it (the propagation that makes one
  # control filter the whole dashboard).
  next unless viz.count { |(_p, e)| e.dig('source', 'elementId') == src_eid } >= 2
  leaf = ref[1]
  mcol = (master['columns'] || []).find { |c| c['name'].to_s == leaf } ||
         (master['columns'] || []).find { |c| norm(c['name']) == norm(leaf) }
  next unless mcol
  next if sel_seen[mcol['id']]
  next if existing_ctrl_cols.include?(mcol['id']) # already has a control
  rows = rows_by_el[el['id']]
  card = rows ? rows.map { |r| row_val(r, xc['name'].to_s) }.uniq.size : nil
  next if card && (card < 2 || card > 50)
  sel_seen[mcol['id']] = true
  cid = "PhaseE#{leaf.gsub(/[^A-Za-z0-9]/, '')}Filter"
  ctrl = {
    'id' => "ctrl-phasee-#{Digest::SHA1.hexdigest(mcol['id'])[0, 6]}",
    'kind' => 'control', 'controlId' => cid, 'name' => leaf,
    'controlType' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple',
    'values' => [],
    'source' => { 'kind' => 'source',
                  'source' => { 'kind' => 'table', 'elementId' => master['id'] },
                  'columnId' => mcol['id'] },
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => master['id'] },
                    'columnId' => mcol['id'] }]
  }
  candidates << {
    'id' => "interactivity-selection-#{norm(leaf)}",
    'category' => 'interactivity-recovery',
    'evidence' => "'#{leaf}' is a chart dimension#{card ? " with #{card} member(s)" : ''} on the shared " \
                  "master '#{master['name']}' (#{viz.count { |(_p, e)| e.dig('source', 'elementId') == src_eid }} " \
                  'charts source it) and has no filter control. A list control on the shared source ' \
                  'filters every consumer (verified propagation pattern).',
    'proposed' => "Add a '#{leaf}' list control bound to the master column. Default = no selection, " \
                  'so the untouched render is identical.',
    'risk' => 'low',
    'verdict_hint' => 'apply',
    'patch' => { 'op' => 'add_elements',
                 'page_id' => dash_pages.first&.dig('id'),
                 'elements' => [ctrl],
                 'layout' => [{ 'element_id' => ctrl['id'], 'grid_column' => '1 / 9', 'height' => 3 }] }
  }
end

# ---------------------------------------------------------------------------
# 2b. grain switcher — segmented control + DateTrunc switch (PBI-trial shape).
#     Default value == the parity grain, so element data is unchanged until a
#     user switches — low risk.
# ---------------------------------------------------------------------------
viz.each do |(pg, el)|
  xc = x_col(el)
  next unless xc
  m = xc['formula'].to_s.match(/\ADateTrunc\(\s*"(year|quarter|month|week|day)"\s*,\s*(.+)\)\z/m)
  next unless m
  cur_unit = m[1]
  inner = m[2]
  grains = %w[Year Quarter Month]
  grains << cur_unit.capitalize unless grains.include?(cur_unit.capitalize)
  cid = "PhaseEGrain#{Digest::SHA1.hexdigest(el['id'])[0, 4]}"
  new_f = "If([#{cid}] = \"Year\", DateTrunc(\"year\", #{inner}), " \
          "If([#{cid}] = \"Quarter\", DateTrunc(\"quarter\", #{inner}), " \
          "DateTrunc(\"#{cur_unit}\", #{inner})))"
  ctrl = {
    'id' => "ctrl-phasee-grain-#{Digest::SHA1.hexdigest(el['id'])[0, 6]}",
    'kind' => 'control', 'controlId' => cid, 'name' => "#{el['name']} grain",
    'controlType' => 'segmented',
    'source' => { 'kind' => 'manual', 'valueType' => 'text',
                  'values' => grains, 'labels' => grains.map { nil } },
    'value' => cur_unit.capitalize
  }
  candidates << {
    'id' => "interactivity-grain-#{el['id']}",
    'category' => 'interactivity-recovery',
    'evidence' => "'#{el['name']}' is hard-grouped to DateTrunc(\"#{cur_unit}\") — the source's date " \
                  'drill/hierarchy affordance was frozen at one grain by the migration. Segmented ' \
                  'control + DateTrunc switch is the trial-verified spec-persistable equivalent.',
    'proposed' => "Add a segmented '#{grains.join('/')}' grain control (default #{cur_unit.capitalize} " \
                  '= parity grain, so data is unchanged at default) and wire the x-axis through it.',
    'risk' => 'low',
    'verdict_hint' => 'apply',
    'patch' => { 'op' => 'add_control_and_rewire', 'page_id' => pg['id'],
                 'control' => ctrl,
                 'rewire' => { 'element_id' => el['id'], 'column_id' => xc['id'], 'formula' => new_f },
                 'layout' => [{ 'element_id' => ctrl['id'], 'grid_column' => '17 / 25', 'height' => 3 }] }
  }
  break # one grain switcher per workbook is plenty for the opt-in pass
end

# ---------------------------------------------------------------------------
# 2c. drill switcher — segmented control + If() dimension switch where a finer
#     dimension exists on the master (tableau-trial pattern). Medium risk: it
#     rewrites the chart's category formula (default reproduces the parity
#     grouping, but the hierarchy pairing is heuristic — confirm before apply).
# ---------------------------------------------------------------------------
HIERARCHY = {
  'region' => %w[state province],
  'state' => %w[city county],
  'category' => ['sub-category', 'subcategory', 'sub category', 'product name'],
  'department' => %w[team role title],
  'country' => %w[state region city]
}.freeze
viz.each do |(pg, el)|
  next if candidates.any? { |c| c['id'].start_with?('interactivity-drill-') }
  xc = x_col(el)
  next unless xc
  ref = bare_ref(xc['formula'])
  next unless ref
  prefix, leaf = ref
  finer_names = HIERARCHY[leaf.downcase.strip]
  next unless finer_names
  src_el = master_by_id[el.dig('source', 'elementId')]
  next unless src_el
  finer = (src_el['columns'] || []).map { |c| c['name'].to_s }
                                   .find { |n| finer_names.include?(n.downcase.strip) }
  next unless finer
  cid = "PhaseELevel#{Digest::SHA1.hexdigest(el['id'])[0, 4]}"
  new_f = "If([#{cid}] = \"#{finer}\", [#{prefix}/#{finer}], [#{prefix}/#{leaf}])"
  ctrl = {
    'id' => "ctrl-phasee-drill-#{Digest::SHA1.hexdigest(el['id'])[0, 6]}",
    'kind' => 'control', 'controlId' => cid, 'name' => "#{el['name']} level",
    'controlType' => 'segmented',
    'source' => { 'kind' => 'manual', 'valueType' => 'text',
                  'values' => [leaf, finer], 'labels' => [nil, nil] },
    'value' => leaf
  }
  candidates << {
    'id' => "interactivity-drill-#{el['id']}",
    'category' => 'interactivity-recovery',
    'evidence' => "'#{el['name']}' groups by '#{leaf}' and the master also exposes the finer " \
                  "'#{finer}' — users of the source clearly analyze below #{leaf} level, but Sigma's " \
                  'spec has no native drill/hierarchy field (UI-only). Segmented control + If() switch ' \
                  'is the trial-verified spec equivalent.',
    'proposed' => "Add a '#{leaf}/#{finer}' segmented control (default #{leaf} reproduces the parity " \
                  'grouping) and switch the category formula through it.',
    'risk' => 'medium',
    'verdict_hint' => 'confirm — rewrites the chart category formula; hierarchy pairing is heuristic',
    'patch' => { 'op' => 'add_control_and_rewire', 'page_id' => pg['id'],
                 'control' => ctrl,
                 'rewire' => { 'element_id' => el['id'], 'column_id' => xc['id'], 'formula' => new_f },
                 'layout' => [{ 'element_id' => ctrl['id'], 'grid_column' => '9 / 17', 'height' => 3 }] }
  }
end

# ---------------------------------------------------------------------------
# 2d. map restoration (PBI-trial shape) — a source map visual that the
#     migration approximated as a bar/table, where geo-ish columns exist.
#     point-map with Switch() centroid synthesis; the centroid table must be
#     supplied at apply time (patch.needs='centroids'), so this is never
#     auto-applied by all-low-risk.
# ---------------------------------------------------------------------------
signals = WORKDIR && jread(File.join(WORKDIR, 'signals.json'))
if signals
  map_visuals = (signals['pages'] || []).flat_map { |p| p['visuals'] || [] }
                                        .select { |v| v['visual_type'].to_s =~ /azureMap|filledMap|shapeMap|^map$/i }
  map_visuals.each do |mv|
    title = (mv['title'] || mv['visual_id']).to_s
    approx = viz.map(&:last).find { |e| norm(e['name']) == norm(title) } ||
             viz.map(&:last).find { |e| !title.empty? && norm(e['name']).include?(norm(title)) }
    src_el = approx && master_by_id[approx.dig('source', 'elementId')]
    geo_cols = src_el ? (src_el['columns'] || []).map { |c| c['name'].to_s }
                                                 .select { |n| n =~ /\b(city|state|zip|postal|country|region|lat|latitude|lon|lng|longitude|location)\b/i } : []
    candidates << {
      'id' => "interactivity-map-#{norm(title)[0, 24]}",
      'category' => 'interactivity-recovery',
      'evidence' => "Source visual '#{title}' is a #{mv['visual_type']} (map), but the migration " \
                    "approximated it as #{approx ? "'#{approx['name']}' (#{approx['kind']})" : 'a non-map element (no name match found in the built workbook)'}." \
                    "#{geo_cols.any? ? " Geo-ish columns available on the source element: #{geo_cols.join(', ')}." : ' No geo-ish columns detected on the matched element.'}",
      'proposed' => 'Restore as a Sigma point-map (trial-verified shape: latitude/longitude/size ' \
                    'bindings persist on readback) with Switch()-synthesized centroids per geo value. ' \
                    "Requires a centroid table {value: [lat, lng]} filled into the patch before apply" \
                    "#{geo_cols.any? ? " (geo column: #{geo_cols.first})" : ''}.",
      'risk' => 'medium',
      'verdict_hint' => 'confirm — needs centroid synthesis; present to the user with the geo column list',
      'patch' => (approx && geo_cols.any? ? {
        'op' => 'replace_with_point_map', 'needs' => 'centroids',
        'element_id' => approx['id'], 'page_id' => page_by_element[approx['id']]&.dig('id'),
        'geo_column' => geo_cols.first, 'source' => approx['source'],
        'geo_ref' => "[#{src_el['name']}/#{geo_cols.first}]",
        'value_formula' => (y_col(approx) || {})['formula'],
        'value_name' => (y_col(approx) || {})['name'],
        'centroids' => {}
      } : nil)
    }
  end
end

# ---------------------------------------------------------------------------
# 3a. null-bucket labeling — a categorical axis with a null bucket renders a
#     blank label; Coalesce -> "No <Dim>" (label-only; values unchanged).
# ---------------------------------------------------------------------------
viz.each do |(_pg, el)|
  xc = x_col(el)
  rows = rows_by_el[el['id']]
  next unless xc && rows.is_a?(Array) && rows.any?
  next unless bare_ref(xc['formula']) # only bare dim refs (don't stack onto switches)
  next if xc['name'].to_s =~ DATEISH
  null_rows = rows.select { |r| v = row_val(r, xc['name'].to_s); v.nil? || v.to_s.strip.empty? }
  next if null_rows.empty?
  label = "No #{xc['name']}"
  candidates << {
    'id' => "polish-null-label-#{el['id']}",
    'category' => 'fidelity-polish',
    'evidence' => "'#{el['name']}' has #{null_rows.size} null '#{xc['name']}' bucket(s) — Sigma renders " \
                  'a blank category label, leaving the bar/slice unexplained (export-verified).',
    'proposed' => "Wrap the category as Coalesce(#{xc['formula']}, \"#{label}\") — label only; " \
                  'bucket values unchanged.',
    'risk' => 'low',
    'verdict_hint' => 'apply',
    'patch' => { 'op' => 'set_column_formula', 'element_id' => el['id'], 'column_id' => xc['id'],
                 'formula' => "Coalesce(#{xc['formula']}, \"#{label}\")" }
  }
end

# ---------------------------------------------------------------------------
# 3a2. value-label polish — the source tool shows data labels by default on
#      small categorical charts; a migrated bar/pie with NO dataLabel config
#      reads bare. dataLabel:{labels:'shown'} is the verified persisting shape
#      (valueFormat:'percent' is NOT — see the descoped notes). Additive-config
#      only; values untouched.
viz.each do |(_pg, el)|
  next unless %w[bar-chart pie-chart line-chart].include?(el['kind'])
  next if el['dataLabel']
  rows = rows_by_el[el['id']]
  next if rows.is_a?(Array) && rows.size > 24 # labels unreadable on dense charts
  candidates << {
    'id' => "polish-data-labels-#{el['id']}",
    'category' => 'fidelity-polish',
    'evidence' => "'#{el['name']}' (#{el['kind']}#{rows.is_a?(Array) ? ", #{rows.size} bucket(s)" : ''}) has no " \
                  'dataLabel config — source-tool defaults show value labels on small categorical charts.',
    'proposed' => "Set dataLabel:{labels:'shown'} (trial-verified persisting shape; percent styling is " \
                  'UI-only and stays descoped).',
    'risk' => 'low',
    'verdict_hint' => 'apply',
    'patch' => { 'op' => 'set_element_prop', 'element_id' => el['id'],
                 'prop' => 'dataLabel', 'value' => { 'labels' => 'shown' } }
  }
end

# ---------------------------------------------------------------------------
# 3b. month/date axis canonicalization — a chart grouped by a bare month
#     NUMBER (1..12) reads as integers and pools across years; MakeDate(Year,
#     Month, 1) restores a true date axis. Medium risk: on a multi-year source
#     this intentionally un-pools the series (trial-validated divergence).
# ---------------------------------------------------------------------------
viz.each do |(_pg, el)|
  xc = x_col(el)
  rows = rows_by_el[el['id']]
  next unless xc && rows.is_a?(Array) && rows.any?
  next unless xc['name'].to_s =~ /\bmonth\b/i && xc['name'].to_s !~ /name/i
  vals = rows.map { |r| row_val(r, xc['name'].to_s) }.compact
  next if vals.empty?
  next unless vals.all? { |v| v.to_s =~ /\A\d+(\.0+)?\z/ && v.to_f.between?(1, 12) }
  ref = bare_ref(xc['formula'])
  next unless ref
  prefix, = ref
  src_el = master_by_id[el.dig('source', 'elementId')]
  year_col = src_el && (src_el['columns'] || []).map { |c| c['name'].to_s }.find { |n| n =~ /\byear\b/i }
  next unless year_col
  candidates << {
    'id' => "polish-date-axis-#{el['id']}",
    'category' => 'fidelity-polish',
    'evidence' => "'#{el['name']}' x-axis is a bare month NUMBER (export shows #{vals.uniq.size} integer " \
                  "bucket(s) in 1..12) — reads as 1,2,3 and pools all years into 12 buckets. Master exposes " \
                  "'#{year_col}'.",
    'proposed' => "x-axis -> MakeDate([#{prefix}/#{year_col}], #{xc['formula']}, 1): true date axis " \
                  '(Jan 2026 style). NOTE: on a multi-year source this correctly UN-POOLS the series ' \
                  '(intended divergence on this element only).',
    'risk' => 'medium',
    'verdict_hint' => 'confirm — changes this element\'s own buckets if the source spans multiple years',
    'patch' => { 'op' => 'set_column_formula', 'element_id' => el['id'], 'column_id' => xc['id'],
                 'formula' => "MakeDate([#{prefix}/#{year_col}], #{xc['formula']}, 1)" }
  }
end

# ---------------------------------------------------------------------------
# 3c. stale-source freshness note — a frozen source snapshot (Tableau extract /
#     stale PBI import) means Sigma (live) WILL show different numbers. A
#     time-boxed text note heads that off. Purely additive — low risk.
# ---------------------------------------------------------------------------
fresh_note = nil
if WORKDIR
  state = jread(File.join(WORKDIR, 'migrate-state.json'))
  freshness = jread(File.join(WORKDIR, 'freshness.json'))
  if freshness && freshness['staleDays'].to_f >= 1
    last = freshness.dig('lastSuccessfulRefresh', 'endTime')
    fresh_note = "**Migration note (as of #{Time.now.utc.strftime('%Y-%m-%d')})** — the source " \
                 "Power BI dataset was last refreshed #{last} (~#{freshness['staleDays'].to_f.ceil} day(s) " \
                 'before migration). This workbook queries the warehouse **live**, so totals here are ' \
                 'expected to run ahead of the frozen source snapshot.'
  elsif state && state['extract_mode']
    fresh_note = "**Migration note (as of #{Time.now.utc.strftime('%Y-%m-%d')})** — the source Tableau " \
                 'workbook reads a frozen EXTRACT snapshot. This workbook queries the warehouse ' \
                 '**live**, so totals here are expected to drift ahead of the extract until it is refreshed.'
  end
end
if fresh_note
  candidates << {
    'id' => 'polish-freshness-note',
    'category' => 'fidelity-polish',
    'evidence' => 'Source is a frozen snapshot (extract/import) while Sigma reads the live warehouse — ' \
                  'the classic "numbers don\'t match" support ticket. Time-boxed wording so the note ' \
                  'ages gracefully.',
    'proposed' => 'Add a small text element stating the source snapshot age and that Sigma is live.',
    'risk' => 'low',
    'verdict_hint' => 'apply',
    'patch' => { 'op' => 'add_elements', 'page_id' => dash_pages.first&.dig('id'),
                 'elements' => [{ 'id' => 'el-phasee-freshness', 'kind' => 'text',
                                  'body' => fresh_note, 'verticalAlign' => 'center', 'overflow' => 'clip' }],
                 'layout' => [{ 'element_id' => 'el-phasee-freshness', 'grid_column' => '1 / 25', 'height' => 2 }] }
  }
end

# ---------------------------------------------------------------------------
# 3d. title corrections — the source dashboard's VISIBLE caption differs from
#     the element name the migration carried over (stale worksheet name).
#     Conservative: only when a caption and an element pair off unambiguously.
# ---------------------------------------------------------------------------
if WORKDIR
  captions = [] # [{caption, ref_name}]
  dl = jread(File.join(WORKDIR, 'dashboard-layout.json'))
  if dl
    zones = dl.is_a?(Array) ? dl.flat_map { |d| d['zones'] || [] } : (dl['zones'] || [])
    zones.select { |z| z['kind'] == 'chart' }.each do |z|
      cap = z['caption'].to_s.strip
      refn = (z['view_ref'] || z['view'] || z['name']).to_s.strip
      captions << { 'caption' => cap, 'ref' => refn } unless cap.empty? || refn.empty?
    end
  elsif signals
    (signals['pages'] || []).flat_map { |p| p['visuals'] || [] }.each do |v|
      cap = v['title'].to_s.strip
      captions << { 'caption' => cap, 'ref' => cap } unless cap.empty?
    end
  end
  el_names = viz.map(&:last).map { |e| e['name'].to_s }
  captions.each do |c|
    next if c['caption'].casecmp?(c['ref'])                       # caption == worksheet name: nothing stale
    next if el_names.any? { |n| norm(n) == norm(c['caption']) }   # an element already carries the caption
    target = viz.map(&:last).find { |e| norm(e['name']) == norm(c['ref']) }
    next unless target
    candidates << {
      'id' => "polish-title-#{target['id']}",
      'category' => 'fidelity-polish',
      'evidence' => "Source dashboard's visible title is '#{c['caption']}' but the migrated element is " \
                    "named '#{target['name']}' (stale internal worksheet/visual name).",
      'proposed' => "Rename element to '#{c['caption']}'.",
      'risk' => 'low',
      'verdict_hint' => 'apply',
      'patch' => { 'op' => 'rename_element', 'element_id' => target['id'], 'name' => c['caption'] }
    }
  end
end

# ---------------------------------------------------------------------------
# DESCOPED — trial-proven spec-unsupported. Emitted as propose-in-UI notes
# only; enhance-apply NEVER applies these.
# ---------------------------------------------------------------------------
if viz.any? { |(_p, e)| e['kind'] == 'pie-chart' }
  descoped << {
    'id' => 'descoped-pie-percent-labels',
    'note' => 'Pie/donut percent labels: dataLabel.valueFormat:"percent" is SILENTLY DROPPED on spec ' \
              'readback (trial-proven, same class as trellis/tooltip). Value labels persist; percent ' \
              'style must be set in the Sigma UI.',
    'evidence' => "#{viz.count { |(_p, e)| e['kind'] == 'pie-chart' }} pie-chart element(s) present."
  }
end
shared_masters = viz.group_by { |(_p, e)| e.dig('source', 'elementId') }.select { |_k, v| v.size >= 2 }
if shared_masters.any?
  descoped << {
    'id' => 'descoped-chart-as-filter',
    'note' => 'Chart-as-filter (cross-filter on click): useAsFilter/crossFilter spec fields are accepted ' \
              'by PUT but silently DROPPED on readback (trial-proven; UI-only). Enable "Use as filter" in ' \
              'the Sigma UI. List controls on the shared master already give equivalent dashboard-wide filtering.',
    'evidence' => "#{shared_masters.values.sum(&:size)} chart(s) share #{shared_masters.size} master source(s)."
  }
end

# ---------------------------------------------------------------------------
# App-shape signals + option rollup.
#
# The detector catalog above answers "which micro-patches are safe here". It
# does NOT answer the question a human actually has: "what should this app
# BE?". These two blocks roll the same evidence up into a handful of
# user-meaningful options so the agent can run a design interview instead of
# reading out fifteen individual patches. Purely additive — `candidates` and
# every existing key keep their shape, so older consumers are unaffected.
# ---------------------------------------------------------------------------
calc_blob = if WORKDIR
              [jread(File.join(WORKDIR, 'calc-fields.json')),
               jread(File.join(WORKDIR, 'dashboard-layout.json'))].compact
                                                                  .map(&:to_s)
                                                                  .join(' ')
            else
              ''
            end
# Profile both spec metadata and sampled exported values. Archetype detection
# needs structural evidence (field names, formulas, real dimension members),
# not just vocabulary in calc-fields.json.
all_elements = spec['elements'] || []
profile_fields = all_elements.flat_map do |el|
  (el['columns'] || []).flat_map { |c| [c['name'], c['formula']] }
end.compact.map(&:to_s)
profile_members = Hash.new { |h, k| h[k] = [] }
rows_by_el.each_value do |rows|
  Array(rows).first(250).each do |row|
    next unless row.is_a?(Hash)
    row.each do |field, value|
      profile_fields << field.to_s
      next if value.nil? || value.is_a?(Hash) || value.is_a?(Array)
      values = profile_members[field.to_s]
      values << value.to_s unless values.include?(value.to_s) || values.size >= 100
    end
  end
end
data_profile = {
  'field_names' => profile_fields.uniq,
  'member_values' => profile_members,
  'formula_text' => all_elements.flat_map do |el|
    (el['columns'] || []).map { |c| c['formula'] }
  end.compact.join(' ')
}
option_rollup = EnhanceOptions.build(
  candidates: candidates,
  shared_master_chart_count: shared_masters.values.sum(&:size),
  calc_blob: calc_blob,
  write_connection_available: !ENV['SIGMA_WRITE_CONNECTION_ID'].to_s.empty?,
  data_profile: data_profile
)
app_signals = option_rollup['signals']
app_options = option_rollup['app_options']

# ---------------------------------------------------------------------------
# Emit.
# ---------------------------------------------------------------------------
out = {
  'schemaVersion' => 1,
  'workbook_id' => WB,
  'workbook_name' => wb_name,
  'source' => source,
  'scanned_at' => Time.now.utc.iso8601,
  'elements_scanned' => viz.size,
  'elements_exported' => rows_by_el.count { |_k, v| v },
  'candidates' => candidates,
  'descoped_notes' => descoped,
  'signals' => app_signals,
  'app_options' => app_options
}
File.write(OUT, JSON.pretty_generate(out))

puts "enhance-scan: #{candidates.size} candidate(s), #{descoped.size} descoped note(s), " \
     "#{app_options.size} app option(s) -> #{OUT}"
puts '  app options (present these to the human before applying anything):'
app_options.each do |o|
  if o['archetype']
    puts format('  %-1s [%-6s/%2s] %-34s %s',
                o['recommended'] ? '*' : ' ', o['confidence'],
                o['score'], o['id'], o['label'].to_s)
  else
    puts format('  %-1s [%-6s] %-34s %s',
                o['recommended'] ? '*' : ' ', o['risk'], o['id'],
                o['label'].to_s)
  end
end
candidates.each do |c|
  puts format('  [%-6s] %-38s %s', c['risk'], c['id'], c['proposed'].to_s.gsub(/\s+/, ' ')[0, 100])
end
descoped.each { |d| puts format('  [note ] %-38s %s', d['id'], d['note'].to_s.gsub(/\s+/, ' ')[0, 100]) }
