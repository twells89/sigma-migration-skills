#!/usr/bin/env ruby
# Phase 5d (pre) — Domo page geometry → the zone-schema dashboard-layout.json that
# the reused build-dashboard-layout.rb consumes.
#
# Geometry source: discovery/cards.json, written by domo-discover.rb via
# DomoSigma.merge_geometry (lib/domo_sigma_util.rb). This is the ONE geometry
# source for the layout builder; there is no separate extractor. (Earlier
# revisions read a duplicate discovery/layout/<pageId>.json produced by
# domo-capture-visuals.rb's own normalize_layout — that path never received
# merge_geometry's output, so a migration's real card coordinates never
# reached the layout builder. domo-capture-visuals.rb now only stages
# PNG/PDF references; it emits no geometry file.)
#
# refs/live-validation-2026-07-30.md ("Layout — classic pages have no
# x/y/w/h") is why this file is a FALLBACK CHAIN rather than one geometry
# read. A live classic Domo page's private read
# (GET /api/content/v3/stacks/{pageId}/cards) carries NO pixel geometry at
# all. What it carries instead is a per-card T-shirt `size` TOKEN (sizes[])
# and titled `collections[]` that group cards BY INDEX. Priority, most
# faithful first:
#   1. x/y/w/h pixel geometry (build_dashboard) — mason/Domo-App pages that
#      genuinely report pixel geometry. Normalized RELATIVE to each page's own
#      max extent (x/maxX etc.), so it works whether Domo reports geometry in
#      grid cells or pixels.
#
#      1.5. OPERATOR-OBSERVED geometry (build_dashboard_with_observed,
#           discovery/layout-observed.json) — a HUMAN-AUTHORED sidecar, not an
#           API read. Live validation confirmed there is NO API path to real
#           per-card geometry on a classic page: preferredFullWidth/Height
#           don't persist anywhere on readback, sizes[].size comes back "" for
#           API-created cards, collections[] has no write endpoint, and there
#           is no page-render endpoint (every attempt 404s). The only way to
#           recover the source page's ACTUAL arrangement is for a human (or an
#           agent) to read a page screenshot and transcribe it. This sidecar
#           is that transcription — see its own section below for the schema.
#           Ranked ABOVE collections/size tokens (rung 2) because a human
#           reading a real screenshot is more faithful than any token-based
#           guess, but BELOW real pixel geometry (rung 1) because it's still a
#           transcription, not a measurement — every zone it produces is
#           tagged '_source' => 'observed-from-screenshot' so it is never
#           mistaken for API-derived truth downstream. A PARTIAL sidecar (only
#           some of a page's cards observed) is expected, not an error: the
#           unobserved remainder falls through to rung 2/2a below, WARNING by
#           name which cards weren't covered.
#   2. collections[] + size tokens (build_dashboard_from_collections) —
#      classic pages (the common case live). A card's own
#      preferredFullWidth/preferredFullHeight (present when it was created
#      via Domo's public card-write API) is preferred over its size token
#      when both exist (see that method's header comment).
#
#      2a. KIND-AWARE DEFAULT COMPOSITION (Phase 5e visual-QA fix,
#          refs/layout-visual-qa.md) — the sub-case within rung 2 that fires
#          when a card carries NO width signal at all (blank/empty '_size',
#          no preferredFullWidth/Height). Live validation (refs/
#          live-validation-2026-07-30.md) found this is the COMMON case for
#          API-created Domo pages, not an edge case: sizes[] comes back
#          {"id":..,"size":""} for every card, and collections: [] gives no
#          sectioning signal either. The old behavior gave every card the
#          same flat 'medium' width/height regardless of KIND — a KPI got the
#          same tall full-width band as a chart. compose_kind_aware_rows
#          below fixes this by REGROUPING a section's cards BY KIND — in the
#          house-style band ORDER confirmed against refs/layout-visual-qa.md's
#          own "Building clean in the first place" table (and, for further
#          reference, millersigma:branded-dashboard-format's header -> filter-
#          bar -> KPI row -> trend -> detail shape): a full-width CONTROL band
#          first (never left loose/interleaved — a loose control is exactly
#          what layout_lint's orphan-control check flags), then the compact
#          KPI row, then paired charts, then full-width tables/pivots — each
#          kind laid out with its own appropriate width+height, while
#          preserving each kind-group's own internal _pageOrder sequence. See
#          that method's header comment for the exact rules and why this only
#          needs to change WIDTH/HEIGHT math here — the downstream (unowned)
#          build-dashboard-layout.rb already detects a KPI row / paired chart
#          band purely from zone geometry (SigmaLayout.detect_kpi_rows /
#          cluster_bands), and already auto-bands any 'control'-kind SPEC
#          ELEMENT under the header regardless of zone backing (build_page_
#          for_dashboard's "Control band" / build_page_synthesized's
#          band_ctls) — so shaping the zones correctly (and, for a control
#          with NO backing card at all — e.g. a page-level filter
#          build-workbook.rb synthesizes independently of any card, confirmed
#          live on a Tier-2 page as "ctl-order_status" — synthesizing a zone
#          for it too, by NAME, so any downstream sidebar/rail detection that
#          keys on caption still works) is sufficient; no new rendering logic
#          is needed on this end of the pipeline.
#   3. last-resort single-column stack (build_stack_fallback) — WARNS LOUDLY
#      every time it fires; this is the exact silent-stack fidelity bug a
#      partner migration hit before, now made loud instead of silent. Should
#      only be reached when a page has NEITHER pixel geometry NOR any
#      collections/size signal at all (e.g. a degraded/Tier-B fetch).
#
# FIELD NAMES (rung 2) — the sibling DomoSigma.merge_geometry change (Bug 5,
# lib/domo_sigma_util.rb, owned by a concurrent task, NOT this file) copies
# THREE fields onto a cards.json record from the private
# GET /api/content/v3/stacks/{pageId}/cards response, independent of the
# legacy 'x'/'y'/'w'/'h' pixel pass and independent of each other:
#   '_size'       — the raw T-shirt token string (stacks['sizes'], keyed by
#                   card id) — "small"/"medium"/"large"/anything else Domo adds.
#   '_collection' — {'id', 'title', 'index'} for the collection this card
#                   falls in, from stacks['collections'][].cardIndices;
#                   OMITTED (never defaulted) when the card isn't referenced
#                   by any collection. NOTE: '_collection'['index'] is the
#                   card's own 0-based position in the stacks cards[] array
#                   (same number as '_pageOrder' below), NOT the collection's
#                   sequence number among collections[] — this file derives
#                   section order from the MINIMUM '_pageOrder' across a
#                   collection's cards instead (see group_into_sections).
#   '_pageOrder'  — that same 0-based stacks-array position, ALWAYS attached
#                   whenever the private stacks response was available at
#                   all (regardless of collection membership) — the explicit
#                   ordering signal even on a page with zero collections
#                   (collections: [], one sizes[] entry per card — the
#                   API-created-page shape).
# preferredFullWidth/preferredFullHeight are NOT something merge_geometry
# adds — they are Domo's own create/update-body field names (verified live),
# read straight off the card record on the (unconfirmed) chance a private
# card read ever echoes them back; card_width_units/card_height_units below
# degrade to the token/default the moment either is absent, so this costs
# nothing when they never appear. Each card becomes a zone with kind:"chart"
# (or "filter"/"text") + caption + chart_kind so ZoneCensus counts it.
#
#   ruby scripts/build-domo-layout.rb            # → discovery/dashboard-layout.json
#
# Then reuse: build-dashboard-layout.rb --layout discovery/dashboard-layout.json --wb-ids wb-ids.json --out layout.xml
#
# NOTE: the dashboard/page NAME here must match the workbook page names
# build-workbook.rb produced (build-dashboard-layout matches dashboards↔pages by
# name and requires a page literally named "Data").

