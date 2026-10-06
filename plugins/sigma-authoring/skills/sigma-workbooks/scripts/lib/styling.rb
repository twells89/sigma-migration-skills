# frozen_string_literal: true
# styling.rb — spec-authorable dashboard styling helpers that decorate
# Composition output: theme (palette), chart color, KPI accent, number
# format, header/section container. Ruby 2.6+, stdlib only.
require_relative 'composition'
require 'base64'

module Styling
  # Authoring-only semantic color roles. Resolve to hex / theme refs before
  # any value is written into a Sigma spec field — never
  # serialize these role names as invented Sigma fields.
  ROLE_NAMES = %i[
    canvas ink body muted hairline fill
    series series-mid series-grey primary tint edge
  ].freeze

  # Map roles onto the current verified palette (same hexes DEFAULT_THEME
  # historically carried). Not a new design system — one indirection layer.
  DEFAULT_ROLES = {
    canvas: '#FFFFFF',           # page / app-shell surface
    ink: '#0F172A',              # hero band + primary dark
    body: '#1E293B',             # dark slate (card_gradient start)
    muted: '#64748B',            # secondary text + quiet labels
    hairline: '#E2E8F0',         # card / shell borders
    fill: '#FFFFFF',             # card fill
    series: '#2563EB',           # categorical slot 0
    :'series-mid' => '#0EA5E9',  # categorical slot 1
    :'series-grey' => '#64748B', # categorical slot 7
    primary: '#2563EB',          # accent / KPI title
    tint: '#1E3A8A',             # navy mid-stop (header_gradient)
    edge: '#FFFFFF'              # on-dark title / high-contrast edge
  }.freeze

  # Categorical slots 2..6 stay fixed verified hues (no dedicated roles).
  CATEGORICAL_MID = %w[#14B8A6 #F59E0B #8B5CF6 #EF4444 #10B981].freeze

  HEX_COLOR = /\A#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?\z/.freeze

  def self.role_key(name)
    name.is_a?(Symbol) ? name : name.to_s.to_sym
  end
  private_class_method :role_key

  # Deep-copy a roles hash without mutating the input. Keys normalized to symbols.
  def self.copy_roles(roles)
    out = {}
    roles.each { |k, v| out[role_key(k)] = (v.is_a?(Hash) ? v.dup : v) }
    out
  end
  private_class_method :copy_roles

  # Merge caller overrides onto a base role map. Never mutates base or overrides.
  def self.merge_roles(base, overrides)
    return copy_roles(base) if overrides.nil? || overrides.empty?
    merged = copy_roles(base)
    overrides.each { |k, v| merged[role_key(k)] = (v.is_a?(Hash) ? v.dup : v) }
    merged
  end
  private_class_method :merge_roles

  # True when `value` is already a supported Sigma color payload for a concrete
  # color field: hex or `{kind:"theme",ref:}`.
  def self.resolved_color?(value)
    case value
    when String
      value.match?(HEX_COLOR)
    when Hash
      kind = value['kind'] || value[:kind]
      ref = value['ref'] || value[:ref]
      kind.to_s == 'theme' && !ref.nil? && !ref.to_s.empty?
    else
      false
    end
  end
  private_class_method :resolved_color?

  # Resolve an authoring role (or an already-resolved color) against a role map.
  # Returns hex / theme-ref only — never a bare role name.
  def self.resolve(role, roles: DEFAULT_ROLES)
    return role.dup if role.is_a?(Hash) && resolved_color?(role)
    return role if role.is_a?(String) && resolved_color?(role)
    key = role_key(role)
    map = roles.equal?(DEFAULT_ROLES) ? DEFAULT_ROLES : merge_roles(DEFAULT_ROLES, roles)
    unless map.key?(key)
      raise ArgumentError, "resolve: unknown role #{role.inspect}"
    end
    value = map[key]
    unless resolved_color?(value)
      raise ArgumentError, "resolve: role #{key.inspect} maps to unsupported color #{value.inspect}"
    end
    value.is_a?(Hash) ? value.dup : value
  end

  def self.validate_role_overrides!(roles)
    return if roles.nil? || roles.empty?
    normalized = copy_roles(roles)
    unknown = normalized.keys - ROLE_NAMES
    unless unknown.empty?
      raise ArgumentError, "theme: unknown role override(s) #{unknown.map(&:inspect).join(', ')}"
    end
    normalized.each do |role, value|
      next if value.is_a?(String) && value.match?(HEX_COLOR)
      raise ArgumentError, "theme: role #{role.inspect} must map to hex (got #{value.inspect})"
    end
  end
  private_class_method :validate_role_overrides!

  # Build the compatibility theme shape from a (possibly overridden) role map.
  def self.theme_from_roles(roles)
    r = roles
    {
      categorical: [
        r[:series], r[:'series-mid'],
        *CATEGORICAL_MID,
        r[:'series-grey']
      ],
      ink: r[:ink], muted: r[:muted],
      # Verified live: field is borderRadius ("round"), borderColor/borderWidth;
      # do NOT put padding alongside border fields (POST 400).
      card: { 'backgroundColor' => r[:fill], 'borderColor' => r[:hairline],
              'borderWidth' => 1, 'borderRadius' => 'round' },
      header: { 'backgroundColor' => r[:ink], 'borderRadius' => 'round' },
      # Compact operational app shell. Unlike :header this is deliberately
      # light, square, and utility-shaped — app identity/navigation/context,
      # not a dashboard hero.
      app_shell: { 'backgroundColor' => r[:canvas], 'borderColor' => r[:hairline],
                   'borderWidth' => 1 },
      accent: r[:primary],
      # Neutral 3-stop gradient (dark slate -> navy -> accent blue) for
      # Styling.gradient_header. NOT red -- red is a caller override, same
      # discipline as theme(accent:) tinting the flat palette above.
      header_gradient: [r[:ink], r[:tint], r[:primary]],
      # Live-render fix: dark default so Styling.gradient_card's `gradient:`
      # can be omitted -- a caller with no brand gradient in mind still gets a
      # legible dark card (paired with the scrim in compose_card_svg below,
      # white KPI text stays legible either way).
      card_gradient: [r[:body], r[:ink]]
    }
  end
  private_class_method :theme_from_roles

  # One professional, host-agnostic palette. Derived from DEFAULT_ROLES so the
  # compatibility shape stays byte-identical to the historical DEFAULT_THEME.
  DEFAULT_THEME = theme_from_roles(DEFAULT_ROLES).freeze

  # Returns a theme derived from roles. `roles:` is a partial or full role→color
  # map (caller-owned — never mutated). `accent:` tints categorical slot 0 +
  # accent (same contract as before).
  def self.theme(accent: nil, roles: nil)
    validate_role_overrides!(roles)
    if (roles.nil? || roles.empty?) && (accent.nil? || accent.to_s.empty?)
      return DEFAULT_THEME
    end
    base_roles = merge_roles(DEFAULT_ROLES, roles)
    t = theme_from_roles(base_roles)
    return t if accent.nil? || accent.to_s.empty?
    t[:categorical] = [accent.to_s] + t[:categorical][1..-1]
    t[:accent] = accent.to_s
    t
  end

  # GO/NO-GO map, seeded from a live spec-readback probe against a real Sigma
  # org: every surface below survived GET-spec readback AND rendered a real
  # pixel hit. All 6 are GO today, but gating every helper through this map
  # (instead of hardcoding `true` at each call site) means a future
  # regression/deprecation can flip one surface off in one place — the gated
  # helper then returns an empty patch instead of emitting an unverified (or
  # 400-rejected) shape.
  SURFACES = {
    kpi_name_color: true,     # name:{text,color} on a kpi-chart (value.color bonus also GO, not emitted here)
    chart_color_by: true,     # color:{by:"single",value:"#hex"} on a chart element
    categorical_scheme: true, # document.settings.theme.overrides:{categoricalScheme:[...]}
    format_string: true,      # format:{kind:"number",formatString:<d3>} — Excel-style formatString is 400-rejected, never emitted
    container_style: true,    # container style:{backgroundColor,borderRadius,borderColor,borderWidth} (borderRadius, NOT cornerRadius; never combine with padding)
    typography: true,         # settings.theme.overrides.titleFont + per-element name:{fontSize} — verified GO live, but no helper below emits it (out of scope here); kept for a complete surface map
    # A container backgroundImage:{url:"data:image/svg+xml;base64,...",
    # style:{fit:"cover"}} carrying a composed <linearGradient>+motif SVG
    # survived readback + a real render. Two independent gates:
    # gradient_header (the whole surface; NO-GO falls back to the flat
    # Styling.header band) and motif (the optional decorative <g> layered on
    # top of a *menu-key* motif; NO-GO degrades that case to a plain gradient
    # with no motif, never a broken shape. It does NOT touch a bring-your-own
    # image URL -- that path has nothing to do with the decorative
    # SVG-fragment library this gate protects, so it is honored
    # unconditionally).
    gradient_header: true,
    motif: true,
    # A gradient backgroundImage CARD container (Styling.gradient_card,
    # wrapping a caller-built kpi-chart with a white-text patch) and a
    # separate borderless `line-chart` composite sparkline (Styling.sparkline)
    # both survived readback + a real render. NO-GO gradient_card -> the
    # empty {element:[],child_layout:'',patch:{}} marker (graceful — never
    # mutates or half-decorates the caller's kpi_element). NO-GO sparkline ->
    # {'opt_in'=>true,'id'=>} (never a faked chart shape). Live-render fix
    # (user-reported "can't see the numbers"): gradient_card's composed
    # background now also carries a dark scrim (see compose_card_svg/
    # CARD_SCRIM_TOP_OPACITY) so white KPI text stays legible on ANY caller
    # gradient, not just dark ones.
    gradient_card: true,
    sparkline: true
  }.freeze

  # d3-format grammar (NOT Excel) — verified live, surviving strings.
  D3_FORMATS = {
    currency: '$,.0f',
    integer: ',.0f',
    percent: '.1%',
    decimal: ',.2f'
  }.freeze

  # Opacity of the dark scrim composed behind a gradient_card's top band
  # (where the KPI name+value sit), fading to 0 by the bottom (where a
  # sparkline sits) -- see compose_card_svg. A single named constant so a
  # future legibility regression is a one-line tune, not a hunt through the
  # SVG string.
  CARD_SCRIM_TOP_OPACITY = 0.55

  # Motif menu for Styling.gradient_header. Each fragment is a fixed,
  # deterministic SVG string local to its own origin (0,0) -- gradient_header
  # wraps it in a positioning <g transform="translate(x,86)"> per motif_side,
  # so the fragments themselves never hardcode a page position. All
  # geometric, trademark-free, white low-opacity strokes/fills. :none is the
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
  # at 86 for every side.
  GRADIENT_MOTIF_X = { right: 1440, left: 160, center: 800 }.freeze

  # Chart color patch: single-series `color:{by:"single",value:}` (categorical
  # slot 0) by default, or the workbook-level categorical-scheme patch when
  # categorical: true. NO-GO surface -> {} (nothing emitted).
  def self.chart_color(theme, categorical: false, surfaces: SURFACES)
    if categorical
      return {} unless surfaces[:categorical_scheme]
      # Workbook-level palette patch at settings.theme.overrides (the removed
      # top-level themeOverrides key is silently dropped by the API).
      # NOTE for callers: this is a NESTED patch, so deep-merge it into the spec;
      # a shallow merge of `settings` would clobber sibling settings (navigation).
      { 'settings' => { 'theme' => { 'overrides' => { 'categoricalScheme' => theme[:categorical] } } } }
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
  # plus the `<Container>` layout fragment wrapping the title
  # `<Element>`. If container-style is NO-GO, returns the header as a
  # plain text element with no wrapping container (a bare `<Element>`).
  def self.header(id:, title:, theme:, page_cols: 24, surfaces: SURFACES)
    title_id = "#{id}-title"
    text_el = { 'id' => title_id, 'kind' => 'text',
                'body' => "# <span style=\"color: #FFFFFF\">#{title}</span>" }
    r0 = 1
    r1 = 3
    unless surfaces[:container_style]
      layout = "  <Element elementId=\"#{title_id}\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\"/>"
      return { element: [text_el], layout: layout }
    end
    container_id = "#{id}-bg"
    container_el = { 'id' => container_id, 'kind' => 'container', 'style' => theme[:header] }
    layout = [
      "<Container elementId=\"#{container_id}\" type=\"grid\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\" " \
        "gridTemplateColumns=\"repeat(#{page_cols}, 1fr)\" gridTemplateRows=\"auto\">",
      "  <Element elementId=\"#{title_id}\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\"/>",
      '</Container>'
    ].join("\n")
    { element: [container_el, text_el], layout: layout }
  end

  # Compact app-level shell around caller-authored identity, navigation, and
  # utility elements. The children stay caller-owned because navigation may be
  # a real `kind:navigation`, text tabs, or a button depending on the workbook.
  # This helper only supplies tested container/style/layout structure.
  #
  # Three children: 6/24 identity, 11/24 navigation, 7/24 utility.
  # Two children redistribute the missing slot; one child fills the row.
  def self.app_shell(id:, identity_id:, navigation_id: nil, utility_id: nil,
                     theme: DEFAULT_THEME, page_cols: 24, r0: 1, r1: 4,
                     surfaces: SURFACES)
    raise ArgumentError, 'app_shell: id required' if id.to_s.empty?
    raise ArgumentError, 'app_shell: identity_id required' if identity_id.to_s.empty?
    children = [identity_id, navigation_id, utility_id].compact
    raise ArgumentError, 'app_shell: child ids must be unique' unless children.uniq.size == children.size

    placements = if navigation_id && utility_id
                   [[identity_id, 1, 7], [navigation_id, 7, 18], [utility_id, 18, page_cols + 1]]
                 elsif navigation_id
                   [[identity_id, 1, 7], [navigation_id, 7, page_cols + 1]]
                 elsif utility_id
                   [[identity_id, 1, 13], [utility_id, 13, page_cols + 1]]
                 else
                   [[identity_id, 1, page_cols + 1]]
                 end
    leaves = placements.map { |child_id, c0, c1| Composition.le(child_id, c0, c1, 1, r1 - r0 + 1) }
    unless surfaces[:container_style]
      bare = placements.map { |child_id, c0, c1| Composition.le(child_id, c0, c1, r0, r1) }
      return { element: nil, layout: bare.join("\n") }
    end

    container = {
      'id' => id,
      'kind' => 'container',
      'style' => theme[:app_shell] || DEFAULT_THEME[:app_shell]
    }
    layout = [
      "<Container elementId=\"#{id}\" type=\"grid\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\" " \
        "gridTemplateColumns=\"repeat(#{page_cols}, 1fr)\" gridTemplateRows=\"auto\">",
      leaves.join("\n"),
      '</Container>'
    ].join("\n")
    { element: container, layout: layout }
  end

  # Wraps one Composition.bands()-style band ({role:,ids:,r0:,r1:}) in a
  # styled card container: a `kind:container` (theme[:card]) at the band's
  # page-level rect, with its ids tiled side-by-side inside (same even
  # column split Composition.band uses, on the container's own relative row
  # range). If container-style is NO-GO, returns the band's bare
  # (unwrapped) `<Element>` render, matching plain Composition output.
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
      "<Container elementId=\"#{id}\" type=\"grid\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{band[:r0]} / #{band[:r1]}\" " \
        "gridTemplateColumns=\"repeat(#{page_cols}, 1fr)\" gridTemplateRows=\"auto\">",
      children,
      '</Container>'
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
  # motif (gradient_header still GO) silently drops the motif <g> for a
  # *menu-key* motif, keeping the plain gradient -- also graceful, never
  # broken. A bring-your-own motif URL is checked FIRST and honored
  # unconditionally, regardless of SURFACES[:motif] -- that gate exists only
  # to protect the decorative SVG-fragment library, not the caller's own
  # image (an arbitrary URL in backgroundImage.url either way).
  def self.gradient_header(id:, title:, subtitle: nil, gradient: DEFAULT_THEME[:header_gradient],
                            motif: :glow, motif_side: :right, logo_url: nil, page_cols: 24, surfaces: SURFACES)
    unless surfaces[:gradient_header]
      return header(id: id, title: title, theme: DEFAULT_THEME, page_cols: page_cols, surfaces: surfaces)
    end

    bg_url = if bring_your_own_motif?(motif)
               motif
             else
               effective_motif = surfaces[:motif] ? motif : :none
               svg_data_uri(compose_gradient_svg(gradient, effective_motif, motif_side))
             end

    container_id = "#{id}-bg"
    logo_id = "#{id}-logo"
    title_id = "#{id}-title"
    subtitle_id = "#{id}-subtitle"

    # Live API contract update (2026-08-08): backgroundImage now requires the
    # url nested under source:{kind:"url",url:} -- the old flat
    # backgroundImage:{url:} shape hard-400s ("backgroundImage.source: Invalid
    # value: undefined"). style stays a sibling of source.
    container_el = { 'id' => container_id, 'kind' => 'container', 'style' => { 'borderRadius' => 'round' },
                     'backgroundImage' => { 'source' => { 'kind' => 'url', 'url' => bg_url }, 'style' => { 'fit' => 'cover' } } }
    title_el = { 'id' => title_id, 'kind' => 'text', 'verticalAlign' => 'center',
                 'body' => "# <span style=\"color: #FFFFFF\">#{title}</span>" }

    elements = [container_el]
    elements << { 'id' => logo_id, 'kind' => 'image', 'url' => logo_url, 'style' => { 'fit' => 'contain' } } if logo_url
    elements << title_el
    if subtitle
      elements << { 'id' => subtitle_id, 'kind' => 'text', 'verticalAlign' => 'center',
                    'body' => "<span style=\"color: #CBD5E1\">#{subtitle}</span>" }
    end

    r0 = 1
    r1 = 4
    title_r1 = subtitle ? 3 : r1
    text_c0 = logo_url ? 3 : 1
    lines = ["<Container elementId=\"#{container_id}\" type=\"grid\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"#{r0} / #{r1}\" " \
              "gridTemplateColumns=\"repeat(#{page_cols}, 1fr)\" gridTemplateRows=\"auto\">"]
    lines << "  <Element elementId=\"#{logo_id}\" gridColumn=\"1 / 3\" gridRow=\"#{r0} / #{r1}\"/>" if logo_url
    lines << "  <Element elementId=\"#{title_id}\" gridColumn=\"#{text_c0} / #{page_cols + 1}\" gridRow=\"#{r0} / #{title_r1}\"/>"
    if subtitle
      lines << "  <Element elementId=\"#{subtitle_id}\" gridColumn=\"#{text_c0} / #{page_cols + 1}\" gridRow=\"#{title_r1} / #{r1}\"/>"
    end
    lines << '</Container>'

    { element: elements, layout: lines.join("\n") }
  end

  # Composes the gradient_card background SVG (live-render fix, user-reported
  # "can't see the numbers"): same viewBox + gradient-rect technique as
  # compose_gradient_svg (always motif :none -- a card this small has no room
  # for a decorative mark), PLUS a second rect layered on top filled with a
  # vertical black scrim `linearGradient` -- CARD_SCRIM_TOP_OPACITY opacity
  # at the top (y=0, where the KPI name+value sit) fading to 0 opacity by
  # the bottom (y=210, where a Styling.sparkline sits) -- so a white KPI
  # value stays legible on ANY caller gradient, bright or dark, while the
  # brand gradient still reads through in the lower half (never fully
  # blacked out). Kept as its own composer (not a compose_gradient_svg
  # option) so gradient_header's output -- already live-verified without a
  # scrim -- is untouched.
  def self.compose_card_svg(gradient)
    unless gradient.is_a?(Array) && [2, 3].include?(gradient.length)
      raise ArgumentError, "compose_card_svg: gradient must be an array of 2-3 hex stops (got #{gradient.inspect})"
    end
    offsets = gradient.length == 2 ? %w[0 1] : %w[0 0.5 1]
    stops = gradient.each_with_index.map { |hex, i| "<stop offset=\"#{offsets[i]}\" stop-color=\"#{hex}\"/>" }.join
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 210" preserveAspectRatio="xMidYMid slice">' \
      "<defs><linearGradient id=\"cg\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0.45\">#{stops}</linearGradient>" \
      "<linearGradient id=\"card-scrim\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">" \
      "<stop offset=\"0\" stop-color=\"#000000\" stop-opacity=\"#{CARD_SCRIM_TOP_OPACITY}\"/>" \
      '<stop offset="1" stop-color="#000000" stop-opacity="0"/></linearGradient></defs>' \
      '<rect width="1600" height="210" fill="url(#cg)"/><rect width="1600" height="210" fill="url(#card-scrim)"/></svg>'
  end

  # Wraps a caller-built kpi-chart element (a Hash, e.g. from KpiCard.build)
  # in a gradient backgroundImage CARD container. Decorate-only, like
  # `section_card`: `kpi_element` is READ ONLY here (its `id` is read to
  # build `child_layout`) -- it is never mutated, and `kpi_card.rb` is never
  # touched. Instead this returns a `patch` Hash the caller MERGES (never
  # replaces) onto their own copy of three top-level keys on the kpi element:
  #   kpi_element['value'] = kpi_element['value'].merge(patch['value'])
  #   kpi_element['name']  = kpi_element['name'].merge(patch['name'])
  #   kpi_element['style'] = (kpi_element['style'] || {}).merge(patch['style'])
  # A shallow `Hash#merge` is REQUIRED, not a wholesale replace of the
  # `value`/`name` hashes -- kpi_element['value'] carries `columnId` (and
  # optionally `fontSize`) that this patch must not clobber; merge overlays
  # only the `color` key. `patch['style']` (live-render fix): the KpiCard.build
  # shape never sets a `style` key of its own, so this is additive, but
  # callers should still merge rather than assign in case a future
  # kpi_element does carry one. Turning the value + title white is not
  # enough by itself -- the KPI element still keeps its own opaque
  # background, so a live render shows white-on-white; `patch['style']` sets
  # `backgroundColor: 'transparent'` (letting the gradient card behind show
  # through) and `padding: 'none'` (edge-to-edge) so the white value/title
  # are actually legible against the gradient. `gradient:` is OPTIONAL --
  # it defaults to `DEFAULT_THEME[:card_gradient]` (a dark slate pair), so a
  # caller with no brand gradient in mind still gets a legible dark card;
  # pass a caller-specific 2-3 hex-stop array to override it (distinct KPI
  # cards typically carry distinct gradients). The composed background is
  # now TWO layers (see compose_card_svg): the gradient rect, then a dark
  # scrim -- this is what makes the white value/title legible on a
  # bright/medium gradient too, not just a dark one (live-render fix,
  # user-reported "can't see the numbers"). `child_layout` is only the
  # inner `<Element>` fragment positioning `kpi_element`'s id inside
  # the container at the Composition kpi-band height (rows 1..7, matching
  # `Composition.bands`' own `:kpi` role height) -- placing the container
  # itself on the page is the caller's job (same "decorate, don't own
  # layout" contract as `section_card`), so no outer `<Container>` is
  # returned here. NO-GO -> `{element:[],child_layout:'',patch:{}}`
  # (graceful: nothing to merge, nothing to lay out, never a broken/
  # half-decorated card).
  def self.gradient_card(id:, kpi_element:, gradient: DEFAULT_THEME[:card_gradient], page_cols: 24, surfaces: SURFACES)
    return { element: [], child_layout: '', patch: {} } unless surfaces[:gradient_card]

    bg_url = svg_data_uri(compose_card_svg(gradient))
    # Live API contract update (2026-08-08) -- see gradient_header's identical note above.
    container_el = { 'id' => id, 'kind' => 'container', 'style' => { 'borderRadius' => 'round' },
                      'backgroundImage' => { 'source' => { 'kind' => 'url', 'url' => bg_url }, 'style' => { 'fit' => 'cover' } } }
    child_layout = "<Element elementId=\"#{kpi_element['id']}\" gridColumn=\"1 / #{page_cols + 1}\" gridRow=\"1 / 7\"/>"
    patch = { 'value' => { 'color' => '#FFFFFF' }, 'name' => { 'color' => '#FFFFFF' },
              'style' => { 'backgroundColor' => 'transparent', 'padding' => 'none' } }
    { element: [container_el], child_layout: child_layout, patch: patch }
  end

  # Composite in-card sparkline: a separate, borderless mini `line-chart`
  # element meant to sit BELOW a kpi-chart inside the same `gradient_card`
  # container -- NOT a date column bound inside the kpi-chart itself (that
  # in-kpi shape is NO-GO; this standalone line-chart is the live-verified
  # GO pattern). Two columns: a period dimension (`period_ref`'s formula,
  # formatted `kind:"datetime"`/`period_format`) and a value (`value_formula`'s
  # formula). Both axes hide their labels/marks so no chrome competes with
  # the kpi above it; the y-axis scale is `zero:false` (a small trend doesn't
  # get flattened against a forced-zero baseline) with `hideZeroLine:true`;
  # `name`/`legend` are hidden (no title, no legend on a sparkline); the line
  # uses a smooth `monotone` interpolation; the background is transparent so
  # the chart blends into the gradient card above/around it. NO-GO ->
  # `{'opt_in'=>true,'id'=>id}` (never a faked/broken chart shape).
  def self.sparkline(id:, source_element_id:, period_ref:, value_formula:, period_format: '%b %Y', surfaces: SURFACES)
    return { 'opt_in' => true, 'id' => id } unless surfaces[:sparkline]

    period_col_id = "#{id}-period"
    value_col_id = "#{id}-value"
    {
      'id' => id,
      'kind' => 'line-chart',
      'source' => { 'kind' => 'table', 'elementId' => source_element_id },
      'columns' => [
        { 'id' => period_col_id, 'formula' => period_ref, 'name' => 'Period',
          'format' => { 'kind' => 'datetime', 'formatString' => period_format } },
        { 'id' => value_col_id, 'formula' => value_formula, 'name' => 'Value' }
      ],
      'xAxis' => { 'columnId' => period_col_id, 'format' => { 'marks' => 'none', 'labels' => 'hidden' } },
      'yAxis' => { 'columnIds' => [value_col_id],
                    'format' => { 'labels' => 'hidden', 'marks' => 'none',
                                  'scale' => { 'type' => 'linear', 'zero' => false, 'hideZeroLine' => true } } },
      'name' => { 'visibility' => 'hidden' },
      'legend' => { 'visibility' => 'hidden' },
      'lineAreaStyle' => { 'interpolation' => 'monotone' },
      'style' => { 'backgroundColor' => 'transparent', 'padding' => 'none' }
    }
  end
end
