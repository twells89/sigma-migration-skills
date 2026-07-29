# frozen_string_literal: true
# styling.rb — Ruby twin of styling.py. Spec-authorable dashboard styling
# helpers that decorate Composition output: theme (palette), chart color,
# KPI accent, number format, header/section container. Ruby 2.6, stdlib only.
require_relative 'composition'
require 'base64'

module Styling
  # One professional, host-agnostic palette. No branding.
  DEFAULT_THEME = {
    categorical: %w[#2563EB #0EA5E9 #14B8A6 #F59E0B #8B5CF6 #EF4444 #10B981 #64748B],
    ink: '#0F172A', muted: '#64748B',
    # Task-1 verified: field is borderRadius ("round"), borderColor/borderWidth;
    # do NOT put padding alongside border fields (POST 400).
    card: { 'backgroundColor' => '#FFFFFF', 'borderColor' => '#E2E8F0',
            'borderWidth' => 1, 'borderRadius' => 'round' },
    header: { 'backgroundColor' => '#0F172A', 'borderRadius' => 'round' },
    accent: '#2563EB',
    # WS4 Task 2: neutral 3-stop gradient (dark slate -> navy -> accent blue)
    # for Styling.gradient_header. NOT red -- red is a caller override, same
    # discipline as theme(accent:) tinting the flat palette above.
    header_gradient: %w[#0F172A #1E3A8A #2563EB]
  }.freeze

  # Returns a theme; an accent override tints categorical slot 0 + accent.
  def self.theme(accent: nil)
    return DEFAULT_THEME if accent.nil? || accent.to_s.empty?
    t = Marshal.load(Marshal.dump(DEFAULT_THEME))         # deep copy (stdlib)
    t[:categorical] = [accent.to_s] + t[:categorical][1..-1]
    t[:accent] = accent.to_s
    t
  end

  # GO/NO-GO map, seeded from the live Task-1 probe
  # (.superpowers/sdd/styling-task-1-report.md, workbook
  # e0586f0d-a2cd-431c-b495-555acf3ccae0): every surface below survived
  # GET-spec readback AND rendered a real pixel hit. All 6 are GO today, but
  # gating every helper through this map (instead of hardcoding `true` at
  # each call site) means a future regression/deprecation can flip one
  # surface off in one place — the gated helper then returns an empty patch
  # instead of emitting an unverified (or 400-rejected) shape.
  SURFACES = {
    kpi_name_color: true,     # name:{text,color} on a kpi-chart (value.color bonus also GO, not emitted here)
    chart_color_by: true,     # color:{by:"single",value:"#hex"} on a chart element
    categorical_scheme: true, # workbook-level themeOverrides:{categoricalScheme:[...]}
    format_string: true,      # format:{kind:"number",formatString:<d3>} — Excel-style formatString is 400-rejected, never emitted
    container_style: true,    # container style:{backgroundColor,borderRadius,borderColor,borderWidth} (borderRadius, NOT cornerRadius; never combine with padding)
    typography: true,         # themeOverrides.titleFont + per-element name:{fontSize} — GO, but no helper below emits it (out of this task's scope); kept for a complete surface map
    # WS4 Task 2 (build-plugs-command-center.rb HDRBG probe): container
    # backgroundImage:{url:"data:image/svg+xml;base64,...",style:{fit:"cover"}}
    # carrying a composed <linearGradient>+motif SVG survived readback + a
    # real render. Two independent gates: gradient_header (the whole surface;
    # NO-GO falls back to the flat Styling.header band) and motif (the
    # optional decorative <g> layered on top; NO-GO degrades to a plain
    # gradient with no motif, never a broken shape).
    gradient_header: true,
    motif: true
  }.freeze

  # d3-format grammar (NOT Excel) — Task-1 verified surviving strings.
  D3_FORMATS = {
    currency: '$,.0f',
    integer: ',.0f',
    percent: '.1%',
    decimal: ',.2f'
  }.freeze

  # Motif menu for Styling.gradient_header (WS4 Task 2, design doc "Component
  # B" + the live-verified HDRBG concentric-ring <g> in
  # build-plugs-command-center.rb). Each fragment is a fixed, deterministic
  # SVG string local to its own origin (0,0) -- gradient_header wraps it in a
  # positioning <g transform="translate(x,86)"> per motif_side, so the
  # fragments themselves never hardcode a page position. All geometric,
  # trademark-free, white low-opacity strokes/fills. :none is the
  # empty-string identity (no motif layered on the gradient).
  GLOW_MOTIF_FRAGMENT = '<defs><radialGradient id="motif-glow" cx="0.5" cy="0.5" r="0.6">' \
                        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.2"/>' \
                        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient></defs>' \
                        '<rect x="-260" y="-105" width="520" height="210" fill="url(#motif-glow)"/>'
  RINGS_MOTIF_FRAGMENT = '<g fill="none" stroke="#FFFFFF" stroke-opacity="0.12" stroke-width="1.4">' \
                         '<circle r="40"/><circle r="74"/><circle r="108"/>' \
                         '<line x1="-130" y1="0" x2="130" y2="0"/><line x1="0" y1="-130" x2="0" y2="130"/></g>'
  GRID_MOTIF_FRAGMENT = '<defs><pattern id="motif-grid" width="40" height="40" patternUnits="userSpaceOnUse">' \
                        '<path d="M 40 0 L 0 0 0 40" fill="none" stroke="#FFFFFF" stroke-opacity="0.12" stroke-width="1"/>' \
                        '</pattern></defs><rect x="-260" y="-105" width="520" height="210" fill="url(#motif-grid)"/>'
  WAVES_MOTIF_FRAGMENT = '<g fill="none" stroke="#FFFFFF" stroke-opacity="0.14" stroke-width="2">' \
                         '<path d="M -150 0 A 150 150 0 0 1 150 0"/>' \
                         '<path d="M -110 0 A 110 110 0 0 1 110 0"/>' \
                         '<path d="M -70 0 A 70 70 0 0 1 70 0"/></g>'
  DOTS_MOTIF_FRAGMENT = '<defs><pattern id="motif-dots" width="24" height="24" patternUnits="userSpaceOnUse">' \
                        '<circle cx="4" cy="4" r="2" fill="#FFFFFF" fill-opacity="0.16"/></pattern></defs>' \
                        '<rect x="-260" y="-105" width="520" height="210" fill="url(#motif-dots)"/>'

  MOTIFS = {
    glow: -> { GLOW_MOTIF_FRAGMENT },
    rings: -> { RINGS_MOTIF_FRAGMENT },
    grid: -> { GRID_MOTIF_FRAGMENT },
    waves: -> { WAVES_MOTIF_FRAGMENT },
    dots: -> { DOTS_MOTIF_FRAGMENT },
    none: -> { '' }
  }.freeze

  # motif_side -> x translate (page-space, viewBox 0 0 1600 210); y is fixed
  # at 86 for every side (matches the HDRBG reference's vertical placement).
  GRADIENT_MOTIF_X = { right: 1440, left: 160, center: 800 }.freeze

  # Chart color patch: single-series `color:{by:"single",value:}` (categorical
  # slot 0) by default, or the workbook-level categorical-scheme patch when
  # categorical: true. NO-GO surface -> {} (nothing emitted).
  def self.chart_color(theme, categorical: false, surfaces: SURFACES)
    if categorical
      return {} unless surfaces[:categorical_scheme]
      { 'themeOverrides' => { 'categoricalScheme' => theme[:categorical] } }
    else
      return {} unless surfaces[:chart_color_by]
      { 'color' => { 'by' => 'single', 'value' => theme[:categorical][0] } }
    end
  end

  # Fragment to merge into a KPI element's `name` object: name:{text:,color:}.
  # NO-GO surface -> {} (nothing to merge).
  def self.kpi_accent(theme, surfaces: SURFACES)
    return {} unless surfaces[:kpi_name_color]
    { 'color' => theme[:accent] }
  end

  # Number-format fragment for a column's `format` field.
  # semantic: :currency / :integer / :percent / :decimal.
  def self.format_for(semantic, surfaces: SURFACES)
    return {} unless surfaces[:format_string]
    d3 = D3_FORMATS[semantic.to_sym]
    raise ArgumentError, "format_for: unknown semantic #{semantic.inspect}" if d3.nil?
    { 'kind' => 'number', 'formatString' => d3 }
  end

  # Thin full-width header band (rows 1..3): a styled `kind:container` +
  # a separate `kind:text` title child (containers have no title-rendering
  # field of their own — see reference/specification/layout.md Recipe 1),
  # plus the `<GridContainer>` layout fragment wrapping the title
  # `<LayoutElement>`. If container-style is NO-GO, returns the header as a
  # plain text element with no wrapping container (a bare `<LayoutElement>`).
  def self.header(id:, title:, theme:, page_cols: 24, surfaces: SURFACES)
    title_id = "#{id}-title"
    text_el = { 'id' => title_id, 'kind' => 'text',
                'body' => "# <span style=\"color: #FFFFFF\">#{title}</span>" }
    r0 = 1
    r1 = 3
    unless surfaces[:container_style]
      layout = "  <LayoutElement elementId=\"#{title_id}\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\"/>"
      return { element: [text_el], layout: layout }
    end
    container_id = "#{id}-bg"
    container_el = { 'id' => container_id, 'kind' => 'container', 'style' => theme[:header] }
    layout = [
      "<GridContainer elementId=\"#{container_id}\" type=\"grid\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\" " \
        "gridTemplateColumns=\"repeat(#{page_cols}, 1fr)\" gridTemplateRows=\"auto\">",
      "  <LayoutElement elementId=\"#{title_id}\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\"/>",
      '</GridContainer>'
    ].join("\n")
    { element: [container_el, text_el], layout: layout }
  end

  # Wraps one Composition.bands()-style band ({role:,ids:,r0:,r1:}) in a
  # styled card container: a `kind:container` (theme[:card]) at the band's
  # page-level rect, with its ids tiled side-by-side inside (same even
  # column split Composition.band uses, on the container's own relative row
  # range). If container-style is NO-GO, returns the band's bare
  # (unwrapped) `<LayoutElement>` render, matching plain Composition output.
  def self.section_card(id:, band:, theme:, page_cols: 24, surfaces: SURFACES)
    ids = band[:ids]
    height = band[:r1] - band[:r0]
    unless surfaces[:container_style]
      wrap = Composition.band(ids.map { |i| { id: i } }, band[:r0], band[:r1], page_cols).join("\n")
      return { element: nil, wrap: wrap }
    end
    container_el = { 'id' => id, 'kind' => 'container', 'style' => theme[:card] }
    children = Composition.band(ids.map { |i| { id: i } }, 1, 1 + height, page_cols).join("\n")
    wrap = [
      "<GridContainer elementId=\"#{id}\" type=\"grid\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{band[:r0]} / #{band[:r1]}\" " \
        "gridTemplateColumns=\"repeat(#{page_cols}, 1fr)\" gridTemplateRows=\"auto\">",
      children,
      '</GridContainer>'
    ].join("\n")
    { element: container_el, wrap: wrap }
  end

  # True when `motif` is a caller-supplied image reference (bring-your-own),
  # not a Styling::MOTIFS menu key.
  def self.bring_your_own_motif?(motif)
    motif.is_a?(String) && (motif.start_with?('http') || motif.start_with?('data:'))
  end

  # data:image/svg+xml;base64,... URI for an inline SVG string. Ruby 2.6
  # stdlib only (Base64.strict_encode64 -- no embedded newlines, unlike encode64).
  def self.svg_data_uri(svg)
    'data:image/svg+xml;base64,' + Base64.strict_encode64(svg)
  end

  # Composes the gradient_header background SVG: viewBox 0 0 1600 210, a
  # linearGradient from `gradient`'s 2-3 hex stops, plus an optional motif
  # <g> positioned per motif_side. `motif` here is always a Styling::MOTIFS
  # key (bring-your-own URLs are handled by the caller before this is
  # reached -- see gradient_header).
  def self.compose_gradient_svg(gradient, motif, motif_side)
    unless gradient.is_a?(Array) && [2, 3].include?(gradient.length)
      raise ArgumentError, "compose_gradient_svg: gradient must be an array of 2-3 hex stops (got #{gradient.inspect})"
    end
    offsets = gradient.length == 2 ? %w[0 1] : %w[0 0.5 1]
    stops = gradient.each_with_index.map { |hex, i| "<stop offset=\"#{offsets[i]}\" stop-color=\"#{hex}\"/>" }.join
    motif_key = motif.is_a?(String) ? motif.to_sym : motif
    motif_fn = MOTIFS.fetch(motif_key) { raise ArgumentError, "compose_gradient_svg: unknown motif #{motif.inspect}" }
    frag = motif_fn.call
    tx = GRADIENT_MOTIF_X.fetch(motif_side, GRADIENT_MOTIF_X[:right])
    motif_group = frag.empty? ? '' : "<g transform=\"translate(#{tx},86)\">#{frag}</g>"
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 210" preserveAspectRatio="xMidYMid slice">' \
      "<defs><linearGradient id=\"hg\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0.45\">#{stops}</linearGradient></defs>" \
      "<rect width=\"1600\" height=\"210\" fill=\"url(#hg)\"/>#{motif_group}</svg>"
  end

  # Sleek gradient header band (rows 1..4): a container whose backgroundImage
  # is a composed data-URI SVG (linearGradient + optional motif), an optional
  # left-side logo image, a white title text element, and an optional
  # subtitle text element. Same { element:, layout: } contract as
  # Styling.header. `motif:` is a Styling::MOTIFS key (default :glow) or a
  # bring-your-own `http`/`data:` URL string used verbatim as the background
  # (SVG compose skipped). NO-GO gradient_header falls back to the existing
  # flat Styling.header band (graceful, never a broken/fake surface). NO-GO
  # motif (gradient_header still GO) silently drops the motif <g>, keeping
  # the plain gradient -- also graceful, never broken.
  def self.gradient_header(id:, title:, subtitle: nil, gradient: DEFAULT_THEME[:header_gradient],
                            motif: :glow, motif_side: :right, logo_url: nil, page_cols: 24, surfaces: SURFACES)
    unless surfaces[:gradient_header]
      return header(id: id, title: title, theme: DEFAULT_THEME, page_cols: page_cols, surfaces: surfaces)
    end

    effective_motif = surfaces[:motif] ? motif : :none
    bg_url = if bring_your_own_motif?(effective_motif)
               effective_motif
             else
               svg_data_uri(compose_gradient_svg(gradient, effective_motif, motif_side))
             end

    container_id = "#{id}-bg"
    logo_id = "#{id}-logo"
    title_id = "#{id}-title"
    subtitle_id = "#{id}-subtitle"

    container_el = { 'id' => container_id, 'kind' => 'container', 'style' => { 'borderRadius' => 'round' },
                     'backgroundImage' => { 'url' => bg_url, 'style' => { 'fit' => 'cover' } } }
    title_el = { 'id' => title_id, 'kind' => 'text', 'verticalAlign' => 'middle',
                 'body' => "# <span style=\"color: #FFFFFF\">#{title}</span>" }

    elements = [container_el]
    elements << { 'id' => logo_id, 'kind' => 'image', 'url' => logo_url, 'style' => { 'fit' => 'contain' } } if logo_url
    elements << title_el
    if subtitle
      elements << { 'id' => subtitle_id, 'kind' => 'text', 'verticalAlign' => 'middle',
                    'body' => "<span style=\"color: #CBD5E1\">#{subtitle}</span>" }
    end

    r0 = 1
    r1 = 4
    title_r1 = subtitle ? 3 : r1
    text_c0 = logo_url ? 3 : 1
    lines = ["<GridContainer elementId=\"#{container_id}\" type=\"grid\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\" " \
              "gridTemplateColumns=\"repeat(#{page_cols}, 1fr)\" gridTemplateRows=\"auto\">"]
    lines << "  <LayoutElement elementId=\"#{logo_id}\" gridColumn=\"1 / 3\" gridRow=\"#{r0} / #{r1}\"/>" if logo_url
    lines << "  <LayoutElement elementId=\"#{title_id}\" gridColumn=\"#{text_c0} / #{page_cols + 1}\" gridRow=\"#{r0} / #{title_r1}\"/>"
    if subtitle
      lines << "  <LayoutElement elementId=\"#{subtitle_id}\" gridColumn=\"#{text_c0} / #{page_cols + 1}\" gridRow=\"#{title_r1} / #{r1}\"/>"
    end
    lines << '</GridContainer>'

    { element: elements, layout: lines.join("\n") }
  end
end