require 'json'
require 'fileutils'
require_relative 'lib/domo_sigma_util'
include DomoSigma

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# Coarse chart_kind token for census/placement (the real Sigma kind is chosen by
# build-workbook.rb; this is only for layout weighting). Substring map, kept
# independent of domo-discover.rb. NOTE: this is the zone's LOGICAL kind that
# lib/layout.rb's kpi_like_zone? (vendored verbatim from tableau-to-sigma)
# matches against — it expects the bare 'kpi', not the Sigma ELEMENT kind
# 'kpi-chart' that domo-discover.rb's sigma_kind_hint separately emits for
# build-workbook.rb's build_kpi. Emitting 'kpi-chart' here silently missed
# KPI-row detection for any Domo KPI tile that failed the plain size heuristic.
def kind_hint(chart_type)
  t = chart_type.to_s.downcase
  return 'filter'       if t.include?('filter')
  return 'progress'     if t.include?('gauge')
  return 'kpi'          if t.include?('singlevalue') || t.include?('summary') || t == 'badge'
  return 'table'        if t.include?('datagrid') || t.include?('table')
  return 'bar-chart'    if t.include?('bar')
  return 'line-chart'   if t.include?('line')
  return 'donut-chart'  if t.include?('pie') || t.include?('donut')
  return 'scatter-chart' if t.include?('scatter') || t.include?('bubble')
  'bar-chart'
end

# Zone caption for a card. KPI-kind cards must match the name build_kpi
# (build-workbook.rb) will actually give the built Sigma element -- it prefers
# the card's Summary Number label over the card's own title (Domo lets an
# author label a tile differently from the card's title; the label is what
# actually renders ON the KPI). Every zone-building path in this file used the
# card's title unconditionally, so a KPI whose summaryNumber.label differs
# from its title (e.g. a card titled "Units Ordered" labeled "Units" on the
# tile itself) got a zone build-dashboard-layout.rb's name-based matcher could
# never find, silently dropping it into the generic bottom-band fallback
# (bead wmkf).
def zone_caption_for(card, chart_kind)
  if chart_kind == 'kpi'
    label = card['summaryNumber'] && card['summaryNumber']['label']
    return label unless label.to_s.strip.empty?
  end
  card['title']
end

# Build one dashboard's zone tree from its own geometry-bearing cards (already
# scoped to one page by the caller). `cards` — this page's cards.json records
# that carry x/y/w/h (Task 1's merge_geometry). `name` — the page title, used
# as the dashboard name build-dashboard-layout.rb matches against the workbook
# page name.
def build_dashboard(name, cards)
  cards = Array(cards).select { |c| c['x'] && c['y'] && c['w'] && c['h'] }
  return nil if cards.empty?
  max_x = cards.map { |c| c['x'].to_f + c['w'].to_f }.max
  max_y = cards.map { |c| c['y'].to_f + c['h'].to_f }.max
  max_x = 1.0 if max_x.zero?
  max_y = 1.0 if max_y.zero?
  zones = cards.map do |c|
    kh = c['sigmaKindHint'].to_s.empty? ? kind_hint(c['chartType']) : c['sigmaKindHint']
    is_filter = kh == 'filter'
    {
      'id'        => c['id'],
      'x_pct'     => (c['x'].to_f * 100.0 / max_x).round(2),
      'y_pct'     => (c['y'].to_f * 100.0 / max_y).round(2),
      'w_pct'     => (c['w'].to_f * 100.0 / max_x).round(2),
      'h_pct'     => (c['h'].to_f * 100.0 / max_y).round(2),
      'kind'      => is_filter ? 'filter' : 'chart',
      'caption'   => zone_caption_for(c, kh),
      'chart_kind'=> is_filter ? nil : kh,
      # non-empty so ZoneCensus.plots? counts a data card as a real tile
      'measures'  => is_filter ? [] : ['value'],
      'children'  => [],
    }.compact
  end
  { 'dashboard' => name, 'zone_tree' => zones, 'zones' => zones }
end

# ==== rung 1.5 — operator-observed geometry (file header "1.5") =============
# discovery/layout-observed.json — OPERATOR input (a human, or an agent
# reading a page screenshot), never written by this skill itself (same
# convention as discovery/dataset-map.json — this file must NEVER author it).
# There is no live API path to a classic page's real per-card geometry (see
# the file header: preferredFullWidth/Height don't persist, sizes[].size
# comes back "", collections[] has no write endpoint, there is no page-render
# endpoint), so a human-transcribed screenshot is the only route to the
# source page's ACTUAL arrangement rather than a kind-based guess.
#
# SCHEMA (this file's own choice, documented here — no other doc owns it): a
# flat JSON object keyed by the Domo CARD ID as a STRING (JSON object keys
# are always strings, so "390868622", not 390868622), each value:
#   { "x": 0.0, "y": 0.0, "w": 0.25, "h": 0.12, "section": "optional label" }
# x/y/w/h are FRACTIONS OF THE FULL PAGE (0.0..1.0, origin top-left) — chosen
# over Domo's native 1..6 grid units because a human (or a model) reading a
# screenshot naturally estimates "this KPI spans about a quarter of the page
# width," not "1.5 of Domo's 6 grid columns"; mapping onto Sigma's 24-col
# grid is a bare *100 either way (x_pct = x*100), so nothing is lost by
# picking the human-friendlier unit. 'section' is OPTIONAL free text — cards
# sharing the same 'section' value get ONE thin heading zone above them
# (mirrors '_collection' grouping) but, unlike a collection, are NEVER
# re-packed — the operator's own x/y/w/h is authoritative, full stop.
def load_observed_layout(dir)
  path = File.join(dir, 'layout-observed.json')
  return {} unless File.exist?(path)
  data = JSON.parse(File.read(path)) rescue nil
  return {} unless data.is_a?(Hash)
  data.each_with_object({}) do |(k, v), out|
    next unless v.is_a?(Hash) && %w[x y w h].all? { |f| v.key?(f) }
    out[k.to_s] = v
  end
end

