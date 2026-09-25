#!/usr/bin/env ruby
# ── VENDORED (do not edit here) ──────────────────────────────────────────────
# Source: twells89/sigma-migration-skills @ a73f833
#   plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/post-and-readback.rb
# Fix upstream and re-vendor; do not diverge this copy. Vendored for the
# standalone domo-sigma-migration repo (clone-safety) per the domo-build-pipeline plan.
# ─────────────────────────────────────────────────────────────────────────────
# POST a DM or workbook spec, parse the YAML response, then GET the spec back
# and emit a clean JSON map of pages → elements with server-assigned IDs.
# On the datamodel path, a post-readback COLUMN CENSUS (lib/column_census.rb)
# compares the posted spec's per-element columns against the readback and
# WARNs loudly on any silent drop — columns that vanish without an HTTP error
# or a type="error" entry (a live migration lost 550 of 599 columns this way).
# It is a WARN, not a hard stop: the pre-POST ref-resolution gate
# (assert-wb-refs-resolve.rb) hard-stops the workbook build downstream.
#
# Usage:
#   ruby post-and-readback.rb --type datamodel|workbook --spec <spec.json> --out <id-map.json>
#
# Exit codes:
#   0  posted + readback clean
#   1  hard failure (abort) — POST/PUT rejected, nothing recoverable
#   2  column(s) resolved to type=error on the live DM/workbook
#   3  workbook layout lint violations
#   4  workbook control lint violations
#   6  DATAMODEL QUARANTINED (only with --quarantine-on-failure): one or more
#      broken elements were removed to <workdir>/deferred-elements.json and the
#      REMAINING spec re-POSTed once. The DM is PARTIAL — the migration may NOT
#      be declared GREEN while deferred-elements.json is non-empty
#      (assert-phase6-ran.rb enforces this). Fix the deferred elements, restore
#      them into the spec, re-POST, then delete the file.

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'date'
require 'time'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--type T', %w[datamodel workbook]) { |v| opts[:type] = v }
  p.on('--spec P')                         { |v| opts[:spec] = v }
  p.on('--out P')                          { |v| opts[:out]  = v }
  p.on('--workdir P', 'Per-conversion working dir (default: dir of --spec). Used to track posted workbook IDs across retries.') { |v| opts[:workdir] = v }
  p.on('--skip-layout-lint') { opts[:skip_lint] = true }
  p.on('--skip-control-lint') { opts[:skip_control_lint] = true }
  p.on('--control-scope P', 'control-scope.json sidecar (default: <workdir>/control-scope.json if present)') { |v| opts[:control_scope] = v }
  p.on('--update-id ID', 'PUT the spec to this existing workbook/DM id instead of POSTing a new one (retry-safe; avoids orphan workbooks). For workbooks, if omitted, the last id in posted-workbooks.jsonl is reused automatically.') { |v| opts[:update_id] = v }
  p.on('--quarantine-on-failure', 'DATAMODEL only: when the POST fails naming specific element(s), or the post-POST column census resolves specific elements to type=error, move those elements to <workdir>/deferred-elements.json, re-POST ONCE without them, and exit 6 (PARTIAL DM — never GREEN until the file is resolved). Default (no flag): fail loudly, quarantine nothing.') { opts[:quarantine] = true }
end.parse!
%i[type spec out].each { |k| abort("missing --#{k}") unless opts[k] }
opts[:workdir] ||= File.dirname(File.expand_path(opts[:spec]))
require 'fileutils'
FileUtils.mkdir_p(opts[:workdir])

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'dm_quarantine'
require 'code_rep'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

QUARANTINE = opts[:quarantine] && opts[:type] == 'datamodel'
DEFERRED_PATH = File.join(opts[:workdir], 'deferred-elements.json')
warn 'NOTE: --quarantine-on-failure only applies to --type datamodel; ignored.' if opts[:quarantine] && opts[:type] != 'datamodel'

BASE = ENV.fetch('SIGMA_BASE_URL')

POST_PATH = opts[:type] == 'datamodel' ? '/v2/dataModels/spec'              : '/v2/workbooks/spec'
GET_PATH  = opts[:type] == 'datamodel' ? '/v2/dataModels/%s/spec'           : '/v2/workbooks/%s/spec'
ID_FIELD  = opts[:type] == 'datamodel' ? 'dataModelId'                      : 'workbookId'

