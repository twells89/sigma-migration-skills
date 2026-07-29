# frozen_string_literal: true
# test_styling.rb — run directly: ruby shared/lib/test_styling.rb
require 'json'
require 'base64'
require_relative 'styling'
require_relative 'composition'
$failures = 0
def check(desc); ok = yield; puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}"); $failures += 1 unless ok; end

# Deep-sort hashes/arrays so twin/golden comparison is key-order-independent.
def sort_deep(o)
  case o
  when Hash then o.keys.sort.each_with_object({}) { |k, h| h[k] = sort_deep(o[k]) }
  when Array then o.map { |e| sort_deep(e) }
  else o
  end
end

check('theme() (no args) returns the default palette') do
  Styling.theme == Styling::DEFAULT_THEME
end
check('theme(accent: nil) returns the default palette') do
  Styling.theme(accent: nil) == Styling::DEFAULT_THEME
end
check("theme(accent: '') returns the default palette") do
  Styling.theme(accent: '') == Styling::DEFAULT_THEME
end
check('DEFAULT_THEME categorical slot 0 + accent are the base blue') do
  Styling::DEFAULT_THEME[:categorical].first == '#2563EB' && Styling::DEFAULT_THEME[:accent] == '#2563EB'
end
check("theme(accent: '#FF6600') tints categorical slot 0") do
  Styling.theme(accent: '#FF6600')[:categorical].first == '#FF6600'
end
check("theme(accent: '#FF6600') tints :accent too") do
  Styling.theme(accent: '#FF6600')[:accent] == '#FF6600'
end
check('accent override leaves categorical slots 1..7 unchanged') do
  Styling.theme(accent: '#FF6600')[:categorical][1..-1] == Styling::DEFAULT_THEME[:categorical][1..-1]
end
check('accent override does not mutate DEFAULT_THEME (deep copy)') do
  Styling.theme(accent: '#FF6600')
  Styling::DEFAULT_THEME[:categorical].first == '#2563EB' && Styling::DEFAULT_THEME[:accent] == '#2563EB'
end
check('card shape: borderRadius/borderColor/borderWidth, no cornerRadius, no padding') do
  card = Styling::DEFAULT_THEME[:card]
  card['borderRadius'] == 'round' && card['borderColor'] == '#E2E8F0' && card['borderWidth'] == 1 &&
    !card.key?('cornerRadius') && !card.key?('padding')
end
check('header shape: backgroundColor + borderRadius only') do
  header = Styling::DEFAULT_THEME[:header]
  header == { 'backgroundColor' => '#0F172A', 'borderRadius' => 'round' }
end

# Composition.bands — role -> [r0, r1) band descriptors (Step 1 example).
check('Composition.bands: kpi + hero (exec) matches the brief example') do
  out = Composition.bands([{ id: 'k', role: :kpi }, { id: 'h', role: :hero }], :exec)
  out == [
    { role: :kpi, ids: ['k'], r0: 1, r1: 7 },
    { role: :hero, ids: ['h'], r0: 7, r1: 19 }
  ]
end
check('Composition.bands: master_detail with control row') do
  out = Composition.bands([
    { id: 'ctl', role: :control },
    { id: 'master-chart', role: :master },
    { id: 'detail-tbl', role: :detail }
  ], :master_detail)
  out == [
    { role: :control, ids: ['ctl'], r0: 1, r1: 3 },
    { role: :master_detail, ids: %w[master-chart detail-tbl], r0: 3, r1: 17 }
  ]
end
check('Composition.bands: unknown pattern raises') do
  begin; Composition.bands([{ id: 'k', role: :kpi }], :nope); false
  rescue ArgumentError; true; end
end
check('Composition.bands: role not used by pattern raises') do
  begin; Composition.bands([{ id: 'm1', role: :master }], :exec); false
  rescue ArgumentError; true; end
end
check('Composition.bands: page_cols defaults to 24') do
  out = Composition.bands([{ id: 'h', role: :hero }], :exec)
  out == [{ role: :hero, ids: ['h'], r0: 1, r1: 13 }]