# rung 1.5 proper. `observed` is the FULL sidecar map (every observed card on
# every page) — filtering to THIS page's own cards happens right here, so
# callers never need to pre-slice it. Returns nil (never partially-applies
# without a caller check) when NONE of this page's cards are observed, so
# build_dashboard_for_page falls through to rung 2 untouched.
#
# PARTIAL coverage is expected, not an error (file header note): a card on
# this page with NO observed entry is never dropped — it is laid out via the
# ordinary kind-aware default composition (build_dashboard_from_collections,
# extending the SAME machinery rather than a parallel one) and appended BELOW
# the observed content, never overlapping it. The observed region keeps
# EXACTLY the vertical extent the operator gave it; the composed remainder is
# proportionally rescaled into whatever page fraction is left (floored at a
# 20-point minimum so a near-full-page observed region doesn't squeeze the
# remainder to nothing).
def build_dashboard_with_observed(name, cards, observed, kind_map)
  observed_cards, unobserved_cards = cards.partition { |c| observed.key?(c['id'].to_s) }
  return nil if observed_cards.empty?
  attached_companions, unobserved_cards = unobserved_cards.partition do |c|
    c['_primary_card_id'] && observed.key?(c['_primary_card_id'].to_s)
  end
  companions_by_primary = attached_companions.each_with_object({}) do |c, out|
    out[c['_primary_card_id'].to_s] = c
  end

  unless unobserved_cards.empty?
    warn "  ⚠ discovery/layout-observed.json covers #{observed_cards.length} of #{cards.length} " \
         "card(s) on page #{name.inspect} — falling back to the default kind-aware composition for " \
         "the rest: #{unobserved_cards.map { |c| c['title'] || c['id'] }.join(', ')}"
  end

  obs_zones = observed_cards.map do |c|
    o = observed[c['id'].to_s]
    kh = zone_chart_kind_for(c, kind_map)
    is_filter = kh == 'filter'
    companion = companions_by_primary[c['id'].to_s]
    companion_share = companion ? 0.24 : 0.0
    {
      'id'         => c['id'],
      'x_pct'      => (o['x'].to_f * 100.0).round(2),
      'y_pct'      => ((o['y'].to_f + o['h'].to_f * companion_share) * 100.0).round(2),
      'w_pct'      => (o['w'].to_f * 100.0).round(2),
      'h_pct'      => (o['h'].to_f * (1.0 - companion_share) * 100.0).round(2),
      'kind'       => is_filter ? 'filter' : 'chart',
      'caption'    => zone_caption_for(c, kh),
      'chart_kind' => is_filter ? nil : kh,
      'measures'   => is_filter ? [] : ['value'],
      'children'   => [],
      '_source'    => 'observed-from-screenshot',
    }.compact
  end
  companion_zones = attached_companions.map do |c|
    o = observed[c['_primary_card_id'].to_s]
    {
      'id' => c['id'], 'kind' => 'chart', 'caption' => c['title'],
      'chart_kind' => 'kpi', 'measures' => ['value'], 'children' => [],
      'x_pct' => (o['x'].to_f * 100.0).round(2),
      'y_pct' => (o['y'].to_f * 100.0).round(2),
      'w_pct' => (o['w'].to_f * 100.0).round(2),
      'h_pct' => (o['h'].to_f * 0.24 * 100.0).round(2),
      '_source' => 'observed-from-screenshot-summary',
    }
  end
  primary_zones = obs_zones.each_with_object({}) { |zone, out| out[zone['id'].to_s] = zone }
  companion_zones_by_primary = attached_companions.each_with_object({}) do |card, out|
    out[card['_primary_card_id'].to_s] = companion_zones.find { |zone| zone['id'].to_s == card['id'].to_s }
  end
  observed_tree = observed_cards.map do |card|
    primary = primary_zones.fetch(card['id'].to_s)
    companion = companion_zones_by_primary[card['id'].to_s]
    next primary unless companion

    o = observed.fetch(card['id'].to_s)
    {
      'id' => "observed-card-#{card['id']}",
      'kind' => 'container',
      'caption' => card['title'],
      'x_pct' => (o['x'].to_f * 100.0).round(2),
      'y_pct' => (o['y'].to_f * 100.0).round(2),
      'w_pct' => (o['w'].to_f * 100.0).round(2),
      'h_pct' => (o['h'].to_f * 100.0).round(2),
      'fill_color' => '#FFFFFF',
      'border_color' => '#D9DEE5',
      'children' => [companion, primary],
      '_source' => 'observed-from-screenshot-card',
    }
  end

  # Optional 'section' grouping (schema note above): one thin heading zone per
  # named group, at that group's own topmost observed y — no reflow.
  sections_seen = observed_cards.map { |c| observed[c['id'].to_s]['section'] }.compact.uniq
                                .sort_by do |sec|
    observed_cards.select { |c| observed[c['id'].to_s]['section'] == sec }
                  .map { |c| observed[c['id'].to_s]['y'].to_f }.min
  end
  hdr_zones = sections_seen.each_with_index.map do |sec, i|
    members_y = observed_cards.select { |c| observed[c['id'].to_s]['section'] == sec }
                               .map { |c| observed[c['id'].to_s]['y'].to_f }
    {
      'id' => "observed-section-#{i}", 'kind' => 'text', 'caption' => sec,
      'x_pct' => 0.0, 'y_pct' => [(members_y.min * 100.0) - 3.0, 0.0].max.round(2),
      'w_pct' => 100.0, 'h_pct' => 2.5, 'children' => [], '_source' => 'observed-from-screenshot',
    }
  end

  zones = obs_zones + companion_zones + hdr_zones
  tree_zones = observed_tree + hdr_zones
  observed_max_y_pct = obs_zones.map { |z| z['y_pct'] + z['h_pct'] }.max

  unless unobserved_cards.empty?
    rest = build_dashboard_from_collections(name, unobserved_cards, kind_map)
    if rest
      remaining_budget = [100.0 - observed_max_y_pct, 20.0].max
      rest['zones'].each do |z|
        shifted = z.dup
        shifted['y_pct'] = (observed_max_y_pct + z['y_pct'] / 100.0 * remaining_budget).round(2)
        shifted['h_pct'] = (z['h_pct'] / 100.0 * remaining_budget).round(2)
        zones << shifted
        tree_zones << shifted
      end
    end
  end

  { 'dashboard' => name, 'zone_tree' => tree_zones, 'zones' => zones }
end

# ==== rung 2 — classic-page fallback: collections[] + size tokens ==========
# See the file header for the full rationale. Domo's OWN card grid is 6
# columns wide (verified live: preferredFullWidth/Height are REJECTED outside
# 1..6 — "height and width must have values between 1 and 6"), so all the
# math below works in that native 1..6 unit space and only converts to
# PERCENT at the very end — never to an absolute 24-column count. This is
# deliberately equivalent to (and simpler than) scaling by the observed x4
# Domo->Sigma factor and then re-expressing as a fraction of Sigma's 24-col
# grid: units*4/24*100 == units/6*100. A 'large' (6-wide) card therefore comes
# out at exactly 100% page width either way.
DOMO_GRID_COLS = 6

# T-shirt size TOKEN → Domo grid-column span. Domo's live API gives only the
# token (sizes[].size), never a numeric width, and there is no documented
# token→column table — these spans are this file's ASSUMPTION, chosen so
# 'medium' (the one token value observed live, 36/36 cards on the validated
# instance) fills half a row (2-up), 'small' a third (3-up), and 'large' the
# full row (1-up). An unrecognized token WARNS and is treated as 'medium'
# rather than guessed at further (see normalize_size_token).
SIZE_TOKEN_WIDTH = { 'small' => 2, 'medium' => 3, 'large' => 6 }.freeze

# Per-row height in the same native units, used when a card carries no
# preferredFullHeight override. Domo's size token carries NO height signal at
# all (only build_dashboard_from_collections's width varies by token) —
# every synthesized row is this same height unless overridden per-card.
ROW_HEIGHT_UNITS = 4

# A collection-title heading band's height — thin relative to a content row,
# matching lib/layout.rb's own "banner, not a block" HEADER_ROWS intent.
HEADER_ROW_UNITS = 1

# ==== kind-aware default composition constants (see file header "2a") =======
# Row heights are in the SAME unitless native-row space as ROW_HEIGHT_UNITS
# above (only ever compared to each other / summed into a total before being
# converted to a percentage) — there is no absolute "inch" behind any of
# these numbers, only their RATIO to one another. The ratios below are chosen
# so a KPI row reads as short, a chart row as a normal tile, and a table row
# as noticeably roomier — directly answering the measured complaint in
# refs/layout-visual-qa.md ("a KPI occupies the same footprint as a full
# chart"; "huge vertical whitespace").
CONTROL_ROW_HEIGHT_UNITS = 2 # a control strip is short too — same order as a KPI row
KPI_ROW_HEIGHT_UNITS     = 2 # a KPI needs far less height than a chart (WHAT TO BUILD #1)
CHART_ROW_HEIGHT_UNITS   = 5 # a chart-appropriate height for a paired 12-col tile (#2)
TABLE_ROW_HEIGHT_UNITS   = 8 # tables/pivots need more vertical room than a chart (#3)

