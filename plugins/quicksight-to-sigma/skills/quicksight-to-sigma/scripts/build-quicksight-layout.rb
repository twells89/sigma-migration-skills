#!/usr/bin/env ruby
# build-quicksight-layout.rb
# Emit a Sigma layout XML for a QuickSight-derived workbook, faithfully mapping the
# QuickSight sheet layout to Sigma's 24-col grid (1-based grid lines).
#
# Handles:
#   - GridLayout (TILED) with explicit ColumnIndex/RowIndex/ColumnSpan/RowSpan (36-col grid)
#   - GridLayout auto-flow (spans only, no indices) → flow left-to-right, wrap by span
#   - FreeFormLayout (pixel X/Y/W/H) → normalized to the bounding box
#   - fallback: 2-per-row flow when no layout info is present
#
# Usage:
#   ruby scripts/build-quicksight-layout.rb --analysis DISCOVER_DIR/analysis.json \
#        --map /tmp/wb-spec.map.json --out /tmp/layout.xml
require 'json'
require 'optparse'
require 'set'
require_relative 'lib/layout'
include SigmaLayout

opts = {}
OptionParser.new do |o|
  o.on('--analysis F') { |v| opts[:an] = v }
  o.on('--map F') { |v| opts[:map] = v }
  o.on('--out F') { |v| opts[:out] = v }
end.parse!
%i[an map out].each { |k| abort "missing --#{k}" unless opts[k] }

defn = JSON.parse(File.read(opts[:an]))['Definition']
map = JSON.parse(File.read(opts[:map]))
v2e = map['visualToElement']             # QS VisualId -> Sigma element id
GRID = 36.0                              # QuickSight max grid width (fallback only)
SIG = 24                                 # Sigma grid width

# QuickSight does NOT use a fixed 36-column grid when indices are EXPLICIT. A sheet's
# effective grid width is whatever the widest row of tiles adds up to — commonly 12,
# 18, 24, or 36 depending on how the author sized things. Scaling every layout by a
# hardcoded 36 squeezes a 12-wide D4 into the left third of the Sigma page. Infer the
# real width as the max row edge (ColumnIndex + ColumnSpan — i.e. the per-row span sum
# of the widest row) across the sheet's elements, so relative widths + the overall
# span are preserved when we scale to Sigma's 24 columns.
#
# SPANS-ONLY layouts (auto-flow GridLayout: ColumnSpan but no ColumnIndex) are a
# DIFFERENT case: QS auto-flows those on its full 36-column canvas, so the canvas IS
# 36. Taking max(span) as the width here collapsed a uniform-18-span sheet (2-up on
# the QS canvas) into a full-width single-column stack (every 18-span tile scaled to
# 18/18 = full width) — beads-sigma-vvus. Spans-only callers must pass
# spans_only: true to get the fixed 36 canvas.
def infer_grid_width(els, spans_only: false)
  return GRID if spans_only
  edges = els.map { |e| (e['ColumnIndex'] || 0) + (e['ColumnSpan'] || 0) }
  w = edges.compact.max.to_f
  w >= 1 ? w : GRID
end

def num(s) # "120px" / "50%" / 120 -> float
  s.to_s.gsub(/[^0-9.\-]/, '').to_f
end

def scale_cols(x, w, canvas)
  c0 = (x.to_f / canvas * SIG).round + 1
  c1 = ((x.to_f + w.to_f) / canvas * SIG).round + 1
  c0 = 1 if c0 < 1
  c1 = c0 + 1 if c1 <= c0
  c1 = SIG + 1 if c1 > SIG + 1
  [c0, c1]
end


# Collision guard helper (D15 free-form overlap -> Sigma rejects "Element collisions").
# Two elements collide when their column AND row ranges both overlap.
def collides?(a, b)
  _, ac0, ac1, ar0, ar1 = a
  _, bc0, bc1, br0, br1 = b
  (ac0 < bc1 && bc0 < ac1) && (ar0 < br1 && br0 < ar1)
end