# Wraps a single Sigma REST call with automatic 401-retry-after-refresh
# (tokens last ~1 hour; long conversions outlive a single token). Returns
# the raw Net::HTTPResponse so existing .body / .is_a?(Net::HTTPSuccess)
# checks below keep working unchanged.
def http(method, path, body = nil, accept_json: false)
  attempts = 0
  loop do
    attempts += 1
    uri = URI("#{BASE}#{path}")
    req = case method
          when :post then r = Net::HTTP::Post.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
          when :put  then r = Net::HTTP::Put.new(uri);  r.body = body; r['Content-Type'] = 'application/json'; r
          when :get  then Net::HTTP::Get.new(uri)
          end
    req['Authorization'] = "Bearer #{Sigma.auth_token}"
    req['Accept']        = 'application/json' if accept_json
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |h| h.request(req) }
    if res.code.to_i == 401 && attempts == 1 && ENV['SIGMA_CLIENT_ID']
      warn '  [auth] Sigma token expired mid-run, refreshing and retrying...'
      Sigma.refresh_token!
      next
    end
    return res
  end
end

# Orphan-prevention pre-check: workbook POSTs are create-only. If this is a
# second invocation in the same conversion, the previous workbook is being
# orphaned in the customer's My Documents. WARN loudly and emit the PUT
# alternative. Tracked at beads-sigma-38a (3-workbook customer regression).
posted_log = File.join(opts[:workdir], 'posted-workbooks.jsonl') if opts[:type] == 'workbook'
prior_ids = []
if posted_log && File.exist?(posted_log)
  prior_ids = File.readlines(posted_log).map { |l| JSON.parse(l)['id'] rescue nil }.compact
end
# Decide POST (create) vs PUT (update existing). An explicit --update-id always
# wins; otherwise, for a workbook retry, auto-reuse the last id we posted in this
# conversion so a re-run UPDATES the workbook in place instead of orphaning it
# (beads-sigma-38a — the 3-workbook customer regression). DM updates require an
# explicit --update-id (Phase 3 normally reuses a DM via the ref-dm path).
update_id = opts[:update_id] || (prior_ids.last if opts[:type] == 'workbook' && prior_ids.any?)

# Workbook code-rep nests non-metadata fields under `document`; data models
# deliberately remain flat with pages[*].elements. Normalize the workbook body
# once, before either POST or PUT, and require the authoritative layout the
# released representation uses for page membership.
spec_body =
  if opts[:type] == 'workbook'
    posting_doc = JSON.parse(File.read(opts[:spec]))
    document = Sigma::CodeRep.document(posting_doc)
    abort('workbook spec missing required document.layout') if document['layout'].to_s.strip.empty?
    abort('workbook spec pages must be metadata-only') if Array(document['pages']).any? { |page| page.key?('elements') }
    JSON.generate(Sigma::CodeRep.wrap(document, extra: Sigma::CodeRep.metadata(posting_doc)))
  else
    File.read(opts[:spec])
  end

if update_id
  warn "UPDATE mode: PUT #{opts[:type]} #{update_id} (no new #{opts[:type]} created)"
  resp = http(:put, format(GET_PATH, update_id), spec_body)
  parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
  oid = parsed[ID_FIELD] || update_id
  abort("PUT failed (HTTP #{resp.code}): #{parsed.inspect}") unless resp.is_a?(Net::HTTPSuccess)
  warn "PUT ok: #{ID_FIELD}=#{oid}"