# A KPI row wraps to a new row past this many members — chosen so the LAST
# row of a wrap is never a lone straggler for any n (see balanced_chunk_sizes):
# Domo's own card grid is 6 native columns, so 6 is also the largest row that
# can still give every member a whole-number-friendly share of it.
KPI_MAX_PER_ROW = 6

# Normalize a raw Domo size token to the known small/medium/large family.
# Unknown/blank tokens fall back to 'medium' — LOUDLY (a warning, not a
# silent guess) when the token was actually present but unrecognized; a
# genuinely absent token (nil) defaults quietly since that's the expected
# shape for a card the discovery step simply couldn't size.
def normalize_size_token(token)
  t = token.to_s.downcase.strip
  return t if SIZE_TOKEN_WIDTH.key?(t)
  warn "  ⚠ unknown Domo card size token #{token.inspect} on a classic-page " \
       "card — treating as 'medium' (known family: small/medium/large)" unless token.nil? || t.empty?
  'medium'
end

# A card's explicit preferredFullWidth/preferredFullHeight (Domo's own
# create/update-body field names, verified live — present when the card was
# created via the public write API), clamped into Domo's native 1..6 range.
# Returns nil when the field is absent/non-numeric so the caller can fall
# back to the size-token width.
def numeric_grid_value(v)
  return nil if v.nil?
  n = begin
    Float(v)
  rescue ArgumentError, TypeError
    nil
  end
  return nil unless n
  n.clamp(1.0, DOMO_GRID_COLS.to_f)
end

# This card's column span in Domo's native 1..6 units: its own
# preferredFullWidth when present (an exact, API-confirmed span), else the
# size-token lookup (an assumption — see SIZE_TOKEN_WIDTH). '_size' is
# DomoSigma.merge_geometry's field name for the raw token (stacks['sizes']).
def card_width_units(card)
  numeric_grid_value(card['preferredFullWidth']) || SIZE_TOKEN_WIDTH.fetch(normalize_size_token(card['_size']))
end

# This card's row height in the same native units: its own
# preferredFullHeight when present, else the flat ROW_HEIGHT_UNITS default
# (Domo's size token carries no height signal to read instead).
def card_height_units(card)
  numeric_grid_value(card['preferredFullHeight']) || ROW_HEIGHT_UNITS
end

# True when this card carries a REAL width signal of its own — an explicit
# NON-EMPTY '_size' token (even an unrecognized one, e.g. 'huge-token': Domo
# told us *something*, we just don't know its exact span — see
# normalize_size_token), or a numeric preferredFullWidth/Height. False for the
# live API-created-card shape ('_size' => "", no preferred* fields at all) —
# see refs/live-validation-2026-07-30.md ("size is an EMPTY STRING for
# API-created cards"). This is the gate between the two rung-2 sub-paths:
# a section where EVERY card fails this check gets the kind-aware default
# composition (compose_kind_aware_rows); a section with even one real signal
# keeps the original per-card token-default wrap (wrap_into_rows) so a
# genuinely-sized card is never second-guessed by a kind guess.
def has_width_signal?(card)
  return true if numeric_grid_value(card['preferredFullWidth'])
  return true if numeric_grid_value(card['preferredFullHeight'])
  !card['_size'].to_s.strip.empty?
end

# Partition a page's cards into ordered SECTIONS: one per Domo `collections[]`
# entry, each holding its cards in stacks-array order, plus one trailing,
# unheaded section for cards no collection references ("ungrouped", per the
# live API's own terminology) in their original discovery order. No card is
# ever dropped: a card with no '_collection' at all lands in the trailing
# ungrouped section.
#
# Keyed off merge_geometry's '_collection' ({'id','title','index'} — 'index'
# is the CARD's own stacks-array position, not the collection's sequence
# number) and '_pageOrder' (that same stacks-array position, always present
# when the private stacks response was available at all). Sections are
# ordered by the MINIMUM '_pageOrder' among their cards, and cards within a
# section are sorted by their own '_pageOrder' — since Domo's own
# `collections[].cardIndices` are contiguous, ascending blocks in every
# observed live response, this reproduces collections[]'s own declared order
# without needing a separate "which collection came Nth" field.
def group_into_sections(cards)
  grouped = Hash.new { |h, k| h[k] = [] }
  ungrouped = []
  cards.each do |c|
    coll = c['_collection']
    if coll.is_a?(Hash) && coll['title']
      grouped[[coll['id'], coll['title'].to_s]] << c
    else
      ungrouped << c
    end
  end
  sections = grouped.map do |(_id, title), scards|
    ordered = scards.sort_by { |c| c['_pageOrder'].to_i }
    { 'title' => title, 'cards' => ordered, 'order' => ordered.map { |c| c['_pageOrder'].to_i }.min.to_i }
  end.sort_by { |s| s['order'] }
  sections.each { |s| s.delete('order') }
  sections << { 'title' => nil, 'cards' => ungrouped.sort_by { |c| c['_pageOrder'].to_i } } unless ungrouped.empty?
  sections
end

# Wrap an ordered list of cards into ROWS on Domo's native 6-col grid: tile
# left-to-right, starting a new row once placing the next card would push the
# row's used width past DOMO_GRID_COLS. Returns rows of [card, x_units, w_units]
# triples (x_units is this card's left offset WITHIN its own row).
def wrap_into_rows(cards)
  rows = []
  row = []
  used = 0
  cards.each do |c|
    w = card_width_units(c)
    if used.positive? && used + w > DOMO_GRID_COLS
      rows << row
      row = []
      used = 0
    end
    row << [c, used, w]
    used += w
  end
  rows << row unless row.empty?
  rows
end

# ==== kind-aware default composition (file header "2a") =====================
# Fires only for a SECTION where every card fails has_width_signal? — i.e.
# Domo gave us genuinely nothing to size by. Rather than the flat
# one-width-fits-all wrap_into_rows path, this REGROUPS the section's cards
# by element KIND (a control reads differently than a KPI, which reads
# differently than a chart, which reads differently than a table) and lays
# out each kind-group with its own appropriate width/height, in the house
# band ORDER confirmed against refs/layout-visual-qa.md's own "Building clean
# in the first place" table (Header -> Control row -> KPI row -> Chart row ->
# Detail table) and, for further reference, millersigma:branded-dashboard-
# format's header -> filter-bar -> KPI row -> trend -> detail shape:
#   - filter/control cards share ONE full-width band at CONTROL_ROW_HEIGHT_
#     UNITS, FIRST — never left loose or interleaved among charts (a loose
#     control is exactly what layout_lint's orphan-control check flags).
#   - KPI cards share a compact ROW (2-6 per row; a lone KPI is still capped
#     at half width rather than stretched full-row) at KPI_ROW_HEIGHT_UNITS.
#   - plotting chart cards PAIR 2-up at CHART_ROW_HEIGHT_UNITS; an odd
#     trailing chart with no partner gets the full row width.
#   - table/pivot cards each get their own FULL-WIDTH row at
#     TABLE_ROW_HEIGHT_UNITS (they need more room, not less).
#   - anything else (a text tile, or a kind this file doesn't otherwise
#     recognize) is OUT OF SCOPE for this regrouping — WHAT TO BUILD #1-3
#     only names control/KPI/chart/table — and keeps the pre-existing
#     per-card token-default wrap (wrap_into_rows) untouched, placed LAST.
# _pageOrder is preserved WITHIN each kind-group (cards arrive already sorted
# by _pageOrder from group_into_sections, and buckets below only filter, never
# reorder), so "preserve source order" (WHAT TO BUILD #4) means "the migrated
# page still reads like the Domo page" AT THE KIND-GROUP level: the 4th KPI
# on the source page is still the 4th KPI left-to-right in the KPI row, even
# though it may have sat between two charts on the source page.
#
# Element-KIND source priority (report this choice, per the task brief):
# chart-specs.json's resolved Sigma `kind` (build-workbook.rb's OWN final
# choice — e.g. it may promote a "bar chart with a secondary line measure" to
# 'combo-chart', which cards.json's sigmaKindHint predates) beats
# cards.json's sigmaKindHint (an EARLIER best-guess, made before the data
# model / chart builder resolved the real element), which beats chartType via
# the existing kind_hint() (a coarse last resort when neither of the above
# ran yet, e.g. an offline/unit-test card with no discovery pipeline behind
# it at all).

