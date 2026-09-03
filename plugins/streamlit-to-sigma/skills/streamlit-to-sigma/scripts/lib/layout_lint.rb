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
#   (b) orphan controls — input controls placed OUTSIDE any <Container>
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
#   (e) band column fill — a band (top-level Container) whose children
#       cover <60% of the 24 grid columns, i.e. shipped dead space (the
#       PHASEE2 PBI regression: band 1 = one small bar chart at columns 1-6
#       next to a 19-column hole). Deliberate KPI bands (<=4 tiles, all
#       kpi-chart) are exempt.
#   (f) sub-minimum tile height — an element whose gridRow span is below its
#       kind's minimum (KIND_MIN_ROWS). Sigma renders chart/KPI tiles BLANK
#       under ~3-4 grid rows — in the live page AND in page/element PNG
#       exports (hit twice in a 2026-07 live migration). Element kinds come
#       from the spec's flat document elements; layout-only container shells (no spec
#       kind) are skipped. A child's span is measured in its own container's
#       row units (matched-inner-span convention: inner rows track page rows).
#
# API:
#   violations = LayoutLint.lint(spec)   # spec = parsed workbook spec Hash
#   -> array of human-readable violation strings; empty = clean.
#
# Standalone:
#   ruby scripts/lib/layout_lint.rb <spec.json>   # exit 1 + list on violations
require_relative 'code_rep'

