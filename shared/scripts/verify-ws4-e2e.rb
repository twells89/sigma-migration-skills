#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-ws4-e2e.rb — LIVE GO/NO-GO probe for WS4 (docs/superpowers/specs/
# 2026-07-29-ws4-agent-gradient-actions-design.md, Task 6). Creds-gated: needs
# a live Sigma org + a read connection + a write-enabled connection, so it is
# NOT part of the offline CI corpus (same class as
# verify-richness-surfaces-e2e.rb / verify-styling-surfaces-e2e.rb, which this
# script mirrors structurally — home-folder/schemaVersion resolution, the
# POST/PUT-spec YAML-or-JSON response parse, and the sigma-export-png.py
# render helper are all copied from those, not re-derived).
#
# UNLIKE the richness/styling probes, this script builds its workbook ENTIRELY
# from the shared-lib helpers under test (Richness.agent/chat,
# Styling.gradient_header/gradient_card/sparkline, Actions.*, plus the
# already-shipped KpiCard.build) — it never hand-inlines a shape those
# helpers already emit. The reference build this mirrors is
# scratchpad/build-plugs-command-center.rb (a real Plugs-data command center
# using the same helpers pre-refactor); this probe is deliberately generic
# (no product/company theming) since it is a shared-lib regression gate, not
# a demo.
#
# THE SURFACES UNDER TEST (one workbook, four pages):
#   pg-main    — Styling.gradient_header (:glow motif, the "hero" case) +
#                two comparative KPI cards (KpiCard.build) each wrapped in
#                Styling.gradient_card + a Styling.sparkline underneath +
#                Richness.agent/chat (a read-only analyst + its chat rail).
#   pg-actions — Styling.gradient_header (:rings motif, a second live motif
#                in a real page-header context) + Actions.input_table_empty
#                (an append-only review log) + Actions.input_table_linked
#                (write-back category targets, keyed off a read-only pivot on
#                the DIFFERENT read connection) + an entry text-area control
#                + three Actions.button instances, one per verified effect
#                (insert_rows_effect / clear_control_effect /
#                set_control_value_effect).
#   pg-motifs  — a small side-by-side gallery: Styling::MOTIFS :glow and
#                :rings again (smaller, for a direct visual A/B) plus ONE
#                bring-your-own image (a caller-supplied data: URI SVG passed
#                verbatim as `motif:`, per gradient_header's documented
#                bring-your-own path — this is NOT a MOTIFS library key, it
#                REPLACES the whole gradient+motif background).
#   pg-data    — hidden; the source table + the read-only category pivot that
#                feeds the linked input table.
#
# Usage:  ruby shared/scripts/verify-ws4-e2e.rb
# Env (ALL from ENV; this script NEVER hardcodes a connection/org/workbook id
# — the hygiene-sweep gate blocks literal test-org ids in tracked files):
#   SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (or SIGMA_API_TOKEN,
#     or ~/.sigma-migration/env — sigma_rest.rb self-bootstraps from there).
#   SIGMA_TEST_CONNECTION_ID  — a READ connection (source table's warehouse).
#   SIGMA_WRITE_CONNECTION_ID — a write-enabled connection (input tables).
# Missing creds OR either connection id ⇒ this script SKIPS cleanly (exit 0,
# a clear "SKIP:" message), never a faked pass.
# Exit: 0 = the probe ran to completion (POST + readback + render all
#   attempted; per-surface structural verdicts printed — visual confirmation
#   of the render is the calling agent's job, same discipline as the other
#   verify-*-e2e.rb scripts) OR a clean SKIP. 1 = the probe itself could not
#   complete (e.g. the workbook never POSTed) — a hard failure, never green.

require 'json'
require 'time'
require 'base64'
require 'fileutils'
require 'shellwords'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sigma_rest'
require 'kpi_card'
require 'richness'
require 'styling'
require 'actions'

def log(msg)
  $stderr.puts("[verify-ws4-e2e] #{msg}")
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
WRITE_CONNECTION_ID = ENV['SIGMA_WRITE_CONNECTION_ID'].to_s
if CONNECTION_ID.empty? || WRITE_CONNECTION_ID.empty?
  skip!('SIGMA_TEST_CONNECTION_ID and/or SIGMA_WRITE_CONNECTION_ID not set in ENV — this probe ' \
        'never hardcodes connection ids (hygiene-sweep gate); export both (a read connection and a ' \
        'write-enabled connection) and re-run.')