# Load discovery/chart-specs.json (written by build-workbook.rb — NOT owned
# by this file) into a flat { "el-<cardId>" => sigma_kind } map. Absent/
# unparsable/wrong-shaped file -> {} (never raises); this is a NICE-TO-HAVE
# refinement of the kind guess, not a hard dependency — build-workbook.rb may
# not have run yet (e.g. layout built before charts), or this may be a unit
# test with no discovery/ directory at all.
def load_chart_specs_kind_map(dir)
  path = File.join(dir, 'chart-specs.json')
  return {} unless File.exist?(path)
  data = JSON.parse(File.read(path)) rescue nil
  return {} unless data.is_a?(Hash) && data['pages'].is_a?(Array)
  map = {}
  data['pages'].each do |p|
    Array(p['elements']).each do |el|
      next unless el.is_a?(Hash) && el['id'] && el['kind']
      map[el['id'].to_s] = el['kind'].to_s
    end
  end
  map
end

# Load discovery/chart-specs.json's 'control'-kind elements, GROUPED BY PAGE
# NAME (chart-specs pages are keyed by name, matching pages.json's own
# title). A Domo page-level filter/quick-filter is synthesized by
# build-workbook.rb (NOT owned by this file) from something OTHER than a
# card — confirmed live on a real Tier-2 page: element "ctl-order_status"
# (kind "control", name "ORDER STATUS") has NO corresponding entry in
# cards.json at all, so it would never reach this file's normal per-card
# kind resolution (element_kind_for). The caller (see $PROGRAM_NAME ==
# __FILE__) uses this to synthesize a pseudo-card for any such control so it
# still lands in the control band (composition_class :control) — see the
# "2a" file-header note. Returns { page_name => [{'id'=>, 'name'=>}, ...] };
# absent/unparsable file -> {} (never raises, same degrade-gracefully
# contract as load_chart_specs_kind_map).
def load_chart_specs_controls(dir)
  path = File.join(dir, 'chart-specs.json')
  return {} unless File.exist?(path)
  data = JSON.parse(File.read(path)) rescue nil
  return {} unless data.is_a?(Hash) && data['pages'].is_a?(Array)
  out = {}
  data['pages'].each do |p|
    pname = p['name']
    next unless pname
    ctrls = Array(p['elements']).select { |el| el.is_a?(Hash) && el['kind'] == 'control' && el['id'] && el['name'] }
    out[pname] = ctrls.map { |el| { 'id' => el['id'].to_s, 'name' => el['name'].to_s } } unless ctrls.empty?
  end
  out
end

# Final-review Important I1: load discovery/chart-specs.json's companion KPI
# elements (bead 08sf's "-summary" elements, built by build_summary_companion
# / eid(card, '-summary')), GROUPED BY PAGE NAME — same shape/contract as
# load_chart_specs_controls directly above, and for the SAME underlying
# reason: a companion KPI has no entry of its own in cards.json (it is
# synthesized inside build-workbook.rb from a card that's really a chart or
# table), so it would never reach this file's normal per-card kind resolution
# (element_kind_for) and would never get a layout zone at all — present in
# the workbook spec, but invisible on the migrated page. The caller (see
# $PROGRAM_NAME == __FILE__) synthesizes a pseudo-card for each one it finds,
# the exact same mechanism already used for an orphan control. Matched by the
# id suffix build_summary_companion always uses ("-summary") plus kind
# 'kpi-chart' so a coincidentally-named real KPI card is never mistaken for
# one. Returns { page_name => [{'id'=>, 'name'=>}, ...] }; absent/unparsable
# file -> {} (never raises, same degrade-gracefully contract as
# load_chart_specs_controls).
def load_chart_specs_companions(dir)
  path = File.join(dir, 'chart-specs.json')
  return {} unless File.exist?(path)
  data = JSON.parse(File.read(path)) rescue nil
  return {} unless data.is_a?(Hash) && data['pages'].is_a?(Array)
  out = {}
  data['pages'].each do |p|
    pname = p['name']
    next unless pname
    comps = Array(p['elements']).select do |el|
      el.is_a?(Hash) && el['kind'] == 'kpi-chart' && el['id'].to_s.end_with?('-summary') && el['name']
    end
    out[pname] = comps.map { |el| { 'id' => el['id'].to_s, 'name' => el['name'].to_s } } unless comps.empty?
  end
  out
end

# This card's best-known Sigma-ish kind string, per the priority above.
# `kind_map` keys on "el-<cardId>" — build-workbook.rb's own element-id
# convention for a card-derived element (confirmed against a live chart-specs
# capture: card id 390868622 -> element id "el-390868622").
def element_kind_for(card, kind_map)
  resolved = (kind_map[card['id'].to_s] || kind_map["el-#{card['id']}"]).to_s
  return resolved unless resolved.empty?
  hint = card['sigmaKindHint'].to_s
  return hint unless hint.empty?
  kind_hint(card['chartType'])
end

# Coarse composition BUCKET for a resolved kind string. Handles both the
# Sigma ELEMENT kind vocabulary ('kpi-chart', 'pivot-table', 'bar-chart',
# 'combo-chart', 'control', 'text'...) and kind_hint()'s own LOGICAL vocabulary
# ('kpi', 'table', 'filter', '*-chart') — element_kind_for's own fallback
# chain can produce either, and this must classify both without caring which.
def composition_class(kind)
  k = kind.to_s
  return :kpi if k.start_with?('kpi')
  return :table if k == 'table' || k == 'pivot-table'
  return :chart if k.end_with?('-chart')
  return :control if k == 'control' || k == 'filter'
  :other # text/title/anything else unrecognized — see header note
end

# The ZONE-level chart_kind tag for a kind-aware row (see build_dashboard's
# own kind_hint comment on why this must be the LOGICAL 'kpi', never the
# Sigma element kind 'kpi-chart' — lib/layout.rb's kpi_like_zone? matches on
# the bare 'kpi'). 'control' is normalized to 'filter' to match kind_hint()'s
# own vocabulary (only relevant for the :other bucket's callers); every other
# resolved kind (e.g. 'combo-chart', 'donut-chart', 'pivot-table') passes
# through UNCHANGED — min_rows_for_zone only special-cases 'kpi'/'table'/
# 'pivot-table' and floors everything else to the generic chart minimum, so a
# more specific tag here costs nothing and preserves more information.
def zone_chart_kind_for(card, kind_map)
  resolved = element_kind_for(card, kind_map).to_s
  return 'kpi' if resolved.start_with?('kpi')
  return 'filter' if resolved == 'control'
  resolved
end

