#!/usr/bin/env ruby
# Build a Sigma layout XML that mirrors a Tableau dashboard's zone grid for
# dashboard-fidelity conversion mode (Phase 0b).
#
# Output: a layout XML with two pages —
#   1. <Page id="page-data">: hidden master element spanning the page
#   2. <Page id="<overview-page-id>">: title + N controls + N chart tiles
#      positioned at grid cells derived from each Tableau zone's x/y/w/h%.
#
# Crucially: walks each chart row left-to-right and STRETCHES each chart's
# right edge to meet the next chart's left edge so there are no empty columns
# between adjacent tiles (Tableau dashboards often have separate legend/filter
# zones between two tiles that Sigma doesn't render; without this step, those
# gaps stay visible).
#
# Usage:
#   ruby scripts/build-dashboard-layout.rb \
#     --layout /tmp/<name>/dashboard-layout.json \
#     --wb-ids /tmp/<name>/wb-ids.json \
#     --out /tmp/<name>/layout.xml
#
# Optional:
#   --page-cols N    Sigma grid columns (default 24)
#   --page-rows N    visible rows BEFORE row scaling (default 32)
#   --row-scale F    multiply the chart band's row count (default 1.5).
#                    Tableau zone h% mapped 1:1 onto a 32-row Sigma page makes
#                    tiles too short — Sigma suppresses axis labels / pie slice
#                    labels below ~5-6 grid rows (bead tkkv; the looker builder
#                    uses ROW_SCALE=2, tableau E2E found 1.43× sufficient —
#                    default 1.5 preserves proportions while clearing the
#                    label-suppression threshold). Pass --row-scale 1 to get
#                    the old un-scaled mapping.
#   --rename PAIR    "Tableau name=Sigma name" (repeatable) — same flag as the
#                    parity scripts. A chart tile renamed during conversion
#                    otherwise fails the zone→element name match and silently
#                    drops out of the layout (bead ddbq).
#                    PERSISTED (#422): every --rename is merged into
#                    <workdir>/layout-renames.json (beside --layout) and every
#                    later invocation — orchestrator re-entry included — loads
#                    and applies it automatically, so the operator never re-types
#                    the mappings after a re-entry rebuild. CLI flags win over
#                    the persisted file on conflict.
#   --no-synthetic-title  never fabricate the page-name header band (the
#                    synthetic title banner). Also AUTO-suppressed when a prior
#                    layout.xml at --out carries no header band — i.e. the
#                    operator removed the banner; a re-entry rebuild must
#                    respect that last state instead of re-injecting it (#422).
#   --chart-y0 PCT   top of the chart band as Tableau %  (default 29.7)
#   --chart-y1 PCT   bottom of the chart band as Tableau % (default 100.0)
#   --chart-row0 N   first grid row of the chart band     (default 6)

require 'json'
require 'optparse'
require_relative 'lib/layout'
require_relative 'lib/zone_census'
require_relative 'lib/arrangement_lint'
require_relative 'lib/workbook_code'
require_relative 'lib/workbook_ir'
include SigmaLayout

# ---- Source-derived header chrome -----------------------------------------
# The skill used to stamp a fixed dark-navy header band on EVERY dashboard,
# which makes a minimalist white source (title text on the canvas) come out
# looking nothing like itself. Instead, only emit a COLORED header band when
# the source actually has a band-like fill in the header region; otherwise the
# title sits on the page canvas (transparent container), matching the source.
#
# "Band-like" = a fill that reads as a deliberate header strip: dark (low
# luminance, needs light text) OR saturated (a brand colour). Light-neutral
# fills (white/near-white/grey card backgrounds) are NOT bands — they blend
# into the canvas, so we emit no band. A full-page background (h≈100%) is the
# canvas, not a header, so it's excluded by the height/width gate.
def band_like_fill?(hex)
  return false unless hex.is_a?(String) && hex =~ /\A#[0-9a-fA-F]{6}/
  h = hex[1, 6]
  r, g, b = h[0, 2].to_i(16), h[2, 2].to_i(16), h[4, 2].to_i(16)
  luminance = 0.299 * r + 0.587 * g + 0.114 * b
  chroma = [r, g, b].max - [r, g, b].min
  luminance < 200 || chroma >= 40
end

# Returns the header container style hash derived from the source dashboard, or
# nil when the source has no colored header band (→ transparent, title on the
# canvas). Also returns whether the band is dark (so the title text needs a
# light colour on the page-name fallback).
def header_from_source(dashboard)
  fill = nil
  walk = lambda do |nodes|
    (nodes || []).each do |n|
      y = (n['y_pct'] || 0).to_f
      w = (n['w_pct'] || 0).to_f
      hpct = (n['h_pct'] || 0).to_f
      fc = n['fill_color']
      # header region: near the top, spans most of the width, but is a strip
      # (not the full-page canvas background).
      if fill.nil? && y < 18 && w >= 50 && hpct < 25 && band_like_fill?(fc)
        fill = fc[0, 7]
      end
      walk.call(n['children'])
    end
  end
  walk.call(dashboard['zone_tree'])
  return [nil, false] unless fill
  h = fill[1, 6]
  dark = (0.299 * h[0, 2].to_i(16) + 0.587 * h[2, 2].to_i(16) + 0.114 * h[4, 2].to_i(16)) < 140
  [{ 'backgroundColor' => fill, 'borderRadius' => 'round' }, dark]
end

opts = { page_cols: 24, page_rows: 32, row_scale: 1.5, chart_y0: 29.7,
         chart_y1: 100.0, chart_row0: 6, renames: {}, pruned_elements: [] }
