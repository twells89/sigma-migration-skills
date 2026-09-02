#!/usr/bin/env ruby
#!/usr/bin/env ruby
# ── VENDORED (do not edit here) ──────────────────────────────────────────────
# Source: twells89/sigma-migration-skills @ a73f833
#   plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-dashboard-layout.rb
# Fix upstream and re-vendor; do not diverge this copy. Vendored for the
# standalone domo-sigma-migration repo (clone-safety) per the domo-build-pipeline plan.
# ─────────────────────────────────────────────────────────────────────────────

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
#   --chart-y0 PCT   top of the chart band as Tableau %  (default 29.7)
#   --chart-y1 PCT   bottom of the chart band as Tableau % (default 100.0)
#   --chart-row0 N   first grid row of the chart band     (default 6)

require 'json'
require 'optparse'
require_relative 'lib/layout'
require_relative 'lib/code_rep'
require_relative 'lib/zone_census'
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
         chart_y1: 100.0, chart_row0: 6, renames: {} }
OptionParser.new do |p|
  p.on('--layout PATH')        { |v| opts[:layout] = v }
  p.on('--wb-ids PATH')        { |v| opts[:wb_ids] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--census-out PATH', 'per-page fill/coverage census for gate 8c (default: layout-census.json beside --out)') { |v| opts[:census_out] = v }
  p.on('--page-cols N',  Integer) { |v| opts[:page_cols] = v }
  p.on('--page-rows N',  Integer) { |v| opts[:page_rows] = v }
  p.on('--row-scale F',  Float, 'row-height multiplier (default 1.5; min label-safe ~1.43)') { |v| opts[:row_scale] = v }
  p.on('--rename PAIR', 'Tableau-name=Sigma-name (repeat) — matches the parity scripts\' flag') do |v|
    from, to = v.split('=', 2)
    abort("--rename expects 'Tableau name=Sigma name', got #{v.inspect}") if from.nil? || to.nil? || from.empty? || to.empty?
    opts[:renames][from] = to
  end
  p.on('--chart-y0 PCT', Float)   { |v| opts[:chart_y0] = v }
  p.on('--chart-y1 PCT', Float)   { |v| opts[:chart_y1] = v }
  p.on('--chart-row0 N', Integer) { |v| opts[:chart_row0] = v }
  p.on('--no-containers', 'force the geometry-banded layout even when the dashboard nests a filter/parameter rail') { opts[:no_containers] = true }
end.parse!
%i[layout wb_ids out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

# Row scaling (bead tkkv): scale the page's row count so each chart band tile
# gets proportionally more rows. Title (rows 1-3) and controls (rows 3-6) keep
# their fixed positions; only the chart band [chart_row0..page_rows] stretches.
opts[:page_rows] = (opts[:page_rows] * opts[:row_scale]).round if opts[:row_scale] != 1.0

dash_layout = JSON.parse(File.read(opts[:layout]))
wb_ids      = JSON.parse(File.read(opts[:wb_ids]))

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
dash_layout.each do |d|
  pg = content_pages.find { |p| p['name'] == d['dashboard'] }
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
  # Released page-break elements are fixed to exactly one grid row.
  row_end = row_start + 1 if z['chart_kind'] == 'page-break'
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
    (n['kind'] == 'container' && (n['fill_color'] || n['border_color'])) ||
      tree_has_styled_containers?(n['children'])
  end
end

# Place a child within its parent container's internal 24-col grid from pct
# bounds. parent_rows = grid row-lines the parent spans internally.
def place_in_parent(ch, p, parent_rows)
  pw = (p['w_pct'] || 100).to_f; pw = 1.0 if pw <= 0
  ph = (p['h_pct'] || 100).to_f; ph = 1.0 if ph <= 0
  px = (p['x_pct'] || 0).to_f;   py = (p['y_pct'] || 0).to_f
  cx = (ch['x_pct'] || 0).to_f;  cy  = (ch['y_pct'] || 0).to_f
  cw = (ch['w_pct'] || 0).to_f;  chh = (ch['h_pct'] || 0).to_f
  c0 = clampc(1 + ((cx - px) / pw * 24).round, 1, 24)
  c1 = clampc(1 + ((cx + cw - px) / pw * 24).round, c0 + 1, 25)
  r0 = [1, 1 + ((cy - py) / ph * parent_rows).round].max
  r1 = [r0 + 1, 1 + ((cy + chh - py) / ph * parent_rows).round].max
  [c0, c1, r0, r1]
end

# Resolve a leaf zone to an existing workbook element id (chart by caption,
# filter/param control by target-column / caption, title text to the page
# title). Returns nil for zones Sigma renders inline (legend) or drops (spacer).
def resolve_leaf(node, ctx)
  case node['kind']
  when 'chart'
    name = ctx[:renames][node['caption']] || node['caption']
    # Builder-synthesized content (v4 HEADER/PAGE_BREAK) carries the final
    # element id as its zone id. Ordinary Domo card zones still resolve by
    # display name because their source card id differs from `el-<cardId>`.
    el = ctx[:els_by_id][node['id'].to_s] || ctx[:els_by_name][name]
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
  if node['kind'] == 'container'
    kids = node['children'] || []
    my_rows = [r1 - r0, 2].max
    rects = kids.map { |ch| place_in_parent(ch, node, my_rows) }
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
    cstyle = nil
    if node['fill_color']
      cstyle = { 'backgroundColor' => node['fill_color'], 'borderRadius' => 'round' }
      cstyle['borderColor'] = node['border_color'] if node['border_color']
    end
    ctx[:extra] << container_el(cid, cstyle)
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
            SigmaLayout.min_rows_for(el['kind'])
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
      # section/column header → thin band; multi-line or long text keeps its height.
      zone = ctx[:zone_by_id][node['id']] || node
      runs = zone.is_a?(Hash) ? (zone['text_runs'] || []) : []
      txt = runs.map { |r| r['text'].to_s }.join
      clean = txt.gsub(/\s+/, ' ').strip
      multiline = txt.include?("\n") || runs.any? { |r| r['break'] }
      maxr = SigmaLayout::HEADER_BAND_MAX_ROWS if !clean.empty? && clean.length <= 60 && !multiline
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
def safety_net_band(page, placed, extra_els, children, prefix, below_row, page_rows)
  placeable = lambda do |e|
    k = e['kind'].to_s
    k.end_with?('-chart') ||
      %w[table pivot-table control text image divider embed navigation progress page-break].include?(k)
  end
  unplaced = page['elements'].select { |e| placeable.call(e) && !placed.include?(e['id']) }
  return nil if unplaced.empty?
  n = unplaced.length
  rows_needed = unplaced.map { |e| SigmaLayout.min_rows_for(e['kind']) }.max
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
       "#{unplaced.map { |e| e['name'] || e['id'] }.join(', ')}"
  [1, 25, band_r0, band_r0 + rows_needed]
end

# Container-tree page builder. Same return shape as build_page_for_dashboard.
def build_page_from_tree(dashboard, page, opts)
  tree        = dashboard['zone_tree'] || []
  els_by_name = page['elements'].each_with_object({}) { |e, h| h[e['name']] = e if e['name'] }
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
          extra: [], placed: [], zone_to_ctl: {}, zone_by_id: zone_by_id, min_row_expansions: 0 }

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
  body_rows = [page_rows - HEADER_ROWS, 4].max
  page_pseudo = { 'x_pct' => 0.0, 'y_pct' => 0.0, 'w_pct' => 100.0, 'h_pct' => 100.0 }

  # Header band derived from the source (colored strip only when the source has
  # one; otherwise transparent — title on the canvas, no fabricated navy).
  hdr_style, hdr_dark = header_from_source(dashboard)
  hdr_id = "tc-#{page['id']}-hdr"
  extra_els << container_el(hdr_id, hdr_style)
  if title_el
    children << header_band_xml(hdr_id, title_el['id'])
    ctx[:title_used] = true
    # Mark the title element as PLACED so the unplaced-elements safety net below
    # doesn't append it a SECOND time in the bottom band — a duplicate element id
    # makes Sigma reject the whole layout PUT ("Duplicate layout element id"),
    # dropping the page to a stacked fallback. (The banded path is immune: its
    # text-band selector only matches ids starting "text-", never "title".)
    ctx[:placed] << title_el['id']
  else
    txt_id = "tc-#{page['id']}-hdrtext"
    extra_els << header_text_el(txt_id, page['name'], hdr_dark ? '#FFFFFF' : nil)
    children << header_band_xml(hdr_id, txt_id)
  end

  # Top-level zones → page children, shifted below the header band. PLAN every
  # node first (E1 minimum-row floors can grow a node), then settle the grown
  # rects collision-free (pack_rects pushes lower bands down) and emit at the
  # final cells. Collect the PAGE-absolute footprint of every top-level node
  # that actually placed (gate 8c fill numerator — a top-level container's
  # rect covers its nested tiles).
  content_rects = []
  plans = []
  tree.each do |node|
    c0, c1, r0, r1 = place_in_parent(node, page_pseudo, body_rows)
    r0 += HEADER_ROWS; r1 += HEADER_ROWS
    pl = plan_node(node, c0, c1, r0, r1, ctx)
    next unless pl
    plans << [[c0, c1, r0, [r1, r0 + pl[0]].max], pl[1]]
  end
  packed = SigmaLayout.pack_rects(plans.map { |rc, _| rc })
  plans.each_with_index do |(_, ep), i|
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
    e = els_by_name[zone_el_name(z, opts[:renames])]
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

def detect_header_title_el(page, zone_by_id)
  title_el = page['elements'].find { |e| e['kind'] == 'text' && e['id'].to_s.start_with?('title') }
  return title_el if title_el
  zid = ->(e) { e['id'].to_s.sub(/\Atext-/, '') }
  page['elements'].select { |e| e['kind'] == 'text' }
                  .map { |e| [e, zone_by_id[zid.call(e)]] }
                  .select { |_e, z| z && z['y_pct'].to_f < 12 && z['w_pct'].to_f >= 40 }
                  .min_by { |_e, z| z['y_pct'].to_f }&.first
end

def build_page_synthesized(dashboard, page, opts, structure)
  zones       = dashboard['zones'] || []
  els_by_name = page['elements'].each_with_object({}) { |e, h| h[e['name']] = e if e['name'] }
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

  # Screenshot-transcribed collection headers are section separators, never
  # page-title chrome. Keep them in the content flow even when the first one
  # sits at y≈0; otherwise Salesforce + Google Analytics get packed side by
  # side into the single page-header band and every later section shifts.
  header_zones = Array(structure[:header]).reject {
    |z| z['id'].to_s.start_with?('observed-section-')
  }
  kpi_rows     = structure[:kpi_rows]
  rail         = structure[:sidebar]

  # --- header band (rows 1..1+HEADER_ROWS) -----------------------------------
  hdr_style, hdr_dark = header_from_source(dashboard)
  hdr_id = "#{prefix}-hdr"
  extra_els << container_el(hdr_id, hdr_style)
  hdr_ids = []
  if title_el
    placed << title_el['id']
    hdr_ids << title_el['id']
  else
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
  nh = hdr_ids.length
  hdr_inner = hdr_ids.each_with_index.map do |eid, i|
    c0 = 1 + (24 * i / nh.to_f).round
    c1 = i == nh - 1 ? 25 : [1 + (24 * (i + 1) / nh.to_f).round, c0 + 1].max
    le(eid, c0, c1, 1, 1 + HEADER_ROWS)
  end.join("\n")
  children << gc(hdr_id, 1, 25, 1, 1 + HEADER_ROWS, hdr_inner)

  # --- controls: sidebar rail vs top control band -----------------------------
  control_zones = zones.select { |z| %w[filter parameter].include?(z['kind'].to_s) }
                       .sort_by { |z| [(z['y_pct'] || 0).to_f, (z['x_pct'] || 0).to_f, z['id'].to_s] }
  zone_to_ctl  = assign_controls(control_zones, page['elements'])
  rail_ctl_ids = rail ? rail[:zones].map { |z| zone_to_ctl[z['id']] }.compact.uniq : []
  band_ctls    = page['elements'].select { |e| e['kind'] == 'control' && !rail_ctl_ids.include?(e['id']) }

  ctl_rows   = band_ctls.empty? ? 0 : 3
  content_r0 = 1 + HEADER_ROWS + ctl_rows
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
    children << gc(ctl_id, content_c0, content_c1, 1 + HEADER_ROWS, 1 + HEADER_ROWS + ctl_rows, ctl_inner)
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
      # Screenshot-observed layouts can carry the exact workbook element id
      # (notably companion KPIs whose human labels repeat: "Change over 7
      # Days", "New Visits in Period"). Prefer that exact join before the
      # legacy name fallback, which can map every duplicate label to one tile
      # and strand the others in the generic bottom band.
      zid = z['id'].to_s
      el = els_by_id[zid] || els_by_id["el-#{zid}"] ||
           els_by_id.values.find { |candidate|
             candidate['id'].to_s.start_with?("el-#{zid}-plugin-")
           } ||
           els_by_name[zone_el_name(z, opts[:renames])]
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
    base = el && el['kind'] ? SigmaLayout.min_rows_for(el['kind']) : SigmaLayout.min_rows_for_zone(z)
    if z['_source'].to_s.start_with?('observed-from-screenshot') &&
       z['chart_kind'].to_s != 'kpi'
      [base, 10].max
    else
      base
    end
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
      rail_rect = [rc0, rc1, 1 + HEADER_ROWS, rail_r1]
      children << gc(rid, rc0, rc1, 1 + HEADER_ROWS, rail_r1, rail_inner, cols: 1)
    end
  end

  # --- safety net + census -----------------------------------------------------
  band_rect = safety_net_band(page, placed, extra_els, children, prefix,
                              [content_bottom, rail_rect ? rail_rect[3] : 0].max, page_rows)

  content_zones = ZoneCensus.content_zones(zones)
  placed_count = content_zones.count do |z|
    e = els_by_name[zone_el_name(z, opts[:renames])]
    e && placed.include?(e['id'])
  end
  rects = []
  units.each_with_index { |u, i| rects << urects[i] unless u[:kind] == :text }
  rects << [content_c0, content_c1, 1 + HEADER_ROWS, 1 + HEADER_ROWS + ctl_rows] unless band_ctls.empty?
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
def build_page_for_dashboard(dashboard, page, opts)
  chart_zones = dashboard['zones'].select { |z| z['kind'] == 'chart' && z['caption'] }
  els_by_name = page['elements'].each_with_object({}) { |e, h| h[e['name']] = e if e['name'] }
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

  chart_layouts = chart_zones.map do |z|
    lookup_name = zone_el_name(z, o[:renames])
    el = els_by_name[lookup_name]
    if el.nil?
      warn "WARN: no Sigma element matched zone caption #{z['caption'].inspect} on page #{page['name'].inspect}" \
           "#{lookup_name == z['caption'] ? " — if the tile was renamed, pass --rename #{z['caption'].inspect}'=<Sigma name>'" : " (renamed to #{lookup_name.inspect})"} — tile DROPPED from layout"
    end
    next nil unless el
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
  ov_prefix = "band-#{page['id']}"

  # Header band derived from the source (colored strip only when the source has
  # one; otherwise transparent — title on the canvas, no fabricated navy).
  hdr_style, hdr_dark = header_from_source(dashboard)
  hdr_id = "#{ov_prefix}-hdr"
  extra_els << container_el(hdr_id, hdr_style)
  if title_el
    children << header_band_xml(hdr_id, title_el['id'])
  else
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
    children << gc(ctl_id, 1, o[:page_cols] + 1, 1 + HEADER_ROWS, 1 + HEADER_ROWS + ctl_rows, inner)
  end

  # Chart bands: cluster the zone-derived positions into row bands and shift
  # the whole chart area under the header + control bands.
  chart_items = chart_layouts.map { |c| [c[:el_id], c[:c1], c[:c2], c[:r1], c[:r2]] }
  bands = cluster_bands(chart_items)
  # E1: enforce per-kind minimum row spans (KIND_MIN_ROWS) — tiles under ~3-4
  # grid rows render BLANK in Sigma (page render AND PNG exports). Expansion
  # pushes subsequent bands down; the grid stays collision-free.
  kind_by_id = page['elements'].each_with_object({}) { |e, h| h[e['id']] = e['kind'] }
  bands, min_exp = SigmaLayout.enforce_min_rows(bands, kind_by_id)
  content_start = 1 + HEADER_ROWS + ctl_rows
  band_offset = bands.empty? ? 0 : content_start - bands.first.map { |i| i[3] }.min
  bands.each_with_index do |band, i|
    cid = "#{ov_prefix}-#{i + 1}"
    extra_els << container_el(cid)
    children << band_container_xml(cid, band, row_offset: band_offset)
  end

  # B4 (gap ubr5.8): the banded fallback places charts by geometry but not text.
  # Rather than orphan the emitted styled-text elements (present in the workbook,
  # absent from the layout), tile them across a labelled bottom band so nothing
  # silently drops — WARN, since their exact source position isn't reproduced in
  # the banded path (the container-tree path DOES place them at zone geometry).
  text_els = page['elements'].select { |e| e['kind'] == 'text' && e['id'].to_s.start_with?('text-') }
  unless text_els.empty?
    tn = text_els.length
    r0 = 1 + HEADER_ROWS + ctl_rows + bands.sum { |b| b.map { |i| i[4] }.max - b.map { |i| i[3] }.min }
    inner = text_els.each_with_index.map do |e, i|
      c0 = 1 + (o[:page_cols] * i / tn.to_f).round
      c1 = i == tn - 1 ? o[:page_cols] + 1 : [1 + (o[:page_cols] * (i + 1) / tn.to_f).round, c0 + 1].max
      le(e['id'], c0, c1, 1, 4)
    end.join("\n")
    tid = "#{ov_prefix}-text"
    extra_els << container_el(tid)
    children << gc(tid, 1, o[:page_cols] + 1, r0, r0 + 4, inner)
    warn "WARN: #{tn} styled-text element(s) placed in a bottom band on banded page #{page['name'].inspect} " \
         "(source position not reproduced — the container-tree layout places them by geometry): " \
         "#{text_els.map { |e| e['id'] }.join(', ')}"
  end

  # ---- Layout census (gate 8c, #259) ----------------------------------------
  # zones  = non-furniture source content zones (real plotting tiles).
  # placed = those that resolved to a Sigma element (chart_pos always places a
  #          resolved zone, so a resolved content zone == a placed tile).
  # rects  = PAGE-absolute grid footprints of the placed tiles (the ENFORCED
  #          band items, shifted by band_offset) plus the control band —
  #          furniture (header band, styled-text band) excluded from the fill
  #          numerator.
  content_zones = ZoneCensus.content_zones(dashboard['zones'])
  placed = content_zones.count { |z| els_by_name[zone_el_name(z, o[:renames])] }
  content_rects = bands.flat_map { |b| b.map { |i| [i[1], i[2], i[3] + band_offset, i[4] + band_offset] } }
  content_rects << [1, o[:page_cols] + 1, 1 + HEADER_ROWS, 1 + HEADER_ROWS + ctl_rows] if ctl_els.length.positive?
  fill = ZoneCensus.grid_fill_pct(content_rects, o[:page_cols], o[:page_rows])
  census = ZoneCensus.page_record(page['name'], content_zones.size, placed, fill)

  [page_xml(page['id'], *children), extra_els, chart_layouts.length, bands.length, ctl_els.length,
   census, min_exp]
end

data_children = Array(data_page['elements']).each_with_index.map do |element, index|
  row = index * 12 + 1
  le(element['id'], 1, opts[:page_cols] + 1, row, row + 11)
end
data_page_xml = page_xml('page-data', *data_children)

page_xmls = [data_page_xml]
sidecar = {}
census_pages = []
totals = { charts: 0, bands: 0, controls: 0 }
bands_detected = { 'header' => false, 'kpi_rows' => 0, 'sidebar' => false }
min_row_expansions = 0
dash_layout.each do |d|
  page = page_for_dash[d['dashboard']]
  next unless page
  # E2 structure detection runs on every dashboard (pure geometry over the
  # flat zone list) — it picks the synthesized path AND feeds the census's
  # bands_detected telemetry regardless of which path ends up building.
  structure = SigmaLayout.detect_bands(d['zones'])
  bands_detected['header'] ||= structure[:header].any?
  bands_detected['kpi_rows'] += structure[:kpi_rows].length
  bands_detected['sidebar'] ||= !structure[:sidebar].nil?
  use_tree  = !opts[:no_containers] &&
              (tree_has_controls?(d['zone_tree']) || tree_has_styled_containers?(d['zone_tree']))
  # Explicit source containers carry stronger composition intent than flat
  # KPI/sidebar detection. In particular, Domo observed-layout cards nest a
  # chart's companion summary KPI inside the same source card. Synthesizing
  # from the flattened leaves would pull those summaries into separate KPI
  # rows and destroy the source's card identity.
  use_synth = !opts[:no_containers] && !use_tree &&
              (structure[:sidebar] || structure[:kpi_rows].any?)
  result = nil
  if use_synth
    begin
      result = build_page_synthesized(d, page, opts, structure)
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
      result = build_page_from_tree(d, page, opts)
      warn "container-tree layout: #{d['dashboard'].inspect} → nested Sigma containers (filters/params placed in their Tableau container)"
    rescue StandardError => e
      warn "WARN: container-tree layout failed for #{d['dashboard'].inspect} (#{e.class}: #{e.message}) — falling back to banded layout"
    end
  end
  result ||= build_page_for_dashboard(d, page, opts)
  pxml, extra_els, n_charts, n_bands, n_ctls, census, n_minexp = result
  page_xmls << pxml
  sidecar[page['id']] = extra_els
  census_pages << census if census
  totals[:charts] += n_charts
  totals[:bands] += n_bands
  totals[:controls] += n_ctls
  min_row_expansions += n_minexp.to_i
end

# The vendored geometry helper still accepts its historical layout vocabulary
# internally. Canonicalize at this Domo-owned emission boundary: Sigma's live
# workbook verify/write endpoints accept only Element/Container.
layout_out = Sigma::CodeRep.canonicalize_layout(assemble(*page_xmls)) + "\n"
# Documented output-shape guard: an empty elementId is always a builder bug
# and makes Sigma reject the whole layout PUT.
abort 'FATAL: empty elementId in generated layout XML — builder bug' if layout_out.include?('elementId=""')
abort 'FATAL: legacy layout tag escaped canonicalization — builder bug' \
  if layout_out.match?(%r{</?(?:LayoutElement|GridContainer)\b})
File.write(opts[:out], layout_out)
File.write("#{opts[:out]}.elements.json", JSON.pretty_generate(sidecar))

# ---- layout-census.json (gate 8c producer, #259) --------------------------
# One record per dashboard page (zones / placed / dropped / grid_fill_pct) —
# shape kept exactly compatible. Top-level additions (telemetry, E3):
#   bands_detected     {header:bool, kpi_rows:N, sidebar:bool} across pages
#   min_row_expansions N tiles grown to their per-kind minimum row span
census_out = opts[:census_out] || File.join(File.dirname(opts[:out]), 'layout-census.json')
File.write(census_out, JSON.pretty_generate({
  'pages' => census_pages,
  'bands_detected' => bands_detected,
  'min_row_expansions' => min_row_expansions
}) + "\n")

puts "wrote #{opts[:out]} (#{page_for_dash.size} dashboard page(s): #{totals[:charts]} charts in #{totals[:bands]} band container(s), " \
     "#{totals[:controls]} controls, header bands, gap-closing applied, row-scale #{opts[:row_scale]}× → #{opts[:page_rows]} rows)"
puts "wrote #{opts[:out]}.elements.json (#{sidecar.values.sum(&:length)} container/header spec element(s) — put-layout.rb injects these)"
puts "wrote #{census_out} (#{census_pages.size} page census record(s): " \
     "#{census_pages.map { |c| "#{c['page']} #{c['placed']}/#{c['zones']} tiles, fill #{(c['grid_fill_pct'] * 100).round}%" }.join('; ')})"