# Balanced chunk sizes for splitting `n` items into groups of at most `max`,
# sizes differing by no more than 1 (remainder to the LAST groups) — the same
# balancing idea lib/layout.rb's reflow_bands already uses for re-flowing
# under-filled bands. Chosen over a greedy fixed-size chunk so a count like 7
# (max 6) never leaves a lone straggler (greedy: [6,1]; balanced: [3,4]).
def balanced_chunk_sizes(n, max)
  return [] if n <= 0
  nb = (n.to_f / max).ceil
  base = n / nb
  rem = n % nb
  Array.new(nb) { |i| base + (i >= nb - rem ? 1 : 0) }
end

# Even column-width split of Domo's native 6-col row for a KPI row of `n`
# members. A LONE kpi (n == 1, no peers to share a row with) is still capped
# at HALF width (divisor clamped to >= 2) rather than stretched full-row —
# WHAT TO BUILD #1 is explicit that a KPI must never read as a chart-sized
# band, and a full-width KPI (even at a short height) still reads that way.
def kpi_row_widths(n)
  divisor = [n, 2].max
  Array.new(n) { DOMO_GRID_COLS.to_f / divisor }
end

# Filter/control cards -> ONE full-width band, side by side, short height —
# ALWAYS first (see the file header / this section's own header note). Unlike
# a KPI row, a SOLE control legitimately spans the full band width — there is
# no "must never look chart-sized" constraint for a control the way there is
# for a KPI (kpi_row_widths's half-width floor), so a single control is not
# clamped to a half share.
def control_rows_for(cards)
  return [] if cards.empty?
  n = cards.length
  w = DOMO_GRID_COLS.to_f / n
  x = 0.0
  tagged = cards.map do |c|
    item = [c, x, w, 'filter', true]
    x += w
    item
  end
  [{ 'row' => tagged, 'height' => CONTROL_ROW_HEIGHT_UNITS }]
end

# KPI cards -> ROW(S) of up to KPI_MAX_PER_ROW, evenly split, short height.
# Returns { 'row' => [[card,x,w,chart_kind,is_filter], ...], 'height' => N }.
def kpi_rows_for(cards, kind_map)
  rows = []
  idx = 0
  balanced_chunk_sizes(cards.length, KPI_MAX_PER_ROW).each do |size|
    chunk = cards[idx, size]
    idx += size
    widths = kpi_row_widths(chunk.length)
    x = 0.0
    tagged = chunk.each_with_index.map do |c, i|
      w = widths[i]
      item = [c, x, w, zone_chart_kind_for(c, kind_map), false]
      x += w
      item
    end
    rows << { 'row' => tagged, 'height' => KPI_ROW_HEIGHT_UNITS }
  end
  rows
end

# Plotting-chart cards -> PAIRS of 2 (half width each); an odd trailing chart
# with no partner gets the full row width instead of a half-empty row.
def chart_pair_rows_for(cards, kind_map)
  cards.each_slice(2).map do |pair|
    tagged = if pair.length == 2
               [[pair[0], 0.0, DOMO_GRID_COLS / 2.0, zone_chart_kind_for(pair[0], kind_map), false],
                [pair[1], DOMO_GRID_COLS / 2.0, DOMO_GRID_COLS / 2.0, zone_chart_kind_for(pair[1], kind_map), false]]
             else
               [[pair[0], 0.0, DOMO_GRID_COLS.to_f, zone_chart_kind_for(pair[0], kind_map), false]]
             end
    { 'row' => tagged, 'height' => CHART_ROW_HEIGHT_UNITS }
  end
end

# Table/pivot cards -> each its OWN full-width row (never paired/batched —
# they need horizontal room, not a shared row), taller height.
def table_rows_for(cards, kind_map)
  cards.map do |c|
    { 'row' => [[c, 0.0, DOMO_GRID_COLS.to_f, zone_chart_kind_for(c, kind_map), false]],
      'height' => TABLE_ROW_HEIGHT_UNITS }
  end
end

# The :other bucket (filter/control/text/unrecognized) — out of scope for
# kind-aware composition (see this section's header note); reuses the
# pre-existing per-card token-default wrap_into_rows + kind_hint tagging
# UNCHANGED, just wrapped in the same { 'row' =>, 'height' => } shape as the
# kind-aware rows above so the caller can treat every row uniformly. A nil
# 'height' tells the caller to fall back to the per-card card_height_units
# max, exactly as build_dashboard_from_collections always has.
def other_rows_for(cards)
  return [] if cards.empty?
  wrap_into_rows(cards).map do |row|
    tagged = row.map do |c, x, w|
      kh = kind_hint(c['chartType'])
      [c, x, w, kh, kh == 'filter']
    end
    { 'row' => tagged, 'height' => nil }
  end
end

# Entry point: bucket a no-width-signal section's cards by composition class
# (order-preserving — Hash-of-arrays insertion order == first-seen order,
# and each bucket itself keeps the cards' relative _pageOrder since the
# caller already sorted them), then lay out each bucket with its own rule.
# Row order is the canonical "house style" band order — CONTROLS, then KPIs,
# then charts, then tables — confirmed against refs/layout-visual-qa.md's own
# "Building clean in the first place" table (Header -> Control row -> KPI row
# -> Chart row -> Detail table) rather than literal whole-page _pageOrder,
# since the source data itself is interleaved (KPI/chart/KPI/KPI/chart/KPI on
# a real validated instance page) and re-reading it kind-by-kind is the
# entire point of this fix (see the "2a" file-header note for why literal
# interleaving does not combine 4 separate KPIs into one row). Any leftover
# :other (text/unrecognized — not a named house-style band) trails last.
def compose_kind_aware_rows(cards, kind_map)
  buckets = Hash.new { |h, k| h[k] = [] }
  cards.each { |c| buckets[composition_class(element_kind_for(c, kind_map))] << c }
  control_rows_for(buckets[:control]) +
    kpi_rows_for(buckets[:kpi], kind_map) +
    chart_pair_rows_for(buckets[:chart], kind_map) +
    table_rows_for(buckets[:table], kind_map) +
    other_rows_for(buckets[:other])
end

