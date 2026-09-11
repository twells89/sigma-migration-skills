#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-richness-surfaces-e2e.rb — LIVE GO/NO-GO probe of the NEW WS3
# RICHNESS spec surfaces (WS3 richness Task 1 — the gate for Tasks 2/4's
# emission). Creds-gated: needs a live Sigma org + a warehouse connection with
# Snowflake Cortex enabled, so it is NOT part of the offline CI corpus (same
# class as verify-styling-surfaces-e2e.rb / verify-master-detail-e2e.rb, which
# this script mirrors structurally). This probe deliberately does NOT re-test
# surfaces already proven live elsewhere: comparative `comparisonColumn`
# (verify-kpi-comparison-e2e.rb), controls / control->element filters
# (verify-master-detail-e2e.rb), container `style` / categorical palette / d3
# `format` / KPI `name.color` (verify-styling-surfaces-e2e.rb).
#
# THE FOUR NEW SURFACES UNDER TEST:
#   1. Sparkline-in-KPI  — a kpi-chart whose OWN `columns` include a real date
#      DIMENSION (DateTrunc month) alongside Current/Prior aggregates derived
#      from that SAME date column (the Sum(If(D = Max(D), …)) / prior-month
#      pattern also used by shared/scripts/enhance-scan.rb's comparison-
#      enrichment). Per kpis.md / styling.md, `trend`/sparkline is documented
#      as UI-bound-only in prior live testing — this re-tests the specific,
#      not-yet-tried combination the brief asks for (a date DIMENSION column
#      living inside the KPI's own bound columns, not just a bare `trend`
#      field) and reports honestly rather than assuming the old finding
#      still applies verbatim.
#   2. CallText / AI-insight — a `text` element templating
#      `CallText("SNOWFLAKE.CORTEX.COMPLETE", "<model>", <prompt>)` (CallText's
#      real signature is `CallText(warehouse_function_name, ...args)` — there
#      is NO separate connection argument; it runs against the referenced
#      column's own element/connection). Never round-tripped in this repo
#      before (styling.md: "not yet round-tripped here"). This script first
#      probes candidate Cortex models via a throwaway raw-SQL `kind: sql`
#      element (cheap: no template/render round-trip needed to find out
#      whether a model is even callable) before wiring the real CallText
#      formula into a rendered `text` element.
#   3. Dynamic grain — a `bar-chart` dimension driven by
#      `Switch([GrainCtl], "Week", DateTrunc("week", …), "Month",
#      DateTrunc("month", …), DateTrunc("day", …))`, with `GrainCtl` a
#      `segmented` control using the documented "date-grain switcher" idiom
#      (styling.md: `source: {kind: manual, valueType: text, values: […]}`).
#      Control-driven Switch is itself already proven (see
#      feedback_sigma_control_driven_switch_measure_picker); what's NEW here
#      is whether switching the GRAIN (not just a measure/dimension pick)
#      actually re-buckets the chart — verified via the export API's
#      `parameters` channel (proven in verify-master-detail-e2e.rb): the
#      exported row count / distinct-bucket count must differ meaningfully
#      across Month → Week → Day.
#   4. Value styling + uniform card — a `kpi-chart` with
#      `value: {columnId, color, fontSize}` (already individually documented
#      in styling.md) placed as the MIDDLE of three stacked kpi-charts inside
#      a `<Container gridTemplateRows="repeat(3,1fr)">`. The new question
#      is whether `repeat(3,1fr)` forces UNIFORM (equal) card heights even
#      when one card's own content is visibly taller (a much bigger
#      `value.fontSize`) — CSS Grid's `fr` unit is only guaranteed to
#      equalize tracks when the container has a determinate size, which is
#      exactly the ambiguity worth testing live rather than assuming.
#
# Usage:  ruby shared/scripts/verify-richness-surfaces-e2e.rb
# Env:    SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (or
#         ~/.sigma-migration/env — sigma_rest.rb self-bootstraps);
#         SIGMA_TEST_CONNECTION_ID (Snowflake demo connection; defaults to
#         the shared demo test connection, which this probe confirmed live
#         has SNOWFLAKE.CORTEX.COMPLETE enabled for llama3.1-8b/mistral-large2).
# Exit:   0 = the probe RAN to completion and printed a verdict for every
#         surface (individual surfaces are legitimately GO or NO-GO — this is
#         a discovery probe, not a single pass/fail gate). 1 = the probe
#         itself could not complete (e.g. the workbook never POSTed) — a hard
#         failure, never a faked green.

require 'json'
require 'net/http'
require 'uri'
require 'time'
require 'tmpdir'
require 'fileutils'
require 'shellwords'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sigma_rest'
require 'export_pool'
require 'code_rep'

RUN_TAG       = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
CONNECTION_ID = ENV.fetch('SIGMA_TEST_CONNECTION_ID', '362d859b-f432-4657-8e58-efc8535aa354')

PAGE1_ID = 'pg-main'
PAGE2_ID = 'pg-uniform'

SRC_ID         = 'src'
KPI_SPARK_ID   = 'kpi-spark'
AI_TEXT_ID     = 'ai-text'
GRAIN_CTL_ID   = 'grain-ctl'
GRAIN_CHART_ID = 'grain-chart'
UNIFORM_WRAP_ID = 'uniform-wrap'
CARD_A_ID = 'card-a'
CARD_B_ID = 'card-b' # the styled/value-tested card
CARD_C_ID = 'card-c'

SRC_NAME    = 'Src'
GRAIN_CTL_HANDLE = 'GrainCtl' # controlId — distinct from the element id

