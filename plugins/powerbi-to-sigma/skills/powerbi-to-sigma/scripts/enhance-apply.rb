#!/usr/bin/env ruby
# frozen_string_literal: true
#
# enhance-apply.rb — Phase E (opt-in) shared engine, part 2 of 2: APPLY.
#
# CLONE-FIRST, ACCEPT-ONLY, PARITY-GATED application of enhancements.json
# candidates produced by enhance-scan.rb:
#   1. CLONE: GET the parity-verified workbook's spec and POST it as
#      "<name> — Enhanced". The 1:1 parity artifact is NEVER written.
#   2. ACCEPT: only candidates named in --accept (id list) or matching
#      --accept all-low-risk are applied. Everything else is recorded as
#      skipped. Candidates whose patch carries unmet 'needs' (e.g. map
#      centroids) are skipped with the reason, never half-applied.
#   3. APPLY ONE AT A TIME with a parity-unchanged gate: after each item,
#      spot-query 2-3 UNTOUCHED elements on the clone AND the same elements
#      on the original simultaneously; any divergence (clone != original at
#      the same instant — live-drift-proof, the trial's lesson) auto-REVERTS
#      that item and flags it. enhance-report.json records
#      applied/skipped/reverted with evidence.
#
# This file is the SHARED Phase-E engine, vendored byte-identical into every
# covered plugin (md5 discipline — same as escalate-gap.py).
#
# Usage:
#   ruby scripts/enhance-apply.rb --workbook-id <parityWorkbookId> \
#     --enhancements <enhancements.json> \
#     --accept all-low-risk | --accept id1,id2,... \
#     [--name '<clone name>'] [--out enhance-report.json] [--probes N]
#
# Every applied item lands in the CONTAINER SYSTEM (see the layout-placement
# section): controls -> control band, KPIs -> KPI band, grain/drill switchers
# -> inside their chart's container, notes -> a slim band under the header.
# Pre-container clones get their layout regenerated as a banded layout first.
# The finalize runs the shared layout lint (lib/layout_lint.rb) and prints the
# hard screenshot checklist — the agent MUST export the full-page PNG and
# verify each item.
#
# Exit codes: 0 = done (clone created; accepted items applied or cleanly
# reverted; parity-unchanged gate green; layout lint clean); 2 = nothing
# accepted; 3 = the parity-unchanged gate could not be restored (clone left
# for inspection, report says so); 4 = layout or control lint violations on the clone
# (fix + re-PUT, then re-lint); other = error.

require 'json'
require 'yaml'
require 'time'
require 'date'
require 'optparse'

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'sigma_rest'
require 'code_rep'

opts = { probes: 3 }
OptionParser.new do |o|
  o.on('--workbook-id ID')   { |v| opts[:wb] = v }
  o.on('--enhancements P')   { |v| opts[:enh] = File.expand_path(v) }
  o.on('--accept LIST')      { |v| opts[:accept] = v }
  o.on('--name NAME')        { |v| opts[:name] = v }
  o.on('--out PATH')         { |v| opts[:out] = File.expand_path(v) }
  o.on('--probes N', Integer) { |v| opts[:probes] = v }
end.parse!
abort 'missing --workbook-id' unless opts[:wb]
abort 'missing --enhancements' unless opts[:enh] && File.exist?(opts[:enh])
abort 'missing --accept (id list or all-low-risk) — nothing applies without explicit acceptance' unless opts[:accept]

ORIG_WB = opts[:wb]
enh = JSON.parse(File.read(opts[:enh]))
OUT = opts[:out] || File.join(File.dirname(opts[:enh]), 'enhance-report.json')

candidates = enh['candidates'] || []
accepted_ids =
  if opts[:accept].strip.casecmp?('all-low-risk')
    candidates.select { |c| c['risk'].to_s == 'low' }.map { |c| c['id'] }
  else
    opts[:accept].split(',').map(&:strip).reject(&:empty?)
  end
unknown = accepted_ids - candidates.map { |c| c['id'] }
abort "FATAL: --accept names unknown candidate id(s): #{unknown.join(', ')}" if unknown.any?

accepted = candidates.select { |c| accepted_ids.include?(c['id']) }
skipped  = candidates.reject { |c| accepted_ids.include?(c['id']) }
                     .map { |c| { 'id' => c['id'], 'risk' => c['risk'], 'reason' => 'not accepted' } }
if accepted.empty?
  puts 'enhance-apply: no candidate accepted — nothing to do (no clone created).'
  File.write(OUT, JSON.pretty_generate(
    'workbook_id' => ORIG_WB, 'status' => 'nothing-accepted',
    'applied' => [], 'skipped' => skipped, 'reverted' => [],
    'descoped_notes' => enh['descoped_notes'] || []))
  exit 2
end

READONLY_KEYS = %w[workbookId url ownerId createdBy updatedBy createdAt updatedAt
                   documentVersion latestDocumentVersion].freeze

def clean(spec)
  s = JSON.parse(JSON.generate(spec))
  READONLY_KEYS.each { |k| s.delete(k) }
  s
end

# Workbook code-rep nests pages/elements/layout/schemaVersion/kind under a top-level
# `document` key (live since 2026-08-03/04). Every helper below this point
# (ensure_banded!, apply_patch!, find_element, etc.) was written against the
# pre-nesting working shape and freely mixes document fields (spec['pages'],
# spec['layout']) with metadata (spec['name']) on the SAME hash — so rather
# than threading two hashes through a dozen functions, flatten a live GET back
# onto one hash and keep that as the single working `current` spec throughout.
# Sigma::CodeRep.metadata/.document partition any hash with no risk of
# collision (metadata explicitly excludes the document keys), so this round-
# trips losslessly. Pair with wrap_spec below at every PUT boundary.
def flatten_spec(raw)
  Sigma::CodeRep.metadata(raw).merge(Sigma::CodeRep.document(raw))
end

# Inverse of flatten_spec — re-nest a flattened working spec for the wire.
def wrap_spec(flat)
  Sigma::CodeRep.wrap(Sigma::CodeRep.document(flat), extra: Sigma::CodeRep.metadata(flat))
end

# Sigma's workbook POST/PUT responses can come back as YAML — parse leniently.
def lenient(body)
  return body if body.is_a?(Hash)
  YAML.safe_load(body.to_s, permitted_classes: [Date, Time]) rescue nil
end

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