# Lay out ONE QuickSight sheet onto a Sigma grid. Returns [[elId, c0, c1, r0, r1], ...]
# using ONLY the element ids that belong to this sheet (eids_for_sheet) so a multi-sheet
# analysis lays out each page from its OWN sheet's QS layout (no cross-sheet bleed).
def layout_sheet(sheet, v2e, eids_for_sheet)
  cfg = (sheet['Layouts'] || [{}])[0].fetch('Configuration', {})
  placed = []
  if (g = cfg['GridLayout'])
    els = g['Elements'] || []
    explicit = els.any? { |e| !e['ColumnIndex'].nil? }
    if explicit
      grid_w = infer_grid_width(els)
      els.each do |e|
        eid = v2e[e['ElementId']]; next unless eid && eids_for_sheet.include?(eid)
        c0, c1 = scale_cols(e['ColumnIndex'] || 0, e['ColumnSpan'] || (grid_w / 2), grid_w)
        r0 = (e['RowIndex'] || 0) + 1
        r1 = r0 + (e['RowSpan'] || 8)
        placed << [eid, c0, c1, r0, r1]
      end
    else
      grid_w = infer_grid_width(els, spans_only: true); grid_w = GRID if grid_w <= 0
      col = 0; row = 1; row_h = 0
      els.each do |e|
        eid = v2e[e['ElementId']]; next unless eid && eids_for_sheet.include?(eid)
        span = e['ColumnSpan'] || (grid_w / 2)
        col = 0 if col + span > grid_w
        row += row_h if col.zero? && row_h.positive?
        c0, c1 = scale_cols(col, span, grid_w)
        h = (e['RowSpan'] || 12)
        placed << [eid, c0, c1, row, row + h]
        col += span; row_h = [row_h, h].max
        if col >= grid_w
          col = 0; row += row_h; row_h = 0
        end
      end
    end
  elsif (sb = cfg['SectionBasedLayout'])
    # QuickSight paginated/section layout (header/body/footer). Sigma has no page-section
    # concept; flatten every section's free-form sub-elements into a single stacked column
    # in document order so the report's vertical sequence is preserved. (D16 paginated)
    sects = []
    sects.concat(sb['HeaderSections'] || [])
    sects.concat(sb['BodySections'] || [])
    sects.concat(sb['FooterSections'] || [])
    row = 1
    sects.each do |sec|
      sec_els = (sec.dig('Content', 'Layout', 'FreeFormLayout', 'Elements') || sec['Elements'] || [])
      cw = sec_els.map { |e| num(e['XAxisLocation']) + num(e['Width']) }.max
      cw = 1.0 if cw.nil? || cw <= 0
      sec_els.each do |e|
        eid = v2e[e['ElementId']]; next unless eid && eids_for_sheet.include?(eid)
        c0, c1 = scale_cols(num(e['XAxisLocation']), num(e['Width']), cw)
        h = [(num(e['Height']) / 40.0).round, 4].max
        placed << [eid, c0, c1, row, row + h]
        row += h
      end
    end
  elsif (f = cfg['FreeFormLayout'])
    els = f['Elements'] || []
    cw = els.map { |e| num(e['XAxisLocation']) + num(e['Width']) }.max || 1.0
    ch_unit = 40.0 # ~px per Sigma row
    els.each do |e|
      eid = v2e[e['ElementId']]; next unless eid && eids_for_sheet.include?(eid)
      c0, c1 = scale_cols(num(e['XAxisLocation']), num(e['Width']), cw <= 0 ? 1 : cw)
      r0 = (num(e['YAxisLocation']) / ch_unit).round + 1
      r1 = r0 + [(num(e['Height']) / ch_unit).round, 4].max
      placed << [eid, c0, c1, r0, r1]
    end
  end

  # fallback: 2-per-row flow over this sheet's mapped elements (preserving sheet order)
  if placed.empty?
    sheet_eids = (sheet['Visuals'] || []).map { |v| _t, inner = v.first; v2e[inner['VisualId']] }
                                          .compact.select { |eid| eids_for_sheet.include?(eid) }
    col = 1; row = 1
    sheet_eids.each do |eid|
      if col > 13
        col = 1; row += 12
      end
      placed << [eid, col, col + 12, row, row + 12]
      col += 12
    end
  end

  # collision guard: collapse to stacked full-width rows if any pair overlaps
  if placed.combination(2).any? { |a, b| collides?(a, b) }
    STDERR.puts "layout: collisions on sheet \"#{sheet['Name']}\" -> collapsing #{placed.size} elements to stacked rows"
    row = 1; row_h = 12
    placed = placed.map { |eid, _c0, _c1, _r0, _r1| r0 = row; row += row_h; [eid, 1, SIG + 1, r0, r0 + row_h] }
  end
  [placed, cfg.keys.first || 'flow-fallback']
