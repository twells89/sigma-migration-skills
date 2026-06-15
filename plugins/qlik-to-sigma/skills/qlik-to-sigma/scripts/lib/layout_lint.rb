# frozen_string_literal: true
#
# layout_lint.rb — mechanized layout-quality lint for built Sigma workbooks.
#
# SHARED lib, vendored byte-identical into every covered plugin's scripts/lib/
# (md5 discipline — same as escalate-gap.py / enhance-apply.rb). Run by:
#   - post-and-readback.rb (--type workbook) right after the column-type guard
#   - enhance-apply.rb's finalize (the Phase E clone must lint clean)
#   - assert-phase6-ran.rb gate 6 (with a --skip-layout-lint escape)
#
# It exists because a workbook can pass every data gate and still ship as a
# visual mess (raw-id chart titles, controls dumped at the page foot, dead
# zones) — the "PHASEE PBI Employee Dashboard" regression. Five checks:
#
#   (a) raw-id display names — any element display name matching a raw-id
#       pattern (^[0-9a-f]{12,}$ or ^el-[0-9a-f]+$). A human must never see a
#       visual id as a chart title.
#   (b) orphan controls — input controls placed OUTSIDE any <GridContainer>
#       on a page that HAS containers (banded layout). Controls belong in a
#       band (control band, or their chart's container), never loose at the
#       page foot.
#   (c) dead zones — more than 25% of a page's grid rows empty between the
#       page's first and last positioned element (top-level layout entries).
#       Catches the "elements scattered with a hole next to the title" look.
#   (d) generic header-band title — the header band's text rendering as a
#       generic auto-name ("Page 1" / "Sheet 3" / "Dashboard 2"). The header
#       must carry the promoted source title, the source dashboard/report
#       display name, or the workbook name — never the Sigma page name (the
#       PHASEE2 PBI regression: header read "Page 1" while the real title sat
#       inside band 1).
#   (e) band column fill — a band (top-level GridContainer) whose children
#       cover <60% of the 24 grid columns, i.e. shipped dead space (the
#       PHASEE2 PBI regression: band 1 = one small bar chart at columns 1-6
#       next to a 19-column hole). Deliberate KPI bands (<=4 tiles, all
#       kpi-chart) are exempt.
#
# API:
#   violations = LayoutLint.lint(spec)   # spec = parsed workbook spec Hash
#   -> array of human-readable violation strings; empty = clean.
#
# Standalone:
#   ruby scripts/lib/layout_lint.rb <spec.json>   # exit 1 + list on violations
module LayoutLint
  RAW_ID_NAME = /\A(?:[0-9a-f]{12,}|el-[0-9a-f]+)\z/i
  DEAD_ZONE_MAX = 0.25
  GENERIC_HEADER = /\A(?:page|sheet|dashboard)\s*\d+\z/i
  GRID_COLS = 24
  MIN_BAND_FILL = 0.60
  KPI_BAND_MAX_TILES = 4

  module_function

  # All [element, page] pairs in the spec (skips layout-only container shells).
  def named_elements(spec)
    (spec['pages'] || []).flat_map do |pg|
      (pg['elements'] || []).map { |el| [el, pg] }
    end
  end

  # Per-page layout blocks: { page_id => page_inner_xml }.
  def page_blocks(layout_xml)
    layout_xml.to_s.scan(%r{<Page\b[^>]*\bid="([^"]*)"[^>]*>(.*?)</Page>}m).to_h
  end

  # Top-level entries of a page block (direct children only, containers kept
  # opaque): [[:container|:element, element_id, row_start, row_end], ...]
  def top_level_entries(page_xml)
    entries = []
    s = page_xml.to_s
    pos = 0
    while (m = s.match(%r{<(GridContainer|LayoutElement)\b([^>]*?)(/>|>)}m, pos))
      tag, attrs, close = m[1], m[2], m[3]
      eid = attrs[/elementId="([^"]*)"/, 1]
      rows = attrs[/gridRow="\s*(\d+)\s*/, 1].to_i
      rowe = attrs[/gridRow="\s*\d+\s*\/\s*(\d+)\s*"/, 1].to_i
      if tag == 'GridContainer' && close == '>'
        endm = s.match(%r{</GridContainer>}m, m.end(0))
        entries << [:container, eid, rows, rowe]
        pos = endm ? endm.end(0) : m.end(0)
      else
        entries << [tag == 'GridContainer' ? :container : :element, eid, rows, rowe]
        pos = m.end(0)
      end
    end
    entries
  end

  # Top-level GridContainers of a page block with their direct children:
  # [{eid:, r0:, r1:, children: [[child_eid, c0, c1, r0, r1], ...]}, ...]
  def containers(page_xml)
    out = []
    s = page_xml.to_s
    pos = 0
    while (m = s.match(%r{<GridContainer\b([^>]*?)(/>|>)}m, pos))
      attrs, close = m[1], m[2]
      eid = attrs[/elementId="([^"]*)"/, 1]
      r0 = attrs[/gridRow="\s*(\d+)/, 1].to_i
      r1 = attrs[/gridRow="\s*\d+\s*\/\s*(\d+)/, 1].to_i
      inner = ''
      if close == '>'
        endm = s.match(%r{</GridContainer>}m, m.end(0))
        inner = endm ? s[m.end(0)...endm.begin(0)] : ''
        pos = endm ? endm.end(0) : m.end(0)
      else
        pos = m.end(0)
      end
      children = inner.scan(%r{<LayoutElement\b[^>]*?/?>}m).map do |le|
        [le[/elementId="([^"]*)"/, 1],
         le[/gridColumn="\s*(\d+)/, 1].to_i, le[/gridColumn="\s*\d+\s*\/\s*(\d+)/, 1].to_i,
         le[/gridRow="\s*(\d+)/, 1].to_i, le[/gridRow="\s*\d+\s*\/\s*(\d+)/, 1].to_i]
      end
      out << { eid: eid, r0: r0, r1: r1, children: children }
    end
    out
  end

  # A text element's body reduced to its visible text (markdown/HTML stripped).
  def plain_text(body)
    body.to_s.gsub(%r{<[^>]+>}, '').gsub(/^#+\s*/, '').gsub(/[*_`]/, '').strip
  end

  def lint(spec)
    violations = []
    el_kind = {}
    el_body = {}
    named_elements(spec).each do |el, _pg|
      el_kind[el['id']] = el['kind']
      el_body[el['id']] = el['body']
    end

    # (a) raw-id display names ------------------------------------------------
    named_elements(spec).each do |el, pg|
      name = el['name'].to_s
      next if name.empty?
      next unless name.match?(RAW_ID_NAME)
      violations << "raw-id display name: element #{el['id']} (#{el['kind']}) on page " \
                    "'#{pg['name'] || pg['id']}' is named #{name.inspect} — derive a human title " \
                    '(the source visual had no explicit title; see derived_title in the builder)'
    end

    page_blocks(spec['layout']).each do |page_id, body|
      next if page_id.to_s.downcase.include?('data')
      entries = top_level_entries(body)
      next if entries.empty?

      # (b) controls outside any container on a containered page --------------
      if body.include?('<GridContainer')
        entries.each do |kind, eid, _r0, _r1|
          next unless kind == :element && el_kind[eid] == 'control'
          violations << "orphan control: #{eid} sits OUTSIDE every GridContainer on page #{page_id} " \
                        '(banded page) — place it in the control band or its chart\'s container'
        end
      end

      # (d) generic header-band title ------------------------------------------
      bands = containers(body)
      hdr = bands.select { |b| b[:r0] <= 1 }.min_by { |b| b[:r0] }
      if hdr
        hdr[:children].each do |ceid, _c0, _c1, _r0, _r1|
          next unless el_kind[ceid] == 'text'
          txt = plain_text(el_body[ceid])
          next unless txt.match?(GENERIC_HEADER)
          violations << "generic header title: the header band (#{hdr[:eid]}) on page #{page_id} " \
                        "renders #{txt.inspect} (element #{ceid}) — a Sigma auto page name must never " \
                        'title the dashboard; use the promoted source title, the source display name, ' \
                        'or the workbook name (SigmaLayout.resolve_header_title)'
        end
      end

      # (e) band column fill ---------------------------------------------------
      bands.each do |b|
        kids = b[:children]
        kpi_band = kids.any? && kids.length <= KPI_BAND_MAX_TILES &&
                   kids.all? { |k| el_kind[k[0]] == 'kpi-chart' }
        next if kpi_band
        covered = Array.new(GRID_COLS, false)
        kids.each do |_eid, c0, c1, _r0, _r1|
          (c0...c1).each { |c| covered[c - 1] = true if c >= 1 && c <= GRID_COLS }
        end
        fill = covered.count(true).to_f / GRID_COLS
        next if fill >= MIN_BAND_FILL
        empty_cols = covered.each_index.reject { |i| covered[i] }.map { |i| i + 1 }
        violations << format('band under-filled: container %s on page %s — %s cover %d of %d grid ' \
                             'columns (%.0f%% < %.0f%% required); dead space at columns %s — ' \
                             're-flow the band (SigmaLayout.reflow_bands) or widen the elements',
                             b[:eid], page_id,
                             kids.empty? ? 'no children' : "#{kids.length} element(s) (#{kids.map(&:first).join(', ')})",
                             covered.count(true), GRID_COLS, fill * 100, MIN_BAND_FILL * 100,
                             empty_cols.empty? ? '-' : empty_cols.slice_when { |a, x| x != a + 1 }.map { |g| g.length > 1 ? "#{g.first}-#{g.last}" : g.first.to_s }.join(', '))
      end

      # (c) dead-zone heuristic ------------------------------------------------
      spans = entries.map { |_k, _e, r0, r1| [r0, [r1, r0 + 1].max] }
                     .select { |r0, _r1| r0.positive? }
      next if spans.length < 2
      first = spans.map(&:first).min
      last  = spans.map(&:last).max
      total = last - first
      next if total <= 0
      covered = Array.new(total, false)
      spans.each { |r0, r1| (r0...r1).each { |r| covered[r - first] = true if r - first < total } }
      empty = covered.count(false)
      ratio = empty.to_f / total
      if ratio > DEAD_ZONE_MAX
        violations << format('dead zone: page %s has %d of %d grid rows empty between its first and ' \
                             'last element (%.0f%% > %.0f%% allowed) — close the gaps (banded layout)',
                             page_id, empty, total, ratio * 100, DEAD_ZONE_MAX * 100)
      end
    end

    violations
  end
end

if __FILE__ == $PROGRAM_NAME
  require 'json'
  abort 'usage: ruby layout_lint.rb <workbook-spec.json>' unless ARGV[0] && File.exist?(ARGV[0])
  v = LayoutLint.lint(JSON.parse(File.read(ARGV[0])))
  if v.empty?
    puts 'layout lint: clean'
  else
    warn "layout lint: #{v.size} violation(s):"
    v.each { |x| warn "  - #{x}" }
    exit 1
  end
end
