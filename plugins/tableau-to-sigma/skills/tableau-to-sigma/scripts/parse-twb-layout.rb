#!/usr/bin/env ruby
# Parse the dashboard layout out of a .twb XML file.
#
# The dashboard image PNG only shows pixels; the .twb XML carries the actual
# zone tree with chart positions, captions, underlying view refs, AND the chart
# kind (bar / line / pie / map / etc.) via the worksheet's <mark> element.
# Reading this BEFORE building the workbook spec prevents the common Phase 5
# miss: dropping the dashboard title, filter shelf, or any pie/donut/map tile
# whose chart-kind isn't visible in the view CSV.
#
# Usage:
#   ruby scripts/parse-twb-layout.rb /tmp/<name>/workbook-content.twb \
#                                    /tmp/<name>/dashboard-layout.json
#
# Output (one JSON object per dashboard):
#   {
#     "dashboard": "Orders Overview",
#     "zones": [
#       { "id":"3", "kind":"chart", "caption":"Revenue by Region",
#         "x_pct":0, "y_pct":29.7, "w_pct":35.5, "h_pct":31.5,
#         "view_ref":"[federated.xxx].[…]",
#         "chart_kind":"bar", "mark_class":"Bar",
#         "geo_role":null },
#       { "id":"26", "kind":"chart", "caption":"Order Channel vs Ship Method",
#         "chart_kind":"pie", "mark_class":"Pie", ... },
#       { "id":"57", "kind":"text", "caption":null, ... },
#       { "id":"71", "kind":"filter", "caption":"Revenue by Region", ... }
#     ]
#   }
#
# `chart_kind` is the Sigma-relevant chart type derived from the worksheet's
# <mark class="..."> element plus a check for geographic encoding roles. Map to
# Sigma kinds with the table in refs/workbook-layout.md.

require 'json'
# Nokogiri-backed REXML drop-in — REXML is O(n^2) on large .twb files; twb_xml.rb
# parses a 5 MB / 95-worksheet workbook in well under a second. See lib/twb_xml.rb.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'
require 'format_map' # PR-12: the ONE Tableau→Sigma format translator (lib/format_map.rb)
require 'integer_dim' # PR-18: integer-coded dimension detection (shelf role + datatype)

# ---- Per-dashboard scoping ------------------------------------------------
# `--dashboard "<name>"` (repeatable) and `--page <id>` let a LARGE workbook
# (14+ dashboards) be migrated ONE tab at a time: only the matching
# dashboard(s) are emitted in the layout JSON, and the *-meta.json worksheets /
# shared_filters are scoped to those used by the selected dashboard(s). No
# filter ⇒ current behavior (all dashboards, full meta). The dashboard name
# match is case-insensitive and accepts either an exact match or a unique
# substring (so `--dashboard "Regional"` resolves a long Tableau caption).
# `--page <id>` filters on the dashboard's zone-root id (rarely needed; name is
# the ergonomic handle) and is treated as an additional accepted token.
DASHBOARD_FILTERS = []
PAGE_FILTERS = []
positional = []
i = 0
while i < ARGV.length
  a = ARGV[i]
  case a
  when '--dashboard'
    DASHBOARD_FILTERS << ARGV[i + 1].to_s
    i += 2
  when '--page'
    PAGE_FILTERS << ARGV[i + 1].to_s
    i += 2
  else
    positional << a
    i += 1
  end
end

INP = positional[0] || abort('usage: parse-twb-layout.rb <workbook-content.twb> <out.json> [--dashboard "<name>"] [--page <id>]')
OUT = positional[1] || abort('usage: parse-twb-layout.rb <workbook-content.twb> <out.json> [--dashboard "<name>"] [--page <id>]')

# True when no scoping requested → keep every dashboard (current behavior).
def dashboard_scoping?
  !DASHBOARD_FILTERS.empty? || !PAGE_FILTERS.empty?
end

# Decide whether a dashboard (by name + zone-root id) is in scope. Name match is
# case-insensitive exact OR unique substring; page match is exact on the id.
def dashboard_in_scope?(name, page_id)
  return true unless dashboard_scoping?
  n = name.to_s.downcase
  name_hit = DASHBOARD_FILTERS.any? do |f|
    fl = f.downcase
    n == fl || (!fl.empty? && n.include?(fl))
  end
  page_hit = PAGE_FILTERS.any? { |p| !p.empty? && p == page_id.to_s }
  name_hit || page_hit
end

TWB_TEXT = begin
  raw = File.read(INP, encoding: 'UTF-8')
  # Defensive FCP normalization for pre-existing workdirs whose .twb was
  # written before discovery normalized at download time (idempotent; see
  # lib/fcp_normalize — literal-name XPaths are otherwise blind to native
  # rounded corners and every other forward-compatibility feature).
  require_relative 'lib/fcp_normalize'
  FcpNormalize.needed?(raw) ? FcpNormalize.normalize(raw) : raw
end
xml = TwbXml.parse(TWB_TEXT)

# ---- Brand palette (Phase-1 D1, general) ----------------------------------
# The workbook's real categorical/brand palette lives in the color ENCODING
# (<encoding attr='color'> <map to='#rrggbb'>…) and any custom <color-palette>
# — NOT in container fills. derive_theme previously read only container tints,
# so a dashboard whose design is a color scheme (not tinted cards) degenerated
# to picking white card backgrounds. We surface the encoded colors here,
# frequency-ranked, with neutrals dropped (near-white/black card & text fills,
# and low-chroma greys), so downstream theming can reproduce the source's own
# palette. Neutral test mirrors the prototype validated across the benchmark
# set (ER reds / Quota blue-teal / History blue+orange / course-workbook subject dots).
def color_neutral?(hex)
  h = hex.delete('#')
  return true unless h.length == 6
  r, g, b = h[0, 2].to_i(16), h[2, 2].to_i(16), h[4, 2].to_i(16)
  mx = [r, g, b].max
  mn = [r, g, b].min
  # Low chroma (grey), OR near-white (ALL channels high) OR near-black (ALL
  # channels low). Test mn/mx not the opposite bound, so a vivid colour with a
  # single near-max channel (orange #f06719, red #ff0000) is NOT dropped.
  (mx - mn) < 24 || mn > 235 || mx < 26
end