end

# ----- assemble: one Sigma page per QS sheet (plus the shared Data page) -----
# The map's sheetPages (written by build-workbook-from-quicksight.rb) tells us which
# Sigma page each QS sheet maps to. Fall back to the legacy single dashPageId when an
# older map (no sheetPages) is supplied.
sheet_pages = map['sheetPages']
sheets = defn['Sheets'] || []
pages_xml = []
sidecar = {}   # pageId -> container/header spec elements (put-layout.rb injects)
total_placed = 0

# Sigma control elements per page (built from QS sheet FilterControls/ParameterControls).
# They have no QS visual-grid coords, so we LIFT them into a clean full-width band at the
# top of the page (qlik-to-sigma parity): the chart bands keep their QS geometry below.
control_eids = map['controlElementIds'] || {}

# Prepend a controls band: tile the page's control eids edge-to-edge across the full grid
# at the top (rows 1..3), then shift all chart items DOWN by that band's height so nothing
# overlaps. Returns the augmented `placed`.
def lift_controls(placed, ctl_ids)
  return placed if ctl_ids.nil? || ctl_ids.empty?
  band_h = 3
  shift = placed.map { |i| i[3] }.min.to_i
  shift = 1 if shift.zero?
  charts = placed.map { |eid, c0, c1, r0, r1| [eid, c0, c1, r0 - shift + 1 + band_h, r1 - shift + 1 + band_h] }
  n = ctl_ids.size
  ctl_band = ctl_ids.each_with_index.map do |eid, j|
    c0 = 1 + (24 * j / n.to_f).round
    c1 = 1 + (24 * (j + 1) / n.to_f).round
    [eid, c0, c1, 1, 1 + band_h]
  end
  ctl_band + charts
end

if sheet_pages && !sheet_pages.empty?
  sheet_pages.each do |sp|
    idx = sp['sheetIndex']
    sheet = sheets[idx] || {}
    # element ids that belong to THIS sheet = the elements for this sheet's visuals
    eids_for_sheet = (sheet['Visuals'] || []).map { |v| _t, inner = v.first; v2e[inner['VisualId']] }.compact.to_set
    placed, src = layout_sheet(sheet, v2e, eids_for_sheet)
    placed = lift_controls(placed, control_eids[sp['pageId']])
    total_placed += placed.size
    next if placed.empty?
    # Container-banded page (layout-playbook.md): header band with the QS sheet
    # name, then one full-width GridContainer per row band — the QS 36-col row
    # geometry is preserved INSIDE each band (container-relative coordinates).
    xml, extra = banded_page(sp['pageId'], placed, title: sp['name'] || sheet['Name'])
    pages_xml << xml
    sidecar[sp['pageId']] = extra
    STDERR.puts "layout: page \"#{sp['name']}\" (#{sp['pageId']}) <- QS sheet[#{idx}] #{src}: #{placed.size} element(s), #{extra.size - 2} chart band(s) + header"
    placed.each { |eid, c0, c1, r0, r1| STDERR.puts "  #{eid}  col #{c0}-#{c1}  row #{r0}-#{r1}" }
  end
else
  # legacy single-page path (old map without sheetPages)
  all_eids = v2e.values.to_set
  placed, src = layout_sheet(sheets[0] || {}, v2e, all_eids)
  placed = lift_controls(placed, control_eids[map['dashPageId']])
  total_placed += placed.size
  xml, extra = banded_page(map['dashPageId'], placed, title: (sheets[0] || {})['Name'] || 'Dashboard')
  pages_xml << xml
  sidecar[map['dashPageId']] = extra
  STDERR.puts "layout: #{placed.size} elements mapped from QuickSight #{src} (legacy single-page; container bands)"
end

data_page = page_xml('page-data', le(map['masterElementId'], 1, 25, 1, 15))
File.write(opts[:out], assemble(data_page, *pages_xml))
File.write("#{opts[:out]}.elements.json", JSON.pretty_generate(sidecar))
STDERR.puts "layout: #{total_placed} elements across #{pages_xml.size} page(s) -> #{opts[:out]} (+ .elements.json sidecar)"