OptionParser.new do |p|
  p.on('--ir PATH', 'canonical workbook-ir.json; resolves layout/wb-ids/out') { |v| opts[:ir] = v }
  p.on('--layout PATH')        { |v| opts[:layout] = v }
  p.on('--wb-ids PATH')        { |v| opts[:wb_ids] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--census-out PATH', 'per-page fill/coverage census for gate 8c (default: layout-census.json beside --out)') { |v| opts[:census_out] = v }
  p.on('--page-cols N',  Integer) { |v| opts[:page_cols] = v }
  # Explicitness recorded (v5.1): an explicit --page-rows always wins over the
  # px-derived row model (see the per-dashboard derivation in the dash loop).
  p.on('--page-rows N',  Integer) { |v| opts[:page_rows] = v; opts[:page_rows_explicit] = true }
  p.on('--row-scale F',  Float, 'row-height multiplier (default 1.5; min label-safe ~1.43)') { |v| opts[:row_scale] = v; opts[:row_scale_explicit] = true }
  p.on('--rename PAIR', 'Tableau-name=Sigma-name (repeat) — matches the parity scripts\' flag') do |v|
    from, to = v.split('=', 2)
    abort("--rename expects 'Tableau name=Sigma name', got #{v.inspect}") if from.nil? || to.nil? || from.empty? || to.empty?
    opts[:renames][from] = to
  end
  p.on('--chart-y0 PCT', Float)   { |v| opts[:chart_y0] = v }
  p.on('--chart-y1 PCT', Float)   { |v| opts[:chart_y1] = v }
  p.on('--chart-row0 N', Integer) { |v| opts[:chart_row0] = v }
  p.on('--no-containers', 'force the geometry-banded layout even when the dashboard nests a filter/parameter rail') { opts[:no_containers] = true }
  p.on('--no-synthetic-title', 'never fabricate the page-name header band (synthetic title banner)') { opts[:no_synthetic_title] = true }
end.parse!
if opts[:ir]
  ir_root = File.dirname(File.expand_path(opts[:ir]))
  opts[:layout] ||= WorkbookIR.artifact_path(opts[:ir], 'layout')
  opts[:wb_ids] ||= WorkbookIR.artifact_path(opts[:ir], 'workbook_ids')
  opts[:out] ||= WorkbookIR.artifact_path(opts[:ir], 'layout_xml') || File.join(ir_root, 'layout.xml')
end
%i[layout wb_ids out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

# ---- Rename persistence (#422 re-entry repeat-tax) --------------------------
# Operator --rename mappings used to live only in the invocation: every
# orchestrator re-entry rebuilt the layout WITHOUT them, silently dropping the
# renamed tiles until the operator re-typed --rename by hand (live-measured 4x
# per re-entry). Persist the merged map to <workdir>/layout-renames.json
# (beside --layout, like the other sidecars) and auto-load it on every build.
# CLI flags win over the file on conflict; the write-back accumulates.
RENAMES_PATH = File.join(File.dirname(opts[:layout]), 'layout-renames.json')
cli_renames = opts[:renames].dup
if File.exist?(RENAMES_PATH)
  begin
    prior = JSON.parse(File.read(RENAMES_PATH))
    if prior.is_a?(Hash) && prior.any?
      opts[:renames] = prior.merge(cli_renames) # CLI wins
      warn "loaded #{prior.size} persisted rename mapping(s) from #{RENAMES_PATH}"
    end
  rescue JSON::ParserError => e
    warn "WARN: #{RENAMES_PATH} unreadable (#{e.message}) — persisted renames ignored this run"
  end
end
if cli_renames.any?
  begin
    File.write(RENAMES_PATH, JSON.pretty_generate(opts[:renames]) + "\n")
    warn "persisted #{opts[:renames].size} rename mapping(s) → #{RENAMES_PATH} (auto-applied on every rebuild, re-entry included)"
  rescue StandardError => e
    warn "WARN: could not persist renames to #{RENAMES_PATH}: #{e.class}: #{e.message}"
  end
end

# ---- Synthetic-title prior-state suppression (#422) -------------------------
# When a prior layout.xml exists at --out and shows NO header band (neither a
# fabricated "-hdrtext" banner nor a "-hdr" band container), the operator
# removed the banner — a rebuild must respect that last state, not re-inject it.
unless opts[:no_synthetic_title]
  begin
    if File.exist?(opts[:out])
      prior_xml = File.read(opts[:out])
      if prior_xml.include?('<Page') && !prior_xml.include?('-hdrtext"') && !prior_xml.include?('-hdr"')
        opts[:no_synthetic_title] = true
        warn "prior #{opts[:out]} carries no header band — synthetic title banner auto-suppressed " \
             '(operator last state respected; pass --no-synthetic-title to make it explicit)'
      end
    end
  rescue StandardError
    # unreadable prior layout → build as usual
  end
end

# Row scaling / px-derived page height (v5.1 defect 1): the page row count is
# now resolved PER DASHBOARD in the dash loop below — a dashboard with a fixed
# px canvas derives its rows from canvas_h / SIGMA_ROW_PX (row_scale
# neutralized: the 1.5x scale existed only to compensate the 32-row default's
# underestimate); dashboards without canvas_px keep the legacy
# page_rows * row_scale mapping byte-identically (bead tkkv).

dash_layout = JSON.parse(File.read(opts[:layout]))
wb_ids_raw  = JSON.parse(File.read(opts[:wb_ids]))
wb_ids      = WorkbookCode.legacy_view(wb_ids_raw)

# ---- Chart provenance (orphan-fix, class 2 prevention) ----------------------
# chart-provenance.json (written by build-charts-from-signals beside
# dashboard-layout.json) maps element id → the Tableau WORKSHEET that built it.
# Zone→element matching is name-based (display_title, then caption) while the
# builder names tiles by display_title — so a tile whose display name drifted
# from what the zone knows failed the match, fell into the safety-net band
# ("N element(s) had no Tableau zone"), and left a stale injected container
# behind on later re-PUTs. Provenance gives the collision-free caption
# (worksheet) → element join; aliases are ADDED to els_by_name and never
# overwrite a real display name. Best-effort: no file → no aliases.
PROV_BY_ID = begin
  prov_path = File.join(File.dirname(opts[:layout]), 'chart-provenance.json')
  if File.exist?(prov_path)
    pj = JSON.parse(File.read(prov_path))
    # ROOT CAUSE (#422 re-entry 1/6 match): build-charts-from-signals writes
    # { "version": 1, "elements": { "<id>": {...} } } — this loader read the
    # file FLAT, so every id lookup missed the "elements" envelope and #421's
    # provenance matching silently never fired in the orchestrated flow (the
    # unit fixture wrote the flat shape: a false green). Unwrap the envelope;
    # a flat hand-authored map is still accepted.
    if pj.is_a?(Hash) && pj['elements'].is_a?(Hash)
      pj['elements']
    else
      pj.is_a?(Hash) ? pj : {}
    end
  else
    {}
  end
rescue StandardError
  {}
end

# KPI-comparison wave: kpi-chart elements (KpiCard.build, scripts/lib/kpi_card.rb)
# carry `name` as the house-standard OBJECT form {'text'=>...}, not a plain
# String — every other element kind still emits a plain String name. Name-based
# zone matching (els_by_name below) must accept both shapes, or every KPI tile
# silently misses its els_by_name lookup (String zone name vs Hash element key)
# and falls into the safety-net band as an "unmatched zone" tile.
def el_display_name(el)
  n = el['name']
  n.is_a?(Hash) ? n['text'] : n
end

# Add provenance worksheet-name aliases for this page's elements (see above).
def augment_els_by_name!(els_by_name, elements)
  elements.each do |e|
    rec = PROV_BY_ID[e['id'].to_s]
    next unless rec.is_a?(Hash)
    ws = rec['worksheet'].to_s
    els_by_name[ws] = e unless ws.empty? || els_by_name.key?(ws)
  end
  els_by_name
end

# Resolve a zone's Sigma element: display-title/rename name first
# (zone_el_name), then the raw caption — the worksheet name, which hits the
# provenance alias when the tile was renamed. Shared by all three layout paths
# and their census counts so matching cannot drift between them.
def find_zone_el(els_by_name, z, renames)
  els_by_name[zone_el_name(z, renames)] || els_by_name[z['caption'].to_s]
end

# Page lookups
data_page  = wb_ids['pages'].find { |p| p['name'] == 'Data' }
abort('no "Data" page in wb-ids') unless data_page
master_el  = data_page['elements'].first

# Multi-dashboard workbooks (bead ptrt): ONE Sigma page per Tableau dashboard,
# each with its own container-banded layout. Pair each dashboard to the page
# with the same name; when the workbook has a single non-Data page (legacy
# single-dashboard flow), pair the first dashboard to it.
content_pages = wb_ids['pages'].reject { |p| p['name'] == 'Data' || p['name'].nil? }
content_pages = [wb_ids['pages'][1]].compact if content_pages.empty?
abort('no overview page (non-Data) in wb-ids') if content_pages.empty?

page_for_dash = {}
normalize_page_name = lambda do |value|
  value.to_s.sub(/\A\[synthetic\]\s*/i, '').downcase.gsub(/[^a-z0-9]+/, ' ').strip
end
dash_layout.each do |d|
  pg = content_pages.find { |p| p['name'] == d['dashboard'] }
  if pg.nil?
    wanted = normalize_page_name.call(d['dashboard'])
    candidates = content_pages.select { |page| normalize_page_name.call(page['name']) == wanted }
    pg = candidates.first if candidates.one?
  end
  pg ||= content_pages.first if dash_layout.length == 1
  if pg.nil?
    warn "WARN: no Sigma page matched dashboard #{d['dashboard'].inspect} — dashboard skipped from layout"
    next
  end
  page_for_dash[d['dashboard']] = pg
end
abort('no dashboard↔page pairs resolved') if page_for_dash.empty?

def chart_pos(z, opts)
  y0 = z['y_pct'] || 0
  h  = z['h_pct'] || 0
  y1 = y0 + h
  remaining_rows = opts[:page_rows] - (opts[:chart_row0] - 1)
  span = (opts[:chart_y1] - opts[:chart_y0]).to_f
  span = 1.0 if span <= 0
  row_start = (opts[:chart_row0] + (y0 - opts[:chart_y0]) / span * remaining_rows).round
  row_end   = (opts[:chart_row0] + (y1 - opts[:chart_y0]) / span * remaining_rows).round
  # Sigma rejects non-positive grid positions ("Invalid element position").
  # Clamp into the legal band [chart_row0 .. page_rows+1] and guarantee a span.
  max_row   = opts[:page_rows] + 1
  row_start = [[row_start, opts[:chart_row0]].max, max_row - 1].min
  row_end   = [[row_end,   row_start + 1].max,      max_row].min
  row_end   = row_start + 1 if row_end <= row_start
  col_start = [1,  (1 + (z['x_pct'] || 0) / 100.0 * opts[:page_cols]).round].max
  col_end   = [opts[:page_cols] + 1, (1 + ((z['x_pct'] || 0) + (z['w_pct'] || 0)) / 100.0 * opts[:page_cols]).round].min
  col_end   = col_start + 1 if col_end <= col_start
  [col_start, col_end, row_start, row_end]
end

# ---- Faithful container-tree layout (preferred when a control rail exists) --
# Mirror Tableau's nested zone tree as nested Sigma Containers so each
# filter / parameter / chart lands INSIDE the container it lives in — preserving
# the left-rail / sidebar idiom and arbitrary nesting — instead of re-banding by
# raw geometry (which lumps every control into one top strip). Activates only
# when the dashboard actually nests a filter/parameter zone; otherwise the
# proven banded path runs. Any failure falls back to bands (rescued in caller).

def clampc(v, lo, hi)
  [[v, lo].max, hi].min
end

# True when the zone tree contains a filter/parameter zone at any depth — the
# case the banded path mishandles and the container path fixes.
def tree_has_controls?(tree)
  (tree || []).any? do |n|
    %w[filter parameter].include?(n['kind']) || tree_has_controls?(n['children'])
  end
end

# True when any container in the tree carries a fill (region-card tints etc.).
# B2 (gap ubr5.6): a designed dashboard with tinted containers but NO controls
# would otherwise take the banded fallback and lose its tints — the container
# path is what preserves them (and falls back safely if the tree can't build).
def tree_has_styled_containers?(tree)
  (tree || []).any? do |n|
    (n['kind'] == 'container' &&
      (n['fill_color'] || n['border_color'] || n['corner_radius'] || n['rounding'])) ||
      tree_has_styled_containers?(n['children'])
  end
end

# Place a child within its parent container's internal 24-col grid from pct
# bounds. parent_rows = grid row-lines the parent spans internally.
# canvas_px ({'w','h'} from the dashboard <size>, sizing-mode=fixed) makes
# px-FIXED zones exact: a child with `fixed_size` inside a layout-flow parent
# is sized in PIXELS on the flow axis (verified: zone h_pct == fixed_size /
# canvas_h to the digit), so its span comes from px density, not from rounding
# an already-rounded pct — thin fixed rails/headers keep their exact height.
def place_in_parent(ch, p, parent_rows, canvas_px = nil)
  pw = (p['w_pct'] || 100).to_f; pw = 1.0 if pw <= 0
  ph = (p['h_pct'] || 100).to_f; ph = 1.0 if ph <= 0
  px = (p['x_pct'] || 0).to_f;   py = (p['y_pct'] || 0).to_f
  cx = (ch['x_pct'] || 0).to_f;  cy  = (ch['y_pct'] || 0).to_f
  cw = (ch['w_pct'] || 0).to_f;  chh = (ch['h_pct'] || 0).to_f
  c0 = clampc(1 + ((cx - px) / pw * 24).round, 1, 24)
  c1 = clampc(1 + ((cx + cw - px) / pw * 24).round, c0 + 1, 25)
  r0 = [1, 1 + ((cy - py) / ph * parent_rows).round].max
  r1 = [r0 + 1, 1 + ((cy + chh - py) / ph * parent_rows).round].max
  if canvas_px && ch['fixed_size'].to_i.positive? && p['direction']
    fixed = ch['fixed_size'].to_f
    if p['direction'] == 'vert' && canvas_px['h'].to_i.positive?
      px_per_row = (ph / 100.0 * canvas_px['h']) / parent_rows
      r1 = r0 + [(fixed / px_per_row).round, 1].max if px_per_row.positive?
    elsif p['direction'] == 'horz' && canvas_px['w'].to_i.positive?
      px_per_col = (pw / 100.0 * canvas_px['w']) / 24
      c1 = clampc(c0 + [(fixed / px_per_col).round, 1].max, c0 + 1, 25) if px_per_col.positive?
    end
  end
  [c0, c1, r0, r1]
end

# Resolve a leaf zone to an existing workbook element id (chart by caption,
# filter/param control by target-column / caption, title text to the page
# title). Returns nil for zones Sigma renders inline (legend) or drops (spacer).
def resolve_leaf(node, ctx)
  case node['kind']
  when 'chart'
    name = ctx[:renames][node['caption']] || node['caption']
    el = ctx[:els_by_name][name]
    el && el['id']
  when 'filter', 'parameter'
    # Pre-assigned by build_page_from_tree (caption match, then rail-fill) so a
    # control lands in its container even when its target column didn't resolve.
    ctx[:zone_to_ctl][node['id']]
  when 'text', 'title'
    if ctx[:title_el] && !ctx[:title_used]
      ctx[:title_used] = true
      ctx[:title_el]['id']
    else
      # B4 (gap ubr5.8): styled static-text zone → its emitted element
      # (build-charts id "text-<zoneid>"), placed at the zone's own geometry.
      el = ctx[:els_by_id]["text-#{node['id']}"]
      el && el['id']
    end
  when 'image'
    # v5.0: bitmap zone → its emitted image element (build-charts id
    # "img-<zoneid>", data-URI body from the .twbx Image/ asset). Full-canvas
    # backgrounds (is_background) are page-level, not grid tiles — skip here.
    return nil if node['is_background']
    el = ctx[:els_by_id]["img-#{node['id']}"]
    el && el['id']
  when 'dashboard-object'
    # v5.0-P2: navigation buttons → their emitted element (build-charts id
    # "btn-<zoneid>"). Export/toggle buttons emit nothing (named residue) —
    # nil drops the zone from the grid, correctly.
    el = ctx[:els_by_id]["btn-#{node['id']}"]
    el && el['id']
  end
end

# Recursively emit a zone node as Sigma layout XML at grid cell (c0,c1,r0,r1)
# RELATIVE to its parent container. Container nodes become Containers whose
# children are placed in the container's own 24-col internal grid; empty
# containers (no resolvable children) are dropped. Appends new container spec
# placeholders to ctx[:extra]; records placed element ids in ctx[:placed].
# Resolve overlapping sibling placements within a container. Tableau floats text
# objects (titles, captions, annotations) over/beside charts, so their derived
# grid cells can overlap — and Sigma's put-layout REJECTS the whole layout on any
# collision, dropping the page to a raw vertical stack. The banded path already
# de-collides (lib/layout.rb decollide_bands); the container-tree path did not,
# so a floated text zone could sink the entire layout (B4-emit regression).
#
# rects are [c0,c1,r0,r1] grid-line tuples, container-relative. NO-OP when the
# children don't collide (clean source geometry — e.g. a KPI strip — is preserved
# EXACTLY). Only when a collision exists do we re-flow: give every child an equal
# vertical row slice (columns kept), which is collision-free by construction
# (non-overlapping rows) and localized to the offending container — strictly
# better than the previous whole-page stack fallback.
def decollide_rects(rects, my_rows)
  return rects if rects.length < 2
  overlap = ->(a, b) { a[0] < b[1] && b[0] < a[1] && a[2] < b[3] && b[2] < a[3] }
  return rects unless rects.combination(2).any? { |a, b| overlap.call(a, b) }
  n = rects.length
  rects.each_index.map do |i|
    nr0 = 1 + (my_rows * i / n.to_f).round
    nr1 = [1 + (my_rows * (i + 1) / n.to_f).round, nr0 + 1].max
    [rects[i][0], rects[i][1], nr0, nr1] # keep columns, non-overlapping rows
  end
end

# A comparative KPI (kpi-chart with a comparisonColumn) renders the ▲/▼ delta
# badge only above a taller floor than a single-value KPI — 4 grid rows fits
# value+title but blanks the badge (diagnosed live, see
# .superpowers/sdd/fix-detector-header-report.md #3). Single-value kpi-charts
# (no comparisonColumn) are unaffected and keep the shared kind-only floor.
#
# This bump is intentionally kept LOCAL to the tableau layout builder rather
# than in shared `SigmaLayout.min_rows_for` (lib/layout.rb) — that function
# stays kind-only, used by every el-aware AND kind-only call site across the
# builder. `kpi_min_rows(el)` is a drop-in replacement wherever a full
# resolved ELEMENT (not just its kind) is already in scope.
COMPARATIVE_KPI_MIN_ROWS = 6

def kpi_min_rows(el)
  el ||= {}
  base = SigmaLayout.min_rows_for(el['kind'])
  return base unless el['kind'] == 'kpi-chart' && el['comparisonColumn']
  [base, COMPARATIVE_KPI_MIN_ROWS].max
end

# Same push-down/expand algorithm as SigmaLayout.enforce_min_rows (band-level
# E1 floor enforcement), but keyed on the resolved ELEMENT rather than kind
# alone, so kpi_min_rows can see comparisonColumn. Mirrors the shared logic
# locally (via the shared, kind-agnostic expand_min_rows primitive) instead of
# changing the shared, kind-only SigmaLayout.enforce_min_rows/min_rows_for.
# Used by the banded-fallback path (build_page_for_dashboard) — the one
# el-aware site that went through a kind-only id->kind map rather than a
# direct min_rows_for(el['kind']) call.
def enforce_min_rows_els(bands, els_by_id)
  total = 0
  offset = 0
  out = bands.map do |band|
    shifted = band.map { |it| [it[0], it[1], it[2], it[3] + offset, it[4] + offset, *it[5..-1]] }
    bottom_before = shifted.map { |i| i[4] }.max
    rects = shifted.map { |it| it[1, 4] }
    mins  = shifted.map { |it| kpi_min_rows(els_by_id[it[0]]) }
    rects, n = SigmaLayout.expand_min_rows(rects, mins)
    total += n
    grown = shifted.each_with_index.map do |it, i|
      [it[0], rects[i][0], rects[i][1], rects[i][2], rects[i][3], *it[5..-1]]
    end
    bottom_after = grown.map { |i| i[4] }.max
    offset += [bottom_after - bottom_before, 0].max
    grown
  end
  [out, total]
end

# Recursively PLAN a zone node. Returns nil (nothing placeable) or
# [needed_rows, emit_proc] where emit_proc.(c0, c1, r0, r1) yields the node's
# XML at its FINAL grid cell. Two-phase (plan, then emit) because E1
# minimum-row enforcement can grow a leaf — and therefore every ancestor
# container: the parent learns each child's needed height first, grows the
# child rects, pushes lower siblings down (SigmaLayout.pack_rects — the grid
# stays collision-free), and only then emits at the settled cells. A node's
# needed_rows never shrinks below its original allocation, so source
# proportions are preserved when no floor kicks in.
def plan_node(node, c0, c1, r0, r1, ctx)
  # v5.0-P2 divider synthesis: a thin filled rule (spacer / childless container
  # / blank-text zone) becomes a NATIVE Sigma divider (live-verified). Checked
  # FIRST so it catches the childless-container idiom (which the container
  # branch would drop as plans.empty?) and preempts resolve_leaf's nil for
  # spacer/blank-text rules. Horizontal rules clamp to 1 row (cmax — the
  # stroke centers in its cell); vertical rules keep their source row span.
  if ZoneCensus.divider_zone?(node, ctx[:canvas_px])
    did = "dv-#{ctx[:page_id]}-#{node['id']}"
    ctx[:extra] << SigmaLayout.divider_el(did, node)
    horizontal = node['w_pct'].to_f >= node['h_pct'].to_f
    return [1, proc { |fc0, fc1, fr0, fr1| le(did, fc0, fc1, fr0, fr1) }, horizontal ? 1 : nil]
  end
  if node['kind'] == 'container'
    kids = node['children'] || []
    # Wrapper-chain collapse: Tableau nests single-child pass-through
    # containers several levels deep (authoring artifacts). Each one used to
    # become a real Container — 12 no-op containers on the benchmark,
    # each adding padding + a rounding pass that drifts the geometry. A
    # single-child container that carries NO visual identity of its own
    # (no fill/border/corner style) is pure structure: plan the child
    # directly at the container's cell.
    if kids.length == 1 && !node['fill_color'] && !node['border_color'] &&
       !node['corner_radius'] && !node['rounding']
      return plan_node(kids[0], c0, c1, r0, r1, ctx)
    end
    my_rows = [r1 - r0, 2].max
    rects = kids.map { |ch| place_in_parent(ch, node, my_rows, ctx[:canvas_px]) }
    rects = decollide_rects(rects, my_rows)
    plans = []
    kids.each_index do |i|
      pl = plan_node(kids[i], *rects[i], ctx)
      plans << [rects[i], pl[0], pl[1], pl[2]] if pl
    end
    return nil if plans.empty?
    # Grow each child rect to fit its content, THEN clamp a header-label child
    # (cmax present) down to its max height — the layout otherwise never shrinks
    # below the source zone geometry, so a one-line header stays ~6 rows tall.
    grown = plans.map do |(rc, needed, _ep, cmax)|
      r1 = [rc[3], rc[2] + needed].max
      r1 = [r1, rc[2] + cmax].min if cmax
      [rc[0], rc[1], rc[2], r1]
    end
    packed = SigmaLayout.pack_rects(grown)
    needed_rows = [my_rows, packed.map { |r| r[3] }.max - 1].max
    # If EVERY child is a header label, this container IS a header band — clamp its
    # own height and propagate the clamp up (3rd return element) so the OUTER tinted
    # band row shrinks too, not just the inner leaf. Mixed containers (a chart +
    # a label) get no container clamp; the label child is still clamped via `grown`.
    child_maxes = plans.map { |pl| pl[3] }
    band_max = (!child_maxes.empty? && child_maxes.all?) ? child_maxes.compact.max : nil
    needed_rows = [needed_rows, band_max].min if band_max
    cid = "tc-#{ctx[:page_id]}-#{node['id']}"
    # B2 (gap ubr5.6): apply the Tableau zone's fill as the Sigma container tint.
    # parse-twb-layout surfaces fill_color (region-card tints, e.g. #07b4a24e) and
    # border_color from the zone's <zone-style>. 8-digit-alpha hex renders over the
    # canvas verbatim (Sigma accepts it), so the region columns keep their color
    # without a separate pastel-flattening step. Unstyled zones → plain container.
    cstyle = {}
    cstyle['backgroundColor'] = node['fill_color'] if node['fill_color']
    if node['border_color']
      cstyle['borderColor'] = node['border_color']
      width = node['border_width'].to_i
      cstyle['borderWidth'] = [[width, 1].max, 3].min
    end
    radius = node['corner_radius'].to_i
    if radius.positive? || node['rounding']
      height_px = ctx.dig(:canvas_px, 'h').to_f * node['h_pct'].to_f / 100.0
      cstyle['borderRadius'] = height_px.positive? && radius / height_px > 0.3 ? 'pill' : 'round'
    elsif node['fill_color']
      cstyle['borderRadius'] = 'round'
    end
    ctx[:extra] << container_el(cid, cstyle.empty? ? nil : cstyle)
    emit = proc do |fc0, fc1, fr0, fr1|
      inner = plans.each_with_index.map { |(_, _, ep), i| ep.call(*packed[i]) }.join("\n")
      gc(cid, fc0, fc1, fr0, fr1, inner)
    end
    [needed_rows, emit, band_max]
  else
    eid = resolve_leaf(node, ctx)
    return nil unless eid && !ctx[:placed].include?(eid)
    ctx[:placed] << eid
    # E1: enforce the per-kind minimum row span (KIND_MIN_ROWS) — tiles under
    # ~3-4 grid rows render BLANK in Sigma. The floor keys on the RESOLVED
    # element's Sigma kind (the same source layout_lint checks); the flat zone
    # (chart_kind + plot signals) is the fallback when the kind is unknown.
    span = r1 - r0
    el = ctx[:els_by_id][eid]
    min = if el && el['kind']
            kpi_min_rows(el)
          else
            SigmaLayout.min_rows_for_zone(ctx[:zone_by_id][node['id']] || node)
          end
    if span < min
      ctx[:min_row_expansions] += 1
      span = min
    end
    # A short single-line TEXT LABEL (section/column header) must render as a THIN
    # banner, not a tall colored block. Return a MAX-rows clamp (3rd element) that
    # the parent's grow-to-fit honors — capping `span` alone does nothing because
    # the layout grows to max(geometry, needed) and never shrinks below the source
    # zone geometry (which maps a one-line header to ~6 rows). See the parent
    # branch: it clamps each child rect to `cmax` and, when EVERY child is a header
    # label, propagates the clamp up so the whole tinted band row shrinks too.
    maxr = nil
    if el && el['kind'] == 'text'
      # Read the label from the ZONE's text_runs — NOT the readback element's
      # `body`. The /columns readback drops `body`, so keying on it left maxr nil
      # and starved the whole band_max clamp (the false-green: the unit test had
      # supplied a body the real readback omits). A short SINGLE-LINE label is a
      # section/column header → thin band; multi-line or long text keeps its
      # height. (Predicate shared with the header-title detection — v5.1.)
      zone = ctx[:zone_by_id][node['id']] || node
      runs = zone.is_a?(Hash) ? (zone['text_runs'] || []) : []
      maxr = SigmaLayout::HEADER_BAND_MAX_ROWS if SigmaLayout.title_like_runs?(runs)
    end
    [span, proc { |fc0, fc1, fr0, fr1| le(eid, fc0, fc1, fr0, fr1) }, maxr]
  end
end

# Assign workbook control elements to control zones (filter/parameter), in the
# given zone order: caption match first, then fill the remaining control zones
# with leftover controls. Returns { zone_id => element_id }. (Shared by the
# container-tree and synthesized paths — puts a rail's controls INSIDE the
# rail even when a zone's target column didn't resolve.)
def assign_controls(control_zones, elements)
  ctl_by_name = elements.select { |e| e['kind'] == 'control' && e['name'] }
                        .each_with_object({}) { |e, h| h[e['name'].to_s.downcase] = e }
  all_ctls = elements.select { |e| e['kind'] == 'control' }
  zone_to_ctl = {}
  used = {}
  control_zones.each do |z|
    nm = (z['filter_column_caption'] || z['caption']).to_s.downcase
    el = nm.empty? ? nil : ctl_by_name[nm]
    next unless el && !used[el['id']]
    zone_to_ctl[z['id']] = el['id']
    used[el['id']] = true
  end
  leftover = all_ctls.reject { |e| used[e['id']] }
  control_zones.each do |z|
    next if zone_to_ctl[z['id']]
    el = leftover.shift or next
    zone_to_ctl[z['id']] = el['id']
    used[el['id']] = true
  end
  zone_to_ctl
end

# Safety net shared by the container-tree + synthesized paths: any placeable
# element NOT placed by the structure (an unmatched zone, or a control with no
# dashboard zone) lands in a bottom band so nothing silently drops from the
# layout. Placeable content = any *-chart, table/pivot-table, control, or text
# (never structural containers/data; charts built from signals may carry no
# name, yet must still be placed). The band sits BELOW the placed content
# (below_row) and is tall enough for its neediest kind (E1 floors). Returns
# the band's page rect, or nil when everything was placed.
# CONTRACT (v5.1 defect 3): a FLOATED image zone must never reach this band —
# the float partition in build_page_from_tree consumes every floating root
# (header composition, top strip, or an explicit drop + image-assets.json
# record), marking its element placed either way.
def safety_net_band(page, placed, extra_els, children, prefix, below_row, page_rows)
  placeable = lambda do |e|
    k = e['kind'].to_s
    # dividers deliberately EXCLUDED: an unplaced divider must never generate
    # a stray bottom band (it only exists when the tree placed it anyway).
    k.end_with?('-chart') || %w[table pivot-table control text image button].include?(k)
  end
  unplaced = page['elements'].select { |e| placeable.call(e) && !placed.include?(e['id']) }
  return nil if unplaced.empty?
  n = unplaced.length
  rows_needed = unplaced.map { |e| kpi_min_rows(e) }.max
  cw = 24.0 / n
  inner = unplaced.each_with_index.map do |e, i|
    cs = 1 + (cw * i).round
    ce = i == n - 1 ? 25 : [1 + (cw * (i + 1)).round, cs + 1].max
    le(e['id'], cs, ce, 1, 1 + rows_needed)
  end.join("\n")
  bid = "#{prefix}-extra"
  extra_els << container_el(bid)
  band_r0 = [[page_rows - 4, HEADER_ROWS + 1].max, below_row].max
  children << gc(bid, 1, 25, band_r0, band_r0 + rows_needed, inner)
  warn "WARN: #{n} element(s) had no Tableau zone — appended in a bottom band: " \
       "#{unplaced.map { |e| el_display_name(e) || e['id'] }.join(', ')}"
  [1, 25, band_r0, band_r0 + rows_needed]
end

# Container-tree page builder. Same return shape as build_page_for_dashboard.
def build_page_from_tree(dashboard, page, opts)
  tree        = dashboard['zone_tree'] || []
  els_by_name = page['elements'].each_with_object({}) { |e, h| n = el_display_name(e); h[n] = e if n }
  augment_els_by_name!(els_by_name, page['elements'])
  ctl_by_name = page['elements'].select { |e| e['kind'] == 'control' && e['name'] }
                    .each_with_object({}) { |e, h| h[e['name'].to_s.downcase] = e }
  els_by_id   = page['elements'].each_with_object({}) { |e, h| h[e['id']] = e if e['id'] }
  # Pin the header title to the dedicated title element (build-charts prepends id
  # "title-text"/"title-<slug>"); a bare first-text-element match would grab a B4
  # styled-text element once those exist. Falls back to the page name when absent.
  # E1: flat zones carry chart_kind + plot signals (tree nodes don't) — the
  # per-kind row floor resolves through this map.
  zone_by_id  = (dashboard['zones'] || []).each_with_object({}) { |z, h| h[z['id']] = z if z['id'] }
  # Dedicated title-* element, else the source's own top banner (shared detector,
  # used by the synthesis path too) — avoids the fabricate-H1-alongside-source-
  # title duplicate-title bug. (Marked placed in the header branch below.)
  title_el    = detect_header_title_el(page, zone_by_id)

  ctx = { page_id: page['id'], renames: opts[:renames], els_by_name: els_by_name,
          ctl_by_name: ctl_by_name, els_by_id: els_by_id, title_el: title_el, title_used: false,
          extra: [], placed: [], zone_to_ctl: {}, zone_by_id: zone_by_id, min_row_expansions: 0,
          canvas_px: dashboard['canvas_px'] }

  # Assign workbook control elements to control zones in document order (see
  # assign_controls) so a rail's controls land INSIDE the rail even when a
  # zone's target column didn't resolve to a caption.
  control_zones = []
  collect = lambda { |ns| (ns || []).each { |n| control_zones << n if %w[filter parameter].include?(n['kind']); collect.call(n['children']) } }
  collect.call(tree)
  ctx[:zone_to_ctl] = assign_controls(control_zones, page['elements'])

  children  = []
  extra_els = ctx[:extra]
  page_rows = opts[:page_rows]
  page_pseudo = { 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0 }
  canvas = dashboard['canvas_px']
  canvas_fixed = canvas.is_a?(Hash) && canvas['sizing_mode'] == 'fixed' &&
                 canvas['h'].to_i >= 400 # same gate as the px-derived row model

  # Header band derived from the source (colored strip only when the source has
  # one; otherwise transparent — title on the canvas, no fabricated navy).
  # v5.1 defect 2: three-way, replacing the old extracted-or-fabricated two-way.
  hdr_style, hdr_dark = header_from_source(dashboard)
  hdr_id = "tc-#{page['id']}-hdr"
  hdr_rows = 0
  if title_el
    # 1. Extracted source banner (dedicated title-* element or the guarded
    # fallback) → band + clip + renormalize. Under the px-derived row model the
    # band height comes from the title zone's own px (min HEADER_ROWS).
    tz = zone_by_id[title_el['id'].to_s.sub(/\Atext-/, '')]
    hdr_rows = HEADER_ROWS
    if canvas_fixed && tz && tz['h_pct']
      hdr_rows = [(tz['h_pct'].to_f / 100.0 * canvas['h'].to_i / SigmaLayout::SIGMA_ROW_PX).ceil,
                  HEADER_ROWS].max
    end
    extra_els << container_el(hdr_id, hdr_style)
    children << header_band_xml(hdr_id, title_el['id'], rows: hdr_rows)
    ctx[:title_used] = true
    # Mark the title element as PLACED so the unplaced-elements safety net below
    # doesn't append it a SECOND time in the bottom band — a duplicate element id
    # makes Sigma reject the whole layout PUT ("Duplicate layout element id"),
    # dropping the page to a stacked fallback. (The banded path is immune: its
    # text-band selector only matches ids starting "text-", never "title".)
    ctx[:placed] << title_el['id']
    # The extracted banner's SOURCE ZONE would otherwise still reserve its
    # y-extent inside the tree — clip it out and renormalize the page domain to
    # the title's bottom edge so content shifts UP into the freed rows.
    tb = clip_extracted_title_zone!(tree, tz)
    if tb && tb < 50
      page_pseudo['y_pct'] = tb
      page_pseudo['h_pct'] = 100.0 - tb
    end
  elsif top_banner_content?(zone_by_id.values)
    # 2. v5.1 — the source's own top band is an IMAGE wordmark or body text the
    # guarded fallback refused to promote: NO header band at all. The tree
    # already renders the source order (title art at its own geometry); a
    # fabricated page-name H1 here would duplicate the wordmark.
    hdr_rows = 0
  elsif opts[:no_synthetic_title]
    # #422: synthetic banner suppressed (flag or prior-state) — no fabricated
    # page-name header; the body starts at the top of the grid.
    hdr_rows = 0
  else
    # 3. Fabricated page-name header — only when the source has no banner-like
    # content in the top region at all.
    hdr_rows = HEADER_ROWS
    extra_els << container_el(hdr_id, hdr_style)
    txt_id = "tc-#{page['id']}-hdrtext"
    extra_els << header_text_el(txt_id, page['name'], hdr_dark ? '#FFFFFF' : nil)
    children << header_band_xml(hdr_id, txt_id)
  end
  body_rows = hdr_rows.zero? ? page_rows : [page_rows - hdr_rows, 4].max
  if canvas_fixed && page_pseudo['y_pct'].to_f.positive?
    # px-true body budget after a title clip (v5.1 defect 1, insertion pt 4):
    # the remaining content must keep mapping at SIGMA_ROW_PX per row, so the
    # budget shrinks in px, not just pct.
    body_rows = [((100.0 - page_pseudo['y_pct'].to_f) / 100.0 * canvas['h'].to_i /
                  SigmaLayout::SIGMA_ROW_PX).round, 4].max
  end

  # v5.1 defect 3 — float partition. Floating root zones (Tableau floats are
  # root SIBLINGS of the layout root) must never be packed below the main
  # container by pack_rects (the brush-X-art-at-page-bottom defect):
  #   - header-region floats join the top-band composition — beside the intro
  #     text when one overlaps (adjacency degradation of the inexpressible
  #     z-overlap), else as their own top strip above the body;
  #   - mid-page floats keep tree placement, but a floating IMAGE that
  #     pack_rects would displace > 25% of the page below its source row is
  #     dropped with a WARN + a recoverable image-assets.json record.
  content_rects = []
  floats, tree_roots = tree.partition { |n| floating_zone?(n, tree) }
  host = tree_roots.find { |n| n['kind'] == 'container' }
  # Descend single-child pass-through wrappers (the same chain plan_node
  # collapses) to the EFFECTIVE composition container — real trees nest the
  # header row / intro / sections many wrapper levels deep, and the float must
  # compose against those siblings, not against a lone wrapper child.
  while host && Array(host['children']).length == 1 && host['children'][0]['kind'] == 'container'
    host = host['children'][0]
  end
  mid_floats = []
  floats.each do |f|
    fy0 = (f['y_pct'] || 0).to_f
    in_header = fy0 < SigmaLayout::HEADER_MAX_Y_PCT || fy0 < page_pseudo['y_pct'].to_f
    unless in_header
      mid_floats << f
      next
    end
    next if host && compose_float_beside_text!(f, host) # now IN the tree, beside the intro
    # No side-by-side text row in the header composition: the float gets its
    # own px rows (capped at the header region's extent) as a top strip and the
    # body shifts below it — NEVER the page-bottom band.
    eid = resolve_leaf(f, ctx)
    next unless eid && !ctx[:placed].include?(eid)
    ctx[:placed] << eid
    fc0 = clampc(1 + ((f['x_pct'] || 0).to_f / 100.0 * 24).round, 1, 24)
    fc1 = clampc(1 + (((f['x_pct'] || 0).to_f + (f['w_pct'] || 0).to_f) / 100.0 * 24).round, fc0 + 1, 25)
    frows = if canvas_fixed
              ((f['h_pct'] || 0).to_f / 100.0 * canvas['h'].to_i / SigmaLayout::SIGMA_ROW_PX).ceil
            else
              ((f['h_pct'] || 0).to_f / 100.0 * body_rows).round
            end
    cap = [(page_rows * SigmaLayout::HEADER_MAX_H_PCT / 100.0).ceil, HEADER_ROWS].max
    frows = [[frows, 2].max, cap].min
    children << le(eid, fc0, fc1, 1 + hdr_rows, 1 + hdr_rows + frows)
    content_rects << [fc0, fc1, 1 + hdr_rows, 1 + hdr_rows + frows]
    hdr_rows += frows
  end

  # Top-level zones → page children, shifted below the header band. PLAN every
  # node first (E1 minimum-row floors can grow a node), then settle the grown
  # rects collision-free (pack_rects pushes lower bands down) and emit at the
  # final cells. Collect the PAGE-absolute footprint of every top-level node
  # that actually placed (gate 8c fill numerator — a top-level container's
  # rect covers its nested tiles).
  plans = []
  float_src = {}
  tree_roots.each do |node|
    c0, c1, r0, r1 = place_in_parent(node, page_pseudo, body_rows)
    r0 += hdr_rows; r1 += hdr_rows
    pl = plan_node(node, c0, c1, r0, r1, ctx)
    next unless pl
    plans << [[c0, c1, r0, [r1, r0 + pl[0]].max], pl[1]]
  end
  mid_floats.each do |node|
    c0, c1, r0, r1 = place_in_parent(node, page_pseudo, body_rows)
    r0 += hdr_rows; r1 += hdr_rows
    pl = plan_node(node, c0, c1, r0, r1, ctx)
    next unless pl
    plans << [[c0, c1, r0, [r1, r0 + pl[0]].max], pl[1]]
    float_src[plans.length - 1] = { r0: r0, node: node }
  end
  packed = SigmaLayout.pack_rects(plans.map { |rc, _| rc })
  plans.each_with_index do |(_, ep), i|
    fs = float_src[i]
    if fs && fs[:node]['kind'] == 'image' && (packed[i][2] - fs[:r0]) > page_rows * 0.25
      # Hard invariant (v5.1): a decorative float stranded far below its source
      # y is worse than absent — drop it, keep it recoverable, and explicitly
      # remove its declared element during put-layout. The prune record is the
      # only exception to the every-declared-element-is-placed contract.
      eid = resolve_leaf(fs[:node], ctx)
      warn "WARN: floating image zone #{fs[:node]['id']} would be packed " \
           "#{packed[i][2] - fs[:r0]} rows below its source position — dropped from " \
           'the grid (placement: manual-composite in image-assets.json)'
      record_manual_composite(opts[:layout], dashboard['dashboard'], fs[:node]['id'])
      opts[:pruned_elements] << {
        'element_id' => eid,
        'page_id' => page['id'],
        'reason' => 'manual-composite',
        'dashboard' => dashboard['dashboard'],
        'zone_id' => fs[:node]['id'].to_s
      }
      next
    end
    children << ep.call(*packed[i])
    content_rects << packed[i]
  end

  # Safety net: any chart/control element NOT placed by the tree (an unmatched
  # zone, or a control with no dashboard zone) lands in a bottom band so nothing
  # silently drops from the layout (see safety_net_band — kinds are REAL Sigma
  # element kinds: `bar-chart`/`kpi-chart`/`table`/…, never literal `chart`).
  content_bottom = content_rects.map { |r| r[3] }.max || (HEADER_ROWS + 1)
  band_rect = safety_net_band(page, ctx[:placed], extra_els, children,
                              "tc-#{page['id']}", content_bottom, page_rows)
  content_rects << band_rect if band_rect # safety band holds real tiles → counts as filled

  # ---- Layout census (gate 8c, #259) ----------------------------------------
  # zones from the authoritative flat source list; placed = content zones whose
  # element made it into ctx[:placed]. Header band excluded from the fill rects.
  content_zones = ZoneCensus.content_zones(dashboard['zones'])
  placed = content_zones.count do |z|
    e = find_zone_el(els_by_name, z, opts[:renames])
    e && ctx[:placed].include?(e['id'])
  end
  fill = ZoneCensus.grid_fill_pct(content_rects, opts[:page_cols], page_rows)
  census = ZoneCensus.page_record(page['name'], content_zones.size, placed, fill)

  [page_xml(page['id'], *children), extra_els, ctx[:placed].size, tree.length, ctl_by_name.size,
   census, ctx[:min_row_expansions]]
end

# ---- E2: structure-aware synthesis (composition-recipe.md, codified) --------
# Preferred path when the FLAT zone list exhibits recognizable dashboard
# structure — a KPI card row and/or a narrow control sidebar (SigmaLayout
# detect_bands). Emits, top to bottom:
#   header band (rows 1..3) — title text full-width; colored only when the
#                             source has a band-like fill (header_from_source);
#                             detected source header text zones join the band
#   sidebar rail            — one vertical Container (repeat(1,1fr)) of
#                             stacked controls at the page edge; the content
#                             grid gets the remaining columns
#   control band            — non-rail controls side-by-side under the header
#   KPI rows                — ONE Container per detected row, inner
#                             Elements at equal spans, inner gridRow
#                             matching the container span (the KPI-sliver
#                             rule: gridTemplateRows="auto" does NOT stretch
#                             short children — see refs/workbook-layout.md)
#   section panels          — contiguous chart groups between full-width text
#                             zones keep their relative geometry (percentage
#                             mapping) snapped to the standard breakpoints
#                             (SigmaLayout::COL_BREAKPOINTS), gaps closed
# E1 minimum row spans are enforced throughout; growth pushes lower units down
# so the grid stays collision-free. Deterministic: same input, same XML (every
# sort carries a zone/element id tiebreaker). Same return shape as
# build_page_for_dashboard (+ min_row_expansions).
SECTION_TEXT_MIN_W_PCT = 60.0 # a text zone at least this wide separates sections

# The source dashboard's title element, resolved identically for BOTH layout
# paths (geometry `build_page_from_tree` and synthesis `build_page_synthesized`).
# Prefer a dedicated `title-*` element; otherwise fall back to the source's own
# TOP-BANNER text (a text zone at y≈0 spanning most of the width). Using the
# source title as the header — instead of fabricating a page-name H1 alongside it
# — is what prevents the duplicate-title bug. Previously only the geometry path
# had the fallback, so synthesized pages shipped two titles. Shared here so the
# two paths cannot drift again.
# Resolve the Sigma element NAME a source zone maps to. Tiles are now named by
# the worksheet display_title (human title, e.g. "Net Revenue"), NOT the caption/
# nickname ("OV KPI Revenue"), so zone→element matching must prefer display_title
# (after any explicit --rename), falling back to the caption (still == the name
# when the worksheet had no custom title). This keeps the layout + parity matchers
# in lockstep with the element namer — changing the display name in one place must
# not silently drop every tile from the layout.
def zone_el_name(z, renames)
  explicit = renames && renames[z['caption']]
  return explicit if explicit
  dt = z['display_title'].to_s.strip
  dt.empty? ? z['caption'] : dt
end

# Ancestor-container chain (outermost first) leading to zone id `zid`; [] for a
# top-level zone, nil when absent from the tree.
def find_zone_path(nodes, zid, path = [])
  (nodes || []).each do |n|
    return path if n['id'] == zid
    if n['children']
      found = find_zone_path(n['children'], zid, path + [n])
      return found if found
    end
  end
  nil
end

# The source's own top-banner text zone gets EXTRACTED into the page header
# band — but its zone stays in the tree, so its y-extent is reserved TWICE:
# header rows up top PLUS an equal dead band inside every top-aligned ancestor
# container (live-caught: the title cost ~20% of the page instead of the
# source's 8%, and the page failed the visual-similarity floor on dead space
# alone). Remove the zone, clip each top-aligned ancestor's y-domain to the
# title's bottom edge, and return that edge — the caller renormalizes the page
# pseudo-container to it so the remaining content SHIFTS UP into the freed
# rows (clipping alone keeps absolute proportions and the gap survives).
# Returns the title's bottom y_pct, or nil when nothing was clipped.
def clip_extracted_title_zone!(tree, tz, eps = 1.5)
  return nil unless tz && tz['id'] && tz['y_pct'] && tz['h_pct']
  path = find_zone_path(tree, tz['id'])
  return nil unless path
  ty = tz['y_pct'].to_f
  tb = ty + tz['h_pct'].to_f
  (path.empty? ? tree : (path.last['children'] || [])).reject! { |k| k['id'] == tz['id'] }
  # Prune ancestors the removal left CONTENT-FREE (spacers only): a dead
  # title-row container still maps to a rect at its siblings' top edge, and
  # that phantom collision trips decollide_rects' equal-slicing — which throws
  # away every sibling's source proportions (live-caught: the whole page
  # re-flowed into uniform bands, dead space intact).
  placeable = lambda do |n|
    next false if n['kind'] == 'spacer'
    next true unless n['kind'] == 'container'
    (n['children'] || []).any? { |c| placeable.call(c) }
  end
  (path.length - 1).downto(0) do |i|
    node = path[i]
    break if placeable.call(node)
    (i.zero? ? tree : (path[i - 1]['children'] || [])).reject! { |k| k['id'] == node['id'] }
  end
  # Clip surviving top-aligned ancestors so children map from the title's
  # bottom edge.
  path.each do |a|
    next unless a['y_pct'] && a['h_pct'] && (a['y_pct'].to_f - ty).abs <= eps
    shrink = tb - a['y_pct'].to_f
    next unless shrink.positive?
    a['y_pct'] = tb
    a['h_pct'] = [a['h_pct'].to_f - shrink, 1.0].max
  end
  tb
end

# v5.1 defect 2: a zone that counts as CONTENT for the header y-order contract
# (chart / image / text-with-runs; containers, spacers and full-canvas
# background images are not content).
def header_guard_content?(z)
  case z['kind'].to_s
  when 'chart' then true
  when 'image' then !z['is_background']
  when 'text', 'title'
    Array(z['text_runs']).any? { |r| !r['text'].to_s.strip.empty? }
  else false
  end
end

# True when another CONTENT zone ends at or above the candidate's top — the
# topmost-content y-order contract (v5.1 defect 2): extraction must never hoist
# a zone above content that sits above it in the source. This alone fixes the
# intro-above-wordmark inversion even where the title heuristic misjudges.
def header_content_above?(zones, cand)
  cand_top = cand['y_pct'].to_f
  Array(zones).any? do |z|
    next false if z.equal?(cand) || (z['id'] && z['id'] == cand['id'])
    next false unless header_guard_content?(z)
    (z['y_pct'].to_f + z['h_pct'].to_f) <= cand_top + 1.5
  end
end

def detect_header_title_el(page, zone_by_id)
  title_el = page['elements'].find { |e| e['kind'] == 'text' && e['id'].to_s.start_with?('title') }
  return title_el if title_el
  zid = ->(e) { e['id'].to_s.sub(/\Atext-/, '') }
  zones = zone_by_id.values
  cands = page['elements'].select { |e| e['kind'] == 'text' }
                          .map { |e| [e, zone_by_id[zid.call(e)]] }
                          .select { |_e, z| z && z['y_pct'].to_f < 12 && z['w_pct'].to_f >= 40 }
  # v5.1 defect 2 guard 1 (title-likeness): a wide multi-line / long-copy zone
  # near the top is an INTRO paragraph, not the banner — never promote it into
  # the header band. Zones with no run data keep the geometric behavior.
  cands = cands.select { |_e, z| !z.key?('text_runs') || SigmaLayout.title_like_runs?(z['text_runs']) }
  # guard 2 (topmost-content y-order): only extract a banner when no other
  # content zone sits ABOVE it in the source.
  cands = cands.reject { |_e, z| header_content_above?(zones, z) }
  cands.min_by { |_e, z| z['y_pct'].to_f }&.first
end

# v5.1 defect 2 (case 2 of the header three-way): true when the source's own
# top band carries a visual banner — an image wordmark, or body text the
# guarded fallback refused to promote. The tree already renders the source
# order for these, so the page emits NO header band and the page name is NOT
# fabricated over the title art. Deliberately narrower than "any content zone"
# (a chart at y<12 keeps the fabricated page-name header — nothing to
# duplicate, and prior behavior for chart-at-top sources is preserved).
def top_banner_content?(zones)
  Array(zones).any? do |z|
    next false unless (z['y_pct'] || 100).to_f < SigmaLayout::HEADER_MAX_Y_PCT
    k = z['kind'].to_s
    (k == 'image' && !z['is_background']) ||
      (%w[text title].include?(k) && Array(z['text_runs']).any? { |r| !r['text'].to_s.strip.empty? })
  end
end

# ---- v5.1 defect 3: floating root zones ------------------------------------
# Tableau floats are additional ROOTS of the dashboard <zones> (siblings of the
# single layout root). Until parse-twb-layout stamps a 'floating' marker,
# detect them structurally: a non-container root when the FIRST root is a
# container. Floats must never be pack_rects'ed below the main container (the
# brush-X-art-at-page-bottom defect) — see the float partition in
# build_page_from_tree.
def floating_zone?(node, tree)
  return false if node['kind'] == 'container'
  return true if node['floating']
  first = tree.first
  !first.nil? && first['kind'] == 'container' && !node.equal?(first)
end

FLOAT_TEXT_Y_OVERLAP_MIN = 0.30 # float must cover >=30% of a text row's
#   y-extent before that text shrinks aside (never shrink images/wordmarks)

# Compose a header-region float into the top-band row it overlaps: find the
# TEXT sibling (host container's direct child) whose y-extent the float covers
# by >= FLOAT_TEXT_Y_OVERLAP_MIN, shrink that text horizontally away from the
# float (z-overlap is inexpressible in Sigma's grid — adjacency degradation),
# snap the float to that row-band's full height, and insert the float into the
# tree in y-order. Only TEXT siblings shrink — full-width wordmark images keep
# their width above. Returns true when composed; false → the caller gives the
# float its own top strip.
def compose_float_beside_text!(float, host)
  fy0 = (float['y_pct'] || 0).to_f
  fy1 = fy0 + (float['h_pct'] || 0).to_f
  kids = (host['children'] ||= [])
  cand = kids.select { |k| %w[text title].include?(k['kind'].to_s) }.map do |k|
    ky0 = (k['y_pct'] || 0).to_f
    kh  = (k['h_pct'] || 0).to_f
    ov  = [fy1, ky0 + kh].min - [fy0, ky0].max
    [kh.positive? && ov.positive? ? ov / kh : 0.0, k]
  end.select { |frac, _| frac >= FLOAT_TEXT_Y_OVERLAP_MIN }
     .max_by { |frac, k| [frac, -(k['y_pct'] || 0).to_f, k['id'].to_s] }
  return false unless cand
  cand = cand.last
  fx0 = (float['x_pct'] || 0).to_f
  fx1 = fx0 + (float['w_pct'] || 0).to_f
  cx0 = (cand['x_pct'] || 0).to_f
  cx1 = cx0 + (cand['w_pct'] || 0).to_f
  if fx0 + fx1 <= cx0 + cx1 # float sits left of the text's center of mass
    nx0 = [fx1, cx1 - 5.0].min # text keeps >= 5% width
    cand['w_pct'] = cx1 - nx0
    cand['x_pct'] = nx0
  else
    cand['w_pct'] = [fx0 - cx0, 5.0].max
  end
  float['y_pct'] = (cand['y_pct'] || 0).to_f
  float['h_pct'] = (cand['h_pct'] || 0).to_f
  idx = kids.index { |k| ([(k['y_pct'] || 0).to_f, (k['x_pct'] || 0).to_f] <=> [float['y_pct'], (float['x_pct'] || 0).to_f]) == 1 }
  kids.insert(idx || kids.length, float)
  true
end

# v5.1 defect 3 (mid-page floats): a floating image pack_rects would strand far
# below its source y is DROPPED from the grid (a decorative float at the wrong
# y is worse than absent) and flagged recoverable in the workdir's
# image-assets.json (written by build-charts-from-signals beside
# dashboard-layout.json in the orchestrated flow). Best-effort: no file, no-op.
def record_manual_composite(layout_path, dash_name, zone_id)
  path = File.join(File.dirname(layout_path.to_s), 'image-assets.json')
  return unless File.exist?(path)
  data = JSON.parse(File.read(path))
  return unless data.is_a?(Array)
  rec = data.find { |a| a.is_a?(Hash) && a['dashboard'] == dash_name && a['zone_id'].to_s == zone_id.to_s }
  unless rec
    rec = { 'dashboard' => dash_name, 'zone_id' => zone_id }
    data << rec
  end
  rec['placement'] = 'manual-composite'
  File.write(path, JSON.pretty_generate(data) + "\n")
rescue StandardError => e
  warn "WARN: could not record manual-composite placement for zone #{zone_id}: #{e.class}: #{e.message}"
end

def build_page_synthesized(dashboard, page, opts, structure)
  zones       = dashboard['zones'] || []
  els_by_name = page['elements'].each_with_object({}) { |e, h| n = el_display_name(e); h[n] = e if n }
  augment_els_by_name!(els_by_name, page['elements'])
  els_by_id   = page['elements'].each_with_object({}) { |e, h| h[e['id']] = e if e['id'] }
  # Header title: dedicated title-* element, else the source's own top banner
  # (shared detector) — NOT a fabricated page-name H1 alongside the source title.
  zone_by_id  = zones.each_with_object({}) { |z, h| h[z['id']] = z if z['id'] }
  title_el    = detect_header_title_el(page, zone_by_id)
  page_rows   = opts[:page_rows]
  placed      = []
  extra_els   = []
  children    = []
  minexp      = 0
  prefix      = "syn-#{page['id']}"

  header_zones = structure[:header]
  kpi_rows     = structure[:kpi_rows]
  rail         = structure[:sidebar]

  # --- header band (rows 1..1+HEADER_ROWS) -----------------------------------
  hdr_style, hdr_dark = header_from_source(dashboard)
  hdr_id = "#{prefix}-hdr"
  hdr_ids = []
  if title_el
    placed << title_el['id']
    hdr_ids << title_el['id']
  elsif !opts[:no_synthetic_title]
    # #422: with --no-synthetic-title (or prior-state suppression) no page-name
    # banner is fabricated; source header-text zones below still get a band.
    txt_id = "#{prefix}-hdrtext"
    extra_els << header_text_el(txt_id, page['name'], hdr_dark ? '#FFFFFF' : nil)
    hdr_ids << txt_id
  end
  # Detected source header-text zones join the band (right of the title) so
  # they are neither re-placed mid-page nor auto-appended by Sigma on save.
  header_zones.each do |z|
    el = els_by_id["text-#{z['id']}"]
    next unless el && !placed.include?(el['id'])
    placed << el['id']
    hdr_ids << el['id']
  end
  hdr_rows = hdr_ids.empty? ? 0 : HEADER_ROWS
  unless hdr_ids.empty?
    extra_els << container_el(hdr_id, hdr_style)
    nh = hdr_ids.length
    hdr_inner = hdr_ids.each_with_index.map do |eid, i|
      c0 = 1 + (24 * i / nh.to_f).round
      c1 = i == nh - 1 ? 25 : [1 + (24 * (i + 1) / nh.to_f).round, c0 + 1].max
      le(eid, c0, c1, 1, 1 + hdr_rows)
    end.join("\n")
    children << gc(hdr_id, 1, 25, 1, 1 + hdr_rows, hdr_inner)
  end

  # --- controls: sidebar rail vs top control band -----------------------------
  control_zones = zones.select { |z| %w[filter parameter].include?(z['kind'].to_s) }
                       .sort_by { |z| [(z['y_pct'] || 0).to_f, (z['x_pct'] || 0).to_f, z['id'].to_s] }
  zone_to_ctl  = assign_controls(control_zones, page['elements'])
  rail_ctl_ids = rail ? rail[:zones].map { |z| zone_to_ctl[z['id']] }.compact.uniq : []
  band_ctls    = page['elements'].select { |e| e['kind'] == 'control' && !rail_ctl_ids.include?(e['id']) }

  ctl_rows   = band_ctls.empty? ? 0 : 3
  content_r0 = 1 + hdr_rows + ctl_rows
  content_c0 = 1
  content_c1 = opts[:page_cols] + 1
  rail_cols  = 0
  if rail
    rail_cols = (((rail[:x1] - rail[:x0]) / 100.0) * opts[:page_cols]).round
    rail_cols = 3 if rail_cols < 3
    rail_cols = 5 if rail_cols > 5
    rail[:side] == :left ? content_c0 = 1 + rail_cols : content_c1 = opts[:page_cols] + 1 - rail_cols
  end

  unless band_ctls.empty?
    nb = band_ctls.length
    ctl_inner = band_ctls.each_with_index.map do |e, i|
      placed << e['id']
      c0 = 1 + (24 * i / nb.to_f).round
      c1 = i == nb - 1 ? 25 : [1 + (24 * (i + 1) / nb.to_f).round, c0 + 1].max
      le(e['id'], c0, c1, 1, 1 + ctl_rows)
    end.join("\n")
    ctl_id = "#{prefix}-ctl"
    extra_els << container_el(ctl_id)
    children << gc(ctl_id, content_c0, content_c1, 1 + hdr_rows, 1 + hdr_rows + ctl_rows, ctl_inner)
  end

  # --- content mapping ---------------------------------------------------------
  consumed = {}
  header_zones.each { |z| consumed[z['id']] = true }
  if rail
    rail[:zones].each { |z| consumed[z['id']] = true }
    rail[:texts].each { |z| consumed[z['id']] = true }
  end
  kpi_rows.each { |row| row.each { |z| consumed[z['id']] = true } }

  resolve_zone_el = lambda do |z|
    case z['kind'].to_s
    when 'chart'
      el = find_zone_el(els_by_name, z, opts[:renames])
      el && el['id']
    when 'text', 'title'
      el = els_by_id["text-#{z['id']}"]
      el && el['id']
    end
  end

  section_zones = zones.select do |z|
    !consumed[z['id']] && %w[chart text title].include?(z['kind'].to_s) && resolve_zone_el.call(z)
  end
  separators = section_zones.select do |z|
    %w[text title].include?(z['kind'].to_s) && (z['w_pct'] || 0).to_f >= SECTION_TEXT_MIN_W_PCT
  end
  sep_ids    = separators.map { |z| z['id'] }
  body_zones = section_zones.reject { |z| sep_ids.include?(z['id']) }

  # Percentage → grid mapping, normalized to the CONTENT extents (the source
  # canvas padding and the rail column are excluded, so content fills the grid).
  all_content = body_zones + separators + kpi_rows.flatten(1)
  cy0 = all_content.map { |z| (z['y_pct'] || 0).to_f }.min || 0.0
  cy1 = all_content.map { |z| (z['y_pct'] || 0).to_f + (z['h_pct'] || 0).to_f }.max || 100.0
  cy1 = cy0 + 1.0 if cy1 <= cy0
  cx0 = all_content.map { |z| (z['x_pct'] || 0).to_f }.min || 0.0
  cx1 = all_content.map { |z| (z['x_pct'] || 0).to_f + (z['w_pct'] || 0).to_f }.max || 100.0
  cx1 = cx0 + 1.0 if cx1 <= cx0
  rows_avail = [page_rows + 1 - content_r0, 4].max
  to_row = lambda do |y|
    r = content_r0 + ((y - cy0) / (cy1 - cy0) * rows_avail).round
    [[r, content_r0].max, page_rows + 1].min
  end
  # container-INTERNAL column (each unit container declares 24 internal cols),
  # snapped to the standard breakpoints (quarters/thirds/halves).
  to_icol = lambda do |x|
    c = 1 + ((x - cx0) / (cx1 - cx0) * 24).round
    SigmaLayout.snap_col([[c, 1].max, 25].min)
  end
  # E1 floor keyed on the RESOLVED element's Sigma kind (the same source
  # layout_lint checks); the zone (chart_kind + plot signals) is the fallback.
  min_for = lambda do |z, eid|
    el = els_by_id[eid]
    el && el['kind'] ? kpi_min_rows(el) : SigmaLayout.min_rows_for_zone(z)
  end

  # --- units: KPI rows, section text separators, section panels ---------------
  units = []
  kpi_rows.each_with_index do |row, ki|
    ids  = []
    mins = []
    row.each do |z|
      eid = resolve_zone_el.call(z)
      next unless eid && !placed.include?(eid)
      placed << eid
      ids  << eid
      mins << min_for.call(z, eid)
    end
    next if ids.empty?
    r0 = to_row.call(row.map { |z| (z['y_pct'] || 0).to_f }.min)
    r1 = to_row.call(row.map { |z| (z['y_pct'] || 0).to_f + (z['h_pct'] || 0).to_f }.max)
    r1 = r0 + 1 if r1 <= r0
    if (r1 - r0) < mins.max
      minexp += mins.count { |m| (r1 - r0) < m }
      r1 = r0 + mins.max
    end
    units << { kind: :kpi, r0: r0, r1: r1, ids: ids, idx: ki }
  end

  separators.each_with_index do |z, si|
    eid = resolve_zone_el.call(z)
    next unless eid && !placed.include?(eid)
    placed << eid
    r0 = to_row.call((z['y_pct'] || 0).to_f)
    units << { kind: :text, r0: r0, r1: r0 + 2, id: eid, idx: si }
  end

  items = body_zones.map do |z|
    eid = resolve_zone_el.call(z)
    next nil unless eid && !placed.include?(eid)
    placed << eid
    c0 = [to_icol.call((z['x_pct'] || 0).to_f), 24].min
    c1 = [[to_icol.call((z['x_pct'] || 0).to_f + (z['w_pct'] || 0).to_f), c0 + 1].max, 25].min
    r0 = to_row.call((z['y_pct'] || 0).to_f)
    r1 = [to_row.call((z['y_pct'] || 0).to_f + (z['h_pct'] || 0).to_f), r0 + 1].max
    [eid, c0, c1, r0, r1, min_for.call(z, eid)]
  end.compact
  cluster_bands(items).each_with_index do |band, bi|
    base = band.map { |i| i[3] }.min
    # rebase rows container-relative; close horizontal gaps between row-
    # overlapping neighbours (Tableau leaves legend/spacer gaps Sigma doesn't
    # render) and stretch the rightmost tile to the container edge.
    rebased = band.map { |i| [i[0], i[1], i[2], i[3] - base + 1, i[4] - base + 1, i[5]] }
    rebased.each do |it|
      rights = rebased.select { |o| o[1] > it[1] && o[3] < it[4] && it[3] < o[4] }
      it[2] = rights.empty? ? 25 : [rights.map { |o| o[1] }.min, it[1] + 1].max
    end
    # an under-filled band (lint rule e) also closes LEFT gaps: each tile
    # stretches back to its left row-overlapping neighbour (or column 1), so a
    # lone small tile fills the row instead of shipping dead space.
    if SigmaLayout.band_fill(rebased) < MIN_BAND_FILL
      rebased.sort_by { |it| [it[1], it[3], it[0].to_s] }.each do |it|
        lefts = rebased.select { |o| !o.equal?(it) && o[1] < it[1] && o[3] < it[4] && it[3] < o[4] }
        it[1] = [lefts.empty? ? 1 : lefts.map { |o| o[2] }.max, it[2] - 1].min
        it[1] = 1 if it[1] < 1
      end
    end
    rects = rebased.map { |it| it[1, 4] }
    rects, n = SigmaLayout.expand_min_rows(rects, rebased.map { |it| it[5] })
    minexp += n
    rects = SigmaLayout.pack_rects(rects) # duplicate source rects (swap stacks) go vertical
    inner_h = rects.map { |r| r[3] }.max - 1
    units << { kind: :section, r0: base, r1: base + [inner_h, 1].max, idx: bi,
               items: rebased.each_with_index.map { |it, i| [it[0], *rects[i]] } }
  end

  # --- settle units top-to-bottom (never overlapping), then emit ---------------
  rank = { text: 0, kpi: 1, section: 2 }
  units = units.sort_by { |u| [u[:r0], rank[u[:kind]], u[:idx]] }
  urects = SigmaLayout.pack_rects(units.map { |u| [content_c0, content_c1, u[:r0], u[:r1]] })
  units.each_with_index do |u, i|
    c0, c1, r0, r1 = urects[i]
    case u[:kind]
    when :kpi
      span = r1 - r0
      cid = "#{prefix}-kpi-#{u[:idx] + 1}"
      extra_els << container_el(cid)
      nk = u[:ids].length
      inner = u[:ids].each_with_index.map do |eid, j|
        ic0 = 1 + (24 * j / nk.to_f).round
        ic1 = j == nk - 1 ? 25 : [1 + (24 * (j + 1) / nk.to_f).round, ic0 + 1].max
        le(eid, ic0, ic1, 1, 1 + span) # KPI-sliver rule: inner span == container span
      end.join("\n")
      children << gc(cid, c0, c1, r0, r1, inner)
    when :text
      children << le(u[:id], c0, c1, r0, r1)
    when :section
      cid = "#{prefix}-sec-#{u[:idx] + 1}"
      extra_els << container_el(cid)
      inner = u[:items].map { |eid, ic0, ic1, ir0, ir1| le(eid, ic0, ic1, ir0, ir1) }.join("\n")
      children << gc(cid, c0, c1, r0, r1, inner)
    end
  end
  content_bottom = (urects.map { |r| r[3] }.max || content_r0)

  # --- sidebar rail: stacked controls (+ rail texts) in source y-order --------
  rail_rect = nil
  if rail
    entries = []
    rail[:zones].each do |z|
      eid = zone_to_ctl[z['id']]
      entries << [(z['y_pct'] || 0).to_f, z['id'].to_s, eid, 3] if eid
    end
    rail[:texts].each do |z|
      el = els_by_id["text-#{z['id']}"]
      entries << [(z['y_pct'] || 0).to_f, z['id'].to_s, el['id'], 2] if el
    end
    entries = entries.sort_by { |y, zid, _, _| [y, zid] }
                     .reject { |_, _, eid, _| placed.include?(eid) }
    unless entries.empty?
      rid = "#{prefix}-rail"
      extra_els << container_el(rid)
      r = 1
      rail_inner = entries.map do |_, _, eid, h|
        placed << eid
        x = le(eid, 1, 2, r, r + h)
        r += h
        x
      end.join("\n")
      rail_r1 = [content_bottom, page_rows + 1].max
      rc0 = rail[:side] == :left ? 1 : content_c1
      rc1 = rail[:side] == :left ? 1 + rail_cols : opts[:page_cols] + 1
      rail_rect = [rc0, rc1, 1 + hdr_rows, rail_r1]
      children << gc(rid, rc0, rc1, 1 + hdr_rows, rail_r1, rail_inner, cols: 1)
    end
  end

  # --- safety net + census -----------------------------------------------------
  band_rect = safety_net_band(page, placed, extra_els, children, prefix,
                              [content_bottom, rail_rect ? rail_rect[3] : 0].max, page_rows)

  content_zones = ZoneCensus.content_zones(zones)
  placed_count = content_zones.count do |z|
    e = find_zone_el(els_by_name, z, opts[:renames])
    e && placed.include?(e['id'])
  end
  rects = []
  units.each_with_index { |u, i| rects << urects[i] unless u[:kind] == :text }
  rects << [content_c0, content_c1, 1 + hdr_rows, 1 + hdr_rows + ctl_rows] unless band_ctls.empty?
  rects << rail_rect if rail_rect
  rects << band_rect if band_rect
  fill = ZoneCensus.grid_fill_pct(rects, opts[:page_cols], page_rows)
  census = ZoneCensus.page_record(page['name'], content_zones.size, placed_count, fill)

  n_ctls = band_ctls.length + rail_ctl_ids.length
  [page_xml(page['id'], *children), extra_els, placed_count, units.length, n_ctls, census, minexp]
end

# Build one container-banded page for a single dashboard. Returns
# [page_xml_string, extra_spec_elements, n_charts, n_bands, n_controls,
#  census, min_row_expansions].
# Native trellis (fix/native-trellis, SUPERSEDES #451 B1). The parser flags a
# dashboard that repeats one viz across a categorical dimension as small
# multiples; build-charts-from-signals collapses the N member worksheets into
# ONE viz element carrying a native `trellis` property. On the layout side this
# means the group is now a SINGLE element, so we prune the absorbed SIBLING
# member zones (keeping only the base) and EXPAND the base zone to the group's
# bounding box — the one trellis element then lands full-size via the ordinary
# banded/synth path (no per-card Containers). Mutates `dashboard` in place;
# only touches a dashboard that carries `trellis`, so non-trellis output is
# byte-identical to the flat build.
def prune_trellis_zones!(dashboard)
  groups = dashboard['trellis']
  return unless groups.is_a?(Array) && !groups.empty?
  zone_by_id = (dashboard['zones'] || []).each_with_object({}) { |z, h| h[z['id']] = z if z['id'] }
  drop_ids = {}
  groups.each do |g|
    zids = Array(g['zone_ids'])
    next if zids.size < 2
    base = zone_by_id[zids.first]
    next unless base
    members = zids.map { |zid| zone_by_id[zid] }.compact
    # Expand the base zone to the union bbox of every member panel so the single
    # trellis element occupies the whole small-multiples area (not just the base
    # member's slot).
    x0 = members.map { |z| z['x_pct'].to_f }.min
    y0 = members.map { |z| z['y_pct'].to_f }.min
    x1 = members.map { |z| z['x_pct'].to_f + z['w_pct'].to_f }.max
    y1 = members.map { |z| z['y_pct'].to_f + z['h_pct'].to_f }.max
    base['x_pct'] = x0
    base['y_pct'] = y0
    base['w_pct'] = x1 - x0
    base['h_pct'] = y1 - y0
    zids[1..].each { |zid| drop_ids[zid] = true }
  end
  dashboard['zones'] = (dashboard['zones'] || []).reject { |z| drop_ids[z['id']] } unless drop_ids.empty?
end

def build_page_for_dashboard(dashboard, page, opts)
  chart_zones = dashboard['zones'].select { |z| z['kind'] == 'chart' && z['caption'] }
  els_by_name = page['elements'].each_with_object({}) { |e, h| n = el_display_name(e); h[n] = e if n }
  augment_els_by_name!(els_by_name, page['elements'])
  # Dedicated title-* element, else the source's own top banner (shared detector,
  # same as the tree + synthesis paths) — no fabricated page-name H1 alongside a
  # source title.
  zone_by_id = (dashboard['zones'] || []).each_with_object({}) { |z, h| h[z['id']] = z if z['id'] }
  title_el = detect_header_title_el(page, zone_by_id)
  ctl_els  = page['elements'].select { |e| e['kind'] == 'control' }

  # Per-dashboard copy of the band tuning — auto-fit must not leak between
  # dashboards (bead ptrt: the old script used dash_layout.first only).
  o = opts.dup

  # Auto-fit the chart band to the ACTUAL zone extents. The default
  # chart_y0=29.7 assumes a title/filter band at the top; a dashboard whose
  # charts start near y=0 would otherwise map to negative grid rows.
  zone_y0s = chart_zones.map { |z| (z['y_pct'] || 0).to_f }
  zone_y1s = chart_zones.map { |z| (z['y_pct'] || 0).to_f + (z['h_pct'] || 0).to_f }
  unless zone_y0s.empty?
    fit_y0 = zone_y0s.min
    fit_y1 = [zone_y1s.max, fit_y0 + 1].max
    if fit_y0 < o[:chart_y0]
      o[:chart_y0] = fit_y0
      o[:chart_y1] = fit_y1
    end
  end

  used_el_ids = {} # one zone per element — a duplicate Element id makes
  #   Sigma reject the whole layout PUT (same guard as the tree/synth paths)
  chart_layouts = chart_zones.map do |z|
    lookup_name = zone_el_name(z, o[:renames])
    el = find_zone_el(els_by_name, z, o[:renames])
    if el.nil?
      warn "WARN: no Sigma element matched zone caption #{z['caption'].inspect} on page #{page['name'].inspect}" \
           "#{lookup_name == z['caption'] ? " — if the tile was renamed, pass --rename #{z['caption'].inspect}'=<Sigma name>'" : " (renamed to #{lookup_name.inspect})"} — tile DROPPED from layout"
    end
    next nil unless el && !used_el_ids[el['id']]
    used_el_ids[el['id']] = true
    c1, c2, r1, r2 = chart_pos(z, o)
    { el_id: el['id'], c1: c1, c2: c2, r1: r1, r2: r2 }
  end.compact

  # Close horizontal gaps within each row (Tableau dashboards often have
  # separate legend/filter zones between chart tiles that Sigma doesn't render).
  rows = chart_layouts.group_by { |c| [c[:r1], c[:r2]] }
  rows.each_value do |row_charts|
    row_charts.sort_by! { |c| c[:c1] }
    row_charts.each_with_index do |c, i|
      next_c1 = i + 1 < row_charts.length ? row_charts[i + 1][:c1] : (o[:page_cols] + 1)
      c[:c2] = next_c1
    end
  end

  children = []
  extra_els = []
  placed = [] # element ids this path positions — feeds the shared safety net
  ov_prefix = "band-#{page['id']}"

  # Header band derived from the source (colored strip only when the source has
  # one; otherwise transparent — title on the canvas, no fabricated navy).
  hdr_style, hdr_dark = header_from_source(dashboard)
  hdr_id = "#{ov_prefix}-hdr"
  hdr_rows = HEADER_ROWS
  if title_el
    extra_els << container_el(hdr_id, hdr_style)
    children << header_band_xml(hdr_id, title_el['id'])
    placed << title_el['id']
  elsif o[:no_synthetic_title]
    # #422: synthetic banner suppressed (flag or prior-state) — no fabricated
    # page-name header; content starts at the top of the grid.
    hdr_rows = 0
  else
    extra_els << container_el(hdr_id, hdr_style)
    txt_id = "#{ov_prefix}-hdrtext"
    extra_els << header_text_el(txt_id, page['name'], hdr_dark ? '#FFFFFF' : nil)
    children << header_band_xml(hdr_id, txt_id)
  end

  # Control band: dashboard-global controls side-by-side under the header.
  n = ctl_els.length
  ctl_rows = 0
  if n > 0
    ctl_rows = 3
    col_width = (o[:page_cols].to_f / n).round
    inner = ctl_els.each_with_index.map do |c, i|
      col_start = 1 + i * col_width
      col_end   = i == n - 1 ? o[:page_cols] + 1 : col_start + col_width
      le(c['id'], col_start, col_end, 1, 1 + ctl_rows)
    end.join("\n")
    ctl_id = "#{ov_prefix}-ctl"
    extra_els << container_el(ctl_id)
    children << gc(ctl_id, 1, o[:page_cols] + 1, 1 + hdr_rows, 1 + hdr_rows + ctl_rows, inner)
    placed.concat(ctl_els.map { |c| c['id'] })
  end

  # Chart bands: cluster the zone-derived positions into row bands and shift
  # the whole chart area under the header + control bands.
  chart_items = chart_layouts.map { |c| [c[:el_id], c[:c1], c[:c2], c[:r1], c[:r2]] }
  bands = cluster_bands(chart_items)
  # E1: enforce per-kind minimum row spans (KIND_MIN_ROWS) — tiles under ~3-4
  # grid rows render BLANK in Sigma (page render AND PNG exports). Expansion
  # pushes subsequent bands down; the grid stays collision-free.
  els_by_id_full = page['elements'].each_with_object({}) { |e, h| h[e['id']] = e }
  bands, min_exp = enforce_min_rows_els(bands, els_by_id_full)
  content_start = 1 + hdr_rows + ctl_rows
  band_offset = bands.empty? ? 0 : content_start - bands.first.map { |i| i[3] }.min
  bands.each_with_index do |band, i|
    cid = "#{ov_prefix}-#{i + 1}"
    extra_els << container_el(cid)
    children << band_container_xml(cid, band, row_offset: band_offset)
    placed.concat(band.map { |it| it[0] })
  end

  # B4 (gap ubr5.8): the banded fallback places charts by geometry but not text.
  # Rather than orphan the emitted styled-text elements (present in the workbook,
  # absent from the layout), tile them across a labelled bottom band so nothing
  # silently drops — WARN, since their exact source position isn't reproduced in
  # the banded path (the container-tree path DOES place them at zone geometry).
  text_els = page['elements'].select { |e| e['kind'] == 'text' && e['id'].to_s.start_with?('text-') }
  unless text_els.empty?
    tn = text_els.length
    r0 = 1 + hdr_rows + ctl_rows + bands.sum { |b| b.map { |i| i[4] }.max - b.map { |i| i[3] }.min }
    inner = text_els.each_with_index.map do |e, i|
      c0 = 1 + (o[:page_cols] * i / tn.to_f).round
      c1 = i == tn - 1 ? o[:page_cols] + 1 : [1 + (o[:page_cols] * (i + 1) / tn.to_f).round, c0 + 1].max
      le(e['id'], c0, c1, 1, 4)
    end.join("\n")
    tid = "#{ov_prefix}-text"
    extra_els << container_el(tid)
    children << gc(tid, 1, o[:page_cols] + 1, r0, r0 + 4, inner)
    placed.concat(text_els.map { |e| e['id'] })
    warn "WARN: #{tn} styled-text element(s) placed in a bottom band on banded page #{page['name'].inspect} " \
         "(source position not reproduced — the container-tree layout places them by geometry): " \
         "#{text_els.map { |e| e['id'] }.join(', ')}"
  end

  # Safety net (orphan-element invariant — parity with the tree + synthesized
  # paths, which already had one): any placeable element the banded path did
  # not position (an image/button with no band, a stray text) lands in a
  # bottom band. An element in the built page but absent from the layout is
  # auto-flowed by Sigma as a stray white card (bottom-left), so NOTHING may
  # be left unreferenced.
  content_bottom = 1 + hdr_rows + ctl_rows +
                   bands.sum { |b| b.map { |i| i[4] }.max - b.map { |i| i[3] }.min } +
                   (text_els.empty? ? 0 : 4)
  band_rect = safety_net_band(page, placed, extra_els, children, ov_prefix,
                              content_bottom, o[:page_rows])

  # ---- Layout census (gate 8c, #259) ----------------------------------------
  # zones  = non-furniture source content zones (real plotting tiles).
  # placed = those that resolved to a Sigma element (chart_pos always places a
  #          resolved zone, so a resolved content zone == a placed tile).
  # rects  = PAGE-absolute grid footprints of the placed tiles (the ENFORCED
  #          band items, shifted by band_offset) plus the control band —
  #          furniture (header band, styled-text band) excluded from the fill
  #          numerator.
  content_zones = ZoneCensus.content_zones(dashboard['zones'])
  placed_count = content_zones.count { |z| find_zone_el(els_by_name, z, o[:renames]) }
  content_rects = bands.flat_map { |b| b.map { |i| [i[1], i[2], i[3] + band_offset, i[4] + band_offset] } }
  content_rects << [1, o[:page_cols] + 1, 1 + hdr_rows, 1 + hdr_rows + ctl_rows] if ctl_els.length.positive?
  content_rects << band_rect if band_rect # safety band holds real tiles → counts as filled
  fill = ZoneCensus.grid_fill_pct(content_rects, o[:page_cols], o[:page_rows])
  census = ZoneCensus.page_record(page['name'], content_zones.size, placed_count, fill)

  [page_xml(page['id'], *children), extra_els, chart_layouts.length, bands.length, ctl_els.length,
   census, min_exp]
end

# Place EVERY hidden Data-page element. Layout is the authoritative page
# membership map in workbook code-rep; leaving helpers unreferenced is no
# longer an auto-flow convenience, it is an invalid document.
data_row = 1
master_les = data_page['elements'].map do |element|
  height = [WorkbookCode.row_span(element), 10].max
  xml = le(element['id'], 1, opts[:page_cols] + 1, data_row, data_row + height)
  data_row += height
  xml
end
data_page_xml = page_xml(data_page['id'], *master_les)

# ---- Layout-arrangement parity record (PLAN-v3 PR-11; WARN-level release) ---
# Compares the SOURCE zone arrangement (normalized bboxes) against the BUILT
# grid (page XML flattened to page-absolute rects): row-band ordering,
# within-band left-right ordering, quadrant agreement, and the controls-shelf
# placement class (top-shelf vs sidebar). Ordering/class only — no pixel IoU,
# so grid quantization/row scaling never false-fires. Advisory: a lint crash
# must never sink the layout build.
def arrangement_record(dashboard, page, pxml, o)
  els_by_name = page['elements'].each_with_object({}) { |e, h| n = el_display_name(e); h[n] = e if n }
  augment_els_by_name!(els_by_name, page['elements'])
  built_rects = ArrangementLint.absolute_rects(pxml, page_cols: o[:page_cols])
  zrect = lambda do |z|
    [z['x_pct'].to_f, z['x_pct'].to_f + z['w_pct'].to_f,
     z['y_pct'].to_f, z['y_pct'].to_f + z['h_pct'].to_f]
  end
  source_items = []
  built_items = []
  seen_el = {}
  ZoneCensus.content_zones(dashboard['zones']).each do |z|
    el = find_zone_el(els_by_name, z, o[:renames])
    next unless el && built_rects[el['id']] && !seen_el[el['id']]
    seen_el[el['id']] = true
    source_items << { name: z['caption'].to_s, role: 'tile', rect: zrect.call(z) }
    built_items  << { name: z['caption'].to_s, role: 'tile', rect: built_rects[el['id']] }
  end
  (dashboard['zones'] || []).each do |z|
    next unless %w[filter parameter].include?(z['kind'].to_s)
    source_items << { name: (z['filter_column_caption'] || z['id']).to_s,
                      role: 'control', rect: zrect.call(z) }
  end
  page['elements'].each do |e|
    next unless e['kind'].to_s == 'control' && built_rects[e['id']]
    built_items << { name: e['id'].to_s, role: 'control', rect: built_rects[e['id']] }
  end
  ArrangementLint.compare_page(page['name'], source_items, built_items)
rescue StandardError => e
  warn "WARN: arrangement lint failed for #{dashboard['dashboard'].inspect} " \
       "(#{e.class}: #{e.message}) — layout-arrangement.json record skipped for this page"
  nil
end

page_xmls = [data_page_xml]
sidecar = {}
census_pages = []
arrangement_pages = []
totals = { charts: 0, bands: 0, controls: 0 }
bands_detected = { 'header' => false, 'kpi_rows' => 0, 'sidebar' => false }
min_row_expansions = 0
dash_layout.each do |d|
  page = page_for_dash[d['dashboard']]
  next unless page
  # Native trellis (SUPERSEDES #451): build-charts collapsed each detected
  # small-multiples group into ONE element (regardless of layout flags), so prune
  # the absorbed sibling member zones and expand the base zone to the group bbox
  # BEFORE any layout path runs (structure detection, banded/synth/tree all read
  # d['zones']). Gated on `trellis` → non-trellis dashboards are untouched
  # (byte-identical). Unconditional: the collapse already happened in the spec.
  prune_trellis_zones!(d)
  # v5.1 defect 1 — px-derived page height, PER DASHBOARD (multi-dashboard
  # workbooks carry one canvas_px each; the theme's maxPageWidth stays
  # first-dashboard-global — theme_derive — an accepted caveat). A fixed-size
  # canvas maps rows at SIGMA_ROW_PX (28px) so zone→row mapping reproduces
  # source px exactly and the E1 floors become true px floors; row_scale is
  # NEUTRALIZED (the 1.5x scale existed only to compensate the 32-row default's
  # underestimate). Explicit --page-rows always wins. No canvas_px → the legacy
  # page_rows * row_scale mapping, byte-identical.
  o = opts.dup
  cpx = d['canvas_px']
  canvas_rows = nil
  if cpx.is_a?(Hash) && cpx['sizing_mode'] == 'fixed' && cpx['h'].to_i >= 400
    canvas_rows = [[(cpx['h'].to_f / SigmaLayout::SIGMA_ROW_PX).round, 24].max, 400].min
  end
  # An explicit --page-rows OR --row-scale is an operator override of the row
  # model — the px derivation would silently neutralize it (review-caught:
  # row_scale_explicit was recorded but never honored).
  if !o[:page_rows_explicit] && !o[:row_scale_explicit] && canvas_rows
    o[:page_rows] = canvas_rows
    o[:row_scale] = 1.0
    warn "px-derived rows: #{d['dashboard'].inspect} canvas #{cpx['w']}x#{cpx['h']} → " \
         "#{o[:page_rows]} rows (row-scale neutralized)"
  elsif o[:row_scale] != 1.0
    o[:page_rows] = (o[:page_rows] * o[:row_scale]).round
  end
  # E2 structure detection runs on every dashboard (pure geometry over the
  # flat zone list) — it picks the synthesized path AND feeds the census's
  # bands_detected telemetry regardless of which path ends up building.
  structure = SigmaLayout.detect_bands(d['zones'])
  bands_detected['header'] ||= structure[:header].any?
  bands_detected['kpi_rows'] += structure[:kpi_rows].length
  bands_detected['sidebar'] ||= !structure[:sidebar].nil?
  use_synth = !o[:no_containers] && (structure[:sidebar] || structure[:kpi_rows].any?)
  use_tree  = !o[:no_containers] &&
              (tree_has_controls?(d['zone_tree']) || tree_has_styled_containers?(d['zone_tree']))
  result = nil
  if use_synth
    begin
      result = build_page_synthesized(d, page, o, structure)
      warn "synthesized layout: #{d['dashboard'].inspect} → " \
           "#{structure[:kpi_rows].length} KPI row(s), " \
           "#{structure[:sidebar] ? "#{structure[:sidebar][:side]} sidebar rail" : 'no sidebar'}, " \
           "#{structure[:header].any? ? 'source header text' : 'derived header'}"
    rescue StandardError => e
      warn "WARN: synthesized layout failed for #{d['dashboard'].inspect} (#{e.class}: #{e.message}) — falling back"
    end
  end
  if result.nil? && use_tree
    begin
      result = build_page_from_tree(d, page, o)
      warn "container-tree layout: #{d['dashboard'].inspect} → nested Sigma containers (filters/params placed in their Tableau container)"
    rescue StandardError => e
      warn "WARN: container-tree layout failed for #{d['dashboard'].inspect} (#{e.class}: #{e.message}) — falling back to banded layout"
    end
  end
  result ||= build_page_for_dashboard(d, page, o)
  pxml, extra_els, n_charts, n_bands, n_ctls, census, n_minexp = result
  if census
    # Telemetry for the page-height budget (v5.1): rows actually built vs the
    # canvas-implied row count (present only for fixed-px sources).
    census['rows'] = o[:page_rows]
    census['canvas_rows'] = canvas_rows if canvas_rows
    # ---- Placement invariant (orphan-element guard) -------------------------
    # NO element in the built page may be absent from the layout bands: Sigma
    # auto-flows an unreferenced element as a stray white card (bottom-left;
    # live-caught on the synthetic dashboard title). Authoritative check —
    # scan the page XML the chosen path actually emitted rather than trusting
    # per-path bookkeeping. Gate 8c (assert-phase6-ran.rb) fails on a
    # non-empty list.
    refd = pxml.scan(/elementId="([^"]+)"/).flatten
    explicitly_pruned = opts[:pruned_elements]
                        .select { |record| record['page_id'] == page['id'] }
                        .map { |record| record['element_id'] }
    unplaced = page['elements'].select do |e|
      k = e['kind'].to_s
      (k.end_with?('-chart') || %w[table pivot-table control text image button].include?(k)) &&
        e['id'] && !refd.include?(e['id']) && !explicitly_pruned.include?(e['id'])
    end.map { |e| e['id'] }
    census['unplaced_elements'] = unplaced
    census['pruned_elements'] = explicitly_pruned.sort
    if unplaced.any?
      warn "WARN: #{unplaced.length} element(s) on page #{page['name'].inspect} are absent from the " \
           "built layout — Sigma will auto-flow them as stray cards: #{unplaced.join(', ')}"
    end
    # Synthetic dashboard-title accounting: when the source .twb declared NO
    # header text zone, the header band carrying the synthetic "title-*"
    # element is layout the zones never described — note it and COUNT the
    # title in zones/placed so the census reflects what the page shows (it
    # used to be invisible to gate 8c).
    syn_title = page['elements'].find { |e| e['kind'].to_s == 'text' && e['id'].to_s.start_with?('title') }
    if syn_title && structure[:header].empty? && refd.include?(syn_title['id'])
      census['zones'] += 1
      census['placed'] += 1
      census['synthetic_header'] = true
    end
  end
  if (arr = arrangement_record(d, page, pxml, o))
    arr['violations'].each { |v| warn "ARRANGEMENT WARN (#{page['name'].inspect}): #{v}" }
    arrangement_pages << arr
  end
  page_xmls << pxml
  sidecar[page['id']] = extra_els
  census_pages << census if census
  totals[:charts] += n_charts
  totals[:bands] += n_bands
  totals[:controls] += n_ctls
  min_row_expansions += n_minexp.to_i
end

layout_out = assemble(*page_xmls) + "\n"

# Preserve workbook-local pipeline pages that have no Tableau dashboard zone
# counterpart (hidden inputs/data/derived pages, joins, unions, sub-masters).
# Previously the builder validated against ALL declared elements but generated
# layout only for source dashboards, so a valid reused pipeline failed as
# "missing elements" and the orchestrator fell back to a stacked layout.
laid_out_page_ids = layout_out.scan(/<Page\b[^>]*\bid="([^"]+)"/).flatten
preserved_pages = []
WorkbookCode.pages(wb_ids_raw).each do |page|
  page_id = page['id'].to_s
  next if page_id.empty? || laid_out_page_ids.include?(page_id)
  page_elements = WorkbookCode.elements_for_page(wb_ids_raw, page)
  next if page_elements.empty?
  layout_out << "#{WorkbookCode.page_xml(page_id, page_elements)}\n"
  preserved_pages << { 'id' => page_id, 'name' => page['name'], 'elements' => page_elements.length }
