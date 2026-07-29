# ── VENDORED (do not edit here) ──────────────────────────────────────────────
# Source: twells89/sigma-migration-skills @ a73f833
#   plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/layout.rb
# Fix upstream and re-vendor; do not diverge this copy. Vendored for the
# standalone domo-sigma-migration repo (clone-safety) per the domo-build-pipeline plan.
# ─────────────────────────────────────────────────────────────────────────────
# Layout-XML helpers. require'd by per-workbook layout configs.
#
# Container-based layouts (layout-playbook.md, verified 2026-06-10):
#   - spec side: a `kind: container` placeholder element per band
#     (container_el / header_text_el below build those spec objects)
#   - layout side: a <GridContainer> (NOT <LayoutElement type="grid">, which
#     silently drops children) whose child <LayoutElement>s use
#     CONTAINER-RELATIVE coordinates (rows restart at 1).
require_relative 'zone_census'

module SigmaLayout
  module_function

  HEADER_STYLE = { 'backgroundColor' => '#0F172A', 'borderRadius' => 'round' }.freeze
  HEADER_ROWS  = 3 # header band height in grid rows
  HEADER_BAND_MAX_ROWS = 3 # cap a short single-line text LABEL (section/column
  #   header) to a thin banner — source geometry can inflate a one-line header to
  #   many rows, which tints into a big empty colored block.
  GRID_COLS    = 24 # page/container grid width (gridTemplateColumns repeat(24))
  MIN_BAND_FILL = 0.60 # a band must fill >=60% of the grid columns (lint parity)
  # Generic auto-names (Sigma page names / source section names) that must
  # NEVER become a header-band title — "Page 1" / "Sheet 3" / "Dashboard 2".
  GENERIC_TITLE = /\A(?:page|sheet|dashboard)\s*\d+\z/i

  # True when a candidate header title is a generic auto-name.
  def generic_title?(s)
    s.to_s.strip.match?(GENERIC_TITLE)
  end

  # First usable header-band title from a priority-ordered candidate list:
  # skips nil/empty and generic auto-names ("Page 1" etc). Callers pass, in
  # order: promoted source title -> source dashboard/report display name ->
  # workbook name. Returns nil when nothing usable remains (caller decides).
  def resolve_header_title(*candidates)
    candidates.map { |c| c.to_s.strip }.find { |c| !c.empty? && !generic_title?(c) }
  end

  # `cols:` sets the container's internal column count (gridTemplateColumns).
  # Default 24 (the page grid); a vertical control rail declares cols: 1 so its
  # children stack full-width (children's gridColumn refs are LOCAL to this).
  def gc(eid, c0, c1, r0, r1, inner, cols: GRID_COLS)
    "<GridContainer elementId=\"#{eid}\" type=\"grid\" " \
    "gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\" " \
    "gridTemplateColumns=\"repeat(#{cols}, 1fr)\" gridTemplateRows=\"auto\">\n#{inner}\n</GridContainer>"
  end

  def le(eid, c0, c1, r0, r1)
    "  <LayoutElement elementId=\"#{eid}\" gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\"/>"
  end

  def page_xml(page_id, *children)
    header = "<Page type=\"grid\" gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\" id=\"#{page_id}\">"
    [header, *children.compact, "</Page>"].join("\n")
  end

  def assemble(*pages)
    %(<?xml version="1.0" encoding="utf-8"?>\n) + pages.join("\n")
  end

  # ---- container-layout helpers --------------------------------------------

  # Spec-side placeholder for a band container.
  def container_el(id, style = nil)
    el = { 'id' => id, 'kind' => 'container' }
    el['style'] = style if style
    el
  end

  # Spec-side page-title text element. `color` sets the title colour: pass a
  # light hex over a dark header band, or nil to leave the title in the theme's
  # default text colour (correct when the title sits on the page canvas — no
  # band — so it isn't forced white-on-white).
  def header_text_el(id, title, color = nil)
    span = color ? %(<span style="color: #{color}">#{title}</span>) : title.to_s
    { 'id' => id, 'kind' => 'text', 'body' => "# #{span}" }
  end

  # Header band XML: dark full-width container at the top of the page wrapping
  # the title text (child coordinates are container-relative).
  def header_band_xml(container_id, text_id, rows: HEADER_ROWS)
    gc(container_id, 1, 25, 1, 1 + rows, le(text_id, 1, 25, 1, 1 + rows))
  end

  # Cluster placed items into horizontal bands by row overlap. Items are
  # [eid, c0, c1, r0, r1, *rest] tuples with PAGE-ABSOLUTE rows. Returns an
  # array of bands (each an array of items), top-to-bottom.
  def cluster_bands(items)
    bands = []
    items.sort_by { |i| [i[3], i[1]] }.each do |it|
      if bands.any? && it[3] < bands.last[:r1]
        bands.last[:items] << it
        bands.last[:r1] = [bands.last[:r1], it[4]].max
      else
        bands << { r0: it[3], r1: it[4], items: [it] }
      end
    end
    bands.map { |b| b[:items] }
  end

  # Fraction of the GRID_COLS columns covered by a band's items (union).
  def band_fill(items)
    covered = Array.new(GRID_COLS, false)
    items.each do |i|
      (i[1]...i[2]).each { |c| covered[c - 1] = true if c >= 1 && c <= GRID_COLS }
    end
    covered.count(true).to_f / GRID_COLS
  end

  # Re-flow under-filled bands (phase-e layout-quality fix, round 2): when any
  # band's items cover <60% of the grid columns — e.g. a small chart left
  # alone in band 1 after its neighboring title textbox was promoted into the
  # header band — the page's items are redistributed across the same number
  # of bands EVENLY (sizes differ by at most 1, remainder to the bottom bands:
  # 5 charts -> 2+3), and each band's items are tiled edge-to-edge across the
  # full grid width at the band's original height (uniform rows — no stagger).
  # Pages whose bands all fill >=60% keep the source-canvas geometry exactly.
  def reflow_bands(bands)
    return bands unless bands.any? { |b| band_fill(b) < MIN_BAND_FILL }
    heights = bands.map { |b| b.map { |i| i[4] }.max - b.map { |i| i[3] }.min }
    items = bands.flat_map { |b| b.sort_by { |i| [i[3], i[1]] } }
    k = items.length
    nb = [bands.length, k].min
    base = k / nb
    sizes = Array.new(nb) { |bi| base + (bi >= nb - (k % nb) ? 1 : 0) }
    out = []
    idx = 0
    cursor = 1
    sizes.each_with_index do |n, bi|
      band_items = items[idx, n]
      idx += n
      h = [heights[bi] || heights.compact.max || 8, 4].max
      band = band_items.each_with_index.map do |it, j|
        c0 = 1 + (GRID_COLS * j / n.to_f).round
        c1 = 1 + (GRID_COLS * (j + 1) / n.to_f).round
        [it[0], c0, c1, cursor, cursor + h, *it[5..]]
      end
      out << band
      cursor += h
    end
    out
  end

  # Two placed items collide when their column AND row ranges both overlap.
  # Items are [eid, c0, c1, r0, r1, *rest] with grid-line (exclusive-end) coords.
  def collide?(a, b)
    a[1] < b[2] && b[1] < a[2] && a[3] < b[4] && b[3] < a[4]
  end

  # De-overlap each band. Sigma's grid has NO z-order, so two items sharing a
  # cell — common when a source tool floats a filter/legend/listbox on top of a
  # chart (e.g. Qlik's associative-model listboxes over charts) — render
  # stacked on top of each other. When any pair in a band overlaps in BOTH
  # axes, tile that band's items edge-to-edge across the full grid width at the
  # band's row range (same tiling math as reflow_bands). Collision-free bands
  # are returned untouched, so clean source geometry is preserved exactly. This
  # is the universal safety net that runs after reflow on every banded_page.
  def decollide_bands(bands)
    bands.map do |band|
      next band unless band.combination(2).any? { |a, b| collide?(a, b) }
      r0 = band.map { |i| i[3] }.min
      r1 = band.map { |i| i[4] }.max
      n = band.length
      band.sort_by { |i| [i[1], i[3]] }.each_with_index.map do |it, j|
        c0 = 1 + (GRID_COLS * j / n.to_f).round
        c1 = 1 + (GRID_COLS * (j + 1) / n.to_f).round
        [it[0], c0, c1, r0, r1, *it[5..]]
      end
    end
  end

  # One band of items -> a full-width GridContainer spanning the band's row
  # range at page level, children re-emitted with CONTAINER-RELATIVE rows.
  # row_offset shifts the container's page-level position (e.g. +3 when a
  # header band was prepended above the original geometry).
  def band_container_xml(cid, items, row_offset: 0)
    r0 = items.map { |i| i[3] }.min
    r1 = items.map { |i| i[4] }.max
    inner = items.map { |i| le(i[0], i[1], i[2], i[3] - r0 + 1, i[4] - r0 + 1) }.join("\n")
    gc(cid, 1, 25, r0 + row_offset, r1 + row_offset, inner)
  end

  # Full container-banded page: header band + one container per row band.
  # Returns [page_xml_string, extra_spec_elements] — the caller must add the
  # extra elements (containers + header text) to the page's spec `elements`
  # (directly, or via put-layout.rb's <layout>.elements.json sidecar).
  # `title` of nil/empty skips the header band (e.g. when the caller bands an
  # existing title text element explicitly).
  # `header_el`: an EXISTING text element id to wrap as the header band's text
  # (e.g. the source dashboard's own title textbox — phase-e layout-quality
  # fix: a short title text left inside band 1 reads as a dead zone). It must
  # NOT also appear in `items`; the caller should recolor its body for the
  # dark band (see header_text_el's white span).
  # `title` must already be resolved through resolve_header_title (promoted
  # source title -> source display name -> workbook name) — a generic
  # auto-name ("Page 1") raises rather than ships a wrong header band.
  # `reflow: true` (default) runs reflow_bands so no band ships <60% filled.
  def banded_page(page_id, items, title: nil, id_prefix: "band-#{page_id}", header_el: nil,
                  reflow: true)
    extra = []
    children = []
    offset = 0
    if header_el
      hdr_id = "#{id_prefix}-hdr"
      extra << container_el(hdr_id, HEADER_STYLE.dup)
      children << header_band_xml(hdr_id, header_el)
      offset = HEADER_ROWS
    elsif title && !title.to_s.empty?
      raise ArgumentError, "banded_page: generic header title #{title.inspect} — " \
                           'resolve via resolve_header_title (source display name / workbook name)' \
        if generic_title?(title)
      hdr_id = "#{id_prefix}-hdr"
      txt_id = "#{id_prefix}-hdrtext"
      extra << container_el(hdr_id, HEADER_STYLE.dup)
      extra << header_text_el(txt_id, title)
      children << header_band_xml(hdr_id, txt_id)
      offset = HEADER_ROWS
    end
    bands = cluster_bands(items)
    bands = reflow_bands(bands) if reflow
    bands = decollide_bands(bands)
    top = bands.flatten(1).map { |i| i[3] }.min
    offset += (1 - top) if top # first band starts right under the header
    bands.each_with_index do |band, i|
      cid = "#{id_prefix}-#{i + 1}"
      extra << container_el(cid)
      children << band_container_xml(cid, band, row_offset: offset)
    end
    [page_xml(page_id, *children), extra]
  end

  # ==== E1 — per-kind minimum row heights ====================================
  # Sigma renders chart/KPI tiles BLANK below ~3-4 grid rows — in the live page
  # AND in page/element PNG exports (hit twice in a 2026-07 live migration).
  # These are the floor row-spans the layout builder enforces after converting
  # Tableau zone percentages to grid rows, and that layout_lint rejects.
  # Keys are Sigma element kinds; 'chart' covers every *-chart kind without an
  # explicit entry (kpi-chart is the deliberate exception: KPI cards are short
  # by design, but still blank under 4 rows).
  # KEEP IN SYNC with LayoutLint::KIND_MIN_ROWS (lib/layout_lint.rb is vendored
  # standalone across plugins, so it carries its own copy).
  KIND_MIN_ROWS = {
    'kpi-chart'   => 4,  # value + label need ~4 rows to render at all
    'chart'       => 8,  # axis/labels suppressed and tile blanks below ~8
    'table'       => 10, # header row + a few data rows
    'pivot-table' => 10,
    'control'     => 2,  # one input strip; 2 rows keeps the label visible
    'text'        => 2
  }.freeze

  # Minimum grid-row span for a Sigma element kind (see KIND_MIN_ROWS).
  def min_rows_for(kind)
    k = kind.to_s
    return KIND_MIN_ROWS[k] if KIND_MIN_ROWS.key?(k)
    return KIND_MIN_ROWS['chart'] if k.end_with?('-chart')
    KIND_MIN_ROWS['text'] # unknown/other -> smallest floor
  end

  # Same floor derived from a Tableau ZONE (where the Sigma element kind isn't
  # resolved yet — the container-tree/synthesized paths place by zone). A chart
  # zone that provably plots nothing (ZoneCensus furniture — title/label
  # worksheets) only gets the text floor; zones lacking the shelf/measure keys
  # (zone_tree nodes) are assumed to plot.
  def min_rows_for_zone(zone)
    z = zone || {}
    k = z['kind'].to_s
    return KIND_MIN_ROWS['control'] if k == 'filter' || k == 'parameter'
    return KIND_MIN_ROWS['text'] unless k == 'chart'
    has_signal = z.key?('measures') || z.key?('rows_shelf') || z.key?('cols_shelf')
    return KIND_MIN_ROWS['text'] if has_signal && !ZoneCensus.plots?(z)
    ck = z['chart_kind'].to_s
    return KIND_MIN_ROWS['kpi-chart'] if ck == 'kpi'
    return KIND_MIN_ROWS['table'] if ck == 'table' || ck == 'pivot-table'
    KIND_MIN_ROWS['chart']
  end

  # rects are [c0, c1, r0, r1] grid-LINE tuples (exclusive end).
  def rects_overlap?(a, b)
    a[0] < b[1] && b[0] < a[1] && a[2] < b[3] && b[2] < a[3]
  end

  # Resolve overlaps by pushing rects DOWN (rows only; columns untouched), in
  # reading order (r0, c0, input index — fully deterministic). Returns a new
  # array in the SAME order as the input. A rect that collides with an
  # already-settled rect moves just below it, repeatedly, so the result is
  # collision-free; collision-free input is returned unchanged.
  def pack_rects(rects)
    order = rects.each_index.sort_by { |i| [rects[i][2], rects[i][0], i] }
    settled = []
    final = Array.new(rects.length)
    order.each do |i|
      rect = rects[i].dup
      loop do
        hit = settled.find { |p| rects_overlap?(p, rect) }
        break unless hit
        h = rect[3] - rect[2]
        rect[2] = hit[3]
        rect[3] = rect[2] + h
      end
      settled << rect
      final[i] = rect
    end
    final
  end

  # Expand each rect to at least mins[i] rows (growing r1), then push-down so
  # the expansion never creates an overlap. Returns [new_rects, n_expanded]
  # (same order as input). Collision-free input stays collision-free.
  def expand_min_rows(rects, mins)
    expanded = 0
    grown = rects.each_with_index.map do |(c0, c1, r0, r1), i|
      min = mins[i].to_i
      if min.positive? && (r1 - r0) < min
        expanded += 1
        [c0, c1, r0, r0 + min]
      else
        [c0, c1, r0, r1]
      end
    end
    return [rects, 0] if expanded.zero?
    [pack_rects(grown), expanded]
  end

  # Band-level minimum-row enforcement for the geometry-banded path. `bands`
  # are cluster_bands output ([eid, c0, c1, r0, r1, *rest] items, PAGE-absolute
  # rows); `kind_for` maps element id -> Sigma element kind. Expands each item
  # to its kind floor, de-collides within the band (push-down), and shifts
  # every SUBSEQUENT band down by the accumulated growth so bands never
  # overlap. Returns [new_bands, n_expanded].
  def enforce_min_rows(bands, kind_for)
    total = 0
    offset = 0
    out = bands.map do |band|
      shifted = band.map { |it| [it[0], it[1], it[2], it[3] + offset, it[4] + offset, *it[5..-1]] }
      bottom_before = shifted.map { |i| i[4] }.max
      rects = shifted.map { |it| it[1, 4] }
      mins  = shifted.map { |it| min_rows_for(kind_for[it[0]]) }
      rects, n = expand_min_rows(rects, mins)
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

  # ==== E2 — band/structure detection (composition-recipe.md, codified) ======
  # Pure geometry over the parser's FLAT zone list (dashboard['zones']); the
  # layout builder consumes the returned band structures. Deterministic: every
  # sort carries the zone id as the final tiebreaker.

  KPI_MAX_H_PCT     = 12.0 # a plotting chart this short reads as a KPI card
  KPI_MAX_W_PCT     = 40.0 # ... unless it spans wide (sparkline strips etc.)
  KPI_ROW_Y_TOL     = 4.0  # zones whose tops differ <= this % share a y-band
  KPI_ROW_H_RATIO   = 1.6  # max/min height ratio still "similar height"
  KPI_ROW_X_OVERLAP = 0.2  # row members must be x-disjoint beyond this frac
  SIDEBAR_MAX_W_PCT = 20.0 # rail column must be narrower than this
  SIDEBAR_MIN_ZONES = 2
  SIDEBAR_MIN_SPREAD = 15.0 # controls must span this much height (or be >= 3)
  HEADER_MAX_Y_PCT  = 12.0
  HEADER_MIN_W_PCT  = 50.0
  HEADER_MAX_H_PCT  = 15.0 # a strip, not a full-page canvas background

  # Fraction of the NARROWER zone's width shared by the two zones' x-extents.
  def x_overlap_frac(a, b)
    ax0 = (a['x_pct'] || 0).to_f
    ax1 = ax0 + (a['w_pct'] || 0).to_f
    bx0 = (b['x_pct'] || 0).to_f
    bx1 = bx0 + (b['w_pct'] || 0).to_f
    inter = [ax1, bx1].min - [ax0, bx0].max
    return 0.0 if inter <= 0
    inter / [[ax1 - ax0, bx1 - bx0].min, 0.1].max
  end

  # A chart zone that reads as a KPI card: declared kpi, or a short plotting
  # tile that isn't a wide strip.
  def kpi_like_zone?(z)
    return false unless z.is_a?(Hash) && z['kind'] == 'chart'
    return false unless ZoneCensus.plots?(z)
    return true if z['chart_kind'].to_s == 'kpi'
    (z['h_pct'] || 100).to_f <= KPI_MAX_H_PCT && (z['w_pct'] || 100).to_f <= KPI_MAX_W_PCT
  end

  # Topmost full-width title/text zone(s) -> the header band (rows 1..3).
  def detect_header_zones(zones)
    Array(zones).select do |z|
      %w[text title].include?(z['kind'].to_s) &&
        (z['y_pct'] || 0).to_f <= HEADER_MAX_Y_PCT &&
        (z['w_pct'] || 0).to_f >= HEADER_MIN_W_PCT &&
        (z['h_pct'] || 100).to_f <= HEADER_MAX_H_PCT
    end.sort_by { |z| [(z['y_pct'] || 0).to_f, (z['x_pct'] || 0).to_f, z['id'].to_s] }
  end

  # >= 2 x-disjoint, similar-height, same-y-band KPI-like chart zones -> one
  # KPI row (emitted as ONE GridContainer with equal inner spans). Returns an
  # array of rows, each an array of zones sorted left-to-right.
  def detect_kpi_rows(zones)
    cands = Array(zones).select { |z| kpi_like_zone?(z) }
                        .sort_by { |z| [(z['y_pct'] || 0).to_f, (z['x_pct'] || 0).to_f, z['id'].to_s] }
    rows = []
    cands.each do |z|
      zy = (z['y_pct'] || 0).to_f
      zh = [(z['h_pct'] || 0).to_f, 0.1].max
      home = rows.find do |row|
        ref = row.first
        ry = (ref['y_pct'] || 0).to_f
        rh = [(ref['h_pct'] || 0).to_f, 0.1].max
        next false if (ry - zy).abs > KPI_ROW_Y_TOL
        next false if [zh, rh].max / [zh, rh].min > KPI_ROW_H_RATIO
        # members must sit side-by-side: reject vertical stacks (same x)
        row.none? { |m| x_overlap_frac(m, z) > KPI_ROW_X_OVERLAP }
      end
      home ? home << z : rows << [z]
    end
    rows.select { |r| r.length >= 2 }
        .map { |r| r.sort_by { |z| [(z['x_pct'] || 0).to_f, z['id'].to_s] } }
  end

  # A narrow (< SIDEBAR_MAX_W_PCT) column of filter/parameter zones hugging the
  # left or right edge -> a vertical control rail. Returns nil or
  # { side: :left|:right, zones: [ctl zones by y], texts: [text zones in the
  #   rail column], x0:, x1: } (x0/x1 = the rail column's % extent).
  def detect_sidebar(zones)
    zs = Array(zones)
    ctls = zs.select { |z| %w[filter parameter].include?(z['kind'].to_s) }
    return nil if ctls.empty?
    left  = ctls.select { |z| (z['x_pct'] || 0).to_f + (z['w_pct'] || 0).to_f <= SIDEBAR_MAX_W_PCT }
    right = ctls.select { |z| (z['x_pct'] || 0).to_f >= 100.0 - SIDEBAR_MAX_W_PCT }
    side, rail = left.length >= right.length ? [:left, left] : [:right, right]
    return nil if rail.length < SIDEBAR_MIN_ZONES
    ys = rail.map { |z| (z['y_pct'] || 0).to_f }
    y1s = rail.map { |z| (z['y_pct'] || 0).to_f + (z['h_pct'] || 0).to_f }
    spread = y1s.max - ys.min
    return nil if rail.length < 3 && spread < SIDEBAR_MIN_SPREAD
    x0 = rail.map { |z| (z['x_pct'] || 0).to_f }.min
    x1 = rail.map { |z| (z['x_pct'] || 0).to_f + (z['w_pct'] || 0).to_f }.max
    return nil if x1 - x0 >= SIDEBAR_MAX_W_PCT
    # the rail must leave real content beside it (a plotting chart outside it)
    content = zs.select { |z| ZoneCensus.plots?(z) }
    outside = content.any? do |z|
      cx = (z['x_pct'] || 0).to_f + (z['w_pct'] || 0).to_f / 2.0
      side == :left ? cx > x1 : cx < x0
    end
    return nil unless outside
    texts = zs.select do |z|
      next false unless %w[text title].include?(z['kind'].to_s)
      cx = (z['x_pct'] || 0).to_f + (z['w_pct'] || 0).to_f / 2.0
      cx >= x0 - 2 && cx <= x1 + 2
    end.sort_by { |z| [(z['y_pct'] || 0).to_f, z['id'].to_s] }
    { side: side,
      zones: rail.sort_by { |z| [(z['y_pct'] || 0).to_f, z['id'].to_s] },
      texts: texts, x0: x0, x1: x1 }
  end

  # The structure-synthesis entry point: { header:, kpi_rows:, sidebar: }.
  def detect_bands(zones)
    { header: detect_header_zones(zones),
      kpi_rows: detect_kpi_rows(zones),
      sidebar: detect_sidebar(zones) }
  end

  # Standard grid breakpoints (workbook-layout.md "Percent -> Sigma 24-col
  # grid"): quarters, thirds, halves. Section-panel columns snap to these when
  # within `tol` columns (~3% of the page) so panels align to the common grid.
  COL_BREAKPOINTS = [1, 7, 9, 13, 17, 19, 25].freeze

  def snap_col(c, tol = 1)
    bp = COL_BREAKPOINTS.min_by { |b| (b - c).abs }
    (bp - c).abs <= tol ? bp : c
  end
end