# Build one dashboard's zone tree for a classic page: NO x/y/w/h anywhere,
# only `collections[]` (titled sections, cards grouped by index) and a T-shirt
# `size` token per card (see the file header for the live evidence and the
# field-name caveat). Every card in `cards` is placed — a card lacking both a
# collection and a size still lands in the trailing ungrouped section at its
# token-defaulted ('medium') width, never silently dropped.
#
# `kind_map` — optional "el-<cardId>" -> Sigma kind lookup (see
# load_chart_specs_kind_map); defaults to {} so every existing caller/test
# that predates this parameter keeps working unchanged (element_kind_for
# degrades gracefully through sigmaKindHint / kind_hint when a card's id has
# no entry).
def build_dashboard_from_collections(name, cards, kind_map = {})
  sections = group_into_sections(Array(cards))

  y = 0
  raw = []
  hdr_n = 0
  sections.each do |section|
    next if section['cards'].empty?
    if section['title']
      hdr_n += 1
      raw << { 'kind' => 'text', 'id' => "collection-#{hdr_n}", 'caption' => section['title'],
                'x' => 0, 'y' => y, 'w' => DOMO_GRID_COLS, 'h' => HEADER_ROW_UNITS }
      y += HEADER_ROW_UNITS
    end

    # rung 2a vs the original rung 2: only regroup-by-kind when NOTHING in
    # this section carries its own real width signal (see has_width_signal?
    # and the "2a" file-header note). A section with even one explicitly
    # sized card keeps the original per-card token-default wrap untouched —
    # unchanged byte-for-byte from before this fix (the `else` branch below).
    no_signal = section['cards'].none? { |c| has_width_signal?(c) }
    row_groups = if no_signal
                   compose_kind_aware_rows(section['cards'], kind_map)
                 else
                   wrap_into_rows(section['cards']).map do |row|
                     tagged = row.map do |c, x, w|
                       kh = kind_hint(c['chartType'])
                       [c, x, w, kh, kh == 'filter']
                     end
                     { 'row' => tagged, 'height' => nil }
                   end
                 end

    row_groups.each do |rg|
      row = rg['row']
      row_h = rg['height'] || row.map { |c, _x, _w, _ck, _f| card_height_units(c) }.max
      row.each do |c, x, w, chart_kind, is_filter|
        raw << {
          'kind' => is_filter ? 'filter' : 'chart', 'id' => c['id'], 'caption' => zone_caption_for(c, chart_kind),
          'chart_kind' => is_filter ? nil : chart_kind, 'x' => x, 'y' => y, 'w' => w, 'h' => row_h,
          'measures' => is_filter ? [] : ['value'],
        }
      end
      y += row_h
    end
  end
  return nil if raw.empty?

  total_h = y.zero? ? 1 : y
  zones = raw.map do |z|
    {
      'id'         => z['id'],
      'x_pct'      => (z['x'].to_f * 100.0 / DOMO_GRID_COLS).round(2),
      'y_pct'      => (z['y'].to_f * 100.0 / total_h).round(2),
      'w_pct'      => (z['w'].to_f * 100.0 / DOMO_GRID_COLS).round(2),
      'h_pct'      => (z['h'].to_f * 100.0 / total_h).round(2),
      'kind'       => z['kind'],
      'caption'    => z['caption'],
      'chart_kind' => z['chart_kind'],
      'measures'   => z['measures'] || [],
      'children'   => [],
    }.compact
  end
  { 'dashboard' => name, 'zone_tree' => zones, 'zones' => zones }
end

# ==== rung 3 — absolute last resort: no geometry signal of any kind ========
# No x/y/w/h, no preferredFullWidth/Height, no collections/size tokens — the
# exact "flat stack" fidelity bug this skill previously shipped (a partner
# migration's dashboard rendered as one vertical column). UNLIKE that
# regression, this path is never silent: it warns loudly every time it fires.
# The fallback chain above means a real Domo page should never actually reach
# here — classic pages carry sizes[]/collections[], mason/Domo-App pages
# carry x/y/w/h — so landing here usually means discovery came back
# degraded (e.g. Tier B / a failed private stacks() fetch), not that the page
# genuinely lacks layout information.
def build_stack_fallback(name, cards)
  cards = Array(cards)
  return nil if cards.empty?
  warn "  ⚠ WARNING: page #{name.inspect} has NO geometry signal of any kind " \
       '(no x/y/w/h, no preferredFullWidth/Height, no collections/size tokens) — ' \
       'falling back to a single-column vertical STACK. This is the exact flat-stack ' \
       'fidelity bug this skill previously shipped; verify domo-discover.rb reached the ' \
       'private GET /api/content/v3/stacks/{pageId}/cards endpoint (Tier A) for this page.'
  n = cards.length
  zones = cards.each_with_index.map do |c, i|
    kh = kind_hint(c['chartType'])
    is_filter = kh == 'filter'
    {
      'id'         => c['id'],
      'x_pct'      => 0.0,
      'y_pct'      => (i * 100.0 / n).round(2),
      'w_pct'      => 100.0,
      'h_pct'      => (100.0 / n).round(2),
      'kind'       => is_filter ? 'filter' : 'chart',
      'caption'    => zone_caption_for(c, kh),
      'chart_kind' => is_filter ? nil : kh,
      'measures'   => is_filter ? [] : ['value'],
      'children'   => [],
    }.compact
  end
  { 'dashboard' => name, 'zone_tree' => zones, 'zones' => zones }
end

# I1 (final review, Important): rung 1 (build_dashboard) filters its input to
# ONLY cards carrying real x/y/w/h — that's correct for genuine Domo cards
# (a real page reports pixel geometry for ALL of its cards or NONE of them,
# never a mix, live-validated), but a SYNTHESIZED pseudo-card (an orphan
# control, or bead 08sf's companion KPI — see the $PROGRAM_NAME == __FILE__
# block below) never carries geometry at all, so it silently falls out of
# rung 1's own filter and never gets a zone — even on a page whose real cards
# all have pixel geometry. Reuses the SAME "compose the remainder below the
# primary content" idea rung 1.5 (build_dashboard_with_observed) already
# applies to its own observed/unobserved split: run the geometry-less cards
# through the kind-aware composition (build_dashboard_from_collections) and
# append the result below whatever rung 1 already placed, proportionally
# rescaled into whatever page fraction is left. A no-op (returns `dash`
# unchanged) when every one of `cards` carried real geometry, which is true
# for every ordinary (non-synthesized) page today.
def append_geometryless_remainder(dash, cards, kind_map)
  # Scoped to cards THIS file itself synthesized (`_synthesized` — see the
  # main block below), never to an arbitrary real card that happens to carry
  # no geometry: a real Domo page reports pixel geometry for ALL of its cards
  # or NONE (live-validated), so a genuinely-geometry-less REAL card mixed in
  # among geometry-bearing ones is a degraded/partial capture, not a case
  # this remainder pass should rescue — it stays excluded from rung 1's
  # output, unchanged (see test-build-domo-layout.rb's NoGeom/_error case).
  synthesized = cards.select { |c| c['_synthesized'] }
  return dash if synthesized.empty?

  rest = build_dashboard_from_collections(dash['dashboard'], synthesized, kind_map)
  return dash unless rest

  dash_max_y = dash['zones'].map { |z| z['y_pct'].to_f + z['h_pct'].to_f }.max
  remaining_budget = [100.0 - dash_max_y, 20.0].max
  rest['zones'].each do |z|
    shifted = z.dup
    shifted['y_pct'] = (dash_max_y + z['y_pct'] / 100.0 * remaining_budget).round(2)
    shifted['h_pct'] = (z['h_pct'] / 100.0 * remaining_budget).round(2)
    # build_dashboard (rung 1) constructs 'zone_tree' and 'zones' as the SAME
    # array object (line 877: `'zone_tree' => zones, 'zones' => zones`), not
    # two independent lists — appending to both double-inserts every
    # synthesized zone (verified live: a companion KPI's elementId landed
    # TWICE in the merged layout XML, once degenerate zero-width). One append
    # reaches both keys.
    dash['zone_tree'] << shifted
  end
  dash
end

# Orchestrates the fallback chain for one page's cards, highest-fidelity rung
# first. Only returns nil when the page genuinely has zero cards. `kind_map`
# threads through to rung 2/1.5's kind-aware composition (see
# build_dashboard_from_collections); `observed` (the FULL layout-observed.json
# map, pre-filtered internally to this page's cards) threads through to rung
# 1.5 (build_dashboard_with_observed). Both default to {} so every caller/test
# that predates these parameters keeps working unchanged.
def build_dashboard_for_page(name, cards, kind_map = {}, observed = {})
  cards = Array(cards)
  return nil if cards.empty?

  dash = build_dashboard(name, cards) # rung 1: genuine x/y/w/h pixel geometry
  return append_geometryless_remainder(dash, cards, kind_map) if dash

  unless observed.empty?
    dash = build_dashboard_with_observed(name, cards, observed, kind_map) # rung 1.5: operator-authored
    return dash if dash
  end

  has_collection_signal = cards.any? do |c|
    c['_collection'] || c['_size'] || c.key?('_pageOrder') || c['preferredFullWidth'] || c['preferredFullHeight']
  end
  return build_dashboard_from_collections(name, cards, kind_map) if has_collection_signal

  build_stack_fallback(name, cards) # rung 3: last resort, warns loudly