end
unless preserved_pages.empty?
  warn "preserved #{preserved_pages.length} non-dashboard pipeline page(s): " +
       preserved_pages.map { |page| "#{page['name'] || page['id']} (#{page['elements']})" }.join(', ')
end

# Documented output-shape guard: an empty elementId is always a builder bug
# and makes Sigma reject the whole layout PUT.
abort 'FATAL: empty elementId in generated layout XML — builder bug' if layout_out.include?('elementId=""')
declared_ids = WorkbookCode.elements(wb_ids_raw).filter_map { |element| element['id'] } +
               sidecar.values.flatten.filter_map { |element| element['id'] }
layout_ids = layout_out.scan(/elementId="([^"]+)"/).flatten
duplicate_ids = layout_ids.tally.select { |_, count| count > 1 }.keys
prune_records = opts[:pruned_elements].sort_by do |record|
  [record['page_id'].to_s, record['element_id'].to_s, record['zone_id'].to_s]
end
prune_ids = prune_records.map { |record| record['element_id'] }
invalid_pruned = prune_records.reject do |record|
  record['reason'] == 'manual-composite' && !record['element_id'].to_s.empty? &&
    declared_ids.count(record['element_id']) == 1 && !layout_ids.include?(record['element_id'])
end
duplicate_pruned = prune_ids.tally.select { |_, count| count > 1 }.keys
missing_ids = declared_ids - layout_ids - prune_ids
unknown_ids = layout_ids - declared_ids
unless duplicate_ids.empty? && missing_ids.empty? && unknown_ids.empty? &&
       invalid_pruned.empty? && duplicate_pruned.empty?
  abort "FATAL: generated layout must place every element exactly once " \
        "(duplicates=#{duplicate_ids.inspect}, missing=#{missing_ids.inspect}, unknown=#{unknown_ids.inspect}, " \
        "invalid_explicit_prunes=#{invalid_pruned.inspect}, duplicate_explicit_prunes=#{duplicate_pruned.inspect})"
