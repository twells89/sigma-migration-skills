#!/usr/bin/env ruby
# ── VENDORED (do not edit here) ──────────────────────────────────────────────
# Source: twells89/sigma-migration-skills @ a73f833
#   plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-workbook-spec.rb
# Fix upstream and re-vendor; do not diverge this copy. Vendored for the
# standalone domo-sigma-migration repo (clone-safety) per the domo-build-pipeline plan.
# ─────────────────────────────────────────────────────────────────────────────
# Assemble a complete Sigma workbook spec from build-charts-from-signals
# output + DM IDs + a master-columns config. Replaces the per-conversion
# hand-written assemble-*.py one-offs that crept in during dashboard-mode
# conversions.
#
# Usage:
#   ruby scripts/build-workbook-spec.rb \
#     --chart-specs /tmp/<name>/chart-specs.json    # build-charts-from-signals output
#     --dm-ids      /tmp/<name>/dm-ids.json         # post-and-readback output for the DM
#     --master-cols /tmp/<name>/master-columns.yaml # see schema below
#     --workbook-name "<name>"
#     --description "<one-liner>"
#     --folder-id   <uuid>
#     [--mode dashboard|page-per-worksheet]         # default: page-per-worksheet
#     [--dm-element-name "Order Fact"]              # which DM element the master sources from (default: first non-Date)
#     [--layout /tmp/<name>/dashboard-layout.json]  # parse-twb-layout output — derives themeName + themeOverrides
#                                                    #   (backgroundCanvas from the page fill; categoricalScheme
#                                                    #   from the tinted region-card palette). Omit → no theme.
#     --out /tmp/<name>/wb-spec.json
#
# --master-cols schema (YAML):
#   columns:
#     - { id: m-order-id,      name: "Order Id",       formula: "[Order Fact/Order Id]" }
#     - { id: m-order-date,    name: "Order Date",     formula: "[Order Fact/Order Date]" }
#     - { id: m-gross-revenue, name: "Gross Revenue",  formula: "[Order Fact/Gross Revenue]" }
#     ...
#
# Or omit --master-cols entirely: the script will auto-build a master that
# passes through every column of the named DM element by name. Suitable for
# small workbooks; for complex masters with renames or Lookup columns, supply
# the YAML explicitly.

require 'json'
require 'set'
require 'yaml'
require 'optparse'
require 'net/http'
require 'uri'
require 'base64'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'code_rep'
require 'layout'

def sigma_color_overrides(background_canvas)
  [{ 'name' => 'backgroundCanvas', 'color' => background_canvas }]
end

opts = { mode: 'page-per-worksheet' }
OptionParser.new do |p|
  p.on('--chart-specs PATH')    { |v| opts[:specs] = v }
  p.on('--dm-ids PATH')         { |v| opts[:dm_ids] = v }
  p.on('--master-cols PATH')    { |v| opts[:master_cols] = v }
  p.on('--workbook-name S')     { |v| opts[:name] = v }
  p.on('--description S')       { |v| opts[:description] = v }
  p.on('--folder-id S')         { |v| opts[:folder_id] = v }
  p.on('--mode S')              { |v| opts[:mode] = v }
  p.on('--dm-element-name S')   { |v| opts[:dm_el_name] = v }
  p.on('--layout PATH', 'parse-twb-layout output — used to derive workbook theme (canvas + region palette)') { |v| opts[:layout] = v }
  p.on('--out PATH')            { |v| opts[:out] = v }
end.parse!
%i[specs dm_ids name folder_id out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }
abort("--mode must be dashboard or page-per-worksheet") unless %w[dashboard page-per-worksheet].include?(opts[:mode])

specs   = JSON.parse(File.read(opts[:specs]))
dm_ids  = JSON.parse(File.read(opts[:dm_ids]))

dm_id = dm_ids['dataModelId'] || abort('dm-ids.json missing dataModelId')