# Test colors — distinct hexes, one per probed channel, so a pixel hit can
# only be attributed to the field under test.
# NOTE (live-discovered): the first cut of this probe used pale pastel card
# backgrounds (#DBEAFE/#FEF9C3/#DCFCE7). Under tol=40 those are ALL within
# tolerance of the page's own white/near-white background on every channel
# (e.g. #DBEAFE vs white diffs by only 36/21/1), so the row-wise argmax band
# detector spuriously classified the page background — and even the OTHER
# cards' own pixels — as a match for whichever pale color came first in the
# candidate list. Saturated, mutually-distant colors (checked pairwise and
# against white, every pair differs by >40 on at least one channel) fix the
# measurement without changing what's being tested.
CARD_A_BG    = '#2563EB' # strong blue   — plain KPI, default fontSize
CARD_B_BG    = '#D97706' # strong amber  — the styled KPI under test
CARD_C_BG    = '#059669' # strong green  — plain KPI, default fontSize
VALUE_COLOR  = '#FDE047' # bright yellow — card-b's value.color (distinct from all 3 bg's and from black ink)
VALUE_FONT_SIZE = 44     # card-b's value.fontSize (default is ~28-32)

# Generic demo data — region/category/revenue/orders/margin WITH a real DATE
# column (90 consecutive days, Jan 1 – Mar 31 2026), so sparkline/grain/
# Current-Prior surfaces have genuine time-series structure to work with. No
# customer/personal/company names. Revenue ramps upward over time (the
# `days.i*4` term) so a REAL sparkline (if one rendered) would show visible
# movement, not a flat line.
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
      ('North', 'Electronics', 1.00),
      ('South', 'Electronics', 0.85),
      ('North', 'Apparel',     0.65),
      ('South', 'Apparel',     0.55)
    ) AS t(region, category, mult)
  )
  SELECT
    days.d AS date,
    dims.region,
    dims.category,
    ROUND((900 + MOD(days.i, 30) * 35 + days.i * 4) * dims.mult, 2) AS revenue,
    (40 + MOD(days.i, 25)) AS orders,
    ROUND(0.18 + MOD(days.i, 12) * 0.01, 2) AS margin
  FROM days CROSS JOIN dims
SQL

ALIASES = %w[date region category revenue orders margin].freeze
DISPLAY = { 'date' => 'Date', 'region' => 'Region', 'category' => 'Category',
            'revenue' => 'Revenue', 'orders' => 'Orders', 'margin' => 'Margin' }.freeze

# Current/Prior period tagging (like WS1's comparative-KPI house shape —
# refs/kpi-comparison.md — but derived from a REAL date dimension rather than
# two static same-row columns, per the brief's "DATE column + Current/Prior
# period tagging"): current = latest calendar month present in the data,
# prior = the month immediately before it. Mirrors the verified
# Sum(If(D = Max(D), v, Null)) / Sum(If(D = DateAdd(unit,-1,Max(D)), v, Null))
# pattern from shared/scripts/enhance-scan.rb's comparison-enrichment.
KPI_MONTH_AGG  = 'Max(DateTrunc("month",[Src/Date]))'
KPI_MONTH_DIM  = 'DateTrunc("month",[Src/Date])' # non-aggregate — the literal ask
KPI_CUR_FORMULA   = 'Sum(If(DateTrunc("month",[Src/Date]) = Max(DateTrunc("month",[Src/Date])), [Src/Revenue], Null))'
KPI_PRIOR_FORMULA = 'Sum(If(DateTrunc("month",[Src/Date]) = ' \
                    'DateAdd("month", -1, Max(DateTrunc("month",[Src/Date]))), [Src/Revenue], Null))'

GRAIN_DIM_FORMULA = 'Switch([GrainCtl],"Week",DateTrunc("week",[Src/Date]),' \
                     '"Month",DateTrunc("month",[Src/Date]),DateTrunc("day",[Src/Date]))'
GRAIN_VAL_FORMULA = 'Sum([Src/Revenue])'

# CallText candidate Cortex models — live-probed via raw SQL passthrough
# BEFORE wiring the real formula (cheap: no workbook render round-trip needed
# to find out whether a model string is even callable on this org's
# Snowflake account/region). Populated with the models Sigma's own docs use
# as CallText/CORTEX.COMPLETE examples, in a rough
# small-and-likely-enabled-first order.
CORTEX_MODEL_CANDIDATES = %w[llama3.1-8b mistral-large2 snowflake-arctic claude-3-5-sonnet reka-flash].freeze

def log(msg)
  $stderr.puts("[verify-richness-surfaces-e2e] #{msg}")
end

# ---------------------------------------------------------------------------
# Shared helpers (same pattern as verify-styling-surfaces-e2e.rb /
# verify-master-detail-e2e.rb).
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
    doc = Sigma::CodeRep.document(spec) if spec.is_a?(Hash)
    return doc['schemaVersion'] if doc && doc['schemaVersion']
  end
  raise 'could not discover schemaVersion from any existing workbook'
end

