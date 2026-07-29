#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-ws5-tabbed-e2e.rb — LIVE GO/NO-GO probe for WS5 (docs/superpowers/
# specs/2026-07-29-ws5-tabbed-container-design.md, Task 3). Creds-gated: needs
# a live Sigma org + a read connection, so it is NOT part of the offline CI
# corpus (same class as verify-ws4-e2e.rb, which this script mirrors
# structurally — home-folder/schemaVersion resolution, the POST-spec
# YAML-or-JSON response parse, and the sigma-export-png.py render helper are
# all copied from there, not re-derived).
#
# THE SURFACE UNDER TEST: Composition.tabbed_container (shared/lib/
# composition.rb) — a `kind:"tabbed-container"` page element + its
# `<TabbedContainer>`/`<Tab>` layout XML. This probe builds ONE workbook, ONE
# page, with a single tabbed_container of 2 tabs:
#   Tab 1 "Table"  — a `table` element listing the raw demo rows.
#   Tab 2 "Chart"  — a `bar-chart` element, revenue by category.
# Both elements source from ONE base table (`src`), itself sourced from
# ENV['SIGMA_TEST_CONNECTION_ID'] via a small deterministic custom-SQL demo
# dataset (same shape discipline as verify-ws4-e2e.rb's DEMO_SQL — no
# customer/personal/company names). Each tab's `inner` layout is built with
# Composition.band/Composition.le (bare LayoutElements — no nested
# GridContainer inside a <Tab>, per the verified gotcha).
#
# Usage:  ruby shared/scripts/verify-ws5-tabbed-e2e.rb
# Env (ALL from ENV; this script NEVER hardcodes a connection/org/workbook id
# — the hygiene-sweep gate blocks literal test-org ids in tracked files):
#   SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (or SIGMA_API_TOKEN,
#     or ~/.sigma-migration/env — sigma_rest.rb self-bootstraps from there).
#   SIGMA_TEST_CONNECTION_ID  — a READ connection (source table's warehouse).
# Missing creds OR the connection id ⇒ this script SKIPS cleanly (exit 0, a
# clear "SKIP:" message), never a faked pass.
# Exit: 0 = the probe ran to completion (POST + readback + render all
#   attempted; per-element structural verdicts printed — visual confirmation
#   of the render is the calling agent's job, same discipline as the other
#   verify-*-e2e.rb scripts) OR a clean SKIP. 1 = the probe itself could not
#   complete (e.g. the workbook never POSTed) — a hard failure, never green.

require 'json'
require 'time'
require 'fileutils'
require 'shellwords'
require 'tmpdir'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sigma_rest'
require 'composition'

def log(msg)
  $stderr.puts("[verify-ws5-tabbed-e2e] #{msg}")
end

def skip!(msg)
  puts "SKIP: #{msg}"
  log "SKIP: #{msg}"
  exit 0
end

# --- creds + ENV gate (never hardcode; skip cleanly, never fake a pass) -----
unless ENV['SIGMA_BASE_URL'].to_s != '' &&
       (ENV['SIGMA_API_TOKEN'].to_s != '' || (ENV['SIGMA_CLIENT_ID'].to_s != '' && ENV['SIGMA_CLIENT_SECRET'].to_s != ''))
  skip!('no Sigma credentials in ENV or ~/.sigma-migration/env — set SIGMA_BASE_URL + ' \
        'SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (or SIGMA_API_TOKEN) to run this live probe.')
end

CONNECTION_ID = ENV['SIGMA_TEST_CONNECTION_ID'].to_s
if CONNECTION_ID.empty?
  skip!('SIGMA_TEST_CONNECTION_ID not set in ENV — this probe never hardcodes a connection id ' \
        '(hygiene-sweep gate); export a read connection id (e.g. a small EXAMPLES warehouse table\'s ' \
        'connection) and re-run.')
end

RUN_TAG = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')

PG_MAIN = 'pg-main'
SRC_ID  = 'src'
TAB_TABLE_ID = 'tab-table'
TAB_CHART_ID = 'tab-chart'
TC_ID = 'tc'

# Generic synthetic demo data (region/category/revenue) — no customer/
# personal/company names, same shape discipline as verify-ws4-e2e.rb's
# DEMO_SQL. Small and deterministic; enough rows for a real table + a real
# grouped bar chart.
DEMO_SQL = <<~SQL.strip
  WITH RECURSIVE seq(i) AS (
    SELECT 0
    UNION ALL
    SELECT i + 1 FROM seq WHERE i < 19
  ),
  dims AS (
    SELECT * FROM (VALUES
      ('North', 'Widgets', 1.00),
      ('South', 'Widgets', 0.80),
      ('North', 'Gadgets', 0.60),
      ('South', 'Gadgets', 0.50)
    ) AS t(region, category, mult)
  )
  SELECT
    dims.region,
    dims.category,
    ROUND((500 + MOD(seq.i, 10) * 40) * dims.mult, 2) AS revenue
  FROM seq CROSS JOIN dims
SQL

ALIASES = %w[region category revenue].freeze
DISPLAY = { 'region' => 'Region', 'category' => 'Category', 'revenue' => 'Revenue' }.freeze

