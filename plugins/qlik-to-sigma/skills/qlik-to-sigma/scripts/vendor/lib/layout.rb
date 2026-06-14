# Layout-XML helpers. require'd by per-workbook layout configs.
#
# Container-based layouts (layout-playbook.md, verified 2026-06-10):
#   - spec side: a `kind: container` placeholder element per band
#     (container_el / header_text_el below build those spec objects)
#   - layout side: a <GridContainer> (NOT <LayoutElement type="grid">, which
#     silently drops children) whose child <LayoutElement>s use
#     CONTAINER-RELATIVE coordinates (rows restart at 1).
module SigmaLayout
  module_function

  HEADER_STYLE = { 'backgroundColor' => '#0F172A', 'borderRadius' => 'round' }.freeze
  HEADER_ROWS  = 3 # header band height in grid rows
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

  def gc(eid, c0, c1, r0, r1, inner)
    "<GridContainer elementId=\"#{eid}\" type=\"grid\" " \
    "gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\" " \
    "gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\">\n#{inner}\n</GridContainer>"
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

  # Spec-side page-title text element (white text over the dark header band).
  def header_text_el(id, title)
    { 'id' => id, 'kind' => 'text',
      'body' => %(# <span style="color: #FFFFFF">#{title}</span>) }
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
end
