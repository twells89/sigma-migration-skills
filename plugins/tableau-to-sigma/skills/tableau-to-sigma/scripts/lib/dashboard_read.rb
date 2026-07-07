# frozen_string_literal: true
#
# Shared validator for the Phase 1d dashboard-read artifact (png-read.json).
#
# WHY THIS EXISTS. Reading the SOURCE Tableau dashboard PNG and enumerating its
# tiles/text/filters *before* building is the single most-skipped load-bearing
# step in the whole conversion. It gets skipped because — unlike Phase 6 — it
# was prose-only: it produced no artifact anything downstream required, so under
# time/token pressure an agent heads-down on the DM+workbook drops it. The
# result is a workbook with the right NUMBERS but missing tiles/text/filters the
# source dashboard actually rendered (the most common Phase 5 escape).
#
# This module turns that invisible attention step into a required INPUT:
#   - Phase 5 build (build-charts-from-signals.rb) refuses to run without a
#     well-formed png-read.json.
#   - The final gate (assert-phase6-ran.rb) re-checks it as a safety net for the
#     hand-written-spec path that bypasses the build script.
#
# png-read.json schema — the agent writes this in Phase 1d AFTER Reading the PNG:
#   {
#     "source_png": "views/<dashboardViewId>.png",  # the PNG that was read
#     "tiles": [                                     # >=1, one per dashboard zone
#       { "title":    "Revenue by Region",
#         "kind":     "bar-chart",                   # a valid Sigma element kind
#         "measures": ["Gross Revenue"],             # optional
#         "note":     "..." }                        # optional
#     ],
#     "text_elements": ["Orders Dashboard"],         # page title/section headers ([] if none)
#     "filter_shelf": [                              # dashboard-level controls ([] if none)
#       { "label": "Order Date", "control_type": "date-range" }
#     ]
#   }
#
# text_elements and filter_shelf must be PRESENT (use [] when the dashboard
# genuinely has none) — their absence signals the agent never looked for the two
# most-dropped non-chart surfaces.

require 'json'