# ---------------------------------------------------------------------------
# Shared helpers (same pattern as verify-ws4-e2e.rb).
# ---------------------------------------------------------------------------

def home_folder_id
  me = Sigma.request(:get, '/v2/whoami')
  uid = me && me['userId']
  raise 'could not resolve userId from /v2/whoami' unless uid
  mem = Sigma.request(:get, "/v2/members/#{uid}")
  home = mem && mem['homeFolderId']
  raise 'could not resolve homeFolderId' unless home
  home
end

def reference_schema_version
  wbs = Sigma.request(:get, '/v2/workbooks?limit=10')
  entries = (wbs && (wbs['entries'] || wbs['workbooks'])) || []
  entries.each do |w|
    wid = w['workbookId'] || w['id']
    next unless wid
    spec = (Sigma.request(:get, "/v2/workbooks/#{wid}/spec", accept: 'application/json') rescue nil)
    return spec['schemaVersion'] if spec.is_a?(Hash) && spec['schemaVersion']
  end
  raise 'could not discover schemaVersion from any existing workbook'
end

# POST /v2/workbooks/spec: response is documented as YAML. Request a
# non-JSON accept so the raw string always comes back, then self-parse (JSON
# first in case the org actually returns JSON, else scrape `workbookId:` out
# of the YAML text) — same discipline as verify-ws4-e2e.rb.
def post_workbook_spec(spec_hash)
  raw = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec_hash),
                                                    content_type: 'application/json', accept: 'application/yaml')
  parsed = (JSON.parse(raw) rescue nil)
  return parsed['workbookId'] if parsed.is_a?(Hash) && parsed['workbookId']
  m = raw.to_s.match(/^\s*workbookId:\s*"?'?([\w-]+)"?'?\s*$/)
  raise "no workbookId in POST response: #{raw.to_s[0, 600]}" unless m
  m[1]
end

def render_png(wb, out_path, page_id: nil, w: 1600, h: 1200)
  png_script = File.expand_path('sigma-export-png.py',
                                 File.join(__dir__, '..', '..', 'plugins', 'tableau-to-sigma', 'skills',
                                            'tableau-to-sigma', 'scripts'))
  cmd = ['python3', png_script, '--workbook', wb, '--out', out_path, '--w', w.to_s, '--h', h.to_s]
  cmd += ['--page', page_id] if page_id
  out = `#{cmd.map { |c| Shellwords.escape(c) }.join(' ')} 2>&1`
  ok = $?.success? && File.exist?(out_path)
  { ok: ok, path: (ok ? out_path : nil), log: out.to_s[0, 800] }
end

# ---------------------------------------------------------------------------
# Spec construction — the tabbed-container element + its layout come ENTIRELY
# from Composition.tabbed_container (the helper under test); this script
# never hand-inlines a <TabbedContainer>/<Tab> shape.
# ---------------------------------------------------------------------------

def build_spec(home, schema_version)
  src_cols = ALIASES.map { |a| { 'id' => "c_#{a}", 'name' => DISPLAY[a], 'formula' => "[Custom SQL/#{a}]" } }
  src = { 'id' => SRC_ID, 'kind' => 'table', 'name' => 'Src',
          'source' => { 'kind' => 'sql', 'connectionId' => CONNECTION_ID, 'statement' => DEMO_SQL },
          'columns' => src_cols }

  tab_table = { 'id' => TAB_TABLE_ID, 'kind' => 'table', 'name' => 'Raw rows',
                'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
                'columns' => [
                  { 'id' => 'tt-region', 'name' => 'Region', 'formula' => '[Src/Region]' },
                  { 'id' => 'tt-category', 'name' => 'Category', 'formula' => '[Src/Category]' },
                  { 'id' => 'tt-revenue', 'name' => 'Revenue', 'formula' => '[Src/Revenue]' }
                ] }

  tab_chart = { 'id' => TAB_CHART_ID, 'kind' => 'bar-chart', 'name' => 'Revenue by Category',
                'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
                'columns' => [
                  { 'id' => 'tc-cat', 'name' => 'Category', 'formula' => '[Src/Category]' },
                  { 'id' => 'tc-rev', 'name' => 'Revenue', 'formula' => 'Sum([Src/Revenue])' }
                ],
                'xAxis' => { 'columnId' => 'tc-cat' },
                'yAxis' => { 'columnIds' => ['tc-rev'] },
                'stacking' => 'none' }

  # ==== SURFACE under test: Composition.tabbed_container ===================
  # Composition.band returns an Array of <LayoutElement> lines — join into
  # the single XML string `inner` expects (a tab holding more than one band
  # would join multiple band() calls the same way).
  tabbed = Composition.tabbed_container(
    id: TC_ID,
    tabs: [
      { name: 'Table', inner: Composition.band([{ id: TAB_TABLE_ID }], 1, 20, 24).join("\n") },
      { name: 'Chart', inner: Composition.band([{ id: TAB_CHART_ID }], 1, 20, 24).join("\n") }
    ],
    grid_column: '1 / 25', grid_row: '2 / 24'
  )

  pg_main_layout = <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="#{PG_MAIN}">
    #{tabbed[:layout]}
    </Page>
  XML

  {
    'name' => "WS5 tabbed-container probe — E2E proof (#{RUN_TAG})",
    'folderId' => home,
    'schemaVersion' => schema_version,
    'description' => 'Live GO/NO-GO proof of WS5 Composition.tabbed_container: a 2-tab ' \
                      'tabbed-container (table tab, bar-chart tab) sourced from one base table. ' \
                      'Throwaway test artifact.',
    'pages' => [
      { 'id' => PG_MAIN, 'name' => 'Overview',
        'elements' => [src, tab_table, tab_chart, tabbed[:element]] }
    ],
    # layout is a single WORKBOOK-TOP-LEVEL field (sibling of `pages`) — see
    # verify-ws4-e2e.rb's comment on this same discovery; a per-page `layout`
    # key is silently ignored and replaced by Sigma's own auto-arrange.
    'layout' => pg_main_layout
  }
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SCRATCH = ENV.fetch('SCRATCH_DIR', Dir.tmpdir)
FileUtils.mkdir_p(SCRATCH)

verdict = { probe_completed: false }

begin
  home = home_folder_id
  schema_version = reference_schema_version
  log "home folder=#{home} schemaVersion=#{schema_version}"

  spec = build_spec(home, schema_version)
  wb = post_workbook_spec(spec)
  raise 'no workbookId returned from POST' if wb.to_s.empty?
  workbook_url = "#{ENV['SIGMA_BASE_URL']}/workbook/#{wb}"
  log "workbook #{wb} (#{workbook_url})"

  # --- structural (GET) readback ------------------------------------------
  spec_back = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
  els = spec_back['pages'].flat_map { |p| p['elements'] || [] }
  find_el = ->(id) { els.find { |e| e['id'] == id } }

  tc_back    = find_el.call(TC_ID)
  table_back = find_el.call(TAB_TABLE_ID)
  chart_back = find_el.call(TAB_CHART_ID)

  surfaces = {
    'Composition.tabbed_container element (2 labels + tabBar)' => {
      post_accepted: !!(tc_back && tc_back['kind'] == 'tabbed-container' &&
                         tc_back['tabs'] == [{ 'name' => 'Table' }, { 'name' => 'Chart' }] &&
                         tc_back.dig('tabBar', 'alignment') == 'start'),
      render_hint: 'Read the pg-main render — a tab bar should be visible near the top of the ' \
                    'container reading "Table" and "Chart", with one tab active.'
    },
    'Tab 1 content (table element)' => {
      post_accepted: !!(table_back && table_back['kind'] == 'table'),
      render_hint: 'If "Table" is the active tab in the render, the region below the tab bar should ' \
                    'show a real table with Region/Category/Revenue columns and populated rows.'
    },
    'Tab 2 content (bar-chart element)' => {
      post_accepted: !!(chart_back && chart_back['kind'] == 'bar-chart'),
      render_hint: 'Only the active tab renders in a static export — if "Chart" is not the default ' \
                    'active tab this element will not be visible in the pg-main render; that is ' \
                    'expected, not a failure. Structural POST-accept above is the signal for this tab.'
    }
  }

  # --- render ----------------------------------------------------------
  page_main_png = File.join(SCRATCH, "ws5-tabbed-e2e-#{RUN_TAG}-pg-main.png")
  render_main = render_png(wb, page_main_png, page_id: PG_MAIN, w: 1600, h: 1000)

  log "render pg-main: ok=#{render_main[:ok]} path=#{render_main[:path]} #{render_main[:ok] ? '' : render_main[:log]}"

  verdict = {
    probe_completed: true,
    workbook_id: wb,
    workbook_url: workbook_url,
    render_pg_main_png: render_main[:path],
    render_ok: { pg_main: render_main[:ok] },
    surfaces: surfaces
  }
rescue StandardError => e
  verdict = { probe_completed: false, fatal_error: "#{e.class}: #{e.message}", backtrace: e.backtrace&.first(15) }
  log "FATAL — probe did not complete: #{e.class}: #{e.message}"
end

puts
puts '=' * 78
puts verdict[:probe_completed] ? 'PROBE COMPLETED (per-surface POST-accept below — RENDER is a visual read ' \
                                  'the calling agent must do honestly against the PNG, never auto-claimed here)' :
                                  'PROBE FAILED (fatal)'
puts '=' * 78
if verdict[:probe_completed]
  puts "workbook_id: #{verdict[:workbook_id]}"
  puts "workbook_url: #{verdict[:workbook_url]}"
  puts
  puts format('%-55s %-8s', 'SURFACE', 'POST')
  verdict[:surfaces].each do |name, v|
    puts format('%-55s %-8s', name, v[:post_accepted] ? 'PASS' : 'FAIL')
  end
  puts
  puts "render pg-main: ok=#{verdict[:render_ok][:pg_main]} -> #{verdict[:render_pg_main_png]}"
  puts
end
puts JSON.pretty_generate(verdict)
exit(verdict[:probe_completed] ? 0 : 1)