end

RUN_TAG = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')

PG_MAIN    = 'pg-main'
PG_ACTIONS = 'pg-actions'
PG_MOTIFS  = 'pg-motifs'
PG_DATA    = 'pg-data'

SRC_ID  = 'src'
CAT_PIVOT_ID = 'cat-pivot'

NOTE_CTL_ID     = 'note-ctl'
NOTE_CTL_HANDLE = 'NoteCtl'

# Generic synthetic demo data (region/category/revenue/orders/margin + a real
# DATE column, 90 consecutive days) — no customer/personal/company names, same
# shape discipline as verify-richness-surfaces-e2e.rb's DEMO_SQL. Two regions x
# two categories gives the KPI/pivot/linked-table surfaces genuine grouping
# structure to work with.
DEMO_SQL = <<~SQL.strip
  WITH RECURSIVE seq(i) AS (
    SELECT 0
    UNION ALL
    SELECT i + 1 FROM seq WHERE i < 89
  ),
  days AS (
    SELECT DATEADD(day, i, DATE '2026-01-01') AS d, i FROM seq
  ),
  dims AS (
    SELECT * FROM (VALUES
      ('North', 'Widgets',  1.00),
      ('South', 'Widgets',  0.80),
      ('North', 'Gadgets',  0.60),
      ('South', 'Gadgets',  0.50)
    ) AS t(region, category, mult)
  )
  SELECT
    days.d AS date,
    dims.region,
    dims.category,
    ROUND((800 + MOD(days.i, 30) * 30 + days.i * 3) * dims.mult, 2) AS revenue,
    (20 + MOD(days.i, 15)) AS orders,
    ROUND(0.15 + MOD(days.i, 10) * 0.01, 2) AS margin
  FROM days CROSS JOIN dims
SQL

ALIASES = %w[date region category revenue orders margin].freeze
DISPLAY = { 'date' => 'Date', 'region' => 'Region', 'category' => 'Category',
            'revenue' => 'Revenue', 'orders' => 'Orders', 'margin' => 'Margin' }.freeze

# Comparative period predicates — anchor "current" on the latest COMPLETE
# month (Max month - 1), not the max month itself (which may be a partial
# month in real data); mirrors build-plugs-command-center.rb's MREF/CUR/PRI.
MREF = 'DateAdd("month",-1,DateTrunc("month",Max([Src/Date])))'
CUR = lambda { |expr| "If(DateTrunc(\"month\",[Src/Date]) = #{MREF}, #{expr}, Null)" }
PRI = lambda { |expr| "If(DateTrunc(\"month\",[Src/Date]) = DateAdd(\"month\",-1,#{MREF}), #{expr}, Null)" }