# Order-insensitive, float-tolerant normalization for row comparison.
def norm_rows(rows)
  return nil unless rows.is_a?(Array)
  rows.map do |r|
    r.transform_values { |v| v.is_a?(Numeric) ? v.to_f.round(4) : v }
  end.sort_by { |r| JSON.generate(r.sort.to_h) }
end

# ---------------------------------------------------------------------------
# Container-aware layout placement (phase-e layout-quality fix).
#
# The first Phase E shipped enhancements by APPENDING <Element>s at the
# bottom of the Page block — controls/KPIs/notes dumped below the fold, the
# grain switcher orphaned at the foot. Every applied item now lands in the
# container system instead:
#   - selection controls       -> the control band (created if absent)
#   - comparison KPIs          -> the KPI band (created if absent)
#   - grain/drill switcher     -> INSIDE its chart's own container (slim row
#                                 above the chart)
#   - migration/freshness note -> a slim note band directly under the header
# If the cloned parity workbook PREDATES container layouts (no <Container>
# in its layout), the clone's layout is REGENERATED as a banded layout first,
# using the builder's shared container machinery (lib/layout.rb).
#
# layout.rb is skill-local (not every converter vendors it yet). Lazy-load so
# spec-only patches (formula/rename/prop) still run where layout.rb is absent;
# banding/placement aborts with an explicit message when layout is required.
# ---------------------------------------------------------------------------
def ensure_layout!
  return if defined?(SigmaLayout)
  begin
    require 'layout'
  rescue LoadError => e
    abort 'enhance-apply: scripts/lib/layout.rb is required for Phase E layout ' \
          "banding/placement (#{e.message}). Add layout.rb (or vendor it) before " \
          'applying patches that touch layout; formula/rename/prop patches do not need it.'
  end
  return if defined?(SigmaLayout)
  abort 'enhance-apply: layout.rb loaded but SigmaLayout is undefined'
end

CTRL_BAND_PREFIX = 'phasee-ctrl-band'
KPI_BAND_PREFIX  = 'phasee-kpi-band'
NOTE_BAND_PREFIX = 'phasee-note-band'
# vertical order of phasee-created bands under the header (note = slimmest,
# closest to the header; KPIs above the charts read best below the controls)
BAND_PRIORITY = { NOTE_BAND_PREFIX => 0, CTRL_BAND_PREFIX => 1, KPI_BAND_PREFIX => 2 }.freeze
BAND_ROWS = { NOTE_BAND_PREFIX => 2, CTRL_BAND_PREFIX => 3, KPI_BAND_PREFIX => 6 }.freeze

def page_block(spec, page_id)
  return nil if page_id.nil?
  spec['layout'].to_s.match(%r{(<Page\b[^>]*\bid="#{Regexp.escape(page_id)}"[^>]*>)(.*?)(</Page>)}m)
end

def replace_page_inner!(spec, page_id, new_inner)
  m = page_block(spec, page_id) or return nil
  spec['layout'] = spec['layout'].to_s.sub(m[0]) { "#{m[1]}#{new_inner}#{m[3]}" }
  true
end