end
File.write(opts[:out], layout_out)
File.write("#{opts[:out]}.elements.json", JSON.pretty_generate(sidecar))
prune_path = "#{opts[:out]}.prune-elements.json"
File.write(prune_path, JSON.pretty_generate({
  'version' => 1,
  'elements' => prune_records
}) + "\n")

# ---- layout-census.json (gate 8c producer, #259) --------------------------
# One record per dashboard page (zones / placed / dropped / grid_fill_pct) —
# shape kept exactly compatible. Per-page additions (orphan invariant):
#   unplaced_elements  ids in the built page but ABSENT from the layout XML
#                      (gate 8c fails on non-empty — Sigma auto-flows these
#                      as stray cards)
#   pruned_elements     ids deliberately omitted under the explicit
#                      manual-composite contract; put-layout removes them
#                      from flat document.elements before validating/PUT
#   synthetic_header   true when the header band carries the synthetic
#                      "title-*" element with no source header zone (the
#                      title is then counted in zones/placed)
# Top-level additions (telemetry, E3):
#   bands_detected     {header:bool, kpi_rows:N, sidebar:bool} across pages
#   min_row_expansions N tiles grown to their per-kind minimum row span
census_out = opts[:census_out] || File.join(File.dirname(opts[:out]), 'layout-census.json')
File.write(census_out, JSON.pretty_generate({
  'pages' => census_pages,
  'bands_detected' => bands_detected,
  'min_row_expansions' => min_row_expansions
}) + "\n")