def extract_brand_palette(twb_text)
  freq = Hash.new(0)
  # color-encoding buckets
  twb_text.scan(/<map\s+to=(['"])(#[0-9a-fA-F]{6})\1/) { |_q, hex| freq[hex.downcase] += 1 }
  # user-defined custom palettes — CATEGORICAL ONLY. ordered-sequential /
  # ordered-diverging bodies are RAMPS (heatmap gradients); ingesting them
  # polluted categoricalScheme with 9-11 near-duplicate ramp steps
  # (field-caught: a 30-color "brand palette" mixing CB_Paired with the
  # CB_PuBu ramp). type='regular' is Tableau's categorical marker.
  twb_text.scan(%r{<color-palette\b([^>]*)>(.*?)</color-palette>}m) do |attrs, body|
    next unless attrs =~ /type=(['"])regular\1/
    body.to_s.scan(/#[0-9a-fA-F]{6}/) { |hex| freq[hex.downcase] += 1 }
  end
  freq.reject! { |hex, _| color_neutral?(hex) }
  freq.sort_by { |hex, n| [-n, hex] }.map(&:first)
end

BRAND_PALETTE = extract_brand_palette(TWB_TEXT)

# ---- Workbook/dashboard style rules (theme channel) ------------------------
# Tableau's Format▸Workbook + Format▸Dashboard land as <style><style-rule
# element='all|worksheet|title|dash-title|dash-text|table'> blocks at workbook
# and dashboard scope. These are the THEME inputs (fonts, dashboard shading) —
# a separate channel from per-zone <zone-style> (zone_style_fields) and
# worksheet-level chart chrome. style-rules under <mapsource-defaults> or
# <datasource> are Mapbox/mark-encoding config, not theme — excluded by
# walking only the two scopes we want. Consumed by lib/theme_derive.
def style_rules_for(scope_el)
  out = {}
  return out unless scope_el
  scope_el.elements.each('style/style-rule') do |sr|
    el = sr.attributes['element'].to_s
    next if el.empty?
    sr.elements.each('format') do |f|
      a = f.attributes['attr']; v = f.attributes['value']
      next if a.nil? || v.nil?
      (out[el] ||= {})[a] = v
    end
  end
  out
end

WORKBOOK_STYLE_RULES = style_rules_for(xml.elements['/workbook'])

def pct(v)
  return nil if v.nil?
  (v.to_f / 1_000.0).round(1)   # Tableau: 100000 == 100%
end

# ---- Column GUID → caption resolver ---------------------------------------
# Tableau filters reference columns by GUID (e.g.,
# `[federated.X].[none:c2ec6b07-...:qk]`). To translate a filter into a Sigma
# control we need the human-readable caption ("Region") plus the data type
# (categorical / date / numeric). Both live on <column> elements throughout the
# .twb (datasource-dependencies blocks AND the top-level metadata-records).
#
# We build a single lookup: { "c2ec6b07-..." => { caption:, datatype: } }.
COL_BY_GUID = {}
# Column role by GUID/body (PR-18): Tableau tags a `<column>` role='dimension'
# when the field is used discretely. Captured alongside caption/datatype so the
# integer-coded-dimension detector can confirm a discrete-dimension shelf role.
# A role='dimension' declaration anywhere wins (a field used discretely on ANY
# sheet is a discrete dimension for filter purposes).
COL_ROLE_BY_KEY = {}
xml.elements.each('//column') do |c|
  raw = c.attributes['name'].to_s
  cap = c.attributes['caption']
  dt  = c.attributes['datatype']
  role_attr = c.attributes['role'].to_s
  # v5.1.1: carry the calc FORMULA — the translator's one-level calc-ref
  # dereference (RANK([CalcRef])<=N over a window share) resolves through it.
  cf  = (calc_el = c.elements['calculation']) && calc_el.attributes['formula']
  next if raw.empty?
  # Names look like `[guid]`, `[guid (foo)]`, `[Friendly Name]`,
  # `[Calculation_123]`, or a Tableau group/copy `[Partner Level (group)]`.
  # Strip surrounding brackets.
  body = raw.sub(/^\[/, '').sub(/\]$/, '')
  # GUID-shaped heads (hex UUID, possibly `(suffix)`-tagged) and Calculation_
  # ids resolve via their leading token — keep the historical head-split so
  # instance refs that quote only the GUID still match. These are only useful
  # when a caption exists (the GUID itself is not human-readable).
  if body =~ /\A([0-9a-f]{8}-[0-9a-f\-]{20,}|Calculation_\d+)/i
    head = body.split(/\s/, 2).first
    COL_ROLE_BY_KEY[head] = 'dimension' if role_attr == 'dimension'
    if cap && !cap.empty?
      COL_BY_GUID[head] ||= { caption: cap, datatype: dt }
      COL_BY_GUID[head][:formula] ||= cf if cf
    elsif cf
      # Caption-less calc columns (Calculation_NNN with only a formula) still
      # need to resolve for the deref — register with the id as caption.
      COL_BY_GUID[head] ||= { caption: head, datatype: dt }
      COL_BY_GUID[head][:formula] ||= cf
    end
  else
    COL_ROLE_BY_KEY[body] = 'dimension' if role_attr == 'dimension'
    # Friendly / group / copy names are referenced VERBATIM by their full body
    # (e.g. instance ref `[none:Customer Geo:nk]` → "Customer Geo", filter
    # `[Partner Level (group)]` → "Partner Level (group)"). Register under the
    # FULL body — NOT the first word — or multi-word names ("Customer Geo")
    # collapse to "Customer" and never resolve. Plain warehouse columns carry NO
    # caption attribute (their name IS the display name), so fall the caption
    # back to the body; that is the fix for the ~40 enterprise quick-filters that were
    # silently dropped ("shared filter has no resolvable column_caption").
    COL_BY_GUID[body] ||= { caption: (cap && !cap.empty? ? cap : body), datatype: dt }
    COL_BY_GUID[body][:formula] ||= cf if cf
  end
end

# ---- Per-column DEFAULT formats (PR-12) ------------------------------------
# Tableau stores a column's default number/date format as a `default-format`
# ATTRIBUTE on <column> (e.g. default-format='p0.00%' / '$#,##0') and, in
# older serializations, as a column-scoped <format attr='…-format' value='…'/>
# child (no field= attr — worksheet-level text-format entries DO carry field=
# and are parsed per worksheet below). These are the display ground truth for
# any sheet that doesn't override per-pill — the reason a one-shot KPI printed
# raw where the source shows $-formatted. Keyed by caption; first (richest)
# declaration wins. Shipped in the meta sidecar as 'column_formats'.
COLUMN_FORMATS = {}
xml.elements.each('//column') do |c|
  cap = c.attributes['caption']
  cap = c.attributes['name'].to_s.gsub(/^\[|\]$/, '') if cap.nil? || cap.empty?
  next if cap.to_s.empty?
  fmt = c.attributes['default-format'].to_s
  if fmt.empty?
    c.elements.each('.//format') do |f|
      next unless f.attributes['field'].nil? && f.attributes['attr'].to_s =~ /-format\z/
      v = f.attributes['value'].to_s
      fmt = v unless v.empty?
      break unless fmt.empty?
    end
  end
  next if fmt.empty?
  COLUMN_FORMATS[cap] ||= fmt
end

# Filter columns use a column-instance level reference like
#   `[federated.X].[none:c2ec6b07-...:qk]`
# where `none` is the derivation and `qk`/`nk` is pivot/key qualifier. Strip
# both and extract the column id.
#
# Two id shapes occur:
#   - raw warehouse columns → a 36-char hex GUID (`c2ec6b07-...`)
#   - CALCULATED fields      → the calc's internal id (`Calculation_<digits>`)
# Both are registered in COL_BY_GUID (the latter keyed by its `Calculation_…`
# head), so resolving either form lets a filter bound to a calc field surface a
# real caption instead of being silently dropped by the auto-control builder
# ("shared filter has no resolvable column_caption"). The raw-GUID behaviour is
# unchanged — we only add the calc-id alternative.
#   - raw warehouse columns by FRIENDLY NAME (`none:Region:nk`) — simple
#     columns whose instance ref uses the column name rather than a GUID; the
#     friendly head (`Region`) is registered in COL_BY_GUID too.
def guid_from_param(param)
  return nil if param.nil? || param.empty?
  # Friendly/group/copy names carry parens, slashes ("Mkt Sourced/Influenced"),
  # hyphens, ampersands, and trailing `(copy)_<digits>` / `(group)` suffixes —
  # the friendly char class keeps them all so refs like `[Partner Level
  # (group)]`, `[none:Region (copy)_4720…:nk]`, and `[none:Mkt
  # Sourced/Influenced:nk]` resolve instead of returning nil (which dropped
  # those quick-filters entirely). `:` stays excluded — it's the structural
  # `<deriv>:<name>:<qual>` delimiter.
  m = param.match(%r{\.\[(?:[a-z\-]+:)?([0-9a-f\-]{36}|Calculation_\d+|[A-Za-z_][\w. ()/&-]*)(?::[a-z]+)?\]$}i)
  return m[1] if m
  # DATASOURCE-LEVEL filters (a <filter> child of <datasource> or its <extract>)
  # reference their column WITHOUT the `[federated.X].` prefix — a bare
  # `[Segment]` / `[none:Segment:nk]`. Accept a single bracket group ONLY when
  # the ref carries no `].[` datasource-qualified segment (so worksheet-level
  # refs, which always carry the prefix, are byte-identical to before).
  unless param.include?('].[')
    m = param.match(%r{\A\[(?:[a-z\-]+:)?([0-9a-f\-]{36}|Calculation_\d+|[A-Za-z_][\w. ()/&-]*)(?::[a-z]+)?\]\z}i)
    return m[1] if m
  end
  nil
end

# Strip Tableau's quoted-string member encoding (`&quot;CA&quot;` → `CA`).
def unquote_member(s)
  return nil if s.nil?
  s = s.to_s.gsub('&quot;', '"').strip
  return nil if s == '%null%'
  s.sub(/^"/, '').sub(/"$/, '')
end

# WILDCARD tab filters (D5/P0.6): Tableau compiles the pattern box into a
# `groupfilter function='filter'` whose expression is a string-match call —
# CONTAINS([Field],"x") / STARTSWITH(...) / ENDSWITH(...), optionally NOT-
# negated and sometimes STR()-wrapped. Parse it into the Sigma text-control
# mode vocabulary ({mode, pattern}); return nil when the expression is not a
# recognizable pattern match (condition-tab expressions stay conditions).
WILDCARD_MODE = {
  'CONTAINS'   => 'contains',
  'STARTSWITH' => 'starts-with',
  'ENDSWITH'   => 'ends-with'
}.freeze
WILDCARD_NEG_MODE = {
  'contains'    => 'does-not-contain',
  'starts-with' => 'does-not-start-with',
  'ends-with'   => 'does-not-end-with'
}.freeze
def parse_wildcard_expression(expr)
  s = expr.to_s.gsub('&quot;', '"').strip
  neg = false
  if (m = s.match(/\A\s*NOT\s+(.*)\z/im))
    neg = true
    s = m[1].strip
  end
  m = s.match(/\A\(?\s*(CONTAINS|STARTSWITH|ENDSWITH)\s*\(\s*(?:STR\s*\(\s*)?\[[^\]]+\]\s*\)?\s*,\s*(['"])(.*)\2\s*\)\s*\)?\z/im)
  return nil unless m
  base = WILDCARD_MODE[m[1].upcase]
  { 'mode' => (neg ? WILDCARD_NEG_MODE[base] : base), 'pattern' => m[3] }
end

# Does an expression LOOK like a wildcard pattern match (even if it failed the
# strict parse above)? Used to route unparseable pattern shapes to a loud
# STAYS-MANUAL instead of silently degrading to "All" / a condition.
def wildcard_flavored?(expr)
  expr.to_s =~ /\b(CONTAINS|STARTSWITH|ENDSWITH)\s*\(/i ? true : false
end

# Read a <filter> element and emit a normalized spec:
#   { kind: "list" | "date-range" | "relative-date" | "number-range" | "action" | "unknown",
#     column_guid: "...", column_caption: "...", datatype: "string|date|real|integer|...",
#     members: ["CA","NY",...]  (for list)
#     min/max: numbers           (for number-range)
#     first_period/last_period/period_type/include_future/include_null  (relative-date)
#     raw_param: ...,
#     is_action: true|false }
def normalize_filter(f)
  cls   = f.attributes['class'].to_s
  param = f.attributes['column'].to_s
  is_action = param.include?('[Action ') || param.include?('[Action(')
  guid  = guid_from_param(param)
  info  = guid ? COL_BY_GUID[guid] : nil

  # Caption fallback: when the ref resolved to a friendly name (not a hex GUID /
  # Calculation_ id) but no <column> def registered it, the extracted token IS
  # the display name — use it rather than dropping the filter as "unresolvable".
  # Strip Tableau's `(copy)_<digits>` / `(group)` decorations for a clean label.
  friendly = guid && guid !~ /\A([0-9a-f]{8}-[0-9a-f\-]{20,}|Calculation_\d+)\z/i
  fallback_caption =
    if friendly
      guid.sub(/\s*\(copy\)_\d+\z/i, '').sub(/\s*\(group\)\z/i, ' (group)').strip
    end

  out = {
    'raw_class'      => cls,
    'raw_param'      => param,
    'column_guid'    => guid,
    'column_caption' => (info && info[:caption]) || fallback_caption,
    'datatype'       => info && info[:datatype],
    'is_action'      => is_action
  }

  if is_action
    out['kind'] = 'action'
    return out
  end

  case cls
  when 'categorical'
    members = []
    conditions = []
    exclude = false
    null_member = false
    wildcard = nil
    wildcard_unparsed = nil
    topn = nil
    order_expr = nil
    order_dir  = nil
    ui_domain  = nil
    f.each_element('.//groupfilter') do |gf|
      fn = gf.attributes['function'].to_s
      # ui-domain (#483): a filter whose enumeration is scoped to the whole
      # database — `user:ui-domain='database'` on the union/filter node — is a
      # DATA-SOURCE-level (always-on) filter, not a dashboard quick-filter the
      # user toggles. Capture it so the shared-view walk can distinguish a
      # virtual-connection data-source filter (which renders nothing on any
      # dashboard) from a real quick filter. (Nokogiri resolves `user:`; probe
      # both keys for the REXML fallback.)
      dom = gf.attributes['user:ui-domain'] || gf.attributes['ui-domain']
      ui_domain ||= dom.to_s if dom && !dom.to_s.empty?
      # EXCLUDE mode (D1/P0.1): the member tree is wrapped in
      # `function='except'` (and/or tagged `user:ui-enumeration='exclusive'`).
      # The member descendants are then the EXCLUDED values — collecting them
      # without this flag silently inverts the filter into an include list.
      # (Nokogiri resolves the `user:` prefix, so probe both attribute keys.)
      enum_attr = gf.attributes['user:ui-enumeration'] || gf.attributes['ui-enumeration']
      exclude = true if fn == 'except' || enum_attr.to_s == 'exclusive'
      if fn == 'member'
        # `%null%` is Tableau's Null member sentinel. unquote_member drops it
        # (a Sigma list value can't carry null), but REMEMBER we saw it: in an
        # exclude filter it means "Tableau hides the null bucket" — the signal
        # the builder needs for the #417 option-source IsNotNull workaround
        # (Sigma's `showNullOption:false` is accepted then silently dropped).
        null_member = true if gf.attributes['member'].to_s.strip == '%null%'
        m = unquote_member(gf.attributes['member'])
        members << m if m
      end
      # Native TOP-N tab (D6/P0.5): `function='end' end='top|bottom' count='N'
      # units='records'` nesting a `function='order' direction='DESC|ASC'
      # expression='SUM([Sales])'`. count may reference [Parameters].[X].
      if fn == 'end'
        topn ||= {}
        topn['end']   = (gf.attributes['end'] || 'top').to_s.downcase
        topn['units'] = gf.attributes['units'] if gf.attributes['units']
        cnt = gf.attributes['count'].to_s.strip
        if cnt =~ /\A\d+\z/
          topn['n'] = cnt.to_i
        elsif !cnt.empty?
          topn['count_param'] = cnt
        end
      end
      if fn == 'order'
        order_dir  = gf.attributes['direction']
        order_expr = gf.attributes['expression']
        next # the ORDER expression is the ranking key, not a condition
      end
      # CONDITION filters (function='filter' with an expression, e.g. a
      # minimum-sample gate `COUNTD([seed]) > 20` guarding a Top-N ranking)
      # were silently invisible — the emitted kind:list carried only members,
      # and two independent field runs had to grep raw XML to discover why
      # their Top-15 rosters were wrong. Surface every expression verbatim.
      # WILDCARD tab patterns also land here (function='filter' whose
      # expression is a CONTAINS/STARTSWITH/ENDSWITH compile) — peel those
      # off into a typed wildcard spec instead of a raw condition.
      expr = gf.attributes['expression']
      next unless expr && !expr.strip.empty?
      if fn == 'filter' && wildcard.nil? && (wc = parse_wildcard_expression(expr))
        wildcard = wc
      elsif fn == 'filter' && wildcard_flavored?(expr)
        wildcard_unparsed ||= expr
      else
        conditions << expr
      end
    end
    out['kind']    = 'list'
    out['members'] = members
    out['exclude'] = true if exclude
    out['ui_domain'] = ui_domain if ui_domain
    # A single-member boolean list (e.g. `company_active = true`) is the classic
    # always-on "active flag" data-source filter shape (#483). Advisory metadata;
    # the gate keys on is_datasource_filter, this only sharpens its messaging.
    if !exclude && members.length == 1 &&
       %w[true false 1 0 yes no].include?(members.first.to_s.downcase)
      out['is_active_flag'] = true
    end
    # An exclude filter whose excluded members include Null: the view hides
    # the null bucket. Surfaced so the builder can filter nulls at the list
    # control's option source (#417 workaround) instead of emitting the
    # silently-dropped `showNullOption:false`.
    out['excludes_null'] = true if exclude && null_member
    if topn
      topn['direction']  = (order_dir || 'DESC').to_s.upcase
      topn['order_expr'] = order_expr if order_expr
      out['topn'] = topn
    end
    if wildcard || wildcard_unparsed
      # A wildcard filter carries no member enumeration — surface it as its
      # own kind so the builder emits a text control / text-match element
      # filter (or a loud STAYS-MANUAL for unparseable patterns) instead of
      # mislabeling the empty member list as Tableau "All".
      out['kind'] = 'wildcard'
      out['wildcard'] = wildcard if wildcard
      out['wildcard_unparsed'] = wildcard_unparsed if wildcard.nil?
    end
    unless conditions.empty?
      out['condition_expressions'] = conditions.uniq
      out['kind'] = 'list+condition' if members.empty? && out['kind'] == 'list'
    end
  when 'relative-date'
    out['kind']           = 'relative-date'
    out['first_period']   = f.attributes['first-period']
    out['last_period']    = f.attributes['last-period']
    out['period_type']    = f.attributes['period-type-v2'] || f.attributes['period-type']
    out['include_future'] = f.attributes['include-future']
    out['include_null']   = f.attributes['include-null']
  when 'quantitative'
    out['kind'] = 'number-range'
    out['min'] = f.attributes['min']
    out['max'] = f.attributes['max']
  else
    out['kind'] = 'unknown'
  end

  # PR-18: flag an integer-coded column used as a DISCRETE dimension on a filter
  # shelf. Signals: integer datatype + a discrete (categorical/list) filter, or a
  # declared `role='dimension'`. Downstream (build-charts) routes a Text() decode
  # helper so the Sigma list control's STRING option values actually filter the
  # column instead of being silently stripped. Only stamped when TRUE — a
  # non-integer/quantitative filter's normalized output is unchanged.
  role = COL_ROLE_BY_KEY[guid] if guid
  out['integer_dim'] = true if IntegerDim.integer_dim_filter?(out.merge('role' => role))
  out
end

# ---- Rows/Cols shelf parsing (pivot-table detection) ----------------------
# Tableau worksheets carry their shelf state inside <table>:
#   <rows>[federated.X].[REGION] / [federated.X].[CATEGORY]</rows>
#   <cols>[federated.X].[yr:ORDER_DATE:ok] / [federated.X].[sum:SALES:qk]</cols>
# Each field is separated by ` / `. The bracketed spec carries a prefix that
# tells us role:
#   `[FIELDNAME]` (no prefix)                 → dim
#   `[none:GUID:nk]` / `[none:GUID:qk]`       → dim (Tableau's "no aggregation")
#   `[yr|qr|mn|wk|dy|hr|mi|sc:GUID:ok]`       → date-trunc dim
#   `[mdy|md|qd|ymd|y|q|m|d|w|h|s:...]`       → date-part dim
#   `[sum|avg|min|max|count|countd|cntd|median|stdev|stdevp|var|varp|attr|usr:...]`
#                                              → measure
#   `[Measure Names]` literal                  → placeholder, skip
#
# Detection rule for pivot-table:
#   - mark in {Text, Square} (necessary)
#   - rows AND cols each carry ≥1 real dim                       → pivot-table
#   - OR one shelf has a real dim + the other has Measure Names
#     plus the worksheet has ≥2 measures                          → pivot-table
#   - Otherwise (one shelf empty, or both empty)                  → table
# v5.1.1: pcto/rtot are Tableau QUICK-CALC measure tokens (percent-of-total /
# running-total) — without them a pcto pill classified role='dim' and the
# builder's PercentOfTotal mapping was unreachable (review-caught).
MEASURE_PREFIXES = %w[sum avg min max count countd cntd median stdev stdevp var varp attr usr pcto rtot].freeze
DATE_TRUNC_PREFIXES = %w[yr qr mn wk dy hr mi sc mdy md qd ymd y q m d w h s].freeze

# Classify a single shelf-field bracketed spec like "none:GUID:qk" or "sum:GUID:qk"
# or "REGION" (no prefix).
# Returns [:dim | :measure | :measure_names | :skip, derivation_or_nil, discrete_bool].
#
# The trailing type code encodes the pill's data role: `qk`/`ok` = CONTINUOUS
# (green — a measure that draws a bar/line axis), `nk` = DISCRETE (blue — renders
# as a text header, never an axis). Dimensions are always discrete; a MEASURE can
# be either. A discrete measure (e.g. `[usr:Calc:nk]`) is a text-table cell, not a
# bar — so we surface `discrete` for the chart-kind inference to honor.
# An optional trailing `:N` is a duplicate-instance index (the same field placed
# twice on the shelves), NOT part of the type code — strip it before reading the
# code, or a field like `[usr:Calc:nk:1]` slips past the matcher and is mis-typed
# as a dimension.
def classify_shelf_field(field_str)
  return [:skip, nil, false] if field_str.nil? || field_str.strip.empty?
  fs = field_str.strip
  # Bare "[Measure Names]" or ".[Measure Names]" → placeholder
  return [:measure_names, nil, false] if fs =~ /\bMeasure\s*Names\b/i
  # Extract the inner spec — the last `[...]` segment
  spec = fs[/\[([^\[\]]*)\]\s*$/, 1] || fs
  # Aggregation/trunc prefix form: "prefix:GUID:type" (+ optional ":N" instance)
  if (m = spec.match(/^([a-z]+):.*?:([a-z]+)(?::\d+)?$/i))
    pref = m[1].downcase
    discrete = m[2].downcase.start_with?('n')   # nk → discrete; qk/ok → continuous
    return [:measure, pref, discrete] if MEASURE_PREFIXES.include?(pref)
    return [:dim, pref, false]        if DATE_TRUNC_PREFIXES.include?(pref)
    return [:dim, pref, false]        if pref == 'none'
    return [:dim, pref, false]        # unknown prefix → conservative dim
  end
  # No prefix → dim (e.g. "[REGION]")
  [:dim, nil, false]
end

# Parse a `<rows>` or `<cols>` shelf string into a structured summary.
def parse_shelf(shelf_str)
  out = { 'raw' => shelf_str, 'fields' => [], 'dim_count' => 0,
          'measure_count' => 0, 'cont_measure_count' => 0,
          'has_measure_names' => false, 'has_measure_values' => false }
  return out if shelf_str.nil? || shelf_str.strip.empty?
  # The Measure-VALUES pill (`[Multiple Values]` / `[Measure Values]`) signals
  # measures placed on this shelf as a VISUAL encoding (bar lengths / line
  # values). Detect it from the RAW string as a flag — NOT as a per-field role —
  # because a shelf can hold it ALONGSIDE a real measure pill
  # (`([Multiple Values] + [usr:Calc:qk])`), and classifying the whole field as
  # measure-values would drop that real measure and break line/bar inference.
  out['has_measure_values'] = true if shelf_str =~ /\[(?:Multiple|Measure)\s+Values\]/i
  shelf_str.split('/').each do |f|
    # Nested shelves wrap the field list in parens —
    #   `([ds].[none:A:nk] / [ds].[none:B:nk])`
    # — so split('/') leaves a leading '(' on the first field and a trailing
    # ')' on the last. Strip surrounding parens/whitespace; otherwise
    # guid_from_param / classify_shelf_field (both anchored on a trailing ']')
    # miss, and the nested dim keeps its raw federated GUID and POSTs as a
    # broken `[Master/<guid>:nk])` dependency. (Field refs never contain
    # parens, so this is safe for flat and ≥2-level nested shelves alike.)
    raw_field = f.strip.gsub(/\A[(\s]+/, '').gsub(/[)\s]+\z/, '')
    next if raw_field.empty?
    role, deriv, discrete = classify_shelf_field(raw_field)
    case role
    when :dim
      out['dim_count'] += 1
      out['fields'] << { 'raw' => raw_field, 'role' => 'dim', 'derivation' => deriv,
                         'guid' => guid_from_param(raw_field) }
    when :measure
      out['measure_count'] += 1
      out['cont_measure_count'] += 1 unless discrete
      out['fields'] << { 'raw' => raw_field, 'role' => 'measure', 'derivation' => deriv,
                         'discrete' => discrete, 'guid' => guid_from_param(raw_field) }
    when :measure_names
      out['has_measure_names'] = true
      out['fields'] << { 'raw' => raw_field, 'role' => 'measure-names' }
    end
  end
  out
end

# Build a lookup of worksheet name → metadata extracted from <worksheet> elements.
# - mark_class: the <mark class="..."> value (Bar / Line / Pie / Filled / Circle / etc.)
# - geo_role:   the first geographic semantic-role we find on any column (e.g. "geo:state")
# - has_lat / has_long: heuristic for point-map detection (column names contain
#   "latitude" / "longitude")
# - rows_shelf / cols_shelf: structured summary of dims/measures on each shelf
# - is_crosstab: convenience flag — true when the worksheet is a Tableau crosstab
#   (Text/Square mark + dims on both shelves, or Measure Names crosstab)
# Top-level datasource calc definitions — the SOURCE OF TRUTH for a calc's
# formula. Worksheet <datasource-dependencies> blocks carry CACHED copies that
# go stale when the calc is later edited in the datasource (caught live on
# WINPROBE: the funnel's [Return Rate] dependency block said SUM/COUNTD while
# the top-level datasource — and Tableau's actual evaluation + CSV export —
# said SUM/COUNT). Keyed by internal column name; used to OVERRIDE the
# per-worksheet formula on name match.
ds_calc_formulas = {}
xml.elements.each('/workbook/datasources/datasource') do |ds|
  ds_label = (ds.attributes['caption'] || ds.attributes['name']).to_s
  next if ds_label.start_with?('Parameter')
  ds.elements.each('column') do |col|
    calc = col.elements['calculation']
    next unless calc && calc.attributes['class'] == 'tableau'
    f = calc.attributes['formula']
    next if f.nil? || f.empty?
    ds_calc_formulas[col.attributes['name'].to_s] = f
  end
end

# ── Phase-1 B3: KPI scorecard <customized-label> (BAN) extraction ────────────
# A Tableau "big number" scorecard often uses a Shape/Circle mark with the value
# rendered as a <customized-label> BAN inside the pane, e.g.:
#   <customized-label><formatted-text>
#     <run fontcolor='#333' fontsize='10'>Total Job Losses</run>   ← label
#     <run fontsize='26'><[…measure…]></run>                        ← BAN value
#     <run fontcolor='#666' fontsize='8'>of U.S. total</run>        ← annotation
#   </formatted-text></customized-label>
# Returns {label, value_font_size, annotation_runs} when a BAN (a run whose font
# size is >= KPI_BAN_MIN_FONT — the "big number") is present, else nil. The BAN
# lets a Shape/Circle-mark scorecard qualify as a KPI (narrow: a real scatter has
# no big-font customized-label), and feeds the B3 composite emit (label + big
# value + side annotation). Runs mirror zone_text_fields' shape (Æ = U+00C6
# line-break sentinel); `ref`=true marks a dynamic <[…]> field/measure token.
KPI_BAN_MIN_FONT = 16
# The worksheet's DISPLAYED title (shown above the viz on a dashboard) — the
# source of the human element name ("Net Revenue"), distinct from the worksheet
# NAME/nickname ("OV KPI Revenue"). Path: layout-options/title/formatted-text.
# Custom text only: a DEFAULT title is the "<Sheet Name>" field token (or the
# element is absent), which we skip so the builder falls back to the nickname.
# Concatenates runs (a title can be multi-span).
def worksheet_display_title(ws)
  t = ws.elements['layout-options/title'] || ws.elements['title']
  return nil unless t
  ft = t.elements['formatted-text']
  return nil unless ft
  # .elements.to_a('run') / .text — supported by BOTH backends of twb_xml
  # (the Nokogiri shim and the REXML fallback); get_elements is REXML-only.
  txt = ft.elements.to_a('run').map { |r| r.text.to_s }.join.strip
  return nil if txt.empty?
  return nil if txt =~ /\A<[^<>]+>\z/ # "<Sheet Name>" / field-token default
  txt
end

def parse_customized_label(ws)
  cl = ws.elements['.//customized-label']
  return nil unless cl
  runs = []
  cl.elements.each('.//run') do |r|
    txt = r.text.to_s.gsub("Æ", '')
    a = r.attributes
    runs << {
      'text'      => txt,
      'color'     => (c = a['fontcolor']) && !c.empty? ? c : nil,
      'font_size' => (fs = a['fontsize']) && !fs.empty? ? fs.to_i : nil,
      'bold'      => a['bold'] == 'true',
      'break'     => txt.include?("\n"),
      'ref'       => txt.include?('<[')
    }.compact
  end
  return nil if runs.empty?
  ban_i    = runs.each_index.max_by { |i| runs[i]['font_size'] || 0 }
  ban_font = (runs[ban_i] && runs[ban_i]['font_size']) || 0
  return nil if ban_font < KPI_BAN_MIN_FONT
  # Label = leading non-ref, non-spacer, non-tiny (>= 6pt) text runs before the
  # BAN value run (drops the invisible filler runs Tableau injects for spacing).
  label = runs[0...ban_i]
          .reject { |r| r['ref'] || r['text'].to_s.strip.empty? || (r['font_size'] && r['font_size'] < 6) }
          .map { |r| r['text'] }.join(' ').gsub(/\s+/, ' ').strip
  { 'label'           => (label.empty? ? nil : label),
    'value_font_size' => ban_font,
    'annotation_runs' => (runs[(ban_i + 1)..] || []) }.compact
end

worksheets = {}
xml.elements.each('//worksheet') do |ws|
  name = ws.attributes['name']
  next unless name
  mark = ws.elements['.//mark']
  mark_class = mark ? (mark.attributes['class'].to_s) : nil
  # Phase-1 B3: a Shape/Circle scorecard's big-number <customized-label> (nil otherwise).
  kpi_ban = parse_customized_label(ws)

  geo_role = nil
  has_lat  = false
  has_long = false
  has_geometry = !ws.elements['.//geometry'].nil?
  ws.elements.each('.//column') do |col|
    # Tableau's `semantic-role` attribute on a column carries the geographic
    # assignment when one is set. Patterns we've seen in the wild:
    #   [Country].[ISO3166_2]      [State].[Country].[State]
    #   [State/Province].[Name]    [City].[Country].[Name]
    #   [County].[Country].[Name]  [Zip Code].[Country].[Zip]
    # If the attribute is present at all, the column carries a geo assignment.
    role = col.attributes['semantic-role'] || col.attributes['semanticRole']
    if role && !role.to_s.empty?
      geo_role ||= role
    end
    nm = col.attributes['caption'] || col.attributes['name'] || ''
    has_lat  = true if nm =~ /latitude/i
    has_long = true if nm =~ /longitude/i
  end

  # Per-worksheet sort. <sort> element under the worksheet carries direction
  # ("ascending"|"descending") and a `column` attribute referencing the sorted
  # dimension. We emit the first sort we find (Tableau allows multiple but
  # downstream tooling almost always wants the primary one).
  sort_info = nil
  if (s = ws.elements['.//sort'])
    sort_info = {
      direction: s.attributes['direction'],
      column:    s.attributes['column']
    }
  end
  # "Sort field X by measure Y" lands as <computed-sort column='<dim ref>'
  # direction='ASC|DESC' using='<measure column-instance ref>'/> — a DIFFERENT
  # element from <sort>. Window-function worksheets (pareto / rank) rely on it:
  # Sigma Cumulative* / Rank follow the chart's xAxis sort, so dropping the
  # computed-sort silently re-accumulates in natural order and every cumulative
  # value diverges. `using` is carried so build-charts can sort by the measure.
  if sort_info.nil? && (cs = ws.elements['.//computed-sort'])
    sort_info = {
      direction: (cs.attributes['direction'].to_s =~ /desc/i ? 'descending' : 'ascending'),
      column:    cs.attributes['column'],
      using:     cs.attributes['using']
    }
  end

  # K21: <alphabetic-sort> — "sort this dimension alphabetically". The vendored
  # XSD (schemas/twb_2026.2.0.xsd, Sort-Alphabetic-G) declares it as an EMPTY
  # element with no attributes, so there is no `column` to resolve. That matters:
  # sort_target_column_id falls back to the MEASURE on an empty column token, so
  # wiring this through without an explicit marker silently sorts the wrong axis.
  # Hence `alphabetic: true`, which the resolver checks before that fallback.
  # `direction`/`column` are read defensively in case a real export carries them
  # (the XSD says it does not; not verified against a live .twb).
  if sort_info.nil? && (as = ws.elements['.//alphabetic-sort'])
    sort_info = {
      direction:  (as.attributes['direction'].to_s =~ /desc/i ? 'descending' : 'ascending'),
      column:     as.attributes['column'],
      alphabetic: true
    }
  end

  # Per-worksheet view-level filters. Each filter is normalized via
  # normalize_filter (resolves GUID → caption + datatype, extracts member values
  # for categorical, period spec for relative-date, min/max for quantitative,
  # and flags action filters separately).
  filters_info = []
  ws.elements.each('.//filter') do |f|
    filters_info << normalize_filter(f)
  end

  # Per-column aggregation override. <column-instance derivation="Sum|Avg|Min|
  # Max|Median|CountD|None|User|Month-Trunc|Year-Trunc|..."> tells us what
  # aggregation Tableau is using for that column in the pane. We expose all of
  # them; the agent decides which are interesting (non-default).
  aggregations = {}
  ws.elements.each('.//column-instance') do |ci|
    col = ci.attributes['column']
    deriv = ci.attributes['derivation']
    next if col.nil? || deriv.nil?
    aggregations[col.to_s] = deriv.to_s
  end

  # Per-column format strings. Tableau emits these via
  #   <style-rule element='cell'>
  #     <format attr='text-format' field='[federated.X].[col-ref]' value='p0.0%' />
  # We capture the value verbatim keyed by the field reference. translate_format
  # below converts to Sigma's d3-format string.
  formats = {}
  ws.elements.each('.//format') do |fmt|
    next unless fmt.attributes['attr'] == 'text-format'
    field = fmt.attributes['field']
    val   = fmt.attributes['value']
    next if field.nil? || val.nil?
    formats[field.to_s] = val.to_s
  end

  # Per-worksheet dual-axis / synchronized-axis detection. Tableau combo charts
  # ship two measures on the same dim shelf and a `synchronized='true'`
  # attribute on the axis encoding inside <style-rule element='axis'>. We surface:
  #   dual_axis: bool       — true if any axis has synchronized='true' or there
  #                            are 2+ distinct quantitative measures
  #   measures:  [{column, derivation}]
  axis_synced = false
  # Axis range/scale/log overrides. Tableau emits these inside
  #   <style-rule element='axis'><encoding attr='space' .../></style-rule>
  # Attributes we extract:
  #   scope='rows'|'cols'           → which Sigma axis: rows→yAxis, cols→xAxis
  #   class='0'|'1'                 → axis index: 0=primary, 1=secondary (dual-axis)
  #   scale='log'                   → log scale (otherwise linear)
  #   range-type='fixed'|'automatic'→ when 'fixed', honor min/max
  #   min='...' max='...'           → numeric bounds (only meaningful when fixed)
  # Verified against "Orders Conversion Test" workbook (2026-05-22).
  axis_formats = []
  ws.elements.each('.//style-rule[@element="axis"]/encoding') do |e|
    a = e.attributes
    if a['synchronized'].to_s == 'true'
      axis_synced = true
    end
    next unless a['attr'].to_s == 'space'
    next unless %w[rows cols].include?(a['scope'].to_s)
    af = {
      'scope'      => a['scope'].to_s,
      'class'      => a['class'].to_s,
      'scale'      => a['scale']&.to_s,
      'range_type' => a['range-type']&.to_s,
      'field'      => a['field']&.to_s
    }
    af['min'] = a['min'].to_f if a['min']
    af['max'] = a['max'].to_f if a['max']
    axis_formats << af.compact
  end
  measures = []
  ws.elements.each('.//column-instance') do |ci|
    col = ci.attributes['column']
    deriv = ci.attributes['derivation']
    next if col.nil? || deriv.nil?
    next unless ci.attributes['type'] == 'quantitative'
    # 'None' = raw (non-aggregated) usage — not a measure. 'User' IS a measure:
    # a user-aggregated calc field (ratio KPIs like Gross Margin Pct). Excluding
    # it made every calc-measure KPI read as 0-measure and fall through to the
    # flat-table flow (bead 3w4d — "CSV has only 1 column" KPI drops).
    next if deriv == 'None'
    measures << { 'column' => col.to_s, 'derivation' => deriv.to_s }
  end
  # Conservative: only flag dual_axis when Tableau explicitly synchronized two
  # axes. Multi-measure worksheets without sync are usually pivot tables or
  # measure-name shelves, not combo charts.
  dual_axis = axis_synced

  # Per-worksheet reference lines / bands / distributions / trendlines.
  # Surface enough metadata for build-charts-from-signals.rb to emit Sigma
  # refMarks / trendlines blocks per the new chart spec (2026-05-21):
  #
  #   - formula:      "average" | "median" | "max" | "min" | "sum" | "count" | "constant" | "attr" | ...
  #   - axis_column:  Tableau axis-column ref (column the line is anchored to)
  #   - value_column: column the formula evaluates against (often same as axis-column)
  #   - label:        custom label text (with <Value> template) or nil
  #   - label_type:   "custom" | "none" | "computation" | ...
  #   - scope:        "per-table" | "per-pane" | "per-cell"
  #   - band_values:  array of percentage thresholds for percentage-bands
  #   - fill_above / fill_below / percentage_bands / symmetric: band styling flags
  def extract_ref_line_attrs(node, kind)
    a = node.attributes
    info = {
      'kind'         => kind,
      'formula'      => a['formula'],
      'axis_column'  => a['axis-column'],
      'value_column' => a['value-column'],
      'label'        => a['label'],
      'label_type'   => a['label-type'],
      'scope'        => a['scope']
    }
    info['fill_above']        = a['fill-above']        if a['fill-above']
    info['fill_below']        = a['fill-below']        if a['fill-below']
    info['percentage_bands']  = a['percentage-bands']  if a['percentage-bands']
    info['symmetric']         = a['symmetric']         if a['symmetric']
    info['probability']       = a['probability']       if a['probability']
    band_vals = node.elements.to_a('.//reference-line-value').map { |v| v.attributes['percentage'] }.compact
    info['band_values'] = band_vals unless band_vals.empty?
    info.compact
  end

  ref_marks = []
  ws.elements.each('.//reference-line')        { |n| ref_marks << extract_ref_line_attrs(n, 'line') }
  ws.elements.each('.//reference-band')        { |n| ref_marks << extract_ref_line_attrs(n, 'band') }
  ws.elements.each('.//reference-distribution'){ |n| ref_marks << extract_ref_line_attrs(n, 'distribution') }
  ws.elements.each('.//trendline-model') do |n|
    a = n.attributes
    ref_marks << {
      'kind'    => 'trendline',
      'model'   => a['model-type'] || a['model'] || 'linear',
      'field_x' => a['field-x'],
      'field_y' => a['field-y']
    }.compact
  end

  # Encoding channels (color / size / detail / shape / label / tooltip).
  # Color is the key one for multi-series approximations (Sales by Segment etc).
  channels = {}
  ws.elements.each('.//encodings/encoding') do |e|
    attr = e.attributes['attr']
    next unless %w[color size shape detail label tooltip text].include?(attr.to_s)
    channels[attr.to_s] = {
      column: e.attributes['column'],
      field:  e.attributes['field']
    }
  end
  # Alt/older form: the channel is the ELEMENT NAME, not an attr — e.g.
  #   <encodings><color column='…Customer Value Tier…'/></encodings>
  # (vs the newer <encoding attr='color' …/> above). Without this, a dimension
  # on the color shelf (categorical bar coloring) is silently dropped.
  ws.elements.each('.//encodings/*') do |e|
    ch = e.name.to_s
    next unless %w[color size shape detail label tooltip text].include?(ch)
    next if channels.key?(ch) # newer form already captured this channel
    channels[ch] = { column: e.attributes['column'], field: e.attributes['field'] }
  end

  # Per-worksheet calculated fields. Tableau emits these as
  #   <column datatype='X' name='[Calc Name]' role='dimension|measure' type='...'>
  #     <calculation class='tableau' formula='...' />
  #   </column>
  # We surface them so the build script can flag (or translate) calcs that are
  # used by this worksheet's chart.
  calcs = []
  ws.elements.each('.//column') do |col|
    calc = col.elements['calculation']
    next unless calc
    cls  = calc.attributes['class']
    formula = calc.attributes['formula']
    next if formula.nil? || formula.empty?
    entry = {
      'name'    => col.attributes['name'],
      'caption' => col.attributes['caption'],
      'datatype'=> col.attributes['datatype'],
      'role'    => col.attributes['role'],
      'class'   => cls,
      'formula' => formula
    }
    # Tableau numeric bins are calc columns with class='bin': `formula` is the
    # base field ref, `size` (or a `size-parameter` ref) is the bin width and
    # `peg` the bin origin. Surfaced so build-charts-from-signals.rb can emit
    # the Sigma-native BinFixed/BinRange translation (beads-sigma-t67b).
    if cls == 'bin'
      entry['bin_size'] = calc.attributes['size'] || calc.attributes['size-parameter']
      entry['bin_peg']  = calc.attributes['peg']
    end
    # Stale-dependency override: the top-level datasource definition wins over
    # the worksheet's cached copy (see ds_calc_formulas above).
    ds_f = ds_calc_formulas[col.attributes['name'].to_s]
    if cls == 'tableau' && ds_f && ds_f != formula
      entry['stale_dependency_formula'] = formula
      entry['formula'] = ds_f
    end
    calcs << entry
  end

  # v5.1.1: table-calc ADDRESSING ("compute using <dim>") — serialized on the
  # worksheet's <column-instance> as <table-calc ordering-field='[ds].[dim]'
  # ordering-type='Field'/>. For RANK-family calcs this names the RANKED
  # ENTITY dimension, which the top-N prefilter must filter (review round: a
  # rowsBy-first heuristic picked the pivot's other axis — directions, not
  # rooms). A column-instance can carry several <table-calc> children: the one
  # WITHOUT a field= attr is this calc's own addressing (field='[X]' entries
  # belong to nested calc X).
  quick_calc_pcto = []
  ws.elements.each('.//column-instance') do |ci|
    ci_col = ci.attributes['column'].to_s[/\[([^\]]+)\]/, 1]
    next if ci_col.nil? || ci_col.empty?
    tcs = []
    ci.elements.each('table-calc') { |t| tcs << t }
    tc = tcs.find { |t| t.attributes['field'].nil? } || tcs.first
    of = tc && tc.attributes['ordering-field']
    # v5.1.2: percent-of-total QUICK CALC on the MARKS CARD — the canonical
    # Tableau crosstab heatmap. The pill never touches rows/cols shelves
    # (MEASURE_PREFIXES can't see it); it serializes as
    #   <column-instance column='[seed]' derivation='CountD'
    #                    name='[pcto:ctd:seed:qk]'>
    #     <table-calc ordering-field='[..].[summoner_dir]' type='PctTotal'/>
    # and z['measures'] recorded only the bare CountD — the pivot shipped raw
    # counts where the source renders percentages (review round). The
    # PctTotal addressing dim decides the Sigma PercentOfTotal scope.
    # (?::[a-z0-9]+)* — Tableau appends a NUMERIC instance suffix when the
    # same quick-calc pill exists twice in the workbook ([pcto:ctd:seed:qk:2],
    # present in the reference twb itself); [a-z]+ silently missed those and
    # the second crosstab shipped raw counts (v5.1.3 review-caught).
    if (qm = ci.attributes['name'].to_s.match(/\A\[pcto:([a-z]+):([^:\]]+)(?::[a-z0-9]+)*\]\z/i))
      addr = of && of.to_s[/\.\[(?:[a-z]+:)?([^:\]]+)(?::[a-z0-9]+)*\]\z/, 1]
      quick_calc_pcto << { 'agg' => qm[1].downcase, 'col' => qm[2],
                           'addressing' => addr, 'token' => ci.attributes['name'].to_s }
    end
    next unless of
    inner = of.to_s[/\.\[(?:[a-z]+:)?([^:\]]+)(?::[a-z0-9]+)*\]\z/, 1]
    next unless inner
    c = calcs.find { |x| x['name'].to_s.gsub(/^\[|\]$/, '') == ci_col }
    c['ordering_field'] = inner if c && !c['ordering_field']
  end

  # Worksheet-level "Show Mark Labels" toggle. Tableau emits this on the
  # worksheet's pane style:
  #   <pane><style><style-rule element='mark'>
  #     <format attr='mark-labels-show' value='true' />
  # Verified against "Orders Conversion Test" workbook (2026-05-22).
  mark_labels_show = false
  ws.elements.each(".//pane//style-rule[@element='mark']/format") do |f|
    if f.attributes['attr'].to_s == 'mark-labels-show' && f.attributes['value'].to_s == 'true'
      mark_labels_show = true
      break
    end
  end

  # Rows/Cols shelf parsing for pivot-table detection. Tableau emits these as
  # sibling elements under <table> in the worksheet. We pick the first match
  # (worksheets rarely have multiples).
  rows_node  = ws.elements['.//table/rows'] || ws.elements['.//rows']
  cols_node  = ws.elements['.//table/cols'] || ws.elements['.//cols']
  rows_shelf = parse_shelf(rows_node&.text)
  cols_shelf = parse_shelf(cols_node&.text)

  # Crosstab signal:
  #   (a) explicit Text/Square mark with ≥1 real dim on BOTH shelves, OR a
  #       Measure-Names shelf (≥2 measures + ≥1 dim) — the mark is unambiguous, OR
  #   (b) Automatic/blank mark with Measure Names AND dims on BOTH shelves.
  # Measure Names on a shelf lays measures out as a text grid, and Tableau's
  # DEFAULT "Automatic" mark renders that grid as text — so a crosstab authored
  # without flipping the mark to "Text" reports mark_class="Automatic" (or blank).
  # Gating only on text/square missed every such table (enterprise's "Metric Partner
  # Closed Won" / "1T.PartnerClosed size&Status" → flat table/kpi, losing the
  # grouped quarter headers + Grand Total).
  #
  # BUT the AUTOMATIC relaxation excludes sheets carrying the Measure-VALUES pill
  # (`[Multiple Values]` / `[Measure Values]`) on a shelf: that places the
  # measures as a VISUAL encoding (bar lengths / line values), so an
  # Automatic-mark sheet with Measure Names on one shelf and Measure Values on the
  # other is a MULTI-MEASURE BAR, not a text crosstab (real-world catch: a public
  # "Barchart of accident factors" sheet — Measure Names on cols, `[Multiple
  # Values]` on rows — must stay a bar). A genuine text crosstab carries the
  # measure values on the Text marks card, never as a row/col pill. Explicit
  # Text/Square marks keep the lenient rule — the author's intent is unambiguous.
  is_text_mark = %w[text square].include?(mark_class.to_s.downcase)
  automatic_mark = mark_class.to_s.downcase == 'automatic' || mark_class.to_s.strip.empty?
  both_have_dims = rows_shelf['dim_count'] >= 1 && cols_shelf['dim_count'] >= 1
  shelf_has_measure_values = rows_shelf['has_measure_values'] || cols_shelf['has_measure_values']
  measure_names_crosstab =
    (rows_shelf['has_measure_names'] || cols_shelf['has_measure_names']) &&
    (rows_shelf['dim_count'] + cols_shelf['dim_count']) >= 1 &&
    (rows_shelf['measure_count'] + cols_shelf['measure_count'] + measures.size) >= 2
  is_crosstab = (is_text_mark && (both_have_dims || measure_names_crosstab)) ||
                (automatic_mark && measure_names_crosstab && !shelf_has_measure_values)

  # KPI signal: Text/Square/AUTOMATIC mark with ZERO dims on both shelves AND
  # ≥1 measure (on shelves or on the worksheet's Marks card). Tableau
  # "scorecard" / "big number" tiles match this shape — they're not detail
  # lists, not crosstabs, just a single aggregated value rendered as text.
  # Maps to Sigma kpi-chart. beads-sigma-bw3.
  # Automatic mark included (bead 3w4d): Tableau's default mark for a
  # zero-dim single-measure sheet renders as a big-number text table — the
  # FATSCALE rehearsal lost 14/40 tiles because these fell through to the
  # CSV-driven flow (1-column CSV → zone dropped).
  # Phase-1 B3: a Shape/Circle scorecard carrying a big-number <customized-label>
  # BAN is a KPI too (Tableau's "big number on a dot" idiom). Narrow by design —
  # a real scatter/symbol plot has no large-font customized-label — so ordinary
  # Shape/Circle marks keep flowing to scatter.
  ban_scorecard_mark = !kpi_ban.nil? && %w[shape circle].include?(mark_class.to_s.downcase)
  kpi_capable_mark = is_text_mark || mark_class.to_s.downcase == 'automatic' ||
                     mark_class.to_s.empty? || ban_scorecard_mark
  total_dim_count = rows_shelf['dim_count'] + cols_shelf['dim_count']
  total_measure_count = rows_shelf['measure_count'] + cols_shelf['measure_count'] + measures.size
  is_kpi = kpi_capable_mark && !is_crosstab &&
           total_dim_count == 0 && total_measure_count >= 1

  # Hidden calc filters: worksheet-level filters whose target column is a
  # calculated field. These are invisible in Tableau CSV exports — they silently
  # reduce row counts and cause parity divergences with no warning. A filter is
  # "calc-targeted" when:
  #   - the column ref contains `Calculation_`
  #   - the column ref starts with `[Parameters.`
  #   - OR the resolved COL_BY_GUID entry matches a calc we know about
  # We walk the already-built filters_info (worksheet-level only, NOT
  # shared-view filters — those are dashboard-level).
  # Build a set of known calc column names from this worksheet's calcs plus
  # top-level datasource calcs for quick membership test.
  ws_calc_names = calcs.map { |c| c['name'].to_s }.to_set
  ws_calc_captions = calcs.map { |c| c['caption'].to_s }.reject(&:empty?).to_set
  hidden_filters = filters_info.select do |fi|
    raw = fi['raw_param'].to_s
    guid = fi['column_guid'].to_s
    # Check 1: raw param contains Calculation_ or Parameters.
    next true if raw =~ /Calculation_\d+/i
    next true if raw =~ /\[Parameters\./i
    # Check 2: resolved guid is a Calculation_ id
    next true if guid =~ /\ACalculation_\d+\z/i
    # Check 3: caption matches a known calc in this worksheet
    cap = fi['column_caption'].to_s
    next true if !cap.empty? && (ws_calc_captions.include?(cap) || ws_calc_names.include?("[#{cap}]"))
    false
  end.map do |fi|
    hf = {
      'calc_ref'    => fi['raw_param'],
      'caption'     => fi['column_caption'],
      'filter_type' => fi['raw_class'],
      'kind'        => fi['kind']
    }
    hf['members'] = fi['members'] if fi['kind'] == 'list' && fi['members']
    hf['min']     = fi['min']     if fi['min']
    hf['max']     = fi['max']     if fi['max']
    hf.compact
  end

  # v5.1: pivot/shelf sorts live in <shelf-sort-v2> (dimension-to-sort +
  # measure-to-sort-by + direction + shelf) — a DIFFERENT surface from
  # <sort>/<computed-sort>, and the reason three rounds of ranked pivots
  # shipped alphabetical. Resolve the field tokens to captions best-effort
  # ([fed].[none:Concat_X:nk] → Concat_X; [fed].[ctd:seed:qk] → ctd:seed).
  shelf_sorts = []
  ws.elements.each('.//shelf-sort-v2') do |ss|
    tok = ->(s) { s.to_s[/\[[^\]]+\]\.\[(?:[a-z]+:)?([^:\]]+)(?::[a-z0-9]+)*\]/, 1] || s.to_s }
    shelf_sorts << {
      'dimension' => tok.call(ss.attributes['dimension-to-sort']),
      'measure'   => tok.call(ss.attributes['measure-to-sort-by']),
      'measure_raw' => ss.attributes['measure-to-sort-by'],
      'direction' => ss.attributes['direction'].to_s.downcase == 'desc' ? 'descending' : 'ascending',
      'shelf'     => ss.attributes['shelf']
    }
  end

  # v5.1: per-worksheet HEAT RAMP — the color encoding's sequential palette IS
  # the source heat scale (e.g. #f1f1f1→#52baee). Two serializations:
  # type='custom-interpolated' carries inline stops; type='interpolated'
  # references a named <preferences> palette (palette='CB_PuBu'). Emitted so
  # pivots derive backgroundScale from the source, never a default. NOT
  # neutral-stripped — a near-white low stop is legitimate.
  heat_scheme = nil
  ws.elements.each(".//encoding[@attr='color']") do |enc|
    case enc.attributes['type']
    when 'custom-interpolated'
      cols = []
      enc.elements.each('color-palette/color') { |c| cols << c.text.to_s.strip.downcase }
      heat_scheme = cols if cols.size >= 2
    when 'interpolated'
      pname = enc.attributes['palette'].to_s
      next if pname.empty? || heat_scheme
      body = TWB_TEXT[/<color-palette[^>]*name='#{Regexp.escape(pname)}'[^>]*type='ordered-(?:sequential|diverging)'[^>]*>(.*?)<\/color-palette>/m, 1]
      cols = body.to_s.scan(/#[0-9a-fA-F]{6}/).map(&:downcase)
      heat_scheme = cols if cols.size >= 2
    end
  end

  # PR-12: explicit per-series COLOR ASSIGNMENTS — the member→color map Tableau
  # serializes on the CATEGORICAL color encoding (type='palette'):
  #   <encoding attr='color' field='[fed].[none:Value Tier:nk]' type='palette'>
  #     <map to='#f2c037'><bucket>&quot;Top 500&quot;</bucket></map>
  # Captured in .twb document order, verbatim; ramp encodings (type=
  # '[custom-]interpolated', already surfaced as heat_scheme) are excluded —
  # their <map> buckets are numeric breakpoints, not series members. The
  # builder + theme derivation turn this into ORDERED schemes (ascending
  # member order = Sigma's positional category-sort application), which is
  # what kills the Top/Bottom-500 inversion class. No map ⇒ nil ⇒ the
  # frequency-ranked brand-palette derivation applies unchanged.
  series_colors = nil
  series_color_field = nil
  ws.elements.each(".//encoding[@attr='color']") do |enc|
    next if enc.attributes['type'].to_s =~ /interpolated/
    pairs = []
    enc.elements.each('map') do |mp|
      hex = mp.attributes['to'].to_s.strip.downcase
      next unless hex =~ /\A#[0-9a-f]{6}\z/
      bucket = mp.elements['bucket']
      member = bucket && unquote_member(bucket.text)
      next if member.nil? || member.empty?
      pairs << { 'member' => member, 'color' => hex }
    end
    next if pairs.empty?
    series_colors = pairs
    g = guid_from_param(enc.attributes['field'].to_s)
    info = g && COL_BY_GUID[g]
    series_color_field = (info && info[:caption]) || g
    break
  end

  worksheets[name] = {
    mark_class:       mark_class,
    geo_role:         geo_role,
    has_lat:          has_lat,
    has_long:         has_long,
    has_geometry:     has_geometry,
    sort:             sort_info,
    shelf_sorts:      shelf_sorts,
    quick_calc_pcto:  quick_calc_pcto,
    heat_scheme:      heat_scheme,
    # PR-12: explicit member→color assignments + the encoded column's caption
    series_colors:      series_colors,
    series_color_field: series_color_field,
    filters:          filters_info,
    hidden_filters:   hidden_filters,
    aggregations:     aggregations,
    channels:         channels,
    formats:          formats,
    calculations:     calcs,
    dual_axis:        dual_axis,
    measures:         measures.uniq { |m| m['column'] },
    ref_marks:        ref_marks,
    axis_formats:     axis_formats,
    mark_labels_show: mark_labels_show,
    rows_shelf:       rows_shelf,
    cols_shelf:       cols_shelf,
    is_crosstab:      is_crosstab,
    is_kpi:           is_kpi,
    # The source-displayed worksheet title → human element name (falls back to
    # the nickname when the title is default/absent). See worksheet_display_title.
    display_title:        worksheet_display_title(ws),
    # Phase-1 B3: KPI composite signals (nil unless a BAN scorecard label exists)
    kpi_label:            kpi_ban && kpi_ban['label'],
    kpi_value_font_size:  kpi_ban && kpi_ban['value_font_size'],
    kpi_annotation_runs:  kpi_ban && kpi_ban['annotation_runs']
  }
end

# ---- Tableau format → Sigma format translator -----------------------------
# PR-12: delegates to the shared lib/format_map.rb (the ONE translator — the
# builder's copy delegates there too, so the two can't drift again). Subset:
#   p0.0% / #,##0.0% → ,.1%      $#,##0.00 / C1033 → $,.2f (+currencySymbol)
#   #,##0 → ,.0f                 pos;(neg) → '(' paren-negative prefix
#   yyyy-MM-dd → %Y-%m-%d        MMM yyyy → %b %Y
# Date-times are d3-time/strftime strings ('%B %-d, %Y'); moment-style tokens
# ("MMM D, YYYY") print LITERALLY in Sigma, so FormatMap refuses (nil) any
# string it can't fully tokenize — unmapped formats are recorded downstream
# (formats-emitted.json), never guessed.
def translate_format(tableau_fmt)
  FormatMap.translate(tableau_fmt)
end

# Translate Tableau mark class + geo signals into a Sigma-relevant chart-kind label.
# Returns one of:
#   bar | line | area | pie | scatter | map-region | map-point |
#   pivot-table | table | automatic | other
#
# Pivot vs table detection (mark in {Text, Square}):
#   - Dims on BOTH rows AND cols shelves → "pivot-table" (Tableau crosstab)
#   - Measure-Names crosstab pattern     → "pivot-table"
#   - Otherwise                           → "table" (flat detail list)
# The `is_crosstab` flag set during worksheet parsing carries this decision.
#
# Notes:
#   - "Automatic" is Tableau's default-pick-for-the-encodings. It usually renders
#     as a bar in our experience but is not deterministic; we emit "automatic" so
#     the agent KNOWS to look at the PNG before committing to a Sigma kind.
#   - Geographic encoding presence beats mark class for map detection.
# Tableau "Show Me" picks a mark for an Automatic worksheet deterministically
# from the shelf structure. Replicate the high-value rules so an Automatic sheet
# isn't blindly defaulted to a bar (the #1 first-pass fidelity miss — a time
# series silently became bars). Conservative: only fires for mark=Automatic;
# anything it can't classify still falls back to bar (and gets image-confirmed
# downstream, since the kind was inferred not declared).
DATE_GRAIN_DERIV = %w[tyr tqr tmn twk tdy thr tmi tsc yr qr mn wk dy hr mi sc].freeze
def infer_automatic_kind(meta)
  rs = meta[:rows_shelf] || {}
  cs = meta[:cols_shelf] || {}
  fields = (rs['fields'] || []) + (cs['fields'] || [])
  dims = fields.select { |f| f['role'] == 'dim' }
  meas = fields.select { |f| f['role'] == 'measure' }
  # Only CONTINUOUS measures draw an axis (bar length / line value). A DISCRETE
  # measure (blue pill, type code `nk`) renders as a text cell — for chart-kind
  # inference it behaves like "no measure on the axis." (Zero-dim + a measure is
  # already claimed as a KPI upstream, so we only reach here for dim-bearing
  # sheets.)
  cont_meas = meas.reject { |f| f['discrete'] }
  has_date_dim = dims.any? { |f| DATE_GRAIN_DERIV.include?(f['derivation'].to_s.downcase) }
  has_measure_values = rs['has_measure_values'] || cs['has_measure_values']
  # 1) continuous date dimension + a continuous measure → time-series LINE
  return 'line' if has_date_dim && !cont_meas.empty?
  # 2) a continuous measure on BOTH axes (rows AND cols), ≤1 dim → SCATTER
  return 'scatter' if rs['cont_measure_count'].to_i >= 1 && cs['cont_measure_count'].to_i >= 1 && dims.size <= 1
  # 3) flat detail TABLE: dimension(s) present but NO continuous measure sits on
  #    an axis (measures live on the Marks/Text card, are DISCRETE blue pills, or
  #    the sheet is a pure dimension list) and no Measure-VALUES encoding pill. A
  #    bar needs a continuous measure axis; with none, Tableau's default
  #    "Automatic" mark renders a text grid, not bars — so route to a Sigma
  #    `table` instead of blindly defaulting to bar-chart. Rescues detail tables
  #    left on the default mark (never flipped to "Text"), including the discrete-
  #    measure-on-a-shelf idiom, which the Text/Square and crosstab/KPI
  #    heuristics above don't claim.
  return 'table' if !dims.empty? && cont_meas.empty? && !has_measure_values
  # 4) categorical dim(s) + continuous measure → BAR (Tableau's default)
  return 'bar' if !dims.empty? && !cont_meas.empty?
  'bar'
end

def chart_kind_for(meta)
  return nil unless meta
  mc       = (meta[:mark_class] || '').downcase
  has_xy   = meta[:has_lat] && meta[:has_long]
  geo_mark = %w[multipolygon polygon filled map].include?(mc)

  # Map detection — STRONG signals only. Semantic-role on a column alone is not
  # enough: a column with a geographic semantic-role on the datasource flows into
  # every worksheet that uses it, including KPIs, bar charts, etc. that aren't
  # maps. Only trust:
  #   1. Mark class is one of the explicit map marks (Multipolygon / Polygon /
  #      Filled / Map). Tableau sets these when the worksheet renders as a map.
  #   2. <geometry> element present in the worksheet — auto-generated for filled
  #      maps from named regions (state / country / etc.).
  #   3. Both Latitude and Longitude column references — a lat/long symbol map.
  return 'map-region' if geo_mark || meta[:has_geometry]
  return 'map-point'  if has_xy

  case mc
  when 'bar'        then 'bar'
  when 'line'       then 'line'
  when 'area'       then 'area'
  when 'pie'        then 'pie'
  when 'circle'     then (meta[:is_kpi] ? 'kpi' : 'scatter')  # BAN scorecard on a dot, else symbol=scatter
  when 'square'     then (meta[:is_crosstab] ? 'pivot-table' : (meta[:is_kpi] ? 'kpi' : 'table'))
  when 'text'       then (meta[:is_crosstab] ? 'pivot-table' : (meta[:is_kpi] ? 'kpi' : 'table'))
  when 'shape'      then (meta[:is_kpi] ? 'kpi' : 'scatter')  # big-number BAN, else symbol=scatter
  # Automatic is Tableau's default-pick — but a zero-dim single-measure sheet
  # under Automatic renders as a big-number text table, i.e. a KPI (bead 3w4d).
  when 'automatic'
    # An Automatic-mark sheet with the crosstab shape (Measure Names + dims) is
    # a text grid pivot — honor is_crosstab BEFORE the bar/KPI inference, else
    # the grouped headers + Grand Total are lost to a flat table (enterprise partner
    # tables). A measure on BOTH axes is unambiguously a scatter (not a
    # big-number KPI), so it overrides the zero-dim KPI heuristic; otherwise
    # zero-dim → KPI.
    if meta[:is_crosstab]
      'pivot-table'
    else
      inferred = infer_automatic_kind(meta)
      inferred == 'scatter' ? 'scatter' : (meta[:is_kpi] ? 'kpi' : inferred)
    end
  when ''           then (meta[:is_crosstab] ? 'pivot-table' : 'other')
  else 'other'
  end
end

# Map a Tableau zone `type-v2` (+ presence of a worksheet name) to our
# zone-level kind label. Shared by the flat-zone loop and the nested
# zone-tree builder so the two never diverge.
def zone_kind(type_v2, caption)
  case type_v2
  when 'layout-basic', 'layout-flow' then 'container'
  when 'text'                        then 'text'
  when 'title'                       then 'title'
  when 'filter'                      then 'filter'
  when 'paramctrl'                   then 'parameter'
  when 'color'                       then 'legend'
  when 'empty'                       then 'spacer'
  when 'bitmap'                      then 'image'
  when 'dashboard-object'            then 'dashboard-object'
  when nil
    # No type-v2 + a worksheet name → this is the chart tile
    caption ? 'chart' : 'container'
  else type_v2
  end
end

# Build a NESTED zone tree for a dashboard, preserving Tableau's container
# hierarchy (layout-basic / layout-flow, nested arbitrarily). Each node carries
# enough to drive a faithful Sigma container layout — kind, caption, bounds,
# flow direction (vert/horz for layout-flow), the resolved filter/param target
# column, and `children` (direct-child zones only). This is ADDITIVE: the flat
# `zones` list (below) is preserved for every downstream consumer that wants the
# geometry-banded path; the layout builder prefers the tree when present.
# ── Phase-1 style extraction (composition/style layer, gaps B2/D1/E1) ────────
# Tableau stores a dashboard zone's fill/border on the zone's DIRECT <zone-style>
# child (NOT a <style-rule element='dash-zone'> — that scope does not exist):
#   <zone …><zone-style>
#     <format attr='background-color' value='#RRGGBBAA'/>   ← region-card tint / canvas
#     <format attr='border-color' value='#hex'/> …
#   </zone-style></zone>
# Values may be 8-digit alpha hex (#rrggbbaa) — Sigma style.backgroundColor accepts
# them verbatim. Returns {} when the zone has no explicit styling (→ plain container,
# never worse than today's output). Verified against the "Job Loss from Mass
# Deportations" benchmark (region tints #07b4a2/#e8519a/#827bb8/#f28e2b at alpha).
# Full zone-style surface (official StyleAttribute-ST enum, twb XSD 2026.2):
# background, per-side borders, NATIVE rounded corners (Tableau 2026.1+ —
# reached here via the FCP normalization pass; previously invisible),
# margins/padding. Emitted keys are consumed by the layout/style compiler
# (container style.{backgroundColor,borderColor,borderWidth,borderRadius}).
def zone_style_fields(z)
  out = {}
  corners = {}
  z.elements.each('zone-style/format') do |f|
    a = f.attributes['attr']; v = f.attributes['value']
    next if v.nil? || v.empty?
    case a
    when 'background-color'
      out['fill_color'] = v unless v.downcase == '#00000000' # skip fully-transparent
    when 'background-transparency' then out['fill_transparency'] = v
    when 'border-color'  then out['border_color'] = v
    when 'border-style'  then out['border_style'] = v
    when 'border-width'  then out['border_width'] = v
    when /\Aborder-(color|style|width)-(top|right|bottom|left)\z/
      prop, side = Regexp.last_match(1), Regexp.last_match(2)
      ((out['border_sides'] ||= {})[side] ||= {})[prop] = (prop == 'width' ? v.to_i : v)
    when 'corner-radius' then out['corner_radius'] = v.to_i
    when /\Acorner-radius-(top|bottom)-(left|right)\z/
      corners[a.sub('corner-radius-', '')] = v.to_i
    when 'rounding' then out['rounding'] = v
    when /\Amargin(-top|-right|-bottom|-left)?\z/
      (out['margins'] ||= {})[a == 'margin' ? 'all' : a.sub('margin-', '')] = v.to_i
    when /\Apadding(-top|-right|-bottom|-left)?\z/
      (out['paddings'] ||= {})[a == 'padding' ? 'all' : a.sub('padding-', '')] = v.to_i
    end
  end
  out['corner_radii'] = corners unless corners.empty?
  # A per-corner-only spec still means "rounded" — surface the max as the
  # scalar so downstream style mapping needs one lookup.
  out['corner_radius'] ||= corners.values.max if corners.any?
  out
end

# Bitmap (image) zones: the design-compiler input for backgrounds/cards/art.
# `param` is the exact zip path inside the .twbx (e.g. 'Image/hero.png') →
# pixel-exact asset recovery; is-scaled/is-centered mirror the product's
# Fit/Center options; image-file-url carries web-hosted images. Shared by the
# flat-zone loop and build_zone_tree so the two never diverge.
# ---- Dashboard-object BUTTONS (v5.0-P2) ------------------------------------
# A Tableau button zone is <zone type-v2='dashboard-object'><button action=…>
# with <button-visual-state> children (caption/image-path/tooltip/font).
# Navigation targets are window-id GUIDs → resolve via //windows/window
# simple-id (census: all 21 corpus navigate targets are class='dashboard',
# i.e. 1:1 Sigma pages). Export/toggle buttons have no Sigma spec equivalent
# and become named residue downstream.
WINDOW_BY_UUID = {}
xml.elements.each('//windows/window') do |w|
  sid = w.elements['simple-id']
  WINDOW_BY_UUID[sid.attributes['uuid']] = {
    'name' => w.attributes['name'], 'class' => w.attributes['class']
  } if sid
end

def zone_button_fields(z)
  b = z.elements['button'] or return {}
  out = {}
  action = b.attributes['action'].to_s
  out['button_intent'] =
    if action =~ /goto-sheet/ then 'navigate'
    elsif b.elements['.//export-button-action'] || b.attributes['button-click-action-metadata']
      "export-#{b.attributes['button-click-action-metadata'] || 'image'}"
    elsif b.elements['.//toggle-action'] || action =~ /toggle/ then 'toggle'
    else 'unknown'
    end
  if out['button_intent'] == 'navigate' &&
     (g = action[/window-id="?\{([0-9A-Fa-f-]+)\}/, 1]) && (w = WINDOW_BY_UUID["{#{g}}"])
    out['button_nav_target']       = w['name']
    out['button_nav_target_class'] = w['class'] # 'dashboard' | 'worksheet'
  end
  cap = (c = b.elements['.//caption']) && c.text.to_s.strip
  # call-center carries the junk caption " ." — punctuation-only falls through
  out['button_caption'] = cap unless cap.nil? || cap.empty? || cap =~ /\A[.\s]+\z/
  out['button_tooltip']    = (t = b.elements['.//tooltip-text']) && t.text
  out['button_image_path'] = (ip = b.elements['.//image-path']) && ip.text
  out['button_type']       = b.attributes['button-type'] # 'text' | nil (image)
  if (f = b.elements['.//button-caption-font-style'])
    out['button_font_color'] = f.attributes['fontcolor']
    out['button_font_size']  = f.attributes['fontsize'] && f.attributes['fontsize'].to_i
  end
  out.reject { |_, v| v.nil? }
end

def zone_image_fields(z)
  a = z.attributes
  out = {
    'image_path'  => a['param'],
    'is_scaled'   => %w[1 true].include?(a['is-scaled'].to_s),
    'is_centered' => %w[1 true].include?(a['is-centered'].to_s)
  }
  out['image_file_url'] = a['image-file-url'] if a['image-file-url']
  out
end

# Tableau quick-filter / parameter display mode (zone `mode` attr) → E1 control-style
# hint. mode='compact' → dropdown (Sigma controlType:list); 'type_in' → text input;
# absent → default button/radio (Sigma segmented). Returns nil when unset.
def zone_control_display(z)
  m = z.attributes['mode']
  m && !m.empty? ? m : nil
end

# ── Phase-1 style extraction (B4: rich styled static text) ──────────────────
# A Tableau dashboard text/title zone carries its content as run-level formatted
# text — one <run> per style span:
#   <zone type-v2='text' …><formatted-text>
#     <run bold='true' fontcolor='#1b1b1b' fontsize='24'>Job Losses</run>
#     <run>Æ&#10;</run>                    ← U+00C6 line-break sentinel (+ newline)
#     <run fontcolor='#333333'>Estimating the job loss …</run>
#   </formatted-text></zone>
# Today the parser drops every one of these zones (they have no `name`, so
# `caption` is nil and no chart/worksheet backs them) — the subtitle, captions,
# credit line, and section headers vanish. This returns a structured
# `text_runs` array + `text_align` so the builder can re-emit them as styled
# Sigma `text` bodies (color/size spans, **bold**, paragraph breaks). Returns {}
# when the zone has no formatted text (→ unchanged behavior). Run attributes are
# lowercase 6-digit hex (`fontcolor`) and bare-integer points (`fontsize`);
# `bold` present only when bold. Verified against the "Job Loss from Mass
# Deportations" benchmark.
def zone_text_fields(z)
  ft = z.elements['formatted-text']
  return {} unless ft
  runs = []
  ft.elements.each('run') do |r|
    raw = r.text.to_s
    # U+00C6 (Æ) is Tableau's in-text line-break sentinel; the actual newline
    # rides alongside it as &#10;. Strip the sentinel; a run that then holds a
    # newline is a hard break, one that's whitespace-only is a spacer.
    txt = raw.gsub("Æ", '')
    a = r.attributes
    runs << {
      'text'      => txt,
      'color'     => (c = a['fontcolor']) && !c.empty? ? c : nil,
      'font_size' => (fs = a['fontsize']) && !fs.empty? ? fs.to_i : nil,
      'bold'      => a['bold'] == 'true',
      # v5.0 full run surface: family ('Roboto Light'), italic/underline, and
      # per-run alignment (fontalignment enum PNG-verified: 1=center 2=right;
      # absent/0=left). nil-compacted so absent attrs don't bloat every run.
      'font'      => (fn = a['fontname']) && !fn.empty? ? fn : nil,
      'italic'    => a['italic'] == 'true' || nil,
      'underline' => a['underline'] == 'true' || nil,
      'align'     => { '1' => 'center', '2' => 'right' }[a['fontalignment'].to_s],
      'break'     => txt.include?("\n")
    }.compact
  end
  return {} if runs.empty?
  out = { 'text_runs' => runs }
  # Alignment lives on the zone's <zone-style><format attr='text-align'>; default
  # (left) is Sigma's default and 400s if forced, so only carry center/right.
  z.elements.each('zone-style/format') do |f|
    if f.attributes['attr'] == 'text-align'
      v = f.attributes['value'].to_s
      out['text_align'] = v if %w[center right].include?(v)
    end
  end
  # Run-level alignment fallback: a zone whose alignment lives ONLY on its runs
  # (no zone-style text-align — the hero-art credit-line defect) still aligns:
  # when every visible run agrees, promote to the zone level.
  if out['text_align'].nil?
    vis = runs.reject { |r| r['text'].to_s.strip.empty? }
    aligns = vis.map { |r| r['align'] }.uniq
    out['text_align'] = aligns.first if vis.any? && aligns.size == 1 && %w[center right].include?(aligns.first)
  end
  # A short single-run zone with a solid fill reads as a pill/chip (e.g. a
  # "Learn More" button) — flag it so the builder can render a background chip.
  visible = runs.reject { |r| r['text'].to_s.strip.empty? }
  out['is_pill'] = true if visible.size == 1 && zone_style_fields(z)['fill_color']
  out
end

def build_zone_tree(z)
  type_v2 = z.attributes['type-v2']
  caption = z.attributes['name']
  param   = z.attributes['param']
  kind    = zone_kind(type_v2, caption)
  node = {
    'id'      => z.attributes['id'],
    'kind'    => kind,
    'caption' => caption,
    'x_pct'   => pct(z.attributes['x']),
    'y_pct'   => pct(z.attributes['y']),
    'w_pct'   => pct(z.attributes['w']),
    'h_pct'   => pct(z.attributes['h'])
  }
  # layout-flow's `param` is the stack direction; a vertical flow stacks its
  # children top-to-bottom (the classic left filter-rail), horizontal L→R.
  node['direction'] = (param == 'vert' ? 'vert' : 'horz') if type_v2 == 'layout-flow'
  # Fixed-pixel geometry: is-fixed zones size one axis in PIXELS (fixed-size),
  # not canvas-percent — px-fixed rails/dividers must map to exact grid spans.
  node['is_fixed']   = true if z.attributes['is-fixed'] == 'true'
  node['fixed_size'] = z.attributes['fixed-size'].to_i if z.attributes['fixed-size']
  # Bitmap zones: the design-compiler input for background/card/art images.
  # `param` is the exact zip path inside the .twbx (Image/<name>.png);
  # is-scaled/is-centered mirror the product's Fit/Center options and
  # image-file-url carries web-hosted images.
  if kind == 'image'
    node.merge!(zone_image_fields(z))
    # Full-canvas image = the Figma/PPT designed-background pattern (the
    # rounded "cards" live inside the PNG). Charts paint over it, so it maps
    # to a page/container backgroundImage, not a grid element.
    node['is_background'] = true if node['w_pct'] >= 95.0 && node['h_pct'] >= 95.0
  end
  # Phase-1 style: per-zone fill/border (region-card tints, canvas) + control mode.
  node.merge!(zone_style_fields(z))
  cd = zone_control_display(z)
  node['control_display'] = cd if cd
  # Phase-1 B4: styled static text (run-level formatting) on text/title zones.
  node.merge!(zone_text_fields(z)) if kind == 'text' || kind == 'title'
  # v5.0-P2: button payload on dashboard-object zones.
  node.merge!(zone_button_fields(z)) if kind == 'dashboard-object'
  # filter/param zones resolve their target column from `param` (a column GUID).
  if kind == 'filter' || kind == 'parameter'
    g = guid_from_param(param)
    info = g ? COL_BY_GUID[g] : nil
    node['filter_column_caption']  = info && info[:caption]
    node['filter_column_datatype'] = info && info[:datatype]
  end
  kids = []
  z.elements.each('zone') { |cz| next if cz.attributes['id'].nil?; kids << build_zone_tree(cz) }
  node['children'] = kids unless kids.empty?
  node
end

# ---- Native trellis detection (fix/native-trellis, SUPERSEDES #451 B1) ------
# A "trellis" is a Tableau dashboard that repeats the SAME viz across a
# categorical dimension as small multiples — authored as N sibling worksheets,
# each pinned to one member of the same field (the benchmark's 4 Ship-Method
# panels). The CORRECT Sigma shape for this is a SINGLE viz element carrying a
# native `trellis` property (rowsBy / columnsBy) — NOT N cloned chart elements.
# This detector identifies the repetition + the facet field + the source
# ARRANGEMENT; the builder (build-charts-from-signals) then collapses the N
# worksheets into ONE element and attaches trellis.rowsBy / columnsBy.
#
# Detection is deliberately CONSERVATIVE — it must NEVER fire on a non-trellis
# dashboard (that would change the byte-identical flat output). A group needs:
#   * >=3 sibling CHART zones (not KPI/table/pivot — those trellis differently),
#   * an identical viz template  (same chart_kind + same measure set),
#   * each carrying exactly the facet field as a single-member categorical
#     `list` filter, pinning DISTINCT members, and
#   * a tiled small-multiples geometry (a horizontal row, a vertical stack, or
#     a grid) — the arrangement decides rowsBy vs columnsBy.
# The native single-worksheet Tableau trellis (one sheet, dim on Rows/Cols) is
# NOT handled here — its member list isn't in the .twb, so the panel set can't
# be built offline (stays the existing UI-only WARN, F4).
TRELLIS_KINDS = %w[bar line area scatter pie donut map-region map-point].freeze

# [chart_kind, sorted-measure-columns] — two zones are the SAME viz template
# only when both match. nil when the zone plots no measure (can't be a facet).
def trellis_signature(z)
  ms = Array(z['measures']).map { |m| m['column'].to_s }.reject(&:empty?).sort
  return nil if ms.empty?
  [z['chart_kind'].to_s, ms]
end

# {field_key => {member, caption}} for each NON-action single-member categorical
# `list` filter on the zone — the candidate facet pins.
def trellis_facets(z)
  out = {}
  Array(z['filters']).each do |f|
    next unless f.is_a?(Hash)
    next if f['is_action']
    next unless f['kind'] == 'list'
    mems = Array(f['members'])
    next unless mems.size == 1
    dt = f['datatype'].to_s
    next unless dt.empty? || dt == 'string' || dt == 'nominal'
    key = (f['column_caption'] || f['column_guid'] || f['raw_param']).to_s
    next if key.empty?
    out[key] ||= { 'member' => mems.first.to_s, 'caption' => (f['column_caption'] || key).to_s }
  end
  out
end

# Small-multiples ARRANGEMENT of the member zones → the Sigma trellis axis.
#   * same top edge, spread across x  → 'cols' (a horizontal row of panels →
#     Sigma columnsBy, the common "cards across" look),
#   * same left edge, stacked down y  → 'rows' (a vertical stack of panels →
#     Sigma rowsBy, the "4 rows" small-multiples the owner showed),
#   * both x AND y vary               → 'grid' (a 2-D tile field).
# Returns nil when the zones aren't a disjoint tiling on either axis (so the
# group is NOT treated as a trellis — conservative). Heuristic: "aligned" on an
# axis means the min/max origin spread is within half the median tile size on
# that axis; the OTHER axis must be disjoint (ordered, non-overlapping tiles).
def trellis_arrangement(zs)
  return nil if zs.size < 2
  xs = zs.map { |z| z['x_pct'].to_f }
  ys = zs.map { |z| z['y_pct'].to_f }
  ws = zs.map { |z| z['w_pct'].to_f }.sort
  hs = zs.map { |z| z['h_pct'].to_f }.sort
  w_med = ws[ws.size / 2]
  h_med = hs[hs.size / 2]
  return nil unless w_med.positive? && h_med.positive?
  x_aligned = (xs.max - xs.min) <= 0.5 * w_med # shared left edge → a vertical stack
  y_aligned = (ys.max - ys.min) <= 0.5 * h_med # shared top edge  → a horizontal row
  disjoint = lambda do |spans|
    spans.sort_by(&:first).each_cons(2).all? { |a, b| a[1] <= b[0] + 1.0 }
  end
  x_spans = zs.map { |z| [z['x_pct'].to_f, z['x_pct'].to_f + z['w_pct'].to_f] }
  y_spans = zs.map { |z| [z['y_pct'].to_f, z['y_pct'].to_f + z['h_pct'].to_f] }
  if y_aligned && !x_aligned
    disjoint.call(x_spans) ? 'cols' : nil
  elsif x_aligned && !y_aligned
    disjoint.call(y_spans) ? 'rows' : nil
  elsif !x_aligned && !y_aligned
    'grid' # a 2-D field of tiles (x and y both vary)
  end
end

# Returns [] for a non-trellis dashboard (the common case) so the emitter can
# omit the key entirely and keep the flat output byte-identical. Each detected
# group carries the facet field, the ordered members / zone_ids / captions (the
# FIRST is the base worksheet the single trellis element is built from), the
# base chart_kind, and the source `orientation` (rows|cols|grid) → trellis axis.
def detect_trellis_groups(zones)
  charts = Array(zones).select { |z| z.is_a?(Hash) && z['kind'] == 'chart' && TRELLIS_KINDS.include?(z['chart_kind'].to_s) }
  return [] if charts.size < 3
  anno = charts.map do |z|
    sig = trellis_signature(z)
    next nil unless sig
    facets = trellis_facets(z)
    next nil if facets.empty?
    { 'z' => z, 'sig' => sig, 'facets' => facets }
  end.compact
  return [] if anno.size < 3
  groups = []
  used = {}
  anno.group_by { |a| a['sig'] }.each_value do |cohort|
    next if cohort.size < 3
    field_keys = cohort.flat_map { |a| a['facets'].keys }.uniq
    field_keys.each do |fk|
      seen = {}
      members = cohort.select do |a|
        next false unless a['facets'].key?(fk)
        next false if used[a['z']['id']]
        m = a['facets'][fk]['member']
        seen[m] ? false : (seen[m] = true) # distinct members only
      end
      next if members.size < 3
      orientation = trellis_arrangement(members.map { |a| a['z'] })
      next if orientation.nil? # not a tiled small-multiples layout
      ordered = members.sort_by { |a| a['facets'][fk]['member'].to_s.downcase }
      ordered.each { |a| used[a['z']['id']] = true }
      field_caption = ordered.first['facets'][fk]['caption']
      groups << {
        'field'       => field_caption,
        'chart_kind'  => ordered.first['sig'][0],
        'orientation' => orientation,
        'members'     => ordered.map { |a| a['facets'][fk]['member'] },
        'zone_ids'    => ordered.map { |a| a['z']['id'] },
        'captions'    => ordered.map { |a| a['z']['caption'] }
      }
    end
  end
  groups
end

dashboards = []
xml.elements.each('//dashboard') do |d|
  dash_name = d.attributes['name']
  # Zone-root id is the handle `--page` filters on.
  zone_root_id = (r = d.elements['zones']) ? r.attributes['id'] : nil
  next unless dashboard_in_scope?(dash_name, zone_root_id)
  zones = []
  seen_ids = {}
  # Iterate ONLY the dashboard's default <zones> tree. A bare `.//zone` also
  # descends into <devicelayouts> (phone/tablet variants carry their OWN zone
  # trees with different geometry) — contaminating the flat zone list with
  # duplicate-content zones at device-specific coordinates (official schema:
  # devicelayouts is a sibling of zones). Device layouts are a per-device
  # concern the desktop migration must not ingest.
  default_zones_root = d.elements['zones'] || d
  default_zones_root.elements.each('.//zone') do |z|
    next if z.attributes['id'].nil?
    next if seen_ids[z.attributes['id']]
    seen_ids[z.attributes['id']] = true

    type_v2  = z.attributes['type-v2']
    caption  = z.attributes['name']
    view_ref = z.attributes['param']

    # Translate Tableau zone type-v2 → our zone-level kind label
    kind = zone_kind(type_v2, caption)

    ws_meta    = caption ? worksheets[caption] : nil
    chart_kind = kind == 'chart' ? chart_kind_for(ws_meta) : nil
    # The chart kind was INFERRED from shelves (Tableau mark=Automatic), not
    # declared — flag it so the builder routes it to image confirmation.
    chart_kind_inferred = kind == 'chart' &&
                          ws_meta&.dig(:mark_class).to_s.downcase == 'automatic' &&
                          chart_kind != 'kpi'

    # Resolve filter-zone param GUID → column caption when this is a filter
    # zone, so downstream tools don't need to re-walk the .twb.
    if kind == 'filter' || kind == 'parameter'
      g = guid_from_param(view_ref)
      info = g ? COL_BY_GUID[g] : nil
      filter_col_caption  = info && info[:caption]
      filter_col_datatype = info && info[:datatype]
    end

    # Phase-1 style: per-zone fill/border (tints, canvas) + control display mode.
    zstyle = zone_style_fields(z)
    zdisp  = zone_control_display(z)
    # Phase-1 B4: styled static text (run-level formatting) on text/title zones.
    ztext  = (kind == 'text' || kind == 'title') ? zone_text_fields(z) : {}
    # Image zones: asset path + fit options (+ full-canvas background flag).
    zimg   = kind == 'image' ? zone_image_fields(z) : {}
    # Button payload (dashboard-object zones).
    zbtn   = kind == 'dashboard-object' ? zone_button_fields(z) : {}
    if kind == 'image' && pct(z.attributes['w']) >= 95.0 && pct(z.attributes['h']) >= 95.0
      zimg['is_background'] = true
    end

    zones << {
      'id'           => z.attributes['id'],
      'kind'         => kind,
      'caption'      => caption,
      'view_ref'     => view_ref,
      'x_pct'        => pct(z.attributes['x']),
      'y_pct'        => pct(z.attributes['y']),
      'w_pct'        => pct(z.attributes['w']),
      'h_pct'        => pct(z.attributes['h']),
      'chart_kind'   => chart_kind,
      'chart_kind_inferred' => chart_kind_inferred,
      # Source-displayed worksheet title → human element name (nil = use nickname).
      'display_title' => ws_meta&.dig(:display_title),
      'mark_class'   => ws_meta&.dig(:mark_class),
      'geo_role'     => ws_meta&.dig(:geo_role),
      # New per-worksheet signal fields (nil for non-chart zones)
      'sort'           => (kind == 'chart' ? ws_meta&.dig(:sort)           : nil),
      'shelf_sorts'    => (kind == 'chart' ? ws_meta&.dig(:shelf_sorts)   : nil),
      'quick_calc_pcto' => (kind == 'chart' ? ws_meta&.dig(:quick_calc_pcto) : nil),
      'heat_scheme'    => (kind == 'chart' ? ws_meta&.dig(:heat_scheme)   : nil),
      # PR-12: explicit member→color map (nil = no assignment; keep palette derivation)
      'series_colors'      => (kind == 'chart' ? ws_meta&.dig(:series_colors)      : nil),
      'series_color_field' => (kind == 'chart' ? ws_meta&.dig(:series_color_field) : nil),
      # v5.1: zone show-title='false' = the source HIDES the worksheet title
      # (all 6 hero-art workbook tiles carry it; three rounds leaked "Sheet 9" because
      # nothing read the attribute). Absent attr = shown (fails safe).
      'show_title'   => z.attributes['show-title'] != 'false',
      'filters'        => (kind == 'chart' ? ws_meta&.dig(:filters)       : nil),
      'hidden_filters' => (kind == 'chart' ? (ws_meta&.dig(:hidden_filters) || []) : nil),
      'aggregations'   => (kind == 'chart' ? ws_meta&.dig(:aggregations)  : nil),
      'channels'     => (kind == 'chart' ? ws_meta&.dig(:channels)      : nil),
      'formats'      => (kind == 'chart' ? ws_meta&.dig(:formats)       : nil),
      'calculations' => (kind == 'chart' ? ws_meta&.dig(:calculations)  : nil),
      'dual_axis'    => (kind == 'chart' ? ws_meta&.dig(:dual_axis)     : nil),
      'measures'     => (kind == 'chart' ? ws_meta&.dig(:measures)      : nil),
      'ref_marks'    => (kind == 'chart' ? ws_meta&.dig(:ref_marks)     : nil),
      'axis_formats' => (kind == 'chart' ? ws_meta&.dig(:axis_formats)  : nil),
      'mark_labels_show' => (kind == 'chart' ? ws_meta&.dig(:mark_labels_show) : nil),
      'rows_shelf'   => (kind == 'chart' ? ws_meta&.dig(:rows_shelf)    : nil),
      'cols_shelf'   => (kind == 'chart' ? ws_meta&.dig(:cols_shelf)    : nil),
      'is_crosstab'  => (kind == 'chart' ? ws_meta&.dig(:is_crosstab)   : nil),
      'is_kpi'       => (kind == 'chart' ? ws_meta&.dig(:is_kpi)        : nil),
      # Phase-1 B3: KPI composite signals (nil unless a BAN scorecard)
      'kpi_label'           => (kind == 'chart' ? ws_meta&.dig(:kpi_label)           : nil),
      'kpi_value_font_size' => (kind == 'chart' ? ws_meta&.dig(:kpi_value_font_size) : nil),
      'kpi_annotation_runs' => (kind == 'chart' ? ws_meta&.dig(:kpi_annotation_runs) : nil),
      # Resolved filter target (filter/parameter zones only)
      'filter_column_caption'  => (kind == 'filter' || kind == 'parameter' ? filter_col_caption  : nil),
      'filter_column_datatype' => (kind == 'filter' || kind == 'parameter' ? filter_col_datatype : nil),
      # Phase-1 composition/style signals (gaps B2/E1; nil when the zone is unstyled)
      'fill_color'      => zstyle['fill_color'],
      'border_color'    => zstyle['border_color'],
      'control_display' => zdisp,
      # Phase-1 B4: styled static text signals (nil for non-text zones / unstyled)
      'text_runs'  => ztext['text_runs'],
      'text_align' => ztext['text_align'],
      'is_pill'    => ztext['is_pill'],
      # v5.0 design-compiler signals (nil when absent — additive)
      'corner_radius' => zstyle['corner_radius'],
      'border_width'  => zstyle['border_width'],
      'is_fixed'      => (z.attributes['is-fixed'] == 'true' || nil),
      'fixed_size'    => (z.attributes['fixed-size'] ? z.attributes['fixed-size'].to_i : nil),
      # Image (bitmap) zone signals: .twbx asset path + fit + background flag
      'image_path'     => zimg['image_path'],
      'is_scaled'      => (kind == 'image' ? zimg['is_scaled']   : nil),
      'is_centered'    => (kind == 'image' ? zimg['is_centered'] : nil),
      'image_file_url' => zimg['image_file_url'],
      'is_background'  => zimg['is_background'],
      # Button signals (dashboard-object zones; nil elsewhere)
      'button_intent'           => zbtn['button_intent'],
      'button_nav_target'       => zbtn['button_nav_target'],
      'button_nav_target_class' => zbtn['button_nav_target_class'],
      'button_caption'          => zbtn['button_caption'],
      'button_tooltip'          => zbtn['button_tooltip'],
      'button_image_path'       => zbtn['button_image_path'],
      'button_type'             => zbtn['button_type'],
      'button_font_color'       => zbtn['button_font_color'],
      'button_font_size'        => zbtn['button_font_size']
    }
  end
  # A "storyboard" dashboard is Tableau's story container (sequential story
  # points in a flipboard zone) — flag it so downstream layout builders don't
  # treat the flipboard chrome as a regular chart page. The story itself is
  # parsed into story-plan.json below (beads-sigma-y6b).
  is_story = d.attributes['type-v2'] == 'storyboard' || !d.elements['.//story-points'].nil?
  # Nested container tree (additive — see build_zone_tree). Walk the direct
  # children of the dashboard's <zones> root so nesting is preserved.
  zone_tree = []
  if (root = d.elements['zones'])
    root.elements.each('zone') { |z| next if z.attributes['id'].nil?; zone_tree << build_zone_tree(z) }
  end

  # Authored canvas size in PIXELS (dashboard <size> maxwidth/maxheight;
  # sizing-mode=fixed means these are exact). The px density is what makes
  # fixed-size zone spans and row-height math exact downstream.
  canvas_px = nil
  if (sz = d.elements['size'])
    w_px = sz.attributes['maxwidth'].to_i
    h_px = sz.attributes['maxheight'].to_i
    if w_px.positive? && h_px.positive?
      canvas_px = { 'w' => w_px, 'h' => h_px,
                    'sizing_mode' => sz.attributes['sizing-mode'] }
    end
  end

  dash_h = {
    'dashboard'     => d.attributes['name'],
    'is_story'      => is_story,
    'canvas_px'     => canvas_px,
    # Theme channel: this dashboard's Format▸Dashboard rules + the workbook's
    # Format▸Workbook rules (lib/theme_derive resolves precedence).
    'style_rules'   => { 'workbook' => WORKBOOK_STYLE_RULES,
                         'dashboard' => style_rules_for(d) },
    'zones'         => zones,
    'zone_tree'     => zone_tree,
    # Phase-1 D1 (general): workbook brand palette from color encodings, so
    # derive_theme can reproduce the source's own scheme instead of falling
    # back to white card fills. Empty when the source encodes no non-neutral
    # colors (theme then omitted — Sigma defaults apply, never worse).
    'brand_palette' => BRAND_PALETTE
  }
  # Native trellis: attach the detected groups ONLY when a trellis is present,
  # so every non-trellis dashboard's JSON is byte-identical to the flat build.
  # The builder collapses each group into ONE element with a native `trellis`
  # property; the layout stage prunes the absorbed sibling zones (both gated on
  # this key).
  trellis_groups = detect_trellis_groups(zones)
  dash_h['trellis'] = trellis_groups unless trellis_groups.empty?
  dashboards << dash_h
end

# Sheet-only workbooks (no <dashboard> blocks — just standalone worksheets)
# still need a zone list so downstream build-charts-from-signals can match
# Sigma chart-elements to Tableau views. Emit a synthetic dashboard per
# worksheet so the parser output looks normal to the build script.
if dashboards.empty? && !worksheets.empty?
  worksheets.each_key do |ws_name|
    # In a sheet-only workbook the worksheet IS the page, so `--dashboard`
    # filters on the worksheet name (zone-root id n/a → nil).
    next unless dashboard_in_scope?(ws_name, nil)
    ws_meta    = worksheets[ws_name]
    chart_kind = chart_kind_for(ws_meta)
    dashboards << {
      'dashboard' => "[synthetic] #{ws_name}",
      # Sheet-only workbooks still carry workbook-level Format▸Workbook rules
      # + encoded brand colors (theme channel); no dashboard scope exists.
      'style_rules'   => { 'workbook' => WORKBOOK_STYLE_RULES, 'dashboard' => {} },
      'brand_palette' => BRAND_PALETTE,
      'canvas_px'     => nil,
      'zones'     => [{
        'id'           => '1',
        'kind'         => 'chart',
        'caption'      => ws_name,
        'view_ref'     => nil,
        'x_pct'        => 0.0,
        'y_pct'        => 0.0,
        'w_pct'        => 100.0,
        'h_pct'        => 100.0,
        'chart_kind'     => chart_kind,
        'mark_class'     => ws_meta[:mark_class],
        'geo_role'       => ws_meta[:geo_role],
        'sort'           => ws_meta[:sort],
        'shelf_sorts'    => ws_meta[:shelf_sorts],
        'quick_calc_pcto' => ws_meta[:quick_calc_pcto],
        'series_colors'      => ws_meta[:series_colors],
        'series_color_field' => ws_meta[:series_color_field],
        'filters'        => ws_meta[:filters],
        'hidden_filters' => ws_meta[:hidden_filters] || [],
        'aggregations'   => ws_meta[:aggregations],
        'channels'     => ws_meta[:channels],
        'formats'      => ws_meta[:formats],
        'calculations' => ws_meta[:calculations],
        'dual_axis'    => ws_meta[:dual_axis],
        'measures'     => ws_meta[:measures],
        'ref_marks'    => ws_meta[:ref_marks],
        'axis_formats' => ws_meta[:axis_formats],
        'mark_labels_show' => ws_meta[:mark_labels_show],
        'rows_shelf'   => ws_meta[:rows_shelf],
        'cols_shelf'   => ws_meta[:cols_shelf],
        'is_crosstab'  => ws_meta[:is_crosstab],
        'is_kpi'       => ws_meta[:is_kpi],
        'kpi_label'           => ws_meta[:kpi_label],
        'kpi_value_font_size' => ws_meta[:kpi_value_font_size],
        'kpi_annotation_runs' => ws_meta[:kpi_annotation_runs],
        'filter_column_caption'  => nil,
        'filter_column_datatype' => nil
      }]
    }
  end
end

def unquote_value(s)
  s = s.to_s.gsub('&quot;', '"')
  s.sub(/^"/, '').sub(/"$/, '')
end

## ---- Tableau column aliases -----------------------------------------------
# Columns can carry per-value aliases that override the raw warehouse value
# with a friendly display label. Pattern:
#   <column caption='Region' name='[Region]' ...>
#     <aliases>
#       <alias key='"N"' value='North' />
#       <alias key='"S"' value='South' />
#     </aliases>
#   </column>
# We skip the Tableau-internal `[:Measure Names]` pseudo-column and any aliases
# whose key references an internal federated id (those map field-ids to display
# strings, not data values — agent needs to wire those by hand).
column_aliases = {}
xml.elements.each('//column') do |col|
  raw_name = col.attributes['name'].to_s
  next if raw_name == '[:Measure Names]' || raw_name.empty?
  # Caption is the human-facing column name; fall back to the bracketed `name`
  # (with brackets stripped) when caption isn't set — Tableau leaves caption
  # empty for columns whose name IS already display-friendly (e.g., `[Metric]`).
  cap = col.attributes['caption']
  cap = raw_name.gsub(/^\[|\]$/, '') if cap.nil? || cap.empty?
  next if cap.empty?
  pairs = []
  col.each_element('aliases/alias') do |a|
    k = unquote_value(a.attributes['key'])
    v = a.attributes['value']
    next if k.nil? || v.nil? || v.empty?
    # Drop internal-id keys (federated.* / [usr:foo] / [sum:foo] / [ctd:foo]).
    next if k =~ /^\[(?:federated|usr|sum|ctd|min|max|avg|none):/i
    next if k =~ /^\[[\w-]+\]\.\[/  # e.g., [Sample.csv].[usr:Calc...:qk]
    pairs << { 'key' => k, 'value' => v }
  end
  next if pairs.empty?
  # Keep the richest alias set per caption (a column may appear in multiple
  # datasource blocks — keep the one with the most pairs).
  existing = column_aliases[cap]
  column_aliases[cap] = pairs if existing.nil? || pairs.size > existing.size
end

## ---- Tableau parameters ---------------------------------------------------
# Parameters live as <column param-domain-type='list|range'> inside any
# datasource (Tableau's "Parameters" datasource for global ones, or inside a
# real datasource for legacy local params). Each has:
#   - caption        (display name)
#   - datatype       (integer | real | string | date | datetime | boolean)
#   - param_domain   ('list' | 'range' | 'any')
#   - default_value  (value attribute, raw — may be quoted)
#   - members        [{ value }] when param_domain='list'
#   - min/max/step   when param_domain='range'
# Sigma maps these to: segmented/list control (list), number/range-slider
# control (range numeric), date-range control (range date).
parameters = []
xml.elements.each("//column[@param-domain-type]") do |col|
  raw_name = col.attributes['name'].to_s
  caption  = col.attributes['caption'] || raw_name.gsub(/^\[|\]$/, '')
  members  = []
  col.each_element('.//members/member') do |m|
    members << unquote_value(m.attributes['value'])
  end
  rng = col.elements['range']
  parameters << {
    'name'          => raw_name,
    'caption'       => caption,
    'datatype'      => col.attributes['datatype'],
    'param_domain'  => col.attributes['param-domain-type'],
    'default_value' => unquote_value(col.attributes['value']),
    'members'       => members,
    'min'           => rng && rng.attributes['min'],
    'max'           => rng && rng.attributes['max'],
    'step'          => rng && rng.attributes['granularity']
  }
end

# A global parameter is redeclared in EVERY worksheet's embedded
# datasource-dependencies — so the raw scan finds the same `[Parameter N]`
# hundreds of times (enterprise: 604 declarations for ~50 params), and the COPIES
# carry empty <members> while the canonical Parameters-datasource declaration
# carries the real domain. Dedup by internal NAME, keeping the richest entry
# (most members; tie-break on a non-empty default). Without this the meta is
# bloated AND a downstream consumer that takes the first-seen declaration can
# land on an empty-members copy and emit a domainless control.
parameters = parameters
  .group_by { |p| p['name'] }
  .map do |_name, dups|
    dups.max_by { |p| [(p['members'] || []).size, p['default_value'].to_s.empty? ? 0 : 1] }
  end

# Detect which worksheet calcs reference a parameter so the build script knows
# which calcs to translate via Switch(). A calc references a parameter when its
# formula contains `[Parameters].[X]` OR a bare `[X]` matching a known param.
#
# X may be the parameter's CAPTION ("Switch Metric") or its internal NAME
# ("[Parameter 5]") depending on the .twb version. The auto-control builder keys
# its orphan check on the caption, so a calc that references a param by name was
# previously misflagged "orphan parameter" and its control silently skipped.
# Resolve every ref — by name or caption — to the canonical caption so the
# builder sees the param as referenced.
param_caption_to_caption = {}
parameters.each do |p|
  cap = p['caption']
  next if cap.nil? || cap.to_s.empty?
  param_caption_to_caption[cap] = cap
  nm = p['name'].to_s.gsub(/^\[|\]$/, '')
  param_caption_to_caption[nm] = cap unless nm.empty?
end
worksheets.each do |_ws_name, w|
  next unless w[:calculations]
  w[:calculations].each do |c|
    f = c['formula'].to_s
    refs = []
    # Explicit `[Parameters].[X]` references — X may be name or caption.
    f.scan(/\[Parameters?(?:\s*\([^)]*\))?\]\s*\.\s*\[([^\]]+)\]/i).flatten.each do |x|
      refs << (param_caption_to_caption[x] || x)
    end
    # Bare bracket-refs that resolve to a known parameter (by name or caption).
    f.scan(/\[([^\]\/]+)\]/).flatten.each do |x|
      refs << param_caption_to_caption[x] if param_caption_to_caption.key?(x)
    end
    c['parameter_refs'] = refs.uniq unless refs.empty?
  end
end

## ---- Shared-view (workbook-level) filters ---------------------------------
# Tableau emits dashboard / cross-sheet filters in <shared-view> blocks at the
# workbook level. These apply to every worksheet that uses the same datasource.
# Parsing here means a page-per-worksheet builder can auto-emit Sigma controls
# for them without the agent supplying any config.
shared_filters = []
# Datasource names — a shared-view named after a datasource hosts that
# datasource's always-on (data-source-level) filters, not dashboard quick
# filters. Virtual-connection / published-datasource filters live here rather
# than under a top-level <datasource> (which the D2/P0.2 walk below covers), so
# without this tag they were misread as toggleable quick-filters and silently
# widened/dropped (#483).
ds_names = []
xml.elements.each('/workbook/datasources/datasource') do |ds|
  n = ds.attributes['name'].to_s
  ds_names << n unless n.empty?
end
xml.elements.each('//shared-view') do |sv|
  sv_name = sv.attributes['name']
  sv.elements.each('filter') do |f|
    spec = normalize_filter(f)
    spec['shared_view'] = sv_name
    # #483: a shared-view filter is a DATA-SOURCE (always-on) filter — invisible
    # on every dashboard surface, so the Phase-1d PNG read can never catch a
    # miss — when its enumeration is database-domain scoped OR the shared-view is
    # named after a datasource. Tag it so build-charts records it and the
    # datasource-filter gate blocks GREEN unless it was applied. Genuine
    # dashboard quick-filters (no database domain, shared-view not a datasource
    # name) stay untagged and flow through the normal auto-control path.
    spec['is_datasource_filter'] = true if spec['ui_domain'] == 'database' || ds_names.include?(sv_name)
    shared_filters << spec
  end
end

## ---- Datasource-level + extract filters (D2/P0.2) --------------------------
# Tableau row-scopes a whole datasource with <filter> children of <datasource>
# (Data Source Filters — users "can't see or modify" them) and of its
# <extract> (rows removed at extract time). NO other walk sees them — the
# worksheet walk is worksheet-scoped and shared filters live in <shared-view>
# — so every sheet silently over-reported. Normalize them with the SAME shapes
# as worksheet filters and ship them in the meta sidecar; build-charts applies
# them as element filters on every element sourcing that datasource.
datasource_filters = []
xml.elements.each('/workbook/datasources/datasource') do |ds|
  ds_label = (ds.attributes['caption'] || ds.attributes['name']).to_s
  ds_name  = ds.attributes['name'].to_s
  next if ds_label.start_with?('Parameter')
  { 'filter' => 'datasource', 'extract/filter' => 'extract' }.each do |xpath, scope|
    ds.elements.each(xpath) do |f|
      spec = normalize_filter(f)
      spec['datasource']      = ds_label
      spec['datasource_name'] = ds_name
      spec['filter_scope']    = scope
      datasource_filters << spec
    end
  end
end

## ---- Tableau stories (story points) ----------------------------------------
# A Tableau story is a sequential slide deck: each <story-point> captures a
# dashboard or worksheet plus a navigator caption. XML shapes in the wild:
#   <story name='X'> ... <flipboard><story-points><story-point .../>   (older)
#   <dashboard name='X' type-v2='storyboard'> ... same flipboard tree  (newer)
# We match on //story-points so both shapes parse, and resolve each point's
# captured-sheet against the dashboard/worksheet name sets so the downstream
# builder (scripts/build-story-pages.rb) knows whether the point's Sigma page
# clones a whole dashboard page or a single worksheet element. Output:
# story-plan.json in the same directory as OUT (only when stories exist).
# beads-sigma-y6b.
stories = []
dashboard_names = dashboards.map { |d| d['dashboard'] }
xml.elements.each('//story-points') do |spn|
  # Enclosing story container = nearest ancestor carrying a name attribute
  # (<story name=...> or <dashboard name=... type-v2='storyboard'>).
  story_name = nil
  anc = spn.parent
  while anc
    nm = anc.respond_to?(:attributes) && anc.attributes ? anc.attributes['name'] : nil
    unless nm.to_s.empty?
      story_name = nm
      break
    end
    anc = anc.respond_to?(:parent) ? anc.parent : nil
  end
  points = []
  spn.elements.each('story-point') do |sp|
    a = sp.attributes
    cap = a['caption']
    cap = sp.elements['caption'].text if (cap.nil? || cap.to_s.empty?) && sp.elements['caption']
    captured = a['captured-sheet']
    kind = if captured.nil?                          then 'unknown'
           elsif dashboard_names.include?(captured)  then 'dashboard'
           elsif worksheets.key?(captured)           then 'worksheet'
           else 'unknown'
           end
    points << {
      'id'             => a['id'],
      'caption'        => cap,
      'captured_sheet' => captured,
      'sheet_kind'     => kind
    }
  end
  next if points.empty?
  stories << { 'story' => story_name, 'points' => points }
end
unless stories.empty?
  story_plan_path = File.join(File.dirname(File.expand_path(OUT)), 'story-plan.json')
  File.write(story_plan_path, JSON.pretty_generate(stories))
  puts "wrote #{story_plan_path} (#{stories.size} story(ies), " \
       "#{stories.sum { |st| st['points'].size }} story point(s)) — " \
       'run scripts/build-story-pages.rb to emit one Sigma page per story point'
end

# When per-dashboard scoping is active, narrow the meta worksheets/shared_filters
# to only what the in-scope dashboard(s) actually use, so a single-tab build
# doesn't drag the whole workbook's worksheet metadata along. Worksheets are
# referenced by a chart zone's `caption`; shared_filters are kept when their
# resolved column_caption is filtered by an in-scope worksheet (conservative —
# keep any whose column is referenced, plus all when we can't tell).
scoped_worksheets = worksheets
scoped_shared_filters = shared_filters
if dashboard_scoping?
  used_captions = {}
  dashboards.each do |d|
    d['zones'].each do |z|
      cap = z['caption']
      used_captions[cap] = true if cap && worksheets.key?(cap)
    end
  end
  scoped_worksheets = worksheets.select { |name, _| used_captions[name] }
  # Shared filters apply workbook-wide; keep those whose target column is filtered
  # by an in-scope worksheet (matched on column_caption), so the auto-control
  # builder still surfaces the relevant dashboard filters without the full set.
  used_filter_captions = {}
  scoped_worksheets.each_value do |w|
    (w[:filters] || []).each do |f|
      c = f['column_caption']
      used_filter_captions[c] = true if c
    end
  end
  scoped_shared_filters = shared_filters.select do |f|
    c = f['column_caption']
    c.nil? || used_filter_captions[c]
  end
end

meta = {
  'worksheets'     => scoped_worksheets.transform_values { |v| v.transform_keys(&:to_s) },
  'stories'        => stories,
  'shared_filters' => scoped_shared_filters,
  # Datasource/extract filters are workbook-global row scoping — never narrowed
  # by dashboard scoping (they apply to every sheet on the datasource).
  'datasource_filters' => datasource_filters,
  'parameters'     => parameters,
  'column_aliases' => column_aliases,
  # PR-12: per-column default number/date formats (caption → raw Tableau
  # format string). build-charts-from-signals maps them to Sigma column/KPI
  # formats (lib/format_map) when no worksheet-level pill format overrides.
  'column_formats' => COLUMN_FORMATS,
  'columns_by_guid'=> COL_BY_GUID.transform_values { |v|
    h = { 'caption' => v[:caption], 'datatype' => v[:datatype] }
    h['formula'] = v[:formula] if v[:formula] # calc-ref deref (v5.1.1)
    h
  }
}
META_OUT = OUT.sub(/\.json$/, '-meta.json')
File.write(META_OUT, JSON.pretty_generate(meta))
scope_note = dashboard_scoping? ? " [scoped: #{(DASHBOARD_FILTERS + PAGE_FILTERS).join(', ')}]" : ''
puts "wrote #{META_OUT} (#{meta['worksheets'].size} worksheets, #{meta['shared_filters'].size} shared filters)#{scope_note}"

File.write(OUT, JSON.pretty_generate(dashboards))
puts "wrote #{OUT} (#{dashboards.size} dashboards, #{dashboards.sum { |d| d['zones'].size }} zones total)"
dashboards.each do |d|
  puts "  [#{d['dashboard']}]"
  d['zones'].each do |z|
    next if z['kind'] == 'container' && z['caption'].nil?
    cap = z['caption'] || '(no caption)'
    extras = []
    extras << "chart_kind=#{z['chart_kind']}" if z['chart_kind']
    extras << "mark=#{z['mark_class']}"        if z['mark_class']
    extras << "geo=#{z['geo_role']}"           if z['geo_role']
    pos = "x=#{z['x_pct']}% y=#{z['y_pct']}% w=#{z['w_pct']}% h=#{z['h_pct']}%"
    puts "    #{z['kind'].ljust(8)} #{cap.to_s[0..38].ljust(40)} #{pos.ljust(45)} #{extras.join(' ')}"
  end
end