# One professional gradient per KPI card (distinct, non-red, matching
# Styling::DEFAULT_THEME[:header_gradient]'s "not red" discipline).
GRADIENTS = {
  'k-rev' => %w[#0F172A #2563EB],
  'k-ord' => %w[#134E4A #14B8A6]
}.freeze

# A bring-your-own header background (WS4 design doc: a String motif starting
# http/data: is used VERBATIM as the whole background — gradient_header skips
# its own SVG compose entirely for this case). Built here with
# Styling.svg_data_uri (the same public helper gradient_header itself uses)
# so it's still deterministic + geometric + trademark-free, just NOT drawn
# from Styling::MOTIFS.
BYO_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 210" preserveAspectRatio="xMidYMid slice">' \
          '<defs><linearGradient id="byo" x1="0" y1="0" x2="1" y2="1">' \
          '<stop offset="0" stop-color="#134E4A"/><stop offset="1" stop-color="#059669"/>' \
          '</linearGradient></defs>' \
          '<rect width="1600" height="210" fill="url(#byo)"/>' \
          '<g fill="none" stroke="#FFFFFF" stroke-opacity="0.18" stroke-width="2">' \
          '<polygon points="1440,40 1478,63 1478,109 1440,132 1402,109 1402,63"/>' \
          '<polygon points="1500,86 1538,109 1538,155 1500,178 1462,155 1462,109"/>' \
          '<polygon points="1380,86 1418,109 1418,155 1380,178 1342,155 1342,109"/>' \
          '</g></svg>'
BYO_URI = Styling.svg_data_uri(BYO_SVG)

# ---------------------------------------------------------------------------
# Shared helpers (same pattern as verify-richness-surfaces-e2e.rb).
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

# POST/PUT /v2/workbooks/spec: response is documented as YAML. Request a
# non-JSON accept so the raw string always comes back, then self-parse (JSON
# first in case the org actually returns JSON, else scrape `workbookId:` out
# of the YAML text) — same discipline as verify-richness-surfaces-e2e.rb.
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

# Retarget a Styling.gradient_header layout snippet from its fixed default
# page position (rows 1..4, r0/r1 hardcoded inside gradient_header — it has
# no row_start param) to an arbitrary row range, for the pg-motifs gallery
# where three instances are stacked on one page. Safe ONLY when `subtitle` was
# nil for that call — with no subtitle, title_r1 == r1, so both the
# container's and the title's gridRow attributes read the identical literal
# `gridRow="1 / 4"` string, and a single global substitution retargets both
# consistently. (Each gradient_header call uses a distinct `id:`, so element
# ids never collide across the three gallery instances — only this row-range
# substring needs adjusting.)
def retarget_header_rows(layout, r0, r1)
  layout.gsub('gridRow="1 / 4"', "gridRow=\"#{r0} / #{r1}\"")
end

# ---------------------------------------------------------------------------
# Builds one gradient KPI card: KpiCard.build (comparative Current/Prior) ->
# Styling.gradient_card (wraps it in a gradient background, returns a
# white-text patch merged onto a COPY, never mutating the original kpi Hash)
# -> Styling.sparkline (a separate borderless line-chart stacked below the
# kpi inside the SAME container). Returns the three elements + the inner
# layout fragment (relative to the outer GridContainer the caller still has
# to place on the page — gradient_card's own contract: "placing the container
# on the page is the caller's job").
# ---------------------------------------------------------------------------
def build_gradient_kpi(id:, title:, cur_formula:, pri_formula:, fmt_sym:, gradient:, spark_value_formula:)
  fmt = Styling.format_for(fmt_sym)
  card = KpiCard.build(
    id: id, name: title, source_element_id: SRC_ID,
    columns: [
      { 'id' => "#{id}-cur", 'name' => 'Current', 'formula' => cur_formula, 'format' => fmt },
      { 'id' => "#{id}-pri", 'name' => 'Prior', 'formula' => pri_formula, 'format' => fmt }
    ],
    value_column_id: "#{id}-cur", comparison_column_id: "#{id}-pri", good_direction: :up
  )
  gc = Styling.gradient_card(id: "#{id}-bg", kpi_element: card, gradient: gradient)

  patched_card = JSON.parse(JSON.generate(card)) # deep copy, never mutate `card`
  patched_card['value'] = patched_card['value'].merge(gc[:patch]['value'])
  patched_card['name']  = patched_card['name'].merge(gc[:patch]['name'])

  spark = Styling.sparkline(id: "#{id}-spark", source_element_id: SRC_ID,
                             period_ref: 'DateTrunc("month",[Src/Date])',
                             value_formula: spark_value_formula)

  inner_layout = [
    gc[:child_layout],
    "  <LayoutElement elementId=\"#{spark['id']}\" gridColumn=\"1 / 25\" gridRow=\"7 / 11\"/>"
  ].join("\n")

  { container: gc[:element].first, kpi: patched_card, spark: spark, inner_layout: inner_layout }
end

# ---------------------------------------------------------------------------
# Spec construction — every surface below is built by requiring/calling the
# WS4 shared-lib helpers (Richness/Styling/Actions/KpiCard), never a
# hand-inlined shape.
# ---------------------------------------------------------------------------

def build_spec(home, schema_version)
  # ---- source + read-only category pivot (hidden Data page) --------------
  src_cols = ALIASES.map { |a| { 'id' => "c_#{a}", 'name' => DISPLAY[a], 'formula' => "[Custom SQL/#{a}]" } }
  src = { 'id' => SRC_ID, 'kind' => 'table', 'name' => 'Src',
          'source' => { 'kind' => 'sql', 'connectionId' => CONNECTION_ID, 'statement' => DEMO_SQL },
          'columns' => src_cols }

  cat_pivot = { 'id' => CAT_PIVOT_ID, 'kind' => 'pivot-table', 'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
                'columns' => [
                  { 'id' => 'cp-cat', 'name' => 'Category', 'formula' => '[Src/Category]' },
                  { 'id' => 'cp-rev', 'name' => 'Actual Revenue', 'formula' => 'Sum([Src/Revenue])',
                    'format' => Styling.format_for(:currency) }
                ],
                'rowsBy' => [{ 'id' => 'cp-cat' }], 'columnsBy' => [], 'values' => ['cp-rev'] }

  # ==== SURFACE: Styling.gradient_header — hero (glow motif) ===============
  hdr_main = Styling.gradient_header(id: 'hdr-main', title: 'WS4 Surfaces — Live Probe',
                                      subtitle: 'Sigma agent + gradient header/cards + actions/input-tables',
                                      motif: :glow)

  # ==== SURFACE: KpiCard.build + Styling.gradient_card + Styling.sparkline =
  k_rev = build_gradient_kpi(id: 'k-rev', title: 'Revenue',
                              cur_formula: "Sum(#{CUR.call('[Src/Revenue]')})",
                              pri_formula: "Sum(#{PRI.call('[Src/Revenue]')})",
                              fmt_sym: :currency, gradient: GRADIENTS['k-rev'],
                              spark_value_formula: 'Sum([Src/Revenue])')
  k_ord = build_gradient_kpi(id: 'k-ord', title: 'Orders',
                              cur_formula: "Sum(#{CUR.call('[Src/Orders]')})",
                              pri_formula: "Sum(#{PRI.call('[Src/Orders]')})",
                              fmt_sym: :integer, gradient: GRADIENTS['k-ord'],
                              spark_value_formula: 'Sum([Src/Orders])')

  # ==== SURFACE: Richness.agent + Richness.chat (read-only analyst) ========
  agent = Richness.agent(id: 'ag-ws4', name: 'WS4 Analyst',
                          instructions: 'You are an analyst for this dataset. Answer questions about revenue, ' \
                                        'orders, margin, region, and category, and trends over time. Be concise ' \
                                        'and quantitative; cite the numbers you used.',
                          data_source_ids: [SRC_ID])
  chat_hd = { 'id' => 'chat-hd', 'kind' => 'text', 'verticalAlign' => 'middle', 'body' => '**Ask the WS4 Analyst**' }
  chat = Richness.chat(id: 'chat', agent_id: 'ag-ws4')

  # ==== SURFACE: Styling.gradient_header — second live motif (:rings) ======
  hdr_actions = Styling.gradient_header(id: 'hdr-actions', title: 'Actions & Write-back',
                                         subtitle: 'buttons, effects, and input tables',
                                         gradient: %w[#111827 #6D28D9], motif: :rings)

  # ==== SURFACE: entry text-area control (the 4 required trailing fields) =
  note_ctl = { 'id' => NOTE_CTL_ID, 'kind' => 'control', 'controlId' => NOTE_CTL_HANDLE,
               'name' => 'Add a review note', 'controlType' => 'text-area',
               'mode' => 'equals', 'case' => 'insensitive',
               'includeNulls' => 'when-no-value-is-selected', 'showOperators' => false }

  # ==== SURFACE: Actions.button x3, one per verified effect ================
  btn_reset = Actions.button(id: 'btn-reset', text: 'Reset filters', appearance: 'outline',
                              effects: [Actions.clear_control_effect(page: PG_ACTIONS)])
  btn_preset = Actions.button(id: 'btn-preset', text: 'Preset note', appearance: 'outline',
                               effects: [Actions.set_control_value_effect(control: NOTE_CTL_HANDLE,
                                                                           text: 'Reviewed - looks good')])
  btn_log = Actions.button(id: 'btn-log', text: 'Log note', appearance: 'filled',
                            effects: [Actions.insert_rows_effect(table: 'review-log',
                                                                  values: { 'rl-note' => { 'type' => 'control',
                                                                                            'control' => NOTE_CTL_HANDLE } })])

  # ==== SURFACE: Actions.input_table_linked (write conn, keyed off the ====
  #      READ-conn cat_pivot — the cross-connection linked-table pattern) ===
  targets = Actions.input_table_linked(
    id: 'targets', from: CAT_PIVOT_ID, connection_id: WRITE_CONNECTION_ID,
    columns: [
      { 'id' => 'tg-cat', 'key' => 'cp-cat' },
      { 'id' => 'tg-actual', 'key' => 'cp-rev', 'name' => 'Actual Revenue' },
      { 'id' => 'tg-target', 'type' => 'number', 'name' => 'Target Revenue', 'format' => Styling.format_for(:currency) },
      { 'id' => 'tg-var', 'name' => 'Variance vs Target', 'formula' => '[Actual Revenue] - [Target Revenue]',
        'format' => Styling.format_for(:currency) }
    ],
    name: { 'text' => 'Category revenue targets (enter a target per category ->)', 'fontWeight' => 'bold', 'fontSize' => 15 }
  )

  # ==== SURFACE: Actions.input_table_empty (append-only review log) =======
  review_log = Actions.input_table_empty(
    id: 'review-log', connection_id: WRITE_CONNECTION_ID,
    columns: [
      { 'id' => 'rl-note', 'type' => 'text', 'name' => 'Review note' },
      { 'id' => 'CREATED_AT' }, { 'id' => 'CREATED_BY' }
    ],
    name: { 'text' => 'Review log (append-only)', 'fontWeight' => 'bold', 'fontSize' => 15 }
  )

  # ==== SURFACE: pg-motifs gallery — :glow, :rings again (smaller, direct ==
  #      A/B) + ONE bring-your-own image (verbatim, not a MOTIFS key) =======
  gh_glow = Styling.gradient_header(id: 'hdr-glow', title: 'Motif: glow (default)', motif: :glow)
  gh_rings = Styling.gradient_header(id: 'hdr-rings-gallery', title: 'Motif: rings', motif: :rings,
                                      gradient: %w[#111827 #6D28D9])
  gh_byo = Styling.gradient_header(id: 'hdr-byo', title: 'Motif: bring-your-own (verbatim data: URI)', motif: BYO_URI)

  motif_layout = [
    retarget_header_rows(gh_glow[:layout], 1, 5),
    retarget_header_rows(gh_rings[:layout], 6, 10),
    retarget_header_rows(gh_byo[:layout], 11, 15)
  ].join("\n")

  # ---- page layouts ---------------------------------------------------
  pg_main_layout = <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="#{PG_MAIN}">
    #{hdr_main[:layout]}
      <GridContainer elementId="#{k_rev[:container]['id']}" type="grid" gridColumn="1 / 13" gridRow="6 / 18" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    #{k_rev[:inner_layout]}
      </GridContainer>
      <GridContainer elementId="#{k_ord[:container]['id']}" type="grid" gridColumn="13 / 25" gridRow="6 / 18" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    #{k_ord[:inner_layout]}
      </GridContainer>
      <LayoutElement elementId="chat-hd" gridColumn="1 / 25" gridRow="18 / 19"/>
      <LayoutElement elementId="chat" gridColumn="1 / 25" gridRow="19 / 36"/>
    </Page>
  XML

  pg_actions_layout = <<~XML
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="#{PG_ACTIONS}">
    #{hdr_actions[:layout]}
      <LayoutElement elementId="#{NOTE_CTL_ID}" gridColumn="1 / 13" gridRow="5 / 8"/>
      <LayoutElement elementId="btn-reset" gridColumn="13 / 17" gridRow="5 / 8"/>
      <LayoutElement elementId="btn-preset" gridColumn="17 / 21" gridRow="5 / 8"/>
      <LayoutElement elementId="btn-log" gridColumn="21 / 25" gridRow="5 / 8"/>
      <LayoutElement elementId="targets" gridColumn="1 / 25" gridRow="8 / 20"/>
      <LayoutElement elementId="review-log" gridColumn="1 / 25" gridRow="20 / 30"/>
    </Page>
  XML

  pg_motifs_layout = <<~XML
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="#{PG_MOTIFS}">
    #{motif_layout}
    </Page>
  XML

  pg_data_layout = <<~XML
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="#{PG_DATA}">
      <LayoutElement elementId="#{SRC_ID}" gridColumn="1 / 25" gridRow="1 / 10"/>
      <LayoutElement elementId="#{CAT_PIVOT_ID}" gridColumn="1 / 25" gridRow="10 / 20"/>
    </Page>
  XML

  {
    'name' => "WS4 surfaces probe — E2E proof (#{RUN_TAG})",
    'folderId' => home,
    'schemaVersion' => schema_version,
    'description' => 'Live GO/NO-GO proof of WS4 shared-lib surfaces: Richness.agent/chat, ' \
                      'Styling.gradient_header (+motif menu)/gradient_card/sparkline, Actions.* ' \
                      '(buttons/effects, empty + linked input tables). Throwaway test artifact.',
    'agents' => [agent],
    'pages' => [
      { 'id' => PG_MAIN, 'name' => 'Overview',
        'elements' => [
          *hdr_main[:element],
          k_rev[:container], k_rev[:kpi], k_rev[:spark],
          k_ord[:container], k_ord[:kpi], k_ord[:spark],
          chat_hd, chat
        ] },
      { 'id' => PG_ACTIONS, 'name' => 'Actions & Write-back',
        'elements' => [
          *hdr_actions[:element],
          note_ctl, btn_reset, btn_preset, btn_log,
          targets, review_log
        ] },
      { 'id' => PG_MOTIFS, 'name' => 'Motif gallery',
        'elements' => [*gh_glow[:element], *gh_rings[:element], *gh_byo[:element]] },
      { 'id' => PG_DATA, 'name' => 'Data', 'visibility' => 'hidden',
        'elements' => [src, cat_pivot] },
    ],
    # IMPORTANT (live-discovered, this task): layout is a single WORKBOOK-TOP-
    # LEVEL field (sibling of `pages`), matching build-plugs-command-center.rb
    # — NOT a per-page `layout` key (the shape verify-richness-surfaces-e2e.rb
    # uses). An isolated A/B POST probe during this task's run confirmed a
    # per-page `layout` key is silently IGNORED and replaced by Sigma's own
    # auto-arrange (all elements squeezed into the left half of the page,
    # stacked in element-array order) — only ONE combined top-level `layout`
    # string (a single leading XML prolog, then each page's own <Page> block
    # concatenated) is actually honored.
    'layout' => [pg_main_layout, pg_actions_layout, pg_motifs_layout, pg_data_layout].join("\n")
  }
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SCRATCH = ENV.fetch('SCRATCH_DIR', '/private/tmp/claude-502/-Users-tjwells/0fd12afc-2738-4328-a4d5-67e7ce57b185/scratchpad')
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
  agents_back = spec_back['agents'] || []

  hdr_main_bg    = find_el.call('hdr-main-bg')
  hdr_actions_bg = find_el.call('hdr-actions-bg')
  hdr_byo_bg     = find_el.call('hdr-byo-bg')
  agent_back     = agents_back.find { |a| a['id'] == 'ag-ws4' }
  chat_back      = find_el.call('chat')
  k_rev_bg       = find_el.call('k-rev-bg')
  k_rev_kpi      = find_el.call('k-rev')
  k_rev_spark    = find_el.call('k-rev-spark')
  k_ord_bg       = find_el.call('k-ord-bg')
  k_ord_kpi      = find_el.call('k-ord')
  k_ord_spark    = find_el.call('k-ord-spark')
  review_log_el  = find_el.call('review-log')
  targets_el     = find_el.call('targets')
  btn_reset_el   = find_el.call('btn-reset')
  btn_preset_el  = find_el.call('btn-preset')
  btn_log_el     = find_el.call('btn-log')

  surfaces = {
    'gradient_header :glow (hero, pg-main)' => {
      post_accepted: !!(hdr_main_bg && hdr_main_bg.dig('backgroundImage', 'url').to_s.start_with?('data:image/svg+xml;base64,')),
      render_hint: 'Read the pg-main render — top band should show a dark-slate->blue diagonal gradient with a soft ' \
                    'radial glow motif (top-right) behind the white title/subtitle text.'
    },
    'gradient_header :rings (pg-actions)' => {
      post_accepted: !!(hdr_actions_bg && hdr_actions_bg.dig('backgroundImage', 'url').to_s.start_with?('data:image/svg+xml;base64,')),
      render_hint: 'Read the pg-actions render — header band should show the purple gradient with concentric-ring ' \
                    '"signal" motif (top-right).'
    },
    'gradient_header bring-your-own (pg-motifs)' => {
      post_accepted: !!(hdr_byo_bg && hdr_byo_bg.dig('backgroundImage', 'url') == BYO_URI),
      render_hint: 'Read the pg-motifs render (bottom band) — should show the teal/green diagonal gradient with the ' \
                    'hexagon-tile pattern verbatim (NOT the glow/rings library motifs), proving the bring-your-own ' \
                    'path bypasses SVG compose entirely.'
    },
    'Richness.agent (workbook-level, read-only)' => {
      post_accepted: !!(agent_back && agent_back['dataSources'].is_a?(Array) &&
                         agent_back['dataSources'].any? { |d| d['elementId'] == SRC_ID } && !agent_back.key?('tools')),
      render_hint: 'Structural only (agents[] is workbook metadata, not directly visible) — the chat element below ' \
                    'is what actually surfaces it.'
    },
    'Richness.chat rail (pg-main)' => {
      post_accepted: !!(chat_back && chat_back['kind'] == 'chat' && chat_back['agentId'] == 'ag-ws4'),
      render_hint: 'Read the pg-main render — bottom of the page should show either a live chat panel (if AI ' \
                    'agents are enabled on this org) or a "not enabled" placeholder. Report exactly which.'
    },
    'KpiCard + gradient_card + sparkline (Revenue)' => {
      post_accepted: !!(k_rev_bg && k_rev_bg.dig('backgroundImage', 'url').to_s.start_with?('data:') &&
                         k_rev_kpi && k_rev_kpi['comparisonColumn'] &&
                         k_rev_kpi.dig('value', 'color').to_s.downcase == '#ffffff' &&
                         k_rev_spark && k_rev_spark['kind'] == 'line-chart'),
      render_hint: 'Read the pg-main render (left KPI card) — should show a blue gradient card, a white Revenue ' \
                    'value + delta badge, and a TIGHT sparkline directly under it (no large blank gap — this ' \
                    'validates the Task-3 padding:none fix).'
    },
    'KpiCard + gradient_card + sparkline (Orders)' => {
      post_accepted: !!(k_ord_bg && k_ord_bg.dig('backgroundImage', 'url').to_s.start_with?('data:') &&
                         k_ord_kpi && k_ord_kpi['comparisonColumn'] &&
                         k_ord_kpi.dig('value', 'color').to_s.downcase == '#ffffff' &&
                         k_ord_spark && k_ord_spark['kind'] == 'line-chart'),
      render_hint: 'Read the pg-main render (right KPI card) — same check as Revenue, teal gradient.'
    },
    'Actions.input_table_empty (review-log)' => {
      post_accepted: !!(review_log_el && review_log_el['kind'] == 'input-table' && review_log_el['inputMode'] == 'edit' &&
                         review_log_el.dig('source', 'kind') == 'empty'),
      render_hint: 'Read the pg-actions render — the log grid renders EMPTY (no rows) until a real click inserts ' \
                    'one; that is EXPECTED, not a failure. Confirm the column header ("Review note") is visible.'
    },
    'Actions.input_table_linked (targets, cross-connection)' => {
      post_accepted: !!(targets_el && targets_el['kind'] == 'input-table' && targets_el['inputMode'] == 'edit' &&
                         targets_el.dig('source', 'kind') == 'linked' && targets_el.dig('source', 'from') == CAT_PIVOT_ID),
      render_hint: 'Read the pg-actions render — the Targets grid should show one row per category with REAL ' \
                    '"Actual Revenue" figures pulled from the read-connection pivot (not blank) — confirm honestly; ' \
                    'the Target/Variance columns are expected EMPTY until a value is typed in.'
    },
    'Actions.button + clear_control_effect (Reset filters)' => {
      post_accepted: !!(btn_reset_el && btn_reset_el['kind'] == 'button' &&
                         btn_reset_el.dig('actions', 0, 'effects', 0, 'effect') == 'clear-control' &&
                         btn_reset_el.dig('actions', 0, 'effects', 0, 'scope', 'page') == PG_ACTIONS),
      render_hint: 'Read the pg-actions render — "Reset filters" outline button should be visible.'
    },
    'Actions.button + set_control_value_effect (Preset note)' => {
      post_accepted: !!(btn_preset_el && btn_preset_el['kind'] == 'button' &&
                         btn_preset_el.dig('actions', 0, 'effects', 0, 'effect') == 'set-control-value' &&
                         btn_preset_el.dig('actions', 0, 'effects', 0, 'control') == NOTE_CTL_HANDLE),
      render_hint: 'Read the pg-actions render — "Preset note" outline button should be visible.'
    },
    'Actions.button + insert_rows_effect (Log note)' => {
      post_accepted: !!(btn_log_el && btn_log_el['kind'] == 'button' &&
                         btn_log_el.dig('actions', 0, 'effects', 0, 'effect') == 'insert-rows' &&
                         btn_log_el.dig('actions', 0, 'effects', 0, 'table') == 'review-log'),
      render_hint: 'Read the pg-actions render — "Log note" filled button should be visible.'
    }
  }

  # --- render ----------------------------------------------------------
  page_main_png    = File.join(SCRATCH, "ws4-e2e-#{RUN_TAG}-pg-main.png")
  page_actions_png = File.join(SCRATCH, "ws4-e2e-#{RUN_TAG}-pg-actions.png")
  page_motifs_png  = File.join(SCRATCH, "ws4-e2e-#{RUN_TAG}-pg-motifs.png")

  render_main    = render_png(wb, page_main_png, page_id: PG_MAIN, w: 1700, h: 1500)
  render_actions = render_png(wb, page_actions_png, page_id: PG_ACTIONS, w: 1700, h: 1600)
  render_motifs  = render_png(wb, page_motifs_png, page_id: PG_MOTIFS, w: 1700, h: 900)

  log "render pg-main: ok=#{render_main[:ok]} path=#{render_main[:path]} #{render_main[:ok] ? '' : render_main[:log]}"
  log "render pg-actions: ok=#{render_actions[:ok]} path=#{render_actions[:path]} #{render_actions[:ok] ? '' : render_actions[:log]}"
  log "render pg-motifs: ok=#{render_motifs[:ok]} path=#{render_motifs[:path]} #{render_motifs[:ok] ? '' : render_motifs[:log]}"

  verdict = {
    probe_completed: true,
    workbook_id: wb,
    workbook_url: workbook_url,
    render_pg_main_png: render_main[:path],
    render_pg_actions_png: render_actions[:path],
    render_pg_motifs_png: render_motifs[:path],
    render_ok: { pg_main: render_main[:ok], pg_actions: render_actions[:ok], pg_motifs: render_motifs[:ok] },
    surfaces: surfaces
  }
rescue StandardError => e
  verdict = { probe_completed: false, fatal_error: "#{e.class}: #{e.message}", backtrace: e.backtrace&.first(15) }
  log "FATAL — probe did not complete: #{e.class}: #{e.message}"
end

puts
puts '=' * 78
puts verdict[:probe_completed] ? 'PROBE COMPLETED (per-surface POST-accept below — RENDER is a visual read ' \
                                  'the calling agent must do honestly against the PNGs, never auto-claimed here)' :
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
  puts "render pg-actions: ok=#{verdict[:render_ok][:pg_actions]} -> #{verdict[:render_pg_actions_png]}"
  puts "render pg-motifs: ok=#{verdict[:render_ok][:pg_motifs]} -> #{verdict[:render_pg_motifs_png]}"
  puts
end
puts JSON.pretty_generate(verdict)
exit(verdict[:probe_completed] ? 0 : 1)