module DashboardRead
  # Valid Sigma element kinds a tile may declare — the chart kinds PLUS the
  # non-chart surfaces the read must still enumerate (text/control/image). Kept
  # in sync with the "Sigma spec supports:" list in SKILL.md Phase 1d.
  VALID_KINDS = %w[
    bar-chart line-chart area-chart combo-chart scatter-chart kpi-chart
    pie-chart donut-chart region-map point-map table pivot-table
    control text image container
  ].freeze

  # parse-twb-layout chart_kind → a Sigma element kind, for the DRAFT seed only.
  DRAFT_KIND = {
    'bar' => 'bar-chart', 'line' => 'line-chart', 'area' => 'area-chart',
    'pie' => 'pie-chart', 'scatter' => 'scatter-chart', 'kpi' => 'kpi-chart',
    'pivot-table' => 'pivot-table', 'table' => 'table',
    'map-region' => 'region-map', 'map-point' => 'point-map',
    'automatic' => 'bar-chart', 'other' => 'bar-chart'
  }.freeze

  # Seed a DRAFT png-read.json from the .twb zone tree (dashboard-layout.json),
  # so the agent EDITS a starting point instead of writing from scratch (finding
  # #8). The draft is verified:false, so validate() still fails until the agent
  # Reads the dashboard PNG and confirms/corrects it — the .twb can't tell
  # bar-vs-pie for 'automatic' marks, what text actually rendered, or the filter
  # shelf. Returns the written path, or nil if there's no zone tree to seed from.
  def self.seed_from_layout(dir)
    layout_path = File.join(dir, 'dashboard-layout.json')
    return nil unless File.exist?(layout_path)

    layout = (JSON.parse(File.read(layout_path)) rescue nil)
    return nil unless layout

    dashes = layout.is_a?(Array) ? layout : (layout['dashboards'] || [layout])
    zones = dashes.flat_map { |d| d.is_a?(Hash) ? (d['zones'] || []) : [] }
    tiles = []
    text_elements = []
    zones.each do |z|
      if z['is_kpi'] || z['kind'] == 'chart'
        tiles << { 'title' => z['caption'].to_s,
                   'kind' => DRAFT_KIND[z['chart_kind'].to_s] || (z['is_kpi'] ? 'kpi-chart' : 'bar-chart') }
      elsif %w[text title].include?(z['kind']) && z['text_runs']
        t = z['text_runs'].map { |r| r['text'] }.join.strip
        text_elements << t unless t.empty?
      end
    end

    filter_shelf = []
    meta_path = layout_path.sub(/\.json\z/, '-meta.json')
    if File.exist?(meta_path)
      meta = (JSON.parse(File.read(meta_path)) rescue {})
      (meta['shared_filters'] || []).each do |f|
        lbl = (f['caption'] || f['column'] || f['name']).to_s
        filter_shelf << { 'label' => lbl } unless lbl.empty?
      end
    end

    draft = {
      'verified'      => false,
      'seeded_from'   => 'twb-parse — UNVERIFIED. Read the dashboard PNG, correct tiles/text/filter_shelf, then set verified:true.',
      'source_png'    => nil,
      'tiles'         => tiles,
      'text_elements' => text_elements,
      'filter_shelf'  => filter_shelf
    }
    File.write(path(dir), JSON.pretty_generate(draft) + "\n")
    path(dir)
  end

  def self.path(dir)
    File.join(dir, 'png-read.json')
  end

  # Is this workdir a Tableau conversion that SHOULD have a dashboard read?
  # Trigger on the tableau-only zone-tree artifact so the final-gate check stays
  # invisible to the other converters that share assert-phase6-ran.rb.
  def self.expected?(dir)
    %w[dashboard-layout.json get-workbook.json].any? { |f| File.exist?(File.join(dir, f)) }
  end

  # Returns [ok(Boolean), errors(Array<String>)].
  def self.validate(dir)
    p = path(dir)
    return [false, ["#{p} does not exist — the Phase 1d dashboard-read step was skipped."]] unless File.exist?(p)

    begin
      doc = JSON.parse(File.read(p))
    rescue JSON::ParserError => e
      return [false, ["#{p} is malformed JSON: #{e.message}"]]
    end

    # A DRAFT seeded from the .twb (seed_from_layout) carries verified:false. The
    # .twb can't tell bar-vs-pie for 'automatic' marks, what text annotations
    # rendered, or the filter shelf — so a draft does NOT satisfy the gate until
    # the agent Reads the dashboard PNG, corrects it, and sets verified:true.
    # (Hand-written png-read.json omit the field entirely — treated as verified.)
    if doc['verified'] == false
      return [false, ["#{p} is a DRAFT seeded from the .twb (\"verified\": false). Read the " \
                      'dashboard PNG, correct the tiles/text/filter_shelf (esp. bar-vs-pie, ' \
                      'annotations, and the filter shelf — the .twb cannot see these), then set ' \
                      '"verified": true.']]
    end

    errs = []
    tiles = doc['tiles']
    if !tiles.is_a?(Array) || tiles.empty?
      errs << 'png-read.json has no `tiles` — enumerate EVERY dashboard zone from the image ' \
              '(chart AND non-chart: text, filter shelf, legend).'
    else
      tiles.each_with_index do |t, i|
        unless t.is_a?(Hash) && t['kind']
          errs << "tiles[#{i}] missing `kind` — decide the Sigma element kind from the IMAGE, not the CSV header."
          next
        end
        unless VALID_KINDS.include?(t['kind'])
          errs << "tiles[#{i}].kind=#{t['kind'].inspect} is not a valid Sigma kind (#{VALID_KINDS.join(', ')})."
        end
      end
    end

    %w[text_elements filter_shelf].each do |k|
      next if doc.key?(k)
      errs << "png-read.json missing `#{k}` — set it to [] if the dashboard genuinely has none, " \
              'but confirm from the image first (these are the two most-dropped surfaces).'
    end

    [errs.empty?, errs]
  end

  # Convenience: tile count for PASS messages (0 if unreadable).
  def self.tile_count(dir)
    doc = JSON.parse(File.read(path(dir)))
    doc['tiles'].is_a?(Array) ? doc['tiles'].size : 0
  rescue StandardError
    0
  end
end