# Find the DM element to source the master from. Default heuristic: pick the
# first element whose name doesn't start with a dimension-table prefix
# (Date Dim / Customer Dim / etc.). User can override via --dm-element-name.
dm_elements = (dm_ids['pages'] || []).flat_map { |p| p['elements'] || [] }
abort('no elements in dm-ids') if dm_elements.empty?
target = if opts[:dm_el_name]
           dm_elements.find { |e| e['name'] == opts[:dm_el_name] } ||
             abort("no DM element named #{opts[:dm_el_name].inspect}")
         else
           # First non-dim-suffixed element, but only among elements that actually
           # carry columns. The readback exposes columns via 'columnLabels'; an
           # extract-landed (or multi-datasource) DM has NAMELESS master-shell
           # elements with ZERO columns that must NOT be chosen — picking one
           # aborts at 'no master columns to emit'. Skipping empty shells keeps
           # the original "first non-dim" order for normal single-fact DMs.
           width = ->(e) { (e['columnLabels'] || e['columns'] || []).size }
           bearing = dm_elements.select { |e| width.call(e).positive? }
           bearing = dm_elements if bearing.empty?
           # PREFER the element build-workbook.rb identified as the DOMINANT
           # dataset's. Falling straight through to "first non-Dim" is only
           # correct when the dominant dataset happens to be the data model's
           # first element — true for the single-fact Orders pages, FALSE on a
           # real multi-dataset page. Measured on the 36-card cold run: Master
           # bound to PDP_EXAMPLE_DATASET (element 0, 11 columns) while the
           # dominant dataset was SALESFORCE (element 7, 15 columns), and there
           # was no sub-master for SALESFORCE because it was supposed to BE the
           # Master. That is a SILENT wrong-data bug, not just a 400: it only
           # errored on a column name absent from PDP ('Close Date'); every
           # card referencing a name present in BOTH tables would have POSTed
           # fine and rendered the wrong table's numbers. Bead 0ku5.
           dominant_id = specs['dominant_dm_element_id']
           dominant = dominant_id && bearing.find { |e| e['id'] == dominant_id }
           if dominant_id && !dominant
             warn "  ⚠ chart-specs names DM element #{dominant_id.inspect} as the dominant " \
                  "dataset's, but it is not among the data model's column-bearing elements — " \
                  "falling back to positional selection (bead 0ku5)."
           end
           dominant || bearing.find { |e| !(e['name'] || '').end_with?(' Dim') } || bearing.first
         end
dm_el_id   = target['id']
dm_el_name = target['name']
# A DM element is often NAMELESS in the spec (rule 3: omit the element-level
# name). Sigma then assigns a name on the server BY KIND, and the master column
# formula must use that server name or it references a phantom element and the
# workbook POSTs but renders EMPTY. Fetch the spec up front so we can both name
# the element correctly and (in auto mode) read its columns.
#   • warehouse-table  → the table's last path segment (e.g. an extract-landed
#                        or direct-table element: MY_SCHEMA.MY_TABLE → "MY_TABLE")
#   • everything else  → "Custom SQL" (SQL / published-DS elements)
require 'sigma_rest'
spec = Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec")
el = spec['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == dm_el_id }
abort("DM element #{dm_el_id} not found in spec") unless el
if dm_el_name.to_s.strip.empty?
  src = el['source'] || {}
  dm_el_name = if src['kind'] == 'warehouse-table' && !Array(src['path']).empty?
                 Array(src['path']).last
               else
                 'Custom SQL'
               end
end

# Master columns: either explicit from --master-cols or auto-passthrough from the DM element
master_columns =
  if opts[:master_cols]
    cfg = YAML.safe_load(File.read(opts[:master_cols]))
    cfg['columns'] || abort('master-cols YAML missing `columns:` key')
  else
    (el['columns'] || []).map do |c|
      nm = c['name'] || (c['formula'].to_s.match(/^\[[^\/]+\/([^\]]+)\]$/) || [nil, c['id']])[1]
      slug = nm.to_s.downcase.gsub(/\W+/, '-').sub(/-$/, '')
      { 'id' => "m-#{slug}", 'name' => nm, 'formula' => "[#{dm_el_name}/#{nm}]" }
    end
  end
abort('no master columns to emit') if master_columns.empty?