end

# F3 (blocker 3, 2026-08-05 batch-verify): this MUST resolve a page's default
# name IDENTICALLY to build-workbook.rb's own group_cards_by_page — a
# mismatch here silently drops layout zones. load_chart_specs_companions /
# load_chart_specs_controls (above) key the companion-KPI/control lookup by
# page NAME, and build-dashboard-layout.rb matches a workbook page to a
# layout dashboard by that same name; if this file falls back to the literal
# 'Overview' while build-workbook.rb attributes the same cardIds-less page to
# its REAL title, every companion/control lookup here misses. Measured on the
# real cold run (page 'Sample DataSets + Cards', pages.json's cardIds: []):
# name-matched = 50 zones with the 5 real bead-08sf companion KPIs; as-landed
# (this file still hard-coded 'Overview') = 45 zones, 0 companion KPIs — all 5
# companion elements POSTed but invisible, no layout zone at all. Verbatim
# same default-name resolution as build-workbook.rb's group_cards_by_page
# (kept as a separate function, not a shared require, matching this
# codebase's existing per-script duplication of small helpers); see
# test/test-build-domo-layout.rb's cross-file consistency test, which calls
# both functions with the same inputs and asserts they agree.
def group_cards_by_page_for_layout(cards, pages)
  by_page = Hash.new { |h, k| h[k] = [] }
  card_page = {}
  pages.each do |p|
    Array(p['cardIds'] || p['cards']).each { |cid| card_page[cid.to_s] = p['title'] || p['name'] || p['id'] }
  end
  default_name =
    if pages.size == 1
      pages.first['title'] || pages.first['name'] || pages.first['id'].to_s
    else
      'Overview'
    end
  cards.each { |c| by_page[card_page[c['id'].to_s] || default_name] << c }
  by_page
end

if $PROGRAM_NAME == __FILE__
  cards = JSON.parse(File.read(File.join(OUT, 'cards.json'))) rescue []
  pages = JSON.parse(File.read(File.join(OUT, 'pages.json'))) rescue []

  cards = cards.reject { |c| c['_error'] || c['_tierB'] }

  # Element-kind lookup for the kind-aware composition (file header "2a") —
  # discovery/chart-specs.json may not exist yet (e.g. layout built before
  # build-workbook.rb ran); load_chart_specs_kind_map degrades to {} rather
  # than raising, and element_kind_for falls back to sigmaKindHint/chartType.
  kind_map = load_chart_specs_kind_map(OUT)

  # Operator-observed geometry (file header "1.5") — a human-authored sidecar,
  # never written by this script. Absent file -> {} (rung 1.5 never fires;
  # every existing offline/live run that has no such sidecar is unaffected).
  observed_layout = load_observed_layout(OUT)
  unless observed_layout.empty?
    known_ids = cards.map { |c| c['id'].to_s }
    unmatched = observed_layout.keys - known_ids
    unmatched.each do |bad_id|
      warn "  ⚠ discovery/layout-observed.json key #{bad_id.inspect} matches NO card id in " \
           'discovery/cards.json — typo, or a stale sidecar from a re-numbered page? (ignored)'
    end
  end

  # Group cards by page — same membership resolution (AND the same default-
  # name fallback — F3/blocker 3) build-workbook.rb uses, so a page's layout
  # dashboard and its workbook page carry the SAME cards under the SAME name.
  by_page = group_cards_by_page_for_layout(cards, pages)

  # Synthesize a pseudo-card for any chart-specs.json 'control' element that
  # has NO backing card at all (file header "2a" note — a page-level filter
  # build-workbook.rb derives independently of any card, e.g. real Tier-2
  # element "ctl-order_status"). Without this, such a control never reaches
  # composition_class at all (it isn't in cards.json), so it would never join
  # the control band — this is the concrete mechanism that gets it there,
  # keyed by NAME (not id) so downstream zone_el_name/assign_controls
  # matching still resolves it to the real control element.
  orphan_controls_by_page = load_chart_specs_controls(OUT)
  # I1 (final review, Important): a companion KPI element (bead 08sf) has no
  # card of its own either — same problem as an orphan control immediately
  # above, same fix. It lands wherever this file's kind-aware composition
  # puts any other 'kpi-chart' element (the page's shared KPI band) rather
  # than truly beside its own primary chart/table — the kind-grouped
  # composition model (build_dashboard_from_collections's rung 2a) buckets
  # ALL kpi-kind elements into one shared row regardless of which card
  # produced them, so per-primary adjacency isn't a placement this model can
  # express. Landing in the KPI band (a real, deliberate placement) beats not
  # landing anywhere at all.
  orphan_companions_by_page = load_chart_specs_companions(OUT)
  # PageLayoutV4 non-card content is authored page content, not furniture:
  # discovery preserved HEADER/PAGE_BREAK geometry on pages.json and
  # build-workbook emitted matching text/page-break elements with these ids.
  pages.each do |page|
    pname = page['title'] || page['name'] || page['id'].to_s
    Array(page['_layoutContent']).each do |content|
      next unless %w[header page-break].include?(content['type'])
      title = content['text'].to_s.strip
      title = 'Page break' if title.empty?
      by_page[pname] << {
        'id' => content['id'],
        'title' => title,
        'chartType' => content['type'],
        'sigmaKindHint' => (content['type'] == 'header' ? 'text' : 'page-break'),
        'x' => content['x'], 'y' => content['y'], 'w' => content['w'], 'h' => content['h'],
        '_synthesized' => true
      }
    end
  end
  by_page.each do |pname, pcards|
    card_el_ids = pcards.map { |c| "el-#{c['id']}" }
    Array(orphan_controls_by_page[pname]).each do |ctl|
      next if card_el_ids.include?(ctl['id'])
      pcards << { 'id' => ctl['id'], 'title' => ctl['name'], 'chartType' => 'filter',
                  'sigmaKindHint' => 'control', '_size' => '', '_pageOrder' => -1, '_synthesized' => true }
    end
    Array(orphan_companions_by_page[pname]).each do |comp|
      next if card_el_ids.include?(comp['id'])
      primary_card_id = comp['id'].to_s[/\Ael-(.+)-summary\z/, 1]
      pcards << { 'id' => comp['id'], 'title' => comp['name'], 'chartType' => 'badge_singlevalue',
                  'sigmaKindHint' => 'kpi-chart', '_size' => '', '_pageOrder' => -1,
                  '_synthesized' => true, '_primary_card_id' => primary_card_id }
    end
  end

  dashboards = by_page.map { |pname, pcards| build_dashboard_for_page(pname, pcards, kind_map, observed_layout) }.compact
  abort("  no cards at all in #{File.join(OUT, 'cards.json')} for any page — " \
        'run domo-discover.rb --pages <ids> first (its merge_geometry copies the ' \
        'private-API page layout — or, for classic pages, collections/size tokens — ' \
        'onto each card); an image/PNG capture is not required.') if dashboards.empty?

  FileUtils.mkdir_p(OUT)
  out = File.join(OUT, 'dashboard-layout.json')
  File.write(out, JSON.pretty_generate(dashboards))
  warn "  wrote #{out} (#{dashboards.size} dashboard(s), #{dashboards.sum { |d| d['zones'].size }} zones)"
  warn "  ⚠ dashboard names must match the workbook page names; ensure a 'Data' page exists in wb-ids."
end