end

# --- Task 3: chart_color, kpi_accent, format_for, header, section_card ---

check('SURFACES: all 10 surfaces (Task-1 six + WS4 gradient_header/motif/gradient_card/sparkline) are GO') do
  expected = %i[categorical_scheme chart_color_by container_style format_string kpi_name_color typography
                gradient_header motif gradient_card sparkline]
  Styling::SURFACES.keys.sort == expected.sort && Styling::SURFACES.values.all? { |v| v == true }
end

check('chart_color(theme): single-series color:{by:"single",value:} (categorical slot 0)') do
  Styling.chart_color(Styling::DEFAULT_THEME) == { 'color' => { 'by' => 'single', 'value' => '#2563EB' } }
end
check('chart_color(theme, categorical: true): workbook-level categoricalScheme patch') do
  Styling.chart_color(Styling::DEFAULT_THEME, categorical: true) ==
    { 'themeOverrides' => { 'categoricalScheme' => Styling::DEFAULT_THEME[:categorical] } }
end
check('chart_color: NO-GO chart_color_by -> {}') do
  Styling.chart_color(Styling::DEFAULT_THEME, surfaces: Styling::SURFACES.merge(chart_color_by: false)) == {}
end
check('chart_color: NO-GO categorical_scheme -> {}') do
  Styling.chart_color(Styling::DEFAULT_THEME, categorical: true,
                       surfaces: Styling::SURFACES.merge(categorical_scheme: false)) == {}
end

check('kpi_accent(theme) merges into a name object') do
  name = { 'text' => 'Revenue' }.merge(Styling.kpi_accent(Styling::DEFAULT_THEME))
  name == { 'text' => 'Revenue', 'color' => '#2563EB' }
end
check('kpi_accent: NO-GO kpi_name_color -> {}') do
  Styling.kpi_accent(Styling::DEFAULT_THEME, surfaces: Styling::SURFACES.merge(kpi_name_color: false)) == {}
end

check('format_for(:currency/:integer/:percent/:decimal) — d3-format, not Excel') do
  Styling.format_for(:currency) == { 'kind' => 'number', 'formatString' => '$,.0f' } &&
    Styling.format_for(:integer) == { 'kind' => 'number', 'formatString' => ',.0f' } &&
    Styling.format_for(:percent) == { 'kind' => 'number', 'formatString' => '.1%' } &&
    Styling.format_for(:decimal) == { 'kind' => 'number', 'formatString' => ',.2f' }
end
check('format_for: unknown semantic raises') do
  begin
    Styling.format_for(:bogus)
    false
  rescue ArgumentError
    true
  end
end
check('format_for: NO-GO format_string -> {}') do
  Styling.format_for(:currency, surfaces: Styling::SURFACES.merge(format_string: false)) == {}
end

check('header: container-style GO emits a container + title text element and a rows-1/3 GridContainer') do
  h = Styling.header(id: 'hdr', title: 'Dashboard', theme: Styling::DEFAULT_THEME)
  h[:element].length == 2 &&
    h[:element][0] == { 'id' => 'hdr-bg', 'kind' => 'container', 'style' => Styling::DEFAULT_THEME[:header] } &&
    h[:element][1]['kind'] == 'text' &&
    h[:layout].include?('<GridContainer') && h[:layout].include?('gridRow="1 / 3"') &&
    h[:layout].include?('elementId="hdr-title"')
end
check('header: NO-GO container_style emits a bare text element, no container') do
  h = Styling.header(id: 'hdr', title: 'Dashboard', theme: Styling::DEFAULT_THEME,
                      surfaces: Styling::SURFACES.merge(container_style: false))
  h[:element].length == 1 && h[:element][0]['kind'] == 'text' && !h[:layout].include?('GridContainer')
end