# Dedupe master column ids: two DM columns whose distinct display names slug to the
# same id (e.g. a calc "Market Maker" alongside the physical "MARKET_MAKER") would
# emit a duplicate id and 400 the workbook POST ("Duplicate id"). Names/formulas stay
# distinct (charts reference by name), so we only need to make the ids unique — keep
# the first, suffix later collisions (-2, -3, …).
seen_master_ids = {}
master_columns.each do |c|
  base = c['id']
  next unless seen_master_ids[base]
  n = 2
  n += 1 while seen_master_ids["#{base}-#{n}"]
  c['id'] = "#{base}-#{n}"
ensure
  seen_master_ids[c['id']] = true
end

# Build the data page. Beyond the master, build-charts may emit hidden helper
# elements (scatter grouped sources, FIXED/INCLUDE/EXCLUDE LOD two-level
# helpers, window helpers, aggregate-derived dimension helpers — y9rd.13) under
# the top-level `data_elements` key; they source the master (or each other) and
# the visible charts source THEM, so they must live on the Data page or the
# workbook POST 400s "Dependency not found". They carry visibleAsSource:false.
helper_elements = (specs.is_a?(Hash) && specs['data_elements']) || []
data_page = {
  'id'   => 'page-data',
  'name' => 'Data',
  'elements' => [{
    'id'   => 'master',
    'kind' => 'table',
    'name' => 'Master',
    'visibleAsSource' => false,
    'source' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => dm_el_id },
    'columns' => master_columns,
    'order'   => master_columns.map { |c| c['id'] }
  }] + helper_elements
}
warn "  Data page: + #{helper_elements.size} hidden helper element(s) [#{helper_elements.map { |h| h['id'] }.join(', ')}]" if helper_elements.any?

# Build the visible pages from chart-specs.json
# Two shapes:
#  - dashboard mode: chart-specs.json is a flat array → one page with all elements
#  - page-per-worksheet: chart-specs.json is { pages: [{name, elements}, ...] }
visible_pages = []
if specs.is_a?(Hash) && specs['pages']
  specs['pages'].each do |p|
    # Sigma enforces /^[a-zA-Z0-9_-]{1,64}$/ on a page id. Squash anything
    # outside that set — an ALLOWLIST, not a denylist: the previous
    # hand-picked "/ ( ) %" list let other punctuation straight through, and a
    # real Domo page title ("Sample DataSets + Cards") 400'd the whole workbook
    # POST with `Invalid id format: 'page-sample-datasets-+-cards'`. Only
    # surfaced once the page id started deriving from the REAL title instead of
    # the hardcoded "Overview" placeholder.
    slug = p['name'].to_s.downcase.gsub(/[^a-z0-9]+/, '-')
                    .gsub(/-+/, '-').sub(/\A-/, '').sub(/-\z/, '')[0..40].to_s
    slug = 'page' if slug.empty?   # a title of pure punctuation still needs an id
    visible_pages << {
      'id'       => "page-#{slug}",
      'name'     => p['name'],
      'elements' => p['elements']
    }
  end
elsif specs.is_a?(Array)
  # Dashboard mode → single visible page
  visible_pages << {
    'id'       => 'page-overview',
    'name'     => opts[:name] && opts[:mode] == 'dashboard' ? opts[:name].sub(/\(.*\)$/, '').strip : 'Overview',
    'elements' => specs
  }
else
  abort('chart-specs.json must be either { pages: [...] } or [ ... ]')
end