else
  resp = http(:post, POST_PATH, spec_body)
  parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
  oid = parsed.is_a?(Hash) ? parsed[ID_FIELD] : nil
  # Rec5 quarantine (opt-in): a POST killed by ONE broken element must not lose
  # the other N-1. If the API error names attributable element(s), defer them
  # to <workdir>/deferred-elements.json and re-POST ONCE without them. If the
  # error is not attributable, fail loudly exactly as before.
  if oid.nil? && QUARANTINE
    spec_doc = JSON.parse(File.read(opts[:spec]))
    found = DmQuarantine.offending_from_error(spec_doc, resp.body.to_s)
    if found[:ids].any?
      q = DmQuarantine.quarantine(spec_doc, found[:ids], found[:reasons])
      $quarantined = q[:deferred]
      File.write(DEFERRED_PATH, JSON.pretty_generate(
        DmQuarantine.deferred_doc(q[:deferred], spec_path: File.expand_path(opts[:spec]))))
      cleaned_path = File.join(opts[:workdir], 'dm-spec.quarantined.json')
      File.write(cleaned_path, JSON.pretty_generate(q[:spec]))
      warn "QUARANTINE: POST failed naming #{found[:ids].size} element(s) — deferred to #{DEFERRED_PATH}; re-POSTing ONCE without them (#{cleaned_path})"
      found[:ids].each { |id| warn "  - #{id}: #{found[:reasons][id]}" }
      resp = http(:post, POST_PATH, File.read(cleaned_path))
      parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
      oid = parsed.is_a?(Hash) ? parsed[ID_FIELD] : nil
      abort("POST failed AGAIN after quarantining #{found[:ids].size} element(s) — not a single-element failure. " \
            "Deferred file kept for forensics: #{DEFERRED_PATH}. Error: #{parsed.inspect}") if oid.nil?
    end
  end
  abort("POST failed: #{parsed.inspect}") if oid.nil?
  warn "POST ok: #{ID_FIELD}=#{oid}"

  # Append the new ID to the per-conversion log. Newline-delimited JSON so
  # multiple processes can append safely (atomic append on POSIX). Only on
  # create — a PUT reuses an existing id and adds no orphan to track.
  if posted_log
    File.open(posted_log, 'a') do |f|
      f.puts(JSON.generate({ 'id' => oid, 'ran_at' => Time.now.utc.iso8601 }))
    end
  end
end

# Read back
# Fetch the resolved /columns BEFORE writing the id-map so we can attach the
# AUTHORITATIVE per-element column labels (the suffixed display names Sigma
# assigns to disambiguate joined-dim columns — e.g. "Customer Id (CUSTOMER_DIM)").
# derive_master needs these to emit master-column formulas that actually resolve.
# (Same response is reused below for the error-type guard — one round trip.)
# Wrapped in a lambda because the quarantine path below may PUT a cleaned spec
# and needs a SECOND readback of the final live state.
columns_path = opts[:type] == 'datamodel' ?
  "/v2/dataModels/#{oid}/columns" :
  "/v2/workbooks/#{oid}/columns"
readback = lambda do
  # Workbook code-rep responses nest non-metadata fields (pages/layout/
  # schemaVersion/kind) under `document` (live since 2026-08); the DM
  # readback is unchanged and stays flat.
  raw_spec = JSON.parse(http(:get, format(GET_PATH, oid), accept_json: true).body)
  spec = opts[:type] == 'workbook' ? Sigma::CodeRep.document(raw_spec) : raw_spec
  cols_res = http(:get, columns_path, accept_json: true)
  cols_json = cols_res.is_a?(Net::HTTPSuccess) ? (JSON.parse(cols_res.body) rescue { 'entries' => [] }) : nil
  labels_by_el = Hash.new { |h, k| h[k] = [] }
  (cols_json && cols_json['entries'] || []).each do |c|
    labels_by_el[c['elementId']] << c['label'] if c['elementId'] && c['label']
  end
  [spec, cols_res, cols_json, labels_by_el]
end
spec, cols_res, cols_json, labels_by_el = readback.call