check('section_card: container-style GO wraps band ids in a themed card GridContainer') do
  band = { role: :kpi, ids: %w[k1 k2 k3], r0: 7, r1: 13 }
  sc = Styling.section_card(id: 'card-1', band: band, theme: Styling::DEFAULT_THEME)
  sc[:element] == { 'id' => 'card-1', 'kind' => 'container', 'style' => Styling::DEFAULT_THEME[:card] } &&
    sc[:wrap].include?('<GridContainer elementId="card-1"') && sc[:wrap].include?('gridRow="7 / 13"') &&
    sc[:wrap].scan('<LayoutElement').length == 3
end
check('section_card: NO-GO container_style returns bare band render, no container element') do
  band = { role: :kpi, ids: %w[k1 k2], r0: 1, r1: 7 }
  sc = Styling.section_card(id: 'card-1', band: band, theme: Styling::DEFAULT_THEME,
                             surfaces: Styling::SURFACES.merge(container_style: false))
  sc[:element].nil? && !sc[:wrap].include?('GridContainer') && sc[:wrap].scan('<LayoutElement').length == 2
end

# --- Task 2: Styling::MOTIFS + Styling.gradient_header ---

check('DEFAULT_THEME[:header_gradient] is a neutral 2-3 stop hex gradient, not red') do
  hg = Styling::DEFAULT_THEME[:header_gradient]
  hg.is_a?(Array) && [2, 3].include?(hg.length) && hg.all? { |h| h =~ /\A#[0-9A-Fa-f]{6}\z/ } &&
    !hg.include?('#E4002B') && !hg.include?('#FF0000')
end

check('MOTIFS: exactly the 6 menu keys') do
  Styling::MOTIFS.keys.sort == %i[dots glow grid none rings waves].sort
end

check('MOTIFS: glow/rings/grid/waves/dots each return a non-empty deterministic SVG fragment') do
  %i[glow rings grid waves dots].all? do |k|
    frag = Styling::MOTIFS[k].call
    frag.is_a?(String) && !frag.empty? && frag == Styling::MOTIFS[k].call
  end
end
check('MOTIFS: :none returns an empty string') do
  Styling::MOTIFS[:none].call == ''
end

check('gradient_header (default :glow, :right): container has data-URI SVG backgroundImage + title element + GridContainer layout') do
  h = Styling.gradient_header(id: 'ghdr', title: 'Command Center')
  bg = h[:element][0]
  bg['kind'] == 'container' && bg['style'] == { 'borderRadius' => 'round' } &&
    bg['backgroundImage']['url'].start_with?('data:image/svg+xml;base64,') &&
    bg['backgroundImage']['style'] == { 'fit' => 'cover' } &&
    h[:element].any? { |e| e['kind'] == 'text' && e['id'] == 'ghdr-title' } &&
    h[:layout].include?('<GridContainer') && h[:layout].include?('elementId="ghdr-title"')
end

check('gradient_header: decoded SVG carries the linearGradient + the requested motif group') do
  h = Styling.gradient_header(id: 'ghdr', title: 'X', motif: :rings)
  svg = Base64.decode64(h[:element][0]['backgroundImage']['url'].sub('data:image/svg+xml;base64,', ''))
  svg.include?('linearGradient') && svg.include?('<circle r="40"/>') && svg.include?('<g transform="translate(1440,86)">')
end

check('gradient_header motif :none: no motif <g> group in the decoded SVG') do
  h = Styling.gradient_header(id: 'ghdr', title: 'X', motif: :none)
  svg = Base64.decode64(h[:element][0]['backgroundImage']['url'].sub('data:image/svg+xml;base64,', ''))
  !svg.include?('<g transform=')
end

check('gradient_header motif_side: :left translates the motif group to x=160') do
  h = Styling.gradient_header(id: 'ghdr', title: 'X', motif: :rings, motif_side: :left)
  svg = Base64.decode64(h[:element][0]['backgroundImage']['url'].sub('data:image/svg+xml;base64,', ''))
  svg.include?('translate(160,86)')
end

check('gradient_header: logo_url present -> logo element + logo/title split layout (logo col 1/3)') do
  h = Styling.gradient_header(id: 'ghdr', title: 'X', logo_url: 'https://example.com/logo.png')
  h[:element].length == 3 &&
    h[:element][1] == { 'id' => 'ghdr-logo', 'kind' => 'image', 'url' => 'https://example.com/logo.png',
                         'style' => { 'fit' => 'contain' } } &&
    h[:layout].include?('elementId="ghdr-logo" gridColumn="1 / 3"') &&
    h[:layout].include?('elementId="ghdr-title" gridColumn="3 / 25"')
end

check('gradient_header: no logo_url -> title spans full width, no logo element') do
  h = Styling.gradient_header(id: 'ghdr', title: 'X')
  h[:element].none? { |e| e['kind'] == 'image' } &&
    h[:layout].include?('elementId="ghdr-title" gridColumn="1 / 25"')
end

check('gradient_header: subtitle -> separate subtitle text element + split layout rows') do
  h = Styling.gradient_header(id: 'ghdr', title: 'X', subtitle: 'Sub')
  h[:element].length == 3 &&
    h[:element][2]['kind'] == 'text' && h[:element][2]['id'] == 'ghdr-subtitle' &&
    h[:element][2]['body'].include?('Sub') &&
    h[:layout].include?('elementId="ghdr-title" gridColumn="1 / 25" gridRow="1 / 3"') &&
    h[:layout].include?('elementId="ghdr-subtitle" gridColumn="1 / 25" gridRow="3 / 4"')
end

check('gradient_header: bring-your-own http(s) URL used verbatim, SVG compose skipped') do
  h = Styling.gradient_header(id: 'ghdr', title: 'X', motif: 'https://example.com/art.png')
  h[:element][0]['backgroundImage']['url'] == 'https://example.com/art.png'
end
check('gradient_header: bring-your-own data: URL used verbatim') do
  uri = 'data:image/png;base64,AAAA'
  h = Styling.gradient_header(id: 'ghdr', title: 'X', motif: uri)
  h[:element][0]['backgroundImage']['url'] == uri
end

check('gradient_header: gradient with != 2-3 stops raises ArgumentError') do
  begin
    Styling.gradient_header(id: 'ghdr', title: 'X', gradient: ['#111111'])
    false
  rescue ArgumentError
    true
  end
end

check('gradient_header: NO-GO gradient_header surface falls back to flat Styling.header output') do
  surfaces = Styling::SURFACES.merge(gradient_header: false)
  h = Styling.gradient_header(id: 'ghdr', title: 'X', surfaces: surfaces)
  expected = Styling.header(id: 'ghdr', title: 'X', theme: Styling::DEFAULT_THEME, surfaces: surfaces)
  h == expected
end

check('gradient_header: NO-GO motif surface + menu-key motif falls back to the plain gradient (:none)') do
  surfaces = Styling::SURFACES.merge(motif: false)
  h = Styling.gradient_header(id: 'ghdr', title: 'X', motif: :rings, surfaces: surfaces)
  bg = h[:element][0]['backgroundImage']['url']
  svg = Base64.decode64(bg.sub('data:image/svg+xml;base64,', ''))
  bg.start_with?('data:image/svg+xml;base64,') && svg.include?('linearGradient') && !svg.include?('<g transform=')
end

check('gradient_header: NO-GO motif surface does NOT suppress a bring-your-own URL (honored verbatim)') do
  surfaces = Styling::SURFACES.merge(motif: false)
  h = Styling.gradient_header(id: 'ghdr', title: 'X', motif: 'https://example.com/art.png', surfaces: surfaces)
  h[:element][0]['backgroundImage']['url'] == 'https://example.com/art.png'
end

check('gradient_header motif_side: :center translates the motif group to x=800 and produces a valid header') do
  h = Styling.gradient_header(id: 'ghdr', title: 'X', motif: :rings, motif_side: :center)
  svg = Base64.decode64(h[:element][0]['backgroundImage']['url'].sub('data:image/svg+xml;base64,', ''))
  svg.include?('translate(800,86)') &&
    h[:element].any? { |e| e['kind'] == 'text' && e['id'] == 'ghdr-title' } &&
    h[:layout].include?('<GridContainer') && h[:layout].include?('elementId="ghdr-title"')
end

check('gradient_header: unrecognized motif symbol raises ArgumentError') do
  begin
    Styling.gradient_header(id: 'ghdr', title: 'X', motif: :sparkles)
    false
  rescue ArgumentError
    true
  end
end

# --- Task 3: Styling.gradient_card + Styling.sparkline ---

GC_KPI_EL = { 'id' => 'kpi-rev', 'kind' => 'kpi-chart', 'name' => { 'text' => 'Revenue' },
              'value' => { 'columnId' => 'rev-cur' } }.freeze

check('gradient_card: GO returns a gradient container + child_layout positioning the kpi + a white-text patch') do
  gc = Styling.gradient_card(id: 'card-1', kpi_element: GC_KPI_EL, gradient: %w[#0F172A #2563EB])
  gc[:element].length == 1 &&
    gc[:element][0]['id'] == 'card-1' && gc[:element][0]['kind'] == 'container' &&
    gc[:element][0]['style'] == { 'borderRadius' => 'round' } &&
    gc[:element][0]['backgroundImage']['url'].start_with?('data:image/svg+xml;base64,') &&
    gc[:element][0]['backgroundImage']['style'] == { 'fit' => 'cover' } &&
    gc[:child_layout] == '<LayoutElement elementId="kpi-rev" gridColumn="1 / 25" gridRow="1 / 7"/>' &&
    gc[:patch] == { 'value' => { 'color' => '#FFFFFF' }, 'name' => { 'color' => '#FFFFFF' } }
end

check('gradient_card: decoded SVG carries the linearGradient stops (motif: :none -- no motif group)') do
  gc = Styling.gradient_card(id: 'card-1', kpi_element: GC_KPI_EL, gradient: %w[#0F172A #2563EB])
  svg = Base64.decode64(gc[:element][0]['backgroundImage']['url'].sub('data:image/svg+xml;base64,', ''))
  svg.include?('linearGradient') && !svg.include?('<g transform=')
end

check('gradient_card: does NOT mutate the passed kpi_element hash') do
  kpi_el = { 'id' => 'kpi-rev2', 'kind' => 'kpi-chart', 'name' => { 'text' => 'Revenue' },
             'value' => { 'columnId' => 'rev-cur', 'fontSize' => 32 } }
  snapshot = Marshal.load(Marshal.dump(kpi_el))
  Styling.gradient_card(id: 'card-2', kpi_element: kpi_el, gradient: %w[#0F172A #2563EB])
  kpi_el == snapshot
end

check('gradient_card: respects a custom page_cols in child_layout gridColumn span') do
  gc = Styling.gradient_card(id: 'card-1', kpi_element: GC_KPI_EL, gradient: %w[#0F172A #2563EB], page_cols: 12)
  gc[:child_layout] == '<LayoutElement elementId="kpi-rev" gridColumn="1 / 13" gridRow="1 / 7"/>'
end

check('gradient_card: NO-GO gradient_card surface -> empty element/child_layout/patch, no crash') do
  surfaces = Styling::SURFACES.merge(gradient_card: false)
  gc = Styling.gradient_card(id: 'card-1', kpi_element: GC_KPI_EL, gradient: %w[#0F172A #2563EB], surfaces: surfaces)
  gc == { element: [], child_layout: '', patch: {} }
end

check('sparkline: GO returns a borderless line-chart with hidden axes/legend/name + transparent bg + datetime format') do
  sp = Styling.sparkline(id: 'spark-rev', source_element_id: 'tbl', period_ref: '[Table/Month]',
                          value_formula: 'Sum([Table/Revenue])')
  sp['id'] == 'spark-rev' && sp['kind'] == 'line-chart' &&
    sp['source'] == { 'kind' => 'table', 'elementId' => 'tbl' } &&
    sp['columns'].length == 2 &&
    sp['columns'][0]['formula'] == '[Table/Month]' &&
    sp['columns'][0]['format'] == { 'kind' => 'datetime', 'formatString' => '%b %Y' } &&
    sp['columns'][1]['formula'] == 'Sum([Table/Revenue])' &&
    sp['xAxis']['format'] == { 'marks' => 'none', 'labels' => 'hidden' } &&
    sp['yAxis']['format']['labels'] == 'hidden' && sp['yAxis']['format']['marks'] == 'none' &&
    sp['yAxis']['format']['scale'] == { 'type' => 'linear', 'zero' => false, 'hideZeroLine' => true } &&
    sp['name'] == { 'visibility' => 'hidden' } && sp['legend'] == { 'visibility' => 'hidden' } &&
    sp['lineAreaStyle'] == { 'interpolation' => 'monotone' } &&
    sp['style'] == { 'backgroundColor' => 'transparent', 'padding' => 'none' }
end

check('sparkline: custom period_format flows into the period column format') do
  sp = Styling.sparkline(id: 'spark-rev', source_element_id: 'tbl', period_ref: '[Table/Month]',
                          value_formula: 'Sum([Table/Revenue])', period_format: '%Y-%m')
  sp['columns'][0]['format'] == { 'kind' => 'datetime', 'formatString' => '%Y-%m' }
end

check('sparkline: NO-GO sparkline surface -> opt_in marker, never a broken chart shape') do
  surfaces = Styling::SURFACES.merge(sparkline: false)
  sp = Styling.sparkline(id: 'spark-rev', source_element_id: 'tbl', period_ref: '[Table/Month]',
                          value_formula: 'Sum([Table/Revenue])', surfaces: surfaces)
  sp == { 'opt_in' => true, 'id' => 'spark-rev' }
end

golden = JSON.parse(File.read(File.join(__dir__, 'testdata', 'styling_golden.json')))
check('helpers match styling_golden.json (sorted-key identical)') do
  theme = Styling::DEFAULT_THEME
  band = { role: :kpi, ids: %w[k1 k2 k3], r0: 7, r1: 13 }
  actual = {
    'chart_color_single' => Styling.chart_color(theme),
    'chart_color_categorical' => Styling.chart_color(theme, categorical: true),
    'kpi_accent' => Styling.kpi_accent(theme),
    'format_for_currency' => Styling.format_for(:currency),
    'format_for_integer' => Styling.format_for(:integer),
    'format_for_percent' => Styling.format_for(:percent),
    'format_for_decimal' => Styling.format_for(:decimal),
    'header' => Styling.header(id: 'hdr', title: 'Dashboard', theme: theme),
    'section_card' => Styling.section_card(id: 'card-1', band: band, theme: theme),
    'gradient_header_glow' => Styling.gradient_header(id: 'ghdr', title: 'Command Center', subtitle: 'Live metrics',
                                                        logo_url: 'https://example.com/logo.png'),
    'gradient_header_rings_left' => Styling.gradient_header(id: 'ghdr2', title: 'Ops', motif: :rings, motif_side: :left),
    'gradient_header_none' => Styling.gradient_header(id: 'ghdr3', title: 'Plain', motif: :none),
    'gradient_header_byo' => Styling.gradient_header(id: 'ghdr4', title: 'Custom', motif: 'https://example.com/art.png'),
    'gradient_card' => Styling.gradient_card(id: 'card-1', kpi_element: GC_KPI_EL, gradient: %w[#0F172A #2563EB]),
    'sparkline' => Styling.sparkline(id: 'spark-rev', source_element_id: 'tbl', period_ref: '[Table/Month]',
                                      value_formula: 'Sum([Table/Revenue])')
  }
  JSON.generate(sort_deep(actual)) == JSON.generate(sort_deep(golden))
end

exit($failures.zero? ? 0 : 1)