# Direct children of a page block: [{tag:, eid:, c0:, c1:, r0:, r1:, s:, e:,
# head_e:, inner: (containers only)}] — byte offsets into the inner string.
def scan_top(inner)
  out = []
  pos = 0
  while (m = inner.match(%r{<(Container|GridContainer|Element|LayoutElement)\b[^>]*?(/>|>)}m, pos))
    source_tag = m[1]
    tag = %w[Container GridContainer].include?(source_tag) ? 'Container' : 'Element'
    open_e = m.end(0)
    ent_end = open_e
    body = nil
    if tag == 'Container' && m[2] == '>'
      close = inner.match(%r{</#{source_tag}>}m, open_e)
      ent_end = close ? close.end(0) : open_e
      body = close ? inner[open_e...close.begin(0)] : ''
    end
    head = inner[m.begin(0)...open_e]
    out << { tag: tag, eid: head[/elementId="([^"]*)"/, 1],
             c0: head[/gridColumn="\s*(\d+)/, 1].to_i,
             c1: head[/gridColumn="\s*\d+\s*\/\s*(\d+)/, 1].to_i,
             r0: head[/gridRow="\s*(\d+)/, 1].to_i,
             r1: head[/gridRow="\s*\d+\s*\/\s*(\d+)/, 1].to_i,
             s: m.begin(0), e: ent_end, head_e: open_e, inner: body }
    pos = ent_end
  end
  out
end

# Place a flat document element at the end of a page's required layout. Used
# for hidden helper tables added during control-extension repair.
def place_at_page_end!(spec, page_id, element_id, rows: 10)
  ensure_layout!
  m = page_block(spec, page_id) or raise "no layout block for page #{page_id}"
  last_row = scan_top(m[2]).map { |entry| entry[:r1] }.max || 1
  entry = SigmaLayout.le(element_id, 1, 25, last_row, last_row + rows)
  replace_page_inner!(spec, page_id, "#{m[2]}\n#{entry}\n")
end

def set_rows(head, r0, r1)
  head.sub(/gridRow="[^"]*"/) { %(gridRow="#{r0} / #{r1}") }
end

# Shift every top-level entry starting at/after from_row down by delta rows.
def shift_top_rows(inner, from_row, delta)
  res = inner.dup
  scan_top(inner).reverse_each do |t|
    next unless t[:r0] >= from_row
    res[t[:s]...t[:head_e]] = set_rows(inner[t[:s]...t[:head_e]], t[:r0] + delta, t[:r1] + delta)
  end
  res
end

# Regenerate a banded layout for every dashboard page of a pre-container clone
# (flat <Element> list -> header band + row-band Containers via the
# builder's shared SigmaLayout machinery). No-op when containers exist.
def ensure_banded!(spec)
  return false if spec['layout'].to_s.match?(%r{<(?:Container|GridContainer)\b})
  ensure_layout!
  changed = false
  all_elements = Sigma::CodeRep.workbook_elements(spec)
  (spec['pages'] || []).each do |pg|
    next if pg['id'].to_s.downcase.include?('data')
    m = page_block(spec, pg['id']) or next
    page_ids = Sigma::CodeRep.workbook_page_element_ids(spec)[pg['id']] || []
    page_elements = all_elements.select { |e| page_ids.include?(e['id']) }
    kind_of = page_elements.to_h { |e| [e['id'], e['kind']] }
    items = scan_top(m[2]).select { |t| t[:tag] == 'Element' }
                          .map { |t| [t[:eid], t[:c0], t[:c1], t[:r0], t[:r1]] }
    next if items.empty?
    # an existing short top text element (the dashboard's own title) becomes
    # the header band's text (recolored white for the dark band); otherwise
    # SigmaLayout adds a header from the page name -> workbook name chain
    # (resolve_header_title — never a generic "Page 1" auto-name). The
    # candidate may start up to one row below the topmost element (classic
    # title boxes are nudged a few px down; exact-row equality was the
    # PHASEE2 fragility).
    top_row = items.map { |i| i[3] }.min
    own_hdr = items.find { |i| i[3] <= top_row + 1 && kind_of[i[0]] == 'text' && (i[4] - i[3]) <= 5 }
    if own_hdr && items.length > 1
      items -= [own_hdr]
      hdr_el = page_elements.find { |e| e['id'] == own_hdr[0] }
      if hdr_el && hdr_el['body'].is_a?(String) && !hdr_el['body'].include?('color:')
        plain = hdr_el['body'].gsub(/^#+\s*/, '').strip
        hdr_el['body'] = %(# <span style="color: #FFFFFF">#{plain}</span>)
      end
      xml, extra = SigmaLayout.banded_page(pg['id'], items, header_el: own_hdr[0],
                                           id_prefix: "band-#{pg['id']}")
    else
      hdr_title = SigmaLayout.resolve_header_title(pg['name'], spec['name']) || 'Dashboard'
      xml, extra = SigmaLayout.banded_page(pg['id'], items, title: hdr_title,
                                           id_prefix: "band-#{pg['id']}")
    end
    new_ids = all_elements.map { |e| e['id'] }
    spec['elements'] = all_elements + extra.reject { |e| new_ids.include?(e['id']) }
    all_elements = spec['elements']
    spec['layout'] = spec['layout'].to_s.sub(m[0]) { xml }
    changed = true
  end
  changed
end

# Row where a new phasee band of `prefix` should start on this page: under the
# header band (the row-1 container), below any already-created phasee band of
# lower priority.
def band_anchor_row(ents, prefix)
  hdr = ents.select { |t| t[:tag] == 'Container' }
            .find { |t| t[:r0] <= 1 }
  row = hdr ? hdr[:r1] : (ents.map { |t| t[:r0] }.min || 1)
  ents.each do |t|
    pfx = BAND_PRIORITY.keys.find { |p| t[:eid].to_s.start_with?(p) }
    row = [row, t[:r1]].max if pfx && BAND_PRIORITY[pfx] < BAND_PRIORITY[prefix]
  end
  row
end

# Find-or-create the phasee band container for `prefix` on the page; returns
# the band's container element id. Creates the spec-side `kind: container`
# placeholder and shifts everything below the insertion point down.
def ensure_band!(spec, page, prefix)
  m = page_block(spec, page['id']) or raise "no layout block for page #{page['id']}"
  ents = scan_top(m[2])
  existing = ents.find { |t| t[:eid].to_s.start_with?(prefix) }
  return existing[:eid] if existing
  ensure_layout!
  rows = BAND_ROWS[prefix]
  cid = "#{prefix}-#{page['id']}"[0, 60]
  anchor = band_anchor_row(ents, prefix)
  inner = shift_top_rows(m[2], anchor, rows)
  band = SigmaLayout.gc(cid, 1, 25, anchor, anchor + rows, '')
  replace_page_inner!(spec, page['id'], "#{inner}\n#{band}\n")
  spec['elements'] ||= []
  spec['elements'] << SigmaLayout.container_el(cid) unless spec['elements'].any? { |e| e['id'] == cid }
  cid
end

# Place an element INTO a band container, flowing left-to-right then wrapping
# to a new row (growing the band + shifting the bands below it).
def band_add!(spec, page_id, band_cid, element_id, grid_column, height)
  ensure_layout!
  m = page_block(spec, page_id) or raise "no layout block for page #{page_id}"
  ents = scan_top(m[2])
  band = ents.find { |t| t[:eid] == band_cid } or raise "band #{band_cid} not found"
  c0, c1 = grid_column.to_s.scan(/\d+/).map(&:to_i)
  c0 = 1 if c0.nil? || c0 < 1
  c1 = [c0 + 8, 25].min if c1.nil? || c1 <= c0
  width = c1 - c0
  band_rows = band[:r1] - band[:r0]
  h = [height || band_rows, band_rows].min
  h = band_rows if h <= 0
  kids = scan_top(band[:inner].to_s)
  if kids.empty?
    row = 1
    place_c0 = c0
  else
    cur = kids.map { |k| k[:r0] }.max
    cur_kids = kids.select { |k| k[:r0] == cur }
    max_c1 = cur_kids.map { |k| k[:c1] }.max
    if max_c1 + width <= 25
      row = cur
      place_c0 = max_c1
    else
      row = kids.map { |k| k[:r1] }.max
      place_c0 = c0
    end
  end
  grow = [row + h - 1 - band_rows, 0].max
  entry = SigmaLayout.le(element_id, place_c0, place_c0 + width, row, row + h)
  new_band_inner = "#{band[:inner]}\n#{entry}"
  new_band_head = set_rows(m[2][band[:s]...band[:head_e]], band[:r0], band[:r1] + grow)
  new_band = "#{new_band_head}#{new_band_inner}\n</Container>"
  inner = m[2].dup
  inner[band[:s]...band[:e]] = new_band
  inner = shift_below!(inner, band[:eid], band[:r1], grow) if grow.positive?
  replace_page_inner!(spec, page_id, inner)
end

# After growing a band, push every OTHER top-level entry that started at/after
# the band's old end row down by delta.
def shift_below!(inner, except_eid, from_row, delta)
  res = inner.dup
  scan_top(inner).reverse_each do |t|
    next if t[:eid] == except_eid || t[:r0] < from_row
    res[t[:s]...t[:head_e]] = set_rows(inner[t[:s]...t[:head_e]], t[:r0] + delta, t[:r1] + delta)
  end
  res
end

# Place a control INSIDE the container of the chart it drives: a slim row is
# opened at the top of that container (children shifted down), the container
# grows, and the bands below shift. Falls back to nil when the chart has no
# container (caller then uses the control band).
CHART_CTRL_ROWS = 2
def add_into_chart_container!(spec, page_id, chart_eid, ctrl_eid, grid_column)
  m = page_block(spec, page_id) or return nil
  ents = scan_top(m[2])
  host = ents.find { |t| t[:tag] == 'Container' && t[:inner].to_s.include?(%(elementId="#{chart_eid}")) }
  return nil unless host
  ensure_layout!
  c0, c1 = grid_column.to_s.scan(/\d+/).map(&:to_i)
  c0, c1 = 17, 25 if c0.nil? || c1.nil? || c1 <= c0
  kids_shifted = shift_top_rows(host[:inner].to_s, 1, CHART_CTRL_ROWS)
  entry = SigmaLayout.le(ctrl_eid, c0, c1, 1, 1 + CHART_CTRL_ROWS)
  new_head = set_rows(m[2][host[:s]...host[:head_e]], host[:r0], host[:r1] + CHART_CTRL_ROWS)
  new_host = "#{new_head}#{entry}\n#{kids_shifted}\n</Container>"
  inner = m[2].dup
  inner[host[:s]...host[:e]] = new_host
  inner = shift_below!(inner, host[:eid], host[:r1], CHART_CTRL_ROWS)
  replace_page_inner!(spec, page_id, inner)
  true
end

# Band routing per added element kind.
def place_added_element!(spec, page, el, hint)
  grid_column = hint && hint['grid_column']
  height = hint && hint['height']
  case el['kind']
  when 'control'
    band = ensure_band!(spec, page, CTRL_BAND_PREFIX)
    band_add!(spec, page['id'], band, el['id'], grid_column || '1 / 9', height || BAND_ROWS[CTRL_BAND_PREFIX])
  when 'kpi-chart'
    band = ensure_band!(spec, page, KPI_BAND_PREFIX)
    band_add!(spec, page['id'], band, el['id'], grid_column || '1 / 13', height || BAND_ROWS[KPI_BAND_PREFIX])
  when 'text'
    band = ensure_band!(spec, page, NOTE_BAND_PREFIX)
    band_add!(spec, page['id'], band, el['id'], grid_column || '1 / 25', height || BAND_ROWS[NOTE_BAND_PREFIX])
  else
    band = ensure_band!(spec, page, KPI_BAND_PREFIX)
    band_add!(spec, page['id'], band, el['id'], grid_column || '1 / 25', height || BAND_ROWS[KPI_BAND_PREFIX])
  end
end

def find_element(spec, element_id)
  el = Sigma::CodeRep.workbook_elements(spec).find { |e| e['id'] == element_id }
  return nil unless el
  [Sigma::CodeRep.workbook_page_by_element(spec)[element_id], el]
end

# ---------------------------------------------------------------------------
# Control-coverage extension (control-targeting fix, workstream C).
#
# add_elements can introduce charts/KPIs whose source chain NEVER reaches the
# elements the workbook's controls filter — audit-proven: enhancement KPIs
# added with a DM-direct source were dead to the dashboard's Region/State
# controls. After adding a viz element, every existing filtering control is
# EXTENDED to cover it:
#   - if the element's source chain already reaches one of the control's
#     targets, Sigma's downstream propagation covers it — nothing to do;
#   - else target the element's sourcing ROOT (the element itself when it is
#     its own root, e.g. DM-direct) on the column matching the control's
#     filter column by name — adding a hidden passthrough column when the
#     root sources the SAME data-model element as a targeted element (its
#     column formula is valid verbatim there);
#   - grain/drill switchers (add_control_and_rewire) are value providers wired
#     through formulas, not filter targets — deliberately EXEMPT.
# Every extension/exemption is merged into <workdir>/control-scope.enhanced.json
# (contract shape — see merged_control_scope!) and linted on the clone.
# ---------------------------------------------------------------------------
VIZ_EXTENDABLE = %w[bar-chart line-chart area-chart pie-chart donut-chart combo-chart
                    scatter-chart kpi-chart table pivot-table box-chart funnel-chart
                    waterfall-chart region-map point-map].freeze
$control_scope_notes = []

def spec_elements_by_id(spec)
  Sigma::CodeRep.workbook_elements(spec).to_h { |e| [e['id'], e] }
end

# Element ids on `el`'s source chain (excluding el itself); stops at a
# data-model source or an id not present in the spec.
def source_chain_ids(spec, el)
  by_id = spec_elements_by_id(spec)
  ids = []
  cur = el
  loop do
    src = cur['source'] || {}
    break if src['kind'] == 'data-model' || src['elementId'].nil?
    nid = src['elementId']
    break if ids.include?(nid)
    ids << nid
    cur = by_id[nid] or break
  end
  ids
end

def norm_colname(s)
  s.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '')
end

# Control filter targets may only point at TABLE elements — a chart/KPI
# target 400s at PUT with "Dependency not found" (live-verified here AND in
# the looker builder, which re-sources tiles through hidden scope tables for
# the same reason). So a DM-direct added viz is covered via the estate
# repair's hidden SHARED-BASE-TABLE pattern: a hidden table on the Data page
# sourcing the same DM element, the added viz re-sourced through it (formula
# prefixes rewritten), and the control targeting the table.
def ensure_base_table!(spec, el, dm_src, cand_id)
  base_name = "#{el['name'] || el['id']} Base (#{cand_id})"
  base = { 'id' => "phasee-base-#{el['id']}".gsub(/[^A-Za-z0-9_-]+/, '-')[0, 60],
           'kind' => 'table', 'name' => base_name,
           'source' => JSON.parse(JSON.generate(dm_src)), 'columns' => [] }
  # Pass through every DM column the viz references, then rewrite the viz's
  # refs ([<DM element name>/<col>] -> [<base name>/<col>]) and re-source it.
  refs = (el['columns'] || []).flat_map { |c| c['formula'].to_s.scan(%r{\[([^\]\[/]+)/([^\]]+)\]}) }.uniq
  seen = {}
  refs.each do |prefix, colname|
    next if seen[colname]
    seen[colname] = true
    base['columns'] << { 'id' => "#{base['id']}-c#{base['columns'].size}",
                         'name' => colname, 'formula' => "[#{prefix}/#{colname}]" }
  end
  (el['columns'] || []).each do |c|
    next unless c['formula'].is_a?(String)
    c['formula'] = c['formula'].gsub(%r{\[[^\]\[/]+/([^\]]+)\]}) { "[#{base_name}/#{Regexp.last_match(1)}]" }
  end
  el['source'] = { 'kind' => 'table', 'elementId' => base['id'] }
  # The base lives on the Data page (same convention as the master and the
  # looker scope tables); page order puts it before every dashboard page, so
  # control filter targets resolve in Sigma's array-order dependency walk.
  master_page = Sigma::CodeRep.workbook_page_by_element(spec)['master']
  data_page = (spec['pages'] || []).find { |p| p['id'] == master_page&.dig('id') } ||
              (spec['pages'] || []).find { |p| p['id'].to_s.downcase.include?('data') } ||
              (spec['pages'] || []).first
  raise 'cannot place hidden enhancement base: workbook has no page metadata' unless data_page
  (spec['elements'] ||= []) << base
  place_at_page_end!(spec, data_page['id'], base['id'])
  base
end

def extend_controls_for_added!(spec, added_els, cand_id)
  by_id = spec_elements_by_id(spec)
  ctrls = by_id.values.select { |e| e['kind'] == 'control' && Array(e['filters']).any? }
  notes = []
  added_els.each do |el|
    next unless VIZ_EXTENDABLE.include?(el['kind'])
    chain = source_chain_ids(spec, el)
    root = chain.empty? ? el : (by_id[chain.last] || el)
    root_src = root['source'] || {}
    base = nil # lazily-built hidden shared base table (one per added viz)
    ctrls.each do |ctl|
      next if Array(ctl['filters']).any? do |f|
        tid = f.dig('source', 'elementId')
        tid == el['id'] || chain.include?(tid) # propagation already covers it
      end
      # Resolve the control's filter column (name + formula) from its first target.
      tgt = ctl['filters'].first
      tgt_el = by_id[tgt.dig('source', 'elementId')]
      tgt_col = tgt_el && (tgt_el['columns'] || []).find { |c| c['id'] == tgt['columnId'] }
      unless tgt_col
        notes << { 'controlId' => ctl['controlId'], 'candidate' => cand_id,
                   'element' => el['id'], 'status' => 'not-extended',
                   'reason' => 'control target column not resolvable from the spec' }
        next
      end
      same_dm = root_src['kind'] == 'data-model' &&
                (tgt_el['source'] || {})['kind'] == 'data-model' &&
                (tgt_el['source'] || {})['elementId'] == root_src['elementId']
      col = nil
      target_id = nil
      if root['kind'] == 'table' && root['id'] != el['id']
        # Root is already a table (hidden helper) — target it directly, adding
        # a passthrough filter column when it shares the control's DM element.
        col = (root['columns'] || []).find { |c| norm_colname(c['name']) == norm_colname(tgt_col['name']) }
        if col.nil? && same_dm
          col = { 'id' => "phasee-ctlext-#{ctl['controlId']}-#{root['id']}".gsub(/[^A-Za-z0-9_-]+/, '-')[0, 60],
                  'name' => tgt_col['name'], 'formula' => tgt_col['formula'], 'hidden' => true }
          (root['columns'] ||= []) << col
        end
        target_id = root['id']
      elsif same_dm
        # DM-direct viz: re-root it through the hidden shared base table and
        # target that (chart/KPI elements cannot be filter targets).
        base ||= ensure_base_table!(spec, el, root_src, cand_id)
        col = base['columns'].find { |c| norm_colname(c['name']) == norm_colname(tgt_col['name']) }
        unless col
          col = { 'id' => "#{base['id']}-f#{base['columns'].size}",
                  'name' => tgt_col['name'], 'formula' => tgt_col['formula'], 'hidden' => true }
          base['columns'] << col
        end
        target_id = base['id']
      end
      if col
        ctl['filters'] << { 'source' => { 'kind' => 'table', 'elementId' => target_id },
                            'columnId' => col['id'] }
        notes << { 'controlId' => ctl['controlId'], 'candidate' => cand_id,
                   'element' => el['id'], 'element_name' => el['name'],
                   'status' => 'extended', 'target_root' => target_id,
                   'via_column' => tgt_col['name'] }
      else
        notes << { 'controlId' => ctl['controlId'], 'candidate' => cand_id,
                   'element' => el['id'], 'element_name' => el['name'],
                   'status' => 'not-extended',
                   'reason' => "sourcing root '#{root['id']}' has no '#{tgt_col['name']}' column " \
                               'and is not the same data-model element as the control target — wire manually' }
      end
    end
  end
  notes
end

# Merge the enhancement's control-scope notes into the builder's sidecar
# contract (lib/control_lint.rb CONTRACT shape) and write the result as
# control-scope.enhanced.json — a SEPARATE file because the workdir's
# control-scope.json must keep describing the ORIGINAL workbook (its gate-7
# re-runs would otherwise trip over mustReach entries naming elements that
# only exist on the clone). Returns the merged contract Hash so the finalize
# can run the control lint on the live clone spec against it.
#   extended -> the covering control gains a mustReach hard assertion (and an
#               allowlist slot when its scope is a narrow array)
#   exempt   -> grain/drill switchers added by add_control_and_rewire get a
#               scope:[rewired element] allowlist entry (formula-wired value
#               providers — deliberately NOT filter-extended)
#   not-extended -> recorded under enhancement_notes only; a page-scoped
#               control stays honestly PARTIAL in the lint
def merged_control_scope!(notes)
  base = File.join(File.dirname(OUT), 'control-scope.json')
  scope = File.exist?(base) ? (JSON.parse(File.read(base)) rescue nil) : nil
  scope = { 'version' => 1, 'source' => 'enhance-apply', 'sourceFilterSignals' => 0 } unless scope.is_a?(Hash)
  scope['controls'] ||= []
  notes.each do |n|
    case n['status']
    when 'extended'
      entry = scope['controls'].find { |c| c['controlId'] == n['controlId'] }
      unless entry
        entry = { 'controlId' => n['controlId'], 'scope' => 'page',
                  'sourceName' => 'existing workbook control (extended by phase-e add_elements)' }
        scope['controls'] << entry
      end
      (entry['mustReach'] ||= []) << n['element'] unless Array(entry['mustReach']).include?(n['element'])
      entry['scope'] << n['element'] if entry['scope'].is_a?(Array) && !entry['scope'].include?(n['element'])
    when 'exempt'
      next if scope['controls'].any? { |c| c['controlId'] == n['controlId'] }
      scope['controls'] << {
        'controlId' => n['controlId'], 'mechanism' => 'formula',
        'sourceName' => "phase-e #{n['candidate']} grain/drill switcher (formula-wired value provider)",
        'scope' => [n['element']].compact
      }
    end
    (scope['enhancement_notes'] ||= []) << n
  end
  File.write(File.join(File.dirname(OUT), 'control-scope.enhanced.json'),
             JSON.pretty_generate(scope))
  scope
end

# Apply one candidate's patch to a working spec (in place). Returns a
# human-readable description, or raises with the reason it cannot apply.
def apply_patch!(spec, cand)
  patch = cand['patch']
  raise 'candidate has no machine patch (propose-in-UI only)' unless patch.is_a?(Hash)
  if patch['needs'] && (patch[patch['needs']].nil? || patch[patch['needs']].empty?)
    raise "patch needs '#{patch['needs']}' filled in before apply (see candidate.proposed)"
  end
  case patch['op']
  when 'add_elements'
    page = (spec['pages'] || []).find { |p| p['id'] == patch['page_id'] } ||
           (spec['pages'] || []).reject { |p| p['id'] == 'page-data' }.first
    raise 'target page not found' unless page
    hints = Array(patch['layout']).to_h { |l| [l['element_id'], l] }
    Array(patch['elements']).each do |el|
      raise "element id #{el['id']} already exists" if find_element(spec, el['id'])
      (spec['elements'] ||= []) << el
      place_added_element!(spec, page, el, hints[el['id']])
    end
    # Extend existing controls to cover the added charts/KPIs (or their
    # sourcing root) — an enhancement must never ship outside the dashboard's
    # filter closure (see extend_controls_for_added!).
    ext_notes = extend_controls_for_added!(spec, Array(patch['elements']), cand['id'])
    $control_scope_notes.concat(ext_notes)
    ext = ext_notes.count { |n| n['status'] == 'extended' }
    missed = ext_notes.count { |n| n['status'] == 'not-extended' }
    warn "   [#{cand['id']}] control extension: #{missed} added element/control pair(s) NOT coverable — see control-scope.json" if missed.positive?
    if ext.positive?
      # Sigma resolves spec dependencies in ARRAY ORDER: a control whose
      # `filters` target an element appended LATER in document.elements 400s at PUT with
      # "Dependency not found" (live-verified; same rule the looker builder
      # honors by emitting tiles before controls). Stable-move controls to the
      # end of the flat document collection so every extended target precedes
      # its control. Formula
      # references ([controlId] in a chart calc) do NOT need array order —
      # the grain-switcher control already PUTs fine after its chart.
      spec['elements'] = spec['elements'].reject { |e| e['kind'] == 'control' } +
                         spec['elements'].select { |e| e['kind'] == 'control' }
    end
    "added #{Array(patch['elements']).size} element(s) into page #{page['id']}'s bands" \
      "#{ext.positive? ? " + extended #{ext} control target(s)" : ''}"
  when 'set_column_formula'
    _pg, el = find_element(spec, patch['element_id'])
    raise "element #{patch['element_id']} not found" unless el
    col = (el['columns'] || []).find { |c| c['id'] == patch['column_id'] }
    raise "column #{patch['column_id']} not found on #{patch['element_id']}" unless col
    col['formula'] = patch['formula']
    "set #{patch['element_id']}/#{patch['column_id']} formula"
  when 'rename_element'
    _pg, el = find_element(spec, patch['element_id'])
    raise "element #{patch['element_id']} not found" unless el
    el['name'] = patch['name']
    "renamed #{patch['element_id']} -> '#{patch['name']}'"
  when 'add_control_and_rewire'
    pg, el = find_element(spec, patch.dig('rewire', 'element_id'))
    raise "element #{patch.dig('rewire', 'element_id')} not found" unless el
    col = (el['columns'] || []).find { |c| c['id'] == patch.dig('rewire', 'column_id') }
    raise 'rewire column not found' unless col
    ctrl = patch['control']
    raise "control id #{ctrl['id']} already exists" if find_element(spec, ctrl['id'])
    (spec['elements'] ||= []) << ctrl
    col['formula'] = patch.dig('rewire', 'formula')
    # the switcher lives WITH the chart it drives: a slim row inside that
    # chart's container (falls back to the control band when uncontainered).
    hint = Array(patch['layout']).find { |l| l['element_id'] == ctrl['id'] } || {}
    placed = add_into_chart_container!(spec, pg['id'], el['id'], ctrl['id'], hint['grid_column'])
    unless placed
      band = ensure_band!(spec, pg, CTRL_BAND_PREFIX)
      band_add!(spec, pg['id'], band, ctrl['id'], hint['grid_column'] || '17 / 25', hint['height'] || 3)
    end
    # Grain/drill switchers are value providers wired through the chart's
    # FORMULA, not filter targets — deliberately exempt from control-coverage
    # extension; record the exemption so the lint allowlists it.
    $control_scope_notes << {
      'controlId' => ctrl['controlId'], 'candidate' => cand['id'],
      'status' => 'exempt', 'mechanism' => 'formula',
      'element' => el['id'], 'element_name' => el['name'],
      'reason' => 'grain/drill switcher — value provider wired through the chart formula, ' \
                  'not a filter target (deliberately exempt from control extension)'
    }
    "added control #{ctrl['controlId']} #{placed ? "inside #{el['id']}'s container" : 'to the control band'} + rewired #{el['id']}"
  when 'set_element_prop'
    _pg, el = find_element(spec, patch['element_id'])
    raise "element #{patch['element_id']} not found" unless el
    el[patch['prop']] = patch['value']
    "set #{patch['element_id']}.#{patch['prop']}"
  when 'replace_with_point_map'
    pg, el = find_element(spec, patch['element_id'])
    raise "element #{patch['element_id']} not found" unless el
    geo = patch['geo_column']
    cents = patch['centroids'] || {}
    raise 'centroids empty' if cents.empty?
    sw = lambda do |idx, default|
      args = cents.flat_map { |val, ll| ["\"#{val}\"", ll[idx].to_s] }.join(', ')
      "Switch([#{geo}], #{args}, #{default})"
    end
    geo_ref = patch['geo_ref'] ||
              (el['columns'] || []).map { |c| c['formula'] }.find { |f| f.to_s =~ /\/#{Regexp.escape(geo)}\]\z/ }
    raise 'cannot resolve a geo column reference' unless geo_ref
    map_el = {
      'id' => "map-phasee-#{el['id']}"[0, 40], 'kind' => 'point-map',
      'source' => el['source'],
      'columns' => [
        { 'id' => 'map-phasee-geo', 'formula' => geo_ref, 'name' => geo },
        { 'id' => 'map-phasee-lat', 'formula' => sw.call(0, '39'), 'name' => 'Lat' },
        { 'id' => 'map-phasee-lng', 'formula' => sw.call(1, '-98'), 'name' => 'Long' },
        { 'id' => 'map-phasee-val', 'formula' => patch['value_formula'],
          'name' => patch['value_name'] || 'Value' }
      ],
      'latitude' => { 'columnId' => 'map-phasee-lat' }, 'longitude' => { 'columnId' => 'map-phasee-lng' },
      'size' => { 'columnId' => 'map-phasee-val' },
      'color' => { 'by' => 'category', 'column' => 'map-phasee-geo' },
      'name' => "#{el['name']} (map restored)"
    }
    element_index = spec['elements'].index(el)
    raise "element #{el['id']} missing from flat document collection" unless element_index
    spec['elements'][element_index] = map_el
    spec['layout'] = spec['layout'].to_s.gsub(/elementId="#{Regexp.escape(el['id'])}"/,
                                              %(elementId="#{map_el['id']}"))
    "replaced #{el['id']} with point-map #{map_el['id']}"
  else
    raise "unknown patch op #{patch['op'].inspect}"
  end
end

# Element ids a candidate touches (so probes only use UNTOUCHED elements).
def touched_ids(cand)
  p = cand['patch'] || {}
  ids = [p['element_id'], p.dig('rewire', 'element_id')]
  ids += Array(p['elements']).map { |e| e['id'] }
  ids += [p['control'] && p['control']['id']]
  ids.compact.uniq
end

# ---------------------------------------------------------------------------
# 1. CLONE — the 1:1 parity artifact is never touched.
# ---------------------------------------------------------------------------
orig_meta_before = Sigma.request(:get, "/v2/workbooks/#{ORIG_WB}")
orig_spec = Sigma.request(:get, "/v2/workbooks/#{ORIG_WB}/spec")
# Keep the raw GET for metadata/document partitioning. The clone POST passes
# through wrap_spec so legacy layout aliases can never be re-emitted.
orig_doc = Sigma::CodeRep.document(orig_spec)
abort "FATAL: cannot read complete spec of #{ORIG_WB}" unless orig_spec.is_a?(Hash) &&
                                                           orig_doc['pages'].is_a?(Array) &&
                                                           orig_doc['elements'].is_a?(Array) &&
                                                           !orig_doc['layout'].to_s.empty?
clone_name = opts[:name] || "#{orig_spec['name']} — Enhanced"

clone_spec = flatten_spec(clean(orig_spec))
clone_spec['name'] = clone_name
post = lenient(Sigma.request(:post, '/v2/workbooks/spec',
                             body: JSON.generate(wrap_spec(clone_spec)), binary: true))
clone_id = post.is_a?(Hash) && (post['workbookId'] || post['id'])
abort "FATAL: clone POST returned no workbookId: #{post.inspect[0, 300]}" unless clone_id
puts "enhance-apply: clone '#{clone_name}' = #{clone_id} (original #{ORIG_WB} untouched)"

# ---------------------------------------------------------------------------
# 2. Pick probe elements (untouched by ANY accepted item) + baseline check.
# ---------------------------------------------------------------------------
all_touched = accepted.flat_map { |c| touched_ids(c) }
viz_kinds = %w[bar-chart line-chart area-chart pie-chart combo-chart scatter-chart kpi-chart table pivot-table]
probe_pool = Sigma::CodeRep.workbook_elements_with_pages(orig_doc)
                           .select { |_e, page| page && page['id'] != 'page-data' }
                           .map(&:first)
                           .select { |e| viz_kinds.include?(e['kind']) }
                           .reject { |e| all_touched.include?(e['id']) }
probes = probe_pool.first(opts[:probes]).map { |e| e['id'] }
abort 'FATAL: no untouched element available as a parity probe' if probes.empty?
puts "   parity probes (untouched elements): #{probes.join(', ')}"

# clone-vs-original at (near) the same instant: live-drift-proof comparison.
def probe_pair(clone_id, orig_id, probes)
  probes.to_h do |el|
    [el, { 'clone' => norm_rows(export_rows(clone_id, el)),
           'orig' => norm_rows(export_rows(orig_id, el)) }]
  end
end

def probe_diffs(pair)
  pair.reject { |_el, v| v['clone'] && v['orig'] && v['clone'] == v['orig'] }.keys
end

baseline = probe_pair(clone_id, ORIG_WB, probes)
bad = probe_diffs(baseline)
abort "FATAL: clone baseline already diverges from original on #{bad.join(', ')} — aborting before any change" if bad.any?
puts "   baseline: clone == original on #{probes.size}/#{probes.size} probe(s)"

# ---------------------------------------------------------------------------
# 3. Apply accepted items ONE AT A TIME with the parity-unchanged gate.
# ---------------------------------------------------------------------------
# `spec` here is the FLATTENED working document (flatten_spec below) — wrap
# it back into the live nested shape right at the wire boundary so every
# helper upstream (ensure_banded!, apply_patch!, find_element, ...) keeps
# reading/writing metadata-only pages, flat elements, layout, and name on one
# working hash.
def put_spec(wb, spec)
  lenient(Sigma.request(:put, "/v2/workbooks/#{wb}/spec",
                        body: JSON.generate(wrap_spec(spec)), binary: true))
end

current = flatten_spec(clean(Sigma.request(:get, "/v2/workbooks/#{clone_id}/spec")))

# Pre-container clone? (parity workbook built before banded layouts existed.)
# Regenerate a banded layout FIRST so every applied item has a container
# system to land in. Layout-only change — element data untouched, so the
# parity probes are unaffected by construction.
if ensure_banded!(current)
  put_spec(clone_id, current)
  current = flatten_spec(clean(Sigma.request(:get, "/v2/workbooks/#{clone_id}/spec")))
  puts '   clone layout predates containers — regenerated banded layout (header + row bands)'
end

applied = []
reverted = []
gate_green = true

accepted.each do |cand|
  print "   [#{cand['id']}] "
  prev = JSON.parse(JSON.generate(current))
  notes_mark = $control_scope_notes.length # discard this item's scope notes on skip/revert
  begin
    desc = apply_patch!(current, cand)
  rescue StandardError => e
    skipped << { 'id' => cand['id'], 'risk' => cand['risk'], 'reason' => "not applied: #{e.message}" }
    current = prev
    $control_scope_notes.slice!(notes_mark..)
    puts "SKIP (#{e.message})"
    next
  end
  begin
    put_spec(clone_id, current)
  rescue StandardError => e
    current = prev
    (put_spec(clone_id, current) rescue nil) # restore server state if the PUT half-landed
    $control_scope_notes.slice!(notes_mark..)
    reverted << { 'id' => cand['id'], 'reason' => "PUT rejected: #{e.message.to_s.gsub(/\s+/, ' ')[0, 200]}" }
    puts 'REVERTED (PUT rejected)'
    next
  end
  # parity-unchanged gate: untouched probes, clone vs original, same instant.
  pair = probe_pair(clone_id, ORIG_WB, probes)
  diffs = probe_diffs(pair)
  if diffs.any?
    current = prev
    $control_scope_notes.slice!(notes_mark..)
    begin
      put_spec(clone_id, current)
      recheck = probe_diffs(probe_pair(clone_id, ORIG_WB, probes))
      gate_green &&= recheck.empty?
    rescue StandardError
      gate_green = false
    end
    reverted << { 'id' => cand['id'],
                  'reason' => "parity-unchanged gate: untouched element(s) #{diffs.join(', ')} shifted vs original" }
    puts "REVERTED (probes shifted: #{diffs.join(', ')})"
  else
    applied << { 'id' => cand['id'], 'category' => cand['category'], 'change' => desc,
                 'evidence' => cand['evidence'] }
    puts "APPLIED (#{desc}; #{probes.size} probe(s) unchanged)"
  end
end

# ---------------------------------------------------------------------------
# 4. Finalize: layout lint (hard) + re-read the live layout + final report.
# ---------------------------------------------------------------------------
# Layout-quality lint (shared lib/layout_lint.rb, vendored byte-identical):
# raw-id display names / controls outside containers / dead zones. The clone
# must lint CLEAN — a parity-green visual mess is exactly the regression this
# phase exists to prevent.
require 'layout_lint'
# layout_lint/control_lint keep their existing contract ("give me a plain
# document") — unwrap/flatten at this caller rather than teaching the libs
# about the document wrapper (they're also fed local pre-POST specs
# elsewhere, which never carry one).
live_spec = flatten_spec(clean(Sigma.request(:get, "/v2/workbooks/#{clone_id}/spec")))
lint_violations = LayoutLint.lint(live_spec)
if lint_violations.any?
  warn "enhance-apply FINALIZE FAIL — layout lint: #{lint_violations.size} violation(s) on the clone:"
  lint_violations.each { |v| warn "  - #{v}" }
end

# Control-wiring lint on the CLONE (gate-7 grade — the pipeline's gate 7 ran
# on the ORIGINAL before Phase E; the clone now carries extended/added
# controls and added elements, so it gets its own lint against the merged
# contract). Applied items only — reverts were truncated from the notes.
merged_scope = merged_control_scope!($control_scope_notes)
require 'control_lint'
control_violations = ControlLint.lint(live_spec, scope: merged_scope)
if control_violations.any?
  warn "enhance-apply FINALIZE FAIL — control lint: #{control_violations.size} violation(s) on the clone:"
  control_violations.each { |v| warn "  - #{v}" }
end

final_pair = probe_pair(clone_id, ORIG_WB, probes)
final_ok = probe_diffs(final_pair).empty?
gate_green &&= final_ok
orig_meta_after = Sigma.request(:get, "/v2/workbooks/#{ORIG_WB}")
orig_untouched = orig_meta_before['updatedAt'] == orig_meta_after['updatedAt']

report = {
  'workbook_id' => ORIG_WB,
  'workbook_name' => orig_spec['name'],
  'clone_id' => clone_id,
  'clone_name' => clone_name,
  'clone_url' => (lenient(post) || {})['url'],
  'accepted' => accepted_ids,
  'applied' => applied,
  'skipped' => skipped,
  'reverted' => reverted,
  'control_scope_notes' => $control_scope_notes,
  'descoped_notes' => enh['descoped_notes'] || [],
  'parity_unchanged_gate' => {
    'probe_elements' => probes,
    'method' => 'clone-vs-original simultaneous JSON exports (live-drift-proof), after every item',
    'green' => gate_green
  },
  'layout_lint' => {
    'violations' => lint_violations,
    'green' => lint_violations.empty?
  },
  'control_lint' => {
    'violations' => control_violations,
    'scope_sidecar' => File.join(File.dirname(OUT), 'control-scope.enhanced.json'),
    'green' => control_violations.empty?
  },
  'original_untouched' => {
    'updatedAt_before' => orig_meta_before['updatedAt'],
    'updatedAt_after' => orig_meta_after['updatedAt'],
    'unchanged' => orig_untouched
  },
  'finished_at' => Time.now.utc.iso8601
}
File.write(OUT, JSON.pretty_generate(report))

puts
puts "enhance-apply: #{applied.size} applied, #{skipped.size} skipped, #{reverted.size} reverted"
puts "   clone: '#{clone_name}' (#{clone_id})"
puts "   parity-unchanged gate: #{gate_green ? 'GREEN' : 'NOT GREEN (see report)'}; original untouched: #{orig_untouched}"
puts "   layout lint: #{lint_violations.empty? ? 'CLEAN' : "#{lint_violations.size} violation(s) — FIX BEFORE DECLARING DONE"}"
puts "   control lint: #{control_violations.empty? ? 'CLEAN' : "#{control_violations.size} violation(s) — FIX BEFORE DECLARING DONE"}"
puts "   report -> #{OUT}"
puts
puts '──────────────── HARD SCREENSHOT CHECKLIST (Phase E finalize) ────────────────'
puts 'The lint is mechanical; YOUR EYES are the last gate. Export the FULL-PAGE PNG'
puts "of the clone (scripts/sigma-export-png.py --workbook #{clone_id}) and verify"
puts 'EVERY item — list each with pass/fail in your report:'
puts '  [ ] every chart/control title is human-readable (no raw element ids)'
puts '  [ ] the page has a header band (dark, full-width, page title)'
puts '  [ ] selection controls sit together in a control band near the top'
puts '  [ ] every control is adjacent to / inside the container of what it filters'
puts '      (grain/drill switchers INSIDE their chart\'s container)'
puts '  [ ] no orphan elements below the fold (nothing dumped at the page foot)'
puts '  [ ] no dead zones; row heights look even across each band'
puts '──────────────────────────────────────────────────────────────────────────────'
exit((lint_violations.any? || control_violations.any?) ? 4 : (gate_green ? 0 : 3))