# POST/PUT /v2/workbooks/spec: response is documented as YAML. Never rely on
# Sigma.request's accept:'application/json' auto-parse here — request a
# non-JSON accept so the raw string always comes back, then self-parse (JSON
# first in case the org actually returns JSON, else scrape `workbookId:` out
# of the YAML text).
def post_or_put_workbook_spec(method, path, spec_hash)
  raw = Sigma.request(method, path, body: JSON.generate(spec_hash),
                                     content_type: 'application/json', accept: 'application/yaml')
  parsed = (JSON.parse(raw) rescue nil)
  return parsed if parsed.is_a?(Hash) && parsed['workbookId']
  m = raw.to_s.match(/^\s*workbookId:\s*"?'?([\w-]+)"?'?\s*$/)
  raise "no workbookId in #{method.upcase} response: #{raw.to_s[0, 500]}" unless m
  { 'workbookId' => m[1], 'raw' => raw }
end

# ---------------------------------------------------------------------------
# STAGE 0 — cheap Cortex model discovery via raw-SQL passthrough (no
# templating, no render round-trip). A throwaway single-column `kind: sql`
# element per candidate model; the first one whose export succeeds and
# returns real (non-empty) text is the model CallText will use for real.
# ---------------------------------------------------------------------------

def probe_cortex_model(home, schema_version, model)
  sql = "SELECT SNOWFLAKE.CORTEX.COMPLETE('#{model}', 'Respond with exactly the single word: OK') AS resp"
  doc = {
    'schemaVersion' => schema_version,
    'kind' => 'workbook', # PATCHED for live probe: current contract requires document.kind
    'pages' => [{ 'id' => 'p1', 'name' => 'P1' }],
    'elements' => [
      { 'id' => 'cx', 'kind' => 'table', 'name' => 'Cx',
        'source' => { 'kind' => 'sql', 'connectionId' => CONNECTION_ID, 'statement' => sql },
        'columns' => [{ 'id' => 'r', 'name' => 'Resp', 'formula' => '[Custom SQL/resp]' }] }
    ],
    'layout' => '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">' \
                '<Element elementId="cx" gridColumn="1 / 25" gridRow="1 / 10"/></Page>'
  }
  spec = Sigma::CodeRep.wrap(doc, extra: {
    'name' => "Cortex model probe — #{model} (#{RUN_TAG})",
    'folderId' => home,
    'description' => 'Throwaway raw-SQL Cortex-availability probe. Not the richness workbook.'
  })
  wb = nil
  begin
    resp = post_or_put_workbook_spec(:post, '/v2/workbooks/spec', spec)
    wb = resp['workbookId']
    return { model: model, ok: false, error: "no workbookId in response: #{resp.inspect[0, 300]}" } unless wb
    qid = ExportPool.start_json_export(wb, 'cx', 5)
    return { model: model, ok: false, error: 'export POST did not return a queryId', workbook_id: wb } unless qid
    status, body = ExportPool.poll_json_download(qid, ExportPool::Deadline.new(45))
    return { model: model, ok: false, error: "poll status=#{status}", workbook_id: wb } unless status == :ok
    rows = ExportPool.parse_json_rows(body)
    text = rows.first && (rows.first['Resp'] || rows.first['resp'])
    if text.to_s.strip.empty?
      { model: model, ok: false, error: "empty response: #{rows.inspect[0, 300]}", workbook_id: wb }
    else
      { model: model, ok: true, sample: text.to_s.strip, workbook_id: wb }
    end
  rescue StandardError => e
    { model: model, ok: false, error: e.message[0, 500], workbook_id: wb }
  end
end

# ---------------------------------------------------------------------------
# Spec construction. `flags` gates the guessed/uncertain KPI-sparkline shape
# (raw date-dimension column vs an aggregated Max(DateTrunc(...)) fallback)
# so a live 400 disables exactly the culprit and retries, rather than
# guessing blind (same discipline as verify-styling-surfaces-e2e.rb).
# ---------------------------------------------------------------------------

def build_spec(home, schema_version, cortex_model, flags)
  src_cols = ALIASES.map { |a| { 'id' => "c_#{a}", 'name' => DISPLAY[a], 'formula' => "[Custom SQL/#{a}]" } }

  kpi_month_col =
    if flags[:kpi_date_dim_raw]
      { 'id' => 'kpi-month', 'name' => 'Month', 'formula' => KPI_MONTH_DIM,
        'format' => { 'kind' => 'datetime', 'formatString' => '%b %Y' } }
    else
      { 'id' => 'kpi-month', 'name' => 'Month', 'formula' => KPI_MONTH_AGG,
        'format' => { 'kind' => 'datetime', 'formatString' => '%b %Y' } }
    end

  # Live-verified shape (interactive dry-run, model llama3.1-8b): rendered as
  # "Total revenue across the period was 435,219.75 dollars." — a genuinely
  # computed, non-echoed sentence. Built as ONE double-quoted Ruby string
  # (never %q{}) so `\"` is Ruby's real escape for a literal `"` character —
  # NOT a literal backslash+quote pair — matching what Sigma's own formula
  # parser expects once JSON-decoded server-side.
  ai_body = "{{ Replace(CallText(\"SNOWFLAKE.CORTEX.COMPLETE\", \"#{cortex_model}\", " \
            '"Write one short business-insight sentence (no preamble, no question) stating that total ' \
            "revenue across the period was \" & Text(Sum([Src/Revenue])) & \" dollars.\"), '\"', \"\") }}"

  page1_elements = [
          { 'id' => SRC_ID, 'kind' => 'table', 'name' => SRC_NAME,
            'source' => { 'kind' => 'sql', 'connectionId' => CONNECTION_ID, 'statement' => DEMO_SQL },
            'columns' => src_cols },
          # SURFACE 1: sparkline-in-KPI — date DIMENSION column living inside
          # the KPI's own `columns`, + Current/Prior via comparisonColumn.
          { 'id' => KPI_SPARK_ID, 'kind' => 'kpi-chart',
            'name' => 'Monthly Revenue',
            'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
            'columns' => [
              kpi_month_col,
              { 'id' => 'kpi-cur', 'name' => 'Current Month Revenue', 'formula' => KPI_CUR_FORMULA,
                'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } },
              { 'id' => 'kpi-prior', 'name' => 'Prior Month Revenue', 'formula' => KPI_PRIOR_FORMULA,
                'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } },
            ],
            'value' => { 'columnId' => 'kpi-cur' },
            'comparisonColumn' => { 'columnId' => 'kpi-prior' },
            'comparison' => { 'display' => 'delta', 'colorGood' => '#1a7f37', 'colorBad' => '#cf222e' },
            'trend' => { 'shape' => 'line' } },
          # SURFACE 2: CallText / AI-insight.
          { 'id' => AI_TEXT_ID, 'kind' => 'text', 'verticalAlign' => 'center', 'body' => ai_body },
          # SURFACE 3: dynamic grain — segmented control (documented
          # "date-grain switcher" idiom: manual value-list, no `filters`,
          # consumed only via the chart column's own Switch([GrainCtl],…)).
          { 'id' => GRAIN_CTL_ID, 'kind' => 'control', 'controlId' => GRAIN_CTL_HANDLE,
            'name' => 'Grain', 'controlType' => 'segmented', 'selectionMode' => 'single',
            'value' => 'Month',
            'source' => { 'kind' => 'manual', 'valueType' => 'text', 'values' => %w[Week Month Day],
                          'labels' => %w[Week Month Day] } },
          { 'id' => GRAIN_CHART_ID, 'kind' => 'bar-chart', 'name' => 'Revenue by Grain (Switch-driven)',
            'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
            'columns' => [
              { 'id' => 'grain-dim', 'name' => 'Grain Date', 'formula' => GRAIN_DIM_FORMULA,
                'format' => { 'kind' => 'datetime', 'formatString' => '%b %d, %Y' } },
              { 'id' => 'grain-val', 'name' => 'Revenue', 'formula' => GRAIN_VAL_FORMULA },
            ],
            'xAxis' => { 'columnId' => 'grain-dim' },
            'yAxis' => { 'columnIds' => ['grain-val'] } },
  ]
  page1_layout = <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="#{PAGE1_ID}">
      <Element elementId="#{KPI_SPARK_ID}" gridColumn="1 / 13" gridRow="1 / 11"/>
      <Element elementId="#{AI_TEXT_ID}" gridColumn="13 / 25" gridRow="1 / 11"/>
      <Element elementId="#{GRAIN_CTL_ID}" gridColumn="1 / 9" gridRow="11 / 13"/>
      <Element elementId="#{GRAIN_CHART_ID}" gridColumn="1 / 25" gridRow="13 / 25"/>
      <Element elementId="#{SRC_ID}" gridColumn="1 / 25" gridRow="25 / 29"/>
    </Page>
  XML

  # SURFACE 4 lives on its OWN page — a clean, predictable render
  # (nothing above it) makes the equal/unequal-band pixel measurement
  # reliable without having to first detect an arbitrary content
  # boundary the way the styling probe's hero band needed to.
  page2_elements = [
          { 'id' => UNIFORM_WRAP_ID, 'kind' => 'container', 'style' => { 'backgroundColor' => '#FFFFFF' } },
          { 'id' => CARD_A_ID, 'kind' => 'kpi-chart', 'name' => 'Card A (plain)',
            'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
            'columns' => [{ 'id' => 'a-val', 'name' => ' ', 'formula' => 'Sum([Src/Revenue])',
                            'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } }],
            'value' => { 'columnId' => 'a-val' },
            'style' => { 'backgroundColor' => CARD_A_BG } },
          { 'id' => CARD_B_ID, 'kind' => 'kpi-chart', 'name' => 'Card B (styled — value.color/fontSize)',
            'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
            'columns' => [{ 'id' => 'b-val', 'name' => ' ', 'formula' => 'Sum([Src/Revenue])',
                            'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } }],
            'value' => { 'columnId' => 'b-val', 'color' => VALUE_COLOR, 'fontSize' => VALUE_FONT_SIZE },
            'style' => { 'backgroundColor' => CARD_B_BG } },
          { 'id' => CARD_C_ID, 'kind' => 'kpi-chart', 'name' => 'Card C (plain)',
            'source' => { 'kind' => 'table', 'elementId' => SRC_ID },
            'columns' => [{ 'id' => 'c-val', 'name' => ' ', 'formula' => 'Sum([Src/Orders])' }],
            'value' => { 'columnId' => 'c-val' },
            'style' => { 'backgroundColor' => CARD_C_BG } },
  ]
  page2_layout = <<~XML
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="#{PAGE2_ID}">
      <Container elementId="#{UNIFORM_WRAP_ID}" type="grid" gridColumn="1 / 25" gridRow="1 / 19" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="repeat(3, 1fr)">
        <Element elementId="#{CARD_A_ID}" gridColumn="1 / 25" gridRow="1 / 2"/>
        <Element elementId="#{CARD_B_ID}" gridColumn="1 / 25" gridRow="2 / 3"/>
        <Element elementId="#{CARD_C_ID}" gridColumn="1 / 25" gridRow="3 / 4"/>
      </Container>
    </Page>
  XML
  doc = {
    'schemaVersion' => schema_version,
    'kind' => 'workbook', # PATCHED for live probe: current contract requires document.kind
    'pages' => [
      { 'id' => PAGE1_ID, 'name' => 'Richness Probe — main' },
      { 'id' => PAGE2_ID, 'name' => 'Richness Probe — uniform card' }
    ],
    'elements' => page1_elements + page2_elements,
    'layout' => [page1_layout, page2_layout].join("\n")
  }
  Sigma::CodeRep.wrap(doc, extra: {
    'name' => "WS3 richness-surface probe — E2E proof (#{RUN_TAG})",
    'folderId' => home,
    'description' => 'Live GO/NO-GO proof of WS3 richness spec surfaces (sparkline-in-KPI, CallText, ' \
                     'Switch-grain, value-style + uniform card). Throwaway test artifact.'
  })
end

# ---------------------------------------------------------------------------
# Export / render / pixel-probe helpers.
# ---------------------------------------------------------------------------

def start_json_export_with_params(wb, element_id, params)
  body = { 'elementId' => element_id, 'format' => { 'type' => 'json' } }
  body['parameters'] = params if params && !params.empty?
  r = Sigma.request(:post, "/v2/workbooks/#{wb}/export", body: JSON.generate(body))
  r && r['queryId']
end

def export_rows(wb, element_id, params = nil, deadline_s: 60)
  qid = start_json_export_with_params(wb, element_id, params)
  return { ok: false, reason: 'export POST did not return a queryId' } unless qid
  deadline = ExportPool::Deadline.new(deadline_s)
  status, body = ExportPool.poll_json_download(qid, deadline)
  return { ok: false, reason: "poll status=#{status}", status: status } unless status == :ok
  { ok: true, rows: ExportPool.parse_json_rows(body) }
end

def png_dims(path)
  code = 'import sys; from PIL import Image; im = Image.open(sys.argv[1]); print(im.size[0], im.size[1])'
  out = `python3 -c #{Shellwords.escape(code)} #{Shellwords.escape(path)}`
  w, h = out.strip.split.map(&:to_i)
  { 'width' => w, 'height' => h }
end

def render_png(wb, out_path, page_id: nil, element_id: nil, params: nil, w: 1600, h: 1200)
  png_script = File.expand_path('sigma-export-png.py',
                                 File.join(__dir__, '..', '..', 'plugins', 'tableau-to-sigma', 'skills',
                                            'tableau-to-sigma', 'scripts'))
  cmd = ['python3', png_script, '--workbook', wb, '--out', out_path, '--w', w.to_s, '--h', h.to_s]
  cmd += ['--page', page_id] if page_id
  cmd += ['--element', element_id] if element_id
  (params || {}).each { |k, v| cmd += ['--param', "#{k}=#{v}"] }
  out = `#{cmd.map { |c| Shellwords.escape(c) }.join(' ')} 2>&1`
  ok = $?.success? && File.exist?(out_path)
  { ok: ok, path: (ok ? out_path : nil), log: out.to_s[0, 800] }
end

PIXEL_PROBE_PY = <<~PY
  import sys, json
  import numpy as np
  from PIL import Image

  def main():
      args = json.loads(sys.argv[1])
      img = Image.open(args['png']).convert('RGB')
      arr = np.asarray(img)
      h, w, _ = arr.shape
      tol = args.get('tol', 40)
      results = {}
      for region in args['regions']:
          x0 = max(0, min(w, int(region['x0']))); x1 = max(0, min(w, int(region['x1'])))
          y0 = max(0, min(h, int(region['y0']))); y1 = max(0, min(h, int(region['y1'])))
          if x1 <= x0 or y1 <= y0:
              results[region['name']] = {'error': 'empty box', 'box_px': [x0, y0, x1, y1]}
              continue
          crop = arr[y0:y1, x0:x1, :].reshape(-1, 3)
          total = crop.shape[0] or 1
          hit = {}
          for hexcolor in region.get('targets', []):
              r = int(hexcolor[1:3], 16); g = int(hexcolor[3:5], 16); b = int(hexcolor[5:7], 16)
              target = np.array([r, g, b])
              diff = np.abs(crop.astype(np.int16) - target)
              mask = np.all(diff <= tol, axis=1)
              count = int(mask.sum())
              hit[hexcolor] = {'count': count, 'fraction': round(count / total, 5)}
          results[region['name']] = {'box_px': [x0, y0, x1, y1], 'total_px': int(total), 'targets': hit}
      print(json.dumps(results))

  main()
PY

def pixel_probe(png_path, regions, tol: 40)
  Dir.mktmpdir('pixel-probe-') do |dir|
    script = File.join(dir, 'probe.py')
    File.write(script, PIXEL_PROBE_PY)
    args = JSON.generate({ 'png' => png_path, 'regions' => regions, 'tol' => tol })
    out = `python3 #{Shellwords.escape(script)} #{Shellwords.escape(args)} 2>&1`
    raise "pixel_probe failed: #{out}" unless $?.success?
    JSON.parse(out)
  end
end

def region(name, box, targets)
  x0, x1, y0, y1 = box
  { 'name' => name, 'x0' => x0, 'x1' => x1, 'y0' => y0, 'y1' => y1, 'targets' => targets }
end

# SURFACE 4 band-boundary detection — a generalization of the styling probe's
# detect_hero_bottom_px for THREE sequential, non-overlapping background
# bands (top to bottom: CARD_A_BG, CARD_B_BG, CARD_C_BG). Per ROW, computes
# which of the three candidate colors covers the largest fraction of that
# row's width (text/border ink is only ever a minority of any row) and
# assigns the row to that color if the fraction clears `row_threshold`. Since
# the bands are stacked top-to-bottom with no interleaving, each color's
# [min_row, max_row] IS its band — this directly answers "are the three
# `repeat(3,1fr)` rows actually equal height?" without assuming it.
BAND_PROBE_PY = <<~PY
  import sys, json
  import numpy as np
  from PIL import Image

  def main():
      args = json.loads(sys.argv[1])
      img = Image.open(args['png']).convert('RGB')
      arr = np.asarray(img).astype(np.int16)
      h, w, _ = arr.shape
      tol = args.get('tol', 40)
      colors = args['colors'] # ordered top-to-bottom: [{name, hex}, ...]
      targets = []
      for c in colors:
          hexcolor = c['hex']
          r = int(hexcolor[1:3], 16); g = int(hexcolor[3:5], 16); b = int(hexcolor[5:7], 16)
          targets.append(np.array([r, g, b]))
      row_threshold = args.get('row_threshold', 0.4)
      bands = {c['name']: {'min': None, 'max': None, 'rows_matched': 0} for c in colors}
      for i in range(h):
          row = arr[i]
          fractions = []
          for t in targets:
              diff = np.abs(row - t)
              mask = np.all(diff <= tol, axis=1)
              fractions.append(float(mask.mean()))
          best_idx = int(np.argmax(fractions))
          if fractions[best_idx] >= row_threshold:
              name = colors[best_idx]['name']
              b = bands[name]
              b['rows_matched'] += 1
              b['min'] = i if b['min'] is None else min(b['min'], i)
              b['max'] = i if b['max'] is None else max(b['max'], i)
      for name, b in bands.items():
          b['height_px'] = (b['max'] - b['min'] + 1) if (b['min'] is not None and b['max'] is not None) else 0
      print(json.dumps({'width': int(w), 'height': int(h), 'bands': bands}))

  main()
PY

def band_probe(png_path, colors, tol: 40, row_threshold: 0.4)
  Dir.mktmpdir('band-probe-') do |dir|
    script = File.join(dir, 'band.py')
    File.write(script, BAND_PROBE_PY)
    args = JSON.generate({ 'png' => png_path, 'colors' => colors, 'tol' => tol, 'row_threshold' => row_threshold })
    out = `python3 #{Shellwords.escape(script)} #{Shellwords.escape(args)} 2>&1`
    raise "band_probe failed: #{out}" unless $?.success?
    JSON.parse(out)
  end
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

  # --- STAGE 0: Cortex model discovery (cheap raw-SQL passthrough) ---------
  cortex_results = []
  working_model = nil
  CORTEX_MODEL_CANDIDATES.each do |m|
    r = probe_cortex_model(home, schema_version, m)
    cortex_results << r
    log "cortex candidate #{m}: ok=#{r[:ok]} #{r[:ok] ? "sample=#{r[:sample].inspect}" : "error=#{r[:error]}"}"
    if r[:ok]
      working_model = m
      break
    end
  end

  if working_model.nil?
    # NO-GO -> opt-in path: still emit the formula shape (documented), never
    # a faked summary. Build the rest of the workbook WITHOUT a working
    # CallText call so the other 3 surfaces can still be probed live.
    log 'NO-GO: no candidate Cortex model callable on this connection — CallText marked opt-in, not faked.'
  end

  # --- STAGE 1: build + POST the richness workbook (both pages) -----------
  flags = { kpi_date_dim_raw: true }
  flag_findings = {}
  wb = nil
  attempt = 0
  cortex_model_for_spec = working_model || CORTEX_MODEL_CANDIDATES.first
  loop do
    attempt += 1
    spec = build_spec(home, schema_version, cortex_model_for_spec, flags)
    method = wb.nil? ? :post : :put
    path = wb.nil? ? '/v2/workbooks/spec' : "/v2/workbooks/#{wb}/spec"
    begin
      resp = post_or_put_workbook_spec(method, path, spec)
      wb ||= resp['workbookId']
      raise "no workbookId in response: #{resp.inspect[0, 300]}" unless wb
      log "workbook #{wb} — attempt #{attempt}, flags=#{flags.inspect}"
      break
    rescue StandardError => e
      msg = e.message.to_s
      log "attempt #{attempt} (flags=#{flags.inspect}) raised: #{msg[0, 400]}"
      if flags[:kpi_date_dim_raw] && msg =~ /kpi-month|aggregat|#{Regexp.escape(KPI_SPARK_ID)}/i
        flag_findings[:kpi_date_dim_raw] = msg[0, 400]
        flags[:kpi_date_dim_raw] = false
        log 'disabling flag kpi_date_dim_raw (falling back to Max(DateTrunc(...)) aggregate form) and retrying'
        next if attempt < 5
      end
      raise "workbook POST/PUT never succeeded after #{attempt} attempts: #{msg[0, 800]}"
    end
  end

  workbook_url = "#{ENV['SIGMA_BASE_URL']}/workbook/#{wb}"
  log "resolved workbook #{wb} (#{workbook_url})"

  # --- STAGE 2: structural (GET) readback ----------------------------------
  spec_back = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'application/json')
  spec_back = Sigma::CodeRep.document(spec_back)
  els = Sigma::CodeRep.workbook_elements(spec_back)
  find_el = ->(id) { els.find { |e| e['id'] == id } }

  kpi_el    = find_el.call(KPI_SPARK_ID)
  ai_el     = find_el.call(AI_TEXT_ID)
  ctl_el    = find_el.call(GRAIN_CTL_ID)
  grain_el  = find_el.call(GRAIN_CHART_ID)
  card_a_el = find_el.call(CARD_A_ID)
  card_b_el = find_el.call(CARD_B_ID)
  card_c_el = find_el.call(CARD_C_ID)

  readback = {
    kpi_columns: kpi_el && (kpi_el['columns'] || []).map { |c| { id: c['id'], formula: c['formula'], format: c['format'] } },
    kpi_comparison_column: kpi_el && kpi_el['comparisonColumn'],
    kpi_comparison: kpi_el && kpi_el['comparison'],
    kpi_trend: kpi_el && kpi_el['trend'],
    ai_body: ai_el && ai_el['body'],
    grain_ctl_source: ctl_el && ctl_el['source'],
    grain_ctl_value: ctl_el && ctl_el['value'],
    grain_dim_formula: grain_el && (grain_el['columns'] || []).find { |c| c['id'] == 'grain-dim' } && grain_el['columns'].find { |c| c['id'] == 'grain-dim' }['formula'],
    card_b_value: card_b_el && card_b_el['value'],
    card_a_style: card_a_el && card_a_el['style'],
    card_b_style: card_b_el && card_b_el['style'],
    card_c_style: card_c_el && card_c_el['style'],
  }
  log "readback: #{JSON.generate(readback)[0, 3000]}"

  # --- STAGE 3: SURFACE 1 (sparkline) + SURFACE 2 (CallText) render --------
  page1_png = File.join(SCRATCH, "richness-probe-#{RUN_TAG}-page1.png")
  render_page1 = render_png(wb, page1_png, page_id: PAGE1_ID, w: 1700, h: 1300)
  log "render page1 (kpi-spark + ai-text + grain default): ok=#{render_page1[:ok]} path=#{render_page1[:path]}"

  # --- STAGE 4: SURFACE 3 (dynamic grain) — the hard, non-visual signal ----
  # export the grain-chart element's OWN rows across all three control
  # values and count DISTINCT bucket dates — this is what actually proves
  # (or disproves) that Switch-driven grain re-buckets the chart, independent
  # of any pixel/visual ambiguity.
  grain_buckets = {}
  grain_export_errors = {}
  %w[Month Week Day].each do |val|
    result = (export_rows(wb, GRAIN_CHART_ID, { GRAIN_CTL_HANDLE => val }) rescue { ok: false, reason: $!.message })
    if result[:ok]
      dates = result[:rows].map { |r| r['Grain Date'] || r['grain date'] || r['grain_date'] }.compact.uniq
      grain_buckets[val] = dates.length
      log "grain export param=#{val}: rows=#{result[:rows].size} distinct_buckets=#{dates.length}"
    else
      grain_export_errors[val] = result[:reason]
      log "grain export param=#{val} FAILED: #{result[:reason]}"
    end
  end
  # A visual companion: default (Month) vs a Day-grain render of the SAME
  # element, side by side, for the calling agent's honest eyeball check.
  grain_month_png = File.join(SCRATCH, "richness-probe-#{RUN_TAG}-grain-month.png")
  grain_day_png   = File.join(SCRATCH, "richness-probe-#{RUN_TAG}-grain-day.png")
  render_grain_month = render_png(wb, grain_month_png, element_id: GRAIN_CHART_ID, w: 1200, h: 700)
  render_grain_day    = render_png(wb, grain_day_png, element_id: GRAIN_CHART_ID,
                                    params: { GRAIN_CTL_HANDLE => 'Day' }, w: 1200, h: 700)
  log "render grain-chart Month(default): ok=#{render_grain_month[:ok]}  Day(--param): ok=#{render_grain_day[:ok]}"

  # --- STAGE 5: SURFACE 4 (value styling + uniform card) -------------------
  page2_png = File.join(SCRATCH, "richness-probe-#{RUN_TAG}-page2-uniform.png")
  render_page2 = render_png(wb, page2_png, page_id: PAGE2_ID, w: 1200, h: 1200)
  log "render page2 (uniform card): ok=#{render_page2[:ok]} path=#{render_page2[:path]}"
  band_result = nil
  value_color_probe = nil
  if render_page2[:ok]
    colors = [{ 'name' => 'card_a', 'hex' => CARD_A_BG }, { 'name' => 'card_b', 'hex' => CARD_B_BG },
              { 'name' => 'card_c', 'hex' => CARD_C_BG }]
    band_result = (band_probe(render_page2[:path], colors) rescue { 'error' => $!.message })
    log "band_result: #{band_result.inspect[0, 1500]}"
    if band_result && band_result['bands']
      b = band_result['bands']['card_b']
      if b && b['min'] && b['max']
        box = [0, band_result['width'], b['min'], b['max'] + 1]
        value_color_probe = (pixel_probe(render_page2[:path], [region('card_b_value', box, [VALUE_COLOR])]) rescue { 'error' => $!.message })
      end
    end
  end

  # --- assemble the per-surface verdict ------------------------------------
  def hit?(probe, region_name, hex, min_fraction)
    return false unless probe && probe[region_name] && probe[region_name]['targets']
    t = probe[region_name]['targets'][hex]
    t && t['fraction'].to_f >= min_fraction
  end

  # SURFACE 1 — readback survival is unambiguous; RENDER (does a sparkline
  # actually draw?) is NOT decidable by pixel-color probing (a sparkline has
  # no fixed target hex) — it is called out for the calling agent's honest
  # visual read of render_page1, per this repo's render-honesty convention.
  kpi_month_survived = readback[:kpi_columns] && readback[:kpi_columns].any? { |c| c[:id] == 'kpi-month' }
  kpi_comparison_survived = readback[:kpi_comparison_column].is_a?(Hash) && readback[:kpi_comparison_column]['columnId'] == 'kpi-prior'
  kpi_trend_survived = readback[:kpi_trend].is_a?(Hash) && readback[:kpi_trend]['shape'] == 'line'

  # SURFACE 2 — GO requires a WORKING model found in stage 0 (real generated
  # text, verified live in this probe's own interactive dry-run: model
  # llama3.1-8b returned "Total revenue across the period was 435,219.75
  # dollars." — a genuinely computed, non-echoed sentence). ai_body_survived
  # only proves the FORMULA text round-tripped; render still needs the
  # calling agent's honest look at render_page1 to confirm real generated
  # text (vs. an error/placeholder) actually appeared.
  ai_body_survived = readback[:ai_body].to_s.include?('CallText(') && readback[:ai_body].to_s.include?(cortex_model_for_spec)

  # SURFACE 3 — the hard, non-visual gate: bucket counts must both resolve
  # AND meaningfully differ (Day > Week > Month), not just "no error."
  grain_ok = grain_buckets['Month'] && grain_buckets['Week'] && grain_buckets['Day'] &&
             grain_buckets['Month'] <= 4 && grain_buckets['Week'] >= 8 && grain_buckets['Week'] <= 20 &&
             grain_buckets['Day'] >= 60 &&
             grain_buckets['Month'] < grain_buckets['Week'] && grain_buckets['Week'] < grain_buckets['Day']

  # SURFACE 4a — value.color/fontSize survived readback + a pixel hit in
  # card-b's OWN detected band (fontSize itself still needs the calling
  # agent's visual confirmation — pixel color can't measure glyph size).
  value_survived = readback[:card_b_value].is_a?(Hash) && readback[:card_b_value]['color'].to_s.downcase == VALUE_COLOR.downcase &&
                    readback[:card_b_value]['fontSize'] == VALUE_FONT_SIZE
  value_rendered = value_color_probe && hit?(value_color_probe, 'card_b_value', VALUE_COLOR, 0.01)

  # SURFACE 4b — uniform card geometry: all three bands detected, and their
  # heights are within 35% of each other despite card-b's much larger font.
  uniform_heights = nil
  uniform_ok = false
  if band_result && band_result['bands']
    hts = %w[card_a card_b card_c].map { |k| band_result['bands'][k] && band_result['bands'][k]['height_px'] }
    if hts.all? { |h| h && h > 0 }
      uniform_heights = { card_a: hts[0], card_b: hts[1], card_c: hts[2] }
      uniform_ok = (hts.max.to_f / hts.min) <= 1.35
    end
  end

  verdict = {
    probe_completed: true,
    workbook_id: wb,
    workbook_url: workbook_url,
    cortex_probe_results: cortex_results,
    cortex_working_model: working_model,
    flags_final: flags,
    flag_findings: flag_findings,
    render_page1_png: render_page1[:path],
    render_grain_month_png: render_grain_month[:path],
    render_grain_day_png: render_grain_day[:path],
    render_page2_uniform_png: render_page2[:path],
    readback: readback,
    grain_bucket_counts: grain_buckets,
    grain_export_errors: grain_export_errors,
    band_result: band_result,
    value_color_probe: value_color_probe,
    surfaces: {
      'sparkline-in-kpi' => {
        go: nil, # decided by the calling agent's visual read of render_page1_png — never auto-claimed GO here
        readback_survived: { date_dimension_column: !!kpi_month_survived, comparison_column: !!kpi_comparison_survived,
                              trend_field: !!kpi_trend_survived },
        date_dim_shape_used: (flags[:kpi_date_dim_raw] ? 'raw non-aggregate DateTrunc (as literally asked)' : "aggregated fallback: #{KPI_MONTH_AGG} (raw form rejected: #{flag_findings[:kpi_date_dim_raw]})"),
        surviving_shape: (kpi_month_survived && kpi_comparison_survived ?
          { columns: [{ id: 'kpi-month', formula: (flags[:kpi_date_dim_raw] ? KPI_MONTH_DIM : KPI_MONTH_AGG),
                        format: { kind: 'datetime', formatString: '%b %Y' } },
                      { id: 'kpi-cur', formula: KPI_CUR_FORMULA }, { id: 'kpi-prior', formula: KPI_PRIOR_FORMULA }],
            value: { columnId: 'kpi-cur' }, comparisonColumn: { columnId: 'kpi-prior' },
            comparison: { display: 'delta' }, trend: { shape: 'line' } } : nil),
        render: 'NEEDS VISUAL CONFIRMATION — Read render_page1_png and look at the kpi-spark card (top-left) ' \
                'for an actual line/sparkline under the number. Prior live findings (kpis.md, styling.md) found ' \
                'trend/sparkline UI-bound-only across ~8 configurations on 2026-06-24 — this is a re-test of a ' \
                'not-previously-tried combination (date dimension living in the KPI\'s own bound columns), not ' \
                'an assumption that the old finding still holds.',
      },
      'calltext-ai-insight' => {
        go: working_model.nil? ? false : nil, # false=hard NO-GO (no usable model); nil=needs the calling agent's visual read
        opt_in: working_model.nil?,
        working_model: working_model,
        cortex_candidates_tried: cortex_results.map { |r| { model: r[:model], ok: r[:ok], error: r[:error], sample: r[:sample] } },
        readback_survived: !!ai_body_survived,
        surviving_shape: (working_model ?
          { kind: 'text', body: "{{ Replace(CallText(\"SNOWFLAKE.CORTEX.COMPLETE\", \"#{working_model}\", " \
                                 '"Write one short business-insight sentence (no preamble, no question) stating ' \
                                 'that total revenue across the period was " & Text(Sum([<Source>/Revenue])) & ' \
                                 '" dollars."), \'"\', "") }}' } : nil),
        render: (working_model ?
          'NEEDS VISUAL CONFIRMATION — Read render_page1_png (right column) and confirm the text reads as a ' \
          'real, coherent generated sentence (this probe\'s own interactive dry-run with model llama3.1-8b ' \
          'returned "Total revenue across the period was 435,219.75 dollars." — a genuinely computed, ' \
          'non-echoed sentence, not a template artifact or error).' :
          'NOT RENDERED — no Cortex model was callable on this connection (see cortex_probe_results for the ' \
          'exact per-model errors). NO-GO -> opt-in: the CallText formula shape is still documented/emittable, ' \
          'but must be flagged "renders only where the org has a working Cortex/warehouse-AI connection" — ' \
          'never emitted as if it will always show real text.'),
      },
      'dynamic-grain-switch' => {
        go: !!grain_ok,
        bucket_counts: grain_buckets,
        export_errors: grain_export_errors,
        readback_survived: !!(readback[:grain_dim_formula] && readback[:grain_ctl_source]),
        surviving_shape: (grain_ok ?
          { control: { kind: 'control', controlId: GRAIN_CTL_HANDLE, controlType: 'segmented', selectionMode: 'single',
                       value: 'Month', source: { kind: 'manual', valueType: 'text', values: %w[Week Month Day] } },
            chart_dimension_formula: GRAIN_DIM_FORMULA } : nil),
        render: 'render_grain_month_png (default) vs render_grain_day_png (--param GrainCtl=Day) are companion ' \
                'visual evidence — Day should show visibly more/narrower bars than Month. The GATING evidence ' \
                'is bucket_counts above (export API, --param channel), not pixel comparison.',
        note: "Month=#{grain_buckets['Month'].inspect} Week=#{grain_buckets['Week'].inspect} " \
              "Day=#{grain_buckets['Day'].inspect} distinct buckets over 90 days of source data " \
              '(expect ~3 / ~13 / ~90).',
      },
      'value-style-uniform-card' => {
        go: !!(value_survived && value_rendered && uniform_ok),
        value_style: { readback_survived: !!value_survived, rendered: !!value_rendered,
                        surviving_shape: (value_survived && value_rendered ?
                          { value: { columnId: 'b-val', color: VALUE_COLOR, fontSize: VALUE_FONT_SIZE } } : nil),
                        render_fontSize_note: 'fontSize magnitude itself still NEEDS VISUAL CONFIRMATION (pixel ' \
                          'color alone cannot measure glyph size) — Read render_page2_uniform_png\'s middle band ' \
                          '(card B) and confirm the number visibly reads larger than cards A/C.' },
        uniform_card: { bands_detected: !!uniform_heights, heights_px: uniform_heights, uniform_within_35pct: uniform_ok,
                        note: 'card B was deliberately given a much larger value.fontSize than A/C so unequal ' \
                              'natural content heights would show up as unequal bands IF repeat(3,1fr) does not ' \
                              'truly force equal division on an auto-height page.' },
        surviving_shape: (uniform_ok ?
          { layout_container: { gridTemplateRows: 'repeat(3,1fr)', gridTemplateColumns: 'repeat(24,1fr)' } } : nil),
      },
    },
  }
rescue StandardError => e
  verdict = { probe_completed: false, fatal_error: "#{e.class}: #{e.message}", backtrace: e.backtrace&.first(15) }
  log "FATAL — probe did not complete: #{e.class}: #{e.message}"
end

puts
puts '=' * 78
puts verdict[:probe_completed] ? 'PROBE COMPLETED (per-surface verdicts below — some fields need the calling ' \
                                  'agent\'s visual confirmation, marked go: nil)' : 'PROBE FAILED (fatal)'
puts '=' * 78
if verdict[:probe_completed]
  puts
  puts format('%-26s %-10s %s', 'SURFACE', 'VERDICT', 'NOTES')
  verdict[:surfaces].each do |name, v|
    label = v[:go] == true ? 'GO' : (v[:go] == false ? 'NO-GO' : 'NEEDS VISUAL')
    note = (v[:render] || v[:note] || '')[0, 140]
    puts format('%-26s %-10s %s', name, label, note)
  end
  puts
end
puts JSON.pretty_generate(verdict)
exit(verdict[:probe_completed] ? 0 : 1)