# Derive the workbook theme from the parsed layout (Phase-1 composition/style,
# gaps D1 + Pass-7 canvas). Two pieces, both spec-authorable (themeName +
# themeOverrides), emitted only when the source actually declares them:
#   - backgroundCanvas: the outermost dashboard zone's fill (the page canvas).
#   - categoricalScheme: the SOURCE region palette, recovered from the tinted
#     container cards. Tableau stores region-card tints as 8-digit-alpha hex
#     (#07b4a24e = the saturated base #07b4a2 over the canvas); stripping the
#     alpha yields the mark color, which is the faithful chart palette (the
#     hand-built spec's hexes are aesthetic tweaks not present in the .twb, so
#     the source colors are the correct automated target). Ordered by first
#     appearance, deduped. Solid 6-digit fills (grey KPI cards) are excluded so
#     only the categorical region hues form the scheme. Returns {} when nothing
#     is derivable → no theme emitted (Sigma defaults apply; never worse).
def derive_theme(layout)
  dashes = layout.is_a?(Array) ? layout : []
  return {} if dashes.empty?
  roots = dashes.first['zone_tree'] || []
  canvas = nil
  palette = []
  seen = {}
  walk = lambda do |nodes, depth|
    (nodes || []).each do |n|
      fc = n['fill_color']
      canvas ||= fc if depth.zero? && fc # outermost zone fill = page canvas
      if n['kind'] == 'container' && fc.is_a?(String) && fc =~ /\A#[0-9a-fA-F]{8}\z/
        base = fc[0, 7].downcase # strip 8-digit alpha → saturated base (mark color)
        unless seen[base]
          seen[base] = true
          palette << base
        end
      end
      walk.call(n['children'], depth + 1)
    end
  end
  walk.call(roots, 0)
  # Canvas: strip any 8-digit alpha so Sigma gets a solid #rrggbb.
  canvas = canvas[0, 7] if canvas.is_a?(String) && canvas =~ /\A#[0-9a-fA-F]{8}\z/
  # Palette preference: the source's real color-encoding brand palette (emitted
  # by parse-twb-layout as brand_palette) beats the container-tint palette. The
  # tint palette only fits the region-card idiom; a dashboard whose design is a
  # color SCHEME (one customer's brand reds, another's subject-color dots) has
  # no ≥2 tinted containers, so the old path degenerated to white card fills.
  # Fall back to tints when the source encodes no brand colors.
  brand = dashes.first['brand_palette']
  scheme = (brand.is_a?(Array) && brand.size >= 2) ? brand : palette
  theme = {}
  theme['backgroundCanvas'] = canvas if canvas
  theme['categoricalScheme'] = scheme if scheme.size >= 2
  theme
end

# GUARD (bead 0ku5): every reference into the primary Master must name a column
# the Master actually has. This exists because binding Master to the WRONG data
# model element failed SILENTLY — the POST only errored on a column name absent
# from the wrong table, so any card using a name present in both tables would
# have rendered the wrong table's numbers with no error at all. Catch it here,
# at build time, instead of trusting a POST-succeeds signal.
#
# Only the bare [Master/...] namespace is checked; a sub-master reference
# ([Master (TABLE)/...]) is validated by its own element's column list.
master_el = ([data_page] + visible_pages).flat_map { |pg| pg['elements'] || [] }
            .find { |e| e['id'] == 'master' }
if master_el
  have = (master_el['columns'] || []).map { |c| c['name'].to_s.downcase }.to_set
  missing = Hash.new { |h, k| h[k] = [] }
  ([data_page] + visible_pages).each do |pg|
    (pg['elements'] || []).each do |el|
      next if el['id'] == 'master'
      (el['columns'] || []).each do |c|
        c['formula'].to_s.scan(/\[Master\/([^\[\]\/]+)\]/) do |(col)|
          missing[col] << (el['name'] || el['id']) unless have.include?(col.to_s.downcase)
        end
      end
    end
  end
  unless missing.empty?
    warn "\n  MASTER REFERENCE CHECK FAILED — #{missing.size} column(s) referenced on the primary"
    warn "  Master that it does not have. The Master is bound to DM element #{dm_el_id.inspect}"
    warn "  (#{dm_el_name.inspect}); if that is not the dominant dataset's table, THAT is the bug"
    warn "  (bead 0ku5) — a wrong binding renders the wrong table's data, mostly WITHOUT erroring."
    missing.each { |col, els| warn "    #{col.inspect} <- #{els.uniq.first(4).join(', ')}" }
    warn "  Master has: #{(master_el['columns'] || []).map { |c| c['name'] }.join(', ')}"
    abort('  aborting before POST rather than shipping a workbook that reads the wrong table')
  end
end

wb = {
  'name' => opts[:name],
  'folderId' => opts[:folder_id]
}
wb['description'] = opts[:description] if opts[:description]