module LayoutLint
  RAW_ID_NAME = /\A(?:[0-9a-f]{12,}|el-[0-9a-f]+)\z/i
  DEAD_ZONE_MAX = 0.25
  GENERIC_HEADER = /\A(?:page|sheet|dashboard)\s*\d+\z/i
  GRID_COLS = 24
  MIN_BAND_FILL = 0.60
  KPI_BAND_MAX_TILES = 4
  # Per-kind minimum gridRow spans (check f). KEEP IN SYNC with
  # SigmaLayout::KIND_MIN_ROWS (lib/layout.rb) — this lib is vendored
  # standalone across plugins, so it carries its own copy. 'chart' covers
  # every *-chart kind without an explicit entry.
  KIND_MIN_ROWS = {
    'kpi-chart'   => 4,  # value + label need ~4 rows to render at all
    'chart'       => 8,  # axis/labels suppressed and tile blanks below ~8
    'table'       => 10, # header row + a few data rows
    'pivot-table' => 10,
    'control'     => 2,  # one input strip; 2 rows keeps the label visible
    'text'        => 2,
    'divider'     => 1,  # hairline rule — stroke centers in the cell
    'button'      => 2   # control-sized pill
  }.freeze

  module_function

  # Minimum gridRow span for a Sigma element kind (see KIND_MIN_ROWS).
  def min_rows_for(kind)
    k = kind.to_s
    return KIND_MIN_ROWS[k] if KIND_MIN_ROWS.key?(k)
    return KIND_MIN_ROWS['chart'] if k.end_with?('-chart')
    KIND_MIN_ROWS['text']
  end

  # All [element, page] pairs in the workbook document. Elements are flat;
  # page metadata is joined through the required layout's <Page> membership.
  # Layout-only container shells are naturally skipped because they are not in
  # document.elements.
  def named_elements(spec)
    Sigma::CodeRep.workbook_elements_with_pages(spec)
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
    while (m = s.match(%r{<(Container|GridContainer|Element|LayoutElement)\b([^>]*?)(/>|>)}m, pos))
      tag, attrs, close = m[1], m[2], m[3]
      container = %w[Container GridContainer].include?(tag)
      eid = attrs[/elementId="([^"]*)"/, 1]
      rows = attrs[/gridRow="\s*(\d+)\s*/, 1].to_i
      rowe = attrs[/gridRow="\s*\d+\s*\/\s*(\d+)\s*"/, 1].to_i
      if container && close == '>'
        endm = s.match(%r{</#{tag}>}m, m.end(0))
        entries << [:container, eid, rows, rowe]
        pos = endm ? endm.end(0) : m.end(0)
      else
        entries << [container ? :container : :element, eid, rows, rowe]
        pos = m.end(0)
      end
    end
    entries
  end

  # Top-level Containers of a page block with their direct children:
  # [{eid:, r0:, r1:, children: [[child_eid, c0, c1, r0, r1], ...]}, ...]
  # The column count a container's children are laid out against — its OWN
  # gridTemplateColumns (a child's gridColumn refs are LOCAL to its container,
  # not the page's 24-col grid). "repeat(N, ...)" -> N; an explicit track list
  # -> token count; absent -> the page-grid default. A vertical rail declares
  # repeat(1, 1fr): one full-width column, NOT 1/24 of the page.
  def grid_col_count(attrs)
    tmpl = attrs.to_s[/gridTemplateColumns="([^"]*)"/, 1]
    return GRID_COLS if tmpl.nil? || tmpl.strip.empty?
    if (rep = tmpl[/repeat\(\s*(\d+)/, 1])
      return [[rep.to_i, 1].max, GRID_COLS * 4].min
    end
    n = tmpl.strip.split(/\s+/).reject(&:empty?).length
    n.positive? ? n : GRID_COLS
  end

  # NESTING-AWARE Container extraction. The old version matched the FIRST
  # </Container> after an open tag, so an OUTER band's body was truncated
  # at its first nested container's close — the band then appeared to hold
  # only that fragment's leaves and false-failed the fill check on every
  # container-tree layout (live-caught: the whole-page content container
  # "held" only the region control). Children are the container's DIRECT
  # Elements PLUS its direct child containers' spans (a nested
  # container's own leaves live in a different local column space, but the
  # container itself covers its gridColumn span in the parent's grid).
  def containers(page_xml)
    out = []
    stack = []
    span = lambda do |tag|
      [tag[/elementId="([^"]*)"/, 1],
       tag[/gridColumn="\s*(\d+)/, 1].to_i, tag[/gridColumn="\s*\d+\s*\/\s*(\d+)/, 1].to_i,
       tag[/gridRow="\s*(\d+)/, 1].to_i, tag[/gridRow="\s*\d+\s*\/\s*(\d+)/, 1].to_i]
    end
    page_xml.to_s.scan(
      %r{</(?:Container|GridContainer)>|<(?:Container|GridContainer)\b[^>]*?/?>|<(?:Element|LayoutElement)\b[^>]*?/?>}m
    ) do
      tag = Regexp.last_match(0)
      if tag.match?(%r{\A</(?:Container|GridContainer)})
        c = stack.pop
        out << c if c
      elsif tag.match?(%r{\A<(?:Container|GridContainer)\b})
        stack.last[:children] << span.call(tag) unless stack.empty?
        c = { eid: tag[/elementId="([^"]*)"/, 1], cols: grid_col_count(tag),
              r0: tag[/gridRow="\s*(\d+)/, 1].to_i,
              r1: tag[/gridRow="\s*\d+\s*\/\s*(\d+)/, 1].to_i,
              children: [] }
        tag.end_with?('/>') ? (out << c) : (stack << c)
      else # Element — a direct child of the innermost open container
        stack.last[:children] << span.call(tag) unless stack.empty?
      end
    end
    out.concat(stack) # tolerate unclosed tags rather than dropping them
    out
  end

  # A text element's body reduced to its visible text (markdown/HTML stripped).
  def plain_text(body)
    body.to_s.gsub(%r{<[^>]+>}, '').gsub(/^#+\s*/, '').gsub(/[*_`]/, '').strip
  end

  def lint(spec)
    spec = Sigma::CodeRep.document(spec)
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
      page_name = pg && (pg['name'] || pg['id'])
      violations << "raw-id display name: element #{el['id']} (#{el['kind']}) on page " \
                    "'#{page_name || '(unplaced: missing from layout)'}' is named #{name.inspect} — derive a human title " \
                    '(the source visual had no explicit title; see derived_title in the builder)'
    end

    page_blocks(spec['layout']).each do |page_id, body|
      next if page_id.to_s.downcase.include?('data')
      entries = top_level_entries(body)
      next if entries.empty?

      # (b) controls outside any container on a containered page --------------
      # A top-level control is fine when it sits in the control region ABOVE the
      # first section band (the standard "filter over a banded grid" pattern the
      # exemplar hand migrations use). It's only orphaned when it floats AT or
      # BELOW the first band — i.e. lost among the banded chart content.
      if body.match?(%r{<(?:Container|GridContainer)\b})
        first_band_r0 = entries.select { |k,| k == :container }.map { |e| e[2] }.min
        entries.each do |kind, eid, r0, _r1|
          next unless kind == :element && el_kind[eid] == 'control'
          next if first_band_r0 && r0.positive? && r0 < first_band_r0
          violations << "orphan control: #{eid} sits OUTSIDE every Container on page #{page_id} " \
                        'and is not in the control region above the first band — place it in the ' \
                        'control band or its chart\'s container'
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
        # A control-only band is sparse BY DESIGN: source dashboards render a
        # narrow parameter/filter row with the rest of the band empty, and
        # stretching a lone dropdown to 60% width would be a fidelity bug, not
        # a fix. (The orphan-control check above still catches controls parked
        # OUTSIDE any band.)
        next if kids.any? && kids.all? { |k| el_kind[k[0]] == 'control' }
        # Measure fill against the container's OWN column count — a child's
        # gridColumn is local to its container's gridTemplateColumns. A vertical
        # rail (repeat(1, 1fr)) whose children fill its one column is 100% full,
        # not 1/24 (was a false-positive hard-fail on every sidebar layout).
        ncols = b[:cols] || GRID_COLS
        covered = Array.new(ncols, false)
        kids.each do |_eid, c0, c1, _r0, _r1|
          (c0...c1).each { |c| covered[c - 1] = true if c >= 1 && c <= ncols }
        end
        fill = covered.count(true).to_f / ncols
        next if fill >= MIN_BAND_FILL
        empty_cols = covered.each_index.reject { |i| covered[i] }.map { |i| i + 1 }
        violations << format('band under-filled: container %s on page %s — %s cover %d of %d grid ' \
                             'columns (%.0f%% < %.0f%% required); dead space at columns %s — ' \
                             're-flow the band (SigmaLayout.reflow_bands) or widen the elements',
                             b[:eid], page_id,
                             kids.empty? ? 'no children' : "#{kids.length} element(s) (#{kids.map(&:first).join(', ')})",
                             covered.count(true), ncols, fill * 100, MIN_BAND_FILL * 100,
                             empty_cols.empty? ? '-' : empty_cols.slice_when { |a, x| x != a + 1 }.map { |g| g.length > 1 ? "#{g.first}-#{g.last}" : g.first.to_s }.join(', '))
      end

      # (f) sub-minimum tile height --------------------------------------------
      tiles = entries.select { |k, _e, _r0, _r1| k == :element }
                     .map { |_k, eid, r0, r1| [eid, r0, r1] }
      bands.each do |b|
        b[:children].each { |ceid, _c0, _c1, r0, r1| tiles << [ceid, r0, r1] }
      end
      tiles.each do |eid, r0, r1|
        kind = el_kind[eid]
        next if kind.nil? || kind == 'container' # layout-only shells
        min = min_rows_for(kind)
        span = [r1 - r0, 0].max
        next if span >= min
        violations << format('tile below minimum height: element %s (%s) on page %s spans %d grid row(s) ' \
                             '(< %d required for %s) — Sigma renders sub-minimum tiles BLANK in the page ' \
                             'and in PNG exports; grow the tile (see SigmaLayout::KIND_MIN_ROWS)',
                             eid, kind, page_id, span, min, kind)
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