# Rec5 quarantine, census leg (opt-in, datamodel only): the POST succeeded but
# specific live element(s) resolved columns to type=error. Defer those elements,
# PUT the cleaned spec back to the SAME DM id (no orphan), and re-read once.
# $quarantined.nil? enforces the re-POST-ONCE contract: if the POST leg already
# quarantined and errors REMAIN, fail loudly (exit 2) instead of looping.
if QUARANTINE && $quarantined.nil? && cols_res.is_a?(Net::HTTPSuccess)
  census_errors = (cols_json['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
  if census_errors.any?
    spec_doc = JSON.parse(File.read(opts[:spec]))
    # live element id → name, so census elementIds map back onto spec elements
    live_names = {}
    (spec['pages'] || []).each { |p| (p['elements'] || []).each { |e| live_names[e['id']] = e['name'] } }
    found = DmQuarantine.offending_from_error_columns(spec_doc, census_errors, live_names)
    if found[:ids].any?
      q = DmQuarantine.quarantine(spec_doc, found[:ids], found[:reasons])
      $quarantined = Array($quarantined) + q[:deferred]
      File.write(DEFERRED_PATH, JSON.pretty_generate(
        DmQuarantine.deferred_doc($quarantined, data_model_id: oid, spec_path: File.expand_path(opts[:spec]))))
      cleaned_path = File.join(opts[:workdir], 'dm-spec.quarantined.json')
      File.write(cleaned_path, JSON.pretty_generate(q[:spec]))
      warn "QUARANTINE: column census flagged #{found[:ids].size} element(s) — deferred to #{DEFERRED_PATH}; " \
           "re-PUTting the remaining spec to #{ID_FIELD}=#{oid} (#{cleaned_path})"
      found[:ids].each { |id| warn "  - #{id}: #{found[:reasons][id]}" }
      put_res = http(:put, format(GET_PATH, oid), File.read(cleaned_path))
      abort("re-PUT after quarantine failed (HTTP #{put_res.code}): #{put_res.body.to_s[0, 500]} — " \
            "deferred file kept: #{DEFERRED_PATH}") unless put_res.is_a?(Net::HTTPSuccess)
      spec, cols_res, cols_json, labels_by_el = readback.call
    else
      warn 'QUARANTINE: column census has type=error entries but none map to a spec element — nothing quarantined (failing loudly below).'
    end
  end
end

page_elements =
  if opts[:type] == 'workbook'
    elements_by_id = Sigma::CodeRep.workbook_elements(spec).each_with_object({}) do |element, index|
      index[element['id']] = element if element['id']
    end
    Sigma::CodeRep.workbook_page_element_ids(spec).transform_values do |ids|
      ids.filter_map { |id| elements_by_id[id] }
    end
  else
    spec.fetch('pages', []).each_with_object({}) do |page, pages|
      pages[page['id']] = page['elements'] || []
    end
  end

out = {
  ID_FIELD => oid,
  'pages'  => spec.fetch('pages', []).map do |p|
    {
      'id'       => p['id'],
      'name'     => p['name'],
      'visibility' => p['visibility'],
      'elements' => Array(page_elements[p['id']]).map do |e|
        el = { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'] }
        el['columnLabels'] = labels_by_el[e['id']] if labels_by_el.key?(e['id'])
        el
      end
    }
  end
}
File.write(opts[:out], JSON.pretty_generate(out))
puts JSON.pretty_generate(out)

# Universal silent-error guard: scan every column's resolved type via the
# `/columns` endpoint and fail loudly on any column with type `error`.
#
# A column ends up "error" when the formula compiles successfully against the
# validator but fails at runtime. Typical causes:
#   - Referenced column doesn't exist (typo)
#   - Function doesn't exist in Sigma (e.g., IsIn — see memory feedback_sigma_formula_isin.md)
#   - Window aggregate used in calc-column context (validate-spec catches the known
#     function names; this catches anything else that produces an error type)
#   - Cross-element ref without a Lookup wrapper (compiles, returns NULL forever — actually
#     resolves as the column's declared type, not "error", so this guard misses it; that's
#     why refs/data-model-spec.md has its own callout)
#
# Endpoint: GET /v2/{dataModels|workbooks}/<id>/columns — returns one entry per
# column with `type.type` resolved. Scan for type == "error".

res = cols_res
if res.is_a?(Net::HTTPSuccess)
  error_columns = (cols_json['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
  if error_columns.any?
    warn "\n========================================"
    warn "FAIL — #{error_columns.size} column(s) compiled to type \"error\":"
    error_columns.each do |c|
      warn "  [element=#{c['elementId']}] #{c['label']} (#{c['columnId']}):"
      warn "    formula: #{c['formula']}"
    end
    warn 'Fix these formulas before continuing — Phase 6 parity would fail downstream.'
    warn 'Common causes: typo in a column ref, IsIn() / non-existent function, window'
    warn 'aggregate in a calc column (use a Custom SQL element instead — see Phase 3).'
    warn "NOTE: errors persist AFTER quarantining #{Array($quarantined).size} element(s) — see #{DEFERRED_PATH}." if $quarantined
    warn '========================================'
    exit(2)
  else
    total = (cols_json['entries'] || []).size
    warn "column-type guard: #{total} columns clean (no `error` types)"
  end
else
  warn "WARN: could not fetch /columns for type guard (got HTTP #{res.code}); skipping"
end

# DM column-DROPPAGE guard (a real multi-datasource workbook): the type=error guard above
# only catches columns that POSTed-then-errored. When a multi-datasource workbook
# is collapsed onto its primary, the OTHER sources' columns are simply ABSENT from
# the live DM (never posted) — no error type, so the guard above stays silent while
# the spec declared hundreds more. Surface that gap loudly here; the pre-POST
# ref-resolution gate (assert-wb-refs-resolve.rb) then hard-stops the workbook.
# The per-element COLUMN CENSUS (lib/column_census.rb) enriches the warning
# with posted-vs-resolved counts and the missing column names, and also WARNs
# on smaller silent drops that miss the aggregate droppage threshold.
if opts[:type] == 'datamodel' && res.is_a?(Net::HTTPSuccess)
  declared = (spec['pages'] || []).sum { |p| (p['elements'] || []).sum { |e| (e['columns'] || []).size } }
  live = (cols_json['entries'] || []).size

  # One census pass feeds both the droppage detail and the small-drop warning.
  require_relative 'lib/column_census'
  posted_spec = begin
    JSON.parse(File.read(opts[:spec]))
  rescue JSON::ParserError
    nil # spec file already POSTed fine; census just can't re-read it
  end
  census_problems = posted_spec ? ColumnCensus.census(posted_spec, spec, cols_json['entries'] || []) : []

  if declared > 20 && live < declared * 0.7
    pct = ((1.0 - live.to_f / declared) * 100).round
    warn "\n========================================"
    warn "WARN — DM column DROPPAGE: spec declared #{declared} column(s), live DM has #{live} " \
         "(#{pct}% absent, NOT type=error)."
    warn 'This is the multi-datasource-collapse signature: columns from non-primary datasources'
    warn 'were dropped. The workbook build will fail ref-resolution downstream. Verify the DM has'
    warn 'one element per datasource (multi-element DM) before building the workbook.'
    if census_problems.any?
      warn "Per-element census (#{census_problems.size} element(s) lost columns between POST and readback):"
      ColumnCensus.report_lines(census_problems).each { |l| warn "  #{l}" }
    end
    warn '========================================'
  elsif census_problems.any?
    warn "\n========================================"
    warn "WARN — column census: #{census_problems.size} element(s) lost columns between POST and readback:"
    ColumnCensus.report_lines(census_problems).each { |l| warn "  #{l}" }
    warn 'These columns were POSTed but the live DM did not resolve them (silent drop —'
    warn 'no HTTP error, no type=error entry). Downstream [Master/...] refs to missing'
    warn 'columns will be caught by the pre-POST ref gate (assert-wb-refs-resolve.rb).'
    warn '========================================'
  elsif posted_spec
    warn "column census: #{ColumnCensus.posted_column_count(posted_spec)} posted column(s) all resolved in readback"
  end
end

# Rec5 quarantine final report: the (re-)POST succeeded and the census is clean,
# but only because broken element(s) were REMOVED. The DM is PARTIAL — exit with
# the distinct code so no caller mistakes this for a full green POST.
if $quarantined && Array($quarantined).any?
  File.write(DEFERRED_PATH, JSON.pretty_generate(
    DmQuarantine.deferred_doc($quarantined, data_model_id: oid, spec_path: File.expand_path(opts[:spec]))))
  names = Array($quarantined).map { |d| d.dig('element', 'name') || d.dig('element', 'id') }
  warn "\n================================================================"
  warn "PARTIAL DM — #{names.size} element(s) QUARANTINED (exit #{DmQuarantine::EXIT_QUARANTINED})"
  warn "================================================================"
  Array($quarantined).each do |d|
    warn "  - #{d.dig('element', 'name') || d.dig('element', 'id')}: #{d['reason']}"
  end
  warn "The remaining elements posted cleanly to #{ID_FIELD}=#{oid}, but the DM is"
  warn "INCOMPLETE. Fix each element spec in:"
  warn "  #{DEFERRED_PATH}"
  warn 'restore it into the DM spec, re-POST (PUT --update-id), and delete the file.'
  warn 'The migration may NOT be declared GREEN while deferred-elements.json is'
  warn 'non-empty — assert-phase6-ran.rb blocks it (escape: --accept-deferred-elements'
  warn '"<reason>", which must be named in the migration report).'
  warn '================================================================'
  exit(DmQuarantine::EXIT_QUARANTINED)
end

# Layout-quality lint (shared scripts/lib/layout_lint.rb — vendored byte-
# identical, md5 discipline): fails loudly on raw-id element display names,
# input controls outside the GridContainer bands of a banded page, and dead
# zones (>25% empty grid rows between a page's first and last element). The
# "PHASEE PBI Employee Dashboard" regression shipped a parity-green workbook
# that was a visual mess — every data gate passed. Escape: --skip-layout-lint
# (legacy/intentional layouts only; name the reason in your report).
if opts[:type] == 'workbook' && !opts[:skip_lint]
  require_relative 'lib/layout_lint'
  violations = LayoutLint.lint(spec)
  if violations.any?
    warn "\n========================================"
    warn "FAIL — layout lint: #{violations.size} violation(s):"
    violations.each { |v| warn "  - #{v}" }
    warn 'Fix the spec/layout and re-PUT before continuing: raw-id names -> derive human'
    warn 'titles; loose controls -> control band or the chart container; dead zones ->'
    warn 're-band the page. The workbook DID post — fix with PUT /v2/workbooks/<id>/spec'
    warn '(re-POSTing creates an orphan).'
    warn '========================================'
    exit(3)
  end
  warn 'layout lint: clean (raw-id names / orphan controls / dead zones)'
end

# Control-wiring lint (shared scripts/lib/control_lint.rb — vendored byte-
# identical, md5 discipline): fails loudly on dead controls (no resolving
# filter target AND no [controlId] formula reference — the "Orders Overview
# (from Looker)" estate escape), ghost filter targets, and controls whose
# source-closure misses same-page queryable elements (the PHASEE
# "Action(Region) -> Monthly Revenue Trend" escape). If the builder emitted a
# control-scope sidecar (<workdir>/control-scope.json — see the lib header
# CONTRACT), it also fails when the source artifact had filter signals but the
# spec shipped zero controls (the Qlik class), and honors per-control
# scope:[...] allowlists for intentional single-chart switchers (grain
# controls). Escape: --skip-control-lint (name the reason in your report).
if opts[:type] == 'workbook' && !opts[:skip_control_lint]
  require_relative 'lib/control_lint'
  scope_path = opts[:control_scope] || File.join(opts[:workdir], 'control-scope.json')
  scope = nil
  if File.exist?(scope_path)
    scope = JSON.parse(File.read(scope_path)) rescue nil
    warn "WARN: #{scope_path} is not valid JSON — control lint runs without source scope" if scope.nil?
  end
  violations = ControlLint.lint(spec, scope: scope)
  if violations.any?
    warn "\n========================================"
    warn "FAIL — control lint: #{violations.size} violation(s):"
    violations.each { |v| warn "  - #{v}" }
    warn 'Fix the control wiring and re-PUT before continuing: dead controls -> add'
    warn 'filters targets ({source:{elementId}, columnId}) or remove the control;'
    warn 'partial reach -> wire the uncovered elements or annotate controlScope in'
    warn 'control-scope.json (see scripts/lib/control_lint.rb CONTRACT). The workbook'
    warn 'DID post — fix with PUT /v2/workbooks/<id>/spec (re-POSTing creates an orphan).'
    warn '========================================'
    exit(4)
  end
  n = ControlLint.controls_report(spec).length
  warn "control lint: clean (#{n} control(s); dead / ghost-target / reach#{scope ? ' / source-scope' : ''})"
end

# Phase 6 nag — column-type guard catches formula-resolution errors but does
# NOT compare data values to Tableau. Phase 6 (mandatory per SKILL.md) is the
# ONLY thing that confirms the chart actually reproduces the source. Emit a
# clear next-step prompt so the agent (or human) doesn't silently skip it.
if opts[:type] == 'workbook'
  warn ""
  warn "================================================================"
  warn "NEXT STEP — Phase 6 (MANDATORY): verify data parity vs Tableau"
  warn "================================================================"
  warn "Column-type guard PASSES means formulas RESOLVE. It does NOT mean"
  warn "the chart values match Tableau's. Run this BEFORE declaring done:"
  warn ""
  warn "  ruby scripts/phase6-parity.rb \\"
  warn "    --tableau <dir-with-views/-and-get-workbook.json> \\"
  warn "    --workbook-id #{oid}"
  warn ""
  warn "Add --extract-mode --extract-tol 0.30 if the Tableau workbook has"
  warn "a .hyper extract (drift between live + cached data is expected)."
  warn "================================================================"
end