# The released workbook representation differs from the unchanged data-model
# representation: pages are metadata only, elements are document-global, and
# layout is the sole authority for page membership. Add released auto
# navigation only when the Domo source really has multiple pages.
if visible_pages.size > 1
  page_labels = visible_pages.each_with_object({}) { |page, labels| labels[page['id']] = page['name'] }
  visible_pages.each do |page|
    page['elements'].unshift(
      'id' => "nav-#{page['id']}",
      'kind' => 'navigation',
      'mode' => 'auto',
      'pageLabels' => page_labels
    )
  end
end

page_records = [data_page] + visible_pages
flat_elements = page_records.flat_map { |page| page['elements'] || [] }
layout_pages = page_records.map do |page|
  row = 1
  children = (page['elements'] || []).map do |element|
    height = case element['kind']
             when 'page-break' then 1
             when 'control', 'text', 'navigation', 'progress', 'image', 'divider' then 3
             when 'kpi-chart' then 6
             when 'table', 'pivot-table' then 12
             else 10
             end
    xml = SigmaLayout.le(element['id'], 1, 25, row, row + height)
    row += height
    xml
  end
  SigmaLayout.page_xml(page['id'], children.join("\n"))
end

document = {
  'schemaVersion' => 1,
  'kind' => 'workbook',
  'pages' => page_records.map do |page|
    metadata = page.reject { |key, _| key == 'elements' }
    metadata['visibility'] = 'hidden' if page['id'] == 'page-data'
    metadata
  end,
  'elements' => flat_elements,
  'layout' => SigmaLayout.assemble(*layout_pages),
  'panels' => [],
  'overlays' => []
}
if visible_pages.size > 1
  document['settings'] = { 'navigation' => { 'pageTabsInViewMode' => 'shown' } }
end

# Phase-1 theme (D1 palette + Pass-7 canvas), when a --layout was provided.
if opts[:layout]
  theme = derive_theme(JSON.parse(File.read(opts[:layout])))
  unless theme.empty?
    overrides = {}
    overrides['colorOverrides'] = sigma_color_overrides(theme['backgroundCanvas']) if theme['backgroundCanvas']
    overrides['categoricalScheme'] = theme['categoricalScheme'] if theme['categoricalScheme']
    overrides['titleFont'] = { 'fontSize' => 10, 'fontWeight' => 'bold' }
    # Live since 2026-08: themeName/themeOverrides moved to
    # document.settings.theme.{name,overrides} (shared/lib/code_rep.rb
    # DOC_KEYS) — a flat top-level themeName/themeOverrides is invalid on
    # write and gets silently dropped by the code-rep wrapper.
    Sigma::CodeRep.set_theme(document, name: 'Light', overrides: overrides) unless overrides.empty?
    warn "  theme: canvas=#{theme['backgroundCanvas'] || '(default)'}, categoricalScheme=#{(theme['categoricalScheme'] || []).size} color(s)"
  end
else
  # Domo's default card palette, observed across the live gold page. Without a
  # parsed layout palette Sigma falls back to saturated blue/orange, changing
  # almost every multi-series card. Preserve Domo's blue/green/orange/red order
  # and its light-gray dashboard canvas.
  Sigma::CodeRep.set_theme(
    document,
    name: 'Light',
    overrides: {
      'colorOverrides' => sigma_color_overrides('#F4F4F4'),
      'categoricalScheme' => %w[#82BADF #8BC34A #F3A24F #D95C59 #C8E5A3 #7FB4D3 #F8DFA0 #8BBF78],
      'titleFont' => { 'fontSize' => 10, 'fontWeight' => 'bold' }
    }
  )
  warn '  theme: Domo default canvas + 8-color categorical scheme'
end

wb = Sigma::CodeRep.wrap(document, extra: wb)
File.write(opts[:out], JSON.pretty_generate(wb))
warn "wrote #{opts[:out]}"
warn "  mode: #{opts[:mode]}"
warn "  Data page: master sourced from '#{dm_el_name}' (#{dm_el_id})  #{master_columns.size} columns"
warn "  visible pages: #{visible_pages.size}"
visible_pages.each { |p| warn "    - #{p['name']}: #{p['elements'].size} elements" }
