# frozen_string_literal: true
#
# theme_derive.rb — derive Sigma themeOverrides from a parse-twb-layout dump.
#
# ONE shared pure function so the orchestrated mechanical path
# (build-charts-from-signals → mechanical-specs build_wb_spec) and the
# standalone path (build-workbook-spec.rb) cannot diverge — the v5.0 field
# finding was that only the standalone path emitted a theme, so every
# orchestrated run shipped themeless even when the source declared fonts,
# a fixed canvas width, and a brand palette.
#
# Inputs per dashboard (parse-twb-layout): 'style_rules' ({'workbook'=>
# {element=>{attr=>value}}, 'dashboard'=>{...}}), 'canvas_px' ({w,h,
# sizing_mode}), 'zone_tree' (container fill tints), 'brand_palette'
# (frequency-ranked encoded colors, categorical palettes only).
#
# Sigma surface (styling.md, live-verified 2026-06-26): themeOverrides
# {fonts.{textFont,dataFont}, pageWidth+maxPageWidth, colorOverrides.
# backgroundCanvas, categoricalScheme}. sequentialScheme/divergingScheme take
# NAMED schemes only — Tableau custom ramps can never ride the theme.
#
# Contract: returns {} when the source declares nothing (apply! then emits no
# document.settings.theme — an unstyled workbook gets pure Sigma defaults,
# byte-identical to the pre-theme output).
require_relative 'series_colors'

module ThemeDerive
  module_function

  # Tableau's bundled families aren't web-available — emitting them makes
  # Sigma fall back to an uncontrolled substitute. Treat as "no declaration".
  TABLEAU_ONLY_FONT = /\ATableau($|\s)/i.freeze
  SCHEME_CAP = 20 # Tableau 10/20 hues; beyond that map-to noise, not a palette

  def derive(layout)
    dashes = layout.is_a?(Array) ? layout : []
    return {} if dashes.empty?
    d = dashes.first # first-in-scope dashboard wins every slot (deterministic)
    theme = {}
    fonts = derive_fonts(d['style_rules'] || {})
    theme['fonts'] = fonts unless fonts.empty?
    pw = derive_page_width(d['canvas_px'])
    theme.merge!(pw) if pw
    canvas = derive_canvas(d)
    theme['backgroundCanvas'] = canvas if canvas
    scheme = derive_scheme(d)
    theme['categoricalScheme'] = scheme if scheme && scheme.size >= 2
    theme
  end

  # F1-F4: font-family slots. dataFont = table/chart data; textFont = titles
  # and text. Sigma's titleFont has no family field, so a dash-title family
  # can only land in textFont (by design, not a loss).
  def derive_fonts(style_rules)
    wb = style_rules['workbook'] || {}
    db = style_rules['dashboard'] || {}
    fam = lambda do |scope, element|
      v = scope.dig(element, 'font-family').to_s.strip.gsub(/\A['"]|['"]\z/, '')
      return nil if v.empty? || v =~ TABLEAU_ONLY_FONT
      v
    end
    base = fam.call(wb, 'all')
    data = fam.call(wb, 'worksheet') || base
    text = fam.call(db, 'dash-title') || fam.call(db, 'dash-text') ||
           fam.call(wb, 'dash-title') || fam.call(wb, 'title') ||
           fam.call(wb, 'dash-text') || base
    out = {}
    out['textFont'] = text if text
    out['dataFont'] = data if data
    out
  end

  # P1: a fixed-width dashboard is an authored canvas — carry it. Range /
  # automatic sizing and phone-narrow (<600, also Sigma's minimum) are omitted.
  def derive_page_width(canvas_px)
    return nil unless canvas_px.is_a?(Hash)
    w = canvas_px['w'].to_i
    fixed = canvas_px['sizing_mode'] == 'fixed'
    return nil unless fixed && w >= 600
    { 'pageWidth' => 'custom', 'maxPageWidth' => w }
  end

  # C1 (outermost zone fill) then C2 (dashboard Format▸Shading, stored as a
  # dashboard-scope style-rule element='table' background-color — the
  # "transparent sheets on a shaded dashboard" idiom). Declared #ffffff is
  # emitted (a declaration beats guessing the default); transparent = absent.
  def derive_canvas(d)
    roots = d['zone_tree'] || []
    c = roots.first && roots.first['fill_color']
    c = nil if c.to_s.downcase == '#00000000'
    c ||= begin
      v = (d['style_rules'] || {}).dig('dashboard', 'table', 'background-color')
      v.to_s.downcase == '#00000000' ? nil : v
    end
    return nil unless c.is_a?(String) && c =~ /\A#[0-9a-fA-F]{6}/
    c[0, 7].downcase
  end

  # S0 (PR-12): EXPLICIT member→color assignments beat frequency ranking —
  # themeOverrides.categoricalScheme applies POSITIONALLY in category-sort
  # order, so when the .twb binds members to colors the scheme must be ordered
  # ascending by member (the only slice-color path for pie/donut, and the fix
  # for the series-inversion class). Conservative: only when every assigned
  # zone colors by the same field (else nil → S1 frequency order unchanged).
  # Then S1/S2 (brand palette from color encodings + categorical palettes,
  # frequency-ranked — parse-twb-layout) then S3 (container-tint fallback for
  # the region-card idiom), capped at SCHEME_CAP.
  def derive_scheme(d)
    explicit = SeriesColors.explicit_scheme_for_dashboard(d, SCHEME_CAP)
    return explicit if explicit
    brand = d['brand_palette']
    return brand.first(SCHEME_CAP) if brand.is_a?(Array) && brand.size >= 2
    palette = []
    seen = {}
    walk = lambda do |nodes|
      (nodes || []).each do |n|
        fc = n['fill_color']
        if n['kind'] == 'container' && fc.is_a?(String) && fc =~ /\A#[0-9a-fA-F]{8}\z/
          base = fc[0, 7].downcase # strip alpha → the saturated mark color
          unless seen[base]
            seen[base] = true
            palette << base
          end
        end
        walk.call(n['children'])
      end
    end
    walk.call(d['zone_tree'])
    palette.first(SCHEME_CAP)
  end

  # Shared emission: mutate a workbook-spec hash in place. `theme` is
  # derive()'s output. No-op on {} (the never-worse contract).
  def apply!(spec, theme)
    return spec if theme.nil? || theme.empty?
    overrides = {}
    if theme['fonts'] && !theme['fonts'].empty?
      overrides['fonts'] = theme['fonts']
    end
    if theme['pageWidth']
      overrides['pageWidth'] = theme['pageWidth']
      overrides['maxPageWidth'] = theme['maxPageWidth'] if theme['maxPageWidth']
    end
    overrides['colorOverrides'] = [{ 'name' => 'backgroundCanvas', 'color' => theme['backgroundCanvas'] }] if theme['backgroundCanvas']
    overrides['categoricalScheme'] = theme['categoricalScheme'] if theme['categoricalScheme']
    unless overrides.empty?
      # Live since 2026-08: themeName/themeOverrides moved to
      # document.settings.theme.{name,overrides} (see shared/lib/code_rep.rb
      # DOC_KEYS). A flat top-level themeName/themeOverrides is invalid on
      # write and gets silently dropped by the code-rep wrapper.
      spec['settings'] = (spec['settings'] || {}).merge('theme' => { 'name' => 'Light', 'overrides' => overrides })
    end
    spec
  end
end