# ---- layout-arrangement.json (gate 8e producer, PLAN-v3 PR-11) ------------
# One record per dashboard page comparing the SOURCE zone arrangement against
# the BUILT grid: row-band ordering, within-band left-right ordering, quadrant
# agreement, controls-shelf placement class. enforcement:"warn" this release —
# assert-phase6-ran.rb prints the violations as advisory WARNs unless the
# caller opts into blocking with --require-arrangement (gate 8e, exit 29).
arr_out = File.join(File.dirname(opts[:out]), 'layout-arrangement.json')
arr_total = arrangement_pages.sum { |p| p['violations'].length }
File.write(arr_out, JSON.pretty_generate({
  'pages' => arrangement_pages,
  'violations_total' => arr_total,
  'enforcement' => 'warn',
  'generated_by' => 'build-dashboard-layout.rb'
}) + "\n")

# Per-page row report (v5.1): rows are resolved per dashboard (px-derived when
# the source canvas is fixed), so a single global row count no longer exists.
rows_report = census_pages.map do |c|
  "#{c['page']}=#{c['rows']}#{c['canvas_rows'] ? " (px-derived #{c['canvas_rows']})" : ''}"
end.join(', ')
puts "wrote #{opts[:out]} (#{page_for_dash.size} dashboard page(s): #{totals[:charts]} charts in #{totals[:bands]} band container(s), " \
     "#{totals[:controls]} controls, header bands, gap-closing applied, rows: #{rows_report})"
puts "wrote #{opts[:out]}.elements.json (#{sidecar.values.sum(&:length)} container/header spec element(s) — put-layout.rb injects these)"
puts "wrote #{prune_path} (#{prune_records.length} explicit manual-composite element prune(s) — put-layout.rb removes these before PUT)"
puts "wrote #{census_out} (#{census_pages.size} page census record(s): " \
     "#{census_pages.map { |c| "#{c['page']} #{c['placed']}/#{c['zones']} tiles, fill #{(c['grid_fill_pct'] * 100).round}%" }.join('; ')})"
puts "wrote #{arr_out} (#{arrangement_pages.size} page arrangement record(s), " \
     "#{arr_total} violation(s)#{arr_total.positive? ? ' — see ARRANGEMENT WARN lines above' : ''})"

if opts[:ir]
  WorkbookIR.emit(
    File.dirname(opts[:layout]),
    out: opts[:ir],
    overrides: {
      'layout_xml' => opts[:out],
      'layout_elements' => "#{opts[:out]}.elements.json",
      'layout_census' => census_out,
      'layout_arrangement' => arr_out
    }
  )
  puts "refreshed workbook IR #{opts[:ir]}"
end
