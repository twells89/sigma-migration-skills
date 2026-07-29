#!/usr/bin/env ruby
# Phase 1b — visual capture for domo-to-sigma.
#
#   ruby scripts/domo-capture-visuals.rb --pages 123,456
#   ruby scripts/domo-capture-visuals.rb --pages 123 --no-pdf      # skip page PDF
#   ruby scripts/domo-capture-visuals.rb --cards 789,790           # render specific cards
#
# WHY THIS EXISTS
# A Domo migration that only reads DataSets + chart-type strings rebuilds
# dashboards from guesses, and the output looks generically templated (the
# "design still a big issue" feedback). This script captures a VISUAL
# reference — a true PNG per card + a full-page PDF, fed to the build step and
# the MANDATORY layout-visual-qa gate (compare Sigma render <-> Domo source,
# page-to-page). See shared refs/layout-visual-qa.md,
# feedback_phase1d_dashboard_png, batch_converter_png_brief.
#
# This is the automated upgrade of the old Tier-B "manually export each card as
# PNG" fallback in refs/connection.md — it needs the private dev token (Tier A).
#
# NOTE on layout geometry: this script used to ALSO extract card x/y/w/h into
# discovery/layout/<pageId>.json (normalize_layout). That path was a dead end —
# domo-discover.rb's --pages run never read it, so a migration's real card
# coordinates never reached build-domo-layout.rb (it auto-stacked instead).
# Task 1 (lib/domo_sigma_util.rb's DomoSigma.merge_geometry) now copies the
# SAME private-API page-layout geometry directly onto discovery/cards.json
# during domo-discover.rb --pages, which build-domo-layout.rb reads. That is
# the ONE geometry source; this script no longer extracts or emits geometry —
# it only stages PNG/PDF visual references.
#
# Prereqs (see refs/connection.md):
#   export DOMO_INSTANCE=acme DOMO_DEV_TOKEN=...
#   export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=...   # for public page() lookup
#   eval "$(scripts/get-domo-token.sh)"                     # sets DOMO_ACCESS_TOKEN
#
# Outputs:
#   discovery/png/cards/<cardId>.png   per-card visual reference
#   discovery/png/pages/<pageId>.pdf   full-page source reference (for QA gate)

require 'json'
require 'fileutils'
require 'optparse'
require_relative 'lib/domo_rest'

OUT       = File.expand_path('../discovery', __dir__)
CARD_PNG  = File.join(OUT, 'png', 'cards')
PAGE_PDF  = File.join(OUT, 'png', 'pages')
[CARD_PNG, PAGE_PDF].each { |d| FileUtils.mkdir_p(d) }

opts = { pdf: true }
OptionParser.new do |o|
  o.on('--pages IDS', Array) { |v| opts[:pages] = v }
  o.on('--cards IDS', Array) { |v| opts[:cards] = v }
  o.on('--no-pdf')           { opts[:pdf] = false }
  o.on('--width N', Integer) { |v| opts[:width]  = v }
  o.on('--height N', Integer){ |v| opts[:height] = v }
end.parse!(ARGV)

if Domo.dev_token.nil?
  warn <<~MSG
    DOMO_DEV_TOKEN is unset => TIER B (public API only).
    Visual capture requires the private render endpoint, so it is not
    available. Fall back to the manual path in refs/connection.md:
      - export each card as a PNG from the Domo UI,
      - drop them in discovery/png/cards/ named <cardId>.png,
      - capture the full page (UI "Export to PDF") into discovery/png/pages/.
    Then read those images during build + the layout-visual-qa gate.
  MSG
  exit 3
end

WIDTH  = opts[:width]  || 1000
HEIGHT = opts[:height] || 700

# Card ids for a page, from the PUBLIC page() response — the same field
# domo-discover.rb reads (`page['cardIds'] || page['cards']`). No private-API
# layout call is needed here anymore; geometry lives solely in cards.json via
# domo-discover.rb's merge_geometry.
def page_card_ids(public_page)
  Array(public_page['cardIds'] || public_page['cards']).map do |c|
    c.is_a?(Hash) ? (c['id'] || c['cardId'] || c['urn']) : c
  end.compact
end

def write_bytes(path, bytes)
  return warn("  SKIP #{File.basename(path)} (empty render)") if bytes.nil? || bytes.empty?
  File.binwrite(path, bytes)
  warn "  wrote #{path} (#{bytes.bytesize} bytes)"
end

def capture_card(card_id)
  png = Domo.render_card_png(card_id, width: WIDTH, height: HEIGHT)
  write_bytes(File.join(CARD_PNG, "#{card_id}.png"), png)
rescue => e
  warn "  render FAIL card #{card_id}: #{e.message}"
end

# --- per-page capture -------------------------------------------------------
if opts[:pages]
  opts[:pages].each do |pid|
    warn "page #{pid}:"
    public_page = (Domo.page(pid) rescue {}) || {}
    card_ids    = page_card_ids(public_page)
    warn "  #{card_ids.size} card(s)"

    card_ids.each { |cid| capture_card(cid) }

    if opts[:pdf]
      # Full-page reference for the layout-visual-qa source-fidelity comparison.
      # Domo renders a page-to-PDF; if the instance lacks a page-level render,
      # fall back to a per-card PDF of the first card so something exists.
      # TODO(on-access): confirm the page-PDF endpoint path/params.
      begin
        pdf = Domo.private_put_raw("/api/content/v1/pages/#{pid}/render",
                                   body: { width: 1600 }, query: { parts: 'imagePDF' })
        write_bytes(File.join(PAGE_PDF, "#{pid}.pdf"), pdf && Domo.decode_render(pdf))
      rescue => e
        warn "  page PDF unavailable (#{e.message}) — rely on per-card PNGs for QA"
      end
    end
  end
end

# --- explicit card list -----------------------------------------------------
if opts[:cards]
  warn 'cards:'
  opts[:cards].each { |cid| capture_card(cid) }
end

unless opts[:pages] || opts[:cards]
  abort 'nothing to do — pass --pages <ids> and/or --cards <ids>'
end

warn "\nNext: run domo-discover.rb --pages <ids> for cards.json geometry (merge_geometry),"
warn "then build-domo-layout.rb. READ discovery/png/** during build + the mandatory"
warn "layout-visual-qa gate."
